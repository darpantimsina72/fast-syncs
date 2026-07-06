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
--   - ReaImGui extension (free, install via ReaPack). The UI is a ReaImGui
--     window; if it's missing the script shows one-time install steps and exits.
--   - Python 3.9+ (3.11+ recommended)
--   - One-time install: setup.bat (Windows) / setup.sh (macOS) builds ./venv.
--     Thin-client (server) mode needs only the standard library; direct mode
--     adds google-genai + soundfile (install with:  setup.bat --direct)
--   - sync_matcher.py + run_sync.py in the SAME folder as this script
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
local MATCH_MODE       = "gemini"      -- locked: Gemini semantic matching only

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

-- Coerce free-text values to what the Python side accepts, so a typo or a
-- stray capital letter ("Gemini", "VERTEX") can never crash argparse.
-- Defined BEFORE load_settings so its body can see them (lexical scoping).
local function _norm_mode(m)
  -- Gemini semantic matching is the ONLY supported mode. Legacy settings
  -- files may still say hybrid/duration — coerce them. If Gemini fails the
  -- Python side hard-errors (exit 1) instead of falling back.
  return "gemini"
end

local function _norm_backend(b)
  b = tostring(b or ""):lower()
  if b ~= "vertex" and b ~= "rest" and b ~= "gateway" and b ~= "auto" then
    b = "vertex"
  end
  return b
end

