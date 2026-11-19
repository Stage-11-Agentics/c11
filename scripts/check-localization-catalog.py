#!/usr/bin/env python3
"""Every String(localized:) key in c11's sources has a full catalog entry.

    scripts/check-localization-catalog.py [--root <repo>] [--catalog <path>] [--list-missing]

AGENTS.md (Localization): English plus ja, uk, ko, zh-Hans, zh-Hant and ru, all in
Resources/Localizable.xcstrings. A key the catalog lacks shows its English default to every
other locale; a locale that drops an interpolation token crashes at format time.

The check reads every Swift file under Sources/ and CLI/ with a small lexer (comments and
string literals understood, so a commented-out call or a call inside a string is not a call;
`String`, `(`, `localized` and `:` may be split by whitespace, newlines or comments), collects
each `String(localized: "<key>", defaultValue: ...)` call, and fails when:

  - a key used in the sources has no catalog entry;
  - an entry lacks English or one of the six locales, or any value (English included) is empty
    or not `translated`;
  - a value holds a `%` conversion the check does not support (a `*` width, a bare `%`);
  - a locale's format tokens differ from English's: each argument position keeps its exact
    spec (`%@`, `%lld`, `%02d`, `%.1f`), though positional `%2$@ ... %1$@` may reorder;
  - English does not use exactly the arguments the call supplies (each `\\(...)` in the
    defaultValue, plus %-tokens written there for a String(format:) around the call), or any
    value references a position past them;
  - a locale changes a protocol prefix English starts with: a code (`relay_unreachable:`,
    `input-state:`, `ERROR:`) or a prefix the sources test with `hasPrefix("...")`;
  - a call's key or defaultValue is not a plain string literal.

Exit 0 clean, 1 with findings, 2 when the catalog or the sources cannot be read.
`--list-missing` prints each key with no entry or a missing locale as one JSON line.
It is stdlib-only and reads about 600 files in well under a second.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

LOCALES = ("ja", "uk", "ko", "zh-Hans", "zh-Hant", "ru")
SOURCE_DIRS = ("Sources", "CLI")
CATALOG = Path("Resources/Localizable.xcstrings")
# One printf conversion: position, flags, width, precision, length, conversion.
SPEC_RE = re.compile(
    r"%(?:(\d+)\$)?([-+ #0']*)(\d+)?(?:\.(\d+))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGaAcCsSp])"
)
# A protocol code at the start of English: snake_case or kebab-case, or an ALL-CAPS word.
CODE_PREFIX_RE = re.compile(r"(?:[A-Za-z][A-Za-z0-9]*[_-][A-Za-z0-9_-]*|[A-Z][A-Z0-9_]+):")
HAS_PREFIX_RE = re.compile(r'hasPrefix\("([A-Za-z][A-Za-z0-9_-]*:|OK |ERROR)"\)')
RAW_OPEN = re.compile(r"#+\"")
LITERAL_SPECIAL = re.compile(r'[\\"\n]')
NEXT = re.compile(r'//|/\*|#+"|"|(?<![A-Za-z0-9_])String(?![A-Za-z0-9_])')
SENTINEL = ""  # stands for one interpolation while a literal is read


def raw_open(src: str, i: int) -> bool:
    """A string literal starts at src[i]: `"`, or a raw string's `#..."`."""

    return src[i] == '"' or (src[i] == "#" and RAW_OPEN.match(src, i) is not None)


@dataclass
class Format:
    """The format arguments one string references: position -> spec, and what it can't parse."""

    args: dict[int, str] = field(default_factory=dict)
    unsupported: list[str] = field(default_factory=list)

    def show(self) -> str:
        return "{" + ", ".join(f"{n}:%{k}" for n, k in sorted(self.args.items())) + "}"


def parse_format(value: str) -> Format:
    """`%@ %lld` and `%2$lld %1$@` both read {1: '@', 2: 'lld'}, so a translation may reorder its
    arguments. A position given two specs reads as 'conflict'."""

    out = Format()
    sequential = 0
    i = value.find("%")
    while i >= 0:
        if value.startswith("%%", i):
            i = value.find("%", i + 2)
            continue
        m = SPEC_RE.match(value, i)
        if m is None:
            out.unsupported.append(value[i : i + 4])
            i = value.find("%", i + 1)
            continue
        pos, flags, width, precision, length, conv = m.groups()
        spec = flags + (width or "") + ("." + precision if precision is not None else "") + (length or "") + conv
        if pos:
            n = int(pos)
        else:
            sequential += 1
            n = sequential
        out.args[n] = spec if out.args.get(n, spec) == spec else "conflict"
        i = value.find("%", m.end())
    return out


