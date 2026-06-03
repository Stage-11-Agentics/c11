Could not write to `/Users/atin/Projects/Stage11/code/c11/.lattice/tmp-prompts/code-review-76uwzdmo/codex/output.md`: sandbox denied it with `Operation not permitted`. Review output follows.

### 1. Verdict

**FAIL (implementation-level)**

### 2. Summary

The target split is mostly sound: `c11LogicTests` owns 74 files, `c11Tests` owns 27, `TEST_HOST` is cleared, and aggregate schemes reference the new bundle. The blocker is CI: the branch pins baseline failures but still runs raw `xcodebuild test`, so the plan’s “no new failures beyond baseline” gate is not implemented.

### 3. Issues

**[MAJOR] .github/workflows/ci.yml:198 — Baseline failures are pinned but ignored by CI**  
The plan says `c11-unit` is already red on main and C11-27 must gate on “no new failures,” not “all tests pass.” This branch adds `.lattice/plans/c11-27-baseline-failures.txt`, but CI still runs raw `xcodebuild ... test` under `set -e`, so any known failure still fails CI and the baseline file is unused.  
**Fix:** Wrap the test step with the planned baseline comparison harness. Capture failing test IDs, normalize/remap `c11Tests` vs `c11LogicTests` prefixes for moved tests, compare against the baseline, and fail only on new failures. Or document the fallback explicitly and add a separate green `c11-logic` gate.

**[MINOR] .lattice/plans/task_01KRQD33HPPS66DHVKANVA8KWJ.md:922 — Required memory-note artifact is missing**  
The acceptance checklist requires `.lattice/plans/c11-27-memory-note.md`, but the diff does not add it.  
**Fix:** Add that file with the proposed memory update, or update the plan if this artifact is no longer required.

**[MINOR] .github/workflows/mailbox-parity.yml:12 — Workflow header still names `c11-unit`**  
The command now correctly uses `c11-logic`, but the top-level workflow comment still says the filtered unit tests run through `c11-unit`.  
**Fix:** Update the header comment to reference `c11-logic` / `c11LogicTests`.

**[MINOR] scripts/c11-27-split-tests.rb:5 — Strategy B summary contradicts Debug loader code**  
The header says Strategy B points at `c11.app/c11 DEV.app`, while Debug actually uses `c11.debug.dylib` with an rpath.  
**Fix:** Update the top comment to match the implemented Debug/Release loader paths.

### 4. Positive Observations

- The test membership split is clean: 74 logic files + 27 host files = 101 total.
- `c11-unit` and `c11-ci` include `c11LogicTests` as both build and test references.
- `mailbox-parity.yml` correctly updates `-only-testing` selectors to `c11LogicTests/...`.
- The Debug `BUNDLE_LOADER` adaptation to `c11.debug.dylib` plus rpath is a good correction for Xcode’s debug dylib layout.
