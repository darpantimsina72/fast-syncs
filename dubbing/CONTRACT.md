# Reaper Dubbing App — Interface Contract

Goal: run the dubbing pipeline of the existing Tkinter app FROM INSIDE REAPER.
The original app is READ-ONLY — never modify or write anything inside
`APP_DIR`. As of v0.3 the project is STANDALONE (see v0.3 section): APP_DIR
is only a one-time extraction source and optional key-migration source, never
a runtime dependency.

## v0.7 — Auto-Sync-style matching for dub runs, Un sync track, version, history

### Sync mode (engine)

- `--sync-mode match|legacy` on run_dub.py + dub_engine.py (also a
  `sync_mode` key in `engine_settings.json`; CLI wins; default **match**).
  Applies to the dub half of `--steps full` and to `--steps dub`; regen /
  voice-change / test-llm / list-voices are unaffected.
- **match** (new default) replaces the S3b/S3c/S3d internals for BOTH the
  Full Pipeline and Paste Translation runs; **legacy** is the old
  whole-script-TTS + Scribe-re-transcription + SyncingPrompt path,
  kept verbatim in `_stage_dub_legacy`.
- Match flow (`pipeline/match.py` + `tts.synthesize_sections_elevenlabs`):
  1. The dub script (LLM translation or `--provided-script` text, possibly
     user-edited at review) is split into sentences
     (`tts._split_script_into_sentences` — danda-aware, tag-safe).
  2. ONE Gemini call (`call_match_sections`, transported through the
     provider-agnostic `_llm_generate`, so vertex/gemini/gateway all work)
     groups EN sync-SRT cue ids with script sentence ids into sections —
     the same section prompt idea as the fast-syncs `sync_matcher.py`.
     Retries once, then HARD-fails (no silent fallback, like Auto Sync).
     Unmentioned ids are mechanically filed as unmatched.
  3. `build_chunks`: one TTS chunk per matched section; consecutive
     unmatched sentences merge into unsync chunks; script order kept.
  4. Per-section ElevenLabs TTS with request stitching (previous_text /
     next_text = neighbouring script text) into ONE `tts_wav`, 240 ms
     silence between sections; exact per-section spans returned — S3b's
     second Scribe pass and S3c's SyncingPrompt call are GONE in this mode
     (S3a-S3c are printed as book-keeping lines so the panel checklist
     still advances in order).
  5. `place_chunks`: the Auto Sync placement — slot from the section's EN
     cues, rounds center/align_start/align_end ×2 iterations,
     align_start fallback (bleed-over), then the order-preserving sweep:
     a chunk that cannot end before the next chunk's spring position is
     demoted to **unsync** with a chain position (each unsync chunk sits
     right after the previous clip, chronological). No silence correction
     (TTS starts at speech; EN cue starts are word-refined already).
  6. Step-4 emotion enrichment is SKIPPED in match mode (logged at S2d):
     per-section enrichment would multiply LLM calls and whole-script
     enrichment would break the sentence-id mapping.
- Timestamps file gains an OPTIONAL 6th bracket `[synced]` / `[unsync]`
  (header gains `[Status]`). 5-field files stay byte-identical and every
  reader treats a missing status as synced — old runs import unchanged.
  `_parse_timestamps_text` returns it as `sync_status`.
- New sidecar `<base>_sync_texts.txt`: blank-line-separated blocks, block N
  = chunk text for timestamps index N (item notes for BOTH tracks; the
  synced SRT covers only synced chunks, so notes need their own channel).
- `_sync_synced.srt` = synced chunks only (regions must not point at the
  Un sync chain). `_synced.wav` renders synced chunks only, via
  `sync_audio_with_timestamps(..., extend_last=False)` (spans are exact;
  extending the last segment would drag trailing unsync audio in).
- Manifest (full/dub) gains `sync_texts`, `synced_count`, `unsynced_count`
  (strings; "" from legacy mode — consumers skip empties, as always).

### Import (both importers)

