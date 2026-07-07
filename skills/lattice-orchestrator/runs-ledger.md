# Runs Ledger — lattice-orchestrator

The run log behind the skill's rules. Each entry preserves the story that shaped (or validated) a rule; the skill itself carries only the timeless statement. New entries accrue at closeout audits; a footgun mitigated three times in one run, or seen across two runs, promotes to a permanent rule in the references with its story recorded here.

## Overtone V1.1 (2026-05-23)

- **600-second code-review rule:** `lattice code-review` from a worktree hung three times in one run (OVR-51 first cycle, OVR-39, OVR-52). The prior soft guidance ("if it hangs >5–10 min, consider falling back") was treated as soft — every instance polled indefinitely until orchestrator-nudged. Promoted to a hard timeout + immediate own-reviewer fallback.
- **`.env` propagation to worktrees:** every delegator depended on `OVERTONE_HF_TOKEN`; without copy-at-worktree-create, four tickets would have stalled mid-tool-call on a model fetch.
- **PR-queue clearance:** the run sat at 7 PRs queued for ~5 hours awaiting manual merges; under auto-merge it would have closed itself out. Informs the auto-merge opt-in.
- **Plan-validation variant:** OVR-47 arrived with a 210-line pre-existing plan that passed revalidation with no amendments — the do-not-re-plan path validated.

## OVR V1 (2026-05-20)

- **Stacked-squash rebases:** 15 PRs; 14 needed the `git rebase --onto` recipe after the first squash-merge. Budget ~1–2 minutes per PR; birthed the Merge Captain procedure.
- **Run-touched-tests rule:** skipping the targeted suite on a modify/delete conflict shipped 3 broken tests in `tests/job/test_cli_status.py`, caught only in retrospective.

## Substrate wiki run (2026-06-15)

- **Fast-suite economics:** a ~22-minute full suite (embedding model + graph DB spin-up) was paid by all 11 delegators per review cycle; suite latency, not reasoning, dominated the run. Informs the fast/full test-split contract check.
- **Frozen-cost diagnosis:** the "frozen cost + live shell = background-watching, not a stall" distinction prevented every false recovery — it fired ~6 times and each was the live 22-minute suite.
- **Assembled-tree gating:** integration-branch validation (GATE-1) caught an output-truncation bug visible only on the live corpus — invisible to every per-PR review.
- **Ticket the gap:** a Track-B audit found 4 of 5 sketched work-items already shipped; only one was real. Informs the brownfield-reconcile posture.

## Substrate Round 2 (2026-05-21)

- **Write-tool bypass (SB-28):** a planner's relative `Write(.lattice/plans/<uuid>.md)` landed in the worktree's shadow copy; the parent plan file stayed an empty scaffold and plan-review ran on stale content. Recovery: nudge the still-alive planner to re-Write to the absolute path.
- **Monitor path (SB-21):** a watcher missing the `.lattice/` segment silently never fired; the delegator idled 10+ minutes.
- **`--headless` flag drift:** every delegator hit `No such option: --headless` on the newer install; the env var (`LATTICE_SPAWN_BACKEND=headless`) became the durable mechanism.

## Expanded Cinema v1.2.1

- **`LATTICE_ROOT=$PWD` divergent boards:** every Wave-2 delegator wrote to its worktree's shadow `.lattice/`, surfacing as duplicate short IDs and unmapped tickets on the primary board.
- **Press-ahead branch-off-parent:** Wave-2 delegators branched off the in-review foundation branch and inherited its utilities import-stable — the validated case for spawning dependents at review, not merge.
- **Additive-registration conflicts:** `__init__.py` re-exports and registry unions resolved mechanically, ordered by ticket ID — the standing conflict pattern.

## Expanded Cinema v1.1

- **Field Assignments / unowned writer:** `viewing_began_at` was read by PSY-43 and schema-declared by PSY-40, but no ticket wrote it — the badge silently never displayed in production. The writer/reader contract check exists because of this.

## C11-27 (2026-05-16)

- **Backend leak → stray workspaces:** five plan-review iterations spawned ten stray `plan-review-*`/`merge-*` c11 workspaces before the operator caught it; the review CLI also renamed the invoking surface's tab (`review-<random>`). Source of the force-headless rule and the restore-title-after-review habit.

## TT-43 / TT-59 run

- **Shell-loop cadence anti-pattern:** multiple delegators independently rediscovered `sleep`/`watch`/`lattice watch --exec` loops as failure modes (die on compaction, invisible to the harness) — the `/loop`-only cadence rule.
- **Polling-string footgun:** `until lattice review-status | grep "state: done"` returned `status: none` and never matched — a silent stall; the founding entry of the run-time footgun catalog.

## Holodeck v1 (HOLO-54, HOLO-57)

- **Inline-full mode validated:** single-session delegators with headless reviews carried medium tickets end-to-end without sub-agent PTY pressure — the basis for inline-full as the default mode.

## Truth & Stability cycle (C11-159..165, 2026-07-07)

- **Seven tickets, ~5h50m fully autonomous overnight, zero parked, zero captains, GREEN audit (32/6/0/0).** Wave barrier + press-ahead planning-only variant meant the 4-ticket Wave 2 lost zero wall-clock to the DX keystone merge.
- **The stray-commit save:** the DX delegator over-generalized the "absolute parent path for .lattice writes" rule to source files and committed extraction work onto the parent checkout's local main. The Master Validator's git-truth audit caught it within two 5-minute ticks — before any push. Recovery: freeze → cherry-pick to branch → per-file restore + reset --soft (never --hard; live .lattice). MV's ROI for the whole run was justified by this one catch.
- **Locked-screen wall for overnight visual proofs:** a 6am autonomous run cannot capture screenshots — the display sleeps, and `caffeinate -u` wakes only the lock screen (verified: screencapture returns byte-identical black frames; CGSSessionScreenIsLocked=True also blocks GUI workspace materialization, which cost RES-3 its second harness run). Overnight contracts should pre-declare the fallback: code-path proof + repro script pre-merge, visuals to operator smoke.
- **`lattice code-review` empty-diff bug hit 3/3 worktree delegators** (resolves parent checkout, not worktree — filed as LAT-250); the own-reviewer fallback carried all three cleanly, including one that found and fixed a MAJOR.
- **A delegator self-caught a CI blind spot:** dependabot eslint-10 bump was green in CI (which runs no eslint), delegator ran `bun run lint` anyway, found the fatal break, reverted its own merge with reason, and filed the machine memory.
- **Boot-burst 429s:** four simultaneous Opus spawns rate-limited every session and killed one boot turn outright. Stagger fleet spawns 10–15s.
