#!/usr/bin/env python3
"""Regression loop for Auto Sync's transcription step (sync_matcher).

Guards four things:

  1. Cache key collision — the transcript cache used to hash only the first
     64 KB of a clip (+ size). Two clips of equal length that open the same
     way got each other's transcript. The key must cover the whole file.
  2. Temp-slice collision — EN and DUB clips are both numbered from 1. With
     one shared transcription pool both sides are sliced before either is
     transcribed, so "chunk_0001.wav" for EN would be overwritten by DUB.
  3. Log shape — the unchanged Lua poller greps "STEP 1"/"STEP 2" and counts
     lines matching  %[%s*%d+%]%s+"  per phase. EN clip lines must land in
     phase 1 and DUB clip lines in phase 2, all of them, exactly once.
  4. Cache is saved even when the run fails (SystemExit in the matcher, the
     zero-match hard failure) — and the exit code is still 1.

Offline, deterministic, no API calls and no network: transcribe() and the
matcher are replaced with fakes.

Run:  venv/bin/python tests/test_transcribe_pool_and_cache.py
"""
import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import struct
import sys
import tempfile
import threading
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import sync_matcher as m  # noqa: E402

FAILS = []


def check(cond, label):
    print(f"  {'PASS' if cond else 'FAIL'} {label}")
    if not cond:
        FAILS.append(label)


