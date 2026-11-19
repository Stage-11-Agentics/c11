#!/bin/zsh
# c11 2.0 migration e2e (C11H-266). Brings up a Tart guest on the Tart host (C11_SANDBOX_HOST), installs a
# real c11h build, builds a world of stand-in agents across shards and hidden
# workspaces, quits c11h, then launches the app under test and checks every
# panel came back attached (same pid, scrollback, input, nothing typed or resumed).
#
#   scripts/c11-2.0-migration-e2e/run.sh --c11h <c11h.app> [--app <2.0.app>] [--c11-1x <c11.app>] [--run-id ID]
#       [--scenario baseline|h15-to-2.0|twice|back-to-c11h|baseline1x|1x-to-2.0|both|convergence|batch] [--keep] [--reuse] [--allow-second]
#       [--app-env K=V,K=V] [--app-sock <guest socket path>]
#
# baseline     c11h -> quit -> c11h again (the harness checking itself).
# h15-to-2.0   c11h -> quit -> the --app build with C11_MIGRATION_QA=1.
# twice        h15-to-2.0, then quit and launch the --app build again.
# back-to-c11h h15-to-2.0, then quit it and launch c11h: its own state and terminals.
# baseline1x   c11 1.8.x world -> quit -> 1.8.x again (the 1.x checker checking itself).
# 1x-to-2.0    c11 1.8.x world -> quit -> the --app build: workspaces, titles, settings carried.
# both         c11 1.8.x world and a c11h world -> the --app build takes c11h's, keeps 1.x's aside.
# convergence  F1 adopt then host end, F2 direct convergence; each checks a second launch for no extra resume.
# batch        every proof in one guest boot (needs --app and --c11-1x): c11h still running at
#              first launch, twice, back to c11h, a big world (72 panels, 1 GiB browser store,
#              timed) with the survivor's everyday verbs, a crash after each adopt step, a host
#              end then convergence, 1.8.1 -> 2.0, and both with a crash mid keep-aside.
#
# Output: build-remote/mig-e2e-<run-id>/ (verdict JSONs, screenshots, guest log,
# the migration log). Exit 0 all checks pass, 1 a check failed, 2 the harness failed.
# Runs only in a guest; never against the operator's session.
set -u
here=${0:A:h}
root=${here:h:h}
c11h_app="" app="" onex_app="" run_id="" scenario=baseline reuse=0 keep=0 second=() app_env="" app_sock=""
while (( $# )); do
  case "$1" in
    --c11h) c11h_app=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    --c11-1x) onex_app=$2; shift 2 ;;
    --run-id) run_id=$2; shift 2 ;;
    --scenario) scenario=$2; shift 2 ;;
    --app-env) app_env=$2; shift 2 ;;
    --app-sock) app_sock=$2; shift 2 ;;
    --reuse) reuse=1; shift ;;
    --keep) keep=1; shift ;;
    --allow-second) second=(--allow-second); shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) print -u2 -r -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$run_id" ]] || run_id="mig-$(date +%H%M%S)"
out="$root/build-remote/mig-e2e-$run_id"
mkdir -p "$out"
log="$out/guest.log"
cd "$root"
export PATH=/opt/homebrew/bin:$PATH
[[ "$scenario" == baseline* || -n "$app" ]] || { print -u2 -r -- "--scenario $scenario needs --app"; exit 2 }

# Tart host disk rule (Chief of Staff, 2026-11-13): start only with >= 60 GiB free,
# stop at once under 50 GiB (MIG_DISK_START / MIG_DISK_STOP when a turn sets others). One c11 2.0 guest at a time; delete it once recorded.
atlas_free_gib() {
  bash -c 'source scripts/sandbox-common.sh; sandbox_on_host' <<<'df -g / | awk "NR==2 {print \$4}"' 2>/dev/null | tail -1
}
disk_ok() {
  local need=$1 free
  free=$(atlas_free_gib)
  [[ "$free" == <-> ]] || { print -u2 -r -- "could not read the Tart host's free space"; return 1 }
  (( free >= need )) || { print -u2 -r -- "the Tart host has ${free} GiB free, under ${need} GiB: stopping"; return 1 }
}
# MIG_DRY=1 walks every stage with its arguments and no VM: no clone, no copy, no fetch.
[[ -n "${MIG_DRY:-}" ]] && reuse=1
if (( ! reuse )); then
  disk_ok ${MIG_DISK_START:-60} || exit 2
  [[ -d "$c11h_app" ]] || { print -u2 -r -- "c11h app not found: $c11h_app"; exit 2 }
  # This branch's sandbox scripts launch a c11-named app; c11h is pushed beside it.
  scripts/sandbox-up.sh "$run_id" "${app:-$c11h_app}" $second || exit 2
