"""
Pipeline configuration: paths, constants, language table, ffmpeg discovery
and settings-file loaders.

Extracted from Translation_and_Syncing_App.py (bulk app, v1.8.0):
    lines 144-146   SSL context (was unverified; replaced here with the
                    verified-first strategy from sync_matcher.py — see below)
    lines 150-198   platform flags + ffmpeg discovery (Tk font selection skipped)
    lines 446-481   _prepare_output_dir (per-file output folder helper)
    lines 696-990   TTS language/voice catalogue, ElevenLabs model table,
                    LLM provider constants, chunk limits, region-detection
                    defaults (Tk colour palette / theme / UI persistence
                    helpers skipped)

Adaptations (everything else is verbatim):
  * SCRIPT_DIR-based paths repointed to this repo: settings live in
    <repo>/config/, prompts in <repo>/prompts/, data in <repo>/data/.
  * New loaders for config/tts_settings.json (this repo's TTS settings
    file, written by the REAPER panel / setup script).
  * The optional pydub import guard lives here so every pipeline module
    shares one _AudioSegment / PYDUB_AVAILABLE pair.
"""

import json
import os
import re
import shutil
import ssl
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from typing import Dict, List, Optional

# ─── Repo paths ──────────────────────────────────────────────────────────────
# This file lives at <repo>/engine/pipeline/config.py.
PIPELINE_DIR = os.path.dirname(os.path.abspath(__file__))
ENGINE_DIR   = os.path.dirname(PIPELINE_DIR)
REPO_DIR     = os.path.dirname(ENGINE_DIR)
CONFIG_DIR   = os.path.join(REPO_DIR, "config")
PROMPTS_DIR  = os.path.join(REPO_DIR, "prompts")
DATA_DIR     = os.path.join(REPO_DIR, "data")

LLM_SETTINGS_FILE = os.path.join(CONFIG_DIR, "llm_settings.json")
TTS_SETTINGS_FILE = os.path.join(CONFIG_DIR, "tts_settings.json")

# ─── Cross-platform setup ────────────────────────────────────────────────────
IS_WINDOWS = sys.platform.startswith("win")
IS_MAC     = sys.platform == "darwin"


def _find_ffmpeg() -> Optional[str]:
    """Locate ffmpeg. Checks PATH, then a bundled ffmpeg/bin folder in the
    repo root, then common Windows install locations. Returns the executable
    path or None."""
    exe = "ffmpeg.exe" if IS_WINDOWS else "ffmpeg"
    found = shutil.which("ffmpeg")
    if found:
        return found
    candidates = [os.path.join(REPO_DIR, "ffmpeg", "bin", exe),
                  os.path.join(REPO_DIR, "ffmpeg", exe)]
    if IS_WINDOWS:
        candidates += [
            os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Links\ffmpeg.exe"),
            os.path.expandvars(r"%ProgramFiles%\ffmpeg\bin\ffmpeg.exe"),
            r"C:\ffmpeg\bin\ffmpeg.exe",
        ]
    elif IS_MAC:
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    for c in candidates:
        if os.path.isfile(c):
            return c
    return None


FFMPEG_PATH = _find_ffmpeg()
if FFMPEG_PATH and not shutil.which("ffmpeg"):
    # Make ffmpeg visible to pydub/librosa even when it isn't on PATH. This has
    # to run BEFORE pydub is imported below: pydub probes for ffmpeg at import
    # time and prints a RuntimeWarning when PATH lacks it, which it does for a
    # Homebrew install (/opt/homebrew/bin) under a GUI-launched process.
    os.environ["PATH"] = os.path.dirname(FFMPEG_PATH) + os.pathsep + os.environ.get("PATH", "")

# ─── Optional pydub (shared by srt_tools / tts / sync) ───────────────────────
try:
    from pydub import AudioSegment as _AudioSegment
    PYDUB_AVAILABLE = True
except ImportError:
    _AudioSegment = None
    PYDUB_AVAILABLE = False

if FFMPEG_PATH and PYDUB_AVAILABLE:
    _AudioSegment.converter = FFMPEG_PATH

