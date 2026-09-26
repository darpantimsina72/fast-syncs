#!/usr/bin/env python3
"""Lossless FLAC before the Scribe upload.

A PCM wav is uploaded as mono FLAC at the same sample rate so the upload is
smaller while every sample — and every word timing — stays put. Anything
the conversion cannot guarantee (no ffmpeg, a lossy source, float wav) must
fall back to uploading the original file exactly as before.

Offline, no API calls. The conversion checks need ffmpeg and are skipped
without it.

Run:  dubbing/venv/bin/python tests/test_stt_flac.py
"""
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import wave

sys.path.insert(0, os.path.join(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))), "dubbing", "engine"))
from pipeline import stt  # noqa: E402

FAILS = []


def check(name, cond):
    print(("  ✅ " if cond else "  ❌ ") + name)
    if not cond:
        FAILS.append(name)


def _write_wav(path, rate=48000, channels=2, seconds=2.0):
    n = int(rate * seconds)
    with wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        frames = bytearray()
        for i in range(n):
            v = int(8000 * math.sin(2 * math.pi * 220 * i / rate))
            frames += struct.pack("<h", v) * channels
        w.writeframes(bytes(frames))
    return n


def _probe(path, entry):
    out = subprocess.run(
        [stt._ffprobe_path(), "-v", "error", "-select_streams", "a:0",
         "-show_entries", f"stream={entry}", "-of",
         "default=noprint_wrappers=1:nokey=1", path],
        capture_output=True, text=True)
    return out.stdout.strip()


def main():
    tmp = tempfile.mkdtemp(prefix="stt_flac_")
    try:
        wav = os.path.join(tmp, "talk.wav")
        n = _write_wav(wav)
        if stt.FFMPEG_PATH and stt._ffprobe_path():
            print("PCM wav -> mono FLAC, same rate, same length")
            flac = stt._flac_for_upload(wav)
            check("conversion produced a file", bool(flac)
                  and os.path.isfile(flac))
            if flac:
                check("smaller than the wav",
                      os.path.getsize(flac) < os.path.getsize(wav))
                check("same sample rate", _probe(flac, "sample_rate") == "48000")
                check("mono", _probe(flac, "channels") == "1")
                dec = os.path.join(tmp, "back.wav")
                subprocess.run([stt.FFMPEG_PATH, "-loglevel", "error", "-y",
                                "-i", flac, dec], check=True)
                with wave.open(dec, "rb") as w:
                    check("identical sample count (timings unchanged)",
                          w.getnframes() == n)
                os.remove(flac)
        else:
            print("  (ffmpeg/ffprobe missing — conversion checks skipped)")

        print("falls back to the original upload")
        mp3 = os.path.join(tmp, "talk.mp3")
        open(mp3, "wb").write(b"\xff\xfb" + b"\x00" * 100)
        check("lossy source -> None", stt._flac_for_upload(mp3) is None)
        bad = os.path.join(tmp, "float.wav")
        open(bad, "wb").write(b"RIFF\x00\x00\x00\x00WAVEjunk")
        check("unreadable / non-PCM wav -> None",
              stt._flac_for_upload(bad) is None)
        real = stt.FFMPEG_PATH
        stt.FFMPEG_PATH = None
        try:
            check("ffmpeg missing -> None", stt._flac_for_upload(wav) is None)
        finally:
            stt.FFMPEG_PATH = real
        stt.FFMPEG_PATH = os.path.join(tmp, "no-such-ffmpeg")
        try:
            check("ffmpeg fails -> None, temp file removed",
                  stt._flac_for_upload(wav) is None
                  and not [f for f in os.listdir(tempfile.gettempdir())
                           if f.startswith("dub_stt_")
                           and os.path.getmtime(os.path.join(
                               tempfile.gettempdir(), f)) > os.path.getmtime(wav)])
        finally:
            stt.FFMPEG_PATH = real
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n%s" % ("ALL OK" if not FAILS else "%d FAILED: %s"
                    % (len(FAILS), ", ".join(FAILS))))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
