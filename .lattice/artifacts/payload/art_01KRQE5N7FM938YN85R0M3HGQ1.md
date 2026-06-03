# Plan Review: C11-27 — Split c11Tests into pure vs host-required targets

## 1. Verdict

**FAIL (plan-level)** — The audit is solid and the direction is right, but two concrete decisions need to be locked in before implementation starts: (a) how the new pure target accesses c11 internals without a TEST_HOST (the central architectural question), and (b) the matching CI selector renames in `mailbox-parity.yml`. A second planning pass to nail those down is cheaper than discovering them mid-pbxproj-surgery.

## 2. Summary

Reviewed the plan to split `c11Tests` into pure-logic (`c11-logic-tests`) and host-required halves so 72% of the test surface can run locally without launching a `c11 DEV.app` host. Verified the audit numbers (101 swift files in `c11Tests/`, 28 with UI hits, 73 clean — matches plan) and the project structure (one test target today, `c11Tests`, with `TEST_HOST = c11 DEV.app/Contents/MacOS/c11` set; schemes `c11`, `c11-unit`, `c11-ci`). Plan is well-motivated and well-scoped, but underspecifies the linking model for the new target and misses a concrete CI selector breakage in `mailbox-parity.yml`.

## 3. Issues

**[MAJOR] Approach §1 / Risks — Symbol visibility resolution is undecided, but it determines whether the whole approach works**
The plan lists three options ("`@testable import c11`", "extract a c11Core library", or implicit-via-`BUNDLE_LOADER`) and does not commit to one. This is the load-bearing architectural choice: a "no Host Application" target cannot use the existing `BUNDLE_LOADER = $(TEST_HOST)` setup, and `@testable import c11` against the app module typically still requires the test bundle to link or load that module somehow. The chosen path drives how the pbxproj edit looks, how many source files the new target compiles, and whether a refactor (extract `c11Core` SwiftPM library) is needed in scope. Discovering this at implementation time risks an aborted attempt and a third planning round.
**Recommendation:** Pick a primary path now. Recommended order: (1) try a test bundle that compiles its own copy of the minimal Sources/ files actually referenced by pure tests, no `TEST_HOST`, no `BUNDLE_LOADER` (no `@testable import c11` needed if files are re-compiled in-target); (2) fall back to `@testable import c11` with `BUNDLE_LOADER` pointing at the app but no `TEST_HOST` (links symbols, no GUI launch — verify this combination actually skips app launch); (3) only escalate to `c11Core` library extraction if both fail. Make this an explicit decision tree in the plan with a "spike first" step to verify the chosen path on 2–3 representative pure tests before doing all 73.

**[MAJOR] Approach §4 — `mailbox-parity.yml` uses class-level test selectors that will silently break**
`.github/workflows/mailbox-parity.yml` lines 152–160 invoke `xcodebuild` with `-only-testing:c11Tests/MailboxEnvelopeValidationTests`, `-only-testing:c11Tests/MailboxDispatcherTests`, and seven more. All ten of those class names are in the PURE bucket (Mailbox*, Stdin*), so after the split they'll live in `c11-logic-tests`, not `c11Tests`. The `-only-testing:c11Tests/...` form will then resolve to zero tests and CI will go silently green on an empty test set — a real risk. The plan says "update CI workflows" but doesn't call out this specific rename.
**Recommendation:** Add an explicit step: "Update `mailbox-parity.yml` `-only-testing` selectors from `c11Tests/Mailbox*` and `c11Tests/StdinHandler*` to the new pure-target name." Also audit `ci.yml`, `test-e2e.yml`, and `ci-macos-compat.yml` for the same pattern (only `mailbox-parity.yml` uses `-only-testing` today, but worth re-checking after the file list is regenerated).

**[MAJOR] Approach §3 — c11-ci scheme not addressed; c11UITests not mentioned**
There are three shared schemes: `c11`, `c11-unit`, `c11-ci`. The plan only specifies updates to `c11-unit` and a new `c11-logic`. `c11-ci` currently runs `c11Tests` + `c11UITests`; after the split, should it also run the new pure target? `c11UITests` is a separate target (UI tests, always needs a host) and is unaffected, but the plan doesn't say so.
**Recommendation:** Add to the plan: (a) `c11-ci` will include all three test targets (pure + host + UI) so CI coverage doesn't regress; (b) `c11UITests` is explicitly out of scope and stays as-is. Both are one-line additions that prevent surprise during scheme surgery.

