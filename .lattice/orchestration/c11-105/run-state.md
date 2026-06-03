# Run state — C11-105 (socket-unlink diagnostic)

**Started:** 2026-05-18
**Architect:** condensed into the C11-103 Orchestrator's investigation conversation (this same chat)
**Orchestrator:** agent:claude-opus-4-7 (this session, surface:7 "C11-103 Orch", doubling as C11-105 dispatcher)
**Operator:** atin

## Configuration

| Setting | Value |
|---|---|
| Autonomy level | **Moderate** |
| Concurrent delegator cap (N) | 1 (single-ticket run) |
| Master Validator | off |
| Result Validator | off (the diagnostic output IS the audit — the watcher's log either names the unlinker or doesn't) |
| Ticket fidelity | already-Verbose (C11-105 description + amendment carries the full plan) |
| C11 detection | yes (`C11_SHELL_INTEGRATION=1`) |

## SPEC + BUILDPLAN sources

Phase 1 collapsed — the artifacts already exist:

- **SPEC**: Lattice ticket **C11-105** description + the **2026-05-18 amendment comment** posted earlier this evening. The amendment is authoritative on scope: this is a DIAGNOSTIC ticket. The "Fix shape (sketch)" section in the original description is speculative and should be treated as background, not requirements.
- **BUILDPLAN**: this `run-state.md` `## Implementation plan` section.

## Lattice ticket

**C11-105** (`task_01KRYXGVPQVVD8WM75037YPWJP`) — type=bug, priority=high, complexity=medium, tags=`socket,ipc,debug-build,shutdown`.

## Implementation plan (for the delegator)

**Goal:** ship a tool + runbook that lets ANYONE reproduce the socket-vanish bug and capture which process unlinked the socket file. The delegator does NOT need to identify the culprit themselves — they need to make it cheap for someone (operator, future agent) to do so.

### Deliverable: socket watcher + runbook

1. **A watcher tool** that monitors `~/Library/Application Support/c11/c11.sock` for delete/rename/revoke events. When the path disappears, the watcher captures:
   - Timestamp (microsecond precision)
   - System state snapshot: `lsof` output for any process referencing the path or its parent dir; `ps -ax | grep -iE "c11|cmux"` to catalog c11-family processes alive at that moment
   - The watcher's own log line, structured (JSON or TSV) so post-processing is easy

   Implementation choice is the delegator's call. Recommended: a small Swift CLI under `scripts/` or `Tools/` using **kqueue + EVFILT_VNODE + NOTE_DELETE|NOTE_RENAME|NOTE_REVOKE**. macOS-native, no special permissions, no external deps. Alternative: a shell wrapper around `fs_usage` (system-wide syscall trace; names the unlinker directly but needs `sudo` and System Integrity Protection exceptions). If the delegator picks `fs_usage`, document the sudo requirement in the runbook clearly. A kqueue Swift watcher plus `lsof` snapshotting is probably the right 80/20.

2. **A reproduction runbook** at `docs/c11-socket-unlink-diagnostic.md` (or similar) that walks the operator through:
   - Building and running the watcher in a background terminal
   - Triggering candidate scenarios (launch tagged debug build → quit it; Sparkle-style update simulation; etc.)
   - Reading the watcher's log to identify the unlinker
   - What to do with the finding (file a follow-up fix ticket with the actual PID/process named)

3. **A short note in `code/c11/CLAUDE.md`** under Pitfalls (or the existing C11-105 reference) pointing at the runbook so future agents who hit "Socket not found" know the workaround AND know how to chase root cause.

### Watcher design constraints (for the delegator)

- **Polling rate vs. event-driven.** kqueue is event-driven, fires immediately on delete. Don't add a polling loop for the path itself — kqueue handles it.
- **`lsof` snapshotting** at the moment of the event is the cheapest way to capture "who had the socket open." Run it as a subprocess synchronously inside the event handler. Worth grabbing `ps` simultaneously to catalog all c11/cmux processes (including ones that may have exited milliseconds later).
- **Re-arm.** After the socket file is deleted, the kqueue watch dies (the vnode is gone). The watcher should re-arm by watching the parent directory for NOTE_WRITE events and re-watching the file once it reappears — so a single watcher process can survive multiple bounces.
- **Output format.** JSON Lines (one event per line) is the right shape. Each line: `{"ts": "<iso8601>", "event": "delete|rename|revoke|rebound", "lsof": [...], "ps": [...]}`. Pretty-print on terminal is fine for the operator's eyeball; the JSON Lines is for grepping/scripting.
- **Tests.** Per c11 test quality policy: a `c11LogicTests` test that builds a temp socket file, runs the watcher against it in-process (or as a subprocess with a tempdir-scoped target), unlinks the file, and asserts the watcher emitted a delete event. Don't grep source code or assert tool-file existence.

### Out of scope for this PR

- The actual fix. C11-105's amendment is explicit: file a follow-up ticket once the watcher names the culprit. This PR does NOT touch `SocketControlSettings.swift` or any other shutdown code.
- A general-purpose filesystem-watcher abstraction. The tool is single-purpose: watch the c11 socket path. Don't generalize.
- Catching the unlinker via DTrace / Endpoint Security. Both would be more direct, but the permissions cost is high. kqueue + lsof is sufficient because the suspect set is bounded (c11 family processes + Sparkle).

## Workspace panes (c11 refs)

- orchestrator: workspace:3 / pane:6 / surface:7 (this surface, "C11-103 Orch" doubling as C11-105 dispatcher)
- delegate_view_area: pane:7 (already hosts C11-103 D1 on surface:14, C11-99 D1 ABD on surface:9, C11-99 D2 C-stab on surface:11; C11-105 delegator joins as a new tab on surface:17)
- control_surface: none (single-ticket run; operator reads Lattice status directly)

## Decision log (append-only)

- 2026-05-18 — C11-105 filed earlier; amendment comment posted after source-grep failed to confirm the original hypothesis. Scope re-cast as "diagnostic, not fix."
- 2026-05-18 — Configured Moderate autonomy / N=1 / Master Validator off / Result Validator off.
- 2026-05-18 — Worktree `code/c11-worktrees/c11-105-socket-diag` on branch `diag/c11-105-socket-watcher`, anchored to `origin/main` @ `7cbc27d31`.
