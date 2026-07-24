---
name: lattice-orchestrator
version: 2
description: Stage 4 of the Tone workflow and Stage 11's build engine — takes a complete build contract (SPEC.md, EVALUATION.md, BUILDPLAN.md, and where one exists a binding prototype + DESIGN.md), turns it into Lattice tickets, dispatches a delegator fleet that produces open PRs, and terminally audits the result against a spec its builders did not write. No planning interview — if contract artifacts are missing, run the Tone stage that produces them (tone-architect for spec/plan, tone-initiation for a raw idea). Invoke when the operator says "orchestrate this," "kick off the orchestration," "run the orchestrator," "set up an overnight run," or hands over a finished build contract.
---

# Lattice Orchestrator

The build stage of **Tone** (tone-initiation → tone-prototype → tone-architect → **lattice-orchestrator**), and equally invocable standalone on any complete build contract. Named for its substrate deliberately: this skill orchestrates builds *on Lattice*; a different build substrate would be a different skill.

It does not plan. The contract arrives written — by `tone-architect` or by hand — and this skill's job is execution with integrity: **tickets → dispatch → terminal audit**, where the audit judges the build against a spec its builders did not write. Separation of duties is the design, not an accident.

Three seats, context-isolated: the **Orchestrator** (Phases 0–1 — intake, ticketing, dispatch; it delegates, it does not implement), the **Result Validator** (Phase 2 — fresh session, terminal audit), and the supporting cast: **delegators** (one per ticket, driving plan → impl → review → validate → PR), **captains** (one-shot cross-cutting recovery), and the **Master Validator** singleton (optional in-flight global audit).

Assumes c11 (load the c11 skill; the `lattice` skill owns Lattice CLI footguns beyond orchestration). Outside c11 the run still works — delegators need any harness that can spawn parallel sub-sessions; surfaces degrade to what the harness offers.

## Contract

- **Inputs:** `SPEC.md` (numbered acceptance criteria with stable IDs), `EVALUATION.md` (criteria tagged `autonomous` / `operator-assisted` / `external-oracle` / `felt`, harness commands, human-use checkpoints), `BUILDPLAN.md` (decided architecture, ticket breakdown with dependencies, checkpoint-shaped sequence), project `CLAUDE.md`; where the build has a designed surface, the binding prototype in `prototypes/` and `DESIGN.md`. Read them cold; `sequence/run-state.md`, if present, says where the arc stands.
- **Outputs:** one PR per ticket (merged or open per policy), the validation report at `.lattice/orchestration/validation-report.md`, an operator smoke-pass checklist, and a closeout audit routed to the project's lessons files.
- **Missing inputs:** name the gap and route upstream — this skill never authors the contract it will be audited against.

## Preflight

Thirty seconds before anything else: `lattice --version` works; `git rev-parse --show-toplevel` succeeds (no repo → stop); inside c11 (`C11_SHELL_INTEGRATION=1`) or the operator confirms a harness that can run parallel sub-sessions. Soft warnings (proceed, but say so): no `.lattice/`, no git remote, not in c11. On resume, skip the soft warnings.

## Phase 0 — Intake & ticketing (Orchestrator)

Read the whole contract cold, then:

