"""
Lekhak "Other" desk as the dubbing engine's translation provider (v0.15.5).

WHY THIS EXISTS
---------------
Step 1 of the translation chain (the per-language Step1_Translation_Prompt)
produces a dubbing script directly from the timed English analysis format.
Lekhak — the self-hosted literary-translation workspace — produces a better
*translation* for the languages it has been taught, because every call carries

  * that language desk's own sentence memory (written when a human presses
    Keep),
  * worked examples from published books,
  * a learned style profile built from the pastes humans corrected.

None of that is timing-aware, and it must not be: Lekhak deliberately strips
subtitle timings and rejoins cues into flowing paragraphs. So this module takes
ONLY the translation from Lekhak. Everything that makes a translation dubbable —
mapping thought units onto pulses, the `...` pause threads, the `[fast][/fast]`
tags, shortening anything that will not fit its slot — stays in Step 2 and
Step 3, which already accept "timed English + a translation" as their input.

THE LOOP
--------
A translation Lekhak returns is stored there as a paste. When the human approves
the reviewed script in REAPER, `lekhak_keep()` sends the approved wording back
and marks it Kept — which is what feeds that desk's memory and style learner. An
exact match next time costs no LLM call at all.

The dubbing marks are stripped before that happens (`lekhak_clean_for_memory`).
The desk is shared with human translators; teaching it to emit `...` and
`[fast]` tags would damage their work.

TALKING TO IT
-------------
Two doors guard Lekhak: Cloudflare Access at the edge, and a per-language desk
password inside. On a laptop talking to its own container over loopback only the
second applies, and the desk cookie is checked before Cloudflare's token anyway.

Every request goes through config._urlopen so the repo keeps ONE TLS policy.
Connection-level failures are retried with backoff — the dubbing engine has been
killed by a single dropped socket before, and a translation that has already
been paid for upstream is not worth losing to one blip.
"""

import json
import time
import urllib.error
import urllib.request
from typing import Dict, Optional, Tuple

from .config import _urlopen
from .llm import _get_llm_settings

# ─────────────────────────────────────────────────────────────────────────────
# Settings
#
# These live in config/llm_settings.json beside every other credential, because
# the panel's Settings tab is the single place anything secret is typed. The
# defaults below are what an install that has never heard of Lekhak behaves
# like: disabled, so the Gemini chain runs exactly as it always did.
# ─────────────────────────────────────────────────────────────────────────────

LEKHAK_SETTINGS_DEFAULTS: Dict[str, str] = {
    # "gemini" (the shipped default) or "lekhak".
    "translator":          "gemini",
    "lekhak_base_url":     "http://127.0.0.1:3000",
    "lekhak_password":     "",
    # Languages Lekhak is allowed to translate. Anything not listed falls back
    # to the Gemini chain even when translator == "lekhak", so enabling this on
    # a trial language cannot change what the other eleven do.
    "lekhak_languages":    "Telugu,Hindi,Nepali,Marathi",
    # Send the approved script back as a Kept pair after the human review pause.
    "lekhak_learn":        "1",
}

# Fast-syncs spells a language "Telugu"; Lekhak's desks are lowercase ids.
# Kept explicit rather than str.lower() so an unsupported language is a clear
# refusal instead of a 400 from the far end.
LEKHAK_LANGUAGE_IDS: Dict[str, str] = {
    "Assamese":  "assamese",
    "Bengali":   "bengali",
    "Gujarati":  "gujarati",
    "Hindi":     "hindi",
    "Kannada":   "kannada",
    "Malayalam": "malayalam",
    "Marathi":   "marathi",
    "Nepali":    "nepali",
    "Odia":      "odia",
    "Punjabi":   "punjabi",
    "Tamil":     "tamil",
    "Telugu":    "telugu",
}

# A stable id so every run of this pipeline owns one history inside the desk,
# separate from the human translators sharing the same password. Lekhak accepts
# only a UUID shape here and falls back to the bare desk name otherwise.
_DESK_CLIENT_ID = "fa57539c-0000-4000-8000-726561706572"

_HTTP_TIMEOUT = 900          # a 30-page talk is several batched calls
_ATTEMPTS = 3
_BACKOFF_SECS = (5, 15)      # waits after attempts 1 and 2


