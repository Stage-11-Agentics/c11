# Merged Plan Review — C11-27

## 1. Verdict

**FAIL (plan-level)** — two reviewers independently concluded the plan is high-quality but not yet executable. Both blocked on plan-level contradictions and under-specified execution paths that an implementer would hit on commit 1. A focused revision pass clears it.

## 2. Synthesis

Both reviewers (claude, codex; gemini timed out) rate the plan unusually thorough: locked naming, three-tier strategy with explicit fallbacks, spike-first protocol, mechanical acceptance criteria, per-file CI audit, and a real risk register. The failures are not about ambition or direction; they are about the spike step being unrunnable as written and a cluster of acceptance-semantic drifts that an implementer cannot resolve alone. Two patterns dominate: (a) the spike protocol assumes a clean machine state that does not match the operator's actual workstation, and (b) acceptance criteria (timing, local-test policy, baseline-failure handling) silently relaxed from the ticket without owner approval, so an implementer building to the plan could finish and still miss acceptance. Strategy A — the official fallback — is also under-specified in two independent ways (missing input file, fragile source resolution), which matters because it is the path the plan takes if Strategy B's spike fails.

## 3. Issues

Ordered by severity. Issues flagged by both reviewers are merged and marked **[merged]**.

---

### [MAJOR] §8 — Acceptance timing drift: ticket says <5 s, plan relaxes to ≤12 s, CLAUDE.md draft says ~30 s **[merged]**

Codex (MAJOR) and claude (MINOR) both flag the timing inconsistency, from different angles. Codex's framing is the more serious of the two and should govern: the ticket's `<5 seconds` acceptance is renegotiated to `≤12 seconds` (test phase) inside §8, and a third number — ~30 s wall time — appears in the proposed §5 CLAUDE.md rewrite. An implementer cannot build to three numbers. More importantly, relaxing the ticket's acceptance bar should not happen at PR review; if the spike shows `<5 s` is genuinely infeasible, the ticket owner needs to sign off on the new bar *before* implementation begins.

Claude adds a useful reframe: the operator-visible win here is not raw seconds saved (5 s of wall time is not meaningful), it is the absence of the frozen DEV.app window. The acceptance gate should be primarily *absence-of-app-launch* (verifiable by the same pgrep monitor the spike uses), with a secondary timing target.

**Recommendation:** Resolve before implementation. Pick one of: (a) keep the `<5 seconds` test-phase target and add explicit optimization steps if the spike misses it; (b) get owner-approved wording for a new criterion such as "no app launch during `c11-logic test`; warm test phase ≤ 12 s; total wall time documented separately." Then strike the third number from the §5 CLAUDE.md draft and align the three sections.

---

### [MAJOR] §2.2 / §8 — Spike preflight pgrep gate is unrunnable on the operator's machine

Claude verified on this workstation: the proposed preflight regex `/c11( DEV)?\.app/Contents/MacOS/c11` matches both the operator's daily-driver c11 (PID 26853 at `/Applications/c11.app/...`) and any tagged debug build open in parallel. Since the operator runs c11 all day — and the ticket exists precisely because hosted tests crash that running c11 — the gate trips on every realistic local invocation. The in-loop monitor has the same false-positive problem.

This is the same machine-state assumption flagged by codex from the policy angle below: the spike protocol assumes a quiet workstation it will not get.

**Recommendation:** Scope the pgrep pattern to test-spawned hosts only. Smallest diff is to tighten the regex to `DerivedData/[^ ]+/Build/Products/(Debug|Release)/c11( DEV)?( c11-[a-z0-9-]+)?\.app/Contents/MacOS/c11`, excluding `/Applications/...` and tagged-build paths. More robust alternative: snapshot matching PIDs at preflight and treat *new* PIDs during the test phase as the failure signal. Whichever option lands, demonstrate it does not false-positive on the current `pgrep -fl c11` output before locking in.

---

### [MAJOR] §2.2 / §3 / §8 — Local-test policy exception is required and not granted

The repo's standing policy is "never run tests locally"; CLAUDE.md still claims `c11-unit` is locally safe even though this ticket exists because that claim is false for hosted tests. The plan asks the implementer to run monitored `xcodebuild test -scheme c11-logic` locally during the spike and acceptance gates. That may well be the right validation, but it is also the work product whose safety the spike is *trying to establish*. The implementer should not be quietly asked to violate standing policy to prove the safety of the thing that would lift the policy.

**Recommendation:** Add a "C11-27 local test exception" block before §2.2 that explicitly authorizes only the monitored `c11-logic` spike command, requires the (fixed, see above) preflight pgrep gate, forbids local `c11-unit` / `c11-ci` runs during the spike, and names who runs the spike if it should not be an agent. Update CLAUDE.md as part of the same commit so the policy and the implementation land together.

---

### [MAJOR] §1.5 / §3 — Strategy A is under-specified in two independent ways **[merged]**

