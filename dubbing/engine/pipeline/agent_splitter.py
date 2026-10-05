"""
Splitting Agent: Dynamically divides and rephrases script translations based on
timing windows and estimated speech durations.
"""

import json
import os
import re
import threading
from typing import Dict, List, Tuple, Sequence
from .llm import _llm_generate
from .config import GEMINI_DEFAULT_MODEL, _env_int, _run_parallel, CONFIG_DIR

# Over-long sections are shortened by independent LLM calls (each one sees
# only the ORIGINAL script text of its neighbours), so they run a few at a
# time. DUB_SHORTEN_WORKERS=1 restores the old one-at-a-time behaviour.
SHORTEN_WORKERS = _env_int("DUB_SHORTEN_WORKERS", 4, 1, 8)

# Starting guess of the speaking rate, characters per second per language.
# Only a guess: after every match-mode dub the engine measures how fast the
# voice really spoke (learn_speech_rate) and later runs use that instead.
LANG_CHARS_PER_SEC = {
    "Hindi": 9.2,      # Hindi is spoken slower on ElevenLabs
    "Marathi": 12.0,
    "Bengali": 12.0,
    "Gujarati": 11.0,
    "Tamil": 12.0,
    "Telugu": 11.5,
    "Kannada": 11.5,
    "Malayalam": 12.0,
    "Punjabi": 10.5,
    "Sanskrit": 10.0,
    "English": 14.0,
}
DEFAULT_CHARS_PER_SEC = 11.0

# ─── 0.15.11: fit a line to its English slot, cut as little as possible ─────
# Field report (Bengali, 2026-10-05): about 30% of shortened lines came back
# far too short or missing meaning, and near-perfect pasted scripts were
# rewritten too. Causes: the length check was a fixed letter-count guess, the
# room counted only while the English speaks (not the pause after it), and
# the model was told only "under N seconds" — so it played safe and cut hard.
#
# Now:
#   * room = the English speaking time + the pause after it (up to
#     PAUSE_ROOM_MAX), and a line is only shortened when it overruns that
#     room AND the old 15% tolerance;
#   * the model gets a character budget (FIT_LO..FIT_HI of the room) and is
#     told to keep every idea and change as few words as possible;
#   * a result outside the budget gets ONE retry that says what went wrong;
#   * if neither try lands in FIT_LO..FIT_HI, the closer one is used when it
#     is within KEEP_LO..KEEP_HI; otherwise the original line is kept and
#     listed as "too long — check in Redo". Nothing under KEEP_LO is ever used.
#   * every decision is recorded so the engine can write a changes list.
PAUSE_ROOM_MAX = 1.5     # seconds of the following pause a line may use
FIT_LO, FIT_HI = 0.90, 1.00     # target share of the room
KEEP_LO, KEEP_HI = 0.80, 1.15   # acceptable when no try hits the target
OVERRUN_TOLERANCE = 1.15        # never shorten a line within 15% of its English

SPEECH_RATES_FILE = os.path.join(CONFIG_DIR, "speech_rates.json")
_rates_lock = threading.Lock()


def _clean(text: str) -> str:
    return re.sub(r"\[.*?\]", "", text or "").strip()  # audio tags are not spoken