# ─── TLS: verified first, insecure only as a proven last resort ──────────────
# This engine used to build ONE unverified context (check_hostname=False,
# verify_mode=CERT_NONE) and pass it to every provider call. That silently
# disabled certificate checking for requests carrying the user's ElevenLabs
# and Google API keys, on every network — so anything on the path could
# present any certificate and read them.
#
# The Auto Sync half of this repo already solved the same corporate-proxy
# problem safely (sync_matcher.py). This is that strategy, ported verbatim in
# spirit so the repo has ONE TLS policy:
#   1. Verify against the OS trust store (+ certifi), with Python 3.13's
#      VERIFY_X509_STRICT relaxed so certs lacking an Authority Key Identifier
#      still validate. This succeeds whenever the inspection proxy's root is
#      installed — which is the normal corporate case.
#   2. ONLY after a genuine certificate-VERIFY failure, print a one-time
#      warning and retry that HOST with verification disabled.
# Non-certificate errors (HTTP 4xx/5xx, timeouts, DNS) always propagate.
#
# The downgrade is scoped PER HOST, not process-wide: one endpoint sitting
# behind an untrusted inspection root must not silently disable verification
# for every other endpoint the run touches afterwards.
_SSL_CTX: Optional[ssl.SSLContext] = None
_SSL_INSECURE_CTX: Optional[ssl.SSLContext] = None
_SSL_LOCK = threading.Lock()
_SSL_INSECURE_HOSTS: set = set()
_SSL_INSECURE_WARNED = False


def _ssl_context() -> ssl.SSLContext:
    """Cached verified context, tolerant of TLS-inspecting corporate proxies."""
    global _SSL_CTX
    if _SSL_CTX is not None:
        return _SSL_CTX
    ctx = ssl.create_default_context()
    if hasattr(ssl, "VERIFY_X509_STRICT"):
        ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT
    try:
        import certifi
        ctx.load_verify_locations(certifi.where())
    except (ImportError, ssl.SSLError, OSError):
        pass
    _SSL_CTX = ctx
    return ctx


def _insecure_ssl_context() -> ssl.SSLContext:
    """Last-resort unverified context. Only reached after a real cert-verify
    failure — i.e. an inspection root that is not in the trust store."""
    global _SSL_INSECURE_CTX
    if _SSL_INSECURE_CTX is None:
        c = ssl.create_default_context()
        c.check_hostname = False
        c.verify_mode = ssl.CERT_NONE
        _SSL_INSECURE_CTX = c
    return _SSL_INSECURE_CTX


def _is_cert_verify_error(err: BaseException) -> bool:
    """True ONLY for TLS certificate-VERIFICATION failures.

    Deliberately strict: it walks the exception chain and accepts nothing but
    typed ssl errors carrying a verification result. It does NOT substring-match
    free text, because `URLError.reason` can be an arbitrary server-supplied
    string — an HTTP reason phrase containing "self signed certificate" must
    never be able to talk this client out of verifying certificates.
    """
    # HTTPError subclasses URLError, but reaching an HTTP status means the TLS
    # handshake already succeeded. Never a certificate problem.
    if isinstance(err, urllib.error.HTTPError):
        return False
    cur: Optional[BaseException] = err
    for _ in range(10):                       # bounded: chains can be cyclic
        if cur is None:
            break
        if isinstance(cur, ssl.SSLCertVerificationError):
            return True
        if isinstance(cur, ssl.SSLError):
            # verify_code is set by OpenSSL only for verification failures.
            if getattr(cur, "verify_code", None) is not None:
                return True
            if getattr(cur, "reason", None) == "CERTIFICATE_VERIFY_FAILED":
                return True
        nxt = getattr(cur, "reason", None)
        if not isinstance(nxt, BaseException):
            nxt = cur.__cause__ or cur.__context__
        cur = nxt if isinstance(nxt, BaseException) else None
    return False


def _request_host(req) -> str:
    """Host[:port] a Request targets — the key the insecure downgrade is
    scoped by. Falls back to the whole value if it cannot be parsed, which
    only ever makes the scope narrower."""
    try:
        return urllib.parse.urlsplit(req.full_url).netloc.lower()
    except Exception:
        return str(getattr(req, "host", "") or "").lower()


