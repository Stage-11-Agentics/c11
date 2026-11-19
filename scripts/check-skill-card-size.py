#!/usr/bin/env python3
"""The c11 card stays a card: skills/c11/SKILL.md is read by every agent at launch.

Fails when the card exceeds its word ceiling (counted like `wc -w`). Depth belongs in a
reference page under skills/c11/references/, printed by `c11 guide <page>`, with one line
in the card's map saying when to load it.

Usage: check-skill-card-size.py [repo root]
"""
import sys
from pathlib import Path

CEILING = 2500

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
card = root / "skills" / "c11" / "SKILL.md"
if not card.is_file():
    print(f"check-skill-card-size: no c11 card at {card}", file=sys.stderr)
    sys.exit(2)
words = len(card.read_text(encoding="utf-8").split())
if words > CEILING:
    print(f"{card.relative_to(root)} is {words} words; the ceiling is {CEILING}. "
          "Move depth into a skills/c11/references/ page (printed by `c11 guide <page>`) "
          "and leave one map line in the card.", file=sys.stderr)
    sys.exit(1)
print(f"ok: c11 card is {words} words (ceiling {CEILING})")
