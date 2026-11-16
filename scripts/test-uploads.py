#!/usr/bin/env python3
"""Exercise the upload client against a disposable local Rex, never the user's server."""
import argparse
import os
from pathlib import Path
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib


def main():
    rex = shutil.which("rex")
    if not rex:
        raise SystemExit("test-upload needs the rex CLI/server on PATH")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clipboard", action="store_true")
    parser.add_argument("--preview", action="store_true")
    parser.add_argument("test_binary")
    args = parser.parse_args()
    test_binary = str(Path(args.test_binary).resolve())
    graphical = args.clipboard or args.preview
    if graphical and not shutil.which("gtk4-broadwayd"):
        raise SystemExit("test-clipboard needs gtk4-broadwayd for its private display")
    with tempfile.TemporaryDirectory(prefix="renux-upload-") as tmp:
        root = Path(tmp)
        env = os.environ.copy()
        for key, directory in {
            "HOME": "home", "TMPDIR": "tmp", "XDG_CONFIG_HOME": "config",
            "XDG_CACHE_HOME": "cache", "XDG_STATE_HOME": "state", "XDG_DATA_HOME": "data",
        }.items():
            (root / directory).mkdir()
            env[key] = str(root / directory)
        config = root / "init.lua"
        config.write_text("")
        url = "unix://" + str(root / "server.sock")
        env.update(REX_SERVER=url, REX_CONFIG=str(config))
        log = root / "server.log"
        command = [rex, "server", "run", "--listen", url, "--restore=false",
                   "--config", str(config), "--state-dir", str(root / "state")]
        if graphical:
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                remote_url = f"http://127.0.0.1:{reservation.getsockname()[1]}"
            command += ["--extra-listen", remote_url, "--allow-anonymous"]
        with log.open("wb") as output:
            server = subprocess.Popen(command, env=env, stdout=output, stderr=subprocess.STDOUT)
            processes = [server]
            try:
                if graphical:
                    runtime = root / "runtime"
                    runtime.mkdir(mode=0o700)
                    env.update(XDG_RUNTIME_DIR=str(runtime), GDK_BACKEND="broadway",
                               BROADWAY_DISPLAY=":1", GSETTINGS_BACKEND="memory", G_DEBUG="fatal-warnings")
                    display = subprocess.Popen([
                        "gtk4-broadwayd", "--unixsocket=" + str(root / "display.sock"), ":1",
                    ], env=env, stdout=output, stderr=subprocess.STDOUT)
                    processes.append(display)
                    until = time.monotonic() + 5
                    while not list(runtime.glob("broadway*.socket")):
                        assert display.poll() is None and time.monotonic() < until, "Private display did not start"
                        time.sleep(0.02)

                def cli(*args):
                    return subprocess.check_output(
                        [rex, "-S", url, "--autostart=false", *args], env=env, text=True,
                        stderr=subprocess.STDOUT, timeout=10,
                    )

                until = time.monotonic() + 10
                while not (root / "server.sock").exists():
                    if server.poll() is not None or time.monotonic() > until:
                        raise AssertionError("Isolated Rex did not start")
                    time.sleep(0.02)
                # Raw input is recorded, never executed as a shell command.
                import json
                record = root / "pasted.bin"
                logger = (
                    "import os,sys,tty; tty.setraw(0); "
                    "f=open(sys.argv[1],'ab',buffering=0); print('READY',flush=True)\n"
                    "while True:\n"
                    " b=os.read(0,65536)\n"
                    " if not b: break\n"
                    " f.write(b)\n"
                )
                created = json.loads(cli(
                    "new", "upload-test", "--json", "-c", str(root), "--shell=none", "--",
                    sys.executable, "-u", "-c", logger, str(record),
                ))
                sid = created["session_id"]
                bid = created["initial_windows"][0]["block_ids"][0]
                until = time.monotonic() + 10
                while "READY" not in cli("capture", "-s", sid, "-b", bid, "--trim"):
                    assert time.monotonic() < until, "Input recorder did not start"
                    time.sleep(0.02)
                env.update(RENUX_UPLOAD_TEST_URL=url, RENUX_UPLOAD_TEST_SESSION=sid, RENUX_UPLOAD_TEST_BLOCK=bid)
                regular = root / "screen shot ' <&> ü.bin"
                data = bytes(range(256)) * (4 * 1024)  # 1 MiB, all byte values.
                regular.write_bytes(data)
                link = root / "linked.bin"
                link.symlink_to(regular)
                empty = root / "empty.bin"
                empty.touch()
                second = root / "second file.bin"
                second.write_bytes(b"second\n" * 5000)
                fifo = root / "pipe"
                os.mkfifo(fifo)
                cases = [
                    ("success", regular), ("empty", empty), ("symlink", link), ("duplicate", regular),
                    ("cancel-preparing", regular), ("cancel-sending", regular),
                    ("cancel-finishing", regular), ("host-removed", regular),
                    ("missing", root / "missing"), ("directory", root), ("fifo", fifo),
                    ("old-server", regular), ("grow", regular), ("shrink", regular),
                    ("batch", regular), ("batch-cancel", regular),
                ]
                if graphical:
                    def chunk(kind, payload):
                        return struct.pack("!I", len(payload)) + kind + payload + struct.pack("!I", zlib.crc32(kind + payload))
                    image = root / "fixture.png"
                    image.write_bytes(
                        b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 3, 1, 8, 6, 0, 0, 0))
                        + chunk(b"IDAT", zlib.compress(b"\x00\xff\x64\x00\xff\x0a\x14\x1e\x80\x00\x00\x00\x00"))
                        + chunk(b"IEND", b"")
                    )
                    cases = [(mode, regular if mode.endswith("file") else image) for mode in [
                        "image", "texture", "file", "uri-file", "ctrlv-image", "ctrlv-file",
                        "local-image", "local-file", "text", "ctrlv-text", "shell-ctrlv",
                        "destroy-pane", "destroy-host", "invalid-image", "save-failure", "multiple-file",
                    ]]
                if args.preview:
                    text = root / "read me ü.txt"
                    text.write_text("Preview text\n世界\n")
                    large = root / "large.bin"
                    with large.open("wb") as f:
                        f.truncate(16 * 1024 * 1024 + 1)
                    cases = [("text", text), ("image", image), ("empty", empty), ("binary", regular),
                             ("relative", text), ("symlink", link), ("missing", root / "missing"),
                             ("directory", root), ("large", large), ("cancel", text),
                             ("host-removed", text), ("old-server", text)]
                for mode, source in cases:
                    regular.write_bytes(data)
                    record.write_bytes(b"")
                    test_env = dict(env, RENUX_UPLOAD_TEST_FILE=str(source), RENUX_UPLOAD_TEST_FILE2=str(second))
                    expected = source
                    if args.preview:
                        test_env.update(RENUX_PREVIEW_TEST_MODE=mode, RENUX_PREVIEW_TEST_EXPECTED=str(source),
                                        RENUX_UPLOAD_TEST_URL=remote_url,
                                        RENUX_UPLOAD_TEST_FILE=source.name if mode == "relative" else str(source))
                    elif args.clipboard:
                        expected = source if mode.endswith("file") else root / "normalized.png"
                        test_env.update(RENUX_CLIPBOARD_TEST_MODE=mode, RENUX_CLIPBOARD_TEST_RECORD=str(record),
                                        RENUX_CLIPBOARD_TEST_EXPECTED=str(expected),
                                        RENUX_UPLOAD_TEST_URL=url if mode.startswith("local-") else remote_url)
                        if mode == "save-failure":
                            test_env["TMPDIR"] = str(root / "nonexistent")
                    else:
                        test_env["RENUX_UPLOAD_TEST_MODE"] = mode
                    result = subprocess.run([test_binary], env=test_env, capture_output=True, text=True, timeout=30)
                    if result.returncode:
                        raise AssertionError(f"{mode}:\n{result.stdout}\n{result.stderr}")
                    time.sleep(0.1)
                    pasted = record.read_bytes().decode("utf-8").replace("\x1b[200~", "").replace("\x1b[201~", "")
                    if args.preview:
                        assert not pasted, (mode, "Preview must never paste anything", pasted)
                        assert not list((root / "tmp").glob("renux-preview-*")), (mode, "Preview temp file leaked")
                        print(f"PASS preview {mode}: no terminal input", flush=True)
                        continue
                    if args.clipboard and mode in ("text", "ctrlv-text", "shell-ctrlv"):
                        assert pasted == ("ordinary clipboard text" if mode == "text" else "\x16"), (mode, pasted)
                        print(f"PASS {mode}: text/terminal shortcut preserved", flush=True)
                        continue
                    paths = shlex.split(pasted)
                    # Several files go as one batch: every path is pasted once, in the order given.
                    several = [source, second] if mode == "batch" else [source, source] if mode == "multiple-file" else None
                    assert len(paths) <= (len(several) if several else 1), (mode, "Path was pasted more than once", pasted)
                    no_paste = mode.startswith("destroy-") or mode in ("invalid-image", "save-failure")
                    success = not no_paste if args.clipboard else mode in ("success", "empty", "symlink", "duplicate", "batch")
                    if success:
                        assert len(paths) == (len(several) if several else 1), (mode, "Not every path was pasted", pasted)
                    elif mode != "cancel-finishing":
                        assert not paths, (mode, "Cancelled/failed paste produced a path", pasted)
                    for position, path in enumerate(paths):
                        uploaded = Path(path)
                        assert uploaded.is_relative_to(root), ("Paste escaped the disposable directory", path)
                        wanted = several[position] if several else expected
                        assert uploaded.read_bytes() == wanted.read_bytes(), (mode, "Pasted file bytes differ")
                        if mode == "local-image":
                            assert uploaded.stat().st_mode & 0o777 == 0o600, "Clipboard image is not private"
                            uploaded.unlink()  # This test has finished reading its retained local image.
                    if args.clipboard:
                        assert not list((root / "tmp").glob("renux-clipboard-*.png")), (mode, "Temporary image leaked")
                    print(f"PASS {mode}: {len(paths)} path(s) pasted", flush=True)
            except BaseException:
                print(log.read_text(errors="replace"), file=sys.stderr)
                raise
            finally:
                for process in reversed(processes):
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    main()