def _load_rates() -> dict:
    try:
        with open(SPEECH_RATES_FILE, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def chars_per_sec(language: str = "", model: str = "") -> float:
    """Speaking rate for *language*: the measured one for this voice model,
    else the measured one for the language, else the starting guess."""
    rates = _load_rates()
    for key in (f"{language}|{model}" if model else None, language):
        v = rates.get(key) if key else None
        if isinstance(v, dict) and isinstance(v.get("cps"), (int, float)):
            return float(v["cps"])
    return LANG_CHARS_PER_SEC.get(language, DEFAULT_CHARS_PER_SEC) \
        if language else DEFAULT_CHARS_PER_SEC


def learn_speech_rate(language: str, model: str, texts, durations,
                      status_cb=None):
    """Measure how fast the voice actually spoke this run (characters of the
    spoken text / seconds of the synthesized pieces) and fold it into
    config/speech_rates.json, for this language + model and for the language.
    Pieces shorter than 0.3 s or 3 characters are ignored; a run with under
    5 s of speech teaches nothing. The value moves 40% of the way to each new
    measurement, so one odd run cannot swing it. Returns the new rate or None.
    Never raises — this is bookkeeping, the dub is already done."""
    try:
        chars = secs = 0.0
        for t, d in zip(texts, durations):
            n = len(_clean(t))
            if n >= 3 and d and d >= 0.3:
                chars += n
                secs += float(d)
        if secs < 5.0 or chars <= 0:
            return None
        measured = max(4.0, min(30.0, chars / secs))
        with _rates_lock:
            rates = _load_rates()
            out = None
            for key in (f"{language}|{model}" if model else None, language):
                if not key:
                    continue
                old = rates.get(key) if isinstance(rates.get(key), dict) else {}
                prev = old.get("cps")
                new = measured if not isinstance(prev, (int, float)) \
                    else 0.6 * float(prev) + 0.4 * measured
                rates[key] = {"cps": round(new, 2),
                              "runs": int(old.get("runs") or 0) + 1}
                out = out or rates[key]["cps"]
            os.makedirs(os.path.dirname(SPEECH_RATES_FILE), exist_ok=True)
            tmp = SPEECH_RATES_FILE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(rates, f, ensure_ascii=False, indent=2)
            os.replace(tmp, SPEECH_RATES_FILE)
        if status_cb:
            status_cb(f"    [Splitter] Measured speaking rate: {measured:.1f} "
                      f"chars/s ({language}, {model or 'default model'}) — "
                      f"next runs estimate with {out:.1f}.")
        return out
    except Exception:
        return None


def estimate_duration(text: str, language: str = "", rate: float = None) -> float:
    """Estimated spoken seconds of *text* (audio tags stripped)."""
    return len(_clean(text)) / (rate or chars_per_sec(language))


def _fit_prompt(tr_text, en_text, language, lo, hi, prev_ctx, next_ctx,
                last_try=None):
    note = ""
    if last_try is not None:
        got = len(_clean(last_try))
        what = ("too SHORT — it dropped words the line needs; keep more of "
                "the original wording" if got < lo else
                "still too LONG — remove a little more")
        note = (f"\nYour previous version had {got} characters, which is "
                f"{what}.\nPrevious version: \"{last_try}\"\n")
    return (
        f"You are an expert audio dubbing editor working in {language}. This "
        f"translated line is a little too long to be spoken in the time the "
        f"English takes. Make it fit by changing AS LITTLE AS POSSIBLE.\n"
        f"Rules:\n"
        f"- The result must be between {lo} and {hi} characters long "
        f"(the line now has {len(_clean(tr_text))}). Not shorter: a line that "
        f"is too short sounds rushed into silence and loses meaning.\n"
        f"- Keep every idea, name and image of the line. Prefer shorter "
        f"synonyms and dropping filler words over dropping content.\n"
        f"- Keep the speaker's style and the vocabulary of the surrounding "
        f"lines (for example 'nailed' in a crucifixion context means "
        f"crucified, never slang).\n"
        f"- Keep any [tags] exactly as they are.\n"
        f"{note}\n"
        f"Previous lines: \"{prev_ctx}\"\n"
        f"Next lines: \"{next_ctx}\"\n\n"
        f"Original English: \"{en_text}\"\n"
        f"Line to fit: \"{tr_text}\"\n\n"
        f"Output ONLY the fitted line — no quotes, no commentary.\n"
        f"Fitted line:"
    )


def _strip_quotes(s: str) -> str:
    return re.sub(r'^["\'“‘](.*?)["\'”’]$', r'\1', (s or "").strip()).strip()


def fit_line(tr_text: str, en_text: str, room: float, language: str,
             model: str = GEMINI_DEFAULT_MODEL, rate: float = None,
             status_cb=None, prev_ctx: str = "", next_ctx: str = "",
             generate=None):
    """Fit one too-long line into *room* seconds. Returns
    (text, status, share): status is 'fitted', 'close' (a try within
    KEEP_LO..KEEP_HI) or 'kept_too_long' (original kept); share is the
    result's estimated length as a share of the room."""
    rate = rate or chars_per_sec(language)
    gen = generate or (lambda pr: _llm_generate(pr, model, role="match"))
    budget = room * rate
    lo, hi = max(1, int(budget * FIT_LO)), max(1, int(budget * FIT_HI))

    def share(s):
        return estimate_duration(s, language, rate) / room if room > 0 else 9.9

    tries = []
    last = None
    for _ in range(2):
        try:
            out = _strip_quotes(gen(_fit_prompt(tr_text, en_text, language, lo,
                                                hi, prev_ctx, next_ctx, last)))
        except Exception as e:
            if status_cb:
                status_cb(f"    [Splitter] fit request failed: {e}")
            out = ""
        if out:
            sh = share(out)
            tries.append((out, sh))
            if FIT_LO <= sh <= FIT_HI:
                break
            last = out
        else:
            last = None
    for out, sh in tries:
        if FIT_LO <= sh <= FIT_HI:
            return out, "fitted", sh
    ok = [(o, s) for o, s in tries if KEEP_LO <= s <= KEEP_HI]
    if ok:
        out, sh = min(ok, key=lambda x: abs(x[1] - 0.95))
        return out, "close", sh
    return tr_text, "kept_too_long", share(tr_text)


def shorten_text(tr_text: str, en_text: str, target_dur: float, language: str,
                 model: str = GEMINI_DEFAULT_MODEL, status_cb=None,
                 prev_ctx: str = "", next_ctx: str = "") -> str:
    """Older entry point (still imported by agent_aligner): fit_line's text."""
    return fit_line(tr_text, en_text, target_dur, language, model,
                    status_cb=status_cb, prev_ctx=prev_ctx,
                    next_ctx=next_ctx)[0]


def agentic_split_match(en_entries: Sequence[Tuple[float, float, str]],
                        tr_sentences: Sequence[str],
                        language: str,
                        model: str = GEMINI_DEFAULT_MODEL,
                        status_cb=None,
                        shorten: bool = True,
                        voice_model: str = "",
                        changes: list = None,
                        generate=None,
                        match_fn=None,
                        ) -> Tuple[List[Dict[str, List[int]]], List[int], List[int], List[str]]:
    """Splitting Agent orchestrates the match process:
    1. Runs the initial semantic matching to group TR sentences with EN cues.
    2. Checks each matched group's estimated length against its room (the
       English time + the pause after it). A group that overruns is fitted
       with fit_line — unless *shorten* is False, in which case it is only
       reported.
    *changes*, when given, receives one dict per overrunning group (what was
    done and why) for the engine's changes list. *generate* / *match_fn* are
    test seams.
    """
    if match_fn is None:
        from .match import call_match_sections as match_fn

    sections, unmatched_tr, unmatched_en = match_fn(
        en_entries, tr_sentences, language, model, status_cb
    )
    rate = chars_per_sec(language, voice_model)
    if status_cb:
        status_cb(f"    [Splitter] Speaking rate for {language}: {rate:.1f} "
                  f"chars/s.")

    # Make a copy of tr_sentences so we can modify translations in-place
    modified_sentences = list(tr_sentences)

    # Pass 1 — decide which sections overrun and build each request from the
    # ORIGINAL sentences. _sanitize_match guarantees a TR id belongs to at
    # most one section, so no decision depends on another's shortening.
    jobs = []      # (tr_ids, tr_text, en_text, room, prev, next, est)
    for s in sections:
        if not s["en"] or not s["tr"]:
            continue
        en_ids = sorted(s["en"])
        tr_ids = sorted(s["tr"])
        win_a = min(en_entries[i - 1][0] for i in en_ids)
        win_b = max(en_entries[i - 1][1] for i in en_ids)
        window_dur = win_b - win_a
        # The pause after this English, up to the next cue (or the end).
        last_en = en_ids[-1]
        if last_en < len(en_entries):
            gap = en_entries[last_en][0] - win_b
        else:
            gap = PAUSE_ROOM_MAX
        room = window_dur + max(0.0, min(PAUSE_ROOM_MAX, gap))

        tr_text = " ".join(tr_sentences[j - 1].strip() for j in tr_ids)
        en_text = " ".join(en_entries[i - 1][2].strip() for i in en_ids)
        est_dur = estimate_duration(tr_text, language, rate)

        if room > 0 and est_dur > max(room, window_dur * OVERRUN_TOLERANCE,
                                      window_dur + 0.5):
            prev_ctx = " | ".join(tr_sentences[p - 1] for p in
                                  range(max(1, tr_ids[0] - 2), tr_ids[0]))
            next_ctx = " | ".join(tr_sentences[n - 1] for n in
                                  range(tr_ids[-1] + 1,
                                        min(len(tr_sentences) + 1, tr_ids[-1] + 3)))
            jobs.append((tr_ids, tr_text, en_text, room, prev_ctx, next_ctx,
                         est_dur))

    lock = threading.Lock()

    def _say(msg):
        if status_cb:
            with lock:
                status_cb(msg)

    if not shorten:
        if jobs:
            _say(f"    [Splitter] {len(jobs)} line(s) longer than their "
                 "English — left as written (shortening is off).")
        for j in jobs:
            if changes is not None:
                changes.append({"tr_ids": j[0], "en": j[2], "before": j[1],
                                "after": j[1], "status": "off",
                                "room": j[3], "share_before": j[6] / j[3],
                                "share_after": j[6] / j[3]})
        return sections, unmatched_tr, unmatched_en, modified_sentences

    # Pass 2 — the LLM calls, a few at a time.
    if jobs:
        _say(f"    [Splitter] Fitting {len(jobs)} line(s) to their English, "
             f"up to {min(SHORTEN_WORKERS, len(jobs))} at a time...")
    results = _run_parallel(
        [(lambda j=j: fit_line(j[1], j[2], j[3], language, model, rate,
                               _say if status_cb else None, j[4], j[5],
                               generate))
         for j in jobs],
        SHORTEN_WORKERS)

    # Pass 3 — apply in section order: the fitted text goes to the first
    # sentence of the group, the others are emptied.
    for j, (text, status, share) in zip(jobs, results):
        tr_ids = j[0]
        if status != "kept_too_long":
            modified_sentences[tr_ids[0] - 1] = text
            for extra_id in tr_ids[1:]:
                modified_sentences[extra_id - 1] = ""
        _say(f"    [Splitter] {status}: {share * 100:.0f}% of {j[3]:.1f}s "
             f"(was {j[6] / j[3] * 100:.0f}%)")
        if changes is not None:
            changes.append({"tr_ids": tr_ids, "en": j[2], "before": j[1],
                            "after": text, "status": status, "room": j[3],
                            "share_before": j[6] / j[3], "share_after": share})

    return sections, unmatched_tr, unmatched_en, modified_sentences
