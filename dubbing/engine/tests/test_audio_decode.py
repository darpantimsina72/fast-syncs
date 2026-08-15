#!/usr/bin/env python3
"""Audio decode + region detection regression test.

Runs headlessly, so CI can run it on every push and on both operating systems.
REAPER cannot be automated, but this covers the part that actually breaks
users: whether the engine can decode audio and still find the same speech
regions in it.

Why this exists: librosa used to decode audio here. It was removed because it
was used in only two places and dragged in numba + llvmlite + scipy (~164 MB
installed) plus a Python-version ceiling. Decoding now goes through
pydub/ffmpeg, which was already a hard requirement. This test pins the
behaviour that removal had to preserve.

    python dubbing/engine/tests/test_audio_decode.py

Needs numpy, pydub and ffmpeg — all already required by the engine.
"""
import os
import pathlib
import sys
import tempfile
import wave

import numpy as np

ENGINE_DIR = pathlib.Path(__file__).resolve().parents[1]
if str(ENGINE_DIR) not in sys.path:
    sys.path.insert(0, str(ENGINE_DIR))

from pipeline.srt_tools import (_load_audio_any,          # noqa: E402
                                _detect_regions_from_audio)

THR, HYS, MIN_MS = -42.0, 6.0, 150


def _speechlike(sr, seconds, spans, amp=0.5):
    """Tone bursts separated by true silence — a stand-in for dialogue."""
    n = int(sr * seconds)
    t = np.arange(n) / sr
    y = np.zeros(n, dtype=np.float64)
    for a, b in spans:
        i0, i1 = int(a * sr), int(b * sr)
        seg = np.sin(2 * np.pi * 180 * t[i0:i1])
        seg += 0.3 * np.sin(2 * np.pi * 430 * t[i0:i1])
        if len(seg) > 1:
            seg *= np.hanning(len(seg))
        y[i0:i1] = seg
    return amp * y


def _write_wav(path, y, sr, sampwidth, channels=1):
    peak = float(1 << (8 * sampwidth - 1))
    data = np.clip(y, -1.0, 1.0)
    if channels == 2:
        data = np.stack([data, data * 0.85], axis=1).reshape(-1)
    dtype = {1: np.int8, 2: np.int16, 4: np.int32}[sampwidth]
    with wave.open(str(path), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(sampwidth)
        w.setframerate(sr)
        w.writeframes((data * (peak - 1)).astype(dtype).tobytes())


def main() -> int:
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="fs-audio-test-"))
    spans3 = [(0.4, 1.5), (2.2, 3.4), (4.1, 5.6)]
    cases = []

    p = tmp / "mono16_44k.wav"
    _write_wav(p, _speechlike(44100, 6.0, spans3), 44100, 2)
    cases.append(("mono 16-bit 44.1k", p, 44100, 3))

    p = tmp / "stereo16_44k.wav"
    _write_wav(p, _speechlike(44100, 6.0, spans3), 44100, 2, channels=2)
    cases.append(("stereo 16-bit (downmix)", p, 44100, 3))

    p = tmp / "mono32_48k.wav"
    _write_wav(p, _speechlike(48000, 5.0, [(0.3, 1.9), (2.6, 4.2)]), 48000, 4)
    cases.append(("mono 32-bit 48k", p, 48000, 2))

    p = tmp / "silence.wav"
    _write_wav(p, np.zeros(44100 * 2), 44100, 2)
    cases.append(("pure silence", p, 44100, 0))

    # MP3 round-trip: what ElevenLabs returns before the pipeline exports WAV.
    try:
        from pydub import AudioSegment
        AudioSegment.from_wav(tmp / "mono16_44k.wav").export(
            tmp / "speech.mp3", format="mp3", bitrate="128k")
        cases.append(("mp3 (needs ffmpeg)", tmp / "speech.mp3", 44100, 3))
    except Exception as e:                                   # pragma: no cover
        print("  ! skipping mp3 case (ffmpeg unavailable?): %s" % e)

    failures = 0
    print("%-26s %8s %6s %9s  %s"
          % ("CASE", "sr", "dtype", "regions", "OK"))
    print("-" * 66)
    for label, path, want_sr, want_regions in cases:
        try:
            y, sr = _load_audio_any(str(path))
        except Exception as e:
            print("%-26s  decode FAILED: %s" % (label, e))
            failures += 1
            continue

        regions = _detect_regions_from_audio(y, sr, THR, HYS, MIN_MS)
        checks = {
            "sample rate preserved": sr == want_sr,
            "float32":               y.dtype == np.float32,
            "mono (1-D)":            y.ndim == 1,
            "normalised to +-1":     float(np.max(np.abs(y))) <= 1.0,
            "region count":          len(regions) == want_regions,
        }
        ok = all(checks.values())
        if not ok:
            failures += 1
        print("%-26s %8d %6s %4d/%-4d  %s"
              % (label, sr, y.dtype, len(regions), want_regions,
                 "yes" if ok else "NO"))
        if not ok:
            for name, passed in checks.items():
                if not passed:
                    print("      failed: %s" % name)

    print()
    print("cases: %d   failures: %d" % (len(cases), failures))
    print("AUDIO DECODE OK" if not failures else "AUDIO DECODE FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
