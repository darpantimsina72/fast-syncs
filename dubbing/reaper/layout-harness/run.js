'use strict';
// Load mock.lua, the panel (with hooks spliced in), then tests.lua — under
// fengari, so the panel's draw code actually executes without REAPER.
const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const HERE = __dirname;
const PANEL = process.env.PANEL ||
  path.join(HERE, '..', 'Dub_Pipeline_Panel.lua');

function read(p) { return fs.readFileSync(p, 'utf8'); }

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function run(src, name) {
  const st = lauxlib.luaL_loadbuffer(L, to_luastring(src), null, to_luastring('@' + name));
  if (st !== lua.LUA_OK) {
    console.error('LOAD ERROR in ' + name + ': ' + to_jsstring(lua.lua_tostring(L, -1)));
    process.exit(1);
  }
  const rs = lua.lua_pcall(L, 0, 0, 0);
  if (rs !== lua.LUA_OK) {
    console.error('RUN ERROR in ' + name + ': ' + to_jsstring(lua.lua_tostring(L, -1)));
    process.exit(1);
  }
}

// 1. the mock reaper + layout model
run(read(path.join(HERE, 'mock.lua')), 'mock.lua');

// 2. the panel, with the harness hooks appended INSIDE the chunk so they can
//    close over its file-level locals. `reaper.defer(main)` is the last line
//    and defer is a no-op, so main() never runs.
const panelSrc = read(PANEL) + '\n' + read(path.join(HERE, 'hooks.lua')) + '\n';
run(panelSrc, 'Dub_Pipeline_Panel.lua');

// 2b. optional pre-test globals
if (process.env.WIDE) run(read(path.join(HERE, 'wide.lua')), 'wide.lua');

// 3. the tests
run(read(path.join(HERE, process.env.TESTS || 'tests.lua')), 'tests');
