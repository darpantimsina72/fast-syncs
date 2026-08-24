"""
ElevenLabs helpers: API-key resolution, key validation, voice catalogue
and Scribe speech-to-text.

Extracted from Translation_and_Syncing_App.py (bulk app, v1.8.0):
    lines 993-1331  "Shared helpers — ElevenLabs"

Adaptations (everything else is verbatim):
  * _get_api_key() reads "elevenlabs_api_key" from this repo's
    config/tts_settings.json instead of the app's api.txt / in-memory
    UI paste (the api.txt read/write helpers and set_runtime_api_key
    were UI plumbing and are not ported).
"""

import hashlib
import http.client
import json
import mimetypes
import os
import re
import shutil
import socket
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import wave
from typing import Dict, List, Optional

from .config import (_urlopen, DATA_DIR, FFMPEG_PATH, IS_WINDOWS,
                     TTS_DEFAULT_LANGUAGE, TTS_SETTINGS_FILE, _lang_tokens,
                     load_tts_settings)

# ElevenLabs voice cache keyed by (api-key fingerprint, language name) so we
# don't re-fetch the voice list on every TTS run.
_EL_VOICE_CACHE: Dict[tuple, List[Dict[str, str]]] = {}


_VOICE_ID_RE = re.compile(r"^[A-Za-z0-9]{12,40}$")


def _sanitize_voice_id(raw) -> str:
    """
    Return *raw* unchanged if it is a clean ElevenLabs voice_id, else "".

    ElevenLabs voice IDs are 20-char alphanumeric tokens. The app's dropdown
    shows formatted labels like "✦ Aria — abc12345…  [bn · premade]" — we
    must NOT mangle those into fake IDs by stripping punctuation, because
    the truncated 8-char fragment in the label cannot reconstruct the real
    voice_id (and ElevenLabs returns HTTP 404 voice_not_found).

    Strict policy: input must already match the voice_id regex, otherwise
    callers must look it up in the options map by display label.
    """
    if raw is None:
        return ""
    s = str(raw).strip()
    if not s:
        return ""
    return s if _VOICE_ID_RE.match(s) else ""


def _api_key_fingerprint(api_key: str) -> str:
    """Stable, non-sensitive cache key derived from the API key."""
    if not api_key:
        return ""
    return api_key[-8:] if len(api_key) >= 8 else "x" * len(api_key)


def _get_api_key():
    """
    Resolve the ElevenLabs API key from config/tts_settings.json.

    Raises ValueError with an actionable message when the settings file is
    missing or the key is empty.
    """
    settings = load_tts_settings()
    key = (settings.get("elevenlabs_api_key") or "").strip()
    if not key:
        raise ValueError(
            "No ElevenLabs API key configured.\n"
            f"Add \"elevenlabs_api_key\" to {TTS_SETTINGS_FILE} — "
            "run setup_mac.command or open the REAPER panel's Settings "
            "section and paste your key there.")
    return key


def _redact_api_key(api_key: str) -> str:
    """Safe representation for logs / status messages."""
    if not api_key:
        return "<empty>"
    if len(api_key) <= 8:
        return "*" * len(api_key)
    return f"{api_key[:3]}…{api_key[-4:]}"


