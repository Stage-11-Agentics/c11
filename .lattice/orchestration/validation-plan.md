# Validation plan — C11-99 CI restoration

Per-acceptance-criterion verification plan, authored Phase 2 while audit context is fresh. Phase 4 Result Validator walks this top-down, records pass / fail / partial.

**Verification baseline.** Runs against the merged main HEAD after both delegators' PRs land. Where a check needs CI history, the validator pulls the last 5 main-branch runs via `gh run list --branch main --workflow <name>`.

---

## Area A — CI unblock

| # | Acceptance criterion | How to verify | Artifact |
|---|---|---|---|
| A1 | `nightly.yml` runs go green end-to-end (Sparkle appcast + artifact upload + tag move all execute even if Sentry upload fails) | `gh run list --workflow nightly.yml --limit 3` — all post-merge runs green; pick one and `gh run view --log` to confirm Sparkle/appcast/upload steps ran | nightly.yml run output |
| A2 | `ci.yml` build job green on main with `c11-logic` as the gate | `gh run list --workflow ci.yml --branch main --limit 5` — all post-merge runs green | ci.yml run output |
| A3 | Advisory `c11-unit` step still runs and reports failures, just doesn't fail the job | `gh run view --log` on a recent main run — confirm both `c11-logic` and `c11-unit` steps appear; `c11-unit` step status reads as a warning if failing, doesn't gate the job | ci.yml step block |
| A4 | The skipped slow test has a TODO + Lattice link in source | `grep -n "XCTSkip" c11Tests/AppDelegateShortcutRoutingTests.swift` — confirms skip on `testMinimalModeUsesZeroTopSafeAreaForMainWindowContentView` with reference to C11-99 / area C | c11Tests source |

## Area B — Local test runnability

| # | Acceptance criterion | How to verify | Artifact |
|---|---|---|---|
| B1 | Operator can run `scripts/test-unit-local.sh` on Hyperion with `/Applications/c11.app` AND a `c11 DEV.app` running, and neither dies | Open prod + DEV → invoke `scripts/test-unit-local.sh -only-testing:c11Tests/AppDelegateShortcutRoutingTests/<some fast test>` → confirm test host launches with its own per-PID socket path and prod/DEV sockets remain live | runtime check |
| B2 | New c11LogicTests case verifies the socket path is per-PID under XCTest | `grep -rn "XCTestConfigurationFilePath" c11LogicTests/` — finds the new test in `SocketControlSettings`-related test file; running `xcodebuild -scheme c11-logic test` includes it | c11LogicTests source |
| B3 | CLAUDE.md no longer mentions the "Don't run xcodebuild test on c11 locally" prohibition | `grep -in "don't run xcodebuild" code/c11/CLAUDE.md` → no match; section instead points at `scripts/test-unit-local.sh` | CLAUDE.md |
| B4 | Scheme env var self-documents the isolation | `grep -n "CMUX_TAG" GhosttyTabs.xcodeproj/xcshareddata/xcschemes/c11-unit.xcscheme` — finds `EnvironmentVariable` block with `local-xctest` value | scheme XML |

## Area C — c11Tests stabilization

| # | Acceptance criterion | How to verify | Artifact |
|---|---|---|---|
| C1 | `c11-unit` step in CI green on main for 5+ consecutive runs | `gh run list --workflow ci.yml --branch main --limit 5` — all 5 runs show `c11-unit` step green | ci.yml runs |
| C2 | CI flips `c11-unit` from `continue-on-error: true` back to hard-fail | `grep -A 3 "Host-bound unit tests" .github/workflows/ci.yml` — no `continue-on-error: true` line | ci.yml source |
| C3 | Quarantined slow test re-enabled | `grep -A 3 "testMinimalModeUsesZeroTopSafeAreaForMainWindowContentView" c11Tests/AppDelegateShortcutRoutingTests.swift` — no `XCTSkip`; test executes in the run | c11Tests source |
| C4 | AAR comment on C11-99 covering the actual root cause | `lattice show C11-99` → find a `comment_added` event from `delegator:c-stab` with the AAR (portable insight for future test design — what class of timing assumption was wrong) | C11-99 events |

## Area D — Workflow / scripts / docs hygiene

| # | Acceptance criterion | How to verify | Artifact |
|---|---|---|---|
| D1 | `update-homebrew.yml` has `timeout-minutes: 10` | `grep -n "timeout-minutes" .github/workflows/update-homebrew.yml` → finds `10` | workflow source |
| D2 | `sparkle_generate_appcast.sh` defaults flipped to Stage-11-Agentics/c11 (or requires explicit envs) | `grep -n "DOWNLOAD_URL_PREFIX\|RELEASE_NOTES_URL" scripts/sparkle_generate_appcast.sh` → no `manaflow-ai/cmux` in default fallbacks | script source |
| D3 | `bump-version.sh` hard-fails on Sparkle-floor curl returning 0 bytes when invoked for release tag | Read `scripts/bump-version.sh:28` and surrounding logic — confirms guard added | script source |
| D4 | `claude.yml` deleted | `test ! -f .github/workflows/claude.yml` | filesystem |
| D5 | `test-e2e.yml` deleted | `test ! -f .github/workflows/test-e2e.yml` | filesystem |
| D6 | `code/c11/CLAUDE.md` ghostty submodule section reflects real remote layout | `grep -A 5 "Ghostty submodule workflow" code/c11/CLAUDE.md` — references `stage11` remote, not `manaflow` | CLAUDE.md |

---

## Cross-area integration checks

| # | Criterion | How to verify |
|---|---|---|
| X1 | Local-test wrapper actually unblocks Area C's iteration loop | Have Result Validator run `scripts/test-unit-local.sh -only-testing:c11Tests/<one previously-flaky test>` and confirm it passes locally after C's fixes |
| X2 | No regression in release path | `gh run list --workflow release.yml --limit 3` after a tag push (or against the latest pre-existing successful run if no new tag) — green |
| X3 | No regression in mailbox-parity | `gh run list --workflow mailbox-parity.yml --limit 3` — still green |

## When to skip Phase 4

Skip the formal Result Validator pass only if all of: (a) operator has personally walked the 4 areas in PR review, (b) all PRs are merged, (c) operator confirms 5+ consecutive green main runs. Otherwise run it.
