# Merged Plan Review: C11-27 — Split `c11Tests` into pure-logic vs host-required

*(Synthesized from two independent reviewers — claude and codex. Gemini failed/timed out and is not represented.)*

## 1. Verdict

**FAIL (plan-level)** — the plan is high quality and close to ready, but it ships with at least three implementation-blocking defects that would make the spike fail for the wrong reason, leave the key acceptance gate falsely green, and break at compile time on one of the seven PROMOTE files. None of these require a structural rethink; they require ~30 minutes of plan edits before the implementer's first commit. Once those are corrected, the plan should clear cleanly.

## 2. Synthesis

Both reviewers agree the plan is unusually thorough: spike-first protocol with a concrete go/no-go gate, per-file classification table, verbatim CLAUDE.md rewrite, exact YAML for CI, and a real risk register with mitigations rather than acknowledgments. They also converge on the same shape of problem — the parts of the plan that decide "did we actually achieve hostlessness" are weaker than the parts that decide "how do we move files." Specifically, the spike's `BUNDLE_LOADER` path is wrong for Debug builds (so Strategy B would link-fail before its real question gets tested), the `pgrep` acceptance check is broken in two independent ways (pattern too narrow + not monitored during the test phase), and the audit methodology that drove the per-file classification cannot see AppKit usage that flows through return-type chaining — already producing one demonstrably wrong PROMOTE. The reviewers disagree on the overall verdict (claude: PASS with required corrections; codex: FAIL plan-level), but agree on the substantive fixes needed. Codex caught a CI-loop weakening that claude missed; claude caught a file-classification error and an audit-methodology limitation that codex did not surface.

## 3. Issues

### [CRITICAL] §2.3 / §2.2 — Strategy B's `BUNDLE_LOADER` path points at the wrong Debug product
*(codex; corroborated by claude in §2.2 minor)*
Strategy B currently sets `BUNDLE_LOADER = "$(BUILT_PRODUCTS_DIR)/c11.app/Contents/MacOS/c11"` for both configurations, but the Debug build produces `c11 DEV.app` (`PRODUCT_NAME = "c11 DEV"`). The existing `c11Tests` target already uses the configuration-specific pair (`c11 DEV.app` for Debug, `c11.app` for Release). The spike runs `-configuration Debug`, so Strategy B will fail at link/load time before it has a chance to test the actual question — "does `BUNDLE_LOADER` resolve without launching the app?" The spike's "no" answer would then be a false negative, pushing the plan into Strategy A for the wrong reason.
**Fix:** make `BUNDLE_LOADER` configuration-specific (Debug → `c11 DEV.app/...`, Release → `c11.app/...`), and update the §2.2 expected-output snippet to match.

### [MAJOR] §8 / §2.2 — The `pgrep` acceptance check is broken in two independent ways
*(codex + claude, complementary findings)*
The plan gates Strategy B success on `pgrep -fl 'c11 DEV.app'` returning empty during the test run. Both reviewers found this insufficient, for different reasons:
- **Codex:** the proposed command (`pgrep ... & ; xcodebuild ...`) backgrounds a single `pgrep` invocation *before* `xcodebuild` starts. It can return empty even if `c11 DEV.app` launches moments later during the test phase. The check is not actually monitoring the window it claims to monitor.
- **Claude:** the pattern only matches `c11 DEV.app`. If something silently launches the release `c11.app` binary (possible given how the project produces both), the check returns empty — false green — and the failure mode surfaces later for the operator.
Both flaws compound: the check runs at the wrong time *and* watches the wrong set of names.
**Fix:** preflight (`pgrep` must already be empty), then launch `xcodebuild` in the background and loop with `pgrep -fl '/c11(\.app| DEV\.app)/Contents/MacOS/c11'` (or equivalent broader pattern), failing immediately on any hit. Alternative: use `lsof` against the xctest PID to confirm no `c11*.app` binary is loaded. Reflect the broader check in §8's acceptance criteria.

