## Evolutionary Code Review
- **Date:** 2026-05-03T17:49:00Z
- **Model:** Gemini 1.5 Pro
- **Branch:** c11-24/health-cli
- **Latest Commit:** cdc51c278ddf7bd31ac0c0c540b614d4ee5c1e92
- **Linear Story:** C11-24
- **Review Type:** Evolutionary/Exploratory
---

**What's Really Being Built**:
You aren't just building a CLI diagnostic tool for a human operator; you are building an "Immune System API" or an "Observability Seam" for the operator:agent pair. By normalizing crash logs, MetricKit payloads, Sentry envelopes, and launch sentinels into a single, queryable `HealthEvent` timeline (especially via the `--json` flag), you give agents self-awareness of the host environment's stability. It transitions application crashes from being "opaque host failures" to "queryable context" that an agent can parse and act upon.

**Emerging Patterns**:
1. **The Universal Timeline Pattern**: Mapping four wildly different OS and SDK data models (Sentry cache paths, IPS formats, JSON diagnostics) into a unified `(timestamp, rail, severity, summary, path)` abstraction. 
2. **Graceful Host-Tolerant Parsing**: Using extensive `try?` and skipping missing files/directories gracefully. This pattern assumes the host file system might be fundamentally broken or pristine and still yields a valid payload without aborting.
3. **Core/Shell Segregation**: `HealthCommandCore.swift` is pure logic decoupled from the CLI argument parsing and decoupled from the Sentry SDK. It perfectly positions this logic to be consumed directly by the socket/daemon in the future.

**How This Could Evolve**:
- **Socket Streaming (Live Immune System)**: Right now it is point-in-time polling via CLI (`c11 health`). As the core is already dual-targeted, the daemon could continuously monitor these rails and broadcast `system.health_events` over the socket, allowing agents to instantly react to OOMs or hangs without needing to poll.
- **The 5th Rail (Agent Telemetry)**: If `c11` is the orchestrator, it should also track agent health. Adding an "Agent Rail" where agents drop their own crash/panic JSONs into a known directory would make `c11 health` the ultimate timeline for both host and tenant failures.

**Mutations and Wild Ideas**:
- **Agent-Driven Auto-Triage**: Instead of the operator manually running `c11 health` when things act weird, agents could automatically execute `c11 health --since 5m --json` upon detecting an unexpected shell exit or pane failure, attaching the result to their context window before deciding to retry or report the failure to the user.
- **Cross-Machine Health / Fleet View**: The architecture allows passing a `home` parameter. This implies we could mount or sync the `Library` folder of a remote machine and use the local `c11` CLI to diagnose remote agents. It opens the door to a `c11 health --remote <ssh-target>` variant.

**Leverage Points**:
- **The `--json` flag**: This single addition turns a human-readable table into an API. It is the highest-leverage decision in the PR because it directly enables agent-driven consumption.
- **The `home` parameter injection**: Makes testing trivial, but strategically opens the door for offline or remote diagnostics snapshots.

**The Flywheel**:
- **Self-Healing Loop**: If agents are taught (via the c11 SKILL) to read `c11 health` on failure, they generate better, highly-contextual failure reports for the operator or the orchestrator. This leads to quicker fixes to the environment, allowing agents to run longer without dying. The observability compound success.

**Concrete Suggestions**:

1. **High Value**: Update the `SKILL.md` (Agent operating skill) to explicitly teach agents to invoke `c11 health --json --since 15m` when a sub-process crashes or a pane exits unexpectedly.
   - ✅ Confirmed — The `--json` output makes this perfectly parseable by agents today. No code changes needed, just a documentation/prompting update in `skills/c11/SKILL.md`.

2. **Strategic**: Add an `agent` rail (the 5th rail). Introduce a designated folder like `~/Library/Logs/c11/agents/` where agents can drop standard crash/failure payload JSONs. `scanAgent()` would pick these up just like MetricKit.
   - ✅ Confirmed — `HealthEvent.Rail` can easily be expanded, and the file-parsing pattern established for MetricKit/Sentinel fits this perfectly. This makes the four scanner functions more uniform by setting up a template for the 5th.

3. **Experimental**: Expose the `HealthCommandCore` logic through a v2 Socket Method (e.g., `system.health`).
   - ❓ Needs exploration — Since `Sources/HealthCommandCore.swift` is dual-target, the main c11 app can call it directly and serve it to socket clients without shelling out to the `c11 health` CLI command. It's a quick win for programmatic access but needs to ensure it doesn't block the main thread during heavy I/O sweeps.