---
name: tone-prototype
version: 1
description: Stage 2 of the Tone workflow (tone-initiation → tone-prototype → tone-architect → lattice-orchestrator) — prototype discovery: exploration directions pinned down with the client (by default three, each resting on a different core assumption), a clickable HTML prototype per direction on realistic mock data, iterated with the client until they love it. The full design, UX and UI, is discovered here; the build later reproduces it one-to-one. Invoke when the operator says "tone prototype," "prototype this," "prototype discovery," or standalone whenever a scoped idea needs its design discovered — even outside a full Tone run.
---

# Tone — Prototype

Stage 2 of **Tone**, Stage 11's idea-to-build workflow: **tone-initiation** → **tone-prototype** (this skill) → **tone-architect** → **lattice-orchestrator**. Each stage is independently invocable when its inputs exist; this one needs only a scoped idea — ideally `PHILOSOPHY.md` and `USER_STORIES.md` from initiation, but any clear statement of problem and audience will do.

This is the centerpiece of the arc. The full design — UX *and* UI — is **discovered here**, at the cheapest level where it can still change, and validated by the client actually using it. Everything downstream reproduces what this stage converges on; nothing downstream re-designs. Iteration ends when the client **loves** the prototype, not when they accept it: approval is a gate passed, love is a design found. The working test — *would the client keep this if a better option appeared tomorrow?*

Assumes c11 (load the c11 skill for mechanics). Outside c11, takes degrade to files opened in a browser.

## Contract

**On invoke, skim the sibling stage skills** (`~/.claude/skills/tone-*/SKILL.md`) so you hold the whole arc — the pipeline norms (living artifacts, AC lineage, one run-state, closed loop) live in `tone-initiation` and bind every stage.

- **Inputs:** `PHILOSOPHY.md` and `sequence/USER_STORIES.md` with AC IDs (from initiation) — or, invoked standalone, any clear statement of problem and audience. `ECONOMICS.md` and the dossier where they exist. `sequence/run-state.md` decides where to resume.
- **Outputs:** `prototypes/` with the converged take as the binding visual contract; `DESIGN.md`; amendments flowed back into `USER_STORIES.md` (new AC IDs) and `PHILOSOPHY.md` (upheld violations); `sequence/run-state.md` updated.
- **Consumed by:** `tone-architect` (the prototype is the design reference for the spec and the `felt` checkpoints) and, through it, the build fleet (which reproduces the binding contract one-to-one).

## The work

**Design is a first-class task, not a byproduct of mockups.** Pin down the **brand voice** (how the thing speaks — every string the user reads has a tone) and the **visual aesthetic language** (typography, color, density, motion) alongside the prototypes that express them. Where a house brand exists, inherit it and say so; otherwise fan out — genuinely different aesthetic directions and voices, not one direction in three colorways.

**Pin down the directions before building.** Divergence starts at the assumption level, not the color level. Propose candidate directions, each resting on a **different core assumption** — about who the primary user is, what the central workflow is, how much the product does, where it lives — and agree *with the client* on which to explore. **Three directions is the default**; the client sets more or fewer, and for a small or clearly scoped project one may be right — but the default posture is a broad overview of what *could* be built, because the client can't pick a direction they never saw.

**For anything with a UI, the medium is clickable HTML prototypes** — one per agreed direction, each embodying its assumption as a **different UX paradigm**, not a recolor: swap the headline between two and you should still tell them apart. Frame each to its medium — an iPhone shell for mobile, browser chrome for web.

**Mock data by default — but realistic**, drawn from samples of actual data whenever possible. Idealized mock data silently hides the failures prototyping exists to catch — real names are long, real numbers are ugly, real lists have two hundred items, not three. A prototype validated against pretty fake data validates nothing.

**Mock the boundaries, not just your own surface.** Where the product integrates with an external system the user lives in (a chat client, a third-party app, a device), prototype a stand-in of that surface too, plus a one-page seam diagram — what maps to what, what flows across, what each side sees. The integration boundary is the most error-prone part of any build and gets zero design attention if left a black box.

**For non-UI work**, use the right cheap artifact instead: a sample CLI transcript, an annotated spec-sheet, a sample chapter, a worked end-to-end case for a business process. If there's no experience surface, say so and skip — don't manufacture ceremony.

## The iteration

Present the takes side by side — in c11, one browser surface each, tiled for single-glance comparison. **The pick is the start of the design, not the end**: iterate the chosen direction with the client — revise, re-present in the same surface, repeat, generously. Many rounds are the norm, not gold-plating; this is the cheapest place the design will ever be to change. Diverge, then converge by iteration: the binding design is the one you *arrive at together*, never the first fan-out winner.

**Living artifacts (pipeline norm).** Iteration here stress-tests everything upstream. New stories and criteria discovered in the prototype flow back into `USER_STORIES.md` with fresh AC IDs. And when a client choice contradicts `PHILOSOPHY.md` and they uphold the choice, the philosophy is what's wrong — propose the amendment, update it, propagate. This stage is fully licensed to reopen initiation's artifacts; they live in the same repo precisely so it can.

## Done — and what it produces

The stage is done when the client has **used** the converged prototype — clicked through it, driven its flows — and loves it. Then:

- The converged take in `prototypes/` becomes the build's **binding visual contract**, reproduced one-to-one: every designed control present, even if it only toasts "not yet implemented (AC-x)" — never a loose reference to approximate.
- `DESIGN.md` at the repo root records the converged design language — voice, aesthetic, the chosen direction and why — referenced by `CLAUDE.md` (a pointer, never a copy) so every later agent inherits it.
- Every prototype carries an unmistakable, persistent on-screen `PROTOTYPE` badge ("not wired to real data" where it helps) — part of the artifact itself, never a caption supplied verbally. A high-fidelity mockup must never be mistakable for the shipped product.
- `sequence/run-state.md` updated: takes produced, direction chosen, rounds iterated, stats.

**Handoff.** Invoke `tone-architect` — the technical dialogue that codifies the loved design into `EVALUATION.md`, `SPEC.md`, and `BUILDPLAN.md`.

## When the experience isn't a screen

The riskiest experience may not be on a screen. For hardware, the prototype contract splits: HTML take(s) for any on-device UI *plus* a physical/ergonomic contract — chosen parts, a control/layout map, a foam-core or bench mock — so a pretty screen mock can't pass as "the prototype" while the physical experience goes undesigned. For a business process or new business, the prototype is a worked end-to-end case the client walks through — the counterparty's experience mocked as faithfully as a UI would be.