local function load_settings()
  local path = get_settings_path()
  local f = io.open(path, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()

  -- Simple JSON parsing for flat key-value pairs.
  -- IMPORTANT: unescape \\ and \" — save_settings() escapes them, so without
  -- this a Windows path like C:\Users\... doubles its backslashes on every
  -- save/load cycle (C:\\Users → C:\\\\Users → ...) and slowly corrupts.
  local function jval(key)
    local val = content:match('"' .. key .. '"%s*:%s*"([^"]*)"')
    if val then val = val:gsub('\\(["\\])', '%1') end
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
  ASR_PROVIDER = ASR_PROVIDER:lower()
  if ASR_PROVIDER ~= "elevenlabs" and ASR_PROVIDER ~= "gemini" then
    ASR_PROVIDER = "elevenlabs"
  end
  -- Same for mode/backend — a hand-edited or legacy settings.json must never
  -- feed a value the Python argparse would reject.
  MATCH_MODE     = _norm_mode(MATCH_MODE)
  GEMINI_BACKEND = _norm_backend(GEMINI_BACKEND)

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
  -- Persist the user-pinned interpreter override; without this line a
  -- hand-edited "python_cmd" would be erased on the next dialog OK.
  f:write(string.format('  "python_cmd": "%s",\n',       je(PYTHON_CMD)))
  f:write(string.format('  "script_text": "%s"\n',       jstr(SCRIPT_TEXT)))
  f:write('}\n')
  f:close()
end

-- Load saved settings on script start
load_settings()


-- ═══════════════════════════════════════════════════════════
-- GUI (ReaImGui) — state + shared helpers
-- ═══════════════════════════════════════════════════════════
-- The front-end is a single ReaImGui window that walks through four phases:
--   setup → running → success → failure
-- ReaImGui is REQUIRED. If it is not installed, main() shows a one-time
-- install prompt (with the ReaPack steps) and exits without doing anything.

local function _mask_key(key)
  if not key or key == "" then return "" end
  if #key <= 10 then return string.rep("*", #key) end
  return key:sub(1, 4) .. string.rep("*", #key - 8) .. key:sub(-4)
end

-- ── UI state machine ──────────────────────────────────────
local _ui_ctx          = nil
local _ui_phase        = "setup"   -- setup | running | success | failure
local _ui_banner       = nil       -- { kind = "error"|"info"|"warn", text }
local _ui_setup_card   = nil       -- transient info card over the setup form
local _ui_window_open  = true
local _ui_step_label   = "Preparing…"
local _ui_step_idx     = 0         -- 0..3
local _ui_font         = nil       -- Unicode/Indic-capable font for log lines
local _ui_result       = nil       -- success summary text
local _ui_failure      = nil       -- { error_tail, log_path }
local _log_buffer      = {}        -- ring of last ~500 log lines for display
local _log_autoscroll  = true
local _ui_show_keys    = false     -- toggle plaintext key display

-- Progress tracking (drives the progress bar + per-step detail)
local _ui_progress     = 0.0
local _ui_en_total     = 0
local _ui_dub_total    = 0
local _ui_en_done      = 0
local _ui_dub_done     = 0
local _poll_step_phase = 0         -- 1=EN transcribe, 2=DUB, 3=Gemini, 4=apply
local _ui_cancelled    = false
local _ui_results_rows = {}        -- per-clip rows for the success table

-- Poll state — shared by the running-phase renderer and the poller. Declared
-- here (before the UI renderers) so both capture the same upvalues.
local _poll_log_path     = nil
local _poll_done_path    = nil
local _poll_results_path = nil
local _poll_dub_items    = nil
local _poll_last_size    = 0
local _poll_start_time   = 0

-- Version-safe BeginDisabled / EndDisabled (older ReaImGui lacks them).
local function _ui_begin_disabled(ctx, cond)
  if reaper.ImGui_BeginDisabled then reaper.ImGui_BeginDisabled(ctx, cond) end
end
local function _ui_end_disabled(ctx)
  if reaper.ImGui_EndDisabled then reaper.ImGui_EndDisabled(ctx) end
end

local function log_append(line)
  if not line or line == "" then return end
  _log_buffer[#_log_buffer + 1] = line
  if #_log_buffer > 500 then table.remove(_log_buffer, 1) end
end

local function ui_set_banner(kind, text) _ui_banner = { kind = kind, text = text } end
local function ui_clear_banner() _ui_banner = nil end

-- Version-safe child-window border flag. ReaImGui renamed this across
-- releases (ChildFlags_Border → ChildFlags_Borders).
local function _child_border_flag()
  if reaper.ImGui_ChildFlags_Borders then return reaper.ImGui_ChildFlags_Borders() end
  if reaper.ImGui_ChildFlags_Border  then return reaper.ImGui_ChildFlags_Border()  end
  return 0
end

-- Robust ReaImGui detection. Some installs expose the symbol but the
-- extension isn't fully loaded — pcall a real CreateContext to be sure.
local function imgui_available()
  if reaper.APIExists and reaper.APIExists('ImGui_CreateContext') then
    return true
  end
  if reaper.ImGui_CreateContext ~= nil then
    local ok, ctx = pcall(reaper.ImGui_CreateContext, 'probe')
    if ok and ctx then
      if reaper.ImGui_DestroyContext then pcall(reaper.ImGui_DestroyContext, ctx) end
      return true
    end
  end
  return false
end

-- Each language code → its Unicode script, to pick the right Noto font.
local _LANG_TO_SCRIPT = {
  hi = "Devanagari", ne = "Devanagari", mr = "Devanagari",
  bn = "Bengali", ta = "Tamil", te = "Telugu",
  kn = "Kannada", ml = "Malayalam", gu = "Gujarati",
}

-- Attach a font that covers the configured DUB_LANGUAGE script so Indic log
-- lines render with proper glyphs. Falls back to the default font.
local function _attach_unicode_font(ctx)
  if not reaper.ImGui_CreateFont then return nil end
  local script = _LANG_TO_SCRIPT[DUB_LANGUAGE or ""] or "Devanagari"
  local paths = {}
  if reaper.GetOS():match("Win") then
    local local_fonts = (os.getenv("LOCALAPPDATA") or "")
                         :gsub("\\", "/") .. "/Microsoft/Windows/Fonts"
    paths[#paths+1] = local_fonts .. "/NotoSerif" .. script .. "-Regular.ttf"
    paths[#paths+1] = "C:/Windows/Fonts/NotoSerif" .. script .. "-Regular.ttf"
    paths[#paths+1] = local_fonts .. "/NotoSans"  .. script .. "-Regular.ttf"
    paths[#paths+1] = "C:/Windows/Fonts/NotoSans"  .. script .. "-Regular.ttf"
    paths[#paths+1] = "C:/Windows/Fonts/Nirmala.ttf"   -- all-Indic system font
    paths[#paths+1] = "C:/Windows/Fonts/NirmalaB.ttf"
    paths[#paths+1] = "C:/Windows/Fonts/segoeui.ttf"
  else
    paths = {
      '/Library/Fonts/NotoSerif'..script..'-Regular.ttf',
      '/Library/Fonts/NotoSans'..script..'-Regular.ttf',
      '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
      '/Library/Fonts/Arial Unicode.ttf',
    }
  end
  for _, p in ipairs(paths) do
    local fh = io.open(p, 'rb')
    if fh then
      fh:close()
      local ok, font = pcall(reaper.ImGui_CreateFont, p, 16)
      if ok and font then
        if pcall(reaper.ImGui_Attach, ctx, font) then
          log_append("[font] loaded " .. p)
          return font
        end
      end
    end
  end
  log_append("[font] no Indic font found; default font will be used")
  return nil
end

-- Open a file/URL with the OS default handler.
local function open_path(path)
  if reaper.CF_ShellExecute then reaper.CF_ShellExecute(path)
  elseif reaper.GetOS():match('Win') then os.execute('start "" "' .. path .. '"')
  elseif reaper.GetOS():match('OSX') or reaper.GetOS():match('macOS') then
    os.execute('open "' .. path .. '"')
  else os.execute('xdg-open "' .. path .. '"') end
end
local function open_url(url) open_path(url) end

-- Try to install ReaImGui via ReaPack's Lua API (when ReaPack is present).
-- ReaPack has no public "silently install one package" call — the closest we
-- can do without pulling the entire ReaTeam repo is: add the repo, refresh its
-- index, then open Browse Packages pre-filtered to ReaImGui so the user only
-- has to click Install → Apply → restart. Returns true if that flow ran.
local REAIMGUI_REPO_URL = "https://github.com/ReaTeam/Extensions/raw/master/index.xml"
local function try_reapack_install()
  if not (reaper.APIExists and reaper.APIExists('ReaPack_AddSetRepository')) then
    return false
  end
  -- Add (or re-enable) the ReaTeam Extensions repo. Signature:
  --   ReaPack_AddSetRepository(name, url, enable, autoInstall)  -> bool, error
  -- autoInstall: 0=manual, 1=when synchronizing, 2=obey user setting.
  -- Per the ReaPack API docs: "usually set to 2". Anything else (e.g. -1)
  -- fails with "invalid value for autoInstall".
  local ok, err = reaper.ReaPack_AddSetRepository(
    'ReaTeam Extensions', REAIMGUI_REPO_URL, true, 2)
  if not ok then
    reaper.ShowMessageBox(
      "Could not add the ReaImGui repository automatically:\n" ..
      tostring(err) .. "\n\nFalling back to manual steps.",
      "ReaPack", 0)
    return false
  end
  -- Persist the repo change and refresh its index so the package shows up.
  if reaper.APIExists('ReaPack_ProcessQueue') then
    pcall(reaper.ReaPack_ProcessQueue, true)
  end
  -- Open the package browser filtered to ReaImGui for the final click.
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

-- Pick the ReaPack release asset matching this REAPER build. GetAppVersion()
-- returns e.g. "7.27/macOS-arm64", "7.27/OSX64", "7.27/x64", "6.82/win64",
-- "7.27/linux-x86_64". Returns nil for builds we can't map.
local function _reapack_asset()
  local v = (reaper.GetAppVersion() or ""):lower()
  local os_str = reaper.GetOS()
  if os_str:match("Win") then
    if v:match("arm64") then return "reaper_reapack-arm64ec.dll" end
    if v:match("x64") or v:match("win64") then return "reaper_reapack-x64.dll" end
    return "reaper_reapack-x86.dll"
  elseif os_str:match("OSX") or os_str:match("macOS") then
    if v:match("arm64") then return "reaper_reapack-arm64.dylib" end
    return "reaper_reapack-x86_64.dylib"
  else -- Linux
    if v:match("aarch64") then return "reaper_reapack-aarch64.so" end
    if v:match("armv7") then return "reaper_reapack-armv7l.so" end
    if v:match("i686") then return "reaper_reapack-i686.so" end
    return "reaper_reapack-x86_64.so"
  end
end

-- ReaPack itself is missing: download its extension binary straight into
-- REAPER's UserPlugins folder with curl (bundled on Windows 10+/macOS).
-- After a REAPER restart, ReaPack is live and try_reapack_install() can take
-- over. Returns true if the download succeeded.
local function try_reapack_bootstrap()
  local asset = _reapack_asset()
  if not asset or not reaper.ExecProcess then return false end
  local res = reaper.GetResourcePath()
  local sep = package.config:sub(1, 1)
  local dir = res .. sep .. "UserPlugins"
  reaper.RecursiveCreateDirectory(dir, 0)
  local dest = dir .. sep .. asset
  local url  = "https://github.com/cfillion/reapack/releases/latest/download/" .. asset
  -- Full path on macOS/Linux — ExecProcess may not search a login-shell PATH.
  local curl = reaper.GetOS():match("Win") and "curl.exe" or "/usr/bin/curl"
  local ret = reaper.ExecProcess(
    curl .. ' -fsSL --retry 2 -o "' .. dest .. '" "' .. url .. '"', 120000)
  local code = ret and ret:match("^(%-?%d+)")
  -- Sanity: exit 0 and a plausibly-sized binary (assets are ~2 MB).
  local f = io.open(dest, "rb")
  local size = 0
  if f then size = f:seek("end") or 0; f:close() end
  if code ~= "0" or size < 500000 then
    os.remove(dest)
    return false
  end
  return true
end

-- Combo helper: items as a table, returns (changed, new_value).
local function _ui_combo(ctx, label, current, items)
  local idx = 0
  for i, v in ipairs(items) do if v == current then idx = i - 1 break end end
  local rv, new_idx = reaper.ImGui_Combo(ctx, label, idx, table.concat(items, "\0") .. "\0")
  if rv then return true, items[new_idx + 1] end
  return false, current
end

-- Colored banner across the top of the window.
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
  local frames = { '|','/','-','\\' }
  return frames[math.floor(os.clock() * 8) % #frames + 1]
end

-- Cancel a running sync by killing the worker PID that run_sync.py published.
-- Dir is resolved inline (get_script_dir is defined later in the file).
local function cancel_python()
  if _ui_cancelled then return end
  _ui_cancelled = true
  local info = debug.getinfo(1, 'S')
  local src  = info.source:match('@(.+)') or ''
  local dir  = src:match('(.+)[/\\]') or '.'
  local f = io.open(dir .. '/sync_python_pid.txt', 'r')
  if not f then return end
  local pid = (f:read('*a') or ''):match('(%d+)')
  f:close()
  if not pid then return end
  if reaper.GetOS():match('Win') then
    -- /T kills the whole tree (run_sync.py's child matcher included).
    os.execute(string.format('taskkill /F /T /PID %s > nul 2>&1', pid))
  else
    os.execute(string.format('kill -9 %s 2>/dev/null', pid))
  end
end


-- ═══════════════════════════════════════════════════════════
-- UTILITY FUNCTIONS
-- ═══════════════════════════════════════════════════════════

local function log(msg)
  reaper.ShowConsoleMsg(msg .. "\n")
  log_append(msg)   -- mirror into the GUI Logs tab
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

-- Resolve a Python *command* to a real interpreter path by RUNNING it.
-- io.open() resolves relative names against REAPER's cwd, never the PATH,
-- so bare names like "python" can only be validated by execution. This also
-- rejects the Microsoft Store placeholder alias that stock Windows 10/11
-- puts on the PATH: it opens fine as a file, but running it with arguments
-- just prints "Python was not found" and exits non-zero.
local function probe_python(cmd)
  if not reaper.ExecProcess then return nil end
  local ret = reaper.ExecProcess(
    cmd .. ' -c "import sys;print(sys.executable)"', 15000)
  if not ret then return nil end
  -- ExecProcess returns "<exit code>\n<output>".
  local code, out = ret:match("^(%-?%d+)[\r\n]+(.*)$")
  if code ~= "0" or not out then return nil end
  local path = out:match("^%s*([^\r\n]+)")
  if path then path = path:gsub("%s+$", "") end
  if path and path ~= "" and file_exists(path) then return path end
  return nil
end

-- Returns the first working python path among the candidates, or nil.
local function find_python()
  local script_dir = get_script_dir()

  -- 1. User-pinned override (loaded from settings.json) takes priority.
  if PYTHON_CMD ~= "" then
    if file_exists(PYTHON_CMD) then return PYTHON_CMD end
    -- A bare command name ("python", "py", "py -3") can't be checked with
    -- io.open — resolve it against the PATH by executing it. A value with a
    -- space is a command plus args: pass it raw, not quoted as one token.
    if not PYTHON_CMD:find("[/\\]") then
      local probe_cmd = PYTHON_CMD:find("%s") and PYTHON_CMD
                        or ('"' .. PYTHON_CMD .. '"')
      local resolved = probe_python(probe_cmd)
      if resolved then return resolved end
    end
  end

  local sep = _is_windows() and "\\" or "/"
  local bin = _is_windows() and "Scripts\\python.exe" or "bin/python3"

  -- 2. Local venv next to this script — what setup.bat / setup.sh create.
  local local_venv = script_dir .. sep .. "venv" .. sep .. bin
  if file_exists(local_venv) then return local_venv end

  -- 3. Common system installs (fallback when the venv is missing — the thin
  --    client needs only the standard library, so any Python 3 works).
  if _is_windows() then
    -- No fixed install path on Windows: resolve via the PATH by execution.
    -- "py -3" is the official launcher and exists even when python.exe is
    -- only the Store stub; sys.executable gives the real interpreter path.
    for _, c in ipairs({ 'py -3', 'python', 'python3' }) do
      local resolved = probe_python(c)
      if resolved then return resolved end
    end
  else
    local candidates = {
      "/opt/homebrew/bin/python3",         -- Apple Silicon Homebrew
      "/usr/local/bin/python3",            -- Intel Homebrew
      "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
      "/opt/homebrew/Cellar/python@3.13/3.13.12_1/bin/python3.13",
      "/usr/bin/python3",                  -- system
    }
    for _, c in ipairs(candidates) do
      if file_exists(c) then return c end
    end
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
    -- If this install was made with --direct, rebuild it the same way
    -- (setup.bat --direct writes the .direct-mode marker).
    local extra = file_exists(script_dir .. "\\.direct-mode") and " --direct" or ""
    -- start "<title>" cmd /k "<bat>"  → opens a console that stays up so the
    -- user can read progress/errors (setup.bat ends with pause too).
    os.execute('start "fast-syncs setup" cmd /k "\"' .. setup_bat .. '\"' ..
               extra .. '"')
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
  local extra = file_exists(script_dir .. "/.direct-mode") and " --direct" or ""
  os.execute('osascript -e \'tell application "Terminal" to do script "bash \\"' ..
             setup_sh .. '\\"' .. extra .. '"\'')
  -- We can't easily wait for the Terminal session to finish; tell user to retry.
  reaper.MB("After setup completes in the Terminal window, run this script again.",
            "Re-run after setup", 0)
  return false
end

-- Launch update.bat / update.sh in a terminal window (same pattern as
-- ensure_setup). Pulls the latest version (git) or downloads the latest
-- ZIP from GitHub, then refreshes the venv. User re-runs the script after.
local function run_updater()
  local script_dir = get_script_dir()
  if _is_windows() then
    local bat = script_dir .. "\\update.bat"
    if not file_exists(bat) then
      reaper.MB("update.bat is missing from:\n  " .. script_dir ..
                "\n\nRe-download the project from GitHub to update.",
                "Updater not found", 0)
      return
    end
    os.execute('start "fast-syncs update" cmd /k "\"' .. bat .. '\""')
  else
    local sh = script_dir .. "/update.sh"
    if not file_exists(sh) then
      reaper.MB("update.sh is missing from:\n  " .. script_dir ..
                "\n\nRe-download the project from GitHub to update.",
                "Updater not found", 0)
      return
    end
    os.execute('osascript -e \'tell application "Terminal" to do script "bash \\"' ..
               sh .. '\\""\'')
  end
  reaper.MB("The updater is running in a separate window.\n\n" ..
            "When it says 'Update complete', close this window and run the " ..
            "script again to load the new version.", "Updating", 0)
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
    -- Plain quoted command line — launched via reaper.ExecProcess(cmd, -2),
    -- which uses CreateProcess directly (no cmd.exe, no console window).
    -- The old `os.execute('start "" /b ...')` route spawned a visible
    -- console that python.exe INHERITED, so a black window sat on screen
    -- for the entire multi-minute run.
    cmd = string.format(
      '"%s" "%s" "%s" --language %s --mode %s --asr %s',
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
-- UI RENDERERS — one window, four phases (setup/running/success/failure)
-- ═══════════════════════════════════════════════════════════

-- ─── Setup phase ──────────────────────────────────────────
local function ui_phase_setup(ctx, on_start, on_cancel)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),    10.0, 10.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),   6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),    8.0, 6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(),    6.0)

  -- Hero header: gradient accent bar + title + tagline
  reaper.ImGui_Dummy(ctx, 0, 4)
  if reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddRectFilledMultiColor then
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
    local cw = reaper.ImGui_GetContentRegionAvail(ctx)
    pcall(reaper.ImGui_DrawList_AddRectFilledMultiColor, dl,
      cx, cy, cx + cw, cy + 3,
      0x55AAFFFF, 0x9966FFFF, 0x9966FFFF, 0x55AAFFFF)
  end
  reaper.ImGui_Dummy(ctx, 0, 6)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
  if _ui_font then pcall(reaper.ImGui_PushFont, ctx, _ui_font, 22) end
  reaper.ImGui_Text(ctx, 'Auto Sync Pipeline')
  if _ui_font then pcall(reaper.ImGui_PopFont, ctx) end
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
  reaper.ImGui_Text(ctx, 'Collect  →  AI Match  →  Place items on the timeline')
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_Dummy(ctx, 0, 8)
  _ui_render_banner(ctx)

  if _ui_setup_card then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x223344AA)
    if reaper.ImGui_BeginChild(ctx, '##setupcard', -1, 120, _child_border_flag()) then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFEE88FF)
      reaper.ImGui_TextWrapped(ctx, _ui_setup_card)
      reaper.ImGui_PopStyleColor(ctx)
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx)
    if reaper.ImGui_Button(ctx, 'OK, dismiss') then _ui_setup_card = nil end
    reaper.ImGui_Dummy(ctx, 0, 4)
  end

  local function _f_exists(p)
    local h = io.open(p, 'r')
    if h then h:close(); return true end
    return false
  end
  local _info = debug.getinfo(1, 'S')
  local _src  = _info.source:match('@(.+)') or ''
  local _sdir = _src:match('(.+)[/\\]') or '.'
  local has_vertex_file = _f_exists(_sdir .. '/vertex_key.json') or
                          (VERTEX_KEY_PATH ~= '' and _f_exists(VERTEX_KEY_PATH))
  local server_mode = (API_BASE or '') ~= ''

  local function _status_dot(filled, optional)
    local ww = reaper.ImGui_GetWindowWidth(ctx)
    reaper.ImGui_SameLine(ctx, ww - 38)
    local col, sym
    if filled then col, sym = 0x55DD77FF, '●'
    elseif optional then col, sym = 0x666677FF, '○'
    else col, sym = 0xFFAA55FF, '●' end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col)
    reaper.ImGui_Text(ctx, sym)
    reaper.ImGui_PopStyleColor(ctx)
  end

  local pw_flags = (_ui_show_keys and 0) or
                   (reaper.ImGui_InputTextFlags_Password and reaper.ImGui_InputTextFlags_Password() or 0)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),        0x2A3344FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), 0x3A4A66FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),  0x4A5A77FF)

  -- ── Section: Tracks & Mode ────────────────────────────
  local tracks_filled = (TRACK_VO_NAME ~= '' and TRACK_DUB_NAME ~= '')
  local tracks_open = reaper.ImGui_CollapsingHeader(ctx, '  Tracks & Mode')
  _status_dot(tracks_filled, false)
  if tracks_open then
    reaper.ImGui_Indent(ctx, 12)
    local rv
    rv, TRACK_VO_NAME  = reaper.ImGui_InputText(ctx, 'VO track',  TRACK_VO_NAME  or '')
    rv, TRACK_DUB_NAME = reaper.ImGui_InputText(ctx, 'Dub track', TRACK_DUB_NAME or '')
    _, DUB_LANGUAGE = _ui_combo(ctx, 'Language',   DUB_LANGUAGE,
        { 'hi','ne','ta','te','bn','mr','gu','kn','ml' })
    -- Match mode is locked: Gemini semantic matching only. On failure the
    -- run errors out — there is deliberately no hybrid/duration fallback.
    MATCH_MODE = "gemini"
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
    reaper.ImGui_Text(ctx, 'Match mode: gemini (semantic — only mode; fails hard, no fallback)')
    reaper.ImGui_PopStyleColor(ctx)
    -- ASR trimmed to what this backend supports (see sync_matcher.py).
    _, ASR_PROVIDER = _ui_combo(ctx, 'Transcribe with', ASR_PROVIDER,
        { 'elevenlabs','gemini' })
    reaper.ImGui_Unindent(ctx, 12)
    reaper.ImGui_Dummy(ctx, 0, 4)
  end

  -- ── Section: Server (thin client) ─────────────────────
  local server_open = reaper.ImGui_CollapsingHeader(ctx, '  Server (thin client — optional)')
  _status_dot(server_mode, true)
  if server_open then
    reaper.ImGui_Indent(ctx, 12)
    local rv
    rv, API_BASE  = reaper.ImGui_InputText(ctx, 'Server URL',  API_BASE  or '')
    rv, API_TOKEN = reaper.ImGui_InputText(ctx, 'Access token', API_TOKEN or '', pw_flags)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
    reaper.ImGui_TextWrapped(ctx, 'Set a Server URL to route every AI call through your proxy — the real keys stay server-side and nothing secret lives on this machine. Leave blank for direct mode with your own keys below.')
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Unindent(ctx, 12)
    reaper.ImGui_Dummy(ctx, 0, 4)
  end

  -- ── Section: Gemini matcher ───────────────────────────
  local gemini_filled = (GEMINI_MODEL or '') ~= ''
  local gemini_open = reaper.ImGui_CollapsingHeader(ctx, '  Gemini matcher')
  _status_dot(gemini_filled, false)
  if gemini_open then
    reaper.ImGui_Indent(ctx, 12)
    local rv
    _, GEMINI_BACKEND   = _ui_combo(ctx, 'Backend', GEMINI_BACKEND, { 'vertex','rest','gateway' })
    rv, GEMINI_MODEL    = reaper.ImGui_InputText(ctx, 'Model',            GEMINI_MODEL    or '')
    if GEMINI_BACKEND == 'gateway' then
      rv, GEMINI_BASE_URL = reaper.ImGui_InputText(ctx, 'Gateway URL',    GEMINI_BASE_URL or '')
    end
    rv, VERTEX_KEY_PATH = reaper.ImGui_InputText(ctx, 'Vertex JSON path', VERTEX_KEY_PATH or '')
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
    reaper.ImGui_TextWrapped(ctx, 'vertex = Google service account (vertex_key.json). rest = AI Studio key (AIza…). gateway = OpenAI-compatible proxy (Bearer key + Gateway URL).')
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Unindent(ctx, 12)
    reaper.ImGui_Dummy(ctx, 0, 4)
  end

  -- ── Section: API keys ─────────────────────────────────
  local keys_filled = server_mode or has_vertex_file or (GEMINI_KEY or '') ~= ''
  if not server_mode and ASR_PROVIDER == 'elevenlabs' then
    keys_filled = keys_filled and (ELEVENLABS_KEY or '') ~= ''
  end
  local keys_open = reaper.ImGui_CollapsingHeader(ctx, '  API keys')
  _status_dot(keys_filled, server_mode)
  if keys_open then
    reaper.ImGui_Indent(ctx, 12)
    local rv
    rv, GEMINI_KEY = reaper.ImGui_InputText(ctx, 'Gemini key', GEMINI_KEY or '', pw_flags)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
    if server_mode then
      reaper.ImGui_TextWrapped(ctx, 'Server mode is on — provider keys are optional here (the server holds them).')
    elseif GEMINI_BACKEND == 'gateway' then
      reaper.ImGui_TextWrapped(ctx, 'Gateway Bearer token (often sk-…). Goes in this field.')
    elseif has_vertex_file then
      reaper.ImGui_TextWrapped(ctx, '✓ vertex_key.json found — Gemini key is optional.')
    else
      reaper.ImGui_TextWrapped(ctx, 'AI matcher. Required unless vertex_key.json is present.')
    end
    reaper.ImGui_PopStyleColor(ctx)

    if ASR_PROVIDER == 'elevenlabs' then
      rv, ELEVENLABS_KEY = reaper.ImGui_InputText(ctx, 'ElevenLabs key', ELEVENLABS_KEY or '', pw_flags)
    else  -- gemini ASR
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
      reaper.ImGui_TextWrapped(ctx, 'Gemini ASR reuses the Gemini key above (or vertex_key.json).')
      reaper.ImGui_PopStyleColor(ctx)
    end

    rv, _ui_show_keys = reaper.ImGui_Checkbox(ctx, 'Show keys', _ui_show_keys)
    reaper.ImGui_Unindent(ctx, 12)
    reaper.ImGui_Dummy(ctx, 0, 4)
  end

  -- ── Section: Dubbing script (optional) ────────────────
  local script_filled = (SCRIPT_TEXT or '') ~= ''
  local script_open = reaper.ImGui_CollapsingHeader(ctx, '  Dubbing script (optional)')
  _status_dot(script_filled, true)
  if script_open then
    reaper.ImGui_Indent(ctx, 12)
    local rv
    rv, SCRIPT_TEXT = reaper.ImGui_InputTextMultiline(
      ctx, '##script', SCRIPT_TEXT or '', -1, 140)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x8899AAFF)
    if SCRIPT_TEXT and SCRIPT_TEXT ~= '' then
      reaper.ImGui_Text(ctx, string.format('%d chars · paragraphs preserved', #SCRIPT_TEXT))
    else
      reaper.ImGui_Text(ctx, 'Paste dubbing script here (improves Gemini matching).')
    end
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Unindent(ctx, 12)
    reaper.ImGui_Dummy(ctx, 0, 4)
  end

  reaper.ImGui_PopStyleColor(ctx, 3)
  reaper.ImGui_Dummy(ctx, 0, 10)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 4)

  -- ── Validate before enabling Start ────────────────────
  local missing = {}
  if TRACK_VO_NAME  == '' then missing[#missing+1] = 'VO track name'  end
  if TRACK_DUB_NAME == '' then missing[#missing+1] = 'Dub track name' end
  if not server_mode then
    if GEMINI_BACKEND == 'gateway' then
      if (GEMINI_BASE_URL or '') == '' then missing[#missing+1] = 'Gemini gateway URL' end
      if (GEMINI_KEY or '')      == '' then missing[#missing+1] = 'Gemini key (gateway Bearer token)' end
    elseif not has_vertex_file and (GEMINI_KEY or '') == '' then
      missing[#missing+1] = 'Gemini key (or vertex_key.json)'
    end
    if ASR_PROVIDER == 'elevenlabs' and (ELEVENLABS_KEY or '') == '' then
      missing[#missing+1] = 'ElevenLabs key'
    end
  end

  local _disabled = (#missing > 0)
  _ui_begin_disabled(ctx, _disabled)
  local t = os.clock()
  local pulse = 0.5 + 0.5 * math.sin(t * 3.0)
  local r = math.floor(0x22 + pulse * 0x18)
  local g = math.floor(0x88 + pulse * 0x30)
  local b = math.floor(0x33 + pulse * 0x18)
  local idle_col = (r * 0x1000000) + (g * 0x10000) + (b * 0x100) + 0xFF
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        idle_col)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x44CC55FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x119911FF)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 12.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 16.0, 10.0)
  if reaper.ImGui_Button(ctx, '▶  Start Sync', 220, 44) then on_start() end
  reaper.ImGui_PopStyleVar(ctx, 2)
  reaper.ImGui_PopStyleColor(ctx, 3)
  _ui_end_disabled(ctx)

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 12.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 16.0, 10.0)
  if reaper.ImGui_Button(ctx, 'Cancel', 120, 44) then on_cancel() end
  reaper.ImGui_PopStyleVar(ctx, 2)

  if _disabled then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFAA55FF)
    reaper.ImGui_TextWrapped(ctx, 'Missing: ' .. table.concat(missing, ', '))
    reaper.ImGui_PopStyleColor(ctx)
  end

  -- Footer summary chips
  reaper.ImGui_Dummy(ctx, 0, 8)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x667788FF)
  local sep = '   ·   '
  local backend_label = server_mode and ('server:' .. API_BASE) or (GEMINI_BACKEND or '?')
  local chips = string.format('%s%s%s%s%s%s%s',
    DUB_LANGUAGE or '?', sep, GEMINI_MODEL or '?', sep,
    backend_label, sep, ASR_PROVIDER or '?')
  reaper.ImGui_Text(ctx, chips)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_SmallButton(ctx, 'Update...') then run_updater() end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Get the latest version (runs update.bat / update.sh in a terminal).')
  end

  reaper.ImGui_PopStyleVar(ctx, 4)
end

-- ─── Running phase (progress bar + Progress/Logs tabs) ────
local function ui_phase_running(ctx, elapsed_s)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x55AAFFFF)
  reaper.ImGui_Text(ctx, _spinner_glyph() .. '  Running...')
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_SameLine(ctx)

  local time_str = string.format('  %02d:%02d elapsed',
    math.floor(elapsed_s / 60), elapsed_s % 60)
  if _ui_progress > 0.05 and _ui_progress < 0.99 then
    local eta_s = math.floor(elapsed_s * (1.0 - _ui_progress) / _ui_progress)
    time_str = time_str .. string.format('  ·  ETA ~%02d:%02d',
      math.floor(eta_s / 60), eta_s % 60)
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xAAAAAAFF)
  reaper.ImGui_Text(ctx, time_str)
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x883333FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xAA4444FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x661111FF)
  if reaper.ImGui_Button(ctx, 'Cancel', 80, 0) then cancel_python() end
  reaper.ImGui_PopStyleColor(ctx, 3)

  reaper.ImGui_Dummy(ctx, 0, 4)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PlotHistogram(), 0x3388FFFF)
  reaper.ImGui_ProgressBar(ctx, _ui_progress, -1, 22,
    string.format('%.0f%%', _ui_progress * 100))
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Dummy(ctx, 0, 4)

  if reaper.ImGui_BeginTabBar(ctx, '##runtabs') then
    if reaper.ImGui_BeginTabItem(ctx, 'Progress') then
      reaper.ImGui_Dummy(ctx, 0, 6)
      local steps = {
        'Step 1/3 -- Writing config',
        'Step 2/3 -- AI matching (Python)',
        'Step 3/3 -- Applying to timeline',
      }
      for i, label in ipairs(steps) do
        local done   = (_ui_step_idx > i)
        local active = (_ui_step_idx == i)
        local color  = done and 0x55DD55FF or (active and 0xFFCC55FF or 0x666666FF)
        local mark   = done and '[done]' or (active and '[-->]' or '[ ]')
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color)
        reaper.ImGui_Text(ctx, mark .. '  ' .. label)
        reaper.ImGui_PopStyleColor(ctx)
      end
      if _ui_step_idx == 2 then
        reaper.ImGui_Dummy(ctx, 0, 8)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xAAAAAAFF)
        if _poll_step_phase == 1 and _ui_en_total > 0 then
          reaper.ImGui_Text(ctx, string.format('    Transcribing EN clips : %d / %d', _ui_en_done, _ui_en_total))
        elseif _poll_step_phase == 2 and _ui_dub_total > 0 then
          reaper.ImGui_Text(ctx, string.format('    Transcribing DUB clips: %d / %d', _ui_dub_done, _ui_dub_total))
        elseif _poll_step_phase == 3 then
          reaper.ImGui_Text(ctx, '    Waiting for AI matcher response...')
        elseif _poll_step_phase == 4 then
          reaper.ImGui_Text(ctx, '    Placing clips on timeline...')
        end
        reaper.ImGui_PopStyleColor(ctx)
      end
      reaper.ImGui_EndTabItem(ctx)
    end

    if reaper.ImGui_BeginTabItem(ctx, 'Logs') then
      if reaper.ImGui_BeginChild(ctx, '##loglines', -1, -30, _child_border_flag()) then
        if _ui_font then pcall(reaper.ImGui_PushFont, ctx, _ui_font, 16) end
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBBBBBFF)
        local start = math.max(1, #_log_buffer - 200)
        for i = start, #_log_buffer do
          reaper.ImGui_Text(ctx, _log_buffer[i])
        end
        reaper.ImGui_PopStyleColor(ctx)
        if _ui_font then pcall(reaper.ImGui_PopFont, ctx) end
        if _log_autoscroll then reaper.ImGui_SetScrollHereY(ctx, 1.0) end
        reaper.ImGui_EndChild(ctx)
      end
      local rv
      rv, _log_autoscroll = reaper.ImGui_Checkbox(ctx, 'Auto-scroll', _log_autoscroll)
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, 'Open log in editor') then
        if _poll_log_path then open_path(_poll_log_path) end
      end
      reaper.ImGui_EndTabItem(ctx)
    end
    reaper.ImGui_EndTabBar(ctx)
  end
