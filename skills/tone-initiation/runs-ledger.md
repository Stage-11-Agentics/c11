# Runs Ledger — the Overture workflow

The run log behind the Overture skills (and their predecessor, project-architect). Each entry preserves the full story that shaped a principle; the skills themselves carry only the principle. New entries accrue at each closing retrospective.

## The Overture redesign (2026-07)

The workflow itself was redesigned through the exact process it prescribes: what began as "touch up the project-architect skill" became, through dialogue, the discovery that the product-type was wrong — one monolithic skill split into a four-stage pipeline (initiation → prototype → architect → lattice-orchestrator). The meta-lesson: the interview surfaces what an audit cannot; auditing polishes the artifact you have, dialogue discovers the artifact you need.

## Polyphony

- **Use-first / `felt` criteria:** the build passed every Podium acceptance criterion yet didn't match its prototype (a full one-to-one rebuild resulted) and shipped a 45-second interaction latency — both invisible to every hermetic test, caught only when a human sat down with it.
- **Integration seam:** treated Zulip as a known black box. The seam — how a chat *room* vs. a *topic* actually behaves, what the event queue guarantees — was implemented, never designed. It prototyped its operator console but not the other half the user actually lives in, and paid for it at the boundary.
- **Merge conflicts:** repeated Acetate's shared-file collisions exactly, on `cli.py` plus a layout-test file.

## Acetate

- **Merge conflicts:** every parallel ticket pair collided on `cli.py` import-groups and `sync/exporters.py` helpers — predictable, repeated merge surgery that disjoint boundaries would have prevented.
- **Guardrails enforced, not assumed:** the pre-existing `ace sync engine` could rebuild the operator's real library in violation of the SPEC's #1 rule ("never write a live DB") — caught only by an ad-hoc audit, then guarded by a ticket that should have existed from the start.
- **`external-oracle` criteria:** "zero corruption" was tagged autonomous but actually required a real ~16k-track library plus the DJ app as oracle — surfaced only at the terminal audit.
- **Keyword-safe names:** the BUILDPLAN literally specified `acetate/import/` — a Python `SyntaxError`; `import` is a keyword.

## Electric unicycle app

- **Build on the HTML prototype:** the build didn't treat an HTML prototype as its foundation — design discovery that should have happened cheaply at the prototype level leaked into the build itself. Motivated the multi-prototype default and the "design is discovered at the HTML-prototype level; the build reproduces, never re-designs" emphasis in overture-prototype, plus checkpoint-shaped sequencing in overture-architect's build plan so critical assumptions can't all resolve at the end.

## Ra

- **Product-type is a hypothesis:** the run opened classified "hardware," wrote eight hardware-specific lessons, then the keystone interview pivoted it to a native iPad app with a boring off-the-shelf BOM — mooting or recontextualizing five of the eight within hours.
- **Hardware adaptation axes:** the "When the build isn't pure software" section (verification cost, reversal cost, who-builds partition, BOM + safety guardrails, environment-matched checkpoints) originates from this run; project-specific detail lives in the run's own lessons file.
