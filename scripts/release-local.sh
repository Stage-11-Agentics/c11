#!/usr/bin/env bash
# Production release of c11 without GitHub Actions.
#
# Mirrors .github/workflows/release.yml step for step, split by machine:
#   Atlas    the heavy Release build (scripts/remote-build.sh --mode release)
#   Hyperion the light tail: daemon assets, Sparkle keys, codesign, notarize,
#            staple, DMG, Sentry dSYMs, Sparkle appcast, GitHub release
#
# gh release create/upload use the REST API, so GitHub Actions billing does
# not apply. Run from a clean checkout of the release tag:
#
#   scripts/release-local.sh vX.Y.Z              # real release
#   scripts/release-local.sh --dry-run vX.Y.Z    # stops before notarization; publishes nothing
#
# See --help. Every step is logged to build-release-local/<tag>/release-local.log.
set -euo pipefail

# ---------------------------------------------------------------- constants --
REPO_SLUG="Stage-11-Agentics/c11"
SIGNING_IDENTITY="${C11_SIGNING_IDENTITY:-Developer ID Application: Authentic Technologies Inc. (UKQ4QALWD4)}"
NOTARY_PROFILE="${C11_NOTARY_PROFILE:-c11-notary}"
SPARKLE_ACCOUNT="${C11_SPARKLE_ACCOUNT:-c11mux}"
# The public half of the c11mux key; every shipped c11 trusts only this key.
SPARKLE_PUBLIC_KEY="naW2p9Qixxto6tuJUi+NgmJU8EOx2vdRazhi0jwBALk="
SPARKLE_FEED_URL="https://github.com/${REPO_SLUG}/releases/latest/download/appcast.xml"
# Prebuilt Sparkle tools at the version sparkle_generate_appcast.sh and the
# embedded Sparkle.framework pin (Package.resolved), so nothing is xcodebuilt
# on this machine.
SPARKLE_TOOLS_VERSION="2.9.3"
SPARKLE_TOOLS_SHA256="74a07da821f92b79310009954c0e15f350173374a3abe39095b4fc5096916be6"
# DTXcode of the toolchain the release must be built with. release.yml's
# macos-15-xlarge runner shipped v0.67.0 with Xcode 16.4 (DTXcode 1640, SDK
# macosx15.5). Atlas builds with Xcode 26.3 (2630, SDK macosx26.2), which links
# a newer SDK and changes runtime behavior, so a real run refuses until either
# Atlas builds with the pinned Xcode or the operator deliberately moves the pin
# (C11_RELEASE_DTXCODE=2630) and release.yml with it.
RELEASE_DTXCODE="${C11_RELEASE_DTXCODE:-1640}"
CREATE_DMG_VERSION="8.0.0"   # release.yml env.CREATE_DMG_VERSION
SENTRY_ORG="stage-11-kl"
SENTRY_PROJECT="c11"
DMG_NAME="c11-macos.dmg"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: scripts/release-local.sh [options] <vX.Y.Z>

Builds, signs, notarizes and publishes a c11 release without GitHub Actions.
The Release build runs on Atlas; everything after it runs here.

Options:
  --dry-run              Run every step up to, not including, notarization.
                         The DMG and appcast are still produced locally as a
                         rehearsal (unnotarized, appcast signed with a
                         throwaway key so the c11mux key is never read).
                         Notarize, staple, Sentry and every publish step only
                         print what they would do. Publishes nothing.
  --skip-notarize-check  Skip the preflight that proves the notarytool
                         keychain profile works before the long build.
  --skip-sentry          Skip the Sentry dSYM upload (it is also skipped when
                         SENTRY_AUTH_TOKEN is unset, as in release.yml).
  --reuse-build          Reuse the Atlas build already in
                         build-release-local/<tag>/pristine when it was built
                         from this HEAD (rerun the tail after a failure).
  --host <ssh-host>      Build host (default: atlas).
  -h, --help             Show this help.

Environment overrides: C11_SIGNING_IDENTITY, C11_NOTARY_PROFILE,
C11_SPARKLE_ACCOUNT, C11_RELEASE_DTXCODE (toolchain pin, see the constant),
SENTRY_AUTH_TOKEN.

Guards (real run): HEAD must equal the tag's commit locally and on origin, the
tree must be clean, MARKETING_VERSION must equal the tag, and the release must
not already hold any of the immutable assets (scripts/release_asset_guard.js).
The release is created as a draft, every asset is verified, and only then is it
published and given the `latest` slot, so `latest` always carries appcast.xml.
Existing assets are never overwritten.
EOF
}

DRY_RUN=0
SKIP_NOTARIZE_CHECK=0
SKIP_SENTRY=0
REUSE_BUILD=0
HOST="${C11_REMOTE_HOST:-atlas}"
TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --skip-notarize-check) SKIP_NOTARIZE_CHECK=1; shift ;;
    --skip-sentry) SKIP_SENTRY=1; shift ;;
    --reuse-build) REUSE_BUILD=1; shift ;;
    --host) HOST="${2:?--host needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)
      [[ -z "$TAG" ]] || { echo "error: one tag only" >&2; exit 2; }
      TAG="$1"; shift ;;
  esac
done
[[ -n "$TAG" ]] || { usage >&2; exit 2; }
# Only versioned tags take this path; artifact releases (xcframework-*,
# nightly) never do, so they can never be handed the `latest` slot here.
if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: tag must look like vX.Y.Z (got '$TAG')" >&2
  exit 2