@dataclass
class Literal:
    """A Swift string literal: its text, its interpolated expressions, and its text without them."""

    text: str = ""
    interpolations: list[str] = field(default_factory=list)
    plain: str = ""  # the text with each interpolation removed

    @property
    def is_plain(self) -> bool:
        return not self.interpolations

    @property
    def arity(self) -> int:
        """Format arguments the call supplies: each interpolation, plus the %-tokens written
        literally for a String(format:) around the call."""

        return len(self.interpolations) + max(parse_format(self.plain).args, default=0)


@dataclass
class Call:
    path: str
    line: int
    key: Literal | None
    default: Literal | None
    has_default_label: bool


class SwiftLexError(Exception):
    pass


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}


def read_literal(src: str, i: int) -> tuple[Literal, int]:
    """Read the string literal starting at src[i] (at `#` or `"`); return it and the index after."""

    hashes = 0
    while src.startswith("#", i + hashes):
        hashes += 1
    j = i + hashes
    if not src.startswith('"', j):
        raise SwiftLexError("not a string literal")
    multiline = src.startswith('"""', j)
    j += 3 if multiline else 1
    close = ('"""' if multiline else '"') + "#" * hashes
    escape = "\\" + "#" * hashes
    out = Literal()
    buf: list[str] = []
    while True:
        m = LITERAL_SPECIAL.search(src, j)
        if m is None:
            raise SwiftLexError("unterminated string literal")
        buf.append(src[j : m.start()])
        j = m.start()
        if src.startswith(close, j):
            j += len(close)
            break
        if not multiline and src[j] == "\n":
            raise SwiftLexError("newline in a single-line string literal")
        if src.startswith(escape, j):
            k = j + len(escape)
            ch = src[k] if k < len(src) else ""
            if ch == "(":
                expr, k = read_balanced(src, k)
                out.interpolations.append(expr)
                buf.append(SENTINEL)
                j = k
                continue
            if ch == "u" and src.startswith("{", k + 1):
                end = src.index("}", k + 2)
                buf.append(chr(int(src[k + 2 : end], 16)))
                j = end + 1
                continue
            if multiline and ch == "\n":  # line continuation
                j = k + 1
                continue
            if ch in ESCAPES:
                buf.append(ESCAPES[ch])
                j = k + 1
                continue
            buf.append(src[j])
            j += 1
            continue
        buf.append(src[j])
        j += 1
    text = "".join(buf)
    if multiline:
        text = dedent_multiline(text)
    out.plain = text.replace(SENTINEL, "")
    for expr in out.interpolations:
        text = text.replace(SENTINEL, "\\(" + expr + ")", 1)
    out.text = text
    return out, j


def dedent_multiline(text: str) -> str:
    lines = text.split("\n")
    # The opening delimiter's newline and the closing line (its indentation) are not content.
    indent = lines[-1] if lines[-1].strip() == "" else ""
    body = lines[1:-1] if len(lines) >= 2 else lines
    return "\n".join(line[len(indent):] if line.startswith(indent) else line for line in body)


def read_balanced(src: str, i: int) -> tuple[str, int]:
    """src[i] is `(`: return the text inside the matching `)` and the index after it."""

    depth = 0
    j = i
    start = i + 1
    while j < len(src):
        ch = src[j]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return src[start:j], j + 1
        elif raw_open(src, j):
            _, j = read_literal(src, j)
            continue
        elif src.startswith("//", j):
            j = src.find("\n", j)
            if j < 0:
                break
            continue
        elif src.startswith("/*", j):
            j = skip_block_comment(src, j)
            continue
        j += 1
    raise SwiftLexError("unbalanced parentheses")


