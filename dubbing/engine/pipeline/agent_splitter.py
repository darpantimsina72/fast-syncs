"""
Splitting Agent: Dynamically divides and rephrases script translations based on
timing windows and estimated speech durations.
"""

import re
import threading
from typing import Dict, List, Tuple, Sequence
from .llm import _llm_generate
from .config import GEMINI_DEFAULT_MODEL, _env_int, _run_parallel

# Over-long sections are shortened by independent LLM calls (each one sees
# only the ORIGINAL script text of its neighbours), so they run a few at a
# time. DUB_SHORTEN_WORKERS=1 restores the old one-at-a-time behaviour.
SHORTEN_WORKERS = _env_int("DUB_SHORTEN_WORKERS", 4, 1, 8)

# Estimated speaking rate: characters per second depending on language
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


def estimate_duration(text: str, language: str = "") -> float:
    """Estimate spoken duration of text in seconds based on character count and language."""
    clean_text = re.sub(r"\[.*?\]", "", text).strip()  # remove tags
    rate = LANG_CHARS_PER_SEC.get(language, DEFAULT_CHARS_PER_SEC) if language else DEFAULT_CHARS_PER_SEC
    return len(clean_text) / rate


def shorten_text(tr_text: str, en_text: str, target_dur: float, language: str,
                 model: str = GEMINI_DEFAULT_MODEL, status_cb=None,
                 prev_ctx: str = "", next_ctx: str = "") -> str:
    """Use Gemini to shorten a translation text to fit a target duration, with dialogue context."""
    if status_cb:
        status_cb(f"    [Splitter] Shortening text: '{tr_text}' to fit {target_dur:.1f}s...")

    prompt = (
        f"You are an expert audio dubbing editor. Shorten the following translated text ({language}) "
        f"so that it can be naturally spoken in under {target_dur:.1f} seconds.\n"
        f"Maintain the core semantic meaning and style of the original English phrase as closely as possible. "
        f"Use the surrounding dialogue context to ensure correct vocabulary and word meanings (for example, "
        f"translating 'nailed' correctly in context as 'crucified/सूली पर चढ़ाया' rather than slang/literal translations).\n\n"
        f"Context of surrounding dialogue:\n"
        f"Previous lines: \"{prev_ctx}\"\n"
        f"Next lines: \"{next_ctx}\"\n\n"
        f"Original English: \"{en_text}\"\n"
        f"Current translation to shorten: \"{tr_text}\"\n\n"
        f"Do NOT add any commentary or explanation — output ONLY the shortened translation.\n"
        f"Shortened translation:"
    )

    result = _llm_generate(prompt, model, role="match").strip()
    # Strip quotes if the LLM wrapped it
    result = re.sub(r'^["\'“‘](.*?)["\'”’]$', r'\1', result).strip()

    if status_cb:
        status_cb(f"    [Splitter] Shortened: '{tr_text}' -> '{result}' "
                  f"(estimated: {estimate_duration(result, language):.1f}s)")
    return result


def agentic_split_match(en_entries: Sequence[Tuple[float, float, str]],
                        tr_sentences: Sequence[str],
                        language: str,
                        model: str = GEMINI_DEFAULT_MODEL,
                        status_cb=None
                        ) -> Tuple[List[Dict[str, List[int]]], List[int], List[int], List[str]]:
    """Splitting Agent orchestrates the match process:
    1. Runs the initial semantic matching to group TR sentences with EN cues.
    2. Checks each matched group's duration. If a translation is too long for its window,
       rephrases it to fit.
    """
    from .match import call_match_sections
    
    sections, unmatched_tr, unmatched_en = call_match_sections(
        en_entries, tr_sentences, language, model, status_cb
    )

    # Make a copy of tr_sentences so we can modify translations in-place
    modified_sentences = list(tr_sentences)

    # Pass 1 — decide which sections need shortening and build each request
    # from the ORIGINAL sentences. _sanitize_match guarantees a TR id belongs
    # to at most one section, so no section's decision or text depends on
    # another section's shortening; only the neighbour CONTEXT used to be
    # able to see an already-shortened line, and it now always shows the
    # original wording (the full meaning — never less information).
    jobs = []            # (tr_ids, tr_text, en_text, window_dur, prev, next)
    for s in sections:
        if not s["en"] or not s["tr"]:
            continue
        
        # Calculate target window duration
        win_a = min(en_entries[i - 1][0] for i in s["en"])
        win_b = max(en_entries[i - 1][1] for i in s["en"])
        window_dur = win_b - win_a

        # Gather current translation text and English text
        tr_ids = sorted(s["tr"])
        en_ids = sorted(s["en"])
        
        tr_text = " ".join(tr_sentences[j - 1].strip() for j in tr_ids)
        en_text = " ".join(en_entries[i - 1][2].strip() for i in en_ids)

        est_dur = estimate_duration(tr_text, language)

        # If estimated duration overruns target window by more than 15% (or 0.5s)
        if est_dur > max(window_dur * 1.15, window_dur + 0.5):
            # Extract previous and next lines for semantic context
            prev_context = []
            for p_id in range(max(1, tr_ids[0] - 2), tr_ids[0]):
                prev_context.append(tr_sentences[p_id - 1])
            prev_ctx_str = " | ".join(prev_context)

            next_context = []
            for n_id in range(tr_ids[-1] + 1, min(len(tr_sentences) + 1, tr_ids[-1] + 3)):
                next_context.append(tr_sentences[n_id - 1])
            next_ctx_str = " | ".join(next_context)

            jobs.append((tr_ids, tr_text, en_text, window_dur,
                         prev_ctx_str, next_ctx_str))

    # Pass 2 — the LLM calls, a few at a time. status_cb is serialised so
    # two progress lines never interleave in the log.
    lock = threading.Lock()

    def _say(msg):
        if status_cb:
            with lock:
                status_cb(msg)

    if len(jobs) > 1 and SHORTEN_WORKERS > 1:
        _say(f"    [Splitter] Shortening {len(jobs)} section(s), up to "
             f"{min(SHORTEN_WORKERS, len(jobs))} at a time...")
    shortened_all = _run_parallel(
        [(lambda j=j: shorten_text(
            j[1], j[2], j[3], language, model, _say if status_cb else None,
            prev_ctx=j[4], next_ctx=j[5]))
         for j in jobs],
        SHORTEN_WORKERS)

    # Pass 3 — apply in section order, exactly as before: the shortened text
    # goes to the first sentence of the group, the others are emptied.
    for (tr_ids, *_rest), shortened in zip(jobs, shortened_all):
        if tr_ids:
            modified_sentences[tr_ids[0] - 1] = shortened
            for extra_id in tr_ids[1:]:
                modified_sentences[extra_id - 1] = ""

    return sections, unmatched_tr, unmatched_en, modified_sentences
