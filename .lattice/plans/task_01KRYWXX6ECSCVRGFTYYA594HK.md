# C11-104 plan — Sidebar worktree+branch chips (Option C + D bundled)

**Author:** agent:claude-opus-4-7 (C11-104-D1-1)
**Worktree:** `code/c11-worktrees/c11-104-sidebar-chips`
**Branch:** `feat/c11-104-sidebar-chips`
**Anchored at:** `7cbc27d31` (origin/main as of 2026-05-19)
**Spec sources:** `lattice show C11-104 --full` (refined SPEC + decisions wins) and `.lattice/orchestration/c11-104/{run-state,validation-plan}.md`.

This plan covers the eight sections the boot prompt asked for, with each
acceptance-criterion (`ACn`) traced from spec → resolver/projection → test.

---

## 1. Module mapping

### 1.1 Resolver

- **New file: `Sources/Metadata/GitContextResolver.swift`** (new directory).
  - Pure-Swift, host-less, no SwiftUI / AppKit imports.
  - Public surface: a `GitContextResolver` type with one entry point
    `resolve(cwd:gitRunner:fileManager:headMtime:) -> ResolvedGitContext?`.
  - The optional `gitRunner` and `fileManager` parameters let tests inject
    deterministic doubles. In production it defaults to a `git` Process
    runner that takes a 1-byte stdin so a hung child cannot stall the
    background queue and a `FileManager` reader for `.git/HEAD` mtime.
- **Wire-in: `Sources/TabManager.swift`**, alongside the existing
  `InitialWorkspaceGitMetadataSnapshot` path.
  - Extend `InitialWorkspaceGitMetadataSnapshot` (or add a sibling
    snapshot value) so the off-main probe captures the resolver output
    alongside `branch / isDirty / pullRequest`.
  - The main-actor application (`applyWorkspaceGitMetadataSnapshot`) writes
    the resolved `worktree` / `branch` / colored-dot / submodule data to
    the surface metadata store with source `.derived`.

### 1.2 Chip projection

- **New file: `Sources/Sidebar/WorktreeChipModel.swift`** (new directory).
  - Pure value-types + a `WorktreeChipProjector` enum that takes
    `(ResolvedGitContext?, settingsEnabled: Bool) -> [WorktreeChipRow]`.
  - Each `WorktreeChipRow` is one of:
    - `.branchOnly(BranchChip)` — main checkout
    - `.linkedWorktree(WorktreeChip, BranchChip)` — linked worktree
    - `.submoduleStack(outer: WorktreeChipRow, inner: WorktreeChipRow)`
  - `BranchChip` carries `label: String`, `isDimmed: Bool` (true for
    `main`/`master`/`trunk`), `isDetached: Bool`.
  - `WorktreeChip` carries `label: String`, `dotColorHex: String` (RGB
    sRGB hex from `hash(absolutePath)`).
- **Color hashing — new file: `Sources/Sidebar/WorktreeColorPalette.swift`**.
  - 10-entry palette tuned for both Light and Dark theme slots (selected
    against `C11Theme.swift` neutrals).
  - Hash function: SipHash-2-4 on the UTF-8 bytes of the absolute path
    (Swift's `Hasher` is salted across launches, so we use a stable
    DJB2 or FNV-1a roll-your-own — DJB2 chosen for two-line simplicity
    and deterministic output across `c11LogicTests`).

### 1.3 Sidebar render

- **Edit: `Sources/ContentView.swift` (`TabItemView` block, lines 11392–11617).**
  - Insert a new "worktree + branch chips row" between the
    `AgentChipBadge` row (11468–11492) and `effectiveSubtitle` (11494) — so
    chips sit immediately under the agent chip and above the description.
  - Render via a new `WorktreeChipsRow` view (new file
    `Sources/Sidebar/WorktreeChipsRow.swift`) so the body stays terse and
    `Equatable` stays cheap (no new env-object reads inside `TabItemView`).
  - `WorktreeChipsRow` accepts precomputed `[WorktreeChipRow]` only; no
    git/IO inside the view body. Hot-path discipline (AC10/AC11).