fi
fetch_results() {
  (( fetched )) && return 0
  fetched=1
  scripts/sandbox-exec.sh "$run_id" /bin/zsh -c 'cp /tmp/migw/record*.json /tmp/migw-results/ 2>/dev/null; cd /tmp/migw-results && tar -cf - * 2>/dev/null | /usr/bin/base64; for f in ~/Library/Logs/c11/migration.log; do [[ -f $f ]] && { print "===LOG==="; cat $f } ; done' > "$out/fetch.b64" 2>/dev/null
  python3 - "$out" <<'PY'
import base64, io, os, sys, tarfile
out = sys.argv[1]
raw = open(os.path.join(out, "fetch.b64")).read()
b64, _, mlog = raw.partition("===LOG===")
try:
    tarfile.open(fileobj=io.BytesIO(base64.b64decode(b64))).extractall(out)
except Exception as e:
    print("fetch failed:", e)
if mlog.strip():
    open(os.path.join(out, "migration.log"), "w").write(mlog.strip() + "\n")
os.remove(os.path.join(out, "fetch.b64"))
print("artifacts:", out)
PY

}
fetched=0
cleanup() {
  # Whatever was recorded comes back on every exit, before the guest goes.
  [[ -n "${GUEST_APP:-}" ]] && fetch_results
  (( reuse || keep )) || scripts/sandbox-down.sh "$run_id" >/dev/null 2>&1 || print -u2 -r -- "sandbox-down $run_id failed; run it again"
}
trap cleanup EXIT INT TERM

if [[ -n "${MIG_DRY:-}" ]]; then
  GUEST_APP=/dry/c11-sandbox/apps/$run_id/app.app; fetched=1
else
eval "$(bash -c 'source scripts/sandbox-common.sh; sandbox_load_meta "$1"; printf "GUEST_APP=%q\n" "$GUEST_APP"' _ "$run_id")"
fi
[[ -n "${GUEST_APP:-}" ]] || { print -u2 -r -- "no guest metadata for $run_id"; exit 2 }

# Copy a local .app into the guest at /tmp/migw-apps/<name>, through the Tart host.
push_app() {
  if [[ -n "${MIG_DRY:-}" ]]; then print -r -- "DRY push $1"; return 0; fi
  local src=$1 base=${1:t} rel=".c11-sandbox/mig-apps/$run_id"
  COPYFILE_DISABLE=1 tar -C "${src:h}" -cf - "$base" | bash -c 'source scripts/sandbox-common.sh; sandbox_extract_tar "$1"' _ "$rel" || return 1
  bash -c 'source scripts/sandbox-common.sh; sandbox_on_host' <<EOF
set -eu
$(bash -c 'source scripts/sandbox-common.sh; sandbox_host_prelude')
load_meta $(printf '%q' "$run_id")
ip="\$(guest_ip "\$VM")"
COPYFILE_DISABLE=1 tar -C "\$HOME/$rel" -cf - $(printf '%q' "$base") | guest_receive_tar "\$ip" /tmp/migw-apps
EOF
}

guest() {
  if [[ -n "${MIG_DRY:-}" ]]; then print -r -- "DRY guest $*"; return 0; fi
  disk_ok ${MIG_DISK_STOP:-50} || exit 2
  local b64
  b64=$(base64 < "$here/guest.py" | tr -d '\n')
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 1500 \
    scripts/sandbox-exec.sh "$run_id" /bin/zsh -c \
    'print -r -- "$1" | /usr/bin/base64 -D > /tmp/mig-guest.py; shift; exec /usr/bin/python3 -u /tmp/mig-guest.py "$@"' \
    _ "$b64" "$@" "run=$run_id" 2>&1 | tee -a "$log"
  return ${pipestatus[1]}
}

# Mark this guest for this run: guest.py refuses to run anywhere without it.
if [[ -z "${MIG_DRY:-}" ]]; then
  scripts/sandbox-exec.sh "$run_id" /bin/zsh -c 'print -r -- "$1" > /var/tmp/c11-2.0-migration-guest' _ "$run_id" || exit 2
fi
# The c11h app every scenario installs at /Applications/c11h.app.
c11h_guest="$GUEST_APP"
if [[ -n "$app" ]]; then
  push_app "$c11h_app" || { print -u2 -r -- "could not push $c11h_app"; exit 2 }
  c11h_guest="/tmp/migw-apps/${c11h_app:t}"
fi
guest_app=""
if [[ -n "$app" ]]; then
  push_app "$app" || { print -u2 -r -- "could not push $app"; exit 2 }
  guest_app="/tmp/migw-apps/${app:t}"
fi
mig_env="C11_MIGRATION_QA=1${app_env:+,$app_env}"
sock_arg=()
[[ -n "$app_sock" ]] && sock_arg=("sock=$app_sock")

