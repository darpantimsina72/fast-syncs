# Auto-sync-style Gemini section matching + slot placement (contract v0.7).
# Ported from the fast-syncs sync_matcher.py matcher (＿call_gemini_sections +
# _place_with_springs, see that file's provenance) and adapted for the dub
# engine: the "DUB clips" side is not recorded audio but the translation
# script split into sentences, matched BEFORE TTS, so every synthesized
# section lands at the timestamp of the English cue it translates. Transport
# is the engine's provider-agnostic _llm_generate (vertex | gemini | gateway),
# NOT sync_matcher's own HTTP layer — credentials stay in config/.
#
# No silence correction here (sync_matcher applies speech-onset correction
# between two recordings): TTS sections start at speech and the English sync
# SRT cue starts are already word-refined speech onsets, so the correction
# would always be ~0.

import json
import re
from typing import Dict, List, Optional, Sequence, Tuple

from .config import GEMINI_DEFAULT_MODEL
from .llm import _llm_generate

# Sentence splitting for the match units lives in tts._split_script_into_
# sentences (shared with per-sentence TTS): blank lines are hard breaks,
# Latin .!?… and danda ।॥ end sentences, tag-only fragments stay attached.

MIN_SPRING = 0.010          # 10 ms anti-overlap spring between placed chunks


def _parse_match_json(raw: str) -> Optional[dict]:
    """Fence-strip + parse + {..} salvage, exactly like sync_matcher."""
    cleaned = (raw or "").strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```\w*\n?", "", cleaned)
        cleaned = re.sub(r"\n?```$", "", cleaned)
        cleaned = cleaned.strip()
    try:
        parsed = json.loads(cleaned)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", cleaned, re.DOTALL)
        if not m:
            return None
        try:
            parsed = json.loads(m.group(0))
        except json.JSONDecodeError:
            return None
    return parsed if isinstance(parsed, dict) else None


def _int_ids(seq) -> List[int]:
    return [int(x) for x in (seq or [])
            if isinstance(x, (int, float, str)) and str(x).lstrip("-").isdigit()]


_MATCH_RULES_PREFIX = (
    "You are an audio-dubbing sync expert. Match translated script sentences "
    "to the English source cues they translate, by meaning.\n"
    "Group EN cue IDs and TR sentence IDs into sections, where each section "
    "represents ONE thought.\n\n"
    "Return ONLY a single JSON object (no markdown, no commentary):\n"
    "{\n"
    '  "sections": [\n'
    '    {"en": [<id>,...], "tr": [<id>,...]},\n'
    "    ...\n"
    "  ],\n"
    '  "unmatched_tr": [<id>,...],\n'
    '  "unmatched_en":  [<id>,...]\n'
    "}\n\n"
    "Rules:\n"
    "1. Every EN id must appear exactly once (in a section OR unmatched_en).\n"
    "2. Every TR id must appear exactly once (in a section OR unmatched_tr).\n"
    "3. Sections in chronological order by EN cue position.\n"
    "4. Group consecutive EN cues that finish one thought (e.g. a sentence "
    "split by silence detection).\n"
    "5. Group consecutive TR sentences that together translate that thought. "
    "Translations are not literal — match by meaning, not exact words.\n"
    "6. A TR sentence with no English counterpart (translator addition, "
    "speaker name like \"Sadhguru:\", chapter heading) goes in unmatched_tr.\n"
    "7. An EN cue whose content is absent from the translation goes in "
    "unmatched_en.\n"
    "8. Keep TR sentence order: the script reads top to bottom in the same "
    "order the English is spoken, so sections should consume TR ids in "
    "ascending order.\n"
)


