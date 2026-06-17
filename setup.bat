@echo off
rem ──────────────────────────────────────────────────────────────
rem  fast-syncs setup (Windows) — creates a Python virtualenv and
rem  installs dependencies for sync_matcher.py.
rem
rem    setup.bat            thin client (server/proxy mode). Tiny install.
rem    setup.bat --direct   also install direct-mode libs (google-genai,
rem                         soundfile) for running WITHOUT a server.
rem
rem  Run once (double-click). To update later, run update.bat.
rem ──────────────────────────────────────────────────────────────
setlocal
cd /d "%~dp0"

set "DIRECT=0"
if /I "%~1"=="--direct" set "DIRECT=1"

rem ── Find a Python 3 launcher ──────────────────────────────────
set "PYEXE="
where py >nul 2>&1 && set "PYEXE=py -3"
if not defined PYEXE (
  where python >nul 2>&1 && set "PYEXE=python"
)
if not defined PYEXE (
  echo ERROR: Python 3 not found.
  echo Install it from https://www.python.org/downloads/ and re-run this file.
  echo During install, tick "Add python.exe to PATH".
  pause
  exit /b 1
)

echo [setup] Using: %PYEXE%
echo [setup] Creating virtualenv in .\venv ...
%PYEXE% -m venv venv
if errorlevel 1 ( echo ERROR: could not create virtualenv. & pause & exit /b 1 )

set "VPY=.\venv\Scripts\python.exe"

if not exist "%VPY%" (
  echo ERROR: virtualenv python not found at %VPY%
  echo The Python install may be incomplete. Reinstall Python 3.11+ from
  echo https://www.python.org/downloads/ ^(tick "Add python.exe to PATH"^).
  pause
  exit /b 1
)

rem Confirm the venv's pip actually works before relying on it.
"%VPY%" -m pip --version >nul 2>&1
if errorlevel 1 (
  echo ERROR: pip is not working in the new virtualenv.
  echo Reinstall Python 3.11+ from https://www.python.org/downloads/ and re-run.
  pause
  exit /b 1
)

echo [setup] Installing thin-client dependencies ...
"%VPY%" -m pip install --quiet --upgrade pip
"%VPY%" -m pip install --quiet -r requirements.txt
if errorlevel 1 ( echo ERROR: dependency install failed. & pause & exit /b 1 )

if "%DIRECT%"=="1" (
  echo [setup] Installing direct-mode dependencies ...
  "%VPY%" -m pip install --quiet -r requirements-direct.txt
)

echo.
echo [setup] Verifying ...
if "%DIRECT%"=="1" (
  "%VPY%" -c "from google import genai; import soundfile; print('OK (direct mode)')"
) else (
  "%VPY%" -c "import ssl, wave, urllib.request; print('OK (thin client)')"
)

echo.
echo Setup complete. You can now run auto_sync_pipeline.lua in Reaper.
pause