def _validate_api_key(api_key: str, timeout: float = 15.0) -> Dict[str, str]:
    """
    Verify an ElevenLabs API key by hitting /v1/user.

    Returns a dict like {"ok": True, "tier": "...", "name": "..."} on success.
    Raises ValueError with a user-friendly message on failure (invalid /
    expired / network / quota).
    """
    if not api_key or not api_key.strip():
        raise ValueError("API key is empty.")
    api_key = api_key.strip()

    # v0.15.0: retried like the voice pages. A single dropped connection used
    # to report the key itself as bad, which sends people off rotating a key
    # that was never the problem.
    last: Optional[BaseException] = None
    payload = None
    for attempt in range(1, _EL_PAGE_ATTEMPTS + 1):
        req = urllib.request.Request(
            "https://api.elevenlabs.io/v1/user",
            method="GET",
            headers={"xi-api-key": api_key, "Accept": "application/json"},
        )
        try:
            with _urlopen(req, timeout=timeout) as resp:
                payload = json.loads(resp.read().decode("utf-8", errors="replace"))
            break
        except urllib.error.HTTPError as e:
            # A verdict on the key is the same on every attempt — don't wait
            # three times to deliver it.
            if e.code == 401:
                raise ValueError("Invalid or expired ElevenLabs API key (401).") from None
            if e.code == 429:
                raise ValueError("ElevenLabs API rate limit hit (429). Try again shortly.") from None
            if e.code < 500:
                raise ValueError(f"ElevenLabs API error: HTTP {e.code}.") from None
            last = e
        # OSError covers URLError, socket.timeout and ssl.SSLError alike —
        # every way a connection can die mid-read. HTTPError is handled above
        # and never reaches here, which is what keeps a 4xx from being retried.
        except (OSError, http.client.HTTPException,
                json.JSONDecodeError) as e:
            last = e
        except Exception as e:
            raise ValueError(f"Could not validate ElevenLabs key: {e}") from None
        if attempt == _EL_PAGE_ATTEMPTS:
            break
        time.sleep(_EL_PAGE_BACKOFF[min(attempt - 1,
                                        len(_EL_PAGE_BACKOFF) - 1)])

    if payload is None:
        raise ValueError(
            f"Network error reaching ElevenLabs after {_EL_PAGE_ATTEMPTS} "
            f"attempts: {_voice_err_detail(last)}") from None

    sub = payload.get("subscription") or {}
    return {
        "ok": True,
        "tier": str(sub.get("tier", "")),
        "name": str(payload.get("first_name") or payload.get("xi_api_key") or "user"),
    }


def _voice_supports_language(voice: dict, lang_tokens: tuple) -> bool:
    """
    Heuristic: does this ElevenLabs voice metadata indicate support for the
    language identified by *lang_tokens* (from TTS_LANGUAGES[...]["el_tokens"])?

    Looks at:
      • labels.language / labels.languages
      • verified_languages (newer schema, list of {language, ...})
      • language / language_code top-level fields
      • name / description text mentions
    """
    if not isinstance(voice, dict):
        return False
    haystacks: List[str] = []

    labels = voice.get("labels") or {}
    if isinstance(labels, dict):
        for key in ("language", "languages", "accent"):
            v = labels.get(key)
            if isinstance(v, str):
                haystacks.append(v)
            elif isinstance(v, list):
                haystacks.extend(str(x) for x in v)

    verified = voice.get("verified_languages") or []
    if isinstance(verified, list):
        for entry in verified:
            if isinstance(entry, dict):
                for key in ("language", "code", "name", "locale"):
                    val = entry.get(key)
                    if isinstance(val, str):
                        haystacks.append(val)
            elif isinstance(entry, str):
                haystacks.append(entry)

    for key in ("language", "language_code", "locale"):
        v = voice.get(key)
        if isinstance(v, str):
            haystacks.append(v)

    for key in ("name", "description"):
        v = voice.get(key)
        if isinstance(v, str):
            haystacks.append(v)

    blob = " ".join(haystacks).lower()
    if not blob:
        return False
    for token in lang_tokens:
        t = str(token).lower()
        # Word-boundary match for short codes, substring for full names.
        if len(t) <= 3:
            if re.search(rf"\b{re.escape(t)}\b", blob):
                return True
        else:
            if t in blob:
                return True
    return False


# ── Voice catalogue paging ──────────────────────────────────────────────────
# v0.15.0: the catalogue is fetched from /v2/voices, ONE PAGE AT A TIME.
#
# This used to be a single unpaginated GET /v1/voices. That endpoint returns
# every voice the account can see in one response, with the complete record
# for each (samples[], fine_tuning, sharing, verified_languages...). On an
# account with a shared workspace and library access that is not a small
# thing: measured at 4,288 voices / 28 MB / 91 seconds against a 30 s
# timeout. It had been creeping up for months and finally crossed the line
# when two more clones were added — at which point the voice picker stopped
# working on every machine at once, because the size is decided server-side
# and has nothing to do with the client.
#
# The point of paging is NOT that it is faster (the full walk is ~2 min).
# It is that the largest single request is now a fixed 100 voices — measured
# 6.1 s worst case, well inside the per-page timeout — and adding voices only
# ever adds pages. The old shape had one request that grew without limit, so
# it was always going to fail eventually; this one cannot.
#
# The caller still gets one merged list, and the panel still caches it to
# voice_cache.json (Dub_Pipeline_Panel.lua V5.voice_cache_save), so the walk
# is a one-off — not something the user pays on every launch.
_EL_VOICES_URL      = "https://api.elevenlabs.io/v2/voices"
_EL_PAGE_SIZE       = 100      # ElevenLabs' maximum; 200 and 1000 both 400.
_EL_PAGE_ATTEMPTS   = 3
_EL_PAGE_BACKOFF    = (2.0, 5.0)
_EL_MAX_PAGES       = 200      # 20,000 voices. A runaway guard, not a policy.


