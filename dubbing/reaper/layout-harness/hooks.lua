-- ══ appended to the panel source by the harness only ═══════════════════════
-- The phase renderers and the config state are chunk-level LOCALS with no V5
-- handle. Setting a same-named global from the harness is silently ignored, so
-- everything the tests drive has to be reached through a closure written HERE,
-- inside the chunk, where those locals are in scope.
_G.V5 = V5
_G.__H = {
  setup   = function(ctx) ui_phase_setup(ctx, function() end, function() end) end,
  running = function(ctx) ui_phase_setup(ctx, function() end, function() end, 252) end,
  review  = function(ctx) ui_phase_review(ctx) end,
  success = function(ctx) ui_phase_success(ctx, function() end) end,
  failure = function(ctx) ui_phase_failure(ctx, function() end) end,

  set_phase = function(p) _ui_phase = p end,
  get_phase = function() return _ui_phase end,
  set_stage = function(t) _ui_stage_tag = t end,
  set_prog  = function(p) _ui_progress = p end,
  set_review = function(r) _review = r end,
  -- The screens' buttons call chunk-level LOCALS. A typo there would resolve to
  -- a nil global and only fail the day someone presses that button, so the
  -- harness asserts the names resolve — the one error class luaparse cannot
  -- see, because a nil global is valid Lua right up to the call.
  callables = function()
    return {
      start_dub_run       = start_dub_run,
      cancel_engine       = cancel_engine,
      start_fetch_voices  = start_fetch_voices,
      save_review_text    = save_review_text,
      launch_dub_continue = launch_dub_continue,
      import_to_timeline   = import_to_timeline,
      review_collect_text = review_collect_text,
      open_path           = open_path,
      file_exists         = file_exists,
      save_settings       = save_settings,
      ui_set_banner       = ui_set_banner,
      CONFIG_DIR          = CONFIG_DIR,
    }
  end,

  set_manifest = function(m, imported)
    _manifest = m
    _imported = imported and true or false
  end,
  para_h    = function(en, tr) return _para_box_height(en, tr) end,
  banner    = function(k, t) ui_set_banner(k, t) end,

  -- v0.31 source region. The decision of WHAT to dub is a chunk-level local,
  -- and it is the one the credits are spent on.
  set_src_track    = function(i) _src_track_idx = i end,
  audio_for_region = function(plan) return audio_for_region(plan) end,

  set_cfg = function(t)
    if t.SCRIPT_MODE     ~= nil then SCRIPT_MODE     = t.SCRIPT_MODE end
    if t.FULL_RUN        ~= nil then FULL_RUN        = t.FULL_RUN end
    if t.LAST_AUDIO      ~= nil then LAST_AUDIO      = t.LAST_AUDIO end
    if t.LANGUAGE        ~= nil then LANGUAGE        = t.LANGUAGE end
    if t.LLM_MODEL       ~= nil then LLM_MODEL       = t.LLM_MODEL end
    if t.LLM_PROVIDER    ~= nil then LLM_PROVIDER    = t.LLM_PROVIDER end
    if t.LLM_GEMINI_KEY  ~= nil then LLM_GEMINI_KEY  = t.LLM_GEMINI_KEY end
    if t.LLM_OPENAI_KEY  ~= nil then LLM_OPENAI_KEY  = t.LLM_OPENAI_KEY end
    if t.LLM_OPENAI_URL  ~= nil then LLM_OPENAI_URL  = t.LLM_OPENAI_URL end
    if t.LLM_SERVER_URL  ~= nil then LLM_SERVER_URL  = t.LLM_SERVER_URL end
    if t.EL_KEY          ~= nil then EL_KEY          = t.EL_KEY end
    if t.EL_MODEL        ~= nil then EL_MODEL        = t.EL_MODEL end
    if t.VOICE_ID        ~= nil then VOICE_ID        = t.VOICE_ID end
    if t.GOOGLE_TTS_KEY_PATH ~= nil then GOOGLE_TTS_KEY_PATH = t.GOOGLE_TTS_KEY_PATH end
    if t._provided_text  ~= nil then _provided_text  = t._provided_text end
  end,

  read_cfg = function()
    return { SCRIPT_MODE = SCRIPT_MODE, FULL_RUN = FULL_RUN,
             LAST_AUDIO = LAST_AUDIO, LANGUAGE = LANGUAGE,
             LLM_MODEL = LLM_MODEL, LLM_PROVIDER = LLM_PROVIDER,
             EL_KEY = EL_KEY, EL_MODEL = EL_MODEL, VOICE_ID = VOICE_ID,
             _provided_text = _provided_text }
  end,
}

-- A mistyped V5.COL role must raise during the draw, not pass nil to
-- PushStyleColor and vanish.
setmetatable(V5.COL, { __index = function(_, k)
  error('unknown V5.COL key: ' .. tostring(k), 2)
end })

return V5
