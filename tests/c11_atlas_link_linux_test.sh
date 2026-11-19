#!/bin/sh
# C11H-392: scripts/c11-atlas-link.sh on Linux, against a real hc core running
# as a systemd user service. Only inside a disposable Linux box, as root:
#
#   C11_LINUX_TEST_BOX=1 C11_LINUX_HC=/path/to/herdr-core sh tests/c11_atlas_link_linux_test.sh
#
# C11_LINUX_HC is hc 0.1.16 for x86-64 Linux, the build
# Resources/hc/hc-source.json pins. The box needs systemd as PID 1, logind,
# openssh-server listening on localhost, and python3. The test creates the
# user c11linktest, links to it over ssh as Add Machine does (render, then the
# via), toggles its linger and the user manager's NOFILE default, starts and
# stops its cores, and removes the user, its drop-in and its linger at the end.
set -eu
[ "${C11_LINUX_TEST_BOX:-}" = 1 ] || { echo "SKIP: set C11_LINUX_TEST_BOX=1 inside a disposable Linux box"; exit 0; }
[ "$(uname -s)" = Linux ] && [ "$(id -u)" = 0 ] || { echo "FAIL: run as root on Linux"; exit 1; }
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LINK=$ROOT/scripts/c11-atlas-link.sh
HC=${C11_LINUX_HC:?set C11_LINUX_HC to the pinned Linux hc}
PIN=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["remote"]["linux-x86_64"]["sha256"])' "$ROOT/Resources/hc/hc-source.json")
[ "$(sha256sum "$HC" | cut -d' ' -f1)" = "$PIN" ] || { echo "FAIL: $HC is not the pinned Linux hc $PIN"; exit 1; }
U=c11linktest
S=c11-lt
DROPIN=/etc/systemd/user.conf.d/50-c11-link-test-nofile.conf
TMP=$(mktemp -d)
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
cleanup() {
  loginctl disable-linger "$U" 2>/dev/null || true
  for pid in $(ps -u "$U" -o pid= 2>/dev/null); do kill -KILL "$pid" 2>/dev/null || true; done
  userdel -r "$U" 2>/dev/null || true
  rm -f "$DROPIN"
  rm -rf "$TMP"
}
trap cleanup EXIT

id "$U" >/dev/null 2>&1 && { echo "FAIL: user $U already exists; this box was not fresh"; exit 1; }
useradd -m -s /bin/bash "$U"
H=$(getent passwd "$U" | cut -d: -f6)
ssh-keygen -q -t ed25519 -N '' -f "$TMP/key"
install -d -m 700 -o "$U" -g "$U" "$H/.ssh"
install -m 600 -o "$U" -g "$U" "$TMP/key.pub" "$H/.ssh/authorized_keys"
cat > "$TMP/ssh_config" <<EOF
Host lt
  HostName 127.0.0.1
  User $U
  IdentityFile $TMP/key
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $TMP/known_hosts
EOF
SSH="ssh -F $TMP/ssh_config -o BatchMode=yes"
far() { $SSH lt "$@"; }
# The link script, staged where Add Machine stages it.
far 'umask 077; mkdir -p ~/.local/share/c11/setup && cat > ~/.local/share/c11/setup/c11-atlas-link.sh' < "$LINK"
DIR='$HOME/.local/share/c11/setup'
HCPATH=$H/.local/share/c11/hc/0.1.16/herdr-core
SOCK=$H/.local/share/c11/run/$S.sock
secure() { far "/bin/sh \"$DIR/c11-atlas-link.sh\" secure --session $S --socket $SOCK --hc $HCPATH --sha $PIN"; }
stop() { far "/bin/sh \"$DIR/c11-atlas-link.sh\" stop --session $S --socket $SOCK --hc $HCPATH --sha $PIN --allow $PIN"; }
serving_pid() { secure | sed -n 's/^serving=ok \([0-9]*\)$/\1/p'; }
alive() { kill -0 "$1" 2>/dev/null; }

# install, with sha256sum and no shasum on PATH (Debian without the full perl).
mkdir -p "$TMP/nosha"
for tool in sh cat mkdir mv chmod awk grep sha256sum id uname dirname; do ln -s "$(command -v $tool)" "$TMP/nosha/$tool"; done
cp -r "$TMP/nosha" "$H/.nosha"; chown -R "$U:$U" "$H/.nosha"
check "install hashes with sha256sum when shasum is absent" \
  "far 'PATH=\$HOME/.nosha /bin/sh \"$DIR/c11-atlas-link.sh\" install --pin 0.1.16 --sha $PIN' < '$HC' | grep -qx 'installed $HCPATH'"
