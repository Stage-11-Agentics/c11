# Plan Review: C11-27 — Split c11Tests into pure-logic vs host-required

## 1. Verdict

**PASS** — with refinements recommended before implementation.

The plan is well-framed, has a real audit behind it, lists serious risks, and is dependency-aware (waits on PR #164). The remaining concerns are mostly clarifications and unspecified surfaces; none of them invalidate the approach. Worth tightening before the delegator picks it up, but not worth a return-trip to `in_planning`.

## 2. Summary

Reviewed a plan to split `c11Tests` into two Xcode targets so pure-logic tests can run without spawning a beachballed `c11 DEV.app` host. The plan is solid in its problem statement, audit, and risk identification; the main gaps are: (1) the `@testable import c11` / "no AppKit dependency" framing is technically muddled in a way the implementer needs clarified, (2) several adjacent surfaces (`c11-ci` scheme, `c11UITests`, multiple CI workflows beyond `ci.yml` + `mailbox-parity.yml`, the c11-unit double-host-launch question) aren't addressed, and (3) the "47 pre-existing failures" acceptance carve-out needs to be quantified per-target so the implementer can't accidentally declare success on a still-broken pure suite.

## 3. Issues

**[MAJOR] Approach §1 — "no AppKit dependency" framing conflates two different things**
The plan says the new target should have "no Host Application, no AppKit dependency." Those are independent properties. The actionable property is *no host app launch*: a unit-test bundle with `Host Application = None` runs under `xctest` directly without spawning a window. But pure tests will still `@testable import c11` (per the Risks section), which pulls in c11's full module — and c11's module includes AppKit-using code. That's fine: AppKit isn't *initialized* unless `NSApplicationMain` runs or a code path actually touches `NSApp`. The thing that matters is "no host app launch," not "no AppKit symbols in the linked binary." Without this clarification the implementer may go chasing the c11Core extraction listed under Out of Scope on the assumption that the bundle target must not link AppKit at all.
**Recommendation:** Reword step 1 to "no Host Application (tests run under `xctest` without launching a window)." Keep `@testable import c11` as the default and let the existing Risk #2 (transitive NSApp paths) handle the genuinely problematic cases.

**[MAJOR] Acceptance — "passes modulo pre-existing failures" needs a per-target baseline**
Acceptance says "`c11-logic` runs and passes (modulo the pre-existing failures that already fail on main)." With 47 pre-existing failures and 73 pure files, it's plausible that some of those 47 live in pure-classified files. The plan should commit to producing a baseline list of *which* of the 47 fall in the pure subset, so when the delegator reports "c11-logic green minus N known failures," the operator can verify N is the right number rather than a swept-under-the-rug regression.
**Recommendation:** Before reclassifying, the delegator runs current `c11-unit` on main, captures the failing test names, intersects with the PURE classifier list, and pins the resulting "expected-failing-on-c11-logic" list into the plan doc. Acceptance becomes "c11-logic green except for the N enumerated tests in that list."

**[MAJOR] Approach §3 — `c11-unit` running both targets sequentially likely doubles host-launch cost**
Today `c11-unit` pays one ~22s host-app launch. After the split, if it runs the pure target *and* the host target, that's two test-bundle runs — possibly two host-app launches, possibly one (Xcode can sometimes pool). The plan says "matches current behavior" but doesn't address this. If CI runtime ends up worse, the "CI time is no worse than today" acceptance fails silently.
**Recommendation:** Decide explicitly: either (a) `c11-unit` keeps only the host target and a new `c11-all` or `c11-ci` scheme aggregates both, or (b) confirm via experiment that Xcode doesn't double-spawn the host. Make the decision part of the plan, not a discovery left to the delegator.

**[MAJOR] `c11-ci` scheme not addressed**
The plan mentions `c11-ci` in the problem statement but only specifies changes to `c11-unit` and a new `c11-logic`. There are three existing schemes (`c11`, `c11-unit`, `c11-ci`) and CI workflows that name them. What runs in `c11-ci` after the split?
**Recommendation:** Add an explicit line item: "c11-ci runs [both targets / host target only / pure target only — pick one] because [reason]."

**[MINOR] `c11UITests` target not addressed**
Repo has a separate `c11UITests/` directory. Plan focuses on `c11Tests/` only. Confirm this is intentional (UI tests stay as-is) so reviewers don't assume it's an omission.
**Recommendation:** Add a one-liner under Out of Scope: "c11UITests target is untouched."

**[MINOR] Approach §4 — CI workflow enumeration is incomplete**
Plan mentions `ci.yml`, `mailbox-parity.yml`, "etc." Actual grep for `c11Tests|c11-unit|c11-ci` in `.github/workflows/` returns four files: `ci.yml`, `test-e2e.yml`, `mailbox-parity.yml`, `ci-macos-compat.yml`. Two of those weren't named.
**Recommendation:** Enumerate the four affected workflows in the plan so the delegator doesn't miss `test-e2e.yml` or `ci-macos-compat.yml`. State what each should run after the split.

**[MINOR] Approach §2 — pbxproj editing tool not chosen**
Plan says "use the `xcodeproj` Ruby gem or a scripted approach. Avoid raw sed." Reasonable guardrail but leaves the implementer to make a tooling decision under time pressure. Other c11 work has used the Ruby gem before; pinning to it would speed things up.
**Recommendation:** Recommend `xcodeproj` Ruby gem explicitly, point at an existing script in the repo if one exists, and require the script to be checked in so the audit/reclassification is repeatable.

**[MINOR] Audit regeneration command unspecified**
Plan says "Full classified file list will be regenerated by the delegator and pinned into the plan doc." The original audit used a specific grep set (`import AppKit`, `import SwiftUI`, `NSWindow`, etc.). For reproducibility the exact classifier script should be specified or checked in.
**Recommendation:** Either inline the classifier script in the plan, or commit it under `scripts/` (e.g., `scripts/classify-tests.sh`) and reference that path. Bonus: the script becomes a guard rail for future test files added to the wrong target.

**[MINOR] Target name not decided**
Plan offers "`c11-logic-tests`" or "`c11Tests-Pure`" interchangeably across sections, and the scheme name "`c11-logic`" implies neither.
**Recommendation:** Pick one. Suggest target = `c11Tests-Pure`, scheme = `c11-logic` — matches the existing `c11Tests` / `c11-unit` asymmetry.

**[MINOR] File count off by two**
Plan states "101 test files in c11Tests/" but `ls c11Tests/` shows 103 entries (minus `Fixtures/` directory gives 102 .swift files). Small but suggests the audit was run before two files landed.
**Recommendation:** Delegator re-runs the classifier on the post-PR-#164 state and pins the actual numbers into the plan.

**[MINOR] CLAUDE.md update scope underspecified**
Plan says "the 'tests must go to CI' rule narrows to 'host-required tests must go to CI.'" The actual Testing policy block has several adjacent claims (no `xcodebuild test` on c11 locally, untagged DEV.app warning, the `CMUX_SOCKET` vs `C11_SOCKET` examples). Some of these were written under the (now-corrected) assumption that local test runs would crash the operator's c11.
**Recommendation:** Plan should explicitly list the CLAUDE.md lines to revise, not just gesture at "update the policy." Include: the operator's-c11-doesn't-crash correction, the new safe-locally one-liner, and a note on what's still off-limits (`c11-unit`, `c11-ci`).

**[MINOR] Memory: `feedback_no_local_xcodebuild_test.md` needs updating in lockstep**
Atin's auto-memory currently says "Don't run xcodebuild test on c11 locally" full-stop. After this work that becomes "don't run host-bearing schemes locally." If CLAUDE.md changes but the memory doesn't, future agents will keep refusing to run `c11-logic` locally.
**Recommendation:** Add a small acceptance line: "Update `feedback_no_local_xcodebuild_test.md` to reflect the new boundary," or treat the memory as derivable from CLAUDE.md and call it out in the AAR.

## 4. Positive Observations

- **Audit-backed framing.** "73 PURE / 28 HOST, classifier counts these specific symbols" is exactly the level of evidence a plan reviewer wants. Whoever did the audit didn't just guess.
- **Provenance corrected on the record.** The original "would crash operator's running c11" framing turned out to be wrong, and the plan calls that out explicitly rather than quietly inheriting it. That's good plan hygiene.
- **Out of Scope is genuinely well-scoped.** The c11Core SwiftPM extraction is explicitly named as the bigger lever and held back. Same with the 47 pre-existing failures and the headless-host alternative. This stops scope creep before it starts.
- **Dependency on PR #164 is named.** Most plans miss this kind of cross-PR pbxproj-conflict risk. Calling it out up front saves a painful merge.
- **Risks include the actual hard one (`@testable import` transitive NSApp).** Most plans would have missed this. Even though the framing around AppKit dependency needs sharpening (see Issue #1), the underlying risk is correctly identified.
- **Acceptance criteria are operationally testable.** "<5 seconds," "no frozen DEV.app window," "CI time no worse" — all measurable, not aspirational.
