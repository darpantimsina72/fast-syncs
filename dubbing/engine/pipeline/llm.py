"""
LLM provider layer (Vertex AI / Gemini API / OpenAI-compatible), prompt
loading, the 3-step translation chain, translation-memory hooks, Step-4
emotion enrichment and EN<->target subtitle mapping.

Extracted from Translation_and_Syncing_App.py (bulk app, v1.8.0):
    lines 76-81     google-genai optional import guard
    lines 2012-2530 "LLM provider layer" + translation chain + review
                    pairing + TM helpers + emotion + mapping

Adaptations (everything else is verbatim):
  * Settings live in this repo's config/llm_settings.json (SAME schema as
    the bulk app's llm_settings.json). The provider field additionally
    accepts the short aliases "vertex" | "gemini" | "openai" written by
    the REAPER panel's Settings section.
  * A blank "vertex_json" now resolves to config/vertex_key.json.
  * Prompts load from this repo's prompts/ directory; the app's legacy
    top-level <stage>.txt fallback is dropped.
  * translation_memory is this package's tm module (pipeline/tm.py); the
    optional-module guard pattern is kept verbatim.
  * _validate_llm_config() raises an actionable error when
    config/llm_settings.json itself is missing (contract v0.3).
  * New helper _active_provider_and_model() supports the engine's
    --test-llm manifest.
"""

import json
import os
import re
import urllib.error
import urllib.request
from typing import Dict, List, Optional, Set, Tuple

from .config import (CONFIG_DIR, GEMINI_DEFAULT_MODEL, LLM_DEFAULT_BASE_URL,
                     LLM_PROVIDER_GEMINI, LLM_PROVIDER_OPENAI,
                     LLM_PROVIDER_SERVER, LLM_PROVIDER_VERTEX,
                     LLM_PROVIDERS, LLM_SETTINGS_FILE,
                     PROMPTS_DIR, STEP4_EMOTION_ENABLED, TTS_DEFAULT_LANGUAGE,
                     TTS_LANGUAGES)

try:
    from google import genai
    from google.genai import types as genai_types
    GENAI_AVAILABLE = True
except ImportError:
    GENAI_AVAILABLE = False

# Translation memory — proofed-translation feedback loop (optional module;
# the pipeline must keep working if tm.py cannot load, e.g. sqlite issues).
try:
    from . import tm as translation_memory
except Exception:
    translation_memory = None


_LLM_SETTINGS_DEFAULTS: Dict[str, str] = {
    "provider":        LLM_PROVIDER_VERTEX,
    "vertex_json":     "",                    # blank → config/vertex_key.json
    "gemini_api_key":  "",
    "openai_base_url": LLM_DEFAULT_BASE_URL,
    "openai_api_key":  "",
    "openai_model":    "",
    "gemini_model":    GEMINI_DEFAULT_MODEL,     # model for vertex + gemini-key providers
    "prompt_caching":  "1",
    "http_user_agent": "",                    # blank → _DEFAULT_HTTP_USER_AGENT
    # Auto-Sync-only server/proxy credentials. The engine never calls them; they
    # live in this file because the panel's Settings tab is the single place any
    # credential is entered, and listing them here keeps them round-tripping.
    "server_url":      "",
    "server_token":    "",
}
_LLM_SETTINGS: Dict[str, str] = dict(_LLM_SETTINGS_DEFAULTS)

# Short provider names (as written by the REAPER panel's provider combo)
# mapped onto the app's full display-string constants.
_PROVIDER_ALIASES: Dict[str, str] = {
    "vertex": LLM_PROVIDER_VERTEX,
    "gemini": LLM_PROVIDER_GEMINI,
    "openai": LLM_PROVIDER_OPENAI,
    "server": LLM_PROVIDER_SERVER,
    # The Auto Sync tab's own vocabulary for the same two modes.
    "studio":  LLM_PROVIDER_GEMINI,
    "gateway": LLM_PROVIDER_OPENAI,
}

# Raised (as ValueError) for the Auto-Sync-only server mode: dubbing has no
# server path, and silently using whichever direct key happens to be filled in
# would be worse than saying so.
_SERVER_MODE_ERROR = (
    "Server proxy mode is Auto-Sync-only — the dubbing engine calls the LLM "
    "directly and has no server path. In the panel's Settings tab pick Vertex, "
    "a Gemini API key, or an OpenAI-compatible gateway for dubbing; Auto Sync "
    "keeps using the server.")


