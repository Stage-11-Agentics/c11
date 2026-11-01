"""Pytest entry. Direct ``python3 tests/test_*.py`` runs install from each file."""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import socket_guard

socket_guard.install()
