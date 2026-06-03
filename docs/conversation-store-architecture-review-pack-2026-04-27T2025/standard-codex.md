# Standard Plan Review: Conversation Store Architecture

PLAN_ID=conversation-store-architecture
MODEL=Codex

## Executive Summary

The plan is directionally right. Moving from per-TUI wrapper tricks and reserved metadata keys to a c11-owned Conversation primitive is the correct architectural move for c11. It matches the product's role as host and primitive, not tenant configurator, and it gives the system a vocabulary for "the work continues" that is not tied to one process, one hook payload, or one sidebar metadata key.

The most important caveat: the plan currently overstates what the proposed architecture can guarantee for hookless TUIs, especially Codex. A first-class store makes resume state explicit, but it does not magically create a stable identity signal when the TUI does not expose one. The proposed Codex scrape heuristic, "same cwd + modified after claim + after surface activity," is plausible as a best effort, but it is not yet strong enough to support the claim that two Codex panes in the same project become structurally impossible to confuse. That identity problem is the main thing to pressure-test before implementation starts.

My verdict is "needs revision, then ready." The core decomposition is good. The plan should be tightened around identity confidence, shutdown/crash marking, snapshot mapping, shell-command safety, and the exact boundary between store, strategy, wrappers, and filesystem scrapers.

## The Plan's Intent vs. Its Execution

The intent is clear: c11 needs to preserve agent continuity across app restarts, crashes, sleep/power loss, and multi-agent workspaces without writing persistent config into the user's TUI-specific dotfiles. The current implementation has backed into a series of special cases: Claude writes `claude.session_id` into surface metadata, Codex falls back to `codex resume --last`, and SessionEnd cleanup races c11 shutdown. The proposed ConversationStore is meant to make conversation continuity a first-class c11 concern.

That intent is the right one, and most of the plan serves it. The separation between surface metadata and conversation state is especially important. `terminal_type`, role, task, cwd, and status are surface or UI facts. A conversation ref is a resumable unit of work. Keeping those apart reduces reserved-key creep and gives c11 a place to model lifecycle transitions instead of encoding them as "write or clear a metadata field."

The main drift is that the plan sometimes treats "ConversationStore exists" as equivalent to "conversation identity is known." Those are different problems. The store can hold a ref, arbitrate state transitions, and expose observability. It cannot identify a Codex session correctly unless a strategy has a reliable signal. For Claude, the signal is strong because the wrapper injects `--session-id` and hooks report the id. For Codex, the signal remains inferred from cwd and timing. That may still be worth doing, but the plan should label it as a confidence-scored heuristic until proven against real session files and overlapping same-cwd panes.

There is a second drift around crash recovery. The plan's `shutdown_clean` marker is framed as a clean/crash oracle, but the proposed write timing leaves a false-clean window: if c11 writes the marker at the start of termination and then crashes, hangs, or is killed before forced scrape and final snapshot complete, the next launch will trust stale state. The marker needs to mean "the final conversation capture and snapshot completed," not merely "termination began."

## Architectural Assessment

The high-level decomposition is sound:

- `ConversationRef` is the persisted identity and provenance.
- `ConversationStore` owns lifecycle and reconciliation.
- Per-kind strategies interpret refs and know how to capture/resume a given TUI.
- Wrappers shrink toward declaration and hook transport rather than owning persistence semantics.
- Snapshots remain the source of truth, with a future derived index for discovery.

That is a better shape than hardening `AgentRestartRegistry`. The registry is a command lookup table; it cannot model provenance, crash recovery, tombstones, history, or multiple capture sources without becoming a store in disguise.

I would adjust a few boundaries.

First, strategies should not be described as pure functions if they perform scrape discovery. A scrape reads filesystem state, compares mtimes, parses session files, and may consult cached surface activity. The cleaner split is:

- a strategy describes how to interpret already-collected signals and synthesize resume actions;
- a scraper/provider performs bounded I/O and returns typed candidate signals;
- the store reconciles candidates under a single transition rule.

