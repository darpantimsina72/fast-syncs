#!/usr/bin/env python3
"""Regression loop for reusing a paid TTS synthesis after a late failure.

A legacy dub pays ElevenLabs for the speech and Scribe for transcribing it,
then makes the mapping call. When that call dies, the re-run used to pay for
both again. A sidecar now records what was synthesized.

The danger of reuse is silently dubbing the WRONG words, so these tests are
mostly about refusing to reuse: any change to the script, the voice or the
model, and any missing output, must redo the work.

Offline, deterministic, no API calls.

Run:  dubbing/venv/bin/python tests/test_tts_reuse.py
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))), "dubbing", "engine"))
import dub_engine as de  # noqa: E402

TEXT  = "नमस्ते दुनिया"
VOICE = "kkMxZ9B1JBX0queRrnb9"
MODEL = "eleven_v3"


def _project(tmp):
    """A finished S3b: sidecar + wav + target SRT all present."""
    base = os.path.join(tmp, "All Dialogue (1)")
    wav  = base + "_tts.wav"
    srt  = base + "_sync_te.srt"
    open(wav, "wb").write(b"RIFF....WAVE")
    open(srt, "w", encoding="utf-8").write("1\n00:00:00,000 --> 00:00:01,000\nhi\n")
    fp = de._dub_fingerprint(TEXT, VOICE, MODEL)
    de._remember_tts(base, fp, wav)
    return base, wav, srt, fp


def main():
    fails = []

    def check(name, cond):
        print(("  ✅ " if cond else "  ❌ ") + name)
        if not cond:
            fails.append(name)

    with tempfile.TemporaryDirectory() as tmp:
        base, wav, srt, fp = _project(tmp)

        print("reuses only when everything matches")
        check("identical run reuses the wav",
              de._reusable_tts(base, fp, srt) == wav)

        print("refuses to reuse when anything changed")
        check("edited script -> no reuse", de._reusable_tts(
            base, de._dub_fingerprint(TEXT + " extra", VOICE, MODEL), srt) is None)
        check("different voice -> no reuse", de._reusable_tts(
            base, de._dub_fingerprint(TEXT, "other-voice", MODEL), srt) is None)
        check("different model -> no reuse", de._reusable_tts(
            base, de._dub_fingerprint(TEXT, VOICE, "eleven_turbo_v2"), srt) is None)

        print("refuses to reuse when an output is gone")
        os.remove(srt)
        check("missing target SRT -> no reuse",
              de._reusable_tts(base, fp, srt) is None)
        open(srt, "w", encoding="utf-8").write("1\n")
        os.remove(wav)
        check("missing wav -> no reuse", de._reusable_tts(base, fp, srt) is None)

    with tempfile.TemporaryDirectory() as tmp:
        print("refuses to reuse with no sidecar at all")
        base = os.path.join(tmp, "Fresh")
        open(base + "_sync_te.srt", "w").write("1\n")
        check("first run -> no reuse", de._reusable_tts(
            base, de._dub_fingerprint(TEXT, VOICE, MODEL),
            base + "_sync_te.srt") is None)

        print("survives a corrupt sidecar")
        open(base + de._TTS_STATE_SUFFIX, "w").write("{not json")
        check("corrupt sidecar -> no reuse, no crash", de._reusable_tts(
            base, de._dub_fingerprint(TEXT, VOICE, MODEL),
            base + "_sync_te.srt") is None)

    print("\n%s" % ("ALL OK" if not fails else "%d FAILED: %s"
                    % (len(fails), ", ".join(fails))))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
