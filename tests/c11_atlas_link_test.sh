#!/bin/sh
# Host-side checks for scripts/c11-atlas-link.sh. No guest, no herdr-app, no network.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LINK=$ROOT/scripts/c11-atlas-link.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); printf 'ok %s\n' "$1"; }

# The ssh host comes from --target, C11_REMOTE_HOST, or the dev-hosts file; the script has no default.
unset C11_REMOTE_HOST
C11_DEV_HOSTS=$TMP/dev-hosts
export C11_DEV_HOSTS
printf '# sample config\nC11_REMOTE_HOST=studio\n' > "$C11_DEV_HOSTS"
# C11H-365: pair refuses --yes inside a c11 terminal; these runs are outside
# one unless a case sets a variable itself.
unset C11_PANEL_ID C11_SURFACE_ID CMUX_SURFACE_ID

# Exercise the production in-use check with a recorded open-file table, one
# "pid uid fd path" line per open file. The lsof stand-in applies lsof's
# selection rules: -u, -d and names each select, ORed unless -a ANDs them;
# -t prints the PIDs; exit 0 only on a match. The ps stand-in prints recorded
# command lines, so a check that reads argv would see them. Host tests never
# create or signal a process merely to make a file appear open.
PS_BIN=$TMP/process-bin
mkdir -p "$PS_BIN"
cat > "$PS_BIN/ps" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${TEST_PS_CALLS:-/dev/null}"
cat "${TEST_PS_OUTPUT:-/dev/null}"
EOF
cat > "$PS_BIN/lsof" <<'EOF'
#!/usr/bin/python3 -I
import os, sys
args = sys.argv[1:]
with open(os.environ.get("TEST_LSOF_CALLS", "/dev/null"), "a") as calls:
    calls.write(" ".join(args) + "\n")
users = fds = None
names, joined, i = [], False, 0
while i < len(args):
    arg = args[i]
    if arg == "--":
        names += args[i + 1:]
        break
    if arg in ("-u", "-d"):
        if i + 1 == len(args):
            sys.exit(2)
        values = set(args[i + 1].split(","))
        if arg == "-u":
            users = values
        else:
            fds = values
        i += 2
        continue
    if arg.startswith("-"):
        if not set(arg[1:]) <= set("nPwta"):
            sys.exit(2)  # an option this stand-in does not model
        joined = joined or "a" in arg
    else:
        names.append(arg)
    i += 1
rows = []
for line in open(os.environ.get("TEST_LSOF_TABLE", "/dev/null")):
    row = line.rstrip("\n").split(" ", 3)
    if len(row) == 4:
        rows.append(row)
tests = []
if users is not None:
    tests.append(lambda row: row[1] in users)
if fds is not None:
    tests.append(lambda row: row[2] in fds)
if names:
    tests.append(lambda row: row[3] in names)
pick = all if joined else any
hits = [row for row in rows if not tests or pick(test(row) for test in tests)]
for pid in sorted({row[0] for row in hits}, key=int):
    print(pid)
sys.exit(0 if hits else 1)
EOF
chmod 755 "$PS_BIN/ps" "$PS_BIN/lsof"
MY_UID=$(id -u)

HOME_A=$TMP/home
mkdir -p "$HOME_A/.local/bin"
printf 'herdr-app\n' > "$HOME_A/.local/bin/herdr-core"
chmod 755 "$HOME_A/.local/bin/herdr-core"
bin_inode=$(stat -f '%i' "$HOME_A/.local/bin/herdr-core")

PIN_DIR=$HOME_A/.local/share/c11/hc/0.1.16
SOCK=$HOME_A/.local/share/c11/run/c11-c11-b.sock
HC=$PIN_DIR/herdr-core
printf 'pin-bytes-v1\n' > "$TMP/pin"
SHA=$(shasum -a 256 "$TMP/pin" | awk '{print $1}')

# install: missing -> written; herdr-app's binary untouched
HOME=$HOME_A "$LINK" install --pin 0.1.16 --sha "$SHA" < "$TMP/pin" | grep -q '^installed '
[ "$(cat "$HC")" = "$(cat "$TMP/pin")" ] || fail "installed bytes"
[ "$(stat -f '%i' "$HOME_A/.local/bin/herdr-core")" = "$bin_inode" ] || fail "local bin inode changed"
ok "install writes only the c11 pin path"

# matching hash does not rewrite
mtime=$(stat -f '%m' "$HC")
sleep 1
HOME=$HOME_A "$LINK" install --pin 0.1.16 --sha "$SHA" < "$TMP/pin" | grep -q '^unchanged '
[ "$(stat -f '%m' "$HC")" = "$mtime" ] || fail "matching hash rewrote the file"
ok "matching hash is a no-op"

# different hash while a process of this account runs the file: refuse, leave both trees
printf 'other-bytes\n' > "$TMP/other"
OSHA=$(shasum -a 256 "$TMP/other" | awk '{print $1}')
printf '4100 %s txt %s\n' "$MY_UID" "$HC" > "$TMP/lsof.busy"
: > "$TMP/lsof.calls"
set +e
HOME=$HOME_A PATH="$PS_BIN:$PATH" TEST_LSOF_TABLE=$TMP/lsof.busy TEST_LSOF_CALLS=$TMP/lsof.calls \
  "$LINK" install --pin 0.1.16 --sha "$OSHA" < "$TMP/other" >"$TMP/refuse.out" 2>"$TMP/refuse.err"
rc=$?
set -e
[ -s "$TMP/lsof.calls" ] || fail "installer did not run its open-file check"
[ "$rc" = 3 ] || fail "in-use replace exited $rc"
[ "$(cat "$HC")" = "$(cat "$TMP/pin")" ] || fail "in-use replace changed the pin"
[ "$(stat -f '%i' "$HOME_A/.local/bin/herdr-core")" = "$bin_inode" ] || fail "refuse touched local bin"
ok "a hash mismatch is refused while this account runs the file"

# C11H-365: what another account runs, what this account only reads, and a
# command line that merely names the path never block the replace.
{
  printf '4200 %s txt %s\n' "$((MY_UID + 1000))" "$HC"
  printf '4300 %s 3r %s\n' "$MY_UID" "$HC"
  printf '4400 %s txt /bin/sh\n' "$MY_UID"
} > "$TMP/lsof.decoys"
printf '/bin/sh -c wait %s connect --session c11-test\n' "$HC" > "$TMP/ps.decoys"
HOME=$HOME_A PATH="$PS_BIN:$PATH" TEST_LSOF_TABLE=$TMP/lsof.decoys TEST_PS_OUTPUT=$TMP/ps.decoys \
  "$LINK" install --pin 0.1.16 --sha "$OSHA" < "$TMP/other" >"$TMP/decoy.out" 2>"$TMP/decoy.err" \
  || fail "another account, a reader or an argv blocked the replace ($(cat "$TMP/decoy.err"))"
grep -q '^installed ' "$TMP/decoy.out" || fail "decoy replace said ($(cat "$TMP/decoy.out"))"
[ "$(cat "$HC")" = "$(cat "$TMP/other")" ] || fail "replace bytes"
printf 'pin-bytes-v1\n' > "$TMP/pin"
HOME=$HOME_A PATH="$PS_BIN:$PATH" "$LINK" install --pin 0.1.16 --sha "$SHA" < "$TMP/pin" >/dev/null
ok "another account's process, a reader or a matching command line does not block a replace"

# bad stdin hash writes nothing new
before=$(shasum -a 256 "$HC" | awk '{print $1}')
set +e
printf 'nope\n' | HOME=$HOME_A PATH="$PS_BIN:$PATH" "$LINK" install --pin 0.1.16 --sha "$OSHA" >"$TMP/bad.out" 2>"$TMP/bad.err"
rc=$?
set -e
[ "$rc" = 2 ] || fail "bad stdin exited $rc"
[ "$(shasum -a 256 "$HC" | awk '{print $1}')" = "$before" ] || fail "bad stdin replaced the pin"
ok "stdin hash mismatch writes nothing"

# The pin stand-in records the limit and environment of the process that
# replaced the raiser. env -i drops the test's variables, so the path is baked.
PIN_DIR=$HOME_A/.local/share/c11/hc/0.1.16-$(printf '%s' "$SHA" | cut -c1-12)
mkdir -p "$PIN_DIR"
HC=$PIN_DIR/herdr-core
cat > "$HC" <<EOF
#!/usr/bin/python3 -I
import os, resource, sys
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
base = "$TMP/stub"
open(base + ".soft", "w").write("%s\n" % soft)
open(base + ".hard", "w").write("%s\n" % hard)
with open(base + ".env", "w") as fh:
    for key in sorted(os.environ):
        fh.write("%s=%s\n" % (key, os.environ[key]))
with open(base + ".argv", "w") as fh:
    fh.write("\\n".join(sys.argv) + "\\n")
EOF
chmod 755 "$HC"
# C11H-332: every via carries the pin; here it is the stand-in's own hash.
PIN_SHA=$(shasum -a 256 "$HC" | awk '{print $1}')

# ssh via: ignore the default remote line, bake the tuple, raise NOFILE
STUB=$TMP/ssh
cat > "$STUB" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$STUB_ARGS"
exit 0
EOF
chmod 755 "$STUB"
VIA=$TMP/atlas-via
FAKE_MARK=$TMP/fake-ran
mkdir -p "$TMP/fakebin" "$HOME_A/.local/bin"
cat > "$TMP/fakebin/herdr-core" <<EOF
#!/bin/sh
echo ran >> "$FAKE_MARK"
exit 99
EOF
cp "$TMP/fakebin/herdr-core" "$HOME_A/.local/bin/herdr-core"
chmod 755 "$TMP/fakebin/herdr-core" "$HOME_A/.local/bin/herdr-core"
STUB_ARGS=$TMP/ssh.args "$LINK" render --sha "$PIN_SHA" --mode ssh --out "$VIA" \
  --session c11-c11-b --socket "$SOCK" --hc "$HC" \
  --target studio --ssh "$STUB" --home "$HOME_A" --user tester
