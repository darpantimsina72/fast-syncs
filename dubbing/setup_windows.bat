@echo off
rem Reaper Dubbing App - one-time Windows setup (v0.6, standalone).
rem
rem Double-click this file, or run it from a terminal:  setup_windows.bat
rem
rem   setup_windows.bat          interactive (pauses at the end)
rem   setup_windows.bat --auto   fully automatic: no prompts, no pause. Used
rem                              by update.bat and by the REAPER panel's
rem                              first-open bootstrap.
rem
rem What it does - safe to re-run at any time:
rem   1. Finds Python 3.11+ (py launcher, PATH, per-user + all-users
rem      installs); in --auto mode installs Python 3.12 via winget when
rem      none is found. Prefers 3.12/3.13 over brand-new releases, which
rem      often have no prebuilt wheels for the audio libraries yet.
rem   2. Creates a local .\venv and installs requirements.txt into it.
rem      A broken venv (its Python was removed/upgraded) is rebuilt.
rem   3. Installs ffmpeg automatically when missing (winget first, then a
rem      pinned, SHA256-verified portable build into .\ffmpeg\bin) - the
rem      engine needs it to decode TTS audio; without it dub runs fail at
rem      the save step.
rem   4. Runs the engine self-check (imports the pipeline modules).

setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
set "HERE=%CD%"
rem Paths used in COMMANDS below are relative to this folder (we cd'd into it
rem above); %HERE% is only ever echoed, outside parenthesized blocks. Reason:
rem a folder name containing parentheses - "fast-syncs-main (1)", the name
rem Windows gives a second ZIP download - expands its ")" into the middle of a
rem parenthesized if-block, which derails cmd.exe's parser ("<rest of path>
rem was unexpected at this time") and silently skipped the venv creation.
rem Relative paths can never carry a parenthesis, so they are immune.
set "VENV_PY=venv\Scripts\python.exe"
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
rem    All version asserts are written WITHOUT parentheses on purpose: a ")"
rem    inside a parenthesized for-block can prematurely close the block on
rem    some cmd.exe versions.
rem ---------------------------------------------------------------------------

set "PY_CMD="
call :find_python
if defined PY_CMD goto have_python
call :probe_localdirs
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
if not defined PY_CMD call :probe_localdirs
if not defined PY_CMD goto no_python

:have_python
%PY_CMD% --version > "%TEMP%\dub-pyver.txt" 2>&1
set "PY_VER="
set /p PY_VER=<"%TEMP%\dub-pyver.txt"
del "%TEMP%\dub-pyver.txt" 2>nul
echo Python      : %PY_CMD%  (%PY_VER%)

rem ---------------------------------------------------------------------------
rem 2. Create .\venv (reused when it already works) + install requirements.
rem    "Works" means: it runs AND is 3.11+. A venv whose base Python was
rem    uninstalled or upgraded still has python.exe on disk but cannot run -
rem    delete it and rebuild (stale site-packages from another Python
rem    version cause import errors otherwise).
rem ---------------------------------------------------------------------------

if not exist "%VENV_PY%" goto venv_create
rem "|| goto", not "if errorlevel 1": when the base Python was uninstalled this
rem python.exe dies with STATUS_DLL_NOT_FOUND, whose exit code is NEGATIVE, and
rem "if errorlevel 1" (which means ">= 1") would call that broken venv healthy.
"%VENV_PY%" -c "import sys; assert sys.version_info[0]==3 and sys.version_info[1]>=11" >nul 2>&1 || goto venv_rebuild
echo venv        : %HERE%\venv - already exists, reusing it.
goto venv_ready

:venv_rebuild
echo venv        : broken or outdated - rebuilding it from scratch ...

:venv_create
rem Always start from an empty dir: a half-created venv, or one whose base
rem Python was removed/upgraded, otherwise keeps stale Lib\site-packages.
rmdir /s /q "venv" 2>nul
echo venv        : creating %HERE%\venv ...
%PY_CMD% -m venv venv
if not exist "%VENV_PY%" goto venv_failed