def call_match_sections(en_entries: Sequence[Tuple[float, float, str]],
                        tr_sentences: Sequence[str],
                        language: str,
                        model: str = GEMINI_DEFAULT_MODEL,
                        status_cb=None
                        ) -> Tuple[List[Dict[str, List[int]]], List[int], List[int]]:
    """One Gemini call: section-group EN cues (1-based ids) with TR sentences
    (1-based ids). Returns (sections, unmatched_tr_ids, unmatched_en_ids).

    Retries once on an unusable reply, then raises — no silent fallback, a
    failed match must stop the run instead of producing a half-synced dub
    (same philosophy as the Auto Sync tab)."""
    en_lines = [
        f"  EN[{i}] @{s0:.2f}s ({s1 - s0:.2f}s): \"{(t or '').strip()}\""
        for i, (s0, s1, t) in enumerate(en_entries, 1)
    ]
    tr_lines = [
        f"  TR[{j}]: \"{(t or '').strip()}\""
        for j, t in enumerate(tr_sentences, 1)
    ]
    dynamic = (
        f"\n=== ENGLISH CUES ===\n{chr(10).join(en_lines)}\n"
        f"\n=== TRANSLATED SCRIPT SENTENCES ({language}) ===\n"
        f"{chr(10).join(tr_lines)}\n\n"
        "JSON:"
    )

    if status_cb:
        status_cb(f"Matching {len(en_lines)} EN cues to {len(tr_lines)} "
                  f"script sentences ({len(_MATCH_RULES_PREFIX) + len(dynamic)}"
                  " chars)…")

    last_err = "empty reply"
    for attempt in (1, 2):
        raw = _llm_generate(dynamic, model, static_prefix=_MATCH_RULES_PREFIX,
                            role="match")
        parsed = _parse_match_json(raw)
        if parsed is None:
            last_err = f"unparsable reply ({(raw or '')[:120]!r}…)"
        else:
            sections = []
            for s in parsed.get("sections") or []:
                if not isinstance(s, dict):
                    continue
                en_ids = _int_ids(s.get("en"))
                tr_ids = _int_ids(s.get("tr"))
                if en_ids or tr_ids:
                    sections.append({"en": en_ids, "tr": tr_ids})
            if sections:
                unmatched_tr = _int_ids(parsed.get("unmatched_tr"))
                unmatched_en = _int_ids(parsed.get("unmatched_en"))
                return _sanitize_match(sections, unmatched_tr, unmatched_en,
                                       len(en_entries), len(tr_sentences),
                                       status_cb)
            last_err = "reply contained no usable sections"
        if status_cb and attempt == 1:
            status_cb(f"Match attempt 1 failed ({last_err}) — retrying once…")

    raise RuntimeError(
        f"Gemini section matching failed twice ({last_err}). The run stops "
        "here instead of guessing positions — check the LLM settings "
        "(panel Settings tab) and try again.")


def _sanitize_match(sections, unmatched_tr, unmatched_en, n_en, n_tr,
                    status_cb=None):
    """Enforce rule 1/2 mechanically: drop out-of-range and duplicate ids,
    file every unmentioned id as unmatched. The placer must never see an id
    twice or an id that does not exist."""
    seen_en, seen_tr = set(), set()
    clean_sections = []
    for s in sections:
        en_ids = [i for i in s["en"] if 1 <= i <= n_en and i not in seen_en]
        tr_ids = [j for j in s["tr"] if 1 <= j <= n_tr and j not in seen_tr]
        seen_en.update(en_ids)
        seen_tr.update(tr_ids)
        if en_ids or tr_ids:
            clean_sections.append({"en": en_ids, "tr": tr_ids})

    unmatched_tr = [j for j in unmatched_tr
                    if 1 <= j <= n_tr and j not in seen_tr and not seen_tr.add(j)]
    unmatched_en = [i for i in unmatched_en
                    if 1 <= i <= n_en and i not in seen_en and not seen_en.add(i)]

    missing_tr = [j for j in range(1, n_tr + 1) if j not in seen_tr]
    missing_en = [i for i in range(1, n_en + 1) if i not in seen_en]
    if missing_tr:
        unmatched_tr = sorted(unmatched_tr + missing_tr)
        if status_cb:
            status_cb(f"WARNING: {len(missing_tr)} TR sentence(s) missing "
                      f"from the reply — treated as unmatched: "
                      f"{missing_tr[:10]}")
    if missing_en and status_cb:
        status_cb(f"note: {len(missing_en)} EN cue(s) not mentioned in the "
                  "reply — treated as unmatched EN (no dub for them).")

    return clean_sections, unmatched_tr, unmatched_en


