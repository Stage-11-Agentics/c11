# C11-4: Resolve Audit Findings

From notes/c11-audit-2026-04-21.md. Track the selected audit findings only; remote CLI parity/finding 2 is intentionally excluded and should become its own work item.

Scope:

1. Fix C11 CLI resolution in live shells. `c11` and `cmux` should resolve to the active bundled CLI when inside C11, and user-facing docs/welcome examples should teach the right primary command. Add a startup/debug health check if useful.

3. Remove synchronous main-thread work from hot socket telemetry paths. Focus first on status/progress/log metadata updates and other high-frequency telemetry commands. Parse/validate off-main, enqueue minimal UI/model mutation asynchronously, and keep synchronous reads only where callers need a current answer.

6. Add/maintain an explicit security threat model for entitlement, URL handler, browser/web-content, Apple Events, camera/mic, JIT/unsigned executable memory, and socket-control behavior. Include release checklist coverage for entitlement or Info.plist changes.

Acceptance criteria:
- CLI compatibility issue is fixed or documented with a deliberate migration path.
- Telemetry hot paths no longer use raw `DispatchQueue.main.sync`; any remaining synchronous main-thread usage has an explicit justification.
- A security threat model document exists and covers the audited sensitive surfaces.
- The audit report is linked from the task record.

Out of scope:
- Audit finding 2 / remote daemon CLI parity.
