#!/bin/sh
# C11H-13: render the remote machine's --via script, serve the same remote command on a
# local socket, or install the pinned binary into a c11-owned directory.
# None of these talk to herdr-app or open a guest.
#
#   c11-atlas-link.sh render --mode ssh --out FILE --session S \
#       --socket SOCK --hc BIN --sha HEX [--machine NAME] [--target HOST] \
#       [--ssh /usr/bin/ssh] [--home DIR] [--user NAME] [--platform mac|linux]
#   c11-atlas-link.sh serve --listen SOCK --session S --socket SOCK \
#       --hc BIN --sha HEX --home DIR --user NAME
#   c11-atlas-link.sh secure --session S --socket SOCK --hc BIN --sha HEX
#   c11-atlas-link.sh stop --session S --socket SOCK --hc BIN --sha HEX [--allow HEX[,HEX]]
#   c11-atlas-link.sh migrate --via FILE --sha HEX [--machine NAME]
#   c11-atlas-link.sh install --pin VER --sha HEX < binary
#   c11-atlas-link.sh install --from /path/to/c11.app
#   c11-atlas-link.sh pair --mode ssh --session S --shards N --hc BIN --sha HEX \
#       --home DIR --user NAME [--machine NAME] [--target HOST] [--ssh /usr/bin/ssh] [--platform mac|linux] [--yes]
#   c11-atlas-link.sh unpair
#
# --target is the ssh host. Without it, ssh mode uses C11_REMOTE_HOST from the
# environment, else the last C11_REMOTE_HOST= line of
# ${C11_DEV_HOSTS:-~/.config/c11/dev-hosts} (parsed, never sourced); unset
# everywhere, it exits 2 naming the variable. It is read at render time and
# baked into the via. pair's --machine defaults to that host, without any user@.
#
# pair (C11H-78) pairs local shards S-s1 .. S-sN one to one with the sessions
# of the same names on the other machine: it renders one via per shard,
# ~/.local/share/c11/atlas-via-S-sK.sh (each baking its own session and
# socket), and writes ~/.local/share/c11/atlas-pair.json listing them. c11
# adds the machine to a shard's core when that core connects; it adds none
# without this file. --home, --user and --hc describe the other machine.
# C11H-397: --platform (default mac) is the other machine's, as render takes
# it; every shard's via is rendered with it. --sha is that platform's pin:
# c11 adds a Linux via only when it checks this build's Linux hc pin, and a
# Mac via only when it checks this Mac's (otherwise unsafe_via
# reason=other_platform_pin, or no_pin, in the pairing log).
# C11H-365: pair first asks on the terminal, naming the machine, the shard
# count and the ssh target, and writes nothing without a typed yes. --yes
# skips the question and is refused inside a c11 terminal. The manifest
# records the answer ("acknowledged": 1); c11 adds no machine for one without it.
# pair writes only those files and never replaces one it did not write;
# unpair removes only unchanged files whose hashes the intact manifest owns,
# then the manifest; edited files and symlinks stay. A
# machine already added to a running shard stays until `hc machine rm`.
#
# render bakes every value into the script. hc's core drops the environment,
# so the script must not read C11_* or $1 (hc's default remote line, which
# would pick up herdr-app's herdr-core). install writes only
# $HOME/.local/share/c11/hc/<pin>/herdr-core. A matching hash is a no-op.
# A different hash is replaced only when no process of this account runs
# that file (lsof); otherwise the command exits 3 and writes nothing.
#
# ssh mode turns connection sharing off (ControlMaster=no, ControlPath=none)
# whatever ~/.ssh/config says: each shard pair is its own connection, so one
# shard's dropped line never takes another's down (C11H-78).
# C11H-361: it also turns every forwarding off whatever ~/.ssh/config says
# (LINK_SSH_NO_FORWARDING: no agent, no X11, no local, remote or dynamic
# forward, no LocalCommand, no GSSAPI credential delegation). hc holds this
# line for as long as the machine stays linked, so a forwarded agent would
# let the other machine sign with this Mac's keys for that long. ssh still
# authenticates with SSH_AUTH_SOCK. migrate re-renders a via without these
# switches, keeping its own pin.
# ssh mode's remote command raises soft RLIMIT_NOFILE before exec, using
# target = min(finite hard, kern.maxfilesperproc) and treating an infinite
# hard limit as unbounded. A soft limit already above the kernel cap is left
# alone. Hard is never changed. The process re-reads the limit and refuses
# to exec unless min(soft, kernel cap) is at least 8192. Failure prints
# hc_fd_limit on stderr and exits 4. The log stays on stderr: hc's dial
# reads stdout as the protocol. Bridge mode only connects the socket; the
# process that execs the pin must run this same remote command.
# C11H-332: the pin is required (render, serve, pair and secure all take
# --sha). Before it starts hc, the remote command (1) hashes the hc it is
# about to run and refuses a different file (hc_hash_mismatch, exit 5);
# (2) walks hc's socket folder, state root and session state folder, each
# opened without following a symlink relative to its parent's descriptor: a
# folder this user owns with group or other bits is fchmod'ed to 0700
# (hc_dir_repaired); a symlink, a non-directory or another owner's folder is
# refused and stops the walk (hc_dir_refused, exit 6); (3) if a core already
# serves the session's socket, finds that process from the kernel (the
# socket's peer pid, its executable and the inode it runs) and refuses one
# that is not this pin, never signalling it (hc_serving_mismatch, exit 8).
# `secure` runs the same checks and prints a report instead of starting hc.
# The ssh via names those exits in link-ssh.log with the machine, host and
# session; c11 turns them into audit records.
# serve accepts one connection on a local unix socket and runs that command.
# It does not ssh, and it does not open a guest.
# C11H-392: --platform linux renders for an x86-64 Linux machine: its
# terminals get SHELL=/bin/bash and LANG=C.UTF-8 (a Mac's get zsh and
# en_US.UTF-8), and the same remote command reads the kernel's own answers
# there: the cap from /proc/sys/fs/nr_open, the serving core's pid by
# SO_PEERCRED, its executable and running inode through /proc/<pid>/exe.
# hc runs a Linux core as a systemd user service, so before a dial starts one
# it needs this user's systemd manager, linger on, and the manager's default
# NOFILE soft limit at least 8192 (the service never sees this launcher's
# raise): otherwise hc_needs_user_manager (exit 10), hc_needs_linger (exit 9)
# or hc_fd_limit (exit 4). install
# uses sha256sum when there is no shasum, and finds a running copy of a file
# from /proc instead of lsof.
set -eu

# C11H-361: every ssh this script renders carries these, before `--`.
# HCMachineSetup.sshForwardingOff (Swift) is the same list in the same order.
LINK_SSH_NO_FORWARDING='-o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no -k'

