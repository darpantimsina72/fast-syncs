"""
Sync engine: SRT/mapping parsers, the 5-round spring placement algorithm
with bleed-over and the order-preserving sweep, caption re-chunking,
timestamp building and synced-audio reassembly.

Extracted from Translation_and_Syncing_App.py (bulk app, v1.8.0):
    lines 3207-3823 "Sync algorithm helpers (from Audio_File_Sync_New.py)"

Adaptations (everything else is verbatim):
  * TTS_LANGUAGES and the shared pydub guard come from pipeline.config.
"""

import os
import re
from copy import deepcopy
from typing import Dict, List, Set

from .config import PYDUB_AVAILABLE, TTS_LANGUAGES, _AudioSegment


def _sync_srt_ts(ms: float) -> str:
    ms = max(0, int(round(ms)))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02}:{m:02}:{s:02},{ms:03}"


def _parse_srt_time(t: str) -> float:
    t = t.strip().replace(",", ".")
    hms, ms_part = t.split(".")
    h, m, s = hms.split(":")
    return (int(h)*3600 + int(m)*60 + int(s)) * 1000 + int(ms_part)


class Subtitle:
    def __init__(self, index, start, end, text):
        self.index = index
        self.start = start
        self._dur  = end - start
        self.text  = text

    @property
    def length(self): return self._dur
    @property
    def end(self): return self.start + self._dur
    def shift(self, delta): self.start += delta


class MappingGroup:
    def __init__(self, no, en, te):
        self.no = no
        self.en = en
        self.te = te

    @property
    def mtype(self):
        e, t = len(self.en), len(self.te)
        if e == 1 and t == 1: return "1to1"
        if t == 1 and e >  1: return "Mto1"
        if e == 1 and t >  1: return "1toM"
        return "MtoM"


class Section:
    def __init__(self, no, start, end, gap_before=0.0, gap_after=0.0):
        self.no = no; self.start = start; self.end = end
        self.gap_before = gap_before; self.gap_after = gap_after

    @property
    def length(self):         return self.end - self.start
    @property
    def len_gap_after(self):  return self.length + self.gap_after
    @property
    def len_gap_before(self): return self.length + self.gap_before
    @property
    def len_both_gaps(self):  return self.gap_before + self.length + self.gap_after
    @property
    def start_pad(self):      return self.start - self.gap_before
    @property
    def end_pad(self):        return self.end   + self.gap_after


def _parse_srt_from_string(content: str) -> Dict[int, Subtitle]:
    subs: Dict[int, Subtitle] = {}
    for block in re.split(r"\n\s*\n", content.strip()):
        lines = block.strip().splitlines()
        if len(lines) < 3:
            continue
        try:
            idx = int(lines[0].strip())
        except ValueError:
            continue
        m = re.match(
            r"(\d{2}:\d{2}:\d{2}[,\.]\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}[,\.]\d{3})",
            lines[1])
        if not m:
            continue
        subs[idx] = Subtitle(idx, _parse_srt_time(m.group(1)),
                             _parse_srt_time(m.group(2)),
                             "\n".join(lines[2:]))
    return subs


def _write_srt_from_dict(subs: Dict[int, Subtitle]) -> str:
    lines = []
    for i, s in enumerate(sorted(subs.values(), key=lambda x: x.start), 1):
        lines += [str(i), f"{_sync_srt_ts(s.start)} --> {_sync_srt_ts(s.end)}", s.text, ""]
    return "\n".join(lines)


# ─── Caption-style re-chunking ───────────────────────────────────────────────
# Re-flow a synced SRT into short, single-line caption cues — useful for
# burned-in subtitles, social media reels, and karaoke-style overlays.
def _caption_chunks(text: str, max_chars: int) -> List[str]:
    """
    Split a Bengali subtitle line into chunks each ≤ max_chars characters,
    preserving Unicode and breaking at whitespace whenever possible. If a
    single token is longer than max_chars (rare for Bengali words but happens
    with conjunct-heavy compounds), it is hard-split at the character limit
    so no chunk ever exceeds the cap.
    """
    text = (text or "").replace("\n", " ").strip()
    if not text:
        return []
    if max_chars <= 0:
        return [text]
    if len(text) <= max_chars:
        return [text]

    chunks: List[str] = []
    current = ""
    # Tokenise on whitespace — Bengali, like English, uses spaces between words.
    for word in text.split():
        if len(word) > max_chars:
            # Flush whatever we accumulated before the oversized word.
            if current:
                chunks.append(current)
                current = ""
            # Hard-split the long word.
            for k in range(0, len(word), max_chars):
                piece = word[k:k + max_chars]
                if len(piece) == max_chars:
                    chunks.append(piece)
                else:
                    current = piece
            continue
        candidate = (current + " " + word).strip() if current else word
        if len(candidate) <= max_chars:
            current = candidate
        else:
            if current:
                chunks.append(current)
            current = word
    if current:
        chunks.append(current)
    return chunks


