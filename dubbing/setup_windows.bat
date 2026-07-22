@echo off
rem Reaper Dubbing App - one-time Windows setup (v0.4, standalone).
rem
rem Double-click this file, or run it from a terminal:  setup_windows.bat
rem
rem What it does - safe to re-run at any time:
rem   1. Finds Python 3.11+ (py launcher first, then python on PATH),
rem      creates a local .\venv and installs requirements.txt into it.
rem   2. Runs the engine self-check (imports the pipeline modules).
rem   3. Checks for ffmpeg (needed for audio conversion) and offers to
rem      install it with winget when missing.
rem   4. Prints the REAPER script-install steps.

setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
set "HERE=%CD%"
set "VENV_PY=%HERE%\venv\Scripts\python.exe"

echo == Reaper Dubbing App setup (Windows) ==
echo Project dir : %HERE%
echo.

rem ---------------------------------------------------------------------------
rem 1. Find a Python 3.11+ interpreter.
rem    The bare "python" on a stock Windows can be the Microsoft Store
rem    placeholder alias, which exits non-zero on -c - the version probe
rem    below rejects it automatically.
rem ---------------------------------------------------------------------------

set "PY_CMD="
for %%P in ("py -3.14" "py -3.13" "py -3.12" "py -3.11" "py -3" "python" "python3") do (
  if not defined PY_CMD (
    %%~P -c "import sys; raise SystemExit(0 if sys.version_info >= (3,11) else 1)" >nul 2>&1
    if !errorlevel! == 0 set "PY_CMD=%%~P"
  )
)

if not defined PY_CMD (
  echo ERROR: no Python 3.11+ interpreter found.
  echo.
  echo Install Python first - either:
  echo   - winget install -e --id Python.Python.3.12
  echo   - or download it from https://www.python.org/downloads/
  echo     ^(tick "Add python.exe to PATH" in the installer^)
  echo then re-run this script.
  goto :end_fail
)
for /f "delims=" %%V in ('%PY_CMD% -c "import sys;print(sys.version.split()[0])"') do set "PY_VER=%%V"
echo Python      : %PY_CMD%  (%PY_VER%)

rem ---------------------------------------------------------------------------
rem 2. Create .\venv (reused when it already works) + install requirements
rem ---------------------------------------------------------------------------

set "VENV_OK="
if exist "%VENV_PY%" (
  "%VENV_PY%" -c "import sys" >nul 2>&1
  if !errorlevel! == 0 set "VENV_OK=1"
)
if defined VENV_OK (
  echo venv        : %HERE%\venv  (already exists - reusing)
) else (
  echo venv        : creating %HERE%\venv ...
  %PY_CMD% -m venv "%HERE%\venv"
  if errorlevel 1 (
    echo ERROR: could not create the venv.
    goto :end_fail
  )
)

if not exist "%HERE%\requirements.txt" (
  echo ERROR: requirements.txt not found next to this script.
  goto :end_fail
)

echo.
echo Installing engine dependencies (idempotent - re-runs are fast) ...
"%VENV_PY%" -m pip install --upgrade pip --quiet
"%VENV_PY%" -m pip install -r "%HERE%\requirements.txt"
if errorlevel 1 (
  echo ERROR: pip install failed. Check your network and re-run.
  goto :end_fail
)

rem ---------------------------------------------------------------------------
rem 3. Engine self-check (imports the pipeline modules, verifies prompts)
rem ---------------------------------------------------------------------------

echo.
echo Running engine self-check ...
"%VENV_PY%" "%HERE%\engine\dub_engine.py" --selfcheck
if errorlevel 1 (
  echo WARNING: engine self-check failed (see messages above).
  echo Setup continues - fix the reported issue, then re-run this script.
) else (
  echo Self-check passed.
)

rem ---------------------------------------------------------------------------
rem 4. ffmpeg - needed by the engine for audio conversion (pydub/librosa).
rem    The engine also finds the winget install location automatically.
rem ---------------------------------------------------------------------------

echo.
set "FFMPEG_FOUND="
where ffmpeg >nul 2>&1 && set "FFMPEG_FOUND=1"
if not defined FFMPEG_FOUND if exist "%LOCALAPPDATA%\Microsoft\WinGet\Links\ffmpeg.exe" set "FFMPEG_FOUND=1"
if not defined FFMPEG_FOUND if exist "%HERE%\ffmpeg\bin\ffmpeg.exe" set "FFMPEG_FOUND=1"

if defined FFMPEG_FOUND (
  echo ffmpeg      : found.
) else (
  echo ffmpeg      : NOT found - the pipeline needs it for audio conversion.
  where winget >nul 2>&1
  if !errorlevel! == 0 (
    set "REPLY=N"
    set /p "REPLY=Install ffmpeg now with winget? [y/N] "
    if /i "!REPLY!" == "y" (
      winget install -e --id Gyan.FFmpeg
      echo   If the install just finished, ffmpeg is picked up automatically
      echo   on the next run - no restart of this script needed.
    ) else (
      echo   Skipped. Install it later with:  winget install -e --id Gyan.FFmpeg
    )
  ) else (
    echo   Install it with:  winget install -e --id Gyan.FFmpeg
    echo   or download a build from https://www.gyan.dev/ffmpeg/builds/ and
    echo   unzip it to %HERE%\ffmpeg\  (so ffmpeg.exe is in ffmpeg\bin\).
  )
)

rem ---------------------------------------------------------------------------
rem 5. REAPER script-install steps
rem ---------------------------------------------------------------------------

echo.
echo == Setup complete ==
echo.
echo Install the REAPER scripts (load them IN PLACE - do not copy them):
echo   1. In REAPER: Actions -^> Show action list -^> New action -^> Load ReaScript...
echo   2. Pick both files from:  %HERE%\reaper\
echo      (Dub_Pipeline_Panel.lua and Import_Dub_Results.lua).
echo   NOTE: do NOT copy the .lua files into REAPER's Scripts\ folder.
echo   The panel finds the engine relative to its own location, so it only
echo   works from  %HERE%\reaper\  (next to the engine\ folder).
echo.
echo Recommended: install ReaImGui via ReaPack (Extensions -^> ReaPack -^>
echo Browse packages -^> search 'ReaImGui') for the panel UI - the panel
echo also offers to install it for you on first run.
echo.
pause
exit /b 0

:end_fail
echo.
pause
exit /b 1