die() { printf 'c11-atlas-link: %s\n' "$1" >&2; exit 2; }

# render's --platform (C11H-392): which machine the remote command runs on.
LINK_PLATFORM=mac

# The ssh host when --target is absent (see the header). No default lives here.
remote_host() {
  if [ -n "${C11_REMOTE_HOST:-}" ]; then
    printf '%s\n' "$C11_REMOTE_HOST"
    return 0
  fi
  hosts=${C11_DEV_HOSTS:-${HOME:-}/.config/c11/dev-hosts}
  value=
  if [ -f "$hosts" ]; then
    value=$(sed -n 's/^[[:space:]]*C11_REMOTE_HOST[[:space:]]*=[[:space:]]*//p' "$hosts" | sed 's/[[:space:]]*$//' | sed '/^$/d' | tail -n 1)
  fi
  if [ -z "$value" ]; then
    printf 'C11_REMOTE_HOST is unset: pass --target, export it, or add C11_REMOTE_HOST=<ssh host> to %s\n' \
      "${C11_DEV_HOSTS:-~/.config/c11/dev-hosts}" >&2
    exit 2
  fi
  printf '%s\n' "$value"
}

safe_token() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._@-]*$'
}

safe_path() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._/-]+$' || return 1
  case "$1" in
    *..*) return 1 ;;
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

session_ok() {
  printf '%s' "$1" | grep -Eq '^c11(-[A-Za-z0-9][A-Za-z0-9._-]*)?$'
}

# One line of base64. The remote shell has no single quotes available: the
# via script passes the whole command as one single-quoted ssh argument.
nofile_b64() {
  /usr/bin/base64 <<'ENDPY' | /usr/bin/tr -d '\n'
import ctypes, errno, hashlib, os, resource, socket, stat, struct, subprocess, sys

def emit(kind, cap, before_soft, before_hard, after_soft, after_hard, reason):
    tail = "" if reason is None else " reason=%s" % reason
    sys.stderr.write(
        "%s kernel_cap=%s before_soft=%s before_hard=%s after_soft=%s after_hard=%s%s\n"
        % (kind, cap, before_soft, before_hard, after_soft, after_hard, tail)
    )
    sys.stderr.flush()

def fail(cap, before_soft, before_hard, after_soft, after_hard, reason):
    emit("hc_fd_limit", cap, before_soft, before_hard, after_soft, after_hard, reason)
    sys.exit(4)

LINUX = sys.platform.startswith("linux")
args = sys.argv[2:]
report = bool(args) and args[0] == "--report"
stopping = bool(args) and args[0] == "--stop"
if report or stopping:
    args.pop(0)
expected = args.pop(0)[len("sha256="):] if args and args[0].startswith("sha256=") else None
allowed = set()
if stopping and args and args[0].startswith("allow="):
    allowed = set(word for word in args.pop(0)[len("allow="):].split(",") if word)
binary = args[0] if args else ""

def say(line):
    if report:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()
    else:
        sys.stderr.write(line + "\n")
        sys.stderr.flush()

def refuse(line, status):
    say(line)
    if not report:
        sys.exit(status)

def sha256_of(path):
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                digest.update(chunk)
    except OSError:
        return None
    return digest.hexdigest()

# C11H-332: run only the hc this link was rendered for; a link without its pin runs nothing.
def check_binary():
    found = sha256_of(binary)
    if report:
        say("sha=%s" % (found or "missing"))
        return
    if expected is None or found != expected:
        refuse("hc_hash_mismatch expected=%s found=%s path=%s" % (expected or "none", found or "missing", binary), 5)

# C11H-332: hc's folders are this user's alone. Each is opened without
# following a symlink, relative to its parent's descriptor, and changed with
# fchmod; the first refused folder stops the walk, so nothing under it is
# created or changed.
class Refused(Exception):
    pass

def parent_fd(path):
    previous = os.umask(0o077)
    try:
        os.makedirs(path, 0o700, exist_ok=True)
    finally:
        os.umask(previous)
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY)

def private_child(dir_fd, name, shown, created=False):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)
    except FileNotFoundError:
        if created:
            raise Refused("%s create_failed" % shown)
        previous = os.umask(0o077)
        try:
            os.mkdir(name, 0o700, dir_fd=dir_fd)
        except FileExistsError:
            pass
        except OSError as exc:
            raise Refused("%s %s" % (shown, (exc.strerror or "error").replace(" ", "_").lower()))
        finally:
            os.umask(previous)
        return private_child(dir_fd, name, shown, True)
    except OSError as exc:
        reason = None
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            try:
                reason = "symlink" if stat.S_ISLNK(os.lstat(name, dir_fd=dir_fd).st_mode) else "not_a_directory"
            except OSError:
                reason = "not_a_directory"
        raise Refused("%s %s" % (shown, reason or (exc.strerror or "error").replace(" ", "_").lower()))
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode):
        os.close(fd)
        raise Refused("%s not_a_directory" % shown)
    if info.st_uid != os.getuid():
        os.close(fd)
        raise Refused("%s owner_%d" % (shown, info.st_uid))
    mode = stat.S_IMODE(info.st_mode)
    if mode & 0o077:
        os.fchmod(fd, 0o700)
        if report:
            say("repaired=%s %o" % (shown, mode))
        else:
            say("hc_dir_repaired path=%s from=%o to=700" % (shown, mode))
    return fd, created

def secure_folders():
    home = os.environ.get("HOME", "")
    session = os.environ.get("HC_SESSION", "")
    run = os.path.dirname(os.environ.get("HC_SOCKET", ""))
    if not home.startswith("/") or not run.startswith("/") or not session:
        refuse("hc_dir_refused path=%s reason=no_folders" % (run or "-"), 6)
        return
    try:
        for parent, name, child in ((os.path.dirname(run), os.path.basename(run), None),
                                    (os.path.join(home, ".local", "state"), "herdr-core", session)):
            pfd = parent_fd(parent)
            try:
                fd, created = private_child(pfd, name, os.path.join(parent, name))
                if created and report:
                    say("created=%s" % os.path.join(parent, name))
                if child is not None:
                    try:
                        cfd, ccreated = private_child(fd, child, os.path.join(parent, name, child))
                        if ccreated and report:
                            say("created=%s" % os.path.join(parent, name, child))
                        os.close(cfd)
                    finally:
                        os.close(fd)
                else:
                    os.close(fd)
            finally:
                os.close(pfd)
    except Refused as refusal:
        path, reason = str(refusal).rsplit(" ", 1)
        if report:
            say("refused=%s %s" % (path, reason))
        else:
            refuse("hc_dir_refused path=%s reason=%s" % (path, reason), 6)