def _fetch_voice_page(api_key: str, page_token: Optional[str],
                      timeout: float) -> dict:
    """One page of /v2/voices, retried on transient failures.

    Retries only what is worth retrying: timeouts, dropped connections and
    5xx. A 401 or a 400 is the same on every attempt, so it is raised at once
    rather than after three identical waits.
    """
    url = f"{_EL_VOICES_URL}?page_size={_EL_PAGE_SIZE}"
    if page_token:
        url += f"&next_page_token={urllib.parse.quote(page_token, safe='')}"

    last: Optional[BaseException] = None
    for attempt in range(1, _EL_PAGE_ATTEMPTS + 1):
        req = urllib.request.Request(
            url, method="GET",
            headers={"xi-api-key": api_key, "Accept": "application/json"},
        )
        try:
            with _urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8", errors="replace"))
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise ValueError(
                    "Invalid or expired ElevenLabs API key (401).") from None
            if e.code == 429:
                # Honour Retry-After when the server sends one.
                last = e
                if attempt == _EL_PAGE_ATTEMPTS:
                    raise ValueError("ElevenLabs API rate limit hit (429). "
                                     "Try again shortly.") from None
                try:
                    delay = float(e.headers.get("Retry-After") or 0)
                except (TypeError, ValueError):
                    delay = 0.0
                time.sleep(max(delay, _EL_PAGE_BACKOFF[
                    min(attempt - 1, len(_EL_PAGE_BACKOFF) - 1)]))
                continue
            if e.code < 500:
                raise ValueError(
                    f"Could not fetch voices (HTTP {e.code}).") from None
            last = e
        # OSError covers URLError, socket.timeout and ssl.SSLError alike —
        # every way a connection can die mid-read. HTTPError is handled above
        # and never reaches here, which is what keeps a 4xx from being retried.
        except (OSError, http.client.HTTPException,
                json.JSONDecodeError) as e:
            last = e
        if attempt == _EL_PAGE_ATTEMPTS:
            break
        time.sleep(_EL_PAGE_BACKOFF[min(attempt - 1,
                                        len(_EL_PAGE_BACKOFF) - 1)])
    raise ValueError(f"Could not fetch voices: {_voice_err_detail(last)}")


def _voice_err_detail(err: Optional[BaseException]) -> str:
    """Short, specific description of why a page failed."""
    if err is None:
        return "unknown error"
    if isinstance(err, urllib.error.HTTPError):
        return f"HTTP {err.code}"
    if isinstance(err, urllib.error.URLError):
        return f"{type(err).__name__}: {err.reason}"
    return f"{type(err).__name__}: {err}"


