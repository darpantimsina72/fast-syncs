-- ============================================================
-- DUB PIPELINE PANEL  (Reaper Dubbing App — contract v0.7; the app
-- version shown in the title bar comes from the root VERSION file)
--
-- One-click: pick English audio → run the dubbing pipeline
-- headless (engine/run_dub.py) → import the results to the timeline.
--
-- Phases: setup → running → [review →] running → success/failure.
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
local V5 = { STATUS_ROOT = STATUS_DIR, run_project = nil }

function V5.project_status_slug()
  local _, projfn = reaper.EnumProjects(-1, "")
  if not projfn or projfn == "" then return "unsaved" end
  local h = 5381
  for i = 1, #projfn do h = (h * 33 + projfn:byte(i)) % 4294967296 end
  local base = projfn:match("([^/\\]+)%.[Rr][Pp][Pp]$")
               or projfn:match("([^/\\]+)$") or "project"
  base = base:gsub("[^%w%-_]", "_"):sub(1, 32)
  return string.format("%s_%08x", base, h)
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
  { "translate",  "Translate",        "Full Pipeline steps 1-3" },
  { "emotion",    "Emotion tags",     "step 4, before TTS" },
  { "match",      "Dub matching",     "script to English lines" },
  { "mapping",    "Legacy sync map",  "only in legacy sync mode" },
  { "sync_match", "Auto Sync match",  "the Auto Sync tab" },
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

local LANGUAGES = { "Bengali", "Hindi", "Kannada", "Malayalam", "Tamil",
                    "Telugu", "Gujarati", "Marathi", "Assamese", "Odia",
                    "Nepali" }

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
local MODE_STAGES = {
  full      = STAGE_ORDER,
  translate = { "S1a", "S1b", "S2a", "S2b", "S2c" },
  dub       = { "S2d", "S3a", "S3b", "S3c", "S3d", "S3e" },
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
                     voice_change = true, tts = true }
local _util_return_phase = "setup" -- phase to return to when test/fetch ends

-- v0.3 Settings section state.
local _ui_show_keys    = false     -- plaintext key display toggle
local _voices          = {}        -- { {id=..., name=...}, ... } from --list-voices
local _voices_language = ""        -- language the list was fetched for

-- Review phase state (staged run paused between translation and dubbing):
-- { manifest, en_paras, tr_paras, tr_buffer, use_table, base, edited_path,
--   dirty }
local _review          = nil
-- Review manifest found in status/ at startup (panel closed mid-review).
local _resume_manifest = nil

-- Chunk regeneration state.
local _regen_out_dir      = ""     -- out_dir of the last known manifest
local _regen_lang         = ""     -- language of the last known manifest
local _regen_sel_guid     = ""     -- GUID of the item whose note was loaded
local _regen_text         = ""     -- editable chunk text
local _regen_pending      = nil    -- { guid, note, out_wav } while running
local _regen_return_phase = "setup" -- phase to return to when regen ends

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

local function _spinner_glyph()
  local frames = { '|', '/', '-', '\\' }
  return frames[math.floor(os.clock() * 8) % #frames + 1]
end

local function _grey_hint(ctx, text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
  reaper.ImGui_TextWrapped(ctx, text)
  reaper.ImGui_PopStyleColor(ctx)
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
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFAA55FF)
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

  -- Build everything inside one undo block.
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local suffix = fresh_name_suffix()
  local chunks_added, notes_matched = 0, 0

  -- 1. EN Original
  if en_audio ~= "" then
    local tr = append_named_track(TRACK_EN .. suffix)
    local it = add_file_item(tr, en_audio, 0, nil, 0, basename(en_audio))
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
        local it = add_file_item(tr, tts_wav, e.synced_start, e.dur,
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
        local it = add_file_item(tr, tts_wav, e.synced_start, e.dur,
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
    local it = add_file_item(tr, synced_wav, 0, nil, 0, basename(synced_wav))
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
  local q = _is_windows()
            and function(s) return '"' .. s .. '"' end
            or  shellquote
  local parts = {
    q(py),
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
    "You can keep using this panel — the Auto Sync tab works right\n" ..
    "away. When the terminal says 'Setup complete', the Dubbing tabs\n" ..
    "are ready too.",
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
                  V5.sync_path .. "\n\nThe Auto Sync tab needs the fast-syncs " ..
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
        "\n\nFix it in the Settings tab, then press 'Test connection'.")
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
local function launch_engine(cmd, mode, header_lines)
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
  _ui_phase        = "running"
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
        "Script source is set to 'I already have the translation' — " ..
        "paste the translated script first (or untick the checkbox).")
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
-- manifest's voices[] fills the Settings voice combo.
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
  })
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
  }
  -- Remember (and persist) the run's out_dir for the regen section.
  V5.set_regen_target(m.out_dir, m.language)
  -- v0.7: reaching review is a resumable milestone — record it.
  V5.history_record("review", m)
  _ui_phase = "review"
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

