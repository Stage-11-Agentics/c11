#!/usr/bin/env bash
# Behavioral coverage for the process-scoped Atlas CI helpers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/c11-ci-atlas-tools.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# A runner-provided Zig install is selected without a network or system write.
mkdir -p "$TMP_DIR/zig"
cat > "$TMP_DIR/zig/zig" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == version ]] || exit 2
echo 0.15.2
EOF
chmod +x "$TMP_DIR/zig/zig"
selected="$(C11_ZIG_DIR="$TMP_DIR/zig" PATH="/usr/bin:/bin" "$ROOT_DIR/scripts/ensure-zig.sh")"
[[ "$selected" == "$TMP_DIR/zig" ]] || fail "ensure-zig selected '$selected'"

# The Atlas wrapper reaches the command with a slot and the nested build lock,
# and releases the lock on completion.
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s:%s\n' "${C11_ATLAS_BUILD_SLOT:-}" "${C11_ATLAS_LOCK_OWNER:-}" > "${PROBE_OUTPUT:?}"
EOF
chmod +x "$TMP_DIR/bin/probe"
printf '0\n' > "$TMP_DIR/load"
PROBE_OUTPUT="$TMP_DIR/probe" \
  C11_ATLAS_BUILD_SLUG=fixture \
  C11_ATLAS_SLOTS_DIR="$TMP_DIR/slots" \
  C11_ATLAS_LOAD_FILE="$TMP_DIR/load" \
  PATH="$TMP_DIR/bin:$PATH" \
  "$ROOT_DIR/scripts/ci-atlas-run.sh" probe

IFS=: read -r slot owner < "$TMP_DIR/probe"
[[ "$slot" =~ ^[12]$ ]] || fail "wrapper did not acquire slot: $slot"
[[ "$owner" =~ ^[0-9]+$ ]] || fail "wrapper did not acquire nested lock: $owner"
[[ ! -d "$TMP_DIR/slots/build-$slot" ]] || fail "nested build lock leaked"

set +e
C11_ATLAS_BUILD_SLUG=fixture \
  C11_ATLAS_SLOTS_DIR="$TMP_DIR/slots" \
  C11_ATLAS_LOAD_FILE="$TMP_DIR/load" \
  "$ROOT_DIR/scripts/ci-atlas-run.sh" bash -c 'exit 9'
rc=$?
set -e
[[ "$rc" -eq 9 ]] || fail "wrapper changed command exit status to $rc"

echo "PASS: Atlas wrapper admits commands and keeps Zig/build state process-scoped"