def write_wav(path, seconds, sign, rate=16000):
    """Mono 16-bit PCM WAV: a slow ramp, positive (sign=1) or negative (-1).

    The ramp makes every slice's bytes unique (so the identical-transcript
    gate does not fire); the sign tells which source a slice came from.
    """
    n = int(seconds * rate)
    frames = b"".join(struct.pack("<h", sign * (1000 + (k // 100) % 20000))
                      for k in range(n))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(frames)


# ── 1. Cache key covers the whole file ─────────────────────────────
def test_cache_key(tmp):
    print("cache key")
    head = os.urandom(65536)
    a = os.path.join(tmp, "a.wav")
    b = os.path.join(tmp, "b.wav")
    c = os.path.join(tmp, "c.wav")
    with open(a, "wb") as f:
        f.write(head + b"\x01" * 4096)
    with open(b, "wb") as f:
        f.write(head + b"\x02" * 4096)
    with open(c, "wb") as f:
        f.write(head + b"\x01" * 4096)
    check(os.path.getsize(a) == os.path.getsize(b), "fixtures: same size")

    cache = m.TranscriptCache(os.path.join(tmp, "cache_key.json"))
    ka = cache._key(a, "transcribe", "en", "elevenlabs")
    kb = cache._key(b, "transcribe", "en", "elevenlabs")
    kc = cache._key(c, "transcribe", "en", "elevenlabs")
    check(ka != kb, "same size + same first 64 KB, different tail -> different keys")
    check(ka == kc, "identical content -> same key")
    check(re.fullmatch(r"[0-9a-f]{16}_\d+__transcribe__en__elevenlabs", ka)
          is not None, "key keeps the old '<digest>_<size>__task__lang__model' shape")

    cache.set(a, "transcribe", "en", "elevenlabs", {"text": "A"})
    check(cache.get(b, "transcribe", "en", "elevenlabs") is None,
          "clip B does not get clip A's transcript")


def test_cache_loads_old_file(tmp):
    print("old sync_cache.json still loads")
    path = os.path.join(tmp, "old_cache.json")
    old = {
        "0123456789abcdef_12345__transcribe__en__elevenlabs":
            {"text": "old", "speech_start": 0.0, "speech_end": 1.0},
        "gemini:deadbeef": "raw matcher text",
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(old, f)
    with contextlib.redirect_stdout(io.StringIO()):
        cache = m.TranscriptCache(path)
    check(cache.get_raw("gemini:deadbeef") == "raw matcher text",
          "raw (matcher) entries survive")
    check(len(cache._data) == 2, "all old entries loaded")


# ── 2. Side-specific temp names ────────────────────────────────────
def test_chunk_names():
    print("temp slice names")
    check(m._chunk_name(1, "en") != m._chunk_name(1, "dub"),
          "EN 1 and DUB 1 get different temp names")
    check(m._chunk_name(1) == "chunk_0001.wav", "no side -> old name unchanged")


# ── 3. Shared pool: slices, concurrency, Lua-visible log shape ─────
class _StopAfterTranscription(Exception):
    pass


def lua_count(log):
    """Replay auto_sync_pipeline.lua poll_python_step() phase counting."""
    clip_re = re.compile(r'\[\s*\d+\]\s+"')      # Lua: %[%s*%d+%]%s+"
    phase, en_done, dub_done = 0, 0, 0
    for line in log.splitlines():
        if "STEP 1" in line:
            phase = 1
        if "STEP 2" in line:
            phase = 2
        if "STEP 3" in line:
            phase = 3
        if "STEP 4" in line:
            phase = 4
        if clip_re.search(line):
            if phase == 1:
                en_done += 1
            elif phase == 2:
                dub_done += 1
    return en_done, dub_done


def run_pool(tmp, n_en, n_dub, en_delay, dub_delay):
    """Run match_gemini's transcription half with a fake transcribe()."""
    src_en = os.path.join(tmp, "src_en.wav")
    src_dub = os.path.join(tmp, "src_dub.wav")
    write_wav(src_en, 30.0, 1)
    write_wav(src_dub, 30.0, -1)

    def items(src, n):
        # take_offset > 0.05 forces a real slice into the temp dir
        return [{"id": i, "position": float(i), "duration": 0.5,
                 "wav_path": src, "take_offset": 0.25 + i}
                for i in range(1, n + 1)]
    en_items, dub_items = items(src_en, n_en), items(src_dub, n_dub)

    lock = threading.Lock()
    state = {"now": 0, "max": 0}

    def fake_transcribe(path, task="transcribe", language=None, cache=None,
                        **_kw):
        with lock:
            state["now"] += 1
            state["max"] = max(state["max"], state["now"])
        # Text comes from the slice's BYTES, so a clobbered slice shows up
        # as a transcript that belongs to the other side.
        with open(path, "rb") as f:
            data = f.read()
        with wave.open(path, "rb") as w:
            first = struct.unpack("<h", w.readframes(1)[:2])[0]
        time.sleep(en_delay if language == "en" else dub_delay)
        # EN source samples are positive, DUB source samples negative.
        side = "EN" if first > 0 else "DUB"
        with lock:
            state["now"] -= 1
        return {"text": f"{side} {hashlib.md5(data).hexdigest()[:6]}",
                "speech_start": 0.0, "speech_end": 0.5}

    def stop(*_a, **_kw):
        raise _StopAfterTranscription()

    orig_t, orig_sec = m.transcribe, m._call_gemini_sections
    m.transcribe, m._call_gemini_sections = fake_transcribe, stop
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            try:
                m.match_gemini(en_items, dub_items, "hi", "fake-key")
            except _StopAfterTranscription:
                pass
    finally:
        m.transcribe, m._call_gemini_sections = orig_t, orig_sec
    return en_items, dub_items, buf.getvalue(), state["max"]


def test_shared_pool(tmp):
    print("shared transcription pool")
    # EN slow, DUB fast: most DUB clips finish while STEP 1 is still open,
    # which is exactly the case where their lines must be held back.
    en, dub, log, peak = run_pool(tmp, 10, 10, en_delay=0.15, dub_delay=0.01)
    check(all(i["transcript"].startswith("EN ") for i in en),
          "every EN clip transcribed from EN audio (no slice clobbering)")
    check(all(i["transcript"].startswith("DUB ") for i in dub),
          "every DUB clip transcribed from DUB audio (no slice clobbering)")
    check(peak > 8, f"EN+DUB overlap in one pool (peak concurrency {peak} > 8)")
    check(peak <= m.TRANSCRIBE_WORKERS,
          f"never more than {m.TRANSCRIBE_WORKERS} at once (peak {peak})")
    en_n, dub_n = lua_count(log)
    check((en_n, dub_n) == (10, 10),
          f"Lua counter sees EN 10 in phase 1, DUB 10 in phase 2 (got {en_n}, {dub_n})")
    check(log.index("STEP 1") < log.index("STEP 2"), "STEP 1 before STEP 2")
    check(log.count("✓ Done in") == 2, "two 'Done in' timing lines")

    # DUB slow, EN fast: DUB lines stream live after the STEP 2 header.
    en, dub, log, _ = run_pool(tmp, 5, 12, en_delay=0.01, dub_delay=0.05)
    en_n, dub_n = lua_count(log)
    check((en_n, dub_n) == (5, 12),
          f"reverse timing: EN 5 / DUB 12 counted (got {en_n}, {dub_n})")

    # No EN clips at all: STEP 2 header must still appear before DUB lines.
    en, dub, log, _ = run_pool(tmp, 0, 4, en_delay=0.0, dub_delay=0.01)
    en_n, dub_n = lua_count(log)
    check((en_n, dub_n) == (0, 4), f"no EN clips: DUB 4 counted (got {en_n}, {dub_n})")


# ── 4. Cache saved on failure; exit code still 1 ───────────────────
def run_main(tmp, fake_match):
    cfg = os.path.join(tmp, "cfg.json")
    cache_path = os.path.join(tmp, "main_cache.json")
    if os.path.exists(cache_path):
        os.remove(cache_path)
    with open(cfg, "w", encoding="utf-8") as f:
        json.dump({"output_path": os.path.join(tmp, "out.json"),
                   "en_items": [], "dub_items": [
                       {"id": 1, "position": 0.0, "duration": 1.0,
                        "wav_path": "x.wav", "take_offset": 0.0}]}, f)
    orig_argv, orig_match = sys.argv, m.match_gemini
    sys.argv = ["sync_matcher.py", "--config", cfg, "--cache", cache_path,
                "--elevenlabs-key", "fake", "--gemini-key", "fake"]
    m.match_gemini = fake_match
    code = None
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            m.main()
    except SystemExit as e:
        code = e.code
    finally:
        sys.argv, m.match_gemini = orig_argv, orig_match
    saved = {}
    if os.path.exists(cache_path):
        with open(cache_path, encoding="utf-8") as f:
            saved = json.load(f)
    return code, saved


def test_cache_saved_on_failure(tmp):
    print("cache flushed when the run fails")

    def gate_fails(*_a, cache=None, **_kw):
        cache.set_raw("paid-for", {"text": "keep me"})
        raise SystemExit(1)
    code, saved = run_main(tmp, gate_fails)
    check(code == 1, f"SystemExit(1) in matcher -> exit 1 (got {code})")
    check("paid-for" in saved, "cache saved after SystemExit in matcher")

    def crashes(*_a, cache=None, **_kw):
        cache.set_raw("paid-for", {"text": "keep me"})
        raise RuntimeError("boom")
    try:
        run_main(tmp, crashes)
        raised = False
    except RuntimeError:
        raised = True
    saved = json.load(open(os.path.join(tmp, "main_cache.json"), encoding="utf-8"))
    check(raised and "paid-for" in saved, "cache saved after unexpected exception")

    def zero_matches(*_a, cache=None, **_kw):
        cache.set_raw("paid-for", {"text": "keep me"})
        return [{"dub_id": 1, "match": None, "score": 0,
                 "new_position": 0.0, "dub_duration": 1.0,
                 "status": "unmatched"}]
    code, saved = run_main(tmp, zero_matches)
    check(code == 1, f"zero matches is still a hard failure, exit 1 (got {code})")
    check("paid-for" in saved, "cache saved on zero-match failure")


def main():
    tmp = tempfile.mkdtemp(prefix="pooltest_")
    try:
        test_cache_key(tmp)
        test_cache_loads_old_file(tmp)
        test_chunk_names()
        test_shared_pool(tmp)
        test_cache_saved_on_failure(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print()
    if FAILS:
        print(f"RED: {len(FAILS)} check(s) failed")
        return 1
    print("GREEN: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
