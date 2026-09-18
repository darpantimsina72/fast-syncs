#!/usr/bin/env python3
"""Regression loop for the LLM call's transient-failure retry.

Symptom this guards against: a legacy dub pays ElevenLabs for speech and
Scribe for transcribing it, THEN makes the EN<->target mapping call. On
2026-09-16 a Windows run died there with

    ConnectionResetError: [WinError 10054] An existing connection was
    forcibly closed by the remote host

and the whole paid run was lost. Two separate defects: the error escaped
every handler (urllib wraps only send-side errors in URLError, so one raised
while READING the reply arrives raw), and nothing retried.

Offline, deterministic, no API calls and no network: urlopen is replaced.

Run:  dubbing/venv/bin/python tests/test_llm_retry.py
"""
import http.client
import io
import json
import os
import socket
import sys
import urllib.error

sys.path.insert(0, os.path.join(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))), "dubbing", "engine"))
from pipeline import llm  # noqa: E402

FAILS = 0


def _http_error(code):
    return urllib.error.HTTPError("http://x/v1/chat/completions", code,
                                  "boom", {}, io.BytesIO(b"{}"))


def test_classifier():
    """Only genuinely transient failures may be retried."""
    retry = [
        ConnectionResetError(10054, "forcibly closed"),   # the reported bug
        ConnectionAbortedError(10053, "aborted"),
        BrokenPipeError(32, "broken pipe"),
        TimeoutError("read timed out"),
        socket.timeout("timed out"),
        http.client.RemoteDisconnected("closed without response"),
        http.client.IncompleteRead(b"half"),
        urllib.error.URLError("dns went away"),
        _http_error(500), _http_error(502), _http_error(503),
        _http_error(504), _http_error(429),
    ]
    no_retry = [
        _http_error(400), _http_error(401), _http_error(403),
        _http_error(404), _http_error(422),
        ValueError("bad json"), KeyError("choices"),
    ]
    for e in retry:
        assert llm._llm_retryable(e), f"should retry: {e!r}"
    for e in no_retry:
        assert not llm._llm_retryable(e), f"must NOT retry: {e!r}"
    print("  classifier: %d retryable, %d fatal — OK"
          % (len(retry), len(no_retry)))


class _Resp:
    """Minimal stand-in for the urlopen context manager."""
    def __init__(self, body):
        self._body = body.encode("utf-8")

    def read(self):
        return self._body

    def geturl(self):
        return "http://x/v1/chat/completions"

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _install_fake(fail_times, exc):
    """urlopen that raises *exc* the first *fail_times* calls, then answers."""
    state = {"calls": 0}

    def fake_urlopen(req, timeout=None):
        state["calls"] += 1
        if state["calls"] <= fail_times:
            raise exc
        return _Resp(json.dumps(
            {"choices": [{"message": {"content": "mapped"}}]}))

    llm.urllib.request.urlopen = fake_urlopen
    return state


def test_recovers_after_resets():
    """Three resets in a row, then a good reply — the call still succeeds."""
    state = _install_fake(3, ConnectionResetError(
        10054, "An existing connection was forcibly closed by the remote host"))
    out = llm._openai_chat("hi", "some-model")
    assert out == "mapped", out
    assert state["calls"] == 4, state["calls"]
    print("  recovered after 3 resets in %d calls — OK" % state["calls"])


def test_gives_up_with_a_clear_message():
    """Every attempt reset: a RuntimeError naming the endpoint, not a raw
    ConnectionResetError traceback."""
    state = _install_fake(99, ConnectionResetError(10054, "forcibly closed"))
    try:
        llm._openai_chat("hi", "some-model")
    except RuntimeError as e:
        assert "Lost the connection" in str(e), str(e)
        assert state["calls"] == llm._LLM_ATTEMPTS, state["calls"]
        print("  gave up after %d attempts with a RuntimeError — OK"
              % state["calls"])
        return
    except ConnectionResetError:
        raise AssertionError("raw ConnectionResetError escaped again")
    raise AssertionError("no error raised")


def test_probe_does_not_wait():
    """attempts=1 (the start-of-run probe) must fail on the first try."""
    state = _install_fake(99, ConnectionResetError(10054, "forcibly closed"))
    try:
        llm._openai_chat("hi", "some-model", attempts=1)
    except RuntimeError:
        assert state["calls"] == 1, state["calls"]
        print("  probe stopped after 1 attempt — OK")
        return
    raise AssertionError("no error raised")


def main():
    # No real sleeping, and no real settings file needed.
    llm.time.sleep = lambda _s: None
    llm._get_llm_settings = lambda: {
        "provider": "openai", "openai_base_url": "http://x/v1",
        "openai_api_key": "k", "openai_model": "some-model"}
    fails = 0
    for fn in (test_classifier, test_recovers_after_resets,
               test_gives_up_with_a_clear_message, test_probe_does_not_wait):
        print(fn.__name__)
        try:
            fn()
        except AssertionError as e:
            fails += 1
            print("  FAILED: %s" % e)
    print("\n%s" % ("ALL OK" if not fails else "%d FAILED" % fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
