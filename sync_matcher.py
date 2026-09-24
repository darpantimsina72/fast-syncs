#!/usr/bin/env python3
"""
sync_matcher.py — AI-powered audio sync matcher for Reaper
============================================================
Called by auto_sync_pipeline.lua. Do not run manually.

Matches dubbed audio items to original VO items using:
  1. ElevenLabs Scribe v2 transcription (or Gemini audio)
  2. Gemini semantic matching (one API call for all clips)
  3. Silence correction (speech start alignment)
  4. Anti-collision (daisy chain)

Supported languages: hi, ne, ta, te, bn, mr, gu, kn, ml, pa, ur, and more.
"""

import os
import sys
import re
import json
import time
import argparse
import hashlib
import tempfile
import subprocess
import base64
import ssl
import wave
import urllib.request
import urllib.error
import threading
import atexit
import shutil
import bisect
import difflib
import unicodedata
from pathlib import Path
from collections import defaultdict, Counter
from concurrent.futures import ThreadPoolExecutor, as_completed

# Always resolve paths relative to THIS script file, not the
# working directory — Reaper launches Python from a read-only
# system folder so relative paths like "sync_cache.json" fail.
SCRIPT_DIR = Path(__file__).parent.resolve()

# ── Force UTF-8 console output (Windows safety) ──────────────────────
# This script prints box-drawing/check-mark glyphs (✓ → ── …). When stdout
# is redirected to a file on Windows it defaults to the legacy ANSI code page
# (cp1252), which can't encode those glyphs → UnicodeEncodeError mid-run.
# run_sync.py already exports PYTHONUTF8/PYTHONIOENCODING, but reconfigure here
# too so a manual `python sync_matcher.py ...` run can never crash on a glyph.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass  # very old Python or a stream without reconfigure() — non-fatal

# True on Windows; used to hide child-process console windows (e.g. ffmpeg).
_IS_WINDOWS = (os.name == "nt")
_NO_WINDOW_FLAGS = getattr(subprocess, "CREATE_NO_WINDOW", 0) if _IS_WINDOWS else 0

# ── Cross-platform TLS for corporate SSL-inspection proxies ──────────
# Some networks (Zscaler, Netskope, ESET, Windows Defender) decrypt HTTPS
# by inserting their own root certificate. That proxy root lives in the OS
# trust store but often omits the Authority Key Identifier extension, which
# Python 3.13 enforces by default (VERIFY_X509_STRICT). Result on Windows:
#   "certificate verify failed: Missing Authority Key Identifier"
#   "self-signed certificate in certificate chain"
#
# truststore is the clean fix: it routes ALL TLS (urllib here, plus httpx
# used by the google-genai Vertex client, and requests) through the native
# OS certificate verification APIs, which trust the proxy root and don't
# apply the strict AKI rule. It's optional — if it isn't installed we fall
# back to _ssl_context() below, which covers every urllib call in this file.
try:
    import truststore
    truststore.inject_into_ssl()
    _HAS_TRUSTSTORE = True
except Exception:
    _HAS_TRUSTSTORE = False

_SSL_CTX = None
_SSL_INSECURE_CTX = None
# Once a cert-verify failure proves a TLS-inspection proxy is in the path, we
# stop verifying for the rest of the session (avoids a failed-then-retried
# double request on every subsequent call). Off until proven necessary.
_SSL_FORCE_INSECURE = False
_SSL_INSECURE_WARNED = False


def _ssl_context():
    """Return a cached SSL context tolerant of corporate SSL-inspection proxies.

    Clears VERIFY_X509_STRICT (Python 3.13's default) so certs lacking the
    Authority Key Identifier extension still validate, while keeping full
    chain validation against trusted roots — including the OS store, where
    the proxy root is installed. On macOS / normal networks this is a no-op
    because real certificates carry AKI. certifi is added as an extra root
    source on top of the OS store.
    """
    if _SSL_FORCE_INSECURE:
        return _insecure_ssl_context()
    global _SSL_CTX
    if _SSL_CTX is not None:
        return _SSL_CTX
    ctx = ssl.create_default_context()
    if hasattr(ssl, "VERIFY_X509_STRICT"):
        ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT
    try:
        import certifi
        ctx.load_verify_locations(certifi.where())
    except (ImportError, ssl.SSLError):
        pass
    _SSL_CTX = ctx
    return ctx


def _insecure_ssl_context():
    """Last-resort context with verification disabled. Only used after a real
    cert-verify failure (TLS-inspection proxy whose root isn't trusted)."""
    global _SSL_INSECURE_CTX
    if _SSL_INSECURE_CTX is None:
        c = ssl.create_default_context()
        c.check_hostname = False
        c.verify_mode = ssl.CERT_NONE
        _SSL_INSECURE_CTX = c
    return _SSL_INSECURE_CTX


def _is_cert_verify_error(err):
    """True only for TLS certificate-VERIFICATION failures (not HTTP errors,
    timeouts, DNS, resets). These are the ones a TLS-inspection proxy causes."""
    reason = getattr(err, "reason", err)
    if isinstance(reason, ssl.SSLCertVerificationError):
        return True
    msg = str(reason).lower()
    return ("certificate verify failed" in msg
            or "certificate_verify_failed" in msg
            or "self-signed certificate" in msg
            or "self signed certificate" in msg)


def _urlopen(req, timeout=120):
    """urllib.request.urlopen wrapper with a verified-first, insecure-fallback
    TLS strategy for Windows machines behind SSL-inspecting AV/proxies.

    1. Try with the proxy-tolerant verified context (OS store + certifi, AKI
       strictness relaxed). This succeeds whenever the proxy root is trusted.
    2. ONLY if that fails with a certificate-VERIFY error (e.g. a self-signed
       inspection root that isn't installed in the trust store) retry once with
       verification disabled, print a one-time notice, and disable verification
       for the rest of the session. Never disables verification up front, and
       never swallows non-certificate errors (HTTP 4xx/5xx, timeouts) — those
       propagate so callers handle them as before.
    """
    try:
        return urllib.request.urlopen(req, timeout=timeout, context=_ssl_context())
    except urllib.error.URLError as e:
        # HTTPError is a URLError subclass but means TLS already succeeded —
        # _is_cert_verify_error() returns False for it, so it re-raises here.
        if not _is_cert_verify_error(e):
            raise
        global _SSL_FORCE_INSECURE, _SSL_INSECURE_WARNED
        if not _SSL_INSECURE_WARNED:
            print("    [SSL] Certificate verification failed — a TLS-inspection "
                  "proxy/antivirus is likely intercepting HTTPS. Retrying with "
                  "verification DISABLED for the rest of this run.")
            _SSL_INSECURE_WARNED = True
        _SSL_FORCE_INSECURE = True
        return urllib.request.urlopen(req, timeout=timeout,
                                      context=_insecure_ssl_context())


# ── Optional API proxy mode ──────────────────────────────────────────
# When SYNC_API_BASE is set, every upstream AI call (ElevenLabs, Gemini,
# OpenAI, Anthropic) routes through YOUR server, which holds the real API
# keys. The client carries only a per-user bearer token (SYNC_API_TOKEN),
# never the provider keys — so you can share this app without sharing keys.
# When SYNC_API_BASE is empty the app calls providers directly as before.
_API_BASE  = os.environ.get("SYNC_API_BASE", "").rstrip("/")
_API_TOKEN = os.environ.get("SYNC_API_TOKEN", "")
_USE_PROXY = bool(_API_BASE)

# Force ElevenLabs to use an explicit language_code instead of auto-detect.
# Auto-detect is usually most accurate, but misfires on some scripts (e.g.
# Kannada 'kn' detected as Nepali/Hindi). Set SYNC_ELEVENLABS_FORCE_LANG=1
# to pass the known language through. Works in both direct and proxy mode.
# v0.15.4: this now defaults to ON. The user always picks the dub language in
# the UI, so Scribe never needs to guess — and when it guesses wrong (Kannada
# read as Nepali, Hindi read as Nepali: both Devanagari) every transcript on the
# track is wrong, Gemini cannot match anything, and the clips end up on the
# Un sync track. That is the "works for some languages, not others" report.
# Set SYNC_ELEVENLABS_FORCE_LANG=0 to go back to auto-detect.
_ELEVENLABS_FORCE_LANG = os.environ.get(
    "SYNC_ELEVENLABS_FORCE_LANG", "1").strip().lower() in ("1", "true", "yes", "on")


def _proxy_post(path, json_body=None, multipart=None, timeout=180):
    """POST to the proxy server. Returns (status_code, parsed_json_or_None).

    multipart: (fields_dict, (filename, file_bytes, mime_type)) for uploads.
    json_body: dict serialised as JSON. Exactly one of the two is used.
    """
    url = f"{_API_BASE}{path}"
    headers = {}
    if _API_TOKEN:
        headers["Authorization"] = f"Bearer {_API_TOKEN}"
    if multipart is not None:
        fields, (fname, fbytes, fmime) = multipart
        data, content_type = _multipart_encode(
            fields or {}, {"file": (fname, fbytes, fmime)})
        headers["Content-Type"] = content_type
    else:
        data = json.dumps(json_body or {}).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with _urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode()[:200]
        except Exception:
            pass
        print(f"    [PROXY] HTTP {e.code}: {e.reason} — {body}")
        return e.code, None
    except Exception as e:
        print(f"    [PROXY] Error: {e}")
        return 0, None


# ── Audio chunk extraction (BUG 3 FIX) ──────────────────────────
# After Reaper's Dynamic Split, each item still points to the FULL
# source WAV file. take_offset tells us WHERE in that file to start,
# and duration tells us how long the chunk is.
# We must extract only that slice before sending to the STT model.

# soundfile is OPTIONAL. It is only used to slice audio chunks and to read
# any non-WAV format. When absent (thin-client / server mode) we fall back to
# the stdlib `wave` module for PCM .wav files — zero pip dependencies.
try:
    import soundfile as sf
    HAS_SOUNDFILE = True
except ImportError:
    HAS_SOUNDFILE = False


# ── Problem collector ────────────────────────────────────────────────────
# Everything that degrades a run but does not stop it used to be a [WARN]
# printed into sync_python_log.txt — a file nobody opens. So a run could
# silently transcribe the whole source file for every clip and still report
# "RESULT: 28/40 matched" as though that were normal.
#
# Problems are collected here, printed as a block at the end of the run, and
# written into sync_results.json as a "problems" array of flat
# "SEVERITY|CODE|message" strings. Flat strings, not objects: the Lua reads
# that file with line-wise pattern matching, and strings are the one shape it
# cannot get wrong.
_PROBLEMS = []
_PROBLEM_SEEN = set()


def report_problem(severity, code, message, once_key=None):
    """Record a user-visible problem. severity: ERROR | WARN | INFO."""
    key = once_key or (severity, code, message)
    if key in _PROBLEM_SEEN:
        return
    _PROBLEM_SEEN.add(key)
    _PROBLEMS.append({"severity": severity, "code": code, "message": message})


def problems_as_strings():
    return [f'{p["severity"]}|{p["code"]}|{p["message"]}' for p in _PROBLEMS]


def print_problems():
    if not _PROBLEMS:
        return
    order = {"ERROR": 0, "WARN": 1, "INFO": 2}
    print(f"\n{'=' * 60}")
    print(f"  PROBLEMS FOUND: {len(_PROBLEMS)}")
    print(f"{'=' * 60}")
    for p in sorted(_PROBLEMS, key=lambda x: order.get(x["severity"], 9)):
        print(f'  [{p["severity"]}] {p["code"]}: {p["message"]}')
    print(f"{'=' * 60}")

# Vertex AI (google-genai) — preferred path: no free-tier rate limits,
# no 503 overload storms, no 404 model-shopping. Install with:
#     pip install google-genai
try:
    from google import genai as _vertex_genai
    HAS_VERTEX_GENAI = True
except ImportError:
    HAS_VERTEX_GENAI = False

_VERTEX_CLIENT = None
# Gemini backend: "auto" (use Vertex if vertex_key.json present, else REST),
# "vertex" (force Vertex; error if unavailable), or "rest" (force REST API key).
_GEMINI_BACKEND = os.environ.get("SYNC_GEMINI_BACKEND", "auto").lower()
_GEMINI_MATCHER_MODEL = os.environ.get("SYNC_GEMINI_MODEL", "gemini-2.5-pro")
_GEMINI_AUDIO_MODEL   = os.environ.get("SYNC_GEMINI_AUDIO_MODEL", "gemini-2.5-flash")

# OpenAI-compatible gateway for Gemini (e.g. an internal LiteLLM-style proxy).
# When backend == "gateway" (or "auto" with this set) the matcher talks to
# {base}/v1/chat/completions with an `Authorization: Bearer <key>` header — the
# OpenAI Chat Completions contract — instead of Google's native API. The key in
# this mode is a Bearer token (often "sk-..."), NOT a Google "AIza..." key.
_GEMINI_BASE_URL = os.environ.get("SYNC_GEMINI_BASE_URL", "").rstrip("/")

# Browser agent string for the gateway path. Cloudflare-fronted gateways deny
# the default "Python-urllib/x.y" agent with a 403 / "error code: 1010" before
# the request ever reaches the model. Override with SYNC_HTTP_USER_AGENT.
_DEFAULT_HTTP_USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                           "AppleWebKit/537.36 (KHTML, like Gecko) "
                           "Chrome/126.0.0.0 Safari/537.36")
_HTTP_USER_AGENT = (os.environ.get("SYNC_HTTP_USER_AGENT", "").strip()
                    or _DEFAULT_HTTP_USER_AGENT)


def _gateway_urls(base_url):
    """Chat-completions URLs to try for an OpenAI-compatible base, best first.

    A base that already carries a path is its API root, so only the endpoint is
    appended — the shape OpenAI (…/v1), OpenRouter (…/api/v1), Gemini's
    OpenAI-compat layer (…/v1beta/openai) and Open WebUI (…/api) all use. A bare
    host gets the versioned path. An unversioned path may instead be a proxy
    mounted on a sub-path (…/llm serving /llm/v1/chat/completions), so that shape
    stays as a 404 fallback.
    """
    base = (base_url or "").strip().rstrip("/")
    m = re.match(r"^(?:[A-Za-z][\w+.-]*://)?[^/]+(/.*)?$", base)
    path = (m.group(1) or "") if m else ""
    if not path:
        return [base + "/v1/chat/completions"]
    urls = [base + "/chat/completions"]
    if not re.search(r"/v\d", path):
        urls.append(base + "/v1/chat/completions")
    return urls

def _get_vertex_client():
    """Lazy-init Vertex AI client from vertex_key.json beside this script.
    Returns None if unavailable so caller can fall back to REST path."""
    global _VERTEX_CLIENT
    if _GEMINI_BACKEND == "rest":
        return None
    if _VERTEX_CLIENT is not None:
        return _VERTEX_CLIENT
    if not HAS_VERTEX_GENAI:
        if _GEMINI_BACKEND == "vertex":
            print("[VERTEX] google-genai package not installed — install with: "
                  "pip install google-genai")
        return None
    # Honour GOOGLE_APPLICATION_CREDENTIALS env var if set (Lua passes it
    # when the user has chosen a custom Vertex JSON path).
    key_file = Path(os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
                    or (SCRIPT_DIR / "vertex_key.json"))
    if not key_file.exists():
        if _GEMINI_BACKEND == "vertex":
            print(f"[VERTEX] Service-account JSON not found at {key_file}")
        return None
    try:
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = str(key_file)
        with open(key_file, "r", encoding="utf-8") as f:
            project_id = json.load(f).get("project_id")
        if not project_id:
            return None
        _VERTEX_CLIENT = _vertex_genai.Client(
            vertexai=True, project=project_id, location="us-central1"
        )
        print(f"[VERTEX] Client ready (project={project_id}, model={_GEMINI_MATCHER_MODEL})")
        return _VERTEX_CLIENT
    except Exception as e:
        print(f"[VERTEX] Init failed ({e}) — REST fallback will be used")
        return None

_temp_dir = None

def _cleanup_temp():
    global _temp_dir
    if _temp_dir and os.path.exists(_temp_dir):
        shutil.rmtree(_temp_dir, ignore_errors=True)

atexit.register(_cleanup_temp)

def get_temp_dir():
    global _temp_dir
    if _temp_dir is None:
        # Use system temp dir — always writable, even when launched from Reaper
        _temp_dir = tempfile.mkdtemp(prefix="sync_pipeline_")
    return _temp_dir


def extract_chunk_soundfile(wav_path, take_offset, duration, out_path):
    """Extract audio slice using soundfile (pure Python, no ffmpeg needed)."""
    with sf.SoundFile(wav_path) as f:
        sr = f.samplerate
        channels = f.channels
        start_sample = int(take_offset * sr)
        n_samples = int(duration * sr)
        f.seek(start_sample)
        data = f.read(n_samples, dtype="float32")
    # Convert to mono if needed (mono works best for STT)
    if channels > 1 and data.ndim > 1:
        data = data.mean(axis=1)
    sf.write(out_path, data, sr)
    return out_path


def _find_ffmpeg():
    """Locate ffmpeg: PATH first, then the places the installers put it.

    Mirrors dubbing/engine/pipeline/config.py:_find_ffmpeg(). Auto Sync used a
    bare "ffmpeg" here, so on Windows — where setup_windows.bat drops the binary
    into dubbing/ffmpeg/ or WinGet Links rather than onto the PATH REAPER hands
    its child processes — the ffmpeg slice backend was unreachable and AAC-family
    sources (.m4a/.mp4/.aac) silently fell back to whole-file transcription.
    """
    import shutil as _shutil
    exe = "ffmpeg.exe" if _IS_WINDOWS else "ffmpeg"
    found = _shutil.which("ffmpeg")
    if found:
        return found
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, "ffmpeg", "bin", exe),
        os.path.join(here, "ffmpeg", exe),
        os.path.join(here, "dubbing", "ffmpeg", "bin", exe),
        os.path.join(here, "dubbing", "ffmpeg", exe),
    ]
    if _IS_WINDOWS:
        candidates += [
            os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Links\ffmpeg.exe"),
            os.path.expandvars(r"%ProgramFiles%\ffmpeg\bin\ffmpeg.exe"),
            r"C:\ffmpeg\bin\ffmpeg.exe",
        ]
    else:
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg",
                       "/usr/bin/ffmpeg"]
    for c in candidates:
        if c and os.path.isfile(c):
            return c
    return None


FFMPEG_PATH = _find_ffmpeg()


def extract_chunk_ffmpeg(wav_path, take_offset, duration, out_path):
    """Extract audio slice using ffmpeg subprocess (fallback)."""
    if not FFMPEG_PATH:
        raise RuntimeError(
            "ffmpeg not found (checked PATH, ffmpeg/, dubbing/ffmpeg/ and the "
            "standard install locations) — cannot slice this audio format")
    cmd = [
        FFMPEG_PATH, "-y",
        "-i", wav_path,
        "-ss", str(take_offset),
        "-t",  str(duration),
        "-ar", "16000",
        "-ac", "1",
        out_path
    ]
    # creationflags hides the brief console window ffmpeg would otherwise pop
    # on Windows (REAPER is a GUI app); it is 0 / no-op everywhere else.
    result = subprocess.run(cmd, capture_output=True,
                            creationflags=_NO_WINDOW_FLAGS)
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {result.stderr.decode(errors='replace')}")
    return out_path


def _wav_duration(wav_path):
    """Duration (seconds) of a PCM WAV using only the stdlib. None if unreadable."""
    try:
        with wave.open(wav_path, "rb") as w:
            fr = w.getframerate()
            if fr <= 0:
                return None
            return w.getnframes() / float(fr)
    except Exception:
        return None


def extract_chunk_wave(wav_path, take_offset, duration, out_path):
    """Extract a slice from a PCM WAV using ONLY the stdlib `wave` module.

    Zero third-party deps — the thin-client/server path relies on this. Keeps
    the source channel count (no mono downmix; STT services accept stereo).
    Raises if the file is not a readable PCM WAV so the caller can fall back.
    """
    with wave.open(wav_path, "rb") as w:
        sr      = w.getframerate()
        nch     = w.getnchannels()
        sw      = w.getsampwidth()
        nframes = w.getnframes()
        start   = max(0, int(take_offset * sr))
        count   = int(duration * sr)
        if start >= nframes:
            frames = b""        # offset past end of file → empty slice
        else:
            count = min(count, nframes - start)
            w.setpos(start)
            frames = w.readframes(count)
    with wave.open(out_path, "wb") as o:
        o.setnchannels(nch)
        o.setsampwidth(sw)
        o.setframerate(sr)
        o.writeframes(frames)
    return out_path


