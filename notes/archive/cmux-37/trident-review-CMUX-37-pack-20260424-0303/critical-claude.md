## Critical Code Review
- **Date:** 2026-04-24T03:03:00Z
- **Model:** Claude Opus 4.7 (claude-opus-4-7)
- **Branch:** cmux-37/phase-0-workspace-apply-plan
- **Latest Commit:** e4f60b98
- **Linear Story:** CMUX-37
- **Review Type:** Critical / Adversarial
- **Scope:** Phase 0 only — `WorkspaceApplyPlan` value types, `WorkspaceLayoutExecutor`, 5-fixture acceptance test, optional `workspace.apply` socket handler + `c11 workspace-apply` CLI (commit 8b)
---

## The Ugly Truth

The schema half of this branch is solid. The *executor* half ships a layout walker that does not build the tree the plan describes, and an acceptance test that is not equipped to notice. Everything else — Codable round-trips, `mailbox.*` guard, metadata routing through the canonical stores, socket handler threading, no hot-path edits, TODO comments at the migration sites — is on-target. But the central primitive that Phase 1 (Snapshot restore), Phase 2 (Blueprints), and the operator-facing `workspace.apply` CLI are all supposed to stand on has a layout-construction bug that will materialize the wrong workspace shape for every fixture in this PR except `single-large-with-metadata`.

The acceptance fixture passes not because the executor is correct but because the assertions are too weak to see the defect: the test checks that four `surfaceRef` keys exist and that `total` timing is under 2s. Both are true even when the tree is shaped wrong. We would ship a welcome-quad that is not a quad and never know until a human opened the window.

Ship the types, ship the fixture schema, ship the socket handler. **Do not ship the walker as-is.** The fix is not a one-liner; it's a rethink of how a depth-first plan tree gets composed through bonsplit's leaf-only `splitPane` API.

## What Will Break

### 1. Layout walker produces wrong trees for nested splits (BLOCKER)

`WorkspaceLayoutExecutor.swift:448-501` (`materializeSplit`) picks `firstAnchorPanelId` — the panel id returned by materializing `split.first` — as the source for `newXSplit(from:)`. That id is the **first leaf** of the first subtree, not a representative of the first subtree as a composite. Bonsplit's `splitPane` (`vendor/bonsplit/Sources/Bonsplit/Internal/Controllers/SplitViewController.swift:137-162`) then splits **that single leaf pane**, nesting the new pane inside `split.first` rather than creating a sibling adjacent to `split.first` as a whole.

Trace the welcome-quad fixture (`c11Tests/Fixtures/workspace-apply-plans/welcome-quad.json`):

Plan tree:
```
outer: H-split(
  first:  V-split(tl, bl),
  second: V-split(tr, br)
)
```

