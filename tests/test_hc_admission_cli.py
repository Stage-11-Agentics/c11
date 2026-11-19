#!/usr/bin/env python3
"""C11H-8: built CLI against a private fake socket, never the operator's app.

C11_CLI_BIN must name the newly built binary. No hc or GUI process is launched.
"""
import json
import os
from pathlib import Path
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import uuid

from fake_server_env import fake_server_env


CAPS = {"methods": ["panel.list", "fixture.mutate", "agent.event.append", "conversation.capture_runtime"],
        "features": [{"id": "vocabulary.workspace_area_panel", "version": 1}]}


def main():
    cli = os.environ["C11_CLI_BIN"]
    base = Path(os.environ.get("C11_TEST_ROOT", str(Path.home() / "c11h-run/evidence/C11H-8")))
    base.mkdir(parents=True, exist_ok=True)
    # Journal storage deliberately rejects symlink ancestors. Run folders may
    # be symlinks after the build host's .noindex move, so use their physical location.
    base = base.resolve()
    with tempfile.TemporaryDirectory(prefix="cli-", dir=base) as temporary:
        root = Path(temporary)
        address = str(root / "s")
        state = {"mode": "birth", "calls": [], "executed": [], "first": None}

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                try:
                    for line in self.rfile:
                        if line.startswith(b"auth "):
                            self.wfile.write(b"OK\n"); self.wfile.flush(); continue
                        if not line.startswith(b"{"):
                            state["calls"].append({"method": "legacy.fixture"})
                            self.wfile.write(b"ERROR: hc_inventory_pending: retry\n"); self.wfile.flush(); continue
                        request = json.loads(line)
                        method = request["method"]
                        now = time.monotonic()
                        if state["first"] is None:
                            state["first"] = now
                        state["calls"].append(request)
                        elapsed = now - state["first"]
                        mode = state["mode"]
                        pending = mode in ("pending", "spool") or (mode == "birth" and elapsed < 0.12)
                        pending = pending or (mode == "two-stage" and (method != "system.capabilities" or elapsed < 0.45))
                        if pending:
                            response = {"ok": False, "error": {"code": "hc_inventory_pending", "message": "retry",
                                        "data": {"retryable": True, "pre_dispatch": True, "retry_after_ms": 25}}}
                        elif method == "system.capabilities":
                            response = {"ok": True, "result": CAPS}
                        elif mode == "wrong-id":
                            response = {"ok": False, "error": {"code": "hc_inventory_pending", "message": "unmatched",
                                        "data": {"retryable": True, "pre_dispatch": True}}}
                        elif mode in ("refused", "unsafe"):
                            code = "hc_caller_not_owned" if mode == "refused" else "hc_inventory_pending"
                            response = {"ok": False, "error": {"code": code, "message": "no retry"}}
                        elif mode == "lost":
                            # An ambiguous write must never be repeated.
                            state["executed"].append(request)
                            return
                        else:
                            state["executed"].append(request)
                            response = {"ok": True, "result": {"accepted": True}}
                        response["id"] = "unmatched" if mode == "wrong-id" and method != "system.capabilities" else request["id"]
                        self.wfile.write((json.dumps(response) + "\n").encode()); self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass

        server = socketserver.ThreadingUnixStreamServer(address, Handler)
        server.daemon_threads = True
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        env = fake_server_env(address)
        env.update(CFFIXED_USER_HOME=str(root), CMUX_BUNDLE_ID="com.stage11.c11.debug.admission-test",
                   CMUX_CLI_SENTRY_DISABLED="1", CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1", C11_QUIET_DISCOVERY="1")
        panel, thread = str(uuid.uuid4()), str(uuid.uuid4())
        env.update(C11_PANEL_ID=panel, CODEX_THREAD_ID=thread,
                   CMUX_CLAUDE_HOOK_STATE_PATH=str(root / "hook-state.json"))

        # Cold executable verification is outside the hook's transport budget.
        subprocess.run([cli, "--version"], env=env, capture_output=True, check=True, timeout=5)

        def run(mode, args, stdin=None):
            state.update(mode=mode, calls=[], executed=[], first=None)
            started = time.monotonic()
            result = subprocess.run([cli, "--socket", address, "--password", "fixture-only", *args],
                                    input=stdin, capture_output=True, text=True, env=env, cwd=root, timeout=4)
            return result, time.monotonic() - started

        checks = {}
        def check_birth():
            result, elapsed = run("birth", ["conversation", "capture-runtime"])
            assert result.returncode == 0, (result.stdout, result.stderr)
            assert elapsed < 1, elapsed
            assert len(state["executed"]) == 1, state
            request = state["executed"][0]
            assert request["method"] == "conversation.capture_runtime", request
            assert request["params"] == {"panel_id": panel, "id": thread, "cwd": str(root.resolve())}, request
            assert len(state["calls"]) > 2, state
            print(f"PASS birth pending retries, one exact env capture ({elapsed:.3f}s)")
        checks["birth"] = check_birth

        def check_pending():
            result, elapsed = run("pending", ["conversation", "capture-runtime"])
            # A final attempted round trip may consume the remaining deadline;
            # it must remain a timeout (its outcome is unknown), not be relabeled
            # as pre-dispatch pending from the preceding completed attempt.
            assert result.returncode != 0, result.stdout
            assert "hc_inventory_pending" in result.stderr or "c11: timeout:" in result.stderr, result.stderr
            assert elapsed < 1, elapsed
            assert len(state["calls"]) > 1, state
            assert not state["executed"], state
            assert all(c["method"] == "system.capabilities" for c in state["calls"]), state
            print(f"PASS pending probe preserves 0.75s aggregate capture budget ({elapsed:.3f}s)")
        checks["pending"] = check_pending

        def check_aggregate():
            result, elapsed = run("two-stage", ["conversation", "capture-runtime"])
            assert result.returncode != 0, result.stdout
            assert elapsed < 1, elapsed
            assert not state["executed"], state
            assert {c["method"] for c in state["calls"]} == {"system.capabilities", "conversation.capture_runtime"}, state
            print(f"PASS probe plus capture share one 0.75s deadline ({elapsed:.3f}s)")
        checks["aggregate"] = check_aggregate

        def check_once():
            result, _ = run("birth", ["rpc", "fixture.mutate"])
            assert result.returncode == 0, result.stderr
            assert len(state["executed"]) == 1, state
            print("PASS pre-dispatch retry executes mutation once")
        checks["once"] = check_once

        def check_unsafe():
            failures = []
            for mode in ("refused", "unsafe", "lost", "wrong-id"):
                result, _ = run(mode, ["rpc", "fixture.mutate"])
                assert result.returncode != 0, result.stdout
                mutations = [c for c in state["calls"] if c["method"] == "fixture.mutate"]
                if len(mutations) != 1:
                    failures.append((mode, len(mutations)))
            assert not failures, failures
            print("PASS definitive refusal, unmarked pending and ambiguous loss never replay")
        checks["unsafe"] = check_unsafe

        def check_spool():
            draft = {"schema_version": 1, "event_id": str(uuid.uuid4()), "kind": "agent.turn.started",
                     "emitted_at_ms": int(time.time() * 1000), "tab_id": panel,
                     "workspace_id": str(uuid.uuid4()), "session_id": "fixture-session", "agent_kind": "claude-code",
                     "source": "hook", "adapter": "claude_hook", "native_event": "UserPromptSubmit"}
            result, elapsed = run("spool", ["agent-event", "append", "--stdin"], json.dumps(draft))
            assert result.returncode == 0 and json.loads(result.stdout)["spooled"], (result.stdout, result.stderr)
            assert elapsed < 1, elapsed
            files = list(root.glob("Library/Application Support/**/spool/*.ready"))
            assert len(files) == 1, files
            saved = json.loads(files[0].read_text())
            assert saved["event_id"].lower() == draft["event_id"], saved
            assert not state["executed"], state
            print(f"PASS bounded journal spool retains event identity before one-second hook kill ({elapsed:.3f}s)")
        checks["spool"] = check_spool

        def check_permission():
            before_files = set(root.glob("Library/Application Support/**/spool/*.ready"))
            payload = {"session_id": "fixture-permission", "tool_name": "Bash", "tool_use_id": "fixture-tool",
                       "tool_input": {"command": "PRIVATE-FIXTURE-SENTINEL"}}
            result, elapsed = run("pending", ["claude-hook", "permission-request", "--workspace", str(uuid.uuid4()),
                                               "--panel", panel], json.dumps(payload))
            assert result.returncode == 0 and result.stdout.strip() == "{}", (result.stdout, result.stderr)
            assert elapsed < 1, elapsed
            files = list(root.glob("Library/Application Support/**/spool/*.ready"))
            assert len(set(files) - before_files) == 1, files
            saved = [json.loads(path.read_text()) for path in files]
            assert any(event["kind"] == "agent.approval.requested" for event in saved), saved
            assert all("PRIVATE-FIXTURE-SENTINEL" not in path.read_text() for path in files)
            print(f"PASS actual permission hook pending is observe-only and spools structural event ({elapsed:.3f}s)")
        checks["permission"] = check_permission

        try:
            selected = sys.argv[1:] or list(checks)
            failures = []
            for name in selected:
                try:
                    checks[name]()
                except Exception as error:
                    failures.append((name, repr(error)))
                    print(f"FAIL {name}: {error}", flush=True)
            assert not failures, failures
        finally:
            server.shutdown(); server.server_close(); worker.join(timeout=2)


if __name__ == "__main__":
    main()
