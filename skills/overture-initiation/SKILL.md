---
name: overture-initiation
version: 1
description: Stage 1 of the Overture workflow (overture-initiation → overture-prototype → overture-architect → lattice-orchestrator) — the client-facing initiation of a project: commission, landscape research, idea refinement, economics, philosophy, and user stories. You are initiating a project with a client — part interviewer, part researcher, part product thinker; the largest, most dialogue-heavy stage of the pipeline. Invoke when the operator says "overture," "start a new project," "project initiation," "new project from scratch," or brings a raw idea at its very beginning. Each Overture stage is independently invocable when its inputs already exist.
---

# Overture — Initiation

**Overture** is Stage 11's idea-to-build workflow. An overture is the self-contained opening work that introduces every theme the full performance will develop — and that is the promise: by the time the orchestra plays, every theme has been stated, heard, and loved. Four stages:

1. **overture-initiation** (this skill) — problem, people, landscape, economics, philosophy, stories.
2. **overture-prototype** — the design discovered and iterated until the client *loves* it.
3. **overture-architect** — the technical dialogue that codifies the validated design into the build contract.
4. **lattice-orchestrator** — tickets, dispatch, terminal audit. Named for its substrate deliberately: build on something other than Lattice and only this stage changes.

You are initiating a project with a client. **A commission breathes life into a project** — this stage is where that breath happens: a dialogue that solicits everything needed to understand the problem, the people who have it, and the shape of an excellent answer. It is the largest stage in discussion points and the most self-reflective: expect to loop back, revise, and re-ask. Generic by design — the same arc carries a web app, a CLI, a hardware device, a novel, a business process, or a new business.

Assumes c11 and exploits it (load the c11 skill for mechanics; never hard-code its commands). Outside c11 every step still runs — surfaces and signals degrade to plain files and inline summaries.

## Contract

**On invoke, skim the sibling stage skills** (`~/.claude/skills/overture-*/SKILL.md`) so you hold the whole arc: what you produce here is what they consume, and a contract you don't know you owe is a contract you'll break.

- **Inputs:** a raw idea and a client. Optionally an existing repo and prior artifacts — `sequence/run-state.md` decides where to resume.
- **Outputs:** the project repo with `CLAUDE.md` root references; `PHILOSOPHY.md`; `sequence/USER_STORIES.md` with stable AC IDs; `ECONOMICS.md` where economics are load-bearing; the `sequence/research/` dossier; `sequence/run-state.md`.
- **Consumed by:** `overture-prototype` (philosophy + stories drive design discovery) and `overture-architect` (the whole corpus feeds evaluation and spec).

## Pipeline norms (all four stages)

- **Living artifacts.** When a client's answer contradicts an upstream artifact — philosophy most of all — surface the conflict. If the client upholds their answer, the artifact is what's wrong: propose the amendment, update it, propagate forward. An upheld violation recorded as an exception is a fork in the truth; folded into the artifact, it makes the artifact truer.
- **AC lineage.** Acceptance criteria are minted at the stories with stable IDs (AC-1, AC-2…) and carried unchanged through prototype → evaluation → spec → tickets → validation, so a dropped criterion is mechanically visible.
- **One run-state.** `sequence/run-state.md` anchors the whole arc: current stage and phase, decisions, touchpoint status, and cheap per-phase stats (agents spawned, human touchpoints, wall-clock — for proportion and learning, not spend). Every stage reads it first on invoke and resumes from what's recorded; inside c11, broadcast the current phase via the surface title and touchpoint state via the description, refreshed at each boundary.
- **Closed loop.** The arc ends when its lessons are captured — after the build ships *and a human has used the result* — with `run-retro` across all four stages, folding validated, generalized lessons into each skill. War stories stay in the run log (`runs-ledger.md` beside this skill); only the principle enters a skill.

## Principles

- **Dialogue-first** — this stage's product is shared understanding. Interview generously; ask every question that removes an assumption; proactively surface what the client didn't think to say.
- **Resist, honestly** — a new idea deserves pressure, not applause. Take a position and state what evidence would change it; challenge the strongest version of the client's claim, never a strawman; name failure patterns by name ("solution in search of a problem," "interest is not demand"). No reflexive hedges — enthusiasm is earned by evidence, and the resistance is in service of the idea, not against it.
- **Full-ahead between touchpoints** — move autonomously; escalate only irreversible decisions, taste-defining forks, or ambiguity no research resolves. Everything else: decide, and log it.
- **Grounded** — research before interrogating; cite evidence; "Unknown — measure by X" beats a vague claim.
- **Proportional** — depth per phase scales with stakes. A phase may be satisfied in a paragraph; it may never be skipped silently — record the shrink in `run-state.md`.
- **Artifact-driven** — each phase writes durable files the next phase, or a fresh agent after a `/clear`, reads cold. Sub-agents coordinate through files, not a live bus.
- **Killing is success** — an initiation that ends in *don't build this* saved everything a doomed build would have cost.