end

-- ─── Success phase ────────────────────────────────────────
local function ui_phase_success(ctx, on_close)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x55DD55FF)
  reaper.ImGui_Text(ctx, '✓  Successful')
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 8)

  if _ui_result then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xDDDDDDFF)
    reaper.ImGui_Text(ctx, _ui_result)
    reaper.ImGui_PopStyleColor(ctx)
  end

  if #_ui_results_rows > 0 then
    reaper.ImGui_Dummy(ctx, 0, 8)
    local hdr = string.format('Per-clip results (%d)', #_ui_results_rows)
    if reaper.ImGui_CollapsingHeader(ctx, hdr) then
      local tflags = 0
      if reaper.ImGui_TableFlags_Borders   then tflags = tflags | reaper.ImGui_TableFlags_Borders() end
      if reaper.ImGui_TableFlags_RowBg     then tflags = tflags | reaper.ImGui_TableFlags_RowBg()    end
      if reaper.ImGui_TableFlags_ScrollY   then tflags = tflags | reaper.ImGui_TableFlags_ScrollY()  end
      if reaper.ImGui_TableFlags_Resizable then tflags = tflags | reaper.ImGui_TableFlags_Resizable() end
      if reaper.ImGui_BeginTable(ctx, '##results', 3, tflags, 0, 240) then
        reaper.ImGui_TableSetupColumn(ctx, 'Dub #')
        reaper.ImGui_TableSetupColumn(ctx, 'Status')
        reaper.ImGui_TableSetupColumn(ctx, 'New pos (s)')
        reaper.ImGui_TableHeadersRow(ctx)
        for _, r in ipairs(_ui_results_rows) do
          reaper.ImGui_TableNextRow(ctx)
          reaper.ImGui_TableSetColumnIndex(ctx, 0)
          reaper.ImGui_Text(ctx, tostring(r.dub_id or '?'))
          reaper.ImGui_TableSetColumnIndex(ctx, 1)
          local color = 0xAAAAAAFF
          if r.status == 'matched'      then color = 0x55DD55FF
          elseif r.status == 'unmatched' then color = 0xFFAA55FF
          elseif r.status == 'missing_file' then color = 0xFF5555FF end
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color)
          reaper.ImGui_Text(ctx, r.status or '-')
          reaper.ImGui_PopStyleColor(ctx)
          reaper.ImGui_TableSetColumnIndex(ctx, 2)
          reaper.ImGui_Text(ctx, r.new_position and string.format('%.3f', r.new_position) or '-')
        end
        reaper.ImGui_EndTable(ctx)
      end
    end
  end

  reaper.ImGui_Dummy(ctx, 0, 12)
  reaper.ImGui_Separator(ctx)
  if reaper.ImGui_Button(ctx, 'Close', 120, 32) then on_close() end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Run again', 120, 32) then
    _ui_phase = 'setup'; _log_buffer = {}; _ui_result = nil
    _ui_step_idx = 0; _ui_progress = 0.0
    _ui_en_total = 0; _ui_dub_total = 0; _ui_en_done = 0; _ui_dub_done = 0
    _poll_step_phase = 0; _ui_cancelled = false; _ui_results_rows = {}
  end
