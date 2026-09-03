'use strict';
// The Sync tab is a separate chunk that the dub panel dofile()s into its Sync
// tab. Its chunk RETURNS the module from inside `if EMBED then`, so hooks
// appended at the end of the file never execute — they have to be spliced in
// just before that line.
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const HERE = __dirname;
const SYNC = process.env.SYNC ||
  path.join(HERE, '..', '..', '..', 'auto_sync_pipeline.lua');
const read = p => fs.readFileSync(p, 'utf8');

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function run(src, name) {
  let st = lauxlib.luaL_loadbuffer(L, to_luastring(src), null, to_luastring('@' + name));
  if (st !== lua.LUA_OK) {
    console.error('LOAD ERROR ' + name + ': ' + to_jsstring(lua.lua_tostring(L, -1)));
    process.exit(1);
  }
  st = lua.lua_pcall(L, 0, 0, 0);
  if (st !== lua.LUA_OK) {
    console.error('RUN ERROR ' + name + ': ' + to_jsstring(lua.lua_tostring(L, -1)));
    process.exit(1);
  }
}

run(read(path.join(HERE, 'mock.lua')), 'mock.lua');
run('__FASTSYNC_EMBED = true', 'embed-flag');

let src = read(SYNC);
const at = src.lastIndexOf('if EMBED then');
if (at < 0) { console.error('could not find the EMBED export block'); process.exit(1); }
const hooks = `
-- spliced in by the harness, INSIDE the chunk, before the EMBED export
_G.__S = {
  setup  = function(ctx) ui_phase_setup(ctx, function() end, function() end) end,
  phase  = function(p) _ui_phase = p end,
  render = function(ctx) render_active_phase(ctx, function() end, 0) end,
}
`;
src = src.slice(0, at) + hooks + src.slice(at);
run(src, 'auto_sync_pipeline.lua');

run(read(path.join(HERE, 'tests-sync.lua')), 'tests-sync.lua');
