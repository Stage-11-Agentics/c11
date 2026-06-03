# Plan Review — C11-27 (split `c11Tests` into pure-logic vs host-required)

## 1. Verdict

**PASS** — Plan is complete, feasible, and aligned. Implementation can proceed.

## 2. Summary

This is a thorough, deterministic plan that has clearly already been through one or more plan-review rounds: it carries forward explicit responses to prior MAJOR/MINOR comments (§1.5 transitive-dep audit, §2.2 spike protocol, §4.5/§4.6 scheme coverage, §8 mechanical acceptance criteria). The PURE/HOST classification is honest about grep being insufficient — the re-audit demoting 6/7 PROMOTE candidates back to HOST is exactly the discipline you want before a 80-file pbxproj move. The remaining issues are minor: a couple of format / idempotency gaps in the executable artifacts, one acceptance criterion that quietly relaxes a ticket-level number, and a small handful of edge cases worth tightening before the implementer starts.

## 3. Issues

**[MAJOR] §1.5 + §3 — `c11-27-deps.txt` format contract is ambiguous**
§1.5's audit script writes triples (`test_file  type  sources_file`) to `/tmp/c11-27-deps.txt`. §3's Ruby script reads `.lattice/plans/c11-27-deps.txt` and expects "one Sources/ path relative to project root" per line. The implementer is implicitly responsible for the dedup transformation, but that step is never spelled out and the file name is reused for two different shapes. Under time pressure this is the kind of gap that produces a script that silently runs against the wrong format and adds nothing, or aborts with a parse error mid-surgery.
**Recommendation:** Use two files. `.lattice/plans/c11-27-deps.txt` keeps the raw audit triples (evidence for the reviewer). `.lattice/plans/c11-27-sources.txt` is the de-duplicated Sources path list the Ruby script consumes. Add an explicit "derive sources.txt from deps.txt" step in §1.5 (one-liner: `awk '{print $3}' c11-27-deps.txt | sort -u > c11-27-sources.txt`) and update the script's `deps_path` to point at the sources file.

**[MAJOR] §3 Ruby script — no idempotency / spike-already-applied handling**
The §3 implementer workflow has the spike commit (step 2) create `c11LogicTests` for the four spike files, and the bulk commit (step 4) re-runs the script for the remaining ~70 files. But `project.new_target(:unit_test_bundle, 'c11LogicTests', ...)` will create a *second* target with the same name, or `xcodeproj` will reject it. Either way the bulk run on top of the spike commit fails or corrupts. There's no `find_or_create` branch and no "if target exists, just move files" path.
**Recommendation:** Make the script idempotent: `new_target = project.targets.find { |t| t.name == 'c11LogicTests' } || project.new_target(...)`. Only apply build-settings + scheme creation if it's a fresh target. Or, alternatively: have the spike commit also create the target via the script (one-file invocation list passed in), and have the bulk commit pass the full PURE list and rely on the move loop's "already in target" no-op. Either way, document the actual workflow in §3 so the implementer doesn't have to reverse-engineer it.

**[MINOR] §8 vs ticket — acceptance criterion silently relaxes "<5 seconds"**
The ticket's `# Acceptance` says "The new target runs in <5 seconds (no app launch overhead)." §8 rewrites this as "Test phase under 12 s on warm build" and §5's CLAUDE.md text says "around 30 seconds" total. The rationale (xcodebuild has ~10–15 s of inherent overhead independent of the test phase) is fair, but the plan changes a ticket-level number from 5 to 12 without flagging it as a deviation that the ticket author should confirm. If the operator's actual ask was "wall-clock fast enough that I'd run it between edits" — which is the practical motivation — 30 s wall time may or may not clear that bar.
**Recommendation:** Either (a) reduce the test-phase budget to ≤5 s to match the ticket literally (73 tests over 5 s is ~70 ms each — plausible for pure logic) and let xcodebuild overhead be a known separate cost, or (b) keep ≤12 s but add a one-line "deviation from ticket: ticket said <5 s; redefined as test-phase rather than wall-clock — Atin to confirm" so the change is visible at PR review.

