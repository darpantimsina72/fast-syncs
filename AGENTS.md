# AGENTS.md — fast-syncs

Read this before changing anything. It is short on purpose; deeper material
lives in `.claude/skills/` (loaded on demand) and in the existing
`HOW_IT_WORKS.md`, `README.md`, `dubbing/README.md`, `dubbing/CONTRACT.md`.

> **On the line numbers below:** they were accurate when written and are there
> to get you to the right neighbourhood, not to be trusted blindly. Any commit
> that inserts lines shifts them. Search for the named function or string
> instead — every citation here names one — and treat a line number that no
> longer matches as a stale reference rather than a missing feature.

---

## What this is

Two automation tools that live inside **REAPER** (an audio DAW) and do the
manual parts of dubbing English video into 11 Indian languages.

- **Auto Sync** — you already have English clips and dubbed clips on two
  tracks. It transcribes every clip, asks Gemini which dubbed clip means the
  same thing as which English clip, and moves each dubbed clip to its English
  clip's position on the timeline.
- **Dubbing app** — you only have English audio. It transcribes, translates,
  pauses for a human to read the translation, then synthesizes speech and
  places it the same way.

Both run in **one REAPER window** with four tabs. `auto_sync_pipeline.lua` is
the only script a user loads.

The author is not a professional developer. Prefer small, obvious, well-
commented changes over refactors. Almost every defensive-looking check in this
codebase is there because it broke on somebody's machine.

---

## Architecture: Lua draws, Python thinks, files carry

REAPER's Lua cannot do HTTP or long work without freezing the UI. So the Lua
half writes a JSON file, launches a detached Python process, and polls a log
file until a "done" marker appears.

```
REAPER
 └─ auto_sync_pipeline.lua ── EMBED module ──► dubbing/reaper/Dub_Pipeline_Panel.lua
      │  writes sync_config.json                  │  writes argv (no secrets)
      │  launches (detached)                      │  launches (detached)
      ▼                                           ▼
    run_sync.py  ── reads settings JSON ──►     dubbing/engine/run_dub.py
      │            sets SYNC_* env                │  sets DUB_STATUS_DIR
      ▼                                           ▼
    sync_matcher.py                             dubbing/engine/dub_engine.py
      ElevenLabs Scribe (transcribe)              └─ engine/pipeline/*.py
      Gemini (one call, semantic match)              stt / llm / tts / match / sync
      spring placement + order sweep
      │                                           │
      └─ writes sync_results.json ──► Lua moves items in one undo block
```

**Two independent instances of the same pattern**, one per tool. They do
**not** share a venv, a launcher, or a status folder.

| | Auto Sync | Dubbing |
|---|---|---|
| Lua | `auto_sync_pipeline.lua` (2316 lines) | `dubbing/reaper/Dub_Pipeline_Panel.lua` (6409 lines) |
| Launcher | `run_sync.py` | `dubbing/engine/run_dub.py` |
| Worker | `sync_matcher.py` (2639 lines) | `dubbing/engine/dub_engine.py` + `engine/pipeline/` |
| venv | `venv/` (repo root) | `dubbing/venv/` |
| Deps | `requirements.txt` (+ `requirements-direct.txt`) | `dubbing/requirements.txt` |
| Secrets | `sync_pipeline_settings.json` | `dubbing/config/*.json` |
| Runtime files | `sync_python_{log.txt,pid.txt,done.txt}` at repo root | `dubbing/engine/status/<project-slug>/engine_{log.txt,pid.txt,done.txt,done.json}` |

Full field-by-field contract: **`.claude/skills/lua-python-ipc/SKILL.md`**.
Read it before touching either boundary.

### The one-window trick (EMBED)

`auto_sync_pipeline.lua:33` reads `_G.__FASTSYNC_EMBED`.

- Not set → standalone: own ImGui context, own font, own `reaper.defer` loop.
  But it then **redirects** to the dub panel if that file exists
  (`launch_dub_panel()` at `:2300-2310`), so old toolbar buttons still work.