# restore the herdr-app stand-in that the copy above replaced
printf 'herdr-app\n' > "$HOME_A/.local/bin/herdr-core"
chmod 755 "$HOME_A/.local/bin/herdr-core"
HOME=$HOME_A STUB_ARGS=$TMP/ssh.args "$VIA" "sh -c 'p=\$(command -v herdr-core); exec \"\$p\" connect'"
[ -f "$FAKE_MARK" ] && fail "via script ran the fake herdr-core"
grep -q 'command -v' "$TMP/ssh.args" && fail "via passed hc's remote line to ssh"
grep -q -- "--" "$TMP/ssh.args" || fail "ssh args missing --"
grep -q '^studio$' "$TMP/ssh.args" || fail "ssh target not baked"
# C11H-78: no connection sharing, whatever ~/.ssh/config says, and set before the target.
opts=$(awk '$0 == "--" { exit } { print }' "$TMP/ssh.args")
printf '%s\n' "$opts" | grep -qx 'ControlMaster=no' || fail "ssh via does not turn ControlMaster off"
printf '%s\n' "$opts" | grep -qx 'ControlPath=none' || fail "ssh via does not turn ControlPath off"
# C11H-361: and every forwarding off, whatever ~/.ssh/config says, also before the target.
for want in ForwardAgent=no ForwardX11=no ClearAllForwardings=yes PermitLocalCommand=no -k; do
  printf '%s\n' "$opts" | grep -qx -- "$want" || fail "ssh via lacks $want before --"
done
grep -q "HC_SESSION=c11-c11-b" "$TMP/ssh.args" || fail "session not baked"
grep -q "HC_SOCKET=$SOCK" "$TMP/ssh.args" || fail "socket not baked"
grep -q 'HC_SPAWN_MS=10000' "$TMP/ssh.args" || fail "HC_SPAWN_MS not baked"
grep -q 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "$TMP/ssh.args" || fail "remote PATH not restricted"
grep -q " $HC connect --session c11-c11-b" "$TMP/ssh.args" || fail "absolute pin not baked"
grep -q '/usr/bin/python3' "$TMP/ssh.args" || fail "remote command does not raise the limit before exec"
remote=$(awk 'END{print}' "$TMP/ssh.args" | sed "s/^'//;s/'$//")
limit_field() {
  awk -v key="$2" '{
    for (i = 1; i <= NF; i++) {
      split($i, a, "=")
      if (a[1] == key) print a[2]
    }
  }' "$1"
}
rm -f "$TMP/stub.soft" "$TMP/stub.hard" "$TMP/stub.env" "$TMP/stub.argv"
PATH="$TMP/fakebin:$HOME_A/.local/bin:/usr/bin:/bin" XDG_CONFIG_HOME=/local/app/config \
  XDG_DATA_HOME=/local/app/data XDG_CACHE_HOME=/local/app/cache SSH_AUTH_SOCK=/local/agent \
  HC_LAUNCHD_DIRECT=1 /bin/sh -c "$remote" >"$TMP/remote.out" 2>"$TMP/remote.err"
[ -f "$FAKE_MARK" ] && fail "dirty PATH reached the fake herdr-core"
[ ! -s "$TMP/remote.out" ] || fail "limit log leaked onto stdout"
grep -q '^nofile ' "$TMP/remote.err" || fail "missing nofile log ($(cat "$TMP/remote.err"))"
kernel_cap=$(/usr/sbin/sysctl -n kern.maxfilesperproc)
[ "$(limit_field "$TMP/remote.err" kernel_cap)" = "$kernel_cap" ] || fail "kernel cap not logged"
before_soft=$(limit_field "$TMP/remote.err" before_soft)
before_hard=$(limit_field "$TMP/remote.err" before_hard)
after_soft=$(limit_field "$TMP/remote.err" after_soft)
after_hard=$(limit_field "$TMP/remote.err" after_hard)
[ "$after_hard" = "$before_hard" ] || fail "hard limit changed"
[ "$after_soft" -ge 8192 ] || fail "soft limit stayed under 8192"
[ "$after_soft" -ge "$before_soft" ] || fail "soft limit was lowered"
[ "$(cat "$TMP/stub.soft")" = "$after_soft" ] || fail "pin did not inherit the soft limit"
[ "$(cat "$TMP/stub.hard")" = "$after_hard" ] || fail "pin did not inherit the hard limit"
grep -q '^HC_SESSION=c11-c11-b$' "$TMP/stub.env" || fail "pin session"
grep -q "^HC_SOCKET=$SOCK$" "$TMP/stub.env" || fail "pin socket"
grep -q '^HC_SPAWN_MS=10000$' "$TMP/stub.env" || fail "pin HC_SPAWN_MS"
grep -q '^PATH=/usr/bin:/bin:/usr/sbin:/sbin$' "$TMP/stub.env" || fail "pin PATH"
grep -Fx "HOME=$HOME_A" "$TMP/stub.env" >/dev/null || fail "pin HOME"
assert_core_config() {
  grep -Fx "XDG_CONFIG_HOME=$HOME_A/.local/share/c11/config" "$TMP/stub.env" >/dev/null || fail "pin owned config"
  [ "$(grep -c '^XDG_' "$TMP/stub.env")" = 1 ] || fail "pin inherited another XDG variable"
  grep -Eq '^(SSH_|HC_LAUNCHD_DIRECT=)' "$TMP/stub.env" && fail "pin inherited SSH or launchd state"
  return 0
}
assert_core_config
grep -q 'fakebin' "$TMP/stub.env" && fail "pin inherited the dirty PATH"
printf '%s\n' "$HC" connect --session c11-c11-b > "$TMP/argv.want"
cmp -s "$TMP/stub.argv" "$TMP/argv.want" || fail "pin argv ($(cat "$TMP/stub.argv"))"
ok "ssh via ignores the default line and a dirty PATH"

# A soft limit already above the kernel cap stays there.
rm -f "$TMP/stub.soft" "$TMP/stub.hard" "$TMP/stub.env" "$TMP/stub.argv"
set +e
/usr/bin/python3 -I -c 'import os, resource, subprocess, sys
cap = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "kern.maxfilesperproc"]))
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
resource.setrlimit(resource.RLIMIT_NOFILE, (cap + 100, hard))
os.execv("/bin/sh", ["sh", "-c", sys.argv[1]])' "$remote" >"$TMP/high.out" 2>"$TMP/high.err"
rc=$?
set -e
[ "$rc" = 0 ] || fail "above-cap launch exited $rc ($(cat "$TMP/high.err"))"
[ "$(limit_field "$TMP/high.err" before_soft)" = "$((kernel_cap + 100))" ] || fail "above-cap before_soft"
[ "$(limit_field "$TMP/high.err" after_soft)" = "$((kernel_cap + 100))" ] || fail "above-cap soft was lowered"
[ "$(cat "$TMP/stub.soft")" = "$((kernel_cap + 100))" ] || fail "pin soft was lowered"
[ -f "$FAKE_MARK" ] && fail "above-cap launch ran the fake"
ok "soft limit above the kernel cap is not lowered"

# A hard limit under 8192 cannot be raised. Refuse before exec.
rm -f "$TMP/stub.soft" "$TMP/stub.hard" "$TMP/stub.env" "$TMP/stub.argv"
set +e
/usr/bin/python3 -I -c 'import os, resource, sys
resource.setrlimit(resource.RLIMIT_NOFILE, (1024, 1024))
os.execv("/bin/sh", ["sh", "-c", sys.argv[1]])' "$remote" >"$TMP/low.out" 2>"$TMP/low.err"
rc=$?
set -e
[ "$rc" = 4 ] || fail "low hard limit exited $rc ($(cat "$TMP/low.err"))"
grep -q '^hc_fd_limit ' "$TMP/low.err" || fail "low hard limit was not hc_fd_limit"
[ ! -f "$TMP/stub.argv" ] || fail "low hard limit still exec'd the pin"
[ -f "$FAKE_MARK" ] && fail "low hard limit ran the fake"
ok "hard limit under 8192 is hc_fd_limit and does not exec"

# C11H-332: the pin is required, and every dial checks the hc it is about to run.
HCSHA=$(shasum -a 256 "$HC" | awk '{print $1}')
WRONG=$(printf 'not-this-hc' | shasum -a 256 | awk '{print $1}')
STUB_ARGS=$TMP/ssh-sha.args "$LINK" render --mode ssh --out "$TMP/via-sha" \
  --session c11-c11-b --socket "$SOCK" --hc "$HC" --sha "$HCSHA" \
  --target studio --ssh "$STUB" --home "$HOME_A" --user tester
HOME=$HOME_A STUB_ARGS=$TMP/ssh-sha.args "$TMP/via-sha" ignored
grep -q " sha256=$HCSHA $HC connect --session c11-c11-b" "$TMP/ssh-sha.args" || fail "--sha not baked before the pin"
remote_sha=$(awk 'END{print}' "$TMP/ssh-sha.args" | sed "s/^'//;s/'$//")
rm -f "$TMP/stub.argv"
/bin/sh -c "$remote_sha" >"$TMP/sha-ok.out" 2>"$TMP/sha-ok.err" || fail "matching hash did not run ($(cat "$TMP/sha-ok.err"))"
cmp -s "$TMP/stub.argv" "$TMP/argv.want" || fail "matching hash argv ($(cat "$TMP/stub.argv"))"
ok "a matching hc runs, and the hash never reaches its argv"

STUB_ARGS=$TMP/ssh-bad.args "$LINK" render --mode ssh --out "$TMP/via-bad" \
  --session c11-c11-b --socket "$SOCK" --hc "$HC" --sha "$WRONG" \
  --target studio --ssh "$STUB" --home "$HOME_A" --user tester
HOME=$HOME_A STUB_ARGS=$TMP/ssh-bad.args "$TMP/via-bad" ignored
remote_bad=$(awk 'END{print}' "$TMP/ssh-bad.args" | sed "s/^'//;s/'$//")
rm -f "$TMP/stub.argv"
set +e
/bin/sh -c "$remote_bad" >"$TMP/sha-bad.out" 2>"$TMP/sha-bad.err"
rc=$?
set -e
[ "$rc" = 5 ] || fail "hash mismatch exited $rc ($(cat "$TMP/sha-bad.err"))"
grep -q "^hc_hash_mismatch expected=$WRONG found=$HCSHA path=$HC\$" "$TMP/sha-bad.err" || fail "mismatch line ($(cat "$TMP/sha-bad.err"))"
[ ! -f "$TMP/stub.argv" ] || fail "a mismatched hc was started"
ok "a different hc is refused with hc_hash_mismatch and never started"

for flags in "--sha NOTHEX" ""; do
  set +e
  # shellcheck disable=SC2086
  "$LINK" render --mode ssh --out "$TMP/via-x" --session c11-c11-b --socket "$SOCK" --hc "$HC" $flags \
    --target studio --ssh "$STUB" --home "$HOME_A" --user tester 2>"$TMP/nosha.err"
  rc=$?
  set -e
  [ "$rc" = 2 ] || fail "render without a valid pin exited $rc ($flags)"
  [ ! -e "$TMP/via-x" ] || fail "render without a valid pin wrote a via ($flags)"
