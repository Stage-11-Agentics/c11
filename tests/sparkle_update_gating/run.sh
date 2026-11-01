#!/usr/bin/env bash
# Proves, with real Sparkle 2.8.1 and 2.9.3 clients, that the appcast
# scripts/sparkle_generate_appcast.sh writes for an arm64-only c11 keeps the
# update from Intel Macs and still offers it to Apple silicon. See README.md.
#
# Usage: tests/sparkle_update_gating/run.sh [results.json]
#   Results JSON goes to the given path, or to stdout; the table goes to stderr.
#   Exits non-zero if any case's verdict differs from the expected one.
set -euo pipefail

SPARKLE_281_SHA256="5cddb7695674ef7704268f38eccaee80e3accbf19e61c1689efff5b6116d85be"
SPARKLE_293_SHA256="74a07da821f92b79310009954c0e15f350173374a3abe39095b4fc5096916be6"
HOST_BUNDLE_ID="com.stage11.c11-tests.sparkle-update-gating.host"
PROBE_PREFIX="sparkle-gating-probe"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out_json="${1:-}"

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ "$(uname -m)" == "arm64" ]] || die "needs an Apple-silicon Mac"
/usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || die "needs Rosetta (softwareupdate --install-rosetta --agree-to-license)"
for tool in clang swiftc codesign hdiutil lipo python3 curl shasum; do
  command -v "$tool" >/dev/null || die "missing $tool"
done
pinned_293="$(sed -n 's/^SPARKLE_TOOLS_SHA256="\(.*\)"$/\1/p' "$repo/scripts/fetch-sparkle-tools.sh")"
[[ "$pinned_293" == "$SPARKLE_293_SHA256" ]] \
  || die "SPARKLE_293_SHA256 here differs from scripts/fetch-sparkle-tools.sh ($pinned_293)"

started=$SECONDS
tmp="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-update-gating.XXXXXX")"
server_pid=""

# The probes leave state outside $tmp: Sparkle's defaults for the fake host
# bundle id, and URLSession storage named after each probe binary. Remove
# what this run created, never what existed before it.
state_paths=()
for v in 281 293; do
  for a in arm64 x86_64; do
    state_paths+=("$HOME/Library/Caches/$PROBE_PREFIX-$v-$a"
                  "$HOME/Library/HTTPStorages/$PROBE_PREFIX-$v-$a"
                  "$HOME/Library/HTTPStorages/$PROBE_PREFIX-$v-$a.binarycookies")
  done
done
preexisting=" "
for p in "${state_paths[@]}"; do
  if [[ -e "$p" ]]; then preexisting+="$p "; fi
done
had_defaults=0
if defaults read "$HOST_BUNDLE_ID" >/dev/null 2>&1 || [[ -e "$HOME/Library/Preferences/$HOST_BUNDLE_ID.plist" ]]; then
  had_defaults=1
fi

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ $had_defaults == 0 ]]; then
    # defaults delete leaves an empty plist behind; remove it too.
    defaults delete "$HOST_BUNDLE_ID" >/dev/null 2>&1 || true
    /bin/rm -f "$HOME/Library/Preferences/$HOST_BUNDLE_ID.plist"
  fi
  for p in "${state_paths[@]}"; do
    if [[ "$preexisting" != *" $p "* ]]; then /bin/rm -rf "$p"; fi
  done
  /bin/rm -rf "$tmp"
}
trap cleanup EXIT

sparkle="$tmp/sparkle"   # extracted release tarballs only
build="$tmp/build"
feeds="$tmp/feeds"
mkdir -p "$sparkle" "$build" "$feeds"

