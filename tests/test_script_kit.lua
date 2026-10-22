-- Offline check of the script editor's tag logic (no REAPER needed):
--   lua tests/test_script_kit.lua
reaper = { ImGui_CalcTextSize = function(_, t) return #t * 7 end }
local dir = arg[0]:match("^(.*)[/\\]tests[/\\]") or "."
local M = dofile(dir .. "/script_kit.lua")
local fails = 0
local function eq(got, want, name)
  if got ~= want then
    fails = fails + 1
    print("FAIL " .. name .. "\n  got:  " .. got .. "\n  want: " .. want)
  end
end
local T = "[telugu accent]\n[warm] [slow] one two... [thoughtful] three four five"
eq(M.tags_strip(T), "one two... three four five", "strip")
eq(M.tags_merge(T, "one TWO... four five six"),
   "[telugu accent] [warm] [slow] one TWO... [thoughtful] four five six",
   "edit words, deleted word's tag moves on")
eq(M.tags_merge(T, M.tags_strip(T)),
   "[telugu accent] [warm] [slow] one two... [thoughtful] three four five",
   "round trip keeps every tag")
eq(M.tags_merge("plain words", "plain new words"), "plain new words", "no tags")
local w = M.soft_wrap(nil, "alpha beta gamma delta epsilon zeta", 80)
eq(M.soft_unwrap(w), "alpha beta gamma delta epsilon zeta", "wrap round trip")
-- Live wrap: break goes right after the last space that fits (7 px/char,
-- width 80 -> 11 chars), never inside a word.
eq(tostring(M.next_break(nil, "alpha beta gamma", 80)), "11", "live break offset")
eq(tostring(M.next_break(nil, "short", 80)), "nil", "no break needed")
eq(tostring(M.next_break(nil, "averyveryverylongword", 80)), "nil", "long word kept whole")
-- A tag pasted in the words-only view is kept, other tags stay put.
eq(M.tags_merge("[warm] one two [slow] three", "one [pause] two three"),
   "[warm] one [pause] two [slow] three", "tag pasted in Script view")
print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