- Entries parse the optional trailing `[synced]/[unsync]` bracket (letters
  only, so a 5-field line's `[1234ms]` tail can never match).
- Synced entries → `Dub Chunks` (fresh-suffix rule unchanged). Unsync
  entries → the **`Un sync`** track — find-by-exact-name or append, the
  SAME name + reuse rule as `auto_sync_pipeline.lua`, so Auto Sync and dub
  runs park leftovers on one track. Item take names: `unsync NN`.
- Item notes prefer the `sync_texts` sidecar (block by entry index) and
  fall back to the old synced-SRT cue matching. Summary line reports
  "Synced chunks placed / Un sync chunks" when any unsync exist; the
  panel success phase shows `Chunks: N synced, M unsynced` from the
  manifest counts.

### Version (the "which build am I on" answer)

- Root `VERSION` file (starts at 0.7.0), shipped in the repo so git pull /
  ZIP overlay updates it. Shown: dub panel title bar and Settings tab
  (`V5.APP_VERSION`), Auto Sync standalone title bar, engine log banner
  (`[engine] Reaper Dubbing App vX (contract v0.7)`).
- Both ImGui windows now carry a `###` ID suffix (`###dub_pipeline`,
  `###auto_sync_pipeline`) so the version text in the title never resets
  the saved window position again (the one rename to add the suffix does,
  once).

### A model per stage (engine + panel)

- `llm_settings.json` gains `model_translate`, `model_emotion`,
  `model_match`, `model_mapping`, `model_sync_match`. **Blank is the
  default and means "use the provider model"**, so an upgraded install
  behaves exactly as before until a field is filled in.
- `_llm_generate(prompt, model, static_prefix, role=None)` resolves the
  model through `_model_for(role, fallback)`: `model_<role>` → the
  provider-wide model (`openai_model` / `gemini_model`) → the caller's
  default. Roles are named at the call sites: `translate` (Step1-3),
  `emotion` (Step4), `match` (v0.7 section matching), `mapping` (legacy
  S3c). `--test-llm` deliberately passes no role — it tests the main model.
- `_llm_role_overrides_label()` is printed in the startup banner whenever
  anything is overridden, for the same reason `_llm_provider_label()` is:
  a run that used a different model than the Settings field shows must
  say so in its own log.
- `model_sync_match` is Auto Sync's, and Auto Sync reads its model from
  `sync_pipeline_settings.json` — so `save_sync_credentials()` writes that
  value into `gemini_model` there (falling back to the main model when
  blank). The engine never reads `model_sync_match`.

### User-added languages (engine + panel)

- `config/custom_languages.json`:
  `{"languages":[{"name","code","tag"}]}` (gitignored with the rest of
  `config/`). A language is a name plus five prompt files — nothing else
  in the engine is language-specific.
- `pipeline/config.py::_load_custom_languages()` merges each entry into
  `TTS_LANGUAGES` at import (marked `google_unavailable`; ElevenLabs
  detects the script from the text). A name that collides with a built-in
  is **ignored, not overwritten** — the shipped entries carry Google voice
  lists a hand-written one cannot.
- `dub_engine.py` and `run_dub.py` extend their `--language` choices from
  the SAME file with their own stdlib-only read: argparse builds choices
  before the pipeline import, and the launcher validates `--language`
  before spawning the worker, so both lists must agree.
- `--selfcheck` treats missing prompts for a user-added language as a
  WARNING naming the files, not a failure. A half-configured extra
  language must never block setup for the eleven built-ins.

### Prompt editing (panel)

- Settings → **Prompts**: language combo × stage combo → the file's text in
  an editable box, with Save / Reload / Open in editor.
  `dubbing/prompts/<Stage>_<Language>.txt`, the same files the engine
  loads through `_load_lang_prompt()`.
- Settings → **Languages** → *Add language* writes the JSON entry and
  seeds the five prompts from an existing language (`V5.prompts_seed`,
  which never overwrites an existing file). *Remove* drops the entry and
  leaves the prompt files on disk — deleting user-edited text on a
  mis-click is not recoverable.

### Voice bookmarks + search (panel)

- `reaper/voice_bookmarks.json` (gitignored, GLOBAL — not per project, not
  per language): `{"voices":[{"id","name"},…]}`, the SAME shape the
  `--list-voices` manifest uses, so `parse_voices_json` reads it unchanged.
- `V5.ui_voice_picker(ctx, key, cur, label)` is the one voice widget, used
  by ⚙ Settings, Track Voice and Text to Speech (`key` keeps the ImGui ids
  unique). It renders a search box (case-insensitive substring on name or
  id, `find(…, 1, true)` so a name with `(`/`-` is not read as a pattern),
  one combo listing bookmarks (★) before the fetched catalogue, and a
  star/unstar button for the current voice. Returns the chosen id; every
  host keeps its manual "Voice id" field, which still wins.
- Bookmarks survive panel restarts and language switches; the fetched
  catalogue (`_voices`) does not, which is the whole point.

### Text to Speech tab (panel)

- Paste text → synthesize → item on a `TTS` track at the EDIT CURSOR
  (find-or-create track, same rule as `Un sync`). Item note = the spoken
  text; take name = the wav name.
- Runs the EXISTING `--regen-chunk` engine mode (text file in, wav out, no
  emotion, no other stages) — no new engine mode, no contract change on the
  Python side. Only the finish handling differs from Regen Audio: the wav
  is imported instead of replacing an item's take.
- `tts` is a UTIL_MODE: it never owns the phase state, never clears the
  last run's manifest or a pending review, and returns to the phase it was
  started from. It has no entry in `MODE_STAGES`, so no stage checklist is
  drawn (same as regen).
- Files land in `<project media path>/TTS/` as `TTS_<stamp>.txt` (UTF-8 —
  Indic text never travels on argv) and `TTS_<stamp>[_vN].wav`. An unsaved
  project is refused with a message, since there is no media path yet.
- Voice resolution: the tab's own voice → ⚙ Settings voice → engine
  auto-resolve. `--language` is still passed (it only matters for
  auto-resolution; eleven_v3 detects the language from the text).

### Per-project run history (panel)

- `engine/history/<project-slug>.json` (same slug as the status dirs;
  gitignored; NOT under engine/status/, which run_dub.py wipes per launch).
  Shape: `{"entries":[{"ts","mode","audio","language","out_dir","status"},…]}`
  newest first, deduped by out_dir (a finished dub replaces its review
  entry), capped at 20. Writers: `enter_review_phase` records "review",
  `_finish_run` records "ok" for full/dub runs. The history file only
  INDEXES runs — the authority stays each run's `<out_dir>/engine_done.json`
  (written there since v0.1 precisely because status dirs are transient).
- Setup phase (Full Pipeline AND Paste Translation tabs) shows a
  "Project history" section for the ACTIVE REAPER project (slug re-checked
  every frame, so switching project tabs swaps the list). Per entry:
  **Resume review** (reload the out_dir manifest → the normal review
  phase; transcription + translation are NOT redone), **Import to
  timeline** (finished runs; re-imports from the out_dir manifest),
  **Use audio + language** (prefill setup), **Folder**.
- Unsaved projects share the `unsaved` slug — their history is one bucket
  by design (same trade-off as the status dirs).

## v0.6 — One entry point, credentials that cannot be half-configured

### One documented ReaScript

- `auto_sync_pipeline.lua` (fast-syncs root) is the ONLY script a user loads.
  It already redirects to the dub panel (see the v0.5 embed section); v0.6
  makes the docs and both setup scripts say only that. `Sync_Item.lua` moved
  to `scripts_optional/` so the repo root lists exactly one `.lua`.
- `dubbing/reaper/*.lua` are INTERNAL: loaded for the user, never advertised.
  They stay where they are — `Dub_Pipeline_Panel.lua` derives `BASE_DIR` from
  its own parent directory and keeps `dub_panel_settings.json` beside itself,
  so moving or renaming it would break every engine/venv/config path and
  orphan existing panel settings.
- `Import_Dub_Results.lua` is the ONE exception a user may load directly, and
  only when ReaImGui is unavailable.

### Credentials (a blank key must never reach a paid run)

- `_validate_llm_config()` also requires `openai_api_key` for the OpenAI
  provider, UNLESS the base URL host is loopback / RFC-1918 / `*.local` (a
  keyless local Ollama, vLLM or LiteLLM is legitimate). Shared rule:
  `_gateway_needs_key()` in `pipeline/llm.py`, mirrored by
  `V5.gateway_needs_key()` in the panel — keep the two in step.
- A blank key means NO `Authorization` header, and gateways answer that with
  wording about the key being wrong ("No api key passed in."). So a 401/403
  raised while no key was sent must say the key is MISSING, quoting the
  gateway's own text only as trailing detail.
- `_openai_api_urls()` rejects a base URL ending in `/ui`: that is the gateway's
  admin console pasted in place of the API root. LiteLLM answers the resulting
  `/ui/v1/chat/completions` with `405 Method Not Allowed`, which names nothing,
  and the existing HTML-body guard cannot help because the 405 body is JSON.
  Seen in the wild — a panel configured from the browser address bar.
- The engine banner prints `_llm_provider_label()` — active provider, model,
  base URL and whether the credential is set. Never the
  `GEMINI_DEFAULT_MODEL` constant: a gateway run used to log "gemini-2.5-pro".
- `_load_llm_settings()` coerces non-string scalars and PRINTS a line for any
  other type. A silent drop to `""` turns a configured key into a 401.
- Panel saves are blank-preserving: an empty credential box keeps the value
  already on disk (`V5.keep_stored_credentials()`), because the save rewrites
  every field. A per-field `Clear` button is the only way to remove a key.
- `preflight_engine(need_llm)` refuses LLM runs (`full`/`translate`/`dub`)
  when `V5.llm_creds_error()` reports a gap. `--test-llm` and the LLM-free
  modes (`--regen`, `--voice-change`) are never gated.
- Saving Settings with complete credentials auto-runs `--test-llm`; with an
  incomplete set it shows a warn banner naming the gap. "Settings saved" is
  never the last word on a config that cannot run.

## v0.5 — Merged into fast-syncs: 7-tab panel, embedded Auto Sync, per-project status dirs, robust updater

### Repo

- The whole app now lives at `<fast syncs>/dubbing/` and is distributed by
  the fast-syncs updater (git pull / ZIP overlay — the overlay never
  deletes, so `dubbing/venv`, `dubbing/config`, `dubbing/data` survive).
  `update.sh` / `update.bat` additionally refresh `dubbing/venv` from
  `dubbing/requirements.txt` WHEN that venv exists (first-time setup stays
  manual/panel-offered — dubbing deps are heavy and sync-only users must
  not pull them).
- `auto_sync_pipeline.lua` gains a small `Dubbing...` button (setup-phase
  footer) that registers `dubbing/reaper/Dub_Pipeline_Panel.lua` via
  `AddRemoveReaScript(true, 0, path, true)` and runs it.
- All paths stay self-relative — nothing depends on the folder's location.

### Engine

- `run_dub.py --status-dir <abs>`: per-run status directory for
  log/pid/done/manifest. MUST be `engine/status` itself or a subdirectory
  (launcher refuses anything else — it cleans the target). Subdirs are
  cleaned with rmtree; the shared root is cleaned file-by-file so a legacy
  root-mode launch can never wipe a live sibling subdir. The dir is passed
  to `dub_engine.py` via the `DUB_STATUS_DIR` env var (manifest must land
  in the same per-run dir).

### Panel — one TabBar, seven tabs

`Full Pipeline` (all phases; staged/review default) · `Paste Translation`
(own audio+language+script form → runs with `--provided-script`) ·
`Auto Sync` (the embedded fast-syncs pipeline — §Auto Sync embed) ·
`Regen Audio` (the `ui_regen_section` utility) · `Track Voice`
(`ui_voice_change_section`) · `Logs` · `Settings` (LLM/TTS keys + Advanced
python override + fast-syncs `Update…`; locked while a dub run is active).

- The tab a run starts from decides the script source (Full Pipeline → LLM,
  Paste → provided) — the old "I already have the translation" checkbox is
  gone. Regen/Track Voice are no longer inline in setup/success — they are
  their own tabs, usable any time (their own launch still goes through
  `preflight_engine`, which blocks starting one over a live run).
- Per-project status dirs: `engine/status/<projname>_<djb2(projpath)>/`
  (`unsaved` for unsaved projects). Re-resolved at load and in preflight
  ONLY while `_ui_phase == "setup"`; a run keeps its launch-time paths.
  `--status-dir` is passed on EVERY engine invocation. The
  previous-run-alive probe is scoped to this status dir (`ps … | grep
  --status-dir <dir>`, not a bare `pgrep run_dub.py`). The startup review
  probe also checks the legacy shared root once (pre-v0.5 paused reviews
  stay resumable).
- Import: the launch-time project is remembered
  (`reaper.EnumProjects(-1,"")`), and Import switches back to it via
  `SelectProjectInstance` if the user changed project tabs mid-run.
- Missing venv at preflight → MB offer to run the platform setup script in
  a terminal.
- NOTE: every v0.5 symbol lives in the single `V5` table — the main chunk
  is at Lua's 200-local limit; add new file-scope state as `V5.*` fields.

### Auto Sync embed (dub panel ↔ auto_sync_pipeline.lua)

- `auto_sync_pipeline.lua` is DUAL-MODE. Standalone (run as an action) it
  behaves exactly as before. When `_G.__FASTSYNC_EMBED == true` at load, it
  skips its own `ClearConsole`/`CreateContext`/font-attach/`Begin`/`defer`
  and instead `return`s a module `{ render(ctx,on_close), poll(),
  is_running(), reload_settings() }`.
- The dub panel `dofile()`s it once at startup (`V5.load_sync`), setting the
  flag around the call. Because it is a separate `dofile` chunk it has its
  OWN fresh Lua-local budget AND its own copies of `_ui_phase`, poll offsets
  etc. — no collision with the dub panel's identically-named locals.
- `V5.SYNC.poll()` is called every dub frame (outside the tab bar) so a sync
  run progresses regardless of the active tab; `V5.SYNC.render(ctx,
  close_window)` draws the sync phases inside the `Auto Sync` tab, sharing
  the dub panel's ImGui context. In embed the sync uses the default font
  (no cross-context `Attach`); pasted Indic `script_text` may not shape
  in-panel (cosmetic).
- Sync paths stay rooted at the fast-syncs root (the sync file's own dir),
  so `run_sync.py`, the sync `venv`, `sync_pipeline_settings.json`,
  `sync_config.json`, `sync_results.json`, and `sync_python_{log,pid,done}`
  are all the fast-syncs ones — NOT the dubbing ones. The sync tab needs the
  fast-syncs root `venv` (root `setup.sh`/`.bat`), separate from
  `dubbing/venv`. The standalone sync `Dubbing...` button is hidden in embed
  (it would re-open the dub panel).
- If `auto_sync_pipeline.lua` is absent (dubbing installed standalone, not
  under fast-syncs), the `Auto Sync` tab shows `V5.sync_err` instead.

### Update button (both this panel and auto_sync_pipeline.lua)

- The `osascript -e 'tell application "Terminal" …'` launch was replaced:
  it needs macOS Automation permission (REAPER→Terminal) and fails SILENTLY
  when that was never granted — the "Update/Setup does nothing" reports.
  Now: macOS `open`s a generated `.command` wrapper in `$TMPDIR` (no
  Automation permission, no Gatekeeper quarantine on a locally-written
  file); Windows uses `start "" "<script>"` (empty title so a spaced path
  isn't taken as the title) instead of the fragile nested-quote `cmd /k`.
  A `.command` target is `open`ed directly. The dialog now also prints the
  exact shell command as a manual fallback.
- `update.sh`/`update.bat`: `git pull --ff-only` failure (diverged / locally
  modified tracked files) no longer aborts the update — it falls back to the
  ZIP overlay (add/overwrite, never delete; gitignored venv/settings safe).

## v0.4 — Provided translation, track voice change, log tab, Windows

### Engine changes (all previous modes/flags/manifests unchanged)

- `--provided-script "<abs .txt>"` (run_dub.py + dub_engine.py). Valid with
  `--steps translate` and `--steps full` only (dub already takes `--script`;
  invalid with regen/voice-change). The UTF-8 file replaces the S2a–S2c LLM
  translation chain: S1a/S1b still run (sync needs the transcription and
  regions), the TM lookup is skipped, and the file's text is used verbatim
  as tr/rev/punc result (S2a–S2c log "skipped" lines). Read + validated
  BEFORE any paid API call. Everything downstream (review files, FinalScript,
  manifests) behaves exactly as if the LLM had produced that text.
- `--voice-change --in-wav "<abs>" --out-wav "<abs>" --language <Lang>
  [--voice-id ID] [--sts-model M]` — ElevenLabs speech-to-speech re-voice
  of an existing audio file (new pipeline helper
  `tts.voice_change_elevenlabs`). Voice resolution follows the same rule as
  every other mode (explicit id wins, else first language-matched account
  voice). Long inputs are split into ≤ ~4-minute chunks at the quietest
  point near the boundary, converted per chunk
  (`POST /v1/speech-to-speech/<voice>`, model default
  `eleven_multilingual_sts_v2`), joined, and written as WAV to --out-wav.
  Manifest: `{"status":"ok","vc_wav":"<abs>"}` (status-dir copy only — no
  out_dir of its own). Goes through run_dub.py like every mode (same
  status/log/pid/done plumbing); no LLM required.

### Panel changes

- Tabs: one TabBar with " Pipeline " (all phases) and " Log " (full live
  log + autoscroll + open-in-editor). The running phase shows progress,
  stage line and checklist WITHOUT the log, then the setup UI read-only
  (BeginDisabled) below it, so settings are never hidden by log output.
  Poll runs outside the tabs (switching tabs cannot stall a run). Fallback
  for tab-less ReaImGui: old inline layout.
- Per-language fonts: fonts are created+attached lazily PER SCRIPT and
  follow the language combo live. Candidates: user-installed Noto Sans/Serif
  per script, then macOS `/System/Library/Fonts/Supplemental/<Script> Sangam
  MN.ttc` (+ MT/Kohinoor variants, Arial Unicode fallback), Windows
  `Nirmala.ttf` (covers all 11 languages) + segoeui fallback. Dear ImGui
  still has no complex shaping — documented as cosmetic; the clipboard
  round-trip below is the supported perfect-rendering path.
- Review phase toolbar: 📋 Copy script (whole translation →clipboard via
  ImGui_SetClipboardText), 📋 Copy English, 📥 Paste script (clipboard
  replaces the whole translation, blank-line paragraph re-split), Open in
  editor (saves then opens `<base>_translation_edited.txt`), ⟲ Reload file
  (re-reads edited file, else the engine's translation_text).
- Setup phase: "I already have the translation" checkbox (persisted as
  `script_mode`: auto|have) + multiline paste box (+ paste-from-clipboard /
  clear buttons, paragraph+char count). On Run the text is written to
  `<out_dir>/<base>_provided_translation.txt` (out_dir mirrors
  `_prepare_output_dir` convention) and passed via `--provided-script`.
  Staged runs still pause for review (pairing check); full runs go
  straight through.
- 🎤 Change track voice section (setup + success phases): track combo
  (any project track), voice from the fetched catalogue and/or manual id
  (persisted as `vc_voice_id`; falls back to the Settings voice). Flow:
  render the track to `<project media path>/VoiceChange/<name>_<ts>.wav`
  via the render API (RENDER_SETTINGS=3 selected-track stems, custom
  bounds 0..last item end, mono, "evaw" format, action 42230, every
  touched setting saved/restored) → engine `--voice-change` → on ok, new
  track "<name> (voice changed)" inserted directly below the original with
  the result wav at position 0; the original track is MUTED, never
  modified. voice_change is a utility mode (returns to its origin phase,
  keeps manifests).
- English audio from a project track (setup phase): "From track" combo +
  "Use track" button next to the file picker. Resolution rule
  (audio_from_track): a track with exactly ONE item that is untrimmed
  (STARTOFFS≈0), unstretched (playrate≈1) and full-length (item length ≈
  source length ±50 ms) → the item's source FILE is used directly (section/
  reverse wrappers unwrapped via GetMediaSourceParent); anything else →
  the track is rendered (same render_track_stem helper) to
  `<project media path>/DubSource/<name>_<ts>.wav` and that wav is used.
  render_track_stem also temporarily unmutes the target track during the
  render (muted tracks render silent) and restores the mute state after.
- OS-aware setup hints: every error/hint names `setup_windows.bat` on
  Windows, `setup_mac.command` elsewhere.

### Repo

- `setup_windows.bat`: Windows twin of setup_mac.command (py-launcher
  discovery rejecting the Store alias, local venv, requirements install,
  selfcheck, ffmpeg check with winget offer, REAPER install steps,
  re-run safe, CRLF).

## v0.3 — Standalone app (GitHub-shareable, zero bulk-app dependency)

### Architecture

`dub_engine.py` no longer imports `Translation_and_Syncing_App`. All needed
logic is EXTRACTED (copied verbatim where possible, minimally adapted:
UI/global refs removed, settings paths repointed) into:

```
engine/pipeline/
  __init__.py
  config.py      # languages table, constants, ffmpeg discovery, settings loaders
  stt.py         # ElevenLabs Scribe STT + voice catalogue helpers
  srt_tools.py   # region detection, SRT builders, SpaCy chunking (optional dep),
                 # LLM input formats, timestamps txt read/write
  llm.py         # provider layer (vertex | gemini | openai-compatible),
                 # prompt loading, 3-step chain, emotion, EN<->target mapping
  tts.py         # ElevenLabs TTS (+ Google Cloud TTS port), chunkers, stitching
  sync.py        # sync engine (springs/bleed-over/order sweep), audio
                 # reassembly, captions rechunk
  tm.py          # translation_memory port (SQLite, data/ dir inside this repo)
prompts/         # copied from APP_DIR/prompts (all languages, 5 stages)
config/          # ALL user secrets/settings — entire dir gitignored
  llm_settings.json   # same schema as bulk app's llm_settings.json
  tts_settings.json   # {"elevenlabs_api_key","el_model","voice_id",
                      #  "google_tts_key_path"}
  vertex_key.json     # optional, user-provided
  TTS_Key.json        # optional, user-provided
data/            # translation_memory.db lives here (gitignored)
```

Provenance note: each pipeline module starts with a comment naming the source
file + line ranges it was extracted from.

### Engine changes

- All v0.1/v0.2 CLI modes keep IDENTICAL flags/manifests — panel unaffected
  except new flags below. `--app-dir` becomes OPTIONAL and IGNORED at runtime
  (accepted for backward compat, warning logged).
- Keys/settings resolution: `config/llm_settings.json` + `config/tts_settings.json`
  ONLY. Clear actionable error when missing ("run setup / open panel Settings").
  `openai_base_url` is an API base (host, or host + path such as `/v1`), never
  the chat-UI address and never with `/chat/completions` appended; the panel
  strips those on save. Optional `http_user_agent` overrides the engine's HTTP
  agent string for gateway calls (blank → browser default, needed because
  Cloudflare-fronted gateways reject `Python-urllib/*` with 403 / code 1010);
  `DUB_HTTP_USER_AGENT` in the environment does the same. The panel round-trips
  the key so a Settings save cannot drop it.
- Credentials are entered in ONE place: the panel's Settings tab. Every save also
  mirrors the shared keys into `<fast-syncs>/sync_pipeline_settings.json`
  (Auto Sync's own file, read by `run_sync.py`), touching only those keys —
  tracks, language, match mode, script text and `python_cmd` stay as Auto Sync
  left them. Vocabulary differs by design: `provider` here vs `conn_mode` there
  (`gemini`→`studio`, `openai`→`gateway`), and Auto Sync keeps both the Gemini
  key and the gateway Bearer token in one `gemini_key` field, so the mirror hands
  over whichever matches the selected provider. `run_sync.py` back-fills any
  credential missing from the sync file from `config/llm_settings.json`.
- `provider` may also be `"Server proxy (Auto Sync only)"` (alias `server`) with
  `server_url` + `server_token`: Auto Sync routes all AI calls through the user's
  own server. The engine has no server path, so every LLM entry point raises an
  actionable error instead of falling back to another provider's key.
- New modes (all through run_dub.py, same status/log/pid/done plumbing):
  - `--test-llm` → manifest `{"status":"ok","provider":"…","model":"…","reply":"…"}`
    (one tiny LLM call) or status error.
  - `--list-voices --language <Lang>` → manifest `{"status":"ok","voices":
    [{"id","name"},…]}` from ElevenLabs, language-token sorted like the app.
- `--selfcheck` reworked: imports pipeline modules (not the app), asserts
  required symbols + prompt files exist, prints SELFCHECK OK.

### Panel changes

- New ⚙ Settings section (collapsible, setup phase):
  - LLM: provider combo (vertex | gemini | openai) + model text field
    (default gemini-2.5-pro) + per-provider fields (gemini API key masked,
    vertex key path, openai base URL + key masked) + "Test connection" button
    (runs --test-llm, shows reply/error).
  - TTS: ElevenLabs key (masked), model combo (4 models), voice: "Fetch
    voices" button (--list-voices) filling a combo, manual voice-id fallback.
  - Panel WRITES config/llm_settings.json + config/tts_settings.json directly
    (same JSON-escape discipline as dub_panel_settings.json). Engine reads them.
- Engine location unchanged (sibling engine/). app_dir setting removed from
  UI (kept harmless in old settings files).

### Repo prep (GitHub-ready)

- `git init` in project root. `.gitignore`: `config/`, `data/`, `venv/`,
  `__pycache__/`, `engine/status/`, `*.pyc`, `.DS_Store`, `dub_panel_settings.json`.
- `requirements.txt` (engine deps only: numpy, librosa, pydub, google-genai,
  google-cloud-texttospeech, google-auth, pyphen; spacy optional — document).
  NO tkinter/matplotlib/sounddevice/opencv — nothing UI-related.
- `setup_mac.command` rewritten: creates LOCAL `venv/` in project root,
  pip-installs requirements, offers one-time key MIGRATION by copying (never
  moving) from the bulk app install if found at the known path (api.txt →
  tts_settings, llm_settings.json, vertex_key.json, TTS_Key.json, el_model.txt),
  prints REAPER script-install steps. Re-run safe.
- Python discovery order (panel + docs): project `venv/` FIRST, then old
  app-venv fallback (transition), then system candidates.
- README rewritten for a public audience: what it is, requirements, setup,
  keys (bring-your-own, stored only in gitignored config/), usage, file map,
  credits note that it's a REAPER port of an internal dubbing pipeline.

### Out of scope v0.3 (documented as roadmap)

Batch processing, TTS-Studio-style per-sentence editor, history/re-dub
manager, multi-speaker per-paragraph voices, prompt editor UI (prompts are
plain files — edit in any editor), updater/feedback systems.



## Fixed paths & names

- `APP_DIR` (default): `/Users/ilp/Documents/Claude code/Akash anna Translation and Syncing App_All`
- App module: `Translation_and_Syncing_App.py` (import as module — entry point is
  guarded by `if __name__ == "__main__"`, so importing never opens the Tk UI).
- App venv python (has ALL deps): `APP_DIR/.venv/bin/python3` (mac). Windows:
  `APP_DIR\.venv\Scripts\python.exe`.
- This project layout:
  ```
  Reaper Dubbing App/
    CONTRACT.md
    README.md
    setup_mac.command
    engine/
      run_dub.py          # launcher (env, tee log, pid, done marker)
      dub_engine.py       # worker: imports app module, runs pipeline
      engine_settings.json# written by setup: {"app_dir": "..."}
      status/             # created at runtime by run_dub.py
        engine_log.txt    # live tee of worker stdout+stderr
        engine_pid.txt    # worker PID (for cancel)
        engine_done.txt   # written LAST: single line = exit code
        engine_done.json  # copy of result manifest (also written to out_dir)
    reaper/                    # internal: loaded by auto_sync_pipeline.lua
      Dub_Pipeline_Panel.lua   # ReaImGui panel (run + poll + import)
      Import_Dub_Results.lua   # standalone importer (no ReaImGui needed)
  ```

## Engine CLI (Lua → Python)

```
"<python>" "<.../engine/run_dub.py>" --app-dir "<APP_DIR>" --audio "<audio path>" \
    --language <Language> [--voice-id <ELid>] [--el-model <model>] [--steps full]
```

Setup-time self-check (the ONLY supported direct `dub_engine.py` invocation —
used by `setup_mac.command`; all real runs go through `run_dub.py`):

```
"<python>" "<.../engine/dub_engine.py>" --selfcheck --app-dir "<APP_DIR>"
```

- `--selfcheck`: imports the app module headlessly and verifies every
  required module-level symbol exists — no network, no audio processing,
  no status files, no manifest. Prints `SELFCHECK OK` and exits 0 on
  success; non-zero on failure. `--audio`/`--language` are not required
  with this flag.
- `--language`: display name, one of: Bengali Hindi Kannada Malayalam Tamil
  Telugu Gujarati Marathi Assamese Odia Nepali
- `--el-model` default `eleven_v3`; `--steps` only `full` for v0.1.
- `run_dub.py`: stdlib only. Deletes old status files, spawns
  `dub_engine.py` via subprocess (same interpreter), tees combined
  stdout/stderr to `status/engine_log.txt` (line-buffered, utf-8), writes
  `status/engine_pid.txt` (its OWN pid pre-fork is useless — write the CHILD
  pid), on child exit writes `status/engine_done.txt` with exit code.
  No shell=True. Secrets never on the command line (keys come from APP_DIR
  files read by the app module itself: api.txt, llm_settings.json,
  vertex_key.json, TTS_Key.json — engine passes nothing).
- Progress protocol: worker prints lines `[S1a] message`, `[S2a] …` etc. —
  stage tags mirror the app's stages: S1a transcribe, S1b regions/SRT,
  S2a translate, S2b review, S2c punctuation, S2d TTS, S3a EN sync SRT,
  S3b TTS regions/SRT, S3c mapping, S3d sync, S3e render. Panel shows the
  last tag as current stage.
- Diagnostic lines from the pipeline modules carry a module tag instead of a
  stage tag — `[stt]`, `[LLM]`, `[config]`, `[engine]`. They are log-only and
  MUST NOT move the panel's stage: `stt.py` prints `[stt]` progress during
  both S1a and S3b, so a `[S1a]` tag there would drag the checklist backwards
  mid-dub.

## Result manifest — `engine_done.json`

Written by `dub_engine.py` to BOTH `<out_dir>/engine_done.json` and
`engine/status/engine_done.json`. UTF-8 JSON:

```json
{
  "status": "ok",              // or "error"
  "error": "",                 // traceback tail when status=error
  "audio": "<input audio abs path>",
  "language": "Bengali",
  "out_dir": "<abs path>",
  "en_audio": "<abs path to copied original audio inside out_dir>",
  "en_srt": "<abs>",           // <base>.srt
  "tts_wav": "<abs>",          // full TTS wav (dub voice, pre-sync)
  "timestamps_txt": "<abs>",   // <base>_sync_timestamps.txt
  "synced_wav": "<abs>",       // final synced wav
  "synced_srt": "<abs>"        // <base>_sync_synced.srt
}
```

Missing/not-produced files = "" (empty string). Consumers must skip empties.

## Timestamps file format (unchanged from app, line 1902 area)

```
[<idx>] [<orig_start>ms] [<orig_end>ms] [<orig_dur>ms] [<synced_start>ms]
```
Chunk audio source = `tts_wav`; item: STARTOFFS=orig_start, LEN=orig_dur,
POSITION=synced_start (all seconds in Reaper, file is ms).

## Import layout (both importers build the same thing)

Tracks appended at end of project, in order:
1. `EN Original` — one item, `en_audio`, position 0.
2. `Dub Chunks` — one item per timestamps line (source `tts_wav`, offsets per
   above). Item note = matching cue text from `synced_srt` (match by order;
   if counts differ, match by nearest start ≤0.5s; else leave note empty).
3. `Dub Rendered (ref)` — one item, `synced_wav`, position 0, track MUTED.
Regions: one per `synced_srt` cue (start/end/text). Wrap in one undo block.
All in Lua; SRT parser must handle CRLF, multi-line cue text (join with " "),
and UTF-8 Indic text (byte-safe string handling only).

## Panel behavior (`Dub_Pipeline_Panel.lua`)

Adapt proven patterns from `/Users/ilp/Documents/Claude code/fast syncs/auto_sync_pipeline.lua`
(READ-ONLY reference — do not modify that file):
- `imgui_available()` probe + ReaPack install guidance (copy pattern).
- Settings persist to `dub_panel_settings.json` next to the Lua script:
  app_dir, python_cmd override, language, voice_id, el_model, last_audio.
- Python discovery order: settings override → `app_dir/.venv` python →
  fast-syncs-style candidates (`probe_python` pattern).
- Launch non-blocking: Windows `reaper.ExecProcess(cmd, -2)`; macOS
  `os.execute(cmd .. ' >/dev/null 2>&1 &')` — run_dub.py owns log/pid/done.
- Poll in `reaper.defer` loop: tail `engine_log.txt` (read from last size),
  show stage from `[Sxx]` tags; when `engine_done.txt` appears → read
  `status/engine_done.json` → success/failure phase.
- Cancel button: kill pid from `engine_pid.txt` (`kill -9` / `taskkill /F /T`).
- Success phase: "Import to timeline" button → same import routine as
  `Import_Dub_Results.lua` (shared code duplicated is fine for v0.1).
- Audio file picker: `reaper.GetUserFileNameForRead`. Language: Combo of the
  11 languages. Voice id: plain text field (optional).
- Panel locates the engine via its own path: `reaper/` → sibling `engine/`.
  `app_dir` default from `engine/engine_settings.json`, fallback to the
  CONTRACT default above.

## v0.2 — Review pause + chunk regeneration

### Staged runs (script review between translation and dubbing)

`--steps` gains two values (old `full` stays and behaves as before):

- `--steps translate` — run S1a…S2c only (transcribe, regions/SRT, translation
  chain incl. punctuation; NO emotion, NO TTS). Write the app-convention
  outputs (EN SRT, `<base>_FinalScript.txt`, …) into out_dir, then write a
  REVIEW manifest to `engine/status/engine_done.json` AND
  `<out_dir>/engine_done.json`:

  ```json
  {
    "status": "review",
    "error": "",
    "audio": "…", "language": "…", "out_dir": "…",
    "en_srt": "<abs>",
    "en_text": "<abs>",          // plain-text EN transcript, paragraph per SRT chunk
    "translation_text": "<abs>", // plain-text translation, SAME paragraph count/order
    "final_script": "<abs>"      // <base>_FinalScript.txt (app format)
  }
  ```
  `en_text` / `translation_text`: UTF-8, one paragraph per line-block separated
  by ONE blank line — the panel renders EN left / translation right.
  Exit code 0. engine_done.txt written LAST as usual.

- `--steps dub --script "<abs path>"` — resume in the SAME out_dir (derive it
  from --audio exactly like a full run; the translate stage must have run
  first). `--script` points to the (possibly user-edited) translation text
  file (same blank-line paragraph format). Engine reads it, runs emotion
  enrichment (unless --no-emotion) + TTS + S3a…S3e, writes the normal
  v0.1 `"status":"ok"` manifest. Stale review manifests must be overwritten.

Panel flow: Run button now defaults to staged mode →
`--steps translate` → poll → on `"status":"review"` enter REVIEW phase:
side-by-side panes, EN read-only left, translation EDITABLE right
(ImGui InputTextMultiline, Indic font attached, per-paragraph rows aligned
where feasible). Buttons: "💾 Save" (write edited text to
`<out_dir>/<base>_translation_edited.txt`), "▶ Continue to Dubbing"
(save, then launch `--steps dub --script <edited file>`), "Skip edit"
(continue with engine-produced file). A "Full run (no review)" checkbox in
setup phase preserves old one-shot `--steps full` behavior.

### Chunk regeneration (like the app's Compare-view regen, but non-destructive)

Engine mode:
```
"<python>" run_dub.py --app-dir "…" --regen-chunk --language <Lang> \
    [--voice-id ID] [--el-model M] --text-file "<abs .txt>" --out-wav "<abs .wav>"
```
- `--text-file`: UTF-8 chunk text (never pass Indic text on argv).
- Engine synthesizes that text alone with the app's ElevenLabs helpers
  (same voice-resolution rule as v0.1), converts to WAV, writes `--out-wav`.
- Goes through run_dub.py like any run: same status dir, log, pid, done.txt.
  Manifest: `{"status":"ok","regen_wav":"<abs>"}` (or status error).
- No emotion pass on regen (text is already final; document if deviating).

Panel regen UI (post-import, success phase — and available any time via a
"Regen selected item" section): read the selected media item on a
"Dub Chunks*" track, load its item NOTE into an editable text box, user edits,
"⟳ Regenerate" → write text to `<out_dir>/regen/chunk_<n>.txt`, out-wav
`<out_dir>/regen/chunk_<n>_v<K>.wav` (K increments, never overwrite), launch
engine, poll as usual; on ok: in one undo block set the item's take source to
the new wav (PCM_Source_CreateFromFile + SetMediaItemTake_Source),
D_STARTOFFS=0, D_LENGTH=new source length (BR_GetMediaSourceProperties not
required — use reaper.GetMediaSourceLength), update the item note to the
edited text, UpdateArrange. Original synced wav and app files untouched.

## Hard rules

- NEVER write into APP_DIR. Engine must not update `projects.json`,
  `run_history.json`, or any app-owned state. Out_dir (next to the input
  audio) is app-convention output — allowed.
- dub_engine.py: import app module by adding APP_DIR to sys.path; call its
  MODULE-LEVEL functions; never instantiate `EndToEndApp`, never import
  tkinter-touching entry paths beyond what module import itself does.
  Set `matplotlib.use("Agg")` BEFORE importing the app module.
- All Lua: version-safe ReaImGui calls (pcall wrappers like the reference),
  two-arg `GetMediaSourceFileName(src, "")`, `AddProjectMarker2(0, true, ...)`.
- macOS primary target; keep Windows branches where the reference has them.