Strategy A is the named fallback if Strategy B's spike fails, so it needs to be executable end-to-end without further planning. Both reviewers found gaps:

1. **Missing input file (claude).** §1.5's recipe opens with `awk -F' ' '/^PURE 0 / || /^HOST 1 / {print $3}' /tmp/c11-27-audit.txt`, but `/tmp/c11-27-audit.txt` is referenced nowhere else and has no recipe for generation. The expected shape (`PURE 0 <file>` / `HOST 1 <file>`) matches neither the §1 markdown table nor any checked-in artifact. §1.5 produces `c11-27-deps.txt`, which produces `c11-27-sources.txt`, which `scripts/c11-27-split-tests.rb` requires under `STRATEGY=A`. If §1.5 cannot run, Strategy A cannot run.
2. **Fragile source resolution (codex).** The Strategy A script resolves source refs by basename: `sources_group.recursive_children.find { |c| c.respond_to?(:path) && c.path == leaf }`. Duplicate leaf names anywhere under `Sources/` would silently match the wrong file. Strategy A also does not specify how to attach the package/framework/resource dependencies needed by dual-compiled production sources.

**Recommendation:** (i) Add an explicit "Step 0" recipe that emits `/tmp/c11-27-audit.txt` in the documented shape — a one-liner re-running the §1 classifier grep — and commit that as `scripts/c11-27-audit.sh` so the audit and the markdown table cannot drift. (ii) Make the Strategy A script consume full project-relative source paths and resolve file refs by full path/realpath. (iii) Either spell out the dependency-mirroring step (packages, frameworks, resources) or explicitly declare Strategy A a *stop-and-replan* point if those dependencies are non-trivial, rather than letting the implementer discover that mid-run.

---

### [MAJOR] §3 / §6 / §8 — Baseline failures captured but not reconciled with raw `xcodebuild ... test` CI gates

The plan repeatedly states that pre-existing main failures are out of scope and should be treated as non-regressions, then leaves the CI updates running raw `xcodebuild ... test`. Raw XCTest exits nonzero on failure; a checked-in `c11-27-baseline-failures.txt` does not make CI pass "modulo baseline." If those 47 failures still exist in either bundle, the PR will be red despite the plan declaring them acceptable.

**Recommendation:** Clarify the current state. If main is green, drop the "47 pre-existing failures" path entirely so it does not confuse acceptance. If main is not green, either (a) add an explicit baseline-comparison harness that allows the workflow to pass modulo the recorded list, or (b) state plainly that C11-27 cannot require green CI until the baseline failures are fixed/isolated, and adjust the acceptance criteria accordingly.

---

### [MINOR] §3 — `@testable` block rewrite leaves dangling `#if canImport(...)` if regex misses (claude)

The two `gsub`s strip `@testable import c11(_DEV)?` lines and the surrounding `#if canImport / #elseif / #endif` block separately. The validation gate only checks that no `@testable` lines remain — it doesn't check for orphaned `#if canImport` blocks. A future file that deviates in whitespace, blank lines, or comment placement would pass validation while leaving a `#if canImport(c11_DEV)` wrapping nothing, which is a compile error.

**Recommendation:** Strengthen validation to also flag any `^#if canImport\(c11(_DEV)?\)` left without a following `@testable import` line. Or simpler and structural: after the gsubs, `xcrun -sdk macosx swiftc -parse` each rewritten file before `project.save`. Catches the orphan no matter what shape it takes.

---

### [MINOR] §3 / §6 — Ruby + xcodeproj gem version unpinned; system Ruby 2.6.10 is EOL (claude)

The plan checks `gem list -i xcodeproj` but doesn't pin a version. `/usr/bin/ruby 2.6.10` shipped with macOS, end-of-lifed in March 2022, and won't ship on future macOS versions. A new operator workstation could resolve a different `xcodeproj` major, or have no Ruby at all on macOS 26+.

**Recommendation:** Add `gem 'xcodeproj', '~> 1.27'` (or the resolved version today) at the top of the script. Note in the PR description that the script depends on system Ruby, so it becomes a re-do item when macOS drops Ruby. Not urgent enough to block C11-27.

---

### [MINOR] §4.6.1 — Strategy A's c11-logic scheme drops `<MacroExpansion>` without flagging the asymmetry (claude)

`MacroExpansion` also drives how the scheme resolves `$(SRCROOT)`-style variables in test-target environment expansion. In practice, today's PURE tests don't reference path macros, so it likely doesn't matter — but the asymmetry vs Strategy B isn't documented, and a test that *did* rely on `$(SRCROOT)` would silently behave differently.

**Recommendation:** Either keep `MacroExpansion` pointing at `c11LogicTests` itself under Strategy A (cleanest — scheme stays valid for run/debug), or add a one-line note in §4.6.1 documenting the asymmetry and what to verify in the spike if Strategy A is selected.

