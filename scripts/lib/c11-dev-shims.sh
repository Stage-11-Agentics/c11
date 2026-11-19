#!/usr/bin/env bash
# c11 development CLI links. These names are c11's. A reload must not
# replace a c11 or cmux shim, or a c11-cli link another user owns.
if ! declare -F c11_user_runtime_dir >/dev/null 2>&1; then
  # shellcheck source=c11-user-paths.sh
  source "$(dirname "${BASH_SOURCE[0]}")/c11-user-paths.sh"
fi

write_c11_dev_cli_shim() {
  local target="$1"
  local fallback_bin="$2"
  local path_file="${C11_DEV_CLI_PATH_FILE:-$(c11_user_runtime_dir)/c11-last-cli-path}"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<EOF
#!/usr/bin/env bash
# c11 dev shim (managed by scripts/reload.sh)
set -euo pipefail

CLI_PATH_FILE="$path_file"
CLI_PATH_OWNER="\$(stat -c '%u' "\$CLI_PATH_FILE" 2>/dev/null || /usr/bin/stat -f '%u' "\$CLI_PATH_FILE" 2>/dev/null || echo -1)"
if [[ -r "\$CLI_PATH_FILE" ]] && [[ ! -L "\$CLI_PATH_FILE" ]] && [[ "\$CLI_PATH_OWNER" == "\$(id -u)" ]]; then
  CLI_PATH="\$(cat "\$CLI_PATH_FILE")"
  if [[ -x "\$CLI_PATH" ]]; then
    exec "\$CLI_PATH" "\$@"
  fi
fi

if [[ -x "$fallback_bin" ]]; then
  exec "$fallback_bin" "\$@"
fi

echo "error: no reload-selected dev c11 CLI found. Run ./scripts/reload.sh --tag <name> first." >&2
exit 1
EOF
  chmod +x "$target"
}

# Link the just-built CLI as c11-cli and install ~/.local/bin/c11-dev.
# The bundled binary inside c11.app stays named c11. Pre-existing c11 and
# cmux shims in the same directories are not opened for write.
install_c11_dev_cli_links() {
  local cli_path="$1"
  local link_dir="${C11_DEV_LINK_DIR:-$(c11_user_runtime_dir)}"
  local shim_dir="${C11_DEV_SHIM_DIR:-${HOME}/.local/bin}"
  local path_file="${C11_DEV_CLI_PATH_FILE:-$(c11_user_runtime_dir)/c11-last-cli-path}"
  (umask 077; mkdir -p "$(dirname "$path_file")") || true
  # No-follow, owner-checked writes (C11H-364 L21): a link or a name another
  # account planted is never written through.
  c11_private_write "$path_file" "$cli_path" || true
  c11_private_symlink "$cli_path" "$link_dir/c11-cli" || true
  # The old /tmp/c11-cli, kept current only while it is this user's link.
  if [[ -z "${C11_DEV_LINK_DIR:-}" ]]; then
    c11_private_symlink "$cli_path" /tmp/c11-cli || true
  fi
  write_c11_dev_cli_shim "$shim_dir/c11-dev" "/Applications/c11.app/Contents/Resources/bin/c11"
}