def _extract_slice(wav_path, take_offset, duration, out_path):
    """Slice an audio chunk using the best available backend, in order:
      1. soundfile  — most formats, mono downmix (only if installed)
      2. stdlib wave — PCM .wav, zero deps (thin-client default)
      3. ffmpeg      — any format, if the binary is on PATH
    Raises only if all backends fail.

    EVERY backend is tried in turn. soundfile is built on libsndfile, which
    cannot decode AAC-family containers (.m4a / .mp4 / .aac / .wma) and chokes
    on some .ogg files. Before this loop existed, an installed soundfile
    returned early, its exception escaped to the caller, and the caller fell
    back to transcribing the WHOLE source file — so every clip on the track
    got identical text and semantic matching collapsed into "unmatched".
    ffmpeg handles those formats; it must stay reachable.
    """
    errors = []

    if HAS_SOUNDFILE:
        try:
            return extract_chunk_soundfile(wav_path, take_offset, duration, out_path)
        except Exception as e:
            errors.append(f"soundfile: {e}")

    try:
        return extract_chunk_wave(wav_path, take_offset, duration, out_path)
    except Exception as e:
        errors.append(f"wave: {e}")

    try:
        return extract_chunk_ffmpeg(wav_path, take_offset, duration, out_path)
    except Exception as e:
        errors.append(f"ffmpeg: {e}")

    raise RuntimeError("all slice backends failed — " + " | ".join(errors))


_SOURCE_DURATION_CACHE = {}


def _source_duration(wav_path):
    """Duration of a source file in seconds, or None if unreadable. Cached."""
    if wav_path in _SOURCE_DURATION_CACHE:
        return _SOURCE_DURATION_CACHE[wav_path]
    dur = None
    if HAS_SOUNDFILE:
        try:
            with sf.SoundFile(wav_path) as f:
                dur = f.frames / f.samplerate
        except Exception:
            dur = None
    if dur is None:
        # Stdlib probe — PCM WAV only, None for anything else.
        dur = _wav_duration(wav_path)
    _SOURCE_DURATION_CACHE[wav_path] = dur
    return dur


# When extraction fails we used to hand ASR the whole source file. That is only
# sane when the file really is about one clip long: on an hour-long stem it
# sends 60 minutes of audio to the transcriber for a two-second clip — slow,
# expensive, and useless for matching. Past this length, skip the clip instead;
# the caller records an empty transcript and the run carries on.
_FULL_FILE_FALLBACK_MAX = float(
    os.environ.get("SYNC_FULL_FILE_FALLBACK_MAX", "30"))


def _extract_failed(item_id, wav_path, err):
    """Log an extraction failure and decide what to transcribe instead."""
    print(f"    [WARN] Could not extract chunk for item {item_id}: {err}")
    dur = _source_duration(wav_path)
    if dur is not None and dur > _FULL_FILE_FALLBACK_MAX:
        print(f"    [WARN] Source is {dur:.0f}s — skipping this clip rather "
              f"than sending the whole file to ASR")
        return None
    print(f"    [WARN] Falling back to full source file (accuracy may suffer)")
    return wav_path


def get_audio_for_item(item_id, wav_path, take_offset, duration):
    """
    Return the path to a WAV file containing ONLY the audio for this item.

    If take_offset is near 0 and duration covers the whole file, return
    the original path directly (no extraction needed — item IS the file).
    Otherwise extract the slice.
    """
    if not os.path.exists(wav_path):
        return None

    # Check if extraction is actually needed
    # (take_offset very small = item starts at the beginning of its file)
    OFFSET_THRESHOLD = 0.05   # seconds — treat anything < 50ms as "starts at 0"

    if take_offset < OFFSET_THRESHOLD:
        # Item starts at the beginning of the source file.
        # But if the clip is much shorter than the file (e.g. the first
        # Dynamic Split segment), we still need to extract just that slice.
        needs_extract = False
        file_duration = None
        if HAS_SOUNDFILE:
            try:
                with sf.SoundFile(wav_path) as f:
                    file_duration = f.frames / f.samplerate
            except Exception:
                pass
        else:
            # No soundfile — probe duration with the stdlib (PCM WAV only).
            file_duration = _wav_duration(wav_path)
        if file_duration is not None:
            if duration < file_duration - OFFSET_THRESHOLD:
                needs_extract = True
        else:
            # Unknown duration (non-WAV and no soundfile) — assume a slice
            # is needed so we don't transcribe the whole file by accident.
            needs_extract = True

        if needs_extract:
            temp_path = os.path.join(
                get_temp_dir(),
                f"chunk_{item_id:04d}.wav"
            )
            try:
                return _extract_slice(wav_path, 0.0, duration, temp_path)
            except Exception as e:
                print(f"    [WARN] Could not extract first chunk for item {item_id}: {e}")
                print(f"    [WARN] Falling back to full source file (accuracy may suffer)")
                report_problem(
                    "ERROR", "SLICE_FAILED",
                    f"Could not cut item {item_id} out of "
                    f"{os.path.basename(wav_path)} ({e}). The WHOLE file was "
                    f"transcribed instead, so this clip's text is wrong.",
                    once_key=("SLICE_FAILED", wav_path))
        return wav_path

    # Need to extract the slice
    temp_path = os.path.join(
        get_temp_dir(),
        f"chunk_{item_id:04d}.wav"
    )

    try:
        return _extract_slice(wav_path, take_offset, duration, temp_path)
    except Exception as e:
        print(f"    [WARN] Could not extract chunk for item {item_id}: {e}")
        print(f"    [WARN] Falling back to full source file (accuracy may suffer)")
        report_problem(
            "ERROR", "SLICE_FAILED",
            f"Could not cut clips out of {os.path.basename(wav_path)} ({e}). "
            f"The WHOLE file was transcribed for every affected clip, so their "
            f"text is identical and matching cannot work. Convert the track's "
            f"media to .wav, or install ffmpeg.",
            once_key=("SLICE_FAILED", wav_path))
        return wav_path


# ═══════════════════════════════════════════════════════════
# ElevenLabs Scribe v2 (Speech-to-Text API)
# Best accuracy for Indian languages (Hindi 5-10% WER,
# Nepali 3.1% WER). Paid: ~$0.22/hour of audio.
# Get API key at elevenlabs.io
# ═══════════════════════════════════════════════════════════

def _multipart_encode(fields, files):
    """Encode multipart/form-data without the requests library."""
    boundary = os.urandom(16).hex()
    body = b""
    for key, value in fields.items():
        body += f"--{boundary}\r\n".encode()
        body += f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode()
        body += f"{value}\r\n".encode()
    for key, (filename, data, content_type) in files.items():
        body += f"--{boundary}\r\n".encode()
        body += (f'Content-Disposition: form-data; name="{key}"; '
                 f'filename="{filename}"\r\n').encode()
        body += f"Content-Type: {content_type}\r\n\r\n".encode()
        body += data
        body += b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    return body, f"multipart/form-data; boundary={boundary}"


def transcribe_elevenlabs(audio_path, language, api_key):
    """
    Transcribe audio using ElevenLabs Scribe v2.
    Returns same dict shape as transcribe():
      {"text": str, "speech_start": float, "speech_end": float}

    NOTE: ElevenLabs Scribe does transcription only, NOT translation.
    For dub items it returns native-language text. The hybrid fallback
    will handle matching via duration+position when word overlap = 0.
    However, speech_start from ElevenLabs word timestamps is very
    accurate — this improves silence correction alignment.
    """
    empty = {"text": "", "speech_start": 0.0, "speech_end": 0.0}

    try:
        with open(audio_path, "rb") as f:
            audio_data = f.read()
    except Exception as e:
        print(f"    [11LABS] Could not read audio: {e}")
        return empty

    # Build multipart request.
    # Default: omit language_code so Scribe auto-detects (usually most
    # accurate). With SYNC_ELEVENLABS_FORCE_LANG=1 we pass the known
    # language_code — fixes misdetection (e.g. Kannada read as Nepali/Hindi).
    fields = {
        "model_id": "scribe_v2",
        "tag_audio_events": "false",
        "timestamps_granularity": "word",
    }
    if _ELEVENLABS_FORCE_LANG and language and language.lower() not in ("auto", "und", ""):
        fields["language_code"] = language
        print(f"    [11LABS] forcing language_code={language}")

    if _USE_PROXY:
        status, result = _proxy_post(
            "/v1/elevenlabs/stt",
            multipart=(fields, (os.path.basename(audio_path), audio_data, "audio/wav")),
            timeout=120,
        )
        if not result:
            return empty
    else:
        files = {
            "file": (os.path.basename(audio_path), audio_data, "audio/wav")
        }
        body, content_type = _multipart_encode(fields, files)

        req = urllib.request.Request(
            "https://api.elevenlabs.io/v1/speech-to-text",
            data=body,
            headers={
                "Content-Type": content_type,
                "xi-api-key": api_key,
            }
        )

        try:
            with _urlopen(req, timeout=120) as resp:
                result = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            err_body = ""
            try:
                err_body = e.read().decode()[:200]
            except Exception:
                pass
            print(f"    [11LABS] HTTP {e.code}: {e.reason} — {err_body}")
            return empty
        except Exception as e:
            print(f"    [11LABS] Error: {e}")
            return empty

    text = result.get("text", "")
    words = result.get("words", [])

    # Extract speech_start and speech_end from word-level timestamps
    speech_start = 0.0
    speech_end   = 0.0
    if words:
        speech_start = words[0].get("start", 0.0)
        speech_end   = words[-1].get("end", 0.0)

    print(f"    [11LABS] \"{text[:70]}\"")
    if words:
        print(f"    [11LABS] speech: {speech_start:.2f}s – {speech_end:.2f}s "
              f"({len(words)} words)")

    return {
        "text": text,
        "speech_start": speech_start,
        "speech_end": speech_end,
    }


# ═══════════════════════════════════════════════════════════
# Gemini audio transcription (gemini-2.5-flash supports audio input)
# Free tier at aistudio.google.com, or Vertex via vertex_key.json.
# ═══════════════════════════════════════════════════════════

_AUDIO_MIME = {
    ".wav": "audio/wav", ".mp3": "audio/mpeg", ".m4a": "audio/mp4",
    ".flac": "audio/flac", ".ogg": "audio/ogg", ".aac": "audio/aac",
    ".aiff": "audio/aiff", ".aif": "audio/aiff",
}

def _audio_mime(path):
    return _AUDIO_MIME.get(Path(path).suffix.lower(), "audio/wav")

def transcribe_gemini_audio(audio_path, language, api_key):
    """Transcribe audio using Gemini's multimodal audio understanding.
    Prefers Vertex AI (vertex_key.json) over the REST API key when available."""
    empty = {"text": "", "speech_start": 0.0, "speech_end": 0.0}
    try:
        with open(audio_path, "rb") as f:
            audio_data = f.read()
    except Exception as e:
        print(f"    [GEMINI-STT] Could not read audio: {e}")
        return empty

    if _USE_PROXY:
        status, result = _proxy_post(
            "/v1/gemini/stt",
            multipart=({"language": language or ""},
                       (os.path.basename(audio_path), audio_data, _audio_mime(audio_path))),
            timeout=180,
        )
        text = (result or {}).get("text", "").strip() if result else ""
        if text:
            print(f"    [GEMINI-STT/proxy] \"{text[:70]}\"")
        return {"text": text, "speech_start": 0.0, "speech_end": 0.0}

    prompt = (
        f"Transcribe this audio in its original language ({language or 'auto'}). "
        f"Return ONLY the transcript text — no timestamps, no commentary, no quotation marks."
    )

    # ── Path 1: Vertex AI SDK ──────────────────────────────
    vclient = _get_vertex_client()
    if vclient is not None:
        try:
            from google.genai import types as _gtypes
            audio_part = _gtypes.Part.from_bytes(
                data=audio_data, mime_type=_audio_mime(audio_path)
            )
            resp = vclient.models.generate_content(
                model=_GEMINI_AUDIO_MODEL,
                contents=[prompt, audio_part],
            )
            text = (resp.text or "").strip()
            print(f"    [GEMINI-STT/Vertex] \"{text[:70]}\"")
            return {"text": text, "speech_start": 0.0, "speech_end": 0.0}
        except Exception as e:
            print(f"    [GEMINI-STT/Vertex] Error: {e} — falling back to REST")

    # ── Path 2: REST fallback ──────────────────────────────
    if not api_key:
        print("    [GEMINI-STT] No api_key for REST fallback")
        return empty

    payload = {
        "contents": [{
            "parts": [
                {"text": prompt},
                {"inline_data": {
                    "mime_type": _audio_mime(audio_path),
                    "data": base64.b64encode(audio_data).decode("ascii"),
                }},
            ]
        }],
        "generationConfig": {"temperature": 0.0},
    }
    data = json.dumps(payload).encode("utf-8")
    url = (f"https://generativelanguage.googleapis.com/v1beta/models/"
           f"{_GEMINI_AUDIO_MODEL}:generateContent?key={api_key}")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}
    )
    try:
        with _urlopen(req, timeout=180) as resp:
            result = json.loads(resp.read())
        text = result["candidates"][0]["content"]["parts"][0]["text"].strip()
        print(f"    [GEMINI-STT/REST] \"{text[:70]}\"")
        return {"text": text, "speech_start": 0.0, "speech_end": 0.0}
    except urllib.error.HTTPError as e:
        err = ""
        try:
            err = e.read().decode()[:200]
        except Exception:
            pass
        print(f"    [GEMINI-STT/REST] HTTP {e.code}: {e.reason} — {err}")
        return empty
    except Exception as e:
        print(f"    [GEMINI-STT/REST] Error: {e}")
        return empty


# ═══════════════════════════════════════════════════════════
# Gemini Flash translation (text → English)
# Used after ElevenLabs transcribes native audio to text.
# Gemini translates that native text to English for word
# overlap matching.
# Free tier available at aistudio.google.com
# ═══════════════════════════════════════════════════════════

def translate_gemini(text, source_lang, api_key, model="gemini-3-flash-preview"):
    """
    Translate native-language text to English using Gemini Flash.
    Returns English string, or empty string on failure.

    Tries multiple model names / API versions automatically so a 404
    on one model does not silently kill all translations.
    """
    if not text or not text.strip():
        return ""

    if _USE_PROXY:
        status, result = _proxy_post(
            "/v1/translate",
            json_body={"text": text, "source_lang": source_lang, "model": model},
            timeout=30,
        )
        return (result or {}).get("text", "").strip() if result else ""

    prompt = (
        f"Translate the following {source_lang} text to English. "
        f"Return ONLY the English translation, nothing else.\n\n{text}"
    )

    # Gateway backend: the key is an OpenAI-style Bearer token, which Google's
    # native endpoint rejects with HTTP 400 — so route translation through the
    # gateway too, same as matching.
    if _GEMINI_BACKEND == "gateway" or (_GEMINI_BACKEND == "auto" and _GEMINI_BASE_URL):
        out = _call_gemini_gateway(prompt, api_key, _GEMINI_BASE_URL,
                                   _GEMINI_MATCHER_MODEL, temperature=0.1)
        if out is not None:
            return out
        if _GEMINI_BACKEND == "gateway":
            return ""   # explicit gateway choice — never fall through to Google

    payload = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"maxOutputTokens": 256, "temperature": 0.1},
    }
    data = json.dumps(payload).encode("utf-8")

    # Try the requested model first, then current fallback names
    base = "https://generativelanguage.googleapis.com"
    candidates_to_try = [
        f"{base}/v1beta/models/{model}:generateContent?key={api_key}",
        f"{base}/v1beta/models/gemini-2.0-flash:generateContent?key={api_key}",
        f"{base}/v1beta/models/gemini-2.0-flash-lite:generateContent?key={api_key}",
    ]
    # deduplicate while preserving order
    seen = set()
    urls_to_try = []
    for u in candidates_to_try:
        if u not in seen:
            seen.add(u)
            urls_to_try.append(u)

    for url in urls_to_try:
        req = urllib.request.Request(
            url, data=data, headers={"Content-Type": "application/json"}
        )
        try:
            with _urlopen(req, timeout=15) as resp:
                result = json.loads(resp.read())
            translated = (
                result["candidates"][0]["content"]["parts"][0]["text"].strip()
            )
            return translated
        except urllib.error.HTTPError as e:
            err_detail = ""
            try:
                err_detail = e.read().decode()[:120]
            except Exception:
                pass
            if e.code == 404:
                print(f"    [GEMINI] 404 on {url.split('/models/')[1].split(':')[0]} — trying next model...")
                continue   # try the next URL
            print(f"    [GEMINI] HTTP {e.code}: {e.reason} — {err_detail}")
            return ""
        except Exception as e:
            print(f"    [GEMINI] Error: {e}")
            return ""

    print("    [GEMINI] All model variants returned 404 — check your API key at aistudio.google.com")
    return ""


# ═══════════════════════════════════════════════════════════
# Gemini semantic matching — ONE API call matches all clips
# ═══════════════════════════════════════════════════════════

# Module-level matcher response cache (prompt-hash -> raw text).
# Populated/restored by TranscriptCache so re-runs skip the model entirely.
_GEMINI_RESPONSE_CACHE = {}

def _matcher_cache_key(provider, prompt_text):
    h = hashlib.sha256(prompt_text.encode("utf-8")).hexdigest()[:24]
    return f"{provider}__{h}"


def _invalidate_matcher_cache(prompt_text, cache):
    """Purge the cached matcher response for this prompt from BOTH the
    in-memory dict and the persistent disk cache.

    _call_gemini caches raw response text before anyone validates it as JSON.
    If the response turns out to be garbage (an error object, an HTML page
    from a misconfigured gateway, a truncated reply), leaving it cached means
    every future run replays the same failure from sync_cache.json. Callers
    that fail to parse a response MUST call this before erroring out."""
    prov = (_MATCHER_PROVIDER or "gemini").lower()
    if prov not in ("openai", "anthropic"):
        prov = "gemini"
    key = _matcher_cache_key(prov, prompt_text)
    _GEMINI_RESPONSE_CACHE.pop(key, None)
    if cache is not None:
        try:
            cache.delete_raw(key)
        except Exception:
            pass


# ─── Default model names (override via env if you want) ──────────────
_OPENAI_MATCHER_MODEL    = os.environ.get("SYNC_OPENAI_MODEL",    "gpt-4o")
_ANTHROPIC_MATCHER_MODEL = os.environ.get("SYNC_ANTHROPIC_MODEL", "claude-sonnet-4-5")


def _call_openai_chat(prompt_text, api_key, model=None, cache=None):
    """Send prompt to OpenAI Chat Completions; return raw text or None."""
    model = model or _OPENAI_MATCHER_MODEL
    cache_key = _matcher_cache_key("openai", prompt_text)
    if cache_key in _GEMINI_RESPONSE_CACHE:
        print(f"    [OPENAI CACHE HIT] {len(prompt_text)} chars")
        return _GEMINI_RESPONSE_CACHE[cache_key]
    if cache is not None:
        cached = cache.get_raw(cache_key)
        if cached:
            _GEMINI_RESPONSE_CACHE[cache_key] = cached
            print(f"    [OPENAI CACHE HIT] {len(prompt_text)} chars (disk)")
            return cached
    if _USE_PROXY:
        status, result = _proxy_post(
            "/v1/match",
            json_body={"provider": "openai", "prompt": prompt_text, "model": model},
            timeout=180,
        )
        text = (result or {}).get("text", "").strip() if result else ""
        if text:
            _GEMINI_RESPONSE_CACHE[cache_key] = text
            if cache is not None:
                cache.set_raw(cache_key, text)
        return text or None
    if not api_key:
        print("    [OPENAI] No api_key configured for matcher")
        return None

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt_text}],
        "temperature": 0.1,
        "response_format": {"type": "json_object"},
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
    )
    try:
        t0 = time.time()
        print(f"    [OPENAI] Sending {len(prompt_text)} chars to {model}…")
        with _urlopen(req, timeout=180) as resp:
            result = json.loads(resp.read())
        text = result["choices"][0]["message"]["content"].strip()
        print(f"    [OPENAI] Got {len(text)} chars in {time.time()-t0:.1f}s")
        if text:
            _GEMINI_RESPONSE_CACHE[cache_key] = text
            if cache is not None:
                cache.set_raw(cache_key, text)
        return text
    except urllib.error.HTTPError as e:
        err = ""
        try:
            err = e.read().decode()[:200]
        except Exception:
            pass
        print(f"    [OPENAI] HTTP {e.code}: {e.reason} — {err}")
        return None
    except Exception as e:
        print(f"    [OPENAI] Error: {e}")
        return None


