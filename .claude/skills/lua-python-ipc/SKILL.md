---
name: lua-python-ipc
description: Use when changing anything that crosses the Lua↔Python boundary — the JSON written by the Lua script, the results Python writes back, the log/pid/done marker files, the SYNC_* environment variables, or the progress strings the Lua poller greps for. Both halves must be edited together; this skill documents the exact contract so you don't half-change it.
---

# The Lua ↔ Python file contract

REAPER's Lua cannot do HTTP or long-running work, so all of it happens in a
separate Python process. They never talk directly. Everything goes through
**files on disk, next to the script**, plus **environment variables** for
secrets.

There are two independent instances of this pattern in the repo:

| | Auto Sync (Robot 1) | Dubbing (Robot 2) |
|---|---|---|
| Lua side | `auto_sync_pipeline.lua` | `dubbing/reaper/Dub_Pipeline_Panel.lua` |
| Launcher | `run_sync.py` | `dubbing/engine/run_dub.py` |
| Worker | `sync_matcher.py` | `dubbing/engine/dub_engine.py` |
| venv | `venv/` | `dubbing/venv/` |

They share the same *shape*. This skill documents Auto Sync in full — the
dubbing one is the same idea with per-project status folders under
`dubbing/engine/status/`.

---

## The five files (Auto Sync)

All written into `get_script_dir()` — the repo root, resolved from
`debug.getinfo` (`auto_sync_pipeline.lua:683`). All are gitignored.