def skip_block_comment(src: str, i: int) -> int:
    depth = 0
    j = i
    while j < len(src):
        if src.startswith("/*", j):
            depth += 1
            j += 2
        elif src.startswith("*/", j):
            depth -= 1
            j += 2
            if depth == 0:
                return j
        else:
            j += 1
    raise SwiftLexError("unterminated block comment")


def skip_space(src: str, i: int) -> int:
    """Skip whitespace, newlines and comments."""

    while i < len(src):
        if src[i].isspace():
            i += 1
        elif src.startswith("//", i):
            nl = src.find("\n", i)
            i = len(src) if nl < 0 else nl
        elif src.startswith("/*", i):
            i = skip_block_comment(src, i)
        else:
            break
    return i


def call_head(src: str, i: int) -> tuple[int, int] | None:
    """src[i:] starts with the word `String`. If `(` `localized` `:` follow (whitespace and
    comments allowed between them), return the index of `(` and the index after `:`."""

    paren = skip_space(src, i + len("String"))
    if not src.startswith("(", paren):
        return None
    j = skip_space(src, paren + 1)
    if not src.startswith("localized", j):
        return None
    j += len("localized")
    if j < len(src) and (src[j].isalnum() or src[j] == "_"):
        return None
    j = skip_space(src, j)
    if not src.startswith(":", j):
        return None
    return paren, j + 1


def parse_call(src: str, i: int, paren: int, after_label: int, path: str) -> Call:
    """Parse the call whose `String` is at src[i]: its key and its defaultValue."""

    line = src.count("\n", 0, i) + 1
    _, end = read_balanced(src, paren)
    j = skip_space(src, after_label)
    key: Literal | None = None
    if j < len(src) and raw_open(src, j):
        try:
            key, j = read_literal(src, j)
            j = skip_space(src, j)
            if src[j] not in ",)":  # an expression that starts with a literal: not a literal key
                key = None
        except SwiftLexError:
            key = None
    default: Literal | None = None
    has_label = False
    # Walk the remaining top-level arguments for `defaultValue:`.
    k = j
    while k < end - 1:
        k = skip_space(src, k)
        if k >= end - 1:
            break
        if src[k] == ",":
            k += 1
            continue
        m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", src[k:end])
        if m:
            label = m.group(1)
            k = skip_space(src, k + m.end())
            if label == "defaultValue":
                has_label = True
                if raw_open(src, k):
                    try:
                        lit, after = read_literal(src, k)
                        nxt = skip_space(src, after)
                        default = lit if src[nxt] in ",)" else None
                    except SwiftLexError:
                        default = None
        k = skip_argument(src, k, end - 1)
    return Call(path, line, key, default, has_label)


def skip_argument(src: str, i: int, stop: int) -> int:
    """Skip one argument's value to just after the next top-level comma (or to stop)."""

    j = i
    while j < stop:
        ch = src[j]
        if ch == ",":
            return j + 1
        if ch in "([{":
            close = {"(": ")", "[": "]", "{": "}"}[ch]
            depth = 0
            while j < stop:
                c = src[j]
                if raw_open(src, j):
                    _, j = read_literal(src, j)
                    continue
                if src.startswith("//", j) or src.startswith("/*", j):
                    j = skip_space(src, j)
                    continue
                if c == ch:
                    depth += 1
                elif c == close:
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            continue
        if raw_open(src, j):
            _, j = read_literal(src, j)
            continue
        if src.startswith("//", j) or src.startswith("/*", j):
            j = skip_space(src, j)
            continue
        j += 1
    return stop


def scan_file(path: Path, rel: str) -> tuple[list[Call], str]:
    src = path.read_text(encoding="utf-8")
    return scan_text(src, rel, 0), src


def scan_text(src: str, rel: str, first_line: int) -> list[Call]:
    """Every String(localized:) call in src outside comments, including calls nested in another
    call's arguments or in a string interpolation."""

    calls: list[Call] = []
    i = 0
    while (m := NEXT.search(src, i)) is not None:
        i = m.start()
        tok = m.group(0)
        if tok == "//":
            nl = src.find("\n", i)
            i = len(src) if nl < 0 else nl
        elif tok == "/*":
            i = skip_block_comment(src, i)
        elif tok.endswith('"'):
            lit, after = read_literal(src, i)
            nested = [e for e in lit.interpolations if "String" in e and "localized" in e]
            if nested:
                line = first_line + src.count("\n", 0, i)
                for expr in nested:
                    calls.extend(scan_text(expr, rel, line))
            i = after
        else:
            head = call_head(src, i)
            if head is None:
                i += len("String")
                continue
            call = parse_call(src, i, head[0], head[1], rel)
            call.line += first_line
            calls.append(call)
            i = head[1]  # arguments may hold nested calls; keep scanning inside them
    return calls


