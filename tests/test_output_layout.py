#!/usr/bin/env python3
"""Output layout: a new run keeps every file of one video in ONE flat folder
next to the audio (<audio dir>/<base>/, as up to 0.15.6 — restored in
0.15.10); the 0.15.7–0.15.9 tidy FastSyncs/ layout is still read and a run
whose earlier half lives in one finishes there. A fake end-to-end run checks
the real engine puts its files where they belong.

What is checked:
  * layout_path maps every file kind to its subfolder in a tidy folder (one
    with the .fastsyncs-layout marker) and to the flat out_dir/filename in a
    pre-0.15.7 folder (no marker) — the rule that keeps old runs resumable.
  * TTS side files (chunk mp3s, _sec_/_str_ reuse sidecars, _chunks.txt) go
    to 03_Voice/pieces/ in a tidy folder, next to the wav anywhere else.
  * _prepare_output_dir: a fresh audio gets <audio dir>/<base>/ with no copy
    of the English audio and no FastSyncs/ anywhere; a flat folder that
    holds this audio's work (or its review script) is kept; a tidy folder
    that holds it is continued.
  * two audios in one project never write the same file.
  * the panel / importer / feedback kit Lua copies of the folder names agree
    with the Python table.
  * end-to-end (needs ffmpeg): a full run, a translate -> dub staged run and
    a dub that continues a 0.15.9 tidy review, with every paid call faked —
    ElevenLabs answers from a local fake, Scribe and the LLM are stubbed.
    Zero network.

Run:  dubbing/venv/bin/python3 tests/test_output_layout.py
"""
import base64
import contextlib
import io
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import types
import wave

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = os.path.join(REPO, "dubbing", "engine")
sys.path.insert(0, ENGINE)
from pipeline import config, tts  # noqa: E402
import dub_engine as de  # noqa: E402

FAILS = []
VOICE = "kkMxZ9B1JBX0queRrnb9"
LANG = "Hindi"


def check(name, cond):
    print(("  ✅ " if cond else "  ❌ ") + name)
    if not cond:
        FAILS.append(name)