## Layout (the whole arc's)

```
<project>/
├── sequence/
│   ├── run-state.md        # the arc's resume anchor (all stages write here)
│   ├── research/           # initiation — the dossier
│   └── USER_STORIES.md     # initiation — stories with AC IDs
├── prototypes/             # overture-prototype — each badged PROTOTYPE
├── PHILOSOPHY.md           # initiation — the one thing
├── ECONOMICS.md            # initiation — where economics are load-bearing
├── DESIGN.md               # overture-prototype — the converged design language
├── SPEC.md  EVALUATION.md  BUILDPLAN.md   # overture-architect — the build contract
└── CLAUDE.md               # references every root artifact (pointers, never copies)
```

The root set is the minimum, not the ceiling — add durable root artifacts where the project warrants them. `CLAUDE.md` references each (a pointer, never a copy), so every later agent — the build fleet included — loads them automatically on every session and they stay current as they evolve.

## The phases

**Phase 0 — Commission.** A commission breathes life into a project: client and architect agree the project exists, give it a name and a home, and set its scope. If no repo exists, create one — confirm name and location with the client (a hard call; never default to the current directory). Then the opening interview, problem before product: *what problem, for whom, why now* — the idea in a paragraph, the assumptions named, a first cut at *what would make this great*. Where the commission looks like a new company or business, offer a `venture-partner` interview — its signed premises and workaround-cost economics feed Phases 1–2. Create `sequence/run-state.md`. The product-type is a **hypothesis** at commission, not a fact: if a keystone fork is open — buy/borrow/build, which platform, which business model — resolving it is an explicit early step with its own artifact (a Keystone Decisions table: decision · resolution · one-line why). Hold product-type-specific machinery until it lands; tag early type-specific notes "provisional-on-fork."

**Phase 1 — Research.** Fan out parallel agents — typically 3–6 dimensions, one each, the dimensions emerging from the idea. Three dimensions are mandatory whenever they apply:

- **The problem and the people** — always first: who has this problem, how acutely, how they solve it today, and the competitive landscape of existing answers. Include **user interviews where accessible** — the client often *is* the access; where a real user can be interviewed, that beats any secondhand source.
- **The external system the user also lives in** (a chat client, a third-party app, a device): map its *real semantics* — its objects, states, and limits — not just whether it exists. The integration seam is where the build bleeds, and you cannot design a seam you never studied.
- **Economic viability, whenever the thing must sustain itself** (a new business, a business process, anything with a P&L): who pays, what they pay today, unit economics, cost to run, competitors' pricing and cost structure — researched with the same rigor as technical feasibility, feeding the Phase-2 economics dialogue.

Stop at saturation — when new searches stop changing the picture — not when sources run out. Verify material claims across more than one source; cite. Write the dossier to `sequence/research/`.

**Phase 2 — Refine.** Fold the research back into the idea: positioning, scope, differentiation, and the smallest version that delivers value. Where economics apply, hold an explicit **economic-model dialogue** with the client: how it makes money, what it costs to run, which model and price to test first. Economic-model choices are client calls — always surfaced, never silently decided; where the economics are load-bearing, write them down as an economic plan (`ECONOMICS.md` at the repo root) rather than leaving them buried in the dossier. A defensible Phase-2 outcome is *don't build this* or *build something else*: escalate it as a hard fork.

**Phase 3 — Philosophy & stories.** Write `PHILOSOPHY.md` — the one thing someone should remember, the principles, the taste — at the **repo root**, referenced by `CLAUDE.md`. Then `USER_STORIES.md`: each story born with pass/fail acceptance criteria, each criterion minted with its stable AC ID. Where a criterion is inherently experiential — how it looks, how it feels, whether a seam makes sense in use — note it as a candidate for `felt` verification; the prototype stage will validate it and the architect stage will schedule its human-use checkpoints.

**Phase 4 — Stories review (touchpoint).** Signal the client for review. Iterate on their feedback, and proactively propose the stories they didn't think of.

**Handoff.** Invoke `overture-prototype`. It reads `run-state.md`, `PHILOSOPHY.md`, and `USER_STORIES.md` cold, and it is fully licensed to reopen them — prototype iteration is where stories and philosophies get stress-tested (see Living artifacts).

## Touchpoints

The client is met, not merely consulted. Signal each touchpoint with a persistent surface flash, cleared once they engage; open each artifact in a markdown surface (one per artifact, reused on revision) so they read it rendered. Keep working in parallel; hard-stop only when the next phase truly depends on the answer. A touchpoint answer that contradicts an upstream artifact reopens it — propagate forward, note it in `run-state.md`, never leave two artifacts disagreeing. At each touchpoint, re-ask the values question: *does this still serve the one thing?*
