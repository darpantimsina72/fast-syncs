-- error_explain.lua — turns a run log into one plain-English reason.
--
-- Shared by Auto Sync (auto_sync_pipeline.lua) and the dub panel
-- (dubbing/reaper/Dub_Pipeline_Panel.lua), loaded with dofile like
-- feedback_kit.lua. A missing or broken copy must never stop a run: both
-- callers pcall the dofile and fall back to the raw log.
--
-- What it does: when a run fails, the panel used to show only the last
-- ~1500 characters of the log. Most people cannot read a Python traceback.
-- This reads the WHOLE log, finds the known error in it, and returns three
-- short sentences — what went wrong, why, what to do — which the failure
-- screen shows in large text above the (now folded away) log.
--
-- The RULES are a Lua port of the team inbox's rules (feedback/apps_script.gs
-- on the feat/inbox-explains-errors branch), so the screen and the report
-- email give the same reason. When you add a rule in one, add it in the
-- other. The wording differs in one way only: the screen says "send a report
-- with the button below" where the email says "reply to this email".
--
-- Matching rules (same as the inbox):
--   * each rule is tested against ONE log line at a time;
--   * the last line a rule matches is its evidence;
--   * errors beat warnings, then the earlier rule in RULES wins — so a
--     specific cause sits ABOVE the umbrella error it leads to;
--   * a FAILED run whose only matches are warnings failed for another,
--     unknown reason: a warning is never passed off as the cause.
--
-- Pure Lua 5.3/5.4, no REAPER calls outside M.render, so tests run offline:
--   lua tests/test_error_explain.lua

local M = {}

