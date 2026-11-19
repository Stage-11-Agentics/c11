#!/bin/zsh
# Host-end restore e2e (C11H-196): bring up a sandbox guest with a tagged c11
# app, drive guest.py through clean quit, host end and resume relaunch, and
# save the summary JSON. Run from a c11 checkout on the operator's laptop (the guest lives
# on the Tart host C11_SANDBOX_HOST names: scripts/dev-hosts.sh).
#
#   scripts/sandbox-host-end-e2e/run.sh <path/to/tagged.app> [--run-id ID] [--out FILE]
#       [--reuse] [--keep] [--allow-second] [t=120 quiet=20 cpu=30 n=8 noresume=1 again=1 t2=45 mode=signal|mass|marks|lifecycle]
#
# --reuse  the guest for --run-id is already up (sandbox-up.sh); skip up/down
# --keep   leave the guest running afterwards (sandbox-down.sh <run-id> removes it)
# Exit: 0 every assertion passed, 1 an assertion failed, 2 the harness failed.
set -u
zmodload zsh/datetime
here=${0:A:h}
root=${here:h:h}
app="" run_id="" out="" reuse=0 keep=0 second=()
extra=()
while (( $# )); do
  case "$1" in
    --run-id) run_id=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --reuse) reuse=1; shift ;;
    --keep) keep=1; shift ;;
    --allow-second) second=(--allow-second); shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *=*) extra+=("$1"); shift ;;
    *) [[ -z "$app" ]] || { print -u2 "unexpected argument: $1"; exit 2 }; app=$1; shift ;;
  esac
done
[[ -n "$run_id" ]] || run_id="hostend-$(date +%H%M%S)"
[[ -n "$out" ]] || out="$root/build-remote/c11h196-e2e-$run_id.json"
mkdir -p "${out:h}"
log="${out:r}.log"
cd "$root"
export PATH=/opt/homebrew/bin:$PATH

if (( ! reuse )); then
  [[ -d "$app" ]] || { print -u2 "app not found: $app"; exit 2 }
  scripts/sandbox-up.sh "$run_id" "$app" $second || exit 2
fi
cleanup() {
  (( reuse || keep )) || scripts/sandbox-down.sh "$run_id" >/dev/null 2>&1 || print -u2 "sandbox-down $run_id failed; run it again"
}
trap cleanup EXIT INT TERM

# The guest's app, socket and logs, as sandbox-up recorded them.
eval "$(bash -c 'source scripts/sandbox-common.sh; sandbox_load_meta "$1"; printf "GUEST_APP=%q\nSOCKET=%q\nLOG=%q\nDSOCK=%q\n" "$GUEST_APP" "$SOCKET" "$LOG" "$DSOCK"' _ "$run_id")"
[[ -n "${GUEST_APP:-}" && -n "${SOCKET:-}" ]] || { print -u2 "no guest metadata for $run_id"; exit 2 }

b64=$(base64 < "$here/guest.py" | tr -d '\n')
# mode=mass (C11H-235) clicks the strip's Resume all by its accessibility id: ship a compiled
# tests_v2/ax_walk.swift into the guest (one small swiftc, no xcodebuild).
ax_b64=-
if (( ${extra[(I)mode=mass]} )); then
  ax_bin=$(mktemp -t c11h235-ax-walk)
  if xcrun swiftc -O -target arm64-apple-macos14 "$root/tests_v2/ax_walk.swift" -o "$ax_bin" 2>/dev/null; then
    ax_b64=$(base64 < "$ax_bin" | tr -d '\n')
  else
    print -u2 "ax_walk did not compile; the strip click falls back to restore run --all"
  fi
  /bin/rm -f "$ax_bin"
fi
started=$EPOCHSECONDS
# Hard ceiling for the whole guest run; the driver's own waits are bounded well inside it.
/usr/bin/perl -e 'alarm shift; exec @ARGV' 900 \
  scripts/sandbox-exec.sh "$run_id" /bin/zsh -c \
  'print -r -- "$1" | /usr/bin/base64 -D > /tmp/c11h196-guest.py; if [[ "$2" != - ]]; then print -r -- "$2" | /usr/bin/base64 -D > /tmp/c11h196-ax-walk; chmod 755 /tmp/c11h196-ax-walk; fi; shift 2; exec /usr/bin/python3 -u /tmp/c11h196-guest.py "$@"' \
  _ "$b64" "$ax_b64" all "app=$GUEST_APP" "socket=$SOCKET" "log=$LOG" "dsock=$DSOCK" $extra 2>&1 | tee "$log"
rc=${pipestatus[1]}
print "guest run: $(( EPOCHSECONDS - started ))s, exit $rc, log $log"

python3 - "$log" "$out" <<'PY'
import json, sys
text = open(sys.argv[1], errors="replace").read()
a, b = "===C11H196-SUMMARY-BEGIN===", "===C11H196-SUMMARY-END==="
if a not in text or b not in text:
    sys.exit("no summary in the guest output")
summary = json.loads(text.rsplit(a, 1)[1].split(b, 1)[0])  # `again` prints a second, fuller one
json.dump(summary, open(sys.argv[2], "w"), indent=1)
print(f"summary: {sys.argv[2]}")
print(f"result: {summary['result']}  resumed {summary['resumed']}/{summary['panels']}  failed: {', '.join(summary['failed']) or 'none'}")
for name, v in summary["assertions"].items():
    print(f"  {'INFO' if v.get('informational') else 'PASS' if v['pass'] else 'FAIL'} {name}")
PY
(( $? == 0 )) || exit 2
[[ $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"])' "$out") == pass ]] && exit 0 || exit 1