def _load_llm_settings() -> None:
    """Load config/llm_settings.json (if present) over the defaults."""
    global _LLM_SETTINGS
    _LLM_SETTINGS = dict(_LLM_SETTINGS_DEFAULTS)
    try:
        with open(LLM_SETTINGS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            for k in _LLM_SETTINGS_DEFAULTS:
                if k not in data:
                    continue
                v = data[k]
                # A hand-edited file can carry 1 where "1" belongs. Coerce the
                # scalars and SAY SO for anything else: silently falling back to
                # the default here is how a configured key turns into a 401 with
                # no explanation ("openai_api_key": null).
                if isinstance(v, str):
                    _LLM_SETTINGS[k] = v
                elif isinstance(v, bool):
                    _LLM_SETTINGS[k] = "1" if v else "0"
                elif isinstance(v, (int, float)):
                    _LLM_SETTINGS[k] = str(v)
                else:
                    print(f"[LLM] {LLM_SETTINGS_FILE}: {k!r} is "
                          f"{'null' if v is None else type(v).__name__}, not a "
                          "string — treating it as not set.")
        alias = _LLM_SETTINGS["provider"].strip().lower()
        if alias in _PROVIDER_ALIASES:
            _LLM_SETTINGS["provider"] = _PROVIDER_ALIASES[alias]
        # Keep LLM_PROVIDER_SERVER as-is even though it is not a dub-capable
        # provider: _validate_llm_config() turns it into an actionable error.
        if _LLM_SETTINGS["provider"] not in LLM_PROVIDERS \
           and _LLM_SETTINGS["provider"] != LLM_PROVIDER_SERVER:
            _LLM_SETTINGS["provider"] = LLM_PROVIDER_VERTEX
    except FileNotFoundError:
        pass
    except Exception as e:
        print(f"[LLM] Could not read {LLM_SETTINGS_FILE}: {e} — using defaults.")


def _save_llm_settings() -> None:
    os.makedirs(os.path.dirname(LLM_SETTINGS_FILE), exist_ok=True)
    with open(LLM_SETTINGS_FILE, "w", encoding="utf-8") as f:
        json.dump(_LLM_SETTINGS, f, indent=2)


def _get_llm_settings() -> Dict[str, str]:
    return _LLM_SETTINGS


def _llm_provider_label() -> str:
    """Short human-readable description of the active provider.

    The engine's startup banner prints this, so it names the provider that will
    ACTUALLY be called and whether its credential is present. A log line that
    said "gemini-2.5-pro" while the run was really going to a keyless gateway is
    why this is in the banner at all.
    """
    s = _get_llm_settings()
    p = s.get("provider", LLM_PROVIDER_VERTEX)
    if p == LLM_PROVIDER_OPENAI:
        model = s.get("openai_model") or "(model not set)"
        key = "key set" if (s.get("openai_api_key") or "").strip() else "NO KEY"
        return (f"{model} via gateway "
                f"{s.get('openai_base_url') or '(base URL not set)'} [{key}]")
    gm = (s.get("gemini_model") or "").strip() or GEMINI_DEFAULT_MODEL
    if p == LLM_PROVIDER_GEMINI:
        key = "key set" if (s.get("gemini_api_key") or "").strip() else "NO KEY"
        return f"{gm} via {p} [{key}]"
    return f"{gm} via {p}"


def _active_provider_and_model() -> Tuple[str, str]:
    """(short provider name, active model id) for the --test-llm manifest."""
    s = _get_llm_settings()
    p = s.get("provider", LLM_PROVIDER_VERTEX)
    short = {LLM_PROVIDER_VERTEX: "vertex",
             LLM_PROVIDER_GEMINI: "gemini",
             LLM_PROVIDER_OPENAI: "openai",
             LLM_PROVIDER_SERVER: "server"}.get(p, p)
    if p == LLM_PROVIDER_OPENAI:
        return short, (s.get("openai_model") or "").strip() or "(model not set)"
    return short, (s.get("gemini_model") or "").strip() or GEMINI_DEFAULT_MODEL


def _get_vertex_context():
    key_file = (_get_llm_settings().get("vertex_json") or "").strip() \
               or os.path.join(CONFIG_DIR, "vertex_key.json")
    if not os.path.exists(key_file):
        raise FileNotFoundError(f"Vertex service-account JSON not found at {key_file}")
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = key_file
    with open(key_file, "r", encoding="utf-8") as f:
        key_data = json.load(f)
    project_id = key_data.get("project_id")
    if not project_id:
        raise ValueError(f"{os.path.basename(key_file)} is missing 'project_id'.")
    return project_id


def _make_genai_client():
    """google-genai Client for the Vertex or Gemini-API-key providers."""
    if not GENAI_AVAILABLE:
        raise ImportError("google-genai not installed. Run: pip install google-genai")
    s = _get_llm_settings()
    if s.get("provider") == LLM_PROVIDER_GEMINI:
        api_key = (s.get("gemini_api_key") or "").strip()
        if not api_key:
            raise ValueError("Gemini API key is empty — set it in "
                             "config/llm_settings.json (panel Settings).")
        return genai.Client(api_key=api_key)
    project_id = _get_vertex_context()
    return genai.Client(vertexai=True, project=project_id, location="us-central1")


# urllib's default agent ("Python-urllib/x.y") is on every bot blocklist, so
# Cloudflare-fronted gateways deny it with a 403 / "error code: 1010" before the
# request reaches the model. Override per install with "http_user_agent" in
# config/llm_settings.json, or the DUB_HTTP_USER_AGENT environment variable.
_DEFAULT_HTTP_USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                            "AppleWebKit/537.36 (KHTML, like Gecko) "
                            "Chrome/126.0.0.0 Safari/537.36")


