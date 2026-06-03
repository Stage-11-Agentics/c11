# Adversarial Plan Review

### Executive Summary
The proposed Conversation Store Architecture is a pragmatic but inherently fragile attempt to solve the session resume problem. While it successfully moves state management out of ephemeral, race-prone metadata hooks, it replaces them with a heavy reliance on reverse-engineered, undocumented internal state of third-party TUIs. The system's resilience is entirely dependent on the filesystem stability of tools we do not control. The single biggest issue is elevating "scraping" from a fallback hack to a load-bearing architectural pillar.

### How Plans Like This Fail
Efforts that attempt to synthesize a cohesive state machine from a mix of push events (hooks) and pull polling (scraping) usually fail at the seams.
1. **The Polling Trap:** Polling internal state (the autosave scrape) means there is always a window of staleness.
2. **Third-Party Coupling:** Plans like this fail when the third party (Claude, Codex) updates their internal storage mechanisms. We are building a formal API on top of an informal, undocumented data structure.
3. **Complex Reconciliation:** Fusing push and pull signals often leads to "last-writer-wins" bugs where a delayed scrape overwrites a fresh push, or a stale push overrides a valid scrape due to clock skew.

### Assumption Audit
- **Assumption:** TUI session file locations and formats (e.g., `~/.codex/sessions/*.jsonl`) will remain stable across versions.
  - *Likelihood to hold:* Low. These are internal implementation details, not public APIs. (Load-bearing)
- **Assumption:** The `isTerminatingApp` flag perfectly captures the nuance of c11's shutdown sequence without race conditions against TUI exit hooks.
  - *Likelihood to hold:* Medium. macOS termination can be messy. If a TUI gets a SIGTERM slightly before c11 sets `isTerminatingApp`, the session will be erroneously tombstoned. (Load-bearing)
- **Assumption:** Scraping the filesystem every 30 seconds per surface is lightweight enough to avoid performance degradation.
  - *Likelihood to hold:* High for local SSDs, but Low for network mounts, heavily loaded systems, or power-constrained states. (Cosmetic but risky)
- **Assumption:** For hook-less TUIs, CWD + modification time is a reliable heuristic to map a session to a specific pane.
  - *Likelihood to hold:* Medium. It breaks down entirely if two panes in the same CWD are interacting simultaneously.

### Blind Spots
- **Filesystem Event Alternatives:** The plan completely ignores `FSEvents` or `kqueue` for monitoring session directories, opting instead for a primitive 30s polling loop.
- **Multiple Instances:** How does this architecture behave if two instances of c11 are running and trying to manage the same `~/.c11-snapshots/` or `~/.c11/conversations.index.json`?
- **Tombstone Un-detection:** The plan states "Codex... treats every absent-on-restore session-file as `tombstoned`." What if the disk is temporarily unreadable or a remote mount drops? The conversation is irrevocably tombstoned due to a transient read error.
- **Sandboxing/Permissions:** Future macOS updates or TUI sandboxing might prevent c11 from reading `~/.claude/sessions/` entirely.

### Challenged Decisions
- **Decision:** Implementing "Pull-scrape" inside the core Swift strategy.
  - *Counterargument:* This couples the core architecture to external implementation details. If scraping is necessary, it should be externalized to the wrapper scripts or a configuration layer so it can be updated independently of c11 releases.
- **Decision:** 30s polling cadence for autosave scrape.
  - *Counterargument:* Polling is the wrong primitive here. Use filesystem watchers (`FSEvents` or `kqueue`). If the goal is to be lightweight, doing nothing until the OS notifies you of a change is strictly better than waking up a thread every 30 seconds to `stat` files.
- **Decision:** Falling back to "focused-surface" silent misroute footgun removal.
  - *Counterargument:* Are there external dependencies on this behavior? While the change makes sense internally, it could unexpectedly break scripts outside c11's immediate control that have come to rely on this.

### Hindsight Preview
In two years, we will look back and regret hardcoding `~/.codex/sessions/*.jsonl` into the Swift source code. We will realize that we traded the fragility of metadata hooks for the fragility of filesystem scraping. The early warning signs will be an uptick in GitHub issues stating "Codex session resume broken on vX.Y.Z" immediately following an upstream release of the Codex CLI.

### Reality Stress Test
Imagine this scenario:
1. Codex updates its session format to use a SQLite database instead of JSONL.
2. The user has two Codex panes open in the same project root (`CWD`), both being actively modified.
3. c11 experiences a hard crash (power loss).

*Result:* On restart, c11 lacks the `shutdown_clean` marker and falls back to the pull-scrape for crash recovery. The scrape fails entirely because it's looking for JSONL files. The fallback assumes the sessions are gone and tombstones them. The user silently loses both active sessions. Even if the file format hadn't changed, the heuristic of CWD+mtime fails to disambiguate the concurrent panes reliably.

### The Uncomfortable Truths
- We are not actually decoupling from the TUIs; we are just shifting the coupling from environment variables to their internal file formats.
- The Codex implementation is entirely best-effort and will demonstrably fail to restore the correct session if multiple panes share a directory.
- We are building a complex state machine to compensate for the fact that these TUIs simply do not have the integration APIs we need.

### Hard Questions for the Plan Author
1. How do we detect and gracefully handle upstream TUI changes that break our hardcoded scraping logic? (Currently, "we don't know").
2. Why rely on a 30s polling loop (`stat`) instead of using efficient filesystem monitoring (`FSEvents`)?
3. What is the explicit fallback if `isTerminatingApp` evaluates to false, but the TUI was killed as part of an abrupt system shutdown or window-close cascade?
4. For hook-less TUIs like Codex, if two panes share a CWD and are used concurrently, how can you guarantee the "latest modified" file maps to the correct pane?
5. If the `~/.claude` directory becomes unreadable due to permissions, does the architecture correctly suspend the state, or does it erroneously tombstone it?