def _call_anthropic_chat(prompt_text, api_key, model=None, cache=None):
    """Send prompt to Anthropic Messages API; return raw text or None."""
    model = model or _ANTHROPIC_MATCHER_MODEL
    cache_key = _matcher_cache_key("anthropic", prompt_text)
    if cache_key in _GEMINI_RESPONSE_CACHE:
        print(f"    [ANTHROPIC CACHE HIT] {len(prompt_text)} chars")
        return _GEMINI_RESPONSE_CACHE[cache_key]
    if cache is not None:
        cached = cache.get_raw(cache_key)
        if cached:
            _GEMINI_RESPONSE_CACHE[cache_key] = cached
            print(f"    [ANTHROPIC CACHE HIT] {len(prompt_text)} chars (disk)")
            return cached
    if _USE_PROXY:
        status, result = _proxy_post(
            "/v1/match",
            json_body={"provider": "anthropic", "prompt": prompt_text, "model": model},
            timeout=180,
        )
        text = (result or {}).get("text", "").strip() if result else ""
        if text:
            _GEMINI_RESPONSE_CACHE[cache_key] = text
            if cache is not None:
                cache.set_raw(cache_key, text)
        return text or None
    if not api_key:
        print("    [ANTHROPIC] No api_key configured for matcher")
        return None

    payload = {
        "model": model,
        "max_tokens": 8192,
        "temperature": 0.1,
        "messages": [{"role": "user", "content": prompt_text}],
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=data,
        headers={
            "Content-Type":      "application/json",
            "x-api-key":         api_key,
            "anthropic-version": "2023-06-01",
        },
    )
    try:
        t0 = time.time()
        print(f"    [ANTHROPIC] Sending {len(prompt_text)} chars to {model}…")
        with _urlopen(req, timeout=180) as resp:
            result = json.loads(resp.read())
        # Anthropic returns content as list of blocks
        blocks = result.get("content", [])
        text = "".join(b.get("text", "") for b in blocks if b.get("type") == "text").strip()
        print(f"    [ANTHROPIC] Got {len(text)} chars in {time.time()-t0:.1f}s")
        if text:
            _GEMINI_RESPONSE_CACHE[cache_key] = text
            if cache is not None:
                cache.set_raw(cache_key, text)
        return text
    except urllib.error.HTTPError as e:
        err = ""
        try:
            err = e.read().decode()[:200]
        except Exception:
            pass
        print(f"    [ANTHROPIC] HTTP {e.code}: {e.reason} — {err}")
        return None
    except Exception as e:
        print(f"    [ANTHROPIC] Error: {e}")
        return None


# Per-call provider selection — set by main() before matching starts.
# match_gemini() forwards matcher_provider down to _call_gemini via this var.
_MATCHER_PROVIDER = "gemini"
_OPENAI_KEY    = None
_ANTHROPIC_KEY = None


def _call_gemini_gateway(prompt_text, api_key, base_url, model, temperature=0.1):
    """Send the matcher prompt to an OpenAI-compatible gateway serving Gemini.

    POST {base_url}/v1/chat/completions with `Authorization: Bearer <api_key>`.
    Returns the assistant text, or None on failure. Routes through _urlopen so
    it inherits the same TLS-inspection handling as every other call. No
    response_format is forced — not all gateways accept it; the prompt already
    asks for JSON and the callers strip ``` fences.
    """
    if not base_url:
        print("    [GATEWAY] backend=gateway but no gateway URL set "
              "(SYNC_GEMINI_BASE_URL) — aborting")
        return None
    if not api_key:
        print("    [GATEWAY] backend=gateway needs a Bearer key "
              "(your gateway/Gemini key) — aborting")
        return None

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt_text}],
        "temperature": temperature,
    }
    data = json.dumps(payload).encode("utf-8")
    urls = _gateway_urls(base_url)
    for i, url in enumerate(urls):
        req = urllib.request.Request(
            url, data=data,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {api_key}",
                # Gateways behind Cloudflare reject the default
                # "Python-urllib/x.y" agent outright (403, "error code: 1010"),
                # so send a browser one. Override: SYNC_HTTP_USER_AGENT.
                "User-Agent": _HTTP_USER_AGENT,
            },
        )
        try:
            t0 = time.time()
            print(f"    [GATEWAY] Sending {len(prompt_text)} chars to {model} "
                  f"via {url}…")
            with _urlopen(req, timeout=180) as resp:
                result = json.loads(resp.read())
            text = (result["choices"][0]["message"]["content"] or "").strip()
            print(f"    [GATEWAY] Got {len(text)} chars in {time.time()-t0:.1f}s")
            return text or None
        except urllib.error.HTTPError as e:
            err = ""
            try:
                err = e.read().decode(errors="replace")[:200]
            except Exception:
                pass
            # An unversioned base can be a proxy mounted on a sub-path; retry
            # the versioned shape once when the endpoint simply isn't there.
            if e.code in (404, 405) and i + 1 < len(urls):
                print(f"    [GATEWAY] HTTP {e.code} at {url} — retrying "
                      f"{urls[i + 1]}")
                continue
            hint = ""
            if e.code == 403 and "1010" in err:
                hint = (" — Cloudflare is blocking this client's user-agent, not "
                        "your key; set SYNC_HTTP_USER_AGENT to override it")
            print(f"    [GATEWAY] HTTP {e.code}: {e.reason} — {err}{hint}")
            return None
        except Exception as e:
            print(f"    [GATEWAY] Error: {e}")
            return None


def _call_gemini(prompt_text, api_key, model="gemini-2.5-pro",
                 temperature=0.1, cache=None):
    """
    Dispatcher: routes the prompt to the configured matcher provider.
    The function name is kept for backwards compatibility with existing
    callers (_call_gemini_sections / _gemini_batched_pairs).

    Provider routing:
      - "gemini"     -> Vertex AI (vertex_key.json) → REST fallback
      - "openai"     -> OpenAI Chat Completions
      - "anthropic"  -> Anthropic Messages
    """
    provider = (_MATCHER_PROVIDER or "gemini").lower()
    if provider == "openai":
        return _call_openai_chat(prompt_text, _OPENAI_KEY, cache=cache)
    if provider == "anthropic":
        return _call_anthropic_chat(prompt_text, _ANTHROPIC_KEY, cache=cache)

    # ── Default: Gemini path ─────────────────────────────────
    cache_key = _matcher_cache_key("gemini", prompt_text)
    if cache_key in _GEMINI_RESPONSE_CACHE:
        print(f"    [GEMINI CACHE HIT] {len(prompt_text)} chars")
        return _GEMINI_RESPONSE_CACHE[cache_key]
    if cache is not None:
        cached = cache.get_raw(cache_key)
        if cached:
            _GEMINI_RESPONSE_CACHE[cache_key] = cached
            print(f"    [GEMINI CACHE HIT] {len(prompt_text)} chars (disk)")
            return cached

    if _USE_PROXY:
        status, result = _proxy_post(
            "/v1/match",
            json_body={"provider": "gemini", "prompt": prompt_text,
                       "model": _GEMINI_MATCHER_MODEL},
            timeout=180,
        )
        text = (result or {}).get("text", "").strip() if result else ""
        if text:
            _GEMINI_RESPONSE_CACHE[cache_key] = text
            if cache is not None:
                cache.set_raw(cache_key, text)
        return text or None

    # ── Path 0: OpenAI-compatible gateway ─────────────────────
    # Used when backend == "gateway", or "auto" with a gateway URL configured.
    # Routes Gemini through {base}/v1/chat/completions (Bearer key) instead of
    # Google's native API or Vertex.
    if _GEMINI_BACKEND == "gateway" or (_GEMINI_BACKEND == "auto" and _GEMINI_BASE_URL):
        text = _call_gemini_gateway(prompt_text, api_key, _GEMINI_BASE_URL,
                                    _GEMINI_MATCHER_MODEL, temperature)
        if text:
            _GEMINI_RESPONSE_CACHE[cache_key] = text
            if cache is not None:
                cache.set_raw(cache_key, text)
            return text
        # Explicit gateway choice must not silently fall through to Google.
        if _GEMINI_BACKEND == "gateway":
            print("    [GATEWAY] No response from gateway — aborting "
                  "(backend=gateway)")
            return None

    # ── Path 1: Vertex AI ─────────────────────────────────────
    # Skipped if backend == "rest"; required if backend == "vertex".
    vclient = _get_vertex_client()
    if vclient is not None:
        try:
            t0 = time.time()
            print(f"    [VERTEX] Sending {len(prompt_text)} chars to {_GEMINI_MATCHER_MODEL}…")
            resp = vclient.models.generate_content(
                model=_GEMINI_MATCHER_MODEL, contents=prompt_text
            )
            text = (resp.text or "").strip()
            print(f"    [VERTEX] Got {len(text)} chars in {time.time()-t0:.1f}s")
            if text:
                _GEMINI_RESPONSE_CACHE[cache_key] = text
                if cache is not None:
                    cache.set_raw(cache_key, text)
                return text
            print("    [VERTEX] Empty response")
        except Exception as e:
            print(f"    [VERTEX] Error: {e}")
        # An explicitly chosen backend is strict: vertex errors must surface,
        # not silently reroute to Google's REST endpoint with a different key.
        # (Only legacy backend=auto keeps the vertex→REST chain.)
        if _GEMINI_BACKEND == "vertex":
            print("    [VERTEX] backend=vertex is strict — not falling back "
                  "to REST")
            return None
        print(f"    [VERTEX] backend={_GEMINI_BACKEND} — falling back to REST")
    elif _GEMINI_BACKEND == "vertex":
        # User explicitly asked for Vertex but it isn't available — don't
        # silently fall through to REST.
        print("    [GEMINI] Backend=vertex but Vertex unavailable — aborting")
        return None

    # ── Path 2: REST fallback ────────────────────────────────
    if not api_key:
        print("    [GEMINI] No api_key for REST fallback — giving up")
        return None

    payload = {
        "contents": [{"parts": [{"text": prompt_text}]}],
        "generationConfig": {"temperature": temperature},
    }
    data = json.dumps(payload).encode("utf-8")

    base = "https://generativelanguage.googleapis.com"
    # Use the user's chosen matcher model first, then keep stable fallbacks.
    candidates_to_try = [
        f"{base}/v1beta/models/{_GEMINI_MATCHER_MODEL}:generateContent?key={api_key}",
        f"{base}/v1beta/models/gemini-2.5-pro:generateContent?key={api_key}",
        f"{base}/v1beta/models/gemini-2.5-flash:generateContent?key={api_key}",
    ]
    seen = set()
    urls = [u for u in candidates_to_try if not (u in seen or seen.add(u))]

    MAX_RETRIES = 3

    for url in urls:
        short_name = url.split("/models/")[1].split(":")[0]
        for attempt in range(1, MAX_RETRIES + 1):
            req = urllib.request.Request(
                url, data=data, headers={"Content-Type": "application/json"}
            )
            try:
                with _urlopen(req, timeout=180) as resp:
                    result = json.loads(resp.read())
                text = result["candidates"][0]["content"]["parts"][0]["text"].strip()
                if text:
                    _GEMINI_RESPONSE_CACHE[cache_key] = text
                    if cache is not None:
                        cache.set_raw(cache_key, text)
                return text
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    print(f"    [GEMINI] 404 on {short_name} — model not found, trying next...")
                    break  # try next URL, don't retry this one
                if e.code == 503:
                    # Overloaded — retry the same model with a short wait
                    wait = attempt * 15  # 15s, 30s, 45s
                    print(f"    [GEMINI] 503 on {short_name} "
                          f"(attempt {attempt}/{MAX_RETRIES}) — overloaded, retrying in {wait}s...")
                    if attempt < MAX_RETRIES:
                        time.sleep(wait)
                        continue
                    else:
                        print(f"    [GEMINI] 503 — giving up on {short_name}, trying next model...")
                        break  # exhausted retries, try next model
                if e.code in (429, 500):
                    # 429 = rate limit. Free tier = 15 RPM.
                    # Use longer waits: 30s / 60s / 90s.
                    wait = attempt * 30
                    err = ""
                    try:
                        err = e.read().decode()[:120]
                    except Exception:
                        pass
                    print(f"    [GEMINI] {e.code} on {short_name} "
                          f"(attempt {attempt}/{MAX_RETRIES}) — retrying in {wait}s...")
                    if attempt < MAX_RETRIES:
                        time.sleep(wait)
                        continue
                    else:
                        print(f"    [GEMINI] {e.code} — giving up on {short_name}, trying next model...")
                        break  # try next URL
                err = ""
                try:
                    err = e.read().decode()[:200]
                except Exception:
                    pass
                print(f"    [GEMINI] HTTP {e.code}: {e.reason} — {err}")
                return None
            except Exception as e:
                if "timed out" in str(e).lower() and attempt < MAX_RETRIES:
                    wait = attempt * 30
                    print(f"    [GEMINI] Timeout on {short_name} "
                          f"(attempt {attempt}/{MAX_RETRIES}) — retrying in {wait}s...")
                    time.sleep(wait)
                    continue
                if "timed out" in str(e).lower():
                    print(f"    [GEMINI] Timeout — giving up on {short_name}, trying next model...")
                    break  # try next URL
                print(f"    [GEMINI] Error: {e}")
                return None

    print("    [GEMINI] All model variants failed")
    return None


def _load_script_text(script_text=None, script_path=None):
    """Resolve dubbing-script text from inline string or file path."""
    if script_text and script_text.strip():
        return script_text.strip()
    if script_path:
        try:
            with open(script_path, "r", encoding="utf-8") as f:
                return f.read().strip()
        except Exception as e:
            print(f"  [SCRIPT] Could not read {script_path}: {e}")
    return None


def _call_gemini_sections(en_items, dub_items, dub_language, gemini_key,
                          script_text=None, cache=None):
    """
    Single-call sectioned grouping. Returns:
      (sections, unmatched_dub_ids, unmatched_en_ids)
    where sections is a list of {"en": [ids], "dub": [ids]}.
    Returns None on failure.
    """
    en_lines = [
        f"  EN[{i['id']}] @{i['position']:.2f}s ({i['duration']:.2f}s): "
        f"\"{(i.get('transcript') or '').strip()}\""
        for i in en_items
    ]
    dub_lines = [
        f"  DUB[{i['id']}] @{i['position']:.2f}s ({i['duration']:.2f}s): "
        f"\"{(i.get('transcript') or '').strip()}\""
        for i in dub_items
    ]

    if script_text:
        script_block = (
            "\n=== DUBBING SCRIPT (use punctuation as the chunk boundary hierarchy) ===\n"
            f"{script_text}\n\n"
            "Boundary hierarchy:\n"
            "  - Paragraph break  → topic change (always a section break)\n"
            "  - . ? !            → end of one thought\n"
            "  - ;                → connected continuation of a thought\n"
            "  - ,                → meaningful chunk inside a sentence (not list-commas)\n"
            "  - -                → additional info attached to the main idea\n"
            "Group EN and DUB clips so each section corresponds to one thought "
            "(sentence-level chunk) from the script.\n"
        )
    else:
        script_block = ""

    prompt = (
        "You are an audio-sync expert. Match dubbed clips to their English source clips by meaning.\n"
        "Group EN and DUB clip IDs into sections, where each section represents ONE thought.\n\n"
        "Return ONLY a single JSON object (no markdown, no commentary):\n"
        "{\n"
        '  "sections": [\n'
        '    {"en": [<id>,...], "dub": [<id>,...]},\n'
        "    ...\n"
        "  ],\n"
        '  "unmatched_dub": [<id>,...],\n'
        '  "unmatched_en":  [<id>,...]\n'
        "}\n\n"
        "Rules:\n"
        "1. Every EN id must appear exactly once (in a section OR unmatched_en).\n"
        "2. Every DUB id must appear exactly once (in a section OR unmatched_dub).\n"
        "3. Sections in chronological order by EN position.\n"
        "4. Group EN clips that finish one thought (e.g. a sentence split by silence detection).\n"
        "5. Group DUB clips that are multiple takes/parts of the same thought.\n"
        "6. If a DUB clip is silence/breath/has no transcript → unmatched_dub.\n"
        "7. Match by meaning, not exact words. Names of speakers (e.g. \"Sadhguru:\") in "
        "the DUB are not content — they go in unmatched_dub.\n"
        f"{script_block}"
        f"\n=== ENGLISH CLIPS ===\n{chr(10).join(en_lines)}\n"
        f"\n=== DUBBED CLIPS ({dub_language}) ===\n{chr(10).join(dub_lines)}\n\n"
        "JSON:"
    )

    print(f"  Sending {len(en_items)} EN + {len(dub_items)} DUB clips to Gemini "
          f"({len(prompt)} chars, script={'yes' if script_text else 'no'})")

    raw = _call_gemini(prompt, gemini_key, cache=cache)
    if not raw:
        return None

    cleaned = raw.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```\w*\n?", "", cleaned)
        cleaned = re.sub(r"\n?```$", "", cleaned)
        cleaned = cleaned.strip()

    parsed = None
    try:
        parsed = json.loads(cleaned)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", cleaned, re.DOTALL)
        if m:
            try:
                parsed = json.loads(m.group(0))
            except json.JSONDecodeError:
                parsed = None

    if not isinstance(parsed, dict):
        _invalidate_matcher_cache(prompt, cache)
        return None

    sections = parsed.get("sections") or []
    unmatched_dub = parsed.get("unmatched_dub") or []
    unmatched_en  = parsed.get("unmatched_en")  or []

    if not isinstance(sections, list):
        _invalidate_matcher_cache(prompt, cache)
        return None

    # Coerce ids to ints, drop malformed entries
    clean_sections = []
    for s in sections:
        if not isinstance(s, dict):
            continue
        en_ids  = [int(x) for x in (s.get("en")  or []) if isinstance(x, (int, float, str)) and str(x).lstrip("-").isdigit()]
        dub_ids = [int(x) for x in (s.get("dub") or []) if isinstance(x, (int, float, str)) and str(x).lstrip("-").isdigit()]
        if en_ids or dub_ids:
            clean_sections.append({"en": en_ids, "dub": dub_ids})

    unmatched_dub = [int(x) for x in unmatched_dub
                     if isinstance(x, (int, float, str)) and str(x).lstrip("-").isdigit()]
    unmatched_en  = [int(x) for x in unmatched_en
                     if isinstance(x, (int, float, str)) and str(x).lstrip("-").isdigit()]

    if not clean_sections:
        # A dict with zero usable sections — '{}', an {"error": ...} object
        # from a gateway/proxy, or entries under wrong keys — is a FAILED
        # response, NOT "every clip is unmatched". Treating it as success
        # used to skip the batched retry and emit an all-unmatched result
        # with exit code 0. Purge the cached response and report failure so
        # the caller retries (and hard-errors if that fails too).
        _invalidate_matcher_cache(prompt, cache)
        print("  [ERROR] Sectioned response contained no usable sections — "
              "treating as a failed call")
        return None

    return clean_sections, unmatched_dub, unmatched_en


def _pairs_to_sections(matches, dub_by_id, en_by_id):
    """
    Convert flat {dub, en} pair list (from batched fallback prompt) into
    grouped sections {en: [ids], dub: [ids]} + unmatched_dub list.
    Each EN id becomes one section containing all DUBs that map to it.
    """
    en_to_dubs = defaultdict(list)
    unmatched_dub_ids = []
    for pair in matches:
        dub_id = pair.get("dub")
        en_id  = pair.get("en")
        if dub_id is None or dub_id not in dub_by_id:
            continue
        if en_id is None or en_id not in en_by_id:
            unmatched_dub_ids.append(dub_id)
        else:
            en_to_dubs[en_id].append(dub_id)

    sections = [
        {"en": [en_id], "dub": dub_ids}
        for en_id, dub_ids in en_to_dubs.items()
    ]
    return sections, unmatched_dub_ids


# ─── Spring-based placer ──────────────────────────────────────
# Adapted from Translation_and_Syncing_App.py (_process_round +
# _process_overflow). Treats each EN-side group as a "section" with a
# slot bounded by min(EN.start) and max(EN.end), plus surrounding silence
# gaps that act as compressible springs. DUB items are placed back-to-back
# inside the section; if the total DUB content exceeds the slot, we extend
# into the gap_after, then both gaps, and finally overflow past the end of
# the original audio (so DUBs never collide with neighbouring sections).

