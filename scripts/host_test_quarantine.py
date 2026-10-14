#!/usr/bin/env python3
"""Parse the shared exact-method host-test quarantine inventory."""
import re
import sys
from pathlib import Path


TEST_ID = re.compile(r"c11Tests/[A-Za-z0-9_]+/test[A-Za-z0-9_]+\Z")


def read_host_test_quarantine(path):
    """Read unique exact c11Tests methods with one-line reasons."""
    path = Path(path)
    rows = []
    seen = set()
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        test_id, separator, reason = line.partition("\t")
        if (
            not separator
            or "\t" in reason
            or not reason.strip()
            or reason != reason.strip()
        ):
            raise ValueError(f"{path}:{line_number}: expected selector and one-line reason")
        if not TEST_ID.fullmatch(test_id):
            raise ValueError(f"{path}:{line_number}: expected one exact c11Tests method selector")
        if test_id in seen:
            raise ValueError(f"{path}:{line_number}: duplicate host quarantine selector {test_id}")
        seen.add(test_id)
        rows.append({"test_id": test_id, "reason": reason})
    return rows


def main():
    path = Path(__file__).with_name("host-test-quarantine.tsv")
    try:
        rows = read_host_test_quarantine(path)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2
    for row in rows:
        print("%s\t%s" % (row["test_id"], row["reason"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