That split matters for testability and concurrency. It lets unit tests cover pure reconciliation separately from fixture-backed scrape tests.

Second, `ResumeAction.typeCommand(text:)` needs a safety contract. `ConversationRef.id` is opaque to the store, but it cannot be opaque to a shell command. Every strategy that emits `typeCommand` must validate or shell-quote the id according to that TUI's grammar. Claude already has UUID validation in today's `AgentRestartRegistry`. Codex needs an equivalent grammar once the real session id shape is verified. If a strategy cannot validate an id, it should not type it through a shell.

Third, the snapshot schema should probably attach conversations to panel snapshots, or at least define exact old-id to new-id remapping. The proposal says each workspace snapshot grows `surface_conversations: { surface_id: SurfaceConversations }` alongside `panels`. Current restore has an `oldToNewPanelIds` path because stable panel ids can be disabled. A sibling map keyed by old surface id must be remapped in lockstep or conversations can be orphaned. Embedding `conversations` on `SessionPanelSnapshot` would be simpler and would make the conversation follow the restored panel naturally. If the separate map stays, the plan should explicitly specify remapping and pruning semantics.

Fourth, the lifecycle state machine needs one more distinction: "process ended" is not always "conversation intentionally tombstoned." The plan says Claude SessionEnd with `isTerminatingApp == false` tombstones. That handles `/exit`, but it may also tombstone on unexpected Claude process crash, terminal shell kill, wrapper failure, or other non-c11 termination. If the hook payload does not distinguish explicit user end from process death, the safe default may be `unknown` or `suspended-with-ended-process`, not tombstone. Tombstone should mean "do not auto-resume because the conversation was intentionally ended or the backing session is gone."

## Is This the Move?

Yes, replacing the current pattern is the right move. The observed failures are architectural, not incidental:

- the current Claude path stores the ref in metadata and clears it through the same hook channel;
- the current Codex path knowingly collapses same-cwd panes into most-recent global resume;
- opencode and Kimi have no meaningful resume story;
- env-var loss can silently route hook writes to the focused surface.

Patching each symptom would add more special cases to the same weak model. A c11-owned Conversation primitive is the right foundation for session resume, future history, and remote/cloud continuation.

The plan should be less ambitious in its first implementation claims. I would ship v1 with these explicit tiers:

1. Strong resume: Claude Code, because c11 controls session id injection and receives hook ids.
2. Heuristic resume: Codex, only after real fixture validation of session files, with diagnostics when ambiguity exists.
3. Fresh-launch declaration: opencode/Kimi until their session stores are mapped.

That tiering is honest and operationally useful. It also prevents an implementation team from spending days trying to make an unobservable identity problem deterministic through timestamp cleverness.

## Key Strengths

The first-class Conversation primitive is the strongest idea in the plan. It names the actual domain object: not process, not panel, not terminal type, but a resumable continuation of work. That is the right abstraction for c11's agent-centric mission.

Separating conversation state from `surface.metadata` is also strong. Surface metadata is an extension and display channel. Making it the durable source of truth for agent session refs invites key sprawl and lifecycle races. A dedicated store can enforce provenance, state transitions, history, and observability in one place.

The push plus pull model is directionally correct. Hooks are low-latency and precise when available; scrape is necessary for crash recovery and hookless tools. Treating scrape as a fallback and crash-recovery primary is the right pattern, provided the scrape cost and identity ambiguity are bounded.

Removing focused-surface fallback from the conversation CLI is a necessary hardening step. The current `resolveSurfaceId` fallback is acceptable for interactive operator commands, but it is dangerous for hook subprocesses. Conversation writes must fail closed when `CMUX_SURFACE_ID` is absent.

Keeping the global index derived rather than authoritative is a good bet. It avoids creating a second source of truth before the UI needs it.

The out-of-scope section is disciplined. History UI, cloud strategies, plugin systems, cross-machine portability, and blueprint schema changes are all tempting, and all should stay out of v1.

## Weaknesses and Gaps

