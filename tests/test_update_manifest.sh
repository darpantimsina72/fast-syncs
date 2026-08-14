#!/usr/bin/env bash
# Tests for the manifest-driven cleanup in update.sh.
#
# This is the only code in the project that DELETES files on a user's machine,
# so it gets a real test rather than a careful reading. Run it from anywhere:
#
#     bash tests/test_update_manifest.sh
#
# It sources update.sh with FAST_SYNCS_LIB=1, which loads the helpers without
# running an update, then drives manifest_prune() against throwaway directories.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FAST_SYNCS_LIB=1 . "$REPO/update.sh"

pass=0; fail=0
ok()   { if [ "$1" = "1" ]; then pass=$((pass+1)); printf '    ok   %s\n' "$2"
         else fail=$((fail+1)); printf '    FAIL %s\n' "$2"; fi; }
gone() { [ ! -e "$1" ] && ok 1 "$2" || ok 0 "$2 (still present)"; }
kept() { [ -e "$1" ]   && ok 1 "$2" || ok 0 "$2 (was deleted!)"; }

newcase() {
    printf '\n== %s ==\n' "$1"
    ROOT="$(mktemp -d)"; cd "$ROOT" || exit 1
}

# Build an install tree plus the "unpacked new release" the updater compares to.
seed() {
    mkdir -p keep dropped dubbing/engine venv/bin dubbing/venv dubbing/config \
             dubbing/engine/status src/new
    echo x > keep/stays.py
    echo x > dropped/gone.py
    echo x > dubbing/engine/old_module.py
    echo x > settings_here.json
    echo x > venv/bin/python
    echo x > dubbing/venv/marker
    echo x > dubbing/config/llm_settings.json
    echo x > my_song.RPP
    echo x > take.wav
    # previous manifest: what the last release shipped
    cat > prev <<'EOF'
keep/stays.py
dropped/gone.py
dubbing/engine/old_module.py
EOF
    # new release tree + its manifest: old_module and dropped/gone are gone
    mkdir -p src/new/keep
    echo x > src/new/keep/stays.py
    echo x > src/new/brand_new.py
    cat > "$MANIFEST" <<'EOF'
keep/stays.py
brand_new.py
EOF
    cp "$MANIFEST" src/new/"$MANIFEST"
}

# ---------------------------------------------------------------------------
newcase "a normal upgrade removes what the release dropped"
seed
manifest_prune "$MANIFEST" prev src/new >/dev/null
gone dropped/gone.py            "file dropped upstream is deleted"
gone dubbing/engine/old_module.py "nested dropped file is deleted"
gone dropped                    "emptied directory is pruned"
kept keep/stays.py              "file still shipped is kept"
kept venv/bin/python            "venv/ untouched"
kept dubbing/venv/marker        "dubbing/venv/ untouched"
kept dubbing/config/llm_settings.json "dubbing/config/ untouched"
kept settings_here.json         "unlisted user file untouched"
kept my_song.RPP                "user .RPP untouched"
kept take.wav                   "user audio untouched"

# ---------------------------------------------------------------------------
newcase "hostile manifest paths are refused, not normalised"
seed
mkdir -p ../victim_dir && echo x > ../victim_sibling.txt
cat > prev <<'EOF'
../victim_sibling.txt
/etc/passwd
C:\Windows\System32\drivers\etc\hosts
./keep/stays.py
~/.ssh/id_rsa
dropped/gone.py
EOF
manifest_prune "$MANIFEST" prev src/new >/dev/null
kept ../victim_sibling.txt      "parent-traversal path refused"
kept keep/stays.py              "non-canonical ./ path refused"
gone dropped/gone.py            "the one legitimate stale file still went"

# ---------------------------------------------------------------------------
newcase "no previous manifest deletes nothing"
seed
rm -f prev
manifest_prune "$MANIFEST" prev src/new >/dev/null
kept dropped/gone.py            "nothing deleted without a previous list"
kept dubbing/engine/old_module.py "nothing deleted without a previous list (2)"

# ---------------------------------------------------------------------------
newcase "a file still present in the new release tree is never deleted"
seed
# Manifest claims it is gone, but the release actually still ships it.
printf 'keep/stays.py\n' > "$MANIFEST"
cp "$MANIFEST" src/new/"$MANIFEST"
mkdir -p src/new/dropped && echo x > src/new/dropped/gone.py
manifest_prune "$MANIFEST" prev src/new >/dev/null
kept dropped/gone.py            "release tree overrules a stale manifest"

# ---------------------------------------------------------------------------
newcase "CRLF line endings do not make every path look obsolete"
seed
printf 'keep/stays.py\r\ndropped/gone.py\r\ndubbing/engine/old_module.py\r\n' > prev
manifest_prune "$MANIFEST" prev src/new >/dev/null
kept keep/stays.py              "CR-terminated path still matches the new list"
gone dropped/gone.py            "genuinely obsolete path still removed"

# ---------------------------------------------------------------------------
newcase "running twice is idempotent"
seed
manifest_prune "$MANIFEST" prev src/new >/dev/null
manifest_prune "$MANIFEST" prev src/new >/dev/null
kept keep/stays.py              "second run changes nothing"
ok 1 "second run did not error"

printf '\n%s\n' "──────────────────────────────────────────"
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo "UPDATE MANIFEST OK" || echo "UPDATE MANIFEST FAILED"
exit $((fail > 0))
