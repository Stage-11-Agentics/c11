# C11-152: Live scrape-capture pipeline (wire scrapers into restore)

Phase B foundation. The scrape rail (`Sources/Conversation/Scrapers/`) exists as a unit-tested
seam but has **0 live call sites** — nothing invokes scrapers at restore. This ticket builds the
missing seam: at surface restore, per-kind scraper → `[ScrapeCandidate]` → `strategy.capture` →
`store.applyScrape`, so captured refs drive `strategy.resume` on the next restore. Injectable
filesystem so the pipeline is unit-testable without touching `~/.<k>/...`. Lights up **codex**
(which already has a scrape-primary strategy with no live capture rail) with **no regression** to
claude/codex resume. **BLOCKS C11-153 (pi) + C11-154 (omp)** — they import against the public seam
defined below.

## The architectural finding (why this is the seam, not "add a scraper")

- `ConversationStore` is seeded from the session snapshot at launch
  (`AppDelegate.prepareStartupSessionSnapshotIfNeeded` → `WorkspaceSnapshotConversationBridge.seedFromSnapshot`).
- Strategies (`CodexStrategy.capture`) already know how to turn `[ScrapeCandidate]` + surface
  context into a resolved `ConversationRef`. Scrapers (`CodexScraper.candidates`) already know how
  to produce `[ScrapeCandidate]` from disk.
- **The two are never connected at runtime.** No code path calls a scraper, hands its candidates to
  a strategy's `capture`, and writes the result to the store. So codex (and future pi/omp) panes
  never resolve a real session id at restore → `resume()` has nothing but a placeholder → skip.

This ticket adds that connective tissue and one live call site.

## Public seam shape (AUTHORITATIVE — pi/omp build against this; keep stable)

These are the types/signatures C11-153 and C11-154 import. They are additive; nothing existing is
removed except the rename in (5).

### 1. `ConversationScraper` protocol — `Sources/Conversation/Scrapers/ConversationScraper.swift` (new)
```swift
/// A per-kind bounded, metadata-only session scraper. Conformers walk a TUI's
/// on-disk session store and return candidates newest-first by mtime. Privacy
/// contract: filename + mtime + size only; never transcript bytes.
protocol ConversationScraper: Sendable {
    /// Stable kind identifier; matches `ConversationStrategy.kind` and
    /// `ConversationRef.kind` (e.g. "claude-code", "codex", "pi", "omp").
    var kind: String { get }
    /// Bounded top-N candidates, newest-first by mtime. `cwd` is stamped onto
    /// each returned candidate when provided (strategies filter on it).
    func candidates(cwd: String?) -> [ScrapeCandidate]
}
```
`ClaudeCodeScraper` and `CodexScraper` are retrofitted to conform (they already have `kind` +
`candidates(cwd:)` — no behavior change). pi/omp add `PiScraper`/`OmpScraper: ConversationScraper`.

### 2. `ConversationScraperRegistry` — `Sources/Conversation/Scrapers/ConversationScraperRegistry.swift` (new)
Mirrors `ConversationStrategyRegistry`. Keyed by `kind`, O(1) lookup, filesystem injected so
production uses the real FS and tests pass a mock.
```swift
struct ConversationScraperRegistry: Sendable {
    init(scrapers: [any ConversationScraper])
    func scraper(forKind kind: String) -> (any ConversationScraper)?
    func contains(kind: String) -> Bool
    var allKinds: [String] { get }
    /// Built-in scrapers, wired to one filesystem. pi/omp add their scraper here.
    static func v1(filesystem: ConversationFilesystem = DefaultConversationFilesystem()) -> ConversationScraperRegistry
}
```
`v1` initially holds `ClaudeCodeScraper(filesystem:)` + `CodexScraper(filesystem:)`. **pi/omp's only
registry edit is appending one scraper here** (plus their strategy in `ConversationStrategyRegistry.v1`).