The Codex identity strategy is the biggest gap. "Same cwd + mtime after wrapper claim + after surface activity" is not enough unless verified against real Codex session data and overlapping same-cwd panes. Two Codex panes can start close together, both can be active, and session-file modification time may reflect later model output rather than creation. If both sessions share cwd, a later write in pane B may make B look like the candidate for pane A. The plan needs an ambiguity path: leave the ref unknown, skip auto-resume, or present diagnostics rather than choosing incorrectly.

The crash marker is written at the wrong conceptual time. A file named `shutdown_clean` should be written only after final capture and snapshot have succeeded. Writing it at the start of `applicationWillTerminate` makes "termination began" look like "termination completed." A safer pattern is a dirty/clean generation marker: mark dirty at launch, write clean only after final forced scrape plus synchronous snapshot, and clear or rotate on next launch.

The autosave cost is understated. Current `SessionPersistencePolicy.autosaveInterval` is 8 seconds, not roughly 30 seconds. In a workspace with many terminal surfaces, "one stat per TUI per autosave per surface" can become significant, especially if discovering cwd requires opening JSONL files. The plan should say "only run the active surface's strategy" and define a cheap directory generation cache before parsing any transcript/session content.

The privacy boundary needs to be explicit. Reading `~/.claude/sessions` and `~/.codex/sessions` is not a persistent write, so it does not violate the unopinionated-terminal rule in the same way installers would. But these files may contain transcripts. The plan should commit to metadata-only reads where possible, bounded parsing, no transcript indexing, and no copying transcript content into c11 snapshots.

The source priority rule is questionable. The proposal says latest `capturedAt` wins, with priority `push > scrape > wrapperClaim > manual` as a tiebreaker. Manual should probably not be lowest priority. If an operator manually sets or clears a conversation, that should either be an explicit override or a distinct action with clear precedence. Also, wall-clock `capturedAt` and filesystem mtimes are weak ordering tools under close races; store-side monotonic sequence numbers or compare-and-set generations would be safer for reconciliation.

`ResumeAction.launchProcess` and `replayPTY` are under-specified. The current restore path types commands into a shell-backed terminal. Launching a process inside an existing terminal surface is a different primitive; if there is no concrete `TerminalPanel.runProcess(argv:env:)` equivalent, this should be omitted from v1. `replayPTY` is also premature if no strategy emits it.

The plan does not mention updating `skills/c11/SKILL.md`. Project convention says every CLI, socket protocol, metadata schema, or surface-model change is incomplete until the skill is updated. `c11 conversation ...` is agent-facing infrastructure; the skill must document how agents inspect, clear, and reason about conversations.

The rollout/migration note is too compressed. "No migration" is fine for pre-release software, but the plan also says existing `claude.session_id` metadata is read once for backward compatibility. That is a migration, even if intentionally narrow. The implementation should define where that translation happens and whether it is tied to one release, one launch, or one snapshot rewrite.

## Alternatives Considered

The plan rejects hardening the current pattern, and I agree. A better `AgentRestartRegistry` plus a skip-clear flag would fix the latest Claude race but leave Codex and future TUIs in the same structural hole.

The plan rejects PTY hibernation, and I mostly agree for the stated goal. Keeping processes alive can improve GUI relaunch behavior, but it does not survive reboot, power loss, or process death. It is a complement, not a replacement, for durable conversation refs.

One alternative worth considering inside the chosen architecture is "panel-embedded conversations" rather than a sibling `surface_conversations` map. Embedding the active/history refs into each `SessionPanelSnapshot` keeps identity local, removes an orphan-map class of bugs, and naturally follows existing restore remapping. The downside is that it touches the panel schema directly. I think that downside is acceptable because conversations are not generic metadata; they are part of terminal surface persistence.

Another alternative is confidence-scored refs. Instead of `active: ConversationRef?`, v1 could model `active: ConversationCandidate?` with confidence/provenance. Claude hook refs would be high confidence. Codex scrape refs could be medium or ambiguous. Resume would only auto-run above a threshold. This may be overkill, but the concept is useful: wrong auto-resume is worse than skipped auto-resume.

