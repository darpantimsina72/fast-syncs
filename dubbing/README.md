# Reaper Dubbing App

> **Bundled with fast-syncs** (v0.5): this app lives in the `dubbing/`
> folder of the fast-syncs repo and arrives / stays current through the
> same **Update…** button as the sync tool. Open it from the sync window's
> **Dubbing...** button, or load `dubbing/reaper/Dub_Pipeline_Panel.lua`
> as a REAPER action.

Automatic voice dubbing for [REAPER](https://www.reaper.fm/): take an English
voice recording, and get a translated, voice-synthesized, time-synced dub in
one of 11 Indian languages — imported straight onto your REAPER timeline as
editable chunks.

The pipeline: **transcribe** (ElevenLabs Scribe) → **translate + review +
punctuation** (your choice of LLM) → **text-to-speech** (ElevenLabs) →
**time-sync** the dub to the original speech → **import** to the timeline.
A ReaImGui panel drives everything from inside REAPER, including a pause for
human review of the translation before any TTS cost is spent.

Supported target languages: Bengali, Hindi, Kannada, Malayalam, Tamil,
Telugu, Gujarati, Marathi, Assamese, Odia, Nepali.

## Requirements

- **macOS or Windows**
- **Python 3.11+**
  - macOS: `brew install python`
  - Windows: `winget install -e --id Python.Python.3.12` (or python.org —
    tick *Add python.exe to PATH*)
- **ffmpeg** (audio conversion/stitching)
  - macOS: `brew install ffmpeg`
  - Windows: `winget install -e --id Gyan.FFmpeg` (the setup script offers
    to do this for you)
- **REAPER** with the **ReaImGui** extension (free, via ReaPack — the panel
  offers to install it for you on first run)
- **Your own API keys** (bring-your-own, entered in the panel's Settings):
  - an **ElevenLabs** key (speech-to-text + text-to-speech + voice changer), and
  - one **LLM provider**: a Gemini API key, a Google Vertex AI
    service-account JSON, or any OpenAI-compatible endpoint (base URL + key).
  - optional: a Google Cloud TTS service-account JSON.

## Installation

The app ships inside the fast-syncs repo — if you have fast-syncs, you
already have the files (click **Update…** in the sync window if `dubbing/`
is missing). Then run the one-time setup:

### macOS

```
cd "<fast syncs>/dubbing"
bash setup_mac.command
```

### Windows

**Double-click `dubbing\setup_windows.bat`** (or run it from a terminal).

The dubbing panel also offers to run this setup for you the first time you
click Run without a venv.

Both setup scripts do the same thing: create a local `venv/`, install the
Python dependencies from `requirements.txt`, run an engine self-check, and
print the REAPER steps below. They are safe to re-run at any time.

Then, in REAPER (both platforms):

1. Actions → Show action list → New action → **Load ReaScript…**
2. Pick **both** files from the `reaper/` folder:
   `Dub_Pipeline_Panel.lua` and `Import_Dub_Results.lua`.
3. Load them **in place** — do not copy them into REAPER's `Scripts/`
   folder. The panel finds the engine relative to its own location.

### First run on a new Mac

If this folder arrived as a zip or download, macOS may block the
double-click on `setup_mac.command`. Any one of these fixes it:

- Right-click (Ctrl-click) → **Open** → **Open** (one-time Gatekeeper bypass), or
- `xattr -d com.apple.quarantine setup_mac.command && chmod +x setup_mac.command`, or
- just run `bash setup_mac.command` from Terminal.

## API keys and privacy

Open the panel and expand **⚙ Settings**:

- **LLM** — pick a provider (`vertex` / `gemini` / `openai`), set the model
  (default `gemini-2.5-pro`) and the provider's credentials. Key fields are
  masked (a "Show keys" checkbox reveals them). **Test connection** makes
  one tiny LLM call and shows the reply.
- **TTS** — your ElevenLabs key, the ElevenLabs model, and the voice.
  **Fetch voices** pulls the voice catalogue for the selected language into
  a combo; a manual voice-id field is always available as a fallback.

Settings are written to `config/llm_settings.json` and
`config/tts_settings.json`, and re-written automatically before every run.

**Everything in `config/` and `data/` stays on your machine.** Both folders
are gitignored, so keys, service-account files and the local translation
memory database can never end up in a commit. Keys are read by the engine
from those files only — they are never placed on a command line.

## Usage

1. Run the **Dub Pipeline Panel** action.
2. Pick the English audio and the target language. (Voice and models live
   in ⚙ Settings.) Two ways to pick the audio:
   - **Browse…** — pick a file on disk, or
   - **From track → Use track** — take it straight from a project track,
     no file browsing. A track holding one clean item uses that item's
     source file directly; anything else (chunks, trims, offsets) is
     rendered to `<project path>/DubSource/` automatically and that wav
     is used.
3. **Already have the translation?** Use the **Paste Translation** tab:
   pick the audio + language there and paste the translated script (one
   blank line between paragraphs — **📥 Paste from clipboard** works too).
   The engine then skips the LLM translation entirely and goes straight to
   TTS + sync; the audio is still transcribed once because the sync stages
   need the timings.

   The panel has seven tabs (v0.5): **Full Pipeline** (the LLM translates —
   pauses for your review), **Paste Translation** (your script),
   **Auto Sync** (the fast-syncs clip-matching pipeline, embedded right in
   this window — its own settings live inside the tab), **Regen Audio**
   (re-synthesize one selected chunk), **Track Voice** (re-voice a whole
   track), **Logs** (full live log) and **Settings** (keys, python
   override, updater).
4. Click **▶ Run dubbing pipeline**. By default this is a **staged run**:
   the engine transcribes and translates (stages S1a–S2c), then pauses.
   Progress and the stage checklist stay on the **Full Pipeline** tab; the
   full live log is on the **Logs** tab.
5. **Review** — the panel shows a side-by-side editor: English transcript
   read-only on the left, translation editable on the right (rendered with
   a system font matching the language's script). Buttons:
   - **📋 Copy script / 📋 Copy English** — copy the whole translation (or
     the transcript) to the clipboard in one click.
   - **📥 Paste script** — replace the whole translation with the
     clipboard (edit it in any external editor and paste it back).
   - **Open in editor / ⟲ Reload file** — the same round-trip through the
     saved file and your default text editor.
   - **💾 Save** — writes your edits to
     `<out_dir>/<base>_translation_edited.txt`.
   - **▶ Continue to Dubbing** — saves, then resumes with the edited text:
     emotion enrichment, TTS and the sync chain (stages S2d–S3e).
   - **Skip edit** — continues with the engine's own translation.
   - **Back to setup** — the paused run is kept; the setup phase offers
     **Resume review** (it even survives closing the panel).

   Tick **Full run (no review)** in the setup phase for the one-shot
   behavior with no pause.

   > Indic conjuncts can look re-ordered *inside REAPER* (the UI toolkit
   > has no complex text shaping) — this is cosmetic only and never
   > affects the audio. For a perfectly rendered view use Copy → edit
   > anywhere → Paste, or Open in editor → ⟲ Reload file.
6. On success, click **Import to timeline**. Appended to your project, in
   one undo block:
   - **EN Original** — the original audio at position 0.
   - **Dub Chunks** — one item per synced chunk, freely draggable; each
     item's note holds the matching subtitle cue text.
   - **Dub Rendered (ref)** — the final synced wav, as a muted reference.
   - **Regions** — one region per subtitle cue.

   `Import_Dub_Results.lua` can also import any finished run on its own
   (no ReaImGui needed).
7. **Fix single lines with chunk regeneration** — go to the **Regen Audio**
   tab, select a chunk item on a "Dub Chunks" track, edit the item's text,
   click **⟳ Regenerate**. The engine synthesizes just that text and the
   panel swaps the item's take source to the new wav — non-destructively,
   new files only ever land in `<out_dir>/regen/` with auto-incrementing
   version suffixes.
8. **Change the voice of a whole track** — go to the **Track Voice** tab,
   pick any project track and a target ElevenLabs voice, click **🎤 Change
   voice**. The track is rendered to a wav, converted with the ElevenLabs
   voice changer (speech-to-speech — timing and pacing are kept, so a synced
   dub stays synced), and imported as a new track directly below the
   original. The original track is muted but never modified. Files land in
   `<project path>/VoiceChange/`.
9. **Sync dubbed clips to the English timeline** — the **Auto Sync** tab is
   the full fast-syncs pipeline embedded in this window: it reads your
   Dialogue VO + Dub tracks, AI-matches every clip, and snaps each dubbed
   clip to its English line. Its settings (tracks, connection mode, keys)
   live inside the tab. Same tool as the standalone Auto Sync action — just
   no second window to juggle.

Outputs go to a folder next to your input audio. Progress and a Cancel
button are live on the Full Pipeline tab during every run; the full log is
on the Logs tab.

## Two projects at the same time

One REAPER instance runs one dub at a time (the panel is one script
instance). To dub a **second project in parallel**, open a second REAPER
instance — macOS: `open -na REAPER`, Windows: `reaper.exe -newinst` — open
the other project there and run the panel again. Each project gets its own
status folder under `engine/status/<project>_<hash>/` (v0.5), so the two
runs never mix up their logs, progress or results. Keep in mind both runs
share your ElevenLabs/LLM account rate limits, and each import goes to the
project the run was started from.

## File map

```
dubbing/                    (inside the fast-syncs repo)
  README.md                 this file
  CONTRACT.md               interface spec (panel <-> engine)
  setup_mac.command         one-time macOS setup (re-run safe)
  setup_windows.bat         one-time Windows setup (re-run safe)
  requirements.txt          engine Python dependencies
  engine/
    run_dub.py              launcher: log tee, PID file, done marker
    dub_engine.py           worker: runs the pipeline, writes the manifest
    pipeline/               the pipeline itself (config, stt, srt_tools,
                            llm, tts, sync, tm)
    status/                 runtime files (gitignored)
  prompts/                  LLM prompt files per language and stage —
                            plain text, edit in any editor
  reaper/
    Dub_Pipeline_Panel.lua  ReaImGui panel: settings, run, review, import,
                            chunk regeneration
    Import_Dub_Results.lua  standalone importer (no ReaImGui needed)
  config/                   your keys and settings (gitignored, created on
                            first save)
  data/                     translation memory database (gitignored)
```

## Troubleshooting

- **"ReaImGui not installed"** — accept the panel's automatic install offer,
  or install ReaImGui via ReaPack, then restart REAPER.
- **"Project venv not found"** — run `setup_mac.command` /
  `setup_windows.bat` once, or set a Python override in the panel's
  Advanced section.
- **LLM or TTS errors** — use **Test connection** in ⚙ Settings; check the
  **Log** tab (the same text is at `engine/status/engine_log.txt`). The
  final result and error tail are in `engine/status/engine_done.json`.
- **Devanagari / Indic text looks distorted in the panel** — the panel
  picks a system font for the selected language automatically (macOS
  "Sangam MN" family, Windows "Nirmala UI"), but the UI toolkit cannot
  shape conjuncts/matras perfectly. This is display-only: the script files
  and the audio are always correct. Use **📋 Copy script** →  edit in any
  editor → **📥 Paste script** (or **Open in editor** → **⟲ Reload file**)
  for a perfect view. Installing Noto Sans fonts for your script improves
  in-panel rendering further.
- **mp3 decode / "ffmpeg not found" errors (Windows)** — install ffmpeg:
  `winget install -e --id Gyan.FFmpeg` (or unzip a build to `ffmpeg\bin\`
  inside the project folder), then re-run.
- **💾 / ▶ / ⟳ render as boxes** — the default ImGui font lacks those glyphs
  on some systems; the buttons still work.

## Roadmap (not in v0.3)

- Batch processing of multiple files
- Per-sentence TTS editor (studio-style)
- History / re-dub manager
- Multi-speaker per-paragraph voices
- Prompt editor UI (prompts are plain files — edit them in any editor)
- Feedback systems (updating is handled by the fast-syncs **Update…**
  button since v0.5)

## Credits

This project is a REAPER port of an internal dubbing pipeline; the engine
logic was extracted into the standalone `engine/pipeline/` package so the
whole thing runs with nothing but this repository, Python and your own API
keys.