-- Setup-phase history section. Re-loads when the active REAPER project
-- changes (panel left open, user switches project tabs).
function V5.ui_history(ctx)
  if V5.history_slug ~= V5.project_status_slug() then V5.history_load() end
  if #V5.hist == 0 then return end
  reaper.ImGui_Dummy(ctx, 0, 2)
  if not reaper.ImGui_CollapsingHeader(ctx,
      ('Project history (%d run%s)###dub_history'):format(
        #V5.hist, #V5.hist == 1 and "" or "s"),
      reaper.ImGui_TreeNodeFlags_DefaultOpen
      and reaper.ImGui_TreeNodeFlags_DefaultOpen() or 0) then
    return
  end
  reaper.ImGui_Indent(ctx, 8)
  for i, e in ipairs(V5.hist) do
    local label = ('%s  ·  %s  ·  %s  ·  %s'):format(
      e.ts or "?", basename(e.audio or ""), e.language or "?",
      (e.status == "review") and "paused at review"
        or (e.mode == "paste" and "dubbed (pasted script)" or "dubbed"))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
      e.status == "review" and 0xFFCC55FF or 0xAABBCCFF)
    reaper.ImGui_TextWrapped(ctx, label)
    reaper.ImGui_PopStyleColor(ctx)

    local mpath = (e.out_dir or "") .. SEP .. "engine_done.json"
    if e.status == "review" then
      if reaper.ImGui_SmallButton(ctx, 'Resume review##h' .. i) then
        local m = file_exists(mpath) and load_manifest_json(mpath) or nil
        if m and m.status == "review" then
          local ok, why = enter_review_phase(m)
          if not ok then
            ui_set_banner("error", why or "Could not resume the review.")
          end
        else
          ui_set_banner("error",
            "The review files are no longer in:\n" .. (e.out_dir or "?") ..
            "\n(The folder was moved or cleaned — run the pipeline again.)")
        end
      end
      reaper.ImGui_SameLine(ctx)
    elseif e.status == "ok" then
      if reaper.ImGui_SmallButton(ctx, 'Import to timeline##h' .. i) then
        local m = file_exists(mpath) and load_manifest_json(mpath) or nil
        if m and m.status == "ok" then
          reaper.ShowMessageBox(import_to_timeline(m),
                                "Import Dub Results", 0)
        else
          ui_set_banner("error",
            "The run's files are no longer in:\n" .. (e.out_dir or "?"))
        end
      end
      reaper.ImGui_SameLine(ctx)
    end
    if reaper.ImGui_SmallButton(ctx, 'Use audio + language##h' .. i) then
      if (e.audio or "") ~= "" and file_exists(e.audio) then
        LAST_AUDIO = e.audio
      end
      if (e.language or "") ~= "" then LANGUAGE = e.language end
      save_settings()
      ui_set_banner("info", "Audio and language loaded from history.")
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, 'Folder##h' .. i) then
      if (e.out_dir or "") ~= "" then open_path(e.out_dir) end
    end
    if i < #V5.hist then reaper.ImGui_Dummy(ctx, 0, 2) end
  end
  reaper.ImGui_Unindent(ctx, 8)
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

  local lang = (m.language ~= "" and m.language) or LANGUAGE
  local cmd = build_engine_cmd(py, {
    audio = audio, language = lang, steps = "dub", script = script_path,
  })
  return launch_engine(cmd, "dub", {
    "[panel] Python : " .. py,
    "[panel] Audio  : " .. audio,
    "[panel] Lang   : " .. lang,
    "[panel] Steps  : dub",
    "[panel] Script : " .. script_path,
  })
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
local function start_regen(item, text)
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
  local cmd = build_engine_cmd(py, {
    regen = true, language = lang, text_file = txt_path, out_wav = wav_path,
  })
  _regen_pending      = { guid = _item_guid(item), note = text,
                          out_wav = wav_path }
  _regen_return_phase = _ui_phase
  return launch_engine(cmd, "regen", {
    "[panel] Regen  : " .. txt_path,
    "[panel] Out wav: " .. wav_path,
    "[panel] Lang   : " .. lang,
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
local function render_track_stem(track, out_dir, name_base)
  local endpos = _track_items_end(track)
  if endpos <= 0 then
    return nil, "The selected track has no media items."
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
  reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", 0, true)
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

-- v0.4.1: resolve a project track to an English-audio FILE for the
-- pipeline, without manual browsing. A track with exactly ONE untrimmed,
-- unstretched item plays its source file as-is — use that file directly
-- (no render). Anything else (multiple items, trims, offsets, play-rate)
-- is rendered to <project media path>/DubSource/ first.
-- Returns (path, nil, rendered_bool) or (nil, reason).
local function audio_from_track(track)
  local n_items = reaper.CountTrackMediaItems(track)
  if n_items == 0 then
    return nil, "The selected track has no media items."
  end

  if n_items == 1 then
    local it = reaper.GetTrackMediaItem(track, 0)
    local take = reaper.GetActiveTake(it)
    if take and not reaper.TakeIsMIDI(take) then
      local src = reaper.GetMediaItemTake_Source(take)
      -- Unwrap section/reversed wrappers to reach the file source.
      while src do
        local parent = reaper.GetMediaSourceParent(src)
        if parent then src = parent else break end
      end
      local fn = src and reaper.GetMediaSourceFileName(src, "") or ""
      local startoffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
      local rate      = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      local item_len  = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      local src_len, is_qn = reaper.GetMediaSourceLength(src)
      if fn ~= "" and file_exists(fn) and not is_qn
         and math.abs(startoffs or 0) < 0.01
         and math.abs((rate or 1) - 1) < 0.001
         and src_len and math.abs(item_len - src_len) < 0.05 then
        return fn, nil, false
      end
    end
  end

  -- General case: render the track stem and feed the wav to the pipeline.
  local _, tname = reaper.GetSetMediaTrackInfo_String(track, "P_NAME",
                                                      "", false)
  if not tname or tname == "" then tname = "track" end
  local out_dir = reaper.GetProjectPath("") .. SEP .. "DubSource"
  local name_base = _sanitize_filename(tname) .. os.date("_%Y%m%d_%H%M%S")
  local wav, why = render_track_stem(track, out_dir, name_base)
  if not wav then return nil, why end
  return wav, nil, true
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
        ui_set_banner("info", string.format(
          "Fetched %d ElevenLabs voices for %s — pick one in Settings.",
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
    _ui_phase = _util_return_phase or "setup"
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

  if m and m.status == "ok" and exit_code == 0 and not cancelled then
    _manifest    = m
    -- Remember (and persist) where this run's outputs live, so regen works
    -- in later REAPER sessions without re-picking engine_done.json.
    V5.set_regen_target(m.out_dir, m.language)
    -- v0.7: finished dub runs land in the per-project history.
    if _run_mode == "full" or _run_mode == "dub" then
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
    _ui_failure = {
      error_tail = "Python produced no output for 90 seconds — the launch " ..
                   "probably failed.\n\nThings to check:\n" ..
                   "  - the project venv exists and runs (" ..
                   project_venv_python() .. ")\n" ..
                   "    — run " .. SETUP_SCRIPT .. " once; it also rebuilds " ..
                   "a broken venv\n" ..
                   "  - the interpreter path is valid\n" ..
                   "  - engine/run_dub.py exists next to this script's folder",
      log_path = LOG_PATH,
    }
    _ui_phase = "failure"
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
  if _run_mode == "voice_change" then
    return "Changing track voice (ElevenLabs speech-to-speech)…"
  end
  if not _ui_stage_tag then return "Starting engine…" end
  return string.format("[%s]  %s", _ui_stage_tag,
                       STAGE_LABELS[_ui_stage_tag] or "Working…")
end

local function _render_log_child(ctx, height)
  if reaper.ImGui_BeginChild(ctx, '##loglines', -1, height, _child_border_flag()) then
    local pushed = _push_font(ctx, 16)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBBBBBFF)
    local start = math.max(1, #_log_buffer - 300)
    for i = start, #_log_buffer do
      reaper.ImGui_Text(ctx, _log_buffer[i])
    end
    reaper.ImGui_PopStyleColor(ctx)
    if pushed then _pop_font(ctx) end
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

-- ─── Regen section (shared by setup + success phases) ────────
-- Reads the currently selected media item, loads its note into an editable
-- text box and offers "⟳ Regenerate". The out_dir comes from the last
-- manifest this panel saw, the persisted per-project regen target, or a
-- manually picked engine_done.json.
local function ui_regen_section(ctx, default_open)
  V5.prefill_regen_target()
  local flags = 0
  if default_open and reaper.ImGui_TreeNodeFlags_DefaultOpen then
    flags = reaper.ImGui_TreeNodeFlags_DefaultOpen()
  end
  if not reaper.ImGui_CollapsingHeader(ctx, 'Regen selected item', nil, flags) then
    return
  end
  reaper.ImGui_Indent(ctx, 12)
  V5.script_font_warning(ctx)

  if _regen_out_dir == "" then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFAA55FF)
    reaper.ImGui_TextWrapped(ctx,
      'Output folder unknown — pick the engine_done.json of a finished run.')
    reaper.ImGui_PopStyleColor(ctx)
    if reaper.ImGui_Button(ctx, 'Pick engine_done.json…') then
      V5.pick_regen_manifest()
    end
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
    reaper.ImGui_TextWrapped(ctx, 'Regen output: ' .. _regen_out_dir
                                  .. SEP .. 'regen')
    reaper.ImGui_PopStyleColor(ctx)
    -- Wrong target (another project's run)? Re-point without a restart.
    if reaper.ImGui_SmallButton(ctx, 'Change…') then
      V5.pick_regen_manifest()
    end
  end

  local item = reaper.CountSelectedMediaItems(0) > 0
               and reaper.GetSelectedMediaItem(0, 0) or nil
  if not item then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
    reaper.ImGui_TextWrapped(ctx,
      'Select a dub chunk item in the arrange view (on a "Dub Chunks" ' ..
      'track) to edit its text and regenerate its audio.')
    reaper.ImGui_PopStyleColor(ctx)
    _ui_begin_disabled(ctx, true)
    reaper.ImGui_Button(ctx, '⟳ Regenerate', 150, 30)
    _ui_end_disabled(ctx)
  else
    -- Reload the text box from the item note whenever the selection changes
    -- (deliberately discards edits made for a different item).
    local guid = _item_guid(item)
    if guid ~= _regen_sel_guid then
      _regen_sel_guid = guid
      _regen_text = V5.get_item_text(item)
    end

    local tr = reaper.GetMediaItem_Track(item)
    local _, tname = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME",
                                                        "", false)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xDDDDDDFF)
    reaper.ImGui_Text(ctx, string.format('Item: %s  @  %d:%06.3f',
      (tname ~= "" and tname or "(unnamed track)"),
      math.floor(pos / 60), pos % 60))
    reaper.ImGui_PopStyleColor(ctx)

    local pushed = _push_font(ctx, 17)
    local rv, txt = reaper.ImGui_InputTextMultiline(
      ctx, '##regentext', _regen_text or '', -1, 90)
    if pushed then _pop_font(ctx) end
    if rv then _regen_text = txt end

    local can = _regen_out_dir ~= "" and (_regen_text or ""):match("%S") ~= nil
    _ui_begin_disabled(ctx, not can)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x2A6699FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x4488CCFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x114477FF)
    if reaper.ImGui_Button(ctx, '⟳ Regenerate', 150, 30) and can then
      start_regen(item, _regen_text)
    end
    reaper.ImGui_PopStyleColor(ctx, 3)
    _ui_end_disabled(ctx)
    if not can then
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
      reaper.ImGui_Text(ctx, _regen_out_dir == "" and 'need an output folder'
                             or 'text is empty')
      reaper.ImGui_PopStyleColor(ctx)
    end
  end

  reaper.ImGui_Unindent(ctx, 12)
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

function V5.custom_langs_load()
  V5.custom_langs = {}
  for _, e in ipairs(V5.json_object_array(read_all(V5.CUSTOM_LANGS_PATH),
                                          "languages")) do
    local name = (e.name or ""):match("^%s*(.-)%s*$")
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
      'Tip: "Fetch voices" in ⚙ Settings fills this list from your account.')
  end
  return cur
