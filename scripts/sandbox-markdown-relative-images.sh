#!/usr/bin/env bash
# C11-387 acceptance: relative images follow the current document after in-panel navigation.
# Usage: scripts/sandbox-markdown-relative-images.sh <run-id> <out-dir>
#
# Needs a guest from scripts/sandbox-up.sh. Builds two documents in different folders, each
# with a relative pic.png of a different solid color (A red, B blue), opens A in a markdown
# panel, navigates the same panel to B, then back to A and forward. A
# screenshot of the guest display is taken after each step and classified by dominant color.
# Exit 0 only when the picture follows the document at every step.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=sandbox-common.sh
source "$SCRIPT_DIR/sandbox-common.sh"

[[ $# -eq 2 ]] || { echo "Usage: $0 <run-id> <out-dir>" >&2; exit 1; }
run_id="$1"
out="$2"
sandbox_validate_run_id "$run_id"
mkdir -p "$out"

exec_guest() { "$SCRIPT_DIR/sandbox-exec.sh" "$run_id" "$@"; }

cli="$(exec_guest zsh -c "ls -d /Users/admin/c11-sandbox/apps/$run_id/*.app | head -1")/Contents/Resources/bin/c11"
socket="/tmp/c11-sandbox-$run_id.sock"
c11() { exec_guest "$cli" --socket "$socket" "$@"; }

# A fresh guest can raise System Settings over the display; it would hide the panel in every screenshot.
exec_guest osascript -e 'tell application "System Settings" to quit' >/dev/null 2>&1 || true

echo "== fixtures =="
fixture_code="$(cat <<'PY'
import os, struct, zlib
base = "/Users/admin/c11-387"
def png(path, rgb, w=360, h=240):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
for name, rgb in (("a", (255, 0, 0)), ("b", (0, 0, 255))):
    folder = os.path.join(base, name)
    os.makedirs(folder, exist_ok=True)
    png(os.path.join(folder, "pic.png"), rgb)
    with open(os.path.join(folder, "doc.md"), "w") as f:
        f.write("# Document %s\n\n![pic](pic.png)\n" % name.upper())
PY
)"
exec_guest /usr/bin/python3 -c "$fixture_code"

echo "== open A, then navigate the same panel to B =="
opened="$(c11 markdown open /Users/admin/c11-387/a/doc.md)"
echo "$opened"
panel="$(printf '%s' "$opened" | grep -o 'panel:[0-9]*' | head -1)"
[[ -n "$panel" ]] || { echo "no panel ref in: $opened" >&2; exit 1; }

shot() {
  sleep 4
  "$SCRIPT_DIR/sandbox-shot.sh" "$run_id" "$out/$1.png" >/dev/null
  echo "shot $out/$1.png"
}
# The panel's toolbar back and forward arrows, at their place in a fresh guest's layout.
click() { exec_guest /opt/homebrew/bin/cliclick "c:$1"; }

shot 1-a-before
c11 markdown open /Users/admin/c11-387/b/doc.md --panel "$panel"
shot 2-b-after-navigate
click 652,110
shot 3-a-after-back
click 677,110
shot 4-b-after-forward

echo "== classify =="
python3 -I - "$out" <<'PY'
import subprocess, sys, tempfile, os
out = sys.argv[1]
def dominant(png):
    with tempfile.TemporaryDirectory() as tmp:
        bmp = os.path.join(tmp, "s.bmp")
        subprocess.run(["sips", "-s", "format", "bmp", png, "--out", bmp], check=True, capture_output=True)
        data = open(bmp, "rb").read()
    offset = int.from_bytes(data[10:14], "little")
    bpp = int.from_bytes(data[28:30], "little") // 8
    pixels = memoryview(data)[offset:]
    red = blue = 0
    for i in range(0, len(pixels) - bpp, bpp * 5):
        b, g, r = pixels[i], pixels[i + 1], pixels[i + 2]
        if r > 200 and g < 60 and b < 60: red += 1
        elif b > 200 and r < 60 and g < 60: blue += 1
    return red, blue
expect = {"1-a-before": "red", "2-b-after-navigate": "blue", "3-a-after-back": "red", "4-b-after-forward": "blue"}
failed = False
for name, want in expect.items():
    red, blue = dominant(os.path.join(out, name + ".png"))
    seen = "red" if red > 2000 and blue < 200 else "blue" if blue > 2000 and red < 200 else f"unclear(red={red},blue={blue})"
    ok = seen == want
    failed |= not ok
    print(f"{'PASS' if ok else 'FAIL'} {name}: picture is {seen} (want {want}); red={red} blue={blue}")
sys.exit(1 if failed else 0)
PY
