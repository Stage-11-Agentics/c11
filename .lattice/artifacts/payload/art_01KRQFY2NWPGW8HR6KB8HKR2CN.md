# Merged Review — C11-27 (split `c11Tests` into pure-logic vs host-required)

## 1. Verdict

**FAIL (plan-level)** — The plan is substantively strong and close to ready, but two implementation-critical gaps surfaced by codex must be closed before the implementer starts: (a) the Strategy A fallback path does not bulk-rewrite `@testable import` lines across the 70+ moved files, leaving the target in an uncompilable state if Strategy B aborts; and (b) the scheme update instructions specify `TestableReference` entries but not the matching `BuildActionEntry buildForTesting="YES"` entries, risking a target that exists but is not built by `c11-unit` / `c11-ci`. Several MINOR gaps (file/script contract ambiguity, idempotency, acceptance-criterion arithmetic, memory-update mechanics) should also be cleaned up — they are not individually blocking but together represent the kind of friction that wastes the implementation pass.

## 2. Synthesis

Both engaged reviewers (claude, codex) read the plan carefully; gemini failed/timed out and contributes no signal. They converge on a consistent picture: the plan's classification work (PURE/HOST re-audit), three-tier strategy decision tree, spike protocol, risk register, and CI selector updates are unusually strong — well above the typical bar — but the executable artifacts (the Ruby script, the scheme XML mutations, the `/tmp/c11-27-deps.txt` contract, the §8 acceptance gates) have not received the same level of polish. The pattern across both reviews is "great thinking, incomplete mechanics." Codex correctly identifies that the mechanics gaps are sharp enough to block the implementer; claude treats the plan as PASS-with-tightenings but flags overlapping mechanical issues. The merged judgment sides with codex on verdict because the missing import-rewrite step and missing BuildActionEntries are not stylistic — they would either fail the build or silently produce an under-tested CI configuration.

## 3. Issues

**[MAJOR] §2.1 / §3 — Strategy A fallback omits the bulk `@testable import` rewrite** *(codex)*
Strategy A dual-compiles production sources into `c11LogicTests`, so moved tests must drop their `@testable import c11` / `@testable import c11_DEV` blocks. The spike step edits four files, but the bulk Ruby script only mutates target membership and source-file membership; it never rewrites imports across the remaining 70+ moved files. If Strategy B fails and the implementer falls back to A, the target is left in an uncompilable or internally inconsistent state.
**Recommendation:** Add a Strategy A bulk import-rewrite step, preferably inside `scripts/c11-27-split-tests.rb` or a companion script, that strips the conditional `canImport(c11_DEV)` / `canImport(c11)` import block from every PURE file. Add a validation gate: `grep -rn '@testable import c11' <PURE files>` must return empty after the rewrite.

**[MAJOR] §4.5 / §4.6 — Scheme updates specify TestableReferences but not BuildActionEntries** *(codex)*
The plan adds `c11LogicTests` as a `TestableReference` in `c11-unit.xcscheme` and `c11-ci.xcscheme` but never adds the matching `<BuildActionEntry buildForTesting="YES">`. Existing schemes carry both. Without the build-action entry, `xcodebuild build -scheme c11-unit` may not compile the new bundle, and `xcodebuild test` falls back to Xcode's implicit handling rather than an explicit scheme contract — a silent regression vector.
**Recommendation:** For all three schemes (`c11-logic`, `c11-unit`, `c11-ci`), specify exact XML or xcodeproj-API mutations covering BOTH a `BuildActionEntry buildForTesting="YES"` and a `TestableReference` for `c11LogicTests`. Add an acceptance gate: `xcodebuild build -scheme c11-unit -configuration Debug` succeeds AND compiles both test bundles.

**[MAJOR] §1.5 + §3 — `c11-27-deps.txt` format contract is ambiguous** *(claude)*
§1.5's audit script writes triples (`test_file  type  sources_file`) to `/tmp/c11-27-deps.txt`. §3's Ruby script reads `.lattice/plans/c11-27-deps.txt` and expects one Sources/ path per line. The implementer is implicitly responsible for the dedup transformation, but it is never spelled out and the filename is reused for two different shapes — a recipe for a silent parse mismatch.
**Recommendation:** Use two files. `.lattice/plans/c11-27-deps.txt` keeps raw audit triples (reviewer evidence). `.lattice/plans/c11-27-sources.txt` is the de-duplicated path list the Ruby script consumes. Add an explicit derivation step in §1.5 (e.g., `awk '{print $3}' c11-27-deps.txt | sort -u > c11-27-sources.txt`) and point the script's `deps_path` at the sources file.

