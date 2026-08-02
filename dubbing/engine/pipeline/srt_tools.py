"""
SRT builders, SpaCy meaningful-chunk splitting, LLM input formats,
timestamps txt read/write, audio loading and waveform region detection.

Extracted from Translation_and_Syncing_App.py (bulk app, v1.8.0):
    lines 140-142   SpaCy lazy-load globals
    lines 1335-2010 "Shared helpers — SRT / region detection"

Adaptations (everything else is verbatim):
  * The optional pyphen import guard moved here from the app's module top
    (lines 134-138); pydub comes via pipeline.config so all modules share
    one guard.
  * _resample_np (app lines 1948-1956) skipped — it fed the Tk playback
    mixer only.
"""

import os
import re
from typing import List, Optional, Set

import numpy as np
import librosa

from .config import (PYDUB_AVAILABLE, TTS_DEFAULT_LANGUAGE, TTS_LANGUAGES,
                     _AudioSegment)

try:
    import pyphen as _pyphen_module
    PYPHEN_AVAILABLE = True
except ImportError:
    PYPHEN_AVAILABLE = False

# Optional SpaCy for English meaningful-chunk SRT splitting
_SPACY_NLP = None
_SPACY_TRIED = False


def _srt_ts(seconds: float) -> str:
    h  = int(seconds // 3600)
    m  = int((seconds % 3600) // 60)
    s  = int(seconds % 60)
    ms = int(round((seconds - int(seconds)) * 1000))
    if ms >= 1000:
        ms = 999
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def _build_subtitle_srt(regions, words) -> str:
    if not regions:
        return ""
    word_list  = [w for w in words if w.get("type", "word") == "word"]
    buckets    = [[] for _ in regions]
    word_idx   = 0
    region_idx = 0
    while word_idx < len(word_list) and region_idx < len(regions):
        w          = word_list[word_idx]
        word_start = w.get("start", 0.0)
        reg_end    = regions[region_idx][1]
        if word_start <= reg_end:
            buckets[region_idx].append(w.get("text", "").strip())
            word_idx += 1
        else:
            region_idx += 1
    while word_idx < len(word_list):
        buckets[-1].append(word_list[word_idx].get("text", "").strip())
        word_idx += 1
    lines = []
    idx   = 1
    for (rs, re_end), bucket in zip(regions, buckets):
        text = " ".join(t for t in bucket if t)
        if not text:
            # Region had no words assigned — skip rather than emitting a blank
            # subtitle entry that can confuse downstream SRT parsers.
            continue
        lines += [str(idx), f"{_srt_ts(rs)} --> {_srt_ts(re_end)}", text, ""]
        idx += 1
    return "\n".join(lines)


def _build_target_subtitle_srt(regions: list, words: list) -> str:
    """
    Build a target-language TTS SRT from (regions, words).

    ElevenLabs Scribe often returns all word timestamps as 0.0 when the
    source audio is TTS-generated (very uniform amplitude / pitch).  When
    that happens the normal timestamp-bucketing approach puts every word into
    the very first region, producing gibberish subtitles.

    Strategy
    --------
    1. Filter to actual word tokens (non-empty text, type == "word").
    2. Reliability check: if ≥ half the words have start > 0.05 s → the
       timestamps are good → fall back to the standard bucketing used by
       _build_subtitle_srt.
    3. Otherwise distribute words proportionally across regions weighted by
       each region's duration (same approach as Step-1 English SRT that is
       used for translation — no SpaCy, just regions → pour words in).
    """
    if not regions:
        return ""

    word_list = [
        w for w in words
        if w.get("type", "word") == "word" and w.get("text", "").strip()
    ]
    if not word_list:
        return ""

    # ── Reliability check ────────────────────────────────────────────────────
    nonzero = sum(1 for w in word_list if w.get("start", 0.0) > 0.05)
    timestamps_reliable = nonzero >= len(word_list) / 2

    if timestamps_reliable:
        # Use exact timestamp bucketing (same as _build_subtitle_srt)
        buckets    = [[] for _ in regions]
        word_idx   = 0
        region_idx = 0
        while word_idx < len(word_list) and region_idx < len(regions):
            w          = word_list[word_idx]
            word_start = w.get("start", 0.0)
            reg_end    = regions[region_idx][1]
            if word_start <= reg_end:
                buckets[region_idx].append(w.get("text", "").strip())
                word_idx += 1
            else:
                region_idx += 1
        while word_idx < len(word_list):
            buckets[-1].append(word_list[word_idx].get("text", "").strip())
            word_idx += 1
    else:
        # Proportional distribution by region duration
        total_dur = sum(re_end - rs for rs, re_end in regions)
        if total_dur <= 0:
            # Edge case: zero-length regions — spread words evenly
            n_reg = len(regions)
            per_reg = max(1, len(word_list) // n_reg)
            buckets = []
            for i, _ in enumerate(regions):
                start_i = i * per_reg
                end_i   = start_i + per_reg if i < n_reg - 1 else len(word_list)
                buckets.append([w.get("text", "").strip()
                                 for w in word_list[start_i:end_i]])
        else:
            # Calculate how many words each region should receive,
            # weighted by its fraction of the total audio duration.
            n_words  = len(word_list)
            counts   = []
            assigned = 0
            for i, (rs, re_end) in enumerate(regions):
                if i < len(regions) - 1:
                    c = max(1, round(n_words * (re_end - rs) / total_dur))
                    c = min(c, n_words - assigned - (len(regions) - 1 - i))
                    c = max(c, 1)
                else:
                    c = n_words - assigned   # last region gets the remainder
                counts.append(c)
                assigned += c

            buckets = []
            wi = 0
            for c in counts:
                buckets.append([w.get("text", "").strip()
                                 for w in word_list[wi: wi + c]])
                wi += c

    # ── Build SRT lines ──────────────────────────────────────────────────────
    lines = []
    idx   = 1
    for (rs, re_end), bucket in zip(regions, buckets):
        text = " ".join(t for t in bucket if t)
        if not text:
            continue
        lines += [str(idx), f"{_srt_ts(rs)} --> {_srt_ts(re_end)}", text, ""]
        idx += 1
    return "\n".join(lines)


# Backwards-compat alias for older callers/scripts.
_build_bn_subtitle_srt = _build_target_subtitle_srt


def _extract_translation_from_finalscript(combined: str,
                                          language: str = TTS_DEFAULT_LANGUAGE) -> str:
    """
    Pull the translation text out of a FinalScript file. Accepts the
    current "=== <LANGUAGE> TRANSLATION ===" marker plus legacy markers
    ("BENGALI" / "TELUGU") so older FinalScript files keep working.
    """
    markers = [f"=== {language.upper()} TRANSLATION ==="]
    for lang_name in TTS_LANGUAGES:
        m = f"=== {lang_name.upper()} TRANSLATION ==="
        if m not in markers:
            markers.append(m)
    markers.append("=== TELUGU TRANSLATION ===")  # legacy
    for marker in markers:
        if marker in combined:
            return combined.split(marker, 1)[1].strip()
    return combined.strip()


def _load_spacy_model():
    """Load and cache a SpaCy English model.  Returns None if unavailable."""
    global _SPACY_NLP, _SPACY_TRIED
    if _SPACY_TRIED:
        return _SPACY_NLP
    _SPACY_TRIED = True
    try:
        import spacy  # noqa: F401
        for name in ("en_core_web_sm", "en_core_web_md", "en_core_web_lg"):
            try:
                _SPACY_NLP = spacy.load(name)
                return _SPACY_NLP
            except OSError:
                continue
        _SPACY_NLP = None
    except ImportError:
        _SPACY_NLP = None
    return _SPACY_NLP


def _get_spacy_chunk_boundaries(word_texts: List[str]) -> List[int]:
    """
    Given a list of plain word strings, return a sorted list of word indices
    at which new subtitle chunks should begin.  The first entry is always 0.

    Split criteria (SpaCy dependency parse):
      • Sentence boundaries
      • Coordinating conjunction (dep_==cc) whose head is a VERB / AUX / ROOT
        → the conjunction starts a new clause, not just a noun phrase
      • Subordinating conjunction (SCONJ) or adverbial/relative clause token
        (dep_ in advcl / relcl / acl) that immediately follows a comma

    Constraints:
      • MIN_WORDS_TO_SPLIT  — text shorter than this is never split
      • MIN_CHUNK_WORDS     — resulting chunks shorter than this are merged
        back into the preceding chunk

    Falls back to [0] (= no split) when SpaCy is unavailable.
    """
    MIN_WORDS_TO_SPLIT = 6
    MIN_CHUNK_WORDS    = 3

    if len(word_texts) < MIN_WORDS_TO_SPLIT:
        return [0]

    nlp = _load_spacy_model()
    if nlp is None:
        return [0]

    full_text = " ".join(word_texts)

    # Build char-offset → word-index table
    char_starts: List[int] = []
    pos = 0
    for wt in word_texts:
        char_starts.append(pos)
        pos += len(wt) + 1          # +1 for the space separator

    def _char_to_word(char_off: int) -> int:
        """Return the word index whose span contains char_off."""
        for i in range(len(char_starts) - 1, -1, -1):
            if char_off >= char_starts[i]:
                return i
        return 0

    doc    = nlp(full_text)
    tokens = list(doc)

    # SpaCy 3.x-safe sentence boundary detection: use doc.sents rather than
    # tok.is_sent_start, which can return None (not just False) when the model
    # hasn't explicitly assigned a boundary, causing silent misses.
    sent_starts: Set[int] = {sent.start for sent in doc.sents}

    split_tok_set: Set[int] = {0}

    for i, tok in enumerate(tokens):
        if i == 0:
            continue

        # 1. SpaCy sentence boundary
        if i in sent_starts:
            split_tok_set.add(i)
            continue

        # 2. Coordinating conjunction joining clauses (not bare NP coordination)
        if tok.dep_ == "cc":
            head = tok.head
            if head.pos_ in ("VERB", "AUX") or head.dep_ == "ROOT":
                split_tok_set.add(i)
            continue

        # 3. Clause token that immediately follows a comma
        if i > 0 and tokens[i - 1].text == ",":
            if tok.pos_ == "SCONJ" or tok.dep_ in ("advcl", "relcl", "acl"):
                split_tok_set.add(i)

    # Map token-level split positions → word-level split positions
    split_word_set: Set[int] = set()
    for tok_i in split_tok_set:
        split_word_set.add(_char_to_word(tokens[tok_i].idx))
    split_word_set.add(0)

    # Enforce minimum chunk size: merge tiny chunks into the previous one
    sorted_splits = sorted(split_word_set)
    n_words       = len(word_texts)
    merged: List[int] = []
    for sp in sorted_splits:
        next_sp   = next((s for s in sorted_splits if s > sp), n_words)
        chunk_len = next_sp - sp
        if chunk_len < MIN_CHUNK_WORDS and merged:
            continue            # too short → discard this split boundary
        merged.append(sp)

    # If the last chunk ended up too short, drop its boundary
    while len(merged) > 1:
        last_start = merged[-1]
        if (n_words - last_start) < MIN_CHUNK_WORDS:
            merged.pop()
        else:
            break

    return merged if merged else [0]


def _split_words_into_chunks(word_objs: List[dict]) -> List[List[dict]]:
    """
    Split a list of ElevenLabs word objects into subtitle-sized chunks.

    Each chunk is a contiguous sub-list of word_objs.
    Returns [word_objs] unchanged when SpaCy is unavailable or the region
    is too short to warrant splitting.
    """
    if not word_objs:
        return []

    # Strip empty-text entries before building the SpaCy input.  Empty strings
    # (punctuation artefacts, spacing tokens) create phantom words that shift
    # every character offset in the mapping table and cause split boundaries to
    # land on the wrong word index.
    word_objs = [w for w in word_objs if w.get("text", "").strip()]
    if not word_objs:
        return []

    texts      = [w.get("text", "").strip() for w in word_objs]
    boundaries = _get_spacy_chunk_boundaries(texts)

    if len(boundaries) <= 1:
        return [word_objs]

    n      = len(word_objs)
    chunks = []
    for k, start in enumerate(boundaries):
        end   = boundaries[k + 1] if k + 1 < len(boundaries) else n
        chunk = word_objs[start:end]
        if chunk:
            chunks.append(chunk)

    return chunks if chunks else [word_objs]


def _build_english_subtitle_srt(regions, words) -> str:
    """
    Build the English SRT with intra-segment meaningful-chunk splitting.

    For each waveform region the function:
      1. Collects the ElevenLabs word objects that fall inside that region
         (same bucketing logic as _build_subtitle_srt).
      2. Uses SpaCy to split the region's words into meaningful sub-chunks
         at clause / phrase / grammatical boundaries.
      3. Assigns timestamps per chunk:
           • First chunk   → start = segment start  (always)
           • Middle chunks → start/end = actual word-level timestamps
           • Last chunk    → end = last-word-end  if  last-word-end < seg-end,
                                   seg-end         otherwise
    """
    if not regions:
        return ""

    word_list = [w for w in words if w.get("type", "word") == "word"]

    # ── bucket words into regions (identical to original logic) ─────────────
    buckets: List[List[dict]] = [[] for _ in regions]
    word_idx   = 0
    region_idx = 0

    while word_idx < len(word_list) and region_idx < len(regions):
        w          = word_list[word_idx]
        word_start = w.get("start", 0.0)
        reg_end    = regions[region_idx][1]
        if word_start <= reg_end:
            buckets[region_idx].append(w)
            word_idx += 1
        else:
            region_idx += 1

    while word_idx < len(word_list):
        buckets[-1].append(word_list[word_idx])
        word_idx += 1

    # ── build SRT lines ──────────────────────────────────────────────────────
    sub_counter = 1
    lines: List[str] = []

    for (reg_start, reg_end), bucket in zip(regions, buckets):
        if not bucket:
            # Empty region → keep a placeholder subtitle
            lines += [str(sub_counter),
                      f"{_srt_ts(reg_start)} --> {_srt_ts(reg_end)}", "", ""]
            sub_counter += 1
            continue

        chunks   = _split_words_into_chunks(bucket)
        n_chunks = len(chunks)

        for c_idx, chunk_words in enumerate(chunks):
            is_first = (c_idx == 0)
            is_last  = (c_idx == n_chunks - 1)

            text = " ".join(
                w.get("text", "").strip()
                for w in chunk_words
                if w.get("text", "").strip()
            )

            # ── start time ───────────────────────────────────────────────────
            if is_first:
                t_start = reg_start
            else:
                t_start = chunk_words[0].get("start", reg_start)

            # ── end time ─────────────────────────────────────────────────────
            if is_last:
                last_word_end = chunk_words[-1].get("end", reg_end)
                # Use the earlier of (last-word-end, segment-end)
                t_end = last_word_end if last_word_end < reg_end else reg_end
            else:
                # End at the actual end timestamp of the last word in this chunk
                last_w = chunk_words[-1]
                t_end  = last_w.get("end",
                         last_w.get("start", t_start) + 1.0)

            lines += [str(sub_counter),
                      f"{_srt_ts(t_start)} --> {_srt_ts(t_end)}",
                      text, ""]
            sub_counter += 1

    return "\n".join(lines)


def _parse_srt_to_duration_format(final_srt: str) -> str:
    """
    Convert an SRT string into the duration-annotated format sent to Gemini.

    Each output line looks like:
        [4.139s] A little pause... and we are back. [-0.033s]

    Prefix [Xs]  — how long this subtitle is displayed on screen (seconds).
    Suffix [Xs]  — gap between the END of this subtitle and the START of the
                   next one.  Zero or negative means no gap: the next subtitle
                   starts immediately (or even overlaps slightly).

    A legend explaining these conventions is prepended so the model can use
    the timing information when deciding translation length and phrasing.
    """
    if not final_srt:
        return ""
    pattern = re.compile(
        r'\d+\n(\d{2}:\d{2}:\d{2},\d{3}) --> (\d{2}:\d{2}:\d{2},\d{3})\n([\s\S]*?)(?=\n\n|\n$|$)',
        re.MULTILINE)
    matches = list(pattern.finditer(final_srt))

    def toSec(ts):
        h, m, s_ms = ts.split(':')
        s, ms = s_ms.split(',')
        return int(h)*3600 + int(m)*60 + int(s) + int(ms)/1000

    lines = []
    for i, m in enumerate(matches):
        start    = toSec(m.group(1))
        end      = toSec(m.group(2))
        duration = end - start
        gap      = toSec(matches[i+1].group(1)) - end if i < len(matches)-1 else 0.0
        cleanText = m.group(3).replace('\n', ' ').strip()
        lines.append(f"[{duration:.3f}s] {cleanText} [{gap:.3f}s]")

    legend = (
        "=== FORMAT LEGEND ===\n"
        "Each subtitle line is written as:\n"
        "    [DURATION] subtitle text [GAP]\n"
        "\n"
        "  • DURATION (prefix, e.g. [4.139s]) — how long this subtitle is\n"
        "    displayed on screen.  Use this to judge how long the translated\n"
        "    audio should be: a short duration means a short, punchy translation.\n"
        "\n"
        "  • GAP (suffix, e.g. [0.033s] or [-0.033s]) — the silence between\n"
        "    the end of this subtitle and the start of the next one.\n"
        "    Zero or negative gap means there is NO pause — the next subtitle\n"
        "    starts immediately (or slightly overlaps).  A positive gap means\n"
        "    there is a natural breath / pause between the two lines.\n"
        "=== END LEGEND ===\n"
    )
    return legend + "\n" + "\n".join(lines)


def _parse_srt_to_analysis_format(final_srt: str) -> str:
    """
    Convert an SRT string into the detailed analysis format (mirrors Format_srt_V2.py).

    Outputs a header row followed by one data line per segment:
        [Segment duration][Gap after segment][Gap %][Total available] [Syllables] [Syl/s] [Rel syl/s] [Words] text

    Uses pyphen for syllable counting when available; falls back to a vowel-group
    estimate otherwise.
    """
    if not final_srt:
        return ""

    # ── Parse SRT ─────────────────────────────────────────────────────────────
    def _to_sec(ts):
        h, m, s_ms = ts.split(':')
        s, ms = s_ms.split(',')
        return int(h)*3600 + int(m)*60 + int(s) + int(ms)/1000

    pattern = re.compile(
        r'\d+\n(\d{2}:\d{2}:\d{2},\d{3}) --> (\d{2}:\d{2}:\d{2},\d{3})\n([\s\S]*?)(?=\n\n|\n$|$)',
        re.MULTILINE)
    matches = list(pattern.finditer(final_srt))
    if not matches:
        return ""

    segments = []
    for m in matches:
        start = _to_sec(m.group(1))
        end   = _to_sec(m.group(2))
        text  = m.group(3).replace('\n', ' ').strip()
        segments.append({'start': start, 'end': end, 'text': text})

    # ── Syllable counting ─────────────────────────────────────────────────────
    if PYPHEN_AVAILABLE:
        dic = _pyphen_module.Pyphen(lang='en')
        def _count_syllables(text):
            words = re.findall(r'\b[a-zA-Z]+\b', text)
            count = 0
            for w in words:
                count += len(dic.inserted(w).split('-'))
            return count
    else:
        def _count_syllables(text):
            # Rough fallback: count vowel groups
            return max(1, len(re.findall(r'[aeiouAEIOU]+', text)))

    # ── Pass 1: base calculations & average syllables/sec ─────────────────────
    total_syl_per_sec = 0.0
    valid_count = 0

    for seg in segments:
        seg['duration']    = max(seg['end'] - seg['start'], 0.001)
        seg['words']       = len(re.findall(r'\b\w+\b', seg['text']))
        seg['syllables']   = _count_syllables(seg['text'])
        seg['syl_per_sec'] = seg['syllables'] / seg['duration']
        if seg['words'] > 0:
            total_syl_per_sec += seg['syl_per_sec']
            valid_count += 1

    avg_syl_per_sec = total_syl_per_sec / valid_count if valid_count > 0 else 1.0
    if avg_syl_per_sec == 0:
        avg_syl_per_sec = 1.0

    # ── Pass 2: gaps, relative values & format output ─────────────────────────
    header = (
        "[Segment duration][Gap after segment][Gap after segment in percentage wrt segment length]"
        "[Total duration available for dubbing segment] [Number of syllables in the segment] "
        "[Number of syllables per second] [Relative number of syllables per second] "
        "[Number of words] Actual text of segment"
    )
    output_lines = [header]

    for i, seg in enumerate(segments):
        gap             = segments[i+1]['start'] - seg['end'] if i < len(segments)-1 else 0.0
        seg['gap']      = gap
        seg['gap_pct']  = (gap / seg['duration']) * 100
        seg['total_avail']     = seg['duration'] + gap
        seg['rel_syl_per_sec'] = seg['syl_per_sec'] / avg_syl_per_sec

        line = (
            f"[{seg['duration']:.2f}s]"
            f"[{seg['gap']:.2f}s]"
            f"[{seg['gap_pct']:.0f}%]"
            f"[{seg['total_avail']:.2f}s] "
            f"[{seg['syllables']}] "
            f"[{seg['syl_per_sec']:.2f}] "
            f"[{seg['rel_syl_per_sec']:.2f}] "
            f"[{seg['words']}] "
            f"{seg['text']}"
        )
        output_lines.append(line)

    return '\n'.join(output_lines)


def _format_timestamps_as_text(timestamps: list) -> str:
    """
    Format a list of sync timestamp dicts as a human-readable text file.

    Each entry comes from sync._build_timestamps() and contains:
        index, orig_start_ms, orig_end_ms, synced_start_ms
    Match-mode entries (contract v0.7) additionally carry a "sync_status"
    of "synced" or "unsync"; when present it is written as a 6th bracket.
    Files without the 6th field keep the exact pre-v0.7 format, and readers
    treat a missing status as "synced".
    """
    with_status = any(e.get("sync_status") for e in timestamps)
    header = "[Index] [Orig Start] [Orig End] [Orig Duration] [Synced Start]"
    if with_status:
        header += " [Status]"
    lines = [header]
    for entry in timestamps:
        orig_dur = entry['orig_end_ms'] - entry['orig_start_ms']
        line = (
            f"[{entry['index']}] "
            f"[{entry['orig_start_ms']}ms] "
            f"[{entry['orig_end_ms']}ms] "
            f"[{orig_dur}ms] "
            f"[{entry['synced_start_ms']}ms]"
        )
        if with_status:
            line += f" [{entry.get('sync_status') or 'synced'}]"
        lines.append(line)
    return '\n'.join(lines)


def _parse_timestamps_text(path: str) -> list:
    """Inverse of _format_timestamps_as_text — read a *_sync_timestamps.txt
    file back into the list-of-dicts shape sync_audio_with_timestamps()
    expects. Returns [] when the file is missing or unparsable. A v0.7
    trailing [synced]/[unsync] bracket is returned as "sync_status"
    (absent field → "synced")."""
    entries = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\[(\d+)\]\s+\[(\d+)ms\]\s+\[(\d+)ms\]\s+"
                             r"\[\d+ms\]\s+\[(\d+)ms\]"
                             r"(?:\s+\[(synced|unsync)\])?", line.strip())
                if m:
                    entries.append({
                        "index":           int(m.group(1)),
                        "orig_start_ms":   int(m.group(2)),
                        "orig_end_ms":     int(m.group(3)),
                        "synced_start_ms": int(m.group(4)),
                        "sync_status":     m.group(5) or "synced",
                    })
    except Exception:
        return []
    return entries


_VIDEO_EXTS = (".mp4", ".mov", ".mkv", ".avi", ".webm", ".m4v", ".mpg", ".mpeg")


def _load_audio_any(path: str):
    """Load mono float32 audio from an audio OR video file → (y, sr).
    librosa handles audio; video containers go through pydub/ffmpeg."""
    ext = os.path.splitext(path)[1].lower()
    if ext not in _VIDEO_EXTS:
        try:
            y, sr = librosa.load(path, sr=None, mono=True)
            return y.astype(np.float32), int(sr)
        except Exception:
            pass                      # fall through to pydub
    if not PYDUB_AVAILABLE:
        raise ValueError(
            f"Cannot decode {os.path.basename(path)} — pydub/ffmpeg needed "
            "for video files.")
    seg = _AudioSegment.from_file(path)
    seg = seg.set_channels(1)
    sr = seg.frame_rate
    y = np.array(seg.get_array_of_samples(), dtype=np.float32)
    peak = float(1 << (8 * seg.sample_width - 1))
    return (y / peak).astype(np.float32), int(sr)


def _detect_regions_from_audio(y, sr, threshold_db=-42.0, hysteresis_db=6.0, min_sil_ms=150):
    hop   = max(1, int(sr * 0.010))
    win   = hop * 2
    n_fr  = len(y) // hop
    frames = np.array([
        np.sqrt(np.mean(y[i*hop: i*hop+win]**2)) for i in range(n_fr)
    ], dtype=np.float32)
    thr_open  = 10 ** (threshold_db / 20.0)
    thr_close = 10 ** ((threshold_db - abs(hysteresis_db)) / 20.0)
    min_sil_f = max(1, int((min_sil_ms/1000.0) * sr / hop))
    active, raw, seg_start = False, [], 0
    for i, rms in enumerate(frames):
        if not active:
            if rms >= thr_open:
                active, seg_start = True, i
        else:
            if rms < thr_close:
                active = False
                raw.append([seg_start, i])
    if active:
        raw.append([seg_start, n_fr-1])
    merged = []
    for seg in raw:
        if merged and (seg[0] - merged[-1][1]) < min_sil_f:
            merged[-1][1] = seg[1]
        else:
            merged.append(seg[:])
    hop_s = hop / sr
    return [(r[0]*hop_s, r[1]*hop_s) for r in merged]
