#!/bin/bash
# Focused runtime fixtures; no app build, real c11 socket, or user dotfiles.
set -eu
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$TEST_DIR/test_shell_git_watchers.py" "$@"