**[MAJOR] §3 Ruby script — no idempotency / spike-already-applied handling** *(claude)*
The spike commit (step 2) creates `c11LogicTests` for four files; the bulk commit (step 4) re-runs the script for the remaining ~70. `project.new_target(:unit_test_bundle, 'c11LogicTests', ...)` will either create a duplicate target or have xcodeproj reject it. There is no `find_or_create` branch and no "if target exists, just move files" path.
**Recommendation:** Make the script idempotent: `new_target = project.targets.find { |t| t.name == 'c11LogicTests' } || project.new_target(...)`. Apply build settings + scheme creation only on first creation. Alternatively, have the spike commit pass a one-file invocation list and have the bulk commit pass the full PURE list, relying on the move loop's no-op behavior for already-migrated files. Document the chosen workflow in §3.

**[MINOR] §8 — Memory update requirement points outside the project workflow** *(claude + codex)*
The acceptance list requires updating `feedback_no_local_xcodebuild_test.md`, which lives under `~/.claude/projects/.../memory/` — outside the repo's reviewable diff. The plan handwaves this as "or call it out for Atin to update directly" but keeps it as a mechanical acceptance checkbox.
**Recommendation:** Split into (a) a PR-description bullet asking Atin to update the memory file post-merge, plus optionally `.lattice/plans/c11-27-memory-note.md` capturing the exact requested change for reviewability; and (b) remove the item from the mechanical acceptance criteria block since the implementer cannot satisfy it inside the PR.

**[MINOR] §8 — Test-count acceptance criterion confuses files with XCTest cases** *(codex)*
"101 tests" is used to mean 101 test files, but verification is proposed via xcresult test-case counts. XCTest reports test methods, not files, so the gate as written will not verify what is intended.
**Recommendation:** Reword to either count test-bundle file membership from the project file, or count XCTest suites by class name as the proxy. Keep method-count verification separate, since the method total will be much larger than 101.

**[MINOR] §8 vs ticket — acceptance criterion silently relaxes "<5 seconds"** *(claude)*
The ticket says "The new target runs in <5 seconds (no app launch overhead)." §8 rewrites this as "Test phase under 12 s on warm build" and §5 says "around 30 seconds" total. The xcodebuild-overhead rationale is fair, but the ticket-level number was changed without flagging it as a deviation requiring sign-off.
**Recommendation:** Either (a) tighten the test-phase budget to ≤5 s (73 pure tests at ~70 ms each is plausible) and accept xcodebuild overhead as separate, or (b) keep ≤12 s and add a one-line "deviation from ticket: Atin to confirm" so the change is visible at PR review.

**[MINOR] §2.2 spike acceptance gate — `pgrep` pattern + log clobbering** *(claude)*
Two small issues: (1) `pgrep -fl '/c11( DEV)?\.app/Contents/MacOS/c11'` uses ERE `?`. Darwin `pgrep` defaults to ERE so it works, but a comment would prevent a future "fix" to BRE. (2) The `>/tmp/c11-27-spike-launches.log` redirect clobbers the file every 0.25 s, so late launches can be lost if the loop exits immediately after.
**Recommendation:** Use `>>` with a timestamp prefix so the post-mortem log is durable and ordered.

**[MINOR] §2.3 — `TEST_HOST` deletion may not be sufficient if inherited from xcconfig** *(claude)*
The script `delete`s `TEST_HOST`. If a project-level xcconfig ever sets it (not today, but the seam is fragile), the new target re-inherits silently. The acceptance check catches it post-facto.
**Recommendation:** Explicitly set `bc.build_settings['TEST_HOST'] = ''` and the same for `BUNDLE_LOADER` under Strategy A. One-line defensive change.

**[MINOR] §3 step 1 — pinning baseline failures from CI** *(claude)*
"Capture the failing-test list" has no scripted path from a CI run artifact to a file in the worktree.
**Recommendation:** Add a concrete recipe — e.g., `gh run download <run-id> --name <artifact>` if CI uploads xcresult, or `gh run view <run-id> --log | grep 'Test Case.*failed' > .lattice/plans/c11-27-baseline-failures.txt`. Without one, the implementer guesses and the artifact format is not reviewable.

**[MINOR] §5 — "around 30 seconds" wall-time ignores cold-build cost under Strategy B** *(claude)*
Strategy B's `c11LogicTests` depends on `c11`. First `c11-logic test` after a clean checkout pays the multi-minute c11 build, not 30 s.
**Recommendation:** Add one sentence in §5: "First invocation after clean checkout pays the c11 app build cost (multi-minute) under Strategy B; subsequent warm-build runs are ~30 s."

