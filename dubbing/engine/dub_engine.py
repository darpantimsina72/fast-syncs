#!/usr/bin/env python3
"""
Headless dubbing worker (contract v0.3) — single-voice pipeline with an
optional review pause, standalone chunk regeneration, and settings/voice
utility modes.

STANDALONE as of v0.3: all pipeline logic lives in the local pipeline/
package (extracted from the bulk app's Translation_and_Syncing_App.py —
see each module's provenance header and ENGINE_NOTES.md). The bulk app is
no longer imported and --app-dir is accepted only for backward
compatibility (ignored, with a warning). The stage sequence is unchanged:

    [S1a] ElevenLabs Scribe transcription of the English audio
    [S1b] Region detection + English SRT + analysis format
    [S2a] Translation  (Step1 prompt)   \
    [S2b] Review       (Step2 prompt)    > one _run_gemini_pipeline() call
    [S2c] Punctuation  (Step3 prompt)   /
    [S2d] Step-4 emotion enrichment (default ON) + ElevenLabs TTS (single voice)
    [S3a] English sync SRT (reuses the S1a transcription)
    [S3b] TTS-audio regions + transcription -> target-language SRT
    [S3c] LLM subtitle mapping
    [S3d] Sync algorithm (+ synced SRT + timestamps file)
    [S3e] Synced audio render

Modes (v0.1 + v0.2 modes keep IDENTICAL flags and manifests):
  --steps full        S1a..S3e in one shot (v0.1 behaviour, unchanged).
  --steps translate   S1a..S2c only. Writes the app-convention outputs plus
                      a pair of aligned plain-text paragraph files (English
                      left / translation right, one paragraph per review
                      row, blank-line separated, SAME count and order in
                      both files) and a "status":"review" manifest, then
                      exits 0 so the panel can pause for human review.
  --steps dub         Resume after review. Re-derives out_dir from --audio,
                      validates the translate-stage artifacts, reads the
                      (possibly user-edited) translation from --script,
                      runs emotion (unless --no-emotion) + TTS + S3a..S3e
                      and writes the normal "status":"ok" manifest,
                      overwriting the stale review manifest.
  --regen-chunk       Synthesize ONE chunk text (--text-file, UTF-8; Indic
                      text never travels on argv) with the ElevenLabs
                      helpers into --out-wav. No emotion pass — the chunk
                      text is already final. Manifest:
                      {"status":"ok","regen_wav":"<abs>"}.
  --test-llm          NEW in v0.3. One tiny LLM call on the configured
                      provider. Manifest: {"status":"ok","provider":"…",
                      "model":"…","reply":"…"} (or status error).
  --list-voices       NEW in v0.3 (requires --language). Fetch the account
                      voice catalogue from ElevenLabs, language-token
                      sorted like the app (voices matching the language
                      first). Manifest: {"status":"ok","voices":
                      [{"id","name"},…]} (or status error).

Scope notes (unchanged from v0.1): NO multi-speaker dubbing (a saved
speaker voice map is detected and reported, then ignored), NO translation-
memory WRITES, NO run-history recording. Translation-memory READS (from
this repo's data/translation_memory.db) and Step-4 emotion enrichment
mirror the bulk app's defaults (both ON). Emotion is toggleable:
--no-emotion on the CLI, or {"emotion": false} in engine_settings.json.
All outputs go to the app-convention per-file output folder next to the
input audio (regen output goes wherever --out-wav points, typically
<out_dir>/regen/).

Secrets: read from this repo's gitignored config/ directory only —
config/llm_settings.json + config/tts_settings.json (plus the key files
they point at). Nothing sensitive is passed on argv.

On success AND on failure a result manifest (engine_done.json) is written
to <engine>/status/engine_done.json, and additionally to
<out_dir>/engine_done.json whenever an out_dir is known (regen/test-llm/
list-voices runs have no out_dir of their own, so they write the status
copy only).

Run with --selfcheck to verify the pipeline package imports, every
required symbol exists and every per-language prompt file is present
(no network, no audio processing). A missing config/ settings file is
reported as a WARNING, not a failure.
"""

import argparse
import json
import os
import sys
import traceback
import types

ENGINE_DIR = os.path.dirname(os.path.abspath(__file__))
# DUB_STATUS_DIR is set by run_dub.py when the panel runs with a per-project
# status dir (concurrent runs from two REAPER instances must not share one).
STATUS_DIR = os.environ.get("DUB_STATUS_DIR") or os.path.join(ENGINE_DIR, "status")
ENGINE_SETTINGS_FILE = os.path.join(ENGINE_DIR, "engine_settings.json")

LANGUAGES = ["Bengali", "Hindi", "Kannada", "Malayalam", "Tamil", "Telugu",
             "Gujarati", "Marathi", "Assamese", "Odia", "Nepali"]

# The five per-language prompt stages the pipeline loads from prompts/.
PROMPT_STAGES = ["Step1_Translation_Prompt", "Step2_Review_Prompt",
                 "Step3_Punctuation_Prompt", "Step4_Emotion_Prompt",
                 "SyncingPrompt"]

# Every pipeline symbol this worker relies on, verified by _check_symbols
# (and by --selfcheck). Defined across pipeline/config|stt|srt_tools|llm|
# tts|sync — see ENGINE_NOTES.md for the module map.
REQUIRED_FUNCTIONS = [
    "_prepare_output_dir",           # per-file output folder + audio copy
    "_get_api_key",                  # ElevenLabs key from config/tts_settings.json
    "_validate_llm_config",          # fail fast if the LLM provider is unusable
    "_transcribe_audio",             # ElevenLabs Scribe STT
    "_load_audio_any",               # audio/video -> mono float32 + sr
    "_detect_regions_from_audio",    # waveform speech-region detection
    "_build_subtitle_srt",           # Stage-1 English SRT (for translation)
    "_parse_srt_to_analysis_format", # LLM input format
    "_run_gemini_pipeline",          # Step1 -> Step2 -> Step3 chain
    "_run_emotion_enrichment",       # Step4 emotion tags (best-effort)
    "_extract_srt_entries",          # SRT -> (start, end, text) rows (review pairing)
    "_split_translation_paragraphs", # dub script -> blank-line paragraphs
    "_pair_review_rows",             # EN segments <-> translation paragraphs, aligned
    "_tts_output_name",              # output naming convention
    "_sanitize_voice_id",            # strict ElevenLabs voice_id validation
    "_fetch_voices_for_language",    # account voice catalogue, matches first
    "synthesize_tts_elevenlabs",     # single-voice TTS -> WAV
    "ensure_writable_output",        # locked-output divert (open REAPER project)
    "voice_change_elevenlabs",       # speech-to-speech re-voice (--voice-change)
    "_build_english_subtitle_srt",   # sync-quality English SRT
    "_build_target_subtitle_srt",    # target-language SRT from TTS audio
    "_call_gemini_mapping",          # EN<->target subtitle mapping
    "run_sync_from_strings",         # sync algorithm
    "_write_srt_from_dict",          # synced subs -> SRT text
    "_build_timestamps",             # synced subs -> timestamp entries
    "_format_timestamps_as_text",    # timestamps file format (contract)
    "sync_audio_with_timestamps",    # cut/overlay TTS audio -> synced WAV
    "_llm_generate",                 # provider-agnostic generation (--test-llm)
    "_active_provider_and_model",    # provider/model names (--test-llm manifest)
    "_llm_provider_label",           # provider + credential state (startup banner)
    "request_with_retry",            # network retry with backoff and heartbeat
    "get_audio_duration",            # ffprobe duration probe
]
REQUIRED_ATTRIBUTES = [
    "librosa",                       # used to load TTS audio like the app does
    "GEMINI_DEFAULT_MODEL",
    "TTS_LANGUAGES",
    "PROMPTS_DIR", "LLM_SETTINGS_FILE", "TTS_SETTINGS_FILE",
    "DEFAULT_THR_DB", "DEFAULT_HYS_DB", "DEFAULT_MIN_MS",          # EN regions
    "DEFAULT_BN_THR_DB", "DEFAULT_BN_HYS_DB", "DEFAULT_BN_MIN_MS", # TTS regions
]

