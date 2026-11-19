#!/usr/bin/env python3
"""C11H-50: the built CLI shows c11's version line. Offline: built artifact plus a fake peer.

`--version` and `version` print `c11 <version> (<build>) [<C11Commit>]`, read from the built
app's Info.plist, and `hc-diagnostics` prints the server's `c11_version` first. The peer is a
disposable socket in a temp dir that answers one `hc.diagnostics` call; no app is launched and
the operator's session is never contacted.

Usage: C11_CLI=<built .app>/Contents/Resources/bin/c11 python3 tests_v2/test_c11_version_line.py --offline
"""

import argparse
import json
import os
import plistlib
import re
import socket
import subprocess
import tempfile
import threading
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--offline", action="store_true", required=True)
    parser.parse_args()
    cli = os.environ["C11_CLI"]
    info_path = Path(cli).resolve().parents[2] / "Info.plist"
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)

    # c11 2.0: the version line is the plain marketing version, and CFBundleVersion is the plain
    # build number, so Sparkle orders every build after c11 1.8.x (C11H-265). Both come from the
    # caller too (the logic test bundle's own Info.plist), so a wrong value in the app fails.
    line = info["CFBundleShortVersionString"]
    assert re.fullmatch(r"\d+\.\d+\.\d+", line), ("not a plain version", line)
    assert "C11Version" not in info, ("the -hN version line is retired", info.get("C11Version"))
    c11_build = os.environ["C11_EXPECTED_BUILD"]
    c11_version = os.environ["C11_EXPECTED_VERSION"]
    assert re.fullmatch(r"\d+", c11_build), ("build not an integer", c11_build)
    assert int(c11_build) > 150, ("must order after c11 1.8.1 (build 150)", c11_build)
    assert line == c11_version, (line, c11_version)
    assert info["CFBundleVersion"] == c11_build, (info["CFBundleVersion"], c11_build)

    environment = dict(os.environ)
    for key in ("C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET", "CMUX_SOCKET_PATH"):
        environment.pop(key, None)

    def run(*arguments):
        proc = subprocess.run([cli, *arguments], capture_output=True, text=True, timeout=20,
                              env=environment, stdin=subprocess.DEVNULL)
        assert proc.returncode == 0, (arguments, proc.returncode, proc.stderr)
        return proc.stdout

    expected = "c11 %s (%s)" % (line, info["CFBundleVersion"])
    commit = (info.get("C11Commit") or "").strip().lower()
    if commit:
        expected += " [%s]" % commit
    version = run("--version").strip()
    assert version == expected, (version, expected)
    assert run("version").strip() == version

    with tempfile.TemporaryDirectory(prefix="c11-ver-", dir="/tmp") as directory:
        socket_path = str(Path(directory) / "peer.sock")
        errors = []
        served = "9.9.9-h9"
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(socket_path)
            listener.listen(1)
            listener.settimeout(20)

            methods = []

            def serve():
                # Answers every request on each connection the CLI opens (it may make a
                # preflight call first); only hc.diagnostics carries a result.
                try:
                    while "hc.diagnostics" not in methods:
                        with listener.accept()[0] as connection:
                            connection.settimeout(20)
                            with connection.makefile("rwb") as stream:
                                for request_line in stream:
                                    if request_line.startswith(b"auth "):
                                        stream.write(b"OK\n")
                                        stream.flush()
                                        continue
                                    request = json.loads(request_line)
                                    methods.append(request["method"])
                                    result = {}
                                    if request["method"] == "hc.diagnostics":
                                        result = {"c11_version": served, "holder_lost_count": 0, "panels": []}
                                    stream.write((json.dumps({"id": request["id"], "ok": True,
                                                              "result": result}) + "\n").encode())
                                    stream.flush()
                except Exception as error:
                    errors.append(error)

            peer = threading.Thread(target=serve, daemon=True)
            peer.start()
            try:
                output = run("--socket", socket_path, "hc-diagnostics")
            finally:
                peer.join(timeout=20)
            assert not peer.is_alive() and not errors, (errors, methods)
            assert "hc.diagnostics" in methods, methods
            lines = output.splitlines()
            assert lines[:2] == ["c11_version=" + served, "holder_lost_count=0"], lines

    print("PASS: c11 version line (%s)" % version)


if __name__ == "__main__":
    main()
