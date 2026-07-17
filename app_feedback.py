"""app_feedback.py — drop-in feedback sender (message + screenshots → GitHub issue).

Shared across all of Darpan's apps: every report lands as an issue on ONE
private inbox repo (FEEDBACK_REPO below), labeled with the app's name, so
there is a single place to watch. Screenshots are committed to that repo's
`feedback` branch and linked from the issue.

Security: the token distributed with installs only needs access to the
dedicated inbox repo — it can never alter any app's code.

Token lookup (first hit wins):
  1. $GITHUB_FEEDBACK_TOKEN environment variable
  2. github_token.txt next to the app (script/executable directory)
  3. github_token.txt in the user config dir (AppFeedback folder)

Fine-grained PAT scoped to only the inbox repo, permissions:
Issues: Read & write + Contents: Read & write.

Offline / no-token fallback: feedback is saved to feedback_outbox/<stamp>/
next to the app so the user can send the folder manually.

Usage — tkinter GUI apps:
    import app_feedback
    app_feedback.open_feedback_dialog(root, app_name="My App", app_version="1.0")

Usage — servers / scripts:
    url = app_feedback.send_feedback(app_name="My Tool", app_version="2.1",
                                     kind="Bug", sender="", message="...",
                                     attachments=["shot.png"])

CLI:
    python app_feedback.py --app "My Tool" [--attach shot.png] [--message "..."]

Stdlib only — no third-party dependencies.
"""

import base64
import json
import os
import re
import shutil
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

FEEDBACK_REPO = "darpantimsina72/app-feedback"   # owner/repo of the inbox
FEEDBACK_BRANCH = "feedback"                     # attachments branch
MAX_ATTACHMENT_MB = 20

_SSL_CTX = ssl._create_unverified_context()      # fallback for broken cert stores


def _app_dir() -> str:
    """Directory of the running app (works for scripts and frozen bundles)."""
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    main = sys.modules.get("__main__")
    main_file = getattr(main, "__file__", None)
    if main_file:
        return os.path.dirname(os.path.abspath(main_file))
    return os.path.dirname(os.path.abspath(__file__))


def _config_dir() -> str:
    if sys.platform == "win32":
        base = os.environ.get("APPDATA") or os.path.expanduser("~")
    elif sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support")
    else:
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "AppFeedback")


def _token() -> str:
    tok = os.environ.get("GITHUB_FEEDBACK_TOKEN", "").strip()
    if tok:
        return tok
    for d in (_app_dir(), os.path.dirname(os.path.abspath(__file__)), _config_dir()):
        p = os.path.join(d, "github_token.txt")
        try:
            with open(p, encoding="utf-8") as f:
                tok = f.read().strip()
            if tok:
                return tok
        except OSError:
            pass
    return ""


def _api(url: str, payload=None, method: str = "GET") -> dict:
    """Minimal GitHub REST call. Raises urllib.error.HTTPError on 4xx/5xx."""
    h = {"User-Agent": "AppFeedback",
         "Accept": "application/vnd.github+json"}
    tok = _token()
    if tok:
        h["Authorization"] = "token " + tok
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.URLError as e:
        # Corporate proxies / broken cert stores: retry without verification.
        if isinstance(getattr(e, "reason", None), ssl.SSLError):
            with urllib.request.urlopen(req, timeout=60, context=_SSL_CTX) as r:
                return json.loads(r.read().decode("utf-8"))
        raise


def _ensure_branch():
    base = "https://api.github.com/repos/" + FEEDBACK_REPO
    try:
        _api(base + "/git/ref/heads/" + FEEDBACK_BRANCH)
        return
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
    default = _api(base).get("default_branch") or "main"
    head = _api(base + "/git/ref/heads/" + default)
    _api(base + "/git/refs", method="POST", payload={
        "ref": "refs/heads/" + FEEDBACK_BRANCH,
        "sha": head["object"]["sha"],
    })