def _urlopen(req, timeout: int = 120):
    """urlopen with a verified-first, per-host insecure-fallback TLS strategy.

    Drop-in for `urllib.request.urlopen(req, timeout=..., context=_SSL_CTX)`,
    which is what every call site here used to do unconditionally.
    """
    host = _request_host(req)
    with _SSL_LOCK:
        already_insecure = host in _SSL_INSECURE_HOSTS
    if already_insecure:
        return urllib.request.urlopen(req, timeout=timeout,
                                      context=_insecure_ssl_context())
    try:
        return urllib.request.urlopen(req, timeout=timeout, context=_ssl_context())
    except urllib.error.URLError as e:
        if not _is_cert_verify_error(e):
            raise
        global _SSL_INSECURE_WARNED
        with _SSL_LOCK:
            _SSL_INSECURE_HOSTS.add(host)
            warn = not _SSL_INSECURE_WARNED
            _SSL_INSECURE_WARNED = True
        if warn:
            print("    [SSL] Certificate verification failed - a TLS-inspection "
                  "proxy/antivirus is likely intercepting HTTPS. Retrying with "
                  "verification DISABLED for the affected host(s) this run.",
                  flush=True)
        return urllib.request.urlopen(req, timeout=timeout,
                                      context=_insecure_ssl_context())


# ─── TTS Language / Voice catalogue ─────────────────────────────────────────
# Single source of truth for every per-language artefact: BCP-47 locale code,
# native autonym, ElevenLabs language-token filter, and Google Cloud TTS voice
# catalogue per engine family (Standard / WaveNet / Chirp3-HD).
#
# Languages without native Google Cloud TTS coverage (Assamese, Odia, Nepali)
# carry "google_unavailable": True — only ElevenLabs is offered for synthesis
# on those.
#
# Chirp3-HD voice characters (Algenib, Aoede, Charon, Fenrir, Kore, Leda,
# Orus, Puck, Schedar, Zephyr) are the same set across all Indic locales
# where Chirp3 is offered; only the locale prefix changes.

def _std_voices(code: str) -> List[str]:
    return [f"{code}-Standard-A", f"{code}-Standard-B",
            f"{code}-Standard-C", f"{code}-Standard-D"]

def _wn_voices(code: str) -> List[str]:
    return [f"{code}-Wavenet-A", f"{code}-Wavenet-B",
            f"{code}-Wavenet-C", f"{code}-Wavenet-D"]

def _c3_voices(code: str) -> List[str]:
    return [f"{code}-Chirp3-HD-Algenib", f"{code}-Chirp3-HD-Aoede",
            f"{code}-Chirp3-HD-Charon",  f"{code}-Chirp3-HD-Fenrir",
            f"{code}-Chirp3-HD-Kore",    f"{code}-Chirp3-HD-Leda",
            f"{code}-Chirp3-HD-Orus",    f"{code}-Chirp3-HD-Puck",
            f"{code}-Chirp3-HD-Schedar", f"{code}-Chirp3-HD-Zephyr"]

