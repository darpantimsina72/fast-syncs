-- ============================================================
-- AUTO SYNC PIPELINE v1.1
-- One-click: Collect → AI Match → Place items on timeline
--
-- Workflow:
--   1. Reads all items from "Dialogue VO" and "Dub" tracks
--   2. Writes a config JSON with source paths + chunk offsets
--   3. Calls sync_matcher.py (AI transcribes + matches)
--   4. Reads results and moves Dub items to matched positions
--   5. Moves unmatched items to "Un sync" track
--
-- Requirements:
--   - Python 3 with google-genai
--   - soundfile  →  pip install -r requirements.txt
--   - sync_matcher.py in the SAME folder as this script
--
-- How to run:
--   Actions > Show action list > New action > Load ReaScript
--   Select this file, then Run
-- ============================================================

-- ── DEFAULT SETTINGS  (dialog lets you change these) ─────
local TRACK_VO_NAME    = "Dialogue VO"
local TRACK_DUB_NAME   = "Dub"
local TRACK_UNSYNC     = "Un sync"
local DUB_LANGUAGE     = "ne"
local MATCH_MODE       = "gemini"      -- gemini | hybrid | duration

-- Transcription provider — which service turns audio → text:
--   elevenlabs | gemini
local ASR_PROVIDER     = "elevenlabs"

-- Matching always uses Gemini. Backend chooses HOW to call it:
--   vertex  = Google Cloud service-account JSON (fast, no rate limits)
--   rest    = Google AI Studio API key (AIza...), Gemini's native endpoint
--   gateway = an OpenAI-compatible proxy serving Gemini (e.g. an internal
--             LiteLLM gateway). Uses {GEMINI_BASE_URL}/v1/chat/completions
--             with the Gemini key sent as a Bearer token (often "sk-...").
local GEMINI_BACKEND   = "vertex"

-- Gemini model — edit freely. Look up current names at
-- https://ai.google.dev/gemini-api/docs/models  (or check Vertex Model Garden).
local GEMINI_MODEL     = "gemini-2.5-pro"

-- Base URL for the OpenAI-compatible gateway. Only used when
-- GEMINI_BACKEND = "gateway". Example: https://your-gateway.example.com
-- Blank = not used (vertex/rest talk to Google directly).
local GEMINI_BASE_URL  = ""

-- Per-provider keys. Stored locally in sync_pipeline_settings.json (gitignored).
local ELEVENLABS_KEY   = ""
local GEMINI_KEY       = ""

-- Path to a Google Cloud service-account JSON for Vertex AI. Blank = look
-- for "vertex_key.json" next to this script.
local VERTEX_KEY_PATH  = ""

-- Server proxy (thin-client mode). When API_BASE is set, every AI call is
-- routed through your server, which holds the real provider keys — so the
-- ElevenLabs/Gemini keys above can stay blank on shared machines. API_TOKEN
-- is the per-user access token you issued. Blank API_BASE = direct/local mode.
local API_BASE         = ""
local API_TOKEN        = ""

-- Dubbing script content. Pasted directly into the dialog. Reaper's input
-- box collapses newlines on macOS, so use "||" between paragraphs — the
-- save step converts those to real newlines.
local SCRIPT_TEXT      = ""

-- Resolved at runtime by find_python() — never exposed in the dialog.
local PYTHON_CMD       = ""
-- ─────────────────────────────────────────────────────────


-- ═══════════════════════════════════════════════════════════
-- PERSISTENT SETTINGS (saved to settings.json next to script)
-- ═══════════════════════════════════════════════════════════

local function get_settings_path()
  local info = debug.getinfo(1, "S")
  local src  = info.source:match("@(.+)") or ""
  local dir  = src:match("(.+)[/\\]") or "."
  return dir .. "/sync_pipeline_settings.json"
end

