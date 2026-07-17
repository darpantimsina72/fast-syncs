#!/bin/bash
# Double-click to send feedback (message + screenshots) to the developer.
cd "$(dirname "$0")"
PY=".venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3 || command -v python)"
exec "$PY" app_feedback.py --gui --app "Fast Syncs"
