# Adversarial Review: Conversation Store Architecture

PLAN_ID=conversation-store-architecture  
MODEL=Codex

## Executive Summary

This plan is directionally right about the wrapper-only architecture being insufficient, but it is much too confident that a new `ConversationStore` primitive makes the observed bugs "structurally impossible." The biggest risk is that the plan moves ambiguity out of wrappers and metadata into strategy heuristics, without proving those heuristics can identify the right TUI session under real multi-pane, same-cwd, fast-typing, crash, and upgrade conditions.

The plan's load-bearing bet is "pull-scrape can reconstruct truth." That is not established. For Claude it assumes session files can be matched by cwd and freshness. For Codex it assumes cwd plus modification time plus surface activity is enough to disambiguate two sessions in the same repo. For Opencode and Kimi it explicitly does not know whether resumable state exists. If that bet fails, this becomes a larger rewrite that still ships the same user-visible failure mode: panes resume the wrong thing, resume nothing, or resume something stale with confidence.

I would not implement this as written until the plan first proves the per-TUI session identity model with fixtures or a throwaway probe. The current proposal spends many words on the generalized primitive and too few on whether the primitive can be populated correctly.

## How Plans Like This Fail

Architecture-replacement plans usually fail by solving the clean abstraction while underspecifying the dirty edge where external systems are observed. That pattern is present here. The `Conversation`, `ConversationStrategy`, and `ResumeAction` shapes are coherent, but the correctness boundary is actually the undocumented session storage of Claude, Codex, Opencode, and Kimi. The plan treats that boundary as an implementation detail to verify later, even though it is the foundation.

They also fail by converting one race into several smaller races. The current `SessionEnd` clear-on-quit race is concrete and ugly. The replacement adds autosave scraping races, launch-time claim races, activity timestamp races, shutdown sentinel races, snapshot/store synchronization races, and strategy reconciliation races. Some of those may be acceptable, but the plan does not rank them or define the invariants that make them safe.

They fail by making "best effort" look like "architecture." Codex, Opencode, and Kimi are still best-effort. The difference is that best-effort is now packaged as a strategy. That may be a better implementation shape, but it is not yet a guarantee that same-cwd Codex panes restore correctly.

They fail by underestimating lifecycle interactions. c11 already has autosave quiet periods, startup restore suppression, synchronous termination saves, stable ID rollback flags, metadata precedence, wrappers, and socket handlers. The plan adds another persistence layer but does not map exactly how its revisions participate in autosave fingerprints, restore suppression, and shutdown ordering.

They fail by shipping a new source of truth that operators cannot debug. The plan proposes provenance, `conversation list`, and `conversation get`, which is good, but it does not define the event log needed to explain "why did this pane resume that session?" Without a replayable decision trace, the first wrong resume will be hard to diagnose.

## Assumption Audit

The most load-bearing assumption is that TUI on-disk session files contain enough stable, parseable, non-private metadata to map a session to a c11 surface. This is unproven in the plan. "Path verified at impl" is not sufficient for a proposal whose central fix depends on scraping those paths.

The second load-bearing assumption is that cwd is an acceptable discriminator. c11's actual failure case includes two Codex panes in the same project. For agent workflows, same-cwd parallel panes are common, not edge cases. The plan adds modification time and last activity timestamp, but does not define how c11 records last activity per surface, whether that timestamp survives restore, whether background TUI writes count, or how clock granularity affects ties.

The third load-bearing assumption is that modification time corresponds to "the conversation this surface is hosting." That may fail if a TUI rewrites indexes, touches files in batches, buffers writes, syncs cloud state, compacts histories, or updates a global metadata file rather than the per-session transcript.

The fourth is that hooks and scrapes can be reconciled by latest `capturedAt`. Hook time, file mtime, monotonic process uptime, wall-clock time, and autosave time are not the same clock. The plan does not say which clock `capturedAt` uses for scrape-derived refs or how it handles timestamp skew, coarse filesystem mtimes, or TUI files whose mtime updates after SessionEnd.

The fifth is that a wrapper claim with `<surface-uuid>:<launch-ts>` is harmless. It creates an ID that is not a real conversation ID, will be persisted, and must never leak into resume. Every code path that consumes `ConversationRef.id` now needs to understand placeholder-ness, despite the schema saying `id` is opaque to the store.

The sixth is that "snapshot is source of truth" is compatible with a live store mutated by off-main socket handlers and autosave scrapes. The plan says the store has a serial queue, but snapshot capture is synchronous today during termination. The plan does not specify whether termination blocks on in-flight scrapes or drops them.

The seventh is that c11 can reliably distinguish user `/exit` from app shutdown via `isTerminatingApp`. That covers graceful app termination, but not terminal close, pane close, workspace close, shell exit, TUI crash, kill from Activity Monitor, or c11 crash while the hook subprocess is still running.