def build_caption_srt(synced_srt_text: str,
                      max_chars: int = 10,
                      max_secs:  float = 1.0) -> str:
    """
    Re-chunk a synced SRT into single-line caption cues that satisfy:
        • each cue contains AT MOST `max_chars` characters
        • each cue spans AT MOST `max_secs` seconds

    Time within each source cue is split proportionally by character count so
    shorter chunks get shorter on-screen durations and the audio still lines
    up. Cues that are already short enough pass through unchanged.

    Returns a fresh SRT text (UTF-8 safe). Empty cues are dropped.
    """
    subs = _parse_srt_from_string(synced_srt_text or "")
    if not subs:
        return ""

    out_lines: List[str] = []
    out_idx = 1
    for s in sorted(subs.values(), key=lambda x: x.start):
        text = (s.text or "").replace("\n", " ").strip()
        if not text:
            continue

        chunks = _caption_chunks(text, max_chars)
        if not chunks:
            continue

        cue_dur_ms = max(1, int(round(s.end - s.start)))   # ms (Subtitle uses ms)
        max_chunk_ms = max(50, int(round(max_secs * 1000.0)))

        # Distribute cue duration proportional to chunk length, but cap each
        # chunk at max_secs so captions never linger past the limit.
        total_chars = sum(len(c) for c in chunks) or 1
        cursor_ms = float(s.start)
        for ci, chunk in enumerate(chunks):
            share = (len(chunk) / total_chars) * cue_dur_ms
            chunk_ms = min(max_chunk_ms, max(120, int(round(share))))
            start_ms = cursor_ms
            end_ms = min(float(s.end), start_ms + chunk_ms)
            # On the last piece, never exceed the original cue end.
            if ci == len(chunks) - 1:
                end_ms = float(s.end)
                # But still respect the per-chunk cap.
                if end_ms - start_ms > max_chunk_ms:
                    end_ms = start_ms + max_chunk_ms
            if end_ms <= start_ms:
                end_ms = start_ms + 120

            out_lines += [
                str(out_idx),
                f"{_sync_srt_ts(start_ms)} --> {_sync_srt_ts(end_ms)}",
                chunk,
                "",
            ]
            out_idx += 1
            cursor_ms = end_ms

    return "\n".join(out_lines)


def _parse_mapping_from_string(content: str) -> List[MappingGroup]:
    """
    Parse Gemini mapping output. Accepts every per-language 2-letter tag
    registered in TTS_LANGUAGES (BN, HI, KN, ML, AS, OR, NE, TA, TE, GU, MR)
    plus the legacy full-word `BENGALI` / `BANGLA` forms, so prompts can
    migrate incrementally without breaking the syncing pipeline.
    """
    groups = []
    _tags = {info.get("tag", "") for info in TTS_LANGUAGES.values()}
    _tags.update({"BN", "TE", "BENGALI", "BANGLA"})
    tag_alt = "|".join(sorted(t for t in _tags if t))
    pattern = re.compile(
        r"\[(\d+)\]\s*EN\s*\[([^\]]+)\]\s*->\s*"
        rf"(?:{tag_alt})\s*\[([^\]]+)\]",
        re.IGNORECASE)
    for line in content.splitlines():
        m = pattern.match(line.strip())
        if not m:
            continue
        groups.append(MappingGroup(
            no=int(m.group(1)),
            en=[int(x.strip()) for x in m.group(2).split(",")],
            te=[int(x.strip()) for x in m.group(3).split(",")]))
    groups.sort(key=lambda g: g.no)
    return groups


