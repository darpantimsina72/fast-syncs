local T, S = __T, _G.__S
local ctx = {}
local fails, checks = {}, 0
local function fail(n, d) fails[#fails+1] = { name = n, detail = d } end

local function draw(name, fn, opts)
  opts = opts or {}
  T.reset({ regime = opts.regime or 'honest', w = opts.w or 1040, h = opts.h or 660 })
  local ok, err = pcall(fn, ctx)
  checks = checks + 1
  if not ok then fail(name, 'ERROR: ' .. tostring(err)) return end
  if T.pushed_col ~= 0 then fail(name, 'colour stack leaked ' .. T.pushed_col) end
  if T.pushed_var ~= 0 then fail(name, 'var stack leaked ' .. T.pushed_var) end
  local seen = {}
  for _, c in ipairs(T.collisions) do
    local k = string.format('"%s" (%s) over "%s" (%s) by %.0fx%.0f',
      c.by, c.by_kind, c.over, c.over_kind, c.ox, c.oy)
    if not seen[k] then seen[k] = true fail(name, k) end
  end
  local root = T.stack[1]
  local over = (root.right - root.x0) - (root.w - 16)
  if over > 0.5 and (opts.w or 1040) >= 560 then
    local worst, wx = '?', -1
    for _, it in ipairs(root.items) do
      if not it.soft and it.x2 > wx then wx, worst = it.x2, it.label .. '/' .. it.kind end
    end
    fail(name, string.format('content %.0f px WIDER than the window (widest: %s)', over, worst))
  end
end

for _, r in ipairs({ 'honest', 'nonascii0', 'all0' }) do
  for _, w in ipairs({ 1400, 1040, 820, 640, 560, 480, 400, 320 }) do
    for _ = 1, 2 do
      draw(string.format('sync/setup [%s @ %d]', r, w), S.setup, { regime = r, w = w })
    end
  end
end

local groups, order = {}, {}
for _, f in ipairs(fails) do
  local g = f.name:match('^(.-) %[') or f.name
  if not groups[g] then groups[g] = { seen = {}, ex = {}, n = 0 } order[#order+1] = g end
  local G = groups[g]
  G.n = G.n + 1
  if not G.seen[f.detail] then
    G.seen[f.detail] = true
    if #G.ex < 3 then G.ex[#G.ex+1] = (f.name:match('%[(.-)%]') or '?') .. '  ' .. f.detail end
  end
end
print('')
print(string.format('  SYNC TAB: %d draws, %d group(s) failing, %d finding(s)', checks, #order, #fails))
print('')
if #order == 0 then print('  PASS  no collisions, no clipping at or above 560 px.') end
for _, g in ipairs(order) do
  print('  FAIL  ' .. g)
  for _, d in ipairs(groups[g].ex) do print('          ' .. d) end
end
print('')
