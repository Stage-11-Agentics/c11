# Plan Review: C11-224 — TTY-only PID resolution in SurfaceMetricsSampler

Reviewer: Claude (Fable 5.1), 2026-09-13.
Reviewed against the on-disk plan `.lattice/plans/task_01M2DZB167H5PKY3WSKR1R7RK7.md`, which carries a "Plan (delegator, 2026-09-13)" section with four steps. The copy embedded in the review prompt stops at the task description and omits that section; the review below covers the full on-disk plan.

## 1. Verdict

**PASS** — the approach is correct, minimal, and verified feasible. Two major additions (a deterministic test and a runtime validation gate) must be folded in during implementation; neither changes the design.

## 2. Summary

The plan replaces `proc_listpids(PROC_ALL_PIDS)` plus a `proc_pidinfo` call per process with a single `proc_listpids(PROC_TTY_ONLY, dev)` per terminal, keeping highest-pid-wins semantics and the 2s cadence. I confirmed `PROC_TTY_ONLY` (value 3) exists in the macOS SDK's `sys/proc_info.h`, that the kernel filters on the same session controlling-tty device that populates `pbi_tdev`/`e_tdev`, and that c11 never holds the pty master (Ghostty owns it), so the ticket's `tcgetpgrp` alternative is not available and the plan's choice is the right one. The key concern is that the plan's only new test is environment-dependent and likely a no-op in CI, and the plan has no step that observes the load reduction the ticket exists to fix.

## 3. Issues

**[MAJOR] Plan step 3 — Proposed test is likely a no-op in CI and the existing tests cannot catch a broken filter**
The new case resolves "this process's own tty via `ttyname(STDIN)` when present." `SurfaceLifecycleTests.swift` is a member of the host-required `c11Tests` target; the xctest host (c11 DEV.app under xcodebuild) has no controlling tty on CI runners, so the guard will skip and the test asserts nothing. The two existing cases also cannot detect a regression: `testTerminalPIDResolverHandlesRealTTYPath` accepts `nil`, and `testTerminalPIDResolverReturnsNilForUnknownTTY` only exercises the `stat` failure path. A `PROC_TTY_ONLY` call that returned zero pids for every tty (wrong `typeinfo` width, wrong argument order) would sail through CI green, and the sidebar would silently lose terminal CPU/MEM attribution.
**Recommendation:** Add a deterministic test that manufactures the condition: `openpty()` a pair, `posix_spawn` `/bin/sleep 30` with `POSIX_SPAWN_SETSID` and a file action that `open()`s the slave path for fd 0/1/2 (first tty open by a new session leader acquires it as controlling tty), then assert `foregroundPID(forTTYName: slaveName) == childPid`; kill the child in teardown. Keep a second assertion that the resolver returns `nil` for the slave path after the child exits. This runs without a runner-side controlling tty and satisfies the repo test policy (observable runtime behavior, not source shape).

**[MAJOR] Plan step 4 — No runtime validation of the load fix, and no acceptance criteria stated**
The ticket is a performance fix diagnosed with `/usr/bin/sample`; the plan ends at "watch CI, attach PR URL." CI proves the code compiles and the unit tests pass, not that the surface-metrics thread stops spending its time in `__proc_info` or that the sidebar still shows terminal CPU/MEM. Per the repo rule "Validate what you ship," the escape-forward expectation for delegators, and the no-local-xcodebuild memory, the build itself may need to come from CI artifacts, the operator, or a build-lock-guarded tagged build; the validation step still has to exist.
**Recommendation:** Add explicit acceptance criteria and a validation step: (a) on a tagged build with the `terminalPidRefreshSeconds` override absent (default 2s), `sample` the c11 process for 10s and confirm the `com.stage11.c11.surface-metrics` thread shows no `proc_pidinfo` frames and at most O(terminals) `proc_listpids` frames; (b) run `yes > /dev/null` in one terminal surface and confirm that surface's sidebar CPU figure rises and the idle surfaces' figures do not; (c) confirm resolver returns `nil` for a surface whose shell has exited. Record the sample excerpt on the ticket.

**[MINOR] Plan (missing step) — Live mitigation on Hyperion is not scheduled for revert**
The ticket records that Hyperion currently runs `c11.surfaceMetrics.terminalPidRefreshSeconds = 60` as a live mitigation. Once the fix ships, that override keeps the operator's sidebar attribution 30x staler than intended, with no signal that anything is wrong.
**Recommendation:** Add a closing step: after the fix is validated on the operator's build, run `defaults delete com.stage11.c11 c11.surfaceMetrics.terminalPidRefreshSeconds` and note it in the ticket's completion comment. Mention it in the release notes for the next patch so other operators who copied the workaround know to remove it.

**[MINOR] Plan step 2 — Sizing call semantics for `PROC_TTY_ONLY` and stale comments**
`proc_listpids` with a `nil` buffer returns a size derived from the total process count plus slack, not the filtered count, so the current allocate-then-fill pattern will still allocate ~nprocs pids per terminal per refresh (about 5 KB at 1160 processes; harmless, but not the "one syscall" the ticket describes). The comments in `SurfaceMetricsSampler.swift` around line 238 ("proc_listpids walks every process") and the `TerminalPIDResolver` header doc will be wrong after the change.
**Recommendation:** Either keep the two-call pattern and note that the count comes from `written / stride`, or use a fixed stack buffer (a tty rarely has more than a few dozen processes) and fall back to the sizing path only on overflow. Update the header doc and the sampler comment in the same commit so the next reader does not re-derive the old cost model.

**[MINOR] Review inputs — Prompt pack plan copy is stale**
The plan text in the review prompt lacks the delegator's four-step section present on disk. If the pack was generated before the plan was appended, later reviewers in this cycle may be reviewing only the task description.
**Recommendation:** Regenerate the review pack from the current plan file, or have reviewers read `.lattice/plans/<task>.md` directly.

## 4. Positive Observations

- **Right fix, smallest footprint.** One function body changes; call sites, cadence, the `UserDefaults` override, and the highest-pid-wins contract all stay put. The plan explicitly declines to touch the cadence or the two related renderer leads, which C11-225 already owns.
- **Feasibility is real, not assumed.** `PROC_TTY_ONLY` is in the SDK, filters on the same session tty device the old code compared against, and drops the per-pid lock acquisition that was contending with every fork/exec on the box. The choice of highest-pid over `tcgetpgrp` is correct given c11 has no handle on the pty master.
- **Respects the repo's operating constraints.** Worktree from `origin/main` (already present at `c11-worktrees/c11-224-tty-only-pid` on the v0.66.0 bump), no local xcodebuild, CI as the gate, and a named report-back surface.
- **Cleans up as it goes.** Dropping the stale `e_tdev` sign note is the kind of small doc hygiene that keeps the resolver honest.