def _http_user_agent() -> str:
    return ((_get_llm_settings().get("http_user_agent") or "").strip()
            or os.environ.get("DUB_HTTP_USER_AGENT", "").strip()
            or _DEFAULT_HTTP_USER_AGENT)


_BASE_URL_HINT = ("This setting is the API base URL — <host> or <host>/v1 — not "
                  "the browser address of the chat UI, and must not include "
                  "/chat/completions.")


def _openai_api_urls(base: str) -> List[str]:
    """Chat-completions URLs to try for an OpenAI-compatible base, best first.

    A base that already carries a path is treated as the API root, so only the
    endpoint is appended: that is the shape OpenAI (…/v1), OpenRouter (…/api/v1),
    Gemini's OpenAI-compat layer (…/v1beta/openai) and Open WebUI (…/api) all
    use. A bare host gets the versioned path. When the path carries no version
    segment it could also be a proxy mounted on a sub-path (…/llm serving
    /llm/v1/chat/completions), so that shape is kept as a fallback for the
    caller to retry on a 404.

    Rejects a base that already ends in the endpoint path — the suffix is
    appended here, so pasting the full endpoint would double it.
    """
    base = (base or "").strip().rstrip("/")
    if not base:
        raise ValueError("Base URL is empty — set it in config/llm_settings.json "
                         "(panel Settings).")
    if base.lower().endswith("/completions"):
        raise ValueError(f"Base URL must not include the endpoint path: {base} — "
                         + _BASE_URL_HINT)
    m = re.match(r"^(?:[A-Za-z][\w+.-]*://)?[^/]+(/.*)?$", base)
    path = (m.group(1) or "") if m else ""
    # LiteLLM and Open WebUI serve their admin console at /ui, so a base ending
    # there is the console's browser address pasted in place of the API root.
    # Left alone it becomes …/ui/v1/chat/completions, and LiteLLM answers 405
    # "Method Not Allowed" — a reply that says nothing about the real mistake.
    # Caught here so --test-llm and the pre-run check name it before any spend.
    if re.search(r"/ui$", path, re.IGNORECASE):
        raise ValueError(
            f"Base URL {base} is the gateway's admin console, not its API — "
            f"use {base[:-len('/ui')].rstrip('/')}/v1 instead. " + _BASE_URL_HINT)
    if not path:
        return [base + "/v1/chat/completions"]
    urls = [base + "/chat/completions"]
    if not re.search(r"/v\d", path):
        urls.append(base + "/v1/chat/completions")
    return urls


def _openai_api_url(base: str) -> str:
    """The preferred chat-completions URL for an OpenAI-compatible base."""
    return _openai_api_urls(base)[0]


# A gateway on this machine or the LAN (Ollama, LM Studio, vLLM, a local
# LiteLLM) legitimately serves with no key at all; a gateway out on the
# internet never does. Only the local shapes may leave "openai_api_key" blank.
_LOCAL_HOST_RE = re.compile(
    r"(?:localhost"
    r"|127(?:\.\d{1,3}){3}"
    r"|0\.0\.0\.0"
    r"|\[?::1\]?"
    r"|10(?:\.\d{1,3}){3}"
    r"|192\.168(?:\.\d{1,3}){2}"
    r"|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}"
    r"|[^.]+\.local)$", re.IGNORECASE)


