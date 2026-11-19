#!/bin/zsh
# snap.sh <out>: manifest of c11's footprint for before/after diffs (acceptance matrix, T1 and T10).
# Read-only. "Unchanged" means `diff before after` prints nothing.
set -u
out="${1:?usage: snap.sh <out>}"
{
  echo "## paths"
  for p in "$HOME/Library/Application Support/c11" "$HOME/Library/Application Support/c11mux" \
           "$HOME/Library/Application Support/cmux" "$HOME/.claude/skills" "$HOME/.codex/skills" \
           "$HOME/.pi/agent/skills" /tmp/c11-last-socket-path /tmp/cmux-last-socket-path; do
    if [[ -L "$p" ]]; then echo "link $p -> $(readlink "$p")"
    elif [[ -d "$p" ]]; then
      find "$p" \( -type f -o -type l \) 2>/dev/null | LC_ALL=C sort | while read -r f; do
        case "$f" in */c11*|*/.DS_Store) continue;; esac
        # a LIVE c11 writes these itself (event log, dispatch log, journal, crash sentinels): c11's own activity, never c11's
        case "$f" in */c11/events/*|*/c11/journal/*|*/_dispatch.log|*/c11/logs/*|*/c11/mailbox/*|*/c11/sessions/*|*/c11/session-*.json|*/c11/launch-sentinel*|*/c11/health*|*/c11/*.lock) continue;; esac
        if [[ -L "$f" ]]; then echo "link $f -> $(readlink "$f")"
        else echo "file $(shasum -a 256 "$f" | cut -d' ' -f1) $f"; fi
      done
    elif [[ -e "$p" ]]; then echo "file $(shasum -a 256 "$p" | cut -d' ' -f1) $p"
    else echo "absent $p"; fi
  done
  echo "## defaults"
  for d in com.stage11.c11 com.stage11.c11mux com.cmuxterm.app; do
    echo "$d $(defaults export "$d" - 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
  done
  echo "## listeners"
  lsof -nP -U 2>/dev/null | awk '/c11|cmux/ && !/c11/ {print $1, $2, $NF}' | LC_ALL=C sort -u
  echo "## processes"
  pgrep -lf 'c11.app|herdr-core' 2>/dev/null | grep -v c11 | LC_ALL=C sort
} > "$out"
echo "wrote $out ($(wc -l < "$out") lines)"