fi
VERSION="${TAG#v}"

OUT="$ROOT/build-release-local/$TAG"
mkdir -p "$OUT"
LOG="$OUT/release-local.log"
exec > >(tee -a "$LOG") 2>&1

MODE_LABEL="REAL RUN"
[[ "$DRY_RUN" -eq 1 ]] && MODE_LABEL="DRY RUN"
STEP=0
step() { STEP=$((STEP + 1)); printf '\n==== [%s] step %d: %s (%s)\n' "$(date '+%H:%M:%S')" "$STEP" "$1" "$MODE_LABEL"; }
note() { printf '  %s\n' "$*"; }
die() { printf '\nRELEASE-LOCAL FAILED: %s\n' "$*" >&2; exit 1; }
# Prints a command a dry run skips, shell-quoted so it can be pasted.
would() { printf '  WOULD RUN:'; printf ' %q' "$@"; printf '\n'; }

KEY_DIR=""
cleanup() {
  # The exported Sparkle key lives only in this 0700 dir during step 13.
  if [[ -n "$KEY_DIR" && -d "$KEY_DIR" ]]; then rm -rf "$KEY_DIR"; fi
}
trap cleanup EXIT

printf '==== release-local %s %s at %s\n' "$TAG" "$MODE_LABEL" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
note "repo root: $ROOT"
note "output:    $OUT"

# ---------------------------------------------------------------- preflight --
step "Preflight: tools, tag, tree, version"
for tool in gh jq node npx go python3 xcrun ssh rsync swift codesign lipo shasum ditto openssl curl; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
gh auth status >/dev/null 2>&1 || die "gh is not authenticated"

