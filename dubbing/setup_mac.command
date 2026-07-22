#!/bin/bash
# Reaper Dubbing App — one-time macOS setup (v0.3, standalone).
#
# Double-click this file, or run:  bash setup_mac.command
# (If double-click is blocked on a new Mac, see README "First run on a new Mac".)
#
# What it does — safe to re-run at any time:
#   1. Creates a local ./venv with the newest python3 it can find
#      (Homebrew locations first) and installs requirements.txt into it.
#   2. Runs the engine self-check (imports the pipeline modules).
#   3. OPTIONAL: if the legacy bulk-app install is present, offers to COPY
#      its API keys/settings into ./config (originals are never modified).
#   4. Prints the REAPER script-install steps.
set -u

cd "$(dirname "$0")" || exit 1
HERE="$(pwd)"
VENV="$HERE/venv"
CONFIG="$HERE/config"

# Legacy bulk-app install — only ever READ, and only for the optional
# one-time key migration below.
BULK_APP_DIR="/Users/ilp/Documents/Claude code/Akash anna Translation and Syncing App_All"

echo "== Reaper Dubbing App setup =="
echo "Project dir : $HERE"
echo

# ---------------------------------------------------------------------------
# 1. Find the newest python3 (Homebrew paths first, then system locations)
# ---------------------------------------------------------------------------

find_python() {
  local candidates=()
  # Versioned Homebrew interpreters first (newest wins), then the generic
  # symlinks, then framework/system installs.
  local d v
  for d in /opt/homebrew/bin /usr/local/bin; do
    for v in 3.14 3.13 3.12 3.11; do
      candidates+=("$d/python$v")
    done
    candidates+=("$d/python3")
  done
  candidates+=("/Library/Frameworks/Python.framework/Versions/Current/bin/python3")
  candidates+=("/usr/bin/python3")

  local best="" best_ver=0 c ver
  for c in "${candidates[@]}"; do
    [ -x "$c" ] || continue
    # /usr/bin/python3 without the Command Line Tools is Apple's GUI stub —
    # verify the interpreter actually runs before trusting it.
    ver="$("$c" -c 'import sys; print(sys.version_info[0]*1000 + sys.version_info[1])' 2>/dev/null)" || continue
    case "$ver" in (''|*[!0-9]*) continue ;; esac
    [ "$ver" -ge 3011 ] || continue          # need Python 3.11+
    if [ "$ver" -gt "$best_ver" ]; then
      best="$c"; best_ver="$ver"
    fi
  done
  [ -n "$best" ] && printf '%s\n' "$best"
}

PY_BASE="$(find_python)"
if [ -z "${PY_BASE:-}" ]; then
  echo "ERROR: no Python 3.11+ interpreter found."
  echo
  echo "Install one first (Homebrew recommended):"
  echo "  brew install python"
  echo "then re-run this script."
  exit 1
fi
echo "Python      : $PY_BASE  ($("$PY_BASE" -c 'import sys;print(sys.version.split()[0])'))"

# ---------------------------------------------------------------------------
# 2. Create ./venv (reused when it already works) + install requirements
# ---------------------------------------------------------------------------

VENV_PY="$VENV/bin/python3"
if [ -x "$VENV_PY" ] && "$VENV_PY" -c 'import sys' >/dev/null 2>&1; then
  echo "venv        : $VENV (already exists — reusing)"
else
  echo "venv        : creating $VENV ..."
  "$PY_BASE" -m venv "$VENV" || { echo "ERROR: could not create the venv."; exit 1; }
fi

if [ ! -f "$HERE/requirements.txt" ]; then
  echo "ERROR: requirements.txt not found next to this script."
  exit 1
fi

echo
echo "Installing engine dependencies (idempotent — re-runs are fast) ..."
"$VENV_PY" -m pip install --upgrade pip --quiet
"$VENV_PY" -m pip install -r "$HERE/requirements.txt" || {
  echo "ERROR: pip install failed. Check your network and re-run."
  exit 1
}

# ---------------------------------------------------------------------------
# 3. Engine self-check (imports the pipeline modules, verifies prompts)
# ---------------------------------------------------------------------------

echo
echo "Running engine self-check ..."
if "$VENV_PY" "$HERE/engine/dub_engine.py" --selfcheck; then
  echo "Self-check passed."
