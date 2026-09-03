#!/usr/bin/env python3
"""Start a command detached with no console window, then exit immediately.

Why this exists
---------------
The panel launches background helpers with `reaper.ExecProcess(cmd, -2)`.
That detaches the child, but it does NOT suppress the child's console: any
console-subsystem exe (cmd.exe, curl.exe, powershell.exe) gets its own window
that sits on top of REAPER for as long as it runs — up to the full curl
timeout. Everything those helpers produce is read back from a file by the
panel, so the window is pure noise.

REAPER creates no console for a GUI-subsystem exe, and pythonw.exe is exactly
that: the same interpreter as python.exe, built without a console. So the
panel calls

    pythonw.exe hidden_run.py <thing>

and this script re-launches <thing> with CREATE_NO_WINDOW. Net result: no
window at any point in the chain.

Usage
-----
    pythonw.exe hidden_run.py <script.bat|script.cmd>   # run via cmd.exe /C
    pythonw.exe hidden_run.py <exe> [args...]           # run directly

Exits as soon as the child is spawned — it never waits for it. Nothing is
printed: under pythonw.exe there is nowhere to print to.
"""

import os
import subprocess
import sys

# subprocess.CREATE_NO_WINDOW only exists on Windows.
_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def main(argv):
    if not argv:
        return 2

    target = argv[0]
    if target.lower().endswith((".bat", ".cmd")):
        # A batch file needs an interpreter. COMSPEC honours a non-standard
        # Windows install; cmd.exe is the fallback.
        cmd = [os.environ.get("COMSPEC") or "cmd.exe", "/C", target] + argv[1:]
    else:
        cmd = list(argv)

    kwargs = {}
    if os.name == "nt":
        kwargs["creationflags"] = _NO_WINDOW
    else:
        # Not the intended platform (REAPER's os.execute already backgrounds
        # helpers on macOS/Linux), but keep the child out of our process group
        # so it survives this script exiting.
        kwargs["start_new_session"] = True

    # No inherited std handles: the child must not hold a pipe to REAPER, and
    # anything it writes is unread by design.
    subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        **kwargs,
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception:
        # Under pythonw.exe a traceback has nowhere to go and an unhandled
        # exception would pop a Windows error dialog — the very thing this
        # script exists to avoid. Fail silently; the caller times out.
        sys.exit(1)
