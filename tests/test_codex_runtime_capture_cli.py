#!/usr/bin/env python3
"""Executable coverage for Codex runtime identity capture and claim expiry."""

from __future__ import annotations

import glob
import json
import os
import shutil
import socketserver
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path


def resolve_c11_cli() -> str:
    explicit = os.environ.get("C11_CLI_BIN") or os.environ.get("CMUX_CLI_BIN")
    if explicit and os.path.isfile(explicit) and os.access(explicit, os.X_OK):
        return explicit
    candidates = glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/c11"
    ))
    candidates = [path for path in candidates if os.access(path, os.X_OK)]
    if candidates:
        return max(candidates, key=os.path.getmtime)
    found = shutil.which("c11")
    if found:
        return found
    raise RuntimeError("Unable to find c11 CLI binary; set C11_CLI_BIN")


class CaptureState:
    def __init__(self) -> None:
        self.requests: list[dict] = []


class Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        for line in self.rfile:
            request = json.loads(line)
            self.server.state.requests.append(request)  # type: ignore[attr-defined]
            response = {
                "id": request.get("id"),
                "ok": True,
                "result": {"accepted": True},
            }
            self.wfile.write((json.dumps(response) + "\n").encode())
            self.wfile.flush()


class Server(socketserver.ThreadingUnixStreamServer):
    allow_reuse_address = True

    def __init__(self, path: str, state: CaptureState) -> None:
        self.state = state
        super().__init__(path, Handler)


def runtime_env(surface: str, thread_id: str) -> dict[str, str]:
    env = os.environ.copy()
    for key in ("C11_SURFACE_ID", "CMUX_SURFACE_ID", "CODEX_THREAD_ID"):
        env.pop(key, None)
    env.update({
        "C11_SURFACE_ID": surface,
        "CMUX_SURFACE_ID": surface,
        "CODEX_THREAD_ID": thread_id,
        "PWD": "/deliberately/not/the/subprocess/cwd",
        "CMUX_CLI_SENTRY_DISABLED": "1",
    })
    return env