- Set → module: draws nothing of its own, returns
  `{ render, poll, is_running, reload_settings }` at `:2285-2290`.

`Dub_Pipeline_Panel.lua:2391-2410` (`V5.load_sync()`) sets the flag, `dofile`s
the sync script, and clears the flag. The `dofile` is also a **Lua
200-locals-per-chunk workaround** — the panel is already at the limit, which
is why all its state hangs off one table `V5` (`Dub_Pipeline_Panel.lua:129-137`).

---

## Directory map

```
fast-syncs/
├── auto_sync_pipeline.lua   THE only ReaScript a user loads. Dual-mode (see above).
├── run_sync.py              Launcher: settings JSON → SYNC_* env → worker; owns log/pid/done.
├── sync_matcher.py          Worker: transcribe → Gemini match → spring placement.
├── app_feedback.py          "Send Feedback" helper (stdlib only) → GitHub issue.
├── Sync_Item.lua            ⚠ byte-identical duplicate of scripts_optional/Sync_Item.lua
├── scripts_optional/
│   └── Sync_Item.lua        Optional manual one-clip aligner (the copy README points at).
├── VERSION                  Single line, e.g. 0.13.0. Shown in both window titles.
├── SyncingPrompt.txt        Original hand-written prompt (origin of the punctuation hierarchy).
├── requirements.txt         Thin-client deps (stdlib + truststore/certifi).
├── requirements-direct.txt  Extra deps when calling providers directly (google-genai, soundfile, numpy).
├── setup.sh / setup.bat     One-time install → creates venv/
├── update.sh / update.bat   git pull OR ZIP overlay, then refresh both venvs + ffmpeg
├── server/                  OPTIONAL FastAPI proxy that holds the real keys (main.py, 333 lines)
└── dubbing/                 The dubbing app — its own everything
    ├── CONTRACT.md          Changelog-shaped spec: file formats, CLI, stage tags, hard rules
    ├── setup_mac.command / setup_windows.bat   Dubbing-only installer (creates dubbing/venv)
    ├── requirements.txt     numpy, librosa, pydub, google-genai, google-cloud-texttospeech, …
    ├── prompts/             55 text files = 5 stages × 11 languages. Translation STYLE lives here.
    ├── reaper/
    │   ├── Dub_Pipeline_Panel.lua   The 4-tab window (Dub / Sync / Tools / Log) + Settings window
    │   └── Import_Dub_Results.lua   Fallback importer that works without ReaImGui
    └── engine/
        ├── run_dub.py       Launcher (status dir, tee, pid, done-last)
        ├── dub_engine.py    Stage conductor: [S1a]…[S3e]
        ├── ENGINE_NOTES.md  Provenance of each pipeline module + selfcheck description
        └── pipeline/        config, stt, srt_tools, llm, tts, match, sync, agent_*, tm
```

**Gitignored, never commit:** `sync_pipeline_settings.json`,
`dubbing/config/`, `vertex_key.json`, `*.env`, both `venv/`s,
`dubbing/engine/status/`, `dubbing/data/`, all audio and `.RPP` files.

---

## Running and checking things

**You cannot run REAPER headlessly.** There is no way for you to execute the
Lua, render the UI, or see a clip move. Any claim that a Lua change "works"
must come from a human with REAPER open. Say so instead of implying you
tested it.

There is no CI, no test suite, no linter config. The gates you *can* run:

```bash
# Python syntax — all of it
python -m py_compile run_sync.py sync_matcher.py app_feedback.py \
  dubbing/engine/run_dub.py dubbing/engine/dub_engine.py dubbing/engine/pipeline/*.py

# Engine self-check: asserts every pipeline symbol + all 55 prompt files exist.
# A fresh clone must pass this. (ENGINE_NOTES.md:44-49)
dubbing/venv/bin/python dubbing/engine/dub_engine.py --selfcheck

# CLI surfaces still parse
python run_sync.py --help                 # (argparse: script_dir, --language, --mode, --asr)
dubbing/venv/bin/python dubbing/engine/run_dub.py --help

# Lua syntax, if luac happens to be installed
luac -p auto_sync_pipeline.lua dubbing/reaper/*.lua
```

