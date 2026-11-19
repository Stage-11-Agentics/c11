# Sourced by g.sh and tools/c11h-proofs/lib-b.sh (host side). C11H-31: every guest command a row runs is tagged.
# sshd makes each command its own session, so the remote shell's process group id plus that leader's start time is
# appended to ~/c11-guest/rows/<row> in the guest; `g.sh reap-row <row>` ends only those groups (start time checked),
# inside the guest. The app starts through launchd and is never in one. Prints nothing outside a row (C11_ROW unset).
rowtag() {
  [[ -n "${C11_ROW:-}" ]] || return 0
  local r; r=$(printf '%s' "$C11_ROW" | tr -c 'A-Za-z0-9._@-' '_')
  printf '%s' "mkdir -p ~/c11-guest/rows && { p=\$(ps -o pgid= -p \$\$ | tr -d ' '); echo \"\$p \$(ps -o lstart= -p \$p | tr -s ' ' _)\" >> ~/c11-guest/rows/$r; } 2>/dev/null; "
}
