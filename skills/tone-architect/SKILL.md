---
name: tone-architect
version: 1
description: Stage 3 of the Tone workflow (tone-initiation → tone-prototype → tone-architect → lattice-orchestrator) — the technical-architecture dialogue that translates a validated prototype, philosophy, and stories into the build contract: EVALUATION.md, SPEC.md, and BUILDPLAN.md. You are a technical architect in dialogue with the client: options weighed with pros and cons, a path to success laid out, nothing glossed over. Invoke when the operator says "tone architect," "technical architecture," "translate the prototype into a spec," "spec and build plan," or standalone when a validated design needs codifying for a build.
---

# Tone — Architect

Stage 3 of **Tone**, Stage 11's idea-to-build workflow: **tone-initiation** → **tone-prototype** → **tone-architect** (this skill) → **lattice-orchestrator**. Each stage is independently invocable when its inputs exist; this one wants a validated prototype plus `PHILOSOPHY.md` and `USER_STORIES.md` with AC IDs.

You are a technical architect in dialogue with the client: the question is *how do we translate this loved design into a system we will run and build* — and the answer is co-authored, never handed down. **Separation of duties is the point of this stage's existence**: the build contract is written here, upstream of the builders, so the build is judged against a spec its builders did not write. The design questions are already answered — by a prototype the client used and loved; what remains is codification and the technical path.

Assumes c11 (load the c11 skill for mechanics). Full-ahead between touchpoints; escalate irreversible decisions and taste-defining forks; decide-and-log everything else. Proportional: depth scales with stakes, and any shrink is recorded in `sequence/run-state.md`, the arc's shared resume anchor — read it first on invoke.

## Contract

**On invoke, skim the sibling stage skills** (`~/.claude/skills/tone-*/SKILL.md`) so you hold the whole arc — the pipeline norms (living artifacts, AC lineage, one run-state, closed loop) live in `tone-initiation` and bind every stage.

- **Inputs:** the validated prototype in `prototypes/` and `DESIGN.md` (from tone-prototype); `PHILOSOPHY.md` and `sequence/USER_STORIES.md` with AC IDs (from initiation); `ECONOMICS.md` and the dossier where they exist; `sequence/run-state.md`.
- **Outputs:** `EVALUATION.md`, `SPEC.md`, `BUILDPLAN.md` at the repo root — the complete build contract — plus `sequence/run-state.md` updated.
- **Consumed by:** `lattice-orchestrator` — tickets from the plan, dispatch, and a terminal audit against a spec its builders did not write.

## The phases

**Phase 0 — Intake.** Read the corpus cold: `run-state.md`, `PHILOSOPHY.md`, `USER_STORIES.md`, the converged prototype and `DESIGN.md`, `ECONOMICS.md` where present. Confirm the inputs are complete — a missing input is surfaced now, not discovered at spec time. If anything upstream must change (see Living artifacts, below), it changes upstream: propose the amendment, propagate, never fork the truth locally.

**Phase 1 — Evaluation contract.** Turn the criteria into the contract the build inherits: what "done" means and *exactly how an agent verifies it without a human in the loop*. Bias hard toward runnable; record the harness command(s). Write `EVALUATION.md` at the repo root. Tag every criterion's verifiability:

- `autonomous` — a build agent proves it alone.
- `operator-assisted` — needs human-supplied data or a manual step. Record what the human must supply and *when*, so the build doesn't reach terminal validation unable to prove its headline claim.
- `external-oracle` — needs a real artifact or third-party tool to judge against (e.g., a "zero corruption" claim provable only against a real production-scale library with the consuming app as judge).
- `felt` — visual fidelity, responsiveness, integration-seam sense; no automated check settles it (a 45-second interaction latency passes every hermetic test). Schedule each as a **human-use checkpoint** with an explicit trigger — walking skeleton usable; each user-facing surface — so the build carries a real human-drives-it step, with the validated prototype as the reference. No user-facing milestone is done on green tests alone.

