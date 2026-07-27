@echo off
rem ──────────────────────────────────────────────────────────────
rem  fast-syncs setup (Windows) — creates a Python virtualenv and
rem  installs dependencies for sync_matcher.py.
rem
rem    setup.bat            thin client (server/proxy mode). Tiny install.
rem    setup.bat --direct   also install direct-mode libs (google-genai,
rem                         soundfile) for running WITHOUT a server.
rem
rem  If Python is missing, this script offers to install it for you
rem  via winget (built into Windows 10/11).
rem
rem  Run once (double-click). To update later, run update.bat.
rem ──────────────────────────────────────────────────────────────
rem Delayed expansion is on so the helpers below can expand paths as !VAR!
rem INSIDE parenthesized blocks: %VAR% is expanded while cmd.exe parses the
rem block, so a value containing ")" — "C:\Program Files (x86)", or a project
rem folder named "fast-syncs-main (1)" — closes the block early and derails
rem the whole script. No literal "!" appears in this file.
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

set "DIRECT=0"
if /I "%~1"=="--direct" set "DIRECT=1"

rem ── Find a working Python 3.9+ ────────────────────────────────
rem Each probe RUNS the candidate: on stock Windows 10/11, "python" on the
rem PATH is often the Microsoft Store alias stub, which exists but only
rem opens the Store page and exits with an error. Running it is the only
rem reliable check.
rem Probe 3.12/3.13/3.11 BEFORE the generic "py -3": the launcher picks the
rem NEWEST install, and a brand-new Python (3.14+) often has no prebuilt
rem wheels yet for the optional direct-mode libs.
set "PYEXE="
call :try_python py -3.12
if not defined PYEXE call :try_python py -3.13
if not defined PYEXE call :try_python py -3.11
if not defined PYEXE call :try_python py -3
if not defined PYEXE call :try_python python
if not defined PYEXE call :try_python python3
if not defined PYEXE call :try_userdir
if not defined PYEXE call :try_progfiles
if not defined PYEXE call :offer_winget
if not defined PYEXE goto no_python

echo [setup] Using: %PYEXE%

rem ── Create / reuse the virtualenv ─────────────────────────────
rem A venv whose base Python was uninstalled or upgraded still has
rem python.exe on disk but cannot run — probe by executing, and rebuild
rem from scratch when it is broken (stale site-packages from another
rem Python version cause import errors otherwise).
set "VPY=.\venv\Scripts\python.exe"
set "VENV_OK="
rem "&& set", not "if not errorlevel 1": after the base Python is uninstalled
rem this python.exe dies with STATUS_DLL_NOT_FOUND, whose exit code is NEGATIVE,
rem and "not errorlevel 1" (which means "< 1") would call it healthy. "&&" runs
rem only on exit code 0, whatever the sign of a failure.
if exist "!VPY!" (
  "!VPY!" -c "import sys" >nul 2>&1 && set "VENV_OK=1"
)
if defined VENV_OK (
  echo [setup] Reusing the existing virtualenv in .\venv
  goto have_venv
)
if exist ".\venv" (
  echo [setup] The existing virtualenv is broken - its Python was removed
  echo         or upgraded. Rebuilding it from scratch...
  rmdir /s /q ".\venv" 2>nul
)
echo [setup] Creating virtualenv in .\venv ...
%PYEXE% -m venv venv
if not !errorlevel! == 0 ( echo ERROR: could not create virtualenv. & pause & exit /b 1 )

:have_venv
if not exist "!VPY!" (
  echo ERROR: virtualenv python not found at !VPY!
  echo The Python install may be incomplete. Reinstall Python 3.11+ from
  echo https://www.python.org/downloads/ ^(tick "Add python.exe to PATH"^).
  pause
  exit /b 1
)

rem Confirm the venv's pip actually works before relying on it.
"!VPY!" -m pip --version >nul 2>&1
if not !errorlevel! == 0 (
  echo ERROR: pip is not working in the new virtualenv.
  echo Reinstall Python 3.11+ from https://www.python.org/downloads/ and re-run.
  pause
  exit /b 1
)

echo [setup] Installing thin-client dependencies ...
"!VPY!" -m pip install --quiet --upgrade pip
"!VPY!" -m pip install --quiet -r requirements.txt
if not !errorlevel! == 0 ( echo ERROR: dependency install failed. & pause & exit /b 1 )

if "%DIRECT%"=="1" (
  echo [setup] Installing direct-mode dependencies ...
  "!VPY!" -m pip install --quiet -r requirements-direct.txt
  if not !errorlevel! == 0 ( echo ERROR: direct-mode dependency install failed. & pause & exit /b 1 )
)

