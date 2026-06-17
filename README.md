# Fast Syncs — Auto Sync Pipeline for REAPER

One-click dubbing sync for [REAPER](https://www.reaper.fm/). It reads your
**Dialogue VO** and **Dub** tracks, transcribes + AI-matches every clip by
meaning, and snaps each dubbed clip to the position of the English line it
corresponds to. Unmatched clips are parked on an **Un sync** track for manual
cleanup.

Works on **Windows** and **macOS**. The instructions below are Windows-first.

---

## What's in here

| File | What it does |
|---|---|
| `auto_sync_pipeline.lua` | The REAPER ReaScript you run. The only file you load in REAPER. |
| `Sync_Item.lua` | Helper ReaScript: align the clip under the mouse to the selected clip. |
| `sync_matcher.py` | The Python worker (transcribe + AI match). Started for you — don't run it by hand. |
| `run_sync.py` | Cross-platform launcher the Lua script calls. |
| `setup.bat` / `setup.sh` | One-time installer (creates the Python virtualenv). |
| `update.bat` / `update.sh` | Pull the latest version + refresh dependencies. |
| `requirements*.txt` | Python dependencies (tiny for the default thin-client mode). |

---

## Install on Windows

1. **Install Python 3.11+** from <https://www.python.org/downloads/>.
   During install, tick **"Add python.exe to PATH"**.
2. **Get the files**: download this repo as a ZIP (green *Code* button →
   *Download ZIP*) and unzip it, **or** `git clone` it.
3. **Double-click `setup.bat`.** It creates a `venv` folder and installs the
   dependencies. Wait for `Setup complete`, then close the window.
   - Default install is the lightweight **thin client** (runs through a server).
   - Calling the AI providers directly from this PC? Run from a terminal
     instead: `setup.bat --direct`
4. **Load the script in REAPER**: *Actions → Show action list → New action →
   Load ReaScript…* → pick `auto_sync_pipeline.lua` → **Run**.
   - First run shows a 3-step settings dialog (tracks, keys/server, script text).
   - If the `venv` is missing, the script offers to run `setup.bat` for you.

## Install on macOS

```bash
bash setup.sh           # thin client (default)
bash setup.sh --direct  # if this Mac calls the AI providers directly
```

Then load `auto_sync_pipeline.lua` in REAPER the same way as above.

---

## Updating

- **Windows:** double-click `update.bat`
- **macOS:** `bash update.sh`

Both `git pull` the latest version (if it's a git clone) and refresh the Python
dependencies in `venv`. If you downloaded a ZIP instead of cloning, re-download
the ZIP to update.

---

## Two ways to run

- **Thin client (default).** Set a **Server URL** + **access token** in the
  settings dialog. All AI calls route through your server, which holds the real
  provider keys — nothing secret lives on the editor's machine, and the install
  stays tiny (standard library only).
- **Direct mode.** Leave the Server URL blank and provide your own keys
  (ElevenLabs and/or Gemini, or a Vertex `vertex_key.json` next to the script).
  Run `setup.bat --direct` / `setup.sh --direct` so the heavier libraries
  (`google-genai`, `soundfile`) are installed.

Settings are saved to `sync_pipeline_settings.json` next to the script. That
file holds your keys and is **gitignored** — it never gets committed.

---

## Troubleshooting

- **"Python 3 not found" (Windows).** Reinstall Python and tick *Add
  python.exe to PATH*, then re-run `setup.bat`.
- **Track not found.** Track names must match exactly, including capital
  letters (`Dialogue VO`, `Dub`).
- **HTTPS / certificate errors on a corporate network** (Zscaler, Netskope,
  Defender, ESET…). The default install includes `truststore`, which routes TLS
  through the OS certificate store and fixes most SSL-inspection-proxy errors
  automatically. No action needed.
- **It failed — where are the logs?** Full output is written to
  `sync_python_log.txt` next to the script, and also streamed live into
  REAPER's console while it runs.

---

## Requirements

- REAPER (any recent version)
- Python 3.11 or newer
- For direct mode only: outbound HTTPS to your chosen AI provider
