#!/usr/bin/env python3
"""
Sync Matcher API proxy
======================
Holds the real provider API keys server-side so the Reaper client
(sync_matcher.py) never needs them. Clients authenticate with a per-user
bearer token you issue; the server attaches the real keys and forwards the
request to ElevenLabs / Gemini / OpenAI / Anthropic.

Run (local test on your Mac):
    cd server
    python -m venv venv && source venv/bin/activate
    pip install -r requirements.txt
    cp .env.example .env        # fill in your real keys + a client token
    set -a; source .env; set +a
    uvicorn main:app --host 0.0.0.0 --port 8000 --reload

Point the client at it:
    export SYNC_API_BASE="http://localhost:8000"
    export SYNC_API_TOKEN="<one of SYNC_CLIENT_TOKENS>"

Endpoints
    GET  /health
    POST /v1/elevenlabs/stt   multipart: file, [language_code]   -> ElevenLabs raw JSON
    POST /v1/gemini/stt       multipart: file, [language]        -> {"text": ...}
    POST /v1/translate        json: {text, source_lang, [model]} -> {"text": ...}
    POST /v1/match            json: {provider, prompt, [model]}  -> {"text": ...}
"""
import os
import time
import base64
import threading
from collections import defaultdict

import requests
from fastapi import FastAPI, UploadFile, File, Form, Header, HTTPException, Request

try:
    # Route outbound TLS through the OS certificate store (declared in
    # requirements.txt) — matches the client's behaviour behind corporate
    # TLS-inspection proxies. Optional: plain certifi verification otherwise.
    import truststore
    truststore.inject_into_ssl()
except Exception:
    pass

app = FastAPI(title="Sync Matcher API proxy", version="1.0")

# ── Real provider keys (server-side only) ────────────────────────────
ELEVENLABS_KEY = os.environ.get("SYNC_ELEVENLABS_KEY", "")
GEMINI_KEY     = os.environ.get("SYNC_GEMINI_KEY", "")
OPENAI_KEY     = os.environ.get("SYNC_OPENAI_KEY", "")
ANTHROPIC_KEY  = os.environ.get("SYNC_ANTHROPIC_KEY", "")

GEMINI_MATCHER_MODEL = os.environ.get("SYNC_GEMINI_MODEL", "gemini-2.5-pro")
GEMINI_AUDIO_MODEL   = os.environ.get("SYNC_GEMINI_AUDIO_MODEL", "gemini-2.5-flash")
OPENAI_MODEL         = os.environ.get("SYNC_OPENAI_MODEL", "gpt-4o")
ANTHROPIC_MODEL      = os.environ.get("SYNC_ANTHROPIC_MODEL", "claude-sonnet-4-5")

GLAPI = "https://generativelanguage.googleapis.com"

# ── Auth: per-client bearer tokens ───────────────────────────────────
def _client_tokens():
    raw = os.environ.get("SYNC_CLIENT_TOKENS", "")
    return {t.strip() for t in raw.split(",") if t.strip()}


def _auth(authorization):
    """Validate the client bearer token. Returns the token (used as the
    rate-limit key). If no tokens are configured the server runs open —
    fine for local testing, NOT for a shared/public deployment."""
    tokens = _client_tokens()
    if not tokens:
        return "anon"
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    tok = authorization.split(" ", 1)[1].strip()
    if tok not in tokens:
        raise HTTPException(status_code=403, detail="Invalid token")
    return tok


# ── Rate limit: per-token sliding window (in-memory) ─────────────────
# Good enough for a single-process test box. For a real multi-worker
# deployment move this to Redis so the window is shared across workers.
_RL_LOCK = threading.Lock()
_RL_HITS = defaultdict(list)
_RL_MAX  = int(os.environ.get("SYNC_RL_PER_MIN", "60"))


def _rate_limit(key):
    now = time.time()
    with _RL_LOCK:
        hits = _RL_HITS[key]
        cutoff = now - 60.0
        while hits and hits[0] < cutoff:
            hits.pop(0)
        if len(hits) >= _RL_MAX:
            raise HTTPException(status_code=429, detail="Rate limit exceeded")
        hits.append(now)