def _build_section_table(mappings, en_subs, te_subs, processed):
    raw = {}
    for mg in mappings:
        if mg.no in processed:
            valid = [i for i in mg.te if i in te_subs]
            if not valid: continue
            raw[mg.no] = (min(te_subs[i].start for i in valid),
                          max(te_subs[i].end   for i in valid))
        else:
            valid = [i for i in mg.en if i in en_subs]
            if not valid: continue
            raw[mg.no] = (min(en_subs[i].start for i in valid),
                          max(en_subs[i].end   for i in valid))
    if not raw:
        return {}
    ordered = sorted(raw.keys(), key=lambda n: raw[n][0])
    table   = {}
    for i, no in enumerate(ordered):
        start, end = raw[no]
        gb = max(0.0, start - raw[ordered[i-1]][1]) if i > 0 else 0.0
        ga = max(0.0, raw[ordered[i+1]][0] - end) if i < len(ordered)-1 else 0.0
        table[no] = Section(no, start, end, gb, ga)
    return table


MIN_SPRING = 10.0

def _te_valid(mg, te): return [i for i in mg.te if i in te]
def _te_start(mg, te):
    v = _te_valid(mg, te); return min(te[i].start for i in v) if v else 0.0
def _te_end(mg, te):
    v = _te_valid(mg, te); return max(te[i].end   for i in v) if v else 0.0
def _te_len(mg, te): return _te_end(mg, te) - _te_start(mg, te)
def _te_len_np(mg, te): return sum(te[i].length for i in mg.te if i in te)
def _shift(mg, delta, te):
    for i in mg.te:
        if i in te: te[i].shift(delta)

def _align_center(mg, te, target):
    cur = (_te_start(mg, te) + _te_end(mg, te)) / 2
    _shift(mg, target - cur, te)
def _align_start(mg, te, target): _shift(mg, target - _te_start(mg, te), te)
def _align_end(mg, te, target):   _shift(mg, target - _te_end(mg, te), te)


def _compress_springs(mg, te, anchor_start, target_end):
    valid = _te_valid(mg, te)
    if not valid: return
    if len(valid) == 1:
        te[valid[0]].start = anchor_start; return
    gaps = [max(0.0, te[valid[k+1]].start - te[valid[k]].end) for k in range(len(valid)-1)]
    total_content = sum(te[i].length for i in valid)
    available     = target_end - anchor_start
    space_gaps    = available - total_content
    new_gaps      = list(gaps)
    free          = list(range(len(gaps)))
    for _ in range(len(gaps)):
        ft = sum(gaps[k] for k in free)
        if ft <= 0: break
        tgt = space_gaps - sum(new_gaps[k] for k in range(len(gaps)) if k not in free)
        if tgt < 0: tgt = 0.0
        ratio  = tgt / ft if ft > 0 else 0.0
        frozen = []
        for k in free:
            p = gaps[k] * ratio
            if p <= MIN_SPRING: new_gaps[k] = MIN_SPRING; frozen.append(k)
            else:               new_gaps[k] = p
        for k in frozen: free.remove(k)
        if not frozen: break
    cursor = anchor_start
    for k, idx in enumerate(valid):
        te[idx].start = cursor
        cursor += te[idx].length
        if k < len(gaps): cursor += new_gaps[k]


def _attach_fixed(mg, te, anchor_start, spring=MIN_SPRING):
    cursor = anchor_start
    for idx in _te_valid(mg, te):
        te[idx].start = cursor
        cursor += te[idx].length + spring


def _fix_min_spring_forward(te, ordered_ids, min_gap=MIN_SPRING):
    for k in range(1, len(ordered_ids)):
        needed = te[ordered_ids[k-1]].end + min_gap
        if te[ordered_ids[k]].start < needed:
            te[ordered_ids[k]].start = needed