| File | Written by | Read by |
|---|---|---|
| `sync_config.json` | Lua `write_config()` `:946` | Python `main()` `sync_matcher.py:2473` |
| `sync_results.json` | Python `main()` `sync_matcher.py:2609` | Lua `apply_results()` `:1061`, `read_summary()` `:1154` |
| `sync_python_log.txt` | `run_sync.py:181` (child's stdout fd) | Lua `poll_python_step()` `:1791` |
| `sync_python_pid.txt` | `run_sync.py:224` | Lua `cancel_python()` `:624` |
| `sync_python_done.txt` | `run_sync.py:245` (in `finally`) | Lua `poll_python_step()` `:1837` |

### `sync_config.json` — Lua → Python

Hand-built line by line at `auto_sync_pipeline.lua:946-991`:

```json
{
  "output_path": "<abs path to sync_results.json>",
  "script_text": "<optional, inline dubbing script>",
  "en_items":  [ {"id":1,"position":3.200000,"duration":2.100000,"wav_path":"…","take_offset":0.500000}, … ],
  "dub_items": [ … same shape … ]
}
```

`id` is `seq` from `get_items_sorted()` (`:669-681`) — **1-based, assigned
after sorting by timeline position**. Python echoes it back as `dub_id`.
Item field format string: `build_item_json()` at `:939-944`.

### `sync_results.json` — Python → Lua

Built at `sync_matcher.py:2595-2607`, records at `:1676-1703`:

```json
{
  "results": [
    {"dub_id":12,"en_id":5,"match":4,"score":1.0,"new_position":45.320000,
     "silence_correction":0.041000,"dub_duration":2.100000,"status":"matched"},
    {"dub_id":13,"match":null,"score":0,"new_position":91.400000,
     "dub_duration":1.800000,"status":"unmatched"}
  ],
  "summary": {"total_en":…,"total_dub":…,"matched":…,"unmatched":…,
              "model":"…","language":"…","backend":"…","asr":"…"}
}
```

Three `status` values are handled on the Lua side (`apply_results()`
`:1109-1141`):

- `matched` → set `D_POSITION` on the `Dub` track
- `unmatched` → move to the `Un sync` track at `new_position`
- `missing_file` → move to `Un sync`, keep original position
  (produced at `sync_matcher.py:2267`)

**The Lua parser is line-oriented regex, not a JSON parser**
(`:1077-1089`). It scans for `"dub_id"` to start a record, then picks up
`"status"` and `"new_position"` from following lines. This works only because
Python writes with `json.dump(..., indent=2)` (`sync_matcher.py:2610`), which
puts one field per line. **If you ever change that dump to compact output, or
reorder fields so `dub_id` is not first in its block, the Lua silently parses
nothing and no clips move.** `read_summary()` (`:1154-1166`) is the same
style.

---

## Secrets never travel on argv

The Lua command line carries only non-secret selectors
(`build_python_cmd()` `:998-1054`):

```
"<python>" "<repo>/run_sync.py" "<repo>" --language ne --mode gemini --asr elevenlabs
```

`run_sync.py` then reads `sync_pipeline_settings.json` (`:43-54`) — and, as a
fallback, `dubbing/config/llm_settings.json` + `tts_settings.json` via
`_dub_credentials()` (`:57-98`) — and maps them into the environment in
`_build_env()` (`:101-137`):

| Env var | Source key |
|---|---|
| `SYNC_ELEVENLABS_KEY` | `elevenlabs_key` |
| `SYNC_GEMINI_KEY` | `gemini_key` |
| `SYNC_GEMINI_BACKEND` | `gemini_backend` (`vertex`/`rest`/`gateway`) |
| `SYNC_GEMINI_MODEL` | `gemini_model` |
| `SYNC_GEMINI_BASE_URL` | `gemini_base_url` |
| `SYNC_API_BASE` / `SYNC_API_TOKEN` | `api_base` / `api_token` (proxy mode) |
| `GOOGLE_APPLICATION_CREDENTIALS` | `vertex_key_path` |
| `SYNC_MATCHER_PROVIDER` | hardcoded `"gemini"` (`run_sync.py:136`) |

`sync_matcher.py` reads these at module scope (`:177`, `:250-263`). Adding a
new setting means editing **four** places: the Lua `save_settings()`
(`:298-318`) *and* `load_settings()` (`:171-227`), `run_sync.py:_build_env()`,
and the `os.environ.get` in `sync_matcher.py`.

`PYTHONUTF8=1` / `PYTHONIOENCODING=utf-8` are also forced
(`run_sync.py:110-111`) — the worker prints `✓ → ──` and on Windows a
redirected stream defaults to cp1252, which would raise `UnicodeEncodeError`
and kill the run.

---

## Progress reporting is string-matched log lines

The Lua poller greps the log for literal markers (`:1801-1829`):

| Marker in the log | Effect |
|---|---|
| `STEP 1` | phase 1, progress ≥ 0.08 |
| `STEP 2` | phase 2, progress ≥ 0.40 |
| `STEP 3` | phase 3, progress ≥ 0.75 |
| `STEP 4` | phase 4, progress ≥ 0.88 |
| a line matching `%[%s*%d+%]%s+"` (e.g. `[ 12] "some text"`) | increments the per-clip counter for the current phase |

**These are a real interface.** If you reword the worker's progress prints,
the progress bar freezes. Grep `sync_matcher.py` for `STEP ` before changing
any print.

---

## Lifecycle rules

**Launch (Lua, `start_sync_run()` `:1907-2073`):**
1. `os.remove(results_path)` `:1990` — stale results must not be re-applied.
2. `os.remove(done_path)` `:2006`.
3. Truncate the log `:2009-2010` — the poller reads by byte offset from 0.
4. `os.remove(sync_python_pid.txt)` `:2012` — a stale PID could be recycled,
   and Cancel would kill an unrelated process.
5. Launch: `ExecProcess(cmd, -2)` on Windows, `os.execute(cmd)` with a
   trailing `&` on macOS.

**Completion (`run_sync.py` `finally` block `:238-254`):** the done file is
written **always**, even on a crash, so the Lua poller can never hang. Then
the PID file is removed. Keep that ordering.

**Success gate (Lua `:1862`):** `exit_code == 0` **and** the results file
exists. Anything else → failure phase.

**Hard-fail rule:** `sync_matcher.py:2629-2635` exits 1 when zero clips
matched, even though it already wrote the results file. A half-synced
timeline that looks plausible is worse than a visible error. Do not add a
fallback matcher — `run_sync.py:169-173` actively forces any legacy
`--mode` value back to `gemini`.

**Watchdog (Lua `:1884-1897`):** if the log is still zero bytes 90 s after
launch, the run is declared failed. `run_sync.py` writes its
`[run_sync] launching:` line (`:199`) within a second or two of a successful
start, so an empty log means the launch itself failed.

**Cancel (Lua `cancel_python()` `:618-635`):** reads the PID and issues
`taskkill /F /T /PID` (Windows) or `kill -9` (macOS). `run_sync.py` sets
`start_new_session=True` on POSIX (`:212`) and `CREATE_NO_WINDOW` on Windows
(`:208`) so the whole worker tree is signalable and no console window appears.

---

## Checklist before you commit a change here

- [ ] Did you change a field name in `sync_config.json`? Update
      `build_item_json()` **and** `sync_matcher.py:main()`'s `config[...]`
      reads.
- [ ] Did you change the results JSON shape? Check the Lua regex parser still
      finds `dub_id` / `status` / `new_position` on their own lines.
- [ ] Did you rename a `STEP n` print? The progress bar depends on it.
- [ ] Did you add a setting? Four edit sites (see the env table above).
- [ ] Is the done file still written in a `finally`?