# C11H-392: on Linux the kernel names a process's executable at /proc/<pid>/exe:
# its target is the path (a " (deleted)" suffix when the file was removed or
# replaced since), and stat through it is the inode the process runs. Readable
# only for this user's own processes; anything else is unknown.
def linux_running(pid):
    link = "/proc/%d/exe" % pid
    try:
        path = os.readlink(link)
        running = os.stat(link)
    except OSError:
        return "", None
    if path.endswith(" (deleted)"):
        return path[:-len(" (deleted)")], "replaced_on_disk"
    found = sha256_of(path)
    try:
        on_disk = os.stat(path)
    except OSError:
        return path, "replaced_on_disk"
    if (running.st_dev, running.st_ino) != (on_disk.st_dev, on_disk.st_ino):
        return path, "replaced_on_disk"
    return path, found

# C11H-332: a core already serving this session must be this build's hc. Its
# process is found from the kernel (the socket's peer pid, that pid's
# executable and the inode it runs), never from its own reply, and it is never
# signalled.
def serving_identity():
    """(state, pid, path, found): state is none, known (found is its hash
    or replaced_on_disk) or unknown (no peer identity could be read)."""
    sock = os.environ.get("HC_SOCKET", "")
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(2)
    # Relative to its folder, so a long path still connects; the cwd hc
    # inherits is restored.
    here = os.open(".", os.O_RDONLY)
    try:
        os.chdir(os.path.dirname(sock) or "/")
        probe.connect(os.path.basename(sock))
    except (FileNotFoundError, ConnectionRefusedError):
        probe.close()
        return "none", 0, "", None
    except OSError:
        probe.close()
        return "unknown", 0, "", None
    finally:
        os.fchdir(here)
        os.close(here)
    try:
        if LINUX:
            # SO_PEERCRED: struct ucred {pid, uid, gid}.
            pid = struct.unpack("3i", probe.getsockopt(socket.SOL_SOCKET, getattr(socket, "SO_PEERCRED", 17), 12))[0]
        else:
            pid = struct.unpack("i", probe.getsockopt(0, 2, 4))[0]
    except OSError:
        pid = 0
    finally:
        probe.close()
    if LINUX:
        path, found = linux_running(pid) if pid > 0 else ("", None)
        return ("known" if found else "unknown"), pid, path, found
    path, found = "", None
    if pid > 0:
        buf = ctypes.create_string_buffer(4096)
        try:
            if ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidpath(pid, buf, 4096) > 0:
                path = buf.value.decode("utf-8", "replace")
        except OSError:
            path = ""
    if path:
        found = sha256_of(path)
        try:
            listed = subprocess.run(["/usr/sbin/lsof", "-a", "-n", "-P", "-p", str(pid), "-d", "txt", "-F", "in"],
                                    capture_output=True, text=True, timeout=5).stdout.split("\n")
            running = None
            for index, line in enumerate(listed):
                if line == "n" + path and index > 0 and listed[index - 1].startswith("i"):
                    running = int(listed[index - 1][1:])
                    break
            if running is None or running != os.stat(path).st_ino:
                found = "replaced_on_disk"
        except (OSError, ValueError, subprocess.SubprocessError):
            found = None
    return ("known" if found else "unknown"), pid, path, found

def check_serving():
    state, pid, path, found = serving_identity()
    if state == "none":
        if report:
            say("serving=none")
        return state
    if found is not None and found == expected:
        if report:
            say("serving=ok %d" % pid)
        return state
    if report:
        say("serving=mismatch %d %s" % (pid, found or "unknown"))
    else:
        refuse("hc_serving_mismatch expected=%s found=%s pid=%d path=%s" % (expected or "none", found or "unknown", pid, path or "-"), 8)
    return state

# C11H-392: hc starts a Linux core as a systemd user service (systemd-run
# --user), so before this dial starts one: a user manager must run for this
# user, linger must be on (without it the manager, and the core with every
# terminal, stops at the user's last logout; the link's own ssh is often that
# login), and the manager's default NOFILE soft limit, which is what the
# service gets (this launcher's own raise below never reaches it), must be at
# least 8192. Refusals: hc_needs_user_manager (exit 10), hc_needs_linger
# (exit 9) and hc_fd_limit (exit 4).
def service_nofile(run):
    try:
        # systemctl from /usr/bin or /bin (a Linux without merged /usr), by the env's PATH.
        value = subprocess.run(["systemctl", "--user", "show", "-p", "DefaultLimitNOFILESoft", "--value"],
                               env={"XDG_RUNTIME_DIR": run, "PATH": "/usr/bin:/bin"}, stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    if value == "infinity":
        return resource.RLIM_INFINITY
    return int(value) if value.isdigit() else None

def check_user_services():
    user = os.environ.get("USER", "")
    run = "/run/user/%d" % os.getuid()
    if not os.path.exists(os.path.join(run, "systemd", "private")):
        refuse("hc_needs_user_manager user=%s" % user, 10)
    if not user or not os.path.exists(os.path.join("/var/lib/systemd/linger", user)):
        refuse("hc_needs_linger reason=linger_off user=%s" % user, 9)
    soft = service_nofile(run)
    if soft is None or (soft != resource.RLIM_INFINITY and soft < 8192):
        sys.stderr.write("hc_fd_limit reason=service_default_%s\n" % ("unknown" if soft is None else soft))
        sys.stderr.flush()
        sys.exit(4)

# C11H-332: Remove and Update stop a core only after the client hashed to the
# pin AND the process serving the socket is positively identified, from the
# kernel, as an hc in `allow` (this pin, or the one the link was made with).
# Anything else is left running and reported (exit 8); nothing is signalled.
def stop_core(allowed):
    if expected is None or sha256_of(binary) != expected:
        say("hc_hash_mismatch expected=%s found=%s path=%s" % (expected or "none", sha256_of(binary) or "missing", binary))
        sys.exit(7)
    state, pid, path, found = serving_identity()
    if state == "none":
        say("stopped=none")
        sys.exit(0)
    if found is None or found not in allowed:
        say("hc_serving_mismatch expected=%s found=%s pid=%d path=%s" % (",".join(sorted(allowed)), found or "unknown", pid, path or "-"))
        sys.exit(8)
    os.execv(binary, [binary, "server", "stop"])

try:
    if stopping:
        stop_core(allowed or ({expected} if expected else set()))
    check_binary()
    secure_folders()
    serving = check_serving()
    if report:
        sys.exit(0)
    if LINUX and serving == "none":
        check_user_services()
    before_soft, before_hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if LINUX:
        with open("/proc/sys/fs/nr_open") as handle:
            cap = int(handle.read().strip())
    else:
        cap = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "kern.maxfilesperproc"]))
    infinity = resource.RLIM_INFINITY
    finite = cap if before_hard == infinity else before_hard
    target = finite if finite < cap else cap
    # A soft limit already above the kernel cap is sufficient. Do not lower it.
    if before_soft == infinity or before_soft > cap:
        new_soft = before_soft
    else:
        new_soft = target
    if new_soft != before_soft:
        resource.setrlimit(resource.RLIMIT_NOFILE, (new_soft, before_hard))
    after_soft, after_hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if after_hard != before_hard:
        fail(cap, before_soft, before_hard, after_soft, after_hard, "hard_changed")
    effective = cap if after_soft == infinity else (after_soft if after_soft < cap else cap)
    if effective < 8192:
        fail(cap, before_soft, before_hard, after_soft, after_hard, "effective_%s" % effective)
    emit("nofile", cap, before_soft, before_hard, after_soft, after_hard, None)
    os.execv(binary, args)
