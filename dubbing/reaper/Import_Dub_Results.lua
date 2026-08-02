-- Import_Dub_Results.lua
--
-- Reaper Dubbing App -- standalone importer (contract v0.1).
-- Plain Lua, no ReaImGui required.
--
-- Asks the user for an engine_done.json result manifest (fallback: pick the
-- *_sync_timestamps.txt directly and derive sibling file names), then builds
-- the contract import layout, appended at the end of the project:
--
--   1. "EN Original"        - one item: the copied original audio, position 0
--   2. "Dub Chunks"         - one item per timestamps line, cut from tts_wav
--                             (D_STARTOFFS = orig start, D_LENGTH = orig dur,
--                              D_POSITION = synced start; note = cue text)
--   3. "Dub Rendered (ref)" - one item: final synced wav, position 0, MUTED
--
-- Plus one project region per synced-SRT cue. Everything happens inside a
-- single undo block. Empty ("") or missing manifest files are skipped and
-- reported in a summary message box at the end.
--
-- A second run never reuses existing tracks: it creates a fresh set with a
-- " 2" / " 3" / ... suffix on the track names.

local SEP = package.config:sub(1, 1)

-- ---------------------------------------------------------------------------
-- Small path / file helpers
-- ---------------------------------------------------------------------------

local function file_exists(path)
  if not path or path == "" then return false end
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function dirname(path)
  return path:match("^(.*)[/\\][^/\\]*$") or ""
end

local function basename(path)
  return path:match("([^/\\]+)$") or path
end

local function strip_ext(path)
  return path:match("^(.*)%.[^./\\]+$") or path
end

-- Case-insensitive "ends with" (byte-safe: only ASCII case is folded).
local function ends_with_ci(s, suffix)
  return s:lower():sub(-#suffix) == suffix:lower()
end

-- ---------------------------------------------------------------------------
-- Minimal tolerant JSON reader (flat string / number / bool fields only).
-- The engine_done.json manifest is a flat object of strings, so a full JSON
-- parser is unnecessary; we scan for '"key"' and decode the value after it.
-- Byte-safe for UTF-8: escapes and quotes are ASCII, and UTF-8 continuation
-- bytes can never be mistaken for them.
-- ---------------------------------------------------------------------------

local function utf8_encode(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40),
                       0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000),
                       0x80 + math.floor(cp / 0x40) % 0x40,
                       0x80 + cp % 0x40)
  else
    return string.char(0xF0 + math.floor(cp / 0x40000),
                       0x80 + math.floor(cp / 0x1000) % 0x40,
                       0x80 + math.floor(cp / 0x40) % 0x40,
                       0x80 + cp % 0x40)
  end
end

local function skip_ws(s, i)
  while i <= #s do
    local c = s:byte(i)
    if c == 32 or c == 9 or c == 10 or c == 13 then i = i + 1 else break end
  end
  return i
end

-- Decode a JSON string starting at s[i] == '"'. Returns value, next index.
local JSON_ESCAPES = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
  n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
}