-- Each rule: id, level ('error' = the run broke, 'warn' = it finished but
-- this explains a bad result), title/why/fix, and how to recognise it:
--   find  = plain substrings (exact text, no pattern magic)
--   pat   = Lua patterns
--   ci    = true → the line is lower-cased first (find/pat must be lower case)
--   unless_pat = skip the rule when ANY log line matches one of these
-- Keep them specific: a rule that fires on a healthy log is worse than none.
M.RULES = {
  -- ── Keys and credits ──
  { id = "elevenlabs_key_missing", level = "error",
    find = { "No ElevenLabs API key configured", "ElevenLabs API key unavailable",
             "No ElevenLabs voice selected", "--asr elevenlabs requires --elevenlabs-key" },
    title = "ElevenLabs key is missing",
    why = "Making or reading speech needs an ElevenLabs API key, and none is saved on this computer.",
    fix = "Open Settings → Voices, paste the ElevenLabs key, press Save, then run again." },
  { id = "elevenlabs_credits", level = "error", ci = true,
    find = { "quota_exceeded", "exceeds your quota", "exceeds your character quota" },
    title = "ElevenLabs credits are used up",
    why = "ElevenLabs refused the request because the account has no characters left this month.",
    fix = "Top up the ElevenLabs plan (or use another key in Settings → Voices), then run again." },
  { id = "elevenlabs_key_rejected", level = "error",
    find = { "ElevenLabs rejected the API key (401)", "Invalid or expired ElevenLabs API key (401)",
             "[11LABS] HTTP 401" },
    title = "ElevenLabs refused the key",
    why = "The ElevenLabs key saved in Settings was not accepted — it is wrong, expired, or the account is out of credits.",
    fix = "Copy the key again from elevenlabs.io → Profile → API keys, paste it in Settings → Voices, Save, and run again." },
  { id = "cartesia_key_missing", level = "error",
    find = { "No Cartesia API key configured" },
    title = "Cartesia key is missing",
    why = "The voice provider is set to Cartesia, but no Cartesia key is saved on this computer.",
    fix = "Open Settings → Voices, paste the Cartesia key (or switch the voice provider back to ElevenLabs), Save, and run again." },
  { id = "cartesia_key_rejected", level = "error",
    find = { "Cartesia rejected the API key (401)" },
    title = "Cartesia refused the key",
    why = "The Cartesia key saved in Settings was not accepted.",
    fix = "Copy the key again from the Cartesia dashboard, paste it in Settings → Voices, Save, and run again." },
  { id = "cartesia_credits", level = "error",
    find = { "out of credits (402)" },
    title = "Cartesia credits are used up",
    why = "Cartesia refused the request because the account has no credits left.",
    fix = "Top up the Cartesia account, or switch the voice provider to ElevenLabs in Settings → Voices." },

  -- ── The AI server (gateway / Gemini) ──
  { id = "llm_timeout_524", level = "error",
    find = { "returned HTTP 524", "HTTP Error 524", "[GATEWAY] HTTP 524" },
    title = "The AI server took too long",
    why = "The AI server gave up after about 100 seconds on one request (error 524). The server was too slow or too busy — it is not about this video.",
    fix = "Run again; it often works the second time. If it keeps failing, check the AI server setting in Settings, and send a report with the button below. Only for a very long video (over ~20 minutes) does cutting it into parts help." },
  { id = "llm_down_502", level = "error",
    pat = { "returned HTTP 50[234]", "HTTP Error 50[234]", "%[GATEWAY%] HTTP 50[234]" },
    title = "The AI server is down",
    why = "The AI server that translates and matches was not answering (error 502/503/504). This is on our side, not your computer.",
    fix = "Wait a few minutes and run again. If it keeps happening, send a report with the button below." },
  { id = "gemini_overloaded", level = "error",
    pat = { "%[GEMINI%] 503 on .*overloaded" }, find = { "[GEMINI] All model variants failed" },
    title = "Google's AI was overloaded",
    why = "Google's Gemini service was too busy to answer.",
    fix = "Wait a few minutes and run again." },
  { id = "llm_rate_limited", level = "error",
    find = { "returned HTTP 429", "[GATEWAY] HTTP 429", "[GEMINI] 429 on" },
    title = "Too many AI requests at once",
    why = "The AI server asked us to slow down (error 429) — too many requests in a short time.",
    fix = "Wait a minute or two and run again." },
  { id = "gateway_unreachable", level = "error",
    find = { "[GATEWAY] Error: <urlopen error", "No response from gateway",
             "Cannot reach LLM endpoint", "Lost the connection to the LLM endpoint" },
    title = "Could not reach the AI server",
    why = "This computer could not connect to the AI server. An office address (starting 172.18.) only works on the office network.",
    fix = "Check the internet, connect to the office network or VPN if you use the office address, then run again." },
  { id = "cloudflare_1010", level = "error",
    find = { "error code: 1010", "Cloudflare is blocking this client" },
    title = "The AI server's firewall blocked this computer",
    why = "Cloudflare, which protects the AI server, rejected the request from this computer.",
    fix = "Update Fast Syncs (Settings → About → Update…) and run again. If it persists, send a report with the button below." },
  { id = "llm_key_rejected", level = "error",
    -- %f[%W] = the "\b" after the number: 401/403, not 4010.
    pat = { "returned HTTP 40[13]%f[%W]", "%[GATEWAY%] HTTP 40[13]%f[%W]" },
    find = { "carried NO API key", "Gateway API key is empty" },
    title = "The AI server refused the key",
    why = "The key saved for the AI server (Settings → Connection) is missing or not accepted.",
    fix = "Open Settings → Connection, paste the correct key, Save, and run again." },
  { id = "llm_settings_wrong", level = "error",
    find = { "returned an HTML page, not JSON", "is the gateway's admin console, not its API",
             "Base URL must not include the endpoint path", "OpenAI-compatible base URL is empty",
             "backend=gateway requires SYNC_GEMINI_BASE_URL", "backend=gateway but no gateway URL set" },
    title = "The AI server address in Settings is wrong",
    why = "The address saved in Settings → Connection is empty or points at the wrong page, so the AI could not be reached.",
    fix = "Open Settings → Connection and put back the address the team gave you (it ends before \"/v1/chat/completions\"), Save, and run again." },
  { id = "llm_settings_missing", level = "error",
    find = { "LLM provider not usable:", "LLM settings file not found", "Model name is empty",
             "Gemini API key is empty", "backend=gateway requires --gemini-key",
             "matcher=gemini requires --gemini-key", "[GEMINI] No api_key for REST fallback" },
    title = "AI settings are incomplete",
    why = "The AI part of the settings (key, address or model) is not filled in on this computer.",
    fix = "Open Settings → Connection, fill in the key and model, press Save, and run again." },

  -- ── Transcription / audio ──
  { id = "elevenlabs_busy", level = "error",
    find = { "ElevenLabs rate limit hit (429)", "[11LABS] HTTP 429", "Cartesia rate limit hit (429)" },
    title = "The voice service was busy",
    why = "ElevenLabs/Cartesia asked us to slow down (error 429) — too many requests at the same time on this account.",
    fix = "Wait a few minutes and run again. Avoid running two dubs at once on the same key." },
  { id = "transcription_failed", level = "error",
    find = { "ElevenLabs Scribe transcription failed after", "[ERROR] Transcription produced NO text" },
    title = "Turning the audio into text failed",
    why = "ElevenLabs could not transcribe the audio — usually a dropped internet connection, or an ElevenLabs key/credit problem.",
    fix = "Check the internet and the ElevenLabs key and credits (Settings → Voices), then run again." },
  { id = "voice_not_found", level = "error",
    find = { "ElevenLabs voice not found (404)", "is not a valid ElevenLabs voice_id",
             "Invalid ElevenLabs voice_id", "Cartesia voice not found (404)", "is not a Cartesia voice id" },
    title = "The chosen voice does not exist",
    why = "The voice picked in Settings is not on this voice account (deleted, or from another account).",
    fix = "Open Settings → Voices, pick a voice from the list again, Save, and run again." },
  { id = "no_speech_found", level = "error",
    find = { "No speech regions detected in the English audio",
             "No word data from ElevenLabs for the English audio" },
    title = "No speech found in the English audio",
    why = "The English audio that was given looks silent or has no speech the tool could find.",
    fix = "Check the right English audio file was chosen and that it plays with speech, then run again." },
  { id = "audio_unreadable", level = "error",
    find = { "clips produced the SAME transcript", "Could not extract chunk for item" },
    title = "The audio file could not be read clip by clip",
    why = "The audio format (for example .m4a / .mp4 / .aac) could not be cut into clips, so every clip got the same text.",
    fix = "Convert the audio to .wav, import the .wav into REAPER instead, and run again." },
  { id = "file_locked", level = "error",
    pat = { "Cannot write .* the file is locked by another program" },
    title = "A file was in use by another program",
    why = "The audio file the tool needed to write was still open in REAPER or another program.",
    fix = "Remove that audio from the REAPER project (or close the other program), then run again." },

  -- ── The install itself ──
  { id = "ffmpeg_missing", level = "error",
    find = { "ffmpeg not found", "ffmpeg/ffprobe not found" },
    title = "ffmpeg is not installed",
    why = "The dubbing part needs a helper program called ffmpeg to read and write audio, and it was not found.",
    fix = "Run the update (Settings → About → Update…), which installs it, then restart REAPER and run again." },
  { id = "install_broken", level = "error",
    find = { "ModuleNotFoundError: No module named", "Pipeline package is missing required symbols",
             "dub_engine.py not found at", "sync_matcher.py not found at",
             "Prompt file(s) missing or empty for", "Prompt file not found: prompts/",
             "Python produced no output for 90 seconds" },
    title = "The Fast Syncs install is incomplete",
    why = "Part of the program is missing on this computer — usually an update that did not finish.",
    fix = "Run the update (Settings → About → Update…), let it finish, restart REAPER, and run again." },

  -- ── Matching (after the causes above, which explain it) ──
  { id = "matching_failed", level = "error",
    find = { "0 clips matched — treating the run as FAILED",
             "Gemini matching failed — sectioned AND batched", "Gemini section matching failed twice" },
    title = "Clips could not be matched",
    why = "The step that pairs dubbed clips with English clips got no usable answer from the AI.",
    fix = "Run again. If it fails again, send a report with the button below (tick \"Attach this run's log\")." },

  -- ── Warnings: the run finished, but these explain a bad result ──
  { id = "english_not_split", level = "warn",
    pat = { "%f[%w]EN: [12] items | DUB: %d%d+ items" },
    unless_pat = { "%[SPLIT%] EN clips for matching: %d+ → %d+" },
    title = "The English track was one long clip",
    why = "Auto Sync places each dubbed clip inside the English clip it matches. The English was one long clip, so all dubbed clips were packed together in one block — even if it says they all matched.",
    fix = "Cut the English track into sentences first (Dynamic Split), then run Auto Sync again. Newer versions do this cut automatically." },
  { id = "english_split_failed", level = "warn",
    find = { "LONG_EN_NOT_SPLIT" },
    title = "A long English clip could not be cut automatically",
    why = "An English clip was too long to match well, and the automatic cut into sentences was not possible for it.",
    fix = "Cut the English track with Dynamic Split, or choose ElevenLabs for transcription, then run Auto Sync again." },
  { id = "dub_not_split", level = "warn",
    pat = { "%f[%w]EN: %d%d+ items | DUB: 1 items" },
    title = "The dubbed track was one long clip",
    why = "Auto Sync moves dubbed clips one by one. The dubbed track was a single clip, so there was nothing to move into place.",
    fix = "Cut the dubbed track into sentences (Dynamic Split), then run Auto Sync again." },
  { id = "many_empty_clips", level = "warn",
    find = { "[WARN] Many empty transcripts" },
    title = "Many clips had no speech in them",
    why = "A lot of clips came back with no words — very short clips, breaths or noise.",
    fix = "Delete the tiny clips (or re-split with a longer minimum length) and run again." },
  { id = "section_pieces", level = "warn",
    find = { "[S2d] Piece size: section." },
    title = "Speech was made in very long pieces",
    why = "\"Dub pieces\" is set to Section, so each piece of speech is 15–60 seconds long and cannot follow the English closely.",
    fix = "Open Settings → Advanced → Dub pieces, choose Clause, then make the voice again." },
  { id = "pieces_too_long", level = "warn",
    find = { "longer than available space" }, pat = { "would end .*→ Un ?sync" },
    title = "Some dubbed lines are longer than the English",
    why = "Some dubbed pieces take longer to say than the English they replace, so they run past it or were moved to the Un sync track.",
    fix = "Shorten those lines and redo them in the Tools tab, or nudge them by hand." },
  { id = "some_unmatched", level = "warn",
    pat = { "RESULT: %d+/%d+ matched, [1-9]%d* unmatched" },
    title = "Some clips were not matched",
    why = "Some dubbed clips could not be paired with an English clip and were put on the Un sync track.",
    fix = "Place those clips by hand (Sync Item), or check they actually contain speech." },
  { id = "lines_shortened", level = "warn",
    pat = { "%[Splitter%] Shortening %d+ section" },
    title = "The AI shortened some lines to fit",
    why = "Some translated lines were too long for the English timing, so the AI shortened them.",
    fix = "Check the shortened lines in the result and redo any that lost meaning in the Tools tab." },
  { id = "speech_reused", level = "warn",
    find = { "Reusing the speech from the previous run" },
    title = "No new voice was made — last run's speech was reused",
    why = "The script, voice and model were the same as last time, so the speech from the previous run was used again.",
    fix = "To get a different voice, pick another voice in Settings → Voices (or change the text) and run again." },
}

