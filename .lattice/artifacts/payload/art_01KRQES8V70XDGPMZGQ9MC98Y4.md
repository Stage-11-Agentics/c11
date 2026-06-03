# Merge Review: C11-27 — Split c11Tests into pure-logic vs host-required

## 1. Verdict

**FAIL (plan-level)** — Direction and framing are right, but the plan does not resolve how a no-host XCTest bundle will resolve symbols from the c11 app executable. That question is load-bearing for the whole approach and needs a concrete answer (or a small spike) before implementation begins.

## 2. Synthesis

Two reviews returned; the Gemini run failed. Both reviewers agree the split is the right product move, the audit work behind the plan is genuine, the dependency on PR #164 is correctly called out, and the scope boundaries (no c11Core extraction, no headless-host detour, no touching the 47 pre-existing failures) are sensible. They diverge sharply on readiness. Claude reads the open questions as clarifications and recommends PASS with refinements; Codex identifies an unresolved technical blocker around test-bundle linkage and recommends FAIL at plan level. On the merits Codex is correct: the current `c11Tests` target uses `BUNDLE_LOADER = "$(TEST_HOST)"` pointing at the c11 app executable, and `@testable import c11` resolves the imported module's symbols *through* that host at runtime. Removing the host without specifying an alternative (compile a curated slice of production sources into the logic target, extract a `c11Core` library, or another verified path) leaves the plan with an undefined central mechanism. This contradicts the framing in Claude's Issue #1, which treats `@testable import c11` as a working default — it is, but only because the bundle is currently host-loaded.

## 3. Issues

### [CRITICAL] No concrete linkage strategy for the hostless target *(Codex; contradicts Claude's framing in his Issue #1)*
Today's `c11Tests` is app-hosted: `BUNDLE_LOADER = "$(TEST_HOST)"`, `TEST_HOST = "$(BUILT_PRODUCTS_DIR)/c11 DEV.app/Contents/MacOS/c11"`, `TEST_TARGET_NAME = c11`. The 73 "pure" files almost all use `@testable import c11` (or `c11_DEV`). With no host and no `BUNDLE_LOADER`, the test executable has no way to resolve those symbols. The plan lists `@testable import c11` under Risks as a *workaround*, but that's the current hosted shape — not a demonstrated hostless solution. Claude's review reframes this as "AppKit isn't *initialized* unless `NSApplicationMain` runs" and treats the import as harmless; that reasoning addresses runtime initialization, not link/load resolution, and is the wrong answer to the question Codex is actually asking.
**Recommendation:** Before bulk migration, require a spike: create the new hostless target, set empty `TEST_HOST` / `BUNDLE_LOADER`, add one representative pure test, and prove compile + run. The plan then locks one production-code access strategy: either compile a curated slice of c11 sources into the logic target, or pull the smallest viable `c11Core` library out (which means moving "library extraction" from Out of Scope into Approach). Until that's pinned, the rest of the file-level work is premature.

### [MAJOR] `-only-testing` selectors in `mailbox-parity.yml` need explicit migration *(Codex)*
`.github/workflows/mailbox-parity.yml` uses explicit selectors like `-only-testing:c11Tests/MailboxEnvelopeValidationTests`, `MailboxDispatcherTests`, and `StdinHandlerFormattingTests`. The plan classifies all Mailbox tests as pure, so those selectors will need the new target name after migration. Stale selectors can silently run zero tests depending on `xcodebuild` behavior.
**Recommendation:** Decide the new target name up front, then add a per-selector migration step for `mailbox-parity.yml`.

### [MAJOR] Per-target baseline for the 47 pre-existing failures *(Claude)*
Acceptance says "passes modulo the pre-existing failures." With 73 pure files and 47 known failures, some failures may live in the pure subset. Without a pinned list of which failures are *expected* on `c11-logic`, "green minus N" is unverifiable.
**Recommendation:** Before reclassifying, run current `c11-unit` on main, capture failing test names, intersect with the PURE classifier list, and pin the resulting "expected-failing-on-c11-logic" set into the plan. Acceptance becomes: green except for the N enumerated tests.

### [MAJOR] `c11-unit` running both targets risks doubling host-launch cost *(Claude)*
If `c11-unit` runs the pure target *and* the host target after the split, Xcode may double-spawn the host app (~22s × 2). The plan asserts "matches current behavior" without checking.
**Recommendation:** Decide explicitly — either (a) `c11-unit` keeps only the host target and a new aggregator scheme runs both, or (b) confirm by experiment that Xcode pools the host spawn. Don't leave this as a discovery for the delegator.

### [MAJOR] `c11-ci` scheme behavior after the split is unspecified *(Claude)*
Three schemes exist (`c11`, `c11-unit`, `c11-ci`) but only `c11-unit` and a new `c11-logic` are addressed.
**Recommendation:** State explicitly what `c11-ci` runs after the split and why.

### [MAJOR] Classifier-by-grep isn't strong enough to prove hostless safety *(Codex; overlaps with Claude's Risk #2 acknowledgement)*
A test can contain zero UI symbols while exercising production code that transitively touches `NSApp`, `@MainActor` state, `NSScreen`, `NSColor`, `NSWorkspace`, or main-actor singletons. The grep classifier catches surface symbols only.
**Recommendation:** Migrate a small representative slice first (one Mailbox, one Health parser, one Theme/settings, one Workspace snapshot/blueprint), use the result to refine the classifier, and require the pinned list to record *why* each moved file is hostless-safe — not just "zero grep hits."

