#!/usr/bin/env python3
"""Docker integration: SSH remains usable while remote c11 commands are unavailable."""

from __future__ import annotations

import glob
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
# Keep the fixture's extra HTTP server below 1024 so there are no eligible
# (>1023) ports to auto-forward. This guards the "connecting forever" regression.
REMOTE_HTTP_PORT = int(os.environ.get("CMUX_SSH_TEST_REMOTE_HTTP_PORT", "81"))


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    from cmux import find_cli_binary

    return find_cli_binary()


def _run(cmd: list[str], *, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env, check=False)
    if check and proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"Command failed ({' '.join(cmd)}): {merged}")
    return proc


def _run_cli_json(cli: str, args: list[str]) -> dict:
    env = dict(os.environ)
    # Explicitly address the test app socket.
    env.pop("CMUX_SOCKET_PATH", None)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("C11_TAB_ID", None)
    env.pop("C11_TAB_ID", None)
    env.pop("CMUX_TAB_ID", None)
    env.pop("C11_TAB_ID", None)

    proc = _run([cli, "--socket", SOCKET_PATH, "--json", "--id-format", "both", *args], env=env)
    try:
        return json.loads(proc.stdout or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {proc.stdout!r} ({exc})")


def _docker_available() -> bool:
    if shutil.which("docker") is None:
        return False
    probe = _run(["docker", "info"], check=False)
    return probe.returncode == 0


def _parse_host_port(docker_port_output: str) -> int:
    text = docker_port_output.strip()
    if not text:
        raise cmuxError("docker port output was empty")
    last = text.split(":")[-1]
    return int(last)


def _shell_single_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def _ssh_run(host: str, host_port: int, key_path: Path, script: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return _run(
        [
            "ssh",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=5",
            "-p", str(host_port),
            "-i", str(key_path),
            host,
            f"sh -lc {_shell_single_quote(script)}",
        ],
        check=check,
    )


def _wait_for_ssh(host: str, host_port: int, key_path: Path, timeout: float = 20.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        probe = _ssh_run(host, host_port, key_path, "echo ready", check=False)
        if probe.returncode == 0 and "ready" in probe.stdout:
            return
        time.sleep(0.5)
    raise cmuxError("Timed out waiting for SSH server in docker fixture to become ready")


def _wait_for_remote_ready(client, workspace_id: str, timeout: float = 45.0) -> dict:
    deadline = time.time() + timeout
    last_status = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        daemon = remote.get("daemon") or {}
        state = str(remote.get("state") or "")
        daemon_state = str(daemon.get("state") or "")
        if state == "connected" and daemon_state == "ready":
            return last_status
        time.sleep(0.5)
    raise cmuxError(f"Remote daemon did not become ready: {last_status}")


def _assert_remote_commands_unavailable(host: str, host_port: int, key_path: Path, session_id: int) -> None:
    wrapper_dir = f"$HOME/.cmux/ssh/{session_id}.shell/bin"
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        probe = _ssh_run(host, host_port, key_path, f'test -x "{wrapper_dir}/c11" && test -x "{wrapper_dir}/cmux"', check=False)
        if probe.returncode == 0:
            break
        time.sleep(0.2)
    for command_name in ("c11", "cmux"):
        result = _ssh_run(host, host_port, key_path, f'"{wrapper_dir}/{command_name}" ping', check=False)
        _must(result.returncode != 0, f"{command_name} unexpectedly succeeded: {result.stdout!r}")
        _must(
            "c11 commands are not available over c11 ssh in this version" in result.stderr,
            f"{command_name} should explain unavailable commands: {result.stderr!r}",
        )

    result = _ssh_run(host, host_port, key_path, f'"{wrapper_dir}/c11" rpc system.ping', check=False)
    _must(result.returncode != 0, "remote rpc unexpectedly succeeded")
    _must(
        "c11 commands are not available over c11 ssh in this version" in result.stderr,
        "remote rpc should explain unavailable commands",
    )


def main() -> int:
    if not _docker_available():
        print("SKIP: docker is not available")
        return 0

    cli = _find_cli_binary()
    repo_root = Path(__file__).resolve().parents[1]
    fixture_dir = repo_root / "tests" / "fixtures" / "ssh-remote"
    _must(fixture_dir.is_dir(), f"Missing docker fixture directory: {fixture_dir}")

    temp_dir = Path(tempfile.mkdtemp(prefix="cmux-ssh-cli-relay-"))
    image_tag = f"cmux-ssh-test:{secrets.token_hex(4)}"
    container_name = f"cmux-ssh-cli-relay-{secrets.token_hex(4)}"
    workspace_id = ""
    workspace_id_2 = ""

    try:
        # Generate SSH key pair
        key_path = temp_dir / "id_ed25519"
        _run(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path)])
        pubkey = (key_path.with_suffix(".pub")).read_text(encoding="utf-8").strip()
        _must(bool(pubkey), "Generated SSH public key was empty")

        # Build and start Docker container
        _run(["docker", "build", "-t", image_tag, str(fixture_dir)])
        _run([
            "docker", "run", "-d", "--rm",
            "--name", container_name,
            "-e", f"AUTHORIZED_KEY={pubkey}",
            "-e", f"REMOTE_HTTP_PORT={REMOTE_HTTP_PORT}",
            "-p", "127.0.0.1::22",
            image_tag,
        ])

        port_info = _run(["docker", "port", container_name, "22/tcp"]).stdout
        host_ssh_port = _parse_host_port(port_info)
        host = "root@127.0.0.1"
        _wait_for_ssh(host, host_ssh_port, key_path)

        with cmux(SOCKET_PATH) as client:
            # Create an SSH workspace and wait for its remote daemon.
            payload = _run_cli_json(
                cli,
                [
                    "ssh",
                    host,
                    "--name", "docker-cli-relay",
                    "--port", str(host_ssh_port),
                    "--identity", str(key_path),
                    "--ssh-option", "UserKnownHostsFile=/dev/null",
                    "--ssh-option", "StrictHostKeyChecking=no",
                ],
            )
            workspace_id = str(payload.get("workspace_id") or "")
            workspace_ref = str(payload.get("workspace_ref") or "")
            if not workspace_id and workspace_ref.startswith("workspace:"):
                listed = client._call("workspace.list", {}) or {}
                for row in listed.get("workspaces") or []:
                    if str(row.get("ref") or "") == workspace_ref:
                        workspace_id = str(row.get("id") or "")
                        break
            _must(bool(workspace_id), f"cmux ssh output missing workspace_id: {payload}")
            _must("remote_relay_port" not in payload, f"SSH should not advertise a command relay: {payload}")
            session_id = payload.get("ssh_session_id")
            _must(isinstance(session_id, int), f"SSH session identity missing: {payload}")
            workspace_window_id = payload.get("window_id")
            current_params = {"window_id": workspace_window_id} if isinstance(workspace_window_id, str) and workspace_window_id else {}
            current = client._call("workspace.current", current_params) or {}
            current_workspace_id = str(current.get("workspace_id") or "")
            _must(
                current_workspace_id == workspace_id,
                f"cmux ssh should focus created workspace: current={current_workspace_id!r} created={workspace_id!r}",
            )

            # Wait for daemon to be ready
            first_status = _wait_for_remote_ready(client, workspace_id)
            first_remote = first_status.get("remote") or {}
            # Regression: should transition to connected even with no eligible
            # (>1023, non-ephemeral) remote ports.
            _must(
                not (first_remote.get("detected_ports") or []),
                f"expected no eligible detected ports in fixture: {first_status}",
            )
            _must(
                not (first_remote.get("forwarded_ports") or []),
                f"expected no forwarded ports when none are eligible: {first_status}",
            )

            _assert_remote_commands_unavailable(host, host_ssh_port, key_path, session_id)

            # A second workspace to the same destination still has its own lifecycle.
            payload_2 = _run_cli_json(
                cli,
                [
                    "ssh",
                    host,
                    "--name", "docker-cli-relay-2",
                    "--port", str(host_ssh_port),
                    "--identity", str(key_path),
                    "--ssh-option", "UserKnownHostsFile=/dev/null",
                    "--ssh-option", "StrictHostKeyChecking=no",
                ],
            )
            workspace_id_2 = str(payload_2.get("workspace_id") or "")
            workspace_ref_2 = str(payload_2.get("workspace_ref") or "")
            if not workspace_id_2 and workspace_ref_2.startswith("workspace:"):
                listed_2 = client._call("workspace.list", {}) or {}
                for row in listed_2.get("workspaces") or []:
                    if str(row.get("ref") or "") == workspace_ref_2:
                        workspace_id_2 = str(row.get("id") or "")
                        break
            _must(bool(workspace_id_2), f"second cmux ssh output missing workspace_id: {payload_2}")

            _must("remote_relay_port" not in payload_2, f"SSH should not advertise a command relay: {payload_2}")
            _must(payload_2.get("ssh_session_id") != session_id, "SSH sessions should have distinct identities")
            _wait_for_remote_ready(client, workspace_id_2)
            _assert_remote_commands_unavailable(host, host_ssh_port, key_path, int(payload_2["ssh_session_id"]))
            shell_probe = _ssh_run(host, host_ssh_port, key_path, "printf shell-ready")
            _must(shell_probe.stdout == "shell-ready", f"Remote shell failed: {shell_probe.stdout!r}")

            # Cleanup
            try:
                client.close_workspace(workspace_id)
            except Exception:
                pass
            workspace_id = ""
            if workspace_id_2:
                try:
                    client.close_workspace(workspace_id_2)
                except Exception:
                    pass
                workspace_id_2 = ""

        print("PASS: SSH sessions remain available and remote c11 commands explain their unavailability")
        return 0

    finally:
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass
        if workspace_id_2:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id_2)
            except Exception:
                pass

        _run(["docker", "rm", "-f", container_name], check=False)
        _run(["docker", "rmi", "-f", image_tag], check=False)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