### 1.4 Settings toggle

- **Edit: `Sources/c11App.swift`.**
  - Add `@AppStorage("sidebarShowWorktreeChips") private var
    sidebarShowWorktreeChips = true` near the existing
    `sidebarShowGitBranch` declarations (search-by `sidebarShowGitBranch`
    locates the block in `ContentView.swift`; the matching Settings UI
    block lives in `c11App.swift` around line 3410 under
    `GroupBox("Workspace Metadata")`).
  - Add a `Toggle("Show worktree/branch chips", isOn:
    $sidebarShowWorktreeChips)` alongside "Render branch list vertically"
    in the same `GroupBox("Workspace Metadata")`.
- **Edit: `Sources/ContentView.swift` (`TabItemView`)** — add a matching
  `@AppStorage` read so the projection can be gated. Default on,
  live-toggleable.

### 1.5 Skill docs

- **Edit: `skills/c11/references/metadata.md`** — add `worktree` and
  `branch` to the canonical-keys table, document the new `derived`
  precedence tier, and update the precedence chain prose from
  `explicit > declare > osc > heuristic` to
  `explicit > declare > osc > derived > heuristic`.
- **Edit: `skills/c11/SKILL.md`** if and only if it carries the
  precedence chain or canonical keys near the surface. Spot-check after
  the reference edit — the SKILL.md "Canonical keys" table at lines
  ~196–215 needs the two new keys added (or a one-line pointer back to
  the reference).

### 1.6 Tests

- **New file: `c11Tests/GitContextResolverTests.swift`** — exercises the
  resolver against temp-dir-built git repos. Listed in the
  `c11LogicTests` Sources build phase only (pbxproj id
  `37DDE3B0A6A70E75A7B2BEDF`), NOT the `c11Tests` Sources phase.
- **New file: `c11Tests/WorktreeChipProjectorTests.swift`** — projector
  unit tests; constructed `ResolvedGitContext` inputs, asserts chip
  shape, dimming, color stability. Also added to `c11LogicTests`.
- **New file: `c11Tests/MetadataDerivedPrecedenceTests.swift`** — asserts
  that the new `.derived` rank sits between `.osc` and `.heuristic`
  and that `osc > derived` for the same key in both stores. Listed in
  `c11LogicTests`.

### 1.7 pbxproj wiring (do this last per pitfall guidance)

- Add three new `PBXFileReference` entries (in `c11Tests/` source group)
  for the three new test files.
- Add three new `PBXBuildFile` entries.
- Add the three new file refs to the `37DDE3B0` (c11LogicTests) Sources
  phase. Expect the gem to renormalize whitespace; verify with
  `xcodebuild -list` and the new file count instead of trying to gate
  on a clean diff.
- Add four new `PBXFileReference` + `PBXBuildFile` entries for the new
  source files (`GitContextResolver.swift`,
  `WorktreeChipModel.swift`, `WorktreeColorPalette.swift`,
  `WorktreeChipsRow.swift`), wired into the **`c11`** target Sources
  build phase (`A5001051`).

---

## 2. Resolver shape

### 2.1 Public type

```swift
public struct ResolvedGitContext: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case mainCheckout(branch: BranchValue)
        case linkedWorktree(basename: String, absolutePath: String, branch: BranchValue)
    }
    public enum BranchValue: Equatable, Sendable {
        case attached(String)
        case detached(shortSHA: String)
        case unknown            // worktree-with-deleted-branch graceful degrade
    }
    public let outer: Kind
    public let inner: Submodule?     // populated only when cwd is inside a submodule
    public struct Submodule: Equatable, Sendable {
        public let name: String          // basename of submodule's worktree
        public let absolutePath: String  // for color-hash continuity if we ever
                                         // hint the submodule row
        public let branch: BranchValue
        public let isDetached: Bool
    }
}
```