else
  echo "WARNING: engine self-check failed (see messages above)."
  echo "Setup continues — fix the reported issue, then re-run this script."
fi

# ---------------------------------------------------------------------------
# 4. Optional one-time key migration from the legacy bulk-app install.
#    COPY only — the bulk app's files are never moved or modified.
# ---------------------------------------------------------------------------

# ask "question" -> returns 0 on yes. Defaults to No; non-interactive = No.
ask() {
  local reply
  if [ -t 0 ]; then
    read -r -p "$1 [y/N] " reply
  else
    reply="n"
  fi
  case "$reply" in ([yY]|[yY][eE][sS]) return 0 ;; esac
  return 1
}

# copy_if_confirmed <src> <dest> — skips missing sources; asks before
# overwriting an existing destination.
copy_if_confirmed() {
  local src="$1" dest="$2"
  [ -f "$src" ] || { echo "  - skip (not found): $src"; return; }
  if [ -e "$dest" ]; then
    if ask "  - $(basename "$dest") already exists in config/ — overwrite?"; then
      cp "$src" "$dest" && echo "  - copied: $(basename "$src") -> config/"
    else
      echo "  - kept existing: $dest"
    fi
  else
    cp "$src" "$dest" && echo "  - copied: $(basename "$src") -> config/"
  fi
}

if [ -d "$BULK_APP_DIR" ]; then
  echo
  echo "Legacy bulk-app install found at:"
  echo "  $BULK_APP_DIR"
  if ask "Copy its API keys/settings into this project's config/ (one-time)?"; then
    mkdir -p "$CONFIG"

    # llm_settings.json + key files: straight copies.
    copy_if_confirmed "$BULK_APP_DIR/llm_settings.json" "$CONFIG/llm_settings.json"
    copy_if_confirmed "$BULK_APP_DIR/vertex_key.json"   "$CONFIG/vertex_key.json"
    copy_if_confirmed "$BULK_APP_DIR/TTS_Key.json"      "$CONFIG/TTS_Key.json"

    # api.txt (ElevenLabs key) + el_model.txt -> config/tts_settings.json.
    if [ -e "$CONFIG/tts_settings.json" ] \
       && ! ask "  - tts_settings.json already exists in config/ — overwrite?"; then
      echo "  - kept existing: $CONFIG/tts_settings.json"
    else
      "$VENV_PY" - "$BULK_APP_DIR" "$CONFIG" <<'EOF'
import json, os, sys
bulk, config = sys.argv[1], sys.argv[2]

def read_txt(name):
    p = os.path.join(bulk, name)
    try:
        with open(p, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""

key      = read_txt("api.txt")
el_model = read_txt("el_model.txt")
tts_key  = os.path.join(config, "TTS_Key.json")
data = {
    "elevenlabs_api_key":  key,
    "el_model":            el_model or "eleven_v3",
    "voice_id":            "",
    "google_tts_key_path": tts_key if os.path.exists(tts_key) else "",
}
out = os.path.join(config, "tts_settings.json")
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print("  - wrote: config/tts_settings.json"
      + ("" if key else "  (no api.txt found — key left empty)"))
EOF
    fi
    echo "  Migration done. Originals in the bulk app were not touched."
  else
    echo "  Skipped. Enter your keys in the panel's Settings section instead."
  fi
else
  echo
  echo "No legacy bulk-app install found — enter your API keys in the"
  echo "panel's Settings section on first run (stored in ./config, gitignored)."
fi

# ---------------------------------------------------------------------------
# 5. REAPER script-install steps
# ---------------------------------------------------------------------------

echo
echo "== Setup complete =="
echo
echo "Install the REAPER scripts (load them IN PLACE — do not copy them):"
echo "  1. In REAPER: Actions -> Show action list -> New action -> Load ReaScript..."
echo "  2. Pick both files from:  $HERE/reaper/"
echo "     (Dub_Pipeline_Panel.lua and Import_Dub_Results.lua)."
echo "  NOTE: do NOT copy the .lua files into REAPER's Scripts/ folder."
echo "  The panel finds the engine relative to its own location, so it only"
echo "  works from  $HERE/reaper/  (next to the engine/ folder)."
echo
echo "Recommended: install ReaImGui via ReaPack (Extensions -> ReaPack ->"
echo "Browse packages -> search 'ReaImGui') for the panel UI."
echo "Import_Dub_Results.lua works even without ReaImGui."
