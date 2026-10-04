#!/usr/bin/env python3
"""Regression loop for the long-English auto-split (v0.15.7).

Field report 2026-09-29 (Nepali): the English track was ONE 110 s clip, the
dub track 36 clips. Every DUB matched that one clip, so the spring placer
packed all 36 back-to-back in the middle of the 110 s slot — "36/36 matched"
and nothing lined up.

Guards:
  1. split_words_into_pieces cuts at sentence ends and long pauses, never
     inside a word, caps piece length, and merges tiny fragments.
  2. split_long_en_items leaves short clips alone, renumbers ids in timeline
     order, and keeps pieces at their absolute timeline time.
  3. A long clip with no word timings is left whole and reported.
  4. End to end through match_gemini (fake transcribe + fake matcher): each
     DUB lands near its own sentence, not packed into the middle.
  5. A cached transcript without word timings is re-transcribed for a long
     EN clip, and served from cache for a short one.

Offline, deterministic, no API calls and no network.

Run:  venv/bin/python tests/test_en_split.py
"""
import contextlib
import io
import os
import shutil
import struct
import sys
import tempfile
import wave

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import sync_matcher as m  # noqa: E402

FAILS = []


def check(cond, label):
    print(f"  {'PASS' if cond else 'FAIL'} {label}")
    if not cond:
        FAILS.append(label)


def write_wav(path, seconds, rate=8000):
    n = int(seconds * rate)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", 500 + (k % 97))
                               for k in range(n)))


def make_words(sentences, t0=0.5, word_len=0.3, word_gap=0.05,
               sentence_gap=0.6):
    """[(sentence text), ...] → Scribe-shaped word list with timings."""
    words, t = [], t0
    starts = []
    for s in sentences:
        starts.append(t)
        toks = s.split()
        for i, tok in enumerate(toks):
            words.append({"text": tok, "start": round(t, 3),
                          "end": round(t + word_len, 3)})
            t += word_len + (word_gap if i < len(toks) - 1 else sentence_gap)
    return words, starts


SENTS = [
    "I lost my brother recently.",
    "He was an Isha meditator.",
    "What should I do now?",
    "Life is like this.",
    "When we are here it is so precious.",
    "Do not waste a moment.",
]


# ── 1. word grouping ───────────────────────────────────────────────
def test_pieces():
    print("split_words_into_pieces")
    words, _ = make_words(SENTS)
    pieces = m.split_words_into_pieces(words)
    check(len(pieces) == len(SENTS),
          f"one piece per sentence ({len(pieces)} == {len(SENTS)})")
    check([" ".join(w["text"] for w in p) for p in pieces] == SENTS,
          "pieces keep every word, in order, cut only between words")

    # No punctuation, but a long pause → still a cut.
    w2 = [{"text": "and", "start": 0.0, "end": 0.5},
          {"text": "then", "start": 0.55, "end": 1.1},
          {"text": "silence", "start": 1.9, "end": 2.4},
          {"text": "came", "start": 2.45, "end": 3.0}]
    check(len(m.split_words_into_pieces(w2)) == 2, "long pause alone cuts")

    # Short pause after a comma → no cut.
    w3 = [{"text": "yes,", "start": 0.0, "end": 0.4},
          {"text": "we", "start": 0.6, "end": 0.9},
          {"text": "go", "start": 0.95, "end": 1.3}]
    check(len(m.split_words_into_pieces(w3)) == 1, "comma + short pause: no cut")

    # 40 s of fast speech, no pauses above the gap → capped pieces.
    fast = [{"text": f"w{i}", "start": i * 0.4, "end": i * 0.4 + 0.35}
            for i in range(100)]
    fast[50]["start"] += 0.02   # a slightly longer pause to cut at
    fp = m.split_words_into_pieces(fast)
    spans = [p[-1]["end"] - p[0]["start"] for p in fp]
    check(all(s <= m._EN_SPLIT_MAX_PIECE for s in spans),
          f"no piece over {m._EN_SPLIT_MAX_PIECE}s (max {max(spans):.1f}s)")
    check(sum(len(p) for p in fp) == 100, "capping loses no words")

    # A lone "Yes." between sentences is merged, not its own piece.
    w4, _ = make_words(["This is the first thought.", "Yes.",
                        "This is the second thought."])
    p4 = m.split_words_into_pieces(w4)
    check(all(p[-1]["end"] - p[0]["start"] >= m._EN_SPLIT_MIN_PIECE
              for p in p4), "tiny fragment merged into a neighbour")
    check(sum(len(p) for p in p4) == 11, "merging loses no words")
    check(m.split_words_into_pieces([]) == [], "no words → no pieces")