def build_chunks(sections: List[Dict[str, List[int]]],
                 unmatched_tr: List[int],
                 tr_sentences: Sequence[str]
                 ) -> List[dict]:
    """Turn the match result into the TTS chunk list, in SCRIPT order.

    One chunk per matched section (its TR sentences joined), plus one chunk
    per run of consecutive unmatched TR sentences (they still get dubbed —
    they just park on the Un sync track). A section that lost one of its
    sides in sanitizing degrades to unmatched. Chunks are ordered by their
    first TR sentence id so the concatenated TTS wav reads like the script
    and ElevenLabs request-stitching gets natural neighbour context."""
    chunks = []
    demoted: List[int] = []
    for s in sections:
        if not s["en"] or not s["tr"]:
            demoted.extend(s["tr"])
            continue
        tr_ids = sorted(s["tr"])
        chunks.append({
            "tr_ids": tr_ids,
            "en_ids": sorted(s["en"]),
            "text": " ".join(tr_sentences[j - 1].strip() for j in tr_ids),
        })

    loose = sorted(set(unmatched_tr) | set(demoted))
    run: List[int] = []
    for j in loose:
        if run and j == run[-1] + 1:
            run.append(j)
        else:
            if run:
                chunks.append(_unsync_chunk(run, tr_sentences))
            run = [j]
    if run:
        chunks.append(_unsync_chunk(run, tr_sentences))

    chunks.sort(key=lambda c: c["tr_ids"][0])
    return chunks


def _unsync_chunk(tr_ids: List[int], tr_sentences: Sequence[str]) -> dict:
    return {
        "tr_ids": list(tr_ids),
        "en_ids": [],
        "text": " ".join(tr_sentences[j - 1].strip() for j in tr_ids),
    }


# ─── v0.8 sentence-level pieces ──────────────────────────────────────────────
# One piece per sentence. Gemini's sections stay the unit of CERTAINTY (this
# thought belongs to that English window); the section's window is then
# sliced among its sentences proportionally by character share, so each
# sentence gets its own target on the timeline. Coarse thought-level chunks
# were placed as blocks, which read as "coming in bunches" — the whole point
# of pieces is restoring the old fine grain without the old guessing.

CASCADE_MAX_S = 1.5     # most slack one piece may borrow from its neighbour


def build_pieces(sections: List[Dict[str, List[int]]],
                 unmatched_tr: List[int],
                 tr_sentences: Sequence[str],
                 en_entries: Sequence[Tuple[float, float, str]]
                 ) -> List[dict]:
    """Explode the match result into per-sentence pieces, in script order.

    Matched section → one piece per sentence, each with a "win" (start, end)
    slice of the section's English window sized by the sentence's share of
    the section text. Unmatched sentences → one windowless piece each (they
    end up on Un sync as single draggable lines, not merged blobs). A
    section that lost a side in sanitizing degrades to unmatched."""
    pieces: List[dict] = []
    demoted: List[int] = []
    for s in sections:
        if not s["en"] or not s["tr"]:
            demoted.extend(s["tr"])
            continue
        tr_ids = sorted(s["tr"])
        win_a = min(en_entries[i - 1][0] for i in s["en"])
        win_b = max(en_entries[i - 1][1] for i in s["en"])
        texts = [" ".join(tr_sentences[j - 1].split()) for j in tr_ids]
        total = float(sum(len(t) for t in texts)) or 1.0
        cur = win_a
        for k, (j, t) in enumerate(zip(tr_ids, texts)):
            if k == len(tr_ids) - 1:
                nxt = win_b                     # last slice takes the rest
            else:
                nxt = min(win_b, cur + (win_b - win_a) * (len(t) / total))
            pieces.append({"tr_ids": [j], "text": t, "win": (cur, nxt)})
            cur = nxt

    for j in sorted(set(unmatched_tr) | set(demoted)):
        pieces.append({"tr_ids": [j],
                       "text": " ".join(tr_sentences[j - 1].split()),
                       "win": None})

    pieces.sort(key=lambda p: p["tr_ids"][0])
    return pieces


