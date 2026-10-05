#!/usr/bin/env python3
"""0.15.11 line fitting: a too-long script line is trimmed just enough to fit
its English, never cut too short, and a pasted script that already fits is
left alone.

Field report (Bengali, 2026-10-05): ~30% of shortened lines came back too
short or missing meaning, and near-perfect pasted scripts were rewritten.

Guards:
  1. room = English time + the pause after it (capped); a line that fits
     that room is NOT sent to the AI.
  2. fit_line: a try at 90-100% of the room is used; a too-short first try
     gets ONE retry that says "too short"; if neither hits 90-100%, the
     closer try within 80-115% is used; otherwise the ORIGINAL line is kept
     ("kept_too_long"). Nothing under 80% is ever used. At most 2 AI calls.
  3. shorten=False changes nothing but still reports the long lines.
  4. the changes list file lists what happened; it is removed when empty.
  5. learn_speech_rate measures chars/s from synthesized pieces, smooths it,
     and chars_per_sec uses it on the next run (model-specific first).

No network: the AI and the matcher are fakes. Run:
  dubbing/venv/bin/python tests/test_line_fit.py
"""
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "dubbing", "engine"))
from pipeline import agent_splitter as sp  # noqa: E402
import dub_engine as de  # noqa: E402

FAILS = []


def check(name, cond):
    print(("PASS  " if cond else "FAIL  ") + name)
    if not cond:
        FAILS.append(name)


TMP = tempfile.mkdtemp()
sp.SPEECH_RATES_FILE = os.path.join(TMP, "speech_rates.json")
RATE = 10.0   # chars/s used in these checks
LANG = "Bengali"


def scripted(*replies):
    """A fake AI that answers with *replies* in order and counts its calls."""
    state = {"n": 0, "prompts": []}

    def gen(prompt):
        state["prompts"].append(prompt)
        r = replies[min(state["n"], len(replies) - 1)]
        state["n"] += 1
        return r
    return gen, state


def text(n):
    return "ক" * n


# room 5 s at 10 chars/s = budget 50 chars; target 45..50; keep 40..57
print("fit_line")
gen, st = scripted(text(48))
out, status, share = sp.fit_line(text(80), "en", 5.0, LANG, rate=RATE, generate=gen)
check("first try at 96% -> used, one call", status == "fitted" and len(out) == 48 and st["n"] == 1)

gen, st = scripted(text(30), text(46))
out, status, share = sp.fit_line(text(80), "en", 5.0, LANG, rate=RATE, generate=gen)
check("too-short first try -> retry -> fitted", status == "fitted" and len(out) == 46 and st["n"] == 2)
check("the retry prompt says it was too short", "too SHORT" in st["prompts"][1])

gen, st = scripted(text(30), text(25))
out, status, share = sp.fit_line(text(80), "en", 5.0, LANG, rate=RATE, generate=gen)
check("both tries too short (60%, 50%) -> ORIGINAL kept",
      status == "kept_too_long" and out == text(80) and st["n"] == 2)

gen, st = scripted(text(42), text(55))
out, status, share = sp.fit_line(text(80), "en", 5.0, LANG, rate=RATE, generate=gen)
check("both miss 90-100% -> the closer one inside 80-115% (55 = 110%... vs 42 = 84%)",
      status == "close" and len(out) in (42, 55))
check("closer to 95% wins (84% is 11 away, 110% is 15 away)", len(out) == 42)

gen, st = scripted(text(39), text(70))
out, status, share = sp.fit_line(text(80), "en", 5.0, LANG, rate=RATE, generate=gen)
check("78% and 140% -> nothing acceptable -> original kept", status == "kept_too_long")

gen, st = scripted("")
out, status, share = sp.fit_line(text(80), "en", 5.0, LANG, rate=RATE, generate=gen)
check("empty AI replies -> original kept, at most 2 calls", status == "kept_too_long" and st["n"] == 2)

check("never uses anything under 80%", sp.KEEP_LO == 0.80 and sp.FIT_LO == 0.90)


print("agentic_split_match: room and trigger")
# EN cues (start, end, text): cue 1 0-4 s, cue 2 5-8 s, cue 3 8.2-10 s
EN = [(0.0, 4.0, "one"), (5.0, 8.0, "two"), (8.2, 10.0, "three")]


def matcher(sections):
    return lambda en, tr, lang, model, cb: (sections, [], [])


open(sp.SPEECH_RATES_FILE, "w").write('{"Bengali": {"cps": 10.0, "runs": 1}}')
# TR 1: 45 chars = 4.5 s. EN 1 is 4 s (+1 s pause before cue 2 -> room 5 s):
# fits the room -> NOT touched (old rule: 4.5 <= max(4.6, 4.5) also fine).
# TR 2: 52 chars = 5.2 s for EN 2 (3 s + 0.2 s pause = 3.2 s room) -> fitted.
TR = [text(45), text(52), text(12)]
SECTIONS = [{"en": [1], "tr": [1]}, {"en": [2], "tr": [2]}, {"en": [3], "tr": [3]}]
gen, st = scripted(text(30))          # 30 chars = 3.0 s = 94% of 3.2 s
changes = []
_, _, _, out = sp.agentic_split_match(EN, TR, LANG, "m", None, True, "",
                                      changes, gen, matcher(SECTIONS))