def _gate(authorization):
    """Auth + rate-limit in one call. Returns the client key."""
    key = _auth(authorization)
    _rate_limit(key)
    return key


# ── Upstream helpers ─────────────────────────────────────────────────
def _gemini_generate(prompt, model, max_output_tokens=None, temperature=0.1,
                     fallbacks=None):
    """Call Gemini generateContent, trying `model` then any fallbacks.
    Mirrors the client's 404-skip / 503-retry behaviour. Returns text or ''."""
    if not GEMINI_KEY:
        raise HTTPException(status_code=500, detail="Server missing SYNC_GEMINI_KEY")
    gen_cfg = {"temperature": temperature}
    if max_output_tokens:
        gen_cfg["maxOutputTokens"] = max_output_tokens
    payload = {"contents": [{"parts": [{"text": prompt}]}], "generationConfig": gen_cfg}

    models = [model] + list(fallbacks or [])
    seen, ordered = set(), []
    for m in models:
        if m and m not in seen:
            seen.add(m)
            ordered.append(m)

    last_err = "no models tried"
    for m in ordered:
        url = f"{GLAPI}/v1beta/models/{m}:generateContent?key={GEMINI_KEY}"
        for attempt in range(1, 4):
            try:
                r = requests.post(url, json=payload, timeout=180)
            except requests.RequestException as e:
                last_err = f"{m}: {e}"
                break
            if r.status_code == 404:
                last_err = f"{m}: 404 model not found"
                break  # try next model
            if r.status_code == 503:
                last_err = f"{m}: 503 overloaded"
                if attempt < 3:
                    time.sleep(attempt * 5)
                    continue
                break
            if r.status_code != 200:
                last_err = f"{m}: HTTP {r.status_code} {r.text[:160]}"
                break
            try:
                data = r.json()
                return data["candidates"][0]["content"]["parts"][0]["text"].strip()
            except (KeyError, IndexError, ValueError):
                last_err = f"{m}: unparseable response"
                break
    print(f"[gemini] giving up: {last_err}")
    return ""


def _openai_chat(prompt, model):
    if not OPENAI_KEY:
        raise HTTPException(status_code=500, detail="Server missing SYNC_OPENAI_KEY")
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.1,
        "response_format": {"type": "json_object"},
    }
    r = requests.post(
        "https://api.openai.com/v1/chat/completions",
        headers={"Authorization": f"Bearer {OPENAI_KEY}"},
        json=payload, timeout=180,
    )
    if r.status_code != 200:
        print(f"[openai] HTTP {r.status_code}: {r.text[:160]}")
        return ""
    try:
        return r.json()["choices"][0]["message"]["content"].strip()
    except (KeyError, IndexError, ValueError):
        return ""


def _anthropic_chat(prompt, model):
    if not ANTHROPIC_KEY:
        raise HTTPException(status_code=500, detail="Server missing SYNC_ANTHROPIC_KEY")
    payload = {
        "model": model,
        "max_tokens": 8192,
        "temperature": 0.1,
        "messages": [{"role": "user", "content": prompt}],
    }
    r = requests.post(
        "https://api.anthropic.com/v1/messages",
        headers={"x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01"},
        json=payload, timeout=180,
    )
    if r.status_code != 200:
        print(f"[anthropic] HTTP {r.status_code}: {r.text[:160]}")
        return ""
    try:
        blocks = r.json().get("content", [])
        return "".join(b.get("text", "") for b in blocks
                       if b.get("type") == "text").strip()
    except ValueError:
        return ""


_AUDIO_MIME = {
    ".wav": "audio/wav", ".mp3": "audio/mpeg", ".m4a": "audio/mp4",
    ".flac": "audio/flac", ".ogg": "audio/ogg", ".aac": "audio/aac",
    ".aiff": "audio/aiff", ".aif": "audio/aiff",
}


def _audio_mime(filename):
    ext = os.path.splitext(filename or "")[1].lower()
    return _AUDIO_MIME.get(ext, "audio/wav")