def _fetch_voices_for_language(api_key: str,
                               language: str = TTS_DEFAULT_LANGUAGE,
                               force_refresh: bool = False,
                               timeout: float = 45.0) -> List[Dict[str, str]]:
    """
    Pull the user's full voice catalogue from ElevenLabs and return EVERY
    voice on the account.

    Voices that advertise support for *language* (per TTS_LANGUAGES tokens)
    are sorted to the top and marked with a ✦ prefix so they're easy to
    find, but the list shows everything — eleven_v3 auto-detects the
    target language from the input text and works on any voice.

    Each entry is a small dict: {"voice_id", "name", "label"}.
    Result is cached per (API-key fingerprint, language) to avoid repeated
    API calls.

    *timeout* is PER PAGE, not for the whole walk.
    """
    api_key = (api_key or "").strip()
    if not api_key:
        raise ValueError("API key is empty.")

    lang_tokens = _lang_tokens(language)
    cache_key   = (_api_key_fingerprint(api_key), language)
    if not force_refresh and cache_key in _EL_VOICE_CACHE:
        return _EL_VOICE_CACHE[cache_key]

    voices:   List[dict] = []
    seen_ids: set        = set()
    token: Optional[str] = None
    pages   = 0
    total   = None
    partial = ""
    started = time.time()

    while pages < _EL_MAX_PAGES:
        try:
            payload = _fetch_voice_page(api_key, token, timeout)
        except ValueError:
            # A first-page failure means we have nothing to show: the caller
            # needs the error. Later pages: keep what already arrived and say
            # plainly what is missing — a partial list beats an empty picker.
            if not voices:
                raise
            partial = (f" (incomplete: page {pages + 1} failed after "
                       f"{_EL_PAGE_ATTEMPTS} attempts)")
            print(f"    [voices] page {pages + 1} failed — keeping the "
                  f"{len(voices)} voice(s) already fetched", flush=True)
            break

        pages += 1
        page = payload.get("voices")
        if not isinstance(page, list):
            page = []
        for v in page:
            # The token walk should not repeat a voice, but a duplicate here
            # would show up twice in the dropdown, so filter defensively.
            if isinstance(v, dict):
                vid = v.get("voice_id") or v.get("voiceId") or ""
                if vid and vid not in seen_ids:
                    seen_ids.add(vid)
                    voices.append(v)
        if total is None:
            total = payload.get("total_count")

        if pages == 1 or pages % 5 == 0:
            of = f"/{total}" if isinstance(total, int) else ""
            print(f"    [voices] {len(voices)}{of} fetched "
                  f"({pages} page(s), {int(time.time() - started)}s)",
                  flush=True)

        if not payload.get("has_more"):
            break
        token = payload.get("next_page_token")
        if not token:
            break
    else:
        # Loop guard tripped. Never truncate silently.
        partial = f" (stopped at the {_EL_MAX_PAGES}-page safety limit)"
        print(f"    [voices] stopped at {_EL_MAX_PAGES} pages — "
              f"{len(voices)} voice(s) fetched", flush=True)

    print(f"    [voices] {len(voices)} voice(s) in "
          f"{int(time.time() - started)}s{partial}", flush=True)

    matched_voices: List[Dict[str, str]] = []
    other_voices:   List[Dict[str, str]] = []
    for v in voices:
        if not isinstance(v, dict):
            continue
        vid = v.get("voice_id") or v.get("voiceId") or ""
        if not vid:
            continue
        name = v.get("name") or "Unnamed voice"
        labels = v.get("labels") or {}
        accent = ""
        category = str(v.get("category", "")).strip()
        if isinstance(labels, dict):
            accent = str(labels.get("accent") or labels.get("language") or "")

        meta_bits: List[str] = []
        if accent:
            meta_bits.append(accent)
        if category and category.lower() not in ("premade",):
            meta_bits.append(category)
        meta = f"  [{' · '.join(meta_bits)}]" if meta_bits else ""

        is_match = _voice_supports_language(v, lang_tokens)
        prefix = "✦ " if is_match else "  "
        entry = {
            "voice_id": vid,
            "name": str(name),
            "label": f"{prefix}{name} — {vid[:8]}…{meta}",
        }
        (matched_voices if is_match else other_voices).append(entry)

    # Sort each bucket alphabetically for stable display order.
    matched_voices.sort(key=lambda e: e["name"].lower())
    other_voices.sort(key=lambda e: e["name"].lower())

    all_voices = matched_voices + other_voices

    _EL_VOICE_CACHE[cache_key] = all_voices
    return all_voices


def _clear_el_voice_cache(language: Optional[str] = None,
                          api_key: Optional[str] = None) -> None:
    """Clear ElevenLabs voice cache. If *language* is given, clear only that
    language's entries; otherwise clear everything. If *api_key* is also
    given, scope the clear to that key's fingerprint."""
    if language is None and api_key is None:
        _EL_VOICE_CACHE.clear()
        return
    fp = _api_key_fingerprint(api_key) if api_key else None
    for key in list(_EL_VOICE_CACHE.keys()):
        key_fp, key_lang = key
        if (language is None or key_lang == language) and \
           (fp is None or key_fp == fp):
            _EL_VOICE_CACHE.pop(key, None)


