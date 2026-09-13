# Plan Review: C11-225 (Backport ghostty 14d9e600a: skip renderer updateFrame while occluded)

Reviewer: claude-fable-5-1 (plan review, 2026-09-13)

Note on inputs: the review payload's "Plan" section is a verbatim copy of the task description. The
actual plan is the five-step list at `.lattice/plans/task_01M2DZYEX6HB2VP0VSKSGX8ETE.md`, and steps
1 and 2 are already executed (fork main at `26c3e499e`, c11 PR #444 open). This review covers the
five-step plan and verifies the executed steps against the repo rather than reviewing the description
against itself.

## 1. Verdict

**PASS**

Implementation can proceed. The two major items below are tightening of the validation step
(step 4), not gaps in approach. They should be applied when step 4 runs, and they do not require
returning the ticket to `in_planning`.

## 2. Summary

Reviewed the five-step plan (cherry-pick onto the fork, submodule bump plus fork-doc section,
checksum pin via CI, tagged-build validation with `sample`, merge and ship with C11-224) and the
already-landed steps. The plan is tightly scoped, mechanically correct, and the landed port is
verified byte-identical to upstream: the cherry-pick's post-image blob for `src/renderer/Thread.zig`
is `488642199`, the same blob hash upstream `14d9e600a` produces, so "identical to upstream" is a
fact, not a claim. The key concern is that the visibility-regain check in step 4, as worded, can be
satisfied by a check that cannot detect the one regression this patch could introduce (a stale
first frame on re-show), because `c11 read-screen` reads the terminal model, which this patch does
not touch, rather than the rendered frame.

## 3. Issues

**[MAJOR] Step 4 (validation) — The visibility-regain check must observe the rendered frame, not the terminal model**
This patch's only new failure mode is on the regain path: `renderCallback` now skips `updateFrame`
while `flags.visible == false`, and correctness depends on the new `updateFrame` call inside the
`.visible => true` mailbox arm running before `drawFrame`. If that path were wrong (or if the
embedder ever flipped occlusion without pushing the mailbox message), the terminal model would be
fully current while the Metal layer showed the last frame drawn before the tab was hidden.
`c11 read-screen`, socket `list`/`tree`, and any terminal-state oracle would all pass in that
scenario. The plan says "switching to that workspace shows current content" without saying how that
is observed, which invites a model-side check.
**Recommendation:** Make the check a rendered-frame check with an objective time anchor. In the
background workspace run a one-second clock (`while true; do date '+%T'; sleep 1; done`), switch away
for at least 10 s, switch back, and immediately take a screenshot (`screencapture` or the
c11-computer-use skill). The last visible line must be within about one second of wall clock, with no
visible snap from an older frame. Repeat once with the surface hidden by tab deselection inside a
visible pane (not only by workspace switch), since `panelVisibleInUI` gates both paths. Attach the
screenshot to the ticket as the artifact for this criterion.

**[MAJOR] Step 4 (validation) — Define the oracle for "renderer threads for occluded surfaces" so the sample cannot be misread**
`sample` output does not label threads by surface. The plan needs a stated rule for which threads
count as occluded, or a validator can produce a false pass (looking only at idle threads) or a false
fail (seeing `updateFrame` on a visible-but-unfocused thread and blaming the port). The correct
oracle already exists in the code path: `Thread.setQosClass` drops a renderer thread to `.utility`
only when `flags.visible == false`, so "occluded renderer thread" equals "Ghostty renderer thread at
utility priority" in the sample, and visible-but-unfocused threads sit at `user_initiated` (the
`37T` figure in C11-224).
**Recommendation:** Write step 4 as: (a) sample the tagged build with N background terminals
streaming and one visible pane; (b) for every renderer thread at utility priority, assert zero
frames in `updateFrame` / `rebuildCells` / `rebuildRow` / `addGlyph` (only `drainMailbox` and
`wakeupCallback` frames are acceptable); (c) record the count of renderer threads at
`user_initiated` and compare it to the count of surfaces that are actually on screen. If (c) shows
more `user_initiated` threads than visible surfaces, that is the separate lead from C11-224, not a
port failure: file it as its own ticket and do not block C11-225 on it. Include the C11-224 sample
(pre-fix, 18 of 32 renderer threads in `rebuildRow`/`addGlyph`) as the baseline in the ticket so the
"no longer" claim has a before and an after.

