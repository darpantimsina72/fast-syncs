"""
Shared networking and audio duration helpers for the dubbing pipeline.

Provides HTTP retry logic with exponential backoff, background heartbeat logging
during long socket reads, and fast ffprobe audio duration probing.
"""

import http.client
import json
import os
import re
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.request
from typing import Callable, Optional, Sequence, Tuple, Union

from .config import FFMPEG_PATH, _SSL_CTX

_FATAL_HTTP = {400, 401, 403, 404, 422}
_RETRY_HTTP = {408, 425, 429, 500, 502, 503, 504}
_RETRY_EXC  = (TimeoutError, ssl.SSLError, ConnectionError,
               http.client.IncompleteRead, http.client.RemoteDisconnected,
               urllib.error.URLError)


def _retry_after(e: urllib.error.HTTPError) -> Optional[float]:
    """Extract Retry-After header in seconds, if present."""
    if not hasattr(e, "headers") or not e.headers:
        return None
    val = e.headers.get("Retry-After")
    if not val:
        return None
    try:
        return max(1.0, float(val))
    except ValueError:
        return None


def _urlopen_with_heartbeat(req: urllib.request.Request, *,
                            timeout: float,
                            context: Optional[ssl.SSLContext] = None,
                            label: str = "",
                            attempt: int = 1,
                            attempts: int = 4,
                            heartbeat: float = 30.0,
                            log: Callable[[str], None] = print) -> bytes:
    """
    Execute urllib.request.urlopen in a daemon thread while the calling thread
    logs periodic heartbeat messages every `heartbeat` seconds until completion.
    """
    box: dict = {}
    t0 = time.monotonic()

    def worker():
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=context) as r:
                box["ok"] = r.read()
        except BaseException as err:
            box["err"] = err

    t = threading.Thread(target=worker, daemon=True)
    t.start()

    while t.is_alive():
        t.join(heartbeat)
        if t.is_alive():
            elapsed = int(time.monotonic() - t0)
            tag = f"{label} " if label else ""
            log(f"{tag}waiting… {elapsed}s elapsed (attempt {attempt}/{attempts}, timeout {int(timeout)}s)")

    if "err" in box:
        raise box["err"]
    return box.get("ok", b"")


def request_with_retry(req: urllib.request.Request, *,
                       timeout: float = 180.0,
                       attempts: int = 4,
                       backoff: Sequence[float] = (5.0, 15.0, 45.0),
                       label: str = "",
                       heartbeat: float = 30.0,
                       context: Optional[ssl.SSLContext] = _SSL_CTX,
                       log: Callable[[str], None] = print) -> bytes:
    """
    Execute an HTTP request with retry logic, exponential backoff, and heartbeat logging.

    CRITICAL: urllib.error.HTTPError MUST be caught before urllib.error.URLError because
    HTTPError is a subclass of URLError.
    """
    for n in range(1, attempts + 1):
        try:
            return _urlopen_with_heartbeat(
                req, timeout=timeout, context=context, label=label,
                attempt=n, attempts=attempts, heartbeat=heartbeat, log=log
            )
        except urllib.error.HTTPError as e:  # MUST precede URLError
            if e.code in _FATAL_HTTP or e.code not in _RETRY_HTTP or n == attempts:
                raise
            wait = _retry_after(e) or backoff[min(n - 1, len(backoff) - 1)]
            why = f"HTTP {e.code}"
        except _RETRY_EXC as e:
            if n == attempts:
                raise
            wait = backoff[min(n - 1, len(backoff) - 1)]
            why = repr(e)
        except Exception as e:
            # Fallback for unclassified exceptions on final attempt or fatal
            if n == attempts:
                raise
            wait = backoff[min(n - 1, len(backoff) - 1)]
            why = repr(e)

        tag = f"{label} " if label else ""
        log(f"{tag}attempt {n}/{attempts} failed: {why} — retrying in {wait}s")
        time.sleep(wait)

    raise RuntimeError(f"{label} failed after {attempts} attempts.")


def get_audio_duration(audio_path: str) -> float:
    """
    Get audio duration in seconds using ffprobe if available.
    Falls back to a file-size / bitrate calculation, or 60.0s floor.
    Avoids decoding whole audio through librosa (preventing heavy memory load on 60-min files).
    """
    if not os.path.isfile(audio_path):
        return 60.0

    # 1. Try ffprobe executable derived from FFMPEG_PATH
    ffprobe_bin = None
    if FFMPEG_PATH:
        dirname = os.path.dirname(FFMPEG_PATH)
        exe_name = "ffprobe.exe" if os.name == "nt" else "ffprobe"
        cand = os.path.join(dirname, exe_name)
        if os.path.isfile(cand):
            ffprobe_bin = cand

    if not ffprobe_bin:
        import shutil
        ffprobe_bin = shutil.which("ffprobe")

    if ffprobe_bin:
        try:
            cmd = [
                ffprobe_bin, "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                audio_path
            ]
            res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
            if res.returncode == 0 and res.stdout.strip():
                dur = float(res.stdout.strip())
                if dur > 0:
                    return dur
        except Exception:
            pass

    # 2. Fallback: estimate from file size assuming standard MP3/WAV bitrates (~128 kbps = 16 KB/s)
    try:
        size_bytes = os.path.getsize(audio_path)
        ext = os.path.splitext(audio_path)[1].lower()
        if ext in (".mp3", ".aac", ".m4a"):
            # ~128 kbps = 16000 bytes/sec
            est = size_bytes / 16000.0
        elif ext in (".wav", ".flac"):
            # ~16-bit 44.1kHz mono = 88200 bytes/sec
            est = size_bytes / 88200.0
        else:
            est = size_bytes / 20000.0
        return max(60.0, est)
    except Exception:
        return 60.0
