-- Offline check for V5.save_final_script (Dub_Pipeline_Panel.lua, 0.15.10):
-- after a redo, the whole script as it now stands is written to
-- "<name>_FinalScript_after_redo.txt" in the run folder.
--
-- The function is cut out of the panel source and run against a fake
-- `reaper` with one track of chunks:
--   * chunks in timeline order (not item-list order), one per line,
--   * a split item's repeated text written once, empty chunks skipped,
--   * flat run folder -> <folder>/<folder name>_FinalScript_after_redo.txt,
--   * tidy 0.15.7–0.15.9 folder -> 02_Script/<track>_FinalScript_after_redo.txt,
--   * rewritten (not appended) on the next redo,
--   * no run folder / no text -> nothing written, no error.
--
-- Run:  lua tests/test_final_script.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local src = io.open(here .. "/../dubbing/reaper/Dub_Pipeline_Panel.lua"):read("*a")
local a = src:find("function V5.save_final_script", 1, true)
local b = src:find("\nend\n", a, true)
local chunk = src:sub(a, b + 4)

local fails = 0
local function check(name, cond)
  print((cond and "  PASS " or "  FAIL ") .. name)
  if not cond then fails = fails + 1 end
end

local tmp = os.tmpname(); os.remove(tmp); os.execute("mkdir -p '" .. tmp .. "'")
local function read(p) local f = io.open(p, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s end

-- Fake project: one track, items deliberately NOT in timeline order.
local ITEMS = {
  { pos = 4.0, text = "third line" },
  { pos = 0.0, text = "first line" },
  { pos = 2.0, text = "second line" },
  { pos = 2.5, text = "second line" },   -- split piece of the same chunk
  { pos = 3.0, text = "   " },           -- empty chunk
}
local TRACK = { name = "Dub Chunks (Hindi)" }

local env = {
  V5 = {}, SEP = "/", _regen_out_dir = "",
  pcall = pcall, ipairs = ipairs, table = table, io = io,
  basename = function(p) return p:match("([^/]+)$") or p end,
}
env.reaper = {
  ValidatePtr = function() return true end,
  GetMediaItem_Track = function() return TRACK end,
  CountTrackMediaItems = function() return #ITEMS end,
  GetTrackMediaItem = function(_, i) return ITEMS[i + 1] end,
  GetMediaItemInfo_Value = function(it) return it.pos end,
  GetSetMediaTrackInfo_String = function(tr) return true, tr.name end,
}
env.V5.get_item_text = function(it) return it.text end
env.V5.is_tidy = function(d) return read(d .. "/.fastsyncs-layout") ~= nil end
env.V5.layout_path = function(d, kind, name)
  assert(kind == "script")
  os.execute("mkdir -p '" .. d .. "/02_Script'")
  return d .. "/02_Script/" .. name
end

local fn = assert(load(chunk, "save_final_script", "t", env))
fn()

-- flat run folder
local flat = tmp .. "/Media/talk"
os.execute("mkdir -p '" .. flat .. "'")
env._regen_out_dir = flat
local p = env.V5.save_final_script(ITEMS[1])
check("flat: written next to the run's files",
      p == flat .. "/talk_FinalScript_after_redo.txt")
check("timeline order, one chunk per line, split text once, empties skipped",
      read(p or "") == "first line\nsecond line\nthird line\n")

ITEMS[2].text = "first line, redone"
env.V5.save_final_script(ITEMS[2])
check("rewritten on the next redo (not appended)",
      read(p or "") == "first line, redone\nsecond line\nthird line\n")

-- tidy folder from 0.15.7–0.15.9
local tidy = tmp .. "/Proj/FastSyncs"
os.execute("mkdir -p '" .. tidy .. "'")
io.open(tidy .. "/.fastsyncs-layout", "wb"):write("2\n")
env._regen_out_dir = tidy
local q = env.V5.save_final_script(ITEMS[1])
check("tidy: 02_Script/<track>_FinalScript_after_redo.txt",
      q == tidy .. "/02_Script/Dub_Chunks__Hindi__FinalScript_after_redo.txt"
      and read(q) ~= nil)

-- nothing to do
env._regen_out_dir = ""
check("no run folder -> nil", env.V5.save_final_script(ITEMS[1]) == nil)
env._regen_out_dir = flat
for _, it in ipairs(ITEMS) do it.text = "" end
check("no text on any chunk -> nil", env.V5.save_final_script(ITEMS[1]) == nil)

os.execute("rm -rf '" .. tmp .. "'")
print(fails == 0 and "\nGREEN: all checks passed" or ("\nRED: " .. fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
