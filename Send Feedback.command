#!/bin/bash
# Double-click to send feedback (message + screenshots) to the developer.
cd "$(dirname "$0")"
PY="venv/bin/python3"
[ -x "$PY" ] || PY=".venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3 || command -v python)"
if [ -z "$PY" ]; then
  echo "Could not find Python. Run setup.sh first, then try again."
  read -r -p "Press Return to close." _
  exit 1
fi
exec "$PY" app_feedback.py --gui --app "Fast Syncs"
