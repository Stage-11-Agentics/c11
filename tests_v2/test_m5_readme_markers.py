#!/usr/bin/env python3
"""M5 README markers — asserts the c11 README carries the brand-identity
header, tagline, fork-acknowledgment marker, and license marker.

README is a rendered artifact for humans, not source-code metadata; the
testing-policy clause that forbids grepping source code to assert string
existence does not apply here.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def _fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    readme = REPO / "README.md"
    if not readme.is_file():
        _fail(f"README.md not found at {readme}")

    text = readme.read_text(encoding="utf-8")

    # 1. First 5 non-empty lines contain the canonical h1 ("# c11" markdown).
    first_lines = [line for line in text.splitlines()[:5]]
    if not any(line.strip() == "# c11" for line in first_lines):
        _fail('README.md first 5 lines must contain the "# c11" markdown header')

    # 2. Tagline appears exactly once.
    tagline = "the Stage 11 terminal multiplexer for AI coding agents"
    occurrences = text.count(tagline)
    if occurrences != 1:
        _fail(f"Expected tagline {tagline!r} exactly once; got {occurrences}")

    # 3. Fork-acknowledgment marker.
    fork_marker = "Stage 11 Agentics fork of [cmux](https://github.com/manaflow-ai/cmux)"
    fork_count = text.count(fork_marker)
    if fork_count != 1:
        _fail(f"Expected fork marker {fork_marker!r} exactly once; got {fork_count}")

    # 4. License marker.
    if "AGPL-3.0-or-later" not in text:
        _fail("README.md must reference AGPL-3.0-or-later")

    print("PASS: README.md M5 markers present (header, tagline, fork, license)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