TTS_LANGUAGES = {
    "Bengali": {
        "code": "bn-IN", "autonym": "বাংলা", "tag": "BN", "display_name": "Bangla",
        "el_tokens": ("bn", "ben", "bengali", "bangla", "bn-in", "bn-bd", "বাংলা"),
        "Standard": _std_voices("bn-IN"),
        "WaveNet":  _wn_voices("bn-IN"),
        "Chirp3":   _c3_voices("bn-IN"),
    },
    "Hindi": {
        "code": "hi-IN", "autonym": "हिन्दी", "tag": "HI", "display_name": "Hindi",
        "el_tokens": ("hi", "hin", "hindi", "हिन्दी", "hi-in"),
        "Standard": _std_voices("hi-IN"),
        "WaveNet":  _wn_voices("hi-IN"),
        "Chirp3":   _c3_voices("hi-IN"),
    },
    "Kannada": {
        "code": "kn-IN", "autonym": "ಕನ್ನಡ", "tag": "KN", "display_name": "Kannada",
        "el_tokens": ("kn", "kan", "kannada", "ಕನ್ನಡ", "kn-in"),
        "Standard": _std_voices("kn-IN"),
        "WaveNet":  _wn_voices("kn-IN"),
        "Chirp3":   _c3_voices("kn-IN"),
    },
    "Malayalam": {
        "code": "ml-IN", "autonym": "മലയാളം", "tag": "ML", "display_name": "Malayalam",
        "el_tokens": ("ml", "mal", "malayalam", "മലയാളം", "ml-in"),
        "Standard": _std_voices("ml-IN"),
        "WaveNet":  _wn_voices("ml-IN"),
        "Chirp3":   _c3_voices("ml-IN"),
    },
    "Tamil": {
        "code": "ta-IN", "autonym": "தமிழ்", "tag": "TA", "display_name": "Tamil",
        "el_tokens": ("ta", "tam", "tamil", "தமிழ்", "ta-in", "ta-lk"),
        "Standard": _std_voices("ta-IN"),
        "WaveNet":  _wn_voices("ta-IN"),
        "Chirp3":   _c3_voices("ta-IN"),
    },
    "Telugu": {
        "code": "te-IN", "autonym": "తెలుగు", "tag": "TE", "display_name": "Telugu",
        "el_tokens": ("te", "tel", "telugu", "తెలుగు", "te-in"),
        "Standard": _std_voices("te-IN"),
        "WaveNet":  _wn_voices("te-IN"),
        "Chirp3":   _c3_voices("te-IN"),
    },
    "Gujarati": {
        "code": "gu-IN", "autonym": "ગુજરાતી", "tag": "GU", "display_name": "Gujarati",
        "el_tokens": ("gu", "guj", "gujarati", "ગુજરાતી", "gu-in"),
        "Standard": _std_voices("gu-IN"),
        "WaveNet":  _wn_voices("gu-IN"),
        "Chirp3":   _c3_voices("gu-IN"),
    },
    "Marathi": {
        "code": "mr-IN", "autonym": "मराठी", "tag": "MR", "display_name": "Marathi",
        "el_tokens": ("mr", "mar", "marathi", "मराठी", "mr-in"),
        "Standard": _std_voices("mr-IN"),
        "WaveNet":  _wn_voices("mr-IN"),
        "Chirp3":   _c3_voices("mr-IN"),
    },
    "Punjabi": {
        "code": "pa-IN", "autonym": "ਪੰਜਾਬੀ", "tag": "PA", "display_name": "Punjabi",
        "el_tokens": ("pa", "pan", "pnb", "punjabi", "panjabi", "ਪੰਜਾਬੀ", "pa-in"),
        "Standard": _std_voices("pa-IN"),
        "WaveNet":  _wn_voices("pa-IN"),
        "Chirp3":   _c3_voices("pa-IN"),
    },
    # Google Cloud TTS does not currently expose native voices for the
    # following languages — only ElevenLabs is available for synthesis.
    "Assamese": {
        "code": "as-IN", "autonym": "অসমীয়া", "tag": "AS", "display_name": "Assamese",
        "el_tokens": ("as", "asm", "assamese", "অসমীয়া", "as-in"),
        "google_unavailable": True,
        "Standard": [], "WaveNet": [], "Chirp3": [],
    },
    "Odia": {
        "code": "or-IN", "autonym": "ଓଡ଼ିଆ", "tag": "OR", "display_name": "Odia",
        "el_tokens": ("or", "ori", "odia", "oriya", "ଓଡ଼ିଆ", "or-in"),
        "google_unavailable": True,
        "Standard": [], "WaveNet": [], "Chirp3": [],
    },
    "Nepali": {
        "code": "ne-NP", "autonym": "नेपाली", "tag": "NE", "display_name": "Nepali",
        "el_tokens": ("ne", "nep", "nepali", "नेपाली", "ne-np"),
        "google_unavailable": True,
        "Standard": [], "WaveNet": [], "Chirp3": [],
    },
}

# ─── User-added languages (v0.7) ────────────────────────────────────────────
# config/custom_languages.json, written by the panel's Settings tab:
#     {"languages": [{"name": "Konkani", "code": "kok-IN", "tag": "KOK",
#                     "display_name": "Konkani", "el_tokens": ["kok", "konkani"]}]}
# Entries are merged into TTS_LANGUAGES on import, so every downstream lookup
# (voice matching, output naming, prompt loading) treats them like a built-in.
# A name that collides with a built-in is IGNORED rather than overwriting it:
# the shipped table carries Google voice lists a hand-written entry cannot.
# Google Cloud TTS is marked unavailable — this engine dubs with ElevenLabs,
# which auto-detects the script from the text.
CUSTOM_LANGUAGES_FILE = os.path.join(CONFIG_DIR, "custom_languages.json")