class LekhakError(RuntimeError):
    """Lekhak could not be used. Always actionable — never a silent fallback."""


# ─────────────────────────────────────────────────────────────────────────────
# Settings helpers
# ─────────────────────────────────────────────────────────────────────────────

def _setting(key: str) -> str:
    s = _get_llm_settings()
    v = s.get(key, LEKHAK_SETTINGS_DEFAULTS.get(key, ""))
    return (v or "").strip()


def lekhak_base_url() -> str:
    base = _setting("lekhak_base_url") or LEKHAK_SETTINGS_DEFAULTS["lekhak_base_url"]
    return base.rstrip("/")


def lekhak_language_id(language: str) -> Optional[str]:
    return LEKHAK_LANGUAGE_IDS.get((language or "").strip())


def lekhak_languages_enabled() -> list:
    raw = _setting("lekhak_languages") or LEKHAK_SETTINGS_DEFAULTS["lekhak_languages"]
    return [p.strip() for p in raw.split(",") if p.strip()]


def lekhak_learn_enabled() -> bool:
    v = _setting("lekhak_learn")
    return v not in ("0", "false", "False", "no")


def lekhak_selected(language: str) -> bool:
    """True when this run should translate through Lekhak.

    Three conditions, all of them: the translator is switched over, the language
    is on the allow-list, and Lekhak knows that language. Any one missing means
    the Gemini chain runs — the shipped behaviour."""
    if _setting("translator").lower() != "lekhak":
        return False
    language = (language or "").strip()
    if language not in lekhak_languages_enabled():
        return False
    return lekhak_language_id(language) is not None


def lekhak_status_label(language: str) -> str:
    """One line for the engine banner, so a run says which translator it used."""
    if _setting("translator").lower() != "lekhak":
        return "Translator: Gemini prompt chain (Step1-3)."
    if not lekhak_selected(language):
        return (f"Translator: Gemini prompt chain — Lekhak is enabled but not "
                f"for {language} (allowed: "
                f"{', '.join(lekhak_languages_enabled()) or 'none'}).")
    learn = "on" if lekhak_learn_enabled() else "off"
    return (f"Translator: Lekhak desk '{lekhak_language_id(language)}' at "
            f"{lekhak_base_url()} (Step1 replaced; learn-back {learn}).")


# ─────────────────────────────────────────────────────────────────────────────
# HTTP
# ─────────────────────────────────────────────────────────────────────────────

def _request(method: str, path: str, body: Optional[dict] = None,
             cookie: str = "", timeout: int = _HTTP_TIMEOUT
             ) -> Tuple[dict, str]:
    """One call to Lekhak. Returns (parsed JSON, Set-Cookie header).

    Retried on connection-level failures only. An HTTP status is an answer, not
    a blip: a 401 means the password is wrong and retrying it twice more just
    burns the login rate limiter.
    """
    url = lekhak_base_url() + path
    data = json.dumps(body or {}).encode("utf-8") if body is not None else None
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        # Gives this pipeline its own paste history inside the shared desk.
        "x-lekhak-desk": _DESK_CLIENT_ID,
    }
    if cookie:
        headers["Cookie"] = cookie

    last_err: Optional[BaseException] = None
    for attempt in range(1, _ATTEMPTS + 1):
        req = urllib.request.Request(url, data=data, headers=headers,
                                     method=method)
        try:
            with _urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8", "replace")
                set_cookie = resp.headers.get("Set-Cookie", "") or ""
            break
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = e.read().decode("utf-8", "replace")[:400]
            except Exception:
                pass
            try:
                detail = json.loads(detail).get("error", detail)
            except Exception:
                pass
            raise LekhakError(
                f"Lekhak returned HTTP {e.code} for {method} {path}: "
                f"{detail or e.reason}") from e
        except Exception as e:
            # urllib wraps most socket trouble in URLError, but a connection
            # reset while waiting for the first response byte arrives raw from
            # http.client. Both are the same thing to us: try again.
            last_err = e
            if attempt < _ATTEMPTS:
                time.sleep(_BACKOFF_SECS[attempt - 1])
                continue
            raise LekhakError(
                f"Cannot reach Lekhak at {url} after {_ATTEMPTS} attempts: {e}. "
                "Check that the Lekhak container is running and that "
                "\"lekhak_base_url\" in config/llm_settings.json points at it."
            ) from e
    else:                                      # pragma: no cover - defensive
        raise LekhakError(f"Cannot reach Lekhak at {url}: {last_err}")

    if not raw.strip():
        return {}, set_cookie
    try:
        parsed = json.loads(raw)
    except ValueError:
        if raw.lstrip()[:1] == "<":
            raise LekhakError(
                f"{url} returned an HTML page, not JSON. The base URL is "
                "probably the web interface rather than the server root, or a "
                "sign-in page is in front of it.") from None
        raise LekhakError(f"Unexpected reply from {url}: {raw[:300]}") from None
    if not isinstance(parsed, dict):
        raise LekhakError(f"Unexpected reply from {url}: {raw[:300]}")
    return parsed, set_cookie


