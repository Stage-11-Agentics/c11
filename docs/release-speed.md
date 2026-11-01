# Release and PR speed

Budgets (Stage 11 doctrine): push ≤30 s, PR ≤2 min, release ≤15 min from tag to published. This page holds the measured baseline, the plan, and how to re-measure. Re-measure after any change to `release.yml`, the poller, or the Atlas admission rules, and add a row.

PR CI, the hourly backstop and Drawbridge timings are recorded per attempt by `ci-timing.yml` (C11-538). Release timings come from `scripts/release-timing.sh [count]`, which prints one TSV row per `release.yml` run.

## Release, tag to published (`release.yml`, free `macos-15`, one serial job)

| Tag | Job s | Build s | Deps s | Notarize s | Appcast s | Sentry s | Upload s |
|---|---:|---:|---:|---:|---:|---:|---:|
| v1.2.0 | 2475 | 2067 | 36 | 167 | 77 | 22 | 13 |
| v1.3.0 | 2366 | 2021 | 27 | 112 | 70 | 26 | 14 |
| v1.4.0 | 2404 | 2026 | 28 | 138 | 80 | 23 | 15 |
| v1.5.0 | 2126 | 1767 | 39 | 109 | 75 | 26 | 15 |
| v1.5.1 | 2838 | 2383 | 67 | 124 | 102 | 35 | 16 |
| v1.6.0 | 1932 | 1581 | 34 | 129 | 66 | 22 | 13 |
| v1.7.0 | 2113 | 1857 | 24 | 94 | 8 | 20 | 14 |

The build is 84-88% of the job. In v1.5.1's 2383 s build: universal (arm64 + x86_64) whole-module `-O` Swift compile about 1555 s, the uncached `zig build cli-helper` about 538 s, dependencies and the CLI about 235 s, link and dSYM about 55 s. DerivedData is not cached; Swift packages are. The same universal Release build on Atlas (M2 Ultra) took 172 s fresh and 20 s warm. That baseline (to v1.7.0) was built with Xcode 16.4; releases are now pinned to Xcode 26.3 (see Release path below).

The appcast step used to clone Sparkle and xcodebuild its tools on every release (70-102 s). It now downloads the pinned, checksum-verified tarball through `scripts/fetch-sparkle-tools.sh` (8 s cold). The Sentry dSYM upload (continue-on-error) runs after the release upload, so it is off the tag-to-published path.

## Release prep (v1.6.0, 2026-10-31, PDT)

| Time | Stage |
|---|---|
| 13:27 | Release ticket created |
| 13:32 | PR #806 open (branch, bump, changelog) |
| 13:32-13:36 | GitHub CI and Drawbridge complete |
| 13:32-13:39 | Atlas `release-local.sh --dry-run`, Release build 415 s, in parallel |
| 13:32-13:50 | `c11/pr-swift` waits: the poller logs `no-start reason=guest` every 25 s (Tiles sandbox guest) |
| 13:50-13:55 | `pr-swift` invocation 1, 293 s, green but cold, so the poller posts pending and retries |
| 13:55-13:59 | `pr-swift` invocation 2, 246 s; reported as 536 s |
| 13:58 | Tag pushed |

Critical path: 18 min of guest yield plus 9 min of gate, of which 4.5 min was the cold-cache retry.

## PR checks

| Check | Measured | Owner of the fix |
|---|---|---|
| CI (`ci.yml`) | 272 s recent median, 85 s with #807 | C11-538 A |
| `c11/pr-swift` (Atlas, advisory) | 288-364 s; tests 225-269 s, `CLIResolutionSnapshotTests` 192 s; plus guest yields up to 20 min and the cold retry (removed in PR B) | C11-538 B, poller |
| Drawbridge (dry run) | 210-416 s; its two serial LLM jobs about 150 s | Atin's call |