except SystemExit:
    raise
except Exception as exc:
    sys.stderr.write("hc_fd_limit reason=%s\n" % exc)
    sys.stderr.flush()
    sys.exit(4)
ENDPY
}

# The ssh remote line and `serve` both exec this. Values are baked.
# Callers validate the tokens before expanding them into the command.
remote_command() {
  session=$1 socket=$2 hc=$3 home=$4 user=$5 sha=$6 mode=${7:-connect}
  case "$home" in */) die "home must not end in /" ;; esac
  sha_ok "$sha" || die "the hc pin (--sha) is required: 64 lower-case hex digits"
  b64=$(nofile_b64)
  [ -n "$b64" ] || die "nofile launcher was empty"
  tail="sha256=$sha $hc connect --session $session"
  [ "$mode" = report ] && tail="--report sha256=$sha $hc"
  [ "$mode" = stop ] && tail="--stop sha256=$sha allow=${8:-$sha} $hc"
  # C11H-392: a Linux machine's terminals get bash and the C locale every
  # Linux has; a Mac's get zsh, as before.
  shell=/bin/zsh lang=en_US.UTF-8
  case "$LINK_PLATFORM" in
    mac) ;;
    linux) shell=/bin/bash lang=C.UTF-8 ;;
    *) die "platform must be mac or linux" ;;
  esac
  printf '%s' "exec /usr/bin/env -i HOME=$home USER=$user LOGNAME=$user SHELL=$shell LANG=$lang PATH=/usr/bin:/bin:/usr/sbin:/sbin HC_SESSION=$session HC_SOCKET=$socket HC_SPAWN_MS=10000 XDG_CONFIG_HOME=$home/.local/share/c11/config /usr/bin/python3 -I -c \"import base64,sys; exec(base64.b64decode(sys.argv[1]).decode())\" $b64 $tail"
}

sha_ok() {
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'
}

# C11H-392: a Linux machine may have sha256sum and no shasum (Debian ships
# shasum with the full perl package).
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'
}

# C11H-332: Add Machine's check, run on the far machine after install. The
# same launcher code as every dial, in report mode: it prints sha=, created=,
# repaired=, refused= and serving= lines and never starts or signals hc.
cmd_secure() {
  session= socket= hc= sha=
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) session=$2; shift 2 ;;
      --socket) socket=$2; shift 2 ;;
      --hc) hc=$2; shift 2 ;;
      --sha) sha=$2; shift 2 ;;
      *) die "unknown secure option: $1" ;;
    esac
  done
  session_ok "$session" || die "bad session: $session"
  safe_path "$socket" || die "bad socket"
  safe_path "$hc" || die "bad hc path"
  [ -n "${HOME:-}" ] || die "HOME is unset"
  user=$(/usr/bin/id -un)
  safe_token "$user" || die "bad user"
  remote=$(remote_command "$session" "$socket" "$hc" "$HOME" "$user" "$sha" report)
  exec /bin/sh -c "$remote"
}

# C11H-332: Remove's and Update's stop, run on the far machine: `server stop`
# runs only when the client hashes to --sha and the core serving --socket is
# identified from the kernel as an hc whose hash is in --allow (default: the
# pin). An unidentified or foreign core is left running: exit 8, never
# signalled. Exit 7: the client isn't the pin. No core serving: exit 0.
cmd_stop() {
  session= socket= hc= sha= allow=
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) session=$2; shift 2 ;;
      --socket) socket=$2; shift 2 ;;
      --hc) hc=$2; shift 2 ;;
      --sha) sha=$2; shift 2 ;;
      --allow) allow=$2; shift 2 ;;
      *) die "unknown stop option: $1" ;;
    esac
  done
  session_ok "$session" || die "bad session: $session"
  safe_path "$socket" || die "bad socket"
  safe_path "$hc" || die "bad hc path"
  [ -n "$allow" ] || allow=$sha
  printf '%s' "$allow" | grep -Eq '^[0-9a-f]{64}(,[0-9a-f]{64})*$' || die "bad --allow"
  [ -n "${HOME:-}" ] || die "HOME is unset"
  user=$(/usr/bin/id -un)
  safe_token "$user" || die "bad user"
  remote=$(remote_command "$session" "$socket" "$hc" "$HOME" "$user" "$sha" stop "$allow")
  exec /bin/sh -c "$remote"
}

