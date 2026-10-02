#!/usr/bin/env python3
"""C11-284 bundled-CLI smoke. Use --offline for built-artifact checks in CI.

Live mode requires C11_CLI and C11_SOCKET_PATH from a tagged/sandbox build.
Never point this script at the operator's session. It only reads capabilities.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import socket
import threading


def skill_state(root):
    if not root.exists():
        return None
    return {str(path.relative_to(root)): (path.stat().st_mtime_ns, path.stat().st_size)
            for path in [root, *root.rglob("*")] if path.exists()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--foundation-only", action="store_true",
                        help="assert that the five later-ticket features are absent")
    args = parser.parse_args()
    cli = os.environ["C11_CLI"]
    skill_root = Path.home() / ".claude/skills/c11"
    before = skill_state(skill_root)

    def run(*arguments, ok=True):
        proc = subprocess.run([cli, *arguments], capture_output=True, text=True, timeout=20)
        assert (proc.returncode == 0) == ok, (arguments, proc.returncode, proc.stderr)
        return proc.stdout

    # An explicit non-existent path proves this command does not need a server,
    # even on a machine that happens to have an app running.
    with tempfile.TemporaryDirectory(prefix="c11-guide-") as directory:
        dead_socket = str(Path(directory) / "absent.sock")
        guide = json.loads(run("--socket", dead_socket, "--json", "guide"))
        alias = json.loads(run("--socket", dead_socket, "--skill", "--json"))
        assert guide == alias, (guide.keys(), alias.keys())
        human = run("--socket", dead_socket, "guide")
        assert human.startswith("c11 ") and human.endswith(guide["body"])
        assert guide["source"] == "bundle" and guide["skill_version"] is not None
        assert guide["cli"]["short_version"] and guide["cli"]["build"] and guide["cli"]["commit"]
        assert "rename-tab" in guide["body"] and "rename-tab" in run("--help")
        assert "There is no `c11 list`" in guide["body"]
        run("--socket", dead_socket, "list", ok=False)
        assert "Usage: c11 guide" in run("--socket", dead_socket, "guide", "--help")
        assert "Discovery & state" in run("--socket", dead_socket, "guide", "api")
        run("--socket", dead_socket, "guide", "../SKILL", ok=False)
        run("--socket", dead_socket, "guide", "missing-fixture-page", ok=False)

    # Execute the real CLI's comparison against a synthetic peer, including
    # older servers without identity. This is fixture proof, not a live app run.
    for server_sha, expected in [(guide["cli"]["commit"], True),
                                 ("111111111" if not guide["cli"]["commit"].startswith("111111111") else "222222222", False),
                                 (None, None)]:
        with tempfile.TemporaryDirectory(prefix="c11-caps-", dir="/tmp") as directory:
            socket_path = str(Path(directory) / "peer.sock")
            errors = []
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(socket_path)
                listener.listen(1)
                listener.settimeout(20)

                def serve():
                    try:
                        with listener.accept()[0] as connection:
                            connection.settimeout(20)
                            with connection.makefile("rwb") as stream:
                                line = stream.readline()
                                if line.startswith(b"auth "):
                                    stream.write(b"OK\n")
                                    stream.flush()
                                    line = stream.readline()
                                request = json.loads(line)
                                assert request["method"] == "system.capabilities", request
                                result = {"methods": ["system.capabilities"], "features": [], "features_version": 1}
                                if server_sha is not None:
                                    result["server"] = {"commit": server_sha}
                                stream.write((json.dumps({"id": request["id"], "ok": True, "result": result}) + "\n").encode())
                                stream.flush()
                    except Exception as error:
                        errors.append(error)

                peer = threading.Thread(target=serve, daemon=True)
                peer.start()
                try:
                    comparison = json.loads(run("--socket", socket_path, "--json", "capabilities"))
                finally:
                    peer.join(timeout=20)
                assert not peer.is_alive() and not errors, errors
                assert comparison["sha_match"] is expected, comparison
                assert comparison["cli"] == guide["cli"]
                if server_sha is not None:
                    assert comparison["server"]["commit"] == server_sha

    assert skill_state(skill_root) == before, "guide modified the installed skill"
    if not args.offline:
        live_socket = os.environ["C11_SOCKET_PATH"]
        payload = json.loads(run("--socket", live_socket, "--json", "capabilities"))
        ids = {item["id"] for item in payload["features"]}
        assert payload["features_version"] == 1
        assert {"vocabulary.workspace_area_tab", "send.explicit_tab", "events.offline"} <= ids
        if args.foundation_only:
            assert not ids & {"routing.canonical_keys", "create.initial_input", "send.raw",
                              "read_selection.terminal", "window.route_without_focus"}
        for identity in (payload["cli"], payload["server"]):
            assert {"short_version", "build", "commit", "bundle_identifier"} <= identity.keys()
        cli_sha, server_sha = payload["cli"]["commit"], payload["server"]["commit"]
        expected = (cli_sha.startswith(server_sha) or server_sha.startswith(cli_sha)) if cli_sha and server_sha else None
        assert payload["sha_match"] is expected, payload
    print("PASS C11-284 bundled guide" + (" (offline)" if args.offline else " and server features"))


if __name__ == "__main__":
    main()
