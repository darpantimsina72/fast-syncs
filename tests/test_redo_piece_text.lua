-- Offline check for "Redo one line" showing THIS piece's words
-- (Dub_Pipeline_Panel.lua, 0.15.19): V5.piece_text and its helpers, cut out
-- of the panel and run on a fake `reaper`.
--
-- Reported 2026-11-21: reopen a finished project, select one chunk, and the
-- Redo pane showed the whole script of that audio instead of the chunk's
-- line. Checks:
--   * an ordinary dub chunk (one line over the run's long speech wav) keeps
--     its stored text exactly — no note
--   * a chunk carrying the WHOLE script gets its own line from the run's
--     timings + texts files
--   * same, when the files are only reachable through engine_done.json
--   * a Text to Speech take cut into pieces: each piece gets its own
--     sentences, estimated from timing
--   * a cut in the middle of one long sentence falls back to words
--   * an uncut item keeps its whole text
--   * an empty chunk of a run is filled from the run's files
--
-- Run:  lua tests/test_redo_piece_text.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local src = io.open(here .. "/../dubbing/reaper/Dub_Pipeline_Panel.lua"):read("*a")
local function cut(sig)
  local a = assert(src:find(sig, 1, true), sig)
  local b = src:find("\nend\n", a, true)
  return src:sub(a, b + 4)
end

local fails = 0
local function check(name, cond)
  print((cond and "  PASS " or "  FAIL ") .. name)
  if not cond then fails = fails + 1 end
end

local tmp = os.tmpname(); os.remove(tmp)
local function mk(p) os.execute("mkdir -p '" .. p .. "'") end
local function put(p, s) local f = io.open(p, "wb"); f:write(s); f:close() end
local function exists(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end
local function read_all(p) local f = io.open(p, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s end

-- A flat run folder: speech wav + timings + texts, like the engine writes.
local run = tmp .. "/Media/talk"; mk(run)
put(run .. "/engine_done.json", '{"status":"ok","language":"Hindi"}\n')
put(run .. "/Hindi_(talk)_tts.wav", "")
put(run .. "/Hindi_(talk)_sync_timestamps.txt",
  "[Index] [Orig Start] [Orig End] [Orig Duration] [Synced Start]\n" ..
  "[1] [0ms] [2000ms] [2000ms] [500ms]\n" ..
  "[2] [2500ms] [4500ms] [2000ms] [3000ms]\n" ..
  "[3] [5000ms] [8000ms] [3000ms] [6000ms]\n")
put(run .. "/Hindi_(talk)_sync_texts.txt",
  "पहली पंक्ति यहाँ है।\n\nदूसरी पंक्ति यहाँ है।\n\nतीसरी पंक्ति यहाँ है।\n")
local WHOLE = "पहली पंक्ति यहाँ है। दूसरी पंक्ति यहाँ है। तीसरी पंक्ति यहाँ है। " ..
              string.rep("और भी बहुत कुछ कहा गया था इस वीडियो में जो यहाँ लिखा है। ", 12)

-- A second run whose sidecars sit elsewhere, named only in engine_done.json.
local run2 = tmp .. "/Media/other"; mk(run2); mk(tmp .. "/elsewhere")
put(run2 .. "/Tamil_(other)_tts.wav", "")
put(tmp .. "/elsewhere/ts.txt",
  "[1] [0ms] [3000ms] [3000ms] [0ms]\n[2] [3000ms] [6000ms] [3000ms] [3000ms]\n")
put(tmp .. "/elsewhere/tx.txt", "line one\n\nline two\n")
put(run2 .. "/engine_done.json", string.format(
  '{"status":"ok","timestamps_txt":"%s","sync_texts":"%s"}\n',
  tmp .. "/elsewhere/ts.txt", tmp .. "/elsewhere/tx.txt"))

-- Fake items: { path, src_len, offs, len, text, guid }.
local env = {
  V5 = {}, SEP = "/", ipairs = ipairs, pairs = pairs, pcall = pcall,
  io = io, string = string, table = table, math = math, tonumber = tonumber,
  tostring = tostring, print = print,
  file_exists = exists, read_all = read_all,
  basename = function(p) return p:match("([^/]+)$") or p end,
  load_manifest_json = function(p)
    local s = read_all(p); if not s then return nil end
    return { status = s:match('"status":"(.-)"') or "",
             language = s:match('"language":"(.-)"') or "",
             timestamps_txt = s:match('"timestamps_txt":"(.-)"') or "",
             sync_texts = s:match('"sync_texts":"(.-)"') or "", out_dir = "" }
  end,
  _item_guid = function(it) return it.guid end,
}
local ALL = {}     -- every item "on the timeline"
env.reaper = {
  GetActiveTake = function(it) return it end,
  TakeIsMIDI = function() return false end,
  GetMediaItemTake_Source = function(t) return t end,
  GetMediaSourceFileName = function(s, _) return s.path end,
  GetMediaSourceLength = function(s) return s.src_len, false end,
  GetMediaItemTakeInfo_Value = function(t, k)
    if k == "D_STARTOFFS" then return t.offs end
    if k == "D_PLAYRATE" then return 1 end
  end,
  GetMediaItemInfo_Value = function(it, k) if k == "D_LENGTH" then return it.len end end,
  GetSetMediaItemInfo_String = function(it, k) return true, it.text or "" end,
  RecursiveCreateDirectory = function() end,
  CountMediaItems = function() return #ALL end,
  GetMediaItem = function(_, i) return ALL[i + 1] end,
}

local pieces = {
  [[local TS_PATTERN = ]],
  "local function parse_timestamps_file(path)",
  "function V5.parse_texts_file(path)",
  "function V5.is_tidy(dir)",
  "function V5.layout_path(out_dir, kind, filename, make)",
  "function V5.get_item_text(item)",
  "function V5._rg_chars(str)",
  "function V5.out_dir_from_item(item)",
  "function V5.piece_window(item)",
  "function V5.text_is_for_source(text, piece_len, src_len)",
  "function V5.run_line_for_piece(item, a, b)",
  "function V5.estimate_piece_text(text, a, b, src_len)",
  "function V5.text_shared(item, stored)",
  "function V5.piece_text(item)",
}
local code = {}
for _, sig in ipairs(pieces) do
  if sig == [[local TS_PATTERN = ]] then
    local a = assert(src:find(sig, 1, true))
    local b = src:find("\n\n", a, true)
    code[#code + 1] = src:sub(a, b)
  else
    code[#code + 1] = cut(sig)
  end
end
code[#code + 1] = "V5.SPEECH_CPS = 12\nV5.piece_cache = {}\nV5.ITEM_TEXT_KEY = 'x'\n" ..
                  "V5.LAYOUT_MARKER = '.fastsyncs-layout'\nV5.LAYOUT_SUB = { work = '_work' }\n" ..
                  "return V5"
local V5 = assert(load(table.concat(code, "\n"), "panel_cut", "t", env))()

local n = 0
local function item(path, src_len, offs, len, text)
  n = n + 1
  local it = { path = path, src_len = src_len, offs = offs, len = len,
               text = text, guid = "g" .. n }
  ALL[#ALL + 1] = it
  return it
end
local tts = run .. "/Hindi_(talk)_tts.wav"

-- 1. ordinary chunk: unchanged
local t, how = V5.piece_text(item(tts, 60, 2.5, 2.0, "दूसरी पंक्ति यहाँ है।"))
check("ordinary dub chunk keeps its own stored line", t == "दूसरी पंक्ति यहाँ है।" and how == nil)

-- 2. chunk carrying the whole script -> its own line from the run's files
t, how = V5.piece_text(item(tts, 60, 2.5, 2.0, WHOLE))
check("whole-script chunk -> its own line from the run files",
      t == "दूसरी पंक्ति यहाँ है।" and how == "run")

-- 3. via engine_done.json
t, how = V5.piece_text(item(run2 .. "/Tamil_(other)_tts.wav", 600, 3.0, 3.0,
                            string.rep("whole script words here. ", 40)))
check("files found through engine_done.json", t == "line two" and how == "run")

-- 4. a Text to Speech take cut into pieces: sentences by timing
local tts_take = tmp .. "/Media/TTS/tts_1.wav"
local s1 = "This is the first sentence of the script."
local s2 = "Here comes the second one, a bit longer than that."
local s3 = "And this is the third and last sentence here."
local full = s1 .. " " .. s2 .. " " .. s3
local total = #full                      -- ASCII: chars == bytes
local L = total / 14                     -- recording length at 14 chars/s
local e1 = (#s1 + 1) / total * L
local e2 = (#s1 + 1 + #s2 + 1) / total * L
local p1 = item(tts_take, L, 0, e1, full)
local p2 = item(tts_take, L, e1, e2 - e1, full)
local p3 = item(tts_take, L, e2, L - e2, full)
t, how = V5.piece_text(p1)
check("TTS piece 1 -> first sentence only", t == s1 and how == "estimate")
t, how = V5.piece_text(p2)
check("TTS piece 2 -> second sentence only", t == s2 and how == "estimate")
t, how = V5.piece_text(p3)
check("TTS piece 3 -> third sentence only", t == s3 and how == "estimate")

-- 4b. slow speech cut in two halves: caught because both halves share the
-- same audio file and the same text
local slow = tmp .. "/Media/TTS/slow.wav"
local Ls = total / 6                     -- 6 chars/s: a very slow voice
local h1 = item(slow, Ls, 0, e2 / L * Ls, full)
item(slow, Ls, e2 / L * Ls, Ls - e2 / L * Ls, full)
t, how = V5.piece_text(h1)
check("slow speech, first of two halves -> first two sentences",
      t == s1 .. " " .. s2 and how == "estimate")

-- 5. cut inside one long sentence -> words
local long = "one two three four five six seven eight nine ten eleven twelve " ..
             "thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty"
t, how = V5.piece_text(item(tmp .. "/x.wav", 20, 0, 5, long))
check("cut inside one long sentence -> its first words, not all of it",
      how == "estimate" and t:sub(1, 13) == "one two three" and #t < #long / 2)

-- 6. uncut item: whole text stays
t, how = V5.piece_text(item(tmp .. "/Media/TTS/uncut.wav", L, 0, L, full))
check("uncut item keeps its whole text", t == full and how == nil)

-- 7. empty chunk of a run -> filled from the run's files
t, how = V5.piece_text(item(tts, 60, 5.0, 3.0, ""))
check("empty run chunk -> its line from the run files",
      t == "तीसरी पंक्ति यहाँ है।" and how == "run")

-- 7b. two dub chunks that say the same short line are not a cut
local dup = "हाँ, बिल्कुल।"
item(tts, 60, 9.0, 1.0, dup)
t, how = V5.piece_text(item(tts, 60, 20.0, 1.0, dup))
check("two chunks with the same short line keep their text",
      t == dup and how == nil)

-- 8. whole script with no run files and no sentence ends
local nopunct = string.rep("word ", 200)
t, how = V5.piece_text(item(tmp .. "/y.wav", 100, 50, 2, nopunct))
check("no run files, no sentence ends -> a few words, not 200",
      how == "estimate" and select(2, t:gsub("%S+", "")) < 20)

os.execute("rm -rf '" .. tmp .. "'")
print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
