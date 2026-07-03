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
| `auto_sync_pipeline.lua` | The main ReaScript you load and run in REAPER. |
| `Sync_Item.lua` | Optional helper ReaScript: align the clip under the mouse to the selected clip. Load it in REAPER the same way if you want it. |
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
   - Calling the AI providers directly from this PC? Open a terminal in the
     unzipped folder (Windows 11: right-click the folder background → *Open in
     Terminal*; Windows 10: Shift+right-click → *Open PowerShell window here*)
     and run: `.\setup.bat --direct`
4. **Load the script in REAPER**: *Actions → Show action list → New action →
   Load ReaScript…* → pick `auto_sync_pipeline.lua` → **Run**.
   - First run shows a 3-step settings dialog (tracks, keys/server, script text).
   - If the `venv` is missing, the script offers to run `setup.bat` for you.
   - Optional: load `Sync_Item.lua` the same way for the one-clip manual
     align helper.

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
dependencies in `venv` (including the direct-mode extras, if you installed with
`--direct`). If you downloaded a ZIP instead of cloning, re-download the ZIP —
and note a fresh unzip does **not** carry over your saved settings or the
`venv`: either unzip **over** the old folder, or copy
`sync_pipeline_settings.json` from the old folder and run the update script
once to rebuild the `venv`. A `--direct` install rebuilt from a fresh unzip
also loses its `.direct-mode` marker — run `.\setup.bat --direct` /
`bash setup.sh --direct` again instead of the update script.

---

## Two ways to run

- **Thin client (default).** Set a **Server URL** + **access token** in the
  settings dialog. All AI calls route through your server, which holds the real
  provider keys — nothing secret lives on the editor's machine, and the install
  stays tiny (standard library only).
- **Direct mode.** Leave the Server URL blank and provide your own keys
  (ElevenLabs and/or Gemini, or a Vertex `vertex_key.json` next to the script).
  Run `.\setup.bat --direct` (Windows) / `bash setup.sh --direct` (macOS) so
  the heavier libraries (`google-genai`, `soundfile`) are installed.

Settings are saved to `sync_pipeline_settings.json` next to the script. That
file holds your keys and is **gitignored** — it never gets committed.

### Choosing the Gemini backend (matching)

The semantic matcher is always Gemini, but you choose **how** it's called via the
**Gemini backend** field in the settings dialog:

| Backend | When to use | Key format | Needs |
|---|---|---|---|
| `vertex` | You have a Google Cloud service account | service-account JSON | `vertex_key.json` next to the script (or a path in the dialog) |
| `rest` | You have a Google AI Studio key | `AIza...` | the key in the **Gemini key** field |
| `gateway` | Your org runs an OpenAI-compatible proxy that serves Gemini (e.g. an internal LiteLLM gateway) | Bearer token, often `sk-...` | **Gemini gateway URL** + the Bearer token in the **Gemini key** field |

- **`gateway`** calls `{gateway URL}/v1/chat/completions` with
  `Authorization: Bearer <key>` — the OpenAI Chat Completions contract — instead
  of Google's native endpoint.
- **Match the key to the backend:** an `AIza...` key is Google-native (`rest`);
  an `sk-...` key is OpenAI-style and belongs to a `gateway` (or real OpenAI).
  Sending an `sk-...` key to `rest` returns HTTP 400 "API key not valid".
- The gateway is used for **matching** (and hybrid-mode translation) only.
  Transcription (ASR) still uses ElevenLabs (default) or Google. If you pick
  *Transcribe with = gemini* together with the `gateway` backend, you still
  need Google-native credentials for the transcription step
  (`vertex_key.json` or an `AIza...` key) — the script stops with a clear
  error otherwise.

---

## Troubleshooting

- **"Python 3 not found" (Windows).** Reinstall Python and tick *Add
  python.exe to PATH*, then re-run `setup.bat`.
- **Track not found.** Track names must match exactly, including capital
  letters (`Dialogue VO`, `Dub`).
- **HTTPS / certificate errors on a corporate network** (Zscaler, Netskope,
  Defender, ESET…), e.g. `CERTIFICATE_VERIFY_FAILED ... Missing Authority Key
  Identifier`. Handled automatically in three layers: (1) the default install
  includes `truststore`, which routes TLS through the OS certificate store;
  (2) the client relaxes the strict Authority-Key-Identifier check that
  OpenSSL 3.x enforces; (3) if a cert *still* fails to verify (an inspection
  root that isn't in the trust store), the client prints a one-time `[SSL]`
  notice and retries with verification disabled for the rest of the run. No
  action needed. If transcripts come back empty and matches are all zero,
  it's almost always this — check the log for the `[SSL]` line.
- **It failed — where are the logs?** Full output is written to
  `sync_python_log.txt` next to the script, and also streamed live into
  REAPER's console while it runs.

---

## Requirements

- REAPER (any recent version)
- Python 3.9 or newer (3.11+ recommended)
- For direct mode only: outbound HTTPS to your chosen AI provider
