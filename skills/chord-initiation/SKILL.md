---
name: chord-initiation
version: 1
description: Stage 1 of the Chord workflow (chord-initiation → chord-prototype → chord-architect → lattice-orchestrator ×K) — Tone in plural: the portfolio initiation of one problem with several complete answers. Commission a portfolio, research to enumerate, generate ~N candidate bets, voice K uncorrelated ones with a champion each, and write the two-tier philosophy & stories. Inherits tone-initiation by reference. Invoke when the operator says "chord," "chord this," "portfolio this," "build several answers," or when a keystone fork resists resolution by research and dialogue.
---

# Chord — Initiation

**Chord** is Stage 11's portfolio-creation workflow — Tone in plural. Where Tone carries one idea to one loved prototype and one build contract, Chord carries one *problem* to K complete, shipped, instrumented solutions and lets reality pick. The entry bar is the **keystone inversion**: a fork that dialogue, research, and a venture-partner grilling cannot settle stops being a blocker and becomes the axis of variation. If one shape is obviously right with cosmetic variants, the fork isn't wide enough — run Tone. The portfolio buys **effectiveness, not speed**: candidates are not racing, and every design choice below spends one currency — information per unit of operator attention.

## Inheritance (the load-bearing rule)

On invoke, read `~/.claude/skills/tone-initiation/SKILL.md` in full. It is the **base contract**: its pipeline norms, principles, phases, touchpoint discipline, and layout all bind here unless this skill explicitly overrides them. If it is missing, stop and say so — never improvise the base. Then skim the sibling chord skills, exactly as Tone's stages skim theirs. Tone and Chord are coupled on purpose: an improvement to Tone is an improvement to Chord the moment the skills sync.

**Overrides.** This skill replaces its base in exactly three places; everything else is additive. (A Tone edit landing in one of these should check both families.)

1. **Research saturation** — enumerate, not validate: stop when new searches stop yielding new candidate *shapes*.
2. **Layout** — portfolio root with per-candidate subtrees, in place of the singular project layout.
3. **Phase 3–4 stories** — two-tier (shared core + per-candidate), in place of one singular stories file.

## The plural norms (additive to Tone's pipeline norms)

1. **One problem, one philosophy, K solutions.** The one thing, the people, and the problem contract are singular. Two candidates needing different philosophies are different projects — split the commission.
2. **Uncorrelated failures.** Name *the one thing that kills it* per candidate; choose a set whose kill-conditions differ — including **distribution decorrelation**: candidates that all reach users through the operator's personal network are correlated where attention binds hardest.
3. **One problem, honestly held.** The shared acceptance core is written before any candidate exists. It is a problem-honesty instrument, not a stopwatch — it guarantees all K still answer the same problem, never that their clocks or fleets match.
4. **The membrane.** The operator is the only channel between candidates. Problem-level facts propagate to all by default; solution-level ideas cross only at operator discretion. Champion topology makes this physical.
5. **The bench.** The N−K unselected candidates are reserves, not rejects — a candidate that dies at any pre-ship gate can be replaced from the bench at operator discretion.
6. **Batched attention.** Every human touchpoint sees all K side-by-side, once. K gates in sequence is how the operator drowns.
7. **Pre-registration.** Kill and double-down criteria per candidate are written before anything ships (authored at chord-architect; honored from here forward).
8. **Chord creates; operations reads.** The resolution book is a handoff artifact, not a standing loop inside Chord.

Amendments to the *shared* core apply to all candidates simultaneously or none, and are logged. Candidate-level artifacts stay freely living, exactly as in Tone.

## The phases

**C0 — Commission (plural).** Tone's Phase 0, with the fork logic inverted. One problem, agreed and named, with a portfolio home (a portfolio repo for shared artifacts; candidate repos spawn at build — confirm name and location, never default). The Keystone Decisions table splits two ways: resolvable forks get resolved as in Tone; irresolvable ones are captured as **candidate variation axes**. Entry-bar check, honestly applied: if no fork survives as genuinely irresolvable, or the space can't support ~10 distinct shapes, say so and route to Tone — a commission correctly turned away is a success. Venture-partner offered at the portfolio level when the commission is a business.

**C1 — Research (enumeration-oriented).** Tone's Phase 1 dimensions survive wholesale; a fourth is mandatory: **the solution landscape** — how many genuinely distinct shapes others have used against this problem and its analogues. The brief inverts from validate to enumerate, and saturation is redefined (override 1): stop when new searches stop yielding new candidate shapes.

**C2 — Enumerate (new).** Generate ~N candidates (default ≈10), each a one-card bet: name · core assumption · who pays and roughly how · the one thing that kills it · its natural distribution channel. Fan out generation across deliberately different lenses — personas, wedges, business models; cross-model seeds where they add genuine diversity. Distinctness discipline: swap the pitch between two cards and you should still tell them apart. Resist honestly card-by-card — weak candidates die here, where dying is cheap.

**C3 — Voicing (gate).** The portfolio pick, with the operator: select K (default 3–5) under uncorrelated failures — kill-condition diversity and distribution decorrelation weighed together. The selection artifact is `PORTFOLIO.md`: the chosen candidates, their axes of variation, their kill-conditions, why *this set* spans the space, and the bench. Explicit check: is this K different bets, or one bet voiced K ways? Each selection gets its premises signed (venture-partner per candidate, proportional) and a **champion**: a dedicated agent owning the candidate from here through build-contract handoff. Inside c11, champions are surfaces of one champions pane — one pane, K surfaces — with this conductor in its own pane; champions never read each other's surfaces (norm 4, enforced by topology). A bench promotion mints a fresh champion. Each champion writes its candidate's `ECONOMICS.md` where economics are load-bearing.

**C4 — Philosophy & stories (two-tier).** One `PHILOSOPHY.md` at the portfolio root — shared, referenced never copied, by every candidate. Stories split (override 3): the **shared core** (problem-level stories and ACs — the problem-honesty rulebook, identical for all, IDs like `AC-1`) and **per-candidate stories** (candidate-prefixed IDs like `B/AC-4`, authored by each champion). One **batched stories review** (touchpoint): the operator reads all K side-by-side, once.

## Layout (the portfolio's)

```
<portfolio>/
├── sequence/
│   ├── run-state.md          # ONE portfolio run-state; per-candidate status rolls up here
│   ├── research/             # the enumeration-oriented dossier
│   └── USER_STORIES.md       # the shared core (AC-n)
├── PORTFOLIO.md              # voicing artifact: the K, their axes, kill-conditions, the bench
├── PHILOSOPHY.md             # singular, shared by reference
├── candidates/<X>/           # per candidate: stories (X/AC-n), ECONOMICS.md, prototypes/ …
│                             # (own repo spawns at build; this is the pre-build home)
└── CLAUDE.md                 # pointers to every root artifact, never copies
```

## Handoff

Champions invoke `chord-prototype` per candidate — proportionality dialed down (divergence was spent at the candidate level), iteration batched portfolio-wide. The conductor keeps `run-state.md` current and its own lane clear for the operator.