### [MAJOR] File-by-file change list and final naming not committed *(Codex; overlaps with Claude's minor "target name not decided")*
The plan moves between `c11-logic-tests`, `c11Tests-Pure`, and scheme name `c11-logic` interchangeably. Additional surfaces not enumerated in the plan: `c11-unit.xcscheme`, `c11-ci.xcscheme`, `.github/workflows/ci-macos-compat.yml`, `.github/workflows/test-e2e.yml`, the repo `AGENTS.md` symlink, and (depending on policy) `~/.claude/CLAUDE.md`. Module name, product name, and scheme XML all depend on the chosen target name.
**Recommendation:** Pin one set of names — suggest target `c11Tests-Pure`, scheme `c11-logic`, module `c11Tests_Pure` — and produce a concrete file-by-file change list including all four affected workflows plus both schemes plus the docs surfaces.

### [MINOR] `<5 seconds` acceptance criterion is unvalidated *(Codex)*
73 files include disk-heavy Mailbox and persistence tests; `<5s` may be arbitrary.
**Recommendation:** Replace with measurable criteria tied to the actual goal: no `c11 DEV.app` process/window launches during `c11-logic`, `TEST_HOST` / `BUNDLE_LOADER` are empty for the logic target, and wall-time threshold is set from the spike's vertical-slice run rather than guessed.

### [MINOR] CI workflow enumeration is incomplete *(Claude; overlaps with Codex MAJOR file-by-file)*
Plan mentions `ci.yml` and `mailbox-parity.yml` plus "etc." Actual references in `.github/workflows/` are four files: `ci.yml`, `test-e2e.yml`, `mailbox-parity.yml`, `ci-macos-compat.yml`.
**Recommendation:** Enumerate all four and state what each runs post-split.

### [MINOR] pbxproj editing tool not chosen *(Claude)*
Plan recommends "`xcodeproj` Ruby gem or a scripted approach." Pinning to the gem (and checking in the script) makes the audit repeatable.
**Recommendation:** Pick `xcodeproj` Ruby gem explicitly; commit the script under `scripts/`.

### [MINOR] Classifier script not committed *(Claude)*
"Full classified file list will be regenerated by the delegator" without the exact classifier script being shipped is a reproducibility gap.
**Recommendation:** Commit the classifier under `scripts/classify-tests.sh` (or inline it in the plan) and re-use it as a future guardrail when tests are added.

### [MINOR] `c11UITests` target not addressed *(Claude)*
Confirm it stays as-is.
**Recommendation:** One-liner under Out of Scope.

### [MINOR] File count off by two *(Claude)*
Plan says 101 files; `ls c11Tests/` shows 102 .swift files. Audit appears to predate two recent additions.
**Recommendation:** Delegator re-runs classifier post-PR-#164 and re-pins numbers.

### [MINOR] CLAUDE.md update scope underspecified *(Claude)*
The Testing-policy block has several adjacent claims (no local `xcodebuild test`, untagged DEV.app warning, `C11_SOCKET` examples). Some were written under the now-corrected assumption.
**Recommendation:** List the specific CLAUDE.md (and `AGENTS.md` symlink) lines to revise. Decide whether `~/.claude/CLAUDE.md` is in scope for this implementation agent.

### [MINOR] `feedback_no_local_xcodebuild_test.md` memory needs updating in lockstep *(Claude)*
Otherwise future agents will keep refusing to run `c11-logic` locally.
**Recommendation:** Add an acceptance line covering the memory update, or call it out in the AAR.

## 4. Positive Observations

- **Audit-backed framing** — both reviewers credit the "73 PURE / 28 HOST, classifier counts these symbols" evidence as the right level of rigor for a plan.
- **Provenance corrected on the record** — the original "would crash the operator's running c11" framing was wrong and the plan calls that out explicitly rather than inheriting it silently.
- **Out of Scope is genuinely well-scoped** — c11Core extraction, the 47 pre-existing failures, and the headless-host alternative are all named and held back. *(Caveat: c11Core may need to move back into scope if the linkage spike forces it.)*
- **Dependency on PR #164 is named** — cross-PR pbxproj conflict risk is exactly the thing plans typically miss.
- **Risks include the genuinely hard one** (`@testable import` transitive NSApp paths) — Claude notes that this is uncommonly well-identified, even though the surrounding framing needs sharpening.
- **Right high-level product call** — splitting pure logic from host-required is smaller and higher-value than headless-ifying every UI test.

## 5. Reviewer Agreement

**Agreed:** Direction is correct; the audit and risk identification are above average; PR #164 dependency, Out of Scope discipline, and acceptance-by-measurable-criteria are all good plan hygiene. Both reviewers want the four CI workflows enumerated, the target name pinned, and the `@testable import` transitive-NSApp risk taken seriously.

**Disagreed:** Readiness for implementation. Claude treats the open questions as clarifications (PASS with refinements). Codex treats the no-host linkage question as an unresolved core mechanism (FAIL at plan level). The disagreement turns on a technical claim — Claude's Issue #1 asserts that `@testable import c11` will work in a hostless bundle because AppKit isn't initialized without `NSApplicationMain`. That conflates initialization with symbol resolution. App-hosted XCTest bundles resolve the imported module's symbols via `BUNDLE_LOADER` pointing at the host executable; remove the host and that mechanism is gone. Codex is right on the merits. The merged verdict sides with Codex: the plan needs a small linkage spike (and possibly a c11Core extraction back-in-scope) before file-level migration begins.

**Gemini run failed and is not represented here.**
