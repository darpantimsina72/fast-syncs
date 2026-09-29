"""
Cartesia text-to-speech, voice changer and voice catalogue (v0.15.8).

NEW code, not extracted from the bulk app. It mirrors the ElevenLabs
functions in tts.py one for one, so the engine can swap providers without
any stage knowing which one is speaking:

    ElevenLabs (tts.py)                  Cartesia (this module)
    synthesize_tts_elevenlabs        ->  synthesize_tts_cartesia
    synthesize_sections_elevenlabs   ->  synthesize_sections_cartesia
    synthesize_sentences_elevenlabs  ->  synthesize_sentences_cartesia
    voice_change_elevenlabs          ->  voice_change_cartesia
    stt._fetch_voices_for_language   ->  _fetch_cartesia_voices

The shared plumbing (retry loop, parallel runner, reuse sidecars, locked
output divert, chunkers, sentence packing, span maths) is imported from
tts.py / config.py, not copied — so both providers keep the same rules.

Differences that matter, all handled below:
  * Voice ids are UUIDs ("a0e99841-438c-4a64-b679-ae501e7d6091"), not the
    20-char ElevenLabs tokens — own sanitizer, own regex.
  * Cartesia needs the language code on every request (it does not guess
    from the script). Taken from TTS_LANGUAGES[...]["code"] ("te-IN" -> "te").
  * Timings come back per WORD (SSE "timestamps" events), not per
    character. _word_times_to_char_table turns them into the per-character
    table tts._sentence_spans_from_alignment already understands.
  * No ElevenLabs audio tags. [calm] / [pause] … would be read aloud, so
    they are stripped before every request.
  * Output is PCM/WAV, not MP3 — reuse sidecars are .wav files.

API reference: https://docs.cartesia.ai/api-reference (Cartesia-Version
2026-08-14). Endpoints used: POST /tts/bytes, POST /tts/sse,
POST /voice-changer/bytes, GET /voices.
"""

import base64
import hashlib
import io
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid
import wave
from typing import Dict, List, Optional

from .config import (_urlopen, CARTESIA_TTS_MODEL, ELEVENLABS_CHUNK_CHARS,
                     PYDUB_AVAILABLE, TTS_LANGUAGES, TTS_SETTINGS_FILE,
                     _AudioSegment, _strip_emotion_tags, _run_parallel,
                     load_tts_settings, pieces_base)
from .tts import (ELEVENLABS_TTS_WORKERS, SECTION_GAP_MS, _el_send,
                  _locked_cb, _pack_sentences, _read_reuse_sidecar,
                  _sentence_spans_from_alignment, _split_audio_for_sts,
                  _split_text_for_elevenlabs, _write_reuse_sidecar,
                  ensure_writable_output)

CARTESIA_API_BASE = "https://api.cartesia.ai"
CARTESIA_VERSION = "2026-08-14"
CARTESIA_SAMPLE_RATE = 44100
# Same request sizes as ElevenLabs, so a script splits into the same pieces
# on either provider (and a chunk redo is still one take).
CARTESIA_CHUNK_CHARS = ELEVENLABS_CHUNK_CHARS
CARTESIA_ONE_TAKE_CHARS = 2800

# Cartesia Sonic has no Assamese. Bengali is the same script and the nearest
# pronunciation, so it is used instead — with a loud note in the log.
_CARTESIA_LANG_FALLBACK = {"as": "bn"}

_CA_VOICE_ID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{12}$")

_CA_VOICE_CACHE: Dict[tuple, List[Dict[str, str]]] = {}
_CA_MAX_PAGES = 50          # 5,000 voices. A runaway guard, not a policy.


# ─── Small helpers ──────────────────────────────────────────────────────────

def _sanitize_cartesia_voice_id(raw) -> str:
    """*raw* unchanged if it is a clean Cartesia voice id (a UUID), else "".

    Strict, like stt._sanitize_voice_id: a display label or an ElevenLabs
    id is rejected, never "repaired" into something that looks valid."""
    if raw is None:
        return ""
    s = str(raw).strip()
    return s if _CA_VOICE_ID_RE.match(s) else ""