### 3. `ScrapeCaptureContext` — in the pipeline file (new)
Per-surface restore context the pipeline consumes. Built from the session snapshot.
```swift
struct ScrapeCaptureContext: Sendable, Equatable {
    let surfaceId: String            // panel.id.uuidString
    let kind: String                 // terminal_type metadata value
    let cwd: String?                 // panel.directory
    let lastActivityTimestamp: Date? // optional mtime floor; nil at cold restore
    /// Build contexts from a loaded snapshot. Walks terminal panels; keeps only
    /// those whose `terminal_type` metadata is non-empty (the kind).
    static func contexts(from snapshot: AppSessionSnapshot) -> [ScrapeCaptureContext]
}
```

### 4. `ScrapeCapturePipeline` — `Sources/Conversation/ScrapeCapturePipeline.swift` (new)
The pure orchestrator. No actor, no I/O of its own beyond calling the injected scrapers. This is the
heart of the seam and the unit-test surface.
```swift
struct ScrapeCapturePipeline: Sendable {
    let scrapers: ConversationScraperRegistry
    let strategies: ConversationStrategyRegistry
    init(scrapers: ConversationScraperRegistry, strategies: ConversationStrategyRegistry = .v1)

    /// For each context: look up the scraper for its kind, pull candidates,
    /// hand them (+ existing wrapperClaim/push for that surface) to the
    /// strategy's `capture`, and collect the result IFF it is a genuinely
    /// scrape-derived ref (`capturedVia == .scrape`). Pure: never touches the
    /// store. Returns (surfaceId, ref) pairs to apply, in input order.
    func captureRefs(
        contexts: [ScrapeCaptureContext],
        existing: [String: SurfaceConversations]
    ) -> [(surfaceId: String, ref: ConversationRef)]
}
```
Per-context logic: existing active ref is routed into `ConversationStrategyInputs` as `push` (when
its `capturedVia != .wrapperClaim`) or `wrapperClaim` (when it is), so `CodexStrategy`'s
claim-time/cwd filter keeps working. We forward only `.scrape`-provenance results — a strategy that
merely echoes back the wrapper-claim placeholder (no disk match) produces nothing to apply, so the
store is never written with a placeholder via the scrape path.

### 5. Store write method rename: `recordScrape` → `applyScrape` — `Sources/Conversation/Store.swift`
The ticket/contract name is `store.applyScrape`. `recordScrape(surfaceId:ref:)` has **zero callers**
(grep-verified), so rename it to `applyScrape(surfaceId:ref:)` (same body, same reconcile rule).
Add the actor driver that runs the pipeline and applies results under isolation:
```swift
extension ConversationStore {
    @discardableResult
    func applyScrape(surfaceId: String, ref: ConversationRef) -> ConversationRef  // renamed from recordScrape
    /// Live scrape-capture driver. Runs the pure pipeline against the current
    /// store contents, applies each scrape-derived ref, returns what was applied.
    @discardableResult
    func runScrapeCapture(
        contexts: [ScrapeCaptureContext],
        pipeline: ScrapeCapturePipeline
    ) -> [(surfaceId: String, ref: ConversationRef)]
}
```

### 6. Live call site — `AppDelegate.prepareStartupSessionSnapshotIfNeeded`
After `seedFromSnapshot` and **before** the `--no-resume` sentinel / dirty-reclassify branches, run
the pipeline against the loaded snapshot, gated on `!ConversationStorePolicy.isDisabled` and a
non-empty context list, via the existing `Task.detached` + bounded-semaphore pattern (1s budget,
matching the neighbours — the actor work must run while `@MainActor` blocks on the wait):
```swift
if let snapshot, !ConversationStorePolicy.isDisabled {
    let contexts = ScrapeCaptureContext.contexts(from: snapshot)
    if !contexts.isEmpty {
        let pipeline = ScrapeCapturePipeline(scrapers: .v1(), strategies: .v1)
        // Task.detached { await ConversationStore.shared.runScrapeCapture(contexts:pipeline:) } + sema.wait(1s)
    }
}
```
Ordering: seed → **scrape-capture** → no-resume/dirty. `--no-resume` (markAllUnknown) and the dirty
reclassify still run *after* and therefore still win when they apply, preserving their contracts.

## Why no claude/codex resume regression (validation row 5)

