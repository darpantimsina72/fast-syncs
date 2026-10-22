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
  -- Usable text width = box width minus its inner padding on both sides
  -- and room for a scrollbar, read from the live style (themes differ).
  local pad, sb = 8, 14
  if reaper.ImGui_GetStyleVar and reaper.ImGui_StyleVar_FramePadding then
    pad = (reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding())) or pad
  end
  if reaper.ImGui_GetStyleVar and reaper.ImGui_StyleVar_ScrollbarSize then
    sb = (reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize())) or sb
  end
  local width = avail - 2 * pad - sb - 12
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
  local boxh = n * lh + 12
  local pady = 3
  if reaper.ImGui_GetStyleVar and reaper.ImGui_StyleVar_FramePadding then
    pady = select(2, reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding())) or pady
  end
  local cb = M._wrap_cb(ctx)
  -- Joined letters ALWAYS, typing included: the OS-drawn picture sits under
  -- an invisible edit box that does the typing; the cursor and selection
  -- are drawn on the picture at the joined-letter positions (measured with
  -- the OS text engine, see M.joined_x). Without js_ReaScriptAPI: the
  -- ordinary box.
  local joined = cb and M.can_draw_joined()
  local x0, y0
  if joined then
    x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
    local img = M.picture(ctx, c, avail, boxh, lh, pad, pady)
    if img then
      reaper.ImGui_Image(ctx, img, avail, boxh)
      reaper.ImGui_SetCursorScreenPos(ctx, x0, y0)
    else
      joined = false
    end
  end
  local hidden = 0
  if joined then
    for _, col in ipairs({ "Col_Text", "Col_FrameBg", "Col_FrameBgHovered",
                           "Col_FrameBgActive", "Col_TextSelectedBg",
                           "Col_InputTextCursor" }) do
      if reaper["ImGui_" .. col] then
        reaper.ImGui_PushStyleColor(ctx, reaper["ImGui_" .. col](), 0x00000000)
        hidden = hidden + 1
      end
    end
  end
  local rv, txt
  if cb then
    rv, txt = reaper.ImGui_InputTextMultiline(ctx, id, c.disp, -1, boxh,
      reaper.ImGui_InputTextFlags_CallbackAlways(), cb)
  else
    rv, txt = reaper.ImGui_InputTextMultiline(ctx, id, c.disp, -1, boxh)
  end
  if hidden > 0 then reaper.ImGui_PopStyleColor(ctx, hidden) end
  c.active = reaper.ImGui_IsItemActive(ctx)
  if joined and c.active then
    M.joined_overlay(ctx, cb, c, rv and txt or c.disp, x0, y0, pad, pady, lh, avail)
  end
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

-- ── Joined-letter pictures (needs js_ReaScriptAPI) ────────────────────────
-- The panel sets M.joined_font to the OS font family for the language.
M.joined_font = nil
function M.can_draw_joined()
  return reaper.JS_LICE_CreateBitmap ~= nil and reaper.JS_GDI_DrawText ~= nil
     and reaper.ImGui_CreateImageFromLICE ~= nil and M.joined_font ~= nil
end

M._gdi_fonts = {}
function M._gdi_font(name, px)
  local k = name .. "@" .. px
  if not M._gdi_fonts[k] then
    M._gdi_fonts[k] = reaper.JS_GDI_CreateFont(px, 400, 0, false, false, false, name)
  end
  return M._gdi_fonts[k]
end