done
grep -q "needs --sha" "$TMP/nosha.err" || fail "missing --sha message ($(cat "$TMP/nosha.err"))"
for sub in serve pair; do
  set +e
  if [ "$sub" = serve ]; then
    "$LINK" serve --listen "$TMP/nosha.sock" --session c11-c11-b --socket "$SOCK" --hc "$HC" --home "$HOME_A" --user tester >/dev/null 2>&1
  else
    HOME=$TMP/nosha-home "$LINK" pair --yes --mode ssh --session c11-c11-b --shards 1 --hc "$HC" --home "$HOME_A" --user far --target studio >/dev/null 2>&1
  fi
  rc=$?
  set -e
  [ "$rc" = 2 ] || fail "$sub without --sha exited $rc"
done
[ ! -e "$TMP/nosha.sock" ] && [ ! -e "$TMP/nosha-home/.local/share/c11/atlas-pair.json" ] || fail "a pinless serve or pair left something behind"
ok "render, serve and pair refuse a missing or malformed pin"

# C11H-357: c11 reads `local` as this Mac, so pair refuses it like `default`
# and writes nothing. The same call with another name pairs, so the refusal is
# the machine check's.
for name in local default; do
  set +e
  HOME=$TMP/reserved-home "$LINK" pair --yes --sha "$PIN_SHA" --mode ssh --session c11-c11-b --shards 1 \
    --hc /Users/far/.local/share/c11/hc/0.1.16-abcdef123456/herdr-core --home /Users/far --user far \
    --target studio --machine "$name" --ssh "$STUB" >/dev/null 2>"$TMP/reserved.err"
  rc=$?
  set -e
  [ "$rc" != 0 ] || fail "pair --machine $name succeeded"
  grep -q "bad machine name" "$TMP/reserved.err" || fail "pair --machine $name: $(cat "$TMP/reserved.err")"
  [ ! -e "$TMP/reserved-home/.local/share/c11/atlas-pair.json" ] || fail "pair --machine $name wrote a pairing file"
done
HOME=$TMP/reserved-home "$LINK" pair --yes --sha "$PIN_SHA" --mode ssh --session c11-c11-b --shards 1 \
  --hc /Users/far/.local/share/c11/hc/0.1.16-abcdef123456/herdr-core --home /Users/far --user far \
  --target studio --machine studio-2 --ssh "$STUB" >/dev/null 2>"$TMP/reserved.err" \
  || fail "pair --machine studio-2 failed: $(cat "$TMP/reserved.err")"
[ -e "$TMP/reserved-home/.local/share/c11/atlas-pair.json" ] || fail "pair --machine studio-2 wrote no pairing file"
ok "pair refuses the machine names local and default and writes nothing"

# C11H-332: hc's socket and state folders are made 0700 without following a
# symlink, and a refused folder stops the walk.
RUN_DIR=$(dirname "$SOCK")
STATE_ROOT=$HOME_A/.local/state/herdr-core
chmod 755 "$RUN_DIR" "$STATE_ROOT" "$STATE_ROOT/c11-c11-b"
rm -f "$TMP/stub.argv"
/bin/sh -c "$remote" >"$TMP/dirs.out" 2>"$TMP/dirs.err" || fail "repair run failed ($(cat "$TMP/dirs.err"))"
for d in "$RUN_DIR" "$STATE_ROOT" "$STATE_ROOT/c11-c11-b"; do
  [ "$(stat -f '%Lp' "$d")" = 700 ] || fail "$d not repaired ($(stat -f '%Lp' "$d"))"
  grep -q "^hc_dir_repaired path=$d from=755 to=700\$" "$TMP/dirs.err" || fail "no repair line for $d ($(cat "$TMP/dirs.err"))"
done
[ -f "$TMP/stub.argv" ] || fail "repaired folders did not run the pin"
/bin/sh -c "$remote" >/dev/null 2>"$TMP/dirs2.err" || fail "second run failed"
grep -q hc_dir_repaired "$TMP/dirs2.err" && fail "a private folder was reported repaired"
ok "loose hc folders are repaired to 0700 before hc starts"

mv "$STATE_ROOT/c11-c11-b" "$TMP/real-state"
ln -s "$TMP/real-state" "$STATE_ROOT/c11-c11-b"
chmod 755 "$TMP/real-state"
rm -f "$TMP/stub.argv"
set +e
/bin/sh -c "$remote" >/dev/null 2>"$TMP/dirs3.err"
rc=$?
set -e
[ "$rc" = 6 ] || fail "symlinked state folder exited $rc ($(cat "$TMP/dirs3.err"))"
grep -q "^hc_dir_refused path=$STATE_ROOT/c11-c11-b reason=symlink\$" "$TMP/dirs3.err" || fail "symlink refusal line ($(cat "$TMP/dirs3.err"))"
[ ! -f "$TMP/stub.argv" ] || fail "a symlinked state folder still started the pin"
[ "$(stat -f '%Lp' "$TMP/real-state")" = 755 ] || fail "the symlink's target was changed"
rm "$STATE_ROOT/c11-c11-b"
mv "$TMP/real-state" "$STATE_ROOT/c11-c11-b"
chmod 700 "$STATE_ROOT/c11-c11-b"
ok "a symlinked hc folder is refused with hc_dir_refused and its target is untouched"

# A refused parent stops the walk: nothing under it is changed or created.
OUTSIDE=$TMP/outside-state
mkdir -p "$OUTSIDE/c11-c11-b"
chmod 755 "$OUTSIDE" "$OUTSIDE/c11-c11-b"
mv "$STATE_ROOT" "$TMP/real-root"
ln -s "$OUTSIDE" "$STATE_ROOT"
for case in loose missing; do
  [ "$case" = missing ] && rmdir "$OUTSIDE/c11-c11-b"
  rm -f "$TMP/stub.argv"
  set +e
  /bin/sh -c "$remote" >/dev/null 2>"$TMP/dirs4.err"
  rc=$?
  set -e
  [ "$rc" = 6 ] || fail "symlinked state root exited $rc ($case: $(cat "$TMP/dirs4.err"))"
  grep -q "^hc_dir_refused path=$STATE_ROOT reason=symlink\$" "$TMP/dirs4.err" || fail "parent refusal line ($case)"
  [ ! -f "$TMP/stub.argv" ] || fail "a symlinked state root still started the pin ($case)"
done
[ ! -e "$OUTSIDE/c11-c11-b" ] || fail "a session folder was created through the refused parent"
[ "$(stat -f '%Lp' "$OUTSIDE")" = 755 ] || fail "the refused parent's target was changed"
mkdir -p "$OUTSIDE/c11-c11-b"; chmod 755 "$OUTSIDE/c11-c11-b"
/bin/sh -c "$remote" >/dev/null 2>&1 || true
[ "$(stat -f '%Lp' "$OUTSIDE/c11-c11-b")" = 755 ] || fail "a child under the refused parent was changed"
rm "$STATE_ROOT"
mv "$TMP/real-root" "$STATE_ROOT"
ok "a symlinked state root stops the walk: nothing under it is created or changed"

# C11H-332: a core already serving the session's socket must be this pin.
# The listener here is python, not the pin: it is refused from kernel facts
# and never signalled (it exits on its own timeout).
/usr/bin/python3 -I - "$SOCK" <<'PY' &
import os, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
os.chdir(os.path.dirname(sys.argv[1]))
s.bind(os.path.basename(sys.argv[1])); s.listen(4); s.settimeout(4)
try:
    while True:
        c, _ = s.accept(); c.close()
except Exception:
    pass
PY
lpid=$!
i=0; while [ ! -S "$SOCK" ] && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.05; done
rm -f "$TMP/stub.argv"
set +e
/bin/sh -c "$remote" >/dev/null 2>"$TMP/serving.err"
rc=$?
set -e
[ "$rc" = 8 ] || fail "a foreign serving core exited $rc ($(cat "$TMP/serving.err"))"
grep -q "^hc_serving_mismatch expected=$PIN_SHA found=[0-9a-f]\{64\} pid=$lpid path=" "$TMP/serving.err" || fail "serving refusal line ($(cat "$TMP/serving.err"))"
[ ! -f "$TMP/stub.argv" ] || fail "a client was started against a foreign serving core"
ps -p "$lpid" >/dev/null 2>&1 || fail "the serving process was signalled"
HOME=$HOME_A "$LINK" secure --session c11-c11-b --socket "$SOCK" --hc "$HC" --sha "$PIN_SHA" >"$TMP/secure.out" 2>&1 || fail "secure report failed"
grep -q "^sha=$PIN_SHA\$" "$TMP/secure.out" || fail "secure report hash ($(cat "$TMP/secure.out"))"
grep -q "^serving=mismatch $lpid " "$TMP/secure.out" || fail "secure report serving ($(cat "$TMP/secure.out"))"
wait "$lpid" 2>/dev/null || true
rm -f "$SOCK"
HOME=$HOME_A "$LINK" secure --session c11-c11-b --socket "$SOCK" --hc "$HC" --sha "$PIN_SHA" >"$TMP/secure2.out" 2>&1 || fail "secure report failed"
grep -q "^serving=none\$" "$TMP/secure2.out" || fail "secure report with no core ($(cat "$TMP/secure2.out"))"
ok "a foreign serving core is refused (exit 8, never signalled); secure reports it"

# C11H-332: Remove's and Update's stop runs `server stop` only for a core
# identified from the kernel as an allowed hc; anything else is untouched.
rm -f "$SOCK" "$TMP/stub.argv"
HOME=$HOME_A "$LINK" stop --session c11-c11-b --socket "$SOCK" --hc "$HC" --sha "$PIN_SHA" >"$TMP/stop0.out" 2>&1 || fail "stop with no core ($(cat "$TMP/stop0.out"))"
grep -q '^stopped=none$' "$TMP/stop0.out" || fail "stop with no core said ($(cat "$TMP/stop0.out"))"
[ ! -f "$TMP/stub.argv" ] || fail "stop ran the client with no core serving"
/usr/bin/python3 -I - "$SOCK" <<'PY' &
import os, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
os.chdir(os.path.dirname(sys.argv[1]))
s.bind(os.path.basename(sys.argv[1])); s.listen(8); s.settimeout(6)
try:
    while True:
        c, _ = s.accept(); c.close()
except Exception:
    pass