- **claude (push-primary):** when a hook ref is seeded, it is routed as `push`; `ClaudeCodeStrategy.capture`
  returns it unchanged with `capturedVia == .hook` → filtered out (not `.scrape`) → store untouched.
  When there is no seeded ref but a top-by-mtime transcript exists, capture yields a `.scrape` ref with
  `state == .unknown` → `resume()` returns `.skip` → no auto-resume into a possibly-wrong session. Net:
  claude's existing resume behavior is unchanged.
- **codex:** today there are 0 live scrape call sites, so codex never auto-resumes. This seam is exactly
  what "lights it up": a single unambiguous cwd+mtime match → `state == .alive` → `resume()` →
  `codex resume '<uuid>'` (`.typeCommand`). Ambiguous (>1 candidate) → `state == .unknown` → skip. This
  is added capability, not a regression; the existing `ConversationStrategyTests`/`ConversationCrashRecoveryTests`
  assertions about strategy/store behavior are untouched.

## Files

| File | Change |
|------|--------|
| `Sources/Conversation/Scrapers/ConversationScraper.swift` | **new** — `ConversationScraper` protocol |
| `Sources/Conversation/Scrapers/ConversationScraperRegistry.swift` | **new** — registry + `v1(filesystem:)` |
| `Sources/Conversation/Scrapers/ClaudeCodeScraper.swift` | conform `ClaudeCodeScraper` + `CodexScraper` to `ConversationScraper` |
| `Sources/Conversation/ScrapeCapturePipeline.swift` | **new** — `ScrapeCaptureContext` + `ScrapeCapturePipeline` |
| `Sources/Conversation/Store.swift` | rename `recordScrape`→`applyScrape`; add `runScrapeCapture` |
| `Sources/AppDelegate.swift` | live call site in `prepareStartupSessionSnapshotIfNeeded` |
| `c11LogicTests/ScrapeCapturePipelineTests.swift` | **new** — pure tests (safe scheme) |
| `GhosttyTabs.xcodeproj/project.pbxproj` | add 3 new Sources to `c11` target + 1 test to `c11LogicTests` (via `xcodeproj` gem) |

New product Swift files join the **`c11`** target; the new test file joins **`c11LogicTests`** (so it
runs under the safe `c11-logic` scheme — `ConversationCrashRecoveryTests` already proves Conversation
symbols are reachable there via `BUNDLE_LOADER`). pbxproj edits go through the `xcodeproj` Ruby gem;
gate on `xcodebuild -list` + build-file ref-count symmetry, **not** the line diff (the gem reformats).

## Tests (`ScrapeCapturePipelineTests`, c11LogicTests target — safe to run locally)

Mock `ConversationScraper`/`ConversationFilesystem` (reuse the `MockFS` shape from
`ConversationScraperTests`). Cases:
1. **End-to-end acceptance (the gate):** a codex `ScrapeCandidate` for a surface (cwd match, single
   candidate) → `captureRefs` yields a `.scrape` ref `state == .alive` → `store.applyScrape` →
   `CodexStrategy.resume` returns `.typeCommand(text: "codex resume '<uuid>'", submitWithReturn: true)`.
2. **Ambiguous codex:** 2 candidates → ref `state == .unknown` → `resume` → `.skip(reason: "ambiguous")`.
3. **No regression — claude hook ref preserved:** seeded `.hook` ref present → pipeline forwards
   nothing for that surface (no `.scrape` write); the hook ref still drives `resume`.
4. **Injectable filesystem:** pipeline runs entirely against the mock; no real `~/.codex`/`~/.claude`
   access. Empty scraper output → empty applied set, store unchanged.
5. **`runScrapeCapture` actor driver:** applies the captured refs into a real `ConversationStore`
   instance and the post-state `active` ref round-trips to a resumable `.typeCommand`.
6. **`ScrapeCaptureContext.contexts(from:)`** extracts (surfaceId, kind, cwd) from a synthetic
   snapshot with a codex terminal panel; skips non-terminal / kind-less panels.

Plus run the existing logic-target regression guard `ConversationCrashRecoveryTests`. Note:
`ConversationStrategyTests` lives in the **host** `c11Tests` target (not `c11-logic`), so it is
exercised in CI, not locally — stated explicitly per CLAUDE.md's no-local-host-test rule.