end

V5.bookmarks_load()

local function ui_voice_change_section(ctx, default_open)
  local flags = 0
  if default_open and reaper.ImGui_TreeNodeFlags_DefaultOpen then
    flags = reaper.ImGui_TreeNodeFlags_DefaultOpen()
  end
  if not reaper.ImGui_CollapsingHeader(ctx, '🎤 Change track voice', nil,
                                       flags) then
    return
  end
  reaper.ImGui_Indent(ctx, 12)
  _grey_hint(ctx,
    'Re-voice a whole track: it is rendered to a wav, converted to the ' ..
    'chosen ElevenLabs voice (timing and pacing are kept), and added ' ..
    'back as a new track. The original track is muted, never modified.')

  -- Track picker (rebuilt every frame — tracks can change any time).
  local n_tracks = reaper.CountTracks(0)
  if n_tracks == 0 then
    _grey_hint(ctx, 'The project has no tracks yet.')
    _vc_track_idx = -1
  else
    if _vc_track_idx >= n_tracks then _vc_track_idx = -1 end
    local NO_TRACK = '(pick a track)'
    local items, cur = { NO_TRACK }, NO_TRACK
    for i = 0, n_tracks - 1 do
      local tr = reaper.GetTrack(0, i)
      local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME",
                                                       "", false)
      local label = string.format('%d: %s', i + 1,
                                  (nm ~= "" and nm or '(unnamed)'))
      items[#items + 1] = label
      if i == _vc_track_idx then cur = label end
    end
    local changed, picked = _ui_combo(ctx, 'Track##vc', cur, items)
    if changed then
      _vc_track_idx = -1
      for i, label in ipairs(items) do
        if label == picked and i > 1 then _vc_track_idx = i - 2 break end
      end
    end
  end

  -- Target voice: bookmarks first, then the fetched catalogue (v0.7 picker),
  -- with the manual id field still the final say.
  VC_VOICE_ID = V5.ui_voice_picker(ctx, 'vc', VC_VOICE_ID, 'New voice')
  local rv
  rv, VC_VOICE_ID = reaper.ImGui_InputText(ctx, 'Voice id##vc',
                                           VC_VOICE_ID or '')
  _grey_hint(ctx, 'Leave empty to fall back to the ⚙ Settings voice.')

  local voice = (VC_VOICE_ID ~= "" and VC_VOICE_ID) or VOICE_ID
  local can = _vc_track_idx >= 0 and _vc_track_idx < reaper.CountTracks(0)
              and (voice or ""):match("%S") ~= nil
  _ui_begin_disabled(ctx, not can)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x2A6699FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x4488CCFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x114477FF)
  if reaper.ImGui_Button(ctx, '🎤 Change voice', 160, 30) and can then
    start_voice_change()
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  _ui_end_disabled(ctx)
  if not can then
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
    reaper.ImGui_Text(ctx,
      _vc_track_idx < 0 and 'pick a track first' or 'pick a voice first')
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_Unindent(ctx, 12)
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
V5.tts_pending      = nil     -- { out_wav, text } while a run is in flight
V5.tts_return_phase = "setup"
V5.tts_last_wav     = ""

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
      "No voice selected. Bookmark one here, or fetch the catalogue in the " ..
      "⚙ Settings tab.")
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
  V5.tts_pending      = { out_wav = wav_path, text = text }
  V5.tts_return_phase = _ui_phase
  return launch_engine(cmd, "tts", {
    "[panel] TTS text: " .. txt_path,
    "[panel] Out wav : " .. wav_path,
    "[panel] Voice   : " .. voice,
    "[panel] Python  : " .. py,
  })
end

function V5.ui_tts_tab(ctx)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),  10.0, 10.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),  8.0, 6.0)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
  local pushed = _push_font(ctx, 22)
  reaper.ImGui_Text(ctx, 'Text to Speech')
  if pushed then _pop_font(ctx) end
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
  reaper.ImGui_Text(ctx,
    'Paste text  →  speak it  →  it lands on a "TTS" track at the edit cursor')
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_Dummy(ctx, 0, 6)
  _ui_render_banner(ctx)

  local running = (_ui_phase == "running")
  _ui_begin_disabled(ctx, running)

  reaper.ImGui_Text(ctx, 'Text')
  local pushedf = _push_font(ctx, 17)
  local rv, txt = reaper.ImGui_InputTextMultiline(
    ctx, '##ttstext', V5.tts_text or '', -1, 200)
  if pushedf then _pop_font(ctx) end
  if rv then V5.tts_text = txt end

  if reaper.ImGui_SmallButton(ctx, '📥 Paste from clipboard##tts') then
    local t = reaper.ImGui_GetClipboardText and
              reaper.ImGui_GetClipboardText(ctx)
    if t and t:match("%S") then
      V5.tts_text = t
      ui_set_banner("info", "Pasted " .. #t .. " characters.")
    else
      ui_set_banner("warn", "The clipboard has no text.")
    end
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_SmallButton(ctx, 'Clear##tts') then V5.tts_text = "" end
  reaper.ImGui_SameLine(ctx)
  _grey_hint(ctx, string.format('%d characters', #(V5.tts_text or "")))

  reaper.ImGui_Dummy(ctx, 0, 4)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 4)

  -- Same bookmarks + search as Settings and Track Voice.
  V5.tts_voice = V5.ui_voice_picker(ctx, 'tts', V5.tts_voice, 'Voice')
  local rv2
  rv2, V5.tts_voice = reaper.ImGui_InputText(ctx, 'Voice id##ttsid',
                                             V5.tts_voice or '')
  _grey_hint(ctx, 'Leave empty to use the ⚙ Settings voice'
                  .. ((VOICE_ID or "") ~= "" and (' (' .. VOICE_ID .. ')')
                      or ' (none set yet)') .. '.')
  _grey_hint(ctx, 'Model ' .. (EL_MODEL or '?') ..
                  '  ·  eleven_v3 detects the language from the text itself.')

  reaper.ImGui_Dummy(ctx, 0, 6)
  local voice = ((V5.tts_voice or "") ~= "" and V5.tts_voice) or VOICE_ID
  local can = (V5.tts_text or ""):match("%S") ~= nil
              and (voice or ""):match("%S") ~= nil
  _ui_begin_disabled(ctx, not can)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x2A9945FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x44CC55FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x119911FF)
  if reaper.ImGui_Button(ctx, '🔊  Generate + import', 220, 36) and can then
    V5.start_tts()
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  _ui_end_disabled(ctx)
  if not can then
    reaper.ImGui_SameLine(ctx)
    _grey_hint(ctx, (V5.tts_text or ""):match("%S") and 'pick a voice first'
                    or 'paste some text first')
  end

  _ui_end_disabled(ctx)

  if running then
    reaper.ImGui_Dummy(ctx, 0, 4)
    _grey_hint(ctx, 'A run is in progress — the Logs tab shows its output.')
  end
  if (V5.tts_last_wav or "") ~= "" then
    reaper.ImGui_Dummy(ctx, 0, 4)
    _grey_hint(ctx, 'Last generated: ' .. V5.tts_last_wav)
    if reaper.ImGui_SmallButton(ctx, 'Import again##tts') then
      local ok, why = V5.tts_import(V5.tts_last_wav)
      ui_set_banner(ok and "info" or "error",
        ok and ("Imported again at the edit cursor:\n" .. V5.tts_last_wav)
        or (why or "Import failed."))
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, 'Open folder##tts') then
      open_path(dirname(V5.tts_last_wav))
    end
  end

  reaper.ImGui_PopStyleVar(ctx, 3)
end

