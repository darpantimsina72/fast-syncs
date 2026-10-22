-- script_kit.lua — the script editor shared by the dub panel and Auto Sync
-- (0.15.14+). Two views of one text: "Script + tags" (the text itself) and
-- "Script" (every [tag] hidden; an edit there is merged back so each tag
-- stays in front of its word). ReaImGui's edit box cannot word-wrap, so
-- the box shows soft line breaks (" \n") that are removed before storing.
-- Loaded with dofile by both scripts; returns a table.
local M = {}

M.TAG_PAT = "%[/?[%a ]+%]"
-- The tag palette (same set the Step-4 prompts use). Click = copy.
M.TAG_LIST = {
  { "[calm]", "steady, unhurried" }, { "[contemplative]", "reflective" },
  { "[thoughtful]", "considered" },  { "[soft]", "quiet, gentle volume" },
  { "[warm]", "friendly, kind" },    { "[gentle]", "tender" },
  { "[slow]", "slower pace for a deep line" },
  { "[pause]", "a short pause before what follows" },
  { "[sighs]", "an exhale — use rarely" },
  { "[smiling]", "light, a smile in the voice" },
  { "[curious]", "questioning" },    { "[lighthearted]", "playful" },
  { "[emphatic]", "strong emphasis — rarely" },
  { "[serious]", "grave — rarely" },
}

function M.has_tags(s) return (s or ""):find(M.TAG_PAT) ~= nil end

