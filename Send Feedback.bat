@echo off
rem Double-click to send feedback (message + screenshots) to the developer.
cd /d "%~dp0"
set "PY=python"
if exist ".venv\Scripts\python.exe" set "PY=.venv\Scripts\python.exe"
if exist "venv\Scripts\python.exe"  set "PY=venv\Scripts\python.exe"
"%PY%" app_feedback.py --gui --app "Fast Syncs"
if errorlevel 1 (
  echo.
  echo Could not start the feedback tool. If Python is not installed yet,
  echo run setup.bat first, then double-click this file again.
  pause
)