# Which hand-edited custom_languages.json names are usable.
# KEEP IN SYNC with engine/run_dub.py, engine/dub_engine.py and
# dubbing/reaper/Dub_Pipeline_Panel.lua (V5._is_safe_lang_name).
# See run_dub.py for why all four readers carry the same rule, and for
# why the non-ASCII range must start at an explicit \u0080.
# Charset only -- length and edge-whitespace are checked in _lang_name_ok so
# the rule stays readable and matches the Lua predicate exactly.
_LANG_NAME_OK = re.compile("^[0-9A-Za-z \-_.()\u0080-\U0010FFFF]+$")


# Unicode whitespace, rejected anywhere in a name. Mirrors
# V5._has_unicode_space in Dub_Pipeline_Panel.lua, which matches the same
# code points as UTF-8 byte sequences because Lua's %s is ASCII-only.
_LANG_NAME_UNICODE_WS = re.compile(
    "[\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]")


def _lang_name_ok(name: str) -> bool:
    """True if *name* is usable EXACTLY as written. Never raises.

    Mirrors V5._is_safe_lang_name in dubbing/reaper/Dub_Pipeline_Panel.lua.
    The bound is 64 UTF-8 BYTES because that is what Lua's #s measures.

    Edge whitespace is compared against ASCII whitespace ONLY -- the exact set
    Lua's %s matches. Plain str.strip() would also strip U+00A0, U+2003 and
    other Unicode spaces that Lua does not recognise, and the two sides would
    then disagree about names starting with one.

    Leading/trailing whitespace is rejected, not stripped: stripping is a
    rewrite, and a rewritten name is a second spelling of the same entry.
    """
    if not isinstance(name, str) or not name:
        return False
    if name != name.strip(" \t\n\r\v\f"):
        return False
    if _LANG_NAME_UNICODE_WS.search(name):
        return False
    try:
        if len(name.encode("utf-8")) > 64:
            return False
    except (UnicodeEncodeError, UnicodeError):
        # Lone surrogate from a hand-edited "\udXXX" escape. json.load()
        # hands these back happily; encoding them raises. Return False rather
        # than propagating -- the caller in pipeline/config.py has no guard.
        return False
    return bool(_LANG_NAME_OK.match(name))