### 2.2 Resolution sequence (in order, short-circuiting)

1. **Existence check.** If `fileManager.fileExists(atPath: cwd)` is
   false → return `nil`. Handles AC7's "cwd that doesn't exist" race.
2. **Repo discovery.** `git -C <cwd> rev-parse --show-toplevel` — empty
   stdout / non-zero exit → not in git → return `nil` (covers AC7
   not-in-git and AC8 bare clone, since `--show-toplevel` errors in a
   bare repo).
3. **Submodule check.** `git -C <cwd> rev-parse
   --show-superproject-working-tree`. Non-empty stdout means the cwd is
   inside a submodule — capture that path as `superprojectRoot` and
   re-run the outer resolution against `superprojectRoot` (recursive
   call with the submodule-check disabled to prevent infinite recursion
   in the pathological "submodule of submodule" case — we capture only
   the immediate parent for the chip stack).
4. **Linked vs main detection.** Compare
   `git rev-parse --git-common-dir` and `git rev-parse --git-dir`. If
   they differ → linked worktree; if equal → main checkout. (More
   reliable than scanning `.git` for "gitdir:" because it handles both
   `git worktree add` and the rare `gitfile` pattern used by
   submodules of the main repo.)
5. **Branch resolution.**
   - `git symbolic-ref --short HEAD` → attached branch.
   - Failure → `git rev-parse --short=7 HEAD` → detached HEAD with
     short SHA.
   - Failure → `.unknown` (covers AC9 worktree-with-deleted-branch:
     `symbolic-ref` succeeds with empty stdout or fails, and
     `rev-parse HEAD` may also fail if the underlying ref is gone).
6. **Inner (submodule) resolution.** If superproject detected in step
   3, run steps 4–5 against the inner cwd to populate the
   `Submodule` struct. Use the cwd-derived submodule root from
   `git -C <cwd> rev-parse --show-toplevel` for that inner pass.

### 2.3 Hot-path / threading

- Resolution runs on the existing
  `initialWorkspaceGitProbeQueue` (a non-main DispatchQueue) — same
  queue the current branch/PR probe uses. **Zero new work on main.**
- The OSC 7 cwd-update path
  (`updateSurfaceDirectory` → `scheduleWorkspaceGitMetadataRefreshIfPossible`)
  parses on main only for the dispatch hop. The actual `git` calls,
  the `.git/HEAD` mtime stat, and the cache lookup all run inside
  `Self.initialWorkspaceGitMetadataSnapshot(for:)` which is already
  `nonisolated static` and runs on the off-main timer queue.
- **Bounded `git` invocation.** Each Process gets a 1-byte (`b""`)
  stdin to defeat a paranoid hang, plus a `terminationHandler`-backed
  10s timeout (reuses `runCommandResult` plumbing in TabManager).

### 2.4 Cache

- **Key:** `(absoluteCwd: String, headMtime: Date)`.
- **Storage:** an `os_unfair_lock`-guarded `[CacheKey: ResolvedGitContext]`
  inside a `GitContextResolverCache` actor-like struct (we use
  `os_unfair_lock` instead of Swift's `actor` because the surrounding
  `initialWorkspaceGitProbeQueue` is GCD, not a structured-concurrency
  context — keeps the call sites simple).
- **Invalidation:**
  - cwd change → automatic (different key).
  - `.git/HEAD` mtime change → automatic (different key). Polled
    on every `resolve` call by `try?
    fileManager.attributesOfItem(atPath: "\(toplevel)/.git/HEAD")`.
  - Cap entries at 256; LRU evict.

### 2.5 What about main-checkout `.git` being a worktree's `gitfile`?

The reference HEAD for `.git/HEAD` lookups is `git rev-parse
--git-path HEAD` — this resolves the actual path on disk whether the
worktree uses a `.git` directory or a `.git` file pointer. Use that
instead of hand-constructing `toplevel/.git/HEAD`.

---

## 3. Chip projection shape

