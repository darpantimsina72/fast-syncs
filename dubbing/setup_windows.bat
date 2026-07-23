@echo off
rem Reaper Dubbing App - one-time Windows setup (v0.6, standalone).
rem
rem Double-click this file, or run it from a terminal:  setup_windows.bat
rem
rem   setup_windows.bat          interactive (pauses at the end)
rem   setup_windows.bat --auto   fully automatic: no prompts, no pause on
rem                              success. Used by update.bat and by the
rem                              REAPER panel's first-open bootstrap.
rem
rem What it does - safe to re-run at any time:
rem   1. Finds Python 3.11+ (py launcher, PATH, per-user installs); in
rem      --auto mode installs Python 3.12 via winget when none is found.
rem   2. Creates a local .\venv and installs requirements.txt into it.
rem   3. Installs ffmpeg automatically when missing (winget first, then a
rem      portable build into .\ffmpeg\bin) - the engine needs it to decode
rem      TTS audio; without it dub runs fail at the save step.
rem   4. Runs the engine self-check (imports the pipeline modules).

setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
set "HERE=%CD%"
set "VENV_PY=%HERE%\venv\Scripts\python.exe"
set "AUTO="
if /I "%~1"=="--auto" set "AUTO=1"

echo == Reaper Dubbing App setup (Windows) ==
echo Project dir : %HERE%
if defined AUTO echo Mode        : automatic (no prompts)
echo.

rem ---------------------------------------------------------------------------
rem 1. Find a Python 3.11+ interpreter.
rem    The bare "python" on a stock Windows can be the Microsoft Store
rem    placeholder alias, which exits non-zero on -c - the version probe
rem    below rejects it automatically.
rem ---------------------------------------------------------------------------

set "PY_CMD="
call :find_python
if defined PY_CMD goto have_python

rem Per-user python.org installs are NOT on a console's PATH that was opened
rem before the install (PATH is read once at launch) - probe them directly.
for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python3*") do (
  if not defined PY_CMD (
    "%%D\python.exe" -c "import sys; raise SystemExit(0 if sys.version_info >= (3,11) else 1)" >nul 2>&1
    if !errorlevel! == 0 set "PY_CMD="%%D\python.exe""
  )
)
if defined PY_CMD goto have_python

rem No Python 3.11+ anywhere - install one via winget (automatically in
rem --auto mode; after a Yes/No prompt otherwise).
where winget >nul 2>&1
if errorlevel 1 goto no_python
if defined AUTO (
  echo Python 3.11+ not found - installing Python 3.12 via winget ...
) else (
  echo Python 3.11+ was not found on this PC.
  choice /c YN /m "Install Python 3.12 automatically now via winget"
  if errorlevel 2 goto no_python
  echo Installing Python 3.12 - this can take a few minutes ...
)
winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
rem The fresh install is not on THIS console's PATH yet - probe known spots.
call :find_python
if not defined PY_CMD (
  for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python3*") do (
    if not defined PY_CMD (
      "%%D\python.exe" -c "import sys; raise SystemExit(0 if sys.version_info >= (3,11) else 1)" >nul 2>&1
      if !errorlevel! == 0 set "PY_CMD="%%D\python.exe""
    )
  )
)
if not defined PY_CMD goto no_python

:have_python
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
    goto end_fail
  )
)

if not exist "%HERE%\requirements.txt" (
  echo ERROR: requirements.txt not found next to this script.
  goto end_fail
)

echo.
echo Installing engine dependencies (idempotent - re-runs are fast) ...
"%VENV_PY%" -m pip install --upgrade pip --quiet
"%VENV_PY%" -m pip install -r "%HERE%\requirements.txt"
if errorlevel 1 (
  echo ERROR: pip install failed. Check your network and re-run.
  goto end_fail
)

rem ---------------------------------------------------------------------------
rem 3. ffmpeg - REQUIRED by the engine (pydub decodes ElevenLabs MP3 with it;
rem    a missing ffmpeg fails dub runs at the "Saving" step with WinError 2).
rem    Install it automatically: winget first, portable build as fallback.
rem    The engine finds both install styles on its own at run time.
rem ---------------------------------------------------------------------------