def _get_cartesia_api_key() -> str:
    """Cartesia key from config/tts_settings.json, or an actionable error."""
    key = (load_tts_settings().get("cartesia_api_key") or "").strip()
    if not key:
        raise ValueError(
            "No Cartesia API key configured.\n"
            f"Add \"cartesia_api_key\" to {TTS_SETTINGS_FILE} — open the "
            "REAPER panel's Settings tab, choose Cartesia as the voice "
            "provider and paste your key there.")
    return key


def cartesia_language(language: str, status_cb=None) -> str:
    """Cartesia language code for a display name ("Telugu" -> "te")."""
    code = str((TTS_LANGUAGES.get(language) or {}).get("code") or "")
    primary = code.split("-")[0].strip().lower() or "en"
    fb = _CARTESIA_LANG_FALLBACK.get(primary)
    if fb:
        if status_cb:
            status_cb(f"NOTE: Cartesia has no {language} voice model — "
                      f"speaking it with the '{fb}' model (same script).")
        return fb
    return primary


def _ca_headers(api_key: str, accept: str, content_type: str = None) -> dict:
    h = {
        "Authorization": f"Bearer {api_key}",
        "Cartesia-Version": CARTESIA_VERSION,
        "Accept": accept,
    }
    if content_type:
        h["Content-Type"] = content_type
    return h


def _ca_http_error(e: urllib.error.HTTPError, what: str, voice_id: str = ""):
    """Map a Cartesia HTTP failure to a ValueError the user can act on."""
    body = ""
    try:
        body = e.read().decode("utf-8", errors="replace")[:500]
    except Exception:
        pass
    if e.code == 401:
        return ValueError("Cartesia rejected the API key (401). Re-paste a "
                          "valid key in Settings.")
    if e.code == 402:
        return ValueError("Cartesia says the account is out of credits "
                          "(402). Top up on play.cartesia.ai.")
    if e.code == 404 and voice_id:
        return ValueError(
            f"Cartesia voice not found (404). voice_id={voice_id!r} is not "
            "on this account. Fetch the voice list again and pick a voice "
            "from it.")
    if e.code == 429:
        return ValueError("Cartesia rate limit hit (429). Try again shortly.")
    return ValueError(f"Cartesia {what} error (HTTP {e.code}): {body}")


def _ca_prepare_text(text: str) -> str:
    """ElevenLabs audio tags ([calm], [pause]…) mean nothing to Cartesia and
    would be read aloud — strip them (keep the original if only tags)."""
    stripped = _strip_emotion_tags(text or "")
    return stripped if stripped.strip() else (text or "")


def _ca_tts_body(text: str, voice_id: str, model_id: str, lang: str,
                 sse: bool) -> bytes:
    body = {
        "model_id": model_id,
        "transcript": text,
        "voice": {"mode": "id", "id": voice_id},
        "language": lang,
        "output_format": {
            # /tts/sse only streams raw PCM; /tts/bytes can wrap it in WAV.
            "container": "raw" if sse else "wav",
            "encoding": "pcm_s16le",
            "sample_rate": CARTESIA_SAMPLE_RATE,
        },
    }
    if sse:
        body["add_timestamps"] = True
        # Timings for the text AS SENT: our sentence offsets index into it
        # (same reason the ElevenLabs path reads `alignment`, not the
        # normalized one).
        body["use_normalized_timestamps"] = False
    return json.dumps(body, ensure_ascii=False).encode("utf-8")


def _ca_request_key(url: str, payload: bytes) -> str:
    """Identity of one request (endpoint + exact body). API key excluded."""
    h = hashlib.sha256()
    h.update(url.encode("utf-8"))
    h.update(b"\x00")
    h.update(payload)
    return h.hexdigest()


def _pcm_to_wav(pcm: bytes, rate: int = CARTESIA_SAMPLE_RATE) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        wf.writeframes(pcm)
    return buf.getvalue()


def _wav_segment(audio: bytes):
    """Decode WAV bytes with pydub, with the usual ffmpeg hint on failure."""
    try:
        return _AudioSegment.from_file(io.BytesIO(audio), format="wav")
    except FileNotFoundError:
        raise RuntimeError(
            "ffmpeg/ffprobe not found — pydub needs it to assemble the "
            "Cartesia audio. Re-run the setup script (setup_windows.bat / "
            "setup_mac.command). Then run the dub again.")


def _export_wav(combined, output_path: str, status_cb=None) -> str:
    try:
        combined.export(output_path, format="wav")
    except PermissionError:
        # Locked while synthesizing (previous wav opened mid-run): divert
        # instead of losing audio the credits already paid for.
        output_path = ensure_writable_output(output_path, status_cb=status_cb)
        combined.export(output_path, format="wav")
    return output_path