-- ─── Review phase (staged run paused after translation) ─────
-- Estimated pixel height for one editable paragraph box (grows with text).
local function _para_box_height(en, tr)
  local n = math.max(#(en or ""), #(tr or ""))
  local lines = math.max(2, math.min(10, math.ceil(n / 90)))
  return lines * 20 + 14
end

local function ui_phase_review(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFCC55FF)
  reaper.ImGui_Text(ctx, 'Paused for review — check the translation, then continue to dubbing')
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Separator(ctx)
  _ui_render_banner(ctx)

  local m = _review.manifest
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
  reaper.ImGui_Text(ctx, string.format('%s  ·  %d EN / %d translated paragraphs',
    (m.language ~= "" and m.language or LANGUAGE),
    #_review.en_paras, #_review.tr_paras))
  reaper.ImGui_TextWrapped(ctx, 'Edited file: ' .. _review.edited_path
    .. (_review.dirty and '   (unsaved changes)' or ''))
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)

  -- v0.4 whole-script clipboard round-trip. ImGui cannot fully shape Indic
  -- conjuncts, so the supported path for a perfectly rendered view is:
  -- copy the script out, edit it anywhere, paste it back (or open the file
  -- in an external editor and reload).
  if reaper.ImGui_Button(ctx, '📋 Copy script', 130, 26) then
    reaper.ImGui_SetClipboardText(ctx, review_collect_text())
    ui_set_banner("info",
      "Whole translation copied — paste it into any editor.")
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, '📋 Copy English', 130, 26) then
    reaper.ImGui_SetClipboardText(ctx,
      table.concat(_review.en_paras, "\n\n") .. "\n")
    ui_set_banner("info", "English transcript copied to the clipboard.")
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, '📥 Paste script', 130, 26) then
    local txt = reaper.ImGui_GetClipboardText(ctx)
    if txt and txt:match("%S") then
      _review_replace_text(txt)
      ui_set_banner("info", string.format(
        "Clipboard pasted — %d paragraph(s) replace the translation. " ..
        "Keep paragraphs separated by one blank line.", #_review.tr_paras))
    else
      ui_set_banner("warn", "The clipboard is empty — nothing to paste.")
    end
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Open in editor', 125, 26) then
    if save_review_text() then open_path(_review.edited_path) end
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, '⟲ Reload file', 115, 26) then
    local path = file_exists(_review.edited_path) and _review.edited_path
                 or _review.manifest.translation_text
    local raw = read_all(path or "")
    if raw then
      _review_replace_text(raw)
      _review.dirty = false
      ui_set_banner("info", "Translation reloaded from:\n" .. path)
    else
      ui_set_banner("error", "Could not read:\n" .. tostring(path))
    end
  end
  _grey_hint(ctx,
    'Script looks distorted? REAPER cannot shape Indic conjuncts — the ' ..
    'AUDIO is not affected. For a perfect view: 📋 Copy script → edit ' ..
    'anywhere → 📥 Paste script, or Open in editor → save → ⟲ Reload file.')
  reaper.ImGui_Dummy(ctx, 0, 2)

  -- Side-by-side panes: EN transcript read-only left, translation editable
  -- right. -52 leaves room for the button row below.
  V5.script_font_warning(ctx)
  local pane_h = -52
  local pushed = _push_font(ctx, 17)
  if _review.use_table then
    local tflags = 0
    if reaper.ImGui_TableFlags_Borders then tflags = tflags | reaper.ImGui_TableFlags_Borders() end
    if reaper.ImGui_TableFlags_RowBg   then tflags = tflags | reaper.ImGui_TableFlags_RowBg()   end
    if reaper.ImGui_TableFlags_ScrollY then tflags = tflags | reaper.ImGui_TableFlags_ScrollY() end
    if reaper.ImGui_BeginTable(ctx, '##review', 2, tflags, -1, pane_h) then
      reaper.ImGui_TableSetupColumn(ctx, 'English (read-only)')
      reaper.ImGui_TableSetupColumn(ctx, 'Translation (editable)')
      if reaper.ImGui_TableSetupScrollFreeze then
        reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
      end
      reaper.ImGui_TableHeadersRow(ctx)
      local rows = math.max(#_review.en_paras, #_review.tr_paras)
      for i = 1, rows do
        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableSetColumnIndex(ctx, 0)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBCCDDFF)
        reaper.ImGui_TextWrapped(ctx, _review.en_paras[i] or '')
        reaper.ImGui_PopStyleColor(ctx)
        reaper.ImGui_TableSetColumnIndex(ctx, 1)
        -- ReaImGui grows string buffers automatically — passing the current
        -- string each frame is the whole buffer-management story.
        local rv, txt = reaper.ImGui_InputTextMultiline(
          ctx, '##tr' .. i, _review.tr_paras[i] or '', -1,
          _para_box_height(_review.en_paras[i], _review.tr_paras[i]))
        if rv then
          _review.tr_paras[i] = txt
          _review.dirty = true
        end
      end
      reaper.ImGui_EndTable(ctx)
    end
  else
    -- Old ReaImGui without tables: two plain children side by side, with
    -- the whole translation in one editable buffer on the right.
    local avail_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local half = math.floor(avail_w / 2) - 6
    if reaper.ImGui_BeginChild(ctx, '##reven', half, pane_h,
                               _child_border_flag()) then
      for _, p in ipairs(_review.en_paras) do
        reaper.ImGui_TextWrapped(ctx, p)
        reaper.ImGui_Dummy(ctx, 0, 8)
      end
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_SameLine(ctx)
    local rv, txt = reaper.ImGui_InputTextMultiline(
      ctx, '##trall', _review.tr_buffer or '', half, pane_h)
    if rv then
      _review.tr_buffer = txt
      _review.dirty = true
    end
  end
  if pushed then _pop_font(ctx) end

  reaper.ImGui_Dummy(ctx, 0, 2)
  if reaper.ImGui_Button(ctx, '💾 Save', 110, 34) then
    if save_review_text() then
      ui_set_banner("info", "Saved:\n" .. _review.edited_path)
    end
  end

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x2A9945FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x44CC55FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x119911FF)
  if reaper.ImGui_Button(ctx, '▶ Continue to Dubbing', 210, 34) then
    -- Capture the path first: a successful launch clears _review.
    local edited = _review.edited_path
    if save_review_text() then launch_dub_continue(edited) end
  end
  reaper.ImGui_PopStyleColor(ctx, 3)

  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Skip edit', 100, 34) then
    -- Continue with the engine's own translation file, ignoring edits.
    launch_dub_continue(_review.manifest.translation_text)
  end

  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Back to setup', 130, 34) then
    -- The translate step already finished — nothing to cancel. The review
    -- manifest stays in status/, so setup offers to resume it.
    _resume_manifest = _review.manifest
    _review = nil
    _ui_phase = 'setup'
  end
end

-- ─── ⚙ Settings section (setup phase, v0.3) ──────────────
-- LLM provider/model/keys + ElevenLabs TTS key/model/voice. Persisted to
-- config/llm_settings.json + config/tts_settings.json (gitignored); the
-- engine reads keys from those files only. Key fields are masked; the
-- "Show keys" checkbox toggles plaintext (fast-syncs pattern).

