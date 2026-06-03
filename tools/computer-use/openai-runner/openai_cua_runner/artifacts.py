from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any


def _timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


@dataclass
class RunArtifacts:
    root: Path

    @classmethod
    def create(cls, scenario: str, base_dir: Path | None = None) -> "RunArtifacts":
        base = base_dir or Path("artifacts/openai-cua-runs")
        root = base / f"{_timestamp()}-{scenario}"
        for child in ["screenshots", "c11", "logs"]:
            (root / child).mkdir(parents=True, exist_ok=True)
        return cls(root=root)

    def write_json(self, relative: str, value: Any) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return path

    def append_jsonl(self, relative: str, value: Any) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(value, sort_keys=True) + "\n")
        return path

    def write_text(self, relative: str, value: str) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8")
        return path

    def screenshot_path(self, index: int, label: str) -> Path:
        safe = "".join(ch if ch.isalnum() or ch in "-_" else "-" for ch in label).strip("-") or "shot"
        return self.root / "screenshots" / f"{index:03d}-{safe}.png"