HEAD_SHA="$(git rev-parse HEAD)"
note "HEAD: $HEAD_SHA"
# Run in preflight and again right before publishing, so a re-pointed tag is caught.
check_tag() {
  local tag_sha remote_refs origin_sha
  tag_sha="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" 2>/dev/null || true)"
  remote_refs="$(git ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}")" || die "git ls-remote origin failed"
  # An annotated tag lists its peeled commit as refs/tags/<tag>^{}; prefer it.
  origin_sha="$(awk -v t="refs/tags/$TAG" \
    '$2 == t "^{}" {peeled = $1} $2 == t {plain = $1} END {print (peeled != "" ? peeled : plain)}' <<<"$remote_refs")"
  note "tag $TAG locally: ${tag_sha:-absent}; on origin: ${origin_sha:-absent}"
  if [[ "$tag_sha" != "$HEAD_SHA" || "$origin_sha" != "$HEAD_SHA" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      note "WARNING: HEAD is not the commit of $TAG locally and on origin; allowed only because --dry-run."
    else
      die "HEAD ($HEAD_SHA) must equal $TAG's commit locally (${tag_sha:-absent}) and on origin (${origin_sha:-absent})."
    fi
  fi
}
check_tag

DIRTY="$(git status --porcelain)"
if [[ -n "$DIRTY" ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    note "WARNING: working tree is dirty; remote-build ships the dirty files as an overlay (dry run only):"
    printf '%s\n' "$DIRTY" | sed 's/^/    /'
  else
    die "working tree must be clean for a release:"$'\n'"$DIRTY"
  fi
fi

PBX_VERSIONS="$(grep -E '^\s*MARKETING_VERSION = ' GhosttyTabs.xcodeproj/project.pbxproj | sed -E 's/.*= ([^;]+);/\1/' | sort -u)"
PBX_BUILDS="$(grep -E '^\s*CURRENT_PROJECT_VERSION = ' GhosttyTabs.xcodeproj/project.pbxproj | sed -E 's/.*= ([^;]+);/\1/' | sort -u)"
note "MARKETING_VERSION: $(echo $PBX_VERSIONS); CURRENT_PROJECT_VERSION: $(echo $PBX_BUILDS)"
[[ "$(wc -l <<<"$PBX_VERSIONS" | tr -d ' ')" == "1" ]] || die "targets disagree on MARKETING_VERSION"
if [[ "$PBX_VERSIONS" != "$VERSION" ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    note "WARNING: MARKETING_VERSION $PBX_VERSIONS != tag version $VERSION; allowed only because --dry-run."
  else
    die "MARKETING_VERSION $PBX_VERSIONS != tag version $VERSION"
  fi
fi

IDENTITIES="$(security find-identity -v -p codesigning)" || die "security find-identity failed"
grep -qF "\"$SIGNING_IDENTITY\"" <<<"$IDENTITIES" || die "signing identity not in the keychain: $SIGNING_IDENTITY"
note "signing identity present: $SIGNING_IDENTITY"

if [[ "$SKIP_NOTARIZE_CHECK" -eq 1 ]]; then
  note "notarytool profile check skipped (--skip-notarize-check)"
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>"$OUT/notary-check.err"; then
  note "notarytool profile '$NOTARY_PROFILE' works"
else
  msg="notarytool keychain profile '$NOTARY_PROFILE' is missing or rejected: $(tr '\n' ' ' <"$OUT/notary-check.err")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    note "WARNING (a real run stops here): $msg"
  else
    die "$msg -- store it with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id UKQ4QALWD4"
  fi
fi

# -------------------------------------------------------- immutable guard --
# Same decision table as release.yml's "Guard immutable release assets" step,
# evaluated by the same module (scripts/release_asset_guard.js).
GUARD_JS='
const { evaluateReleaseAssetGuard } = require(process.argv[1]);
const existingAssetNames = JSON.parse(process.argv[2]);
const r = evaluateReleaseAssetGuard({ existingAssetNames });
console.log(JSON.stringify(r));
'
# Prints the release for $TAG as compact JSON, or nothing. Lists releases
# instead of GET releases/tags/<tag>, which never returns drafts.
find_release() {
  local found
  found="$(gh api --paginate "repos/$REPO_SLUG/releases?per_page=100" \
    --jq ".[] | select(.tag_name == \"$TAG\") | {id, draft, prerelease, assets: [.assets[] | {name, size, state, digest}]}")" \
    || die "could not list releases on GitHub"
  [[ "$(jq -s length <<<"$found")" -le 1 ]] || die "more than one release (drafts included) for $TAG; resolve by hand"
  printf '%s' "$found"
}
# phase: preflight | publish. Sets RELEASE_ID and RELEASE_DRAFT.
check_guard() {
  local phase="$1" rel names state guard
  rel="$(find_release)"
  if [[ -z "$rel" ]]; then
    RELEASE_ID=""
    RELEASE_DRAFT=""
    note "Release $TAG does not exist yet; safe to build and publish assets."
    return 0
  fi
  RELEASE_ID="$(jq -r .id <<<"$rel")"
  RELEASE_DRAFT="$(jq -r .draft <<<"$rel")"
  names="$(jq -c '[.assets[].name]' <<<"$rel")"
  state="$(node -e "$GUARD_JS" "$ROOT/scripts/release_asset_guard.js" "$names")" || die "release asset guard failed"
  guard="$(jq -r .guardState <<<"$state")"
  note "Release $TAG exists (id $RELEASE_ID, draft $RELEASE_DRAFT); guard state: $guard"
  case "$guard" in
    clear) note "Release $TAG has no immutable release assets yet; continuing." ;;
    partial)
      die "Release $TAG has a partial immutable asset state. Existing: $(jq -r '.conflicts|join(", ")' <<<"$state"). Missing: $(jq -r '.missingImmutableAssets|join(", ")' <<<"$state"). Resolve release assets manually before rerunning." ;;
    complete)
      if [[ "$RELEASE_DRAFT" == "true" ]]; then
        die "draft release $TAG (id $RELEASE_ID) already holds every immutable asset: an earlier run stopped before publishing. Inspect it, then publish it (gh api -X PATCH repos/$REPO_SLUG/releases/$RELEASE_ID -F draft=false -f make_latest=true) or delete it and rerun."
      fi
      if [[ "$phase" == "publish" ]]; then
        die "Release $TAG gained every immutable asset during this run: another publisher raced this one. Nothing was uploaded."
      fi
      note "Release $TAG already contains immutable assets ($(jq -r '.conflicts|join(", ")' <<<"$state"))."
      note "Skipping build, notarization, and upload to preserve existing signed artifacts."
      exit 0 ;;
    *) die "unexpected guard state: $guard" ;;
  esac
}
# A tag push also starts release.yml; two publishers must never race. Fails
# closed: an API error stops a real run.
check_active_runs() {
  local runs
  runs="$(gh run list --repo "$REPO_SLUG" --workflow release.yml --branch "$TAG" \
    --json databaseId,status --jq '[.[] | select(.status != "completed") | .databaseId] | join(" ")')" \
    || die "could not list release.yml runs"
  if [[ -z "$runs" ]]; then
    note "no active release.yml run for $TAG"
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    note "WARNING: release.yml runs still active for $TAG: $runs (a real run stops here)"
  else
    die "release.yml runs still active for $TAG ($runs); cancel them first: gh run cancel <id> --repo $REPO_SLUG"
  fi
}
step "Guard immutable release assets"
check_guard preflight
check_active_runs

# ------------------------------------------------------------ Atlas build --
PRISTINE="$OUT/pristine/c11.app"
IDENTITY_FILE="$OUT/pristine/build-identity.json"
REMOTE_TAG="release-local-$TAG"
REMOTE_SLUG="$(python3 -c 'import re,sys; print(re.sub(r"[^a-z0-9]+","-",sys.argv[1].lower()).strip("-"))' "$REMOTE_TAG")"
REMOTE_PRODUCTS="c11-builds/$REMOTE_SLUG/derived-release/Build/Products/Release"

# Executable bytes with the code signature removed, so the Xcode ad-hoc
# signature (pristine) and reloads.sh's re-sign (staging) compare equal.
# Callers must use `x="$(unsigned_sha f)" || die`: errexit does not reach
# into command substitutions on macOS bash 3.2.
unsigned_sha() {
  local tmp
  [[ -f "$1" ]] || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/c11-exec.XXXXXX")" || return 1
  cp "$1" "$tmp" || { rm -f "$tmp"; return 1; }
  codesign --remove-signature "$tmp" || { rm -f "$tmp"; return 1; }
  shasum -a 256 "$tmp" | awk '{print $1}'
  rm -f "$tmp"
}
SENTRY_WANTED=0
if [[ "$SKIP_SENTRY" -eq 0 && -n "${SENTRY_AUTH_TOKEN:-}" ]]; then SENTRY_WANTED=1; fi

# Checks the pristine app against the identity recorded when it was fetched.
verify_pristine() {
  local plist="$PRISTINE/Contents/Info.plist" exec_sha built_commit bundle_id
  [[ -d "$PRISTINE" && -f "$IDENTITY_FILE" ]] || die "no pristine build at $PRISTINE"
  [[ "$(jq -r .head "$IDENTITY_FILE")" == "$HEAD_SHA" ]] || die "pristine build is not of HEAD $HEAD_SHA"
  if [[ "$(jq -r .dirty "$IDENTITY_FILE")" != "false" && "$DRY_RUN" -ne 1 ]]; then
    die "pristine build carried an overlay of uncommitted files; rebuild without --reuse-build"
  fi
  exec_sha="$(unsigned_sha "$PRISTINE/Contents/MacOS/c11")" || die "cannot hash pristine executable"
  [[ "$exec_sha" == "$(jq -r .unsigned_exec_sha256 "$IDENTITY_FILE")" ]] || die "pristine executable changed since it was fetched"
  built_commit="$(/usr/libexec/PlistBuddy -c 'Print :C11Commit' "$plist" 2>/dev/null || true)"
  [[ "$built_commit" == "${HEAD_SHA:0:9}" ]] || die "pristine C11Commit '$built_commit' != ${HEAD_SHA:0:9}"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
  [[ "$bundle_id" == "com.stage11.c11" ]] || die "pristine bundle id is $bundle_id, not com.stage11.c11"
  if /usr/libexec/PlistBuddy -c 'Print :LSEnvironment' "$plist" >/dev/null 2>&1; then
    die "pristine Info.plist carries LSEnvironment (a staging/dev build)"
  fi
  if [[ "$SENTRY_WANTED" -eq 1 && "$DRY_RUN" -ne 1 ]]; then
    compgen -G "$OUT/pristine/dsyms/*.dSYM" >/dev/null || die "no dSYMs fetched with the pristine build; rebuild without --reuse-build"
  fi
  note "pristine identity ok: head $HEAD_SHA, C11Commit $built_commit, $bundle_id, unsigned exec $exec_sha"
}

step "Build app (Release) on $HOST"
if [[ "$REUSE_BUILD" -eq 1 && -f "$IDENTITY_FILE" && -d "$PRISTINE" \
      && "$(jq -r .head "$IDENTITY_FILE")" == "$HEAD_SHA" ]]; then
  note "--reuse-build: pristine build of $HEAD_SHA already at $PRISTINE"
else
  [[ "$REUSE_BUILD" -eq 1 ]] && note "--reuse-build: no pristine build for this HEAD; building."
  # reloads.sh --tag (behind remote-build --mode release) builds the prod
  # c11.app identity into derived-release, then returns a re-identified
  # STAGING copy. --clean --wmo --universal match release.yml's cold,
  # wholemodule, arm64+x86_64 build. The pristine c11.app is fetched below.
  note "remote-build: $HOST tag=$REMOTE_TAG (cold, wholemodule, universal)"
  set +e
  "$ROOT/scripts/remote-build.sh" --host "$HOST" --tag "$REMOTE_TAG" --mode release \
    --clean --wmo --universal 2>&1 | tee "$OUT/remote-build.out"
  rb_status="${PIPESTATUS[0]}"
  set -e
  [[ "$rb_status" -eq 0 ]] || die "remote build failed (exit $rb_status); see $OUT/remote-build.out"
  INVOCATION_DIR="$(sed -n 's/^\[remote-build\] logs and identity: //p' "$OUT/remote-build.out" | tail -1)"
  [[ -n "$INVOCATION_DIR" && -f "$INVOCATION_DIR/result.json" ]] || die "remote-build did not report its identity dir"
  RESULT="$INVOCATION_DIR/result.json"
  [[ "$(jq -r .head "$RESULT")" == "$HEAD_SHA" ]] || die "remote build head $(jq -r .head "$RESULT") != HEAD $HEAD_SHA"
  [[ "$(jq -r .mode "$RESULT")" == "release" && "$(jq -r .ok "$RESULT")" == "true" ]] || die "remote result is not an ok release build"
  if [[ "$(jq -r .dirty "$RESULT")" == "true" && "$DRY_RUN" -ne 1 ]]; then
    die "remote build carried an overlay of uncommitted files"
  fi
  STAGING_APP="$(sed -n 's/^APP_PATH=//p' "$OUT/remote-build.out" | tail -1)"
  [[ -d "$STAGING_APP" ]] || die "remote-build did not return an app"

  # Fetched right after the build returns. The per-tag derived-data dir is
  # only rebuilt by another remote-build of this same tag, and the hashes
  # below prove the fetched binaries are the build remote-build attested.
  note "fetching pristine c11.app from $HOST:$REMOTE_PRODUCTS"
  rm -rf "$OUT/pristine"
  mkdir -p "$OUT/pristine"
  rsync -a -e "ssh -o BatchMode=yes" "$HOST:$REMOTE_PRODUCTS/c11.app" "$OUT/pristine/"
  [[ -d "$PRISTINE" ]] || die "pristine c11.app not retrieved"
  if [[ "$SENTRY_WANTED" -eq 1 && "$DRY_RUN" -ne 1 ]]; then
    note "fetching dSYMs for Sentry"
    mkdir -p "$OUT/pristine/dsyms"
    rsync -a -e "ssh -o BatchMode=yes" "$HOST:$REMOTE_PRODUCTS/*.dSYM" "$OUT/pristine/dsyms/" \
      || die "could not fetch dSYMs from $HOST"
  fi

  for rel in MacOS/c11 Resources/bin/c11 Resources/bin/ghostty; do
    pristine_sha="$(unsigned_sha "$PRISTINE/Contents/$rel")" || die "cannot hash pristine $rel"
    staging_sha="$(unsigned_sha "$STAGING_APP/Contents/$rel")" || die "cannot hash staging $rel"
    note "unsigned sha256 $rel: pristine $pristine_sha staging $staging_sha"
    [[ "$pristine_sha" == "$staging_sha" ]] || die "pristine $rel is not the build remote-build attested"
    [[ "$rel" == "MacOS/c11" ]] && PRISTINE_EXEC_SHA="$pristine_sha"
  done
  jq -n --arg head "$HEAD_SHA" --arg invocation "$(jq -r .invocation "$RESULT")" \
    --arg host "$HOST" --arg products "$REMOTE_PRODUCTS" --arg exec "$PRISTINE_EXEC_SHA" \
    --arg xcode "$(jq -r .xcode "$RESULT")" --argjson dirty "$(jq .dirty "$RESULT")" \
    '{head:$head, invocation:$invocation, host:$host, products:$products, unsigned_exec_sha256:$exec, xcode:$xcode, dirty:$dirty}' \
    >"$IDENTITY_FILE"
fi
verify_pristine
ARCHS="$(lipo -archs "$PRISTINE/Contents/MacOS/c11")" || die "lipo failed"
note "architectures: $ARCHS"
[[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]] || die "app is not universal (arm64 + x86_64)"
DTXCODE="$(/usr/libexec/PlistBuddy -c 'Print :DTXcode' "$PRISTINE/Contents/Info.plist")"
DTSDK="$(/usr/libexec/PlistBuddy -c 'Print :DTSDKName' "$PRISTINE/Contents/Info.plist")"
note "toolchain: DTXcode $DTXCODE, SDK $DTSDK (pinned DTXcode $RELEASE_DTXCODE)"
if [[ "$DTXCODE" != "$RELEASE_DTXCODE" ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    note "WARNING (a real run stops here): built with DTXcode $DTXCODE, release pin is $RELEASE_DTXCODE"
  else
    die "built with DTXcode $DTXCODE ($DTSDK) but releases are pinned to $RELEASE_DTXCODE; see RELEASE_DTXCODE in this script"
  fi
fi

# Work on a copy so a rerun of the tail always starts from the unsigned build.
BUILD_DIR="$OUT/Release"
APP_PATH="$BUILD_DIR/c11.app"
APP_PLIST="$APP_PATH/Contents/Info.plist"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
ditto "$PRISTINE" "$APP_PATH"

# ------------------------------------------- remote daemon assets/manifest --
step "Build remote daemon release assets and inject manifest"
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PLIST")
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST")
note "app CFBundleShortVersionString=$APP_VERSION CFBundleVersion=$APP_BUILD"
[[ "$APP_VERSION" == "$PBX_VERSIONS" && "$APP_BUILD" == "$PBX_BUILDS" ]] \
  || die "built app version $APP_VERSION ($APP_BUILD) != project $PBX_VERSIONS ($PBX_BUILDS)"
DAEMON_DIR="$OUT/remote-daemon-assets"
"$ROOT/scripts/build_remote_daemon_release_assets.sh" \
  --version "$APP_VERSION" \
  --release-tag "$TAG" \
  --repo "$REPO_SLUG" \
  --output-dir "$DAEMON_DIR"
MANIFEST_JSON="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), separators=(",",":")))' "$DAEMON_DIR/c11d-remote-manifest.json")"
plutil -remove C11RemoteDaemonManifestJSON "$APP_PLIST" >/dev/null 2>&1 || true
plutil -remove CMUXRemoteDaemonManifestJSON "$APP_PLIST" >/dev/null 2>&1 || true
plutil -insert C11RemoteDaemonManifestJSON -string "$MANIFEST_JSON" "$APP_PLIST"
plutil -insert CMUXRemoteDaemonManifestJSON -string "$MANIFEST_JSON" "$APP_PLIST"

step "Run CLI version memory guard regression"
CLI_BINARY="$APP_PATH/Contents/Resources/bin/c11"
[ -x "$CLI_BINARY" ] || die "c11 CLI binary not found at $CLI_BINARY"
C11_CLI_BIN="$CLI_BINARY" CMUX_CLI_BIN="$CLI_BINARY" python3 "$ROOT/tests/test_cli_version_memory_guard.py"

step "Verify bundled Ghostty theme picker helper"
HELPER_BINARY="$APP_PATH/Contents/Resources/bin/ghostty"
[ -x "$HELPER_BINARY" ] || die "Ghostty theme picker helper not found at $HELPER_BINARY"
note "present: $HELPER_BINARY"

# ------------------------------------------------------------ Sparkle keys --
step "Inject Sparkle keys into Info.plist"
# release.yml derives the public key from the private key here. The key is
# pinned instead, and step 13 proves the private key matches it by verifying
# the appcast signature against this value before anything is published.
if [[ -f /Applications/c11.app/Contents/Info.plist ]]; then
  INSTALLED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' /Applications/c11.app/Contents/Info.plist 2>/dev/null || true)"
  if [[ -n "$INSTALLED_KEY" && "$INSTALLED_KEY" != "$SPARKLE_PUBLIC_KEY" ]]; then
    die "installed /Applications/c11.app trusts a different Sparkle key ($INSTALLED_KEY); shipped apps could not update"
  fi
  note "matches SUPublicEDKey of /Applications/c11.app"
fi
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${SPARKLE_PUBLIC_KEY}" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string ${SPARKLE_FEED_URL}" "$APP_PLIST"
note "SUPublicEDKey=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP_PLIST")"
note "SUFeedURL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP_PLIST")"

# --------------------------------------------------------------- codesign --
step "Codesign app"
# release.yml imports a .p12 into a throwaway build.keychain first; here the
# Developer ID identity already lives in the login keychain, whose ACL lets
# /usr/bin/codesign use the key without a prompt.
ENTITLEMENTS="$ROOT/c11.entitlements"
CLI_PATH="$APP_PATH/Contents/Resources/bin/c11"
HELPER_PATH="$APP_PATH/Contents/Resources/bin/ghostty"
if [ -f "$CLI_PATH" ]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$CLI_PATH"
fi
if [ -f "$HELPER_PATH" ]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$HELPER_PATH"
fi
/usr/bin/codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" --deep "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# --------------------------------------------------------- notarize: app --
# Returns the submission's status; prints the notary log on rejection.
notarize() {
  local file="$1" label="$2" json id status
  # notarytool exits non-zero on Invalid; keep its JSON so the log is fetched.
  json="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
  id="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$json" 2>/dev/null || true)"
  status="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$json" 2>/dev/null || true)"
  note "$label notarization ${id:-<no id>}: ${status:-<no status>}"
  if [[ "$status" != "Accepted" ]]; then
    printf '%s\n' "$json"
    [[ -n "$id" ]] && { xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true; }
    die "$label notarization failed with status: ${status:-submit error}"
  fi
}

