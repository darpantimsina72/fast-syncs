-- Offline checks for error_explain.lua — the plain-English reason a failed
-- run shows on screen.
--
-- Guards:
--   1. Each known error in a real log gets its own reason, not a generic one
--      (same cases the team inbox is tested against).
--   2. A healthy log gives no reason (a rule that fires on a good run would
--      tell the user something false).
--   3. Stopped / unknown / Auto Sync problem-list runs each get a sensible
--      answer, and a broken input never raises.
--   4. Every rule is well formed and every Lua pattern compiles.
--
-- Run:  lua tests/test_error_explain.lua

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local E = dofile(here .. "/../error_explain.lua")
local CASES = dofile(here .. "/error_explain_cases.lua")

local fails = 0
local function check(name, cond)
  print((cond and "  PASS " or "  FAIL ") .. name)
  if not cond then fails = fails + 1 end
end

-- ── 1 + 2. Known errors, from real logs ────────────────────────────────────
for _, c in ipairs(CASES) do
  local d = E.diagnose(c.log, c.status)
  if c.expect == false then
    check(c.name .. " → no rule gives the reason (got " .. tostring(d.id) .. ")",
          d.kind ~= "error" and d.kind ~= "warn")
  else
    check(c.name .. " → " .. c.expect .. " (got " .. tostring(d.id) .. ")",
          d.id == c.expect)
    check(c.name .. " → evidence quotes the log", #d.evidence > 0)
  end
end

-- ── 3. The no-rule paths ────────────────────────────────────────────────────
local d = E.diagnose("STEP 1\nworking...\n", "cancelled")
check("stopped run → cancelled", d.kind == "cancelled")

d = E.diagnose('STEP 1\nTraceback (most recent call last):\n  File "x.py", line 3\n' ..
               'ZeroDivisionError: division by zero\n', "failed")
check("unknown failure → unknown", d.kind == "unknown")
check("unknown failure → quotes the exception in plain words",
      d.why:find("ZeroDivisionError: division by zero", 1, true) ~= nil)

d = E.diagnose(table.concat({
  "  PROBLEMS FOUND: 1",
  "  [ERROR] NO_DUB_ITEMS: The dubbed track has no clips on it.",
}, "\n"), "failed")
check("Auto Sync problem code → shown in its own words",
      d.kind == "problem" and d.id == "NO_DUB_ITEMS"
      and d.why == "The dubbed track has no clips on it.")

d = E.diagnose("", "failed")
check("empty log, failed → unknown, no crash", d.kind == "unknown")
d = E.diagnose(nil, nil)
check("nil log → no crash", type(d) == "table" and d.title ~= nil)

-- Finished run with a warning → notes() lists it; diagnose(ok) gives it too.
local warn_log = "  EN: 1 items | DUB: 36 items\n  RESULT: 36/36 matched, 0 unmatched"
local notes = E.notes(warn_log)
check("notes() on a finished run lists the warning",
      #notes == 1 and notes[1].id == "english_not_split")
check("notes() on a clean run is empty",
      #E.notes("  EN: 42 items | DUB: 40 items\n  RESULT: 40/40 matched, 0 unmatched") == 0)

-- as_text carries all three parts for the archived log / report.
local t = E.as_text(E.diagnose("RuntimeError: ffmpeg not found", "failed"))
check("as_text has reason, why and what to do",
      t:find("^Reason: ffmpeg is not installed") and t:find("\nWhy: ")
      and t:find("\nWhat to do: ") and true or false)
check("as_text of a clean run is empty", E.as_text({ kind = "ok" }) == "")

-- A very long matched line is shortened, never cut inside a UTF-8 character.
d = E.diagnose("RuntimeError: ffmpeg not found " .. string.rep("अ", 200), "failed")
local ev = d.evidence[1] or ""
check("long evidence line is shortened", #ev < 300)
check("shortened line is valid UTF-8", utf8.len(ev) ~= nil)

-- ── 4. Rules are well formed ────────────────────────────────────────────────
local ids = {}
for _, r in ipairs(E.RULES) do
  check("rule " .. r.id .. " has title/why/fix/level",
        r.title and r.why and r.fix and (r.level == "error" or r.level == "warn") and true or false)
  check("rule " .. r.id .. " has something to match", #(r.find or {}) + #(r.pat or {}) > 0)
  local ok = true
  for _, p in ipairs(r.pat or {}) do ok = ok and pcall(string.find, "", p) end
  for _, p in ipairs(r.unless_pat or {}) do ok = ok and pcall(string.find, "", p) end
  check("rule " .. r.id .. " patterns compile", ok)
  if r.ci then
    for _, s in ipairs(r.find or {}) do
      check("rule " .. r.id .. " ci text is lower case: " .. s, s == s:lower())
    end
  end
  check("rule id unique: " .. r.id, not ids[r.id]); ids[r.id] = true
end

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
