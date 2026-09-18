-- Regression loop for the Lua side of the results contract.
--
-- The Lua reads sync_results.json with pattern matching, not a JSON parser
-- (AGENTS.md gotcha 4). That works only because Python writes indent=2. This
-- checks the summary fields AND the v0.15.4 "problems" array survive the round
-- trip, so a change on either side is caught here instead of in REAPER.
--
-- Run:  lua tests/test_lua_results_parse.lua

local fails = 0
local function check(name, got, want)
  if got ~= want then
    print(string.format("  FAIL %-28s got %q want %q", name, tostring(got), tostring(want)))
    fails = fails + 1
  else
    print(string.format("  PASS %-28s %s", name, tostring(got)))
  end
end

-- The exact parser from auto_sync_pipeline.lua (kept in sync by eye; this
-- file exists to prove the PATTERNS work against real worker output).
local function read_problems(content)
  local out = {}
  local block = content:match('"problems"%s*:%s*%[(.-)%]')
  if not block then return out end
  for entry in block:gmatch('"(.-)"') do
    local sev, code, msg = entry:match("^([A-Z]+)|([A-Z_]+)|(.*)$")
    if sev then out[#out + 1] = { severity = sev, code = code, message = msg } end
  end
  return out
end

local function read_summary(c)
  return {
    total_en  = c:match('"total_en"%s*:%s*(%d+)')  or "?",
    total_dub = c:match('"total_dub"%s*:%s*(%d+)') or "?",
    matched   = c:match('"matched"%s*:%s*(%d+)')   or "?",
    unmatched = c:match('"unmatched"%s*:%s*(%d+)') or "?",
    problems  = read_problems(c),
  }
end

local path = (arg and arg[1]) or "sync_results.json"
local f = io.open(path, "r")
if not f then print("SKIP: no " .. path) ; os.exit(0) end
local content = f:read("*a"); f:close()

print("parsing " .. path)
local s = read_summary(content)
check("total_en parsed",  s.total_en  ~= "?", true)
check("total_dub parsed", s.total_dub ~= "?", true)
check("matched parsed",   s.matched   ~= "?", true)
check("unmatched parsed", s.unmatched ~= "?", true)

-- Every dub_id + new_position pair must be readable; a compact-JSON regression
-- makes this zero and no clip moves in REAPER.
local n = 0
for _ in content:gmatch('"dub_id"%s*:%s*%d+') do n = n + 1 end
check("dub_id lines found", n > 0, true)

local probs = s.problems
print(string.format("  problems parsed: %d", #probs))
for _, p in ipairs(probs) do
  print(string.format("    [%s] %s: %s", p.severity, p.code, p.message))
end

-- Synthetic round trip: a problems array must parse back to 2 entries.
local synth = [[{
  "summary": { "total_en": 3, "total_dub": 3, "matched": 2, "unmatched": 1 },
  "problems": [
    "ERROR|SLICE_FAILED|Could not cut clips out of Recording_572.m4a",
    "WARN|DROPPED_FOR_OVERFLOW|5 clips moved to the Un sync track"
  ]
}]]
local sp = read_problems(synth)
check("synthetic problem count", #sp, 2)
check("synthetic severity",      sp[1] and sp[1].severity, "ERROR")
check("synthetic code",          sp[1] and sp[1].code, "SLICE_FAILED")
check("synthetic 2nd code",      sp[2] and sp[2].code, "DROPPED_FOR_OVERFLOW")

print()
if fails > 0 then
  print(string.format("RED: %d check(s) failed", fails)); os.exit(1)
end
print("GREEN: the Lua patterns read the worker's output correctly")
