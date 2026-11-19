#!/usr/bin/env bash
# Build a c11 Release app on the build host, sign it, and write one local zip.
#
#   scripts/c11-release.sh --build
#   scripts/c11-release.sh --sign-app /path/to/c11.app [--remote-artifacts <dir>]
#
# Signs only an app whose bundle id is already com.stage11.c11. A staging
# app (LSEnvironment set) and com.stage11.c11 are refused before the keychain
# is unlocked. Nothing is published. Notarization runs only with --notarize
# and C11_NOTARIZE_GO=1: the signed app is notarized and stapled before the
# zip is written, so the zip carries a stapled app.
#
# Every run records its time: one JSON line per run in release-timing.jsonl
# beside the zip (C11_TIMING_LOG overrides it), with each step's seconds
# (build, locate, stage, sign, notarize, staple, zip), the total and the step that
# failed. scripts/c11-release-timing.py prints the log.
set -euo pipefail

EXPECTED_BUNDLE_ID="com.stage11.c11"
IDENTITY="${C11_SIGNING_IDENTITY:-Developer ID Application: Authentic Technologies Inc. (UKQ4QALWD4)}"
# The notarytool profile stored in the release keychain itself (not the login
# keychain). The keychain is unlocked only for the submission, then relocked.
NOTARY_PROFILE="${C11_NOTARY_PROFILE:-acetate-notary}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT/c11.entitlements"
INSTALL_SH="$ROOT/scripts/c11-install.sh"
# C11H-130: the friend's install guide rides in the zip as README.md, so whoever is handed
# the zip has the instructions without the private repo.
GUIDE="${C11_FRIEND_GUIDE:-$ROOT/docs/c11-friend-install.md}"
ARTIFACT="${C11_ARTIFACT:-$HOME/c11h-run/artifacts/c11/c11-macos.zip}"
# c11-b is the shared tag for seats without their own lane. A private tag
# would count against the 50 GB cap. C11_RELEASE_TAG overrides it in tests.
TAG="${C11_RELEASE_TAG:-c11-b}"
BUILD_ROOT="${C11_BUILD_ROOT:-$HOME/c11-builds}"
ATLAS_BUILD="${C11_ATLAS_BUILD:-$HOME/c11h-run/bin/atlas-build}"
SECURITY="${C11_SECURITY:-/usr/bin/security}"
CODESIGN="${C11_CODESIGN:-/usr/bin/codesign}"
XCRUN="${C11_XCRUN:-/usr/bin/xcrun}"
STAPLE_TRIES="${C11_STAPLE_TRIES:-4}"
STAPLE_SLEEP="${C11_STAPLE_SLEEP:-15}"
NOTARY_RECORD=""
TIMING_LOG="${C11_TIMING_LOG:-$(dirname "$ARTIFACT")/release-timing.jsonl}"
TIMING_STEPS=""
MODE=""

