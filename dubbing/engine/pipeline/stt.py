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

import json
import mimetypes
import os
import re
import urllib.error
import urllib.request
from typing import Dict, List, Optional

from .config import (_SSL_CTX, TTS_DEFAULT_LANGUAGE, TTS_SETTINGS_FILE,
                     _lang_tokens, load_tts_settings, load_engine_settings)
from .net import get_audio_duration, request_with_retry

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
    req = urllib.request.Request(
        "https://api.elevenlabs.io/v1/user",
        method="GET",
        headers={"xi-api-key": api_key, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_SSL_CTX) as resp:
            payload = json.loads(resp.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise ValueError("Invalid or expired ElevenLabs API key (401).") from None
        if e.code == 429:
            raise ValueError("ElevenLabs API rate limit hit (429). Try again shortly.") from None
        raise ValueError(f"ElevenLabs API error: HTTP {e.code}.") from None
    except urllib.error.URLError as e:
        raise ValueError(f"Network error reaching ElevenLabs: {e.reason}") from None
    except Exception as e:
        raise ValueError(f"Could not validate ElevenLabs key: {e}") from None

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


def _fetch_voices_for_language(api_key: str,
                               language: str = TTS_DEFAULT_LANGUAGE,
                               force_refresh: bool = False,
                               timeout: float = 30.0) -> List[Dict[str, str]]:
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
    """
    api_key = (api_key or "").strip()
    if not api_key:
        raise ValueError("API key is empty.")

    lang_tokens = _lang_tokens(language)
    cache_key   = (_api_key_fingerprint(api_key), language)
    if not force_refresh and cache_key in _EL_VOICE_CACHE:
        return _EL_VOICE_CACHE[cache_key]

    req = urllib.request.Request(
        "https://api.elevenlabs.io/v1/voices",
        method="GET",
        headers={"xi-api-key": api_key, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_SSL_CTX) as resp:
            payload = json.loads(resp.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise ValueError("Invalid or expired ElevenLabs API key (401).") from None
        if e.code == 429:
            raise ValueError("ElevenLabs API rate limit hit (429). Try again shortly.") from None
        raise ValueError(f"Could not fetch voices (HTTP {e.code}).") from None
    except urllib.error.URLError as e:
        raise ValueError(f"Network error fetching voices: {e.reason}") from None
    except Exception as e:
        raise ValueError(f"Could not fetch voices: {e}") from None

    voices = payload.get("voices") or []
    if not isinstance(voices, list):
        voices = []

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


def _transcribe_audio(audio_path, api_key, label="", status_cb=None):
    """
    Transcribe audio with ElevenLabs Scribe (model_id=scribe_v2).

    Includes Scribe transcript checkpointing: saves/loads JSON from {base}_scribe_en.json
    (or _scribe_te.json) when audio (file_size, mtime) fingerprint matches.
    Employs adaptive timeout scaling based on audio duration and retry with exponential backoff.
    """
    def _log(msg):
        if status_cb:
            status_cb(msg)
        else:
            tag = f"[{label}] " if label else "[STT] "
            print(f"{tag}{msg}", flush=True)

    # 1. Checkpoint lookup
    stem = os.path.splitext(audio_path)[0]
    ckpt_suffix = "_scribe_te.json" if ("S3b" in label or "_tts" in os.path.basename(audio_path)) else "_scribe_en.json"
    ckpt_path = stem + ckpt_suffix

    try:
        st = os.stat(audio_path)
        cur_fp = {"size": st.st_size, "mtime": st.st_mtime}
        if os.path.isfile(ckpt_path):
            with open(ckpt_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict) and data.get("fingerprint") == cur_fp and "result" in data:
                _log(f"Reusing cached Scribe transcript from {os.path.basename(ckpt_path)}")
                return data["result"]
    except Exception:
        pass

    # 2. Prepare multipart request
    with open(audio_path, "rb") as f:
        audio_data = f.read()
    mime, _ = mimetypes.guess_type(audio_path)
    mime = mime or "audio/mpeg"
    body, boundary = _multipart_body(
        fields=[("model_id", "scribe_v2")],
        files=[("file", os.path.basename(audio_path), mime, audio_data)],
    )
    req = urllib.request.Request(
        "https://api.elevenlabs.io/v1/speech-to-text",
        data=body, method="POST",
        headers={"xi-api-key": api_key,
                 "Content-Type": f"multipart/form-data; boundary={boundary}"},
    )

    # 3. Adaptive timeout & retry
    cfg = load_engine_settings()
    stt_min = float(cfg.get("stt_timeout_min", 600.0))
    stt_scale = float(cfg.get("stt_timeout_scale", 2.0))
    stt_max = float(cfg.get("stt_timeout_max", 7200.0))
    attempts = int(cfg.get("retry_attempts", 4))
    raw_backoff = cfg.get("retry_backoff", [5.0, 15.0, 45.0])
    backoff = tuple(float(x) for x in raw_backoff) if isinstance(raw_backoff, (list, tuple)) else (5.0, 15.0, 45.0)

    dur_s = get_audio_duration(audio_path)
    calc_timeout = max(stt_min, dur_s * stt_scale)
    timeout = min(stt_max, calc_timeout)

    tag = f"[{label}]" if label else "[Scribe STT]"
    _log(f"Sending {len(audio_data)/(1024*1024):.1f} MB audio ({int(dur_s)}s duration) to Scribe (timeout {int(timeout)}s)…")

    resp_bytes = request_with_retry(
        req, timeout=timeout, attempts=attempts, backoff=backoff,
        label=tag, context=_SSL_CTX, log=_log
    )
    result = json.loads(resp_bytes.decode("utf-8"))

    # 4. Save checkpoint
    try:
        st = os.stat(audio_path)
        ckpt_data = {
            "fingerprint": {"size": st.st_size, "mtime": st.st_mtime},
            "result": result
        }
        with open(ckpt_path, "w", encoding="utf-8") as f:
            json.dump(ckpt_data, f, indent=2)
    except Exception as e:
        _log(f"Warning: could not write Scribe transcript checkpoint {os.path.basename(ckpt_path)}: {e}")

    return result
