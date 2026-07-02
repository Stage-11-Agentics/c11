---
name: chord-prototype
version: 1
description: Stage 2 of the Chord workflow (chord-initiation → chord-prototype → chord-architect → lattice-orchestrator ×K) — prototype discovery per candidate, run by each candidate's champion and iterated on a portfolio-wide board until the operator loves every surviving candidate's design. Inherits tone-prototype by reference; divergence was already spent at the candidate level, so takes are dialed down and iteration is batched. Invoke when the operator says "chord prototype," "prototype the portfolio," or when a voiced portfolio (PORTFOLIO.md with champions assigned) needs its designs discovered.
---

# Chord — Prototype

Stage 2 of **Chord**, Tone in plural. Each champion runs prototype discovery for its own candidate; the portfolio meets the operator as **one board, one sitting per round**. The design of every candidate is discovered here at the cheapest level where it can still change — and a candidate whose design cannot be loved is not a design problem, it is *information*: a kill signal the portfolio paid to receive.

## Inheritance (the load-bearing rule)

On invoke, read `~/.claude/skills/tone-prototype/SKILL.md` in full. It is the **base contract**: design as a first-class task, realistic mock data, boundary mocks, PROTOTYPE badges, the non-UI and non-screen variants, and the love bar all bind here unless explicitly overridden. If it is missing, stop and say so — never improvise the base. Skim the sibling chord skills for the arc.

**Overrides.** This skill replaces its base in exactly two places; everything else — including the love bar — is inherited untouched.

1. **Direction fan-out** — Tone defaults to three directions per project; Chord spent its divergence choosing K candidates, so the default is **1–2 takes per candidate**. Go wider only where a candidate's UX *is* its core assumption (PORTFOLIO.md says which).
2. **Presentation & iteration cadence** — takes are presented and iterated on a **portfolio-wide board**, not per-project sittings: all candidates' takes tiled for single-glance comparison, one round of operator feedback per sitting, champions iterating in parallel between sittings. Attention costs rounds × one sitting, never rounds × K sittings.

## The work, plural

- **Champions execute; the conductor curates the board.** Each champion builds and revises its candidate's takes in its own surface (browser surfaces per take, grouped by candidate on the board). The conductor assembles the board, schedules sittings, and routes the operator's feedback to the right champion.
- **The membrane holds during iteration.** Feedback on candidate A goes to champion A. A discovery that is *problem-level* — a mock-data truth, a boundary-semantics surprise, a shared-core story gap — fast-lanes to all champions with operator approval; a design idea from one candidate crosses to another only by explicit operator choice, logged in `run-state.md`.
- **The love bar holds per candidate** (inherited, deliberately not overridden): iteration ends when the operator has used each surviving candidate's converged take and loves it — would keep it if a better option appeared tomorrow. A candidate stuck short of love after generous rounds is surfaced for **kill and optional bench promotion**, not for bar-lowering. Lukewarm probes ship ambiguous failures: bad bet, or just unloved design? The portfolio can't afford the ambiguity.
- **Living artifacts flow per candidate.** New stories and criteria discovered in a candidate's prototype land in `candidates/<X>/` with fresh `X/AC-n` IDs. An upheld contradiction with the shared `PHILOSOPHY.md` or the shared story core is portfolio-level by definition — it amends the shared artifact for all candidates simultaneously or none.

## Done — and what it produces

Per surviving candidate: the converged take in `candidates/<X>/prototypes/` as that candidate's **binding visual contract**, and `candidates/<X>/DESIGN.md` recording its converged design language — voice, aesthetic, direction, why. Portfolio `run-state.md` updated: takes per candidate, rounds, kills and promotions, stats. Every take carries the PROTOTYPE badge (inherited, non-negotiable).

## Handoff

Invoke `chord-architect`: champions codify their loved designs into K build contracts under one shared rulebook, and the conductor's build-and-handoff playbook takes the portfolio home.