def leaves(node: Any, path: tuple[str, ...] = ()) -> dict[tuple[str, ...], dict[str, Any]]:
    """Every stringUnit of one localization, including those below plural/device variations."""

    if not isinstance(node, dict):
        return {}
    found: dict[tuple[str, ...], dict[str, Any]] = {}
    unit = node.get("stringUnit")
    if isinstance(unit, dict):
        found[path] = unit
    variations = node.get("variations")
    if isinstance(variations, dict):
        for dimension, choices in variations.items():
            if isinstance(choices, dict):
                for choice, child in choices.items():
                    found.update(leaves(child, path + (str(dimension), str(choice))))
    return found


def where(path: tuple[str, ...]) -> str:
    return "" if not path else " [" + "/".join(path) + "]"


def protocol_prefix(english: str, tested: list[str]) -> str | None:
    for prefix in tested:
        if english.startswith(prefix):
            return prefix
    m = CODE_PREFIX_RE.match(english)
    return m.group(0) if m else None


def check_unit(key: str, locale: str, path: tuple[str, ...], unit: dict[str, Any],
               problems: list[str]) -> Format | None:
    """The checks every value gets, English included. Returns its format, or None if empty."""

    at = f"{key} {locale}{where(path)}"
    value = unit.get("value")
    if not isinstance(value, str) or not value.strip():
        problems.append(f"{at}: empty value")
        return None
    if unit.get("state") != "translated":
        problems.append(f"{at}: state {unit.get('state')!r}, not 'translated'")
    fmt = parse_format(value)
    for bad in fmt.unsupported:
        problems.append(f"{at}: unsupported format conversion {bad!r} (write %% for a literal %)")
    return fmt


def arity_problem(key: str, path: tuple[str, ...], fmt: Format, arity: int) -> str | None:
    """English uses exactly the call's arguments; a plural or device variation may leave some
    out, but none references one past them."""

    used = set(fmt.args)
    if path:
        beyond = sorted(n for n in used if n > arity)
        if not beyond:
            return None
        return f"{key} en{where(path)}: references argument {beyond} but the call site supplies {arity}"
    if used == set(range(1, arity + 1)):
        return None
    if arity == 0:
        want = "no format arguments"
    elif arity == 1:
        want = "argument 1 and no other"
    else:
        want = f"each of arguments 1 to {arity} (a repeated value still takes its own position)"
    return f"{key} en: format arguments {fmt.show()} but the call site supplies {arity}; English must use {want}"


