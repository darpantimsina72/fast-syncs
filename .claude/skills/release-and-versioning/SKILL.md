---
name: release-and-versioning
description: Use when finishing any user-visible change, bumping the VERSION file, or changing an on-disk file format (settings JSON, results JSON, the dubbing timestamps/manifest files). Covers how users actually receive updates here (there is no package manager), why every shipped change must bump VERSION, and the additive-only rule that keeps old projects openable.
---

# Shipping a change in this repo

There is no build, no package registry, no CI, and no release artifact. Users
receive changes by **pulling the repo over their existing folder**. That makes
two things unusually important: the version number, and never breaking an old
file format.

---

## 1. Bump `VERSION` on every shipped change

`VERSION` at the repo root is a single line (currently `0.13.0`). It is the
only way a user can tell whether their update actually landed.
`HOW_IT_WORKS.md` states this as design rule 7.

It is read at runtime in three places — all of them display-only, all of them
degrade gracefully if the file is missing:

| Where | What it does |
|---|---|
| `auto_sync_pipeline.lua:2204-2212` | standalone window title, read once per launch |
| `dubbing/reaper/Dub_Pipeline_Panel.lua:176-180` (`V5.APP_VERSION`) | panel title `:6304`, Settings tab `:5767-5768`, `:5894` |
| `dubbing/engine/dub_engine.py:440-448` (`_app_version()`) | engine logs / manifests |

The panel shows `(VERSION file missing — run Update…)` when it can't read it
(`Dub_Pipeline_Panel.lua:5768`), which is the user-visible symptom of a
half-applied update.

**When you bump it, also update the version headers in the docs that carry
one.** As of this writing they disagree: `VERSION` says `0.13.0` but
`HOW_IT_WORKS.md:3` still says `v0.12.0`. Keep them in step or drop the
number from the docs.

`dubbing/CONTRACT.md` is a running, newest-first changelog of engine
behaviour changes (`## v0.12 —`, `## v0.10 —`, `## v0.7 —` …). A change to
the dubbing engine's behaviour or file formats belongs there as a new section
at the top; it is the closest thing this project has to release notes.

---

## 2. File formats grow by appending optional fields — never by changing them

`HOW_IT_WORKS.md` design rule 6: *"Old runs must still open. File formats grow
by adding an optional field at the end."* This is not aspirational; the code
depends on it.

Worked examples already in the tree:

- **Timestamps file.** `dubbing/CONTRACT.md` (v0.7 section, ~line 121):
  a 6th optional bracket `[synced]`/`[unsync]` was appended. *"5-field files
  stay byte-identical and every reader treats a missing status as synced — old
  runs import unchanged."* The bracket is letters-only so a 5-field line's
  trailing `[1234ms]` can never be mistaken for it.
- **Manifests.** Same section: new keys (`sync_texts`, `synced_count`,
  `unsynced_count`) are added as **strings**, `""` when the producing mode
  didn't fill them — *"consumers skip empties, as always"*.
- **Results JSON.** `auto_sync_pipeline.lua:1118-1126` falls back to the
  clip's own position when `new_position` is absent, explicitly *"(e.g. older
  results file)"*.
- **Settings JSON.** `auto_sync_pipeline.lua:221-225` migrates a legacy
  `api_key` into `elevenlabs_key`; `:186-190` falls back from `server_url` to
  the older `api_base`; `:201-209` derives `conn_mode` from legacy fields when
  it isn't present. `:192-199` coerces any legacy/hand-edited value for
  `asr_provider` / `match_mode` / `gemini_backend` into something the Python
  argparse will accept.
- **Item chunk text.** `dubbing/CONTRACT.md`: v0.8 moved it from `P_NOTES` to
  the hidden ext state `P_EXT:fastsyncs_chunk_text`, and readers still fall
  back to `P_NOTES` for pre-v0.8 projects.

So: **add a field, default it, keep the reader tolerant.** Never rename, never
reorder, never change a field's type.

---

## 3. How the update actually reaches a user

`update.sh` / `update.bat`, launched either by double-click or by the
panel's **Update…** button (`run_updater()` at `auto_sync_pipeline.lua:905`,
which shells out via `_spawn_terminal_script()` at `:827`).

Two install shapes are supported and both must keep working:

- **git clone** → `git pull`. A pull that can't fast-forward (local edits)
  falls back to the ZIP overlay rather than failing the update
  (`README.md:116-118`).
- **ZIP download** → download the latest ZIP from GitHub and copy it over the
  folder.

Either way, the updater must **preserve** the user's
`sync_pipeline_settings.json`, `venv/`, `dubbing/venv/`,
`dubbing/config/`, and the `.direct-mode` marker (`README.md:93-104`).

Consequences for you:

- **A new file only ships if the overlay copies it.** Check `update.sh` /
  `update.bat` before assuming a newly added file will reach existing users.
- **A deleted file will NOT disappear from a ZIP-installed folder.** The
  overlay copies over; it doesn't remove. Code that must not run again after
  deletion needs a guard, not just a `git rm`.
- **A new Python dependency needs the updater to reinstall it.** The updater
  refreshes the venv from `requirements.txt` (plus
  `requirements-direct.txt` if `.direct-mode` exists) and `dubbing/requirements.txt`.
- **Never commit `sync_pipeline_settings.json` or anything under
  `dubbing/config/`** — they hold live API keys. Both `.gitignore` files
  already cover them (`.gitignore:8-11`, `dubbing/.gitignore:2`), and no such
  file is currently tracked. Keep it that way. Note `dubbing/.gitignore:2`
  ignores the whole `config/` directory, so a new *non-secret* file placed
  there would also silently not ship.

---

## 4. Repository hygiene notes

- **Dependencies are unpinned.** `requirements.txt`,
  `requirements-direct.txt` and `dubbing/requirements.txt` use `>=` or bare
  names. An update can therefore pull a breaking release of `google-genai`,
  `librosa`, `pydub`, etc. onto a user's machine without any repo change. If
  a user reports "it broke and I changed nothing", suspect this first. Pinning
  is a real improvement to propose — but pin the whole set at once, and test
  a fresh `setup.sh` before shipping it.
- **There is no CI.** Nothing checks that the Python still imports or the Lua
  still parses. The cheapest local gates:
  ```bash
  python -m py_compile run_sync.py sync_matcher.py app_feedback.py \
      dubbing/engine/run_dub.py dubbing/engine/dub_engine.py dubbing/engine/pipeline/*.py
  dubbing/venv/bin/python dubbing/engine/dub_engine.py --selfcheck   # if the venv exists
  luac -p auto_sync_pipeline.lua dubbing/reaper/*.lua                # if luac is installed
  ```
  `--selfcheck` is documented in `dubbing/engine/ENGINE_NOTES.md:44-49`: it
  asserts every required pipeline symbol exists and all 55 per-language
  prompt files are present, and a fresh clone must pass it.
- **No git tags and no GitHub releases.** `git describe` has nothing to
  describe, and `VERSION` is the only version marker — it is hand-edited, so it
  is not derivable from git. Check `git rev-parse --is-shallow-repository`
  before relying on history: an agent's checkout is often `--depth 1`.
  (Tagging releases would also be the prerequisite for ever letting a user roll
  back to an earlier version, which is currently impossible.)