-- v0.5: `always_open` renders the body without the CollapsingHeader gate —
-- used by the dedicated Settings tab.
local function ui_settings_section(ctx, always_open)
  if not always_open then
    if not reaper.ImGui_CollapsingHeader(ctx, '⚙ Settings  (LLM + TTS keys)') then
      return
    end
  end
  reaper.ImGui_Indent(ctx, 12)
  local rv

  local pw_flags = (_ui_show_keys and 0) or
                   (reaper.ImGui_InputTextFlags_Password and
                    reaper.ImGui_InputTextFlags_Password() or 0)

  -- ── LLM (translation chain) ─────────────────────────────
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xDDDDDDFF)
  reaper.ImGui_Text(ctx, 'LLM — translation / review / mapping')
  reaper.ImGui_PopStyleColor(ctx)

  _grey_hint(ctx, 'These keys are the only copy — the Auto Sync tab uses the ' ..
                  'same ones and has no fields of its own.')
  _, LLM_PROVIDER = _ui_combo(ctx, 'Provider', LLM_PROVIDER, PROVIDER_UI)
  rv, LLM_MODEL = reaper.ImGui_InputText(ctx, 'Model', LLM_MODEL or '')
  if LLM_PROVIDER == 'openai' then
    _grey_hint(ctx, 'Model id your gateway serves, e.g. gemini-3-flash-preview.')
  elseif LLM_PROVIDER == 'server' then
    _grey_hint(ctx, 'Model Auto Sync asks your server for — the server may ' ..
                    'override it.')
  else
    _grey_hint(ctx, 'Gemini model, e.g. gemini-2.5-pro or gemini-3.5-flash.')
  end

  if LLM_PROVIDER == 'gemini' then
    rv, LLM_GEMINI_KEY = reaper.ImGui_InputText(ctx, 'Gemini API key',
                                                LLM_GEMINI_KEY or '', pw_flags)
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, 'Clear##gemk') then
      LLM_GEMINI_KEY, V5.cred_cleared.gemini = '', true
    end
    _grey_hint(ctx, 'Google AI Studio key (starts with "AIza") — ' ..
                    'aistudio.google.com/apikey.')
  elseif LLM_PROVIDER == 'vertex' then
    rv, LLM_VERTEX_JSON = reaper.ImGui_InputText(ctx, 'Vertex key path',
                                                 LLM_VERTEX_JSON or '')
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, 'Browse…##vtx') then
      local ok, picked = reaper.GetUserFileNameForRead(
        LLM_VERTEX_JSON or "", "Select Vertex service-account JSON", "json")
      if ok and picked and picked ~= "" then LLM_VERTEX_JSON = picked end
    end
    _grey_hint(ctx, 'Path to a Google service-account JSON. Leave blank to ' ..
                    'use config/vertex_key.json when it exists.')
  elseif LLM_PROVIDER == 'server' then
    rv, LLM_SERVER_URL = reaper.ImGui_InputText(ctx, 'Server URL',
                                                LLM_SERVER_URL or '')
    rv, LLM_SERVER_TOKEN = reaper.ImGui_InputText(ctx, 'Access token',
                                                  LLM_SERVER_TOKEN or '', pw_flags)
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, 'Clear##srvt') then
      LLM_SERVER_TOKEN, V5.cred_cleared.server = '', true
    end
    _grey_hint(ctx, 'Auto Sync routes every AI call through your server, which ' ..
                    'holds the real provider keys — only this token lives on ' ..
                    'this machine.')
    _grey_hint(ctx, 'DUBBING CANNOT USE THIS MODE: the dub engine calls the LLM ' ..
                    'directly, so dub runs will stop with that message. Pick ' ..
                    'Vertex, Gemini or OpenAI-compatible above to dub.')
  else -- openai
    rv, LLM_OPENAI_URL = reaper.ImGui_InputText(ctx, 'Base URL',
                                                LLM_OPENAI_URL or '')
    rv, LLM_OPENAI_KEY = reaper.ImGui_InputText(ctx, 'API key',
                                                LLM_OPENAI_KEY or '', pw_flags)
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, 'Clear##oaik') then
      LLM_OPENAI_KEY, V5.cred_cleared.openai = '', true
    end
    if LLM_OPENAI_KEY == '' and V5.gateway_needs_key(LLM_OPENAI_URL) then
      _grey_hint(ctx, 'API key is empty — this gateway is remote, so every ' ..
                      'request would go out unauthenticated and come back 401.')
    end
    _grey_hint(ctx, 'API base of an OpenAI-compatible gateway (LiteLLM, ' ..
                    'OpenRouter, vLLM, ...) plus its Bearer key. Host or ' ..
                    'host/v1 — e.g. https://llm.example.com/v1 — NOT the ' ..
                    'chat UI address and without /chat/completions.')
  end

  if LLM_PROVIDER ~= 'server' then
    if reaper.ImGui_Button(ctx, 'Test connection', 150, 26) then
      start_test_llm()
    end
    reaper.ImGui_SameLine(ctx)
    _grey_hint(ctx, 'one tiny LLM call — result shows in a banner')
  end

  reaper.ImGui_Dummy(ctx, 0, 4)
  reaper.ImGui_Separator(ctx)

  -- ── TTS (ElevenLabs) ────────────────────────────────────
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xDDDDDDFF)
  reaper.ImGui_Text(ctx, 'TTS — ElevenLabs')
  reaper.ImGui_PopStyleColor(ctx)

  rv, EL_KEY = reaper.ImGui_InputText(ctx, 'ElevenLabs key',
                                      EL_KEY or '', pw_flags)
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_SmallButton(ctx, 'Clear##elk') then
    EL_KEY, V5.cred_cleared.el = '', true
  end

  -- Model combo: keep an unknown persisted model visible by prepending it.
  local model_items = {}
  local known = false
  for _, mdl in ipairs(EL_MODELS) do
    model_items[#model_items + 1] = mdl
    if mdl == EL_MODEL then known = true end
  end
  if not known and (EL_MODEL or "") ~= "" then
    table.insert(model_items, 1, EL_MODEL)
  end
  _, EL_MODEL = _ui_combo(ctx, 'EL model', EL_MODEL, model_items)

  -- Voice: fetch the catalogue for the current language, pick from a combo,
  -- or type a voice id manually (fallback — always wins, it IS the value).
  if reaper.ImGui_Button(ctx, 'Fetch voices', 150, 26) then
    start_fetch_voices()
  end
  reaper.ImGui_SameLine(ctx)
  _grey_hint(ctx, 'ElevenLabs voice catalogue for: ' .. (LANGUAGE or '?'))

  -- v0.7: bookmarks + search, shared with the Track Voice and Text to
  -- Speech tabs. The manual id field below still wins — it IS the value.
  VOICE_ID = V5.ui_voice_picker(ctx, 'settings', VOICE_ID, 'Voice')
  if #_voices > 0 and _voices_language ~= "" and _voices_language ~= LANGUAGE then
    _grey_hint(ctx, 'Fetched list is for ' .. _voices_language ..
                    ' — fetch again for ' .. LANGUAGE ..
                    ' (bookmarks are not affected).')
  end
  rv, VOICE_ID = reaper.ImGui_InputText(ctx, 'Voice id (manual)', VOICE_ID or '')

  rv, GOOGLE_TTS_KEY_PATH = reaper.ImGui_InputText(
    ctx, 'Google TTS key (optional)', GOOGLE_TTS_KEY_PATH or '')

  reaper.ImGui_Dummy(ctx, 0, 4)
  rv, _ui_show_keys = reaper.ImGui_Checkbox(ctx, 'Show keys', _ui_show_keys)
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, '💾 Save settings', 150, 24) then
    local ok, path = save_config_files()
    if ok and LAST_SYNC_CRED_ERR then
      ui_set_banner("error", "Saved for dubbing, but could not share the keys " ..
                             "with Auto Sync:\n" .. LAST_SYNC_CRED_ERR ..
                             "\nThe Auto Sync tab may still use older keys.")
    elseif ok then
      -- Don't let "Settings saved" be the last word when the LLM still can't
      -- run: say what is missing now, or spend one tiny --test-llm call to
      -- prove the credentials actually work. A paid dub run should never be
      -- the first thing that discovers a blank key.
      local why = V5.llm_creds_error()
      if why then
        ui_set_banner("warn", "Settings saved, but the LLM is not usable yet:\n"
                              .. why)
      elseif LLM_PROVIDER ~= 'server' then
        start_test_llm()
      else
        ui_set_banner("info", "Settings saved to:\n" .. LLM_SETTINGS_PATH ..
                              "\n" .. TTS_SETTINGS_PATH ..
                              "\n" .. SYNC_SETTINGS_PATH .. "  (Auto Sync keys)")
      end
    else
      ui_set_banner("error", "Could not write settings file:\n" ..
                             tostring(path))
    end
  end

  -- Masked one-line summary of what is configured (fast-syncs _mask_key).
  local llm_key_summary
  if LLM_PROVIDER == 'gemini' then
    llm_key_summary = 'gemini key ' ..
      (LLM_GEMINI_KEY ~= '' and _mask_key(LLM_GEMINI_KEY) or '(not set)')
  elseif LLM_PROVIDER == 'vertex' then
    llm_key_summary = 'vertex json ' ..
      (LLM_VERTEX_JSON ~= '' and basename(LLM_VERTEX_JSON) or '(default)')
  elseif LLM_PROVIDER == 'server' then
    llm_key_summary = 'server ' ..
      (LLM_SERVER_URL ~= '' and LLM_SERVER_URL or '(not set)') .. ', token ' ..
      (LLM_SERVER_TOKEN ~= '' and _mask_key(LLM_SERVER_TOKEN) or '(not set)')
  else
    llm_key_summary = 'openai key ' ..
      (LLM_OPENAI_KEY ~= '' and _mask_key(LLM_OPENAI_KEY) or '(not set)')
  end
  _grey_hint(ctx, string.format('%s  ·  EL key %s',
    llm_key_summary,
    EL_KEY ~= '' and _mask_key(EL_KEY) or '(not set)'))
  _grey_hint(ctx, 'Saved automatically before every run. Files stay in ' ..
                  'config/ (gitignored — they never leave this machine).')

  reaper.ImGui_Unindent(ctx, 12)
end