def touch(path, data=b"x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def rel(root, path):
    return os.path.relpath(path, root).replace(os.sep, "/")


# Every file a run writes: (kind, name) -> expected tidy sub-path.
# Names use <base> = "talk" and the Hindi display name.
def _expected_files(base, disp):
    return [
        ("source", f"{base}.wav",                      "01_Source"),
        ("script", f"{base}.srt",                      "02_Script"),
        ("script", f"{base}_analyzed.txt",             "02_Script"),
        ("script", f"{base}_TranslationStep.txt",      "02_Script"),
        ("script", f"{base}_ReviewStep.txt",           "02_Script"),
        ("script", f"{base}_FinalScript.txt",          "02_Script"),
        ("script", f"{base}_provided_translation.txt", "02_Script"),
        ("script", f"{base}_review_en.txt",            "02_Script"),
        ("script", f"{base}_review_translation.txt",   "02_Script"),
        ("script", f"{base}_translation_edited.txt",   "02_Script"),
        ("voice",  f"{disp}_({base})_tts.wav",         "03_Voice"),
        ("pieces", f"{disp}_({base})_tts_sec_001.mp3", "03_Voice/pieces"),
        ("pieces", f"{disp}_({base})_tts_str_001.mp3.json", "03_Voice/pieces"),
        ("pieces", f"{disp}_({base})_tts_chunk_01.mp3", "03_Voice/pieces"),
        ("pieces", f"{disp}_({base})_tts_chunks.txt",  "03_Voice/pieces"),
        ("pieces", f"{base}_tts_state.json",           "03_Voice/pieces"),
        ("regen",  "chunk_1200_v1.wav",                "03_Voice/Redo/regen"),
        ("voicechange", "Dub_20260927_vc.wav",         "03_Voice/Redo/VoiceChange"),
        ("tts",    "TTS_20260927_120000.wav",          "03_Voice/Redo/TTS"),
        ("final",  f"{disp}_({base})_synced.wav",      "04_Final"),
        ("final",  f"{base}_sync_synced.srt",          "04_Final"),
        ("logs",   f"{base}_sync_log.txt",             "Logs"),
        ("work",   f"{base}_sync_en.srt",              "_work"),
        ("work",   f"{base}_sync_te.srt",              "_work"),
        ("work",   f"{base}_sync_texts.txt",           "_work"),
        ("work",   f"{base}_sync_timestamps.txt",      "_work"),
        ("work",   f"{base}_sync_mapping.txt",         "_work"),
        ("work",   f"{base}_engine_done.json",         "_work"),
    ]


def test_layout_mapping(tmp):
    print("layout_path: tidy subfolders vs legacy flat")
    tidy = config.make_tidy_root(os.path.join(tmp, "proj", "FastSyncs"))
    legacy = os.path.join(tmp, "proj", "talk")
    os.makedirs(legacy)
    marker = open(os.path.join(tidy, ".fastsyncs-layout")).read().strip()
    check("marker content is 2", marker == "2")
    check("is_tidy(tidy) / not is_tidy(legacy)",
          config.is_tidy(tidy) and not config.is_tidy(legacy))
    ok_t = ok_l = True
    for kind, name, sub in _expected_files("talk", "Hindi"):
        got = config.layout_path(tidy, kind, name)
        if rel(tidy, got) != f"{sub}/{name}":
            ok_t = False
            print(f"     tidy {kind}: {rel(tidy, got)}")
        if config.layout_path(legacy, kind, name) != os.path.join(legacy, name):
            ok_l = False
            print(f"     legacy {kind}: wrong")
    check("every kind maps to its tidy subfolder", ok_t)
    check("every kind stays flat in a legacy folder", ok_l)
    check("tidy subfolder created on demand",
          os.path.isdir(os.path.join(tidy, "03_Voice", "pieces")))
    check("make=False creates nothing",
          not os.path.isdir(os.path.join(
              os.path.dirname(config.layout_path(
                  os.path.join(tmp, "t2"), "work", "x", make=False)), "_work")))
    check("unused kind leaves no folder in a fresh tidy root",
          sorted(os.listdir(config.make_tidy_root(os.path.join(tmp, "fresh",
                                                               "FastSyncs"))))
          == [".fastsyncs-layout"])
    try:
        config.layout_path(tidy, "nope", "x")
        check("unknown kind raises", False)
    except ValueError:
        check("unknown kind raises", True)

    print("pieces_base: TTS side files")
    wav = config.layout_path(tidy, "voice", "Hindi_(talk)_tts.wav")
    check("tidy 03_Voice wav -> 03_Voice/pieces/<stem>",
          rel(tidy, config.pieces_base(wav)) == "03_Voice/pieces/Hindi_(talk)_tts")
    check("legacy wav -> next to the wav",
          config.pieces_base(os.path.join(legacy, "Hindi_(talk)_tts.wav"))
          == os.path.join(legacy, "Hindi_(talk)_tts"))
    rg = config.layout_path(tidy, "regen", "chunk_5_v1.wav")
    check("regen wav keeps its side files next to it",
          config.pieces_base(rg) == os.path.splitext(rg)[0])
    check("diverted -2 wav still goes to pieces",
          rel(tidy, config.pieces_base(os.path.join(
              tidy, "03_Voice", "Hindi_(talk)-2_tts.wav")))
          == "03_Voice/pieces/Hindi_(talk)-2_tts")

    print("manifest copy per audio")
    check("tidy -> _work/<base>_engine_done.json",
          rel(tidy, config.manifest_copy_path(tidy, "/a/b/talk.wav"))
          == "_work/talk_engine_done.json")
    check("legacy -> out_dir/engine_done.json",
          config.manifest_copy_path(legacy, "/a/b/talk.wav")
          == os.path.join(legacy, "engine_done.json"))
    c = config.manifest_copy_candidates(tidy, "/x/talk.wav")
    check("readers try the per-audio name, then the old name",
          [rel(tidy, p) for p in c] == ["_work/talk_engine_done.json",
                                        "engine_done.json"])


def test_prepare_output_dir(tmp):
    print("_prepare_output_dir picks the folder")
    proj = os.path.join(tmp, "Project")
    media = os.path.join(proj, "Media")
    audio = os.path.join(media, "talk.wav")
    touch(audio, b"RIFF")

    out = config._prepare_output_dir(audio, proj)
    check("fresh audio + saved project -> <audio dir>/<base>/ (flat)",
          out == os.path.join(media, "talk") and not config.is_tidy(out))
    check("English audio NOT copied into it", not os.listdir(out))
    check("no FastSyncs/ created anywhere",
          not os.path.exists(os.path.join(proj, "FastSyncs"))
          and not os.path.exists(os.path.join(media, "FastSyncs")))
    check("audio placed inside its own folder -> that folder, not nested",
          config._prepare_output_dir(os.path.join(out, "talk.wav"), proj) == out
          and not os.path.exists(os.path.join(out, "talk")))

    audio2 = os.path.join(tmp, "Loose", "clip.wav")
    touch(audio2, b"RIFF")
    out2 = config._prepare_output_dir(audio2)
    check("no project dir -> <audio dir>/<base>/",
          out2 == os.path.join(tmp, "Loose", "clip"))
    check("missing --project-dir folder -> same",
          config._prepare_output_dir(audio2, os.path.join(tmp, "gone"))
          == out2)

    print("flat (pre-0.15.7 / 0.15.10+) folders keep being used")
    old_audio = os.path.join(media, "old.wav")
    touch(old_audio, b"RIFF")
    old_dir = os.path.join(media, "old")
    touch(os.path.join(old_dir, "old.srt"), b"1")
    touch(os.path.join(old_dir, "old.wav"), b"RIFF")      # 0.15.6 copy
    touch(os.path.join(old_dir, "old_review_translation.txt"), b"t")
    check("dub --script in a flat folder -> that folder",
          config._prepare_output_dir(
              old_audio, proj, os.path.join(old_dir, "old_review_translation.txt"))
          == old_dir)
    check("flat folder already holds this audio's work -> kept",
          config._prepare_output_dir(old_audio, proj) == old_dir)
    check("flat folder never gets a marker", not config.is_tidy(old_dir))
    check("audio inside its own flat folder -> that folder",
          config._prepare_output_dir(os.path.join(old_dir, "old.wav"), proj)
          == old_dir)
    edited = os.path.join(old_dir, "old_translation_edited.txt")
    touch(edited, b"t")
    check("dub --script = edited file in flat folder -> flat",
          config._prepare_output_dir(old_audio, None, edited) == old_dir)

    print("0.15.7–0.15.9 tidy work is continued")
    tidy = config.make_tidy_root(os.path.join(proj, "FastSyncs"))
    rv = config.layout_path(tidy, "script", "talk_review_translation.txt")
    touch(rv, b"t")
    other = os.path.join(tmp, "Elsewhere")
    os.makedirs(other)
    check("dub --script in 02_Script -> that tidy root (even if the project "
          "moved)", config._prepare_output_dir(audio, other, rv) == tidy)
    held = os.path.join(media, "held.wav")
    touch(held, b"RIFF")
    touch(config.layout_path(tidy, "script", "held.srt"), b"1")
    check("project FastSyncs/ holds this audio's work -> continued there",
          config._prepare_output_dir(held, proj) == tidy)
    check("... and no flat folder made for it",
          not os.path.exists(os.path.join(media, "held")))
    check("a tidy root WITHOUT this audio's work is ignored",
          config._prepare_output_dir(audio2, proj) == out2)
    touch(config.layout_path(tidy, "script", "old.srt"), b"1")
    check("tidy root already holds this audio's work -> tidy wins over flat",
          config._prepare_output_dir(old_audio, proj) == tidy)
    src = config.layout_path(tidy, "source", "Dub_20260927.wav")
    touch(src, b"RIFF")
    touch(config.layout_path(tidy, "script", "Dub_20260927.srt"), b"1")
    check("0.15.9 01_Source render with its work -> its tidy root, not nested",
          config._prepare_output_dir(src) == tidy)


def test_two_audios(tmp):
    print("two audios in one project share FastSyncs/ without collisions")
    root = config.make_tidy_root(os.path.join(tmp, "P", "FastSyncs"))
    seen = {}
    clash = []
    for base in ("talk", "talk (2)", "interview"):
        audio = f"/media/{base}.wav"
        disp = config._lang_display_name(LANG)
        names = [config.layout_path(root, k, n, make=False)
                 for k, n, _ in _expected_files(base, disp)
                 if k not in ("regen", "voicechange", "tts")]
        names.append(config.manifest_copy_path(root, audio))
        names.append(config.layout_path(root, "voice", config._tts_output_name(
            LANG, audio, "_tts"), make=False))
        for n in set(names):
            if n in seen and seen[n] != base:
                clash.append((n, seen[n], base))
            seen[n] = base
    check("no two audios write the same path", not clash)
    for c in clash:
        print("     clash:", c)
    check("manifest copies differ per audio",
          config.manifest_copy_path(root, "/m/a.wav")
          != config.manifest_copy_path(root, "/m/b.wav"))


def test_lua_mirrors():
    print("Lua copies of the folder names agree with Python")
    panel = open(os.path.join(REPO, "dubbing", "reaper",
                              "Dub_Pipeline_Panel.lua"), encoding="utf-8").read()
    m = re.search(r"V5\.LAYOUT_SUB = \{(.*?)\n\}", panel, re.S)
    lua = dict(re.findall(r'(\w+)\s*=\s*"([^"]+)"', m.group(1))) if m else {}
    py = {k: v.replace(os.sep, "/") for k, v in config.LAYOUT_SUBDIRS.items()}
    check("panel V5.LAYOUT_SUB == config.LAYOUT_SUBDIRS", lua == py)
    check("panel marker name",
          f'V5.LAYOUT_MARKER  = "{config.LAYOUT_MARKER}"' in panel)
    imp = open(os.path.join(REPO, "dubbing", "reaper", "Import_Dub_Results.lua"),
               encoding="utf-8").read()
    check("importer knows the tidy folders", all(
        f'"{config.LAYOUT_SUBDIRS[k]}"' in imp
        for k in ("source", "voice", "final")) and '"_work"' in imp
        and config.LAYOUT_MARKER in imp)
    fk = open(os.path.join(REPO, "feedback_kit.lua"), encoding="utf-8").read()
    check("feedback kit archives to FastSyncs_Logs/ and plants no marker",
          '"FastSyncs_Logs"' in fk and config.LAYOUT_MARKER not in fk)


def test_lua_out_dir_mirror(tmp):
    """Run the panel's own V5.out_dir_for / V5.layout_path (cut out of the
    panel source, with a stub `reaper`) against the same folders as the
    Python rules. Needs `lua` on PATH; skipped otherwise."""
    print("panel V5.out_dir_for agrees with config._choose_output_dir")
    lua = shutil.which("lua")
    if not lua:
        print("  (skipped: lua not found)")
        return
    panel = open(os.path.join(REPO, "dubbing", "reaper",
                              "Dub_Pipeline_Panel.lua"), encoding="utf-8").read()
    a = panel.index("V5.LAYOUT_DIRNAME = ")
    b = panel.index("-- Minimal tolerant JSON reader")
    block = panel[a:b]

    proj = os.path.join(tmp, "Proj")
    media = os.path.join(proj, "Media")
    fresh = os.path.join(media, "fresh.wav")
    touch(fresh)
    old = os.path.join(media, "old.wav")
    touch(old)
    touch(os.path.join(media, "old", "old.srt"))
    inside = os.path.join(media, "own", "own.wav")
    touch(inside)
    root = config.make_tidy_root(os.path.join(proj, "FastSyncs"))
    src = config.layout_path(root, "source", "Dub_1.wav")
    touch(src)
    touch(config.layout_path(root, "script", "Dub_1.srt"))
    held = os.path.join(media, "held.wav")
    touch(held)
    touch(config.layout_path(root, "script", "held.srt"))
    loose = os.path.join(tmp, "Loose", "clip.wav")
    touch(loose)
    cases = [(fresh, proj), (old, proj), (inside, proj), (src, None),
             (src, proj), (held, proj), (held, None), (loose, None),
             (fresh, None)]

    lines = ['SEP = "/"', "V5 = {}",
             "local function file_exists(p) local f = io.open(p, 'rb') "
             "if f then f:close() return true end return false end",
             "local function dirname(p) return p:match('^(.*)[/\\\\][^/\\\\]*$') or '' end",
             "local function basename(p) return p:match('([^/\\\\]+)$') or p end",
             "PROJ = ''",
             "reaper = { EnumProjects = function() return 'P', PROJ end,",
             "  RecursiveCreateDirectory = function(d) "
             "os.execute(\"mkdir -p '\" .. d .. \"'\") end }",
             block]
    for audio, pd in cases:
        rpp = (pd + "/p.RPP") if pd else ""
        lines.append(f"PROJ = {json.dumps(rpp)}")
        lines.append(f"do local d, t = V5.out_dir_for({json.dumps(audio)}) "
                     "print(d .. '|' .. tostring(t)) end")
    lines.append(f"print(V5.layout_path({json.dumps(root)}, 'regen', 'x.wav'))")
    script = os.path.join(tmp, "mirror.lua")
    open(script, "w", encoding="utf-8").write("\n".join(lines))
    out = subprocess.run([lua, script], capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stderr)
    got = out.stdout.strip().splitlines()
    ok = out.returncode == 0 and len(got) == len(cases) + 1
    for (audio, pd), line in zip(cases, got):
        d, t = config._choose_output_dir(audio, pd)
        if line != f"{d}|{str(t).lower()}":
            ok = False
            print(f"     {os.path.basename(audio)} pd={bool(pd)}: lua {line} "
                  f"!= py {d}|{t}")
    check("same folder for every case (fresh, flat, own folder, 01_Source, "
          "tidy with work, loose, unsaved)", ok)
    check("Lua regen path = 03_Voice/Redo/regen",
          bool(got) and got[-1] == config.layout_path(root, "regen", "x.wav"))


# ── fake end-to-end ─────────────────────────────────────────────────────────

class _Resp:
    def __init__(self, body):
        self._b = body

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _tone_mp3(tmp, ms=600):
    path = os.path.join(tmp, "tone.mp3")
    subprocess.run([config.FFMPEG_PATH, "-loglevel", "error", "-y", "-f",
                    "lavfi", "-i", f"sine=frequency=330:duration={ms / 1000}",
                    "-ac", "1", "-ar", "44100", "-b:a", "64k", path],
                   check=True)
    return open(path, "rb").read()


class FakeElevenLabs:
    """Stands in for api.elevenlabs.io: every request gets the same tone."""

    def __init__(self, mp3):
        self.mp3 = mp3
        self.calls = 0

    def __call__(self, req, timeout=120):
        self.calls += 1
        if not req.full_url.startswith("https://api.elevenlabs.io/"):
            raise AssertionError("unexpected network call: " + req.full_url)
        text = json.loads(req.data.decode("utf-8"))["text"]
        if req.full_url.endswith("/with-timestamps"):
            k = max(1, len(text))
            return _Resp(json.dumps({
                "audio_base64": base64.b64encode(self.mp3).decode(),
                "alignment": {
                    "characters": list(text),
                    "character_start_times_seconds":
                        [0.5 * i / k for i in range(k)],
                    "character_end_times_seconds":
                        [0.5 * (i + 1) / k for i in range(k)]}}).encode())
        return _Resp(self.mp3)


def _english_wav(path):
    """6 s: three 1 s tones separated by silence -> three speech regions."""
    sr = 16000
    frames = bytearray()
    for i in range(sr * 6):
        t = i / sr
        on = int(t) % 2 == 0
        v = int(12000 * math.sin(2 * math.pi * 220 * t)) if on else 0
        frames += struct.pack("<h", v)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(bytes(frames))


SCRIPT = "नमस्ते दुनिया।\n\nयह एक परीक्षण है।\n\nधन्यवाद दोस्तों।"


def _fake_pipeline(real_import):
    def fake():
        ns = real_import()
        words = []
        for k, (a, w) in enumerate([(0.1, "Hello"), (0.5, "world."),
                                    (2.1, "This"), (2.5, "is"), (2.7, "a"),
                                    (2.8, "test."), (4.1, "Thank"),
                                    (4.5, "you.")]):
            words.append({"text": w, "start": a, "end": a + 0.3,
                          "type": "word"})
        ns._get_api_key = lambda: "fake-key"
        ns._validate_llm_config = lambda: None
        ns._active_provider_and_model = lambda: ("fake", "fake-model")
        ns._llm_provider_label = lambda: "fake"
        ns._llm_role_overrides_label = lambda: ""
        ns._llm_generate = lambda *a, **k: "OK"
        ns._tm_lookup_full = None
        ns._tm_glossary_block = None
        ns._transcribe_audio = lambda path, key, **k: {
            "text": " ".join(w["text"] for w in words), "words": words}
        ns._run_gemini_pipeline = lambda *a, **k: (SCRIPT,) * 3 + ("",) * 3

        def split_match(en_entries, sentences, *a, **k):
            m = len(en_entries)
            sections = [{"en": [min(i, m)], "tr": [i]}
                        for i in range(1, len(sentences) + 1)]
            return sections, [], [], sentences
        ns.agentic_split_match = split_match
        ns.agentic_place_pieces = lambda pieces, durations, *a, **k: [
            {"position": (p["win"][0] if p.get("win") else 0.0),
             "status": "synced" if p.get("win") else "unsync"}
            for p in pieces]
        return ns
    return fake


def _run_engine(argv):
    old = sys.argv
    sys.argv = ["dub_engine.py"] + argv
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc = de.main()
    finally:
        sys.argv = old
    if rc != 0:
        print(buf.getvalue()[-3000:])
    return rc


def _tree(root):
    out = []
    for d, _, fs in os.walk(root):
        for f in fs:
            out.append(rel(root, os.path.join(d, f)))
    return sorted(out)


def test_end_to_end(tmp):
    print("fake end-to-end (all paid calls stubbed, zero network)")
    if not config.FFMPEG_PATH:
        print("  (skipped: ffmpeg not found)")
        return
    real_import, real_urlopen = de._import_pipeline, tts._urlopen
    real_status = de.STATUS_DIR
    fake_el = FakeElevenLabs(_tone_mp3(tmp))
    de._import_pipeline = _fake_pipeline(real_import)
    tts._urlopen = fake_el
    de.STATUS_DIR = os.path.join(tmp, "status")
    try:
        proj = os.path.join(tmp, "My Project")
        media = os.path.join(proj, "Media")
        audio = os.path.join(media, "talk.wav")
        _english_wav(audio)
        flat = os.path.join(media, "talk")
        disp = config._lang_display_name(LANG)
        common = ["--language", LANG, "--voice-id", VOICE,
                  "--sync-mode", "match", "--project-dir", proj]

        # 1. full run -> everything flat in <audio dir>/talk/
        rc = _run_engine(["--audio", audio, "--steps", "full"] + common)
        check("full run exits 0", rc == 0)
        tree = _tree(flat)
        want = ["talk.srt", "talk_analyzed.txt",
                "talk_TranslationStep.txt", "talk_ReviewStep.txt",
                "talk_FinalScript.txt",
                f"{disp}_(talk)_tts.wav", f"{disp}_(talk)_tts_chunks.txt",
                f"{disp}_(talk)_synced.wav", "talk_sync_synced.srt",
                "engine_done.json", "talk_sync_en.srt",
                "talk_sync_texts.txt", "talk_sync_timestamps.txt"]
        missing = [w for w in want if w not in tree]
        check("full run: every file in the one folder next to the audio",
              not missing)
        for w in missing:
            print("     missing:", w)
        check("full run: paid TTS pieces + reuse sidecars in the same folder",
              any(re.match(rf"{re.escape(disp)}_\(talk\)_tts_(str|sec)_001"
                           r"\.mp3$", t) for t in tree)
              and any(re.match(r".*_tts_(str|sec)_001\.mp3\.json$", t)
                      for t in tree))
        check("full run: no subfolders, no marker",
              all("/" not in t for t in tree) and ".fastsyncs-layout" not in tree)
        check("full run: no FastSyncs/ folder anywhere",
              not os.path.exists(os.path.join(proj, "FastSyncs"))
              and not os.path.exists(os.path.join(media, "FastSyncs")))
        man = json.load(open(os.path.join(flat, "engine_done.json")))
        check("manifest out_dir = the flat folder", man["out_dir"] == flat)
        check("English audio not copied", "talk.wav" not in tree)
        check("manifest en_audio = the original audio", man["en_audio"] == audio)
        check("manifest points at the synced wav in the folder",
              man["synced_wav"] == os.path.join(flat, f"{disp}_(talk)_synced.wav"))
        check("status-dir manifest still written", os.path.isfile(
            os.path.join(de.STATUS_DIR, "engine_done.json")))
        print("     tree:", ", ".join(tree))

        # 2. staged translate -> dub on a second audio in the same project
        audio_b = os.path.join(media, "interview.wav")
        _english_wav(audio_b)
        flat_b = os.path.join(media, "interview")
        rc = _run_engine(["--audio", audio_b, "--steps", "translate"] + common)
        check("translate exits 0", rc == 0)
        rman = json.load(open(os.path.join(flat_b, "engine_done.json")))
        check("review manifest status", rman["status"] == "review")
        check("review files in the audio's folder",
              rman["translation_text"] == os.path.join(
                  flat_b, "interview_review_translation.txt")
              and rman["en_text"] == os.path.join(flat_b, "interview_review_en.txt"))
        edited = os.path.join(flat_b, "interview_translation_edited.txt")
        shutil.copy(rman["translation_text"], edited)
        rc = _run_engine(["--audio", audio_b, "--steps", "dub",
                          "--script", edited] + common)
        check("dub resume exits 0", rc == 0)
        dman = json.load(open(os.path.join(flat_b, "engine_done.json")))
        check("dub manifest ok, same folder",
              dman["status"] == "ok" and dman["out_dir"] == flat_b)
        check("dub wrote its speech + SRT there", os.path.isfile(
            os.path.join(flat_b, f"{disp}_(interview)_tts.wav"))
            and os.path.isfile(os.path.join(flat_b, "interview_sync_synced.srt")))
        check("first audio's manifest untouched by the second",
              json.load(open(os.path.join(flat, "engine_done.json")))["audio"]
              == audio)

        # 3. a review paused on 0.15.9 (tidy FastSyncs/) continued on 0.15.10
        root = config.make_tidy_root(os.path.join(proj, "FastSyncs"))
        old_audio = os.path.join(media, "old.wav")
        _english_wav(old_audio)
        for suf, kind in ((".srt", "script"), ("_FinalScript.txt", "script"),
                          ("_review_translation.txt", "script"),
                          ("_sync_en.srt", "work")):
            shutil.copy(os.path.join(flat_b, "interview" + suf),
                        config.layout_path(root, kind, "old" + suf))
        rc = _run_engine(["--audio", old_audio, "--steps", "dub", "--script",
                          config.layout_path(root, "script",
                                             "old_review_translation.txt")]
                         + common)
        check("tidy dub continuation exits 0", rc == 0)
        lt = _tree(root)
        check("tidy: outputs go to its subfolders",
              f"03_Voice/{disp}_(old)_tts.wav" in lt
              and f"04_Final/{disp}_(old)_synced.wav" in lt
              and "04_Final/old_sync_synced.srt" in lt
              and "_work/old_engine_done.json" in lt
              and any(re.match(r"03_Voice/pieces/.*_\(old\)_tts_(str|sec)_001"
                               r"\.mp3$", t) for t in lt))
        check("tidy: no flat folder made for it",
              not os.path.exists(os.path.join(media, "old")))
        tman = json.load(open(os.path.join(root, "_work", "old_engine_done.json")))
        check("tidy manifest en_audio = the original audio",
              tman["en_audio"] == old_audio)

        # 4. legacy sync mode (whole-script TTS + mapping + sync log)
        audio_c = os.path.join(media, "lecture.wav")
        _english_wav(audio_c)
        flat_c = os.path.join(media, "lecture")
        real_fake = de._import_pipeline

        def with_legacy_stubs():
            ns = real_fake()
            ns._call_gemini_mapping = lambda *a, **k: "1 -> 1"

            def fake_sync(en_srt, te_srt, mapping, en_audio_duration=0.0):
                te = ns._parse_srt_from_string(te_srt)
                return dict(te), dict(te), "fake sync log"
            ns.run_sync_from_strings = fake_sync
            return ns
        de._import_pipeline = with_legacy_stubs
        rc = _run_engine(["--audio", audio_c, "--steps", "full",
                          "--language", LANG, "--voice-id", VOICE,
                          "--sync-mode", "legacy", "--no-emotion",
                          "--project-dir", proj])
        de._import_pipeline = real_fake
        check("legacy-sync-mode run exits 0", rc == 0)
        tree = _tree(flat_c)
        want = ["lecture_sync_log.txt", "lecture_sync_te.srt",
                "lecture_sync_mapping.txt", "lecture_sync_en.srt",
                "lecture_sync_timestamps.txt", "lecture_tts_state.json",
                f"{disp}_(lecture)_tts_chunk_01.mp3",
                f"{disp}_(lecture)_tts_chunks.txt",
                f"{disp}_(lecture)_tts.wav",
                f"{disp}_(lecture)_synced.wav",
                "lecture_sync_synced.srt", "engine_done.json"]
        missing = [w for w in want if w not in tree]
        check("legacy sync mode: every file in the one folder", not missing)
        for w in missing:
            print("     missing:", w)
        st = json.load(open(os.path.join(flat_c, "lecture_tts_state.json")))
        check("TTS reuse sidecar points at the wav in the folder",
              st["tts_wav"] == os.path.join(flat_c, f"{disp}_(lecture)_tts.wav"))
        calls = fake_el.calls
        de._import_pipeline = with_legacy_stubs
        rc = _run_engine(["--audio", audio_c, "--steps", "full",
                          "--language", LANG, "--voice-id", VOICE,
                          "--sync-mode", "legacy", "--no-emotion",
                          "--project-dir", proj])
        de._import_pipeline = real_fake
        check("re-run reuses the paid speech from the folder (no new "
              "ElevenLabs call)", rc == 0 and fake_el.calls == calls)
        check("only the fake ElevenLabs was called", fake_el.calls > 0)
    finally:
        de._import_pipeline = real_import
        tts._urlopen = real_urlopen
        de.STATUS_DIR = real_status


def test_engine_log_kept(tmp):
    print("run_dub appends the engine log to the video's folder")
    import run_dub  # noqa: E402 — the launcher, stdlib only
    status = os.path.join(tmp, "status")
    flat = os.path.join(tmp, "Media", "talk")
    os.makedirs(status)
    os.makedirs(flat)
    log = os.path.join(status, "engine_log.txt")

    def run(body, out_dir, audio="/m/talk.wav", st="ok"):
        open(log, "w", encoding="utf-8").write(body)
        json.dump({"status": st, "out_dir": out_dir, "audio": audio},
                  open(os.path.join(status, "engine_done.json"), "w"))
        run_dub._keep_log_with_outputs(status, log)

    run("translate log\n", flat, st="review")
    run("dub log\n", flat)
    got = open(os.path.join(flat, "talk_engine_log.txt"), encoding="utf-8").read()
    check("flat: <base>_engine_log.txt next to the outputs, both runs kept",
          "translate log" in got and "dub log" in got
          and got.index("translate log") < got.index("dub log"))
    tidy = config.make_tidy_root(os.path.join(tmp, "P", "FastSyncs"))
    run("tidy log\n", tidy)
    check("tidy: goes to Logs/", os.path.isfile(
        os.path.join(tidy, "Logs", "talk_engine_log.txt")))
    os.remove(os.path.join(status, "engine_done.json"))
    run_dub._keep_log_with_outputs(status, log)   # no manifest: must not raise
    json.dump({"status": "ok", "regen_wav": "/x.wav"},
              open(os.path.join(status, "engine_done.json"), "w"))
    run_dub._keep_log_with_outputs(status, log)   # redo manifest: skipped
    check("no manifest / redo manifest: nothing written, no crash",
          sorted(os.listdir(flat)) == ["talk_engine_log.txt"])


def main():
    with tempfile.TemporaryDirectory() as tmp:
        for i, t in enumerate((test_layout_mapping, test_prepare_output_dir,
                               test_two_audios, test_lua_out_dir_mirror,
                               test_engine_log_kept, test_end_to_end)):
            d = os.path.join(tmp, str(i))
            os.makedirs(d)
            t(d)
    test_lua_mirrors()
    if FAILS:
        print(f"\nRED: {len(FAILS)} failed")
        sys.exit(1)
    print("\nGREEN: output layout checks passed")


if __name__ == "__main__":
    main()
