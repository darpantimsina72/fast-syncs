---
name: cross-platform-installers
description: Use when touching setup.sh, setup.bat, update.sh, update.bat, dubbing/setup_mac.command, dubbing/setup_windows.bat, or any code that has to locate a Python interpreter or a venv. These six scripts run on users' machines with no error reporting back to you; this skill maps what each one actually does, where they disagree, and the cmd.exe traps that make batch edits dangerous.
---

# The six installers

None of these can be tested here — running one mutates the machine, and
`update.*` overwrites the working tree from GitHub. **Do not execute them.**
Read, reason, edit carefully, and tell the user what needs manual testing on
which OS.

| Script | Creates | Calls |
|---|---|---|
| `setup.sh` (97 L) | `venv/`, `.direct-mode` | `dubbing/setup_mac.command --auto` (`:92`) |
| `setup.bat` (202 L) | `venv\`, `.direct-mode` | `dubbing\setup_windows.bat --auto` (`:126`) |
| `update.sh` (123 L) | refreshes `venv/`; may call `setup.sh` (`:99`) | git pull **or** ZIP overlay |
| `update.bat` (190 L) | refreshes `venv\`; may call `setup.bat` (`:127`/`:131`) | git pull **or** ZIP overlay |
| `dubbing/setup_mac.command` (296 L) | `dubbing/venv/`, `dubbing/config/*` (interactive only) | `brew install ffmpeg` |
| `dubbing/setup_windows.bat` (290 L) | `dubbing\venv\`, `dubbing\ffmpeg\bin\` | `winget` Python + FFmpeg, portable ZIP fallback |

Two venvs, never mixed: **`venv/`** (thin client for Auto Sync) and
**`dubbing/venv/`** (the dubbing engine). The `.direct-mode` marker exists
**only at the repo root** and the dubbing scripts do not read it.

---

## 1. Python discovery is implemented five times and they disagree

There is no shared helper. Editing one changes nothing about the others.

| Implementation | Version floor | How it validates |
|---|---|---|
| `setup.sh:22-50` | **none** — only "`python -m pip --version` works" (`:39`) | absolute paths + `[ -x ]` |
| `setup.bat:34-44` + `:try_python` `:142-148` | **3.9** (`assert sys.version_info[1]>=9`) | executes each candidate |
| `dubbing/setup_windows.bat:229-257` | **3.11** | executes each candidate |
| `dubbing/setup_mac.command:47-86` | **3.11**, and accepts `pip` **or** `ensurepip` (`:73-81`) | executes; computes `major*1000+minor` |
| `auto_sync_pipeline.lua:754-812` / `Dub_Pipeline_Panel.lua:1078-1128` | **none** | Windows: executes (`probe_python`). macOS: `file_exists` only (`:806-808`) |

Real consequences already latent in the tree:

- `setup.sh` will happily build the root venv on Python 3.9 or 3.10, while
  `dubbing/setup_mac.command` (which `setup.sh:92` then calls) requires 3.11.
  The two venvs can end up on different interpreters, or the dubbing half
  refuses to install while the root half reports success.
- Preference order differs: `setup.sh` prefers 3.13 first; both `.bat` files
  prefer 3.12 first.
- `setup.sh:24-35` is missing
  `/Library/Frameworks/Python.framework/Versions/Current/bin/python3` — the
  python.org installer path — which `dubbing/setup_mac.command:61` and
  `auto_sync_pipeline.lua:802` both have.
- `auto_sync_pipeline.lua:803` hardcodes a **patch** version,
  `/opt/homebrew/Cellar/python@3.13/3.13.12_1/bin/python3.13`. One
  `brew upgrade` and that entry is dead.
- `setup.sh:3` claims "macOS / Linux" but every candidate is a Homebrew or
  `/usr/local` path and the error hint is `brew install python@3.13`
  (`:47-48`). On Debian/Ubuntu `python3 -m venv venv` fails without
  `python3-venv` — and see the `set -e` trap below.

**If you are asked to fix Python discovery, propose unifying it** — the
version floor, the candidate list, and the "must execute it, not just stat
it" rule. Do it in one change across all five, or the divergence gets worse.

Why the Lua side must *execute* a bare command name: `io.open` resolves
relative names against REAPER's cwd, never the PATH; and stock Windows 10/11
puts a Microsoft Store `python.exe` **stub** on the PATH that opens fine as a
file but prints "Python was not found" and exits non-zero when run.
`probe_python()` at `auto_sync_pipeline.lua:733-745` documents both.

---

## 2. cmd.exe rules for the `.bat` files

**Encoding and line endings are load-bearing.**
`.gitattributes:10` pins `*.bat` to CRLF; `*.sh` to LF (`:14`).
`dubbing/.gitattributes:8` and `:11-12` do the same for the dubbing scripts
(including `*.command`). LF in a `.bat`
makes `cmd.exe` mis-parse; CRLF in a `.sh` breaks `#!/usr/bin/env bash`.
All three `.bat` files are UTF-8 **without BOM** — a BOM would make cmd choke
on `@echo off`. There is no `chcp` anywhere; non-ASCII characters appear only
inside `rem` comments, so a CP437 console mangles comments and nothing else.
**Keep it that way: never put a non-ASCII character in an `echo` line.**

**Delayed expansion.** `setup.bat:20` and `setup_windows.bat:23` use
`setlocal EnableExtensions EnableDelayedExpansion`. `update.bat:31` uses
**plain `setlocal`** — no delayed expansion. Inside a parenthesised block,
`%VAR%` is expanded once when the block is *parsed*, so a variable assigned
inside the block reads as its old value; `!VAR!` reads it live. Correct
examples: `setup.bat:153`/`:165` use `!LOCALAPPDATA!` / `!ProgramFiles!`
inside a `for /d` precisely so `C:\Program Files (x86)` cannot close the block
(the comment at `:163-164` says so).

**Known offender:** `update.bat:88` expands `%ZIPTMP%` at parse time inside a
`for /d` block, which the file's own comment at `:19` warns about, and it has
no delayed expansion available to fix it with. If you touch that block, either
enable delayed expansion on `update.bat:31` or move the expansion out.

**Parentheses.** A literal `)` inside a quoted string still closes a block
unless escaped `^)`. `setup.bat:143-146` and `setup_windows.bat:47-49`
deliberately write the version asserts **paren-free** for this reason. Flat
`goto` labels are used instead of blocks at the risky spots
(`setup.bat:123-132`, `update.bat:126-137`, `setup_windows.bat:260-290`).
Prefer `goto` over nesting when editing.

**Errorlevel.** Three styles are in use, on purpose:

- `if not !errorlevel! == 0` — a **string** compare, so it catches *negative*
  exit codes such as `STATUS_DLL_NOT_FOUND` (`setup.bat:73,86,96,101,111`).
- `cmd >nul 2>&1 && set "VAR=1"` — runs only on exit 0 (`setup.bat:60,147`).
- `if errorlevel 1` means "**≥ 1**" and misses negatives; it survives only
  where the command is a well-behaved tool.

`update.bat:134-136` puts `if errorlevel 1 exit /b 1` **before** `cd /d`
because `cd` resets errorlevel. Don't reorder that.

**Quoting.** `cd /d "%~dp0"` at `setup.bat:21` / `setup_windows.bat:24`.
`%PYEXE%` / `%PY_CMD%` are expanded **unquoted by design** because they may be
multi-token (`py -3.12`); the directory-scan branches embed their own quotes
(`set "PYEXE="%%D\python.exe""`, `setup.bat:155`).

**Returning from a sub-script changes the cwd.** `setup.bat:130-132` re-runs
`cd /d "%~dp0"` after calling the dubbing setup, with a comment explaining
that cmd re-reads the file from disk as it runs, so a changed cwd corrupts
everything after that line. Always restore the cwd after a `call`.

**`pause` policy is inconsistent and it matters.**
`dubbing/setup_windows.bat` supports `--auto` and skips its `pause`
(`:199`, `:288`). **`setup.bat` has no `--auto` mode**, ends with an
unconditional `pause` (`:136`), and can hit an interactive `choice /c YN`
(`:177`) — yet it is invoked non-interactively from `update.bat:127`/`:131`
and from REAPER via `ensure_setup()` (`auto_sync_pipeline.lua:894`). That is a
real contradiction worth fixing; mirror `setup_windows.bat`'s `--auto`
handling.

---

## 3. `set -e` makes the shell installers fail silently

`setup.sh:12` and `update.sh` both use `set -e`. Any failing command aborts
the script **with no message** — and, worse, skips everything after it:
`setup.sh:85` (`.direct-mode`) and `setup.sh:89-94` (the dubbing setup) never
run. The Windows twins print an explicit error and `pause`
(`setup.bat:73,96,101,111`).

Also: `setup.sh:66-71` and `update.sh:91-94` call the `./venv/bin/pip`
**console script**, whose shebang embeds the absolute venv path. A deep
project path can exceed the ~127-byte shebang limit and produce
`bad interpreter`. Every other script uses the robust `python -m pip` form
(`setup.bat:94-100`, `update.bat:149-152`, `setup_mac.command:127`,
`setup_windows.bat:115`). **Prefer `python -m pip`.**

`setup.bat:24` only checks `%~1` for `--direct`; `setup.sh:16-20` loops over
all arguments. So `setup.bat --verbose --direct` silently installs thin mode.

---

## 4. ffmpeg

Only the two dubbing scripts handle it. The root scripts get it transitively.

- **macOS** `dubbing/setup_mac.command:133-168`: probe `command -v ffmpeg` →
  `/opt/homebrew/bin` → `/usr/local/bin` → `$HERE/ffmpeg/bin`. If missing, run
  `brew install ffmpeg` (`:156`). **If Homebrew is not installed there is no
  fallback** — it prints a warning (`:160-167`) and exits 0.
- **Windows** `dubbing/setup_windows.bat:119-173`: probe `where ffmpeg` →
  WinGet Links → `ffmpeg\bin` → `winget install Gyan.FFmpeg` (`:139`) →
  portable ZIP from `gyan.dev` via `curl` + `tar` (`:151-160`) → manual
  warning (`:166-171`).

Both treat a missing ffmpeg as **non-fatal**, so an `--auto` run reports
success and the dub then fails much later at the audio-save step. The runtime
finder is `_find_ffmpeg()` at `dubbing/engine/pipeline/config.py:48-69`, and
`FFMPEG_PATH` is prepended to `PATH` *before* pydub is imported (`:73-78`).
Don't reorder those imports.

---

## 5. `update.sh` vs `update.bat` — the branch logic differs

| | `update.sh:56` | `update.bat:42` |
|---|---|---|
| Detect git install | `[ -d .git ] && command -v git` | `if exist ".git"` |
| git missing | falls through to **ZIP overlay** (`:69`) | sets `NO_DL=1` and **skips straight to deps** (`:52-53`) — no update at all |
| `.git` is a *file* (worktree/submodule) | takes the ZIP path | takes the git path |

Both run `git pull --ff-only` and fall back to the ZIP overlay on failure
(`update.sh:63-67`, `update.bat:56-60`).

**The overlay is a one-way trap.** Once the ZIP has been copied over a git
checkout, the tree is permanently dirty, so every later `--ff-only` fails and
the tool silently re-downloads the whole ZIP forever. Nothing detects or
reports this. Worth surfacing to the user if they report "updates are slow".

**Nothing is explicitly preserved.** `venv/`, `sync_pipeline_settings.json`,
`.direct-mode`, `dubbing/config/`, `dubbing/data/`, `dubbing/ffmpeg/` survive
only because they are gitignored and therefore absent from the codeload ZIP.
**If you add a user-data file, add it to `.gitignore` or the next update
overwrites it.**

**Neither overlay deletes files removed upstream.** Stale files accumulate.
Code that must stop running after you delete its file needs a guard, not just
a `git rm`. (`update.bat`'s `xcopy` also lacks `/h`, so hidden-attributed
files are skipped; `cp -R "$src/."` on macOS does copy dotfiles.)

**Neither updater reads or compares `VERSION`** — it is just overwritten as a
side effect. There is no "already up to date" logic.

Re-running plain `setup.sh` / `setup.bat` **removes** `.direct-mode`
(`setup.sh:85`, `setup.bat:115`), demoting a direct install to thin mode even
though the packages are still there. A migration check at
`update.sh:87-89` / `update.bat:142-144` (`import google.genai`) re-creates it
— but only on the *next* update.

---

## 6. Supply-chain note

`dubbing/setup_windows.bat:151` downloads a binary ZIP from `gyan.dev` and
copies `ffmpeg.exe`/`ffprobe.exe` out of it with **no checksum or signature**.
`update.sh:28` / `update.bat:74` download a codeload ZIP and overlay it over
`.sh`/`.bat`/`.py`/`.lua` files that are then executed. HTTPS is the only
integrity control in both cases. Adding a checksum to the ffmpeg download is a
cheap, low-risk improvement if the user asks for hardening.