local function decode_json_string(s, i)
  local buf = {}
  i = i + 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(buf), i + 1
    elseif c == "\\" then
      local e = s:sub(i + 1, i + 1)
      if e == "u" then
        local cp = tonumber(s:sub(i + 2, i + 5), 16) or 0xFFFD
        i = i + 6
        -- Combine a UTF-16 surrogate pair when present.
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
          local lo = tonumber(s:sub(i + 2, i + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          end
        end
        buf[#buf + 1] = utf8_encode(cp)
      else
        buf[#buf + 1] = JSON_ESCAPES[e] or e
        i = i + 2
      end
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
  return table.concat(buf), i
end

-- Find a top-level-ish "key": value pair and return the decoded value
-- (string, number, or boolean), or nil when absent.
local function json_field(s, key)
  local needle = '"' .. key .. '"'
  local pos = 1
  while true do
    local a, b = s:find(needle, pos, true)
    if not a then return nil end
    local i = skip_ws(s, b + 1)
    if s:sub(i, i) == ":" then
      i = skip_ws(s, i + 1)
      local c = s:sub(i, i)
      if c == '"' then
        local v = decode_json_string(s, i)
        return v
      end
      local num = s:match("^%-?%d+%.?%d*", i)
      if num then return tonumber(num) end
      local lit = s:match("^%a+", i)
      if lit == "true" then return true end
      if lit == "false" then return false end
      return nil  -- null / nested value: not needed for this manifest
    end
    pos = b + 1
  end
end

-- ---------------------------------------------------------------------------
-- Timestamps file parser
-- Format (see _format_timestamps_as_text in the app, header line included):
--   [Index] [Orig Start] [Orig End] [Orig Duration] [Synced Start]
--   [2] [630ms] [2790ms] [2160ms] [49879ms]
-- All values are milliseconds; REAPER wants seconds.
-- ---------------------------------------------------------------------------

local TS_PATTERN = "%[%s*(%d+)%s*%]%s*%[%s*(%d+)%s*ms%s*%]%s*%[%s*(%d+)%s*ms%s*%]" ..
                   "%s*%[%s*(%d+)%s*ms%s*%]%s*%[%s*(%d+)%s*ms%s*%]"

local function parse_timestamps_file(path)
  local entries = {}
  local f = io.open(path, "rb")
  if not f then return entries end
  for line in f:lines() do
    local idx, s_ms, e_ms, d_ms, sy_ms = line:match(TS_PATTERN)
    if idx then
      local orig_start = tonumber(s_ms) / 1000.0
      local orig_end   = tonumber(e_ms) / 1000.0
      local dur        = tonumber(d_ms) / 1000.0
      local synced     = tonumber(sy_ms) / 1000.0
      -- Fall back to end-start when the duration column is not sensible.
      if dur <= 0 then dur = orig_end - orig_start end
      -- v0.7 optional 6th field: [synced] / [unsync]. Letters only, so the
      -- trailing "[12345ms]" of a 5-field line can never match. Absent
      -- field = synced (pre-v0.7 files).
      local status = line:match("%[%s*(%a+)%s*%]%s*$")
      if dur > 0 then
        entries[#entries + 1] = {
          index        = tonumber(idx),
          orig_start   = orig_start,
          orig_end     = orig_end,
          dur          = dur,
          synced_start = synced,
          unsync       = (status == "unsync") or nil,
        }
      end
    end
  end
  f:close()
  return entries
end

-- v0.7 texts sidecar (<base>_sync_texts.txt): blank-line-separated blocks,
-- block N = chunk text for timestamps index N. Byte-safe: only newline
-- splitting + ASCII whitespace trims touch the (Indic) text.
local function parse_texts_file(path)
  local blocks = {}
  local content = read_all(path)
  if not content then return blocks end
  if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  local parts = nil
  local function flush()
    if parts and #parts > 0 then
      blocks[#blocks + 1] = table.concat(parts, " ")
    end
    parts = nil
  end
  for line in (content .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed == "" then
      flush()
    else
      parts = parts or {}
      parts[#parts + 1] = trimmed
    end
  end
  flush()
  return blocks
end

-- ---------------------------------------------------------------------------
-- SRT parser
-- CRLF-safe, multi-line cue text joined with " ", UTF-8 byte-safe: we only
-- split on newline bytes and match ASCII digits/punctuation; cue TEXT is
-- never run through multi-byte-unsafe patterns beyond ASCII whitespace trim
-- (UTF-8 continuation bytes are >= 0x80 and can never match ASCII classes).
-- ---------------------------------------------------------------------------

local SRT_TIME_PATTERN = "^%s*(%d+):(%d+):(%d+)[,%.](%d+)%s*%-%->" ..
                         "%s*(%d+):(%d+):(%d+)[,%.](%d+)"

local function parse_srt_file(path)
  local cues = {}
  local content = read_all(path)
  if not content then return cues end
  -- Strip a UTF-8 BOM if present, then normalise CRLF / lone CR to LF.
  if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")

  local cur = nil
  local function flush()
    if cur then
      cur.text = table.concat(cur.parts, " ")
      cur.parts = nil
      cues[#cues + 1] = cur
      cur = nil
    end
  end

  for line in (content .. "\n"):gmatch("(.-)\n") do
    local h1, m1, s1, ms1, h2, m2, s2, ms2 = line:match(SRT_TIME_PATTERN)
    if h1 then
      flush()  -- tolerate a missing blank line between cues
      cur = {
        start = tonumber(h1) * 3600 + tonumber(m1) * 60 + tonumber(s1)
                + tonumber(ms1) / 1000.0,
        stop  = tonumber(h2) * 3600 + tonumber(m2) * 60 + tonumber(s2)
                + tonumber(ms2) / 1000.0,
        parts = {},
      }
    elseif cur then
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed == "" then
        flush()  -- blank line ends the cue
      else
        cur.parts[#cur.parts + 1] = trimmed
      end
    end
    -- Lines outside a cue (index numbers, leading garbage) are ignored.
  end
  flush()

  table.sort(cues, function(a, b) return a.start < b.start end)
  return cues
end

-- ---------------------------------------------------------------------------
-- Fallback manifest: user picked a *_sync_timestamps.txt directly.
-- Derive the sibling file names from the app's naming conventions:
--   <base>_sync_timestamps.txt, <base>_sync_synced.srt, <base>.<audio ext>,
--   {Display}_({stem})_tts.wav, {Display}_({stem})_synced.wav (same folder).
-- ---------------------------------------------------------------------------

-- The app also accepts video input and copies the original container into
-- out_dir (its _VIDEO_EXTS list), so probe those too -- REAPER opens them
-- as media sources.
local AUDIO_EXTS = { ".wav", ".mp3", ".m4a", ".flac", ".ogg", ".aiff", ".aif",
                     ".mp4", ".mov", ".mkv", ".avi", ".webm", ".m4v",
                     ".mpg", ".mpeg" }
local TS_SUFFIX  = "_sync_timestamps.txt"

-- Find a file in dir whose (lowercased) name ends with suffix_lc. Prefer one
-- containing "(<stem>)" (the app's {Display}_({stem})_tts.wav convention);
-- otherwise accept a single unambiguous match.
local function find_file_by_suffix(dir, suffix_lc, stem)
  if dir == "" then return "" end
  -- REAPER caches EnumerateFiles listings per path for the whole session;
  -- flush with index -1 so files written since the last call are seen.
  reaper.EnumerateFiles(dir, -1)
  local matches = {}
  local i = 0
  while true do
    local fn = reaper.EnumerateFiles(dir, i)
    if not fn then break end
    if fn:lower():sub(-#suffix_lc) == suffix_lc then
      matches[#matches + 1] = fn
    end
    i = i + 1
  end
  if stem and stem ~= "" then
    local needle = "(" .. stem .. ")"
    for _, fn in ipairs(matches) do
      if fn:find(needle, 1, true) then return dir .. SEP .. fn end
    end
  end
  if #matches == 1 then return dir .. SEP .. matches[1] end
  return ""
end

local function manifest_from_timestamps(ts_path)
  local base
  if ends_with_ci(ts_path, TS_SUFFIX) then
    base = ts_path:sub(1, #ts_path - #TS_SUFFIX)
  else
    base = strip_ext(ts_path)
  end
  local dir  = dirname(ts_path)
  local stem = basename(base)

  local m = {
    status         = "ok",
    error          = "",
    out_dir        = dir,
    timestamps_txt = ts_path,
    en_audio       = "",
    tts_wav        = "",
    synced_wav     = "",
    synced_srt     = "",
    sync_texts     = "",
  }

  local srt = base .. "_sync_synced.srt"
  if file_exists(srt) then m.synced_srt = srt end
  local texts = base .. "_sync_texts.txt"
  if file_exists(texts) then m.sync_texts = texts end

  for _, ext in ipairs(AUDIO_EXTS) do
    if file_exists(base .. ext) then m.en_audio = base .. ext break end
  end

  m.tts_wav    = find_file_by_suffix(dir, "_tts.wav", stem)
  m.synced_wav = find_file_by_suffix(dir, "_synced.wav", stem)
  return m
end

-- ---------------------------------------------------------------------------
-- REAPER helpers
-- ---------------------------------------------------------------------------

local TRACK_EN     = "EN Original"
local TRACK_CHUNKS = "Dub Chunks"
local TRACK_REF    = "Dub Rendered (ref)"
-- v0.7: chunks the engine marked [unsync] go here. Same name and same
-- find-or-reuse behaviour as the Auto Sync tab's Un sync track, so both
-- tools park unplaceable material in one place.
local TRACK_UNSYNC = "Un sync"

-- v0.1 rule: never reuse an existing same-named track. A second import must
-- create a fresh set, so find the smallest suffix (" 2", " 3", ...) that is
-- free for ALL THREE names at once and return it ("" for the first import).
local function fresh_name_suffix()
  local existing = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if ok and nm then existing[nm] = true end
  end
  local n = 1
  while n < 1000 do
    local suffix = (n == 1) and "" or (" " .. n)
    if not (existing[TRACK_EN .. suffix]
            or existing[TRACK_CHUNKS .. suffix]
            or existing[TRACK_REF .. suffix]) then
      return suffix
    end
    n = n + 1
  end
  return " " .. tostring(os.time())  -- practically unreachable
end

-- Append a new named track at the end of the project.
local function append_named_track(name)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local tr = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  return tr
end

-- Find an existing track by exact name, else append one (the Auto Sync
-- pipeline's rule for its Un sync track — shared here on purpose).
local function find_or_append_track(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if ok and nm == name then return tr end
  end
  return append_named_track(name)
end

-- Create one item on `track` playing `path`. Same construction pattern as
-- the Audoi_Syncing_V2 reference: AddMediaItemToTrack + AddTakeToMediaItem +
-- a PCM source (here PCM_Source_CreateFromFile, one source per take) +
-- SetMediaItemTake_Source. `length` nil = use the full source length.
local function add_file_item(track, path, position, length, startoffs, take_name)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src)
  if not length then
    local src_len, is_qn = reaper.GetMediaSourceLength(src)
    if src_len and not is_qn then length = src_len end
  end
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", position or 0)
  if length and length > 0 then
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
  end
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", startoffs or 0)
  if take_name and take_name ~= "" then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", take_name, true)
  end
  return item
end

-- Contract matching rule for item notes: match cues to chunks by order when
-- counts are equal; otherwise by nearest cue start within 0.5 s; else empty.
local function note_for_chunk(cues, n_entries, i, synced_start)
  if #cues == 0 then return "" end
  if #cues == n_entries then return cues[i].text or "" end
  local best, best_d = nil, math.huge
  for _, c in ipairs(cues) do
    local d = math.abs(c.start - synced_start)
    if d < best_d then best, best_d = c, d end
  end
  if best and best_d <= 0.5 then return best.text or "" end
  return ""
end

-- ---------------------------------------------------------------------------
-- File picking + manifest loading
-- ---------------------------------------------------------------------------

local MANIFEST_KEYS = {
  "status", "error", "audio", "language", "out_dir",
  "en_audio", "en_srt", "tts_wav", "timestamps_txt",
  "synced_wav", "synced_srt", "sync_texts",
  "synced_count", "unsynced_count",
}

local function load_manifest_json(path)
  local text = read_all(path)
  if not text then return nil, "Could not read file:\n" .. path end
  if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
  local m = {}
  for _, k in ipairs(MANIFEST_KEYS) do
    local v = json_field(text, k)
    if type(v) == "string" then
      m[k] = v
    elseif v ~= nil then
      m[k] = tostring(v)
    else
      m[k] = ""
    end
  end
  if m.status == "" and m.timestamps_txt == "" and m.synced_srt == ""
     and m.en_audio == "" and m.synced_wav == "" then
    return nil, "This does not look like an engine_done.json manifest:\n" .. path
  end
  return m
end

-- Seed the file dialog with the engine's own status manifest when this
-- script lives in the contract layout (reaper/ next to engine/status/).
local function default_manifest_path()
  local _, script_path = reaper.get_action_context()
  local dir = dirname(script_path or "")
  if dir == "" then return "" end
  local candidate = dir .. SEP .. ".." .. SEP .. "engine" .. SEP .. "status"
                        .. SEP .. "engine_done.json"
  if file_exists(candidate) then return candidate end
  return ""
end

local function pick_manifest()
  local seed = default_manifest_path()
  local ok, picked = reaper.GetUserFileNameForRead(
    seed, "Select engine_done.json (Cancel to pick a timestamps .txt)", ".json")
  if not ok then
    ok, picked = reaper.GetUserFileNameForRead(
      "", "Select *_sync_timestamps.txt", ".txt")
    if not ok then return nil end
  end
  if ends_with_ci(picked, ".txt") then
    return manifest_from_timestamps(picked)
  end
  local m, err = load_manifest_json(picked)
  if not m then
    reaper.ShowMessageBox(err, "Import Dub Results", 0)
    return nil
  end
  return m
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local function main()
  local m = pick_manifest()
  if not m then return end

  if m.status == "error" then
    local msg = "The pipeline reported an ERROR:\n\n"
                .. (m.error ~= "" and m.error or "(no details)")
                .. "\n\nImport whatever partial results exist anyway?"
    if reaper.ShowMessageBox(msg, "Import Dub Results", 1) ~= 1 then return end
  end

  local skipped = {}
  local function skip(reason) skipped[#skipped + 1] = reason end

  -- Resolve inputs, skipping empty manifest fields and missing files.
  local en_audio = m.en_audio or ""
  if en_audio ~= "" and not file_exists(en_audio) then
    skip('en_audio: file not found ("' .. en_audio .. '")')
    en_audio = ""
  elseif en_audio == "" then
    skip("en_audio: empty in manifest")
  end

  local entries = {}
  local ts_path = m.timestamps_txt or ""
  if ts_path ~= "" and file_exists(ts_path) then
    entries = parse_timestamps_file(ts_path)
    if #entries == 0 then
      skip("timestamps_txt: no parsable lines -- Dub Chunks skipped")
    end
  elseif ts_path == "" then
    skip("timestamps_txt: empty in manifest -- Dub Chunks skipped")
  else
    skip('timestamps_txt: file not found ("' .. ts_path .. '")')
  end

  local tts_wav = m.tts_wav or ""
  if #entries > 0 then
    if tts_wav == "" then
      skip("tts_wav: empty in manifest -- Dub Chunks skipped")
      entries = {}
    elseif not file_exists(tts_wav) then
      skip('tts_wav: file not found ("' .. tts_wav .. '") -- Dub Chunks skipped')
      entries = {}
    end
  end

  local cues = {}
  local synced_srt = m.synced_srt or ""
  if synced_srt ~= "" and file_exists(synced_srt) then
    cues = parse_srt_file(synced_srt)
    if #cues == 0 then
      skip("synced_srt: no parsable cues -- no regions / item notes")
    end
  elseif synced_srt == "" then
    skip("synced_srt: empty in manifest -- no regions / item notes")
  else
    skip('synced_srt: file not found ("' .. synced_srt .. '")')
  end

  local synced_wav = m.synced_wav or ""
  if synced_wav ~= "" and not file_exists(synced_wav) then
    skip('synced_wav: file not found ("' .. synced_wav .. '")')
    synced_wav = ""
  elseif synced_wav == "" then
    skip("synced_wav: empty in manifest -- reference track skipped")
  end

  if en_audio == "" and #entries == 0 and synced_wav == "" and #cues == 0 then
    reaper.ShowMessageBox(
      "Nothing to import -- every manifest field was empty or missing:\n\n- "
      .. table.concat(skipped, "\n- "),
      "Import Dub Results", 0)
    return
  end

  -- Build everything inside one undo block.
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local suffix = fresh_name_suffix()
  local chunks_added, regions_added, notes_matched = 0, 0, 0

  -- 1. EN Original
  if en_audio ~= "" then
    local tr = append_named_track(TRACK_EN .. suffix)
    local it = add_file_item(tr, en_audio, 0, nil, 0, basename(en_audio))
    if not it then skip("en_audio: REAPER could not open the media file") end
  end

  -- 2. Dub Chunks (synced) + Un sync (v0.7 [unsync] entries)
  local unsync_added = 0
  if #entries > 0 then
    -- v0.7 texts sidecar: block N = note for timestamps index N (works for
    -- both tracks). Fallback: the old synced-SRT cue matching.
    local texts = {}
    if (m.sync_texts or "") ~= "" and file_exists(m.sync_texts) then
      texts = parse_texts_file(m.sync_texts)
    end
    local synced_entries, unsync_entries = {}, {}
    for _, e in ipairs(entries) do
      if e.unsync then unsync_entries[#unsync_entries + 1] = e
      else synced_entries[#synced_entries + 1] = e end
    end
    local function note_for(e, list_n, i)
      local t = texts[e.index or 0]
      if t and t ~= "" then return t end
      return note_for_chunk(cues, list_n, i, e.synced_start)
    end

    if #synced_entries > 0 then
      local tr = append_named_track(TRACK_CHUNKS .. suffix)
      for i, e in ipairs(synced_entries) do
        local it = add_file_item(tr, tts_wav, e.synced_start, e.dur,
                                 e.orig_start,
                                 string.format("chunk %02d", e.index or i))
        if it then
          chunks_added = chunks_added + 1
          local note = note_for(e, #synced_entries, i)
          if note ~= "" then
            reaper.GetSetMediaItemInfo_String(it, "P_NOTES", note, true)
            notes_matched = notes_matched + 1
          end
        end
      end
      if chunks_added == 0 then
        skip("tts_wav: REAPER could not open the media file -- no chunks placed")
      end
    end

    if #unsync_entries > 0 then
      local tr = find_or_append_track(TRACK_UNSYNC)
      for i, e in ipairs(unsync_entries) do
        local it = add_file_item(tr, tts_wav, e.synced_start, e.dur,
                                 e.orig_start,
                                 string.format("unsync %02d", e.index or i))
        if it then
          unsync_added = unsync_added + 1
          local note = note_for(e, #unsync_entries, i)
          if note ~= "" then
            reaper.GetSetMediaItemInfo_String(it, "P_NOTES", note, true)
          end
        end
      end
    end
  end

  -- 3. Dub Rendered (ref) -- muted reference track
  if synced_wav ~= "" then
    local tr = append_named_track(TRACK_REF .. suffix)
    reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1)
    local it = add_file_item(tr, synced_wav, 0, nil, 0, basename(synced_wav))
    if not it then skip("synced_wav: REAPER could not open the media file") end
  end

  -- Regions: one per synced-SRT cue. A re-import must not stack a second
  -- identical region per cue, so collect the existing regions first and skip
  -- cues whose start/stop/name already match (keys quantised to 1 ms, the
  -- SRT resolution, so float noise cannot defeat the match).
  local existing_regions = {}
  do
    local ri = 0
    while true do
      local retval, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers3(0, ri)
      if retval == 0 then break end
      if isrgn then
        existing_regions[string.format("%.3f|%.3f|%s", pos, rgnend, name or "")] = true
      end
      ri = ri + 1
    end
  end
  local regions_skipped = 0
  for _, c in ipairs(cues) do
    local key = string.format("%.3f|%.3f|%s", c.start, c.stop, c.text or "")
    if existing_regions[key] then
      regions_skipped = regions_skipped + 1
    else
      reaper.AddProjectMarker2(0, true, c.start, c.stop, c.text or "", -1, 0)
      existing_regions[key] = true
      regions_added = regions_added + 1
    end
  end
  if regions_skipped > 0 then
    skip("regions: " .. regions_skipped
         .. " identical region(s) already in project -- not re-added")
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Import dub results", -1)

  -- Summary
  local lines = {
    "Import finished" .. (suffix ~= "" and " (track set" .. suffix .. ")" or "") .. ".",
    "",
    "Dub chunks placed: " .. chunks_added,
    "Regions created:   " .. regions_added,
  }
  if unsync_added > 0 then
    lines[3] = "Synced chunks placed: " .. chunks_added
    lines[#lines + 1] = "Un sync chunks:    " .. unsync_added
                        .. '  (on the "' .. TRACK_UNSYNC .. '" track)'
  end
  if chunks_added > 0 then
    lines[#lines + 1] = "Item notes matched: " .. notes_matched
                        .. " of " .. chunks_added
  end
  if #skipped > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Skipped (" .. #skipped .. "):"
    for _, s in ipairs(skipped) do lines[#lines + 1] = "- " .. s end
  end
  reaper.ShowMessageBox(table.concat(lines, "\n"), "Import Dub Results", 0)
end

main()