**[MINOR] §2.2 — Strategy A floor of 50 tests is asserted, never derived** *(claude)*
A hard "below 50 → Strategy C escalation" rule with no provenance is a high-cost outcome from an arbitrary number.
**Recommendation:** Either cite the reasoning (e.g., derived from the 72% coverage target with false-positive buffer) or drop the hard floor and let Atin decide at the inflection point — matching how the plan treats other inflection points.

**[MINOR] §3 step 4 — pbxproj diff size expectation is descriptive, not a gate** *(claude)*
"Expected diff size: one new PBXNativeTarget … 73–74 target-membership migrations" reads like a checksum but reviewers have no way to verify it.
**Recommendation:** Don't gate the pbxproj diff line-by-line. Gate on what matters: `xcodebuild -list -project GhosttyTabs.xcodeproj` shows `c11LogicTests`; the diff contains no removed PBXNativeTarget entries; `xcodebuild build -scheme c11-unit -configuration Debug` succeeds. Move the prose to a "what to expect when reviewing" note.

## 4. Positive Observations

- **PURE/HOST re-audit is the strongest move in the plan.** Catching that 6 of 7 PROMOTE candidates inferred NSColor types through grep-invisible API surface (`.red` literal type elision, `NSColor` return types, chained `.usingColorSpace(.sRGB).redComponent`) prevents an opaque mid-bulk link failure. "The compiler is the audit" reads as a principle, not a one-liner. *(claude, codex)*
- **Three-tier strategy decision tree with explicit abort thresholds.** Naming what each strategy costs and where Strategy C escalation kicks in is exactly the shape plans usually fail to take. *(claude, codex)*
- **Spike-first protocol with `pgrep` monitoring during the test phase.** Identifies "did the app launch" as the load-bearing question and answers it by watching the process table during the run — far stronger than after-the-fact log inspection. *(claude)*
- **CI selector updates are concrete and well-scoped.** The `mailbox-parity.yml` migration and the deliberate decision not to double-run `c11-logic` in `ci.yml` show real attention to wall-time and overlap costs. *(codex)*
- **Risk register is exemplary.** Each row carries likelihood, impact, mitigation, and fallback. The "spike falsely passes because c11.app got built first elsewhere" entry shows the author is thinking about how the validation could *lie*, not just how the change could fail. *(claude)*
- **§4.5/§4.6 explicit scheme TestableReference additions** prevent the silent coverage regression that would otherwise drop 73 tests from `c11-ci`. (Caveat: needs the matching BuildActionEntry — see MAJOR above.) *(claude)*
- **§4.1's decision to keep a single `c11-unit test` step rather than splitting into `c11-logic` + `c11-unit`** correctly catches the double-execution that the naive split would produce via TestableReferences. *(claude)*
- **Separable-commits workflow (spike → bulk → schemes → CI/docs)** gives the reviewer a clean reading order and a single-stage revert path. Matches the c11 norm of leaving the trail readable. *(claude)*
- **Scope discipline.** The plan resists drifting into hostless UI-test refactors or a `c11Core` extraction — stays a target split. *(codex)*

## 5. Reviewer Agreement

- **Gemini did not return a usable review** (failed/timed out). The merged verdict and signal-weight derive from claude and codex only.
- **Strong agreement on quality of classification, spike protocol, risk register, and CI updates.** Both reviewers explicitly praise the PURE/HOST re-audit and the spike-first strategy.
- **Strong agreement on the §8 memory-update mechanics being broken.** Both flagged it as MINOR and proposed compatible fixes (PR-description bullet + optional in-repo note file).
- **Disagreement on overall verdict: claude PASS, codex FAIL (plan-level).** The disagreement is grounded in which issues each reviewer treated as MAJOR: codex weighted the Strategy A import-rewrite gap and the missing BuildActionEntries as implementation-blocking; claude did not surface those (likely because claude reasoned about Strategy B as the dominant path and did not press on the fallback mechanics, and read the TestableReference instruction as implicitly carrying its BuildActionEntry). On the merits, codex's two MAJORs are real — both would produce concrete failure modes in the implementation pass — so the merged verdict sides with FAIL (plan-level). Closing those two gaps plus the deps.txt/idempotency MAJORs from claude should be quick and unblock implementation.
- **No outright contradictions** between the two reviews. Their MAJORs are disjoint and additive; their MINORs partially overlap (memory update) and are otherwise complementary. Folding both reviewers' MAJORs into a revised plan is straightforward.