:venv_ready
if not exist "requirements.txt" goto no_reqs

echo.
echo Installing engine dependencies (idempotent - re-runs are fast) ...
"%VENV_PY%" -m pip install --upgrade pip --quiet
"%VENV_PY%" -m pip install -r requirements.txt
if not !errorlevel! == 0 goto pip_failed

rem ---------------------------------------------------------------------------
rem 3. ffmpeg - REQUIRED by the engine (pydub decodes ElevenLabs MP3 with it;
rem    a missing ffmpeg fails dub runs at the "Saving" step with WinError 2).
rem    Install it automatically: winget first (it verifies its own downloads),
rem    then a pinned + SHA256-checked portable build as the fallback.
rem    The engine finds both install styles on its own at run time.
rem ---------------------------------------------------------------------------

echo.
set "FFMPEG_FOUND="
where ffmpeg >nul 2>&1 && set "FFMPEG_FOUND=1"
if not defined FFMPEG_FOUND if exist "!LOCALAPPDATA!\Microsoft\WinGet\Links\ffmpeg.exe" set "FFMPEG_FOUND=1"
if not defined FFMPEG_FOUND if exist "ffmpeg\bin\ffmpeg.exe" set "FFMPEG_FOUND=1"
if not defined FFMPEG_FOUND goto ffmpeg_install
echo ffmpeg      : found.
goto ffmpeg_done

:ffmpeg_install
echo ffmpeg      : not found - installing it now ...
where winget >nul 2>&1
if errorlevel 1 goto ffmpeg_portable
winget install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements
where ffmpeg >nul 2>&1 && set "FFMPEG_FOUND=1"
if not defined FFMPEG_FOUND if exist "!LOCALAPPDATA!\Microsoft\WinGet\Links\ffmpeg.exe" set "FFMPEG_FOUND=1"
if not defined FFMPEG_FOUND goto ffmpeg_portable
echo ffmpeg      : installed via winget.
goto ffmpeg_done

rem The portable fallback runs UNSANDBOXED code we just pulled off the network,
rem so it pins one exact build and checks its SHA256 before unpacking it.
rem Why not the vendor's "ffmpeg-release-essentials.zip": that URL is a moving
rem pointer to whatever is newest, so its bytes change without notice and no
rem checksum can ever be pinned to it - HTTPS alone would be the only integrity
rem control, and a bad build would be executed before anyone noticed.
rem FFURL is the immutable GitHub release asset for FFVER, not the vendor's own
rem webserver, because a release-tag asset cannot be swapped in place.
rem To bump the version: change FFVER, download the new asset, hash it with
rem   certutil -hashfile THEFILE.zip SHA256   and paste the result into FFSHA.
rem FFSHA below was verified by downloading this asset from BOTH github.com and
rem gyan.dev and confirming the two copies are byte-identical to each other and
rem to the vendor's published ffmpeg-9.0.1-essentials_build.zip.sha256.
:ffmpeg_portable
echo ffmpeg      : winget unavailable or failed - downloading a portable build ...
set "FFVER=9.0.1"
set "FFSHA=fec81ae03971d9dd4be3ebe02e263bd2ec1d789483f931bdba5f5715e65da2e9"
set "FFURL=https://github.com/GyanD/codexffmpeg/releases/download/%FFVER%/ffmpeg-%FFVER%-essentials_build.zip"
set "FFTMP=%TEMP%\dub-ffmpeg"
rmdir /s /q "%FFTMP%" 2>nul
mkdir "%FFTMP%"
echo ffmpeg      : fetching pinned build %FFVER% ...
curl -fSL -o "%FFTMP%\ffmpeg.zip" "%FFURL%"
if errorlevel 1 goto ffmpeg_manual
rem Verify BEFORE unpacking: nothing from the archive is written to the project
rem folder, let alone run, unless the bytes match the pin above.
call :verify_sha256 "%FFTMP%\ffmpeg.zip" "%FFSHA%"
if errorlevel 1 goto ffmpeg_badhash
echo ffmpeg      : SHA256 verified.
tar -xf "%FFTMP%\ffmpeg.zip" -C "%FFTMP%"
if errorlevel 1 goto ffmpeg_manual
set "FFSRC="
for /d %%D in ("%FFTMP%\ffmpeg-*") do set "FFSRC=%%D"
if not defined FFSRC goto ffmpeg_manual
if not exist "ffmpeg\bin" mkdir "ffmpeg\bin"
copy /y "%FFSRC%\bin\ffmpeg.exe"  "ffmpeg\bin\" >nul
copy /y "%FFSRC%\bin\ffprobe.exe" "ffmpeg\bin\" >nul
rmdir /s /q "%FFTMP%" 2>nul
if not exist "ffmpeg\bin\ffmpeg.exe" goto ffmpeg_manual
echo ffmpeg      : portable build installed to ffmpeg\bin\.
goto ffmpeg_done