A third alternative is to keep `typeCommand` as the only v1 resume action. `launchProcess` and `replayPTY` can land when a strategy needs them. Smaller v1 surface area reduces implementation ambiguity.

## Readiness Verdict

Needs revision before implementation.

The architecture should proceed after these changes:

1. Downgrade Codex from "structurally fixed" to "heuristic until fixture-proven," and define ambiguity behavior.
2. Move the clean-shutdown marker to after successful final capture and snapshot, or switch to a dirty/clean generation model.
3. Specify snapshot remapping for conversations, preferably by embedding conversation state in panel snapshots.
4. Add strategy-level id validation or shell quoting requirements for every `typeCommand`.
5. Define scrape cost/privacy constraints and acknowledge the current 8 second autosave interval.
6. Add skill documentation and CLI observability requirements to the implementation checklist.

With those revisions, this is the right foundation. Without them, the team risks rebuilding the current class of bugs under a cleaner name: stale refs, wrong-surface writes, and wrong-session resumes.

## Questions for the Plan Author

1. For Codex, what exact fields exist in `~/.codex/sessions/*.jsonl`, and do they include a stable session id, creation timestamp, cwd, process id, invocation id, or any value that can be tied to a specific wrapper claim?

2. What should happen when the Codex scraper finds two plausible sessions for one surface? Skip, choose newest, prompt via diagnostics, or store an ambiguous ref?

3. Is wrong auto-resume considered worse than no auto-resume? The answer should drive the Codex ambiguity policy.

4. Can the Codex wrapper inject any harmless per-surface marker into the session without violating the "host, not configurator" principle, or is filesystem scrape the only allowed signal?

5. Does Claude SessionEnd distinguish explicit `/exit` from process crash or terminal kill? If not, should SessionEnd outside app termination tombstone or transition to unknown?

6. Should `shutdown_clean` be written only after final forced scrape and synchronous snapshot complete? If not, how is the false-clean termination crash window handled?

7. Is `~/.c11/runtime/shutdown_clean` shared across tagged debug builds, release builds, and multiple running c11 instances? If so, should the marker be per bundle id, socket path, process namespace, or snapshot store?

8. Should conversations be stored as a sibling `surface_conversations` map, or embedded into each `SessionPanelSnapshot`? If the sibling map stays, what is the exact old surface id to new surface id remap behavior?

9. What is the intended precedence of manual conversation pushes or clears? Should manual really be lower priority than hook and scrape when timestamps tie?

10. What validation grammar will each strategy apply before emitting `typeCommand`? Claude has UUID validation today; Codex and future tools need equivalent rules.

11. Is `ResumeAction.launchProcess` backed by an existing terminal-panel API, or is it aspirational? If aspirational, should it be removed from v1?

12. Should `ResumeAction.replayPTY` ship in v1 if no strategy emits it?

13. Does scrape read only metadata and filenames, or can it parse transcript/session content? What transcript content, if any, may be copied into c11-owned files?

14. Should scrape run every 8 second autosave tick, or should it be throttled separately from session autosave?

15. Should scrape run for every registered TUI strategy per surface, or only for the surface's declared/claimed kind?

16. Where will `isTerminatingApp` be exposed to CLI tombstone commands: a new `system.is_terminating` socket method, an app lifecycle field in capabilities, or internal-only routing that avoids a CLI query?

17. What is the exact backward-compat path from existing `claude.session_id` metadata to `ConversationRef`? One launch, one release, or all legacy snapshots until rewritten?

18. Should the plan include an implementation step to update `skills/c11/SKILL.md` with `c11 conversation` commands and the no-focused-fallback rule?

19. What diagnostics should operators see when auto-resume skips because there is no strategy, an ambiguous scrape, a tombstoned ref, or a failed command synthesis?

20. What is the minimum manual QA matrix that must pass before 0.44.0 can ship: Claude same-cwd, Codex same-cwd, mixed Claude/Codex, crash recovery, clean Cmd+Q, and user `/exit` tombstone?