### [MAJOR] §1 — `FlashColorParsingTests` PROMOTE classification is verifiably wrong, and the §1.5 audit methodology can't catch this class of error
*(claude)*
The plan classifies `FlashColorParsingTests` as PROMOTE with the note "body uses no AppKit symbol." Direct read of `c11Tests/FlashColorParsingTests.swift:14–77` shows the test body calls `color.usingColorSpace(.sRGB)` and reads `srgb.redComponent / greenComponent / blueComponent / alphaComponent` across 7+ test functions — those are NSColor APIs with no `CGColor` equivalent. `FlashAppearance.parseHex(...)` returns `NSColor?`. Dropping `import AppKit` here will fail to compile.

The deeper signal: §1.5's audit script greps test files for `[A-Z][A-Za-z0-9_]+` identifiers and traces declarations into `Sources/`. That methodology fundamentally cannot see AppKit usage chained off a c11-typed return value (`FlashAppearance.parseHex(...).usingColorSpace(...)` — the NSColor methods are never named explicitly). The audit will keep producing false PROMOTEs in exactly the test clusters with the heaviest AppKit pressure (Theme).
**Fix:** demote `FlashColorParsingTests` from PROMOTE → HOST in §1 before implementation starts. Drop the pretense that grep proves hostlessness — make the compiler the audit. Bulk-move under the chosen strategy, then `xcodebuild build -scheme c11-logic`; files that fail compilation revert to HOST. If a checked-in dependency artifact is needed for PR review, derive it from `swiftc -dump-ast` or `xcodebuild -showBuildSettings` module dependencies, not PascalCase regex.

### [MAJOR] §2.2 — Spike candidates don't exercise the failure mode the spike is meant to detect
*(claude)*
Spike candidates are `MailboxIOTests` and `StdinHandlerFormattingTests` — both genuinely AppKit-free subsystems. A green spike here proves Strategy B works *for files that have no AppKit pressure at all*; it does not prove Strategy B works for the Theme/Workspace clusters where transitive AppKit pull is the real concern. The spike will green-light bulk roll-out, then bulk roll-out will surface AppKit-via-return-type problems one file at a time.
**Fix:** add one Theme-cluster spike candidate (e.g., `ThemeRegistryTests`) plus one PROMOTE candidate from a high-pressure subsystem (e.g., `ThemeResolvedSnapshotArtifactTests`). If both pass after dropping `import AppKit`, bulk-move confidence rises. If they fail like `FlashColorParsingTests` would, the implementer learns at spike time, not bulk-move time.

### [MAJOR] §4.1 / §8 — CI plan double-runs the logic suite and quietly relaxes the "no worse than today" wall-time criterion
*(codex)*
The plan says `c11-unit` covers both `c11Tests` and `c11LogicTests` in one invocation, but §4.1 also adds a separate `c11-logic test` step *before* the `c11-unit test` step. CI then runs the logic suite twice. The ticket's acceptance bar is "no worse than today"; §8 relaxes it to "today's CI wall time + 30 s." The "host-required" CI step name is also misleading because `c11-unit` still runs both targets.
**Fix:** pick one explicit shape and make §8 match it. Either (a) run only `c11-unit` in the main job after wiring both TestableReferences (mailbox-parity uses `c11-logic`), or (b) introduce a `c11-host` scheme so `c11-logic` + host can be sequenced without duplication. Keep the wall-time criterion at "no worse than today" unless the ticket owner explicitly grants a regression budget.

### [MAJOR] §2.1 — Strategy A scope risk is under-quantified
*(claude)*
The plan acknowledges Strategy A may force PURE→HOST demotions when a source file transitively imports AppKit, but does not define a threshold for when Strategy A stops being worth doing. If `Sources/Theme/*.swift` imports AppKit (likely given NSColor usage), every Theme test touching a Theme type demotes; combined with Workspace tests against SwiftUI-importing sources, Strategy A could end up moving only the ~25 self-contained tests (Mailbox, parsers, CLI runtime) and leaving the rest in HOST — far short of the "80 logic tests" framing.
**Fix:** before locking in Strategy A from a spike pass, require a full dependency check (compile the entire candidate set under Strategy A; count successful inclusions). If the post-demotion count is below a stated floor (claude suggested 50), escalate to Strategy B even if Strategy A's spike technically passed. Add the floor to §8.

