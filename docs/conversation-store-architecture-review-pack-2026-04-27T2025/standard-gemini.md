# Standard Plan Review

## Executive Summary
This is a highly mature, defensively engineered architectural proposal that correctly identifies the root cause of the current session-resume fragility. The existing system (relying solely on surface metadata and lifecycle hooks) was always going to lose to race conditions during app teardown and fail gracefully for TUIs without hooks (like Codex or Kimi). By elevating `Conversation` to a first-class primitive owned by `c11` and introducing the push/pull (hook/scrape) duality, the plan solves the immediate bugs while laying a robust foundation for future capabilities like history and remote agents. It is the right approach.

## The Plan's Intent vs. Its Execution
The intent is to make agent session continuity reliable across app restarts, crashes, and OS reboots, regardless of whether the agent TUI provides explicit lifecycle hooks. The execution matches this intent perfectly. The shift from "metadata bolted onto a UI surface" to "a persistent conversation pointer that a surface hosts" is the critical conceptual leap. The execution correctly maps out the state machine required to handle the messy reality of process death and race conditions.

## Architectural Assessment
The decomposition is excellent. Separating the `ConversationStore` (lifecycle and persistence) from `ConversationStrategy` (per-TUI semantics for capture and resume) ensures that adding new TUIs scales linearly without cluttering core app logic. 

The fallback mechanism (pull-scrape) acting as the crash-recovery primary is a particularly strong architectural choice. It acknowledges that push-based systems (hooks) are inherently untrustworthy across abrupt failures.

One area of architectural friction is the concept of a global derived index (`~/.c11/conversations.index.json`). While keeping it in-memory for v1 is smart, its existence highlights a slight tension between "the workspace snapshot is the source of truth" and the desire for global cross-workspace portability. 

## Is This the Move?
Yes. The previous hotfix plan (`notes/session-resume-fix-plan.md`) was patching a leaky boat. As noted in the proposal, you would have to fight a new battle for every new TUI integration. This architecture pays the upfront cost to define a real primitive. It's making the right bets by prioritizing crash resilience (the `shutdown_clean` marker) and stateless strategies.

## Key Strengths
- **Push/Pull Duality:** Combining hook-based push for immediacy and scrape-based pull for crash-recovery and hookless TUIs is the strongest part of the design. It's a classic reconciliation loop pattern.
- **The `isTerminatingApp` Gate:** This elegantly solves the `SessionEnd` race condition where `Cmd+Q` triggers a teardown that clears the session ID right before the snapshot is saved.
- **Decoupled Strategies:** Modeling strategies as a pair of pure Swift functions (`capture` and `resume`) makes testing trivial and keeps the domain logic cleanly separated.
- **Forward Compatibility:** The `Payload` dictionary and opaque `id` string leave ample room for remote URLs, tunneling data, or new TUI-specific requirements without breaking the core schema.

## Weaknesses and Gaps
- **Pull-Scrape I/O Cost:** Performing a `stat` on every autosave tick per surface per TUI could become a problem. If an operator is running 30 agents across multiple workspaces, that's a noticeable cluster of I/O operations every 30 seconds, potentially waking up drives or causing micro-stutters.
- **Tombstone Ambiguity:** For hookless TUIs like Codex, treating "absent-on-restore" as tombstoned means the system can never confidently know if a session is truly dead until a restart happens. This limits the usefulness of the global in-memory index for hookless agents.
- **YAGNI on `ResumeAction.replayPTY`:** Including an action in the enum that no v1 strategy emits is premature. It pollutes the switch statements in the executor with dead code paths.

## Alternatives Considered
- **Harden the current pattern:** The plan correctly rejected this. Continuing to stuff `claude.session_id` into generic surface metadata would inevitably lead to `codex.session_id`, `kimi.session_id`, and a fragile web of UI-coupled logic.
- **PTY Hibernation (c11d daemon):** Also correctly rejected. A daemon doesn't survive a reboot, which is the primary operator complaint (losing context across OS restarts).

## Readiness Verdict
**Ready to execute (with minor revisions).** 
The architecture is sound. The revisions needed are mostly scoping decisions (dropping `replayPTY`) and finalizing concurrency models.

## Questions for the Plan Author

1. **Pull-scrape cadence:** You raised the concern about I/O cost. Doing this *only* on explicit push hooks, application quit (`applicationWillTerminate`), and crash-recovery launch seems far safer and entirely sufficient. Why poll every 30 seconds if the source of truth for active typing is the hook, and the scrape is just a fallback?
2. **`shutdown_clean` location:** Placing it in `~/.c11/runtime/shutdown_clean` is fine, but placing a lockfile/sentinel directly in the `~/.c11-snapshots/` directory might conceptually bind the "unclean shutdown" state closer to the data it affects. Have you considered this?
3. **Concurrency model:** You asked about an `actor` vs a serial dispatch queue. Yes, absolutely use a Swift `actor` for `ConversationStore`. Since c11 is moving toward actor-isolation, this is the perfect isolated state container. It prevents the boilerplate of serial queues and gives you compiler-enforced thread safety for the state machine transitions.
4. **YAGNI `replayPTY`:** Should we just drop `ResumeAction.replayPTY` for v1? If no strategy uses it, it's just dead weight in the `execute` switch statement.
5. **Wrapper PATH gating:** Yes, the wrapper should short-circuit completely if `CMUX_DISABLE_AGENT_RESTART=1` is set. If the operator opted out, we shouldn't even bother generating the placeholder claim IDs or spawning background processes.
6. **Hook payload routing:** Collapsing `c11 claude-hook session-start` into `c11 conversation push` is much cleaner. Can the telemetry breadcrumbs simply be migrated into the generic `push` handler (e.g., logging `conversation.push.claude-code`) rather than keeping the old hook command alive just for taxonomy?
7. **Strategy resolution at restore:** If `kind = "claude-code-2"` has no strategy, skipping with `Diagnostics.log` is the safest v1 approach. Don't build UI for a "missing strategy" edge case until it actually happens.
8. **Querying `isTerminatingApp`:** Rather than a new socket method, can this be exposed via the existing `capabilities` or `ping` command responses to avoid adding a dedicated, highly-specific socket method just for the CLI tombstone check?