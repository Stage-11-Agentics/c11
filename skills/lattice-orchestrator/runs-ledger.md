# Runs Ledger — lattice-orchestrator

The run log behind the skill's rules. Each entry preserves the story that shaped (or validated) a rule; the skill itself carries only the timeless statement. New entries accrue at closeout audits; a footgun mitigated three times in one run, or seen across two runs, promotes to a permanent rule in the references with its story recorded here.

## Ralph Prize V1 build (2026-09-29 to 09-30)

39 contract tickets plus seven follow-ups (RP-V1-40 to 46), Sonnet-high builders, an Opus orchestrator, auto-merge on one Forgejo runner on Atlas with a gate of under 30 s wall at load. About 15 hours in, 31 of 39 tickets were merged and checkpoints W0, WA and WB had passed. Times are PT from run-state; entries stamped 02:45 to 04:25 ran about 1.5 h fast.

- **The gate was the largest loss.** Baseline 24.52 s wall and 149.75 CPU-s (ten runs). The per-PR rule changed three times (lenient, then "offset your own cost", then "up to 1.5 s accepted"), none of it enforced by the gate; CPU still climbed from 150 to 184 over eight merges, and a tiny seed PR failed on budget alone (05:21). Re-baselined at 29.62 s / 173.7 (06:19), then climbed again: by 10:00 `main`'s own post-merge runs were red and #219 failed alone on a quiet runner (10:16). Pushes held about 50 minutes until #227 (10:51); a second re-baseline and a blocking per-PR CPU gate followed (#237, 12:24: `main` failed the wall 7 of 10 runs). Rerun cycles of about 10 minutes each hit #191 three times, #216, #219 and #220 twice each, #206 and #224 once. Source of the blocking-growth-check-from-ticket-one contract check.
- **Our own concurrency was the foreign load.** #224 went red at 34.98 s only while it overlapped #223's run (10:59); #232 and #233 were red when three runs overlapped (11:30). Serial CI one PR at a time ended it; once Atin raised the wall limit to 60 s, the window was lifted and runs overlapped again. Source of the conditional CI window clause.
- **Guessed levers, twice wrong.** The Orchestrator bet on more shards (16/20/24: wall flat, 10:32) and then on migration replay; the builder's measurements showed the test-database pool empty 26.8 s of a run, and fewer copy producers (6 to 3) fixed it (10:44). Source of measure-before-hypothesizing.
- **The 5-hour usage window stalled the whole fleet.** One account ran the Orchestrator plus about ten builders: stalled 08:05 to 09:50 (1h45m on every builder and review). The recovery nudged delegators only. V1-21a's implementer had died at about 10:25 and V1-18 sat with ten committed fixes waiting for a CI window it was never given, subtitle unchanged; found at 11:37, about 70 minutes lost on the critical path. Source of nudge-every-surface and the 45-minute subtitle rule.
- **Rebasing pushed branches cascaded.** V1-15a's PR carried V1-06's pre-rebase history and conflicted (06:47); V1-12b carried its own copies of V1-06 commits (07:02); every anchor rebase meant cueing each stacked child. Switching dependents to merging `main` after the anchor landed (07:17, 07:24) ended the restacks. Source of never-rebase-a-pushed-branch.
- **Shared CHECK lists dropped values.** Two migrations recreated the notice-template CHECK and the persona-kind CHECK with partial lists; fresh CI order and the live environment's late-applied lower numbers disagreed, so one side silently lost `panel_invite` or `closeout_warning` (10:01). The per-ticket vigilance rule written at 07:46 did not hold; one canonical list in code plus a daily test that scans migrations did (#223). Replaced functions had the same shape (the assignment insert guard, 03:05). Source of the shared-objects contract check.
- **Two misattributions.** A pair-symmetry failure was blamed on V1-17a's jury code (07:27); a diagnostic captain showed an unawaited top-level sweep in another test file swapping the global service registry when the two files first shared a shard (07:38). A route 500 in #222 was blamed on that harness race; it was an unknown stored value reaching a template key (10:02). Source of reproduce-before-attributing and the Diagnostic Captain.
- **A question left on a builder's own screen** waited 37 minutes (11:53). Source of the questions-to-the-parent clause.
- **Kept, because they worked.** The fresh exact-head landing review caught, before `main`: a concurrent-submit deadlock (07:42), a jury invitation link that broke on retry (07:15), a missing probe that failed to adverse (07:34), the CHECK-list drops (10:01), an unrecoverable G4 gate after a G2 correction (11:32), and raw assignment and participation IDs printed on the demand page's scan acts where SV1-116 allows blind IDs only (#225). That fix itself leaked: a `/g` regex used with `.test()` keeps `lastIndex`, so every other subject still showed its ID; the Orchestrator's delta check on the fix head caught it, and it was fixed with `replace` plus a consecutive-subjects assertion. A fix gets its own check, not only the finding it answers. Planning-only press-ahead kept the critical path planned ahead of its anchors. Landing capacity and the usage window, not builder count, bound the run; Prime Intellect seat boxes were not used and would not have helped the gate.
- **An orphaned test worker** from a merged ticket's worktree ran six hours at 34 to 83% CPU before a tick found it (07:30).

## Marquee eval round 10 (2026-08-14)

- **Parallel build, serial landing:** 18 small PRs landed in 4h15m (median cycle
  9m44s), but late queued reviews repeatedly became obsolete as `main` advanced.
  One final branch's two-dot diff changed meaning after another PR merged; rebasing,
  fresh exact-head review, and a fresh gate caught it before merge. Source of the
  landing-train convention.
- **Launch is not acknowledgement:** a reviewer surface existed but never established
  that it had the intended cwd/head. The run recovered by replacing it, but paid the
  latency and ambiguity. Source of the positive launch receipt.
- **External defects still need durable state:** 22 evaluator defects across six
  areas ended as patches or evidence-backed non-code dispositions without minting
  Lattice tickets. Source of the external-work pilot ledger and generic delivery
  receipts; hold CLI/schema productization until several rounds stabilize the fields.
- **Rendered evidence is its own modality:** an independent reviewer caught a global
  CSS leak that source-local reasoning and the gate missed. Source of the explicit
  `pre-merge-runtime` validation class.

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