# Per-mode manifest key sets (contract v0.1 + v0.2 + v0.3). _write_manifest
# filters by the active set, so stray working keys never leak into the JSON.
MANIFEST_KEYS = ["status", "error", "audio", "language", "out_dir",
                 "en_audio", "en_srt", "tts_wav", "timestamps_txt",
                 "synced_wav", "synced_srt"]
REVIEW_MANIFEST_KEYS = ["status", "error", "audio", "language", "out_dir",
                        "en_srt", "en_text", "translation_text",
                        "final_script"]
REGEN_MANIFEST_KEYS = ["status", "error", "regen_wav"]
TEST_LLM_MANIFEST_KEYS = ["status", "error", "provider", "model", "reply"]
VOICES_MANIFEST_KEYS = ["status", "error", "voices"]
VOICE_CHANGE_MANIFEST_KEYS = ["status", "error", "vc_wav"]

# Stand-in for a review row that has no text on one side (e.g. more
# translation paragraphs than English segments). A visible placeholder keeps
# the blank-line paragraph count identical in both files — an empty string
# would merge two separators and desync the panes.
EMPTY_PARAGRAPH_PLACEHOLDER = "—"


def _parse_args():
    ap = argparse.ArgumentParser(
        description="Headless dubbing worker — normally spawned by "
                    "run_dub.py, which owns log/pid/done markers.")
    ap.add_argument("--app-dir", default=None,
                    help="DEPRECATED (v0.3): accepted for backward "
                         "compatibility and IGNORED — the engine is "
                         "standalone and no longer imports the bulk app")
    ap.add_argument("--audio", default=None,
                    help="Path to the English source audio file")
    ap.add_argument("--language", default=None, choices=LANGUAGES,
                    help="Target language display name")
    ap.add_argument("--voice-id", default=None,
                    help="Optional ElevenLabs voice_id; auto-resolved from "
                         "the account voice catalogue when omitted")
    ap.add_argument("--el-model", default="eleven_v3",
                    help="ElevenLabs TTS model id (default: eleven_v3)")
    ap.add_argument("--steps", default="full",
                    choices=["full", "translate", "dub"],
                    help="Pipeline scope: 'full' = one shot (v0.1), "
                         "'translate' = stop after S2c for script review, "
                         "'dub' = resume from a reviewed script "
                         "(requires --script)")
    ap.add_argument("--script", default=None,
                    help="Reviewed translation text file for --steps dub "
                         "(blank-line paragraph format, as written by the "
                         "translate stage, possibly user-edited)")
    ap.add_argument("--provided-script", dest="provided_script", default=None,
                    help="User-provided translation text file (UTF-8). With "
                         "--steps translate/full the S2a-S2c LLM translation "
                         "chain is SKIPPED and this text is used as the "
                         "translation. Transcription (S1a/S1b) still runs — "
                         "the sync stages need it.")
    ap.add_argument("--voice-change", dest="voice_change",
                    action="store_true",
                    help="Re-voice an existing audio file with the "
                         "ElevenLabs voice changer (speech-to-speech): "
                         "convert --in-wav to the --voice-id voice and "
                         "write --out-wav. No other pipeline stages.")
    ap.add_argument("--in-wav", dest="in_wav", default=None,
                    help="Input audio file for --voice-change")
    ap.add_argument("--sts-model", dest="sts_model",
                    default="eleven_multilingual_sts_v2",
                    help="ElevenLabs speech-to-speech model for "
                         "--voice-change (default: eleven_multilingual_sts_v2)")
    ap.add_argument("--regen-chunk", dest="regen_chunk", action="store_true",
                    help="Regenerate ONE chunk: synthesize the text in "
                         "--text-file with ElevenLabs and write --out-wav. "
                         "No emotion pass, no other pipeline stages.")
    ap.add_argument("--text-file", dest="text_file", default=None,
                    help="UTF-8 chunk text file for --regen-chunk (Indic "
                         "text never travels on argv)")
    ap.add_argument("--out-wav", dest="out_wav", default=None,
                    help="Output WAV path for --regen-chunk")
    ap.add_argument("--emotion", dest="emotion", action="store_true",
                    default=None,
                    help="Run the Step-4 emotion enrichment before TTS "
                         "(default: ON, matching the bulk app; also settable "
                         "via an 'emotion' key in engine_settings.json)")
    ap.add_argument("--no-emotion", dest="emotion", action="store_false",
                    help="Skip Step-4 emotion enrichment (send the bare "
                         "punctuated text to TTS)")
    ap.add_argument("--test-llm", dest="test_llm", action="store_true",
                    help="Make one tiny LLM call on the configured provider "
                         "and write a {status, provider, model, reply} "
                         "manifest. No audio, no TTS.")
    ap.add_argument("--list-voices", dest="list_voices", action="store_true",
                    help="Fetch the ElevenLabs account voice catalogue "
                         "(language-token sorted, requires --language) and "
                         "write a {status, voices:[{id,name},…]} manifest.")
    ap.add_argument("--selfcheck", action="store_true",
                    help="Import the pipeline package, verify every required "
                         "symbol and prompt file exists, print SELFCHECK OK "
                         "and exit. Missing config/ settings files are "
                         "warnings, not failures. No network, no audio "
                         "processing.")
    args = ap.parse_args()

    if args.selfcheck:
        return args
    if args.test_llm:
        if args.regen_chunk or args.list_voices or args.voice_change:
            ap.error("--test-llm cannot be combined with other modes")
        return args
    if args.list_voices:
        if args.regen_chunk or args.voice_change:
            ap.error("--list-voices cannot be combined with other modes")
        if not args.language:
            ap.error("--list-voices requires --language")
        return args
    if args.voice_change:
        if args.regen_chunk:
            ap.error("--voice-change cannot be combined with --regen-chunk")
        if not args.language:
            ap.error("--voice-change requires --language")
        if not args.in_wav:
            ap.error("--voice-change requires --in-wav <input audio path>")
        if not args.out_wav:
            ap.error("--voice-change requires --out-wav <output wav path>")
        if args.script or args.provided_script or args.text_file:
            ap.error("--script/--provided-script/--text-file are not valid "
                     "with --voice-change")
        return args
    if args.regen_chunk:
        if not args.language:
            ap.error("--regen-chunk requires --language")
        if not args.text_file:
            ap.error("--regen-chunk requires --text-file <utf-8 chunk text>")
        if not args.out_wav:
            ap.error("--regen-chunk requires --out-wav <output wav path>")
        if args.script or args.provided_script:
            ap.error("--script/--provided-script are not valid with "
                     "--regen-chunk")
        return args
    if not args.audio or not args.language:
        ap.error("--audio and --language are required unless --selfcheck, "
                 "--test-llm, --list-voices, --voice-change or --regen-chunk")
    if args.steps == "dub" and not args.script:
        ap.error("--steps dub requires --script <translation text file> — "
                 "run '--steps translate' first, review/edit its "
                 "translation_text file, then pass that file here")
    if args.script and args.steps != "dub":
        ap.error("--script is only valid with --steps dub")
    if args.provided_script and args.steps == "dub":
        ap.error("--provided-script is only valid with --steps translate/"
                 "full (--steps dub already takes the script via --script)")
    if args.text_file or args.out_wav or args.in_wav:
        ap.error("--text-file/--out-wav/--in-wav are only valid with "
                 "--regen-chunk / --voice-change")
    return args