-- ── Helpers ────────────────────────────────────────────────────────────────

local function split_lines(text)
  local out = {}
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line:gsub("\r$", "")
  end
  return out
end

local function trim(s) return (tostring(s or ""):match("^%s*(.-)%s*$")) end

-- Long lines (a whole JSON reply, a transcript) are cut for the screen.
local function short(s, n)
  s = trim(s); n = n or 220
  if #s > n then
    -- Back off to a UTF-8 lead byte so Devanagari is never cut mid-character.
    local cut = n
    while cut > 1 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80
          and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
    s = s:sub(1, cut) .. "…"
  end
  return s
end

local function rule_hits_line(rule, line)
  local l = rule.ci and line:lower() or line
  for _, s in ipairs(rule.find or {}) do
    if l:find(s, 1, true) then return true end
  end
  for _, p in ipairs(rule.pat or {}) do
    if l:find(p) then return true end
  end
  return false
end

local function any_line(lines, pats)
  for _, ln in ipairs(lines) do
    for _, p in ipairs(pats) do
      if ln:find(p) then return true end
    end
  end
  return false
end

-- The matched line plus one before and two after — tracebacks put the
-- useful part on the next line.
local function around(lines, at)
  local out = {}
  for i = math.max(1, at - 1), math.min(#lines, at + 2) do
    if trim(lines[i]) ~= "" then out[#out + 1] = short(lines[i]) end
  end
  return out
end

-- Lines that look like an error, newest first. Used when no rule knows the
-- error: the last exception line is still more useful than 1500 characters
-- of log.
local ERRORISH = { "Traceback", "Error%f[%W]", "ERROR", "FAILED", "Failed", "failed",
                   "Exception", "HTTP [45]%d%d", "✗", "❌" }
local function errorish(lines, max)
  local out = {}
  for i = #lines, 1, -1 do
    local ln = lines[i]
    for _, p in ipairs(ERRORISH) do
      if ln:find(p) then
        table.insert(out, 1, short(ln))
        break
      end
    end
    if #out >= (max or 6) then break end
  end
  return out
end

-- "KeyError: 'start'" / "RuntimeError: …" — the last line a Python
-- traceback ends on, which names the actual failure.
local function last_exception(lines)
  for i = #lines, 1, -1 do
    local name, msg = lines[i]:match("^%s*([%a_][%w_%.]*Error):%s*(.*)$")
    if not name then name, msg = lines[i]:match("^%s*([%a_][%w_%.]*Exception):%s*(.*)$") end
    if name then return short(name .. ": " .. msg) end
  end
  return nil
end

-- ── Public ─────────────────────────────────────────────────────────────────

-- diagnose(log_text, status) → table
--   status: "failed" | "cancelled" | "ok" (anything else = "failed")
-- Returns { kind, id, title, why, fix, evidence = {lines}, also = {titles} }
--   kind: "error"     a known error broke the run
--         "warn"      run finished; a known warning explains a bad result
--         "problem"   Auto Sync printed its own [ERROR] CODE: message
--         "unknown"   failed, but no rule knows why (evidence = error lines)
--         "cancelled" the user pressed Stop
--         "ok"        nothing to explain
-- Never raises: a bug in here must not hide the log.
function M.diagnose(log_text, status)
  local ok, d = pcall(M._diagnose, log_text, status)
  if ok and type(d) == "table" then return d end
  return { kind = "unknown", title = "The run failed",
           why = "The reason could not be read from the log.",
           fix = "Open the full log below, or send a report with the button below.",
           evidence = {}, also = {} }
end

function M._diagnose(log_text, status)
  status = tostring(status or "failed"):lower()
  local failed = (status ~= "ok" and status ~= "cancelled")
  local lines = split_lines(log_text)

  -- 1. Known errors — the last line each rule matches.
  local hits = {}
  for order, rule in ipairs(M.RULES) do
    if not (rule.unless_pat and any_line(lines, rule.unless_pat)) then
      for i = #lines, 1, -1 do
        if rule_hits_line(rule, lines[i]) then
          hits[#hits + 1] = { rule = rule, at = i, order = order }
          break
        end
      end
    end
  end
  table.sort(hits, function(a, b)
    local ra = (a.rule.level == "error") and 0 or 1
    local rb = (b.rule.level == "error") and 0 or 1
    if ra ~= rb then return ra < rb end
    return a.order < b.order
  end)
  local function titles(from)
    local out, seen = {}, {}
    for i = from, #hits do
      local t = hits[i].rule.title
      if not seen[t] then seen[t] = true; out[#out + 1] = t end
    end
    return out
  end

  -- A stopped run is the user's own choice — say so, whatever the log shows.
  if status == "cancelled" then
    return { kind = "cancelled", title = "The run was stopped",
             why = "Stop was pressed (or REAPER was closed) before the run finished.",
             fix = "Start the run again and let it finish.",
             evidence = {}, also = titles(1) }
  end

  local top = hits[1]
  if top and not (failed and top.rule.level ~= "error") then
    return { kind = top.rule.level, id = top.rule.id,
             title = top.rule.title, why = top.rule.why, fix = top.rule.fix,
             evidence = around(lines, top.at), also = titles(2) }
  end

  -- 2. Auto Sync prints its own "PROBLEMS FOUND" block — [ERROR] CODE: words.
  --    A code no rule covers is still worth showing in its own words.
  local probs = {}
  for i, ln in ipairs(lines) do
    local sev, code, msg = ln:match("^%s*%[(%u+)%]%s+(%u[%u%d_]+):%s*(.+)$")
    if (sev == "ERROR" or sev == "WARN") and code then
      probs[#probs + 1] = { sev = sev, code = code, msg = msg, at = i }
    end
  end
  table.sort(probs, function(a, b)
    local ra = (a.sev == "ERROR") and 0 or 1
    local rb = (b.sev == "ERROR") and 0 or 1
    if ra ~= rb then return ra < rb end
    return a.at < b.at
  end)
  local p = probs[1]
  if p and not (failed and p.sev ~= "ERROR") then
    return { kind = "problem", id = p.code,
             title = "Auto Sync found a problem (" .. p.code .. ")",
             why = short(p.msg, 400),
             fix = "Follow what the message says. If it is unclear, send a report with the button below.",
             evidence = { short(lines[p.at]) }, also = titles(1) }
  end

  -- 3. Nothing known.
  if failed then
    local exc = last_exception(lines)
    return { kind = "unknown", title = "The run failed — not a known error yet",
             why = exc and ("The last error in the log says: " .. exc)
                   or "The log does not match any error this app knows about.",
             fix = "Run again once. If it fails the same way, send a report with the button below "
                   .. "(tick \"Attach this run's log\") so this error can be explained next time.",
             evidence = errorish(lines, 6), also = titles(1) }
  end
  return { kind = "ok", title = "", why = "", fix = "", evidence = {}, also = titles(1) }
end

-- Warnings for a run that FINISHED: every warn rule that fired, as
-- { {title, why, fix}, … } in RULES order. Empty when the run was clean.
function M.notes(log_text)
  local ok, out = pcall(function()
    local lines = split_lines(log_text)
    local res = {}
    for _, rule in ipairs(M.RULES) do
      if rule.level == "warn"
         and not (rule.unless_pat and any_line(lines, rule.unless_pat)) then
        for i = #lines, 1, -1 do
          if rule_hits_line(rule, lines[i]) then
            res[#res + 1] = { id = rule.id, title = rule.title, why = rule.why, fix = rule.fix }
            break
          end
        end
      end
    end
    return res
  end)
  return ok and out or {}
end

-- The reason as plain text — goes at the top of the "Shown in the panel"
-- block of the archived log, so a report email carries it too.
function M.as_text(d)
  if not d or d.kind == "ok" then return "" end
  local t = { "Reason: " .. tostring(d.title or "") }
  if d.why and d.why ~= "" then t[#t + 1] = "Why: " .. d.why end
  if d.fix and d.fix ~= "" then t[#t + 1] = "What to do: " .. d.fix end
  return table.concat(t, "\n")
end

-- ── Drawing (ReaImGui) ─────────────────────────────────────────────────────
-- Draws the reason box. `opts.push_font(ctx, size)` / `opts.pop_font(ctx)`
-- are the panel's own font helpers (optional — the dub panel has them).
local C_TITLE = { error = 0xFF7070FF, unknown = 0xFF7070FF, problem = 0xFF7070FF,
                  warn = 0xFFCC55FF, cancelled = 0xCCCCCCFF }
local C_LABEL = 0xAAAAAAFF
local C_BODY  = 0xEEEEEEFF

function M.render(ctx, d, opts)
  if not d or d.kind == "ok" then return end
  opts = opts or {}
  local R = reaper
  local function colored(col, fn)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), col); fn(); R.ImGui_PopStyleColor(ctx)
  end
  local function big(fn)
    local pushed = opts.push_font and opts.push_font(ctx, 20)
    fn()
    if pushed and opts.pop_font then opts.pop_font(ctx) end
  end

  colored(C_LABEL, function() R.ImGui_Text(ctx, "What went wrong") end)
  big(function()
    colored(C_TITLE[d.kind] or C_TITLE.error, function()
      R.ImGui_TextWrapped(ctx, d.title or "")
    end)
  end)
  R.ImGui_Dummy(ctx, 0, 4)
  if d.why and d.why ~= "" then
    colored(C_LABEL, function() R.ImGui_Text(ctx, "Why") end)
    colored(C_BODY, function() R.ImGui_TextWrapped(ctx, d.why) end)
    R.ImGui_Dummy(ctx, 0, 4)
  end
  if d.fix and d.fix ~= "" then
    colored(C_LABEL, function() R.ImGui_Text(ctx, "What to do") end)
    colored(C_BODY, function() R.ImGui_TextWrapped(ctx, d.fix) end)
  end
  if d.also and #d.also > 0 then
    R.ImGui_Dummy(ctx, 0, 4)
    colored(C_LABEL, function()
      R.ImGui_TextWrapped(ctx, "Also seen in this run: " .. table.concat(d.also, " · "))
    end)
  end
end

-- Notes on a FINISHED run (yellow): "Finished, but …". Nothing when clean.
function M.render_notes(ctx, notes)
  if not notes or #notes == 0 then return end
  local R = reaper
  R.ImGui_Dummy(ctx, 0, 6)
  for _, n in ipairs(notes) do
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), C_TITLE.warn)
    R.ImGui_TextWrapped(ctx, "!  " .. n.title)
    R.ImGui_PopStyleColor(ctx)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), C_BODY)
    R.ImGui_TextWrapped(ctx, n.why)
    R.ImGui_PopStyleColor(ctx)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), C_LABEL)
    R.ImGui_TextWrapped(ctx, "What to do: " .. n.fix)
    R.ImGui_PopStyleColor(ctx)
    R.ImGui_Dummy(ctx, 0, 4)
  end
end

return M
