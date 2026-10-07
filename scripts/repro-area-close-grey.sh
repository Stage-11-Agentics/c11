#!/usr/bin/env bash
# Repro: closing the lower area of a vertical split leaves the surviving
# area's pre-existing terminals detached from the portal (solid grey area).
# Usage: C11_SOCKET_PATH=/tmp/c11-debug-<tag>.sock scripts/repro-area-close-grey.sh <c11-cli>
# Prints one line per terminal in the surviving area and exits 1 if any
# selected terminal is not visible in the UI.
set -euo pipefail
CLI="${1:-c11}"
export C11_SOCKET_PATH="${C11_SOCKET_PATH:?set C11_SOCKET_PATH to the tagged build socket}"

top_panel="$("$CLI" tree --json | python3 -c 'import json,sys
d=json.load(sys.stdin)
def walk(o):
    if isinstance(o,dict):
        if o.get("type")=="terminal" and o.get("ref","").startswith("panel:"): print(o["ref"]); sys.exit()
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(d)')"
echo "top panel: $top_panel"
"$CLI" new-panel --type terminal >/dev/null
"$CLI" new-panel --type terminal >/dev/null
split_out="$("$CLI" new-split down --panel "$top_panel")"
echo "split: $split_out"
bottom_panel="$(grep -oE 'panel:[0-9]+' <<<"$split_out" | tail -1)"
sleep 2
echo "closing bottom panel: $bottom_panel"
"$CLI" tree --no-layout
"$CLI" close-panel --panel "$bottom_panel" >/dev/null
sleep 2
# The operator then dragged a column divider; resize the surviving area.
top_area="$("$CLI" tree --no-layout | awk -v p="$top_panel" '/area:/{a=$2} $2==p{print a; exit}')"
"$CLI" resize-pane --pane "$top_area" -R --amount 80 >/dev/null
sleep 2
"$CLI" rpc debug.terminals '{}' | python3 -c 'import json,sys
d=json.load(sys.stdin); items=d.get("result",d); items=items.get("terminals",items) if isinstance(items,dict) else items
bad=0
for t in items:
    print(t["panel_ref"], "selected=%s" % t["panel_selected_in_area"], "visible=%s" % t["hosted_view_visible_in_ui"],
          "host=%s" % (t["portal_host_id"] is not None), "superview=%s" % t["hosted_view_has_superview"],
          "frame=%s" % t["hosted_view_frame_in_window"])
    if t["panel_selected_in_area"] and (not t["hosted_view_visible_in_ui"] or t["portal_host_id"] is None): bad=1
print("RESULT", "GREY" if bad else "OK")
sys.exit(bad)'