Walker steps (seed = terminal panel in pane_root):
1. `materialize(outer.first = V(tl, bl), anchor = seedTerminal(seed))`.
2. `materialize(V.first = pane(tl), anchor = seedTerminal(seed))` → anchor kind matches, `firstPanelId = seed`. Return `seed`.
3. `splitFromPanel(seed, .vertical, bl)` → bonsplit splits pane_root vertically. Tree becomes `V(pane_root[tl], pane_new[bl])`. Return `bl_panel`.
4. `materialize(V.second = pane(bl), anchor = anyExisting(bl_panel, terminal))` — pane(bl) lands on bl_panel. Return the inner materialize's value, `seed`, to the outer split.
5. Back in outer: `splitFromPanel(seed, .horizontal, tr)` → bonsplit splits the pane *currently containing seed*, which is still pane_root (tl's pane). Tree becomes `V( H(pane_root[tl], pane_tr[tr]), pane_new[bl] )`.
6. `materialize(outer.second = V(tr, br), anchor = anyExisting(tr_panel, browser))`.
7. `splitFromPanel(tr_panel, .vertical, br)` → splits tr's pane vertically. Tree becomes `V( H( pane_root[tl], V(pane_tr[tr], pane_br[br]) ), pane_new[bl] )`.

Final live tree: a three-level asymmetric arrangement, **not a 2×2 quad**. The same walker logic produces the same class of malformed tree for `default-grid.json` (identical layout shape), `mixed-browser-markdown.json` (same outer structure), and `deep-nested-splits.json` (every recursive split compounds the defect).

The Phase 0 plan literally flags this at `.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md:380`:

> "Pick the 'parent' panel = the tail of whatever the first subtree resolves to (for split.first we descend into first and remember the last panel id we created there; for split.second we split off that panel)."

The implementation picks the **head**, not the tail. And even the "tail" approach does not work against bonsplit's leaf-only split API — you cannot take a leaf inside `split.first` and split it to produce a sibling of `split.first` as a whole. Producing nested splits correctly against this API requires building outer splits **before** recursing into their children, which inverts the current depth-first order.

**Reproducer after fix is in:** add a structural assertion to `WorkspaceLayoutExecutorAcceptanceTests.swift` comparing `workspace.bonsplitController.treeSnapshot()` shape against the plan's `LayoutTreeSpec` (orientation + recursive pane grouping) for each fixture. The welcome-quad and default-grid fixtures will fail immediately.

✅ Confirmed — I traced the execution against the bonsplit source. Five of the five acceptance fixtures will produce an incorrect tree shape. Only `single-large-with-metadata.json` (no splits) escapes this bug.

### 2. Acceptance test does not verify layout shape (BLOCKER co-cause of #1)

`c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:106-147` (`runFixture`) asserts:
- `workspaceRef` non-empty
- `surfaceRefs.keys == expectedSurfaceIds`
- `paneRefs.keys == expectedSurfaceIds`
- no `validation_failed` entries in `failures`
- `total` timing under 2000ms

It does not assert:
- The live bonsplit tree shape matches the plan's layout tree.
- Split orientations match.
- Divider positions match.
- `selectedIndex` is honored.

The plan at `:446-456` describes the fixtures covering "welcome-quad shape," "default-grid" (mirroring `performDefaultGrid`), "deep-nested-splits" exercising "the depth-first layout walker, dividerPosition application, and parent-panel bookkeeping" — but the test for any of those just counts `surfaceRefs.keys`. The harness cannot fail on a wrong tree. This is a fake regression guard. The welcome-quad test passes today on a broken walker.

The `single-large-with-metadata` test does the right thing — it peeks into `SurfaceMetadataStore` and `PaneMetadataStore` and verifies the `mailbox.*` round-trip. That pattern needs to extend to every layout fixture, plus a structural assertion on the bonsplit tree shape.

✅ Confirmed by reading the assertions.

### 3. `SurfaceSpec.workingDirectory` silently dropped for terminals created via split (IMPORTANT)

`WorkspaceLayoutExecutor.swift:506-537` (`splitFromPanel`) forwards only `(panelId, orientation, insertFirst, focus, url, filePath)` into the `newXSplit` primitives. `newTerminalSplit` (`Sources/Workspace.swift:7250-7255`) has no `workingDirectory` parameter — it derives cwd from `panelDirectories[panelId]` or the workspace's `currentDirectory` (`:7263-7276`). So if a plan specifies `SurfaceSpec.workingDirectory` for a terminal surface that happens to be created via a split (any non-first-leaf terminal), that value is **silently ignored**.

This is the hidden-data-loss case the Phase 0 plan's "writes happen during creation, not after" contract was meant to prevent. The plan at `:244` lists `workingDirectory` as one of the fields to apply, but the walker has no code path for terminal-via-split cwd.

Worse, there's no warning — no `ApplyFailure` flagging "cwd requested but couldn't be applied." The data just disappears between plan JSON and live workspace. A Blueprint author in Phase 2 setting `cwd: ~/repo/logs` on a logs pane will be surprised that the resulting terminal runs in `~/repo` instead.

Fix options: (a) plumb `workingDirectory:` through `newTerminalSplit`, or (b) record a warning at the walker level when the field is non-nil for a split-created surface.

✅ Confirmed by reading the executor + Workspace primitives.

### 4. `bonsplitController.selectTab` steals focus mid-apply (IMPORTANT)

`WorkspaceLayoutExecutor.swift:436-443` calls `workspace.bonsplitController.selectTab(selectedTabId)` when a `PaneSpec.selectedIndex > 0`. `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift:269-278`:

```swift
public func selectTab(_ tabId: TabID) {
    guard let (pane, tabIndex) = findTabInternal(tabId) else { return }
    pane.selectTab(tabId.id)
    internalController.focusPane(pane.id)   // ← focus mutation
    ...
}
```

`selectTab` unconditionally focuses the pane containing that tab. When the plan's layout has multiple panes and `selectedIndex` is set on any pane other than the last-materialized one, the executor's final focus lands wherever the last `selectTab` call pointed — not on the pane the user intended, and not controlled by `ApplyOptions.select`.

Phase 0 plan section 9.3 argues `workspace.apply` is "intent-bearing" so the outer workspace selection is acceptable. The per-pane tab selection inside the walker is a *different* focus move the plan did not budget for, and it's not gated on `options.select`. If a future caller passes `select: false` (intending "create a workspace in the background"), the walker still steals focus via `selectTab`.

Also, the executor uses the canonical `setPanelCustomTitle` (`Workspace.swift:5873-5901`) and `setCustomTitle` / `setCustomColor` on `Workspace` — those are data-only. `selectTab` is the one side-effect that breaches the stated no-focus-theft contract.

Fix: route through a focus-preserving API (or drop `selectTab` entirely and let bonsplit's default selection stand) unless `options.select == true` AND the targeted pane is the creation-intent pane.

⬇️ Real, but smaller blast radius than #1/#3 in Phase 0 since the acceptance fixtures don't set `selectedIndex > 0`. The contract breach is still there and Phase 1 snapshots will trip it the first time a captured workspace has a non-zero selected tab.

### 5. `status` reserved-key kebab rule conflicts with "ready" (POTENTIAL; verified non-issue)

`SurfaceMetadataStore.reservedKeys` includes `status` (`Sources/SurfaceMetadataStore.swift:143-152`). `validateReservedKey(key: "status", ...)` uses `validateString` (`:158`) not `validateKebab`. `"ready"` is fine. Initially I suspected a regression here; the single-large-with-metadata fixture writes `"status": "ready"` and `"role": "driver"`, `"task": "cmux-37"`, `"model": "claude-opus-4-7"`. All pass the reserved-key validators (`role`/`model` are kebab, `task` is plain string up to 128 chars, `status` is plain string up to 32). No issue.

❌ ~~Initially suspected a validation rejection; struck through after reading `validateReservedKey`.~~

### 6. Seed-panel replacement closes a terminal panel while its Ghostty surface is mid-init (POTENTIAL)

`WorkspaceLayoutExecutor.swift:369-391` — when the plan's root leaf is browser or markdown, the walker creates the replacement in the seed's pane, then calls `workspace.closePanel(seed.id, force: true)`. The seed `TerminalPanel` was constructed inside `Workspace.init` (`Sources/Workspace.swift:5426-5434`) moments ago; its Ghostty surface may not yet be active. Force-closing a freshly-minted terminal is a codepath the app normally doesn't hit — closing a terminal right after creation, in the same main-actor tick.

`closePanel(_: force:)` (`Sources/Workspace.swift:7717-7758`) routes through `bonsplitController.closeTab(tabId)`, which is synchronous. As long as bonsplit and the TerminalPanel teardown are both ready for a panel closed before its surface attached, this is fine. I have not traced the full TerminalPanel teardown path; there's a real risk of a dangling Ghostty surface handle or a Combine subscription that expected the panel to live longer.

❓ Likely benign, but worth an explicit test. None of the Phase 0 fixtures currently exercise browser-root or markdown-root — every fixture's first leaf is a terminal. The contract (step 4 of the plan) is unexercised in this PR.

Add a sixth fixture with a browser-root plan (`{layout: pane([docs]), surfaces: [{kind: browser, ...}]}`) to tickle this path.

### 7. `v2MainSync` blocks socket thread for the full executor run (IMPORTANT)

`Sources/TerminalController.swift:4385-4399` wraps the entire `WorkspaceLayoutExecutor.apply` call inside `v2MainSync { ... }` which is `DispatchQueue.main.sync` (`:3225-3230`). The plan's acceptance target is 2s; the `ApplyOptions.perStepTimeoutMs` default is 2000ms. So the socket thread is blocked on main for up to the same 2s window.

The CLAUDE.md socket command threading policy allows this for "commands that directly manipulate AppKit/Ghostty UI state" — `workspace.apply` qualifies. But:

- The header-comment promise in `v2WorkspaceApply` (`:4347-4348`) says "Decode the plan and (optional) options off-main. Validation failures never touch the main actor." In practice decoding is the only off-main work. Plan validation (`WorkspaceLayoutExecutor.validate`) runs inside `v2MainSync`. The comment overstates what's off-main.
- Any client sending a second socket command while `workspace.apply` is running will see it queued behind the blocking sync. For a debug CLI that's tolerable; for an operator with agents pushing telemetry in parallel, a 2s freeze on every workspace-create-from-plan is noticeable.

The fix is modest: lift `WorkspaceLayoutExecutor.validate(plan:)` out of the main-sync block so at least validation errors short-circuit off-main. That matches the comment's claim and the rest of the codebase's v2 handlers.

⬇️ Real but Phase-0-tolerable. Flag as a `// TODO(CMUX-37 Phase 1+)` with the readiness `async` refactor.

### 8. `v2EnsureHandleRef` fallback in weak-self minter is inconsistent (POTENTIAL)

`Sources/TerminalController.swift:4388-4396`:
```swift
workspaceRefMinter: { [weak self] uuid in
    self?.v2EnsureHandleRef(kind: .workspace, uuid: uuid) ?? "workspace:\(uuid.uuidString)"
}
```

If the TerminalController is deallocated between executor scheduling and the minter being called, the fallback returns `"workspace:<uuidString>"`. The canonical v2 ref format is `"workspace:<ordinal>"` (`:3283`). A consumer that sees a `workspace:AB12...` ref and tries to resolve it via `v2ResolveHandleRef` will get nil — the ref doesn't exist in the bidirectional map.

Realistically `self` can't deallocate while we're inside `v2MainSync { ... }` called from a method on `self`. The fallback is dead code. Still, the format divergence is a foot-gun if someone copies this minter pattern elsewhere.

⬇️ Cosmetic. Either assert `self != nil` with a precondition (since this *can't* happen in practice here) or just drop the fallback. Not a ship-blocker.

### 9. CLI `c11 workspace-apply` swallows warnings/failures from JSON output mode in useful ways (POTENTIAL)

`CLI/c11.swift:1713-1760` — when `jsonOutput` is true, the full ApplyResult payload is dumped via `jsonString(formatIDs(payload, mode: idFormat))`. When `jsonOutput` is false, it prints a summary. Both paths surface warnings and failures. ✅ Reasonable.

One thing to watch: the pretty-print path uses `payload["failures"] as? [[String: Any]] ?? []` and reads `code`, `step`, `message` strings. That's correct for the wire shape of `ApplyFailure`. ✅ OK.

No issue.

### 10. Fixtures directory not declared in `project.pbxproj` (POTENTIAL)

`GhosttyTabs.xcodeproj/project.pbxproj` adds `WorkspaceApplyPlanCodableTests.swift` and `WorkspaceLayoutExecutorAcceptanceTests.swift` to the `c11Tests` target but does not add the `Fixtures/workspace-apply-plans/` directory or any of the five JSON files as bundle resources. The test loads fixtures via `URL(fileURLWithPath: #filePath)` relative path at `WorkspaceLayoutExecutorAcceptanceTests.swift:150-154`, so it reads from the source checkout on disk — not from the xctest bundle.

This works on a CI runner that has the source tree checked out at the path `#filePath` reports. It will silently break if:
- The test bundle is installed somewhere else (unlikely for `xcodebuild test` on CI, but possible for ad-hoc runs with `xctest` on the built bundle).
- The source tree is moved/symlinked between build and run.

Conventional Xcode pattern is to add the Fixtures folder as a "Folder Reference" (blue folder, `PBXFileReference` with `lastKnownFileType = folder`) in the test target's Copy Bundle Resources phase, then load via `Bundle(for: self).url(forResource:)`. That would make the fixtures travel with the test bundle.

⬇️ Works on CI as-is; worth tightening before Phase 1 when operators may run ad-hoc.

### 11. Plan deviation: `apply()` dropped `async` (ACCEPTABLE)

Plan section 1 (`.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md:58`) specifies `async` on `apply`. Commit `e4f60b98` drops it. No trailing awaits were left over — the implementation is clean, no `async let`, no orphan `Task {}`. The socket handler `v2WorkspaceApply` ran the executor synchronously inside `v2MainSync`, which is exactly what a non-async executor requires. The test harness also matches (runs through a regular call, not `await`).

Phase 1's readiness pass will need `async` back for awaiting surface-ready notifications. Re-introducing it is a non-breaking change to the signature. The deviation is cleanly reversible and justified by the commit message.

✅ Acceptable. Flag in Phase 1 plan notes that the `async` re-adoption must carry a readiness test.

## What's Missing

1. **Structural layout assertions in the acceptance test.** See #2 above. Without these, the test suite cannot catch #1, which is the most serious defect on this branch.
2. **A fixture whose root leaf is browser or markdown.** The seed-replacement path (step 4, `WorkspaceLayoutExecutor.swift:369-391`) is unexercised. See #6.
3. **A fixture with `PaneSpec.selectedIndex > 0`.** The `selectTab` code path (and the focus-theft concern #4) is unexercised.
4. **A fixture with non-string `mailbox.*` values.** The strings-only guard (`WorkspaceLayoutExecutor.swift:631-643`) is unexercised by the test fixtures — the only test coverage is the Codable round-trip (`WorkspaceApplyPlanCodableTests.testSurfaceSpecPreservesMailboxStarKeysVerbatim`), which asserts the *wire* preserves non-string values. No test asserts the *executor* drops them with `mailbox_non_string_value`.
5. **A negative-path fixture or inline test exercising `duplicate_surface_id`, `unknown_surface_ref`, `split_failed` code paths.** Validation logic is all private static in the executor and the acceptance test only runs happy-path plans. `result.failures.allSatisfy { $0.code != "validation_failed" }` is the only validation assertion — positive-direction only.
6. **A test for the socket handler end-to-end.** `v2WorkspaceApply` is ~80 lines of handler logic with its own parse/decode/encode path, and no test calls it. The existing acceptance test calls the executor directly. An XCTest that constructs a `TerminalController`, calls the v2 switch with a raw params dict, and inspects the returned JSON would catch encoding regressions (e.g., `failures` array shape changes).
7. **A test that `select: false` does not foreground the workspace.** Nothing on this branch exercises the `ApplyOptions.select` flag in the non-default direction.
8. **Documentation of the plan deviation.** Commit `e4f60b98`'s message mentions the `async` drop but the plan file itself still says `async func apply`. Update `.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md:58` to reflect the synchronous Phase 0 signature, or leave a `*note: Phase 0 ships sync; Phase 1 restores async*` pointer. Right now future agents reading the plan will implement to the wrong signature.

## The Nits

- `Sources/WorkspaceLayoutExecutor.swift:438-443` — the `selectedIndex` path uses `Optional(paneSpec.surfaceIds[selectedIndex])` wrapped in `if let selectedSurfaceId = Optional(...)`. Array access by index on a bounded index is not optional; the `Optional()` wrapper is noise. Collapse to `let selectedSurfaceId = paneSpec.surfaceIds[selectedIndex]`.
- `Sources/WorkspaceLayoutExecutor.swift:115-117` — the indexing comment says "Validation already rejected duplicates" but `Dictionary(uniqueKeysWithValues:)` still **crashes** on duplicate keys. The comment is correct (duplicates fail validation first) but this is a belt-and-braces situation — if the validation logic ever regresses, this crashes at runtime. `Dictionary(grouping:by:)` or the keyed literal form would degrade more gracefully. Since Swift-the-compiler won't catch this for you, consider `Dictionary($0.surfaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })` to make "validator is the guard" explicit.
- `Sources/WorkspaceLayoutExecutor.swift:116` wording: "surfacesById" map is threaded via a `let` but then captured into a `WalkState` struct that takes ownership. The `surfacesById` parameter on `WalkState` could be `[String: SurfaceSpec]` directly (it is). Just — the walker then never uses `surfacesById` for the *first* leaf; it uses it only for `materializePane`'s additional-surface lookup. Inline the dict build next to the walker entry to avoid the misleading impression it's used throughout.
- `Sources/WorkspaceLayoutExecutor.swift:155` — `_ = walkState.materialize(plan.layout, intoAnchor: .seedTerminal(seedPanel))`. The return value (the subtree's first-leaf panel id) is discarded at the top level. OK at the root. Consider an explicit `@discardableResult` annotation on `materialize` to silence the pattern without the `_ =` prefix everywhere else in the walker.
- `Sources/Workspace.swift:7761-7766` — there are now two methods doing the same thing: the new `paneIdForPanel(_:)` (`:5611-5619`) and the preexisting `paneId(forPanelId:)` (`:7761-7766`). The 9fef6089 extract should have also consolidated this preexisting duplicate. Not a bug, just untidy.
- `Sources/TerminalController.swift:4347-4349` comment says "Decode the plan and (optional) options off-main. Validation failures never touch the main actor." Decoding is off-main; plan validation (`WorkspaceLayoutExecutor.validate`) runs inside `v2MainSync`. Tighten the comment or lift validation to actually be off-main.
- `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:63-66` — `UUID(uuidString: result.workspaceRef.replacingOccurrences(of: "workspace:", with: ""))` is fragile. The test-local minter is `"workspace:\($0.uuidString)"` so this works. But once the test starts exercising the socket handler (which uses ordinal refs), this parse silently returns nil. A small helper `uuid(fromTestRef:)` that knows about both formats would future-proof this.
- `CLI/c11.swift:1713` — command name is `workspace-apply` (hyphen), not `workspace apply` (subcommand under `workspace`). The Phase 0 plan section at `:83` specifies `c11 workspace apply --file <path>`. Minor inconsistency between plan prose and shipped CLI form. `c11 workspace-apply` works as a compact form but loses the grouping; consider adding an alias or updating the plan.

## Blockers

1. **Layout walker produces wrong trees for nested splits.** `WorkspaceLayoutExecutor.swift:448-501`. The depth-first walker splits from a leaf of `split.first` instead of composing outer splits first. Every plan with more than one split (4 of 5 acceptance fixtures) materializes a malformed tree. See "What Will Break #1" for the full trace. ✅ Confirmed against bonsplit source.

2. **Acceptance test lacks structural assertions.** `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:106-147`. The test passes on a broken walker — it only counts refs and timings. Without bonsplit-tree-shape comparison, this fixture cannot catch #1 or similar regressions. See "What Will Break #2". ✅ Confirmed by reading assertions.

## Important

3. **`SurfaceSpec.workingDirectory` silently dropped for split-created terminals.** `WorkspaceLayoutExecutor.swift:506-537` → `Workspace.swift:7250-7255`. Plan JSON `cwd` disappears between spec and live terminal; no warning, no `ApplyFailure`. See "What Will Break #3". ✅ Confirmed.

4. **`bonsplitController.selectTab` steals focus.** `WorkspaceLayoutExecutor.swift:436-443`. Unconditional focus move breaches CLAUDE.md socket focus policy when `options.select: false`. ⬇️ Smaller blast radius in Phase 0 (no fixture triggers it).

5. **`v2MainSync` blocks socket thread for full executor duration.** `Sources/TerminalController.swift:4385-4399`. Validation could trivially move off-main; currently blocks up to 2s. Flag for Phase 1 async readiness refactor. ⬇️ Phase-0-tolerable.

6. **Plan file unchanged despite `async` drop.** `.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md:58` still shows `async func apply`. Future agents will implement to the wrong signature. ✅ Confirmed.

## Potential

7. **Seed-panel replacement path unexercised.** `WorkspaceLayoutExecutor.swift:369-391`. No browser-root or markdown-root fixture; force-closing a just-minted terminal may surface latent teardown bugs. ❓ Likely benign.

8. **Fixtures not in test bundle resources.** `project.pbxproj` does not include `Fixtures/workspace-apply-plans/`. `#filePath` loading works on CI but is fragile for ad-hoc runs. ⬇️ Works today.

9. **`v2EnsureHandleRef` fallback format divergence.** `TerminalController.swift:4388-4396`. Dead-code fallback returns `workspace:<uuidString>` instead of the canonical `workspace:<ordinal>`. ⬇️ Cosmetic.

10. **Missing executor-level test for `mailbox_non_string_value` guard.** Codable test asserts wire round-trip of non-string values; no test asserts the executor drops them with a named warning.

11. **Missing negative-path tests.** `duplicate_surface_id`, `unknown_surface_ref`, `split_failed`, `metadata_override`, `metadata_write_failed` codes exist in the executor but have no test coverage.

12. **No socket-handler test.** `v2WorkspaceApply` has ~80 LOC of handler logic (parse, decode, encode, weak-self minter wiring) with zero coverage.

13. **`Dictionary(uniqueKeysWithValues:)` crashes on duplicate keys if validation regresses.** `WorkspaceLayoutExecutor.swift:115-117`.

14. **Duplicate `paneIdForPanel` methods on `Workspace`.** `:5611` (new) and `:7761` (existing) do the same thing.

15. **CLI name mismatch.** Plan specifies `c11 workspace apply`; branch ships `c11 workspace-apply`. Small plan-vs-code drift.

## Closing

**Is this code ready for production? No.**

Would I mass-deploy this to 100k users? Absolutely not. The executor builds the wrong workspace shape for any plan with nested splits, and the acceptance test is not equipped to see that. The 5-fixture acceptance suite the plan invested in specifically to prevent layout regressions provides effectively zero layout coverage.

Three things must change before this merges:

1. **Fix the layout walker** to compose outer splits before recursing into their children (or build the tree bottom-up, or use a two-pass scheme that pre-allocates panes and then fills them — the Phase 0 plan's "depth-first with parent-panel bookkeeping" strategy doesn't work against bonsplit's leaf-only `splitPane` API). Trace-validate against welcome-quad and default-grid before calling it done.

2. **Add structural layout assertions** to `WorkspaceLayoutExecutorAcceptanceTests`. Each fixture must compare `workspace.bonsplitController.treeSnapshot()` shape (orientation + recursive pane grouping + leaf surface ids) against the plan's `LayoutTreeSpec`. Add a helper that converts one tree to the other for comparison. Without this, the test does not defend the primitive.

3. **Plumb `workingDirectory` through `newTerminalSplit`** or emit an `ApplyFailure("metadata_override")` when the field is non-nil for a split-created terminal. Silent data loss on a documented plan field is not acceptable.

The schema half (`WorkspaceApplyPlan.swift`, Codable tests, `mailbox.*` round-trip via `PersistedJSONValue`, the strings-only guard location) is ready and can land as-is once the walker is fixed. The socket handler (`v2WorkspaceApply`) and CLI (`workspace-apply`) are minimal, correct, and follow the existing patterns — those are also ready. The TODO comments at the welcome-quad and default-grid migration sites are correct and minimal. Hot paths are untouched. `Resources/bin/claude` is untouched. There's no terminal-opinion creep.

The executor walker is the one load-bearing piece that isn't ready. Fix that and the branch becomes a strong foundation for Phase 1+.

**Next action for Impl:** re-read bonsplit's `splitPane` semantics (leaf-only), rewrite `materializeSplit` to either (a) split the containing ancestor pane before recursing, or (b) build the tree in outer-first order with explicit split-id tracking, then harden the acceptance test to compare tree shapes. Expect ~1 day of focused work.