# ── 2 + 3. item splitting ──────────────────────────────────────────
def test_items():
    print("split_long_en_items")
    words, starts = make_words(SENTS)
    long_clip = {"id": 1, "position": 100.0, "duration": 30.0,
                 "wav_path": "x.wav", "transcript": "all", "words": words}
    short_before = {"id": 2, "position": 90.0, "duration": 3.0,
                    "wav_path": "x.wav", "transcript": "short"}
    m._PROBLEMS.clear() if hasattr(m, "_PROBLEMS") else None
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        out = m.split_long_en_items([long_clip, short_before])
    log = buf.getvalue()
    check(len(out) == 1 + len(SENTS), f"1 short + {len(SENTS)} pieces "
          f"(got {len(out)})")
    check([e["id"] for e in out] == list(range(1, len(out) + 1)),
          "ids renumbered 1..N")
    check(out[0]["transcript"] == "short", "short clip first and untouched")
    check(all(out[i]["position"] < out[i + 1]["position"]
              for i in range(len(out) - 1)), "timeline order")
    got = [round(e["position"], 3) for e in out[1:]]
    want = [round(100.0 + s, 3) for s in starts]
    check(got == want, "piece position = clip position + first word time")
    check(all(e["speech_start"] == 0.0 for e in out[1:]),
          "piece speech_start is 0 (position is already the first word)")
    check(all("words" not in e for e in out), "word lists not carried on")
    check(long_clip.get("words") is words, "input item not mutated")
    import re
    check(not re.search(r'\[\s*\d+\]\s+"', log),
          "split log has no '[N] \"' lines (Lua poller would count them)")

    # Long clip, no word timings (Gemini ASR) → whole + problem reported.
    no_words = {"id": 1, "position": 0.0, "duration": 60.0,
                "wav_path": "x.wav", "transcript": "text"}
    with contextlib.redirect_stdout(io.StringIO()):
        out2 = m.split_long_en_items([no_words])
    check(len(out2) == 1, "no word timings → clip kept whole")
    check(any("LONG_EN_NOT_SPLIT" in p for p in m.problems_as_strings()),
          "LONG_EN_NOT_SPLIT reported to the panel")

    # Feature off.
    old = m._EN_SPLIT_MIN_SEC
    m._EN_SPLIT_MIN_SEC = 0
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            out3 = m.split_long_en_items([long_clip])
        check(len(out3) == 1, "SYNC_EN_SPLIT_MIN_SEC=0 turns splitting off")
    finally:
        m._EN_SPLIT_MIN_SEC = old


