# C11-110 — Staging build perf plan

Apply four xcodebuild improvements to `scripts/reloads.sh` (staging Release build) on M-series Macs. Item 3 from the original spec (skipPackagePluginValidation + skipMacroValidation) was dropped by the operator. CI's `release.yml` and `nightly.yml` are untouched.

## Files affected

- `scripts/reloads.sh` (primary)
- `scripts/reload.sh` (Debug script): not touched in this PR. Same improvements can apply but are out of scope per the prompt — surface as follow-up at the end.

## Decisions

### Flag names

| Flag | Default behavior | Effect when passed |
|------|------------------|--------------------|
| `--universal` | arm64-only | adds `x86_64` back: drops `ARCHS=` / `ONLY_ACTIVE_ARCH=YES` overrides so the project's `ONLY_ACTIVE_ARCH=NO` Release setting takes hold |
| `--clean` | reuse derived-data | nuke derived-data dir before build |
| `--wmo` | `SWIFT_COMPILATION_MODE=incremental` | drop the override so the project's `wholemodule` Release setting takes hold |

Chose `--wmo` over `--release-mode` because the only thing we're actually toggling is the Swift compilation mode. "Release mode" reads as "switch to Release config," which is misleading (we're already in Release config).

### Derived-data family path

Default per-tag path today: `/tmp/c11-staging-<tag-slug>/`.
New default: `/tmp/c11-staging-<family>/`, where `<family>` is derived from `<tag-slug>` as the segment up to the first hyphen:

| Tag | Sanitized slug | Family | Derived-data |
|-----|----------------|--------|--------------|
| `release/v0.49.0` | `release-v0-49-0` | `release` | `/tmp/c11-staging-release/` |
| `c11-110-build-perf` | `c11-110-build-perf` | `c11` | `/tmp/c11-staging-c11/` |
| `feat/foo-bar` | `feat-foo-bar` | `feat` | `/tmp/c11-staging-feat/` |
| (no tag) | n/a | n/a | (unchanged: no derived-data override) |

Explicit `--derived-data` overrides keep working untouched. `--clean` wipes whichever directory is selected.

### HEAD sanity check

On entry (after path is chosen, before xcodebuild runs):

1. If the derived-data dir exists, read `<derived-data>/.last-sha` and `<derived-data>/.last-tag`. Print both alongside current `git rev-parse --short HEAD` and current tag — one stdout line, not a prompt.
2. After successful xcodebuild, write current short SHA + tag to those files.
3. No blocking, no interactive prompt. The point is "leave a breadcrumb so the operator can decide whether to pass `--clean` next time." Forcing a prompt would break unattended runs.

### Universal flag interaction with WMO

`--universal --wmo` is the closest-to-prod-parity validation mode. Document that combo explicitly in the help text — it's the "right before tag push" recipe.

## What stays the same

- `xcodebuild -configuration Release` (Release config still controls codesign/optimizations/etc. on the project side).
- App-bundle copying, PlistBuddy injections, codesign, socket isolation, c11d zig build, `open -g`.
- The `--tag`/`--name`/`--bundle-id`/`--derived-data` flags retain their existing meanings.

## Implementation order

1. **Items 4 and 5** (smallest, no flag plumbing): add `COMPILER_INDEX_STORE_ENABLE=NO` and `SWIFT_COMPILATION_MODE=incremental` unconditionally. *Then* refactor to honor `--wmo`. Separate commits.
2. **Item 1**: add arm64-only by default with `--universal` opt-out. One commit.
3. **Item 2**: switch default derived-data path to family-keyed, add `--clean`, add HEAD sanity check. One commit.
4. Update `--help` text to document all new flags + new defaults.

Each step is its own commit on `c11-110/staging-build-perf`. One PR against `main`.

## Validation

Run from this worktree, with `--tag c11-110-perf-test` so a stray staging app doesn't collide with the operator's live `release/v0.49.0` staging build.

| Scenario | Command | Expected |
|----------|---------|----------|
| Cold build (default) | `./scripts/reloads.sh --tag c11-110-perf-test --clean` | arm64-only, incremental; wall-clock vs. universal+wmo baseline |
| Warm rebuild | `./scripts/reloads.sh --tag c11-110-perf-test` | sub-minute incremental |
| Universal opt-out | `./scripts/reloads.sh --tag c11-110-perf-test --clean --universal` | universal binary in `Build/Products/Release/c11.app/Contents/MacOS/c11` (`lipo -info` shows arm64 + x86_64) |
| Clean wipe | `./scripts/reloads.sh --tag c11-110-perf-test --clean` | derived-data dir absent before build (verified by adding a stray file and watching it disappear) |
| WMO opt-out | `./scripts/reloads.sh --tag c11-110-perf-test --clean --wmo` | wall-clock longer than incremental; verify Swift driver invocations show `-whole-module-optimization` |
| App launches | after each successful build | staging app comes up, sidebar visible, terminal pane opens |

Capture wall-clock numbers for the PR body. Cold-vs-warm is the headline.

## Out of scope

- `scripts/reload.sh` (Debug script): same improvements would help but the prompt scopes this PR to `reloads.sh`. Flag as follow-up in PR description.
- No version bump, no CHANGELOG entry.
- No new tests. c11 test-quality policy: build-script behavior verified by running the script, not by source-text assertions.

## Risks

- Project-level `ARCHS = "arm64 x86_64"` could be referenced from elsewhere (Run Script phases, packaging). Worth a grep before shipping.
- `SWIFT_COMPILATION_MODE` interaction with module-emit or LTO settings is generally fine for Release+incremental, but the 0.47.0 New Workspace dialog regression was a WMO-only bug. The `--wmo` flag is the escape hatch for the "validate before tag push" case where that matters.
- Family extraction prefix-up-to-first-hyphen is dumb-simple by design. If a future tag style breaks it (e.g. `releaseV050`), the `--derived-data` override is still there as a manual fallback.
