#!/usr/bin/env python3
"""Parallel ElevenLabs synthesis: order, retry, and re-run reuse.

Voice requests now run a few at a time. The one thing that must never
happen is audio landing in the wrong order, so the fake server below answers
requests in a scrambled order (later requests finish first) and every check
compares against what a strictly one-at-a-time run produces.

Also covered: retry on HTTP 429 / 5xx (honouring Retry-After), no retry on a
real refusal, and match-mode reuse of already-paid stretch audio.

Offline, deterministic, no API calls: config._urlopen is replaced inside
the tts module. Needs ffmpeg for the audio-assembly checks (pydub decodes
MP3 with it); those checks are skipped when it is missing.

Run:  dubbing/venv/bin/python tests/test_tts_parallel.py
"""
import base64
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error

sys.path.insert(0, os.path.join(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))), "dubbing", "engine"))
from pipeline import config, tts  # noqa: E402

VOICE = "kkMxZ9B1JBX0queRrnb9"
FAILS = []


def check(name, cond):
    print(("  ✅ " if cond else "  ❌ ") + name)
    if not cond:
        FAILS.append(name)


class _Resp:
    def __init__(self, body):
        self._b = body

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _tone(ms, tmp):
    """A real MP3 of *ms* milliseconds (so decoded lengths identify it)."""
    path = os.path.join(tmp, f"t{ms}.mp3")
    subprocess.run([config.FFMPEG_PATH, "-loglevel", "error", "-y", "-f",
                    "lavfi", "-i", f"sine=frequency=440:duration={ms / 1000}",
                    "-ac", "1", "-ar", "44100", "-b:a", "64k", path],
                   check=True)
    return open(path, "rb").read()


class FakeEL:
    """Answers each request with an MP3 whose LENGTH encodes which text it
    was for, sleeping so that EARLIER requests finish LATER."""

    def __init__(self, tones):
        self.tones = tones              # text -> mp3 bytes
        self.calls = []
        self.lock = threading.Lock()
        self.active = 0
        self.peak = 0

    def __call__(self, req, timeout=120):
        body = json.loads(req.data.decode("utf-8"))
        text = body["text"]
        with self.lock:
            self.calls.append(text)
            n = len(self.calls)
            self.active += 1
            self.peak = max(self.peak, self.active)
        time.sleep(max(0.0, 0.12 - 0.02 * n))   # first request slowest
        with self.lock:
            self.active -= 1
        audio = self.tones[text]
        if req.full_url.endswith("/with-timestamps"):
            k = len(text)
            return _Resp(json.dumps({
                "audio_base64": base64.b64encode(audio).decode(),
                "alignment": {
                    "characters": list(text),
                    "character_start_times_seconds":
                        [0.1 * i / k for i in range(k)],
                    "character_end_times_seconds":
                        [0.1 * (i + 1) / k for i in range(k)]}}).encode())
        return _Resp(audio)


def test_run_parallel_order():
    print("_run_parallel keeps the original order")
    order = []

    def mk(i):
        def f():
            time.sleep(0.05 * (5 - i))   # task 0 finishes last
            return i * 10
        return f
    out = config._run_parallel([mk(i) for i in range(6)], 4,
                               on_done=lambda i, r: order.append(i))
    check("results in task order", out == [0, 10, 20, 30, 40, 50])
    check("completions really were out of order", order != sorted(order))

    def boom():
        raise ValueError("second task failed")
    try:
        config._run_parallel([lambda: 1, boom, lambda: 3], 4)
        check("an error propagates", False)
    except ValueError as e:
        check("an error propagates", "second task" in str(e))


def test_sentences_order_and_reuse(tmp):
    print("sentence-timed synthesis: order under scrambled completion")
    # One sentence per stretch (each longer than half the packing size),
    # each answered with a tone of a DIFFERENT length.
    sents = [f"{chr(0x0915 + i)} " * 300 + "।" for i in range(6)]
    tones = {s: _tone(300 + 100 * i, tmp) for i, s in enumerate(sents)}

    def run(workers, out_name, model="eleven_v3", voice=VOICE):
        fake = FakeEL(tones)
        tts._urlopen = fake
        path, spans = tts.synthesize_sentences_elevenlabs(
            sents, os.path.join(tmp, out_name), "k", voice, model,
            workers=workers)
        return fake, spans

    seq_fake, seq_spans = run(1, "seq_tts.wav")
    par_fake, par_spans = run(4, "par_tts.wav")
    check("one request per stretch", len(par_fake.calls) == len(sents))
    check("requests really overlapped", par_fake.peak > 1)
    check("completion order differed from script order",
          par_fake.calls != sents or par_fake.peak > 1)
    check("spans identical to the one-at-a-time run", par_spans == seq_spans)
    lens = [e - s for (s, e) in par_spans]
    check("piece lengths grow in script order (right audio, right place)",
          lens == sorted(lens) and len(set(lens)) == len(lens))
    seq_wav = open(os.path.join(tmp, "seq_tts.wav"), "rb").read()
    par_wav = open(os.path.join(tmp, "par_tts.wav"), "rb").read()
    check("combined wav byte-identical to the one-at-a-time run",
          seq_wav == par_wav)

    print("sentence-timed synthesis: re-run reuse")
    again_fake, again_spans = run(4, "par_tts.wav")
    check("identical re-run makes zero requests", again_fake.calls == [])
    check("reused spans identical", again_spans == par_spans)
    other_fake, _ = run(4, "par_tts.wav", voice="zzzzzzzzzzzzzzzzzzzz")
    check("different voice -> every stretch synthesized again",
          len(other_fake.calls) == len(sents))
    # corrupt one sidecar, change one file's size: only those redo
    open(os.path.join(tmp, "par_tts_str_002.mp3.json"), "w").write("{bad")
    with open(os.path.join(tmp, "par_tts_str_004.mp3"), "ab") as f:
        f.write(b"x")
    part_fake, part_spans = run(4, "par_tts.wav", voice="zzzzzzzzzzzzzzzzzzzz")
    check("corrupt / altered pieces (and only those) are redone",
          sorted(part_fake.calls) == sorted([sents[1], sents[3]]))


