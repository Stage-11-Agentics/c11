#!/bin/bash
# Host self-test of the kit's hc records and diag join (C11H-31): hcrecs.py (hc ls, then hc get per terminal), diagjoin.py (the
# `diag` listing when C11_DIAG_VERB is unset), lib.sh term_snapshot and guest-b.zsh's label helpers. Needs no guest, no app,
# no hc: a fake hc answers `ls`/`get` from test/fixtures (real C11H-24 / C11H-13 guest output, plus get records in the real
# record's shape; see fixtures/README.md). The tty lookup is off (C11_DIAG_PS=0). Nothing is launched or signalled.
# Usage: tools/c11-guest/test/hcrecs-selftest.sh  -> "HCRECS SELFTEST PASS n" or the failures, exit 0/1.
set -u
K="$(cd "$(dirname "$0")/.." && pwd)"; FX="$K/test/fixtures"
# The proofs kit (lib.sh, guest-b.zsh) moved to the private c11-ops repo (C11H-268): C11_PROOFS_DIR, or a
# c11-ops checkout beside this repo.
PR="${C11_PROOFS_DIR:-$K/../../../c11-ops/tools/c11h-proofs}"
[ -f "$PR/lib.sh" ] || { echo "HCRECS SELFTEST SKIP: no proofs kit at $PR (set C11_PROOFS_DIR)"; exit 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/c11-hcrecs.XXXXXX")"
n=0; bad=0
check() { if eval "$2"; then n=$((n + 1)); else echo "HCRECS SELFTEST FAIL: $1 [$2]"; bad=1; fi; }
J() { python3 -I -c "import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))" "$1"; }   # J '<expr over d>'

# fake hc: ls [--all] -> fixture; get <addr> -> that record from get-records.json (or get-ticker-real.json for studio/t1), else an
# error; FAKE_LS_ERR set -> the real no-core error, exit 4. Records its argv.
cat > "$W/hc" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE/argv"
[ -n "${FAKE_LS_ERR:-}" ] && { cat "$FAKE_LS_ERR" >&2; exit 4; }
case "$1" in
  ls) if [[ " $* " == *" --all "* ]]; then cat "$FAKE/ls-all.json"; else cat "$FAKE/ls.json"; fi ;;
  get) [ "$2" = studio/t1 ] && { cat "$FX/get-ticker-real.json"; exit 0; }
       [ -f "$FAKE/get-fails-$2" ] && { echo '{"error":{"kind":"not_found","message":"no terminal '"$2"'","hint":""}}'; exit 1; }
       python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d.get(sys.argv[2]); print(json.dumps(r)) if r else sys.exit(1)' "$FX/get-records.json" "$2" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$W/hc"
export FX FAKE="$W/f"; mkdir -p "$FAKE"
cp "$FX/hcls-6-live.json" "$FAKE/ls.json"; cp "$FX/hcls-all.json" "$FAKE/ls-all.json"
RECS() { python3 -I "$K/hcrecs.py" "$W/hc" "$@"; }

