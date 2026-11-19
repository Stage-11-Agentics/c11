#!/usr/bin/env bash
# Install or update c11 at a stable path.
#
# Usage: scripts/c11-install.sh [<zip-or-app>]
# With no argument, installs a c11.app sitting beside this script.
#
# Quits only bundle id com.stage11.c11. Never signals another app.
# Reads c11's settings on the first install and does not write them.
# Leaves ~/.local/share/c11/hc/ untouched.
# The hc core is bundled (C11H-66): there is no separate hc install step. The
# incoming helper must match its sealed hc-pin.json, and Contents/Helpers is
# made 0555 so hc's own `update` refuses (S1). Old copies are made writable
# only to be removed.
set -euo pipefail

EXPECTED_BUNDLE_ID="com.stage11.c11"
SOURCE_DOMAIN="com.stage11.c11"
DEST_DOMAIN="com.stage11.c11"
PORT_BASE="29100"

if [[ -n "${C11_HOME:-}" ]]; then
  HOME_ROOT="$C11_HOME"
  USE_DEFAULTS=0
else
  HOME_ROOT="${HOME:?}"
  USE_DEFAULTS=1
fi

APP_PATH="${C11_APP_PATH:-/Applications/c11.app}"
HC_ROOT="${C11_HC_ROOT:-$HOME_ROOT/.local/share/c11/hc}"
QUIT_MODE="${C11_QUIT_MODE:-live}"
SUPPORT_SRC="$HOME_ROOT/Library/Application Support/c11"
SUPPORT_DST="$HOME_ROOT/Library/Application Support/c11"
MARKER="$SUPPORT_DST/.c11-settings-imported"
OSASCRIPT="${C11_OSASCRIPT:-/usr/bin/osascript}"
CODESIGN="${C11_CODESIGN:-/usr/bin/codesign}"
LSOF="${C11_LSOF:-/usr/sbin/lsof}"
XCODE_SELECT="${C11_XCODE_SELECT:-/usr/bin/xcode-select}"
# C11H-100: c11 treats TERM as a clean quit (final snapshot, clean shutdown marker), so an update
# no longer reads as a crash. It gets QUIT_WAIT_TRIES x 0.2 s to finish before KILL ends it.
KILL_BIN="${C11_KILL:-/bin/kill}"
QUIT_WAIT_TRIES="${C11_QUIT_WAIT_TRIES:-100}"

die() {
  printf 'c11-install: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/c11-install.sh [<artifact>]

Install or update c11. <artifact> is a .zip that contains c11.app, or a
c11.app bundle. With no argument, uses a c11.app beside this script.

The app is swapped into /Applications/c11.app (override C11_APP_PATH).
An update quits bundle id com.stage11.c11 only, then renames the new app
into place. c11 gets TERM, its clean quit, and 20 s to finish before KILL.
If that query fails, the app already on disk stays. A failed
copy is removed. hc at ~/.local/share/c11/hc/ is only read, including the
pinned herdr-core.

The hc core ships inside the app (Contents/Helpers/herdr-core); there is no
separate hc install step. An app whose helper does not match its hc-pin.json,
or whose signature does not verify, is refused before anything is replaced.
Contents/Helpers is set to mode 0555, so hc's own update refuses.
A core still running from the replaced app keeps its executable: while some
process runs the old app's helper, the old app is renamed whole (same volume,
so the process follows it) into .<app name>-helpers/ beside the app, and the
new app accepts that core as already serving. A retained app no process runs
any more is removed by the next install.

The first install copies c11's settings into c11, including settings
reached through links, as c11's own files. Sparkle keys, socket keys,
and cmuxPortBase are left out; c11's port base is set to 29100.
A later install does not import again. c11's files are only read.
EOF
}

