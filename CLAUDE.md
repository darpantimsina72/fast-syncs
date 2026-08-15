# CLAUDE.md

@AGENTS.md

Everything an agent needs is in `AGENTS.md`. Keep it as the single source of
truth — add new guidance there, not here.

Task-specific detail lives in `.claude/skills/`, which Claude Code loads on
demand:

- `reascript-lua` — REAPER Lua API traps, ReaImGui version safety, defer loops
- `lua-python-ipc` — the file + environment contract between the Lua and Python halves
- `cross-platform-installers` — the six setup/update scripts, Python discovery, cmd.exe traps
- `release-and-versioning` — VERSION bumps, file-format compatibility, how updates reach users
