"""
One place that decides which voice provider speaks (v0.15.8).

The engine used to call the ElevenLabs functions by name. It now asks
voice_backend() once per run and calls the returned object instead, so
every mode — full / dub runs, chunk redo, Text to Speech, track voice
change, voice list, voice test — follows the same Settings choice.

Choice order: --tts-provider on the command line (the panel always sends
what its Settings show) > "tts_provider" in config/tts_settings.json >
ElevenLabs. Transcription (Scribe) is NOT part of this: it stays on
ElevenLabs whatever is chosen here.
"""

import types

from .config import (CARTESIA_TTS_MODEL, ELEVENLABS_ONE_TAKE_CHARS,
                     ELEVENLABS_TTS_MODEL,
                     TTS_PROVIDER_CARTESIA, TTS_PROVIDER_ELEVENLABS,
                     TTS_PROVIDERS, load_tts_settings)
from . import stt as _stt
from . import tts as _tts
from . import tts_cartesia as _ca


def tts_provider(cli_value: str = None) -> str:
    """'elevenlabs' or 'cartesia' — CLI wins, then the settings file."""
    v = (cli_value or "").strip().lower()
    if v not in TTS_PROVIDERS:
        v = str(load_tts_settings().get("tts_provider") or "").strip().lower()
    return v if v in TTS_PROVIDERS else TTS_PROVIDER_ELEVENLABS


def voice_backend(provider: str = None, el_model: str = None,
                  ca_model: str = None, sts_model: str = None,
                  need_key: bool = True):
    """Namespace with the active provider's key, model and functions.

    Every function takes the same arguments whichever provider is behind it:
      whole(text, out_wav, voice_id, language, status_cb, max_chars=None)
      sections(texts, out_wav, voice_id, language, status_cb) -> (wav, spans)
      sentences(texts, out_wav, voice_id, language, status_cb) -> (wav, spans)
      voice_change(in_wav, out_wav, voice_id, status_cb)
      fetch_voices(language, force_refresh=False) -> [{voice_id,name,label}]
      sanitize(voice_id) -> clean id or ""
    need_key=False skips the key lookup (selfcheck / banners only)."""
    name = tts_provider(provider)
    vb = types.SimpleNamespace(provider=name)

    if name == TTS_PROVIDER_CARTESIA:
        model = ((ca_model or "").strip()
                 or (load_tts_settings().get("cartesia_model") or "").strip()
                 or CARTESIA_TTS_MODEL)
        key = _ca._get_cartesia_api_key() if need_key else ""
        vb.label, vb.model, vb.key = "Cartesia", model, key
        vb.one_take_chars = _ca.CARTESIA_ONE_TAKE_CHARS
        vb.sanitize = _ca._sanitize_cartesia_voice_id
        vb.whole = lambda text, out, voice_id, language, status_cb, \
            max_chars=None: _ca.synthesize_tts_cartesia(
                text, out, api_key=key, voice_id=voice_id, model_id=model,
                language=language, status_cb=status_cb, max_chars=max_chars)
        vb.sections = lambda texts, out, voice_id, language, status_cb: \
            _ca.synthesize_sections_cartesia(
                texts, out, api_key=key, voice_id=voice_id, model_id=model,
                language=language, status_cb=status_cb)
        vb.sentences = lambda texts, out, voice_id, language, status_cb: \
            _ca.synthesize_sentences_cartesia(
                texts, out, api_key=key, voice_id=voice_id, model_id=model,
                language=language, status_cb=status_cb)
        vb.voice_change = lambda in_wav, out, voice_id, status_cb: \
            _ca.voice_change_cartesia(in_wav, out, api_key=key,
                                      voice_id=voice_id, status_cb=status_cb)
        vb.fetch_voices = lambda language, force_refresh=False: \
            _ca._fetch_cartesia_voices(key, language,
                                       force_refresh=force_refresh)
        return vb

    model = (el_model or "").strip() or ELEVENLABS_TTS_MODEL
    sts = (sts_model or "").strip() or _tts.ELEVENLABS_STS_MODEL
    key = _stt._get_api_key() if need_key else ""
    vb.label, vb.model, vb.key = "ElevenLabs", model, key
    vb.one_take_chars = ELEVENLABS_ONE_TAKE_CHARS
    vb.sanitize = _stt._sanitize_voice_id
    # language is accepted and ignored: eleven_v3 reads it from the script.
    vb.whole = lambda text, out, voice_id, language, status_cb, \
        max_chars=None: _tts.synthesize_tts_elevenlabs(
            text, out, api_key=key, voice_id=voice_id, model_id=model,
            status_cb=status_cb, max_chars=max_chars)
    vb.sections = lambda texts, out, voice_id, language, status_cb: \
        _tts.synthesize_sections_elevenlabs(
            texts, out, api_key=key, voice_id=voice_id, model_id=model,
            status_cb=status_cb)
    vb.sentences = lambda texts, out, voice_id, language, status_cb: \
        _tts.synthesize_sentences_elevenlabs(
            texts, out, api_key=key, voice_id=voice_id, model_id=model,
            status_cb=status_cb)
    vb.voice_change = lambda in_wav, out, voice_id, status_cb: \
        _tts.voice_change_elevenlabs(in_wav, out, api_key=key,
                                     voice_id=voice_id, model_id=sts,
                                     status_cb=status_cb)
    vb.fetch_voices = lambda language, force_refresh=False: \
        _stt._fetch_voices_for_language(key, language,
                                        force_refresh=force_refresh)
    return vb