cmd_render() {
  mode= session= socket= hc= target= ssh=/usr/bin/ssh home= user= out= sha= machine=
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode=$2; shift 2 ;;
      --platform) LINK_PLATFORM=$2; shift 2 ;;
      --sha) sha=$2; shift 2 ;;
      --machine) machine=$2; shift 2 ;;
      --session) session=$2; shift 2 ;;
      --socket) socket=$2; shift 2 ;;
      --hc) hc=$2; shift 2 ;;
      --target) target=$2; shift 2 ;;
      --ssh) ssh=$2; shift 2 ;;
      --home) home=$2; shift 2 ;;
      --user) user=$2; shift 2 ;;
      --out) out=$2; shift 2 ;;
      *) die "unknown render option: $1" ;;
    esac
  done
  [ -n "$out" ] || die "render needs --out"
  case "$LINK_PLATFORM" in mac|linux) ;; *) die "platform must be mac or linux" ;; esac
  session_ok "$session" || die "bad session: $session"
  sha_ok "$sha" || die "render needs --sha: this c11's hc pin, 64 lower-case hex digits"
  [ -z "$machine" ] || safe_token "$machine" || die "bad machine name"
  safe_path "$socket" || die "bad socket"
  safe_path "$hc" || die "bad hc path"
  safe_path "$ssh" || die "bad ssh path"
  case "$socket" in
    */.local/share/c11/run/"$session".sock) ;;
    *) die "socket must be ~/.local/share/c11/run/$session.sock" ;;
  esac
  case "$hc" in
    */.local/share/c11/hc/*/herdr-core) ;;
    *) die "hc must be ~/.local/share/c11/hc/<pin>/herdr-core" ;;
  esac
  case "$hc" in
    */.local/bin/*) die "refusing herdr-app's binary path" ;;
  esac
  body=
  case "$mode" in
    ssh)
      [ -n "$target" ] || target=$(remote_host)
      safe_token "$target" || die "bad ssh target"
      case "$target" in -*) die "ssh target must not be an option" ;; esac
      [ -n "$home" ] || die "ssh mode needs --home"
      [ -n "$user" ] || die "ssh mode needs --user"
      safe_path "$home" || die "bad home"
      safe_token "$user" || die "bad user"
      remote=$(remote_command "$session" "$socket" "$hc" "$home" "$user" "$sha")
      [ -n "$machine" ] || machine=$(printf '%s' "$target" | sed 's/.*@//')
      # ssh stays a child so a signal to this script can be forwarded, logged,
      # and re-raised. The log is c11's own state directory, never hc's
      # ~/.local/share tree. One line per exit, appended, and held to 64 KiB.
      body="#!/bin/sh
# Ignore \$1. hc passes its default remote line, which runs whatever herdr-core is on PATH.
started=\$(date +%s)
$ssh -T -o BatchMode=yes -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 $LINK_SSH_NO_FORWARDING -- $target '$remote' <&0 &
child=\$!
trap 'kill -TERM \"\$child\" 2>/dev/null || true' TERM
trap 'kill -HUP \"\$child\" 2>/dev/null || true' HUP
trap 'kill -INT \"\$child\" 2>/dev/null || true' INT
status=0
while kill -0 \"\$child\" 2>/dev/null; do
  wait \"\$child\" || status=\$?
done
ended=\$(date +%s)
up=\$((ended - started))
if [ \"\$up\" -lt 0 ]; then up=0; fi
signal=-
if [ \"\$status\" -gt 128 ] && [ \"\$status\" -lt 160 ]; then
  signal=\$((status - 128))
fi
reason=-
case \"\$status\" in
  4) reason=hc_fd_limit ;;
  5) reason=hc_hash_mismatch ;;
  6) reason=hc_dir_refused ;;
  8) reason=hc_serving_mismatch ;;
  9) reason=hc_needs_linger ;;
  10) reason=hc_needs_user_manager ;;
esac
logdir=\"\$HOME/Library/Application Support/c11\"
log=\"\$logdir/link-ssh.log\"
mkdir -p \"\$logdir\" 2>/dev/null || true
# C11H-332: a refused dial names its reason, machine, host and session; c11
# turns these lines into audit records (it is the audit log's only writer).
{ printf '%s\\n' \"time=\$(date +%Y-%m-%dT%H:%M:%S%z) status=\$status signal=\$signal up_s=\$up reason=\$reason machine=$machine host=$target session=$session\" >> \"\$log\"; } 2>/dev/null || true
if [ -f \"\$log\" ]; then
  bytes=\$(wc -c < \"\$log\" | awk '{print \$1}')
  if [ \"\$bytes\" -gt 65536 ]; then
    tail -c 32768 \"\$log\" | awk 'NR>1' > \"\$log.\$\$.part\" && mv \"\$log.\$\$.part\" \"\$log\"
  fi
fi
if [ \"\$signal\" != \"-\" ]; then
  trap - TERM HUP INT
  kill -\"\$signal\" \$\$
fi
exit \$status
"
      ;;
    # C11H-332: ssh is the only mode; a via must carry the pin it checks.
    *) die "mode must be ssh" ;;
  esac
  umask 077
  mkdir -p "$(dirname "$out")"
  printf '%s' "$body" > "$out"
  chmod 700 "$out"
}

cmd_serve() {
  listen= session= socket= hc= home= user= sha=
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha) sha=$2; shift 2 ;;
      --listen) listen=$2; shift 2 ;;
      --session) session=$2; shift 2 ;;
      --socket) socket=$2; shift 2 ;;
      --hc) hc=$2; shift 2 ;;
      --home) home=$2; shift 2 ;;
      --user) user=$2; shift 2 ;;
      *) die "unknown serve option: $1" ;;
    esac
  done
  [ -n "$listen" ] || die "serve needs --listen"
  session_ok "$session" || die "bad session: $session"
  safe_path "$socket" || die "bad socket"
  safe_path "$hc" || die "bad hc path"
  safe_path "$listen" || die "bad listen socket"
  safe_path "$home" || die "bad home"
  safe_token "$user" || die "bad user"
  case "$socket" in
    */.local/share/c11/run/"$session".sock) ;;
    *) die "socket must be ~/.local/share/c11/run/$session.sock" ;;
  esac
  case "$hc" in
    */.local/share/c11/hc/*/herdr-core) ;;
    *) die "hc must be ~/.local/share/c11/hc/<pin>/herdr-core" ;;
  esac
  case "$hc" in
    */.local/bin/*) die "refusing herdr-app's binary path" ;;
  esac
  case "$listen" in
    */.local/bin/*) die "refusing to listen under ~/.local/bin" ;;
  esac
  # Darwin's sockaddr_un holds 103 bytes. Same ceiling as HCAtlasLink.maximumSocketPathBytes.
  listen_bytes=$(printf '%s' "$listen" | wc -c | awk '{print $1}')
  [ "$listen_bytes" -le 103 ] || die "listen socket is $listen_bytes bytes; the ceiling is 103"
  remote=$(remote_command "$session" "$socket" "$hc" "$home" "$user" "$sha")
  exec /usr/bin/python3 -I - "$listen" "$remote" <<'PY'
import os, socket, sys

listen, remote = sys.argv[1], sys.argv[2]
if os.path.exists(listen):
    sys.stderr.write("c11-atlas-link: listen socket exists\n")
    sys.exit(2)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(listen)
os.chmod(listen, 0o600)
srv.listen(1)
sys.stderr.write("listening %s\n" % listen)
sys.stderr.flush()
conn, _ = srv.accept()
# Protocol bytes stay on the socket. The limit log stays on this stderr.
os.dup2(conn.fileno(), 0)
os.dup2(conn.fileno(), 1)
os.execv("/bin/sh", ["sh", "-c", remote])
PY
}

pair_dir() { printf '%s/.local/share/c11' "$HOME"; }

# Pairing paths are managed only while their recorded bytes still match.
pair_real_path() {
  checked=$1
  while [ "$checked" != "$HOME" ]; do
    [ ! -L "$checked" ] || return 1
    parent=${checked%/*}
    [ -n "$parent" ] && [ "$parent" != "$checked" ] || return 1
    checked=$parent
  done
}

paired_vias() {
  f="$(pair_dir)/atlas-pair.json"
  pair_real_path "$f" && [ -f "$f" ] || return 0
  /usr/bin/python3 -I - "$f" <<'PAIRREAD'
import hashlib, json, os, re, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    raw = path.read_bytes()
    m = json.loads(raw)
    own = m.get("self_sha256")
    if not isinstance(own, str) or not re.fullmatch("[0-9a-f]{64}", own):
        sys.exit(0)
    field = b'"self_sha256":"' + own.encode() + b'"'
    if raw.count(field) != 1 or hashlib.sha256(raw.replace(field, b'"self_sha256":""')).hexdigest() != own:
        sys.exit(0)
    if m.get("pairing") != 1 or not isinstance(m.get("vias"), dict) or not isinstance(m.get("file_sha256"), dict):
        sys.exit(0)
    for session, via in m["vias"].items():
        if not re.fullmatch(r"c11(?:-[A-Za-z0-9][A-Za-z0-9._-]*)?-s[1-8]", session):
            continue
        p = path.parent / ("atlas-via-" + session + ".sh")
        if str(p) == via and not p.is_symlink() and p.is_file():
            if hashlib.sha256(p.read_bytes()).hexdigest() == m["file_sha256"].get(via):
                print(via)
except (OSError, ValueError, TypeError, AttributeError):
    pass
PAIRREAD
}

# C11H-332: migrate a stored via that an older c11 rendered without the pin:
# re-render it exactly as Update renders it, from its own target, session,
# socket, hc, home and user, with --sha added, and keep a pairing manifest
# that owns it consistent (its file hash and self hash updated in the same
# step). It grants no new trust: the operator consented when the link was
# made. C11H-361: a via that checks a pin but lacks LINK_SSH_NO_FORWARDING is
# re-rendered the same way with its own pin, not --sha: its hc path names
# that pin's version, so another hash would refuse every dial.
# Exit 0 prints `pinned` (already current) or `migrated`; exit 3: the via
# isn't one of c11's own files under ~/.local/share/c11; exit 4: it can't be
# read or re-rendered; exit 5: a pairing manifest lists it but doesn't own its
# current bytes. Nothing is changed unless it exits 0 with `migrated`.
cmd_migrate() {
  via= sha= machine=
  while [ $# -gt 0 ]; do
    case "$1" in
      --via) via=$2; shift 2 ;;
      --sha) sha=$2; shift 2 ;;
      --machine) machine=$2; shift 2 ;;
      *) die "unknown migrate option: $1" ;;
    esac
  done
  sha_ok "$sha" || die "migrate needs --sha: this c11's hc pin, 64 lower-case hex digits"
  [ -z "$machine" ] || safe_token "$machine" || die "bad machine name"
  [ -n "${HOME:-}" ] && safe_path "$HOME" || die "HOME is not a plain absolute path"
  if ! safe_path "$via"; then echo "via_outside"; exit 3; fi
  case "$via" in
    "$HOME"/.local/share/c11/*) ;;
    *) echo "via_outside"; exit 3 ;;
  esac
  if ! pair_real_path "$via" || [ -L "$via" ] || [ ! -f "$via" ] || [ "$(stat -f %u "$via")" != "$(id -u)" ]; then
    echo "via_outside"; exit 3
  fi
  own_sha=$(sed -nE 's/.* sha256=([0-9a-f]{64}) .*/\1/p' "$via" | head -n 1)
  if [ -n "$own_sha" ] && grep -Fq -- " $LINK_SSH_NO_FORWARDING -- " "$via"; then printf 'pinned %s\n' "$via"; exit 0; fi
  [ -z "$own_sha" ] || sha=$own_sha
  fields=$(/usr/bin/python3 -I - "$via" <<'MIGRATEPARSE'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^(/\S+) -T .* -- (\S+) '(.*)' <&0 &$", text, re.M)
if not m:
    sys.exit(4)
ssh, target, remote = m.groups()
def one(pattern):
    found = re.search(pattern, remote)
    if not found:
        sys.exit(4)
    return found.group(1)
values = [ssh, target, one(r"\bHOME=(\S+)"), one(r"\bUSER=(\S+)"), one(r"\bHC_SESSION=(\S+)"),
          one(r"\bHC_SOCKET=(\S+)"), one(r"(\S+) connect --session \S+\s*$")]
if any(not re.fullmatch(r"[A-Za-z0-9._/@-]+", v) for v in values):
    sys.exit(4)
# C11H-392: a Linux machine's via bakes bash; keep its platform.
values.append("linux" if re.search(r"\bSHELL=/bin/bash\b", remote) else "mac")
print(" ".join(values))
MIGRATEPARSE
) || { echo "unreadable"; exit 4; }
  # shellcheck disable=SC2086
  set -- $fields
  [ $# -eq 8 ] || { echo "unreadable"; exit 4; }
  m_ssh=$1 m_target=$2 m_home=$3 m_user=$4 m_session=$5 m_socket=$6 m_hc=$7 m_platform=$8
  old_hash=$(shasum -a 256 "$via" | awk '{print $1}')
  tmp="$via.migrate.$$"
  if ! ( cmd_render --mode ssh --out "$tmp" --session "$m_session" --socket "$m_socket" --hc "$m_hc" --sha "$sha" \
           --machine "$machine" --target "$m_target" --ssh "$m_ssh" --home "$m_home" --user "$m_user" \
           --platform "$m_platform" ) >/dev/null 2>&1; then
    rm -f "$tmp"; echo "render_refused"; exit 4
  fi
  new_hash=$(shasum -a 256 "$tmp" | awk '{print $1}')
  manifest="$(pair_dir)/atlas-pair.json"
  next_manifest=
  if pair_real_path "$manifest" && [ -f "$manifest" ]; then
    next_manifest=$(/usr/bin/python3 -I - "$manifest" "$via" "$old_hash" "$new_hash" <<'MIGRATEPAIR'
import hashlib, json, os, re, sys
from pathlib import Path
path, via, old, new = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
try:
    raw = path.read_bytes()
    m = json.loads(raw)
    own = m.get("self_sha256")
    field = b'"self_sha256":"' + str(own).encode() + b'"'
    intact = (isinstance(own, str) and re.fullmatch("[0-9a-f]{64}", own) and raw.count(field) == 1
              and hashlib.sha256(raw.replace(field, b'"self_sha256":""')).hexdigest() == own
              and m.get("pairing") == 1 and isinstance(m.get("vias"), dict) and isinstance(m.get("file_sha256"), dict))
except (OSError, ValueError, TypeError, AttributeError):
    intact = False
    m = {}
if not intact or via not in m["vias"].values():
    sys.exit(0)
if m["file_sha256"].get(via) != old:
    sys.exit(5)
m["file_sha256"][via] = new
m["self_sha256"] = ""
def encoded(): return (json.dumps(m, separators=(",", ":")) + "\n").encode()
m["self_sha256"] = hashlib.sha256(encoded()).hexdigest()
tmp = "%s.migrate.%d" % (path, os.getpid())
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
os.write(fd, encoded())
os.close(fd)
print(tmp)
MIGRATEPAIR
) || { rc=$?; rm -f "$tmp"; echo "pairing_unowned"; exit "$rc"; }
  fi
  mv -f "$tmp" "$via"
  [ -z "$next_manifest" ] || mv -f "$next_manifest" "$manifest"
  printf 'migrated %s\n' "$via"
}

