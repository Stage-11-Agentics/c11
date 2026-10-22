#!/usr/bin/env bash
# Stage only an executable and synthetic provider in an existing sandbox guest.
# No account configuration or credentials are copied.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sandbox-common.sh"
[[ $# == 1 ]] || sandbox_die "Usage: stage-opencode-mail-proof.sh RUN_ID"
run_id="$1"
sandbox_validate_run_id "$run_id"
provider="$(base64 < "$SCRIPT_DIR/fixtures/opencode-mail-provider.py" | tr -d '\n')"
observer="$(base64 < "$SCRIPT_DIR/fixtures/opencode-mail-observer.mjs" | tr -d '\n')"
sandbox_on_host <<EOF
set -eu
setopt pipefail
$(sandbox_host_prelude)
load_meta $(printf '%q' "$run_id")
ip="\$(guest_ip "\$VM")"
binary="\$HOME/.opencode/bin/opencode"
[[ -x "\$binary" ]] || die "OpenCode is not installed at \$binary on the sandbox host"
fixture=/tmp/c11-opencode-proof-$(printf '%q' "$run_id")
guest_ssh_run "\$ip" "mkdir -p '\$fixture/real-bin' '\$fixture/home' '\$fixture/project'" </dev/null
cat "\$binary" | guest_ssh_run "\$ip" "cat > '\$fixture/real-bin/opencode'; chmod 755 '\$fixture/real-bin/opencode'"
{
  printf 'fixture=%q\n' "\$fixture"
  cat <<'GUEST'
set -eu
print -r -- '${provider}' | /usr/bin/base64 -D > "\$fixture/provider.py"
print -r -- '${observer}' | /usr/bin/base64 -D > "\$fixture/observer.mjs"
nohup /usr/bin/python3 "\$fixture/provider.py" "\$fixture" >"\$fixture/provider.log" 2>&1 </dev/null &
echo \$! > "\$fixture/provider.pid"
GUEST
} | guest_ssh "\$ip"
echo "staged=\$fixture credentials=none"
EOF
