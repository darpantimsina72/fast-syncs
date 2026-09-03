__T.WIDE_SWEEP = (_G.WIDE == true)
-- ══ the actual layout tests ═══════════════════════════════════════════════
local T, V5, H = __T, _G.V5, _G.__H
local ctx = {}

local fails, checks = {}, 0
local function fail(name, detail)
  fails[#fails + 1] = { name = name, detail = detail }
end

local REGIMES = { 'honest', 'nonascii0', 'all0' }

-- Draw *fn* under one regime/size and report the collisions it produced.
local function draw(name, fn, opts)
  opts = opts or {}
  T.reset({ regime = opts.regime or 'honest', w = opts.w or 1040,
            h = opts.h or 660, missing = opts.missing or {} })
  local ok, err = pcall(fn, ctx)
  checks = checks + 1
  if not ok then
    fail(name, 'ERROR: ' .. tostring(err))
    return nil
  end
  if T.pushed_col ~= 0 then fail(name, 'style COLOUR stack leaked ' .. T.pushed_col) end
  if T.pushed_var ~= 0 then fail(name, 'style VAR stack leaked ' .. T.pushed_var) end
  if T.pushed_font ~= 0 then fail(name, 'FONT stack leaked ' .. T.pushed_font) end
  if V5.form_key ~= nil then fail(name, 'form_begin without form_end') end
  for k, v in pairs(T.open_pairs) do
    if v ~= 0 then fail(name, 'unclosed ' .. k .. ' pair: ' .. v) end
  end
  for _, n in ipairs(T.notes) do fail(name, n) end
  -- The root window is never popped, so its own edges have to be checked here.
  -- This is what catches CLIPPING: a row of fixed-width buttons that runs off
  -- the right edge never collides with anything, it just stops existing.
  local root = T.stack[1]
  if root then
    local over_x = (root.right  - root.x0) - (root.w - 16)
    -- Clipping is a failure at or above the panel's design floor; a window
    -- dragged below that degrades, but must still never OVERPRINT anything.
    -- opts.chrome: the title bar's caption buttons are positioned in SCREEN
    -- space and are MEANT to reach the window's edge, the way Explorer's do —
    -- that is not content overflowing a content region.
    if over_x > 0.5 and not opts.chrome and (opts.w or 1040) >= 560 then
      -- name the item that reaches furthest right, or the report says only
      -- that something overflows and not what
      local worst, wx = '?', -1
      for _, it in ipairs(root.items) do
        if not it.soft and it.x2 > wx then wx, worst = it.x2, it.label .. '/' .. it.kind end
      end
      fail(name, string.format('content is %.0f px WIDER than the window (widest: %s)',
                               over_x, worst))
    end
  end
  for _, o in ipairs(T.overflow) do
    if (opts.w or 1040) >= 560 then
      fail(name, string.format('%s overflows by %s%.0f px', o.win,
                               o.byX and 'X ' or 'Y ', o.byX or o.byY))
    end
  end
  if #T.collisions > 0 then
    local seen = {}
    for _, c in ipairs(T.collisions) do
      local k = string.format('"%s" (%s) over "%s" (%s) by %.0fx%.0f in %s',
        c.by, c.by_kind, c.over, c.over_kind, c.ox, c.oy, c.win)
      if not seen[k] then
        seen[k] = true
        fail(name, k)
      end
    end
  end
  return T
end

-- Run one draw across all three measurement regimes and three widths.
local function sweep(name, fn, widths, opts0)
  widths = widths or { 1040, 820, 640 }
  if T.WIDE_SWEEP then
    widths = { 1400, 1040, 900, 780, 640, 560, 480, 400, 340, 280, 220 }
  end
  for _, r in ipairs(REGIMES) do
    for _, w in ipairs(widths) do
      -- two frames: the label column measures on frame 1 and is used on frame 2
      T.reset({ regime = r, w = w })
      pcall(fn, ctx)
      draw(string.format('%s [%s @ %dpx]', name, r, w), fn,
           { regime = r, w = w, chrome = opts0 and opts0.chrome })
    end
  end
end

-- ── fixtures ──────────────────────────────────────────────────────────────
local HIST = {
  -- the legacy raw-timestamp entry that overruns the date column
  { ts = '2026-08-19 14:32:07', audio = 'D:\\p\\Isha_Kriya_Intro_EN_master.wav',
    out_dir = 'D:\\p\\out1', language = 'Malayalam', status = 'done', mode = 'paste' },
  -- the "your script" chip, which is the widest of them
  { ts = '2026-08-18 18:22:00', audio = 'D:\\p\\Darshan_2026_08_18_part2.wav',
    out_dir = 'D:\\p\\out2', language = 'Hindi', status = 'review', mode = 'paste' },
  { ts = '2026-08-14 09:51:00', audio = 'D:\\p\\Sathsang_evening_EN.wav',
    out_dir = 'D:\\p\\gone', language = 'Bengali', status = 'done', mode = 'auto' },
}

local PLAN_TR = {
  'जो कुछ भी घटित हो, उसे घटित होने दीजिए। किसी भी अनुभव से चिपकिए नहीं।',
  'नमस्कार।',
  'यह अभ्यास प्रतिदिन बारह मिनट का है — सुबह और शाम, और इसे कभी छोड़िए नहीं।',
  '',
}
local PLAN_VERDICTS = { 'fits', 'tight', 'over', 'short', 'empty' }

local function plan_fixture(total, use_table)
  local rows, counts = {}, {}
  local t, i = 0, 1
  while t < total do
    local dur = 3.2
    local v   = PLAN_VERDICTS[(i - 1) % #PLAN_VERDICTS + 1]
    counts[v] = (counts[v] or 0) + 1
    rows[#rows + 1] = {
      index = i, start_s = t, end_s = t + dur, dur = dur, pause = 0.6,
      est = dur * (v == 'over' and 1.35 or v == 'short' and 0.6 or 1.05),
      verdict = v, atempo = (v == 'over') and 1.27 or 1.0,
      tr = PLAN_TR[(i - 1) % #PLAN_TR + 1],
      en = 'Let whatever happens, happen. Do not hold on to any experience.',
    }
    t = t + dur + 0.6
    i = i + 1
  end
  return { total_s = total, rows = rows, sel = 1, counts = counts,
           use_table = (use_table ~= false),
           manifest = { language = 'Hindi', out_dir = [[D:\p\out]] },
           plan_path = [[D:\p\out\plan.txt]],
           html_path = [[D:\p\out
eview.html]] }
end

local REVIEW = {
  manifest = { language = 'Hindi', translation_text = 'x.txt' },
  edited_path = 'D:\\p\\out\\edited.txt',
  dirty = false,
  use_table = true,
  en_paras = { 'Namaskaram. Isha Kriya is a simple and powerful process.',
               'Sit comfortably, close your eyes and watch your breath.' },
  tr_paras = { 'नमस्कार। ईशा क्रिया एक सरल और शक्तिशाली प्रक्रिया है।',
               'आप आराम से बैठिए, आँखें बंद कीजिए और अपनी श्वास पर ध्यान दीजिए।' },
  tr_buffer = 'नमस्कार।',
}

local CFG_FULL = {
  SCRIPT_MODE = 'have', FULL_RUN = false,
  LAST_AUDIO = 'D:\\p\\Isha_Kriya_Intro_EN_master.wav',
  LANGUAGE = 'Malayalam', LLM_PROVIDER = 'gemini',
  LLM_MODEL = 'gemini-2.5-pro-preview-06-05', LLM_GEMINI_KEY = 'k',
  EL_KEY = 'k', EL_MODEL = 'eleven_multilingual_v2', VOICE_ID = 'v1',
  _provided_text = 'नमस्कार। ईशा क्रिया एक सरल प्रक्रिया है।\n\nआप आराम से बैठिए।',
}
local CFG_EMPTY = {
  SCRIPT_MODE = 'auto', FULL_RUN = true, LAST_AUDIO = '', LANGUAGE = 'Hindi',
  LLM_PROVIDER = 'openai', LLM_MODEL = '', LLM_GEMINI_KEY = '',
  LLM_OPENAI_KEY = '', LLM_OPENAI_URL = '', EL_KEY = '', VOICE_ID = '',
  _provided_text = '',
}

-- ══ 1. the history row (F3 chip-over-button, F4 name-over-date) ════════════
H.set_cfg(CFG_FULL)
sweep('hist_row', function(c)
  for i, e in ipairs(HIST) do V5.hist_row(c, i, e) end
end)

-- the expanded ⋯ row, which indents by a hard 106
V5.hist_open = 2
sweep('hist_row expanded', function(c)
  for i, e in ipairs(HIST) do V5.hist_row(c, i, e) end
end)
V5.hist_open = nil

-- ══ 2. the run plan (F9 fixed value column) ════════════════════════════════
for _, cfg in ipairs({ CFG_FULL, CFG_EMPTY }) do
  H.set_cfg(cfg)
  for _, ph in ipairs({ 'setup', 'running', 'review', 'success', 'failure' }) do
    H.set_phase(ph)
    H.set_stage('S2d')
    sweep('run_plan/' .. ph .. '/' .. tostring(cfg.SCRIPT_MODE), function(c)
      V5.run_plan(c)
    end, { 300, 288, 240 })
  end
end
H.set_phase('setup')

-- ══ 3. the fit strip's ruler (F1 tick labels overprinting) ═════════════════
for _, total in ipairs({ 12, 45, 130, 521, 1800 }) do
  local P = plan_fixture(total)
  sweep('plan_strip ' .. total .. 's', function(c)
    V5.plan_strip(c, P)
  end, { 1040, 700, 460, 300, 180, 120 })
end

-- ══ 4. the source form (F2 field-over-label, F5 field into next cell) ══════
for _, cfg in ipairs({ CFG_FULL, CFG_EMPTY }) do
  H.set_cfg(cfg)
  sweep('ui_source_inputs/' .. tostring(cfg.SCRIPT_MODE), function(c)
    V5.ui_source_inputs(c)
  end, { 1040, 820, 680, 520, 400 })
end

-- ══ 5. every settings pane ════════════════════════════════════════════════
H.set_cfg(CFG_FULL)
for _, pane in ipairs(V5.PANES) do
  sweep('pane/' .. pane[1], function(c) pane[3](c) end, { 740, 560, 420 })
end
H.set_cfg(CFG_EMPTY)
for _, pane in ipairs(V5.PANES) do
  sweep('pane(empty)/' .. pane[1], function(c) pane[3](c) end, { 740, 560 })
end

-- ══ 6. the script box (F6 counter off the right edge) ══════════════════════
H.set_cfg(CFG_FULL)
sweep('script_box', function(c)
  V5.script_box(c, 'provided', CFG_FULL._provided_text, { height = 120 })
end, { 700, 460, 300, 200 })

-- ══ 7. the review screen (F7 toolbar clipping, F8 byte-sized boxes) ════════
H.set_review(REVIEW)
H.set_phase('review')
-- Untimed: no en_srt in the run, so the strip / tally / transport are all
-- absent and the screen is head + toolbar + table + bar.
for _, lay in ipairs({ 'list', 'grid' }) do
  V5.review_layout = lay
  sweep('ui_phase_review(untimed)/' .. lay, function(c) H.review(c) end,
        { 1040, 820, 640 })
end

-- ══ 7b. v0.29 preview sync ════════════════════════════════════════════════
-- The times come from the run's own English SRT, walked as ONE character
-- stream (V5.review_times). The fixture below is the shape the engine writes:
-- two review paragraphs, each the text of two cues joined with a space.
local SRT_PATH = 'D:/p/out/run.srt'
T.files[SRT_PATH] = table.concat({
  '1', '00:00:00,000 --> 00:00:04,000', 'Namaskaram.', '',
  '2', '00:00:04,500 --> 00:00:09,000',
  'Isha Kriya is a simple and powerful process.', '',
  '3', '00:00:10,000 --> 00:00:14,000',
  'Sit comfortably, close your eyes.', '',
  '4', '00:00:14,200 --> 00:00:19,000',
  'Watch your breath for a few moments.', '',
}, '\n')

do
  checks = checks + 1
  local slots, total = V5.review_times(REVIEW.en_paras, SRT_PATH)
  local function near(a, b) return math.abs((a or -99) - b) < 0.02 end
  if not slots then
    fail('review_times', 'returned nil for a readable SRT')
  elseif not (near(slots[1].start_s, 0.0) and near(slots[1].stop_s, 9.0)
              and near(slots[2].start_s, 10.0) and near(slots[2].stop_s, 19.0)
              and near(total, 19.0)) then
    fail('review_times', string.format(
      'paragraph slots are wrong: [%.2f..%.2f] [%.2f..%.2f] of %.2f — ' ..
      'expected [0..9] [10..19] of 19',
      slots[1].start_s, slots[1].stop_s, slots[2].start_s, slots[2].stop_s,
      total or -1))
  end
  -- A missing SRT must answer nil rather than inventing zeros: the screen
  -- drops its timed half on nil, and would otherwise draw a strip of
  -- zero-length bars over a table of them.
  checks = checks + 1
  if V5.review_times(REVIEW.en_paras, 'D:/p/out/gone.srt') ~= nil then
    fail('review_times', 'invented timings for an SRT that is not there')
  end
end

-- The verdicts, straight from the measurement: one paragraph that fits its
-- slot and one that cannot. The rate is the ENGINE's — Hindi at 9.2 chars/s
-- (V5.LANG_CPS), not the panel's old flat 15 — so these lengths are what the
-- plan stage would also call fits / over.
local LONG_TR = string.rep('क', 150)      -- ~16 s of Hindi, in an 8.2 s slot
do
  -- 75 characters is ~8.2 s of Hindi at 9.2 chars/s: inside the 9 s slot and
  -- above the 0.85 short line. 150 is ~16 s, which no amount of pause saves.
  local R = { manifest = { language = "Hindi" },
              en_paras = REVIEW.en_paras,
              slots    = V5.review_times(REVIEW.en_paras, SRT_PATH),
              tr_paras = { string.rep("क", 75), LONG_TR } }
  checks = checks + 1
  local rows = V5.review_measure(R)
  if rows[1].verdict ~= 'fits' or rows[2].verdict ~= 'over' then
    fail('review_measure', string.format(
      'verdicts are %s / %s — expected fits / over (est %.1f / %.1f s in ' ..
      '%.1f / %.1f s slots)', rows[1].verdict, rows[2].verdict,
      rows[1].est, rows[2].est, rows[1].dur, rows[2].dur))
  end
  checks = checks + 1
  if math.abs(rows[1].pause - 1.0) > 0.02 then
    fail('review_measure', string.format(
      'the pause between paragraph 1 and 2 measured %.2f s, not 1.00 s',
      rows[1].pause))
  end
end

-- The estimate itself: the engine strips ElevenLabs [tags] before counting
-- (they steer prosody and are never spoken), and an unknown language falls
-- back to 11.0 rather than to the panel's old flat 15.
do
  checks = checks + 1
  if math.abs(V5.lang_cps('Hindi') - 9.2) > 0.001
     or math.abs(V5.lang_cps('Klingon') - 11.0) > 0.001 then
    fail('lang_cps', string.format('Hindi %.2f / unknown %.2f — expected 9.20 / 11.00',
                                   V5.lang_cps('Hindi'), V5.lang_cps('Klingon')))
  end
  checks = checks + 1
  local tagged = V5.est_secs('[excited] नमस्ते दोस्तों', 'Hindi')
  local plain  = V5.est_secs(' नमस्ते दोस्तों', 'Hindi')
  if math.abs(tagged - plain) > 0.001 then
    fail('est_secs', string.format(
      'an ElevenLabs tag added %.2f s to the estimate — it is never spoken',
      tagged - plain))
  end
end

-- The whole screen, timed: strip, tally, transport chips, both layouts, all
-- three text sizes, and the inspector at every width down to the one that
-- drops it.
local REVIEW_T = {
  manifest = { language = 'Hindi', translation_text = 'x.txt',
               en_srt = SRT_PATH, out_dir = 'D:/p/out',
               audio = 'D:/p/Isha_Kriya_Intro_EN_master.wav' },
  edited_path = 'D:/p/out/edited.txt',
  dirty = true,
  use_table = true,
  en_paras = REVIEW.en_paras,
  tr_paras = { REVIEW.tr_paras[1], LONG_TR },
  tr_buffer = REVIEW.tr_paras[1],
  sel = 2, follow = true, time_off = 0, timed = true, total_s = 19.0,
  linked = 'Isha_Kriya_Intro_EN_master.wav',
}
REVIEW_T.slots = V5.review_times(REVIEW_T.en_paras, SRT_PATH)
H.set_review(REVIEW_T)
for _, lay in ipairs({ 'list', 'grid' }) do
  V5.review_layout = lay
  for _, px in ipairs({ 13, 15, 17 }) do
    V5.review_px = px
    sweep(('ui_phase_review(timed)/%s/%dpx'):format(lay, px),
          function(c) H.review(c) end, { 1040, 780, 640 })
  end
end
V5.review_px = 15

-- Playing: the strip grows a play cursor and Follow walks the selection with
-- it. Every transport call this makes is a stub answering nil, which is also
-- the build-without-a-transport path they have to survive.
do
  local play_state, play_pos = reaper.GetPlayState, reaper.GetPlayPosition
  reaper.GetPlayState    = function() return 1 end
  reaper.GetPlayPosition = function() return 11.5 end
  V5.review_layout = 'list'
  sweep('ui_phase_review(playing)', function(c) H.review(c) end, { 1040, 640 })
  checks = checks + 1
  V5.review_measure(REVIEW_T)
  V5.review_follow_poll(REVIEW_T)
  if REVIEW_T.sel ~= 2 or math.abs((REVIEW_T.play_s or 0) - 11.5) > 0.01 then
    fail('review_follow_poll', string.format(
      'the play cursor at 11.5 s selected paragraph %s (play_s %s) — ' ..
      'expected paragraph 2', tostring(REVIEW_T.sel),
      tostring(REVIEW_T.play_s)))
  end
  reaper.GetPlayState, reaper.GetPlayPosition = play_state, play_pos
end
-- ══ 7c. v0.30 the cast ════════════════════════════════════════════════════
-- The screen with more than one voice in it. Everything the cast adds is
-- drawn here — the strip riding on the view row, the editor open over the
-- table, the per-paragraph chips in both layouts, the List's voice column and
-- the inspector's block — because all of it is new geometry on the one screen
-- that had no vertical slack left to give (V5.cast_strip's whole shape is an
-- answer to that).
do
  -- The panel loads its voice catalogue from disk at start-up and there is no
  -- disk here, so the combos would otherwise have nothing but '(no voice yet)'.
  local saved_bm = V5.bookmarks
  V5.bookmarks = { { id = 'sadhguruvoice01', name = 'Sadhguru HI' },
                   { id = 'narratorvoice2',  name = 'Narrator HI' },
                   { id = 'questionvoice3',  name = 'Questioner HI' } }

  local CAST = {}
  for k, v in pairs(REVIEW_T) do CAST[k] = v end
  CAST.cast, CAST.sel = nil, 2
  V5.review_measure(CAST)

  -- The default: one speaker, and every paragraph already belongs to it.
  checks = checks + 1
  local C = V5.cast_ensure(CAST)
  if #C.speakers ~= 1 or V5.cast_of(CAST, 1) ~= C.speakers[1]
     or V5.cast_of(CAST, 2) ~= C.speakers[1] then
    fail('cast_ensure', 'a fresh cast is not one speaker owning every row')
  end
  C.speakers[1].voice = 'sadhguruvoice01'

  -- A second voice, cast to paragraph 2 only.
  local q = V5.cast_add(CAST, 'Questioner', 'questionvoice3')
  V5.cast_assign(CAST, 2, q.key)
  checks = checks + 1
  local st = V5.cast_stats(CAST)
  if V5.cast_of(CAST, 2) ~= q or V5.cast_of(CAST, 1) ~= C.speakers[1]
     or (st[q.key] or {}).lines ~= 1
     or (st[C.speakers[1].key] or {}).lines ~= 1 then
    fail('cast_assign', string.format(
      'casting paragraph 2 to a second speaker left %s/%s lines on the two ' ..
      'voices — expected 1/1',
      tostring((st[C.speakers[1].key] or {}).lines),
      tostring((st[q.key] or {}).lines)))
  end
  checks = checks + 1
  if not V5.cast_multi(CAST) then
    fail('cast_multi', 'two speakers did not read as a multi-voice run')
  end

  -- A cast speaker with no voice is the one state Continue must refuse; the
  -- MAIN voice being empty is not (the engine auto-resolves that one).
  local mute = V5.cast_add(CAST, 'Silent', '')
  V5.cast_assign(CAST, 1, mute.key)
  checks = checks + 1
  if #V5.cast_voiceless(CAST) ~= 1 then
    fail('cast_voiceless', string.format(
      '%d speaker(s) reported without a voice — expected exactly the one ' ..
      'that has paragraphs and no voice', #V5.cast_voiceless(CAST)))
  end
  checks = checks + 1
  local main_voice = C.speakers[1].voice
  C.speakers[1].voice = ''
  if #V5.cast_voiceless(CAST) ~= 1 then
    fail('cast_voiceless',
         'an empty MAIN voice was counted — the engine auto-resolves that one')
  end
  C.speakers[1].voice = main_voice
  V5.cast_assign(CAST, 1, nil)
  V5.cast_remove(CAST, mute.key)
  checks = checks + 1
  if #V5.cast_voiceless(CAST) ~= 0 or #C.speakers ~= 2 then
    fail('cast_remove', 'removing the voiceless speaker did not clear it')
  end

  -- Removing a speaker returns ITS paragraphs to the main voice — nothing is
  -- left pointing at a speaker that is gone.
  do
    checks = checks + 1
    local tmp = V5.cast_add(CAST, 'Temp', 'narratorvoice2')
    V5.cast_assign(CAST, 1, tmp.key)
    V5.cast_remove(CAST, tmp.key)
    if V5.cast_of(CAST, 1) ~= C.speakers[1] then
      fail('cast_remove', 'a removed speaker left paragraph 1 orphaned')
    end
  end

  -- The main voice cannot be removed: it is what every uncast paragraph is.
  checks = checks + 1
  if V5.cast_remove(CAST, C.speakers[1].key) then
    fail('cast_remove', 'the main voice was removable')
  end

  -- Promotion swaps the two WITHOUT moving anyone's lines: the paragraphs that
  -- were implicitly on the old main have to be named before the swap.
  do
    checks = checks + 1
    local before1 = V5.cast_of(CAST, 1).name
    local before2 = V5.cast_of(CAST, 2).name
    local Cc = CAST.cast
    local old, new = Cc.speakers[1], Cc.speakers[2]
    for _, r in ipairs(CAST.rows) do
      if not Cc.by_row[r.index] then Cc.by_row[r.index] = old.key end
    end
    Cc.speakers[1], Cc.speakers[2] = new, old
    for _, r in ipairs(CAST.rows) do
      if Cc.by_row[r.index] == new.key then Cc.by_row[r.index] = nil end
    end
    if V5.cast_of(CAST, 1).name ~= before1
       or V5.cast_of(CAST, 2).name ~= before2 then
      fail('cast promote', 'swapping the main voice re-cast someone’s lines')
    end
    -- put it back the way the drawing tests want it
    Cc.speakers[1], Cc.speakers[2] = old, new
    Cc.by_row = { [2] = new.key }
  end

  -- Row number is not paragraph number. A row with no text writes no
  -- paragraph into the script file, so the engine never counts it — and the
  -- engine's own placeholder row ("1 no text", a paragraph it could not pair)
  -- is exactly the case that would shift every voice one line early.
  do
    checks = checks + 1
    local E = { manifest = { language = 'Hindi' }, use_table = true,
                en_paras = { 'One.', 'Two.', 'Three.', 'Four.' },
                tr_paras = { '', 'B', '   ', 'D' } }
    V5.review_measure(E)
    local to_para, to_row = V5.cast_ordinals(E)
    if to_para[1] ~= nil or to_para[2] ~= 1 or to_para[3] ~= nil
       or to_para[4] ~= 2 or to_row[1] ~= 2 or to_row[2] ~= 4 then
      fail('cast_ordinals', string.format(
        'rows 1..4 (two of them empty) numbered %s/%s/%s/%s — the engine ' ..
        'counts only the paragraphs that have text, so those are 1 and 2',
        tostring(to_para[1]), tostring(to_para[2]), tostring(to_para[3]),
        tostring(to_para[4])))
    end
    -- And the round trip: a map keyed by paragraph comes back on the right
    -- ROWS, which is the half that would silently mis-cast on a resume.
    checks = checks + 1
    E.manifest.out_dir, E.base = 'D:/p/out', 'gaps'
    T.files[V5.cast_file(E)] = table.concat({
      '{', '  "speakers": [',
      '    {"key": "s1", "name": "Main", "voice_id": "sadhguruvoice01"},',
      '    {"key": "s2", "name": "Other", "voice_id": "questionvoice3"}',
      '  ],', '  "assignments": {',
      '    "2": {"speaker": "s2", "voice_id": "questionvoice3"}',
      '  }', '}',
    }, '\n')
    V5.cast_ensure(E)
    if V5.cast_of(E, 4).name ~= 'Other' or V5.cast_of(E, 2).name ~= 'Main' then
      fail('cast_load', string.format(
        'paragraph 2 of the file came back on the row spoken by %s — it is ' ..
        'row 4, the second row that has text',
        tostring(V5.cast_of(E, 4) and V5.cast_of(E, 4).name)))
    end
  end

  -- Speaker labels in the English column ("Sadhguru:", "Questioner:").
  do
    checks = checks + 1
    local L = { manifest = { language = 'Hindi' }, use_table = true,
                en_paras = { 'Sadhguru: Do not seek. Just see.',
                             'Questioner: How do we begin?',
                             'Sadhguru: You have already begun.' },
                tr_paras = { 'क', 'ख', 'ग' } }
    V5.review_measure(L)
    V5.cast_ensure(L)
    local added, assigned = V5.cast_detect(L)
    local names = {}
    for _, r in ipairs(L.rows) do names[#names + 1] = V5.cast_of(L, r.index).name end
    if assigned ~= 3 or names[1] ~= 'Sadhguru' or names[2] ~= 'Questioner'
       or names[3] ~= 'Sadhguru' then
      fail('cast_detect', string.format(
        'the English labels cast %d paragraph(s) as %s / %s / %s (+%d ' ..
        'speaker(s)) — expected Sadhguru / Questioner / Sadhguru',
        assigned, tostring(names[1]), tostring(names[2]), tostring(names[3]),
        added))
    end
    -- and it must not have touched the script: the label is the transcript's.
    checks = checks + 1
    if L.tr_paras[1] ~= 'क' or L.dirty then
      fail('cast_detect', 'detection edited the script')
    end
  end

  -- The file the engine reads. Written by the bulk app or by an earlier pass
  -- of this screen, it has to come back as the same cast — including an
  -- assignment recorded only as a voice id, which is the shape the engine
  -- documents (pipeline/tts.py _speakers_voice_map).
  do
    checks = checks + 1
    local F = { manifest = { language = 'Hindi', out_dir = 'D:/p/out' },
                base = 'run', use_table = true,
                en_paras = REVIEW_T.en_paras, tr_paras = REVIEW_T.tr_paras }
    V5.review_measure(F)
    local path = V5.cast_file(F)
    T.files[path] = table.concat({
      '{', '  "version": 1,', '  "default_voice_id": "sadhguruvoice01",',
      '  "speakers": [',
      '    {"key": "s1", "name": "Sadhguru", "voice_id": "sadhguruvoice01"},',
      '    {"key": "s2", "name": "Questioner", "voice_id": "questionvoice3"}',
      '  ],', '  "assignments": {',
      '    "2": {"voice_id": "questionvoice3"}', '  }', '}',
    }, '\n')
    V5.cast_ensure(F)
    if #(F.cast.speakers or {}) ~= 2
       or V5.cast_of(F, 1).name ~= 'Sadhguru'
       or V5.cast_of(F, 2).name ~= 'Questioner' then
      fail('cast_load', string.format(
        'the saved map came back as %d speaker(s), paragraph 2 spoken by %s ' ..
        '— expected 2 and Questioner', #(F.cast.speakers or {}),
        tostring(V5.cast_of(F, 2) and V5.cast_of(F, 2).name)))
    end
    -- Saving cannot succeed here (every write answers nil in the mock), and a
    -- failed save must be a reported false, not an error and not a lie.
    checks = checks + 1
    local ok, where = V5.cast_save(F)
    if ok ~= false or (where or '') == '' then
      fail('cast_save', 'a write that could not open the file did not report it')
    end
  end

  -- ── the drawing ─────────────────────────────────────────────────────────
  H.set_review(CAST)
  H.set_phase('review')
  for _, lay in ipairs({ 'list', 'grid' }) do
    V5.review_layout = lay
    CAST.cast.open = false
    sweep('ui_phase_review(cast)/' .. lay, function(c) H.review(c) end,
          { 1040, 780, 640 })
    CAST.cast.open = true
    sweep('ui_phase_review(cast-open)/' .. lay, function(c) H.review(c) end,
          { 1040, 780, 640 })
  end

  -- A full cast: eight speakers is the cap, and no row is wide enough for
  -- eight chips — the strip has to collapse the overflow into '+N' rather
  -- than wrap, which is the one thing this screen cannot afford.
  CAST.cast.open = false
  while #CAST.cast.speakers < V5.CAST_MAX do
    V5.cast_add(CAST, 'Speaker ' .. (#CAST.cast.speakers + 1), 'narratorvoice2')
  end
  checks = checks + 1
  if #CAST.cast.speakers ~= V5.CAST_MAX
     or V5.cast_add(CAST, 'Nine', '') ~= nil then
    fail('cast_add', 'the cast grew past its cap')
  end
  V5.review_layout = 'list'
  sweep('ui_phase_review(cast-full)', function(c) H.review(c) end,
        { 1040, 780, 640 })
  CAST.cast.open = true
  sweep('ui_phase_review(cast-full-open)', function(c) H.review(c) end,
        { 1040, 780, 640 })

  V5.bookmarks = saved_bm
  V5.review_layout = 'list'
end

H.set_review(REVIEW)
V5.review_layout = 'list'

-- F8 as a direct assertion: an Indic paragraph must not be sized as if every
-- byte were a character.
do
  checks = checks + 1
  local en = REVIEW.en_paras[1]
  local tr = REVIEW.tr_paras[1]
  local h  = H.para_h(en, tr)
  -- 54 English chars / 51 Hindi clusters => 2 lines, not the 10-line cap
  if h > 4 * 20 + 14 then
    fail('_para_box_height', string.format(
      'sized a 2-line paragraph at %d px (byte count, not clusters)', h))
  end
end
H.set_phase('setup')
H.set_review(nil)

-- ══ 8. whole screens, both phases, every regime ════════════════════════════
H.set_cfg(CFG_FULL)
sweep('screen/setup', function(c) H.setup(c) end, { 1040, 860, 700, 560 })
H.set_cfg(CFG_EMPTY)
sweep('screen/setup(empty)', function(c) H.setup(c) end, { 1040, 700 })
-- v0.27 Console: both middles (a pasted script, and the engine log when there
-- is no script yet), and every stage the rail can be showing.
for _, cfg in ipairs({ CFG_FULL, CFG_EMPTY }) do
  H.set_cfg(cfg)
  -- '-' rather than nil: a table constructor with a leading nil makes ipairs
  -- stop at index 1, so the whole loop silently ran zero times.
  for _, tag in ipairs({ '-', 'S1b', 'S2c', 'S2d', 'S3e' }) do
    H.set_phase('running')
    H.set_stage(tag ~= '-' and tag or nil)
    H.set_prog(0.58)
    sweep('console/' .. tostring(cfg.SCRIPT_MODE) .. '/' .. tostring(tag),
          function(c) H.running(c) end, { 1400, 1040, 820, 700, 640, 560 })
  end
end
-- and the pipeline rail on its own, down to one column of cards
H.set_cfg(CFG_FULL)
H.set_phase('running')
H.set_stage('S2d')
sweep('pipe_rail', function(c) V5.pipe_rail(c, function() end, 252) end,
      { 1400, 1040, 820, 640, 480, 360, 260 })
sweep('console_inspector', function(c) V5.console_inspector(c) end,
      { 320, 300, 240, 210 })
H.set_phase('setup')

sweep('ui_rail', function(c) V5.ui_rail(c) end, { 1040 })
sweep('ui_header', function(c) V5.ui_header(c) end, { 1040, 600 })
sweep('ui_readiness', function(c) V5.ui_readiness(c) end, { 300, 288, 240 })
sweep('ui_settings_screen', function(c) V5.ui_settings_screen(c) end, { 1040, 800 })

-- ══ 9. old ReaImGui builds: the guarded fallbacks must actually run ════════
local OLD = { ImGui_BeginTable = true, ImGui_EndTable = true,
              ImGui_BeginCombo = true, ImGui_Selectable = true,
              ImGui_CreateFontFromFile = true, ImGui_PushFont = true,
              ImGui_DrawList_AddCircleFilled = true,
              ImGui_DrawList_AddRectFilled = true,
              ImGui_GetWindowDrawList = true }
H.set_cfg(CFG_FULL)
draw('screen/setup [old ReaImGui]', function(c) H.setup(c) end,
     { missing = OLD, w = 1040 })
draw('hist_row [old ReaImGui]', function(c)
  for i, e in ipairs(HIST) do V5.hist_row(c, i, e) end
end, { missing = OLD, w = 1040 })
draw('run_plan [old ReaImGui]', function(c) V5.run_plan(c) end,
     { missing = OLD, w = 300 })

-- The review screen with no tables. The List layout has nowhere to draw, so
-- the screen has to demote itself to the Grid's single-buffer editor rather
-- than leaving an empty canvas with a transport bar under it.
do
  local old_review = {}
  for k, v in pairs(REVIEW) do old_review[k] = v end
  old_review.use_table = false
  H.set_review(old_review)
  H.set_phase('review')
  V5.review_layout = 'list'
  draw('screen/review [old ReaImGui]', function(c) H.review(c) end,
       { missing = OLD, w = 1040 })
  H.set_phase('setup')
  H.set_review(nil)
end

-- ══ 10. the form kit itself, with the labels that actually overrun ═════════
-- 'Google TTS key' is the widest label in the panel and the one the measured
-- column was introduced for; the Indic labels are the ones ReaImGui measures
-- as 0 until its atlas has baked them.
local WIDE = { 'Google TTS key', 'Vertex service account JSON',
               'लक्ष्य भाषा', 'অনুবাদ মডেল', 'Model per stage override' }
for _, lbl in ipairs(WIDE) do
  sweep('form_kit/' .. lbl, function(c)
    V5.form_begin(c, 'kittest')
    V5.field(c, lbl, 260)
    local _, v = reaper.ImGui_InputText(c, '##kit', 'some value')
    V5.form_end(c)
  end, { 740, 460, 320 })

  sweep('form_kit_grid/' .. lbl, function(c)
    V5.grid_begin(c, 'kitgrid', 2)
    V5.cell(c)
    V5.cell_field(c, lbl, 0)
    reaper.ImGui_InputText(c, '##kg1', 'left value')
    V5.cell(c)
    V5.cell_field(c, lbl, 46)
    reaper.ImGui_InputText(c, '##kg2', 'right value')
    reaper.ImGui_SameLine(c)
    reaper.ImGui_Button(c, 'Use')
    V5.grid_end(c)
  end, { 1040, 740, 620 })
end

-- ══ 11. every 'advanced' group OPEN — that is where the wide labels live ════
V5.adv = V5.adv or {}
for _, k in ipairs({ 'voiceid_settings', 'ttsvoice', 'regenvoice', 'python',
                     'llm', 'tts', 'sync', 'prompts' }) do V5.adv[k] = true end
H.set_cfg(CFG_FULL)
for _, pane in ipairs(V5.PANES) do
  sweep('pane_open/' .. pane[1], function(c) pane[3](c) end, { 740, 560, 420 })
end
sweep('ui_voices_tool', function(c) V5.ui_voices_tool(c) end, { 900, 700, 520 })
sweep('ui_tools_tab',   function(c) V5.ui_tools_tab(c) end,   { 900, 700 })

-- ══ 12. the history row's LEGACY timestamp, which is the F4 trigger ════════
local HIST_LEGACY = {
  { ts = 'Wed Aug 19 14:32:07 2026', audio = [[D:\p\Isha_Kriya_Intro_EN.wav]],
    out_dir = [[D:\p\o]], language = 'Malayalam', status = 'done', mode = 'paste' },
  { ts = '19/08/2026 14:32', audio = [[D:\p\Darshan_part2.wav]],
    out_dir = [[D:\p\o]], language = 'Hindi', status = 'review', mode = 'auto' },
}
sweep('hist_row legacy ts', function(c)
  for i, e in ipairs(HIST_LEGACY) do V5.hist_row(c, i, e) end
end, { 1040, 700, 520, 440 })

-- ══ 13. F3 as arithmetic: the chip must fit the gap before the button ══════
do
  checks = checks + 1
  for _, e in ipairs({ HIST[1], HIST[2], HIST[3] }) do
    local _, chip_text = V5.hist_look(e)
    local pw = V5.text_w(nil, chip_text, 7) + 14      -- V5.pill's own width
    local gap = V5.HIST_CHIP_GAP or 84
    if pw > gap then
      fail('hist_row chip gap', string.format(
        'the "%s" chip is %.0f px wide but the button is placed %d px along',
        chip_text, pw, gap))
    end
  end
end

-- ══ 14. v0.27 stacked fields and the cost meter ═══════════════════════════
local FLD_LABELS = { 'English source', 'Target language',
                     'Or take it off a track', 'Vertex service account JSON',
                     'लक्ष्य भाषा — अनुवाद मॉडल', 'অনুবাদ মডেল' }
for _, lbl in ipairs(FLD_LABELS) do
  sweep('fld/' .. lbl, function(c)
    V5.fld(c, lbl, 'a tooltip', 0)
    reaper.ImGui_InputText(c, '##fld1', 'some value')
  end, { 740, 460, 300 })

  sweep('fgrid/' .. lbl, function(c)
    V5.fgrid_begin(c, 'fgt', 2)
    V5.fcell(c)
    V5.fld(c, lbl, 'a tooltip', 0, '4 paragraphs  ·  1,847 characters')
    reaper.ImGui_InputText(c, '##fg1', 'left value')
    V5.fcell(c)
    V5.fld(c, lbl, nil, 46)
    reaper.ImGui_InputText(c, '##fg2', 'right value')
    reaper.ImGui_SameLine(c, 0, 6)
    reaper.ImGui_Button(c, 'Use', 40, 0)
    V5.fcell(c)
    V5.fld(c, 'Script', nil, 0)
    V5.segmented(c, 'sm', 'have', { { 'auto', 'Translate with AI' },
                                    { 'have', 'I have a script' } })
    V5.fcell(c)
    V5.fld(c, 'Review', nil, 0)
    V5.segmented(c, 'rm', 'staged', { { 'staged', 'Pause to check' },
                                      { 'full', 'Straight through' } })
    V5.fgrid_end(c)
  end, { 1040, 780, 620, 480 })
end

-- the meter with and without a source length to charge transcription against
H.set_cfg(CFG_FULL)
for _, withplan in ipairs({ false, true }) do
  V5.plan = withplan and plan_fixture(521) or nil
  sweep('cost_meter/' .. tostring(withplan), function(c) V5.cost_meter(c) end,
        { 300, 288, 240, 200 })
end
V5.plan = nil
H.set_cfg(CFG_EMPTY)
sweep('cost_meter/empty', function(c) V5.cost_meter(c) end, { 300, 240 })
H.set_cfg(CFG_FULL)

-- ══ 15. v0.27 Studio: the approval gate ═══════════════════════════════════
for _, use_table in ipairs({ true, false }) do
  for _, total in ipairs({ 45, 130 }) do
    for _, sort in ipairs({ 'fit', 'index', 'start', 'speed' }) do
      V5.plan = plan_fixture(total, use_table)
      V5.plan.sort = sort
      H.set_phase('plan')
      sweep(string.format('studio/%s/%ds/%s', use_table and 'table' or 'rows',
                          total, sort),
            function(c) V5.ui_phase_plan(c) end, { 1400, 1040, 700, 560 })
    end
  end
end

-- every inspector tab, and the no-selection case
for _, tab in ipairs({ 'Chunk', 'Run', 'Voice' }) do
  V5.plan = plan_fixture(120)
  V5.plan_tab = tab
  H.set_phase('plan')
  sweep('studio_insp/' .. tab, function(c) V5.plan_inspector(c, V5.plan) end,
        { 320, 288, 240, 200 })
end
V5.plan = plan_fixture(120)
V5.plan.sel = nil
V5.plan_tab = 'Chunk'
sweep('studio_insp/none', function(c) V5.plan_inspector(c, V5.plan) end,
      { 320, 240 })

-- the inspector's key/value rows with values that do not fit
sweep('kv', function(c)
  V5.kv(c, 'Rate', '1.27 x')
  V5.kv(c, 'Language', 'Malayalam  ·  eleven_multilingual_v2')
  V5.kv(c, 'Model', 'gemini-2.5-pro-preview-06-05-experimental')
end, { 320, 240, 180 })

V5.plan = nil
V5.plan_tab = nil
H.set_phase('setup')

-- ══ 9c. v0.31 the source region ═══════════════════════════════════════════
-- What the run is ABOUT: the span of timeline the engine is given. Every
-- assertion here is a way of spending money on the wrong audio — dubbing a
-- whole hour because the trim was ignored, transcribing minutes of silence
-- because a time selection ran past the talk, or handing a trimmed item's
-- full source file to the engine because the fast path did not check.
do
  local WHOLE = { name = 'Sadhguru EN', items = {
    { pos = 0, len = 600, file = 'D:/p/talk.wav', src_len = 600 } } }
  local TRIMMED = { name = 'Sadhguru EN', items = {
    -- 95 s of a 600 s file, 30 s in, parked at 2:00 on the timeline
    { pos = 120, len = 95, offs = 30, file = 'D:/p/talk.wav',
      src_len = 600 } } }

  -- 1. an untrimmed item at 0:00 is the whole file, and is still the one case
  --    that needs no render.
  checks = checks + 1
  T.set_project({ tracks = { WHOLE } })
  H.set_src_track(0)
  local plan = V5.timeline_region()
  if not plan or math.abs(plan.a) > 0.01 or math.abs(plan.b - 600) > 0.01 then
    fail('timeline_region', 'an untrimmed 10-minute item did not read as ' ..
         '0:00-10:00: ' .. (plan and string.format('%.1f..%.1f', plan.a, plan.b)
                            or 'nil'))
  end
  checks = checks + 1
  T.files['D:/p/talk.wav'] = 'RIFF'          -- file_exists() reads through io
  local path, why, rendered, pos = H.audio_for_region(plan)
  if path ~= 'D:/p/talk.wav' or rendered or (pos or 0) ~= 0 then
    fail('audio_for_region', string.format(
      'the whole-file case rendered instead of using the file (%s, rendered=%s)',
      tostring(path or why), tostring(rendered)))
  end

  -- 2. THE POINT: a trimmed item dubs the trim. Both halves matter — the span
  --    is the item's 95 s and not the file's 600, and the file must NOT be
  --    handed over whole just because the track holds a single item.
  checks = checks + 1
  T.set_project({ tracks = { TRIMMED } })
  plan = V5.timeline_region()
  if not plan or math.abs(plan.a - 120) > 0.01 or math.abs(plan.b - 215) > 0.01
  then
    fail('timeline_region', 'a trimmed item did not read as its own span: ' ..
         (plan and string.format('%.1f..%.1f', plan.a, plan.b) or 'nil'))
  end
  checks = checks + 1
  path, why, rendered, pos = H.audio_for_region(plan)
  -- The render cannot succeed here (Main_OnCommand is a stub and no wav
  -- appears), so the ONLY passing answer is "it tried to render".
  if path == 'D:/p/talk.wav' then
    fail('audio_for_region',
         'a trimmed item was handed to the engine as its whole 600 s source ' ..
         'file — the trim is exactly what the run is supposed to cover')
  elseif path ~= nil then
    fail('audio_for_region', 'unexpected path: ' .. tostring(path))
  end

  -- 2b. the predicate the source row leans on: only a whole untrimmed item at
  --     0:00 IS the file. Get this wrong in the permissive direction and the
  --     row says "dubbing 1:35" while the engine is handed the whole hour.
  checks = checks + 1
  T.set_project({ tracks = { WHOLE } })
  H.set_src_track(0)
  local whole_ok, whole_file = V5.region_is_whole_file(V5.timeline_region())
  T.set_project({ tracks = { TRIMMED } })
  local trimmed_whole = V5.region_is_whole_file(V5.timeline_region())
  if not whole_ok or whole_file ~= 'D:/p/talk.wav' or trimmed_whole then
    fail('region_is_whole_file', string.format(
      'whole=%s (%s), trimmed=%s — expected true / false',
      tostring(whole_ok), tostring(whole_file), tostring(trimmed_whole)))
  end

  -- 3. a time selection wins, and is clamped to what the track holds: a
  --    selection dragged to the end of the project would otherwise render
  --    (and transcribe) minutes of silence.
  checks = checks + 1
  T.set_project({ tracks = { TRIMMED }, time_sel = { 130, 160 } })
  plan = V5.timeline_region()
  if not plan or math.abs(plan.a - 130) > 0.01 or math.abs(plan.b - 160) > 0.01
     or plan.why ~= 'the time selection' then
    fail('timeline_region', 'the time selection did not win: ' ..
         (plan and string.format('%.1f..%.1f (%s)', plan.a, plan.b, plan.why)
          or 'nil'))
  end
  checks = checks + 1
  T.set_project({ tracks = { TRIMMED }, time_sel = { 100, 900 } })
  plan = V5.timeline_region()
  if not plan or math.abs(plan.a - 120) > 0.01 or math.abs(plan.b - 215) > 0.01
  then
    fail('timeline_region', 'a time selection past both ends of the talk was ' ..
         'not clamped to it: ' ..
         (plan and string.format('%.1f..%.1f', plan.a, plan.b) or 'nil'))
  end
  checks = checks + 1
  T.set_project({ tracks = { TRIMMED }, time_sel = { 400, 500 } })
  local nope, reason = V5.timeline_region()
  if nope ~= nil or (reason or '') == '' then
    fail('timeline_region',
         'a time selection that misses the track was accepted anyway')
  end

  -- 4. a selected item says which track, so the combo can stay on
  --    "(from track)" — clicking the piece you mean is the whole gesture.
  checks = checks + 1
  local A = { name = 'Music', items = {
    { pos = 0, len = 300, file = 'D:/p/music.wav', src_len = 300 } } }
  local B = { name = 'Sadhguru EN', items = {
    { pos = 60, len = 40, offs = 10, file = 'D:/p/talk.wav', src_len = 600,
      selected = true } } }
  T.set_project({ tracks = { A, B } })
  H.set_src_track(-1)
  plan = V5.timeline_region()
  if not plan or math.abs(plan.a - 60) > 0.01 or math.abs(plan.b - 100) > 0.01
     or plan.why ~= 'the selected item' then
    fail('timeline_region', 'a selected item did not supply its own track: ' ..
         (plan and string.format('%.1f..%.1f (%s)', plan.a, plan.b, plan.why)
          or 'nil'))
  end
  -- and a selection on ANOTHER track is ignored once a track is chosen
  checks = checks + 1
  H.set_src_track(0)
  plan = V5.timeline_region()
  if not plan or math.abs(plan.b - 300) > 0.01 then
    fail('timeline_region',
         'the chosen track lost to a selected item on a different one')
  end

  -- 5. the sidecar: where the dub goes back. Written next to the rendered wav
  --    and read by the import and the review transport.
  checks = checks + 1
  local WAV = 'C:/proj/DubSource/take.wav'
  T.files[WAV .. V5.REGION_SUFFIX] = table.concat({
    '{', '  "version": 1,', '  "source": "D:\\\\p\\\\talk.wav",',
    '  "project_pos": 120.500000,', '  "start": 120.500000,',
    '  "end": 215.500000,', '  "track": "Sadhguru EN",',
    '  "why": "the track\'s items"', '}',
  }, '\n')
  local r = V5.region_load(WAV)
  if not r or math.abs(r.pos - 120.5) > 0.001
     or math.abs(V5.region_offset(WAV) - 120.5) > 0.001 then
    fail('region_load', 'the sidecar did not give back its project position')
  end
  checks = checks + 1
  if V5.region_offset('D:/p/plain.wav') ~= 0 then
    fail('region_offset', 'a plain file with no sidecar must answer 0 — that ' ..
         'is every run before regions existed')
  end

  -- 6. the review transport takes its zero from the sidecar when the region
  --    wav is not on the timeline (it never is — it is a slice of what is).
  checks = checks + 1
  local RR = { manifest = { audio = WAV }, use_table = true,
               en_paras = REVIEW.en_paras, tr_paras = REVIEW.tr_paras }
  T.set_project({ tracks = {} })
  V5.review_relink(RR)
  if math.abs((RR.time_off or 0) - 120.5) > 0.001 then
    fail('review_relink', string.format(
      'a region run timed its previews from %.1f s — the region starts at ' ..
      '120.5 s, which is where "Play here" has to land',
      RR.time_off or 0))
  end

  -- 7. the screen itself, with a project to take audio from. The source cell
  --    grew a live caption line, and the track picker has never been drawn in
  --    this harness before (CountTracks used to answer 0 for everything).
  T.set_project({ tracks = { A, B }, time_sel = { 65, 90 } })
  H.set_src_track(1)
  H.set_cfg(CFG_FULL)
  H.set_phase('setup')
  sweep('screen/setup(region)', function(c) H.setup(c) end,
        { 1040, 860, 700, 560 })
  T.set_project({ tracks = { WHOLE } })
  H.set_src_track(0)
  sweep('screen/setup(region-whole)', function(c) H.setup(c) end,
        { 1040, 700 })

  -- Leave the project empty: every later case assumes a bare REAPER.
  T.set_project(nil)
  H.set_src_track(-1)
end

-- ══ 16. the chunk-level locals the screens reach for ══════════════════════
-- A typo in one resolves to a nil global, which is valid Lua right up to the
-- call — the one error class luaparse cannot see. Asserting the names resolve
-- is the cheapest place to catch it.
do
  checks = checks + 1
  for name, v in pairs(H.callables()) do
    if name == 'CONFIG_DIR' then
      if type(v) ~= 'string' or v == '' then
        fail('commands/callables', 'CONFIG_DIR is not a string')
      end
    elseif type(v) ~= 'function' then
      fail('commands/callables',
           name .. ' is ' .. type(v) .. ', not a function — a command that ' ..
           'calls it would fail only when pressed')
    end
  end
  for _, n in ipairs({ 'start_plan_run', 'start_dubplan_run', 'do_save_settings',
                       'check_update', 'plan_paste_corrections', 'plan_reload',
                       'win_roll', 'win_maximise', 'go' }) do
    if type(V5[n]) ~= 'function' then
      fail('commands/callables', 'V5.' .. n .. ' is ' .. type(V5[n]))
    end
  end
end

-- the title bar
sweep('titlebar', function(c) V5.ui_titlebar(c, function() end) end,
      { 1400, 1040, 700, 560, 420, 300 }, { chrome = true })

-- ══ report ════════════════════════════════════════════════════════════════
-- Grouped by the function under test, not by regime/width, or one bad column
-- reports thirty times and hides everything else.
local groups, order = {}, {}
for _, f in ipairs(fails) do
  local g = f.name:match('^(.-) %[') or f.name
  if not groups[g] then groups[g] = { n = 0, seen = {}, ex = {} } order[#order+1] = g end
  local G = groups[g]
  G.n = G.n + 1
  if not G.seen[f.detail] then
    G.seen[f.detail] = true
    if #G.ex < 3 then
      G.ex[#G.ex + 1] = (f.name:match('%[(.-)%]') or '?') .. '  ' .. f.detail
    end
    G.distinct = (G.distinct or 0) + 1
  end
end

print('')
print(string.format('  %d draws checked  ·  %d group(s) failing  ·  %d finding(s)',
                    checks, #order, #fails))
print('')
if #order == 0 then
  print('  PASS  no collisions, no overflow, no leaked stacks, in any regime.')
else
  for _, g in ipairs(order) do
    local G = groups[g]
    print(string.format('  FAIL  %s   (%d distinct)', g, G.distinct or 0))
    for _, d in ipairs(G.ex) do print('          ' .. d) end
  end
end
print('')
