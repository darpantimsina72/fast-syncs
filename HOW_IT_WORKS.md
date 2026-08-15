# How This Automation Works — Explained Simply

**Project:** fast-syncs (v0.12.0)
**What it is:** two robots that live inside REAPER (a music/audio editing program)
and do the boring parts of dubbing videos into Indian languages.

---

## 1. The Big Idea (the 10-year-old version)

Imagine you have a video of someone speaking **English**.
Now you want the same video, but the person speaks **Hindi** (or Tamil, Telugu,
Bengali… 12 languages total).

Two problems:

**Problem A — "I already have Hindi recordings, but they're in a messy pile."**
A voice artist recorded all the Hindi lines. But they're just sitting there in a
big row. Nobody knows which Hindi line goes where in the video. Somebody has to
drag each clip to the exact right second. That takes *hours*.

> 🤖 **Robot 1 — "Auto Sync"** does this dragging for you.

**Problem B — "I don't even have the Hindi recording yet."**
You only have English. You need translation + a voice + placement, all of it.

> 🤖 **Robot 2 — "Dubbing App"** does the whole thing from scratch.

Both robots live in **one window** inside REAPER. You click one button.

---

## 2. The Two Robots, Side by Side

```
                      ┌─────────────────────────────────┐
                      │   ONE REAPER WINDOW (8 tabs)    │
                      └─────────────────────────────────┘
                                     │
                ┌────────────────────┴────────────────────┐
                │                                         │
        ROBOT 1: AUTO SYNC                        ROBOT 2: DUBBING APP
        "Move my clips"                           "Make the dub for me"
                │                                         │
   You already have:                          You only have:
   • English clips on a track                 • One English audio file
   • Hindi clips on a track                          │
                │                             It creates:
   It figures out which Hindi                 • The translation
   clip belongs to which English              • The Hindi voice (AI speaks it)
   clip, then MOVES it there.                 • And places it, same as Robot 1
```

---

## 3. Robot 1 — Auto Sync, step by step

You have two tracks in REAPER, named **exactly**:
- `Dialogue VO` ← the English clips
- `Dub` ← the Hindi/Tamil/… clips

You press **Start Sync**. Here's what happens:

### Step 1 — REAPER writes a shopping list
The Lua script ([auto_sync_pipeline.lua](auto_sync_pipeline.lua))
walks both tracks and writes a small file, `sync_config.json`, that says:

> "English clip #1 sits at 3.20 seconds, is 2.10 seconds long, and its sound is
> in file `xyz.wav` starting at offset 0.5s. English clip #2 is … " (and so on
> for every clip, both languages)

It's like listing every LEGO brick with where it is on the table.

### Step 2 — Python wakes up
Lua can't talk to the internet well, so it starts Python in the background:
[run_sync.py](run_sync.py) → which starts
[sync_matcher.py](sync_matcher.py), the real worker.

