#!/usr/bin/env python3
"""`c11 hc ...` (what Resources/bin/hc execs inside a c11 terminal) sends one
`hc.call` request to the socket and prints its result.

The verb was not routed in the CLI at all, and the socket had no `hc.call`, so
`hc ls|get|server|run` failed before reaching the core. The server here is a
disposable socket in a temp directory; no c11 app and no hc core run.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

from fake_server_env import fake_server_env

SESSION = "c11-fixture"
HC_SOCKET = "/tmp/c11-fixture-not-used.sock"
RESULT = {"terminals": [{"address": "t1b"}]}


def main():
    cli = os.environ.get("C11_CLI") or os.environ.get("C11_CLI_BIN")
    if not cli:
        raise RuntimeError("Set C11_CLI to the candidate bundled CLI")
    with tempfile.TemporaryDirectory(prefix="c11-hc-call-") as directory:
        path = str(Path(directory) / "fixture.sock")
        calls = []
        errors = []
        failure = None
        stopped = threading.Event()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(8)
        server.settimeout(0.1)

        def serve():
            while not stopped.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                try:
                    with conn, conn.makefile("rwb") as stream:
                        for line in stream:
                            if not line.startswith(b"{"):
                                stream.write(b"OK\n")
                                stream.flush()
                                continue
                            request = json.loads(line)
                            method = request["method"]
                            if method == "system.capabilities":
                                result = {"methods": ["hc.call", "system.ping"], "features": []}
                            elif method == "hc.call":
                                calls.append(request["params"])
                                result = RESULT
                            else:
                                result = {"pong": True}
                            response = {"id": request["id"], "ok": True, "result": result}
                            if method == "hc.call" and failure is not None:
                                response = {"id": request["id"], "ok": False, "error": failure}
                            stream.write((json.dumps(response) + "\n").encode())
                            stream.flush()
                except Exception as error:
                    errors.append(type(error).__name__)

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()

        def run(args, hc_env=True):
            env = fake_server_env(path)
            env.update(CMUX_CLI_SENTRY_DISABLED="1", CMUX_CLAUDE_HOOK_SENTRY_DISABLED="1", C11_QUIET_DISCOVERY="1")
            for key in ("HC_SESSION", "HC_SOCKET"):
                env.pop(key, None)
            if hc_env:
                env.update(HC_SESSION=SESSION, HC_SOCKET=HC_SOCKET)
            return subprocess.run([cli, "--socket", path, "hc", *args], env=env, capture_output=True, text=True, timeout=10,
                                  cwd=directory)

        def one_call(args):
            before = len(calls)
            result = run(args)
            assert result.returncode == 0, (args, result.stderr)
            assert len(calls) == before + 1, (args, "expected exactly one hc.call", calls[before:])
            return calls[-1], json.loads(result.stdout)

        try:
            params, out = one_call(["ls"])
            assert out == RESULT, out
            assert (params["verb"], params["session"], params["socket"]) == ("list", SESSION, HC_SOCKET), params

            # C11H-42: read-only machine inventory goes through the same route;
            # changing a machine is refused here and sends nothing.
            for spelling in ("ls", "list"):
                params, out = one_call(["machine", spelling])
                assert (params["verb"], params["session"], params["socket"]) == ("machine_list", SESSION, HC_SOCKET), params
                assert out == RESULT, out
            for args in (["machine", "add", "studio", "ssh://studio"], ["machine", "remove", "studio"], ["machine", "link"]):
                before = len(calls)
                result = run(args)
                assert result.returncode != 0 and "hc_command_unsupported" in result.stderr, (args, result.returncode, result.stderr)
                assert len(calls) == before, (args, "a machine change sent hc.call")

            params, _ = one_call(["get", "t1b"])
            assert (params["verb"], params["terminal"]) == ("get", "t1b"), params

            params, _ = one_call(["server", "status"])
            assert params["verb"] == "status", params
            params, _ = one_call(["server", "restart"])
            assert params["verb"] == "restart", params

            # hc's own grammar passes through untouched, including words the c11
            # CLI would otherwise take for its own flags.
            params, _ = one_call(["run", "--cwd", "/tmp", "--env", "A=B", "--label", "k=v", "--", "sh", "-c", "echo --help --json"])
            assert params["verb"] == "run", params
            assert params["argv"] == ["sh", "-c", "echo --help --json"], params
            assert params["cwd"] == "/tmp", params
            assert params["environment"].get("A") == "B", params
            assert params["labels"] == {"k": "v"}, params

            # A child's own help flags are its argv, not a request for c11's help:
            # standalone tokens, with and without `--`, must reach hc.call exactly.
            for child in (["/bin/echo", "--help"], ["/bin/echo", "-h"], ["/bin/echo", "--help", "-h", "--json"]):
                params, _ = one_call(["run", "--", *child])
                assert params["argv"] == child, (child, params)
            params, _ = one_call(["run", "/bin/echo", "--help"])
            assert params["argv"] == ["/bin/echo", "--help"], params

            # `c11 hc --help` is hc's own help from HCCoreCommand, not an unknown command.
            before = len(calls)
            result = run(["--help"])
            assert result.returncode == 0 and "Usage: c11 hc" in result.stdout, (result.returncode, result.stdout, result.stderr)
            assert "Unknown command" not in result.stdout + result.stderr
            assert len(calls) == before, "help sent hc.call"

            # Refused before any request: the managed runtime owns start/stop/update.
            for args, code in ([["server", "start"], "hc_managed_runtime"], [["update"], "hc_managed_runtime"],
                               [["server", "bogus"], "hc_command_unsupported"], [["get"], "hc_invalid_arguments"]):
                before = len(calls)
                result = run(args)
                assert result.returncode != 0 and code in result.stderr, (args, result.returncode, result.stderr)
                assert len(calls) == before, (args, "a refused command sent hc.call")

            before = len(calls)
            result = run(["ls"], hc_env=False)
            assert result.returncode != 0 and "hc_session_required" in result.stderr, result.stderr
            assert len(calls) == before

            # Real CLI/socket error path: reason plus machine-readable safety,
            # including a mutating call whose reply was lost. No retry of hc.call.
            for args in (["ls"], ["get", "studio/t1"], ["server", "status"], ["machine", "ls"]):
                failure = {"code": "hc_deadlineExceeded", "message": "The hc command could not complete.",
                           "data": {"retry_safe": True}}
                before = len(calls)
                result = run(args)
                assert result.returncode != 0 and not result.stdout, (args, result)
                assert "hc_deadlineExceeded" in result.stderr and "retry_safe=true" in result.stderr, result.stderr
                assert "same command again" in result.stderr and "does not mean sessions ended" in result.stderr, result.stderr
                assert len(calls) == before + 1, "read was unexpectedly replayed"
            failure = {"code": "hc_outcome_uncertain", "message": "The command may have taken effect.",
                       "data": {"retry_safe": False}}
            before = len(calls)
            result = run(["run", "--", "sh"])
            assert result.returncode != 0 and "retry_safe=false" in result.stderr, result.stderr
            assert "retry_safe=true" not in result.stderr
            assert len(calls) == before + 1, "uncertain run was replayed"
            failure = None

            # Initial connect fails before hc.call; it still names retry safety.
            original_path = path
            path = str(Path(directory) / "missing.sock")
            result = run(["ls"])
            path = original_path
            assert result.returncode != 0 and "retry_safe=true" in result.stderr, result.stderr
            assert not errors, errors
            print("PASS: c11 hc ls|get|server|run send one hc.call with the parsed command; result printed")
            print("PASS: run's argv/cwd/env/labels survive; start/update/unsupported/no-session send nothing")
            print("PASS: read errors retain cause/retry_safe=true; connect failure is actionable; uncertain run is retry_safe=false and never replayed")
        finally:
            stopped.set()
            worker.join(timeout=2)
            server.close()


if __name__ == "__main__":
    main()