def test_sections_and_legacy_order(tmp):
    print("sectioned + legacy synthesis: order under scrambled completion")
    secs = [f"{chr(0x0915 + i)} " * 60 + "।" for i in range(5)]
    tones = {s: _tone(250 + 100 * i, tmp) for i, s in enumerate(secs)}
    fake = FakeEL(tones)
    tts._urlopen = fake
    _, seq = tts.synthesize_sections_elevenlabs(
        secs, os.path.join(tmp, "sq_tts.wav"), "k", VOICE, "eleven_v3",
        workers=1)
    fake = FakeEL(tones)
    tts._urlopen = fake
    _, par = tts.synthesize_sections_elevenlabs(
        secs, os.path.join(tmp, "pr_tts.wav"), "k", VOICE, "eleven_v3",
        workers=4)
    check("section spans identical to one-at-a-time", par == seq)
    check("section requests overlapped", fake.peak > 1)
    fake = FakeEL(tones)
    tts._urlopen = fake
    tts.synthesize_sections_elevenlabs(
        secs, os.path.join(tmp, "pr_tts.wav"), "k", VOICE, "eleven_v3")
    check("identical sectioned re-run makes zero requests", fake.calls == [])

    # Legacy: chunks joined in order. _split_text_for_elevenlabs is stubbed
    # so each chunk is one known text.
    real_split = tts._split_text_for_elevenlabs
    tts._split_text_for_elevenlabs = lambda text, max_chars=None: list(secs)
    try:
        wavs = []
        for w, name in ((1, "lg1_tts.wav"), (4, "lg4_tts.wav")):
            tts._urlopen = FakeEL(tones)
            p = tts.synthesize_tts_elevenlabs(
                "x", os.path.join(tmp, name), "k", VOICE, "eleven_v3",
                workers=w)
            wavs.append(open(p, "rb").read())
        check("legacy wav byte-identical to one-at-a-time", wavs[0] == wavs[1])
    finally:
        tts._split_text_for_elevenlabs = real_split


def _http_error(code, retry_after=None):
    hdrs = {"Retry-After": str(retry_after)} if retry_after is not None else {}
    return urllib.error.HTTPError("https://api.elevenlabs.io/x", code, "err",
                                  hdrs, io.BytesIO(b'{"detail":"x"}'))


def test_retry():
    print("retry on 429 / 5xx, not on a refusal")
    sleeps = []
    # tts.time IS the global time module: keep the real sleep to restore.
    real_sleep = time.sleep
    tts.time.sleep = lambda s: sleeps.append(s)
    try:
        seq = [_http_error(429, retry_after=7), _http_error(503)]
        calls = []

        def flaky(req, timeout=120):
            calls.append(1)
            if seq:
                raise seq.pop(0)
            return _Resp(b"MP3")
        tts._urlopen = flaky
        out = tts._elevenlabs_tts_post("t", "k", VOICE, "eleven_v3")
        check("429 then 503 then success -> audio returned", out == b"MP3")
        check("3 attempts made", len(calls) == 3)
        check("Retry-After 7 honoured, then 5s backoff", sleeps == [7.0, 5.0])

        sleeps.clear()
        calls.clear()

        def always_429(req, timeout=120):
            calls.append(1)
            raise _http_error(429)
        tts._urlopen = always_429
        try:
            tts._elevenlabs_tts_post("t", "k", VOICE, "eleven_v3")
            check("gives up after retries", False)
        except ValueError as e:
            check("gives up after 4 attempts with the rate-limit message",
                  len(calls) == 4 and "429" in str(e))
        check("backoff 2/5/10 s", sleeps == [2.0, 5.0, 10.0])

        sleeps.clear()
        calls.clear()

        def timeout_once(req, timeout=120):
            calls.append(1)
            if len(calls) == 1:
                raise TimeoutError("The read operation timed out")
            return _Resp(b"OK")
        tts._urlopen = timeout_once
        check("a read timeout is retried",
              tts._elevenlabs_tts_post("t", "k", VOICE, "eleven_v3") == b"OK")

        calls.clear()

        def refuse(req, timeout=120):
            calls.append(1)
            raise _http_error(401)
        tts._urlopen = refuse
        try:
            tts._elevenlabs_tts_post("t", "k", VOICE, "eleven_v3")
        except ValueError:
            pass
        check("401 is not retried", len(calls) == 1)
    finally:
        tts.time.sleep = real_sleep


def main():
    real_urlopen = tts._urlopen
    try:
        test_run_parallel_order()
        test_retry()
        if config.FFMPEG_PATH and tts.PYDUB_AVAILABLE:
            tmp = tempfile.mkdtemp(prefix="tts_parallel_")
            try:
                test_sentences_order_and_reuse(tmp)
                test_sections_and_legacy_order(tmp)
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
        else:
            print("  (ffmpeg/pydub missing — audio-assembly checks skipped)")
    finally:
        tts._urlopen = real_urlopen
    print("\n%s" % ("ALL OK" if not FAILS else "%d FAILED: %s"
                    % (len(FAILS), ", ".join(FAILS))))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
