#!/usr/bin/env python3
"""Isolated layout slice; run only via sandbox-tests-v2.sh in an owned guest."""
from test_titlebar_focus_history import main

if __name__ == '__main__':
    main(layout_only=True)
