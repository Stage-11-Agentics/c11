#!/usr/bin/env bash
# C11H-130: the blocking gate around scripts/check-shareable.py, shared by remote-build.sh and
# .githooks/pre-push. main stays shareable with a friend (C11.md, 2026-11-02); Atin made the
# guard blocking on 2026-11-03.
#
#   scripts/shareable-gate.sh <context> [<repo root>]
#
# C11H-337: the gate also runs scripts/check-public-tree.py --strict --allow-pending, the bar c11 2.0's
# public tree must meet (client and people names, the operator's machines, emails, secrets by
# token shape), beside check-shareable and at the same time, so it adds about no wall time. It
# reads the private terms from a c11-ops checkout beside this repo (or C11_PUBLIC_TREE_TERMS) and
# says so on every run where it found none. gitleaks is left to the public push: over the whole
# tree it takes about ten seconds.
#
# Exit 0 when both checks are clean, or when C11_SHAREABLE_OVERRIDE gives a reason (at least 12
# characters) why its findings are a known false alarm. Every override is printed and appended
# to the override log (C11_SHAREABLE_LOG, default ~/.local/state/c11/shareable-overrides.log)
# with the time, the context, the head commit, the reason and the findings it let through; an
# override that can't be logged does not proceed. Exit 1 otherwise, including when either check is
# missing or can't run. The lasting fix for a false alarm is a reasoned line in
# scripts/shareable-allowlist.txt or scripts/public-tree-allowlist.txt; CI takes no override.
#
# The check reads the working tree, so pre-push judges what is checked out, not the pushed
# commit; the c11-shareable workflow checks the pushed commit itself.
set -uo pipefail

context="${1:?usage: shareable-gate.sh <context> [<repo root>]}"
root="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
check="$root/scripts/check-shareable.py"
public="$root/scripts/check-public-tree.py"
MIN_REASON=12

# The strict public-tree check runs in the background while check-shareable runs.
pub_out="$(mktemp "${TMPDIR:-/tmp}/c11-public-tree.XXXXXX")" || { echo "[$context] could not make a temp file. Blocked." >&2; exit 1; }
trap '/bin/rm -f "$pub_out"' EXIT
pub_pid=""
if [[ -f "$public" ]]; then
  python3 "$public" --root "$root" --strict --allow-pending --no-gitleaks >"$pub_out" 2>&1 &
  pub_pid=$!
fi

rc=0
if [[ -f "$check" ]]; then
  out="$(python3 "$check" --root "$root" 2>&1)" || rc=$?
else
  out="check-shareable: $check is missing"
  rc=3
fi

prc=0
if [[ -n "$pub_pid" ]]; then
  wait "$pub_pid" || prc=$?
  pout="$(cat "$pub_out")"
else
  pout="check-public-tree: $public is missing"
  prc=3
fi

if grep -q 'no private terms file' <<<"$pout"; then
  echo "[$context] check-public-tree found no private terms (no c11-ops/public-tree-terms.txt beside this repo, no C11_PUBLIC_TREE_TERMS): client and people names were NOT checked." >&2
fi
[[ "$rc" -eq 0 && "$prc" -eq 0 ]] && exit 0

describe() {  # <check name> <exit code> <what its findings are>
  case "$2" in
    0) ;;
    1) printf '%s found %s' "$1" "$3" ;;
    3) printf '%s is missing, so nothing was verified' "$1" ;;
    *) printf '%s failed to run (exit %s), so nothing was verified' "$1" "$2" ;;
  esac
}
what="" failed=""
if [[ "$rc" -ne 0 ]]; then
  what="$(describe check-shareable "$rc" "friend-share blockers")"
  failed="$out"
fi
if [[ "$prc" -ne 0 ]]; then
  pout="$(grep -v -E 'pending \(allowed by --allow-pending\)' <<<"$pout")"
  what="${what:+$what; }$(describe check-public-tree "$prc" "public-tree blockers")"
  failed="${failed:+$failed
}$pout"
fi
printf '%s\n' "$failed" >&2
out="$failed"

# One line, printable characters only.
# The retired line's names still work, only when the current name is unset (C11H-265):
# a current name that is set, even empty, wins.
[[ -n "${C11_SHAREABLE_OVERRIDE+set}" ]] || C11_SHAREABLE_OVERRIDE="${C11H_SHAREABLE_OVERRIDE:-}" # c11-2.0:legacy
if [[ -z "${C11_SHAREABLE_LOG+set}" && -n "${C11H_SHAREABLE_LOG:-}" ]]; then C11_SHAREABLE_LOG="$C11H_SHAREABLE_LOG"; fi # c11-2.0:legacy
reason="$(printf '%s' "${C11_SHAREABLE_OVERRIDE:-}" | LC_ALL=C tr -c '[:print:]' ' ' | sed 's/^ *//; s/ *$//')"
if [[ ${#reason} -lt $MIN_REASON ]]; then
  {
    echo "[$context] $what. Blocked."
    echo "  Fix them, or add a reasoned whole-line entry to scripts/shareable-allowlist.txt (check-shareable)"
    echo "  or scripts/public-tree-allowlist.txt (check-public-tree)."
    echo "  For a known false alarm only: C11_SHAREABLE_OVERRIDE='<why, at least $MIN_REASON characters>' (logged)."
  } >&2
  exit 1
fi

log="${C11_SHAREABLE_LOG:-${HOME:?HOME is unset; set C11_SHAREABLE_LOG}/.local/state/c11/shareable-overrides.log}"
head="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
stamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
findings="$(printf '%s\n' "$out" | grep -v -E '^$|finding\(s\)[.,]|^check-(shareable|public-tree): (ok|by kind|no private terms|gitleaks)|pending \(allowed' | head -3 \
  | sed -E 's/^check-(shareable|public-tree): //' | LC_ALL=C tr -c '[:print:]\n' ' ' | paste -sd ';' -)"
line="$stamp context=$context head=$head check=$what reason=$reason findings=$findings"
if ! { mkdir -p "$(dirname "$log")" && printf '%s\n' "$line" >> "$log"; } 2>/dev/null; then
  echo "[$context] $what. Override NOT logged (could not write $log), so it does not proceed. Blocked." >&2
  exit 1
fi
echo "[$context] $what. OVERRIDDEN: $reason (logged to $log)" >&2
exit 0