die() {
  printf 'c11-release: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/c11-release.sh --build
       scripts/c11-release.sh --sign-app <c11.app>

--build    Release build through the build host's wrapper (C11_ATLAS_BUILD)
           (--mode release --clean --wmo --universal), then sign the pristine
           app. Tag defaults to c11-b (C11_RELEASE_TAG).
--sign-app Sign an app that already has bundle id com.stage11.c11.
--remote-artifacts <dir>
           Before signing, name the Linux machine's hc and relay CLI in the
           app by hash (scripts/c11-remote-artifacts.sh stamp: <dir> holds
           herdr-core and c11 for x86-64 Linux) and lay them out as release
           assets in <dir>/assets. Without it the app refuses to add a Linux
           machine. Nothing is uploaded.

The zip is written to C11_ARTIFACT (default: c11-macos.zip in the run's artifacts folder).
It contains c11.app, c11-install.sh and README.md (docs/c11-friend-install.md). Beside it, <zip>.identity.txt names
the bundle id, version, commit and the zip's sha256, and <zip>.sha256 holds the
same hash in shasum's format. --build signs only an app
whose C11Commit is this HEAD. No appcast and no GitHub release.

C11_RELEASE_KEYCHAIN=acetate (default) uses acetate-release.keychain-db.
C11_RELEASE_KEYCHAIN=c11 uses C11_REF_RELEASE_KEYCHAIN and
C11_REF_RELEASE_KEYCHAIN_PASS, and stops if those are unset.

--notarize submits the signed app with notarytool (profile acetate-notary in
the release keychain, C11_NOTARY_PROFILE), staples and validates the ticket,
and only then writes the zip. The identity file then also names notary_id,
notary_status and stapled. A rejected submission writes its notary log to
<zip>.notary-log.json and publishes no zip. --notarize requires
C11_NOTARIZE_GO=1, the Orchestrator's go; without it the script stops before
building, unlocking or submitting anything.
EOF
}

clock() {
  python3 -I -S -c 'import time; print("%.3f" % time.time())'
}

# Step marks go to a file, so a step inside the signing subshell, or one a
# die ends, is still recorded. Recording never fails a release.
step_begin() {
  [[ -n "$TIMING_STEPS" ]] || return 0
  printf 'begin %s %s\n' "$1" "$(clock)" >> "$TIMING_STEPS" 2>/dev/null || true
}

step_end() {
  [[ -n "$TIMING_STEPS" ]] || return 0
  printf 'end %s %s %s\n' "$1" "$(clock)" "$2" >> "$TIMING_STEPS" 2>/dev/null || true
}

timing_note() {
  [[ -n "$TIMING_STEPS" ]] || return 0
  printf 'note %s %s\n' "$1" "$2" >> "$TIMING_STEPS" 2>/dev/null || true
}

timing_start() {
  TIMING_STEPS="$(mktemp "${TMPDIR:-/tmp}/c11-release-timing.XXXXXX" 2>/dev/null)" || TIMING_STEPS=""
  [[ -n "$TIMING_STEPS" ]] || return 0
  printf 'start %s\n' "$(clock)" >> "$TIMING_STEPS" 2>/dev/null || true
  # Called in an || list, so set -e is off inside it and nothing in it can
  # replace the script's exit status.
  trap 'timing_finish $? || :' EXIT
}

# What this run signs, read from its staged copy, so a later rebuild of the
# shared tag cannot rename the record.
timing_note_build() {
  local info="$1/Contents/Info.plist" key
  for key in C11Version CFBundleShortVersionString CFBundleVersion C11Commit; do
    timing_note "$key" "$(/usr/libexec/PlistBuddy -c "Print :$key" "$info" 2>/dev/null || true)"
  done
}

# The EXIT trap: one JSON line for the run, and a summary line on stdout.
timing_finish() {
  local rc="$1"
  [[ -n "$TIMING_STEPS" && -f "$TIMING_STEPS" ]] || return 0
  python3 -I - "$TIMING_STEPS" "$TIMING_LOG" "$rc" "$MODE" "$NOTARIZE" "${C11_SIGN_DRY:-0}" \
    "$TAG" "$BUILD_ROOT" <<'PY' || printf 'c11-release: warning: could not record this run in %s\n' "$TIMING_LOG" >&2
import datetime, json, os, sys, time


def main():
    steps_path, log_path, rc, mode, notarize, dry, tag, build_root = sys.argv[1:9]
    rc = int(rc)
    end = time.time()
    start = end
    order, opened, steps, notes, failed = [], {}, {}, {}, None
    with open(steps_path, encoding="utf-8") as handle:
        for line in handle:
            kind, _, rest = line.rstrip("\n").partition(" ")
            if kind == "start":
                start = float(rest)
            elif kind == "note":
                key, _, value = rest.partition(" ")
                notes[key] = value
            elif kind == "begin":
                name, _, when = rest.partition(" ")
                opened[name] = float(when)
                if name not in order:
                    order.append(name)
            elif kind == "end":
                name, when, code = rest.split(" ")
                began = opened.pop(name, None)
                if began is not None:
                    steps[name] = round(float(when) - began, 1)
                if code != "0" and failed is None:
                    failed = name
    for name, began in opened.items():
        # Begun and never ended: a die or exit inside the step.
        steps[name] = round(end - began, 1)
        if failed is None and rc != 0:
            failed = name

    version = notes.get("C11Version", "").strip()
    if not version or "$(" in version:
        version = notes.get("CFBundleShortVersionString", "").strip()
    record = {
        "schema": 1,
        "script": "c11-release",
        "started": datetime.datetime.fromtimestamp(start).astimezone().isoformat(timespec="seconds"),
        "started_epoch": round(start, 3),
        "host": os.uname().nodename.split(".")[0],
        "mode": mode,
        "notarize": notarize == "1",
        "dry": dry == "1",
        "tag": tag,
        "c11_version": version,
        "build": notes.get("CFBundleVersion", ""),
        "commit": notes.get("C11Commit", ""),
        "result": "ok" if rc == 0 else "failed",
        "exit": rc,
        "failed_step": failed if rc != 0 else None,
        "total_s": round(end - start, 1),
        "steps": {name: steps[name] for name in order if name in steps},
    }
    # The remote build route's own record of this build: compile time apart from the
    # wait for a build slot. Rows land when a build ends, not in start order.
    gates = os.path.join(build_root, "gates.jsonl")
    if "build" in record["steps"] and os.path.isfile(gates):
        try:
            with open(gates, encoding="utf-8") as handle:
                rows = [json.loads(row) for row in handle if row.strip()]
            for row in reversed(rows):
                if not isinstance(row, dict) or row.get("tag") != tag or row.get("mode") != "release":
                    continue
                if record["commit"] and not str(row.get("head", "")).startswith(record["commit"]):
                    continue
                if datetime.datetime.fromisoformat(row["started"]).timestamp() < start - 5:
                    continue
                record["atlas_compile_s"] = round(float(row.get("build_seconds", 0)), 1)
                record["atlas_slot_wait_s"] = round(float(row.get("slot_wait_seconds", 0)), 1)
                break
        except Exception:
            pass
    try:
        directory = os.path.dirname(log_path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, separators=(",", ":")) + "\n")
    except OSError as error:
        sys.stderr.write("c11-release: warning: could not write the timing log %s: %s\n" % (log_path, error))
        return
    parts = ["%s=%.1fs" % (name, value) for name, value in record["steps"].items()]
    parts.append("total=%.1fs" % record["total_s"])
    if record["failed_step"]:
        parts.append("failed=%s" % record["failed_step"])
    try:
        print("timing %s (%s)" % (" ".join(parts), log_path))
    except OSError:
        pass


try:
    main()
except Exception as error:
    sys.stderr.write("c11-release: warning: timing not recorded: %s\n" % error)
PY
  rm -f "$TIMING_STEPS" 2>/dev/null || true
}