end

-- ─── Failure phase ────────────────────────────────────────
local function ui_phase_failure(ctx, on_close)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF5555FF)
  reaper.ImGui_Text(ctx, '✗  Failed')
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 8)

  if _ui_failure then
    reaper.ImGui_Text(ctx, 'Error output (tail):')
    if reaper.ImGui_BeginChild(ctx, '##errtail', -1, 240, _child_border_flag()) then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFAAAAFF)
      reaper.ImGui_Text(ctx, _ui_failure.error_tail or '(no output)')
      reaper.ImGui_PopStyleColor(ctx)
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_Dummy(ctx, 0, 6)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xAAAAAAFF)
    reaper.ImGui_TextWrapped(ctx,
      'Common fixes:\n  re-run setup.bat / setup.sh (rebuilds the venv)\n  for direct mode: setup.bat --direct')
    reaper.ImGui_Text(ctx, 'Full log: ' .. (_ui_failure.log_path or ''))
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_Dummy(ctx, 0, 12)
  reaper.ImGui_Separator(ctx)
  if reaper.ImGui_Button(ctx, 'Close', 120, 32) then on_close() end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Back to setup', 140, 32) then
    _ui_phase = 'setup'; _ui_failure = nil; _ui_progress = 0.0
    _ui_en_total = 0; _ui_dub_total = 0; _ui_en_done = 0; _ui_dub_done = 0
    _poll_step_phase = 0; _ui_cancelled = false; _ui_results_rows = {}
  end
