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
rem NO_DL is set when the new files could NOT be fetched, so the final
rem message never claims an update that did not happen.
set "NO_DL="
rem SETUP_RAN is set when setup.bat ran (it already sets up the dubbing
rem app itself, so the dubbing step below can be skipped).
set "SETUP_RAN="

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
curl -fsSL -o "%ZIPTMP%\repo.zip" "%ZIP_URL%"
if errorlevel 1 (
  echo [update] Could not download the update ^(offline, or the GitHub
  echo          repository is private / moved^).
  goto zip_manual
)
tar -xf "%ZIPTMP%\repo.zip" -C "%ZIPTMP%"
if errorlevel 1 goto zip_manual

rem The ZIP contains one folder (fast-syncs-<branch>); copy its contents
rem over this folder. Settings/venv/.direct-mode are not in the ZIP, so
rem they are left untouched. This updater itself runs from %TEMP%, so
rem overwriting update.bat here is safe.
set "COPIED=0"
for /d %%D in ("%ZIPTMP%\*") do (
  xcopy /e /y /q /i "%%D\*" . >nul && set "COPIED=1"
)
if "%COPIED%"=="0" goto zip_manual
echo [update] Files updated to the latest version.
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