check "and a second install changes nothing" \
  "far 'PATH=\$HOME/.nosha /bin/sh \"$DIR/c11-atlas-link.sh\" install --pin 0.1.16 --sha $PIN' < '$HC' | grep -qx 'unchanged $HCPATH'"
check "secure reports the pin, private folders and no core" \
  "secure > '$TMP/secure0' && grep -qx 'sha=$PIN' '$TMP/secure0' && grep -qx 'serving=none' '$TMP/secure0' && [ \"\$(stat -c %a '$H/.local/share/c11/run')\" = 700 ]"

# The via, rendered on this side exactly as Add Machine renders it.
via=$TMP/via.sh
sh "$LINK" render --mode ssh --platform linux --session $S --socket "$SOCK" --hc "$HCPATH" --sha "$PIN" \
  --machine lt --target lt --home "$H" --user "$U" --out "$via"
sed -i "s|^/usr/bin/ssh -T |/usr/bin/ssh -F $TMP/ssh_config -T |" "$via"
check "the Linux via bakes bash and the C locale" "grep -q 'SHELL=/bin/bash LANG=C.UTF-8' '$via' && ! grep -q 'SHELL=/bin/zsh' '$via'"
dial() { status=0; HOME=$TMP "$via" </dev/null >/dev/null 2>"$TMP/dial.err" || status=$?; echo "$status"; }

# No systemd user manager for this user (masked here, as on a machine whose
# logins start none): refused by that name before any core starts (exit 10).
loginctl disable-linger "$U"
UNIT="user@$(id -u "$U").service"
systemctl stop "$UNIT" 2>/dev/null || true
systemctl mask "$UNIT" >/dev/null 2>&1
check "a dial with no user manager is refused by its own name (exit 10), and logged" \
  "[ \"\$(dial)\" = 10 ] && grep -q 'hc_needs_user_manager user=$U' '$TMP/dial.err' && grep -q 'status=10 .*reason=hc_needs_user_manager machine=lt' '$TMP/Library/Application Support/c11/link-ssh.log'"
systemctl unmask "$UNIT" >/dev/null 2>&1

# Linger off: hc's user service would stop at the user's last logout.
check "a dial with linger off is refused before any core starts (exit 9)" \
  "[ \"\$(dial)\" = 9 ] && grep -q 'hc_needs_linger reason=linger_off user=$U' '$TMP/dial.err' && secure | grep -qx 'serving=none'"
check "the via logs the refusal by name" "grep -q 'status=9 .*reason=hc_needs_linger machine=lt' '$TMP/Library/Application Support/c11/link-ssh.log'"

# Linger on, the user manager's default NOFILE soft limit (systemd's 1024).
loginctl enable-linger "$U"
sleep 1
check "a dial whose core would get 1024 files is refused (exit 4)" \
  "[ \"\$(dial)\" = 4 ] && grep -q 'hc_fd_limit reason=service_default_1024' '$TMP/dial.err' && secure | grep -qx 'serving=none'"
mkdir -p "$(dirname "$DROPIN")"
printf '[Manager]\nDefaultLimitNOFILE=524288\n' > "$DROPIN"
far 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user daemon-reexec'
sleep 1
check "with the drop-in the dial starts a core" "[ \"\$(dial)\" = 0 ]"
sleep 2
core=$(serving_pid)
check "the serving core is identified from the kernel as the pin" "[ -n '$core' ] && alive '$core'"
check "it runs as a systemd user service, with the drop-in's limit" \
  "grep -q 'user@[0-9]*.service/.*hc-' /proc/$core/cgroup && grep -q 'Max open files *524288' /proc/$core/limits"
check "a different hc is not installed over the running one (exit 3, from /proc)" \
  "{ printf '\n' | cat '$HC' - > '$TMP/foreign'; chmod 755 '$TMP/foreign'; s=0; far '/bin/sh \"$DIR/c11-atlas-link.sh\" install --pin 0.1.16 --sha $(printf '\n' | cat "$HC" - | sha256sum | cut -d' ' -f1)' < '$TMP/foreign' >/dev/null 2>&1 || s=\$?; [ \$s = 3 ]; }"

# The ssh line is gone and nobody is logged in: with linger the core stays.
sleep 15
check "the core outlives the ssh line and the last logout (linger on)" "alive '$core' && [ \"\$(serving_pid)\" = '$core' ]"
check "a second dial attaches to the same core" "[ \"\$(dial)\" = 0 ] && [ \"\$(serving_pid)\" = '$core' ]"

# The path names another inode while the core's own file is not deleted (a
# bind mount over the path; same bytes): only the running inode tells them apart.
cp "$HCPATH" "$TMP/same-bytes-hc"; chmod 755 "$TMP/same-bytes-hc"
mount --bind "$TMP/same-bytes-hc" "$HCPATH"
check "a core whose path now names another inode reads replaced_on_disk, with no ' (deleted)'" \
  "! readlink /proc/$core/exe | grep -q deleted && secure | grep -qx 'serving=mismatch $core replaced_on_disk'"
