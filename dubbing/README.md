# Reaper Dubbing App

> **Bundled with fast-syncs** (v0.6): this app lives in the `dubbing/`
> folder of the fast-syncs repo and arrives / stays current through the
> same **Update…** button as the sync tool. `auto_sync_pipeline.lua` in the
> repo root is the only script you load in REAPER — it opens this panel
> directly, with the sync tool as its **Auto Sync** tab. The files under
> `dubbing/reaper/` are internal and are not meant to be loaded by hand.

Automatic voice dubbing for [REAPER](https://www.reaper.fm/): take an English
voice recording, and get a translated, voice-synthesized, time-synced dub in
one of 12 Indian languages — imported straight onto your REAPER timeline as
editable chunks.

The pipeline: **transcribe** (ElevenLabs Scribe) → **translate + review +
punctuation** (your choice of LLM) → **text-to-speech** (ElevenLabs) →
**time-sync** the dub to the original speech → **import** to the timeline.
A ReaImGui panel drives everything from inside REAPER, including a pause for
human review of the translation before any TTS cost is spent.

Supported target languages: Assamese, Bengali, Gujarati, Hindi, Kannada,
Malayalam, Marathi, Nepali, Odia, Punjabi, Tamil, Telugu.

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
    That base URL is an **API base** — `https://host` or `https://host/v1`, not
    the chat UI's browser address and never with `/chat/completions` appended.
    A bare host gets `/v1/chat/completions`; a base that already has a path
    (`/v1`, `/api/v1`, `/v1beta/openai`) is used as-is with `/chat/completions`
    appended, so OpenAI, OpenRouter, LiteLLM, vLLM, Open WebUI and Gemini's
    OpenAI-compatible layer all work. Azure OpenAI is **not** supported — its
    URL shape and auth header differ.
  - optional: a Google Cloud TTS service-account JSON.

## Installation

The app ships inside the fast-syncs repo — if you have fast-syncs, you
already have the files (click **Update…** in the panel's Settings tab if
`dubbing/` is missing).

**Setup is automatic.** The fast-syncs updater (`update.bat`/`update.sh`)
and installers (`setup.bat`/`setup.sh`) run the dubbing setup in `--auto`
mode: create `dubbing/venv`, install the Python dependencies, install
**ffmpeg** when missing (winget on Windows, with a portable-build fallback
into `ffmpeg\bin\`; Homebrew on macOS), and run an engine self-check — no
prompts. If the panel ever opens before that ran, it starts the same setup
itself in a terminal, once.

Manual fallback (safe to re-run any time):

### macOS

```
cd "<fast syncs>/dubbing"
bash setup_mac.command
```

### Windows

**Double-click `dubbing\setup_windows.bat`** (or run it from a terminal).

Then, in REAPER (both platforms):

1. Actions → Show action list → New action → **Load ReaScript…**
2. Pick `auto_sync_pipeline.lua` from the fast-syncs root — the one entry
   point for both tools. Nothing under `reaper/` needs loading.
3. Load it **in place** — do not copy it into REAPER's `Scripts/` folder.
   Each script finds the engine relative to its own location.

Fallback: if ReaImGui cannot be installed on this machine, the panel will not
open. `reaper/Import_Dub_Results.lua` still imports a finished run on its own
(plain REAPER API, no ReaImGui) — load that one directly in that case only.

### First run on a new Mac

If this folder arrived as a zip or download, macOS may block the
double-click on `setup_mac.command`. Any one of these fixes it:

- Right-click (Ctrl-click) → **Open** → **Open** (one-time Gatekeeper bypass), or
- `xattr -d com.apple.quarantine setup_mac.command && chmod +x setup_mac.command`, or
- just run `bash setup_mac.command` from Terminal.

## API keys and privacy

Open the panel and go to **⚙ Settings → Connections**. Every API the app talks
to has a row there — the OpenAI-compatible gateway, Gemini, Vertex AI, the
server proxy, and ElevenLabs — and each row says whether its key works and
which models that key serves.

- **Paste a key and it checks itself.** About a second after you stop typing,
  the row asks that API whether the key is valid (one HTTP call, nothing
  blocks) and reports back: *valid · 14 models available*, *key rejected (HTTP
  401)*, or what went wrong. No button to press.
- **The model list comes from the key.** A validated key fills that provider's
  Model dropdown with the ids it can actually serve; the built-in list stays
  below it, and **Custom** still turns the dropdown into a text box for an id
  nobody advertises. If your saved model is not one the key serves, the row
  says so and offers the one it detected.
- **Every key field has its own eye.** Click it to read that key in plain text,
  click again to mask it. One field at a time, and never remembered across
  launches.
- **Used for AI** at the top (or **Use for AI** on any row) picks which
  provider translates, reviews and maps. **Test connection** at the bottom is
  the end-to-end proof: one real LLM call through the engine with the model you
  selected.

Voice work moved to the **Tools** tab → **Voices**: the ElevenLabs model,
**Fetch voices** for the selected language, auditioning, and the default voice
every stage falls back to. A manual voice-id field is always available as a
fallback. Only the ElevenLabs *key* stays in Connections, with the other
credentials.

**Settings → Connections is the only place credentials are entered.** The
**Auto Sync** tab
uses the same keys and has no fields of its own — every save mirrors the shared
ones (provider, model, keys, gateway URL, ElevenLabs key, server URL + token)
into `sync_pipeline_settings.json` next to `run_sync.py`, leaving Auto Sync's own
settings — track names, language, match mode, script text — untouched. Launching
Auto Sync as its own REAPER action still shows the full fields, since the
Settings tab isn't there to read from.

`server` is the exception to "one provider for everything": it means *Auto Sync
routes AI calls through your own server*, which the dubbing engine cannot do.
Pick it and dub runs stop with a message saying exactly that; Auto Sync keeps
working. For dubbing, choose `vertex`, `gemini` or `openai`.

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
   - **Or take it off a track → Use** — take it straight from the
     timeline, no file browsing.

   **The timeline decides how much gets dubbed.** Trim an item to the two
   minutes you want and only those two minutes are transcribed, translated
   and spoken — you are not billed for the rest of the talk. What **Use**
   would take, most specific first:

   1. the **time selection**, if you dragged one (clamped to the track, so a
      selection past the end of the talk never renders silence),
   2. the **item(s) you selected** — which also say which track, so the
      picker can stay on *(from track)*,
   3. everything the chosen track holds.

   The line under the picker says which, live, while you trim — and turns
   **amber** while the audio in the field is not that span, because pressing
   Run without pressing Use is how the whole file gets dubbed by accident.
   A whole untrimmed item at 0:00 uses its source file directly; anything
   else is rendered to `<project path>/DubSource/` first.

   The span is remembered next to that wav, so the dub is **imported back
   where it came from** — a region taken from 2:00 lands at 2:00, under the
   item it was made for, not at 0:00 — and ▶ Play here on the review screen
   plays the right part of the talk.
3. **Already have the translation?** Use the **Paste Translation** tab:
   pick the audio + language there and paste the translated script (one
   blank line between paragraphs — **📥 Paste from clipboard** works too).
   The engine then skips the LLM translation entirely: it transcribes the
   English once, **Gemini-matches your script's sentences to the English
   lines**, speaks the script in long natural stretches, and cuts the audio
   into **small pieces** at the exact times ElevenLabs itself reports —
   at every sentence end, and inside a long sentence at its `;` `:` `,` or
   dash, so no piece runs much over four seconds. Each piece lands on its
   own English line. Pieces with no English home (or no room) go to the
   **Un sync** track as single short clips, easy to drag into place — the
   same behaviour as Auto Sync. Piece size is switchable in Settings →
   Advanced → *Dub piece size* (**clause** by default, or *sentence*, or
   *thought* for the old one-block-per-idea behaviour).

   **🔍 Preview sync — see the drift before spending any credits.** With a
   script pasted, the **🔍 Preview sync** button next to Run does a free dry
   run instead of a dubbing run. It listens to the source audio for where
   the speaker actually stops and starts, cuts it into chunks at those
   pauses, spreads your script across them, and estimates how long each
   line will take to speak from its character count and the language's
   speaking rate. Nothing is generated and nothing is billed — the only
   network call is the transcription, and that is cached on disk, so you
   can preview as many times as you like.

   You get two files next to the audio:

   - `<name>_sync_plan.html` — **🌐 Open preview** opens it in your browser.
     Source speech on the top lane, the estimated dub on the bottom lane,
     both on one time axis with the pauses drawn hatched. Where a coloured
     bar sticks out past its grey bar, that is exactly where the dub will
     drift. Green fits, amber eats into the pause, **red overflows**.
   - `<name>_sync_plan.txt` — the same thing as editable text. **📝 Edit
     plan** opens it; change any `TR:` line (shorten an overflowing one,
     move a sentence to the chunk it belongs in), save, and press
     **⟲ Reload**. Free, and as many times as you want. Only the `TR:`
     lines are read back — the timings always come from the audio, so a
     stray edit to a timestamp cannot desync anything.

   When it looks right, **▶ Approve & Generate**. That is the only step
   that spends credits. Each chunk is synthesized and laid down at *its own
   original timestamp*, so the dub keeps the source's rhythm exactly; a
   chunk that still runs long is sped up (pitch preserved) to fit, up to a
   ceiling of 1.25× by default. Anything that would need more than that is
   left alone and named in the log rather than squashed into mush — shorten
   its line and preview again. Nothing lands on **Un sync** in this mode:
   every chunk already has a home.

   Tuning lives in `engine/engine_settings.json` — `pause_min_ms` (200; the
   shortest gap that counts as a pause), `pause_thr_db` (−42; the silence
   floor), `max_atempo` (1.25) and `plan_rate_override` (force a chars/sec
   rate if the estimate reads slow or fast for your voice).

   The rail down the left has five destinations: **Dub** (the whole run —
   the LLM translates and pauses for your review, or you paste your own
   script), **Sync** (the fast-syncs clip-matching pipeline, embedded right
   in this window — its own settings live inside it), **Tools** (four voice
   utilities behind one row of chips: Voices, Text to speech, Redo one line,
   Re-voice a track — see below), **Log** (full live log) and **Settings**
   (connections, models, prompts, advanced, about).

   **Voice bookmarks.** Anywhere you pick a voice — any of the Tools —
   there is a search box and a **☆ Bookmark this
   voice** button. Starred voices sit at the top of the list with a ★ and
   stay there across projects, languages and restarts, so you never scroll
   the whole account catalogue again. Bookmarks are saved in
   `reaper/voice_bookmarks.json` on your machine only.

   **A model per stage** (⚙ Settings → *Model per stage*). By default every
   AI call uses the one **Model** field. Pick a model in a stage's dropdown
   to give just that stage its own — a fast, cheap one for the mechanical
   work (matching, emotion tags) and the strong one for translation. Stages:
   Translate, Emotion tags, Dub matching, Legacy sync map, and Auto Sync
   match (handed to the Auto Sync tab when you save). *same as Model* = use
   the main Model, which is what every existing setup already does.

   **Add a language** (⚙ Settings → *Languages*). Type a name, optionally a
   locale code, pick an existing language to copy prompts from, and click
   **Add language**. The new language appears in every language dropdown
   immediately. Copying the prompts gives you a working starting point —
   open the **Prompts** section afterwards and edit them so they name the
   right language. Removing a language leaves its prompt files alone.

   **Edit the prompts** (⚙ Settings → *Prompts*). Pick a language and a
   stage to see the exact instructions sent to the AI, edit them in place,
   and **💾 Save**. **Open in editor** saves first, then opens the file in
   your normal text editor — easier for long prompts and for languages
   whose script REAPER cannot shape properly.
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
     Gemini section matching, per-section TTS and placement (stages
     S2d–S3e).
   - **Skip edit** — continues with the engine's own translation.
   - **Back to setup** — the paused run is kept; the setup phase offers
     **Resume review** (it even survives closing the panel).

   **🎙 Cast — the ElevenLabs voices, chosen here.** The chip row beside
   List/Grid is the cast: the first speaker is the **main voice** (the one
   the run is launched with, and the one every paragraph you do not
   re-assign is spoken by), and you can add up to eight more.

   - Open **🎙 Cast** to name each speaker, pick its voice from your
     ElevenLabs catalogue (**⟳ Fetch voices** fills the combos), audition it
     with **🔊**, or promote another speaker to main with **⇧ main**.
   - Press a speaker's chip to make it *active*, then click the coloured
     chip on any paragraph to cast that line to it. The right-hand
     inspector has the same choice as a list, for the selected paragraph.
   - **🔎 Detect speakers** reads `Name:` labels off the English column and
     casts those paragraphs for you. It never edits the script — including
     the labels, which ElevenLabs would otherwise read aloud.
   - The casting is saved with your edits as
     `<out_dir>/<base>_speakers.json`, so a resumed review comes back with
     the same cast. A single-voice run writes no such file.
   - **Continue** refuses while a speaker that has paragraphs has no voice —
     that is a line nobody could speak, and it costs nothing to fix here.

   The engine speaks each paragraph in its cast voice: in match sync mode
   one request per run of same-voice pieces, in legacy sync mode one request
   per run of same-voice paragraphs. Emotion enrichment (legacy mode) is
   checked against the paragraph count first — if it changed, the cast is
   reported as unusable rather than applied to the wrong lines.

   Tick **Full run (no review)** in the setup phase for the one-shot
   behavior with no pause.

   > Indic conjuncts can look re-ordered *inside REAPER* (the UI toolkit
   > has no complex text shaping) — this is cosmetic only and never
   > affects the audio. For a perfectly rendered view use Copy → edit
   > anywhere → Paste, or Open in editor → ⟲ Reload file.
6. On success, click **Import to timeline**. Appended to your project, in
   one undo block:
   - **EN Original** — the original audio at position 0.
   - **Dub Chunks** — one item per synced chunk, at the position of the
     English line it matched. Each item carries its script text invisibly
     (no note text over the waveform, no regions): select the item and the
     **Regen Audio** tab loads that text for editing.
   - **Un sync** — chunks that had no English match (or no room to fit in
     order) sit here for manual placement, side by side — the same track
     Auto Sync uses. The success screen shows the synced/unsynced counts.
   - **Dub Rendered (ref)** — the synced-only render, as a muted reference.

   `Import_Dub_Results.lua` can also import any finished run on its own
   (no ReaImGui needed).

   **Project history**: the setup screen lists this REAPER project's past
   runs — **Resume review** a paused run or **Import to timeline** a
   finished one at any time, with no re-transcription / re-translation.
   The app version is in the panel's title bar and Settings tab.
7. **Fix single lines** — **Tools → Redo one line**. Select a chunk item on a
   "Dub Chunks" track and the panel shows it in context: which chunk it is
   (*47 of 148*), the slot it has to land in, and the lines either side of it.
   Edit the text and a **fit meter** says, before you spend anything, whether
   the new line will still fit — the speaking rate is measured from that
   chunk's own text and duration, so it is this speaker, this language, this
   project. Too long turns it amber, because in Match mode an overrunning
   chunk is parked on the Un sync track.
   **⟳ Regenerate this line** synthesizes just that text and swaps the item's
   take source to the new wav. Non-destructive on disk (files land in
   `<out_dir>/regen/` with version suffixes) *and* on the timeline: afterwards
   you can play the new take, play the one it replaced, then **Keep it** or
   **Put the old one back**.
   **Redo it in a different voice** re-does the same chunk in another
   ElevenLabs voice — same bookmarks + search as everywhere else, or paste a
   voice id. **⟳ Fetch voices** pulls your account's catalogue for the current
   language right there, cached in `reaper/voice_cache.json` so it is already
   filled next time. **🔊 Test voice** auditions the pick before you spend a
   regen on it: the start of the selected chunk is synthesized in that voice
   and played straight away — nothing imported, no item touched, and pressing
   it again with the same voice and text replays the sample instead of calling
   ElevenLabs twice (samples live in `engine/preview/`, newest one only).
   Leave the voice empty and regeneration uses the default voice. The choice
   sticks, so several chunks can be redone in the new voice one by one.
8. **Change the voice of a whole track** — **Tools → Re-voice a track**. The
   project's tracks are listed with their item count and length, so you can
   tell "EN Original" from "Dub Chunks" at a glance. Pick one, pick a voice,
   and the panel writes out what will happen in a sentence — which track, how
   long, which voice, what the new track will be called — before you press
   **Convert**. The track is rendered to a wav, converted with the ElevenLabs
   voice changer (speech-to-speech — timing and pacing are kept, so a synced
   dub stays synced), and imported as a new track directly below the original.
   The original track is muted but never modified. Files land in
   `<project path>/VoiceChange/`.
9. **Just speak some text** — **Tools → Text to speech**. Paste (or type) any
   text; beside the box the panel shows who will speak it, where it lands (the
   `TTS` track, at the edit cursor's timecode) and what it will cost, and the
   button repeats it: *Speak it in Priya S — ~8 s, ~128 credits*. Both numbers
   are local estimates (≈15 characters a second, 1 credit a character), not a
   quote from ElevenLabs. The audio is dropped straight onto the `TTS` track
   with the spoken text kept in the item's note. No transcription, no
   translation, no syncing — the plain "say this in that voice" tool. Files
   land in `<project path>/TTS/`, so save the project first.
   **Recent** keeps the last eight generations (in `reaper/tts_history.json`):
   play one, drop it in again at the cursor, or open its folder — re-inserting
   a line you already paid for never costs a second synthesis.
10. **Sync dubbed clips to the English timeline** — the **Auto Sync** tab is
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
  reaper/                   internal — loaded FOR you by
                            auto_sync_pipeline.lua, not by hand
    Dub_Pipeline_Panel.lua  ReaImGui panel: settings, run, review, import,
                            chunk regeneration
    Import_Dub_Results.lua  standalone importer (no ReaImGui needed) — the
                            one file here you may load directly
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
- **mp3 decode / "ffmpeg not found" errors** — re-run the setup script
  (`setup_windows.bat` / `setup_mac.command`): it installs ffmpeg
  automatically (winget → portable fallback on Windows, Homebrew on macOS).
  The engine now also refuses to start a dub run without ffmpeg, so this
  can no longer surface mid-run after the LLM/TTS spend. Manual install:
  `winget install -e --id Gyan.FFmpeg` / `brew install ffmpeg`, or unzip a
  build to `ffmpeg\bin\` inside the `dubbing\` folder.
- **💾 / ▶ / ⟳ render as boxes** — the default ImGui font lacks those glyphs
  on some systems; the buttons still work.

## Roadmap (not in v0.3)

- Batch processing of multiple files
- Per-sentence TTS editor (studio-style)
- History / re-dub manager
- Prompt editor UI (prompts are plain files — edit them in any editor)
- Feedback systems (updating is handled by the fast-syncs **Update…**
  button since v0.5)

## Credits

This project is a REAPER port of an internal dubbing pipeline; the engine
logic was extracted into the standalone `engine/pipeline/` package so the
whole thing runs with nothing but this repository, Python and your own API
keys.
