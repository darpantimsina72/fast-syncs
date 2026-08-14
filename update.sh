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

# The newest RELEASE, not the tip of main. This URL is stable: GitHub always
# redirects it to the fast-syncs.zip asset of the latest published release
# (see .github/workflows/release.yml), so users move between versions that
# were deliberately shipped rather than whatever was committed last.
#
# To install a specific older version instead, download its fast-syncs.zip
# from https://github.com/darpantimsina72/fast-syncs/releases and unzip it
# over this folder — settings and venv are preserved either way.
ZIP_URL="https://github.com/darpantimsina72/fast-syncs/releases/latest/download/fast-syncs.zip"

# Set FAST_SYNCS_ZIP_URL to override (e.g. to pin an older release):
#   FAST_SYNCS_ZIP_URL=https://github.com/.../download/v0.12.0/fast-syncs.zip bash update.sh
ZIP_URL="${FAST_SYNCS_ZIP_URL:-$ZIP_URL}"

# Fallback for the window BEFORE the first release exists: the releases/latest
# URL 404s until something has actually been published, and an updater that
# stops working the moment this lands would be worse than the problem it fixes.
# Tried only if the release download fails, so a normal update never touches it.
FALLBACK_ZIP_URL="https://codeload.github.com/darpantimsina72/fast-syncs/zip/refs/heads/main"

# Set when the new files could NOT be fetched, so the final message never
# claims an update that did not happen.
NO_DL=0

# ZIP installs (no .git): download the latest ZIP and overlay it onto this
# folder. Settings, venv and .direct-mode aren't in the ZIP, so they survive.
# Runs inside main() (fully parsed), so rewriting update.sh mid-run is safe.
zip_update() {
    echo "[update] Downloading the latest version from GitHub…"
    local tmp="${TMPDIR:-/tmp}/fast-syncs-zip"
    rm -rf "$tmp" && mkdir -p "$tmp"
    if ! curl -fsSL -o "$tmp/repo.zip" "$ZIP_URL"; then
        # No release published yet (releases/latest 404s), or this machine
        # cannot reach it. Fall back to the branch ZIP so the button keeps
        # working; once the first release exists this branch is never taken.
        if [ -n "${FAST_SYNCS_ZIP_URL:-}" ] \
           || ! curl -fsSL -o "$tmp/repo.zip" "$FALLBACK_ZIP_URL"; then
            echo "[update] Could not download the update (offline, or the GitHub"
            echo "         repository is private / moved). Update manually instead:"
            echo "         re-download the ZIP and unzip it OVER this folder"
            echo "         (your settings and venv are kept)."
            NO_DL=1
            return 0
        fi
        echo "[update] No published release yet — used the latest code instead."
    fi
    if ! unzip -oq "$tmp/repo.zip" -d "$tmp"; then
        echo "[update] Could not unpack the update — update manually (re-download the ZIP)."
        NO_DL=1
        return 0
    fi
    # The ZIP contains one folder (fast-syncs-<branch>); copy its contents here.
    local src
    src=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    if [ -z "$src" ]; then
        echo "[update] Unexpected ZIP layout — update manually (re-download the ZIP)."
        NO_DL=1
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

    # A venv whose base Python was uninstalled or upgraded (a Homebrew
    # upgrade breaks the symlinks) still exists on disk but cannot run.
    # Probe by executing; a broken venv is deleted and rebuilt through
    # setup.sh (this used to abort the whole update at the pip step).
    if [ -d venv ] && ! ./venv/bin/python3 -c 'import sys' >/dev/null 2>&1; then
        echo "[update] The venv is broken (its Python was removed or upgraded) — rebuilding…"
        rm -rf venv
    fi

    # setup.sh sets up the dubbing app itself, so the dubbing step below
    # can be skipped when it ran.
    SETUP_RAN=0
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
        echo "[update] No working venv — running setup.sh first."
        SETUP_RAN=1
        if [ -f .direct-mode ]; then bash setup.sh --direct; else bash setup.sh; fi
    fi

    # Bundled dubbing app (dubbing/): run its setup in automatic mode on
    # EVERY update — first update after the merge it creates dubbing/venv
    # and installs ffmpeg (this used to be a manual step people hit as
    # "venv not found" errors); later updates just refresh deps (fast).
    # Never fails the whole update. Skipped when setup.sh just ran — it
    # already did this itself.
    if [ "$SETUP_RAN" = "0" ] && [ -f dubbing/setup_mac.command ]; then
        echo "[update] Setting up / refreshing the dubbing app (first time can take a few minutes)…"
        bash dubbing/setup_mac.command --auto \
            || echo "[update] Dubbing setup reported a problem — run dubbing/setup_mac.command manually."
    fi

    echo
    if [ "$NO_DL" = "1" ]; then
        echo "Update finished, but the new version could NOT be downloaded —"
        echo "see the messages above. Your current version keeps working."
    else
        echo "Update complete. Re-run the script in REAPER to use the new version."
    fi
}

main "$@"; exit $?