The `test_default_local_lock_remains_single_slot` failure (`2 != 1`, seen on #805 and on the v1.6.0 release PR) was a real build-lock race on Ubuntu 26's uutils `mkdir`, not a flaky test; #807 fixes the lock.

## Plan, ranked by minutes saved per unit of effort

| # | Change | Saves | Needs |
|---|---|---|---|
| R1 | Sparkle tools from the pinned tarball | ~1.5 min per release | done |
| R2 | Sentry upload after publish | ~0.5 min to published | done |
| R3 | Exact-key zig helper cache | ~9 min per release | C11-538 C |
| R4 | Cache the zig toolchain | ~45 s (52 s to 8 s) | #811 |
| P1 | Release heads skip the guest yield, or reuse a main pass when the release tree is that commit plus version and changelog | ~18 min of prep (v1.6.0) | Lead (poller) |
| P2 | A green cold `pr-swift` run posts success instead of pending plus a rerun | ~4.5 min when cold | Lead (poller) |
| Q2 | Shard `CLIResolutionSnapshotTests` | `pr-swift` ~300 s to ~150 s | C11-538 B |
| B | Release on Atlas through `release-local.sh`: the build runs before the go, then sign, notarize and publish on Atlas | ~30 min | done (C11-542, C11-541) |

## Release path (C11-542, C11-541)

Atin decided on 2026-10-31: Atlas builds and signs his releases, so a release runs while his Mac sleeps; c11 ships for Apple silicon only (Intel Macs stay on 1.7.0); the Xcode 26 look is fine. `scripts/release-local.sh` is the release path. `release.yml` is a manual fallback on `macos-26`, and a tag push starts no workflow.

Releases run on Atlas in `~/c11-release`, a clean checkout of the tested head, with the build in place and the signing keychain:

```bash
C11_SIGNING_KEYCHAIN=$HOME/Library/Keychains/acetate-release.keychain-db \
  scripts/release-local.sh --host local [--dry-run | --reuse-build] vX.Y.Z
```

- `--host local` builds in place: `remote-build.sh --host local` runs the same admitted build (`atlas_build_slots.py`) from `$HOME` with no ssh hop.
- Signing-keychain mode takes one launchd unlock lease of Atlas's release keychain (`acetate-release`, shared with Acetate; locked at rest; `~/.acetate-release/bin/release_keychain.sh`), passes the keychain to codesign and notarytool, reads the Sparkle key from it into the run's 0700 temp directory, and relocks on every exit path. `C11_SIGNING_IDENTITY` is the single identity setting.
- The keychain holds the Developer ID (Authentic Technologies Inc., team UKQ4QALWD4) and the `acetate-notary` profile, both from Acetate's operator-run provisioning, plus the `c11mux` Sparkle key, which Atin moved with `scripts/move-sparkle-key-to-atlas.sh` on 2026-10-31. Notarization uses `c11-notary`, else `acetate-notary`, and the log names the profile and team.
- Before the go, `--dry-run` builds the tested head (cold, wholemodule, arm64, Xcode 26.3) while staging is smoked and CI runs. After the go, `--reuse-build` checks that build's identity, then signs, notarizes, publishes and dispatches the Homebrew update.
- `scripts/atlas-signing-check.sh [--full]` (agent-safe) proves the path from a non-GUI ssh session and fails unless the keychain ends locked.

| Measured on Atlas, 2026-10-31 | Seconds |
|---|---:|
| Release build, arm64, clean (`remote-build.sh`, plus 54 s slot wait) | 370 |
| Full dry run, signing-keychain mode, `--host local`, cold arm64 build | 402 (build 375) |
| Dry run reusing the build, everything but notarization and upload | 25 |
| Real notarization of app and DMG, with stapling and the signed DMG | 80 |

End-to-end rehearsal (#815 proof, 2026-10-31, nothing published): scratch release branch to would-publish in 8 min 52 s. Cheap CI was green at 1:57, `c11/pr-swift` at 3:45 (166 s), the Atlas dry run finished at 7:10, and notarization at 8:52. With the build done during the staging smoke, tag to published is about 2.5 min. Each run appends its step seconds to `build-release-local/timings.jsonl`; add a row to the release table above.

Xcode 16.4 runs only through macOS 26.1.x ([Apple's support table](https://developer.apple.com/support/xcode/)), which is why the pin moved to Xcode 26.3 (DTXcode 2630).