def _multipart_body(fields, files):
    boundary = "----ElevenLabsBoundary7MA4YWxkTrZu0gW"
    body = b""
    for name, value in fields:
        body += (f"--{boundary}\r\nContent-Disposition: form-data; "
                 f"name=\"{name}\"\r\n\r\n{value}\r\n").encode()
    for name, filename, mime, data in files:
        body += (f"--{boundary}\r\nContent-Disposition: form-data; "
                 f"name=\"{name}\"; filename=\"{filename}\"\r\n"
                 f"Content-Type: {mime}\r\n\r\n").encode()
        body += data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    return body, boundary


# ─── Scribe robustness ───────────────────────────────────────────────────────
# One slow response used to kill a whole 60-minute job. The call was a single
# urlopen with a fixed timeout=180 and no retry, so a slow uplink, a corporate
# proxy or a busy Scribe queue surfaced as
#     TimeoutError: The read operation timed out
# raised from resp.read() — i.e. AFTER the multipart upload had succeeded, the
# expensive part. The connection was fine; the script simply stopped waiting
# for the answer. Identical code transcribes 60-minute audio fine on a fast
# desk, so the timeout constant was never the bug on its own: the gap was
# robustness. Hence, in order of value:
#   1. retry the transient failures with backoff,
#   2. size the timeout to the audio instead of a fixed 180 s,
#   3. prove the cheap things (key, file, proxy) before the upload,
#   4. print a heartbeat so "working" and "hung" stop looking identical,
#   5. checkpoint the transcript so a later crash never re-uploads — and
#      re-pays for — a transcription we already have.

_STT_ATTEMPTS       = 4
_STT_BACKOFF_SECS   = (5, 15, 45)   # waits after attempts 1, 2, 3
_STT_TIMEOUT_FLOOR  = 300.0         # never allow less than 5 min of patience
_STT_TIMEOUT_PER_S  = 2.0           # ...then 2 s per second of audio
_STT_TIMEOUT_CAP    = 1800.0        # ...but past 30 min of silence it is dead
_STT_HEARTBEAT_SECS = 30.0
_STT_CACHE_DIR      = os.path.join(DATA_DIR, "stt_cache")

# HTTP codes that fail identically forever — retrying only wastes a minute and
# buries the real message.
_STT_FATAL_HTTP = frozenset({400, 401, 403, 404, 413, 422})

# Fingerprints of keys already checked in this process: the preflight
# GET /v1/user must not repeat for the second (S3b) transcription.
_STT_KEYS_CHECKED: set = set()

_NO_WINDOW_FLAGS = getattr(subprocess, "CREATE_NO_WINDOW", 0) if IS_WINDOWS else 0

_PROXY_ENV_VARS = ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                   "http_proxy", "https_proxy", "all_proxy", "no_proxy")


def _stt_log(msg: str) -> None:
    """Progress line for the Scribe call.

    Tagged [stt], NOT [Sxx]: this helper serves both S1a (English audio) and
    S3b (TTS audio), and the REAPER panel takes the last "[Sxx]" tag it sees
    as the current stage — printing [S1a] here would drag the panel backwards
    mid-dub. Module tag matches the existing [config] / [LLM] lines.
    """
    print(f"[stt] {msg}", flush=True)


def _fmt_duration(seconds: float) -> str:
    """'61m 12s' — for logs, so operators can eyeball audio length."""
    if seconds <= 0:
        return "unknown length"
    total = int(round(seconds))
    return f"{total // 60}m {total % 60:02d}s"


def _ffprobe_path() -> Optional[str]:
    """Locate ffprobe: PATH first, else alongside the ffmpeg config found."""
    found = shutil.which("ffprobe")
    if found:
        return found
    if FFMPEG_PATH:
        exe = "ffprobe.exe" if IS_WINDOWS else "ffprobe"
        candidate = os.path.join(os.path.dirname(FFMPEG_PATH), exe)
        if os.path.isfile(candidate):
            return candidate
    return None


