#!/usr/bin/env python3
"""
Cross-platform launcher for sync_matcher.py.

Reaper's Lua front-end used to build an OS-specific shell command to:
  - inline-set SYNC_* environment variables (POSIX-only `VAR=val cmd` syntax),
  - redirect output to a log file and capture the exit code with `( ... ) &`
    (bash-only), and
  - background the process.
None of that worked on Windows (cmd.exe). This launcher does all of it in
plain Python so the behaviour is identical on macOS and Windows. The Lua side
now only has to start this script in the background (`... &` vs `start /b`).

Responsibilities:
  1. Read provider keys + selections from sync_pipeline_settings.json
     (gitignored, same folder). Secrets never travel on the command line.
  2. Map them to the SYNC_* environment the matcher expects.
  3. Run sync_matcher.py, teeing its stdout/stderr to sync_python_log.txt.
  4. Write the worker's exit code to sync_python_done.txt so the Lua poller
     knows it finished.

Usage (from Lua):
    python run_sync.py <script_dir> [--language ne] [--mode gemini] [--asr elevenlabs]

CLI flags override settings.json; settings.json overrides inherited env.
"""

import os
import sys
import json
import argparse
import subprocess
import traceback
from pathlib import Path


# Warnings raised before the log file is open. We can't print() them: when
# REAPER launches this script detached (no console), stdout may be an invalid
# handle on Windows and print() itself would crash the launcher.
_EARLY_WARNINGS = []


def _load_settings(script_dir: Path) -> dict:
    """Read the flat JSON settings file. Returns {} if missing/unreadable."""
    path = script_dir / "sync_pipeline_settings.json"
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except FileNotFoundError:
        return {}
    except Exception as e:
        _EARLY_WARNINGS.append(f"[run_sync] WARNING: could not parse settings.json: {e}")
        return {}


def _build_env(settings: dict) -> dict:
    """Start from the inherited environment, then let non-empty settings win."""
    env = os.environ.copy()

    # Force UTF-8 for the worker's stdout/stderr. The matcher prints box-drawing
    # and check-mark characters (✓ → ── …). On Windows, redirected output (our
    # log file) defaults to the legacy ANSI code page (cp1252), so those prints
    # raise UnicodeEncodeError and kill the run. PYTHONUTF8/PYTHONIOENCODING make
    # the child emit UTF-8 on every OS, matching the utf-8 log file we open below.
    env["PYTHONUTF8"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"

    def put(env_name, value):
        if value is not None and str(value).strip() != "":
            env[env_name] = str(value)

    put("SYNC_ELEVENLABS_KEY", settings.get("elevenlabs_key"))
    put("SYNC_GEMINI_KEY",     settings.get("gemini_key"))
    put("SYNC_GEMINI_BACKEND", settings.get("gemini_backend"))
    put("SYNC_GEMINI_MODEL",   settings.get("gemini_model"))
    # OpenAI-compatible gateway base URL (used when gemini_backend == "gateway").
    put("SYNC_GEMINI_BASE_URL", settings.get("gemini_base_url"))

    # Thin-client / server proxy: when these are set the matcher routes every
    # provider call through the server and needs no local keys at all.
    put("SYNC_API_BASE",  settings.get("api_base"))
    put("SYNC_API_TOKEN", settings.get("api_token"))

    # Custom Vertex service-account JSON (only used in direct mode).
    vkey = (settings.get("vertex_key_path") or "").strip()
    if vkey:
        env["GOOGLE_APPLICATION_CREDENTIALS"] = vkey

    # Matching is always Gemini — OpenAI/Anthropic matcher options are not
    # exposed in the Reaper UI.
    env["SYNC_MATCHER_PROVIDER"] = "gemini"
    return env


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("script_dir", help="Folder containing sync_matcher.py + settings")
    ap.add_argument("--language", default=None)
    ap.add_argument("--mode",     default=None)
    ap.add_argument("--asr",      default=None)
    args = ap.parse_args()

    script_dir = Path(args.script_dir).expanduser().resolve()
    matcher    = script_dir / "sync_matcher.py"
    config     = script_dir / "sync_config.json"
    log_path   = script_dir / "sync_python_log.txt"
    done_path  = script_dir / "sync_python_done.txt"
    pid_path   = script_dir / "sync_python_pid.txt"

    settings = _load_settings(script_dir)

    # Resolve selections: CLI flag > settings.json > built-in default.
    language = args.language or settings.get("language")   or "ne"
    mode     = args.mode     or settings.get("match_mode") or "gemini"
    # Gemini semantic matching is the only supported mode — a legacy
    # settings.json (or stray CLI flag) must not resurrect hybrid/duration.
    if mode != "gemini":
        _EARLY_WARNINGS.append(
            f"[run_sync] WARNING: match mode '{mode}' is no longer supported "
            "— forcing 'gemini'")
        mode = "gemini"
    asr      = args.asr      or settings.get("asr_provider") or "elevenlabs"
    if asr not in ("elevenlabs", "gemini"):
        asr = "elevenlabs"

    env = _build_env(settings)

    # Open the log fresh (truncate) so the Lua poller sees only this run.
    log_file = open(log_path, "w", encoding="utf-8")
    for w in _EARLY_WARNINGS:
        log_file.write(w + "\n")
    log_file.flush()
    exit_code = 1
    try:
        if not matcher.exists():
            log_file.write(f"[run_sync] ERROR: sync_matcher.py not found at {matcher}\n")
            log_file.flush()
            return 1

        cmd = [
            sys.executable, "-u", str(matcher),
            "--config",   str(config),
            "--language", language,
            "--mode",     mode,
            "--asr",      asr,
        ]
        log_file.write(f"[run_sync] launching: {' '.join(cmd)}\n")
        log_file.flush()

        # Child writes directly to the log fd → live, unbuffered output.
        # CREATE_NO_WINDOW: if this launcher was started with no console
        # (REAPER's ExecProcess / a detached start), a console-subsystem
        # child would otherwise allocate its own visible console window.
        kwargs = {}
        if os.name == "nt":
            kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
        else:
            # New session so the whole worker tree can be signalled at once if
            # the UI's Cancel button kills the process group.
            kwargs["start_new_session"] = True
        # Popen (not run) so we can publish the worker PID immediately — the
        # Reaper UI's Cancel button reads sync_python_pid.txt to stop the run.
        proc = subprocess.Popen(
            cmd,
            cwd=str(script_dir),
            stdout=log_file,
            stderr=subprocess.STDOUT,
            env=env,
            **kwargs,
        )
        try:
            with open(pid_path, "w", encoding="utf-8") as pf:
                pf.write(str(proc.pid))
        except Exception:
            pass
        proc.wait()
        exit_code = proc.returncode
    except Exception:
        try:
            log_file.write("\n[run_sync] launcher crashed:\n")
            log_file.write(traceback.format_exc())
            log_file.flush()
        except Exception:
            pass
        exit_code = 1
    finally:
        try:
            log_file.close()
        except Exception:
            pass
        # Always write the done marker so the Lua poller never hangs.
        try:
            with open(done_path, "w", encoding="utf-8") as df:
                df.write(str(exit_code))
        except Exception:
            pass
        # The worker is gone — drop the stale PID file so a later Cancel can't
        # signal an unrelated, recycled PID.
        try:
            os.remove(pid_path)
        except OSError:
            pass

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
