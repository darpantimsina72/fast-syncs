#!/usr/bin/env python3
"""On-disk LLM reply cache + parallel line shortening.

A re-run after a late failure should not pay for the mechanical LLM calls
(match / shortening / emotion / mapping) again. The danger is replaying a
reply that does not belong to the request, or replaying a bad one forever,
so most checks here are about MISSING the cache when anything differs.

Also: the translation chain (role "translate") and probes are never cached,
and the parallel shortening pass returns sentences in the original order.

Offline, deterministic, no API calls: the provider call is replaced.

Run:  dubbing/venv/bin/python tests/test_llm_cache.py
"""
import os
import shutil
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))), "dubbing", "engine"))
from pipeline import agent_splitter, llm  # noqa: E402

FAILS = []


def check(name, cond):
    print(("  ✅ " if cond else "  ❌ ") + name)
    if not cond:
        FAILS.append(name)


SETTINGS = {"provider": llm.LLM_PROVIDER_OPENAI,
            "openai_base_url": "http://gw/v1", "openai_api_key": "k",
            "openai_model": "model-a"}
CALLS = []


def fake_chat(prompt, model, timeout=900.0, attempts=None):
    CALLS.append((prompt, model, attempts))
    return REPLY[0]


REPLY = ["reply-1"]


def test_cache():
    gen = llm._llm_generate
    print("miss, then hit")
    CALLS.clear()
    a = gen("dyn", "x", static_prefix="PREFIX", role="match")
    b = gen("dyn", "x", static_prefix="PREFIX", role="match")
    check("first call is live", len(CALLS) == 1 and a == "reply-1")
    check("identical second call served from disk", len(CALLS) == 1
          and b == "reply-1")

    print("anything different is a miss")
    CALLS.clear()
    gen("dyn2", "x", static_prefix="PREFIX", role="match")
    check("different prompt -> live", len(CALLS) == 1)
    gen("dyn", "x", static_prefix="PREFIX-2", role="match")
    check("different static prefix -> live", len(CALLS) == 2)
    SETTINGS["openai_model"] = "model-b"
    gen("dyn", "x", static_prefix="PREFIX", role="match")
    check("different model -> live", len(CALLS) == 3)
    SETTINGS["openai_model"] = "model-a"
    SETTINGS["openai_base_url"] = "http://other/v1"
    gen("dyn", "x", static_prefix="PREFIX", role="match")
    check("different gateway -> live", len(CALLS) == 4)
    SETTINGS["openai_base_url"] = "http://gw/v1"
    SETTINGS["model_match"] = "model-override"
    gen("dyn", "x", static_prefix="PREFIX", role="match")
    check("different per-role model -> live", len(CALLS) == 5)
    SETTINGS.pop("model_match")

    print("never cached: translation chain, probes, no-role calls")
    CALLS.clear()
    for _ in range(2):
        gen("t", "x", static_prefix="P", role="translate")
    check("translate is always live", len(CALLS) == 2)
    for _ in range(2):
        gen("Reply with OK", "x", attempts=1)
    check("probe (attempts=1, no role) is always live", len(CALLS) == 4)
    for _ in range(2):
        gen("m", "x", role="match", attempts=1)
    check("attempts= given -> live even for a cached role", len(CALLS) == 6)

    print("bad replies are never stored or replayed")
    CALLS.clear()
    REPLY[0] = "not json at all"
    ok = llm._mapping_reply_ok
    gen("map", "x", static_prefix="S", role="mapping", cache_ok=ok)
    gen("map", "x", static_prefix="S", role="mapping", cache_ok=ok)
    check("unparsable mapping reply not cached", len(CALLS) == 2)
    REPLY[0] = '```json\n{"detailed": []}\n```'
    gen("map", "x", static_prefix="S", role="mapping", cache_ok=ok)
    gen("map", "x", static_prefix="S", role="mapping", cache_ok=ok)
    check("good mapping reply cached", len(CALLS) == 3)
    REPLY[0] = "   "
    gen("empty", "x", role="emotion")
    gen("empty", "x", role="emotion")
    check("empty reply not cached", len(CALLS) == 5)

    print("corrupt cache falls back silently")
    CALLS.clear()
    REPLY[0] = "fresh"
    key = llm._llm_cache_key(SETTINGS["provider"], "model-a", "http://gw/v1",
                             "PREFIX", "dyn")
    path = os.path.join(llm._LLM_CACHE_DIR, key + ".json")
    check("entry exists where expected", os.path.isfile(path))
    open(path, "w").write("{truncated")
    out = gen("dyn", "x", static_prefix="PREFIX", role="match")
    check("corrupt entry -> live call, no crash", len(CALLS) == 1
          and out == "fresh")
    out = gen("dyn", "x", static_prefix="PREFIX", role="match")
    check("...and the entry is healed", len(CALLS) == 1 and out == "fresh")

    print("switch")
    os.environ["DUB_LLM_CACHE"] = "0"
    try:
        CALLS.clear()
        gen("dyn", "x", static_prefix="PREFIX", role="match")
        check("DUB_LLM_CACHE=0 -> live", len(CALLS) == 1)
    finally:
        os.environ.pop("DUB_LLM_CACHE", None)


