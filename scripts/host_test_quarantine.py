#!/usr/bin/env python3
"""Parse the shared exact-method host-test quarantine inventory."""
import argparse
import re
import sys
from pathlib import Path


TEST_ID = re.compile(r"c11Tests/[A-Za-z0-9_]+/test[A-Za-z0-9_]+\Z")


def read_host_test_quarantine(path):
    """Read unique exact c11Tests methods, scopes, and one-line reasons."""
    path = Path(path)
    rows = []
    seen = set()
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if (
            len(fields) != 3
            or any(not field for field in fields)
        ):
            raise ValueError(f"{path}:{line_number}: expected selector, scope, and one-line reason")
        test_id, scope, reason = fields
        if not reason.strip() or reason != reason.strip():
            raise ValueError(f"{path}:{line_number}: expected selector and one-line reason")
        if not TEST_ID.fullmatch(test_id):
            raise ValueError(f"{path}:{line_number}: expected one exact c11Tests method selector")
        if scope not in ("all", "atlas"):
            raise ValueError(f"{path}:{line_number}: scope must be all or atlas")
        if test_id in seen:
            raise ValueError(f"{path}:{line_number}: duplicate host quarantine selector {test_id}")
        seen.add(test_id)
        rows.append({"test_id": test_id, "scope": scope, "reason": reason})
    return rows


def ci_actions(rows):
    """Return the CI decision for every row, keeping Atlas-only tests in CI."""
    return [
        {"action": "skip" if row["scope"] == "all" else "run", **row}
        for row in rows
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ci-actions", action="store_true",
                        help="emit action, selector, scope, reason rows for the CI host gate")
    args = parser.parse_args()
    path = Path(__file__).with_name("host-test-quarantine.tsv")
    try:
        rows = read_host_test_quarantine(path)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2
    if args.ci_actions:
        rows = ci_actions(rows)
        for row in rows:
            print("%s\t%s\t%s\t%s" %
                  (row["action"], row["test_id"], row["scope"], row["reason"]))
    else:
        for row in rows:
            print("%s\t%s\t%s" % (row["test_id"], row["scope"], row["reason"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