hc_snapshot() {
  python3 - "$HC_ROOT" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
if not os.path.exists(root):
    sys.stdout.write("absent\n")
    raise SystemExit(0)
lines = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        if os.path.islink(path):
            lines.append("link\t%s\t%s" % (rel, os.readlink(path)))
        elif os.path.isfile(path):
            digest = hashlib.sha256()
            with open(path, "rb") as handle:
                for chunk in iter(lambda: handle.read(1 << 20), b""):
                    digest.update(chunk)
            lines.append("file\t%s\t%s" % (rel, digest.hexdigest()))
        else:
            lines.append("other\t%s" % rel)
sys.stdout.write("\n".join(lines) + ("\n" if lines else ""))
PY
}

# C11H-66: a bundled helper must be the file its sealed manifest names, and the
# app's signature must hold. An app with neither helper nor manifest (the
# transition's external-pin build) passes; half of one does not.
verify_bundled_core() {
  local app="$1" helper="$1/Contents/Helpers/herdr-core" manifest="$1/Contents/Resources/hc-pin.json" want got
  if [[ ! -e "$helper" && ! -e "$manifest" ]]; then
    return 0
  fi
  [[ -f "$helper" && -f "$manifest" ]] || die "$app has half a bundled hc core"
  want="$(/usr/bin/plutil -extract executableSHA256 raw -o - "$manifest" 2>/dev/null)" \
    || die "$manifest has no executableSHA256"
  got="$(/usr/bin/shasum -a 256 "$helper" | /usr/bin/awk '{print $1}')"
  [[ "$got" == "$want" ]] || die "bundled hc core hashes to $got, not $want"
  "$CODESIGN" --verify --deep --strict "$app" >/dev/null 2>&1 || die "$app signature does not verify"
}

# 0555 on Helpers (S1). The owner can still chmod it back; this is a guard
# against accidents, not a security boundary.
lock_helpers() {
  local helpers="$1/Contents/Helpers"
  [[ -d "$helpers" ]] || return 0
  chmod 0555 "$helpers/herdr-core" 2>/dev/null || true
  chmod 0555 "$helpers"
}

# rm -rf cannot unlink entries of a 0555 folder.
make_removable() {
  local helpers="$1/Contents/Helpers"
  if [[ -d "$helpers" ]]; then
    chmod u+w "$helpers" 2>/dev/null || true
  fi
}

# Retained apps (C11H-66). A core (or holder) of a replaced app runs that app's
# Contents/Helpers/herdr-core, so the replaced app is kept, renamed whole into
# .<app name>-helpers/ beside the app, while any process still runs its helper.
# rename(2) keeps the vnode, so the process's executable path follows it and
# the new app can still verify that core by path and hash. Nothing inside a
# bundle a core ran from is changed. An entry has no .app extension, so it is
# not an app to LaunchServices.
retained_root() {
  printf '%s/.%s-helpers\n' "$(dirname "$1")" "$(basename "$1")"
}

helper_in_use() {
  [[ -f "$1" ]] && "$LSOF" -t -- "$1" >/dev/null 2>&1
}

