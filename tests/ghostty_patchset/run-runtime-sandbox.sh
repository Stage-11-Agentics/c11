#!/bin/bash
# Existing sandbox guest, or explicitly authorized local tagged app. No launch.
set -euo pipefail
if [[ "${1:-}" == --local-tagged ]]; then
  if [[ $# -lt 8 ]]; then
    echo "usage: $0 --local-tagged <tag> <socket> <app> <cli> <baseline|candidate> <full-ghostty-sha> </tmp/new-output-dir> [--comparison-only] [--ui-driver PATH --ui-window ID] [--streams N --samples N --sample-pause SECONDS --min-sample-seconds SECONDS --measure-switches]" >&2
    exit 2
  fi
  shift
  fixture_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
  /usr/bin/python3 - "$fixture_dir/runtime-fixture.py" "$@" <<'PYLOCAL'
import argparse, os, pathlib, signal, subprocess, sys
values = sys.argv[1:]
script, tag, sock, app, cli, label, sha, out = values[:8]
optional = argparse.ArgumentParser()
optional.add_argument('--comparison-only', action='store_true')
optional.add_argument('--ui-driver')
optional.add_argument('--ui-window', type=int)
optional.add_argument('--streams', type=int, default=30)
optional.add_argument('--samples', type=int, default=100)
optional.add_argument('--sample-pause', type=float, default=.05)
optional.add_argument('--min-sample-seconds', type=float, default=0)
optional.add_argument('--measure-switches', action='store_true')
options = optional.parse_args(values[8:])
if bool(options.ui_driver) != bool(options.ui_window):
    sys.exit('--ui-driver and --ui-window must be supplied together')
if tag not in ('c11-294-base', 'c11-294-ghostty') or pathlib.Path('/tmp').resolve() not in pathlib.Path(out).resolve().parents:
    sys.exit('Local fixture requires an authorized C11-294 tag and output below /tmp')
pathlib.Path(out).parent.mkdir(parents=True, exist_ok=True)
args = [sys.executable, script, 'run', '--local-tagged', '--tag', tag,
        '--label', label, '--engine-sha', sha, '--socket', sock,
        '--cli', cli, '--app', app, '--out', out,
        '--streams', str(options.streams), '--samples', str(options.samples),
        '--sample-pause', str(options.sample_pause), '--min-sample-seconds', str(options.min_sample_seconds)]
if options.measure_switches:
    args.append('--measure-switches')
if options.comparison_only:
    args.append('--comparison-only')
if options.ui_driver:
    args.extend(['--ui-driver', options.ui_driver, '--ui-window', str(options.ui_window)])
with open(out + '.log', 'xb') as target:
    child = subprocess.Popen(args, stdout=target, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        code = child.wait(timeout=360)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()
        target.write(b'FAIL: external 360-second watchdog; inspect ONLY the named tagged app and fixture PIDs\n')
        code = 124
print(open(out + '.log').read())
sys.exit(code if code >= 0 else 128 - code)
PYLOCAL
  exit $?
fi
if [[ $# -lt 4 ]]; then
  echo "usage: $0 <sandbox-run-id> <tag> <baseline|candidate> <full-ghostty-sha> [--full-scenarios | --comparison-only] [--ui-driver GUEST_PATH --ui-window ID] [--streams N --samples N --sample-pause SECONDS --min-sample-seconds SECONDS --measure-switches]" >&2
  exit 2
fi
run_id="$1"
tag="$2"
label="$3"
engine_sha="$4"
shift 4
# Transfer structured arguments through the guest shell without interpolation.
options_b64="$(/usr/bin/python3 - "$@" <<'PYOPTIONS'
import argparse, base64, json, sys
parser = argparse.ArgumentParser()
scenario = parser.add_mutually_exclusive_group()
scenario.add_argument('--full-scenarios', action='store_true')
scenario.add_argument('--comparison-only', action='store_true')
parser.add_argument('--ui-driver')
parser.add_argument('--ui-window', type=int)
parser.add_argument('--streams', type=int, default=30)
parser.add_argument('--samples', type=int, default=100)
parser.add_argument('--sample-pause', type=float, default=.05)
parser.add_argument('--min-sample-seconds', type=float, default=0)
parser.add_argument('--measure-switches', action='store_true')
options = parser.parse_args()
if bool(options.ui_driver) != bool(options.ui_window):
    parser.error('--ui-driver and --ui-window must be supplied together')
print(base64.b64encode(json.dumps(vars(options)).encode()).decode())
PYOPTIONS
)"
[[ "$tag" =~ ^[a-z0-9][a-z0-9.-]*$ && "$engine_sha" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$label" == baseline || "$label" == candidate ]] || exit 2
fixture_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$fixture_dir/../.." && pwd)"
source "$repo_dir/scripts/sandbox-common.sh"
sandbox_validate_run_id "$run_id"
fixture_b64="$(base64 < "$fixture_dir/runtime-fixture.py" | tr -d '\n')"
sandbox_guest_script "$run_id" <<EOF
set -eu
setopt pipefail
export C11_FIXTURE_B64='$fixture_b64'
dest="\$HOME/c11-sandbox/ghostty-fixtures/\$SANDBOX_RUN_ID"
mkdir -p "\$dest"
/usr/bin/python3 -c 'import base64,os,sys; open(sys.argv[1], "wb").write(base64.b64decode(os.environ["C11_FIXTURE_B64"]))' "\$dest/runtime-fixture.py"
unset C11_FIXTURE_B64
# Controller and terminal workers run on the same guest monotonic clock.
# Hard external deadline: children independently expire after <=180 seconds.
# Enter the guest's Aqua audit session, then drop root before running the
# controller and its PID-scoped CGEvent helper (the sandbox-exec.sh pattern).
# Pass sandbox metadata as explicit arguments; do not inherit C11/CMUX state.
fixture_uid="\$(id -u)"
fixture_user="\$(id -un)"
/usr/bin/sudo -n /bin/launchctl asuser "\$fixture_uid" \
  /usr/bin/sudo -n -u "\$fixture_user" /usr/bin/env -i \
  HOME="\$HOME" USER="\$fixture_user" LOGNAME="\$fixture_user" \
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  TMPDIR="\${TMPDIR:-/tmp}" \
  /usr/bin/python3 - "\$dest/runtime-fixture.py" "\$SANDBOX_RUN_ID" "\$SANDBOX_SOCKET" "\$SANDBOX_CLI" "\$SANDBOX_GUEST_APP" <<'PY'
import base64, json, os, signal, subprocess, sys
script, run_id, sock, cli, app = sys.argv[1:]
out = '/Volumes/My Shared Files/out/ghostty-runtime-$label'
log = '/Volumes/My Shared Files/out/ghostty-runtime-$label.log'
args = [sys.executable, script, 'run', '--run-id', run_id, '--tag', '$tag',
        '--label', '$label', '--engine-sha', '$engine_sha', '--socket', sock,
        '--cli', cli, '--app', app, '--out', out]
options = json.loads(base64.b64decode('$options_b64'))
for name in ('streams', 'samples', 'sample_pause', 'min_sample_seconds'):
    args.extend(['--' + name.replace('_', '-'), str(options[name])])
if options['measure_switches']:
    args.append('--measure-switches')
if options['ui_driver']:
    args.extend(['--ui-driver', options['ui_driver'], '--ui-window', str(options['ui_window'])])
if options['comparison_only'] or ('$label' == 'baseline' and not options['full_scenarios']):
    args.append('--comparison-only')
with open(log, 'wb') as target:
    child = subprocess.Popen(args, stdout=target, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        code = child.wait(timeout=360)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()
        target.write(b'FAIL: external 360-second watchdog; guest disposal required\n')
        code = 124
print(open(log).read())
sys.exit(code if code >= 0 else 128 - code)
PY
EOF