---

### [MINOR] §2.3 — BUNDLE_LOADER convention change from indirect to absolute not noted (claude)

Existing `c11Tests` uses `BUNDLE_LOADER = "$(TEST_HOST)"`. The plan's Strategy B sets `TEST_HOST = ""` and `BUNDLE_LOADER` to the explicit absolute path. That's *correct* (the indirect form would resolve to empty), but the divergence from the project's existing convention isn't called out; a reviewer skimming the script might flag it.

**Recommendation:** Add one sentence to §2.3 explaining the divergence and why the explicit form is required when `TEST_HOST` is empty by design. Saves a reviewer the head-scratch.

---

### [MINOR] §3 — Baseline `gh run list` may capture the wrong run (codex)

The recipe triggers `ci.yml` on main, then asks for the latest main run. If another run is queued or completes around the same time, the baseline captured may be the wrong one.

**Recommendation:** Capture the run id from the workflow-dispatch path if possible, or filter by `headSha == origin/main@7e0e0b282` and verify the selected run matches before saving it as the baseline.

---

### [MINOR] §2.4 — PROMOTE wording stale ("7 listed" vs actual 1) (codex)

The plan still reads "For PROMOTE files (the 7 listed in §1)" even though the re-audit reduced §1 to exactly one `VERIFY-PROMOTE` file.

**Recommendation:** Update to "For the VERIFY-PROMOTE file" so the implementer isn't hunting for six files that no longer exist in the list.

## 4. Positive Observations

Both reviewers praised:

- **Naming locked up front** (`c11LogicTests`, `c11-logic`, `com.stage11.c11.logictests`) eliminates churn in pbxproj and CI review that an earlier plan-review pass apparently surfaced.
- **Three-tier strategy decision tree (§2.1)** with explicit B → A → C fallback ordering and a defined Strategy C escalation. Real risk-register thinking.
- **Spike-first protocol (§2.2)** with four representative test files chosen to exercise both easy paths and the actual failure mode (Theme/Workspace transitive AppKit). The file selection is load-bearing — Mailbox+Stdin alone would falsely validate.
- **Per-file CI workflow audit (§4.1–4.6)** with line numbers and the important `mailbox-parity.yml` `-only-testing` migration. Non-test references (`ci-macos-compat.yml`, `test-e2e.yml`) are explicitly verified as leave-alone, not omitted by silence.
- **Mechanical acceptance criteria (§8)** — every bullet is testable by a concrete command, and the two-form pbxproj count check (test-file membership, not test-method count) avoids the obvious double-count trap.
- **Re-audit that demoted 6/7 PROMOTE candidates** with explicit NSColor/AppKit references for each demotion — demonstrates the author actually read the files instead of trusting the first-pass grep.
- **Risk register (§6)** is a real risk register, not a CYA list: each row pairs likelihood × impact × mitigation × fallback, and "was-high, now mitigated" rows show iteration on prior plan-review feedback.

## 5. Reviewer Agreement

Two reviews landed (claude, codex); gemini timed out, so this is a two-vote synthesis rather than three.

**Where they agreed:**
- Both reached **FAIL (plan-level)** independently. Not a close call from either side.
- Both flagged the timing/acceptance drift, though with different severity weighting (codex MAJOR on policy grounds, claude MINOR on consistency grounds). The merged take treats it as MAJOR because the underlying issue — silently relaxing ticket acceptance — is what codex correctly identified.
- Both flagged Strategy A as under-specified, from non-overlapping angles (missing input file vs fragile source resolution + missing dependency handling). The two findings reinforce each other: Strategy A needs work on multiple axes before it is a credible fallback.
- Both praised the same set of plan strengths: locked naming, three-tier strategy with fallback ordering, the file-level re-audit, the per-file CI inventory, and the mechanical acceptance gates.

**Where they diverged:**
- **Spike runnability vs spike policy.** Claude focused on the mechanical defect (the pgrep regex matches the operator's running c11) and verified the false-positive against live process state. Codex focused on the policy gap (local test runs violate standing repo policy and need an explicit exception). Both are real and complementary — the merged review treats them as two separate MAJOR issues because fixing one does not fix the other.
- **Baseline-failure handling.** Codex caught that the recorded 47 baseline failures don't actually reconcile with raw `xcodebuild ... test` exit codes in CI — meaning the PR will be red even if the implementation is correct. Claude did not flag this. It is a substantial gap on its own.
- **Coverage breadth.** Claude went deeper on script-level correctness (the orphan `#if canImport` failure mode, the `BUNDLE_LOADER` convention drift, the `MacroExpansion` asymmetry, Ruby/xcodeproj pinning). Codex went deeper on plan-level acceptance semantics and the staleness of the §2.4 PROMOTE wording. No direct contradictions — the reviews are complementary rather than overlapping.

No issue flagged by one reviewer was contradicted by the other.
