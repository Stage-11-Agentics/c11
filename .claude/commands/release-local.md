# Release Local

Ship a c11 production release through `scripts/release-local.sh`, the release path (C11-542). It runs on Atlas, so the operator's Mac can sleep: the build happens in place (`--host local`), and signing, notarization, DMG, Sparkle appcast, `gh release` and the Homebrew dispatch use Atlas's release keychain. `release.yml` is the manual GitHub fallback. The `gh release` calls use the REST API, so Actions billing does not apply to them.

## Steps

### 1. Prepare and tag the release

Follow `skills/release/SKILL.md` through tagging: choose the version, update `CHANGELOG.md`, bump with `./scripts/bump-version.sh`, then gate and push the annotated tag `vX.Y.Z` on the tested release-branch head. Merge the branch back into `main` after the release is verified (skill step 11).

A tag push starts no workflow. If someone dispatched the `release.yml` fallback for this tag, the script refuses to publish while that run is active.

### 2. Check the signing path, from your own Mac

Run these from your own Mac, not from the Atlas shell: both drive Atlas over ssh, and Atlas cannot ssh to itself.
- `scripts/atlas-signing-check.sh` passes: the release keychain unlocks through its launchd lease, codesign and notarytool work from a non-GUI session, and it ends locked.
- `scripts/move-sparkle-key-to-atlas.sh --check` prints `match`: the `c11mux` Sparkle key is on Atlas.

### 3. Check out the tag cleanly on Atlas

Over ssh, in `~/c11-release` on Atlas, fetch the tag and check it is the tested commit before anything runs: `git fetch origin refs/tags/vX.Y.Z:refs/tags/vX.Y.Z && test "$(git rev-parse 'vX.Y.Z^{commit}')" = "<tested sha>" && git checkout --detach vX.Y.Z && git submodule update --init --recursive ghostty vendor/bonsplit`. A real run refuses on a dirty tree, a HEAD that is not the tag's commit locally and on origin, or a `MARKETING_VERSION` that does not match the tag. The two runs below go there; each command carries `C11_SIGNING_KEYCHAIN` itself, because a fresh ssh session does not keep an exported variable.

### 4. Dry run

```bash
C11_SIGNING_KEYCHAIN=$HOME/Library/Keychains/acetate-release.keychain-db scripts/release-local.sh --host local --dry-run vX.Y.Z
```

This builds in place, signs with the Developer ID, builds a rehearsal DMG and appcast (signed with a throwaway key), and prints every notarize and publish command without running it. It keeps the build and its dSYMs and publishes nothing. The skill runs it before the go (step 6.7, on the tested head before the tag exists), so the real run reuses its build.

### 5. Real run

```bash
C11_SIGNING_KEYCHAIN=$HOME/Library/Keychains/acetate-release.keychain-db scripts/release-local.sh --host local --reuse-build vX.Y.Z
```

Drop `--reuse-build` when there is no dry-run build of this HEAD; the run then builds first. Notes:
- Notarization uses `c11-notary`, else `acetate-notary` (team UKQ4QALWD4), or the one `C11_NOTARY_PROFILE` names. The log names the profile and team.
- The build matches the release toolchain pin, `RELEASE_DTXCODE` 2630 (Xcode 26.3). Moving the pin (`C11_RELEASE_DTXCODE`) is a deliberate SDK change and should move `release.yml` with it.

`--reuse-build` also reruns the tail after a failure, for example a notarization error; a rerun on an already-published release only dispatches the Homebrew update. If the run fails, read `build-release-local/vX.Y.Z/release-local.log`.

### 6. Verify

The script itself checks that `latest` names the tag, carries `appcast.xml`, and that the feed URL resolves. Then confirm by hand:

```bash
gh release view vX.Y.Z --repo Stage-11-Agentics/c11
gh api repos/Stage-11-Agentics/c11/releases/latest --jq .tag_name
```

Credentials and their keychain locations: `~/Projects/Stage11/code/platform/apple.md`.