# Stage 0 (optional): another seat's guest script, run first on the same boot,
# beside a running c11h h15: build-remote/mig-stage0.sh, called as
# `stage0.sh <c11h.app> <2.0.app>` inside the guest. Its output and exit code are
# kept in the results as stage0.log; a failure does not stop the batch.
run_stage0() {
  local script="$root/build-remote/mig-stage0.sh" b64 code
  [[ -f "$script" ]] || return 0
  disk_ok ${MIG_DISK_STOP:-50} || exit 2
  guest setup "src=$c11h_guest" || return 2
  b64=$(base64 < "$script" | tr -d '\n')
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 1500 \
    scripts/sandbox-exec.sh "$run_id" /bin/zsh -c \
    'mkdir -p /tmp/migw-results; print -r -- "$1" | /usr/bin/base64 -D > /tmp/mig-stage0.sh; /bin/zsh /tmp/mig-stage0.sh "$2" "$3" > /tmp/migw-results/stage0.log 2>&1; c=$?; print "exit $c" >> /tmp/migw-results/stage0.log; cat /tmp/migw-results/stage0.log; exit $c' \
    _ "$b64" /Applications/c11h.app "$guest_app" 2>&1 | tee -a "$log"
  code=${pipestatus[1]}
  print -r -- "stage0 exit $code" | tee -a "$log"
  return 0
}

# Shared by the full batch and the bounded convergence-only guest turn.
run_convergence() {
  local A="app=$guest_app" E="env=$mig_env"
  # F1. Adopt, then a reboot-like host end, then convergence. The original mark
  # spans both 2.0 launches, so a duplicate resume on the second one fails.
  { guest setupclaude "src=$c11h_guest" && guest quit &&
    guest relaunch "$A" "$E" $sock_arg label=F1-adopt && guest quit "$A" &&
    guest hostend "$A" && guest mark name=F1 preserve=1 &&
    guest relaunch "$A" "$E" $sock_arg label=F1-converge &&
    { guest checkconverged "$A" "$E" $sock_arg label=F1-adopt-then-converge since_mark=F1 || rc=1; guest shot label=F1-converged; } &&
    guest quit "$A" && guest relaunch "$A" "$E" $sock_arg label=F1-repeat &&
    { guest checkconverged "$A" "$E" $sock_arg label=F1-repeat-no-extra-resume since_mark=F1 || rc=1; guest shot label=F1-repeat; }
  } || { print -r -- "scenario F1 stopped"; rc=1 }
  # F2. No adopted terminal is alive at 2.0's first launch.
  { guest setupclaude "src=$c11h_guest" && guest quit &&
    guest hostend && guest mark name=F2 preserve=1 &&
    guest relaunch "$A" "$E" $sock_arg label=F2-converge &&
    { guest checkconverged "$A" "$E" $sock_arg label=F2-direct-converge since_mark=F2 || rc=1; guest shot label=F2-converged; } &&
    guest quit "$A" && guest relaunch "$A" "$E" $sock_arg label=F2-repeat &&
    { guest checkconverged "$A" "$E" $sock_arg label=F2-repeat-no-extra-resume since_mark=F2 || rc=1; guest shot label=F2-repeat; }
  } || { print -r -- "scenario F2 stopped"; rc=1 }
  return 0
}

