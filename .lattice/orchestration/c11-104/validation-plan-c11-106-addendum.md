# C11-104 validation plan — C11-106 addendum

This file is the addendum to `.lattice/orchestration/c11-104/validation-plan.md`. It records which validation-plan ACs were deferred at C11-104 ship (PR #181) and resolved here in C11-106. The original validation plan and its Phase 4 report (`validation-report.md`) are untouched — they remain the historical evidence of what was known at #181 merge time.

## Resolution summary

| AC | Original verdict (C11-104) | C11-106 resolution | Where to find evidence |
| --- | --- | --- | --- |
| **AC10** — stale worktree (worktree removed while pane is open) | FAIL (no test, no `.stale` enum case) | RESOLVED. `GitContextKind.stale` added; `GitContextResolver.resolve(cwd:)` returns `.stale` when `git rev-parse --git-path HEAD` resolves to a missing file; projector clears the chip. | `c11Tests/GitContextResolverTests.swift::testStaleWorktreeReturnsStaleWhenHeadPathFileMissing`; `c11Tests/WorktreeChipProjectorTests.swift::testStaleOuterProducesEmptyRows`. |
| **AC12** — cache against git-resolved HEAD path | PARTIAL (cache class library-tested, not wired to production probe path; no linked-worktree / submodule fixtures) | RESOLVED. `GitContextResolverCache` wired into `TabManager.initialWorkspaceGitMetadataSnapshot(for:)` via `GitContextResolver.resolveCached(cwd:cache:)`. Cache key is `(cwd, mtime(headPath), mtime(superHeadPath?))` — multi-HEAD for submodules. Linked-worktree + submodule + nil-result fixture tests added. | `c11Tests/GitContextResolverCacheWiringTests.swift` (5 fixture tests + 2 diagnostic-counter tests). |
| **AC14** — git subprocess timeout | FAIL (no test) | RESOLVED. `ProcessGitRunner` extended with `executable:` + `argPrefix:` constructor seams (defaults unchanged: `/usr/bin/env git`, 5s timeout). Tests substitute `/bin/sh -c 'sleep ...'` and assert nil result + bounded wall time + no queue-blocking. Timeout default kept at 5s; the v2 SPEC's 2s suggestion is amended in this PR's body. Typed timeout enum is a deliberate follow-up — `GitRunner.run` continues to return `String?` so timeout collapses to nil alongside non-zero exit / missing binary / not-in-repo / bare clone. | `c11Tests/ProcessGitRunnerTimeoutTests.swift` (4 tests). |
| **AC16** — socket `set_metadata` rejects `source=derived` from external clients | PARTIAL (code present at 4 call sites, no test) | RESOLVED. Duplicated 3-line rejection extracted to `SocketMetadataSourceValidator.externalRejectionMessage(for:)` (`Sources/Metadata/SocketMetadataSourceValidator.swift`). All 4 socket handlers in `TerminalController.swift` now route through this helper. Logic test exercises the helper directly with every `MetadataSource` case. | `c11Tests/SocketDerivedSourceRejectionTests.swift::testDerivedSourceProducesInvalidSourceRejection`, `::testExplicitDeclareOscHeuristicAreAccepted`, `::testRejectionMessageMatchesProductionConstants`. |
| **AC17** — `c11 get-metadata --key worktree`/`--key branch` returns derived values | CANNOT_VERIFY (no test) | RESOLVED. Test writes `worktree`+`branch` via `SurfaceMetadataStore.setInternal(.derived)` (same call sequence the cache-wired probe uses) and reads back through the same `getMetadata(workspaceId:surfaceId:)` path the socket handler invokes. Asserts both keys present + sources labeled `.derived`. Pins the "derived keys are not filtered on read" contract. | `c11Tests/SocketDerivedSourceRejectionTests.swift::testGetMetadataReturnsDerivedWorktreeAndBranchValuesWithDerivedSource`, `::testGetMetadataDoesNotFilterDerivedKeysFromUnfilteredRead`. |
| **AC20** — runtime `dispatchPrecondition(.notOnQueue(.main))` traps main-thread invocation | PARTIAL (sentinel test only; doesn't deterministically trip the precondition) | EXPLICIT DOWNGRADE recorded. `XCTExpectFailure` does not trap `dispatchPrecondition` (preconditions abort with `EXC_BAD_INSTRUCTION`, not XCTFails); a subprocess fatal-test harness was rejected as scope-expansion for C11-106. The existing sentinel + an expanded doc-comment + this addendum + the PR-body note constitute the residual coverage. Re-opening the subprocess harness is a deliberate future ticket. | `c11Tests/GitContextResolverTests.swift::testResolverPreconditionTripsOnMainThread` (now with full rationale in the docstring). |

Remaining deferrals (unchanged from C11-104):

| AC | Status after C11-106 | Tracking |
| --- | --- | --- |
| **AC19** — restore-warmpath snapshot pre-paint | Still deferred. Touches workspace restore lifecycle; out of C11-106's blast radius. | Filed as **C11-107** (`task_01KS08E3NRW5PVM9YCGW04JK6E`), spawned_by C11-104, related_to C11-106. |
| **AC31–AC33** — operator post-merge smoke (visual chip render, settings toggle, typing-latency burst) | Still operator-driven. C11-106 does not change the user-visible sidebar render; the smoke pass is recommended in the PR body. | C11-104 validation-report.md § "Operator smoke-pass checklist (post-merge)". |

## Drift items closed in C11-106

The C11-104 validation report's "Drift from BUILDPLAN architecture" section enumerated 5 items. Status after C11-106:

1. **Timeout 5s vs spec's 2s.** Amended SPEC to 5s in this PR's body — "conservative for slow disks." AC14 test pins the 5s default. (Per trident plan-review I2.)
2. **Dim opacity hardcoded `0.55`.** Deferred again — declared out of C11-106's blast radius per the "no user-visible sidebar render change" boundary. A separate visual-polish ticket is the right home.
3. **State naming (`.unknown` vs `.noBranch`, `.notInRepo`, `.stale`).** RESOLVED. `BranchValue.unknown` → `.noBranch`; `GitContextKind` gains `.notInRepo` and `.stale`. See `c11Tests/GitContextResolverTests.swift` + `c11Tests/WorktreeChipProjectorTests.swift` for the projector / store contract table.
4. **Cache + coordinator as library code, not system code.** RESOLVED for the cache (now load-bearing via `resolveCached`). `DerivationCoordinator` remains an explicit forward seam; production status documented in `skills/c11/references/metadata.md` § "Production wiring."
5. **`Workspace.orderedUniqueBranchDirectoryEntries()` dead code.** RESOLVED. Helper, struct, and two test methods deleted after the trident's three-step safety protocol (grep → compile both schemes → snapshot/persistence audit).

## What this addendum does NOT cover

- A retroactive edit of the original `validation-plan.md` or `validation-report.md`. Those files remain the historical evidence of what was known at #181 merge time.
- Operator post-merge smoke (AC31–33). The PR body carries the recommendation; the smoke pass is the operator's call.
- FSEvents-based cache invalidation (the structural replacement for mtime polling). Out of scope; a TODO comment in `GitContextResolverCache` documents the eventual upgrade path.

## Authoring note

This addendum was written by the C11-106 delegator. The decisions it records were applied per the trident plan-review's "Apply by default" + "Surface to user" findings (synthesis pack: `.lattice/orchestration/c11-106/c11-106-plan-review-pack-2026-05-19T0935/synthesis-action.md`).
