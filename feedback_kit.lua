-- feedback_kit.lua — per-video run logs + the "How did it go?" star card.
--
-- Loaded with dofile() by BOTH auto_sync_pipeline.lua and
-- dubbing/reaper/Dub_Pipeline_Panel.lua. Being its own chunk it costs the dub
-- panel ONE local (the panel is at Lua's 200-locals limit), and both tools
-- share one implementation instead of two that drift apart.
--
-- Two jobs:
--
-- 1. archive_log(opts) — when a run ends, copy its log next to the REAPER
--    project it belongs to:  <project folder>/FastSyncs_Logs/
--        2026-09-26_14-05-33_AutoSync_failed.txt
--    One folder per video, newest 50 kept. The live log files are wiped at
--    every launch (the poller needs a clean file), so without this copy the
--    previous run's error is gone the moment anybody presses a button.
--    Unsaved project → <fast-syncs>/logs/unsaved/ (nowhere better to put it).
--
-- 2. card — a small 1-to-5 star card drawn on the success/failure screens.
--    4-5 send just the rating. 1-3 stars open a message box and a
--    "Send report" button, which sends the rating, the message and that
--    run's archived log. Sending is done by app_feedback.py --send-report in
--    a detached Python process (Lua cannot do HTTPS); this file only writes
--    the report JSON and polls for "<report>.result".
--
-- Nothing here may block a defer frame: no waiting os.execute, no sleeps.

local M = {}

local SEP = package.config:sub(1, 1)
local IS_WIN = reaper.GetOS():match("Win") ~= nil
local KEEP_LOGS = 50
local EXT = "FastSyncsFeedback"   -- ExtState section (remembers the contact)

-- ── small helpers ─────────────────────────────────────────

local function read_all(path)
  if not path or path == "" then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local function dirname(p) return (p or ""):match("^(.*)[/\\][^/\\]*$") or "" end

-- JSON string escaping: quotes, backslashes and control characters. UTF-8
-- (Indic text in a message) passes through untouched — the file is UTF-8.
local function jstr(s)
  s = tostring(s or "")
  s = s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    if c == "\n" then return "\\n" end
    if c == "\r" then return "\\r" end
    if c == "\t" then return "\\t" end
    return string.format("\\u%04x", c:byte())
  end)
  return '"' .. s .. '"'
end

-- POSIX single-quote wrapping (os.execute goes through /bin/sh).
local function shq(s)
  return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

-- MSVCRT argv quoting for CreateProcess (same rules as V5.winquote).
local function winq(s)
  s = tostring(s or "")
  s = s:gsub('(\\*)"', function(b) return b .. b .. '\\"' end)
  s = s:gsub('(\\+)$', function(b) return b .. b end)
  return '"' .. s .. '"'
end

local function safe_name(s)
  return (tostring(s or "run"):gsub("[^%w%-]+", ""))
end

-- The REAPER project this run belongs to: its folder and file name.
-- `proj` may be a project pointer captured at launch (the user can switch
-- project tabs while a run is going); nil means the active project.
local function project_info(proj)
  local fn = ""
  local found = false
  if proj and reaper.ValidatePtr and reaper.ValidatePtr(proj, "ReaProject*") then
    local i = 0
    while true do
      local pp, pfn = reaper.EnumProjects(i, "")
      if not pp then break end
      if pp == proj then fn, found = pfn or "", true break end
      i = i + 1
    end
  end
  if not found then
    local _, pfn = reaper.EnumProjects(-1, "")
    fn = pfn or ""
  end
  if fn == "" then return nil, "" end
  return dirname(fn), (fn:match("([^/\\]+)$") or fn)
end