echo.
set "FFMPEG_FOUND="
where ffmpeg >nul 2>&1 && set "FFMPEG_FOUND=1"
if not defined FFMPEG_FOUND if exist "%LOCALAPPDATA%\Microsoft\WinGet\Links\ffmpeg.exe" set "FFMPEG_FOUND=1"
if not defined FFMPEG_FOUND if exist "%HERE%\ffmpeg\bin\ffmpeg.exe" set "FFMPEG_FOUND=1"
if defined FFMPEG_FOUND (
  echo ffmpeg      : found.
  goto ffmpeg_done
)

echo ffmpeg      : not found - installing it now ...
where winget >nul 2>&1
if errorlevel 1 goto ffmpeg_portable
winget install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements
where ffmpeg >nul 2>&1 && set "FFMPEG_FOUND=1"
if not defined FFMPEG_FOUND if exist "%LOCALAPPDATA%\Microsoft\WinGet\Links\ffmpeg.exe" set "FFMPEG_FOUND=1"
if defined FFMPEG_FOUND (
  echo ffmpeg      : installed via winget.
  goto ffmpeg_done
)

:ffmpeg_portable
echo ffmpeg      : winget unavailable or failed - downloading a portable build ...
set "FFTMP=%TEMP%\dub-ffmpeg"
rmdir /s /q "%FFTMP%" 2>nul
mkdir "%FFTMP%"
curl -fSL -o "%FFTMP%\ffmpeg.zip" "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
if errorlevel 1 goto ffmpeg_manual
tar -xf "%FFTMP%\ffmpeg.zip" -C "%FFTMP%"
if errorlevel 1 goto ffmpeg_manual
set "FFSRC="
for /d %%D in ("%FFTMP%\ffmpeg-*") do set "FFSRC=%%D"
if not defined FFSRC goto ffmpeg_manual
if not exist "%HERE%\ffmpeg\bin" mkdir "%HERE%\ffmpeg\bin"
copy /y "%FFSRC%\bin\ffmpeg.exe"  "%HERE%\ffmpeg\bin\" >nul
copy /y "%FFSRC%\bin\ffprobe.exe" "%HERE%\ffmpeg\bin\" >nul
rmdir /s /q "%FFTMP%" 2>nul
if not exist "%HERE%\ffmpeg\bin\ffmpeg.exe" goto ffmpeg_manual
echo ffmpeg      : portable build installed to ffmpeg\bin\.
goto ffmpeg_done

:ffmpeg_manual
echo WARNING: could not install ffmpeg automatically (offline?).
echo   Install it later with:  winget install -e --id Gyan.FFmpeg
echo   or unzip a build from https://www.gyan.dev/ffmpeg/builds/ into
echo   %HERE%\ffmpeg\  (so ffmpeg.exe is in ffmpeg\bin\).
echo   Dub runs will fail at the audio-save step until ffmpeg is installed.

:ffmpeg_done

rem ---------------------------------------------------------------------------
rem 4. Engine self-check (imports the pipeline modules, verifies prompts)
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
rem 5. Done. (REAPER script-install steps only shown interactively - the
rem    panel bootstraps itself when this ran via --auto.)
rem ---------------------------------------------------------------------------

echo.
echo == Setup complete ==
if defined AUTO exit /b 0
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

rem ---------------------------------------------------------------------------
rem helpers
rem ---------------------------------------------------------------------------

:find_python
for %%P in ("py -3.14" "py -3.13" "py -3.12" "py -3.11" "py -3" "python" "python3") do (
  if not defined PY_CMD (
    %%~P -c "import sys; raise SystemExit(0 if sys.version_info >= (3,11) else 1)" >nul 2>&1
    if !errorlevel! == 0 set "PY_CMD=%%~P"
  )
)
exit /b 0

:no_python
echo ERROR: no Python 3.11+ interpreter found.
echo.
echo Install Python first - either:
echo   - winget install -e --id Python.Python.3.12
echo   - or download it from https://www.python.org/downloads/
echo     ^(tick "Add python.exe to PATH" in the installer^)
echo then re-run this script.

:end_fail
echo.
echo == Setup did NOT finish ==
pause
exit /b 1