slug_of() {
  python3 -c 'import re,sys; print(re.sub(r"[^a-z0-9]+","-",sys.argv[1].lower()).strip("-"))' "$1"
}

bundle_id_of() {
  local app="$1"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null \
    || die "no bundle id in $app"
}

has_launch_environment() {
  local app="$1"
  /usr/libexec/PlistBuddy -c 'Print :LSEnvironment' "$app/Contents/Info.plist" >/dev/null 2>&1
}

select_keychain() {
  local which="${C11_RELEASE_KEYCHAIN:-acetate}"
  case "$which" in
    acetate)
      KEYCHAIN="${C11_KEYCHAIN:-$HOME/Library/Keychains/acetate-release.keychain-db}"
      PASSFILE="${C11_KEYCHAIN_PASS_FILE:-$HOME/.config/acetate/release-keychain.pass}"
      ;;
    c11)
      KEYCHAIN="${C11_REF_RELEASE_KEYCHAIN:-}"
      PASSFILE="${C11_REF_RELEASE_KEYCHAIN_PASS:-}"
      [[ -n "$KEYCHAIN" && -n "$PASSFILE" ]] \
        || die "c11 build-host release keychain is not configured"
      ;;
    *)
      die "C11_RELEASE_KEYCHAIN must be acetate or c11"
      ;;
  esac
  [[ -f "$KEYCHAIN" ]] || die "release keychain is missing"
  [[ -f "$PASSFILE" ]] || die "release keychain password file is missing"
}

# c11 2.0 updates through c11's Sparkle feed (C11H-265): the packaged app carries c11's
# feed and the pinned release key (scripts/release-local.sh), whatever the build baked in.
SPARKLE_FEED_URL="${C11_SPARKLE_FEED_URL:-https://github.com/Stage-11-Agentics/c11/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_KEY="${C11_SPARKLE_PUBLIC_KEY:-naW2p9Qixxto6tuJUi+NgmJU8EOx2vdRazhi0jwBALk=}"
set_sparkle() {
  python3 - "$1/Contents/Info.plist" "$SPARKLE_FEED_URL" "$SPARKLE_PUBLIC_KEY" <<'PY'
import plistlib, sys
path, feed, key = sys.argv[1:4]
with open(path, "rb") as handle:
    info = plistlib.load(handle)
info["SUFeedURL"] = feed
info["SUPublicEDKey"] = key
with open(path, "wb") as handle:
    plistlib.dump(info, handle, fmt=plistlib.FMT_XML)
PY
}