:ffmpeg_badhash
rem Mismatch = the download is not the build this script was pinned to. It is
rem deleted unopened and NOTHING is installed; a corrupted transfer and a
rem tampered-with archive look identical from here, so both are refused.
rmdir /s /q "%FFTMP%" 2>nul
rem FFHASH is empty when certutil itself failed to run; give it a printable
rem value first so the echo below cannot emit a bare "%FFHASH%".
if not defined FFHASH set "FFHASH=not computed - certutil could not hash the file"
echo ffmpeg      : DOWNLOAD COULD NOT BE VERIFIED - refusing to install it.
echo   The portable ffmpeg %FFVER% archive did not match its expected SHA256,
echo   so it was deleted without being unpacked. Nothing was installed.
echo     expected: %FFSHA%
echo     actual  : %FFHASH%
echo   This is either a corrupted download or a tampered-with file. Retry the
echo   setup; if it keeps failing, install ffmpeg by hand as described below.

:ffmpeg_manual
echo WARNING: could not install ffmpeg automatically.
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
"%VENV_PY%" "engine\dub_engine.py" --selfcheck
if not !errorlevel! == 0 goto selfcheck_warn
echo Self-check passed.
goto selfcheck_done

:selfcheck_warn
echo WARNING: engine self-check failed (see messages above).
echo Setup continues - fix the reported issue, then re-run this script.

:selfcheck_done

rem ---------------------------------------------------------------------------
rem 5. Done. (REAPER script-install steps only shown interactively - the
rem    panel bootstraps itself when this ran via --auto.)
rem ---------------------------------------------------------------------------

echo.
echo == Setup complete ==
if defined AUTO exit /b 0
echo.
for %%I in ("%HERE%\..") do set "FSROOT=%%~fI"
echo Install the REAPER script (load it IN PLACE - do not copy it):
echo   1. In REAPER: Actions -^> Show action list -^> New action -^> Load ReaScript...
echo   2. Pick this ONE file:  %FSROOT%\auto_sync_pipeline.lua
echo      It opens the dub panel; the sync tool is its Auto Sync tab.
echo   NOTE: do NOT copy the .lua files into REAPER's Scripts\ folder, and do
echo   not load anything from  %HERE%\reaper\  by hand - those are internal and
echo   are loaded for you. They find the engine relative to their own location,
echo   so they only work where they are (next to the engine\ folder).
echo.
echo Recommended: install ReaImGui via ReaPack (Extensions -^> ReaPack -^>
echo Browse packages -^> search 'ReaImGui') for the panel UI - the panel
echo also offers to install it for you on first run. If ReaImGui cannot be
echo installed here, reaper\Import_Dub_Results.lua still imports a finished run
echo on its own - the only file in reaper\ you would ever load directly.
echo.
pause
exit /b 0

rem ---------------------------------------------------------------------------
rem helpers
rem ---------------------------------------------------------------------------