# Removes an app copy; never fails the install. macOS can refuse to change a
# bundle whose executable has run; what cannot be removed is parked in the
# retained root and pruned by a later install.
remove_app_copy() {
  local copy="$1" dest="$2" root
  make_removable "$copy"
  rm -rf "$copy" 2>/dev/null || true
  [[ -e "$copy" ]] || return 0
  printf 'c11-install: macOS refused to remove %s for now; a later install removes it\n' "$copy" >&2
  root="$(retained_root "$dest")"
  case "$copy" in "$root"/*) return 0 ;; esac
  mkdir -p "$root"
  mv "$copy" "$(mktemp -u "$root/removed.XXXXXX")" 2>/dev/null || true
}

# A retained entry whose helper no process runs is removed.
prune_retained() {
  local dest="$1" root entry
  root="$(retained_root "$dest")"
  [[ -d "$root" ]] || return 0
  for entry in "$root"/*; do
    [[ -e "$entry" ]] || continue
    if helper_in_use "$entry/Contents/Helpers/herdr-core"; then
      continue
    fi
    remove_app_copy "$entry" "$dest"
  done
  rmdir "$root" 2>/dev/null || true
}

# The replaced app is retained when some process runs its helper and that
# helper is the file its sealed manifest names; otherwise it is removed.
retain_or_remove() {
  local previous="$1" dest="$2" helper manifest want got root
  helper="$previous/Contents/Helpers/herdr-core"
  manifest="$previous/Contents/Resources/hc-pin.json"
  if [[ -f "$manifest" ]] && helper_in_use "$helper"; then
    want="$(/usr/bin/plutil -extract executableSHA256 raw -o - "$manifest" 2>/dev/null || true)"
    got="$(/usr/bin/shasum -a 256 "$helper" | /usr/bin/awk '{print $1}')"
    if [[ -n "$want" && "$got" == "$want" ]]; then
      root="$(retained_root "$dest")"
      mkdir -p "$root"
      if mv "$previous" "$(mktemp -u "$root/${got:0:12}.XXXXXX")"; then
        return 0
      fi
    else
      printf 'c11-install: a running hc core does not match its hc-pin.json; not kept\n' >&2
    fi
  fi
  remove_app_copy "$previous" "$dest"
}

bundle_id_of() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  [[ -f "$plist" ]] || die "no Info.plist in $app"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null \
    || die "no bundle id in $app"
}

# Fixed query. The bundle id is not a parameter, so a caller cannot aim this
# at com.stage11.c11 or herdr-app.
quit_c11() {
  if [[ "$QUIT_MODE" == "record" ]]; then
    [[ -n "${C11_QUIT_LOG:-}" ]] || die "C11_QUIT_LOG is required when C11_QUIT_MODE=record"
    printf '%s\n' "$EXPECTED_BUNDLE_ID" >> "$C11_QUIT_LOG"
    return 0
  fi
  [[ "$QUIT_MODE" == "live" ]] || die "C11_QUIT_MODE must be live or record"
  [[ "$QUIT_WAIT_TRIES" =~ ^[0-9]+$ ]] || die "C11_QUIT_WAIT_TRIES must be a whole number"
  local raw pid raw_rc=0
  local -a pids=()
  # No match exits 0 with an empty result. A real failure must not look like
  # "nothing running", or the swap would replace an app we could not see.
  raw="$("$OSASCRIPT" -e 'tell application "System Events" to get unix id of every process whose bundle identifier is "com.stage11.c11"' 2>/dev/null)" || raw_rc=$?
  if [[ "$raw_rc" -ne 0 ]]; then
    die "could not query processes for com.stage11.c11"
  fi
  raw="${raw//,/ }"
  for pid in $raw; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" -gt 1 ]] || continue
    pids+=("$pid")
  done
  [[ ${#pids[@]} -eq 0 ]] && return 0
  # TERM is c11's clean quit (C11H-100): it suspends conversations, writes the final snapshot
  # and marks the shutdown clean, then exits. Only these pids, never a name.
  "$KILL_BIN" -TERM "${pids[@]}" 2>/dev/null || true
  local try=0 still
  while :; do
    still=()
    for pid in "${pids[@]}"; do
      if "$KILL_BIN" -0 "$pid" 2>/dev/null; then
        still+=("$pid")
      fi
    done
    [[ ${#still[@]} -eq 0 ]] && return 0
    pids=("${still[@]}")
    [[ "$try" -ge "$QUIT_WAIT_TRIES" ]] && break
    try=$((try + 1))
    sleep 0.2
  done
  printf 'c11-install: c11 (pid %s) did not quit within %s s; ending it, so its next launch reads as a crash\n' \
    "${pids[*]}" "$((QUIT_WAIT_TRIES / 5))" >&2
  "$KILL_BIN" -KILL "${pids[@]}" 2>/dev/null || true
}

import_settings() {
  C11_IMPORT_HOME="$HOME_ROOT" \
  C11_IMPORT_SUPPORT_SRC="$SUPPORT_SRC" \
  C11_IMPORT_SUPPORT_DST="$SUPPORT_DST" \
  C11_IMPORT_USE_DEFAULTS="$USE_DEFAULTS" \
  python3 - <<'PY'
import hashlib, os, plistlib, subprocess, sys

home = os.environ["C11_IMPORT_HOME"]
support_src = os.environ["C11_IMPORT_SUPPORT_SRC"]
support_dst = os.environ["C11_IMPORT_SUPPORT_DST"]
use_defaults = os.environ["C11_IMPORT_USE_DEFAULTS"] == "1"
source_domain = "com.stage11.c11"
dest_domain = "com.stage11.c11"
port_base = 29100
prefs = os.path.join(home, "Library", "Preferences")

def excluded(key):
    lowered = key.lower()
    if key == "cmuxPortBase":
        return True
    if key.startswith("SU"):
        return True
    if "sparkle" in lowered:
        return True
    if "socket" in lowered:
        return True
    # c11's own settings (c11.*) are never taken from c11, so c11-owned
    # defaults such as the Dark-slot sidebar look hold after the import.
    if key.startswith("c11."):
        return True
    # c11 never sends telemetry; c11's choice is not carried over.
    if key == "sendAnonymousTelemetry" or "telemetry" in lowered:
        return True
    return False

def digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()

def read_only_bytes(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        chunks = []
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)

def write_bytes(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".incoming"
    with open(tmp, "wb") as handle:
        handle.write(data)
    os.replace(tmp, path)

def load_plist(data):
    if not data:
        return {}
    loaded = plistlib.loads(data)
    if not isinstance(loaded, dict):
        raise SystemExit("c11-install: source defaults are not a dictionary")
    return loaded

def canonical(mapping):
    return plistlib.dumps(mapping, sort_keys=True, fmt=plistlib.FMT_XML)

source_plist_path = os.path.join(prefs, source_domain + ".plist")
dest_plist_path = os.path.join(prefs, dest_domain + ".plist")

if use_defaults:
    exported = subprocess.run(
        ["defaults", "export", source_domain, "-"],
        check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if exported.returncode != 0:
        err = exported.stderr.decode("utf-8", "replace")
        if "does not exist" in err or exported.returncode == 1:
            source = {}
            source_canon = canonical(source)
        else:
            sys.stderr.write("c11-install: could not read c11 settings\n")
            raise SystemExit(1)
    else:
        source = load_plist(exported.stdout)
        source_canon = canonical(source)
else:
    if os.path.exists(source_plist_path):
        raw = read_only_bytes(source_plist_path)
        source = load_plist(raw)
        source_canon = raw
    else:
        source = {}
        source_canon = b""

kept = {key: value for key, value in source.items() if not excluded(key)}
kept["cmuxPortBase"] = port_base
payload = plistlib.dumps(kept, sort_keys=True, fmt=plistlib.FMT_XML)

if use_defaults:
    tmp_dir = os.path.join(support_dst, ".import-tmp")
    os.makedirs(tmp_dir, exist_ok=True)
    tmp_plist = os.path.join(tmp_dir, "import.plist")
    try:
        write_bytes(tmp_plist, payload)
        imported = subprocess.run(
            ["defaults", "import", dest_domain, tmp_plist],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    finally:
        if os.path.exists(tmp_plist):
            os.remove(tmp_plist)
        try:
            os.rmdir(tmp_dir)
        except OSError:
            pass
    if imported.returncode != 0:
        sys.stderr.write("c11-install: could not write c11 settings\n")
        raise SystemExit(1)
    again = subprocess.run(
        ["defaults", "export", source_domain, "-"],
        check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if again.returncode != 0:
        again_source = {}
    else:
        again_source = load_plist(again.stdout)
    if canonical(again_source) != source_canon and source:
        sys.stderr.write("c11-install: c11 settings changed while importing\n")
        raise SystemExit(1)
else:
    write_bytes(dest_plist_path, payload)
    if os.path.exists(source_plist_path):
        if read_only_bytes(source_plist_path) != source_canon:
            sys.stderr.write("c11-install: c11 settings file changed while importing\n")
            raise SystemExit(1)

file_hashes = {}

def remember(path):
    # isfile follows a link. A dangling link is not a file and is not copied.
    if os.path.isfile(path):
        file_hashes[path] = digest(path)

def materialize(src_path, dst_path):
    # Readers accept a link to a file. c11 gets an independent regular file,
    # so a relative target outside this tree cannot dangle after the copy.
    if not os.path.isfile(src_path):
        return
    remember(src_path)
    write_bytes(dst_path, read_only_bytes(src_path))

def copy_tree(src, dst):
    for dirpath, dirnames, filenames in os.walk(src, followlinks=False):
        dirnames.sort()
        rel_dir = os.path.relpath(dirpath, src)
        target_dir = dst if rel_dir == "." else os.path.join(dst, rel_dir)
        os.makedirs(target_dir, exist_ok=True)
        for name in sorted(filenames):
            materialize(os.path.join(dirpath, name), os.path.join(target_dir, name))

agent_configs = os.path.join(support_src, "agent-configs.json")
materialize(agent_configs, os.path.join(support_dst, "agent-configs.json"))

themes = os.path.join(support_src, "themes")
if os.path.isdir(themes):
    copy_tree(themes, os.path.join(support_dst, "themes"))

for path, before in file_hashes.items():
    if digest(path) != before:
        sys.stderr.write("c11-install: c11 file changed while copying\n")
        raise SystemExit(1)
PY
}

find_app() {
  local root="$1"
  local -a apps=()
  local path
  while IFS= read -r -d '' path; do
    apps+=("$path")
  done < <(find "$root" -maxdepth 3 -name 'c11.app' -type d -print0)
  [[ ${#apps[@]} -eq 1 ]] || die "expected one c11.app in the artifact, found ${#apps[@]}"
  printf '%s\n' "${apps[0]}"
}

resolve_artifact() {
  local artifact="$1"
  if [[ -z "$artifact" ]]; then
    local sibling
    sibling="$(cd "$(dirname "$0")" && pwd)/c11.app"
    [[ -d "$sibling" ]] || die "give a zip or c11.app, or place c11.app beside this script"
    SRC_APP="$sibling"
    return 0
  fi
  if [[ -d "$artifact" && "$artifact" == *.app ]]; then
    SRC_APP="$artifact"
    return 0
  fi
  if [[ -f "$artifact" && "$artifact" == *.zip ]]; then
    EXTRACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/c11-install.XXXXXX")"
    ditto -x -k "$artifact" "$EXTRACT_DIR"
    SRC_APP="$(find_app "$EXTRACT_DIR")"
    return 0
  fi
  die "artifact must be a .zip or a .app"
}

swap_app() {
  local src="$1"
  local dest="$2"
  local parent incoming previous
  parent="$(dirname "$dest")"
  mkdir -p "$parent"
  incoming="${dest}.incoming.$$"
  previous="${dest}.previous.$$"
  INCOMING="$incoming"
  PREVIOUS=""
  if [[ -e "$incoming" ]]; then make_removable "$incoming"; fi
  rm -rf "$incoming"
  ditto "$src" "$incoming"
  lock_helpers "$incoming"
  if [[ -d "$dest" ]]; then
    mv "$dest" "$previous"
    PREVIOUS="$previous"
  fi
  if ! mv "$incoming" "$dest"; then
    if [[ -n "$PREVIOUS" && -d "$PREVIOUS" && ! -d "$dest" ]]; then
      mv "$PREVIOUS" "$dest" || true
      PREVIOUS=""
    fi
    die "could not swap $dest into place"
  fi
  INCOMING=""
  if [[ -n "$PREVIOUS" ]]; then
    prune_retained "$dest"
    retain_or_remove "$PREVIOUS" "$dest"
    PREVIOUS=""
  fi
}

EXTRACT_DIR=""
HC_ARMED=0
HC_BEFORE=""
INCOMING=""
PREVIOUS=""

on_exit() {
  local rc=$?
  trap - EXIT
  if [[ -n "$EXTRACT_DIR" ]]; then
    chmod -R u+w "$EXTRACT_DIR" 2>/dev/null || true
    rm -rf "$EXTRACT_DIR"
  fi
  # A crash between the two renames leaves the live app under PREVIOUS.
  if [[ -n "$PREVIOUS" && -d "$PREVIOUS" && ! -d "$APP_PATH" ]]; then
    mv "$PREVIOUS" "$APP_PATH" || true
  fi
  if [[ -n "$INCOMING" && -e "$INCOMING" ]]; then
    make_removable "$INCOMING"
    rm -rf "$INCOMING"
  fi
  if [[ "$HC_ARMED" -eq 1 ]]; then
    local after
    after="$(hc_snapshot)"
    if [[ "$after" != "$HC_BEFORE" ]]; then
      printf 'c11-install: hc tree at %s changed\n' "$HC_ROOT" >&2
      exit 1
    fi
  fi
  exit "$rc"
}
trap on_exit EXIT

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -gt 1 ]]; then
  die "one artifact only"
fi
if [[ "${1:-}" == -* ]]; then
  die "unknown option $1"
fi

# The installer runs python3. Without the Xcode Command Line Tools, /usr/bin/python3 is only
# a stub that opens macOS's install prompt and fails, so say so before anything starts. The
# stub runs <developer dir>/usr/bin/python3; running the stub itself would open the prompt.
python_preflight() {
  local py dev
  py="$(command -v python3 2>/dev/null)" \
    || die "needs python3 and found none on PATH. Install Apple's Command Line Tools (xcode-select --install), then run this installer again. Nothing was changed."
  [[ "$py" == /usr/bin/python3 ]] || return 0
  if dev="$("$XCODE_SELECT" -p 2>/dev/null)" && [[ -x "$dev/usr/bin/python3" ]]; then
    return 0
  fi
  die "needs python3, which comes with Apple's Command Line Tools, and they are missing or broken on this Mac. Run xcode-select --install, wait for it to finish, then run this installer again. Nothing was changed."
}
python_preflight

case "$(basename "$APP_PATH")" in
  c11.app) ;;
  c11h.app) die "refusing to install over c11h.app" ;; # c11-2.0:keep (the retired app stays, so going back works)
  *) die "stable path must be named c11.app" ;;
esac
case "$APP_PATH" in
  /Applications/c11h.app|*/c11h.app) die "refusing to install over c11h.app" ;; # c11-2.0:keep