def _audio_duration_seconds(audio_path: str) -> float:
    """Best-effort audio length in seconds; 0.0 when it cannot be determined.

    Only used to size the read timeout, so an estimate is good enough — three
    tiers, cheapest reliable first:
      1. ffprobe when present (exact, one short subprocess),
      2. the stdlib wave header for PCM .wav (no dependency at all),
      3. file size / 16 KB per second — the ~128 kbps MP3 rule of thumb.
    Never raises and never loads the audio: failing to measure the file must
    not stop us transcribing it, and librosa would cost more than the call.
    """
    probe = _ffprobe_path()
    if probe:
        try:
            out = subprocess.run(
                [probe, "-v", "error", "-show_entries", "format=duration",
                 "-of", "default=noprint_wrappers=1:nokey=1", audio_path],
                capture_output=True, text=True, timeout=20,
                creationflags=_NO_WINDOW_FLAGS)
            dur = float((out.stdout or "").strip())
            if dur > 0:
                return dur
        except Exception:
            pass
    if audio_path.lower().endswith(".wav"):
        try:
            with wave.open(audio_path, "rb") as w:
                rate = w.getframerate()
                if rate:
                    return w.getnframes() / float(rate)
        except Exception:
            pass
    try:
        return os.path.getsize(audio_path) / 16000.0
    except OSError:
        return 0.0


def _stt_timeout_for(duration_s: float) -> float:
    """Read timeout sized to the work.

    A 3-minute clip and a 60-minute talk are not the same request, so one
    fixed number is wrong by definition — too tight for the talk or uselessly
    slack for the clip. Note this is a per-socket-read timeout: it bounds how
    long Scribe may stay silent, not how long the job may take.
    """
    scaled = float(duration_s) * _STT_TIMEOUT_PER_S
    return max(_STT_TIMEOUT_FLOOR, min(scaled, _STT_TIMEOUT_CAP))


def _redact_proxy_url(value: str) -> str:
    """Strip any user:password@ out of a proxy URL before it reaches a log."""
    return re.sub(r"://[^/@\s]*@", "://<credentials>@", value)


def _proxy_env_note() -> str:
    """Proxy environment as one line, credentials removed; '' when unset.

    Worth logging on every run: a proxy on one desk and none on another is
    the usual difference between "works" and "times out", and nobody can see
    it after the fact unless the run log recorded it.
    """
    seen: Dict[str, str] = {}
    for name in _PROXY_ENV_VARS:
        val = (os.environ.get(name) or "").strip()
        if val:
            seen[name.upper()] = _redact_proxy_url(val)
    return ", ".join(f"{k}={v}" for k, v in sorted(seen.items()))


def _stt_key_precheck(api_key: str) -> None:
    """Validate the API key once per process with one cheap GET /v1/user.

    Failing in two seconds with "your API key is wrong" beats failing in
    eight minutes with a stack trace, after a 58 MB upload. A network failure
    here is NOT fatal, though — that is exactly what the retry loop below is
    for, so an unreachable /v1/user only logs and continues. Only a key the
    server actively rejects (401) stops the run, because it will keep being
    rejected no matter how many times we upload the audio.
    """
    fingerprint = _api_key_fingerprint(api_key)
    if fingerprint in _STT_KEYS_CHECKED:
        return
    try:
        info = _validate_api_key(api_key)
    except ValueError as e:
        msg = str(e)
        # _validate_api_key flattens everything into ValueError; the "(401)"
        # marker and the empty-key message are the two verdicts that are
        # about the key itself rather than about the network.
        if "(401)" in msg or "API key is empty" in msg:
            raise
        _stt_log(f"key precheck inconclusive ({msg}) — continuing to the "
                 "upload anyway.")
        return
    _STT_KEYS_CHECKED.add(fingerprint)
    _stt_log(f"API key {_redact_api_key(api_key)} accepted"
             + (f" (tier: {info['tier']})" if info.get("tier") else "") + ".")


def _stt_preflight(audio_path: str, api_key: str) -> None:
    """Cheap checks before an expensive upload. Fail fast, be patient later."""
    if not audio_path or not os.path.isfile(audio_path):
        raise ValueError(
            f"Audio file to transcribe does not exist: {audio_path}")
    if os.path.getsize(audio_path) <= 0:
        raise ValueError(f"Audio file to transcribe is empty (0 bytes): "
                         f"{audio_path}")
    proxies = _proxy_env_note()
    if proxies:
        _stt_log(f"proxy environment: {proxies}")
    _stt_key_precheck(api_key)