# ── Routes ───────────────────────────────────────────────────────────
@app.get("/health")
def health():
    return {
        "ok": True,
        "auth_required": bool(_client_tokens()),
        "rate_limit_per_min": _RL_MAX,
        "providers": {
            "elevenlabs": bool(ELEVENLABS_KEY),
            "gemini": bool(GEMINI_KEY),
            "openai": bool(OPENAI_KEY),
            "anthropic": bool(ANTHROPIC_KEY),
        },
    }


@app.post("/v1/elevenlabs/stt")
async def elevenlabs_stt(file: UploadFile = File(...),
                         language_code: str = Form(default=""),
                         authorization: str = Header(default=None)):
    _gate(authorization)
    if not ELEVENLABS_KEY:
        raise HTTPException(status_code=500, detail="Server missing SYNC_ELEVENLABS_KEY")
    audio = await file.read()
    form = {
        "model_id": "scribe_v2",
        "tag_audio_events": "false",
        "timestamps_granularity": "word",
    }
    if language_code:
        form["language_code"] = language_code
    files = {"file": (file.filename or "audio.wav", audio,
                      file.content_type or "audio/wav")}
    r = requests.post(
        "https://api.elevenlabs.io/v1/speech-to-text",
        headers={"xi-api-key": ELEVENLABS_KEY},
        data=form, files=files, timeout=120,
    )
    if r.status_code != 200:
        raise HTTPException(status_code=r.status_code,
                            detail=f"ElevenLabs: {r.text[:200]}")
    return r.json()


@app.post("/v1/gemini/stt")
async def gemini_stt(file: UploadFile = File(...),
                     language: str = Form(default=""),
                     authorization: str = Header(default=None)):
    _gate(authorization)
    if not GEMINI_KEY:
        raise HTTPException(status_code=500, detail="Server missing SYNC_GEMINI_KEY")
    audio = await file.read()
    prompt = (
        f"Transcribe this audio in its original language ({language or 'auto'}). "
        f"Return ONLY the transcript text — no timestamps, no commentary, "
        f"no quotation marks."
    )
    payload = {
        "contents": [{"parts": [
            {"text": prompt},
            {"inline_data": {
                "mime_type": _audio_mime(file.filename),
                "data": base64.b64encode(audio).decode("ascii"),
            }},
        ]}],
        "generationConfig": {"temperature": 0.0},
    }
    url = f"{GLAPI}/v1beta/models/{GEMINI_AUDIO_MODEL}:generateContent?key={GEMINI_KEY}"
    r = requests.post(url, json=payload, timeout=180)
    if r.status_code != 200:
        raise HTTPException(status_code=r.status_code,
                            detail=f"Gemini STT: {r.text[:200]}")
    try:
        text = r.json()["candidates"][0]["content"]["parts"][0]["text"].strip()
    except (KeyError, IndexError, ValueError):
        text = ""
    return {"text": text}


@app.post("/v1/translate")
async def translate(req: Request, authorization: str = Header(default=None)):
    _gate(authorization)
    body = await req.json()
    text = (body.get("text") or "").strip()
    if not text:
        return {"text": ""}
    source_lang = body.get("source_lang") or ""
    model = body.get("model") or "gemini-3-flash-preview"
    prompt = (
        f"Translate the following {source_lang} text to English. "
        f"Return ONLY the English translation, nothing else.\n\n{text}"
    )
    out = _gemini_generate(prompt, model, max_output_tokens=256, temperature=0.1,
                           fallbacks=["gemini-2.0-flash", "gemini-2.0-flash-lite"])
    return {"text": out}


@app.post("/v1/match")
async def match(req: Request, authorization: str = Header(default=None)):
    _gate(authorization)
    body = await req.json()
    provider = (body.get("provider") or "gemini").lower()
    prompt = body.get("prompt") or ""
    model = body.get("model")
    if not prompt:
        return {"text": ""}
    if provider == "openai":
        text = _openai_chat(prompt, model or OPENAI_MODEL)
    elif provider == "anthropic":
        text = _anthropic_chat(prompt, model or ANTHROPIC_MODEL)
    else:
        text = _gemini_generate(prompt, model or GEMINI_MATCHER_MODEL,
                                fallbacks=["gemini-2.5-pro", "gemini-2.5-flash"])
    return {"text": text}