def test_parallel_shortening():
    print("parallel shortening keeps order and uses original context")
    # 6 EN cues of 1 s each; 8 TR sentences; sections 1..4 overrun.
    en = [(float(i), float(i) + 1.0, f"en {i}") for i in range(6)]
    tr = ["क" * 60 + f" {j}" for j in range(8)]
    sections = [{"en": [1], "tr": [1, 2]}, {"en": [2], "tr": [3]},
                {"en": [3], "tr": [4]}, {"en": [4], "tr": [5, 6]},
                {"en": [5], "tr": []}, {"en": [6], "tr": [7]}]
    import pipeline.match as match_mod
    real_match = match_mod.call_match_sections
    match_mod.call_match_sections = lambda *a, **k: (sections, [8], [])
    seen = []
    active = [0]
    peak = [0]
    lock = threading.Lock()

    def fake_generate(prompt, model, role=None, **kw):
        with lock:
            active[0] += 1
            peak[0] = max(peak[0], active[0])
            seen.append(prompt)
        # earlier sections answer later
        idx = int(prompt.split('Current translation to shorten: "')[1]
                  .split('"')[0].split()[-1])
        time.sleep(0.02 * (8 - idx))
        with lock:
            active[0] -= 1
        return f'"short-{idx}"'

    real_gen = agent_splitter._llm_generate
    agent_splitter._llm_generate = fake_generate
    try:
        secs, un_tr, un_en, out = agent_splitter.agentic_split_match(
            en, tr, "Hindi")
    finally:
        agent_splitter._llm_generate = real_gen
        match_mod.call_match_sections = real_match
    check("calls overlapped", peak[0] > 1)
    check("one call per overrunning section", len(seen) == 5)
    expect = list(tr)
    expect[0], expect[1] = "short-1", ""
    expect[2] = "short-2"
    expect[3] = "short-3"
    expect[4], expect[5] = "short-5", ""
    expect[6] = "short-6"
    check("sentences in original order, extras emptied", out == expect)
    # Section 3 (TR 4): previous context is TR 2..3 as ORIGINALLY written,
    # not the shortened / emptied versions.
    p = [x for x in seen if 'shorten: "' + tr[3] in x][0]
    check("neighbour context is the original text",
          f'Previous lines: "{tr[1]} | {tr[2]}"' in p)


def main():
    tmp = tempfile.mkdtemp(prefix="llm_cache_")
    real = (llm._get_llm_settings, llm._openai_chat, llm._LLM_CACHE_DIR)
    llm._get_llm_settings = lambda: SETTINGS
    llm._openai_chat = fake_chat
    llm._LLM_CACHE_DIR = tmp
    try:
        test_cache()
        test_parallel_shortening()
    finally:
        llm._get_llm_settings, llm._openai_chat, llm._LLM_CACHE_DIR = real
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n%s" % ("ALL OK" if not FAILS else "%d FAILED: %s"
                    % (len(FAILS), ", ".join(FAILS))))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