def _process_round(rnd, mappings, en_subs, te, processed, log_lines=None):
    count = 0
    for mg in mappings:
        if mg.no in processed:
            continue
        # Rebuild the section table after each section is processed so every
        # subsequent section sees the updated neighbour positions.
        sec_tbl = _build_section_table(mappings, en_subs, te, processed)
        if mg.no not in sec_tbl:
            continue
        tl      = sec_tbl[mg.no]
        te_len  = _te_len(mg, te)
        np_len  = _te_len_np(mg, te)
        mt      = mg.mtype
        te_v    = _te_valid(mg, te)
        en_v    = [i for i in mg.en if i in en_subs]

        eligible = False
        if   rnd == 1: eligible = te_len <= tl.length
        elif rnd == 2: eligible = (mt in ("1toM","MtoM")) and (np_len <= tl.length)
        elif rnd == 3: eligible = te_len <= tl.len_gap_after
        elif rnd == 4: eligible = (mt in ("1toM","MtoM")) and (np_len <= tl.len_gap_after)
        elif rnd == 5:
            bound = tl.len_both_gaps + MIN_SPRING
            eligible = (te_len <= bound) or (np_len <= bound)
        if not eligible:
            continue

        # Capture TE positions before placement for the log
        te_before = {i: (te[i].start, te[i].end) for i in te_v} if log_lines is not None else {}

        strategy = ""
        if rnd == 1:
            if mt == "MtoM":
                ne, nt = len(en_v), len(te_v)
                if ne == nt:
                    for eid, tid in zip(en_v, te_v):
                        te[tid].start = en_subs[eid].start
                    _fix_min_spring_forward(te, te_v)
                    strategy = "MtoM_equal"
                else:
                    for tid in te_v:
                        if en_v: te[tid].start = en_subs[en_v.pop(0)].start
                    _fix_min_spring_forward(te, te_v)
                    strategy = "MtoM_unequal"
            else:
                _align_center(mg, te, (tl.start + tl.end) / 2)
                strategy = "align_center"
        elif rnd == 2: _compress_springs(mg, te, tl.start, tl.end); strategy = "compress_springs"
        elif rnd == 3:
            if mt in ("1to1","Mto1"): _align_start(mg, te, tl.start); strategy = "align_start"
            else:                      _attach_fixed(mg, te, tl.start, MIN_SPRING); strategy = "attach_fixed"
        elif rnd == 4: _attach_fixed(mg, te, tl.start, MIN_SPRING); strategy = "attach_fixed"
        elif rnd == 5:
            target_end = tl.end_pad - MIN_SPRING
            if mt in ("1to1","Mto1"): _align_end(mg, te, target_end); strategy = "align_end"
            else:
                _attach_fixed(mg, te, tl.start, MIN_SPRING)
                _align_end(mg, te, target_end)
                strategy = "attach_fixed+align_end"

        processed.add(mg.no)
        count += 1

        if log_lines is not None:
            en_info = "  ".join(
                f"EN{i}:[{en_subs[i].start:.2f}s-{en_subs[i].end:.2f}s]"
                for i in mg.en if i in en_subs)
            te_info = "  ".join(
                f"TE{i}:{te_before[i][0]:.2f}s→{te[i].start:.2f}s"
                for i in te_v if i in te_before)
            log_lines.append(
                f"  Sec {mg.no:>3} [{mt:<5}]  slot:[{tl.start:.2f}s-{tl.end:.2f}s]"
                f"  {en_info}  {te_info}  [{strategy}]")

    return count