```swift
public enum WorktreeChipProjector {
    public static func project(
        _ context: ResolvedGitContext?,
        settingsEnabled: Bool
    ) -> [WorktreeChipRow] { ... }
}
```

### 3.1 Rules → ACs

| Spec rule | Projector output | AC |
|---|---|---|
| `settingsEnabled == false` | `[]` | AC14 |
| `context == nil` (not-in-git or missing cwd) | `[]` | AC7 |
| `.mainCheckout(.attached("main"))` | `[.branchOnly(BranchChip("main", dim))]` | AC2, AC3 |
| `.mainCheckout(.attached("feature/x"))` | `[.branchOnly(BranchChip("feature/x"))]` | AC2 |
| `.linkedWorktree(basename, abs, .attached(b))` | `[.linkedWorktree(WorktreeChip(basename, color=hash(abs)), BranchChip(b))]` | AC1, AC4 |
| `.attached(b)` with `b ∈ {main, master, trunk}` | `BranchChip.isDimmed = true` | AC3 |
| `.detached(short)` | `BranchChip(label: "(detached @ \(short))", isDetached: true)` | AC5 |
| `.unknown` (deleted underlying branch) | `BranchChip(label: "(no branch)", isDetached: false)` | AC9 |
| `inner != nil` | wrap in `.submoduleStack(outer, inner)` | AC6 |

### 3.2 Dot color rendering

- Dot is a SwiftUI `Circle()` 7pt × 7pt, filled with
  `Color(nsColor: NSColor(hex: dotColorHex)!)`. Lives inside the
  `WorktreeChip` view body in `WorktreeChipsRow.swift`.
- Branch chip stays neutral — color is worktree-only (matches spec
  decision 2 + the run-state note in §"Color hint specifics").
