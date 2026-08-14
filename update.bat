@echo off
rem ──────────────────────────────────────────────────────────────
rem  fast-syncs update (Windows) — pulls the latest version and
rem  re-installs Python dependencies.
rem
rem  Works for BOTH install styles:
rem    - git clone      → git pull
rem    - ZIP download   → downloads the latest ZIP from GitHub and
rem                       copies it over this folder (settings, venv
rem                       and .direct-mode are untouched).
rem
rem  cmd.exe reads batch files from disk line-by-line WHILE they run,
rem  so an update rewriting this very file mid-run would derail it.
rem  Guard: re-launch from a copy in %TEMP% and do the real work there.
rem ──────────────────────────────────────────────────────────────
if "%~1"=="--from-temp" goto run
copy /y "%~f0" "%TEMP%\fast-syncs-update.bat" >nul
if errorlevel 1 (
  rem No %TEMP% in this echo: a TEMP containing ")" would break this block.
  echo ERROR: could not copy the updater to the temp folder.
  pause
  exit /b 1
)
rem Pass the project dir with a trailing "." (not a bare "%~dp0", which ends
rem in a backslash — "C:\path\" can confuse quote parsing). "C:\path\." is
rem unambiguous and cd resolves it to the folder.
"%TEMP%\fast-syncs-update.bat" --from-temp "%~dp0."
exit /b

:run
setlocal
cd /d "%~2"
rem The install folder, absolute and without a trailing backslash. Used by the
rem cleanup below as the one boundary it must never cross.
set "ROOTDIR=%CD%"

rem The newest RELEASE, not the tip of main. This URL is stable: GitHub always
rem redirects it to the fast-syncs.zip asset of the latest published release
rem (see .github\workflows\release.yml), so users move between versions that
rem were deliberately shipped rather than whatever was committed last.
rem
rem To install a specific older version instead, download its fast-syncs.zip
rem from https://github.com/darpantimsina72/fast-syncs/releases and unzip it
rem over this folder - settings and venv are preserved either way.
set "ZIP_URL=https://github.com/darpantimsina72/fast-syncs/releases/latest/download/fast-syncs.zip"
rem Set FAST_SYNCS_ZIP_URL beforehand to override (e.g. to pin an older release).
if defined FAST_SYNCS_ZIP_URL set "ZIP_URL=%FAST_SYNCS_ZIP_URL%"
rem Used only if the release download fails - see :zip_update below.
set "FALLBACK_ZIP_URL=https://codeload.github.com/darpantimsina72/fast-syncs/zip/refs/heads/main"
rem NO_DL is set when the new files could NOT be fetched, so the final
rem message never claims an update that did not happen.
set "NO_DL="
rem SETUP_RAN is set when setup.bat ran (it already sets up the dubbing
rem app itself, so the dubbing step below can be skipped).
set "SETUP_RAN="

rem ── the file manifest ─────────────────────────────────────────
rem Every release ships a .fast-syncs-manifest in its root: one repo-relative
rem path per line, listing exactly what that release contains (written by
rem .github\workflows\release.yml).
rem
rem The ZIP overlay below only ADDS and OVERWRITES - xcopy cannot remove. So a
rem file deleted or renamed upstream would otherwise sit on this machine
rem forever, and an installed copy drifts into a state nobody else has. Worse,
rem a stale .py module keeps shadowing the new code, producing bugs that only
rem ever show up for upgraded users and never on a fresh install. Keeping the
rem manifest lets the next update delete what the new release dropped.
set "MANIFEST=.fast-syncs-manifest"
set "PRUNED=0"

if exist ".git" goto git_update
goto zip_update

rem ── git checkout: pull ────────────────────────────────────────
:git_update
echo [update] Pulling latest changes...
where git >nul 2>&1
if errorlevel 1 (
  echo [update] WARNING: git is not on PATH - cannot pull the latest version.
  echo          Install "Git for Windows", or use the ZIP flow instead.
  set "NO_DL=1"
  goto deps
)
git pull --ff-only
if errorlevel 1 (
  echo [update] git pull could not fast-forward ^(diverged or local edits^) -
  echo          falling back to ZIP overlay...
  goto zip_update
)
goto deps

rem ── ZIP install: download latest ZIP and overlay it ───────────
:zip_update
echo [update] Downloading the latest version from GitHub...
where curl >nul 2>&1
if errorlevel 1 goto zip_manual
where tar >nul 2>&1
if errorlevel 1 goto zip_manual

set "ZIPTMP=%TEMP%\fast-syncs-zip"
rmdir /s /q "%ZIPTMP%" 2>nul
mkdir "%ZIPTMP%"
rem Scratch files for the post-overlay cleanup (see :prune_removed).
set "MANIFEST_PREV=%ZIPTMP%\previous-manifest"
set "OBSOLETE=%ZIPTMP%\obsolete-paths"
set "DIRLIST=%ZIPTMP%\emptied-dirs"
curl -fsSL -o "%ZIPTMP%\repo.zip" "%ZIP_URL%"
if not errorlevel 1 goto zip_got
rem No release published yet (releases/latest 404s), or this machine cannot
rem reach it. Fall back to the branch ZIP so the button keeps working; once
rem the first release exists this path is never taken. Skipped when the user
rem pinned a specific release with FAST_SYNCS_ZIP_URL - silently substituting
rem a different version there would defeat the point of pinning.
if defined FAST_SYNCS_ZIP_URL (
  echo [update] Could not download the pinned release.
  goto zip_manual
)
curl -fsSL -o "%ZIPTMP%\repo.zip" "%FALLBACK_ZIP_URL%"
if errorlevel 1 (
  echo [update] Could not download the update ^(offline, or the GitHub
  echo          repository is private / moved^).
  goto zip_manual
)
echo [update] No published release yet - used the latest code instead.

:zip_got
tar -xf "%ZIPTMP%\repo.zip" -C "%ZIPTMP%"
if errorlevel 1 goto zip_manual

rem The ZIP contains one folder (fast-syncs-<branch>); copy its contents
rem over this folder. Settings/venv/.direct-mode are not in the ZIP, so
rem they are left untouched. This updater itself runs from %TEMP%, so
rem overwriting update.bat here is safe.
rem
rem Keep the manifest the PREVIOUS install left behind BEFORE the overlay
rem overwrites it - the difference between the two is the whole point.
if exist "%MANIFEST%" copy /y "%MANIFEST%" "%MANIFEST_PREV%" >nul

set "COPIED=0"
set "SRCDIR="
for /d %%D in ("%ZIPTMP%\*") do (
  xcopy /e /y /q /i "%%D\*" . >nul && set "COPIED=1" && set "SRCDIR=%%D"
)
if "%COPIED%"=="0" goto zip_manual
echo [update] Files updated to the latest version.
rem Delete what this release no longer ships. Releases older than this feature
rem carry no manifest; :prune_removed then finds nothing to compare and does
rem nothing at all.
call :prune_removed
goto deps

:zip_manual
set "NO_DL=1"
echo [update] Automatic download failed - update manually instead:
echo          re-download the ZIP from GitHub and unzip it OVER this
echo          folder ^(your settings and venv are kept^).
goto deps

rem ── refresh Python dependencies ───────────────────────────────
:deps
rem A venv whose base Python was uninstalled or upgraded still has
rem python.exe on disk but cannot run. Probe by executing; a broken venv
rem is deleted and rebuilt through setup.bat (this used to hard-fail here
rem with "dependency update failed").
set "VENV_OK="
rem "&& set", not "if not errorlevel 1": a venv whose base Python was removed
rem dies with a NEGATIVE exit code, which "not errorlevel 1" reads as success.
if exist ".\venv\Scripts\python.exe" (
  ".\venv\Scripts\python.exe" -c "import sys" >nul 2>&1 && set "VENV_OK=1"
)
if defined VENV_OK goto deps_pip

if exist ".\venv" (
  echo [update] The venv is broken - its Python was removed or upgraded.
  echo          Rebuilding it from scratch...
  rmdir /s /q ".\venv" 2>nul
)
echo [update] Running setup.bat ...
set "SETUP_RAN=1"
rem Flat flow, NOT a parenthesized block: setup.bat cd's around, and the
rem "cd /d" that restores our directory must not expand a project path
rem inside a block (a folder named "fast-syncs-main (1)" closes it on its ")").
if exist ".direct-mode" goto setup_direct
call setup.bat
goto setup_done

:setup_direct
call setup.bat --direct

:setup_done
if errorlevel 1 exit /b 1
rem cd (below) resets errorlevel, so it goes AFTER the check.
cd /d "%~2"
goto dubbing

:deps_pip
rem Migrate installs made before the .direct-mode marker existed: if the
rem direct-mode libs are importable, this venv was set up with --direct.
if not exist ".direct-mode" (
  ".\venv\Scripts\python.exe" -c "import google.genai" >nul 2>&1 && type nul > ".direct-mode"
)
rem "|| goto", not "if errorlevel 1" (which only catches >= 1): a python.exe that
rem cannot start exits with a NEGATIVE code, and this update would then print
rem "Update complete" over a failed dependency install.
echo [update] Updating Python dependencies...
".\venv\Scripts\python.exe" -m pip install --quiet --upgrade -r requirements.txt || goto deps_failed
if exist ".direct-mode" (
  echo [update] Updating direct-mode dependencies...
  ".\venv\Scripts\python.exe" -m pip install --quiet --upgrade -r requirements-direct.txt || goto direct_failed
)
goto dubbing

:deps_failed
echo ERROR: dependency update failed.
pause
exit /b 1

:direct_failed
echo ERROR: direct-mode dependency update failed.
pause
exit /b 1

rem ── bundled dubbing app (dubbing\) ─────────────────────────────
rem Run its setup in automatic mode on EVERY update - the first update
rem after the merge it creates dubbing\venv and installs ffmpeg (this used
rem to be a manual step people hit as "venv not found" errors); later
rem updates just refresh deps (fast). Never fails the whole update.
rem Skipped when setup.bat just ran - it already did this itself.
:dubbing
if defined SETUP_RAN goto finish
if not exist ".\dubbing\setup_windows.bat" goto finish
echo [update] Setting up / refreshing the dubbing app ^(first time can take a few minutes^)...
call ".\dubbing\setup_windows.bat" --auto
if errorlevel 1 echo WARNING: dubbing setup reported a problem - run dubbing\setup_windows.bat manually.
rem Restore the project dir the sub-script cd'd out of: every relative path
rem below resolves against it, and this updater itself runs from %TEMP%.
cd /d "%~2"

:finish
echo.
if defined NO_DL (
  echo Update finished, but the new version could NOT be downloaded -
  echo see the messages above. Your current version keeps working.
) else (
  echo Update complete. Re-run the script in REAPER to use the new version.
)
pause
rem Everything past here is subroutines. cmd.exe runs straight through a
rem label, so the script MUST end here or it would fall into them.
exit /b 0

rem ──────────────────────────────────────────────────────────────
rem  Removing files the new release no longer ships
rem
rem  This is the only code in the updater that deletes a user's files, so it
rem  fails CLOSED at every step: anything unexpected means skip that path and
rem  carry on. A stale file is a far smaller problem than a deleted one.
rem
rem  Flow: the previous install's manifest minus the new one = the obsolete
rem  paths. That list is then filtered - hard - before anything is touched.
rem ──────────────────────────────────────────────────────────────
:prune_removed
rem No previous manifest (fresh install, or the first update after this
rem shipped): there is no record of what the older release contained, so
rem DELETE NOTHING and never guess. The new manifest is on disk now, so from
rem the next update on there is something to compare against.
if not exist "%MANIFEST_PREV%" goto prune_first_time
rem No new manifest, or an empty one - "no list" must never be read as
rem "this release ships nothing".
if not exist "%MANIFEST%" goto :eof
if not exist "%SRCDIR%\%MANIFEST%" goto :eof
rem String compare, not EQU: a lookup that returns nothing would make a
rem numeric "if  EQU 0" a syntax error rather than a clean bail-out.
for %%S in ("%MANIFEST%") do if "%%~zS"=="0" goto :eof

rem Set difference, in one pass and without a loop: /v inverts, /x matches
rem whole lines only, /l compares literally (never as a regex), /g: reads the
rem new manifest as the list of strings to match. What survives is every path
rem the previous release shipped that this one does not.
findstr /v /x /l /g:"%MANIFEST%" "%MANIFEST_PREV%" > "%OBSOLETE%" 2>nul

rem ── filter 1: shape ───────────────────────────────────────────
rem A path must be a plain relative path inside this folder. The whitelist
rem admits only letters, digits, space, dot, underscore, hyphen and forward
rem slash, and the first character may not be a slash or a hyphen. In one
rem regex that refuses absolute paths, drive letters (no colon is allowed),
rem UNC paths and every backslash, a leading tilde, and - the part that
rem matters most here - every character cmd.exe would otherwise act on:
rem ampersand, caret, percent, exclamation mark, parentheses, quote, pipe,
rem both redirection signs, asterisk and question mark. That is what makes
rem it safe to hand these strings to a subroutine further down.
rem Non-ASCII names are refused too: they simply never get pruned, which is
rem the harmless direction.
findstr /r /c:"^[A-Za-z0-9._][A-Za-z0-9._/ -]*$" "%OBSOLETE%" > "%OBSOLETE%.shape" 2>nul
rem Then drop anything containing ".." at all, so no path can climb out.
findstr /v /l /c:".." "%OBSOLETE%.shape" > "%OBSOLETE%.noclimb" 2>nul
rem And anything non-canonical: no real manifest path contains "./", and a
rem line that is just "." is not a file. Refuse rather than normalise, exactly
rem as manifest_path_ok() does in update.sh. Both are plain literal (/l)
rem matches, so no regex metacharacter - and no caret - is involved.
findstr /v /l /c:"./" "%OBSOLETE%.noclimb" > "%OBSOLETE%.nodot" 2>nul
findstr /v /x /l /c:"." "%OBSOLETE%.nodot" > "%OBSOLETE%.plain" 2>nul

rem ── filter 2: the refuse-list ─────────────────────────────────
rem Paths that are never deleted whatever a manifest claims. Nearly all of
rem these are already safe by never appearing in a manifest (they are
rem gitignored, so they are not in the release) - this is the second layer,
rem for the day a manifest is wrong. Mirrors manifest_protected() in update.sh.
rem /i because Windows paths are case-insensitive; /r with several /c: strings
rem means "matches any of these".
rem
rem Deliberately UNANCHORED: "venv/" rather than "^venv/". Matching anywhere in
rem the line is the broader, safer reading for a refuse-list, and it keeps "^"
rem out of these two commands entirely - a caret would otherwise sit inside a
rem quoted argument on a line that is itself continued with a caret, which is
rem more cmd.exe parsing than this is worth betting a user's files on. The
rem cost is only that a release file with "venv/" in its path could never be
rem pruned, which is the harmless direction.
findstr /v /i /r ^
 /c:"venv/" ^
 /c:"sync_pipeline_settings\.json" /c:"vertex_key\.json" ^
 /c:"service_account\.json" /c:"github_token\.txt" ^
 /c:"dubbing/config/" /c:"dubbing/engine/status/" /c:"dubbing/data/" ^
 "%OBSOLETE%.plain" > "%OBSOLETE%.safe1" 2>nul
findstr /v /i /r ^
 /c:"\.env$" /c:"\.env\." /c:"\.direct-mode" /c:"\.fast-syncs-manifest" ^
 /c:"\.pem$" /c:"\.key$" ^
 /c:"\.RPP$" /c:"\.RPP-bak$" ^
 /c:"\.wav$" /c:"\.mp3$" /c:"\.aif$" /c:"\.aiff$" /c:"\.m4a$" ^
 /c:"\.flac$" /c:"\.ogg$" /c:"\.opus$" ^
 "%OBSOLETE%.safe1" > "%OBSOLETE%.safe" 2>nul

rem Every surviving line is now known to be a plain relative path made of
rem harmless characters, so passing it to a subroutine is safe.
for /f "usebackq delims=" %%L in ("%OBSOLETE%.safe") do call :prune_one "%%L"

call :prune_dirs
if "%PRUNED%"=="0" goto prune_nothing
echo [update] Removed %PRUNED% file^(s^) this version no longer ships.
goto :eof

:prune_nothing
echo [update] Nothing left over from the previous version.
goto :eof

:prune_first_time
echo [update] First update carrying a file list - nothing to clean up yet.
goto :eof

rem ── delete one obsolete file ──────────────────────────────────
:prune_one
set "MP=%~1"
if not defined MP goto :eof
rem Forward slashes to back: cmd tools take "/" in most places but not all,
rem and "del" is one that can read a leading "/" as a switch.
set "MPW=%MP:/=\%"
rem Still in the release we just unpacked? Then it is not obsolete. The
rem unpacked tree overrules the list, so even a truncated or garbled manifest
rem cannot delete a file this very update just installed.
if exist "%SRCDIR%\%MPW%" goto :eof
rem Already gone, or never installed here.
if not exist "%MPW%" goto :eof
rem Files only. `if exist "path\"` is true only for a directory, and
rem directories are removed by :prune_dirs alone - never here.
if exist "%MPW%\" goto :eof
rem A junction or symlink for a parent folder would make an in-folder-looking
rem path resolve somewhere else entirely. Refuse those.
for %%P in ("%MPW%") do call :is_link "%%~dpP."
if defined ISLINK goto :eof
del /f /q "%MPW%" >nul 2>&1
rem Confirm rather than trust the exit code (a file held open by REAPER just
rem stays put; that is fine, it is only stale).
if exist "%MPW%" goto :eof
set /a PRUNED+=1
rem Remember the folder it lived in, for the empty-directory sweep. Quoted
rem going in and coming back out, so an install path containing "&" or ")"
rem can break neither the echo nor the loop that reads it.
for %%P in ("%MPW%") do call :note_dir "%%~dpP."
goto :eof

:note_dir
echo "%~f1">>"%DIRLIST%"
goto :eof

rem ── sweep up directories our deletions emptied ────────────────
rem Only directories that DIRECTLY held a file we shipped are even
rem considered, and plain `rmdir` - no /s, no /q - refuses to touch one that
rem still has anything at all inside it. Three passes, because a\b\c has to
rem go before a\b can, and the list is in deletion order rather than depth
rem order.
:prune_dirs
if not exist "%DIRLIST%" goto :eof
set "PASS=0"
:prune_dirs_pass
set /a PASS+=1
for /f "usebackq delims=" %%L in ("%DIRLIST%") do call :rmdir_if_empty %%L
if %PASS% LSS 3 goto prune_dirs_pass
goto :eof

:rmdir_if_empty
if "%~1"=="" goto :eof
rem The install folder itself is never a candidate - that is the boundary.
if /i "%~f1"=="%ROOTDIR%" goto :eof
if not exist "%~1\" goto :eof
call :is_link "%~1"
if defined ISLINK goto :eof
rmdir "%~1" 2>nul
goto :eof

rem ── is this directory a junction / symlink? ───────────────────
rem "%%~aF" gives the attribute string; an "l" in it means reparse point, and
rem no other attribute letter is "l". The install folder itself is exempt: it
rem is where we already are, so how it is reached does not matter.
:is_link
set "ISLINK="
if /i "%~f1"=="%ROOTDIR%" goto :eof
set "ATTR="
for %%F in ("%~f1") do set "ATTR=%%~aF"
if not defined ATTR goto :eof
if not "%ATTR:l=%"=="%ATTR%" set "ISLINK=1"
goto :eof