def _process_overflow(mappings, en_subs, te, processed, log_lines=None,
                      en_audio_duration: float = None):
    """
    Place sections that remain unprocessed after iterations 1 & 2.

    Each unprocessed section is moved to its corresponding English section's
    start time PLUS an extra offset. The extra offset is the length of the
    English audio file (en_audio_duration, in SECONDS) when supplied;
    otherwise we fall back to the max end of the English subtitle file.

    NOTE: Subtitle.start/.end are in MILLISECONDS (see _parse_srt_time),
    so en_audio_duration must be converted from seconds → ms here to keep
    the units consistent. Without this conversion the offset is ~1000×
    too small and overflow positioning effectively becomes zero.
    """
    srt_end_ms = max((s.end for s in en_subs.values()), default=0.0)
    if en_audio_duration is not None and en_audio_duration > 0:
        total_dur = float(en_audio_duration) * 1000.0  # seconds → ms
        offset_label = "EN-audio-len"
    elif srt_end_ms > 0:
        total_dur = srt_end_ms
        offset_label = "EN-srt-end"
    else:
        total_dur = 0.0
        offset_label = "ZERO-fallback (no audio length, no SRT end)"

    en_starts  = {}
    for mg in mappings:
        if mg.no in processed: continue
        valid = [i for i in mg.en if i in en_subs]
        if valid: en_starts[mg.no] = min(en_subs[i].start for i in valid)

    # Sections WITH a valid English anchor are placed directly at their
    # English start and allowed to BLEED OVER into the next slot (ported
    # from fast-syncs). No compression, no shoving past placed audio — the
    # order-preserving sweep that runs after placement resolves overlaps by
    # nudging later clips forward, which keeps speech at natural pace and
    # as close to its English timing as physically possible.
    anchored = sorted(
        [mg for mg in mappings if mg.no not in processed and mg.no in en_starts],
        key=lambda mg: en_starts[mg.no])
    # Sections with NO usable English reference still go after the end.
    orphans = [mg for mg in mappings
               if mg.no not in processed and mg.no not in en_starts]

    for mg in anchored:
        te_v = _te_valid(mg, te)
        if not te_v:
            processed.add(mg.no)
            continue
        want = en_starts[mg.no]
        te_before = {i: te[i].start for i in te_v} if log_lines is not None else {}
        _align_start(mg, te, want)
        processed.add(mg.no)
        if log_lines is not None:
            te_info = "  ".join(
                f"TE{i}:{te_before[i]:.2f}s→{te[i].start:.2f}s" for i in te_v)
            log_lines.append(
                f"  Sec {mg.no:>3} [{mg.mtype:<5}]  anchored at EN start "
                f"{want/1000.0:.2f}s (may bleed into the next slot)  "
                f"{te_info}  [bleed-over]")

    if orphans and log_lines is not None:
        log_lines.append(
            f"  Overflow offset for {len(orphans)} EN-less section(s): "
            f"{total_dur/1000.0:.2f}s ({total_dur:.0f} ms) [{offset_label}]")
    placed_ends = []
    for mg in orphans:
        te_v = _te_valid(mg, te)
        if not te_v:
            processed.add(mg.no)
            continue
        ds = total_dur
        if placed_ends and ds < placed_ends[-1]: ds = placed_ends[-1]
        te_before = {i: te[i].start for i in te_v} if log_lines is not None else {}
        _align_start(mg, te, ds)
        placed_ends.append(_te_end(mg, te))
        processed.add(mg.no)
        if log_lines is not None:
            te_info = "  ".join(
                f"TE{i}:{te_before[i]:.2f}s→{te[i].start:.2f}s" for i in te_v)
            log_lines.append(
                f"  Sec {mg.no:>3} [{mg.mtype:<5}]  overflow at {ds:.2f}s  {te_info}  [overflow]")
    return len(anchored) + len(orphans)


def run_sync_from_strings(en_srt_text, te_srt_text, mapping_text,
                          en_audio_duration: float = None):
    """
    Full sync algorithm. Returns (synced_subs, original_te_subs, sync_log).

    en_audio_duration (optional): length of the original English audio in
    SECONDS. When supplied (and > 0) it is used as the overflow offset for
    sections that remain unprocessed after iteration 2 (Stage 3d). If
    omitted/zero, we fall back to the end of the English subtitle file.
    Both values are converted to milliseconds inside _process_overflow
    because Subtitle.start/.end are stored in ms.
    """
    en_subs  = _parse_srt_from_string(en_srt_text)
    te       = {k: deepcopy(v) for k, v in _parse_srt_from_string(te_srt_text).items()}
    orig_te  = {k: deepcopy(v) for k, v in _parse_srt_from_string(te_srt_text).items()}
    mappings = _parse_mapping_from_string(mapping_text)
    if not mappings:
        raise ValueError("No mapping groups found.")
    processed: Set[int] = set()
    log_lines = [
        f"=== Sync Log — {len(mappings)} sections | {len(en_subs)} EN subs | {len(te)} TE subs ==="]
    # Log which overflow offset will be used so debugging is obvious.
    _srt_end_ms = max((s.end for s in en_subs.values()), default=0.0)
    if en_audio_duration is not None and en_audio_duration > 0:
        log_lines.append(
            f"  English audio length: {en_audio_duration:.2f}s "
            f"({en_audio_duration*1000.0:.0f} ms) [used for overflow]")
    elif _srt_end_ms > 0:
        log_lines.append(
            f"  English audio length: not supplied — falling back to "
            f"EN-SRT end = {_srt_end_ms/1000.0:.2f}s ({_srt_end_ms:.0f} ms)")
    else:
        log_lines.append(
            "  WARNING: no English audio length AND no EN-SRT end — "
            "overflow offset will be 0.")
    for iteration in (1, 2):
        for rnd in range(1, 6):
            log_lines.append(f"\n--- Iteration {iteration}, Round {rnd} ---")
            c = _process_round(rnd, mappings, en_subs, te, processed, log_lines=log_lines)
            if c == 0:
                log_lines.append("  (none processed)")
    remaining = len(mappings) - len(processed)
    if remaining:
        log_lines.append(f"\n--- Overflow ({remaining} unprocessed sections) ---")
        _process_overflow(mappings, en_subs, te, processed,
                          log_lines=log_lines,
                          en_audio_duration=en_audio_duration)
    # Order-preserving sweep (ported from fast-syncs): dubbed clips must stay
    # in recording order and must never overlap — overlapping segments get
    # mixed on top of each other in the final audio and sound garbled. Walk
    # the clips in recording order and nudge any offender forward.
    ordered_ids = sorted(te.keys())
    n_pushed, prev_end = 0, None
    for i in ordered_ids:
        if prev_end is not None and te[i].start < prev_end + MIN_SPRING:
            delta = (prev_end + MIN_SPRING) - te[i].start
            te[i].shift(delta)
            if delta > 1.0:
                n_pushed += 1
                log_lines.append(
                    f"  sweep: TE{i} +{delta/1000.0:.2f}s "
                    "(keep order / avoid overlap)")
        prev_end = te[i].end
    if n_pushed:
        log_lines.append(
            f"\n--- Order sweep: {n_pushed} subtitle(s) nudged forward ---")
    log_lines.append(f"\n=== Complete: {len(processed)}/{len(mappings)} sections synced ===")
    all_te_idx = {i for mg in mappings for i in mg.te}
    synced = {i: te[i] for i in sorted(all_te_idx) if i in te}
    # Safety net: dubbed subtitles the LLM mapping never mentioned used to be
    # DROPPED from the output entirely (missing audio in the dub). Keep them
    # at their original TTS timing instead so no speech disappears.
    missing = [i for i in sorted(te) if i not in all_te_idx]
    if missing:
        for i in missing:
            synced[i] = te[i]
        log_lines.append(
            f"⚠ {len(missing)} dubbed subtitle(s) were missing from the "
            f"mapping ({missing[:10]}{'…' if len(missing) > 10 else ''}) — "
            "kept at their original timing instead of being dropped.")
    return synced, orig_te, "\n".join(log_lines)


