@echo off
rem ──────────────────────────────────────────────────────────────
rem  fast-syncs update (Windows) — pulls the latest version and
rem  re-installs Python dependencies.
rem
rem  cmd.exe reads batch files from disk line-by-line WHILE they run,
rem  so `git pull` rewriting this very file mid-run would derail it.
rem  Guard: re-launch from a copy in %TEMP% and do the real work there.
rem ──────────────────────────────────────────────────────────────
if "%~1"=="--from-temp" goto run
copy /y "%~f0" "%TEMP%\fast-syncs-update.bat" >nul
if errorlevel 1 (
  echo ERROR: could not copy the updater to %TEMP%.
  pause
  exit /b 1
)
"%TEMP%\fast-syncs-update.bat" --from-temp "%~dp0"
exit /b

:run
setlocal
cd /d "%~2"

echo [update] Pulling latest changes...
if exist ".git" (
  where git >nul 2>&1
  if errorlevel 1 (
    echo [update] WARNING: git is not on PATH - cannot pull the latest version.
    echo          Install "Git for Windows", or re-download the ZIP to update.
  ) else (
    git pull --ff-only
    if errorlevel 1 (
      echo ERROR: git pull failed - the latest version was NOT applied.
      echo Resolve the conflict ^(or re-download the ZIP^) and run update.bat again.
      pause
      exit /b 1
    )
  )
) else (
  echo [update] Not a git checkout - skipping pull. Re-download the ZIP to update.
)

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
echo Update complete.
pause
