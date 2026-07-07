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
  echo ERROR: could not copy the updater to %TEMP%.
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

set "ZIP_URL=https://codeload.github.com/darpantimsina72/fast-syncs/zip/refs/heads/main"

if exist ".git" goto git_update
goto zip_update

rem ── git checkout: pull ────────────────────────────────────────
:git_update
echo [update] Pulling latest changes...
where git >nul 2>&1
if errorlevel 1 (
  echo [update] WARNING: git is not on PATH - cannot pull the latest version.
  echo          Install "Git for Windows", or use the ZIP flow instead.
  goto deps
)
git pull --ff-only
if errorlevel 1 (
  echo ERROR: git pull failed - the latest version was NOT applied.
  echo Resolve the conflict ^(or re-download the ZIP^) and run update.bat again.
  pause
  exit /b 1
)
goto deps

rem ── ZIP install: download latest ZIP and overlay it ───────────
:zip_update
echo [update] Not a git checkout - downloading the latest version from GitHub...
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
  xcopy /e /y /q /i "%%D\*" . >nul
  if not errorlevel 1 set "COPIED=1"
)
if "%COPIED%"=="0" goto zip_manual
echo [update] Files updated to the latest version.
goto deps

:zip_manual
echo [update] Automatic download failed - update manually instead:
echo          re-download the ZIP from GitHub and unzip it OVER this
echo          folder ^(your settings and venv are kept^).
goto deps

rem ── refresh Python dependencies ───────────────────────────────
:deps
if exist ".\venv\Scripts\python.exe" (
  rem Migrate installs made before the .direct-mode marker existed: if the
  rem direct-mode libs are importable, this venv was set up with --direct.
  if not exist ".direct-mode" (
    ".\venv\Scripts\python.exe" -c "import google.genai" >nul 2>&1
    if not errorlevel 1 ( type nul > ".direct-mode" )
  )
  echo [update] Updating Python dependencies...
  ".\venv\Scripts\python.exe" -m pip install --quiet --upgrade -r requirements.txt
  if errorlevel 1 ( echo ERROR: dependency update failed. & pause & exit /b 1 )
  if exist ".direct-mode" (
    echo [update] Updating direct-mode dependencies...
    ".\venv\Scripts\python.exe" -m pip install --quiet --upgrade -r requirements-direct.txt
    if errorlevel 1 ( echo ERROR: direct-mode dependency update failed. & pause & exit /b 1 )
  )
) else (
  echo [update] No venv found - running setup.bat ...
  if exist ".direct-mode" ( call setup.bat --direct ) else ( call setup.bat )
  if errorlevel 1 ( exit /b 1 )
)

echo.
echo Update complete. Re-run the script in REAPER to use the new version.
pause
