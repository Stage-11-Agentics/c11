#!/bin/bash
# Run on Atlas's unlocked macOS GUI seat, against the opt-in test archive.
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "usage: $0 /absolute/path/libghostty-c11-read-test.a /absolute/output/directory" >&2
  exit 2
fi
fixture_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$fixture_dir/../.." && pwd)"
test_archive="$1"
output_dir="$2"
[[ "$test_archive" = /* && -f "$test_archive" && "$output_dir" = /* ]] || {
  echo "archive must exist and both paths must be absolute" >&2; exit 2;
}
mkdir -p "$output_dir"
xcrun clang -std=c11 -fobjc-arc -g \
  -I "$repo_dir/ghostty/include" "$fixture_dir/teardown_host.m" "$test_archive" \
  -lc++ -framework Cocoa -framework Metal -framework QuartzCore \
  -framework CoreText -framework CoreGraphics -framework IOSurface \
  -framework Carbon -framework IOKit -framework CoreVideo \
  -o "$output_dir/c11-teardown-host"
# The executable has a 30-second SIGALRM guard; this separate process also
# catches regressions that interfere with signal handling or initialization.
python3 - "$output_dir/c11-teardown-host" "$output_dir/teardown.log" <<'PY'
import os
import signal
import subprocess
import sys
binary, log = sys.argv[1:]
with open(log, "wb") as out:
    process = subprocess.Popen([binary], stdout=out, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        result = process.wait(timeout=40)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        out.write(b"AC1 FAIL: external watchdog expired\n")
        result = 124
with open(log, "r", errors="replace") as source:
    print(source.read(), end="")
sys.exit(result if result >= 0 else 128 - result)
PY