# The CLI's rule (HCCoreUtility.insideC11Terminal): a c11 terminal, here or on
# a linked machine.
inside_c11_terminal() {
  [ -n "${C11_PANEL_ID:-}" ] || [ -n "${C11_SURFACE_ID:-}" ] || [ -n "${CMUX_SURFACE_ID:-}" ]
}

# C11H-365: a paired machine is added to each shard's core, which gives c11 a
# shell there as this user. pair goes on only after the operator types yes on
# a terminal, or with --yes outside a c11 terminal (an agent's shell there
# can't pass it); otherwise it exits 2 and writes nothing.
pair_consent() {
  c_yes=$1 c_machine=$2 c_shards=$3 c_base=$4 c_target=$5
  if [ -n "$c_yes" ]; then
    ! inside_c11_terminal || die "pair: --yes isn't accepted inside a c11 terminal. Pairing gives c11 a shell on $c_target as you, so the operator answers the question here; nothing written"
    return 0
  fi
  [ -t 0 ] && [ -t 2 ] || die "pair needs the operator's answer on a terminal, or --yes outside a c11 terminal; nothing written"
  printf "Pairing gives c11 a shell on %s as you: when a shard's core connects, c11 adds %s to it through ssh to %s.\n" \
    "$c_target" "$c_machine" "$c_target" >&2
  printf 'Pair %s shard(s), %s-s1..s%s, with %s through ssh to %s? [y/N] ' \
    "$c_shards" "$c_base" "$c_shards" "$c_machine" "$c_target" >&2
  answer=
  IFS= read -r answer || answer=
  case "$answer" in
    y|Y|yes|Yes|YES) return 0 ;;
  esac
  die "pair: not confirmed; nothing written"
}

