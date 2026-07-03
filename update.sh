#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# fast-syncs update script — pulls the latest version from
# GitHub and re-installs Python dependencies.
#
# Run this whenever you want to grab the newest features.
#
# The whole body lives in main(): bash reads scripts from disk as it
# executes them, so `git pull` rewriting THIS file mid-run could
# otherwise derail the remaining lines. A fully-parsed function (plus
# `exit` on the same line as the call) makes the run immune to that.
# ──────────────────────────────────────────────────────────────
set -e

main() {
    cd "$(dirname "$0")"

    echo "[update] Pulling latest changes…"
    if [ -d .git ] && command -v git >/dev/null 2>&1; then
        git pull --ff-only
    else
        echo "[update] Not a git checkout — skipping pull. Re-download the ZIP to update."
    fi

    if [ -d venv ]; then
        # Migrate installs made before the .direct-mode marker existed: if the
        # direct-mode libs are importable, this venv was set up with --direct.
        if [ ! -f .direct-mode ] && ./venv/bin/python3 -c "import google.genai" >/dev/null 2>&1; then
            touch .direct-mode
        fi
        echo "[update] Updating Python dependencies…"
        ./venv/bin/pip install --quiet --upgrade -r requirements.txt
        if [ -f .direct-mode ]; then
            echo "[update] Updating direct-mode dependencies…"
            ./venv/bin/pip install --quiet --upgrade -r requirements-direct.txt
        fi
    else
        echo "[update] No venv found — running setup.sh first."
        if [ -f .direct-mode ]; then bash setup.sh --direct; else bash setup.sh; fi
    fi

    echo
    echo "Update complete."
}

main "$@"; exit $?