log "== Sparkle 2.9.3 via scripts/fetch-sparkle-tools.sh"
bin293="$("$repo/scripts/fetch-sparkle-tools.sh" "$sparkle")"
fw293="$(cd "$bin293/.." && pwd)"
log "== Sparkle 2.8.1"
fw281="$sparkle/2.8.1"
mkdir -p "$fw281"
curl -fsSL --retry 3 -o "$fw281/Sparkle-2.8.1.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-2.8.1.tar.xz"
got="$(shasum -a 256 "$fw281/Sparkle-2.8.1.tar.xz" | awk '{print $1}')"
[[ "$got" == "$SPARKLE_281_SHA256" ]] || die "Sparkle 2.8.1 tarball checksum mismatch: $got"
tar -xf "$fw281/Sparkle-2.8.1.tar.xz" -C "$fw281"
/bin/rm -f "$fw281/Sparkle-2.8.1.tar.xz"
[[ -d "$fw281/Sparkle.framework" && -d "$fw293/Sparkle.framework" ]] || die "Sparkle.framework missing after extract"

log "== compile probes, interposer, payload, keygen"
for a in arm64 x86_64; do
  clang -fobjc-arc -arch "$a" -mmacosx-version-min=14.0 -F"$fw293" -framework Foundation -framework Sparkle \
    -Wl,-rpath,"$fw293" -o "$build/$PROBE_PREFIX-293-$a" "$here/probe.m"
  clang -fobjc-arc -arch "$a" -mmacosx-version-min=14.0 -F"$fw281" -framework Foundation -framework Sparkle \
    -Wl,-rpath,"$fw281" -o "$build/$PROBE_PREFIX-281-$a" "$here/probe281.m"
done
clang -arch x86_64 -dynamiclib -o "$build/fake_intel_x86_64.dylib" "$here/fake_intel.c"
clang -arch arm64 -mmacosx-version-min=14.0 -o "$build/hello-arm64" "$here/hello.c"
clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -o "$build/hello-universal" "$here/hello.c"
swiftc -o "$build/keygen" "$here/keygen.swift"

{ read -r private_seed; read -r public_key; } < <("$build/keygen")
key_file="$build/ed25519.key"
printf '%s' "$private_seed" > "$key_file"

plist() { # path bundle-id short-version build [executable]
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleName</key><string>Hello</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$3</string>
<key>CFBundleVersion</key><string>$4</string>
${5:+<key>CFBundleExecutable</key><string>$5</string>}
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUPublicEDKey</key><string>$public_key</string>
</dict></plist>
EOF
}

log "== payload apps and DMGs (arm64-only 2.0.0 build 200, universal 1.6.0 build 160)"
make_dmg() { # name binary short-version build
  local stage="$build/stage-$1"
  mkdir -p "$stage/Hello.app/Contents/MacOS"
  /bin/cp "$2" "$stage/Hello.app/Contents/MacOS/Hello"
  plist "$stage/Hello.app/Contents/Info.plist" com.stage11.c11-tests.sparkle-update-gating.payload "$3" "$4" Hello
  codesign -s - --force "$stage/Hello.app" 2>/dev/null
  hdiutil create -quiet -volname Hello -srcfolder "$stage" -ov -format UDZO "$build/Hello-$1.dmg"
}
make_dmg arm64 "$build/hello-arm64" 2.0.0 200
make_dmg universal "$build/hello-universal" 1.6.0 160
# A nightly payload numbered like nightly.yml (run id + two-digit attempt).
make_dmg nightly "$build/hello-arm64" 1.8.0-nightly 3799999999901
# Hosts: 0.x (131), 1.0.0 (132), 1.x (160), the last Sparkle 2.8.1 nightly and the first 2.9.3 one.
for b in 131:0.67.0 132:1.0.0 160:1.6.0 3684650524801:0.67.0-nightly 3711499935701:1.0.0-nightly; do
  mkdir -p "$build/FakeC11-${b%%:*}.app/Contents"
  plist "$build/FakeC11-${b%%:*}.app/Contents/Info.plist" "$HOST_BUNDLE_ID" "${b#*:}" "${b%%:*}"
done

