"""End-to-end check of claude-rotate-proxy.py against a FAKE upstream and a sandbox seat store.

No real tokens, no network beyond 127.0.0.1. Run:  py -I C:\\Dev\\Rotators\\claude-rotate-proxy-test.py
Covers: quota 429 -> rotate -> retry on the new seat; a foreign token passes through untouched;
nothing to rotate to -> the client gets the original 429 (no replay); usage headers land in the
seat's usage-cache.json; the health endpoint.
"""
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
RL = "anthropic-ratelimit-unified-"
seen = []


class Fake(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        tok = (self.headers.get("authorization") or "")[7:]
        seen.append(tok)
        if tok == "tok-A":   # seat A's session window is spent
            body = b'{"type":"error","error":{"type":"rate_limit_error","message":"spent"}}'
            self.send_response(429)
            for k, v in (("status", "rejected"), ("5h-status", "rejected"), ("5h-utilization", "1.0")):
                self.send_header(RL + k, v)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header(RL + "status", "allowed")
        self.send_header(RL + "5h-utilization", "0.12")
        self.send_header(RL + "7d_oi-utilization", "0.40")
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        for part in (b"event: a\ndata: one\n\n", b"event: b\ndata: two\n\n"):
            self.wfile.write(part)
            self.wfile.flush()
            time.sleep(0.05)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def call(port, token, path="/v1/messages"):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    c.request("POST", path, body=json.dumps({"model": "m", "messages": []}),
              headers={"authorization": "Bearer " + token, "content-type": "application/json"})
    r = c.getresponse()
    return r.status, r.read()


def main():
    root = tempfile.mkdtemp(prefix="crp-test-")
    for seat in ("A", "B"):
        os.makedirs(os.path.join(root, seat))
        with open(os.path.join(root, seat, "token.txt"), "w") as f:
            f.write("tok-" + seat)
    with open(os.path.join(root, ".active"), "w") as f:
        f.write("A")
    rot = os.path.join(root, "fake_rotator.py")
    with open(rot, "w") as f:   # rotates A -> B unless told not to
        f.write("import os\nr=%r\nif not os.path.exists(os.path.join(r,'.no-rotate')):\n"
                "    open(os.path.join(r,'.active'),'w').write('B')\n" % root)

    up = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
    threading.Thread(target=up.serve_forever, daemon=True).start()
    port = free_port()
    env = dict(os.environ, CLAUDE_ROTATE_PROXY_PORT=str(port),
               CLAUDE_ROTATE_PROXY_TEST_UPSTREAM="127.0.0.1:%d" % up.server_address[1],
               CLAUDE_ROTATE_PROXY_TEST_ROOT=root, CLAUDE_ROTATE_PROXY_TEST_ROTATOR=rot)
    proxy = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "claude-rotate-proxy.py")], env=env)
    try:
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)

        # 1. quota 429 on A -> rotator flips to B -> same request retried on B, streamed through
        status, body = call(port, "tok-A")
        assert status == 200, (status, body)
        assert body == b"event: a\ndata: one\n\nevent: b\ndata: two\n\n", body
        assert seen == ["tok-A", "tok-B"], seen
        assert open(os.path.join(root, ".active")).read() == "B"
        a = json.load(open(os.path.join(root, "A", "usage-cache.json")))["data"]
        assert a["s5_stat"] == "rejected" and a["src"] == "proxy", a
        b = json.load(open(os.path.join(root, "B", "usage-cache.json")))["data"]
        assert b["s5_util"] == "0.12" and b["label"] == "B", b
        assert json.load(open(os.path.join(root, "B", "usage-cache-fable.json")))["data"]["oi7_util"] == "0.40"
        print("ok  quota 429 rotated and retried on the next seat")

        # 2. a session still holding A's token now rides B without restarting
        seen.clear()
        status, _ = call(port, "tok-A")
        assert status == 200 and seen == ["tok-B"], (status, seen)
        print("ok  running session follows the rotation")

        # 3. a token the rotator does not own is forwarded untouched
        seen.clear()
        status, _ = call(port, "foreign")
        assert status == 200 and seen == ["foreign"], (status, seen)
        print("ok  foreign token passes through")

        # 4. nowhere to rotate: the client gets the original 429, with no replay upstream
        with open(os.path.join(root, ".active"), "w") as f:
            f.write("A")
        open(os.path.join(root, ".no-rotate"), "w").close()
        time.sleep(21)   # past the proxy's rotate cooldown, so the rotator really is asked
        seen.clear()
        status, body = call(port, "tok-A")
        assert status == 429 and b"spent" in body and seen == ["tok-A"], (status, body, seen)
        print("ok  nothing to rotate to -> original 429, no replay")

        # 5. health
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        c.request("GET", "/__proxy/health")
        h = json.loads(c.getresponse().read())
        assert h["ok"] and h["active"] == "A", h
        print("ok  health endpoint")
        print("ALL PASSED")
    finally:
        proxy.terminate()
        up.shutdown()


if __name__ == "__main__":
    main()