The eighth is that `shutdown_clean` can detect crash state. A one-byte marker at `~/.c11/runtime/shutdown_clean` is global, but c11 supports tagged/dev builds and multiple windows, and current snapshot storage is under Application Support with bundle-id scoping. A global marker can cross-contaminate builds or instances unless the instance identity is defined.

The ninth is that strategies are pure. A strategy that scrapes the filesystem, stats directories, checks app termination state, and interprets external session stores is not pure in the meaningful sense. If "pure" only means "no internal mutable state," the plan should say that; otherwise the purity claim obscures test and concurrency requirements.

The tenth is that no migration is acceptable because this is pre-release. That may be true for snapshot schema, but PR #89 already shipped opt-in in 0.43.0 and default-on in 0.44.0-pre according to the plan. Users or internal QA may have snapshots with `claude.session_id`; the one-release compatibility path needs more precision than "read once."

## Blind Spots

Privacy and data minimization are underdeveloped. Scraping `~/.claude/sessions` and `~/.codex/sessions/*.jsonl` can easily read transcript content, prompts, file paths, model names, and possibly secrets. The plan says lightweight stat unless newer, but the strategy still may need to inspect content to match cwd or extract session IDs. It needs a strict "metadata only" contract, size limits, redaction rules, and a statement about never persisting transcript snippets into c11 snapshots.

Security is underdeveloped. `ResumeAction.typeCommand(text:)` reintroduces command synthesis. Claude IDs currently have UUID validation. Codex IDs and future strategy IDs are opaque. The plan must define per-strategy shell-escaping or avoid shell text entirely by using argv-based process launch where possible. "Opaque id" plus "type a shell command containing id" is a command injection trap unless every strategy owns validation and escaping.

The plan does not account for user intent at restore time. Auto-resuming an agent is not always wanted after a crash or restart. The current global flag is coarse. There is no per-surface "do not resume this" state, no stale-age threshold, no prompt for unknown confidence, and no way to distinguish "resume after app relaunch" from "restore the room but leave agents idle."

Confidence is missing from the schema. `capturedVia` and `state` are not enough. A hook-captured Claude session ID has high confidence. A Codex scrape selected by cwd plus timestamp among two candidates has lower confidence. A wrapper claim has near-zero confidence. The resume path should treat those differently.

Conflict handling is missing. What if two surfaces claim the same conversation ref? What if one surface has two plausible Codex session files? What if a session file matches a deleted surface and a live surface? What if the global index sees the same ref in multiple snapshots? The plan does not define uniqueness constraints or conflict resolution beyond latest timestamp wins.

Deletion semantics are vague. Tombstoned refs move to history later, absent-on-restore means tombstoned for hookless TUIs, `conversation clear` exists, snapshots are source of truth, and global index is derived. The plan does not say when tombstones are pruned, whether they persist forever, or how clearing a surface interacts with old snapshots that still contain the ref.

Observability is too shallow. `conversation list/get` answers current state. It does not answer why a decision happened. The system needs a bounded decision log: claim received, scrape candidates considered, candidate rejected reasons, selected ref, resume action emitted, resume action skipped, tombstone reason.

Rollback is underspecified. "No feature flag for the architecture" is brave but brittle. The existing `agentRestartOnRestoreEnabled` flag only disables resume; it does not disable scraping, conversation writes, snapshot schema changes, hook routing changes, wrapper claims, or state transitions. If the store corrupts snapshots or misattributes refs, the rollback path needs more than "do not execute resume."

Testing is not realistic enough. Unit tests over fixture session-storage layouts are necessary but insufficient. The core risk is timing: two panes, same cwd, both active, quit while hooks fire, restart, crash, and resume. The plan relegates that to manual QA. That is exactly the bug class that will regress.

The plan does not discuss performance budgets in c11's typing-latency-sensitive environment. It mentions one `stat` per TUI per autosave per surface, but current autosave is every 8 seconds, not "~30 s" as the open question suggests. With 30 agent panes and multiple strategies, even "small" filesystem work and fingerprint invalidation can become visible if routed poorly.

The plan does not clearly separate in-bundle wrapper behavior from tenant config behavior. Claude hook injection via wrapper is allowed under the current rules, but `c11 claude-hook` compatibility and "existing hook configurations keep working" can sound like persistent external hook configurations are supported. The plan should explicitly preserve the "no tenant config writes" boundary.

## Challenged Decisions

I challenge the decision to make scraping part of every autosave tick. Autosave already has careful fingerprinting and typing quiet periods. Conversation scraping has different freshness needs and different cost. It should probably have its own scheduler, debounce, and per-strategy budget rather than piggybacking on snapshot autosave.

