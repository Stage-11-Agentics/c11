#!/usr/bin/env python3
"""C11-284 bundled-CLI smoke. Use --offline for built-artifact checks in CI.

Live mode requires C11_CLI and C11_SOCKET_PATH from a tagged/sandbox build.
Never point this script at the operator's session. It only reads capabilities.
"""

import argparse
import json
import os
import plistlib
import shutil
from pathlib import Path
import subprocess
import tempfile
import socket
import threading
import uuid


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

    def run(*arguments, ok=True, environment=None, error_contains=None):
        proc = subprocess.run([cli, *arguments], capture_output=True, text=True,
                              timeout=20, env=environment)
        assert (proc.returncode == 0) == ok, (arguments, proc.returncode, proc.stderr)
        if error_contains is not None:
            assert error_contains in proc.stderr, (arguments, proc.stderr)
        return proc.stdout

    # A tag-derived listener is the first implicit discovery candidate. Clear
    # every socket override: plain guide and its alias/help must never probe it.
    environment = dict(os.environ)
    for key in ("C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET", "CMUX_SOCKET_PATH"):
        environment.pop(key, None)
    environment["CMUX_TAG"] = "c11-guide-" + uuid.uuid4().hex
    discoverable_socket = "/tmp/cmux-debug-" + environment["CMUX_TAG"] + ".sock"
    try:
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(discoverable_socket)
            listener.listen(8)
            listener.settimeout(0.1)
            plain = run("guide", environment=environment)
            assert plain == run("--skill", environment=environment)
            implicit_guide = json.loads(run("--json", "guide", environment=environment))
            assert implicit_guide == json.loads(run("--skill", "--json", environment=environment))
            help_text = run("guide", "--help", environment=environment)
            assert "Usage: c11 guide" in help_text
            assert help_text == run("--skill", "--help", environment=environment)
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                pass
            else:
                connection.close()
                raise AssertionError("bundled guide/help connected to a discoverable listener")
    finally:
        Path(discoverable_socket).unlink(missing_ok=True)

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
        assert guide["cli"]["short_version"] and guide["cli"]["build"]
        # Plain XCTest builds can be unstamped; guide must report the built
        # artifact, including an unknown commit, rather than infer checkout HEAD.
        bundle = next(parent for parent in Path(cli).resolve().parents if parent.suffix == ".app")
        with (bundle / "Contents/Info.plist").open("rb") as info_file:
            info = plistlib.load(info_file)
        stamped_commit = info.get("C11Commit") or info.get("CMUXCommit")
        assert guide["cli"]["commit"] == (stamped_commit.strip().lower() if stamped_commit else None)
        # The bundled skill and `--help` both teach panel, never the tab alias.
        assert "rename-panel" in guide["body"] and "rename-tab" not in guide["body"]
        help_text = run("--help")
        assert "rename-panel" in help_text and "rename-tab" not in help_text
        assert "There is no `c11 list`" in guide["body"]
        assert "Usage: c11 guide" in run("--socket", dead_socket, "guide", "--help")
        assert "Discovery & state" in run("--socket", dead_socket, "guide", "api")
        # The guide opens with its authority line, in both forms, before the page.
        assert any(l.startswith("This is c11 ") for l in human.split("\n")[:3]), human[:300]
        assert guide["authority"].startswith("This is c11 ") and \
            "that command does not exist here" in guide["authority"]
        assert guide["authority"] in human.split("\n\n")[0]
        assert "This guide matches the build you are in" in guide["body"]
        # A verb this build lacks, with --help, needs no server: the hint, not 'Run c11 help'.
        # (Not a real c11 verb: c11 syncs bring those in; `fleet` arrived with C11H-51.)
        proc = subprocess.run([cli, "--socket", dead_socket, "no-such-c11-verb", "--help"],
                              capture_output=True, text=True, timeout=20)
        assert "'no-such-c11-verb' is not in c11 " in proc.stdout and "run 'c11 guide'" in proc.stdout, proc
        # c11-2.0:begin-keep (the retired c11h sidecar folded into c11, C11H-269)
        # c11 installs the bundled skills MANIFEST.json lists, only on the operator's explicit
        # command. `c11h`, the retired sidecar, means `c11`; an unstamped c11h folder is never touched.
        skill_home = Path(directory) / "skill-home"
        (skill_home / ".claude" / "skills" / "c11h").mkdir(parents=True)
        c11h_copy = skill_home / ".claude" / "skills" / "c11h" / "SKILL.md"
        c11h_copy.write_text("the operator's own c11h folder, not stamped by c11\n")
        (skill_home / ".claude" / "settings.json").write_text('{"tenant": true}\n')
        before_c11h = c11h_copy.read_bytes()
        before_settings = (skill_home / ".claude" / "settings.json").read_bytes()
        listed = json.loads(run("--socket", dead_socket, "skill", "status", "--json", "--home", str(skill_home)))
        offered = [p["package"] for row in listed["targets"] if row["tool"] == "claude" for p in row["packages"]]
        assert "c11" in offered and "c11-browser" in offered and "c11h" not in offered, listed
        installed_out = run("--socket", dead_socket, "skill", "install", "c11h", "--home", str(skill_home))
        assert "part of the c11 skill now" in installed_out and "installed: c11" in installed_out, installed_out
        sidecar = skill_home / ".claude" / "skills" / "c11"
        assert (sidecar / "SKILL.md").read_text().startswith("---\nname: c11\n"), (sidecar / "SKILL.md").read_text()[:80]
        assert (sidecar / ".c11-skill.json").exists()
        assert sorted(p.name for p in (skill_home / ".claude" / "skills").iterdir()) == ["c11", "c11h"]
        assert "skipped (up-to-date): c11" in run("--socket", dead_socket, "skill", "install", "c11", "--home", str(skill_home))
        for verb in ("install", "remove"):
            run("--socket", dead_socket, "skill", verb, "no-such-skill", "--home", str(skill_home), ok=False,
                error_contains="No bundled skill named 'no-such-skill'")
        # Sol's review of #288: names are honoured, and a retired copy someone else owns is kept.
        def skill_json(*arguments, home):
            return json.loads(run("--socket", dead_socket, "skill", *arguments, "--home", str(home), "--json"))

        def stamped_c11h(home, installed_by="app", edit=False):
            # A real stamp: install c11 into a scratch home, then relabel the copy as the old sidecar.
            scratch = Path(tempfile.mkdtemp(prefix="c11-skill-src-", dir=directory))
            (scratch / ".claude").mkdir()
            skill_json("install", "c11", home=scratch)
            copy = scratch / ".claude" / "skills" / "c11"
            stamp = json.loads((copy / ".c11-skill.json").read_text())
            stamp["package"], stamp["installed_by"] = "c11h", installed_by
            (copy / ".c11-skill.json").write_text(json.dumps(stamp))
            if edit:
                (copy / "SKILL.md").write_text("the operator's own instructions\n")
            target = home / ".claude" / "skills" / "c11h"
            shutil.rmtree(target, ignore_errors=True)
            shutil.move(str(copy), str(target))
            return target

        multi_home = Path(directory) / "multi-home"
        (multi_home / ".claude").mkdir(parents=True)
        both = skill_json("install", "c11", "c11-browser", home=multi_home)
        assert sorted(both["installed"]) == ["c11", "c11-browser"], both
        unchanged = stamped_c11h(multi_home)
        assert skill_json("install", "c11-browser", "--force", home=multi_home)["retired"] == [], "another package's install"
        assert unchanged.exists()
        named = skill_json("remove", "c11", home=multi_home)
        assert named["removed"] == ["c11"] and named["retired"] == [], named
        assert (multi_home / ".claude" / "skills" / "c11-browser").exists(), "a named remove spares the others"
        assert unchanged.exists()
        alias = skill_json("remove", "c11h", home=multi_home)
        assert alias["removed"] == [] and alias["retired"] == ["c11h"], alias
        assert not unchanged.exists() and (multi_home / ".claude" / "skills" / "c11-browser").exists()
        edited = stamped_c11h(multi_home, edit=True)
        kept = skill_json("install", "c11", home=multi_home)
        assert kept["retired"] == [] and "c11h" in kept["kept_local"], kept
        assert (edited / "SKILL.md").read_text() == "the operator's own instructions\n"
        assert skill_json("install", "c11", "--force", home=multi_home)["retired"] == ["c11h"]
        assert not edited.exists()
        synced = stamped_c11h(multi_home, installed_by="sync")
        unforced = skill_json("remove", home=multi_home)
        assert unforced["retired"] == [] and "c11h" in unforced["kept_local"] and synced.exists(), unforced
        # c11-2.0:end-keep
        run("--socket", dead_socket, "skill", "install", "--tool", "codex", "--home", str(skill_home), ok=False,
            error_contains="not found")
        assert not (skill_home / ".codex").exists()
        assert "removed: c11" in run("--socket", dead_socket, "skill", "remove", "c11", "--home", str(skill_home))
        assert not sidecar.exists()
        assert c11h_copy.read_bytes() == before_c11h  # c11-2.0:keep
        assert (skill_home / ".claude" / "settings.json").read_bytes() == before_settings
        # c11-2.0:begin-keep
        # C11H-265: the retired name `c11h` stays a hidden alias for this build's CLI. A
        # different `c11` earlier on PATH (c11's dev shim in ~/.cargo/bin) cannot change what it
        # runs, and it speaks as `c11`: the old name never reaches its output or hints.
        alias = Path(cli).with_name("c11h")
        assert os.access(alias, os.X_OK), f"bundle has no executable {alias}"
        decoy = Path(directory) / "decoy"
        decoy.mkdir()
        (decoy / "c11").write_text("#!/bin/sh\necho 'c11 guide of the OTHER build'\n")
        (decoy / "c11").chmod(0o755)
        env_decoy = dict(os.environ, PATH=f"{decoy}:{os.environ['PATH']}")
        env_decoy.pop("C11_INVOKED_AS", None)
        other = subprocess.run(["c11", "guide"], capture_output=True, text=True, timeout=20, env=env_decoy)
        assert "OTHER build" in other.stdout, other  # the decoy really does shadow `c11`
        named = subprocess.run([str(alias), "--socket", dead_socket, "guide"],
                               capture_output=True, text=True, timeout=20, env=env_decoy)
        direct = subprocess.run([cli, "--socket", dead_socket, "guide"],
                                capture_output=True, text=True, timeout=20, env=env_decoy)
        assert named.returncode == 0 and named.stdout.startswith("c11 "), named
        assert named.stdout == direct.stdout, (named.stdout[:200], direct.stdout[:200])
        by_path = subprocess.run(["c11h", "--socket", dead_socket, "guide"], capture_output=True,
                                 text=True, timeout=20, env=dict(env_decoy, PATH=f"{decoy}:{alias.parent}:{os.environ['PATH']}"))
        assert by_path.stdout == named.stdout, by_path
        for runner in (str(alias), cli):
            hint = subprocess.run([runner, "--socket", dead_socket, "no-such-c11-verb", "--help"],
                                  capture_output=True, text=True, timeout=20, env=env_decoy)
            assert "run 'c11 guide'" in hint.stdout and "c11h" not in hint.stdout, (runner, hint)
        # c11-2.0:end-keep
        spoofed = subprocess.run([cli, "--socket", dead_socket, "no-such-c11-verb", "--help"], capture_output=True,
                                 text=True, timeout=20, env=dict(env_decoy, C11_INVOKED_AS="rm -rf"))
        assert "run 'c11 guide'" in spoofed.stdout, spoofed
        # C11H-269: the c11h sidecar folded into the guide's pages; every verb they name for c11-2.0:keep
        # persistence and other machines is one the built CLI has, and `guide c11h` still answers. c11-2.0:keep
        for verb in (["hc", "server", "status"], ["hc", "ls"], ["hc", "get"], ["hc", "run"], ["retry-input"],
                     ["restore", "status"], ["restore", "run"], ["machine", "link"], ["machine", "unlink"],
                     ["machine", "list"], ["send-key"], ["close-workspace"], ["move-panel"],
                     ["move-workspace-to-window"], ["hc-diagnostics"]):
            said = subprocess.run([cli, "--socket", dead_socket, *verb, "--help"],
                                  capture_output=True, text=True, timeout=20)
            assert f"'{verb[0]}' is not in c11 " not in said.stdout, (verb, said.stdout[:200])
        persistence = run("--socket", dead_socket, "guide", "persistence")
        assert "When input is paused" in persistence and "Outside signals" in persistence, persistence[:300]
        assert run("--socket", dead_socket, "guide", "c11h") == persistence  # c11-2.0:keep (hidden alias)
        # C11H-90: --json and --id-format are accepted after any command (and still before it).
        # A peer that answers every request OK lets each command's own parser run.
        any_dir = tempfile.mkdtemp(prefix="c11-anyok-", dir="/tmp")
        any_path = str(Path(any_dir) / "any.sock")
        any_listener = socket.socket(socket.AF_UNIX)
        any_listener.bind(any_path)
        any_listener.listen(16)

        seen_methods = []

        def answer_everything():
            def talk(connection):
                with connection, connection.makefile("rwb") as stream:
                    for line in stream:
                        if line.startswith(b"auth "):
                            stream.write(b"OK\n")
                        else:
                            try:
                                request = json.loads(line)
                                seen_methods.append(request.get("method"))
                                stream.write((json.dumps({"id": request.get("id"), "ok": True, "result": {}}) + "\n").encode())
                            except ValueError:
                                stream.write(b"OK\n")
                        stream.flush()
            while True:
                try:
                    connection, _ = any_listener.accept()
                except OSError:
                    return
                threading.Thread(target=talk, args=(connection,), daemon=True).start()

        threading.Thread(target=answer_everything, daemon=True).start()
        try:
            panel_env = dict(os.environ, C11_WORKSPACE_ID="11111111-1111-1111-1111-111111111111",
                             C11_PANEL_ID="22222222-2222-2222-2222-222222222222")
            for words in (["new-workspace", "--json"], ["mailbox", "recv", "--json"], ["mailbox", "recv", "--ack", "--json"],
                          ["list-workspaces", "--id-format", "both"], ["mailbox", "recv", "--id-format", "both"],
                          ["new-workspace", "--id-format=uuids", "--json"], ["tree", "--json"]):
                said = subprocess.run([cli, "--socket", any_path, *words], capture_output=True, text=True,
                                      timeout=20, env=panel_env)
                assert "nknown flag" not in said.stderr + said.stdout, (words, said)
            # A command's own value option named --json keeps its value: it is the JSON body.
            body = subprocess.run([cli, "--socket", any_path, "set-metadata", "--panel",
                                   "22222222-2222-2222-2222-222222222222", "--json", '{"role":"reviewer"}'],
                                  capture_output=True, text=True, timeout=20, env=panel_env)
            assert body.returncode == 0 and "panel.set_metadata" in seen_methods, (body, seen_methods)
            seen_methods.clear()
            body = subprocess.run([cli, "--socket", any_path, "set-workspace-metadata", "--json", '{"k":"v"}'],
                                  capture_output=True, text=True, timeout=20, env=panel_env)
            assert body.returncode == 0 and any(m and m.endswith("set_metadata") for m in seen_methods), (body, seen_methods)
            # The offline commands take the global flags in any position too.
            plain_guide = subprocess.run([cli, "--socket", any_path, "guide"], capture_output=True, text=True, timeout=20)
            with_flag = subprocess.run([cli, "--socket", any_path, "guide", "--id-format", "both"],
                                       capture_output=True, text=True, timeout=20)
            assert with_flag.returncode == 0 and with_flag.stdout == plain_guide.stdout, with_flag
            # (usage and report run the same helper; their offline analysis is too slow to run here.)
            missing = subprocess.run([cli, "--socket", any_path, "tree", "--id-format"], capture_output=True,
                                     text=True, timeout=20, env=panel_env)
            assert missing.returncode != 0 and "--id-format requires a value" in missing.stderr, missing
        finally:
            any_listener.close()
        run("--socket", dead_socket, "guide", "../SKILL", ok=False)
        run("--socket", dead_socket, "guide", "missing-fixture-page", ok=False)

    # Execute the real CLI's comparison against a synthetic peer, including
    # older servers without identity. This is fixture proof, not a live app run.
    cli_sha = guide["cli"]["commit"]
    for server_sha, expected in [(cli_sha, True if cli_sha else None),
                                 ("111111111" if not (cli_sha or "").startswith("111111111") else "222222222",
                                  False if cli_sha else None),
                                 (None, None)]:
        with tempfile.TemporaryDirectory(prefix="c11-caps-", dir="/tmp") as directory:
            socket_path = str(Path(directory) / "peer.sock")
            errors = []
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(socket_path)
                listener.listen(1)
                listener.settimeout(20)

                def serve(expect_request=True):
                    try:
                        with listener.accept()[0] as connection:
                            connection.settimeout(20)
                            with connection.makefile("rwb") as stream:
                                line = stream.readline()
                                if line.startswith(b"auth "):
                                    stream.write(b"OK\n")
                                    stream.flush()
                                    line = stream.readline()
                                if not expect_request:
                                    assert not line, line
                                    return
                                request = json.loads(line)
                                assert request["method"] == "system.capabilities", request
                                result = {"methods": ["system.capabilities"], "features": [], "features_version": 1}
                                if server_sha is not None:
                                    result["server"] = {"commit": server_sha}
                                stream.write((json.dumps({"id": request["id"], "ok": True, "result": result}) + "\n").encode())
                                stream.flush()
                                # c11's socket is persistent: its read loop
                                # updates SO_RCVTIMEO after the response. Keep
                                # the peer alive until the client disconnects.
                                stream.read()
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
                if expected is True:
                    # A reachable peer proves rejection is command validation,
                    # rather than the unrelated missing-socket failure.
                    for verb in ("list", "no-such-c11-verb"):
                        peer = threading.Thread(target=lambda: serve(False), daemon=True)
                        peer.start()
                        try:
                            proc = subprocess.run([cli, "--socket", socket_path, verb],
                                                  capture_output=True, text=True, timeout=20)
                        finally:
                            peer.join(timeout=20)
                        assert not peer.is_alive() and not errors, errors
                        assert proc.returncode != 0 and proc.stdout == "", (verb, proc)
                        assert f"Unknown command: {verb}" in proc.stderr, proc.stderr
                        # Hint first, usage behind it, both on stderr.
                        hint = f"'{verb}' is not in c11 "
                        assert proc.stderr.startswith(hint) and "run 'c11 guide'" in proc.stderr.split("\n")[0], proc.stderr
                        assert proc.stderr.index(hint) < proc.stderr.index("Usage"), proc.stderr

    assert skill_state(skill_root) == before, "guide modified the installed skill"
    if not args.offline:
        live_socket = os.environ["C11_SOCKET_PATH"]
        payload = json.loads(run("--socket", live_socket, "--json", "capabilities"))
        ids = {item["id"] for item in payload["features"]}
        assert payload["features_version"] == 1
        assert {"vocabulary.workspace_area_panel", "send.explicit_panel", "events.offline"} <= ids
        assert not ids & {"vocabulary.workspace_area_tab", "send.explicit_tab"}, ids
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
