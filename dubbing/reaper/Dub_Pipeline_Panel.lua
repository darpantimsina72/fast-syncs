-- ============================================================
-- DUB PIPELINE PANEL  (Reaper Dubbing App — contract v0.7; the app
-- version shown in the title bar comes from the root VERSION file)
--
-- One-click: pick English audio → run the dubbing pipeline
-- headless (engine/run_dub.py) → import the results to the timeline.
--
-- Phases: setup → running → [review →] running → success/failure.
--
-- v0.31 (THE REGION — dub the trim, not the file):
--   Trimming an item is how you say what the dub covers, and the panel only
--   half-heard it. A track holding one clean item handed its SOURCE FILE to
--   the engine — the whole file, however short the item had been trimmed to —
--   and anything else was rendered from project 0:00, so an excerpt of an
--   hour-long talk was transcribed, translated and SPOKEN in full. Then the
--   result landed at 0:00, nowhere near the item it came from.
--     * V5.timeline_region answers what would be taken, every frame: the time
--       selection if you dragged one, else the item(s) you selected (which
--       also say which track, so the combo can stay on "(from track)"), else
--       everything the chosen track holds. A time selection is clamped to the
--       track — one dragged past the end of the talk would otherwise render,
--       and transcribe, minutes of silence at ElevenLabs' expense.
--     * The source row SAYS it before you press anything, and says it in
--       amber while the audio in the field is not that span: pressing Run
--       without pressing Use is the exact failure this exists to end.
--     * audio_for_region renders exactly the span (render_track_stem took
--       from_s/to_s for this). The one case that still needs no render is
--       V5.region_is_whole_file — one untrimmed, unstretched item at 0:00,
--       all of it — which is the old fast path plus the two conditions it was
--       missing: the item has to START at zero, and the region has to be the
--       whole of it.
--     * THE SPAN TRAVELS WITH THE AUDIO. <wav>.dubregion.json, written beside
--       the rendered wav in DubSource/ (never next to your own files), records
--       where the span starts in project time. import_to_timeline offsets
--       every track it builds by it, so the dub goes back under the item it
--       was taken from instead of at 0:00, and V5.review_relink takes its zero
--       from it — a region wav is never ON the timeline, it IS a slice of
--       something that is, so the item search could only ever answer 0:00.
--
-- v0.30 (THE CAST — the ElevenLabs voices, chosen where the script is read):
--   The voice was one id in ⚙ Settings: picked before the run, invisible on
--   the screen the pause exists for, and one for the whole talk. But a talk
--   is not always one voice — Sadhguru speaks most of it, a question comes
--   from the audience, an invocation belongs to someone else — and the
--   paragraph is where that is obvious. This screen already lists the
--   paragraphs, so the casting happens here, before anything is spoken.
--     * 🎙 CAST rides on the view row (List/Grid, S/M/L) and never wraps.
--       This screen has no vertical slack left at 780 px — the layout
--       harness measures zero in the regimes where a glyph has not been
--       baked yet — so a row of its own was the difference between a table
--       and a one-pixel sliver of one. Speakers that do not fit collapse
--       into a '+N' chip; the editor it opens takes only what the table can
--       spare, and below ~90 px does not draw rather than squeeze the
--       script off the screen.
--     * CASTING A LINE is a brush, not a dialog: press a speaker's chip to
--       make it active, then click the coloured chip on any paragraph. The
--       inspector lists the whole cast for the selected paragraph, and
--       🔎 Detect speakers reads 'Name:' labels off the English column —
--       without editing the script, including those labels, which
--       ElevenLabs would otherwise read aloud.
--     * EVERY PARAGRAPH HAS A SPEAKER. Speaker 1 is the main voice (and the
--       run's --voice-id); anything not cast to someone else is spoken by
--       it. There is no "unassigned" state to render or to fail on, and
--       ⇧ main swaps two speakers without moving anyone's lines.
--     * IT REACHES THE ENGINE. V5.cast_save writes <base>_speakers.json —
--       the file pipeline/tts.py already knew how to read — keyed by
--       paragraph number, which is exactly a row of this screen. Since
--       engine v0.16 both sync modes speak it (one request is one voice).
--       A single-voice run writes NO file and deletes a stale one, so an
--       empty map means "one voice", never "the cast went missing".
--     * CONTINUE REFUSES while a speaker that has paragraphs has no voice:
--       that is a line nobody can speak, and it costs nothing to fix here.
--       An empty MAIN voice is allowed — that is the engine's documented
--       auto-resolve — and the strip says 'main voice: auto' so it reads as
--       a choice rather than a surprise.
--
-- v0.29 (PROOF, the review screen — and the preview sync it was missing):
--   The staged run's pause used to show two columns of text and five buttons:
--   the translation, the English beside it, and no answer to the question the
--   pause exists for — will this line still land where the English landed?
--   The answer was already in the run. The engine paired these paragraphs
--   against the English SRT it wrote for this audio, so every paragraph's
--   place in the source is recoverable (V5.review_times walks the cues as one
--   character stream and hands them out whole, one group per paragraph).
--   What that buys:
--     * A PREVIEW SYNC. Each paragraph carries its slot, the pause after it,
--       an estimated spoken length for the target text (V5.speech_secs) and
--       the same verdict Studio gives a chunk — fits / eats pause /
--       OVERFLOWS / short. It re-measures every frame, so shortening a line
--       moves its bar while you type, and that costs nothing; the plan stage
--       is where the same question gets its paid, pause-detected answer.
--     * A LANE STRIP and a TRANSPORT. The whole script on one time axis
--       (V5.plan_strip, shared with Studio — a review row is shaped like a
--       plan row on purpose), ▶ Play here to move REAPER's edit cursor to the
--       selected paragraph's place in the English audio, and Follow to walk
--       the selection along with the play cursor. Positions go through
--       V5.review_relink, which finds the run's audio on the timeline: the
--       SRT is timed from the file's own zero, and an item dragged to 0:30
--       would otherwise send every preview half a minute early.
--     * TWO LAYOUTS at a text size you choose (13/15/17, persisted). List is
--       one line per paragraph — the whole script scannable, the bad fits
--       visible without scrolling — and edits the selected one in the
--       inspector; Grid is the v0.4 side-by-side editor, kept because a full
--       retype wants every box at once. A build with no tables, or a window
--       too narrow for the inspector, demotes to Grid rather than stranding
--       the editor.
--   V5.review_bot_h computes the transport bar's height from the widths and
--   the room rather than measuring it. Studio's bar is one row by
--   construction; this one has four buttons and a note and genuinely wraps,
--   and a flat reserve pushed the second row out of the body under ~700 px.
--   Width is an INPUT to that answer, so it is stable — unlike a V5.mh
--   measurement of a block whose height depends on the space left for it.
--
-- v0.27 (three screens, drawn against the v0.26 contract):
--   * BRIDGE, the setup screen. Labels sit ABOVE their controls (V5.fld,
--     V5.fgrid/V5.fcell), which retires the label column entirely: a label and
--     its control cannot collide when they never share a row, and an Indic
--     label takes the width it needs instead of taking it from the field. The
--     grid still pairs short controls two-up, so stacking does not trade
--     horizontal waste for vertical. The run column gains V5.cost_meter — the
--     estimate split into TTS, transcription and headroom, because only the
--     TTS share changes when you shorten the script, and that is the decision
--     the number exists to inform.
--   * CONSOLE, the running screen (V5.ui_console). The pipeline becomes the
--     top-level chrome: one card per stage across the full width, each carrying
--     its own value and the live one its own progress. The screen it replaces
--     was the setup form locked read-only beside a 288 px column, so the thing
--     actually happening was the narrowest element on the widest screen. The
--     script gets the middle; when there is no script yet, the engine's own
--     output does.
--   * STUDIO, the approval gate (V5.ui_phase_plan). Sorted worst-fit-first by
--     default, because the reason to be on this screen is the chunks that do
--     not fit; the table shows each chunk's TEXT, which it never used to; and
--     the selected chunk gets an inspector with its numbers, its target text
--     and its English. The approval sits in a transport bar.
--
--   Two things learned building these, both now written into the primitives:
--   a pending SetNextItemWidth belongs to the NEXT widget only, so a row of
--   several (V5.segmented, a V5.chip toolbar) must size its own or the first
--   one silently takes the whole cell; and after a caption's line ends, ImGui
--   puts the cursor at the WINDOW's left margin, which inside a grid cell is
--   not the cell's left edge.
--
--   V5.PLAN_BOT_H is a FIXED reserve, not a V5.mh measurement, on purpose: a
--   measured reserve for a block whose height depends on the space left for it
--   is a feedback loop, and the transport bar's did not settle.
--
-- v0.26 (the layout contract — nothing can be drawn on top of anything):
--   Nine defects all came from the same two habits: rows placed with an
--   ABSOLUTE ImGui_SameLine(ctx, x) at a hand-counted offset, and text widths
--   taken from ImGui_CalcTextSize without noticing it answers 0 for a glyph
--   ReaImGui has not rasterized yet. ImGui's absolute SameLine sets the cursor
--   whether the offset is ahead of what was just drawn or behind it, so a
--   column that turns out one pixel short does not clip — it overprints.
--   The rules the panel now follows, and what each one fixed:
--     * every text width goes through V5.text_w, which never answers 0 (it
--       estimates instead). V5.label uses it to measure THIS frame and takes
--       max(column, this label) — a label can push its own control right, but
--       can no longer have it drawn through (Google TTS key, and every Indic
--       label on the frame its font was attached).
--     * a hand-counted column is replaced by a measured one plus a pen that
--       only moves forward, and the columns that must stay put (a row's last
--       action) are pinned rather than pushed — V5.hist_row.
--     * tick and column DENSITY is budgeted in pixels, not in units: the fit
--       strip's ruler asks how many m:ss labels the width holds instead of how
--       many fit the duration, and drops the labels when the answer is under
--       two (V5.strip_step).
--     * a button row that does not fit WRAPS (V5.wrap_begin/wrap_next) rather
--       than running off the edge, and it returns to the x the row started at,
--       not the window's margin. V5.segmented, the review toolbar and the
--       prompt editor's footer all use it.
--     * an explicit pixel width is clamped to the room there is (V5.fit_w),
--       and "the room there is" stops at the grid cell's edge (V5.room).
--     * a grid cell is placed at (cell_x, ROW TOP) with the cursor set
--       directly; SameLine returns to the last item's line, which stopped
--       being the row's top once cells could wrap.
--     * lengths are counted in UTF-8 clusters, never bytes (V5.cells) — a
--       Devanagari paragraph is a third as long as '#' claims, which is what
--       made every review box the same oversized shape.
--     * V5.ellipsize truncates for ANY budget and cuts on a character
--       boundary at both ends; it used to return the text untouched below
--       40 px and could split a character off the tail.
--   Verified with a load-and-draw harness rather than by eye: every screen,
--   pane and phase drawn at eleven widths under three CalcTextSize regimes
--   (honest / non-ASCII answers 0 / everything answers 0), plus an
--   old-ReaImGui build with the optional calls absent, asserting that no item
--   is ever drawn over another. The same three defects existed in the Sync
--   tab's own chunk (auto_sync_pipeline.lua) and are fixed there too.
--
-- v0.21 additions (the voice fetch stops being a "run"):
--   - "⟳ Fetch voices" no longer enters the running phase. It is a QUIET job
--     (V5.quiet_job): same launch/poll machinery, but the panel stays on the
--     screen you pressed it from — the button itself spins and the banner
--     beside it reports the result. It used to hand the whole panel to the
--     Dub run screen for the few seconds it took, and — when the launch
--     watchdog fired — leave the Dub screen sitting on a failure page you
--     had to dismiss to get back to your voice list.
--   - V5.busy() is the new "the engine is doing something" test (a run OR a
--     quiet job). Everything that would launch a second engine call gates on
--     it, and preflight_engine refuses outright: run_dub.py's status/ files
--     are a single set, and preflight deletes them.
--   - The Tools tab draws the banner once for all four tools. Only Text to
--     speech used to, so a fetch fired from Voices, Redo one line or Re-voice
--     a track reported its outcome on a screen you were not looking at.
--
-- v0.17 additions (settings/credentials rework):
--   - Every key field has its own eye: masked by default, readable while you
--     hold it open, one field at a time (V5.key_field / V5.eye_button). The
--     old panel-wide "Show keys" checkbox is gone.
--   - ⚙ Settings → Connections lists EVERY API instead of only the one the
--     provider dropdown named, with a live verdict per row. Pasting a key
--     validates it 0.8 s later — one fire-and-forget curl per row, the same
--     non-blocking pattern as the update check (V5.conn_probe / V5.conn_poll)
--     — and a valid key reports which models it serves. That list feeds every
--     Model dropdown (V5.models_for), so the ids offered are the ids the key
--     can actually run.
--   - Voices left Settings for the Tools tab (voice generation belongs with
--     the other voice tools); its ElevenLabs key moved to Connections.
--   - The Languages pane is gone. Target languages still come from LANGUAGES
--     plus config/custom_languages.json — only the editor was retired.
--
-- v0.11 additions:
--   - Every voice picker (Regen Audio, Track Voice, Text to Speech) has its
--     own "⟳ Fetch voices" button, so changing a chunk's voice no longer
--     needs a detour through ⚙ Settings.
--   - "🔊 Test voice" auditions the picked voice before it is used: a short
--     sample (the selected chunk's own text in Regen Audio) is synthesized
--     into engine/preview/ and played outside the timeline — no track, no
--     item, nothing to undo. Pressing it again with the same voice and text
--     replays the wav instead of paying for a second ElevenLabs call.
--   - The fetched catalogue is cached in reaper/voice_cache.json and
--     reloaded at startup, so the voice combos are filled when the panel
--     opens instead of only after a fetch.
--
-- v0.4 additions:
--   - Tabs: the log lives in its own "Log" tab; the Pipeline tab keeps
--     the settings visible (read-only) while a run is in progress.
--   - Per-language Indic fonts: the review editor picks a system font
--     matching the CURRENT language's script (macOS "Sangam MN" family /
--     Windows Nirmala UI), switching live with the language combo.
--   - Whole-script clipboard round-trip in the review phase: Copy script /
--     Copy English / Paste script / Open in editor / Reload file (ImGui
--     cannot fully shape Indic conjuncts — edit externally, paste back).
--   - "I already have the translation": paste an existing translated
--     script; the engine skips the LLM translation chain (S2a–S2c) and
--     goes straight to TTS + sync ("--provided-script").
--   - 🎤 Change track voice: render any project track, re-voice it with
--     the ElevenLabs voice changer (speech-to-speech keeps the timing),
--     import the result as a new track and mute the original
--     ("--voice-change").
--   - Windows support: OS-aware setup hints (setup_windows.bat).
--   - "From track": pick the English audio straight from a project
--     track — one clean item uses its source file, anything else is
--     rendered to <project>/DubSource/ first.
--
-- v0.3 additions (standalone app):
--   - ⚙ Settings section (setup phase): LLM provider/model/keys and
--     ElevenLabs TTS key/model/voice. The panel writes
--     config/llm_settings.json + config/tts_settings.json directly;
--     the engine reads keys from there (never from the command line).
--   - "Test connection" (--test-llm) and "Fetch voices" (--list-voices)
--     go through the same non-blocking run_dub.py launch/poll mechanism.
--   - Python discovery: the project's own venv/ first, then the old
--     bulk-app venv (transition fallback), then system candidates.
--   - app_dir removed from the UI (still tolerated in old settings
--     files; only used to locate the legacy venv fallback).
--
-- v0.2 additions:
--   - Staged runs by default: "--steps translate" pauses after the
--     translation chain and shows a side-by-side review editor
--     (EN transcript read-only left, translation editable right).
--     "Continue to Dubbing" resumes with "--steps dub --script <file>".
--     A "Full run (no review)" checkbox restores the v0.1 one-shot run.
--   - Chunk regeneration: select a "Dub Chunks" item, edit its stored
--     text, hit Regenerate — the engine synthesizes just that text
--     ("--regen-chunk") and the panel swaps the item's take source to
--     the new wav. Non-destructive: new files go to <out_dir>/regen/.
--     v0.8: an optional voice picker under the button re-synthesizes the
--     same text in a different voice (empty = the Settings voice).
--
-- On success, the "Import to timeline" button builds the SAME layout as
-- Import_Dub_Results.lua (the import code is duplicated here on
-- purpose — contract v0.1 allows it):
--
--   1. "EN Original"        — copied original audio, position 0
--   2. "Dub Chunks"         — one item per timestamps line, cut from
--                             tts_wav (STARTOFFS = orig start,
--                             LEN = orig dur, POSITION = synced start;
--                             chunk text = matching synced-SRT cue text,
--                             kept in a hidden item ext state)
--   3. "Dub Rendered (ref)" — final synced wav, position 0, MUTED
--   One undo block. v0.8: no project regions, no visible item notes —
--   both drew over the arrange view and hid the waveforms.
--
-- Requirements:
--   - ReaImGui extension (free, via ReaPack). If missing, the script
--     shows install guidance and exits.
--   - The project venv python (<project>/venv, created by
--     setup_mac.command / setup_windows.bat) or any Python 3 with the
--     engine deps.
--   - engine/run_dub.py + engine/dub_engine.py in the sibling engine/
--     folder (this script lives in reaper/).
--
-- Battle-tested patterns adapted from fast-syncs auto_sync_pipeline.lua:
-- imgui_available() probe, ReaPack guidance, probe_python discovery,
-- non-blocking launch, defer-driven log tail, JSON settings persistence,
-- pid-file cancel.
-- ============================================================

local SEP = package.config:sub(1, 1)

-- Re-running this action while the panel is already open restarts it (no
-- "ReaScript task control" dialog): the legacy auto_sync_pipeline.lua action
-- now redirects here, so the one button users always pressed must reliably
-- bring this window up. REAPER 7.03+; older builds keep the stock prompt.
if reaper.set_action_options then reaper.set_action_options(2) end

-- ---------------------------------------------------------------------------
-- Paths — this script lives in <project>/reaper/, engine in <project>/engine/
-- ---------------------------------------------------------------------------

local SCRIPT_PATH = (debug.getinfo(1, "S").source:match("@(.+)")) or ""
local SCRIPT_DIR  = SCRIPT_PATH:match("(.+)[/\\]") or "."
local BASE_DIR    = SCRIPT_DIR:match("^(.*)[/\\][^/\\]*$") or SCRIPT_DIR
local ENGINE_DIR  = BASE_DIR .. SEP .. "engine"
local RUN_DUB_PY  = ENGINE_DIR .. SEP .. "run_dub.py"
local STATUS_DIR  = ENGINE_DIR .. SEP .. "status"
local LOG_PATH    = STATUS_DIR .. SEP .. "engine_log.txt"
local PID_PATH    = STATUS_DIR .. SEP .. "engine_pid.txt"
local DONE_PATH   = STATUS_DIR .. SEP .. "engine_done.txt"
local DONE_JSON   = STATUS_DIR .. SEP .. "engine_done.json"

-- v0.5 (fast-syncs merge): per-project status dirs. Every REAPER project
-- gets its own subdir under engine/status/, so two REAPER instances can
-- dub two projects at the same time without sharing log/pid/done files.
-- The five paths above are re-pointed by V5.set_status_paths() — at load,
-- and again in preflight while still on setup (a run in flight keeps the
-- paths it launched with).
-- NOTE: every v0.5 addition lives in this ONE table — the file is close
-- to Lua's 200-upvalue/local limit for the main chunk.
local V5 = {
  STATUS_ROOT = STATUS_DIR, run_project = nil,
  -- v0.13 UI state. Declared here because load_settings() runs long before
  -- the UI helpers are defined and must not have its values overwritten.
  adv           = {},        -- "Show advanced" reveal key -> true
  settings_open = false,     -- legacy free-floating settings window (v0.13)
  settings_pane = "connection",
  tool          = "tts",     -- Tools tab: tts | regen | voice | voices
  -- v0.17: per-field key reveal (the eye button). One entry per key input id,
  -- deliberately NOT persisted — a key left in plaintext across launches is a
  -- key on someone else's screen.
  key_shown     = {},        -- input id -> true while that field is readable
  -- v0.17 Connections: one entry per API, filled by the curl probe in
  -- V5.conn_probe / V5.conn_poll. state: unset | idle | checking | ok | bad
  conn          = {},
  conn_started  = false,     -- the once-per-session probe of saved keys has run
  -- v0.16 console shell: the rail replaced the tab bar, so "which tab" is now
  -- "which rail destination" — and Settings is one of them.
  nav           = "dub",     -- dub | sync | tools | log | settings
  ui_gen        = 0,         -- layout generation; a bump resizes the window once
  -- v0.29 Proof (the review screen). Here for the same reason as the rest of
  -- this block: load_settings() restores them long before the review code is
  -- defined, so a default assigned down there would overwrite what was loaded.
  review_px     = 15,        -- script text size on the review screen (13/15/17)
  review_layout = "list",    -- list = scan + inspector · grid = side-by-side
}

-- On V5, not a file-level `local`: this chunk sits at Lua's 200-locals-per-
-- function limit, and two more would fail to compile ("too many local
-- variables in main function").
V5.STATUS_EXT_SECTION = "FastSyncsDub"

-- Windows argument quoting, per the CommandLineToArgvW rules that every
-- MSVCRT-linked program (python.exe included) uses to split its command line.
-- Wrapping a value in bare double quotes — what this file did before — is NOT
-- escaping: any value containing a quote escapes its own argument. VOICE_ID
-- and the ElevenLabs model name are both editable in Settings and both flow
-- into the launch command, so this has to be correct rather than approximate.
--
-- Rules: backslashes are literal EXCEPT before a quote. A run of N
-- backslashes before a `"` becomes 2N backslashes plus an escaped quote; a
-- run at the very end becomes 2N so it cannot escape our closing quote.
-- Windows paths therefore round-trip unchanged ("C:\dir\file.py" stays as
-- typed, "C:\dir\" becomes "C:\dir\\" and parses back correctly).
function V5.winquote(s)
  s = tostring(s or "")
  s = s:gsub('(\\*)"', function(b) return b .. b .. '\\"' end)
  s = s:gsub('(\\+)$', function(b) return b .. b end)
  return '"' .. s .. '"'
end

-- 32-bit DJB2 hashes are formatted through this rather than "%08x" directly.
-- string.format's x conversion demands a value with an INTEGER representation.
-- REAPER's Lua 5.4 keeps the hash an integer and formats it fine, but the
-- layout harness runs this file under fengari, whose integer subtype is 32-bit:
-- there a hash above 2^31 is a float, "%08x" raises "number has no integer
-- representation", and the whole setup screen used to die when the harness
-- drew it. Emitting one nibble at a time never asks for an integer, because
-- the only value formatted is a digit INDEX in 1..16.
-- Verified byte-identical to "%08x" for every n in [0, 2^32).
-- A formatting detail, not a change of hash: existing status directory names
-- are unaffected.
V5._HEXDIGITS = "0123456789abcdef"
function V5._hex32(n)
  n = n % 4294967296
  local out = {}
  for i = 8, 1, -1 do
    local d = n % 16
    out[i] = V5._HEXDIGITS:sub(d + 1, d + 1)
    n = (n - d) / 16
  end
  return table.concat(out)
end

function V5._unsaved_project_token(proj)
  local key = "status_token_" .. (tostring(proj):gsub("[^%w]", ""))
  local tok = reaper.GetExtState(V5.STATUS_EXT_SECTION, key) or ""
  tok = tok:gsub("[^%x]", "")
  if tok == "" then
    local h = 5381
    local seed = table.concat({
      tostring(proj),
      string.format("%.6f", reaper.time_precise and reaper.time_precise() or 0),
      tostring(os.time()),
      tostring(math.random(0, 0xFFFFFF)),   -- Lua 5.4 auto-seeds per instance
    }, "|")
    for i = 1, #seed do h = (h * 33 + seed:byte(i)) % 4294967296 end
    tok = V5._hex32(h)
    reaper.SetExtState(V5.STATUS_EXT_SECTION, key, tok, false)
  end
  return tok
end

function V5.project_status_slug()
  local proj, projfn = reaper.EnumProjects(-1, "")
  if not projfn or projfn == "" then
    return "unsaved_" .. V5._unsaved_project_token(proj)
  end
  local h = 5381
  for i = 1, #projfn do h = (h * 33 + projfn:byte(i)) % 4294967296 end
  local base = projfn:match("([^/\\]+)%.[Rr][Pp][Pp]$")
               or projfn:match("([^/\\]+)$") or "project"
  base = base:gsub("[^%w%-_]", "_"):sub(1, 32)
  return base .. "_" .. V5._hex32(h)
end

function V5.set_status_paths()
  STATUS_DIR = V5.STATUS_ROOT .. SEP .. V5.project_status_slug()
  LOG_PATH   = STATUS_DIR .. SEP .. "engine_log.txt"
  PID_PATH   = STATUS_DIR .. SEP .. "engine_pid.txt"
  DONE_PATH  = STATUS_DIR .. SEP .. "engine_done.txt"
  DONE_JSON  = STATUS_DIR .. SEP .. "engine_done.json"
end
V5.set_status_paths()

-- v0.7 per-stage models. Every place the pipeline calls an LLM can point at
-- its own model; blank means "use the one Model field". {key, label, hint}
-- — the key matches the engine's model_<key> setting and its role name in
-- llm.py::_model_for(). sync_match is the odd one out: Auto Sync reads its
-- model from sync_pipeline_settings.json, so the panel mirrors it there.
V5.MODEL_ROLES = {
  { "translate",  "Translate",        "Dub steps 1-3" },
  { "emotion",    "Emotion tags",     "step 4, before TTS" },
  { "match",      "Dub matching",     "script to English lines" },
  { "mapping",    "Legacy sync map",  "only in legacy sync mode" },
  { "sync_match", "Auto Sync match",  "the Sync tab" },
}
V5.model_roles = { translate = "", emotion = "", match = "", mapping = "",
                   sync_match = "" }

-- v0.7: app version, read from the fast-syncs root VERSION file (kept
-- current by the updater). Shown above the tab bar and in Settings.
V5.APP_VERSION = (function()
  local root = BASE_DIR:match("^(.*)[/\\][^/\\]*$") or BASE_DIR
  local f = io.open(root .. SEP .. "VERSION", "r")
  if not f then return "" end
  local v = (f:read("*l") or ""):match("^%s*(.-)%s*$")
  f:close()
  return v or ""
end)()

local ENGINE_SETTINGS_PATH = ENGINE_DIR .. SEP .. "engine_settings.json"
local PANEL_SETTINGS_PATH  = SCRIPT_DIR .. SEP .. "dub_panel_settings.json"

-- v0.3: user secrets/settings live in <project>/config/ (gitignored).
-- The panel writes these two files; the engine reads them.
local CONFIG_DIR        = BASE_DIR .. SEP .. "config"
local LLM_SETTINGS_PATH = CONFIG_DIR .. SEP .. "llm_settings.json"
local TTS_SETTINGS_PATH = CONFIG_DIR .. SEP .. "tts_settings.json"

-- Contract default APP_DIR (macOS install of the legacy bulk app).
-- v0.3: only used to locate the transition-period venv fallback.
local DEFAULT_APP_DIR = "/Users/ilp/Documents/Claude code/"
                        .. "Akash anna Translation and Syncing App_All"

-- Alphabetical, and kept that way: table.sort runs again after
-- custom_languages.json is merged and after a language is added, so a name
-- picked in a drop-down is always where the alphabet says it is.
local LANGUAGES = { "Assamese", "Bengali", "Gujarati", "Hindi", "Kannada",
                    "Malayalam", "Marathi", "Nepali", "Odia", "Punjabi",
                    "Tamil", "Telugu" }

-- ---------------------------------------------------------------------------
-- Small file helpers
-- ---------------------------------------------------------------------------

local function _is_windows()
  return reaper.GetOS():match("Win") ~= nil
end

-- The one-time setup script for THIS platform (shown in error guidance).
local SETUP_SCRIPT = (reaper.GetOS():match("Win") ~= nil)
                     and "setup_windows.bat" or "setup_mac.command"

local function file_exists(path)
  if not path or path == "" then return false end
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function dirname(path)
  return path:match("^(.*)[/\\][^/\\]*$") or ""
end

local function basename(path)
  return path:match("([^/\\]+)$") or path
end

-- POSIX shell single-quote escaping. os.execute goes through /bin/sh, where
-- DOUBLE quotes still expand $, backtick and backslash, and an embedded
-- double quote ends the quoting entirely — single quotes are the only safe
-- wrapper for arbitrary paths/values.
local function shellquote(s)
  local q = tostring(s or ""):gsub("'", "'\\''")
  return "'" .. q .. "'"
end

-- Mask an API key for display: first/last 4 chars kept, middle starred
-- (fast-syncs pattern). Short keys are fully starred.
local function _mask_key(key)
  if not key or key == "" then return "" end
  if #key <= 10 then return string.rep("*", #key) end
  return key:sub(1, 4) .. string.rep("*", #key - 8) .. key:sub(-4)
end

-- Open a file/URL with the OS default handler.
local function open_path(path)
  if reaper.CF_ShellExecute then reaper.CF_ShellExecute(path)
  elseif reaper.GetOS():match('Win') then os.execute('start "" "' .. path .. '"')
  elseif reaper.GetOS():match('OSX') or reaper.GetOS():match('macOS') then
    os.execute('open ' .. shellquote(path))
  else os.execute('xdg-open ' .. shellquote(path)) end
end
local function open_url(url) open_path(url) end

-- ---------------------------------------------------------------------------
-- Minimal tolerant JSON reader (flat string / number / bool fields only).
-- Same as Import_Dub_Results.lua — engine_done.json is a flat object of
-- strings. Byte-safe for UTF-8 (escapes and quotes are ASCII; continuation
-- bytes >= 0x80 can never be mistaken for them).
-- ---------------------------------------------------------------------------

local function utf8_encode(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40),
                       0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000),
                       0x80 + math.floor(cp / 0x40) % 0x40,
                       0x80 + cp % 0x40)
  else
    return string.char(0xF0 + math.floor(cp / 0x40000),
                       0x80 + math.floor(cp / 0x1000) % 0x40,
                       0x80 + math.floor(cp / 0x40) % 0x40,
                       0x80 + cp % 0x40)
  end
end

local function skip_ws(s, i)
  while i <= #s do
    local c = s:byte(i)
    if c == 32 or c == 9 or c == 10 or c == 13 then i = i + 1 else break end
  end
  return i
end

local JSON_ESCAPES = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
  n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
}

local function decode_json_string(s, i)
  local buf = {}
  i = i + 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(buf), i + 1
    elseif c == "\\" then
      local e = s:sub(i + 1, i + 1)
      if e == "u" then
        local cp = tonumber(s:sub(i + 2, i + 5), 16) or 0xFFFD
        i = i + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
          local lo = tonumber(s:sub(i + 2, i + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          end
        end
        buf[#buf + 1] = utf8_encode(cp)
      else
        buf[#buf + 1] = JSON_ESCAPES[e] or e
        i = i + 2
      end
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  return table.concat(buf), i
end

local function json_field(s, key)
  local needle = '"' .. key .. '"'
  local pos = 1
  while true do
    local a, b = s:find(needle, pos, true)
    if not a then return nil end
    local i = skip_ws(s, b + 1)
    if s:sub(i, i) == ":" then
      i = skip_ws(s, i + 1)
      local c = s:sub(i, i)
      if c == '"' then
        local v = decode_json_string(s, i)
        return v
      end
      local num = s:match("^%-?%d+%.?%d*", i)
      if num then return tonumber(num) end
      local lit = s:match("^%a+", i)
      if lit == "true" then return true end
      if lit == "false" then return false end
      return nil
    end
    pos = b + 1
  end
end

-- ---------------------------------------------------------------------------
-- PERSISTENT SETTINGS (dub_panel_settings.json next to this script)
-- ---------------------------------------------------------------------------

local APP_DIR    = ""             -- legacy bulk-app dir (venv fallback only)
local PYTHON_CMD = ""             -- optional user override
local LANGUAGE   = "Bengali"
local VOICE_ID   = ""             -- v0.3: persisted in config/tts_settings.json
local EL_MODEL   = "eleven_v3"    -- v0.3: persisted in config/tts_settings.json
local LAST_AUDIO = ""
local FULL_RUN   = false          -- true = v0.1 one-shot run (no review pause)
local SCRIPT_MODE = "auto"        -- v0.4: "auto" = LLM translation,
                                  -- "have" = user pastes the translation
local VC_VOICE_ID = ""            -- v0.4: target voice for track voice change

-- v0.3 LLM settings — mirror of config/llm_settings.json (bulk-app schema).
-- The UI provider values are short tokens; the JSON file stores the bulk
-- app's full provider strings (schema-identical file, empty-by-default).
local LLM_PROVIDER   = "gemini"          -- vertex | gemini | openai
local LLM_MODEL      = "gemini-2.5-pro"  -- written to both openai_model + gemini_model
local LLM_VERTEX_JSON = ""               -- path to a service-account JSON
local LLM_GEMINI_KEY  = ""
local LLM_OPENAI_URL  = ""
local LLM_OPENAI_KEY  = ""
local LLM_PROMPT_CACHING = "1"
-- Advanced, no UI field: the engine's HTTP agent string for gateway calls.
-- Blank means its built-in default. Round-tripped here so saving Settings
-- cannot wipe a value someone set by hand in config/llm_settings.json.
local LLM_USER_AGENT  = ""
-- Server/proxy credentials. Only Auto Sync can use these (it routes every AI
-- call through your server, which holds the real provider keys), but they are
-- entered and stored here so there is exactly ONE place for credentials.
local LLM_SERVER_URL   = ""
local LLM_SERVER_TOKEN = ""

-- v0.3 TTS settings — mirror of config/tts_settings.json.
local EL_KEY              = ""
local GOOGLE_TTS_KEY_PATH = ""

-- JSON provider strings used by the bulk app (schema compatibility).
local PROVIDER_UI     = { "vertex", "gemini", "openai", "server" }
local PROVIDER_TO_JSON = {
  vertex = "Vertex AI (JSON file)",
  gemini = "Gemini API key",
  openai = "OpenAI-compatible (Base URL)",
  -- Auto-Sync-only: the dub engine has no server path and says so when a run
  -- starts. It lives here because this tab is the single home for every
  -- credential, Auto Sync's included.
  server = "Server proxy (Auto Sync only)",
}
local PROVIDER_FROM_JSON = {}
for ui, js in pairs(PROVIDER_TO_JSON) do PROVIDER_FROM_JSON[js] = ui end

-- ElevenLabs model choices (contract v0.3).
local EL_MODELS = { "eleven_v3", "eleven_multilingual_v2",
                    "eleven_turbo_v2_5", "eleven_flash_v2_5" }

-- LLM model choices for the Model dropdowns (V5.model_picker). Google first:
-- the pipeline is tuned on Gemini, and Vertex/Gemini can serve nothing else.
V5.MODELS_GOOGLE = {
  "gemini-3-pro-preview",
  "gemini-3-flash-preview",
  "gemini-2.5-pro",
  "gemini-2.5-flash",
  "gemini-2.5-flash-lite",
  "gemini-2.0-flash",
}
-- What the common OpenAI-compatible gateways (LiteLLM, OpenRouter, vLLM)
-- proxy besides Google. Plain vendor ids: a gateway that namespaces them
-- ("openai/gpt-5", "google/gemini-2.5-pro") needs the Custom entry instead.
V5.MODELS_OTHER = {
  "gpt-5", "gpt-5-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4o", "gpt-4o-mini",
  "o3", "o4-mini",
  "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5",
  "grok-4",
  "deepseek-chat", "deepseek-reasoner",
  "mistral-large-latest", "llama-3.3-70b-instruct",
}

-- Gemini and Vertex reach Google only; a gateway (or the server proxy) can be
-- pointed at anything, so those get the full list. Built once and cached —
-- this is called every frame the Settings window is open.
-- v0.17: what a validated key actually serves, per provider — filled by the
-- Connections probe (V5.conn_poll). A real list beats a hand-maintained one,
-- so once a key has been validated its served list REPLACES the built-ins —
-- a gateway key that serves 4 models must show exactly those 4, not the
-- built-ins padded on top of them (which read as "also available" when they
-- are not, for this key). The built-ins are only the pre-validation guess.
V5.models_fetched = {}

function V5.models_for(provider)
  -- Vertex authenticates with a service-account JSON, so no key probe ever
  -- runs for it; it borrows Gemini's list because Google serves both.
  local fetched = V5.models_fetched[provider == "vertex" and "gemini" or provider]
  if fetched and #fetched > 0 then
    local out, seen = {}, {}
    for _, m in ipairs(fetched) do
      if not seen[m] then out[#out + 1] = m; seen[m] = true end
    end
    return out
  end

  if provider == "gemini" or provider == "vertex" then
    return V5.MODELS_GOOGLE
  end
  if not V5.MODELS_ALL then
    local all = {}
    for _, m in ipairs(V5.MODELS_GOOGLE) do all[#all + 1] = m end
    for _, m in ipairs(V5.MODELS_OTHER)  do all[#all + 1] = m end
    V5.MODELS_ALL = all
  end
  return V5.MODELS_ALL
end

local function load_settings()
  local content = read_all(PANEL_SETTINGS_PATH)
  if not content then return end
  -- Use the real JSON string decoder (json_field/decode_json_string): the
  -- old ad-hoc '([^"]*)' pattern truncated values at the first escaped
  -- quote, corrupting exotic paths on every save/load cycle.
  local function jval(key)
    local v = json_field(content, key)
    if type(v) == "string" then return v end
    return nil
  end
  local v
  -- app_dir is no longer shown in the UI; it is tolerated here so old
  -- settings files keep working and it still drives the legacy-venv fallback.
  v = jval("app_dir")     if v and v ~= "" then APP_DIR    = v end
  v = jval("python_cmd")  if v then PYTHON_CMD = v end
  v = jval("language")    if v and v ~= "" then LANGUAGE   = v end
  -- voice_id / el_model migrated to config/tts_settings.json in v0.3.
  -- Values from an old panel settings file are picked up here and win only
  -- when the tts settings file does not exist yet (see load_tts_config).
  v = jval("voice_id")    if v then VOICE_ID   = v end
  v = jval("el_model")    if v and v ~= "" then EL_MODEL   = v end
  v = jval("last_audio")  if v then LAST_AUDIO = v end
  v = jval("vc_voice_id") if v then VC_VOICE_ID = v end
  v = jval("script_mode")
  if v == "auto" or v == "have" then SCRIPT_MODE = v end
  local b = json_field(content, "full_run")
  if type(b) == "boolean" then FULL_RUN = b end
  -- v0.13 UI state: reveals stay open across launches, and the Tools/Settings
  -- panes reopen where they were left. Purely cosmetic — an absent or
  -- hand-mangled value just falls back to the defaults in the V5 table.
  v = jval("advanced_open")
  if v and v ~= "" then
    for key in v:gmatch("[^,]+") do V5.adv[key] = true end
  end
  v = jval("tool")
  if v == "tts" or v == "regen" or v == "voice" or v == "voices" then
    V5.tool = v
  end
  v = jval("settings_pane") if v and v ~= "" then V5.settings_pane = v end
  -- v0.17: Voices moved to the Tools tab and Languages went away. A settings
  -- file written by an older build can still name them, which would open the
  -- Settings screen on a pane that no longer exists (no tab highlighted, the
  -- Connection body drawn under it).
  if V5.settings_pane == "voices" or V5.settings_pane == "languages" then
    V5.settings_pane = "connection"
  end
  -- v0.16: the rail destination the panel reopens on.
  v = jval("nav")
  if v == "dub" or v == "sync" or v == "tools" or v == "log"
     or v == "settings" then V5.nav = v end
  v = jval("ui_gen") V5.ui_gen = tonumber(v or "") or 0
  -- v0.29 review screen: text size, and which of the two layouts it opens on.
  -- Both are cosmetic, so an absent or hand-mangled value keeps the default.
  local rpx = tonumber(json_field(content, "review_px") or "")
  if rpx == 13 or rpx == 15 or rpx == 17 then V5.review_px = rpx end
  v = jval("review_layout")
  if v == "list" or v == "grid" then V5.review_layout = v end

  -- Coerce a legacy/hand-edited language back into the supported set.
  local ok = false
  for _, l in ipairs(LANGUAGES) do if l == LANGUAGE then ok = true break end end
  if not ok then LANGUAGE = "Bengali" end
end

local function save_settings()
  local f = io.open(PANEL_SETTINGS_PATH, "w")
  if not f then return end
  local function je(s)
    s = tostring(s or "")
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    return s
  end
  -- voice_id / el_model intentionally absent: they moved to
  -- config/tts_settings.json in v0.3 (single source of truth).
  f:write('{\n')
  f:write(string.format('  "app_dir": "%s",\n',    je(APP_DIR)))
  f:write(string.format('  "python_cmd": "%s",\n', je(PYTHON_CMD)))
  f:write(string.format('  "language": "%s",\n',   je(LANGUAGE)))
  f:write(string.format('  "full_run": %s,\n',     FULL_RUN and 'true' or 'false'))
  f:write(string.format('  "script_mode": "%s",\n', je(SCRIPT_MODE)))
  f:write(string.format('  "vc_voice_id": "%s",\n', je(VC_VOICE_ID)))
  -- v0.13 UI state: reveals stay open across launches for power users, and
  -- the Tools/Settings panes reopen where they were left.
  local adv_keys = {}
  for key, on in pairs(V5.adv) do
    if on then adv_keys[#adv_keys + 1] = key end
  end
  table.sort(adv_keys)
  f:write(string.format('  "advanced_open": "%s",\n',
                        je(table.concat(adv_keys, ","))))
  f:write(string.format('  "tool": "%s",\n',          je(V5.tool)))
  f:write(string.format('  "settings_pane": "%s",\n', je(V5.settings_pane)))
  f:write(string.format('  "nav": "%s",\n',           je(V5.nav)))
  f:write(string.format('  "ui_gen": "%s",\n',        je(tostring(V5.ui_gen or 0))))
  f:write(string.format('  "review_px": %d,\n',       math.floor(V5.review_px or 15)))
  f:write(string.format('  "review_layout": "%s",\n', je(V5.review_layout or 'list')))
  f:write(string.format('  "last_audio": "%s"\n',  je(LAST_AUDIO)))
  f:write('}\n')
  f:close()
end

-- JSON string escaping for the config files — same discipline as
-- save_settings above (backslash first, then quote).
local function _json_escape(s)
  s = tostring(s or "")
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  return s
end

-- Load config/llm_settings.json over the in-memory defaults (if present).
local function load_llm_config()
  local content = read_all(LLM_SETTINGS_PATH)
  if not content then return end
  local function jval(key)
    local v = json_field(content, key)
    if type(v) == "string" then return v end
    return nil
  end
  local v
  v = jval("provider")
  if v and PROVIDER_FROM_JSON[v] then LLM_PROVIDER = PROVIDER_FROM_JSON[v] end
  v = jval("vertex_json")      if v then LLM_VERTEX_JSON = v end
  v = jval("gemini_api_key")   if v then LLM_GEMINI_KEY  = v end
  v = jval("openai_base_url")  if v then LLM_OPENAI_URL  = v end
  v = jval("openai_api_key")   if v then LLM_OPENAI_KEY  = v end
  -- The single Model field mirrors into both openai_model and gemini_model
  -- (see save_config_files). On load, gemini_model wins when present; else fall
  -- back to a legacy openai_model-only config.
  local got_model = false
  v = jval("gemini_model")     if v and v ~= "" then LLM_MODEL = v; got_model = true end
  v = jval("openai_model")     if v and v ~= "" and not got_model then LLM_MODEL = v end
  v = jval("prompt_caching")   if v and v ~= "" then LLM_PROMPT_CACHING = v end
  v = jval("http_user_agent")  if v then LLM_USER_AGENT = v end
  v = jval("server_url")       if v then LLM_SERVER_URL   = v end
  v = jval("server_token")     if v then LLM_SERVER_TOKEN = v end
  -- v0.7 per-stage model overrides. Blank = "use the Model field above",
  -- which is what every existing config has, so nothing changes on upgrade.
  for _, role in ipairs(V5.MODEL_ROLES) do
    v = jval("model_" .. role[1])
    if v then V5.model_roles[role[1]] = v end
  end
end

-- Load config/tts_settings.json (if present). Its voice_id / el_model win
-- over values migrated from an old dub_panel_settings.json.
local function load_tts_config()
  local content = read_all(TTS_SETTINGS_PATH)
  if not content then return end
  local function jval(key)
    local v = json_field(content, key)
    if type(v) == "string" then return v end
    return nil
  end
  local v
  v = jval("elevenlabs_api_key")  if v then EL_KEY = v end
  v = jval("el_model")            if v and v ~= "" then EL_MODEL = v end
  v = jval("voice_id")            if v then VOICE_ID = v end
  v = jval("google_tts_key_path") if v then GOOGLE_TTS_KEY_PATH = v end
end

-- Normalise the OpenAI-compatible base URL before it reaches the engine, which
-- appends "/v1/chat/completions" itself. Users paste the full endpoint (doubling
-- the path) or the chat UI's address (…/ui, which serves HTML and redirects API
-- calls to a login page) — strip both, plus any trailing slash.
local function _clean_base_url(u)
  u = (u or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
  u = u:gsub("/[Cc][Hh][Aa][Tt]/[Cc][Oo][Mm][Pp][Ll][Ee][Tt][Ii][Oo][Nn][Ss]$", "")
  u = u:gsub("/[Uu][Ii]$", "")
  return (u:gsub("/+$", ""))
end

-- ── Single source of truth for credentials ──────────────────────────────────
-- Auto Sync keeps its own flat settings file in the fast-syncs root, read by
-- run_sync.py. The keys it needs are the SAME keys typed in this tab, so rather
-- than asking for them twice, every save pushes them over there. Only the
-- shared keys are touched: tracks, language, match mode, script text and the
-- python override stay exactly as Auto Sync left them.
--
-- BASE_DIR is <root>/dubbing (this panel lives in <root>/dubbing/reaper), so the
-- root is one level up. Computed here, not from V5.FS_ROOT, because a migration
-- save can run at load time before V5.FS_ROOT is assigned further down.
local SYNC_SETTINGS_PATH = (BASE_DIR:match("^(.*)[/\\][^/\\]*$") or BASE_DIR)
                           .. SEP .. "sync_pipeline_settings.json"

-- Set one flat "key": "value" pair in raw JSON text, preserving every other
-- key byte-for-byte (script_text is multi-line and must not be re-encoded).
-- Replacement goes through a function so a "%" in a key or URL is never read
-- as a gsub capture reference.
local function _json_set_flat(content, key, value)
  local esc = _json_escape(value)
  local n
  content, n = content:gsub('("' .. key .. '"%s*:%s*")[^"]*(")',
                            function(pre, post) return pre .. esc .. post end, 1)
  if n > 0 then return content end
  -- Key not in the file yet: splice it in before the closing brace.
  local i = content:find("}[^}]*$")
  if not i then return content end
  local head = content:sub(1, i - 1):gsub("%s+$", "")
  local sep  = (head:sub(-1) == "{") and "\n" or ",\n"
  return head .. sep .. '  "' .. key .. '": "' .. esc .. '"\n' .. content:sub(i)
end

-- Mirror this tab's credentials into sync_pipeline_settings.json.
-- Returns true, or false + the path on write failure (non-fatal: the dub
-- engine's own config files are already written by then).
local function save_sync_credentials()
  -- Provider vocabularies differ by design: Auto Sync says "studio" for a
  -- Gemini API key and "gateway" for an OpenAI-compatible base URL.
  local conn = ({ vertex = "vertex", gemini = "studio",
                  openai = "gateway", server = "server" })[LLM_PROVIDER] or "vertex"
  -- gemini_backend is what run_sync.py actually reads; mirror Auto Sync's own
  -- _apply_conn_mode() mapping. In server mode the backend is irrelevant
  -- (api_base routes everything through the proxy) — leave a sane default.
  local backend = ({ vertex = "vertex", studio = "rest",
                     gateway = "gateway", server = "vertex" })[conn]
  -- Auto Sync stores BOTH the Gemini key and the gateway Bearer token in one
  -- field, so hand over the one that matches the chosen mode. Sending the
  -- other would look like an auth failure on the far side.
  local shared_key = (LLM_PROVIDER == "openai") and LLM_OPENAI_KEY or LLM_GEMINI_KEY
  local pairs_out = {
    { "conn_mode",       conn },
    { "gemini_backend",  backend },
    -- v0.7: Auto Sync's matching gets its own model when one is set here;
    -- gemini_model is the only model key run_sync.py reads.
    { "gemini_model",    (V5.model_roles.sync_match or "") ~= ""
                         and V5.model_roles.sync_match or LLM_MODEL },
    { "gemini_key",      shared_key },
    { "gemini_base_url", LLM_OPENAI_URL },
    { "vertex_key_path", LLM_VERTEX_JSON },
    { "elevenlabs_key",  EL_KEY },
    { "server_url",      LLM_SERVER_URL },
    { "api_token",       LLM_SERVER_TOKEN },
    -- api_base is the switch that turns proxy mode on for the Python worker:
    -- the server URL in server mode, empty in every direct mode.
    { "api_base",        (conn == "server") and LLM_SERVER_URL or "" },
  }

  local content
  local rf = io.open(SYNC_SETTINGS_PATH, "r")
  if rf then content = rf:read("*a"); rf:close() end

  -- One-time safety net: an install that had its OWN keys in here (set up
  -- through the Auto Sync tab before this tab owned credentials) gets a copy
  -- kept beside the file the first time we rewrite it. Only ever written once,
  -- so it always holds the pre-unification values. Gitignored like the original.
  if content and content:find("{") then
    local bak = SYNC_SETTINGS_PATH .. ".bak"
    local probe = io.open(bak, "r")
    if probe then
      probe:close()
    else
      local bf = io.open(bak, "w")
      if bf then bf:write(content); bf:close() end
    end
  end

  if not content or not content:find("{") then content = "{\n}\n" end
  for _, kv in ipairs(pairs_out) do
    content = _json_set_flat(content, kv[1], kv[2])
  end

  local wf = io.open(SYNC_SETTINGS_PATH, "w")
  if not wf then return false, SYNC_SETTINGS_PATH end
  wf:write(content)
  wf:close()
  return true
end

-- Non-nil when the last save could not reach sync_pipeline_settings.json; the
-- Save button surfaces it instead of claiming a clean save.
local LAST_SYNC_CRED_ERR = nil

-- Credential fields cleared on purpose this session (per-field "Clear" button).
-- New file-scope state goes on V5: the main chunk is at Lua's 200-local limit.
V5.cred_cleared = {}

-- The value a credential currently has on disk, or "" — used to refuse to
-- overwrite a stored key with a blank box.
function V5.stored_secret(path, key)
  local content = read_all(path)
  if not content then return "" end
  local v = json_field(content, key)
  return (type(v) == "string") and v or ""
end

-- A save rewrites EVERY field, so an empty key box would erase a key that is
-- already on disk — and the engine would then post to the gateway with no
-- Authorization header and read back "No api key passed in.", which looks like
-- a wrong key rather than a missing one. So: an empty box KEEPS the stored
-- value, and the per-field "Clear" button is the only way to remove a key.
-- The recovered value goes back into the UI variable, so the tab shows what is
-- really stored instead of a blank that lies.
function V5.keep_stored_credentials()
  local function keep(field, cur, path, key)
    if cur ~= "" then return cur end
    if V5.cred_cleared[field] then return "" end
    return V5.stored_secret(path, key)
  end
  LLM_GEMINI_KEY   = keep("gemini", LLM_GEMINI_KEY,
                          LLM_SETTINGS_PATH, "gemini_api_key")
  LLM_OPENAI_KEY   = keep("openai", LLM_OPENAI_KEY,
                          LLM_SETTINGS_PATH, "openai_api_key")
  LLM_SERVER_TOKEN = keep("server", LLM_SERVER_TOKEN,
                          LLM_SETTINGS_PATH, "server_token")
  EL_KEY           = keep("el",     EL_KEY,
                          TTS_SETTINGS_PATH, "elevenlabs_api_key")
  V5.cred_cleared = {}
end

-- True when this gateway base URL is remote, so a blank API key cannot work.
-- Mirrors _gateway_needs_key() in pipeline/llm.py: a gateway on this machine or
-- the LAN (Ollama, LM Studio, vLLM, a local LiteLLM) may serve without a key.
function V5.gateway_needs_key(url)
  local host = (url or ""):gsub("^%a[%w+.%-]*://", "")
  host = host:match("^([^/]*)") or ""
  host = host:match("([^@]*)$") or host              -- drop any userinfo
  if host:sub(1, 1) == "[" then                     -- bracketed IPv6 literal
    host = host:match("^(%[.-%])") or host
  else
    host = host:gsub(":%d+$", "")
  end
  host = host:lower()
  if host == "localhost" or host == "0.0.0.0"
     or host == "::1" or host == "[::1]" then return false end
  if host:match("^127%.%d+%.%d+%.%d+$")   then return false end
  if host:match("^10%.%d+%.%d+%.%d+$")    then return false end
  if host:match("^192%.168%.%d+%.%d+$")   then return false end
  local second = tonumber(host:match("^172%.(%d+)%.%d+%.%d+$"))
  if second and second >= 16 and second <= 31 then return false end
  if host:match("%.local$") then return false end
  return true
end

-- nil when the active provider's credentials are complete, else a message
-- naming what is missing. Mirrors _validate_llm_config() in pipeline/llm.py so
-- an LLM run is refused HERE, with the Settings tab one click away, instead of
-- in an engine traceback.
function V5.llm_creds_error()
  if LLM_PROVIDER == "server" then
    return "Provider is 'Server proxy', which dubbing cannot use — the dub " ..
           "engine calls the LLM directly. Pick Vertex, Gemini or " ..
           "OpenAI-compatible in Settings (Auto Sync keeps using the server)."
  end
  if LLM_MODEL == "" then return "Model is empty in Settings." end
  if LLM_PROVIDER == "gemini" then
    if LLM_GEMINI_KEY == "" then
      return "Gemini API key is empty in Settings."
    end
  elseif LLM_PROVIDER == "openai" then
    if LLM_OPENAI_URL == "" then
      return "Gateway base URL is empty in Settings."
    end
    if LLM_OPENAI_KEY == "" and V5.gateway_needs_key(LLM_OPENAI_URL) then
      return "Gateway API key is empty in Settings. Without it every request " ..
             "goes out unauthenticated and the gateway answers 401 " ..
             "(\"No api key passed in.\"). Only a gateway on this machine or " ..
             "the LAN may be left blank."
    end
  elseif LLM_PROVIDER == "vertex" then
    local p = (LLM_VERTEX_JSON ~= "") and LLM_VERTEX_JSON
              or (CONFIG_DIR .. SEP .. "vertex_key.json")
    if not file_exists(p) then
      return "Vertex service-account JSON not found:\n" .. p ..
             "\nSet its path in Settings."
    end
  end
  return nil
end

-- Write BOTH config files. Creates config/ when missing. Returns true on
-- success; false with an error banner path string on failure.
local function save_config_files()
  reaper.RecursiveCreateDirectory(CONFIG_DIR, 0)
  V5.keep_stored_credentials()

  -- llm_settings.json — schema identical to the bulk app's file.
  local f = io.open(LLM_SETTINGS_PATH, "w")
  if not f then return false, LLM_SETTINGS_PATH end
  f:write('{\n')
  f:write(string.format('  "provider": "%s",\n',
    _json_escape(PROVIDER_TO_JSON[LLM_PROVIDER] or PROVIDER_TO_JSON.gemini)))
  f:write(string.format('  "vertex_json": "%s",\n',     _json_escape(LLM_VERTEX_JSON)))
  f:write(string.format('  "gemini_api_key": "%s",\n',  _json_escape(LLM_GEMINI_KEY)))
  LLM_OPENAI_URL = _clean_base_url(LLM_OPENAI_URL)
  f:write(string.format('  "openai_base_url": "%s",\n', _json_escape(LLM_OPENAI_URL)))
  f:write(string.format('  "openai_api_key": "%s",\n',  _json_escape(LLM_OPENAI_KEY)))
  -- One Model field drives every provider: write it to both keys so the engine
  -- reads the right one (openai_model for the OpenAI path, gemini_model for the
  -- vertex / gemini-key paths).
  f:write(string.format('  "openai_model": "%s",\n',    _json_escape(LLM_MODEL)))
  f:write(string.format('  "gemini_model": "%s",\n',    _json_escape(LLM_MODEL)))
  -- v0.7: one optional model per stage. Blank means "use the Model above";
  -- the engine's _model_for() resolves it that way, so writing them always
  -- (even empty) keeps the file's shape stable.
  for _, role in ipairs(V5.MODEL_ROLES) do
    f:write(string.format('  "model_%s": "%s",\n', role[1],
      _json_escape(V5.model_roles[role[1]] or "")))
  end
  f:write(string.format('  "http_user_agent": "%s",\n', _json_escape(LLM_USER_AGENT)))
  f:write(string.format('  "server_url": "%s",\n',      _json_escape(LLM_SERVER_URL)))
  f:write(string.format('  "server_token": "%s",\n',    _json_escape(LLM_SERVER_TOKEN)))
  f:write(string.format('  "prompt_caching": "%s"\n',   _json_escape(LLM_PROMPT_CACHING)))
  f:write('}\n')
  f:close()

  -- tts_settings.json — contract v0.3 schema.
  f = io.open(TTS_SETTINGS_PATH, "w")
  if not f then return false, TTS_SETTINGS_PATH end
  f:write('{\n')
  f:write(string.format('  "elevenlabs_api_key": "%s",\n', _json_escape(EL_KEY)))
  f:write(string.format('  "el_model": "%s",\n',           _json_escape(EL_MODEL)))
  f:write(string.format('  "voice_id": "%s",\n',           _json_escape(VOICE_ID)))
  f:write(string.format('  "google_tts_key_path": "%s"\n', _json_escape(GOOGLE_TTS_KEY_PATH)))
  f:write('}\n')
  f:close()

  -- Hand the shared credentials to Auto Sync, then let its embedded module pick
  -- them up so the tab shows the new values without a panel restart. A failure
  -- here does not fail the save: the dub engine's own config is already on disk.
  local synced, sync_path = save_sync_credentials()
  LAST_SYNC_CRED_ERR = (not synced) and sync_path or nil
  if V5 and V5.SYNC and V5.SYNC.reload_settings then
    pcall(V5.SYNC.reload_settings)
  end
  return true
end

-- Adopt credentials that only Auto Sync knows about. Installs that set Auto Sync
-- up FIRST have keys — and a remembered proxy URL + token — in its settings file
-- and nothing here; without this, the first save from this tab would overwrite
-- them with blanks. Only fields that are still EMPTY here get filled, so a value
-- already in config/llm_settings.json always wins and nothing typed in this tab
-- can be undone.
local function seed_credentials_from_sync()
  local f = io.open(SYNC_SETTINGS_PATH, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  local function jval(key)
    local v = content:match('"' .. key .. '"%s*:%s*"([^"]*)"')
    if v then v = v:gsub('\\(["\\])', '%1') end
    return v or ""
  end

  if EL_KEY == ""           then EL_KEY = jval("elevenlabs_key") end
  if LLM_VERTEX_JSON == ""  then LLM_VERTEX_JSON = jval("vertex_key_path") end
  if LLM_OPENAI_URL == ""   then LLM_OPENAI_URL = jval("gemini_base_url") end
  if LLM_SERVER_URL == ""   then LLM_SERVER_URL = jval("server_url") end
  if LLM_SERVER_TOKEN == "" then LLM_SERVER_TOKEN = jval("api_token") end

  -- Auto Sync stores one key field whose meaning depends on its mode: an
  -- "AIza…" Google key in studio mode, a Bearer token in gateway mode.
  local conn, shared_key = jval("conn_mode"), jval("gemini_key")
  if conn == "gateway" and LLM_OPENAI_KEY == "" then
    LLM_OPENAI_KEY = shared_key
  elseif conn == "studio" and LLM_GEMINI_KEY == "" then
    LLM_GEMINI_KEY = shared_key
  end

  -- No llm_settings.json at all: this tab has never been used, so Auto Sync's
  -- mode is the only stated intent — adopt it instead of showing a default that
  -- would overwrite a working setup on the first save.
  if not file_exists(LLM_SETTINGS_PATH) then
    local from_conn = { server = "server", studio = "gemini",
                        vertex = "vertex", gateway = "openai" }
    if from_conn[conn] then LLM_PROVIDER = from_conn[conn] end
    local m = jval("gemini_model")
    if m ~= "" then LLM_MODEL = m end
  end
end

-- v0.8: dub piece size (sentence | section), stored in engine_settings.json
-- where the engine's _chunk_mode() reads it. V5 fields — 200-local limit.
V5.chunk_mode = "clause"
V5.sync_mode  = "match"

function V5.load_chunk_mode()
  local content = read_all(ENGINE_SETTINGS_PATH)
  if not content then return end
  local v = json_field(content, "chunk_mode")
  if v == "clause" or v == "sentence" or v == "section" then
    V5.chunk_mode = v
  end
  local s = json_field(content, "sync_mode")
  if s == "match" or s == "legacy" then
    V5.sync_mode = s
  end
end

function V5.save_chunk_mode()
  -- NOTE: no ui_set_banner here — it is declared further down the file, so
  -- this closure could not capture it. Returns ok, path for the caller.
  local content = read_all(ENGINE_SETTINGS_PATH)
  if not content or not content:find("{") then content = "{\n}\n" end
  content = _json_set_flat(content, "chunk_mode", V5.chunk_mode)
  content = _json_set_flat(content, "sync_mode", V5.sync_mode)
  local f = io.open(ENGINE_SETTINGS_PATH, "w")
  if not f then return false, ENGINE_SETTINGS_PATH end
  f:write(content)
  f:close()
  return true
end
V5.load_chunk_mode()

-- app_dir default chain: panel settings → engine/engine_settings.json →
-- contract default.
local function resolve_default_app_dir()
  local content = read_all(ENGINE_SETTINGS_PATH)
  if content then
    local v = json_field(content, "app_dir")
    if type(v) == "string" and v ~= "" then return v end
  end
  return DEFAULT_APP_DIR
end

load_settings()
if APP_DIR == "" then APP_DIR = resolve_default_app_dir() end
-- Config files override the panel-settings values loaded above (migration:
-- when they do not exist yet, old dub_panel_settings values survive and get
-- written into config/ on the next save).
load_llm_config()
load_tts_config()
-- Then fill any credential this tab still lacks from Auto Sync's file, so the
-- two never disagree and nothing is lost the first time Settings is saved.
seed_credentials_from_sync()
-- One-time migration: voice_id / el_model used to live in
-- dub_panel_settings.json. Persist them into config/tts_settings.json right
-- away so they cannot be lost when the panel settings file is rewritten.
if not file_exists(TTS_SETTINGS_PATH)
   and (VOICE_ID ~= "" or EL_MODEL ~= "eleven_v3") then
  save_config_files()
end

-- ---------------------------------------------------------------------------
-- ReaImGui availability probe + ReaPack guidance (fast-syncs pattern)
-- ---------------------------------------------------------------------------

-- Robust ReaImGui detection. Some installs register the symbol before the
-- extension is fully loaded, so APIExists alone can be a false positive that
-- then crashes an unprotected ImGui_CreateContext. Probe with a real
-- CreateContext whenever the function is callable, and trust that.
local function imgui_available()
  if reaper.ImGui_CreateContext ~= nil then
    local ok, ctx = pcall(reaper.ImGui_CreateContext, 'probe')
    if ok and ctx then
      if reaper.ImGui_DestroyContext then pcall(reaper.ImGui_DestroyContext, ctx) end
      return true
    end
    return false   -- symbol present but not actually usable yet
  end
  if reaper.APIExists and reaper.APIExists('ImGui_CreateContext') then
    return true
  end
  return false
end

local REAIMGUI_REPO_URL = "https://github.com/ReaTeam/Extensions/raw/master/index.xml"

local function try_reapack_install()
  if not (reaper.APIExists and reaper.APIExists('ReaPack_AddSetRepository')) then
    return false
  end
  local ok, err = reaper.ReaPack_AddSetRepository(
    'ReaTeam Extensions', REAIMGUI_REPO_URL, true, 2)
  if not ok then
    reaper.ShowMessageBox(
      "Could not add the ReaImGui repository automatically:\n" ..
      tostring(err) .. "\n\nFalling back to manual steps.",
      "ReaPack", 0)
    return false
  end
  if reaper.APIExists('ReaPack_ProcessQueue') then
    pcall(reaper.ReaPack_ProcessQueue, true)
  end
  if reaper.APIExists('ReaPack_BrowsePackages') then
    pcall(reaper.ReaPack_BrowsePackages, 'ReaImGui')
  end
  reaper.ShowMessageBox(
    "The ReaImGui repository was added and the package browser opened.\n\n" ..
    "Finish the install:\n" ..
    "  1. Right-click 'ReaImGui: ReaScript binding for Dear ImGui'.\n" ..
    "  2. Choose Install, then click Apply.\n" ..
    "  3. Restart REAPER and run this script again.",
    "Almost done", 0)
  return true
end

-- Pick the ReaPack release asset matching this REAPER build.
local function _reapack_asset()
  local os_str = reaper.GetOS() or ""
  local v = (reaper.GetAppVersion() or ""):lower()
  if os_str == "Win64" then
    if v:match("arm64") then return "reaper_reapack-arm64ec.dll" end
    return "reaper_reapack-x64.dll"
  elseif os_str == "Win32" then
    return "reaper_reapack-x86.dll"
  elseif os_str == "macOS-arm64" then
    return "reaper_reapack-arm64.dylib"
  elseif os_str == "OSX64" then
    return "reaper_reapack-x86_64.dylib"
  elseif os_str:match("^OSX") then
    return "reaper_reapack-i386.dylib"
  elseif os_str == "linux-x86_64" then
    return "reaper_reapack-x86_64.so"
  elseif os_str == "linux-aarch64" then
    return "reaper_reapack-aarch64.so"
  elseif os_str == "linux-armv7l" then
    return "reaper_reapack-armv7l.so"
  elseif os_str == "linux-i686" then
    return "reaper_reapack-i686.so"
  end
  return nil
end

local function try_reapack_bootstrap()
  local asset = _reapack_asset()
  if not asset or not reaper.ExecProcess then return false end
  local res = reaper.GetResourcePath()
  local dir = res .. SEP .. "UserPlugins"
  reaper.RecursiveCreateDirectory(dir, 0)
  local dest = dir .. SEP .. asset
  local url  = "https://github.com/cfillion/reapack/releases/latest/download/" .. asset
  local curl = reaper.GetOS():match("Win") and "curl.exe" or "/usr/bin/curl"
  -- ExecProcess is synchronous — REAPER's UI is frozen for the duration.
  -- Bound the network work (10 s to connect, 60 s total) so a slow/offline
  -- network can't lock the UI for the full 2 minutes.
  local ret = reaper.ExecProcess(
    curl .. ' -fsSL --retry 2 --connect-timeout 10 -m 60 -o "'
         .. dest .. '" "' .. url .. '"', 65000)
  local code = ret and ret:match("^(%-?%d+)")
  local f = io.open(dest, "rb")
  local size = 0
  if f then size = f:seek("end") or 0; f:close() end
  if code ~= "0" or size < 500000 then
    os.remove(dest)
    return false
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Python discovery (fast-syncs probe_python pattern)
-- ---------------------------------------------------------------------------

-- Resolve a Python *command* to a real interpreter path by RUNNING it.
-- io.open() resolves relative names against REAPER's cwd, never the PATH,
-- so bare names like "python" can only be validated by execution. Also
-- rejects the Microsoft Store placeholder alias on stock Windows.
local function probe_python(cmd)
  if not reaper.ExecProcess then return nil end
  -- Synchronous call on the UI thread: keep the timeout short so a hung
  -- interpreter (Store alias, network shim) can't freeze REAPER for long.
  local ret = reaper.ExecProcess(
    cmd .. ' -c "import sys;print(sys.executable)"', 5000)
  if not ret then return nil end
  local code, out = ret:match("^(%-?%d+)[\r\n]+(.*)$")
  if code ~= "0" or not out then return nil end
  local path = out:match("^%s*([^\r\n]+)")
  if path then path = path:gsub("%s+$", "") end
  if path and path ~= "" and file_exists(path) then return path end
  return nil
end

-- Path of the project's own venv interpreter (created by setup_mac.command).
-- v0.3: this is the primary interpreter with every pipeline dep.
local function project_venv_python()
  if _is_windows() then
    return BASE_DIR .. "\\venv\\Scripts\\python.exe"
  end
  return BASE_DIR .. "/venv/bin/python3"
end

-- Path of the legacy bulk-app venv interpreter (transition fallback only).
local function venv_python_path()
  if _is_windows() then
    return APP_DIR .. "\\.venv\\Scripts\\python.exe"
  end
  return APP_DIR .. "/.venv/bin/python3"
end

-- Order: settings override → project venv/ → legacy bulk-app venv
-- (transition) → common installs.
local function find_python()
  -- 1. User-pinned override.
  if PYTHON_CMD ~= "" then
    if file_exists(PYTHON_CMD) then return PYTHON_CMD end
    if not PYTHON_CMD:find("[/\\]") then
      local probe_cmd = PYTHON_CMD:find("%s") and PYTHON_CMD
                        or ('"' .. PYTHON_CMD .. '"')
      local resolved = probe_python(probe_cmd)
      if resolved then return resolved end
    end
  end

  -- 2. The project's own venv — created by setup_mac.command.
  local proj_py = project_venv_python()
  if file_exists(proj_py) then return proj_py end

  -- 3. Legacy bulk-app venv (transition fallback while migrating installs).
  if APP_DIR ~= "" then
    local venv_py = venv_python_path()
    if file_exists(venv_py) then return venv_py end
  end

  -- 4. Common system installs (last resort — the launcher itself is
  --    stdlib-only, but the pipeline needs the venv's deps, so this
  --    mostly serves clearer error reporting from dub_engine.py).
  if _is_windows() then
    for _, c in ipairs({ 'py -3', 'python', 'python3' }) do
      local resolved = probe_python(c)
      if resolved then return resolved end
    end
  else
    local candidates = {
      "/opt/homebrew/bin/python3",
      "/usr/local/bin/python3",
      "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
      "/usr/bin/python3",
    }
    for _, c in ipairs(candidates) do
      if file_exists(c) then
        if c ~= "/usr/bin/python3" then return c end
        -- Without the Xcode Command Line Tools, /usr/bin/python3 is Apple's
        -- stub: it pops an "install developer tools" GUI dialog (behind
        -- REAPER) and exits without running anything. Only trust it when
        -- the CLT is actually installed.
        local ok = os.execute('xcode-select -p >/dev/null 2>&1')
        if ok == true or ok == 0 then return c end
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Stage protocol — worker prints "[S1a] message" lines
-- ---------------------------------------------------------------------------

local STAGE_ORDER = { "S1a", "S1b", "S2a", "S2b", "S2c", "S2d",
                      "S3a", "S3b", "S3c", "S3d", "S3e" }
-- v0.7: the default match mode does Gemini matching + per-section TTS
-- under S2d and only book-keeps S3a-S3c, so those labels are worded to
-- fit both modes (legacy still re-transcribes + maps in S3b/S3c).
local STAGE_LABELS = {
  S1a = "Transcribe (speech-to-text)",
  S1b = "Regions / SRT",
  S2a = "Translate",
  S2b = "Review",
  S2c = "Punctuation",
  S2d = "Match + TTS (ElevenLabs)",
  S3a = "Sync SRT (EN)",
  S3b = "Chunk boundaries",
  S3c = "EN ↔ script mapping",
  S3d = "Placement (springs)",
  S3e = "Render synced audio",
}
local STAGE_INDEX = {}
for i, tag in ipairs(STAGE_ORDER) do STAGE_INDEX[tag] = i end

-- Stage subsets per run mode (v0.2 staged runs). Progress and the running
-- checklist are computed against the ACTIVE mode's list so a translate-only
-- run still reaches 100% instead of stalling at S2c. "regen" has no stages.
-- v0.13: the pause-aware modes reuse S1a/S1b for transcribe + pause
-- detection, and dubplan reuses the dub tail. "plan" makes no API call
-- beyond the (cached) transcription, so its checklist is deliberately short.
local MODE_STAGES = {
  full      = STAGE_ORDER,
  translate = { "S1a", "S1b", "S2a", "S2b", "S2c" },
  dub       = { "S2d", "S3a", "S3b", "S3c", "S3d", "S3e" },
  plan      = { "S1a", "S1b" },
  dubplan   = { "S1a", "S1b", "S2d", "S3a", "S3b", "S3c", "S3d", "S3e" },
}

-- ---------------------------------------------------------------------------
-- UI state machine
-- ---------------------------------------------------------------------------

local _ui_ctx          = nil
local _ui_phase        = "setup"   -- setup | running | review | success | failure
local _ui_banner       = nil       -- { kind = "error"|"info"|"warn", text }
local _ui_window_open  = true
local _ui_font         = nil       -- Unicode/Indic-capable font for log lines
local _ui_failure      = nil       -- { error_tail, log_path }
local _log_buffer      = {}        -- ring of last ~500 log lines
local _log_autoscroll  = true

local _ui_stage_tag    = nil       -- last seen [Sxx] tag
local _ui_progress     = 0.0
local _ui_cancelled    = false     -- a kill was actually issued
local _cancel_pending  = false     -- Cancel clicked before engine_pid.txt existed

local _manifest        = nil       -- engine_done.json fields (success phase)
local _import_summary  = nil       -- text after "Import to timeline" ran
local _imported        = false

-- v0.2/v0.3 run mode: which engine invocation the current/last poll belongs
-- to. Drives the stage checklist and the finish handling.
local _run_mode        = "full"    -- full | translate | dub | regen |
                                   -- test_llm | list_voices | voice_change |
                                   -- tts (v0.7 Text to Speech tab)

-- Utility modes never own the phase state: they report back into the phase
-- they were launched from and leave the last run's manifest untouched.
local UTIL_MODES = { regen = true, test_llm = true, list_voices = true,
                     voice_change = true, tts = true, preview = true }
local _util_return_phase = "setup" -- phase to return to when test/fetch ends

-- v0.21: a QUIET job is a utility run the panel never enters the run phase
-- for — the voice fetch. It goes through the same launch/poll machinery as
-- everything else (run_dub.py's status/ files are a single set, so only one
-- job can ever be out), but it leaves _ui_phase alone: no run screen on the
-- Dub tab, no "a run is in progress · Go to Dub" in every header, no locked
-- Settings, and — the bug this fixes — no failure screen when the launch
-- watchdog fires. The button that started it shows the spinner and the
-- banner reports the outcome, right where you pressed it.
-- Holds the mode string while such a job is in flight, nil otherwise.
V5.quiet_job = nil

-- True while the engine is busy with anything — a dub run or a quiet job.
-- Every control that would launch a second engine call gates on this.
function V5.busy()
  return _ui_phase == "running" or V5.quiet_job ~= nil
end

-- v0.3 Settings section state. (v0.17: the panel-wide "Show keys" flag that
-- used to live here is gone — reveal is per field, in V5.key_shown.)
local _voices          = {}        -- { {id=..., name=...}, ... } from --list-voices
local _voices_language = ""        -- language the list was fetched for

-- Review phase state (staged run paused between translation and dubbing):
-- { manifest, en_paras, tr_paras, tr_buffer, use_table, base, edited_path,
--   dirty }
local _review          = nil
-- Review manifest found in status/ at startup (panel closed mid-review).
local _resume_manifest = nil

-- v0.13 plan phase state (pause-aware dry run paused at the approval gate):
-- { manifest, rows, plan_path, html_path, use_table, counts }. V5 fields,
-- not locals — the main chunk sits at Lua's 200-local limit.
V5.plan             = nil
-- The target script file the plan run was launched with, so ⟲ Reload can
-- re-run the (free) analysis without making the user paste the script again.
V5.plan_script_path = nil

-- Chunk regeneration state.
local _regen_out_dir      = ""     -- out_dir of the last known manifest
local _regen_lang         = ""     -- language of the last known manifest
local _regen_sel_guid     = ""     -- GUID of the item whose note was loaded
local _regen_text         = ""     -- editable chunk text
local _regen_pending      = nil    -- { guid, note, out_wav } while running
local _regen_return_phase = "setup" -- phase to return to when regen ends
-- v0.8: optional per-regen voice override ("" = the ⚙ Settings voice).
-- V5 field, not a local — the main chunk sits at Lua's 200-local limit.
V5.regen_voice            = ""

-- v0.4 "I already have the translation": pasted script (in-memory only —
-- written to <out_dir>/<base>_provided_translation.txt at launch).
local _provided_text      = ""

-- v0.4 track voice change state.
local _vc_track_idx       = -1     -- 0-based index of the chosen track
local _vc_pending         = nil    -- { guid, in_wav, out_wav, track_name }
local _vc_return_phase    = "setup"

-- v0.4.1 "English audio from track" state (setup phase source picker).
local _src_track_idx      = -1     -- 0-based index of the chosen track

-- Poll state
local _poll_last_size  = 0
local _poll_partial    = ""        -- carry an incomplete trailing line
local _poll_start_time = 0

local function log_append(line)
  if not line or line == "" then return end
  _log_buffer[#_log_buffer + 1] = line
  if #_log_buffer > 500 then table.remove(_log_buffer, 1) end
end

local function ui_set_banner(kind, text) _ui_banner = { kind = kind, text = text } end
local function ui_clear_banner() _ui_banner = nil end

-- Version-safe BeginDisabled / EndDisabled (older ReaImGui lacks them).
local function _ui_begin_disabled(ctx, cond)
  if reaper.ImGui_BeginDisabled then reaper.ImGui_BeginDisabled(ctx, cond) end
end
local function _ui_end_disabled(ctx)
  if reaper.ImGui_EndDisabled then reaper.ImGui_EndDisabled(ctx) end
end

-- Version-safe child-window border flag (renamed across ReaImGui releases).
local function _child_border_flag()
  if reaper.ImGui_ChildFlags_Borders then return reaper.ImGui_ChildFlags_Borders() end
  if reaper.ImGui_ChildFlags_Border  then return reaper.ImGui_ChildFlags_Border()  end
  return 0
end

-- v0.19: "this child never scrolls". For a column that only WRAPS something
-- which scrolls on its own — a text box, a list child — because two nested
-- scroll regions mean the wheel does a different thing depending on which
-- pixel the pointer is over, and the outer scrollbar eats width off the inner
-- box for no gain. Both flags: NoScrollbar hides the bar, NoScrollWithMouse
-- hands the wheel to the parent instead of swallowing it.
function V5.noscroll_flags()
  local f = 0
  if reaper.ImGui_WindowFlags_NoScrollbar then
    f = f | reaper.ImGui_WindowFlags_NoScrollbar()
  end
  if reaper.ImGui_WindowFlags_NoScrollWithMouse then
    f = f | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  end
  return f
end

-- Version-safe PushFont: newer ReaImGui takes (ctx, font, size), older
-- (ctx, font). Returns true when a font was actually pushed so the caller
-- pops only then (avoids stack imbalance).
local function _push_font(ctx, size)
  if not _ui_font then return false end
  if pcall(reaper.ImGui_PushFont, ctx, _ui_font, size) then return true end
  if pcall(reaper.ImGui_PushFont, ctx, _ui_font) then return true end
  return false
end
local function _pop_font(ctx)
  pcall(reaper.ImGui_PopFont, ctx)
end

-- Combo helper: items as a table, returns (changed, new_value).
local function _ui_combo(ctx, label, current, items)
  local idx = 0
  for i, v in ipairs(items) do if v == current then idx = i - 1 break end end
  local rv, new_idx = reaper.ImGui_Combo(ctx, label, idx, table.concat(items, "\0") .. "\0")
  if rv then return true, items[new_idx + 1] end
  return false, current
end

local function _ui_render_banner(ctx)
  if not _ui_banner then return end
  local color
  if     _ui_banner.kind == "error" then color = 0xFF5555FF
  elseif _ui_banner.kind == "warn"  then color = 0xFFCC55FF
  else                                   color = 0x55AAFFFF end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x22222266)
  if reaper.ImGui_BeginChild(ctx, '##banner', -1, 48, _child_border_flag()) then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color)
    reaper.ImGui_TextWrapped(ctx, _ui_banner.text)
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx)
  if reaper.ImGui_SmallButton(ctx, 'Dismiss##bn') then _ui_banner = nil end
  reaper.ImGui_Separator(ctx)
end

-- The one animated thing on the panel: every "something is happening" label
-- (checking a key, fetching voices, a run in flight) spins this.
--
-- WALL clock, via reaper.time_precise. os.clock() is PROCESSOR time in Lua,
-- and a defer loop spends nearly all of its wall time yielding -- so os.clock()
-- crawled, the glyph held one frame for seconds at a stretch, and the spinner
-- read as frozen: exactly the "nothing is happening" it exists to deny. Same
-- reason V5.now() exists for the probe debounce (see it below); this call site
-- was simply never moved over. 8 frames/sec = two rotations a second.
local function _spinner_glyph()
  local frames = { '|', '/', '-', '\\' }
  local t = (reaper.time_precise and reaper.time_precise()) or os.clock()
  return frames[math.floor(t * 8) % #frames + 1]
end

local function _grey_hint(ctx, text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
  reaper.ImGui_TextWrapped(ctx, text)
  reaper.ImGui_PopStyleColor(ctx)
end

-- ─── v0.13 form kit ─────────────────────────────────────────────────────────
-- The drawing primitives the whole panel is built from. Explanatory prose
-- moves into (?) tooltips so a form reads as a form; _grey_hint stays for the
-- things that must be seen without hovering (errors, blocking warnings).
--
-- V5 fields, not locals: the main chunk is AT Lua's 200-local limit.
-- ---------------------------------------------------------------------------

-- ── The palette (v0.22) ────────────────────────────────────────────────────
-- Every colour the panel draws, named once. Before this the same graphite and
-- the same amber were retyped as raw 0xRRGGBBAA at ~190 call sites, so
-- "make the warnings less shouty" meant finding sixteen literals and hoping.
-- Roles, not hues: rename the value here and the whole panel follows.
-- ImGui packs these as 0xRRGGBBAA — the last byte is ALPHA, not blue.
V5.COL = {
  -- Ground. bg is the window, panel the children, sunken the input boxes.
  bg          = 0x16181BFF,
  panel       = 0x1A1D21FF,
  sunken      = 0x101214FF,
  sunken_hi   = 0x161B20FF,
  sunken_act  = 0x1B2127FF,
  title_act   = 0x14171AFF,
  line        = 0x282C31FF,   -- borders, separators, strong table rules
  line_soft   = 0x202429FF,   -- light table rules
  plot        = 0x2E5877FF,

  -- Neutral buttons and the rail/collapsing-header rows.
  btn         = 0x22262BFF,
  btn_hi      = 0x2A2F35FF,
  btn_act     = 0x32383FFF,
  hdr         = 0x22262BFF,
  hdr_hi      = 0x2A3038FF,
  hdr_act     = 0x333B44FF,

  -- Text, brightest to faintest. hint is the (?) glyph specifically: it has
  -- to recede further than ordinary secondary text or every row grows a dot.
  bright      = 0xFFFFFFFF,
  text        = 0xC8CDD3FF,
  text2       = 0x99A3B0FF,
  dim         = 0x8899AAFF,
  dimmer      = 0x66707EFF,
  off         = 0x5A616AFF,   -- ImGui TextDisabled
  faint       = 0x5F6873FF,   -- a step not reached yet, a file gone missing
  hint        = 0x667788FF,

  -- Meaning. warn is the chip/border amber, warn_text the sentence-in-the-
  -- flow orange — deliberately different, so a warning you must read does not
  -- look like a badge you may ignore.
  ok          = 0x55DD77FF,
  done        = 0x55DD55FF,   -- a stage that finished, in a list of stages
  step_ok     = 0x7FD3A0FF,   -- a completed step in the numbered strips
  warn        = 0xFFCC55FF,
  warn_text   = 0xFFAA55FF,
  err         = 0xFF5555FF,
  info        = 0x55AAFFFF,

  -- Selection blue: the on-state of a segmented row, the active rail item.
  accent      = 0x3A5A8CFF,
  accent_hi   = 0x4A6A9CFF,
  accent_act  = 0x2A4A7CFF,
  -- Same blue at 55% for text selection inside a field, where an opaque
  -- highlight would swallow the characters it is supposed to be marking.
  sel_bg      = 0x3A5A8C8C,

  -- v0.23 state chips in the run list. A tinted ground behind a word that is a
  -- STATE, not a button — the text roles above supply the foreground, so a
  -- chip is always one of these grounds under one of those colours.
  chip_ok     = 0x173021FF,
  chip_warn   = 0x3A2E12FF,
  chip_info   = 0x1C2733FF,
  chip_off    = 0x22262BFF,

  -- Off-state of a segmented row. Distinct from btn: a segmented row's unlit
  -- segments must read as "not chosen", not as "ordinary button".
  seg         = 0x2A2F38FF,
  seg_hi      = 0x3A4048FF,
  seg_act     = 0x22262CFF,

  -- The one green Run/Go button. Nothing else in the panel is this saturated.
  go          = 0x2A9945FF,
  go_hi       = 0x44CC55FF,
  go_act      = 0x119911FF,

  -- Blue action button: starts a SMALL job (preview a voice, change a track's
  -- voice). Deliberately not green — green is reserved for the run that costs
  -- credits, and two greens would make them look equally consequential.
  job         = 0x2A6699FF,
  job_hi      = 0x4488CCFF,
  job_act     = 0x114477FF,
}

-- One corner radius for the whole panel (v0.22). Was 3, hard-coded on three
-- style vars and absent from the rest; 4 at the panel's 14 px face is the
-- shell's own softness without looking like a toy.
V5.ROUND = 4

V5.LABEL_W = 84           -- label column width, px (Indic labels are wide)

-- v0.16: the standard field FILLS its row instead of being 260 px wide in a
-- 760 px window, which left ~380 px of every row empty while long paths and
-- model ids scrolled inside the box. Negative = "fill, minus this much", and
-- the reserve is what a trailing SmallButton ("Clear", "Browse…") plus its (?)
-- hint need — nearly every field in the settings panes has one.
V5.FIELD_W = -132

-- ImGui_SetTooltip does not wrap, so wrap by hand at ~62 columns.
function V5.wrap(text, cols)
  cols = cols or 62
  local out, line = {}, ""
  for word in tostring(text or ""):gmatch("%S+") do
    if line == "" then
      line = word
    elseif #line + #word + 1 <= cols then
      line = line .. " " .. word
    else
      out[#out + 1] = line
      line = word
    end
  end
  if line ~= "" then out[#out + 1] = line end
  return table.concat(out, "\n")
end

-- A dim (?) after the previous control, explaining it on hover. This replaces
-- the bulk of the old _grey_hint calls — errors and blocking warnings stay
-- inline, because a warning you have to hover to find is not a warning.
function V5.hint(ctx, text)
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.hint)
  reaper.ImGui_Text(ctx, '(?)')
  reaper.ImGui_PopStyleColor(ctx)
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(text))
  end
end

-- ── v0.22 measured label column ─────────────────────────────────────────────
-- The column used to be a flat 84 px, which was fine only as long as no label
-- was wider than 84 px in ImGui's 13 px built-in face. With a real UI face
-- (V5.ui_font) every label grew, and "Google TTS key" now overruns the column
-- and collides with its own field.
--
-- So a form GROUP measures its widest label while drawing and uses that width
-- on the NEXT frame — the same previous-frame trick as V5.measured/V5.mh,
-- for the same reason: a hand-counted pixel budget goes wrong the moment the
-- font, the language or the label text changes, and a width is stable frame to
-- frame so the measured value is right from the second frame onward.
--
-- Why not one BeginTable per pane, which would size the column with no lag:
-- these panes are not uniform stacks of rows. Section headings, warning
-- paragraphs and buttons sit BETWEEN the rows, and a 2-column table would
-- either have to span them explicitly or be broken into one table per run of
-- rows — at which point each run sizes its column independently and the rows
-- stop lining up, which is the very thing the column exists to do. The review
-- and plan screens, which ARE real grids, do use BeginTable.
--
-- V5 fields, not locals: the main chunk is AT Lua's 200-local limit.
V5.lw = {}          -- key -> label-column width measured last frame

-- Never let a freak measurement (or a very long label) push the fields off the
-- right edge — past this the label wraps into its own row's business instead.
V5.LABEL_W_MAX = 240

function V5.form_begin(ctx, key)
  V5.form_key  = key
  V5.form_seen = 0
  V5.form_w    = math.max(V5.LABEL_W,
                          math.min(V5.LABEL_W_MAX, V5.lw[key] or 0))
end

function V5.form_end(ctx)
  if V5.form_key then V5.lw[V5.form_key] = V5.form_seen or 0 end
  V5.form_key, V5.form_seen, V5.form_w = nil, nil, nil
  V5.row_x = nil
end

-- Label in the current form group's column. Everything after it on the row
-- starts at the same x, which is what makes a stack of rows read as a form
-- instead of as ImGui's default ragged right-hand labels. Outside a group it
-- behaves exactly as it always did, at the flat V5.LABEL_W.
function V5.label(ctx, text)
  reaper.ImGui_Text(ctx, text)

  -- v0.26: measured through V5.text_w, which NEVER answers 0 — it falls back
  -- to a per-character estimate when ReaImGui has not rasterized the glyphs
  -- yet. That guarantee matters more here than anywhere else in the panel:
  -- this is the number that decides whether the field lands beside the label
  -- or on top of it. The old code took CalcTextSize's 0 as "no information"
  -- and left the column at its 84 px floor, which is the safe direction only
  -- for labels NARROWER than the floor. 'Google TTS key' is 96 px and
  -- 'Vertex service account JSON' is 188, and both were overprinted by their
  -- own input box on every frame the atlas had not caught up — which for a
  -- pane you have just opened is every frame you look at.
  -- 8 px per character rather than 7: over-estimating widens the column, and
  -- too wide never hides anything.
  local want = V5.text_w(ctx, text, 8) + 12   -- 12 px of air after the label
  if V5.form_key and want > (V5.form_seen or 0) then V5.form_seen = want end

  -- The group's column, but NEVER narrower than this label. ImGui's absolute
  -- SameLine sets the cursor to the offset whether that is ahead of what was
  -- just drawn or behind it, so a column one frame stale — or one bad
  -- measurement short — would place the control inside the label's own text.
  -- Pushing one row's control right is a ragged form; drawing it over the
  -- label is an unreadable one.
  --
  -- V5.cell_x is the left edge of the grid cell this row is in (v0.23) and nil
  -- everywhere else. V5.row_x is where the control actually starts, which is
  -- what V5.cell_field measures its width from — the column width is no longer
  -- enough to know that.
  local col = math.max(V5.form_w or V5.LABEL_W, want)
  V5.row_x = (V5.cell_x or 0) + col
  reaper.ImGui_SameLine(ctx, V5.row_x)
end

-- Clamp an explicit control width to the room actually left on this row, and
-- leave *keep* px after it for whatever follows (a (?) hint needs about 30).
-- A positive width passed by a caller was chosen for a comfortable window; at
-- 280 px it is simply wider than the row, and ImGui does not clamp it.
-- Negative widths already mean "fill minus n" and are left alone.
V5.HINT_W = 30
function V5.fit_w(ctx, width, keep)
  if type(width) ~= 'number' or width <= 0 then return width end
  local room = V5.room(ctx)
  if type(room) ~= 'number' or room <= 0 then return width end
  return math.max(40, math.min(width, room - (keep or V5.HINT_W)))
end

-- V5.label plus a width for the next input. The widget itself is given a
-- '##id' label so ImGui does not draw a second one to its right.
-- 260 is passed explicitly by a dozen call sites and always MEANT "the standard
-- field", so it maps to the standard width rather than being edited out of each
-- one. Any other number is a deliberate exception (a short combo on a shared
-- row) and is left alone.
function V5.field(ctx, label, width)
  V5.label(ctx, label)
  if width == nil or width == 260 then width = V5.FIELD_W end
  reaper.ImGui_SetNextItemWidth(ctx, V5.fit_w(ctx, width))
end

-- ── v0.17 secret fields ─────────────────────────────────────────────────────
-- A key row is wider than a normal one: eye + Clear + (?) all sit after it.
V5.FIELD_W_KEY = -168

-- The eye. Drawn rather than typed: the built-in ImGui font has no eye glyph
-- (and an emoji would land as a hollow box on the machines that matter), so
-- this is two arcs, an iris, and — when the key is masked — a slash through
-- it. Returns true on click. Falls back to a labelled SmallButton on ReaImGui
-- builds without the draw-list calls.
function V5.eye_button(ctx, id, shown)
  local dl = reaper.ImGui_GetWindowDrawList and reaper.ImGui_GetWindowDrawList(ctx)
  local bez = reaper.ImGui_DrawList_AddBezierQuadratic
  local ln  = reaper.ImGui_DrawList_AddLine
  local cir = reaper.ImGui_DrawList_AddCircleFilled
  if not (dl and bez and ln and cir and reaper.ImGui_InvisibleButton
          and reaper.ImGui_GetCursorScreenPos) then
    local hit = reaper.ImGui_SmallButton(ctx,
      (shown and 'Hide##eye' or 'Show##eye') .. id)
    if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
      reaper.ImGui_SetTooltip(ctx, V5.wrap(
        shown and 'Hide this key again.' or 'Show this key in plain text.'))
    end
    return hit
  end

  local w, h = 24, 18
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local hit  = reaper.ImGui_InvisibleButton(ctx, '##eye' .. id, w, h)
  local hot  = reaper.ImGui_IsItemHovered(ctx)
  if hot and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(
      shown and 'Hide this key again.' or 'Show this key in plain text.'))
  end

  local col = hot and 0xE2E8EFFF or (shown and 0xB9C4D0FF or 0x7E8996FF)
  local cx, cy = x + w * 0.5, y + h * 0.5
  local x0, x1 = cx - 7.5, cx + 7.5
  -- Upper and lower lid: one quadratic each, control point pushed out to the
  -- lens height. 12 segments is smooth at this size and costs nothing.
  bez(dl, x0, cy, cx, cy - 6.5, x1, cy, col, 1.3, 12)
  bez(dl, x0, cy, cx, cy + 6.5, x1, cy, col, 1.3, 12)
  cir(dl, cx, cy, 2.5, col, 12)
  if not shown then
    -- Masked: the same eye, struck through. The slash is what carries the
    -- state at a glance — an eye alone reads as "there is an eye here".
    ln(dl, cx - 8, cy + 6, cx + 8, cy - 6, col, 1.3)
  end
  return hit
end

-- ── v0.24 browse button ─────────────────────────────────────────────────────
-- The folder. Drawn rather than typed, for the same reason as the eye above:
-- the built-in ImGui font has no folder glyph and an emoji would land as a
-- hollow box on exactly the machines this is installed on. A real ImGui_Button
-- sits underneath, so the frame, hover, active and rounding are the panel's own
-- and only the glyph is by hand — 'File…' spelled out was the widest thing on
-- the Source row and said less than the icon does.
-- Returns true on click. Falls back to the labelled button on ReaImGui builds
-- without the draw-list calls.
V5.BROWSE_W = 28

function V5.browse_button(ctx, id, tip)
  local dl = reaper.ImGui_GetWindowDrawList and reaper.ImGui_GetWindowDrawList(ctx)
  local ln = reaper.ImGui_DrawList_AddLine
  local function tipped(hit)
    if tip and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
      reaper.ImGui_SetTooltip(ctx, V5.wrap(tip))
    end
    return hit
  end
  if not (dl and ln and reaper.ImGui_GetCursorScreenPos) then
    return tipped(reaper.ImGui_Button(ctx, 'File…##browse' .. id))
  end

  local h = reaper.ImGui_GetFrameHeight and reaper.ImGui_GetFrameHeight(ctx) or 22
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  -- '##browse' .. id, not 'browse##' .. id: ImGui hashes ONLY what follows
  -- '##', and a bare id would collide with the input this button sits beside.
  local hit = tipped(reaper.ImGui_Button(ctx, '##browse' .. id, V5.BROWSE_W, h))
  local hot = reaper.ImGui_IsItemHovered(ctx)

  -- Half-pixel centres: a 1 px line on a whole coordinate straddles two pixels
  -- and comes out grey and two wide (same reason as the caption glyphs).
  local col = hot and 0xE2E8EFFF or 0xB9C4D0FF
  local cx  = math.floor(x + V5.BROWSE_W * 0.5) + 0.5
  local cy  = math.floor(y + h * 0.5) + 0.5
  local t   = 1.0
  local x0, x1 = cx - 6, cx + 6
  local y0, y1 = cy - 3, cy + 4                -- body, tab rides above y0
  ln(dl, x0,     y0 - 3, x0 + 4, y0 - 3, col, t)   -- tab: top
  ln(dl, x0 + 4, y0 - 3, x0 + 5, y0,     col, t)   --      shoulder into the body
  ln(dl, x0 + 5, y0,     x1,     y0,     col, t)   -- body: top
  ln(dl, x1,     y0,     x1,     y1,     col, t)   --       right
  ln(dl, x1,     y1,     x0,     y1,     col, t)   --       bottom
  ln(dl, x0,     y1,     x0,     y0 - 3, col, t)   --       left, up to the tab
  return hit
end

-- One secret input: label, masked box, eye, Clear, (?) — everywhere a key or
-- token is entered, so the four of them can never drift apart again.
--   id     unique input id (also the reveal key)
--   cred   V5.cred_cleared key, so clearing propagates to the config writer
--   probe  Connections provider to validate after an edit (nil = no probe)
-- Returns the (possibly new) value and whether this frame changed it.
function V5.key_field(ctx, label, id, value, cred, tip, probe)
  value = value or ''
  V5.field(ctx, label, V5.FIELD_W_KEY)
  local flags = V5.key_shown[id] and 0
                or (reaper.ImGui_InputTextFlags_Password
                    and reaper.ImGui_InputTextFlags_Password() or 0)
  local rv, txt = reaper.ImGui_InputText(ctx, '##' .. id, value, flags)
  local changed = false
  if rv and txt ~= value then value, changed = txt, true end

  reaper.ImGui_SameLine(ctx, 0, 4)
  if V5.eye_button(ctx, id, V5.key_shown[id]) then
    V5.key_shown[id] = (not V5.key_shown[id]) or nil
  end
  reaper.ImGui_SameLine(ctx, 0, 4)
  -- 'clr' prefix, not 'Clear##' .. id: ImGui hashes ONLY what follows '##', so
  -- 'Clear##oaikey' and the input's own '##oaikey' would be the SAME widget id
  -- — two controls sharing one id fight over focus and activation state.
  if reaper.ImGui_SmallButton(ctx, 'Clear##clr' .. id) then
    if value ~= '' then changed = true end
    value = ''
    if cred then V5.cred_cleared[cred] = true end
  end
  if tip then V5.hint(ctx, tip) end

  -- Paste-to-validate. The debounce lives in V5.conn_touch, so holding a key
  -- down in the box does not fire one request per keystroke.
  if changed and probe then V5.conn_touch(probe, value) end
  return value, changed
end

-- Model dropdown. Every model id used to be typed by hand, which meant
-- remembering exact strings like "gemini-3-flash-preview" — one typo and the
-- run died at the first LLM call. The list is what the current provider can
-- actually serve (V5.models_for); the last entry drops back to a text box,
-- because a gateway can serve an id no built-in list will ever have. An id
-- already saved but absent from the list is kept at the top of it, so opening
-- Settings never silently changes a setting.
--   id          full ImGui label — '##foo', or 'Label##foo' to show a label
--   blank_label makes "" selectable (the per-stage "same as Model" rows)
V5.MODEL_CUSTOM = 'Custom — type an id…'
V5.model_typing = {}    -- id -> true while that row is a text box

function V5.model_picker(ctx, id, current, provider, blank_label, width)
  current = current or ''
  -- Same 260 → standard-width mapping as V5.field (negative widths fill, so
  -- the "width - 46" reserve below still means "leave 46 px for the button").
  if width == nil or width == 260 then width = V5.FIELD_W end

  if V5.model_typing[id] then
    reaper.ImGui_SetNextItemWidth(ctx, width - 46)
    local rv, typed = reaper.ImGui_InputText(ctx, id, current)
    if rv then current = typed end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, 'list##back' .. id) then
      V5.model_typing[id] = nil
    end
    return current
  end

  -- Empty needs a visible entry of its own, or the combo would show the first
  -- model in the list as if it were the setting.
  local empty_label = blank_label or (current == '' and '(not set)' or nil)
  local items, known = {}, false
  if empty_label then items[#items + 1] = empty_label end
  for _, m in ipairs(V5.models_for(provider)) do
    items[#items + 1] = m
    if m == current then known = true end
  end
  if current ~= '' and not known then
    table.insert(items, empty_label and 2 or 1, current)
  end
  items[#items + 1] = V5.MODEL_CUSTOM

  reaper.ImGui_SetNextItemWidth(ctx, width)
  local changed, picked = _ui_combo(ctx, id,
    current == '' and empty_label or current, items)
  if not changed then return current end
  if picked == V5.MODEL_CUSTOM then
    V5.model_typing[id] = true
    return current
  end
  if empty_label and picked == empty_label then return '' end
  return picked
end

-- The reveal toggles write immediately (they are one-click state, and losing
-- them on a crash would be silently annoying).
function V5.save_adv() save_settings() end

-- One-line reveal for the fields most people never touch. Returns true when
-- the group is open; the state persists (see save_settings).
function V5.advanced(ctx, key, label)
  local open = V5.adv[key] and true or false
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
  if reaper.ImGui_SmallButton(ctx,
      (open and '▾  ' or '▸  ') .. (label or 'Show advanced')
      .. '##adv' .. key) then
    open = not open
    V5.adv[key] = open or nil
    V5.save_adv()
  end
  reaper.ImGui_PopStyleColor(ctx)
  return open
end

-- Segmented button row: the flat replacement for "one tab per mode" and for
-- checkboxes whose two states both need a name. *opts* is
-- { {value, label, tooltip}, … }; returns the (possibly new) value.
function V5.segmented(ctx, key, cur, opts)
  local new = cur
  -- v0.26: wraps. Two segments labelled 'Translate with AI' and 'I have a
  -- script' need 250 px, and the Dub screen's form is 303 px wide at a window
  -- of 560 — minus the label column, the row did not fit and the second
  -- segment was cut in half.
  V5.wrap_begin(ctx, 4)
  for i, o in ipairs(opts) do
    -- Each segment is sized EXPLICITLY, for two reasons. A pending
    -- SetNextItemWidth belongs to the next widget, so a stacked field's
    -- "fill the cell" width was being eaten by the FIRST segment — which then
    -- filled the cell on its own and pushed the second one clean out of it.
    -- And an explicit width is the same number the wrap budgeted with, so the
    -- row breaks exactly where it said it would.
    local sw = V5.btn_w(ctx, o[2])
    V5.wrap_next(ctx, sw)
    local on = (o[1] == cur)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
                               on and V5.COL.accent or V5.COL.seg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),
                               on and V5.COL.accent_hi or V5.COL.seg_hi)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),
                               on and V5.COL.accent_act or V5.COL.seg_act)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                               on and V5.COL.bright or V5.COL.text2)
    if reaper.ImGui_Button(ctx, o[2] .. '##seg' .. key .. i, sw, 0) then
      new = o[1]
    end
    reaper.ImGui_PopStyleColor(ctx, 4)
    if o[3] and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
      reaper.ImGui_SetTooltip(ctx, V5.wrap(o[3]))
    end
  end
  V5.wrap_end()
  return new
end

-- Same { {value, label, tooltip}, … } opts as V5.segmented, drawn as one combo
-- instead of a button per value. Use it where the choices are settings you set
-- once — a row of buttons advertises "flip me while you work", which is the
-- wrong invitation for anything under Advanced — and where a fourth value would
-- otherwise push the row wider than the pane.
-- Each row keeps its own tooltip while the list is open; BeginCombo is what
-- makes that possible, so builds without it fall back to the flat ImGui_Combo
-- (choices still selectable, per-row tooltips lost).
function V5.dropdown(ctx, key, cur, opts, width)
  local new, cur_label = cur, cur
  for _, o in ipairs(opts) do if o[1] == cur then cur_label = o[2] end end
  reaper.ImGui_SetNextItemWidth(ctx, V5.fit_w(ctx, width or V5.FIELD_W))

  if not (reaper.ImGui_BeginCombo and reaper.ImGui_Selectable) then
    local labels = {}
    for i, o in ipairs(opts) do labels[i] = o[2] end
    local changed, picked = _ui_combo(ctx, '##dd' .. key, cur_label, labels)
    if changed then
      for _, o in ipairs(opts) do if o[2] == picked then new = o[1] end end
    end
    return new
  end

  if reaper.ImGui_BeginCombo(ctx, '##dd' .. key, cur_label) then
    for i, o in ipairs(opts) do
      local on = (o[1] == cur)
      -- '##dd<key><i>' keeps the ids unique when two options ever share a
      -- label; the visible text is only what precedes the ##.
      if reaper.ImGui_Selectable(ctx, o[2] .. '##dd' .. key .. i, on) then
        new = o[1]
      end
      if o[3] and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
        reaper.ImGui_SetTooltip(ctx, V5.wrap(o[3]))
      end
      if on and reaper.ImGui_SetItemDefaultFocus then
        reaper.ImGui_SetItemDefaultFocus(ctx)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  return new
end

-- ── Pinned chrome / one scroll region (v0.15) ───────────────────────────────
-- The window used to be one long stream: header, tab bar, fields, run button
-- and status bar all in the same flow, so the moment the content grew past the
-- window the TAB BAR and the RUN BUTTON scrolled away with it. Now every tab
-- body is a fixed-height child. The window's own content can then never exceed
-- its height, so the outer scrollbar never appears — the child scrolls
-- instead, and only when something inside it is expanded.
-- How tall a pinned block turned out to be, keyed by name, MEASURED on the
-- previous frame rather than guessed. Hand-counted pixel budgets go wrong the
-- moment a style var, a font or a wrapped line changes — and going wrong here
-- means the body reserves too little and the outer scrollbar comes back, which
-- is the whole bug. A block's height is stable frame to frame, so the measured
-- value is right from the second frame and stays right.
V5.mh = {}

function V5.y(ctx)
  return reaper.ImGui_GetCursorPosY and reaper.ImGui_GetCursorPosY(ctx) or nil
end

-- Record the height of the block that started at *y0* (from V5.y before it).
-- Includes the block's own item spacing, which is what has to be reserved.
function V5.measured(ctx, key, y0)
  local y1 = V5.y(ctx)
  if y0 and y1 and y1 > y0 then V5.mh[key] = y1 - y0 end
end

function V5.mh_get(key, fallback) return V5.mh[key] or fallback end

-- The same, for sizing a CHILD from content measured INSIDE one: a child's
-- height has to cover its own WindowPadding as well, which V5.measured (an
-- inside-the-child cursor delta) does not see. Without this the child is 16 px
-- short of its content every frame and clips the last line of it.
V5.CHILD_PAD = 16
function V5.mh_child(key, fallback)
  return (V5.mh[key] or fallback) + V5.CHILD_PAD
end

-- Open the scrolling body of a tab. *footer_h* is the height of whatever that
-- tab pins under the body (0 for tabs with no footer).
-- *noscroll* (v0.23) is the caller promising that everything it draws is
-- sized to fit — because one thing inside it (a text area) takes the height
-- that is left over and owns the only scrollbar on the screen. Opt-in, not
-- the default: the Tools tab draws straight into this child and genuinely
-- needs it to scroll.
function V5.begin_body(ctx, footer_h, noscroll)
  return reaper.ImGui_BeginChild(ctx, '##tabbody', -1,
    -math.max(0, footer_h or 0),
    0, noscroll and V5.noscroll_flags() or 0)
end

-- One dim line of "what this tab does", drawn at the top of a body. Replaces
-- the 22px hero titles: the tab already names the screen, so a second title
-- was pushing the first real control below the fold.
function V5.steps(ctx, text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
  -- Wrapped: 'Paste text → speak it → it lands on a track' is 46 characters,
  -- and a plain Text ran off the edge of any tab under ~420 px.
  reaper.ImGui_TextWrapped(ctx, text)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)
end

-- ── v0.23 two-up form grid ──────────────────────────────────────────────────
-- A form row is one label column plus one control, and at 900 px that leaves
-- roughly half the row empty — which is fine for a path but wasteful for a
-- 170 px combo, and it is vertical space the script box needs. A grid pairs
-- the short controls two to a row.
--
-- It is a thin wrapper over the existing label column, not a replacement:
-- V5.form_begin still measures the widest label, V5.label still aligns to it,
-- and V5.cell only moves the row's origin. Widths inside a cell must be
-- POSITIVE — ImGui's "-n = fill minus n" fills to the WINDOW edge, which in
-- the left-hand cell would run straight through the right-hand one.
V5.CELL_GAP = 20
V5.CELL_MIN = 300    -- below this per column, pairing clips; use one column

function V5.grid_begin(ctx, key, cols)
  V5.form_begin(ctx, key)
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  if type(avail) ~= "number" or avail < 80 then avail = 560 end
  cols = math.max(1, cols or 2)
  -- Narrow window: one column. Two half-width cells that clip their own
  -- buttons are worse than the stack this replaced.
  -- v0.26: and one column too when the MEASURED label column would leave less
  -- than a usable field inside each cell. The old test looked only at the
  -- window, so a pane whose labels had grown (a real UI face, or a translated
  -- label) still paired up and then had nowhere to put the control.
  while cols > 1 do
    local cw = math.floor((avail - V5.CELL_GAP * (cols - 1)) / cols)
    if avail >= V5.CELL_MIN * cols
       and cw - (V5.form_w or V5.LABEL_W) >= 120 then break end
    cols = cols - 1
  end
  V5.grid_n  = cols
  -- minus 2: the last cell's right edge would otherwise land exactly on the
  -- content edge, and a trailing button's border sat one pixel past it.
  V5.grid_w  = math.floor((avail - 2 - V5.CELL_GAP * (cols - 1)) / cols)
  V5.grid_x0 = reaper.ImGui_GetCursorPosX(ctx) or 0
  V5.grid_i  = 0
  V5.grid_y  = V5.y(ctx) or 0
  V5.grid_bot = V5.grid_y
end

-- Open the next cell, wrapping to a new row after the last column. Returns the
-- cell's full width.
--
-- v0.26: the cursor is SET to (cell_x, row_top) rather than walked back with
-- SameLine. SameLine returns to the last ITEM's line, which is the same thing
-- as the row's top only while every cell is exactly one line tall — and cells
-- stopped being one line tall the moment segmented rows learned to wrap. The
-- second cell was then drawn on the second line of the first one, which is how
-- 'Review' ended up printed across the 'I have a script' button.
--
-- V5.grid_bot is how far down the tallest cell of the current row reached, so
-- the next row — and V5.grid_end — start below all of them.
function V5.cell(ctx)
  local n   = V5.grid_n or 1
  local col = (V5.grid_i or 0) % n
  local y   = V5.y(ctx) or 0
  if y > (V5.grid_bot or 0) then V5.grid_bot = y end
  if col == 0 then V5.grid_y = V5.grid_bot or y end
  V5.cell_x = (V5.grid_x0 or 0) + col * ((V5.grid_w or 0) + V5.CELL_GAP)
  if reaper.ImGui_SetCursorPos then
    reaper.ImGui_SetCursorPos(ctx, V5.cell_x, V5.grid_y or y)
  elseif col > 0 then
    reaper.ImGui_SameLine(ctx, V5.cell_x)
  end
  V5.grid_i = (V5.grid_i or 0) + 1
  return V5.grid_w or 0
end

-- V5.field for a cell: the label, then a width that stops at the cell's right
-- edge. *reserve* is what a trailing button on the same row needs.
function V5.cell_field(ctx, label, reserve)
  V5.label(ctx, label)
  -- Measured from where the label actually LEFT the cursor (V5.row_x), not
  -- from the column width. A label wider than the column moves its control
  -- right, and a width computed from the column would then reach past the
  -- cell's right edge, across the 20 px gap, and into the next cell's label.
  local cell_l = V5.cell_x or 0
  local cell_r = cell_l + (V5.grid_w or 260)
  local at     = V5.row_x or (cell_l + (V5.form_w or V5.LABEL_W))
  local w      = cell_r - at - (reserve or 0)
  -- Below the floor the reserve goes first: a trailing button that has to sit
  -- half a pixel closer is better than a box drawn through the next column.
  -- V5.grid_begin drops to one column before it can get this far, so this is
  -- the backstop, not the plan.
  reaper.ImGui_SetNextItemWidth(ctx, math.max(40, math.min(w, cell_r - at)))
  return w
end

function V5.grid_end(ctx)
  -- Leave the cursor below the TALLEST cell of the last row, or whatever is
  -- drawn next starts inside it.
  local y   = V5.y(ctx) or 0
  local bot = math.max(V5.grid_bot or 0, y)
  if reaper.ImGui_SetCursorPosY and bot > y then
    reaper.ImGui_SetCursorPosY(ctx, bot)
  end
  V5.cell_x, V5.grid_w, V5.grid_x0 = nil, nil, nil
  V5.grid_i, V5.grid_n = nil, nil
  V5.grid_y, V5.grid_bot = nil, nil
  V5.form_end(ctx)               -- also clears V5.row_x
end

-- ── v0.27 stacked fields ────────────────────────────────────────────────────
-- The label sits ABOVE its control instead of beside it. Two reasons, in this
-- order: a label and its control cannot collide when they are not on the same
-- row at all — which retires the entire class of defect the measured label
-- column existed to manage — and a Devanagari or Bengali label takes the width
-- it needs without taking it out of the field. The column it replaces was
-- costing every row between 84 and 240 px of its width to say something the
-- reader has already read.
--
-- V5.fgrid pairs the short ones into as many columns as the width holds, so
-- stacking does not simply trade horizontal waste for vertical.
V5.FGRID_MIN = 190       -- below this per column, use one column
V5.FGRID_GAP = 16

function V5.fgrid_begin(ctx, key, want)
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  if type(avail) ~= 'number' or avail < 80 then avail = 560 end
  local cols = math.max(1, want or 2)
  while cols > 1 and avail < V5.FGRID_MIN * cols do cols = cols - 1 end
  local y = V5.y(ctx) or 0
  V5.fg = { key = key, n = cols, i = 0, y = y, bot = y,
            w  = math.floor((avail - 2 - V5.FGRID_GAP * (cols - 1)) / cols),
            x0 = reaper.ImGui_GetCursorPosX(ctx) or 0 }
  V5.fg.x = V5.fg.x0
end

-- Open the next cell. Same discipline as V5.cell: the cursor is SET to the
-- cell's x and the ROW's top, never walked back with SameLine — a stacked
-- field is two lines tall by definition, so the last item's line is never the
-- row's top.
-- Put the cursor back on this cell's left edge. Any caller that starts a new
-- LINE inside a cell needs this: ImGui's next-line x is the window's margin.
function V5.fcell_x(ctx)
  if V5.fg and reaper.ImGui_SetCursorPosX then
    reaper.ImGui_SetCursorPosX(ctx, V5.fg.x or 0)
  end
end

function V5.fcell(ctx)
  local F = V5.fg
  if not F then return 260 end
  local col = F.i % F.n
  local y   = V5.y(ctx) or 0
  if y > F.bot then F.bot = y end
  if col == 0 then F.y = F.bot end
  F.x = F.x0 + col * (F.w + V5.FGRID_GAP)
  if reaper.ImGui_SetCursorPos then
    reaper.ImGui_SetCursorPos(ctx, F.x, F.y)
  end
  F.i = F.i + 1
  -- V5.room and V5.fit_w already stop at a grid cell; point them at this one.
  V5.cell_x, V5.grid_w = F.x, F.w
  return F.w
end

function V5.fgrid_end(ctx)
  local F = V5.fg
  if F then
    local y   = V5.y(ctx) or 0
    local bot = math.max(F.bot or 0, y)
    if reaper.ImGui_SetCursorPosY and bot > y then
      reaper.ImGui_SetCursorPosY(ctx, bot)
    end
  end
  V5.fg, V5.cell_x, V5.grid_w = nil, nil, nil
end

-- How wide the control under a stacked label may be. Inside a cell that is the
-- cell's own right edge — NOT ImGui's -1, which fills to the WINDOW and would
-- run the left-hand control straight through the right-hand one.
function V5.fld_w(ctx, reserve)
  local x = reaper.ImGui_GetCursorPosX and reaper.ImGui_GetCursorPosX(ctx) or 0
  local w
  if V5.fg then
    w = (V5.fg.x or 0) + (V5.fg.w or 260) - x
  else
    local a = reaper.ImGui_GetContentRegionAvail(ctx)
    w = (type(a) == 'number' and a > 0) and a or 260
  end
  return math.max(40, w - (reserve or 0))
end

-- The caption line of a stacked field: the label, its (?) if it has one, and an
-- optional right-aligned status on the same line (a character count, a credit
-- estimate). Leaves the next item sized to the cell, minus *reserve* for a
-- trailing button.
function V5.fld(ctx, label, tip, reserve, right)
  local x0   = reaper.ImGui_GetCursorPosX and reaper.ImGui_GetCursorPosX(ctx) or 0
  local room = V5.fld_w(ctx, 0)
  -- The caption is cut to its own cell. A label can be wider than the cell it
  -- captions — 'Vertex service account JSON' is 188 px and a two-up cell is 183
  -- at a 400 px pane — and a caption that overran would be drawn across the
  -- next column's. Stacking removed the collision between a label and its OWN
  -- control; this is the one that remains, and cutting is the answer because the
  -- full text is one hover away.
  local shown = V5.ellipsize(ctx, label, math.max(40, room - (tip and 34 or 4)))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.text2)
  reaper.ImGui_Text(ctx, shown)
  reaper.ImGui_PopStyleColor(ctx)
  if shown ~= label and reaper.ImGui_IsItemHovered(ctx)
     and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(label .. (tip and ('\n\n' .. tip) or '')))
  end
  if tip then V5.hint(ctx, tip) end
  if right and right ~= '' then
    -- Right-aligned against the CELL, and only ever moved further right — the
    -- same rule as everywhere else in the panel.
    -- Right-aligned on the caption's line, and drawn ONLY if it genuinely fits
    -- there. Squeezing it in beside a caption that already fills the cell is
    -- how a status ends up printed across the next column — and this is a
    -- status, not a control: the cost meter in the run column says the same
    -- thing, so dropping it at a narrow width costs the reader nothing.
    local rw   = V5.text_w(ctx, right, 8)
    local want = x0 + room - rw
    reaper.ImGui_SameLine(ctx)
    local at = reaper.ImGui_GetCursorPosX and reaper.ImGui_GetCursorPosX(ctx) or 0
    if want > at + 8 then
      reaper.ImGui_SameLine(ctx, want)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
      reaper.ImGui_Text(ctx, right)
      reaper.ImGui_PopStyleColor(ctx)
    else
      reaper.ImGui_NewLine(ctx)
    end
  end
  -- The caption's line ended, so ImGui has put the cursor at the WINDOW's left
  -- margin — which inside a grid cell is not this cell's left edge. Putting it
  -- back is the whole difference between a stacked field and a control drawn on
  -- top of the neighbouring column.
  if V5.fg and reaper.ImGui_SetCursorPosX then
    reaper.ImGui_SetCursorPosX(ctx, V5.fg.x or 0)
  end
  -- NOTE: this width belongs to the NEXT widget only. A caller that draws a row
  -- of several widgets (V5.segmented, a V5.chip toolbar) must size them itself —
  -- both of those do — or the first one silently takes the whole cell.
  reaper.ImGui_SetNextItemWidth(ctx, V5.fld_w(ctx, reserve))
end

-- ── The five steps, and where the run is in them ────────────────────────────
-- "Transcribe → Translate → TTS → Sync → Import" used to be a dim string that
-- said exactly the same thing whether the panel was idle, running, paused for
-- review or finished. It is the pipeline's real shape, and the engine already
-- reports where it is: every log line carries an [Sxx] tag, _ui_stage_tag
-- holds the last one and STAGE_INDEX orders them.
--
-- v0.25: this is the DATA half. What draws it is V5.run_plan, in the Dub
-- screen's run column, where each step also carries the value it will use.
--
-- .last is the engine stage a step ENDS on; a step is done once the live tag
-- is past it. Import has none — it happens in REAPER, after the engine exits.
V5.STEPS = {
  { label = 'Transcribe', last = 'S1b',
    tip = 'Speech-to-text on the English source, then regions and an SRT. ' ..
          'Runs even when you supply your own script — the sync stages need ' ..
          'its timings.' },
  { label = 'Translate',  last = 'S2c',
    tip = 'The LLM translation chain and a punctuation pass. Skipped ' ..
          'entirely when the Script control says you have one.' },
  { label = 'TTS',        last = 'S2d',
    tip = 'ElevenLabs speaks the script, one piece per matched section. ' ..
          'This is the step that spends credits.' },
  { label = 'Sync',       last = 'S3e',
    tip = 'Chunk boundaries, English-to-script mapping and spring ' ..
          'placement, then the synced audio is rendered.' },
  { label = 'Import',     last = nil,
    tip = 'The finished dub is placed on its own tracks in this project.' },
}

-- 'todo' | 'current' | 'done' | 'skip' | 'fail', one per step.
function V5.stepper_state()
  local st = {}
  for i = 1, #V5.STEPS do st[i] = 'todo' end
  -- A choice that removes a step should say so before the run, not silently.
  if SCRIPT_MODE == 'have' then st[2] = 'skip' end

  local ph = _ui_phase
  if ph == 'success' then
    for i = 1, 4 do if st[i] ~= 'skip' then st[i] = 'done' end end
    st[5] = 'current'                     -- the import is yours to press
  elseif ph == 'review' then
    st[1] = 'done'
    if st[2] ~= 'skip' then st[2] = 'current' end
  elseif ph == 'running' or ph == 'failure' or ph == 'plan' then
    local cur = _ui_stage_tag and STAGE_INDEX[_ui_stage_tag] or nil
    if cur then
      local marked = false
      for i = 1, #V5.STEPS do
        local ls = V5.STEPS[i].last
        local ln = ls and STAGE_INDEX[ls] or nil
        if not ln then break end
        if cur > ln then
          if st[i] ~= 'skip' then st[i] = 'done' end
        elseif not marked and st[i] ~= 'skip' then
          st[i] = 'current'
          marked = true
        end
      end
    end
    if ph == 'failure' then
      for i = 1, #st do if st[i] == 'current' then st[i] = 'fail' end end
    end
  end
  return st
end

-- v0.25: the horizontal five-node stepper is gone. It centred five labels on
-- V5.text_w, which is a GUESS whenever ImGui_CalcTextSize answers 0 for a glyph
-- the atlas has not rasterized yet — and before a run every node read 'todo',
-- so it was 42 px of decoration above a form you had not filled in. The run is
-- a vertical list in the Dub screen's own column now (V5.run_plan), where each
-- step carries the value it will actually use and nothing has to be centred.
-- V5.stepper_state stays: it is what tells that list which step is live.

-- Width of *text* in the current face, or an estimate when ReaImGui answers 0
-- for glyphs the atlas has not rasterized yet (which it does, and trusting it
-- would centre every label on the wrong pixel).
function V5.text_w(ctx, text, per_char)
  if reaper.ImGui_CalcTextSize then
    local ok, w = pcall(reaper.ImGui_CalcTextSize, ctx, text)
    if ok and type(w) == "number" and w > 0 then return w end
  end
  -- ImGui draws nothing from '##' on, so neither does the estimate. Counting
  -- the id suffix made every widget sized from a fallback measurement wider
  -- than it draws: 'Remove from list##hr1' is a third longer than its label.
  local vis = tostring(text or '')
  local cut = vis:find('##', 1, true)
  if cut then vis = vis:sub(1, cut - 1) end
  return #vis * (per_char or 7)
end

-- Section heading inside a settings pane or tab body.
function V5.heading(ctx, text, sub)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xEEEEEEFF)
  local pushed = _push_font(ctx, 17)
  reaper.ImGui_Text(ctx, text)
  if pushed then _pop_font(ctx) end
  reaper.ImGui_PopStyleColor(ctx)
  if sub then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
    -- Wrapped, not Text: these are sentences, and every one of them is wider
    -- than a pane dragged to 420 px. A plain Text just ran off the edge.
    reaper.ImGui_TextWrapped(ctx, sub)
    reaper.ImGui_PopStyleColor(ctx)
  end
  reaper.ImGui_Dummy(ctx, 0, 6)
end

-- Language display name → Unicode script, to pick an Indic-capable font.
local _LANG_TO_SCRIPT = {
  Hindi = "Devanagari", Nepali = "Devanagari", Marathi = "Devanagari",
  Bengali = "Bengali", Assamese = "Bengali",
  Tamil = "Tamil", Telugu = "Telugu", Kannada = "Kannada",
  Malayalam = "Malayalam", Gujarati = "Gujarati", Odia = "Oriya",
}

-- v0.4: one font PER SCRIPT, created+attached lazily and cached, so the
-- review editor renders correctly for whatever language is selected NOW
-- (the old code picked one font at startup and never followed the combo).
-- Note: Dear ImGui has no complex text shaping, so Indic conjuncts/matras
-- can still look re-ordered — that is cosmetic only. The review phase
-- offers Copy/Paste/Open-in-editor for a perfectly rendered view.
local _lang_fonts = {}             -- script name -> font, or false (none found)

-- macOS system fonts per script — the "<Script> Sangam MN" family ships
-- with macOS and covers every script this panel needs.
local _MAC_SCRIPT_FONTS = {
  Devanagari = { 'Devanagari Sangam MN.ttc', 'DevanagariMT.ttc',
                 'ITFDevanagari.ttc' },
  Bengali    = { 'Bangla Sangam MN.ttc', 'Bangla MN.ttc' },
  Tamil      = { 'Tamil Sangam MN.ttc', 'Tamil MN.ttc' },
  Telugu     = { 'Telugu Sangam MN.ttc', 'Telugu MN.ttc' },
  Kannada    = { 'Kannada Sangam MN.ttc', 'Kannada MN.ttc' },
  Malayalam  = { 'Malayalam Sangam MN.ttc', 'Malayalam MN.ttc' },
  Gujarati   = { 'Gujarati Sangam MN.ttc', 'GujaratiMT.ttc' },
  Oriya      = { 'Oriya Sangam MN.ttc', 'Oriya MN.ttc' },
}

local function _font_candidates(script)
  local paths = {}
  if _is_windows() then
    local local_fonts = (os.getenv("LOCALAPPDATA") or "")
                         :gsub("\\", "/") .. "/Microsoft/Windows/Fonts"
    -- User-installed Noto fonts first (best coverage), then Nirmala UI —
    -- ships with Windows 8.1+ and covers ALL 11 target languages' scripts.
    -- Noto comes under two names: the hinted "-Regular.ttf" build and the
    -- variable-font file that fonts.google.com serves by default — a
    -- per-user install ("Install for me") lands in LOCALAPPDATA, an
    -- all-users install in C:/Windows/Fonts. Probe every combination.
    -- segoeui.ttf is deliberately NOT a fallback: it has no Indic glyphs,
    -- so "loading" it only masked the failure while still drawing '?'.
    for _, dir in ipairs({ local_fonts, "C:/Windows/Fonts" }) do
      paths[#paths+1] = dir .. "/NotoSans" .. script .. "-Regular.ttf"
      paths[#paths+1] = dir .. "/NotoSans" .. script ..
                        "-VariableFont_wdth,wght.ttf"
      paths[#paths+1] = dir .. "/NotoSerif" .. script .. "-Regular.ttf"
      paths[#paths+1] = dir .. "/NotoSerif" .. script ..
                        "-VariableFont_wdth,wght.ttf"
    end
    paths[#paths+1] = "C:/Windows/Fonts/Nirmala.ttf"
    paths[#paths+1] = "C:/Windows/Fonts/NirmalaS.ttf"
    paths[#paths+1] = "C:/Windows/Fonts/NirmalaB.ttf"
    paths[#paths+1] = local_fonts .. "/Nirmala.ttf"
  else
    paths[#paths+1] = '/Library/Fonts/NotoSans' .. script .. '-Regular.ttf'
    paths[#paths+1] = '/Library/Fonts/NotoSerif' .. script .. '-Regular.ttf'
    for _, f in ipairs(_MAC_SCRIPT_FONTS[script] or {}) do
      paths[#paths+1] = '/System/Library/Fonts/Supplemental/' .. f
    end
    paths[#paths+1] = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf'
    paths[#paths+1] = '/Library/Fonts/Arial Unicode.ttf'
  end
  return paths
end

local function _create_script_font(ctx, script)
  if not (reaper.ImGui_CreateFontFromFile or reaper.ImGui_CreateFont) then
    return nil
  end
  for _, p in ipairs(_font_candidates(script)) do
    if file_exists(p) then
      -- ReaImGui 0.10 split the API: CreateFont(family, flags) matches an
      -- installed family name, while file loading moved to
      -- CreateFontFromFile(file, index, flags). Passing a .ttf path to the
      -- new CreateFont fails silently, so prefer the file variant when the
      -- installed ReaImGui provides it and keep the pre-0.10 call as the
      -- fallback for older installs.
      local ok, font
      if reaper.ImGui_CreateFontFromFile then
        ok, font = pcall(reaper.ImGui_CreateFontFromFile, p, 0, 0)
      else
        ok, font = pcall(reaper.ImGui_CreateFont, p, 16)
      end
      if ok and font then
        if pcall(reaper.ImGui_Attach, ctx, font) then
          return font
        end
      end
    end
  end
  return nil
end

-- ── v0.22 UI face ───────────────────────────────────────────────────────────
-- Dear ImGui's built-in face is Proggy: a 13 px bitmap font meant for debug
-- overlays. It is the single biggest reason an ImGui panel reads as a hacked-
-- together tool rather than an application, and replacing it is one call.
--
-- Latin only, deliberately. The Indic face is a SEPARATE handle that
-- _push_font puts on top around script text — ReaImGui exposes no way to merge
-- glyph ranges into one font, so the panel switches faces instead. Nothing
-- regresses when this fails: no font is pushed and ImGui's default is used,
-- exactly as before.
--
-- V5 fields, not locals: the main chunk is AT Lua's 200-local limit.
V5.UI_PX = 14   -- 13 is ImGui's own size; 15+ overflows the 84 px label column

function V5.ui_font_paths()
  local t = {}
  -- A face shipped beside the script wins, so an install can pin its look
  -- without depending on what the machine happens to have.
  t[#t+1] = SCRIPT_DIR .. SEP .. "fonts" .. SEP .. "Inter-Regular.ttf"
  if _is_windows() then
    -- Segoe UI is the Windows shell face — the one every other window on the
    -- screen is using. Selawik is its metric-compatible open twin, present on
    -- some stripped installs; Tahoma/Arial are the last resorts.
    t[#t+1] = "C:/Windows/Fonts/segoeui.ttf"
    t[#t+1] = "C:/Windows/Fonts/selawk.ttf"
    t[#t+1] = "C:/Windows/Fonts/tahoma.ttf"
    t[#t+1] = "C:/Windows/Fonts/arial.ttf"
  else
    -- SF is not loadable from disk as a plain file, so Helvetica (the .ttc
    -- REAPER itself falls back to) and then Arial.
    t[#t+1] = "/System/Library/Fonts/Helvetica.ttc"
    t[#t+1] = "/System/Library/Fonts/Supplemental/Arial.ttf"
    t[#t+1] = "/Library/Fonts/Arial.ttf"
  end
  return t
end

-- The Latin UI face, created and attached once. false = tried and failed, so
-- a missing font costs one probe per session rather than one per frame.
function V5.ui_font(ctx)
  if V5._uiface ~= nil then return V5._uiface or nil end
  V5._uiface = false
  if not (reaper.ImGui_CreateFontFromFile or reaper.ImGui_CreateFont) then
    return nil
  end
  -- Same 0.10 API split as _create_script_font: CreateFont() matches an
  -- INSTALLED FAMILY NAME there and takes flags where the old one took a
  -- size, so which call gets which argument follows CreateFontFromFile's
  -- presence, never a version string.
  local new10 = reaper.ImGui_CreateFontFromFile ~= nil
  local function try(maker, ...)
    local ok, font = pcall(maker, ...)
    if ok and font and pcall(reaper.ImGui_Attach, ctx, font) then
      V5._uiface = font
      return true
    end
    return false
  end
  -- 'sans-serif' is ReaImGui's generic family: it resolves to whatever the
  -- platform calls its UI face, which is exactly what is wanted and needs no
  -- path at all. Files are the fallback for builds that do not resolve it.
  if reaper.ImGui_CreateFont then
    if new10 then
      if try(reaper.ImGui_CreateFont, 'sans-serif', 0) then return V5._uiface end
    else
      if try(reaper.ImGui_CreateFont, 'sans-serif', V5.UI_PX) then return V5._uiface end
    end
  end
  for _, p in ipairs(V5.ui_font_paths()) do
    if file_exists(p) then
      if new10 then
        if try(reaper.ImGui_CreateFontFromFile, p, 0, 0) then return V5._uiface end
      else
        if try(reaper.ImGui_CreateFont, p, V5.UI_PX) then return V5._uiface end
      end
    end
  end
  return nil
end

-- Push the UI face for a whole window's content. Returns true when something
-- was pushed, and ONLY then may the caller pop — an unmatched pop corrupts
-- every later frame, which is why this is a boolean and not an assumption.
function V5.push_ui_font(ctx)
  local f = V5.ui_font(ctx)
  if not f then return false end
  if pcall(reaper.ImGui_PushFont, ctx, f, V5.UI_PX) then return true end
  if pcall(reaper.ImGui_PushFont, ctx, f) then return true end
  return false
end

function V5.pop_ui_font(ctx, pushed)
  if pushed then pcall(reaper.ImGui_PopFont, ctx) end
end

-- Point _ui_font at a font matching the CURRENT language's script. Called
-- once per frame; each script's font is created and attached only once.
local function _ensure_lang_font(ctx)
  local script = _LANG_TO_SCRIPT[LANGUAGE or ""] or "Devanagari"
  if _lang_fonts[script] == nil then
    _lang_fonts[script] = _create_script_font(ctx, script) or false
  end
  _ui_font = _lang_fonts[script] or nil
end

-- ReaImGui older than 0.9 rasterizes only a fixed Latin glyph range — an
-- Indic font may load fine and STILL draw every character as '?'. 0.9+
-- rasterizes glyphs on demand. Cached; used to explain '?' text honestly.
function V5.reaimgui_pre09()
  if V5.pre09 ~= nil then return V5.pre09 end
  V5.pre09 = false
  if reaper.ImGui_GetVersion then
    local ok, _, _, rv = pcall(reaper.ImGui_GetVersion)
    if ok and type(rv) == "string" then
      local maj, min = rv:match("^(%d+)%.(%d+)")
      if maj then
        V5.pre09 = (tonumber(maj) == 0 and tonumber(min) < 9)
      end
    end
  end
  return V5.pre09
end

-- Visible one-line explanation wherever script text is shown, instead of
-- the silent '?' rendering users hit on machines without a usable font
-- (or with a pre-0.9 ReaImGui). Reads _ui_font as set by _ensure_lang_font
-- for the CURRENT language this frame.
function V5.script_font_warning(ctx)
  local msg
  local script = _LANG_TO_SCRIPT[LANGUAGE or ""] or "Devanagari"
  if V5.reaimgui_pre09() then
    msg = "Your ReaImGui version is too old to draw " .. script ..
          " text — it shows every character as '?'. Update it via " ..
          "Extensions → ReaPack → Synchronize packages, then restart REAPER."
  elseif _ui_font == nil then
    msg = "No " .. script .. " font was found on this system — the text " ..
          "shows as '?'. Install \"Noto Sans " .. script ..
          "\" (free, fonts.google.com), then restart REAPER. " ..
          "The dubbing AUDIO is not affected."
  end
  if not msg then return end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn_text)
  reaper.ImGui_TextWrapped(ctx, msg)
  reaper.ImGui_PopStyleColor(ctx)
end

-- ---------------------------------------------------------------------------
-- Cancel — kill the worker PID published by run_dub.py
-- ---------------------------------------------------------------------------

-- True when the pid is alive AND still belongs to this pipeline (the worker
-- runs dub_engine.py, the launcher run_dub.py). Guards Cancel and the
-- pre-launch check against stale pid files and PID recycling — kill -9 on a
-- recycled pid/pgid would hit an unrelated process group.
local function pid_is_engine(pid)
  if _is_windows() then
    local fh = io.popen('tasklist /FI "PID eq ' .. pid .. '" /NH 2>nul')
    local out = fh and fh:read("*a") or ""
    if fh then fh:close() end
    return out:find(pid, 1, true) ~= nil
           and out:lower():find("python") ~= nil
  end
  local fh = io.popen('ps -o command= -p ' .. pid .. ' 2>/dev/null')
  local out = fh and fh:read("*a") or ""
  if fh then fh:close() end
  return out:find("dub_engine%.py") ~= nil or out:find("run_dub%.py") ~= nil
end

-- Try to kill the worker published in engine_pid.txt. Returns true when the
-- cancel is resolved (killed, or the worker is verifiably gone); false when
-- the pid file has not been written yet and the caller must retry.
local function _try_cancel_kill()
  local content = read_all(PID_PATH)
  if not content then return false end
  local pid = content:match("(%d+)")
  if not pid then return false end
  if pid_is_engine(pid) then
    if _is_windows() then
      -- /T kills the whole tree.
      os.execute(string.format('taskkill /F /T /PID %s > nul 2>&1', pid))
    else
      -- The worker runs in its own session (start_new_session=True), so
      -- signal the process group first, then the pid itself as a fallback.
      os.execute(string.format('kill -9 -%s 2>/dev/null; kill -9 %s 2>/dev/null',
                               pid, pid))
    end
    log_append("[panel] Cancel requested — killed worker pid " .. pid)
  else
    log_append("[panel] Cancel: pid " .. pid ..
               " no longer belongs to the dub worker — nothing to kill")
  end
  return true
end

local function cancel_engine()
  if _ui_cancelled then return end
  if _try_cancel_kill() then
    _ui_cancelled   = true
    _cancel_pending = false
  else
    -- run_dub.py needs a moment after launch to publish engine_pid.txt.
    -- Do NOT latch _ui_cancelled yet: poll_engine() retries the kill every
    -- frame until the pid appears, so an early Cancel is never a no-op.
    if not _cancel_pending then
      log_append("[panel] Cancel requested — waiting for the engine pid…")
    end
    _cancel_pending = true
  end
end

-- ---------------------------------------------------------------------------
-- Manifest loading (same tolerant reader as Import_Dub_Results.lua)
-- ---------------------------------------------------------------------------

local MANIFEST_KEYS = {
  "status", "error", "audio", "language", "out_dir",
  "en_audio", "en_srt", "tts_wav", "timestamps_txt",
  "synced_wav", "synced_srt",
  -- v0.2: review manifest ("status":"review") and regen manifest fields.
  "en_text", "translation_text", "final_script", "regen_wav",
  -- v0.3: --test-llm manifest fields ("voices" from --list-voices is an
  -- array and is parsed separately by parse_voices_json).
  "provider", "model", "reply",
  -- v0.4: --voice-change manifest field.
  "vc_wav",
  -- v0.7: match sync mode (texts sidecar for the item text + chunk counts).
  "sync_texts", "synced_count", "unsynced_count",
  -- v0.13: pause-aware plan manifest ("status":"plan"). The counts are
  -- strings like every other numeric field here — json_field returns
  -- numbers as text and every consumer tonumber()s what it needs.
  "plan_txt", "plan_html", "chunk_count",
  "fits_count", "tight_count", "over_count", "short_count", "empty_count",
}

-- Parse the "voices" array of a --list-voices manifest:
--   {"status":"ok","voices":[{"id":"…","name":"…"}, …]}
-- Walks the array with the real JSON string decoder, so braces/brackets
-- inside voice names can never derail it. Returns a list of {id, name}.
local function parse_voices_json(text)
  local voices = {}
  if not text then return voices end
  local a, b = text:find('"voices"', 1, true)
  if not a then return voices end
  local i = skip_ws(text, b + 1)
  if text:sub(i, i) ~= ":" then return voices end
  i = skip_ws(text, i + 1)
  if text:sub(i, i) ~= "[" then return voices end
  i = i + 1
  while i <= #text do
    i = skip_ws(text, i)
    local c = text:sub(i, i)
    if c == "]" or c == "" then break end
    if c == "{" then
      -- One voice object: read "key": "value" string pairs until "}".
      local obj = {}
      i = i + 1
      while i <= #text do
        i = skip_ws(text, i)
        local cc = text:sub(i, i)
        if cc == "}" then i = i + 1 break end
        if cc == '"' then
          local key; key, i = decode_json_string(text, i)
          i = skip_ws(text, i)
          if text:sub(i, i) == ":" then
            i = skip_ws(text, i + 1)
            if text:sub(i, i) == '"' then
              local val; val, i = decode_json_string(text, i)
              obj[key] = val
            else
              -- Non-string value (number/bool/null): skip the token.
              local j = text:find("[,}%]]", i) or (#text + 1)
              i = j
            end
          end
        else
          i = i + 1
        end
      end
      if (obj.id or "") ~= "" then
        voices[#voices + 1] = { id = obj.id, name = obj.name or "" }
      end
    else
      i = i + 1
    end
  end
  return voices
end

local function load_manifest_json(path)
  local text = read_all(path)
  if not text then return nil, "Could not read file:\n" .. path end
  if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
  local m = {}
  for _, k in ipairs(MANIFEST_KEYS) do
    local v = json_field(text, k)
    if type(v) == "string" then
      m[k] = v
    elseif v ~= nil then
      m[k] = tostring(v)
    else
      m[k] = ""
    end
  end
  if m.status == "" and m.timestamps_txt == "" and m.synced_srt == ""
     and m.en_audio == "" and m.synced_wav == "" then
    return nil, "This does not look like an engine_done.json manifest:\n" .. path
  end
  return m
end

-- Startup probe: a staged run that paused for review while the panel was
-- closed leaves its review manifest in status/. Offer to resume it from the
-- setup phase instead of forcing a full (paid) re-run of the translate step.
-- v0.5: also probe the legacy shared status root, so a review paused under
-- the pre-merge layout is still resumable after updating.
do
  local probe_paths = { DONE_JSON,
                        V5.STATUS_ROOT .. SEP .. "engine_done.json" }
  for _, p in ipairs(probe_paths) do
    if file_exists(p) then
      local m = load_manifest_json(p)
      if m and m.status == "review" then _resume_manifest = m break end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Timestamps file parser
--   [Index] [Orig Start] [Orig End] [Orig Duration] [Synced Start]
--   [2] [630ms] [2790ms] [2160ms] [49879ms]      (ms → seconds)
-- ---------------------------------------------------------------------------

local TS_PATTERN = "%[%s*(%d+)%s*%]%s*%[%s*(%d+)%s*ms%s*%]%s*%[%s*(%d+)%s*ms%s*%]" ..
                   "%s*%[%s*(%d+)%s*ms%s*%]%s*%[%s*(%d+)%s*ms%s*%]"

local function parse_timestamps_file(path)
  local entries = {}
  local f = io.open(path, "rb")
  if not f then return entries end
  for line in f:lines() do
    local idx, s_ms, e_ms, d_ms, sy_ms = line:match(TS_PATTERN)
    if idx then
      local orig_start = tonumber(s_ms) / 1000.0
      local orig_end   = tonumber(e_ms) / 1000.0
      local dur        = tonumber(d_ms) / 1000.0
      local synced     = tonumber(sy_ms) / 1000.0
      if dur <= 0 then dur = orig_end - orig_start end
      -- v0.7 optional 6th field [synced]/[unsync] (letters only — a
      -- 5-field line's trailing "[1234ms]" can never match). Absent =
      -- synced, so pre-v0.7 files import exactly as before.
      local status = line:match("%[%s*(%a+)%s*%]%s*$")
      if dur > 0 then
        entries[#entries + 1] = {
          index        = tonumber(idx),
          orig_start   = orig_start,
          orig_end     = orig_end,
          dur          = dur,
          synced_start = synced,
          unsync       = (status == "unsync") or nil,
        }
      end
    end
  end
  f:close()
  return entries
end

-- ---------------------------------------------------------------------------
-- v0.13 sync plan parser (<base>_sync_plan.txt) — the editable dry-run
-- artifact written by "--steps plan":
--   [1] [0ms] [4120ms] [4120ms] [680ms] [fits] [3980ms] [1.00]
--   EN: what the source said here
--   TR: the target text that has to fit
-- Line-oriented on purpose: this file's Lua reader is flat-scalar JSON only,
-- so a nested JSON plan would arrive with its numbers dropped.
-- V5 function, not a local — the main chunk sits at Lua's 200-local limit.
-- ---------------------------------------------------------------------------

local PLAN_PATTERN = "%[%s*(%d+)%s*%]%s*%[%s*(%d+)%s*ms%s*%]%s*%[%s*(%d+)%s*ms%s*%]" ..
                     "%s*%[%s*(%d+)%s*ms%s*%]%s*%[%s*(%d+)%s*ms%s*%]" ..
                     "%s*%[%s*(%a+)%s*%]%s*%[%s*(%d+)%s*ms%s*%]" ..
                     "%s*%[%s*([%d%.]+)%s*%]"

function V5.parse_plan_file(path)
  local rows = {}
  local content = read_all(path)
  if not content then return rows end
  if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  local cur, in_tr = nil, false
  for line in (content .. "\n"):gmatch("(.-)\n") do
    local t = line:match("^%s*(.-)%s*$")
    local idx, s_ms, e_ms, d_ms, p_ms, verdict, est_ms, atempo =
      t:match(PLAN_PATTERN)
    if idx then
      cur = {
        index   = tonumber(idx),
        start_s = tonumber(s_ms) / 1000.0,
        end_s   = tonumber(e_ms) / 1000.0,
        dur     = tonumber(d_ms) / 1000.0,
        pause   = tonumber(p_ms) / 1000.0,
        verdict = verdict,
        est     = tonumber(est_ms) / 1000.0,
        atempo  = tonumber(atempo) or 1.0,
        en = "", tr = "",
      }
      rows[#rows + 1] = cur
      in_tr = false
    elseif cur then
      if t:sub(1, 3) == "EN:" then
        cur.en = t:sub(4):match("^%s*(.-)%s*$")
        in_tr = false
      elseif t:sub(1, 3) == "TR:" then
        cur.tr = t:sub(4):match("^%s*(.-)%s*$")
        in_tr = true
      elseif t:sub(1, 1) == "#" or t == "" then
        in_tr = false
      elseif in_tr then
        -- A TR line the user wrapped across several lines.
        cur.tr = (cur.tr ~= "" and (cur.tr .. " ") or "") .. t
      end
    end
  end
  return rows
end

-- v0.7 texts sidecar (<base>_sync_texts.txt): blank-line-separated blocks,
-- block N = chunk text for timestamps index N (hidden item text, both tracks).
-- V5 field, not a local — the main chunk sits at Lua's 200-local limit.
function V5.parse_texts_file(path)
  local blocks = {}
  local content = read_all(path)
  if not content then return blocks end
  if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  local parts = nil
  local function flush()
    if parts and #parts > 0 then
      blocks[#blocks + 1] = table.concat(parts, " ")
    end
    parts = nil
  end
  for line in (content .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed == "" then flush()
    else
      parts = parts or {}
      parts[#parts + 1] = trimmed
    end
  end
  flush()
  return blocks
end

-- ---------------------------------------------------------------------------
-- SRT parser — CRLF-safe, multi-line cue text joined with " ", UTF-8
-- byte-safe (only splits on newline bytes / matches ASCII classes).
-- ---------------------------------------------------------------------------

local SRT_TIME_PATTERN = "^%s*(%d+):(%d+):(%d+)[,%.](%d+)%s*%-%->" ..
                         "%s*(%d+):(%d+):(%d+)[,%.](%d+)"

local function parse_srt_file(path)
  local cues = {}
  local content = read_all(path)
  if not content then return cues end
  if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")

  local cur = nil
  local function flush()
    if cur then
      cur.text = table.concat(cur.parts, " ")
      cur.parts = nil
      cues[#cues + 1] = cur
      cur = nil
    end
  end

  for line in (content .. "\n"):gmatch("(.-)\n") do
    local h1, m1, s1, ms1, h2, m2, s2, ms2 = line:match(SRT_TIME_PATTERN)
    if h1 then
      flush()
      cur = {
        start = tonumber(h1) * 3600 + tonumber(m1) * 60 + tonumber(s1)
                + tonumber(ms1) / 1000.0,
        stop  = tonumber(h2) * 3600 + tonumber(m2) * 60 + tonumber(s2)
                + tonumber(ms2) / 1000.0,
        parts = {},
      }
    elseif cur then
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed == "" then
        flush()
      else
        cur.parts[#cur.parts + 1] = trimmed
      end
    end
  end
  flush()

  table.sort(cues, function(a, b) return a.start < b.start end)
  return cues
end

-- ---------------------------------------------------------------------------
-- Import to timeline — IDENTICAL layout to Import_Dub_Results.lua
-- ---------------------------------------------------------------------------

local TRACK_EN     = "EN Original"
local TRACK_CHUNKS = "Dub Chunks"
local TRACK_REF    = "Dub Rendered (ref)"
-- v0.7: [unsync] chunks land here — same name + find-or-reuse rule as the
-- Auto Sync tab's Un sync track (both tools park leftovers in one place).
V5.TRACK_UNSYNC = "Un sync"

function V5.find_or_append_track(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if ok and nm == name then return tr end
  end
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local tr = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  return tr
end

-- Never reuse an existing same-named track: find the smallest suffix
-- (" 2", " 3", ...) free for ALL THREE names at once ("" first import).
local function fresh_name_suffix()
  local existing = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if ok and nm then existing[nm] = true end
  end
  local n = 1
  while n < 1000 do
    local suffix = (n == 1) and "" or (" " .. n)
    if not (existing[TRACK_EN .. suffix]
            or existing[TRACK_CHUNKS .. suffix]
            or existing[TRACK_REF .. suffix]) then
      return suffix
    end
    n = n + 1
  end
  return " " .. tostring(os.time())
end

local function append_named_track(name)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local tr = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  return tr
end

local function add_file_item(track, path, position, length, startoffs, take_name)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src)
  if not length then
    local src_len, is_qn = reaper.GetMediaSourceLength(src)
    if src_len and not is_qn then length = src_len end
  end
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", position or 0)
  if length and length > 0 then
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
  end
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", startoffs or 0)
  if take_name and take_name ~= "" then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", take_name, true)
  end
  return item
end

-- v0.8: the chunk text lives in a hidden per-item ext state instead of the
-- item notes field. REAPER paints notes across the top of the item, which
-- covered the waveform people are actually editing against; the text is only
-- ever read back by the Regenerate tab, so it never needs to be on screen.
V5.ITEM_TEXT_KEY = "P_EXT:fastsyncs_chunk_text"

function V5.set_item_text(item, text)
  reaper.GetSetMediaItemInfo_String(item, V5.ITEM_TEXT_KEY, text or "", true)
  -- Pre-v0.8 imports put the same text in the visible notes field; clear it
  -- so re-imported / regenerated items stop drawing over the waveform.
  reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", true)
end

function V5.get_item_text(item)
  local ok, t = reaper.GetSetMediaItemInfo_String(item, V5.ITEM_TEXT_KEY,
                                                  "", false)
  if ok and t and t ~= "" then return t end
  -- Fallback: projects imported before v0.8 still carry the text in notes.
  local _, note = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
  return note or ""
end

-- Contract note-matching rule: by order when counts are equal; otherwise
-- nearest cue start within 0.5 s; else empty.
local function note_for_chunk(cues, n_entries, i, synced_start)
  if #cues == 0 then return "" end
  if #cues == n_entries then return cues[i].text or "" end
  local best, best_d = nil, math.huge
  for _, c in ipairs(cues) do
    local d = math.abs(c.start - synced_start)
    if d < best_d then best, best_d = c, d end
  end
  if best and best_d <= 0.5 then return best.text or "" end
  return ""
end

-- Run the full import for a manifest table. Returns a summary string.
local function import_to_timeline(m)
  local skipped = {}
  local function skip(reason) skipped[#skipped + 1] = reason end

  local en_audio = m.en_audio or ""
  if en_audio ~= "" and not file_exists(en_audio) then
    skip('en_audio: file not found ("' .. en_audio .. '")')
    en_audio = ""
  elseif en_audio == "" then
    skip("en_audio: empty in manifest")
  end

  local entries = {}
  local ts_path = m.timestamps_txt or ""
  if ts_path ~= "" and file_exists(ts_path) then
    entries = parse_timestamps_file(ts_path)
    if #entries == 0 then
      skip("timestamps_txt: no parsable lines -- Dub Chunks skipped")
    end
  elseif ts_path == "" then
    skip("timestamps_txt: empty in manifest -- Dub Chunks skipped")
  else
    skip('timestamps_txt: file not found ("' .. ts_path .. '")')
  end

  local tts_wav = m.tts_wav or ""
  if #entries > 0 then
    if tts_wav == "" then
      skip("tts_wav: empty in manifest -- Dub Chunks skipped")
      entries = {}
    elseif not file_exists(tts_wav) then
      skip('tts_wav: file not found ("' .. tts_wav .. '") -- Dub Chunks skipped')
      entries = {}
    end
  end

  local cues = {}
  local synced_srt = m.synced_srt or ""
  if synced_srt ~= "" and file_exists(synced_srt) then
    cues = parse_srt_file(synced_srt)
    if #cues == 0 then
      skip("synced_srt: no parsable cues -- no chunk text fallback")
    end
  elseif synced_srt == "" then
    skip("synced_srt: empty in manifest -- no chunk text fallback")
  else
    skip('synced_srt: file not found ("' .. synced_srt .. '")')
  end

  local synced_wav = m.synced_wav or ""
  if synced_wav ~= "" and not file_exists(synced_wav) then
    skip('synced_wav: file not found ("' .. synced_wav .. '")')
    synced_wav = ""
  elseif synced_wav == "" then
    skip("synced_wav: empty in manifest -- reference track skipped")
  end

  if en_audio == "" and #entries == 0 and synced_wav == "" and #cues == 0 then
    return "Nothing to import -- every manifest field was empty or missing:\n- "
           .. table.concat(skipped, "\n- ")
  end

  -- v0.31: where this dub belongs on the timeline. A run made from a REGION
  -- (a trimmed item, a time selection) covers a slice that starts somewhere
  -- in the middle of the talk, and every time in the manifest is measured
  -- from that slice's own 0:00. Placing them at the project's 0:00 would put
  -- the whole dub minutes away from the audio it was made for. The sidecar
  -- beside the region wav says where the slice starts; a plain file has no
  -- sidecar and answers 0, which is what every run did before.
  local off = V5.region_offset(m.audio or "")
  if off == 0 then off = V5.region_offset(m.en_audio or "") end

  -- Build everything inside one undo block.
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local suffix = fresh_name_suffix()
  local chunks_added, notes_matched = 0, 0

  -- 1. EN Original
  if en_audio ~= "" then
    local tr = append_named_track(TRACK_EN .. suffix)
    local it = add_file_item(tr, en_audio, off, nil, 0, basename(en_audio))
    if not it then skip("en_audio: REAPER could not open the media file") end
  end

  -- 2. Dub Chunks (synced) + Un sync (v0.7 [unsync] entries)
  local unsync_added = 0
  if #entries > 0 then
    local texts = {}
    if (m.sync_texts or "") ~= "" and file_exists(m.sync_texts) then
      texts = V5.parse_texts_file(m.sync_texts)
    end
    local synced_entries, unsync_entries = {}, {}
    for _, e in ipairs(entries) do
      if e.unsync then unsync_entries[#unsync_entries + 1] = e
      else synced_entries[#synced_entries + 1] = e end
    end
    local function note_for(e, list_n, i)
      local t = texts[e.index or 0]
      if t and t ~= "" then return t end
      return note_for_chunk(cues, list_n, i, e.synced_start)
    end

    if #synced_entries > 0 then
      local tr = append_named_track(TRACK_CHUNKS .. suffix)
      for i, e in ipairs(synced_entries) do
        local it = add_file_item(tr, tts_wav, off + e.synced_start, e.dur,
                                 e.orig_start,
                                 string.format("chunk %02d", e.index or i))
        if it then
          chunks_added = chunks_added + 1
          local note = note_for(e, #synced_entries, i)
          if note ~= "" then
            V5.set_item_text(it, note)
            notes_matched = notes_matched + 1
          end
        end
      end
      if chunks_added == 0 then
        skip("tts_wav: REAPER could not open the media file -- no chunks placed")
      end
    end

    if #unsync_entries > 0 then
      local tr = V5.find_or_append_track(V5.TRACK_UNSYNC)
      for i, e in ipairs(unsync_entries) do
        local it = add_file_item(tr, tts_wav, off + e.synced_start, e.dur,
                                 e.orig_start,
                                 string.format("unsync %02d", e.index or i))
        if it then
          unsync_added = unsync_added + 1
          local note = note_for(e, #unsync_entries, i)
          if note ~= "" then
            V5.set_item_text(it, note)
          end
        end
      end
    end
  end

  -- 3. Dub Rendered (ref) -- muted reference track
  if synced_wav ~= "" then
    local tr = append_named_track(TRACK_REF .. suffix)
    reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1)
    local it = add_file_item(tr, synced_wav, off, nil, 0, basename(synced_wav))
    if not it then skip("synced_wav: REAPER could not open the media file") end
  end

  -- v0.8: no regions. One region per cue drew a vertical line through every
  -- track at every cue boundary, which is what made the arrange view
  -- unreadable at normal zoom. The cue text still reaches the items above.

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Import dub results", -1)

  local lines = {
    "Import finished" .. (suffix ~= "" and " (track set" .. suffix .. ")" or "") .. ".",
    "",
    "Dub chunks placed: " .. chunks_added,
  }
  if unsync_added > 0 then
    lines[3] = "Synced chunks placed: " .. chunks_added
    lines[#lines + 1] = "Un sync chunks:    " .. unsync_added
                        .. '  (on the "' .. V5.TRACK_UNSYNC .. '" track)'
  end
  if chunks_added > 0 then
    lines[#lines + 1] = "Chunk text stored:  " .. notes_matched
                        .. " of " .. chunks_added
                        .. "  (hidden -- shown in the Regenerate tab)"
  end
  if off > 0 then
    -- Said out loud: everything landed minutes into the project, on purpose.
    lines[#lines + 1] = "Placed at:          " .. V5.fmt_pos(off)
                        .. "  (this run dubbed a region of the timeline, "
                        .. "so it goes back where it came from)"
  end
  if #skipped > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Skipped (" .. #skipped .. "):"
    for _, s in ipairs(skipped) do lines[#lines + 1] = "- " .. s end
  end
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Launch + poll
-- ---------------------------------------------------------------------------

-- Every path is quoted — this project's paths all contain spaces.
-- Language names never contain spaces (argparse choices), voice/model are
-- quoted anyway in case of stray whitespace.
-- opts: audio, language, steps, script, provided_script, regen (bool),
-- text_file, out_wav, test_llm (bool), list_voices (bool),
-- voice_change (bool), in_wav, voice_id (overrides the Settings voice) —
-- covers all v0.2/v0.3/v0.4 engine invocations (full/translate/dub runs,
-- chunk regen, LLM test, voice list, track voice change).
-- v0.3: --app-dir is no longer passed (optional and ignored by the engine);
-- keys/settings come from config/*.json, never from the command line.
local function build_engine_cmd(py, opts)
  -- Windows: the command runs via ExecProcess / cmd's `start`, where double
  -- quotes are the correct escaping. macOS/Linux: os.execute goes through
  -- /bin/sh, where double quotes still expand $, backtick and backslash and
  -- an embedded " breaks the whole line — use POSIX single-quoting there.
  -- V5.winquote, not bare double quotes: wrapping a value in quotes is not
  -- escaping, and VOICE_ID and the ElevenLabs model name are both editable in
  -- Settings and both flow into this command line.
  local q = _is_windows() and V5.winquote or shellquote
  local parts = {
    -- pythonw.exe on Windows — the same interpreter with no console window
    -- (see V5.pythonw). Every caller of this feeds launch_engine, which
    -- detaches the process; its output is read back from engine_log.txt.
    q(V5.pythonw(py)),
    q(RUN_DUB_PY),
    -- v0.5: per-project status dir — every mode reports into the dir the
    -- panel is polling (see V5.set_status_paths()).
    '--status-dir',
    q(STATUS_DIR),
  }
  if opts.test_llm then
    -- One tiny LLM call; needs no audio/language/voice flags.
    parts[#parts + 1] = '--test-llm'
    return table.concat(parts, ' ')
  end
  if opts.list_voices then
    -- Voice catalogue for the current language; no audio/voice flags.
    parts[#parts + 1] = '--list-voices'
    parts[#parts + 1] = '--language'
    parts[#parts + 1] = opts.language or LANGUAGE
    return table.concat(parts, ' ')
  end
  if opts.regen then
    parts[#parts + 1] = '--regen-chunk'
  end
  if opts.voice_change then
    parts[#parts + 1] = '--voice-change'
  end
  if opts.in_wav then
    parts[#parts + 1] = '--in-wav'
    parts[#parts + 1] = q(opts.in_wav)
  end
  if opts.audio and opts.audio ~= '' then
    parts[#parts + 1] = '--audio'
    parts[#parts + 1] = q(opts.audio)
  end
  parts[#parts + 1] = '--language'
  parts[#parts + 1] = opts.language or LANGUAGE
  -- opts.voice_id overrides the Settings voice (used by voice change).
  local vid = opts.voice_id or VOICE_ID
  if vid and vid:match("%S") then
    parts[#parts + 1] = '--voice-id'
    parts[#parts + 1] = q(vid)
  end
  if EL_MODEL and EL_MODEL:match("%S") then
    parts[#parts + 1] = '--el-model'
    parts[#parts + 1] = q(EL_MODEL)
  end
  if opts.steps then
    parts[#parts + 1] = '--steps'
    parts[#parts + 1] = opts.steps
  end
  if opts.script then
    parts[#parts + 1] = '--script'
    parts[#parts + 1] = q(opts.script)
  end
  if opts.provided_script then
    parts[#parts + 1] = '--provided-script'
    parts[#parts + 1] = q(opts.provided_script)
  end
  if opts.plan then
    parts[#parts + 1] = '--plan'
    parts[#parts + 1] = q(opts.plan)
  end
  if opts.text_file then
    parts[#parts + 1] = '--text-file'
    parts[#parts + 1] = q(opts.text_file)
  end
  if opts.out_wav then
    parts[#parts + 1] = '--out-wav'
    parts[#parts + 1] = q(opts.out_wav)
  end
  return table.concat(parts, ' ')
end

-- ─── Setup / update helpers (v0.5, fast-syncs merge) ──────────────────────
-- The dubbing app ships inside the fast-syncs repo: BASE_DIR is
-- <fast syncs>/dubbing, so the shared updater lives one level up.
-- (All in the V5 table — the main chunk is near Lua's 200-local limit.)
V5.FS_ROOT = BASE_DIR:match("^(.*)[/\\][^/\\]*$") or BASE_DIR

function V5.updater_path()
  local p = _is_windows() and (V5.FS_ROOT .. "\\update.bat")
                          or  (V5.FS_ROOT .. "/update.sh")
  if file_exists(p) then return p end
  return nil
end

-- Open a setup/update script in a visible terminal WITHOUT relying on macOS
-- AppleEvents. The `osascript -e 'tell application "Terminal"...'` route
-- needs Automation permission (REAPER → Terminal); when it was never granted
-- — or was denied — the call fails SILENTLY and the button looks dead. That
-- is the #1 "Update/Setup does nothing" report on macOS.
--   macOS: `open` a .command wrapper (needs no special permission; a
--          locally-written file has no Gatekeeper quarantine, so it runs).
--          A .command target is opened directly.
--   Windows: `start "" "<script>"` runs the .bat in a NEW console that stays
--          up (our .bat scripts end with `pause`). Empty title so a path
--          with spaces (…/fast syncs/…) is the program, not the title.
-- Returns the shell command run (shown to the user as a manual fallback).
function V5.run_in_terminal(path, extra_args)
  extra_args = (extra_args and extra_args ~= "") and (" " .. extra_args) or ""
  if _is_windows() then
    local cmd = 'start "" "' .. path .. '"' .. extra_args
    os.execute(cmd)
    return cmd
  end
  local osname = reaper.GetOS() or ""
  local opener = (osname:match("OSX") or osname:match("[Mm]ac")) and "open"
                 or "xdg-open"
  -- A .command target can be opened directly — but `open` cannot pass
  -- arguments to it, so any call WITH extra_args must go through the
  -- wrapper below (which bakes the args into its bash line).
  if path:match("%.command$") and extra_args == "" then
    local cmd = opener .. ' "' .. path .. '"'
    os.execute(cmd)
    return cmd
  end
  local tmp = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
  local tag = (path:match("([^/\\]+)$") or "run"):gsub("[^%w%-_.]", "_")
  local wrapper = tmp .. "/fs_" .. tag .. ".command"
  local dir = path:match("^(.*)[/\\][^/\\]*$") or "."
  local f = io.open(wrapper, "wb")
  if f then
    f:write("#!/bin/bash\n")
    f:write('cd "' .. dir .. '"\n')
    f:write('bash "' .. path .. '"' .. extra_args .. "\n")
    f:write('status=$?\n')
    f:write('echo; echo "[Finished (exit $status) — press Return to close.]"; read _\n')
    f:close()
    os.execute('chmod +x "' .. wrapper .. '"')
    local cmd = opener .. ' "' .. wrapper .. '"'
    os.execute(cmd)
    return cmd
  end
  local cmd = opener .. ' "' .. path .. '"'
  os.execute(cmd)
  return cmd
end

-- ── v0.16 update check ──────────────────────────────────────────────────────
-- "Update…" used to be a button you pressed to find out whether you needed it.
-- Instead the panel compares the VERSION file it ships with against the one on
-- main, once per launch, and only speaks up when there IS a newer one.
--
-- The fetch is fire-and-forget into a temp file, read back on a later frame:
-- reaper.ExecProcess with a positive timeout is SYNCHRONOUS — the whole REAPER
-- UI freezes for its duration — so a blocking curl at startup would stall the
-- DAW on every slow network. curl writes a .part and renames it, so a frame
-- that catches the file mid-write cannot read half a version number.
V5.UPD_URL =
  'https://raw.githubusercontent.com/darpantimsina72/fast-syncs/main/VERSION'
V5.upd = {
  state     = 'idle',   -- idle | checking | current | available | failed
  latest    = nil,
  file      = nil,
  deadline  = 0,
  available = false,
  popup     = false,    -- an "update available" dialog is due
  asked     = false,    -- ...and has already been shown this session
}

function V5.tmp_dir()
  if _is_windows() then
    return ((os.getenv('TEMP') or os.getenv('TMP') or 'C:\\Windows\\Temp')
            :gsub('[/\\]+$', ''))
  end
  return ((os.getenv('TMPDIR') or '/tmp'):gsub('/+$', ''))
end

-- ─── Windows: launch without a console window ──────────────────────────────
-- reaper.ExecProcess(cmd, -2) detaches the child but does NOT suppress its
-- console, so every console-subsystem exe we start (python.exe for the
-- engine, cmd.exe/curl.exe for the probes) gets its own window on top of
-- REAPER for as long as it runs. All of it is redundant: the engine's output
-- is teed to engine_log.txt and shown in the panel's log pane, and the curl
-- probes are read back from files. Two routes, both no-window:
--   * the engine  -> pythonw.exe, a GUI-subsystem build of the SAME
--                    interpreter, so no console is ever created for it;
--   * the helpers -> pythonw.exe running engine/hidden_run.py, which
--                    re-launches the real command with CREATE_NO_WINDOW.
-- Both fall back to the old visible-window command when the pythonw half is
-- missing, so a partial install still works — just noisily.
V5.HIDDEN_PY = ENGINE_DIR .. SEP .. "hidden_run.py"

-- "…/python.exe" -> "…/pythonw.exe" when that exists beside it. Any other
-- shape (bare "python" from PATH, a non-.exe path, macOS/Linux) is returned
-- unchanged: there is nothing to verify and nothing to gain.
function V5.pythonw(py)
  if not _is_windows() or not py or py == "" then return py end
  local cand = py:gsub('%.[Ee][Xx][Ee]$', 'w.exe')
  if cand ~= py and file_exists(cand) then return cand end
  return py
end

-- The interpreter used to run hidden_run.py. Only the project venv is
-- considered, and only by file_exists: this is called from the per-keystroke
-- connection probe, so it must never fall through to probe_python() (a
-- synchronous ExecProcess would freeze the UI thread). Cached; false = none.
function V5.hidden_py()
  if V5.hidden_pyw ~= nil then return V5.hidden_pyw or nil end
  V5.hidden_pyw = false
  if _is_windows() and file_exists(V5.HIDDEN_PY) then
    local w = V5.pythonw(project_venv_python())
    if w and w:match('w%.[Ee][Xx][Ee]$') then V5.hidden_pyw = w end
  end
  return V5.hidden_pyw or nil
end

-- Run *cmd* (a cmd.exe command line) detached with no console window. *tag*
-- names the scratch .bat, one per caller so concurrent probes never collide.
-- Returns false when the hidden route is unavailable and the caller must fall
-- back to its plain ExecProcess.
function V5.win_hidden(cmd, tag)
  if not _is_windows() or not reaper.ExecProcess then return false end
  local py = V5.hidden_py()
  if not py then return false end
  local bat = V5.tmp_dir() .. '\\fs_hidden_' .. tag .. '.bat'
  local f = io.open(bat, 'w')
  if not f then return false end
  -- A batch file eats a lone '%' (only '%%' survives), unlike the command
  -- line these strings were written for — curl's -w "%{http_code}" would
  -- arrive as "{http_code}" and the probe would never report a status.
  local ok = f:write('@echo off\r\n', (cmd:gsub('%%', '%%%%')), '\r\n')
  f:close()
  if not ok then return false end
  return reaper.ExecProcess('"' .. py .. '" "' .. V5.HIDDEN_PY .. '" "' ..
                            bat .. '"', -2) ~= nil
end

-- "0.14.1" → {0,14,1}, compared field by field so 0.9 sorts BELOW 0.14.
-- Returns -1 when a is older than b.
function V5.ver_cmp(a, b)
  local function parts(s)
    local t = {}
    for n in tostring(s or ''):gmatch('%d+') do t[#t + 1] = tonumber(n) end
    return t
  end
  local pa, pb = parts(a), parts(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x < y and -1 or 1 end
  end
  return 0
end

function V5.check_update()
  if V5.upd.state == 'checking' then return end
  -- Nothing to compare against: no VERSION file means this is not a release
  -- checkout, and every remote version would look newer.
  if (V5.APP_VERSION or '') == '' then V5.upd.state = 'failed' return end
  if _is_windows() and not reaper.ExecProcess then
    V5.upd.state = 'failed' return
  end

  local sep  = _is_windows() and '\\' or '/'
  local out  = V5.tmp_dir() .. sep .. 'fs_latest_version.txt'
  local part = out .. '.part'
  os.remove(out)
  os.remove(part)

  V5.upd.file     = out
  V5.upd.state    = 'checking'
  V5.upd.deadline = os.time() + 25

  if _is_windows() then
    -- curl.exe ships with Windows 10 1803+; -s quiet, -m caps the transfer.
    local line = 'curl.exe -s -m 12 -o "' .. part .. '" ' .. V5.UPD_URL ..
                 ' && move /y "' .. part .. '" "' .. out .. '"'
    if not V5.win_hidden(line, 'upd') then
      reaper.ExecProcess('cmd.exe /C ' .. line, -2)
    end
  else
    os.execute('{ curl -s -m 12 -o "' .. part .. '" "' .. V5.UPD_URL ..
               '" && mv -f "' .. part .. '" "' .. out .. '" ; } ' ..
               '>/dev/null 2>&1 &')
  end
end

-- Called every frame. Cheap until the fetch lands, then never runs again.
function V5.poll_update()
  if V5.upd.state ~= 'checking' then return end
  local f = V5.upd.file and io.open(V5.upd.file, 'r')
  if f then
    local raw = f:read('*a') or ''
    f:close()
    local ver = raw:match('(%d+[%d%.]*)')
    if ver then
      V5.upd.latest = ver
      if V5.ver_cmp(V5.APP_VERSION, ver) < 0 then
        V5.upd.state     = 'available'
        V5.upd.available = true
        V5.upd.popup     = true
      else
        V5.upd.state = 'current'
      end
      os.remove(V5.upd.file)
      return
    end
  end
  if os.time() > V5.upd.deadline then V5.upd.state = 'failed' end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- v0.17 CONNECTIONS — validate a key, then ask it what it serves
-- ═══════════════════════════════════════════════════════════════════════════
-- Settings used to show ONE provider (whichever the dropdown named) and could
-- only answer "does this work?" by launching the Python engine with --test-llm
-- — a whole subprocess, and impossible while a dub run owns the status files.
-- So: every API gets a row, and each row validates itself with the same
-- fire-and-forget curl the update check uses (see V5.check_update for why a
-- blocking ExecProcess would freeze REAPER). Two files per probe: the response
-- body, renamed into place so a frame can never read half of it, and curl's
-- own HTTP status code.
--
-- The model list is the point. A key does not name one model — it grants
-- access to a set — so a valid key answers "which ids can I actually type in
-- the Model box", and that list feeds V5.models_for.
V5.CONN = {
  { 'openai',     'OpenAI-compatible gateway' },
  { 'gemini',     'Gemini' },
  { 'vertex',     'Vertex AI' },
  { 'server',     'Server proxy' },
  { 'elevenlabs', 'ElevenLabs' },
}

-- Wall clock. os.clock() is PROCESSOR time in Lua — inside a defer loop it
-- advances at a fraction of real time, which would turn a 0.8 s debounce into
-- several seconds of "nothing is happening".
function V5.now()
  return (reaper.time_precise and reaper.time_precise()) or os.clock()
end

function V5.conn_state(pv)
  local st = V5.conn[pv]
  if not st then
    st = { state = 'unset', models = {} }
    V5.conn[pv] = st
  end
  return st
end

-- The credential this row validates with (nil for Vertex — a service-account
-- JSON is a file, not something you paste, so it is never probed).
function V5.conn_cred(pv)
  if pv == 'openai'     then return LLM_OPENAI_KEY end
  if pv == 'gemini'     then return LLM_GEMINI_KEY end
  if pv == 'server'     then return LLM_SERVER_TOKEN end
  if pv == 'elevenlabs' then return EL_KEY end
  return nil
end

-- Keys travel on a command line, so anything that could end an argument or
-- start a new command is dropped rather than escaped. Real keys are
-- base64/hex/dotted and survive this untouched.
function V5.conn_safe(s)
  return (tostring(s or ''):gsub('[^%w%-%_%.%+%/%=%:%~]', ''))
end

-- "host", "host/v1", "https://host/" → an API base ending in a version
-- segment. The wrong shape here is the single most common gateway mistake, so
-- the probe fixes what it safely can instead of failing on it.
function V5.conn_api_base(url)
  local u = tostring(url or ''):gsub('%s+', ''):gsub('/+$', '')
  if u == '' then return nil end
  if not u:match('^https?://') then u = 'http://' .. u end
  u = u:gsub('/chat/completions$', '')
  if not u:match('/v%d') then u = u .. '/v1' end
  return u
end

-- Where to ask, and with which header. Returns url, header or nil, why.
function V5.conn_endpoint(pv)
  local key = V5.conn_safe(V5.conn_cred(pv))
  if pv == 'openai' then
    local base = V5.conn_api_base(LLM_OPENAI_URL)
    if not base then return nil, 'Base URL is empty' end
    return base .. '/models',
           key ~= '' and ('Authorization: Bearer ' .. key) or nil
  elseif pv == 'server' then
    local base = V5.conn_api_base(LLM_SERVER_URL)
    if not base then return nil, 'Server URL is empty' end
    return base .. '/models',
           key ~= '' and ('Authorization: Bearer ' .. key) or nil
  elseif pv == 'gemini' then
    if key == '' then return nil, 'no key' end
    return 'https://generativelanguage.googleapis.com/v1beta/models?key=' ..
           key, nil
  elseif pv == 'elevenlabs' then
    if key == '' then return nil, 'no key' end
    return 'https://api.elevenlabs.io/v1/models', 'xi-api-key: ' .. key
  end
  return nil, 'not probed'
end

-- Model ids out of a response body, by pattern rather than a JSON parser: the
-- three shapes are known and each is one field deep.
function V5.conn_models_from(pv, body)
  body = tostring(body or '')
  local out, seen = {}, {}
  local function add(id)
    id = tostring(id or ''):match('^%s*(.-)%s*$')
    if id ~= '' and not seen[id] and #out < 80 then
      out[#out + 1] = id
      seen[id] = true
    end
  end
  if pv == 'gemini' then
    -- ListModels also returns embedding/media models, which would be dead
    -- entries in a text-generation dropdown.
    for id in body:gmatch('"name"%s*:%s*"models/(.-)"') do
      if not id:match('embedding') and not id:match('aqa')
         and not id:match('imagen') and not id:match('veo')
         and not id:match('^tts') and not id:match('%-tts') then
        add(id)
      end
    end
  elseif pv == 'elevenlabs' then
    for id in body:gmatch('"model_id"%s*:%s*"(.-)"') do add(id) end
  else
    for id in body:gmatch('"id"%s*:%s*"(.-)"') do add(id) end
  end
  return out
end

-- What went wrong, in the words the fix needs. The provider's own "message"
-- is included when there is one — it is usually the most specific thing said.
function V5.conn_fail_msg(pv, code, body)
  local detail = tostring(body or ''):match('"message"%s*:%s*"(.-)"')
  if detail and #detail > 140 then detail = detail:sub(1, 140) .. '…' end
  local body_s = tostring(body or '')
  local head
  -- Google answers a bad AI Studio key with 400 API_KEY_INVALID, not 401, so
  -- code alone would report it as a mysterious "HTTP 400" (verified against
  -- the live endpoint).
  local bad_key = (code == 400) and (body_s:match('API_KEY_INVALID')
                                     or body_s:match('[Aa][Pp][Ii] key'))
  if code == 401 or code == 403 or bad_key then
    head = 'key rejected (HTTP ' .. code .. ')'
  elseif code == 404 then
    head = (pv == 'openai' or pv == 'server')
           and 'no /models here (HTTP 404) — Base URL must be the API base, ' ..
               'e.g. host/v1'
           or  'not found (HTTP 404)'
  elseif code == 429 then
    head = 'rate limited (HTTP 429) — the key works, try again in a moment'
  elseif code == 0 then
    head = 'could not reach it — wrong host, or no route from this machine'
  elseif code >= 500 then
    head = 'the API is erroring (HTTP ' .. code .. ')'
  else
    head = 'HTTP ' .. tostring(code)
  end
  if detail and detail ~= '' then return head .. ' — ' .. detail end
  return head
end

-- Fire the probe. Nothing here blocks: curl writes a .part plus a file holding
-- its HTTP code, then renames the body into place as the completion signal.
function V5.conn_probe(pv)
  local st = V5.conn_state(pv)
  -- Second return is the header when there IS an endpoint, the reason when
  -- there is not.
  local url, hdr = V5.conn_endpoint(pv)
  if not url then
    st.state, st.msg, st.models = 'unset', hdr, {}
    return
  end
  if _is_windows() and not reaper.ExecProcess then
    st.state, st.msg = 'unset', 'needs curl'
    return
  end

  local sep  = _is_windows() and '\\' or '/'
  local out  = V5.tmp_dir() .. sep .. 'fs_conn_' .. pv .. '.json'
  local part = out .. '.part'
  local code = out .. '.code'
  os.remove(out)
  os.remove(part)
  os.remove(code)

  st.out       = out
  st.code_file = code
  st.state     = 'checking'
  st.msg       = nil
  st.deadline  = os.time() + 20

  local h = hdr and (' -H "' .. hdr .. '"') or ''
  if _is_windows() then
    -- One `&` not `&&`: a curl that fails still has to hand us a completion
    -- signal, or the row would sit on "checking" until the 20 s deadline.
    local line = 'curl.exe -s -m 15 -o "' .. part .. '" -w "%{http_code}"' ..
      h .. ' "' .. url .. '" > "' .. code .. '" & move /y "' .. part ..
      '" "' .. out .. '"'
    -- One .bat per provider: probes for several APIs can be in flight at once.
    if not V5.win_hidden(line, 'conn_' .. pv) then
      reaper.ExecProcess('cmd.exe /C ' .. line, -2)
    end
  else
    os.execute('{ curl -s -m 15 -o "' .. part .. '" -w "%{http_code}"' .. h ..
      ' "' .. url .. '" > "' .. code .. '" ; mv -f "' .. part .. '" "' ..
      out .. '" ; } >/dev/null 2>&1 &')
  end
end

-- Debounce. Called on every edit of a key field: one probe 0.8 s after typing
-- stops, not one per keystroke. A paste is the same event, which is why
-- pasting a key validates itself with no button to press.
function V5.conn_touch(pv, _value)
  local st = V5.conn_state(pv)
  st.state  = 'idle'
  st.msg    = nil
  st.models = {}
  st.model  = nil
  st.due    = V5.now() + 0.8
end

-- Validate everything already saved, once, when Connections first draws. A
-- row that claims to be connected has to have asked.
function V5.conn_autostart()
  if V5.conn_started then return end
  V5.conn_started = true
  local n = 0
  for _, row in ipairs(V5.CONN) do
    local pv = row[1]
    if pv ~= 'vertex' and (V5.conn_cred(pv) or '') ~= '' then
      n = n + 1
      -- Staggered: four curls in one frame is four processes competing for the
      -- same slow network.
      V5.conn_state(pv).due = V5.now() + 0.2 * n
    end
  end
end

-- Which of the served models this row should show. The configured one wins
-- when the key really serves it; otherwise the best of what it does serve —
-- displayed, not silently written over the setting (see V5.conn_apply_model).
function V5.conn_pick_model(pv, models)
  local has = {}
  for _, m in ipairs(models) do has[m] = true end
  local cur = (pv == 'elevenlabs') and EL_MODEL or LLM_MODEL
  if cur and cur ~= '' and has[cur] then return cur end
  -- The BUILT-IN lists, not V5.models_for: that one now leads with whatever
  -- the gateway happened to return first, and the built-in order is the one
  -- that encodes "this pipeline is tuned on Gemini".
  local prefer
  if pv == 'elevenlabs' then
    prefer = EL_MODELS
  elseif pv == 'gemini' or pv == 'vertex' then
    prefer = V5.MODELS_GOOGLE
  else
    prefer = {}
    for _, m in ipairs(V5.MODELS_GOOGLE) do prefer[#prefer + 1] = m end
    for _, m in ipairs(V5.MODELS_OTHER)  do prefer[#prefer + 1] = m end
  end
  for _, m in ipairs(prefer) do if has[m] then return m end end
  return models[1]
end

-- Adopt the detected model. Only ever called from the row's own button, or
-- when the setting is empty — opening Settings must not change a setting.
function V5.conn_apply_model(pv, model)
  if not model or model == '' then return end
  if pv == 'elevenlabs' then
    EL_MODEL = model
  else
    LLM_MODEL = model
  end
  -- Panel UI state only. The model itself reaches config/*.json through Save,
  -- exactly like every other field on this screen — adopting a detected model
  -- must not be the one edit that writes the engine's config behind your back.
  save_settings()
end

-- Called every frame. Cheap: it walks five rows and touches the disk only for
-- a probe that is actually in flight.
function V5.conn_poll()
  local now = V5.now()
  for _, row in ipairs(V5.CONN) do
    local pv = row[1]
    local st = V5.conn[pv]
    if st then
      if st.due and now >= st.due then
        st.due = nil
        V5.conn_probe(pv)
      end
      if st.state == 'checking' then
        local body = st.out and read_all(st.out)
        if body then
          local code = tonumber((read_all(st.code_file) or '')
                                :match('(%d%d%d)') or '') or 0
          os.remove(st.out)
          os.remove(st.code_file)
          local models = V5.conn_models_from(pv, body)
          local http_ok = (code >= 200 and code < 300)
          if http_ok and #models > 0 then
            st.state  = 'ok'
            st.models = models
            st.model  = V5.conn_pick_model(pv, models)
            st.msg    = #models .. (#models == 1 and ' model' or ' models')
                        .. ' available'
            V5.models_fetched[pv] = models
            -- An empty Model box is not a preference — fill it, so a fresh
            -- install stops being one un-runnable field away from working.
            local cur = (pv == 'elevenlabs') and EL_MODEL or LLM_MODEL
            local in_use = (pv == 'elevenlabs') or (pv == LLM_PROVIDER)
            if in_use and (cur or '') == '' then
              V5.conn_apply_model(pv, st.model)
            end
          elseif http_ok then
            -- Authenticated, but nothing recognisable came back: a gateway
            -- that answers /models with something of its own shape.
            st.state = 'ok'
            st.msg   = 'key accepted, but it did not list any models'
            st.models, st.model = {}, nil
          else
            st.state  = 'bad'
            st.models, st.model = {}, nil
            st.msg    = V5.conn_fail_msg(pv, code, body)
          end
        elseif os.time() > (st.deadline or 0) then
          st.state = 'bad'
          st.msg   = 'no answer in 20 s — check the address and your network'
        end
      end
    end
  end
end

-- One line of "where this install stands", for the About pane and anywhere
-- else that wants it. Returns text, colour.
function V5.update_status_line()
  local v = (V5.APP_VERSION or '') ~= '' and ('v' .. V5.APP_VERSION)
            or '(no VERSION file)'
  local s = V5.upd.state
  if s == 'checking' then
    return v .. '   ·   checking for updates…', V5.COL.dim
  elseif s == 'current' then
    return v .. '   ·   up to date', V5.COL.ok
  elseif s == 'available' then
    return v .. '   ·   v' .. tostring(V5.upd.latest) ..
           ' is available', V5.COL.warn
  elseif s == 'failed' then
    return v .. '   ·   could not reach GitHub to check', V5.COL.warn_text
  end
  return v, V5.COL.dim
end

-- The dialog. Native rather than an ImGui modal because the answer leaves this
-- window entirely — the updater runs in a terminal and the script must be
-- restarted afterwards.
function V5.update_popup_if_due()
  if not V5.upd.popup or V5.upd.asked then return end
  V5.upd.popup = false
  V5.upd.asked = true
  local choice = reaper.MB(
    'A newer version of Fast Syncs is available.\n\n' ..
    '    installed   v' .. tostring(V5.APP_VERSION) .. '\n' ..
    '    latest      v' .. tostring(V5.upd.latest) .. '\n\n' ..
    'Download and install it now?\n\n' ..
    'The updater opens in its own terminal window and updates the sync ' ..
    'tool and this dubbing app together. When it says "Update complete", ' ..
    'close it and run this script again.',
    'Update available', 4)
  if choice == 6 then V5.run_updater() end
end

-- Update the WHOLE fast-syncs install (sync tool + this dubbing app) via
-- the shared updater. Mirrors auto_sync_pipeline.lua's run_updater.
function V5.run_updater()
  local p = V5.updater_path()
  if not p then
    reaper.MB("No updater found at:\n  " .. V5.FS_ROOT ..
              "\n\nThis dubbing panel updates through the fast-syncs " ..
              "updater (update.sh / update.bat in the folder above " ..
              "dubbing/). Re-download the project from GitHub if it is " ..
              "missing.", "Updater not found", 0)
    return
  end
  local cmd = V5.run_in_terminal(p)
  reaper.MB("The updater is opening in a separate terminal window.\n\n" ..
            "When it says 'Update complete', close it and run the script " ..
            "again to load the new version.\n\nIf no window appeared, run " ..
            "this manually:\n  " .. cmd, "Updating", 0)
end

-- Offer to run the one-time dubbing setup (creates dubbing/venv/ and
-- installs the engine deps) when the venv is missing at launch time.
function V5.offer_run_setup(reason)
  local script = BASE_DIR .. SEP .. SETUP_SCRIPT
  if not file_exists(script) then return false end
  local ret = reaper.MB(
    (reason or "The dubbing engine's Python venv was not found.") ..
    "\n\nRun " .. SETUP_SCRIPT .. " now? It creates dubbing/venv/ and " ..
    "installs the engine dependencies (takes a few minutes).\n\n" ..
    "When it finishes, come back and click Run again.",
    "Dub Pipeline — setup needed", 4)
  if ret == 6 then
    local cmd = V5.run_in_terminal(script)
    reaper.MB("Setup is opening in a terminal window.\n\nIf no window " ..
              "appeared, run this manually:\n  " .. cmd, "Setup running", 0)
    return true
  end
  return false
end

-- v0.6: zero-click bootstrap — when the engine venv is missing at panel
-- open (fresh install, or the first launch right after an Update that
-- shipped this app), start the one-time setup NOW in a terminal instead of
-- letting the first Run click fail with "venv not found". Non-interactive
-- (--auto): creates dubbing/venv, installs the engine deps and ffmpeg, no
-- prompts. Once per REAPER session (non-persistent ExtState) so a setup
-- already grinding away in a terminal is never launched twice. The panel
-- opens normally either way; Run's preflight still guards until it's done.
function V5.autorun_setup_if_needed()
  if PYTHON_CMD ~= "" then return end                 -- user pinned an interpreter
  -- A broken venv (its base Python was removed or upgraded) counts as
  -- missing: the --auto setup deletes and rebuilds it. Probe by executing,
  -- not just io.open (old REAPER builds without ExecProcess keep the
  -- existence check).
  local proj = project_venv_python()
  if file_exists(proj) and (not reaper.ExecProcess
                            or probe_python('"' .. proj .. '"')) then return end
  if APP_DIR ~= "" and file_exists(venv_python_path()) then return end
  if reaper.GetExtState("dub_pipeline", "setup_autorun") == "1" then return end
  local script = BASE_DIR .. SEP .. SETUP_SCRIPT
  if not file_exists(script) then return end
  reaper.SetExtState("dub_pipeline", "setup_autorun", "1", false)
  V5.run_in_terminal(script, "--auto")
  reaper.MB(
    "Automatic setup has started in a separate terminal window.\n\n" ..
    "It installs (or repairs) the dubbing engine's Python packages\n" ..
    "and ffmpeg automatically (takes a few minutes, one time only).\n\n" ..
    "You can keep using this panel — the Sync tab works right\n" ..
    "away. When the terminal says 'Setup complete', the Dub tab\n" ..
    "is ready too.",
    "Dub Pipeline — automatic setup", 0)
end

-- v0.5: load the fast-syncs Auto Sync pipeline as an EMBEDDED module, so it
-- renders inside this window's "Auto Sync" tab instead of its own window.
-- auto_sync_pipeline.lua lives in the fast-syncs root (V5.FS_ROOT) next to
-- run_sync.py + the sync venv, which is exactly where it needs to run from.
-- The __FASTSYNC_EMBED flag makes it return a module (render/poll) rather
-- than opening a window. dofile gives it its own Lua chunk (fresh local
-- budget), and it shares THIS panel's ImGui context via render(ctx).
V5.sync_path = V5.FS_ROOT .. SEP .. "auto_sync_pipeline.lua"
V5.SYNC = nil
V5.sync_err = nil
V5.sync_tried = false
function V5.load_sync()
  if V5.sync_tried then return end
  V5.sync_tried = true
  if not file_exists(V5.sync_path) then
    V5.sync_err = "auto_sync_pipeline.lua was not found at:\n" ..
                  V5.sync_path .. "\n\nThe Sync tab needs the fast-syncs " ..
                  "install (this dubbing app lives in its dubbing/ subfolder). " ..
                  "If you installed dubbing standalone, run the Auto Sync tool " ..
                  "from its own action instead."
    return
  end
  rawset(_G, "__FASTSYNC_EMBED", true)
  local ok, mod = pcall(dofile, V5.sync_path)
  rawset(_G, "__FASTSYNC_EMBED", nil)
  if ok and type(mod) == "table" and mod.render then
    V5.SYNC = mod
  else
    V5.sync_err = "Could not load the Auto Sync module:\n" .. tostring(mod)
  end
end
V5.load_sync()

-- Shared pre-launch checks for EVERY engine invocation (full/staged runs,
-- dub resume, chunk regen). Returns the interpreter path on success; nil
-- after setting an error banner otherwise. Also removes stale status files
-- so the poller only ever sees markers from the run about to start.
-- *need_llm*: this launch will call the translation LLM (full/translate/dub —
-- dub still needs the mapping call). Passed only by those sites, so
-- --test-llm keeps running with broken credentials (reporting on them is its
-- job) and the LLM-free modes (--regen, --voice-change) are never blocked.
local function preflight_engine(need_llm)
  -- v0.21: refused HERE, not at launch — the last thing this function does is
  -- delete the status files, which a quiet job in flight (the voice fetch) is
  -- still being polled from. Its buttons are disabled while it runs; this is
  -- the guard for every path that is not a button.
  if V5.quiet_job then
    ui_set_banner("warn",
      "Still fetching the ElevenLabs voices — try again in a moment.")
    return nil
  end

  -- v0.5: re-resolve the per-project status dir for the ACTIVE project when
  -- starting fresh from setup. Review-continue and other mid-run launches
  -- keep the dir their run started with, even if the user switched REAPER
  -- project tabs in between.
  if _ui_phase == "setup" then V5.set_status_paths() end

  -- The engine reads every key/setting from config/*.json — sync them with
  -- the current UI values before any launch (keys never travel on argv).
  local okc, cpath = save_config_files()
  if not okc then
    ui_set_banner("error", "Could not write settings file:\n" .. tostring(cpath))
    return nil
  end

  -- Checked AFTER the save, so a key recovered from disk by
  -- V5.keep_stored_credentials() counts. Refusing here costs nothing; the same
  -- gap found by the engine costs the Scribe transcription first, because a
  -- dub run's first LLM call is S2a.
  if need_llm then
    local why = V5.llm_creds_error()
    if why then
      ui_set_banner("error",
        "This run needs the translation LLM, but its credentials are " ..
        "incomplete:\n" .. why ..
        "\n\nFix it in the settings window (⚙ in the header), then press " ..
        "'Test connection'.")
      return nil
    end
  end

  if not file_exists(RUN_DUB_PY) then
    ui_set_banner("error",
      "engine/run_dub.py not found at:\n" .. RUN_DUB_PY ..
      "\n\nThis script must live in the project's reaper/ folder, " ..
      "next to the engine/ folder.")
    return nil
  end
  -- The pipeline only works on a venv interpreter with the engine deps
  -- installed. Falling back to a system python silently produces either a
  -- raw ModuleNotFoundError or — CLT stub — a GUI dialog behind REAPER and
  -- an empty log. Refuse with actionable guidance instead, unless the user
  -- explicitly pinned an interpreter override.
  local proj_py   = project_venv_python()
  local legacy_py = (APP_DIR ~= "") and venv_python_path() or ""
  if PYTHON_CMD == "" and not file_exists(proj_py)
     and not (legacy_py ~= "" and file_exists(legacy_py)) then
    ui_set_banner("error",
      "Project venv not found at:\n" .. proj_py ..
      "\n\nRun " .. SETUP_SCRIPT .. " once (it creates venv/ and installs " ..
      "the engine dependencies), or set a Python override in Settings.")
    -- v0.5: offer to run the setup script right now (fast-syncs pattern).
    V5.offer_run_setup("The dubbing engine's Python venv was not found at:\n"
                       .. proj_py)
    return nil
  end

  local py = find_python()
  if not py then
    ui_set_banner("error",
      "No Python interpreter found. Expected the project venv at:\n" ..
      proj_py ..
      "\n\nRun " .. SETUP_SCRIPT .. " once, or set a Python override below.")
    return nil
  end

  -- The venv interpreter can exist on disk yet be broken (its base Python
  -- was uninstalled or upgraded) — the engine would then die instantly and
  -- the run only fail via the 90 s watchdog. Probe by EXECUTING it and
  -- offer the rebuild right away instead.
  if PYTHON_CMD == "" and reaper.ExecProcess
     and (py == proj_py or (legacy_py ~= "" and py == legacy_py))
     and not probe_python('"' .. py .. '"') then
    ui_set_banner("error",
      "The engine's Python venv is broken — its Python was removed or " ..
      "upgraded. Run " .. SETUP_SCRIPT .. " to rebuild it.")
    V5.offer_run_setup("The dubbing engine's venv exists but its Python " ..
      "no longer runs (removed or upgraded).\nSetup will rebuild it.")
    return nil
  end

  -- A previous engine run may still be alive (panel closed mid-run keeps the
  -- engine going on purpose, and the 90s watchdog's "Back to setup" never
  -- kills it). Its run_dub.py owns the SAME status paths: when its worker
  -- exits it removes engine_pid.txt (breaking this run's Cancel) and writes
  -- engine_done.txt/json, finishing this run's poller with the wrong exit
  -- code and manifest. Never launch while the old worker is still alive.
  local prev = read_all(PID_PATH)
  local prev_pid = prev and prev:match("(%d+)")
  if prev_pid then
    -- Identity-checked, not just kill -0: a stale engine_pid.txt (launcher
    -- SIGKILLed / crash / logout) plus PID recycling would otherwise make
    -- this guard refuse forever on an unrelated process.
    if pid_is_engine(prev_pid) then
      ui_set_banner("error",
        "A previous dub run is still in progress (worker pid " .. prev_pid ..
        ") — Cancel it first, or wait for it to finish before starting " ..
        "a new run.")
      return nil
    end
    -- Stale pid file from a crashed run: drop it and proceed.
    os.remove(PID_PATH)
  end

  -- The old launcher can outlive its worker for a moment: run_dub.py deletes
  -- engine_pid.txt BEFORE writing engine_done.txt, so launching in that gap
  -- would hand this run's poller the OLD run's done marker + manifest.
  -- Refuse while a launcher for THIS project's status dir is still alive.
  -- (v0.5: scoped per status dir — a run for a DIFFERENT project in another
  -- REAPER instance writes elsewhere and must not block this launch.)
  if not _is_windows() then
    local probe = 'ps -axo command 2>/dev/null | grep -F run_dub.py | ' ..
                  'grep -F -- ' .. shellquote('--status-dir ' .. STATUS_DIR) ..
                  ' | grep -v grep'
    local fh = io.popen(probe)
    local out = fh and fh:read("*a") or ""
    if fh then fh:close() end
    if out:match("%S") then
      ui_set_banner("error",
        "A previous dub run is still shutting down — wait a moment, then " ..
        "try again.")
      return nil
    end
  end

  -- Remove stale status files so the poller can't read a previous run's
  -- markers in the moment before run_dub.py recreates the status dir.
  os.remove(DONE_PATH)
  os.remove(DONE_JSON)
  os.remove(PID_PATH)
  os.remove(LOG_PATH)

  return py
end

-- Launch run_dub.py non-blocking and switch the UI to the running phase.
-- run_dub.py owns log/pid/done from here on. `mode` (full | translate |
-- dub | regen) drives the stage checklist and the finish handling.
-- Returns true when the engine launched; false (with a banner) otherwise.
-- v0.21: *quiet* launches the job without entering the run phase — see
-- V5.quiet_job. Only the voice fetch uses it.
local function launch_engine(cmd, mode, header_lines, quiet)
  -- A quiet job owns the same status/ files as any other run; a second launch
  -- on top of it would read the first one's log and done marker. (A real run
  -- is already blocked by the running phase and preflight_engine's pid check.)
  if V5.quiet_job then
    ui_set_banner("warn",
      "Still fetching the ElevenLabs voices — try again in a moment.")
    return false
  end

  -- v0.5: remember which project this run belongs to, so Import can switch
  -- back to it if the user changed REAPER project tabs mid-run.
  V5.run_project = reaper.EnumProjects(-1, "")
  _log_buffer = {}
  for _, l in ipairs(header_lines or {}) do log_append(l) end
  log_append("[panel] Launch : " .. cmd)
  log_append("")

  if _is_windows() then
    if reaper.ExecProcess then
      local ret = reaper.ExecProcess(cmd, -2)
      if ret == nil then
        ui_set_banner("error",
          "Could not launch Python. Check the interpreter path.")
        return false
      end
    else
      os.execute('start "" /b ' .. cmd)
    end
  else
    os.execute(cmd .. ' >/dev/null 2>&1 &')
  end

  _run_mode        = mode
  _ui_stage_tag    = nil
  _ui_progress     = 0.02
  _ui_cancelled    = false
  _cancel_pending  = false
  if not UTIL_MODES[mode] then
    -- A fresh run invalidates the previous run's results and any pending
    -- review. Utility modes (regen, test_llm, list_voices) keep them: they
    -- report back into the phase they came from.
    _manifest        = nil
    _import_summary  = nil
    _imported        = false
    _review          = nil
    _resume_manifest = nil
  end
  _poll_last_size  = 0
  _poll_partial    = ""
  _poll_start_time = os.time()
  if quiet then
    -- The panel stays exactly where it is. poll_engine still runs every
    -- frame — the frame loop polls whenever a quiet job is out.
    V5.quiet_job = mode
  else
    _ui_phase    = "running"
  end
  return true
end

-- v0.4: write the pasted translation where the engine's own outputs live.
-- Mirrors pipeline/config._prepare_output_dir: outputs go to a sibling
-- folder named after the audio file (reused when the audio already sits
-- inside its own output folder). Returns the file path, or nil + banner.
local function write_provided_script(audio, text)
  local adir = dirname(audio)
  local base = basename(audio):gsub("%.[^.]+$", "")
  local out_dir
  if basename(adir) == base then
    out_dir = adir
  else
    out_dir = adir .. SEP .. base
    reaper.RecursiveCreateDirectory(out_dir, 0)
  end
  local path = out_dir .. SEP .. base .. "_provided_translation.txt"
  local f = io.open(path, "wb")
  if not f then
    ui_set_banner("error",
      "Could not write the provided translation to:\n" .. path)
    return nil
  end
  local body = text:gsub("\r\n", "\n")
  if body:sub(-1) ~= "\n" then body = body .. "\n" end
  f:write(body)
  f:close()
  return path
end

-- Called on "Run". Returns true when the engine launched and the UI should
-- switch to the running phase; false (with a banner) to stay on setup.
local function start_dub_run()
  ui_clear_banner()
  save_settings()

  local audio = LAST_AUDIO
  if audio and audio ~= "" then
    local base = audio:match("^.-([^\\/]+)%.[^\\/]+$")
    local out_dir = audio:match("^(.*)[\\/]")
    if out_dir and base then
      local edited_path = out_dir .. SEP .. base .. "_translation_edited.txt"
      os.remove(edited_path)
    end
  end
  if audio == "" then
    ui_set_banner("error", "Pick an English audio file first.")
    return false
  end
  if not file_exists(audio) then
    ui_set_banner("error", "Audio file not found:\n" .. audio)
    return false
  end

  -- v0.4 "I already have the translation": the pasted script replaces the
  -- LLM translation chain (the engine still transcribes for sync timings).
  local provided_path = nil
  if SCRIPT_MODE == "have" then
    if not (_provided_text or ""):match("%S") then
      ui_set_banner("error",
        "Script is set to 'I have a script' — paste the translated script " ..
        "first (or switch Script back to 'Translate with AI').")
      return false
    end
    provided_path = write_provided_script(audio, _provided_text)
    if not provided_path then return false end
  end

  local py = preflight_engine(true)
  if not py then return false end

  -- v0.2 default is the staged run: pause after translation for review.
  local steps = FULL_RUN and "full" or "translate"
  local cmd = build_engine_cmd(py, {
    audio = audio, language = LANGUAGE, steps = steps,
    provided_script = provided_path,
  })
  local header = {
    "[panel] Python : " .. py,
    "[panel] Audio  : " .. audio,
    "[panel] Lang   : " .. LANGUAGE,
    "[panel] Steps  : " .. steps,
  }
  if provided_path then
    header[#header + 1] = "[panel] Script : provided by user — " ..
                          provided_path
  end
  return launch_engine(cmd, steps, header)
end

-- ─── v0.13 pause-aware sync ───────────────────────────────────────────────
-- "Preview sync": lay the pasted target script across the pauses the source
-- audio actually has, and report the fit. Free — the only network call is
-- the transcription, and that is cached on disk, so Reload costs nothing.
-- V5 functions, not locals: the main chunk is at Lua's 200-local limit.

-- *reuse_script_path*: the pasted-script file a previous run wrote, so a
-- Reload needs no re-paste. *plan_path*: a plan file whose TR: lines are
-- already assigned per chunk — when given, the engine re-measures THOSE
-- lines instead of re-spreading the script, which is what makes a review
-- survive a reload (v0.15; before this, every correction was silently
-- discarded the moment you pressed ⟲).
function V5.start_plan_run(reuse_script_path, plan_path)
  ui_clear_banner()
  save_settings()

  local audio = LAST_AUDIO
  if audio == "" then
    ui_set_banner("error", "Pick the source audio file first.")
    return false
  end
  if not file_exists(audio) then
    ui_set_banner("error", "Audio file not found:\n" .. audio)
    return false
  end

  -- The target script travels by file, never on argv (Indic text on a
  -- command line does not survive the Windows console codepage). A Reload
  -- reuses the file the first run wrote instead of demanding a re-paste.
  local script_path = reuse_script_path
  if not plan_path and not script_path then
    if not (_provided_text or ""):match("%S") then
      ui_set_banner("error",
        "Paste the target-language script first — Preview sync lays it " ..
        "across the pauses detected in the source audio.")
      return false
    end
    script_path = write_provided_script(audio, _provided_text)
    if not script_path then return false end
  end
  if plan_path and not file_exists(plan_path) then
    ui_set_banner("error", "Plan file not found:\n" .. plan_path)
    return false
  end

  local py = preflight_engine(false)
  if not py then return false end

  if script_path then V5.plan_script_path = script_path end
  local cmd = build_engine_cmd(py, {
    audio = audio, language = LANGUAGE, steps = "plan",
    provided_script = (not plan_path) and script_path or nil,
    plan = plan_path,
  })
  return launch_engine(cmd, "plan", {
    "[panel] Python : " .. py,
    "[panel] Audio  : " .. audio,
    "[panel] Lang   : " .. LANGUAGE,
    "[panel] Mode   : pause-aware preview (--steps plan) — no TTS, no LLM, " ..
      "no credits",
    plan_path and ("[panel] Plan   : " .. plan_path .. "  (re-measuring the " ..
                   "corrected TR: lines)")
              or  ("[panel] Script : " .. tostring(script_path)),
  })
end

-- "Approve & Generate": the ONLY paid step in this flow.
function V5.start_dubplan_run()
  ui_clear_banner()
  if not (V5.plan and V5.plan.plan_path) then
    ui_set_banner("error", "No sync plan loaded.")
    return false
  end
  if not file_exists(V5.plan.plan_path) then
    ui_set_banner("error", "Plan file not found:\n" .. V5.plan.plan_path)
    return false
  end
  local audio = (V5.plan.manifest and V5.plan.manifest.audio) or LAST_AUDIO
  local lang  = (V5.plan.manifest and V5.plan.manifest.language) or LANGUAGE
  if audio == "" or not file_exists(audio) then
    ui_set_banner("error", "Source audio not found:\n" .. tostring(audio))
    return false
  end

  local py = preflight_engine(false)
  if not py then return false end

  local cmd = build_engine_cmd(py, {
    audio = audio, language = lang, steps = "dubplan",
    plan = V5.plan.plan_path,
  })
  return launch_engine(cmd, "dubplan", {
    "[panel] Python : " .. py,
    "[panel] Audio  : " .. audio,
    "[panel] Lang   : " .. lang,
    "[panel] Mode   : generate from approved plan (--steps dubplan)",
    "[panel] Plan   : " .. V5.plan.plan_path,
  })
end

-- v0.3: "Test connection" — write the config files (the engine reads keys
-- from there), then run --test-llm through the normal launch/poll mechanism.
local function start_test_llm()
  ui_clear_banner()
  save_settings()
  local py = preflight_engine()
  if not py then return false end
  local cmd = build_engine_cmd(py, { test_llm = true })
  _util_return_phase = _ui_phase
  return launch_engine(cmd, "test_llm", {
    "[panel] Python : " .. py,
    "[panel] Mode   : test LLM connection (--test-llm)",
  })
end

-- v0.3: "Fetch voices" — --list-voices for the current language; the result
-- manifest's voices[] fills every voice combo.
-- v0.21: launched QUIET. Reading a voice catalogue is not a run: it must not
-- move the panel off the tool you pressed the button on, and a fetch that
-- fails must not leave the Dub screen sitting on a failure page. The button
-- spins in place and the banner beside it reports the outcome.
local function start_fetch_voices()
  ui_clear_banner()
  save_settings()
  local py = preflight_engine()
  if not py then return false end
  local cmd = build_engine_cmd(py, { list_voices = true, language = LANGUAGE })
  _util_return_phase = _ui_phase
  return launch_engine(cmd, "list_voices", {
    "[panel] Python : " .. py,
    "[panel] Mode   : list ElevenLabs voices (--list-voices)",
    "[panel] Lang   : " .. LANGUAGE,
  }, true)
end

-- ---------------------------------------------------------------------------
-- Review helpers — staged run paused between translation and dubbing
-- ---------------------------------------------------------------------------

local function _strip_bom(s)
  if s:sub(1, 3) == "\239\187\191" then return s:sub(4) end
  return s
end

-- Split a review text file into paragraphs: blocks separated by one or more
-- blank lines (contract format). Byte-safe for UTF-8 Indic text.
local function split_paragraphs(text)
  text = _strip_bom(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local paras, buf = {}, {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:match("^%s*$") then
      if #buf > 0 then
        paras[#paras + 1] = table.concat(buf, "\n")
        buf = {}
      end
    else
      buf[#buf + 1] = line
    end
  end
  if #buf > 0 then paras[#paras + 1] = table.concat(buf, "\n") end
  return paras
end

-- ═══════════════════════════════════════════════════════════
-- SCRIPT BOX — the fields whose CONTENT has to be readable
-- ═══════════════════════════════════════════════════════════
-- ImGui's multiline InputText cannot word-wrap (upstream dear-imgui #952): a
-- pasted paragraph is drawn as one endless line that scrolls off the right
-- edge — exactly the wrong behaviour for the fields you paste a whole script
-- into. So this is a plain text box that keeps itself wrapped: see
-- V5.wrap_soft below for how, and nothing else changes about it. Paste/Clear
-- used to be bare SmallButtons landing on top of the input frame; here they
-- sit in a toolbar above it.
V5.script_box_state = {}     -- id -> { buf, src, w, active }

-- Characters, not bytes. '#s' over Devanagari reports roughly three times the
-- truth, which made the counter under the box read like nonsense.
function V5.char_count(s)
  s = tostring(s or "")
  if utf8 and utf8.len then
    local n = utf8.len(s)
    if n then return n end
  end
  local n = 0
  for _ in s:gmatch("[^\128-\191]") do n = n + 1 end
  return n
end

-- ─── v0.18 estimates ────────────────────────────────────────────────────────
-- How long a piece of text will take to say, and what it will cost. Both are
-- ESTIMATES made locally — no API call, nothing to wait for — and both exist
-- for the same reason: the panel used to ask you to spend credits and timeline
-- space with no idea of how much of either.
--
-- 15 characters per second is what these dubs actually come out at across the
-- Indic languages and English. Where a better number is available it is used
-- instead: a dub chunk knows its own speaker's real rate (its text length over
-- its slot length), which is far more accurate than any global constant.
V5.SPEECH_CPS = 15

function V5.speech_secs(text, cps)
  return V5.char_count(text) / math.max(1, cps or V5.SPEECH_CPS)
end

-- ElevenLabs bills per character on the models this app uses. Shown as "~" and
-- never as money: the credit-to-currency rate depends on the user's plan.
function V5.credit_est(text)
  return V5.char_count(text)
end

-- 8 → "8 s", 95 → "1:35". Durations here are either seconds-small or
-- minutes-long, and a bare "95 s" reads worse than either.
function V5.fmt_dur(sec)
  sec = tonumber(sec) or 0
  if sec < 60 then
    return string.format('%.0f s', sec + 0.5 >= 1 and sec or 1)
  end
  return string.format('%d:%02d', math.floor(sec / 60), math.floor(sec % 60))
end

-- Timeline position, the way REAPER's own transport writes it.
function V5.fmt_pos(sec)
  sec = math.max(0, tonumber(sec) or 0)
  return string.format('%d:%02d:%06.3f', math.floor(sec / 3600),
                       math.floor(sec / 60) % 60, sec % 60)
end

-- Soft wrapping for the EDIT state. ImGui's text box will not wrap, so the
-- only way to see a long paragraph while editing it is to put real newlines
-- in — and the only way to do that without quietly rewriting the script is to
-- mark the breaks we inserted. The mark is a zero-width space: invisible, not
-- something anyone types, and stripped again by V5.unwrap_soft. Line breaks
-- YOU typed carry no mark and survive untouched.
V5.ZWSP = "\226\128\139"
-- ...and a second mark for a break made INSIDE a word (a path too long for
-- the box). That one has to unwrap to nothing, not to a space, or the word
-- comes back with a hole in it.
V5.WJ   = "\226\129\160"

-- Codepoints that carry no advance of their own: combining marks, the Indic
-- matras that sit above or below their base consonant, and the invisible
-- formatting characters. They are counted OUT of the character estimate
-- below — a Devanagari paragraph has roughly one of these per two letters,
-- so counting codepoints makes it measure a third wider than it draws.
V5.ZERO_W = {
  {0x0300,0x036F},                                            -- Latin marks
  {0x0483,0x0489},
  {0x0591,0x05BD},{0x05BF,0x05BF},{0x05C1,0x05C2},            -- Hebrew
  {0x05C4,0x05C5},{0x05C7,0x05C7},
  {0x0610,0x061A},{0x064B,0x065F},{0x0670,0x0670},            -- Arabic
  {0x06D6,0x06DC},{0x06DF,0x06E4},{0x06E7,0x06E8},{0x06EA,0x06ED},
  {0x0900,0x0902},{0x093A,0x093A},{0x093C,0x093C},            -- Devanagari
  {0x0941,0x0948},{0x094D,0x094D},{0x0951,0x0957},{0x0962,0x0963},
  {0x0981,0x0981},{0x09BC,0x09BC},{0x09C1,0x09C4},            -- Bengali
  {0x09CD,0x09CD},{0x09E2,0x09E3},
  {0x0A01,0x0A02},{0x0A3C,0x0A3C},{0x0A41,0x0A51},            -- Gurmukhi
  {0x0A70,0x0A71},{0x0A75,0x0A75},
  {0x0A81,0x0A82},{0x0ABC,0x0ABC},{0x0AC1,0x0AC8},{0x0ACD,0x0ACD},  -- Gujarati
  {0x0B01,0x0B01},{0x0B3C,0x0B3C},{0x0B3F,0x0B3F},            -- Odia
  {0x0B41,0x0B44},{0x0B4D,0x0B56},
  {0x0B82,0x0B82},{0x0BC0,0x0BC0},{0x0BCD,0x0BCD},            -- Tamil
  {0x0C00,0x0C00},{0x0C3E,0x0C40},{0x0C46,0x0C56},            -- Telugu
  {0x0C81,0x0C81},{0x0CBC,0x0CBC},{0x0CBF,0x0CBF},            -- Kannada
  {0x0CC6,0x0CC6},{0x0CCC,0x0CCD},
  {0x0D01,0x0D01},{0x0D41,0x0D44},{0x0D4D,0x0D4D},            -- Malayalam
  {0x200B,0x200F},{0x2060,0x2064},{0xFE00,0xFE0F},            -- invisibles
}

function V5.is_zero_w(cp)
  for _, r in ipairs(V5.ZERO_W) do
    if cp >= r[1] and cp <= r[2] then return true end
  end
  return false
end

-- One UTF-8 character at a time, zero-width marks kept attached to the base
-- character they belong to. Breaking between the two would split a
-- Devanagari cluster and draw a dotted-circle placeholder.
V5.UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"
function V5.clusters(s)
  local out = {}
  for ch in tostring(s or ""):gmatch(V5.UTF8_CHAR) do
    local cp = (utf8 and utf8.codepoint) and (select(2, pcall(utf8.codepoint, ch)))
    if #out > 0 and type(cp) == "number" and V5.is_zero_w(cp) then
      out[#out] = out[#out] .. ch
    else
      out[#out + 1] = ch
    end
  end
  return out
end

-- How many advancing characters *s* draws as. Not #s (bytes) and not
-- utf8.len (codepoints) — see V5.ZERO_W.
function V5.cells(s)
  return #V5.clusters(s)
end

-- Text measurement that admits when it has failed. ReaImGui rasterizes
-- glyphs on demand, so CalcTextSize over a script whose glyphs are not in
-- the atlas yet answers 0 — and a wrapper that believes that answer decides
-- every line fits and produces exactly one endless line, which is the bug
-- this whole box exists to avoid. Returns nil instead of a bogus width.
function V5.measure(ctx, s)
  local ok, w = pcall(reaper.ImGui_CalcTextSize, ctx, s)
  if ok and type(w) == "number" and w > 0 then return w end
  return nil
end

-- Returns the wrapped text and whether any width had to be ESTIMATED. The
-- caller re-flows while that flag is set, so a box wrapped from estimates on
-- the frame the font was attached tightens up once the atlas catches up.
function V5.wrap_soft(ctx, text, px)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
                             :gsub(V5.ZWSP, ""):gsub(V5.WJ, "")
  if px <= 40 then return text, false end

  -- Average advance of an ASCII character. ASCII is in the atlas from the
  -- first frame, so this probe answers even when the script's own glyphs do
  -- not. Indic and CJK draw wider than lowercase Latin, hence the 1.3 — and
  -- erring wide is the safe direction: a line estimated short merely leaves
  -- a gap, a line estimated long runs off the edge, which is the whole bug.
  local probe = 'the quick brown fox jumps over a lazy dog'
  local avg = V5.measure(ctx, probe)
  avg = (avg and (avg / V5.cells(probe)) or 8) * 1.3
  local sp = V5.measure(ctx, ' ') or (avg * 0.5)
  local est = false

  -- A drawn glyph is never narrower than about 1.5 px. A run measuring less
  -- than that per character means the atlas answered for glyphs it has not
  -- rasterized — fall back to the character estimate for that word.
  local function width_of(word)
    local cells = V5.cells(word)
    local w = V5.measure(ctx, word)
    if w and w >= cells * 1.5 then return w end
    est = true
    return cells * avg
  end

  -- A single word wider than the whole box — a long path, a URL, a run of
  -- CJK with no spaces in it — has no space to break at, so break it
  -- between characters instead. Without this one word still runs off the
  -- right edge no matter how well the rest wraps.
  local function split_long(word, ww)
    if ww <= px then return { word } end
    local pieces, cur, cur_w = {}, "", 0
    for _, ch in ipairs(V5.clusters(word)) do
      local cw = width_of(ch)
      if cur ~= "" and cur_w + cw > px then
        pieces[#pieces + 1] = cur
        cur, cur_w = ch, cw
      else
        cur, cur_w = cur .. ch, cur_w + cw
      end
    end
    if cur ~= "" then pieces[#pieces + 1] = cur end
    return pieces
  end

  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:match("^%s*$") then
      out[#out + 1] = ""
    else
      local cur, cur_w = nil, 0
      for word in line:gmatch("%S+") do
        local parts = split_long(word, width_of(word))
        for pi, part in ipairs(parts) do
          local ww = width_of(part)
          -- Pieces of a split word rejoin with no space between them, so
          -- only the first piece may share a line with what came before.
          if not cur then
            cur, cur_w = part, ww
          elseif pi > 1 then
            out[#out + 1] = cur .. V5.WJ      -- mid-word: no space to restore
            cur, cur_w = part, ww
          elseif cur_w + sp + ww > px then
            out[#out + 1] = cur .. V5.ZWSP    -- a break we own
            cur, cur_w = part, ww
          else
            cur, cur_w = cur .. " " .. part, cur_w + sp + ww
          end
        end
      end
      out[#out + 1] = cur or ""
    end
  end
  return table.concat(out, "\n"), est
end

function V5.unwrap_soft(s)
  s = tostring(s or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  s = s:gsub(V5.WJ   .. "\n", "")    -- mid-word break — close it up
  s = s:gsub(V5.ZWSP .. "\n", " ")   -- our break — put the space back
  s = s:gsub(V5.WJ, "")
  return (s:gsub(V5.ZWSP, ""))       -- stragglers left by editing
end

-- ── v0.26 rows that wrap instead of clipping ───────────────────────────────
-- Every fixed-width button row in the panel was a chain of SameLine calls
-- adding up to a number nobody re-checked against the window: the review
-- screen's five buttons came to 662 px and the prompt editor's three to 394,
-- so a panel dragged narrower than that cut the last of them in half. There is
-- no ImGui flag for this — a row wraps only if something decides it does.
--
-- Call V5.wrap_begin once, then V5.wrap_next(ctx, w) BEFORE each item: it
-- either puts the cursor back on the current line or leaves it on the next
-- one. Widths are what the item will actually take, so a caller that lets
-- ImGui size a button passes V5.btn_w(ctx, label).
-- Room left on the current row, stopping at the grid cell's right edge when
-- there is one. Everything that sizes itself horizontally goes through this.
function V5.room(ctx, dflt)
  local a = reaper.ImGui_GetContentRegionAvail(ctx)
  a = (type(a) == 'number' and a > 0) and a or (dflt or 400)
  if V5.cell_x and V5.grid_w then
    local x = reaper.ImGui_GetCursorPosX and reaper.ImGui_GetCursorPosX(ctx) or 0
    a = math.min(a, math.max(40, V5.cell_x + V5.grid_w - x))
  end
  return a
end

function V5.wrap_begin(ctx, gap)
  V5.wr = { pen = 0, gap = gap or 6, first = true, avail = V5.room(ctx, 400),
            x = reaper.ImGui_GetCursorPosX and reaper.ImGui_GetCursorPosX(ctx) or 0 }
end

function V5.wrap_next(ctx, w)
  local W = V5.wr
  if not W then return end
  w = w or 80
  if W.first then
    W.first, W.pen = false, w
  elseif W.pen + W.gap + w <= W.avail then
    reaper.ImGui_SameLine(ctx, 0, W.gap)
    W.pen = W.pen + W.gap + w
  else
    -- New line — and back to the x this row STARTED at. ImGui's own next-line x
    -- is the window's left margin, which after a label column (and inside a
    -- grid cell) is not where the row began: a wrapped segment landed at the
    -- far left, on top of whatever the neighbouring cell had drawn there.
    if reaper.ImGui_SetCursorPosX then reaper.ImGui_SetCursorPosX(ctx, W.x) end
    W.pen = w
  end
end

function V5.wrap_end() V5.wr = nil end

-- What ImGui will make a default-sized button, so a wrapping row can budget
-- for one without hard-coding a width that the face decides.
function V5.btn_w(ctx, label)
  return V5.text_w(ctx, label, 8) + 18
end

-- How wide V5.chip draws *label*, so a wrapping row can budget for it.
function V5.chip_w(ctx, label)
  return V5.text_w(ctx, label, 8) + 22
end

-- Flat toolbar button. Quieter than ImGui's default blue Button and far more
-- legible than SmallButton, which has no padding at all.
function V5.chip(ctx, label, tip, danger)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
                              danger and 0x3E2A2EFF or 0x2A313DFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),
                              danger and 0x5C3239FF or 0x3B4655FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),
                              danger and 0x6E3941FF or 0x4B5768FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                              danger and 0xE2A2AAFF or 0xC6D0DEFF)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 5.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 11.0, 4.0)
  -- Sized explicitly, like V5.segmented and for the same reason: a chip row is
  -- usually the FIRST thing after a stacked field's caption, and a pending
  -- SetNextItemWidth belongs to the next widget — so 'Paste' would take the
  -- whole row's width and push 'Clear' out of it.
  local hit = reaper.ImGui_Button(ctx, label, V5.chip_w(ctx, label), 0)
  reaper.ImGui_PopStyleVar(ctx, 2)
  reaper.ImGui_PopStyleColor(ctx, 4)
  if tip and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(tip))
  end
  return hit
end

-- A multiline box that keeps itself wrapped. The review editor has one of
-- these per paragraph and the script boxes wrap one in a toolbar, so this is
-- the piece both share. *pad* is how much of the available width the frame
-- and a possible scrollbar take. Returns the (possibly edited) text and
-- whether this frame changed it.
-- *px* (v0.29) is the text size, because the review screen lets you choose it
-- and the soft wrap below is measured in whatever face is pushed here — a box
-- flowed at 17 and drawn at 13 wraps two thirds of the way across.
function V5.wrapped_input(ctx, id, text, height, pad, px)
  text = text or ""
  local st = V5.script_box_state[id]
  if not st then st = {}; V5.script_box_state[id] = st end

  local pushed = _push_font(ctx, px or 17)

  -- st.buf is the wrapped copy the box actually shows; *text* stays canonical.
  -- Re-flowed when the text arrives from outside (paste, load), when the panel
  -- is resized, and the moment you stop typing — but never mid-keystroke,
  -- which would drag the caret around under your hands.
  local box_w = (reaper.ImGui_GetContentRegionAvail(ctx) or 0) - (pad or 44)
  local reflow = (not st.buf) or math.abs((st.w or 0) - box_w) > 2
                 or st.px ~= (px or 17)
  if not reflow and st.src ~= text then
    -- Changed since the last flow: a paste is a big jump and re-flows at
    -- once; ordinary typing waits until the box loses focus.
    reflow = (not st.active) or math.abs(#text - #(st.src or "")) > 8
  end
  -- The last flow had to estimate widths because the atlas had not
  -- rasterized this script yet (V5.wrap_soft's second return). Keep trying —
  -- but never while the caret is in the box — so the wrap tightens up on the
  -- first frame the font can actually be measured.
  if not reflow and st.est and not st.active then reflow = true end
  if reflow then
    st.buf, st.est = V5.wrap_soft(ctx, text, box_w)
    st.src = text
    st.w   = box_w
    st.px  = px or 17
  end

  local rv, typed = reaper.ImGui_InputTextMultiline(
    ctx, '##' .. id, st.buf, -1, height)
  if pushed then _pop_font(ctx) end
  if rv then
    st.buf = typed
    text   = V5.unwrap_soft(typed)
    -- st.src deliberately keeps the last FLOWED text, not this one: that
    -- difference is what tells the block above to re-flow once you stop.
  end
  st.active = reaper.ImGui_IsItemActive and reaper.ImGui_IsItemActive(ctx)
  return text, rv
end

-- The widget: one text box you paste into, wrapped to its own width, plus the
-- two buttons that were already there. *id* must be unique per call site;
-- returns the (possibly edited) text. *opts*:
--   height   MINIMUM box height in px (default 150) — see below
--   max      ceiling for the grown height (default 520)
--   frac     share of the window height to aim for (default 0.42)
--   fixed    true to use *height* verbatim and ignore the window
--   fill     v0.23: take the height LEFT in this column instead of a share of
--            the window, so the box ends on the bottom edge and nothing
--            around it needs a scrollbar. Overrides height/frac/max.
--   min      floor for fill mode (default 120)
--   reserve  px of fill height to leave for something drawn after the box
--   paras    false to count characters only (plain prose, e.g. TTS)
function V5.script_box(ctx, id, text, opts)
  opts = opts or {}
  text = text or ""

  -- The box takes a share of whatever height the panel has, so making the
  -- window taller shows more of the script instead of more empty chrome.
  -- opts.height is the floor, not the answer.
  local height = opts.height or 150
  if not opts.fixed and reaper.ImGui_GetWindowHeight then
    local ok, wh = pcall(reaper.ImGui_GetWindowHeight, ctx)
    if ok and type(wh) == "number" and wh > 0 then
      height = math.max(height,
                        math.min(opts.max or 520,
                                 math.floor(wh * (opts.frac or 0.42))))
    end
  end

  local st = V5.script_box_state[id]
  if not st then st = {}; V5.script_box_state[id] = st end

  local empty = (text:match("%S") == nil)

  -- ── Toolbar ──────────────────────────────────────────────────
  local row_x = reaper.ImGui_GetCursorPosX(ctx)
  local row_w = reaper.ImGui_GetContentRegionAvail(ctx)

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 6.0, 6.0)

  if V5.chip(ctx, 'Paste##' .. id .. 'pst',
             'Replace the box with the clipboard.') then
    local clip = reaper.ImGui_GetClipboardText and reaper.ImGui_GetClipboardText(ctx)
    if clip and clip:match("%S") then
      text, empty = clip, false
      st.buf = nil
    else
      ui_set_banner("warn", "The clipboard has no text to paste.")
    end
  end
  reaper.ImGui_SameLine(ctx)
  _ui_begin_disabled(ctx, empty)
  if V5.chip(ctx, 'Clear##' .. id .. 'clr', 'Empty the box.', true) then
    text, empty = "", true
    st.buf = nil
  end
  _ui_end_disabled(ctx)

  -- Counter, right-aligned so the toolbar reads controls-left / status-right.
  -- Two forms, because the long one is 190 px and this box is as narrow as the
  -- column it sits in — on the Dub screen's form at a 560 px window there is
  -- not room for it beside the chips, and it used to be drawn over them.
  local stats, brief
  if empty then
    stats, brief = 'empty', 'empty'
  elseif opts.paras == false then
    local n = V5.char_count(text)
    stats, brief = string.format('%d characters', n), string.format('%d ch', n)
  else
    local paras = split_paragraphs(text)
    local n     = V5.char_count(text)
    stats = string.format('%d paragraph%s  ·  %d characters',
                          #paras, #paras == 1 and '' or 's', n)
    brief = string.format('%d para, %d ch', #paras, n)
  end
  -- v0.26: measured through V5.text_w, and the "is there room" test asks the
  -- cursor AFTER a relative SameLine has put it back on this row.
  --
  -- Two bugs lived in the three lines this replaces. It was the only
  -- right-alignment in the panel to call CalcTextSize raw instead of the
  -- zero-guarded V5.text_w, and the string contains '·' — so an unrasterized
  -- middle dot answered 0 and put the counter's left edge exactly on the pane
  -- border. Worse, the guard compared stats_x against GetCursorPosX() taken
  -- straight after a button, which ImGui reports as the start of the NEXT
  -- line — very nearly 0. So the guard was true whatever the width, the
  -- absolute branch always ran, and on any narrow pane the counter was drawn
  -- on top of the Clear button.
  reaper.ImGui_SameLine(ctx)                 -- relative: back onto this row
  local at = reaper.ImGui_GetCursorPosX and reaper.ImGui_GetCursorPosX(ctx) or 0
  -- Pick the longest form that still fits after the chips; if even the brief
  -- one does not, the counter goes on its own line rather than off the edge.
  local tw, own_line = V5.text_w(ctx, stats, 8), false
  if at + 12 + tw > row_x + row_w then
    stats = brief
    tw    = V5.text_w(ctx, stats, 8)
    own_line = (at + 12 + tw > row_x + row_w)
  end
  local stats_x = row_x + row_w - tw
  if own_line then
    -- Its own row. NewLine ends the line the chips are on; the alignment has to
    -- be SetCursorPosX and NOT SameLine, because SameLine always returns to the
    -- PREVIOUS line — which would put the counter straight back on the chips.
    reaper.ImGui_NewLine(ctx)
    if reaper.ImGui_SetCursorPosX and stats_x > row_x then
      reaper.ImGui_SetCursorPosX(ctx, stats_x)
    end
  elseif stats_x > at + 12 then
    -- Only ever move it FURTHER right; otherwise leave it where the row put it.
    reaper.ImGui_SameLine(ctx, stats_x)
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                              empty and V5.COL.dimmer or V5.COL.dim)
  reaper.ImGui_Text(ctx, stats)
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_PopStyleVar(ctx)

  -- v0.23 fill mode: the box takes what is LEFT in this column rather than a
  -- share of the whole window. Measured HERE and not at the top of the
  -- function on purpose — by this line the toolbar row above has been drawn
  -- and its height is already out of the remaining total, so the box lands
  -- exactly on the bottom edge. This is what makes the box the only scrollbar
  -- on the screen: the window fraction could exceed what was left, which is
  -- what grew a second scrollbar on the body around it.
  if opts.fill then
    local _, avail_y = reaper.ImGui_GetContentRegionAvail(ctx)
    if type(avail_y) == "number" and avail_y > 0 then
      height = math.max(opts.min or 120,
                        math.floor(avail_y - (opts.reserve or 0)))
    else
      height = math.max(opts.min or 120, height)
    end
  end

  -- ── The box ──────────────────────────────────────────────────
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x161B24FF)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 3.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 10.0, 8.0)

  text = V5.wrapped_input(ctx, id, text, height, 44)

  reaper.ImGui_PopStyleVar(ctx, 2)
  reaper.ImGui_PopStyleColor(ctx)

  return text
end

-- v0.4: replace the whole review translation with *txt* (clipboard paste /
-- file reload). Keeps both editor representations in sync.
local function _review_replace_text(txt)
  if not _review then return end
  txt = _strip_bom(txt or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  _review.tr_paras  = split_paragraphs(txt)
  _review.tr_buffer = txt
  _review.dirty     = true
end

-- Output base name, for <out_dir>/<base>_translation_edited.txt. The EN SRT
-- is <base>.srt by contract; the input audio name is the fallback.
local function derive_base(m)
  local srt = m.en_srt or ""
  if srt ~= "" then
    local b = basename(srt):gsub("%.[sS][rR][tT]$", "")
    if b ~= "" then return b end
  end
  local audio = m.audio or ""
  if audio ~= "" then
    local b = basename(audio):gsub("%.[^.]+$", "")
    if b ~= "" then return b end
  end
  return "dub"
end

-- Load the review manifest's text files and switch to the review phase.
-- Returns true, or false + reason (the caller reports it).
local function enter_review_phase(m)
  local tr_raw = read_all(m.translation_text or "")
  if not tr_raw then
    return false, "The review manifest points at a translation file that " ..
                  "cannot be read:\n" .. (m.translation_text ~= "" and
                  m.translation_text or "(empty in manifest)")
  end
  -- A missing EN transcript is survivable: the right pane still works.
  local en_raw = read_all(m.en_text or "") or ""

  tr_raw = _strip_bom(tr_raw):gsub("\r\n", "\n"):gsub("\r", "\n")
  local base = derive_base(m)
  _review = {
    manifest    = m,
    en_paras    = split_paragraphs(en_raw),
    tr_paras    = split_paragraphs(tr_raw),
    tr_buffer   = tr_raw,               -- fallback editor (no-table ReaImGui)
    use_table   = reaper.ImGui_BeginTable ~= nil,
    base        = base,
    edited_path = (m.out_dir or "") .. SEP .. base .. "_translation_edited.txt",
    dirty       = false,
    sel         = 1,                    -- v0.29: the paragraph the inspector holds
    follow      = false,                -- v0.29: selection walks the play cursor
    time_off    = 0,                    -- project time of the audio's own 0:00
  }
  -- v0.29 preview sync: the English paragraphs came from cues in this run's own
  -- English SRT, so their times are recoverable — see V5.review_times. Computed
  -- ONCE here: the English side never changes on this screen, and the fit that
  -- does change (the target text) is measured every frame from these slots.
  local slots, total = V5.review_times(_review.en_paras, m.en_srt)
  _review.slots   = slots
  _review.total_s = total or 0
  _review.timed   = (slots ~= nil)
  -- Where that audio actually sits in THIS project, so "play here" lands on the
  -- paragraph rather than on the same offset from zero.
  V5.review_relink(_review)
  -- Remember (and persist) the run's out_dir for the regen section.
  V5.set_regen_target(m.out_dir, m.language)
  -- v0.7: reaching review is a resumable milestone — record it.
  V5.history_record("review", m)
  _ui_phase = "review"
  return true
end

-- v0.13: load a "status":"plan" manifest and switch to the plan phase — the
-- approval gate for the pause-aware flow. Mirrors enter_review_phase: a
-- phase-scoped state table, a renderer, and a continue button. Returns true,
-- or false + reason (the caller reports it).
function V5.enter_plan_phase(m)
  local plan_path = m.plan_txt or ""
  if plan_path == "" or not file_exists(plan_path) then
    return false, "the plan file is missing (" .. plan_path .. ")"
  end
  local rows = V5.parse_plan_file(plan_path)
  if #rows == 0 then
    return false, "the plan file has no chunks (" .. plan_path .. ")"
  end
  -- The strip's time axis. Measured from the rows rather than the manifest
  -- so it can never disagree with the bars drawn from those same rows.
  local total_s = 1.0
  for _, r in ipairs(rows) do
    local e = r.start_s + r.dur + r.pause
    if e > total_s then total_s = e end
    if r.start_s + r.est > total_s then total_s = r.start_s + r.est end
  end

  V5.plan = {
    manifest   = m,
    rows       = rows,
    plan_path  = plan_path,
    html_path  = m.plan_html or "",
    total_s    = total_s,
    sel        = nil,             -- chunk index selected in the strip/table
    scroll_to  = nil,             -- table row to bring into view next frame
    use_table  = reaper.ImGui_BeginTable ~= nil,
    -- Counts come from the manifest, not from re-tallying rows: the engine
    -- is the authority on the verdicts and the panel must never disagree
    -- with the HTML the user is looking at.
    counts     = {
      fits  = tonumber(m.fits_count)  or 0,
      tight = tonumber(m.tight_count) or 0,
      over  = tonumber(m.over_count)  or 0,
      short = tonumber(m.short_count) or 0,
      empty = tonumber(m.empty_count) or 0,
    },
  }
  V5.set_regen_target(m.out_dir, m.language)
  _ui_phase = "plan"
  return true
end

-- ---------------------------------------------------------------------------
-- v0.7 per-project run history. One JSON per REAPER project under
-- engine/history/ (the status dirs are wiped at every launch — this dir is
-- not). Reopening the project (and this panel) lists its past runs with
-- Resume review / Import, so transcription+translation are never redone.
-- All state lives on V5 (main chunk is at Lua's 200-local limit); the
-- manifests themselves stay in each run's out_dir — history only indexes.
-- ---------------------------------------------------------------------------

V5.HISTORY_DIR  = ENGINE_DIR .. SEP .. "history"
V5.history_slug = nil
V5.hist         = {}

function V5.history_path()
  return V5.HISTORY_DIR .. SEP .. (V5.history_slug or "unsaved") .. ".json"
end

function V5.history_load()
  V5.history_slug = V5.project_status_slug()
  V5.hist = {}
  local text = read_all(V5.history_path())
  if not text then return end
  -- Walk the "entries" array of flat string-valued objects with the real
  -- JSON string decoder (same shape as parse_voices_json).
  local a, b = text:find('"entries"', 1, true)
  if not a then return end
  local i = skip_ws(text, b + 1)
  if text:sub(i, i) ~= ":" then return end
  i = skip_ws(text, i + 1)
  if text:sub(i, i) ~= "[" then return end
  i = i + 1
  while i <= #text do
    i = skip_ws(text, i)
    local c = text:sub(i, i)
    if c == "]" or c == "" then break end
    if c == "{" then
      local obj = {}
      i = i + 1
      while i <= #text do
        i = skip_ws(text, i)
        local cc = text:sub(i, i)
        if cc == "}" then i = i + 1 break end
        if cc == '"' then
          local key; key, i = decode_json_string(text, i)
          i = skip_ws(text, i)
          if text:sub(i, i) == ":" then
            i = skip_ws(text, i + 1)
            if text:sub(i, i) == '"' then
              local val; val, i = decode_json_string(text, i)
              obj[key] = val
            else
              i = text:find("[,}%]]", i) or (#text + 1)
            end
          end
        else
          i = i + 1
        end
      end
      if (obj.out_dir or "") ~= "" then V5.hist[#V5.hist + 1] = obj end
    else
      i = i + 1
    end
  end
end

function V5.history_write()
  reaper.RecursiveCreateDirectory(V5.HISTORY_DIR, 0)
  local f = io.open(V5.history_path(), "wb")
  if not f then return end
  f:write('{\n  "entries": [\n')
  for i, e in ipairs(V5.hist) do
    f:write(string.format(
      '    {"ts": "%s", "mode": "%s", "audio": "%s", "language": "%s", '
      .. '"out_dir": "%s", "status": "%s"}%s\n',
      _json_escape(e.ts or ""), _json_escape(e.mode or ""),
      _json_escape(e.audio or ""), _json_escape(e.language or ""),
      _json_escape(e.out_dir or ""), _json_escape(e.status or ""),
      i < #V5.hist and "," or ""))
  end
  f:write('  ]\n}\n')
  f:close()
end

-- Record a milestone for the CURRENT project. Newest first, deduped by
-- out_dir (a dub after a review replaces the review entry), capped at 20.
function V5.history_record(status, m)
  m = m or {}
  if (m.out_dir or "") == "" then return end
  if V5.history_slug ~= V5.project_status_slug() then V5.history_load() end
  local e = {
    ts       = os.date("%Y-%m-%d %H:%M"),
    mode     = (SCRIPT_MODE == "have") and "paste" or "full",
    audio    = (m.audio ~= "" and m.audio) or LAST_AUDIO or "",
    language = (m.language ~= "" and m.language) or LANGUAGE or "",
    out_dir  = m.out_dir,
    status   = status,
  }
  local kept = { e }
  for _, old in ipairs(V5.hist) do
    if old.out_dir ~= e.out_dir and #kept < 20 then kept[#kept + 1] = old end
  end
  V5.hist = kept
  V5.history_write()
end

-- ── v0.23 presentation ──────────────────────────────────────────────────────
-- A run used to be a wrapped sentence on one line and three SmallButtons on
-- the next — ~56 px each, so four runs cost more than the whole form above
-- them. That is why it defaulted to collapsed, and why opening it was
-- documented as "exactly the case where the body is meant to scroll". The body
-- does not scroll any more (v0.23), so that comment became a promise the
-- screen cannot keep: the list had to become something that FITS. One row per
-- run, aligned columns, and only the action you would actually take.

-- Does this run's manifest still exist? Every action below already answers
-- this on click; answering per ROW instead is what lets a dead entry say so
-- BEFORE you press anything. Cached, because a stat per row per frame is a
-- filesystem hit thirty times a second for an answer that changes in minutes.
V5.HIST_STAT_EVERY = 4
V5.hist_stat = {}
V5.hist_open = nil          -- index whose ⋯ row is expanded, or nil
V5.hist_ask  = false        -- Clear list pressed once, waiting for the yes

function V5.hist_manifest(e)
  return (e and (e.out_dir or "") ~= "")
     and (e.out_dir .. SEP .. "engine_done.json") or ""
end

function V5.hist_alive(e)
  local p = V5.hist_manifest(e)
  if p == "" then return false end
  local now, c = os.time(), V5.hist_stat[V5.hist_manifest(e)]
  if c and (now - c.at) < V5.HIST_STAT_EVERY then return c.ok end
  local ok = file_exists(p)
  V5.hist_stat[p] = { ok = ok, at = now }
  return ok
end

-- "today 10:54" / "yest. 16:25" / "13 Aug 14:54". Three rows out of four in a
-- working week are today or yesterday, and the ISO stamp spends sixteen
-- characters saying so. The full stamp is still there, as the row's tooltip.
V5.MON = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
           'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' }

function V5.hist_when(ts)
  local y, m, d, hh, mm = tostring(ts or ""):match(
    "^(%d%d%d%d)-(%d%d)-(%d%d)%s+(%d%d):(%d%d)")
  if not y then
    -- An entry from before this field existed, or a hand-edited JSON. An empty
    -- string here would draw an empty cell, which reads as a broken row rather
    -- than as a missing value.
    local s = tostring(ts or "")
    return s ~= "" and s or "?"
  end
  local day = y .. "-" .. m .. "-" .. d
  if day == os.date("%Y-%m-%d") then return "today " .. hh .. ":" .. mm end
  -- Noon rather than now: subtracting a day from the current time can land on
  -- the wrong date across a DST change, and this is only used to name a day.
  local t = os.date("*t")
  t.hour, t.min, t.sec = 12, 0, 0
  if day == os.date("%Y-%m-%d", os.time(t) - 86400) then
    return "yest. " .. hh .. ":" .. mm
  end
  return string.format("%s %s %s:%s", d, V5.MON[tonumber(m)] or m, hh, mm)
end

-- Byte index of the last UTF-8 character boundary at or before *i*, so a
-- truncated file name never ends half way through a multi-byte character.
function V5.u8_cut(s, i)
  if i >= #s then return #s end
  while i > 0 do
    local b = s:byte(i + 1)
    if not b or b < 0x80 or b >= 0xC0 then return i end
    i = i - 1
  end
  return 0
end

-- Fit *text* into *max_w* px, cutting the MIDDLE — run names differ at the
-- end (they carry a timestamp), so lopping the tail off makes every row in a
-- session look identical.
-- Byte index of the first UTF-8 boundary at or AFTER *i*. V5.u8_cut answers for
-- the HEAD of a string; the tail needs this one, and using u8_cut for both is
-- what let ellipsize emit half a character.
function V5.u8_next(s, i)
  if i < 1 then return 1 end
  local n = #s
  while i <= n do
    local b = s:byte(i)
    -- 0x80..0xBF is a continuation byte, so not a character boundary
    if not (b >= 0x80 and b <= 0xBF) then return i end
    i = i + 1
  end
  return n + 1
end

V5.EST_WIDE = 9        -- conservative px/char: over-estimating is the safe way

function V5.ellipsize(ctx, text, max_w)
  text = tostring(text or "")
  if text == "" then return text end
  -- Under a couple of characters' worth there is nothing to cut TO, so the
  -- answer is the ellipsis itself. It used to return the text UNCHANGED here,
  -- which turned "no room" into "draw all of it" — the one case where the
  -- caller most needed a short string. That is how the run column's value
  -- column ran 200 px past its own edge.
  if max_w < 18 then return '…' end
  if V5.text_w(ctx, text, V5.EST_WIDE) <= max_w then return text end
  local n = #text
  for keep = n - 1, 6, -2 do
    local head = V5.u8_cut(text, math.floor(keep / 2))
    -- The tail used to be n - u8_cut(text, …): a boundary counted from the
    -- FRONT, subtracted from the length, which is an arbitrary byte offset from
    -- the back. On any string with a multi-byte character in it — every Indic
    -- label, and every '·' separator in this panel — that could start the tail
    -- inside a character and produce invalid UTF-8, which ImGui draws as a
    -- hollow box.
    local tail = V5.u8_next(text, n - math.ceil(keep / 2) + 1) - 1
    local out  = text:sub(1, head) .. '…' .. text:sub(tail + 1)
    if V5.text_w(ctx, out, V5.EST_WIDE) <= max_w then return out end
  end
  -- The floor used to be a flat six bytes plus the ellipsis, whatever the
  -- budget was — so a 34 px column still got a 57 px string and whatever came
  -- after it was drawn through. Walk the head down instead, and give up on
  -- showing any of the text before giving up on the budget.
  for keep = 6, 1, -1 do
    local out = text:sub(1, V5.u8_cut(text, keep)) .. '…'
    if V5.text_w(ctx, out, V5.EST_WIDE) <= max_w then return out end
  end
  return '…'
end

-- A non-interactive state chip. Drawn rather than typed: a disabled button
-- reads as something you failed to be allowed to press, and bare coloured text
-- does not hold a column together when you are scanning down it.
-- How wide V5.pill will draw *text*. Callers that put something after a chip
-- need this: the chip is as wide as its own text, and 'your script' is 12 px
-- wider than the 84 px gap the run list used to leave for it (F3).
function V5.pill_w(ctx, text)
  return V5.text_w(ctx, text, 7) + 14
end

function V5.pill(ctx, text, fg, bg)
  local dl   = reaper.ImGui_GetWindowDrawList and reaper.ImGui_GetWindowDrawList(ctx)
  local rect = reaper.ImGui_DrawList_AddRectFilled
  local txt  = reaper.ImGui_DrawList_AddText
  if not (dl and rect and txt and reaper.ImGui_GetCursorScreenPos) then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), fg)
    reaper.ImGui_Text(ctx, text)
    reaper.ImGui_PopStyleColor(ctx)
    return
  end
  local w    = V5.pill_w(ctx, text)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_Dummy(ctx, w, 18)
  rect(dl, x, y + 1, x + w, y + 17, bg, 8)
  txt(dl, x + 7, y + 2, fg, text)
end

-- What a row's state is called and coloured, in one place: the dot, the chip
-- and the primary button all read from it.
function V5.hist_look(e)
  if not V5.hist_alive(e) then
    return V5.COL.faint, 'files gone', V5.COL.dim, V5.COL.chip_off
  elseif e.status == "review" then
    return V5.COL.warn, 'paused', V5.COL.warn, V5.COL.chip_warn
  elseif e.mode == "paste" then
    return V5.COL.step_ok, 'your script', V5.COL.info, V5.COL.chip_info
  end
  return V5.COL.step_ok, 'dubbed', V5.COL.step_ok, V5.COL.chip_ok
end

-- Load a history entry's manifest, or nil + a sentence saying why not.
function V5.hist_open_manifest(e, want)
  local p = V5.hist_manifest(e)
  local m = (p ~= "" and file_exists(p)) and load_manifest_json(p) or nil
  if m and m.status == want then return m end
  return nil, "This run's files are no longer in:\n" .. (e.out_dir or "?") ..
              "\n(The folder was moved or cleaned. Remove the entry from the " ..
              "list, or run the pipeline again.)"
end

function V5.hist_resume(e)
  local m, why = V5.hist_open_manifest(e, "review")
  if not m then ui_set_banner("error", why) return end
  local ok, err = enter_review_phase(m)
  if not ok then ui_set_banner("error", err or "Could not resume the review.") end
end

function V5.hist_import(e)
  local m, why = V5.hist_open_manifest(e, "ok")
  if not m then ui_set_banner("error", why) return end
  reaper.ShowMessageBox(import_to_timeline(m), "Import Dub Results", 0)
end

function V5.hist_use(e)
  if (e.audio or "") ~= "" and file_exists(e.audio) then LAST_AUDIO = e.audio end
  if (e.language or "") ~= "" then LANGUAGE = e.language end
  save_settings()
  ui_set_banner("info", "Audio and language loaded from history.")
end

-- Removing an ENTRY is not removing a RUN: the index is ours, the folders are
-- the user's. Nothing in here touches out_dir, and the footer says so.
function V5.hist_remove(i)
  table.remove(V5.hist, i)
  V5.hist_open = nil
  V5.history_write()
end

function V5.hist_clear()
  V5.hist, V5.hist_open, V5.hist_ask = {}, nil, false
  V5.history_write()
end

function V5.hist_missing()
  local n = 0
  for _, e in ipairs(V5.hist) do if not V5.hist_alive(e) then n = n + 1 end end
  return n
end

function V5.hist_clear_missing()
  local kept = {}
  for _, e in ipairs(V5.hist) do
    if V5.hist_alive(e) then kept[#kept + 1] = e end
  end
  local n = #V5.hist - #kept
  V5.hist, V5.hist_open = kept, nil
  V5.history_write()
  return n
end

-- The newest paused-and-still-there run — the one the resume card takes out of
-- the list so the two can never offer the same run twice. V5.hist is newest
-- first, so the first match is the right one.
function V5.hist_paused()
  for i, e in ipairs(V5.hist) do
    if e.status == "review" and V5.hist_alive(e) then return i, e end
  end
  return nil
end

-- ── One run, one row ────────────────────────────────────────────────────────
-- Returns a pending action ('remove') to be applied AFTER the loop — mutating
-- V5.hist while drawing it would renumber the rows under the widget ids.
V5.HIST_BTN_W = 104        -- the one primary action (Resume / Import)
V5.HIST_KEB_W = 22         -- the ⋯ kebab
V5.HIST_GAP   = 8          -- between any two columns

function V5.hist_row(ctx, i, e)
  local alive = V5.hist_alive(e)
  local dot, chip_text, chip_fg, chip_bg = V5.hist_look(e)
  local review = (e.status == "review")

  local x0 = reaper.ImGui_GetCursorPosX(ctx) or 0
  local w  = reaper.ImGui_GetContentRegionAvail(ctx)
  if type(w) ~= "number" or w < 120 then w = 560 end

  -- v0.26: every column is MEASURED, and the row is laid out from the right
  -- edge inwards. It used to be four hand-counted offsets — 16, 106,
  -- x_act - 76, x_act + 84 — against text whose width nobody controls: the
  -- language name, the state chip, and a date that is a short stamp for
  -- entries this version wrote and a raw one for anything older or
  -- hand-edited. Both collisions that came out of that (the chip under the
  -- Import button, the file name printed over the date) are gone by
  -- construction.
  local when   = V5.hist_when(e.ts)
  local lang   = e.language or '?'
  -- The date is ellipsized too. hist_when returns a short stamp for anything
  -- this version wrote, but the raw value for an older or hand-edited entry —
  -- 'Wed Aug 19 14:32:07 2026' is 195 px, which is wider than the whole row at
  -- a narrow window, and it was the one column with no ceiling at all.
  local when_room = math.max(18, w - 16 - V5.HIST_KEB_W - V5.HIST_GAP
                                     - V5.HIST_BTN_W - V5.HIST_GAP - 12)
  when = V5.ellipsize(ctx, when, when_room)
  local when_w = V5.text_w(ctx, when, V5.EST_WIDE)
  local lang_w = V5.text_w(ctx, lang, V5.EST_WIDE)
  local chip_w = V5.pill_w(ctx, chip_text)
  local G      = V5.HIST_GAP

  local x_keb  = x0 + w - V5.HIST_KEB_W
  local x_btn  = x_keb  - G - V5.HIST_BTN_W
  local x_chip = x_btn  - G - chip_w
  local x_lang = x_chip - G - lang_w
  local x_file = x0 + 16 + when_w + 12
  -- Under this the chip and the language go, and the row keeps what it cannot
  -- do without: when, what, and the one action.
  local wide   = (x_lang - x_file) >= 120
  local file_r = wide and x_lang or x_btn
  -- Narrower still and even the file name has nowhere to go. The button is
  -- pinned to the right, so a name drawn at its 60 px floor would be drawn
  -- THROUGH it — the date and the action are what the row cannot do without,
  -- and the name is in the row's tooltip either way.
  local room   = file_r - x_file - 12
  local show_name = room >= 60

  -- The pen is the right edge of everything drawn so far. Every column asks to
  -- start at its own x and is given max(that, pen + gap), so a value wider
  -- than the room allowed for it pushes what follows right instead of being
  -- drawn through by it. This is the whole of the fix: an absolute SameLine on
  -- its own will happily walk the cursor backwards.
  local pen = x0
  -- *cap* pins a column that must not move: the kebab is flush to the right
  -- edge, so pushing it (which the pen would do if an earlier value measured
  -- wider than the room reserved for it) would put it outside the row and grow
  -- the list a horizontal scrollbar. Everything before it can be pushed;
  -- the two right-hand columns cannot.
  local function put(want, width, cap)
    local at = math.max(want, pen + G)
    if cap and at > cap then at = math.max(want, cap) end
    pen = at + (width or 0)
    return at
  end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), dot)
  reaper.ImGui_Text(ctx, '●')
  reaper.ImGui_PopStyleColor(ctx)
  pen = x0 + 10

  reaper.ImGui_SameLine(ctx, put(x0 + 16, when_w, x_btn - G))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                              alive and V5.COL.text2 or V5.COL.faint)
  reaper.ImGui_Text(ctx, when)
  reaper.ImGui_PopStyleColor(ctx)

  if show_name then
    local name = V5.ellipsize(ctx, basename(e.audio or ""), room)
    reaper.ImGui_SameLine(ctx, put(x_file, V5.text_w(ctx, name, V5.EST_WIDE),
                                   file_r - 12))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                                alive and V5.COL.text or V5.COL.faint)
    reaper.ImGui_Text(ctx, name)
    reaper.ImGui_PopStyleColor(ctx)
  end
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(
      (e.ts or '?') .. '\n' .. (e.audio or '(no source recorded)') ..
      '\n' .. (e.out_dir or '')))
  end
  if not show_name then
    -- Nothing was drawn for the name, so the indent below has nothing to line
    -- up under: fall back to the date column.
    x_file = x0 + 16
  end

  if wide then
    reaper.ImGui_SameLine(ctx, put(x_lang, lang_w, x_chip - G))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                                alive and V5.COL.dim or V5.COL.faint)
    reaper.ImGui_Text(ctx, lang)
    reaper.ImGui_PopStyleColor(ctx)

    -- The gap after the chip is the chip's OWN measured width, not 84.
    reaper.ImGui_SameLine(ctx, put(x_chip, chip_w, x_btn - G))
    V5.pill(ctx, chip_text, chip_fg, chip_bg)
    reaper.ImGui_SameLine(ctx, put(x_btn, V5.HIST_BTN_W, x_btn))
  else
    reaper.ImGui_SameLine(ctx, put(x_btn, V5.HIST_BTN_W, x_btn))
  end

  _ui_begin_disabled(ctx, not alive)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        V5.COL.job)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), V5.COL.job_hi)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  V5.COL.job_act)
  if reaper.ImGui_Button(ctx, (review and 'Resume##h' or 'Import##h') .. i,
                         104, 20) then
    if review then V5.hist_resume(e) else V5.hist_import(e) end
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  _ui_end_disabled(ctx)
  if not alive and reaper.ImGui_IsItemHovered and reaper.ImGui_SetTooltip
     and reaper.ImGui_IsItemHovered(ctx,
           reaper.ImGui_HoveredFlags_AllowWhenDisabled
           and reaper.ImGui_HoveredFlags_AllowWhenDisabled() or 0) then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(
      "This run's folder is gone:\n" .. (e.out_dir or '?') ..
      "\nUse ⋯ to take it out of the list."))
  end

  -- '##hk', not '##h': ImGui hashes only what FOLLOWS the '##', so a kebab
  -- labelled '⋯##h1' is literally the same widget as 'Import##h1' above it.
  reaper.ImGui_SameLine(ctx, put(x_keb, V5.HIST_KEB_W, x_keb))
  if reaper.ImGui_Button(ctx, '⋯##hk' .. i, V5.HIST_KEB_W, 20) then
    V5.hist_open = (V5.hist_open == i) and nil or i
  end
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap('More for this run.'))
  end

  -- Expanded in place, not in a popup: the panel opens no popups anywhere
  -- else, and a hover menu is not worth being the first one.
  local pending
  if V5.hist_open == i then
    local ind = x_file - x0            -- line up under the file-name column
    reaper.ImGui_Indent(ctx, ind)
    -- A wrapping row: these three chips come to ~330 px and the list is as
    -- narrow as the form column it sits in.
    V5.wrap_begin(ctx, 6)
    V5.wrap_next(ctx, V5.chip_w(ctx, 'Use audio + language'))
    if V5.chip(ctx, 'Use audio + language##hu' .. i,
               'Put this run\'s source file and language back in the form above.') then
      V5.hist_use(e)
    end
    V5.wrap_next(ctx, V5.chip_w(ctx, 'Open folder'))
    if V5.chip(ctx, 'Open folder##hf' .. i, 'Show this run\'s output folder.') then
      if (e.out_dir or "") ~= "" then open_path(e.out_dir) end
    end
    V5.wrap_next(ctx, V5.chip_w(ctx, 'Remove from list'))
    if V5.chip(ctx, 'Remove from list##hr' .. i,
               'Takes this run out of the list. The folder and its audio are ' ..
               'untouched — this list is only an index.', true) then
      pending = 'remove'
    end
    V5.wrap_end()
    reaper.ImGui_Unindent(ctx, ind)
    reaper.ImGui_Dummy(ctx, 0, 2)
  end
  return pending
end

-- Setup-phase history section. Re-loads when the active REAPER project
-- changes (panel left open, user switches project tabs).
function V5.ui_history(ctx)
  if V5.history_slug ~= V5.project_status_slug() then
    V5.history_load()
    V5.hist_open, V5.hist_ask = nil, false
  end
  if #V5.hist == 0 then return end

  -- v0.26: a paused run is a row like any other. It used to be hoisted into a
  -- card of its own above the form — three buttons and two lines of prose for
  -- something the row already says with a "paused" pill and a Resume button.
  -- The card's other two actions live under the row's ⋯ (Open folder, Remove
  -- from list), so nothing it could do was lost with it.
  local paused = V5.hist_paused()
  -- A review manifest found on disk at launch with no row of its own — the
  -- panel was closed when that run paused. Recorded here so it is reachable;
  -- history_record replaces by out_dir, so it can never double up.
  if _resume_manifest and not paused then
    local known = false
    for _, e in ipairs(V5.hist) do
      if e.out_dir == _resume_manifest.out_dir then known = true break end
    end
    if not known then
      V5.history_record("review", _resume_manifest)
      paused = V5.hist_paused()
    end
    -- Consumed either way: the row is the record now. Left set, "Remove from
    -- list" on that row would put it straight back on the next frame.
    _resume_manifest = nil
  end
  local n = #V5.hist
  if n == 0 then return end

  reaper.ImGui_Dummy(ctx, 0, 2)
  -- v0.15: collapsed by default — it is a "look something up" list, not a step
  -- in the run. v0.23: at 22 px a row it can now be opened without putting the
  -- body's scrollbar back, so this is a preference rather than a workaround.
  -- v0.26: unfinished work is the exception — a paused run opens the list once,
  -- because a run waiting for you is not something you should have to go
  -- looking for.
  if paused and reaper.ImGui_SetNextItemOpen and reaper.ImGui_Cond_Once then
    reaper.ImGui_SetNextItemOpen(ctx, true, reaper.ImGui_Cond_Once())
  end
  if not reaper.ImGui_CollapsingHeader(ctx,
      ('Project history (%d)###dub_history'):format(n)) then
    return
  end

  local remove
  for i, e in ipairs(V5.hist) do
    if V5.hist_row(ctx, i, e) == 'remove' then remove = i end
  end
  if remove then V5.hist_remove(remove) end

  -- ── Clearing ──────────────────────────────────────────────
  -- Two very different destructions sit one click apart here: this list is an
  -- INDEX, the runs are folders of audio. Nothing below touches a folder, and
  -- the row that explains that is always on screen while the controls are.
  reaper.ImGui_Dummy(ctx, 0, 2)
  reaper.ImGui_Separator(ctx)
  if V5.hist_ask then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn_text)
    reaper.ImGui_Text(ctx, ('Clear all %d entries for this project?'):format(n))
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_SameLine(ctx)
    if V5.chip(ctx, 'Yes, clear the list##histyes', nil, true) then V5.hist_clear() end
    reaper.ImGui_SameLine(ctx)
    if V5.chip(ctx, 'Cancel##histno') then V5.hist_ask = false end
  else
    if V5.chip(ctx, 'Clear list##histclr',
               'Empties this project\'s run list. No audio and no output ' ..
               'folder is deleted — the list is only an index of past runs.',
               true) then
      V5.hist_ask = true
    end
    local gone = V5.hist_missing()
    if gone > 0 then
      reaper.ImGui_SameLine(ctx)
      -- No confirmation: there is nothing here to lose. These rows point at
      -- folders that are already gone.
      if V5.chip(ctx, ('Clear %d missing##histgone'):format(gone),
                 'Drops only the rows whose folder is no longer there.') then
        local removed = V5.hist_clear_missing()
        ui_set_banner("info", ('Removed %d entr%s that pointed at missing ' ..
                               'folders.'):format(removed,
                               removed == 1 and 'y' or 'ies'))
      end
    end
    reaper.ImGui_SameLine(ctx)
    _grey_hint(ctx, 'removes the list only — no audio, no output folder')
  end
  reaper.ImGui_Separator(ctx)
end

V5.history_load()

-- The edited translation as one blank-line-separated text blob.
local function review_collect_text()
  local txt
  if _review.use_table then
    txt = table.concat(_review.tr_paras, "\n\n")
  else
    txt = _review.tr_buffer or ""
  end
  txt = txt:gsub("\r\n", "\n")
  if txt:sub(-1) ~= "\n" then txt = txt .. "\n" end
  return txt
end

local function save_review_text()
  local f = io.open(_review.edited_path, "wb")
  if not f then
    ui_set_banner("error", "Could not write:\n" .. _review.edited_path)
    return false
  end
  f:write(review_collect_text())
  f:close()
  _review.dirty = false
  return true
end

-- Resume the pipeline: emotion + TTS + sync, reading the (possibly edited)
-- translation from `script_path`. Same out_dir — derived from --audio.
local function launch_dub_continue(script_path)
  ui_clear_banner()
  local m = _review and _review.manifest
  if not m then
    ui_set_banner("error", "No review run is active.")
    return false
  end
  local audio = (m.audio ~= "" and m.audio) or LAST_AUDIO
  if not file_exists(audio) then
    ui_set_banner("error",
      "The original audio file is gone — the dub step derives its output " ..
      "folder from it:\n" .. audio)
    return false
  end
  if not script_path or not file_exists(script_path) then
    ui_set_banner("error",
      "Translation script file not found:\n" .. tostring(script_path))
    return false
  end

  local py = preflight_engine(true)
  if not py then return false end

  -- v0.30: the cast decides the voice, and it is written to disk BEFORE the
  -- launch — the engine reads <base>_speakers.json for the per-paragraph map
  -- and takes the main voice from --voice-id, so both have to be settled
  -- while the review state still exists (a launch clears it).
  local voice, cast_note = nil, nil
  if _review then
    local main = _review.cast and _review.cast.speakers[1]
    if main and (main.voice or ""):match("%S") then voice = main.voice end
    local ok, where, wrote = V5.cast_save(_review)
    if not ok then
      cast_note = "[panel] Cast   : NOT SAVED (" .. tostring(where) .. ")"
    elseif wrote then
      cast_note = "[panel] Cast   : " .. tostring(where)
    end
  end

  local lang = (m.language ~= "" and m.language) or LANGUAGE
  local cmd = build_engine_cmd(py, {
    audio = audio, language = lang, steps = "dub", script = script_path,
    voice_id = voice,
  })
  local log = {
    "[panel] Python : " .. py,
    "[panel] Audio  : " .. audio,
    "[panel] Lang   : " .. lang,
    "[panel] Steps  : dub",
    "[panel] Script : " .. script_path,
    "[panel] Voice  : " .. (voice or "(the ⚙ Settings voice)"),
  }
  if cast_note then log[#log + 1] = cast_note end
  return launch_engine(cmd, "dub", log)
end

-- ---------------------------------------------------------------------------
-- Chunk regeneration — re-synthesize one item's text, swap the take source
-- ---------------------------------------------------------------------------

local function _item_guid(item)
  local ok, g = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
  if ok and g then return g end
  return ""
end

-- Item pointers can go stale across a multi-second engine run (undo, delete,
-- project edits). Re-resolve by GUID right before touching the item.
local function _find_item_by_guid(guid)
  if guid == "" then return nil end
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local it = reaper.GetMediaItem(0, i)
    if _item_guid(it) == guid then return it end
  end
  return nil
end

-- Write the chunk text + launch the engine in --regen-chunk mode.
-- chunk id n = item position in ms (stable and unique per chunk); the wav
-- version suffix _v<K> auto-increments so nothing is ever overwritten.
-- v0.8: *voice_id* re-synthesizes the same text in a different voice; nil or
-- "" keeps the ⚙ Settings voice (the engine still auto-resolves one when no
-- voice is set anywhere).
local function start_regen(item, text, voice_id)
  ui_clear_banner()
  if _regen_out_dir == "" then
    ui_set_banner("error",
      "Output folder unknown — run a pipeline first, or pick a finished " ..
      "run's engine_done.json in the regen section.")
    return false
  end
  if not (text or ""):match("%S") then
    ui_set_banner("error", "Chunk text is empty — nothing to synthesize.")
    return false
  end

  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local n = math.floor(pos * 1000 + 0.5)
  local regen_dir = _regen_out_dir .. SEP .. "regen"
  reaper.RecursiveCreateDirectory(regen_dir, 0)

  -- Indic text never travels on argv: it goes through this UTF-8 file.
  local txt_path = string.format("%s%schunk_%d.txt", regen_dir, SEP, n)
  local f = io.open(txt_path, "wb")
  if not f then
    ui_set_banner("error", "Could not write:\n" .. txt_path)
    return false
  end
  local body = text:gsub("\r\n", "\n")
  if body:sub(-1) ~= "\n" then body = body .. "\n" end
  f:write(body)
  f:close()

  local k, wav_path = 1, nil
  repeat
    wav_path = string.format("%s%schunk_%d_v%d.wav", regen_dir, SEP, n, k)
    k = k + 1
  until not file_exists(wav_path)

  local py = preflight_engine()
  if not py then return false end

  local lang = (_regen_lang ~= "" and _regen_lang) or LANGUAGE
  -- Empty stays nil so build_engine_cmd falls back to the Settings voice.
  local vid = ((voice_id or "") ~= "" and voice_id) or nil
  local cmd = build_engine_cmd(py, {
    regen = true, language = lang, text_file = txt_path, out_wav = wav_path,
    voice_id = vid,
  })
  _regen_pending      = { guid = _item_guid(item), note = text,
                          out_wav = wav_path }
  _regen_return_phase = _ui_phase
  return launch_engine(cmd, "regen", {
    "[panel] Regen  : " .. txt_path,
    "[panel] Out wav: " .. wav_path,
    "[panel] Lang   : " .. lang,
    "[panel] Voice  : " .. (vid or ((VOICE_ID or "") ~= "" and
                            (VOICE_ID .. "  (Settings)") or "(auto)")),
    "[panel] Python : " .. py,
  })
end

-- Swap the regenerated wav into the item recorded by start_regen.
-- Returns true, or false + reason. One undo block.
local function apply_regen_result(wav)
  local p = _regen_pending
  if not p then return false, "No pending regeneration." end
  if not file_exists(wav) then
    return false, "Regenerated wav not found:\n" .. wav
  end
  local item = _find_item_by_guid(p.guid)
  if not item then
    return false, "The media item no longer exists (deleted or project " ..
                  "changed). The new audio is still at:\n" .. wav
  end
  local take = reaper.GetActiveTake(item)
  if not take then
    return false, "The item has no active take. The new audio is at:\n" .. wav
  end
  local src = reaper.PCM_Source_CreateFromFile(wav)
  if not src then
    return false, "REAPER could not open the media file:\n" .. wav
  end

  -- v0.18: remember the take we are about to replace, so the panel can offer
  -- "keep it or put it back" instead of leaving you to press Ctrl+Z and hope.
  -- Regeneration was always non-destructive on DISK (new files go to regen/);
  -- this makes it non-destructive on the TIMELINE too.
  local old_src  = reaper.GetMediaItemTake_Source(take)
  local old_path = old_src and reaper.GetMediaSourceFileName(old_src, "") or ""
  V5.regen_undo = {
    guid     = p.guid,
    old_path = old_path,
    old_len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
    old_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
    old_text = V5.get_item_text(item),
    new_wav  = wav,
    new_text = p.note or "",
  }

  reaper.Undo_BeginBlock()
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 0)
  -- GetMediaSourceLength returns (length, isQN). A QN length is in beats,
  -- not seconds — leave the item length untouched in that case.
  local len, is_qn = reaper.GetMediaSourceLength(src)
  if len and len > 0 and not is_qn then
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len)
  end
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", basename(wav), true)
  V5.set_item_text(item, p.note or "")
  reaper.Undo_EndBlock("Regenerate dub chunk", -1)
  reaper.UpdateArrange()
  if len and len > 0 and not is_qn then V5.regen_undo.new_len = len end
  return true
end

-- Put the take that was there before the last regeneration back. The new wav
-- stays on disk in regen/, so this is reversible in both directions.
function V5.regen_revert()
  local u = V5.regen_undo
  if not u then return false, "Nothing to put back." end
  if (u.old_path or "") == "" or not file_exists(u.old_path) then
    return false, "The original audio file is no longer on disk:\n" ..
                  tostring(u.old_path)
  end
  local item = _find_item_by_guid(u.guid)
  if not item then return false, "That item no longer exists." end
  local take = reaper.GetActiveTake(item)
  if not take then return false, "That item has no active take." end
  local src = reaper.PCM_Source_CreateFromFile(u.old_path)
  if not src then
    return false, "REAPER could not reopen:\n" .. u.old_path
  end

  reaper.Undo_BeginBlock()
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", u.old_offs or 0)
  if (u.old_len or 0) > 0 then
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", u.old_len)
  end
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME",
                                        basename(u.old_path), true)
  V5.set_item_text(item, u.old_text or "")
  reaper.Undo_EndBlock("Revert regenerated dub chunk", -1)
  reaper.UpdateArrange()
  V5.regen_undo = nil
  return true
end

-- ---------------------------------------------------------------------------
-- v0.4 Track voice change — render a track, re-voice it with the ElevenLabs
-- voice changer (speech-to-speech), import the result as a new track
-- ---------------------------------------------------------------------------

local function _find_track_by_guid(guid)
  if not guid or guid == "" then return nil end
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if reaper.GetTrackGUID(tr) == guid then return tr end
  end
  return nil
end

local function _track_items_end(track)
  local max_end = 0
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local e = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
              + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    if e > max_end then max_end = e end
  end
  return max_end
end

local function _sanitize_filename(s)
  s = tostring(s or ""):gsub('[\\/:%*%?"<>|]', "_"):gsub("%s+", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then s = "track" end
  return s
end

-- Render ONE track to a mono WAV through the project render API (stems
-- mode), saving and restoring every render setting it touches. Blocks
-- until the render finishes. Returns the wav path, or nil + reason.
--
-- v0.31: *from_s*/*to_s* bound the render in project time. Without them it is
-- 0:00 → the last item's end, which is what the voice changer wants (it
-- re-voices a whole track in place); the dub source wants the REGION the
-- timeline is showing, and rendering from 0:00 would prepend every minute of
-- silence before it to the transcription.
local function render_track_stem(track, out_dir, name_base, from_s, to_s)
  local startpos = math.max(0, tonumber(from_s) or 0)
  local endpos   = tonumber(to_s) or _track_items_end(track)
  if endpos <= 0 then
    return nil, "The selected track has no media items."
  end
  if endpos - startpos <= 0.01 then
    return nil, string.format(
      "That region is empty (%s to %s).", V5.fmt_pos(startpos),
      V5.fmt_pos(endpos))
  end
  reaper.RecursiveCreateDirectory(out_dir, 0)

  local NUM_KEYS = { "RENDER_SETTINGS", "RENDER_BOUNDSFLAG",
                     "RENDER_STARTPOS", "RENDER_ENDPOS", "RENDER_CHANNELS",
                     "RENDER_TAILFLAG", "RENDER_ADDTOPROJ" }
  local STR_KEYS = { "RENDER_FILE", "RENDER_PATTERN", "RENDER_FORMAT" }
  local saved_num, saved_str = {}, {}
  for _, k in ipairs(NUM_KEYS) do
    saved_num[k] = reaper.GetSetProjectInfo(0, k, 0, false)
  end
  for _, k in ipairs(STR_KEYS) do
    local _, v = reaper.GetSetProjectInfo_String(0, k, "", false)
    saved_str[k] = v or ""
  end
  local sel = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    sel[i] = reaper.IsTrackSelected(reaper.GetTrack(0, i))
  end

  -- A muted track renders as silence — unmute it for the render (restored
  -- below). Matters for re-voicing a track an earlier voice change muted,
  -- and for the muted "Dub Rendered (ref)" track.
  local saved_mute = reaper.GetMediaTrackInfo_Value(track, "B_MUTE")
  reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 0)

  reaper.SetOnlyTrackSelected(track)
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 3, true)    -- selected-track stems
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, true)  -- custom bounds
  reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", startpos, true)
  reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", endpos, true)
  reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 1, true)    -- mono (voice)
  reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_FILE", out_dir, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", name_base, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "evaw", true) -- default WAV

  -- 42230 = "File: Render project, using the most recent render settings
  -- (auto-close render dialog when finished)".
  reaper.Main_OnCommand(42230, 0)

  for _, k in ipairs(NUM_KEYS) do
    reaper.GetSetProjectInfo(0, k, saved_num[k], true)
  end
  for _, k in ipairs(STR_KEYS) do
    reaper.GetSetProjectInfo_String(0, k, saved_str[k], true)
  end
  reaper.SetMediaTrackInfo_Value(track, "B_MUTE", saved_mute)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if tr and sel[i] ~= nil then reaper.SetTrackSelected(tr, sel[i]) end
  end

  local wav = out_dir .. SEP .. name_base .. ".wav"
  if not file_exists(wav) then
    return nil, "REAPER did not produce the rendered file:\n" .. wav ..
                "\n(The render may have been cancelled.)"
  end
  return wav
end

-- ─── v0.31 THE REGION: dub what the timeline shows, not the whole file ────
-- A trimmed item is a statement about what is being dubbed, and the panel
-- only half-heard it. A track holding one clean item handed its SOURCE FILE
-- to the engine — the whole file, however short the item had been trimmed to
-- — and anything else was rendered from project 0:00, so a two-minute excerpt
-- of an hour-long talk was transcribed, translated and SPOKEN in full. The
-- result then landed at 0:00, nowhere near the item it came from.
--
-- Now the timeline decides the span, and the span travels with the audio:
--   * V5.timeline_region answers what would be taken — the time selection,
--     else the selected items, else everything on the chosen track — and the
--     source row says so before anything is pressed.
--   * audio_for_region renders exactly that span. The one case that still
--     needs no render is the old fast path: the region IS a whole untrimmed
--     item starting at 0:00, so the file already is the region.
--   * a <wav>.dubregion.json sidecar records where the span starts in project
--     time, so the IMPORT puts the dub back under the item it was taken from
--     and the review screen's transport plays the right part of the talk.
--     Written only beside audio the panel itself rendered (in DubSource/), so
--     nothing is ever dropped next to the user's own files.

V5.REGION_SUFFIX = '.dubregion.json'

function V5.region_file(audio_path)
  if not audio_path or audio_path == '' then return nil end
  return audio_path .. V5.REGION_SUFFIX
end

function V5.region_save(audio_path, info)
  local p = V5.region_file(audio_path)
  if not p then return false end
  local f = io.open(p, 'wb')
  if not f then return false end
  f:write(string.format(
    '{\n  "version": 1,\n  "source": "%s",\n  "project_pos": %.6f,\n' ..
    '  "start": %.6f,\n  "end": %.6f,\n  "track": "%s",\n  "why": "%s"\n}\n',
    _json_escape(info.source or ''), info.pos or 0, info.a or 0,
    info.b or 0, _json_escape(info.track or ''), _json_escape(info.why or '')))
  f:close()
  return true
end

-- Paths are the only escaped thing in here and they cannot contain a quote on
-- either platform, so the values come back with one pattern each.
function V5.region_load(audio_path)
  local p   = V5.region_file(audio_path)
  local raw = p and read_all(p)
  if not raw then return nil end
  local pos = tonumber(raw:match('"project_pos"%s*:%s*(%-?[%d%.eE+]+)') or '')
  if not pos then return nil end
  return {
    pos    = pos,
    a      = tonumber(raw:match('"start"%s*:%s*(%-?[%d%.eE+]+)') or '') or pos,
    b      = tonumber(raw:match('"end"%s*:%s*(%-?[%d%.eE+]+)') or '') or pos,
    source = (raw:match('"source"%s*:%s*"(.-)"') or ''):gsub('\\\\', '\\'),
    track  = (raw:match('"track"%s*:%s*"(.-)"') or ''),
    why    = (raw:match('"why"%s*:%s*"(.-)"') or ''),
  }
end

-- Project time the dub of *audio_path* belongs at. 0 for a plain file, which
-- is exactly what every run did before regions existed.
function V5.region_offset(audio_path)
  local r = V5.region_load(audio_path)
  return (r and r.pos) or 0
end

-- First item start / last item end on *track*, or nil when it holds nothing.
function V5.track_items_span(track)
  local n = track and reaper.CountTrackMediaItems(track) or 0
  if n == 0 then return nil end
  local a, b
  for i = 0, n - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local s  = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local e  = s + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    a = math.min(a or s, s)
    b = math.max(b or e, e)
  end
  return a, b
end

-- What pressing Use would take, in PROJECT time. Returns {track, a, b, why}
-- or nil + the reason there is nothing to take.
--
-- Precedence — most specific statement first:
--   1. a time selection (you dragged over the part you mean),
--   2. the selected items (you clicked the piece you mean — and that also
--      says which track, so the combo can still read "(from track)"),
--   3. everything the chosen track holds.
function V5.timeline_region()
  local n_tracks = reaper.CountTracks(0)
  local track = (_src_track_idx >= 0 and _src_track_idx < n_tracks)
                and reaper.GetTrack(0, _src_track_idx) or nil

  local sa, sb, str, nsel = nil, nil, nil, 0
  local n_sel = (reaper.CountSelectedMediaItems
                 and reaper.CountSelectedMediaItems(0)) or 0
  for i = 0, n_sel - 1 do
    local it = reaper.GetSelectedMediaItem(0, i)
    local tr = it and reaper.GetMediaItemTrack and reaper.GetMediaItemTrack(it)
    if it and tr and ((not track) or tr == track) then
      -- One track's worth: a selection spanning two tracks would render a mix
      -- of both, which is never what "dub this item" means.
      str = str or tr
      if tr == str then
        local a = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        local b = a + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
        sa, sb = math.min(sa or a, a), math.max(sb or b, b)
        nsel = nsel + 1
      end
    end
  end
  track = track or str
  if not track then
    return nil, 'Pick a track — or select the item you want dubbed.'
  end

  -- NOT `local ta, tb = f and f(...)`: an `and` expression is adjusted to ONE
  -- value, so the second return would silently be nil and the time selection
  -- would never win.
  local ta, tb
  if reaper.GetSet_LoopTimeRange then
    ta, tb = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  end
  local ia, ib = V5.track_items_span(track)
  if type(ta) == 'number' and type(tb) == 'number' and tb - ta > 0.05 then
    if not ia then return nil, 'That track has no media items.' end
    -- Clamped to what the track actually holds: a time selection dragged past
    -- the end of the talk would otherwise render (and transcribe) minutes of
    -- silence at ElevenLabs' expense.
    local a, b = math.max(ta, ia), math.min(tb, ib)
    if b - a <= 0.05 then
      return nil, 'The time selection does not overlap that track.'
    end
    return { track = track, a = a, b = b, why = 'the time selection' }
  end

  if nsel > 0 then
    return { track = track, a = sa, b = sb,
             why = (nsel == 1) and 'the selected item'
                   or string.format('%d selected items', nsel) }
  end

  if not ia then return nil, 'That track has no media items.' end
  return { track = track, a = ia, b = ib, why = "the track's items" }
end

-- m:ss for a file name (V5.review_at's colon is not legal in one).
local function _region_tag(t)
  t = math.max(0, tonumber(t) or 0)
  return string.format('%dm%02ds', math.floor(t / 60), math.floor(t % 60))
end

-- The file whose audio the region is made of, for the record in the sidecar.
function V5.region_source_file(track)
  local it   = reaper.GetTrackMediaItem(track, 0)
  local take = it and reaper.GetActiveTake(it)
  if not (take and not reaper.TakeIsMIDI(take)) then return '' end
  local src = reaper.GetMediaItemTake_Source(take)
  while src and reaper.GetMediaSourceParent do
    local parent = reaper.GetMediaSourceParent(src)
    if parent then src = parent else break end
  end
  return (src and reaper.GetMediaSourceFileName(src, "")) or ''
end

-- Is this region simply a whole file? True only when the track holds ONE
-- item, untrimmed, unstretched, starting at 0:00, and the region is all of it
-- — then the source file already IS the region and 0:00 already is where it
-- belongs. Returns false, or true + that file. This is the v0.4.1 fast path
-- with the two conditions it was missing (the item has to START at zero, and
-- the region has to be the whole of it), and it is also what the source row
-- uses to decide whether the timeline is showing you less than the file.
function V5.region_is_whole_file(plan)
  local track = plan and plan.track
  if not track then return false end
  if reaper.CountTrackMediaItems(track) ~= 1 or plan.a >= 0.05 then
    return false
  end
  local it   = reaper.GetTrackMediaItem(track, 0)
  local take = it and reaper.GetActiveTake(it)
  if not (take and not reaper.TakeIsMIDI(take)) then return false end
  local src = reaper.GetMediaItemTake_Source(take)
  while src do
    local parent = reaper.GetMediaSourceParent and reaper.GetMediaSourceParent(src)
    if parent then src = parent else break end
  end
  local fn        = (src and reaper.GetMediaSourceFileName(src, "")) or ""
  local startoffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local rate      = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local item_len  = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
  local item_pos  = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
  local src_len, is_qn = reaper.GetMediaSourceLength(src)
  if fn ~= "" and file_exists(fn) and not is_qn
     and math.abs(startoffs or 0) < 0.01
     and math.abs((rate or 1) - 1) < 0.001
     and math.abs(item_pos or 0) < 0.01
     and src_len and math.abs(item_len - src_len) < 0.05
     and math.abs((plan.b - plan.a) - item_len) < 0.05 then
    return true, fn
  end
  return false
end

-- Resolve a region to an English-audio FILE for the pipeline.
-- Returns (path, nil, rendered_bool, project_pos) or (nil, reason).
local function audio_for_region(plan)
  local track = plan.track

  local whole, whole_file = V5.region_is_whole_file(plan)
  if whole then return whole_file, nil, false, 0 end

  local _, tname = reaper.GetSetMediaTrackInfo_String(track, "P_NAME",
                                                      "", false)
  if not tname or tname == "" then tname = "track" end
  local out_dir = reaper.GetProjectPath("") .. SEP .. "DubSource"
  -- The span is in the NAME as well as the sidecar: a folder of these is
  -- otherwise four identical-looking wavs of the same talk.
  local name_base = string.format('%s_%s-%s%s', _sanitize_filename(tname),
                                  _region_tag(plan.a), _region_tag(plan.b),
                                  os.date("_%Y%m%d_%H%M%S"))
  local wav, why = render_track_stem(track, out_dir, name_base, plan.a, plan.b)
  if not wav then return nil, why end
  V5.region_save(wav, { source = V5.region_source_file(track), pos = plan.a,
                        a = plan.a, b = plan.b, track = tname,
                        why = plan.why })
  return wav, nil, true, plan.a
end

-- Kick off a track voice change: render the track, then hand the wav to
-- the engine's --voice-change mode (poll/cancel like any other run).
local function start_voice_change()
  ui_clear_banner()
  save_settings()

  local n_tracks = reaper.CountTracks(0)
  if _vc_track_idx < 0 or _vc_track_idx >= n_tracks then
    ui_set_banner("error", "Pick the track to re-voice first.")
    return false
  end
  local track = reaper.GetTrack(0, _vc_track_idx)
  local voice = (VC_VOICE_ID ~= "" and VC_VOICE_ID) or VOICE_ID
  if not (voice or ""):match("%S") then
    ui_set_banner("error",
      "Pick a target voice — fetch voices in ⚙ Settings, or paste a " ..
      "voice id in the voice-change section.")
    return false
  end

  local _, tname = reaper.GetSetMediaTrackInfo_String(track, "P_NAME",
                                                      "", false)
  if not tname or tname == "" then
    tname = "Track " .. (_vc_track_idx + 1)
  end

  local py = preflight_engine()
  if not py then return false end

  -- Rendered + converted audio go to <project media path>/VoiceChange/.
  local out_dir = reaper.GetProjectPath("") .. SEP .. "VoiceChange"
  local name_base = _sanitize_filename(tname) .. os.date("_%Y%m%d_%H%M%S")

  local in_wav, why = render_track_stem(track, out_dir, name_base)
  if not in_wav then
    ui_set_banner("error", "Could not render the track:\n" .. (why or "?"))
    return false
  end

  local out_wav = out_dir .. SEP .. name_base .. "_vc.wav"
  local cmd = build_engine_cmd(py, {
    voice_change = true, in_wav = in_wav, out_wav = out_wav,
    language = LANGUAGE, voice_id = voice,
  })
  _vc_pending      = { guid = reaper.GetTrackGUID(track), in_wav = in_wav,
                       out_wav = out_wav, track_name = tname }
  _vc_return_phase = _ui_phase
  return launch_engine(cmd, "voice_change", {
    "[panel] Python : " .. py,
    "[panel] Mode   : change track voice (--voice-change)",
    "[panel] Track  : " .. tname,
    "[panel] Input  : " .. in_wav,
    "[panel] Voice  : " .. voice,
  })
end

-- Import the re-voiced wav: new track right below the original, original
-- muted (never touched otherwise). One undo block.
local function apply_voice_change_result(wav)
  local p = _vc_pending
  if not p then return false, "No pending voice change." end
  if not file_exists(wav) then
    return false, "Voice-changed wav not found:\n" .. wav
  end
  local src = reaper.PCM_Source_CreateFromFile(wav)
  if not src then
    return false, "REAPER could not open the media file:\n" .. wav
  end

  reaper.Undo_BeginBlock()
  local orig = _find_track_by_guid(p.guid)
  -- IP_TRACKNUMBER is 1-based, so inserting AT that value places the new
  -- track directly below the original (end of project when it is gone).
  local idx = orig
              and math.floor(reaper.GetMediaTrackInfo_Value(
                             orig, "IP_TRACKNUMBER") or 0)
              or reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local tr = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME",
    (p.track_name or "Track") .. " (voice changed)", true)
  local item = reaper.AddMediaItemToTrack(tr)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
  local len, is_qn = reaper.GetMediaSourceLength(src)
  if len and len > 0 and not is_qn then
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len)
  end
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", basename(wav), true)
  if orig then reaper.SetMediaTrackInfo_Value(orig, "B_MUTE", 1) end
  reaper.Undo_EndBlock("Change track voice", -1)
  reaper.UpdateArrange()
  return true
end

local function _handle_log_line(line)
  log_append(line)
  local tag = line:match("^%s*%[(S%d%a?)%]")
  if tag and STAGE_INDEX[tag] then
    _ui_stage_tag = tag
    -- Progress is relative to the ACTIVE mode's stage list, so a staged
    -- translate run fills the bar by S2c instead of stalling at ~45%.
    local list = MODE_STAGES[_run_mode] or STAGE_ORDER
    for i, t in ipairs(list) do
      if t == tag then
        _ui_progress = math.max(_ui_progress, i / (#list + 1))
        break
      end
    end
  end
end

local function _finish_run(exit_code)
  -- v0.21: taken (and cleared) first, so the flag can never stick — whichever
  -- branch below returns, the engine is free again. A quiet job never touched
  -- _ui_phase, so it has nothing to restore either.
  local quiet = V5.quiet_job
  V5.quiet_job = nil

  local m, err = load_manifest_json(DONE_JSON)
  -- A cancelled run must never land on the success phase, even when the
  -- worker managed to finish with exit 0 before the kill took effect.
  local cancelled = _ui_cancelled or _cancel_pending

  -- Shared error detail: manifest error text, else a log tail.
  local function _error_detail(limit)
    local detail = (m and m.error ~= "" and m.error) or nil
    if not detail then
      detail = read_all(LOG_PATH) or "(no output)"
      if #detail > limit then detail = "...\n" .. detail:sub(-limit) end
    end
    return detail
  end

  -- v0.3 "Test connection" — one tiny LLM call, result lands in a banner.
  if _run_mode == "test_llm" then
    if cancelled then
      ui_set_banner("warn", "LLM connection test cancelled.")
    elseif m and m.status == "ok" and exit_code == 0 then
      ui_set_banner("info", string.format(
        "LLM connection OK — %s (%s)\nReply: %s",
        (m.provider ~= "" and m.provider or "?"),
        (m.model ~= "" and m.model or "?"),
        (m.reply ~= "" and m.reply or "(empty)")))
    else
      ui_set_banner("error", "LLM connection test failed:\n" ..
                             _error_detail(600) .. "\n\nFull log: " .. LOG_PATH)
    end
    _ui_phase = _util_return_phase or "setup"
    return
  end

  -- v0.3 "Fetch voices" — fill the voice combo from the manifest voices[].
  if _run_mode == "list_voices" then
    if cancelled then
      ui_set_banner("warn", "Voice fetch cancelled.")
    elseif m and m.status == "ok" and exit_code == 0 then
      local raw = read_all(DONE_JSON) or ""
      local voices = parse_voices_json(raw)
      if #voices > 0 then
        _voices = voices
        _voices_language = LANGUAGE
        -- v0.11: keep it for the next panel session too.
        V5.voice_cache_save()
        ui_set_banner("info", string.format(
          "Fetched %d ElevenLabs voices for %s — pick one in any Voice list " ..
          "(any of the Tools).",
          #voices, LANGUAGE))
      else
        ui_set_banner("warn",
          "Voice fetch finished, but the manifest had no voices — use the " ..
          "manual voice id field instead.")
      end
    else
      ui_set_banner("error", "Voice fetch failed:\n" ..
                             _error_detail(600) .. "\n\nFull log: " .. LOG_PATH)
    end
    if not quiet then _ui_phase = _util_return_phase or "setup" end
    return
  end

  -- v0.4 "Change track voice" — import the re-voiced wav as a new track.
  if _run_mode == "voice_change" then
    local back = _vc_return_phase or "setup"
    if cancelled then
      ui_set_banner("warn", "Voice change cancelled.")
    elseif m and m.status == "ok" and exit_code == 0
           and (m.vc_wav or "") ~= "" then
      local ok, why = apply_voice_change_result(m.vc_wav)
      if ok then
        ui_set_banner("info",
          "Track voice changed — the new track sits below the original " ..
          "(original muted, untouched):\n" .. m.vc_wav)
      else
        ui_set_banner("error",
          "Voice change finished, but the import failed:\n" ..
          (why or "(unknown)") .. "\n\nThe audio is at:\n" ..
          (m.vc_wav or "?"))
      end
    else
      ui_set_banner("error", "Voice change failed:\n" ..
                             _error_detail(600) ..
                             "\n\nFull log: " .. LOG_PATH)
    end
    _vc_pending = nil
    _ui_phase = back
    return
  end

  -- v0.7 Text to Speech: same --regen-chunk manifest, different landing —
  -- the wav goes onto the TTS track at the edit cursor.
  if _run_mode == "tts" then
    local back = V5.tts_return_phase or "setup"
    if cancelled then
      ui_set_banner("warn", "Speech generation cancelled.")
    elseif m and m.status == "ok" and exit_code == 0
           and (m.regen_wav or "") ~= "" then
      V5.tts_last_wav = m.regen_wav
      -- v0.18: remember it, so re-inserting the same line later is a click
      -- rather than a second synthesis of words already paid for.
      V5.tts_history_add(m.regen_wav,
                         (V5.tts_pending and V5.tts_pending.text) or "",
                         (V5.tts_pending and V5.tts_pending.voice) or "")
      local ok, why = V5.tts_import(m.regen_wav)
      if ok then
        ui_set_banner("info",
          "Speech generated and imported on the TTS track:\n" .. m.regen_wav)
      else
        ui_set_banner("error",
          "The audio was generated, but the import failed:\n" ..
          (why or "(unknown)") .. "\n\nThe wav is at:\n" .. m.regen_wav)
      end
    else
      ui_set_banner("error", "Speech generation failed:\n" ..
                             _error_detail(600) ..
                             "\n\nFull log: " .. LOG_PATH)
    end
    V5.tts_pending = nil
    _ui_phase = back
    return
  end

  -- v0.11 voice preview: same --regen-chunk manifest as TTS, but the wav is
  -- only played — no track, no item, nothing to undo.
  if _run_mode == "preview" then
    local back = V5.preview_return_phase or "setup"
    local pend = V5.preview_pending
    if cancelled then
      ui_set_banner("warn", "Voice preview cancelled.")
    elseif m and m.status == "ok" and exit_code == 0
           and (m.regen_wav or "") ~= "" then
      V5.preview_last = { wav = m.regen_wav, txt = pend and pend.txt or "",
                          voice = pend and pend.voice or "",
                          text = pend and pend.text or "" }
      local ok, why = V5.play_wav(m.regen_wav)
      if ok then
        ui_set_banner("info", string.format(
          "Previewing %s — nothing was imported. Press 🔊 Test voice again " ..
          "to replay it.", V5.voice_label_for_banner(
            pend and pend.voice or "")))
      else
        ui_set_banner("warn",
          "The preview was generated, but playback failed:\n" ..
          (why or "(unknown)") .. "\n\nThe wav is at:\n" .. m.regen_wav)
      end
    else
      ui_set_banner("error", "Voice preview failed:\n" ..
                             _error_detail(600) ..
                             "\n\nFull log: " .. LOG_PATH)
    end
    V5.preview_pending = nil
    _ui_phase = back
    return
  end

  -- Chunk regeneration never owns the phase state: it reports back into the
  -- phase it was started from and leaves the last run's manifest untouched.
  if _run_mode == "regen" then
    local back = _regen_return_phase or "setup"
    if cancelled then
      ui_set_banner("warn", "Chunk regeneration cancelled.")
    elseif m and m.status == "ok" and exit_code == 0
           and (m.regen_wav or "") ~= "" then
      local ok, why = apply_regen_result(m.regen_wav)
      if ok then
        ui_set_banner("info", "Chunk regenerated and swapped in:\n"
                              .. m.regen_wav)
      else
        ui_set_banner("error", "Regen finished, but the item swap failed:\n"
                               .. (why or "(unknown)"))
      end
    else
      local detail = (m and m.error ~= "" and m.error) or nil
      if not detail then
        detail = read_all(LOG_PATH) or "(no output)"
        if #detail > 600 then detail = "...\n" .. detail:sub(-600) end
      end
      ui_set_banner("error", "Chunk regeneration failed:\n" .. detail ..
                             "\n\nFull log: " .. LOG_PATH)
    end
    _regen_pending = nil
    _ui_phase = back
    return
  end

  -- Staged run paused after the translation chain: open the review editor.
  if m and m.status == "review" and exit_code == 0 and not cancelled then
    local ok, why = enter_review_phase(m)
    if ok then return end
    _ui_failure = { error_tail = why or "(review manifest unusable)",
                    log_path = LOG_PATH }
    _manifest = m
    _ui_phase = "failure"
    return
  end

  -- v0.13 pause-aware dry run finished: open the plan gate. Nothing was
  -- generated and nothing was billed, so this is a pause, not a result.
  if m and m.status == "plan" and exit_code == 0 and not cancelled then
    local ok, why = V5.enter_plan_phase(m)
    if ok then return end
    _ui_failure = { error_tail = why or "(plan manifest unusable)",
                    log_path = LOG_PATH }
    _manifest = m
    _ui_phase = "failure"
    return
  end

  if m and m.status == "ok" and exit_code == 0 and not cancelled then
    _manifest    = m
    -- Remember (and persist) where this run's outputs live, so regen works
    -- in later REAPER sessions without re-picking engine_done.json.
    V5.set_regen_target(m.out_dir, m.language)
    -- v0.7: finished dub runs land in the per-project history.
    -- v0.13: a dubplan run is a finished dub too — it produces the same
    -- artifacts, so it belongs in history alongside the others.
    if _run_mode == "full" or _run_mode == "dub"
       or _run_mode == "dubplan" then
      V5.history_record("ok", m)
    end
    _ui_progress = 1.0
    _ui_phase    = "success"
    return
  end

  -- Failure: prefer the manifest's error text, else the log tail.
  local detail
  if m and m.error and m.error ~= "" then
    detail = m.error
  else
    local full_log = read_all(LOG_PATH) or (err or "(no output)")
    detail = full_log
    if #detail > 1600 then detail = "...\n" .. detail:sub(-1600) end
  end
  if cancelled then
    detail = "Cancelled by user.\n\n" .. detail
  end
  _ui_failure = { error_tail = detail, log_path = LOG_PATH }
  _manifest   = m   -- partial results may still be importable
  _ui_phase   = "failure"
end

-- Incremental log tail: track the last read size, read only new bytes,
-- carry any incomplete trailing line to the next poll.
local function poll_engine()
  -- Cancel was clicked before run_dub.py published the pid: keep retrying
  -- the kill until engine_pid.txt appears (or the run ends on its own).
  if _cancel_pending and not _ui_cancelled then
    if _try_cancel_kill() then
      _ui_cancelled   = true
      _cancel_pending = false
    end
  end

  local f = io.open(LOG_PATH, "rb")
  if f then
    local size = f:seek("end") or 0
    if size < _poll_last_size then
      -- run_dub.py recreated the status dir: start over.
      _poll_last_size = 0
      _poll_partial   = ""
    end
    if size > _poll_last_size then
      f:seek("set", _poll_last_size)
      local chunk = f:read(size - _poll_last_size) or ""
      _poll_last_size = size
      chunk = _poll_partial .. chunk
      local pos = 1
      while true do
        local nl = chunk:find("\n", pos, true)
        if not nl then break end
        local line = chunk:sub(pos, nl - 1):gsub("\r$", "")
        if line ~= "" then _handle_log_line(line) end
        pos = nl + 1
      end
      _poll_partial = chunk:sub(pos)
    end
    f:close()
  end

  -- Done? engine_done.txt is written LAST by run_dub.py.
  local done = read_all(DONE_PATH)
  if done and done:match("%-?%d") then
    if _poll_partial ~= "" then
      _handle_log_line((_poll_partial:gsub("\r$", "")))
      _poll_partial = ""
    end
    local exit_code = tonumber(done:match("(%-?%d+)")) or 1
    local elapsed = os.time() - _poll_start_time
    log_append(string.format(
      "──── engine finished in %ds (exit code %d) ────", elapsed, exit_code))
    _finish_run(exit_code)
    return
  end

  -- Watchdog: run_dub.py writes its "[run_dub] launching:" line within a
  -- couple of seconds of a successful start. If the log is still empty
  -- after 90 s, the launch failed in a way we could not detect.
  if _poll_last_size == 0 and (os.time() - _poll_start_time) > 90 then
    local why = "Python produced no output for 90 seconds — the launch " ..
                "probably failed.\n\nThings to check:\n" ..
                "  - the project venv exists and runs (" ..
                project_venv_python() .. ")\n" ..
                "    — run " .. SETUP_SCRIPT .. " once; it also rebuilds " ..
                "a broken venv\n" ..
                "  - the interpreter path is valid\n" ..
                "  - engine/run_dub.py exists next to this script's folder"
    -- v0.21: THIS is what used to drag the panel onto the Dub failure screen
    -- after a voice fetch that never started. A quiet job reports in its own
    -- banner and hands the engine back; the phase it was fired from is none
    -- of its business.
    if V5.quiet_job then
      V5.quiet_job = nil
      ui_set_banner("error", "Voice fetch could not start.\n\n" .. why ..
                             "\n\nFull log: " .. LOG_PATH)
      return
    end
    _ui_failure = { error_tail = why, log_path = LOG_PATH }
    _ui_phase   = "failure"
  end
end

-- ---------------------------------------------------------------------------
-- UI renderers — one window, four phases
-- ---------------------------------------------------------------------------

local function _stage_line()
  if _run_mode == "regen"        then return "Regenerating chunk audio (TTS)…" end
  if _run_mode == "test_llm"     then return "Testing LLM connection…" end
  if _run_mode == "list_voices"  then return "Fetching ElevenLabs voices…" end
  if _run_mode == "tts"          then return "Generating speech (ElevenLabs)…" end
  if _run_mode == "preview"      then return "Generating a voice preview…" end
  if _run_mode == "voice_change" then
    return "Changing track voice (ElevenLabs speech-to-speech)…"
  end
  if not _ui_stage_tag then return "Starting engine…" end
  return string.format("[%s]  %s", _ui_stage_tag,
                       STAGE_LABELS[_ui_stage_tag] or "Working…")
end

-- ─── Log typeface ─────────────────────────────────────────
-- The engine log reads like a terminal, so it gets terminal type: small and
-- monospaced. The UI font is proportional and was pushed at 16 px here, which
-- made 300 lines of paths, stage tags and counts far harder to scan than a
-- cmd window showing the same thing.
V5.LOG_PX = 13           -- raise this if it reads too small on your display
V5.mono   = nil          -- nil = not looked for yet, false = nothing to load

function V5.mono_font(ctx)
  if V5.mono ~= nil then return V5.mono or nil end
  V5.mono = false
  if not (reaper.ImGui_CreateFontFromFile or reaper.ImGui_CreateFont) then
    return nil
  end
  local paths
  if _is_windows() then
    paths = { "C:/Windows/Fonts/consola.ttf",
              "C:/Windows/Fonts/CascadiaMono.ttf",
              "C:/Windows/Fonts/CascadiaCode.ttf",
              "C:/Windows/Fonts/lucon.ttf",
              "C:/Windows/Fonts/cour.ttf" }
  else
    paths = { "/System/Library/Fonts/SFNSMono.ttf",
              "/System/Library/Fonts/Menlo.ttc",
              "/System/Library/Fonts/Monaco.dfont",
              "/System/Library/Fonts/Supplemental/Courier New.ttf" }
  end
  for _, p in ipairs(paths) do
    if file_exists(p) then
      -- Same 0.10-vs-older split as _create_script_font: the newer API takes
      -- the size at PushFont time, the older one bakes it here.
      local ok, font
      if reaper.ImGui_CreateFontFromFile then
        ok, font = pcall(reaper.ImGui_CreateFontFromFile, p, 0, 0)
      else
        ok, font = pcall(reaper.ImGui_CreateFont, p, V5.LOG_PX)
      end
      if ok and font and pcall(reaper.ImGui_Attach, ctx, font) then
        V5.mono = font
        return font
      end
    end
  end
  return nil
end

local function _render_log_child(ctx, height)
  if reaper.ImGui_BeginChild(ctx, '##loglines', -1, height, _child_border_flag()) then
    local mono = V5.mono_font(ctx)
    local pushed = mono and pcall(reaper.ImGui_PushFont, ctx, mono, V5.LOG_PX)
    if mono and not pushed then
      pushed = pcall(reaper.ImGui_PushFont, ctx, mono)
    end
    -- No monospace on this machine: at least make the UI font small.
    local pushed_ui = (not pushed) and _push_font(ctx, V5.LOG_PX + 1)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBBBBBFF)
    -- Terminal line spacing. ImGui's default gap between Text calls is a lot
    -- of air once the glyphs are this small.
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 4.0, 1.0)
    local start = math.max(1, #_log_buffer - 300)
    for i = start, #_log_buffer do
      local line = _log_buffer[i]
      if pushed and line:find("[\128-\255]") then
        -- Consolas has no Devanagari. A log line carrying translated text
        -- goes back to the script font instead of drawing as a row of boxes.
        local p = _push_font(ctx, V5.LOG_PX + 2)
        reaper.ImGui_Text(ctx, line)
        if p then _pop_font(ctx) end
      else
        reaper.ImGui_Text(ctx, line)
      end
    end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx)
    if pushed or pushed_ui then _pop_font(ctx) end
    if _log_autoscroll then reaper.ImGui_SetScrollHereY(ctx, 1.0) end
    reaper.ImGui_EndChild(ctx)
  end
  local rv
  rv, _log_autoscroll = reaper.ImGui_Checkbox(ctx, 'Auto-scroll', _log_autoscroll)
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Open log in editor') then
    if file_exists(LOG_PATH) then open_path(LOG_PATH) end
  end
end

-- ─── Regen target persistence (v0.6) ─────────────────────────
-- The regen out_dir used to live only in session-local state, so every new
-- REAPER session forced a manual "pick engine_done.json" before the first
-- regen (the panel forgets it on restart; regen-mode manifests carry no
-- out_dir, so the status-dir engine_done.json alone is not enough either).
-- Persist the target per project as a manifest-shaped sidecar and reload
-- it automatically.
-- CRITICAL: the sidecar must NOT live inside the per-project status dir —
-- run_dub.py deletes that whole directory (shutil.rmtree) at EVERY launch,
-- so a sidecar stored there died on the very next run (including the regen
-- run itself) and the picker came back each session. It lives in the
-- status ROOT instead, named after the project slug: launches never
-- wholesale-clean the root (legacy no---status-dir launches remove only
-- the four fixed status filenames there).
-- (All in the V5 table — the main chunk is near Lua's 200-local limit.)

function V5.regen_target_path()
  -- Slug taken from STATUS_DIR (not recomputed from the current project):
  -- STATUS_DIR stays pinned to the launched project for a run in flight,
  -- so a finish-time write can never land under another project's slug.
  local slug = STATUS_DIR:match("([^/\\]+)$") or "default"
  return V5.STATUS_ROOT .. SEP .. "regen_target_" .. slug .. ".json"
end

-- Single setter for the regen target: updates the session state AND writes
-- the per-project sidecar (shaped like a mini manifest, so the tolerant
-- load_manifest_json reader parses it back).
function V5.set_regen_target(out_dir, lang)
  if (out_dir or "") == "" then return end
  _regen_out_dir = out_dir
  if (lang or "") ~= "" then _regen_lang = lang end
  reaper.RecursiveCreateDirectory(V5.STATUS_ROOT, 0)
  local f = io.open(V5.regen_target_path(), "wb")
  if f then
    f:write(string.format('{"status":"ok","out_dir":"%s","language":"%s"}\n',
                          _json_escape(_regen_out_dir),
                          _json_escape(_regen_lang)))
    f:close()
  end
end

-- Called when the regen section renders with no target. Probes once per
-- status dir: the last full-run manifest in this project's status dir,
-- then the persisted sidecar (survives both regen runs overwriting
-- engine_done.json AND run_dub.py's wholesale status-dir clean), then the
-- pre-relocation sidecar location, then the legacy shared status root.
function V5.prefill_regen_target()
  if _regen_out_dir ~= "" then return end
  -- Same guard as preflight: only re-point the status paths while idle on
  -- setup — a run in flight keeps the paths it launched with.
  if _ui_phase == "setup" then V5.set_status_paths() end
  if V5.regen_prefill_done == STATUS_DIR then return end
  V5.regen_prefill_done = STATUS_DIR
  local probes = { DONE_JSON,
                   V5.regen_target_path(),
                   STATUS_DIR .. SEP .. "regen_target.json",
                   V5.STATUS_ROOT .. SEP .. "engine_done.json" }
  for _, p in ipairs(probes) do
    if file_exists(p) then
      local m = load_manifest_json(p)
      if m and m.status == "ok" and (m.out_dir or "") ~= "" then
        V5.set_regen_target(m.out_dir, m.language)
        return
      end
    end
  end
end

-- Shared "pick engine_done.json" dialog (first-time picker + Change…).
function V5.pick_regen_manifest()
  local ok, picked = reaper.GetUserFileNameForRead(
    "", "Pick engine_done.json of a finished run", "json")
  if not ok or not picked or picked == "" then return end
  local m, why = load_manifest_json(picked)
  if m and (m.out_dir or "") ~= "" then
    V5.set_regen_target(m.out_dir, m.language)
  else
    ui_set_banner("error", why or ("No out_dir in that manifest:\n" .. picked))
  end
end

-- ─── Regen section (the "Redo one line" tool) ────────────────
-- Reads the currently selected media item, loads its note into an editable
-- text box and offers "⟳ Regenerate". The out_dir comes from the last
-- manifest this panel saw, the persisted per-project regen target, or a
-- manually picked engine_done.json.
--
-- v0.18: the line is shown IN CONTEXT (the chunk before and after it, its
-- number, its slot), with a fit meter that says — before you spend anything —
-- whether the text you just typed will still fit the gap it has to land in.
-- Overruns are the failure mode this tool exists to cause: in Match mode a
-- chunk that runs long is parked on the Un sync track, and until now nothing
-- warned you until after the credits were gone.

-- Trim to *n* characters on one line, without cutting a UTF-8 sequence in half
-- (Indic text is three bytes a glyph — a byte-wise sub() produces mojibake).
function V5.ellipsis(s, n)
  s = tostring(s or ''):gsub('%s+', ' '):match('^%s*(.-)%s*$')
  if V5.char_count(s) <= n then return s end
  local out, c = {}, 0
  for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
    c = c + 1
    if c > n then break end
    out[#out + 1] = ch
  end
  return table.concat(out) .. '…'
end

-- Where this item sits among the chunks on its own track: index, total, and
-- the items either side of it. Position order, not creation order — the track
-- is a timeline, and that is the order the listener hears.
function V5.chunk_context(item)
  local tr = item and reaper.GetMediaItem_Track(item)
  if not tr then return 0, 0, nil, nil end
  local n = reaper.CountTrackMediaItems(tr)
  local list = {}
  for i = 0, n - 1 do list[#list + 1] = reaper.GetTrackMediaItem(tr, i) end
  table.sort(list, function(a, b)
    return reaper.GetMediaItemInfo_Value(a, "D_POSITION")
         < reaper.GetMediaItemInfo_Value(b, "D_POSITION")
  end)
  for i, it in ipairs(list) do
    if it == item then return i, #list, list[i - 1], list[i + 1] end
  end
  return 0, #list, nil, nil
end

-- Make *it* the selected chunk, and take the arrange view with you. Fixing a
-- pass of bad lines is a walk along the track, and until this existed every
-- step meant leaving the panel to click the next item.
function V5.select_chunk(it)
  if not it then return end
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(it, true)
  -- moveview = true: an item off the right-hand edge is the whole reason to
  -- have this button, so the view has to follow the cursor.
  reaper.SetEditCurPos(reaper.GetMediaItemInfo_Value(it, "D_POSITION"),
                       true, false)
  reaper.UpdateArrange()
end

-- One neighbouring line, dim and one row tall. Its job is to remind you what
-- this chunk has to sit between, not to be read closely. Clicking it steps
-- there — the line you are reading is the line you want next.
function V5.chunk_neighbour(ctx, it, tag)
  if not it then return end
  local txt = V5.ellipsis(V5.get_item_text(it), 72)
  if txt == '' then txt = '(no text stored on that item)' end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.faint)
  if reaper.ImGui_Selectable then
    if reaper.ImGui_Selectable(ctx, tag .. '  ' .. txt .. '##nb' .. tag) then
      V5.select_chunk(it)
    end
  else
    reaper.ImGui_Text(ctx, tag .. '  ' .. txt)
  end
  reaper.ImGui_PopStyleColor(ctx)
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(
      'Go to this chunk. Anything you typed above and did not regenerate is ' ..
      'dropped, the same as selecting it in the arrange view.'))
  end
end

local function ui_regen_section(ctx)
  V5.prefill_regen_target()
  V5.script_font_warning(ctx)

  if _regen_out_dir == "" then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn_text)
    reaper.ImGui_TextWrapped(ctx,
      'Output folder unknown — pick the engine_done.json of a finished run.')
    reaper.ImGui_PopStyleColor(ctx)
    if reaper.ImGui_Button(ctx, 'Pick engine_done.json…') then
      V5.pick_regen_manifest()
    end
  end

  local item = reaper.CountSelectedMediaItems(0) > 0
               and reaper.GetSelectedMediaItem(0, 0) or nil
  if not item then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
    reaper.ImGui_TextWrapped(ctx,
      'Select a dub chunk item in the arrange view (on a "Dub Chunks" ' ..
      'track) to edit its text and regenerate its audio.')
    reaper.ImGui_PopStyleColor(ctx)
    _ui_begin_disabled(ctx, true)
    reaper.ImGui_Button(ctx, '⟳ Regenerate', 150, 30)
    _ui_end_disabled(ctx)
    return
  end

  -- Reload the text box from the item note whenever the selection changes
  -- (deliberately discards edits made for a different item).
  local guid = _item_guid(item)
  if guid ~= _regen_sel_guid then
    _regen_sel_guid = guid
    _regen_text = V5.get_item_text(item)
  end

  local tr = reaper.GetMediaItem_Track(item)
  local _, tname = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local slot = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local idx, total, prev_it, next_it = V5.chunk_context(item)

  -- ── Where you are ───────────────────────────────────────
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
  reaper.ImGui_Text(ctx, string.format('%s  ·  chunk %d of %d',
    (tname ~= "" and tname or "(unnamed track)"), idx, total))
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
  reaper.ImGui_Text(ctx, string.format('%s → %s   (%s slot)',
    V5.fmt_pos(pos), V5.fmt_pos(pos + slot), V5.fmt_dur(slot)))
  reaper.ImGui_PopStyleColor(ctx)

  -- Step to the chunk either side without leaving the panel. '↑'/'↓' rather
  -- than arrows this font may not carry — they are the same two glyphs the
  -- neighbour rows below are already tagged with.
  reaper.ImGui_SameLine(ctx, 0, 12)
  _ui_begin_disabled(ctx, prev_it == nil)
  if reaper.ImGui_SmallButton(ctx, '↑##chunkprev') and prev_it then
    V5.select_chunk(prev_it)
  end
  _ui_end_disabled(ctx)
  reaper.ImGui_SameLine(ctx, 0, 4)
  _ui_begin_disabled(ctx, next_it == nil)
  if reaper.ImGui_SmallButton(ctx, '↓##chunknext') and next_it then
    V5.select_chunk(next_it)
  end
  _ui_end_disabled(ctx)
  V5.hint(ctx, 'Move to the chunk before or after this one — the arrange ' ..
               'view follows. A line you typed but did not regenerate is ' ..
               'dropped, exactly as it is when you click another item.')

  reaper.ImGui_Dummy(ctx, 0, 4)
  V5.chunk_neighbour(ctx, prev_it, '↑')

  -- ── The line itself ─────────────────────────────────────
  local pushed = _push_font(ctx, 17)
  local rv, txt = reaper.ImGui_InputTextMultiline(
    ctx, '##regentext', _regen_text or '', -1, 74)
  if pushed then _pop_font(ctx) end
  if rv then _regen_text = txt end

  -- ── Will it still fit? ──────────────────────────────────
  -- The speaking rate is measured from THIS chunk rather than assumed: its
  -- own stored text over its own slot length is the real rate of this voice,
  -- in this language, for this project. Falls back to the global estimate for
  -- an item with no text stored on it.
  local on_timeline = V5.get_item_text(item) or ''
  local cps = V5.SPEECH_CPS
  if slot > 0.2 and V5.char_count(on_timeline) > 8 then
    cps = V5.char_count(on_timeline) / slot
  end
  local est  = V5.speech_secs(_regen_text or '', cps)
  local frac = (slot > 0) and (est / slot) or 0
  local over = est > slot + 0.05

  if reaper.ImGui_ProgressBar then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PlotHistogram(),
                                over and 0xB9832AFF or V5.COL.go)
    reaper.ImGui_ProgressBar(ctx, math.min(1.0, frac), -1, 7, '')
    reaper.ImGui_PopStyleColor(ctx)
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                              over and V5.COL.warn or V5.COL.step_ok)
  if (_regen_text or '') == '' then
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
    reaper.ImGui_Text(ctx, 'type the corrected line above')
  elseif over then
    reaper.ImGui_TextWrapped(ctx, string.format(
      'too long — about %.1f s of speech for a %.1f s slot, so this chunk ' ..
      'will overrun. In Match mode it lands on the Un sync track.', est, slot))
  else
    reaper.ImGui_Text(ctx, string.format(
      'fits — about %.1f s of speech in a %.1f s slot', est, slot))
  end
  reaper.ImGui_PopStyleColor(ctx)

  V5.chunk_neighbour(ctx, next_it, '↓')

  -- ── Do it ───────────────────────────────────────────────
  reaper.ImGui_Dummy(ctx, 0, 4)
  local can = _regen_out_dir ~= "" and (_regen_text or ""):match("%S") ~= nil
  -- v0.21: V5.busy() too — one engine job at a time, and a voice fetch is one.
  _ui_begin_disabled(ctx, not can or V5.busy())
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        V5.COL.job)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), V5.COL.job_hi)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  V5.COL.job_act)
  if reaper.ImGui_Button(ctx, '⟳  Regenerate this line', 210, 30) and can then
    start_regen(item, _regen_text, V5.regen_voice)
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  _ui_end_disabled(ctx)
  reaper.ImGui_SameLine(ctx)
  if not can then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
    reaper.ImGui_Text(ctx, _regen_out_dir == "" and 'need an output folder'
                           or 'text is empty')
    reaper.ImGui_PopStyleColor(ctx)
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
    reaper.ImGui_Text(ctx, string.format('~%d credits · nothing overwritten',
                                         V5.credit_est(_regen_text)))
    reaper.ImGui_PopStyleColor(ctx)
  end

  -- ── The take that came back ─────────────────────────────
  -- Regen writes to regen/ and swaps the take; V5.regen_undo remembers what
  -- was there, so the new one can be compared and undone here rather than
  -- through REAPER's undo stack.
  local u = V5.regen_undo
  if u and u.guid == guid then
    reaper.ImGui_Dummy(ctx, 0, 6)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xDDDDDDFF)
    reaper.ImGui_Text(ctx, 'The new take is on the timeline')
    reaper.ImGui_PopStyleColor(ctx)
    _grey_hint(ctx, string.format('%s%s  ·  the take it replaced is still at %s',
      basename(u.new_wav or ''),
      (u.new_len or 0) > 0 and ('  ·  ' .. V5.fmt_dur(u.new_len)) or '',
      (u.old_path or '') ~= '' and basename(u.old_path) or '(unknown)'))

    if V5.chip(ctx, '▶ Play the new take##abnew',
               'Play the regenerated wav on its own — nothing on the ' ..
               'timeline moves.') then
      local ok, why = V5.play_wav(u.new_wav)
      if not ok then ui_set_banner("warn", why or "Playback failed.") end
    end
    if (u.old_path or '') ~= '' and file_exists(u.old_path) then
      reaper.ImGui_SameLine(ctx)
      if V5.chip(ctx, '▶ Play the old one##abold',
                 'Play the take that was there before, for comparison.') then
        local ok, why = V5.play_wav(u.old_path)
        if not ok then ui_set_banner("warn", why or "Playback failed.") end
      end
    end
    reaper.ImGui_SameLine(ctx)
    if V5.chip(ctx, 'Keep it##abkeep', 'Stop offering to put the old one back.')
    then
      V5.regen_undo = nil
      ui_set_banner("info", "Kept. The previous take is still on disk.")
    end
    reaper.ImGui_SameLine(ctx)
    if V5.chip(ctx, 'Put the old one back##abrevert',
               'Swap the previous take back in. The new wav stays in regen/, ' ..
               'so this is reversible too.', true) then
      local ok, why = V5.regen_revert()
      ui_set_banner(ok and "info" or "error",
        ok and "The previous take is back on the timeline."
        or (why or "Could not revert."))
      if ok then _regen_text = V5.get_item_text(item) end
    end
  end

  -- ── Optional: a different voice ─────────────────────────
  -- v0.8: same text, different voice. Behind a reveal because leaving it
  -- alone is the common case — regen then behaves as it always did.
  reaper.ImGui_Dummy(ctx, 0, 6)
  local use_id = ((V5.regen_voice or "") ~= "" and V5.regen_voice)
                 or (VOICE_ID or "")
  local use_nm = V5.voice_name(use_id)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
  reaper.ImGui_Text(ctx, 'Voice: ' .. (use_id == "" and
    'none set — the engine picks one from your account'
    or ((use_nm ~= "" and use_nm or use_id) ..
        ((V5.regen_voice or "") == "" and '  (the default voice)'
         or '  (just for this line)'))))
  reaper.ImGui_PopStyleColor(ctx)

  -- Where the new wavs are written. Dim, at the bottom: it matters once (when
  -- it is wrong, because the panel is pointed at another project's run).
  if _regen_out_dir ~= "" then
    _grey_hint(ctx, 'New takes are written to ' .. _regen_out_dir .. SEP ..
                    'regen')
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, 'Change…##regendir') then
      V5.pick_regen_manifest()
    end
  end

  if V5.advanced(ctx, 'regenvoice', 'Redo it in a different voice') then
    reaper.ImGui_Indent(ctx, 12)
    V5.regen_voice = V5.ui_voice_picker(ctx, 'regen', V5.regen_voice, 'Voice')
    local rvv
    rvv, V5.regen_voice = reaper.ImGui_InputText(ctx, 'Voice id##regenid',
                                                 V5.regen_voice or '')
    if (V5.regen_voice or "") ~= "" then
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_SmallButton(ctx, 'Use the default##regenclr') then
        V5.regen_voice = ""
      end
    end
    -- v0.11: say what "🔊 Test voice" above will actually speak — the chunk's
    -- own words, so the audition matches the regen it is standing in for.
    _grey_hint(ctx, '🔊 Test voice speaks the start of this chunk in the ' ..
                    'picked voice and plays it — nothing is imported or ' ..
                    'replaced.')
    reaper.ImGui_Unindent(ctx, 12)
  end
end

-- ─── 🎤 Change track voice (setup + success phases) ──────────
-- Pick any project track and a target ElevenLabs voice: the track is
-- rendered to a wav, converted with the ElevenLabs voice changer
-- (speech-to-speech keeps timing/pacing — a synced dub stays synced) and
-- imported as a new track below the original. The original is muted only.
-- ---------------------------------------------------------------------------
-- v0.7 voice bookmarks + shared voice picker.
--
-- Scrolling the whole ElevenLabs catalogue to find the same few voices got
-- old fast, so voices can be starred. Bookmarks live in their own file next
-- to the panel settings (same {"voices":[{id,name}]} shape the --list-voices
-- manifest uses, so parse_voices_json reads them as-is) and are GLOBAL: they
-- follow the user across projects and languages, unlike the fetched
-- catalogue, which is per-language and lost when the panel closes.
--
-- V5 fields, not locals — the main chunk is at Lua's 200-local limit.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- v0.7 user-added languages + prompt editing.
--
-- A language is just a name plus five prompt files. config/custom_languages.json
-- carries the name/code/tag; pipeline/config.py merges each entry into
-- TTS_LANGUAGES, and dub_engine.py / run_dub.py extend their --language choices
-- from the same file. Adding one here therefore needs no code change anywhere:
-- write the JSON, seed the five prompts from a language that already works.
-- ---------------------------------------------------------------------------

V5.CUSTOM_LANGS_PATH = CONFIG_DIR .. SEP .. "custom_languages.json"
V5.PROMPTS_DIR       = BASE_DIR .. SEP .. "prompts"
V5.PROMPT_STAGES = { "Step1_Translation_Prompt", "Step2_Review_Prompt",
                     "Step3_Punctuation_Prompt", "Step4_Emotion_Prompt",
                     "SyncingPrompt" }
V5.custom_langs = {}     -- { {name=, code=, tag=}, … }

-- Generic reader for `"<key>": [ {flat string fields}, … ]`, using the real
-- JSON string decoder so quotes/escapes inside values can never derail it.
function V5.json_object_array(text, key)
  local out = {}
  if not text then return out end
  local a, b = text:find('"' .. key .. '"', 1, true)
  if not a then return out end
  local i = skip_ws(text, b + 1)
  if text:sub(i, i) ~= ":" then return out end
  i = skip_ws(text, i + 1)
  if text:sub(i, i) ~= "[" then return out end
  i = i + 1
  while i <= #text do
    i = skip_ws(text, i)
    local c = text:sub(i, i)
    if c == "]" or c == "" then break end
    if c == "{" then
      local obj = {}
      i = i + 1
      while i <= #text do
        i = skip_ws(text, i)
        local cc = text:sub(i, i)
        if cc == "}" then i = i + 1 break end
        if cc == '"' then
          local k; k, i = decode_json_string(text, i)
          i = skip_ws(text, i)
          if text:sub(i, i) == ":" then
            i = skip_ws(text, i + 1)
            if text:sub(i, i) == '"' then
              local val; val, i = decode_json_string(text, i)
              obj[k] = val
            else
              -- Non-string value (a number, or the el_tokens array): skip it.
              local depth, j = 0, i
              while j <= #text do
                local ch = text:sub(j, j)
                if ch == "[" or ch == "{" then depth = depth + 1
                elseif ch == "]" or ch == "}" then
                  if depth == 0 then break end
                  depth = depth - 1
                elseif ch == "," and depth == 0 then break end
                j = j + 1
              end
              i = j
            end
          end
        else
          i = i + 1
        end
      end
      if next(obj) then out[#out + 1] = obj end
    else
      i = i + 1
    end
  end
  return out
end

-- config/custom_languages.json is hand-editable, and whatever `name` it
-- carries ends up on the engine command line via build_engine_cmd.
--
-- VALIDATE AND REJECT — never rewrite. This file is read independently by the
-- panel and by three Python readers (run_dub.py, dub_engine.py and
-- pipeline/config.py), none of which normalise the name. Silently cleaning a
-- name here would give the same entry two different spellings: a hand-edited
-- "C++" would show in the panel as "C" and launch as --language "C", while
-- the engine registered only "C++" and rejected the run as an unknown
-- language. Dropping the entry outright is honest and debuggable; rewriting
-- it is neither. Same policy as _sanitize_voice_id() in pipeline/stt.py,
-- which documents the identical reasoning for voice IDs.
--
-- Every shell metacharacter is ASCII, so allowing all bytes >= 0x80 keeps
-- non-Latin autonyms (हिन्दी, বাংলা) valid. Rejected names are recorded in
-- V5.custom_langs_rejected and shown in the Settings > Languages section, so
-- a dropped entry is diagnosable instead of silently vanishing.
--
-- KEEP IN SYNC — the same rule is enforced by the three Python readers of
-- this file, which each carry their own stdlib-only copy (the file is read
-- four times in total, by design, so argparse choices exist before any heavy
-- import):
--     engine/run_dub.py            _LANG_NAME_OK
--     engine/dub_engine.py         _LANG_NAME_OK
--     engine/pipeline/config.py    _LANG_NAME_OK
-- A literal space is allowed but %s is NOT used: tabs and newlines are never
-- part of a real language name and must not survive into an argument.
-- On V5 rather than a file-level `local` — see V5.STATUS_EXT_SECTION for why
-- this chunk cannot afford another top-level local.
-- The length bound is 64 UTF-8 BYTES, not characters, and the Python copies
-- measure len(name.encode("utf-8")) so the two agree exactly. Measuring Lua's
-- #s against Python's len() would not: 33 accented letters are 33 code points
-- but 66 bytes, and the two sides would disagree about that name.
--
-- The value is validated EXACTLY as it appears in the file — callers must not
-- trim first. Trimming is a rewrite: " Hindi " would validate as "Hindi" and
-- then be used under a name the JSON does not contain, which is the same
-- two-spellings bug this whole rule exists to prevent. A name that starts or
-- ends with a space is therefore rejected and reported, not quietly cleaned.
-- Unicode whitespace is rejected ANYWHERE in the name, as UTF-8 byte
-- sequences. Lua's %s only knows ASCII whitespace, so without this a
-- non-breaking space would sail through the \128-\255 range here while
-- Python's str.strip() treats it as whitespace — the two sides would then
-- disagree about "<NBSP>Hindi", and a name made entirely of non-breaking
-- spaces would be a valid, invisible language. Covers U+00A0, U+1680,
-- U+2000..U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 and U+FEFF.
function V5._has_unicode_space(s)
  return s:find("\194\160") ~= nil                      -- U+00A0
      or s:find("\225\154\128") ~= nil                  -- U+1680
      or s:find("\226\128[\128-\138\168\169\175]") ~= nil  -- U+2000-200A/2028/2029/202F
      or s:find("\226\129\159") ~= nil                  -- U+205F
      or s:find("\227\128\128") ~= nil                  -- U+3000
      or s:find("\239\187\191") ~= nil                  -- U+FEFF
end

function V5._is_safe_lang_name(s)
  if type(s) ~= "string" or s == "" or #s > 64 then return false end
  if s:find("^%s") or s:find("%s$") then return false end
  if V5._has_unicode_space(s) then return false end
  return s:find("^[%w %-_.()\128-\255]+$") ~= nil
end

function V5.custom_langs_load()
  V5.custom_langs = {}
  V5.custom_langs_rejected = {}
  for _, e in ipairs(V5.json_object_array(read_all(V5.CUSTOM_LANGS_PATH),
                                          "languages")) do
    -- Validated verbatim — no trim. See V5._is_safe_lang_name.
    local raw  = tostring(e.name or "")
    local name = raw
    if not V5._is_safe_lang_name(name) then
      -- Record the original string so the warning shows the actual offending
      -- value, including any stray whitespace that caused the rejection.
      if raw ~= "" then
        V5.custom_langs_rejected[#V5.custom_langs_rejected + 1] = raw
      end
      name = ""
    end
    if name ~= "" then
      V5.custom_langs[#V5.custom_langs + 1] =
        { name = name, code = e.code or "", tag = e.tag or "" }
      local known = false
      for _, l in ipairs(LANGUAGES) do
        if l == name then known = true break end
      end
      if not known then LANGUAGES[#LANGUAGES + 1] = name end
    end
  end
  -- A language added by hand lands wherever the JSON happened to list it, so
  -- re-sort: the drop-downs are alphabetical or they are nothing.
  table.sort(LANGUAGES)
end

function V5.custom_langs_save()
  reaper.RecursiveCreateDirectory(CONFIG_DIR, 0)
  local f = io.open(V5.CUSTOM_LANGS_PATH, "wb")
  if not f then return false end
  f:write('{\n  "languages": [\n')
  for i, l in ipairs(V5.custom_langs) do
    f:write(string.format(
      '    {"name": "%s", "code": "%s", "tag": "%s"}%s\n',
      _json_escape(l.name), _json_escape(l.code or ""),
      _json_escape(l.tag or ""), i < #V5.custom_langs and "," or ""))
  end
  f:write('  ]\n}\n')
  f:close()
  return true
end

function V5.prompt_path(lang, stage)
  return V5.PROMPTS_DIR .. SEP .. stage .. "_" .. lang .. ".txt"
end

-- Copy the five prompts of *from_lang* to *to_lang*, never overwriting an
-- existing file. Returns copied, skipped, missing.
function V5.prompts_seed(from_lang, to_lang)
  local copied, skipped, missing = 0, 0, {}
  for _, stage in ipairs(V5.PROMPT_STAGES) do
    local src = V5.prompt_path(from_lang, stage)
    local dst = V5.prompt_path(to_lang, stage)
    if file_exists(dst) then
      skipped = skipped + 1
    else
      local body = read_all(src)
      if not body then
        missing[#missing + 1] = stage
      else
        local f = io.open(dst, "wb")
        if f then f:write(body); f:close(); copied = copied + 1
        else missing[#missing + 1] = stage end
      end
    end
  end
  return copied, skipped, missing
end

-- Prompt editor state.
V5.prompt_lang  = nil
V5.prompt_stage = 1
V5.prompt_text  = ""
V5.prompt_dirty = false
V5.prompt_open  = ""      -- path currently loaded ("" = nothing yet)

function V5.prompt_editor_load(lang, stage_idx)
  local stage = V5.PROMPT_STAGES[stage_idx] or V5.PROMPT_STAGES[1]
  local path = V5.prompt_path(lang, stage)
  V5.prompt_lang, V5.prompt_stage = lang, stage_idx
  V5.prompt_text = read_all(path) or ""
  V5.prompt_open = path
  V5.prompt_dirty = false
  return file_exists(path)
end

function V5.prompt_editor_save()
  if V5.prompt_open == "" then return false, "No prompt loaded." end
  reaper.RecursiveCreateDirectory(V5.PROMPTS_DIR, 0)
  local f = io.open(V5.prompt_open, "wb")
  if not f then return false, "Could not write:\n" .. V5.prompt_open end
  f:write(V5.prompt_text or "")
  f:close()
  V5.prompt_dirty = false
  return true
end

V5.custom_langs_load()

V5.BOOKMARKS_PATH = SCRIPT_DIR .. SEP .. "voice_bookmarks.json"
V5.bookmarks      = {}      -- { {id=, name=}, … }
V5.voice_filter   = {}      -- per-picker search text, keyed by widget id

function V5.bookmarks_load()
  V5.bookmarks = parse_voices_json(read_all(V5.BOOKMARKS_PATH) or "")
end

function V5.bookmarks_save()
  local f = io.open(V5.BOOKMARKS_PATH, "wb")
  if not f then return false end
  f:write('{\n  "voices": [\n')
  for i, v in ipairs(V5.bookmarks) do
    f:write(string.format('    {"id": "%s", "name": "%s"}%s\n',
      _json_escape(v.id or ""), _json_escape(v.name or ""),
      i < #V5.bookmarks and "," or ""))
  end
  f:write('  ]\n}\n')
  f:close()
  return true
end

-- ---------------------------------------------------------------------------
-- v0.11: the fetched catalogue survives a panel restart.
--
-- Until now --list-voices filled an in-memory list that died with the panel,
-- so every session started with an empty combo and the only way to refill it
-- was ⚙ Settings. The last fetch is now mirrored to voice_cache.json next to
-- the bookmarks ({"language": …, "voices":[{id,name}]} — parse_voices_json
-- reads the array as-is) and loaded at startup, so Regen / Track Voice /
-- Text to Speech open with a usable voice list.
-- ---------------------------------------------------------------------------
V5.VOICE_CACHE_PATH = SCRIPT_DIR .. SEP .. "voice_cache.json"

function V5.voice_cache_load()
  local raw = read_all(V5.VOICE_CACHE_PATH) or ""
  local voices = parse_voices_json(raw)
  if #voices == 0 then return end
  _voices = voices
  -- Language names are argparse choices: plain ASCII, no escapes to decode.
  _voices_language = raw:match('"language"%s*:%s*"([^"]*)"') or ""
end

function V5.voice_cache_save()
  local f = io.open(V5.VOICE_CACHE_PATH, "wb")
  if not f then return false end
  f:write(string.format('{\n  "language": "%s",\n  "voices": [\n',
                        _json_escape(_voices_language or "")))
  for i, v in ipairs(_voices) do
    f:write(string.format('    {"id": "%s", "name": "%s"}%s\n',
      _json_escape(v.id or ""), _json_escape(v.name or ""),
      i < #_voices and "," or ""))
  end
  f:write('  ]\n}\n')
  f:close()
  return true
end

-- ---------------------------------------------------------------------------
-- v0.11: audition a voice BEFORE spending a regen on it.
--
-- "🔊 Test voice" synthesizes a short sample with the currently picked voice
-- and plays it outside the timeline — nothing is imported, no item is
-- touched. The sample is the text that voice would actually speak (the
-- selected chunk in Regen Audio, the Text to Speech box), trimmed to keep
-- the audition cheap; anywhere else it falls back to a fixed sentence.
--
-- Re-pressing the button with the same voice AND the same text replays the
-- wav that is already on disk instead of paying ElevenLabs twice.
-- ---------------------------------------------------------------------------
V5.PREVIEW_DIR    = ENGINE_DIR .. SEP .. "preview"
V5.PREVIEW_SAMPLE = "This is a short voice preview from the dubbing panel."
V5.PREVIEW_MAX    = 220        -- bytes of sample text sent to ElevenLabs
V5.preview_pending      = nil  -- { out_wav, voice, text } while running
V5.preview_return_phase = "setup"
V5.preview_last         = nil  -- { wav, voice, text } of the last good one

-- Trim to V5.PREVIEW_MAX bytes without splitting a UTF-8 character (Indic
-- text is multi-byte throughout) and, when possible, without splitting a word.
function V5.preview_trim(s)
  s = (s or ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if #s <= V5.PREVIEW_MAX then return s end
  local cut = V5.PREVIEW_MAX
  -- Walk back off continuation bytes (10xxxxxx) so the cut lands on a
  -- character boundary.
  while cut > 1 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b > 0xBF then break end
    cut = cut - 1
  end
  local space = s:sub(1, cut):match("^.*()%s")
  if space and space > V5.PREVIEW_MAX * 0.5 then cut = space - 1 end
  return s:sub(1, cut) .. "…"
end

-- What the "🔊 Test voice" button next to each picker should speak.
function V5.preview_text(key)
  local t = ""
  if key == 'regen' then
    t = _regen_text or ""
  elseif key == 'tts' then
    t = V5.tts_text or ""
  end
  if not t:match("%S") then t = V5.PREVIEW_SAMPLE end
  return V5.preview_trim(t)
end

-- Play a wav without involving the timeline. REAPER has no portable
-- "just play this file" API (CF_Preview is SWS-only), so the OS player does
-- it: backgrounded on macOS/Linux, ExecProcess(-2) on Windows — both
-- fire-and-forget, so REAPER's UI never blocks on playback.
function V5.play_wav(path)
  if not file_exists(path) then
    return false, "The preview audio is missing:\n" .. path
  end
  if _is_windows() then
    if not reaper.ExecProcess then
      return false, "This REAPER build cannot start the audio player."
    end
    -- PowerShell single-quoted string: '' is the escape for a quote.
    local line =
      'powershell -NoProfile -WindowStyle Hidden -Command ' ..
      '"(New-Object Media.SoundPlayer \'' .. path:gsub("'", "''") ..
      '\').PlaySync()"'
    -- -WindowStyle Hidden only hides PowerShell's own console AFTER it
    -- starts, so it still flashes; the hidden route stops it existing.
    if not V5.win_hidden(line, 'play') then
      reaper.ExecProcess('cmd.exe /C ' .. line, -2)
    end
    return true
  end
  local os_str = reaper.GetOS() or ""
  local mac    = os_str:match("^OSX") or os_str:match("^macOS")
  -- macOS always has afplay; on Linux try ffplay, then aplay.
  local player = mac and "afplay" or "ffplay -autoexit -nodisp -loglevel quiet"
  local q = shellquote(path)
  local line = player .. ' ' .. q
  if not mac then line = line .. ' || aplay ' .. q end
  os.execute('{ ' .. line .. ' ; } >/dev/null 2>&1 &')
  return true
end

-- Synthesize *text* with *voice* and play it. Returns false (with a banner)
-- when there is nothing to test with.
function V5.start_voice_preview(voice, text)
  ui_clear_banner()
  voice = ((voice or "") ~= "" and voice) or VOICE_ID or ""
  if not voice:match("%S") then
    ui_set_banner("error",
      "Pick a voice first — there is nothing to test yet.")
    return false
  end
  text = V5.preview_trim(text or V5.PREVIEW_SAMPLE)
  if not text:match("%S") then text = V5.PREVIEW_SAMPLE end

  -- Same voice, same words, wav still on disk: replay it, don't re-synthesize.
  local last = V5.preview_last
  if last and last.voice == voice and last.text == text
     and file_exists(last.wav) then
    local ok, why = V5.play_wav(last.wav)
    ui_set_banner(ok and "info" or "error", ok and
      ("Replaying the preview of " .. V5.voice_label_for_banner(voice) ..
       " (no new ElevenLabs call).") or why)
    return ok
  end

  -- Only the newest preview is worth keeping — drop the previous pair so
  -- engine/preview/ can't grow forever.
  if last then
    if (last.wav or "") ~= "" then os.remove(last.wav) end
    if (last.txt or "") ~= "" then os.remove(last.txt) end
  end

  reaper.RecursiveCreateDirectory(V5.PREVIEW_DIR, 0)
  local stamp = os.date("%Y%m%d_%H%M%S")
  local txt_path = string.format("%s%spreview_%s.txt", V5.PREVIEW_DIR, SEP,
                                 stamp)
  local f = io.open(txt_path, "wb")
  if not f then
    ui_set_banner("error", "Could not write:\n" .. txt_path)
    return false
  end
  f:write(text .. "\n")
  f:close()

  local k = 1
  local wav_path = string.format("%s%spreview_%s.wav", V5.PREVIEW_DIR, SEP,
                                 stamp)
  while file_exists(wav_path) do
    k = k + 1
    wav_path = string.format("%s%spreview_%s_v%d.wav", V5.PREVIEW_DIR, SEP,
                             stamp, k)
  end

  local py = preflight_engine()
  if not py then return false end
  local cmd = build_engine_cmd(py, {
    regen = true, language = LANGUAGE, text_file = txt_path,
    out_wav = wav_path, voice_id = voice,
  })
  V5.preview_pending      = { out_wav = wav_path, txt = txt_path,
                              voice = voice, text = text }
  V5.preview_return_phase = _ui_phase
  return launch_engine(cmd, "preview", {
    "[panel] Mode    : voice preview (not imported anywhere)",
    "[panel] Voice   : " .. voice,
    "[panel] Sample  : " .. txt_path,
    "[panel] Out wav : " .. wav_path,
    "[panel] Python  : " .. py,
  })
end

-- "Name — id" when the voice is known, the bare id otherwise.
function V5.voice_label_for_banner(id)
  local nm = V5.voice_name(id)
  return nm ~= "" and (nm .. "  ·  " .. id) or id
end

function V5.bookmark_index(id)
  for i, v in ipairs(V5.bookmarks) do
    if v.id == id then return i end
  end
  return nil
end

-- Best display name for a voice id: the bookmark's own name, else the
-- fetched catalogue, else empty (a manually typed id nobody has named).
function V5.voice_name(id)
  local i = V5.bookmark_index(id)
  if i then return V5.bookmarks[i].name or "" end
  for _, vc in ipairs(_voices) do
    if vc.id == id then return vc.name or "" end
  end
  return ""
end

function V5.bookmark_toggle(id)
  if not (id or ""):match("%S") then return end
  local i = V5.bookmark_index(id)
  if i then
    table.remove(V5.bookmarks, i)
  else
    V5.bookmarks[#V5.bookmarks + 1] = { id = id, name = V5.voice_name(id) }
  end
  V5.bookmarks_save()
end

function V5.voice_label(vc, starred)
  return (starred and '★ ' or '')
         .. ((vc.name or "") ~= "" and vc.name or "(unnamed)")
         .. '  —  ' .. (vc.id or "")
end

-- Case-insensitive substring match on name or id. plain=true: a voice name
-- with a "-" or "(" must not be read as a Lua pattern.
function V5.voice_matches(vc, needle)
  if needle == "" then return true end
  needle = needle:lower()
  return ((vc.name or ""):lower():find(needle, 1, true) ~= nil)
         or ((vc.id or ""):lower():find(needle, 1, true) ~= nil)
end

-- Shared picker: search box + one combo listing bookmarks (★) first, then
-- the fetched catalogue, + a star toggle for the current voice. *key* makes
-- the widget ids unique per host (settings / vc / tts). Returns the chosen
-- voice id (unchanged when the user picked nothing this frame).
function V5.ui_voice_picker(ctx, key, cur, label)
  cur = cur or ""
  local filter = V5.voice_filter[key] or ""
  local rvf, ftxt = reaper.ImGui_InputText(ctx, 'Search voices##' .. key,
                                           filter)
  if rvf then
    V5.voice_filter[key] = ftxt
    filter = ftxt
  end

  -- v0.11: fetch where you pick. Regen (and Track Voice / Text to Speech)
  -- used to need a detour through ⚙ Settings before the combo had anything
  -- in it; ⚙ Settings keeps its own full-size button, so skip it there.
  if key ~= 'settings' then
    reaper.ImGui_SameLine(ctx)
    -- v0.21: the fetch happens HERE — the label carries its own progress
    -- instead of the panel jumping to the Dub run screen to show it. The id
    -- after ## is fixed, so the changing label never re-creates the widget.
    local fetching = (V5.quiet_job == "list_voices")
    _ui_begin_disabled(ctx, V5.busy())
    if reaper.ImGui_SmallButton(ctx,
        (fetching and ('⟳ Fetching voices…  ' .. _spinner_glyph())
                   or  '⟳ Fetch voices') .. '##fetch' .. key) then
      start_fetch_voices()
    end
    _ui_end_disabled(ctx)
  end

  local NO_PICK = '(pick a voice)'
  local items, cur_label = { NO_PICK }, NO_PICK
  local by_label = {}
  local function add(vc, starred)
    if not V5.voice_matches(vc, filter) then return end
    local lbl = V5.voice_label(vc, starred)
    items[#items + 1] = lbl
    by_label[lbl] = vc.id
    if vc.id == cur then cur_label = lbl end
  end
  for _, vc in ipairs(V5.bookmarks) do add(vc, true) end
  for _, vc in ipairs(_voices) do
    if not V5.bookmark_index(vc.id) then add(vc, false) end
  end

  local changed, picked = _ui_combo(ctx, (label or 'Voice') .. '##pick' .. key,
                                    cur_label, items)
  if changed and picked ~= NO_PICK and by_label[picked] then
    cur = by_label[picked]
  end

  local starred = V5.bookmark_index(cur) ~= nil
  _ui_begin_disabled(ctx, not (cur or ""):match("%S"))
  if reaper.ImGui_SmallButton(ctx,
      (starred and '★ Remove bookmark##bm' or '☆ Bookmark this voice##bm')
      .. key) then
    V5.bookmark_toggle(cur)
  end
  _ui_end_disabled(ctx)

  -- v0.11: hear the voice before committing a regen (or a whole track) to
  -- it. Falls back to the ⚙ Settings voice when this picker is empty, so the
  -- button tests exactly what the run would use.
  reaper.ImGui_SameLine(ctx)
  local test_voice = ((cur or "") ~= "" and cur) or (VOICE_ID or "")
  _ui_begin_disabled(ctx, V5.busy() or not test_voice:match("%S"))
  if reaper.ImGui_SmallButton(ctx, '🔊 Test voice##try' .. key) then
    V5.start_voice_preview(test_voice, V5.preview_text(key))
  end
  _ui_end_disabled(ctx)

  reaper.ImGui_SameLine(ctx)
  if #V5.bookmarks == 0 then
    _grey_hint(ctx, 'No bookmarks yet — star a voice to keep it at the top.')
  else
    local nm = V5.voice_name(cur)
    _grey_hint(ctx, string.format('%d bookmarked%s', #V5.bookmarks,
      nm ~= "" and ('  ·  current: ' .. nm) or ''))
  end
  if #_voices == 0 and #V5.bookmarks == 0 then
    _grey_hint(ctx,
      'No voices loaded — "Fetch voices" pulls the catalogue for ' ..
      (LANGUAGE or '?') .. ' from your ElevenLabs account.')
  elseif #_voices > 0 and _voices_language ~= ""
         and _voices_language ~= LANGUAGE then
    _grey_hint(ctx, string.format(
      '%d voice(s) listed for %s — fetch again for %s (bookmarks are not ' ..
      'affected).', #_voices, _voices_language, LANGUAGE))
  end
  return cur
end

V5.bookmarks_load()
V5.voice_cache_load()

-- v0.18: one numbered step line, so "pick a track first" is a state you can
-- see rather than a hint printed next to a greyed-out button.
function V5.vc_steps(ctx, have_track, have_voice)
  local function step(n, label, done, current)
    local col = done and V5.COL.step_ok or (current and V5.COL.bright or V5.COL.faint)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col)
    -- '●' rather than a tick: it is the glyph this panel already ships with
    -- (the readiness light), so it is certain to be in the font atlas.
    reaper.ImGui_Text(ctx, (done and '●' or tostring(n)) .. '  ' .. label)
    reaper.ImGui_PopStyleColor(ctx)
  end
  step(1, 'Pick a track',      have_track, not have_track)
  reaper.ImGui_SameLine(ctx, 0, 18)
  step(2, 'Pick the new voice', have_voice, have_track and not have_voice)
  reaper.ImGui_SameLine(ctx, 0, 18)
  step(3, 'Convert', false, have_track and have_voice)
end

-- The project's tracks as rows you can read: name, how many items, how long.
-- A bare '(pick a track)' combo said none of that, and on a dub project half
-- the names are variations of each other. Sets _vc_track_idx.
-- v0.19: one dropdown, not a list. The list spent a bordered, scrolling box on
-- what is a single choice, and pushed the voice controls and the Convert
-- button down with it. The information the rows carried is kept — it moves
-- into the option text, where you read it while choosing:
--   "3: Dub  —  2215 items  ·  117:48"
-- The leading number disambiguates: dub projects really do carry two tracks
-- called the same thing, and a combo can only match its options by string.
function V5.vc_track_picker(ctx)
  local n_tracks = reaper.CountTracks(0)
  if n_tracks == 0 then
    _grey_hint(ctx, 'The project has no tracks yet.')
    _vc_track_idx = -1
    return
  end
  if _vc_track_idx >= n_tracks then _vc_track_idx = -1 end

  local NONE = '(pick a track)'
  local items, cur = { NONE }, NONE
  for i = 0, n_tracks - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if nm == "" then nm = '(unnamed)' end
    local n_items = reaper.CountTrackMediaItems(tr)
    local len     = _track_items_end(tr)
    local label = string.format('%d: %s  —  %d item%s', i + 1, nm, n_items,
                                n_items == 1 and '' or 's')
    if len > 0 then label = label .. '  ·  ' .. V5.fmt_dur(len) end
    if reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") == 1 then
      label = label .. '  ·  muted'
    end
    items[#items + 1] = label
    if i == _vc_track_idx then cur = label end
  end

  V5.field(ctx, 'Track', 260)
  local changed, picked = _ui_combo(ctx, '##vctrack', cur, items)
  if changed then
    _vc_track_idx = -1
    for j, label in ipairs(items) do
      if label == picked and j > 1 then _vc_track_idx = j - 2 break end
    end
  end
  V5.hint(ctx, 'Any track in the project. The item count and length are ' ..
               'there to tell apart tracks whose names look alike — the dub ' ..
               'is the one with hundreds of items.')
end

local function ui_voice_change_section(ctx)
  local voice     = ((VC_VOICE_ID or "") ~= "" and VC_VOICE_ID) or VOICE_ID
  local n_tracks  = reaper.CountTracks(0)
  local have_trk  = _vc_track_idx >= 0 and _vc_track_idx < n_tracks
  local have_vc   = (voice or ""):match("%S") ~= nil
  V5.form_begin(ctx, 'vchange')

  V5.vc_steps(ctx, have_trk, have_vc)
  reaper.ImGui_Dummy(ctx, 0, 4)

  V5.vc_track_picker(ctx)
  have_trk = _vc_track_idx >= 0 and _vc_track_idx < reaper.CountTracks(0)

  -- Target voice: bookmarks first, then the fetched catalogue (v0.7 picker),
  -- with the manual id field still the final say.
  reaper.ImGui_Dummy(ctx, 0, 4)
  VC_VOICE_ID = V5.ui_voice_picker(ctx, 'vc', VC_VOICE_ID, 'New voice')
  local rv
  rv, VC_VOICE_ID = reaper.ImGui_InputText(ctx, 'Voice id##vcid',
                                           VC_VOICE_ID or '')
  _grey_hint(ctx, 'Leave empty to fall back to the default voice ' ..
                  '(Tools → Voices).')

  voice   = ((VC_VOICE_ID or "") ~= "" and VC_VOICE_ID) or VOICE_ID
  have_vc = (voice or ""):match("%S") ~= nil

  -- ── What pressing the button will do ────────────────────
  -- The paragraph that used to sit at the top of this tool described the
  -- behaviour in the abstract. Built from the actual selections it describes
  -- YOUR conversion, names the track it will create, and is worth reading.
  local tname, tlen = '', 0
  if have_trk then
    local tr = reaper.GetTrack(0, _vc_track_idx)
    local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    tname = (nm ~= "" and nm) or ('Track ' .. (_vc_track_idx + 1))
    tlen  = _track_items_end(tr)
  end
  local vname = V5.voice_name(voice)
  if vname == '' then vname = voice ~= '' and voice or '(no voice yet)' end

  reaper.ImGui_Dummy(ctx, 0, 4)
  if have_trk and have_vc then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.text)
    reaper.ImGui_TextWrapped(ctx, string.format(
      '%s (%s) is rendered to a wav, spoken again by %s with its timing ' ..
      'untouched, and imported as a new track "%s (%s)". The original is ' ..
      'muted, never modified.',
      tname, V5.fmt_dur(tlen), vname, tname, vname))
    reaper.ImGui_PopStyleColor(ctx)
    if tlen > 0 then
      -- Speech-to-speech runs roughly a third of real time, plus the render.
      _grey_hint(ctx, string.format(
        '%s of audio · expect roughly %s of conversion',
        V5.fmt_dur(tlen), V5.fmt_dur(math.max(20, tlen * 0.35))))
    end
  else
    _grey_hint(ctx, 'Re-voice a whole track: it is rendered to a wav, ' ..
                    'converted to the chosen ElevenLabs voice (timing and ' ..
                    'pacing are kept), and added back as a new track. The ' ..
                    'original track is muted, never modified.')
  end

  local can = have_trk and have_vc
  _ui_begin_disabled(ctx, not can or V5.busy())
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        V5.COL.job)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), V5.COL.job_hi)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  V5.COL.job_act)
  local label = can
    and string.format('🎤  Convert %s of %s to %s',
                      V5.fmt_dur(tlen), V5.ellipsis(tname, 24),
                      V5.ellipsis(vname, 24))
    or  '🎤  Change voice'
  if reaper.ImGui_Button(ctx, label, -1, 32) and can then
    start_voice_change()
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  _ui_end_disabled(ctx)
  if not can then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
    reaper.ImGui_Text(ctx,
      not have_trk and 'Pick a track above.' or 'Pick a voice above.')
    reaper.ImGui_PopStyleColor(ctx)
  end
  V5.form_end(ctx)
end

-- ---------------------------------------------------------------------------
-- v0.7 Text to Speech tab — paste text, synthesize it, drop it on the
-- timeline. No transcription, no translation, no sync: this is the plain
-- "say this in that voice" utility.
--
-- It runs the engine's EXISTING --regen-chunk mode (text file in, wav out,
-- no emotion pass, no other stages) rather than adding an engine mode: the
-- flags, manifest and status plumbing are identical to what the panel
-- already polls. Only the finish handling differs — the wav goes onto a
-- "TTS" track instead of replacing an item's take.
-- ---------------------------------------------------------------------------

V5.tts_text         = ""
V5.tts_voice        = ""      -- blank = fall back to the Settings voice
V5.tts_pending      = nil     -- { out_wav, text, voice } while in flight
V5.tts_return_phase = "setup"
V5.tts_last_wav     = ""

-- v0.18 history. Every generated line is already a wav sitting in the
-- project's TTS/ folder; without a list of them, re-inserting one meant
-- finding it in Explorer or paying to synthesize the same words again.
-- Newest first, capped — this is a shortcut, not an archive.
V5.TTS_HISTORY_PATH = SCRIPT_DIR .. SEP .. "tts_history.json"
V5.TTS_HISTORY_MAX  = 8
V5.tts_history      = {}
V5.tts_history_read = false

function V5.tts_history_load()
  if V5.tts_history_read then return end
  V5.tts_history_read = true
  local raw = read_all(V5.TTS_HISTORY_PATH)
  if not raw then return end
  -- Same reader the voice bookmarks use: flat string fields, real JSON string
  -- decoding, so a quote inside a line cannot derail the file.
  V5.tts_history = V5.json_object_array(raw, "items") or {}
end

function V5.tts_history_save()
  local f = io.open(V5.TTS_HISTORY_PATH, "w")
  if not f then return false end
  f:write('{\n  "items": [\n')
  for i, e in ipairs(V5.tts_history) do
    f:write(string.format(
      '    {"wav": "%s", "text": "%s", "voice": "%s", "secs": "%s"}%s\n',
      _json_escape(e.wav or ''), _json_escape(e.text or ''),
      _json_escape(e.voice or ''), _json_escape(tostring(e.secs or '')),
      i < #V5.tts_history and ',' or ''))
  end
  f:write('  ]\n}\n')
  f:close()
  return true
end

function V5.tts_history_add(wav, text, voice)
  if (wav or '') == '' then return end
  -- The stored text is a one-line preview, not the script: newlines would
  -- break the flat JSON reader, and the whole point is a glanceable row.
  local preview = V5.ellipsis((text or ''):gsub('%s+', ' '), 120)
  for i = #V5.tts_history, 1, -1 do
    if V5.tts_history[i].wav == wav then table.remove(V5.tts_history, i) end
  end
  table.insert(V5.tts_history, 1, {
    wav = wav, text = preview, voice = voice or '',
    secs = string.format('%.1f', V5.speech_secs(text or '')),
  })
  while #V5.tts_history > V5.TTS_HISTORY_MAX do
    table.remove(V5.tts_history)
  end
  V5.tts_history_save()
end

function V5.tts_import(wav)
  if not file_exists(wav) then
    return false, "The generated wav is missing:\n" .. wav
  end
  local src = reaper.PCM_Source_CreateFromFile(wav)
  if not src then
    return false, "REAPER could not open the media file:\n" .. wav
  end
  local tr = V5.find_or_append_track("TTS")
  local pos = reaper.GetCursorPosition()
  reaper.Undo_BeginBlock()
  local item = reaper.AddMediaItemToTrack(tr)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  local len, is_qn = reaper.GetMediaSourceLength(src)
  if len and len > 0 and not is_qn then
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len)
  end
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", basename(wav), true)
  V5.set_item_text(item, (V5.tts_pending and V5.tts_pending.text) or "")
  reaper.Undo_EndBlock("Import TTS audio", -1)
  reaper.UpdateArrange()
  return true
end

function V5.start_tts()
  ui_clear_banner()
  local text = V5.tts_text or ""
  if not text:match("%S") then
    ui_set_banner("error", "Nothing to speak — type or paste some text first.")
    return false
  end
  local voice = ((V5.tts_voice or "") ~= "" and V5.tts_voice) or VOICE_ID
  if not (voice or ""):match("%S") then
    ui_set_banner("error",
      "No voice selected. Bookmark one here, or fetch the catalogue in " ..
      "Tools → Voices.")
    return false
  end
  -- Audio lands next to the project, like DubSource/ and VoiceChange/ do.
  local proj = reaper.GetProjectPath("")
  if (proj or "") == "" then
    ui_set_banner("error",
      "Save the REAPER project first — the generated audio is written to " ..
      "its media folder.")
    return false
  end
  local dir = proj .. SEP .. "TTS"
  reaper.RecursiveCreateDirectory(dir, 0)

  -- Indic text never travels on argv: it goes through this UTF-8 file.
  local stamp = os.date("%Y%m%d_%H%M%S")
  local txt_path = string.format("%s%sTTS_%s.txt", dir, SEP, stamp)
  local f = io.open(txt_path, "wb")
  if not f then
    ui_set_banner("error", "Could not write:\n" .. txt_path)
    return false
  end
  local body = text:gsub("\r\n", "\n")
  if body:sub(-1) ~= "\n" then body = body .. "\n" end
  f:write(body)
  f:close()

  local k, wav_path = 1, string.format("%s%sTTS_%s.wav", dir, SEP, stamp)
  while file_exists(wav_path) do
    k = k + 1
    wav_path = string.format("%s%sTTS_%s_v%d.wav", dir, SEP, stamp, k)
  end

  local py = preflight_engine()
  if not py then return false end

  local cmd = build_engine_cmd(py, {
    regen = true, language = LANGUAGE, text_file = txt_path,
    out_wav = wav_path, voice_id = voice,
  })
  V5.tts_pending      = { out_wav = wav_path, text = text, voice = voice }
  V5.tts_return_phase = _ui_phase
  return launch_engine(cmd, "tts", {
    "[panel] TTS text: " .. txt_path,
    "[panel] Out wav : " .. wav_path,
    "[panel] Voice   : " .. voice,
    "[panel] Python  : " .. py,
  })
end

-- The right-hand column: who speaks, where it lands, what it costs. Every
-- question you have BEFORE pressing the button, answered without pressing it.
function V5.tts_facts(ctx, voice, secs, nchar)
  V5.cap(ctx, 'VOICE')
  local nm = V5.voice_name(voice)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                              voice ~= '' and V5.COL.text or V5.COL.warn)
  reaper.ImGui_TextWrapped(ctx, voice == '' and 'none set yet'
                                or (nm ~= '' and nm or V5.ellipsis(voice, 26)))
  reaper.ImGui_PopStyleColor(ctx)
  if voice ~= '' and nm ~= '' then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.faint)
    reaper.ImGui_Text(ctx, V5.ellipsis(voice, 24))
    reaper.ImGui_PopStyleColor(ctx)
  end
  _ui_begin_disabled(ctx, V5.busy() or voice == '')
  if reaper.ImGui_SmallButton(ctx, '🔊 Hear it##ttscard') then
    V5.start_voice_preview(voice, V5.preview_text('tts'))
  end
  _ui_end_disabled(ctx)

  reaper.ImGui_Dummy(ctx, 0, 6)
  V5.cap(ctx, 'GOES TO')
  local cur = reaper.GetCursorPosition and reaper.GetCursorPosition() or 0
  _grey_hint(ctx, 'the "TTS" track')
  _grey_hint(ctx, 'at ' .. V5.fmt_pos(cur))
  _grey_hint(ctx, 'model ' .. (EL_MODEL or '?'))

  reaper.ImGui_Dummy(ctx, 0, 6)
  V5.cap(ctx, 'THIS WILL BE')
  if nchar == 0 then
    _grey_hint(ctx, 'nothing yet')
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.text)
    reaper.ImGui_Text(ctx, '~' .. V5.fmt_dur(secs) .. ' of speech')
    reaper.ImGui_PopStyleColor(ctx)
    _grey_hint(ctx, string.format('~%d credits', V5.credit_est(V5.tts_text)))
    _grey_hint(ctx, 'estimates — 15 chars/s, 1 credit/char')
  end
end

function V5.ui_tts_tab(ctx)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),  6.0, 6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 3.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),  8.0, 4.0)

  -- v0.18: no 22 px hero title. The Tools chip already says "Text to speech"
  -- and the step line under it says what the tool does — a third heading cost
  -- ~50 px of the text box.
  V5.tts_history_load()
  -- v0.21: the banner is drawn once for the whole Tools tab (V5.ui_tools_tab).

  local running = (_ui_phase == "running")
  _ui_begin_disabled(ctx, running)

  local voice = ((V5.tts_voice or "") ~= "" and V5.tts_voice) or (VOICE_ID or "")
  local nchar = V5.char_count(V5.tts_text or '')
  local secs  = V5.speech_secs(V5.tts_text or '')

  -- The box takes a share of the window height; both columns are told the
  -- same number so the facts column cannot stretch the row.
  local wh = 0
  if reaper.ImGui_GetWindowHeight then
    local ok, h = pcall(reaper.ImGui_GetWindowHeight, ctx)
    if ok and type(h) == 'number' then wh = h end
  end
  local box_h = math.max(150, math.min(420, math.floor(wh * 0.40)))

  -- Two columns only when there is room for both. Narrow window: the facts
  -- go under the box instead of squeezing it to nothing.
  local avail   = reaper.ImGui_GetContentRegionAvail(ctx) or 600
  local RIGHT_W = 208
  local two_col = avail >= 600

  if two_col then
    -- v0.19: neither column scrolls. box_h + 34 was ~20 px short of what the
    -- left column actually draws ('Text', the box's own toolbar, then the box),
    -- so it grew a scrollbar of its own — and then the wheel scrolled the
    -- COLUMN when the pointer was an inch from the text, while the scrollbar
    -- took 11 px off the box's width. The scrolling that belongs here is the
    -- text box's own. Both columns are drawn at the height their content
    -- measured on the previous frame, so nothing is clipped either; the
    -- fallbacks only ever apply to frame one.
    local row_h = math.max(V5.mh_child('ttsleft',  box_h + 62),
                           V5.mh_child('ttsright', 190))
    if reaper.ImGui_BeginChild(ctx, '##ttsleft', -(RIGHT_W + 8), row_h, 0,
                               V5.noscroll_flags()) then
      local y0 = V5.y(ctx)
      reaper.ImGui_Text(ctx, 'Text')
      V5.tts_text = V5.script_box(ctx, 'ttsbox', V5.tts_text or '',
                                  { height = box_h, fixed = true,
                                    paras = false })
      V5.measured(ctx, 'ttsleft', y0)
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_SameLine(ctx)
    if V5.begin_padded_child(ctx, '##ttsright', -1, row_h,
                             V5.noscroll_flags()) then
      local y0 = V5.y(ctx)
      V5.tts_facts(ctx, voice, secs, nchar)
      V5.measured(ctx, 'ttsright', y0)
      reaper.ImGui_EndChild(ctx)
    end
  else
    reaper.ImGui_Text(ctx, 'Text')
    V5.tts_text = V5.script_box(ctx, 'ttsbox', V5.tts_text or '',
                                { height = box_h, fixed = true, paras = false })
    reaper.ImGui_Dummy(ctx, 0, 4)
    V5.tts_facts(ctx, voice, secs, nchar)
  end

  -- ── The one button, saying what it will do ──────────────
  reaper.ImGui_Dummy(ctx, 0, 4)
  local can = (V5.tts_text or ""):match("%S") ~= nil
              and (voice or ""):match("%S") ~= nil
  _ui_begin_disabled(ctx, not can or V5.busy())
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        V5.COL.go)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), V5.COL.go_hi)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  V5.COL.go_act)
  local nm    = V5.voice_name(voice)
  local label = '🔊  Generate + import'
  if can then
    label = string.format('🔊  Speak it in %s  —  ~%s, ~%d credits',
      V5.ellipsis(nm ~= '' and nm or voice, 22), V5.fmt_dur(secs),
      V5.credit_est(V5.tts_text))
  end
  if reaper.ImGui_Button(ctx, label, -1, 34) and can then
    V5.start_tts()
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  _ui_end_disabled(ctx)
  if not can then
    _grey_hint(ctx, (V5.tts_text or ""):match("%S")
                    and 'Pick a voice below first.'
                    or 'Paste or type some text first.')
  end

  -- ── Changing the voice is the uncommon case ─────────────
  -- Behind a reveal (open by default while no voice is set at all), because
  -- the picker is four controls tall and most runs reuse the same voice.
  if (voice or '') == '' then V5.adv.ttsvoice = true end
  if V5.advanced(ctx, 'ttsvoice', 'Choose a different voice') then
    reaper.ImGui_Indent(ctx, 12)
    V5.tts_voice = V5.ui_voice_picker(ctx, 'tts', V5.tts_voice, 'Voice')
    local rv2
    rv2, V5.tts_voice = reaper.ImGui_InputText(ctx, 'Voice id##ttsid',
                                               V5.tts_voice or '')
    _grey_hint(ctx, 'Leave empty to use the default voice'
                    .. ((VOICE_ID or "") ~= "" and (' (' .. VOICE_ID .. ')')
                        or ' (none set yet — Tools → Voices)') .. '.')
    _grey_hint(ctx, 'eleven_v3 detects the language from the text itself.')
    reaper.ImGui_Unindent(ctx, 12)
  end

  _ui_end_disabled(ctx)

  if running then
    reaper.ImGui_Dummy(ctx, 0, 4)
    _grey_hint(ctx, 'A run is in progress — the Log tab shows its output.')
  end

  -- ── Recent ──────────────────────────────────────────────
  -- Every one of these is a wav already paid for and already on disk.
  if #V5.tts_history > 0 then
    reaper.ImGui_Dummy(ctx, 0, 6)
    reaper.ImGui_Separator(ctx)
    V5.cap(ctx, 'RECENT')
    for i, e in ipairs(V5.tts_history) do
      local gone = not file_exists(e.wav or '')
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                                  gone and V5.COL.faint or V5.COL.text2)
      reaper.ImGui_TextWrapped(ctx, V5.ellipsis(e.text or '(no text)', 76))
      reaper.ImGui_PopStyleColor(ctx)

      local vn = V5.voice_name(e.voice or '')
      _grey_hint(ctx, string.format('%s%ss%s',
        vn ~= '' and (vn .. '  ·  ') or '',
        (e.secs or '?'), gone and '  ·  the wav is gone' or ''))
      if not gone then
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_SmallButton(ctx, 'Insert again##tth' .. i) then
          local ok, why = V5.tts_import(e.wav)
          ui_set_banner(ok and "info" or "error",
            ok and ("Imported at the edit cursor:\n" .. e.wav)
            or (why or "Import failed."))
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_SmallButton(ctx, '🔊##tthp' .. i) then
          local ok, why = V5.play_wav(e.wav)
          if not ok then ui_set_banner("warn", why or "Playback failed.") end
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_SmallButton(ctx, 'Folder##tthf' .. i) then
          open_path(dirname(e.wav))
        end
      end
    end
  end

  reaper.ImGui_PopStyleVar(ctx, 3)
end

-- ─── Tools tab (v0.13) ──────────────────────────────────────
-- The small voice utilities behind one segmented row, replacing the separate
-- tabs they used to be. Which tool is showing persists (V5.tool, see
-- save_settings).
-- v0.17: a fourth one — Voices, moved out of ⚙ Settings. Voice generation work
-- now lives entirely on this tab; Settings keeps only the credential.
function V5.ui_tools_tab(ctx)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),  6.0, 6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 3.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),  8.0, 4.0)

  local tool = V5.segmented(ctx, 'tool', V5.tool, {
    { 'voices', 'Voices',
      'Fetch the ElevenLabs voice catalogue, audition voices, and set the ' ..
      'default one every stage falls back to. Was ⚙ Settings → Voices.' },
    { 'tts',   'Text to speech',
      'Type or paste text and hear it in a chosen voice. The wav lands on a ' ..
      '"TTS" track at the edit cursor. No transcription, translation or sync.' },
    { 'regen', 'Redo one line',
      'Select a dub chunk item in the arrange view, fix its text (or change ' ..
      'its voice) and regenerate just that line. Non-destructive: new files ' ..
      'go to the run\'s regen/ folder.' },
    { 'voice', 'Re-voice a track',
      'Convert a whole track to a different voice with the ElevenLabs voice ' ..
      'changer. Timing is preserved, so a synced dub stays synced.' },
  })
  if tool ~= V5.tool then
    V5.tool = tool
    save_settings()
  end

  reaper.ImGui_Dummy(ctx, 0, 2)

  -- v0.21: one banner for the whole tab, not one per tool. Text to speech was
  -- the only tool that drew it, so a voice fetch fired from Voices, Redo one
  -- line or Re-voice a track reported its result on a screen you were not on.
  _ui_render_banner(ctx)

  -- v0.15: the 17px heading under the segmented row said the same words as the
  -- chip you had just pressed, and cost ~40px doing it — enough to push the
  -- TTS text box past the bottom. Only the line that says what the tool DOES
  -- survives.
  if V5.tool == 'voices' then
    V5.steps(ctx, 'Fetch the catalogue  →  audition  →  set the default voice')
    V5.ui_voices_tool(ctx)
  elseif V5.tool == 'tts' then
    V5.steps(ctx, 'Paste text  →  speak it  →  it lands on a "TTS" track at the cursor')
    V5.ui_tts_tab(ctx)
  elseif V5.tool == 'regen' then
    V5.steps(ctx, 'Select a dub chunk in the arrange view, then edit and regenerate it')
    ui_regen_section(ctx)
  else
    V5.steps(ctx, 'Render a track  →  convert it to another voice  →  import it back')
    ui_voice_change_section(ctx)
  end

  reaper.ImGui_PopStyleVar(ctx, 3)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- v0.29 "Proof" — the review screen (a staged run paused after translation)
-- ═══════════════════════════════════════════════════════════════════════════
-- This screen decides whether the translation is right BEFORE any credit is
-- spent speaking it, and until v0.29 it was two columns of text and five
-- buttons: no timings, no idea whether a paragraph would still fit the gap it
-- has to land in, and no way to hear the English it came from. All of that is
-- already in the run — the engine paired these paragraphs against the English
-- SRT it wrote for this audio — so the screen reads it now.
--
--   * PREVIEW SYNC. Every paragraph carries its source slot, an estimated
--     spoken length for the target text, and the same verdict Studio gives a
--     chunk (fits / eats pause / OVERFLOWS). Local, free, and re-measured as
--     you type, so the fit you are shown is the fit the plan stage will find.
--   * A TRANSPORT. The lane strip is the whole script on one time axis;
--     ▶ Play here moves REAPER's edit cursor to the selected paragraph's place
--     in the English audio, and Follow walks the selection along with the play
--     cursor while you listen.
--   * TWO LAYOUTS, at a text size you pick. List scans (one line per
--     paragraph, the bad fits visible at a glance) and edits the selected one
--     in the inspector; Grid is the v0.4 side-by-side editor, kept because a
--     full retype wants every box at once.
--
-- Drawn against the same layout contract as Studio: a body child, a canvas, an
-- inspector that gives width back rather than squeezing, and a pinned
-- transport bar. Nothing here hand-counts an x offset.

V5.REVIEW_INSP_MIN = 250   -- narrower than this and the inspector goes entirely
V5.REVIEW_PX_OPTS  = { 13, 15, 17 }

-- The transport bar's own height. Four buttons and a note WRAP when they do
-- not fit (V5.wrap_next), so unlike Studio's this bar is not one row by
-- construction — and a canvas sized against a flat 46 px pushed the second row
-- out of the body at any width under ~700.
--
-- Worked out from the widths and the room, NOT measured: the reserve decides
-- how tall the canvas is, so measuring the bar after drawing it would be the
-- feedback loop V5.PLAN_BOT_H exists to avoid (tall canvas → short reserve →
-- short canvas → tall reserve, forever). Width is an input here, not an
-- output, so this answer is stable.
V5.REVIEW_BAR_W = { 110, 200, 100, 120, 120 }   -- Save / Continue / Skip / Back / note

function V5.review_bot_h(avail)
  local rows, pen = 1, 0
  for _, w in ipairs(V5.REVIEW_BAR_W) do
    if pen == 0 then pen = w
    elseif pen + 8 + w <= avail then pen = pen + 8 + w
    else rows, pen = rows + 1, w end
  end
  return 16 + rows * 30 + (rows - 1) * 6
end

-- Estimated pixel height for one editable paragraph box (grows with text).
local function _para_box_height(en, tr)
  -- v0.26: CLUSTERS, not bytes. '#' on a Devanagari or Bengali paragraph counts
  -- three per character, so every translated paragraph saturated the 10-line
  -- cap and the review grid became a column of identical oversized boxes with
  -- the text stranded at the top of each — for the one language pair the
  -- screen exists to proofread.
  -- v0.29: both numbers follow V5.review_px. A smaller face fits MORE
  -- characters on a line and makes each line SHORTER, so a box sized at a flat
  -- 20 px per line and 90 characters per line was a third empty at 13 px.
  local n     = math.max(V5.cells(en or ""), V5.cells(tr or ""))
  local px    = V5.review_px or 15
  local cols  = math.max(40, math.floor(90 * 15 / px))
  local lines = math.max(2, math.min(10, math.ceil(n / cols)))
  return lines * (px + 5) + 14
end

-- ─── Preview sync: recovering each paragraph's place in the audio ──────────
-- Nothing in the review files carries a timestamp, but the engine built them
-- by pairing this run's English SRT (manifest.en_srt = <base>.srt, the file
-- _pair_review_rows consumed) against the translation paragraphs — and each
-- English paragraph is literally the text of its group of cues joined with
-- spaces. So the times are recoverable exactly: walk the cues as ONE character
-- stream and cut it where the paragraphs cut it.
--
-- Both sides are normalized to alphanumerics because the punctuation pass
-- rewrites punctuation and casing between the SRT and the review file, and the
-- offsets are scaled by the two totals, so a paragraph file that gained or lost
-- a few characters slides slightly instead of drifting to the end.
function V5.review_norm(s)
  return (tostring(s or ""):lower():gsub("[^%w]", ""))
end

-- Returns slots (one per English paragraph) + the source duration, or nil when
-- there is no usable SRT — in which case the screen drops the timed half of
-- itself rather than inventing numbers.
function V5.review_times(en_paras, srt_path)
  if not (srt_path and srt_path ~= "" and file_exists(srt_path)) then
    return nil
  end
  local cues = parse_srt_file(srt_path)
  if #cues == 0 then return nil end

  local len, total = {}, 0
  for k, c in ipairs(cues) do
    len[k] = #V5.review_norm(c.text)
    total  = total + len[k]
  end
  if total == 0 then return nil end

  local plen, ptotal = {}, 0
  for i, p in ipairs(en_paras) do
    plen[i] = #V5.review_norm(p)
    ptotal  = ptotal + plen[i]
  end
  if ptotal == 0 then return nil end
  local scale = total / ptotal

  -- Cues are handed out WHOLE, greedily, one group per paragraph: a paragraph
  -- IS a group of whole cues (that is how _pair_review_rows built it), so a
  -- slot that started or ended halfway through one could only be wrong. The
  -- next cue joins this paragraph while more than half of it is still wanted,
  -- which is the rule that survives the two sides disagreeing slightly about
  -- how many characters a paragraph has — and every group is left at least one
  -- cue for the paragraphs still to come, so the slots stay ordered and never
  -- overlap.
  local after = {}                 -- paragraphs after i that still need a cue
  do
    local c = 0
    for i = #en_paras, 1, -1 do
      after[i] = c
      if plen[i] > 0 then c = c + 1 end
    end
  end

  local slots, k = {}, 1
  for i = 1, #en_paras do
    if plen[i] == 0 or k > #cues then
      -- The engine's "—" placeholder row: a place in the order, no English of
      -- its own, so no slot to measure a translation against.
      local t = cues[math.min(k, #cues)].start
      slots[i] = { start_s = t, stop_s = t, timed = false }
    else
      local last = k
      local need = plen[i] * scale
      local got  = len[k]
      local kmax = (i == #en_paras) and #cues
                   or math.max(k, #cues - after[i])
      while last < kmax and got + len[last + 1] * 0.5 <= need do
        last = last + 1
        got  = got + len[last]
      end
      if i == #en_paras then last = #cues end   -- the last one takes the rest
      slots[i] = { start_s = cues[k].start, stop_s = cues[last].stop,
                   timed = true }
      k = last + 1
    end
  end
  return slots, cues[#cues].stop or 0
end

-- ─── The same arithmetic the paid stage will use ──────────────────────────
-- These four constants are the engine's, mirrored: LANG_CHARS_PER_SEC /
-- DEFAULT_CHARS_PER_SEC / SHORT_RATIO / MAX_ATEMPO in pipeline/config.py and
-- pipeline/pausechunk.py. A preview that answered with a different rate would
-- be worse than no preview — it would disagree with the plan stage, on the one
-- screen whose whole job is to be believed before money is spent.
--
-- Hindi at 9.2 is not a rounding of the panel's old flat 15: it is what
-- ElevenLabs actually speaks Hindi at, and estimating a Hindi paragraph at 15
-- called two thirds of a normal script "too long".
V5.LANG_CPS = {
  Hindi = 9.2, Marathi = 12.0, Bengali = 12.0, Gujarati = 11.0,
  Tamil = 12.0, Telugu = 11.5, Kannada = 11.5, Malayalam = 12.0,
  Sanskrit = 10.0, English = 14.0,
}
V5.LANG_CPS_DEFAULT = 11.0
V5.SHORT_RATIO      = 0.85   -- under this share of its slot, a line is 'short'
V5.MAX_ATEMPO       = 1.25   -- the paid run's stretch ceiling

function V5.lang_cps(lang)
  return V5.LANG_CPS[tostring(lang or '')] or V5.LANG_CPS_DEFAULT
end

-- Estimated spoken seconds for *text*. ElevenLabs [tags] are stripped first —
-- they steer prosody and are never spoken, so counting them would inflate
-- every estimate on an emotion-enriched script (estimate_duration does the
-- same). Characters, not bytes: '#' over Devanagari answers about three times
-- the truth.
function V5.est_secs(text, lang)
  local clean = tostring(text or ''):gsub('%[.-%]', '')
  return V5.char_count(clean) / V5.lang_cps(lang)
end

-- The verdict's label and colour. Studio's five, plus the one only this screen
-- can produce: a paragraph with no source timing to judge against.
V5.REVIEW_VERDICTS = { 'over', 'tight', 'short', 'empty', 'untimed', 'fits' }

function V5.review_look(v)
  if v == 'untimed' then return 'no timing', V5.COL.dimmer end
  return (V5.PLAN_LABELS[v] or v), (V5.PLAN_COLOURS[v] or V5.COL.text)
end

-- Estimated spoken length, verdict and following pause for every paragraph.
-- Rebuilt every frame on purpose: it is arithmetic over the paragraph texts,
-- and the whole point of it is that it answers while you type.
function V5.review_measure(R)
  local rows, counts = {}, {}
  local lang = ((R.manifest and (R.manifest.language or '') ~= '')
                and R.manifest.language) or LANGUAGE or ''
  -- The RUN's language, not the combo's: a resumed review can be a language
  -- ago, and the rate, the column header and the caption must all name the
  -- language this script is actually in.
  R.lang, R.cps = lang, V5.lang_cps(lang)
  local n = math.max(#R.en_paras, #R.tr_paras)
  for i = 1, n do
    local en, tr = R.en_paras[i] or '', R.tr_paras[i] or ''
    local sl     = R.slots and R.slots[i]
    local nx     = R.slots and R.slots[i + 1]
    local timed  = (sl ~= nil) and sl.timed
    -- Two slots per paragraph, exactly as estimate_fit reads them: the speech
    -- slot is how long the source speaker talked, the hard slot is that plus
    -- the pause after it. Overrunning the speech slot eats a pause;
    -- overrunning the hard slot means the dub is still talking when the next
    -- paragraph has to start.
    local dur    = timed and math.max(0, sl.stop_s - sl.start_s) or 0
    local pause  = (timed and nx and nx.timed)
                   and math.max(0, nx.start_s - sl.stop_s) or 0
    local hard   = dur + pause
    local est    = V5.est_secs(tr, lang)
    local verdict
    if tr:match('%S') == nil or tr == '—'  then verdict = 'empty'
    elseif not timed or dur <= 0.05        then verdict = 'untimed'
    elseif est > hard and hard > 0         then verdict = 'over'
    elseif est > dur                       then verdict = 'tight'
    elseif est < dur * V5.SHORT_RATIO      then verdict = 'short'
    else                                        verdict = 'fits' end
    counts[verdict] = (counts[verdict] or 0) + 1
    rows[i] = {
      index = i, en = en, tr = tr,
      start_s = sl and sl.start_s or 0,
      dur = dur, pause = pause, est = est, verdict = verdict,
      -- What the placer would have to speed this line up by, clamped to the
      -- same ceiling the paid run clamps to. Same field name as a plan row,
      -- because V5.plan_strip draws both.
      atempo = (verdict == 'over')
               and math.min(est / hard, V5.MAX_ATEMPO) or 1.0,
      over_s = (verdict == 'over') and (est - hard) or 0,
    }
  end
  R.rows, R.counts = rows, counts
  return rows
end

-- ─── The transport half of the preview sync ───────────────────────────────
-- Where this run's English audio sits in THIS project. The SRT is timed from
-- the file's own zero, so an item dragged to 0:30 would send every preview
-- half a minute early. Matched by file NAME, so a render of the same source
-- under another name simply does not match and the offset stays 0 — which is
-- exactly the old behaviour, not a wrong answer.
function V5.review_relink(R)
  R.time_off, R.linked = 0, nil
  local want = basename((R.manifest and R.manifest.audio) or ''):lower()
  -- v0.31: the sidecar answer is checked even when the item search cannot run
  -- (no audio name, an old ReaImGui/REAPER without the media API) — it is a
  -- number on disk, not something read off the timeline.
  local n = (want ~= '' and reaper.CountMediaItems)
            and reaper.CountMediaItems(0) or nil
  for i = 0, (type(n) == 'number' and n or 0) - 1 do
    local it   = reaper.GetMediaItem(0, i)
    local take = it and reaper.GetActiveTake and reaper.GetActiveTake(it)
    if take and not (reaper.TakeIsMIDI and reaper.TakeIsMIDI(take)) then
      local src = reaper.GetMediaItemTake_Source
                  and reaper.GetMediaItemTake_Source(take)
      -- Unwrap section/reversed wrappers to reach the file source, the same
      -- walk audio_from_track does.
      while src and reaper.GetMediaSourceParent do
        local parent = reaper.GetMediaSourceParent(src)
        if parent then src = parent else break end
      end
      local fn = (src and reaper.GetMediaSourceFileName)
                 and reaper.GetMediaSourceFileName(src, "") or ""
      if fn ~= "" and basename(fn):lower() == want then
        local pos  = tonumber(reaper.GetMediaItemInfo_Value(it, "D_POSITION")) or 0
        local offs = tonumber(reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")) or 0
        R.time_off, R.linked = pos - offs, basename(fn)
        return true
      end
    end
  end
  -- v0.31: a region run's audio is not on the timeline and never will be — it
  -- IS a slice of something that is. The sidecar written when the slice was
  -- taken says where it starts, which is the same answer the item search
  -- above would have given for a whole file.
  local reg = V5.region_load((R.manifest and R.manifest.audio) or '')
  if reg and reg.pos and reg.pos > 0 then
    R.time_off = reg.pos
    R.linked   = ((reg.source ~= '' and basename(reg.source))
                  or basename((R.manifest and R.manifest.audio) or ''))
                 .. ' — the region it was taken from'
    return true
  end
  return false
end

-- True when REAPER is playing right now.
function V5.review_playing()
  local st = reaper.GetPlayState and reaper.GetPlayState()
  return type(st) == 'number' and (st & 1) == 1
end

-- Move the edit cursor to *row*'s place in the source, optionally playing from
-- there. Returns false when there is nothing to seek to, so the caller can say
-- why instead of appearing to do nothing.
function V5.review_seek(R, row, play)
  if not (row and R.timed and row.dur > 0.001) then return false end
  if not reaper.SetEditCurPos then return false end
  local t = math.max(0, (R.time_off or 0) + (row.start_s or 0))
  -- moveview: the point of the button is a paragraph that is off-screen.
  -- seekplay: a transport already rolling jumps rather than ignoring us.
  reaper.SetEditCurPos(t, true, true)
  if play and not V5.review_playing() and reaper.CSurf_OnPlay then
    reaper.CSurf_OnPlay()
  end
  if reaper.UpdateArrange then reaper.UpdateArrange() end
  return true
end

-- The live half: read the play cursor, and (when Follow is on) walk the
-- selection with it. Off by default — it moves the selection under your hands,
-- which is right while you listen and wrong while you type.
function V5.review_follow_poll(R)
  R.play_s = nil
  if not (R.timed and V5.review_playing() and reaper.GetPlayPosition) then
    return
  end
  local p = reaper.GetPlayPosition()
  if type(p) ~= 'number' then return end
  local t = p - (R.time_off or 0)
  if t < 0 or t > (R.total_s or 0) + 1 then return end
  R.play_s = t
  if not R.follow then return end
  for _, r in ipairs(R.rows or {}) do
    if t >= r.start_s and t < r.start_s + r.dur + r.pause then
      if R.sel ~= r.index then R.sel, R.scroll_to = r.index, r.index end
      return
    end
  end
end

-- m:ss, Latin digits — legible whatever the target script is.
function V5.review_at(t)
  t = math.max(0, tonumber(t) or 0)
  return string.format('%d:%02d', math.floor(t / 60), math.floor(t % 60))
end

-- ─── v0.30 THE CAST: which ElevenLabs voice speaks which paragraph ────────
-- Until now the voice was one id in ⚙ Settings — chosen before the run, and
-- invisible on the one screen where the script is actually read. A talk is not
-- always one voice: Sadhguru speaks most of it, a question comes from the
-- audience, an invocation or a translator's line belongs to someone else. The
-- paragraph is the unit where that is obvious, and this screen already lists
-- the paragraphs — so the casting belongs here, next to the text, before any
-- credit is spent speaking it in the wrong voice.
--
-- The cast is per RUN, not per panel. It is saved beside the run's other
-- outputs as <base>_speakers.json — the file the engine already looks for
-- (pipeline/tts.py, _speakers_voice_map) — so re-entering a paused review
-- finds the same cast, and the dub stage reads the same map.
--
-- One rule holds the whole thing together: EVERY paragraph has a speaker. The
-- first speaker in the cast is the main one — the voice the run is launched
-- with (--voice-id) — and a paragraph nobody re-assigned is spoken by it.
-- There is no "unassigned" state to render, to explain, or to fail on.

-- Eight hues that stay apart on this ground and read at 13 px. The colour IS
-- the speaker's identity here: it is the row chip, the strip and the combo.
V5.CAST_COLOURS = { 0x7FB3FFFF, 0x7FD3A0FF, 0xE8A13AFF, 0xC792EAFF,
                    0xE5808AFF, 0x6FD8D0FF, 0xD7C56BFF, 0xB0B8C4FF }
V5.CAST_MAX     = 8            -- more than eight voices in one talk is a film
V5.CAST_MAIN    = 'Sadhguru'   -- speaker 1's default name; editable in place

-- <out_dir>/<base>_speakers.json, or nil when this run has no output folder
-- (the harness fixture, and a manifest that lost its out_dir).
function V5.cast_file(R)
  local dir = (R.manifest and R.manifest.out_dir) or ''
  if dir == '' then return nil end
  return dir .. SEP .. ((R.base ~= '' and R.base) or 'dub') .. '_speakers.json'
end

function V5.cast_find(R, key)
  for _, s in ipairs((R.cast and R.cast.speakers) or {}) do
    if s.key == key then return s end
  end
  return nil
end

-- The speaker of paragraph *i*: its assignment, or the main voice. Never nil
-- once the cast exists — that is the rule above, in one line.
function V5.cast_of(R, i)
  local C = R.cast
  if not C then return nil end
  return V5.cast_find(R, C.by_row[i]) or C.speakers[1]
end

function V5.cast_active(R)
  local C = R.cast
  if not C then return nil end
  return V5.cast_find(R, C.active) or C.speakers[1]
end

-- True once the run would need more than one voice — the state that turns on
-- the row chips, the List's voice column and the sidecar the engine reads.
function V5.cast_multi(R)
  local C = R.cast
  return (C and #C.speakers > 1) or false
end

-- Next free 's<n>' key. Not #speakers+1: removing the middle speaker of three
-- would otherwise hand the next one a key an assignment still points at.
local function _cast_next_key(C)
  local n = 0
  for _, s in ipairs(C.speakers) do
    local k = tonumber((s.key or ''):match('^s(%d+)$') or '') or 0
    if k > n then n = k end
  end
  return 's' .. (n + 1)
end

function V5.cast_add(R, name, voice)
  local C = V5.cast_ensure(R)
  if #C.speakers >= V5.CAST_MAX then return nil end
  local sp = {
    key    = _cast_next_key(C),
    name   = (name and name ~= '') and name or ('Speaker ' .. (#C.speakers + 1)),
    voice  = voice or '',
    colour = V5.CAST_COLOURS[(#C.speakers % #V5.CAST_COLOURS) + 1],
  }
  C.speakers[#C.speakers + 1] = sp
  C.dirty = true
  return sp
end

-- Speaker 1 is the main voice and cannot be removed: every paragraph falls
-- back to it, so removing it would leave the run with nothing to speak.
function V5.cast_remove(R, key)
  local C = R.cast
  if not C then return false end
  for i, s in ipairs(C.speakers) do
    if s.key == key and i > 1 then
      table.remove(C.speakers, i)
      for row, k in pairs(C.by_row) do
        if k == key then C.by_row[row] = nil end
      end
      if C.active == key then C.active = C.speakers[1].key end
      C.dirty = true
      return true
    end
  end
  return false
end

-- Assigning the MAIN speaker clears the row instead of recording it: the map
-- on disk then names only the paragraphs that are genuinely someone else's,
-- and a main voice changed later re-casts them all without a sweep.
function V5.cast_assign(R, i, key)
  local C = R.cast
  if not C then return end
  local main = C.speakers[1]
  C.by_row[i] = (key and main and key ~= main.key) and key or nil
  C.dirty = true
end

-- Lines and spoken characters per speaker key — what the chips count, and the
-- only honest answer to "how much of this talk is this voice?".
function V5.cast_stats(R)
  local C, out = R.cast, {}
  if not C then return out end
  for _, s in ipairs(C.speakers) do out[s.key] = { lines = 0, chars = 0 } end
  for _, r in ipairs(R.rows or {}) do
    local s = V5.cast_of(R, r.index)
    local t = s and out[s.key]
    if t then
      t.lines = t.lines + 1
      -- [tags] steer prosody and are never spoken; the estimate strips them,
      -- so the per-speaker count has to strip them too or the two disagree.
      t.chars = t.chars + V5.char_count(((r.tr or ''):gsub('%[.-%]', '')))
    end
  end
  return out
end

-- Speakers that have paragraphs but no voice id. The bar says so and Continue
-- refuses: a cast line with no voice cannot be spoken by anyone, and the only
-- thing the engine could do with it is quietly hand it to the main voice —
-- which is the one outcome this whole screen exists to prevent.
--
-- The MAIN speaker is deliberately not in this list. An empty main voice is
-- the panel's oldest behaviour: the engine auto-resolves the first voice in
-- the account that matches the language, and that path still works. The bar
-- says "auto" so it is a choice rather than a surprise.
function V5.cast_voiceless(R)
  local out = {}
  local C = R.cast
  if not C then return out end
  local used = {}
  for _, r in ipairs(R.rows or {}) do
    local s = V5.cast_of(R, r.index)
    if s then used[s.key] = true end
  end
  for i, s in ipairs(C.speakers) do
    if i > 1 and used[s.key] and not (s.voice or ''):match('%S') then
      out[#out + 1] = s
    end
  end
  return out
end

-- ── the file ──────────────────────────────────────────────────────────────
-- Row number is NOT paragraph number, and the difference is a silent
-- mis-cast. The map on disk is keyed by the paragraph the ENGINE will count,
-- and the engine counts blank-line separated paragraphs of the script file —
-- where a row with no text writes nothing at all (its two separators collapse
-- into one). So an empty row shifts every paragraph after it down by one, and
-- a review that opens with "1 no text" (the engine's own placeholder row for a
-- paragraph it could not pair) would cast every voice one line early.
--
-- Both directions go through this one function: to_para[row] for writing,
-- to_row[paragraph] for reading back.
function V5.cast_ordinals(R)
  local to_para, to_row, n = {}, {}, 0
  for _, r in ipairs(R.rows or {}) do
    if (r.tr or ''):match('%S') then
      n = n + 1
      to_para[r.index] = n
      to_row[n] = r.index
    end
  end
  return to_para, to_row
end

-- Read <base>_speakers.json back into the cast. Speaker objects come through
-- the real JSON string decoder (names carry apostrophes and non-ASCII);
-- assignments are read with patterns because their two values — a slug key and
-- a voice id — are ASCII by construction and cannot carry an escape.
function V5.cast_load(R)
  local path = V5.cast_file(R)
  local raw  = path and read_all(path)
  local C    = R.cast
  if not (raw and C) then return false end

  local list = V5.json_object_array(raw, 'speakers')
  if #list == 0 then return false end
  C.speakers = {}
  for _, e in ipairs(list) do
    if #C.speakers < V5.CAST_MAX then
      local key = (tostring(e.key or ''):match('^[%w_]+$'))
                  or ('s' .. (#C.speakers + 1))
      C.speakers[#C.speakers + 1] = {
        key    = key,
        name   = (e.name ~= '' and e.name) or ('Speaker ' .. (#C.speakers + 1)),
        voice  = e.voice_id or '',
        colour = V5.CAST_COLOURS[(#C.speakers % #V5.CAST_COLOURS) + 1],
      }
    end
  end
  if #C.speakers == 0 then return false end

  C.by_row = {}
  local _, to_row = V5.cast_ordinals(R)
  local body = raw:match('"assignments"%s*:%s*(%b{})') or ''
  for idx, obj in body:gmatch('"(%d+)"%s*:%s*(%b{})') do
    local sp = V5.cast_find(R, obj:match('"speaker"%s*:%s*"([%w_]*)"') or '')
    if not sp then
      -- A map written by something that only recorded voice ids (the shape the
      -- engine documents) still casts correctly: match on the voice.
      local vid = obj:match('"voice_id"%s*:%s*"([%w_%-]*)"') or ''
      if vid ~= '' then
        for _, s in ipairs(C.speakers) do
          if s.voice == vid then sp = s break end
        end
      end
    end
    -- The key is a paragraph; the cast is kept by row. With no rows measured
    -- yet the two are the same thing, which is the right fallback.
    local n = tonumber(idx)
    if sp and n then V5.cast_assign(R, to_row[n] or n, sp.key) end
  end
  C.active = C.speakers[1].key
  C.dirty  = false
  return true
end

-- Write the map — or delete it. A single-voice run writes NO file and removes
-- a stale one: the whole run is the main voice and --voice-id already says so,
-- while a leftover map from an earlier cast would quietly re-cast this one.
-- Returns ok, path_or_reason, wrote(boolean).
function V5.cast_save(R)
  local path = V5.cast_file(R)
  if not path then return false, 'this run has no output folder', false end
  local C = V5.cast_ensure(R)

  local to_para = V5.cast_ordinals(R)
  local lines = {}
  for _, r in ipairs(R.rows or {}) do
    local s = V5.cast_of(R, r.index)
    -- A row with no text is not a paragraph of the script the engine reads,
    -- so it has no number to be cast under and nothing to speak.
    if s and to_para[r.index] and (s.voice or ''):match('%S') then
      lines[#lines + 1] = string.format(
        '    "%d": {"speaker": "%s", "voice_id": "%s"}',
        to_para[r.index], _json_escape(s.key), _json_escape(s.voice))
    end
  end
  if not V5.cast_multi(R) then
    os.remove(path)
    C.dirty = false
    return true, path, false
  end

  local f = io.open(path, 'wb')
  if not f then return false, path, false end
  f:write('{\n  "version": 1,\n')
  f:write(string.format('  "language": "%s",\n', _json_escape(R.lang or '')))
  f:write(string.format('  "default_voice_id": "%s",\n',
                        _json_escape((C.speakers[1] and C.speakers[1].voice) or '')))
  f:write('  "speakers": [\n')
  for i, s in ipairs(C.speakers) do
    f:write(string.format(
      '    {"key": "%s", "name": "%s", "voice_id": "%s"}%s\n',
      _json_escape(s.key), _json_escape(s.name or ''),
      _json_escape(s.voice or ''), i < #C.speakers and ',' or ''))
  end
  f:write('  ],\n  "assignments": {\n')
  f:write(table.concat(lines, ',\n'))
  f:write((#lines > 0 and '\n' or '') .. '  }\n}\n')
  f:close()
  C.dirty = false
  return true, path, true
end

-- Build the cast for this review, once. The main voice starts as the ⚙
-- Settings voice — the one the run would have used anyway — so a single-voice
-- run behaves exactly as it did before anyone opened this section.
function V5.cast_ensure(R)
  if R.cast then return R.cast end
  R.cast = { speakers = {}, by_row = {}, active = nil, open = false,
             dirty = false }
  V5.cast_load(R)
  if #R.cast.speakers == 0 then
    R.cast.speakers[1] = { key = 's1', name = V5.CAST_MAIN,
                           voice = VOICE_ID or '',
                           colour = V5.CAST_COLOURS[1] }
  end
  R.cast.active = R.cast.active or R.cast.speakers[1].key
  return R.cast
end

-- "Sadhguru:" / "Interviewer:" at the head of a paragraph. Read off the
-- ENGLISH side: the transcript keeps those labels, and a name transliterated
-- into the target script is not a name this can match.
V5.CAST_LABEL_PAT = "^%s*([%a][%w%s%.%-'&]-)%s*:%s"

-- Detect speaker labels and cast them. Returns speakers_added, rows_assigned.
-- It never edits the script: the label is the transcript's, and deciding
-- whether ElevenLabs should read it aloud is the proofreader's call.
function V5.cast_detect(R)
  local C = V5.cast_ensure(R)
  local order, rows_of = {}, {}
  for _, r in ipairs(R.rows or {}) do
    local src = ((r.en or ''):match('%S') and r.en) or r.tr or ''
    local nm  = src:match(V5.CAST_LABEL_PAT)
    if nm and V5.cells(nm) >= 2 and V5.cells(nm) <= 24 then
      if not rows_of[nm] then rows_of[nm] = {} order[#order + 1] = nm end
      local t = rows_of[nm]
      t[#t + 1] = r.index
    end
  end

  local added, assigned = 0, 0
  for _, nm in ipairs(order) do
    local sp
    for _, s in ipairs(C.speakers) do
      if (s.name or ''):lower() == nm:lower() then sp = s break end
    end
    if not sp and #C.speakers < V5.CAST_MAX then
      sp = V5.cast_add(R, nm, '')
      if sp then added = added + 1 end
    end
    if sp then
      for _, i in ipairs(rows_of[nm]) do
        V5.cast_assign(R, i, sp.key)
        assigned = assigned + 1
      end
    end
  end
  return added, assigned
end

-- ── the pieces ────────────────────────────────────────────────────────────
-- A speaker chip: a flat button carrying the speaker's colour as its TEXT
-- colour, lit when it is the active one. *w* is what the wrapping row budgeted
-- for it, so the two can never disagree.
function V5.cast_chip(ctx, id, label, colour, on, tip, w)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
                              on and V5.COL.accent or 0x2A313DFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),
                              on and V5.COL.accent_hi or 0x3B4655FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),
                              on and V5.COL.accent_act or 0x4B5768FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                              on and V5.COL.bright or (colour or V5.COL.text))
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 5.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 11.0, 4.0)
  local hit = reaper.ImGui_Button(ctx, label .. '##' .. id,
                                  w or V5.chip_w(ctx, label), 0)
  reaper.ImGui_PopStyleVar(ctx, 2)
  reaper.ImGui_PopStyleColor(ctx, 4)
  if tip and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(tip))
  end
  return hit
end

-- What a chip says: '● Name · 12' — who, and how many paragraphs are theirs.
function V5.cast_chip_label(sp, stat)
  return string.format('● %s · %d', sp.name or '?', (stat and stat.lines) or 0)
end

-- The compact combo the cast rows use. No search box and no fetch button of
-- its own — the editor carries one for the whole section — just every voice
-- the panel knows: bookmarks first and starred, then the fetched catalogue.
function V5.cast_voice_combo(ctx, id, cur, width)
  cur = cur or ''
  local NONE = '(no voice yet)'
  local items, cur_label, by = { NONE }, NONE, {}
  local function add(vc, star)
    local lbl = V5.voice_label(vc, star)
    items[#items + 1] = lbl
    by[lbl] = vc.id
    if vc.id == cur then cur_label = lbl end
  end
  for _, vc in ipairs(V5.bookmarks) do add(vc, true) end
  for _, vc in ipairs(_voices) do
    if not V5.bookmark_index(vc.id) then add(vc, false) end
  end
  -- An id that is in neither list — typed into ⚙ Settings, or fetched for
  -- another language — stays selected instead of reading as "(no voice yet)".
  if cur ~= '' and cur_label == NONE then
    local lbl = V5.voice_label({ id = cur, name = V5.voice_name(cur) }, false)
    items[#items + 1] = lbl
    by[lbl] = cur
    cur_label = lbl
  end
  reaper.ImGui_SetNextItemWidth(ctx, width)
  local changed, picked = _ui_combo(ctx, '##cv' .. id, cur_label, items)
  if changed then return (picked == NONE) and '' or (by[picked] or cur) end
  return cur
end

-- The strip: the whole cast at a glance, and the chip you press becomes the
-- ACTIVE speaker — the one a click in the table casts a paragraph to.
--
-- It rides on the view row (List/Grid, S/M/L) rather than taking a row of its
-- own, and it NEVER wraps: this screen has no vertical slack left at 780 px,
-- and one more wrapping row is the difference between a table and a 1-pixel
-- sliver of one. What does not fit collapses into a '+N' chip that opens the
-- editor, where every speaker is reachable at any width.
function V5.cast_strip(ctx, R)
  local C     = V5.cast_ensure(R)
  local stats = V5.cast_stats(R)
  local room  = V5.room(ctx, 320) - 4
  local head  = (C.open and '▾ 🎙 Cast' or '▸ 🎙 Cast')
  local hw    = V5.chip_w(ctx, head)
  if hw > room then return end          -- a window this narrow keeps the row
  if V5.chip(ctx, head .. '##castopen',
             'The ElevenLabs voices this run will speak in. Add a speaker, ' ..
             'give it a voice, then click a paragraph’s chip to cast that ' ..
             'line to it. Nothing here is spoken or billed until Continue.')
  then
    C.open = not C.open
  end
  room = room - hw

  -- The warning is reserved for BEFORE the chips are laid out: a cast whose
  -- speakers push it off the row is exactly the cast that has one without a
  -- voice, and that is the one thing on this strip that must never be the
  -- part that gets dropped.
  local missing = V5.cast_voiceless(R)
  local main    = C.speakers[1]
  local warn, warn_fg, warn_bg
  if #missing > 0 then
    warn, warn_fg, warn_bg = string.format('%d without a voice', #missing),
                             V5.PLAN_COLOURS.over, 0x33191AFF
  elseif not (main.voice or ''):match('%S') then
    -- The engine's own fallback: the first voice in the account that matches
    -- the language. Named here, because "whatever ElevenLabs picks" is not
    -- something to discover from the finished dub.
    warn, warn_fg, warn_bg = 'main voice: auto', V5.COL.warn, V5.COL.chip_warn
  end
  local warn_w = warn and (V5.pill_w(ctx, warn) + 6) or 0
  if warn_w > room then warn, warn_w = nil, 0 end

  for i, s in ipairs(C.speakers) do
    local lbl  = V5.cast_chip_label(s, stats[s.key])
    local w    = V5.chip_w(ctx, lbl)
    local left = #C.speakers - i
    local more = (left > 0) and (V5.chip_w(ctx, '+' .. left) + 6) or 0
    if 6 + w + more + warn_w <= room then
      reaper.ImGui_SameLine(ctx, 0, 6)
      if V5.cast_chip(ctx, 'cb' .. s.key, lbl, s.colour, C.active == s.key,
            string.format('%s%s\n\nVoice: %s\n%d paragraph(s), about %d ' ..
                          'characters of speech.\n\nPress to make it the ' ..
                          'active speaker — then click a paragraph’s chip in ' ..
                          'the table to cast that line to it.',
              s.name or '?',
              (i == 1) and '  (main voice — every paragraph you do not cast ' ..
                           'to someone else is spoken by it)' or '',
              ((s.voice or '') ~= '')
                and ((V5.voice_name(s.voice) ~= '')
                     and (V5.voice_name(s.voice) .. '  ·  ' .. s.voice)
                     or s.voice)
                or 'none yet — pick one in the cast editor',
              (stats[s.key] or {}).lines or 0,
              (stats[s.key] or {}).chars or 0), w)
      then
        C.active = s.key
        -- Pressing a speaker that cannot speak opens the place where it can
        -- be given a voice: the chip is the only clue it is missing one.
        C.open = C.open or (s.voice or '') == ''
      end
      room = room - 6 - w
    else
      local n    = #C.speakers - i + 1
      local lbl2 = '+' .. n
      local w2   = V5.chip_w(ctx, lbl2)
      if 6 + w2 + warn_w <= room then
        reaper.ImGui_SameLine(ctx, 0, 6)
        if V5.cast_chip(ctx, 'cbmore', lbl2, V5.COL.text2, false,
              string.format('%d more speaker(s) than this row can show — ' ..
                            'open the cast to reach them.', n), w2) then
          C.open = true
        end
        room = room - 6 - w2
      end
      break
    end
  end

  if warn then
    reaper.ImGui_SameLine(ctx, 0, 6)
    V5.pill(ctx, warn, warn_fg, warn_bg)
  end
end

-- The editor. One row per speaker — colour, name, voice, audition, remove —
-- over a row of chips that act on the whole cast. Its own child so a cast of
-- eight scrolls instead of eating the table it is casting.
function V5.cast_editor(ctx, R, h)
  local C     = V5.cast_ensure(R)
  local stats = V5.cast_stats(R)
  h = h or math.min(212, 34 + #C.speakers * 30 + 38)
  if not reaper.ImGui_BeginChild(ctx, '##casted', -1, h,
                                 _child_border_flag()) then
    return
  end

  local kill, promote = nil, nil
  for i, s in ipairs(C.speakers) do
    local main   = (i == 1)
    local room   = V5.room(ctx, 520)
    local test_w = V5.chip_w(ctx, '🔊')
    local del_w  = V5.chip_w(ctx, '✕')
    local up_w   = V5.chip_w(ctx, '⇧ main')
    local name_w = 132
    -- The combo takes what the fixed pieces leave, with a floor: a voice line
    -- reading 'Sadhg…' is the one string in this row that must stay whole.
    local combo_w = math.max(150, room - name_w - test_w - del_w - up_w - 34)

    V5.wrap_begin(ctx, 6)
    V5.wrap_next(ctx, name_w)
    reaper.ImGui_SetNextItemWidth(ctx, name_w)
    local rvn, nm = reaper.ImGui_InputText(ctx, '##cn' .. s.key, s.name or '')
    if rvn then
      s.name  = nm
      C.dirty = true
    end
    if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
      reaper.ImGui_SetTooltip(ctx, V5.wrap(main
        and 'The main voice. Every paragraph you do not cast to someone else ' ..
            'is spoken by it, and it is the voice the run itself is launched ' ..
            'with. The name is yours — it is never spoken.'
        or  'This speaker’s name, for your eyes only — it is never spoken. ' ..
            'Cast paragraphs to it with its chip above, or from the ' ..
            'inspector on the right.'))
    end

    V5.wrap_next(ctx, combo_w)
    local nv = V5.cast_voice_combo(ctx, s.key, s.voice, combo_w)
    if nv ~= s.voice then
      s.voice = nv
      C.dirty = true
      -- Speaker 1 IS the run's voice: keeping ⚙ Settings in step means Regen,
      -- Track Voice and the next run all agree with what was cast here.
      if main and nv ~= '' then
        VOICE_ID = nv
        save_config_files()
      end
    end

    V5.wrap_next(ctx, test_w)
    local can_test = (s.voice or ''):match('%S') and not V5.busy()
    _ui_begin_disabled(ctx, not can_test)
    if V5.chip(ctx, '🔊##ct' .. s.key,
               'Speak a few seconds in this voice and play it here. One ' ..
               'short ElevenLabs call, nothing imported, nothing placed on ' ..
               'the timeline.') then
      -- The audition says the words this voice would actually speak: the
      -- selected paragraph when it is theirs, else their first line.
      local sample
      local sel = R.sel and R.rows[R.sel]
      if sel and V5.cast_of(R, sel.index) == s then sample = sel.tr end
      if not (sample or ''):match('%S') then
        for _, r in ipairs(R.rows or {}) do
          if V5.cast_of(R, r.index) == s and (r.tr or ''):match('%S') then
            sample = r.tr break
          end
        end
      end
      V5.start_voice_preview(s.voice, sample)
    end
    _ui_end_disabled(ctx)

    V5.wrap_next(ctx, up_w)
    _ui_begin_disabled(ctx, main)
    if V5.chip(ctx, '⇧ main##cm' .. s.key,
               'Make this the main voice. The two swap places: every ' ..
               'paragraph that was on the old main moves to it, and this ' ..
               'one’s lines stay this one’s.') then
      promote = i
    end
    _ui_end_disabled(ctx)

    V5.wrap_next(ctx, del_w)
    _ui_begin_disabled(ctx, main)
    if V5.chip(ctx, '✕##cx' .. s.key, main
               and 'The main voice cannot be removed — it is what every ' ..
                   'uncast paragraph falls back to.'
               or  'Remove this speaker. Its paragraphs go back to the main ' ..
                   'voice; nothing in the script changes.', true) then
      kill = s.key
    end
    _ui_end_disabled(ctx)

    local st   = stats[s.key] or {}
    local note = string.format('%d line(s) · %d chars', st.lines or 0,
                               st.chars or 0)
    V5.wrap_next(ctx, V5.text_w(ctx, note, 7) + 4)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
    reaper.ImGui_Text(ctx, V5.ellipsize(ctx, note,
                                        math.max(20, V5.room(ctx, 120) - 4)))
    reaper.ImGui_PopStyleColor(ctx)
    V5.wrap_end()
  end

  if kill then V5.cast_remove(R, kill) end
  -- Never both in one frame: a removal renumbers the list the promotion index
  -- points into, and the two buttons are one click apart.
  if promote and not kill and C.speakers[promote] then
    -- Swapping is the honest move: the paragraphs that were implicitly on the
    -- old main are named explicitly first, so nobody's lines change voice.
    local old = C.speakers[1]
    local new = C.speakers[promote]
    for _, r in ipairs(R.rows or {}) do
      if not C.by_row[r.index] then C.by_row[r.index] = old.key end
    end
    C.speakers[1], C.speakers[promote] = new, old
    for _, r in ipairs(R.rows or {}) do
      if C.by_row[r.index] == new.key then C.by_row[r.index] = nil end
    end
    C.active = new.key
    C.dirty  = true
  end

  reaper.ImGui_Dummy(ctx, 0, 2)
  V5.wrap_begin(ctx, 6)

  local full = #C.speakers >= V5.CAST_MAX
  V5.wrap_next(ctx, V5.chip_w(ctx, '＋ Add speaker'))
  _ui_begin_disabled(ctx, full)
  if V5.chip(ctx, '＋ Add speaker##castadd', full
             and ('Eight speakers is the limit — that is a film, not a talk.')
             or  'Add another voice to the cast, then click the paragraphs ' ..
                 'that belong to it.') then
    local sp = V5.cast_add(R)
    if sp then C.active = sp.key end
  end
  _ui_end_disabled(ctx)

  local fetching = (V5.quiet_job == 'list_voices')
  local flabel   = fetching and ('⟳ Fetching voices…  ' .. _spinner_glyph())
                             or '⟳ Fetch voices'
  V5.wrap_next(ctx, V5.chip_w(ctx, flabel))
  _ui_begin_disabled(ctx, V5.busy())
  if V5.chip(ctx, flabel .. '##castfetch',
             'Pull the ElevenLabs voice catalogue for ' .. (LANGUAGE or '?') ..
             ' into every combo here. Reading the catalogue is free and ' ..
             'nothing is spoken.') then
    start_fetch_voices()
  end
  _ui_end_disabled(ctx)

  V5.wrap_next(ctx, V5.chip_w(ctx, '🔎 Detect speakers'))
  if V5.chip(ctx, '🔎 Detect speakers##castdet',
             'Read the "Name:" labels off the English column and cast those ' ..
             'paragraphs. It adds the speakers it finds and leaves the ' ..
             'script untouched — including the labels themselves, which ' ..
             'ElevenLabs would otherwise read aloud.') then
    local added, assigned = V5.cast_detect(R)
    if assigned == 0 then
      ui_set_banner('warn',
        'No "Name:" labels in the English column — cast the paragraphs by ' ..
        'hand: press a speaker chip, then click the chips in the table.')
    else
      ui_set_banner('info', string.format(
        '%d speaker(s) added, %d paragraph(s) cast from the English labels. ' ..
        'Give each new speaker a voice before continuing.', added, assigned))
    end
  end

  local n_assigned = 0
  for _ in pairs(C.by_row) do n_assigned = n_assigned + 1 end
  V5.wrap_next(ctx, V5.chip_w(ctx, '⟲ Reset casting'))
  _ui_begin_disabled(ctx, n_assigned == 0)
  if V5.chip(ctx, '⟲ Reset casting##castclr',
             'Put every paragraph back on the main voice. The speakers stay ' ..
             'in the cast.') then
    C.by_row = {}
    C.dirty  = true
  end
  _ui_end_disabled(ctx)

  local hint = (#_voices == 0 and #V5.bookmarks == 0)
    and 'No voices loaded yet — "Fetch voices" fills these combos from your ElevenLabs account.'
    or  string.format('%d paragraph(s) cast to a second voice · the map is saved beside the run as %s',
                      n_assigned,
                      basename(V5.cast_file(R) or 'speakers.json'))
  V5.wrap_next(ctx, V5.text_w(ctx, hint, 7) + 4)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.hint)
  reaper.ImGui_Text(ctx, V5.ellipsize(ctx, hint,
                                      math.max(24, V5.room(ctx, 200) - 4)))
  reaper.ImGui_PopStyleColor(ctx)
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(hint))
  end
  V5.wrap_end()

  reaper.ImGui_EndChild(ctx)
end

-- The per-paragraph control in the table's stamp column: who speaks this line,
-- and a click to cast it to the active speaker. Drawn only once the cast has
-- someone to cast to — a column of identical '● Sadhguru' chips on a
-- single-voice run is noise on the screen that exists to be scanned.
function V5.cast_row_chip(ctx, R, r, cell)
  if not V5.cast_multi(R) then return end
  local C   = R.cast
  local sp  = V5.cast_of(R, r.index)
  local act = V5.cast_active(R)
  if not (sp and act) then return end
  local lbl = V5.ellipsize(ctx, '● ' .. (sp.name or '?'), math.max(20, cell - 6))
  if V5.cast_chip(ctx, 'cr' .. r.index, lbl, sp.colour, false,
        string.format('Spoken by %s.\n\nClick to cast this paragraph to %s%s.',
          sp.name or '?', act.name or '?',
          (sp.key == act.key) and ' — it already is, so this puts it back on ' ..
          (C.speakers[1].name or 'the main voice') or ''), cell)
  then
    if sp.key == act.key then V5.cast_assign(R, r.index, C.speakers[1].key)
    else                      V5.cast_assign(R, r.index, act.key) end
    R.sel = r.index
  end
end

-- The inspector's block: the whole cast as a list of radio-ish rows for THIS
-- paragraph. The table's chip is the fast way; this is the one that says what
-- the choices are.
function V5.cast_inspector(ctx, R, row)
  local C = V5.cast_ensure(R)
  V5.cap(ctx, 'SPOKEN BY')
  local cur = V5.cast_of(R, row.index)
  for _, s in ipairs(C.speakers) do
    local on  = (cur and cur.key == s.key)
    local lbl = (on and '● ' or '○ ') .. (s.name or '?')
    local w   = V5.room(ctx, 200)
    if V5.cast_chip(ctx, 'ci' .. s.key, V5.ellipsize(ctx, lbl, w - 8),
          s.colour, on,
          ((s.voice or '') ~= '')
            and ('Voice: ' .. (V5.voice_name(s.voice) ~= ''
                 and (V5.voice_name(s.voice) .. '  ·  ' .. s.voice)
                 or s.voice))
            or 'This speaker has no voice yet — pick one in the cast editor.',
          w) then
      V5.cast_assign(R, row.index, s.key)
      C.active = s.key
    end
  end
  reaper.ImGui_Dummy(ctx, 0, 2)
end

-- ─── The pieces ───────────────────────────────────────────────────────────
-- The tally, as chips. Same shape as Studio's, plus 'untimed' — a count you
-- are meant to act on should not have to be picked out of prose.
function V5.review_tally(ctx, R)
  V5.wrap_begin(ctx, 6)
  for _, k in ipairs(V5.REVIEW_VERDICTS) do
    local n = R.counts[k] or 0
    if n > 0 then
      local label   = string.format('%d %s', n, (V5.review_look(k)))
      local fg      = select(2, V5.review_look(k))
      local bg = (k == 'over') and 0x33191AFF
              or (k == 'tight') and V5.COL.chip_warn
              or (k == 'fits') and V5.COL.chip_ok
              or V5.COL.chip_info
      V5.wrap_next(ctx, V5.pill_w(ctx, label))
      V5.pill(ctx, label, fg, bg)
    end
  end
  V5.wrap_end()
end

-- The clipboard round-trip and the files, as one wrapping row of chips. These
-- were five 130 px buttons that came to 662 px; a chip is as wide as its own
-- label and the row wraps rather than clipping (v0.26).
function V5.review_toolbar(ctx, R)
  V5.wrap_begin(ctx, 6)

  V5.wrap_next(ctx, V5.chip_w(ctx, '📋 Copy script'))
  if V5.chip(ctx, '📋 Copy script',
             'The whole translation on the clipboard. REAPER cannot shape ' ..
             'Indic conjuncts, so this is the way to READ it properly: copy ' ..
             'it out, edit it anywhere, paste it back.') then
    reaper.ImGui_SetClipboardText(ctx, review_collect_text())
    ui_set_banner('info', 'Whole translation copied — paste it into any editor.')
  end

  V5.wrap_next(ctx, V5.chip_w(ctx, '📋 Copy English'))
  if V5.chip(ctx, '📋 Copy English',
             'The English transcript, one paragraph per row — the same rows ' ..
             'this screen lists.') then
    reaper.ImGui_SetClipboardText(ctx,
      table.concat(R.en_paras, "\n\n") .. "\n")
    ui_set_banner('info', 'English transcript copied to the clipboard.')
  end

  V5.wrap_next(ctx, V5.chip_w(ctx, '📥 Paste script'))
  if V5.chip(ctx, '📥 Paste script',
             'Replace the translation with the clipboard. Keep paragraphs ' ..
             'separated by one blank line — that separation is what keeps ' ..
             'each paragraph on its own slot.') then
    local txt = reaper.ImGui_GetClipboardText(ctx)
    if txt and txt:match("%S") then
      _review_replace_text(txt)
      ui_set_banner('info', string.format(
        'Clipboard pasted — %d paragraph(s) replace the translation.',
        #R.tr_paras))
    else
      ui_set_banner('warn', 'The clipboard is empty — nothing to paste.')
    end
  end

  V5.wrap_next(ctx, V5.chip_w(ctx, 'Open in editor'))
  if V5.chip(ctx, 'Open in editor',
             'Save, then open the edited script in the system editor.') then
    if save_review_text() then open_path(R.edited_path) end
  end

  V5.wrap_next(ctx, V5.chip_w(ctx, '⟲ Reload file'))
  if V5.chip(ctx, '⟲ Reload file',
             'Read the script back from disk — after editing it elsewhere, ' ..
             'or to throw away every change made here.') then
    local path = file_exists(R.edited_path) and R.edited_path
                 or R.manifest.translation_text
    local raw = read_all(path or "")
    if raw then
      _review_replace_text(raw)
      R.dirty = false
      ui_set_banner('info', 'Translation reloaded from:\n' .. path)
    else
      ui_set_banner('error', 'Could not read:\n' .. tostring(path))
    end
  end

  V5.wrap_next(ctx, V5.chip_w(ctx, '📁 Folder'))
  if V5.chip(ctx, '📁 Folder', "Open this run's output folder.") then
    if (R.manifest.out_dir or '') ~= '' then open_path(R.manifest.out_dir) end
  end

  V5.wrap_end()
end

-- Play / stop / follow, plus what the transport is aligned to. Drawn only for
-- a timed run: without an SRT there is no position to seek to.
function V5.review_transport(ctx, R)
  local row = R.sel and R.rows[R.sel]
  V5.wrap_begin(ctx, 6)

  V5.wrap_next(ctx, V5.chip_w(ctx, '▶ Play here'))
  if V5.chip(ctx, '▶ Play here',
             "Move REAPER's edit cursor to this paragraph's place in the " ..
             'English audio and play from there. This is the English you are ' ..
             'proofreading a translation of — nothing has been synthesized yet.')
  then
    if not V5.review_seek(R, row, true) then
      ui_set_banner('warn',
        'That paragraph has no source timing to play from.')
    end
  end

  V5.wrap_next(ctx, V5.chip_w(ctx, '■ Stop'))
  if V5.chip(ctx, '■ Stop', 'Stop REAPER’s transport.') then
    if reaper.CSurf_OnStop then reaper.CSurf_OnStop() end
  end

  local flabel = R.follow and '◉ Following play' or '○ Follow play'
  V5.wrap_next(ctx, V5.chip_w(ctx, flabel))
  if V5.chip(ctx, flabel,
             'While REAPER plays, keep the selected paragraph under the play ' ..
             'cursor. Turn it off before typing — it moves the selection.') then
    R.follow = not R.follow
  end

  V5.wrap_next(ctx, V5.chip_w(ctx, '⇱ Re-link audio'))
  if V5.chip(ctx, '⇱ Re-link audio',
             'Find this run’s English audio on the timeline again and use ' ..
             'where it sits as the zero for every preview. Press it after ' ..
             'moving or importing the item.') then
    if V5.review_relink(R) then
      ui_set_banner('info', string.format(
        'Linked to "%s" at %s on the timeline.', R.linked or '?',
        V5.review_at(R.time_off or 0)))
    else
      ui_set_banner('warn', string.format(
        'No item on the timeline plays "%s" — previews are timed from 0:00.',
        basename((R.manifest and R.manifest.audio) or '(no audio)')))
    end
  end

  local note = R.linked
    and string.format('aligned to %s at %s', R.linked,
                      V5.review_at(R.time_off or 0))
    or 'timed from 0:00 — the source item is not in this project'
  V5.wrap_next(ctx, V5.text_w(ctx, note, 7) + 4)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
  reaper.ImGui_Text(ctx, V5.ellipsize(ctx, note, math.max(24, V5.room(ctx, 200) - 4)))
  reaper.ImGui_PopStyleColor(ctx)

  V5.wrap_end()
end

-- Layout and text size. Both persist: proofreading is a long sit, and these
-- are the two things people change before starting one.
function V5.review_view_row(ctx, R)
  local lay = V5.segmented(ctx, 'revlay', V5.review_layout or 'list', {
    { 'list', 'List',
      'One line per paragraph, so the whole script is scannable and the bad ' ..
      'fits stand out. The selected paragraph is edited in the inspector.' },
    { 'grid', 'Grid',
      'English beside an editable box for every paragraph — the v0.4 view, ' ..
      'which is what a full retype wants.' },
  })
  if lay ~= V5.review_layout then
    V5.review_layout = lay
    save_settings()
  end

  reaper.ImGui_SameLine(ctx, 0, 12)
  local opts = {}
  for i, px in ipairs(V5.REVIEW_PX_OPTS) do
    opts[i] = { px, ({ 'S', 'M', 'L' })[i] or tostring(px),
                string.format('Script text at %d px.', px) }
  end
  local px = V5.segmented(ctx, 'revpx', V5.review_px or 15, opts)

  -- v0.30: the cast rides here rather than on a row of its own — see
  -- V5.cast_strip for why this screen cannot afford another row.
  reaper.ImGui_SameLine(ctx, 0, 12)
  V5.cast_strip(ctx, R)

  if px ~= V5.review_px then
    V5.review_px = px
    -- Every wrapped box was flowed in the old face; drop the cached flows so
    -- they are rebuilt at this one. The canonical text is in R.tr_paras, so
    -- nothing typed is lost by clearing them.
    V5.script_box_state = {}
    save_settings()
  end
end

-- ─── List: one line per paragraph ─────────────────────────────────────────
-- #, at, fit. 88 for the verdict, not 62: 'OVERFLOWS' is the widest of them
-- and the one column that must never be the one that gets ellipsized.
-- 104 for the voice column (v0.30): a speaker chip reading '● Interview…' is
-- still the right speaker, but the column only exists on a multi-voice run.
V5.REVIEW_COL_W = { 30, 46, 88, 104 }

function V5.review_table(ctx, R)
  if not R.use_table then
    -- Old ReaImGui without tables. Nothing is editable here — the caller has
    -- already fallen back to Grid in that case; this stays as the safety net.
    if reaper.ImGui_BeginChild(ctx, '##revrows', -1, -6, _child_border_flag()) then
      for _, r in ipairs(R.rows) do
        local label, colour = V5.review_look(r.verdict)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), colour)
        reaper.ImGui_Text(ctx, V5.ellipsize(ctx, string.format(
          '%3d  %s  %s  —  %s', r.index, V5.review_at(r.start_s), label,
          V5.ellipsis(r.en, 60)), V5.room(ctx, 400) - 8))
        reaper.ImGui_PopStyleColor(ctx)
      end
      reaper.ImGui_EndChild(ctx)
    end
    return
  end

  local tflags = 0
  if reaper.ImGui_TableFlags_RowBg then tflags = tflags | reaper.ImGui_TableFlags_RowBg() end
  if reaper.ImGui_TableFlags_ScrollY then tflags = tflags | reaper.ImGui_TableFlags_ScrollY() end
  if reaper.ImGui_TableFlags_BordersInnerV then
    tflags = tflags | reaper.ImGui_TableFlags_BordersInnerV()
  end
  -- -6, not -1: a table flush against the canvas's bottom edge is a pixel away
  -- from asking the canvas for a scrollbar, and the canvas promised not to
  -- have one.
  -- The voice column exists only once there IS a second voice: a column of
  -- identical '● Sadhguru' chips is noise on the view whose job is scanning.
  local multi = V5.cast_multi(R)
  if not reaper.ImGui_BeginTable(ctx, '##revlist', multi and 6 or 5, tflags,
                                 -1, -6) then return end

  local fixed = reaper.ImGui_TableColumnFlags_WidthFixed
                and reaper.ImGui_TableColumnFlags_WidthFixed() or 0
  local stretch = reaper.ImGui_TableColumnFlags_WidthStretch
                  and reaper.ImGui_TableColumnFlags_WidthStretch() or 0
  reaper.ImGui_TableSetupColumn(ctx, '#',   fixed,   V5.REVIEW_COL_W[1])
  reaper.ImGui_TableSetupColumn(ctx, 'at',  fixed,   V5.REVIEW_COL_W[2])
  reaper.ImGui_TableSetupColumn(ctx, 'English', stretch, 1.0)
  reaper.ImGui_TableSetupColumn(ctx,
    ((R.lang or '') ~= '' and R.lang or 'Translation'), stretch, 1.0)
  if multi then
    reaper.ImGui_TableSetupColumn(ctx, 'voice', fixed, V5.REVIEW_COL_W[4])
  end
  reaper.ImGui_TableSetupColumn(ctx, 'fit', fixed,   V5.REVIEW_COL_W[3])
  if reaper.ImGui_TableSetupScrollFreeze then
    reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
  end
  reaper.ImGui_TableHeadersRow(ctx)

  for _, r in ipairs(R.rows) do
    reaper.ImGui_TableNextRow(ctx)
    local on = (R.sel == r.index)

    reaper.ImGui_TableSetColumnIndex(ctx, 0)
    if reaper.ImGui_Selectable then
      local span = reaper.ImGui_SelectableFlags_SpanAllColumns
                   and reaper.ImGui_SelectableFlags_SpanAllColumns() or 0
      if reaper.ImGui_Selectable(ctx, tostring(r.index) .. '##rr' .. r.index,
                                 on, span) then
        R.sel = r.index
      end
    else
      reaper.ImGui_Text(ctx, tostring(r.index))
    end
    if R.scroll_to == r.index then
      if reaper.ImGui_SetScrollHereY then reaper.ImGui_SetScrollHereY(ctx, 0.5) end
      R.scroll_to = nil
    end

    reaper.ImGui_TableSetColumnIndex(ctx, 1)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
    reaper.ImGui_Text(ctx, R.timed and V5.review_at(r.start_s) or '—')
    reaper.ImGui_PopStyleColor(ctx)

    -- Both text columns are ONE line, ellipsized to their own cell: a wrapped
    -- cell makes every row a different height and this list exists to be
    -- scanned. The paragraph itself is in the inspector.
    reaper.ImGui_TableSetColumnIndex(ctx, 2)
    local room = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.text2)
    reaper.ImGui_Text(ctx, V5.ellipsize(ctx, r.en,
                      type(room) == 'number' and room or 120))
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_TableSetColumnIndex(ctx, 3)
    room = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
      (r.verdict == 'empty') and V5.COL.dimmer or V5.COL.text)
    reaper.ImGui_Text(ctx, V5.ellipsize(ctx,
      (r.tr:match('%S') and r.tr) or '(no text)',
      type(room) == 'number' and room or 120))
    reaper.ImGui_PopStyleColor(ctx)

    if multi then
      reaper.ImGui_TableSetColumnIndex(ctx, 4)
      room = reaper.ImGui_GetContentRegionAvail(ctx)
      V5.cast_row_chip(ctx, R, r,
                       (type(room) == 'number' and room > 20) and room or 90)
    end

    reaper.ImGui_TableSetColumnIndex(ctx, multi and 5 or 4)
    local label, colour = V5.review_look(r.verdict)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), colour)
    room = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_Text(ctx, V5.ellipsize(ctx, label,
                      type(room) == 'number' and room or 60))
    reaper.ImGui_PopStyleColor(ctx)
  end
  reaper.ImGui_EndTable(ctx)
end

-- ─── Grid: the side-by-side editor ────────────────────────────────────────
function V5.review_grid(ctx, R)
  if not R.use_table then
    -- Old ReaImGui without tables: two plain children side by side, with the
    -- whole translation in one editable buffer on the right.
    local avail_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local half = math.floor((type(avail_w) == 'number' and avail_w or 600) / 2) - 6
    if reaper.ImGui_BeginChild(ctx, '##reven', half, -6, _child_border_flag()) then
      for _, p in ipairs(R.en_paras) do
        reaper.ImGui_TextWrapped(ctx, p)
        reaper.ImGui_Dummy(ctx, 0, 8)
      end
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_SameLine(ctx)
    local txt, rv = V5.wrapped_input(ctx, 'trall', R.tr_buffer or '', -6, 20,
                                     V5.review_px)
    if rv then
      R.tr_buffer = txt
      R.dirty     = true
    end
    return
  end

  local tflags = 0
  if reaper.ImGui_TableFlags_Borders then tflags = tflags | reaper.ImGui_TableFlags_Borders() end
  if reaper.ImGui_TableFlags_RowBg   then tflags = tflags | reaper.ImGui_TableFlags_RowBg()   end
  if reaper.ImGui_TableFlags_ScrollY then tflags = tflags | reaper.ImGui_TableFlags_ScrollY() end
  if not reaper.ImGui_BeginTable(ctx, '##review', 3, tflags, -1, -6) then return end

  local fixed = reaper.ImGui_TableColumnFlags_WidthFixed
                and reaper.ImGui_TableColumnFlags_WidthFixed() or 0
  local stretch = reaper.ImGui_TableColumnFlags_WidthStretch
                  and reaper.ImGui_TableColumnFlags_WidthStretch() or 0
  -- 92, the width of 'OVERFLOWS' plus the cell's own padding: the stamp
  -- column carries the verdict, and a verdict that reads 'OVERF…' is the one
  -- word on this screen that must not need a tooltip.
  reaper.ImGui_TableSetupColumn(ctx, 'at', fixed, 92)
  reaper.ImGui_TableSetupColumn(ctx, 'English (read-only)', stretch, 1.0)
  reaper.ImGui_TableSetupColumn(ctx,
    ((((R.lang or '') ~= '' and R.lang) or 'Translation') .. ' (editable)'),
    stretch, 1.0)
  if reaper.ImGui_TableSetupScrollFreeze then
    reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
  end
  reaper.ImGui_TableHeadersRow(ctx)

  for _, r in ipairs(R.rows) do
    reaper.ImGui_TableNextRow(ctx)

    -- The stamp column: which paragraph, where it starts, how it fits. It is
    -- also the row's click target — a Selectable spanning the row would sit
    -- over the text box and swallow every click meant for the editor.
    reaper.ImGui_TableSetColumnIndex(ctx, 0)
    local cell = reaper.ImGui_GetContentRegionAvail(ctx)
    cell = (type(cell) == 'number' and cell > 20) and cell or 60
    if reaper.ImGui_Selectable then
      if reaper.ImGui_Selectable(ctx, tostring(r.index) .. '##gr' .. r.index,
                                 R.sel == r.index) then
        R.sel = r.index
      end
    else
      reaper.ImGui_Text(ctx, tostring(r.index))
    end
    -- Follow / ↑ / ↓ / a click on the strip all select a paragraph that may be
    -- pages away; the Grid has to walk there too, not only the List.
    if R.scroll_to == r.index then
      if reaper.ImGui_SetScrollHereY then reaper.ImGui_SetScrollHereY(ctx, 0.5) end
      R.scroll_to = nil
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
    reaper.ImGui_Text(ctx, V5.ellipsize(ctx,
      R.timed and V5.review_at(r.start_s) or '—', cell))
    reaper.ImGui_PopStyleColor(ctx)
    local label, colour = V5.review_look(r.verdict)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), colour)
    reaper.ImGui_Text(ctx, V5.ellipsize(ctx, label, cell))
    reaper.ImGui_PopStyleColor(ctx)
    V5.cast_row_chip(ctx, R, r, cell)

    reaper.ImGui_TableSetColumnIndex(ctx, 1)
    local pushed = _push_font(ctx, V5.review_px)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBCCDDFF)
    reaper.ImGui_TextWrapped(ctx, r.en)
    reaper.ImGui_PopStyleColor(ctx)
    if pushed then _pop_font(ctx) end

    -- Wrapped like the paste boxes: ImGui's multiline input draws a paragraph
    -- as one endless line otherwise, which is unreadable for the very text
    -- this pane exists to proofread.
    reaper.ImGui_TableSetColumnIndex(ctx, 2)
    local txt, rv = V5.wrapped_input(ctx, 'tr' .. r.index, r.tr,
                                     _para_box_height(r.en, r.tr), 20,
                                     V5.review_px)
    if rv then
      R.tr_paras[r.index] = txt
      R.dirty = true
      R.sel   = r.index
    end
  end
  reaper.ImGui_EndTable(ctx)
end

-- ─── The inspector ────────────────────────────────────────────────────────
-- Everything about ONE paragraph, in the width the table does not need: its
-- fit, its numbers, the English it came from, and — in List — the editor.
function V5.review_inspector(ctx, R, editable)
  local row = R.sel and R.rows[R.sel]
  if not row then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
    reaper.ImGui_TextWrapped(ctx,
      'Click a row, or a bar in the strip, to read and edit that paragraph ' ..
      'here.')
    reaper.ImGui_PopStyleColor(ctx)
    return
  end

  V5.cap(ctx, string.format('PARAGRAPH %d OF %d', row.index, #R.rows))

  -- Step to the paragraph either side without leaving the inspector. '↑'/'↓'
  -- rather than arrows this font may not carry.
  _ui_begin_disabled(ctx, row.index <= 1)
  if reaper.ImGui_SmallButton(ctx, '↑##revprev') and row.index > 1 then
    R.sel, R.scroll_to = row.index - 1, row.index - 1
  end
  _ui_end_disabled(ctx)
  reaper.ImGui_SameLine(ctx, 0, 4)
  _ui_begin_disabled(ctx, row.index >= #R.rows)
  if reaper.ImGui_SmallButton(ctx, '↓##revnext') and row.index < #R.rows then
    R.sel, R.scroll_to = row.index + 1, row.index + 1
  end
  _ui_end_disabled(ctx)
  if R.timed then
    reaper.ImGui_SameLine(ctx, 0, 8)
    if reaper.ImGui_SmallButton(ctx, '▶##revplay') then
      V5.review_seek(R, row, true)
    end
    V5.hint(ctx, 'Play the English from this paragraph’s position.')
  end

  reaper.ImGui_Dummy(ctx, 0, 4)

  local label, colour = V5.review_look(row.verdict)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), colour)
  reaper.ImGui_Text(ctx, label)
  reaper.ImGui_PopStyleColor(ctx)

  if R.timed and row.dur > 0.05 then
    local room = row.dur + row.pause
    if reaper.ImGui_ProgressBar then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PlotHistogram(),
                                  (row.verdict == 'over') and V5.PLAN_COLOURS.over
                                  or (row.verdict == 'tight') and V5.PLAN_COLOURS.tight
                                  or V5.COL.go)
      reaper.ImGui_ProgressBar(ctx,
        math.min(1.0, (room > 0) and (row.est / room) or 0), -1, 7, '')
      reaper.ImGui_PopStyleColor(ctx)
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
    if row.verdict == 'over' then
      reaper.ImGui_TextWrapped(ctx, string.format(
        'About %.1f s of speech for a %.1f s slot (%.1f s with the pause ' ..
        'after it) — %.1f s too long. Shorten it here and the bar moves; ' ..
        'that costs nothing. Left as it is, the placer speeds it to %.2fx%s.',
        row.est, row.dur, room, row.over_s or 0, row.atempo,
        (row.atempo >= V5.MAX_ATEMPO - 0.001)
          and ' — the ceiling, so it will still run long' or ''))
    elseif row.verdict == 'tight' then
      reaper.ImGui_TextWrapped(ctx, string.format(
        'About %.1f s of speech in a %.1f s slot: it fits only by eating the ' ..
        'pause after it, so the rhythm tightens here.', row.est, row.dur))
    elseif row.verdict == 'short' then
      reaper.ImGui_TextWrapped(ctx, string.format(
        'About %.1f s of speech in a %.1f s slot — the rest of the slot stays ' ..
        'silent.', row.est, row.dur))
    else
      reaper.ImGui_TextWrapped(ctx, string.format(
        'About %.1f s of speech in a %.1f s slot — it fits, and it starts on ' ..
        'time.', row.est, row.dur))
    end
    reaper.ImGui_PopStyleColor(ctx)
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
    reaper.ImGui_TextWrapped(ctx, R.timed
      and 'This row has no English of its own, so there is no slot to measure it against.'
      or ('No English SRT was found for this run, so the fit cannot be ' ..
          'estimated here — the plan stage measures it against the audio.'))
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_Dummy(ctx, 0, 4)
  if R.timed and row.dur > 0.05 then
    V5.kv(ctx, 'At',    V5.review_at(row.start_s))
    V5.kv(ctx, 'Slot',  string.format('%.2f s', row.dur))
    V5.kv(ctx, 'Pause', string.format('%.2f s', row.pause))
    V5.kv(ctx, 'Est',   string.format('%.2f s', row.est))
    V5.kv(ctx, 'Rate',  string.format('%.1f chars/s', R.cps or 11.0))
  end
  V5.kv(ctx, 'Length', string.format('%d chars', V5.cells(row.tr or '')))

  -- v0.30: who speaks THIS paragraph. The table's chip is the fast way to
  -- cast a line; this is the one that shows what the choices are.
  reaper.ImGui_Dummy(ctx, 0, 4)
  reaper.ImGui_Separator(ctx)
  V5.cast_inspector(ctx, R, row)

  reaper.ImGui_Dummy(ctx, 0, 4)
  reaper.ImGui_Separator(ctx)
  V5.cap(ctx, 'ENGLISH')
  local pushed = _push_font(ctx, V5.review_px)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.text2)
  reaper.ImGui_TextWrapped(ctx, (row.en:match('%S') and row.en)
                                or '(no English for this row)')
  reaper.ImGui_PopStyleColor(ctx)
  if pushed then _pop_font(ctx) end

  reaper.ImGui_Dummy(ctx, 0, 4)
  V5.cap(ctx, ((((R.lang or '') ~= '' and R.lang) or 'Translation')):upper())
  if not editable then
    -- Grid already holds the editor for this paragraph; two boxes over one
    -- string is a way to lose a keystroke.
    local p2 = _push_font(ctx, V5.review_px)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.text)
    reaper.ImGui_TextWrapped(ctx, (row.tr:match('%S') and row.tr) or '(no text)')
    reaper.ImGui_PopStyleColor(ctx)
    if p2 then _pop_font(ctx) end
    return
  end

  -- The editor takes what is left of the column. Measuring is safe here and
  -- only here: it is the LAST thing in the inspector, so its height depends on
  -- the space left rather than the space left depending on it.
  local _, ay = reaper.ImGui_GetContentRegionAvail(ctx)
  local h = (type(ay) == 'number' and ay > 90) and (ay - 4) or 120
  local txt, rv = V5.wrapped_input(ctx, 'revsel' .. row.index, row.tr, h, 20,
                                   V5.review_px)
  if rv then
    R.tr_paras[row.index] = txt
    R.dirty = true
  end
end

-- ─── The screen ───────────────────────────────────────────────────────────
local function ui_phase_review(ctx)
  local R = _review
  if not R then _ui_phase = 'setup' return end
  local m = R.manifest
  -- Phase-changing actions are recorded and run after every Begin/End pair is
  -- closed: Continue launches the engine, Back drops _review, and returning
  -- from the middle of a frame with a child still open loses the frame.
  local act

  -- Measure once, before anything draws: the tally, the strip, the table and
  -- the inspector must all be reading the same answer this frame.
  V5.review_measure(R)
  V5.review_follow_poll(R)
  if not (R.sel and R.rows[R.sel]) then R.sel = R.rows[1] and 1 or nil end
  -- The cast reads the rows (it counts lines and characters per speaker), so
  -- it is built after the measurement and before anything draws.
  V5.cast_ensure(R)

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),  6.0, 6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 3.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),  8.0, 4.0)

  local body = V5.begin_body(ctx, 0, true)
  if not body then
    reaper.ImGui_PopStyleVar(ctx, 3)
    return
  end

  -- ── the head ─────────────────────────────────────────────
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn)
  reaper.ImGui_TextWrapped(ctx,
    'Paused for review — nothing has been spoken and nothing has been billed. ' ..
    'Fix the translation here, then continue to dubbing.')
  reaper.ImGui_PopStyleColor(ctx)
  _ui_render_banner(ctx)

  -- One line, ellipsized, with the whole thing (and the paths it names) on
  -- its tooltip: the head is fixed-height by construction and the edited
  -- file's path is 120 characters of it on a real run.
  local meta = string.format('%s  ·  %d paragraph(s)  ·  %s  ·  editing %s%s',
    (m.language ~= '' and m.language or LANGUAGE), #R.rows,
    R.timed and ('timed from ' .. basename(m.en_srt or ''))
             or 'no English SRT in this run — no timings',
    basename(R.edited_path),
    -- The casting is unsaved work too: it lives in the same file pair and is
    -- lost by the same Back to setup, so it counts in the same word.
    (R.dirty or (R.cast and R.cast.dirty)) and '  ·  unsaved edits' or '')
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
  reaper.ImGui_Text(ctx, V5.ellipsize(ctx, meta,
                                      math.max(24, V5.room(ctx, 400) - 8)))
  reaper.ImGui_PopStyleColor(ctx)
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(meta) .. '\n\n' .. R.edited_path)
  end
  V5.script_font_warning(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)

  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  if type(avail) ~= 'number' or avail <= 0 then avail = 1024 end
  -- The inspector gives width back rather than squeezing the canvas, and below
  -- a floor it goes entirely rather than becoming a column too narrow for its
  -- own key/value rows — the same rule Studio's has.
  local col_w = math.min(V5.CTX_W + 40, math.max(0, avail - 440))
  if col_w < V5.REVIEW_INSP_MIN then col_w = 0 end
  local bot_h = V5.review_bot_h(avail)

  local layout = V5.review_layout or 'list'
  -- Two demotions, both about not stranding the editor: a ReaImGui with no
  -- tables cannot draw the List, and with no inspector column there is nowhere
  -- for List's editor to live.
  if not R.use_table or col_w == 0 then layout = 'grid' end

  -- ── canvas ───────────────────────────────────────────────
  if reaper.ImGui_BeginChild(ctx, '##revcanvas',
                             col_w > 0 and -(col_w + 8) or -1, -bot_h,
                             0, V5.noscroll_flags()) then
    V5.review_toolbar(ctx, R)

    -- This one has to be SEEN, not hovered for: the first reaction to this
    -- screen in an Indic language is that the app has corrupted the script.
    -- One line (the head is sized as if everything in it is), the rest on the
    -- tooltip.
    local shape = 'Script looks broken? REAPER cannot shape Indic ' ..
                  'conjuncts — the AUDIO is not affected. For a perfect ' ..
                  'view: 📋 Copy script → edit anywhere → 📥 Paste script, ' ..
                  'or Open in editor → save → ⟲ Reload file.'
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.hint)
    reaper.ImGui_Text(ctx, V5.ellipsize(ctx, shape,
                                        math.max(24, V5.room(ctx, 400) - 8)))
    reaper.ImGui_PopStyleColor(ctx)
    if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
      reaper.ImGui_SetTooltip(ctx, V5.wrap(shape))
    end

    if R.timed then
      reaper.ImGui_Dummy(ctx, 0, 2)
      V5.review_tally(ctx, R)
      R.legend = 'English above · your translation at its estimated spoken ' ..
                 'length below · click a bar to open that paragraph'
      V5.plan_strip(ctx, R)
      V5.review_transport(ctx, R)
    end

    reaper.ImGui_Dummy(ctx, 0, 2)
    V5.review_view_row(ctx, R)
    reaper.ImGui_Dummy(ctx, 0, 2)

    -- v0.30: the cast strip is ON the view row above (it cannot afford a row
    -- of its own); the editor it opens is drawn here, directly over the table
    -- whose chips it fills in. It takes what the table can spare and no more:
    -- below that it does not draw at all rather than squeeze the script off
    -- the screen — the strip's chips and the inspector still cast paragraphs.
    if R.cast.open then
      local _, ay = reaper.ImGui_GetContentRegionAvail(ctx)
      local free  = (type(ay) == 'number') and ay or 0
      local want  = math.min(212, 34 + #R.cast.speakers * 30 + 38)
      local h     = math.min(want, free - 66)
      if h >= 90 then
        V5.cast_editor(ctx, R, h)
        reaper.ImGui_Dummy(ctx, 0, 2)
      end
    end

    if layout == 'grid' then V5.review_grid(ctx, R)
    else                     V5.review_table(ctx, R) end
    reaper.ImGui_EndChild(ctx)
  end

  -- ── inspector ────────────────────────────────────────────
  if col_w > 0 then
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_BeginChild(ctx, '##revinsp', -1, -bot_h,
                               _child_border_flag()) then
      V5.review_inspector(ctx, R, layout == 'list')
      reaper.ImGui_EndChild(ctx)
    end
  end

  -- ── the transport bar ────────────────────────────────────
  -- Pinned, and in the same place as Studio's and the Dub screen's, so the
  -- button that spends money is always where your hand already is.
  reaper.ImGui_Separator(ctx)
  V5.wrap_begin(ctx, 8)

  V5.wrap_next(ctx, 110)
  if reaper.ImGui_Button(ctx, '💾 Save', 110, 30) then act = 'save' end

  V5.wrap_next(ctx, 200)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        V5.COL.go)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), V5.COL.go_hi)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  V5.COL.go_act)
  if reaper.ImGui_Button(ctx, '▶  Continue to dubbing', 200, 30) then
    act = 'continue'
  end
  reaper.ImGui_PopStyleColor(ctx, 3)

  V5.wrap_next(ctx, 100)
  if reaper.ImGui_Button(ctx, 'Skip edit', 100, 30) then act = 'skip' end

  V5.wrap_next(ctx, 120)
  if reaper.ImGui_Button(ctx, 'Back to setup', 120, 30) then act = 'back' end

  local over_n = (R.counts and R.counts.over) or 0
  local note = (R.dirty or (R.cast and R.cast.dirty))
    and 'Unsaved edits — Continue saves them first, so nothing typed or cast here is lost.'
    or (over_n > 0 and string.format(
         '%d paragraph(s) run past their slot — shortening them now costs ' ..
         'nothing; left alone, the placer speeds them up.', over_n))
    or 'Continue runs emotion, TTS and sync on this script — that is what costs credits.'
  V5.wrap_next(ctx, 120)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                              over_n > 0 and V5.PLAN_COLOURS.over or V5.COL.hint)
  reaper.ImGui_Text(ctx, V5.ellipsize(ctx, note,
                                      math.max(24, V5.room(ctx, 200) - 8)))
  reaper.ImGui_PopStyleColor(ctx)
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(note))
  end
  V5.wrap_end()

  reaper.ImGui_EndChild(ctx)   -- ##tabbody
  reaper.ImGui_PopStyleVar(ctx, 3)

  -- Every child is closed: it is safe to launch, or to change the phase, now.
  if act == 'save' then
    if save_review_text() then
      -- The casting is part of what you just proofread, so one button saves
      -- both: the script, and the map of who speaks it.
      local ok, where, wrote = V5.cast_save(R)
      ui_set_banner(ok and 'info' or 'warn',
        'Saved:\n' .. R.edited_path ..
        ((ok and wrote) and ('\n' .. tostring(where)) or '') ..
        ((not ok) and ('\n\nThe cast could not be saved: ' .. tostring(where))
                  or ''))
    end
  elseif act == 'continue' or act == 'skip' then
    -- v0.30: a cast speaker with paragraphs but no voice stops the run here,
    -- where it costs nothing. Past this button the engine would have to guess.
    local missing = V5.cast_voiceless(R)
    if #missing > 0 then
      local names = {}
      for _, s in ipairs(missing) do names[#names + 1] = s.name or '?' end
      R.cast.open = true
      ui_set_banner('error', string.format(
        'No ElevenLabs voice for %s. Pick one in 🎙 Cast (or remove the ' ..
        'speaker — its paragraphs go back to the main voice), then continue.',
        table.concat(names, ', ')))
    elseif act == 'continue' then
      -- Capture the path first: a successful launch clears _review.
      local edited = R.edited_path
      if save_review_text() then launch_dub_continue(edited) end
    else
      -- Continue with the engine's own translation file, ignoring every edit.
      launch_dub_continue(R.manifest.translation_text)
    end
  elseif act == 'back' then
    -- The translate step already finished — nothing to cancel. The review
    -- manifest stays in status/, so setup offers to resume it.
    _resume_manifest = R.manifest
    _review = nil
    _ui_phase = 'setup'
  end
end

-- ─── v0.13 Plan phase (pause-aware dry run, the approval gate) ────────────
-- The last stop before any credit is spent. The readable timeline lives in
-- the HTML file (ImGui cannot shape Indic conjuncts, so target text is not
-- legible in this window) — here we show the numbers, which ARE legible,
-- and hold the Approve button.

V5.PLAN_COLOURS = {
  fits  = 0x55CC77FF,
  tight = 0xE8A13AFF,
  over  = 0xE5584AFF,
  short = 0x6FA8DCFF,
  empty = 0x99999FFF,
}
V5.PLAN_LABELS = {
  fits = 'fits', tight = 'eats pause', over = 'OVERFLOWS',
  short = 'short', empty = 'no text',
}

function V5.plan_reload()
  local P = V5.plan
  if not (P and P.manifest) then return end
  -- Re-measures the plan file's own TR: lines against freshly detected
  -- pauses, so corrections pasted from the review page (or typed into the
  -- file by hand) survive. Free: the Scribe transcription is cached on disk.
  -- Falls back to re-spreading the pasted script only if the plan file has
  -- gone missing.
  local plan_path = P.plan_path
  if plan_path == "" or not file_exists(plan_path) then plan_path = nil end
  V5.start_plan_run(V5.plan_script_path, plan_path)
end

-- v0.15: take the corrected plan the review page put on the clipboard, write
-- it over the plan file, and re-measure. The page cannot write to disk (it is
-- opened as file://, with no server), and that is deliberate — nothing lands
-- in a paid run without passing through this button.
function V5.plan_paste_corrections(ctx)
  local P = V5.plan
  if not P then return end
  local txt = reaper.ImGui_GetClipboardText(ctx)
  if not (txt and txt:match("%S")) then
    ui_set_banner("warn",
      "The clipboard is empty — press “Copy corrected plan” in the review " ..
      "page first (🌐 Open review page).")
    return
  end
  txt = _strip_bom(txt):gsub("\r\n", "\n"):gsub("\r", "\n")

  -- A half-copied page, or the wrong clipboard entirely, must not overwrite
  -- a good plan: the shape is checked before anything is written.
  local rows_n, tr_n = 0, 0
  for line in (txt .. "\n"):gmatch("(.-)\n") do
    local t = line:match("^%s*(.-)%s*$")
    if t:match("^%[%s*%d+%s*%]%s*%[%s*%d+%s*ms%s*%]") then
      rows_n = rows_n + 1
    elseif t:sub(1, 3) == "TR:" then
      tr_n = tr_n + 1
    end
  end
  if rows_n == 0 or tr_n == 0 then
    ui_set_banner("error",
      "That clipboard is not a sync plan — it has no [index] [start] rows " ..
      "with TR: lines. Use “Copy corrected plan” at the bottom of the " ..
      "review page.")
    return
  end
  if rows_n ~= #P.rows then
    ui_set_banner("error", string.format(
      "That plan has %d chunk(s) but this run has %d — it is from a " ..
      "different (or older) preview. Re-open the review page for THIS run " ..
      "and copy again.", rows_n, #P.rows))
    return
  end

  -- Keep one step back: the reload rewrites the plan file, so without this
  -- a bad paste would take the previous assignment with it.
  local raw = read_all(P.plan_path)
  if raw then
    local bak = io.open(P.plan_path .. ".bak", "wb")
    if bak then bak:write(raw) bak:close() end
  end

  local f = io.open(P.plan_path, "wb")
  if not f then
    ui_set_banner("error", "Could not write:\n" .. P.plan_path)
    return
  end
  f:write(txt)
  f:close()
  ui_set_banner("info", string.format(
    "%d corrected chunk(s) written to the plan — re-measuring against the " ..
    "audio…", tr_n))
  V5.plan_reload()
end

-- ─── The lane strip (v0.15) ──────────────────────────────────────────────
-- Source speech above, estimated dub below, on one time axis. Drawn with the
-- draw list instead of widgets on purpose: rectangles need no text shaping,
-- so this is the one honest picture of the whole run the panel can render for
-- an Indic language. A dub bar longer than the source bar above it IS the
-- overflow — nothing has to be read to see it.

V5.STRIP_H = 62

-- Tick spacing, and whether there is room to LABEL the ticks.
--
-- v0.26: this used to pick a step so that at most 12 ticks fitted the
-- DURATION, with no reference to how wide the strip was. Twelve 'm:ss' labels
-- need roughly 12 * 42 px, so every strip narrower than ~500 px drew them on
-- top of each other — and the only guard was `if w < 80 then return end`, a
-- width at which the ruler was long past unreadable.
--
-- *usable* and *label_w* are optional so the old one-argument call still means
-- what it meant. Returns the step in seconds, plus false when the labels have
-- to be dropped and the bare marks kept.
V5.STRIP_STEPS = { 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800 }

function V5.strip_step(total, usable, label_w)
  local function pick(max_ticks)
    for _, s in ipairs(V5.STRIP_STEPS) do
      if total / s <= max_ticks then return s end
    end
    return 3600
  end
  if not (usable and label_w and label_w > 0) then return pick(12), true end
  -- 12 px of air between one label's end and the next tick.
  local room = math.floor(usable / (label_w + 12))
  if room >= 2 then return pick(math.min(12, room)), true end
  -- Not room for two labels side by side. Marks still carry the rhythm, and a
  -- strip with no numbers reads as "zoom in", which is true.
  return pick(12), false
end

function V5.plan_strip(ctx, P)
  local dl = reaper.ImGui_GetWindowDrawList and
             reaper.ImGui_GetWindowDrawList(ctx)
  local rectf = reaper.ImGui_DrawList_AddRectFilled
  local rect  = reaper.ImGui_DrawList_AddRect
  local addtx = reaper.ImGui_DrawList_AddText
  if not (dl and rectf and rect and addtx and reaper.ImGui_GetCursorScreenPos
          and reaper.ImGui_InvisibleButton and reaper.ImGui_GetMousePos) then
    return                          -- old ReaImGui: the table below is enough
  end

  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  if w < 80 then return end
  local H = V5.STRIP_H
  reaper.ImGui_InvisibleButton(ctx, '##planstrip', w, H)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local clicked = reaper.ImGui_IsItemClicked and reaper.ImGui_IsItemClicked(ctx)

  local pad     = 6
  local left    = x0 + pad
  local usable  = w - pad * 2
  local total   = math.max(P.total_s or 1.0, 0.001)
  local function tx(t) return left + (t / total) * usable end

  local ruler_y = y0 + 2
  local lane1_y = y0 + 18
  local lane2_y = y0 + 40
  local lane_h  = 18

  rectf(dl, x0, y0, x0 + w, y0 + H, 0x191B1EFF, 4)
  rectf(dl, left, lane1_y, left + usable, lane1_y + lane_h, 0x1F2226FF, 2)
  rectf(dl, left, lane2_y, left + usable, lane2_y + lane_h, 0x1F2226FF, 2)

  -- Ruler. Latin digits, so these labels are legible whatever the target is.
  -- The step is budgeted in PIXELS from the widest label the ruler can draw
  -- ('00:00' — every label is at most that wide), not from the duration.
  local label_w      = V5.text_w(ctx, '00:00', 8)
  local step, do_lbl = V5.strip_step(total, usable, label_w)
  local t = 0
  while t <= total do
    local x = tx(t)
    rectf(dl, x, ruler_y, x + 1, y0 + H - 3, 0x2E3338FF, 0)
    if do_lbl then
      addtx(dl, x + 3, ruler_y, 0x6F7A83FF,
            string.format('%d:%02d', math.floor(t / 60), math.floor(t % 60)))
    end
    t = t + step
  end

  -- Bars. The pause after each chunk is hatched with short dashes so the
  -- rhythm the dub has to keep is visible, not implied by empty space.
  for _, r in ipairs(P.rows) do
    local xa, xb = tx(r.start_s), tx(r.start_s + math.max(r.dur, 0.02))
    if xb - xa < 2 then xb = xa + 2 end
    rectf(dl, xa, lane1_y + 3, xb, lane1_y + lane_h - 3, 0x5B6470FF, 2)
    if r.pause > 0.01 then
      local px, pe = tx(r.start_s + r.dur), tx(r.start_s + r.dur + r.pause)
      local dx = px
      while dx < pe - 1 do
        rectf(dl, dx, lane1_y + 7, math.min(dx + 3, pe),
              lane1_y + lane_h - 7, 0x3A4046FF, 0)
        dx = dx + 6
      end
    end
    if r.est > 0 then
      local ea = tx(r.start_s)
      local eb = tx(r.start_s + r.est)
      if eb - ea < 2 then eb = ea + 2 end
      rectf(dl, ea, lane2_y + 3, eb, lane2_y + lane_h - 3,
            V5.PLAN_COLOURS[r.verdict] or 0x99999FFF, 2)
    end
    if P.sel == r.index then
      rect(dl, xa - 1, lane1_y + 1, xb + 1, lane1_y + lane_h - 1,
           0xCFD7DEFF, 2, 0, 1.5)
      local eb = tx(r.start_s + math.max(r.est, 0.05))
      rect(dl, xa - 1, lane2_y + 1, eb + 1, lane2_y + lane_h - 1,
           0xCFD7DEFF, 2, 0, 1.5)
    end
  end

  -- v0.29: the play cursor, for a caller that is following REAPER's transport
  -- (the review screen's preview sync). Nothing sets it on the plan screen, so
  -- the line is drawn only when there is a position to draw it at.
  if type(P.play_s) == 'number' and P.play_s >= 0 and P.play_s <= total then
    local px_ = tx(P.play_s)
    rectf(dl, px_, ruler_y, px_ + 1, y0 + H - 3, 0xE9EEF3FF, 0)
    rectf(dl, px_ - 3, ruler_y, px_ + 4, ruler_y + 3, 0xE9EEF3FF, 0)
  end

  -- Hover / click: which chunk is under the pointer? Decided by the SOURCE
  -- slot (speech + its pause), because those tile the axis without gaps or
  -- overlaps. An overflowing dub bar reaches into its neighbour's slot, so
  -- letting the longer of the two decide would hand every click near the end
  -- of a long chunk to the wrong row.
  if hovered then
    local mx = reaper.ImGui_GetMousePos(ctx)
    local at = ((mx - left) / usable) * total
    local hit = nil
    for _, r in ipairs(P.rows) do
      if at >= r.start_s and at < r.start_s + r.dur + r.pause then
        hit = r
        break
      end
    end
    if not hit then
      -- Past the last chunk, or in a gap the rows do not cover: fall back to
      -- whatever bar is actually drawn under the pointer.
      for _, r in ipairs(P.rows) do
        if at >= r.start_s and at <= r.start_s + math.max(r.dur, r.est, 0.02)
        then hit = r break end
      end
    end
    if hit then
      if reaper.ImGui_SetTooltip then
        reaper.ImGui_SetTooltip(ctx, string.format(
          '#%d   %d:%05.2f\nslot %.2fs  +%.2fs pause\nest %.2fs  ·  %s%s',
          hit.index, math.floor(hit.start_s / 60), hit.start_s % 60,
          hit.dur, hit.pause, hit.est,
          V5.PLAN_LABELS[hit.verdict] or hit.verdict,
          hit.atempo > 1.0 and string.format('  ·  %.2fx', hit.atempo) or ''))
      end
      if clicked then
        P.sel       = hit.index
        P.scroll_to = hit.index
      end
    end
  end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x6F7A83FF)
  -- Wrapped: 88 characters of legend under a strip as narrow as the window, and
  -- a plain Text ran straight off the right edge.
  reaper.ImGui_TextWrapped(ctx, P.legend or
    'source (grey) above · estimated dub (by fit) below · click a bar to ' ..
    'find its chunk')
  reaper.ImGui_PopStyleColor(ctx)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- v0.27 "Studio" — the approval gate
-- ═══════════════════════════════════════════════════════════════════════════
-- This is the screen that decides whether credits get spent, and it used to be
-- a stack: a tally, the strip, five buttons, a paragraph, then a seven-column
-- table of every chunk in index order. Everything was present and nothing was
-- ranked, so finding the two chunks that overflow out of thirty-one meant
-- reading the Fit column down the page — and the text of the chunk you found
-- was not on the screen at all, only in the HTML file.
--
-- Studio ranks by default (worst fit first), keeps the strip as the one thing
-- you look at, and gives the selected chunk an inspector with its own numbers
-- and its own text. The approval sits in a transport bar at the bottom, in the
-- same place on every phase.

-- Verdicts, worst first. This is the default sort, because the reason to be on
-- this screen is the chunks that do not fit.
V5.PLAN_SEV = { over = 1, tight = 2, short = 3, empty = 4, fits = 5 }

-- Separator + one 30 px button row + the gutters around it.
V5.PLAN_BOT_H = 46

-- Narrower than this and the inspector is dropped: three tabs plus a key column
-- and a value need this much before they are a column rather than a squeeze.
V5.PLAN_INSP_MIN = 210

V5.PLAN_SORTS = {
  { 'fit',   'fit'   },
  { 'index', '#'     },
  { 'start', 'at'    },
  { 'speed', 'rate'  },
}

-- A sorted VIEW of P.rows. Never sorts P.rows itself: its order is the timeline
-- order, which the strip draws and the plan file is written in.
function V5.plan_view(P)
  local key = P.sort or 'fit'
  if P.view and P.view_key == key and #P.view == #P.rows then return P.view end
  local v = {}
  for i, r in ipairs(P.rows) do v[i] = r end
  local function sev(r) return V5.PLAN_SEV[r.verdict] or 9 end
  table.sort(v, function(a, b)
    if key == 'index' then return a.index < b.index end
    if key == 'start' then return a.start_s < b.start_s end
    if key == 'speed' then
      if a.atempo ~= b.atempo then return a.atempo > b.atempo end
      return a.index < b.index
    end
    -- 'fit': worst verdict first, then the one being stretched hardest
    if sev(a) ~= sev(b) then return sev(a) < sev(b) end
    if a.atempo ~= b.atempo then return a.atempo > b.atempo end
    return a.index < b.index
  end)
  P.view, P.view_key = v, key
  return v
end

function V5.plan_row(P, index)
  for _, r in ipairs(P.rows) do if r.index == index then return r end end
  return nil
end

-- The tally, as chips rather than coloured words in a sentence. A count you are
-- meant to act on should not have to be picked out of prose.
function V5.plan_tally(ctx, P)
  V5.wrap_begin(ctx, 6)
  local any = false
  for _, k in ipairs({ 'over', 'tight', 'short', 'empty', 'fits' }) do
    local n = P.counts[k] or 0
    if n > 0 then
      any = true
      local label = string.format('%d %s', n, V5.PLAN_LABELS[k] or k)
      V5.wrap_next(ctx, V5.pill_w(ctx, label))
      local fg = V5.PLAN_COLOURS[k] or V5.COL.text
      local bg = (k == 'over') and 0x33191AFF
              or (k == 'tight') and V5.COL.chip_warn
              or (k == 'fits') and V5.COL.chip_ok
              or V5.COL.chip_info
      V5.pill(ctx, label, fg, bg)
    end
  end
  V5.wrap_end()
  if not any then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
    reaper.ImGui_Text(ctx, '(no chunks)')
    reaper.ImGui_PopStyleColor(ctx)
  end
end

V5.PLAN_INS_TABS = { 'Chunk', 'Run', 'Voice' }

-- The inspector: everything about ONE chunk, in the width the strip does not
-- need. Its whole reason for existing is that the text of an overflowing chunk
-- was previously only readable in the HTML file.
function V5.plan_inspector(ctx, P)
  V5.plan_tab = V5.plan_tab or 'Chunk'
  local row = P.sel and V5.plan_row(P, P.sel) or nil

  -- Tab strip. Sized from the width there is, not from a fixed per-tab number.
  local tw = V5.room(ctx, 300)
  local per = math.max(40, math.floor((tw - 6) / #V5.PLAN_INS_TABS))
  for i, name in ipairs(V5.PLAN_INS_TABS) do
    if i > 1 then reaper.ImGui_SameLine(ctx, 0, 2) end
    local on = (V5.plan_tab == name)
    local label = (name == 'Chunk' and row)
                  and string.format('Chunk %d', row.index) or name
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
                                on and V5.COL.accent or V5.COL.seg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),
                                on and V5.COL.accent_hi or V5.COL.seg_hi)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),
                                V5.COL.accent_act)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                                on and V5.COL.bright or V5.COL.text2)
    if reaper.ImGui_Button(ctx, V5.ellipsize(ctx, label, per - 10)
                                .. '##ptab' .. name, per, 24) then
      V5.plan_tab = name
    end
    reaper.ImGui_PopStyleColor(ctx, 4)
  end
  reaper.ImGui_Dummy(ctx, 0, 4)

  if V5.plan_tab == 'Run' then
    V5.cap(ctx, 'THIS PREVIEW')
    V5.kv(ctx, 'Chunks',   tostring(#P.rows))
    V5.kv(ctx, 'Source',   V5.fmt_dur(P.total_s or 0))
    V5.kv(ctx, 'Mode',     tostring(V5.sync_mode) .. '  ·  ' .. tostring(V5.chunk_mode))
    V5.kv(ctx, 'Language', tostring((P.manifest.language ~= '' and P.manifest.language)
                                    or LANGUAGE or '?'))
    reaper.ImGui_Dummy(ctx, 0, 6)
    V5.cap(ctx, 'FILES')
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
    reaper.ImGui_TextWrapped(ctx, basename(P.plan_path or '(no plan file)'))
    reaper.ImGui_PopStyleColor(ctx)
    return
  end

  if V5.plan_tab == 'Voice' then
    V5.cap(ctx, 'WHAT WILL SPEAK IT')
    local vn = V5.voice_name(VOICE_ID or '')
    V5.kv(ctx, 'Voice', vn ~= '' and vn or ((VOICE_ID or '') ~= '' and 'voice set' or 'no voice yet'))
    V5.kv(ctx, 'Model', (EL_MODEL or '') ~= '' and EL_MODEL or 'eleven_v3')
    V5.kv(ctx, 'Speed', 'up to the stretch ceiling on an overflow')
    reaper.ImGui_Dummy(ctx, 0, 6)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
    reaper.ImGui_TextWrapped(ctx,
      'Change the voice or the model in Settings — this screen reads them, it ' ..
      'does not set them.')
    reaper.ImGui_PopStyleColor(ctx)
    return
  end

  -- ── the Chunk tab ────────────────────────────────────────
  if not row then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
    reaper.ImGui_TextWrapped(ctx,
      'Click a bar in the strip, or a row in the table, to see its text and ' ..
      'its numbers here.')
    reaper.ImGui_PopStyleColor(ctx)
    return
  end

  V5.cap(ctx, 'VERDICT')
  local over_by = row.est - (row.dur + row.pause)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                              V5.PLAN_COLOURS[row.verdict] or V5.COL.text)
  local pushed = _push_font(ctx, 17)
  reaper.ImGui_Text(ctx, V5.PLAN_LABELS[row.verdict] or row.verdict)
  if pushed then _pop_font(ctx) end
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
  if row.verdict == 'over' then
    reaper.ImGui_TextWrapped(ctx, string.format(
      'The %s line runs %.2f s past its slot and the pause after it. Shorten ' ..
      'it in the review page, or approve and let the placer speed it to %.2fx.',
      tostring(LANGUAGE or 'target'), math.max(0, over_by), row.atempo))
  elseif row.verdict == 'tight' then
    reaper.ImGui_TextWrapped(ctx,
      'It fits only by eating the pause after it, so the rhythm tightens here.')
  elseif row.verdict == 'short' then
    reaper.ImGui_TextWrapped(ctx,
      'Shorter than its slot — the gap after it stays silent.')
  elseif row.verdict == 'empty' then
    reaper.ImGui_TextWrapped(ctx, 'No target text for this slot.')
  else
    reaper.ImGui_TextWrapped(ctx, 'Fits its own slot; it starts on time.')
  end
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_Dummy(ctx, 0, 6)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 4)

  V5.kv(ctx, 'At',    string.format('%d:%05.2f', math.floor(row.start_s / 60),
                                    row.start_s % 60))
  V5.kv(ctx, 'Slot',  string.format('%.2f s', row.dur))
  V5.kv(ctx, 'Pause', string.format('%.2f s', row.pause))
  V5.kv(ctx, 'Est',   string.format('%.2f s', row.est))
  V5.kv(ctx, 'Rate',  row.atempo > 1.0 and string.format('%.2f x', row.atempo) or '1.00 x',
        row.atempo > 1.0 and V5.PLAN_COLOURS.over or nil)
  V5.kv(ctx, 'Length', string.format('%d chars', V5.cells(row.tr or '')))

  reaper.ImGui_Dummy(ctx, 0, 6)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 4)

  -- The target text. ImGui cannot shape Indic conjuncts, so this is a
  -- reference view and the review page stays the place to EDIT it — which is
  -- exactly what the note under it says, rather than offering an editor that
  -- would render the text wrong.
  V5.cap(ctx, tostring(LANGUAGE or 'TARGET'):upper())
  local sf = _ensure_lang_font(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.text)
  reaper.ImGui_TextWrapped(ctx, (row.tr ~= '' and row.tr) or '(no text)')
  reaper.ImGui_PopStyleColor(ctx)
  if sf then V5.pop_ui_font(ctx, sf) end

  reaper.ImGui_Dummy(ctx, 0, 6)
  V5.cap(ctx, 'ENGLISH')
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.text2)
  reaper.ImGui_TextWrapped(ctx, (row.en ~= '' and row.en) or '(no transcript line)')
  reaper.ImGui_PopStyleColor(ctx)
end

-- A key/value line for the inspector: a fixed key column and a value that
-- truncates, so a long model id cannot push the column apart.
V5.KV_W = 62
function V5.kv(ctx, key, value, colour)
  local room = V5.room(ctx, 260)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
  reaper.ImGui_Text(ctx, key)
  reaper.ImGui_PopStyleColor(ctx)
  -- Relative first so the column can only ever move the value right.
  reaper.ImGui_SameLine(ctx)
  local at = reaper.ImGui_GetCursorPosX and reaper.ImGui_GetCursorPosX(ctx) or 0
  local x0 = at - V5.text_w(ctx, key, 8) - 8
  if x0 + V5.KV_W > at then reaper.ImGui_SameLine(ctx, x0 + V5.KV_W) end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), colour or V5.COL.text)
  reaper.ImGui_Text(ctx, V5.ellipsize(ctx, tostring(value),
                                      math.max(24, room - V5.KV_W - 4)))
  reaper.ImGui_PopStyleColor(ctx)
end

-- The chunk table. Seven columns, sorted by the header you press, and the row
-- selection is shared with the strip in both directions.
V5.PLAN_COL_W = { 34, 58, 52, 48, 52, 74, 46 }

function V5.plan_table(ctx, P)
  local view = V5.plan_view(P)

  if not P.use_table then
    -- Old ReaImGui without tables: one line per chunk, still in sorted order.
    if reaper.ImGui_BeginChild(ctx, '##planrows', -1, -1, _child_border_flag()) then
      for _, r in ipairs(view) do
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
          V5.PLAN_COLOURS[r.verdict] or 0xCCCCCCFF)
        local line = string.format(
          '%3d   %6.2fs  slot %5.2fs  +%4.2fs pause   est %5.2fs   %s',
          r.index, r.start_s, r.dur, r.pause, r.est,
          V5.PLAN_LABELS[r.verdict] or r.verdict)
        local lroom = reaper.ImGui_GetContentRegionAvail(ctx)
        reaper.ImGui_Text(ctx, V5.ellipsize(ctx, line,
                          type(lroom) == 'number' and lroom or 400))
        reaper.ImGui_PopStyleColor(ctx)
        if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsItemClicked
           and reaper.ImGui_IsItemClicked(ctx) then
          P.sel = r.index
        end
      end
      reaper.ImGui_EndChild(ctx)
    end
    return
  end

  local tflags = 0
  if reaper.ImGui_TableFlags_RowBg   then tflags = tflags | reaper.ImGui_TableFlags_RowBg()   end
  if reaper.ImGui_TableFlags_ScrollY then tflags = tflags | reaper.ImGui_TableFlags_ScrollY() end
  if reaper.ImGui_TableFlags_BordersInnerV then
    tflags = tflags | reaper.ImGui_TableFlags_BordersInnerV()
  end
  -- -6, not -1: a table flush against the canvas's bottom edge is a pixel away
  -- from asking the canvas for a scrollbar, and the canvas has promised not to
  -- have one.
  if not reaper.ImGui_BeginTable(ctx, '##plan', 7, tflags, -1, -6) then return end

  local fixed = reaper.ImGui_TableColumnFlags_WidthFixed
                and reaper.ImGui_TableColumnFlags_WidthFixed() or 0
  local stretch = reaper.ImGui_TableColumnFlags_WidthStretch
                  and reaper.ImGui_TableColumnFlags_WidthStretch() or 0
  reaper.ImGui_TableSetupColumn(ctx, '#',     fixed,   V5.PLAN_COL_W[1])
  reaper.ImGui_TableSetupColumn(ctx, 'at',    fixed,   V5.PLAN_COL_W[2])
  reaper.ImGui_TableSetupColumn(ctx, 'text',  stretch, 1.0)
  reaper.ImGui_TableSetupColumn(ctx, 'slot',  fixed,   V5.PLAN_COL_W[4])
  reaper.ImGui_TableSetupColumn(ctx, 'est',   fixed,   V5.PLAN_COL_W[5])
  reaper.ImGui_TableSetupColumn(ctx, 'rate',  fixed,   V5.PLAN_COL_W[7])
  reaper.ImGui_TableSetupColumn(ctx, 'fit',   fixed,   V5.PLAN_COL_W[6])
  if reaper.ImGui_TableSetupScrollFreeze then
    reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
  end
  reaper.ImGui_TableHeadersRow(ctx)

  local sf = _ensure_lang_font(ctx)
  for _, r in ipairs(view) do
    reaper.ImGui_TableNextRow(ctx)
    local on = (P.sel == r.index)

    reaper.ImGui_TableSetColumnIndex(ctx, 0)
    if reaper.ImGui_Selectable then
      -- The whole row selects: the '#' cell owns the Selectable and spans.
      local span = reaper.ImGui_SelectableFlags_SpanAllColumns
                   and reaper.ImGui_SelectableFlags_SpanAllColumns() or 0
      if reaper.ImGui_Selectable(ctx, tostring(r.index) .. '##pr' .. r.index,
                                 on, span) then
        P.sel = r.index
      end
    else
      reaper.ImGui_Text(ctx, tostring(r.index))
    end
    if P.scroll_to == r.index then
      if reaper.ImGui_SetScrollHereY then reaper.ImGui_SetScrollHereY(ctx, 0.5) end
      P.scroll_to = nil
    end

    reaper.ImGui_TableSetColumnIndex(ctx, 1)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.text2)
    reaper.ImGui_Text(ctx, string.format('%d:%05.2f',
      math.floor(r.start_s / 60), r.start_s % 60))
    reaper.ImGui_PopStyleColor(ctx)

    -- The text, which the old table did not show at all. One line, ellipsized
    -- to its own column: a wrapped cell would make every row a different
    -- height and this list is meant to be scanned.
    reaper.ImGui_TableSetColumnIndex(ctx, 2)
    local room = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.text2)
    reaper.ImGui_Text(ctx, V5.ellipsize(ctx, (r.tr ~= '' and r.tr) or r.en or '',
                                        type(room) == 'number' and room or 120))
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_TableSetColumnIndex(ctx, 3)
    reaper.ImGui_Text(ctx, string.format('%.2fs', r.dur))
    reaper.ImGui_TableSetColumnIndex(ctx, 4)
    reaper.ImGui_Text(ctx, string.format('%.2fs', r.est))

    reaper.ImGui_TableSetColumnIndex(ctx, 5)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
      r.atempo > 1.0 and V5.PLAN_COLOURS.over or V5.COL.dimmer)
    reaper.ImGui_Text(ctx, r.atempo > 1.0
                           and string.format('%.2fx', r.atempo) or '—')
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_TableSetColumnIndex(ctx, 6)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
      V5.PLAN_COLOURS[r.verdict] or 0xCCCCCCFF)
    reaper.ImGui_Text(ctx, V5.PLAN_LABELS[r.verdict] or r.verdict)
    reaper.ImGui_PopStyleColor(ctx)
  end
  if sf then V5.pop_ui_font(ctx, sf) end
  reaper.ImGui_EndTable(ctx)
end

-- The sort control. A row of segments rather than clickable table headers: the
-- headers are 34 px wide and a click target that small, on the one screen that
-- decides whether money is spent, is not a control.
function V5.plan_sort_row(ctx, P)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
  reaper.ImGui_Text(ctx, 'worst first by')
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_SameLine(ctx, 0, 6)
  local opts = {}
  for i, o in ipairs(V5.PLAN_SORTS) do opts[i] = { o[1], o[2] } end
  local newsort = V5.segmented(ctx, 'plansort', P.sort or 'fit', opts)
  if newsort ~= P.sort then
    P.sort, P.view = newsort, nil
  end
end

function V5.ui_phase_plan(ctx)
  local P = V5.plan
  if not P then _ui_phase = 'setup' return end
  local m = P.manifest
  -- Something is always selected, so the inspector is never an empty column.
  if not P.sel and P.rows[1] then P.sel = V5.plan_view(P)[1].index end

  -- Actions that change the PHASE are recorded and run after every Begin/End
  -- pair has been closed. Returning from the middle of a frame with a child
  -- still open is how you lose the frame — and three of these buttons do
  -- exactly that (a paste starts a reload run, Approve launches the engine).
  local act

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),  6.0, 6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 3.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),  8.0, 4.0)

  local body = V5.begin_body(ctx, 0, true)
  if not body then
    reaper.ImGui_PopStyleVar(ctx, 3)
    return
  end

  -- ── the head ─────────────────────────────────────────────
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn)
  reaper.ImGui_TextWrapped(ctx,
    'Fit preview — nothing was generated and no credits were spent.')
  reaper.ImGui_PopStyleColor(ctx)
  _ui_render_banner(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)

  local col_w = 0
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  if type(avail) ~= 'number' or avail <= 0 then avail = 1024 end
  -- The inspector gives width back rather than squeezing the canvas, the same
  -- guard the Dub screen's run column has — and below a floor it goes entirely
  -- rather than becoming a column too narrow for its own tab strip. Nothing is
  -- lost: the strip and the table are still here, and the tally says what needs
  -- attention. A 124 px inspector said nothing and cost the table 124 px.
  col_w = math.min(V5.CTX_W + 18, math.max(0, avail - 420))
  if col_w < V5.PLAN_INSP_MIN then col_w = 0 end

  -- A FIXED height, deliberately not V5.mh. The transport is one row by
  -- construction (the note beside the buttons is ellipsized, not wrapped), and
  -- a measured reserve here is a feedback loop: a tall canvas leaves a short
  -- reserve, which next frame makes a short canvas and a tall reserve, and the
  -- two never settle. Measuring works for a block whose height does not depend
  -- on the space left for it; this one's did.
  local bot_h = V5.PLAN_BOT_H

  -- ── canvas ───────────────────────────────────────────────
  if reaper.ImGui_BeginChild(ctx, '##plancanvas',
                             col_w > 0 and -(col_w + 8) or -1, -bot_h, 0,
                             V5.noscroll_flags()) then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
    reaper.ImGui_TextWrapped(ctx, string.format(
      '%s  ·  %d chunk(s) cut at the pauses in the source',
      (m.language ~= '' and m.language or LANGUAGE), #P.rows))
    reaper.ImGui_PopStyleColor(ctx)

    V5.plan_tally(ctx, P)
    reaper.ImGui_Dummy(ctx, 0, 2)

    V5.plan_strip(ctx, P)
    reaper.ImGui_Dummy(ctx, 0, 2)

    -- The free, repeatable loop: read and correct the text where it renders
    -- properly, paste it back, re-measure. Only Approve costs anything.
    V5.wrap_begin(ctx, 6)
    V5.wrap_next(ctx, V5.chip_w(ctx, '🌐 Open review page'))
    if V5.chip(ctx, '🌐 Open review page',
               'The one place the target text renders correctly — REAPER ' ..
               'cannot shape Indic conjuncts. Edit any line there, watch its ' ..
               'bar move, then copy the corrected plan back.') then
      if P.html_path ~= '' and file_exists(P.html_path) then
        open_path(P.html_path)
      else
        ui_set_banner('warn',
          'The review page was not written — 📝 Edit plan file still lets ' ..
          'you correct the TR: lines by hand.')
      end
    end
    V5.wrap_next(ctx, V5.chip_w(ctx, '📥 Paste corrections'))
    if V5.chip(ctx, '📥 Paste corrections',
               'Replace the plan with the corrected copy from the review ' ..
               'page, then measure it again. Free, and repeatable.') then
      act = 'paste'
    end
    V5.wrap_next(ctx, V5.chip_w(ctx, '⟲ Re-measure'))
    if V5.chip(ctx, '⟲ Re-measure', 'Re-read the plan file from disk.') then
      act = 'reload'
    end
    V5.wrap_next(ctx, V5.chip_w(ctx, '📝 Edit plan file'))
    if V5.chip(ctx, '📝 Edit plan file', 'Open the plan in a text editor.') then
      open_path(P.plan_path)
    end
    V5.wrap_next(ctx, V5.chip_w(ctx, '📁 Folder'))
    if V5.chip(ctx, '📁 Folder', "Open this preview's output folder.") then
      if (m.out_dir or '') ~= '' then open_path(m.out_dir) end
    end
    V5.wrap_end()

    reaper.ImGui_Dummy(ctx, 0, 2)
    V5.plan_sort_row(ctx, P)
    reaper.ImGui_Dummy(ctx, 0, 2)

    V5.plan_table(ctx, P)
    reaper.ImGui_EndChild(ctx)
  end

  -- ── inspector ────────────────────────────────────────────
  if col_w > 0 then
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_BeginChild(ctx, '##planinsp', -1, -bot_h,
                               _child_border_flag()) then
      V5.plan_inspector(ctx, P)
      reaper.ImGui_EndChild(ctx)
    end
  end

  -- ── the transport bar ────────────────────────────────────
  -- Pinned, and in the same place as the Dub screen's action row, so the button
  -- that spends money is always where your hand already is.
  reaper.ImGui_Separator(ctx)
  local over_n = P.counts.over or 0

  V5.wrap_begin(ctx, 8)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        V5.COL.go)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), V5.COL.go_hi)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  V5.COL.go_act)
  if reaper.ImGui_Button(ctx, '▶  Approve & dub', 210, 30) then
    act = 'approve'
  end
  reaper.ImGui_PopStyleColor(ctx, 3)

  reaper.ImGui_SameLine(ctx, 0, 8)
  if reaper.ImGui_Button(ctx, 'Back to setup', 130, 30) then
    act = 'back'
  end
  reaper.ImGui_SameLine(ctx, 0, 12)

  -- What approving now actually means, beside the button that does it.
  local note = (over_n > 0)
    and string.format('%d chunk(s) still overflow — approving speeds them to ' ..
                      'the stretch ceiling; anything past it stays long and is ' ..
                      'flagged in the log. Shortening them costs nothing.', over_n)
    or 'Every chunk fits — each starts at its own source timestamp.'
  -- One line, ellipsized: the bar's height is fixed, so this cannot wrap. The
  -- whole sentence is on the button's own tooltip.
  local nroom = V5.room(ctx, 200)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                              over_n > 0 and V5.PLAN_COLOURS.over or V5.COL.hint)
  reaper.ImGui_Text(ctx, V5.ellipsize(ctx, note, math.max(24, nroom - 8)))
  reaper.ImGui_PopStyleColor(ctx)
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(note))
  end
  V5.wrap_end()

  reaper.ImGui_EndChild(ctx)   -- ##tabbody
  reaper.ImGui_PopStyleVar(ctx, 3)

  -- Every child is closed: it is safe to change the phase now.
  if     act == 'approve' then V5.start_dubplan_run()
  elseif act == 'back'    then V5.plan = nil; _ui_phase = 'setup'
  elseif act == 'paste'   then V5.plan_paste_corrections(ctx)
  elseif act == 'reload'  then V5.plan_reload()
  end
end


-- ─── ⚙ Settings section (setup phase, v0.3) ──────────────
-- LLM provider/model/keys + ElevenLabs TTS key/model/voice. Persisted to
-- config/llm_settings.json + config/tts_settings.json (gitignored); the
-- engine reads keys from those files only.
--
-- v0.17: masking is per field. The old single "Show keys" checkbox (and the
-- V5.pw_flags helper that read it) revealed every key on the screen at once to
-- check one of them — so each key row carries its own eye instead. See
-- V5.key_field / V5.eye_button.

-- ── Connections pane (v0.17) ────────────────────────────────
-- Every API this panel talks to, one row each, each row saying whether its key
-- works and which models that key serves. It used to show only the provider
-- named in the dropdown, so a Gemini key entered last week was invisible while
-- you were on the gateway — and nothing said whether any of it was valid until
-- a run failed. These keys are still the only copy: the Sync tab reads the
-- same ones and has no fields of its own.

-- The row's own verdict: text, colour.
function V5.conn_status(pv, st)
  if pv == 'vertex' then
    local p = LLM_VERTEX_JSON or ''
    if p == '' then return 'using config/vertex_key.json if present', V5.COL.dim end
    if file_exists(p) then return 'service-account JSON found', V5.COL.ok end
    return 'that JSON file does not exist', V5.COL.err
  end
  if not st or st.state == 'unset' then
    local cred = V5.conn_cred(pv) or ''
    if cred == '' then return 'not configured', V5.COL.dimmer end
    return (st and st.msg) or 'not checked yet', V5.COL.dim
  end
  if st.state == 'checking' then
    return _spinner_glyph() .. ' checking the key…', V5.COL.dim
  elseif st.state == 'ok' then
    return 'valid · ' .. (st.msg or 'ok'), V5.COL.ok
  elseif st.state == 'bad' then
    return st.msg or 'not usable', V5.COL.err
  end
  return 'waiting…', V5.COL.dim
end

-- Row header: name, whether anything uses it, the verdict, and a re-check.
function V5.conn_head(ctx, pv, title)
  local st     = V5.conn[pv]
  local in_use = (pv == 'elevenlabs') or (pv == LLM_PROVIDER)

  reaper.ImGui_Dummy(ctx, 0, 2)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xEEEEEEFF)
  reaper.ImGui_Text(ctx, title)
  reaper.ImGui_PopStyleColor(ctx)

  if in_use then
    reaper.ImGui_SameLine(ctx, 0, 8)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x77AAEEFF)
    reaper.ImGui_Text(ctx, pv == 'elevenlabs' and '· voices' or '· AI in use')
    reaper.ImGui_PopStyleColor(ctx)
  end

  -- Re-check is per row: the probe is one HTTP GET, not an engine launch, so
  -- it costs nothing and works during a dub run.
  if pv ~= 'vertex' and (V5.conn_cred(pv) or '') ~= '' then
    reaper.ImGui_SameLine(ctx, 0, 8)
    if reaper.ImGui_SmallButton(ctx, '⟳##recheck' .. pv) then
      V5.conn_state(pv).due = V5.now()
    end
    if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
      reaper.ImGui_SetTooltip(ctx, V5.wrap(
        'Ask this API again whether the key works and what it serves.'))
    end
  end

  local text, colour = V5.conn_status(pv, st)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), colour)
  reaper.ImGui_TextWrapped(ctx, text)
  reaper.ImGui_PopStyleColor(ctx)
  return st, in_use
end

-- The model line every row carries. The provider in use gets the real picker
-- (it edits the setting); the others get what their key serves, as text —
-- there is only ONE Model setting, so an editable box on an idle row would
-- pretend otherwise.
function V5.conn_model_row(ctx, pv, st, in_use)
  if in_use and pv ~= 'elevenlabs' then
    V5.field(ctx, 'Model', 260)
    LLM_MODEL = V5.model_picker(ctx, '##llmmodel', LLM_MODEL, LLM_PROVIDER,
                                nil, 260)
    if pv == 'openai' then
      V5.hint(ctx, 'Model id your gateway serves. A validated key fills this ' ..
                   'list from the gateway itself; "Custom" types an id ' ..
                   'directly, e.g. openai/gpt-5.')
    elseif pv == 'server' then
      V5.hint(ctx, 'Model Sync asks your server for — the server may ' ..
                   'override it. Pick "Custom" to type an id that is not in ' ..
                   'the list.')
    else
      V5.hint(ctx, 'Gemini model. A validated key fills this list from ' ..
                   'Google; "Custom" types a newer id by hand.')
    end
  elseif pv == 'elevenlabs' then
    -- What the account actually serves, once validated — not V5.models_for
    -- (that answers for the LLM providers, and this combo must never offer a
    -- gpt id to ElevenLabs). A validated account's list REPLACES the contract
    -- defaults below, same as V5.models_for: those defaults are only the
    -- pre-validation guess, not "also available on top of what you have".
    local items, seen, known = {}, {}, false
    local function add(mdl)
      if mdl ~= '' and not seen[mdl] then
        items[#items + 1] = mdl
        seen[mdl] = true
      end
      if mdl == EL_MODEL then known = true end
    end
    local el_fetched = V5.models_fetched.elevenlabs or {}
    if #el_fetched > 0 then
      for _, mdl in ipairs(el_fetched) do add(mdl) end
    else
      for _, mdl in ipairs(EL_MODELS) do add(mdl) end
    end
    if not known and (EL_MODEL or '') ~= '' then
      table.insert(items, 1, EL_MODEL)
    end
    V5.field(ctx, 'Model', 260)
    _, EL_MODEL = _ui_combo(ctx, '##elmodel', EL_MODEL, items)
    V5.hint(ctx, 'The ElevenLabs synthesis model. A validated key fills this ' ..
                 'list from your account.')
  end

  -- What the key actually reports, and an explicit way to adopt it. Never
  -- automatic: opening Settings must not change a setting.
  if st and st.state == 'ok' and st.model then
    local cur = (pv == 'elevenlabs') and EL_MODEL or LLM_MODEL
    local n   = #(st.models or {})
    if in_use and cur ~= st.model then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn)
      reaper.ImGui_TextWrapped(ctx, 'This key does not serve "' ..
        tostring(cur ~= '' and cur or '(not set)') .. '". It serves ' ..
        st.model .. (n > 1 and (' and ' .. (n - 1) .. ' more') or '') .. '.')
      reaper.ImGui_PopStyleColor(ctx)
      if reaper.ImGui_SmallButton(ctx, 'Use ' .. st.model .. '##adopt' .. pv) then
        V5.conn_apply_model(pv, st.model)
      end
    else
      V5.label(ctx, in_use and 'Detected' or 'Serves')
      _grey_hint(ctx, st.model ..
                 (n > 1 and ('   (+' .. (n - 1) .. ' more)') or ''))
    end
  end
end

function V5.pane_connection(ctx)
  -- Validate whatever is already saved, once per session, so a row can say
  -- "valid" without the user pressing anything.
  V5.conn_autostart()

  V5.heading(ctx, 'Connections',
    'Every API this panel talks to, and the model each one serves')
  local rv
  -- One group for the whole pane, headings and warnings included: every row
  -- here belongs to the same visual column, so "API key" under Gemini has to
  -- line up with "Base URL" under the gateway.
  V5.form_begin(ctx, 'connections')

  V5.field(ctx, 'Used for AI', 200)
  local prov_changed
  prov_changed, LLM_PROVIDER = _ui_combo(ctx, '##provider', LLM_PROVIDER,
                                        PROVIDER_UI)
  V5.hint(ctx, 'Which of the rows below translates, reviews and maps. The ' ..
               'keys are the only copy — the Sync tab uses the same ones and ' ..
               'has no fields of its own.')

  -- ── OpenAI-compatible gateway ───────────────────────────
  local st, in_use = V5.conn_head(ctx, 'openai', 'OpenAI-compatible gateway')
  V5.field(ctx, 'Base URL', 260)
  local url_changed
  url_changed, LLM_OPENAI_URL = reaper.ImGui_InputText(ctx, '##oaiurl',
                                                       LLM_OPENAI_URL or '')
  V5.hint(ctx, 'API base of an OpenAI-compatible gateway (LiteLLM, ' ..
               'OpenRouter, vLLM, ...). Host or host/v1 — e.g. ' ..
               'https://llm.example.com/v1 — NOT the chat UI address and ' ..
               'without /chat/completions.')
  -- The URL is half the credential here: changing it invalidates the verdict
  -- as surely as changing the key does.
  if url_changed then V5.conn_touch('openai', LLM_OPENAI_KEY) end
  LLM_OPENAI_KEY = V5.key_field(ctx, 'API key', 'oaikey', LLM_OPENAI_KEY,
    'openai', 'Paste it and it is checked straight away — no button.', 'openai')
  if LLM_OPENAI_KEY == '' and V5.gateway_needs_key(LLM_OPENAI_URL) then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn)
    reaper.ImGui_TextWrapped(ctx,
      'API key is empty — this gateway is remote, so every request would ' ..
      'go out unauthenticated and come back 401.')
    reaper.ImGui_PopStyleColor(ctx)
  end
  V5.conn_model_row(ctx, 'openai', st, in_use)
  if not in_use then V5.conn_use_button(ctx, 'openai') end

  -- ── Gemini ──────────────────────────────────────────────
  st, in_use = V5.conn_head(ctx, 'gemini', 'Gemini')
  LLM_GEMINI_KEY = V5.key_field(ctx, 'API key', 'gemkey', LLM_GEMINI_KEY,
    'gemini', 'Google AI Studio key (starts with "AIza") — ' ..
    'aistudio.google.com/apikey. Checked as soon as you paste it.', 'gemini')
  V5.conn_model_row(ctx, 'gemini', st, in_use)
  if not in_use then V5.conn_use_button(ctx, 'gemini') end

  -- ── Vertex AI ───────────────────────────────────────────
  st, in_use = V5.conn_head(ctx, 'vertex', 'Vertex AI')
  V5.field(ctx, 'Key file', 260)
  rv, LLM_VERTEX_JSON = reaper.ImGui_InputText(ctx, '##vtxpath',
                                               LLM_VERTEX_JSON or '')
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_SmallButton(ctx, 'Browse…##vtx') then
    local ok, picked = reaper.GetUserFileNameForRead(
      LLM_VERTEX_JSON or "", "Select Vertex service-account JSON", "json")
    if ok and picked and picked ~= "" then LLM_VERTEX_JSON = picked end
  end
  V5.hint(ctx, 'Path to a Google service-account JSON. Leave blank to use ' ..
               'config/vertex_key.json when it exists. There is no key to ' ..
               'paste, so this row is not probed — Vertex serves the same ' ..
               'models as Gemini.')
  V5.conn_model_row(ctx, 'vertex', st, in_use)
  if not in_use then V5.conn_use_button(ctx, 'vertex') end

  -- ── Server proxy ────────────────────────────────────────
  st, in_use = V5.conn_head(ctx, 'server', 'Server proxy')
  V5.field(ctx, 'Server URL', 260)
  local srv_changed
  srv_changed, LLM_SERVER_URL = reaper.ImGui_InputText(ctx, '##srvurl',
                                                       LLM_SERVER_URL or '')
  if srv_changed then V5.conn_touch('server', LLM_SERVER_TOKEN) end
  LLM_SERVER_TOKEN = V5.key_field(ctx, 'Token', 'srvtok', LLM_SERVER_TOKEN,
    'server', 'Sync routes every AI call through your server, which holds ' ..
    'the real provider keys — only this token lives on this machine.', 'server')
  V5.conn_model_row(ctx, 'server', st, in_use)
  if in_use then
    -- Blocking: a dub run in this mode stops with exactly this message, so it
    -- stays inline rather than hiding behind a hover.
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn)
    reaper.ImGui_TextWrapped(ctx,
      'DUBBING CANNOT USE THIS MODE: the dub engine calls the LLM directly, ' ..
      'so dub runs will stop with that message. Pick Vertex, Gemini or ' ..
      'OpenAI-compatible above to dub.')
    reaper.ImGui_PopStyleColor(ctx)
  else
    V5.conn_use_button(ctx, 'server')
  end

  -- ── ElevenLabs ──────────────────────────────────────────
  -- Always "in use": every voice stage and the transcription need this key,
  -- whichever LLM provider is selected above.
  st, in_use = V5.conn_head(ctx, 'elevenlabs', 'ElevenLabs')
  EL_KEY = V5.key_field(ctx, 'API key', 'elkey', EL_KEY, 'el',
    'Transcription and every voice stage need this key. Voice picking and ' ..
    'preview moved to Tools → Voices.', 'elevenlabs')
  V5.conn_model_row(ctx, 'elevenlabs', st, in_use)

  -- ── The full end-to-end test ────────────────────────────
  reaper.ImGui_Dummy(ctx, 0, 6)
  reaper.ImGui_Separator(ctx)
  if LLM_PROVIDER ~= 'server' then
    if reaper.ImGui_Button(ctx, 'Test connection', 150, 26) then
      start_test_llm()
    end
    V5.hint(ctx, 'The rows above check the KEY (one HTTP call each). This ' ..
                 'runs one real LLM call through the engine with the model ' ..
                 'selected — the end-to-end proof. Result shows in a banner.')
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_SmallButton(ctx, 'Re-check every key') then
    for _, row in ipairs(V5.CONN) do
      if row[1] ~= 'vertex' and (V5.conn_cred(row[1]) or '') ~= '' then
        V5.conn_state(row[1]).due = V5.now()
      end
    end
  end

  V5.form_end(ctx)
  if prov_changed then save_settings() end
end

-- "Use this one for the AI work" — the row-local way to switch provider, so
-- the dropdown at the top is not the only path.
function V5.conn_use_button(ctx, pv)
  if reaper.ImGui_SmallButton(ctx, 'Use for AI##use' .. pv) then
    LLM_PROVIDER = pv
    save_settings()
  end
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(
      'Make this the provider that translates, reviews and maps.'))
  end
end

-- ── Voices (v0.17: a Tools tool, not a Settings pane) ───────
-- Was ⚙ Settings → Voices. Everything here is voice GENERATION work you do
-- while dubbing — fetch the catalogue, audition, pick the fallback voice — so
-- it belongs beside the other three voice tools rather than in a settings
-- screen you visit once. The ElevenLabs KEY moved the other way, into
-- Connections, where every credential now lives.
function V5.ui_voices_tool(ctx)
  local rv
  -- 'Google TTS key' is the widest label in the panel and the row that made
  -- the flat 84 px column untenable once a real UI face was loaded.
  V5.form_begin(ctx, 'voices')

  if (EL_KEY or '') == '' then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn)
    reaper.ImGui_TextWrapped(ctx,
      'No ElevenLabs key yet — voices cannot be fetched or auditioned. ' ..
      'Add it in ⚙ Settings → Connections.')
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Dummy(ctx, 0, 4)
  end

  -- Model combo: keep an unknown persisted model visible by prepending it, and
  -- lead with what the validated key actually serves.
  local model_items, seen, known = {}, {}, false
  local function add(mdl)
    if mdl ~= '' and not seen[mdl] then
      model_items[#model_items + 1] = mdl
      seen[mdl] = true
    end
    if mdl == EL_MODEL then known = true end
  end
  for _, mdl in ipairs(V5.models_fetched.elevenlabs or {}) do add(mdl) end
  for _, mdl in ipairs(EL_MODELS) do add(mdl) end
  if not known and (EL_MODEL or "") ~= "" then
    table.insert(model_items, 1, EL_MODEL)
  end
  V5.field(ctx, 'Voice model', 260)
  local el_changed
  el_changed, EL_MODEL = _ui_combo(ctx, '##elmodel_tool', EL_MODEL, model_items)
  V5.hint(ctx, 'The ElevenLabs synthesis model every voice stage uses.')

  reaper.ImGui_Dummy(ctx, 0, 4)
  -- v0.21: the fetch reports itself right here — it used to hand the whole
  -- panel over to the Dub run screen for the three seconds it takes, and
  -- landed you on the failure page when it did not start.
  local fetching = (V5.quiet_job == "list_voices")
  _ui_begin_disabled(ctx, V5.busy())
  if reaper.ImGui_Button(ctx,
      (fetching and ('Fetching…  ' .. _spinner_glyph()) or 'Fetch voices')
      .. '##fetchvoices', 150, 26) then
    start_fetch_voices()
  end
  _ui_end_disabled(ctx)
  if fetching then
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn)
    reaper.ImGui_Text(ctx, 'asking ElevenLabs for the ' .. (LANGUAGE or '?') ..
                           ' catalogue…')
    reaper.ImGui_PopStyleColor(ctx)
  end
  V5.hint(ctx, 'Pulls the ElevenLabs voice catalogue for ' ..
               (LANGUAGE or '?') .. ' into the pickers.')

  -- v0.7: bookmarks + search, shared with the other tools. The manual id field
  -- below still wins — it IS the value. The picker itself flags a list
  -- fetched for another language (v0.11) and can audition a voice (v0.11).
  VOICE_ID = V5.ui_voice_picker(ctx, 'settings', VOICE_ID, 'Default voice')

  if V5.advanced(ctx, 'voiceid_settings', 'Enter a voice id by hand') then
    reaper.ImGui_Indent(ctx, 12)
    V5.field(ctx, 'Voice id', 260)
    rv, VOICE_ID = reaper.ImGui_InputText(ctx, '##vidmanual', VOICE_ID or '')
    V5.hint(ctx, 'An ElevenLabs voice id, for a voice that is not in your ' ..
                 'fetched list. It overrides the picker above.')
    V5.field(ctx, 'Google TTS key', 260)
    rv, GOOGLE_TTS_KEY_PATH = reaper.ImGui_InputText(
      ctx, '##gttskey', GOOGLE_TTS_KEY_PATH or '')
    V5.hint(ctx, 'Optional. Path to a Google Cloud TTS service-account JSON, ' ..
                 'for the Google voice backend.')
    reaper.ImGui_Unindent(ctx, 12)
  end

  -- These are settings, and the Tools tab has no Save row of its own.
  reaper.ImGui_Dummy(ctx, 0, 6)
  if reaper.ImGui_Button(ctx, 'Save voice settings', 170, 26) then
    V5.do_save_settings()
  end
  V5.hint(ctx, 'Writes the voice model and default voice to config/ — the ' ..
               'same Save the Settings screen has.')
  if el_changed then save_settings() end

  -- Masked one-line summary of what is configured (fast-syncs _mask_key).
  _grey_hint(ctx, string.format('EL key %s  ·  default voice %s',
    EL_KEY ~= '' and _mask_key(EL_KEY) or '(not set)',
    (VOICE_ID or '') ~= '' and VOICE_ID or '(not set)'))
  V5.form_end(ctx)
end

-- v0.16: ui_settings_section is gone. It was the setup phase's inline
-- "⚙ Settings (LLM + TTS keys)" collapsing header, reachable only from the
-- no-tab-bar fallback the rail replaced — and it carried a THIRD copy of the
-- Save behaviour that had already drifted from the other two. Settings is a
-- rail destination now; V5.do_save_settings is the one Save.

-- ─── Shared source inputs (v0.5) ──────────────────────────
-- Audio picker + from-track + language + run-mode checkbox, used by BOTH
-- the Full Pipeline and the Paste Translation tabs (shared state — the
-- two tabs are two entrances to the same run).
function V5.ui_source_inputs(ctx)
  local rv

  -- Audio: type a path, pick a file, or lift it off a project track. One
  -- clean item → its source file; anything else is rendered to
  -- <project>/DubSource/ first (v0.4.1).
  -- v0.16: fill the row minus the button, instead of a fixed 250 that left the
  -- end of every path scrolled out of sight.
  -- v0.23 (Direction C): Source keeps a full row of its own — a path is the one
  -- value on this screen that is genuinely long. Everything under it pairs up
  -- two to a row, and those saved rows are what the script box fills.
  -- v0.27: stacked. The path is the longest value on the screen and it now gets
  -- the whole row's width instead of the row minus a label column.
  V5.fld(ctx, 'English source',
         'The audio the run reads. Type a path, pick a file, or take it off a ' ..
         'project track below.',
         V5.BROWSE_W + 8)
  rv, LAST_AUDIO = reaper.ImGui_InputText(ctx, '##audio', LAST_AUDIO or '')
  reaper.ImGui_SameLine(ctx, 0, 6)
  if V5.browse_button(ctx, 'audio', 'Pick the English source audio file.') then
    local ok, picked = reaper.GetUserFileNameForRead(
      LAST_AUDIO or "", "Select English source audio", "")
    if ok and picked and picked ~= "" then LAST_AUDIO = picked end
  end

  -- Row two: the target language and, when this project has tracks, where the
  -- English is coming from.
  reaper.ImGui_Dummy(ctx, 0, 4)
  V5.fgrid_begin(ctx, 'srcgrid', 2)

  V5.fcell(ctx)
  -- Voice id and EL model live in the settings window (v0.3 / v0.10).
  V5.fld(ctx, 'Target language', nil, 0,
         V5.voice_name(VOICE_ID or '') ~= '' and V5.voice_name(VOICE_ID or '') or nil)
  local lang_changed
  lang_changed, LANGUAGE = _ui_combo(ctx, '##lang', LANGUAGE, LANGUAGES)
  if lang_changed then save_settings() end

  local n_src_tracks = reaper.CountTracks(0)
  if n_src_tracks > 0 then
    if _src_track_idx >= n_src_tracks then _src_track_idx = -1 end
    local NO_TRACK = '(from track)'
    local items, cur = { NO_TRACK }, NO_TRACK
    for i = 0, n_src_tracks - 1 do
      local tr = reaper.GetTrack(0, i)
      local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME",
                                                       "", false)
      local label = string.format('%d: %s', i + 1,
                                  (nm ~= "" and nm or '(unnamed)'))
      items[#items + 1] = label
      if i == _src_track_idx then cur = label end
    end
    -- v0.16: its own row. Squeezed onto the Source row this needed ~560 px of
    -- width, which the two-column body does not have.
    -- v0.23: that row is now the right-hand cell, and 46 px of it is the Use
    -- button — a negative width here would fill to the WINDOW edge and draw
    -- straight through nothing, since this is already the last column.
    V5.fcell(ctx)
    V5.fld(ctx, 'Or take it off a track',
           'Press Use to take the English audio off the timeline. What it ' ..
           'takes is the SPAN the timeline is showing: a time selection if ' ..
           'you dragged one, else the item(s) you selected, else everything ' ..
           'on the chosen track — so a trimmed item dubs the trim, not the ' ..
           'whole file. The line below says which, before you press it. ' ..
           'Anything but a whole untrimmed item at 0:00 is rendered to a wav ' ..
           'in the project folder first, and the dub is imported back at the ' ..
           'span’s own place on the timeline.',
           46)
    local tr_changed, picked = _ui_combo(ctx, '##srctrack', cur, items)
    if tr_changed then
      _src_track_idx = -1
      for i, label in ipairs(items) do
        if label == picked and i > 1 then _src_track_idx = i - 2 break end
      end
    end
    -- v0.31: the region is resolved every frame, so the caption under the row
    -- is live — trim the item and the numbers move while you watch.
    local plan, no_plan = V5.timeline_region()
    reaper.ImGui_SameLine(ctx, 0, 6)
    _ui_begin_disabled(ctx, plan == nil)
    if reaper.ImGui_Button(ctx, 'Use', 40, 0) and plan then
      local path, why, rendered, pos = audio_for_region(plan)
      if path then
        LAST_AUDIO = path
        save_settings()
        ui_set_banner("info", string.format(
          '%s of audio — %s to %s, %s.%s\n%s',
          V5.fmt_dur(plan.b - plan.a), V5.fmt_pos(plan.a),
          V5.fmt_pos(plan.b), plan.why,
          (pos or 0) > 0
            and ('\nThe dub will be imported back at ' .. V5.fmt_pos(pos) ..
                 ', where it was taken from.')
            or  '',
          path))
      else
        ui_set_banner("error",
          "Could not take the audio off the timeline:\n" .. (why or "?"))
      end
    end
    _ui_end_disabled(ctx)

    -- One line, ellipsized: what Use would take right now, or why it cannot.
    -- Is the audio in the field ALREADY this region? Pressing Run without
    -- pressing Use is the whole failure this feature exists to end: the
    -- timeline shows a two-minute excerpt and the engine is handed the hour.
    -- So the line goes amber until the two agree.
    local whole, whole_file = false, nil
    local stale = false
    if plan then
      whole, whole_file = V5.region_is_whole_file(plan)
      local reg = V5.region_load(LAST_AUDIO or '')
      if reg then
        stale = not (math.abs((reg.a or -1) - plan.a) < 0.05
                     and math.abs((reg.b or -1) - plan.b) < 0.05)
      elseif whole then
        stale = ((LAST_AUDIO or ''):lower() ~= (whole_file or ''):lower())
      else
        stale = true
      end
    end

    -- m:ss here, not V5.fmt_pos: this line lives in a half-width cell and
    -- '0:02:00.000' twice is most of it. The banner and the import summary
    -- carry the transport-precise numbers.
    local note = plan
      and string.format('%s %s — %s → %s (%s)%s',
                        stale and 'press Use to dub' or 'dubbing',
                        V5.fmt_dur(plan.b - plan.a), V5.review_at(plan.a),
                        V5.review_at(plan.b), plan.why,
                        (stale and not whole) and ' — not the whole file' or '')
      or (no_plan or 'nothing to take yet')
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
      (plan and stale and not whole) and V5.COL.warn
      or (plan and V5.COL.hint or V5.COL.dimmer))
    reaper.ImGui_Text(ctx, V5.ellipsize(ctx, note,
                                        math.max(24, V5.room(ctx, 200) - 4)))
    reaper.ImGui_PopStyleColor(ctx)
    if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
      reaper.ImGui_SetTooltip(ctx, V5.wrap(note))
    end
  end
  V5.fgrid_end(ctx)

  -- Row three: the two choices that change the SHAPE of the run, side by side.
  -- Both are visible in the run column as you set them: Script = have greys the
  -- Translate step out, Review = staged is what the "Your check" row is.
  -- v0.23: 'Pause to check translation' and 'Run straight through' lost their
  -- last word to fit a half-row. The tooltips are unabridged and the status
  -- bar still spells the mode out; what the row loses in words it gets back in
  -- a script box that is 26 px taller and never scrolls the button away.
  reaper.ImGui_Dummy(ctx, 0, 4)
  V5.fgrid_begin(ctx, 'howgrid', 2)

  -- v0.10: what used to be the "Paste Translation" tab. Same run either way —
  -- only the source of the translated script differs — so it is a mode, not
  -- a second entrance.
  V5.fcell(ctx)
  V5.fld(ctx, 'Script', 'Where the translated script comes from.', 0)
  local mode = V5.segmented(ctx, 'scriptmode', SCRIPT_MODE, {
    { 'auto', 'Translate with AI',
      'The engine transcribes the audio and runs the LLM translation ' ..
      'chain to produce the script.' },
    { 'have', 'I have a script',
      'Paste your own translated script. The audio is still transcribed ' ..
      'once, because the sync stages need its timings, but the LLM ' ..
      'translation chain is skipped.' },
  })
  if mode ~= SCRIPT_MODE then
    SCRIPT_MODE = mode
    save_settings()
  end

  -- v0.2: staged runs are the default — the pipeline pauses after the
  -- translation chain for a side-by-side review.
  V5.fcell(ctx)
  V5.fld(ctx, 'Review', 'Whether the run stops for you before it spends ' ..
                        'anything on the voice stage.', 0)
  local full = V5.segmented(ctx, 'runmode', FULL_RUN and 'full' or 'staged', {
    { 'staged', 'Pause to check',
      'The run stops after the translation chain and shows the English ' ..
      'transcript beside the translation so you can fix it before paying ' ..
      'for the voice stage.' },
    { 'full', 'Straight through',
      'One shot, no pause. Nothing to approve — the dub is imported when ' ..
      'the run finishes.' },
  }) == 'full'
  if full ~= FULL_RUN then
    FULL_RUN = full
    save_settings()
  end
  V5.fgrid_end(ctx)

  -- ── Whatever is left of the column ──────────────────────────
  -- v0.25: the plan and readiness card that used to end this column live in the
  -- run column on the right now, where they are visible in BOTH script modes —
  -- pasting a script used to take the model, the voice and the sync mode off
  -- the screen entirely. What is left here is the script itself: the one you
  -- paste, or — when the engine writes it — where it will appear.
  reaper.ImGui_Dummy(ctx, 0, 2)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)

  if SCRIPT_MODE == 'have' then
    -- v0.27: the caption carries what this script will cost, right-aligned, so
    -- the number is beside the text it is counting rather than under the Run
    -- button on the far side of the screen.
    local est = ''
    if (_provided_text or ''):match('%S') then
      est = string.format('~%s speech  ·  ~%d credits',
                          V5.fmt_dur(V5.speech_secs(_provided_text)),
                          V5.credit_est(_provided_text))
    end
    V5.fld(ctx, 'Your ' .. tostring(LANGUAGE or 'target') .. ' script',
           'Paste the translated script. Separate paragraphs with one blank ' ..
           'line — they are what the matcher pairs against the transcript.',
           0, est)
    _provided_text = V5.script_box(ctx, 'provided', _provided_text or '',
                                   { fill = true, min = 120 })
  else
    -- AI-translation mode has no script to show yet, and an empty box would be
    -- a lie about where you type. What goes here instead is the answer to the
    -- two questions this mode raises: who writes it, and when do I see it.
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.text2)
    reaper.ImGui_Text(ctx, 'The script')
    reaper.ImGui_PopStyleColor(ctx)
    V5.hint(ctx, 'Nothing to paste in this mode — the engine writes the ' ..
                 'script. Switch Script to "I have a script" if you already ' ..
                 'have one.')
    -- Only when there is room for it. In a window dragged short the rows above
    -- already fill the form, and -1 would ask for a negative height.
    local _, room = reaper.ImGui_GetContentRegionAvail(ctx)
    if (type(room) ~= 'number' or room >= 60)
       and reaper.ImGui_BeginChild(ctx, '##dubscriptnote', -1, -1,
                                   _child_border_flag()) then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
      reaper.ImGui_TextWrapped(ctx, string.format(
        '%s writes the %s script from the transcript of your English audio.',
        (LLM_MODEL or '') ~= '' and LLM_MODEL or 'The translation model',
        LANGUAGE or 'target'))
      reaper.ImGui_PopStyleColor(ctx)
      reaper.ImGui_Dummy(ctx, 0, 6)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
      if FULL_RUN then
        reaper.ImGui_TextWrapped(ctx,
          'This run goes straight through, so you will not see the script ' ..
          'before it is spoken. Set Review to "Pause to check" and the run ' ..
          'stops here with the English beside it, editable, before anything ' ..
          'is charged.')
      else
        reaper.ImGui_TextWrapped(ctx,
          'The run stops after the translation and shows it here, beside the ' ..
          'English, editable. Nothing is charged until you approve it.')
      end
      reaper.ImGui_PopStyleColor(ctx)
      reaper.ImGui_EndChild(ctx)
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- v0.27 "Console" — the running screen
-- ═══════════════════════════════════════════════════════════════════════════
-- A dub run takes minutes, and this is the screen you sit in front of while it
-- does. It used to be the setup screen with the run column's head swapped for a
-- progress bar: a 288 px column carrying a percentage, a stage line, and a
-- six-row plan, next to a form locked read-only. So the pipeline — the thing
-- actually happening — was the narrowest element on the widest screen, and the
-- two-thirds given to a form you cannot edit said nothing that was changing.
--
-- Console turns it around. The pipeline becomes the top-level chrome, full
-- width, one card per stage carrying its own value and its own progress. What
-- the locked form was there to show you — the model, the voice, the sync mode,
-- the source — is in those cards and in the inspector, so nothing is lost by
-- letting the script have the middle of the screen instead.

V5.PIPE_MIN   = 132       -- per node; under this the rail uses fewer columns
V5.PIPE_GAP   = 6
V5.PIPE_CARD_H = 48
V5.CONSOLE_INSP = 300

-- One card. Deliberately not a child per node on old builds — six nested
-- children for six labels is a lot of ImGui for a strip that has to be cheap,
-- so the ground is drawn and the text placed on it.
function V5.pipe_card(ctx, r, i, w)
  local C  = V5.COL
  local dl = reaper.ImGui_GetWindowDrawList and reaper.ImGui_GetWindowDrawList(ctx)
  local rf = reaper.ImGui_DrawList_AddRectFilled
  local ok_draw = dl and rf and reaper.ImGui_GetCursorScreenPos

  local edge = (r.state == 'done')    and C.step_ok
            or (r.state == 'current') and C.info
            or (r.state == 'fail')    and C.err
            or (r.state == 'skip')    and 0x343A41FF
            or C.line
  local lbl = (r.state == 'current') and C.bright
           or (r.state == 'done')    and C.text2
           or (r.state == 'skip')    and C.faint
           or C.text

  local sx, sy
  if ok_draw then
    sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
    rf(dl, sx, sy, sx + w, sy + V5.PIPE_CARD_H,
       (r.state == 'current') and 0x1B222BFF or 0x1E2227FF, 4)
    rf(dl, sx, sy, sx + 2, sy + V5.PIPE_CARD_H, edge, 2)
  end

  -- The card's own text, placed inside it. An InvisibleButton gives the whole
  -- card the hover target, so the step's tooltip is on the step and not on a
  -- word inside it.
  local x0 = reaper.ImGui_GetCursorPosX(ctx) or 0
  local y0 = V5.y(ctx) or 0
  if reaper.ImGui_InvisibleButton then
    reaper.ImGui_InvisibleButton(ctx, '##pipe' .. i, w, V5.PIPE_CARD_H)
    if r.tip and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
      reaper.ImGui_SetTooltip(ctx, V5.wrap(r.label .. ' — ' .. r.tip ..
        (r.state == 'skip' and '\n\nSkipped in this run.' or '')))
    end
  end

  local inner = math.max(20, w - 18)
  if reaper.ImGui_SetCursorPos then
    reaper.ImGui_SetCursorPos(ctx, x0 + 9, y0 + 6)
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.dimmer)
  reaper.ImGui_Text(ctx, tostring(i))
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_SameLine(ctx, 0, 6)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), lbl)
  reaper.ImGui_Text(ctx, V5.ellipsize(ctx, r.label, inner - 20))
  reaper.ImGui_PopStyleColor(ctx)

  if reaper.ImGui_SetCursorPos then
    reaper.ImGui_SetCursorPos(ctx, x0 + 9, y0 + 25)
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                              (r.state == 'current') and C.warn or C.dimmer)
  reaper.ImGui_Text(ctx, V5.ellipsize(ctx, r.detail or '', inner))
  reaper.ImGui_PopStyleColor(ctx)

  -- The live step gets a hairline of its own progress, so which stage the bar
  -- above belongs to is never a guess.
  if r.state == 'current' and ok_draw then
    local f = math.max(0.02, math.min(1.0, _ui_progress or 0))
    rf(dl, sx + 9, sy + V5.PIPE_CARD_H - 7,
           sx + 9 + (w - 18) * f, sy + V5.PIPE_CARD_H - 5, C.info, 1)
  end

  -- Put the cursor back below the card, whatever the text did inside it.
  if reaper.ImGui_SetCursorPos then
    reaper.ImGui_SetCursorPos(ctx, x0, y0 + V5.PIPE_CARD_H)
  end
end

function V5.pipe_rail(ctx, on_cancel, elapsed)
  local C    = V5.COL
  local rows = V5.run_rows()

  -- Head: what is happening, for how long, and the two things you might do.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.info)
  reaper.ImGui_Text(ctx, _spinner_glyph() .. '  Running')
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_SameLine(ctx, 0, 10)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.dim)
  reaper.ImGui_Text(ctx, string.format('%02d:%02d',
    math.floor((elapsed or 0) / 60), (elapsed or 0) % 60))
  reaper.ImGui_PopStyleColor(ctx)

  -- The two buttons are pinned to the right of the head row, and only ever
  -- moved further right.
  local head_x = reaper.ImGui_GetCursorPosX and 0 or 0
  local room   = V5.room(ctx, 600)
  local cancel_w, log_w = 74, 78
  reaper.ImGui_SameLine(ctx, 0, 12)
  local at = reaper.ImGui_GetCursorPosX and reaper.ImGui_GetCursorPosX(ctx) or 0
  local want = room + head_x - cancel_w - 8 - log_w
  -- The stage line takes whatever is between the clock and those buttons.
  local stage_room = math.max(24, want - at - 10)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.warn)
  reaper.ImGui_Text(ctx, V5.ellipsize(ctx, _stage_line(), stage_room))
  reaper.ImGui_PopStyleColor(ctx)
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(_stage_line()))
  end

  reaper.ImGui_SameLine(ctx)
  local at2 = reaper.ImGui_GetCursorPosX and reaper.ImGui_GetCursorPosX(ctx) or 0
  if want > at2 then reaper.ImGui_SameLine(ctx, want) end
  if reaper.ImGui_Button(ctx, '≡  Log', log_w, 22) then V5.go('log') end
  reaper.ImGui_SameLine(ctx, 0, 8)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x883333FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xAA4444FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x661111FF)
  if reaper.ImGui_Button(ctx, 'Cancel', cancel_w, 22) then cancel_engine() end
  reaper.ImGui_PopStyleColor(ctx, 3)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PlotHistogram(), 0x3388FFFF)
  reaper.ImGui_ProgressBar(ctx, _ui_progress, -1, 6, '')
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)

  -- The cards. As many columns as the width holds, and the rest wrap — six
  -- 132 px minimums do not fit a panel dragged to 700 px, and a card too narrow
  -- for its value is worse than a second row of them.
  local avail = V5.room(ctx, 900)
  local cols  = math.max(1, math.min(#rows,
                  math.floor((avail + V5.PIPE_GAP) / (V5.PIPE_MIN + V5.PIPE_GAP))))
  local cw    = math.floor((avail - V5.PIPE_GAP * (cols - 1)) / cols)
  local x0    = reaper.ImGui_GetCursorPosX(ctx) or 0
  local rowy  = V5.y(ctx) or 0

  for i, r in ipairs(rows) do
    local col = (i - 1) % cols
    if col == 0 and i > 1 then
      rowy = rowy + V5.PIPE_CARD_H + V5.PIPE_GAP
    end
    if reaper.ImGui_SetCursorPos then
      reaper.ImGui_SetCursorPos(ctx, x0 + col * (cw + V5.PIPE_GAP), rowy)
    end
    V5.pipe_card(ctx, r, i, cw)
  end
  if reaper.ImGui_SetCursorPos then
    reaper.ImGui_SetCursorPos(ctx, x0, rowy + V5.PIPE_CARD_H + 4)
  end
end

-- The right-hand inspector: what this run is reading, what will speak it, and
-- what it is expected to cost.
function V5.console_inspector(ctx)
  V5.cap(ctx, 'SOURCE')
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBC4CEFF)
  reaper.ImGui_TextWrapped(ctx, (LAST_AUDIO or '') ~= ''
    and basename(LAST_AUDIO) or 'nothing chosen')
  reaper.ImGui_PopStyleColor(ctx)
  local secs = V5.source_secs()
  if secs then V5.kv(ctx, 'Length', V5.fmt_dur(secs)) end
  V5.kv(ctx, 'Language', tostring(LANGUAGE or '?'))

  reaper.ImGui_Dummy(ctx, 0, 6)
  V5.cap(ctx, 'VOICE')
  local vn = V5.voice_name(VOICE_ID or '')
  V5.kv(ctx, 'Voice', vn ~= '' and vn
        or ((VOICE_ID or '') ~= '' and 'voice set' or 'no voice'))
  V5.kv(ctx, 'Model', (EL_MODEL or '') ~= '' and EL_MODEL or 'eleven_v3')

  reaper.ImGui_Dummy(ctx, 0, 6)
  V5.cap(ctx, 'TRANSLATION')
  V5.kv(ctx, 'Source', SCRIPT_MODE == 'have' and 'your script' or 'AI')
  if SCRIPT_MODE ~= 'have' then
    V5.kv(ctx, 'Model', (LLM_MODEL or '') ~= '' and LLM_MODEL or 'not set')
  end
  V5.kv(ctx, 'Sync', tostring(V5.sync_mode) .. ' · ' .. tostring(V5.chunk_mode))

  reaper.ImGui_Dummy(ctx, 0, 6)
  -- The estimate, not a live total. run_dub.py does not report credits while it
  -- runs, and a number that looked live but was not would be worse than none —
  -- this is the screen people watch to decide whether to cancel.
  V5.cost_meter(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.faint)
  reaper.ImGui_TextWrapped(ctx,
    'An estimate, not a running total — the engine does not report credits ' ..
    'while it works.')
  reaper.ImGui_PopStyleColor(ctx)
end

-- ─── The Dub screen: setup AND running (v0.25) ────────────
-- One renderer for both phases, because they are the same screen. *elapsed* nil
-- means setup; a number means the engine is out, and the only thing that
-- changes is the run column's head — the form stays exactly where it was,
-- locked. Pressing Run used to swap the whole screen for a progress page, so
-- the values you had just chosen left the window at the moment you most wanted
-- to check them, and the running phase had to redraw the entire form read-only
-- underneath its progress bar to get them back.
local function ui_phase_setup(ctx, on_start, on_cancel, elapsed)
  local running = elapsed ~= nil

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),  6.0, 6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 3.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),  8.0, 4.0)

  -- v0.27: a run has its own screen (Console). Everything the locked form used
  -- to keep on view is in the pipeline rail and the inspector.
  if running then
    V5.ui_console(ctx, on_cancel, elapsed)
    reaper.ImGui_PopStyleVar(ctx, 3)
    return
  end

  -- v0.25: nothing is pinned under the body any more. The Run button moved into
  -- the column, on top of the plan it summarizes, so the body is the whole
  -- region and there is no measured footer height to reserve.
  local body = V5.begin_body(ctx, 0, true)
  if not body then
    reaper.ImGui_PopStyleVar(ctx, 3)
    return
  end

  -- The column is a flat 288 px at any sane window width, but the panel can be
  -- dragged narrower than the two of them together — and a fixed reserve there
  -- would hand BeginChild a NEGATIVE width for the form, which fills to the
  -- window edge and draws the form straight through the column. Below the
  -- threshold the column gives width back instead.
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  if type(avail) ~= 'number' or avail <= 0 then avail = 739 end
  local col_w = math.min(V5.CTX_W, math.max(150, math.floor(avail * 0.40)))
  col_w = math.min(col_w, math.max(60, avail - 120))

  -- ── The form ─────────────────────────────────────────────
  -- Everything in it is sized to fit, and its last block — your script, or what
  -- will be written into it — takes what is left, so the screen has exactly one
  -- scrollbar and it is inside the thing you are reading.
  if reaper.ImGui_BeginChild(ctx, '##dubform', -(col_w + 8), -1, 0,
                             V5.noscroll_flags()) then
    _ui_render_banner(ctx)

    -- This project's past runs, a paused one among them. Actions, so not
    -- offered while the engine is already out.
    if not running then
      V5.ui_history(ctx)
    end

    -- Locked, not hidden, while a run is out: the engine reads config/*.json at
    -- launch time, so changing these mid-run would describe a run that is not
    -- the one you are watching.
    _ui_begin_disabled(ctx, running)
    V5.ui_source_inputs(ctx)
    _ui_end_disabled(ctx)

    reaper.ImGui_EndChild(ctx)
  end

  -- ── The run column ───────────────────────────────────────
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_BeginChild(ctx, '##dubcol', -1, -1, _child_border_flag(),
                             V5.noscroll_flags()) then
    V5.ui_dub_column(ctx, on_start, on_cancel, elapsed)
    reaper.ImGui_EndChild(ctx)
  end

  reaper.ImGui_EndChild(ctx)   -- ##tabbody
  reaper.ImGui_PopStyleVar(ctx, 3)
end

-- The running screen: the pipeline across the top, the script in the middle,
-- the inspector on the right.
function V5.ui_console(ctx, on_cancel, elapsed)
  local body = V5.begin_body(ctx, 0, true)
  if not body then return end

  _ui_render_banner(ctx)
  V5.pipe_rail(ctx, on_cancel, elapsed)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)

  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  if type(avail) ~= 'number' or avail <= 0 then avail = 1024 end
  local col_w = math.min(V5.CONSOLE_INSP, math.max(0, avail - 380))
  if col_w < 200 then col_w = 0 end

  -- The middle: the script when there is one, and the engine's own voice when
  -- there is not. Both are "the thing you are watching"; which one it is
  -- depends only on whether the script exists yet.
  if reaper.ImGui_BeginChild(ctx, '##conmain',
                             col_w > 0 and -(col_w + 8) or -1, -1, 0,
                             V5.noscroll_flags()) then
    local have = SCRIPT_MODE == 'have' and (_provided_text or ''):match('%S')
    if have then
      V5.cap(ctx, tostring(LANGUAGE or 'TARGET'):upper() ..
                  '  SCRIPT  ·  LOCKED WHILE THE RUN IS OUT')
      -- Read-only: the engine read this at launch, so editing it now would
      -- describe a run that is not the one on screen.
      _ui_begin_disabled(ctx, true)
      V5.script_box(ctx, 'consolescript', _provided_text or '',
                    { fill = true, min = 120 })
      _ui_end_disabled(ctx)
    else
      V5.cap(ctx, 'ENGINE')
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x161B24FF)
      if reaper.ImGui_BeginChild(ctx, '##conlog', -1, -1, _child_border_flag()) then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
        if #_log_buffer == 0 then
          reaper.ImGui_TextWrapped(ctx, 'waiting for the engine…')
        end
        for i = math.max(1, #_log_buffer - 200), #_log_buffer do
          reaper.ImGui_TextWrapped(ctx, _log_buffer[i] or '')
        end
        reaper.ImGui_PopStyleColor(ctx)
        if reaper.ImGui_SetScrollHereY then reaper.ImGui_SetScrollHereY(ctx, 1.0) end
        reaper.ImGui_EndChild(ctx)
      end
      reaper.ImGui_PopStyleColor(ctx)
    end
    reaper.ImGui_EndChild(ctx)
  end

  if col_w > 0 then
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_BeginChild(ctx, '##coninsp', -1, -1, _child_border_flag()) then
      V5.console_inspector(ctx)
      reaper.ImGui_EndChild(ctx)
    end
  end

  reaper.ImGui_EndChild(ctx)   -- ##tabbody
end

-- ─── Settings tab (v0.5) ──────────────────────────────────
-- LLM + TTS keys (the old ⚙ collapsible), the Advanced python override,
-- and the shared fast-syncs updater. Locked while a run is active — the
-- engine reads config/*.json at launch time.
-- v0.7: one model per pipeline stage. Blank = the single Model field above.
-- *bare* (v0.13): drawn as a settings-window pane, which supplies its own
-- heading — so the collapsing header is skipped and the body always draws.
function V5.ui_models_section(ctx, bare)
  if not bare and not reaper.ImGui_CollapsingHeader(ctx, 'Model per stage') then
    return
  end
  reaper.ImGui_Indent(ctx, 12)
  _grey_hint(ctx, 'Leave a row on "same as Model" to use the Model set above ' ..
                  '(' .. ((LLM_MODEL or '') ~= '' and LLM_MODEL or 'not set') ..
                  '). Use this to give the cheap mechanical stages a faster ' ..
                  'model and keep the good one for translation.')
  reaper.ImGui_Dummy(ctx, 0, 2)
  for _, role in ipairs(V5.MODEL_ROLES) do
    local key, label, hint = role[1], role[2], role[3]
    V5.model_roles[key] = V5.model_picker(
      ctx, label .. '##model_' .. key, V5.model_roles[key], LLM_PROVIDER,
      'same as Model', 240)
    reaper.ImGui_SameLine(ctx)
    _grey_hint(ctx, hint)
  end
  reaper.ImGui_Dummy(ctx, 0, 2)
  _grey_hint(ctx, 'Auto Sync match is handed to the Auto Sync tab when you ' ..
                  'save; the others are read by the dubbing engine.')
  reaper.ImGui_Unindent(ctx, 12)
end

-- v0.7: add a target language. The engine picks it up from
-- config/custom_languages.json — no code change, but it needs prompt files,
-- so adding one seeds them from a language that already works.
function V5.ui_languages_section(ctx, bare)
  if not bare and not reaper.ImGui_CollapsingHeader(ctx, 'Languages') then
    return
  end
  reaper.ImGui_Indent(ctx, 12)
  _grey_hint(ctx, #V5.custom_langs .. ' added by you, ' ..
                  (#LANGUAGES - #V5.custom_langs) .. ' built in.')

  if V5.custom_langs_rejected and #V5.custom_langs_rejected > 0 then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFAA55FF)
    reaper.ImGui_TextWrapped(ctx, string.format(
      '%d entry/entries in custom_languages.json were ignored: %s\n' ..
      'A language name may contain letters, digits, spaces, - _ . ( ) and ' ..
      'non-Latin characters. Rename them in the file and reopen this panel.',
      #V5.custom_langs_rejected,
      table.concat(V5.custom_langs_rejected, ', '):gsub("%s", " ")))
    reaper.ImGui_PopStyleColor(ctx)
  end

  for i, l in ipairs(V5.custom_langs) do
    reaper.ImGui_Text(ctx, string.format('%s   (%s)', l.name,
                                         (l.code or '') ~= '' and l.code or '—'))
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, 'Remove##lang' .. i) then
      table.remove(V5.custom_langs, i)
      V5.custom_langs_save()
      for j = #LANGUAGES, 1, -1 do
        if LANGUAGES[j] == l.name then table.remove(LANGUAGES, j) end
      end
      if LANGUAGE == l.name then LANGUAGE = LANGUAGES[1] or 'Bengali' end
      ui_set_banner("info", 'Removed "' .. l.name ..
        '". Its prompt files were left in place.')
      break
    end
  end

  reaper.ImGui_Dummy(ctx, 0, 2)
  local rv
  rv, V5.newlang_name = reaper.ImGui_InputText(ctx, 'New language',
                                               V5.newlang_name or '')
  rv, V5.newlang_code = reaper.ImGui_InputText(ctx, 'Locale code',
                                               V5.newlang_code or '')
  reaper.ImGui_SameLine(ctx)
  _grey_hint(ctx, 'e.g. pa-IN — labelling only')

  V5.newlang_src = V5.newlang_src or LANGUAGES[1] or 'Bengali'
  local _, picked = _ui_combo(ctx, 'Copy prompts from', V5.newlang_src,
                              LANGUAGES)
  V5.newlang_src = picked

  local name = (V5.newlang_name or ''):match('^%s*(.-)%s*$')
  local dup = false
  for _, l in ipairs(LANGUAGES) do if l == name then dup = true end end
  -- Validate with the canonical predicate rather than a private character
  -- class; '^[%w%-_ ]+$' rejected '.', parentheses and every non-Latin name
  -- that the loader and all three Python readers accept.
  local can = not dup and V5._is_safe_lang_name(name)
  _ui_begin_disabled(ctx, not can)
  if reaper.ImGui_Button(ctx, 'Add language', 150, 26) and can then
    V5.custom_langs[#V5.custom_langs + 1] = {
      name = name,
      code = (V5.newlang_code or ''):match('^%s*(.-)%s*$'),
      tag  = name:sub(1, 2):upper(),
    }
    LANGUAGES[#LANGUAGES + 1] = name
    table.sort(LANGUAGES)
    local okw = V5.custom_langs_save()
    local copied, skipped, missing = V5.prompts_seed(V5.newlang_src, name)
    if not okw then
      ui_set_banner("error", 'Could not write ' .. V5.CUSTOM_LANGS_PATH)
    elseif #missing > 0 then
      ui_set_banner("warn", string.format(
        '"%s" added, but %d prompt file(s) could not be copied from %s (%s). ' ..
        'Write them in the Prompts section before dubbing into it.',
        name, #missing, V5.newlang_src, table.concat(missing, ', ')))
    else
      ui_set_banner("info", string.format(
        '"%s" added. %d prompt(s) copied from %s%s — edit them in the ' ..
        'Prompts section so they name the right language.',
        name, copied, V5.newlang_src,
        skipped > 0 and (', ' .. skipped .. ' already existed') or ''))
    end
    V5.newlang_name = ''
  end
  _ui_end_disabled(ctx)
  if not can and name ~= '' then
    reaper.ImGui_SameLine(ctx)
    _grey_hint(ctx, dup and 'that language already exists'
                    or 'letters, digits, spaces, - and _ only')
  end
  reaper.ImGui_Unindent(ctx, 12)
end

-- v0.7: edit the per-language prompt files from inside the panel.
function V5.ui_prompts_section(ctx, bare)
  if not bare and not reaper.ImGui_CollapsingHeader(ctx, 'Prompts') then
    return
  end
  reaper.ImGui_Indent(ctx, 12)
  _grey_hint(ctx, 'These are the instructions sent to the AI at each stage. ' ..
                  'One file per language per stage, in dubbing/prompts/.')

  V5.prompt_lang = V5.prompt_lang or LANGUAGE
  -- '##prlang' / '##prstage', not '##pr' twice: ImGui hashes only what
  -- follows '##', so both combos were literally the same widget id — picking
  -- a language could leave the stage combo holding the activation state.
  local changed, picked = _ui_combo(ctx, 'Language##prlang', V5.prompt_lang,
                                    LANGUAGES)
  local reload = false
  if changed then V5.prompt_lang = picked; reload = true end

  local stage_names = {}
  for i, s in ipairs(V5.PROMPT_STAGES) do
    stage_names[i] = s:gsub("_", " ")
  end
  local cur_stage = stage_names[V5.prompt_stage] or stage_names[1]
  local ch2, picked2 = _ui_combo(ctx, 'Stage##prstage', cur_stage, stage_names)
  if ch2 then
    for i, s in ipairs(stage_names) do
      if s == picked2 then V5.prompt_stage = i break end
    end
    reload = true
  end

  if reload or V5.prompt_open == "" then
    if V5.prompt_dirty and not reload then
      -- keep unsaved edits on the very first open
    else
      local existed = V5.prompt_editor_load(V5.prompt_lang, V5.prompt_stage)
      if not existed then
        ui_set_banner("warn", 'No prompt file yet for this language and ' ..
          'stage. Pick another language above, copy its text, and paste it ' ..
          'here before pressing Save.')
      end
    end
  end

  local pushed = _push_font(ctx, 15)
  local rv, txt = reaper.ImGui_InputTextMultiline(
    ctx, '##prompt_edit', V5.prompt_text or '', -1, 260)
  if pushed then _pop_font(ctx) end
  if rv then V5.prompt_text = txt; V5.prompt_dirty = true end

  V5.wrap_begin(ctx, 6)
  V5.wrap_next(ctx, 140)
  _ui_begin_disabled(ctx, not V5.prompt_dirty)
  if reaper.ImGui_Button(ctx, '💾 Save prompt', 140, 26) then
    local ok, why = V5.prompt_editor_save()
    ui_set_banner(ok and "info" or "error",
      ok and ('Saved ' .. basename(V5.prompt_open)) or why)
  end
  _ui_end_disabled(ctx)
  V5.wrap_next(ctx, 100)
  if reaper.ImGui_Button(ctx, '⟲ Reload', 100, 26) then
    V5.prompt_editor_load(V5.prompt_lang, V5.prompt_stage)
    ui_set_banner("info", 'Reloaded from disk — unsaved edits discarded.')
  end
  V5.wrap_next(ctx, 130)
  if reaper.ImGui_Button(ctx, 'Open in editor', 130, 26) then
    if V5.prompt_dirty then V5.prompt_editor_save() end
    open_path(V5.prompt_open)
  end
  -- Clusters, not bytes: a Devanagari prompt reported three times its length.
  local pstat = (V5.prompt_dirty and 'unsaved · ' or '') ..
                string.format('%d chars', V5.cells(V5.prompt_text or ''))
  V5.wrap_next(ctx, V5.text_w(ctx, pstat, 8) + 8)
  _grey_hint(ctx, pstat)
  V5.wrap_end()
  _grey_hint(ctx, V5.prompt_open)
  reaper.ImGui_Unindent(ctx, 12)
end

-- ── Remaining settings panes ────────────────────────────────
-- Each supplies its own heading; the shared bodies are drawn *bare*, without
-- the collapsing header they wear when they appear inline in the old tab.

function V5.pane_models(ctx)
  V5.heading(ctx, 'Models',
    'A different model per stage, when the default is not the right trade-off')
  V5.ui_models_section(ctx, true)
end

-- v0.17: no Languages pane. V5.ui_languages_section above is kept because it
-- is the only writer of config/custom_languages.json — a language someone
-- already added still loads and still dubs; there is simply no editor for the
-- list in the panel any more. Re-adding it is one line in V5.PANES.

function V5.pane_prompts(ctx)
  V5.heading(ctx, 'Prompts', 'The instructions sent to the AI at each stage')
  V5.ui_prompts_section(ctx, true)
end

-- Advanced: the two engine switches and the Python override. Both switches
-- are written straight into engine_settings.json, which the engine reads at
-- launch — so they are settings, not per-run choices.
function V5.pane_advanced(ctx)
  V5.heading(ctx, 'Advanced',
    'Engine behaviour and the Python interpreter — rarely worth changing')
  local rv
  V5.form_begin(ctx, 'advanced')

  -- v0.8: piece size for dub runs.
  V5.label(ctx, 'Dub pieces')
  local cm = V5.dropdown(ctx, 'chunkmode', V5.chunk_mode, {
    { 'clause',   'Clause',
      'Default. The voice is generated in long natural stretches, then cut ' ..
      'at the exact times ElevenLabs reports — at sentence ends, and inside ' ..
      'a long sentence at its ; : , or dash. That is the granularity the old ' ..
      'pipeline got from cutting at every silence.' },
    { 'sentence', 'Sentence', 'One piece per sentence.' },
    { 'section',  'Section',  'One piece per thought (v0.7).' },
  }, 180)
  V5.hint(ctx, 'How small the dub audio is cut before it is placed. Clause ' ..
               '(default) is the finest and drifts least; Section is the ' ..
               'coarsest and reads most naturally. Open the list for what ' ..
               'each one does. Only Match sync mode uses this.')
  if cm ~= V5.chunk_mode then
    V5.chunk_mode = cm
    local okc, badpath = V5.save_chunk_mode()
    if not okc then
      ui_set_banner("error", "Could not write:\n" .. tostring(badpath))
    end
  end

  -- v0.12: sync mode (match | legacy).
  reaper.ImGui_Dummy(ctx, 0, 4)
  V5.label(ctx, 'Sync mode')
  local sm = V5.dropdown(ctx, 'syncmode', V5.sync_mode, {
    { 'match',  'Match',
      'v0.7 default. Pre-TTS Gemini matching. Fast, saves API costs, but ' ..
      'strict on timing — overruns go to the Un sync track.' },
    { 'legacy', 'Legacy',
      'v0.2/v0.3 behaviour. Post-TTS transcription matching. Slower, but ' ..
      'lenient on timing: overlapping items are nudged forward instead of ' ..
      'parked. Switch here if your translations run long and clips keep ' ..
      'landing on Un sync.' },
  }, 180)
  V5.hint(ctx, 'How dub clips get their timeline positions. Match is the ' ..
               'fast, cheap default; Legacy is slower but nudges overlapping ' ..
               'clips instead of parking them on Un sync. Open the list for ' ..
               'the full difference.')
  if sm ~= V5.sync_mode then
    V5.sync_mode = sm
    local okc, badpath = V5.save_chunk_mode()
    if not okc then
      ui_set_banner("error", "Could not write:\n" .. tostring(badpath))
    end
  end

  reaper.ImGui_Dummy(ctx, 0, 8)
  V5.field(ctx, 'Python', 260)
  rv, PYTHON_CMD = reaper.ImGui_InputText(ctx, '##pycmd', PYTHON_CMD or '')
  V5.hint(ctx, 'Leave blank to auto-detect (dubbing/venv/ first, then system ' ..
               'installs). Run ' .. SETUP_SCRIPT .. ' once to create venv/.')
  V5.form_end(ctx)
end

function V5.pane_about(ctx)
  V5.heading(ctx, 'About', 'Version and updates')

  -- v0.16: the version and whether it is current, instead of a bare "Update…"
  -- button that answered neither question.
  local line, colour = V5.update_status_line()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), colour)
  reaper.ImGui_Text(ctx, 'Fast Syncs   ' .. line)
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_Dummy(ctx, 0, 8)

  if not V5.updater_path() then
    _grey_hint(ctx, 'No fast-syncs updater found above dubbing/ — this ' ..
                    'looks like a standalone install, so updates have to be ' ..
                    'downloaded by hand.')
    return
  end

  if V5.upd.state == 'available' then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        V5.COL.go)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), V5.COL.go_hi)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  V5.COL.go_act)
    if reaper.ImGui_Button(ctx, 'Download v' .. tostring(V5.upd.latest),
                           190, 28) then
      V5.run_updater()
    end
    reaper.ImGui_PopStyleColor(ctx, 3)
    V5.hint(ctx, 'Runs the shared updater in a terminal — it updates the ' ..
                 'sync tool AND this dubbing app. Your settings, venv and ' ..
                 'keys are left alone.')
  else
    -- Checking, up to date, or the check failed: re-checking is the useful
    -- button. Updating anyway stays available behind it.
    _ui_begin_disabled(ctx, V5.upd.state == 'checking')
    if reaper.ImGui_Button(ctx, 'Check for updates', 160, 28) then
      V5.check_update()
    end
    _ui_end_disabled(ctx)
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, 'Re-install latest', 150, 28) then
      V5.run_updater()
    end
    V5.hint(ctx, 'Re-install runs the updater even when you are already on ' ..
                 'the newest version — useful when an install is damaged.')
  end

  if V5.upd.state == 'failed' then
    reaper.ImGui_Dummy(ctx, 0, 4)
    _grey_hint(ctx, 'The check needs curl and access to raw.githubusercontent' ..
                    '.com. It failing does not affect anything else — the ' ..
                    'updater itself still works.')
  end
end

-- v0.17: four panes, down from six.
--   Voices    → the Tools tab (V5.ui_voices_tool) — it is voice work, not
--               configuration, and its one real setting (the key) is a
--               credential, so that went to Connections.
--   Languages → gone. The target list still comes from LANGUAGES plus
--               config/custom_languages.json, so nothing about dubbing
--               changed; only the in-panel editor for it is retired.
V5.PANES = {
  { 'connection', 'Connections', V5.pane_connection },
  { 'models',     'Models',      V5.pane_models     },
  { 'prompts',    'Prompts',     V5.pane_prompts    },
  { 'advanced',   'Advanced',    V5.pane_advanced   },
  { 'about',      'About',       V5.pane_about      },
}

-- Save is shared by the settings SCREEN (v0.16, a rail destination) and the
-- legacy settings window, so the "saved but the LLM still is not usable"
-- reporting cannot drift between the two.
function V5.do_save_settings()
  local ok, path = save_config_files()
  if ok and LAST_SYNC_CRED_ERR then
    ui_set_banner("error", "Saved for dubbing, but could not share the keys " ..
                           "with Sync:\n" .. LAST_SYNC_CRED_ERR ..
                           "\nSync may still use older keys.")
  elseif ok then
    local why = V5.llm_creds_error()
    if why then
      ui_set_banner("warn", "Saved, but the LLM is not usable yet:\n" .. why)
    elseif LLM_PROVIDER ~= 'server' then
      start_test_llm()
    else
      ui_set_banner("info", "Saved.")
    end
  else
    ui_set_banner("error", "Could not write settings file:\n" .. tostring(path))
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- v0.16 CONSOLE SHELL — rail left, screen middle, context card right
-- ═══════════════════════════════════════════════════════════════════════════
-- Why a rail instead of the tab bar:
--   * five destinations, a version string, a readiness light and a gear did not
--     fit on one row, so the gear sat at (window width - 122) and the light
--     floated between them;
--   * Settings had to stop being a second top-level window — it could drift
--     behind REAPER and needed its own copy of the off-screen rescue;
--   * a fixed rail plus a fixed context column means nothing on screen moves
--     when the phase changes, so Start/Approve/Import always sit in the same
--     place and the read-only duplicate of the form is no longer needed.
V5.RAIL_W = 138
V5.CTX_W  = 288           -- context / run card column

-- Dear ImGui gives a BORDERLESS child zero WindowPadding — which is why the
-- screen's first column sat flush against the rail's dividing line, and why the
-- rail's own items ran edge to edge. Ask for the padding back explicitly. The
-- flag moved between ReaImGui generations: it is a CHILD flag (arg 5) on new
-- builds and a WINDOW flag (arg 6) on old ones, so it cannot simply be OR-ed
-- into one number.
-- *wflags* (v0.19, optional) is OR-ed into the WINDOW flags — V5.noscroll_flags
-- for a column that must not scroll. It cannot simply be passed by callers,
-- because which argument carries padding moves between ReaImGui generations.
function V5.begin_padded_child(ctx, id, w, h, wflags)
  wflags = wflags or 0
  local cf = reaper.ImGui_ChildFlags_AlwaysUseWindowPadding
  if cf then return reaper.ImGui_BeginChild(ctx, id, w, h, cf(), wflags) end
  local wf = reaper.ImGui_WindowFlags_AlwaysUseWindowPadding
  if wf then return reaper.ImGui_BeginChild(ctx, id, w, h, 0, wflags | wf()) end
  return reaper.ImGui_BeginChild(ctx, id, w, h, 0, wflags)
end

-- The console tokens, pushed once per frame: one control height (FramePadding
-- y = 4 → 20 px rows), one 6 px gutter, 1 px hairlines instead of gaps, and a
-- graphite ground. Every entry is GUARDED — a style var or colour the installed
-- ReaImGui does not have is skipped, and the counts of what was actually pushed
-- come back so the pop matches exactly (a mismatch here corrupts every later
-- frame, which is why this is not two hand-counted numbers).
function V5.push_console_style(ctx)
  local nv, nc = 0, 0
  local function var(name, a, b)
    local f = reaper['ImGui_StyleVar_' .. name]
    if not f then return end
    if b then reaper.ImGui_PushStyleVar(ctx, f(), a, b)
    else        reaper.ImGui_PushStyleVar(ctx, f(), a) end
    nv = nv + 1
  end
  local function col(name, rgba)
    local f = reaper['ImGui_Col_' .. name]
    if not f then return end
    reaper.ImGui_PushStyleColor(ctx, f(), rgba)
    nc = nc + 1
  end

  var('WindowPadding',   8, 8)
  var('ItemSpacing',     6, 6)
  var('ItemInnerSpacing', 6, 4)
  var('CellPadding',     7, 2)
  var('FramePadding',    8, 4)
  var('ScrollbarSize',   11)
  var('FrameBorderSize', 1)

  -- v0.22: ONE radius for everything with a corner. Before this only frames,
  -- children and grabs were rounded, so a combo's drop-down list and the
  -- scrollbar kept ImGui's square corners next to rounded fields — the kind of
  -- half-applied styling that reads as unfinished rather than as a choice.
  local R = V5.ROUND
  var('FrameRounding',     R)
  var('ChildRounding',     R)
  var('GrabRounding',      R)
  var('PopupRounding',     R)
  var('ScrollbarRounding', R)
  var('TabRounding',       R)
  var('WindowRounding',    R)

  local C = V5.COL
  col('WindowBg',          C.bg)
  col('ChildBg',           C.panel)
  col('FrameBg',           C.sunken)
  col('FrameBgHovered',    C.sunken_hi)
  col('FrameBgActive',     C.sunken_act)
  col('Border',            C.line)
  col('Text',              C.text)
  col('TextDisabled',      C.off)
  col('Button',            C.btn)
  col('ButtonHovered',     C.btn_hi)
  col('ButtonActive',      C.btn_act)
  col('Header',            C.hdr)
  col('HeaderHovered',     C.hdr_hi)
  col('HeaderActive',      C.hdr_act)
  col('Separator',         C.line)
  col('TableHeaderBg',     C.panel)
  col('TableBorderLight',  C.line_soft)
  col('TableBorderStrong', C.line)
  col('TitleBg',           C.sunken)
  col('TitleBgActive',     C.title_act)
  col('ScrollbarBg',       C.sunken)
  col('ScrollbarGrab',     C.hdr_hi)
  col('PlotHistogram',     C.plot)
  -- v0.22: the states nothing set before, which therefore kept Dear ImGui's
  -- stock cornflower blue. PopupBg is the one that shows: it is the background
  -- of every drop-down list the panel now opens.
  col('PopupBg',           C.panel)
  col('TextSelectedBg',    C.sel_bg)
  col('CheckMark',         C.accent_hi)
  col('SliderGrab',        C.accent)
  col('SliderGrabActive',  C.accent_hi)
  col('SeparatorHovered',  C.accent)
  col('SeparatorActive',   C.accent_hi)
  col('ScrollbarGrabHovered', C.accent)
  col('ScrollbarGrabActive',  C.accent_hi)
  return nv, nc
end

function V5.pop_console_style(ctx, nv, nc)
  if nc and nc > 0 then reaper.ImGui_PopStyleColor(ctx, nc) end
  if nv and nv > 0 then reaper.ImGui_PopStyleVar(ctx, nv) end
end

V5.NAV = {
  { 'dub',      '▶   Dub'      },
  { 'sync',     '⇄   Sync'     },
  { 'tools',    '✦   Tools'    },
  { 'log',      '≡   Log'      },
  { 'settings', '⚙   Settings' },
}

-- True when the dub side wants attention while the user is looking elsewhere.
function V5.phase_wants_attention()
  return _ui_phase == 'review' or _ui_phase == 'plan'
      or _ui_phase == 'success' or _ui_phase == 'failure'
end

function V5.go(nav)
  if V5.nav ~= nav then
    V5.nav = nav
    save_settings()
  end
end

function V5.ui_rail(ctx)
  if not V5.begin_padded_child(ctx, '##rail', V5.RAIL_W, -1) then return end

  -- The frame-wide FrameBorderSize draws a box around every Button, which on a
  -- stack of transparent nav items made the rail a column of empty rectangles.
  -- A rail item is a row of text that highlights when selected — no box.
  local bordered = reaper.ImGui_StyleVar_FrameBorderSize
  if bordered then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
  end

  -- Identity lives here now, not on a row the content has to pay for.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
  reaper.ImGui_Text(ctx, ' FAST SYNCS')
  if V5.APP_VERSION ~= '' then
    reaper.ImGui_Text(ctx, ' v' .. V5.APP_VERSION)
  end
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Dummy(ctx, 0, 4)

  for _, item in ipairs(V5.NAV) do
    -- Settings is a destination, but not a sibling of the four work screens.
    if item[1] == 'settings' then
      reaper.ImGui_Dummy(ctx, 0, 2)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Dummy(ctx, 0, 2)
    end
    local on   = (V5.nav == item[1])
    -- A marker, not a badge: the dub side wants a decision, or a newer version
    -- exists and About is where you act on it.
    local nag  = (item[1] == 'dub' and not on and V5.phase_wants_attention())
                 or (item[1] == 'settings' and V5.upd.available)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
                               on and V5.COL.accent or 0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),
                               on and V5.COL.accent_hi or V5.COL.hdr_hi)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), V5.COL.accent_act)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                               on and V5.COL.bright
                               or (nag and V5.COL.warn or V5.COL.text2))
    if reaper.ImGui_Button(ctx,
        item[2] .. (nag and '  •' or '') .. '##nav' .. item[1], -1, 26) then
      V5.go(item[1])
    end
    reaper.ImGui_PopStyleColor(ctx, 4)
  end

  -- v0.16: no Update button here. An action you take twice a year does not
  -- earn a permanent place on the first screen, and a button labelled "Update"
  -- tells you nothing about whether you need one. The version and its state
  -- live in Settings → About; when a newer version exists the Settings item
  -- above carries a marker.
  if bordered then reaper.ImGui_PopStyleVar(ctx) end
  reaper.ImGui_EndChild(ctx)
end

-- A dim all-caps label, the only "heading" the console has.
function V5.cap(ctx, text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
  -- Ellipsized, not wrapped: a caption is one line by definition, and every
  -- block that follows one is sized on the assumption that it is. These are the
  -- widest single-line strings in the narrow columns — a language name plus
  -- 'SCRIPT · LOCKED WHILE THE RUN IS OUT' does not fit a 356 px pane.
  local room = V5.room(ctx, 200)
  reaper.ImGui_Text(ctx, V5.ellipsize(ctx, text, math.max(24, room - 4)))
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)
end

-- One readiness list, replacing the four _status_dot calls that each computed
-- their own answer at (window width - 38) with no legend. Shared by the
-- Settings screen's card and the Dub screen's context column, so the answer
-- cannot differ between the place you fix it and the place you start from.
function V5.readiness_rows(ctx)
  local function row(ok_, label, tip)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                                ok_ and V5.COL.ok or V5.COL.warn_text)
    reaper.ImGui_Text(ctx, ok_ and 'ok' or ' !')
    reaper.ImGui_SameLine(ctx, 30)
    -- Ellipsized: a voice name plus a language name is longer than the 288 px
    -- column at any window width, and this list is shown in the narrowest
    -- column on the screen. The full text is in the tooltip below.
    local room = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_Text(ctx, (type(room) == 'number' and room > 40)
                           and V5.ellipsize(ctx, label, room) or label)
    reaper.ImGui_PopStyleColor(ctx)
    if tip and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
      reaper.ImGui_SetTooltip(ctx, V5.wrap(tip))
    end
  end

  local why   = V5.llm_creds_error()
  local voice = V5.voice_name(VOICE_ID or '')
  row(not why, 'LLM  ·  ' .. tostring(LLM_PROVIDER or '?'), why)
  row((EL_KEY or '') ~= '', 'Voice  ·  ElevenLabs',
      'Transcription and every voice stage need an ElevenLabs key.')
  row((VOICE_ID or '') ~= '',
      (voice ~= '' and voice or 'default voice') .. '  ·  ' ..
      tostring(LANGUAGE or '?'),
      'The voice every stage falls back to. Fetch voices in the Voices pane, ' ..
      'then pick one.')
  row((LAST_AUDIO or '') ~= '' , 'English audio chosen',
      'The source file the run reads. Pick it on the Dub screen.')
end

function V5.ui_readiness(ctx)
  V5.cap(ctx, 'READINESS')
  V5.readiness_rows(ctx)

  reaper.ImGui_Dummy(ctx, 0, 4)
  _grey_hint(ctx, 'Every pane writes the same two config files, so one Save ' ..
                  'covers the whole screen.')
  reaper.ImGui_Dummy(ctx, 0, 2)
  if reaper.ImGui_BeginChild(ctx, '##cfgpaths', -1, 44, _child_border_flag()) then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
    -- Wrapped: this card is as narrow as 184 px once the settings screen starts
    -- giving width back, and a path is 155 px of unbreakable text.
    reaper.ImGui_TextWrapped(ctx, 'config/llm_settings.json')
    reaper.ImGui_TextWrapped(ctx, 'config/tts_settings.json')
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_EndChild(ctx)
  end
end

-- ── The run column (v0.25) ──────────────────────────────────
-- The Dub screen is a form on the left and this column on the right, in setup
-- AND while running. Everything about the run lives here: the one button that
-- starts it, what it will cost, the plan with the values it will actually use,
-- whether it can start at all, and — once it is out — how far along it is.

-- ── v0.27 the cost meter ────────────────────────────────────────────────────
-- What the run will spend, before it starts, split by what spends it. A run
-- charges for two things: the transcription of the English (once, whatever
-- else happens) and the synthesis of the script. Only the second is affected by
-- shortening the script, which is the decision this number exists to inform —
-- so a single total was the one shape that could not say anything useful.
--
-- The estimate is honest about being one: ElevenLabs bills per character and
-- the transcription share depends on the source's length, which the panel does
-- not know until the engine reports it. The headroom band is the difference,
-- drawn rather than hidden, so a total that comes in over the estimate is not a
-- surprise.
V5.COST_TR_PER_MIN = 60      -- transcription credits per minute of source
V5.COST_HEADROOM   = 0.15    -- what a run typically lands over the estimate

-- Rough source length in seconds, from whatever the panel actually knows. Nil
-- when it knows nothing, which is the usual case before a run.
function V5.source_secs()
  if V5.plan and V5.plan.total_s and V5.plan.total_s > 0 then
    return V5.plan.total_s
  end
  return nil
end

function V5.cost_parts()
  local tts = 0
  if SCRIPT_MODE == 'have' and (_provided_text or ''):match('%S') then
    tts = V5.credit_est(_provided_text)
  end
  local secs = V5.source_secs()
  local tr   = secs and math.floor(secs / 60 * V5.COST_TR_PER_MIN) or nil
  return tts, tr
end

function V5.cost_meter(ctx)
  local tts, tr = V5.cost_parts()
  -- Nothing measurable yet: in AI-translation mode the script does not exist,
  -- and inventing a number for it would be worse than saying so.
  if tts <= 0 then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
    reaper.ImGui_TextWrapped(ctx, SCRIPT_MODE == 'have'
      and 'Paste the script and the cost appears here.'
      or  'The cost is known once the translation exists — the run pauses ' ..
          'there if Review is set to check it.')
    reaper.ImGui_PopStyleColor(ctx)
    return
  end

  local head  = math.floor(tts * V5.COST_HEADROOM)
  local total = tts + (tr or 0) + head

  reaper.ImGui_Dummy(ctx, 0, 4)
  local x0   = reaper.ImGui_GetCursorPosX(ctx) or 0
  local room = V5.room(ctx, 260)

  V5.cap(ctx, 'ESTIMATED COST')
  -- The total, right-aligned on the caption's own line, and only ever moved
  -- further right.
  local tot = string.format('%d cr', total)
  local tw  = V5.text_w(ctx, tot, 8)
  reaper.ImGui_SameLine(ctx)
  local at = reaper.ImGui_GetCursorPosX and reaper.ImGui_GetCursorPosX(ctx) or 0
  if x0 + room - tw > at + 8 then
    reaper.ImGui_SameLine(ctx, x0 + room - tw)
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.text)
  reaper.ImGui_Text(ctx, tot)
  reaper.ImGui_PopStyleColor(ctx)

  -- Three bands in one bar. Drawn, not three ProgressBars: they have to add up
  -- to one width, and a rounded bar per band would read as three separate
  -- measurements of three different things.
  local dl   = reaper.ImGui_GetWindowDrawList and reaper.ImGui_GetWindowDrawList(ctx)
  local rect = reaper.ImGui_DrawList_AddRectFilled
  if dl and rect and reaper.ImGui_GetCursorScreenPos then
    local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
    local bw, bh = math.max(40, room), 8
    reaper.ImGui_Dummy(ctx, bw, bh)
    rect(dl, sx, sy, sx + bw, sy + bh, 0x22262BFF, 4)
    local x = sx
    for _, band in ipairs({ { tts, V5.COL.job }, { tr or 0, V5.COL.accent },
                            { head, 0x2A3038FF } }) do
      if band[1] > 0 then
        local seg = bw * (band[1] / total)
        rect(dl, x, sy, x + seg, sy + bh, band[2], 4)
        x = x + seg
      end
    end
  else
    -- No draw list on this build: one bar for the share that matters.
    reaper.ImGui_ProgressBar(ctx, tts / total, -1, 8, '')
  end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
  local legend = string.format('TTS %d', tts)
  if tr then legend = legend .. string.format('  ·  transcribe %d', tr) end
  legend = legend .. string.format('  ·  headroom %d', head)
  reaper.ImGui_TextWrapped(ctx, legend)
  reaper.ImGui_Text(ctx, string.format('~%s of speech',
    V5.fmt_dur(V5.speech_secs(_provided_text))))
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)
end

-- The plan as data: the five steps of V5.STEPS, each carrying the value it will
-- actually use, plus the review pause as a row of its own. The pause is a row
-- because it is the only step that is YOURS, and because of where it sits — it
-- is what stands between the words and the step that pays to speak them.
function V5.run_rows()
  local st    = V5.stepper_state()
  local voice = V5.voice_name(VOICE_ID or '')
  if voice == '' then
    voice = (VOICE_ID or '') ~= '' and 'voice set' or 'no voice yet'
  end

  local detail = {
    'ElevenLabs transcribe',
    (SCRIPT_MODE == 'have') and 'skipped — your script'
      or ((LLM_MODEL or '') ~= '' and LLM_MODEL or 'no model yet'),
    voice .. '  ·  ' .. ((EL_MODEL or '') ~= '' and EL_MODEL or 'eleven_v3'),
    V5.sync_mode .. '  ·  ' .. V5.chunk_mode .. ' pieces',
    'this REAPER project',
  }

  local rows = {}
  for i, s in ipairs(V5.STEPS) do
    rows[#rows + 1] = { label = s.label, detail = detail[i], state = st[i],
                        tip = s.tip }
    if i == 2 then
      local ps = 'todo'
      if     FULL_RUN                                then ps = 'skip'
      elseif _ui_phase == 'review'                   then ps = 'current'
      elseif st[3] ~= 'todo' or st[4] ~= 'todo'      then ps = 'done'
      end
      rows[#rows + 1] = {
        label  = 'Your check',
        detail = FULL_RUN and 'skipped — straight through'
                           or 'the run pauses here',
        state  = ps,
        tip    = 'A staged run stops after the translation and shows it beside ' ..
                 'the English, editable, so you can fix the wording before ' ..
                 'the voice stage spends anything.',
      }
    end
  end
  return rows
end

V5.PLAN_GUTTER = 18       -- the dots' column, left of the labels
V5.PLAN_VALUE  = 96       -- FLOOR for the value column, from the same origin

-- The plan drawn as a vertical list. Nothing in here is centred, which is the
-- other reason it replaced the horizontal stepper: ReaImGui answers 0 for the
-- width of a glyph its atlas has not rasterized yet, so every centred label was
-- one bad measurement away from the wrong pixel. A label that starts at the
-- left margin cannot be measured wrong.
function V5.run_plan(ctx)
  local rows = V5.run_rows()
  local C    = V5.COL

  local dl  = reaper.ImGui_GetWindowDrawList and reaper.ImGui_GetWindowDrawList(ctx)
  local fil = reaper.ImGui_DrawList_AddCircleFilled
  local rng = reaper.ImGui_DrawList_AddCircle
  local lin = reaper.ImGui_DrawList_AddLine
  -- No draw list on this build: the rows keep their text marks instead of dots.
  local dots = dl and fil and rng and lin and reaper.ImGui_GetCursorScreenPos

  local LBL  = { done = C.text2,   current = C.bright, fail = C.err,
                 todo = C.text,    skip    = C.faint }
  local MARK = { done = '[x]  ',   current = '[>]  ',  fail = '[!]  ',
                 skip = '[-]  ',   todo    = '[ ]  ' }
  local FILL = { done = C.step_ok, current = C.accent_hi, fail = C.err }

  -- One line per step, and a tight one: at the panel's 6 px ItemSpacing a
  -- two-line row would put six steps at 276 px, which does not fit beside the
  -- readiness rows in a 288 px column without a scrollbar. 2 px between rows
  -- also reads as a timeline rather than as six separate paragraphs.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 6.0, 2.0)

  -- v0.26: where the value column starts is MEASURED from the widest label
  -- this frame, with V5.PLAN_VALUE as the floor. The flat 96 survived only
  -- because 'Transcribe' is 78 px at V5.UI_PX = 14 — raise the UI size,
  -- translate a step name, or add a longer one and the value was overprinted.
  local vcol = V5.PLAN_VALUE
  for _, r in ipairs(rows) do
    local lbl = (dots and '' or (MARK[r.state] or '')) .. r.label
    local lw  = V5.text_w(ctx, lbl, 8) + 14
    if lw > vcol then vcol = lw end
  end

  local pts = {}
  for _, r in ipairs(rows) do
    if dots then
      local ok, sx, sy = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
      if ok and type(sx) == 'number' and type(sy) == 'number' then
        pts[#pts + 1] = { x = sx + 5.5, y = sy + 8, state = r.state }
      end
    end

    -- A zero-width anchor, so both columns can be placed with an absolute
    -- SameLine offset. Indent would work for the label but SameLine's offset is
    -- measured from the content origin and does not carry the indent, so the
    -- two would disagree about where the value column is.
    reaper.ImGui_Text(ctx, '')
    reaper.ImGui_SameLine(ctx, dots and V5.PLAN_GUTTER or 0)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                                LBL[r.state] or C.text)
    reaper.ImGui_Text(ctx, (dots and '' or (MARK[r.state] or '')) .. r.label)
    reaper.ImGui_PopStyleColor(ctx)
    -- The tip belongs on the step it explains.
    if r.tip and reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx)
       and reaper.ImGui_SetTooltip then
      reaper.ImGui_SetTooltip(ctx, V5.wrap(r.label .. ' — ' .. r.tip ..
        (r.state == 'skip' and '\n\nSkipped in this run.' or '')))
    end

    -- The value it will use, in its own column. Ellipsized rather than wrapped:
    -- a long model id that wrapped would make the row height depend on the
    -- length of a string, and the dots are placed one per row.
    reaper.ImGui_SameLine(ctx, (dots and V5.PLAN_GUTTER or 0) + vcol)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                                r.state == 'current' and C.warn or C.dimmer)
    local avail = reaper.ImGui_GetContentRegionAvail(ctx)
    -- Always ellipsized. The old guard fell through to the RAW detail whenever
    -- the column was under 40 px — which is exactly when the detail could not
    -- possibly fit, so a narrow run column drew 'gemini-2.5-pro-preview-06-05'
    -- straight out of the panel.
    reaper.ImGui_Text(ctx, V5.ellipsize(ctx, r.detail,
                                        type(avail) == 'number' and avail or 80))
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_PopStyleVar(ctx)

  -- The gutter, drawn last: connectors first so the nodes sit on top of them,
  -- and both after the text, because the gutter is the one strip no text goes
  -- in. A leg is only "done" when the step it leaves has actually finished.
  if dots then
    for i = 1, #pts - 1 do
      local a, b = pts[i], pts[i + 1]
      local past = (a.state == 'done' or a.state == 'skip')
      lin(dl, a.x, a.y + 6, b.x, b.y - 6,
          past and C.step_ok or C.line, past and 1.6 or 1.0)
    end
    for _, p in ipairs(pts) do
      -- A halo rather than a bigger dot: the list keeps one rhythm, and the live
      -- step still reads first from across the room.
      if p.state == 'current' then
        fil(dl, p.x, p.y, 8, (C.accent_hi & 0xFFFFFF00) | 0x38, 16)
      end
      if FILL[p.state] then
        fil(dl, p.x, p.y, 4.5, FILL[p.state], 16)
      else
        rng(dl, p.x, p.y, 4.5, C.line, 16, 1.3)
      end
    end
  end
end

-- The column's middle: what this run will do, what it will read, and — before
-- it starts — whether it can. Present in setup AND while running, in the same
-- width, which is what lets the running phase keep the form on screen instead
-- of redrawing it read-only underneath a progress bar.
function V5.ui_dub_context(ctx, running)
  V5.cap(ctx, running and 'THIS RUN' or 'WHAT WILL HAPPEN')
  V5.run_plan(ctx)

  reaper.ImGui_Dummy(ctx, 0, 6)
  V5.cap(ctx, 'SOURCE')
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBC4CEFF)
  reaper.ImGui_TextWrapped(ctx, (LAST_AUDIO or '') ~= ''
    and basename(LAST_AUDIO) or 'nothing chosen yet')
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dimmer)
  -- Wrapped, not Text: 'Malayalam  ·  AI translation' is 170 px and the run
  -- column is 288 px at its widest and narrower whenever the window is.
  reaper.ImGui_TextWrapped(ctx, (LANGUAGE or '?') .. '  ·  ' ..
    (SCRIPT_MODE == 'have' and 'your script' or 'AI translation'))
  reaper.ImGui_PopStyleColor(ctx)

  if running then
    -- The engine's own voice, the last few lines of it. The full log is one
    -- click away in the rail; what belongs here is enough to see it moving.
    reaper.ImGui_Dummy(ctx, 0, 6)
    V5.cap(ctx, 'ENGINE  ·  LAST LINES')
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
    if #_log_buffer == 0 then
      reaper.ImGui_TextWrapped(ctx, 'waiting for the engine…')
    end
    for i = math.max(1, #_log_buffer - 3), #_log_buffer do
      reaper.ImGui_TextWrapped(ctx, _log_buffer[i])
    end
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Dummy(ctx, 0, 6)
    _grey_hint(ctx, 'Closing this window does not stop the engine — reopen ' ..
                    'the panel and the run reattaches. The form is locked ' ..
                    'until it finishes.')
  else
    reaper.ImGui_Dummy(ctx, 0, 6)
    V5.cap(ctx, 'READY')
    V5.readiness_rows(ctx)
  end
end

-- The whole column: head, the middle above, and the two secondary actions
-- pinned to the bottom edge. *elapsed* nil = setup, a number = a run is out.
function V5.ui_dub_column(ctx, on_start, on_cancel, elapsed)
  local running = elapsed ~= nil

  if running then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.info)
    reaper.ImGui_Text(ctx, _spinner_glyph() .. '  Running…')
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
    reaper.ImGui_Text(ctx, string.format('%02d:%02d',
      math.floor(elapsed / 60), elapsed % 60))
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_Dummy(ctx, 0, 2)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PlotHistogram(), 0x3388FFFF)
    reaper.ImGui_ProgressBar(ctx, _ui_progress, -1, 16,
      string.format('%.0f%%', _ui_progress * 100))
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn)
    reaper.ImGui_TextWrapped(ctx, _stage_line())
    reaper.ImGui_PopStyleColor(ctx)
  else
    local missing = {}
    if (LAST_AUDIO or '') == '' then
      missing[#missing + 1] = 'English audio file'
    end
    -- v0.21: V5.busy() covers the quiet voice fetch. It leaves the panel on
    -- this screen (that is the point of it), and both would write the same
    -- status/ files.
    local disabled = (#missing > 0) or V5.busy()

    _ui_begin_disabled(ctx, disabled)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        V5.COL.go)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), V5.COL.go_hi)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  V5.COL.go_act)
    if reaper.ImGui_Button(ctx, '▶  Run pipeline', -1, 34) then on_start() end
    reaper.ImGui_PopStyleColor(ctx, 3)
    _ui_end_disabled(ctx)

    -- v0.27: what it will cost, split into the two stages that spend and the
    -- headroom between the estimate and what a run of this length usually
    -- lands on. A single number under the button said how much without saying
    -- what for — and the TTS share is the only part a shorter script changes.
    V5.cost_meter(ctx)

    -- The sentence the pinned footer used to carry, in the order you need it:
    -- what stops the run, then what will fail during it, then what the button
    -- above will actually do.
    local note, note_col
    if #missing > 0 then
      note     = 'Missing: ' .. table.concat(missing, ', ')
      note_col = V5.COL.warn_text
    elseif V5.quiet_job then
      note     = 'Fetching the ElevenLabs voices — one moment.'
      note_col = V5.COL.warn_text
    else
      local why = (SCRIPT_MODE ~= 'have') and V5.llm_creds_error() or nil
      if why then
        note     = 'The Translate step has no usable LLM yet: ' .. why ..
                   '  Fix it in Settings → Connections.'
        note_col = V5.COL.warn
      elseif (EL_KEY or '') == '' then
        note     = 'No ElevenLabs key — Transcribe and TTS will both fail. ' ..
                   'Add one in Settings → Connections.'
        note_col = V5.COL.warn
      elseif FULL_RUN then
        note     = 'Runs straight through — the dub is imported when it ' ..
                   'finishes, with no pause to check the wording.'
        note_col = V5.COL.hint
      else
        note     = 'Pauses before TTS so you can check the wording. Nothing ' ..
                   'is charged until you approve it.'
        note_col = V5.COL.hint
      end
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), note_col)
    reaper.ImGui_TextWrapped(ctx, note)
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_Dummy(ctx, 0, 2)
  reaper.ImGui_Separator(ctx)

  -- The plan scrolls if it must; the two buttons below it never do. The bottom
  -- row's height is MEASURED on the previous frame rather than counted by hand
  -- (V5.mh) — a hand-counted reserve goes wrong the moment a style var or the
  -- UI face changes, and going wrong here means a scrollbar inside the column.
  local bot_h = V5.mh_get('dubcolbot', 40)
  if reaper.ImGui_BeginChild(ctx, '##dubcolmid', -1, -bot_h) then
    V5.ui_dub_context(ctx, running)
    reaper.ImGui_EndChild(ctx)
  end

  local by0 = V5.y(ctx)
  reaper.ImGui_Separator(ctx)
  -- Both bottom rows are "one wide button, one 62 px button". Sized from the
  -- measured width rather than as -68, because a column dragged narrower than
  -- 68 px would turn that into a NEGATIVE width, and ImGui does not treat a
  -- negative computed size as "as small as possible".
  local bot_w = reaper.ImGui_GetContentRegionAvail(ctx)
  if type(bot_w) ~= 'number' or bot_w < 140 then bot_w = 140 end
  -- 70, not 68: the small button is 62 wide and ItemSpacing.x is 8, so 68 left
  -- the pair two pixels wider than the column and the column grew a scrollbar.
  local wide_w = bot_w - 70

  if running then
    if reaper.ImGui_Button(ctx, '≡  Open log', wide_w, 26) then V5.go('log') end
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x883333FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xAA4444FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x661111FF)
    if reaper.ImGui_Button(ctx, 'Cancel', 62, 26) then cancel_engine() end
    reaper.ImGui_PopStyleColor(ctx, 3)
  else
    -- v0.13 pause-aware preview: chunk the SOURCE by its own pauses, lay the
    -- target script across them and report the fit — before any credit is
    -- spent. Needs a pasted script, so it is offered only in the mode where
    -- that text exists.
    local blocked = ((LAST_AUDIO or '') == '') or V5.busy()
    _ui_begin_disabled(ctx, blocked or SCRIPT_MODE ~= 'have')
    if reaper.ImGui_Button(ctx, '🔍  Preview sync', wide_w, 26) then
      V5.start_plan_run(nil)
    end
    _ui_end_disabled(ctx)
    -- The hover test comes after _ui_end_disabled on purpose — a disabled item
    -- reports no hover, and this tooltip exists precisely for the disabled case.
    if reaper.ImGui_IsItemHovered
       and reaper.ImGui_IsItemHovered(ctx,
             reaper.ImGui_HoveredFlags_AllowWhenDisabled
             and reaper.ImGui_HoveredFlags_AllowWhenDisabled() or 0)
       and reaper.ImGui_SetTooltip then
      reaper.ImGui_SetTooltip(ctx, V5.wrap(
        SCRIPT_MODE ~= 'have'
        and 'Needs the target script: set Script to "I have a script" and ' ..
            'paste it. It then cuts the source at its own pauses and shows ' ..
            'where the dub would drift — free, no audio generated.'
        or  'Lays the pasted script across the source\'s own pauses and ' ..
            'reports the fit, before any credit is spent.'))
    end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, 'Close', 62, 26) then on_cancel() end
  end
  V5.measured(ctx, 'dubcolbot', by0)
end

-- The Settings SCREEN: pane strip across the top (the old 132 px sidebar cost
-- more width than the widest control inside it), the pane itself and the
-- readiness card side by side, one Save in the action bar.
function V5.ui_settings_screen(ctx)
  local locked = (_ui_phase ~= "setup")
  if locked then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn)
    reaper.ImGui_TextWrapped(ctx,
      'Locked while a run is active — settings are read at launch time. ' ..
      'Finish or cancel the run to edit them.')
    reaper.ImGui_PopStyleColor(ctx)
  end
  _ui_render_banner(ctx)
  _ui_begin_disabled(ctx, locked)

  for i, pane in ipairs(V5.PANES) do
    if i > 1 then reaper.ImGui_SameLine(ctx, 0, 4) end
    local on = (V5.settings_pane == pane[1])
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
                               on and V5.COL.accent or 0x24282FFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),
                               on and V5.COL.accent_hi or 0x333A44FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), V5.COL.accent_act)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                               on and V5.COL.bright or V5.COL.text2)
    if reaper.ImGui_Button(ctx, pane[2] .. '##pane' .. pane[1]) then
      V5.settings_pane = pane[1]
      save_settings()
    end
    reaper.ImGui_PopStyleColor(ctx, 4)
  end
  reaper.ImGui_Dummy(ctx, 0, 2)

  -- 40 = the pinned Save row (24 px button + separator + two gutters).
  local body_h = -40
  -- v0.26: the readiness card gives width back rather than squeezing the pane
  -- to nothing. A flat -(CTX_W + 8) reserve left the pane 168 px at a 480 px
  -- window — narrower than a single 'Re-check every key' button — and below
  -- CTX_W it would have handed BeginChild a negative width, which fills to the
  -- window edge and draws the pane straight through the card. Same guard the
  -- Dub screen's run column has had since v0.25.
  local savail = reaper.ImGui_GetContentRegionAvail(ctx)
  if type(savail) ~= 'number' or savail <= 0 then savail = 900 end
  local card_w = math.min(V5.CTX_W, math.max(0, savail - 360))
  if reaper.ImGui_BeginChild(ctx, '##pane_body',
                             card_w > 0 and -(card_w + 8) or -1, body_h,
                             _child_border_flag()) then
    local drawn = false
    for _, pane in ipairs(V5.PANES) do
      if V5.settings_pane == pane[1] then pane[3](ctx); drawn = true end
    end
    if not drawn then V5.pane_connection(ctx) end
    reaper.ImGui_EndChild(ctx)
  end

  -- Below the threshold there is no room for the card at all; the readiness
  -- list is also on the Dub screen, so dropping it here loses nothing.
  if card_w > 0 then
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_BeginChild(ctx, '##readycard', -1, body_h,
                               _child_border_flag()) then
      V5.ui_readiness(ctx)
      reaper.ImGui_EndChild(ctx)
    end
  end

  reaper.ImGui_Separator(ctx)
  if reaper.ImGui_Button(ctx, 'Save settings', 140, 24) then
    V5.do_save_settings()
  end
  reaper.ImGui_SameLine(ctx)
  _grey_hint(ctx, 'Also saved automatically before every run.')
  _ui_end_disabled(ctx)
end

-- The settings window itself: sidebar left, one pane right, one Save for the
-- whole window at the bottom. Locked while a run is active — the engine reads
-- config/*.json at launch time, so editing mid-run would be a lie.
-- v0.16: superseded by V5.ui_settings_screen (a rail destination). Kept because
-- V5.settings_open is still honoured, and older ReaImGui builds are happier
-- with a plain window than with nested children.
function V5.ui_settings_body(ctx)
  local locked = (_ui_phase ~= "setup")
  if locked then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn)
    reaper.ImGui_TextWrapped(ctx,
      'Locked while a run is active — settings are read at launch time. ' ..
      'Finish or cancel the run to edit them.')
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Dummy(ctx, 0, 4)
  end

  _ui_render_banner(ctx)
  _ui_begin_disabled(ctx, locked)

  -- Sidebar. A child window so the pane beside it can scroll on its own.
  if reaper.ImGui_BeginChild(ctx, '##panes', 132, -38) then
    for _, pane in ipairs(V5.PANES) do
      local on = (V5.settings_pane == pane[1])
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
                                 on and V5.COL.accent or 0x00000000)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),
                                 on and V5.COL.accent_hi or V5.COL.hdr_hi)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),
                                 V5.COL.accent_act)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                                 on and V5.COL.bright or V5.COL.text2)
      if reaper.ImGui_Button(ctx, pane[2] .. '##pane' .. pane[1], -1, 24) then
        V5.settings_pane = pane[1]
        save_settings()
      end
      reaper.ImGui_PopStyleColor(ctx, 4)
    end
    reaper.ImGui_EndChild(ctx)
  end

  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_BeginChild(ctx, '##pane_body', -1, -38) then
    local drawn = false
    for _, pane in ipairs(V5.PANES) do
      if V5.settings_pane == pane[1] then pane[3](ctx); drawn = true end
    end
    if not drawn then V5.pane_connection(ctx) end
    reaper.ImGui_EndChild(ctx)
  end

  -- One Save for the window. Every pane writes to the same two config files,
  -- so a per-section button was only ever a chance to forget one.
  reaper.ImGui_Separator(ctx)
  if reaper.ImGui_Button(ctx, 'Save settings', 140, 26) then
    V5.do_save_settings()
  end
  reaper.ImGui_SameLine(ctx)
  _grey_hint(ctx, 'Also saved automatically before every run.')
  _ui_end_disabled(ctx)
end

-- Its own top-level window, so it can be moved, resized and closed without
-- disturbing the work surface behind it.
function V5.ui_settings_window(ctx)
  if not V5.settings_open then return end
  reaper.ImGui_SetNextWindowSize(ctx, 620, 470,
                                 reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx, 'Settings###dub_settings', true)
  if visible then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 6.0, 6.0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 3.0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 8.0, 4.0)
    -- v0.22: its own push — this is a sibling top-level window, drawn after
    -- the main one has already closed its Begin/End pair and popped the face.
    local sf = V5.push_ui_font(ctx)
    V5.ui_settings_body(ctx)
    V5.pop_ui_font(ctx, sf)
    reaper.ImGui_PopStyleVar(ctx, 3)
    -- ReaImGui calls End() ONLY when Begin() returned true — unlike upstream
    -- Dear ImGui, whose docs say to always pair them. cfillion's own
    -- examples/demo.lua early-outs on `if not rv then return end` without
    -- ending. Calling it anyway raises
    --   ImGui_End: Calling End() too many times!
    --
    -- Begin() reports not-visible more often than "collapsed" suggests. The
    -- case that actually reached users: dragging this window onto the main
    -- one DOCKS the two as tabs in one node, and the unselected tab is not
    -- visible. A field machine's ReaImGui ini showed exactly that —
    -- ###dub_pipeline DockId=0x1,0 and ###dub_settings DockId=0x1,1, with
    -- Collapsed=0 on both. The layout persists in
    -- <REAPER resource>/ReaImGui/AEEFD7DC.ini, so the error returned at
    -- every launch until that file was reset.
    reaper.ImGui_End(ctx)
  end
  V5.settings_open = open and true or false
end

-- ── v0.20 window chrome ─────────────────────────────────────
-- Dear ImGui's title bar offers exactly one control — a ✕ the size of a glyph
-- — and no way to add a second. So the window is opened with NoTitleBar and
-- this row takes its place: title on the left, minimise / maximise / close on
-- the right at Explorer's 46 x 32 each. The empty span between the two is
-- still the grab handle: Dear ImGui moves a window from any point that is not
-- an item, and it skips the "from the title bar only" restriction entirely for
-- a NoTitleBar window, so no drag code is needed here.
--
-- What the three buttons do:
--   minimise   rolls the panel up to this bar, and back down on the next
--              press. Deliberately NOT a taskbar minimise: a ReaImGui window
--              is owned by REAPER's main window, so SW_MINIMIZE would hide it
--              with no taskbar button to bring it back. A run in progress
--              keeps polling while the panel is up.
--   maximise   fills the work area of the monitor the panel is on; the second
--              press puts the previous rectangle back.
--   close      what the ✕ did.
-- Every size change is QUEUED into V5.win.pending rather than applied where
-- the button is: SetNextWindowSize only counts BEFORE Begin, and this row is
-- drawn a long way inside it.
V5.TITLEBAR_H = 32          -- band height, and one caption button's height
V5.CAPTION_W  = 46          -- Explorer's caption button width

V5.win = {
  mode    = 'normal',   -- 'normal' | 'max'
  rolled  = false,      -- rolled up to the title bar
  cur     = nil,        -- {x,y,w,h} measured this frame
  restore = nil,        -- rectangle to put back when un-maximising
  full_h  = nil,        -- height to put back when un-rolling
  pending = nil,        -- {x,y,w,h} to apply before the next Begin
}

-- Every call the custom chrome needs, checked ONCE. A ReaImGui too old for any
-- one of them keeps the stock title bar rather than losing its close button —
-- the panel is installed on machines nobody here updates.
function V5.chrome_ok()
  if V5.chrome == nil then
    V5.chrome = (reaper.ImGui_WindowFlags_NoTitleBar
      and reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddLine
      and reaper.ImGui_InvisibleButton and reaper.ImGui_IsItemHovered
      and reaper.ImGui_GetCursorScreenPos and reaper.ImGui_SetCursorScreenPos
      and reaper.ImGui_GetWindowPos and reaper.ImGui_GetWindowSize
      and reaper.ImGui_SetNextWindowPos and reaper.ImGui_SetNextWindowSize
      and reaper.ImGui_CalcTextSize) and true or false
  end
  return V5.chrome
end

-- The work area of the monitor this rectangle is on — the same call the
-- off-screen rescue uses, so "maximised" means what Windows means by it and
-- the taskbar keeps its strip.
function V5.work_area(x, y, w, h)
  if not reaper.my_getViewport then return nil end
  local ok, l, t, r, b = pcall(reaper.my_getViewport,
                               x, y, x + w, y + h,
                               x, y, x + w, y + h, true)
  if not ok or type(l) ~= 'number' or type(b) ~= 'number' then return nil end
  if (r - l) < 320 or (b - t) < 240 then return nil end
  return l, t, r, b
end

-- One caption button. The glyphs are DRAWN, not typed: the built-in ImGui font
-- has no ▢ and the Indic font this panel swaps in mid-frame is no safer, so a
-- typed one would land as a hollow box on exactly the machines that matter.
-- Four lines make a square; two make the ✕.
function V5.caption_button(ctx, id, kind, tip)
  local W, H = V5.CAPTION_W, V5.TITLEBAR_H
  local dl   = reaper.ImGui_GetWindowDrawList(ctx)
  local ln   = reaper.ImGui_DrawList_AddLine
  local fill = reaper.ImGui_DrawList_AddRectFilled

  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local hit  = reaper.ImGui_InvisibleButton(ctx, '##cap' .. id, W, H)
  local hot  = reaper.ImGui_IsItemHovered(ctx)
  local down = reaper.ImGui_IsItemActive and reaper.ImGui_IsItemActive(ctx)
  if hot and tip and reaper.ImGui_SetTooltip then
    reaper.ImGui_SetTooltip(ctx, V5.wrap(tip))
  end

  -- Drawn after the button, over the band that was added to this same draw
  -- list a moment ago. Close goes Windows red; the other two go one step
  -- lighter than the band.
  if fill and hot then
    local bg
    if kind == 'close' then bg = down and 0x8E1A0FFF or 0xC42B1CFF
    else                    bg = down and 0x363C44FF or 0x2A2F35FF end
    fill(dl, x, y, x + W, y + H, bg)
  end

  local col = (kind == 'close' and hot) and V5.COL.bright
              or (hot and 0xE6EBF1FF or 0x8A93A0FF)
  -- Half-pixel centres: a 1 px line on a whole coordinate straddles two pixels
  -- and comes out grey and two wide.
  local cx = math.floor(x + W * 0.5) + 0.5
  local cy = math.floor(y + H * 0.5) + 0.5
  local t, r = 1.0, 5
  local function box(x0, y0, x1, y1)
    ln(dl, x0, y0, x1, y0, col, t)
    ln(dl, x1, y0, x1, y1, col, t)
    ln(dl, x1, y1, x0, y1, col, t)
    ln(dl, x0, y1, x0, y0, col, t)
  end

  if kind == 'minimise' then
    ln(dl, cx - r, cy, cx + r, cy, col, t)
  elseif kind == 'unroll' then
    -- Rolled up: the same bar with a chevron under it, so the button reads as
    -- "bring it back down" instead of "minimise again".
    ln(dl, cx - r, cy - 4, cx + r, cy - 4, col, t)
    ln(dl, cx - 4, cy,     cx,     cy + 4, col, t)
    ln(dl, cx,     cy + 4, cx + 4, cy,     col, t)
  elseif kind == 'maximise' then
    box(cx - r, cy - r, cx + r, cy + r)
  elseif kind == 'restore' then
    box(cx - r, cy - 2, cx + 2, cy + r)              -- the front square
    ln(dl, cx - 2, cy - r, cx + r, cy - r, col, t)   -- the one behind it: top
    ln(dl, cx + r, cy - r, cx + r, cy + 2, col, t)   --                    right
  elseif kind == 'close' then
    ln(dl, cx - r, cy - r, cx + r, cy + r, col, t)
    ln(dl, cx - r, cy + r, cx + r, cy - r, col, t)
  end
  return hit
end

function V5.win_roll(up)
  local c = V5.win.cur
  if up then
    if c then V5.win.full_h = c.h end
    V5.win.rolled = true
  else
    V5.win.rolled = false
    if c and V5.win.full_h then
      V5.win.pending = { w = c.w, h = V5.win.full_h }
    end
  end
end

function V5.win_maximise(on)
  local c = V5.win.cur
  if not c then return end
  -- Maximising while rolled up drops the panel down first: a full-width strip
  -- is not a state anyone asks for.
  V5.win.rolled = false
  if on then
    local h = V5.win.full_h or c.h
    V5.win.restore = { x = c.x, y = c.y, w = c.w, h = h }
    local l, t, r, b = V5.work_area(c.x, c.y, c.w, h)
    if not l then
      -- No usable monitor answer — leave the window where it is rather than
      -- flinging it somewhere it cannot be grabbed back from.
      V5.win.pending = { w = c.w, h = h }
      return
    end
    V5.win.pending = { x = l, y = t, w = r - l, h = b - t }
    V5.win.mode = 'max'
  else
    local rc = V5.win.restore or { x = c.x, y = c.y, w = 900, h = 600 }
    V5.win.pending = { x = rc.x, y = rc.y, w = rc.w, h = rc.h }
    V5.win.mode = 'normal'
  end
end

-- Called immediately before Begin — the only place SetNextWindow* is heard.
function V5.win_apply(ctx)
  local p = V5.win.pending
  if p then
    if p.x then reaper.ImGui_SetNextWindowPos(ctx, p.x, p.y) end
    if p.w then reaper.ImGui_SetNextWindowSize(ctx, p.w, p.h) end
    V5.win.pending = nil
    return
  end
  -- Rolled up: pin the HEIGHT every frame and leave the width alone, so the
  -- panel can still be widened while it is up.
  if V5.win.rolled and V5.win.cur then
    reaper.ImGui_SetNextWindowSize(ctx, V5.win.cur.w, V5.TITLEBAR_H)
  end
end

function V5.ui_titlebar(ctx, on_close)
  local H       = V5.TITLEBAR_H
  local wx, wy  = reaper.ImGui_GetWindowPos(ctx)
  local ww, wh  = reaper.ImGui_GetWindowSize(ctx)
  -- The rectangle the two size buttons work from. While the panel is rolled
  -- up the real height is 32 and meaningless, so the remembered one stands in.
  V5.win.cur = { x = wx, y = wy, w = ww,
                 h = V5.win.rolled and (V5.win.full_h or wh) or wh }

  local dl   = reaper.ImGui_GetWindowDrawList(ctx)
  local ln   = reaper.ImGui_DrawList_AddLine
  local fill = reaper.ImGui_DrawList_AddRectFilled
  if fill then fill(dl, wx, wy, wx + ww, wy + H, 0x101214FF) end
  ln(dl, wx, wy + H - 0.5, wx + ww, wy + H - 0.5, 0x282C31FF, 1)

  local _, th = reaper.ImGui_CalcTextSize(ctx, 'Ag')
  if type(th) ~= 'number' or th <= 0 then th = 14 end
  reaper.ImGui_SetCursorScreenPos(ctx, wx + 12, wy + (H - th) * 0.5)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8A93A0FF)
  reaper.ImGui_Text(ctx, 'Dub Pipeline'
    .. (V5.APP_VERSION ~= '' and ('   v' .. V5.APP_VERSION) or ''))
  reaper.ImGui_PopStyleColor(ctx)

  local W    = V5.CAPTION_W

  -- Three buttons flush to the right edge, no gap between them — the cursor is
  -- placed for each one rather than walked with SameLine, because ItemSpacing
  -- would open 6 px seams Explorer does not have.
  local bx   = wx + ww - W * 3
  local up   = V5.win.rolled
  local maxd = (V5.win.mode == 'max')

  reaper.ImGui_SetCursorScreenPos(ctx, bx, wy)
  if V5.caption_button(ctx, 'min', up and 'unroll' or 'minimise',
        up and 'Roll the panel back down.'
            or 'Roll the panel up to this bar. A run that is going keeps '
            .. 'going while it is up.') then
    V5.win_roll(not up)
  end

  reaper.ImGui_SetCursorScreenPos(ctx, bx + W, wy)
  if V5.caption_button(ctx, 'max', maxd and 'restore' or 'maximise',
        maxd and 'Put the previous size back.'
              or 'Fill this monitor.') then
    V5.win_maximise(not maxd)
  end

  reaper.ImGui_SetCursorScreenPos(ctx, bx + W * 2, wy)
  if V5.caption_button(ctx, 'close', 'close', 'Close the panel.') then
    on_close()
  end

  -- Hand the rest of the frame a cursor at the top-left of the content area:
  -- window padding in from the left, and clear of the band. Everything below
  -- sizes itself with -1, which is measured from here.
  --
  -- The Dummy is not decoration. ImGui asserts inside End() — "Code uses
  -- SetCursorPos()/SetCursorScreenPos() to extend window/parent boundaries.
  -- Please submit an item e.g. Dummy() afterwards" — whenever a window ends
  -- with the cursor moved past everything that was drawn and no item after it
  -- to grow the boundary. Normally the rail's BeginChild is that item; in the
  -- ROLLED frame nothing follows the title bar at all, so the panel threw the
  -- moment minimise was pressed. Dummy(0, 0) submits the item, and its
  -- ItemSpacing.y is the same 6 px of air that used to be added by hand.
  if V5.win.rolled then
    -- Rolled up the window IS the band: putting the cursor below it would push
    -- the content past a 32 px window, which is the very thing being asserted
    -- about, and would hand the strip a scrollbar besides.
    reaper.ImGui_SetCursorScreenPos(ctx, wx + 8, wy + 4)
  else
    reaper.ImGui_SetCursorScreenPos(ctx, wx + 8, wy + H)
  end
  reaper.ImGui_Dummy(ctx, 0, 0)
end

-- ── Header and status bar ───────────────────────────────────
-- One readiness light for the whole app, instead of each tab working it out
-- again when you press Start.
-- v0.16: the rail carries identity and the gear, so this is one row of state —
-- the readiness light, and (when the dub side is waiting while you are looking
-- at another screen) a way back to it.
function V5.ui_header(ctx)
  local why = V5.llm_creds_error()
  local no_voice_key = (EL_KEY or '') == ''
  if why or no_voice_key then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn_text)
    reaper.ImGui_Text(ctx, '●  needs setup')
    reaper.ImGui_PopStyleColor(ctx)
    V5.hint(ctx, why or 'No ElevenLabs key yet — transcription and every ' ..
                        'voice stage need one. Add it in Settings → ' ..
                        'Connections.')
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.ok)
    reaper.ImGui_Text(ctx, '●  keys ready')
    reaper.ImGui_PopStyleColor(ctx)
  end

  -- A run that finished, failed or is waiting for a decision must be visible
  -- from every screen — previously only the Dub tab knew.
  if V5.nav ~= 'dub' then
    local note
    if     _ui_phase == 'running' then note = 'a run is in progress'
    elseif _ui_phase == 'review'  then note = 'waiting for your translation check'
    elseif _ui_phase == 'plan'    then note = 'a fit preview is waiting'
    elseif _ui_phase == 'success' then note = 'a run finished — import it'
    elseif _ui_phase == 'failure' then note = 'a run failed'
    end
    if note then
      reaper.ImGui_SameLine(ctx, 0, 14)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.warn)
      reaper.ImGui_Text(ctx, '·  ' .. note)
      reaper.ImGui_PopStyleColor(ctx)
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_SmallButton(ctx, 'Go to Dub##gotodub') then V5.go('dub') end
    end
  end
end

-- v0.24: the run-configuration footer is gone. It repeated, on every screen,
-- what the Dub screen's context column already spells out — and it cost every
-- body 26 px of height to say it.


-- ─── Running phase ────────────────────────────────────────
-- v0.25: there is no running SCREEN any more. A run is drawn by the Dub screen
-- itself (ui_phase_setup with an elapsed time), which keeps the form on the left
-- and turns the run column's head into the progress bar — see V5.ui_dub_column.
-- What went with it: the granular MODE_STAGES checklist of every [Sxx] the
-- engine walks through. It never fitted the column, it repeated what the plan
-- list says at the altitude you actually watch, and the same lines are in the
-- Log tab, which the column links to.
-- ─── Success phase ────────────────────────────────────────
local function ui_phase_success(ctx, on_close)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.done)
  reaper.ImGui_Text(ctx, '✓  Pipeline finished')
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 6)
  _ui_render_banner(ctx)   -- regen runs report their outcome here

  if _manifest then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xDDDDDDFF)
    reaper.ImGui_Text(ctx, 'Language : ' .. (_manifest.language ~= '' and _manifest.language or LANGUAGE))
    reaper.ImGui_Text(ctx, 'Output   : ' .. (_manifest.out_dir or ''))
    reaper.ImGui_PopStyleColor(ctx)
    -- v0.7 match mode reports its chunk split up front.
    if (_manifest.synced_count or '') ~= '' then
      local n_un = tonumber(_manifest.unsynced_count or '') or 0
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
                                  n_un > 0 and 0xEEBB44FF or V5.COL.done)
      reaper.ImGui_Text(ctx, ('Chunks   : %s synced, %s unsynced%s'):format(
        _manifest.synced_count, _manifest.unsynced_count or '0',
        n_un > 0 and '  (unsynced go to the "Un sync" track on import)' or ''))
      reaper.ImGui_PopStyleColor(ctx)
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
    local have = {}
    if (_manifest.en_audio or '') ~= ''       then have[#have + 1] = 'EN audio' end
    if (_manifest.tts_wav or '') ~= ''        then have[#have + 1] = 'TTS wav' end
    if (_manifest.timestamps_txt or '') ~= '' then have[#have + 1] = 'timestamps' end
    if (_manifest.synced_wav or '') ~= ''     then have[#have + 1] = 'synced wav' end
    if (_manifest.synced_srt or '') ~= ''     then have[#have + 1] = 'synced SRT' end
    reaper.ImGui_TextWrapped(ctx, 'Produced: ' ..
      (#have > 0 and table.concat(have, ', ') or '(nothing?)'))
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_Dummy(ctx, 0, 8)
  local can_import = (_manifest ~= nil) and not _imported
  _ui_begin_disabled(ctx, not can_import)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        V5.COL.go)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), V5.COL.go_hi)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  V5.COL.go_act)
  if reaper.ImGui_Button(ctx, _imported and 'Imported ✓' or 'Import to timeline',
                         200, 36) and can_import then
    -- v0.5: the user may have switched REAPER project tabs mid-run — put
    -- the import into the project the run was launched from, if it is
    -- still open. (Import inserts into the ACTIVE project.)
    if V5.run_project and reaper.ValidatePtr(V5.run_project, "ReaProject*")
       and V5.run_project ~= reaper.EnumProjects(-1, "") then
      reaper.SelectProjectInstance(V5.run_project)
    end
    _import_summary = import_to_timeline(_manifest)
    _imported = true
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  _ui_end_disabled(ctx)

  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Open output folder', 160, 36) then
    if _manifest and (_manifest.out_dir or '') ~= '' then
      open_path(_manifest.out_dir)
    end
  end

  if _import_summary then
    reaper.ImGui_Dummy(ctx, 0, 6)
    if reaper.ImGui_BeginChild(ctx, '##impsum', -1, 170, _child_border_flag()) then
      local pushed = _push_font(ctx, 16)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xCCDDCCFF)
      reaper.ImGui_TextWrapped(ctx, _import_summary)
      reaper.ImGui_PopStyleColor(ctx)
      if pushed then _pop_font(ctx) end
      reaper.ImGui_EndChild(ctx)
    end
  end

  -- v0.5: post-import fixups live in their own tabs now.
  reaper.ImGui_Dummy(ctx, 0, 8)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.dim)
  reaper.ImGui_TextWrapped(ctx,
    'Fix a single line: "Regen Audio" tab (select the chunk item first). ' ..
    'Re-voice a whole track: "Track Voice" tab.')
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_Dummy(ctx, 0, 10)
  reaper.ImGui_Separator(ctx)
  if reaper.ImGui_Button(ctx, 'Close', 120, 32) then on_close() end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Run again', 120, 32) then
    _ui_phase = 'setup'; _log_buffer = {}
    _ui_stage_tag = nil; _ui_progress = 0.0
    _manifest = nil; _import_summary = nil; _imported = false
    _ui_cancelled = false; _cancel_pending = false
  end
end

-- ─── Failure phase ────────────────────────────────────────
local function ui_phase_failure(ctx, on_close)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), V5.COL.err)
  reaper.ImGui_Text(ctx, '✗  Pipeline failed')
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 6)

  if _ui_failure then
    reaper.ImGui_Text(ctx, 'Error:')
    if reaper.ImGui_BeginChild(ctx, '##errtail', -1, 240, _child_border_flag()) then
      -- This is the log's tail, so it gets the Log tab's terminal type —
      -- unless the tail carries non-Latin text, which the mono font has no
      -- glyphs for and would draw as a wall of boxes.
      local tail = _ui_failure.error_tail or '(no output)'
      local mono = (not tail:find("[\128-\255]")) and V5.mono_font(ctx) or nil
      local pushed = mono and pcall(reaper.ImGui_PushFont, ctx, mono, V5.LOG_PX)
      if mono and not pushed then
        pushed = pcall(reaper.ImGui_PushFont, ctx, mono)
      end
      local pushed_ui = (not pushed) and _push_font(ctx, V5.LOG_PX + 1)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFAAAAFF)
      reaper.ImGui_TextWrapped(ctx, tail)
      reaper.ImGui_PopStyleColor(ctx)
      if pushed or pushed_ui then _pop_font(ctx) end
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_Dummy(ctx, 0, 4)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xAAAAAAFF)
    reaper.ImGui_Text(ctx, 'Full log: ' .. (_ui_failure.log_path or ''))
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, 'Open') then
      if file_exists(LOG_PATH) then open_path(LOG_PATH) end
    end
  end

  -- Partial results may still exist (manifest with status=error).
  if _manifest and not _imported then
    reaper.ImGui_Dummy(ctx, 0, 6)
    if reaper.ImGui_Button(ctx, 'Import partial results anyway', 240, 30) then
      _import_summary = import_to_timeline(_manifest)
      _imported = true
    end
  end
  if _import_summary then
    reaper.ImGui_Dummy(ctx, 0, 4)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xCCDDCCFF)
    reaper.ImGui_TextWrapped(ctx, _import_summary)
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_Dummy(ctx, 0, 10)
  reaper.ImGui_Separator(ctx)
  if reaper.ImGui_Button(ctx, 'Close', 120, 32) then on_close() end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Back to setup', 140, 32) then
    _ui_phase = 'setup'; _ui_failure = nil
    _ui_stage_tag = nil; _ui_progress = 0.0
    _manifest = nil; _import_summary = nil; _imported = false
    _ui_cancelled = false; _cancel_pending = false
  end
end

-- ---------------------------------------------------------------------------
-- MAIN — single ReaImGui frame loop drives all phases
-- ---------------------------------------------------------------------------

local function main()
  if not imgui_available() then
    if reaper.APIExists and reaper.APIExists('ReaPack_AddSetRepository') then
      local choice = reaper.ShowMessageBox(
        "This script needs ReaImGui (free).\n\n" ..
        "ReaPack was detected. Install ReaImGui automatically?\n" ..
        "(This adds the repository and opens the package browser so you\n" ..
        "just click Install → Apply, then restart REAPER.)\n\n" ..
        "Yes  = do it automatically\n" ..
        "No   = show me the manual steps instead\n" ..
        "Cancel = quit",
        "ReaImGui not installed", 3)
      if choice == 6 then       -- Yes
        if try_reapack_install() then return end
      elseif choice == 2 then   -- Cancel
        return
      end
    else
      local choice = reaper.ShowMessageBox(
        "This script needs ReaImGui, which installs through ReaPack —\n" ..
        "and ReaPack is not installed yet either.\n\n" ..
        "Install ReaPack automatically now?\n" ..
        "(Downloads the official extension into REAPER's UserPlugins\n" ..
        "folder. Then: restart REAPER, run this script again, and it\n" ..
        "will offer to install ReaImGui for you.)\n\n" ..
        "Yes  = do it automatically\n" ..
        "No   = show me the manual steps instead\n" ..
        "Cancel = quit",
        "ReaImGui + ReaPack not installed", 3)
      if choice == 6 then       -- Yes
        if try_reapack_bootstrap() then
          reaper.ShowMessageBox(
            "ReaPack was installed.\n\n" ..
            "  1. Restart REAPER.\n" ..
            "  2. Run this script again — it will offer to install\n" ..
            "     ReaImGui automatically.",
            "Restart REAPER", 0)
        else
          reaper.ShowMessageBox(
            "Automatic download failed (offline, or an unusual REAPER\n" ..
            "build). Install ReaPack manually from https://reapack.com\n" ..
            "— opening that page now — then run this script again.",
            "Download failed", 0)
          open_url("https://reapack.com/user-guide#installation")
        end
        return
      elseif choice == 2 then   -- Cancel
        return
      end
    end

    -- Manual fallback, tailored to whether ReaPack is present.
    local has_reapack = reaper.APIExists and reaper.APIExists('ReaPack_AddSetRepository')
    if has_reapack then
      local choice = reaper.ShowMessageBox(
        "This script needs ReaImGui (free).\n\n" ..
        "Quickest install (REAPER must restart after):\n" ..
        "  1. Extensions - ReaPack - Import repositories...\n" ..
        "  2. Paste:\n" ..
        "     " .. REAIMGUI_REPO_URL .. "\n" ..
        "  3. Extensions - ReaPack - Browse packages - search\n" ..
        "     'ReaImGui' - right-click - Install - Apply.\n" ..
        "  4. Restart REAPER and run this script again.\n\n" ..
        "Open the ReaImGui homepage in your browser now?",
        "ReaImGui not installed", 4)
      if choice == 6 then
        open_url("https://github.com/cfillion/reaimgui#installation")
      end
    else
      local choice = reaper.ShowMessageBox(
        "This script needs ReaImGui, which installs through ReaPack —\n" ..
        "and neither is installed yet.\n\n" ..
        "Manual setup (REAPER must restart along the way):\n" ..
        "  1. Install ReaPack from https://reapack.com, then restart\n" ..
        "     REAPER.\n" ..
        "  2. Run this script again — it will offer to install ReaImGui\n" ..
        "     for you (or use ReaPack's Browse packages to add it).\n\n" ..
        "Open the ReaPack website now?",
        "ReaPack not installed", 4)
      if choice == 6 then
        open_url("https://reapack.com/")
      end
    end
    return
  end

  -- Engine venv missing? Kick off the automatic one-time setup before the
  -- window even appears (v0.6) — the panel stays fully usable meanwhile.
  V5.autorun_setup_if_needed()

  -- v0.16: one non-blocking version check per launch. The answer arrives a
  -- second or two into the session and lands in Settings → About; a newer
  -- version also raises the dialog once.
  V5.check_update()

  _ui_ctx = reaper.ImGui_CreateContext('Dub Pipeline')
  _ensure_lang_font(_ui_ctx)

  local function close_window() _ui_window_open = false end

  -- ReaImGui saves this window's position in its own .ini (ViewportPos in
  -- REAPER/ReaImGui/<hash>.ini). A position saved on a monitor that is no
  -- longer attached — or a negative cache like ViewportPos=-740,-660 — puts
  -- the panel completely off-screen: the action ticks, the script runs, and
  -- NOTHING appears, with no way back except editing that .ini by hand.
  -- Check the real position once per session and pull it back on screen only
  -- when it is unreachable, so anyone who moved the window keeps their spot.
  local _pos_checked = false
  local _pos_fix     = nil   -- {x, y} to apply before the NEXT Begin()

  local function check_offscreen(ctx)
    if _pos_checked then return end
    _pos_checked = true
    if not (reaper.ImGui_GetWindowPos and reaper.ImGui_SetNextWindowPos
            and reaper.my_getViewport) then return end
    local ok, x, y = pcall(reaper.ImGui_GetWindowPos, ctx)
    if not ok or type(x) ~= "number" or type(y) ~= "number" then return end
    local w, h = 760, 680
    if reaper.ImGui_GetWindowSize then
      local ok2, gw, gh = pcall(reaper.ImGui_GetWindowSize, ctx)
      if ok2 and type(gw) == "number" and gw > 0 then w, h = gw, gh end
    end
    -- Work area of the monitor nearest that rect — the primary monitor when
    -- the rect sits on no monitor at all, which is exactly the broken case.
    local okv, l, t, r, b = pcall(reaper.my_getViewport,
                                  x, y, x + w, y + h,
                                  x, y, x + w, y + h, true)
    if not okv or type(l) ~= "number" then return end
    -- Enough of the title bar has to be inside the work area to grab it.
    if x >= l - 8 and y >= t - 8 and x <= r - 80 and y <= b - 40 then return end
    _pos_fix = { l + 60, t + 60 }
    log_append(string.format(
      "[panel] Window was off-screen at %d,%d (monitor work area %d,%d..%d,%d)"
      .. " - moved it back on screen.", x, y, l, t, r, b))
  end

  local function frame()
    -- SetNextWindowPos has to precede Begin, so the rescue queued while the
    -- previous frame was inside Begin/End applies here.
    if _pos_fix then
      reaper.ImGui_SetNextWindowPos(_ui_ctx, _pos_fix[1], _pos_fix[2])
      _pos_fix = nil
    end
    -- v0.16: the console layout is 900 x 600 — a 138 px rail, the screen, and a
    -- 288 px context column. Applied ONCE per install (ui_gen), because
    -- FirstUseEver would leave everyone who has already run the panel at
    -- 760 x 680, where the three columns do not fit; after that one frame the
    -- size is the user's again.
    if (V5.ui_gen or 0) < 1 then
      reaper.ImGui_SetNextWindowSize(_ui_ctx, 900, 600)
      V5.ui_gen = 1
      save_settings()
    else
      reaper.ImGui_SetNextWindowSize(_ui_ctx, 900, 600,
                                     reaper.ImGui_Cond_FirstUseEver())
    end
    -- v0.20: whatever the caption buttons asked for, applied here — after the
    -- block above on purpose, so a maximise wins over the one-time sizing.
    V5.win_apply(_ui_ctx)

    -- v0.20: the title bar is ours (V5.ui_titlebar), so ImGui must not draw
    -- its own. NoCollapse stays for the builds that fall back to it.
    local wflags = reaper.ImGui_WindowFlags_NoCollapse()
    if V5.chrome_ok() then
      wflags = wflags | reaper.ImGui_WindowFlags_NoTitleBar()
      -- Rolled up, the caption buttons alone are 32 px of content inside a
      -- 32 px window — with the window padding on top of that, ImGui would
      -- decide the strip needs a scrollbar and eat 11 px off the close button.
      if V5.win.rolled then wflags = wflags | V5.noscroll_flags() end
    end
    -- v0.7: version in the title bar. The "###dub_pipeline" suffix pins the
    -- ImGui window ID, so future version bumps never reset the saved
    -- window position/size again (only this first rename does, once).
    local visible, open = reaper.ImGui_Begin(_ui_ctx,
      'Dub Pipeline' .. (V5.APP_VERSION ~= '' and ('  v' .. V5.APP_VERSION) or '')
      .. '###dub_pipeline',
      true, wflags)
    -- Outside the `visible` guard on purpose: a fully off-screen window can
    -- report itself as not visible, which is the case we must still rescue.
    check_offscreen(_ui_ctx)
    if visible then
      -- v0.16 tokens for the whole frame; popped at the end of this block.
      local _sv, _sc = V5.push_console_style(_ui_ctx)
      -- v0.22: and the UI face, for the same span. Before the title bar so
      -- the window title is drawn in it too.
      local _sf = V5.push_ui_font(_ui_ctx)
      -- v0.20: our own title bar, first thing inside the window — it also
      -- leaves the cursor at the top-left of the content area for everything
      -- below. On a ReaImGui too old for it, ImGui's own bar is still there.
      if V5.chrome_ok() then V5.ui_titlebar(_ui_ctx, close_window) end
      -- Follow the language combo with a matching Indic font (v0.4).
      _ensure_lang_font(_ui_ctx)
      -- Poll OUTSIDE the tab bar: the run must keep progressing even
      -- while the user sits on the Log tab.
      -- v0.21: a quiet job (the voice fetch) never sets the running phase, so
      -- it needs its own reason to be polled — and, like the run, it has to
      -- finish whichever screen the user walked off to.
      if _ui_phase == "running" or V5.quiet_job then poll_engine() end
      -- v0.5: the embedded Auto Sync run polls every frame too — it is
      -- independent of the dub run and of which tab is showing.
      if V5.SYNC then V5.SYNC.poll() end
      -- v0.16: the launch version check, and the one dialog it may raise.
      V5.poll_update()
      -- v0.17: the Connections key probes. Outside the screen switch on
      -- purpose — a probe fired from Settings has to finish even if you walk
      -- away to the Dub screen while curl is still out.
      V5.conn_poll()

      -- v0.13: the Script control on the Dub tab decides where the translated
      -- script comes from, so there is nothing left for the caller to
      -- override — SCRIPT_MODE is already what the user picked.
      local function render_phase()
        -- v0.25: setup and running are the same screen. The second argument is
        -- the elapsed time, and passing it is what turns the run column's head
        -- from the Run button into the progress bar.
        if _ui_phase == "setup" then
          ui_phase_setup(_ui_ctx, start_dub_run, close_window)
        elseif _ui_phase == "running" then
          ui_phase_setup(_ui_ctx, start_dub_run, close_window,
                         os.time() - _poll_start_time)
        elseif _ui_phase == "review" then
          ui_phase_review(_ui_ctx)
        elseif _ui_phase == "plan" then
          V5.ui_phase_plan(_ui_ctx)
        elseif _ui_phase == "success" then
          ui_phase_success(_ui_ctx, close_window)
        elseif _ui_phase == "failure" then
          ui_phase_failure(_ui_ctx, close_window)
        end
      end

      -- v0.16: a rail instead of a tab bar, and one screen child beside it.
      --   Dub      — the whole dubbing run, whichever way the script arrives.
      --   Sync     — the fast-syncs pipeline embedded.
      --   Tools    — the four small voice utilities behind a segmented row.
      --   Log      — the live engine log.
      --   Settings — connections, models, prompts, advanced, about.
      -- v0.20: rolled up to the title bar, none of this is drawn — but the
      -- polls above it already ran, so a run in progress keeps advancing and
      -- the panel comes back down where it was.
      if not V5.win.rolled then
        V5.ui_rail(_ui_ctx)
        -- 6 px here plus the screen's own 8 px of window padding: 14 px of air
        -- between the rail's dividing line and the first label. At the 8/0 this
        -- started as, every label sat ON the line.
        reaper.ImGui_SameLine(_ui_ctx, 0, 6)
        if V5.begin_padded_child(_ui_ctx, '##screen', -1, -1) then
          -- v0.25: not on the Dub screen. There the header was one row saying
          -- one bit — "keys ready" — which the run column now reports in full,
          -- beside the button the answer is about. Every other screen still
          -- needs it: it is the only place a run in progress is visible from
          -- Sync, Tools or Settings.
          if V5.nav ~= 'dub' then
            V5.ui_header(_ui_ctx)
            reaper.ImGui_Dummy(_ui_ctx, 0, 2)
          end

          if V5.nav == 'sync' then
            V5.load_sync()
            if V5.SYNC then
              -- v0.15: the sync module pins its own Start row; nothing else is
              -- pinned below it, so it gets the full region.
              V5.SYNC.render(_ui_ctx, close_window, 0)
            else
              reaper.ImGui_Dummy(_ui_ctx, 0, 8)
              reaper.ImGui_PushStyleColor(_ui_ctx, reaper.ImGui_Col_Text(),
                                          V5.COL.warn_text)
              reaper.ImGui_TextWrapped(_ui_ctx,
                V5.sync_err or 'Sync module is not loaded.')
              reaper.ImGui_PopStyleColor(_ui_ctx)
            end
          elseif V5.nav == 'tools' then
            -- No footer of its own; the tool bodies are what scroll.
            if V5.begin_body(_ui_ctx, 0) then
              V5.ui_tools_tab(_ui_ctx)
              reaper.ImGui_EndChild(_ui_ctx)
            end
          elseif V5.nav == 'log' then
            -- -34 is its own Auto-scroll row.
            _render_log_child(_ui_ctx, -34)
          elseif V5.nav == 'settings' then
            V5.ui_settings_screen(_ui_ctx)
          else
            render_phase()
          end

          reaper.ImGui_EndChild(_ui_ctx)
        end
      end

      V5.pop_ui_font(_ui_ctx, _sf)
      V5.pop_console_style(_ui_ctx, _sv, _sc)
      -- Inside the guard: see the note in V5.ui_settings_window. NoCollapse
      -- hid this one, but Begin() also reports not-visible for a fully
      -- clipped window — the very case check_offscreen() above exists for,
      -- which is why that call stays outside it.
      reaper.ImGui_End(_ui_ctx)
    end

    -- v0.13: the settings window is a sibling top-level window, drawn after
    -- the main one closes its Begin/End pair. Closing it never closes the app.
    V5.ui_settings_window(_ui_ctx)

    -- v0.16: raised AFTER the Begin/End pair closes. reaper.MB is a blocking
    -- native dialog, and blocking with an ImGui frame half-drawn is a good way
    -- to lose the frame.
    V5.update_popup_if_due()

    _ui_window_open = _ui_window_open and open
    if _ui_window_open then
      reaper.defer(frame)
    end
    -- If the window closes mid-run, the engine keeps running (run_dub.py
    -- still writes log/pid/done); we simply stop polling. Import later with
    -- Import_Dub_Results.lua.
  end

  reaper.defer(frame)
end

reaper.defer(main)