I challenge "latest `capturedAt` wins." Latest is not truth. A wrapper claim can be later than a valid hook. A session file can be touched after user exit. A background compaction can update a stale file. A manual ref may intentionally override automatic capture despite being older. Reconciliation needs source-specific semantics, not a universal timestamp rule.

I challenge the placeholder ID design. A `ConversationRef` should either point to a resumable conversation or explicitly represent "unresolved claim." Encoding unresolved state as a fake ID forces every downstream consumer to know a convention the schema hides. Use a separate `Claim` type or make `id` optional while state is `unknown`.

I challenge the state machine. It is too small for the lifecycle it models. It lacks at least `claimed`, `resumable`, `ambiguous`, `failed`, and `disabled`. `unknown` is overloaded: crash recovery unknown, wrapper claim unknown, unregistered strategy unknown, and stale snapshot unknown are different states requiring different UI and resume behavior.

I challenge the claim that "a new kind is one Swift file implementing two functions. No app-wide changes." That is not true once CLI help, wrapper packaging, strategy registration, tests, Localizable strings, diagnostics, and maybe bundle PATH behavior are included. The statement encourages under-scoping future integrations.

I challenge `ResumeAction.launchProcess(argv:env:)` as a v1 abstraction unless the existing terminal panel can actually replace the shell process safely. The current stopgap sends commands into an already-running shell. Launching a process inside a terminal surface is a different lifecycle operation with cwd, env, shell integration, PTY ownership, and UI implications.

I challenge `ResumeAction.replayPTY`. No v1 strategy emits it, and the code sketch references `appendScrollback`, which may not be a real public operation in the current terminal surface API. Keeping speculative actions in the architecture increases implementation surface without reducing the current risk.

I challenge "no migration." The plan also says backward-compat reads `claude.session_id` once. That is a migration, just an opportunistic one. It needs exact behavior: which snapshots, which surfaces, what state, what source, how conflicts with conversation refs are resolved, and when the compatibility path is removed.

I challenge "no feature flag for the architecture." Replacing wrapper hook semantics, adding filesystem scraping, adding snapshot fields, and adding resume decisions is enough blast radius to warrant at least a kill switch for capture and scrape separately from execution.

I challenge putting `surface_conversations` at workspace level keyed by `surface_id` while also preserving stable panel IDs via feature flag. The plan needs to explain how this behaves when stable panel IDs are disabled, when old-to-new remaps are used, and when tabs/surfaces are moved between panes or workspaces before autosave.

I challenge the global derived index as v1 in-memory work. It is not needed to fix the observed bug. Scanning all snapshots at launch adds cost and another correctness surface. If it is future UI scaffolding, it should probably be deferred until the store proves itself.

## Hindsight Preview

Two years from now, the likely regret is that c11 built a generic conversation abstraction before it had strong per-TUI identity proofs. The right sequence may have been: instrument current wrappers, build a Codex session attribution probe, prove same-cwd disambiguation, then generalize.

Another likely regret is that "opaque id" was too loose. Resume correctness and command safety require each kind to define ID grammar, provenance, confidence, and resume quoting rules. Treating the ID as an untyped string will age badly.

Another likely regret is relying on cwd as a primary correlation key. Agent workflows often intentionally run many panes in the same cwd. The plan should expect same-cwd concurrency as the default case, not the degenerate one.

Another likely regret is mixing state capture and user-facing auto-resume. Capturing conversation refs is mostly safe. Executing them on launch is invasive. The design should keep those rails independently controllable from day one.

Another likely regret is insufficient event history. When a user sees a wrong resume, current state will not be enough. The system needs to show the candidates and why one was chosen.

Early warning signs: multiple candidates per surface in scrape logs; wrapper claims surviving longer than one autosave; repeated `unknown` states after clean shutdowns; two surfaces sharing one ref; resume commands skipped for missing strategies; high scrape latency during autosave; user disabling agent restart after wrong resumes; support notes saying "delete your snapshots" to recover.

## Reality Stress Test

Disruption one: Codex changes its session file format or write cadence. The Codex strategy starts failing silently or selecting stale sessions. Since Codex has no hook, there is no independent high-confidence signal. The plan needs schema/version detection, candidate logging, confidence downgrade, and a graceful "do not auto-resume ambiguous Codex panes" mode.

Disruption two: the operator runs 20 to 30 agents in the same repo during a release crunch. Autosave scraping now has many same-cwd candidates, many recent mtimes, and high terminal activity. The exact scenario c11 is built for becomes the hardest case for the heuristic. If the plan cannot restore that room accurately, it misses the product's core use case.

Disruption three: 0.44.0 needs to ship with upstream picks and a held release. The conversation-store implementation touches wrappers, CLI, socket handlers, snapshot schema, restore scheduling, app termination, tests, and docs. Under release pressure, the likely cut is validation depth. That means the architecture lands with fixture tests and manual QA only, then field usage discovers the hard timing bugs.