def _upload_attachment(path: str, stamp: str, app_slug: str) -> str:
    fn = re.sub(r"[^\w.\-]+", "_", os.path.basename(path)) or "attachment"
    with open(path, "rb") as f:
        blob = f.read()
    dest = "feedback_attachments/%s/%s_%s" % (app_slug, stamp, fn)
    url = ("https://api.github.com/repos/" + FEEDBACK_REPO + "/contents/"
           + urllib.parse.quote(dest))
    resp = _api(url, method="PUT", payload={
        "message": "Feedback attachment (%s, %s)" % (app_slug, stamp),
        "content": base64.b64encode(blob).decode("ascii"),
        "branch": FEEDBACK_BRANCH,
    })
    return (resp.get("content") or {}).get("html_url") or (
        "https://github.com/%s/blob/%s/%s" % (FEEDBACK_REPO, FEEDBACK_BRANCH, dest))


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", (name or "app").lower()).strip("-")


def send_feedback(app_name: str, app_version: str, kind: str, sender: str,
                  message: str, attachments=None,
                  progress=None) -> str:
    """Upload attachments + file the issue. Returns the issue URL.
    Raises on failure (caller decides whether to fall back to save_locally).
    `progress` is an optional callable(str) for status updates."""
    import datetime
    attachments = attachments or []
    notify = progress or (lambda s: None)
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    slug = _slug(app_name)

    links = []
    if attachments:
        notify("Uploading screenshots…")
        _ensure_branch()
        for p in attachments:
            links.append((os.path.basename(p), _upload_attachment(p, stamp, slug)))

    notify("Creating report…")
    first_line = (message.strip().splitlines() or ["(no message)"])[0][:60]
    title = "[%s] [%s] %s" % (app_name, kind, first_line)
    body = ("**App:** %s v%s · %s · Python %s\n"
            "**Type:** %s\n"
            "**From:** %s\n\n---\n\n%s\n"
            % (app_name, app_version, sys.platform, sys.version.split()[0],
               kind, sender or "(not given)", message))
    if links:
        body += "\n---\n\n**Screenshots:**\n" + "\n".join(
            "- [%s](%s)" % (n, u) for n, u in links)
    resp = _api("https://api.github.com/repos/" + FEEDBACK_REPO + "/issues",
                method="POST",
                payload={"title": title, "body": body,
                         "labels": [slug, kind.lower(), "in-app-feedback"]})
    return resp.get("html_url", "")


def save_locally(app_name: str, app_version: str, kind: str, sender: str,
                 message: str, attachments=None) -> str:
    """Offline fallback: bundle everything into feedback_outbox/<stamp>/."""
    import datetime
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    folder = os.path.join(_app_dir(), "feedback_outbox", stamp)
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "message.txt"), "w", encoding="utf-8") as f:
        f.write("App:  %s v%s · %s\nType: %s\nFrom: %s\nDate: %s\n\n%s\n"
                % (app_name, app_version, sys.platform, kind,
                   sender or "(not given)", stamp, message))
    for p in (attachments or []):
        try:
            shutil.copy2(p, os.path.join(folder, os.path.basename(p)))
        except OSError:
            pass
    return folder


# ── Optional tkinter dialog (imported lazily so servers never need tk) ────────

_DEFAULT_THEME = {
    "bg":       "#111827",   # panel
    "bg2":      "#1f2937",   # inset panel
    "fg":       "#e2e8f0",
    "fg_faint": "#64748b",
    "accent":   "#34d399",
    "entry_bg": "#e2e8f0",
    "entry_fg": "#0f172a",
    "send_bg":  "#2563eb",
    "font":     None,        # filled below per-platform
}


