#!/usr/bin/env python3
"""Legacy entry point. Generates all c11mux icon variants (stable, debug,
nightly, staging) from the spike source via generate_c11mux_icon.py.

c11mux's palette does not diverge between light and dark appearances —
the brand is void-dominant, and the icon reads the same regardless of
NSAppearance. The _dark PNGs are still emitted for compatibility with
`Contents.json` appearance entries; they are byte-identical to the
light variants by design.
"""
from __future__ import annotations

import os
import sys


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    script = os.path.join(here, "generate_c11mux_icon.py")
    os.execv(sys.executable, [sys.executable, script, *sys.argv[1:]])


if __name__ == "__main__":
    sys.exit(main())