**[MINOR] Approach §1 — Target naming is inconsistent**
Plan uses `c11-logic-tests`, `c11Tests-Pure`, and `c11-logic` (the scheme) interchangeably. Existing convention is dash-separated for schemes (`c11-unit`, `c11-ci`) and the existing test target is `c11Tests`. Pick one and stick to it before edits start.
**Recommendation:** Lock in target name (suggest `c11LogicTests` to match the existing `c11Tests` / `c11UITests` pattern) and scheme name (`c11-logic`). Update the plan to use these consistently.

**[MINOR] Approach §1 — Tool choice is hedged**
"Use the `xcodeproj` Ruby gem or a scripted approach" — these are different stacks. The Ruby gem requires `gem install xcodeproj` (Ruby toolchain); python alternatives (`mod-pbxproj`) require pip; the "scripted approach" is undefined. Picking one matters for reproducibility and for whether agents can re-run the operation later.
**Recommendation:** Commit to `xcodeproj` Ruby gem (mature, well-tested, the de facto standard) and add a tiny script (e.g., `scripts/split-c11tests.rb`) checked into the repo so the operation is reversible/replayable. Optionally re-run the script as a sanity step in CI.

**[MINOR] Acceptance — "<5 seconds" runtime target is optimistic**
The PURE bucket includes all Mailbox tests (which do disk I/O for outbox/dispatch persistence) and Session persistence tests. 73 test files compiling + running, even without app launch, will likely exceed 5s on a cold build. Setting an unachievable acceptance criterion forces awkward post-merge revisions.
**Recommendation:** Relax to "test phase completes in under 20s on warm build, with no `c11 DEV.app` window appearing" or similar — the operator-facing pain is the frozen window, not 5 vs 15 seconds. Or measure first and set the threshold from data.

**[MINOR] Risks §2 — No recovery plan for transitive NSApp dependencies**
"A test classified PURE may still call into Sources/ that brings in NSApp transitively. Discover those by compiling the new target and chasing errors." OK as a discovery method, but what's the move when one shows up — move that test to HOST, refactor the production code, or stub the dependency? Without a default, the implementer will improvise and the resulting test split may be incoherent.
**Recommendation:** State the default: "If a test classified PURE pulls in NSApp transitively, first try to move the offending Sources/ file behind a small protocol so the test can stub it; if that's invasive, demote the test to the HOST bucket. Don't add `import AppKit` to make a pure test compile."

**[MINOR] Acceptance — PR #164 already merged**
"PR #164 merged first to avoid pbxproj conflict" — PR #164 (`Drop c11mux from active code paths`) has state MERGED as of 2026-05-15. This acceptance criterion is already satisfied.
**Recommendation:** Move this from Acceptance to a one-line "Preconditions (satisfied)" note. Cleans up the criteria list and prevents readers from thinking there's still a blocker.

**[MINOR] Problem — CLAUDE.md is quoted inaccurately**
Plan says: "CLAUDE.md's Testing policy says 'tests must go to CI'". Actual text at `CLAUDE.md:130-133`: "**Never run tests locally.** ... `xcodebuild -scheme c11-unit` is safe (no app launch), but prefer CI". This is mildly contradictory — the policy currently *says* it's safe, but the operator's lived experience (force-quits during PR #164 validation) is that it isn't. Worth surfacing in the plan that one outcome is updating CLAUDE.md to remove that "is safe" line, since it's actively misleading.
**Recommendation:** Tighten the Problem statement to say "CLAUDE.md currently claims `c11-unit` is locally safe; in practice the test host beachballs for ~22s and the operator force-quits it" — this also reinforces why the Approach §5 CLAUDE.md update matters.

## 4. Positive Observations

- **Strong, numbers-first audit.** Verified independently: 73 / 28 split using the exact grep set in the plan matches reality. The heavy-hitter call-outs (BrowserPanelTests 163 hits, TerminalAndGhosttyTests 103, …) are useful for setting expectations.
- **Real provenance.** The 2026-05-15 PR #164 incident grounds the work in concrete operator pain rather than aesthetic preference — a useful counterweight when scope creep tempts.
- **Explicit Out of Scope section with reasoning.** Naming the "headless-ify host-required tests" option and rejecting it ("20+ window-creation sites, partial benefit only") prevents a future agent from circling back to it.
- **pbxproj fragility called out up front.** Recognizing that hand-edits will corrupt the project file, and pre-committing to a structured tool, is exactly the kind of risk awareness that prevents lost afternoons.
- **Honest about pre-existing failures.** "47 pre-existing main test failures … won't be fixed by this move" — separating concerns cleanly is the right move.
- **Symbol visibility risk surfaced at all.** Even though it needs to be sharpened (see Major #1), naming it in the risks section is better than discovering it during implementation.