:find_python
rem 3.12/3.13/3.11 BEFORE 3.14+ and the generic "py -3" (which picks the
rem newest install): brand-new Python releases often had no prebuilt wheels
rem for the audio deps (librosa/numba), so pip would try - and fail - to
rem compile them from source.
rem
rem NOTE: librosa/numba/llvmlite/scipy are no longer dependencies, so that
rem reason is gone and every remaining package ships pure-Python or broad
rem wheels. This ordering is kept for now only because it is known-good and
rem cannot be tested on Windows from a Mac. Once the cross-platform install
rem matrix runs green on 3.11-3.14, collapse this to a simple "first Python
rem 3.11+ wins" probe.
for %%P in ("py -3.12" "py -3.13" "py -3.11" "py -3.14" "py -3" "python" "python3") do (
  if not defined PY_CMD (
    %%~P -c "import sys; assert sys.version_info[0]==3 and sys.version_info[1]>=11" >nul 2>&1
    if !errorlevel! == 0 set "PY_CMD=%%~P"
  )
)
exit /b 0

:probe_localdirs
rem Installs that are NOT on a console's PATH that was opened before the
rem install (PATH is read once at launch): per-user python.org / winget
rem installs, then all-users installs (python.org "for all users", winget
rem run elevated).
rem !VAR! (not %VAR%) inside these blocks on purpose: delayed expansion runs
rem AFTER cmd.exe has parsed the block, so a value containing parentheses -
rem "C:\Program Files (x86)" when a 32-bit shell runs this - cannot close the
rem block early.
for /d %%D in ("!LOCALAPPDATA!\Programs\Python\Python3*") do (
  if not defined PY_CMD (
    "%%D\python.exe" -c "import sys; assert sys.version_info[0]==3 and sys.version_info[1]>=11" >nul 2>&1
    if !errorlevel! == 0 set "PY_CMD="%%D\python.exe""
  )
)
for /d %%D in ("!ProgramFiles!\Python3*") do (
  if not defined PY_CMD (
    "%%D\python.exe" -c "import sys; assert sys.version_info[0]==3 and sys.version_info[1]>=11" >nul 2>&1
    if !errorlevel! == 0 set "PY_CMD="%%D\python.exe""
  )
)
exit /b 0

:verify_sha256
rem %1 = file to hash (quoted), %2 = expected SHA256 as hex. Exits 0 on a
rem match, 1 on any mismatch OR any failure to produce a hash - "could not
rem check" must never be treated as "checked and fine". Leaves the computed
rem hash in FFHASH for the caller's error message.
rem certutil is present on every Windows that can run this script, so this
rem needs no PowerShell and no extra download.
rem certutil prints three lines - a header, the hash, a trailer - so skip=1
rem lands on the hash; "if not defined" keeps only that first line. Some
rem Windows builds space-separate the hash bytes and differ in case, hence the
rem ": =" strip and the /I compare.
rem Written flat, with no parenthesized block, per the rule at the top of this
rem file: a ")" from a path or a value must not be able to close a block.
set "FFHASH="
certutil -hashfile %1 SHA256 > "%TEMP%\dub-ffhash.txt" 2>&1
if errorlevel 1 goto verify_sha256_end
for /f "usebackq skip=1 delims=" %%H in ("%TEMP%\dub-ffhash.txt") do if not defined FFHASH set "FFHASH=%%H"
:verify_sha256_end
del "%TEMP%\dub-ffhash.txt" 2>nul
if not defined FFHASH exit /b 1
set "FFHASH=!FFHASH: =!"
if /I "!FFHASH!"=="%~2" exit /b 0
exit /b 1

rem Failure exits, kept flat and out of any parenthesized block so a project
rem path with parentheses can never break them.
:venv_failed
echo ERROR: could not create the venv.
goto end_fail

:no_reqs
echo ERROR: requirements.txt not found next to this script.
goto end_fail

:pip_failed
echo ERROR: pip install failed - read pip's own error above this line; it names
echo the package and reason. Common causes: no network / proxy blocking PyPI, or
echo a Python version with no prebuilt wheels for the audio deps. Then re-run.
goto end_fail

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
if defined AUTO exit /b 1
pause
exit /b 1