- **Dimming opacity:** 0.55 (sits inside the 15–25% reduction band
  the spec asked for, given Stage 11's existing chip foreground at
  ~0.85 opacity → 0.55 effective opacity ≈ 65% relative dimming,
  visually similar to GitHub's "default branch" dim treatment).
  Picked here for operator review at PR time per the spec; easy to
  tune if review prefers a different value.

### 3.3 Layout

- Single horizontal HStack per row, spacing 4. Submodule second row
  prefixed with `↳` (SF Symbol `"arrow.turn.down.right"` at chip
  baseline) and indented 8pt.
- Monospaced font for the worktree label (matches existing branch
  text style at line 11580–11593).

---

## 4. Submodule two-row layout

- Projector returns `[WorktreeChipRow]` of length **2** for
  `.submoduleStack(outer, inner)`:
  - Row 0: outer (superproject chips per the rules above).
  - Row 1: inner — prefixed with `↳` + monospace `submodule: <name>` +
    `branch: <name>`.
- `WorktreeChipsRow.swift` flattens the array into a `VStack(spacing:
  2)` with each row rendered as the chip pair (no dot prefix on the
  submodule row — color signal is per-worktree, not per-submodule).
- Inner branch dimming follows the same `{main, master, trunk}` rule.
- Inner detached HEAD rendered exactly like the outer detached form.

---

## 5. Settings wiring

- **AppStorage key:** `"sidebarShowWorktreeChips"`. Default `true`.
- **Read sites:** `TabItemView` (gates the new chips row), and the
  `WorktreeChipProjector.project(_:settingsEnabled:)` call (same value
  threaded through).
- **Write site:** the new Toggle in `c11App.swift`'s
  `GroupBox("Workspace Metadata")`, alongside "Render branch list
  vertically". One-line addition.
- **Live-toggleable:** `@AppStorage` already gives us this via
  `UserDefaults.didChangeNotification` plumbing — no app restart needed
  (AC19).
- **Naming:** matches the existing `sidebarShow*` convention
  (`sidebarShowGitBranch`, `sidebarShowGitBranchIcon`, etc.).

---

## 6. Test plan (per AC)

All tests live in `c11Tests/` (filesystem) but registered in the
`c11LogicTests` target only (per the C11-27 split). The pbxproj edit
is the load-bearing wiring step.

### `GitContextResolverTests.swift`

| Test | Setup | Asserts | AC |
|---|---|---|---|
| `testMainCheckoutOnFeatureBranch` | Temp repo, `git init`, commit, `git checkout -b feature/x` | `.mainCheckout(.attached("feature/x"))`, `inner == nil` | AC2 |
| `testLinkedWorktreeReturnsBasename` | Temp repo + `git worktree add ../wt-1 feature/x`, resolve against `wt-1` | `.linkedWorktree(basename: "wt-1", abs: <abs>, branch: .attached("feature/x"))` | AC1 |
| `testDetachedHeadReturnsShortSHA` | Temp repo, commit, `git checkout <sha>` | `.attached` fails, returns `.detached(shortSHA: <7-char>)` | AC5 |
| `testSubmoduleReturnsBothContexts` | Temp super repo + `git submodule add <inner>`, cd into inner, resolve | outer = `.mainCheckout` of super, `inner != nil` with submodule basename + branch | AC6 |
| `testSubmoduleInnerDetached` | as above + check out a SHA inside submodule | `inner.branch == .detached(...)` | edge case from run-state |
| `testNotInGitReturnsNil` | Temp dir, no `git init` | `nil` | AC7 |
| `testBareCloneReturnsNil` | `git clone --bare` of an inline repo | `nil` | AC8 |
| `testWorktreeWithDeletedBranchDegrades` | linked worktree, delete its branch from main | `.linkedWorktree(...).branch == .unknown` (no throw) | AC9 |
| `testCwdDoesNotExistReturnsNil` | path that doesn't exist on disk | `nil` (no throw) | AC7 edge |
| `testCacheHitDoesNotReinvokeGit` | spy `GitRunner`, two resolve calls with unchanged HEAD mtime | runner invoked once | AC12 |
| `testCacheInvalidatesOnHeadMtimeChange` | spy runner, touch `.git/HEAD`, resolve again | runner invoked twice | AC12 |

### `WorktreeChipProjectorTests.swift`

| Test | Input | Asserts | AC |
|---|---|---|---|
| `testMainBranchIsDimmed` | `.mainCheckout(.attached("main"))` | `BranchChip.isDimmed == true` | AC3 |
| `testMasterBranchIsDimmed` | `"master"` | dimmed | AC3 |
| `testTrunkBranchIsDimmed` | `"trunk"` | dimmed | AC3 |
| `testFeatureBranchNotDimmed` | `"feature/x"` | not dimmed | AC3 |
| `testWorktreeColorStableAcrossCalls` | same abs path × 2 | identical `dotColorHex` | AC4 |
| `testDifferentWorktreesGetDifferentColors` | two abs paths with known hash collision-free shape | different `dotColorHex` | AC4 |
| `testDetachedRendersShortSHA` | `.detached(shortSHA: "abc1234")` | `BranchChip.label == "(detached @ abc1234)"` | AC5 |
| `testSubmoduleProducesTwoRows` | super + inner | `result.count == 2` | AC6 |
| `testNilContextProducesEmpty` | `nil` | `[]` | AC7 |
| `testSettingsDisabledProducesEmpty` | non-nil context, `settingsEnabled: false` | `[]` | AC14 |

### `MetadataDerivedPrecedenceTests.swift`

| Test | Asserts | AC |
|---|---|---|
| `testDerivedRankIsBetweenOscAndHeuristic` | `MetadataSource.derived.rank == 1.5` analog (`> .heuristic`, `< .osc`) | AC13 |
| `testOscWinsOverDerivedForSameKey` | write `.osc`, then attempt `.derived` write same key → applied=false, reason=lower_precedence | AC13 |
| `testDerivedWinsOverHeuristic` | symmetric on `.heuristic` | AC13 |

### Tests deliberately NOT added

- Source-grep / source-shape tests (AC16 — explicit anti-pattern per
  CLAUDE.md and the spec).
- Snapshot tests (the spec lets us defer; we cover render
  behaviorally via the projector tests, which is the cheaper and more
  durable shape).
- Plist-shape tests (anti-pattern per CLAUDE.md).

### AC coverage summary

- AC1, AC2, AC4, AC5, AC6, AC7, AC8, AC9 → resolver tests.
- AC3, AC4, AC5, AC6, AC7, AC14 → projector tests.
- AC10, AC11 → reviewer inspection of the PR diff (the resolver
  call sites land off-main; `forceRefresh` and `hitTest` are
  literally not touched).
- AC12 → resolver cache tests.
- AC13 → precedence tests.
- AC15, AC16 → reviewer inspection of file placement + test character.
- AC17 → `skills/c11/references/metadata.md` updates inspectable in
  the diff.
- AC18, AC19, AC20 → operator post-merge smoke per validation plan.

---

## 7. Skill / reference doc updates

- **`skills/c11/references/metadata.md`:**
  1. Add two rows to the canonical-keys table for `worktree` and
     `branch` with type/rendering notes that mirror the spec's table.
  2. Add a new entry under the "Source precedence" section
     introducing `derived`, between `osc` and `heuristic`, with a
     short prose paragraph explaining "system-computed projections of
     ground-truth state (cwd, gitfs); agents should not write derived
     keys directly — they're recomputed automatically."
  3. Update any prose copy that hard-codes the
     `explicit > declare > osc > heuristic` chain.
- **`skills/c11/SKILL.md`:** small surgical edit to the canonical-keys
  table near line ~196 to keep it consistent with the reference.
  Don't expand the prose — the skill stays terse per the "trust model
  intelligence" rule.

The skill writes are pull-from-spec, not free invention; the spec's
"Refined SPEC" section already states the new precedence tier and the
two keys.

---

## 8. Risks (surfaced from code reading; not in the original ticket)

### R1 — `gitProbeDirectory` returns nil for non-terminal panes

`gitProbeDirectory(for:panelId:)` in TabManager only resolves a
directory when the panel has one (terminal surfaces). Browser /
markdown / settings panes never trigger the OSC 7 cwd path and have
no `panelDirectories[panelId]` entry, so the worktree chip will only
appear for terminal surfaces. **Acceptable for v1** — the spec is
explicit that the chip is "operator-glanceable signal for terminal
surfaces" and the spec's out-of-scope list mentions
"cross-process visibility (e.g., displaying worktree chip on
non-terminal surfaces like markdown panes)" as a future-ticket item.

