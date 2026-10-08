# Release Local

Ship a c11 production release without GitHub Actions, through `scripts/release-local.sh`. Use it when the Actions release workflow cannot run (runner billing, outage). The script mirrors `.github/workflows/release.yml` step for step: the Release build runs on Atlas, and signing, notarization, DMG, Sparkle appcast and `gh release` run on this Mac. The `gh release` calls use the REST API, so Actions billing does not apply to them.

## Steps

### 1. Prepare and tag the release

Follow `skills/release/SKILL.md` through tagging: choose the version, update `CHANGELOG.md`, bump with `./scripts/bump-version.sh`, merge the release PR, then gate and push the annotated tag `vX.Y.Z`.

The tag push also starts `release.yml`. If that run is queued or in progress, cancel it (`gh run cancel <id> --repo Stage-11-Agentics/c11`); the script refuses to publish while it is active.

### 2. Check out the tag cleanly

Run from a clean checkout whose HEAD is the tag's commit, with submodules provisioned (`git submodule update --init --recursive ghostty vendor/bonsplit`). A real run refuses on a dirty tree, a HEAD that is not the tag's commit locally and on origin, or a `MARKETING_VERSION` that does not match the tag.

### 3. Dry run

```bash
scripts/release-local.sh --dry-run vX.Y.Z
```

This builds on Atlas, then signs, builds a rehearsal DMG and appcast (signed with a throwaway key), and prints every notarize and publish command without running it. It publishes nothing.

### 4. Real run

```bash
scripts/release-local.sh vX.Y.Z
```

Before it runs, check that:
- The `c11-notary` notarytool keychain profile exists (the preflight fails fast without it).
- Atlas builds with the pinned release toolchain. The script refuses an app whose `DTXcode` differs from `RELEASE_DTXCODE` (1640, Xcode 16.4, as v0.67.0 shipped). Moving the pin (`C11_RELEASE_DTXCODE`) is a deliberate SDK change and should move `release.yml` with it.
- Someone is at the Mac: the first read of the `c11mux` Sparkle key shows one keychain dialog for Sparkle's `generate_keys`, asking for the login password. *Always Allow* makes later runs silent.

`--reuse-build` reruns the tail from the existing Atlas build of the same HEAD, for example after a notarization failure. If the run fails, run `say "c11 release failed"` and read `build-release-local/vX.Y.Z/release-local.log`.

### 5. Verify

The script itself checks that `latest` names the tag, carries `appcast.xml`, and that the feed URL resolves. Then confirm by hand:

```bash
gh release view vX.Y.Z --repo Stage-11-Agentics/c11
gh api repos/Stage-11-Agentics/c11/releases/latest --jq .tag_name
```

Credentials and their keychain locations: `~/Projects/Stage11/code/platform/apple.md`.
