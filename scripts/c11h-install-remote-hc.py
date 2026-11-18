#!/usr/bin/env python3
# c11-2.0:shim: the old name; runs c11-install-remote-hc.py.
import os, sys
here = os.path.dirname(os.path.abspath(__file__))
os.execv(sys.executable, [sys.executable, os.path.join(here, 'c11-install-remote-hc.py')] + sys.argv[1:])
