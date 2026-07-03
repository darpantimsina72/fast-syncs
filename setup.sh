#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# fast-syncs setup (macOS / Linux) — creates a Python virtualenv
# and installs dependencies for sync_matcher.py.
#
#   bash setup.sh            → thin client (server/proxy mode). Tiny install.
#   bash setup.sh --direct   → also install direct-mode libs (google-genai,
#                              soundfile) for running WITHOUT a server.
#
# Run once. To update later, run update.sh.
# ──────────────────────────────────────────────────────────────
set -e
cd "$(dirname "$0")"

DIRECT=0
for arg in "$@"; do
  case "$arg" in
    --direct) DIRECT=1 ;;
  esac
done

# Pick a Python that has working pip — prefer 3.13 (stable on macOS) over 3.14.
PYTHON_BIN=""
for candidate in \
    /opt/homebrew/Cellar/python@3.13/*/bin/python3.13 \
    /opt/homebrew/bin/python3.13 \
    /usr/local/bin/python3.13 \
    /opt/homebrew/Cellar/python@3.12/*/bin/python3.12 \
    /opt/homebrew/bin/python3.12 \
    /usr/local/bin/python3.12 \
    /opt/homebrew/bin/python3.11 \
    /usr/local/bin/python3.11 \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 \
    /usr/bin/python3
do
    if [ -x "$candidate" ]; then
        # Verify pip works (Python 3.14 has a known expat issue that breaks pip).
        if "$candidate" -m pip --version >/dev/null 2>&1; then
            PYTHON_BIN="$candidate"
            break
        fi
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo "ERROR: No usable Python 3 (3.9+, 3.11+ recommended) with working pip was found."
    echo "Install Python with:  brew install python@3.13"
    exit 1
fi

echo "[setup] Using Python: $PYTHON_BIN"
echo "[setup] Creating virtualenv in ./venv ..."
"$PYTHON_BIN" -m venv venv

echo "[setup] Installing thin-client dependencies ..."
./venv/bin/pip install --quiet --upgrade pip
./venv/bin/pip install --quiet -r requirements.txt

if [ "$DIRECT" = "1" ]; then
    echo "[setup] Installing direct-mode dependencies (google-genai, soundfile) ..."
    ./venv/bin/pip install --quiet -r requirements-direct.txt
fi

echo
echo "[setup] Verifying ..."
if [ "$DIRECT" = "1" ]; then
    ./venv/bin/python3 -c "from google import genai; import soundfile; print('OK (direct mode)')"
else
    # Thin client runs on the stdlib; just confirm the script imports cleanly.
    ./venv/bin/python3 -c "import ssl, wave, urllib.request; print('OK (thin client)')"
fi

# Remember the install mode, so update.sh (and the Lua bootstrapper) keep
# direct-mode installs direct across updates and venv rebuilds.
if [ "$DIRECT" = "1" ]; then touch .direct-mode; else rm -f .direct-mode; fi

echo
echo "Setup complete. You can now run auto_sync_pipeline.lua in Reaper."