_MIN_SPRING = 0.010   # 10ms anti-overlap
_SILENCE_CAP = 2.0    # max plausible speech-onset shift


#
#   2. RIGID GROUPS — DUB clips recorded less than _ISO_RIGID_GAP apart are
#      one breath. They move together, internal gaps preserved exactly, so
#      the artist's phrasing survives.
#
#   3. PLACEMENT — one global weighted isotonic regression over all blocks:
#         min Σ wᵢ(pᵢ − wantᵢ)²   s.t.  pᵢ₊₁ ≥ pᵢ + durᵢ + gapᵢ
#      Substituting qᵢ = pᵢ − Σⱼ<ᵢ(durⱼ+gapⱼ) turns the constraint into
#      qᵢ₊₁ ≥ qᵢ, so PAVA solves it exactly in O(n). Durations are never
#      touched — no time-stretching, ever. Unavoidable error is spread
#      smoothly across neighbours instead of being dumped on one clip or
#      resolved by deleting it.
#
# Tunables (env overrides, all seconds):
_ISO_RIGID_GAP   = float(os.environ.get("SYNC_RIGID_GAP",   "0.15"))
_ISO_PAUSE_KEEP  = float(os.environ.get("SYNC_PAUSE_KEEP",  "0.5"))
_ISO_PAUSE_FLOOR = float(os.environ.get("SYNC_PAUSE_FLOOR", "0.12"))
_ISO_PAUSE_MAX   = float(os.environ.get("SYNC_PAUSE_MAX",   "1.0"))

# Which placer runs. "isotonic" (default) or "spring" (the previous
# behaviour, kept intact for A/B). CLI --placer overrides this.
# ── v0.15.5: the whole Samanvaya-derived path is ONE opt-in switch ─────────
#
# Everything ported from Samanvaya — proportional placement, script-pivot
# matching, sub-splitting long English lines, the wrong-alphabet check and
# transcript normalisation — is off unless this says "new". "classic" is the
# behaviour that shipped before any of it existed, byte-for-byte: same placer,
# same matching, same transcripts.
#
# One switch and not five on purpose. The team is trialling this as a single
# alternative engine; five independent toggles would produce combinations
# nobody has run and make "it synced worse" impossible to attribute.
#
# The individual SYNC_PLACER / SYNC_MATCH_MODE variables below still work and
# still win when set, so one behaviour can be isolated for a single job.
_SYNC_ENGINE = (os.environ.get("SYNC_ENGINE") or "classic").strip().lower()
_NEW_ENGINE = _SYNC_ENGINE in ("new", "samanvaya", "isotonic")

_PLACER = (os.environ.get("SYNC_PLACER")
           or ("isotonic" if _NEW_ENGINE else "spring")).strip().lower()

# How correspondence is decided. "auto" pivots through the dubbing script when
# one is supplied and falls back to whole-clip model matching when it isn't;
# "script" refuses to fall back; "llm" is the old behaviour.
_MATCH_MODE = (os.environ.get("SYNC_MATCH_MODE")
               or ("auto" if _NEW_ENGINE else "llm")).strip().lower()

# Diagnostics from the last placement run, dumped next to the results file
# so tools/sync_metrics.py can score a run without re-calling any API.
_LAST_DIAG = {}


def _onset_abs(item):
    """Absolute timeline position of the first spoken word in an item."""
    dur = item.get("duration", 0.0) or 0.0
    ss  = item.get("speech_start") or 0.0
    if ss < 0.0 or ss > dur:
        ss = 0.0                      # nonsense from ASR — ignore it
    return item["position"] + ss


def _time_at_progress(spans, u):
    """Absolute time after consuming `u` seconds of speech across `spans`."""
    if u <= 0.0:
        return spans[0][0]
    for a, b in spans:
        length = b - a
        if u <= length:
            return a + u
        u -= length
    return spans[-1][1]


def _compute_targets(en_items, dub_items, sections):
    """dub_id → desired absolute speech-onset time on the EN timeline."""
    en_by_id  = {e["id"]: e for e in en_items}
    dub_by_id = {d["id"]: d for d in dub_items}
    targets = {}

    for sec in sections:
        en_ids = sorted((i for i in sec.get("en", []) if i in en_by_id),
                        key=lambda i: en_by_id[i]["position"])
        dub_ids = sorted((i for i in sec.get("dub", []) if i in dub_by_id),
                         key=lambda i: dub_by_id[i]["position"])
        if not en_ids or not dub_ids:
            continue

        # Equal counts → pair 1:1. The strongest signal a section can give.
        if len(en_ids) == len(dub_ids):
            for eid, did in zip(en_ids, dub_ids):
                targets[did] = _onset_abs(en_by_id[eid])
            continue

        # Otherwise spread the section's DUB speech proportionally over its
        # EN speech, skipping the silence between EN clips.
        spans = [(_onset_abs(en_by_id[i]),
                  en_by_id[i]["position"] + en_by_id[i]["duration"])
                 for i in en_ids]
        spans = [(a, b) for a, b in spans if b > a]
        if not spans:
            first = _onset_abs(en_by_id[en_ids[0]])
            for did in dub_ids:
                targets[did] = first
            continue

        len_en  = sum(b - a for a, b in spans)
        len_dub = sum(dub_by_id[d]["duration"] for d in dub_ids) or 1.0
        scale   = len_en / len_dub
        consumed = 0.0
        for did in dub_ids:
            targets[did] = _time_at_progress(spans, consumed * scale)
            consumed += dub_by_id[did]["duration"]

    return targets


def _pava(y, w):
    """Weighted isotonic regression by pool-adjacent-violators, O(n).

    Returns x minimising Σ wᵢ(xᵢ − yᵢ)² subject to x₁ ≤ x₂ ≤ … ≤ xₙ.
    """
    levels, weights, counts = [], [], []
    for yi, wi in zip(y, w):
        val, wt, cnt = yi, max(wi, 1e-9), 1
        while levels and levels[-1] > val:
            pv, pw, pc = levels.pop(), weights.pop(), counts.pop()
            val = (pv * pw + val * wt) / (pw + wt)
            wt += pw
            cnt += pc
        levels.append(val)
        weights.append(wt)
        counts.append(cnt)

    out = []
    for val, cnt in zip(levels, counts):
        out.extend([val] * cnt)
    return out


def _place_isotonic(en_items, dub_items, sections, unmatched_dub_ids,
                    en_total_duration):
    """Returns result dicts in the same shape as _place_with_springs()."""
    dub_by_id = {d["id"]: d for d in dub_items}
    en_idx_by_id = {e["id"]: i for i, e in enumerate(en_items)}

    targets = _compute_targets(en_items, dub_items, sections)

    # First EN id of each section, for the en_id/match fields downstream.
    first_en = {}
    for sec in sections:
        en_ids = [i for i in sec.get("en", []) if i in en_idx_by_id]
        if not en_ids:
            continue
        head = min(en_ids, key=lambda i: en_items[en_idx_by_id[i]]["position"])
        for did in sec.get("dub", []):
            if did in dub_by_id and did not in first_en:
                first_en[did] = head

    unmatched = {d for d in unmatched_dub_ids if d in dub_by_id}
    unmatched |= {d["id"] for d in dub_items
                  if d["id"] not in targets or d["id"] not in first_en}

    matched = sorted((d for d in dub_items if d["id"] not in unmatched),
                     key=lambda d: d["position"])

    print(f"  Targets built for {len(targets)} clips | "
          f"{len(matched)} to place, {len(unmatched)} unmatched")

    if not matched:
        print("  [WARN] Nothing to place — every clip is unmatched")
        return [{"dub_id": d["id"], "match": None, "score": 0,
                 "new_position": round(d["position"], 6),
                 "dub_duration": round(d["duration"], 6),
                 "status": "unmatched"} for d in dub_items]

    # ── 1. Rigid groups: one breath moves as one block ────────
    blocks = []
    for d in matched:
        if blocks and d["position"] - blocks[-1]["end_orig"] <= _ISO_RIGID_GAP:
            blk = blocks[-1]
            blk["members"].append(d)
            blk["end_orig"] = max(blk["end_orig"], d["position"] + d["duration"])
        else:
            blocks.append({
                "members":    [d],
                "start_orig": d["position"],
                "end_orig":   d["position"] + d["duration"],
            })

    for blk in blocks:
        blk["dur"] = blk["end_orig"] - blk["start_orig"]
        num = den = 0.0
        for m in blk["members"]:
            offset = _onset_abs(m) - blk["start_orig"]   # onset inside block
            wm = max(0.3, min(3.0, m["duration"]))
            num += wm * (targets[m["id"]] - offset)
            den += wm
        blk["want"] = num / den
        blk["w"]    = max(0.3, min(3.0, den))

    glued = len(matched) - len(blocks)
    print(f"  Rigid grouping: {len(matched)} clips → {len(blocks)} blocks "
          f"({glued} glued to a neighbour)")

    # ── 2. Minimum gap per block boundary, from the performance ─
    # Never demand more silence than the artist left, never less than the
    # floor, and never let a long pause hold the whole timeline hostage.
    gaps = []
    for i in range(len(blocks) - 1):
        orig = blocks[i + 1]["start_orig"] - blocks[i]["end_orig"]
        g = max(_ISO_PAUSE_FLOOR, min(orig * _ISO_PAUSE_KEEP, _ISO_PAUSE_MAX))
        gaps.append(max(0.0, min(g, orig)))

    # ── 3. Global solve ───────────────────────────────────────
    cum = [0.0]
    for i, blk in enumerate(blocks[:-1]):
        cum.append(cum[-1] + blk["dur"] + gaps[i])

    y = [blk["want"] - cum[i] for i, blk in enumerate(blocks)]
    w = [blk["w"] for blk in blocks]
    q = _pava(y, w)
    pos = [q[i] + cum[i] for i in range(len(blocks))]

    # Safety net: guarantee validity regardless of numerics. Should be a
    # no-op — a non-zero count here means something upstream is wrong.
    repairs = 0
    for i in range(len(blocks)):
        low = 0.0 if i == 0 else pos[i - 1] + blocks[i - 1]["dur"] + gaps[i - 1]
        if pos[i] < low - 1e-9:
            pos[i] = low
            repairs += 1
    if repairs:
        print(f"  [WARN] Forward repair touched {repairs} block(s)")

    # ── 4. Expand blocks back to clips ────────────────────────
    placements = {}
    for i, blk in enumerate(blocks):
        for m in blk["members"]:
            placements[m["id"]] = max(0.0, pos[i] + (m["position"] - blk["start_orig"]))

    # ── 5. Unmatched clips → Unsync track, near where they belong ─
    # The old placer stacked them from 0s, destroying any hint of where
    # they came from. Interpolating the matched warp puts each stray clip
    # beside the material it was recorded next to.
    warp_x, warp_y = [], []
    for m in matched:
        warp_x.append(_onset_abs(m))
        warp_y.append(placements[m["id"]] + (_onset_abs(m) - m["position"]))

    def _warp_at(x):
        if x <= warp_x[0]:
            return warp_y[0] + (x - warp_x[0])
        if x >= warp_x[-1]:
            return warp_y[-1] + (x - warp_x[-1])
        j = bisect.bisect_right(warp_x, x) - 1
        x0, x1 = warp_x[j], warp_x[j + 1]
        y0, y1 = warp_y[j], warp_y[j + 1]
        if x1 <= x0:
            return y0
        return y0 + (y1 - y0) * (x - x0) / (x1 - x0)

    unsync_positions = {}
    cursor = 0.0
    for d in sorted((dub_by_id[i] for i in unmatched), key=lambda d: d["position"]):
        want = _warp_at(_onset_abs(d)) - (_onset_abs(d) - d["position"])
        placed = max(0.0, want, cursor)
        unsync_positions[d["id"]] = placed
        cursor = placed + d["duration"] + _ISO_PAUSE_FLOOR

    # ── 6. Report ─────────────────────────────────────────────
    residuals = {}
    for did, p in placements.items():
        d = dub_by_id[did]
        residuals[did] = (p + (_onset_abs(d) - d["position"])) - targets[did]

    absr = sorted(abs(v) for v in residuals.values())

    def _pct(frac):
        return absr[min(len(absr) - 1, int(frac * len(absr)))] if absr else 0.0

    placed_gaps = []
    ordered = sorted(placements.items(), key=lambda kv: kv[1])
    for (a_id, a_pos), (b_id, b_pos) in zip(ordered, ordered[1:]):
        placed_gaps.append(b_pos - (a_pos + dub_by_id[a_id]["duration"]))

    print("\n  ── Isotonic placement ────────────────────────────────")
    print(f"  Onset error   : median {_pct(0.5):.3f}s  p90 {_pct(0.9):.3f}s  "
          f"max {absr[-1]:.3f}s")
    print(f"    within 250ms: {sum(1 for v in absr if v <= 0.25)}/{len(absr)}"
          f"  within 1s: {sum(1 for v in absr if v <= 1.0)}/{len(absr)}")
    if placed_gaps:
        tight = sum(1 for g in placed_gaps if g < 0.02)
        print(f"  Placed gaps   : {tight} under 20ms, "
              f"{sum(1 for g in placed_gaps if g < _ISO_PAUSE_FLOOR - 1e-6)} "
              f"under the {_ISO_PAUSE_FLOOR*1000:.0f}ms floor, "
              f"{sum(1 for g in placed_gaps if g < -1e-9)} overlapping")
    print(f"  Span          : {min(placements.values()):.1f}s – "
          f"{max(p + dub_by_id[i]['duration'] for i, p in placements.items()):.1f}s "
          f"(EN content ends {en_total_duration:.1f}s)")
    print(f"  Dropped clips : 0 (isotonic placement never deletes a clip)")

    worst = sorted(residuals.items(), key=lambda kv: -abs(kv[1]))[:15]
    if worst:
        print("\n  ── Tension report: worst 15 onset errors ─────────────")
        for did, r in worst:
            print(f"  DUB[{did:>4}] {r:+8.3f}s   placed {placements[did]:9.3f}s "
                  f"→ target {targets[did]:9.3f}s")

    _LAST_DIAG.update({
        "placer":    "isotonic",
        "targets":   {str(k): round(v, 6) for k, v in targets.items()},
        "residuals": {str(k): round(v, 6) for k, v in residuals.items()},
        "blocks":    len(blocks),
        "glued":     glued,
    })

    # ── 7. Results ────────────────────────────────────────────
    results = []
    for d in dub_items:
        did = d["id"]
        if did in placements:
            resid = residuals[did]
            results.append({
                "dub_id":       did,
                "en_id":        first_en[did],
                "match":        en_idx_by_id[first_en[did]],
                "score":        round(max(0.0, 1.0 - abs(resid) / 2.0), 4),
                "new_position": round(placements[did], 6),
                "target_onset": round(targets[did], 6),
                "residual":     round(resid, 6),
                "dub_duration": round(d["duration"], 6),
                "status":       "matched",
            })
        else:
            results.append({
                "dub_id":       did,
                "match":        None,
                "score":        0,
                "new_position": round(unsync_positions.get(did, d["position"]), 6),
                "dub_duration": round(d["duration"], 6),
                "status":       "unmatched",
            })
    return results


# ═══════════════════════════════════════════════════════════
# Indic text normalisation
# ═══════════════════════════════════════════════════════════
# ASR output, dubbing scripts and hand-typed text disagree on details that
# carry no meaning: precomposed vs base+nukta spellings, zero-width joiners,
# danda vs full stop, native vs ASCII digits. Any same-language text match
# fails on those cosmetics alone — and they add noise to the matcher prompt —
# so everything is folded to one form before it is compared or prompted with.
# The cache keeps the raw ASR text, so nothing is lost permanently.

# Zero-width and directional marks. They control Indic conjunct rendering but
# never change which words were spoken, which is all we compare on.
_ZERO_WIDTH_CPS = (0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2060, 0xFEFF,
                   0x00AD, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E)

# Precomposed nukta letters → base + combining nukta, so both spellings of
# one sound compare equal. NFC alone would leave the two forms different.
# Bengali য়/ড়/ঢ় and Devanagari क़/ज़/फ़ are the ones that matter in practice.
_NUKTA_FOLD = {
    "क़": "क़", "ख़": "ख़",
    "ग़": "ग़", "ज़": "ज़",
    "ड़": "ड़", "ढ़": "ढ़",
    "फ़": "फ़", "य़": "य़",
    "ড়": "ড়", "ঢ়": "ঢ়",
    "য়": "য়",
    "ਲ਼": "ਲ਼", "ਸ਼": "ਸ਼",
    "ਖ਼": "ਖ਼", "ਗ਼": "ਗ਼",
    "ਜ਼": "ਜ਼", "ਫ਼": "ਫ਼",
    "ଡ଼": "ଡ଼", "ଢ଼": "ଢ଼",
}

# Native digits → ASCII, keyed by each script's zero.
_DIGIT_FOLD = {
    chr(zero + d): chr(0x30 + d)
    for zero in (0x0966, 0x09E6, 0x0A66, 0x0AE6, 0x0B66, 0x0BE6, 0x0C66,
                 0x0CE6, 0x0D66, 0x0DE6, 0x0660, 0x06F0)
    for d in range(10)
}

# Punctuation that means the same thing as an ASCII mark. Danda in particular
# is a full stop — the matcher prompt treats '.' as a thought boundary, so it
# has to see one.
_PUNCT_FOLD = {
    "।": ".", "॥": ".", "۔": ".",
    "؟": "?", "،": ",", "؛": ";",
    "‘": "'", "’": "'", "“": '"', "”": '"',
    "–": "-", "—": "-",
}

_FOLD_TABLE = str.maketrans({
    **{chr(cp): "" for cp in _ZERO_WIDTH_CPS},
    **_NUKTA_FOLD, **_DIGIT_FOLD, **_PUNCT_FOLD,
})


def normalize_text(text, keep_lines=False):
    """Fold text to one canonical form for comparison and prompting.

    keep_lines=True preserves line and paragraph structure — use it for the
    dubbing script, where a blank line marks a topic change the matcher relies
    on. Everything else collapses to a single line.
    """
    if not text:
        return ""
    out = unicodedata.normalize("NFC", text).translate(_FOLD_TABLE)
    if not keep_lines:
        return re.sub(r"\s+", " ", out).strip()
    out = re.sub(r"[^\S\n]+", " ", out)
    out = "\n".join(line.strip() for line in out.split("\n"))
    return re.sub(r"\n{3,}", "\n\n", out).strip()


# ── Script detection, for catching a wrong language setting ──
_SCRIPT_BLOCKS = (
    ("devanagari", 0x0900, 0x097F),
    ("bengali",    0x0980, 0x09FF),
    ("gurmukhi",   0x0A00, 0x0A7F),
    ("gujarati",   0x0A80, 0x0AFF),
    ("oriya",      0x0B00, 0x0B7F),
    ("tamil",      0x0B80, 0x0BFF),
    ("telugu",     0x0C00, 0x0C7F),
    ("kannada",    0x0C80, 0x0CFF),
    ("malayalam",  0x0D00, 0x0D7F),
    ("sinhala",    0x0D80, 0x0DFF),
    ("arabic",     0x0600, 0x06FF),
    ("arabic",     0x0750, 0x077F),
    ("latin",      0x0041, 0x024F),
)

_LANG_SCRIPT = {
    "hi": "devanagari", "hin": "devanagari",
    "mr": "devanagari", "mar": "devanagari",
    "ne": "devanagari", "nep": "devanagari",
    "sa": "devanagari", "kok": "devanagari", "mai": "devanagari",
    "bn": "bengali", "ben": "bengali", "as": "bengali", "asm": "bengali",
    "pa": "gurmukhi", "pan": "gurmukhi",
    "gu": "gujarati", "guj": "gujarati",
    "or": "oriya",    "ori": "oriya",
    "ta": "tamil",    "tam": "tamil",
    "te": "telugu",   "tel": "telugu",
    "kn": "kannada",  "kan": "kannada",
    "ml": "malayalam", "mal": "malayalam",
    "si": "sinhala",
    "ur": "arabic", "urd": "arabic", "sd": "arabic", "ks": "arabic",
    "en": "latin", "eng": "latin",
}

