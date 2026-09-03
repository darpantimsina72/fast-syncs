"""
Pause-aware chunking + free dry-run fit analysis (contract v0.13).

NEW module — not extracted from the bulk app. Everything else in pipeline/
decides chunk boundaries from the SCRIPT (clause/sentence splitting in
tts.py) and then searches for somewhere on the timeline to put them
(match.py springs / order sweep, sync.py bleed-over), demoting whatever
will not fit to the Un sync track. This module inverts that: the SOURCE
audio's own pauses are the chunk grid, so every chunk's position is fixed
before any text is considered and placement stops being a search problem.

The only remaining question is whether the target text fits the slot it was
given — which is exactly what estimate_fit answers, from character counts
and a per-language speaking rate, with no ElevenLabs call and no LLM call.

Units: SECONDS everywhere inside this module (matching srt_tools/regions).
Milliseconds appear only in the on-disk plan file, which is the boundary
with sync.py and the REAPER importers.
"""

import os
import re
from typing import Dict, List, Optional, Sequence, Tuple

from .config import (LANG_CHARS_PER_SEC, DEFAULT_CHARS_PER_SEC,
                     estimate_duration)

# ─── Chunking ────────────────────────────────────────────────────────────────
# _detect_regions_from_audio already merges speech separated by less than its
# own min_sil_ms (150 ms by default). This is a SECOND, coarser gate applied
# on top: a 150 ms breath is a region boundary but not a place a dubber would
# ever cut. 200 ms is the shortest gap that still reads as a deliberate pause.
PAUSE_MIN_S = 0.20

# ─── Fit verdicts ────────────────────────────────────────────────────────────
# Two slots per chunk:
#   speech_slot = how long the source speaker talked   (dur_s)
#   hard_slot   = that plus the pause after it         (dur_s + pause_after_s)
# Overrunning the speech slot is survivable — it eats into a pause. Overrunning
# the hard slot means the dub is still talking when the NEXT chunk must start.
SHORT_RATIO = 0.85          # est < 0.85 x speech slot  -> dead air worth flagging
MAX_ATEMPO = 1.25           # stretch ceiling for the paid run

VERDICTS = ("empty", "short", "fits", "tight", "over")

PLAN_FORMAT_VERSION = 1
PLAN_HEADER = (
    "# Fast Syncs sync plan — v{ver}\n"
    "# Edit the TR: lines, save, then press ⟲ Reload in the panel.\n"
    "# Everything else is regenerated from the audio on every reload —\n"
    "# editing a timestamp here cannot desync the run, it is just ignored.\n"
    "#\n"
    "# Source: {audio}\n"
    "# Language: {language}   Chunks: {n}   Source duration: {dur:.1f}s\n"
    "# Rate used: {rate:.1f} chars/sec   Stretch ceiling: {ceil:.2f}x\n"
    "#\n"
    "# [idx] [start] [end] [duration] [pause after] [verdict] [estimate] "
    "[atempo]\n"
)

_PLAN_ROW_RE = re.compile(
    r"^\[(\d+)\]\s*\[(\d+)ms\]\s*\[(\d+)ms\]\s*\[(\d+)ms\]\s*\[(\d+)ms\]"
    r"\s*\[([a-z]+)\]\s*\[(\d+)ms\]\s*\[([\d.]+)\]\s*$")


def chars_per_sec(language: str) -> float:
    """The speaking rate estimate_fit will use for *language*."""
    return LANG_CHARS_PER_SEC.get(language, DEFAULT_CHARS_PER_SEC)


def pause_chunks_from_regions(regions: Sequence[Tuple[float, float]],
                              total_dur_s: float,
                              pause_min_s: float = PAUSE_MIN_S) -> List[Dict]:
    """Speech regions -> pause-delimited chunks, each with the pause after it.

    *regions* is what _detect_regions_from_audio returns: (start_s, end_s)
    SPEECH spans, ascending. Consecutive regions separated by less than
    *pause_min_s* are merged into one chunk — that gap is a breath, not a
    boundary a dub should be cut at.

    Returns one dict per chunk:
        index          1-based
        start_s/end_s  span of the source speech
        dur_s          end_s - start_s
        pause_after_s  silence until the next chunk starts (the trailing
                       chunk measures to total_dur_s, so a long tail of
                       room tone is visible in the preview instead of
                       silently becoming unlimited headroom)
    """
    spans: List[List[float]] = []
    for (a, b) in regions:
        a, b = float(a), float(b)
        if b <= a:
            continue
        if spans and (a - spans[-1][1]) < pause_min_s:
            spans[-1][1] = b
        else:
            spans.append([a, b])

    chunks: List[Dict] = []
    for i, (a, b) in enumerate(spans):
        nxt = spans[i + 1][0] if i + 1 < len(spans) else max(total_dur_s, b)
        chunks.append({
            "index": i + 1,
            "start_s": a,
            "end_s": b,
            "dur_s": b - a,
            "pause_after_s": max(0.0, nxt - b),
        })
    return chunks


