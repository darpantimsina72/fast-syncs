#!/usr/bin/env python3
"""Offline checks for the in-app "Send report" path (app_feedback.py).

Guards three promises made to the user:
  1. API keys never leave the machine — known settings values and common key
     shapes are scrubbed from the log and the message.
  2. No endpoint / no network → the report is kept in feedback_outbox/pending
     and a .result file tells the panel "saved", never a crash.
  3. With an endpoint, the report is posted once, and queued reports are
     flushed first.

No network: _urlopen is replaced. Run:  python3 tests/test_feedback_report.py
"""
import io
import json
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import app_feedback as fb  # noqa: E402

FAILS = []


def check(name, cond):
    print(("PASS  " if cond else "FAIL  ") + name)
    if not cond:
        FAILS.append(name)


# ── 1. scrubbing ─────────────────────────────────────────────
known = {"my-gateway-secret-123456"}
text = ("key=AIzaSyA1234567890abcdefghijklmnopqrstuv ok\n"
        "xi-api-key: sk_0123456789abcdef0123456789abcdef\n"
        "Authorization: Bearer abc.def.ghijklmnopqrstu\n"
        "url https://x.test/v1?key=SECRETVALUE&a=1\n"
        "gateway my-gateway-secret-123456 end\n"
        "नमस्ते stays\n")
out = fb.scrub_secrets(text, known)
check("google key removed", "AIzaSy" not in out)
check("elevenlabs key removed", "sk_0123" not in out)
check("bearer token removed", "abc.def.ghij" not in out)
check("?key= value removed", "SECRETVALUE" not in out)
check("known settings value removed", "my-gateway-secret" not in out)
check("indic text untouched", "नमस्ते stays" in out)

found = set()
fb._collect_secret_values({"gemini_api_key": "AIzaXXXXXXXXXXXX",
                           "language": "Hindi",
                           "nested": {"token": "abcdefghij"},
                           "script_path": "/a/b/c/key_file.json"}, found)
check("secret fields collected", {"AIzaXXXXXXXXXXXX", "abcdefghij"} <= found)
check("non-secret fields ignored", "Hindi" not in found)

# ── 2 + 3. send flow in a sandbox copy ───────────────────────
tmp = tempfile.mkdtemp()
try:
    log = os.path.join(tmp, "run.txt")
    with open(log, "w", encoding="utf-8") as f:
        f.write("STEP 1\nERROR boom AIzaSyA1234567890abcdefghijklmnopqrstuv\n")
    report = os.path.join(tmp, "report.json")
    with open(report, "w", encoding="utf-8") as f:
        json.dump({"kind": "run_report", "pipeline": "Auto Sync",
                   "status": "failed", "stars": 2, "message": "broke",
                   "log_path": log}, f)

    fb._outbox_dir = lambda: os.path.join(tmp, "outbox")
    fb._known_secrets = lambda: set()

    # No endpoint configured → saved.
    fb._endpoint = lambda: ""
    res = fb.send_report_file(report)
    check("no endpoint → saved", res.get("where") == "saved")
    with open(report + ".result", encoding="utf-8") as f:
        check("result file written", json.load(f).get("where") == "saved")
    queued = os.listdir(os.path.join(tmp, "outbox"))
    check("report queued", len(queued) == 1)
    with open(os.path.join(tmp, "outbox", queued[0]), encoding="utf-8") as f:
        q = json.load(f)
    check("queued log is scrubbed", "AIzaSy" not in q["log_text"]
          and "ERROR boom" in q["log_text"])

    # Endpoint works → queued one flushed first, then this one.
    posted = []

    class _Resp(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def fake_urlopen(req, timeout=60):
        posted.append(json.loads(req.data.decode("utf-8")))
        return _Resp(b'{"ok": true, "error": ""}')

    fb._endpoint = lambda: "https://script.google.com/macros/s/X/exec"
    fb._urlopen = fake_urlopen
    res = fb.send_report_file(report)
    check("endpoint → sent", res.get("ok") is True)
    check("queue flushed + new report posted", len(posted) == 2)
    check("outbox empty afterwards", os.listdir(os.path.join(tmp, "outbox")) == [])
    check("stars travel", posted[-1]["stars"] == 2)

    # Endpoint refuses → saved, not crashed.
    fb._urlopen = lambda req, timeout=60: _Resp(b'{"ok": false, "error": "bad team code"}')
    res = fb.send_report_file(report)
    check("refused → saved with reason", res.get("where") == "saved"
          and "bad team code" in res.get("error", ""))

    # Broken report file → "failed", still a result file.
    with open(report, "w") as f:
        f.write("{not json")
    res = fb.send_report_file(report)
    check("unreadable report → failed, no crash", res.get("where") == "failed")
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print("\nRED: %d check(s) failed" % len(FAILS) if FAILS
      else "\nGREEN: all checks passed")
sys.exit(1 if FAILS else 0)
