---
name: resonance
version: 1
description: Stage 11's marketing-capability program — a working session that turns marketing intent into budgeted, pre-registered experiments and accumulates the verdicts into a playbook of plays with real numbers. Demand generation is the unsolved half of the autonomous-business loop; Resonance reps it daily the way agentic coding was repped in 2023–24. Invoke on "resonance," "make this resonate," "marketing," "get users for this," "demand probe," "test demand," or whenever marketing needs to produce a verdict, not a vibe. Standalone; its probe instruments serve Sounding "try" reads; its playbook feeds the distribution skill (per-project channel planning), which feeds every channel result back.
---

# Resonance

A tone is produced; resonance is the audience amplifying it. The skill in five bullets:

1. **A working session that ends with runnable plays, not a philosophy of marketing.**
   The operator brings intent — a product that needs users, a launch, a demand question.
   The session ends with experiment briefs ready to fire, or an explicit "not yet, and
   here's the number we're missing."
2. **Every marketing act is an experiment or it doesn't run.** Hypothesis, audience,
   funnel stage, channel, budget, pre-registered bar, verdict date — written before
   anything fires. No verdict, no learning; no learning, and it was just spend.
3. **Check the playbook before designing anything.** Validated plays get run again
   before novel ones get invented; refuted plays don't get re-bought. The playbook is
   the capability — this file is just the loop that fills it.
4. **Bias hard toward agent-native plays.** Automating the human marketing playbook
   produces slop at scale and burns credibility permanently. The edge is wherever agent
   economics changes the arithmetic — the forcing question below.
5. **Nothing goes public without operator sign-off, per surface.** Brand voice
   (`company/brand/`) binds all public output. No fake social proof, no astroturf, no
   ToS violations — the whole thesis rests on being the evidence-backed actor.

This skill encodes a capability that doesn't exist yet, at Stage 11 or anywhere; it
structures acquisition. Early runs will feel underpowered. That's what repping a
frontier looks like.

Assumes c11 (load the c11 skill for mechanics); degrades cleanly to plain files outside it.

## The session

**R0 — Intent.** What business number is this trying to move, for which product, by
when? Installs, signups, stars, active users, replies, revenue. "We should do
marketing" is not intent — push until it's a number on a date.

**R1 — Map.** Read the playbook first. Then the ground: who the audience actually is,
where they already gather (name real venues, not categories), what the funnel looks
like today (do we even know weekly installs?), and what the audience currently uses
instead. Model intelligence and quick research both count — label which is which.

**R2 — Design.** Candidate plays, each stated tactically: play · funnel stage ·
channel · cost (dollars / agent-hours / operator-minutes) · expected signal ·
time-to-verdict. Rank by information per dollar per week; take positions. The forcing
question for every play: **what does agent economics make affordable here that never
was before?** Fifty positioning variants where humans test two; per-segment landing
pages; always-on community presence; genuinely deep per-prospect research; measurement
rigor humans never sustain; machine-legible surfaces for agent-mediated discovery —
the next buyer is an agent making tooling decisions, and nobody courts them yet. A
play a human team could run just as well is allowed, but must say why we run it.

**R3 — Pre-register.** Chosen plays become experiment briefs (schema below) before
anything fires. The bar is a number with a date and a cost cap, decided now — not
negotiated after the results are in.

**R4 — Run.** Agents carry the agent-executable lanes end-to-end; operator-gated
surfaces (outreach under his name, community posts, anything public) batch for
sign-off per the distribution skill's delegability classes.

**R5 — Verdict.** On the verdict date, read the numbers and write it: **validated /
refuted / inconclusive**. Refuted is full-value — the graveyard prevents re-spend
forever, and honest negative results are themselves an agent-native edge. Inconclusive
on the date means kill or redesign with a sharper bar; no zombie experiments.

## The experiment brief

One file, written at R3: **hypothesis** (one sentence, falsifiable) · **product &
business number** · **audience** · **funnel stage** (aware → considering → trying →
adopted → advocating) · **channel/surface** · **cost** (dollars, agent-hours,
operator-minutes) · **bar** · **measurement** (how we'll know, from whatever the
property already offers — an experiment that can't say how it's measured doesn't run) ·
**verdict date** · **verdict** · **what we learned**.

## Channels

Name real ones, classified by delegability (per distribution): launch venues (HN,
Product Hunt, the right subreddits); content and SEO (comparison pages, tutorials,
docs that answer the buyer's first search); communities (Discords, Slacks, subreddits —
presence earns, drive-by promotion burns); social (X, build-in-public); directories,
listings, awesome-lists, package registries; paid micro-spend (small caps, fast
reads); outreach (drafted by agents, sent under the operator's name); integrations and
partnerships; agent-mediated discovery (llms.txt, machine-readable docs, being the
answer agents give when asked "what should I use for X"). The list illustrates; the
session picks venues the actual audience actually reads.

## The probes

Pre-build demand instruments, available to any Sounding "try" read whose risk is
demand-shaped: landing page, marketplace listing test, waitlist, paid micro-spend,
comparison-page probe, concierge run. Each is an experiment like any other — bar
pre-registered before it fires. Recipes aren't authored here; they're earned into the
playbook by being run.

## The playbook

`resonance/` at the Stage11 root (sibling of `sounding/`), created on first run:
`experiments/` (one brief per run, immutable once verdicted) and `playbook/` (distilled
plays — play, audience, channel, creative approach, actual numbers including cost per
result, conditions where it holds — each citing the experiments that earned it, with
replication count and as-of date), plus `INDEX.md` (regenerate, don't hand-tend). One
experiment makes a play a candidate; replication promotes it. Early reps run on
Stage 11's own tools, where a bad landing costs nearly nothing.

Runs log to `runs-ledger.md` beside this skill; run-retro folds lessons back (family
norm: war stories in the ledger, only principles enter the skill).

## Boundaries

`distribution` plans channels for one shipped thing — it consumes this playbook and
feeds every channel result back as experiment data. Cadence (the standing post-ship
operations rhythm) is deliberately unauthored until something ships and needs it.
Resonance is the cross-project capability program: the session, the playbook, the probes.