1. **Contract checks — validate, never author.** Flag gaps to the operator rather than filling them: every SPEC criterion appears in `EVALUATION.md`; the fast/full test split is defined (`test` hermetic + parallel ≤60s — the delegators' inner-loop clock — and `test:full` for slow suites; a slow default suite is a defect, propose a fix-it ticket); persisted fields each have a writer and a reader; every non-negotiable guardrail has an enforcement/audit item; module names are keyword-safe; the ticket sequence de-risks assumptions early (walking skeleton first).
2. **Pin install facts.** Status vocabulary from `.lattice/config.json` — not every install has `pr_open`; record the *terminal pre-merge status* and thread it into every boot prompt (when unsure: `lattice show <ID> --json | jq .valid_transitions`). The actual git remote name via `git remote -v` — many Stage 11 repos use `forgejo`, not `origin`; a wrong remote makes every fetch, review base, and push silently miss. Tickets whose code lands in a different repo, flagged explicitly.
3. **Config dialogue — short, defaults auto-suggested from plan size** (12 tickets → N=5, validators on; a 3-ticket cleanup → N=2, off): autonomy level, max concurrent delegators N, PR merge policy (auto-merge vs. leave at terminal pre-merge status; default leave), per-ticket workflow modes, Master Validator (default on above 3 tickets), Result Validator (default on), c11 preferences. Before proceeding, tell the operator what Phase 1 will look like — how many panes appear, how escalations surface, what "done" is.
4. **Mint the board.** One Lattice ticket per build-plan item, dependencies linked conservatively (loose dependencies kill parallelism), checkpoint order preserved, each ticket carrying its acceptance-criteria IDs and harness hook. Every Lattice mutation needs `--actor` (or `--name`); keep ticket IDs out of titles.
5. **Write the validation plan** — `EVALUATION.md` re-expressed, one row per criterion, each row tagged `pre-merge-static` (answerable from PR diff + source; the Result Validator runs these) or `post-merge-smoke` (needs the merged tree or a human driving; the operator runs these post-merge). Tag honestly — a static row that secretly needs a merged tree ships a partial-inspection failure into Phase 2. `felt` criteria and human-use checkpoints land on the smoke side by construction. The operator reviews the draft.
6. **Stand up the run:** `run-state.md` and `agents.md` under `.lattice/orchestration/`, workspace geometry, dashboard.

Mechanics, schemas, and templates: `references/intake.md`.

## Phase 1 — Dispatch (Orchestrator)

The dispatch loop, run on the `/loop` skill — never shell `watch`/`sleep` loops, which die on compaction and are invisible to the harness. Each tick: refresh state → surface escalations (every tick while unresolved) → press-ahead audit (spawn dependents when a dependency reaches review, not merge) → auto-merge if enabled (gated on *verified* git/PR state AND fresh, this-cycle, PASS review evidence — the review gate fails open; see references/orchestrator.md "A fired review is not a finished review" — never reported state) → close finished surfaces → spawn next available delegators → schedule the next wake.

Delegators run one of three modes, chosen per ticket at Phase 0:

- **Fast-track** — single session, inline self-review; small, well-understood tickets.
- **Inline-full** *(default for medium work)* — single session plus headless plan-review and code-review for fresh eyes without PTY pressure.
- **Sub-agent-full** — separate planner/impl/fix tabs; escalation for large or high-risk tickets only.

The Orchestrator's inviolable norm: **it dispatches; it does not implement.** All operational depth — the identity block, boot templates, worktree discipline, review fallbacks, verified-state rules, merge machinery, captains, recovery — lives in `references/orchestrator.md`.

A general principle for briefs and boot prompts: where a step's success has a concrete observable, name it — what the artifact should look like when it worked, not only the command to run. An expected observable is what lets the executor notice the environment disagreeing with the plan; beyond that, trust their intelligence. (2026-07-11: a "verify rc.3 in manifest.json" line caught a mislabeled staging build that exit-0 would have shipped.)

## Phase 2 — Terminal validation (Result Validator)

A fresh session with no prior context, on purpose: it reads SPEC, BUILDPLAN, and the validation plan cold, walks every `pre-merge-static` row exactly as written (the plan is the contract — no substituting faster methods, no inventing rows, no silently skipping), and writes the validation report: per-criterion results, drift from the build plan, gaps, recommendations, and the operator's post-merge smoke checklist verbatim. Skip it only for trivial runs (1–2 tickets); otherwise it's cheap insurance against the Orchestrator's self-congratulatory bias. Playbook: `references/result-validator.md`.

After the report, the **closeout audit**: read the run's comments, commits, and archived-agent notes; extract *timeless* findings (failure mode → why it matters → fix); route them to the project's `LESSONS.md`, its `CLAUDE.md`, this skill, or new Lattice tickets. War stories go to `runs-ledger.md` beside this skill; only the principle enters the skill.

## Autonomy levels

Set at Phase 0 (the project `CLAUDE.md` may declare a default; otherwise Moderate):

- **Fully Autonomous** — architectural choices, scope expansions, dependency loosening: the Orchestrator decides, logs to run-state, proceeds. Escalate only destructive or irreversible actions.
- **Moderate** *(default)* — decide-and-log routine calls; surface non-trivial architectural choices, scope expansions, and mild irreversibility for approval.
- **Minimal** — surface at every phase transition; the operator is driving.

Every autonomous decision lands in run-state's append-only decision log, tagged with the autonomy level that authorized it.

## Layout (inside c11)

One workspace per run: a **Main View Area** (Orchestrator, Master Validator, and Result Validator tabs), a **Control Surface** (Lattice Board browser surface, logs), and **three Delegate View panes**. Three, because the c11 PTY allocator wedges around 20–25 surfaces per pane on long runs and a wedge spreads globally within a minute — soft cap **15 surfaces per pane**, route new delegators to the lightest-loaded pane, close finished surfaces promptly.

## Resume

`run-state.md` is the anchor. Contract artifacts exist → Phase 0 collapses to surface-and-confirm (no re-asking); tickets exist → re-bind and resume dispatch; dead sessions recover via c11 workspace persistence and the session-resume hook. A delegator that is gone and not resumable goes to `needs_human`.

## References

| File | Owns |
|---|---|
| `references/intake.md` | Phase 0 mechanics: contract checks, config set, install-fact pinning, ticket minting, validation-plan template, run-state/agents schemas, geometry, dashboard |
| `references/orchestrator.md` | Phase 1 depth: identity block, dispatch loop, boot templates + standard clauses, worktrees, reviews, verified-state discipline, merging, captains, recovery, footgun catalog |
| `references/result-validator.md` | Phase 2 playbook: boot, audit protocol, report template |

Each is one seat's playbook — load it when you sit in that seat.