cmd_pair() {
  mode= session= shards= hc= home= user= machine= target= ssh=/usr/bin/ssh sha= yes= platform=mac
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      --platform) platform=$2; shift 2 ;;
      --mode) mode=$2; shift 2 ;;
      --sha) sha=$2; shift 2 ;;
      --session) session=$2; shift 2 ;;
      --shards) shards=$2; shift 2 ;;
      --hc) hc=$2; shift 2 ;;
      --home) home=$2; shift 2 ;;
      --user) user=$2; shift 2 ;;
      --machine) machine=$2; shift 2 ;;
      --target) target=$2; shift 2 ;;
      --ssh) ssh=$2; shift 2 ;;
      *) die "unknown pair option: $1" ;;
    esac
  done
  session_ok "$session" || die "bad session: $session"
  sha_ok "$sha" || die "pair needs --sha: this c11's hc pin, 64 lower-case hex digits"
  printf '%s' "$shards" | grep -Eq '^[1-8]$' || die "--shards must be 1 to 8"
  case "$platform" in mac|linux) ;; *) die "platform must be mac or linux" ;; esac
  if [ -z "$target" ] && { [ "$mode" = ssh ] || [ -z "$machine" ]; }; then
    target=$(remote_host)
  fi
  [ -n "$machine" ] || machine=${target#*@}
  safe_token "$machine" || die "bad machine name"
  # c11 reads `local` as this Mac (C11H-357), so a pairing never names it.
  [ "$machine" != default ] && [ "$machine" != local ] || die "bad machine name"
  [ -n "${HOME:-}" ] && safe_path "$HOME" || die "HOME is not a plain absolute path"
  case "$mode" in
    ssh) ;;
    *) die "mode must be ssh" ;;
  esac
  dir=$(pair_dir)
  pair_real_path "$dir/atlas-pair.json" || die "symlinked pairing path; nothing written"
  ours=$(paired_vias)
  # Refuse before writing anything if a via path holds a file pair did not write.
  n=1
  while [ "$n" -le "$shards" ]; do
    via="$dir/atlas-via-$session-s$n.sh"
    pair_real_path "$via" || die "$via is a symlink; nothing written"
    if [ -e "$via" ] || [ -L "$via" ]; then
      printf '%s\n' "$ours" | grep -Fqx -- "$via" || die "$via exists and pair did not write it; nothing written"
    fi
    n=$((n + 1))
  done
  if [ -e "$dir/atlas-pair.json" ] && [ -z "$ours" ]; then
    die "$dir/atlas-pair.json exists and is not a pairing file; nothing written"
  fi
  safe_token "$target" || die "bad ssh target"
  pair_consent "$yes" "$machine" "$shards" "$session" "$target"
  # cmd_render assigns the shell's globals (session, mode, hc, ...): keep ours apart.
  p_base=$session p_mode=$mode p_hc=$hc p_home=$home p_user=$user p_target=$target p_ssh=$ssh
  p_machine=$machine p_dir=$dir p_shards=$shards p_sha=$sha p_platform=$platform
  entries=
  k=1
  while [ "$k" -le "$p_shards" ]; do
    shard="$p_base-s$k"
    via="$p_dir/atlas-via-$shard.sh"
    cmd_render --mode ssh --out "$via" --session "$shard" --socket "$p_home/.local/share/c11/run/$shard.sock" \
      --hc "$p_hc" --sha "$p_sha" --machine "$p_machine" --target "$p_target" --ssh "$p_ssh" --home "$p_home" --user "$p_user" \
      --platform "$p_platform"
    entries="$entries${entries:+,}\"$shard\":\"$via\""
    k=$((k + 1))
  done
  tmp="$p_dir/atlas-pair.json.tmp.$$"
  /usr/bin/python3 -I - "$p_machine" "$entries" > "$tmp" <<'PAIRWRITE'
import hashlib, json, sys
vias = json.loads("{" + sys.argv[2] + "}")
hashes = {}
for path in vias.values():
    with open(path, "rb") as source:
        hashes[path] = hashlib.sha256(source.read()).hexdigest()
m = {"pairing": 1, "machine": sys.argv[1], "acknowledged": 1, "vias": vias, "file_sha256": hashes, "self_sha256": ""}
def encoded(): return (json.dumps(m, separators=(",", ":")) + "\n").encode()
m["self_sha256"] = hashlib.sha256(encoded()).hexdigest()
sys.stdout.buffer.write(encoded())
PAIRWRITE
  chmod 600 "$tmp"
  mv -f "$tmp" "$p_dir/atlas-pair.json"
  # Vias an earlier pair wrote for shards no longer paired.
  printf '%s\n' "$ours" | while read -r old; do
    [ -n "$old" ] || continue
    case "$entries" in *"\"$old\""*) continue ;; esac
    case "$old" in "$p_dir"/atlas-via-c11*.sh) rm -f "$old" ;; esac
  done
  printf 'paired %s-s1..s%s with %s (%s)\n' "$p_base" "$p_shards" "$p_machine" "$p_mode"
}

