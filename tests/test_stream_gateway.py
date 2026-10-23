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


if __name__ == "__main__":
    unittest.main(verbosity=2)