end


-- ═══════════════════════════════════════════════════════════
-- LIVE LOG TAIL + RESULT HANDLING
-- ═══════════════════════════════════════════════════════════

local function on_python_done(success)
  if not success then return end

  _ui_step_idx     = 3
  _poll_step_phase = 4
  _ui_progress     = 0.92
  _ui_step_label   = "Applying to timeline..."
  log("\n[STEP 3] Applying results to timeline...")

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local moved, unmatched = apply_results(_poll_results_path, _poll_dub_items)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Auto Sync Pipeline", -1)

  _ui_progress = 1.0

  -- Summary shown on the success phase of the GUI.
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
      "Tip: use Sync_Item.lua to manually fix\n"  ..
      "any remaining unmatched items.",
      elapsed, s.total_en, s.matched, s.total_dub,
      s.unmatched, TRACK_UNSYNC,
      s.model, s.language, s.backend)
  else
    msg = string.format(
      "Done in %ds!\n\nMoved: %d\nUnmatched: %d\n\n" ..
      'Unmatched items are on "%s" track.',
      elapsed, moved, unmatched, TRACK_UNSYNC)
  end

  _ui_result = msg
  _ui_phase  = "success"
end

-- Poll the log/done files. Driven by the ImGui frame loop (NOT reaper.defer)
-- so log appends + spinner stay in sync with rendering. Updates UI state and
-- flips _ui_phase to success/failure when the run ends.
local function poll_python_step()
  -- Read new log content → console + UI buffer, and advance progress.
  local f = io.open(_poll_log_path, "r")
  if f then
    local content = f:read("*a")
    f:close()
    if content and #content > _poll_last_size then
      local new_text = content:sub(_poll_last_size + 1)
      for line in new_text:gmatch("([^\n]*)\n?") do
        if line and line ~= "" then
          reaper.ShowConsoleMsg("  " .. line .. "\n")
          log_append("  " .. line)
          if line:find("STEP 1", 1, true) then
            _ui_step_idx = math.max(_ui_step_idx, 1); _poll_step_phase = 1
            _ui_progress = math.max(_ui_progress, 0.08)
          end
          if line:find("STEP 2", 1, true) then
            _ui_step_idx = math.max(_ui_step_idx, 2); _poll_step_phase = 2
            _ui_progress = math.max(_ui_progress, 0.40)
          end
          if line:find("STEP 3", 1, true) then
            _poll_step_phase = 3; _ui_progress = math.max(_ui_progress, 0.75)
          end
          if line:find("STEP 4", 1, true) then
            _poll_step_phase = 4; _ui_progress = math.max(_ui_progress, 0.88)
          end
          if line:match("%[%s*%d+%]%s+\"") then
            if _poll_step_phase == 1 then
              _ui_en_done = _ui_en_done + 1
              if _ui_en_total > 0 then
                _ui_progress = math.max(_ui_progress,
                  0.08 + (_ui_en_done / _ui_en_total) * 0.32)
              end
            elseif _poll_step_phase == 2 then
              _ui_dub_done = _ui_dub_done + 1
              if _ui_dub_total > 0 then
                _ui_progress = math.max(_ui_progress,
                  0.40 + (_ui_dub_done / _ui_dub_total) * 0.35)
              end
            end
          end
        end
      end
      _poll_last_size = #content
    end
  end

  -- Done? (done file present with exit code)
  local df = io.open(_poll_done_path, "r")
  if df then
    local exit_code_str = df:read("*a")
    df:close()
    if exit_code_str and exit_code_str:match("%d") then
      local exit_code = tonumber(exit_code_str:match("(%d+)"))
      local f2 = io.open(_poll_log_path, "r")
      if f2 then
        local final = f2:read("*a")
        f2:close()
        if final and #final > _poll_last_size then
          for line in final:sub(_poll_last_size + 1):gmatch("([^\n]*)\n?") do
            if line and line ~= "" then
              reaper.ShowConsoleMsg("  " .. line .. "\n")
              log_append("  " .. line)
            end
          end
        end
      end

      local elapsed = os.time() - _poll_start_time
      log(string.format("\n──── Python finished in %ds (exit code %d) ────",
        elapsed, exit_code or -1))
      os.remove(_poll_done_path)

      if (exit_code == 0) and file_exists(_poll_results_path) then
        on_python_done(true)
      else
        local python_log = read_file(_poll_log_path) or "(no output)"
        local short_log = python_log
        if #short_log > 1200 then short_log = "...\n" .. short_log:sub(-1200) end
        if _ui_cancelled then
          _ui_failure = { error_tail = "Cancelled by user.\n\n" .. short_log,
                          log_path = _poll_log_path }
        else
          _ui_failure = { error_tail = short_log, log_path = _poll_log_path }
        end
        _ui_phase = "failure"
      end
      return
    end
  end

  -- Watchdog: run_sync.py writes its "[run_sync] launching:" line within a
  -- couple of seconds of a successful start. If the log is still empty after
  -- 90 s, the launch failed in a way we couldn't detect — surface it instead
  -- of spinning the spinner forever.
  if _poll_last_size == 0 and (os.time() - _poll_start_time) > 90 then
    log("\nERROR: no output from Python after 90 s — launch likely failed.")
    _ui_failure = {
      error_tail = "Python produced no output for 90 seconds — the launch " ..
                   "probably failed.\n\nThings to check:\n" ..
                   "  - the venv exists (re-run setup if it was deleted)\n" ..
                   "  - the interpreter path is valid",
      log_path = _poll_log_path,
    }
    _ui_phase = "failure"
    return
  end