def place_pieces(pieces: List[dict],
                 durations_s: Sequence[float],
                 log=None) -> List[dict]:
    """Windowed placement + order sweep with bounded slack borrowing.

    Same round structure as place_chunks, but against each piece's own
    window slice. The sweep keeps script order and forbids overlap; a piece
    that would overrun the next piece's target may borrow up to
    CASCADE_MAX_S seconds by shifting that ONE neighbour later — only when
    the neighbour still ends before ITS successor's target. Anything that
    cannot fit even then is demoted to the Un sync chain (each unsync piece
    parked right after the previous clip, chronological)."""
    say = log or (lambda m: None)

    wins = [p.get("win") for p in pieces]
    order = sorted((i for i in range(len(pieces)) if wins[i]),
                   key=lambda i: wins[i][0])
    gaps_b, gaps_a = {}, {}
    for k, i in enumerate(order):
        gaps_b[i] = max(0.0, wins[i][0] - wins[order[k - 1]][1]) if k > 0 else 0.0
        gaps_a[i] = (max(0.0, wins[order[k + 1]][0] - wins[i][1])
                     if k < len(order) - 1 else 0.0)

    placements: Dict[int, float] = {}
    processed = set()
    for iteration in (1, 2):
        for rnd in (1, 3, 5):
            for i in order:
                if i in processed:
                    continue
                a, b = wins[i]
                length = b - a
                content = float(durations_s[i])
                strategy = None
                if rnd == 1 and content <= length:
                    placements[i] = max(0.0, (a + b) / 2.0 - content / 2.0)
                    strategy = "center"
                elif rnd == 3 and content <= length + gaps_a[i]:
                    placements[i] = max(0.0, a)
                    strategy = "align_start"
                elif rnd == 5 and content <= (length + gaps_b[i]
                                              + gaps_a[i] + MIN_SPRING):
                    placements[i] = max(0.0, b + gaps_a[i] - MIN_SPRING
                                        - content)
                    strategy = "align_end"
                if strategy:
                    processed.add(i)
                    say(f"  piece{i + 1:>3} [iter{iteration} R{rnd} "
                        f"{strategy:<11}] win=[{a:.2f}-{b:.2f}]s "
                        f"dub={content:.2f}s")
    for i in order:
        if i not in processed:
            placements[i] = max(0.0, wins[i][0])
            processed.add(i)
            say(f"  piece{i + 1:>3} [align_start_fallback] "
                f"win=[{wins[i][0]:.2f}-{wins[i][1]:.2f}]s "
                f"dub={float(durations_s[i]):.2f}s")

    # Order sweep with ONE-level bounded borrowing.
    last_synced_end = 0.0
    last_any_end = 0.0
    unsync_pos: Dict[int, float] = {}
    pushes = borrows = demotions = 0

    def _next_spring_idx(after):
        for j in range(after + 1, len(pieces)):
            if j in placements:
                return j
        return None

    for i in range(len(pieces)):
        dur = float(durations_s[i])
        if i not in placements:
            pos = max(last_any_end, 0.0)
            unsync_pos[i] = pos
            last_any_end = pos + dur
            continue
        candidate = max(placements[i], last_synced_end)
        candidate_end = candidate + dur
        j = _next_spring_idx(i)
        next_spring = placements[j] if j is not None else float("inf")

        if candidate_end > next_spring:
            needed = candidate_end - next_spring
            ok = False
            if j is not None and needed <= CASCADE_MAX_S:
                k = _next_spring_idx(j)
                j_end = (placements[j] + needed) + float(durations_s[j])
                if k is None or j_end <= placements[k]:
                    placements[j] += needed
                    borrows += 1
                    ok = True
                    say(f"  [ORDER] piece{i + 1} borrowed {needed:.3f}s — "
                        f"piece{j + 1} shifted to {placements[j]:.3f}s")
            if not ok:
                pos = max(last_any_end, candidate)
                placements.pop(i)
                unsync_pos[i] = pos
                last_any_end = pos + dur
                demotions += 1
                say(f"  [ORDER] piece{i + 1} would end {candidate_end:.3f}s "
                    f"> next target {next_spring:.3f}s → Un sync at "
                    f"{pos:.3f}s")
                continue

        if candidate > placements[i] + MIN_SPRING:
            pushes += 1
        placements[i] = candidate
        last_synced_end = candidate_end
        last_any_end = candidate_end

    if pushes:
        say(f"  Order-preserving push fixes : {pushes}")
    if borrows:
        say(f"  Slack borrowed from a neighbour : {borrows}")
    if demotions:
        say(f"  Order violations → Un sync  : {demotions}")

    out = []
    for i in range(len(pieces)):
        if i in placements:
            out.append({"position": round(placements[i], 6),
                        "status": "synced"})
        else:
            out.append({"position": round(unsync_pos.get(i, 0.0), 6),
                        "status": "unsync"})
    return out