log "== feeds from scripts/sparkle_generate_appcast.sh"
for v in arm64 universal nightly; do
  below=()
  # The nightly feed gets nightly.yml's threshold, read from the workflow itself.
  if [[ "$v" == nightly ]]; then
    nightly_below="$(sed -n 's/.*SPARKLE_LEGACY_BELOW_BUILD: "\([0-9]*\)".*/\1/p' "$repo/.github/workflows/nightly.yml")"
    [[ -n "$nightly_below" ]] || die "nightly.yml sets no SPARKLE_LEGACY_BELOW_BUILD"
    below=(SPARKLE_LEGACY_BELOW_BUILD="$nightly_below")
  fi
  if ! env -u SPARKLE_PRIVATE_KEY -u DOWNLOAD_URL_PREFIX -u RELEASE_NOTES_URL -u SPARKLE_LEGACY_BELOW_BUILD \
      SPARKLE_BIN_DIR="$bin293" SPARKLE_PRIVATE_KEY_FILE="$key_file" ${below[@]+"${below[@]}"} \
      "$repo/scripts/sparkle_generate_appcast.sh" "$build/Hello-$v.dmg" vTEST "$feeds/guarded-$v.xml" \
      > "$build/generate-$v.log" 2>&1; then
    cat "$build/generate-$v.log" >&2
    die "sparkle_generate_appcast.sh failed for the $v DMG"
  fi
  grep -q 'did not add edSignature' "$build/generate-$v.log" && die "generate_appcast did not sign the $v DMG (key mismatch)"
done
sig="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$feeds/guarded-arm64.xml")"
"$bin293/sign_update" --verify --ed-key-file "$key_file" "$build/Hello-arm64.dmg" "$sig" \
  || die "edSignature in the guarded feed does not verify against the DMG"

# Unguarded and mutant feeds are edited copies of the guarded one; each edit
# must change exactly what it names.
python3 -I - "$feeds" <<'PY'
import re
import sys

feeds = sys.argv[1]
guarded = open(f"{feeds}/guarded-arm64.xml", encoding="utf-8").read()
universal = open(f"{feeds}/guarded-universal.xml", encoding="utf-8").read()
link = r"^[ \t]*<link>[^<]*</link>\n"
info = r"^[ \t]*<sparkle:informationalUpdate>\n[ \t]*<sparkle:belowVersion>132</sparkle:belowVersion>\n[ \t]*</sparkle:informationalUpdate>\n"
hardware = r"^[ \t]*<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>\n"
for name, pattern in (("link", link), ("informationalUpdate belowVersion 132", info), ("hardwareRequirements arm64", hardware)):
    if len(re.findall(pattern, guarded, re.M)) != 1:
        sys.exit(f"guarded arm64 feed lacks exactly one {name}")
    if re.search(pattern, universal, re.M):
        sys.exit(f"universal feed carries {name}")

def edit(name, pattern, repl):
    text, n = re.subn(pattern, repl, guarded, flags=re.M)
    if n != 1:
        sys.exit(f"{name}: expected one edit, made {n}")
    open(f"{feeds}/{name}", "w", encoding="utf-8").write(text)

text, n = re.subn(f"{link}{info}", "", guarded, flags=re.M)
if n != 1:
    sys.exit("unguarded-arm64.xml: guard block not found")
open(f"{feeds}/unguarded-arm64.xml", "w", encoding="utf-8").write(text)
edit("mutant-no-hardware.xml", hardware, "")
edit("mutant-below161.xml", r"<sparkle:belowVersion>132</sparkle:belowVersion>", "<sparkle:belowVersion>161</sparkle:belowVersion>")
edit("mutant-no-link.xml", link, "")

nightly = open(f"{feeds}/guarded-nightly.xml", encoding="utf-8").read()
nightly_info = r"^[ \t]*<sparkle:informationalUpdate>\n[ \t]*<sparkle:belowVersion>3711499935701</sparkle:belowVersion>\n[ \t]*</sparkle:informationalUpdate>\n"
if len(re.findall(f"{link}{nightly_info}", nightly, re.M)) != 1:
    sys.exit("guarded nightly feed lacks the link plus informationalUpdate belowVersion 3711499935701")