def _session_cookie(value: str) -> str:
    """The name=value pair out of a Set-Cookie header, attributes dropped."""
    return (value or "").split(";", 1)[0].strip()


def lekhak_login(language: str) -> str:
    """Sign in at this language's desk. Returns the cookie to carry."""
    desk = lekhak_language_id(language)
    if not desk:
        raise LekhakError(f"Lekhak has no desk for {language!r}.")
    password = _setting("lekhak_password")
    if not password:
        raise LekhakError(
            "The Lekhak desk password is empty — set \"lekhak_password\" in "
            "config/llm_settings.json (the panel's Settings tab).")

    data, set_cookie = _request(
        "POST", "/api/other-auth/login",
        {"username": desk, "password": password}, timeout=60)
    cookie = _session_cookie(set_cookie)
    if not cookie:
        raise LekhakError(
            f"Lekhak accepted the sign-in for desk {desk!r} but sent no session "
            "cookie. Check that the Other-translation logins are switched on "
            "there (LEKHAK_OTHER_USERS).")
    if not data.get("ok"):
        raise LekhakError(f"Lekhak refused the sign-in for desk {desk!r}.")
    return cookie


# ─────────────────────────────────────────────────────────────────────────────
# Translation
# ─────────────────────────────────────────────────────────────────────────────

# How long to keep asking, and how often. A talk is about thirty pages and
# twelve model calls a page, so several minutes is normal; the ceiling is there
# so a wedged job ends with a message instead of hanging a REAPER run forever.
_POLL_EVERY_S = 3.0
_POLL_MAX_S = 1800


