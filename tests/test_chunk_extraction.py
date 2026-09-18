#!/usr/bin/env python3
"""Regression loop for per-clip audio slicing (sync_matcher).

Symptom this guards against: when the source media is a format libsndfile
cannot decode (.m4a / .mp4 / .aac / .wma), get_audio_for_item() silently
returns the WHOLE source file instead of the clip's slice. Every clip then
gets the same transcript, Gemini cannot tell the clips apart, and the run
collapses into "unmatched" + order-violation Unsyncs.

Offline, deterministic, no API calls. Requires ffmpeg only to BUILD the
fixtures (the code under test must not need it for wav).

Run:  venv/bin/python tests/test_chunk_extraction.py
"""
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import sync_matcher as m  # noqa: E402

SRC_SECONDS = 10.0
OFFSET = 4.0
SLICE = 2.0
TOLERANCE = 0.15          # seconds

# format -> whether libsndfile can decode it (informational only)
FORMATS = ["wav", "flac", "ogg", "mp3", "m4a", "mp4", "aac"]


def _ffmpeg():
    exe = shutil.which("ffmpeg")
    if not exe:
        sys.exit("SKIP: ffmpeg not on PATH — cannot build fixtures")
    return exe


def _probe_duration(path):
    """Duration in seconds via ffprobe; None if unreadable."""
    exe = shutil.which("ffprobe")
    if not exe:
        return None
    out = subprocess.run(
        [exe, "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", path],
        capture_output=True, text=True)
    try:
        return float(out.stdout.strip())
    except (TypeError, ValueError):
        return None


def build_fixtures(tmp):
    ff = _ffmpeg()
    made = {}
    for ext in FORMATS:
        path = os.path.join(tmp, f"src.{ext}")
        cmd = [ff, "-y", "-v", "error",
               "-f", "lavfi", "-i", f"sine=frequency=440:duration={SRC_SECONDS}",
               "-ar", "44100", "-ac", "1"]
        if ext in ("m4a", "mp4", "aac"):
            cmd += ["-c:a", "aac"]
        cmd.append(path)
        if subprocess.run(cmd, capture_output=True).returncode == 0:
            made[ext] = path
    return made


def check(ext, src, tmp):
    """Return (ok, detail) for one source format."""
    out = m.get_audio_for_item(1, src, OFFSET, SLICE)
    if out is None:
        return False, "returned None"
    if os.path.abspath(out) == os.path.abspath(src):
        return False, ("returned the WHOLE SOURCE FILE — every clip would get "
                       "identical audio")
    dur = _probe_duration(out)
    if dur is None:
        return True, "extracted (duration unverified, no ffprobe)"
    if abs(dur - SLICE) > TOLERANCE:
        return False, f"slice is {dur:.3f}s, expected {SLICE:.3f}s"
    return True, f"slice {dur:.3f}s"


def main():
    print(f"HAS_SOUNDFILE = {m.HAS_SOUNDFILE}")
    if m.HAS_SOUNDFILE:
        import soundfile as sf
        print(f"libsndfile    = {sf.__libsndfile_version__}")
    print(f"ffmpeg        = {shutil.which('ffmpeg')}")
    print()

    tmp = tempfile.mkdtemp(prefix="chunktest_")
    try:
        fixtures = build_fixtures(tmp)
        failures = []
        for ext in FORMATS:
            src = fixtures.get(ext)
            if not src:
                print(f"  skip {ext:5s}  (fixture not buildable)")
                continue
            try:
                ok, detail = check(ext, src, tmp)
            except Exception as e:                      # noqa: BLE001
                ok, detail = False, f"raised {type(e).__name__}: {e}"
            print(f"  {'PASS' if ok else 'FAIL'} {ext:5s}  {detail}")
            if not ok:
                failures.append(ext)
        print()
        if failures:
            print(f"RED: {len(failures)} format(s) do not get a per-clip slice: "
                  f"{', '.join(failures)}")
            return 1
        print("GREEN: every source format yields a correct per-clip slice")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