text, n = re.subn(f"{link}{nightly_info}", "", nightly, flags=re.M)
open(f"{feeds}/unguarded-nightly.xml", "w", encoding="utf-8").write(text)
PY

log "== serve feeds on a free localhost port"
python3 -I -c '
import functools, http.server, os, sys
directory, port_file = sys.argv[1:]
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=directory))
with open(port_file + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
os.rename(port_file + ".tmp", port_file)
server.serve_forever()
' "$feeds" "$build/port" &
server_pid=$!
for _ in $(seq 1 100); do
  [[ -s "$build/port" ]] && break
  kill -0 "$server_pid" 2>/dev/null || die "feed server exited"
  sleep 0.1
done
[[ -s "$build/port" ]] || die "feed server did not start"
port="$(cat "$build/port")"

log "== matrix"
# id|description|sparkle|client|host build|feed|expected substring|expected verdict
# GREEN means the observed RESULT line contains the expected substring.
cases="$(cat <<'EOF'
1|Intel Mac on c11 0.x: information-only|281|intel|131|guarded-arm64.xml|OFFERED  informationOnly=YES|GREEN
2|Apple silicon on c11 0.x: information-only (manual download)|281|arm64|131|guarded-arm64.xml|OFFERED  informationOnly=YES|GREEN
3|Intel Mac on c11 1.x: not offered (hardware)|293|intel|160|guarded-arm64.xml|NOT OFFERED  reason=5|GREEN
4|Apple silicon on c11 1.x: offered, installable|293|arm64|160|guarded-arm64.xml|OFFERED  informationOnly=NO|GREEN
5|Intel build under Rosetta on c11 1.x: offered|293|rosetta|160|guarded-arm64.xml|OFFERED  informationOnly=NO|GREEN
4b|Apple silicon on c11 1.0.0 (boundary build 132): installable|293|arm64|132|guarded-arm64.xml|OFFERED  informationOnly=NO|GREEN
6|Intel Mac on c11 0.x, universal feed: installable|281|intel|131|guarded-universal.xml|OFFERED  informationOnly=NO|GREEN
u1|unguarded: Intel Mac on c11 0.x would install|281|intel|131|unguarded-arm64.xml|OFFERED  informationOnly=YES|RED
u2|unguarded: Apple silicon on c11 0.x installs|281|arm64|131|unguarded-arm64.xml|OFFERED  informationOnly=YES|RED
u3|unguarded: Intel Mac on c11 1.x not offered|293|intel|160|unguarded-arm64.xml|NOT OFFERED  reason=5|GREEN
u4|unguarded: Apple silicon on c11 1.x offered|293|arm64|160|unguarded-arm64.xml|OFFERED  informationOnly=NO|GREEN
u5|unguarded: Rosetta on c11 1.x offered|293|rosetta|160|unguarded-arm64.xml|OFFERED  informationOnly=NO|GREEN
u4b|unguarded: Apple silicon on c11 1.0.0 offered|293|arm64|132|unguarded-arm64.xml|OFFERED  informationOnly=NO|GREEN
m3|mutant, hardware tag removed: case 3 fails|293|intel|160|mutant-no-hardware.xml|NOT OFFERED  reason=5|RED
m4|mutant, belowVersion 161: case 4 fails|293|arm64|160|mutant-below161.xml|OFFERED  informationOnly=NO|RED
m1|mutant, link removed: case 1 fails|281|intel|131|mutant-no-link.xml|OFFERED  informationOnly=YES|RED
n1|Intel Mac on a Sparkle 2.8.1 nightly: information-only|281|intel|3684650524801|guarded-nightly.xml|OFFERED  informationOnly=YES|GREEN
n2|Intel Mac on a Sparkle 2.9.3 nightly: not offered (hardware)|293|intel|3711499935701|guarded-nightly.xml|NOT OFFERED  reason=5|GREEN
n3|Apple silicon on a Sparkle 2.9.3 nightly: offered, installable|293|arm64|3711499935701|guarded-nightly.xml|OFFERED  informationOnly=NO|GREEN
un1|unguarded nightly: Intel Mac on a 2.8.1 nightly would install|281|intel|3684650524801|unguarded-nightly.xml|OFFERED  informationOnly=YES|RED
EOF
)"
results="$build/results.tsv"
: > "$results"
while IFS='|' read -r id desc sparkle_version client host_build feed expect want; do
  [[ -n "$id" ]] || continue
  arch=x86_64
  [[ "$client" == "arm64" ]] && arch=arm64
  probe=("$build/$PROBE_PREFIX-$sparkle_version-$arch" "$build/FakeC11-$host_build.app" "http://127.0.0.1:$port/$feed")
  if [[ "$client" == "intel" ]]; then
    output="$(DYLD_INSERT_LIBRARIES="$build/fake_intel_x86_64.dylib" "${probe[@]}" </dev/null 2>&1 || true)"
  else
    output="$(env -u DYLD_INSERT_LIBRARIES "${probe[@]}" </dev/null 2>&1 || true)"
  fi
  result_line="$(grep -m1 '^RESULT:' <<<"$output" || true)"
  process_line="$(grep -m1 '^process:' <<<"$output" || true)"
  if [[ -z "$result_line" ]]; then result_line="no RESULT line: $(tr '\t\n' '  ' <<<"$output")"; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$desc" "$sparkle_version" "$client" "$host_build" "$feed" \
    "$expect" "$want" "$result_line" "$process_line" >> "$results"
