"""
Text-to-speech: ElevenLabs synthesis (chunked, tag-safe) and the Google
Cloud TTS port, plus the byte/char chunkers shared by both engines.

Extracted from Translation_and_Syncing_App.py (bulk app, v1.8.0):
    lines 127-132   google-cloud-texttospeech optional import guard
    lines 2531-3072 "TTS helpers" (chunkers, Google TTS, ElevenLabs TTS)

Skipped on purpose (out of scope for the standalone engine):
    lines 2817-2844 _indic_matplotlib_font (matplotlib UI helper)
    lines 3093-3095, 3112-3204 multi-speaker dubbing (_speakers_save and
                    synthesize_tts_elevenlabs_multi). The read-only speaker
                    map helpers (lines 3080-3109 minus _speakers_save) ARE
                    ported so the engine can keep detecting and reporting a
                    saved voice map before ignoring it (v0.2 behaviour).

Adaptations (everything else is verbatim):
  * _build_tts_client() reads the Google service-account key path from
    config/tts_settings.json ("google_tts_key_path"); a blank value falls
    back to config/TTS_Key.json.
"""

import base64
import io
import json
import os
import re
import urllib.error
import urllib.request
import uuid
from typing import Dict, List

from .config import (_SSL_CTX, ELEVENLABS_CHUNK_CHARS, ELEVENLABS_TTS_MODEL,
                     ELEVENLABS_TTS_VOICE_ID, CONFIG_DIR, PYDUB_AVAILABLE,
                     TTS_DEFAULT_LANGUAGE, TTS_DEFAULT_VOICE, TTS_LANGUAGES,
                     TTS_MAX_BYTES, _AudioSegment, _strip_emotion_tags,
                     load_tts_settings)
from .stt import _sanitize_voice_id

try:
    from google.cloud import texttospeech as _tts_module
    from google.oauth2 import service_account as _sa_module
    TTS_AVAILABLE = True
except ImportError:
    TTS_AVAILABLE = False


def _split_text_into_chunks(text: str, max_bytes: int = TTS_MAX_BYTES) -> list:
    """
    Split *text* into a list of chunks where every chunk's UTF-8 encoded size
    is ≤ max_bytes.  Splits preferentially at:
      1. Paragraph breaks  (\\n)
      2. Sentence endings  (. ! ? ।)
      3. Word boundaries   (space)
      4. Hard character split (last resort)
    """
    if len(text.encode("utf-8")) <= max_bytes:
        return [text]

    def _fits(s):
        return len(s.encode("utf-8")) <= max_bytes

    def _split_para(para: str) -> list:
        pieces  = []
        current = ""
        sentences = re.split(r'(?<=[.!?।])\s+', para)
        for sent in sentences:
            if not sent:
                continue
            candidate = (current + " " + sent).strip() if current else sent
            if _fits(candidate):
                current = candidate
            else:
                if current:
                    pieces.append(current)
                if _fits(sent):
                    current = sent
                else:
                    words   = sent.split()
                    current = ""
                    for word in words:
                        candidate = (current + " " + word).strip() if current else word
                        if _fits(candidate):
                            current = candidate
                        else:
                            if current:
                                pieces.append(current)
                            if not _fits(word):
                                buf = ""
                                for ch in word:
                                    if _fits(buf + ch):
                                        buf += ch
                                    else:
                                        pieces.append(buf)
                                        buf = ch
                                current = buf
                            else:
                                current = word
        if current:
            pieces.append(current)
        return pieces

    chunks     = []
    current    = ""
    paragraphs = text.split("\n")

    for idx, para in enumerate(paragraphs):
        sep       = "\n" if idx < len(paragraphs) - 1 else ""
        candidate = (current + "\n" + para).lstrip("\n") if current else para

        if _fits(candidate + sep):
            current = candidate + sep
        else:
            if current:
                chunks.append(current.strip())
                current = ""
            if _fits(para):
                current = para + sep
            else:
                sub = _split_para(para)
                if sub:
                    chunks.extend(sub[:-1])
                    current = sub[-1] + sep if sub else ""

    if current.strip():
        chunks.append(current.strip())

    return chunks or [text]


def _build_tts_client():
    if not TTS_AVAILABLE:
        raise ImportError(
            "google-cloud-texttospeech not installed.\n"
            "Run: pip install google-cloud-texttospeech google-auth")
    key_file = (load_tts_settings().get("google_tts_key_path") or "").strip() \
               or os.path.join(CONFIG_DIR, "TTS_Key.json")
    if not os.path.exists(key_file):
        raise FileNotFoundError(
            f"Google TTS service-account JSON not found at {key_file} — "
            "set \"google_tts_key_path\" in config/tts_settings.json or "
            "copy the key to config/TTS_Key.json.")
    creds = _sa_module.Credentials.from_service_account_file(
        key_file,
        scopes=["https://www.googleapis.com/auth/cloud-platform"],
    )
    return _tts_module.TextToSpeechClient(credentials=creds)