## Validation (load-bearing)

- `xcodebuild -scheme c11-logic ... test -only-testing:c11LogicTests/ScrapeCapturePipelineTests` green.
- `-only-testing:c11LogicTests/ConversationCrashRecoveryTests` green (no store/strategy regression).
- Parse for `** TEST SUCCEEDED **`, not a trailing grep exit code.
- End-to-end evidence: case 1 above proves `ScrapeCandidate → applyScrape → resume .typeCommand`
  round-trips. A live codex quit+relaunch in a tagged build (`./scripts/reload.sh --tag c11-152`) is
  attempted as the "I saw it resume" gate; if the seam alone can't be meaningfully exercised live
  without the codex wrapper-claim path, attach the integration-test evidence and state why live-agent
  resume is deferred to the pi/omp tickets (which add the consuming strategies/scrapers).

## Risks / notes

- **Snapshot kind source:** `terminal_type` metadata is the kind. Panels without it are skipped (no
  scraper to run). Matches how the strategy registry is keyed.
- **Ordering vs no-resume/dirty:** scrape-capture runs first; markAllUnknown / reclassifyAfterCrash
  run after and still win — intended (operator no-resume and crash-recovery override disk scrape).
- **Bounded:** scrapers already cap at `maxCandidates` (16) and are stat-only; the pipeline adds no
  unbounded walk. The 1s semaphore budget matches the existing seed/reclassify seams.

## Plan-Review Cycle 1 Resolutions (AUTHORITATIVE)

Plan-review (single, `art_01KW8C98ZD7X28KPR4VXBKJ1ER`) returned **FAIL** on two factual claims about
the existing code that are wrong, plus two minor layout corrections. All folded in below; these
override the body above where they conflict.

1. **[CRITICAL] `recordScrape` is NOT zero-caller.** There is one live caller:
   `c11Tests/WorkspaceConversationResumeTests.swift:78`
   (`await ConversationStore.shared.recordScrape(...)`), a member of the **host `c11Tests`** target.
   **Resolution:** rename `recordScrape` → `applyScrape` (the canonical name pi/omp import) **and**
   update that one call site in the same change. The host test is not runnable locally (no-local-host
   rule), so this edit is **CI-verified** — call it out explicitly in the impl commit + validation note.
   Add `c11Tests/WorkspaceConversationResumeTests.swift` to the Files table. Drop the "zero callers"
   claim. (No deprecated alias is left behind — single clean name.)

2. **[MAJOR] `MockFS` is not reachable from the logic target.** `ConversationScraperTests.MockFS`
   lives in the **host `c11Tests`** target only; a `c11LogicTests`-target test cannot see it.
   **Resolution:** the new test declares its **own** local `ConversationFilesystem` mock **and** a
   local `ConversationScraper` mock (the pipeline needs a stub scraper exposing
   `func candidates(cwd:) -> [ScrapeCandidate]`). Do **not** borrow `MockFS`. The product types
   `ConversationFilesystem` / `DefaultConversationFilesystem` / `ScrapeCandidate` / strategies are
   product code and reachable via `BUNDLE_LOADER`, so only the test-side helpers are authored locally.

3. **[MINOR] `c11LogicTests/` is a target, not a directory.** Author the new test at
   **`c11Tests/ScrapeCapturePipelineTests.swift`** (physical path, mirroring
   `c11Tests/ConversationCrashRecoveryTests.swift`) and add it to the **`c11LogicTests` target only**.
   The Files-table path and §Tests heading are corrected to this.

4. **[MINOR] Guard single-target membership.** Validation adds: confirm the new test file is a member
   of `c11LogicTests` **only** (not also `c11Tests`) via build-file ref count, so the
   `-only-testing:c11LogicTests/ScrapeCapturePipelineTests` acceptance is actually locally-safe.

Net delta to the Files table: add `c11Tests/WorkspaceConversationResumeTests.swift` (rename caller);
the new test file path becomes `c11Tests/ScrapeCapturePipelineTests.swift` (logic target membership).
</content>
</invoke>