ZIP_SUBMIT="$OUT/c11-notary.zip"
DMG_RELEASE="$OUT/$DMG_NAME"
step "Notarize app, staple, assess"
if [[ "$DRY_RUN" -eq 1 ]]; then
  would ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_SUBMIT"
  would xcrun notarytool submit "$ZIP_SUBMIT" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json
  would xcrun stapler staple "$APP_PATH"
  would xcrun stapler validate "$APP_PATH"
  would spctl -a -vv --type execute "$APP_PATH"
  note "dry run: assessing the unnotarized app (a rejection is expected):"
  spctl -a -vv --type execute "$APP_PATH" 2>&1 | sed 's/^/    /' || true
else
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_SUBMIT"
  notarize "$ZIP_SUBMIT" "App"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  spctl -a -vv --type execute "$APP_PATH"
  rm -f "$ZIP_SUBMIT"
fi

# -------------------------------------------------------------------- DMG --
step "Create DMG"
[[ "$DRY_RUN" -eq 1 ]] && note "dry run: building a rehearsal DMG from the unnotarized app"
DMG_WORK="$OUT/dmg-work"
rm -rf "$DMG_WORK" "$DMG_RELEASE"
mkdir -p "$DMG_WORK"
# create-dmg generates a styled drag-to-install DMG and signs it.
npx --yes "create-dmg@${CREATE_DMG_VERSION}" --identity="$SIGNING_IDENTITY" "$APP_PATH" "$DMG_WORK/"
shopt -s nullglob
dmgs=("$DMG_WORK"/c11*.dmg)
shopt -u nullglob
[[ "${#dmgs[@]}" -eq 1 ]] || die "expected one DMG from create-dmg, found ${#dmgs[@]}"
mv "${dmgs[0]}" "$DMG_RELEASE"
rmdir "$DMG_WORK"
codesign --verify --strict --verbose=2 "$DMG_RELEASE"

