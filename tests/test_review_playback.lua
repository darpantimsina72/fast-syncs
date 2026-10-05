-- Offline check for the review-screen playback (Dub_Pipeline_Panel.lua,
-- 0.15.10). The V5.review_* functions are cut out of the panel and run on a
-- fake `reaper` transport.
--
--   * paragraph times recovered from the English SRT (whole cues per
--     paragraph, ordered, "—" placeholder untimed, no SRT -> nil)
--   * re-link finds the English item by file name and its offset
--   * ▶ on a row seeks to that paragraph (+ the item offset) and plays
--   * ⏪/⏩ jump from the play position (playing/paused) or the cursor
--     (stopped), clamped to the English item
--   * Follow walks the selection with the play cursor, not while typing
--
-- Run:  lua tests/test_review_playback.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local src = io.open(here .. "/../dubbing/reaper/Dub_Pipeline_Panel.lua"):read("*a")
local a = assert(src:find("function V5.review_norm", 1, true))
local b = assert(src:find("local function ui_phase_review", a, true))
local chunk = src:sub(a, b - 1)

local fails = 0
local function check(name, cond)
  print((cond and "  PASS " or "  FAIL ") .. name)
  if not cond then fails = fails + 1 end
end
local function near(x, y) return x and math.abs(x - y) < 1e-6 end

-- SRT: 5 cues
local CUES = {
  { start = 0.0,  stop = 2.0,  text = "Hello and welcome." },
  { start = 2.5,  stop = 5.0,  text = "Today we talk about the mind." },
  { start = 6.0,  stop = 9.0,  text = "The mind is a tool." },
  { start = 9.5,  stop = 12.0, text = "Use it well." },
  { start = 13.0, stop = 16.0, text = "Thank you." },
}

local T = { state = 0, play = 0, cursor = 0, items = {} }   -- fake transport
local banners = {}
local env = {
  V5 = {}, ipairs = ipairs, tostring = tostring, tonumber = tonumber,
  type = type, math = math, string = string,
  file_exists = function(p) return p == "/run/talk.srt" end,
  parse_srt_file = function() return CUES end,
  basename = function(p) return p:match("([^/]+)$") or p end,
  ui_set_banner = function(kind, msg) banners[#banners + 1] = kind .. ": " .. msg end,
  _grey_hint = function() end,
}
env.reaper = {
  GetPlayState = function() return T.state end,
  GetPlayPosition = function() return T.play end,
  GetCursorPosition = function() return T.cursor end,
  SetEditCurPos = function(t) T.cursor = t; if T.state ~= 0 then T.play = t end end,
  CSurf_OnPlay = function() T.state = 1; T.play = T.cursor end,
  UpdateArrange = function() end,
  CountMediaItems = function() return #T.items end,
  GetMediaItem = function(_, i) return T.items[i + 1] end,
  GetActiveTake = function(it) return it end,
  TakeIsMIDI = function() return false end,
  GetMediaItemTake_Source = function(it) return it end,
  GetMediaSourceParent = function() return nil end,
  GetMediaSourceFileName = function(s) return s.file end,
  GetMediaItemInfo_Value = function(it, k) return k == "D_POSITION" and it.pos or it.len end,
  GetMediaItemTakeInfo_Value = function(it) return it.offs end,
  ImGui_IsAnyItemActive = function() return T.typing end,
}
assert(load(chunk, "review", "t", env))()
local V5 = env.V5

-- 1. times
local paras = { "Hello and welcome. Today we talk about the mind.",
                "—",
                "The mind is a tool. Use it well.",
                "Thank you." }
local slots, total = V5.review_times(paras, "/run/talk.srt")
check("one slot per paragraph", slots and #slots == 4)
check("para 1 = cues 1-2", slots and near(slots[1].start_s, 0) and near(slots[1].stop_s, 5))
check("placeholder untimed", slots and slots[2].timed == false)
check("para 3 = cues 3-4", slots and near(slots[3].start_s, 6) and near(slots[3].stop_s, 12))
check("last para takes the rest", slots and near(slots[4].start_s, 13) and near(slots[4].stop_s, 16))
check("duration = last cue end", near(total, 16))
check("no SRT -> nil", V5.review_times(paras, "/run/missing.srt") == nil)

-- 2. relink + init
T.items = { { file = "/x/other.wav", pos = 0, offs = 0, len = 5 },
            { file = "/media/talk.wav", pos = 30, offs = 0, len = 16 } }
local R = { en_paras = paras, manifest = { audio = "/media/talk.wav", en_srt = "/run/talk.srt" } }
V5.review_init(R)
check("linked by file name", R.linked == "talk.wav" and near(R.time_off, 30))
check("row 1 selected, Follow on by default", R.sel == 1 and R.follow == true)

-- 3. play a row
V5.review_play_row(R, 3)
check("▶ row 3 -> 30 + 6 and playing", near(T.cursor, 36) and T.state == 1 and R.sel == 3)
local nb = #banners
V5.review_play_row(R, 2)
check("placeholder row does not play, says why", #banners == nb + 1 and R.sel == 3)

-- 4. jumps
T.state, T.play = 1, 40
V5.review_jump(R, -3)
check("playing: back 3 s from the play position", near(T.cursor, 37))
T.state, T.play = 2, 40
V5.review_jump(R, 5)
check("paused: the pause point moves +5", near(T.cursor, 45) and near(T.play, 45))
T.state, T.cursor = 0, 31
V5.review_jump(R, -5)
check("stopped: cursor moves, clamped to the item start", near(T.cursor, 30))
T.cursor = 44
V5.review_jump(R, 5)
check("clamped to the item end", near(T.cursor, 46))

-- 5. follow
T.state, T.play, T.typing = 1, 30 + 13.5, false
V5.review_follow_poll({}, R)
check("Follow selects the paragraph under the play cursor", R.sel == 4 and R.scroll_to == 4)
T.play, T.typing = 30 + 1, true
V5.review_follow_poll({}, R)
check("not while a text box has focus", R.sel == 4)
T.typing = false
R.follow = false
V5.review_follow_poll({}, R)
check("Follow off -> selection stays", R.sel == 4)

-- 6. audio not on the timeline
T.items = {}
local R2 = { en_paras = paras, manifest = { audio = "/media/talk.wav", en_srt = "/run/talk.srt" } }
V5.review_init(R2)
nb = #banners
V5.review_play_row(R2, 1)
check("not on the timeline -> offset 0 + a warning", R2.linked == nil and near(T.cursor, 0)
      and #banners == nb + 1 and banners[#banners]:find("not on the timeline", 1, true))
local R3 = { en_paras = paras, manifest = { audio = "/proj/DubSource/Track_1.wav", en_srt = "/run/talk.srt" } }
V5.review_init(R3)
nb = #banners
V5.review_play_row(R3, 3)
check("track render: offset 0, no warning", R3.is_render and near(T.cursor, 6) and #banners == nb)
check("m:ss", V5.review_at(75) == "1:15")

print(fails == 0 and "\nGREEN: all checks passed" or ("\nRED: " .. fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