def lekhak_translate(english_text: str, language: str,
                     status_cb=None) -> Dict[str, object]:
    """Translate plain English through this language's Lekhak desk.

    *english_text* is prose, NOT the timed analysis format: Lekhak has no way to
    read timings and would translate the annotations as if they were words.

    Lekhak queues the work and is polled for the result. It used to answer the
    POST directly; a long paste outran the hundred seconds Cloudflare holds a
    connection open, so the request died with a 524 while the server quietly
    finished the job. Starting a job and asking after it cannot hit that wall.

    Returns {"text", "paste_id", "from_memory", "pages"}.
    """
    def say(msg):
        if status_cb:
            status_cb(msg)

    desk = lekhak_language_id(language)
    source = (english_text or "").strip()
    if not source:
        raise LekhakError("There is no English text to send to Lekhak.")

    say(f"Lekhak: signing in at the '{desk}' desk…")
    cookie = lekhak_login(language)

    say(f"Lekhak: sending {len(source)} characters to translate…")
    started, _ = _request("POST", "/api/other/translate", {
        "lang": desk,
        "text": source,
        # The proofer marks sentences for a human to re-read and costs an extra
        # call per six pages. Nothing downstream reads its findings, and the
        # human review pause is the place that job is done here.
        "proof": False,
    }, cookie=cookie, timeout=120)

    job = started.get("job") or {}
    job_id = job.get("id") or ""
    if not job_id:
        # An older Lekhak answered the POST with the finished paste. Accept it
        # so this keeps working against either version.
        paste = started.get("paste") or {}
        if (paste.get("text") or "").strip():
            return {
                "text": paste["text"].strip(),
                "paste_id": paste.get("id") or "",
                "from_memory": int(started.get("fromMemory") or 0),
                "pages": int(started.get("pages") or 0),
            }
        raise LekhakError(
            "Lekhak accepted the text but returned neither a job nor a "
            "translation. Check its log for what it did with the paste.")

    say("Lekhak: translating…")
    waited = 0.0
    last_said = 0.0
    while True:
        time.sleep(_POLL_EVERY_S)
        waited += _POLL_EVERY_S
        data, _ = _request("GET", f"/api/other/translate/{job_id}",
                           cookie=cookie, timeout=120)
        job = data.get("job") or {}
        state = (job.get("status") or "").strip().lower()

        if state == "done":
            paste = data.get("paste") or {}
            text = (paste.get("text") or "").strip()
            if not text:
                raise LekhakError(
                    "Lekhak finished the translation but the text came back "
                    "empty. Check its log for this paste.")
            pages = int(job.get("pages") or 0)
            from_memory = int(job.get("fromMemory") or 0)
            if from_memory:
                say(f"Lekhak: {from_memory} of {pages} page(s) came from its "
                    "memory (no model call).")
            say(f"Lekhak: done in {waited:.0f}s "
                f"({pages} page(s), {int(job.get('calls') or 0)} model call(s)).")
            return {
                "text": text,
                "paste_id": paste.get("id") or job.get("pasteId") or "",
                "from_memory": from_memory,
                "pages": pages,
            }

        if state == "failed":
            raise LekhakError(
                f"Lekhak could not translate this text: "
                f"{job.get('error') or 'no reason given'}")

        if waited - last_said >= 30:
            last_said = waited
            say(f"Lekhak: still translating… ({waited:.0f}s)")

        if waited >= _POLL_MAX_S:
            raise LekhakError(
                f"Lekhak has been translating for {_POLL_MAX_S // 60} minutes "
                f"and has not finished (job {job_id}). The run is stopping "
                "rather than waiting further — check Lekhak's own log.")


# ─────────────────────────────────────────────────────────────────────────────
# Learning back
# ─────────────────────────────────────────────────────────────────────────────

# Everything Step 2 and Step 3 add to make a translation dubbable. It is all
# stripped before anything is stored, because this desk is shared with people
# translating ordinary text and must not learn to emit dubbing marks.
def lekhak_clean_for_memory(script_text: str) -> str:
    """The approved script with the dubbing marks taken back out."""
    import re as _re
    text = script_text or ""
    # Pace tags: keep what is inside them, drop the tags themselves.
    text = _re.sub(r"\[/?fast\]", "", text, flags=_re.IGNORECASE)
    # Other inline audio tags the emotion step may have added ([calm], [pause]…).
    text = _re.sub(r"\[[a-zA-Z][a-zA-Z0-9 _-]{0,20}\]", "", text)
    # Pause threads become ordinary sentence flow.
    text = text.replace("…", " ")
    text = _re.sub(r"\.\s*\.\s*\.", " ", text)
    text = _re.sub(r"\s+-\s+", " ", text)
    text = _re.sub(r"[ \t]+", " ", text)
    text = _re.sub(r"\n{3,}", "\n\n", text)
    return "\n".join(line.strip() for line in text.splitlines()).strip()


def lekhak_keep(paste_id: str, approved_text: str, language: str,
                status_cb=None) -> bool:
    """Send the approved script back and mark it Kept.

    Kept pairs are what the desk's sentence memory and style learner read, so
    this is the whole reason the quality goes up with use. Best-effort by
    design: a dub that has already been synthesised must not fail because the
    memory write did not land.
    """
    def say(msg):
        if status_cb:
            status_cb(msg)

    if not paste_id:
        say("Lekhak: nothing to learn from (no paste id from this run).")
        return False
    cleaned = lekhak_clean_for_memory(approved_text)
    if not cleaned:
        return False

    try:
        cookie = lekhak_login(language)
        _request("PUT", f"/api/other/pastes/{paste_id}",
                 {"text": cleaned, "keep": True}, cookie=cookie, timeout=120)
    except LekhakError as e:
        say(f"Lekhak: could not save the approved script for learning ({e}).")
        return False
    say("Lekhak: approved script saved — this desk has learned from it.")
    return True
