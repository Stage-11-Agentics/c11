---
name: chord-architect
version: 1
description: Stage 3 of the Chord workflow (chord-initiation → chord-prototype → chord-architect → lattice-orchestrator ×K) — codifies K loved designs into K build contracts under one shared rulebook, authors the pre-registered resolution book, then conducts the ×K build (fresh lattice-orchestrator run per candidate) through to the handoff of K live, instrumented probes. Inherits tone-architect by reference. Invoke when the operator says "chord architect," "codify the portfolio," "spec the candidates," or when a portfolio of loved prototypes needs its build contracts — and stay seated: this skill also owns the conductor's build-and-handoff playbook.
---

# Chord — Architect & Conduct

Stage 3 of **Chord**, Tone in plural — and the stage that stays in the room longest: first the architecture dialogue that turns K loved designs into K build contracts under one rulebook, then the **conduct phase**, where K lattice-orchestrator runs execute in parallel and the portfolio is held legible until handoff. Separation of duties survives plurality: each build is judged against a spec its builders did not write.

## Inheritance (the load-bearing rule)

On invoke, read `~/.claude/skills/tone-architect/SKILL.md` in full. It is the **base contract**: the evaluation-contract discipline (verifiability tags, human-use checkpoints), spec rigor (guardrails enforced not assumed, judge-gate), build-plan dialogue (merge-friendly boundaries, keyword-safe names, brownfield reconcile, spike tickets), and the non-software variants all bind here unless explicitly overridden. If it is missing, stop and say so. For the conduct phase, `lattice-orchestrator`'s own documentation is the source of truth for each run's mechanics — this skill orchestrates *runs*, never re-documents them.

**Overrides.** This skill replaces its base in exactly three places; everything else is additive.

1. **One contract → K contracts + one rulebook.** One shared problem-spec codifies the shared story core; K candidate specs reference it, never copy it. Evaluation likewise: a shared eval core (identical harness wherever applicable — the honesty instrument) plus per-candidate evals.
2. **The judge-gate gains two cross-candidate duties.** A **distinctness audit** (K different bets, or one bet in K costumes?) and an **honesty audit** (is the shared core actually judgeable across all K — are they still answering the same problem?).
3. **The handoff.** Tone hands one contract to one orchestrator run; Chord's architect seat rolls directly into the conduct phase below — K runs, a membrane, a ledger, and an exit.

## Architecture, plural

Champions author their candidate's spec, evaluation, and build plan in dialogue with the operator — decisions batched across candidates wherever they rhyme (one sitting deciding K stacks beats K sittings). Build plans are merge-friendly across candidates by construction, with milestones **aligned across the portfolio where candidate shapes allow**, so human-use checkpoints batch (one session, K walking skeletons); alignment is a scheduling preference in service of batched attention, never a clock imposed on a candidate whose shape needs longer.

**The resolution book** — authored here, before anything ships; pre-registration is the only defense against sunk-cost creep once there are K living products the operator is fond of. Per candidate:

- **Kill / double-down thresholds**, pre-registered and tied to its `ECONOMICS.md`.
- **The instrumentation contract** — metrics wired from day one; "metrics flowing" is a ship-blocking criterion, not a nice-to-have.
- **The distribution plan** — mandatory; code without distribution is code nobody can use. Authored with the `distribution` skill: every channel classified by delegability (agent-executable / operator-assisted / operator-only), funnels instrumented, the portfolio's distribution-decorrelation check re-run across all K plans.
- **The review cadence** the operations layer will run — which also serves pre-ship as the portfolio's **staleness check**: with no shared clock, a candidate that keeps missing its own cadence is the zombie, surfaced to the operator for kill-or-recommit rather than left at "still building" forever.

## Conduct (the ×K build)

Each champion hands its contract to a **fresh lattice-orchestrator session in its own c11 workspace** — a run is workspace-sized, and the orchestrator seat reads the contract cold; the champion's long creation context never sits in it. The champion stays alive in the champions pane as its candidate's advocate: answering the fleet's questions, reviewing drift against the loved prototype. Terminal validation per candidate as lattice-orchestrator specifies, plus that candidate's resolution-book criteria in its validation plan.

The conductor's standing duties while runs execute:

- **The portfolio ledger** — each run's surfaced learnings, recorded as they land.
- **The membrane** — problem-level facts (a shared-spec bug, a discovered market truth) fast-lane to all runs with operator approval; solution-level ideas cross only by explicit operator choice; every crossing logged in the ledger. Shared-core amendments apply to all candidates simultaneously or none.
- **Shared infrastructure is an explicit call, never a drift.** Candidates share nothing by default — sharing code (auth, billing, design system) correlates the bets and softens the membrane; when the operator chooses to share anyway, the ledger says so and why.
- **Batched checkpoints** — where milestones aligned, human-use checkpoints run as one sitting across candidates.
- **The staleness cadence** — run it; surface zombies; offer the bench.
- **Repo spawn** — candidate repos are minted at conduct start (private by default, per the Stage 11 hard rule), each referencing the portfolio repo's shared artifacts.

## Handoff & resolution

Chord exits at: **K live, instrumented probes + the resolution book**, delivered to whatever owns the operations cadence. Resolution — reading each candidate against its own pre-registered criteria on the stated cadence; kill, double down, or merge (the organ-transplant pass: losers are purchased parts as well as purchased information) — happens *outside* Chord, and each read is absolute, never head-to-head. The closed loop still fires: after the first real resolution reads, `run-retro` folds validated, generalized lessons back into both the Chord and Tone families.
