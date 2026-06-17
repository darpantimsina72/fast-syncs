@echo off
rem ──────────────────────────────────────────────────────────────
rem  fast-syncs update (Windows) — pulls the latest version and
rem  re-installs Python dependencies.
rem ──────────────────────────────────────────────────────────────
setlocal
cd /d "%~dp0"

echo [update] Pulling latest changes...
if exist ".git" (
  where git >nul 2>&1 && git pull --ff-only
) else (
  echo [update] Not a git checkout - skipping pull. Re-download the ZIP to update.
)

if exist ".\venv\Scripts\python.exe" (
  echo [update] Updating Python dependencies...
  ".\venv\Scripts\python.exe" -m pip install --quiet --upgrade -r requirements.txt
) else (
  echo [update] No venv found - running setup.bat ...
  call setup.bat
)

echo.
echo Update complete.
pause
