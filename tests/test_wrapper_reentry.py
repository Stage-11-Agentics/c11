"""Runtime regression tests for the bundled Claude and Codex wrappers."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


class WrapperReentryTests(unittest.TestCase):
    def test_two_bundle_wrappers_reach_the_real_binary_once(self) -> None:
        for tool, reentry_var in (
            ("claude", "C11_CLAUDE_WRAPPER_REENTRY"),
            ("codex", "C11_CODEX_WRAPPER_REENTRY"),
        ):
            with self.subTest(tool=tool), tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                wrapper_a = root / "bundle-a" / tool
                wrapper_b = root / "bundle-b" / tool
                real_binary = root / "real" / tool
                call_log = root / "calls.log"
                for wrapper_path in (wrapper_a, wrapper_b):
                    wrapper_path.parent.mkdir(parents=True)
                    shutil.copy2(REPO_ROOT / "Resources" / "bin" / tool, wrapper_path)
                    wrapper_path.chmod(0o755)

                real_binary.parent.mkdir(parents=True)
                real_binary.write_text(
                    "#!/bin/sh\n"
                    f"printf '%s\\n' \"${{{reentry_var}:-unset}}\" \"$@\" >> \"$CALL_LOG\"\n",
                    encoding="utf-8",
                )
                real_binary.chmod(0o755)

                env = os.environ.copy()
                env.pop("C11_SHELL_INTEGRATION", None)
                env.pop("CMUX_SURFACE_ID", None)
                env.pop("CMUX_SOCKET_PATH", None)
                env.pop(reentry_var, None)
                env["PATH"] = os.pathsep.join(
                    (str(wrapper_a.parent), str(wrapper_b.parent), str(real_binary.parent), "/usr/bin", "/bin")
                )
                env["CALL_LOG"] = str(call_log)

                result = subprocess.run(
                    [str(wrapper_a), "argument with spaces", "--sentinel"],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=3,
                    check=False,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    call_log.read_text(encoding="utf-8").splitlines(),
                    ["1", "argument with spaces", "--sentinel"],
                )

    def test_descendant_invocation_bypasses_wrappers_once(self) -> None:
        for tool, reentry_var in (
            ("claude", "C11_CLAUDE_WRAPPER_REENTRY"),
            ("codex", "C11_CODEX_WRAPPER_REENTRY"),
        ):
            with self.subTest(tool=tool), tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                wrapper_a = root / "bundle-a" / tool
                wrapper_b = root / "bundle-b" / tool
                real_binary = root / "real" / tool
                call_log = root / "calls.log"
                for wrapper_path in (wrapper_a, wrapper_b):
                    wrapper_path.parent.mkdir(parents=True)
                    shutil.copy2(REPO_ROOT / "Resources" / "bin" / tool, wrapper_path)
                    wrapper_path.chmod(0o755)

                real_binary.parent.mkdir(parents=True)
                real_binary.write_text(
                    "#!/bin/sh\n"
                    f"printf '%s\\n' \"${{{reentry_var}:-unset}}|${{CLAUDECODE-__UNSET__}}|${{CALL_LEVEL:-parent}}|$1\" >> \"$CALL_LOG\"\n"
                    f"if [ -z \"${{CALL_LEVEL:-}}\" ]; then CALL_LEVEL=child {tool} child; fi\n",
                    encoding="utf-8",
                )
                real_binary.chmod(0o755)

                env = os.environ.copy()
                env.pop("CMUX_SURFACE_ID", None)
                env.pop("CMUX_SOCKET_PATH", None)
                env.pop(reentry_var, None)
                env["CLAUDECODE"] = "nested-session-sentinel"
                env["PATH"] = os.pathsep.join(
                    (str(wrapper_a.parent), str(wrapper_b.parent), str(real_binary.parent), "/usr/bin", "/bin")
                )
                env["CALL_LOG"] = str(call_log)

                result = subprocess.run(
                    [str(wrapper_a), "parent"],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=3,
                    check=False,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    call_log.read_text(encoding="utf-8").splitlines(),
                    [
                        "1|nested-session-sentinel|parent|parent",
                        "unset|nested-session-sentinel|child|child",
                    ],
                )

    def test_claude_c11_descendant_clears_nested_marker_for_all_socket_states(self) -> None:
        for socket_state in ("missing", "stale", "live"):
            with self.subTest(socket_state=socket_state), tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                wrapper_a = root / "bundle-a" / "claude"
                wrapper_b = root / "bundle-b" / "claude"
                real_binary = root / "real" / "claude"
                socket_path = root / "c11.sock"
                call_log = root / "calls.log"
                for wrapper_path in (wrapper_a, wrapper_b):
                    wrapper_path.parent.mkdir(parents=True)
                    shutil.copy2(REPO_ROOT / "Resources" / "bin" / "claude", wrapper_path)
                    wrapper_path.chmod(0o755)

                real_binary.parent.mkdir(parents=True)
                real_binary.write_text(
                    "#!/bin/sh\n"
                    "printf '%s|%s|%s|%s\\n' "
                    '"${C11_CLAUDE_WRAPPER_REENTRY:-unset}" "${CLAUDECODE-__UNSET__}" '
                    '"${CALL_LEVEL:-parent}" "$1" >> "$CALL_LOG"\n'
                    "if [ -z \"${CALL_LEVEL:-}\" ]; then "
                    "CMUX_SURFACE_ID=surface:test CMUX_SOCKET_PATH=\"$CHILD_SOCKET\" "
                    "CALL_LEVEL=child claude child; fi\n",
                    encoding="utf-8",
                )
                real_binary.chmod(0o755)

                held_socket: socket.socket | None = None
                if socket_state in {"stale", "live"}:
                    held_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    held_socket.bind(str(socket_path))
                    if socket_state == "live":
                        held_socket.listen(1)
                    else:
                        held_socket.close()
                        held_socket = None

                env = os.environ.copy()
                env.pop("C11_SHELL_INTEGRATION", None)
                env.pop("CMUX_SURFACE_ID", None)
                env.pop("CMUX_SOCKET_PATH", None)
                env.pop("C11_CLAUDE_WRAPPER_REENTRY", None)
                env["CLAUDECODE"] = "nested-session-sentinel"
                env["CHILD_SOCKET"] = str(socket_path)
                env["CALL_LOG"] = str(call_log)
                env["PATH"] = os.pathsep.join(
                    (str(wrapper_a.parent), str(wrapper_b.parent), str(real_binary.parent), "/usr/bin", "/bin")
                )

                try:
                    result = subprocess.run(
                        [str(wrapper_a), "parent"],
                        env=env,
                        capture_output=True,
                        text=True,
                        timeout=3,
                        check=False,
                    )
                finally:
                    if held_socket is not None:
                        held_socket.close()

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    call_log.read_text(encoding="utf-8").splitlines(),
                    [
                        "1|nested-session-sentinel|parent|parent",
                        "unset|__UNSET__|child|child",
                    ],
                )


if __name__ == "__main__":
    unittest.main()
