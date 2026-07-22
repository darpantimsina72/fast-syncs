# Engine notes (contract v0.3 — standalone)

The engine no longer imports the bulk app. All pipeline logic was extracted
from `Translation_and_Syncing_App.py` (bulk app v1.8.0, 12,511 lines, at the
old `APP_DIR`) into the local `engine/pipeline/` package. The bulk app was a
one-time extraction source only; it is not needed at runtime and is never
written to.

## Extraction provenance

Every pipeline module starts with a header naming its source line ranges.
Summary (source = `Translation_and_Syncing_App.py` unless noted):

| Module                | Source lines                     | Contents                                                                                  | Lines |
|-----------------------|----------------------------------|-------------------------------------------------------------------------------------------|------:|
| `pipeline/__init__.py`| —                                | package doc / module map                                                                   | 20 |
| `pipeline/config.py`  | 144-146, 150-198, 446-481, 696-990 | SSL ctx, platform flags + ffmpeg discovery, `_prepare_output_dir`, TTS_LANGUAGES table, ElevenLabs/Gemini/LLM constants, region-detection defaults, NEW `load_tts_settings()` | 359 |
| `pipeline/stt.py`     | 993-1331                         | voice-id sanitizing, key validation, voice catalogue (`_fetch_voices_for_language`), multipart body, Scribe `_transcribe_audio` | 324 |
| `pipeline/srt_tools.py`| 134-142, 1335-2010              | SRT timestamp/builders (EN, target, sync-quality EN), SpaCy chunking (optional import kept), FinalScript extraction, duration/analysis LLM input formats, timestamps txt read/write, `_load_audio_any`, `_detect_regions_from_audio` | 697 |
| `pipeline/llm.py`     | 76-81, 2012-2530                 | provider layer (vertex / gemini / openai-compatible), prompt caching, `_load_lang_prompt`, 3-step chain, code-fence strip, SRT entries, paragraph split, review pairing, TM hooks, Step-4 emotion, mapping call; NEW `_active_provider_and_model()` | 597 |
| `pipeline/tts.py`     | 127-132, 2531-3072, 3080-3109 (read-only speakers-map helpers only) | byte/char chunkers, Google Cloud TTS port, ElevenLabs POST + `synthesize_tts_elevenlabs`, sentence splitter, speakers-map detection | 590 |
| `pipeline/sync.py`    | 3207-3823                        | SRT/mapping parsers, Subtitle/MappingGroup/Section, 5-round spring algorithm, bleed-over overflow, order sweep, caption rechunk, `_build_timestamps`, `sync_audio_with_timestamps` | 632 |
| `pipeline/tm.py`      | `translation_memory.py` (226 lines, whole file) | SQLite proofed-translation memory (full docs + pairs), fail-open writes / fail-closed reads | 227 |

`prompts/` was copied verbatim from the bulk app's `prompts/` directory
(56 entries: 5 stages x 11 languages + the internal `_generate_drafts.py`).

Deliberately NOT ported (out of scope, see CONTRACT v0.3): all Tk/UI code,
colour palette and fonts, matplotlib helpers (`_indic_matplotlib_font`),
sounddevice playback (`_resample_np`), api.txt / last_language.txt /
el_model.txt UI persistence, multi-speaker synthesis
(`synthesize_tts_elevenlabs_multi`, `_speakers_save`), batch mode, updater
and feedback systems. The read-only speakers-map helpers WERE ported so the
engine keeps its v0.2 behaviour of detecting a saved voice map and warning
before dubbing single-voice.

Adaptations beyond path/settings repointing are listed in each module's
header. Everything else is verbatim.

## Facade import

`dub_engine.py` calls `_import_pipeline()`, which imports the seven pipeline
modules and aggregates their symbols onto one namespace (`pl.<symbol>`), so
the v0.1/v0.2 stage code kept its exact shape (it previously addressed the
imported app module the same way). Colliding names across modules are shared
imports of identical objects, so aggregation order is safe. `--selfcheck`
asserts every symbol in `REQUIRED_FUNCTIONS` / `REQUIRED_ATTRIBUTES` exists,
asserts all 55 per-language prompt files exist, and reports missing config/
settings files as WARNINGS (a fresh clone must pass selfcheck).

## Settings and secrets resolution (v0.3)

All secrets live in the repo's gitignored `config/` directory — nothing else
is consulted and nothing sensitive travels on argv:

| What                    | Resolution                                                                 |
|-------------------------|-----------------------------------------------------------------------------|
| ElevenLabs API key      | `config/tts_settings.json` → `"elevenlabs_api_key"` (actionable error when missing) |
| ElevenLabs model        | `--el-model` CLI flag (default `eleven_v3`); the panel passes its saved choice |
| Dub voice               | `--voice-id` CLI flag wins; otherwise auto-resolved from the account catalogue (first language-matched voice, else first account voice) |
| LLM provider + creds    | `config/llm_settings.json` — SAME schema as the bulk app's file; `"provider"` also accepts short aliases `vertex`/`gemini`/`openai`; missing file = actionable error |
| Vertex service account  | `llm_settings.json:"vertex_json"`, blank → `config/vertex_key.json`         |
| Google Cloud TTS key    | `tts_settings.json:"google_tts_key_path"`, blank → `config/TTS_Key.json`    |
| Prompts                 | `<repo>/prompts/Step1..4_*_<Language>.txt`, `SyncingPrompt_<Language>.txt`  |
| Translation memory DB   | `<repo>/data/translation_memory.db` (env `TRANSLATION_MEMORY_DB` overrides); engine only READS |
| Emotion default         | `--emotion/--no-emotion` > `engine_settings.json:"emotion"` > ON            |

`--app-dir` is DEPRECATED: both scripts still accept it (backward compat with
saved panel launch commands), log a warning, and ignore it. The engine no
longer reads anything from the bulk-app install.

## Modes

v0.1/v0.2 modes are byte-compatible (flags, stage tags `[S1a]`…`[S3e]`, and
manifests unchanged): `--steps full`, `--steps translate` (review manifest),
`--steps dub --script`, `--regen-chunk --text-file --out-wav`.

New in v0.3 (both through `run_dub.py` with the same status/log/pid/done
plumbing):

- `--test-llm` — validates the LLM config, makes one tiny call
  ("Reply with the single word OK…"). Manifest:
  `{"status":"ok","provider":"vertex|gemini|openai","model":"…","reply":"…"}`
  or the usual `"status":"error"` shape with those keys empty.
- `--list-voices --language <Lang>` — fetches the ElevenLabs account voice
  catalogue (force-refreshed), language-token sorted like the app (voices
  advertising the language first, each bucket alphabetical). Manifest:
  `{"status":"ok","voices":[{"id":"…","name":"…"},…]}`.

`--selfcheck` remains the only supported direct `dub_engine.py` invocation.

## Verification (gate results)

- `py_compile` clean on `run_dub.py`, `dub_engine.py` and every
  `pipeline/*.py`.
- `dub_engine.py --selfcheck` (no `--app-dir`) → `SELFCHECK OK`, exit 0
  (config-missing warnings printed as designed).
- `--help` exits 0 on both scripts with all flags listed.
- `import pipeline.llm/tts/sync/stt/srt_tools/tm/config` succeeds.
- Zero runtime references to the bulk app module anywhere under `engine/`
  (provenance comments only).
- Functional parity smoke test: SRT builders, analysis format, full
  `run_sync_from_strings` round trip, timestamps text format, review
  pairing, ElevenLabs chunker tag safety, voice-id sanitizing, TM
  store/lookup round trip, caption rechunk — all pass on the reference
  interpreter.
