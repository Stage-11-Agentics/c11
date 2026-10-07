#!/usr/bin/env bash
# Repro: closing the lower area of a vertical split leaves the surviving
# area's pre-existing terminals detached from the portal (solid grey area).
# Usage: C11_SOCKET_PATH=/tmp/c11-debug-<tag>.sock scripts/repro-area-close-grey.sh <c11-cli>
# Needs a tagged build launched with --qa fresh: its default layout has the
# first terminal in a left column, so the divider resize step has a border.
# Checks after the close and again after a divider resize; prints one line
# per terminal and exits 1 if a selected terminal is unhosted or hidden.
set -euo pipefail
CLI="${1:-c11}"
unset C11_SOCKET
SOCK="${C11_SOCKET_PATH:?set C11_SOCKET_PATH to the tagged build socket}"
case "$SOCK" in
  /tmp/c11-debug-*.sock) ;;
  *) echo "refusing non-tagged socket $SOCK" >&2; exit 2 ;;
esac

ref_json() { "$CLI" tree --json | python3 -c "$1"; }
top_panel="$(ref_json 'import json,sys
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
bottom_panel="$(grep -oE 'panel:[0-9]+' <<<"$split_out" | tail -1)"
sleep 2
top_area="$(ref_json "import json,sys
d=json.load(sys.stdin)
def walk(o, area=None):
    if isinstance(o,dict):
        r=o.get('ref','')
        if r.startswith('area:'): area=r
        if r=='$top_panel': print(area); sys.exit()
        for v in o.values(): walk(v, area)
    elif isinstance(o,list):
        for v in o: walk(v, area)
walk(d)")"
echo "closing bottom panel $bottom_panel; surviving area $top_area"

check() {
  "$CLI" rpc debug.terminals '{}' | python3 -c 'import json,sys
label=sys.argv[1]
d=json.load(sys.stdin); items=d.get("result",d); items=items.get("terminals",items) if isinstance(items,dict) else items
bad=0
for t in items:
    if t["area_ref"]!=sys.argv[2]: continue
    print(label, t["panel_ref"], "selected=%s" % t["panel_selected_in_area"], "visible=%s" % t["hosted_view_visible_in_ui"],
          "host=%s" % (t["portal_host_id"] is not None), "superview=%s" % t["hosted_view_has_superview"],
          "frame=%s" % t["hosted_view_frame_in_window"])
    if t["panel_selected_in_area"] and (not t["hosted_view_visible_in_ui"] or t["portal_host_id"] is None): bad=1
print("RESULT", label, "GREY" if bad else "OK")
sys.exit(bad)' "$1" "$top_area"
}

"$CLI" close-panel --panel "$bottom_panel" >/dev/null
sleep 2
status=0
check after-close || status=1
# The operator then dragged a column divider.
"$CLI" resize-pane --pane "$top_area" -R --amount 80 >/dev/null
sleep 2
check after-resize || status=1
exit $status