### [MINOR] §3 step 7 / §2.2 — `c11-logic` scheme creation is sequenced after the spike that depends on it; scheme contents are underspecified per strategy
*(claude + codex, related)*
Two adjacent problems with the same scheme:
- **Claude:** the spike at step 4 invokes `xcodebuild build -scheme c11-logic`, but the scheme is not created until step 7. Either fold scheme creation into the spike commit or run the spike against `-target c11LogicTests` instead.
- **Codex:** the scheme template is described as "copy `c11-unit.xcscheme`, swap the BuildableReference, strip the old TestableReference." That leaves the app BuildAction and MacroExpansion ambiguous — Strategy B needs the app target built (to produce the loader binary); Strategy A doesn't, and building the app erodes the "logic-only" feedback loop.
**Fix:** make scheme creation part of the spike commit. Under Strategy B, `c11-logic` builds `c11` + `c11LogicTests`. Under Strategy A, `c11-logic` builds only `c11LogicTests` and drops the app MacroExpansion unless Xcode requires it for a stated reason.

### [MINOR] §4.x / §5 — Wall-time projection conflates test phase with total invocation
*(claude)*
"~5–10 s" is test-phase time only; `xcodebuild` itself has ~10–15 s of inherent overhead even on a warm cache. Total wall time on the first warm run will land closer to 20–25 s. The CLAUDE.md text says "under 20 seconds," which sets the operator up to feel cheated.
**Fix:** soften §5 to "around 30 seconds, dominated by xcodebuild overhead rather than test execution."

### [MINOR] §3 — Ruby script's `STRATEGY_A_SOURCES` is a stub that will silently produce a partial target
*(claude)*
The script ships with `STRATEGY_A_SOURCES = %w[ Sources/Mailbox/MailboxEnvelope.swift ... # ... regenerated from the §1.5 audit ]`. An implementer who runs `STRATEGY=A ruby scripts/c11-27-split-tests.rb` without first regenerating the list creates a Mailbox-only target — confusing partial result, hard to detect.
**Fix:** have the script `abort` when `ENV['STRATEGY'] == 'A'` and `.lattice/plans/c11-27-deps.txt` is missing or empty. Read `STRATEGY_A_SOURCES` from that file. Single source of truth, no stale-stub trap.

### [MINOR] §6 — Risk register missing a "PROMOTE classification error" row
*(claude)*
Given the FlashColor finding, this is now a known risk class, not a hypothetical. The register lists "PURE-classified file pulls AppKit transitively" but not "PROMOTE-classified file's body uses an AppKit type the grep missed."
**Fix:** add a row stating likelihood Medium (1/7 confirmed), impact Low (caught at step 3 build), mitigation: implementer demotes file in the script before re-running.

### [MINOR] §1 — Table rows (93) don't match the file count (101)
*(claude)*
73 + 7 + 21 = 101, but the §1 table has 93 visible rows; 8 files are unaccounted for. They may be test helpers / base classes (no `XCTestCase` subclass), but the plan doesn't say so, and the implementer can't tell whether those files need target-membership changes.
**Fix:** either include the missing 8 rows (with a "TEST HELPER" verdict) or add a paragraph naming the omissions and why they don't need classification.

