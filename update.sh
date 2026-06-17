#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# fast-syncs update script — pulls the latest version from
# GitHub and re-installs Python dependencies.
#
# Run this whenever you want to grab the newest features.
# ──────────────────────────────────────────────────────────────
set -e
cd "$(dirname "$0")"

echo "[update] Pulling latest changes…"
if [ -d .git ] && command -v git >/dev/null 2>&1; then
    git pull --ff-only
else
    echo "[update] Not a git checkout — skipping pull. Re-download the ZIP to update."
fi

if [ -d venv ]; then
    echo "[update] Updating Python dependencies…"
    ./venv/bin/pip install --quiet --upgrade -r requirements.txt
else
    echo "[update] No venv found — running setup.sh first."
    bash setup.sh
fi

echo
echo "Update complete."