class _Heartbeat:
    """Print '<n>s elapsed' every 30 s while a blocking call runs.

    Without this the log printed "Transcribing…" and then went silent for
    minutes: nobody — operator or developer — could tell working from hung,
    which is why the original failure needed a stack trace to diagnose at
    all. Daemon thread, so it can never hold the process open.
    """

    def __init__(self, label: str, interval: float = _STT_HEARTBEAT_SECS):
        self._label = label
        self._interval = interval
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._started = 0.0

    def __enter__(self) -> "_Heartbeat":
        self._started = time.monotonic()
        self._thread = threading.Thread(target=self._tick, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc_info) -> bool:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=1.0)
        return False

    def _tick(self) -> None:
        while not self._stop.wait(self._interval):
            _stt_log(f"{self._label} — {int(self.elapsed())}s elapsed")

    def elapsed(self) -> float:
        return time.monotonic() - self._started


def _transcript_cache_path(audio_path: str) -> str:
    """Cache file for this exact audio file.

    Keyed on absolute path + size + mtime, so a re-rendered or edited audio
    file can never reuse a stale transcript.
    """
    abs_path = os.path.abspath(audio_path)
    try:
        st = os.stat(abs_path)
        stamp = f"{abs_path}|{st.st_size}|{int(st.st_mtime)}"
    except OSError:
        stamp = abs_path
    digest = hashlib.sha1(stamp.encode("utf-8", "replace")).hexdigest()[:16]
    name = re.sub(r"[^A-Za-z0-9_.-]", "_", os.path.basename(abs_path))[:60]
    return os.path.join(_STT_CACHE_DIR, f"{name}.{digest}.json")