When these hit simultaneously, the failure mode is not dramatic data loss. It is worse for trust: c11 confidently resumes the wrong agents into the wrong panes, maybe in the same repo, with plausible-looking sidebar metadata. Operators will stop trusting auto-resume.

## The Uncomfortable Truths

The plan says the wrapper-only pattern cannot capture what the TUI does not expose, but the proposed architecture also cannot capture what the TUI does not expose. It can only infer. That distinction matters.

The Codex fix is still speculative. Until there is a proven way to map a Codex session file to a surface under same-cwd parallel use, the core observed bug is not fixed; it is assigned to a future strategy.

"Structurally impossible" is oversold. The architecture can make `codex resume --last` go away. It cannot make wrong attribution impossible unless session identity is deterministic.

The plan's abstraction is cleaner than the current implementation, but cleanliness is not the scarce resource here. Ground truth is.

The release ambition is too high. Making this the 0.44.0 marquee feature while also carrying 25+ upstream picks invites a broad, late, hard-to-debug diff in lifecycle code.

The plan may be trying to solve future cloud/remote/history UX before proving local resume. Remote/cloud forward-compat is intellectually appealing, but it should not drive the v1 shape if local session attribution remains uncertain.

The current proposal does not yet meet c11's "operator running eight, ten, thirty agents" bar. It describes how to restore one active conversation per surface, but not how to prove correctness in a crowded room where many agents share cwd, model, TUI, and timestamps.

## Hard Questions for the Plan Author

1. What exact fields exist in Claude and Codex session files today, and which of those fields are stable enough to rely on without reading transcript content?

2. In the two-Codex-panes-same-cwd failure that motivated this plan, what concrete data lets the strategy distinguish pane A's session from pane B's session?

3. What is the false-positive policy? If a strategy has two plausible session candidates, should c11 resume one, skip both, or ask the operator?

4. What confidence level is required before auto-resume executes a command in a terminal?

5. Why is latest timestamp the right reconciliation rule when sources have different reliability and clocks?

6. How is per-surface "last activity timestamp" defined, captured, persisted, and tested? Does terminal output count? Does user typing count? Does background process output count?

7. How do you prevent a fake wrapper-claim ID from ever being passed to `resume(surface, ref)`?

8. Why is `id` non-optional if a wrapper claim can create a ref before a real conversation ID exists?

9. What is the shell-injection defense for non-Claude IDs used in `typeCommand` resume actions?

10. Can `ResumeAction.launchProcess` actually be implemented against today's `TerminalPanel` without changing terminal process ownership semantics?

11. What happens if two surfaces resolve to the same conversation ID? Which one wins, and how does the operator see the conflict?

12. What happens if a conversation ref is present in an old snapshot, then the user clears it in the current workspace, but the derived index rebuilds from both snapshots?

13. Is `~/.c11/runtime/shutdown_clean` scoped correctly for tagged builds, dev builds, multiple bundle IDs, and multiple running c11 instances?

14. Why does the plan say autosave is "~30 s" when current `SessionPersistencePolicy.autosaveInterval` is 8 seconds?

15. How many filesystem operations does one autosave scrape do with 30 terminal surfaces and four registered strategies?

16. Does conversation store mutation participate in the existing autosave fingerprint? If not, how do conversation-only changes get persisted promptly? If yes, how do you avoid increasing autosave churn?

17. During `applicationShouldTerminate`, do we block until in-flight strategy scrapes finish, cancel them, or snapshot the previous store state?

18. How does `conversation tombstone` query `isTerminatingApp` without adding a socket method that can race with termination?

19. What is the behavior for pane close, surface close, workspace close, and shell exit? Are those tombstones, suspensions, clears, or history entries?

20. What exact event log will let us debug "why did this pane resume this session" after the fact?

21. Why is the global derived index in v1 at all if no v1 UI consumes it and snapshots are the source of truth?

22. What is the rollback plan if scraping causes wrong resumes but the new snapshot field has already shipped?

23. Should capture, scrape, tombstone, and resume execution have separate feature flags rather than one global resume flag?

24. What privacy guarantee can we make about scraping TUI session directories? What data is read, what data is persisted, and what data is logged?

25. Are Opencode and Kimi in scope for a real improvement, or are they included mostly to justify the abstraction? If they remain fresh-launch-only, say that plainly.

26. What automated test reproduces the exact 4-pane staging QA failure and proves this architecture fixes it?

27. What automated test covers same-cwd Codex panes without depending on the live Codex binary?

28. What user-visible state appears when a strategy is missing, ambiguous, disabled, or low-confidence?

29. What is the minimum version-specific compatibility matrix for Claude Code and Codex? What happens when users upgrade either TUI independently of c11?

30. If implementation discovers that Codex session attribution cannot be made reliable, does the architecture still ship? If yes, what claim does the release note make?