**Do not run the installers, `pip install`, or `git commit`/`push` unless
explicitly asked.** `setup.*` and `update.*` mutate the user's environment
(and `update.*` overwrites the working tree from GitHub).

Never invoke `sync_matcher.py` or `dub_engine.py` directly to "try it" — they
make paid API calls to ElevenLabs and Gemini using the user's real keys.

---

## Platform matrix

Windows and macOS are both first-class. Every launch/spawn path is branched.

| Concern | Windows | macOS |
|---|---|---|
| OS test | `reaper.GetOS():match("Win")` (`auto_sync_pipeline.lua:723`) | anything else |
| Launch worker | `reaper.ExecProcess(cmd, -2)` — `CreateProcess`, no console window (`:2055-2063`) | `os.execute(cmd)` with trailing `&` and `>/dev/null 2>&1` (`:1047`, `:2068`) |
| Open a terminal | `start "" "<script>"` (`:830`) | write a `.command` wrapper to `$TMPDIR` and `open` it (`:837-851`) |
| Kill a run | `taskkill /F /T /PID` (`:631`) | `kill -9` (`:633`) |
| Child process flags | `subprocess.CREATE_NO_WINDOW` (`run_sync.py:208`) | `start_new_session=True` (`:212`) |
| venv python | `venv\Scripts\python.exe` | `venv/bin/python3` |
| Line endings | `.bat`/`.cmd` **must** be CRLF | `.sh` **must** stay LF |

`.gitattributes` pins those line endings. **Do not change it** — LF in a
`.bat` makes `cmd.exe` mis-parse, CRLF in a `.sh` breaks the shebang.

macOS-specific note: `_spawn_terminal_script()` (`:814-856`) deliberately does
**not** use `osascript -e 'tell application "Terminal"'`. That route needs
macOS Automation permission and fails *silently* when it isn't granted — the
comment at `:814-818` calls it the #1 "Update does nothing" report. Don't
reintroduce it.

---

## Known fragile areas

**Python discovery is implemented five separate times** — `find_python()` in
`auto_sync_pipeline.lua:754`, `find_python()` in
`Dub_Pipeline_Panel.lua:1078`, `setup.sh:22-50`, `setup.bat:34-44`, and
`dubbing/setup_mac.command:47-86` / `dubbing/setup_windows.bat:229-257`. They
do **not** agree: the version floor is *none* in `setup.sh` and the Lua, 3.9 in
`setup.bat`, and 3.11 in both dubbing scripts, and the candidate lists differ.
Changing one changes nothing about the others. See
`.claude/skills/cross-platform-installers/SKILL.md`.

Both Lua implementations resolve a bare command name by *executing* it
(`probe_python`, `auto_sync_pipeline.lua:733`), because `io.open` resolves
relative to REAPER's cwd, never the PATH — and because Windows 10/11 ships a
Microsoft Store `python.exe` stub that opens fine as a file but prints
"Python was not found" when run.

**Dependencies are unpinned** (`>=` or bare names in all three requirements
files). A user running `update.*` can get a breaking upstream release without
any repo change. Suspect this first for "it worked yesterday".

**ffmpeg is a native dependency** of the dubbing engine (pydub). Discovery is
`_find_ffmpeg()` at `dubbing/engine/pipeline/config.py:48-69`: `shutil.which`
→ a bundled `dubbing/ffmpeg/` → Windows WinGet/Program Files/`C:\ffmpeg` →
Homebrew paths. It is prepended to `PATH` *before* pydub is imported
(`config.py:73-78`). Reordering those lines breaks audio on machines where
ffmpeg is not already on the PATH.

