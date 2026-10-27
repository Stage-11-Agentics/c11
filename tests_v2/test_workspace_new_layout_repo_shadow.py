#!/usr/bin/env python3
"""C11-483: repository files cannot replace shipped starter layouts.

Run only through scripts/sandbox-tests-v2.sh in a fresh sandbox guest.
The explicit-path control proves an explicit path still applies its own plan;
hostile plans have a shape no starter has, so the shape check is decisive.
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
        repo = (Path(temporary) / "repo").resolve()
        directory = repo / ".c11" / "blueprints"
        directory.mkdir(parents=True)
        subprocess.run(["git", "init", "--quiet", str(repo)], check=True, timeout=10)
        marker = Path(temporary) / "hostile-command-ran"
        control = Path(temporary) / "explicit-command-ran"
        created = []
        bundle = client._call("system.brand")["bundle"]["identifier"]
        assert ".debug." in bundle, "tagged debug bundle required"
        key = "createWorkspace.lastBlueprintId"
        previous_default = subprocess.run(["/usr/bin/defaults", "read", bundle, key],
                                          text=True, capture_output=True, timeout=10)
        default_changed = False
        baseline_ids = {row["id"] for row in client._call("workspace.list")["workspaces"]}

        def blueprint(name, destination, count=5):
            def layout(ids):
                if len(ids) == 1:
                    return {"type": "pane", "pane": {"panelIds": ids}}
                return {"type": "split", "split": {"orientation": "horizontal", "dividerPosition": 0.5,
                        "first": layout(ids[:1]), "second": layout(ids[1:])}}
            ids = ["panel-" + str(index) for index in range(count)]
            return {"version": 1, "name": name, "plan": {
                "version": 1, "workspace": {},
                "layout": layout(ids),
                "panels": [{"id": panel, "kind": "terminal",
                            "command": "printf ran > " + shlex.quote(str(destination)),
                            "submitCommand": True} for panel in ids]}}

        (directory / "layout.json").write_text(json.dumps(blueprint("basic-terminal", marker)))
        for name in ("quad", "single", "basic-terminal", "starter:quad", "two-columns", "agent-room", "unknown"):
            (repo / name).write_text(json.dumps(blueprint("root-file", marker)))
        (repo / "control.json").write_text(json.dumps(blueprint("control", control, count=2)))

        def run(*arguments, accepted=True):
            result = subprocess.run([cli, "--socket", target, "--json", "--id-format", "uuids", *arguments],
                                    cwd=repo, env=env, text=True, capture_output=True, timeout=20)
            if result.stdout.strip():
                remember(json.loads(result.stdout))
            if accepted:
                assert result.returncode == 0, (arguments, result.stdout, result.stderr)
                return json.loads(result.stdout)
            assert result.returncode != 0, (arguments, result.stdout)

        def remember(result):
            workspace = result.get("workspace_id")
            if workspace and workspace not in created:
                created.append(workspace)
            return workspace

        def verify(workspace, count, browser=False, allow_marker=False):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                panels = client._call("panel.list", {"workspace_id": workspace})["panels"]
                areas = client._call("area.list", {"workspace_id": workspace})["areas"]
                if not allow_marker:
                    assert not marker.exists(), "repository command executed"
                if len(panels) == count and len(areas) == count:
                    expected = ["terminal"] * count
                    if browser:
                        expected[-1] = "browser"
                    assert sorted(panel["type"] for panel in panels) == sorted(expected), panels
                    return
                time.sleep(0.1)
            raise AssertionError(("wrong starter layout", count, panels, areas))

        try:
            baseline = client.current_workspace()
            # A background workspace's terminals attach (and run queued commands)
            # only once viewed, so the proof is the applied shape: an explicit path
            # still loads its own 2-pane plan, and every hostile plan has 5 panes.
            control_workspace = remember(run("new-workspace", "--layout", "./control.json"))
            verify(control_workspace, 2, allow_marker=True)
            client.close_workspace(control_workspace)
            created.remove(control_workspace)

            entries = client._call("workspace.list_blueprints", {"cwd": str(repo)})["blueprints"]
            repo_entry = next(entry for entry in entries if entry["source"] == "repo" and entry["name"] == "basic-terminal")
            saved_reference = "saved:" + repo_entry["url"]
            default_changed = True
            subprocess.run(["/usr/bin/defaults", "write", bundle, key, "-string", saved_reference], check=True, timeout=10)
            time.sleep(0.25)

            for layout, count in ((None, 1), ("quad", 4), ("Single", 1), ("basic-terminal", 1), ("quad ", 4)):
                params = {"dir": str(repo), "cwd": str(repo), "launch_agent": False}
                if layout is not None:
                    params["layout"] = layout
                verify(remember(client._call("workspace.create_in_directory", params)), count)

            for layout, count in (("quad", 4), ("Single", 1), ("basic-terminal", 1), ("quad ", 4),
                                  ("starter:quad", 4), ("two-columns", 2)):
                verify(remember(run("workspace", "new", "--dir", ".", "--layout", layout)), count)
            verify(remember(run("workspace", "new", "--dir", ".", "--layout", "agent-room")), 3, browser=True)
            for layout, count in (("quad", 4), ("Single", 1), ("Basic-Terminal", 1)):
                verify(remember(run("new-workspace", "--layout", layout)), count)

            for command in (("new-workspace", "--layout", "unknown"),
                            ("workspace", "new", "--dir", ".", "--layout", "unknown")):
                run(*command, accepted=False)
            try:
                remember(client._call("workspace.create_in_directory", {"dir": str(repo), "layout": "unknown"}))
                raise AssertionError("bare cwd file was accepted as a layout")
            except cmuxError as error:
                assert "layout_not_found" in str(error), error

            for name in ("basic-terminal", " Single ", "agent-room", "starter:unknown", "saved:missing", "team/dev", ".x", "x.json"):
                try:
                    client._call("workspace.export_blueprint", {"name": name, "workspace_id": created[0]})
                    raise AssertionError("reserved export name accepted: " + name)
                except cmuxError as error:
                    assert "invalid_params" in str(error), error

            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                assert not marker.exists(), "repository command executed"
                time.sleep(0.05)

            # Explicit saved selection still applies the repo's distinctive five-pane plan.
            saved_workspace = remember(run("new-workspace", "--layout", saved_reference))
            verify(saved_workspace, 5, allow_marker=True)
            assert client.current_workspace() == baseline, "creation changed selected workspace"
        finally:
            try:
                # Include any workspace returned by an unexpectedly successful rejection case.
                remaining = {row["id"] for row in client._call("workspace.list")["workspaces"]} - baseline_ids
                for workspace in remaining:
                    client.close_workspace(workspace)
            finally:
                if default_changed:
                    if previous_default.returncode == 0:
                        subprocess.run(["/usr/bin/defaults", "write", bundle, key, "-string",
                                        previous_default.stdout.removesuffix("\n")], check=True, timeout=10)
                    else:
                        subprocess.run(["/usr/bin/defaults", "delete", bundle, key], check=True, timeout=10)

    print("PASS: shipped layouts resist repo shadows through socket and both CLI routes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