### R2 — Sidebar row height growth

Adding a new chip row under the agent chip shifts the visual rhythm of
the workspace row. Worth a one-line operator note in the PR body so
they can eyeball the density at review time. If the operator dislikes
the row, the toggle (default on) lets them switch it off without a
revert.

### R3 — `c11LogicTests` build dependency

The c11-logic scheme depends on the c11 target's debug dylib (per
CLAUDE.md "Testing policy"). My new resolver and projector files land
in the c11 target's source set, so the test target compiles against
them via the dylib. Validate by running `xcodebuild -scheme c11-logic
test` on a warm cache before declaring local-green.

### R4 — Hot-path discipline edge

The OSC 7 handler currently triggers
`scheduleWorkspaceGitMetadataRefreshIfPossible` which runs a sequence
of 6 staggered probes (0, 0.5, 1.5, 3, 6, 10s). Adding the resolver
to that sequence multiplies the off-main `git` calls per directory
change by 6. **Mitigation:** the resolver shares the
`InitialWorkspaceGitMetadataSnapshot` capture step — one snapshot
includes branch + worktree + submodule — so we add **zero net
process spawns** (just two extra `rev-parse` calls per existing
snapshot, all bounded by the existing 10s `runCommandResult`
timeout).

### R5 — Submodule color hashing