**ReaImGui / ReaPack bootstrap.** ReaImGui is a REAPER extension the user
must install; it is not vendored. `main()` at `auto_sync_pipeline.lua:2100`
handles three states: ReaPack present (offer to add the repo and open the
package browser, `try_reapack_install()` `:483`), ReaPack absent (download the
ReaPack binary into `UserPlugins` with curl, `try_reapack_bootstrap()` `:558`),
or manual instructions. `_reapack_asset()` (`:525-552`) maps `reaper.GetOS()`
to the right binary. Detection is a real `CreateContext` probe, not
`APIExists` — `imgui_available()` `:403-417` explains why.

**cmd.exe quoting.** Windows batch is the single most breakable surface here.
See the installers skill; the short version is: paths always quoted,
`start ""` needs the empty title so a path with spaces isn't read as the
window title (`auto_sync_pipeline.lua:822-825`), and parentheses/`!` inside
`if`/`for` blocks change meaning.

**TLS: one policy, two implementations of it.** Both halves now verify first
and relax only after a genuine certificate-verification failure —
`sync_matcher.py:87-176` for Auto Sync, and `_ssl_context()` / `_urlopen()` in
`dubbing/engine/pipeline/config.py` for the dubbing engine. Every provider call
in `stt.py` and `tts.py` goes through `_urlopen`; none of them builds its own
context.

Do not "simplify" either one into a single permissive context. The dubbing
engine used to do exactly that (`check_hostname=False`, `verify_mode=CERT_NONE`
for every call) and it sent the user's API keys over unverified TLS on every
network. The layered approach exists so that TLS-inspecting corporate proxies
keep working *without* turning verification off for everyone else. Specifically,
do not make the failure classifier substring-match exception text —
`URLError.reason` can be a server-supplied string.

---

## Gotchas an agent will get wrong

1. **You cannot test the Lua.** No headless REAPER. Don't say "verified".
2. **Never commit `sync_pipeline_settings.json` or `dubbing/config/*`.** They
   hold live ElevenLabs / Gemini / gateway keys in plain text.
   `HOW_IT_WORKS.md:436-452` says the author's own copy contains live keys —
   if you ever see one in a diff, stop and tell the user to rotate them.
3. **`dub_id` is a 1-based index into position-sorted items**, not a REAPER
   object ID. Assigned in `get_items_sorted()` (`:669-681`) after the sort.
   Change the sort and clips silently land in the wrong places.
4. **The Lua reads the results JSON with regexes, one line at a time**
   (`apply_results()` `:1077-1089`). It works only because Python writes
   `json.dump(..., indent=2)`. Compact JSON = zero clips move, no error.
5. **`STEP 1`…`STEP 4` in the worker's output are an API.** The Lua poller
   greps for them to advance the progress bar (`:1801-1814`). So are the
   `[Sxx]` stage tags in the dubbing engine (`Dub_Pipeline_Panel.lua:3420`).
   Reword a print and the progress bar freezes.
6. **`reaper.ExecProcess` returns `"<exit code>\n<output>"`.** Parse both
   parts. See `probe_python()` (`:733-745`).
7. **`GetMediaSourceFileName(src, "")` needs the second argument.**
   (`:703-710`, and `dubbing/CONTRACT.md` "Hard rules".)
8. **Batch-file traps.** `.bat` must stay CRLF. Inside a parenthesised
   `if`/`for` block, `%var%` is expanded once when the block is *parsed*, so
   a variable set inside the block needs `setlocal enabledelayedexpansion`
   and `!var!`. A literal `)` inside a quoted string still closes the block
   unless escaped as `^)`.
9. **Don't add a fallback matcher.** Zero matches is a *deliberate* hard
   failure (`sync_matcher.py:2629-2635`), and `run_sync.py:169-173` forces any
   legacy `--mode` back to `gemini`. The old duration-guessing fallback put
   clips in wrong places and nobody noticed. See `HOW_IT_WORKS.md` rule 1.
10. **Don't move the human review pause.** Translation is cheap, speech
    synthesis is not. The pause sits between them by design
    (`HOW_IT_WORKS.md` rule 2, `dubbing/CONTRACT.md` "Staged runs").