def _load_cached_transcript(audio_path: str) -> Optional[dict]:
    """Return a previously checkpointed Scribe payload, or None."""
    try:
        with open(_transcript_cache_path(audio_path), "r",
                  encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return None
    return data if isinstance(data, dict) and data.get("words") else None


def _save_cached_transcript(audio_path: str, result: dict) -> None:
    """Checkpoint the Scribe JSON the moment it arrives.

    A crash in a later stage must not re-upload and re-pay for a
    transcription already in hand. Best effort and atomic: a cache we cannot
    write is no reason to fail a run that just succeeded.
    """
    path = _transcript_cache_path(audio_path)
    try:
        os.makedirs(_STT_CACHE_DIR, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False)
        os.replace(tmp, path)
    except Exception as e:
        _stt_log(f"WARNING: could not checkpoint the transcript ({e}) — a "
                 "re-run will transcribe again.")


def _stt_retryable(exc: BaseException) -> bool:
    """Is this failure worth another attempt?

    Retry the transient ones — read timeouts, dropped connections, truncated
    bodies, 429 and 5xx. Never retry the verdicts in _STT_FATAL_HTTP.
    """
    if isinstance(exc, urllib.error.HTTPError):   # checked first: it IS a URLError
        return exc.code not in _STT_FATAL_HTTP and (exc.code == 429
                                                    or exc.code >= 500)
    return isinstance(exc, (TimeoutError, socket.timeout, ssl.SSLError,
                            ConnectionError, urllib.error.URLError,
                            http.client.HTTPException, json.JSONDecodeError))


def _stt_retry_after(exc: BaseException) -> float:
    """Seconds the server explicitly asked us to wait (429/503), else 0.0.

    Honouring Retry-After beats guessing: a rate limit usually clears in
    seconds, and ignoring the header risks tripping it again. Capped by the
    caller. The HTTP-date form is ignored — our own backoff covers it.
    """
    headers = getattr(exc, "headers", None)
    raw = headers.get("Retry-After") if headers else None
    try:
        return max(0.0, float(str(raw).strip()))
    except (TypeError, ValueError):
        return 0.0


def _stt_error_detail(exc: BaseException) -> str:
    """Short human phrasing of a failure — no stack trace needed to read it."""
    if isinstance(exc, urllib.error.HTTPError):
        return f"HTTP {exc.code} from ElevenLabs"
    if isinstance(exc, (TimeoutError, socket.timeout)):
        return "read timeout — the upload finished, the answer never arrived"
    if isinstance(exc, urllib.error.URLError):
        return f"network error: {exc.reason}"
    if isinstance(exc, json.JSONDecodeError):
        return "malformed response body (truncated?)"
    return f"{type(exc).__name__}: {exc}"


def _transcribe_audio(audio_path, api_key, use_cache: bool = True):
    """Transcribe *audio_path* with ElevenLabs Scribe. Returns the Scribe JSON.

    Retries transient network failures with backoff, sizes the read timeout
    to the audio length, preflights the cheap checks before uploading, prints
    a heartbeat while it waits, and checkpoints the result so a crash in a
    later stage never re-uploads the same audio. Pass use_cache=False to
    force a fresh transcription.
    """
    audio_path = os.path.abspath(os.path.expanduser(str(audio_path)))

    if use_cache:
        cached = _load_cached_transcript(audio_path)
        if cached is not None:
            _stt_log(f"reusing the checkpointed transcript for "
                     f"{os.path.basename(audio_path)} "
                     f"({len(cached.get('words') or [])} word tokens) — no "
                     "re-upload, no re-charge.")
            return cached

    _stt_preflight(audio_path, api_key)

    with open(audio_path, "rb") as f:
        audio_data = f.read()
    mime, _ = mimetypes.guess_type(audio_path)
    mime = mime or "audio/mpeg"
    body, boundary = _multipart_body(
        fields=[("model_id", "scribe_v2")],
        files=[("file", os.path.basename(audio_path), mime, audio_data)],
    )
    del audio_data          # the multipart copy is the only one the retries need

    duration = _audio_duration_seconds(audio_path)
    timeout = _stt_timeout_for(duration)
    megabytes = len(body) / (1024.0 * 1024.0)
    _stt_log(f"audio {_fmt_duration(duration)} | upload {megabytes:.1f} MB | "
             f"timeout {int(timeout)}s | up to {_STT_ATTEMPTS} attempts")

    for attempt in range(1, _STT_ATTEMPTS + 1):
        # Rebuilt per attempt: a urllib Request is consumed by urlopen, the
        # body bytes are not.
        req = urllib.request.Request(
            "https://api.elevenlabs.io/v1/speech-to-text",
            data=body, method="POST",
            headers={"xi-api-key": api_key,
                     "Content-Type": f"multipart/form-data; boundary={boundary}"},
        )
        with _Heartbeat(f"waiting for Scribe (attempt {attempt}/"
                        f"{_STT_ATTEMPTS})") as beat:
            try:
                with _urlopen(req, timeout=timeout) as resp:
                    raw = resp.read()
                result = json.loads(raw.decode("utf-8", errors="replace"))
                if not isinstance(result, dict):
                    raise ValueError("Scribe returned an unexpected payload "
                                     f"shape ({type(result).__name__}).")
            except Exception as e:
                waited = int(beat.elapsed())
                detail = _stt_error_detail(e)
                if isinstance(e, urllib.error.HTTPError) and e.code == 401:
                    raise ValueError(
                        "Invalid or expired ElevenLabs API key (401).") from None
                if not _stt_retryable(e) or attempt == _STT_ATTEMPTS:
                    proxies = _proxy_env_note()
                    raise RuntimeError(
                        f"ElevenLabs Scribe transcription failed after "
                        f"{attempt} attempt(s): {detail}. Last attempt waited "
                        f"{waited}s of a {int(timeout)}s timeout for "
                        f"{os.path.basename(audio_path)} "
                        f"({_fmt_duration(duration)}, {megabytes:.1f} MB)."
                        + (f" Proxy environment: {proxies}." if proxies else "")
                        + " If this machine sits behind a proxy or TLS "
                          "inspection, allow api.elevenlabs.io through it; "
                          "otherwise re-run — a successful transcript is "
                          "checkpointed and never re-uploaded.") from e
                delay = _STT_BACKOFF_SECS[min(attempt - 1,
                                              len(_STT_BACKOFF_SECS) - 1)]
                delay = max(delay, min(_stt_retry_after(e), 120.0))
                _stt_log(f"attempt {attempt} failed after {waited}s: "
                         f"{detail} — retrying in {int(delay)}s")
                time.sleep(delay)
                continue
            words = result.get("words") or []
            _stt_log(f"attempt {attempt} OK — {len(words)} word tokens in "
                     f"{int(beat.elapsed())}s")
        _save_cached_transcript(audio_path, result)
        return result
