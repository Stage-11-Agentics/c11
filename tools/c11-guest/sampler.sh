#!/bin/zsh
# sampler.sh <tag> [interval]: core / holder / app RSS+CPU every interval s (default 2) appended to ~/c11-guest/rss-<tag>.txt until killed. INSIDE the guest.
G="$HOME/c11-guest/guest.sh"; tag="${1:?tag}"; iv="${2:-2}"
while :; do
  core=$($G procs 2>/dev/null | awk '/ serve/ && !/awk/ {print $1; exit}'); hold=$($G procs 2>/dev/null | awk '/ hold/ && !/awk/ {print $1; exit}')
  app=$($G procs 2>/dev/null | awk '/MacOS\// && !/awk/ {print $1; exit}')
  echo "$(date +%T) core_rss_kb=$(ps -o rss= -p ${core:-0} | tr -d ' ') core_cpu=$(ps -o %cpu= -p ${core:-0} | tr -d ' ') hold_rss_kb=$(ps -o rss= -p ${hold:-0} | tr -d ' ') app_rss_kb=$(ps -o rss= -p ${app:-0} | tr -d ' ') app_cpu=$(ps -o %cpu= -p ${app:-0} | tr -d ' ')"
  sleep $iv
done >> "$HOME/c11-guest/rss-$tag.txt"