done <<<"$cases"

set +e
python3 -I - "$results" "$out_json" "$SPARKLE_281_SHA256" "$SPARKLE_293_SHA256" "$((SECONDS - started))" <<'PY'
import datetime
import json
import sys

results, out_json, sha281, sha293, elapsed = sys.argv[1:]
clients = {"arm64": "arm64 native", "rosetta": "x86_64 under Rosetta", "intel": "x86_64, simulated native Intel"}
cases = []
for row in open(results, encoding="utf-8"):
    cid, desc, version, client, host, feed, expect, want, observed, process = row.rstrip("\n").split("\t")
    verdict = "GREEN" if expect in observed else "RED"
    cases.append({
        "case": cid, "description": desc,
        "client": f"Sparkle {version[0]}.{version[1]}.{version[2]}, {clients[client]}",
        "host_build": int(host), "feed": feed, "expected": expect, "expected_verdict": want,
        "observed": observed, "process": process, "verdict": verdict, "ok": verdict == want,
    })
failed = [c["case"] for c in cases if not c["ok"]]
for c in cases:
    mark = "ok  " if c["ok"] else "FAIL"
    print(f"{mark} {c['verdict']:<5} (want {c['expected_verdict']:<5}) {c['case']:<4} {c['description']}", file=sys.stderr)
    print(f"           {c['client']}, host build {c['host_build']}, {c['feed']}", file=sys.stderr)
    print(f"           {c['observed']}", file=sys.stderr)
print(f"{len(cases) - len(failed)}/{len(cases)} cases as expected" + (f"; FAILED: {', '.join(failed)}" if failed else ""), file=sys.stderr)
doc = {
    "generated": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "elapsed_seconds_before_report": int(elapsed),
    "sparkle_tarball_sha256": {"2.8.1": sha281, "2.9.3": sha293},
    "simulated_intel": "fake_intel.c makes sysctl.proc_translated return ENOENT in an x86_64 probe under Rosetta",
    "cases": cases,
    "summary": {"total": len(cases), "as_expected": len(cases) - len(failed), "failed": failed},
}
text = json.dumps(doc, indent=2) + "\n"
if out_json:
    open(out_json, "w", encoding="utf-8").write(text)
    print(f"results: {out_json}", file=sys.stderr)
else:
    sys.stdout.write(text)
sys.exit(1 if failed else 0)
PY
status=$?
set -e
log "wall time: $((SECONDS - started)) s"
exit "$status"