def _build_timestamps(original_te_subs, synced_subs):
    entries = []
    for idx in sorted(synced_subs.keys()):
        synced   = synced_subs[idx]
        original = original_te_subs.get(idx)
        if original is None: continue
        entries.append({
            "index":           idx,
            "orig_start_ms":   int(round(original.start)),
            "orig_end_ms":     int(round(original.end)),
            "synced_start_ms": int(round(synced.start)),
        })
    return entries


def sync_audio_with_timestamps(audio_path: str, timestamps: list, out_path: str, status_cb=None):
    """Cut & overlay TTS audio according to syncing timestamps. Saves as WAV to out_path."""
    if not PYDUB_AVAILABLE:
        raise ImportError("pydub not installed. Run: pip install pydub")
    if status_cb: status_cb("Sync Audio: Loading audio…")
    ext    = os.path.splitext(audio_path)[1].lower().lstrip(".")
    fmt    = {"m4a": "mp4", "aac": "adts"}.get(ext, ext)
    source = _AudioSegment.from_file(audio_path, format=fmt)

    sorted_ts = sorted(timestamps, key=lambda e: e["synced_start_ms"])
    last_entry = sorted_ts[-1]

    last_end = max(e["synced_start_ms"] + (e["orig_end_ms"] - e["orig_start_ms"])
                   for e in sorted_ts)
    canvas   = _AudioSegment.silent(duration=last_end * 2,
                                    frame_rate=source.frame_rate)

    if status_cb: status_cb(f"Sync Audio: Mixing {len(sorted_ts)} segments…")
    for entry in sorted_ts:
        if entry is last_entry:
            # Last segment: extend to end of TTS source so no word gets clipped
            seg = source[entry["orig_start_ms"]:]
        else:
            seg = source[entry["orig_start_ms"]: entry["orig_end_ms"]]
        canvas = canvas.overlay(seg, position=entry["synced_start_ms"])

    # Trim with generous tail, then smooth fade-out so ending never sounds abrupt
    tail_end = last_end + 1500
    canvas   = canvas[:tail_end].fade_out(1200)
    if status_cb: status_cb(f"Sync Audio: Exporting → {os.path.basename(out_path)}…")
    canvas.export(out_path, format="wav")
    return out_path
