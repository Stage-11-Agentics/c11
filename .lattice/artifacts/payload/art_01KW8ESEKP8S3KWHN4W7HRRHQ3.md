# Plan Review: C11-153 — pi exact-session resume (PiScraper + PiStrategy)

### 1. Verdict

**PASS** — Plan is complete, feasible, and aligned. Implementation can proceed.

### 2. Summary

I reviewed the plan to add `PiScraper` + `PiStrategy` and flip the `pi` manifest's `hasConversationStrategy` flag, verifying every load-bearing claim against the actual C11-152 pipeline as it exists on `origin/main` (commit `e6edf9513`, PR #273). The plan is unusually well-grounded: the scraper/strategy registry shapes, the `.scrape`-provenance contract, the filename grammar, the `isValidConversationUUID` regex, the manifest entry, and the parity test all match what the plan asserts. The one thing worth flagging is operational rather than a plan defect — the **local working tree is one commit behind `origin/main`** and does not contain the pipeline; the `feat/c11-153-pi-resume` branch is correctly based on `origin/main`, so implementation must proceed from there (not the stale local `main`).

### 3. Issues

**[MINOR] Branch base — local `main` is behind `origin/main`**
The current working-tree HEAD (`3428ceb20`) is an ancestor of `origin/main` (`e6edf9513`) and does **not** contain `ScrapeCapturePipeline.swift`, `ConversationScraperRegistry.swift`, or the `ConversationScraper` protocol — all of which the plan depends on. The plan's premise ("C11-152's scrape-capture seam is in `main`") is true for `origin/main`, and the named branch `feat/c11-153-pi-resume` already sits at `e6edf9513`, so the base is fine. The risk is only if the implementer branches off the stale local `main` by reflex.
**Recommendation:** Add one line to the plan's setup: confirm the branch is based on `origin/main` (`git log -1` shows `e6edf9513`) before the first edit, or `git fetch && git merge --ff-only origin/main` on local `main` first. No code change.

**[MINOR] `ConversationScraperRegistry.v1` is a function, not a property**
The plan says "`ConversationScraperRegistry.v1`: append `PiScraper(filesystem: filesystem)`." On `origin/main` the scraper registry's `v1` is a **static func** `v1(filesystem: ConversationFilesystem = …)` whose body holds the scraper array; the strategy registry's `v1` is a static **property**. The edit location (the array literal) is correct either way, but the asymmetry is worth knowing so the implementer doesn't expect a property and edit the wrong shape.
**Recommendation:** Note that the scraper-side edit goes inside `static func v1(filesystem:)`'s array (alongside `ClaudeCodeScraper(filesystem: filesystem)`, `CodexScraper(filesystem: filesystem)`), while the strategy-side edit goes in the `static let v1` array.

**[MINOR] `pi` has no wrapper-claim path, so the placeholder branch is dead in production**
`CodexStrategy.capture`'s empty-candidates branch returns `inputs.wrapperClaim`. Codex mints that placeholder via its wrapper; `pi` has no SessionStart hook and `resume: .fixed("pi -c\n")`, so `inputs.wrapperClaim` will be `nil` at runtime — `capture` returns `nil` when there are no scrape candidates. That's correct behavior (scrape is the primary rail), but it means the plan's `testPiPlaceholderSkips` exercises a state pi won't naturally reach in production; the test must construct a placeholder ref directly.
**Recommendation:** Keep the mirror as-is (returning `wrapperClaim`/`nil` is the right default). Just have `testPiPlaceholderSkips` build a placeholder `ConversationRef` explicitly rather than expecting `capture` to produce one. Optionally note in the file that pi has no claim rail, so this branch only guards against future wiring.

**[MINOR] Ambiguity disambiguation ignores the cwd encoded in the pi directory slug**
The pi layout is `<cwd-slug>/<ts>_<uuid>.jsonl`, so the recursive lister returns candidates from *all* cwd-slug directories. Like `CodexScraper`, `PiScraper` stamps each `ScrapeCandidate.cwd` with the *surface's* cwd (the `cwd:` argument), not a value parsed from the slug — so the cwd filter in `capture` is effectively a no-op and disambiguation falls back to mtime/claim-floor. Two pi sessions in different real cwds can therefore collide as "ambiguous." This exactly mirrors codex's existing limitation, so it is **in scope and consistent**, not a new defect.
**Recommendation:** Match codex (as planned). Optionally file a follow-up: pi's slug actually encodes cwd, so a future enhancement could parse it for sharper cwd filtering than codex gets. Do not expand this ticket's scope to do it.

**[MINOR] Validator doc-comment says "UUID v4" but accepts any version (cosmetic)**
Confirmed: `conversationUUIDPattern` is `^[0-9a-fA-F]{8}-…-{12}$` with no version-nibble enforcement, so a UUIDv7 matches — the plan's "no regex change" claim is correct. The *doc comment* above the pattern still reads "UUID v4 grammar," which is now slightly misleading for the pi case.
**Recommendation:** Optional one-line comment tweak ("8-4-4-4-12 hex; accepts v4 and v7") if the implementer touches `Strategy.swift`; not required.

### 4. Positive Observations

- **Research depth is the standout.** Every structural claim checks out against the real code: the pipeline pairs by kind, keeps only `capturedVia == .scrape`, the recursive lister is reused, the manifest dual-rail (`resume` independent of `hasConversationStrategy`) is real, and the `conversationShellQuote`/`isValidConversationUUID` helpers exist. This is planning done against the source, not from memory.
- **Correctly identifies the genuine divergence from `CodexScraper`.** `CodexScraper` takes the whole filename stem as the id; pi needs the substring after the last `_`. The plan calls this out precisely and tests it (`testPiScraperExtractsUUIDAfterLastUnderscore`, `testPiScraperRejectsNonUUIDTail`), which is the one place a naive copy-paste of codex would silently break.
- **The one-commit constraint is well-motivated.** Tying the manifest flag flip and the strategy registration into a single commit because `AgentManifestTests.testConversationStrategyPresenceParity` asserts `m.hasConversationStrategy == ConversationStrategyRegistry.v1.contains(kind:)` is exactly right — I confirmed that test exists and enforces precisely that invariant.
- **Test-target placement is correct and matches precedent.** `ScrapeCapturePipelineTests` and `AgentManifestTests` are both members of the `c11LogicTests` target (verified in `project.pbxproj`) despite living under `c11Tests/` on disk; putting `PiConversationTests.swift` in the same place with local mocks mirrors C11-152 and keeps the suite on the safe `c11-logic` scheme.
- **Validation is appropriately gated.** Blocking `pr_open` until live exact-resume is observed (capture the uuid, the typed `pi --session <uuid>`, and `c11 state verify` oracle output) meets the task's "live pi resumes exact session" acceptance criterion, and the plan pre-empts the "no `~/.pi/` yet" case by launching pi first.
- **Risk section is honest and accurate** — both listed risks (UUIDv7 validator, no live `~/.pi/`) are real and correctly resolved/mitigated.