11. **Indic text never goes on a command line**, and neither do secrets — both
    travel via UTF-8 files (`dubbing/CONTRACT.md` v0.2 section; argument
    encoding on Windows mangles Devanagari).
12. **File formats only grow by appending optional fields.** Old REAPER
    projects and old runs must still open. See the release skill.
13. **`Sync_Item.lua` exists twice** (repo root and `scripts_optional/`),
    byte-identical. `README.md` points at the `scripts_optional/` copy. If you
    edit one, either edit both or propose deleting the root duplicate.
14. **Every timeline mutation goes in one `Undo_BeginBlock` /
    `Undo_EndBlock`** with `PreventUIRefresh` around it (`:1744-1751`).
15. **`Dub_Pipeline_Panel.lua` is at Lua's 200-locals limit.** New file-scope
    state goes on the `V5` table (`:129-137`), never a new `local`.

---

## Known stale / risky spots (documented, not yet fixed)

- `VERSION` is `0.13.0`; `HOW_IT_WORKS.md:3` still says `v0.12.0`.
- `dubbing/CONTRACT.md`'s newest section is v0.12 and its §v0.5 still
  describes **seven** tabs; the code has four
  (`Dub_Pipeline_Panel.lua:6352-6378`) with Settings as a separate window.
  Its "Hard rules" still mandate importing a bulk app that v0.3 removed.
  Treat CONTRACT.md as a *historical* spec: trust the code where they differ.
- Hardcoded personal paths: `Dub_Pipeline_Panel.lua:196`
  (`DEFAULT_APP_DIR = "/Users/ilp/Documents/Claude code/"`),
  `dubbing/setup_mac.command:37` (`BULK_APP_DIR=…`), and
  `dubbing/CONTRACT.md:610`, `:725`.
- A LAN gateway address `http://172.18.1.17:14005` appears as an example in
  `README.md` and `HOW_IT_WORKS.md`. It only works inside one office network.
- `dubbing/engine/run_dub.py` accepts `--sync-mode`, `--chunk-mode`,
  `--sts-model`, `--emotion/--no-emotion`, but `build_engine_cmd`
  (`Dub_Pipeline_Panel.lua:2166`) never emits them — those settings actually
  reach the engine only via `dubbing/engine/engine_settings.json`. Two config
  paths for one knob; the CLI one is unreachable from the UI.
- `auto_sync_pipeline.lua` still interpolates unescaped values into shell
  commands in several places: `open_path()` (`:468`),
  `_spawn_terminal_script()` (`:827`), the `--language` / `--mode` / `--asr`
  arguments of its launch command (`:1039`), and its old-REAPER `cmd.exe`
  fallback (`:2065`). The dubbing panel's equivalents were fixed; these were
  not, and they are the same class of bug in the half everyone uses. Worth
  doing next.
- `setup.bat` has **no `--auto` mode**: it ends in an unconditional `pause`
  (`:136`) and can hit an interactive `choice /c YN` (`:177`) — yet it is
  invoked non-interactively from `update.bat:127`/`:131` and from REAPER
  (`ensure_setup()`, `auto_sync_pipeline.lua:894`). `dubbing/setup_windows.bat`
  does support `--auto` (`:199`, `:288`).
- `setup.sh` / `update.sh` use `set -e`, so a failure aborts them **with no
  message** and silently skips the `.direct-mode` write and the dubbing setup.
  The `.bat` twins print an error and `pause`.
- On Windows, a git-cloned install with git missing from PATH gets **no
  update and no ZIP fallback** (`update.bat:48-54`); `update.sh:56` does fall
  back.
- Once a ZIP overlay has been applied over a git checkout, the tree stays
  dirty and every later `git pull --ff-only` fails, so the updater silently
  re-downloads the full ZIP forever.
- `dubbing/setup_windows.bat:151` downloads and installs an ffmpeg binary with
  no checksum or signature; the updaters overlay downloaded `.py`/`.lua`/`.bat`
  files that are then executed. HTTPS is the only integrity control.
- No git tags, and clones here may be shallow (depth 1). Don't rely on
  history or `git describe`.
