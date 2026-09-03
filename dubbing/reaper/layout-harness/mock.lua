-- ══════════════════════════════════════════════════════════════════════════
-- A coarse Dear ImGui layout model in Lua, enough to catch COLLISIONS:
-- any item or drawn string that lands on top of something already drawn.
-- Everything is kept in one absolute coordinate space so cursor items and
-- DrawList text can collide with each other, which is how V5.pill and the
-- plan strip's ruler are tested.
-- ══════════════════════════════════════════════════════════════════════════

local T = {}                        -- the harness's own namespace
_G.__T = T

T.LINE_H  = 17                      -- 14 px face + ImGui's leading
T.FRAME_H = 22                      -- 14 px face + FramePadding.y * 2 (4)
T.regime  = 'honest'                -- 'honest' | 'nonascii0' | 'all0'
T.missing = {}                      -- ImGui function names to report absent

-- ── text metrics ──────────────────────────────────────────────────────────
local function cw(cp)
  if cp == 32 then return 4.0 end
  if cp < 0x80 then
    local c = string.char(cp)
    if c:match('[A-Z]') then return 8.6 end
    if c:match('[0-9]') then return 7.8 end
    if ("iljI.,:;'|!"):find(c, 1, true) then return 3.6 end
    if ("mwMW@"):find(c, 1, true) then return 11.2 end
    return 7.2
  end
  -- Devanagari / Bengali matras, signs and virama carry no advance
  if (cp >= 0x0900 and cp <= 0x0903) or (cp >= 0x093A and cp <= 0x094F)
  or (cp >= 0x0951 and cp <= 0x0957) or (cp >= 0x0981 and cp <= 0x0983)
  or (cp >= 0x09BC and cp <= 0x09CD) then return 0 end
  if cp >= 0x0900 and cp <= 0x0DFF then return 9.0 end
  if cp == 0x00B7 or cp == 0x2022 then return 4.5 end   -- ·  •
  if cp == 0x2026 then return 12.0 end                  -- …
  if cp == 0x2500 or cp == 0x2502 then return 7.0 end
  if cp >= 0x2190 and cp <= 0x2BFF then return 14.0 end -- arrows, geometric
  if cp >= 0x1F300 then return 16.0 end                 -- emoji
  return 10.0
end

-- what a string is REALLY worth on screen, for the harness's own maths
local function visible(s)
  s = tostring(s or '')
  local cut = s:find('##', 1, true)
  if cut then s = s:sub(1, cut - 1) end
  return s
end

function T.true_w(s)
  s = visible(s)
  local w, ok = 0, true
  for _, cp in utf8.codes(s) do w = w + cw(cp) end
  return w
end

-- what ReaImGui ANSWERS, which is not always the truth
function T.measured_w(s)
  local vis = visible(s)
  if T.regime == 'all0' then return 0 end
  local nonascii = false
  for _, cp in utf8.codes(vis) do if cp >= 0x80 then nonascii = true end end
  if T.regime == 'nonascii0' and nonascii then return 0 end
  return T.true_w(vis)
end

-- ── the window stack ──────────────────────────────────────────────────────
T.win, T.items, T.collisions, T.overflow, T.notes = nil, {}, {}, {}, {}
T.pushed_col, T.pushed_var, T.pushed_font = 0, 0, 0
T.spacing = { x = 8, y = 6 }
T.frame_pad = { x = 8, y = 4 }
T.open_pairs = {}

local function newwin(id, x, y, w, h)
  return {
    id = id, x = x, y = y, w = w, h = h,
    x0 = x + 8, y0 = y + 8,
    cx = x + 8, cy = y + 8, indent = 0,
    prev_x2 = x + 8, prev_y = y + 8, prev_h = 0, line_h = 0,
    bottom = y + 8, right = x + 8,
    next_w = nil, items = {},
  }
end

function T.reset(opts)
  opts = opts or {}
  T.regime  = opts.regime or 'honest'
  T.missing = opts.missing or {}
  T.items, T.collisions, T.overflow, T.notes = {}, {}, {}, {}
  T.pushed_col, T.pushed_var, T.pushed_font = 0, 0, 0
  T.open_pairs = {}
  T.stack = { newwin('root', 0, 0, opts.w or 1040, opts.h or 660) }
  T.win = T.stack[1]
end

