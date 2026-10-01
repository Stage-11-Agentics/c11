#!/usr/bin/env bash
# Run tests_v2 inside an already-up sandbox guest. Never touches the operator's c11.
# Usage: scripts/sandbox-tests-v2.sh <run-id> [tests_v2/test_file.py ...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=sandbox-common.sh
source "$SCRIPT_DIR/sandbox-common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/sandbox-tests-v2.sh <run-id> [tests_v2/test_file.py ...]

Requires scripts/sandbox-up.sh to have launched the guest app. Copies tests_v2
(and tests/fixtures when present) into that guest and runs the python3 scripts
against the guest socket. With no file arguments, runs every tests_v2/test_*.py
except test_ctrl_interactive.py. This suite is not pytest: flags such as -k or
--tb are rejected. The guest relaunches its c11 once before each test. Results
stream here and are left on the Tart host at .c11-sandbox/out/<run-id>/tests-v2.log.
EOF
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || { usage; exit 0; }
[[ $# -ge 1 ]] || { usage >&2; exit 1; }
run_id="$1"
shift
sandbox_validate_run_id "$run_id"
[[ -d "$REPO_ROOT/tests_v2" ]] || sandbox_die "tests_v2 is missing under $REPO_ROOT"

files=()
if [[ $# -eq 0 ]]; then
  for path in "$REPO_ROOT"/tests_v2/test_*.py; do
    [[ -f "$path" ]] || continue
    base="$(basename "$path")"
    [[ "$base" == "test_ctrl_interactive.py" ]] && continue
    files+=("tests_v2/$base")
  done
  [[ ${#files[@]} -gt 0 ]] || sandbox_die "no tests_v2/test_*.py files found"
else
  for arg in "$@"; do
    case "$arg" in
      -*)
        sandbox_die "tests_v2 is a set of python3 scripts, not pytest. Pass paths like tests_v2/test_tree.py ($arg)."
        ;;
    esac
    case "$arg" in
      tests_v2/*.py) rel="$arg" ;;
      *.py) rel="tests_v2/$(basename "$arg")" ;;
      *) sandbox_die "expected a tests_v2 python file, got: $arg" ;;
    esac
    [[ -f "$REPO_ROOT/$rel" ]] || sandbox_die "test file not found: $REPO_ROOT/$rel"
    files+=("$rel")
  done
fi

copy_paths=(tests_v2)
[[ -d "$REPO_ROOT/tests/fixtures" ]] && copy_paths+=(tests/fixtures)
rel_out=".c11-sandbox/out/${run_id}/suite-src"
ssh_host="$(sandbox_host_name)"
if [[ "$ssh_host" != "local" ]]; then
  ssh -o BatchMode=yes -o ConnectTimeout=25 -o LogLevel=ERROR "$ssh_host" \
    "rm -rf \"\$HOME/${rel_out}\" && mkdir -p \"\$HOME/${rel_out}\""
else
  rm -rf "${HOME:?}/${rel_out}"
  mkdir -p "${HOME}/${rel_out}"
fi
COPYFILE_DISABLE=1 tar -C "$REPO_ROOT" -cf - "${copy_paths[@]}" | sandbox_extract_tar "$rel_out"

files_b64="$(printf '%s\0' "${files[@]}" | base64 | tr -d '\n')"

set +e
sandbox_guest_script "$run_id" <<EOF
set -eu
setopt pipefail
$(sandbox_guest_runtime_zsh)
export SANDBOX_FILES_B64='${files_b64}'
share="/Volumes/My Shared Files/out/suite-src"
[[ -d "\$share/tests_v2" ]] || { print -u2 -- "suite was not visible in the guest at \$share"; exit 1 }
dest="\$HOME/c11-sandbox/suite"
rm -rf "\$dest"
mkdir -p "\$dest"
/usr/bin/ditto "\$share/tests_v2" "\$dest/tests_v2"
if [[ -d "\$share/tests/fixtures" ]]; then
  mkdir -p "\$dest/tests"
  /usr/bin/ditto "\$share/tests/fixtures" "\$dest/tests/fixtures"
fi
meta_socket="\$SANDBOX_SOCKET"
meta_cli="\$SANDBOX_CLI"
meta_app="\$SANDBOX_GUEST_APP"
meta_log="\$SANDBOX_LOG"
meta_stdout="\$SANDBOX_STDOUT"
meta_dsock="\$SANDBOX_DSOCK"
log="/Volumes/My Shared Files/out/tests-v2.log"
: > "\$log"
cd "\$dest"
[[ -n "\${SANDBOX_SOCKET:-}" && -n "\${SANDBOX_GUEST_APP:-}" ]] || { print -u2 -- "run metadata has no guest app or socket. Run sandbox-up.sh first."; exit 1 }
fail=0
file_list="\$(/usr/bin/python3 -c 'import os,base64,sys; raw=base64.b64decode(os.environ["SANDBOX_FILES_B64"]); sys.stdout.write("\\n".join(p.decode() for p in raw.split(b"\\0") if p))')"
while IFS= read -r rel; do
  [[ -n "\$rel" ]] || continue
  print -r -- "== launch \$rel =="
  sandbox_quit_app
  sandbox_launch_app "\$meta_app" "\$meta_socket" "\$meta_log" "\$meta_stdout" "\$meta_dsock"
  print -r -- "RUN  \$rel"
  set +e
  C11_SOCKET="\$meta_socket" \
    C11_SOCKET_PATH="\$meta_socket" \
    CMUX_SOCKET="\$meta_socket" \
    CMUX_SOCKET_PATH="\$meta_socket" \
    C11_CLI="\$meta_cli" \
    CMUXTERM_CLI="\$meta_cli" \
    /usr/bin/python3 "\$rel" 2>&1 | /usr/bin/tee -a "\$log"
  rc=\${pipestatus[1]}
  set -e
  if (( rc != 0 )); then
    print -u2 -- "FAIL \$rel"
    fail=1
    break
  fi
done <<< "\$file_list"
exit "\$fail"
EOF
status=$?
set -e

local_log="${TMPDIR:-/tmp}/c11-sandbox-${run_id}-tests-v2.log"
if sandbox_fetch ".c11-sandbox/out/${run_id}/tests-v2.log" "$local_log" 2>/dev/null; then
  printf 'log=%s\n' "$local_log"
fi
exit "$status"
