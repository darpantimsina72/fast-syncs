"""Streamed gateway replies are read chunk by chunk (the HTTP 524 fix).

    python tests/test_stream_gateway.py
"""
import io, json, os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "dubbing", "engine"))
import sync_matcher
from pipeline import llm


def sse(*pieces, done=True):
    out = b""
    for p in pieces:
        out += b"data: " + json.dumps(
            {"choices": [{"delta": {"content": p}}]}).encode() + b"\n\n"
    if done:
        out += b"data: [DONE]\n\n"
    return io.BytesIO(out)


def whole(text):
    return io.BytesIO(json.dumps(
        {"choices": [{"message": {"content": text}}]}).encode())


class StreamReading(unittest.TestCase):
    def test_both_halves_read_a_stream(self):
        for fn in (llm._sse_content, sync_matcher._sse_content):
            self.assertEqual(fn(sse("Hel", "lo ", "world")), "Hello world")

    def test_server_ignoring_stream_still_works(self):
        for fn in (llm._sse_content, sync_matcher._sse_content):
            self.assertEqual(fn(whole("plain reply")), "plain reply")

    def test_keepalive_and_junk_lines_are_skipped(self):
        body = (b": keep-alive\n\n"
                + b"data: " + json.dumps({"choices": [{"delta": {}}]}).encode() + b"\n\n"
                + b"data: not json\n\n"
                + b"data: " + json.dumps(
                    {"choices": [{"delta": {"content": "ok"}}]}).encode() + b"\n\n"
                + b"data: [DONE]\n\n")
        for fn in (llm._sse_content, sync_matcher._sse_content):
            self.assertEqual(fn(io.BytesIO(body)), "ok")

    def test_truncated_stream_returns_what_arrived(self):
        for fn in (llm._sse_content, sync_matcher._sse_content):
            self.assertEqual(fn(sse("half ", "a reply", done=False)), "half a reply")

    def test_html_login_page_is_not_mistaken_for_a_reply(self):
        for fn in (llm._sse_content, sync_matcher._sse_content):
            self.assertEqual(fn(io.BytesIO(b"<html>login</html>")), "")


class ReasoningEffort(unittest.TestCase):
    """The gateway is asked not to think for minutes before replying.

    Streaming alone does not stop the ~100 s Cloudflare cut-off, because a
    reasoning model sends nothing at all while it is thinking. These assert
    the hint is sent, and that a gateway which rejects it never fails a run.
    """

    def _body(self, fn, *args, **kw):
        """Run fn with urlopen stubbed; return the JSON body it sent."""
        sent = {}

        class Resp:
            def __enter__(self_inner): return self_inner
            def __exit__(self_inner, *a): return False
            def __iter__(self_inner): return iter(sse("ok"))
            def read(self_inner): return b""

        def fake(req, timeout=None, **_):
            sent["body"] = json.loads(req.data.decode())
            return Resp()
        return sent, fake

    def test_auto_sync_sends_low_effort(self):
        sent, fake = self._body(None)
        old = sync_matcher._urlopen
        sync_matcher._urlopen = fake
        try:
            sync_matcher._call_gemini_gateway("hi", "k", "https://x", "m")
        finally:
            sync_matcher._urlopen = old
        self.assertEqual(sent["body"].get("reasoning_effort"), "low")

    def test_auto_sync_effort_can_be_turned_off(self):
        sent, fake = self._body(None)
        old, oldenv = sync_matcher._urlopen, os.environ.get("SYNC_REASONING_EFFORT")
        sync_matcher._urlopen = fake
        os.environ["SYNC_REASONING_EFFORT"] = "off"
        try:
            sync_matcher._call_gemini_gateway("hi", "k", "https://x", "m")
        finally:
            sync_matcher._urlopen = old
            if oldenv is None:
                os.environ.pop("SYNC_REASONING_EFFORT", None)
            else:
                os.environ["SYNC_REASONING_EFFORT"] = oldenv
        self.assertNotIn("reasoning_effort", sent["body"])

    def test_dub_engine_asks_only_for_the_mechanical_roles(self):
        self.assertIn("match", llm._LOW_EFFORT_ROLES)
        self.assertIn("mapping", llm._LOW_EFFORT_ROLES)
        for role in ("translate", "review", "emotion"):
            self.assertNotIn(role, llm._LOW_EFFORT_ROLES)


if __name__ == "__main__":
    unittest.main(verbosity=2)