def check_entry(key: str, entry: Any, arity: int | None, tested: list[str]) -> list[str]:
    if not isinstance(entry, dict) or not isinstance(entry.get("localizations"), dict):
        return [f"{key}: entry has no localizations"]
    locs = entry["localizations"]
    english = leaves(locs.get("en"))
    if not english:
        return [f"{key}: no English (en) value"]
    problems: list[str] = []
    for path, unit in english.items():
        expected = check_unit(key, "en", path, unit, problems)
        if expected is None:
            continue
        if arity is not None and (problem := arity_problem(key, path, expected, arity)):
            problems.append(problem)
        prefix = protocol_prefix(unit["value"], tested) if not path else None
        for locale in LOCALES:
            loc_leaves = leaves(locs.get(locale))
            if not loc_leaves:
                continue  # reported once below
            lu = loc_leaves.get(path)
            if lu is None:
                problems.append(f"{key} {locale}{where(path)}: missing (English has it)")
                continue
            got = check_unit(key, locale, path, lu, problems)
            if got is None:
                continue
            if got.args != expected.args:
                problems.append(f"{key} {locale}{where(path)}: tokens {got.show()} != English {expected.show()}")
            if prefix is not None and not lu["value"].startswith(prefix):
                problems.append(
                    f"{key} {locale}: must start with English's protocol prefix {prefix!r} byte for byte; "
                    f"it starts {lu['value'][:len(prefix) + 2]!r}"
                )
    for locale in LOCALES:
        if not leaves(locs.get(locale)):
            problems.append(f"{key}: no {locale} translation")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    ap.add_argument("--catalog", type=Path, help=f"default: <root>/{CATALOG}")
    ap.add_argument("--list-missing", action="store_true",
                    help="print each key with no entry or a missing locale as a JSON line")
    args = ap.parse_args()
    root: Path = args.root
    catalog_path = args.catalog or root / CATALOG

    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        if not isinstance(catalog, dict):
            raise ValueError("the catalog is not a JSON object")
        strings = catalog.get("strings")
        if not isinstance(strings, dict):
            raise ValueError("strings is missing or not an object")
    except (OSError, ValueError) as exc:
        print(f"check-localization-catalog: cannot read {catalog_path}: {exc}", file=sys.stderr)
        return 2

    calls: list[Call] = []
    tested: set[str] = set()
    for d in SOURCE_DIRS:
        base = root / d
        if not base.is_dir():
            print(f"check-localization-catalog: {base} is missing", file=sys.stderr)
            return 2
        for path in sorted(base.rglob("*.swift")):
            rel = str(path.relative_to(root))
            try:
                found, src = scan_file(path, rel)
            except (SwiftLexError, ValueError, IndexError, UnicodeDecodeError) as exc:
                print(f"check-localization-catalog: cannot lex {rel}: {exc}", file=sys.stderr)
                return 2
            calls.extend(found)
            tested.update(HAS_PREFIX_RE.findall(src))
    tested_prefixes = sorted(tested, key=len, reverse=True)

    problems: list[str] = []
    by_key: dict[str, list[Call]] = {}
    for call in calls:
        at = f"{call.path}:{call.line}"
        if call.key is None or not call.key.is_plain:
            problems.append(f"{at}: key is not a plain string literal; the catalog cannot be checked for it")
            continue
        if call.default is None:
            problems.append(
                f"{at}: {call.key.text}: "
                + ("defaultValue is not a string literal" if call.has_default_label else "no defaultValue")
            )
        by_key.setdefault(call.key.text, []).append(call)

    if args.list_missing:
        for k in sorted(by_key):
            entry = strings.get(k)
            locs = entry.get("localizations") if isinstance(entry, dict) else None
            if isinstance(locs, dict):
                lacking = [loc for loc in ("en",) + LOCALES if not leaves(locs.get(loc))]
                if not lacking:
                    continue
            else:
                lacking = ["entry"]
            c = next((c for c in by_key[k] if c.default is not None), by_key[k][0])
            english = leaves(locs.get("en")).get(()) if isinstance(locs, dict) else None
            print(json.dumps({
                "key": k,
                "lacking": lacking,
                "catalogEnglish": english.get("value") if english else None,
                "defaultValue": c.default.text if c.default else None,
                "interpolations": c.default.interpolations if c.default else None,
                "at": [f"{x.path}:{x.line}" for x in by_key[k]],
            }, ensure_ascii=False))
        return 0

    for k in sorted(by_key):
        if k not in strings:
            problems.append(f"{k}: no catalog entry (used at {by_key[k][0].path}:{by_key[k][0].line})")
            continue
        arities = {c.default.arity for c in by_key[k] if c.default is not None}
        if len(arities) > 1:
            sites = ", ".join(f"{c.path}:{c.line}" for c in by_key[k])
            problems.append(f"{k}: call sites supply different argument counts {sorted(arities)} ({sites})")
        arity = arities.pop() if len(arities) == 1 else None
        problems.extend(check_entry(k, strings[k], arity, tested_prefixes))

    if problems:
        for p in problems:
            print(f"check-localization-catalog: {p}")
        print(f"check-localization-catalog: {len(problems)} finding(s) across {len(by_key)} keys "
              f"and {len(calls)} calls.")
        return 1
    print(f"check-localization-catalog: ok, {len(by_key)} keys from {len(calls)} calls, "
          f"each with English and {len(LOCALES)} locales.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
