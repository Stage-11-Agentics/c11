---
name: sounding
version: 1
description: The idea-generation sequence upstream of the Tone/Chord workflows — the operator brings a direction (a market, a hunch, a theme); Sounding arms it with evidence and explores it in dialogue, producing reads — concrete, carded takes on the direction — each ending in a try/not-try call. Where Tone begins with "a raw idea and a client," Sounding is where raw ideas come from. Invoke on "sounding," "take soundings," "sound this," "let's explore ideas," "what should we build next," or whenever the operator brings a direction that isn't yet an idea. Standalone; "try" reads feed venture-partner and the Tone/Chord commissions; composes with Scanner (/scan) for app-level evidence.
---

# Sounding

A sounding is a depth measurement — taken before the ship commits to the channel. The skill in five bullets:

1. **Starts from a direction the human brings.** A market, a hunch, a theme, an itch. Sounding never runs empty — the direction and the will behind it are the operator's. You may suggest directions you noticed; you never own one.
2. **Arms the direction with evidence.** Scanner sweeps and demand research over the direction's territory: what exists, who pays, what they pay, where incumbents are weak.
3. **Plays.** The exploration dialogue — riffs, angles, what-ifs, sharpening in conversation. The heart of the skill, and it is allowed to be playful; that is where the surprising reads come from.
4. **Produces reads.** Concrete candidate takes on the direction, each packaged as a card: demand evidence, incumbents, distribution hypothesis, build size, kill condition.
5. **Ends in try / not-try per read.** Made with the operator, side by side, no finer ranking. "Try" reads go to a venture-partner grilling and enter Tone or Chord as commissions.

Pre-build validation (landing pages, listing tests, paid probes) is downstream — Resonance's probe instruments, available to any "try" read whose risk is demand-shaped. Sounding's output is ideas, not experiments.

Assumes c11 (load the c11 skill for mechanics) and Scanner where app-level evidence pays; on territory Scanner can't reach, the sequence runs on plain research — the discipline is the skill, not the tooling.

## The exploration dialogue

This is tone-initiation's interview energy pointed at an open direction instead of a brought idea. You are part researcher, part sparring partner: the operator holds the direction, taste, and context the evidence can't supply; you hold the evidence, the breadth, and the obligation to push back. Neither alone generates good ideas — the dialogue is where they combine, and it is the phase everything else serves.

- **Come armed.** Never open the dialogue empty-handed — bring the sweep: what the territory looks like, where the money visibly moves, what surprised you. The operator's time is spent reacting and steering, not waiting for research.
- **Two evidence instruments, both encouraged.** Research (sweeps, sources, numbers — cited) and **model intelligence** — your own knowledge of markets, business models, pricing norms, and failure patterns is a legitimate source: use it freely and label it as yours, so the card can tell a cited fact from a model prior. Hiding behind search when you already know the shape of an answer wastes the dialogue; asserting a prior as a citation poisons it.
- **Ask real questions, liberally.** What pulls the operator toward this direction? What would they never build, and why? Which incumbent's customers do they instinctively understand? Instinct is data — interrogate it like any other source.
- **Volunteer reads, with a position.** Surface more candidate reads than the operator asked for, take positions on them, and state what formed each position. Enthusiasm is earned by evidence; so is skepticism.
- **Loop between evidence and conversation.** A dialogue turn that raises a question the evidence can't answer mints a research task; run it and come back. Expect several passes — exploration is iterative by nature, and "not yet knowable, here's how we'd find out" beats a confident guess.
- **Develop, don't just collect.** When a read shows life, work it *in the dialogue*: sharpen the wedge, name who pays, find the kill condition together. A read leaves the conversation better-formed than it entered, or it doesn't leave as a card.

## The card

One card per read, one file per card:

- **Read** — one paragraph, the wedge in one line.
- **Origin** — the direction it answers (the operator's own words, from S0) and the evidence or dialogue moment that produced it. No orphan reads.
- **Demand** — who pays today, what they pay, with links; model priors marked as such. The mandatory column: real displaced spend, or `Unknown — how we'd find out`, never silence.
- **Incumbents** — who holds the spend, their weakness, Scan refs where they exist.
- **Distribution hypothesis** — how this acquires users, channels tagged by delegability (per the distribution skill). All-operator-only distribution is named on the card as a strike, before anything is built.
- **Build sketch** — size tier (S/M/L) only. Buildability is table stakes, never the selling point.
- **The kill** — the one thing that kills it, plainly.
- **Call** — try / not-try / watch, and the one-line reason.

## The sequence

**S0 — Receive the direction.** The operator states the direction and why it pulls them — captured in their own words; that paragraph heads every read's Origin. Agree on the territory the direction implies and how deep this run should go.

**S1 — Sweep.** Scanner shallow scans over the territory's incumbents; demand overlay alongside (marketplace stats, review velocity, pricing pages, category spend). Output: the evidence brief that opens the dialogue.

**S2 — Play.** The dialogue, as above. Generation runs throughout — between sittings, fan out candidate reads from the evidence and bring the distinct ones in. Distinctness discipline: swap two pitches and you should still tell them apart.

**S3 — Card.** Reads the dialogue kept get the full schema. Filling the card is itself a test — a card that can't fill its demand column goes back to the dialogue or dies.

**S4 — Call (touchpoint).** The operator reads the cards side by side, once: **try, not-try, or watch** — the calls are the output. "Try" reads go to venture-partner; survivors are commissioned into Tone (or Chord, when the read's keystone fork is genuinely irresolvable). Underwriting formality — budgets, signed kill criteria — lives at that commission gate, and Tone's Phase-1 research inherits the card's evidence rather than re-deriving it.

## Corpus

The shape is fixed, the address is the operator's: a sounding corpus, created on first run at the workspace root unless the operator points elsewhere, holding `cards/`, `sweeps/<territory>/<date>/`, and `INDEX.md` (a plain list by status — regenerate, don't hand-tend). Re-sounding a territory diffs against its prior sweep; evidence carries an as-of date, and a stale card re-earns its call or moves to watch. Runs log to `runs-ledger.md` beside this skill; run-retro folds lessons back (family norm: war stories in the ledger, only principles enter the skill).