sign_app() {
  local app="$1"
  local bid
  bid="$(bundle_id_of "$app")"
  if [[ "$bid" != "$EXPECTED_BUNDLE_ID" ]]; then
    die "refusing to sign bundle id $bid"
  fi
  if has_launch_environment "$app"; then
    die "refusing to sign a staging app (LSEnvironment is set)"
  fi
  # C11H-133: a release ships no builder home path (a new dependency's __FILE__,
  # a stale GhosttyKit, a dropped strip flag). The check names each file.
  if ! "$ROOT/scripts/check-build-paths.sh" "$app" "$HOME" >&2; then
    die "refusing to sign $app: it carries the builder's home path (scripts/check-build-paths.sh)"
  fi
  [[ -f "$ENTITLEMENTS" ]] || die "missing entitlements at $ENTITLEMENTS"
  # C11H-392: written before any signature, so the app's seals the manifest.
  if [[ -n "$REMOTE_ARTIFACTS" ]]; then
    "$ROOT/scripts/c11-remote-artifacts.sh" stamp --app "$app" --dir "$REMOTE_ARTIFACTS" >&2 || return $?
  fi
  set_sparkle "$app" || return $?
  if [[ "${C11_SIGN_DRY:-0}" == "1" ]]; then
    printf 'sign-dry %s\n' "$app"
    return 0
  fi
  select_keychain
  C11_SIGN_APP="$app" \
  C11_SIGN_KEYCHAIN="$KEYCHAIN" \
  C11_SIGN_PASSFILE="$PASSFILE" \
  C11_SIGN_IDENTITY="$IDENTITY" \
  C11_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
  C11_SIGN_SECURITY="$SECURITY" \
  C11_SIGN_CODESIGN="$CODESIGN" \
  python3 - <<'PY'
import hashlib, json, os, subprocess, sys

app = os.environ["C11_SIGN_APP"]
keychain = os.environ["C11_SIGN_KEYCHAIN"]
passfile = os.environ["C11_SIGN_PASSFILE"]
identity = os.environ["C11_SIGN_IDENTITY"]
entitlements = os.environ["C11_SIGN_ENTITLEMENTS"]
security = os.environ["C11_SIGN_SECURITY"]
codesign = os.environ["C11_SIGN_CODESIGN"]
MACHO_MAGIC = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
               b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}

def scrub(text, secret):
    if secret:
        text = text.replace(secret, "<redacted>")
    return text

def run(argv, secret, timeout):
    try:
        proc = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        sys.stderr.write("c11-release: timed out: %s\n" % os.path.basename(argv[0]))
        return 1
    if proc.returncode != 0:
        err = scrub(proc.stderr.decode("utf-8", "replace"), secret)
        out = scrub(proc.stdout.decode("utf-8", "replace"), secret)
        sys.stderr.write(err)
        sys.stderr.write(out)
        sys.stderr.write("c11-release: command failed: %s\n" % os.path.basename(argv[0]))
        return proc.returncode or 1
    return 0