**[MINOR] Step 3 → 4 ordering — The local tagged build depends on the checksum pin or a local xcframework build**
A tagged build for step 4 needs `GhosttyKit.xcframework` for submodule `26c3e499e`. The local build
entry points fetch and verify the cache entry only once `scripts/ghosttykit-checksums.txt` has the
pinned line, which arrives via the `build-ghosttykit` bot commit (run 2, currently in progress). Until
then the build either fails the checksum verify or must compile Ghostty locally with Zig (roughly ten
minutes and a full-core load on this machine).
**Recommendation:** State explicitly that step 4 runs after the checksum commit lands on the branch
(and after approving the `action_required` run 2 per CLAUDE.md). Before building, confirm the
`GhosttyKit.xcframework` symlink points at the `26c3e499e` cache entry, not the previous SHA (a known
staging gotcha). Build through `scripts/reload.sh --tag c11-225` (which takes the machine-wide build
lock) and launch with `scripts/launch-tagged-automation.sh c11-225 --qa fresh` so the startup dialogs
do not stall the validation.

**[MINOR] Ticket description vs. executed method — "port it by hand" is no longer accurate**
The description says `git apply --check` fails so the commit must be ported by hand. The landed
approach was `git cherry-pick -x` with one context conflict resolved in favor of upstream, which is
better (authorship and the `cherry picked from` trailer are preserved, and the result is byte
identical). A future reader of the ticket or the retro will see a mismatch between the description and
the fork doc's "cherry-pick, upstream authorship preserved via -x".
**Recommendation:** Add a one-line ticket comment recording that the cherry-pick path worked with a
single conflict, so the description's "by hand" instruction is understood as superseded. No code
change.

**[MINOR] Step 5 (ship) — Release coupling with C11-224 is stated but not sequenced**
"Ships in the next patch release together with C11-224" couples this ticket to a separate branch
that is still in progress. This ticket also changes the ghostty SHA, so the patch release build
depends on the pinned checksum being on `main` at release time.
**Recommendation:** Merge C11-225 as soon as run 2 is green and step 4 passes; do not hold it for
C11-224. Note in the ticket that the release checklist must confirm the checksum line for
`26c3e499e` is present on the release branch, and that the changelog entry names both tickets under
the load-average diagnosis.

## 4. Positive Observations

- **Verified, not asserted, upstream fidelity.** The cherry-pick and the upstream commit share the
  post-image blob hash for `Thread.zig`. That is the strongest possible evidence for the fork doc's
  "identical to upstream, drops out on rebase" note and removes a whole class of hand-port risk.
- **Provenance handled correctly.** `-x` cherry-pick, original author (Mike Bommarito) preserved,
  submodule commit is an ancestor of `stage11/main` before the pointer bump. This follows the
  submodule-safety rule in the c11 agent notes exactly.
- **Fork doc discipline.** Section 10 is written in the same shape as sections 9 and the merge-conflict
  notes, states the file, the behavior change, the reason c11 wants it, and the rebase drop-out
  condition. The merge-conflict section already references `14d9e600a` for the rebase.
- **The fix has full reach in c11.** `WorkspaceContentView.panelVisibleInUI` returns false for any
  panel in a non-selected workspace and for any non-selected tab inside a visible pane;
  `TerminalPanel.applyVisibility` turns that into `lifecycle.transition(.throttled)`, whose dispatcher
  calls `ghostty_surface_set_occlusion(surface, false)`; `Surface.occlusionCallback` pushes
  `.visible = false` to the renderer mailbox and queues a render. So every hidden agent terminal
  hits the new early return, which is what the load diagnosis needs.
- **Upstream soak.** The commit has been in ghostty-org main since 2026-05-20 and in cmux main since
  its July base, so the dirty-flag accumulation and full-rebuild-on-regain behavior have several
  months of real use behind them.
- **CI state matches the documented pattern.** Run 1 shows `workflow-guard-tests`, `build`, and
  `compat-tests` red with `Build GhosttyKit` still in progress, which is exactly the expected
  checksum-guard red described in the agent notes, and not a compile failure.
- **Scope is honest.** Fork-base bump and the visible-but-unfocused thread lead are explicitly left
  to other tickets. The plan does one thing.
- **Validation is behavioral.** `sample` of the real process plus a visual regain check satisfies the
  repo's test-quality policy without inventing a source-grep test for a Zig one-liner.