# Codes are what the API wants; full names are what a human reading the log
# wants. Only ever used for printing — never for building requests.
_LANG_FULL_NAME = {
    "hi": "Hindi", "hin": "Hindi",
    "mr": "Marathi", "mar": "Marathi",
    "ne": "Nepali", "nep": "Nepali",
    "sa": "Sanskrit", "kok": "Konkani", "mai": "Maithili",
    "bn": "Bengali", "ben": "Bengali", "as": "Assamese", "asm": "Assamese",
    "pa": "Punjabi", "pan": "Punjabi",
    "gu": "Gujarati", "guj": "Gujarati",
    "or": "Odia", "ori": "Odia",
    "ta": "Tamil", "tam": "Tamil",
    "te": "Telugu", "tel": "Telugu",
    "kn": "Kannada", "kan": "Kannada",
    "ml": "Malayalam", "mal": "Malayalam",
    "si": "Sinhala",
    "ur": "Urdu", "urd": "Urdu", "sd": "Sindhi", "ks": "Kashmiri",
    "en": "English", "eng": "English",
}


def lang_full(code):
    """Full language name for a code, for display. Unknown codes pass through."""
    key = (code or "").strip().lower()
    if not key:
        return "?"
    return _LANG_FULL_NAME.get(key, code)


def _script_of(ch):
    cp = ord(ch)
    for name, lo, hi in _SCRIPT_BLOCKS:
        if lo <= cp <= hi:
            return name
    return None


def _dominant_script(text, ignore_latin=False):
    """Which script most of `text` is written in, or None."""
    counts = Counter()
    for ch in text or "":
        name = _script_of(ch)
        if name and not (ignore_latin and name == "latin"):
            counts[name] += 1
    return counts.most_common(1)[0][0] if counts else None


def _check_language(items, language, side):
    """Warn loudly when transcripts aren't in the script the language uses.

    That mismatch is the signature of a wrong language selection or an ASR
    misdetection. Either one produces plausible-looking text in the wrong
    language, which then matches badly with nothing to point at the cause.
    Latin loanwords are ignored — Indian-language dubs are full of them.
    """
    expected = _LANG_SCRIPT.get((language or "").strip().lower())
    if not expected or expected == "latin":
        return
    counts = Counter()
    for item in items:
        found = _dominant_script(item.get("transcript") or "", ignore_latin=True)
        if found:
            counts[found] += 1
    total = sum(counts.values())
    if total < 20:
        return                    # sample too small to conclude anything
    share = counts.get(expected, 0) / total
    if share >= 0.5:
        print(f"  [LANG] {side}: {share * 100:.0f}% of {total} transcripts are "
              f"{expected} — consistent with '{lang_full(language)}'")
        return
    top, n = counts.most_common(1)[0]
    bar = "!" * 62
    print(f"\n  {bar}")
    print(f"  [LANG] WRONG LANGUAGE? {side} was transcribed as "
          f"'{lang_full(language)}', "
          f"which uses the {expected} script,")
    print(f"         but only {share * 100:.0f}% of {total} transcripts are in "
          f"it — {top} dominates ({n}/{total}).")
    print("         Check the language selector. If it was wrong: fix it, "
          "delete sync_cache.json,")
    print("         and re-run — matching mis-transcribed text wastes the "
          "whole job.")
    print(f"  {bar}\n")
    # Surfaced in the panel too: a wrong language selector is the user's to
    # fix, and a warning only in the log file is a warning nobody sees.
    report_problem("WARN", "WRONG_LANGUAGE",
                   f"{side} was transcribed as '{lang_full(language)}' "
                   f"({expected} script) but only {share * 100:.0f}% of "
                   f"{total} transcripts are in it — {top} dominates "
                   f"({n}/{total}). Check the language selector, delete "
                   f"sync_cache.json and re-run.")


# ═══════════════════════════════════════════════════════════
# Script-pivot alignment
# ═══════════════════════════════════════════════════════════
# The dub artist read a script, in order. So did the English speaker. That
# makes correspondence a *sequence alignment* problem, and sequence alignment
# has exact algorithms — it does not need a model to pair 2000 clips freehand
# with no guarantee the answer is even in order.
#
# The pivot: the dubbed audio and the dubbing script are the SAME LANGUAGE.
# Aligning them is fuzzy same-language text matching, which is close to
# solved, and it hands us the script's thought boundaries mapped onto real
# clips. That removes the model from the dub side of grouping entirely — the
# side that produced a single 134-clip section. Only "which English clips say
# this sentence" still needs a model, and it now gets ~330 clean sentences
# instead of 1159 ASR fragments, with the result checked for monotonicity.

_UNIT_PARA, _UNIT_STOP, _UNIT_SEMI, _UNIT_COMMA, _UNIT_DASH = 0, 1, 2, 3, 4

# How deep into the boundary hierarchy to cut. 1 = paragraph + . ? ! ("one
# thought"), which is the granularity sections want. 2 adds ';', 3 adds ','.
_SCRIPT_UNIT_LEVEL = int(os.environ.get("SYNC_SCRIPT_UNIT_LEVEL", "1"))

# Alignment guards. The exact solver is only let loose on small gaps; bigger
# anchorless gaps are left unaligned rather than guessed at.
_ALIGN_EXACT_BUDGET = 40_000
_ALIGN_MAX_DEPTH = 80

# A clip needs this fraction of its words to land in a unit before we believe
# the assignment; below it the clip is still placed but flagged low-confidence.
_ALIGN_MIN_COVERAGE = float(os.environ.get("SYNC_ALIGN_MIN_COVERAGE", "0.34"))

_SPEAKER_RE = re.compile(r"^[^.?!]{1,40}:$")


def split_script_units(script_text, level=None):
    """Cut a dubbing script into thought units on its punctuation hierarchy.

    Follows the boundary rules the script was written with: a blank line is a
    topic change, `. ? !` end a thought, `;` continues one, `,` separates
    chunks inside it, `-` attaches extra detail. Speaker headings ("Sadhguru:")
    are labels, not speech, so they are dropped.

    Returns [{"id", "text", "level", "para"}] in reading order.
    """
    if not script_text:
        return []
    level = _SCRIPT_UNIT_LEVEL if level is None else level
    # Normalise here too, not just in _load_script_text: the boundary rules
    # below look for '.', and in an Indian-language script the full stop is a
    # danda. Splitting raw text would find no sentence ends at all.
    script_text = normalize_text(script_text, keep_lines=True)

    enders = ".?!"
    if level >= _UNIT_SEMI:
        enders += ";"
    if level >= _UNIT_COMMA:
        enders += ","

    units = []
    for para_idx, para in enumerate(re.split(r"\n\s*\n", script_text)):
        para = para.strip()
        if not para:
            continue
        # Speaker headings sit on their own line.
        lines = [ln.strip() for ln in para.split("\n")]
        lines = [ln for ln in lines if ln and not _SPEAKER_RE.match(ln)]
        if not lines:
            continue
        body = " ".join(lines)

        chunk, chunk_level = [], _UNIT_STOP
        for ch in body:
            chunk.append(ch)
            if ch in enders:
                text = "".join(chunk).strip()
                if text:
                    units.append({"id": len(units), "text": text,
                                  "level": _UNIT_STOP if ch in ".?!" else _UNIT_SEMI,
                                  "para": para_idx})
                chunk = []
        tail = "".join(chunk).strip()
        if tail:
            units.append({"id": len(units), "text": tail,
                          "level": chunk_level, "para": para_idx})

    # A unit with no words is punctuation debris.
    units = [u for u in units if _match_tokens(u["text"])]
    for i, u in enumerate(units):
        u["id"] = i
    return units


def _match_tokens(text):
    """Word tokens for text comparison: normalised, folded, punctuation-free.

    Not a `\\w+` regex. Python's `\\w` excludes combining marks (Unicode
    category M), and every Indic vowel sign is one — so `\\w+` shreds "शुरू"
    into "श", "र" and drops the rest. Marks have to count as word characters
    or the whole alignment is comparing rubble.
    """
    if not text:
        return []
    out, current = [], []
    for ch in normalize_text(text).lower():
        if ch.isalnum() or ch == "_" or unicodedata.category(ch)[0] == "M":
            current.append(ch)
        elif current:
            out.append("".join(current))
            current = []
    if current:
        out.append("".join(current))
    return out


def _lis_by_second(pairs, strict=True):
    """Longest subsequence of `pairs` (sorted by first) increasing in second.

    This is what makes the alignment monotone by construction instead of
    monotone by hope: anything that would need the timeline to run backwards
    simply isn't in the answer.

    strict=True requires the second coordinate to advance every step — right
    for token indices. strict=False allows repeats, which is right for clips
    sharing a unit: one sentence split across three clips is non-decreasing,
    not a violation.
    """
    if not pairs:
        return []
    tails, back = [], [-1] * len(pairs)
    for idx in range(len(pairs)):
        j = pairs[idx][1]
        lo, hi = 0, len(tails)
        while lo < hi:
            mid = (lo + hi) // 2
            tail_j = pairs[tails[mid]][1]
            if tail_j < j or (not strict and tail_j == j):
                lo = mid + 1
            else:
                hi = mid
        if lo:
            back[idx] = tails[lo - 1]
        if lo == len(tails):
            tails.append(idx)
        else:
            tails[lo] = idx
    out, k = [], tails[-1]
    while k != -1:
        out.append(pairs[k])
        k = back[k]
    out.reverse()
    return out


def _unique_anchor_pairs(a, b, lo_a, hi_a, lo_b, hi_b):
    """Pairs for values occurring exactly once on both sides of a subrange."""
    count_a, count_b = Counter(), Counter()
    for i in range(lo_a, hi_a):
        count_a[a[i]] += 1
    for j in range(lo_b, hi_b):
        count_b[b[j]] += 1
    once = {v for v, n in count_a.items() if n == 1 and count_b.get(v) == 1}
    if not once:
        return []
    where_b = {}
    for j in range(lo_b, hi_b):
        if b[j] in once:
            where_b[b[j]] = j
    return [(i, where_b[a[i]]) for i in range(lo_a, hi_a) if a[i] in once]


def _exact_pairs(a, b, lo_a, hi_a, lo_b, hi_b):
    """Exhaustive matching blocks for a small subrange."""
    matcher = difflib.SequenceMatcher(None, a[lo_a:hi_a], b[lo_b:hi_b],
                                      autojunk=False)
    out = []
    for i, j, size in matcher.get_matching_blocks():
        out.extend((lo_a + i + k, lo_b + j + k) for k in range(size))
    return out


def align_token_streams(a, b):
    """Monotone token alignment. Returns [(i, j)] increasing in both indices.

    Patience diff: anchor on words unique to both sides, keep the longest
    increasing chain of those anchors, recurse into the gaps, and solve small
    leftovers exhaustively. Near-linear on similar text, and where there is no
    evidence it returns nothing for that stretch rather than inventing a
    correspondence.
    """
    pairs = []

    def recurse(lo_a, hi_a, lo_b, hi_b, depth):
        if lo_a >= hi_a or lo_b >= hi_b or depth > _ALIGN_MAX_DEPTH:
            return
        anchors = _unique_anchor_pairs(a, b, lo_a, hi_a, lo_b, hi_b)
        if not anchors:
            if (hi_a - lo_a) * (hi_b - lo_b) <= _ALIGN_EXACT_BUDGET:
                pairs.extend(_exact_pairs(a, b, lo_a, hi_a, lo_b, hi_b))
            return
        prev_a, prev_b = lo_a, lo_b
        for i, j in _lis_by_second(anchors):
            recurse(prev_a, i, prev_b, j, depth + 1)
            pairs.append((i, j))
            prev_a, prev_b = i + 1, j + 1
        recurse(prev_a, hi_a, prev_b, hi_b, depth + 1)

    recurse(0, len(a), 0, len(b), 0)
    pairs.sort()
    return pairs


def align_clips_to_units(clips, units):
    """Assign each clip to the script unit it speaks. No model involved.

    `clips` must be in recording order. Returns
    {clip_id: {"unit": idx, "coverage": float}} plus a stats dict. Clips whose
    words align nowhere inherit the previous clip's unit at zero confidence —
    an ASR failure shouldn't cost the editor a clip.
    """
    script_tokens, token_unit = [], []
    for idx, unit in enumerate(units):
        for tok in _match_tokens(unit["text"]):
            script_tokens.append(tok)
            token_unit.append(idx)

    clip_tokens, token_clip, per_clip_total = [], [], Counter()
    for pos, clip in enumerate(clips):
        toks = _match_tokens(clip.get("transcript") or "")
        per_clip_total[pos] = len(toks)
        for tok in toks:
            clip_tokens.append(tok)
            token_clip.append(pos)

    stats = {
        "script_tokens": len(script_tokens),
        "clip_tokens": len(clip_tokens),
        "units": len(units),
    }
    if not script_tokens or not clip_tokens:
        return {}, stats

    pairs = align_token_streams(script_tokens, clip_tokens)
    stats["aligned_tokens"] = len(pairs)

    votes = defaultdict(Counter)
    for si, ci in pairs:
        votes[token_clip[ci]][token_unit[si]] += 1

    # Best unit per clip, then drop backward jumps: a clip that wants an
    # earlier unit than one already passed is a re-read, not a new line.
    proposed = []
    for pos in range(len(clips)):
        if votes[pos]:
            unit, hits = votes[pos].most_common(1)[0]
            proposed.append((pos, unit, hits / max(1, per_clip_total[pos])))
    kept = {pos for pos, _ in
            _lis_by_second([(pos, unit) for pos, unit, _ in proposed],
                           strict=False)}
    # Usually zero: align_token_streams is already monotone, so a re-read's
    # duplicate words find nothing to align to and the clip arrives here with
    # no votes at all (it gets carried below). This catches the rarer case
    # where a clip votes for an earlier unit outright.
    # NOTE: which take to keep is not decided here — both survive, one carried.
    stats["backward_dropped"] = len(proposed) - len(kept)

    assigned = {pos: (unit, coverage) for pos, unit, coverage in proposed
                if pos in kept}

    out, carried, last_unit = {}, 0, None
    for pos, clip in enumerate(clips):
        if pos in assigned:
            unit, coverage = assigned[pos]
            last_unit = unit
            out[clip["id"]] = {"unit": unit, "coverage": round(coverage, 4)}
        elif last_unit is not None:
            carried += 1
            out[clip["id"]] = {"unit": last_unit, "coverage": 0.0}
    stats["carried"] = carried
    stats["confident"] = sum(1 for v in out.values()
                             if v["coverage"] >= _ALIGN_MIN_COVERAGE)
    return out, stats


def _units_to_en_via_llm(units, en_items, dub_language, gemini_key, cache=None):
    """Ask the model which English clips speak each script unit.

    The one step that genuinely needs cross-lingual understanding. It gets
    complete sentences and a hard ordering rule, and the answer is checked for
    monotonicity afterwards rather than trusted.
    """
    unit_lines = [f"  U[{u['id']}]: \"{u['text']}\"" for u in units]
    en_lines = [
        f"  EN[{i['id']}] @{i['position']:.1f}s: \"{(i.get('transcript') or '').strip()}\""
        for i in en_items
    ]
    prompt = (
        "Align a dubbing script to the English source audio it was translated "
        "from.\n\n"
        f"SCRIPT UNITS are one thought each, in {dub_language}, in order.\n"
        "ENGLISH CLIPS are speech-recognised source audio, in order.\n"
        "For each script unit, list the English clip ids that say the same "
        "thing.\n\n"
        "Rules:\n"
        "1. Both lists are already in the same order — your assignment MUST be "
        "non-decreasing. Never send a later unit to an earlier clip.\n"
        "2. Each English clip belongs to at most one unit.\n"
        "3. A unit may take several clips (a sentence split by silence), or "
        "none — omit it if nothing matches.\n"
        "4. Match by meaning, not by words.\n\n"
        "Return ONLY this JSON, no markdown or commentary:\n"
        '{"map": [{"unit": <id>, "en": [<id>, ...]}, ...]}\n\n'
        f"=== SCRIPT UNITS ({dub_language}) ===\n{chr(10).join(unit_lines)}\n"
        f"\n=== ENGLISH CLIPS ===\n{chr(10).join(en_lines)}\n\nJSON:"
    )

    print(f"  Asking the matcher to place {len(units)} script units against "
          f"{len(en_items)} EN clips ({len(prompt)} chars)")
    raw = _call_gemini(prompt, gemini_key, cache=cache)
    if not raw:
        return None

    cleaned = raw.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```\w*\n?", "", cleaned)
        cleaned = re.sub(r"\n?```$", "", cleaned).strip()
    parsed = None
    try:
        parsed = json.loads(cleaned)
    except json.JSONDecodeError:
        found = re.search(r"\{.*\}", cleaned, re.DOTALL)
        if found:
            try:
                parsed = json.loads(found.group(0))
            except json.JSONDecodeError:
                parsed = None
    if not isinstance(parsed, dict) or not isinstance(parsed.get("map"), list):
        _invalidate_matcher_cache(prompt, cache)
        print("  [ERROR] Unit→EN reply was not usable JSON")
        return None

    valid_units = {u["id"] for u in units}
    valid_en = {e["id"] for e in en_items}
    raw_map, seen_en = {}, set()
    for row in parsed["map"]:
        if not isinstance(row, dict):
            continue
        try:
            unit = int(row.get("unit"))
        except (TypeError, ValueError):
            continue
        if unit not in valid_units:
            continue
        ids = []
        for x in row.get("en") or []:
            try:
                eid = int(x)
            except (TypeError, ValueError):
                continue
            if eid in valid_en and eid not in seen_en:
                seen_en.add(eid)
                ids.append(eid)
        if ids:
            raw_map.setdefault(unit, []).extend(sorted(ids))

    if not raw_map:
        _invalidate_matcher_cache(prompt, cache)
        print("  [ERROR] Unit→EN reply mapped nothing")
        return None

    # Monotonicity is a property of the material, so enforce it rather than
    # hoping. Keep the longest ordered chain and drop the rest.
    ordered = sorted(raw_map.items())
    chain = _lis_by_second([(u, max(ids)) for u, ids in ordered])
    keep = {u for u, _ in chain}
    dropped = len(ordered) - len(keep)
    if dropped:
        print(f"  [ORDER] Dropped {dropped} unit(s) whose EN assignment ran "
              f"backwards")
    return {u: ids for u, ids in ordered if u in keep}


def build_sections_via_script(en_items, dub_items, script_text, dub_language,
                             gemini_key, cache=None):
    """Sections built by pivoting through the dubbing script.

    Returns (sections, unmatched_dub_ids) or None to fall back.
    """
    units = split_script_units(script_text)
    if len(units) < 5:
        print(f"  [SCRIPT] Only {len(units)} usable units in the script — "
              "not enough to pivot on")
        return None

    dubs_in_order = sorted(dub_items, key=lambda d: d["position"])
    clip_unit, stats = align_clips_to_units(dubs_in_order, units)
    if not clip_unit:
        print("  [SCRIPT] Could not align the dub audio to the script")
        return None

    covered = len(clip_unit)
    print(f"  Script → dub alignment: {stats['units']} units, "
          f"{stats['aligned_tokens']}/{stats['clip_tokens']} dub words matched "
          f"({100.0 * stats['aligned_tokens'] / max(1, stats['clip_tokens']):.0f}%)")
    print(f"    {covered}/{len(dub_items)} clips assigned, "
          f"{stats['confident']} confidently, {stats['carried']} carried from a "
          f"neighbour, {stats['backward_dropped']} out-of-order")

    if stats["aligned_tokens"] < 0.25 * stats["clip_tokens"]:
        print("  [SCRIPT] Too little of the dub audio matches this script — "
              "wrong script for this recording? Falling back.")
        return None

    unit_to_dubs = defaultdict(list)
    for dub_id, info in clip_unit.items():
        unit_to_dubs[info["unit"]].append(dub_id)

    unit_to_en = _units_to_en_via_llm(units, en_items, dub_language,
                                      gemini_key, cache=cache)
    if not unit_to_en:
        return None
    print(f"  Units carrying EN clips: {len(unit_to_en)}/{len(units)}")

    # A unit with dub audio but no English of its own joins the nearest unit
    # that has some — never drop the clip for the model's omission.
    with_en = sorted(unit_to_en)
    merged = 0
    sections_by_unit = defaultdict(lambda: {"en": [], "dub": []})
    for unit in sorted(unit_to_dubs):
        if unit in unit_to_en:
            host = unit
        elif with_en:
            pos = bisect.bisect_left(with_en, unit)
            options = [p for p in (pos - 1, pos) if 0 <= p < len(with_en)]
            host = min((with_en[p] for p in options), key=lambda u: abs(u - unit))
            merged += 1
        else:
            continue
        sections_by_unit[host]["dub"].extend(unit_to_dubs[unit])
    for unit, ids in unit_to_en.items():
        sections_by_unit[unit]["en"].extend(ids)
    if merged:
        print(f"  {merged} unit(s) with no English of their own merged into a "
              f"neighbour")

    sections, placed_dubs = [], set()
    for unit in sorted(sections_by_unit):
        entry = sections_by_unit[unit]
        if not entry["en"] or not entry["dub"]:
            continue
        sections.append({"en": sorted(entry["en"]),
                         "dub": sorted(entry["dub"])})
        placed_dubs.update(entry["dub"])

    unmatched = [d["id"] for d in dub_items if d["id"] not in placed_dubs]
    if not sections:
        print("  [SCRIPT] Pivot produced no usable sections")
        return None

    sizes = sorted(len(s["dub"]) for s in sections)
    print(f"  Sections from the script: {len(sections)} "
          f"(median {sizes[len(sizes) // 2]} dub clips, max {sizes[-1]}), "
          f"{len(unmatched)} unmatched")
    return sections, unmatched