def _check_common(api_key, voice_id):
    """Validate key + voice id up front; returns (key, voice_id)."""
    if not api_key or not str(api_key).strip():
        raise ValueError("Cartesia API key is missing — set "
                         "\"cartesia_api_key\" in config/tts_settings.json.")
    raw = str(voice_id or "").strip()
    if not raw:
        raise ValueError("No Cartesia voice selected. Pick one in Settings "
                         "(Fetch voices) or pass --voice-id.")
    vid = _sanitize_cartesia_voice_id(raw)
    if not vid:
        raise ValueError(
            f"Invalid Cartesia voice id (received: {raw!r}). Cartesia voice "
            "ids look like 'a0e99841-438c-4a64-b679-ae501e7d6091'. An "
            "ElevenLabs voice id does not work here — pick a Cartesia voice.")
    return str(api_key).strip(), vid


# ─── Requests ───────────────────────────────────────────────────────────────

def _cartesia_tts_wav(text: str, api_key: str, voice_id: str, model_id: str,
                      lang: str) -> bytes:
    """One /tts/bytes request -> WAV bytes."""
    url = CARTESIA_API_BASE + "/tts/bytes"
    payload = _ca_tts_body(text, voice_id, model_id, lang, sse=False)
    try:
        return _el_send(lambda: urllib.request.Request(
            url, data=payload, method="POST",
            headers=_ca_headers(api_key, "audio/wav",
                                "application/json; charset=utf-8"),
        ), timeout=300, label="Cartesia")
    except urllib.error.HTTPError as e:
        raise _ca_http_error(e, "TTS", voice_id) from None
    except urllib.error.URLError as e:
        raise ValueError(f"Network error during Cartesia TTS: {e.reason}") from None


