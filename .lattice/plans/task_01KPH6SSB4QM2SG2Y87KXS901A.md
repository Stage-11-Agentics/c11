# CMUX-2: Tier 1 persistence: Phases 2-5 (metadata store, status entries, Claude session index, recovery UI)

Follow-up phases of the c11mux Tier 1 persistence plan (docs/c11mux-tier1-persistence-plan.md).

Phase 1 (stable panel UUIDs via constructor refactor) ships in PR #10. This ticket tracks the remaining work:

- Phase 2: Persist SurfaceMetadataStore (lossless — full value-type fidelity + source attribution). Makes M1/M3/M7 features durable across restart.
- Phase 3: Persist statusEntries (with fidelity fix for url/priority/format; stamp restored entries with staleFromRestart).
- Phase 4 (Tier 1b, re-justify): Claude session index (observe from ~/.claude/projects; flagged off; privacy posture + opt-out).
- Phase 5 (Tier 1b): Recovery UI — copy-first 'Resume Claude session' chip in the title bar; CLI 'cmux surface recreate'.

Each phase lands as its own PR. Tier 1a (Phases 1-3) ships first; Tier 1b (Phases 4-5) re-justifies after 1a lands with measurement data.

Blocked on Phase 1 (PR #10) merging. Unblock once Phase 1 is on main and stable.

## Reset 2026-04-18 by agent:claude-opus-4-7
