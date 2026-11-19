#!/usr/bin/env python3
"""C11H-248 native font-grid lock probe, run only in the fixture sandbox guest.

The copied sandbox launcher must inject C11_TEST_CREATION_FONT_LOCK=1 into the
fixture app's environment and truncate both its DEBUG log and stdout before
every launch. The probe identifies startup native creation ordinal 2, validates
that live terminal's identity/readiness, and includes its timings alongside two
driver-created terminals. This is the deterministic lock probe, not the separate
20-panel display-mode churn acceptance test. See the shared driver's docstring.
"""

import sys

from test_surface_creation_display_churn import main


if __name__ == "__main__":
    raise SystemExit(main(["--native-lock-only", *sys.argv[1:]]))