# ─── Sub-splitting over-long EN clips ─────────────────────────
# A silence-split that failed to cut leaves one enormous EN item — a real
# project had a single 352s clip that the matcher grouped 134 dub clips into.
# One clip means one anchor, so there is nothing inside those 352 seconds for
# the dub to aim at, and no placer can recover from that. Here we cut such a
# clip into virtual sub-items at the silences ASR actually found. The REAPER
# project is never touched; only the matcher's view of the EN track changes.
_EN_SPLIT_MAX_LEN = float(os.environ.get("SYNC_EN_MAX_LEN",       "12.0"))
_EN_SPLIT_MIN_GAP = float(os.environ.get("SYNC_EN_SPLIT_MIN_GAP", "0.30"))
_EN_SPLIT_MIN_LEN = float(os.environ.get("SYNC_EN_SPLIT_MIN_LEN", "1.50"))


def _clean_words(words):
    """Keep real words with usable timings, in time order.

    Scribe interleaves `spacing` and `audio_event` entries with the words;
    counting those as words would invent silences that aren't there.
    """
    out = []
    for w in words or []:
        if not isinstance(w, dict):
            continue
        if (w.get("type") or "word") != "word":
            continue
        text = (w.get("text") or "").strip()
        try:
            start, end = float(w["start"]), float(w["end"])
        except (KeyError, TypeError, ValueError):
            continue
        if not text or end < start:
            continue
        out.append({"text": text, "start": start, "end": end})
    out.sort(key=lambda w: w["start"])
    return out


def _split_words_into_segments(words, max_len, min_gap, min_len):
    """Cut a word stream at real silences.

    Returns [(first_word_idx, last_word_idx_exclusive), ...] covering every
    word. Recursively splits whatever is still longer than max_len at the
    best available silence — longest pause wins, ties broken by whichever is
    closest to the middle, so pieces come out balanced instead of ragged.
    Pieces shorter than min_len are never created.
    """
    n = len(words)
    if n == 0:
        return []

    candidates = []
    for i in range(1, n):
        gap = words[i]["start"] - words[i - 1]["end"]
        if gap >= min_gap:
            candidates.append((i, gap))
    if not candidates:
        return [(0, n)]

    def span(a, b):
        return words[b - 1]["end"] - words[a]["start"]

    pieces = [(0, n)]
    while True:
        out, split_any = [], False
        for a, b in pieces:
            if span(a, b) <= max_len:
                out.append((a, b))
                continue
            middle = (words[a]["start"] + words[b - 1]["end"]) / 2.0
            best_key = best_at = None
            for i, gap in candidates:
                if i <= a or i >= b:
                    continue
                if span(a, i) < min_len or span(i, b) < min_len:
                    continue
                # Cap the gap so any pause over a second counts as "a full
                # stop"; among those, balance decides.
                key = (-min(gap, 1.0), abs(words[i]["start"] - middle))
                if best_key is None or key < best_key:
                    best_key, best_at = key, i
            if best_at is None:
                out.append((a, b))
                continue
            out.append((a, best_at))
            out.append((best_at, b))
            split_any = True
        pieces = out
        if not split_any:
            return pieces


def _split_long_en_items(en_items, cache, asr_provider, elevenlabs_key,
                         gemini_key):
    """Replace EN items longer than _EN_SPLIT_MAX_LEN with virtual sub-items.

    Returns (en_items, n_added). Only the over-long clips are re-transcribed
    (with word timings), so this costs a handful of ASR calls, not a rerun.
    """
    long_items = [i for i in en_items
                  if (i.get("duration") or 0.0) > _EN_SPLIT_MAX_LEN]
    if not long_items:
        return en_items, 0

    print(f"\n  Sub-splitting {len(long_items)} EN clip(s) over "
          f"{_EN_SPLIT_MAX_LEN:.0f}s (longest "
          f"{max(i['duration'] for i in long_items):.0f}s)")

    next_id = max(i["id"] for i in en_items) + 1
    replaced = {}

    for item in long_items:
        label = f"    EN[{item['id']}] {item['duration']:.1f}s"
        audio = get_audio_for_item(item["id"], item["wav_path"],
                                   item.get("take_offset", 0.0),
                                   item.get("duration", 0.0))
        if not audio:
            print(f"{label} — audio unavailable, kept whole")
            continue

        result = transcribe(audio, task="transcribe_words", language="en",
                            cache=cache, asr_provider=asr_provider,
                            elevenlabs_key=elevenlabs_key,
                            gemini_key=gemini_key, keep_words=True)
        words = _clean_words(result.get("words"))
        if not words:
            print(f"{label} — ASR returned no word timings, kept whole")
            continue

        ranges = _split_words_into_segments(
            words, _EN_SPLIT_MAX_LEN, _EN_SPLIT_MIN_GAP, _EN_SPLIT_MIN_LEN)
        if len(ranges) <= 1:
            print(f"{label} — no silence long enough to cut on, kept whole")
            continue

        # Boundaries sit midway through each silence, so the pieces tile the
        # original exactly: no audio lost, no overlap.
        def boundary(idx):
            return (words[idx - 1]["end"] + words[idx]["start"]) / 2.0

        subs = []
        for k, (a, b) in enumerate(ranges):
            rel_start = 0.0 if k == 0 else boundary(a)
            rel_end = item["duration"] if k == len(ranges) - 1 else boundary(b)
            subs.append({
                "id":           next_id,
                "position":     item["position"] + rel_start,
                "duration":     max(0.05, rel_end - rel_start),
                "wav_path":     item["wav_path"],
                "take_offset":  item.get("take_offset", 0.0) + rel_start,
                "transcript":   normalize_text(" ".join(w["text"]
                                                        for w in words[a:b])),
                "speech_start": max(0.0, words[a]["start"] - rel_start),
                "virtual_from": item["id"],
            })
            next_id += 1

        replaced[item["id"]] = subs
        print(f"{label} → {len(subs)} pieces "
              f"({min(s['duration'] for s in subs):.1f}s–"
              f"{max(s['duration'] for s in subs):.1f}s, "
              f"{len(words)} words)")

    if not replaced:
        return en_items, 0

    out = []
    for item in en_items:
        out.extend(replaced.get(item["id"], [item]))
    out.sort(key=lambda i: i["position"])
    print(f"  EN clips: {len(en_items)} → {len(out)} "
          f"(+{len(out) - len(en_items)})")
    return out, len(out) - len(en_items)


def _place_with_springs(en_items, dub_items, sections, unmatched_dub_ids,
                        en_total_duration):
    """
    Returns a list of result dicts in the same shape as match_items().
    """
    en_by_id     = {e["id"]: e for e in en_items}
    dub_by_id    = {d["id"]: d for d in dub_items}
    en_idx_by_id = {e["id"]: i for i, e in enumerate(en_items)}

    # Build sections with timing + silence info
    secs = []
    for sec_no, sec in enumerate(sections, 1):
        en_ids  = [i for i in sec.get("en",  []) if i in en_by_id]
        dub_ids = [i for i in sec.get("dub", []) if i in dub_by_id]
        if not en_ids or not dub_ids:
            for d in dub_ids:
                if d not in unmatched_dub_ids:
                    unmatched_dub_ids.append(d)
            continue

        # Sort dub ids by their original position so multi-take order is preserved
        dub_ids.sort(key=lambda d: dub_by_id[d]["position"])
        en_ids.sort(key=lambda e: en_by_id[e]["position"])

        slot_start = min(en_by_id[i]["position"] for i in en_ids)
        slot_end   = max(en_by_id[i]["position"] + en_by_id[i]["duration"]
                         for i in en_ids)
        dub_total  = sum(dub_by_id[d]["duration"] for d in dub_ids)
        dub_content = dub_total + _MIN_SPRING * max(0, len(dub_ids) - 1)

        # Silence correction: shift slot so first DUB's speech onset lands on
        # first EN's speech onset.
        first_en  = en_by_id[en_ids[0]]
        first_dub = dub_by_id[dub_ids[0]]
        diff = first_en.get("speech_start", 0.0) - first_dub.get("speech_start", 0.0)
        if abs(diff) > _SILENCE_CAP:
            diff = 0.0

        secs.append({
            "no":           sec_no,
            "en_ids":       en_ids,
            "dub_ids":      dub_ids,
            "slot_start":   slot_start,
            "slot_end":     slot_end,
            "slot_length":  slot_end - slot_start,
            "dub_total":    dub_total,
            "dub_content":  dub_content,
            "silence_correction": diff,
        })

    # Sort by slot start, then compute neighbour gaps
    secs.sort(key=lambda s: s["slot_start"])
    for i, s in enumerate(secs):
        s["gap_before"] = max(0.0, s["slot_start"] - secs[i-1]["slot_end"]) if i > 0 else 0.0
        s["gap_after"]  = max(0.0, secs[i+1]["slot_start"] - s["slot_end"]) if i < len(secs)-1 else 0.0

    placements = {}     # dub_id -> position
    processed  = set()
    log_lines  = []

    def _place_seq(s, anchor):
        cursor = max(0.0, anchor)
        for did in s["dub_ids"]:
            placements[did] = cursor
            cursor += dub_by_id[did]["duration"] + _MIN_SPRING

    def _place_mtom_equal(s):
        en_starts = [en_by_id[eid]["position"] + s["silence_correction"]
                     for eid in s["en_ids"]]
        for did, en_start in zip(s["dub_ids"], en_starts):
            placements[did] = max(0.0, en_start)
        sorted_dubs = sorted(s["dub_ids"], key=lambda d: placements[d])
        for k in range(1, len(sorted_dubs)):
            prev_id = sorted_dubs[k-1]
            curr_id = sorted_dubs[k]
            prev_end = placements[prev_id] + dub_by_id[prev_id]["duration"]
            if placements[curr_id] < prev_end + _MIN_SPRING:
                placements[curr_id] = prev_end + _MIN_SPRING

    # 5 strategy rounds × 2 iterations (lets earlier sections free up slack
    # for later ones on the second pass).
    for iteration in (1, 2):
        for rnd in (1, 3, 5):
            for s in secs:
                if s["no"] in processed:
                    continue
                slot_start_eff = s["slot_start"] + s["silence_correction"]
                slot_end_eff   = s["slot_end"]   + s["silence_correction"]
                content        = s["dub_content"]
                strategy       = None

                if rnd == 1 and content <= s["slot_length"]:
                    if (len(s["en_ids"]) == len(s["dub_ids"])
                            and len(s["en_ids"]) > 1):
                        _place_mtom_equal(s)
                        strategy = "mtom_equal"
                    else:
                        center = (slot_start_eff + slot_end_eff) / 2.0
                        _place_seq(s, center - content / 2.0)
                        strategy = "center"
                elif rnd == 3 and content <= s["slot_length"] + s["gap_after"]:
                    _place_seq(s, slot_start_eff)
                    strategy = "align_start"
                elif rnd == 5 and content <= (s["slot_length"]
                                              + s["gap_before"]
                                              + s["gap_after"]
                                              + _MIN_SPRING):
                    target_end = slot_end_eff + s["gap_after"] - _MIN_SPRING
                    _place_seq(s, target_end - content)
                    strategy = "align_end"

                if strategy:
                    processed.add(s["no"])
                    log_lines.append(
                        f"  Sec {s['no']:>3} [iter{iteration} R{rnd} {strategy:<11}] "
                        f"slot=[{s['slot_start']:.2f}-{s['slot_end']:.2f}]s "
                        f"gap_b={s['gap_before']:.2f}s gap_a={s['gap_after']:.2f}s "
                        f"dub={s['dub_total']:.2f}s ({len(s['dub_ids'])} clips) "
                        f"sil={s['silence_correction']:+.3f}s"
                    )

    # For any section that didn't fit in rounds 1/3/5 (e.g. dub longer than EN
    # slot + surrounding gaps), ALWAYS fall back to align_start at the EN
    # position. Human-dubbed audio is often longer than English, so we must
    # never push clips past the end of the video — just let them bleed over
    # the next EN slot. The downstream anti-overlap pass will push forward
    # only if there is a real collision.
    for s in secs:
        if s["no"] in processed:
            continue
        slot_start_eff = s["slot_start"] + s["silence_correction"]
        _place_seq(s, max(0.0, slot_start_eff))
        processed.add(s["no"])
        log_lines.append(
            f"  Sec {s['no']:>3} [align_start_fallback] "
            f"slot=[{s['slot_start']:.2f}-{s['slot_end']:.2f}]s "
            f"dub={s['dub_total']:.2f}s (longer than available space — placed at slot start)"
        )

    # Print Spring placement log first
    print("\n  ── Spring placement log ──────────────────────────────")
    for line in log_lines:
        print(line)

    # ── Order-preserving DUB sweep ───────────────────────────────
    # Walk ALL dub items in their ORIGINAL recording order and
    # enforce: D1 < D2 < D3 < … always on the main (Dub) track.
    #
    # Rules agreed with user:
    #   • Each DUB tries to land at its Spring-computed position.
    #   • It is pushed forward to max(spring_pos, last_synced_end)
    #     so it never overlaps the previous synced clip.
    #   • LOOKAHEAD (Option C): if placing here would make this clip
    #     END after the next DUB's Spring position, there is no room
    #     → send this clip to Unsync instead.
    #   • Unsync clips do NOT advance last_synced_end (Option 6a):
    #     the next synced DUB ignores them when deciding its earliest
    #     allowed start.
    #   • Unsync clips DO advance last_any_end, which is used to
    #     position each Unsync clip right beside its predecessor on
    #     the Unsync track, preserving overall chronological order.

    # Sort dub_items by original recording position → DUB order
    dubs_in_order = sorted(dub_items, key=lambda d: d["position"])

    last_synced_end  = 0.0   # end of last SYNCED clip (Option 6a)
    last_any_end     = 0.0   # end of last ANY clip (Unsync positioning)
    unsync_positions = {}    # dub_id → new_position for Unsync clips
    order_pushes     = 0     # how many clips were pushed forward
    order_unsynced   = 0     # how many clips were sent to Unsync

    for i, dub in enumerate(dubs_in_order):
        did = dub["id"]
        dur = dub["duration"]

        if did not in placements:
            # Gemini already marked this DUB unmatched — place it on
            # the Unsync track right beside the previous clip.
            unsync_pos = max(last_any_end, 0.0)
            unsync_positions[did] = unsync_pos
            last_any_end = unsync_pos + dur
            continue

        spring_pos = placements[did]
        # Earliest this clip can start: never before the previous
        # synced clip ends.
        candidate     = max(spring_pos, last_synced_end)
        candidate_end = candidate + dur

        # Lookahead: find the next DUB that has a Spring placement.
        # Unmatched DUBs have no spring position, so we skip them.
        next_spring = float("inf")
        for j in range(i + 1, len(dubs_in_order)):
            nid = dubs_in_order[j]["id"]
            if nid in placements:
                next_spring = placements[nid]
                break

        if candidate_end > next_spring:
            # No room — this clip would crash into the next one.
            # Send it to Unsync, beside the previous DUB.
            unsync_pos = max(last_any_end, candidate)
            placements.pop(did)          # remove from main track
            unsync_positions[did] = unsync_pos
            last_any_end = unsync_pos + dur
            order_unsynced += 1
            print(f"  [ORDER] DUB[{did}] would end {candidate_end:.3f}s > "
                  f"next spring {next_spring:.3f}s → Unsync at {unsync_pos:.3f}s")
        else:
            # Fits — place here.
            if candidate > spring_pos + _MIN_SPRING:
                order_pushes += 1
                print(f"  [ORDER] DUB[{did}] pushed {spring_pos:.3f}s → "
                      f"{candidate:.3f}s to stay after prev clip")
            placements[did] = candidate
            last_synced_end  = candidate_end
            last_any_end     = candidate_end

    if order_pushes:
        print(f"\n  Order-preserving push fixes : {order_pushes}")
    if order_unsynced:
        print(f"  Order violations → Unsync   : {order_unsynced}")
        # These clips WERE matched correctly — they are taken off the Dub track
        # only because the dubbed audio is longer than the English slot. From
        # the timeline that is indistinguishable from "the sync threw my dub
        # away", so it must be reported rather than left in the log.
        report_problem(
            "WARN", "DROPPED_FOR_OVERFLOW",
            f"{order_unsynced} clip(s) were matched correctly but moved to the "
            f"Un sync track because the dubbed audio does not fit the English "
            f"slot (dub ids: "
            f"{', '.join(str(i) for i in sorted(unsync_positions))}).")
    if not order_pushes and not order_unsynced:
        print("\n  DUB order already correct — no fixes needed.")

    # ── Build per-DUB result records ─────────────────────────────
    # Unmatched clips now carry a new_position so the Lua can place
    # them on the Unsync track beside their neighbours (preserving
    # chronological order there too) instead of leaving them at their
    # original recording positions.
    sec_by_dub = {}
    for s in secs:
        for did in s["dub_ids"]:
            sec_by_dub[did] = s

    results = []
    for d in dub_items:
        did = d["id"]
        if did in placements:
            s = sec_by_dub[did]
            first_en_id = s["en_ids"][0]
            results.append({
                "dub_id":             did,
                "en_id":              first_en_id,
                "match":              en_idx_by_id[first_en_id],
                "score":              1.0,
                "new_position":       round(placements[did], 6),
                "silence_correction": round(s["silence_correction"], 6),
                "dub_duration":       round(d["duration"], 6),
                "status":             "matched",
            })
        else:
            # Use the order-sweep-computed Unsync position if available,
            # otherwise fall back to the clip's original position.
            unsync_pos = unsync_positions.get(did, d["position"])
            results.append({
                "dub_id":       did,
                "match":        None,
                "score":        0,
                "new_position": round(unsync_pos, 6),
                "dub_duration": round(d["duration"], 6),
                "status":       "unmatched",
            })

    return results