# ── 4. end to end ──────────────────────────────────────────────────
def test_end_to_end(tmp):
    print("match_gemini end to end (fake ASR + fake matcher)")
    words, starts = make_words(SENTS)
    en_len = max(words[-1]["end"] + 1.0, m._EN_SPLIT_MIN_SEC + 5.0)
    src_en = os.path.join(tmp, "en.wav")
    src_dub = os.path.join(tmp, "dub.wav")
    write_wav(src_en, en_len + 1)
    write_wav(src_dub, 40.0)

    en_items = [{"id": 1, "position": 0.0, "duration": en_len,
                 "wav_path": src_en, "take_offset": 0.0}]
    # One DUB clip per sentence, 1.4 s long, recorded back-to-back.
    dub_items = [{"id": i + 1, "position": 2.0 * i, "duration": 1.4,
                  "wav_path": src_dub, "take_offset": 0.1 + 2.0 * i}
                 for i in range(len(SENTS))]

    def fake_transcribe(path, task="transcribe", language=None, cache=None,
                        need_words=False, **_kw):
        if language == "en":
            return {"text": " ".join(SENTS), "speech_start": words[0]["start"],
                    "speech_end": words[-1]["end"],
                    "words": words if need_words else []}
        n = int(os.path.basename(path).split("_")[-1].split(".")[0])
        return {"text": f"dub sentence {n}", "speech_start": 0.2,
                "speech_end": 1.2, "words": []}

    seen = {}

    def fake_sections(en, dub, *_a, **_kw):
        seen["en"] = en
        # Perfect matcher: DUB k ↔ EN piece k.
        return ([{"en": [e["id"]], "dub": [d["id"]]}
                 for e, d in zip(en, dub)], [], [])

    orig_t, orig_s = m.transcribe, m._call_gemini_sections
    m.transcribe, m._call_gemini_sections = fake_transcribe, fake_sections
    try:
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            results = m.match_gemini(en_items, dub_items, "ne", "fake-key")
    finally:
        m.transcribe, m._call_gemini_sections = orig_t, orig_s
    if os.environ.get("VERBOSE"):
        print(buf.getvalue())

    check(len(seen.get("en", [])) == len(SENTS),
          f"matcher saw {len(SENTS)} EN pieces, not 1")
    by_id = {r["dub_id"]: r for r in results}
    check(all(r["status"] == "matched" for r in results), "all matched")
    # Each DUB's SPEECH (new_position + 0.2 s onset) should sit inside its
    # sentence's window, not in one packed block.
    ok = True
    for k, (d, s) in enumerate(zip(dub_items, starts)):
        speech_at = by_id[d["id"]]["new_position"] + 0.2
        piece = seen["en"][k]
        if not (piece["position"] - 0.5 <= speech_at
                <= piece["position"] + piece["duration"]):
            ok = False
            print(f"    dub {d['id']} speech at {speech_at:.2f}s, sentence "
                  f"{piece['position']:.2f}–"
                  f"{piece['position'] + piece['duration']:.2f}s")
    check(ok, "every DUB lands inside its own sentence window")


# ── 5. cache without word timings ─────────────────────────────────
def test_cache_refetch(tmp):
    print("cache: old entry without word timings")
    wav = os.path.join(tmp, "c.wav")
    write_wav(wav, 1.0)
    cache = m.TranscriptCache(os.path.join(tmp, "cache.json"))
    old_entry = {"text": "old", "speech_start": 0.1, "speech_end": 0.9}
    cache.set(wav, "transcribe", "en", "elevenlabs", old_entry)

    calls = []

    def fake_11(path, language, key):
        calls.append(path)
        return {"text": "fresh", "speech_start": 0.1, "speech_end": 0.9,
                "words": [{"text": "fresh", "start": 0.1, "end": 0.9}]}

    orig = m.transcribe_elevenlabs
    m.transcribe_elevenlabs = fake_11
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            r1 = m.transcribe(wav, language="en", cache=cache,
                              elevenlabs_key="k", need_words=False)
            calls_after_r1 = len(calls)
            r2 = m.transcribe(wav, language="en", cache=cache,
                              elevenlabs_key="k", need_words=True)
            r3 = m.transcribe(wav, language="en", cache=cache,
                              elevenlabs_key="k", need_words=True)
    finally:
        m.transcribe_elevenlabs = orig
    check(r1["text"] == "old" and calls_after_r1 == 0, "short clip: old cache served")
    check(r2["text"] == "fresh" and len(calls) == 1,
          "long clip: re-transcribed to get word timings")
    check(r3["text"] == "fresh" and len(calls) == 1,
          "then served from cache, word timings included")


def main():
    tmp = tempfile.mkdtemp(prefix="ensplit_")
    try:
        test_pieces()
        test_items()
        test_end_to_end(tmp)
        test_cache_refetch(tmp)
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