# --- hcrecs.py
out=$(RECS); rc=$?
check "hcrecs: exit 0, 6 terminals"                  '[ $rc = 0 ] && [ "$(echo "$out" | J "len(d[\"terminals\"])")" = 6 ]'
check "hcrecs: the shape of hc ls (hidden_finished, source)" '[ "$(echo "$out" | J "(d[\"hidden_finished\"], d[\"source\"])")" = "(1, '"'"'hc ls + hc get'"'"')" ]'
check "hcrecs: every terminal carries its get labels and pid" '[ "$(echo "$out" | J "all(t[\"labels\"][\"c11.panel\"] and t[\"pid\"] for t in d[\"terminals\"])")" = True ]'
check "hcrecs: ls addresses kept, in order"          '[ "$(echo "$out" | J "\",\".join(t[\"address\"] for t in d[\"terminals\"])")" = t1,t2,t3,t4,t6,t7 ]'
check "hcrecs: plain ls then one get per terminal"    'grep -cx "ls --json" "$FAKE/argv" | grep -qx 1 && [ "$(grep -c "^get t[0-9] --json$" "$FAKE/argv")" = 6 ]'
: > "$FAKE/argv"; out=$(RECS --all)
check "hcrecs --all: passes --all, adds the finished t5" 'grep -qx "ls --json --all" "$FAKE/argv" && [ "$(echo "$out" | J "[t[\"state\"] for t in d[\"terminals\"] if t[\"address\"]==\"t5\"]")" = "['"'"'finished'"'"']" ]'
: > "$FAKE/get-fails-t3"; out=$(RECS); rc=$?; rm -f "$FAKE/get-fails-t3"
check "hcrecs: a failed get keeps the ls row with get_error" '[ $rc = 0 ] && [ "$(echo "$out" | J "[(t[\"address\"], t.get(\"state\"), \"get_error\" in t, \"labels\" in t) for t in d[\"terminals\"] if t[\"address\"]==\"t3\"]")" = "[('"'"'t3'"'"', '"'"'live'"'"', True, False)]" ]'
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["terminals"].append({"address":"studio/t1","agent":"python","cwd":"/Users/demo","state":"live","turn":0}); print(json.dumps(d))' "$FX/hcls-6-live.json" > "$FAKE/ls.json"
out=$(RECS)
check "hcrecs: the real get record (remote, no labels) merges" '[ "$(echo "$out" | J "[(t[\"address\"], t[\"name\"], t[\"labels\"]) for t in d[\"terminals\"] if t[\"address\"]==\"studio/t1\"]")" = "[('"'"'studio/t1'"'"', '"'"'ticker'"'"', {})]" ]'
cp "$FX/hcls-6-live.json" "$FAKE/ls.json"
err=$(FAKE_LS_ERR="$FX/hcls-socket-absent.err" RECS 2>&1 >/dev/null); rc=$?
check "hcrecs: hc ls's failure (real no-core error) passes through" '[ $rc = 4 ] && echo "$err" | grep -q "core socket absent"'

# --- the guest entry point `guest.sh hcrecs` (PR #50 review): with no core socket it must not run hc at all, because any hc verb
# autostarts a core. guest.sh runs here only through its own overrides: HOME = scratch (its only top-level effect is a mkdir
# under $HOME), C11_APP = a scratch .app holding just an Info.plist, C11_HC_BIN = a recording fake hc, C11_HC_SOCK = an
# absent path or a socket file bound in scratch. Only the hcrecs verb runs; it starts and signals nothing but the fake hc.
GH="$W/gh"; GA="$W/c11 DEV t.app"; mkdir -p "$GH/c11-guest" "$GA/Contents"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.stage11.c11.debug.t' -c 'Add :CFBundleExecutable string c11' "$GA/Contents/Info.plist" >/dev/null
cp "$K/hcrecs.py" "$GH/c11-guest/"
# guest.sh runs hc under env -i, so this fake has its fixture and log paths baked in, and records what env it was given
cat > "$W/hc-entry" <<EOF
#!/bin/bash
echo "\$* | HC_SESSION=\${HC_SESSION:-} HC_SOCKET=\${HC_SOCKET:-}" >> "$W/entry-argv"
case "\$1" in
  ls) cat "$FX/hcls-6-live.json" ;;
  get) python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])).get(sys.argv[2]); print(json.dumps(r)) if r else sys.exit(1)' "$FX/get-records.json" "\$2" ;;