PY
spid=$!
i=0; while [ ! -S "$SOCK" ] && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.05; done
set +e
HOME=$HOME_A "$LINK" stop --session c11-c11-b --socket "$SOCK" --hc "$HC" --sha "$PIN_SHA" >"$TMP/stop1.out" 2>&1; rc=$?
set -e
[ "$rc" = 8 ] || fail "stop of a foreign core exited $rc ($(cat "$TMP/stop1.out"))"
grep -q "^hc_serving_mismatch expected=$PIN_SHA found=[0-9a-f]\{64\} pid=$spid " "$TMP/stop1.out" || fail "foreign stop line ($(cat "$TMP/stop1.out"))"
[ ! -f "$TMP/stub.argv" ] || fail "server stop was sent to a foreign core"
ps -p "$spid" >/dev/null 2>&1 || fail "the foreign core was signalled"
set +e
HOME=$HOME_A "$LINK" stop --session c11-c11-b --socket "$SOCK" --hc "$HC" --sha "$WRONG" >"$TMP/stop2.out" 2>&1; rc=$?
set -e
[ "$rc" = 7 ] || fail "stop with an unchecked client exited $rc"
[ ! -f "$TMP/stub.argv" ] || fail "an unchecked client was run"
SERVING_SHA=$(/usr/bin/python3 -I -c 'import ctypes,hashlib,sys; b=ctypes.create_string_buffer(4096); ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidpath(int(sys.argv[1]), b, 4096); print(hashlib.sha256(open(b.value.decode(),"rb").read()).hexdigest())' "$spid")
HOME=$HOME_A "$LINK" stop --session c11-c11-b --socket "$SOCK" --hc "$HC" --sha "$PIN_SHA" --allow "$PIN_SHA,$SERVING_SHA" >"$TMP/stop3.out" 2>&1 \
  || fail "stop of an identified core failed ($(cat "$TMP/stop3.out"))"
printf '%s\n' "$HC" server stop > "$TMP/stop.want"
cmp -s "$TMP/stub.argv" "$TMP/stop.want" || fail "an identified core was not sent server stop ($(cat "$TMP/stub.argv" 2>/dev/null))"
wait "$spid" 2>/dev/null || true
rm -f "$SOCK" "$TMP/stub.argv"
ok "stop sends server stop only to a core identified as an allowed hc; a foreign one is untouched (exit 8)"

# C11H-332: the via names the far end's refusal with its machine, host and
# session in link-ssh.log; it writes nothing into c11's audit folder.
EXIT_SSH=$TMP/ssh-exit5
printf '#!/bin/sh\nexit 5\n' > "$EXIT_SSH"
chmod 755 "$EXIT_SSH"
"$LINK" render --mode ssh --out "$TMP/via-exit" --session c11-c11-b --socket "$SOCK" --hc "$HC" --sha "$WRONG" \
  --target me@studio.local --machine studio --ssh "$EXIT_SSH" --home "$HOME_A" --user tester
VHOME=$TMP/via-home
mkdir -p "$VHOME"
set +e
HOME=$VHOME "$TMP/via-exit" ignored; rc1=$?
set -e
[ "$rc1" = 5 ] || fail "via did not pass the far exit through ($rc1)"
grep -q 'status=5 .* reason=hc_hash_mismatch machine=studio host=me@studio.local session=c11-c11-b$' "$VHOME/Library/Application Support/c11/link-ssh.log" \
  || fail "link log line ($(cat "$VHOME/Library/Application Support/c11/link-ssh.log"))"
[ ! -e "$VHOME/Library/Application Support/c11/audit" ] || fail "the via wrote into the audit folder"
ok "the via names a refused dial with its machine, host and session, and leaves the audit to c11"

# C11H-332: there is no bridge mode: every via is an ssh via that carries the pin.
for sub in render pair; do
  set +e
  if [ "$sub" = render ]; then
    "$LINK" render --sha "$PIN_SHA" --mode bridge --out "$TMP/bridge-via" --session c11-c11-b --socket "$SOCK" --hc "$HC" >/dev/null 2>&1
  else
    HOME=$TMP/bridge-home "$LINK" pair --yes --sha "$PIN_SHA" --mode bridge --session c11-c11-b --shards 1 --hc "$HC" --home "$HOME_A" --user far >/dev/null 2>&1
  fi
  rc=$?
  set -e
  [ "$rc" = 2 ] || fail "$sub --mode bridge exited $rc"
done
[ ! -e "$TMP/bridge-via" ] && [ ! -e "$TMP/bridge-home/.local/share/c11/atlas-pair.json" ] || fail "a bridge render or pair wrote something"
ok "render and pair refuse --mode bridge"

# Without --target: C11_REMOTE_HOST wins over the dev-hosts file; unset everywhere, exit 2 naming it.
C11_REMOTE_HOST=envhost "$LINK" render --sha "$PIN_SHA" --mode ssh --out "$TMP/env-via" --session c11-c11-b --socket "$SOCK" \
  --hc "$HC" --home "$HOME_A" --user tester
grep -q -- '-- envhost ' "$TMP/env-via" || fail "C11_REMOTE_HOST did not name the ssh target"
"$LINK" render --sha "$PIN_SHA" --mode ssh --out "$TMP/file-via" --session c11-c11-b --socket "$SOCK" \
  --hc "$HC" --home "$HOME_A" --user tester
grep -q -- '-- studio ' "$TMP/file-via" || fail "the dev-hosts file did not name the ssh target"
set +e
C11_DEV_HOSTS=$TMP/no-such-file "$LINK" render --sha "$PIN_SHA" --mode ssh --out "$TMP/unset-via" --session c11-c11-b \
  --socket "$SOCK" --hc "$HC" --home "$HOME_A" --user tester >/dev/null 2>"$TMP/unset.err"
rc=$?
set -e
[ "$rc" = 2 ] || fail "render without a host exited $rc"
grep -q '^C11_REMOTE_HOST is unset' "$TMP/unset.err" || fail "unset host error does not name C11_REMOTE_HOST"
[ ! -e "$TMP/unset-via" ] || fail "render without a host wrote a via"
ok "the ssh host comes from --target, then C11_REMOTE_HOST, then the dev-hosts file; unset fails naming it"

# refuse to name herdr-app's binary or a foreign socket
set +e
"$LINK" render --sha "$PIN_SHA" --mode ssh --out "$TMP/no" --session c11 --socket "$HOME_A/.local/share/c11/run/c11.sock" \
  --hc "$HOME_A/.local/bin/herdr-core" --home "$HOME_A" --user tester >"$TMP/no.out" 2>"$TMP/no.err"
rc=$?
set -e
[ "$rc" = 2 ] || fail "herdr-app path was accepted"
set +e
"$LINK" render --sha "$PIN_SHA" --mode ssh --out "$TMP/no" --session default --socket "$HOME_A/.local/share/c11/run/default.sock" \
  --hc "$HC" --home "$HOME_A" --user tester >"$TMP/no2.out" 2>"$TMP/no2.err"
rc=$?
set -e
[ "$rc" = 2 ] || fail "session default was accepted"
ok "render refuses herdr-app's binary and session default"

# Keep the remote config spelling identical to the home derived from the
# helper path by linkPlan; refusal must happen before publishing a script.
set +e
"$LINK" render --sha "$PIN_SHA" --mode ssh --out "$TMP/trailing-home-via" --session c11-c11-b --socket "$SOCK" \
  --hc "$HC" --home "$HOME_A/" --user tester >"$TMP/trailing.out" 2>"$TMP/trailing.err"
rc=$?
set -e
[ "$rc" = 2 ] || fail "trailing home slash was accepted"
[ ! -e "$TMP/trailing-home-via" ] || fail "refused home published a via"
ok "render refuses a trailing home slash before writing"

# serve: one local connection runs the same remote command. No ssh, no guest.
cat > "$HC" <<EOF
#!/usr/bin/python3 -I
import os, resource, sys
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
base = "$TMP/stub"
open(base + ".soft", "w").write("%s\n" % soft)
open(base + ".hard", "w").write("%s\n" % hard)
with open(base + ".env", "w") as fh:
    for key in sorted(os.environ):
        fh.write("%s=%s\n" % (key, os.environ[key]))
with open(base + ".argv", "w") as fh:
    fh.write("\\n".join(sys.argv) + "\\n")
sys.stdout.write("served\\n")
sys.stdout.flush()
EOF
chmod 755 "$HC"
PIN_SHA=$(shasum -a 256 "$HC" | awk '{print $1}')
rm -f "$FAKE_MARK" "$TMP/stub.soft" "$TMP/stub.hard" "$TMP/stub.env" "$TMP/stub.argv"
LISTEN=/tmp/c11h13-serve-$$.sock
rm -f "$LISTEN"
# Bound the disposable listener through its Python process seam. A failed
# connection exits by socket timeout, so host tests never signal a process.
cat > "$TMP/serve-python" <<'PY'
#!/usr/bin/python3 -I
import socket, sys
socket.setdefaulttimeout(5)
sys.argv = sys.argv[2:]
exec(compile(sys.stdin.read(), "<serve>", "exec"))
PY
chmod 755 "$TMP/serve-python"
sed "s#exec /usr/bin/python3 -I - #exec $TMP/serve-python -I - #" "$LINK" > "$TMP/serve-link"
chmod 755 "$TMP/serve-link"
PATH="$TMP/fakebin:$HOME_A/.local/bin:/usr/bin:/bin" XDG_CONFIG_HOME=/local/app/config \
  XDG_DATA_HOME=/local/app/data SSH_AUTH_SOCK=/local/agent HC_LAUNCHD_DIRECT=1 "$TMP/serve-link" serve --sha "$PIN_SHA" \
  --listen "$LISTEN" --session c11-c11-b --socket "$SOCK" --hc "$HC" \
  --home "$HOME_A" --user tester >"$TMP/serve.out" 2>"$TMP/serve.err" &
spid=$!
i=0
while ! grep -q '^listening ' "$TMP/serve.err" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 50 ]; then
    wait "$spid" 2>/dev/null || true
    fail "serve did not listen ($(cat "$TMP/serve.err" 2>/dev/null))"
  fi
  ps -p "$spid" >/dev/null 2>&1 || fail "serve exited before listen ($(cat "$TMP/serve.err" 2>/dev/null))"
  sleep 0.05
done
/usr/bin/python3 -I - "$LISTEN" "$TMP/served.out" <<'PY'
import socket, sys
path, out = sys.argv[1], sys.argv[2]
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(5)
client.connect(path)
chunks = []
while True:
    piece = client.recv(64)
    if not piece:
        break
    chunks.append(piece)