def _load_custom_languages() -> list:
    """Names of the user-added languages, after merging them into the table."""
    added = []
    try:
        with open(CUSTOM_LANGUAGES_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return added
    except Exception as e:
        print(f"[config] Could not read {CUSTOM_LANGUAGES_FILE}: {e} — "
              "user-added languages ignored.")
        return added
    entries = data.get("languages") if isinstance(data, dict) else None
    if not isinstance(entries, list):
        return added
    for e in entries:
        if not isinstance(e, dict):
            continue
        name = str(e.get("name") or "")
        if not name:
            continue
        if not _lang_name_ok(name):
            # Same rule as run_dub.py, dub_engine.py and the REAPER panel —
            # see run_dub.py for why all four readers carry their own copy.
            # Rejected, never rewritten: a cleaned-up name would be a second
            # spelling the other readers know nothing about.
            print(f"[config] Custom language {name!r} has characters that are "
                  "not allowed in a language name — entry ignored.")
            continue
        if name in TTS_LANGUAGES:
            print(f"[config] Custom language {name!r} shadows a built-in — "
                  "keeping the built-in entry.")
            continue
        code = str(e.get("code") or "").strip() or "en-IN"
        tokens = e.get("el_tokens")
        if not isinstance(tokens, (list, tuple)) or not tokens:
            tokens = [name.lower(), code.split("-")[0].lower()]
        TTS_LANGUAGES[name] = {
            "code": code,
            "autonym": str(e.get("autonym") or name),
            "tag": (str(e.get("tag") or name[:2]).upper())[:4],
            "display_name": str(e.get("display_name") or name),
            "el_tokens": tuple(str(t).lower() for t in tokens),
            "google_unavailable": True,
            "Standard": [], "WaveNet": [], "Chirp3": [],
        }
        added.append(name)
    return added


CUSTOM_LANGUAGE_NAMES = _load_custom_languages()
TTS_LANGUAGE_NAMES   = list(TTS_LANGUAGES.keys())
TTS_DEFAULT_LANGUAGE = "Bengali"

def _lang_display_name(language: str) -> str:
    """Return the output-folder-friendly display name for a language (e.g. 'Bangla' for Bengali)."""
    return TTS_LANGUAGES.get(language, {}).get("display_name", language)

def _tts_output_name(language: str, audio_path: str, suffix: str = "_tts") -> str:
    """
    Build the output filename stem using the convention:
        {DisplayName}_({audio_base}){suffix}.wav
    e.g.  Bangla_(MyLecture)_tts.wav  or  Bangla_(MyLecture)_synced.wav
    """
    display   = _lang_display_name(language)
    audio_base = os.path.splitext(os.path.basename(audio_path))[0]
    return f"{display}_({audio_base}){suffix}.wav"

def _strip_emotion_tags(text: str) -> str:
    """Strip ElevenLabs inline emotion/accent tags like [calm],
    [bengali accent], [pause] — including closers like [/fast]."""
    return re.sub(r'\[/?[\w\s]+\]', '', text).strip()

TTS_DEFAULT_ENGINE   = "Chirp3"
TTS_DEFAULT_VOICE    = "bn-IN-Chirp3-HD-Aoede"

# ─── ElevenLabs TTS settings ─────────────────────────────────────────────────
# Default voice ID is empty — voices are auto-fetched from the ElevenLabs API
# once a valid key is supplied (see stt._fetch_voices_for_language).
ELEVENLABS_TTS_VOICE_ID = ""
# eleven_v3 auto-detects the language from the input text (Indic scripts
# inclusive). It does not accept a language_code parameter — sending one
# triggers HTTP 400 unsupported_language errors on multilingual models.
ELEVENLABS_TTS_MODEL    = "eleven_v3"
# Selectable ElevenLabs TTS models — all multilingual / Indic-capable.
# Only eleven_v3 understands inline audio tags ([calm], [pause], …); for the
# other models synthesize_tts_elevenlabs strips the tags before sending.
ELEVENLABS_TTS_MODELS   = {
    "eleven_v3":              "v3 — expressive (audio tags)",
    "eleven_multilingual_v2": "Multilingual v2 — stable",
    "eleven_turbo_v2_5":      "Turbo v2.5 — fast",
    "eleven_flash_v2_5":      "Flash v2.5 — fastest",
}
TTS_PLATFORMS           = ["ElevenLabs", "Google TTS"]
TTS_DEFAULT_PLATFORM    = "ElevenLabs"

# Gemini models available for translation / review / punctuation / mapping
GEMINI_MODELS         = ["gemini-2.5-pro", "gemini-3.5-flash"]
GEMINI_DEFAULT_MODEL  = "gemini-2.5-pro"

# ─── LLM provider settings ────────────────────────────────────────────────────
# The translation / review / punctuation / mapping / emotion steps can run on:
#   1. Vertex AI          — service-account JSON file (config/vertex_key.json)
#   2. Gemini API         — plain Google AI Studio API key
#   3. OpenAI-compatible  — any /v1/chat/completions endpoint (LiteLLM proxy,
#                           OpenRouter, vLLM, …) via a base URL + optional key
# Selection + credentials live in config/llm_settings.json (same schema as
# the bulk app's llm_settings.json), written by the REAPER panel / setup.
LLM_PROVIDER_VERTEX   = "Vertex AI (JSON file)"
LLM_PROVIDER_GEMINI   = "Gemini API key"
LLM_PROVIDER_OPENAI   = "OpenAI-compatible (Base URL)"
LLM_PROVIDERS         = [LLM_PROVIDER_VERTEX, LLM_PROVIDER_GEMINI, LLM_PROVIDER_OPENAI]
# Auto-Sync-only mode: every AI call is routed through the user's own server,
# which holds the real provider keys. The dubbing engine has no server path, so
# this value is recognised (the panel's Settings tab is the single home for
# every credential, sync ones included) only to fail with a clear message
# instead of silently falling back to another provider's key.
LLM_PROVIDER_SERVER   = "Server proxy (Auto Sync only)"
# Blank by default — OpenAI-compatible users set their own endpoint in the
# panel's ⚙ Settings (or config/llm_settings.json). Never ship an internal
# host here: this file has no secrets and is committed to a public repo.
LLM_DEFAULT_BASE_URL  = ""

# Step4: emotion / accent tag enrichment before ElevenLabs TTS.
# When enabled, runs an extra Gemini pass that injects ElevenLabs v3 inline
# audio tags ([<lang> accent], [calm], [contemplative], [slow], [pause], …)
# into the Step3 punctuated script so the final speech sounds human and
# reflective (Sadhguru-style cadence) rather than flat.
STEP4_EMOTION_ENABLED = True

def _lang_tokens(language: str) -> tuple:
    """ElevenLabs voice-metadata tokens for a given language display name."""
    return TTS_LANGUAGES.get(language, {}).get("el_tokens", ())

# Characters per ElevenLabs TTS request chunk
ELEVENLABS_CHUNK_CHARS = 1000

# ─── TTS byte-chunk limit ─────────────────────────────────────────────────────
TTS_MAX_BYTES = 4800   # Safe limit below the 5000-byte API cap

# ─── Default region detection params — English audio ─────────────────────────
DEFAULT_THR_DB  = -42.0
DEFAULT_HYS_DB  = 6.0
DEFAULT_MIN_MS  = 150

# ─── Default region detection params — target-language TTS audio ────────────
DEFAULT_BN_THR_DB = -42.0
DEFAULT_BN_HYS_DB = 10.0
DEFAULT_BN_MIN_MS = 80

AUDIO_EXTENSIONS = {".wav", ".mp3", ".flac", ".ogg", ".aiff", ".aif", ".m4a"}


# ─── TTS settings loader (new in v0.3 — replaces the app's api.txt et al.) ───
# config/tts_settings.json schema (contract v0.3):
#     {"elevenlabs_api_key": "...", "el_model": "...",
#      "voice_id": "...", "google_tts_key_path": "..."}
_TTS_SETTINGS_DEFAULTS: Dict[str, str] = {
    "elevenlabs_api_key":  "",
    "el_model":            ELEVENLABS_TTS_MODEL,
    "voice_id":            "",
    "google_tts_key_path": "",
}


def load_tts_settings() -> Dict[str, str]:
    """Load config/tts_settings.json over the defaults. Missing file or
    unreadable JSON returns the defaults — callers that need a specific key
    raise their own actionable error when it is empty."""
    settings = dict(_TTS_SETTINGS_DEFAULTS)
    try:
        with open(TTS_SETTINGS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            for k in _TTS_SETTINGS_DEFAULTS:
                if k in data and isinstance(data[k], str):
                    settings[k] = data[k]
    except FileNotFoundError:
        pass
    except Exception as e:
        print(f"[config] Could not read {TTS_SETTINGS_FILE}: {e} — using defaults.")
    return settings


# ─── Per-file output folder helper (app lines 446-481, verbatim) ─────────────
def _prepare_output_dir(audio_path: str) -> str:
    """
    Given the path to an input audio file, create (if needed) a sibling
    folder named after the audio file (without extension) and copy the
    original audio into that folder. Returns the path to the new folder.

    All pipeline outputs (SRT, FinalScript, TTS, sync logs, synced audio,
    etc.) for a given input file should be written inside this folder so
    that each input gets its own self-contained results directory.
    """
    src_dir   = os.path.dirname(os.path.abspath(audio_path))
    base_name = os.path.splitext(os.path.basename(audio_path))[0]
    # Already inside its own output folder (e.g. a reopened project whose
    # audio is the copy that lives in the results dir) — reuse it. Creating
    # a sibling again would nest folder/folder/folder… one level per re-run.
    if os.path.basename(src_dir) == base_name:
        return src_dir
    out_dir   = os.path.join(src_dir, base_name)
    try:
        os.makedirs(out_dir, exist_ok=True)
    except Exception:
        # If the directory cannot be created, fall back to source folder
        return src_dir

    # Copy the original audio file into the new folder (if not already there)
    dst_audio = os.path.join(out_dir, os.path.basename(audio_path))
    try:
        if (os.path.abspath(audio_path) != os.path.abspath(dst_audio)
                and not os.path.exists(dst_audio)):
            shutil.copy2(audio_path, dst_audio)
    except Exception:
        # Non-fatal — the rest of the pipeline can still run
        pass

    return out_dir