esac
EOF
chmod +x "$W/hc-entry"
GE() { env HOME="$GH" C11_APP="$GA" C11_HC_BIN="$W/hc-entry" C11_HC_SOCK="$1" /bin/zsh "$K/guest.sh" hcrecs; }
: > "$W/entry-argv"; err=$(GE "$W/no.sock" 2>&1 >/dev/null); rc=$?
check "guest.sh hcrecs, no socket: exit 4, says so"   '[ $rc = 4 ] && echo "$err" | grep -q "core socket absent ($W/no.sock); not autostarting"'
check "guest.sh hcrecs, no socket: hc never run"      '[ ! -s "$W/entry-argv" ]'
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$W/c.sock"   # a socket file; nothing listens
: > "$W/entry-argv"; out=$(GE "$W/c.sock"); rc=$?
check "guest.sh hcrecs, socket: records for 6"        '[ $rc = 0 ] && [ "$(echo "$out" | J "len(d[\"terminals\"])")" = 6 ]'
check "guest.sh hcrecs: hc gets the app's session and that socket" 'grep -qx "ls --json | HC_SESSION=c11-t HC_SOCKET=$W/c.sock" "$W/entry-argv"'
rm -f "$GH/c11-guest/hcrecs.py"; : > "$W/entry-argv"; GE "$W/c.sock" >/dev/null 2>&1; rc=$?
check "guest.sh hcrecs, helper missing: exit 5, hc never run" '[ $rc = 5 ] && [ ! -s "$W/entry-argv" ]'