-- Newest-last list of archived logs in `dir`, pruned to KEEP_LOGS.
local function prune(dir)
  if not reaper.EnumerateFiles then return end
  local names, i = {}, 0
  while true do
    local n = reaper.EnumerateFiles(dir, i)
    if not n then break end
    if n:match("^%d%d%d%d%-%d%d%-%d%d_.*%.txt$") then names[#names + 1] = n end
    i = i + 1
  end
  table.sort(names)          -- timestamp prefix sorts oldest first
  for k = 1, #names - KEEP_LOGS do os.remove(dir .. SEP .. names[k]) end
end

-- ── 1. per-video log archive ──────────────────────────────

-- opts: app_root, pipeline ("AutoSync", "DubFull", ...), status ("ok",
-- "failed", "cancelled", "review"), log_path (the live log), started
-- (os.time() at launch), version, project (pointer captured at launch, or
-- nil), extra (string: panel-side error text to append).
-- Returns the archived file path, or nil. Never raises.
function M.archive_log(opts)
  local ok, res = pcall(function()
    local pdir, pname = project_info(opts.project)
    local dir
    if pdir and pdir ~= "" then
      dir = pdir .. SEP .. "FastSyncs_Logs"
    else
      dir = opts.app_root .. SEP .. "logs" .. SEP .. "unsaved"
    end
    reaper.RecursiveCreateDirectory(dir, 0)

    local now = os.time()
    local started = opts.started or now
    local name = string.format("%s_%s_%s.txt", os.date("%Y-%m-%d_%H-%M-%S", now),
                               safe_name(opts.pipeline), safe_name(opts.status))
    local path = dir .. SEP .. name
    local f = io.open(path, "wb")
    if not f then return nil end
    f:write("==== Fast Syncs run log ====\n")
    f:write("App version : ", tostring(opts.version or "?"), "\n")
    f:write("Pipeline    : ", tostring(opts.pipeline or "?"), "\n")
    f:write("Result      : ", tostring(opts.status or "?"), "\n")
    f:write("Project     : ", (pname ~= "" and pname or "(unsaved project)"), "\n")
    f:write("Started     : ", os.date("%Y-%m-%d %H:%M:%S", started), "\n")
    f:write("Finished    : ", os.date("%Y-%m-%d %H:%M:%S", now), "\n")
    f:write(string.format("Duration    : %dm %02ds\n",
                          (now - started) // 60, (now - started) % 60))
    f:write("Computer    : ", reaper.GetOS(), " · REAPER ",
            reaper.GetAppVersion(), "\n")
    f:write("============================\n\n")
    f:write(read_all(opts.log_path) or "(the log file was empty or missing)\n")
    if opts.extra and opts.extra ~= "" then
      f:write("\n\n==== Shown in the panel ====\n", opts.extra, "\n")
    end
    f:close()
    prune(dir)
    return path
  end)
  if ok then return res end
  return nil
end

-- ── 2. star card ──────────────────────────────────────────

-- card = M.new_card{ app_root=, get_python=function() return path end }
-- card:start{ pipeline=, status=, log=archived_path, started=, version=,
--             project_name= }  -- call once when a run ends
-- card:render(ctx)             -- call every frame on the result screen
function M.new_card(cfg)
  local c = {
    app_root = cfg.app_root, get_python = cfg.get_python,
    active = false, stars = 0, message = "", state = "ask",
    contact = reaper.GetExtState(EXT, "contact") or "",
  }

  function c:start(run)
    self.run = run
    self.active = true
    self.stars, self.message, self.state = 0, "", "ask"
    self.result_path, self.note = nil, nil
  end

  function c:reset() self.active = false end

  -- Write the report JSON and launch the detached sender.
  function c:send()
    local py = self.get_python and self.get_python() or nil
    local r = self.run or {}
    local dir = self.app_root .. SEP .. "feedback_outbox"
    reaper.RecursiveCreateDirectory(dir, 0)
    local path = dir .. SEP .. "report_" .. os.date("%Y%m%d_%H%M%S") ..
                 string.format("_%04d", math.random(0, 9999)) .. ".json"
    local f = io.open(path, "wb")
    if not f then
      self.state, self.note = "done", "Could not write the report file."
      return
    end
    local _, rver = pcall(reaper.GetAppVersion)
    f:write("{\n",
      '  "kind": "run_report",\n',
      '  "pipeline": ', jstr(r.pipeline), ",\n",
      '  "status": ', jstr(r.status), ",\n",
      '  "stars": ', tostring(self.stars), ",\n",
      '  "message": ', jstr(self.message), ",\n",
      '  "contact": ', jstr(self.contact), ",\n",
      '  "version": ', jstr(r.version), ",\n",
      '  "project": ', jstr(r.project_name), ",\n",
      '  "started": ', jstr(os.date("%Y-%m-%d %H:%M:%S", r.started or os.time())), ",\n",
      '  "duration_s": ', tostring(math.max(0, (r.finished or os.time())
                                            - (r.started or os.time()))), ",\n",
      '  "reaper": ', jstr((rver or "") .. " " .. reaper.GetOS()), ",\n",
      -- 4-5 stars: rating only. The log goes along only with a report.
      '  "log_path": ', jstr(self.stars <= 3 and (r.log or "") or ""), "\n",
      "}\n")
    f:close()
    reaper.SetExtState(EXT, "contact", self.contact or "", true)

    local sender = self.app_root .. SEP .. "app_feedback.py"
    if not py or py == "" then
      self.state = "done"
      self.note = "Python not found — report saved in feedback_outbox and " ..
                  "will be sent with the next one."
      return
    end
    os.remove(path .. ".result")
    if IS_WIN then
      if not reaper.ExecProcess then
        self.state, self.note = "done", "This REAPER is too old to send reports."
        return
      end
      reaper.ExecProcess(winq(py) .. " " .. winq(sender) .. " --send-report "
                         .. winq(path), -2)
    else
      os.execute(shq(py) .. " " .. shq(sender) .. " --send-report " .. shq(path)
                 .. " >/dev/null 2>&1 &")
    end
    self.result_path = path .. ".result"
    self.sent_at = os.time()
    self.state = "sending"
  end

  function c:poll()
    if self.state ~= "sending" then return end
    local txt = read_all(self.result_path)
    if txt and txt:find("}", 1, true) then
      if txt:find('"ok"%s*:%s*true') then
        self.note = "✓ Sent to the team. Thank you!"
      elseif txt:find('"where"%s*:%s*"saved"') then
        self.note = "No connection to the team inbox right now — report " ..
                    "saved and will be sent automatically next time."
      else
        self.note = "Could not send the report: " ..
                    (txt:match('"error"%s*:%s*"(.-)"') or "unknown error")
      end
      self.state = "done"
      os.remove(self.result_path)
    elseif os.time() - (self.sent_at or 0) > 120 then
      self.note = "Still no answer after 2 minutes — the report is saved " ..
                  "and will be retried with the next one."
      self.state = "done"
    end
  end

  function c:render(ctx)
    if not self.active then return end
    self:poll()
    reaper.ImGui_Dummy(ctx, 0, 6)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, "How did this run go?")

    if self.state == "ask" or self.state == "detail" then
      -- Numbered buttons, gold when lit: a star glyph is not guaranteed to
      -- exist in the user's ImGui font, a digit always is.
      for i = 1, 5 do
        if i > 1 then reaper.ImGui_SameLine(ctx) end
        local lit = i <= self.stars
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
                                    lit and 0xE0A800FF or 0x3A3A3AFF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),
                                    0xF0C040FF)
        if reaper.ImGui_Button(ctx, tostring(i) .. "##fbstar", 34, 30) then
          self.stars = i
          if i >= 4 then self:send() else self.state = "detail" end
        end
        reaper.ImGui_PopStyleColor(ctx, 2)
      end
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_TextDisabled(ctx, "1 = bad · 5 = great")
    end

    if self.state == "detail" then
      reaper.ImGui_TextWrapped(ctx,
        "Sorry it didn't go well. Tell us what happened — the log of this " ..
        "run is attached automatically (API keys are removed first).")
      local rv, txt = reaper.ImGui_InputTextMultiline(ctx, "##fbmsg",
                                                      self.message, -1, 70)
      if rv then self.message = txt end
      local rv2, who = reaper.ImGui_InputText(ctx,
                                              "Your name or email (optional)##fbwho",
                                              self.contact)
      if rv2 then self.contact = who end
      if reaper.ImGui_Button(ctx, "Send report", 140, 28) then self:send() end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Skip", 80, 28) then
        self.state, self.note = "done", "Skipped."
      end
    elseif self.state == "sending" then
      reaper.ImGui_TextDisabled(ctx, "Sending…")
    elseif self.state == "done" then
      if self.stars > 0 then
        reaper.ImGui_TextDisabled(ctx, string.format("Your rating: %d / 5",
                                                     self.stars))
      end
      if self.note then reaper.ImGui_TextWrapped(ctx, self.note)
      elseif self.stars >= 4 then reaper.ImGui_Text(ctx, "Thanks!") end
    end
    if self.run and self.run.log and self.run.log ~= "" then
      reaper.ImGui_TextDisabled(ctx, "Log saved: " .. self.run.log)
    end
  end

  return c
end

return M