**Phase 2 — Specification.** Codify the validated prototype and its criteria into `SPEC.md`: zero design decisions left to the implementer, numbered testable acceptance criteria (by ID), explicit non-goals. **Every non-negotiable guardrail is enforced, not assumed**: each gets its own pass/fail criterion and an explicit demand that the build plan carry an enforcement/audit ticket — especially an audit of any *existing* code the build sits on. Stating a guardrail and trusting future code to honor it is how a ship-blocking footgun ships — a "never write the live DB" rule is worthless if a pre-existing sync engine can still do exactly that and nothing audits it. Then an adversarial judge-gate: a second model scores the spec for executability by an unfamiliar implementer; revise until it passes, escalate if author and judge deadlock on a judgment call.

**Phase 3 — Build plan.** The build plan is a **dialogue with the client, not a draft handed down**. For each consequential technical decision — stack, architecture, data model, integration approach — lay out the genuinely viable options with pros, cons, and a recommendation, and decide *together*; full-ahead governs execution, but the path itself is co-authored. `BUILDPLAN.md` then lays out the path to success: the decided architecture and approach, and a ticket breakdown with dependencies, **sequenced around human-visible checkpoints** — the walking skeleton early, named milestones and minimum-viable cuts, each critical assumption checked at the earliest checkpoint a human can drive. A plan whose critical assumptions all resolve at the end discovers its failures at the end; where an assumption can't be settled by discussion or research, mint an explicit **spike ticket** that proves it out before dependent work dispatches. Where the project persists state, every field has a writer and a reader — an unwritten field is a silent hole. Three checks that pay off in the build:

1. **Merge-friendly boundaries** — parallel tickets collide on shared registration/aggregator files (a CLI command group, an `__init__.py` re-export list, a plugin registry, a central router). Prefer auto-discovery or one-file-per-plugin registration over hand-edited shared lists; isolate each ticket's file surface; where a shared file is unavoidable, say so in the ticket item so the orchestrator serializes that edit.
2. **Keyword-safe names** — check every proposed module/dir/package name against the language's reserved words and import rules before writing it down (a `<pkg>/import/` directory is a Python `SyntaxError`).
3. **Brownfield reconcile** — if the build sits on an existing codebase, audit what already exists before minting plan items and plan only the gap (DONE/PARTIAL/MISSING with file:line).

**Phase 4 — Plan review (touchpoint).** Review spec + plan across multiple lenses and, where it pays, multiple models — including an **adversarial pass that reads the actual codebase, not just the plan,** against the SPEC's guardrails and success criteria. Its job is the dangerous gap the plan glosses over: a shipped code path that violates a non-negotiable, a missing field writer, a "we'll just" that isn't ticketed. File what it finds as gap/safety items in the plan. Apply validated findings by default; surface judgment calls and subjective trade-offs to the client.

**Phase 5 — Handoff.** Deliver the contract to `lattice-orchestrator`: it turns the plan into tickets, dispatches the fleet, and audits the result against a spec its builders did not write. Where the build splits into an agent-buildable track and a human track (procure, assemble, sign, call), say so in `BUILDPLAN.md` — only the first goes to the fleet; the second is the client's work plan with its own dependency ordering. For the exact invocation, paths, and section structures the orchestrator expects, follow its own documentation as the source of truth; a copy kept here would rot.

## Living artifacts (pipeline norm)

When codification surfaces a contradiction — a story that can't be specified, a philosophy line the chosen architecture violates — surface it. If the client upholds the new answer, the upstream artifact is what's wrong: propose the amendment, update it, propagate forward. Never leave two artifacts disagreeing; never fork the truth into the spec.

## When the build isn't pure software

- **Verification cost inverts.** Where criteria can't be machine-proven, `autonomous` becomes the rare tag and `operator-assisted` / `external-oracle` / `felt` the norm. Name the procedure and instrument for each the way you'd name a harness command — a bench test and scope for hardware, a real counterparty case for a business process.
- **Reversal cost gates full-ahead.** Cheap (code, config, copy) — decide and log as usual; expensive (procurement, money spent, public commitments, anything engaging real counterparties) — research harder and escalate *before* acting. One-way doors get more dialogue, not less.
- **Hardware adds artifacts.** A **BOM** (parts, qty, unit cost, lead time, in-stock check, a second source on the critical path — a part going EOL is the hardware "dependency that doesn't exist") and **physical-safety/environmental guardrails** (battery, thermal, electrical, EMC), each getting the same enforce-don't-assume treatment as data guardrails. `felt` checkpoints run in — or faithfully simulating — the target environment: a benign-environment demo gives false confidence for exactly the failure class the device exists to beat.