-- The picture for cache entry *c* (its soft-wrapped lines), redrawn only
-- when the text, size or font change. Lines are drawn one by one at the
-- breaks the editor uses, so the picture and the edit box wrap alike.
function M.picture(ctx, c, w, h, lh, pad, pady)
  local scale = (reaper.ImGui_GetWindowDpiScale and
                 reaper.ImGui_GetWindowDpiScale(ctx)) or 1
  local key = table.concat({ c.disp, w, h, M.joined_font, scale }, "\1")
  if c.pic and c.pic_key == key and
     (not reaper.ImGui_ValidatePtr or reaper.ImGui_ValidatePtr(c.pic, "ImGui_Image*")) then
    return c.pic
  end
  local bw, bh = math.max(1, math.floor(w * scale)), math.max(1, math.floor(h * scale))
  local bmp = reaper.JS_LICE_CreateBitmap(true, bw, bh)
  if not bmp then return nil end
  -- Background = the edit box colour (opaque), so a click shows no jump.
  local bg = 0xFF232A36
  if reaper.ImGui_GetStyleColor and reaper.ImGui_Col_FrameBg then
    local rgba = reaper.ImGui_GetStyleColor(ctx, reaper.ImGui_Col_FrameBg())
    bg = 0xFF000000 | ((rgba >> 8) & 0xFFFFFF)
  end
  reaper.JS_LICE_Clear(bmp, bg)
  local dc = reaper.JS_LICE_GetDC(bmp)
  local px = math.floor(((reaper.ImGui_GetFontSize and reaper.ImGui_GetFontSize(ctx)) or 17) * scale + 0.5)
  reaper.JS_GDI_SelectObject(dc, M._gdi_font(M.joined_font, px))
  reaper.JS_GDI_SetTextColor(dc, 0xE6E6E6)   -- grey: same in RGB and BGR
  if reaper.JS_GDI_SetTextBkMode then reaper.JS_GDI_SetTextBkMode(dc, 0) end
  local y = (pady or 3) * scale
  for line in (c.disp .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then
      reaper.JS_GDI_DrawText(dc, line, #line, math.floor(pad * scale), math.floor(y),
                             bw, math.floor(y + lh * scale), "LEFT|TOP|SINGLELINE|NOPREFIX|NOCLIP")
    end
    y = y + lh * scale
  end
  local img = reaper.ImGui_CreateImageFromLICE(bmp)
  if reaper.JS_LICE_DestroyBitmap then reaper.JS_LICE_DestroyBitmap(bmp) end
  c.pic, c.pic_key = img, key
  return img
end

-- ── Joined-letter cursor, selection and clicks ────────────────────────────
-- Shaped width of *s* in screen pixels: draw s.."|" off-screen with the OS
-- text engine and find the tall bar from the right on a few middle rows.
-- The add-on has no text-measure call for shaped text; the bar is exact.
M._wcache = {}
function M.joined_x(ctx, s)
  local scale = (reaper.ImGui_GetWindowDpiScale and
                 reaper.ImGui_GetWindowDpiScale(ctx)) or 1
  local px = math.floor(((reaper.ImGui_GetFontSize and reaper.ImGui_GetFontSize(ctx)) or 17) * scale + 0.5)
  local key = M.joined_font .. "@" .. px .. "@" .. s
  if M._wcache[key] then return M._wcache[key] end
  local W, H = 4096, px * 2
  if M._mbmp_h ~= H then
    if M._mbmp and reaper.JS_LICE_DestroyBitmap then reaper.JS_LICE_DestroyBitmap(M._mbmp) end
    M._mbmp, M._mbmp_h = reaper.JS_LICE_CreateBitmap(true, W, H), H
  end
  local b = M._mbmp
  reaper.JS_LICE_Clear(b, 0xFF000000)
  local dc = reaper.JS_LICE_GetDC(b)
  reaper.JS_GDI_SelectObject(dc, M._gdi_font(M.joined_font, px))
  reaper.JS_GDI_SetTextColor(dc, 0xFFFFFF)
  if reaper.JS_GDI_SetTextBkMode then reaper.JS_GDI_SetTextBkMode(dc, 0) end
  local t = s .. "|"
  reaper.JS_GDI_DrawText(dc, t, #t, 0, 0, W, H, "LEFT|TOP|SINGLELINE|NOPREFIX|NOCLIP")
  local rows = { math.floor(px * 0.45), math.floor(px * 0.6), math.floor(px * 0.75) }
  -- Start the scan a little right of the unjoined width (joined text is
  -- never much wider), not at the far edge: ~100x fewer pixel reads.
  local est = W - 1
  if reaper.ImGui_CalcTextSize then
    est = math.min(W - 1, math.floor((reaper.ImGui_CalcTextSize(ctx, t) * 1.5 + 40) * scale))
  end
  local edge = 0
  for x = est, 0, -1 do
    local hit = false
    for _, y in ipairs(rows) do
      if (reaper.JS_LICE_GetPixel(b, x, y) & 0xFFFFFF) > 0x404040 then hit = true break end
    end
    if hit then edge = x break end
  end
  if not M._bar0 then M._bar0 = {} end
  local k0 = M.joined_font .. "@" .. px
  if s ~= "" and not M._bar0[k0] then M.joined_x(ctx, "") end
  if s == "" then M._bar0[k0] = edge end
  local w = (edge - (M._bar0[k0] or edge)) / scale
  M._wcache[key] = w
  return w
end

-- Line index (0-based), line start offset and line text for byte offset *pos*.
local function line_at(txt, pos)
  local start, i = 0, 0
  for line in (txt .. "\n"):gmatch("(.-)\n") do
    if pos <= start + #line then return i, start, line end
    start, i = start + #line + 1, i + 1
  end
  return i, start, ""
end

-- Byte offset in *line* nearest to x (screen px from the text start), on
-- UTF-8 character boundaries, by binary search over shaped widths.
local function offset_at_x(ctx, line, x)
  local cuts = { 0 }
  for p in line:gmatch("()[^\128-\191]") do if p > 1 then cuts[#cuts + 1] = p - 1 end end
  cuts[#cuts + 1] = #line
  local lo, hi = 1, #cuts
  while hi - lo > 1 do
    local mid = (lo + hi) // 2
    if M.joined_x(ctx, line:sub(1, cuts[mid])) < x then lo = mid else hi = mid end
  end
  local wl = M.joined_x(ctx, line:sub(1, cuts[lo]))
  local wh = M.joined_x(ctx, line:sub(1, cuts[hi]))
  return (x - wl < wh - x) and cuts[lo] or cuts[hi]
end

function M.joined_overlay(ctx, cb, c, txt, x0, y0, pad, pady, lh, w)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  -- Mouse: place the cursor (and drag a selection) by joined positions,
  -- overriding the box's own guess, which uses unjoined widths.
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local inside = mx >= x0 and mx <= x0 + w and my >= y0
  if inside and (reaper.ImGui_IsMouseClicked(ctx, 0) or
                 (reaper.ImGui_IsMouseDown(ctx, 0) and c.drag)) then
    local li = math.max(0, math.floor((my - y0 - pady) / lh))
    local start, i = 0, 0
    local line = ""
    for l in (txt .. "\n"):gmatch("(.-)\n") do
      if i == li then line = l break end
      start, i = start + #l + 1, i + 1
    end
    if i < li then line = "" end
    local pos = start + offset_at_x(ctx, line, mx - x0 - pad)
    if reaper.ImGui_IsMouseClicked(ctx, 0) then c.drag = pos end
    local a, b = math.min(c.drag, pos), math.max(c.drag, pos)
    reaper.ImGui_Function_SetValue(cb, "sets", a)
    reaper.ImGui_Function_SetValue(cb, "sete", b)
    reaper.ImGui_Function_SetValue(cb, "setc", pos)
  end
  if not reaper.ImGui_IsMouseDown(ctx, 0) then c.drag = nil end
  local cur = math.floor(reaper.ImGui_Function_GetValue(cb, "cur") or 0)
  local ss  = math.floor(reaper.ImGui_Function_GetValue(cb, "ss") or cur)
  local se  = math.floor(reaper.ImGui_Function_GetValue(cb, "se") or cur)
  local function xy(pos)
    local li, start, line = line_at(txt, pos)
    return x0 + pad + M.joined_x(ctx, line:sub(1, pos - start)), y0 + pady + li * lh
  end
  -- Selection: one band per line it covers.
  if se ~= ss then
    local a, b = math.min(ss, se), math.max(ss, se)
    local p = a
    while p < b do
      local li, start, line = line_at(txt, p)
      local e = math.min(b, start + #line)
      local xa, ya = xy(p)
      local xb = select(1, xy(e))
      reaper.ImGui_DrawList_AddRectFilled(dl, xa, ya, math.max(xb, xa + 4), ya + lh, 0x4488FF66)
      p = start + #line + 1
    end
  end
  -- Blinking cursor.
  if math.floor(reaper.time_precise() * 2) % 2 == 0 then
    local cx, cy = xy(cur)
    reaper.ImGui_DrawList_AddLine(dl, cx, cy, cx, cy + lh, 0xFFFFFFFF, 1.5)
  end
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
      'cur = CursorPos; ss = SelectionStart; se = SelectionEnd;' ..
      'want >= 0 ? ( InputTextCallback_InsertChars(want, "\\n"); want = -1; );' ..
      'setc >= 0 ? ( CursorPos = setc; SelectionStart = sets; SelectionEnd = sete; setc = -1; );')
    if ok and f then
      reaper.ImGui_Attach(ctx, f)
      reaper.ImGui_Function_SetValue(f, "want", -1)
      reaper.ImGui_Function_SetValue(f, "setc", -1)
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