def source_text_for_chunks(chunks: Sequence[Dict],
                           words: Sequence[Dict]) -> List[str]:
    """Scribe word tokens bucketed into chunks -> the source line per chunk.

    Same bucketing rule as srt_tools._build_subtitle_srt: a word belongs to
    the first chunk whose end it does not pass. Non-word tokens (spacing,
    audio events) are skipped, as everywhere else in the pipeline.
    """
    out = ["" for _ in chunks]
    if not chunks:
        return out
    wi, n = 0, len(words)
    for ci, ch in enumerate(chunks):
        last = (ci == len(chunks) - 1)
        bucket = []
        while wi < n:
            w = words[wi]
            if w.get("type", "word") != "word":
                wi += 1
                continue
            try:
                w_start = float(w.get("start", 0.0))
            except (TypeError, ValueError):
                wi += 1
                continue
            if not last and w_start > ch["end_s"]:
                break
            bucket.append((w.get("text", "") or "").strip())
            wi += 1
        out[ci] = " ".join(t for t in bucket if t)
    return out


def assign_script_to_chunks(script_text: str,
                            chunks: Sequence[Dict],
                            language: str = "",
                            split_sentences=None) -> List[str]:
    """Split the pasted target script across *chunks* by duration share.

    The pasted script is in the TARGET language and the transcript is in the
    source language, so there is nothing to align on textually. What we do
    have is each chunk's share of the total speech time — so a chunk that
    holds 12% of the talking gets ~12% of the characters.

    Sentences are never split (tts._split_script_into_sentences is
    danda-aware and keeps ElevenLabs [tags] attached). Each sentence is
    mapped to the chunk containing its character MIDPOINT under that
    proportional mapping — midpoint rather than greedy accumulation so a
    script with fewer sentences than chunks spreads out instead of piling
    into the first few and leaving the tail silent.

    Always returns exactly len(chunks) strings. This is a starting point,
    not an answer: the plan file exists so a wrong assignment can be moved
    by hand and re-previewed for free.
    """
    out = ["" for _ in chunks]
    text = (script_text or "").strip()
    if not text or not chunks:
        return out

    if split_sentences is None:
        from .tts import _split_script_into_sentences as split_sentences
    sentences = [s for s in (split_sentences(text) or []) if s.strip()]
    if not sentences:
        return out

    total_dur = sum(max(0.0, c["dur_s"]) for c in chunks)
    if total_dur <= 0:
        # Degenerate (all chunks zero-length) — fall back to even spread.
        for i, s in enumerate(sentences):
            ci = min(len(chunks) - 1, i * len(chunks) // len(sentences))
            out[ci] = (out[ci] + " " + s).strip()
        return out

    # Chunk c owns the character interval [lo, hi) of the whole script.
    bounds, acc = [], 0.0
    for c in chunks:
        lo = acc / total_dur
        acc += max(0.0, c["dur_s"])
        bounds.append((lo, acc / total_dur))

    lengths = [len(s) for s in sentences]
    total_chars = sum(lengths) or 1
    pos = 0
    for s, ln in zip(sentences, lengths):
        mid = (pos + ln / 2.0) / total_chars
        pos += ln
        ci = len(chunks) - 1
        for i, (lo, hi) in enumerate(bounds):
            if lo <= mid < hi:
                ci = i
                break
        out[ci] = (out[ci] + " " + s).strip()
    return out


def estimate_fit(target_text: str, chunk: Dict, language: str = "",
                 max_atempo: float = MAX_ATEMPO,
                 rate_override: float = 0.0) -> Dict:
    """Estimated spoken duration + fit verdict for one chunk. No API calls.

    Returns the keys the plan file and the HTML preview both consume:
        est_s     estimated spoken duration of *target_text*
        verdict   one of VERDICTS
        atempo    speed-up the paid run would apply (1.0 = none), clamped
                  to *max_atempo*
        over_s    seconds by which est_s exceeds the hard slot (0 if it fits)
    """
    speech_slot = max(0.0, float(chunk.get("dur_s", 0.0)))
    hard_slot = speech_slot + max(0.0, float(chunk.get("pause_after_s", 0.0)))

    text = (target_text or "").strip()
    if not text:
        return {"est_s": 0.0, "verdict": "empty", "atempo": 1.0, "over_s": 0.0}

    if rate_override and rate_override > 0:
        clean = re.sub(r"\[.*?\]", "", text).strip()
        est_s = len(clean) / float(rate_override)
    else:
        est_s = estimate_duration(text, language)

    if est_s > hard_slot and hard_slot > 0:
        verdict = "over"
    elif est_s > speech_slot:
        verdict = "tight"
    elif speech_slot > 0 and est_s < speech_slot * SHORT_RATIO:
        verdict = "short"
    else:
        verdict = "fits"

    atempo, over_s = 1.0, 0.0
    if verdict == "over":
        over_s = est_s - hard_slot
        atempo = min(est_s / hard_slot, float(max_atempo))
    return {"est_s": est_s, "verdict": verdict, "atempo": atempo,
            "over_s": over_s}


def build_plan(chunks: Sequence[Dict], en_texts: Sequence[str],
               tr_texts: Sequence[str], language: str = "",
               max_atempo: float = MAX_ATEMPO,
               rate_override: float = 0.0) -> List[Dict]:
    """Merge chunks + both text sides + the fit analysis into plan rows."""
    plan = []
    for i, ch in enumerate(chunks):
        en = en_texts[i] if i < len(en_texts) else ""
        tr = tr_texts[i] if i < len(tr_texts) else ""
        row = dict(ch)
        row["en"] = " ".join((en or "").split())
        row["tr"] = " ".join((tr or "").split())
        row.update(estimate_fit(row["tr"], ch, language, max_atempo,
                                rate_override))
        plan.append(row)
    return plan


def plan_counts(plan: Sequence[Dict]) -> Dict[str, int]:
    """Verdict histogram — the one-line summary the panel and HTML show."""
    counts = {v: 0 for v in VERDICTS}
    for row in plan:
        counts[row.get("verdict", "empty")] = \
            counts.get(row.get("verdict", "empty"), 0) + 1
    return counts


# ─── Plan file (the editable artifact) ───────────────────────────────────────
# Deliberately line-oriented, not JSON: the panel's Lua reader is flat-scalar
# only (json_field) and its array reader drops numeric fields, so a nested
# JSON plan would arrive half-parsed. This parses with one string.match on
# the Lua side, exactly like the existing timestamps sidecar.

def format_plan_text(plan: Sequence[Dict], audio_path: str = "",
                     language: str = "", total_dur_s: float = 0.0,
                     max_atempo: float = MAX_ATEMPO,
                     rate_override: float = 0.0) -> str:
    rate = rate_override if rate_override else chars_per_sec(language)
    lines = [PLAN_HEADER.format(
        ver=PLAN_FORMAT_VERSION, audio=os.path.basename(audio_path or ""),
        language=language or "?", n=len(plan), dur=total_dur_s,
        rate=rate, ceil=max_atempo)]
    for row in plan:
        lines.append(
            "[{i}] [{a}ms] [{b}ms] [{d}ms] [{p}ms] [{v}] [{e}ms] [{t:.2f}]"
            .format(i=row["index"],
                    a=int(round(row["start_s"] * 1000)),
                    b=int(round(row["end_s"] * 1000)),
                    d=int(round(row["dur_s"] * 1000)),
                    p=int(round(row["pause_after_s"] * 1000)),
                    v=row.get("verdict", "empty"),
                    e=int(round(row.get("est_s", 0.0) * 1000)),
                    t=row.get("atempo", 1.0)))
        lines.append("EN: " + (row.get("en", "") or ""))
        lines.append("TR: " + (row.get("tr", "") or ""))
        lines.append("")
    return "\n".join(lines)


def parse_plan_text(text: str) -> List[str]:
    """Read the TR: lines back, in index order. Timings are ignored.

    Returns a list positionally indexed by chunk (index 1 -> element 0), so
    a plan whose rows were reordered or renumbered by hand still lands each
    line on the chunk it names. A TR: line may be wrapped across several
    lines; continuation lines are joined with a space.
    """
    rows: Dict[int, List[str]] = {}
    cur, in_tr = None, False
    for raw in (text or "").splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        m = _PLAN_ROW_RE.match(stripped)
        if m:
            cur, in_tr = int(m.group(1)), False
            rows.setdefault(cur, [])
            continue
        if stripped.startswith("#"):
            in_tr = False
            continue
        if stripped.startswith("EN:"):
            in_tr = False
            continue
        if stripped.startswith("TR:"):
            in_tr = True
            if cur is not None:
                rows.setdefault(cur, []).append(stripped[3:].strip())
            continue
        if in_tr:
            if not stripped:
                in_tr = False
                continue
            if cur is not None:
                rows.setdefault(cur, []).append(stripped)
    if not rows:
        return []
    out = ["" for _ in range(max(rows))]
    for idx, parts in rows.items():
        if 1 <= idx <= len(out):
            out[idx - 1] = " ".join(p for p in parts if p).strip()
    return out


def summarize_plan(plan: Sequence[Dict]) -> str:
    """One log line describing the whole plan — worst offender named."""
    counts = plan_counts(plan)
    worst = None
    for row in plan:
        if row.get("verdict") == "over" and (
                worst is None or row["over_s"] > worst["over_s"]):
            worst = row
    parts = [f"{len(plan)} chunk(s)",
             f"{counts.get('fits', 0)} fit",
             f"{counts.get('tight', 0)} tight",
             f"{counts.get('over', 0)} over",
             f"{counts.get('short', 0)} short"]
    if counts.get("empty"):
        parts.append(f"{counts['empty']} with no text")
    line = ", ".join(parts)
    if worst is not None:
        line += (f" — worst: chunk {worst['index']} overruns by "
                 f"{worst['over_s']:.1f}s (needs {worst['atempo']:.2f}x)")
    return line
