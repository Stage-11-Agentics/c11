from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import subprocess
from typing import Any


def sanitize_bundle(raw: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", ".", raw.lower()).strip(".")
    cleaned = re.sub(r"\.+", ".", cleaned)
    return cleaned or "agent"


def sanitize_path(raw: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")
    cleaned = re.sub(r"-+", "-", cleaned)
    return cleaned or "agent"


@dataclass(frozen=True)
class TaggedC11:
    tag: str
    repo_root: Path

    @property
    def tag_id(self) -> str:
        return sanitize_bundle(self.tag)

    @property
    def slug(self) -> str:
        return sanitize_path(self.tag)

    @property
    def bundle_id(self) -> str:
        return f"com.stage11.c11.debug.{self.tag_id}"

    @property
    def app_path(self) -> Path:
        return Path.home() / "Library/Developer/Xcode/DerivedData" / f"c11-{self.slug}" / "Build/Products/Debug" / f"c11 DEV {self.tag}.app"

    @property
    def socket_path(self) -> Path:
        return Path(f"/tmp/c11-debug-{self.slug}.sock")

    @property
    def log_path(self) -> Path:
        return Path(f"/tmp/c11-debug-{self.slug}.log")

    def build(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["./scripts/reload.sh", "--tag", self.tag],
            cwd=self.repo_root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def launch(self, wait_socket: int = 10) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["./scripts/launch-tagged-automation.sh", self.tag, "--wait-socket", str(wait_socket)],
            cwd=self.repo_root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )


class C11Oracle:
    def __init__(self, tagged: TaggedC11) -> None:
        self.tagged = tagged

    def command(self, *args: str, expect_json: bool = True) -> Any:
        env = os.environ.copy()
        for key in [
            "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID", "CMUX_PANE_ID",
            "C11_WORKSPACE_ID", "C11_SURFACE_ID", "C11_TAB_ID", "C11_PANE_ID",
        ]:
            env.pop(key, None)
        env["CMUX_SOCKET_PATH"] = str(self.tagged.socket_path)
        env["CMUX_SOCKET"] = str(self.tagged.socket_path)
        proc = subprocess.run(
            ["c11", "--socket", str(self.tagged.socket_path), *args],
            cwd=self.tagged.repo_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode != 0:
            return {"ok": False, "command": ["c11", *args], "stdout": proc.stdout, "stderr": proc.stderr, "returncode": proc.returncode}
        if not expect_json:
            return {"ok": True, "stdout": proc.stdout}
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError:
            return {"ok": True, "stdout": proc.stdout}

    def tree(self) -> Any:
        return self.command("tree", "--json")

    def identify(self) -> Any:
        return self.command("identify")

    def read_screen(self, lines: int = 80) -> Any:
        return self.command("read-screen", "--lines", str(lines), expect_json=False)


def count_panes(tree: Any) -> int:
    count = 0
    if isinstance(tree, dict):
        if "panes" in tree and isinstance(tree["panes"], list):
            count += len(tree["panes"])
        for value in tree.values():
            count += count_panes(value)
    elif isinstance(tree, list):
        for item in tree:
            count += count_panes(item)
    return count
