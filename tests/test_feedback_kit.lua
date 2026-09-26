-- Offline checks for feedback_kit.lua with a fake `reaper` table.
--
-- Checks the parts that don't need a real REAPER window:
--   * archive_log puts the log next to the project, in FastSyncs_Logs/,
--     with a readable header, and keeps only the newest 50;
--   * an unsaved project falls back to <app>/logs/unsaved/;
--   * the report JSON the star card writes is valid JSON (Python parses it),
--     escapes quotes/newlines, and only carries the log for 1-3 stars.
--
-- Run:  lua tests/test_feedback_kit.lua     (needs python3 on PATH)

local fails = 0
local function check(name, cond)
  print((cond and "  PASS " or "  FAIL ") .. name)
  if not cond then fails = fails + 1 end
end

local tmp = os.tmpname(); os.remove(tmp); os.execute("mkdir -p '" .. tmp .. "'")
local proj_dir = tmp .. "/My Video"
local app_root = tmp .. "/app"
os.execute("mkdir -p '" .. proj_dir .. "' '" .. app_root .. "'")

local current_fn = proj_dir .. "/video.RPP"
local launched = {}
local ext = {}
reaper = {
  GetOS = function() return "macOS-arm64" end,
  GetAppVersion = function() return "7.20/macOS-arm64" end,
  EnumProjects = function(i) if i == -1 or i == 0 then return "P1", current_fn end end,
  ValidatePtr = function(p) return p == "P1" end,
  RecursiveCreateDirectory = function(d) os.execute("mkdir -p '" .. d .. "'") return 1 end,
  EnumerateFiles = function(dir, i)
    local h = io.popen("ls -1 '" .. dir .. "' 2>/dev/null")
    local names = {}
    for n in h:lines() do names[#names + 1] = n end
    h:close()
    return names[i + 1]
  end,
  GetExtState = function(s, k) return ext[k] or "" end,
  SetExtState = function(s, k, v) ext[k] = v end,
}
local real_execute = os.execute
os.execute = function(cmd)
  if cmd:find("--send-report", 1, true) then launched[#launched + 1] = cmd return true end
  return real_execute(cmd)
end

local here = debug.getinfo(1, "S").source:match("@(.+)[/\\]") or "."
local FB = dofile(here .. "/../feedback_kit.lua")

local live = tmp .. "/live_log.txt"
local f = io.open(live, "w"); f:write("STEP 1\nboom\n"); f:close()

-- archive next to the project
local p = FB.archive_log({ app_root = app_root, pipeline = "AutoSync",
  status = "failed", log_path = live, started = os.time() - 75,
  version = "0.15.5", project = "P1", extra = "panel said: boom" })
check("archived", p ~= nil)
check("inside project folder", p and p:find(proj_dir .. "/FastSyncs_Logs/", 1, true) == 1)
check("name has pipeline + status", p and p:match("_AutoSync_failed%.txt$") ~= nil)
local body = p and io.open(p):read("*a") or ""
check("header has version", body:find("App version : 0.15.5", 1, true) ~= nil)
check("header has duration", body:find("Duration    : 1m 15s", 1, true) ~= nil)
check("log copied", body:find("STEP 1\nboom", 1, true) ~= nil)
check("panel text appended", body:find("panel said: boom", 1, true) ~= nil)

-- pruning to 50
local dir = proj_dir .. "/FastSyncs_Logs"
for k = 1, 55 do
  local g = io.open(string.format("%s/2020-01-01_00-00-%02d_Old_ok.txt", dir, k % 60), "w")
  g:write("x"); g:close()
end
FB.archive_log({ app_root = app_root, pipeline = "AutoSync", status = "ok",
  log_path = live, started = os.time(), version = "0.15.5", project = "P1" })
local count = 0
for _ in io.popen("ls -1 '" .. dir .. "'"):lines() do count = count + 1 end
check("pruned to 50", count == 50)

-- unsaved project
current_fn = ""
local u = FB.archive_log({ app_root = app_root, pipeline = "DubFull",
  status = "failed", log_path = live, started = os.time(), version = "x" })
check("unsaved → app/logs/unsaved", u and u:find(app_root .. "/logs/unsaved/", 1, true) == 1)

-- star card report JSON
local card = FB.new_card({ app_root = app_root, get_python = function() return "/usr/bin/python3" end })
card:start({ pipeline = "Auto Sync", status = "failed", log = p,
             started = os.time() - 10, finished = os.time(), version = "0.15.5",
             project_name = 'My "quoted"\nvideo' })
card.stars = 2
card.message = 'It "broke"\nat step 2 \\ नमस्ते'
card.name = "  Asha "
card.language = "Hindi"
card:send()
check("sender launched", #launched == 1)
local rpt = launched[1] and launched[1]:match("%-%-send%-report '([^']+)'")
local check_py = io.popen("python3 -c \"import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8')); " ..
  "print(d['stars'], d['message'].count('\\n'), bool(d['log_path']), d['contact'], d['name'], d['language'])\" '" .. (rpt or "") .. "'")
local parsed = check_py:read("*a"); check_py:close()
check("report JSON parses (2 stars, newline kept, log attached)", parsed:match("^2 1 True Asha %(Hindi%) Asha Hindi") ~= nil)
check("name + language remembered", ext.name == "Asha" and ext.language == "Hindi")

-- 5 stars → no log
card:start({ pipeline = "Auto Sync", status = "ok", log = p, started = os.time(),
             finished = os.time(), version = "0.15.5", project_name = "v" })
card.stars = 5
card.attach = false          -- user unticked "Attach this run's log"
card:send()
local rpt2 = launched[2] and launched[2]:match("%-%-send%-report '([^']+)'")
local h2 = io.popen("python3 -c \"import json,sys; print(repr(json.load(open(sys.argv[1]))['log_path']))\" '" .. (rpt2 or "") .. "'")
local lp = h2:read("*a"); h2:close()
check("unticked box sends no log", lp:match("^''") ~= nil)

-- a good rating may still carry the log when the box is ticked
card:start({ pipeline = "Auto Sync", status = "ok", log = p, started = os.time(),
             finished = os.time(), version = "0.15.6", project_name = "v" })
check("box ticked by default on a new card", card.attach == true)
card.stars = 4
card:send()
local rpt3 = launched[3] and launched[3]:match("%-%-send%-report '([^']+)'")
local h3 = io.popen("python3 -c \"import json,sys; print(bool(json.load(open(sys.argv[1]))['log_path']))\" '" .. (rpt3 or "") .. "'")
local lp3 = h3:read("*a"); h3:close()
check("ticked box sends log even for 4 stars", lp3:match("^True") ~= nil)

real_execute("rm -rf '" .. tmp .. "'")
print(fails == 0 and "\nGREEN: all checks passed" or ("\nRED: " .. fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