status = 0
password = ""
lock_status = 0
try:
    with open(passfile, "r", encoding="utf-8") as handle:
        password = handle.read()
    if password.endswith("\r\n"):
        password = password[:-2]
    elif password.endswith("\n"):
        password = password[:-1]
    if not password:
        sys.stderr.write("c11-release: release keychain password file is empty\n")
        status = 1
    else:
        status = run([security, "unlock-keychain", "-p", password, keychain], password, 30)
        # Lets codesign use the key without a GUI dialog. Does not export the key.
        if status == 0:
            status = run([security, "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                          "-s", "-k", password, keychain], password, 30)
        targets = []
        if status == 0:
            mac_os = os.path.join(app, "Contents", "MacOS")
            if os.path.isdir(mac_os):
                for name in sorted(os.listdir(mac_os)):
                    path = os.path.join(mac_os, name)
                    if os.path.isfile(path) and not os.path.islink(path):
                        targets.append(path)
            # Every Mach-O in Resources/bin (c11, ghostty, any later helper):
            # codesign --deep does not reach Resources, and notarization rejects
            # an unsigned or unhardened executable. Scripts stay sealed resources.
            bundled_bin = os.path.join(app, "Contents", "Resources", "bin")
            if os.path.isdir(bundled_bin):
                for name in sorted(os.listdir(bundled_bin)):
                    path = os.path.join(bundled_bin, name)
                    if name.startswith("._") or os.path.islink(path) or not os.path.isfile(path):
                        continue
                    with open(path, "rb") as handle:
                        magic = handle.read(4)
                    if magic in MACHO_MAGIC:
                        targets.append(path)
            for path in targets:
                status = run([codesign, "--force", "--options", "runtime", "--timestamp",
                              "--sign", identity, "--entitlements", entitlements,
                              "--keychain", keychain, path], password, 180)
                if status != 0:
                    break
        if status == 0:
            status = run([codesign, "--force", "--options", "runtime", "--timestamp",
                          "--sign", identity, "--entitlements", entitlements,
                          "--keychain", keychain, "--deep", app], password, 180)
        # C11H-66: the bundled hc core. --deep above gave it the app's
        # entitlements; it is signed again alone, hardened and with none (what
        # passed the hc contract suite). The signed file's hash goes into the
        # sealed hc-pin.json, then the app is signed again without --deep so the
        # helper keeps its own signature.
        helper = os.path.join(app, "Contents", "Helpers", "herdr-core")
        manifest = os.path.join(app, "Contents", "Resources", "hc-pin.json")
        if status == 0 and os.path.isfile(helper):
            if not os.path.isfile(manifest):
                sys.stderr.write("c11-release: Contents/Helpers/herdr-core has no hc-pin.json\n")
                status = 1
            else:
                helpers = os.path.dirname(helper)
                os.chmod(helpers, 0o755)
                status = run([codesign, "--force", "--options", "runtime", "--timestamp",
                              "--identifier", "com.stage11.c11.herdr-core", "--sign", identity,
                              "--keychain", keychain, helper], password, 180)
            if status == 0:
                with open(manifest, "r", encoding="utf-8") as handle:
                    record = json.load(handle)
                digest = hashlib.sha256()
                with open(helper, "rb") as handle:
                    for chunk in iter(lambda: handle.read(1 << 20), b""):
                        digest.update(chunk)
                record["executableSHA256"] = digest.hexdigest()
                with open(manifest + ".tmp", "w", encoding="utf-8") as handle:
                    json.dump(record, handle, separators=(",", ":"))
                    handle.write("\n")
                os.replace(manifest + ".tmp", manifest)
                status = run([codesign, "--force", "--options", "runtime", "--timestamp",
                              "--sign", identity, "--entitlements", entitlements,
                              "--keychain", keychain, app], password, 180)
        if status == 0:
            status = run([codesign, "--verify", "--deep", "--strict", "--verbose=2", app], password, 60)
finally:
    try:
        lock = subprocess.run([security, "lock-keychain", keychain],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    except subprocess.TimeoutExpired:
        lock_status = 1
        sys.stderr.write("c11-release: timed out locking the release keychain\n")
    else:
        if lock.returncode != 0:
            lock_status = lock.returncode or 1
            sys.stderr.write(scrub(lock.stderr.decode("utf-8", "replace"), password))
            sys.stderr.write(scrub(lock.stdout.decode("utf-8", "replace"), password))
            sys.stderr.write("c11-release: could not lock the release keychain\n")
    password = ""
if status == 0 and lock_status != 0:
    status = lock_status
raise SystemExit(status)
PY
}

write_zip() {
  local app="$1"
  local stage script_copy
  stage="$(mktemp -d "${TMPDIR:-/tmp}/c11-release.XXXXXX")" || return 1
  if ! mkdir -p "$stage/c11"; then
    rm -rf "$stage"
    return 1
  fi
  if ! ditto "$app" "$stage/c11/c11.app"; then
    rm -rf "$stage"
    printf 'c11-release: could not stage %s\n' "$app" >&2
    return 1
  fi
  script_copy="$stage/c11/c11-install.sh"
  if ! cp "$INSTALL_SH" "$script_copy"; then
    rm -rf "$stage"
    printf 'c11-release: could not copy the installer\n' >&2
    return 1
  fi
  if ! chmod +x "$script_copy"; then
    rm -rf "$stage"
    return 1
  fi
  if ! cp "$GUIDE" "$stage/c11/README.md"; then
    rm -rf "$stage"
    printf 'c11-release: could not copy the install guide\n' >&2
    return 1
  fi
  if grep -q 'PLACEHOLDER' "$GUIDE"; then
    printf 'c11-release: warning: the install guide still has PLACEHOLDER blocks; fill them before handing this zip to a friend\n' >&2
  fi
  if ! mkdir -p "$(dirname "$ARTIFACT")"; then
    rm -rf "$stage"
    return 1
  fi
  rm -f "$ARTIFACT" "$ARTIFACT.identity.txt" "$ARTIFACT.sha256"
  if ! ditto -c -k --keepParent "$stage/c11" "$ARTIFACT"; then
    rm -f "$ARTIFACT"
    rm -rf "$stage"
    printf 'c11-release: could not write %s\n' "$ARTIFACT" >&2
    return 1
  fi
  rm -rf "$stage"
  if ! write_identity "$app"; then
    rm -f "$ARTIFACT" "$ARTIFACT.identity.txt" "$ARTIFACT.sha256"
    printf 'c11-release: could not write %s.identity.txt\n' "$ARTIFACT" >&2
    return 1
  fi
  printf 'artifact %s\n' "$ARTIFACT"
  return 0
}

# Beside the zip, not in it: which build this is, so two artifacts (and the
# one Atin installs) can be told apart without unzipping.
write_identity() {
  local app="$1"
  python3 -I - "$app/Contents/Info.plist" "$ARTIFACT" "$ARTIFACT.identity.txt" "$NOTARY_RECORD" <<'PY'
import hashlib, os, plistlib, sys
info_path, zip_path, out, record = sys.argv[1:5]
with open(info_path, "rb") as handle:
    info = plistlib.load(handle)
digest = hashlib.sha256()
with open(zip_path, "rb") as handle:
    for chunk in iter(lambda: handle.read(1 << 20), b""):
        digest.update(chunk)
# A build is named by its c11 version line (C11Version, 1.7.6-h4), else the plain version,
# as C11BuildIdentity.versionLine does: "c11 1.7.6-h4 (build 145.4)".
short = info.get("CFBundleShortVersionString", "")
build = info.get("CFBundleVersion", "")
line = info.get("C11Version", "")
if not isinstance(line, str) or not line.strip() or "$(" in line:
    line = short
line = line.strip()
rows = [
    ("release", "c11 %s (build %s)" % (line, build)),
    ("c11_version", line),
    ("bundle_id", info.get("CFBundleIdentifier", "")),
    ("version", short),
    ("build", build),
    ("commit", info.get("C11Commit", "")),
    ("zip_sha256", digest.hexdigest()),
]
if record and os.path.exists(record):
    # notary_id, notary_status and stapled, written by notarize_app.
    with open(record, "r", encoding="utf-8") as handle:
        for line in handle:
            key, sep, value = line.rstrip("\n").partition("=")
            if sep and key in ("notary_id", "notary_status", "stapled"):
                rows.append((key, value))
tmp = out + ".incoming"
with open(tmp, "w", encoding="utf-8") as handle:
    for key, value in rows:
        handle.write("%s=%s\n" % (key, value))
os.replace(tmp, out)
# <zip>.sha256 in shasum's format, so `shasum -a 256 -c` checks the zip.
sha_out = zip_path + ".sha256"
with open(sha_out + ".incoming", "w", encoding="utf-8") as handle:
    handle.write("%s  %s\n" % (digest.hexdigest(), os.path.basename(zip_path)))
os.replace(sha_out + ".incoming", sha_out)
PY
}

stage_app() {
  local src="$1"
  local work app
  work="$(mktemp -d "${TMPDIR:-/tmp}/c11-sign.XXXXXX")" || return 1
  app="$work/c11.app"
  if ! ditto "$src" "$app"; then
    rm -rf "$work"
    printf 'c11-release: could not copy %s\n' "$src" >&2
    return 1
  fi
  printf '%s\n' "$app"
  return 0
}

# The tag's products are shared with other builds on it. Sign only the app
# this HEAD produced (the build phase stamps C11Commit), never a leftover.
check_commit() {
  local app="$1" want got
  want="$(git -C "$ROOT" rev-parse --short=9 HEAD)" || die "cannot read HEAD"
  got="$(/usr/libexec/PlistBuddy -c 'Print :C11Commit' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$got" == "$want" ]] || die "refusing to sign $app: built from ${got:-unknown commit}, HEAD is $want"
}

