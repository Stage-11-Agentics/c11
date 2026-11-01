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

The build is 84-87% of the job. In v1.5.1's 2383 s build: universal (arm64 + x86_64) whole-module `-O` Swift compile about 1555 s, the uncached `zig build cli-helper` about 538 s, dependencies and the CLI about 235 s, link and dSYM about 55 s. DerivedData is not cached; Swift packages are. The same universal Release build on Atlas (M2 Ultra) takes 172 s fresh and 20 s warm, but Atlas has Xcode 26.x, while releases are pinned to Xcode 16.4 (`RELEASE_DTXCODE` in `scripts/release-local.sh`).

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
| R4 | Cache the zig toolchain and create-dmg | ~0.5 min | none |
| P1 | Release heads skip the guest yield, or reuse a main pass when the release tree is that commit plus version and changelog | ~18 min of prep (v1.6.0) | Lead (poller) |
| P2 | A green cold `pr-swift` run posts success instead of pending plus a rerun | ~4.5 min when cold | Lead (poller) |
| Q2 | Shard `CLIResolutionSnapshotTests` | `pr-swift` ~300 s to ~150 s | C11-538 B |
| B | Build the release faster than the free runner allows | ~15-25 min | Atin |

After R1-R4 a release is about 28 min. Reaching 15 min needs B. Its options:

Xcode 16.4 runs only through macOS 26.1.x ([Apple's support table](https://developer.apple.com/support/xcode/)), so it cannot run on Atlas (macOS 26.5), and the pin ends when GitHub retires its `macos-15` images.

1. Move the pin to Xcode 26.x and release with `release-local.sh`: about 10-12 min. Atlas does only the build; Hyperion signs, notarizes, signs the appcast and publishes, so credentials stay on Hyperion (the `c11-notary` profile has to be stored there once). Users on macOS 26 get the 26 SDK's system look; Apple's `UIDesignRequiresCompatibility` key can keep the old one.
2. Move the pin to Xcode 26.x and keep the free GitHub runner: fixes the pin, no speed gain (about 28 min).
3. Keep the pin on paid `macos-15-xlarge`, arm64-only: about 14 min (estimate). Drops Intel Macs, and the pin still ends with `macos-15`.
4. Paid `macos-15-xlarge` alone, or free per-architecture parallel jobs with a `lipo` merge: about 21 min each; neither meets 15.

## Releasing on Atlas (signing keychain mode)

Atin's go on 2026-10-31 ("keys to Atlas"): a release can run end to end on Atlas while his Mac sleeps. Atlas's dedicated release keychain (`~/Library/Keychains/acetate-release.keychain-db`, shared with Acetate) already holds the Developer ID identity for team UKQ4QALWD4 and the `acetate-notary` profile. It is locked at rest and unlocked by launchd for one run through `~/.acetate-release/bin/release_keychain.sh` (lease, auto-lock, lock in the exit trap).

- `C11_SIGNING_KEYCHAIN=<that keychain> scripts/release-local.sh ...` takes one unlock lease at preflight, passes the keychain to codesign and notarytool, reads the Sparkle key from it into the run's 0700 temp directory, and locks it on exit. `C11_SIGNING_IDENTITY` stays the single setting for the identity.
- `scripts/move-sparkle-key-to-atlas.sh` (operator, once, one macOS Allow) copies the c11mux Sparkle key from the operator's login keychain into that keychain over ssh stdin. It is safe to run twice. Agents run only `--check` (`match`, `missing` or `mismatch`) and `--self-test`.
- `scripts/atlas-signing-check.sh` (agent-safe) proves the path from a non-GUI ssh session: codesign of a scratch binary with hardened runtime and timestamp, `notarytool history`, and a Sparkle signature from a throwaway key read back from the keychain, then confirms the keychain is locked and nothing is left behind.
- On Atlas itself, `--host local` builds in place: `remote-build.sh --host local` runs the same admitted build (`atlas_build_slots.py`) from `$HOME` with no ssh hop, and the release fetches the products from there. A release run entirely on Atlas: `C11_SIGNING_KEYCHAIN=$HOME/Library/Keychains/acetate-release.keychain-db scripts/release-local.sh --host local vX.Y.Z`.