def open_feedback_dialog(root=None, app_name="App", app_version="",
                         theme=None, on_close=None):
    """Open the feedback dialog. Pass an existing Tk root/window as `root`;
    with root=None a standalone window is created (blocks until closed)."""
    import threading
    import tkinter as tk
    from tkinter import filedialog, messagebox, scrolledtext

    th = dict(_DEFAULT_THEME)
    th.update(theme or {})
    if not th["font"]:
        th["font"] = ("Consolas" if sys.platform == "win32"
                      else "Menlo" if sys.platform == "darwin"
                      else "DejaVu Sans Mono")
    F = th["font"]

    standalone = root is None
    if standalone:
        root = tk.Tk()
        root.withdraw()

    dlg = tk.Toplevel(root)
    dlg.title("Send Feedback — %s" % app_name)
    dlg.configure(bg=th["bg"])
    dlg.resizable(False, False)

    tk.Label(dlg, text="Share feedback, ideas or bug reports",
             bg=th["bg"], fg=th["fg"], font=(F, 11, "bold")
             ).pack(anchor="w", padx=14, pady=(12, 2))
    tk.Label(dlg, text="Sent straight to the developer — screenshots welcome.",
             bg=th["bg"], fg=th["fg_faint"], font=(F, 9)
             ).pack(anchor="w", padx=14, pady=(0, 8))

    kind_var = tk.StringVar(value="Feedback")
    kind_row = tk.Frame(dlg, bg=th["bg"])
    kind_row.pack(anchor="w", padx=14)
    for label in ("💬 Feedback", "💡 Improvement", "🐞 Bug"):
        tk.Radiobutton(kind_row, text=label, variable=kind_var,
                       value=label.split(" ", 1)[1],
                       bg=th["bg"], fg=th["fg"], selectcolor=th["bg2"],
                       activebackground=th["bg"], activeforeground=th["accent"],
                       font=(F, 9), cursor="hand2").pack(side="left", padx=(0, 12))

    name_row = tk.Frame(dlg, bg=th["bg"])
    name_row.pack(fill="x", padx=14, pady=(8, 0))
    tk.Label(name_row, text="Your name (optional):", bg=th["bg"],
             fg=th["fg_faint"], font=(F, 9)).pack(side="left")
    name_entry = tk.Entry(name_row, bg=th["entry_bg"], fg=th["entry_fg"],
                          font=(F, 9), width=28, relief="flat")
    name_entry.pack(side="left", padx=(6, 0), ipady=2)

    msg_box = scrolledtext.ScrolledText(
        dlg, bg=th["bg2"], fg=th["fg"], insertbackground=th["fg"],
        font=(F, 10), wrap="word", width=64, height=9)
    msg_box.pack(fill="both", expand=True, padx=14, pady=(8, 4))
    msg_box.focus_set()

    attachments = []
    attach_lbl = tk.Label(dlg, text="No screenshots attached.", bg=th["bg"],
                          fg=th["fg_faint"], font=(F, 8),
                          anchor="w", justify="left")

    def _refresh():
        attach_lbl.config(text=("Attached: " + ", ".join(
            os.path.basename(p) for p in attachments))
            if attachments else "No screenshots attached.")

    def _add():
        for p in filedialog.askopenfilenames(
                parent=dlg, title="Attach screenshot(s)",
                filetypes=[("Images", "*.png *.jpg *.jpeg *.gif *.bmp"),
                           ("All files", "*.*")]):
            try:
                mb = os.path.getsize(p) / (1024 * 1024)
            except OSError:
                continue
            if mb > MAX_ATTACHMENT_MB:
                messagebox.showwarning(
                    "File Too Large",
                    "%s is %.0f MB — the limit is %d MB per file."
                    % (os.path.basename(p), mb, MAX_ATTACHMENT_MB), parent=dlg)
                continue
            if p not in attachments:
                attachments.append(p)
        _refresh()

    attach_row = tk.Frame(dlg, bg=th["bg"])
    attach_row.pack(fill="x", padx=14)
    tk.Button(attach_row, text="📎 Attach Screenshot(s)", command=_add,
              bg=th["bg2"], fg=th["fg"], activebackground=th["bg2"],
              activeforeground=th["accent"], font=(F, 9),
              cursor="hand2", relief="flat", padx=8).pack(side="left", pady=2)
    tk.Button(attach_row, text="Clear",
              command=lambda: (attachments.clear(), _refresh()),
              bg=th["bg2"], fg=th["fg"], activebackground=th["bg2"],
              activeforeground=th["accent"], font=(F, 9),
              cursor="hand2", relief="flat", padx=8
              ).pack(side="left", padx=(6, 0), pady=2)
    attach_lbl.pack(fill="x", padx=14, pady=(2, 0))

    status_lbl = tk.Label(dlg, text="", bg=th["bg"], fg=th["fg_faint"],
                          font=(F, 9), anchor="w")
    status_lbl.pack(fill="x", padx=14, pady=(4, 0))

    def _close():
        dlg.destroy()
        if standalone:
            root.destroy()
        if on_close:
            on_close()

    btn_row = tk.Frame(dlg, bg=th["bg"])
    btn_row.pack(fill="x", padx=14, pady=(6, 12))
    send_btn = tk.Button(btn_row, text="Send  ➤", bg=th["send_bg"], fg="white",
                         activebackground=th["bg2"],
                         activeforeground=th["accent"],
                         font=(F, 9, "bold"), cursor="hand2",
                         relief="flat", padx=14)
    send_btn.pack(side="right")
    tk.Button(btn_row, text="Cancel", command=_close,
              bg=th["bg2"], fg=th["fg"], activebackground=th["bg2"],
              activeforeground=th["accent"], font=(F, 9),
              cursor="hand2", relief="flat", padx=10
              ).pack(side="right", padx=(0, 8))

    def _worker(kind, sender, message, files):
        try:
            url = send_feedback(
                app_name, app_version, kind, sender, message, files,
                progress=lambda s: root.after(0, status_lbl.config, {"text": s}))

            def _done():
                _close()
                messagebox.showinfo(
                    "Feedback Sent",
                    "Thank you! Your feedback was delivered to the developer."
                    + ("\n\nReference: " + url if url else ""))
            root.after(0, _done)
        except Exception as e:
            err = str(e)
            folder = ""
            try:
                folder = save_locally(app_name, app_version, kind,
                                      sender, message, files)
            except OSError:
                pass

            def _failed():
                send_btn.config(state="normal")
                status_lbl.config(text="")
                messagebox.showerror(
                    "Could Not Send Feedback",
                    "Sending needs the github_token.txt file next to the app "
                    "and an internet connection.\n\nDetails: " + err
                    + ("\n\nYour feedback was saved to:\n" + folder +
                       "\nYou can send that folder to the developer manually."
                       if folder else ""), parent=dlg)
            root.after(0, _failed)

    def _send():
        message = msg_box.get("1.0", "end").strip()
        if not message:
            messagebox.showwarning("Empty Message",
                                   "Please write a message first.", parent=dlg)
            return
        send_btn.config(state="disabled")
        status_lbl.config(text="Sending…")
        threading.Thread(target=_worker,
                         args=(kind_var.get(), name_entry.get().strip(),
                               message, list(attachments)),
                         daemon=True).start()

    send_btn.config(command=_send)

    if standalone:
        dlg.protocol("WM_DELETE_WINDOW", _close)
        root.mainloop()
    return dlg


