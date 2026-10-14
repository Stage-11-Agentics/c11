# C11-24: c11 conversation store: TUI-agnostic session resume primitive

Replace the per-TUI bespoke wrapper pattern with a first-class Conversation primitive owned by c11. Each surface hosts ConversationRefs persisted across c11 restarts; per-TUI strategies (push hooks, pull scrape, wrapper claim) capture and resume conversations. Plan at docs/conversation-store-architecture.md (post-Trident review). See review pack at docs/conversation-store-architecture-review-pack-2026-04-27T2025/ for the 9-agent review and synthesis-action.md for what's been baked into the plan vs. surfaced as operator decisions (all resolved as of 2026-04-27).

Success metric: operator closes a c11 window with 15 tabs / 10 coding-agent surfaces, reopens c11, finds all 10 agent conversations preserved and resumable.

Marquee feature for 0.44.0. Stays c11-only (not landing upstream in cmux). Lattice-agnostic.

## Plan

The full architectural plan lives at `docs/conversation-store-architecture.md` in this worktree (~480 lines). It went through a 9-agent Trident plan review on 2026-04-27 (`docs/conversation-store-architecture-review-pack-2026-04-27T2025/`); all 11 surfaced operator decisions (S1–S11) have been resolved and baked into the plan. Read that file as the canonical plan; this scaffold is just the Lattice-side pointer.

Implementation order (per the delegator prompt at `/tmp/C11-24-delegator-prompt.md`, summary):
1. New `Sources/Conversation/` module + types (`Ref`, `ResumeAction`, `Strategy`, `Store` actor, `StrategyRegistry`).
2. `Sources/Conversation/SurfaceActivity.swift` — per-surface `lastActivityTimestamp`.
3. CLI surface in `CLI/c11.swift`: `c11 conversation claim|push|tombstone|list|get|clear` (no focused-fallback).
4. Per-kind strategy + scraper files for Claude Code, Codex, Opencode, Kimi (privacy contract: metadata-only, byte-capped parse, no transcript content).
5. Collapse `claude-hook session-start` to `c11 conversation push --kind claude-code …`.
6. Inverted dirty/clean shutdown sentinel (`~/.c11/runtime/shutdown.<bundle_id>.{dirty,clean}`) written *after* final scrape + snapshot.
7. Refactor `Workspace.scheduleAgentRestart` to consume `ResumeAction` from `ConversationStore` + strategy registry.
8. Embed `SurfaceConversations` on `SessionPanelSnapshot`; round-trip; one-release legacy `claude.session_id` lift on read.
9. Wrappers: `Resources/bin/claude` shrinks; `Resources/bin/codex` gains `c11 conversation claim`; rewrite the `codex resume --last` justification comment.
10. Architecture-level kill switch: `CMUX_DISABLE_CONVERSATION_STORE=1`.
11. Skill update is a merge-blocker: `skills/c11/SKILL.md` (top-level mention) + new `skills/c11/references/conversation.md` (CLI verbs, lifecycle states, ambiguity behavior, examples).
12. Tests: failure-mode 1:1 mapping (one test per row of §Failure modes), fixture-driven Codex two-panes-same-cwd regression test (merge-blocker), snapshot round-trip integration test.

Delegation pattern: orchestrator (surface:13) hands off to delegator (surface:14, this pane); delegator spawns Impl/Review/Fix siblings as new tabs in pane:4 and routes findings via `synthesis-action.md` from `/trident-code-review`. PR opens against `Stage-11-Agentics/c11`; operator completes the ticket post-merge.

## Post-review scope reduction (2026-04-27)

The post-implementation Trident review (`notes/trident-review-C11-24-pack-20260427-2343/synthesis-action.md`) found that 6 of 9 reviewers independently flagged the same structural gap: the new pull-scrape rail (`strategy.capture(inputs:)`, `ClaudeCodeScraper`, `CodexScraper`) has zero production callers and only runs in tests. Operator decision: **scope-down to v1.0 = snapshot-only resume; pull-scrape pass + SurfaceActivity persistence land in v1.1 (0.45.0+).**

Rationale: wiring the pull-scrape pass without first solving Codex cwd recovery would surface "ambiguous, skip" on every restart for every operator with multiple recent Codex sessions — strictly worse than the snapshot-only v1. The cwd-recovery fix needs a privacy-contract design call (parsing JSONL first-line metadata is a bounded transcript read; the structural Mirror test on `ScrapeCandidate` forbids transcript-bearing fields and would need a guarded carve-out).

### Landing in this PR (review-fix commits)

- B2: defer `markAllUnknown` until after `seedFromSnapshot` (race fix)
- B3: claude-hook session-end uses `diagnostic_reason` (was `reason`, silently dropped)
- B4: `v2ConversationTombstone` validates `--kind`/`--id` against active ref
- I1: payload Bool/NSNumber + size cap + nested rejection
- I2: `--state` strict validation on server and CLI
- I3: drop `--workspace` from `c11 conversation list` (v1 limitation)
- I4: rewrite stale Phase 1 resume guidance in `skills/c11/SKILL.md`
- S3: explicit `/exit` does not auto-resume (by design; documented in SKILL)
- M1: drop the redundant `applicationShouldTerminate` snapshot write
- M2: dedup `shouldReplace` predicate
- M3: kill-switch telemetry breadcrumb
- M4: `Resources/bin/claude` resolves `$self_dir/c11` first
- Doc updates: architecture doc + SKILL Codex row + this plan

### v1.1 follow-ups (0.45.0+)

- B1: wire `forcedPullScrapePass()` in `AppDelegate.applicationDidFinishLaunching` after `seedFromSnapshot`
- B5: `SurfaceActivityTracker` snapshot persistence in `SessionPanelSnapshot`
- S4: Codex cwd recovery via bounded JSONL metadata parse (privacy-contract design call first)
- I5: end-to-end Codex two-pane restore test exercising the production path
- E3: `ConversationSupervisor` actor — natural home for the lifecycle/capture orchestration
- E2: centralize the "synchronous bridge into actor with bounded timeout" pattern (5 sites today, 4 different timeouts)
- E1: `kind: String` → enum

### v0.46 / v1.1 removals (already tracked in code TODOs)

- `CMUX_DISABLE_CONVERSATION_STORE` kill switch
- Legacy `claude.session_id` reserved-metadata bridge
- `AgentRestartRegistry` legacy fallback path
