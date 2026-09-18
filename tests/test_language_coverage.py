#!/usr/bin/env python3
"""Cross-check every supported language against every table that must know it.

Symptom this guards against: "syncing/dubbing works for some languages and not
others". Each language has to appear in several independent tables spread over
Python and Lua. Nothing ties them together, so adding a language to the UI list
without adding it everywhere else produces a language that half-works.

config.py:TTS_LANGUAGES is the single source of truth. Offline, no API calls.

Run:  dubbing/venv/bin/python tests/test_language_coverage.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "dubbing", "engine"))
from pipeline import config as cfg  # noqa: E402

PROMPT_STAGES = ["Step1_Translation_Prompt", "Step2_Review_Prompt",
                 "Step3_Punctuation_Prompt", "Step4_Emotion_Prompt",
                 "SyncingPrompt"]


def _lua_table(path, name):
    """Pull the keys out of `local <name> = { k = "v", ... }`."""
    src = open(os.path.join(ROOT, path), encoding="utf-8").read()
    m = re.search(r"local\s+" + re.escape(name) + r"\s*=\s*\{(.*?)\n\}",
                  src, re.S)
    if not m:
        return None
    body = m.group(1)
    # Bare keys (`hi = "Devanagari"`) and bracketed ones (`["or"] = "Oriya"`).
    # Lua keywords such as `or` can only be written in bracket form.
    keys = set(re.findall(r"([A-Za-z_][A-Za-z_0-9]*)\s*=", body))
    keys |= set(re.findall(r'\[\s*"([^"]+)"\s*\]\s*=', body))
    return keys


def _lua_list(path, name):
    src = open(os.path.join(ROOT, path), encoding="utf-8").read()
    m = re.search(r"local\s+" + re.escape(name) + r"\s*=\s*\{(.*?)\}", src, re.S)
    if not m:
        return None
    return set(re.findall(r'"([^"]+)"', m.group(1)))


def _py_dict(path, name):
    src = open(os.path.join(ROOT, path), encoding="utf-8").read()
    m = re.search(re.escape(name) + r"\s*=\s*\{(.*?)\n\s*\}", src, re.S)
    if not m:
        return None
    return dict(re.findall(r'"([^"]+)"\s*:\s*"([^"]+)"', m.group(1)))


def main():
    langs = cfg.TTS_LANGUAGES
    print(f"source of truth: config.TTS_LANGUAGES ({len(langs)} languages)\n")

    prompts_dir = os.path.join(ROOT, "dubbing", "prompts")
    sync_norm = _py_dict("sync_matcher.py", "_LANG_NORMALIZE")
    sync_script = _lua_table("auto_sync_pipeline.lua", "_LANG_TO_SCRIPT")
    panel_list = _lua_list("dubbing/reaper/Dub_Pipeline_Panel.lua", "LANGUAGES")
    panel_script = _lua_table("dubbing/reaper/Dub_Pipeline_Panel.lua",
                              "_LANG_TO_SCRIPT")

    for label, tbl in (("sync_matcher._LANG_NORMALIZE", sync_norm),
                       ("auto_sync _LANG_TO_SCRIPT", sync_script),
                       ("panel LANGUAGES", panel_list),
                       ("panel _LANG_TO_SCRIPT", panel_script)):
        if tbl is None:
            print(f"  !! could not parse {label} — test cannot check it")

    cols = ["prompts", "syncNorm", "syncFont", "panelList", "panelFont", "TTS"]
    print(f"  {'language':<11} " + " ".join(f"{c:>9}" for c in cols))
    print("  " + "-" * 72)

    failures = []
    for name, meta in langs.items():
        two = meta["code"].split("-")[0]
        row = {}

        missing_p = [s for s in PROMPT_STAGES
                     if not os.path.isfile(
                         os.path.join(prompts_dir, f"{s}_{name}.txt"))]
        row["prompts"] = "ok" if not missing_p else f"MISS {len(missing_p)}"

        row["syncNorm"] = ("skip" if sync_norm is None else
                           "ok" if two in sync_norm.values() else "MISSING")
        row["syncFont"] = ("skip" if sync_script is None else
                           "ok" if two in sync_script else "MISSING")
        row["panelList"] = ("skip" if panel_list is None else
                            "ok" if name in panel_list else "MISSING")
        row["panelFont"] = ("skip" if panel_script is None else
                            "ok" if name in panel_script else "MISSING")
        row["TTS"] = "EL-only" if meta.get("google_unavailable") else "ok"

        bad = [c for c in cols if row[c] not in ("ok", "skip", "EL-only")]
        print(f"  {name:<11} " + " ".join(f"{row[c]:>9}" for c in cols)
              + ("   <-- gap" if bad else ""))
        if bad:
            failures.append((name, bad, missing_p))

    print()
    if failures:
        for name, bad, missing_p in failures:
            print(f"  {name}: incomplete in {', '.join(bad)}"
                  + (f" (prompts: {', '.join(missing_p)})" if missing_p else ""))
        print(f"\nRED: {len(failures)} language(s) are not wired into every table")
        return 1
    print("GREEN: every language is present in every table")
    return 0


if __name__ == "__main__":
    sys.exit(main())