end


-- ═══════════════════════════════════════════════════════════
-- ORCHESTRATION — validate inputs and launch the Python matcher
-- ═══════════════════════════════════════════════════════════
-- Called when the user clicks "Start Sync". Returns true if Python was
-- launched and the UI should switch to the running phase; false (with a
-- banner set) to stay on the setup form.
local function start_sync_run()
  ui_clear_banner()
  save_settings()
  reaper.ClearConsole()
  _log_buffer = {}

  -- ── Auto-detect Python ────────────────────────────────
  local py = find_python()
  if not py then
    if not ensure_setup() then return false end
    py = find_python()
    if not py then
      ui_set_banner("error",
        "Could not find a Python interpreter even after setup. " ..
        (_is_windows()
          and "Install Python 3.11+ (python.org) and re-run setup.bat."
          or  "Install Python 3.11+ and re-run setup.sh."))
      return false
    end
  end
  PYTHON_CMD = py
  log(string.format("  Python    : %s", PYTHON_CMD))

  -- ── Find tracks ───────────────────────────────────────
  local track_vo  = find_track_by_name(TRACK_VO_NAME)
  local track_dub = find_track_by_name(TRACK_DUB_NAME)
  if not track_vo then
    ui_set_banner("error", 'Track "' .. TRACK_VO_NAME ..
      '" not found. Check the name matches exactly (capital letters matter).')
    return false
  end
  if not track_dub then
    ui_set_banner("error", 'Track "' .. TRACK_DUB_NAME ..
      '" not found. Check the name matches exactly (capital letters matter).')
    return false
  end

  local vo_items  = get_items_sorted(track_vo)
  local dub_items = get_items_sorted(track_dub)
  if #vo_items == 0 then
    ui_set_banner("error", 'No items on track "' .. TRACK_VO_NAME ..
      '". Import English audio and use Dynamic Split first.')
    return false
  end
  if #dub_items == 0 then
    ui_set_banner("error", 'No items on track "' .. TRACK_DUB_NAME ..
      '". Import dubbed audio and use Dynamic Split first.')
    return false
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

  local script_dir   = get_script_dir()
  local results_path = script_dir .. "/sync_results.json"
  os.remove(results_path)

  _ui_step_idx = 1
  log("\n[STEP 1] Writing config JSON...")
  local config_path = write_config(vo_items, dub_items, results_path)
  if not config_path then
    ui_set_banner("error", "Could not write sync_config.json next to the script.")
    return false
  end
  log("  Written: " .. config_path)

  local cmd, log_path, done_path = build_python_cmd(config_path)
  if not cmd then
    ui_set_banner("error", "sync_matcher.py or run_sync.py is missing next to this script.")
    return false
  end
  os.remove(done_path)

  -- Truncate the stale log so the poller reads only this run's output.
  local lf = io.open(log_path, "w")
  if lf then lf:close() end
  -- Clear any stale PID so a Cancel can't signal a recycled, unrelated PID.
  os.remove(script_dir .. "/sync_python_pid.txt")

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

  _ui_step_idx = 2
  log("\n[STEP 2] Launching AI matcher in background...")
  log("  Mode     : " .. MATCH_MODE)
  log("  " .. asr_info)
  log("  Language : " .. DUB_LANGUAGE)
  log("  Log file : " .. log_path)
  log("\n──── Live Python output ────────────────────────────────")

  _poll_log_path     = log_path
  _poll_done_path    = done_path
  _poll_results_path = results_path
  _poll_dub_items    = dub_items
  _poll_last_size    = 0
  _poll_start_time   = os.time()

  -- Progress tracking for the running phase.
  _ui_progress     = 0.05
  _ui_en_total     = #vo_items
  _ui_dub_total    = #dub_items
  _ui_en_done      = 0
  _ui_dub_done     = 0
  _poll_step_phase = 0
  _ui_cancelled    = false
  _ui_results_rows = {}

  -- Launch (non-blocking).
  --  Windows: ExecProcess(-2) = fire-and-forget CreateProcess (no console
  --  window). Falls back to start /b on very old REAPER builds.
  --  macOS: shell launch with trailing & (needed for the redirect syntax).
  if _is_windows() then
    if reaper.ExecProcess then
      local ret = reaper.ExecProcess(cmd, -2)
      if ret == nil then
        ui_set_banner("error",
          "Could not launch Python. Check the interpreter path " ..
          "(re-run setup.bat if the venv was deleted).")
        return false
      end
    else
      os.execute('start "" /b ' .. cmd)
    end
  else
    os.execute(cmd)
  end

  _ui_phase = "running"
  return true