esac

SRC_APP=""
resolve_artifact "${1:-}"
[[ -n "$SRC_APP" && -d "$SRC_APP" ]] || die "could not find c11.app"
SRC_ID="$(bundle_id_of "$SRC_APP")"
[[ "$SRC_ID" == "$EXPECTED_BUNDLE_ID" ]] || die "refusing bundle id $SRC_ID"
verify_bundled_core "$SRC_APP"

if [[ -e "$APP_PATH" && ! -d "$APP_PATH" ]]; then
  die "$APP_PATH exists and is not an app bundle"
fi
DEST_EXISTED=0
if [[ -d "$APP_PATH" ]]; then
  DEST_ID="$(bundle_id_of "$APP_PATH")"
  [[ "$DEST_ID" == "$EXPECTED_BUNDLE_ID" ]] || die "refusing to replace $APP_PATH (bundle id $DEST_ID)"
  DEST_EXISTED=1
fi

HC_BEFORE="$(hc_snapshot)"
HC_ARMED=1

IMPORTED=0
# c11 2.0 imports nothing here: a first launch carries the retired line's or c11 1.x's state over
# itself (C11H-266), so the source and destination are the same domain and this never runs.
if [[ "$SOURCE_DOMAIN" != "$DEST_DOMAIN" && "$DEST_EXISTED" -eq 0 && ! -f "$MARKER" ]]; then
  import_settings
  IMPORTED=1
fi

if [[ "$DEST_EXISTED" -eq 1 ]]; then
  quit_c11
fi

swap_app "$SRC_APP" "$APP_PATH"

if [[ "$IMPORTED" -eq 1 ]]; then
  mkdir -p "$SUPPORT_DST"
  printf 'v1\nsource=%s\nport_base=%s\n' "$SOURCE_DOMAIN" "$PORT_BASE" > "$MARKER"
fi

printf 'installed %s imported=%s\n' "$APP_PATH" "$([[ "$IMPORTED" -eq 1 ]] && printf yes || printf no)"
