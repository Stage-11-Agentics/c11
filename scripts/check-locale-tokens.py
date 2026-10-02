#!/usr/bin/env python3
"""Validate the six-locale interpolation contract for a frozen key list.

The freeze list is one catalog key per line on stdin.  English is the source
of truth: every localized leaf must have the same variation shape and the
same printf-style interpolation-token multiset as its English counterpart.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any


LOCALES = ("ja", "uk", "ko", "zh-Hans", "zh-Hant", "ru")
TOKEN_RE = re.compile(
    r"%%|%(?:\d+\$)?(?:@|lld|llu|ld|lu|ll[diu]|l[diu]|[diuoxXfFeEgGaAcsp])"
)
NOTE_RE = re.compile(
    r"(?:\b(?:TODO|FIXME|TBD|TRANSLATE|TRANSLATOR(?:\s+NOTE)?|"
    r"TRANSLATION\s+(?:NEEDED|PENDING))\b|\[\s*(?:TODO|FIXME|TBD)\s*\])",
    re.IGNORECASE,
)


def leaves(node: Any, path: tuple[str, ...] = ()) -> dict[tuple[str, ...], dict[str, Any]]:
    """Return every stringUnit, including leaves below catalog variations."""

    if not isinstance(node, dict):
        return {}

    found: dict[tuple[str, ...], dict[str, Any]] = {}
    if "stringUnit" in node:
        unit = node["stringUnit"]
        if isinstance(unit, dict):
            found[path + ("stringUnit",)] = unit

    variations = node.get("variations")
    if isinstance(variations, dict):
        for dimension, choices in variations.items():
            if not isinstance(choices, dict):
                continue
            for choice, child in choices.items():
                found.update(
                    leaves(child, path + ("variations", str(dimension), str(choice)))
                )
    return found


def tokens(value: str) -> Counter[str]:
    return Counter(TOKEN_RE.findall(value))


def read_freeze_keys() -> list[str]:
    keys: list[str] = []
    seen: set[str] = set()
    for line in sys.stdin:
        key = line.split("#", 1)[0].strip()
        if key and key not in seen:
            keys.append(key)
            seen.add(key)
    return keys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--catalog",
        type=Path,
        default=Path("Resources/Localizable.xcstrings"),
        help="path to the xcstrings JSON catalog",
    )
    args = parser.parse_args()

    try:
        catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"catalog: {exc}", file=sys.stderr)
        return 2

    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        print("catalog: missing strings object", file=sys.stderr)
        return 2

    errors: list[str] = []
    freeze_keys = read_freeze_keys()
    if not freeze_keys:
        print("freeze list is empty", file=sys.stderr)
        return 2

    for key in freeze_keys:
        entry = strings.get(key)
        if not isinstance(entry, dict):
            errors.append(f"{key}: missing catalog key")
            continue
        localizations = entry.get("localizations")
        if not isinstance(localizations, dict):
            errors.append(f"{key}: missing localizations")
            continue

        english = leaves(localizations.get("en"))
        if not english:
            errors.append(f"{key}: English has no stringUnit leaves")
            continue

        for path, english_unit in english.items():
            english_value = english_unit.get("value")
            if not isinstance(english_value, str):
                errors.append(f"{key} {path}: English value is not a string")
                continue
            expected_tokens = tokens(english_value)

            for locale in LOCALES:
                localized = leaves(localizations.get(locale))
                unit = localized.get(path)
                if unit is None:
                    errors.append(f"{key} {locale} {path}: missing leaf")
                    continue
                value = unit.get("value")
                if not isinstance(value, str) or not value.strip():
                    errors.append(f"{key} {locale} {path}: empty value")
                    continue
                if unit.get("state") != "translated":
                    errors.append(
                        f"{key} {locale} {path}: state is {unit.get('state')!r}, expected 'translated'"
                    )
                if NOTE_RE.search(value):
                    errors.append(f"{key} {locale} {path}: translator note marker in value")
                actual_tokens = tokens(value)
                if actual_tokens != expected_tokens:
                    errors.append(
                        f"{key} {locale} {path}: tokens {dict(actual_tokens)!r} != "
                        f"English {dict(expected_tokens)!r}"
                    )

        for locale in LOCALES:
            extra_paths = set(leaves(localizations.get(locale))) - set(english)
            if extra_paths:
                errors.append(f"{key} {locale}: extra variation leaves {sorted(extra_paths)!r}")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1

    print(f"OK: {len(freeze_keys)} keys x {len(LOCALES)} locales")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
