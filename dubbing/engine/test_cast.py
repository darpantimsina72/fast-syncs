#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Offline checks for the multi-speaker cast (v0.16).

Everything here is pure text bookkeeping: which paragraph a piece came from,
which voice that paragraph was cast to, and how the pieces are packed into
requests. None of it calls ElevenLabs or an LLM, so this runs anywhere and
costs nothing — which is the point, because the failure it guards against is
a line being SPOKEN in the wrong voice, and by then the credits are gone.

    python dubbing/engine/test_cast.py
"""

import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from pipeline import tts                                     # noqa: E402

FAILS = []


def check(name, cond, detail=""):
    if cond:
        print("  ok    " + name)
    else:
        print("  FAIL  " + name + ("  " + detail if detail else ""))
        FAILS.append(name)


# The script the panel would have saved: three paragraphs, three speakers.
SCRIPT = (
    "Sadhguru: Do not seek. Just see.\n\n"
    "Questioner: How do we begin, in this life, with so much noise "
    "around us all the time?\n\n"
    "Sadhguru: You have already begun."
)

MAIN = "sadhguruvoice01"
QUEST = "questionvoice3"


def _write_cast(base):
    """Exactly the shape the panel's V5.cast_save writes."""
    with open(base + "_speakers.json", "w", encoding="utf-8") as f:
        json.dump({
            "version": 1,
            "language": "Hindi",
            "default_voice_id": MAIN,
            "speakers": [
                {"key": "s1", "name": "Sadhguru", "voice_id": MAIN},
                {"key": "s2", "name": "Questioner", "voice_id": QUEST},
            ],
            "assignments": {
                "1": {"speaker": "s1", "voice_id": MAIN},
                "2": {"speaker": "s2", "voice_id": QUEST},
                "3": {"speaker": "s1", "voice_id": MAIN},
            },
        }, f)


def main():
    print("cast: the file the panel writes")
    tmp = tempfile.mkdtemp(prefix="cast_test_")
    base = os.path.join(tmp, "talk")
    _write_cast(base)
    cast = tts._speakers_voice_map(base)
    check("the map reads back paragraph-keyed",
          cast == {1: MAIN, 2: QUEST, 3: MAIN}, repr(cast))
    check("no file means no cast, not a crash",
          tts._speakers_voice_map(os.path.join(tmp, "absent")) == {})

    print("cast: sentences and units remember their paragraph")
    sents, spar = tts._split_script_into_sentences_with_paras(SCRIPT)
    check("every sentence has a paragraph",
          len(sents) == len(spar) and spar == sorted(spar),
          repr(spar))
    check("the paragraphs are the script's three",
          spar[0] == 1 and spar[-1] == 3 and set(spar) == {1, 2, 3},
          repr(spar))
    check("the plain splitter still answers the same sentences",
          tts._split_script_into_sentences(SCRIPT) == sents)

    units, upar = tts._split_script_into_units_with_paras(SCRIPT)
    check("every unit has a paragraph",
          len(units) == len(upar) and upar == sorted(upar), repr(upar))
    flat = [" ".join(p.split())
            for p in tts.re.split(r"\n\s*\n", SCRIPT) if p.strip()]
    check("no unit spans two paragraphs",
          all(" ".join(u.split()) in flat[p - 1]
              for u, p in zip(units, upar)),
          repr(list(zip(units, upar))))
    # The one deliberate difference from the plain splitter: a tiny fragment
    # ("Questioner:") is never folded into the PREVIOUS paragraph's unit,
    # which is what would put half a question in Sadhguru's voice.
    plain = tts._split_script_into_units(SCRIPT)
    check("a tiny fragment does not cross the speaker boundary",
          not any("Sadhguru: Do not seek." in u and "Questioner" in u
                  for u in units),
          repr(units))
    # Not a curiosity: this is the exact case the paragraph-aware splitter
    # exists for. If upstream ever stops merging across the boundary, this
    # says so rather than letting the two quietly converge.
    check("(the plain splitter is the one that would have)",
          any("Sadhguru: Do not seek." in u and "Questioner" in u
              for u in plain), repr(plain))

    print("cast: which voice each piece gets")

    def piece_voice(tr_ids):
        """The rule _stage_dub_match uses, in one place so it can be tested."""
        for j in tr_ids:
            if 0 < j <= len(upar):
                v = cast.get(upar[j - 1])
                if v:
                    return v
        return MAIN

    voices = [piece_voice([i + 1]) for i in range(len(units))]
    want = [cast[p] for p in upar]
    check("every unit is spoken by its paragraph's voice", voices == want,
          repr(list(zip(units, voices))))
    check("the questioner's units really are the questioner's",
          all(v == QUEST for u, v, p in zip(units, voices, upar) if p == 2))

    print("cast: a request is never two voices")
    groups = tts._pack_sentences(units, 10_000, keys=voices)
    check("packing breaks on a voice change",
          all(len({voices[i] for i in g}) == 1 for g in groups), repr(groups))
    check("packing keeps script order",
          [i for g in groups for i in g] == list(range(len(units))))
    check("one voice packs exactly as before",
          tts._pack_sentences(units, 10_000)
          == tts._pack_sentences(units, 10_000, keys=[MAIN] * len(units)))

    print("cast: the voice list is validated, not trusted")
    check("no voices is the single-voice path",
          tts._resolve_voice_list(None, 3, MAIN) is None)
    check("one voice for everything is the single-voice path",
          tts._resolve_voice_list([MAIN, MAIN, MAIN], 3, MAIN) is None)
    check("a blank entry falls back to the main voice",
          tts._resolve_voice_list([QUEST, "", QUEST], 3, MAIN)
          == [QUEST, MAIN, QUEST])
    check("a display label is not accepted as a voice id",
          tts._resolve_voice_list([QUEST, "Sadhguru HI (v3)", QUEST], 3, MAIN)
          == [QUEST, MAIN, QUEST])
    try:
        tts._resolve_voice_list([QUEST, MAIN], 3, MAIN)
        check("a mismatched list is refused", False)
    except ValueError:
        check("a mismatched list is refused", True)

    print("cast: the legacy stage's same-voice runs")
    paras = [p for p in tts.re.split(r"\n\s*\n", SCRIPT) if p.strip()]
    pvoices = [cast.get(i + 1, MAIN) for i in range(len(paras))]
    runs = []
    for text, v in zip(paras, pvoices):
        if runs and runs[-1][1] == v:
            runs[-1][0].append(text)
        else:
            runs.append(([text], v))
    check("three alternating paragraphs make three runs", len(runs) == 3,
          repr([v for _, v in runs]))
    check("the runs re-join into the whole script",
          "\n\n".join("\n\n".join(t) for t, _ in runs)
          == "\n\n".join(paras))

    print()
    if FAILS:
        print("FAILED: " + ", ".join(FAILS))
        return 1
    print("PASS — the cast reaches the synthesizer intact.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