check("line that fits English + pause is not sent to the AI", out[0] == TR[0])
check("too-long line is fitted", out[1] == text(30) and changes and changes[0]["status"] == "fitted")
check("short line untouched", out[2] == TR[2])
check("one AI call for the one long line", st["n"] == 1)
check("room counted the pause after the English (3.2 s)",
      abs(changes[0]["room"] - 3.2) < 1e-6)

# A near-perfect pasted script: every line within its room -> zero AI calls.
gen, st = scripted(text(1))
changes = []
_, _, _, out = sp.agentic_split_match(EN, [text(40), text(31), text(15)], LANG,
                                      "m", None, True, "", changes, gen,
                                      matcher(SECTIONS))
check("near-perfect script: nothing changed, no AI call, empty list",
      st["n"] == 0 and not changes and out == [text(40), text(31), text(15)])

# shorten=False
gen, st = scripted(text(30))
changes = []
_, _, _, out = sp.agentic_split_match(EN, TR, LANG, "m", None, False, "",
                                      changes, gen, matcher(SECTIONS))
check("switch OFF: no line changed, no AI call", out == TR and st["n"] == 0)
check("switch OFF: the long line is still reported", len(changes) == 1 and changes[0]["status"] == "off")

# a group of 2 sentences fitted -> text on the first, the second emptied
# (last cue: room = 5 s + the 1.5 s end allowance = 6.5 s -> 60 chars = 92%)
gen, st = scripted(text(60))
changes = []
_, _, _, out = sp.agentic_split_match(
    [(0.0, 5.0, "a b")], [text(40), text(40)], LANG, "m", None, True, "",
    changes, gen, matcher([{"en": [1], "tr": [1, 2]}]))
check("group fitted: text on the first sentence, the rest emptied",
      out == [text(60), ""])

# kept_too_long leaves the group exactly as written
gen, st = scripted(text(5))
_, _, _, out = sp.agentic_split_match(
    [(0.0, 5.0, "a b")], [text(40), text(40)], LANG, "m", None, True, "",
    [], gen, matcher([{"en": [1], "tr": [1, 2]}]))
check("kept_too_long: the group is not touched", out == [text(40), text(40)])


print("changes list file")
ctx = {"out_dir": os.path.join(TMP, "talk"), "bname": "talk"}
os.makedirs(ctx["out_dir"])


class PL:
    layout_path = staticmethod(lambda d, kind, name: os.path.join(d, name))


de._write_fit_changes(PL, ctx, [
    {"tr_ids": [2], "en": "two", "before": "long", "after": "short",
     "status": "fitted", "room": 3.2, "share_before": 1.6, "share_after": 0.94},
    {"tr_ids": [5], "en": "five", "before": "long2", "after": "long2",
     "status": "kept_too_long", "room": 2.0, "share_before": 1.9, "share_after": 1.9}])
path = os.path.join(ctx["out_dir"], "talk_shortened_lines.txt")
body = open(path, encoding="utf-8").read()
check("list written next to the script", "Before:  long" in body and "After:   short" in body)
check("kept lines say to check them in Redo", "check in Redo" in body)
de._write_fit_changes(PL, ctx, [])
check("an empty run removes the stale list", not os.path.exists(path))


print("learn_speech_rate")
os.remove(sp.SPEECH_RATES_FILE)
check("no measurement yet -> starting guess", sp.chars_per_sec("Bengali") == 12.0)
r = sp.learn_speech_rate("Bengali", "eleven_v3", [text(150), text(150)], [10.0, 10.0])
check("first run: measured 15 chars/s stored", r == 15.0
      and sp.chars_per_sec("Bengali", "eleven_v3") == 15.0
      and sp.chars_per_sec("Bengali") == 15.0)
sp.learn_speech_rate("Bengali", "eleven_v3", [text(100)], [10.0])
check("second run moves 40% of the way (15 -> 13.0)",
      abs(sp.chars_per_sec("Bengali", "eleven_v3") - 13.0) < 1e-6)
sp.learn_speech_rate("Bengali", "eleven_v4", [text(180)], [10.0])
check("model-specific rate wins, language rate is shared",
      sp.chars_per_sec("Bengali", "eleven_v4") == 18.0
      and abs(sp.chars_per_sec("Bengali", "eleven_v3") - 13.0) < 1e-6)
check("under 5 s of speech teaches nothing",
      sp.learn_speech_rate("Hindi", "", [text(30)], [3.0]) is None
      and sp.chars_per_sec("Hindi") == 9.2)
check("tags are not counted as spoken text",
      sp.estimate_duration("[calm] " + text(20), "x", 10.0) == 2.0)


print("\nGREEN: all checks passed" if not FAILS else f"\nRED: {len(FAILS)} failed")
sys.exit(1 if FAILS else 0)