local function top() return T.stack[#T.stack] end

-- Record a rectangle and shout if it lands on one already recorded.
-- *soft* rectangles (a Dummy, a group's own background) do not collide.
function T.rect(x, y, x2, y2, label, kind, soft)
  local w = top()
  local r = { x = x, y = y, x2 = x2, y2 = y2, kind = kind,
              label = visible(label):sub(1, 44), win = w.id, soft = soft }
  if not soft and x2 > x + 0.5 then
    local n = #w.items
    for i = n, math.max(1, n - 60), -1 do
      local p = w.items[i]
      if not p.soft then
        local ox = math.min(x2, p.x2) - math.max(x, p.x)
        local oy = math.min(y2, p.y2) - math.max(y, p.y)
        if ox > 1.0 and oy > 1.0 then
          T.collisions[#T.collisions + 1] = {
            win = w.id, ox = ox, oy = oy,
            over = p.label, over_kind = p.kind,
            by = r.label, by_kind = kind,
            x = x, y = y,
          }
          break
        end
      end
    end
  end
  w.items[#w.items + 1] = r
  T.items[#T.items + 1] = r
  return r
end

-- One cursor item: sizes itself, collides, then advances the cursor EAGERLY
-- (ImGui's ItemSize moves CursorPos.y at once; SameLine walks back).
local function item(label, w, h, kind, soft)
  local win = top()
  h = h or T.LINE_H
  local x2 = win.cx + w
  if win.is_table and win.cols then
    -- Dear ImGui CLIPS a cell's content to the cell. An overlong string is cut
    -- at the column boundary, never drawn across the next column — so clamping
    -- here is the difference between modelling a table and inventing collisions
    -- it cannot produce on screen.
    local c = win.cols[(win.col or 0) + 1]
    if c then x2 = math.min(x2, win.x0 + c.x + c.w - 2) end
  end
  local r = T.rect(win.cx, win.cy, x2, win.cy + h, label, kind, soft)
  win.prev_x2, win.prev_y = win.cx + w, win.cy
  win.prev_h = h
  win.line_h = math.max(win.line_h, h)
  win.right  = math.max(win.right, win.cx + w)
  win.bottom = math.max(win.bottom, win.cy + h)
  win.cy = win.cy + win.line_h + T.spacing.y
  win.cx = win.x0 + win.indent
  win.line_h = 0
  win.next_w = nil
  return r
end
T.item = item

-- ImGui width conventions: nil/0 = default, <0 = fill to the edge minus n
local function res_w(w, dflt)
  local win = top()
  local right = win.x + win.w - 8
  if w == nil or w == 0 then return dflt end
  if w < 0 then return math.max(1, right + w - win.cx) end
  return w
end

local function avail_x() local w = top() return math.max(0, w.x + w.w - 8 - w.cx) end
local function avail_y() local w = top() return math.max(0, w.y + w.h - 8 - w.cy) end

-- ── the reaper table ──────────────────────────────────────────────────────
local R = {}

local function stub() return nil end

-- Enum getters must answer a NUMBER: the panel ORs them together.
-- NOT '_Flags_': the real names are ImGui_WindowFlags_*, ImGui_TableFlags_*,
-- ImGui_ChildFlags_* — there is no underscore before 'Flags'. Getting this
-- wrong makes every `f | reaper.ImGui_WindowFlags_NoScrollbar()` die on nil.
local ENUMISH = { 'Col_', 'Flags_', 'StyleVar_', 'Cond_', 'Dir_',
                  'MouseButton_', 'Key_', 'Axis_', 'SortDirection_' }

-- One stable bit per distinct flag name, handed out on demand. NoScrollbar is
-- pinned to bit 0 so BeginChild can test for it: a child that asked not to
-- scroll and then overflows is a bug, a child that scrolls is doing its job.
T.FLAGBIT = { ImGui_WindowFlags_NoScrollbar = 1 }
T.NOSCROLL = 1
local flag_next = 1
local function flagbit(name)
  if not T.FLAGBIT[name] then
    flag_next = flag_next + 1
    if flag_next > 26 then flag_next = 2 end
    T.FLAGBIT[name] = 1 << flag_next
  end
  return T.FLAGBIT[name]
end

setmetatable(R, { __index = function(_, k)
  if T.missing[k] then return nil end
  local name = tostring(k)
  for _, pat in ipairs(ENUMISH) do
    if name:find(pat, 1, true) then
      local v = flagbit(name)
      return function() return v end
    end
  end
  return stub
end })

-- load-time calls that kill the chunk if they answer wrong
R.GetOS            = function() return 'Win64' end
-- No filesystem in fengari — but every read the panel does goes through
-- io.open, and one thing worth testing (the review screen's time mapping)
-- reads an SRT off disk. T.files[path] = contents makes exactly that path
-- readable; everything else, and every WRITE, answers nil as before.
T.files = {}
io.open = function(path, mode)
  if mode and tostring(mode):find('w') then return nil end
  local data = T.files[path or '']
  if not data then return nil end
  return {
    read  = function(_, _) return data end,
    close = function() end,
  }
end
R.time_precise     = function() return 1000.0 end
-- ── a minimal project: tracks, items, takes, sources ──────────────────────
-- Enough of REAPER's media model to exercise the source-REGION code, which
-- decides what gets transcribed and dubbed from item positions, trims and the
-- time selection. That decision spends money, so it is worth a test.
--
-- An item doubles as its own take and its own source — the panel only ever
-- walks item -> take -> source and asks each for one or two numbers, and three
-- tables per item would be three chances to wire the fixture wrong.
--   item = { pos=, len=, offs=0, rate=1, file='', src_len=, selected=false }
-- T.project stays put across T.reset (like T.files): a fixture is set up once
-- and drawn under every regime.
T.project = { tracks = {} }

function T.set_project(p)
  T.project = p or { tracks = {} }
  for _, tr in ipairs(T.project.tracks or {}) do
    for _, it in ipairs(tr.items or {}) do
      it._track = tr
      it.offs = it.offs or 0
      it.rate = it.rate or 1
      it.src_len = it.src_len or it.len
    end
  end
  return T.project
end

local function _tracks() return (T.project and T.project.tracks) or {} end

local function _selected()
  local out = {}
  for _, tr in ipairs(_tracks()) do
    for _, it in ipairs(tr.items or {}) do
      if it.selected then out[#out + 1] = it end
    end
  end
  return out
end

R.CountTracks = function() return #_tracks() end
R.GetTrack    = function(_, i) return _tracks()[i + 1] end
R.GetSetMediaTrackInfo_String = function(tr, key, val, set)
  if set then
    if key == 'P_NAME' and tr then tr.name = val end
    return true
  end
  if key == 'P_NAME' then return true, (tr and tr.name) or '' end
  return false, ''
end
R.CountTrackMediaItems = function(tr) return #((tr and tr.items) or {}) end
R.GetTrackMediaItem    = function(tr, i) return ((tr and tr.items) or {})[i + 1] end
R.GetMediaItemTrack    = function(it) return it and it._track end
R.CountMediaItems      = function()
  local n = 0
  for _, tr in ipairs(_tracks()) do n = n + #((tr.items) or {}) end
  return n
end
R.GetMediaItem = function(_, i)
  local n = 0
  for _, tr in ipairs(_tracks()) do
    for _, it in ipairs(tr.items or {}) do
      if n == i then return it end
      n = n + 1
    end
  end
  return nil
end
R.CountSelectedMediaItems = function() return #_selected() end
R.GetSelectedMediaItem    = function(_, i) return _selected()[i + 1] end
R.GetMediaItemInfo_Value = function(it, key)
  if not it then return 0 end
  if key == 'D_POSITION' then return it.pos or 0 end
  if key == 'D_LENGTH'   then return it.len or 0 end
  return 0
end
R.GetMediaItemTakeInfo_Value = function(tk, key)
  if not tk then return 0 end
  if key == 'D_STARTOFFS' then return tk.offs or 0 end
  if key == 'D_PLAYRATE'  then return tk.rate or 1 end
  return 0
end
R.GetActiveTake            = function(it) return it end
R.TakeIsMIDI               = function(tk) return (tk and tk.midi) or false end
R.GetMediaItemTake_Source  = function(tk) return tk end
R.GetMediaSourceParent     = function() return nil end
R.GetMediaSourceFileName   = function(src) return (src and src.file) or '' end
R.GetMediaSourceLength     = function(src)
  return (src and src.src_len) or 0, false
end
R.GetSet_LoopTimeRange = function(isSet, _, s, e)
  local pj = T.project or {}
  if isSet then pj.time_sel = { s, e } return s, e end
  local ts = pj.time_sel
  if not ts then return 0, 0 end
  return ts[1], ts[2]
end
R.GetProjectName   = function() return '', 'Sadhguru_Aug19.rpp' end
R.EnumProjects     = function() return nil, '' end
R.GetProjectPath   = function() return 'C:\\proj' end
R.GetResourcePath  = function() return 'C:\\reaper' end
R.defer            = function() end
R.ShowConsoleMsg   = function() end
R.APIExists        = function(n) return not T.missing[n] end

-- ── text ──────────────────────────────────────────────────────────────────
R.ImGui_CalcTextSize = function(_, s) return T.measured_w(s), T.LINE_H end

R.ImGui_Text = function(_, s)
  item(s, T.true_w(s), T.LINE_H, 'text')
end
R.ImGui_TextDisabled = R.ImGui_Text
R.ImGui_TextColored  = function(_, _, s) item(s, T.true_w(s), T.LINE_H, 'text') end

R.ImGui_TextWrapped = function(_, s)
  local w   = math.max(40, avail_x())
  local tw  = T.true_w(s)
  local n   = math.max(1, math.ceil(tw / w))
  item(s, math.min(tw, w), n * T.LINE_H, 'wrapped')
end

R.ImGui_LabelText = function(_, l, v) item(l .. v, T.true_w(l .. v), T.LINE_H, 'text') end

-- ── widgets ───────────────────────────────────────────────────────────────
-- ImGui reads a 0 size as "use the default", but 0 is TRUTHY in Lua, so
-- `h or FRAME_H` keeps the zero and every Button(label, w, 0) came out with no
-- height at all — which quietly removed a whole chip row from the layout model.
local function nz(v) if v == nil or v == 0 then return nil end return v end

local function framed(label, w, h, kind, dflt)
  local win = top()
  w = res_w(nz(w) or win.next_w, dflt or (T.true_w(label) + 2 * T.frame_pad.x))
  return item(label, w, nz(h) or T.FRAME_H, kind)
end

R.ImGui_Button = function(_, label, w, h)
  framed(label, nz(w) or top().next_w, h, 'button')
  return false
end
R.ImGui_SmallButton = function(_, label)
  item(label, T.true_w(label) + 8, T.LINE_H, 'smallbutton')
  return false
end
-- An InvisibleButton is a hit target, not visible content: the plan strip
-- deliberately draws its whole ruler on top of one. Soft, so it never collides.
R.ImGui_InvisibleButton = function(_, label, w, h)
  item(label, res_w(w, 20), h or 20, 'invisible', true)
  return false
end
R.ImGui_Selectable = function(_, label) item(label, avail_x(), T.LINE_H, 'selectable') return false end
R.ImGui_Checkbox = function(_, label, v)
  item(label, T.FRAME_H + 4 + T.true_w(label), T.FRAME_H, 'checkbox')
  return false, v
end

-- An input with no explicit width takes ImGui's default item width, which is
-- ~65% of the window — not its label's width.
R.ImGui_InputText = function(_, label, v, _)
  framed(label, top().next_w, nil, 'input',
         math.max(80, math.floor(top().w * 0.65)))
  return false, v
end
R.ImGui_InputTextMultiline = function(_, label, v, w, h)
  local win = top()
  w = res_w(w or win.next_w, math.max(80, avail_x()))
  if h and h < 0 then h = math.max(20, avail_y() + h) end
  item(label, w, h or 60, 'multiline')
  return false, v
end
R.ImGui_Combo = function(_, label, cur, items)
  framed(label, top().next_w, nil, 'combo',
         math.max(80, math.floor(top().w * 0.65)))
  return false, cur
end
-- A combo's list lives in its own POPUP window, which cannot collide with the
-- pane behind it — so the closed state is the one worth modelling. Returning
-- true drew every Selectable inline at full width and left the cursor on the
-- right edge, which made the (?) after the combo look like an overflow it is
-- not. T.combo_open opens it when a test wants the list itself walked.
R.ImGui_BeginCombo = function(_, label, preview)
  framed(label, top().next_w, nil, 'combo',
         math.max(80, math.floor(top().w * 0.65)))
  if not T.combo_open then return false end
  T.open_pairs['combo'] = (T.open_pairs['combo'] or 0) + 1
  return true
end
R.ImGui_EndCombo = function() T.open_pairs['combo'] = (T.open_pairs['combo'] or 0) - 1 end
R.ImGui_ProgressBar = function(_, frac, w, h, overlay)
  item(overlay or 'bar', res_w(w, 120), h or T.FRAME_H, 'progress')
end
R.ImGui_CollapsingHeader = function(_, label)
  item(label, avail_x(), T.FRAME_H, 'header')
  return true
end
R.ImGui_Separator = function() item('---', avail_x(), 1, 'sep', true) end
R.ImGui_Spacing   = function() item('', 0, T.LINE_H, 'spacing', true) end
R.ImGui_Dummy     = function(_, w, h) item('', w or 0, h or 0, 'dummy', true) end
R.ImGui_Bullet    = function() item('*', 8, T.LINE_H, 'bullet') end

-- ── cursor and geometry ───────────────────────────────────────────────────
R.ImGui_SameLine = function(_, offset, spacing)
  local w = top()
  w.cy, w.line_h = w.prev_y, w.prev_h
  if offset and offset > 0 then
    w.cx = w.x0 + w.indent + offset          -- ABSOLUTE. May go backwards.
  else
    w.cx = w.prev_x2 + ((spacing and spacing > 0) and spacing or T.spacing.x)
  end
end
-- Ends the current line: the cursor drops below whatever was drawn on it, so
-- this is how a row undoes a SameLine it turns out not to have room for.
R.ImGui_NewLine = function()
  local w = top()
  w.cy = w.prev_y + math.max(w.prev_h, T.LINE_H) + T.spacing.y
  w.cx = w.x0 + w.indent
  w.line_h = 0
end
R.ImGui_SetNextItemWidth = function(_, w) top().next_w = w end
R.ImGui_Indent   = function(_, n) local w = top() w.indent = w.indent + (n or 21) w.cx = w.x0 + w.indent end
R.ImGui_Unindent = function(_, n) local w = top() w.indent = w.indent - (n or 21) w.cx = w.x0 + w.indent end

R.ImGui_GetCursorPosX = function() local w = top() return w.cx - w.x0 end
R.ImGui_GetCursorPosY = function() local w = top() return w.cy - w.y0 end
R.ImGui_SetCursorPosX = function(_, x) local w = top() w.cx = w.x0 + x end
R.ImGui_SetCursorPosY = function(_, y) local w = top() w.cy = w.y0 + y end
R.ImGui_SetCursorPos  = function(_, x, y) local w = top() w.cx, w.cy = w.x0 + x, w.y0 + y end
R.ImGui_GetCursorScreenPos = function() local w = top() return w.cx, w.cy end
R.ImGui_SetCursorScreenPos = function(_, x, y) local w = top() w.cx, w.cy = x, y end
R.ImGui_GetContentRegionAvail = function() return avail_x(), avail_y() end
R.ImGui_GetWindowPos    = function() local w = top() return w.x, w.y end
R.ImGui_GetWindowSize   = function() local w = top() return w.w, w.h end
R.ImGui_GetWindowWidth  = function() return top().w end
R.ImGui_GetWindowHeight = function() return top().h end
R.ImGui_GetFontSize     = function() return 14 end
R.ImGui_GetTextLineHeight = function() return T.LINE_H end
R.ImGui_GetTextLineHeightWithSpacing = function() return T.LINE_H + T.spacing.y end
R.ImGui_GetMousePos     = function() local w = top() return w.x + 40, w.y + 40 end

-- ── children ──────────────────────────────────────────────────────────────
R.ImGui_BeginChild = function(_, id, w, h, cflags, wflags)
  local p = top()
  local noscroll = (((wflags or 0) | (cflags or 0)) & T.NOSCROLL) ~= 0
  -- BeginChild: 0 means FILL the remaining parent size on that axis
  local cw_ = (w == nil or w == 0) and avail_x() or (w < 0 and math.max(1, avail_x() + w) or w)
  local ch_ = (h == nil or h == 0) and avail_y() or (h < 0 and math.max(1, avail_y() + h) or h)
  local c = newwin(id, p.cx, p.cy, cw_, ch_)
  c.noscroll = noscroll
  -- the child occupies a box in the parent
  T.rect(p.cx, p.cy, p.cx + cw_, p.cy + ch_, id, 'child', true)
  p.prev_x2, p.prev_y, p.prev_h = p.cx + cw_, p.cy, ch_
  p.right  = math.max(p.right, p.cx + cw_)
  p.bottom = math.max(p.bottom, p.cy + ch_)
  -- Same bookkeeping as item(): the child IS an item, so it joins the current
  -- line, the cursor drops past the TALLEST thing on that line, and line_h is
  -- then cleared. Leaving line_h set was the bug — a SameLine'd second child
  -- (a screen's inspector column) left the previous child's height standing, so
  -- the next item after it landed one whole column-height too low.
  p.line_h = math.max(p.line_h, ch_)
  p.cy = p.cy + p.line_h + T.spacing.y
  p.line_h = 0
  p.cx = p.x0 + p.indent
  p.next_w = nil
  T.stack[#T.stack + 1] = c
  return true
end

R.ImGui_EndChild = function()
  local c = table.remove(T.stack)
  -- ImGui's content size ends at the last ITEM's bottom, so the trailing
  -- ItemSpacing the cursor carries past it is NOT overflow.
  local content = c.bottom - c.y0
  if c.noscroll and c.h > 0 and content > c.h - 16 + 0.5 then
    T.overflow[#T.overflow + 1] = { win = c.id, byY = content - (c.h - 16) }
  end
  local cr = c.right - c.x0
  if c.w > 0 and cr > c.w - 16 + 0.5 then
    T.overflow[#T.overflow + 1] = { win = c.id, byX = cr - (c.w - 16) }
  end
  T.win = top()
end

R.ImGui_Begin = function() return true, true end
R.ImGui_End   = function() end

-- ── tables ────────────────────────────────────────────────────────────────
R.ImGui_BeginTable = function(_, id, ncol, flags, w, h)
  local p = top()
  local tw = (w == nil or w == 0) and avail_x() or (w < 0 and math.max(1, avail_x() + w) or w)
  local th = (h == nil or h == 0) and avail_y() or (h < 0 and math.max(1, avail_y() + h) or h)
  local t = newwin(id, p.cx, p.cy, tw, th)
  t.is_table, t.ncol = true, ncol
  t.colw = math.floor(tw / math.max(1, ncol))   -- until SetupColumn says better
  t.setup, t.col, t.rowy = {}, 0, t.y0
  T.rect(p.cx, p.cy, p.cx + tw, p.cy + th, id, 'table', true)
  p.prev_x2, p.prev_y, p.prev_h = p.cx + tw, p.cy, th
  p.line_h = math.max(p.line_h, th)
  p.cy = p.cy + p.line_h + T.spacing.y
  p.line_h = 0
  p.bottom = math.max(p.bottom, p.cy)
  T.stack[#T.stack + 1] = t
  T.open_pairs['table'] = (T.open_pairs['table'] or 0) + 1
  return true
end
R.ImGui_EndTable = function()
  table.remove(T.stack)
  T.open_pairs['table'] = (T.open_pairs['table'] or 0) - 1
  T.win = top()
end
R.ImGui_TableNextRow = function()
  local t = top()
  t.rowy = math.max(t.bottom, t.rowy + T.LINE_H)
  t.col, t.cx, t.cy = 0, t.x0, t.rowy
end
-- Resolve the setup into absolute column offsets, once per table: a fixed
-- column really is its stated width and the stretch columns share what is left.
-- A uniform width made the narrow columns too wide and the text column too
-- narrow, and reported collisions from both ends of that error.
local function table_cols(t)
  if t.cols then return t.cols end
  local n = t.ncol or 1
  local fixed, stretch = 0, {}
  for i = 1, n do
    local sc = t.setup and t.setup[i]
    if sc and sc.w and sc.w > 1 then fixed = fixed + sc.w
    else stretch[#stretch + 1] = i end
  end
  local rest = math.max(40, (t.w - 8) - fixed)
  local each = (#stretch > 0) and math.floor(rest / #stretch) or 0
  local cols, x = {}, 0
  for i = 1, n do
    local sc = t.setup and t.setup[i]
    local w  = (sc and sc.w and sc.w > 1) and sc.w or each
    cols[i] = { x = x, w = w }
    x = x + w
  end
  t.cols = cols
  return cols
end

R.ImGui_TableSetColumnIndex = function(_, i)
  local t = top()
  local cols = table_cols(t)
  local c = cols[i + 1] or { x = i * (t.colw or 100), w = t.colw or 100 }
  t.col = i
  t.cx  = t.x0 + c.x
  t.cy  = t.rowy
  t.cell_w = c.w
end

R.ImGui_TableSetupColumn = function(_, label, flags, init_w)
  local t = top()
  if not t.is_table then return end
  t.setup = t.setup or {}
  t.setup[#t.setup + 1] = { w = init_w, flags = flags or 0 }
end
R.ImGui_TableHeadersRow  = function()
  local t = top()
  t.rowy = t.rowy + T.LINE_H + 2
  t.cy = t.rowy
end
R.ImGui_TableSetupScrollFreeze = function() end
R.ImGui_TableNextColumn = function()
  local t = top()
  R.ImGui_TableSetColumnIndex(nil, (t.col or 0) + 1)
  return true
end

-- Inside a table cell, "avail" must be the CELL, not the table.
local base_avail_x = avail_x
avail_x = function()
  local w = top()
  if w.is_table and w.cols then
    local c = w.cols[(w.col or 0) + 1]
    local right = w.x0 + ((c and (c.x + c.w)) or (w.colw or 100))
    return math.max(0, right - w.cx - 4)
  end
  return base_avail_x()
end

-- ── style ─────────────────────────────────────────────────────────────────
R.ImGui_PushStyleColor = function(_, idx, col)
  if type(col) ~= 'number' then
    T.notes[#T.notes + 1] = 'PushStyleColor got a non-number colour'
  end
  T.pushed_col = T.pushed_col + 1
end
R.ImGui_PopStyleColor = function(_, n) T.pushed_col = T.pushed_col - (n or 1) end
R.ImGui_PushStyleVar = function(_, idx, a, b)
  T.pushed_var = T.pushed_var + 1
  T.var_stack = T.var_stack or {}
  T.var_stack[#T.var_stack + 1] = { idx = idx, a = a, b = b,
                                    sx = T.spacing.x, sy = T.spacing.y }
  -- ItemSpacing is the one style var the layout model has to honour
  if a and b and a >= 0 and a <= 40 and b >= 0 and b <= 40 then
    T.spacing = { x = a, y = b }
  end
end
R.ImGui_PopStyleVar = function(_, n)
  n = n or 1
  T.var_stack = T.var_stack or {}
  for _ = 1, n do
    local v = table.remove(T.var_stack)
    if v then T.spacing = { x = v.sx, y = v.sy } end
    T.pushed_var = T.pushed_var - 1
  end
end
R.ImGui_PushFont = function() T.pushed_font = T.pushed_font + 1 end
R.ImGui_PopFont  = function() T.pushed_font = T.pushed_font - 1 end
R.ImGui_CreateFont = function() return {} end
R.ImGui_CreateFontFromFile = function() return {} end
R.ImGui_Attach = function() end
R.ImGui_BeginDisabled = function() end
R.ImGui_EndDisabled   = function() end
R.ImGui_PushTextWrapPos = function() end
R.ImGui_PopTextWrapPos  = function() end

R.ImGui_IsItemHovered = function() return false end
R.ImGui_IsItemClicked = function() return false end
R.ImGui_IsItemActive  = function() return false end
R.ImGui_SetTooltip    = function(_, s)
  if type(s) ~= 'string' then T.notes[#T.notes + 1] = 'SetTooltip got a non-string' end
end
R.ImGui_GetClipboardText = function() return 'clip' end
R.ImGui_SetClipboardText = function() end
R.ImGui_SetItemDefaultFocus = function() end
R.ImGui_CreateContext = function() return {} end
R.ImGui_GetVersion = function() return '0.9.3', '0.9.3', 19100 end

-- ── draw lists: arg 1 is the DRAW LIST, not the ctx ────────────────────────
local DL = { __dl = true }
R.ImGui_GetWindowDrawList     = function() return DL end
R.ImGui_GetForegroundDrawList = function() return DL end

R.ImGui_DrawList_AddText = function(_, x, y, col, s)
  if type(col) ~= 'number' then
    T.notes[#T.notes + 1] = 'DrawList_AddText got a non-number colour'
  end
  T.rect(x, y, x + T.true_w(s), y + T.LINE_H, s, 'drawtext')
end
R.ImGui_DrawList_AddLine        = function() end
R.ImGui_DrawList_AddRect        = function() end
R.ImGui_DrawList_AddRectFilled  = function() end
R.ImGui_DrawList_AddCircle      = function() end
R.ImGui_DrawList_AddCircleFilled= function() end
R.ImGui_DrawList_AddTriangleFilled = function() end
R.ImGui_DrawList_AddQuadFilled  = function() end
R.ImGui_DrawList_PushClipRect   = function() end
R.ImGui_DrawList_PopClipRect    = function() end

_G.reaper = R
_G.__DL   = DL
return T