end


-- ═══════════════════════════════════════════════════════════
-- MAIN — single ReaImGui frame loop drives all phases
-- ═══════════════════════════════════════════════════════════

local function main()
  -- ReaImGui is required. Show a one-time install prompt and exit if missing.
  if not imgui_available() then
    -- If ReaPack is installed, offer to add the repo + open the browser for the
    -- user automatically (removes most of the manual steps).
    if reaper.APIExists and reaper.APIExists('ReaPack_AddSetRepository') then
      -- Yes / No / Cancel  (type 3): Yes = auto, No = manual steps, Cancel = quit.
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
        try_reapack_install()
        return
      elseif choice == 2 then   -- Cancel
        return
      end
      -- choice == 7 (No): fall through to the manual instructions below.
    else
      -- No ReaPack either — offer to download the ReaPack extension itself
      -- into UserPlugins, so after one restart the automatic ReaImGui flow
      -- above can run.
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
      -- No: fall through to the manual instructions below.
    end

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
    return
  end

  reaper.ClearConsole()
  _ui_ctx  = reaper.ImGui_CreateContext('Auto Sync Pipeline')
  _ui_font = _attach_unicode_font(_ui_ctx)

  local function close_window() _ui_window_open = false end

  local function frame()
    reaper.ImGui_SetNextWindowSize(_ui_ctx, 680, 720, reaper.ImGui_Cond_FirstUseEver())
    local visible, open = reaper.ImGui_Begin(_ui_ctx, 'Auto Sync Pipeline',
      true, reaper.ImGui_WindowFlags_NoCollapse())
    if visible then
      if _ui_phase == "setup" then
        ui_phase_setup(_ui_ctx, function() start_sync_run() end, close_window)
      elseif _ui_phase == "running" then
        poll_python_step()   -- refresh log/progress before rendering
        local elapsed = os.time() - _poll_start_time
        ui_phase_running(_ui_ctx, elapsed)
      elseif _ui_phase == "success" then
        ui_phase_success(_ui_ctx, close_window)
      elseif _ui_phase == "failure" then
        ui_phase_failure(_ui_ctx, close_window)
      end
    end
    reaper.ImGui_End(_ui_ctx)   -- always paired with Begin()
    _ui_window_open = _ui_window_open and open
    if _ui_window_open then
      reaper.defer(frame)
    end
    -- If the window closes mid-run the Python keeps running in the background
    -- (it still writes the log + done files); we simply stop polling.
  end

  reaper.defer(frame)
end

reaper.defer(main)