local function load_settings()
  local path = get_settings_path()
  local f = io.open(path, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()

  -- Simple JSON parsing for flat key-value pairs
  local function jval(key)
    local val = content:match('"' .. key .. '"%s*:%s*"([^"]*)"')
    return val
  end

  local v
  v = jval("track_vo")         if v and v ~= "" then TRACK_VO_NAME    = v end
  v = jval("track_dub")        if v and v ~= "" then TRACK_DUB_NAME   = v end
  v = jval("language")         if v and v ~= "" then DUB_LANGUAGE     = v end
  v = jval("match_mode")       if v and v ~= "" then MATCH_MODE       = v end
  v = jval("asr_provider")     if v and v ~= "" then ASR_PROVIDER     = v end
  v = jval("gemini_backend")   if v and v ~= "" then GEMINI_BACKEND   = v end
  v = jval("gemini_model")     if v and v ~= "" then GEMINI_MODEL     = v end
  v = jval("gemini_base_url")  if v then GEMINI_BASE_URL = v end

  -- Per-provider keys
  v = jval("elevenlabs_key")   if v then ELEVENLABS_KEY  = v end
  v = jval("gemini_key")       if v then GEMINI_KEY      = v end
  v = jval("vertex_key_path")  if v then VERTEX_KEY_PATH = v end
  v = jval("api_base")         if v then API_BASE        = v end
  v = jval("api_token")        if v then API_TOKEN       = v end

  -- Guard: old settings.json may have asr_provider = bhashini/openai (removed).
  -- Python only accepts elevenlabs|gemini now, so coerce anything else.
  if ASR_PROVIDER ~= "elevenlabs" and ASR_PROVIDER ~= "gemini" then
    ASR_PROVIDER = "elevenlabs"
  end

  -- Multi-line script_text needs special parsing (jval bails at first quote).
  -- Capture between "script_text":" ... " just before the next key line.
  do
    local raw = content:match('"script_text"%s*:%s*"(.-)"%s*[,}]')
    if raw then
      raw = raw:gsub('\\"', '"'):gsub('\\n', '\n'):gsub('\\t', '\t'):gsub('\\\\', '\\')
      SCRIPT_TEXT = raw
    end
  end

  -- Legacy migration from earlier versions
  v = jval("api_key")
  if v and v ~= "" and ELEVENLABS_KEY == "" then
    ELEVENLABS_KEY = v
  end

  v = jval("python_cmd")       if v and v ~= "" then PYTHON_CMD = v end
end

local function save_settings()
  local path = get_settings_path()
  local f = io.open(path, "w")
  if not f then return end

  -- Escape backslashes and quotes for JSON
  local function je(s)
    s = tostring(s or "")
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    return s
  end

  -- Escape newlines/tabs/quotes for JSON string value.
  local function jstr(s)
    s = tostring(s or "")
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"',  '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return s
  end

  f:write('{\n')
  f:write(string.format('  "track_vo": "%s",\n',         je(TRACK_VO_NAME)))
  f:write(string.format('  "track_dub": "%s",\n',        je(TRACK_DUB_NAME)))
  f:write(string.format('  "language": "%s",\n',         je(DUB_LANGUAGE)))
  f:write(string.format('  "match_mode": "%s",\n',       je(MATCH_MODE)))
  f:write(string.format('  "asr_provider": "%s",\n',     je(ASR_PROVIDER)))
  f:write(string.format('  "gemini_backend": "%s",\n',   je(GEMINI_BACKEND)))
  f:write(string.format('  "gemini_model": "%s",\n',     je(GEMINI_MODEL)))
  f:write(string.format('  "gemini_base_url": "%s",\n',  je(GEMINI_BASE_URL)))
  f:write(string.format('  "elevenlabs_key": "%s",\n',   je(ELEVENLABS_KEY)))
  f:write(string.format('  "gemini_key": "%s",\n',       je(GEMINI_KEY)))
  f:write(string.format('  "vertex_key_path": "%s",\n',  je(VERTEX_KEY_PATH)))
  f:write(string.format('  "api_base": "%s",\n',         je(API_BASE)))
  f:write(string.format('  "api_token": "%s",\n',        je(API_TOKEN)))
  f:write(string.format('  "script_text": "%s"\n',       jstr(SCRIPT_TEXT)))
  f:write('}\n')
  f:close()
end

-- Load saved settings on script start
load_settings()


-- ═══════════════════════════════════════════════════════════
-- SETTINGS DIALOG
-- ═══════════════════════════════════════════════════════════

local function _mask_key(key)
  if not key or key == "" then return "" end
  if #key <= 10 then return string.rep("*", #key) end
  return key:sub(1, 4) .. string.rep("*", #key - 8) .. key:sub(-4)
end

-- We use "|" as the field separator so users can paste a script that
-- contains commas without breaking parsing. extrawidth widens the dialog.
local FIELD_SEP = "|"

local function _split(csv)
  local fields = {}
  -- Append separator so the final field is captured even if empty.
  for v in (csv .. FIELD_SEP):gmatch("([^" .. FIELD_SEP .. "]*)" .. FIELD_SEP) do
    fields[#fields + 1] = v
  end
  return fields
end

-- One-line preview of the saved script for the dialog placeholder.
local function _script_preview(text)
  if not text or text == "" then return "(empty — paste below, use || between paragraphs)" end
  local first = text:gsub("[\r\n]+", " "):sub(1, 80)
  return string.format("(%d chars saved) %s%s", #text, first,
                       (#text > 80) and "…" or "")
end

-- ── Dialog 1: tracks, language, mode, transcription provider ──
local function _dialog_basics()
  local ret, csv = reaper.GetUserInputs(
    "Sync — 1/3  Tracks & Mode", 5,
    "VO track:,"                                       ..
    "Dub track:,"                                      ..
    "Language (hi ne ta te bn mr gu kn ml):,"          ..
    "Mode (gemini hybrid duration):,"                  ..
    "Transcribe with (elevenlabs gemini):,"            ..
    "extrawidth=260",
    TRACK_VO_NAME .. "," .. TRACK_DUB_NAME .. "," .. DUB_LANGUAGE .. "," ..
    MATCH_MODE    .. "," .. ASR_PROVIDER
  )
  if not ret then return false end
  local fields = {}
  for v in (csv .. ","):gmatch("([^,]*),") do
    fields[#fields+1] = v:match("^%s*(.-)%s*$")
  end
  if fields[1] and fields[1] ~= "" then TRACK_VO_NAME  = fields[1] end
  if fields[2] and fields[2] ~= "" then TRACK_DUB_NAME = fields[2] end
  if fields[3] and fields[3] ~= "" then DUB_LANGUAGE   = fields[3] end
  if fields[4] and fields[4] ~= "" then MATCH_MODE     = fields[4] end
  if fields[5] and fields[5] ~= "" then ASR_PROVIDER   = fields[5] end
  -- Only elevenlabs|gemini are valid now; coerce typos/old values so the
  -- Python argparse (choices=["elevenlabs","gemini"]) never crashes.
  if ASR_PROVIDER ~= "elevenlabs" and ASR_PROVIDER ~= "gemini" then
    ASR_PROVIDER = "elevenlabs"
  end
  return true
end

-- ── Dialog 2: Gemini matcher + API keys ──
-- Reaper's GetUserInputs always treats labels as comma-separated. The
-- separator= flag changes only the VALUE separator. So labels here use
-- commas (and must not contain any), and values use "|" (FIELD_SEP) so
-- API keys with commas would still parse cleanly.
local function _dialog_keys()
  local em = _mask_key(ELEVENLABS_KEY)
  local gm = _mask_key(GEMINI_KEY)
  local tm = _mask_key(API_TOKEN)

  local ret, csv = reaper.GetUserInputs(
    "Sync — 2/3  Server & keys", 8,
    "Server URL (blank = direct/local mode):,"               ..
    "Server access token:,"                                  ..
    "Gemini backend (vertex / rest / gateway):,"             ..
    "Gemini gateway URL (only for backend=gateway):,"        ..
    "Gemini model:,"                                         ..
    "Vertex JSON path (blank = use vertex_key.json):,"       ..
    "Gemini key (rest=AIza / gateway=Bearer):,"              ..
    "ElevenLabs key (direct mode):,"                         ..
    "extrawidth=320,separator=" .. FIELD_SEP,
    API_BASE        .. FIELD_SEP ..
    tm              .. FIELD_SEP ..
    GEMINI_BACKEND  .. FIELD_SEP ..
    GEMINI_BASE_URL .. FIELD_SEP ..
    GEMINI_MODEL    .. FIELD_SEP ..
    VERTEX_KEY_PATH .. FIELD_SEP ..
    gm              .. FIELD_SEP ..
    em
  )
  if not ret then return false end
  local f = _split(csv)
  local function update_key(idx, current, masked)
    local typed = f[idx] or ""
    if typed ~= "" and typed ~= masked then return typed end
    return current
  end
  -- Server URL is not secret → set it verbatim (blank clears = direct mode).
  API_BASE        = f[1] or ""
  API_TOKEN       = update_key(2, API_TOKEN, tm)
  if f[3] and f[3] ~= "" then GEMINI_BACKEND = f[3] end
  -- Gateway URL is not secret → set verbatim (blank clears).
  GEMINI_BASE_URL = f[4] or ""
  if f[5] and f[5] ~= "" then GEMINI_MODEL   = f[5] end
  VERTEX_KEY_PATH = f[6] or ""
  GEMINI_KEY      = update_key(7, GEMINI_KEY,     gm)
  ELEVENLABS_KEY  = update_key(8, ELEVENLABS_KEY, em)
  return true
end

-- ── Dialog 3: paste the dubbing script ──
-- Reaper's input field is single-line; pasting multi-line text on macOS
-- collapses newlines into spaces. To keep paragraph boundaries the user
-- can write "||" between paragraphs (we convert those to real \n on save).
local function _dialog_script()
  local placeholder = _script_preview(SCRIPT_TEXT)
  -- Show existing content joined with "||" so user can edit in place.
  local current_oneline = SCRIPT_TEXT:gsub("\n", "||"):gsub("\r", "")
  local ret, csv = reaper.GetUserInputs(
    "Sync — 3/3  Dubbing script (paste here, use || between paragraphs)",
    1,
    "Script (leave blank to keep existing — current: " .. placeholder .. "):,"
      .. "extrawidth=520,separator=" .. FIELD_SEP,
    current_oneline
  )
  if not ret then return false end
  local typed = csv or ""
  -- If the user wiped the field deliberately, keep what was already saved.
  -- (Reaper reports an empty string both for "unchanged" and "cleared",
  -- so we treat empty as "no change" rather than "delete".)
  if typed ~= "" then
    -- Convert paragraph markers and any literal newlines to real \n.
    typed = typed:gsub("||", "\n"):gsub("\r\n?", "\n")
    SCRIPT_TEXT = typed
  end
  return true
end

local function show_settings_dialog()
  if not _dialog_basics() then return false end
  if not _dialog_keys()   then return false end
  if not _dialog_script() then return false end
  save_settings()
  return true
end


-- ═══════════════════════════════════════════════════════════
-- UTILITY FUNCTIONS
-- ═══════════════════════════════════════════════════════════

local function log(msg)
  reaper.ShowConsoleMsg(msg .. "\n")
end

local function find_track_by_name(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    local _, tname = reaper.GetTrackName(t)
    if tname == name then return t end
  end
  return nil
end

local function find_or_create_track(name)
  local t = find_track_by_name(name)
  if t then return t end
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  t = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(t, "P_NAME", name, true)
  return t
end

-- Returns items sorted by timeline position.
-- Each entry: { item, pos, len, seq }
-- seq = 1-based sequential number in sorted order (used as ID in Python)
local function get_items_sorted(track)
  local items = {}
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    items[#items + 1] = { item = item, pos = pos, len = len }
  end
  table.sort(items, function(a, b) return a.pos < b.pos end)
  -- Assign sequential IDs AFTER sorting so they match Python output
  for i, v in ipairs(items) do v.seq = i end
  return items
end

local function get_script_dir()
  local info = debug.getinfo(1, "S")
  local src  = info.source:match("@(.+)") or ""
  return src:match("(.+)[/\\]") or "."
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a"); f:close(); return c
end

-- FIX: GetMediaSourceFileName requires TWO arguments in Reaper's Lua API.
-- The second argument is a string buffer — pass "" and use the return value.
local function get_source_path(item)
  local take = reaper.GetActiveTake(item)
  if not take then return "" end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return "" end
  local path = reaper.GetMediaSourceFileName(src, "")   -- ← BUG 1 fixed: added ""
  return path or ""
end

local function get_take_offset(item)
  local take = reaper.GetActiveTake(item)
  if not take then return 0 end
  return reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0
end


-- ═══════════════════════════════════════════════════════════
-- AUTO-DETECT PYTHON + FIRST-TIME SETUP
-- ═══════════════════════════════════════════════════════════

local function _is_windows()
  return reaper.GetOS():match("Win") ~= nil
end

-- Returns the first existing python path among the candidates, or nil.
local function find_python()
  local script_dir = get_script_dir()

  -- 1. User-pinned override (loaded from settings.json) takes priority.
  if PYTHON_CMD ~= "" and file_exists(PYTHON_CMD) then return PYTHON_CMD end

  local sep = _is_windows() and "\\" or "/"
  local bin = _is_windows() and "Scripts\\python.exe" or "bin/python3"

  -- 2. Local venv next to this script — what setup.sh creates.
  local local_venv = script_dir .. sep .. "venv" .. sep .. bin
  if file_exists(local_venv) then return local_venv end

  -- 3. Common system installs.
  local candidates
  if _is_windows() then
    candidates = { "python.exe", "python3.exe", "py.exe" }
  else
    candidates = {
      "/opt/homebrew/bin/python3",         -- Apple Silicon Homebrew
      "/usr/local/bin/python3",            -- Intel Homebrew
      "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
      "/opt/homebrew/Cellar/python@3.13/3.13.12_1/bin/python3.13",
      "/usr/bin/python3",                  -- system
    }
  end
  for _, c in ipairs(candidates) do
    if file_exists(c) then return c end
  end

  return nil
end

-- Run setup.sh if the local venv is missing (first-time install for a new user).
local function ensure_setup()
  local script_dir = get_script_dir()
  local venv_py    = script_dir .. (_is_windows() and "\\venv\\Scripts\\python.exe"
                                                  or "/venv/bin/python3")
  if file_exists(venv_py) then return true end

  local choice = reaper.MB(
    "First-time setup — Python virtualenv not found.\n\n" ..
    "I'll create one in:\n  " .. script_dir .. "/venv\n\n" ..
    "and install the required Python packages.\n\n" ..
    "Continue?",
    "Auto Sync Pipeline — Setup", 1)
  if choice ~= 1 then return false end

  if _is_windows() then
    local setup_bat = script_dir .. "\\setup.bat"
    if not file_exists(setup_bat) then
      reaper.MB("setup.bat missing — please run it manually:\n\n" ..
                "  double-click setup.bat in:\n  " .. script_dir,
                "Setup script not found", 0)
      return false
    end
    reaper.MB("Setup will open in a new window. When it says 'Setup complete', " ..
              "close it and run this script again.", "Setup running", 0)
    -- start "<title>" cmd /k "<bat>"  → opens a console that stays up so the
    -- user can read progress/errors (setup.bat ends with pause too).
    os.execute('start "fast-syncs setup" cmd /k "\"' .. setup_bat .. '\""')
    return false
  end

  local setup_sh = script_dir .. "/setup.sh"
  if not file_exists(setup_sh) then
    reaper.MB("setup.sh missing — please run it manually:\n\n" ..
              "  cd \"" .. script_dir .. "\"\n  bash setup.sh",
              "Setup script not found", 0)
    return false
  end
  reaper.MB("Setup is running in Terminal. Once it finishes, click OK to continue.",
            "Setup running", 0)
  os.execute('osascript -e \'tell application "Terminal" to do script "bash \\"' ..
             setup_sh .. '\\""\'')
  -- We can't easily wait for the Terminal session to finish; tell user to retry.
  reaper.MB("After setup completes in the Terminal window, run this script again.",
            "Re-run after setup", 0)
  return false
end


-- ═══════════════════════════════════════════════════════════
-- BUILD CONFIG JSON  (written to disk, read by Python)
-- ═══════════════════════════════════════════════════════════

local function esc(s)
  -- Escape a string for JSON
  s = tostring(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"',  '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  return s
end

local function build_item_json(id, pos, dur, wav_path, take_offset)
  return string.format(
    '{"id":%d,"position":%.6f,"duration":%.6f,"wav_path":"%s","take_offset":%.6f}',
    id, pos, dur, esc(wav_path), take_offset
  )
end

local function write_config(en_items, dub_items, results_path)
  local script_dir  = get_script_dir()
  local config_path = script_dir .. "/sync_config.json"

  local lines = {}
  lines[#lines+1] = '{'
  lines[#lines+1] = string.format('  "output_path": "%s",', esc(results_path))

  -- Optional dubbing-script content. We pass it inline as script_text so
  -- the user doesn't need to type a file path in the dialog.
  if SCRIPT_TEXT and SCRIPT_TEXT ~= "" then
    lines[#lines+1] = string.format('  "script_text": "%s",', esc(SCRIPT_TEXT))
  end

  -- EN items array
  lines[#lines+1] = '  "en_items": ['
  for i, v in ipairs(en_items) do
    local comma = (i < #en_items) and "," or ""
    lines[#lines+1] = "    " ..
      build_item_json(v.seq, v.pos, v.len,
                      get_source_path(v.item),
                      get_take_offset(v.item)) .. comma
  end
  lines[#lines+1] = '  ],'

  -- Dub items array
  lines[#lines+1] = '  "dub_items": ['
  for i, v in ipairs(dub_items) do
    local comma = (i < #dub_items) and "," or ""
    lines[#lines+1] = "    " ..
      build_item_json(v.seq, v.pos, v.len,
                      get_source_path(v.item),
                      get_take_offset(v.item)) .. comma
  end
  lines[#lines+1] = '  ]'
  lines[#lines+1] = '}'

  local f = io.open(config_path, "w")
  if not f then
    reaper.ShowMessageBox("Cannot write config to:\n" .. config_path, "Error", 0)
    return nil
  end
  f:write(table.concat(lines, "\n"))
  f:close()
  return config_path
end


-- ═══════════════════════════════════════════════════════════
-- RUN PYTHON MATCHER (non-blocking with live console output)
-- ═══════════════════════════════════════════════════════════

local function build_python_cmd(config_path)
  local script_dir  = get_script_dir()
  local matcher     = script_dir .. "/sync_matcher.py"
  local log_path    = script_dir .. "/sync_python_log.txt"
  local pid_path    = script_dir .. "/sync_python_pid.txt"
  local done_path   = script_dir .. "/sync_python_done.txt"

  if not file_exists(matcher) then
    reaper.ShowMessageBox(
      "sync_matcher.py not found at:\n" .. matcher ..
      "\n\nMake sure it is in the SAME folder as this Lua script.",
      "File not found", 0)
    return nil
  end

  -- Cross-platform launch via run_sync.py.
  --
  -- run_sync.py reads the provider keys + Vertex path + server proxy settings
  -- from sync_pipeline_settings.json (already saved by the dialog), sets the
  -- SYNC_* environment for the worker, redirects output to the log file, and
  -- writes the exit code to the done file. Doing this in Python means the
  -- launch command has NO POSIX-only `VAR=val cmd` env prefix and NO bash-only
  -- `( ... ; echo $? > done ) &` wrapper — both of which failed on Windows.
  -- Secrets never appear on the command line either (so they can't leak via
  -- the process list).
  local launcher = script_dir .. "/run_sync.py"
  if not file_exists(launcher) then
    reaper.ShowMessageBox(
      "run_sync.py not found at:\n" .. launcher ..
      "\n\nMake sure it is in the SAME folder as this Lua script.",
      "File not found", 0)
    return nil
  end

  local cmd
  if _is_windows() then
    -- start "" /b  → background, no new console window. The empty "" is the
    -- required window-title argument that `start` always consumes first.
    cmd = string.format(
      'start "" /b "%s" "%s" "%s" --language %s --mode %s --asr %s',
      PYTHON_CMD, launcher, script_dir,
      DUB_LANGUAGE, MATCH_MODE, ASR_PROVIDER
    )
  else
    -- Trailing & backgrounds the launcher; it manages the log + done files.
    cmd = string.format(
      '"%s" "%s" "%s" --language %s --mode %s --asr %s >/dev/null 2>&1 &',
      PYTHON_CMD, launcher, script_dir,
      DUB_LANGUAGE, MATCH_MODE, ASR_PROVIDER
    )
  end

  return cmd, log_path, done_path
end


-- ═══════════════════════════════════════════════════════════
-- PARSE RESULTS AND MOVE ITEMS
-- ═══════════════════════════════════════════════════════════

local function apply_results(results_path, dub_items)
  local content = read_file(results_path)
  if not content then
    reaper.ShowMessageBox(
      "Results file not found:\n" .. results_path ..
      "\n\nThe Python matcher may have failed or produced no output.",
      "Missing results", 0)
    return 0, 0
  end

  -- Parse results line by line
  -- Each result block in JSON looks like:
  --   { "dub_id": N, "status": "matched", "new_position": X.XXX, ... }
  local results_data = {}
  local cur = nil

  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    local dub_id = line:match('"dub_id"%s*:%s*(%d+)')
    if dub_id then
      cur = { dub_id = tonumber(dub_id) }
      results_data[#results_data + 1] = cur
    end
    if cur then
      local status  = line:match('"status"%s*:%s*"([^"]+)"')
      local new_pos = line:match('"new_position"%s*:%s*(%-?[%d%.]+)')
      if status  then cur.status      = status            end
      if new_pos then cur.new_position = tonumber(new_pos) end
    end
  end

  -- FIX BUG 2: Build lookup keyed on seq (1-based sorted position),
  -- which is exactly what Python uses as dub_id.
  local dub_lookup = {}
  for _, d in ipairs(dub_items) do
    dub_lookup[d.seq] = d        -- seq == the id Python was given
  end

  local unsync_track  = nil
  local moved         = 0
  local unmatched_cnt = 0

  for _, r in ipairs(results_data) do
    local d = dub_lookup[r.dub_id]
    if not d then
      log(string.format("  [WARN] No item found for dub_id=%d", r.dub_id))
      goto continue
    end

    if r.status == "matched" and r.new_position then
      reaper.SetMediaItemInfo_Value(d.item, "D_POSITION", r.new_position)
      moved = moved + 1
      log(string.format("  MOVED  dub[%d] → %.3fs", r.dub_id, r.new_position))

    elseif r.status == "unmatched" then
      if not unsync_track then
        unsync_track = find_or_create_track(TRACK_UNSYNC)
      end
      -- Use the Python-computed new_position (beside previous DUB in
      -- chronological order). Fall back to the clip's original position
      -- if new_position is absent (e.g. older results file).
      local place_pos
      if r.new_position then
        place_pos = r.new_position
      else
        place_pos = reaper.GetMediaItemInfo_Value(d.item, "D_POSITION")
      end
      reaper.MoveMediaItemToTrack(d.item, unsync_track)
      reaper.SetMediaItemInfo_Value(d.item, "D_POSITION", place_pos)
      unmatched_cnt = unmatched_cnt + 1
      log(string.format("  UNSYNC dub[%d] at %.3fs", r.dub_id, place_pos))

    elseif r.status == "missing_file" then
      if not unsync_track then
        unsync_track = find_or_create_track(TRACK_UNSYNC)
      end
      local orig = reaper.GetMediaItemInfo_Value(d.item, "D_POSITION")
      reaper.MoveMediaItemToTrack(d.item, unsync_track)
      reaper.SetMediaItemInfo_Value(d.item, "D_POSITION", orig)
      unmatched_cnt = unmatched_cnt + 1
      log(string.format("  MISSING dub[%d] (audio file not found, moved to unsync)", r.dub_id))
    end

    ::continue::
  end

  return moved, unmatched_cnt
end


-- ═══════════════════════════════════════════════════════════
-- READ SUMMARY FROM RESULTS JSON
-- ═══════════════════════════════════════════════════════════

local function read_summary(results_path)
  local c = read_file(results_path)
  if not c then return nil end
  return {
    total_en  = c:match('"total_en"%s*:%s*(%d+)')  or "?",
    total_dub = c:match('"total_dub"%s*:%s*(%d+)') or "?",
    matched   = c:match('"matched"%s*:%s*(%d+)')   or "?",
    unmatched = c:match('"unmatched"%s*:%s*(%d+)') or "?",
    model     = c:match('"model"%s*:%s*"([^"]+)"') or "?",
    language  = c:match('"language"%s*:%s*"([^"]+)"') or "?",
    backend   = c:match('"backend"%s*:%s*"([^"]+)"') or "?",
  }
end


-- ═══════════════════════════════════════════════════════════
-- LIVE LOG TAIL — polls log file and prints new lines to console
-- ═══════════════════════════════════════════════════════════

-- These are set by main() and read by the polling loop
local _poll_log_path    = nil
local _poll_done_path   = nil
local _poll_results_path = nil
local _poll_dub_items   = nil
local _poll_last_size   = 0
local _poll_start_time  = 0

local function on_python_done(success)
  if not success then return end

  reaper.ShowConsoleMsg("\n[STEP 3] Applying results to timeline...\n")

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local moved, unmatched = apply_results(_poll_results_path, _poll_dub_items)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Auto Sync Pipeline", -1)

  -- Summary popup
  local s = read_summary(_poll_results_path)
  local elapsed = os.time() - _poll_start_time
  local msg
  if s then
    msg = string.format(
      "Done in %ds!\n\n"                          ..
      "VO items analysed  : %s\n"                 ..
      "Dub items matched  : %s / %s\n"            ..
      "Dub items unmatched: %s\n\n"               ..
      'Unmatched → "%s" track\n\n'                ..
      "Model   : %s\n"                            ..
      "Language: %s\n"                            ..
      "Backend : %s\n\n"                          ..
      "Tip: use Sync_Item.lua to manually\n"      ..
      "fix any remaining unmatched items.",
      elapsed, s.total_en, s.matched, s.total_dub,
      s.unmatched, TRACK_UNSYNC,
      s.model, s.language, s.backend)
  else
    msg = string.format(
      "Done in %ds!\n\nMoved: %d\nUnmatched: %d\n\n" ..
      'Unmatched items are on "%s" track.',
      elapsed, moved, unmatched, TRACK_UNSYNC)
  end

  reaper.ShowMessageBox(msg, "Auto Sync — Complete", 0)
end

local function poll_python_log()
  -- Read new content from log file
  local f = io.open(_poll_log_path, "r")
  if f then
    local content = f:read("*a")
    f:close()
    if content and #content > _poll_last_size then
      local new_text = content:sub(_poll_last_size + 1)
      -- Print each new line to Reaper console
      for line in new_text:gmatch("([^\n]*)\n?") do
        if line and line ~= "" then
          reaper.ShowConsoleMsg("  " .. line .. "\n")
        end
      end
      _poll_last_size = #content
    end
  end

  -- Check if Python is done (done file exists with exit code)
  local df = io.open(_poll_done_path, "r")
  if df then
    local exit_code_str = df:read("*a")
    df:close()
    if exit_code_str and exit_code_str:match("%d") then
      local exit_code = tonumber(exit_code_str:match("(%d+)"))
      -- Flush any remaining log content
      local f2 = io.open(_poll_log_path, "r")
      if f2 then
        local final = f2:read("*a")
        f2:close()
        if final and #final > _poll_last_size then
          for line in final:sub(_poll_last_size + 1):gmatch("([^\n]*)\n?") do
            if line and line ~= "" then
              reaper.ShowConsoleMsg("  " .. line .. "\n")
            end
          end
        end
      end

      local elapsed = os.time() - _poll_start_time
      reaper.ShowConsoleMsg(string.format(
        "\n──── Python finished in %ds (exit code %d) ────\n",
        elapsed, exit_code or -1))

      -- Clean up done file
      os.remove(_poll_done_path)

      if (exit_code == 0) and file_exists(_poll_results_path) then
        on_python_done(true)
      else
        local python_log = read_file(_poll_log_path) or "(no output)"
        local short_log = python_log
        if #short_log > 800 then
          short_log = "...\n" .. short_log:sub(-800)
        end
        reaper.ShowMessageBox(
          "The Python matcher failed.\n\n" ..
          "Error output (see console for full log):\n" ..
          "──────────────────\n" ..
          short_log ..
          "\n──────────────────\n\n" ..
          "Common fixes:\n" ..
          "  pip install -r requirements.txt\n" ..
          "  pip install soundfile\n\n" ..
          "Full log saved at:\n" .. _poll_log_path,
          "Python Error", 0)
      end
      return  -- stop polling
    end
  end

  -- Not done yet — schedule next poll
  reaper.defer(poll_python_log)
end


-- ═══════════════════════════════════════════════════════════
-- MAIN
-- ═══════════════════════════════════════════════════════════

local function main()

  -- Open and clear the Reaper console so live output is visible immediately
  reaper.ShowConsoleMsg("")   -- this brings the console window to front
  reaper.ClearConsole()

  -- ── 0. Settings dialog ───────────────────────────────────
  if not show_settings_dialog() then return end

  -- ── 0a. Auto-detect Python ───────────────────────────────
  local py = find_python()
  if not py then
    if not ensure_setup() then return end
    py = find_python()
    if not py then
      reaper.MB("Could not find a Python interpreter even after setup.\n" ..
                "Please install Python 3.11+ and re-run setup.sh.",
                "Python not found", 0)
      return
    end
  end
  PYTHON_CMD = py
  log(string.format("  Python    : %s", PYTHON_CMD))

  -- ── 1. Find tracks ────────────────────────────────────────
  local track_vo  = find_track_by_name(TRACK_VO_NAME)
  local track_dub = find_track_by_name(TRACK_DUB_NAME)

  if not track_vo then
    reaper.ShowMessageBox(
      'Track "' .. TRACK_VO_NAME .. '" not found.\n\n' ..
      'Check the track name matches exactly\n(capital letters matter).',
      "Track not found", 0)
    return
  end
  if not track_dub then
    reaper.ShowMessageBox(
      'Track "' .. TRACK_DUB_NAME .. '" not found.\n\n' ..
      'Check the track name matches exactly\n(capital letters matter).',
      "Track not found", 0)
    return
  end

  -- ── 2. Get items ──────────────────────────────────────────
  local vo_items  = get_items_sorted(track_vo)
  local dub_items = get_items_sorted(track_dub)

  if #vo_items == 0 then
    reaper.ShowMessageBox(
      'No items on track "' .. TRACK_VO_NAME .. '".\n\n' ..
      'Import English audio and use Dynamic Split first.',
      "No items", 0)
    return
  end
  if #dub_items == 0 then
    reaper.ShowMessageBox(
      'No items on track "' .. TRACK_DUB_NAME .. '".\n\n' ..
      'Import dubbed audio and use Dynamic Split first.',
      "No items", 0)
    return
  end

  log("\n" .. string.rep("=", 60))
  log("  AUTO SYNC PIPELINE v1.1")
  log(string.rep("=", 60))
  log(string.format("  VO items  : %d", #vo_items))
  log(string.format("  Dub items : %d", #dub_items))
  log(string.format("  Language  : %s", DUB_LANGUAGE))
  log(string.format("  ASR       : %s", ASR_PROVIDER))
  log(string.format("  Matcher   : Gemini (%s, model: %s)", GEMINI_BACKEND, GEMINI_MODEL))
  if API_BASE ~= "" then
    log(string.format("  Backend   : server proxy (%s)", API_BASE))
  elseif GEMINI_BACKEND == "gateway" then
    log(string.format("  Backend   : gateway (%s)",
        (GEMINI_BASE_URL ~= "" and GEMINI_BASE_URL or "NO URL SET!")))
  else
    log("  Backend   : direct (keys on this machine)")
  end
  if SCRIPT_TEXT and SCRIPT_TEXT ~= "" then
    log(string.format("  Script    : loaded (%d chars)", #SCRIPT_TEXT))
  end

  -- ── 3. Prepare paths ─────────────────────────────────────
  local script_dir  = get_script_dir()
  local results_path = script_dir .. "/sync_results.json"

  -- Delete old results so we don't accidentally use stale data
  os.remove(results_path)

  -- ── 4. Write config JSON ──────────────────────────────────
  log("\n[STEP 1] Writing config JSON...")
  local config_path = write_config(vo_items, dub_items, results_path)
  if not config_path then return end
  log("  Written: " .. config_path)

  -- ── 5. Build and launch Python (non-blocking) ────────────
  local cmd, log_path, done_path = build_python_cmd(config_path)
  if not cmd then return end

  -- Delete old done marker
  os.remove(done_path)

  local asr_info = "ASR: " .. ASR_PROVIDER
  if ASR_PROVIDER == "gemini" then
    asr_info = asr_info .. " (Gemini audio)"
  elseif ASR_PROVIDER == "elevenlabs" then
    if MATCH_MODE == "gemini" then
      asr_info = asr_info .. " (ElevenLabs + Gemini semantic match)"
    elseif GEMINI_KEY and GEMINI_KEY ~= "" then
      asr_info = asr_info .. " (ElevenLabs + Gemini translate)"
    else
      asr_info = asr_info .. " (ElevenLabs Scribe)"
    end
  end

  log("\n[STEP 2] Launching AI matcher in background...")
  log("  Mode     : " .. MATCH_MODE)
  log("  " .. asr_info)
  log("  Language : " .. DUB_LANGUAGE)
  log("  Log file : " .. log_path)
  log("\n──── Live Python output ────────────────────────────────")

  -- Set up polling state
  _poll_log_path     = log_path
  _poll_done_path    = done_path
  _poll_results_path = results_path
  _poll_dub_items    = dub_items
  _poll_last_size    = 0
  _poll_start_time   = os.time()

  -- Launch Python in background
  os.execute(cmd)

  -- Start polling loop (runs via reaper.defer, non-blocking)
  reaper.defer(poll_python_log)
end

reaper.defer(main)