open(out, "wb").write(b"".join(chunks))
PY
wait "$spid"
[ "$(cat "$TMP/served.out")" = "served" ] || fail "protocol bytes ($(cat "$TMP/served.out"))"
grep -q '^nofile ' "$TMP/serve.err" || fail "serve stderr missed the nofile log"
grep -q 'nofile' "$TMP/served.out" && fail "nofile log entered the protocol"
[ -f "$FAKE_MARK" ] && fail "serve ran the fake herdr-core"
grep -q '^HC_SPAWN_MS=10000$' "$TMP/stub.env" || fail "serve pin missed HC_SPAWN_MS"
grep -q '^PATH=/usr/bin:/bin:/usr/sbin:/sbin$' "$TMP/stub.env" || fail "serve pin PATH"
assert_core_config
grep -q 'fakebin' "$TMP/stub.env" && fail "serve pin inherited the dirty PATH"
printf '%s\n' "$HC" connect --session c11-c11-b > "$TMP/argv.want"
cmp -s "$TMP/stub.argv" "$TMP/argv.want" || fail "serve pin argv"
rm -f "$LISTEN"
ok "serve runs the remote command on one local socket"

long=/tmp/$(printf 'a%.0s' $(seq 1 120)).sock
set +e
"$LINK" serve --sha "$PIN_SHA" --listen "$long" --session c11-c11-b --socket "$SOCK" --hc "$HC" \
  --home "$HOME_A" --user tester >"$TMP/long.out" 2>"$TMP/long.err"
rc=$?
set -e
[ "$rc" = 2 ] || fail "overlong listen exited $rc"
[ ! -e "$long" ] || fail "overlong listen created a socket"
grep -q '103' "$TMP/long.err" || fail "overlong listen did not name the ceiling"
ok "serve refuses a listen socket past 103 bytes"

held=/tmp/c11h13-serve-held-$$.sock
rm -f "$held"
printf 'keep\n' > "$held"
set +e
"$LINK" serve --sha "$PIN_SHA" --listen "$held" --session c11-c11-b --socket "$SOCK" --hc "$HC" \
  --home "$HOME_A" --user tester >"$TMP/held.out" 2>"$TMP/held.err"
rc=$?
set -e
[ "$rc" = 2 ] || fail "existing listen path exited $rc"
[ "$(cat "$held")" = "keep" ] || fail "existing listen path was replaced"
rm -f "$held"
ok "serve leaves an existing listen path untouched"

# C11H-78 pair: one via per shard, each baking its own session; a pairing file listing them.
HOME_P=$TMP/phome; mkdir -p "$HOME_P"
PD=$HOME_P/.local/share/c11
REMOTE=/Users/far
RHC=$REMOTE/.local/share/c11/hc/0.1.16-abcdef123456/herdr-core
HOME=$HOME_P "$LINK" pair --yes --sha "$PIN_SHA" --mode ssh --session c11-c11-b --shards 3 --hc "$RHC" --home "$REMOTE" --user far \
  --ssh "$STUB" >/dev/null
[ "$(cd "$PD" && ls | tr '\n' ' ')" = "atlas-pair.json atlas-via-c11-c11-b-s1.sh atlas-via-c11-c11-b-s2.sh atlas-via-c11-c11-b-s3.sh " ] \
  || fail "pair wrote $(cd "$PD" && ls | tr '\n' ' ')"
python3 -I - "$PD" <<'PY' || fail "pairing file"
import json, sys
d = sys.argv[1]
m = json.load(open(d + "/atlas-pair.json"))
assert m["pairing"] == 1 and m["machine"] == "studio", m
want = {"c11-c11-b-s%d" % k: "%s/atlas-via-c11-c11-b-s%d.sh" % (d, k) for k in (1, 2, 3)}
assert m["vias"] == want, m["vias"]
PY
for k in 1 2 3; do
  v=$PD/atlas-via-c11-c11-b-s$k.sh
  [ "$(stat -f '%Lp' "$v")" = 700 ] || fail "via s$k mode $(stat -f '%Lp' "$v")"
  HOME=$HOME_P STUB_ARGS=$TMP/pair.args "$v" ignored
  grep -q "HC_SESSION=c11-c11-b-s$k " "$TMP/pair.args" || fail "via s$k does not bake its own session"
  grep -q "HC_SOCKET=$REMOTE/.local/share/c11/run/c11-c11-b-s$k.sock " "$TMP/pair.args" || fail "via s$k socket"
  grep -q " $RHC connect --session c11-c11-b-s$k" "$TMP/pair.args" || fail "via s$k connect session"
  [ "$(grep -c 'HC_SESSION=' "$TMP/pair.args")" = 1 ] || fail "via s$k names more than one session"
done
ok "pair renders one via per shard, each pairing its own session"

HOME=$HOME_P "$LINK" pair --yes --sha "$PIN_SHA" --mode ssh --session c11-c11-b --shards 2 --hc "$RHC" --home "$REMOTE" --user far \
  --ssh "$STUB" >/dev/null || fail "re-pair over its own files"
grep -q "sha256=$PIN_SHA $RHC connect --session c11-c11-b-s2" "$PD/atlas-via-c11-c11-b-s2.sh" || fail "re-paired via carries the pin per shard"
python3 -I -c 'import json,sys; assert sorted(json.load(open(sys.argv[1]))["vias"]) == ["c11-c11-b-s1","c11-c11-b-s2"]' "$PD/atlas-pair.json" \
  || fail "re-pair file"
[ ! -e "$PD/atlas-via-c11-c11-b-s3.sh" ] || fail "re-pair with fewer shards left the s3 via"
ok "re-pair replaces its own vias, drops ones no longer paired; each carries the pin"

printf 'hand\n' > "$PD/atlas-via-c11-c11-b-s4.sh"
set +e
HOME=$HOME_P "$LINK" pair --yes --sha "$PIN_SHA" --mode ssh --session c11-c11-b --shards 4 --hc "$RHC" --home "$REMOTE" --user far \
  --ssh "$STUB" >/dev/null 2>"$TMP/pair4.err"
rc=$?
set -e
[ "$rc" = 2 ] || fail "pair over a foreign via exited $rc"
[ "$(cat "$PD/atlas-via-c11-c11-b-s4.sh")" = hand ] || fail "pair replaced a via it did not write"
python3 -I -c 'import json,sys; assert len(json.load(open(sys.argv[1]))["vias"]) == 2' "$PD/atlas-pair.json" || fail "a refused pair changed the file"
grep -q 'did not write it' "$TMP/pair4.err" || fail "refusal not explained"
ok "pair refuses, writing nothing, when a via path holds a file it did not write"

for bad in 0 9 x; do
  set +e; HOME=$HOME_P "$LINK" pair --yes --sha "$PIN_SHA" --mode ssh --session c11-c11-b --shards $bad --hc "$RHC" --home "$REMOTE" --user far >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = 2 ] || fail "--shards $bad exited $rc"
done
set +e; HOME=$HOME_P "$LINK" pair --yes --sha "$PIN_SHA" --mode ssh --session default --shards 1 --hc "$RHC" --home "$REMOTE" --user far >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 2 ] || fail "pair accepted session default"
ok "pair refuses bad shard counts and the default session"

# C11H-397: pair renders every shard's via for the other machine's platform,
# as Add Machine renders a link: --platform linux bakes bash and the C locale,
# the default a Mac's zsh; another platform writes nothing.
HOME_L=$TMP/lhome; mkdir -p "$HOME_L"
HOME=$HOME_L "$LINK" pair --yes --sha "$PIN_SHA" --mode ssh --session c11-c11-b --shards 2 --hc "$RHC" --home "$REMOTE" --user far \
  --target studio --ssh "$STUB" --platform linux >/dev/null || fail "pair --platform linux failed"
for k in 1 2; do
  v=$HOME_L/.local/share/c11/atlas-via-c11-c11-b-s$k.sh
  { grep -q 'SHELL=/bin/bash LANG=C.UTF-8' "$v" && ! grep -q 'SHELL=/bin/zsh' "$v"; } || fail "pair --platform linux: via s$k is not a Linux via"
  grep -q "sha256=$PIN_SHA $RHC connect --session c11-c11-b-s$k" "$v" || fail "pair --platform linux: via s$k lost its pin or session"
done
{ grep -q 'SHELL=/bin/zsh LANG=en_US.UTF-8' "$PD/atlas-via-c11-c11-b-s1.sh" && ! grep -q 'SHELL=/bin/bash' "$PD/atlas-via-c11-c11-b-s1.sh"; } \
  || fail "pair's default via is not a Mac's"
set +e
HOME=$TMP/badplat-home "$LINK" pair --yes --sha "$PIN_SHA" --mode ssh --session c11-c11-b --shards 1 --hc "$RHC" --home "$REMOTE" \
  --user far --target studio --ssh "$STUB" --platform windows >/dev/null 2>"$TMP/badplat.err"
rc=$?
set -e
{ [ "$rc" = 2 ] && [ ! -e "$TMP/badplat-home/.local/share/c11/atlas-pair.json" ] \
    && [ ! -e "$TMP/badplat-home/.local/share/c11/atlas-via-c11-c11-b-s1.sh" ] && grep -q "platform must be mac or linux" "$TMP/badplat.err"; } \
  || fail "pair --platform windows: rc=$rc $(cat "$TMP/badplat.err")"
ok "pair renders its vias for --platform linux as Add Machine does, a Mac's by default"

# C11H-365: pair writes the manifest only after the operator's answer (a typed
# yes on a terminal, or --yes outside a c11 terminal), and the manifest says
# so inside its own hash. Each refusal writes nothing.
AH=$TMP/ack-home; AD=$AH/.local/share/c11
mkdir -p "$AH"
# The pair arguments of every case below, as this script's positional parameters.
set -- --sha "$PIN_SHA" --mode ssh --session c11-c11-b --shards 2 --hc "$RHC" --home "$REMOTE" --user far \
  --target me@far.example --machine farbox --ssh "$STUB"