def run(cli: str, socket_path: str, args: list[str], env: dict[str, str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [cli, "--socket", socket_path, *args],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )


def expect(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    failures: list[str] = []
    try:
        cli = resolve_c11_cli()
    except RuntimeError as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="c11-codex-runtime-cli-") as raw_tmp:
        tmp = Path(raw_tmp)
        socket_path = str(tmp / "c11.sock")
        state = CaptureState()
        server = Server(socket_path, state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            caller_surface = str(uuid.uuid4())
            caller_thread_id = str(uuid.uuid4())
            os.environ["C11_SURFACE_ID"] = caller_surface
            os.environ["CMUX_SURFACE_ID"] = caller_surface
            os.environ["CODEX_THREAD_ID"] = caller_thread_id
            surface = str(uuid.uuid4())
            thread_id = str(uuid.uuid4())
            env = runtime_env(surface, thread_id)
            proc = run(cli, socket_path, ["conversation", "capture-runtime"], env, tmp)
            expect(proc.returncode == 0, f"capture-runtime failed: {proc.stderr}", failures)
            request = state.requests[-1] if state.requests else {}
            expect(request.get("method") == "conversation.capture_runtime", f"wrong method: {request}", failures)
            params = request.get("params", {})
            expect(params == {"surface_id": surface, "id": thread_id, "cwd": os.path.realpath(tmp)}, f"wrong runtime params: {params}", failures)
            expect(params.get("id") != caller_thread_id and params.get("surface_id") != caller_surface, f"caller identity leaked into target capture: {params}", failures)

            before = len(state.requests)
            mismatch = env.copy()
            mismatch["CMUX_SURFACE_ID"] = str(uuid.uuid4())
            proc = run(cli, socket_path, ["conversation", "capture-runtime"], mismatch, tmp)
            expect(proc.returncode != 0 and "surface_env_mismatch" in proc.stderr, f"alias mismatch was accepted: {proc.stderr}", failures)
            expect(len(state.requests) == before, "alias mismatch reached the socket", failures)

            for key, value, expected in (
                ("CODEX_THREAD_ID", "", "missing_runtime_id"),
                ("CODEX_THREAD_ID", "not-a-uuid", "invalid_runtime_id"),
                ("C11_SURFACE_ID", "not-a-uuid", "surface_env_mismatch"),
            ):
                bad = env.copy()
                bad[key] = value
                proc = run(cli, socket_path, ["conversation", "capture-runtime"], bad, tmp)
                expect(proc.returncode != 0 and expected in proc.stderr, f"bad {key} was accepted: {proc.stderr}", failures)

            missing_id = env.copy()
            missing_id.pop("CODEX_THREAD_ID")
            proc = run(cli, socket_path, ["conversation", "capture-runtime"], missing_id, tmp)
            expect(proc.returncode != 0 and "missing_runtime_id" in proc.stderr, f"absent runtime id was accepted: {proc.stderr}", failures)

            missing_surface = env.copy()
            missing_surface.pop("C11_SURFACE_ID")
            missing_surface.pop("CMUX_SURFACE_ID")
            proc = run(cli, socket_path, ["conversation", "capture-runtime"], missing_surface, tmp)
            expect(proc.returncode != 0 and "missing_surface" in proc.stderr, f"absent surface aliases were accepted: {proc.stderr}", failures)

            invalid_surface = env.copy()
            invalid_surface["C11_SURFACE_ID"] = "not-a-uuid"
            invalid_surface["CMUX_SURFACE_ID"] = "not-a-uuid"
            proc = run(cli, socket_path, ["conversation", "capture-runtime"], invalid_surface, tmp)
            expect(proc.returncode != 0 and "invalid_surface" in proc.stderr, f"invalid agreeing surface aliases were accepted: {proc.stderr}", failures)

            for override in (
                ["--id", caller_thread_id],
                ["--surface", caller_surface],
                ["--cwd", "/caller/cwd"],
                ["--kind", "claude-code"],
            ):
                proc = run(cli, socket_path, ["conversation", "capture-runtime", *override], env, tmp)
                expect(proc.returncode != 0 and "accepts no arguments" in proc.stderr, f"runtime override was accepted ({override}): {proc.stderr}", failures)

            claim_start_ms = int(time.time() * 1000)
            proc = run(
                cli,
                socket_path,
                ["conversation", "claim", "--kind", "codex", "--cwd", str(tmp), "--ttl-ms", "700"],
                env,
                tmp,
            )
            expect(proc.returncode == 0, f"ttl claim failed: {proc.stderr}", failures)
            claim = state.requests[-1].get("params", {})
            expiry = claim.get("expires_at_epoch_ms")
            expect(isinstance(expiry, int) and claim_start_ms < expiry <= int(time.time() * 1000) + 700, f"claim did not carry an absolute bounded expiry: {claim}", failures)

            expected_resume_id = str(uuid.uuid4())
            proc = run(
                cli,
                socket_path,
                ["conversation", "claim", "--kind", "codex", "--expected-resume-id", expected_resume_id],
                env,
                tmp,
            )
            expected_claim = state.requests[-1].get("params", {})
            expect(proc.returncode == 0 and expected_claim.get("expected_resume_id") == expected_resume_id, f"expected resume intent missing: {expected_claim}", failures)

            invalid_expected = run(
                cli,
                socket_path,
                ["conversation", "claim", "--kind", "codex", "--expected-resume-id", "not-a-uuid"],
                env,
                tmp,
            )
            expect(invalid_expected.returncode != 0 and "must be a UUID" in invalid_expected.stderr, f"invalid expected resume id accepted: {invalid_expected.stderr}", failures)

            bad_ttl = run(cli, socket_path, ["conversation", "claim", "--kind", "codex", "--ttl-ms", "0"], env, tmp)
            expect(bad_ttl.returncode != 0 and "positive integer" in bad_ttl.stderr, f"zero ttl accepted: {bad_ttl.stderr}", failures)
        finally:
            server.shutdown()
            server.server_close()

        missing_socket = str(tmp / "missing.sock")
        start = time.monotonic()
        proc = run(cli, missing_socket, ["conversation", "capture-runtime"], runtime_env(str(uuid.uuid4()), str(uuid.uuid4())), tmp)
        elapsed = time.monotonic() - start
        expect(proc.returncode != 0 and elapsed < 2.0, f"unreachable socket was not bounded: {elapsed:.2f}s", failures)

    if failures:
        print("FAIL: Codex runtime capture CLI")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: Codex runtime capture uses target env/cwd only and claim expiry is absolute")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