pristine_app() {
  local products="$BUILD_ROOT/$(slug_of "$TAG")/derived-release/Build/Products/Release"
  if [[ -d "$products/c11.app" ]]; then
    printf '%s\n' "$products/c11.app"
    return 0
  fi
  if [[ -d "$products/c11.app" ]]; then
    printf '%s\n' "$products/c11.app"
    return 0
  fi
  die "no pristine app under $products"
}

do_sign_source() {
  local src="$1"
  local staged=""
  local stage_rc=0
  local rc=0
  # Explicit statuses. An OR-tested subshell would turn set -e off for the
  # whole sign, and a later printf would report a failed signature as success.
  step_begin stage
  staged="$(stage_app "$src")" || stage_rc=$?
  step_end stage "$stage_rc"
  if [[ "$stage_rc" -eq 0 && -n "$staged" && -d "$staged" ]]; then
    timing_note_build "$staged"
  fi
  if [[ "$stage_rc" -ne 0 || -z "$staged" || ! -d "$staged" ]]; then
    if [[ -n "$staged" ]]; then
      rm -rf "$(dirname "$staged")"
    fi
    return 1
  fi
  # sign_app can exit on refusal. The subshell still reaches the cleanup below.
  # set +e is deliberate: each status is checked, and the zip runs only after sign.
  set +e
  (
    set +e
    step_begin sign
    sign_app "$staged"
    sign_rc=$?
    step_end sign "$sign_rc"
    if [[ "$sign_rc" -ne 0 ]]; then
      exit "$sign_rc"
    fi
    if [[ "$NOTARIZE" -eq 1 ]]; then
      NOTARY_RECORD="$(dirname "$staged")/notary-record.txt"
      notarize_app "$staged"
      notary_rc=$?
      if [[ "$notary_rc" -ne 0 ]]; then
        exit "$notary_rc"
      fi
    fi
    step_begin zip
    write_zip "$staged"
    zip_rc=$?
    step_end zip "$zip_rc"
    exit "$zip_rc"
  )
  rc=$?
  set -e
  rm -rf "$(dirname "$staged")"
  return "$rc"
}