def _parse_sse(raw: bytes):
    """Cartesia SSE body -> (pcm bytes, words, starts, ends)."""
    pcm = bytearray()
    words, starts, ends = [], [], []
    for line in raw.decode("utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        try:
            ev = json.loads(line[5:].strip())
        except ValueError:
            continue
        if not isinstance(ev, dict):
            continue
        kind = ev.get("type")
        if kind == "error" or (isinstance(ev.get("status_code"), int)
                               and ev["status_code"] >= 400):
            raise ValueError(
                "Cartesia TTS error: "
                f"{ev.get('title') or ''} {ev.get('message') or ev}".strip())
        if kind == "chunk" and ev.get("data"):
            pcm += base64.b64decode(ev["data"])
        elif kind == "timestamps":
            wt = ev.get("word_timestamps") or {}
            words += list(wt.get("words") or [])
            starts += list(wt.get("start") or [])
            ends += list(wt.get("end") or [])
        elif kind == "done":
            break
    return bytes(pcm), words, starts, ends


def _cartesia_tts_timed(text: str, api_key: str, voice_id: str,
                        model_id: str, lang: str):
    """One /tts/sse request with word timestamps -> (wav, words, starts, ends)."""
    url = CARTESIA_API_BASE + "/tts/sse"
    payload = _ca_tts_body(text, voice_id, model_id, lang, sse=True)
    try:
        raw = _el_send(lambda: urllib.request.Request(
            url, data=payload, method="POST",
            headers=_ca_headers(api_key, "text/event-stream",
                                "application/json; charset=utf-8"),
        ), timeout=300, label="Cartesia")
    except urllib.error.HTTPError as e:
        raise _ca_http_error(e, "TTS", voice_id) from None
    except urllib.error.URLError as e:
        raise ValueError(f"Network error during Cartesia TTS: {e.reason}") from None
    pcm, words, starts, ends = _parse_sse(raw)
    if not pcm:
        raise ValueError("Cartesia returned no audio for a timed request.")
    return _pcm_to_wav(pcm), words, starts, ends


def _word_times_to_char_table(text: str, words, starts, ends,
                              duration_s: float):
    """Word timings -> the per-character (chars, starts, ends) table that
    tts._sentence_spans_from_alignment reads.

    Each word is found in *text* left to right; its characters get the
    word's start/end. Characters no word covers (spaces, a word Cartesia
    spelled differently) inherit the previous word's end, which puts a
    sentence boundary in the gap between words — where it belongs. If NO
    word can be found, returns empty char lists and ends=[duration], which
    makes the span function fall back to a proportional estimate."""
    n = len(text)
    cs: List[Optional[float]] = [None] * n
    ce: List[Optional[float]] = [None] * n
    pos, found = 0, 0
    for w, s, e in zip(words, starts, ends):
        w = str(w or "").strip()
        if not w:
            continue
        k = text.find(w, pos)
        if k < 0:
            continue
        try:
            s_f, e_f = float(s), float(e)
        except (TypeError, ValueError):
            continue
        for j in range(k, k + len(w)):
            cs[j], ce[j] = s_f, e_f
        pos = k + len(w)
        found += 1
    if not found:
        return [], [], [float(duration_s)]
    last = 0.0
    for j in range(n):
        if cs[j] is None:
            cs[j] = ce[j] = last
        else:
            last = ce[j]
    return list(text), cs, ce


# ─── Synthesis (mirrors of the three ElevenLabs synthesizers) ───────────────

def synthesize_tts_cartesia(text: str, output_path: str, api_key: str,
                            voice_id: str, model_id: str = CARTESIA_TTS_MODEL,
                            language: str = "", status_cb=None,
                            workers: int = None, max_chars: int = None) -> str:
    """Whole-script TTS -> one WAV. Mirror of synthesize_tts_elevenlabs:
    same chunking, same side files (<base>_chunk_NN.wav, _chunks.txt), same
    locked-output divert. Returns the (possibly diverted) output path."""
    api_key, voice_id = _check_common(api_key, voice_id)
    text = _ca_prepare_text(text)
    if not text.strip():
        raise ValueError("TTS text is empty — nothing to synthesize.")
    if not PYDUB_AVAILABLE:
        raise RuntimeError("pydub not installed — Cartesia TTS needs it to "
                           "join the audio. Re-run the setup script.")
    model_id = (model_id or CARTESIA_TTS_MODEL).strip() or CARTESIA_TTS_MODEL
    lang = cartesia_language(language, status_cb)
    output_path = ensure_writable_output(output_path, status_cb=status_cb)

    chunks = _split_text_for_elevenlabs(text, max_chars or CARTESIA_CHUNK_CHARS)
    total = len(chunks)
    out_base = pieces_base(output_path)
    workers = ELEVENLABS_TTS_WORKERS if workers is None else max(1, int(workers))
    say = _locked_cb(status_cb)
    if say:
        say(f"TTS: Cartesia generating audio… {total} chunk(s), up to "
            f"{min(workers, total)} at a time")

    def _done(idx, audio):
        with open(f"{out_base}_chunk_{idx + 1:02d}.wav", "wb") as cf:
            cf.write(audio)
        if say and total > 1:
            say(f"TTS: Cartesia chunk {idx + 1} of {total} done")

    parts = _run_parallel(
        [(lambda c=c: _cartesia_tts_wav(c, api_key, voice_id, model_id, lang))
         for c in chunks], workers, on_done=_done)

    log = [f"TTS Chunk Log — {os.path.basename(output_path)}",
           "Platform : Cartesia", f"Voice ID : {voice_id}",
           f"Model    : {model_id}", f"Language : {lang}",
           f"Total chunks: {total}", ""]
    for i, c in enumerate(chunks, 1):
        log += [f"=== CHUNK {i} of {total} ===", f"Characters : {len(c)}",
                f"Audio saved : {os.path.basename(out_base)}_chunk_{i:02d}.wav",
                "--- Text ---", c, ""]
    with open(out_base + "_chunks.txt", "w", encoding="utf-8") as lf:
        lf.write("\n".join(log))

    combined = _AudioSegment.empty()
    for p in parts:
        combined += _wav_segment(p)
    if status_cb:
        status_cb(f"TTS: Saving → {os.path.basename(output_path)}…")
    return _export_wav(combined, output_path, status_cb)


def synthesize_sections_cartesia(section_texts, output_path: str,
                                 api_key: str, voice_id: str,
                                 model_id: str = CARTESIA_TTS_MODEL,
                                 language: str = "", status_cb=None,
                                 workers: int = None):
    """One piece per section -> (output_path, spans). Mirror of
    synthesize_sections_elevenlabs (same gap, same reuse rule; sidecars are
    <base>_csec_NNN.wav). Cartesia's HTTP API has no previous/next-text
    stitching, so each section is spoken on its own."""
    api_key, voice_id = _check_common(api_key, voice_id)
    sections = [_ca_prepare_text((t or "").strip()).strip()
                for t in (section_texts or [])]
    if not sections or any(not t for t in sections):
        raise ValueError("Section list is empty or contains an empty "
                         "section — nothing to synthesize.")
    if not PYDUB_AVAILABLE:
        raise RuntimeError("pydub not installed — the sectioned TTS mode "
                           "needs it. Re-run the setup script.")
    model_id = (model_id or CARTESIA_TTS_MODEL).strip() or CARTESIA_TTS_MODEL
    lang = cartesia_language(language, status_cb)
    output_path = ensure_writable_output(output_path, status_cb=status_cb)
    out_base = pieces_base(output_path)
    total = len(sections)
    url = CARTESIA_API_BASE + "/tts/bytes"

    plan = [_split_text_for_elevenlabs(t) for t in sections]

    def _sec_key(subs):
        h = hashlib.sha256()
        for sub in subs:
            h.update(_ca_request_key(
                url, _ca_tts_body(sub, voice_id, model_id, lang, False))
                .encode("ascii"))
        return h.hexdigest()

    say = _locked_cb(status_cb)
    keys = [_sec_key(p) for p in plan]
    audio = [None] * total
    for i in range(total):
        hit = _read_reuse_sidecar(f"{out_base}_csec_{i + 1:03d}.wav", keys[i])
        if hit:
            audio[i] = hit[0]
            if say:
                say(f"TTS: section {i + 1} of {total} reused from the "
                    "previous run (same text, voice and model).")

    todo = [i for i in range(total) if audio[i] is None]
    workers = ELEVENLABS_TTS_WORKERS if workers is None else max(1, int(workers))
    if todo and say:
        say(f"TTS: Cartesia synthesizing {len(todo)} section(s), up to "
            f"{min(workers, len(todo))} at a time…")

    def _speak(i):
        seg = _AudioSegment.empty()
        for sub in plan[i]:
            seg += _wav_segment(
                _cartesia_tts_wav(sub, api_key, voice_id, model_id, lang))
        buf = io.BytesIO()
        seg.export(buf, format="wav")
        return buf.getvalue()

    def _done(j, wav_bytes):
        i = todo[j]
        audio[i] = wav_bytes
        _write_reuse_sidecar(f"{out_base}_csec_{i + 1:03d}.wav", wav_bytes,
                             {"key": keys[i]})
        if say:
            say(f"TTS: section {i + 1} of {total} ({len(sections[i])} chars) done")

    _run_parallel([(lambda i=i: _speak(i)) for i in todo], workers,
                  on_done=_done)

    combined = _AudioSegment.empty()
    spans, cursor = [], 0
    log = [f"TTS Section Log — {os.path.basename(output_path)}",
           "Platform : Cartesia (sectioned)", f"Voice ID : {voice_id}",
           f"Model    : {model_id}", f"Language : {lang}",
           f"Sections : {total}",
           f"Gap      : {SECTION_GAP_MS}ms between sections (spans exclude it)",
           ""]
    for i, wav_bytes in enumerate(audio):
        seg = _wav_segment(wav_bytes)
        if i > 0:
            combined += _AudioSegment.silent(duration=SECTION_GAP_MS,
                                             frame_rate=seg.frame_rate)
            cursor += SECTION_GAP_MS
        spans.append((cursor, cursor + len(seg)))
        combined += seg
        cursor += len(seg)
        log += [f"=== SECTION {i + 1} of {total} ===",
                f"Characters : {len(sections[i])}", f"Duration   : {len(seg)}ms",
                "--- Text ---", sections[i], ""]
    with open(out_base + "_chunks.txt", "w", encoding="utf-8") as lf:
        lf.write("\n".join(log))
    if say:
        say(f"TTS: Saving → {os.path.basename(output_path)}… ({total} sections)")
    return _export_wav(combined, output_path, status_cb), spans


def synthesize_sentences_cartesia(sentences, output_path: str, api_key: str,
                                  voice_id: str,
                                  model_id: str = CARTESIA_TTS_MODEL,
                                  language: str = "", status_cb=None,
                                  workers: int = None):
    """Long natural stretches, cut ONE PIECE PER SENTENCE at the word times
    Cartesia reports -> (output_path, spans). Mirror of
    synthesize_sentences_elevenlabs: same packing, same gap, same "last
    sentence keeps the tail" rule; sidecars are <base>_cstr_NNN.wav."""
    api_key, voice_id = _check_common(api_key, voice_id)
    sentences = [_ca_prepare_text((t or "").strip()).strip()
                 for t in (sentences or [])]
    if not sentences or any(not t for t in sentences):
        raise ValueError("Sentence list is empty or contains an empty "
                         "sentence — nothing to synthesize.")
    if not PYDUB_AVAILABLE:
        raise RuntimeError("pydub not installed — the sentence-timed TTS "
                           "mode needs it. Re-run the setup script.")
    model_id = (model_id or CARTESIA_TTS_MODEL).strip() or CARTESIA_TTS_MODEL
    lang = cartesia_language(language, status_cb)
    output_path = ensure_writable_output(output_path, status_cb=status_cb)
    out_base = pieces_base(output_path)
    url = CARTESIA_API_BASE + "/tts/sse"

    groups = _pack_sentences(sentences, CARTESIA_CHUNK_CHARS)
    plan = []            # per stretch: (text, offsets, key)
    for group in groups:
        text = " ".join(sentences[i] for i in group)
        offsets, pos = [], 0
        for i in group:
            a = text.index(sentences[i], pos)
            offsets.append((a, a + len(sentences[i])))
            pos = a + len(sentences[i])
        key = _ca_request_key(
            url, _ca_tts_body(text, voice_id, model_id, lang, True))
        plan.append((text, offsets, key))

    n_groups = len(groups)
    say = _locked_cb(status_cb)
    replies = [None] * n_groups       # (wav, words, starts, ends)
    for gi in range(n_groups):
        hit = _read_reuse_sidecar(f"{out_base}_cstr_{gi + 1:03d}.wav",
                                  plan[gi][2])
        if hit:
            wav_bytes, meta = hit
            w, s, e = meta.get("words"), meta.get("starts"), meta.get("ends")
            if all(isinstance(x, list) for x in (w, s, e)):
                replies[gi] = (wav_bytes, w, s, e)
                if say:
                    say(f"TTS: stretch {gi + 1} of {n_groups} reused from "
                        "the previous run (same text, voice and model).")

    todo = [gi for gi in range(n_groups) if replies[gi] is None]
    workers = ELEVENLABS_TTS_WORKERS if workers is None else max(1, int(workers))
    if todo and say:
        say(f"TTS: Cartesia synthesizing {len(todo)} stretch(es), up to "
            f"{min(workers, len(todo))} at a time…")

    def _done(j, reply):
        gi = todo[j]
        replies[gi] = reply
        wav_bytes, w, s, e = reply
        _write_reuse_sidecar(f"{out_base}_cstr_{gi + 1:03d}.wav", wav_bytes,
                             {"key": plan[gi][2], "words": list(w),
                              "starts": list(s), "ends": list(e)})
        if say:
            say(f"TTS: stretch {gi + 1} of {n_groups} "
                f"({len(groups[gi])} sentence(s)) done")

    _run_parallel(
        [(lambda t=plan[gi][0]:
          _cartesia_tts_timed(t, api_key, voice_id, model_id, lang))
         for gi in todo], workers, on_done=_done)

    combined = _AudioSegment.empty()
    spans = [None] * len(sentences)
    cursor = 0
    log = [f"TTS Sentence Log — {os.path.basename(output_path)}",
           "Platform : Cartesia (/tts/sse, word-timed)",
           f"Voice ID : {voice_id}", f"Model    : {model_id}",
           f"Language : {lang}",
           f"Sentences: {len(sentences)} in {n_groups} request(s)",
           f"Gap      : {SECTION_GAP_MS}ms between requests (spans exclude it)",
           ""]
    for gi, group in enumerate(groups):
        text, offsets = plan[gi][0], plan[gi][1]
        wav_bytes, words, w_starts, w_ends = replies[gi]
        seg = _wav_segment(wav_bytes)
        seg_ms = len(seg)
        chars, c_starts, c_ends = _word_times_to_char_table(
            text, words, w_starts, w_ends, seg_ms / 1000.0)
        if not chars and say:
            say(f"TTS: WARNING — Cartesia word timings did not line up "
                f"with the text for stretch {gi + 1}; estimating sentence "
                "boundaries proportionally for this stretch.")
        rel = _sentence_spans_from_alignment(text, offsets, chars, c_starts,
                                             c_ends)
        if gi > 0:
            combined += _AudioSegment.silent(duration=SECTION_GAP_MS,
                                             frame_rate=seg.frame_rate)
            cursor += SECTION_GAP_MS
        for i, (rs, re_) in zip(group, rel):
            s_ms = max(0, min(seg_ms, int(round(rs * 1000))))
            e_ms = max(s_ms, min(seg_ms, int(round(re_ * 1000))))
            if e_ms == s_ms:
                e_ms = min(seg_ms, s_ms + 1)
            spans[i] = (cursor + s_ms, cursor + e_ms)
        li = group[-1]
        spans[li] = (spans[li][0], cursor + seg_ms)   # keep the tail
        combined += seg
        cursor += seg_ms
        log += [f"=== STRETCH {gi + 1} of {n_groups} ===",
                f"Sentences  : {[i + 1 for i in group]}",
                f"Duration   : {seg_ms}ms", f"Timed words: {len(words)}", ""]
        for i in group:
            log.append(f"  [{i + 1}] {spans[i][0]}ms-{spans[i][1]}ms  "
                       + " ".join(sentences[i].split())[:80])
        log.append("")

    with open(out_base + "_chunks.txt", "w", encoding="utf-8") as lf:
        lf.write("\n".join(log))
    if say:
        say(f"TTS: Saving → {os.path.basename(output_path)}… "
            f"({len(sentences)} sentence pieces)")
    return _export_wav(combined, output_path, status_cb), spans


# ─── Voice changer ──────────────────────────────────────────────────────────

def _cartesia_vc_post(wav_bytes: bytes, api_key: str, voice_id: str) -> bytes:
    """One /voice-changer/bytes request (multipart) -> WAV bytes."""
    boundary = "----ReaperDubCVC" + uuid.uuid4().hex
    fields = {
        "voice[id]": voice_id,
        "output_format[container]": "wav",
        "output_format[encoding]": "pcm_s16le",
        "output_format[sample_rate]": str(CARTESIA_SAMPLE_RATE),
    }
    body = io.BytesIO()
    for name, value in fields.items():
        body.write(f"--{boundary}\r\n".encode())
        body.write(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
                   .encode())
        body.write(value.encode("utf-8"))
        body.write(b"\r\n")
    body.write(f"--{boundary}\r\n".encode())
    body.write(b'Content-Disposition: form-data; name="clip"; '
               b'filename="clip.wav"\r\n')
    body.write(b"Content-Type: audio/wav\r\n\r\n")
    body.write(wav_bytes)
    body.write(f"\r\n--{boundary}--\r\n".encode())
    data = body.getvalue()
    url = CARTESIA_API_BASE + "/voice-changer/bytes"
    try:
        return _el_send(lambda: urllib.request.Request(
            url, data=data, method="POST",
            headers=_ca_headers(
                api_key, "audio/wav",
                f"multipart/form-data; boundary={boundary}"),
        ), timeout=600, label="Cartesia")
    except urllib.error.HTTPError as e:
        raise _ca_http_error(e, "voice-change", voice_id) from None
    except urllib.error.URLError as e:
        raise ValueError(
            f"Network error during Cartesia voice change: {e.reason}") from None


def voice_change_cartesia(input_path: str, output_path: str, api_key: str,
                          voice_id: str, status_cb=None) -> str:
    """Re-voice *input_path* with the Cartesia voice changer (keeps timing
    and intonation) -> WAV at *output_path*. Long inputs are split at quiet
    points into ≤ ~4-minute pieces, exactly like the ElevenLabs path."""
    api_key, voice_id = _check_common(api_key, voice_id)
    if not os.path.isfile(input_path):
        raise ValueError(f"Voice-change input audio not found: {input_path}")
    if not PYDUB_AVAILABLE:
        raise ImportError(
            "pydub is required for voice change (audio chunking + WAV "
            "export). Run the setup script, and make sure ffmpeg is "
            "installed.")
    if status_cb:
        status_cb("Voice change: loading the input audio…")
    seg = _AudioSegment.from_file(input_path)
    if len(seg) < 200:
        raise ValueError("Voice-change input audio is empty (or shorter "
                         "than 0.2 s).")
    pieces = _split_audio_for_sts(seg)
    total = len(pieces)
    if status_cb:
        status_cb(f"Voice change: {len(seg)/1000.0:.1f}s of audio in "
                  f"{total} chunk(s), Cartesia voice {voice_id}.")
    out_parent = os.path.dirname(os.path.abspath(output_path))
    if out_parent:
        os.makedirs(out_parent, exist_ok=True)

    combined = None
    for i, piece in enumerate(pieces, 1):
        if status_cb:
            status_cb(f"Voice change: converting chunk {i} of {total} "
                      f"({len(piece)/1000.0:.0f}s)…")
        buf = io.BytesIO()
        piece.set_channels(1).export(buf, format="wav")
        out = _wav_segment(_cartesia_vc_post(buf.getvalue(), api_key,
                                             voice_id))
        combined = out if combined is None else combined + out
    if status_cb:
        status_cb(f"Voice change: saving → {os.path.basename(output_path)}…")
    combined.export(output_path, format="wav")
    return output_path


# ─── Voice catalogue ────────────────────────────────────────────────────────

def _fetch_cartesia_voice_page(api_key: str, after: Optional[str],
                               timeout: float) -> dict:
    url = CARTESIA_API_BASE + "/voices?limit=100"
    if after:
        url += "&starting_after=" + urllib.parse.quote(after, safe="")
    try:
        with _urlopen(urllib.request.Request(
                url, method="GET",
                headers=_ca_headers(api_key, "application/json")),
                timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as e:
        raise _ca_http_error(e, "voice list") from None
    except urllib.error.URLError as e:
        raise ValueError(f"Could not fetch Cartesia voices: {e.reason}") from None
    if isinstance(data, list):          # very old API shape: a bare array
        return {"data": data, "has_more": False}
    return data if isinstance(data, dict) else {"data": []}


def _fetch_cartesia_voices(api_key: str, language: str = "",
                           force_refresh: bool = False,
                           timeout: float = 45.0) -> List[Dict[str, str]]:
    """Every voice the key can use (the account's own + Cartesia's public
    library), in the same {"voice_id","name","label"} shape as the
    ElevenLabs helper. Voices whose language matches *language* come first
    with a leading ✦ in the label; the account's own voices are tagged
    "mine" in the name so they are easy to spot."""
    api_key = (api_key or "").strip()
    if not api_key:
        raise ValueError("Cartesia API key is empty.")
    lang = cartesia_language(language) if language else ""
    cache_key = (api_key[-8:], lang)
    if not force_refresh and cache_key in _CA_VOICE_CACHE:
        return _CA_VOICE_CACHE[cache_key]

    raw, seen, after = [], set(), None
    for page_no in range(1, _CA_MAX_PAGES + 1):
        try:
            page = _fetch_cartesia_voice_page(api_key, after, timeout)
        except ValueError:
            if not raw:
                raise
            print(f"    [voices] Cartesia page {page_no} failed — keeping "
                  f"the {len(raw)} voice(s) already fetched", flush=True)
            break
        items = page.get("data") or []
        for v in items:
            if isinstance(v, dict) and v.get("id") and v["id"] not in seen:
                seen.add(v["id"])
                raw.append(v)
        if not page.get("has_more") or not items:
            break
        # Cursor = the last voice id of this page (what Cartesia's own SDK
        # sends as starting_after).
        after = items[-1].get("id") or page.get("next_page")
        if not after:
            break
    print(f"    [voices] {len(raw)} Cartesia voice(s) fetched", flush=True)

    matched, mine, other = [], [], []
    for v in raw:
        v_lang = str(v.get("language") or "").split("-")[0].lower()
        bits = [b for b in (v_lang, "mine" if v.get("is_owner") else "") if b]
        name = str(v.get("name") or "Unnamed voice").strip()
        shown = f"{name}  [{' · '.join(bits)}]" if bits else name
        entry = {"voice_id": v["id"], "name": shown}
        if lang and v_lang == lang:
            entry["label"] = "✦ " + shown
            matched.append(entry)
        else:
            entry["label"] = shown
            (mine if v.get("is_owner") else other).append(entry)
    for bucket in (matched, mine, other):
        bucket.sort(key=lambda e: e["name"].lower())
    out = matched + mine + other
    _CA_VOICE_CACHE[cache_key] = out
    return out
