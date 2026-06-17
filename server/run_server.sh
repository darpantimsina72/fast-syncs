#!/usr/bin/env bash
# Start the Sync Matcher API proxy locally for testing.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d venv ]; then
  python3 -m venv venv
  ./venv/bin/pip install --upgrade pip
  ./venv/bin/pip install -r requirements.txt
fi

if [ -f .env ]; then
  set -a; source .env; set +a
else
  echo "WARNING: no .env found — copy .env.example to .env and fill in keys."
fi

exec ./venv/bin/uvicorn main:app --host 0.0.0.0 --port "${PORT:-8000}" --reload