echo.
echo [setup] Verifying ...
if "%DIRECT%"=="1" (
  "!VPY!" -c "from google import genai; import soundfile; print('OK (direct mode)')"
) else (
  "!VPY!" -c "import ssl, wave, urllib.request; print('OK (thin client)')"
)
if not !errorlevel! == 0 ( echo ERROR: verification failed - dependencies did not import. & pause & exit /b 1 )

rem Remember the install mode, so update.bat (and the Lua bootstrapper) keep
rem direct-mode installs direct across updates and venv rebuilds.
if "%DIRECT%"=="1" ( type nul > ".direct-mode" ) else ( del ".direct-mode" 2>nul )

rem ── bundled dubbing app: set it up too, so the one-window app works
rem    end-to-end right after install (venv + deps + ffmpeg, no prompts).
rem    Flat flow, NOT a parenthesized block: the sub-script cd's into
rem    dubbing\, and the "cd /d" that restores our directory below must not
rem    expand a project path inside a block — a folder named
rem    "fast-syncs-main (1)" would close the block on its ")".
if not exist ".\dubbing\setup_windows.bat" goto no_dubbing
echo.
echo [setup] Setting up the bundled dubbing app ^(can take a few minutes^)...
call ".\dubbing\setup_windows.bat" --auto
if errorlevel 1 echo WARNING: dubbing setup reported a problem - run dubbing\setup_windows.bat manually.
rem cmd.exe re-reads THIS file from disk as it runs: returning from a sub-script
rem in a different working directory corrupts everything after this line.
cd /d "%~dp0"

:no_dubbing

echo.
echo Setup complete. You can now run auto_sync_pipeline.lua in Reaper.
pause
exit /b 0


rem ── helpers ───────────────────────────────────────────────────

:try_python
rem Probe a command (all args, e.g. "py -3") as a working Python 3.9+.
rem The assert is written WITHOUT parentheses on purpose: a ")" inside a
rem parenthesized for-block (see :try_userdir) can prematurely close it on
rem some cmd.exe versions, so we keep the same paren-free form everywhere.
%* -c "import sys; assert sys.version_info[0]==3 and sys.version_info[1]>=9" >nul 2>&1 && set "PYEXE=%*"
exit /b 0

:try_userdir
rem Per-user python.org installs live here and are NOT on a console's PATH
rem that was opened before the install (PATH is read once at launch).
for /d %%D in ("!LOCALAPPDATA!\Programs\Python\Python3*") do (
  if not defined PYEXE (
    "%%D\python.exe" -c "import sys; assert sys.version_info[0]==3 and sys.version_info[1]>=9" >nul 2>&1 && set "PYEXE="%%D\python.exe""
  )
)
exit /b 0

:try_progfiles
rem All-users installs (python.org "for all users", winget run elevated)
rem live under Program Files — also invisible to an already-open console.
rem !ProgramFiles! (delayed), not %ProgramFiles%: a 32-bit shell expands it to
rem "C:\Program Files (x86)", whose ")" would close this block early.
for /d %%D in ("!ProgramFiles!\Python3*") do (
  if not defined PYEXE (
    "%%D\python.exe" -c "import sys; assert sys.version_info[0]==3 and sys.version_info[1]>=9" >nul 2>&1 && set "PYEXE="%%D\python.exe""
  )
)
exit /b 0

:offer_winget
where winget >nul 2>&1
if errorlevel 1 exit /b 0
echo.
echo Python 3 was not found on this PC.
choice /c YN /m "Install Python 3.12 automatically now via winget"
if errorlevel 2 exit /b 0
echo [setup] Installing Python 3.12 - this can take a few minutes ...
winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
if errorlevel 1 (
  echo [setup] winget install failed or was cancelled.
  exit /b 0
)
rem The fresh install is not on THIS console's PATH yet - probe known spots.
call :try_python py -3.12
if not defined PYEXE call :try_python py -3
if not defined PYEXE call :try_userdir
if not defined PYEXE call :try_progfiles
if not defined PYEXE call :try_python python
exit /b 0

:no_python
echo ERROR: No working Python 3.9+ was found ^(3.11+ recommended^).
echo.
echo The "python" on your PATH may be the Microsoft Store placeholder
echo alias, not a real install.
echo.
echo Install Python from https://www.python.org/downloads/ and tick
echo "Add python.exe to PATH" during install, then re-run this file.
pause
exit /b 1
