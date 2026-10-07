-- Offline check for the Redo pane's output-folder lookup
-- (Dub_Pipeline_Panel.lua, 0.15.10): V5.out_dir_from_item and
-- V5.prefill_regen_target, cut out of the panel and run on a fake `reaper`.
--
--   * a chunk in a flat run folder -> that folder
--   * an already-redone chunk (<run>/regen/chunk_N_vK.wav) -> the run folder,
--     not regen/ (else the next redo nests regen/regen/)
--   * a chunk in a 0.15.7–0.15.9 tidy folder -> the tidy root
--   * found even when the chunk is selected AFTER the pane first drew
--   * selecting a chunk of ANOTHER video re-points the folder (and drops the
--     old video's language)
--   * the run's language is read from the folder's engine_done.json
--
-- Run:  lua tests/test_redo_folder.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local src = io.open(here .. "/../dubbing/reaper/Dub_Pipeline_Panel.lua"):read("*a")
local function cut(sig)
  local a = assert(src:find(sig, 1, true), sig)
  local b = src:find("\nend\n", a, true)
  return src:sub(a, b + 4)
end

local fails = 0
local function check(name, cond)
  print((cond and "  PASS " or "  FAIL ") .. name)
  if not cond then fails = fails + 1 end
end

local tmp = os.tmpname(); os.remove(tmp)
local function mk(p) os.execute("mkdir -p '" .. p .. "'") end
local function put(p, s) local f = io.open(p, "wb"); f:write(s); f:close() end
local function exists(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end

local flatA = tmp .. "/Media/talk";      mk(flatA .. "/regen")
put(flatA .. "/engine_done.json", '{"status":"ok","language":"Hindi"}\n')
local flatB = tmp .. "/Other/interview"; mk(flatB)
local tidy  = tmp .. "/Proj/FastSyncs";   mk(tidy .. "/03_Voice/pieces")
put(tidy .. "/.fastsyncs-layout", "2\n")

local selected = nil     -- the selected item = its source file path
local env = {
  V5 = {}, SEP = "/", _regen_out_dir = "", _regen_lang = "", _ui_phase = "running",
  STATUS_DIR = tmp .. "/status", DONE_JSON = tmp .. "/status/none.json",
  ipairs = ipairs, io = io, string = string,
  file_exists = exists,
  basename = function(p) return p:match("([^/]+)$") or p end,
  load_manifest_json = function(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*a"); f:close()
    return { status = s:match('"status":"(.-)"') or "",
             language = s:match('"language":"(.-)"') or "", out_dir = "" }
  end,
}
env.reaper = {
  CountSelectedMediaItems = function() return selected and 1 or 0 end,
  GetSelectedMediaItem = function() return selected end,
  GetActiveTake = function(it) return it end,
  TakeIsMIDI = function() return false end,
  GetMediaItemTake_Source = function(t) return t end,
  GetMediaSourceFileName = function(s) return s.path end,
  EnumerateFiles = function(d, i)
    local p = io.popen("ls -1 '" .. d .. "' 2>/dev/null")
    local n, k = nil, -1
    for line in p:lines() do k = k + 1; if k == i then n = line end end
    p:close(); return n
  end,
}
env.V5.is_tidy = function(d) return exists(d .. "/.fastsyncs-layout") end
env.V5.set_status_paths = function() end
env.V5.STATUS_ROOT = tmp .. "/status"
env.V5.regen_target_path = function() return tmp .. "/status/x.json" end
env.V5.set_regen_target = function(d, lang)
  env._regen_out_dir = d
  if (lang or "") ~= "" then env._regen_lang = lang end
end
for _, sig in ipairs({ "function V5.out_dir_from_item", "function V5.prefill_regen_target",
                       "function V5.run_folder_ok" }) do
  assert(load(cut(sig), sig, "t", env))()
end
local V5 = env.V5

check("flat chunk -> its run folder",
      V5.out_dir_from_item({ path = flatA .. "/Hindi_(talk)_tts.wav" }) == flatA)
check("already-redone chunk -> the run folder, not regen/",
      V5.out_dir_from_item({ path = flatA .. "/regen/chunk_1200_v1.wav" }) == flatA)
check("tidy chunk -> the tidy root",
      V5.out_dir_from_item({ path = tidy .. "/03_Voice/pieces/x_str_001.mp3" }) == tidy)

-- pane drawn before anything is selected (the 0.15.9 trap)
V5.prefill_regen_target()
check("nothing selected -> still unknown", env._regen_out_dir == "")
selected = { path = flatA .. "/Hindi_(talk)_tts.wav" }
V5.prefill_regen_target()
check("chunk selected later -> found", env._regen_out_dir == flatA)
check("run's language read from the folder", env._regen_lang == "Hindi")

selected = { path = flatB .. "/Nepali_(interview)_tts.wav" }
V5.prefill_regen_target()
check("chunk of another video -> re-pointed", env._regen_out_dir == flatB)
check("old video's language dropped", env._regen_lang == "")

-- 0.15.12: re-voiced audio goes into a folder only if it is a real run folder
put(flatB .. "/Nepali_(interview)_tts.wav", "x")
check("run folder: has its manifest", V5.run_folder_ok(flatA))
check("run folder: has its speech wav", V5.run_folder_ok(flatB))
mk(tmp .. "/Recordings")
check("a plain audio folder is not a run folder", not V5.run_folder_ok(tmp .. "/Recordings"))
check("tidy root is a run folder", V5.run_folder_ok(tidy))

os.execute("rm -rf '" .. tmp .. "'")
print(fails == 0 and "\nGREEN: all checks passed" or ("\nRED: " .. fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
