#!/usr/bin/env bash
# run-pass.sh <N> : apply pass-<N>.tsv, then its hand-edit patch (pass-<N>.manual.patch) if any.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
n="$1"
python3 scripts/vocab-rename/rename.py apply "scripts/vocab-rename/pass-${n}.tsv" | tee "/tmp/c11-vocab-pass-${n}.log"
if [[ -f "scripts/vocab-rename/pass-${n}.manual.patch" ]]; then
  git apply --3way --whitespace=nowarn "scripts/vocab-rename/pass-${n}.manual.patch"
fi