-- The script with its tags removed, tidily (no double spaces, a line that
-- only held tags disappears). Mirrors the engine's _without_tags.
function M.tags_strip(s)
  local out = {}
  for line in ((s or "") .. "\n"):gmatch("(.-)\n") do
    if not line:match("%S") then
      out[#out + 1] = ""
    else
      local clean = line:gsub(M.TAG_PAT, " "):gsub("%s+", " ")
                        :gsub("^ ", ""):gsub(" $", "")
      if clean ~= "" then out[#out + 1] = clean end
    end
  end
  local r = table.concat(out, "\n"):gsub("\n\n\n+", "\n\n")
  return (r:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Tags of a tagged text, each with the index of the plain word it precedes
-- (#words + 1 = at the end), plus that plain word list.
function M._tag_anchors(tagged)
  local words, tags = {}, {}
  local pos = 1
  local s = tagged or ""
  while pos <= #s do
    local a, b = s:find(M.TAG_PAT, pos)
    local chunk = s:sub(pos, (a or (#s + 1)) - 1)
    for w in chunk:gmatch("%S+") do words[#words + 1] = w end
    if not a then break end
    tags[#tags + 1] = { tag = s:sub(a, b), at = #words + 1 }
    pos = b + 1
  end
  return words, tags
end

-- Re-attach the tags of *old_tagged* to *new_plain* (the words an editor
-- just typed in the Script view). Words are lined up with a longest-common-
-- subsequence pass; a tag whose word was deleted moves to the next surviving
-- word. The new text keeps its own spacing and line breaks.
function M.tags_merge(old_tagged, new_plain)
  local old_words, tags = M._tag_anchors(old_tagged)
  if #tags == 0 then return new_plain end
  local new_words = {}
  for w in (new_plain or ""):gmatch("%S+") do new_words[#new_words + 1] = w end
  local n, m = #old_words, #new_words
  -- LCS table, bottom-up. A paragraph is a few hundred words at most.
  local L = {}
  for i = n + 1, 1, -1 do
    L[i] = {}
    for j = m + 1, 1, -1 do
      if i > n or j > m then L[i][j] = 0
      elseif old_words[i] == new_words[j] then L[i][j] = L[i + 1][j + 1] + 1
      else L[i][j] = math.max(L[i + 1][j], L[i][j + 1]) end
    end
  end
  local map, i, j = {}, 1, 1
  while i <= n and j <= m do
    if old_words[i] == new_words[j] then map[i] = j; i = i + 1; j = j + 1
    elseif L[i + 1][j] >= L[i][j + 1] then i = i + 1
    else j = j + 1 end
  end
  -- Where each old word's tags land in the new text.
  local before = {}           -- new word index -> { tags… }
  for _, t in ipairs(tags) do
    local k, dest = t.at, nil
    while k <= n do
      if map[k] then dest = map[k] break end
      k = k + 1
    end
    -- No surviving word after it: keep it in front of the word that now
    -- sits where the old one was, else at the very end.
    dest = dest or math.min(t.at, m + 1)
    before[dest] = before[dest] or {}
    table.insert(before[dest], t.tag)
  end
  local out, wi = {}, 0
  for sp, w in (new_plain or ""):gmatch("(%s*)(%S+)") do
    wi = wi + 1
    out[#out + 1] = sp
    if before[wi] then out[#out + 1] = table.concat(before[wi], " ") .. " " end
    out[#out + 1] = w
  end
  local tail = (new_plain or ""):match("(%s*)$") or ""
  if before[wi + 1] then
    out[#out + 1] = (wi > 0 and " " or "") .. table.concat(before[wi + 1], " ")
  end
  out[#out + 1] = tail
  return table.concat(out)
end

-- Soft-wrap *s* to *width* pixels with the current font. Real line breaks
-- stay; inserted ones are " \n".
function M.soft_wrap(ctx, s, width)
  if not reaper.ImGui_CalcTextSize or width < 40 then return s end
  local lines = {}
  for raw in ((s or "") .. "\n"):gmatch("(.-)\n") do
    local line = raw:gsub("%s+$", "")
    local cur = ""
    for sp, w in line:gmatch("(%s*)(%S+)") do
      local try = (cur == "") and (sp .. w) or (cur .. sp .. w)
      if cur ~= "" and reaper.ImGui_CalcTextSize(ctx, try) > width then
        lines[#lines + 1] = cur .. " "   -- the space marks a soft break
        cur = w
      else
        cur = try
      end
    end
    lines[#lines + 1] = cur
  end
  return table.concat(lines, "\n")
end

function M.soft_unwrap(s)
  return ((s or ""):gsub(" \n", " "))
end

-- The editor. *id* keys its cache; *text* is the canonical (tagged) text;
-- *view* is "tags" or "plain"; *min_lines* sizes an empty box. Returns
-- changed, new_canonical. The box is as tall as its wrapped text, so it
-- never scrolls sideways or inside itself.
M.ed_cache = {}
function M.script_box(ctx, id, text, view, min_lines)
  text = text or ""
  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx)) or 400
  local width = avail - 22          -- frame padding + a scrollbar's room
  local c = M.ed_cache[id]
  if not (c and c.src == text and c.view == view and c.w == width) then
    if not (c and c.active) then
      local shown = (view == "plain") and M.tags_strip(text) or text
      c = { src = text, view = view, w = width,
            disp = M.soft_wrap(ctx, shown, width) }
      M.ed_cache[id] = c
    end
  end
  local n = 1
  for _ in c.disp:gmatch("\n") do n = n + 1 end
  n = math.max(n, min_lines or 2)
  local lh = (reaper.ImGui_GetTextLineHeight and
              reaper.ImGui_GetTextLineHeight(ctx)) or 18
  local cb = M._wrap_cb(ctx)
  local rv, txt
  if cb then
    rv, txt = reaper.ImGui_InputTextMultiline(ctx, id, c.disp, -1, n * lh + 12,
      reaper.ImGui_InputTextFlags_CallbackAlways(), cb)
  else
    rv, txt = reaper.ImGui_InputTextMultiline(ctx, id, c.disp, -1, n * lh + 12)
  end
  c.active = reaper.ImGui_IsItemActive(ctx)
  if rv then
    c.disp = txt
    -- Wrap WHILE typing: the line being typed past the edge gets a soft
    -- break after its last fitting space, inserted by the callback on the
    -- next frame (the box owns its text while it has focus, so it cannot
    -- simply be replaced). Words are never split.
    local at = cb and M.next_break(ctx, txt, width)
    if at then reaper.ImGui_Function_SetValue(cb, "want", at) end
    local flat = M.soft_unwrap(txt)
    local new = (view == "plain") and M.tags_merge(text, flat) or flat
    c.src = new
    return true, new
  end
  return false, text
end

-- Byte offset (0-based, for the callback) just after the last space that
-- still fits on the first too-long line of *txt*, or nil.
function M.next_break(ctx, txt, width)
  if not reaper.ImGui_CalcTextSize then return nil end
  local pos = 1
  for line in (txt .. "\n"):gmatch("(.-)\n") do
    if reaper.ImGui_CalcTextSize(ctx, line) > width then
      local best
      for k in line:gmatch("() ") do
        if k > 1 and reaper.ImGui_CalcTextSize(ctx, line:sub(1, k - 1)) <= width then
          best = k
        end
      end
      if best then return pos + best - 1 end
    end
    pos = pos + #line + 1
  end
  return nil
end

-- The EEL callback that inserts a soft break ("\n" after a space) at the
-- offset Lua asks for. Made once per ReaImGui context; nil when this
-- ReaImGui lacks EEL callbacks (then wrapping waits for a click-out).
M._cbs = {}
function M._wrap_cb(ctx)
  local have = M._cbs[ctx]
  if have ~= nil then return have or nil end
  local fn = false
  if reaper.ImGui_CreateFunctionFromEEL and reaper.ImGui_Attach
     and reaper.ImGui_InputTextFlags_CallbackAlways
     and reaper.ImGui_Function_SetValue then
    local ok, f = pcall(reaper.ImGui_CreateFunctionFromEEL,
      'want >= 0 ? ( InputTextCallback_InsertChars(want, "\\n"); want = -1; );')
    if ok and f then
      reaper.ImGui_Attach(ctx, f)
      reaper.ImGui_Function_SetValue(f, "want", -1)
      fn = f
    end
  end
  M._cbs[ctx] = fn
  return fn or nil
end

-- Child-window flags for a script frame the editor can drag taller (bottom
-- edge) as well as the window wider.
function M.frame_flags()
  local f = reaper.ImGui_ChildFlags_Borders and reaper.ImGui_ChildFlags_Borders() or 1
  if reaper.ImGui_ChildFlags_ResizeY then f = f | reaper.ImGui_ChildFlags_ResizeY() end
  return f
end

-- The "Script | Script + tags" switch. *key* names whose view it sets.
M.views = {}
function M.view_switch(ctx, key)
  -- 0.15.14: words-only view by default; tags one click away.
  local v = M.views[key] or "plain"
  local function seg(label, val)
    local on = (v == val)
    if on then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x2A6699FF)
    end
    if reaper.ImGui_SmallButton(ctx, label .. '##vw' .. key) then
      M.views[key] = val
    end
    if on then reaper.ImGui_PopStyleColor(ctx) end
  end
  seg(' Script ', "plain")
  reaper.ImGui_SameLine(ctx, 0, 2)
  seg(' Script + tags ', "tags")
  return M.views[key] or "plain"
end

return M