nothing_paired() { [ ! -e "$AD/atlas-pair.json" ] && [ ! -e "$AD/atlas-via-c11-c11-b-s1.sh" ] && [ ! -e "$AD/atlas-via-c11-c11-b-s2.sh" ]; }
acknowledged_manifest() {
  /usr/bin/python3 -I - "$AD/atlas-pair.json" <<'PY'
import hashlib, json, sys
raw = open(sys.argv[1], "rb").read()
m = json.loads(raw)
assert type(m.get("acknowledged")) is int and m["acknowledged"] == 1, m
own = m["self_sha256"]
field = b'"self_sha256":"' + own.encode() + b'"'
assert raw.count(field) == 1 and hashlib.sha256(raw.replace(field, b'"self_sha256":""')).hexdigest() == own, "self hash"
assert m["machine"] == "farbox" and len(m["vias"]) == 2, m
PY
}
set +e; HOME=$AH "$LINK" pair "$@" </dev/null >/dev/null 2>"$TMP/ack-notty.err"; rc=$?; set -e
[ "$rc" = 2 ] || fail "pair with no terminal and no --yes exited $rc"
grep -q "needs the operator's answer on a terminal" "$TMP/ack-notty.err" || fail "no-terminal refusal ($(cat "$TMP/ack-notty.err"))"
nothing_paired || fail "pair with no terminal and no --yes wrote something"
for var in C11_PANEL_ID C11_SURFACE_ID CMUX_SURFACE_ID; do
  set +e; env "$var=11111111-2222-4333-8444-555555555555" HOME="$AH" "$LINK" pair --yes "$@" </dev/null >/dev/null 2>"$TMP/ack-c11.err"; rc=$?; set -e
  [ "$rc" = 2 ] || fail "pair --yes inside a c11 terminal ($var) exited $rc"
  grep -q "isn't accepted inside a c11 terminal" "$TMP/ack-c11.err" || fail "c11-terminal refusal ($var: $(cat "$TMP/ack-c11.err"))"
  nothing_paired || fail "pair --yes inside a c11 terminal ($var) wrote something"
done
ok "pair writes nothing without a terminal answer, and refuses --yes inside a c11 terminal"

# A typed answer on a fresh pseudo-terminal. The question names the machine,
# the shard count and the ssh target; n writes nothing, y pairs. The driver
# never signals the child: closing the terminal ends a read still waiting.
cat > "$TMP/pty-answer" <<'PY'
#!/usr/bin/python3 -I
import os, select, subprocess, sys, time
answer, transcript, argv = sys.argv[1], sys.argv[2], sys.argv[3:]
master, slave = os.openpty()
child = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
seen, sent, deadline = b"", False, time.monotonic() + 20
while time.monotonic() < deadline:
    ready, _, _ = select.select([master], [], [], 0.1)
    if ready:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            chunk = b""
        if not chunk:
            break
        seen += chunk
        if not sent and b"[y/N]" in seen:
            os.write(master, answer.encode() + b"\n")
            sent = True
    elif child.poll() is not None:
        break
os.close(master)
status = child.wait(timeout=20)
open(transcript, "wb").write(seen)
sys.exit(status)
PY
chmod 755 "$TMP/pty-answer"
set +e; HOME=$AH "$TMP/pty-answer" n "$TMP/ack-n.tty" "$LINK" pair "$@"; rc=$?; set -e
[ "$rc" = 2 ] || fail "a typed no exited $rc ($(cat "$TMP/ack-n.tty"))"
grep -Fq 'Pair 2 shard(s), c11-c11-b-s1..s2, with farbox through ssh to me@far.example? [y/N]' "$TMP/ack-n.tty" \
  || fail "the question does not name the machine, shard count and ssh target ($(cat "$TMP/ack-n.tty"))"
grep -Fq 'gives c11 a shell on me@far.example as you' "$TMP/ack-n.tty" || fail "the question does not say what pairing gives"
grep -q 'not confirmed; nothing written' "$TMP/ack-n.tty" || fail "a typed no said ($(cat "$TMP/ack-n.tty"))"
nothing_paired || fail "a typed no wrote something"
HOME=$AH "$TMP/pty-answer" y "$TMP/ack-y.tty" "$LINK" pair "$@" || fail "a typed yes failed ($(cat "$TMP/ack-y.tty"))"
grep -q 'paired c11-c11-b-s1..s2 with farbox' "$TMP/ack-y.tty" || fail "a typed yes said ($(cat "$TMP/ack-y.tty"))"
acknowledged_manifest || fail "a typed yes wrote no acknowledged, self-hashed manifest"
HOME=$AH "$LINK" unpair >/dev/null
nothing_paired || fail "unpair left an acknowledged pairing behind"
ok "pair asks on a terminal, naming the machine, shard count and ssh target; only a typed yes pairs"

HOME=$AH "$LINK" pair --yes "$@" </dev/null >/dev/null || fail "pair --yes outside a c11 terminal failed"
acknowledged_manifest || fail "pair --yes wrote no acknowledged, self-hashed manifest"
# A manifest from before C11H-365 (no acknowledged field, its own hash intact)
# is still pair's own: pairing again records the answer.
/usr/bin/python3 -I - "$AD/atlas-pair.json" <<'PY' || fail "old manifest fixture"
import hashlib, json, sys
p = sys.argv[1]; m = json.load(open(p)); del m["acknowledged"]
m["self_sha256"] = ""
enc = lambda: (json.dumps(m, separators=(",", ":")) + "\n").encode()
m["self_sha256"] = hashlib.sha256(enc()).hexdigest()
open(p, "wb").write(enc())
PY
HOME=$AH "$LINK" pair --yes "$@" </dev/null >/dev/null || fail "re-pair over a manifest without acknowledged failed"
acknowledged_manifest || fail "re-pair did not record the answer"
HOME=$AH "$LINK" unpair >/dev/null
set --
ok "pair --yes outside a c11 terminal writes an acknowledged, self-hashed manifest; an older one re-pairs"

HOME=$HOME_P "$LINK" unpair >/dev/null
[ "$(cd "$PD" && ls | tr '\n' ' ')" = "atlas-via-c11-c11-b-s4.sh " ] || fail "unpair left $(cd "$PD" && ls | tr '\n' ' ')"
HOME=$HOME_P "$LINK" unpair | grep -q 'nothing removed' || fail "second unpair"
ok "unpair removes only the vias its file lists, then the file"

# A recorded path is not ownership after an operator replaces the via.
pair_again() { HOME=$HOME_P "$LINK" pair --yes --sha "$PIN_SHA" --mode ssh --session c11-c11-b --shards 2 --hc "$RHC" --home "$REMOTE" --user far --ssh "$STUB"; }
pair_again >/dev/null
v1="$PD/atlas-via-c11-c11-b-s1.sh"
printf 'operator via\n' > "$v1"
pair_before=$(shasum "$PD/atlas-pair.json" "$v1")
if pair_again >/dev/null 2>&1; then fail "re-pair overwrote an edited via"; fi
[ "$(shasum "$PD/atlas-pair.json" "$v1")" = "$pair_before" ] || fail "refused re-pair changed bytes"
HOME=$HOME_P "$LINK" unpair >/dev/null
[ "$(cat "$v1")" = 'operator via' ] || fail "unpair removed the edited via"
[ ! -e "$PD/atlas-via-c11-c11-b-s2.sh" ] || fail "unpair left unchanged via"
ok "re-pair and unpair preserve an operator-edited via"
rm -f "$v1"

pair_again >/dev/null
# A same-content symlink is still not owned; writing it would alter another file.
cp "$v1" "$TMP/other-via"
rm "$v1"; ln -s "$TMP/other-via" "$v1"
other_before=$(shasum "$TMP/other-via")
if pair_again >/dev/null 2>&1; then fail "re-pair accepted a symlinked via"; fi
[ "$(shasum "$TMP/other-via")" = "$other_before" ] || fail "re-pair changed the symlink target"
HOME=$HOME_P "$LINK" unpair >/dev/null
[ -L "$v1" ] || fail "unpair removed the operator symlink"
ok "pair operations never follow or claim a symlinked via"
rm -f "$v1"

pair_again >/dev/null
python3 -I - "$PD/atlas-pair.json" <<'PYEDIT'
import sys
p=sys.argv[1]
s=open(p).read(); open(p,'w').write(s.replace('"machine":"studio"','"machine":"operator"'))
PYEDIT
pair_before=$(shasum "$PD/atlas-pair.json" "$v1")
if pair_again >/dev/null 2>&1; then fail "re-pair accepted an edited manifest"; fi
HOME=$HOME_P "$LINK" unpair >/dev/null
[ "$(shasum "$PD/atlas-pair.json" "$v1")" = "$pair_before" ] || fail "unpair changed an edited manifest's files"
ok "an edited pairing manifest authorizes no writes or removal"

rm -f "$PD/atlas-pair.json" "$v1" "$PD/atlas-via-c11-c11-b-s2.sh"
pair_again >/dev/null
pair_before=$(shasum "$PD/atlas-pair.json" "$v1")
mv "$PD" "$TMP/other-pairs"
ln -s "$TMP/other-pairs" "$PD"
if pair_again >/dev/null 2>&1; then fail "pair accepted a symlinked pairing directory"; fi
HOME=$HOME_P "$LINK" unpair >/dev/null
[ "$(shasum "$PD/atlas-pair.json" "$v1")" = "$pair_before" ] || fail "unpair followed a symlinked directory"
ok "pair operations never follow a symlinked directory"

# C11H-361: ssh itself, running the via's own ssh line against a config that
# forwards everything, resolves every forwarding off. `ssh -G` prints the
# resolved config and exits: no connection, and -F keeps every other config out.
# The config says `ForwardAgent yes`, not a socket path: with a path, ssh -G
# prints that path even under -o ForwardAgent=no, while the agent request
# follows the flag the command line set to no.
if [ -x /usr/bin/ssh ]; then
  cat > "$TMP/hostile_ssh_config" <<'HOSTILE'
Host *
  ForwardAgent yes
  ForwardX11 yes
  LocalForward 9999 localhost:22
  RemoteForward 9998 localhost:22
  DynamicForward 9997
  PermitLocalCommand yes
  LocalCommand true
  GSSAPIDelegateCredentials yes
HOSTILE
  GSTUB=$TMP/ssh-g
  cat > "$GSTUB" <<'GSTUBEND'
