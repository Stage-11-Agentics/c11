#!/bin/bash
# c11 guest helper, HOST SIDE ($G in the acceptance matrix). Runs on the build host; talks to a leased Tart guest over ssh.
#   C11_GUEST=<run-id> [C11_APP=<tagged .app path, host or guest>] tools/c11-guest/g.sh <verb> [args...]
# Verbs are defined in guest.sh (launch launch-env quit kill9-app kill9-core kill9-holder stop-core cont-core procs keys shot cli incli hc hcrecs diag sh aqua-sh env)
# plus host-side: put <local> <guest-path>, get <guest-path> <local>, put-app <host .app> <guest dir> (second build, T3.4/T10), upload-tools, ip.
# `shot <name>` copies the PNG to ${EVIDENCE_DIR:-$HOME/c11h-run/evidence}/${C11_ROW:-adhoc}/<name>.png and prints that host path.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run="${C11_RUN:-${C11_GUEST:-}}"; [[ -n "$run" ]] || { echo "g: set C11_GUEST (or C11_RUN) to the sandbox run id" >&2; exit 3; }
export C11_RUN="$run"
# Proofs are called with the host path of the tagged app (the one given to guest-up); sandbox-up places it at a fixed guest path.
guest_app_for() { echo "/Users/admin/c11-sandbox/apps/$run/$(basename "$1")"; }
if [[ -n "${C11_APP:-}" && "$C11_APP" != /Users/admin/c11-sandbox/* ]]; then C11_APP="$(guest_app_for "$C11_APP")"; fi
verb="${1:?usage: g.sh <verb> [args]}"; shift || true
state="${C11_STATE_DIR:-$HOME/c11h-run/state/ssh}"; mkdir -p "$state"; chmod 700 "$state"
TART="${TART:-/opt/homebrew/bin/tart}"
ipf="$state/$run.ip"
ip=$(cat "$ipf" 2>/dev/null || true)
if [[ "${C11_G_DRY:-}" == 1 ]]; then ip=dry   # test seam (C11H-31): print the guest command instead of running it; no guest needed
elif [[ -z "$ip" ]] || ! nc -z -G 2 "$ip" 22 2>/dev/null; then
  ip=$("$TART" ip "c11-sb-$run" 2>/dev/null | head -1 || true); [[ -n "$ip" ]] || { echo "g: no guest c11-sb-$run (lease one with the guest-up helper)" >&2; exit 3; }
  echo "$ip" > "$ipf"; rm -f "${state:?}/${run:?}.guest-sha"
fi
SSH=(ssh -i "$HOME/.ssh/c11-sandbox" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ControlMaster=auto -o "ControlPath=$state/%C" -o ControlPersist=120 "admin@$ip")
[[ "${C11_G_DRY:-}" == 1 ]] && SSH=(printf '%s\n')
. "$here/rowtag.sh"   # rowtag: the guest-side process-group record for a row reap (C11H-31)
rsh() { "${SSH[@]}" "$(rowtag)/bin/zsh -c $(printf '%q' "$1")"; }
GUEST_FILES=(guest.sh hcrecs.py diagjoin.py)   # guest.sh and the helpers its verbs run (hcrecs, diag); shipped together
push_guest() {
  [[ "${C11_G_DRY:-}" == 1 ]] && return 0       # dry run: print only the verb's own command
  local sha; sha=$(cd "$here" && cat "${GUEST_FILES[@]}" | shasum -a 256 | cut -d' ' -f1)
  [[ "$(cat "$state/$run.guest-sha" 2>/dev/null)" == "$sha" ]] && return 0
  COPYFILE_DISABLE=1 tar -C "$here" -cf - "${GUEST_FILES[@]}" \
    | "${SSH[@]}" 'mkdir -p ~/c11-guest && tar -xf - -C ~/c11-guest && chmod +x ~/c11-guest/guest.sh'
  echo "$sha" > "$state/$run.guest-sha"
}
exports=""
for v in C11_RUN C11_APP C11_APP_B C11_GUEST_TAG C11_SESSION C11_PROOF_SOCKET C11_HC_BIN C11_HC_SOCK C11_HC_ROOT C11_RUN_DIR C11_DIAG_VERB C11_CLI_BARE C11_HC_ALLOW_START C11_APP_GLOB C11_CRUMB C11_SOCKET_GATE C11_INCLI_S; do
  [[ -n "${!v+x}" ]] && exports+="export $v=$(printf '%q' "${!v}"); "
done
case "$verb" in
  ip) echo "$ip" ;;
  put) "${SSH[@]}" "cat > $(printf '%q' "$2")" < "$1" ;;
  get) "${SSH[@]}" "cat $(printf '%q' "$1")" > "$2" ;;
  put-app)  # put-app <host .app> <guest dir>: copy a second build into the guest; prints the guest path of the bundle
    d="$2"; "${SSH[@]}" "mkdir -p $(printf '%q' "$d")"
    COPYFILE_DISABLE=1 tar -C "$(dirname "$1")" -cf - "$(basename "$1")" | "${SSH[@]}" "tar -xf - -C $(printf '%q' "$d")"
    case "$d" in /*) ;; *) d="/Users/admin/$d";; esac
    echo "$d/$(basename "$1")" ;;
  reap-row)  # reap-row <row>: end the guest commands that row started (their process groups, verified by start time); prints "reaped N"
    r=$(printf '%s' "${1:?reap-row <row>}" | tr -c 'A-Za-z0-9._@-' '_')
    "${SSH[@]}" "/bin/zsh -c $(printf '%q' "f=~/c11-guest/rows/$r; n=0; me=\$(ps -o pgid= -p \$\$ | tr -d ' ')
      if [[ -r \$f ]]; then
        while read -r pg st; do
          [[ \$pg == <2-> && \$pg != \$me ]] || continue
          l=\$(ps -o lstart= -p \$pg 2>/dev/null | tr -s ' ' _); [[ -z \$l || \$l == \$st ]] || continue   # leader gone: a live group keeps its id
          kill -TERM -- -\$pg 2>/dev/null && n=\$((n+1))
        done < \$f
        sleep 1
        while read -r pg st; do
          [[ \$pg == <2-> && \$pg != \$me ]] || continue
          l=\$(ps -o lstart= -p \$pg 2>/dev/null | tr -s ' ' _); [[ -z \$l || \$l == \$st ]] && kill -KILL -- -\$pg 2>/dev/null
        done < \$f
        rm -f \$f
      fi
      echo reaped \$n")" ;;
  rows-clear)  # forget every row's recorded groups (session start)
    "${SSH[@]}" 'rm -rf ~/c11-guest/rows; mkdir -p ~/c11-guest/rows; echo rows-cleared' ;;
  upload-tools)  # ship the kit's probes into the guest at ~/c11-guest/tools
    "${SSH[@]}" 'mkdir -p ~/c11-guest/tools'
    COPYFILE_DISABLE=1 tar -C "$here" -cf - --exclude guest.sh --exclude g.sh --exclude hcrecs.py --exclude diagjoin.py --exclude '__pycache__' . | "${SSH[@]}" 'tar -xf - -C ~/c11-guest/tools && chmod +x ~/c11-guest/tools/*.sh ~/c11-guest/tools/*.py 2>/dev/null; echo ~/c11-guest/tools' ;;
  *)
    push_guest
    args=""; for a in "$@"; do args+=" $(printf '%q' "$a")"; done
    if [[ "$verb" == shot ]]; then
      name="${1:?shot <name>}"
      rsh "$exports exec ~/c11-guest/guest.sh shot$args" >/dev/null
      dest="${EVIDENCE_DIR:-$HOME/c11h-run/evidence}/${C11_ROW:-adhoc}"; mkdir -p "$dest"
      "${SSH[@]}" "cat ~/c11-guest/shots/$(printf '%q' "$name").png" > "$dest/$name.png"
      echo "$dest/$name.png"
    else
      rsh "$exports exec ~/c11-guest/guest.sh $(printf '%q' "$verb")$args"
    fi ;;
esac