umount "$HCPATH"
check "with the path its own file again, the core is the pin" "[ \"\$(serving_pid)\" = '$core' ]"

# A file replaced under a running core: its running inode is not the file.
far "cp '$HCPATH' '$HCPATH.new' && mv -f '$HCPATH.new' '$HCPATH'"
check "a core whose file was replaced reads replaced_on_disk" "secure | grep -qx 'serving=mismatch $core replaced_on_disk'"
check "and the checked stop leaves it running (exit 8)" "s=0; stop >/dev/null 2>&1 || s=\$?; [ \$s = 8 ] && alive '$core'"
check "a dial refuses it too (exit 8)" "[ \"\$(dial)\" = 8 ] && alive '$core'"
kill -KILL "$core"
sleep 2
check "after it is gone, a dial starts a fresh core" "[ \"\$(dial)\" = 0 ]"
sleep 2
core=$(serving_pid)
check "the checked stop stops the pinned core" "[ -n '$core' ] && stop >/dev/null 2>&1; sleep 2; ! alive '$core' && secure | grep -qx 'serving=none'"

# C11H-397: a shard pairing with this Linux machine. pair --platform linux
# renders each shard's via as Add Machine renders a link here, and a shard's
# via dials a core of that shard's own session, checked as the pin.
PH=$TMP/pair-home; mkdir -p "$PH"
HOME=$PH sh "$LINK" pair --yes --mode ssh --session $S --shards 2 --hc "$HCPATH" --sha "$PIN" --home "$H" --user "$U" \
  --machine lt --target lt --platform linux >/dev/null
PVIA=$PH/.local/share/c11/atlas-via-$S-s1.sh
sed -i "s|^/usr/bin/ssh -T |/usr/bin/ssh -F $TMP/ssh_config -T |" "$PVIA"
PSOCK=$H/.local/share/c11/run/$S-s1.sock
psecure() { far "/bin/sh \"$DIR/c11-atlas-link.sh\" secure --session $S-s1 --socket $PSOCK --hc $HCPATH --sha $PIN"; }
check "pair --platform linux renders a Linux via for each shard" \
  "grep -q 'SHELL=/bin/bash LANG=C.UTF-8' '$PVIA' && grep -q 'HC_SESSION=$S-s1 ' '$PVIA' && grep -q 'SHELL=/bin/bash' '$PH/.local/share/c11/atlas-via-$S-s2.sh'"
pstatus=0; HOME=$PH "$PVIA" </dev/null >/dev/null 2>"$TMP/pdial.err" || pstatus=$?
sleep 2
check "a paired shard's via dials a core of its own session here, and it is the pin" \
  "[ $pstatus = 0 ] && psecure | grep -q '^serving=ok [0-9]*$'"
far "/bin/sh \"$DIR/c11-atlas-link.sh\" stop --session $S-s1 --socket $PSOCK --hc $HCPATH --sha $PIN --allow $PIN" >/dev/null 2>&1 || true
sleep 2
check "the shard's core stops with the checked stop" "psecure | grep -qx 'serving=none'"

# A core from a file that is not the pin, on the same socket.
cp "$TMP/foreign" "$H/foreign-hc"; chown "$U:$U" "$H/foreign-hc"
far "HC_SESSION=$S HC_SOCKET=$SOCK XDG_RUNTIME_DIR=/run/user/\$(id -u) ~/foreign-hc connect --session $S </dev/null >/dev/null 2>&1" || true
sleep 2
foreign=$(secure | sed -n 's/^serving=mismatch \([0-9]*\) [0-9a-f]\{64\}$/\1/p')
check "a foreign core is named by its own hash" "[ -n '$foreign' ] && alive '$foreign'"
check "the checked stop never signals it (exit 8)" "s=0; stop >/dev/null 2>&1 || s=\$?; [ \$s = 8 ] && alive '$foreign'"
check "a dial refuses it (exit 8)" "[ \"\$(dial)\" = 8 ] && grep -q 'hc_serving_mismatch' '$TMP/dial.err'"
kill -KILL "$foreign"
sleep 2

# Linger off with a core running: the core ends with the user's last login.
check "with linger on a fresh core starts" "[ \"\$(dial)\" = 0 ]"
sleep 2
core=$(serving_pid)
loginctl disable-linger "$U"
sleep 15
check "without linger the core ends after the last logout (why the link requires it)" "[ -n '$core' ] && ! alive '$core'"

[ "$fails" -eq 0 ] && echo "PASS c11_atlas_link_linux_test" || { echo "FAIL c11_atlas_link_linux_test ($fails)"; exit 1; }
