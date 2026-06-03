# Merged Plan Review: C11-27 — Split c11Tests into pure vs host-required targets

## 1. Verdict

**FAIL (plan-level)**

## 2. Synthesis

Two reviewers (claude, codex) converged independently; the third (gemini) failed and is not factored in. Both reviewers endorse the direction — the operator pain is real, the 73/28 audit is sound, and the host/no-host split is the right shape — but both refuse to pass the plan because its central technical decision is unresolved: how a no-`TEST_HOST` XCTest bundle links against the c11 app code that the moved tests still `@testable import`. Without that decision, the pbxproj edit cannot be specified, and an aborted implementation attempt is the most likely outcome. The reviewers also agree, in different words, that the CI update surface (especially `mailbox-parity.yml`'s `-only-testing:c11Tests/Mailbox*` selectors) is underspecified and will silently break, and that grep-only classification is too thin to prove a test is actually hostless. A second planning pass that locks the linkage strategy, names the new target/scheme, and enumerates the exact CI/docs files to touch is the cheaper path forward.

## 3. Issues

**[CRITICAL] Hostless test target linkage is undefined — this is the load-bearing decision (claude MAJOR #1, codex CRITICAL)**
Both reviewers flagged this as the blocker. The sampled "pure" tests use `@testable import c11` / `@testable import c11_DEV`. Today's `c11Tests` target works because `TEST_HOST` and `BUNDLE_LOADER` point at the built app; a no-host logic bundle won't have that. The plan lists three options (`@testable import c11`, extract `c11Core` library, implicit-via-`BUNDLE_LOADER`) and commits to none, but the option chosen drives the entire pbxproj edit, the file membership list, and whether a production refactor is in scope.
**Recommendation:** Lock the strategy now, as an explicit decision tree:
1. **Primary path:** dual-compile a curated subset of `Sources/` files directly into the logic test target (no `TEST_HOST`, no `BUNDLE_LOADER`, no `@testable import c11` needed because the files are compiled in-target). Define the exact source-file inclusion list, explicitly excluding `c11App.swift` and AppKit/SwiftUI-heavy files.
2. **Fallback:** `@testable import c11` with `BUNDLE_LOADER` pointing at the app but no `TEST_HOST` (verify this combination actually skips app launch on a 2–3-test spike before committing).
3. **Escalation:** extract a `c11Core` SwiftPM/Xcode framework — only if 1 and 2 both fail.
Spike-first on a representative pure test (one Mailbox + one Stdin) before doing all 73. Specify the new target's build settings explicitly: empty `TEST_HOST`, empty `BUNDLE_LOADER`, dependencies, linker inputs, and module-import shape.

**[MAJOR] `mailbox-parity.yml` `-only-testing` selectors will silently break (claude MAJOR #2, codex MAJOR #3 — partial overlap)**
`.github/workflows/mailbox-parity.yml` lines 152–160 use `-only-testing:c11Tests/MailboxEnvelopeValidationTests` (and nine similar). All ten classes are in the PURE bucket and will move to the new target. The selector form resolves to zero tests after the move and CI goes silently green.
**Recommendation:** Decide the new target name first, then update those selectors to `-only-testing:<newTarget>/Mailbox*` and `-only-testing:<newTarget>/StdinHandler*`. Re-audit `ci.yml`, `ci-macos-compat.yml`, and `test-e2e.yml` for the same pattern after the file list is regenerated.

**[MAJOR] CI / docs / schemes update surface is underspecified (codex MAJOR #3, claude MAJOR #3 — partial overlap)**
The plan handwaves "update CI workflows" and "update CLAUDE.md". The actual touch surface is broader: `.github/workflows/ci.yml`, `mailbox-parity.yml`, `ci-macos-compat.yml`, `test-e2e.yml`; the `c11-ci.xcscheme` (today runs `c11Tests` + `c11UITests`; should it include the new pure target?); `docs/DEVELOPMENT.md`; `AGENTS.md`; project `CLAUDE.md`; the operator's global `~/.claude/CLAUDE.md`. The plan also doesn't say what happens to `c11UITests` (separate target, always needs a host — should remain unchanged, but state it).
**Recommendation:** Add an explicit file-by-file update list to the plan covering every workflow, scheme, and doc. Two one-line additions worth committing now: (a) `c11-ci` will include all three test targets so CI coverage doesn't regress; (b) `c11UITests` is out of scope and unchanged.

**[MAJOR] Grep-only classification is insufficient to prove a test is hostless (codex MAJOR #2, related to claude MINOR #6)**
Classification by direct mentions of `AppKit`, `SwiftUI`, `WebKit`, `NSWindow` proves nothing about transitive dependencies. A test with zero hits can still call app types whose source files import AppKit, touch `NSApp`, use `@MainActor`, or depend on app singletons.
**Recommendation:** Add a second-stage classification before pbxproj edits: for each candidate pure test, record the production types/functions it exercises and the source files those symbols live in. Mark files logic-eligible only when those source files link into the chosen no-host target cleanly. Check the artifact into the plan doc or repo so reviewers can see why each file moved. State the recovery default explicitly: if a PURE-classified test pulls NSApp in transitively, first try to put the offending Sources/ file behind a small protocol; if that's invasive, demote the test to the HOST bucket. Never add `import AppKit` to make a pure test compile.

**[MINOR] Target/scheme naming is inconsistent (claude MINOR #4)**
Plan uses `c11-logic-tests`, `c11Tests-Pure`, and `c11-logic` interchangeably. Existing convention: targets are `c11Tests` / `c11UITests` (no dash); schemes are dash-separated (`c11-unit`, `c11-ci`).
**Recommendation:** Lock in `c11LogicTests` (target, matching existing pattern) and `c11-logic` (scheme). Use these consistently from the next plan revision onward.

**[MINOR] Tool choice for pbxproj surgery is hedged (claude MINOR #5)**
"Use the `xcodeproj` Ruby gem or a scripted approach" — these are different stacks. Commit to one and make the operation replayable.
**Recommendation:** Use the `xcodeproj` Ruby gem and check a `scripts/split-c11tests.rb` into the repo so the operation is reversible and re-runnable.

**[MINOR] Acceptance criteria are not fully testable (claude MINOR #6, codex MINOR — full overlap)**
The "<5 seconds" runtime target is optimistic given Mailbox disk I/O across 73 files, and "no app host launches" has no concrete check.
**Recommendation:** Replace with measurable, mechanical checks:
- `xcodebuild -showBuildSettings -scheme c11-logic` shows empty `TEST_HOST` and `BUNDLE_LOADER`.
- A logic test run produces no `c11 DEV.app` process or window (verify via `pgrep` or `ps`).
- Runtime threshold: "test phase completes in under 20s on warm build" (or measure first and set the threshold from data).
- Any pre-existing failing test that lands in the logic target is listed explicitly, or stays in the hosted target until fixed.

**[MINOR] PR #164 precondition is already satisfied (claude MINOR #7)**
PR #164 (`Drop c11mux from active code paths`) is MERGED as of 2026-05-15.
**Recommendation:** Move from Acceptance to a one-line "Preconditions (satisfied)" note.

**[MINOR] CLAUDE.md is quoted inaccurately (claude MINOR #8)**
Plan says "tests must go to CI". Actual `CLAUDE.md:130-133`: "`xcodebuild -scheme c11-unit` is safe (no app launch), but prefer CI" — actively misleading given the PR #164 force-quit incident.
**Recommendation:** Tighten Problem to "CLAUDE.md currently claims `c11-unit` is locally safe; in practice the test host beachballs for ~22s and the operator force-quits it." Reinforces why the CLAUDE.md update in Approach §5 matters.

## 4. Positive Observations

Both reviewers praised:
- **Numbers-first audit grounded in real grep.** The 73 / 28 split was independently verified and matches reality; heavy-hitter call-outs (BrowserPanelTests 163 hits, TerminalAndGhosttyTests 103, etc.) set useful expectations.
- **Concrete operator pain.** The 2026-05-15 PR #164 incident anchors the work in lived experience, not aesthetics.
- **Right architectural choice.** Separating pure-logic from host-required is the higher-leverage move than trying to headless-ify the UI-heavy tests, and the plan explicitly rejects that alternative with reasoning ("20+ window-creation sites, partial benefit only").
- **pbxproj fragility surfaced up front.** Recognizing hand-edits will corrupt the file and pre-committing to a structured tool is the right risk posture.
- **Honest about pre-existing failures.** Calling out the 47 pre-existing failures as out of scope keeps concerns cleanly separated.
- **Risk surface partially named.** Symbol visibility is in the Risks section — needs to be sharpened (see Critical issue), but naming it at all is better than discovering it mid-edit.

## 5. Reviewer Agreement

**Strong agreement:**
- Both reviewers reached FAIL (plan-level), independently.
- Both flagged the hostless linkage decision as the central blocker — claude as MAJOR #1, codex as the CRITICAL issue. Same problem, same recommendation shape (extract `c11Core` or dual-compile sources, spike first).
- Both flagged the CI update surface as underspecified, with overlapping (not identical) lists of files that need touching. Codex named more files explicitly (`ci-macos-compat.yml`, `test-e2e.yml`, `docs/DEVELOPMENT.md`, `AGENTS.md`); claude focused on the `mailbox-parity.yml` `-only-testing` selector breakage specifically.
- Both flagged acceptance criteria as insufficiently mechanical (no concrete check that the app host doesn't launch).

**Partial agreement:**
- Codex went deeper on the audit-method weakness (grep-only classification → need second-stage transitive dependency audit). Claude touched the same nerve at MINOR level (recovery plan for transitive NSApp dependencies). Codex's framing is stronger and should be adopted.

**Where they diverged:**
- Claude raised more low-level cleanup issues (naming consistency, tool choice, PR #164 already merged, CLAUDE.md misquote). Codex did not surface these — likely because they're polish items below codex's reporting threshold, not because codex disagrees. No contradiction.
- Gemini failed and contributes nothing.

**No contradictions between the two reviews.** They are pointing at the same plan with slightly different emphasis; merging is additive, not arbitrative.
