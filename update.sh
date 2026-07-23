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

ZIP_URL="https://codeload.github.com/darpantimsina72/fast-syncs/zip/refs/heads/main"

# ZIP installs (no .git): download the latest ZIP and overlay it onto this
# folder. Settings, venv and .direct-mode aren't in the ZIP, so they survive.
# Runs inside main() (fully parsed), so rewriting update.sh mid-run is safe.
zip_update() {
    echo "[update] Not a git checkout — downloading the latest version from GitHub…"
    local tmp="${TMPDIR:-/tmp}/fast-syncs-zip"
    rm -rf "$tmp" && mkdir -p "$tmp"
    if ! curl -fsSL -o "$tmp/repo.zip" "$ZIP_URL"; then
        echo "[update] Could not download the update (offline, or the GitHub"
        echo "         repository is private / moved). Update manually instead:"
        echo "         re-download the ZIP and unzip it OVER this folder"
        echo "         (your settings and venv are kept)."
        return 0
    fi
    if ! unzip -oq "$tmp/repo.zip" -d "$tmp"; then
        echo "[update] Could not unpack the update — update manually (re-download the ZIP)."
        return 0
    fi
    # The ZIP contains one folder (fast-syncs-<branch>); copy its contents here.
    local src
    src=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    if [ -z "$src" ]; then
        echo "[update] Unexpected ZIP layout — update manually (re-download the ZIP)."
        return 0
    fi
    cp -R "$src/." .
    echo "[update] Files updated to the latest version."
}

main() {
    cd "$(dirname "$0")"

    if [ -d .git ] && command -v git >/dev/null 2>&1; then
        echo "[update] Pulling latest changes…"
        # --ff-only aborts on a diverged / locally-modified checkout. Don't
        # let that fail the whole update (set -e) — fall back to the ZIP
        # overlay, which adds/overwrites tracked files without touching the
        # gitignored venv/settings. This is the common "update did nothing on
        # a git install" case.
        if ! git pull --ff-only; then
            echo "[update] git pull could not fast-forward (diverged or local"
            echo "         edits to tracked files) — falling back to ZIP overlay…"
            zip_update
        fi
    else
        zip_update
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

    # Bundled dubbing app (dubbing/): run its setup in automatic mode on
    # EVERY update — first update after the merge it creates dubbing/venv
    # and installs ffmpeg (this used to be a manual step people hit as
    # "venv not found" errors); later updates just refresh deps (fast).
    # Never fails the whole update.
    if [ -f dubbing/setup_mac.command ]; then
        echo "[update] Setting up / refreshing the dubbing app (first time can take a few minutes)…"
        bash dubbing/setup_mac.command --auto \
            || echo "[update] Dubbing setup reported a problem — run dubbing/setup_mac.command manually."
    fi

    echo
    echo "Update complete. Re-run the script in REAPER to use the new version."
}

main "$@"; exit $?