def match_gemini(en_items, dub_items, dub_language, gemini_key, cache=None,
                 asr_provider="elevenlabs", elevenlabs_key=None,
                 openai_key=None, anthropic_key=None,
                 matcher_provider="gemini",
                 script_text=None, script_path=None):
    """
    Semantic matching: transcribe all clips, then let the configured
    matcher provider match dubbed clips to their English originals in ONE call.

    matcher_provider = "gemini" | "openai" | "anthropic"

    Returns list of result dicts (same format as match_items).
    """
    # Configure the dispatcher used by _call_gemini() at module level.
    global _MATCHER_PROVIDER, _OPENAI_KEY, _ANTHROPIC_KEY
    _MATCHER_PROVIDER = (matcher_provider or "gemini").lower()
    _OPENAI_KEY       = openai_key
    _ANTHROPIC_KEY    = anthropic_key
    print(f"  [MATCHER] Provider = {_MATCHER_PROVIDER}")

    MAX_PARALLEL = 8   # concurrent API calls (avoid rate-limits)

    # ── Helper: prepare audio paths (sequential, fast) ───────
    def _prepare_items(items):
        """Extract audio chunks and return {id: audio_path} map."""
        paths = {}
        for item in items:
            wav         = item["wav_path"]
            take_offset = item.get("take_offset", 0.0)
            duration    = item.get("duration", 0.0)
            audio_path  = get_audio_for_item(item["id"], wav, take_offset, duration)
            if audio_path:
                paths[item["id"]] = audio_path
            else:
                item["transcript"]   = ""
                item["speech_start"] = 0.0
        return paths

    # ── Helper: transcribe one item (thread-safe for API calls) ─
    def _transcribe_one(item_id, audio_path, language):
        return item_id, transcribe(
            audio_path, task="transcribe", language=language,
            cache=cache,
            asr_provider=asr_provider,
            elevenlabs_key=elevenlabs_key,
            openai_key=openai_key,
            gemini_key=gemini_key,
        )

    # ── Step 1: Transcribe ALL EN clips (parallel) ───────────
    print(f"\n{'=' * 60}")
    print(f"  STEP 1: Transcribing {len(en_items)} EN clips "
          f"({MAX_PARALLEL} parallel)")
    print(f"{'=' * 60}")
    _t1 = time.time()

    en_paths = _prepare_items(en_items)
    en_by_id = {item["id"]: item for item in en_items}

    with ThreadPoolExecutor(max_workers=MAX_PARALLEL) as pool:
        futures = {
            pool.submit(_transcribe_one, iid, path, "en"): iid
            for iid, path in en_paths.items()
        }
        for future in as_completed(futures):
            iid, result = future.result()
            item = en_by_id[iid]
            item["transcript"]   = (normalize_text(result["text"])
                                    if _NEW_ENGINE else result["text"])
            item["speech_start"] = result["speech_start"]
            print(f'  [{iid:3d}] "{result["text"][:70]}"')

    print(f"  ✓ Done in {time.time() - _t1:.1f}s")

    # ── Step 2: Transcribe ALL DUB clips (parallel) ──────────
    print(f"\n{'=' * 60}")
    print(f"  STEP 2: Transcribing {len(dub_items)} DUB clips "
          f"({dub_language}, {MAX_PARALLEL} parallel)")
    print(f"{'=' * 60}")
    _t2 = time.time()

    dub_paths = _prepare_items(dub_items)
    dub_by_id = {item["id"]: item for item in dub_items}

    with ThreadPoolExecutor(max_workers=MAX_PARALLEL) as pool:
        futures = {
            pool.submit(_transcribe_one, iid, path, dub_language): iid
            for iid, path in dub_paths.items()
        }
        for future in as_completed(futures):
            iid, result = future.result()
            item = dub_by_id[iid]
            item["transcript"]   = (normalize_text(result["text"])
                                    if _NEW_ENGINE else result["text"])
            item["speech_start"] = result["speech_start"]
            print(f'  [{iid:3d}] "{result["text"][:70]}"')

    print(f"  ✓ Done in {time.time() - _t2:.1f}s")

    # v0.15.5: is this actually the language we were told it is? A transcript
    # that came back in the wrong alphabet means the ASR ignored the language
    # hint, and matching on it is guaranteed nonsense — better said out loud
    # than discovered as "everything went to Un sync".
    if _NEW_ENGINE:
        _check_language(dub_items, dub_language, "DUB")

    # ── ASR sanity gate ──────────────────────────────────────
    # transcribe() returns "" on every failure (bad key, HTTP 401, network,
    # SSL, missing audio). Feeding all-empty transcripts to Gemini "succeeds":
    # the model dutifully reports everything unmatched and the run exits 0.
    # A wholesale ASR outage must be a hard error instead.
    def _empty_count(items):
        return sum(1 for i in items if not (i.get("transcript") or "").strip())
    en_empty, dub_empty = _empty_count(en_items), _empty_count(dub_items)
    if (en_items and en_empty == len(en_items)) or \
       (dub_items and dub_empty == len(dub_items)):
        print(f"\n  [ERROR] Transcription produced NO text "
              f"(EN empty: {en_empty}/{len(en_items)}, "
              f"DUB empty: {dub_empty}/{len(dub_items)}).")
        print("          The ASR provider failed wholesale — matching would "
              "be meaningless. NOT proceeding.")
        print("          Check the [ASR] errors above: key valid? network/SSL "
              "OK? audio files readable?")
        raise SystemExit(1)
    if en_empty > len(en_items) // 2 or dub_empty > len(dub_items) // 2:
        print(f"  [WARN] Many empty transcripts (EN {en_empty}/{len(en_items)}, "
              f"DUB {dub_empty}/{len(dub_items)}) — match quality will suffer; "
              "check ASR errors above")
        report_problem("WARN", "ASR_MOSTLY_EMPTY",
                       f"More than half the clips transcribed to nothing "
                       f"(EN {en_empty}/{len(en_items)}, "
                       f"DUB {dub_empty}/{len(dub_items)}).")

    # ── Identical-transcript gate ────────────────────────────
    # The failure mode the empty-gate above cannot see: slicing failed, every
    # clip on the track was transcribed from the WHOLE source file, so every
    # transcript is the same non-empty string. Gemini then has nothing to tell
    # the clips apart and the run ends with most clips on the Un sync track —
    # which is what "the sync throws my dub away" looks like from the timeline.
    def _dup_ratio(items):
        texts = [(i.get("transcript") or "").strip() for i in items]
        texts = [t for t in texts if t]
        if len(texts) < 3:
            return 0.0, 0, 0
        from collections import Counter
        top_text, top_n = Counter(texts).most_common(1)[0]
        return top_n / float(len(texts)), top_n, len(texts)

    for _label, _items in (("EN", en_items), ("DUB", dub_items)):
        _ratio, _n, _tot = _dup_ratio(_items)
        if _ratio >= 0.9:
            print(f"\n  [ERROR] {_n}/{_tot} {_label} clips produced the SAME "
                  f"transcript.")
            print("          Per-clip audio slicing failed, so every clip was "
                  "transcribed from the whole source file.")
            print("          Matching cannot work on identical text. NOT "
                  "proceeding.")
            print("          Fix: convert the track's media to .wav, or install "
                  "ffmpeg so non-WAV formats can be sliced.")
            report_problem("ERROR", "IDENTICAL_TRANSCRIPTS",
                           f"{_n} of {_tot} {_label} clips transcribed to the "
                           f"same text — per-clip slicing failed. Convert the "
                           f"media to .wav or install ffmpeg.")
            print_problems()
            raise SystemExit(1)
        if _ratio >= 0.5:
            print(f"  [WARN] {_n}/{_tot} {_label} clips share one transcript — "
                  "slicing may be partly failing.")
            report_problem("WARN", "REPEATED_TRANSCRIPTS",
                           f"{_n} of {_tot} {_label} clips share one "
                           f"transcript; matching accuracy will be poor.")

    # ── v0.15.5 Step 2.5: sub-split over-long EN clips ───────
    # After EN transcription (it needs the word timings) and before matching,
    # so the matcher sees several usable anchors instead of one huge slot.
    if _NEW_ENGINE:
        en_items, _n_split = _split_long_en_items(
            en_items, cache, asr_provider, elevenlabs_key, gemini_key)

    # Resolve dubbing script (optional — boosts Gemini's grouping accuracy)
    script_text = _load_script_text(script_text, script_path)

    # ── Step 3a: Try single-call sectioned grouping (preferred) ─────
    print(f"\n{'=' * 60}")
    print(f"  STEP 3: Sending to Gemini for semantic matching")
    print(f"{'=' * 60}")
    _t3 = time.time()

    # With Vertex AI we trust the model with one big call — gemini-2.5-pro
    # easily handles thousands of clips in a single prompt. The batched
    # fallback is only used if the single-call path fails outright.
    SINGLE_CALL_LIMIT = 5000
    sections      = None
    unmatched_dub_ids = []

    # ── v0.15.5 Step 3-pivot: correspondence through the dubbing script ──
    # Preferred when a script is available: the dub side of grouping becomes
    # deterministic same-language alignment instead of a model's guess.
    if _MATCH_MODE != "llm" and script_text:
        pivot = build_sections_via_script(en_items, dub_items, script_text,
                                          dub_language, gemini_key, cache=cache)
        if pivot is not None:
            sections, unmatched_dub_ids = pivot
            _LAST_DIAG["match_mode"] = "script"
        elif _MATCH_MODE == "script":
            print("  [ERROR] Script-pivot matching failed and "
                  "SYNC_MATCH_MODE=script forbids falling back.")
            report_problem("ERROR", "SCRIPT_PIVOT_FAILED",
                           "Script-pivot matching failed and the mode is set "
                           "to script-only.")
            print_problems()
            raise SystemExit(1)
        else:
            print("  Falling back to whole-clip model matching")
    elif _MATCH_MODE == "script":
        print("  [ERROR] SYNC_MATCH_MODE=script needs a dubbing script "
              "(--script / script_text in the config).")
        report_problem("ERROR", "SCRIPT_PIVOT_NO_SCRIPT",
                       "Script-only matching was requested but no dubbing "
                       "script was supplied.")
        print_problems()
        raise SystemExit(1)

    if sections is None and len(en_items) + len(dub_items) <= SINGLE_CALL_LIMIT:
        print(f"  Using sectioned single-call mode "
              f"(EN={len(en_items)} + DUB={len(dub_items)} ≤ {SINGLE_CALL_LIMIT})")
        sec_result = _call_gemini_sections(en_items, dub_items, dub_language,
                                            gemini_key, script_text=script_text,
                                            cache=cache)
        if sec_result is not None:
            sections, unmatched_dub_ids, _unmatched_en = sec_result
            print(f"  ✓ Sections: {len(sections)} | unmatched_dub: "
                  f"{len(unmatched_dub_ids)} | unmatched_en: {len(_unmatched_en)}")
        else:
            print("  [WARN] Sectioned call failed — falling back to batched pairs")

    if sections is None:
        # ── Step 3b: Retry — batched flat-pair prompt (still Gemini) ──
        sections, unmatched_dub_ids = _gemini_batched_pairs(
            en_items, dub_items, dub_language, gemini_key, cache=cache)
        if sections is None:
            # Gemini matching is the ONLY matching method. A failure here must
            # surface as a hard error — never silently produce results from a
            # different algorithm (the old duration fallback misplaced clips
            # with no warning the user could see).
            print("  [ERROR] Gemini matching failed — sectioned AND batched "
                  "attempts both returned nothing.")
            print("          NOT falling back to any other matching method.")
            print("          Check the log above for the cause. Common ones:")
            print("            - gateway base URL unreachable / wrong "
                  "(SYNC_GEMINI_BASE_URL)")
            print("            - invalid or expired key for the chosen backend")
            print("            - wrong model name for this backend")
            raise SystemExit(1)

    print(f"\n  Total sections: {len(sections)}  ✓ {time.time() - _t3:.1f}s")

    # ── Step 4: Placement ────────────────────────────────────
    # v0.15.5: two placers. "isotonic" stretches the whole dub proportionally
    # across the English and can never flip clip order; "spring" is the
    # original per-group placement, kept intact so any job can be compared
    # against it with one setting (SYNC_PLACER=spring).
    placer = "spring" if _PLACER == "spring" else "isotonic"
    print(f"\n{'=' * 60}")
    print(f"  STEP 4: Placement — {placer}")
    print(f"{'=' * 60}")

    en_total_duration = max(
        (e["position"] + e["duration"] for e in en_items),
        default=0.0,
    )
    print(f"  EN content ends at: {en_total_duration:.2f}s")
    if placer == "spring":
        print("  (legacy spring placer — unset SYNC_PLACER to use isotonic)")

    _LAST_DIAG["placer"] = placer
    _LAST_DIAG["sections"] = sections
    # The EN track as the matcher actually saw it, including any virtual
    # sub-items, so an offline tool can reproduce the targets.
    _LAST_DIAG["en_items"] = [
        {k: v for k, v in e.items() if k != "words"} for e in en_items
    ]

    if placer == "spring":
        return _place_with_springs(
            en_items, dub_items, sections, unmatched_dub_ids,
            en_total_duration,
        )
    return _place_isotonic(
        en_items, dub_items, sections, unmatched_dub_ids,
        en_total_duration,
    )


def _gemini_batched_pairs(en_items, dub_items, dub_language, gemini_key, cache=None):
    """
    Legacy batched flat-pair prompt — used as fallback when the sectioned
    single-call path fails or when input is too large for one call.
    Returns (sections, unmatched_dub_ids) or (None, None) on total failure.
    """
    BATCH_SIZE = 20   # EN clips per Gemini call

    def _build_prompt(en_batch, dub_batch):
        en_lines = [
            f"  EN[{i['id']}]: \"{i.get('transcript','')}\" "
            f"(pos={i['position']:.2f}s)"
            for i in en_batch
        ]
        dub_lines = [
            f"  DUB[{i['id']}]: \"{i.get('transcript','')}\" "
            f"(pos={i['position']:.2f}s)"
            for i in dub_batch
        ]
        return (
            f"Match each dubbed clip to the English clip it is a translation of, "
            f"based on meaning not exact words.\n"
            f"Rules: multiple dubs can share one EN clip; maintain chronological order; "
            f"short clips with no text match by position.\n"
            f"Return ONLY a JSON array, no markdown, no explanation. "
            f"Each element: {{\"dub\":<id>,\"en\":<id>}} or {{\"dub\":<id>,\"en\":null}}.\n\n"
            f"EN:\n{chr(10).join(en_lines)}\n\n"
            f"DUB ({dub_language}):\n{chr(10).join(dub_lines)}\n\nJSON array:"
        )

    def _parse_gemini_response(raw):
        if not raw:
            return None
        cleaned = raw.strip()
        if cleaned.startswith("```"):
            cleaned = re.sub(r"^```\w*\n?", "", cleaned)
            cleaned = re.sub(r"\n?```$", "", cleaned)
            cleaned = cleaned.strip()
        try:
            result = json.loads(cleaned)
            if isinstance(result, list):
                return result
        except json.JSONDecodeError:
            pass
        # NOTE: no truncation "salvage" here. The old code chopped a truncated
        # reply at the last '}' and treated the surviving prefix as the full
        # answer — every clip after the cut silently became "unmatched" with
        # exit code 0. A truncated reply is a FAILED reply: return None so the
        # caller purges the cached response and aborts loudly.
        if cleaned.rfind("}") > 0:
            print("  [ERROR] Response is not a valid JSON array "
                  "(likely truncated) — treating as a failed call")
        return None

    # Split EN clips into batches. Send ALL unmatched DUBs to every batch —
    # never filter by position. The dubbing artist may record clips at any
    # position on the DUB track, so positional filtering causes cross-batch
    # misses (a DUB placed at t=45s can still translate EN at t=25s).
    # already_sent prevents a DUB clip from being re-sent once Gemini has
    # already matched it, keeping later batches focused on unmatched clips only.
    all_matches  = []
    already_sent = set()
    n_batches    = (len(en_items) + BATCH_SIZE - 1) // BATCH_SIZE

    for b in range(n_batches):
        en_batch  = en_items[b * BATCH_SIZE : (b + 1) * BATCH_SIZE]
        dub_batch = [d for d in dub_items if d["id"] not in already_sent]

        if not dub_batch:
            print(f"  Batch {b+1}/{n_batches}: {len(en_batch)} EN, 0 DUB — skip")
            continue

        prompt = _build_prompt(en_batch, dub_batch)
        print(f"  Batch {b+1}/{n_batches}: {len(en_batch)} EN + "
              f"{len(dub_batch)} DUB  ({len(prompt)} chars)")

        raw = _call_gemini(prompt, gemini_key, cache=cache)
        batch_matches = _parse_gemini_response(raw)

        if batch_matches is None:
            # All-or-nothing: a failed batch used to be skipped with a WARN,
            # silently dumping every clip in it into "unmatched" while the
            # run still exited 0. Purge the cached response (if any) and fail
            # the whole matching call — the caller hard-errors, the user sees
            # the real cause instead of a mysteriously half-synced timeline.
            if raw:
                _invalidate_matcher_cache(prompt, cache)
            print(f"  [ERROR] Batch {b+1}/{n_batches} failed — aborting "
                  "(Gemini matching is all-or-nothing, no partial results)")
            return None, None

        # Deduplicate: keep only the first occurrence of each dub_id
        # (Gemini occasionally returns the same dub_id twice)
        seen_dubs = set()
        deduped = []
        for pair in batch_matches:
            dub_id = pair.get("dub")
            if dub_id not in seen_dubs:
                seen_dubs.add(dub_id)
                deduped.append(pair)
        if len(deduped) < len(batch_matches):
            print(f"  [DEDUP] Removed {len(batch_matches) - len(deduped)} duplicate dub_id(s)")
        batch_matches = deduped

        # Mark only MATCHED DUB IDs as sent — unmatched ones must remain
        # available for later batches where their EN counterpart may appear.
        for pair in batch_matches:
            if pair.get("en") is not None:
                already_sent.add(pair.get("dub"))

        print(f"  Batch {b+1} got {len(batch_matches)} pairs")
        all_matches.extend(batch_matches)

    if not all_matches:
        return None, None

    # Deduplicate cross-batch: a DUB that was null in Batch 1 and matched in
    # Batch 2 appears twice in all_matches. Keep the matched entry.
    best: dict = {}
    for pair in all_matches:
        dub_id = pair.get("dub")
        if dub_id is None:
            continue
        existing = best.get(dub_id)
        if existing is None or (existing.get("en") is None and pair.get("en") is not None):
            best[dub_id] = pair
    matches = list(best.values())

    print(f"\n  Total pairs from Gemini: {len(matches)}")

    en_by_id  = {e["id"]: e for e in en_items}
    dub_by_id = {d["id"]: d for d in dub_items}
    sections, unmatched_dub_ids = _pairs_to_sections(matches, dub_by_id, en_by_id)

    # Any DUB the model never mentioned → unmatched
    mentioned = {p.get("dub") for p in matches}
    for d in dub_items:
        if d["id"] not in mentioned and d["id"] not in unmatched_dub_ids:
            unmatched_dub_ids.append(d["id"])

    return sections, unmatched_dub_ids


# ═══════════════════════════════════════════════════════════

class TranscriptCache:
    def __init__(self, path=None):
        if path is None:
            path = SCRIPT_DIR / "sync_cache.json"
        self.path = Path(path)
        self._data = {}
        self._dirty = False
        self._lock = threading.Lock()
        if self.path.exists():
            try:
                with open(self.path, "r", encoding="utf-8") as f:
                    self._data = json.load(f)
                print(f"[CACHE] Loaded {len(self._data)} entries")
            except Exception:
                self._data = {}

    def _key(self, filepath, task, lang, model):
        p = Path(filepath)
        size = p.stat().st_size
        with open(p, "rb") as f:
            head = f.read(65536)
        digest = hashlib.sha256(head).hexdigest()[:16]
        return f"{digest}_{size}__{task}__{lang}__{model}"

    def get(self, filepath, task, lang, model):
        with self._lock:
            return self._data.get(self._key(filepath, task, lang, model))

    def set(self, filepath, task, lang, model, value):
        with self._lock:
            self._data[self._key(filepath, task, lang, model)] = value
            self._dirty = True

    # ── Generic key/value cache used for Gemini response caching ──
    def get_raw(self, key):
        with self._lock:
            return self._data.get(key)

    def set_raw(self, key, value):
        with self._lock:
            self._data[key] = value
            self._dirty = True

    def delete_raw(self, key):
        """Drop a cached entry (used to purge responses that failed parsing,
        so a bad response can't deterministically replay on every run)."""
        with self._lock:
            if key in self._data:
                del self._data[key]
                self._dirty = True

    def flush(self):
        """Write accumulated cache entries to disk (call once at end)."""
        with self._lock:
            if not self._dirty:
                return
            try:
                with open(self.path, "w", encoding="utf-8") as f:
                    json.dump(self._data, f, ensure_ascii=False, indent=2)
                self._dirty = False
                print(f"[CACHE] Saved {len(self._data)} entries")
            except Exception as e:
                print(f"[CACHE] Failed to save: {e}")


# ═══════════════════════════════════════════════════════════
# Audio transcription (ElevenLabs Scribe / Gemini audio)
# ═══════════════════════════════════════════════════════════