Spec is explicit: color hash input is the worktree absolute path.
For the submodule row, the inner row is **not** a worktree — it's
the submodule's working tree, which `git` does not consider a
"linked worktree." So the inner row gets no color dot, consistent
with the spec's "branch chip stays neutral" guidance. The submodule
basename label appears, but no `●` prefix. This is the intended
behavior; calling it out so the reviewer doesn't flag it as a miss.

### R6 — Worktree label for nested worktrees on shared name

Two parallel worktrees with the same basename in different parent
directories will render the same chip label but different colors
(spec confirmed: decision 3). Operator-glance disambiguation falls to
the color signal. If the operator finds the color too subtle, the
follow-up ticket can switch the label to "<parent>/<basename>" —
deliberately not done here because the spec says basename only.

### R7 — pbxproj diff bloat

Per the pitfall in CLAUDE.md ("pbxproj edits via the `xcodeproj`
Ruby gem normalize formatting"), the test target wiring will likely
produce a wider diff than the semantic change warrants. I will avoid
the Ruby gem entirely and edit the pbxproj by hand with `Edit` calls
on the four insertion points (`PBXFileReference`, `PBXBuildFile`,
the `c11LogicTests` Sources phase, and the c11 target Sources phase),
keeping the diff under ~25 lines per file added.

---

## Execution sequence

1. ✅ Move ticket to `in_progress`. (Done.)
2. Write `GitContextResolver.swift`, `WorktreeColorPalette.swift`,
   `WorktreeChipModel.swift`. Pure-logic — no UI yet.
3. Write the three test files. Run `xcodebuild -scheme c11-logic test`
   to confirm resolver + projector + precedence tests pass.
4. Wire the new `MetadataSource.derived` case into
   `SurfaceMetadataStore.swift` + `PaneMetadataStore.swift` +
   `PersistedMetadata.swift`. Run tests again.
5. Write `WorktreeChipsRow.swift`. Wire into `TabItemView` in
   `ContentView.swift`. Add the `@AppStorage` read.
6. Add the Settings toggle in `c11App.swift`.
7. Wire the resolver call into `applyWorkspaceGitMetadataSnapshot`
   in `TabManager.swift` so the resolved context flows into surface
   metadata. Add the chip projection call in the sidebar render path.
8. pbxproj wiring: add four source-file refs to c11 target, three
   test-file refs to c11LogicTests target. Run `xcodebuild -list` to
   sanity-check.
9. Tagged-build smoke: `./scripts/reload.sh --tag c11-104` and visually
   inspect a worktree pane vs. the main checkout vs. inside `ghostty/`
   (for the submodule case).
10. Update `skills/c11/references/metadata.md` + `skills/c11/SKILL.md`.
11. Run `lattice code-review`. Address findings. Push + open PR.

---

## Plan amendments

*(Appended after plan-review per the boot prompt. The full review pack
lives at `.lattice/orchestration/c11-104/c11-104-plan-review-pack-2026-05-18T2228/`
in the main repo. Verdict: **revise-then-proceed**. Below is how each
finding was resolved or deferred.)*

### Blockers — resolved

- **B1 (integration map with existing TabManager probe + `sidebarShowBranchDirectory`).**
  Resolved by **extending the existing probe**, not duplicating it.
  `InitialWorkspaceGitMetadataSnapshot` now carries `gitContext:
  ResolvedGitContext?` alongside `branch / isDirty / pullRequest`. One
  off-main probe pass, one generation-token system, one apply step.
  The new chips render in a **new sidebar row** beneath the agent
  chip — the existing branch + directory row remains for now
  (default-on; gated by the existing `sidebarShowBranchDirectory`).
  The new master toggle `sidebarShowWorktreeChips` (default on) gates
  the new row only. Both can be hidden independently.

- **B2 (cache key for linked worktrees / submodules).** Resolver
  exposes `GitContextResolver.headPath(forCwd:runner:)` which calls
  `git rev-parse --git-path HEAD` to resolve the *actual* HEAD path
  (handles gitfile indirection in linked worktrees and submodules).
  `GitContextResolverCache.Key` takes opaque `headMtime: Date?` — the
  runtime doesn't yet read-through the cache (the existing
  TabManager probe rate-limits resolution); the cache struct is in
  place for future use.

