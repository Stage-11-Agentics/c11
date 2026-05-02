#!/usr/bin/env python3
"""Legacy entry point — delegates to generate_c11_icon.py.

c11 Module 5 consolidates all channel icon generation (stable, debug,
nightly, staging) into a single script that operates on the spike
source.
"""
from __future__ import annotations

import os
import sys


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    script = os.path.join(here, "generate_c11_icon.py")
    os.execv(sys.executable, [sys.executable, script, *sys.argv[1:]])


if __name__ == "__main__":
    sys.exit(main())