**[MINOR] §2.2 spike acceptance gate — `pgrep` pattern + log clobbering**
Two small issues with the monitor loop:
1. `pgrep -fl '/c11( DEV)?\.app/Contents/MacOS/c11'` uses ERE-style `?`. macOS `pgrep` (Darwin) defaults to ERE per its man page, so this works — but it's worth a one-line comment in the spike script so a future reader doesn't try to "fix" it to BRE.
2. The `>/tmp/c11-27-spike-launches.log` redirect clobbers the file every 0.25 s. If a launch happens late and the loop exits because `xcodebuild` finishes immediately after, the launch log may be empty when read post-mortem.
**Recommendation:** Append (`>>`) and prefix each line with a timestamp so post-mortem inspection is meaningful. Cheap.

**[MINOR] §2.3 — `TEST_HOST` deletion may not be sufficient if inherited from xcconfig**
The Ruby script does `bc.build_settings.delete('TEST_HOST')`. If a project-level xcconfig sets `TEST_HOST` (it doesn't today — verified, the existing c11Tests sets it per-config in pbxproj on lines 1716/1734 — but this could change), the new target would silently re-inherit. The §8 acceptance check (`-showBuildSettings ... TEST_HOST = `) is the correct gate but only catches it post-facto.
**Recommendation:** Explicitly set `bc.build_settings['TEST_HOST'] = ''` (empty string) instead of just deleting, to override any inheritance. Same for `BUNDLE_LOADER` under Strategy A. Single-line change; defensive.

**[MINOR] §3 step 1 — pinning baseline failures from CI**
Step 1 says "Pin the baseline. Run `c11-unit test` against `origin/main@7e0e0b282` (CI-only)... Capture the failing-test list to `.lattice/plans/c11-27-baseline-failures.txt`. Commit." But the implementer has no scripted path from a CI run artifact to a file in the worktree. Manually copy-pasting from a GitHub Actions log into a text file is fine but worth saying.
**Recommendation:** Add a concrete command: e.g., `gh run download <run-id> --name <artifact>` if CI uploads an xcresult/test-summary artifact, or "scrape from the workflow log via `gh run view <run-id> --log | grep 'Test Case.*failed' > .lattice/plans/c11-27-baseline-failures.txt`." Without a recipe, the implementer guesses and the artifact's format isn't reviewable.

**[MINOR] §8 — `feedback_no_local_xcodebuild_test.md` memory update is outside the PR**
The acceptance criterion says "update `feedback_no_local_xcodebuild_test.md` memory" — that file lives under `~/.claude/projects/-Users-atin-Projects-Stage11-code-c11/memory/`, which is Atin's user-space auto-memory, not the repo. A PR cannot land an edit there. The plan acknowledges this with "or call it out for Atin to update directly" but leaves it as an acceptance checkbox.
**Recommendation:** Split this into (a) a PR-description bullet asking Atin to update the memory file post-merge, and (b) remove it from the acceptance criteria block since it's not something the implementer can satisfy mechanically. Or, gate merge on Atin running `/remember` after reading the PR description — explicit handoff rather than implicit ask.

**[MINOR] §5 — "around 30 seconds" wall-time for `c11-logic` ignores cold-build cost under Strategy B**
Under Strategy B, `c11LogicTests` depends on `c11` (the app target). The first `c11-logic test` run after a clean checkout (or after `xcodebuild clean`) has to build c11 too — that's the multi-minute first-build cost, not 30 s. The "around 30 s" claim only holds on a warm build. Under Strategy A this isn't a concern.
**Recommendation:** In §5, add one sentence: "First invocation after a clean checkout pays the c11 app build cost (multi-minute) under Strategy B; subsequent runs on a warm build are ~30 s." Sets accurate expectations for new contributors.

**[MINOR] §2.2 — Strategy A floor of 50 tests is asserted, never derived**
"Strategy A floor: 50 tests. If after demotions the c11LogicTests file count is below 50, Strategy A is not viable." 50 is a reasonable round number but there's no rationale given. If demotions take the count to 49, the plan demands a Strategy C escalation. That's a high-cost outcome from a number with no provenance.
**Recommendation:** Either (a) cite the reasoning (e.g., "below 50 the operator's local-loop benefit no longer justifies the production refactor cost — derived from the ticket's 72% target coverage figure × buffer for false positives"), or (b) drop the hard floor and let Atin make the call at the spike-result inflection point. The latter matches how the plan otherwise treats inflection points.

**[MINOR] §3 step 4 — pbxproj diff size expectation is approximate, won't gate review**
"Expected diff size: one new PBXNativeTarget, one new PBXSourcesBuildPhase + Frameworks + Resources, two XCBuildConfiguration entries, one XCConfigurationList, 73–74 target-membership migrations." Reviewer reads `git diff` and… how do they know the diff matches this? Without a checksum or line-count threshold, this is descriptive prose, not a gate.
**Recommendation:** Don't try to gate the diff line-by-line — pbxproj diffs are notoriously fiddly. Instead, gate on what matters: (a) `xcodebuild -list -project GhosttyTabs.xcodeproj` shows `c11LogicTests` as a target, (b) `git diff GhosttyTabs.xcodeproj/project.pbxproj` shows no `<<<<<<< HEAD` markers, no removed PBXNativeTarget entries (only additions), and (c) `xcodebuild build -scheme c11-unit -configuration Debug` succeeds. Move the descriptive prose to a "what to expect when reviewing the diff" note.

## 4. Positive Observations

- **The §1 PURE/HOST re-audit is the strongest move in the plan.** Catching that 6 of 7 PROMOTE candidates use NSColor APIs that grep didn't see — including `.red` literal inference through type elision, NSColor return types from `resolveColor`, chained `.usingColorSpace(.sRGB).redComponent` — is the kind of close reading that prevents a Strategy A spike from failing mid-bulk-move with an opaque link error. "The compiler is the audit" landed as a principle, not just a one-liner.
- **§2.1's three-tier strategy decision tree with Strategy C as out-of-scope escalation** is the right shape. Most plans would either commit to one approach prematurely or hand-wave alternatives; this one names what each strategy costs and where the abort thresholds are.
- **§2.2 spike protocol with `pgrep` monitoring during the test phase** correctly identifies that "did the app launch" is the load-bearing question and the only honest way to answer it is to watch the process table during the run. The original plan-review must have flagged this; the response is concrete and runnable.
- **§4.1's decision to keep one `c11-unit test` step rather than splitting into `c11-logic` + `c11-unit` steps** avoids a real subtle bug: under the split, both steps would run the 73 logic tests (once from `c11-logic`, once because `c11-unit` covers both via TestableReferences). The plan caught the double-execution and chose the wall-time-preserving option with explicit reasoning.
- **§4.5/§4.6 explicit scheme TestableReference additions** prevent the silent coverage regression that would otherwise drop 73 tests from `c11-ci` without anyone noticing. Plan-review surfaced it; the response names the exact XML diff.
- **§6 risk register is exemplary** — every row has a likelihood, an impact, a mitigation, and a fallback. The "spike falsely passes because c11.app got built first elsewhere" risk shows the author is thinking about how the validation could lie, not just how the change could fail.
- **§8 acceptance criteria are mechanical and testable** — each is a concrete command or grep, not "make sure it works." This is the standard the plan-review skill is trying to push the team toward.
- **§3's separable-commits workflow (spike, bulk, schemes, CI/docs)** gives the reviewer a sane reading order and a clean revert path if any one stage breaks. Matches the c11 norm of "leave the trail readable."

End of review.