# --- diagjoin.py (the kit's diag with C11_DIAG_VERB unset)
DJ() { C11_DIAG_PS=0 C11_TREE="$(cat "$FX/tree-6.json")" C11_HCRECS="$1" C11_HCDIAG="${2:-}" python3 -I "$K/diagjoin.py"; }
all=$(RECS --all)
d=$(DJ "$all" "$(cat "$FX/hcdiag-ready.json")")
check "diag: 6 panels, all live"                      '[ "$(echo "$d" | J "[p[\"lifecycle\"] for p in d[\"panels\"]]")" = "$(python3 -c "print([\"live\"]*6)")" ]'
check "diag: panel 1 is its live t1, not the finished t5" '[ "$(echo "$d" | J "(d[\"panels\"][0][\"terminal\"], d[\"panels\"][0][\"pid\"])")" = "('"'"'t1'"'"', 2100)" ]'
check "diag: each panel its own terminal and pid"     '[ "$(echo "$d" | J "\",\".join(\"%s:%s\" % (p[\"terminal\"], p[\"pid\"]) for p in d[\"panels\"])")" = t1:2100,t2:2101,t3:2102,t4:2103,t6:2104,t7:2105 ]'
check "diag: real hc-diagnostics (panels []) adds nothing" '[ "$(echo "$d" | J "{p[\"source\"] for p in d[\"panels\"]}")" = "{'"'"'tree+hc-get'"'"'}" ]'
check "diag: keeps the old fields"                    '[ "$(echo "$d" | J "sorted(d[\"panels\"][0])")" = "['"'"'hc_build'"'"', '"'"'lifecycle'"'"', '"'"'panel'"'"', '"'"'pid'"'"', '"'"'ref'"'"', '"'"'source'"'"', '"'"'terminal'"'"', '"'"'tty'"'"']" ]'
p1=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["windows"][0]["workspaces"][0]["areas"][0]["panels"][0]["id"])' "$FX/tree-6.json")
hd='{"readiness":"ready","panels":[{"panel_id":"'"$p1"'","terminal":"t1","tty":"ttys001","pid":2100,"lifecycle":"live","serving_build":"0.1.16"}]}'
d=$(DJ "$all" "$hd")
check "diag: an hc-diagnostics row adds hc_build and its tty" '[ "$(echo "$d" | J "(d[\"panels\"][0][\"hc_build\"], d[\"panels\"][0][\"tty\"], d[\"panels\"][0][\"source\"], d[\"panels\"][1][\"hc_build\"])")" = "('"'"'0.1.16'"'"', '"'"'ttys001'"'"', '"'"'tree+hc-get+hc-diagnostics'"'"', None)" ]'
d=$(DJ '{"terminals":[]}')
check "diag: no hc records (no core): every panel unresolved" '[ "$(echo "$d" | J "{p[\"lifecycle\"] for p in d[\"panels\"]}")" = "{'"'"'unresolved'"'"'}" ]'
d=$(DJ "$(cat "$FX/hcls-6-live.json")")
check "diag: raw hc ls (no labels) joins nothing"     '[ "$(echo "$d" | J "{p[\"lifecycle\"] for p in d[\"panels\"]}")" = "{'"'"'unresolved'"'"'}" ]'
onlyfin=$(echo "$all" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["terminals"]=[t for t in d["terminals"] if t["address"]!="t1"]; print(json.dumps(d))')
d=$(DJ "$onlyfin")
check "diag: a panel with only a finished terminal is ended" '[ "$(echo "$d" | J "(d[\"panels\"][0][\"lifecycle\"], d[\"panels\"][0][\"terminal\"], d[\"panels\"][1][\"lifecycle\"])")" = "('"'"'ended'"'"', '"'"'t5'"'"', '"'"'live'"'"')" ]'
lower=$(echo "$all" | python3 -c 'import json,sys; d=json.load(sys.stdin); [t["labels"].update({"c11.panel": t["labels"]["c11.panel"].lower()}) for t in d["terminals"] if t.get("labels")]; print(json.dumps(d))')
d=$(DJ "$lower")
check "diag: a lowercase label value still joins"     '[ "$(echo "$d" | J "{p[\"lifecycle\"] for p in d[\"panels\"]}")" = "{'"'"'live'"'"'}" ]'

# --- lib.sh term_snapshot, through a fake kit whose hcrecs is hcrecs.py on the fake hc
mkdir -p "$W/kit"; printf '#!/bin/bash\n[ "$1" = hcrecs ] && { shift; exec python3 -I "%s/hcrecs.py" "%s/hc" "$@"; }\n[ "$1" = hc ] && { shift; exec "%s/hc" "$@"; }\nexit 2\n' "$K" "$W" "$W" > "$W/kit/g.sh"; chmod +x "$W/kit/g.sh"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["terminals"].append({"address":"studio/t1","agent":"python","cwd":"/x","state":"live","turn":0}); print(json.dumps(d))' "$FX/hcls-6-live.json" > "$FAKE/ls.json"
snap=$(bash -c '. "$1/lib.sh"; KIT="$2"; term_snapshot' _ "$PR" "$W/kit")
check "term_snapshot: one line per app terminal, with pid and labels" '[ "$(echo "$snap" | wc -l | tr -d " ")" = 6 ] && echo "$snap" | head -1 | grep -q "^t1 2100 {\"c11.panel\": \"$p1\", \"c11.creation\": "'
check "term_snapshot: the unlabelled terminal is left out" '! echo "$snap" | grep -q "studio/t1"'
cp "$FX/hcls-6-live.json" "$FAKE/ls.json"

# --- guest-b.zsh label helpers (hc_labels, hc_label_count, diag_state's fallback), sourced with G -> the fake kit
GB() { zsh -c 'emulate -L zsh; KITG="$2"; export HOME="$3" PD="$1"; source "$1/guest-b.zsh"; G() { "$KITG" "$@"; }; eval "$4"' _ "$PR" "$W/kit/g.sh" "$W/home" "$1"; }
mkdir -p "$W/home"
labs=$(GB 'hc_labels')
check "guest-b hc_labels: the six panel UUIDs"        '[ "$(echo "$labs" | wc -l | tr -d " ")" = 6 ] && [ "$labs" = "$(python3 -c "import json,sys; print(\"\\n\".join(sorted(p[\"id\"].upper() for p in json.load(open(sys.argv[1]))[\"windows\"][0][\"workspaces\"][0][\"areas\"][0][\"panels\"])))" "$FX/tree-6.json" | LC_ALL=C sort)" ]'
check "guest-b hc_label_count: 1 for a panel"         '[ "$(GB "hc_label_count $p1")" = 1 ]'
check "guest-b diag_state fallback: live / none"      '[ "$(GB "diag_json() { :; }; diag_state $p1")" = live ] && [ "$(GB "diag_json() { :; }; diag_state FFFFFFFF-0000-0000-0000-000000000000")" = none ]'

rm -rf "$W"
if [ $bad = 0 ]; then echo "HCRECS SELFTEST PASS $n"; exit 0; else exit 1; fi