### [MINOR] §4.3 / §4.4 — "Leave unchanged" verdict should be verified, not asserted
*(claude)*
The plan dismisses `ci-macos-compat.yml` and `test-e2e.yml` because the relevant line is `-resolvePackageDependencies`. True, but if either workflow elsewhere references `c11-ci` (which gains `c11LogicTests` as a TestableReference in §4.5), the new target will start running there too — possibly desirable, possibly not.
**Fix:** add `grep -nE 'c11-(ci|unit|logic)|c11Tests|c11LogicTests' .github/workflows/ci-macos-compat.yml .github/workflows/test-e2e.yml` to the §4.3/§4.4 verification. If only `-resolvePackageDependencies` matches, the verdict holds. Otherwise evaluate explicitly.

## 4. Positive Observations

Both reviewers praised the plan's overall shape. The recurring notes:

- **Spike-first protocol with a concrete go/no-go gate** rather than "we'll figure out linkage during implementation." Strategy B is cheap to try, falls back to Strategy A cleanly, and Strategy C is explicitly out of scope.
- **Verbatim CLAUDE.md rewrite (§5)** instead of a description of the edit. The new text correctly identifies and replaces the false "safe (no app launch)" policy line.
- **Per-file CI workflow diffs (§4.1–4.6) with exact YAML.** The mailbox-parity selector update (§4.2) preempts a silent-pass mode where the 10 `-only-testing:c11Tests/X` selectors would match zero tests post-split and CI would go green over nothing.
- **`c11-ci` coverage regression caught (§4.5).** Without this, the dedicated CI scheme would silently drop 80 tests.
- **MOVE-don't-duplicate policy (§2.4)** avoids the double-execution-of-mutable-state class of bug, with the decision locked rather than deferred.
- **Risk register (§6) is mitigation-oriented** — each row names a specific countermeasure rather than just acknowledging the risk exists. The retired PR #164 conflict risk is correctly tracked as "was-medium, now mitigated."
- **Commit-the-Ruby-script for the pbxproj mutation.** Makes a fragile Xcode change reproducible and reviewable.
- **Acceptance criteria are mechanical** — `TEST_HOST` empty per `-showBuildSettings`, `pgrep` during the run, test phase under 20 s. Real measurements vs. the ticket's looser "<5 seconds" / "no frozen DEV.app window."

## 5. Reviewer Agreement

**Strong agreement:**
- Plan quality is unusually high; the structural approach is sound.
- The spike's `BUNDLE_LOADER` / `pgrep` machinery — i.e., the gate that decides whether Strategy B counts as having worked — is the weakest part. Both reviewers independently flagged it; the issues compound (codex's "wrong time" + claude's "wrong pattern").
- The pbxproj-mutation script and CI YAML diffs are exactly the level of detail this kind of work needs.

**Complementary, not contradictory:**
- Claude focused on classification correctness and audit methodology (`FlashColorParsingTests` PROMOTE error, transitive-AppKit-via-return-types limitation, Strategy A under-quantification, spike candidates that don't exercise the failure mode).
- Codex focused on build-system specifics (Debug vs. Release product name in `BUNDLE_LOADER`) and CI semantics (double-execution + relaxed wall-time bar).
- Neither reviewer's findings contradict the other; together they cover both the "is the classification accurate?" and "is the build/CI plan internally consistent?" surfaces.

**Notable disagreement:**
- **Verdict label.** Claude wrote PASS with required corrections; codex wrote FAIL (plan-level). This merger sides with codex's FAIL (plan-level): the BUNDLE_LOADER path is a true blocker (the spike would fail for the wrong reason and pull the plan onto Strategy A by mistake), and the PROMOTE classification error means at least one file is guaranteed to break the implementer's first compile. These are correctable in ~30 minutes of plan editing, but they should be corrected *before* implementation starts rather than caught at step 3 of the workflow. The substantive recommendation in both reviews is the same; only the label differs.

**Issues only one reviewer caught:**
- The CI double-run + wall-time relaxation (§4.1 / §8) was codex-only.
- The PROMOTE classification error, the §1.5 grep-methodology limitation, the spike-candidate selection critique, and the Strategy A scope risk were claude-only.

Both gaps are real; both are addressed in this merged review.