#!/bin/sh
exec /usr/bin/ssh -G -F "$HOSTILE_CONFIG" "$@" > "$G_OUT" 2>&1
GSTUBEND
  chmod 755 "$GSTUB"
  "$LINK" render --sha "$PIN_SHA" --mode ssh --out "$TMP/g-via" --session c11-c11-b --socket "$SOCK" --hc "$HC" \
    --target studio --ssh "$GSTUB" --home "$HOME_A" --user tester
  HOME=$HOME_A HOSTILE_CONFIG=$TMP/hostile_ssh_config G_OUT=$TMP/g.out "$TMP/g-via" ignored </dev/null \
    || fail "ssh -G of the via's line failed ($(cat "$TMP/g.out"))"
  for want in 'forwardagent no' 'forwardx11 no' 'clearallforwardings yes' 'permitlocalcommand no' 'controlmaster false'; do
    grep -qx "$want" "$TMP/g.out" || fail "via's ssh did not resolve '$want' ($(grep -E '^(forward|clear|permit|control)' "$TMP/g.out" | tr '\n' ' '))"
  done
  if grep -q '^gssapidelegatecredentials yes' "$TMP/g.out"; then fail "via's ssh still delegates GSSAPI credentials"; fi
  if grep -Eq '^(localforward|remoteforward|dynamicforward) ' "$TMP/g.out"; then fail "a port forward survived in the via's ssh"; fi
  ok "the via's ssh resolves every forwarding off against a config that forwards everything"
fi

# C11H-332: migrate re-renders an older c11's pinless via with the pin,
# keeping its pairing manifest's ownership, so `pair --sha` still works.
MH=$TMP/mhome; MD=$MH/.local/share/c11
mkdir -p "$MD"
strip_pin() { /usr/bin/sed -E -i '' 's/sha256=[0-9a-f]{64} //' "$1"; }
HOME=$MH "$LINK" render --sha "$PIN_SHA" --mode ssh --out "$MD/vias/far-via.sh" --session c11-c11-b \
  --socket "$REMOTE/.local/share/c11/run/c11-c11-b.sock" --hc "$RHC" --target me@far --ssh "$STUB" --home "$REMOTE" --user far
strip_pin "$MD/vias/far-via.sh"
grep -q 'sha256=' "$MD/vias/far-via.sh" && fail "fixture still has a pin"
HOME=$MH "$LINK" migrate --via "$MD/vias/far-via.sh" --sha "$PIN_SHA" --machine far >"$TMP/mig1.out" || fail "migrate failed ($(cat "$TMP/mig1.out"))"
grep -q "^migrated $MD/vias/far-via.sh\$" "$TMP/mig1.out" || fail "migrate said ($(cat "$TMP/mig1.out"))"
grep -q " sha256=$PIN_SHA $RHC connect --session c11-c11-b" "$MD/vias/far-via.sh" || fail "migrated via lacks the pin"
grep -q -- "-- me@far '" "$MD/vias/far-via.sh" || fail "migrated via lost its target"
grep -q "HC_SOCKET=$REMOTE/.local/share/c11/run/c11-c11-b.sock " "$MD/vias/far-via.sh" || fail "migrated via lost its socket"
[ "$(stat -f '%Lp' "$MD/vias/far-via.sh")" = 700 ] || fail "migrated via mode"
HOME=$MH "$LINK" migrate --via "$MD/vias/far-via.sh" --sha "$PIN_SHA" >"$TMP/mig2.out" || fail "second migrate failed"
grep -q '^pinned ' "$TMP/mig2.out" || fail "a pinned via was rewritten ($(cat "$TMP/mig2.out"))"
ok "migrate re-renders an older c11's pinless via with the pin, from its own values"

# C11H-361: a pinned via an older c11 rendered with forwarding left to
# ~/.ssh/config is re-rendered with the switches and its own pin, never
# --sha's (its hc path names that pin's version).
OWN_SHA=$(printf 'an older pin\n' | shasum -a 256 | awk '{print $1}')
HOME=$MH "$LINK" render --sha "$OWN_SHA" --mode ssh --out "$MD/vias/old-via.sh" --session c11-c11-b \
  --socket "$REMOTE/.local/share/c11/run/c11-c11-b.sock" --hc "$RHC" --target me@far --ssh "$STUB" --home "$REMOTE" --user far
/usr/bin/sed -i '' 's/ -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no -k / /' "$MD/vias/old-via.sh"
if grep -q 'ForwardAgent' "$MD/vias/old-via.sh"; then fail "fixture still turns forwarding off"; fi
HOME=$MH "$LINK" migrate --via "$MD/vias/old-via.sh" --sha "$PIN_SHA" --machine far >"$TMP/mig3.out" || fail "forwarding migrate failed ($(cat "$TMP/mig3.out"))"
grep -q "^migrated $MD/vias/old-via.sh\$" "$TMP/mig3.out" || fail "forwarding migrate said ($(cat "$TMP/mig3.out"))"
grep -q -- ' -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no -k -- me@far ' "$MD/vias/old-via.sh" \
  || fail "migrated via still forwards"
grep -q " sha256=$OWN_SHA $RHC connect --session c11-c11-b" "$MD/vias/old-via.sh" || fail "migrated via lost its own pin"
if grep -q "sha256=$PIN_SHA" "$MD/vias/old-via.sh"; then fail "migrated via took --sha over its own pin"; fi
HOME=$MH "$LINK" migrate --via "$MD/vias/old-via.sh" --sha "$PIN_SHA" >"$TMP/mig4.out" || fail "second forwarding migrate failed"
grep -q '^pinned ' "$TMP/mig4.out" || fail "a current via was rewritten ($(cat "$TMP/mig4.out"))"
ok "migrate turns forwarding off in an older c11's pinned via, keeping its own pin"

# C11H-392: migrate keeps a Linux machine's via a Linux via (bash and the C
# locale), and render takes no platform but mac and linux.
HOME=$MH "$LINK" render --sha "$OWN_SHA" --mode ssh --platform linux --out "$MD/vias/lin-via.sh" --session c11-c11-b \
  --socket "$REMOTE/.local/share/c11/run/c11-c11-b.sock" --hc "$RHC" --target me@lin --ssh "$STUB" --home "$REMOTE" --user lin
/usr/bin/sed -i '' 's/ -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no -k / /' "$MD/vias/lin-via.sh"
HOME=$MH "$LINK" migrate --via "$MD/vias/lin-via.sh" --sha "$PIN_SHA" --machine lin >"$TMP/mig6.out" || fail "Linux migrate failed ($(cat "$TMP/mig6.out"))"
grep -q "^migrated $MD/vias/lin-via.sh\$" "$TMP/mig6.out" || fail "Linux migrate said ($(cat "$TMP/mig6.out"))"
grep -q 'SHELL=/bin/bash LANG=C.UTF-8 ' "$MD/vias/lin-via.sh" || fail "migrate lost the via's Linux platform"
if grep -q 'SHELL=/bin/zsh' "$MD/vias/lin-via.sh"; then fail "a migrated Linux via bakes zsh"; fi
ok "migrate keeps a Linux machine's via a Linux via"
if HOME=$MH "$LINK" render --sha "$PIN_SHA" --mode ssh --platform windows --out "$TMP/via-win" --session c11-c11-b \
     --socket "$REMOTE/.local/share/c11/run/c11-c11-b.sock" --hc "$RHC" --target me@far --ssh "$STUB" --home "$REMOTE" --user far 2>"$TMP/win.err"; then
  fail "render took --platform windows"
fi
[ ! -e "$TMP/via-win" ] || fail "a refused platform wrote a via"
grep -q 'platform must be mac or linux' "$TMP/win.err" || fail "render's platform refusal said ($(cat "$TMP/win.err"))"
ok "render refuses a platform other than mac or linux, writing nothing"

# A paired via: an older pinless pairing (manifest owning the pinless bytes).
HOME=$MH "$LINK" pair --yes --sha "$PIN_SHA" --mode ssh --session c11-c11-b --shards 2 --hc "$RHC" --home "$REMOTE" --user far \
  --target me@far --ssh "$STUB" >/dev/null || fail "pair fixture"
for k in 1 2; do strip_pin "$MD/atlas-via-c11-c11-b-s$k.sh"; done
/usr/bin/python3 -I - "$MD/atlas-pair.json" <<'PY' || fail "old manifest fixture"
import hashlib, json, sys
p = sys.argv[1]; m = json.load(open(p))
for via in m["vias"].values():
    m["file_sha256"][via] = hashlib.sha256(open(via, "rb").read()).hexdigest()
m["self_sha256"] = ""
enc = lambda: (json.dumps(m, separators=(",", ":")) + "\n").encode()
m["self_sha256"] = hashlib.sha256(enc()).hexdigest()
open(p, "wb").write(enc())
PY
HOME=$MH "$LINK" migrate --via "$MD/atlas-via-c11-c11-b-s1.sh" --sha "$PIN_SHA" --machine far | grep -q '^migrated ' || fail "paired migrate"
grep -q "sha256=$PIN_SHA " "$MD/atlas-via-c11-c11-b-s1.sh" || fail "paired via lacks the pin"
HOME=$MH "$LINK" pair --yes --sha "$PIN_SHA" --mode ssh --session c11-c11-b --shards 2 --hc "$RHC" --home "$REMOTE" --user far \
  --target me@far --ssh "$STUB" >"$TMP/repair.out" 2>&1 || fail "pair --sha after migrate failed ($(cat "$TMP/repair.out"))"
grep -q "sha256=$PIN_SHA " "$MD/atlas-via-c11-c11-b-s2.sh" || fail "re-pair did not pin s2"
# An edited paired via is not the manifest's: refused, nothing changed.
strip_pin "$MD/atlas-via-c11-c11-b-s2.sh"; printf '# edited\n' >> "$MD/atlas-via-c11-c11-b-s2.sh"
before=$(shasum -a 256 "$MD/atlas-via-c11-c11-b-s2.sh" "$MD/atlas-pair.json")
set +e
HOME=$MH "$LINK" migrate --via "$MD/atlas-via-c11-c11-b-s2.sh" --sha "$PIN_SHA" >"$TMP/mig5.out" 2>&1; rc=$?
set -e
[ "$rc" = 5 ] || fail "migrate of an unowned paired via exited $rc ($(cat "$TMP/mig5.out"))"
[ "$(shasum -a 256 "$MD/atlas-via-c11-c11-b-s2.sh" "$MD/atlas-pair.json")" = "$before" ] || fail "a refused migrate changed something"
ok "migrating a paired via keeps the pairing, so pair --sha works after; an unowned one is refused (exit 5)"