def transcribe(filepath, task="transcribe", language=None,
               cache=None, asr_provider="elevenlabs",
               elevenlabs_key=None, openai_key=None, gemini_key=None):
    """
    Transcribe an audio file. Returns:
        {"text": str, "speech_start": float, "speech_end": float}

    asr_provider:
        "elevenlabs" — ElevenLabs Scribe v2 (best for Indian languages)
        "gemini"     — Gemini 2.5 Flash audio understanding
                        (uses Vertex AI if vertex_key.json is present, else REST)

    Note: OpenAI and Anthropic have no STT used here — they are available for
    the matching step only (openai_key is accepted but unused for STT).
    """
    # Normalize common 3-letter codes → ISO 639-1
    _LANG_NORMALIZE = {
        "nep": "ne", "hin": "hi", "tam": "ta", "tel": "te", "kan": "kn",
        "mal": "ml", "ben": "bn", "guj": "gu", "mar": "mr", "pan": "pa",
        "urd": "ur", "eng": "en", "zho": "zh", "jpn": "ja", "kor": "ko",
        # v0.15.4: Assamese and Odia are in the supported-language list
        # but were missing here, so "asm"/"ori" reached the STT provider
        # unnormalised and were not valid ISO 639-1 language codes.
        "asm": "as", "ori": "or", "ory": "or", "ori_orya": "or",
    }
    if language:
        language = _LANG_NORMALIZE.get(language.lower(), language.lower())
    lang = language or "auto"

    provider = (asr_provider or "elevenlabs").lower()

    # Resolve which provider can actually run with the keys we have
    can_eleven = provider == "elevenlabs" and bool(elevenlabs_key)
    # Gemini audio works via Vertex (no key needed) OR REST (gemini_key)
    can_gemini = provider == "gemini" and (
        _get_vertex_client() is not None or bool(gemini_key)
    )

    if can_eleven:
        effective_model = "elevenlabs"
    elif can_gemini:
        effective_model = "gemini-flash-audio"
    else:
        print(f"    [ERROR] ASR provider '{provider}' has no usable key/client. "
              f"Set an elevenlabs or gemini key as appropriate.")
        return {"text": "", "speech_start": 0.0, "speech_end": 0.0}

    if cache:
        cached = cache.get(filepath, task, lang, effective_model)
        if cached is not None:
            print(f"    [CACHE HIT] {Path(filepath).name} ({lang}/{effective_model})")
            return cached

    if can_eleven:
        result = transcribe_elevenlabs(filepath, language, elevenlabs_key)
    else:  # can_gemini
        result = transcribe_gemini_audio(filepath, language, gemini_key)

    if cache and result.get("text"):
        cache.set(filepath, task, lang, effective_model, result)
    return result


# ═══════════════════════════════════════════════════════════
# Matching utilities
# ═══════════════════════════════════════════════════════════

def tokenize(text):
    return re.findall(r"\b\w+\b", text.lower())


def word_overlap_score(query_words, target_text):
    """Fraction of query words found in target text (0.0–1.0)."""
    if not query_words:
        return 0.0
    target_words = set(tokenize(target_text))
    hits = sum(1 for w in query_words if w in target_words)
    return hits / len(query_words)


def duration_similarity(d1, d2):
    """0.0–1.0 where 1.0 = identical duration."""
    if d1 <= 0 or d2 <= 0:
        return 0.0
    return min(d1, d2) / max(d1, d2)


# ═══════════════════════════════════════════════════════════
# Main matching pipeline
# ═══════════════════════════════════════════════════════════

def match_items(en_items, dub_items, dub_language, cache, mode="duration",
                asr_provider="elevenlabs", elevenlabs_key=None,
                gemini_key=None):
    """
    Match each dub item to an EN item using duration + position scoring.
    Used as fallback when Gemini mode is not selected.

    mode = "duration" — pure duration + position (default, fast)
    mode = "hybrid"   — ElevenLabs transcribe + Gemini translate + duration + position

    Chronological order is always enforced.
    """

    WINDOW_SEC  = 15.0
    MIN_SCORE   = 0.05
    QUERY_WORDS = 8
    SILENCE_CAP = 2.0

    use_ai = (mode == "hybrid")

    # ── Transcribe EN items (only in hybrid mode) ────────────

    print(f"\n{'=' * 60}")
    print(f"  STEP 1: {'Transcribing' if use_ai else 'Scanning'} {len(en_items)} EN items")
    print(f"{'=' * 60}")

    for item in en_items:
        wav         = item["wav_path"]
        take_offset = item.get("take_offset", 0.0)
        duration    = item.get("duration", 0.0)

        audio_path = get_audio_for_item(item["id"], wav, take_offset, duration)
        if not audio_path:
            print(f"  SKIP (file missing): {wav}")
            item["transcript"] = ""
            item["speech_start"] = 0.0
            continue

        print(f"  [{item['id']:3d}] {Path(wav).name} "
              f"(offset={take_offset:.2f}s  dur={duration:.2f}s)", end="")

        if use_ai:
            result = transcribe(audio_path, task="transcribe", language="en",
                                cache=cache, asr_provider=asr_provider,
                                elevenlabs_key=elevenlabs_key)
            item["transcript"]   = result["text"]
            item["speech_start"] = result["speech_start"]
            print(f'\n        → "{result["text"][:70]}"')
        else:
            item["transcript"]   = ""
            item["speech_start"] = 0.0
            print(f"  (duration mode)")

    # ── Match DUB items ──────────────────────────────────────

    print(f"\n{'=' * 60}")
    print(f"  STEP 2: Matching {len(dub_items)} DUB items")
    print(f"  Mode: {mode} | Language: {dub_language}")
    print(f"{'=' * 60}")

    results     = []
    last_en_idx = -1

    for dub in dub_items:
        wav         = dub["wav_path"]
        take_offset = dub.get("take_offset", 0.0)
        dub_pos     = dub["position"]
        dub_dur     = dub["duration"]

        audio_path = get_audio_for_item(dub["id"], wav, take_offset, dub_dur)
        if not audio_path:
            results.append({"dub_id": dub["id"], "status": "missing_file",
                            "match": None, "score": 0, "dub_duration": dub_dur})
            continue

        print(f"\n  DUB[{dub['id']:3d}]  pos={dub_pos:.2f}s  "
              f"dur={dub_dur:.2f}s  offset={take_offset:.2f}s")

        query_words      = []
        dub_speech_start = 0.0

        if use_ai:
            orig = transcribe(audio_path, task="transcribe",
                              language=dub_language, cache=cache,
                              asr_provider=asr_provider,
                              elevenlabs_key=elevenlabs_key)
            dub_speech_start = orig["speech_start"]
            native_text = orig["text"]
            print(f"    Native text : \"{native_text[:80]}\"")

            if gemini_key:
                english_text = translate_gemini(native_text, dub_language, gemini_key)
                print(f"    Gemini EN   : \"{english_text[:80]}\"")
                query_words = tokenize(english_text)[:QUERY_WORDS]
            print(f"    Query words : {query_words}")
        else:
            print(f"    (duration mode)")

        # ── Find candidates within time window ───────────────
        candidates = []
        for i, en in enumerate(en_items):
            if i <= last_en_idx:
                continue
            if abs(dub_pos - en["position"]) <= WINDOW_SEC:
                candidates.append(i)

        # Fallback 1: widen search forward if nothing in window
        if not candidates:
            best_dist = float("inf")
            best_i    = None
            for i, en in enumerate(en_items):
                if i <= last_en_idx:
                    continue
                dist = abs(dub_pos - en["position"])
                if dist < best_dist:
                    best_dist = dist
                    best_i    = i
            if best_i is not None:
                for off in range(-3, 4):
                    idx = best_i + off
                    if 0 <= idx < len(en_items) and idx > last_en_idx:
                        candidates.append(idx)
                candidates = sorted(set(candidates))

        # Fallback 2: if dub items outnumber EN items and we've exhausted
        # all forward EN items, allow re-matching against the last few EN items.
        # This handles the common case where one EN line has multiple dub clips
        # (e.g. a long sentence split across several takes).
        if not candidates and last_en_idx >= 0:
            # Look at the last 3 EN items and any within 2× WINDOW_SEC
            for off in range(0, min(4, last_en_idx + 1)):
                idx = last_en_idx - off
                if 0 <= idx < len(en_items):
                    if abs(dub_pos - en_items[idx]["position"]) <= WINDOW_SEC * 2:
                        candidates.append(idx)
            candidates = sorted(set(candidates))
            if candidates:
                print(f"    [OVERFLOW] More dub clips than EN items — "
                      f"re-matching against last EN items")

        # ── Score each candidate ─────────────────────────────
        best_idx   = None
        best_score = -1.0

        for i in candidates:
            en  = en_items[i]
            dur = duration_similarity(dub_dur, en["duration"])
            pos = max(0.0, 1.0 - abs(dub_pos - en["position"]) / WINDOW_SEC)

            if use_ai and query_words:
                w        = word_overlap_score(query_words, en.get("transcript", ""))
                combined = w * 0.40 + dur * 0.35 + pos * 0.25
                print(f"    EN[{i:3d}]  words={w:.2f}  dur={dur:.2f}  "
                      f"pos={pos:.2f}  =>  {combined:.3f}")
            else:
                combined = dur * 0.60 + pos * 0.40
                print(f"    EN[{i:3d}]  dur={dur:.2f}  pos={pos:.2f}  "
                      f"=>  {combined:.3f}")

            if combined > best_score:
                best_score = combined
                best_idx   = i

        # ── Decide ───────────────────────────────────────────
        if best_idx is not None and best_score >= MIN_SCORE:
            en = en_items[best_idx]

            silence_diff = en.get("speech_start", 0) - dub_speech_start
            if abs(silence_diff) > SILENCE_CAP:
                silence_diff = 0.0

            new_pos     = max(0.0, en["position"] + silence_diff)
            last_en_idx = best_idx

            print(f"    => MATCHED  EN[{best_idx}]  score={best_score:.3f}  "
                  f"new_pos={new_pos:.3f}s  silence={silence_diff:+.3f}s")

            results.append({
                "dub_id"            : dub["id"],
                "en_id"             : en["id"],
                "match"             : best_idx,
                "score"             : round(best_score, 4),
                "new_position"      : round(new_pos, 6),
                "silence_correction": round(silence_diff, 6),
                "dub_duration"      : round(dub_dur, 6),
                "status"            : "matched",
            })
        else:
            print(f"    => NO MATCH  (best={best_score:.3f})")
            results.append({
                "dub_id"      : dub["id"],
                "match"       : None,
                "score"       : round(max(best_score, 0), 4),
                "dub_duration": round(dub_dur, 6),
                "status"      : "unmatched",
            })

    # ── Anti-collision pass ──────────────────────────────

    OVERLAP_MS = 0.010  # 10ms allowed overlap for crossfade
    print(f"\n{'=' * 60}")
    print("  STEP 3: Anti-collision pass")
    print(f"{'=' * 60}")

    matched = [r for r in results if r["status"] == "matched"]
    matched.sort(key=lambda r: r["new_position"])

    collisions = 0
    for i in range(1, len(matched)):
        prev = matched[i - 1]
        curr = matched[i]

        prev_end = prev["new_position"] + prev["dub_duration"]
        if curr["new_position"] < prev_end - OVERLAP_MS:
            old_pos = curr["new_position"]
            curr["new_position"] = round(prev_end - OVERLAP_MS, 6)
            collisions += 1
            print(f"  Collision: DUB[{curr['dub_id']}] {old_pos:.3f}s "
                  f"=> {curr['new_position']:.3f}s")

    if collisions == 0:
        print("  No collisions found.")
    else:
        print(f"  Fixed {collisions} collision(s).")

    return results


# ═══════════════════════════════════════════════════════════
# Entry point — called by Lua script
# ═══════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="AI-powered audio sync matcher (called by Reaper Lua script)")
    parser.add_argument("--config", required=True,
                        help="Path to config JSON written by Lua")
    parser.add_argument("--language", default="ne",
                        help="Dub language code (hi/ne/ta/te/bn/mr/gu/kn/ml/pa/ur)")
    parser.add_argument("--mode", default="gemini",
                        choices=["gemini"],
                        help=(
                            "gemini = transcribe all clips then Gemini matches "
                            "semantically. This is the ONLY mode: on failure the "
                            "run exits non-zero — there is deliberately no "
                            "hybrid/duration fallback."
                        ))
    parser.add_argument("--asr", default="elevenlabs",
                        choices=["elevenlabs", "gemini"],
                        help=(
                            "elevenlabs = ElevenLabs Scribe v2 (default, best for Indian)\n"
                            "gemini     = Gemini 2.5 Flash audio (Vertex if vertex_key.json)"
                        ))
    parser.add_argument("--matcher-provider", default="gemini",
                        choices=["gemini", "openai", "anthropic"],
                        help=(
                            "Which LLM does the EN->DUB semantic matching:\n"
                            "gemini    = Gemini 2.5 Pro (default; Vertex preferred)\n"
                            "openai    = OpenAI gpt-4o\n"
                            "anthropic = Anthropic Claude (set SYNC_ANTHROPIC_MODEL to override)"
                        ))
    parser.add_argument("--elevenlabs-key", default=None,
                        help="ElevenLabs API key (required when --asr elevenlabs)")
    parser.add_argument("--gemini-key", default=None,
                        help="Gemini REST API key (used when no vertex_key.json)")
    parser.add_argument("--openai-key", default=None,
                        help="OpenAI API key (for --matcher-provider openai)")
    parser.add_argument("--anthropic-key", default=None,
                        help="Anthropic API key (for --matcher-provider anthropic)")
    parser.add_argument("--cache", default=None,
                        help="Path to cache file (default: next to sync_matcher.py)")
    parser.add_argument("--script", default=None,
                        help="Path to dubbing script .txt (optional — improves "
                             "Gemini grouping accuracy in gemini mode)")
    args = parser.parse_args()

    # Load config
    with open(args.config, "r", encoding="utf-8") as f:
        config = json.load(f)

    en_items = config["en_items"]
    dub_items = config["dub_items"]
    output_path = config.get("output_path", "sync_results.json")

    # Optional dubbing script (boosts Gemini section grouping). CLI > env > config.
    script_path = (args.script
                   or os.environ.get("SYNC_SCRIPT_PATH")
                   or config.get("script_path"))
    script_text = config.get("script_text")

    # CLI args take precedence, then env vars set by Lua launcher
    elevenlabs_key = getattr(args, "elevenlabs_key", None) or os.environ.get("SYNC_ELEVENLABS_KEY")
    gemini_key     = getattr(args, "gemini_key", None) or os.environ.get("SYNC_GEMINI_KEY")
    openai_key     = getattr(args, "openai_key", None) or os.environ.get("SYNC_OPENAI_KEY")
    anthropic_key  = getattr(args, "anthropic_key", None) or os.environ.get("SYNC_ANTHROPIC_KEY")
    matcher_prov   = (getattr(args, "matcher_provider", None)
                      or os.environ.get("SYNC_MATCHER_PROVIDER")
                      or "gemini")

    asr_label = args.asr
    if args.asr == "elevenlabs" and gemini_key:
        asr_label = "elevenlabs+gemini"

    _t_total = time.time()

    print(f"\n{'=' * 60}")
    print(f"  SYNC MATCHER")
    print(f"  EN: {len(en_items)} items | DUB: {len(dub_items)} items")
    print(f"  Language: {args.language} | ASR: {asr_label} | Mode: {args.mode}")
    print(f"  Engine: {'NEW (trial)' if _NEW_ENGINE else 'classic'} "
          f"| placement: {_PLACER} | matching: {_MATCH_MODE}")
    print(f"{'=' * 60}")

    # ── ASR sanity checks ────────────────────────────────────
    if args.mode != "duration":
        if args.asr == "elevenlabs" and not elevenlabs_key:
            print("ERROR: --asr elevenlabs requires --elevenlabs-key <key>")
            raise SystemExit(1)
        if args.asr == "gemini" and not gemini_key and not (SCRIPT_DIR / "vertex_key.json").exists():
            print("ERROR: --asr gemini requires --gemini-key <key> OR vertex_key.json")
            raise SystemExit(1)
        # The OpenAI-compatible gateway serves MATCHING only — audio
        # transcription still needs Google-native access (Vertex JSON or an
        # AIza... key). Without this guard a gateway Bearer key (sk-...)
        # would be sent to Google's endpoint, fail HTTP 400 on every clip,
        # and produce empty transcripts / zero matches with no clear error.
        if (args.asr == "gemini" and _GEMINI_BACKEND == "gateway"
                and not _USE_PROXY
                and not (SCRIPT_DIR / "vertex_key.json").exists()
                and not os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
                and not (gemini_key or "").startswith("AIza")):
            print("ERROR: ASR=gemini cannot run through the OpenAI-compatible "
                  "gateway (it serves matching only).\n"
                  "Fix one of these:\n"
                  "  - switch 'Transcribe with' to elevenlabs, or\n"
                  "  - add vertex_key.json / a Google AIza... key for "
                  "transcription")
            raise SystemExit(1)

    # ── Matcher sanity checks ────────────────────────────────
    if args.mode == "gemini":
        if matcher_prov == "gemini":
            if _GEMINI_BACKEND == "gateway":
                # Gateway needs a Bearer key + a base URL; vertex_key.json is
                # irrelevant here.
                if not gemini_key:
                    print("ERROR: backend=gateway requires --gemini-key "
                          "(the gateway Bearer token)")
                    raise SystemExit(1)
                if not _GEMINI_BASE_URL:
                    print("ERROR: backend=gateway requires SYNC_GEMINI_BASE_URL "
                          "(the gateway base URL)")
                    raise SystemExit(1)
            elif not gemini_key and not (SCRIPT_DIR / "vertex_key.json").exists():
                print("ERROR: matcher=gemini requires --gemini-key OR vertex_key.json")
                raise SystemExit(1)
        elif matcher_prov == "openai" and not openai_key:
            print("ERROR: matcher=openai requires --openai-key <key>")
            raise SystemExit(1)
        elif matcher_prov == "anthropic" and not anthropic_key:
            print("ERROR: matcher=anthropic requires --anthropic-key <key>")
            raise SystemExit(1)

    print(f"  Matcher provider: {matcher_prov}")
    if matcher_prov == "gemini":
        if _GEMINI_BACKEND == "gateway":
            print(f"  Gemini backend  : gateway → {_GEMINI_BASE_URL}")
        else:
            print(f"  Gemini backend  : {_GEMINI_BACKEND}")

    cache = TranscriptCache(args.cache)

    if args.mode == "gemini":
        results = match_gemini(en_items, dub_items, args.language, gemini_key,
                               cache=cache, asr_provider=args.asr,
                               elevenlabs_key=elevenlabs_key,
                               openai_key=openai_key,
                               anthropic_key=anthropic_key,
                               matcher_provider=matcher_prov,
                               script_text=script_text,
                               script_path=script_path)
    else:
        results = match_items(en_items, dub_items, args.language, cache,
                              mode=args.mode, asr_provider=args.asr,
                              elevenlabs_key=elevenlabs_key,
                              gemini_key=gemini_key)

    # Summary
    n_matched = sum(1 for r in results if r["status"] == "matched")
    n_unmatched = sum(1 for r in results if r["status"] == "unmatched")

    # Record what actually produced the matches — not just the ASR label.
    # (Both "model" and "backend" used to hold the ASR string, so the output
    # carried no trace of which matcher/backend ran.)
    if matcher_prov == "gemini":
        matcher_backend = ("proxy" if _USE_PROXY else _GEMINI_BACKEND)
        matcher_model   = _GEMINI_MATCHER_MODEL
    else:
        matcher_backend = matcher_prov
        matcher_model   = matcher_prov

    output = {
        "results": results,
        "summary": {
            "total_en": len(en_items),
            "total_dub": len(dub_items),
            "matched": n_matched,
            "unmatched": n_unmatched,
            "model": matcher_model,
            "language": args.language,
            "backend": matcher_backend,
            "asr": asr_label,
        },
        # v0.15.4: flat "SEVERITY|CODE|message" strings so the Lua importer can
        # read them with one gmatch. Additive — older importers ignore the key.
        "problems": problems_as_strings(),
    }

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)

    # Flush cached transcriptions to disk
    cache.flush()

    _total_elapsed = time.time() - _t_total
    _mins = int(_total_elapsed // 60)
    _secs = int(_total_elapsed % 60)
    if n_unmatched and len(dub_items):
        _pct = 100.0 * n_unmatched / len(dub_items)
        if _pct >= 25.0:
            report_problem(
                "WARN", "MANY_UNMATCHED",
                f"{n_unmatched} of {len(dub_items)} dub clips "
                f"({_pct:.0f}%) ended on the Un sync track.")

    print_problems()

    print(f"\n{'=' * 60}")
    print(f"  RESULT: {n_matched}/{len(dub_items)} matched, "
          f"{n_unmatched} unmatched")
    print(f"  Total time: {_mins}m {_secs}s")
    print(f"  Output: {output_path}")
    print(f"{'=' * 60}\n")

    # Zero matches in gemini mode means the run FAILED, whatever the exit
    # path above thought: an all-unmatched timeline is never a success the
    # user asked for. Results were written for debugging, but exit non-zero
    # so the front-end shows the failure instead of applying it silently.
    if args.mode == "gemini" and dub_items and n_matched == 0:
        print("  [ERROR] 0 clips matched — treating the run as FAILED.")
        print("          Results were written for inspection, but they will "
              "not be applied.")
        print("          Scroll up for the first [ERROR]/[WARN] — usually "
              "ASR key/network, wrong tracks, or a matcher backend problem.")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
