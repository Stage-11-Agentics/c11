#!/bin/sh
# C11H-392: the relay kit on Linux, with the c11 CLI built for Linux. Only
# inside a disposable Linux box, as root:
#
#   C11_LINUX_TEST_BOX=1 C11_LINUX_CLI=/path/to/c11 C11_LINUX_HC=/path/to/herdr-core \
#     [C11_LINUX_KIT_TAR=/path/to/c11-kit.tar] sh tests/c11_atlas_relay_linux_test.sh
#
# With C11_LINUX_KIT_TAR (an archive packed on a Mac as HCMachineSetup packs
# Add Machine's kit, around the same Linux CLI), the kit is unpacked from it
# by this box's tar; otherwise the same files are laid out with cp.
#
# It creates the user c11relaytest from the box's own skeleton (Debian's
# ~/.profile and /etc/profile, which sets PATH for every login shell), installs
# the kit there, starts bash the way c11's launch line does for a bash shell
# with the kit's rcfile, and runs the Linux CLI's relay verbs against a private
# hc core (tools/linux-cli/relay-offline-test.py). It removes the user at the end.
set -eu
[ "${C11_LINUX_TEST_BOX:-}" = 1 ] || { echo "SKIP: set C11_LINUX_TEST_BOX=1 inside a disposable Linux box"; exit 0; }
[ "$(uname -s)" = Linux ] && [ "$(id -u)" = 0 ] || { echo "FAIL: run as root on Linux"; exit 1; }
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
CLI=${C11_LINUX_CLI:?set C11_LINUX_CLI to the Linux c11}
HC=${C11_LINUX_HC:?set C11_LINUX_HC to the pinned Linux hc}
U=c11relaytest
TMP=$(mktemp -d)
chmod 755 "$TMP"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
cleanup() {
  for pid in $(ps -u "$U" -o pid= 2>/dev/null); do kill -KILL "$pid" 2>/dev/null || true; done
  userdel -r "$U" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
id "$U" >/dev/null 2>&1 && { echo "FAIL: user $U already exists; this box was not fresh"; exit 1; }
useradd -m -s /bin/bash "$U"
H=$(getent passwd "$U" | cut -d: -f6)
as() { runuser -u "$U" -- env -i HOME="$H" USER="$U" LOGNAME="$U" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$@"; }
cp "$CLI" "$TMP/c11"; cp "$HC" "$TMP/herdr-core"; cp "$ROOT/scripts/c11-atlas-relay.sh" "$TMP/relay.sh"
chmod 755 "$TMP/c11" "$TMP/herdr-core"; chmod 644 "$TMP/relay.sh"
if [ -n "${C11_LINUX_KIT_TAR:-}" ]; then
  # C11H-398: the archive Add Machine sends (HCMachineSetup lays the kit out
  # and packs it on the Mac with /usr/bin/tar --format ustar), staged in the
  # user's setup folder and unpacked by this box's tar as the relay step runs it.
  DIR=$H/.local/share/c11/setup-test
  as sh -c "umask 077; mkdir -p '$DIR' && cat > '$DIR/c11-kit.tar'" < "$C11_LINUX_KIT_TAR"
  as sh -c "umask 077; cat > '$DIR/c11-atlas-relay.sh'" < "$ROOT/scripts/c11-atlas-relay.sh"
  check "this box's $(tar --version | head -n 1) unpacks Add Machine's archive with nothing on stderr" \
    "as sh -c \"umask 077; cd '$DIR' && tar -xf c11-kit.tar\" 2>'$TMP/untar.err' && [ ! -s '$TMP/untar.err' ]"
  check "every member is under kit/, and every unpacked file is the user's own and private" \
    "[ -z \"\$(tar -tf '$DIR/c11-kit.tar' | grep -v '^kit/')\" ] && [ -z \"\$(find '$DIR/kit' ! -user $U -o -perm /077)\" ]"
  check "the archive carries the Linux CLI unchanged" "cmp -s '$CLI' '$DIR/kit/Contents/Resources/bin/c11'"
  APPC=$DIR/kit/Contents
  RELAY=$DIR/c11-atlas-relay.sh
else
  # The layout Add Machine stages there (HCMachineSetup.layOutKit): the Linux CLI
  # with the app's Claude wrapper, agent note, Info.plist and c11 skill around it.
  APPC=$TMP/kit/Contents
  RELAY=$TMP/relay.sh
  mkdir -p "$APPC/Resources/bin" "$APPC/Resources/skills"
  cp "$CLI" "$APPC/Resources/bin/c11"; chmod 755 "$APPC/Resources/bin/c11"
  cp "$ROOT/Resources/Info.plist" "$APPC/Info.plist"
  for name in claude c11-agent-note.sh c11-agent-note.txt; do cp "$ROOT/Resources/bin/$name" "$APPC/Resources/bin/$name"; done
  cp -R "$ROOT/skills/c11" "$APPC/Resources/skills/c11"
  chmod -R a+rX "$TMP/kit"
fi

KIT=$H/.local/share/c11/relay/c11
check "the kit installs with the Linux CLI and sha256sum" "as sh '$RELAY' install --session c11 --cli '$APPC/Resources/bin/c11' >/dev/null"
check "a fresh kit carries c11's Claude wrapper, its note, Info.plist and the c11 skill" \
  "[ -x '$KIT/bin/claude' ] && [ -x '$KIT/libexec/claude' ] && [ -f '$KIT/c11-relay.app/Contents/Resources/bin/c11-agent-note.sh' ] && [ -f '$KIT/c11-relay.app/Contents/Resources/bin/c11-agent-note.txt' ] && [ -f '$KIT/c11-relay.app/Contents/Info.plist' ] && [ -f '$KIT/c11-relay.app/Contents/Resources/skills/c11/SKILL.md' ]"
check "its manifest names bash/rc" \
  "python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m[\"bashrc\"] == sys.argv[2] and \"bash/rc\" in m[\"files\"], m' '$KIT/manifest.json' '$KIT/bash/rc'"
check "the kit's c11 is the Linux CLI, unchanged" "cmp -s '$CLI' '$KIT/c11-relay.app/Contents/Resources/bin/c11'"

# What c11's launch line runs on a Linux machine whose terminal has the kit:
# bash --rcfile <kit>/bash/rc -i, in the far core's environment.
term() {
  as SHELL=/bin/bash LANG=C.UTF-8 C11_RELAY_BIN="$KIT/bin" C11_RELAY_BASHRC="$KIT/bash/rc" \
    C11_SOCKET_PATH="$KIT/no-socket" /bin/bash --rcfile "$KIT/bash/rc" -i -c "$1" </dev/null 2>/dev/null
}
check "Debian's /etc/profile and ~/.profile ran (PATH has /usr/local/bin and ~/.local/bin when it exists)" \
  "mkdir -p '$H/.local/bin' && chown -R $U:$U '$H/.local/bin' && term 'printf %s \"\$PATH\"' | grep -q '/usr/local/bin' && term 'printf %s \"\$PATH\"' | grep -q '$H/.local/bin'"
check "the relay c11 is first on PATH, ahead of ~/.local/bin" "[ \"\$(term 'command -v c11')\" = '$KIT/bin/c11' ]"
printf '#!/bin/sh\necho stand-in\n' > "$H/.local/bin/claude"; chmod 755 "$H/.local/bin/claude"; chown "$U:$U" "$H/.local/bin/claude"
check "claude is the kit's wrapper, ahead of another claude in ~/.local/bin" "[ \"\$(term 'command -v claude')\" = '$KIT/bin/claude' ]"
check "the shell is interactive and the rcfile variable is gone" "[ \"\$(term 'case \$- in *i*) printf i;; esac; printf %s \"\${C11_RELAY_BASHRC-unset}\"')\" = iunset ]"
check "the relay c11 runs there" "term 'c11 --version' | grep -q 'c11'"

# A prompt hook in ~/.bashrc (where `mise activate bash` goes; Debian's
# ~/.profile sources it) moves PATH at every prompt. The relay's fixer runs
# after it, for a string PROMPT_COMMAND ending in ';' and for a bash 5 array
# with the hook in a later element. Commands go on stdin, as a terminal types
# them, so every prompt runs PROMPT_COMMAND (`-c` shows none).
mkdir -p "$H/hook"; printf '#!/bin/sh\necho hook\n' > "$H/hook/c11"; chmod 755 "$H/hook/c11"; chown -R "$U:$U" "$H/hook"
cp "$H/.bashrc" "$TMP/bashrc"
hook_term() {
  printf 'command -v c11\ncd /\ncommand -v c11\nprintf "hooks=%%s\\n" "$_hook_n"\nexit\n' |
    as SHELL=/bin/bash LANG=C.UTF-8 C11_RELAY_BIN="$KIT/bin" C11_RELAY_BASHRC="$KIT/bash/rc" \
      C11_SOCKET_PATH="$KIT/no-socket" /bin/bash --rcfile "$KIT/bash/rc" -i 2>/dev/null
}
for form in '"_hook;"' '(: _hook)'; do
  { cat "$TMP/bashrc"; printf '_hook() { _hook_n=$((${_hook_n:-0} + 1)); PATH="$HOME/hook:$PATH"; }\nPROMPT_COMMAND=%s\n' "$form"; } > "$H/.bashrc"
  hook_term > "$TMP/hook.out" || true
  check "the relay c11 stays first after a ~/.bashrc prompt hook (PROMPT_COMMAND=$form)" \
    "[ \"\$(sed -n 1p '$TMP/hook.out')\" = '$KIT/bin/c11' ] && [ \"\$(sed -n 2p '$TMP/hook.out')\" = '$KIT/bin/c11' ] && grep -qx 'hooks=4' '$TMP/hook.out'"
done
cp "$TMP/bashrc" "$H/.bashrc"

# The Linux CLI's relay verbs against a private hc core (no c11 app answers,
# so each verb waits out the claim bound and says nothing ran).
RUN=$H/.local/share/c11/run
as mkdir -p "$RUN" "$H/.hc-rt"
as sh -c "chmod 700 '$RUN'; HC_SESSION=c11 HC_SOCKET=$RUN/c11.sock XDG_RUNTIME_DIR=$H/.hc-rt '$TMP/herdr-core' connect --session c11 </dev/null >/dev/null 2>&1" || true
sleep 2
check "a private core serves the relay's session" "[ -S '$RUN/c11.sock' ] && ps -u '$U' -o args= | grep -q '^$TMP/herdr-core '"
cp "$ROOT/tools/linux-cli/relay-offline-test.py" "$TMP/offline.py"; chmod 644 "$TMP/offline.py"
check "the Linux CLI's relay verbs sign, wait, cancel and spool as on the build host" \
  "as python3 -I '$TMP/offline.py' '$KIT/bin/c11' '$RUN/c11.sock' > '$TMP/offline.out' 2>&1; s=\$?; cat '$TMP/offline.out' | sed 's/^/     /'; [ \$s = 0 ]"

[ "$fails" -eq 0 ] && echo "PASS c11_atlas_relay_linux_test" || { echo "FAIL c11_atlas_relay_linux_test ($fails)"; exit 1; }