# Two shards migrating at once (ordinary parallel shard startup) must not lose
# either ownership hash: the pairing lock serializes them. Four trials; without
# the lock most trials lose one hash and the re-pair fails.
old_pairing() {
  /bin/rm -f "$MD"/atlas-via-c11-c11-b-s*.sh "$MD/atlas-pair.json"
  HOME=$MH "$LINK" pair --yes --sha "$PIN_SHA" --mode ssh --session c11-c11-b --shards 2 --hc "$RHC" --home "$REMOTE" --user far \
    --target me@far --ssh "$STUB" >/dev/null || fail "pair fixture"
  for k in 1 2; do strip_pin "$MD/atlas-via-c11-c11-b-s$k.sh"; done
  /usr/bin/python3 -I - "$MD/atlas-pair.json" <<'PY' || fail "old manifest fixture"
import hashlib, json, sys
p = sys.argv[1]; m = json.load(open(p))
for via in m["vias"].values():
    m["file_sha256"][via] = hashlib.sha256(open(via, "rb").read()).hexdigest()
m["self_sha256"] = ""
enc = lambda: (json.dumps(m, separators=(",", ":")) + "\n").encode()
m["self_sha256"] = hashlib.sha256(enc()).hexdigest()
open(p, "wb").write(enc())
PY
}
for trial in 1 2 3 4; do
  old_pairing
  HOME=$MH "$LINK" migrate --via "$MD/atlas-via-c11-c11-b-s1.sh" --sha "$PIN_SHA" --machine far >"$TMP/cm1.out" 2>&1 & m1=$!
  HOME=$MH "$LINK" migrate --via "$MD/atlas-via-c11-c11-b-s2.sh" --sha "$PIN_SHA" --machine far >"$TMP/cm2.out" 2>&1 & m2=$!
  wait "$m1" || fail "concurrent migrate s1 failed in trial $trial ($(cat "$TMP/cm1.out"))"
  wait "$m2" || fail "concurrent migrate s2 failed in trial $trial ($(cat "$TMP/cm2.out"))"
  /usr/bin/python3 -I - "$MD/atlas-pair.json" <<'PY' || fail "trial $trial: the manifest lost a migrated via's hash"
import hashlib, json, sys
m = json.load(open(sys.argv[1]))
for via in m["vias"].values():
    if m["file_sha256"].get(via) != hashlib.sha256(open(via, "rb").read()).hexdigest():
        sys.exit(1)
PY
  HOME=$MH "$LINK" pair --yes --sha "$PIN_SHA" --mode ssh --session c11-c11-b --shards 2 --hc "$RHC" --home "$REMOTE" --user far \
    --target me@far --ssh "$STUB" >"$TMP/cpair.out" 2>&1 || fail "trial $trial: pair --sha after concurrent migrates failed ($(cat "$TMP/cpair.out"))"
done
ok "two shards migrating at once keep both ownership hashes, and pair --sha works after"

# Outside c11's folder, or not a via it can read: refused, untouched.
cp "$MD/vias/far-via.sh" "$TMP/outside-via.sh"; strip_pin "$TMP/outside-via.sh"
set +e
HOME=$MH "$LINK" migrate --via "$TMP/outside-via.sh" --sha "$PIN_SHA" >/dev/null 2>&1; rc3=$?
printf '#!/bin/sh\nexec something-else\n' > "$MD/vias/odd-via.sh"
HOME=$MH "$LINK" migrate --via "$MD/vias/odd-via.sh" --sha "$PIN_SHA" >/dev/null 2>&1; rc4=$?
set -e
[ "$rc3" = 3 ] || fail "outside via exited $rc3"
[ "$rc4" = 4 ] || fail "unparseable via exited $rc4"
grep -q 'sha256=' "$TMP/outside-via.sh" && fail "an outside via was changed"
ok "migrate refuses a via outside ~/.local/share/c11 (exit 3) and one it can't read (exit 4)"

# ssh exit log: status, signal, local time, how long it was up.
# The file is c11 state, not hc's share directory, and it stays bounded.
LOG="$HOME_A/Library/Application Support/c11/link-ssh.log"
rm -f "$LOG"
# Bridge rendering replaced the via script. Render the ssh one again.
"$LINK" render --sha "$PIN_SHA" --mode ssh --out "$VIA" \
  --session c11-c11-b --socket "$SOCK" --hc "$HC" \
  --target studio --ssh "$STUB" --home "$HOME_A" --user tester
cat > "$STUB" <<'EOF'
#!/bin/sh
sleep 1
exit 7
EOF
chmod 755 "$STUB"
set +e
HOME=$HOME_A "$VIA" ignored-remote-line >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 7 ] || fail "logged ssh exit was $rc"
[ -f "$LOG" ] || fail "ssh exit log was not written"
[ ! -e "$HOME_A/.local/share/c11/link-ssh.log" ] || fail "ssh exit log landed in the hc share directory"
zone=$(date +%z)
grep -q "time=.*${zone} status=7 signal=- up_s=" "$LOG" || fail "exit line ($(cat "$LOG"))"
up=$(awk -F 'up_s=' 'NR==1 { split($2, a, " "); print a[1] }' "$LOG")
grep -q ' reason=- machine=' "$LOG" || fail "a plain exit named a reason ($(cat "$LOG"))"
[ "$up" -ge 1 ] || fail "up_s was $up"
# a log write that cannot create its file stays off stderr and keeps ssh's status
badhome=$TMP/not-a-home
rm -rf "$badhome"
printf 'x' > "$badhome"
cat > "$STUB" <<'EOF'
#!/bin/sh
exit 5
EOF
chmod 755 "$STUB"
set +e
HOME=$badhome "$VIA" ignored >/dev/null 2>"$TMP/badhome.err"
rc=$?
set -e
[ "$rc" = 5 ] || fail "unwritable home exited $rc"
[ ! -s "$TMP/badhome.err" ] || fail "log error reached stderr ($(cat "$TMP/badhome.err"))"
ok "a failed log write stays silent and keeps ssh's status"
# a second exit appends, and a simulated signal death records the signal.
# Source the ACTUAL generated body under shell shims. The harmless ssh stub
# exits normally; wait supplies the signal status, trap records each handler,
# and kill only records requests. No signal reaches any host process.
cat > "$STUB" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$STUB"
cat > "$TMP/signal-driver" <<'EOF'
#!/bin/bash
alive=yes
trap() {
  if [ "$1" = - ]; then
    [ "$*" = '- TERM HUP INT' ] || exit 91
    printf 'trap reset TERM HUP INT\n' >> "$SHIM_CALLS"
    return 0
  fi
  [ "$#" = 2 ] || exit 92
  printf 'trap set %s\n' "$2" >> "$SHIM_CALLS"
  case "$2" in
    TERM) term_handler=$1 ;;
    HUP) hup_handler=$1 ;;
    INT) int_handler=$1 ;;
    *) exit 93 ;;
  esac
}
kill() {
  [ "$#" = 2 ] || exit 94
  if [ "$2" = "$child" ]; then
    target=child
  elif [ "$2" = "$$" ]; then
    target=self
  else
    exit 95
  fi
  printf 'kill %s %s\n' "$1" "$target" >> "$SHIM_CALLS"
  case "$1:$target" in
    -0:child) [ "$alive" = yes ] ;;
    -TERM:child|-HUP:child|-INT:child) return 0 ;;
    -15:self|-1:self|-2:self) return 0 ;;
    *) exit 96 ;;
  esac
}
wait() {
  [ "$#" = 1 ] && [ "$1" = "$child" ] || exit 97
  printf 'wait child\n' >> "$SHIM_CALLS"
  # Reap the short-lived harmless stub, then simulate the wait result.
  builtin wait "$1" || exit 98
  if [ "$SHIM_MODE" = forward ]; then
    case "$SHIM_SIGNAL" in
      TERM) eval "$term_handler" ;;
      HUP) eval "$hup_handler" ;;
      INT) eval "$int_handler" ;;
    esac
  fi
  alive=no
  return "$SHIM_STATUS"
}
. "$SHIM_VIA" ignored
EOF
signal_case() {
  mode=$1 signame=$2 signum=$3
  status=$((128 + signum))
  calls=$TMP/signal-$mode-$signame.calls
  : > "$calls"
  set +e
  HOME=$HOME_A SHIM_MODE=$mode SHIM_SIGNAL=$signame SHIM_STATUS=$status \
    SHIM_CALLS=$calls SHIM_VIA=$VIA /bin/bash "$TMP/signal-driver" >"$TMP/signal.out" 2>"$TMP/signal.err"
  rc=$?
  set -e
  [ "$rc" = "$status" ] || fail "$mode $signame exited $rc ($(cat "$TMP/signal.err"))"
  {
    printf 'trap set TERM\ntrap set HUP\ntrap set INT\nkill -0 child\nwait child\n'
    if [ "$mode" = forward ]; then printf 'kill -%s child\n' "$signame"; fi
    printf 'kill -0 child\ntrap reset TERM HUP INT\nkill -%s self\n' "$signum"
  } > "$TMP/signal.want"
  cmp -s "$calls" "$TMP/signal.want" || fail "$mode $signame shim calls ($(cat "$calls"))"
  tail -1 "$LOG" | grep -q "status=$status signal=$signum up_s=" || fail "$mode $signame log line"
}
signal_case child TERM 15
[ "$(wc -l < "$LOG" | awk '{print $1}')" = 2 ] || fail "log did not append ($(wc -l < "$LOG"))"
signal_case forward TERM 15
signal_case forward HUP 1
signal_case forward INT 2
ok "generated via forwards TERM/HUP/INT, resets traps and re-raises through signal shims"
# over the cap, the new line remains and the file is bounded
python3 -I - "$LOG" <<'PY'
import sys
path = sys.path[0] if False else sys.argv[1]
line = b"time=2000-01-01T00:00:00+0000 status=0 signal=- up_s=0\n"
with open(path, "wb") as fh:
    while fh.tell() < 70000:
        fh.write(line)
PY
cat > "$STUB" <<'EOF'
#!/bin/sh
exit 9
EOF
chmod 755 "$STUB"
set +e
HOME=$HOME_A "$VIA" ignored >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 9 ] || fail "bounded run exited $rc"
grep -q 'status=9 signal=- up_s=' "$LOG" || fail "new line was trimmed away ($(tail -1 "$LOG"))"
bytes=$(wc -c < "$LOG" | awk '{print $1}')
[ "$bytes" -le 65536 ] || fail "log grew to $bytes"
ok "ssh exit log records status, signal, local time and duration"
# A background command in non-interactive /bin/sh gets /dev/null as stdin
# unless it is redirected. hc's link is that stdin.
cat > "$STUB" <<'EOF'
#!/bin/sh
exec cat
EOF
chmod 755 "$STUB"
got=$(printf 'hello\n' | HOME=$HOME_A "$VIA" ignored)
[ "$got" = "hello" ] || fail "stdin did not round-trip ($(printf %s "$got"))"
ok "a line on stdin round-trips through the background ssh"

printf 'PASS %s checks\n' "$pass"
