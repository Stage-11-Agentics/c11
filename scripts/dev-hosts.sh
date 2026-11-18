# shellcheck shell=bash
# The operator's dev hosts, for scripts that reach another machine. No host lives in the tree.
#
#   source scripts/dev-hosts.sh
#   host="$(c11_dev_host C11_REMOTE_HOST --host)" || exit 2
#
# c11_dev_host KEY [FLAG] prints the environment variable KEY when it is set, else the last
# KEY=value line of ${C11_DEV_HOSTS:-~/.config/c11/dev-hosts} (plain KEY=value lines, # comments;
# the file is parsed, never sourced). Unset everywhere, it prints one line naming KEY and returns 2.
# A script's own FLAG (--host) wins over both; the caller checks it first.

c11_dev_host() {
  local key="$1" flag="${2:-}" file="${C11_DEV_HOSTS:-$HOME/.config/c11/dev-hosts}" line value="" hint
  if [[ -n "${!key:-}" ]]; then
    printf '%s\n' "${!key}"
    return 0
  fi
  if [[ -f "$file" && -r "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] || continue
      line="${BASH_REMATCH[1]}"
      [[ -z "$line" ]] || value="$line"
    done <"$file"
  fi
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  case "$key" in *_HOST) hint="<ssh host>" ;; *) hint="<value>" ;; esac
  printf '%s is unset: %sexport it, or add %s=%s to %s\n' "$key" "${flag:+pass $flag, }" "$key" "$hint" \
    "${C11_DEV_HOSTS:-~/.config/c11/dev-hosts}" >&2
  return 2
}
