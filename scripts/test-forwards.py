#!/usr/bin/env python3
"""Check forwarding against a disposable Rex, without a display or the user's server."""
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time


def main():
    if not shutil.which("rex") or not shutil.which("curl"):
        raise SystemExit("test-forward needs rex, curl and Python 3")
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="renux-forward-") as tmp:
        root = Path(tmp)
        env = os.environ.copy()
        for key in ("REX_SERVER", "REX_SESSION", "REX_BLOCK", "REX_CLIENT"):
            env.pop(key, None)
        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
            folder = root / key.lower()
            folder.mkdir()
            env[key] = str(folder)
        config = root / "init.lua"
        config.write_text("")
        unix = "unix://" + str(root / "rex.sock")
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            remote = f"http://127.0.0.1:{reservation.getsockname()[1]}"
        with (root / "rex.log").open("wb") as log:
            server = subprocess.Popen([
                "rex", "server", "run", "--listen", unix, "--extra-listen", remote,
                "--allow-anonymous", "--restore=false", "--config", str(config),
                "--state-dir", str(root / "state"),
            ], env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                def cli(*args):
                    return subprocess.check_output(
                        ["rex", "-S", unix, "--autostart=false", *args],
                        env=env, text=True, stderr=subprocess.STDOUT, timeout=10,
                    )

                until = time.monotonic() + 10
                while not (root / "rex.sock").exists():
                    assert server.poll() is None and time.monotonic() < until, "Isolated Rex didn't start"
                    time.sleep(0.02)
                handler = """
from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  body = (self.path + '\\n').encode()
  self.send_response(200)
  self.send_header('Content-Length', str(len(body)))
  self.end_headers()
  self.wfile.write(body)
server = HTTPServer(('127.0.0.1', 0), Handler)
print('READY_PORT=' + str(server.server_port), flush=True)
server.serve_forever()
"""
                created = json.loads(cli("new", "forward-test", "--json", "--shell=none", "--", sys.executable, "-u", "-c", handler))
                sid = created["session_id"]
                bid = created["initial_windows"][0]["block_ids"][0]
                until = time.monotonic() + 10
                while True:
                    match = re.search(r"READY_PORT=(\d+)", cli("capture", "-s", sid, "-b", bid, "--trim"))
                    if match:
                        break
                    assert time.monotonic() < until, "HTTP target didn't start"
                    time.sleep(0.02)
                test_env = dict(env, RENUX_FORWARD_TEST_URL=remote, RENUX_FORWARD_TEST_SESSION=sid,
                                RENUX_FORWARD_TEST_TARGET=f"http://localhost:{match[1]}/proof?from=integration#fragment")
                subprocess.run([binary], env=test_env, check=True, timeout=30)
                assert not json.loads(cli("forward", "ls", "-A", "--json"))["forwards"], "Tunnel block leaked"
                print("Forwarding: bytes, URL rewrite, listener reuse, host removal and early cancel passed")
            finally:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


if __name__ == "__main__":
    main()