def _emotion_enabled(args) -> bool:
    """Step-4 emotion enrichment toggle.

    Priority: --emotion/--no-emotion CLI flag > 'emotion' key in
    engine_settings.json > ON (the bulk app's own default).
    """
    if args.emotion is not None:
        return bool(args.emotion)
    try:
        with open(ENGINE_SETTINGS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and "emotion" in data:
            return bool(data["emotion"])
    except Exception:
        pass
    return True


def _say(tag, msg):
    """Progress line in the contract format: '[Sxx] message'."""
    print(f"[{tag}] {msg}", flush=True)


def _note(msg):
    """Untagged informational log line (does not change the panel stage)."""
    print(f"[engine] {msg}", flush=True)


def _import_pipeline():
    """Import the local pipeline package and return a flat facade namespace.

    All pipeline symbols (functions, constants, module attributes like
    librosa) are aggregated onto one SimpleNamespace so the stage code can
    keep addressing them the way it addressed the app module in v0.1/v0.2
    (pl.<symbol>). Name collisions across modules are shared imports of the
    same objects (e.g. TTS_LANGUAGES), so the aggregation order is safe.
    """
    if ENGINE_DIR not in sys.path:
        sys.path.insert(0, ENGINE_DIR)
    from pipeline import config, net, stt, srt_tools, llm, tts, sync, tm  # noqa: F401
    ns = types.SimpleNamespace()
    for mod in (config, net, stt, srt_tools, llm, tts, sync):
        for name, value in vars(mod).items():
            if name.startswith("__"):
                continue
            setattr(ns, name, value)
    return ns


def _check_symbols(pl):
    """Assert every pipeline symbol this worker calls actually exists."""
    missing = []
    for name in REQUIRED_FUNCTIONS:
        fn = getattr(pl, name, None)
        if fn is None or not callable(fn):
            missing.append(name + " (function)")
    for name in REQUIRED_ATTRIBUTES:
        if getattr(pl, name, None) is None:
            missing.append(name + " (attribute)")
    if missing:
        raise RuntimeError(
            "Pipeline package is missing required symbols: "
            + ", ".join(missing))


def _selfcheck(args) -> int:
    pl = _import_pipeline()
    _check_symbols(pl)

    # Every per-language prompt file must exist (hard failure when missing —
    # prompts ship with the repo, so absence means a broken checkout).
    missing_prompts = []
    for lang in LANGUAGES:
        for stage in PROMPT_STAGES:
            p = os.path.join(pl.PROMPTS_DIR, f"{stage}_{lang}.txt")
            if not os.path.isfile(p):
                missing_prompts.append(f"prompts/{stage}_{lang}.txt")
    if missing_prompts:
        raise RuntimeError(
            f"{len(missing_prompts)} prompt file(s) missing from "
            f"{pl.PROMPTS_DIR}: " + ", ".join(missing_prompts[:10])
            + ("…" if len(missing_prompts) > 10 else ""))

    # Config presence is a WARNING, not a failure: a fresh clone passes
    # selfcheck and the user configures keys afterwards (setup / panel).
    for label, path in (("LLM settings", pl.LLM_SETTINGS_FILE),
                        ("TTS settings", pl.TTS_SETTINGS_FILE)):
        if not os.path.isfile(path):
            print(f"WARNING: {label} file missing: {path} — run "
                  "setup_mac.command or open the REAPER panel's Settings "
                  "section before the first real run.", flush=True)

    print("SELFCHECK OK", flush=True)
    return 0


def _write_manifest(manifest, out_dir, keys=MANIFEST_KEYS):
    """Write engine_done.json to the status dir and (if known) out_dir.

    *keys* selects the mode's manifest shape (full/dub, review, regen,
    test-llm, voices); anything else in *manifest* is a working value and
    is filtered out.
    """
    payload = {k: manifest.get(k, "") for k in keys}
    targets = [os.path.join(STATUS_DIR, "engine_done.json")]
    if out_dir:
        targets.append(os.path.join(out_dir, "engine_done.json"))
    os.makedirs(STATUS_DIR, exist_ok=True)
    for path in targets:
        try:
            with open(path, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False, indent=2)
        except Exception as e:
            _note(f"WARNING: could not write manifest {path}: {e}")


def _write_text(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def _read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def _resolve_voice(pl, api_key, language, cli_voice_id):
    """Return (voice_id, description) for the dub voice.

    Explicit --voice-id wins (after strict sanitizing). Otherwise the
    account's voice catalogue is fetched with the pipeline helper, which
    sorts voices that advertise support for *language* to the top and marks
    them with a leading '✦'. We pick the first language-matched voice;
    if none advertises the language, fall back to the first voice on the
    account (eleven_v3 auto-detects the target language from the text).
    Hard-errors with a clear message when no voice is available.
    """
    if cli_voice_id and cli_voice_id.strip():
        vid = pl._sanitize_voice_id(cli_voice_id)
        if not vid:
            raise RuntimeError(
                f"--voice-id {cli_voice_id!r} is not a valid ElevenLabs "
                "voice_id (expected a 12-40 char alphanumeric token, not a "
                "display label).")
        return vid, "from --voice-id"

    _note(f"No --voice-id given — resolving a {language} voice from the "
          "ElevenLabs account catalogue…")
    try:
        voices = pl._fetch_voices_for_language(api_key, language)
    except Exception as e:
        raise RuntimeError(f"Could not fetch the ElevenLabs voice "
                           f"catalogue: {e}")
    if not voices:
        raise RuntimeError(
            "The ElevenLabs account has no voices — add a voice on "
            "elevenlabs.io or pass --voice-id explicitly.")
    matched = [v for v in voices
               if str(v.get("label", "")).startswith("✦")]
    if matched:
        pick = matched[0]
        return pick["voice_id"], (f"auto: first {language}-matched voice "
                                  f"'{pick['name']}'")
    pick = voices[0]
    _note(f"WARNING: no voice on the account advertises {language} support "
          f"— falling back to the first account voice '{pick['name']}' "
          "(eleven_v3 auto-detects the language from the text).")
    return pick["voice_id"], f"auto-fallback: first account voice '{pick['name']}'"


def _load_pipeline_and_keys(args, need_llm=True):
    """Import + symbol-check the pipeline and fail fast on credentials.

    Returns (pl, api_key). The LLM check is skipped for --regen-chunk,
    which never calls a language model.
    """
    _note("Importing pipeline modules…")
    pl = _import_pipeline()
    _check_symbols(pl)
    if args.language not in pl.TTS_LANGUAGES:
        raise RuntimeError(f"Language {args.language!r} is not registered "
                           "in the pipeline's TTS_LANGUAGES table.")
    try:
        api_key = pl._get_api_key()
        val_info = pl._validate_api_key(api_key)
        _note(f"ElevenLabs API key verified (tier: {val_info.get('tier', 'active')})")
    except Exception as e:
        raise RuntimeError(f"ElevenLabs API key unavailable or invalid: {e}")

    # Preflight network/proxy check log
    proxies = [f"{k}={v}" for k, v in os.environ.items() if k.lower().endswith("_proxy")]
    if proxies:
        _note(f"Active proxy configuration: {', '.join(proxies)}")

    if need_llm:
        try:
            pl._validate_llm_config()
        except Exception as e:
            raise RuntimeError(f"LLM provider not usable: {e}")
    return pl, api_key


def _prepare_out_dir(pl, audio_path, manifest):
    """Create/reuse the app-convention output folder next to the audio.

    Done BEFORE any paid API work (cheap mkdir+copy): an unwritable input
    location (mounted DMG, read-only share) must fail fast, not after the
    S1a transcription spend. Setting manifest["out_dir"] up front also
    means even early failures write the manifest copy next to the audio.
    Returns (out_dir, base).
    """
    out_dir = pl._prepare_output_dir(audio_path)
    if not os.access(out_dir, os.W_OK):
        raise RuntimeError(f"Output folder is not writable: {out_dir} — "
                           "move the audio to a writable location.")
    base = os.path.join(
        out_dir, os.path.splitext(os.path.basename(audio_path))[0])
    manifest["out_dir"] = out_dir
    copied_audio = os.path.join(out_dir, os.path.basename(audio_path))
    manifest["en_audio"] = copied_audio if os.path.exists(copied_audio) else ""
    return out_dir, base


def _stage_translate(pl, args, api_key, manifest, ctx):
    """S1a..S2c: transcription, regions/SRT, translation chain.

    Fills *ctx* with everything the dub half (or the review-file writer)
    needs: out_dir, base, raw_eng, words, regions, en_audio_dur, final_srt,
    punc_result. Shared verbatim between --steps full and --steps translate.
    """
    audio_path = ctx["audio_path"]
    language = args.language
    gemini_model = pl.GEMINI_DEFAULT_MODEL

    # A user-provided translation (--provided-script) replaces the whole
    # S2a-S2c LLM chain. Read + validate it BEFORE any paid API work so a
    # bad file fails fast, not after the S1a transcription spend.
    provided_text = None
    if getattr(args, "provided_script", None):
        p = os.path.abspath(os.path.expanduser(args.provided_script))
        if not os.path.isfile(p):
            raise RuntimeError(f"--provided-script file not found: {p}")
        provided_text = _read_text(p).strip()
        if not provided_text:
            raise RuntimeError(f"--provided-script file is empty: {p}")
        _note(f"Provided translation loaded: {p} "
              f"({len(provided_text)} chars) — the LLM translation chain "
              "will be skipped.")

    out_dir, base = _prepare_out_dir(pl, audio_path, manifest)
    ctx["out_dir"], ctx["base"] = out_dir, base

    # ── [S1a] Transcribe the English audio ─────────────────────────────────
    _say("S1a", "Transcribing English audio (ElevenLabs Scribe)…")
    result = pl._transcribe_audio(audio_path, api_key, label="S1a", status_cb=lambda m: _say("S1a", m))
    words = result.get("words", [])
    raw_eng = (result.get("text", "") or "").strip()
    if not raw_eng and words:
        raw_eng = " ".join(w.get("text", "").strip() for w in words
                           if w.get("type", "word") == "word")
    if not words:
        raise RuntimeError("No word data from ElevenLabs for the English "
                           "audio.")
    _say("S1a", f"Transcription done ({len(words)} word tokens).")
    ctx["words"], ctx["raw_eng"] = words, raw_eng

    # ── [S1b] Regions + English SRT + analysis format ───────────────────────
    _say("S1b", "Detecting speech regions in the English audio…")
    y_data, sr = pl._load_audio_any(audio_path)
    regions = pl._detect_regions_from_audio(
        y_data, sr, pl.DEFAULT_THR_DB, pl.DEFAULT_HYS_DB,
        pl.DEFAULT_MIN_MS)
    if not regions:
        raise RuntimeError("No speech regions detected in the English audio "
                           "(is the file silent?).")
    try:
        ctx["en_audio_dur"] = float(len(y_data)) / float(sr) if sr else 0.0
    except Exception:
        ctx["en_audio_dur"] = 0.0
    ctx["regions"] = regions

    final_srt = pl._build_subtitle_srt(regions, words)
    srt_path = base + ".srt"
    _write_text(srt_path, final_srt)
    manifest["en_srt"] = srt_path
    formatted_srt = pl._parse_srt_to_analysis_format(final_srt)
    _write_text(base + "_analyzed.txt", formatted_srt)
    _say("S1b", f"{len(regions)} regions — English SRT saved: "
                f"{os.path.basename(srt_path)}")
    ctx["final_srt"] = final_srt

    # ── [S2a-c] Translation chain (Step1 -> Step2 -> Step3) ────────────────
    # The pipeline runs all three prompt steps inside one call, so S2b/S2c
    # are announced when the chain returns rather than in real time.
    # Translation memory: the READ-ONLY half of the TM flow (ON by default,
    # like the app) — an exact proofed match reuses the human-proofed script
    # with zero LLM cost, partial matches become a prompt glossary. No
    # _tm_capture — the engine records nothing. The lookup helpers stay
    # getattr-guarded so a broken/absent tm module degrades gracefully.
    tm_cached = None
    tm_glossary = ""
    _tm_full = getattr(pl, "_tm_lookup_full", None)
    _tm_block = getattr(pl, "_tm_glossary_block", None)
    if callable(_tm_full) and provided_text is None:
        try:
            en_entries_tm = pl._extract_srt_entries(final_srt)
            tm_cached = _tm_full(language, en_entries_tm)
            if not tm_cached and callable(_tm_block):
                tm_glossary = _tm_block(language, en_entries_tm) or ""
        except Exception as e:
            tm_cached, tm_glossary = None, ""
            _note(f"WARNING: translation-memory lookup failed ({e}) — "
                  "running the full LLM chain.")
    if provided_text is not None:
        tr_result = rev_result = punc_result = provided_text
        _say("S2a", "Using the provided translation — LLM translation "
                    "skipped.")
        _say("S2b", "Review step skipped (translation provided by user).")
        _say("S2c", "Punctuation step skipped (translation provided by "
                    "user).")
    elif tm_cached:
        tr_result = rev_result = punc_result = tm_cached
        _say("S2a", "Translation memory hit — reusing the human-proofed "
                    "script (no LLM call).")
        _say("S2b", "Review step skipped (proofed script from memory).")
        _say("S2c", "Punctuation step skipped (proofed script from memory).")
    else:
        if tm_glossary:
            _note("Translation memory: partial matches found — injecting "
                  "the approved-translations glossary into the prompt.")
        _say("S2a", f"Translation chain running on {gemini_model} "
                    f"(Step1 translate -> Step2 review -> Step3 punctuation)…")
        (tr_result, rev_result, punc_result,
         _tr_in, _rev_in, _punc_in) = pl._run_gemini_pipeline(
            formatted_srt, gemini_model, language=language, steps=3,
            tm_glossary=tm_glossary)
        _say("S2b", "Review step done (ran inside the translation chain).")
        _say("S2c", "Punctuation step done (ran inside the translation chain).")

    _write_text(base + "_TranslationStep.txt", tr_result)
    _write_text(base + "_ReviewStep.txt", rev_result)
    combined = (f"=== ENGLISH TRANSCRIPTION ===\n{raw_eng}\n\n"
                f"=== {language.upper()} TRANSLATION ===\n{punc_result}")
    _write_text(base + "_FinalScript.txt", combined)
    _say("S2c", "FinalScript saved.")
    ctx["punc_result"] = punc_result


def _stage_dub(pl, args, api_key, manifest, ctx, voice_id):
    """S2d..S3e: emotion + TTS + sync + render.

    Consumes from *ctx*: out_dir, base, audio_path, en_audio_dur and the
    dub script text (script_text). The English sync SRT comes from the
    in-memory transcription (regions+words, full run) or from the
    _sync_en.srt file the translate stage persisted (dub resume) —
    ctx["en_srt_text"] set means "already on disk, reuse it".
    """
    language = args.language
    gemini_model = pl.GEMINI_DEFAULT_MODEL
    out_dir, base = ctx["out_dir"], ctx["base"]
    audio_path = ctx["audio_path"]
    script_text = ctx["script_text"]

    # ── [S2d] Step-4 emotion enrichment + TTS (ElevenLabs, single voice) ───
    # Single-voice only: a saved per-paragraph speaker voice map (which the
    # bulk app's worker would honour via synthesize_tts_elevenlabs_multi) is
    # reported loudly, then ignored.
    _speakers_map = getattr(pl, "_speakers_voice_map", None)
    if callable(_speakers_map):
        try:
            spk_map = _speakers_map(base) or {}
        except Exception:
            spk_map = {}
        if spk_map:
            _say("S2d", f"WARNING: this project has a saved multi-speaker "
                        f"voice map ({len(spk_map)} paragraph(s)) — "
                        "multi-speaker dubbing is not supported; "
                        "the whole script is dubbed with the single voice "
                        f"{voice_id}.")

    # Step-4 emotion enrichment before ElevenLabs TTS, exactly like the bulk
    # app's single-voice worker (ON by default there; the app only strips
    # the tags for its non-ElevenLabs Google TTS path, which this engine
    # does not have). Best-effort: on any LLM failure the original text
    # comes back unchanged.
    if _emotion_enabled(args):
        _say("S2d", f"Step-4 emotion enrichment on {gemini_model}…")
        tts_text = pl._run_emotion_enrichment(
            script_text, language=language, model=gemini_model,
            status_cb=lambda m: _say("S2d", m))
        if not (tts_text or "").strip():
            tts_text = script_text
    else:
        tts_text = script_text
        _say("S2d", "Emotion enrichment disabled (--no-emotion / settings) "
                    "— sending the bare punctuated text to TTS.")

    _say("S2d", f"Synthesizing {language} speech (voice {voice_id}, "
                f"model {args.el_model})…")
    tts_path = os.path.join(
        out_dir, pl._tts_output_name(language, audio_path, "_tts"))
    # synthesize_tts_elevenlabs may divert to a "-2" name when the previous
    # wav is still locked (open REAPER project) — use the returned path.
    tts_path = pl.synthesize_tts_elevenlabs(
        tts_text, tts_path, api_key=api_key, voice_id=voice_id,
        model_id=args.el_model,
        status_cb=lambda m: _say("S2d", m))
    manifest["tts_wav"] = tts_path
    _say("S2d", f"TTS audio saved: {os.path.basename(tts_path)}")

    # ── [S3a] English sync SRT ──────────────────────────────────────────────
    en_sync_path = base + "_sync_en.srt"
    if ctx.get("en_srt_text"):
        # Dub resume: the translate stage already built and persisted this
        # SRT from its S1a transcription — no second Scribe call needed.
        en_srt = ctx["en_srt_text"]
        _say("S3a", "Using the English sync SRT from the translate stage.")
    else:
        _say("S3a", "Building English sync SRT…")
        en_srt = pl._build_english_subtitle_srt(ctx["regions"], ctx["words"])
        _write_text(en_sync_path, en_srt)
        _say("S3a", "English sync SRT saved.")

    # ── [S3b] Target-language SRT from the TTS audio ───────────────────────
    _say("S3b", "Loading TTS audio and detecting regions…")
    te_y, te_sr = pl.librosa.load(tts_path, sr=None, mono=True)
    te_regions = pl._detect_regions_from_audio(
        te_y, te_sr, pl.DEFAULT_BN_THR_DB, pl.DEFAULT_BN_HYS_DB,
        pl.DEFAULT_BN_MIN_MS)
    if not te_regions:
        raise RuntimeError("No regions detected in the TTS audio.")
    _say("S3b", f"Transcribing TTS audio ({len(te_regions)} regions)…")
    te_result = pl._transcribe_audio(tts_path, api_key, label="S3b", status_cb=lambda m: _say("S3b", m))
    te_words = te_result.get("words", [])
    if not te_words:
        raise RuntimeError("No word data from ElevenLabs for the TTS audio.")
    te_srt = pl._build_target_subtitle_srt(te_regions, te_words)
    _write_text(base + "_sync_te.srt", te_srt)
    _say("S3b", f"{language} sync SRT saved.")

    # ── [S3c] LLM subtitle mapping ──────────────────────────────────────────
    _say("S3c", "Calling the LLM for EN <-> target subtitle mapping…")
    mapping_text = pl._call_gemini_mapping(
        en_srt, te_srt, script_text, gemini_model, language=language)
    _write_text(base + "_sync_mapping.txt", mapping_text)
    _say("S3c", "Mapping received and saved.")

    # ── [S3d] Sync algorithm ────────────────────────────────────────────────
    _say("S3d", "Running the sync algorithm…")
    synced_subs, orig_te_subs, sync_log = pl.run_sync_from_strings(
        en_srt, te_srt, mapping_text,
        en_audio_duration=ctx.get("en_audio_dur", 0.0))
    _write_text(base + "_sync_log.txt", sync_log)
    n_bleed = sync_log.count("[bleed-over]")
    if n_bleed:
        _say("S3d", f"{len(synced_subs)} subtitles synced — {n_bleed} long "
                    "section(s) anchored to their English start (see sync "
                    "log).")
    else:
        _say("S3d", f"{len(synced_subs)} subtitles synced.")

    synced_srt_text = pl._write_srt_from_dict(synced_subs)
    synced_srt_path = base + "_sync_synced.srt"
    _write_text(synced_srt_path, synced_srt_text)
    manifest["synced_srt"] = synced_srt_path

    ts_list = pl._build_timestamps(orig_te_subs, synced_subs)
    sync_ts_path = base + "_sync_timestamps.txt"
    _write_text(sync_ts_path, pl._format_timestamps_as_text(ts_list))
    manifest["timestamps_txt"] = sync_ts_path
    _say("S3d", "Synced SRT + timestamps saved.")

    # ── [S3e] Render the synced audio ───────────────────────────────────────
    _say("S3e", "Rendering the synced audio…")
    synced_path = os.path.join(
        out_dir, pl._tts_output_name(language, audio_path, "_synced"))
    # Same lock hazard as the TTS wav: a previous _synced.wav imported into
    # an open REAPER project holds a share lock — divert instead of Errno 13.
    synced_path = pl.ensure_writable_output(
        synced_path, status_cb=lambda m: _say("S3e", m))
    pl.sync_audio_with_timestamps(
        tts_path, ts_list, synced_path,
        status_cb=lambda m: _say("S3e", m))
    manifest["synced_wav"] = synced_path
    _say("S3e", f"Synced audio saved: {os.path.basename(synced_path)}")


_FFMPEG_MSG = ("ffmpeg not found — the engine needs it to decode TTS audio "
               "(pydub shells out to it). Re-run the setup script "
               "(setup_windows.bat / setup_mac.command); it installs ffmpeg "
               "automatically. Then start the run again.")


def _require_ffmpeg(pl, hard):
    """Fail (or warn) BEFORE any LLM/TTS spend when ffmpeg is missing.

    Without this, a run burns transcription + translation + TTS credits and
    then dies at the audio-save step with a bare WinError 2 (real report
    from a Windows install where the setup's ffmpeg step was skipped).
    """
    if getattr(pl, "FFMPEG_PATH", None):
        return
    if hard:
        raise RuntimeError(_FFMPEG_MSG)
    _note("WARNING: " + _FFMPEG_MSG + " (The dub stage will need it; "
          "translate-only runs on WAV input can proceed.)")


def _begin_run(args, manifest):
    """Common head of full/translate/dub: audio checks + pipeline import +
    keys.

    Returns (pl, api_key, ctx) with ctx pre-seeded with the absolute
    audio path.
    """
    audio_path = os.path.abspath(os.path.expanduser(args.audio))
    manifest["audio"] = audio_path
    manifest["language"] = args.language
    if not os.path.isfile(audio_path):
        raise RuntimeError(f"Audio file not found: {audio_path}")
    pl, api_key = _load_pipeline_and_keys(args, need_llm=True)
    # _llm_provider_label(), not GEMINI_DEFAULT_MODEL: the constant is the
    # Gemini default and says nothing about the provider this install actually
    # calls, so a gateway run used to advertise "gemini-2.5-pro" in its log.
    _note(f"Pipeline loaded. LLM: {pl._llm_provider_label()}; "
          f"TTS model: {args.el_model}.")
    _require_ffmpeg(pl, hard=(args.steps in ("full", "dub")))
    return pl, api_key, {"audio_path": audio_path}


def _run_full(args, manifest):
    """--steps full: v0.1 behaviour, unchanged — S1a..S3e in one process."""
    pl, api_key, ctx = _begin_run(args, manifest)
    # Resolve the dub voice up-front so a bad voice fails before any
    # expensive transcription/translation work happens.
    voice_id, voice_how = _resolve_voice(pl, api_key, args.language,
                                         args.voice_id)
    _note(f"Dub voice: {voice_id} ({voice_how})")
    _stage_translate(pl, args, api_key, manifest, ctx)
    ctx["script_text"] = ctx["punc_result"]
    _stage_dub(pl, args, api_key, manifest, ctx, voice_id)


def _paired_paragraph_texts(pl, final_srt, punc_result):
    """Build the aligned EN/translation paragraph texts for review.

    Uses the pipeline's review pairing (_pair_review_rows): English SRT
    segments are grouped onto translation paragraphs proportionally by
    character share, so both sides come back with the SAME row count in the
    same order. Each row becomes one paragraph; paragraphs are joined with
    exactly one blank line. A row with no text on one side gets a visible
    placeholder so the paragraph counts stay equal after a blank-line
    re-split. Internal blank lines inside a paragraph are collapsed for the
    same reason. The translation side preserves every translation paragraph
    verbatim and in order, so joining it back reproduces the dub script.
    """
    en_entries = pl._extract_srt_entries(final_srt)
    tr_paras = pl._split_translation_paragraphs(punc_result)
    rows = pl._pair_review_rows(en_entries, tr_paras)
    if not rows:
        raise RuntimeError("Could not build review rows — the translation "
                           "result is empty.")

    def _block(text):
        text = (text or "").strip()
        if not text:
            return EMPTY_PARAGRAPH_PLACEHOLDER
        # One paragraph = one blank-line-free block.
        lines = [ln.rstrip() for ln in text.splitlines() if ln.strip()]
        return "\n".join(lines) or EMPTY_PARAGRAPH_PLACEHOLDER

    en_text = "\n\n".join(_block(en) for (en, _tr, _s0, _s1) in rows) + "\n"
    tr_text = "\n\n".join(_block(tr) for (_en, tr, _s0, _s1) in rows) + "\n"
    return en_text, tr_text, len(rows)


def _run_translate(args, manifest):
    """--steps translate: S1a..S2c, then stop for review.

    Extra outputs beyond the app-convention files:
      <base>_sync_en.srt          persisted here (instead of at S3a) so the
                                  dub resume never re-transcribes the audio
      <base>_review_en.txt        EN paragraphs (one per review row)
      <base>_review_translation.txt  translation paragraphs, SAME count/order
    """
    pl, api_key, ctx = _begin_run(args, manifest)
    _stage_translate(pl, args, api_key, manifest, ctx)
    base = ctx["base"]

    # Persist the sync-quality English SRT now (the pipeline builds it at
    # S3a from the same S1a transcription) — this is what lets --steps dub
    # resume without a second paid Scribe call.
    en_sync_srt = pl._build_english_subtitle_srt(ctx["regions"],
                                                 ctx["words"])
    _write_text(base + "_sync_en.srt", en_sync_srt)

    en_text, tr_text, n_rows = _paired_paragraph_texts(
        pl, ctx["final_srt"], ctx["punc_result"])
    en_text_path = base + "_review_en.txt"
    tr_text_path = base + "_review_translation.txt"
    _write_text(en_text_path, en_text)
    _write_text(tr_text_path, tr_text)
    manifest["en_text"] = en_text_path
    manifest["translation_text"] = tr_text_path
    manifest["final_script"] = base + "_FinalScript.txt"
    _say("S2c", f"Review files saved ({n_rows} paragraph pair(s)) — "
                "waiting for script review.")


def _run_dub(args, manifest):
    """--steps dub --script <file>: resume after review, S2d..S3e.

    Re-derives out_dir from --audio exactly like a full run, validates the
    translate-stage artifacts, reads the (possibly edited) translation from
    --script, rewrites FinalScript to match what actually gets dubbed
    (mirroring the bulk app's post-review behaviour), then runs the dub
    half. The stale "status":"review" manifest is overwritten by the normal
    ok manifest at the end.
    """
    pl, api_key, ctx = _begin_run(args, manifest)
    voice_id, voice_how = _resolve_voice(pl, api_key, args.language,
                                         args.voice_id)
    _note(f"Dub voice: {voice_id} ({voice_how})")

    out_dir, base = _prepare_out_dir(pl, ctx["audio_path"], manifest)
    ctx["out_dir"], ctx["base"] = out_dir, base

    # The translate stage must have run first in this out_dir.
    required = {
        "English SRT": base + ".srt",
        "English sync SRT": base + "_sync_en.srt",
        "FinalScript": base + "_FinalScript.txt",
    }
    missing = [f"{name}: {path}" for name, path in required.items()
               if not os.path.isfile(path)]
    if missing:
        raise RuntimeError(
            "Translate-stage artifacts are missing from "
            f"{out_dir} — run '--steps translate' on this audio first. "
            "Missing: " + "; ".join(missing))
    manifest["en_srt"] = required["English SRT"]
    ctx["en_srt_text"] = _read_text(required["English sync SRT"])

    script_path = os.path.abspath(os.path.expanduser(args.script))
    if not os.path.isfile(script_path):
        raise RuntimeError(f"--script file not found: {script_path}")
    script_text = _read_text(script_path).strip()
    if not script_text:
        raise RuntimeError(f"--script file is empty: {script_path}")
    n_paras = len(pl._split_translation_paragraphs(script_text))
    _note(f"Dub script loaded: {script_path} ({n_paras} paragraph(s)).")
    ctx["script_text"] = script_text

    # Rewrite FinalScript so the saved file matches what actually gets
    # dubbed — the same thing the bulk app does after its review window.
    marker = f"=== {args.language.upper()} TRANSLATION ==="
    fs_path = required["FinalScript"]
    fs_text = _read_text(fs_path)
    if marker in fs_text:
        _write_text(fs_path,
                    fs_text.split(marker, 1)[0] + marker + "\n" + script_text)
        _note("FinalScript updated with the reviewed translation.")
    else:
        _note(f"WARNING: marker {marker!r} not found in "
              f"{os.path.basename(fs_path)} — FinalScript left unchanged.")

    # English audio duration for the sync algorithm (local decode, no API).
    try:
        y_data, sr = pl._load_audio_any(ctx["audio_path"])
        ctx["en_audio_dur"] = float(len(y_data)) / float(sr) if sr else 0.0
    except Exception as e:
        ctx["en_audio_dur"] = 0.0
        _note(f"WARNING: could not measure the English audio duration "
              f"({e}) — sync runs without it.")

    _stage_dub(pl, args, api_key, manifest, ctx, voice_id)


def _run_regen(args, manifest):
    """--regen-chunk: synthesize one chunk text into --out-wav.

    Single-voice ElevenLabs synthesis with the same voice-resolution rule
    as the pipeline. No emotion pass — the chunk text is already final
    (it came out of a dubbed script; re-enriching would double the tags).
    synthesize_tts_elevenlabs converts the returned MP3 bytes to WAV via
    pydub, and also drops its usual per-chunk side files (<out>_chunks.txt,
    <out>_chunk_NN.mp3) next to the WAV.
    """
    manifest["regen_wav"] = ""
    text_path = os.path.abspath(os.path.expanduser(args.text_file))
    if not os.path.isfile(text_path):
        raise RuntimeError(f"--text-file not found: {text_path}")
    text = _read_text(text_path).strip()
    if not text:
        raise RuntimeError(f"--text-file is empty: {text_path}")

    pl, api_key = _load_pipeline_and_keys(args, need_llm=False)
    _require_ffmpeg(pl, hard=True)
    voice_id, voice_how = _resolve_voice(pl, api_key, args.language,
                                         args.voice_id)
    _note(f"Regen voice: {voice_id} ({voice_how})")

    out_wav = os.path.abspath(os.path.expanduser(args.out_wav))
    # Hard rule kept from v0.2: never write into the bulk-app folder. The
    # engine no longer knows APP_DIR on its own, but if a legacy caller
    # still passes --app-dir, honour the protection.
    if args.app_dir:
        app_dir = os.path.abspath(os.path.expanduser(args.app_dir))
        if out_wav == app_dir or out_wav.startswith(app_dir + os.sep):
            raise RuntimeError(f"--out-wav must not be inside the bulk-app "
                               f"folder: {out_wav}")
    out_parent = os.path.dirname(out_wav)
    if out_parent:
        os.makedirs(out_parent, exist_ok=True)

    _say("S2d", f"Regenerating chunk ({len(text)} chars, voice {voice_id}, "
                f"model {args.el_model})…")
    # A locked --out-wav (previous regen still loaded in REAPER) diverts to
    # a "-2" name; the panel applies whatever path the manifest reports.
    out_wav = pl.synthesize_tts_elevenlabs(
        text, out_wav, api_key=api_key, voice_id=voice_id,
        model_id=args.el_model,
        status_cb=lambda m: _say("S2d", m))
    manifest["regen_wav"] = out_wav
    _say("S2d", f"Regen chunk saved: {os.path.basename(out_wav)}")


def _run_voice_change(args, manifest):
    """--voice-change: re-voice --in-wav with the ElevenLabs voice changer.

    Speech-to-speech conversion to the --voice-id voice (auto-resolved from
    the account catalogue when omitted, same rule as every other mode).
    Keeps the source timing/pacing, so a synced dub stays synced. Manifest:
    {"status":"ok","vc_wav":"<abs>"}.
    """
    manifest["vc_wav"] = ""
    in_wav = os.path.abspath(os.path.expanduser(args.in_wav))
    if not os.path.isfile(in_wav):
        raise RuntimeError(f"--in-wav not found: {in_wav}")
    out_wav = os.path.abspath(os.path.expanduser(args.out_wav))

    pl, api_key = _load_pipeline_and_keys(args, need_llm=False)
    _require_ffmpeg(pl, hard=True)
    voice_id, voice_how = _resolve_voice(pl, api_key, args.language,
                                         args.voice_id)
    _note(f"Voice-change target voice: {voice_id} ({voice_how})")

    # Same lock hazard as the dub outputs: a previous vc wav still loaded in
    # an open REAPER project would fail the save AFTER the STS credits are
    # spent — divert to a "-2" name up front instead.
    out_wav = pl.ensure_writable_output(out_wav, status_cb=lambda m: _note(m))
    pl.voice_change_elevenlabs(
        in_wav, out_wav, api_key=api_key, voice_id=voice_id,
        model_id=args.sts_model,
        status_cb=lambda m: _note(m))
    manifest["vc_wav"] = out_wav
    _note(f"Voice-changed audio saved: {os.path.basename(out_wav)}")


def _run_test_llm(args, manifest):
    """--test-llm: one tiny call on the configured LLM provider.

    Fills provider/model/reply in the manifest. Any failure (missing
    settings, bad key, unreachable endpoint) surfaces as the usual error
    manifest via main()'s handler.
    """
    manifest["provider"] = ""
    manifest["model"] = ""
    manifest["reply"] = ""
    _note("Importing pipeline modules…")
    pl = _import_pipeline()
    _check_symbols(pl)
    pl._validate_llm_config()
    provider, model = pl._active_provider_and_model()
    manifest["provider"], manifest["model"] = provider, model
    _note(f"Testing LLM connection: provider={provider}, model={model}…")
    reply = pl._llm_generate(
        "Reply with the single word OK and nothing else.", model)
    reply = (reply or "").strip()
    if not reply:
        raise RuntimeError("The LLM returned an empty reply.")
    manifest["reply"] = reply[:200]
    _note(f"LLM reply: {manifest['reply']}")


def _run_list_voices(args, manifest):
    """--list-voices --language <Lang>: fetch the ElevenLabs voice catalogue.

    Voices come back language-token sorted exactly like the app's dropdown
    (voices advertising the language first, each bucket alphabetical); the
    manifest keeps that order as [{"id","name"},…].
    """
    manifest["voices"] = []
    _note("Importing pipeline modules…")
    pl = _import_pipeline()
    _check_symbols(pl)
    if args.language not in pl.TTS_LANGUAGES:
        raise RuntimeError(f"Language {args.language!r} is not registered "
                           "in the pipeline's TTS_LANGUAGES table.")
    api_key = pl._get_api_key()
    _note(f"Fetching the ElevenLabs voice catalogue ({args.language})…")
    voices = pl._fetch_voices_for_language(api_key, args.language,
                                           force_refresh=True)
    manifest["voices"] = [{"id": v["voice_id"], "name": v["name"]}
                          for v in voices]
    _note(f"{len(manifest['voices'])} voice(s) fetched.")


def main() -> int:
    args = _parse_args()

    if args.app_dir:
        _note("WARNING: --app-dir is deprecated as of v0.3 and IGNORED — "
              "the engine is standalone (settings come from config/, "
              "prompts from prompts/).")

    if args.selfcheck:
        return _selfcheck(args)

    if args.test_llm:
        keys, runner, ok_status = TEST_LLM_MANIFEST_KEYS, _run_test_llm, "ok"
    elif args.list_voices:
        keys, runner, ok_status = VOICES_MANIFEST_KEYS, _run_list_voices, "ok"
    elif args.voice_change:
        keys, runner, ok_status = (VOICE_CHANGE_MANIFEST_KEYS,
                                   _run_voice_change, "ok")
    elif args.regen_chunk:
        keys, runner, ok_status = REGEN_MANIFEST_KEYS, _run_regen, "ok"
    elif args.steps == "translate":
        keys, runner, ok_status = (REVIEW_MANIFEST_KEYS, _run_translate,
                                   "review")
    elif args.steps == "dub":
        keys, runner, ok_status = MANIFEST_KEYS, _run_dub, "ok"
    else:
        keys, runner, ok_status = MANIFEST_KEYS, _run_full, "ok"

    manifest = {k: "" for k in keys}
    manifest["status"] = "error"     # flipped only on full success
    try:
        runner(args, manifest)
        manifest["status"] = ok_status
        manifest["error"] = ""
        _write_manifest(manifest, manifest.get("out_dir") or "", keys)
        if ok_status == "review":
            _note("Translate stage complete — review manifest written.")
        else:
            _note("Run complete — manifest written.")
        return 0
    except (Exception, SystemExit):
        # SystemExit is caught too (it is a BaseException, NOT an Exception)
        # as a belt-and-braces measure: the contract requires an error
        # manifest on EVERY failure, so convert it instead of letting the
        # process die manifest-less.
        tb = traceback.format_exc()
        print(tb, flush=True)
        manifest["status"] = "error"
        manifest["error"] = tb[-2000:]
        _write_manifest(manifest, manifest.get("out_dir") or "", keys)
        _note("Run FAILED — error manifest written.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
