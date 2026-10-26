#!/usr/bin/env python3
"""C11-483: repository files cannot replace shipped starter layouts.

Run only through scripts/sandbox-tests-v2.sh in a fresh sandbox guest.
The explicit-path control proves terminal commands really execute there.
"""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import time

from cmux import cmux, cmuxError


def main():
    assert Path("/Volumes/My Shared Files").is_dir(), "sandbox guest required"
    target = os.environ.get("C11_SOCKET", "")
    assert re.fullmatch(r"/tmp/(?:c11|cmux)-debug-[^/]+\.sock", target), "explicit tagged socket required"
    cli = os.environ.get("C11_CLI")
    assert cli and Path(cli).is_file(), "C11_CLI must identify the guest artifact"
    env = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_"))}
    for key in ("C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET", "CMUX_SOCKET_PATH"):
        env[key] = target

    with tempfile.TemporaryDirectory(prefix="c11-483-shadow-", dir="/tmp") as temporary, cmux(target) as client:
        repo = Path(temporary) / "repo"
        directory = repo / ".c11" / "blueprints"
        directory.mkdir(parents=True)
        subprocess.run(["git", "init", "--quiet", str(repo)], check=True, timeout=10)
        marker = Path(temporary) / "hostile-command-ran"
        control = Path(temporary) / "explicit-command-ran"
        created = []

        def blueprint(name, destination):
            return {"version": 1, "name": name, "plan": {
                "version": 1, "workspace": {},
                "layout": {"type": "pane", "pane": {"panelIds": ["one"]}},
                "panels": [{"id": "one", "kind": "terminal",
                            "command": "printf ran > " + shlex.quote(str(destination)),
                            "submitCommand": True}]}}

        (directory / "layout.json").write_text(json.dumps(blueprint("basic-terminal", marker)))
        for name in ("quad", "single", "basic-terminal", "starter:quad", "two-columns", "agent-room", "unknown"):
            (repo / name).write_text(json.dumps(blueprint("root-file", marker)))
        (repo / "control.json").write_text(json.dumps(blueprint("control", control)))

        def run(*arguments, accepted=True):
            result = subprocess.run([cli, "--socket", target, "--json", "--id-format", "uuids", *arguments],
                                    cwd=repo, env=env, text=True, capture_output=True, timeout=20)
            if accepted:
                assert result.returncode == 0, (arguments, result.stdout, result.stderr)
                return json.loads(result.stdout)
            assert result.returncode != 0, (arguments, result.stdout)

        def remember(result):
            workspace = result["workspace_id"]
            created.append(workspace)
            return workspace

        def verify(workspace, count):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                panels = client._call("panel.list", {"workspace_id": workspace})["panels"]
                areas = client._call("area.list", {"workspace_id": workspace})["areas"]
                assert not marker.exists(), "repository command executed"
                if len(panels) == count and len(areas) == count:
                    assert all(panel["type"] == "terminal" for panel in panels), panels
                    return
                time.sleep(0.1)
            raise AssertionError(("wrong starter layout", count, panels, areas))

        try:
            baseline = client.current_workspace()
            control_workspace = remember(run("new-workspace", "--layout", "./control.json"))
            deadline = time.monotonic() + 10
            while not control.exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            assert control.exists(), "explicit-path command control did not execute; invalid proof"
            client.close_workspace(control_workspace)
            created.remove(control_workspace)

            for layout, count in ((None, 1), ("quad", 4), ("Single", 1), ("basic-terminal", 1), ("quad ", 4)):
                params = {"dir": str(repo), "cwd": str(repo), "launch_agent": False}
                if layout is not None:
                    params["layout"] = layout
                verify(remember(client._call("workspace.create_in_directory", params)), count)

            for layout, count in (("quad", 4), ("Single", 1), ("basic-terminal", 1), ("quad ", 4)):
                verify(remember(run("workspace", "new", "--dir", ".", "--layout", layout)), count)
            for layout, count in (("quad", 4), ("Single", 1), ("Basic-Terminal", 1)):
                verify(remember(run("new-workspace", "--layout", layout)), count)

            for command in (("new-workspace", "--layout", "unknown"),
                            ("workspace", "new", "--dir", ".", "--layout", "unknown")):
                run(*command, accepted=False)
            try:
                client._call("workspace.create_in_directory", {"dir": str(repo), "layout": "unknown"})
                raise AssertionError("bare cwd file was accepted as a layout")
            except cmuxError as error:
                assert "layout_not_found" in str(error), error

            for name in ("basic-terminal", " Single ", "agent-room", "starter:unknown", "saved:missing"):
                try:
                    client._call("workspace.export_blueprint", {"name": name, "workspace_id": created[0]})
                    raise AssertionError("reserved export name accepted: " + name)
                except cmuxError as error:
                    assert "invalid_params" in str(error), error

            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                assert not marker.exists(), "repository command executed"
                time.sleep(0.05)
            assert client.current_workspace() == baseline, "creation changed selected workspace"
        finally:
            for workspace in reversed(created):
                client.close_workspace(workspace)

    print("PASS: shipped layouts resist repo shadows through socket and both CLI routes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
