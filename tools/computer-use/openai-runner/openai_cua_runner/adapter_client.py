from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
from typing import Any


class AdapterError(RuntimeError):
    pass


class AdapterClient:
    def __init__(
        self,
        *,
        bundle_id: str,
        app_path: Path | None = None,
        executable: Path | None = None,
        repo_root: Path | None = None,
    ) -> None:
        self.bundle_id = bundle_id
        self.app_path = app_path
        self.repo_root = repo_root or Path.cwd()
        self.package_dir = self.repo_root / "tools/computer-use/mac-adapter"
        env_executable = os.environ.get("CUA_MAC_ADAPTER")
        self.executable = executable or (Path(env_executable) if env_executable else self.package_dir / ".build/debug/cua-mac-adapter")

    def available(self) -> bool:
        return self.executable.exists() and os.access(self.executable, os.X_OK)

    def build(self) -> None:
        proc = subprocess.run(
            ["swift", "build", "--package-path", str(self.package_dir)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode != 0:
            raise AdapterError(proc.stderr.strip() or proc.stdout.strip() or "swift build failed")

    def doctor(self) -> dict[str, Any]:
        return self._run("doctor")

    def window_list(self) -> dict[str, Any]:
        return self._run("window-list")

    def launch(self, wait: int = 10) -> dict[str, Any]:
        return self._run("launch", "--wait", str(wait))

    def observe(self, *, out: Path | None = None, include_base64: bool = False, frontmost_required: bool = True) -> dict[str, Any]:
        args: list[str] = []
        if out is not None:
            args += ["--out", str(out)]
        if include_base64:
            args.append("--include-base64")
        if not frontmost_required:
            args.append("--no-frontmost-required")
        return self._run("observe", *args)

    def act(self, action: dict[str, Any]) -> dict[str, Any]:
        return self._run("act", "--json", json.dumps(action))

    def _run(self, command: str, *args: str) -> dict[str, Any]:
        if not self.available():
            raise AdapterError(f"adapter executable is missing; run: swift build --package-path {self.package_dir}")
        full = [str(self.executable), command, "--bundle-id", self.bundle_id]
        if self.app_path is not None:
            full += ["--app-path", str(self.app_path)]
        full += list(args)
        proc = subprocess.run(full, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if proc.returncode != 0:
            try:
                payload = json.loads(proc.stdout)
            except json.JSONDecodeError:
                payload = {"ok": False, "error": proc.stderr.strip() or proc.stdout.strip()}
            raise AdapterError(payload.get("error") or json.dumps(payload))
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            raise AdapterError(f"adapter returned non-JSON output: {proc.stdout[:500]}") from exc
