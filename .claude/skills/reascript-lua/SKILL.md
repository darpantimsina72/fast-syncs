---
name: reascript-lua
description: Use when editing any .lua file in this repo (auto_sync_pipeline.lua, dubbing/reaper/Dub_Pipeline_Panel.lua, dubbing/reaper/Import_Dub_Results.lua, Sync_Item.lua) — covers the REAPER API traps, ReaImGui version-safety patterns, and the defer-loop rules this codebase already relies on. Read it before writing REAPER Lua; the conventions here are load-bearing and breaking them causes silent, hard-to-debug failures.
---

# ReaScript Lua conventions in this repo

You cannot test this code by running it. There is no headless REAPER.
The only verification available to you is:

```bash
luac -p auto_sync_pipeline.lua                    # syntax only, if luac exists
```

Everything else needs a human with REAPER open. So: **be conservative, keep
edits small, and preserve the existing defensive patterns** — most of them
exist because something broke in the field.

---

## 1. The four REAPER API traps this repo has already been bitten by

Each of these is annotated in the source with a "FIX"/"BUG" comment. Do not
"clean them up".

**`GetMediaSourceFileName` takes two arguments.**
`auto_sync_pipeline.lua:703-710` — `reaper.GetMediaSourceFileName(src, "")`.
The second argument is a string buffer. Calling it with one argument returns
garbage. `dubbing/CONTRACT.md:832` records this as a hard rule for all Lua in
the project.

**`ExecProcess` returns `"<exit code>\n<output>"`, not just output.**
`probe_python()` at `auto_sync_pipeline.lua:733-745` parses it with
`ret:match("^(%-?%d+)[\r\n]+(.*)$")`. Any new `ExecProcess` call must do the
same. `try_reapack_bootstrap()` at line 571 does the shorter
`ret:match("^(%-?%d+)")` when it only needs the code.

**`ExecProcess(cmd, -2)` is the fire-and-forget Windows launch.**
`start_sync_run()` at `auto_sync_pipeline.lua:2055-2066`. The `-2` timeout
means "start it and don't wait", and it uses `CreateProcess` directly — no
`cmd.exe`, so no black console window sits on screen for the whole run. The
old `os.execute('start "" /b ...')` route is kept only as a fallback for
REAPER builds without `ExecProcess`. **On macOS this does not apply**: the
shell form with a trailing `&` is used instead (line 2068), because the
`>/dev/null 2>&1 &` redirect syntax needs a shell.

**Item IDs are 1-based sequence numbers assigned AFTER sorting by position.**
`get_items_sorted()` at `auto_sync_pipeline.lua:669-681` sorts by
`D_POSITION`, then assigns `v.seq = i`. Python receives `seq` as `id` and
returns it as `dub_id`. `apply_results()` at line 1093-1096 rebuilds the
lookup keyed on `seq`. If you ever change the sort or the numbering, you
break the contract with Python silently — clips move to the wrong places
with no error.

---

## 2. ReaImGui version safety

ReaImGui renames and adds functions between releases. This repo never calls a
non-core ImGui function unguarded. Three patterns are in use; match them.

**(a) Feature-detect optional functions with `if reaper.ImGui_X then`:**

```lua
-- auto_sync_pipeline.lua:375-380
local function _ui_begin_disabled(ctx, cond)
  if reaper.ImGui_BeginDisabled then reaper.ImGui_BeginDisabled(ctx, cond) end
end
```

**(b) Handle renamed enums by trying both spellings:**

```lua
-- auto_sync_pipeline.lua:393-397 — ChildFlags_Border was renamed to ChildFlags_Borders
local function _child_border_flag()
  if reaper.ImGui_ChildFlags_Borders then return reaper.ImGui_ChildFlags_Borders() end
  if reaper.ImGui_ChildFlags_Border  then return reaper.ImGui_ChildFlags_Border()  end
  return 0
end
```

**(c) `pcall` anything that can throw** — fonts, draw lists, window geometry:
`auto_sync_pipeline.lua:454` (`ImGui_CreateFont`), `:456` (`ImGui_Attach`),
`:1190` (`DrawList_AddRectFilledMultiColor`), `:1197/1199`
(`PushFont`/`PopFont`), `:2227/2231` (`GetWindowPos`/`GetWindowSize`).

**Detecting ReaImGui at all is a probe, not a symbol check.**
`imgui_available()` at `auto_sync_pipeline.lua:403-417` explains why:
some installs register `ImGui_CreateContext` before the extension is fully
loaded, so `APIExists` alone is a false positive that then crashes the
unprotected `ImGui_CreateContext` in `main()`. The function actually creates
and destroys a probe context. Keep that.

**Begin/End must always be paired, even when not visible.**
`auto_sync_pipeline.lua:2254-2267`: `ImGui_End(ctx)` is called outside the
`if visible then` guard. Same rule for `BeginChild`/`EndChild`
(`:600-605`) and every `PushStyleColor`/`PopStyleColor` pair. An unpaired
call corrupts the whole frame stack and the window vanishes.