do_build() {
  local app=""
  local app_rc=0
  [[ -x "$ATLAS_BUILD" ]] || die "atlas-build is not executable at $ATLAS_BUILD"
  local build_rc=0
  step_begin build
  "$ATLAS_BUILD" --tag "$TAG" --mode release --clean --wmo --universal || build_rc=$?
  step_end build "$build_rc"
  [[ "$build_rc" -eq 0 ]] || return "$build_rc"
  # Finding the product and checking its commit; a die here ends the step.
  step_begin locate
  app="$(pristine_app)" || app_rc=$?
  if [[ "$app_rc" -ne 0 || -z "$app" || ! -d "$app" ]]; then
    step_end locate 1
    return 1
  fi
  # A non-c11 product is refused by sign_app with its own message.
  if [[ "$(bundle_id_of "$app")" == "$EXPECTED_BUNDLE_ID" ]]; then
    check_commit "$app"
  fi
  step_end locate 0
  do_sign_source "$app"
}

# Notarize the signed app in place and staple its ticket. Runs before the zip
# is written, so a rejected or unstapled app is never published.
notarize_app() {
  local app="$1"
  local work submit attempt
  if [[ "${C11_SIGN_DRY:-0}" == "1" ]]; then
    printf 'notarize-dry %s\n' "$app"
    return 0
  fi
  step_begin notarize
  work="$(dirname "$app")"
  submit="$work/c11-notary.zip"
  rm -f "$submit"
  if ! ditto -c -k --sequesterRsrc --keepParent "$app" "$submit"; then
    rm -f "$submit"
    step_end notarize 1
    printf 'c11-release: could not archive the app for notarization\n' >&2
    return 1
  fi
  select_keychain
  if ! mkdir -p "$(dirname "$ARTIFACT")"; then
    rm -f "$submit"
    step_end notarize 1
    return 1
  fi
  rm -f "$ARTIFACT.notary-log.json"
  if ! C11_NOTARY_ZIP="$submit" \
    C11_NOTARY_RECORD="$NOTARY_RECORD" \
    C11_NOTARY_LOG="$ARTIFACT.notary-log.json" \
    C11_NOTARY_PROFILE_NAME="$NOTARY_PROFILE" \
    C11_SIGN_KEYCHAIN="$KEYCHAIN" \
    C11_SIGN_PASSFILE="$PASSFILE" \
    C11_SIGN_SECURITY="$SECURITY" \
    C11_NOTARY_XCRUN="$XCRUN" \
    python3 -I - <<'PY'
import json, os, subprocess, sys

submit = os.environ["C11_NOTARY_ZIP"]
record = os.environ["C11_NOTARY_RECORD"]
log_path = os.environ["C11_NOTARY_LOG"]
profile = os.environ["C11_NOTARY_PROFILE_NAME"]
keychain = os.environ["C11_SIGN_KEYCHAIN"]
passfile = os.environ["C11_SIGN_PASSFILE"]
security = os.environ["C11_SIGN_SECURITY"]
xcrun = os.environ["C11_NOTARY_XCRUN"]
creds = ["--keychain-profile", profile, "--keychain", keychain]

def scrub(text, secret):
    return text.replace(secret, "<redacted>") if secret else text

def run(argv, secret, timeout):
    try:
        proc = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        sys.stderr.write("c11-release: timed out: %s %s\n" % (os.path.basename(argv[0]), argv[1]))
        return 1, ""
    out = scrub(proc.stdout.decode("utf-8", "replace"), secret)
    if proc.returncode != 0:
        sys.stderr.write(scrub(proc.stderr.decode("utf-8", "replace"), secret))
    return proc.returncode, out

status = 1
password = ""
lock_status = 0
try:
    with open(passfile, "r", encoding="utf-8") as handle:
        password = handle.read()
    if password.endswith("\r\n"):
        password = password[:-2]
    elif password.endswith("\n"):
        password = password[:-1]
    if not password:
        sys.stderr.write("c11-release: release keychain password file is empty\n")
    else:
        # notarytool reads the profile from this keychain; locked, it would
        # wait on a GUI prompt. Unlocked only for the submission.
        rc, _ = run([security, "unlock-keychain", "-p", password, keychain], password, 30)
        if rc != 0:
            sys.stderr.write("c11-release: command failed: security\n")
        else:
            # notarytool exits non-zero on Invalid; its JSON still names the id.
            rc, out = run([xcrun, "notarytool", "submit", submit, *creds,
                           "--wait", "--timeout", "1h", "--output-format", "json"], password, 3900)
            try:
                result = json.loads(out) if out.strip() else {}
            except ValueError:
                result = {}
            if not isinstance(result, dict):
                result = {}
            sub_id = str(result.get("id", ""))
            sub_status = str(result.get("status", ""))
            print("notarization %s: %s" % (sub_id or "<no id>", sub_status or "<no status>"))
            if sub_status == "Accepted" and rc == 0:
                with open(record, "w", encoding="utf-8") as handle:
                    handle.write("notary_id=%s\nnotary_status=Accepted\n" % sub_id)
                status = 0
            else:
                if sub_id:
                    run([xcrun, "notarytool", "log", sub_id, *creds, log_path], password, 300)
                    if os.path.exists(log_path):
                        sys.stderr.write("c11-release: notary log at %s\n" % log_path)
                sys.stderr.write("c11-release: notarization failed: %s\n" % (sub_status or "submit error"))
finally:
    try:
        lock = subprocess.run([security, "lock-keychain", keychain],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    except subprocess.TimeoutExpired:
        lock_status = 1
        sys.stderr.write("c11-release: timed out locking the release keychain\n")
    else:
        if lock.returncode != 0:
            lock_status = lock.returncode or 1
            sys.stderr.write(scrub(lock.stderr.decode("utf-8", "replace"), password))
            sys.stderr.write("c11-release: could not lock the release keychain\n")
    password = ""
if status == 0 and lock_status != 0:
    status = lock_status
raise SystemExit(status)
PY
  then
    rm -f "$submit"
    step_end notarize 1
    return 1
  fi
  rm -f "$submit"
  step_end notarize 0
  step_begin staple
  # The ticket service is reached over the network; stapler fails transiently.
  attempt=1
  until "$XCRUN" stapler staple "$app"; do
    if [[ "$attempt" -ge "$STAPLE_TRIES" ]]; then
      step_end staple 1
      printf 'c11-release: stapler staple failed after %s attempts\n' "$attempt" >&2
      return 1
    fi
    sleep $((attempt * STAPLE_SLEEP))
    attempt=$((attempt + 1))
  done
  if ! "$XCRUN" stapler validate "$app"; then
    step_end staple 1
    printf 'c11-release: stapler validate failed\n' >&2
    return 1
  fi
  step_end staple 0
  printf 'stapled=yes\n' >> "$NOTARY_RECORD"
  return 0
}

BUILD=0
SIGN_APP=""
NOTARIZE=0
REMOTE_ARTIFACTS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --build) BUILD=1; shift ;;
    --sign-app)
      [[ $# -ge 2 ]] || die "--sign-app needs a path"
      SIGN_APP="$2"
      shift 2
      ;;
    --notarize) NOTARIZE=1; shift ;;
    --remote-artifacts)
      [[ $# -ge 2 && -d "$2" ]] || die "--remote-artifacts needs a folder"
      REMOTE_ARTIFACTS="$(cd "$2" && pwd)"
      shift 2
      ;;
    *) die "unknown option $1" ;;
  esac
done

[[ -x "$INSTALL_SH" ]] || die "missing $INSTALL_SH"
[[ -f "$GUIDE" ]] || die "missing $GUIDE"
# Before any build, unlock or submission: notarization needs the Orchestrator's go.
if [[ "$NOTARIZE" -eq 1 && "${C11_NOTARIZE_GO:-0}" != "1" ]]; then
  die "refusing notarization without the Orchestrator's go (C11_NOTARIZE_GO=1)"
fi
if [[ "$BUILD" -eq 1 && -n "$SIGN_APP" ]]; then
  die "use either --build or --sign-app"
fi
if [[ "$BUILD" -eq 0 && -z "$SIGN_APP" ]]; then
  usage >&2
  exit 2
fi

if [[ -n "$SIGN_APP" ]]; then
  [[ -d "$SIGN_APP" ]] || die "not an app: $SIGN_APP"
  MODE="sign-app"
  timing_start
  do_sign_source "$SIGN_APP" || exit $?
else
  MODE="build"
  timing_start
  do_build || exit $?
fi