# ── CLI ───────────────────────────────────────────────────────────────────────

def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(
        description="Send feedback (message + screenshots) to the developer.")
    ap.add_argument("--app", default="App", help="application name")
    ap.add_argument("--app-version", default="", help="application version")
    ap.add_argument("--kind", default="Feedback",
                    choices=["Feedback", "Improvement", "Bug"])
    ap.add_argument("--name", default="", help="your name (optional)")
    ap.add_argument("--message", default="", help="feedback text; prompts if omitted")
    ap.add_argument("--attach", action="append", default=[],
                    metavar="FILE", help="screenshot to attach (repeatable)")
    ap.add_argument("--gui", action="store_true",
                    help="open the graphical feedback dialog instead")
    args = ap.parse_args(argv)

    if args.gui:
        open_feedback_dialog(None, app_name=args.app,
                             app_version=args.app_version)
        return 0

    message = args.message
    if not message:
        print("Type your feedback, end with an empty line:")
        lines = []
        while True:
            try:
                line = input()
            except EOFError:
                break
            if not line and lines:
                break
            lines.append(line)
        message = "\n".join(lines).strip()
    if not message:
        print("No message — nothing sent.")
        return 1

    try:
        url = send_feedback(args.app, args.app_version, args.kind,
                            args.name, message, args.attach,
                            progress=lambda s: print("  " + s))
        print("Feedback sent." + (" Reference: " + url if url else ""))
        return 0
    except Exception as e:
        folder = save_locally(args.app, args.app_version, args.kind,
                              args.name, message, args.attach)
        print("Could not reach GitHub (%s).\nFeedback saved to: %s\n"
              "Send that folder to the developer manually." % (e, folder))
        return 1


if __name__ == "__main__":
    sys.exit(main())