---

## 3. The defer loop

`main()` at `auto_sync_pipeline.lua:2100` ends with `reaper.defer(frame)`
(line 2276), and `frame()` re-arms itself with `reaper.defer(frame)` (line
2270) only while `_ui_window_open` is true. That is the entire event loop.

Rules:

- **Never block inside a defer frame.** No `os.execute` that waits, no
  synchronous HTTP, no sleep. Long work goes to Python (see the
  `lua-python-ipc` skill).
- **Polling happens inside the frame, not in a separate defer.**
  `poll_python_step()` is called from `frame()` at line 2263, deliberately —
  the comment at line 1786-1788 says this keeps log appends and the spinner
  in sync with rendering.
- **If the window closes mid-run the Python keeps going.** Comment at line
  2272-2273. That is intentional; the run still writes its log and done
  files. Don't add a kill-on-close.
- `reaper.set_action_options(2)` at line 2314 suppresses REAPER 7.03+'s
  "ReaScript task control" dialog when the action is re-triggered.

---

## 4. The dual-mode / EMBED pattern

`auto_sync_pipeline.lua` is **both** a standalone action and a module.

```lua
-- auto_sync_pipeline.lua:33
local EMBED = (rawget(_G, "__FASTSYNC_EMBED") == true)
```

- `EMBED == false` → creates its own ImGui context, font, defer loop, and
  clears the REAPER console (`:1913`, `:2198-2200`).
- `EMBED == true` → creates **none** of those. It returns a table at
  `:2285-2290`:
  `{ render(ctx, on_close), poll(), is_running(), reload_settings() }`.
  `dubbing/reaper/Dub_Pipeline_Panel.lua` `dofile()`s it and drives those
  from its "Auto Sync" tab, sharing the panel's ImGui context.

Two consequences you must respect when editing:

1. **Every new console write must be guarded by `if not EMBED`** — see
   `log()` at `:642-645` and the poller at `:1799`, `:1850`. Embedded, the
   console belongs to the dub panel.
2. **The `dofile()` is also a local-variable-budget workaround.** Lua has a
   hard limit of 200 locals per chunk, and `Dub_Pipeline_Panel.lua` is
   already at it (comment at `auto_sync_pipeline.lua:26-32`). Loading
   `auto_sync_pipeline.lua` as its own chunk gives it a fresh budget. If you
   add locals to the dub panel and get `too many local variables`, the fix is
   to group them into a table or move code into a separate chunk — not to
   delete something at random.

Standalone mode also **redirects** to the dub panel when it is present:
`launch_dub_panel()` at `:2300-2310` registers
`dubbing/reaper/Dub_Pipeline_Panel.lua` via `reaper.AddRemoveReaScript` and
runs it, so old toolbar buttons still work. The classic window is the
fallback (`:2315`).

---

## 5. Everything is an undo block

`on_python_done()` at `auto_sync_pipeline.lua:1744-1751`:

```lua
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)
  ... all item moves ...
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Auto Sync Pipeline", -1)
```

Any code that moves, creates, or retargets media items must be wrapped the
same way. One user action = one Ctrl+Z. `dubbing/CONTRACT.md` lists this
under "Hard rules".

---

## 6. Path, file, and text handling

- **Script directory** comes from `debug.getinfo(1, "S")`, not from the cwd:
  `get_script_dir()` at `:683-687`. REAPER's cwd is its own install folder,
  so relative paths do not work. `cancel_python()` at `:618-624` and
  `ui_phase_setup` at `:1228-1230` repeat the same inline because of
  declaration order — that's fine, don't "fix" it into a forward reference.
- **Path separator**: `package.config:sub(1, 1)` (`:2207`, `:2301`) or the
  `_is_windows()` branch at `:723-725`. `_is_windows()` is
  `reaper.GetOS():match("Win")`.
- **`reaper.GetOS()` is the authoritative arch signal**, not
  `GetAppVersion()` — see `_reapack_asset()` at `:525-552` for the full list
  of values it returns (`Win64`, `Win32`, `macOS-arm64`, `OSX64`, `OSX`,
  `linux-*`).
- **Indic text**: the UI attaches a Noto/Nirmala font for the configured
  language script via `_attach_unicode_font()` at `:428-465`. If it can't
  find one it logs and continues with the default font — display-only
  degradation, the audio is unaffected. Never pass Indic text on a command
  line; it goes through UTF-8 files (`dubbing/CONTRACT.md`).
- **JSON is hand-rolled here.** Writing: `esc()` at `:928-937`. Reading: Lua
  pattern matches, e.g. `read_summary()` at `:1154-1166` and `jval()` inside
  `load_settings()` at `:164-168`. `jval` unescapes `\\` and `\"` — the
  comment at `:161-163` explains that without it a Windows path doubles its
  backslashes on every save/load cycle. There is no JSON library available;
  don't introduce a dependency, follow the existing pattern.