-- ─── Shared source inputs (v0.5) ──────────────────────────
-- Audio picker + from-track + language + run-mode checkbox, used by BOTH
-- the Full Pipeline and the Paste Translation tabs (shared state — the
-- two tabs are two entrances to the same run).
function V5.ui_source_inputs(ctx)
  local rv

  -- Audio picker
  rv, LAST_AUDIO = reaper.ImGui_InputText(ctx, 'English audio', LAST_AUDIO or '')
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Browse…') then
    local ok, picked = reaper.GetUserFileNameForRead(
      LAST_AUDIO or "", "Select English source audio", "")
    if ok and picked and picked ~= "" then LAST_AUDIO = picked end
  end

  -- v0.4.1: or take the audio straight from a project track — no manual
  -- browsing. One clean item → its source file; else the track is
  -- rendered to <project>/DubSource/ and that wav is used.
  local n_src_tracks = reaper.CountTracks(0)
  if n_src_tracks > 0 then
    if _src_track_idx >= n_src_tracks then _src_track_idx = -1 end
    local NO_TRACK = '(pick a track)'
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
    reaper.ImGui_SetNextItemWidth(ctx, 300)
    local tr_changed, picked = _ui_combo(ctx, 'From track', cur, items)
    if tr_changed then
      _src_track_idx = -1
      for i, label in ipairs(items) do
        if label == picked and i > 1 then _src_track_idx = i - 2 break end
      end
    end
    reaper.ImGui_SameLine(ctx)
    _ui_begin_disabled(ctx, _src_track_idx < 0)
    if reaper.ImGui_Button(ctx, 'Use track') and _src_track_idx >= 0 then
      local track = reaper.GetTrack(0, _src_track_idx)
      local path, why, rendered = audio_from_track(track)
      if path then
        LAST_AUDIO = path
        save_settings()
        ui_set_banner("info", rendered
          and ("Track rendered — using:\n" .. path)
          or  ("Using the track item's source file:\n" .. path))
      else
        ui_set_banner("error",
          "Could not use that track:\n" .. (why or "?"))
      end
    end
    _ui_end_disabled(ctx)
  end

  -- Voice id and EL model moved into the ⚙ Settings section (v0.3).
  _, LANGUAGE = _ui_combo(ctx, 'Language', LANGUAGE, LANGUAGES)

  -- v0.2: staged runs are the default — the pipeline pauses after the
  -- translation chain for a side-by-side review. This restores v0.1.
  local fr_changed
  fr_changed, FULL_RUN = reaper.ImGui_Checkbox(ctx, 'Full run (no review)',
                                               FULL_RUN)
  if fr_changed then save_settings() end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
  reaper.ImGui_Text(ctx, FULL_RUN and 'one-shot: no pause'
                         or 'pauses after translation for review')
  reaper.ImGui_PopStyleColor(ctx)
end

-- ─── Setup phase ──────────────────────────────────────────
-- *busy* (v0.4): rendered read-only below the running-phase progress so
-- the settings stay visible during a run — banner/resume/run-button rows
-- are skipped there (the running phase owns them).
local function ui_phase_setup(ctx, on_start, on_cancel, busy)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),  10.0, 10.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),  8.0, 6.0)

  if not busy then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
    local pushed = _push_font(ctx, 22)
    reaper.ImGui_Text(ctx, 'Dub Pipeline')
    if pushed then _pop_font(ctx) end
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
    reaper.ImGui_Text(ctx, 'Transcribe  →  Translate  →  TTS  →  Sync  →  Import')
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_Dummy(ctx, 0, 6)
    _ui_render_banner(ctx)
  end

  -- A staged run paused for review survives a panel restart: the review
  -- manifest is still in engine/status/. Offer to resume instead of paying
  -- for the translate step again.
  if _resume_manifest and not busy then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFCC55FF)
    reaper.ImGui_TextWrapped(ctx,
      'A previous staged run is paused for translation review.')
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, 'Resume review') then
      local m = _resume_manifest
      _resume_manifest = nil
      local ok, why = enter_review_phase(m)
      if not ok then
        ui_set_banner("error", why or "Could not resume the review.")
      end
    end
    reaper.ImGui_Separator(ctx)
  end

  -- v0.7: this REAPER project's past runs (resume review / re-import
  -- without re-transcribing or re-translating).
  if not busy then V5.ui_history(ctx) end

  -- v0.5: audio + language + run-mode live in a shared block (the Paste
  -- Translation tab renders the same inputs). Pasted-script entry moved to
  -- its own tab; LLM/TTS settings and Advanced moved to the Settings tab.
  V5.ui_source_inputs(ctx)

  reaper.ImGui_Dummy(ctx, 0, 8)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 4)

  if not busy then
    local missing = {}
    if (LAST_AUDIO or '') == '' then missing[#missing + 1] = 'English audio file' end

    local disabled = (#missing > 0)
    _ui_begin_disabled(ctx, disabled)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x2A9945FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x44CC55FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x119911FF)
    if reaper.ImGui_Button(ctx, '▶  Run dubbing pipeline', 240, 40) then on_start() end
    reaper.ImGui_PopStyleColor(ctx, 3)
    _ui_end_disabled(ctx)

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, 'Close', 100, 40) then on_cancel() end

    if disabled then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFAA55FF)
      reaper.ImGui_TextWrapped(ctx, 'Missing: ' .. table.concat(missing, ', '))
      reaper.ImGui_PopStyleColor(ctx)
    end
  end

  reaper.ImGui_Dummy(ctx, 0, 4)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x667788FF)
  reaper.ImGui_Text(ctx, string.format('%s   ·   %s   ·   %s',
                                       LANGUAGE or '?',
                                       EL_MODEL ~= '' and EL_MODEL or 'eleven_v3',
                                       FULL_RUN and 'full run' or 'staged run'))
  reaper.ImGui_PopStyleColor(ctx)

  -- v0.5: Regen Audio and Track Voice moved to their own top-level tabs.
  reaper.ImGui_Dummy(ctx, 0, 4)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x667788FF)
  reaper.ImGui_TextWrapped(ctx,
    'Fix single lines in the "Regen Audio" tab · re-voice a whole track in ' ..
    'the "Track Voice" tab · sync dubbed clips in the "Auto Sync" tab.')
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_PopStyleVar(ctx, 3)
end