def place_chunks(chunks: List[dict],
                 en_entries: Sequence[Tuple[float, float, str]],
                 durations_s: Sequence[float],
                 log=None) -> List[dict]:
    """Slot placement + order sweep, ported from sync_matcher's
    _place_with_springs with one dub item per section.

    *durations_s[i]* is the synthesized duration of chunks[i]. Returns one
    dict per chunk: {"position": float, "status": "synced"|"unsync"}.
    Unsync chunks get chain positions (each right after the previous clip)
    exactly like the Auto Sync tab, so the Un sync track stays chronological."""
    say = log or (lambda m: None)

    secs = []
    for idx, (c, dur) in enumerate(zip(chunks, durations_s)):
        if not c["en_ids"]:
            continue
        slot_start = min(en_entries[i - 1][0] for i in c["en_ids"])
        slot_end = max(en_entries[i - 1][1] for i in c["en_ids"])
        secs.append({
            "chunk": idx,
            "slot_start": slot_start,
            "slot_end": slot_end,
            "slot_length": slot_end - slot_start,
            "content": float(dur),
        })

    secs.sort(key=lambda s: s["slot_start"])
    for i, s in enumerate(secs):
        s["gap_before"] = max(0.0, s["slot_start"] - secs[i - 1]["slot_end"]) if i > 0 else 0.0
        s["gap_after"] = (max(0.0, secs[i + 1]["slot_start"] - s["slot_end"])
                          if i < len(secs) - 1 else 0.0)

    placements: Dict[int, float] = {}
    processed = set()

    for iteration in (1, 2):
        for rnd in (1, 3, 5):
            for s in secs:
                if s["chunk"] in processed:
                    continue
                content = s["content"]
                strategy = None
                if rnd == 1 and content <= s["slot_length"]:
                    center = (s["slot_start"] + s["slot_end"]) / 2.0
                    placements[s["chunk"]] = max(0.0, center - content / 2.0)
                    strategy = "center"
                elif rnd == 3 and content <= s["slot_length"] + s["gap_after"]:
                    placements[s["chunk"]] = max(0.0, s["slot_start"])
                    strategy = "align_start"
                elif rnd == 5 and content <= (s["slot_length"] + s["gap_before"]
                                              + s["gap_after"] + MIN_SPRING):
                    target_end = s["slot_end"] + s["gap_after"] - MIN_SPRING
                    placements[s["chunk"]] = max(0.0, target_end - content)
                    strategy = "align_end"
                if strategy:
                    processed.add(s["chunk"])
                    say(f"  Sec chunk{s['chunk'] + 1:>3} [iter{iteration} R{rnd} "
                        f"{strategy:<11}] slot=[{s['slot_start']:.2f}-"
                        f"{s['slot_end']:.2f}]s gap_b={s['gap_before']:.2f}s "
                        f"gap_a={s['gap_after']:.2f}s dub={content:.2f}s")

    for s in secs:
        if s["chunk"] in processed:
            continue
        placements[s["chunk"]] = max(0.0, s["slot_start"])
        processed.add(s["chunk"])
        say(f"  Sec chunk{s['chunk'] + 1:>3} [align_start_fallback] "
            f"slot=[{s['slot_start']:.2f}-{s['slot_end']:.2f}]s "
            f"dub={s['content']:.2f}s (longer than available space)")

    # Order-preserving sweep in script order (the analog of the Auto Sync
    # sweep over original recording positions): synced chunks must start in
    # script order and never overlap; a chunk that cannot fit before the
    # next chunk's spring position is demoted to the Un sync chain.
    last_synced_end = 0.0
    last_any_end = 0.0
    unsync_pos: Dict[int, float] = {}
    pushes = demotions = 0

    for i in range(len(chunks)):
        dur = float(durations_s[i])
        if i not in placements:
            pos = max(last_any_end, 0.0)
            unsync_pos[i] = pos
            last_any_end = pos + dur
            continue
        spring = placements[i]
        candidate = max(spring, last_synced_end)
        candidate_end = candidate + dur
        next_spring = float("inf")
        for j in range(i + 1, len(chunks)):
            if j in placements:
                next_spring = placements[j]
                break
        if candidate_end > next_spring:
            pos = max(last_any_end, candidate)
            placements.pop(i)
            unsync_pos[i] = pos
            last_any_end = pos + dur
            demotions += 1
            say(f"  [ORDER] chunk{i + 1} would end {candidate_end:.3f}s > next "
                f"spring {next_spring:.3f}s → Un sync at {pos:.3f}s")
        else:
            if candidate > spring + MIN_SPRING:
                pushes += 1
                say(f"  [ORDER] chunk{i + 1} pushed {spring:.3f}s → "
                    f"{candidate:.3f}s to stay after the previous chunk")
            placements[i] = candidate
            last_synced_end = candidate_end
            last_any_end = candidate_end

    if pushes:
        say(f"  Order-preserving push fixes : {pushes}")
    if demotions:
        say(f"  Order violations → Un sync  : {demotions}")

    out = []
    for i in range(len(chunks)):
        if i in placements:
            out.append({"position": round(placements[i], 6),
                        "status": "synced"})
        else:
            out.append({"position": round(unsync_pos.get(i, 0.0), 6),
                        "status": "unsync"})
    return out