step "Notarize DMG, staple"
if [[ "$DRY_RUN" -eq 1 ]]; then
  would xcrun notarytool submit "$DMG_RELEASE" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json
  would xcrun stapler staple "$DMG_RELEASE"
  would xcrun stapler validate "$DMG_RELEASE"
else
  notarize "$DMG_RELEASE" "DMG"
  xcrun stapler staple "$DMG_RELEASE"
  xcrun stapler validate "$DMG_RELEASE"
fi

# ----------------------------------------------------------------- Sentry --
step "Upload dSYMs to Sentry (optional, failure tolerated)"
if [[ "$SKIP_SENTRY" -eq 1 ]]; then
  note "skipped (--skip-sentry)"
elif [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
  note "SENTRY_AUTH_TOKEN not set, skipping dSYM upload"
elif [[ "$DRY_RUN" -eq 1 ]]; then
  would rsync -a "$HOST:$REMOTE_PRODUCTS/*.dSYM" "$OUT/pristine/dsyms/"
  would env SENTRY_ORG="$SENTRY_ORG" SENTRY_PROJECT="$SENTRY_PROJECT" sentry-cli debug-files upload --include-sources "$OUT/pristine/dsyms/"
elif ! command -v sentry-cli >/dev/null 2>&1; then
  note "sentry-cli not installed (brew install getsentry/tools/sentry-cli); skipping dSYM upload"
else
  # dSYMs were fetched together with the pristine app, so they match it.
  SENTRY_ORG="$SENTRY_ORG" SENTRY_PROJECT="$SENTRY_PROJECT" \
    sentry-cli debug-files upload --include-sources "$OUT/pristine/dsyms/" \
    || note "WARNING: Sentry dSYM upload failed (tolerated, as continue-on-error in release.yml)"
fi

# ---------------------------------------------------------------- appcast --
step "Generate Sparkle appcast"
SPARKLE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/c11/sparkle/$SPARKLE_TOOLS_VERSION"
SPARKLE_BIN="$SPARKLE_DIR/bin"
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  mkdir -p "$SPARKLE_DIR"
  curl -fsSL -o "$SPARKLE_DIR/Sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_TOOLS_VERSION/Sparkle-$SPARKLE_TOOLS_VERSION.tar.xz"
  [[ "$(shasum -a 256 "$SPARKLE_DIR/Sparkle.tar.xz" | awk '{print $1}')" == "$SPARKLE_TOOLS_SHA256" ]] \
    || { rm -f "$SPARKLE_DIR/Sparkle.tar.xz"; die "Sparkle $SPARKLE_TOOLS_VERSION tarball checksum mismatch"; }
  tar -xf "$SPARKLE_DIR/Sparkle.tar.xz" -C "$SPARKLE_DIR"
fi
note "Sparkle tools: $SPARKLE_BIN ($SPARKLE_TOOLS_VERSION)"
DOWNLOAD_URL_PREFIX="https://github.com/$REPO_SLUG/releases/download/$TAG/"
RELEASE_NOTES_URL="https://github.com/$REPO_SLUG/releases/tag/$TAG"
APPCAST="$OUT/appcast.xml"
rm -f "$APPCAST"
KEY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/c11-sparkle-key.XXXXXX")"
chmod 700 "$KEY_DIR"
if [[ "$DRY_RUN" -eq 1 ]]; then
  # Never read the c11mux key in a dry run: only an operator-approved tool may.
  note "dry run: signing with a throwaway Ed25519 key; the c11mux key is not read"
  would "$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -x "<0700 temp file, deleted right after>"
  openssl rand -base64 32 >"$KEY_DIR/key"
  VERIFY_PUBLIC_KEY="$(swift "$ROOT/scripts/derive_sparkle_public_key.swift" "$(cat "$KEY_DIR/key")")"
  note "throwaway public key: $VERIFY_PUBLIC_KEY"
else
  note "reading the $SPARKLE_ACCOUNT key from the login keychain with Sparkle's generate_keys"
  note "(macOS asks once for the login keychain password to allow generate_keys; choose Always Allow so later runs are silent)"
  "$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -x "$KEY_DIR/key" >/dev/null
  VERIFY_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY"
fi
[[ -s "$KEY_DIR/key" ]] || die "no Sparkle private key"
# The key goes by path, never through the environment or argv.
SPARKLE_PRIVATE_KEY_FILE="$KEY_DIR/key" \
  SPARKLE_BIN_DIR="$SPARKLE_BIN" SPARKLE_VERSION="$SPARKLE_TOOLS_VERSION" \
  DOWNLOAD_URL_PREFIX="$DOWNLOAD_URL_PREFIX" RELEASE_NOTES_URL="$RELEASE_NOTES_URL" \
  "$ROOT/scripts/sparkle_generate_appcast.sh" "$DMG_RELEASE" "$TAG" "$APPCAST"
rm -rf "$KEY_DIR"
KEY_DIR=""

step "Verify appcast signature, enclosure and versions"
VERIFY_JSON="$(swift "$ROOT/scripts/verify_sparkle_appcast.swift" "$APPCAST" "$DMG_RELEASE" \
  "$VERIFY_PUBLIC_KEY" "${DOWNLOAD_URL_PREFIX}${DMG_NAME}")" || die "appcast verification failed"
note "$VERIFY_JSON"
[[ "$(jq -r .shortVersionString <<<"$VERIFY_JSON")" == "$APP_VERSION" ]] || die "appcast shortVersionString != $APP_VERSION"
[[ "$(jq -r .version <<<"$VERIFY_JSON")" == "$APP_BUILD" ]] || die "appcast version != $APP_BUILD"
if [[ "$DRY_RUN" -eq 1 ]]; then
  note "signature verified against the throwaway key (the real run verifies against $SPARKLE_PUBLIC_KEY)"
else
  note "signature verified against the shipped SUPublicEDKey $SPARKLE_PUBLIC_KEY"
fi

# ---------------------------------------------------------------- publish --
ASSETS=(
  "$DMG_RELEASE"
  "$APPCAST"
  "$DAEMON_DIR/c11d-remote-darwin-arm64"
  "$DAEMON_DIR/c11d-remote-darwin-amd64"
  "$DAEMON_DIR/c11d-remote-linux-arm64"
  "$DAEMON_DIR/c11d-remote-linux-amd64"
  "$DAEMON_DIR/c11d-remote-checksums.txt"
  "$DAEMON_DIR/c11d-remote-manifest.json"
)
for asset in "${ASSETS[@]}"; do [[ -s "$asset" ]] || die "missing asset $asset"; done
# The upload list must be exactly the guard's immutable asset list.
EXPECTED_NAMES="$(node -e 'console.log(require(process.argv[1]).IMMUTABLE_RELEASE_ASSETS.slice().sort().join("\n"))' "$ROOT/scripts/release_asset_guard.js")"
ACTUAL_NAMES="$(for a in "${ASSETS[@]}"; do basename "$a"; done | sort)"
[[ "$EXPECTED_NAMES" == "$ACTUAL_NAMES" ]] || die "upload list differs from IMMUTABLE_RELEASE_ASSETS"

step "Publish GitHub release"
note "re-checking tag, active runs, and the immutable asset guard right before upload"
check_tag
check_active_runs
check_guard publish

# Fails closed: only a 404 (no latest yet) reads as "none".
if ! CURRENT_LATEST="$(gh api "repos/$REPO_SLUG/releases/latest" --jq .tag_name 2>"$OUT/latest.err")"; then
  grep -q 'HTTP 404' "$OUT/latest.err" || { cat "$OUT/latest.err"; die "could not read the latest release"; }
  CURRENT_LATEST=""
fi
TAKE_LATEST=true
# A non-vX.Y.Z holder of `latest` (an artifact release) is always displaced;
# a newer vX.Y.Z keeps it, so a hotfix on an older line never pins the feed back.
if [[ "$CURRENT_LATEST" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$CURRENT_LATEST" != "$TAG" ]]; then
  newest="$(printf '%s\n%s\n' "${CURRENT_LATEST#v}" "$VERSION" | sort -V | tail -1)"
  [[ "$newest" == "$VERSION" ]] || TAKE_LATEST=false
fi
note "current latest: ${CURRENT_LATEST:-none}; $TAG takes latest: $TAKE_LATEST"

# Remote asset names, sizes and (when GitHub reports one) sha256 digests must
# match the local files before the release is published or given `latest`.
verify_remote_assets() {
  local remote asset name size sha
  remote="$(gh api "repos/$REPO_SLUG/releases/$RELEASE_ID" --jq '[.assets[] | {name, size, state, digest}]')" \
    || die "could not read release $RELEASE_ID"
  for asset in "${ASSETS[@]}"; do
    name="$(basename "$asset")"
    size="$(stat -f%z "$asset")"
    sha="sha256:$(shasum -a 256 "$asset" | awk '{print $1}')"
    jq -e --arg n "$name" --argjson s "$size" --arg d "$sha" \
      'any(.[]; .name == $n and .size == $s and .state == "uploaded" and (.digest == null or .digest == $d))' \
      <<<"$remote" >/dev/null || die "release asset $name missing, wrong size, or wrong digest on GitHub"
  done
  note "all ${#ASSETS[@]} assets present on GitHub with matching sizes and digests"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ -z "$RELEASE_ID" ]]; then
    would gh release create "$TAG" --repo "$REPO_SLUG" --verify-tag --draft --title "$TAG" --generate-notes "${ASSETS[@]}"
  else
    [[ "$RELEASE_DRAFT" == "true" ]] || would gh api -X PATCH "repos/$REPO_SLUG/releases/$RELEASE_ID" -F draft=true
    would gh release upload "$TAG" --repo "$REPO_SLUG" "${ASSETS[@]}"
  fi
  note "  then verify every asset name/size/digest via: gh api repos/$REPO_SLUG/releases/<id>"
  would gh api -X PATCH "repos/$REPO_SLUG/releases/<id>" -F draft=false -f "make_latest=$TAKE_LATEST"
  note "  then verify: gh api repos/$REPO_SLUG/releases/latest names $TAG and carries appcast.xml; $SPARKLE_FEED_URL resolves"
  note "dry run: nothing was published (no release, tag, or upload)"
else
  # --verify-tag: never let gh create the tag. The release stays a draft
  # (invisible, never `latest`) until every asset is verified. No --clobber
  # anywhere: an existing asset is never overwritten.
  if [[ -z "$RELEASE_ID" ]]; then
    gh release create "$TAG" --repo "$REPO_SLUG" --verify-tag --draft --title "$TAG" --generate-notes "${ASSETS[@]}"
    RELEASE_ID="$(jq -r .id <<<"$(find_release)")"
    [[ -n "$RELEASE_ID" && "$RELEASE_ID" != "null" ]] || die "created draft for $TAG not found"
  else
    if [[ "$RELEASE_DRAFT" != "true" ]]; then
      note "release $TAG is published without assets; turning it into a draft before uploading"
      gh api -X PATCH "repos/$REPO_SLUG/releases/$RELEASE_ID" -F draft=true >/dev/null
    fi
    gh release upload "$TAG" --repo "$REPO_SLUG" "${ASSETS[@]}"
  fi
  note "draft release id: $RELEASE_ID"
  verify_remote_assets
  gh api -X PATCH "repos/$REPO_SLUG/releases/$RELEASE_ID" -F draft=false -f "make_latest=$TAKE_LATEST" >/dev/null
  if [[ "$TAKE_LATEST" == "true" ]]; then
    LATEST_NOW="$(gh api "repos/$REPO_SLUG/releases/latest" --jq '.tag_name')"
    [[ "$LATEST_NOW" == "$TAG" ]] || die "latest is $LATEST_NOW, expected $TAG"
    gh api "repos/$REPO_SLUG/releases/latest" --jq '[.assets[].name]' | jq -e 'index("appcast.xml")' >/dev/null \
      || die "latest release has no appcast.xml"
    curl -fsSL -o /dev/null "$SPARKLE_FEED_URL" || die "feed $SPARKLE_FEED_URL does not resolve"
    note "latest = $TAG with appcast.xml; feed resolves"
  fi
fi

step "Summary"
note "app:     $APP_PATH ($APP_VERSION, build $APP_BUILD, $ARCHS)"
for asset in "${ASSETS[@]}"; do
  note "$(shasum -a 256 "$asset" | awk '{print $1}')  $(basename "$asset")"
done
note "log:     $LOG"
printf '\n==== release-local %s %s finished OK\n' "$TAG" "$MODE_LABEL"