-- ─── Paste Translation tab (v0.5) ─────────────────────────
-- The old "I already have the translation" checkbox as a tab of its own:
-- pick the audio, paste the translated script, run. The engine skips the
-- LLM translation chain but still transcribes once (sync needs the
-- timings). The staged run still pauses so the pairing can be checked.
function V5.ui_paste_tab(ctx, on_start)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),  10.0, 10.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),  8.0, 6.0)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
  local pushed = _push_font(ctx, 22)
  reaper.ImGui_Text(ctx, 'Paste Translation')
  if pushed then _pop_font(ctx) end
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
  reaper.ImGui_Text(ctx,
    'Your script  →  Match  →  TTS  →  Synced import   (no LLM translation)')
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_Dummy(ctx, 0, 6)
  _ui_render_banner(ctx)

  -- v0.7: same per-project history as the Full Pipeline tab.
  V5.ui_history(ctx)

  V5.ui_source_inputs(ctx)

  reaper.ImGui_Dummy(ctx, 0, 4)
  reaper.ImGui_Text(ctx, 'Translated script')
  local pushedf = _push_font(ctx, 17)
  local rv2, txt = reaper.ImGui_InputTextMultiline(
    ctx, '##provided', _provided_text or '', -1, 180)
  if pushedf then _pop_font(ctx) end
  if rv2 then _provided_text = txt end
  if reaper.ImGui_SmallButton(ctx, '📥 Paste from clipboard##prov') then
    local t = reaper.ImGui_GetClipboardText(ctx)
    if t and t:match("%S") then
      _provided_text = t
    else
      ui_set_banner("warn", "The clipboard is empty — nothing to paste.")
    end
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_SmallButton(ctx, 'Clear##prov') then
    _provided_text = ""
  end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
  reaper.ImGui_Text(ctx, string.format('%d paragraph(s), %d chars',
    #split_paragraphs(_provided_text or ""), #(_provided_text or "")))
  reaper.ImGui_PopStyleColor(ctx)
  _grey_hint(ctx,
    'Separate paragraphs with one blank line. The staged run still ' ..
    'pauses so you can check the pairing against the English transcript. ' ..
    'The audio is transcribed once — the sync stages need the timings.')

  reaper.ImGui_Dummy(ctx, 0, 8)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 4)

  local missing = {}
  if (LAST_AUDIO or '') == '' then
    missing[#missing + 1] = 'English audio file'
  end
  if not (_provided_text or ''):match('%S') then
    missing[#missing + 1] = 'translated script (paste it above)'
  end

  local disabled = (#missing > 0)
  _ui_begin_disabled(ctx, disabled)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x2A9945FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x44CC55FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x119911FF)
  if reaper.ImGui_Button(ctx, '▶  Dub with this script', 240, 40) then
    on_start()
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  _ui_end_disabled(ctx)

  if disabled then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFAA55FF)
    reaper.ImGui_TextWrapped(ctx, 'Missing: ' .. table.concat(missing, ', '))
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_PopStyleVar(ctx, 3)
end

-- ─── Settings tab (v0.5) ──────────────────────────────────
-- LLM + TTS keys (the old ⚙ collapsible), the Advanced python override,
-- and the shared fast-syncs updater. Locked while a run is active — the
-- engine reads config/*.json at launch time.
-- v0.7: one model per pipeline stage. Blank = the single Model field above.
function V5.ui_models_section(ctx)
  if not reaper.ImGui_CollapsingHeader(ctx, 'Model per stage') then return end
  reaper.ImGui_Indent(ctx, 12)
  _grey_hint(ctx, 'Leave a box empty to use the Model set above (' ..
                  ((LLM_MODEL or '') ~= '' and LLM_MODEL or 'not set') ..
                  '). Use this to give the cheap mechanical stages a faster ' ..
                  'model and keep the good one for translation.')
  reaper.ImGui_Dummy(ctx, 0, 2)
  for _, role in ipairs(V5.MODEL_ROLES) do
    local key, label, hint = role[1], role[2], role[3]
    local rv, val = reaper.ImGui_InputText(ctx, label .. '##model_' .. key,
                                           V5.model_roles[key] or '')
    if rv then V5.model_roles[key] = val end
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
function V5.ui_languages_section(ctx)
  if not reaper.ImGui_CollapsingHeader(ctx, 'Languages') then return end
  reaper.ImGui_Indent(ctx, 12)
  _grey_hint(ctx, #V5.custom_langs .. ' added by you, ' ..
                  (#LANGUAGES - #V5.custom_langs) .. ' built in.')

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
  local can = name ~= '' and not dup and name:match('^[%w%-_ ]+$') ~= nil
  _ui_begin_disabled(ctx, not can)
  if reaper.ImGui_Button(ctx, 'Add language', 150, 26) and can then
    V5.custom_langs[#V5.custom_langs + 1] = {
      name = name,
      code = (V5.newlang_code or ''):match('^%s*(.-)%s*$'),
      tag  = name:sub(1, 2):upper(),
    }
    LANGUAGES[#LANGUAGES + 1] = name
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
function V5.ui_prompts_section(ctx)
  if not reaper.ImGui_CollapsingHeader(ctx, 'Prompts') then return end
  reaper.ImGui_Indent(ctx, 12)
  _grey_hint(ctx, 'These are the instructions sent to the AI at each stage. ' ..
                  'One file per language per stage, in dubbing/prompts/.')

  V5.prompt_lang = V5.prompt_lang or LANGUAGE
  local changed, picked = _ui_combo(ctx, 'Language##pr', V5.prompt_lang,
                                    LANGUAGES)
  local reload = false
  if changed then V5.prompt_lang = picked; reload = true end

  local stage_names = {}
  for i, s in ipairs(V5.PROMPT_STAGES) do
    stage_names[i] = s:gsub("_", " ")
  end
  local cur_stage = stage_names[V5.prompt_stage] or stage_names[1]
  local ch2, picked2 = _ui_combo(ctx, 'Stage##pr', cur_stage, stage_names)
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
          'stage. Type one (or copy from another language in the Languages ' ..
          'section) and press Save.')
      end
    end
  end

  local pushed = _push_font(ctx, 15)
  local rv, txt = reaper.ImGui_InputTextMultiline(
    ctx, '##prompt_edit', V5.prompt_text or '', -1, 260)
  if pushed then _pop_font(ctx) end
  if rv then V5.prompt_text = txt; V5.prompt_dirty = true end

  _ui_begin_disabled(ctx, not V5.prompt_dirty)
  if reaper.ImGui_Button(ctx, '💾 Save prompt', 140, 26) then
    local ok, why = V5.prompt_editor_save()
    ui_set_banner(ok and "info" or "error",
      ok and ('Saved ' .. basename(V5.prompt_open)) or why)
  end
  _ui_end_disabled(ctx)
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, '⟲ Reload', 100, 26) then
    V5.prompt_editor_load(V5.prompt_lang, V5.prompt_stage)
    ui_set_banner("info", 'Reloaded from disk — unsaved edits discarded.')
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Open in editor', 130, 26) then
    if V5.prompt_dirty then V5.prompt_editor_save() end
    open_path(V5.prompt_open)
  end
  reaper.ImGui_SameLine(ctx)
  _grey_hint(ctx, (V5.prompt_dirty and 'unsaved · ' or '') ..
                  string.format('%d chars', #(V5.prompt_text or '')))
  _grey_hint(ctx, V5.prompt_open)
  reaper.ImGui_Unindent(ctx, 12)
end

function V5.ui_settings_tab(ctx)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),  10.0, 10.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),  8.0, 6.0)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
  reaper.ImGui_Text(ctx, 'Fast Syncs '
    .. (V5.APP_VERSION ~= '' and ('v' .. V5.APP_VERSION)
        or '(VERSION file missing — run Update…)'))
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)

  local locked = (_ui_phase ~= "setup")
  if locked then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFCC55FF)
    reaper.ImGui_TextWrapped(ctx,
      'Settings are locked while a run is active — they are read at ' ..
      'launch time. Finish (or cancel) the run to edit them.')
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Dummy(ctx, 0, 4)
  end

  _ui_render_banner(ctx)

  _ui_begin_disabled(ctx, locked)
  ui_settings_section(ctx, true)

  reaper.ImGui_Dummy(ctx, 0, 4)
  V5.ui_models_section(ctx)
  reaper.ImGui_Dummy(ctx, 0, 4)
  V5.ui_languages_section(ctx)
  reaper.ImGui_Dummy(ctx, 0, 4)
  V5.ui_prompts_section(ctx)

  reaper.ImGui_Dummy(ctx, 0, 4)
  if reaper.ImGui_CollapsingHeader(ctx, 'Advanced') then
    reaper.ImGui_Indent(ctx, 12)
    local rv
    rv, PYTHON_CMD = reaper.ImGui_InputText(ctx, 'Python override', PYTHON_CMD or '')
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
    reaper.ImGui_TextWrapped(ctx,
      'Python override: leave blank to auto-detect (dubbing/venv/ first, ' ..
      'then system installs). Run ' .. SETUP_SCRIPT .. ' once to create venv/.')
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Unindent(ctx, 12)
  end
  _ui_end_disabled(ctx)

  reaper.ImGui_Dummy(ctx, 0, 8)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 4)

  _ui_begin_disabled(ctx, locked)
  if V5.updater_path() then
    if reaper.ImGui_Button(ctx, 'Update…', 150, 30) then
      V5.run_updater()
    end
    reaper.ImGui_SameLine(ctx)
    _grey_hint(ctx, 'updates the whole fast-syncs install — sync tool ' ..
                    'AND this dubbing app')
  else
    _grey_hint(ctx, 'No fast-syncs updater found above dubbing/ — this ' ..
                    'looks like a standalone install.')
  end
  _ui_end_disabled(ctx)

  reaper.ImGui_PopStyleVar(ctx, 3)
end

-- ─── Running phase ────────────────────────────────────────
local function ui_phase_running(ctx, elapsed_s)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x55AAFFFF)
  reaper.ImGui_Text(ctx, _spinner_glyph() .. '  Running…')
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_SameLine(ctx)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xAAAAAAFF)
  reaper.ImGui_Text(ctx, string.format('  %02d:%02d elapsed',
    math.floor(elapsed_s / 60), elapsed_s % 60))
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x883333FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xAA4444FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x661111FF)
  if reaper.ImGui_Button(ctx, 'Cancel', 80, 0) then cancel_engine() end
  reaper.ImGui_PopStyleColor(ctx, 3)

  reaper.ImGui_Dummy(ctx, 0, 4)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PlotHistogram(), 0x3388FFFF)
  reaper.ImGui_ProgressBar(ctx, _ui_progress, -1, 22,
    string.format('%.0f%%', _ui_progress * 100))
  reaper.ImGui_PopStyleColor(ctx)

  -- Stage checklist (last [Sxx] tag = current stage).
  reaper.ImGui_Dummy(ctx, 0, 4)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFCC55FF)
  reaper.ImGui_Text(ctx, 'Stage: ' .. _stage_line())
  reaper.ImGui_PopStyleColor(ctx)

  -- Checklist: only the ACTIVE mode's stages (a translate run stops at S2c,
  -- a dub resume starts at S2d). Utility modes (regen, test_llm,
  -- list_voices, voice_change) are single calls — no checklist.
  if MODE_STAGES[_run_mode] ~= nil then
    local list = MODE_STAGES[_run_mode] or STAGE_ORDER
    local cur_idx = 0
    for i, t in ipairs(list) do
      if t == _ui_stage_tag then cur_idx = i break end
    end
    for i, t in ipairs(list) do
      local done   = cur_idx > i
      local active = cur_idx == i
      local color  = done and 0x55DD55FF or (active and 0xFFCC55FF or 0x666666FF)
      local mark   = done and '[done]' or (active and '[-->]' or '[    ]')
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color)
      reaper.ImGui_Text(ctx, string.format('%s  %s  %s', mark, t,
                                           STAGE_LABELS[t] or ''))
      reaper.ImGui_PopStyleColor(ctx)
    end
  end

  -- v0.4: the live log lives in the Log tab now. Keep the settings visible
  -- (read-only) below the progress so they are never hidden behind it.
  reaper.ImGui_Dummy(ctx, 0, 4)
  _ui_render_banner(ctx)
  reaper.ImGui_Separator(ctx)
  _ui_begin_disabled(ctx, true)
  ui_phase_setup(ctx, function() end, function() end, true)
  _ui_end_disabled(ctx)
end

-- ─── Success phase ────────────────────────────────────────
local function ui_phase_success(ctx, on_close)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x55DD55FF)
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
                                  n_un > 0 and 0xEEBB44FF or 0x55DD55FF)
      reaper.ImGui_Text(ctx, ('Chunks   : %s synced, %s unsynced%s'):format(
        _manifest.synced_count, _manifest.unsynced_count or '0',
        n_un > 0 and '  (unsynced go to the "Un sync" track on import)' or ''))
      reaper.ImGui_PopStyleColor(ctx)
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
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
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x2A9945FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x44CC55FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x119911FF)
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
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
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
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF5555FF)
  reaper.ImGui_Text(ctx, '✗  Pipeline failed')
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 6)

  if _ui_failure then
    reaper.ImGui_Text(ctx, 'Error:')
    if reaper.ImGui_BeginChild(ctx, '##errtail', -1, 240, _child_border_flag()) then
      local pushed = _push_font(ctx, 16)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFAAAAFF)
      reaper.ImGui_TextWrapped(ctx, _ui_failure.error_tail or '(no output)')
      reaper.ImGui_PopStyleColor(ctx)
      if pushed then _pop_font(ctx) end
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
    -- Wide enough for the side-by-side review table.
    reaper.ImGui_SetNextWindowSize(_ui_ctx, 760, 680, reaper.ImGui_Cond_FirstUseEver())
    -- v0.7: version in the title bar. The "###dub_pipeline" suffix pins the
    -- ImGui window ID, so future version bumps never reset the saved
    -- window position/size again (only this first rename does, once).
    local visible, open = reaper.ImGui_Begin(_ui_ctx,
      'Dub Pipeline' .. (V5.APP_VERSION ~= '' and ('  v' .. V5.APP_VERSION) or '')
      .. '###dub_pipeline',
      true, reaper.ImGui_WindowFlags_NoCollapse())
    -- Outside the `visible` guard on purpose: a fully off-screen window can
    -- report itself as not visible, which is the case we must still rescue.
    check_offscreen(_ui_ctx)
    if visible then
      -- Follow the language combo with a matching Indic font (v0.4).
      _ensure_lang_font(_ui_ctx)
      -- Poll OUTSIDE the tab bar: the run must keep progressing even
      -- while the user sits on the Log tab.
      if _ui_phase == "running" then poll_engine() end
      -- v0.5: the embedded Auto Sync run polls every frame too — it is
      -- independent of the dub run and of which tab is showing.
      if V5.SYNC then V5.SYNC.poll() end

      -- v0.5: the tab a run starts from decides the script source — the
      -- Full Pipeline tab always translates with the LLM, the Paste
      -- Translation tab always uses the pasted script.
      local function start_full_pipeline()
        SCRIPT_MODE = "auto"
        start_dub_run()
      end
      local function start_paste_run()
        SCRIPT_MODE = "have"
        start_dub_run()
      end

      local function render_phase()
        if _ui_phase == "setup" then
          ui_phase_setup(_ui_ctx, start_full_pipeline, close_window)
        elseif _ui_phase == "running" then
          local elapsed = os.time() - _poll_start_time
          ui_phase_running(_ui_ctx, elapsed)
        elseif _ui_phase == "review" then
          ui_phase_review(_ui_ctx)
        elseif _ui_phase == "success" then
          ui_phase_success(_ui_ctx, close_window)
        elseif _ui_phase == "failure" then
          ui_phase_failure(_ui_ctx, close_window)
        end
      end

      -- v0.5: seven tabs. Dubbing: Full Pipeline (all phases, pauses for
      -- review), Paste Translation (bring your own script). Auto Sync: the
      -- fast-syncs pipeline embedded (its own settings live inside it).
      -- Regen Audio / Track Voice: the post-run utilities as their own tabs.
      -- Logs (dub live log) and Settings (dub keys, python override,
      -- updater). A dub run in progress renders on BOTH dubbing tabs so
      -- neither entrance ever looks dead.
      if reaper.ImGui_BeginTabBar
         and reaper.ImGui_BeginTabBar(_ui_ctx, '##tabs') then
        if reaper.ImGui_BeginTabItem(_ui_ctx, ' Full Pipeline ') then
          render_phase()
          reaper.ImGui_EndTabItem(_ui_ctx)
        end
        if reaper.ImGui_BeginTabItem(_ui_ctx, ' Paste Translation ') then
          if _ui_phase == "setup" then
            V5.ui_paste_tab(_ui_ctx, start_paste_run)
          else
            render_phase()
          end
          reaper.ImGui_EndTabItem(_ui_ctx)
        end
        if reaper.ImGui_BeginTabItem(_ui_ctx, ' Auto Sync ') then
          V5.load_sync()
          if V5.SYNC then
            V5.SYNC.render(_ui_ctx, close_window)
          else
            reaper.ImGui_Dummy(_ui_ctx, 0, 8)
            reaper.ImGui_PushStyleColor(_ui_ctx, reaper.ImGui_Col_Text(),
                                        0xFFAA55FF)
            reaper.ImGui_TextWrapped(_ui_ctx,
              V5.sync_err or 'Auto Sync module is not loaded.')
            reaper.ImGui_PopStyleColor(_ui_ctx)
          end
          reaper.ImGui_EndTabItem(_ui_ctx)
        end
        if reaper.ImGui_BeginTabItem(_ui_ctx, ' Text to Speech ') then
          reaper.ImGui_Dummy(_ui_ctx, 0, 6)
          V5.ui_tts_tab(_ui_ctx)
          reaper.ImGui_EndTabItem(_ui_ctx)
        end
        if reaper.ImGui_BeginTabItem(_ui_ctx, ' Regen Audio ') then
          reaper.ImGui_Dummy(_ui_ctx, 0, 6)
          ui_regen_section(_ui_ctx, true)
          reaper.ImGui_EndTabItem(_ui_ctx)
        end
        if reaper.ImGui_BeginTabItem(_ui_ctx, ' Track Voice ') then
          reaper.ImGui_Dummy(_ui_ctx, 0, 6)
          ui_voice_change_section(_ui_ctx, true)
          reaper.ImGui_EndTabItem(_ui_ctx)
        end
        if reaper.ImGui_BeginTabItem(_ui_ctx, ' Logs ') then
          _render_log_child(_ui_ctx, -34)
          reaper.ImGui_EndTabItem(_ui_ctx)
        end
        if reaper.ImGui_BeginTabItem(_ui_ctx, ' Settings ') then
          V5.ui_settings_tab(_ui_ctx)
          reaper.ImGui_EndTabItem(_ui_ctx)
        end
        reaper.ImGui_EndTabBar(_ui_ctx)
      else
        -- Very old ReaImGui without tab support: previous inline layout
        -- (settings included via the setup phase is gone — show the
        -- settings body after the phase instead).
        render_phase()
        if _ui_phase == "setup" then ui_settings_section(_ui_ctx, false) end
        if _ui_phase == "running" then _render_log_child(_ui_ctx, -34) end
      end
    end
    reaper.ImGui_End(_ui_ctx)   -- always paired with Begin()
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