run_batch() {
  local A="app=$guest_app" E="env=$mig_env" s
  run_stage0 || rc=1
  # Each scenario starts from its own setup, so one failing never stops the rest.
  # A. c11h still running at 2.0's first launch: 2.0 quits it, then adopts.
  {
    guest setup "src=$c11h_guest" &&
    guest relaunch "$A" "$E" label=A measure=1 &&
    { guest check "$A" label=A-c11h-running-adopt || rc=1; guest shot label=A-adopted; } &&
    # B. twice is once.
    guest quit "$A" && guest relaunch "$A" "$E" label=B && { guest check "$A" label=B-second-launch || rc=1; } &&
    # C. back to c11h, then forward again.
    guest quit "$A" && guest relaunch app=/Applications/c11h.app label=C1 measure=1 && { guest check label=C-back-to-c11h || rc=1; } &&
    guest quit && guest relaunch "$A" "$E" label=C2 && { guest check "$A" label=C-forward-again || rc=1; }
  } || { print -r -- "scenario A-C stopped"; rc=1 }
  # D. a realistic world, timed, with the survivor's everyday verbs; F. host end, then convergence.
  {
    guest setup "src=/Applications/c11h.app" world=big && guest quit &&
    # Baseline: c11h h15 relaunching the same 72-panel world.
    guest relaunch app=/Applications/c11h.app label=D0-h15-baseline measure=1 wait=600 &&
    guest quit &&
    guest relaunch "$A" "$E" label=D measure=1 wait=600 &&
    { guest check "$A" label=D-big-adopt skew=1 settle=90 || rc=1; guest shot label=D-big; } &&
    guest quit "$A"
  } || { print -r -- "scenario D stopped"; rc=1 }
  # MIG_NO_CONVERGE=1 leaves out F1/F2 from a mixed batch.
  [[ -n "${MIG_NO_CONVERGE:-}" ]] || run_convergence
  # E. a crash right after each adopt step, then a clean launch.
  for s in defaults adopt_files adopt_links; do
    { guest setup "src=/Applications/c11h.app" && guest quit &&
      { guest crashlaunch "$A" "step=$s" || rc=1; } &&
      guest relaunch "$A" "$E" "label=E-$s" && { guest check "$A" "label=E-crash-$s" || rc=1; }
    } || { print -r -- "scenario E-$s stopped"; rc=1 }
  done
  # G. c11 1.8.1 -> 2.0.
  { guest setup1x "src=$onex_guest" && guest relaunch "$A" "$E" label=G &&
    { guest check1x "$A" label=G-1x-to-2.0 || rc=1; guest shot label=G-1x; }
  } || { print -r -- "scenario G stopped"; rc=1 }
  # H. both, with a crash mid keep-aside.
  { guest setup1x "src=$onex_guest" && guest setup "src=/Applications/c11h.app" keep1x=1 && guest quit &&
    { guest crashlaunch "$A" step=keep_1x_mid || rc=1; } &&
    guest relaunch "$A" "$E" label=H &&
    { guest check "$A" label=H-both-after-crash || rc=1; guest checkkept label=H-kept-1x || rc=1; guest shot label=H-both; }
  } || { print -r -- "scenario H stopped"; rc=1 }
  return 0
}

onex_guest=""
if [[ -n "$onex_app" ]]; then
  push_app "$onex_app" || { print -u2 -r -- "could not push $onex_app"; exit 2 }
  onex_guest="/tmp/migw-apps/${onex_app:t}"
fi

rc=0
case "$scenario" in
  convergence)
    run_convergence
    scenario=fetch-only ;;
  batch)
    [[ -n "$onex_guest" && -n "$guest_app" ]] || { print -u2 -r -- "--scenario batch needs --app and --c11-1x"; exit 2 }
    run_batch
    scenario=fetch-only ;;
  baseline1x|1x-to-2.0)
    [[ -n "$onex_guest" ]] || { print -u2 -r -- "--scenario $scenario needs --c11-1x"; exit 2 }
    guest setup1x "src=$onex_guest" || exit 2
    if [[ "$scenario" == baseline1x ]]; then
      guest relaunch app=/Applications/c11.app || exit 2
      guest check1x app=/Applications/c11.app label=baseline-1x-relaunch || rc=1
    else
      guest relaunch "app=$guest_app" "env=$mig_env" $sock_arg || exit 2
      guest check1x "app=$guest_app" label=1x-to-2.0 $sock_arg || rc=1
    fi
    guest shot label=end
    scenario=fetch-only ;;
  both)
    [[ -n "$onex_guest" ]] || { print -u2 -r -- "--scenario both needs --c11-1x"; exit 2 }
    guest setup1x "src=$onex_guest" || exit 2 ;;
esac
if [[ "$scenario" != fetch-only ]]; then
guest setup "src=$c11h_guest" keep1x=$([[ $scenario == both ]] && print 1 || print 0) || exit 2
guest shot label=setup
guest quit || exit 2
case "$scenario" in
  baseline)
    guest relaunch app=/Applications/c11h.app || exit 2
    guest check label=baseline-c11h-relaunch || rc=1 ;;
  h15-to-2.0|twice|back-to-c11h|both)
    guest relaunch "app=$guest_app" "env=$mig_env" $sock_arg || exit 2
    guest check "app=$guest_app" label=first-2.0-launch $sock_arg || rc=1
    guest shot label=first-2.0-launch
    if [[ "$scenario" == twice ]]; then
      guest quit "app=$guest_app" || rc=1
      guest relaunch "app=$guest_app" "env=$mig_env" $sock_arg || exit 2
      guest check "app=$guest_app" label=second-2.0-launch $sock_arg || rc=1
    elif [[ "$scenario" == back-to-c11h ]]; then
      guest quit "app=$guest_app" || rc=1
      guest relaunch app=/Applications/c11h.app || exit 2
      guest check label=back-to-c11h || rc=1
    elif [[ "$scenario" == both ]]; then
      guest checkkept label=kept-1x || rc=1
    fi ;;
  *) print -u2 -r -- "unknown scenario $scenario"; exit 2 ;;
esac
guest shot label=end
fi

exit $rc
