#!/bin/zsh
# Abandoned-session e2e (C11H-352): bring up a sandbox guest with a tagged c11
# app, run guest.py (an hc session abandoned by killing its core and holder,
# listed and ended by c11-core), and save the summary JSON. Run from a c11 checkout on the
# operator's laptop; the guest lives on the Tart host (scripts/dev-hosts.sh).
#
#   scripts/sandbox-abandoned-e2e/run.sh <path/to/tagged.app> [--run-id ID] [--out FILE] [--reuse] [--keep]
#
# Exit: 0 every check passed, 1 a check failed, 2 the harness failed.
set -u
zmodload zsh/datetime
here=${0:A:h}
root=${here:h:h}
app="" run_id="" out="" reuse=0 keep=0
while (( $# )); do
  case "$1" in
    --run-id) run_id=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --reuse) reuse=1; shift ;;
    --keep) keep=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) [[ -z "$app" ]] || { print -u2 "unexpected argument: $1"; exit 2 }; app=$1; shift ;;
  esac
done
[[ -n "$run_id" ]] || run_id="abandoned-$(date +%H%M%S)"
[[ -n "$out" ]] || out="$root/build-remote/c11h352-e2e-$run_id.json"
mkdir -p "${out:h}"
log="${out:r}.log"
cd "$root"
export PATH=/opt/homebrew/bin:$PATH

if (( ! reuse )); then
  [[ -d "$app" ]] || { print -u2 "app not found: $app"; exit 2 }
  scripts/sandbox-up.sh "$run_id" "$app" || exit 2
fi
cleanup() {
  (( reuse || keep )) || scripts/sandbox-down.sh "$run_id" >/dev/null 2>&1 || print -u2 "sandbox-down $run_id failed; run it again"
}
trap cleanup EXIT INT TERM

eval "$(bash -c 'source scripts/sandbox-common.sh; sandbox_load_meta "$1"; printf "GUEST_APP=%q\nSOCKET=%q\nLOG=%q\nDSOCK=%q\n" "$GUEST_APP" "$SOCKET" "$LOG" "$DSOCK"' _ "$run_id")"
[[ -n "${GUEST_APP:-}" && -n "${SOCKET:-}" ]] || { print -u2 "no guest metadata for $run_id"; exit 2 }

b64=$(base64 < "$here/guest.py" | tr -d '\n')
started=$EPOCHSECONDS
# Hard ceiling for the whole guest run; the driver's own waits are bounded well inside it.
/usr/bin/perl -e 'alarm shift; exec @ARGV' 600 \
  scripts/sandbox-exec.sh "$run_id" /bin/zsh -c \
  'print -r -- "$1" | /usr/bin/base64 -D > /tmp/c11h352-guest.py; shift; exec /usr/bin/python3 -u /tmp/c11h352-guest.py "$@"' \
  _ "$b64" "app=$GUEST_APP" "socket=$SOCKET" "log=$LOG" "dsock=$DSOCK" 2>&1 | tee "$log"
rc=${pipestatus[1]}
print "guest run: $(( EPOCHSECONDS - started ))s, exit $rc, log $log"

python3 - "$log" "$out" <<'PY'
import json, sys
text = open(sys.argv[1], errors="replace").read()
a, b = "===C11H352-SUMMARY-BEGIN===", "===C11H352-SUMMARY-END==="
if a not in text or b not in text:
    sys.exit("no summary in the guest output")
summary = json.loads(text.rsplit(a, 1)[1].split(b, 1)[0])
json.dump(summary, open(sys.argv[2], "w"), indent=1)
print(f"summary: {sys.argv[2]}")
print(f"result: {summary['result']}  failed: {', '.join(summary['failed']) or 'none'}")
for name, v in summary["checks"].items():
    print(f"  {'INFO' if v.get('informational') else 'PASS' if v['pass'] else 'FAIL'} {name}")
if summary.get("harness_error"):
    print(f"  harness error: {summary['harness_error']}")
PY
(( $? == 0 )) || exit 2
[[ $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"])' "$out") == pass ]] && exit 0 || exit 1
