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

1. **Get the files**: download this repo as a ZIP (green *Code* button →
   *Download ZIP*) and unzip it, **or** `git clone` it.
2. **Double-click `setup.bat`.** It creates a `venv` folder and installs the
   dependencies. Wait for `Setup complete`, then close the window.
   - **No Python on the PC?** `setup.bat` detects that and offers to install
     Python 3.12 for you automatically (via winget, built into Windows 10/11) —
     just press **Y**. Manual alternative: install from
     <https://www.python.org/downloads/> and tick **"Add python.exe to PATH"**.
   - Default install is the lightweight **thin client** (runs through a server).
   - Calling the AI providers directly from this PC? Open a terminal in the
     unzipped folder (Windows 11: right-click the folder background → *Open in
     Terminal*; Windows 10: Shift+right-click → *Open PowerShell window here*)
     and run: `.\setup.bat --direct`
3. **Load the script in REAPER**: *Actions → Show action list → New action →
   Load ReaScript…* → pick `auto_sync_pipeline.lua` → **Run**.
   - **Missing ReaImGui?** (free — the settings/progress window uses it): the
     script sets it up for you.
     - No ReaPack yet either? It offers to **download ReaPack automatically**
       (official extension, into REAPER's `UserPlugins` folder) — click *Yes*,
       restart REAPER, run the script again.
     - With ReaPack present, it offers to install ReaImGui **automatically** —
       click *Yes*, then *Install* → *Apply* in the package browser it opens,
       and restart REAPER once more.
     - Manual route (if you prefer): *Extensions → ReaPack → Import
       repositories…*, paste
       `https://github.com/ReaTeam/Extensions/raw/master/index.xml`, then
       *Browse packages* → search **ReaImGui** → right-click → *Install* →
       *Apply* → restart REAPER.
   - A window opens with collapsible sections (tracks & mode, server, Gemini
     matcher, keys, script), a **Start Sync** button, a live progress bar with
     **Progress**/**Logs** tabs, and success/failure screens.
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

Easiest: click the **Update…** button at the bottom of the script's settings
window — it runs the updater for you in a terminal. Or run it yourself:

- **Windows:** double-click `update.bat`
- **macOS:** `bash update.sh`

The updater handles both install styles:

- **git clone** → `git pull` the latest version.
- **ZIP download** → downloads the latest ZIP from GitHub automatically and
  copies it over the folder. Your settings (`sync_pipeline_settings.json`),
  the `venv`, and the `.direct-mode` marker are untouched.

Either way it then refreshes the Python dependencies in `venv` (including the
direct-mode extras, if you installed with `--direct`). When it says
`Update complete`, re-run the script in REAPER.

If the automatic ZIP download ever fails (offline / repo moved), fall back to
manual: re-download the ZIP and unzip it **over** the old folder so your
settings and `venv` carry over.

---

## Connection mode — pick one

The **Connection** section of the settings window has a single **Mode**
dropdown. Pick one; only the fields that mode needs are shown.

| Mode | What it does | You provide | Best for |
|---|---|---|---|
| **Server — route through my proxy** | Every AI call goes to your server, which holds the real keys. Nothing secret lives on the editor's machine; the install stays tiny (standard library only). | **Server URL** + **Access token** | People you share this with |
| **Google AI Studio key** | Calls Gemini directly with a Google AI Studio key. | **Gemini key** (`AIza…`) | Quick personal setup |
| **Vertex — service-account JSON** | Calls Gemini through Google Cloud Vertex AI. | **Vertex JSON path**, or drop `vertex_key.json` next to the script | Google Cloud users |
| **LiteLLM gateway** | Calls an **OpenAI-compatible** base URL — the same value you'd paste into n8n's OpenAI node. Hits `{URL}/v1/chat/completions` with your Bearer key. | **Gateway URL** + **Gateway key** (Bearer, often `sk-…`) | Your own LiteLLM proxy |

The three direct modes (AI Studio / Vertex / gateway) need the heavier
libraries — run `.\setup.bat --direct` (Windows) / `bash setup.sh --direct`
(macOS) once so `google-genai` + `soundfile` are installed. Server mode stays
tiny and needs only the default install.

Settings are saved to `sync_pipeline_settings.json` next to the script. That
file holds your keys/token and is **gitignored** — it never gets committed.

### Using your LiteLLM gateway

The **LiteLLM gateway** mode is an OpenAI-compatible client — exactly like the
OpenAI node in n8n. Put your base URL in **Gateway URL** and your Bearer token
in **Gateway key**. Example base URL for a LiteLLM instance on a LAN:

```
http://172.18.1.17:14005
```

Plain `http://` on a local IP is fine (no TLS needed). The field is blank by
default — a LAN address only works from inside that network, so people you
share this with should use **Server** mode or their own key instead.

### Two things to know about matching vs. transcription

The pipeline runs **two** AI steps, and only one of them uses the mode above:

- **Matching** (aligning dub lines to English) is always Gemini, via the mode
  you picked. **No silent fallback** — if it fails (bad key, unreachable
  gateway, empty reply) the run stops with a visible error instead of a
  half-synced timeline.
- **Transcription** (audio → text) is a *separate* step set by **Transcribe
  with** in *Tracks & Mode*. It uses **ElevenLabs** (needs the ElevenLabs key)
  or **Google Gemini** — it can **not** go through the LiteLLM gateway (a
  chat-completions gateway can't take audio). So in gateway mode you still
  need an ElevenLabs key (or Google-native creds if you pick Gemini ASR).

**Match the key to the mode:** an `AIza…` key is Google-native (AI Studio);
an `sk-…` key is OpenAI-style and belongs to a gateway. Sending an `sk-…` key
to AI Studio returns HTTP 400 "API key not valid".

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
- [ReaImGui](https://github.com/cfillion/reaimgui) extension (free, via ReaPack) — the UI runs on it
- Python 3.9 or newer (3.11+ recommended)
- For direct mode only: outbound HTTPS to your chosen AI provider