def synthesize_tts(text: str, output_path: str, status_cb=None,
                   lang_code: str = None,
                   voice_name: str = TTS_DEFAULT_VOICE) -> str:
    """
    Convert text to speech and save WAV to output_path.
    Splits text into byte-safe chunks (≤ 4800 UTF-8 bytes) and joins the audio.
    lang_code is derived from voice_name when not provided.
    Returns output_path.
    """
    import wave as _wave_mod

    # Derive lang_code from voice_name (e.g. "hi-IN-Chirp3-HD-Aoede" → "hi-IN")
    if not lang_code:
        parts     = voice_name.split("-")
        lang_code = "-".join(parts[:2]) if len(parts) >= 2 else \
            TTS_LANGUAGES.get(TTS_DEFAULT_LANGUAGE, {}).get("code", "bn-IN")

    if status_cb:
        status_cb("TTS: Connecting to Google Cloud TTS…")
    client = _build_tts_client()

    # Split into byte-safe chunks
    chunks = _split_text_into_chunks(text)
    total  = len(chunks)

    _SAMPLE_RATE = 24000
    voice_params = _tts_module.VoiceSelectionParams(
        language_code=lang_code, name=voice_name)
    audio_config = _tts_module.AudioConfig(
        audio_encoding=_tts_module.AudioEncoding.LINEAR16,
        sample_rate_hertz=_SAMPLE_RATE)

    out_base         = os.path.splitext(output_path)[0]
    chunk_log_path   = out_base + "_chunks.txt"
    chunk_log_lines  = [
        f"TTS Chunk Log — {os.path.basename(output_path)}",
        f"Platform : Google Cloud TTS",
        f"Voice    : {voice_name}  ({lang_code})",
        f"Total chunks: {total}",
        "",
    ]

    chunk_pcm_list = []
    for i, chunk in enumerate(chunks, 1):
        if status_cb:
            if total > 1:
                status_cb(f"TTS: Generating audio… chunk {i} of {total}")
            else:
                status_cb("TTS: Generating audio…")

        synthesis_input = _tts_module.SynthesisInput(text=chunk)
        response = client.synthesize_speech(
            input=synthesis_input, voice=voice_params, audio_config=audio_config)
        pcm_bytes = response.audio_content
        chunk_pcm_list.append(pcm_bytes)

        # Save individual chunk as WAV
        chunk_audio_path = f"{out_base}_chunk_{i:02d}.wav"
        with _wave_mod.open(chunk_audio_path, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(_SAMPLE_RATE)
            wf.writeframes(pcm_bytes)

        chunk_log_lines += [
            f"=== CHUNK {i} of {total} ===",
            f"Characters : {len(chunk)}",
            f"Bytes (UTF-8): {len(chunk.encode('utf-8'))}",
            f"Audio saved : {os.path.basename(chunk_audio_path)}",
            "--- Text ---",
            chunk,
            "",
        ]

    # Write chunk manifest
    with open(chunk_log_path, "w", encoding="utf-8") as lf:
        lf.write("\n".join(chunk_log_lines))

    if status_cb:
        chunk_note = f" ({total} chunks joined)" if total > 1 else ""
        status_cb(f"TTS: Saving → {os.path.basename(output_path)}…{chunk_note}")

    # Concatenate all PCM chunks and write single WAV
    all_pcm = b"".join(chunk_pcm_list)
    with _wave_mod.open(output_path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(_SAMPLE_RATE)
        wf.writeframes(all_pcm)

    return output_path


def _split_text_for_elevenlabs(text: str,
                               max_chars: int = ELEVENLABS_CHUNK_CHARS) -> list:
    """
    Split text into chunks of at most max_chars characters.

    Strategy (in priority order):
      1. Accumulate consecutive paragraphs into one chunk as long as the total
         stays under max_chars.  Blank lines between paragraphs are ignored —
         they are NOT flush points.  This prevents tiny single-paragraph chunks.
      2. If a single paragraph exceeds max_chars, split it at sentence boundaries.
      3. If a sentence exceeds max_chars, split it at word boundaries.
    """
    if len(text) <= max_chars:
        return [text]

    def _fits(s: str) -> bool:
        return len(s) <= max_chars

    def _split_para(para: str) -> list:
        pieces, current = [], ""
        for sent in re.split(r'(?<=[.!?।])\s+', para):
            if not sent:
                continue
            candidate = (current + " " + sent).strip() if current else sent
            if _fits(candidate):
                current = candidate
            else:
                if current:
                    pieces.append(current)
                if _fits(sent):
                    current = sent
                else:
                    # Split at word boundaries
                    current = ""
                    for word in sent.split():
                        candidate = (current + " " + word).strip() if current else word
                        if _fits(candidate):
                            current = candidate
                        else:
                            if current:
                                pieces.append(current)
                            current = word
        if current:
            pieces.append(current)
        return pieces

    # Walk paragraph by paragraph.  Blank lines are skipped — they are NOT
    # treated as chunk boundaries.  Paragraphs keep accumulating into `current`
    # until adding the next one would exceed max_chars.  This ensures that
    # several short paragraphs are joined into a single chunk rather than each
    # being sent as a separate (tiny) API call.
    chunks, current = [], ""
    for para in text.split("\n"):
        if not para.strip():
            continue                    # skip blank lines — don't flush here
        candidate = (current + "\n" + para).strip() if current else para
        if _fits(candidate):
            current = candidate         # still under limit — keep accumulating
        else:
            if current:
                chunks.append(current)  # flush what we have
            if _fits(para):
                current = para          # start fresh with this paragraph
            else:
                sub = _split_para(para) # paragraph itself is too long — split it
                chunks.extend(sub[:-1])
                current = sub[-1] if sub else ""
    if current:
        chunks.append(current)
    chunks = chunks if chunks else [text]

    # Safety: never split inside an ElevenLabs v3 tag like "[bengali accent]"
    # or "[calm]". If a chunk ends with an unclosed "[" (more "[" than "]"),
    # peel the trailing fragment off and prepend it to the next chunk so the
    # tag stays intact when sent to ElevenLabs.
    if len(chunks) > 1:
        fixed = []
        for idx, ch in enumerate(chunks):
            if idx < len(chunks) - 1 and ch.count("[") > ch.count("]"):
                cut = ch.rfind("[")
                if cut > 0:
                    head, tail = ch[:cut].rstrip(), ch[cut:]
                    fixed.append(head)
                    chunks[idx + 1] = tail + " " + chunks[idx + 1].lstrip()
                    continue
            fixed.append(ch)
        chunks = fixed

    return chunks


# ─── Multi-speaker voice map (read-only detection helpers) ──────────────────
# Per-project map of paragraph-index → ElevenLabs voice, saved by the bulk
# app next to the other pipeline outputs as <base>_speakers.json. The engine
# only DETECTS such a map to warn that multi-speaker dubbing is unsupported
# — multi-speaker synthesis itself is out of scope (see module header).

def _speakers_file_path(base: str) -> str:
    return base + "_speakers.json"


def _speakers_load(base: str) -> dict:
    try:
        with open(_speakers_file_path(base), "r", encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _speakers_voice_map(base: str) -> Dict[int, str]:
    """{paragraph_index: voice_id} for every valid saved assignment."""
    out: Dict[int, str] = {}
    for k, v in (_speakers_load(base).get("assignments") or {}).items():
        try:
            idx = int(k)
        except Exception:
            continue
        vid = _sanitize_voice_id((v or {}).get("voice_id", ""))
        if vid:
            out[idx] = vid
    return out


# Sentence terminators: ASCII . ! ? …  plus Indic danda । and double-danda ॥
_SENTENCE_END_RE = re.compile(r'(?<=[.!?…।॥])\s+')
_ONLY_TAGS_RE    = re.compile(r'(?:\[[^\]]+\]\s*)+$')


def _split_script_into_sentences(text: str) -> List[str]:
    """
    Split a script into sentence-level segments for per-sentence TTS.
    Blank lines are hard paragraph breaks; single newlines inside a paragraph
    are treated as spaces. Inline emotion tags ([calm], [pause]…) that stand
    alone stay attached to the sentence that follows them.
    """
    sentences = []
    for para in re.split(r'\n\s*\n', text):
        para = re.sub(r'\s*\n\s*', ' ', para.strip())
        if not para:
            continue
        parts = [p.strip() for p in _SENTENCE_END_RE.split(para) if p.strip()]
        carry = ""
        for p in parts:
            if carry:
                p = carry + " " + p
                carry = ""
            if _ONLY_TAGS_RE.fullmatch(p):
                carry = p          # tag-only fragment → prefix of next sentence
                continue
            sentences.append(p)
        if carry:                  # trailing tag-only fragment
            if sentences:
                sentences[-1] += " " + carry
            else:
                sentences.append(carry)
    return sentences


# ─── v0.12 clause-level units ────────────────────────────────────────────────
# Sentence boundaries alone are too coarse for these scripts: Indic
# translations chain clauses with ";", "," and dashes, so one "sentence" can
# run 15 seconds and land on the timeline as a block — the "chunks are too
# big" report. The pre-v0.7 pipeline cut wherever the TTS audio went quiet
# (80 ms at -42 dB), which is exactly where those marks are read, hence its
# 350 small pieces. We reproduce that granularity from the TEXT instead, using
# the boundary hierarchy the Auto Sync matcher prompt already documents:
# paragraph → . ? ! → ; : → , → dash.
# 60 chars ≈ 4 s at the ~14.3 chars/s these voices average. Measured on a
# real 3.4k-char Telugu script: 90 → 66 pieces (worst 7.4 s), 60 → ~85
# pieces (worst 5.7 s), and below ~55 nothing improves because the clause
# marks run out. The old silence-cut pipeline averaged ~1.8 s per piece, so
# this lands in the same neighbourhood without ever cutting mid-phrase.
CLAUSE_MAX_CHARS = 60     # longer units get subdivided at clause marks
CLAUSE_MIN_CHARS = 18     # shorter fragments are merged back into a neighbour

_CLAUSE_PATTERNS = (
    r'(?<=[;:])\s+',          # strongest: semicolon / colon
    r'(?<=,)\s+',             # then comma
    r'(?<=[-–—])\s+',         # then a dash that ends a phrase
)


def _merge_tiny_units(units: List[str], min_chars: int) -> List[str]:
    """Fold sub-threshold fragments into their neighbour.

    A stray "సరేనా?" on its own is a worse timeline piece than a slightly
    long neighbour: it desyncs easily and clutters the Un sync track."""
    out: List[str] = []
    for u in units:
        if out and len(u) < min_chars:
            out[-1] = out[-1] + " " + u
        else:
            out.append(u)
    # A tiny FIRST unit has no left neighbour — push it onto the second.
    if len(out) > 1 and len(out[0]) < min_chars:
        out[1] = out[0] + " " + out[1]
        out.pop(0)
    return out


def _subdivide_unit(s: str, max_chars: int) -> List[str]:
    """Split *s* at the strongest available clause mark until every part fits.

    Punctuation stays attached to the LEFT part and only whitespace is
    consumed, so joining the parts back with a single space reproduces the
    original text — that is what keeps the TTS request (and its prosody)
    identical to speaking the sentence whole."""
    if len(s) <= max_chars:
        return [s]
    for pat in _CLAUSE_PATTERNS:
        parts = [p.strip() for p in re.split(pat, s) if p.strip()]
        if len(parts) > 1:
            out: List[str] = []
            for p in parts:
                out.extend(_subdivide_unit(p, max_chars))
            return out
    return [s]          # no clause mark to cut at — keep it whole


def _split_script_into_units(text: str, max_chars: int = CLAUSE_MAX_CHARS,
                             min_chars: int = CLAUSE_MIN_CHARS) -> List[str]:
    """Script → timeline-sized units: sentences, long ones cut at clauses.

    max_chars <= 0 (or huge) disables subdivision, giving plain sentences."""
    units: List[str] = []
    for sent in _split_script_into_sentences(text):
        if max_chars and max_chars > 0:
            units.extend(_subdivide_unit(sent, max_chars))
        else:
            units.append(sent)
    return _merge_tiny_units(units, min_chars) if min_chars > 0 else units


def _elevenlabs_tts_post(chunk: str, api_key: str, voice_id: str, model_id: str,
                         previous_text: str = None, next_text: str = None) -> bytes:
    """
    Single ElevenLabs text-to-speech request → raw MP3 bytes.

    previous_text / next_text enable request-stitching: when synthesizing one
    sentence in isolation the surrounding script is sent as context so prosody
    matches the neighbouring segments. Models that reject those fields get one
    automatic retry without them.
    """
    body = {
        "text": chunk,
        "model_id": model_id,
        "voice_settings": {
            "stability": 0.35,
            "similarity_boost": 0.80,
            "style": 0.40,
            "use_speaker_boost": True,
        },
    }
    # ElevenLabs caps stitching context; trailing/leading 600 chars is plenty
    # for prosody continuity without bloating the request.
    if previous_text:
        body["previous_text"] = previous_text[-600:]
    if next_text:
        body["next_text"] = next_text[:600]

    payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
    url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}"
    req = urllib.request.Request(
        url, data=payload, method="POST",
        headers={
            "xi-api-key": api_key,
            "Content-Type": "application/json; charset=utf-8",
            "Accept": "audio/mpeg",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=180, context=_SSL_CTX) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        err_body = ""
        try:
            err_body = e.read().decode("utf-8", errors="replace")[:500]
        except Exception:
            pass
        if e.code in (400, 422) and (previous_text or next_text):
            return _elevenlabs_tts_post(chunk, api_key, voice_id, model_id)
        if e.code == 401:
            raise ValueError("ElevenLabs rejected the API key (401). Re-paste a valid key.") from None
        if e.code == 404:
            raise ValueError(
                f"ElevenLabs voice not found (404). voice_id={voice_id!r} "
                "is not on this account. Fetch the voice list again and pick "
                "a voice from it.") from None
        if e.code == 422:
            raise ValueError(
                "ElevenLabs rejected the request (422). "
                f"Voice may not support the target language. Details: {err_body}") from None
        if e.code == 429:
            raise ValueError("ElevenLabs rate limit hit (429). Try again shortly.") from None
        raise ValueError(f"ElevenLabs TTS error (HTTP {e.code}): {err_body}") from None
    except urllib.error.URLError as e:
        raise ValueError(f"Network error during ElevenLabs TTS: {e.reason}") from None


def _output_locked(path: str) -> bool:
    """True when *path* cannot be (over)written.

    On Windows a wav that is loaded in an open REAPER project (or playing
    in a media player) holds a share lock; overwriting it fails with
    PermissionError even though the folder is writable — CPython maps
    ERROR_SHARING_VIOLATION to the same "[Errno 13] Permission denied" a
    real ACL denial gives. A read-only file or a directory squatting on
    the name fails the same way, so all three count as locked here."""
    if os.path.isdir(path):
        return True
    if not os.path.exists(path):
        return False
    try:
        with open(path, "r+b"):
            return False
    except OSError:
        return True


def ensure_writable_output(output_path: str, status_cb=None) -> str:
    """Return *output_path*, or a numbered sibling when it is locked.

    Re-dubbing a file whose previous output is still open in REAPER must
    not crash (and must never crash AFTER the TTS credits are spent), so
    a locked target is diverted to "<name>-2", "<name>-3", … The "_tts" /
    "_synced" suffix is kept in place ("Nepali_(x)-2_tts.wav") because
    the REAPER importer's fallback scan matches on that suffix. Callers
    must use the returned path."""
    if not _output_locked(output_path):
        return output_path
    root, ext = os.path.splitext(output_path)
    stem, suffix = root, ""
    for s in ("_tts", "_synced"):
        if root.endswith(s):
            stem, suffix = root[:-len(s)], s
            break
    for n in range(2, 21):
        candidate = f"{stem}-{n}{suffix}{ext}"
        if not _output_locked(candidate):
            if status_cb:
                status_cb(
                    f"WARNING: {os.path.basename(output_path)} is locked by "
                    "another program (usually still loaded in an open REAPER "
                    "project or a media player) — saving as "
                    f"{os.path.basename(candidate)} instead.")
            return candidate
    raise RuntimeError(
        f"Cannot write {output_path} — the file is locked by another "
        "program (usually the wav is still loaded in an open REAPER "
        "project or a media player). Close it and run again.")


def synthesize_tts_elevenlabs(text: str, output_path: str, api_key: str,
                               voice_id: str = ELEVENLABS_TTS_VOICE_ID,
                               model_id: str = ELEVENLABS_TTS_MODEL,
                               status_cb=None) -> str:
    """
    Convert target-language text to speech using ElevenLabs TTS (eleven_v3
    auto-detects the script) and save to output_path (MP3 decoded to WAV via
    pydub). Sends text in chunks of ~ELEVENLABS_CHUNK_CHARS characters and
    concatenates the resulting audio. Returns output_path.

    Validates inputs up-front so we never POST a broken request:
      • API key non-empty
      • voice_id non-empty (raises a clear error if no voice is loaded)
      • text non-empty (after stripping)
    """
    if not api_key or not api_key.strip():
        raise ValueError("ElevenLabs API key is missing — set "
                         "\"elevenlabs_api_key\" in config/tts_settings.json.")
    if not voice_id or not str(voice_id).strip():
        raise ValueError(
            "No ElevenLabs voice selected. Pass --voice-id or let the engine "
            "auto-resolve one from the account's voice catalogue.")
    if not text or not text.strip():
        raise ValueError("TTS text is empty — nothing to synthesize.")

    api_key  = api_key.strip()
    # Sanitize voice_id BEFORE it ever touches the URL. If a display label
    # (e.g. "✦ Aria — abc12345…") leaks through here, urllib raises
    # "URL can't contain control characters (found at least ' ')".
    raw_voice_id = str(voice_id).strip()
    voice_id = _sanitize_voice_id(raw_voice_id)
    if not voice_id:
        raise ValueError(
            "Invalid ElevenLabs voice_id "
            f"(received: {raw_voice_id!r}). The value must be the raw "
            "voice ID, not a display label.")
    model_id = (model_id or ELEVENLABS_TTS_MODEL).strip() or ELEVENLABS_TTS_MODEL

    # Inline audio tags ([calm], [pause], [fast]…) are an eleven_v3 feature.
    # Older models (multilingual v2, turbo/flash v2.5) would read them aloud,
    # so strip them from the script for anything that isn't v3.
    if not model_id.startswith("eleven_v3"):
        stripped = _strip_emotion_tags(text)
        if stripped.strip():
            text = stripped

    # Probe the output BEFORE the first ElevenLabs call: a locked previous
    # wav (open REAPER project / media player) must divert to a "-2" name
    # here, not crash with Errno 13 after the TTS credits are already spent.
    # The chunk mp3s / chunk log below derive from the resolved name too.
    output_path = ensure_writable_output(output_path, status_cb=status_cb)

    if status_cb:
        status_cb("TTS: Connecting to ElevenLabs…")

    chunks = _split_text_for_elevenlabs(text)
    total  = len(chunks)

    out_base        = os.path.splitext(output_path)[0]
    chunk_log_path  = out_base + "_chunks.txt"
    chunk_log_lines = [
        f"TTS Chunk Log — {os.path.basename(output_path)}",
        f"Platform : ElevenLabs",
        f"Voice ID : {voice_id}",
        f"Model    : {model_id}",
        f"Total chunks: {total}",
        "",
    ]

    chunk_bytes_list = []

    for i, chunk in enumerate(chunks, 1):
        if status_cb:
            if total > 1:
                status_cb(f"TTS: ElevenLabs generating audio… chunk {i} of {total}")
            else:
                status_cb("TTS: ElevenLabs generating audio…")

        # Indic-tuned voice settings: slightly higher stability + style 0
        # produce cleaner pronunciation of conjunct consonants and matras
        # across Devanagari / Bengali / Tamil / Telugu / Kannada / Malayalam /
        # Gujarati / Odia / Assamese scripts.
        # NOTE: do NOT send `language_code` — eleven_v3 auto-detects the
        # target language from the input text. Passing language_code triggers
        # HTTP 400 `unsupported_language` on multilingual models.
        # Lower stability + raised style give eleven_v3 room to act on the
        # inline emotion / accent tags injected by Step4 (e.g. [bengali accent],
        # [calm], [slow], [pause]) so delivery feels human and reflective —
        # closer to a wise teacher (Sadhguru-style cadence) than a flat read.
        audio_bytes = _elevenlabs_tts_post(chunk, api_key, voice_id, model_id)
        chunk_bytes_list.append(audio_bytes)

        # Save individual chunk as MP3 (ElevenLabs returns MP3 bytes)
        chunk_audio_path = f"{out_base}_chunk_{i:02d}.mp3"
        with open(chunk_audio_path, "wb") as cf:
            cf.write(audio_bytes)

        # Add entry to chunk log
        chunk_log_lines += [
            f"=== CHUNK {i} of {total} ===",
            f"Characters : {len(chunk)}",
            f"Bytes (UTF-8): {len(chunk.encode('utf-8'))}",
            f"Audio saved : {os.path.basename(chunk_audio_path)}",
            "--- Text ---",
            chunk,
            "",
        ]

    # Write chunk manifest
    with open(chunk_log_path, "w", encoding="utf-8") as lf:
        lf.write("\n".join(chunk_log_lines))

    if status_cb:
        chunk_note = f" ({total} chunks joined)" if total > 1 else ""
        status_cb(f"TTS: Saving → {os.path.basename(output_path)}…{chunk_note}")

    # ElevenLabs returns MP3 — decode with pydub and export as WAV
    try:
        from pydub import AudioSegment
        combined = AudioSegment.empty()
        for raw in chunk_bytes_list:
            seg = AudioSegment.from_file(io.BytesIO(raw), format="mp3")
            combined += seg
        try:
            combined.export(output_path, format="wav")
        except PermissionError:
            # Lock acquired while the chunks were synthesizing (e.g. the
            # user opened the previous wav mid-run). Divert instead of
            # losing the audio the credits already paid for.
            output_path = ensure_writable_output(output_path,
                                                 status_cb=status_cb)
            combined.export(output_path, format="wav")
    except FileNotFoundError:
        # pydub shells out to ffmpeg/ffprobe; a bare WinError 2 here means
        # they are not installed. Fail with the fix instead of a traceback.
        raise RuntimeError(
            "ffmpeg/ffprobe not found — pydub needs it to decode the "
            "ElevenLabs MP3 audio. Re-run the setup script "
            "(setup_windows.bat / setup_mac.command); it installs ffmpeg "
            "automatically. Then run the dub again.")
    except ImportError:
        if status_cb:
            status_cb("TTS: Warning — pydub not found; saving raw MP3 bytes (install pydub for WAV output).")
        with open(output_path, "wb") as f:
            for raw in chunk_bytes_list:
                f.write(raw)

    return output_path


# Silence inserted between sections in the concatenated wav. Spans exclude
# it, so cutting a section out of the wav never clips a neighbour even when
# an item is nudged a few ms in REAPER.
SECTION_GAP_MS = 240


def synthesize_sections_elevenlabs(section_texts, output_path: str,
                                   api_key: str,
                                   voice_id: str = ELEVENLABS_TTS_VOICE_ID,
                                   model_id: str = ELEVENLABS_TTS_MODEL,
                                   status_cb=None):
    """Synthesize *section_texts* one by one into ONE concatenated WAV
    (contract v0.7 match mode). Returns (output_path, spans) where spans is
    one (start_ms, end_ms) pair per section inside the wav, gaps excluded.

    Every section keeps prosody continuity via ElevenLabs request-stitching:
    the neighbouring script text travels as previous_text/next_text context.
    Long sections still go through the ~ELEVENLABS_CHUNK_CHARS splitter.
    Validation, tag stripping for non-v3 models, the locked-output divert
    and the ffmpeg/pydub error paths mirror synthesize_tts_elevenlabs."""
    if not api_key or not api_key.strip():
        raise ValueError("ElevenLabs API key is missing — set "
                         "\"elevenlabs_api_key\" in config/tts_settings.json.")
    if not voice_id or not str(voice_id).strip():
        raise ValueError(
            "No ElevenLabs voice selected. Pass --voice-id or let the engine "
            "auto-resolve one from the account's voice catalogue.")
    sections = [(t or "").strip() for t in (section_texts or [])]
    if not sections or any(not t for t in sections):
        raise ValueError("Section list is empty or contains an empty "
                         "section — nothing to synthesize.")

    api_key = api_key.strip()
    raw_voice_id = str(voice_id).strip()
    voice_id = _sanitize_voice_id(raw_voice_id)
    if not voice_id:
        raise ValueError(
            "Invalid ElevenLabs voice_id "
            f"(received: {raw_voice_id!r}). The value must be the raw "
            "voice ID, not a display label.")
    model_id = (model_id or ELEVENLABS_TTS_MODEL).strip() or ELEVENLABS_TTS_MODEL

    if not model_id.startswith("eleven_v3"):
        stripped = [_strip_emotion_tags(t) for t in sections]
        sections = [s.strip() if s.strip() else o
                    for s, o in zip(stripped, sections)]

    output_path = ensure_writable_output(output_path, status_cb=status_cb)

    try:
        from pydub import AudioSegment
    except ImportError:
        raise RuntimeError(
            "pydub not installed — the sectioned TTS mode needs it to "
            "assemble the per-section audio. Re-run the setup script.")

    out_base = os.path.splitext(output_path)[0]
    log_lines = [
        f"TTS Section Log — {os.path.basename(output_path)}",
        "Platform : ElevenLabs (sectioned, request-stitched)",
        f"Voice ID : {voice_id}",
        f"Model    : {model_id}",
        f"Sections : {len(sections)}",
        f"Gap      : {SECTION_GAP_MS}ms between sections (spans exclude it)",
        "",
    ]

    seg_list = []
    total = len(sections)
    for i, text in enumerate(sections):
        if status_cb:
            status_cb(f"TTS: section {i + 1} of {total} "
                      f"({len(text)} chars)…")
        prev_ctx = sections[i - 1] if i > 0 else None
        next_ctx = sections[i + 1] if i + 1 < total else None
        sec_bytes = []
        subchunks = _split_text_for_elevenlabs(text)
        for k, sub in enumerate(subchunks):
            # Stitching context: everything before/after THIS subchunk, so
            # multi-subchunk sections stay continuous internally too.
            p = " ".join(filter(None, [prev_ctx] + subchunks[:k])) or None
            n = " ".join(filter(None, subchunks[k + 1:] + [next_ctx])) or None
            sec_bytes.append(_elevenlabs_tts_post(
                sub, api_key, voice_id, model_id,
                previous_text=p, next_text=n))
        raw = b"".join(sec_bytes)
        with open(f"{out_base}_sec_{i + 1:03d}.mp3", "wb") as sf:
            sf.write(raw)
        try:
            seg = AudioSegment.empty()
            for rb in sec_bytes:
                seg += AudioSegment.from_file(io.BytesIO(rb), format="mp3")
        except FileNotFoundError:
            raise RuntimeError(
                "ffmpeg/ffprobe not found — pydub needs it to decode the "
                "ElevenLabs MP3 audio. Re-run the setup script "
                "(setup_windows.bat / setup_mac.command); it installs "
                "ffmpeg automatically. Then run the dub again.")
        seg_list.append(seg)
        log_lines += [
            f"=== SECTION {i + 1} of {total} ===",
            f"Characters : {len(text)}",
            f"Duration   : {len(seg)}ms",
            f"Audio saved: {os.path.basename(out_base)}_sec_{i + 1:03d}.mp3",
            "--- Text ---",
            text,
            "",
        ]

    frame_rate = seg_list[0].frame_rate
    gap = AudioSegment.silent(duration=SECTION_GAP_MS, frame_rate=frame_rate)
    combined = AudioSegment.empty()
    spans = []
    cursor = 0
    for i, seg in enumerate(seg_list):
        if i > 0:
            combined += gap
            cursor += len(gap)
        start = cursor
        combined += seg
        cursor += len(seg)
        spans.append((start, cursor))

    with open(out_base + "_chunks.txt", "w", encoding="utf-8") as lf:
        lf.write("\n".join(log_lines))

    if status_cb:
        status_cb(f"TTS: Saving → {os.path.basename(output_path)}… "
                  f"({total} sections)")
    try:
        combined.export(output_path, format="wav")
    except PermissionError:
        output_path = ensure_writable_output(output_path,
                                             status_cb=status_cb)
        combined.export(output_path, format="wav")

    return output_path, spans


# ─── v0.8 sentence-timed synthesis ───────────────────────────────────────────
# One long request speaks many sentences with natural flow; the
# /with-timestamps variant of the endpoint returns, alongside the audio, the
# exact second every CHARACTER was spoken. Knowing where each sentence starts
# and ends in the text we sent, we read its start/end seconds straight off
# that table — so the wav can be cut into per-sentence pieces without ever
# re-transcribing it and without per-sentence requests.

def _elevenlabs_tts_post_ts(chunk: str, api_key: str, voice_id: str,
                            model_id: str, previous_text: str = None,
                            next_text: str = None):
    """One /with-timestamps request → (mp3 bytes, characters, start_s, end_s).

    The JSON body mirrors _elevenlabs_tts_post (same voice settings, same
    stitching fields, same error mapping). `alignment` — the table for the
    ORIGINAL text as sent — is used, never `normalized_alignment`: our
    sentence offsets are indices into the text we sent, and normalization
    rewrites numbers etc., shifting every index after it."""
    body = {
        "text": chunk,
        "model_id": model_id,
        "voice_settings": {
            "stability": 0.35,
            "similarity_boost": 0.80,
            "style": 0.40,
            "use_speaker_boost": True,
        },
    }
    if previous_text:
        body["previous_text"] = previous_text[-600:]
    if next_text:
        body["next_text"] = next_text[:600]

    payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
    url = (f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}"
           "/with-timestamps")
    req = urllib.request.Request(
        url, data=payload, method="POST",
        headers={
            "xi-api-key": api_key,
            "Content-Type": "application/json; charset=utf-8",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=300, context=_SSL_CTX) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        err_body = ""
        try:
            err_body = e.read().decode("utf-8", errors="replace")[:500]
        except Exception:
            pass
        if e.code in (400, 422) and (previous_text or next_text):
            return _elevenlabs_tts_post_ts(chunk, api_key, voice_id, model_id)
        if e.code == 401:
            raise ValueError("ElevenLabs rejected the API key (401). "
                             "Re-paste a valid key.") from None
        if e.code == 404:
            raise ValueError(
                f"ElevenLabs voice not found (404). voice_id={voice_id!r} "
                "is not on this account. Fetch the voice list again and "
                "pick a voice from it.") from None
        if e.code == 429:
            raise ValueError("ElevenLabs rate limit hit (429). "
                             "Try again shortly.") from None
        raise ValueError(
            f"ElevenLabs TTS error (HTTP {e.code}): {err_body}") from None
    except urllib.error.URLError as e:
        raise ValueError(
            f"Network error during ElevenLabs TTS: {e.reason}") from None

    audio = base64.b64decode(data.get("audio_base64") or "")
    align = data.get("alignment") or {}
    chars = align.get("characters") or []
    starts = align.get("character_start_times_seconds") or []
    ends = align.get("character_end_times_seconds") or []
    if not audio:
        raise ValueError("ElevenLabs returned no audio for a timed request.")
    return audio, chars, starts, ends


def _pack_sentences(sentences, max_chars: int):
    """Greedy request packing that NEVER splits inside a sentence.

    Returns a list of lists of sentence indices. A single sentence longer
    than *max_chars* gets a request of its own — the API accepts it (the
    cap here is our packing size, far below the model limit), and keeping
    it whole preserves the sentence == piece rule."""
    groups, cur, cur_len = [], [], 0
    for i, s in enumerate(sentences):
        n = len(s)
        extra = n if not cur else n + 1          # +1 for the joining space
        if cur and cur_len + extra > max_chars:
            groups.append(cur)
            cur, cur_len = [], 0
        cur.append(i)
        cur_len += n if cur_len == 0 else n + 1
    if cur:
        groups.append(cur)
    return groups


def _sentence_spans_from_alignment(text, offsets, chars, starts, ends):
    """Per-sentence (start_s, end_s) inside one request's audio.

    *offsets* is [(char_start, char_end)] of each sentence in *text* (the
    exact string sent). The alignment lists run parallel to the text; when
    their length differs (a defensive case — the API echoes the original
    text, but never trust a length) the lookup is clamped, and a span with
    no timed characters falls back to a proportional estimate over the
    request's total duration."""
    total = ends[-1] if ends else 0.0
    n = min(len(chars), len(starts), len(ends), len(text))
    spans = []
    for (a, b) in offsets:
        a2, b2 = min(a, n), min(b, n)
        first = last = None
        for k in range(a2, b2):
            if not (text[k].isspace()):
                if first is None:
                    first = k
                last = k
        if first is None or first >= n:
            # Nothing timed (all-whitespace or clamped away): estimate.
            frac_a = a / max(1, len(text))
            frac_b = b / max(1, len(text))
            spans.append((total * frac_a, total * frac_b))
        else:
            last = min(last, n - 1)
            spans.append((starts[first], ends[last]))
    return spans


def synthesize_sentences_elevenlabs(sentences, output_path: str,
                                    api_key: str,
                                    voice_id: str = ELEVENLABS_TTS_VOICE_ID,
                                    model_id: str = ELEVENLABS_TTS_MODEL,
                                    status_cb=None):
    """v0.8: speak *sentences* in long natural stretches and return
    (output_path, spans) with ONE (start_ms, end_ms) pair PER SENTENCE
    inside the combined wav.

    Sentences are packed into requests at sentence boundaries only
    (~ELEVENLABS_CHUNK_CHARS per request), each request goes to the
    /with-timestamps endpoint, and per-sentence spans are read from the
    returned character table — no re-transcription, no per-sentence calls.
    Neighbouring script text rides along as previous_text/next_text so
    prosody survives the few request boundaries. Validation, tag stripping
    for non-v3 models, and the locked-output divert mirror the other
    synthesizers."""
    if not api_key or not api_key.strip():
        raise ValueError("ElevenLabs API key is missing — set "
                         "\"elevenlabs_api_key\" in config/tts_settings.json.")
    if not voice_id or not str(voice_id).strip():
        raise ValueError(
            "No ElevenLabs voice selected. Pass --voice-id or let the engine "
            "auto-resolve one from the account's voice catalogue.")
    sentences = [(t or "").strip() for t in (sentences or [])]
    if not sentences or any(not t for t in sentences):
        raise ValueError("Sentence list is empty or contains an empty "
                         "sentence — nothing to synthesize.")

    api_key = api_key.strip()
    raw_voice_id = str(voice_id).strip()
    voice_id = _sanitize_voice_id(raw_voice_id)
    if not voice_id:
        raise ValueError(
            "Invalid ElevenLabs voice_id "
            f"(received: {raw_voice_id!r}). The value must be the raw "
            "voice ID, not a display label.")
    model_id = (model_id or ELEVENLABS_TTS_MODEL).strip() or ELEVENLABS_TTS_MODEL

    if not model_id.startswith("eleven_v3"):
        stripped = [_strip_emotion_tags(t) for t in sentences]
        sentences = [s.strip() if s.strip() else o
                     for s, o in zip(stripped, sentences)]

    output_path = ensure_writable_output(output_path, status_cb=status_cb)

    try:
        from pydub import AudioSegment
    except ImportError:
        raise RuntimeError(
            "pydub not installed — the sentence-timed TTS mode needs it to "
            "assemble the audio. Re-run the setup script.")

    groups = _pack_sentences(sentences, ELEVENLABS_CHUNK_CHARS)
    out_base = os.path.splitext(output_path)[0]
    log_lines = [
        f"TTS Sentence Log — {os.path.basename(output_path)}",
        "Platform : ElevenLabs (/with-timestamps, sentence-timed)",
        f"Voice ID : {voice_id}",
        f"Model    : {model_id}",
        f"Sentences: {len(sentences)} in {len(groups)} request(s)",
        f"Gap      : {SECTION_GAP_MS}ms between requests (spans exclude it)",
        "",
    ]

    combined = AudioSegment.empty()
    gap = None
    spans = [None] * len(sentences)
    cursor = 0

    for gi, group in enumerate(groups):
        text = " ".join(sentences[i] for i in group)
        offsets, pos = [], 0
        for i in group:
            s = sentences[i]
            a = text.index(s, pos)
            offsets.append((a, a + len(s)))
            pos = a + len(s)

        prev_ctx = sentences[group[0] - 1] if group[0] > 0 else None
        nxt_i = group[-1] + 1
        next_ctx = sentences[nxt_i] if nxt_i < len(sentences) else None

        if status_cb:
            status_cb(f"TTS: stretch {gi + 1} of {len(groups)} "
                      f"({len(group)} sentence(s), {len(text)} chars)…")
        audio, chars, starts, ends = _elevenlabs_tts_post_ts(
            text, api_key, voice_id, model_id,
            previous_text=prev_ctx, next_text=next_ctx)
        with open(f"{out_base}_str_{gi + 1:03d}.mp3", "wb") as sf:
            sf.write(audio)
        try:
            seg = AudioSegment.from_file(io.BytesIO(audio), format="mp3")
        except FileNotFoundError:
            raise RuntimeError(
                "ffmpeg/ffprobe not found — pydub needs it to decode the "
                "ElevenLabs MP3 audio. Re-run the setup script "
                "(setup_windows.bat / setup_mac.command). Then run the dub "
                "again.")

        if not chars:
            if status_cb:
                status_cb("TTS: WARNING — no character timings in the reply; "
                          "estimating sentence boundaries proportionally for "
                          "this stretch.")
        rel = _sentence_spans_from_alignment(text, offsets, chars, starts,
                                             ends)
        # Clamp to the decoded audio, then stamp absolute positions.
        seg_ms = len(seg)
        if gi > 0:
            if gap is None:
                gap = AudioSegment.silent(duration=SECTION_GAP_MS,
                                          frame_rate=seg.frame_rate)
            combined += gap
            cursor += SECTION_GAP_MS
        for (i, (rs, re_)) in zip(group, rel):
            s_ms = max(0, min(seg_ms, int(round(rs * 1000))))
            e_ms = max(s_ms, min(seg_ms, int(round(re_ * 1000))))
            if e_ms == s_ms:
                e_ms = min(seg_ms, s_ms + 1)
            spans[i] = (cursor + s_ms, cursor + e_ms)
        # The last sentence of a stretch keeps the audio tail (breath /
        # reverb after the final word) so cutting at its span end never
        # clips the decay.
        li = group[-1]
        spans[li] = (spans[li][0], cursor + seg_ms)
        combined += seg
        cursor += seg_ms

        log_lines += [f"=== STRETCH {gi + 1} of {len(groups)} ===",
                      f"Sentences  : {[i + 1 for i in group]}",
                      f"Characters : {len(text)}",
                      f"Duration   : {seg_ms}ms",
                      f"Timed chars: {len(chars)}", ""]
        for k, i in enumerate(group):
            log_lines += [f"  [{i + 1}] {spans[i][0]}ms-{spans[i][1]}ms  "
                          + " ".join(sentences[i].split())[:80]]
        log_lines.append("")

    with open(out_base + "_chunks.txt", "w", encoding="utf-8") as lf:
        lf.write("\n".join(log_lines))

    if status_cb:
        status_cb(f"TTS: Saving → {os.path.basename(output_path)}… "
                  f"({len(sentences)} sentence pieces)")
    try:
        combined.export(output_path, format="wav")
    except PermissionError:
        output_path = ensure_writable_output(output_path,
                                             status_cb=status_cb)
        combined.export(output_path, format="wav")

    return output_path, spans


# ─── ElevenLabs Speech-to-Speech (voice changer) ────────────────────────────
# NEW in v0.4 (not extracted from the bulk app): convert an existing voice
# recording to a different ElevenLabs voice while keeping timing, pacing and
# intonation — used by the panel's "Change track voice" feature on a rendered
# REAPER track.

ELEVENLABS_STS_MODEL = "eleven_multilingual_sts_v2"

# The ElevenLabs voice changer accepts ~5 minutes of audio per request.
# Stay well under it and split long inputs at the quietest point near the
# boundary so we never cut mid-word.
_STS_CHUNK_MS = 4 * 60 * 1000     # 4-minute target chunk length
_STS_SEARCH_MS = 20 * 1000        # look back this far for a quiet split point
_STS_PROBE_MS = 100               # RMS probe window


def _quietest_split_ms(seg, target_ms: int) -> int:
    """Quietest probe position in (target-search, target] — a natural pause
    to split at. Falls back to target_ms itself."""
    start = max(0, target_ms - _STS_SEARCH_MS)
    best_pos, best_rms = target_ms, None
    pos = start
    while pos + _STS_PROBE_MS <= target_ms:
        rms = seg[pos:pos + _STS_PROBE_MS].rms
        if best_rms is None or rms < best_rms:
            best_pos, best_rms = pos, rms
        pos += _STS_PROBE_MS
    return best_pos


def _split_audio_for_sts(seg) -> list:
    """Split a pydub AudioSegment into ≤ ~4-minute pieces at quiet points."""
    pieces = []
    remaining = seg
    while len(remaining) > _STS_CHUNK_MS:
        cut = _quietest_split_ms(remaining, _STS_CHUNK_MS)
        if cut <= 0:
            cut = _STS_CHUNK_MS
        pieces.append(remaining[:cut])
        remaining = remaining[cut:]
    if len(remaining) > 0:
        pieces.append(remaining)
    return pieces or [seg]


def _elevenlabs_sts_post(audio_bytes: bytes, api_key: str, voice_id: str,
                         model_id: str) -> bytes:
    """One ElevenLabs speech-to-speech request (multipart) → raw MP3 bytes."""
    boundary = "----ReaperDubSTS" + uuid.uuid4().hex
    fields = {"model_id": model_id,
              # Keep the source performance: timing/emotion come from the
              # input audio, the timbre from the target voice.
              "voice_settings": json.dumps({"stability": 0.5,
                                            "similarity_boost": 0.8,
                                            "use_speaker_boost": True})}
    body = io.BytesIO()
    for name, value in fields.items():
        body.write(f"--{boundary}\r\n".encode())
        body.write(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
                   .encode())
        body.write(value.encode("utf-8"))
        body.write(b"\r\n")
    body.write(f"--{boundary}\r\n".encode())
    body.write(b'Content-Disposition: form-data; name="audio"; '
               b'filename="audio.mp3"\r\n')
    body.write(b"Content-Type: audio/mpeg\r\n\r\n")
    body.write(audio_bytes)
    body.write(f"\r\n--{boundary}--\r\n".encode())

    # No output_format override: the default (mp3_44100_128) is available
    # on every ElevenLabs tier; higher bitrates are plan-gated.
    url = f"https://api.elevenlabs.io/v1/speech-to-speech/{voice_id}"
    req = urllib.request.Request(
        url, data=body.getvalue(), method="POST",
        headers={
            "xi-api-key": api_key,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Accept": "audio/mpeg",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=600, context=_SSL_CTX) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        err_body = ""
        try:
            err_body = e.read().decode("utf-8", errors="replace")[:500]
        except Exception:
            pass
        if e.code == 401:
            raise ValueError("ElevenLabs rejected the API key (401). "
                             "Re-paste a valid key.") from None
        if e.code == 404:
            raise ValueError(
                f"ElevenLabs voice not found (404). voice_id={voice_id!r} "
                "is not on this account. Fetch the voice list again and pick "
                "a voice from it.") from None
        if e.code == 429:
            raise ValueError("ElevenLabs rate limit hit (429). "
                             "Try again shortly.") from None
        raise ValueError(
            f"ElevenLabs voice-change error (HTTP {e.code}): {err_body}"
        ) from None
    except urllib.error.URLError as e:
        raise ValueError(
            f"Network error during ElevenLabs voice change: {e.reason}"
        ) from None


def voice_change_elevenlabs(input_path: str, output_path: str, api_key: str,
                            voice_id: str,
                            model_id: str = ELEVENLABS_STS_MODEL,
                            status_cb=None) -> str:
    """
    Re-voice *input_path* with the ElevenLabs voice changer (speech-to-speech)
    and save the result as WAV to *output_path*. Long inputs are split into
    ≤ ~4-minute chunks at quiet points and the converted pieces are joined.
    Returns output_path.
    """
    if not api_key or not api_key.strip():
        raise ValueError("ElevenLabs API key is missing — set "
                         "\"elevenlabs_api_key\" in config/tts_settings.json.")
    raw_voice_id = str(voice_id or "").strip()
    voice_id = _sanitize_voice_id(raw_voice_id)
    if not voice_id:
        raise ValueError(
            "Invalid ElevenLabs voice_id for voice change "
            f"(received: {raw_voice_id!r}). Pick a voice from the fetched "
            "list or paste the raw voice ID.")
    if not os.path.isfile(input_path):
        raise ValueError(f"Voice-change input audio not found: {input_path}")
    if not PYDUB_AVAILABLE:
        raise ImportError(
            "pydub is required for voice change (audio chunking + WAV "
            "export). Run the setup script to install the engine "
            "dependencies, and make sure ffmpeg is installed.")
    api_key = api_key.strip()
    model_id = (model_id or ELEVENLABS_STS_MODEL).strip() or ELEVENLABS_STS_MODEL

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
                  f"{total} chunk(s), voice {voice_id}, model {model_id}.")

    out_parent = os.path.dirname(os.path.abspath(output_path))
    if out_parent:
        os.makedirs(out_parent, exist_ok=True)

    converted = []
    for i, piece in enumerate(pieces, 1):
        if status_cb:
            status_cb(f"Voice change: converting chunk {i} of {total} "
                      f"({len(piece)/1000.0:.0f}s)…")
        buf = io.BytesIO()
        piece.export(buf, format="mp3", bitrate="192k")
        audio_bytes = _elevenlabs_sts_post(buf.getvalue(), api_key,
                                           voice_id, model_id)
        converted.append(_AudioSegment.from_file(io.BytesIO(audio_bytes),
                                                 format="mp3"))

    if status_cb:
        status_cb(f"Voice change: saving → {os.path.basename(output_path)}…")
    combined = converted[0]
    for piece in converted[1:]:
        combined += piece
    combined.export(output_path, format="wav")
    return output_path