def _openai_host(base: str) -> str:
    """Bare host of an OpenAI-compatible base URL — no scheme, port or path."""
    h = re.sub(r"^[A-Za-z][\w+.-]*://", "", (base or "").strip())
    h = h.split("/", 1)[0].split("@")[-1]
    if h.startswith("["):                       # bracketed IPv6 literal
        return h.split("]", 1)[0] + "]"
    return h.rsplit(":", 1)[0] if h.count(":") == 1 else h


def _gateway_needs_key(base: str) -> bool:
    """True when this base URL is remote, so a blank API key cannot work."""
    return not _LOCAL_HOST_RE.match(_openai_host(base))


def _openai_chat(prompt: str, model: str, timeout: float = 900.0) -> str:
    """Single-turn /v1/chat/completions call against the configured base URL."""
    s = _get_llm_settings()
    urls = _openai_api_urls(s.get("openai_base_url") or "")
    model = (model or "").strip()
    if not model:
        raise ValueError("Model name is empty — set it in config/llm_settings.json "
                         "(panel Settings).")
    headers = {"Content-Type": "application/json",
               "User-Agent": _http_user_agent()}
    api_key = (s.get("openai_api_key") or "").strip()
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    payload = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
    }).encode("utf-8")
    raw = final_url = sent_url = None
    for i, url in enumerate(urls):
        req = urllib.request.Request(url, data=payload, headers=headers,
                                     method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw       = resp.read().decode("utf-8", "replace")
                final_url = resp.geturl()
            sent_url = url
            break
        except urllib.error.HTTPError as e:
            body = ""
            try:
                body = e.read().decode("utf-8", "replace")[:400]
            except Exception:
                pass
            # A base URL with a path is usually the API root, but it can also be
            # a proxy mounted on a sub-path. Retry the versioned shape once when
            # the endpoint simply isn't there.
            if e.code in (404, 405) and i + 1 < len(urls):
                continue
            if e.code == 403 and "1010" in body:
                raise RuntimeError(
                    f'LLM endpoint {url} returned HTTP 403 with Cloudflare "error '
                    'code: 1010" — the gateway is refusing this client\'s '
                    "user-agent. The API key and model are not the problem. Set "
                    '"http_user_agent" in config/llm_settings.json to override '
                    "the agent string.") from e
            # No key configured → no Authorization header was sent, so the
            # gateway is rejecting an anonymous request. Its own wording for
            # that ("No api key passed in.") reads like the key is wrong, which
            # sends people re-pasting a key that was never stored.
            if e.code in (401, 403) and not api_key:
                raise RuntimeError(
                    f"LLM endpoint {url} returned HTTP {e.code} and this request "
                    "carried NO API key: \"openai_api_key\" is empty in "
                    "config/llm_settings.json. Enter the gateway key in the "
                    "panel's Settings tab — the base URL and model are not the "
                    f"problem. Gateway said: {body}") from e
            raise RuntimeError(f"LLM endpoint {url} returned HTTP {e.code}: "
                               f"{body}") from e
        except urllib.error.URLError as e:
            raise RuntimeError(f"Cannot reach LLM endpoint {url}: {e.reason}") from e
    url = sent_url or urls[-1]
    try:
        data = json.loads(raw)
    except ValueError:
        # A web-UI base URL (…/ui) redirects a POST to the login page, so the
        # body is HTML instead of JSON. Say that, rather than a parse error.
        if raw.lstrip()[:1] == "<":
            raise ValueError(f"{url} returned an HTML page, not JSON (request "
                             f"ended at {final_url}) — the base URL looks like a "
                             f"web-UI path. {_BASE_URL_HINT}") from None
        raise ValueError(f"Unexpected response from {url}: {raw[:400]}") from None
    try:
        return data["choices"][0]["message"]["content"] or ""
    except (KeyError, IndexError, TypeError):
        raise ValueError(f"Unexpected response from {url}: {str(data)[:400]}")


# Prompt-cache registry: (model, sha1-of-prefix) → Gemini cache name.
# None marks a prefix as uncacheable (too small / API rejected) so we stop
# retrying. Caches live server-side with a 1-hour TTL and are recreated
# transparently when they expire.
_GENAI_CACHE_REGISTRY: Dict[Tuple[str, str], Optional[str]] = {}


def _genai_cached_generate(client, model: str, static_prefix: Optional[str],
                           dynamic: str, use_cache: bool) -> str:
    """generate_content with explicit Gemini prompt caching for the static
    prompt prefix. Any cache failure falls back to a plain inline call."""
    inline = (static_prefix or "") + dynamic
    if not (use_cache and static_prefix):
        return client.models.generate_content(model=model, contents=inline).text

    import hashlib
    key = (model, hashlib.sha1(static_prefix.encode("utf-8")).hexdigest())
    cache_name = _GENAI_CACHE_REGISTRY.get(key, "")
    if cache_name is None:                       # known-uncacheable prefix
        return client.models.generate_content(model=model, contents=inline).text
    if not cache_name:
        try:
            cache = client.caches.create(
                model=model,
                config=genai_types.CreateCachedContentConfig(
                    contents=[static_prefix], ttl="3600s"))
            cache_name = cache.name
            _GENAI_CACHE_REGISTRY[key] = cache_name
        except Exception:
            # Prefix below the model's cache minimum, or API doesn't support
            # caching — remember that and never retry for this prefix.
            _GENAI_CACHE_REGISTRY[key] = None
            return client.models.generate_content(model=model, contents=inline).text
    try:
        return client.models.generate_content(
            model=model, contents=dynamic,
            config=genai_types.GenerateContentConfig(cached_content=cache_name)
        ).text
    except Exception:
        # Cache likely expired — forget it so the next call recreates it.
        _GENAI_CACHE_REGISTRY.pop(key, None)
        return client.models.generate_content(model=model, contents=inline).text


def _llm_generate(prompt: str, model: str = GEMINI_DEFAULT_MODEL,
                  static_prefix: Optional[str] = None) -> str:
    """Provider-agnostic text generation. All pipeline LLM calls go through here.

    *static_prefix* is the reusable part (the per-language prompt file); *prompt*
    is the per-request part. Splitting them enables prompt caching: explicit
    Gemini context caching on the Vertex / Gemini-key providers, and implicit
    (automatic server-side) prefix caching on OpenAI-compatible endpoints —
    which also relies on the static prefix coming first in the request."""
    s = _get_llm_settings()
    if s.get("provider") == LLM_PROVIDER_SERVER:
        raise ValueError(_SERVER_MODE_ERROR)
    if s.get("provider") == LLM_PROVIDER_OPENAI:
        return _openai_chat((static_prefix or "") + prompt,
                            (s.get("openai_model") or "").strip() or model)
    # Vertex / Gemini-key providers: the configured gemini_model overrides the
    # caller's default so the panel's Model field controls these providers too.
    gm = (s.get("gemini_model") or "").strip() or model
    client = _make_genai_client()
    use_cache = s.get("prompt_caching", "1") == "1"
    return _genai_cached_generate(client, gm, static_prefix, prompt, use_cache)


def _validate_llm_config() -> None:
    """Raise with a user-readable message if the active provider is unusable."""
    if not os.path.exists(LLM_SETTINGS_FILE):
        raise FileNotFoundError(
            f"LLM settings file not found: {LLM_SETTINGS_FILE} — "
            "run setup_mac.command or open the REAPER panel's Settings "
            "section to configure the LLM provider.")
    s = _get_llm_settings()
    p = s.get("provider", LLM_PROVIDER_VERTEX)
    if p == LLM_PROVIDER_SERVER:
        raise ValueError(_SERVER_MODE_ERROR)
    if p == LLM_PROVIDER_OPENAI:
        if not (s.get("openai_base_url") or "").strip():
            raise ValueError("OpenAI-compatible base URL is empty — configure "
                             "it in config/llm_settings.json (panel Settings).")
        _openai_api_urls(s["openai_base_url"])    # rejects a pasted endpoint path
        if not (s.get("openai_model") or "").strip():
            raise ValueError("Model name is empty — configure it in "
                             "config/llm_settings.json (panel Settings).")
        # A blank key means the request goes out with no Authorization header at
        # all and the gateway answers 401 ("No api key passed in."). Catch it
        # HERE: the dub run's first LLM call is at S2a, after the paid Scribe
        # transcription, so a key checked late costs money to discover.
        if not (s.get("openai_api_key") or "").strip() \
           and _gateway_needs_key(s["openai_base_url"]):
            raise ValueError(
                f"Gateway API key is empty for {_openai_host(s['openai_base_url'])} "
                "— enter it in the panel's Settings tab (Provider: "
                "OpenAI-compatible → API key). Only a gateway on this machine or "
                "the LAN may be left blank.")
        return
    if not GENAI_AVAILABLE:
        raise ImportError("google-genai not installed. Run: pip install google-genai")
    if p == LLM_PROVIDER_GEMINI:
        if not (s.get("gemini_api_key") or "").strip():
            raise ValueError("Gemini API key is empty — configure it in "
                             "config/llm_settings.json (panel Settings).")
        return
    _get_vertex_context()


_load_llm_settings()


def _load_lang_prompt(stage: str, language: str) -> str:
    """
    Load a per-language prompt file from this repo's prompts/ directory.

    Layout:
        prompts/Step1_Translation_Prompt_<Language>.txt
        prompts/Step2_Review_Prompt_<Language>.txt
        prompts/Step3_Punctuation_Prompt_<Language>.txt
        prompts/Step4_Emotion_Prompt_<Language>.txt
        prompts/SyncingPrompt_<Language>.txt
    """
    fname = f"{stage}_{language}.txt"
    p = os.path.join(PROMPTS_DIR, fname)
    if not os.path.exists(p):
        raise FileNotFoundError(
            f"Prompt file not found: prompts/{fname}\n"
            f"Create it (adapt from prompts/{stage}_Bengali.txt) so the "
            f"pipeline can target {language}.")
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def _run_gemini_pipeline(formatted_srt: str, model: str = GEMINI_DEFAULT_MODEL,
                         language: str = TTS_DEFAULT_LANGUAGE,
                         steps: int = 3, tm_glossary: str = ""):
    """Runs translation (→ review → punctuation) on the configured LLM provider.

    *steps* selects the prompt chain depth:
        1 — translation only (Step1 prompt)
        2 — translation + review (Step1, Step2)
        3 — translation + review + punctuation (Step1, Step2, Step3)
    Skipped steps pass the previous step's text through unchanged.

    Prompt files are sent as the static prefix of each request so they get
    prompt-cached across audios (see _llm_generate).
    *tm_glossary* (optional) is a translation-memory block of previously
    approved translations, appended to the Step-1 dynamic input so proofed
    phrasing is reused for consistency.
    Returns (translation, review, punctuation, tr_input, rev_input, punc_input)."""
    steps = max(1, min(3, int(steps or 3)))

    p1 = _load_lang_prompt("Step1_Translation_Prompt", language)
    tr_dyn     = f"\n\n=== Formatted SRT Content ===\n{formatted_srt}"
    if tm_glossary:
        tr_dyn += tm_glossary
    tr_input   = p1 + tr_dyn
    tr_result  = _llm_generate(tr_dyn, model, static_prefix=p1)

    rev_result, rev_input = tr_result, ""
    if steps >= 2:
        p2 = _load_lang_prompt("Step2_Review_Prompt", language)
        rev_dyn    = (f"\n\nEnglish text\n{formatted_srt}\n\n"
                      f"{language} Script for Tuning\n{tr_result}")
        rev_input  = p2 + rev_dyn
        rev_result = _llm_generate(rev_dyn, model, static_prefix=p2)

    punc_result, punc_input = rev_result, ""
    if steps >= 3:
        p3 = _load_lang_prompt("Step3_Punctuation_Prompt", language)
        punc_dyn    = f"\n\n{rev_result}"
        punc_input  = p3 + punc_dyn
        punc_result = _llm_generate(punc_dyn, model, static_prefix=p3)

    return tr_result, rev_result, punc_result, tr_input, rev_input, punc_input


def _strip_code_fence(text: str) -> str:
    """Strip ```lang ... ``` fences Gemini sometimes wraps its output in."""
    if not text:
        return text
    m = re.match(r"^\s*```[a-zA-Z0-9_-]*\s*\n(.*?)\n```\s*$", text, re.DOTALL)
    return m.group(1) if m else text


def _extract_srt_entries(srt_text: str) -> List[Tuple[float, float, str]]:
    """Return (start_sec, end_sec, text) for every SRT block, in order."""
    if not srt_text:
        return []
    pattern = re.compile(
        r'\d+\n(\d{2}:\d{2}:\d{2},\d{3}) --> (\d{2}:\d{2}:\d{2},\d{3})\n([\s\S]*?)(?=\n\n|\n$|$)',
        re.MULTILINE)

    def _to_sec(ts):
        h, m, s_ms = ts.split(':')
        s, ms = s_ms.split(',')
        return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000

    return [(_to_sec(m.group(1)), _to_sec(m.group(2)),
             m.group(3).replace('\n', ' ').strip())
            for m in pattern.finditer(srt_text)]


def _split_translation_paragraphs(text: str) -> List[str]:
    """Split a dubbing script into its blank-line-separated paragraphs.

    The translation prompts make the LLM emit roughly one paragraph per
    English subtitle segment, so these rows pair up with the English SRT
    entries in the review flow."""
    text = _strip_code_fence(text or "").strip()
    return [p.strip() for p in re.split(r'\n\s*\n', text) if p.strip()]


def _pair_review_rows(en_entries: List[Tuple[float, float, str]],
                      tr_paragraphs: List[str]
                      ) -> List[Tuple[str, str, Optional[float], Optional[float]]]:
    """Pair English SRT segments with translation paragraphs for review.

    Counts rarely match 1:1 — the punctuation pass merges several spoken
    pulses into one continuous paragraph — so when there are more English
    segments than paragraphs, consecutive segments are grouped onto each
    paragraph proportionally by character share. Returns ordered
    (english_text, translation_text, start_sec, end_sec) rows; the times
    span the grouped English segments (None when a row has no English)."""
    en = [(s0, s1, t.strip()) for (s0, s1, t) in en_entries if t and t.strip()]
    tr = [p.strip() for p in tr_paragraphs if p and p.strip()]
    if not tr:
        return [(t, "", s0, s1) for (s0, s1, t) in en]
    if not en:
        return [("", p, None, None) for p in tr]
    if len(en) <= len(tr):
        return [(en[i][2], p, en[i][0], en[i][1]) if i < len(en)
                else ("", p, None, None)
                for i, p in enumerate(tr)]

    tr_total = float(sum(len(p) for p in tr)) or 1.0
    en_total = float(sum(len(t) for (_, _, t) in en)) or 1.0
    prefix = [0.0]                            # prefix[j] = chars in en[:j]
    for (_, _, t) in en:
        prefix.append(prefix[-1] + len(t))

    rows, i, acc = [], 0, 0.0
    for k, p in enumerate(tr):
        if k == len(tr) - 1:
            j = len(en)                       # last paragraph takes the rest
        else:
            acc += len(p)
            target = acc / tr_total * en_total
            # ≥1 segment per row, and leave ≥1 for every remaining paragraph
            j_min = i + 1
            j_max = len(en) - (len(tr) - 1 - k)
            j = j_min
            while j < j_max and prefix[j] < target:
                j += 1
            # step back if the previous boundary is closer to the target
            if j > j_min and (prefix[j] - target) > (target - prefix[j - 1]):
                j -= 1
        rows.append((" ".join(t for (_, _, t) in en[i:j]), p,
                     en[i][0], en[j - 1][1]))
        i = j
    return rows


# ─────────────────────────────────────────────────────────────────────────────
#  Translation memory (feedback loop) helpers
#
#  Capture: when a reviewed script is confirmed for dubbing it is
#  human-proofed — store it (full + row pairs).
#  Reuse: before calling the LLM, an exact English match returns the proofed
#  script for zero tokens; partial matches are injected into the translation
#  prompt as approved reference translations.
#  All helpers are no-ops when the tm module is unavailable, and they
#  never raise into the pipeline.
# ─────────────────────────────────────────────────────────────────────────────

def _tm_lang(language: str) -> str:
    """Normalized language key used across store/lookup."""
    return (language or "").strip().lower()


def _tm_source_text(en_entries: List[Tuple[float, float, str]]) -> str:
    """Timing-independent English key: the segment texts joined in order.
    (Hashing the formatted SRT would bake in timings/syllable metrics that
    drift between transcription runs of the same audio.)"""
    return " ".join(t.strip() for (_s0, _s1, t) in en_entries if t and t.strip())


def _tm_lookup_full(language: str, en_entries) -> Optional[str]:
    """Proofed full script for this exact English content, or None."""
    if translation_memory is None:
        return None
    src = _tm_source_text(en_entries)
    if not src:
        return None
    try:
        return translation_memory.lookup_full(_tm_lang(language), src)
    except Exception:
        return None


def _tm_glossary_block(language: str, en_entries, cap: int = 40) -> str:
    """Prompt block of previously approved translations found in this source.
    Empty string when there are none (or memory is unavailable)."""
    if translation_memory is None:
        return ""
    src = _tm_source_text(en_entries)
    if not src:
        return ""
    try:
        pairs = translation_memory.lookup_pairs_in_source(
            _tm_lang(language), src, cap=cap)
    except Exception:
        return ""
    if not pairs:
        return ""
    lines = [f"English: {en}\n{language}: {tr}" for en, tr in pairs]
    return ("\n\n=== Previously approved translations "
            "(reuse these verbatim wherever the same English appears) ===\n"
            + "\n\n".join(lines))


def _tm_capture(language: str, en_entries, proofed_text: str,
                source: str = "") -> int:
    """Store a human-reviewed script: full doc + review-row pairs.
    Returns the number of pairs stored (0 when memory is unavailable)."""
    if translation_memory is None:
        return 0
    src = _tm_source_text(en_entries)
    proofed_text = (proofed_text or "").strip()
    if not proofed_text:
        return 0
    lang = _tm_lang(language)
    try:
        if src:
            translation_memory.store_full(lang, src, proofed_text, source)
        rows = _pair_review_rows(
            en_entries, _split_translation_paragraphs(proofed_text))
        pairs = [(en, tr) for (en, tr, _s0, _s1) in rows if en and tr]
        return translation_memory.store_pairs(lang, pairs, source) or 0
    except Exception:
        return 0


def _run_emotion_enrichment(text: str,
                            language: str = TTS_DEFAULT_LANGUAGE,
                            model: str = GEMINI_DEFAULT_MODEL,
                            status_cb=None) -> str:
    """
    Step4: inject ElevenLabs v3 emotion / accent tags into a punctuated script.

    Runs a Gemini pass with prompts/Step4_Emotion_Prompt_<Language>.txt to
    prepend a `[<language> accent]` tag and sprinkle calm/contemplative/slow/
    pause tags through the script in a Sadhguru-style cadence. Words and
    punctuation of the input are preserved verbatim — only tags are added.

    Best-effort: on ANY failure (missing prompt, network, Gemini error) the
    original text is returned so the TTS step is never blocked.
    """
    if not STEP4_EMOTION_ENABLED or not text or not text.strip():
        return text
    try:
        if status_cb:
            status_cb(f"Step4: Emotion enrichment ({language})…")
        prompt = _load_lang_prompt("Step4_Emotion_Prompt", language)
        enriched = _llm_generate(f"\n\n{text}", model, static_prefix=prompt) or ""
        enriched = _strip_code_fence(enriched).strip()
        if not enriched:
            if status_cb:
                status_cb("Step4: Emotion enrichment returned empty — using original text.")
            return text
        if status_cb:
            status_cb("Step4: Emotion enrichment ✓")
        return enriched
    except Exception as e:
        if status_cb:
            status_cb(f"Step4: Emotion enrichment skipped ({e}). Using original text.")
        return text


def _read_syncing_prompt(language: str = TTS_DEFAULT_LANGUAGE) -> str:
    return _load_lang_prompt("SyncingPrompt", language)


def _call_gemini_mapping(en_srt: str, te_srt: str, script_text: str,
                         model: str = GEMINI_DEFAULT_MODEL,
                         language: str = TTS_DEFAULT_LANGUAGE) -> str:
    """Calls Gemini to map English and target-language SRTs. Returns detailed
    mapping text tagged with the language's 2-letter code (HI, BN, TA, …)."""
    base_prompt = _read_syncing_prompt(language)
    dynamic = (
        f"\n\n=== English SRT Content ===\n{en_srt}\n\n"
        f"=== {language} SRT Content ===\n{te_srt}\n\n"
        f"=== Video Script ===\n{script_text}"
    )
    raw = _llm_generate(dynamic, model, static_prefix=base_prompt)

    json_match = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", raw, re.DOTALL)
    if json_match:
        json_str = json_match.group(1)
    else:
        json_match = re.search(r"\{.*\}", raw, re.DOTALL)
        if not json_match:
            raise ValueError("No JSON found in Gemini mapping response.")
        json_str = json_match.group(0)

    data     = json.loads(json_str)
    detailed = data.get("detailed", [])
    tag      = TTS_LANGUAGES.get(language, {}).get("tag", "BN")
    lang_key = language.lower()
    lines    = ["=== DETAILED SUBTITLE MAPPING ===", ""]
    for i, m in enumerate(detailed, 1):
        en_s = ", ".join(str(x) for x in m.get("english", []))
        # Prefer the language-specific key, falling back to legacy
        # "bengali" / "telugu" keys for older prompts.
        tgt_list = (m.get(lang_key) or m.get("bengali")
                    or m.get("telugu") or m.get("translation") or [])
        tgt_s = ", ".join(str(x) for x in tgt_list)
        lines.append(f"[{i}] EN [{en_s}] -> {tag} [{tgt_s}]")
    return "\n".join(lines)
