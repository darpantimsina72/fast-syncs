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
| `auto_sync_pipeline.lua` | **The only ReaScript you load in REAPER.** One window: sync *and* dubbing. |
| `scripts_optional/Sync_Item.lua` | Optional helper ReaScript: align the clip under the mouse to the selected clip. Load it the same way if you want it. |
| `sync_matcher.py` | The Python worker (transcribe + AI match). Started for you — don't run it by hand. |
| `run_sync.py` | Cross-platform launcher the Lua script calls. |
| `setup.bat` / `setup.sh` | One-time installer (creates the Python virtualenv). |
| `update.bat` / `update.sh` | Pull the latest version + refresh dependencies. |
| `requirements*.txt` | Python dependencies (tiny for the default thin-client mode). |
| `dubbing/` | **Bundled dubbing app**: translate + TTS + time-sync a voice recording into 12 Indian languages, driven from its own REAPER panel. See below. |

---

## Install on Windows

1. **Get the files**: download this repo as a ZIP (green *Code* button →
   *Download ZIP*) and unzip it, **or** `git clone` it.
2. **Double-click `setup.bat`.** It creates a `venv` folder and installs the
   dependencies. Wait for `Setup complete`, then close the window.
   - **"Windows protected your PC" / SmartScreen warning?** That's normal for
     files downloaded from the internet: click **More info → Run anyway**
     (or right-click `setup.bat` → *Properties* → tick *Unblock* → OK).
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
   - **One script, one window**: `auto_sync_pipeline.lua` is the only file you
     ever load. It opens the **Dub Pipeline** panel — the merged app — with the
     sync tool as its **Auto Sync** tab (collapsible sections, **Start Sync**,
     live progress with **Progress**/**Logs**) next to the dubbing tabs. Old
     toolbar buttons and actions that point at it keep working. Everything
     under `dubbing/reaper/` is internal: don't load it by hand.
   - If the `venv` is missing, the script offers to run `setup.bat` for you;
     the dubbing engine's own venv is created automatically on first open.
   - Optional: load `scripts_optional/Sync_Item.lua` the same way for the
     one-clip manual align helper.

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

**You now update to released versions, not to whatever was committed last.**
The updater downloads the newest published
[release](https://github.com/darpantimsina72/fast-syncs/releases) rather than
the tip of the `main` branch, so you only ever move to a version that was
deliberately shipped.

The updater handles both install styles:

- **ZIP download** → downloads the newest release's `fast-syncs.zip`
  automatically and copies it over the folder. Your settings
  (`sync_pipeline_settings.json`), the `venv`, and the `.direct-mode` marker
  are untouched.
- **git clone** → `git pull` on whatever branch your clone is on. If you
  cloned before releases existed you are on `main` and will keep getting
  development builds — switch once with `git checkout production`.

Either way it then refreshes the Python dependencies in `venv` (including the
direct-mode extras, if you installed with `--direct`) **and sets up the
bundled dubbing app automatically** — on the first update after the merge it
creates `dubbing/venv`, installs the engine dependencies and installs
**ffmpeg** if missing (no prompts); later updates just refresh them (fast).
When it says `Update complete`, re-run the script in REAPER — the same
button/action you always used now opens the merged one-window app.

If the automatic ZIP download ever fails (offline / repo moved), fall back to
manual: re-download the ZIP and unzip it **over** the old folder so your
settings and `venv` carry over.

### Going back to a previous version

If an update breaks something, download the `fast-syncs.zip` of an earlier
release from the
[Releases page](https://github.com/darpantimsina72/fast-syncs/releases) and
unzip it **over** your folder. Your settings and `venv` are preserved, exactly
as with a normal update.

To pin the updater itself to a specific release:

```bash
FAST_SYNCS_ZIP_URL=https://github.com/darpantimsina72/fast-syncs/releases/download/v0.13.0/fast-syncs.zip bash update.sh
```

(On Windows, `set FAST_SYNCS_ZIP_URL=…` before running `update.bat`.)

**If the Update… button seems to do nothing** (reported on some Macs and
Windows PCs): the button opens a terminal to run the updater. As of v0.5 it
no longer relies on macOS "Automation" permission (the old cause of a silent
no-op) — it opens a small `.command` wrapper instead. If a terminal still
doesn't appear, the dialog now shows the exact command to run manually, or
just run it yourself: **Windows** double-click `update.bat`; **macOS**
`bash update.sh`. And a `git pull` that can't fast-forward (a checkout with
local edits) now falls back to the ZIP overlay automatically instead of
failing the whole update.

---

## Bundled dubbing app (`dubbing/`)

The repo also ships the **Reaper Dubbing App**: take an English voice
recording and get a translated, voice-synthesized, time-synced dub in one of
12 Indian languages, imported straight onto the timeline. It arrives (and
stays current) through the same **Update…** button as the sync tool.

- **Open it**: run `auto_sync_pipeline.lua` — the same one script as the sync
  tool. It opens this panel directly, with the sync tool as its **Auto Sync**
  tab. There is nothing else to load.
- **First-time setup is automatic**: `update.bat`/`update.sh` and
  `setup.bat`/`setup.sh` create `dubbing/venv`, install the engine deps and
  install **ffmpeg** when missing — and if the panel opens before that ever
  ran, it starts the setup itself in a terminal (once, no prompts). Manual
  fallback: `dubbing/setup_windows.bat` / `bash dubbing/setup_mac.command`.
  Enter your API keys in the panel's **Settings** tab.
- **Panel tabs**: **Full Pipeline** (transcribe → translate → pauses for
  your review of the script/translation → Gemini-matches the script to the
  English lines → TTS per matched section → each dubbed chunk lands at its
  English line's position; chunks that don't match or don't fit go to the
  **Un sync** track, exactly like Auto Sync), **Paste Translation** (bring
  your own translated script — skips the LLM translation, then matches +
  dubs + places the same way), **Auto Sync** (this sync tool, embedded
  right in the dub window — same pipeline, no second window), **Regen
  Audio** (re-synthesize one chunk), **Track Voice** (re-voice a whole
  track), **Logs**, and **Settings** (keys, python override, and the
  shared Update… button).
- **Project history**: every run is remembered per REAPER project. Reopen
  the project later and the panel lists its past runs — resume a paused
  translation review or re-import a finished dub without transcribing or
  translating again.
- **Version**: shown in the panel title bar (and the Settings tab) — it
  comes from the `VERSION` file the updater keeps current.
- **Two projects at once**: each REAPER project gets its own status folder
  under `dubbing/engine/status/`, so you can run a second REAPER instance
  (macOS: `open -na REAPER`, Windows: `reaper.exe -newinst`) and dub a
  different project there while the first one runs.
- Full docs: [`dubbing/README.md`](dubbing/README.md).

---

## Connection mode — pick one

The **Connection** section of the settings window has a single **Mode**
dropdown. Pick one; only the fields that mode needs are shown.

**Inside the one-window app, keys live in the ⚙ Settings tab only.** The
**Auto Sync** tab reads them from there and shows a read-only summary — no second
copy to keep in step. This section describes the standalone Auto Sync action
(its own REAPER action, where there is no Settings tab) and the values behind
both. Mode names map 1:1 onto Settings' provider names: *Server* ↔ `server`,
*AI Studio* ↔ `gemini`, *Vertex* ↔ `vertex`, *LiteLLM gateway* ↔ `openai`.

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

**Gateway URL is an API base, not a web address you'd open in a browser.** Give
it the host, or the host plus `/v1` — `https://llm.example.com` or
`https://llm.example.com/v1`. Do **not** paste the chat UI's address (a path like
`/ui` serves HTML and redirects API calls to a login page) and do not append
`/chat/completions` — the code adds that itself. A bare host gets
`/v1/chat/completions`; a base that already carries a path (`/v1`, `/api/v1`,
`/v1beta/openai`) keeps it and only gets `/chat/completions`, so OpenAI,
OpenRouter, LiteLLM, vLLM, Open WebUI and Gemini's OpenAI-compatible layer all
work as-is. Azure OpenAI is not supported (different URL shape and auth header).

Requests go out with a browser `User-Agent`, because Cloudflare-fronted gateways
reject Python's default `Python-urllib/*` agent with a 403 (`error code: 1010`)
before the request reaches the model. Set `SYNC_HTTP_USER_AGENT` to send a
different agent string.

### Two things to know about matching vs. transcription

The pipeline runs **two** AI steps, and only one of them uses the mode above:

- **Transcription** (audio → text) is **always ElevenLabs** — it is locked, not
  configurable. Every direct mode therefore needs an **ElevenLabs key** (in
  Server mode your proxy supplies it). Gemini never sees the audio.
- **Matching** (aligning dub lines to English) is always Gemini, via the mode
  you picked. **No silent fallback** — if it fails (bad key, unreachable
  gateway, empty reply) the run stops with a visible error instead of a
  half-synced timeline.

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

---

## For maintainers

`main` is where development happens; **`production` is what users run.**
Merging `main` into `production` is the act of shipping — it tags the commit
and publishes a GitHub Release automatically.

See **[RELEASING.md](RELEASING.md)** for how to cut a release, how to roll one
back, and what adopting ReaPack would add.