cmd_unpair() {
  [ $# -eq 0 ] || die "unpair takes no options"
  [ -n "${HOME:-}" ] && safe_path "$HOME" || die "HOME is not a plain absolute path"
  dir=$(pair_dir)
  if ! pair_real_path "$dir/atlas-pair.json"; then
    printf 'symlinked pairing path at %s; nothing removed\n' "$dir"
    return 0
  fi
  ours=$(paired_vias)
  [ -n "$ours" ] || { printf 'no pairing file at %s; nothing removed\n' "$dir/atlas-pair.json"; return 0; }
  printf '%s\n' "$ours" | while read -r via; do
    case "$via" in
      "$dir"/atlas-via-c11*.sh) rm -f "$via" ;;
      *) printf 'c11-atlas-link: leaving %s: not a pair via path\n' "$via" >&2 ;;
    esac
  done
  rm -f "$dir/atlas-pair.json"
  printf 'unpaired: removed %s and its vias\n' "$dir/atlas-pair.json"
}

pin_in_use() {
  # C11H-365: in use only when a process of this account runs this file (its
  # program text, lsof's txt). Another account's process, or one whose
  # arguments merely name the path, does not count. lsof is in macOS's base
  # system, under /usr/sbin when PATH lacks it.
  # C11H-392: on Linux the kernel says it directly: a process of this account
  # whose /proc/<pid>/exe is this file's device and inode. No lsof needed.
  if [ "$(uname -s)" = Linux ]; then
    /usr/bin/python3 -I - "$1" <<'INUSE'
import os, sys
try:
    want = os.stat(sys.argv[1])
except OSError:
    sys.exit(1)
uid = os.getuid()
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    try:
        if os.stat("/proc/" + name).st_uid != uid:
            continue
        running = os.stat("/proc/%s/exe" % name)
    except OSError:
        continue
    if (running.st_dev, running.st_ino) == (want.st_dev, want.st_ino):
        sys.exit(0)
sys.exit(1)
INUSE
    return $?
  fi
  lsof_bin=$(command -v lsof || printf /usr/sbin/lsof)
  pids=$("$lsof_bin" -nP -w -t -a -u "$(id -u)" -d txt -- "$1" 2>/dev/null) || return 1
  [ -n "$pids" ]
}

cmd_install() {
  if [ "${1:-}" = --from ]; then
    [ $# -eq 2 ] || die "install --from needs one app path"
    exec /usr/bin/python3 -I "$(dirname "$0")/c11-install-remote-hc.py" --from "$2"
  fi
  pin= sha=
  while [ $# -gt 0 ]; do
    case "$1" in
      --pin) pin=$2; shift 2 ;;
      --sha) sha=$2; shift 2 ;;
      *) die "unknown install option: $1" ;;
    esac
  done
  printf '%s' "$pin" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "bad pin"
  printf '%s' "$sha" | grep -Eq '^[0-9a-f]{64}$' || die "bad sha256"
  [ -n "${HOME:-}" ] || die "HOME is unset"
  dest="$HOME/.local/share/c11/hc/$pin/herdr-core"
  case "$dest" in
    */.local/bin/*) die "refusing to write ~/.local/bin" ;;
  esac
  if [ -f "$dest" ]; then
    got=$(sha256_file "$dest")
    if [ "$got" = "$sha" ]; then
      printf 'unchanged %s\n' "$dest"
      exit 0
    fi
    if pin_in_use "$dest"; then
      printf 'c11-atlas-link: %s hash differs and the file is in use; not replaced\n' "$dest" >&2
      exit 3
    fi
  fi
  mkdir -p "$(dirname "$dest")"
  tmp="$dest.new.$$"
  cat > "$tmp"
  got=$(sha256_file "$tmp")
  if [ "$got" != "$sha" ]; then
    rm -f "$tmp"
    die "stdin sha256 $got does not match $sha"
  fi
  chmod 755 "$tmp"
  mv -f "$tmp" "$dest"
  printf 'installed %s\n' "$dest"
}

# C11H-332: pair, unpair and migrate change the pairing manifest and the vias
# it owns. One stable lock beside the manifest (`.atlas-pair.lock`, never
# renamed or removed) serializes them for the whole command, so two shards
# migrating at once can't each publish a manifest that drops the other's hash.
# A small Python parent holds it while the command runs; it waits at most 15 s
# (exit 4: busy, nothing changed).
PAIR_LOCK_PY='
import fcntl, os, subprocess, sys, time
try:
    fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
except OSError as error:
    print("c11-atlas-link: cannot open the pairing lock: %s; nothing changed" % error.strerror, file=sys.stderr)
    sys.exit(4)
deadline = time.monotonic() + 15
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        if time.monotonic() > deadline:
            print("c11-atlas-link: another pair, unpair or migrate is running; nothing changed", file=sys.stderr)
            sys.exit(4)
        time.sleep(0.02)
status = subprocess.call(sys.argv[2:])
sys.exit(status if status >= 0 else 128 - status)
'
with_pair_lock() {
  [ -n "${HOME:-}" ] && safe_path "$HOME" || die "HOME is not a plain absolute path"
  lock_dir=$(pair_dir)
  # A symlinked pairing path: each command refuses it on its own, writing nothing.
  pair_real_path "$lock_dir/.atlas-pair.lock" || { C11_PAIR_LOCK_HELD=1 /bin/sh "$0" "$@"; exit $?; }
  if [ ! -d "$lock_dir" ]; then
    # Nothing is paired yet: a migrate has no manifest to race on.
    [ "$1" != migrate ] || { C11_PAIR_LOCK_HELD=1 /bin/sh "$0" "$@"; exit $?; }
    /bin/mkdir -p "$lock_dir" || die "cannot create $lock_dir"
  fi
  C11_PAIR_LOCK_HELD=1 /usr/bin/python3 -I -c "$PAIR_LOCK_PY" "$lock_dir/.atlas-pair.lock" /bin/sh "$0" "$@"
  exit $?
}

[ $# -ge 1 ] || die "usage: render | serve | install | pair | unpair"
case "$1" in
  pair|unpair|migrate) [ -n "${C11_PAIR_LOCK_HELD:-}" ] || with_pair_lock "$@" ;;
esac
sub=$1
shift
case "$sub" in
  render) cmd_render "$@" ;;
  serve) cmd_serve "$@" ;;
  install) cmd_install "$@" ;;
  secure) cmd_secure "$@" ;;
  stop) cmd_stop "$@" ;;
  migrate) cmd_migrate "$@" ;;
  pair) cmd_pair "$@" ;;
  unpair) cmd_unpair "$@" ;;
  *) die "usage: render | serve | install | pair | unpair" ;;
esac