`run_sync.py` is the **butler**. Its whole job is:
- read your secret API keys from a settings file (never from the command line, so
  they can't leak into the Windows task list),
- turn them into environment variables,
- start the worker,
- write everything the worker prints into `sync_python_log.txt`,
- write the worker's exit code into `sync_python_done.txt` so Lua knows it finished.

### Step 3 — Listen to every single clip 👂
The worker cuts a tiny audio slice for each clip and sends it to **ElevenLabs
Scribe** (a speech-to-text AI) which sends back the words that were spoken.

- It does **8 clips at the same time** (parallel) so it's fast.
- It also remembers answers in a cache file, so if you run it twice, the second
  run is nearly instant and costs nothing.

Now every clip has a **transcript** (its words) attached.

If *every single* transcript comes back empty → the run **stops with a loud error**.
That means your key is broken or the internet is blocked. Better to fail loudly
than to silently place clips in the wrong places.

### Step 4 — Ask Gemini "which goes with which?" 🧠
All the English transcripts and all the Hindi transcripts go to **Google Gemini**
in **one single message**, roughly:

> "Here are English clips 1–200 with their words and times.
> Here are Hindi clips 1–180 with their words and times.
> Group them into *sections*. One section = one **thought**.
> Reply with only JSON."

Gemini replies with something like:

```json
{
  "sections": [
    {"en": [1, 2], "dub": [1]},
    {"en": [3],    "dub": [2, 3]}
  ],
  "unmatched_dub": [17, 44],
  "unmatched_en":  [5]
}
```

Meaning: *"English clips 1 and 2 together say the same thing as Hindi clip 1."*

Important design choice: the matching is **only** Gemini. If Gemini fails, the
whole run fails. There is deliberately **no backup guessing method**, because the
old "guess by duration" backup used to put clips in wrong places and nobody
noticed. Failing is safer than being quietly wrong.

### Step 5 — The Spring Placement 🪀 (the clever bit)

Now we know *which* Hindi clip goes with *which* English clip. But **where
exactly** on the timeline?

Think of each section as a **parking space**. The English clips define the space:
it starts where the first English clip starts and ends where the last one ends.
The Hindi clips are the **car** you need to park in it.

The robot tries 3 parking strategies, in order:

| Round | Strategy | When |
|---|---|---|
| 1 | **Center** — park in the middle of the space | Hindi fits inside the space |
| 3 | **Align start** — park at the very beginning | Hindi is a bit too long, but the gap after helps |
| 5 | **Align end** — park at the very end | Hindi needs the gaps on *both* sides |

It runs all three rounds **twice**, because after the easy sections park
themselves, the hard ones have more room to work with.

If a section *still* doesn't fit → **park it at the start anyway and let it spill
over**. Dubbed speech is usually longer than English, and pushing everything to
the end of the video would be worse.

**Silence correction:** if the English clip has 0.4s of silence before the voice
starts, and the Hindi clip has 0.1s, the robot nudges the Hindi clip so the two
*voices* start together — not the two *files*. It only trusts this nudge up to
2 seconds (`_SILENCE_CAP`); more than that is probably a mistake, so it's ignored.

### Step 6 — The Order Sweep (nothing may overlap, nothing may swap)

Now walk through the Hindi clips **in the order they were recorded** and check:

- ✅ Does it fit after the previous clip without overlapping? → keep it.
- ⚠️ Does it overlap slightly? → push it a bit later.
- ❌ Would pushing it make it crash into the *next* clip's spot? → **give up on
  this one**, and send it to a track called **`Un sync`**.

`Un sync` is the "please fix me by hand" pile. Clips there are laid out one after
another in time order, so a human can drag them into place quickly.

Rule that matters: an `Un sync` clip **doesn't block** the next good clip. It
steps aside completely.

There's a 10-millisecond gap (`_MIN_SPRING`) forced between every two clips, so
they never touch.

### Step 7 — Write the answer, REAPER moves the clips
The worker writes `sync_results.json`:

```json
{"dub_id": 12, "status": "matched", "new_position": 45.320, ...}
{"dub_id": 13, "status": "unmatched", "new_position": 91.400, ...}
```

Lua reads it and calls REAPER's own commands to move each clip. Matched clips
move on the `Dub` track. Unmatched clips get moved to `Un sync`. All of it in
**one undo step** — press Ctrl+Z once and everything goes back.

Then you see: *"148 matched, 12 unsynced."* Done.

---

## 4. Robot 2 — The Dubbing App, step by step

This one starts from just an English audio file. The stages have codenames
(`S1a`, `S2a`…) that show up in the progress bar.

```
  YOUR ENGLISH AUDIO
        │
 [S1a]  ├─→ 👂 ElevenLabs Scribe listens → English words + exact word times
        │
 [S1b]  ├─→ ✂️  Split into "regions" and build an English subtitle file (SRT)
        │
 [S2a]  ├─→ 🌐 LLM translates it        (Step1 prompt)
 [S2b]  ├─→ 🔍 LLM reviews the translation (Step2 prompt)
 [S2c]  ├─→ ❕ LLM fixes punctuation      (Step3 prompt)
        │
        ├─────── ⏸️  PAUSE — YOU READ IT ────────
        │        English on the left, translation on the right, editable.
        │        Nothing expensive has happened yet. Fix anything you want.
        │        Then press "Continue to Dubbing".
        │
 [S2d]  ├─→ ✂️  Chop the script into small pieces (see "piece size" below)
        ├─→ 🧠 Gemini matches each piece to an English subtitle line
        ├─→ 🗣️  ElevenLabs speaks the script (TTS) and reports the exact
        │        millisecond each character was spoken
        │
 [S3d]  ├─→ 🪀 Same spring placement + order sweep as Robot 1
        │
 [S3e]  └─→ 🎵 Render a reference audio file
                │
                └─→ 📥 "Import to timeline" builds 4 tracks in REAPER
```

### The pause is the point
The most important design decision: the robot **stops and waits for a human**
right after translating, *before* spending money on the voice. Translation is
cheap. Voice synthesis is not. So you review first.

You can copy the text out, edit it in Notepad, paste it back — because Indian
scripts (Devanagari etc.) don't render perfectly inside REAPER's UI. That's only
a *display* problem; the actual audio is always correct.

### "Piece size" — why it matters
The AI voice sounds much better when it reads a **long stretch** naturally
instead of one short sentence at a time. But long stretches make huge blocks on
the timeline that drift out of sync.

The clever fix: **record long, cut small.**

ElevenLabs' `with-timestamps` endpoint returns the audio **plus** the exact time
of every single character. So the robot records long natural stretches, then
slices them at the exact reported millisecond. Best of both worlds.

Three cutting settings:
- **`clause`** (default) — cut at `;` `:` `,` and dashes; max ~60 characters
  ≈ 4 seconds per piece. This is the newest and best.
- **`sentence`** — one piece per sentence. Older; some sentences ran 15 seconds.
- **`thought`/`section`** — one piece per idea. Oldest; big blocks.

Pieces shorter than 18 characters get merged into a neighbour — a two-word scrap
on its own timeline slot is just clutter.

### What lands in REAPER when you click Import

| Track | What's on it |
|---|---|
| `EN Original` | Your original English, at position 0 |
| `Dub Chunks` | One item per synced piece, at its English line's position |
| `Un sync` | Pieces with no home — same pile as Robot 1 |
| `Dub Rendered (ref)` | The finished dub as one file, muted, for reference |

Each `Dub Chunks` item secretly stores its own script text (in a hidden REAPER
field, *not* a visible note — visible notes covered the waveform). Select an item
and the **Regen Audio** tab loads its text so you can fix a typo and re-speak
just that one line.

### The other tabs

| Tab | What it does |
|---|---|
| **Full Pipeline** | The whole thing above |
| **Paste Translation** | You already have the translation → skips the LLM, just matches + speaks + places |
| **Auto Sync** | Robot 1, embedded right here |
| **Text to Speech** | Just say this text in this voice. No translation, no syncing |
| **Regen Audio** | Re-do one chunk. Optionally in a different voice. `🔊 Test voice` auditions it first so you don't waste a call |
| **Track Voice** | Take a whole track and change *who* is speaking it (speech-to-speech; timing is kept, so a synced dub stays synced) |
| **Logs** | Everything the engine printed, live |
| **Settings** | Keys, models, voices, prompts, languages, Update button |

---

## 5. Where the Files Live and What Each One Does

```
fast-syncs/
│
├── auto_sync_pipeline.lua   ⭐ THE ONLY FILE YOU LOAD IN REAPER (2,312 lines)
│                                    Draws the window, reads your tracks,
│                                    starts Python, moves the clips at the end.
│
├── run_sync.py                   The butler. Reads keys, starts the worker,
│                                    captures the log and exit code.  (261 lines)
│
├── sync_matcher.py               ⭐ THE BRAIN of Robot 1  (2,639 lines)
│                                    transcribe → Gemini match → spring place
│
├── sync_pipeline_settings.json   🔑 YOUR KEYS. Gitignored — never committed.
├── sync_config.json              (runtime) the clip list Lua wrote
├── sync_results.json             (runtime) the answer Python wrote
├── sync_python_log.txt           (runtime) the full log
├── sync_python_{pid,done}.txt    (runtime) "still alive?" / "finished with code N"
│
├── VERSION                       0.12.0 — shown in the window title
├── setup.bat / setup.sh          One-time installer (makes the venv)
├── update.bat / update.sh        Pull the newest version + refresh deps
├── SyncingPrompt.txt             The old hand-written prompt describing how
│                                    Sadhguru speaks (thought-by-thought, not
│                                    sentence-by-sentence) — the origin of the
│                                    whole punctuation-hierarchy idea
├── app_feedback.py               "Send Feedback" button's helper
│
├── server/main.py                Optional: a proxy server that holds the real
│                                    keys, so people you share this with never
│                                    need any keys at all.  (333 lines, FastAPI)
│
└── dubbing/                      ⭐ ROBOT 2
    ├── engine/
    │   ├── run_dub.py            Butler again (log/pid/done/status folder)
    │   ├── dub_engine.py         The conductor — runs all the stages (1,511 lines)
    │   └── pipeline/
    │       ├── config.py         Languages table, ffmpeg finder, settings loaders
    │       ├── stt.py            ElevenLabs Scribe (listening)
    │       ├── srt_tools.py      Subtitle files, region detection, chunking
    │       ├── llm.py            Talks to Vertex / Gemini / any OpenAI-style gateway
    │       ├── tts.py            ElevenLabs speaking + the timestamp slicing
    │       ├── match.py          Gemini section matching + piece building
    │       ├── sync.py           The older sync engine (springs, SRT, rendering)
    │       ├── agent_splitter.py Shortens text that's too long for its slot
    │       ├── agent_aligner.py  Newer placer: springs + "borrow 1.5s from
    │       │                       your neighbour" before giving up
    │       └── tm.py             Translation memory (SQLite) — don't pay twice
    │                               for the same sentence
    ├── prompts/                  60 plain text files: 5 stages × 12 languages.
    │                               Edit them in Notepad. This is where the
    │                               translation *style* lives.
    ├── reaper/
    │   ├── Dub_Pipeline_Panel.lua   The 8-tab window (6,080 lines)
    │   └── Import_Dub_Results.lua   Backup importer that works without ReaImGui
    ├── config/                   🔑 Your keys (gitignored)
    └── data/                     Translation memory database (gitignored)
```

**Total: about 20,000 lines of code.**

---

## 6. How the Two Robots Share One Window

This is a neat trick. `auto_sync_pipeline.lua` is **dual-personality**:

- Run it on its own → it draws its own window and behaves like Robot 1 alone.
- Run it with a secret flag `_G.__FASTSYNC_EMBED = true` → it doesn't draw a
  window at all. Instead it hands back a little box of functions:
  `{ render(), poll(), is_running(), reload_settings() }`.

The dubbing panel loads it that way and calls `render()` inside its **Auto Sync**
tab. Result: one window, two tools, no duplicated code.

Bonus: because Lua has a hard limit of 200 local variables per file, loading it
as a separate chunk gives it its own fresh budget. Practical engineering, not
theory.

---

## 7. Four Ways to Connect to the AI (pick one)

| Mode | Who holds the keys | Good for |
|---|---|---|
| **Server** | Your own proxy server | People you share this with. Their machine holds *no* secrets and needs no heavy libraries |
| **AI Studio** | This PC (a Google `AIza…` key) | Quick personal setup |
| **Vertex** | This PC (a Google Cloud service-account JSON) | Google Cloud shops |
| **LiteLLM gateway** | This PC (any OpenAI-compatible URL + `sk-…` key) | Your own in-house gateway |

**Two AI jobs, only one is switchable:**
- **Listening (speech→text)** is **always ElevenLabs**. Locked. Not configurable.
  Gemini never gets your audio in Auto Sync.
- **Matching (which line goes where)** is **always Gemini**, through whichever
  mode you picked above.

**Key-shape gotcha:** an `AIza…` key is Google's. An `sk-…` key is OpenAI-style
and belongs to a gateway. Mixing them up gives you HTTP 400 "API key not valid".

**Corporate networks:** offices with Zscaler/Netskope break HTTPS on purpose. The
code handles it in three layers — (1) use the Windows certificate store,
(2) relax one strict OpenSSL check, (3) if it *still* fails, print a `[SSL]`
warning once and continue without verification. Nothing for you to do. If
transcripts come back empty, look in the log for that `[SSL]` line.

---

## 8. Rules the Whole System Follows

These are the design principles you can see everywhere in the code:

1. **Fail loudly, never guess quietly.** No fallback matching method. Zero matches
   = the run FAILED, exit code 1, don't touch the timeline. A half-synced
   timeline that looks fine is worse than an obvious error.
2. **Never spend money before a human approves.** The translation review pause
   sits *before* the expensive voice synthesis.
3. **Secrets never travel on a command line.** They're read from JSON files by
   the process that needs them. Nothing appears in the Windows task list.
4. **Indic text never travels on a command line either.** It goes via UTF-8 files,
   because argument encoding on Windows would mangle it.
5. **Never destroy anything.** Regen makes new files with `_v2`, `_v3` suffixes.
   Track Voice mutes the original but never edits it. Every REAPER change is one
   undo block.
6. **Old runs must still open.** File formats grow by *adding* an optional field
   at the end. A 5-field timestamps line still means exactly what it always did.
7. **Every shipped change bumps `VERSION`.** Otherwise a user can't tell if their
   update actually landed.
8. **Two projects at once.** Each REAPER project gets its own status folder
   (`engine/status/<project>_<hash>/`), so two dubs never mix up their logs.

---

## 9. What It Costs to Run (per run)

| Step | Who | How many calls |
|---|---|---|
| Transcribe each clip | ElevenLabs Scribe | 1 per clip (8 at a time) — **cached** |
| Match everything | Gemini | **1 call total**, no matter how many clips (up to 5,000) |
| Translate / review / punctuate | Your LLM | 3 calls (Robot 2 only) |
| Speak the script | ElevenLabs TTS | a few long calls, not one per sentence |

The single-call matching is why this is fast. Gemini 2.5 Pro reads thousands of
clips in one prompt. Only if that fails does it fall back to a batched
one-pair-at-a-time prompt.

The **translation memory** (`dubbing/data/translation_memory.db`) and the
**transcript cache** both exist so re-running never pays twice for the same work.

---

## 10. One Thing You Should Fix Right Now 🔴

Your [sync_pipeline_settings.json](sync_pipeline_settings.json)
currently contains **two live API keys in plain text** — an ElevenLabs key and a
gateway key.

That file is gitignored, so it won't be committed. But:
- Anyone who gets a copy of this folder gets both keys.
- The ElevenLabs key has a **trailing space** in it, which can cause a
  hard-to-diagnose auth failure with some HTTP clients.

If this folder has ever been zipped, shared, or put on a shared drive, rotate
both keys.

Also worth knowing: `gemini_base_url` is `http://172.18.1.17:14005` — a LAN
address. That only works from inside your office network. Anyone you share this
with must use **Server** mode or their own key instead.

---

## 11. The Shortest Possible Summary

> **A Lua script inside REAPER lists your audio clips into a JSON file. Python
> picks it up, sends every clip to ElevenLabs to find out what words are in it,
> sends all those words to Gemini in one message to find out which Hindi clip
> matches which English clip, then uses a "spring" algorithm to park each Hindi
> clip in its English clip's spot without overlapping. Anything that doesn't fit
> goes on an `Un sync` track for a human. It writes the answer back as JSON and
> Lua moves the clips.**
>
> **The dubbing half does the same thing, but it also creates the Hindi script
> and the Hindi voice first — pausing to let a human read the translation before
> spending money on speech.**