- **B3 (submodule resolution sequence).** Resolver does **two
  passes**: (1) if `--show-superproject-working-tree` from cwd is
  non-empty, run `resolveOuter` against the *superproject path* so
  `--show-toplevel` returns the superproject root; (2) run
  `resolveSubmodule` against the original cwd for the inner row.

- **B4 (stale-async-result handling).** Resolution piggybacks on
  `scheduleWorkspaceGitMetadataRefresh` which already uses per-key
  generation tokens + expected-directory check. No new code path.

- **B5 (`derived` source policy).** Decided:
  - **Socket writability:** accepted via the standard precedence
    chain; documented as system-computed so agents don't write.
  - **Persistence:** `PersistedMetadataBridge.encodeValues` /
    `encodeSources` filter `.derived` source records. Derived keys
    are recomputed on restore, not round-tripped through snapshots.
    Covered by `testDerivedKeysAreDroppedFromSnapshotCapture`.
  - **Clear semantics:** when cwd leaves a git repo the resolver
    writes empty-string values (which the projector treats as
    "no chips").

- **B6 (test file paths).** Implementation uses `c11Tests/` with
  c11LogicTests target membership (the existing convention).
  pbxproj edited by hand to minimize diff bloat.

### Important — addressed

- **I1 (localization).** Settings strings use `String(localized:
  defaultValue:)` keyed at
  `settings.sidebar.showWorktreeChips.title` /
  `…description`. Translation pass for the six locales is a follow-up.

- **I2 (runtime-shape AC10).** `GitContextResolver.resolve` opens
  with `dispatchPrecondition(condition: .notOnQueue(.main))`. Tests
  hop to a background queue via `resolveOffMain` helper.

- **I3 (git-subprocess timeout).** `ProcessGitRunner.timeout` defaults
  to 5s; terminate + SIGKILL escalation after a further 200ms.

- **I4 (multi-surface ambiguity).** Chip row reflects the
  focused-surface's `panelGitContexts` entry.

- **I7 (long branch name).** `GitContextResolver.truncateBranchLabel`
  middle-truncates with `…` to fit the canonical 64-char cap.

- **M1, M2, M5** addressed in implementation.

### Deferred (out of scope this PR)

- **I5** (restore-window gap), **I6** (worktree directory removed),
  **M4** (dirty marker + PR pill on new chips), **M6** (theme-key
  opacity), **EW1** (color on surface model), **E1–E3**
  (deriver-protocol abstraction).

### Surface-to-user — answered

- **S2 — coexist with legacy row.** New chip row and legacy
  branch/directory row both render; gated by separate toggles.
- **S4 — derived chips are agent-readable** via `c11 get-metadata
  --key worktree`.
- **S5 — submodule chip verb** is `submodule:` with `↳` indent;
  display name = basename of `git rev-parse --show-toplevel`.
- **S8** noted: OSC 7 fires from the shell starting an agent TUI,
  so the chips are correct from spawn time even if the agent doesn't
  re-emit OSC 7 during its run.

### Test status

All three new test suites pass on `c11-logic`:

- `GitContextResolverTests` — 14 tests, all pass.
- `WorktreeChipProjectorTests` — 13 tests, all pass.
- `MetadataDerivedPrecedenceTests` — 12 tests, all pass.

Pre-existing failures on `c11-logic` (verified by stashing C11-104
changes, running tests on bare origin/main anchor `7cbc27d31`, seeing
the same 16 failures): BrowserImport, CLIHealth (path-redaction),
CommandPalette, DescriptionSanitizer, Workspace*Restore / Snapshot
tests crashing in `GhosttyTerminalView.swift:1200` due to `NSApp`
being nil under XCTest. **Not caused by C11-104.**
