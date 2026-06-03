## Critical Code Review
- **Date:** 2026-04-24T18:50:00Z
- **Model:** Gemini 1.5 Pro
- **Branch:** cmux-37/phase-1-snapshots-restore
- **Latest Commit:** 2047daff
- **Linear Story:** CMUX-37
- **Review Type:** Critical/Adversarial
---

**The Ugly Truth**: 
The implementation cleanly separates concerns—the converter is truly pure, and the `AgentRestartRegistry` design is well-considered for Phase 5 extensibility. However, it introduces a severe security flaw by exposing arbitrary filesystem paths over the socket without authorization checks. It also subtly breaks the "Phase 0 bit-exact preservation" mandate in the executor, skipping commands that Phase 0 would have executed.

**What Will Break**:
- Any agent connected to the v2 socket can execute `snapshot.create` with an explicit `path` like `~/.claude/settings.json`, overwriting it with the snapshot payload and causing data loss or DoS for the user's tools.
- An agent can use `snapshot.restore` with `snapshot_id: "../../../../etc/passwd.json"` to perform path traversal and parse arbitrary system `.json` files, leaking their contents through the parser's error messages or structural behavior.
- The executor drops `command: " "` (whitespace-only), meaning any existing test or blueprint that relied on sending spaces to the terminal will silently fail.

**What's Missing**:
- Validation of paths in `WorkspaceSnapshotStore` to prevent directory traversal and restrict socket-initiated file writes to safe locations.
- Enforcement of `withFractionalSeconds` in the JSON encoding strategy, as the design explicitly called out having fractional seconds.

**The Nits**:
- `AgentRestartRegistry.init` doesn't trim `terminalType` when populating its map, but `resolveCommand` trims the query. If a row is ever added with trailing spaces, it will be impossible to look up.
- `pendingInitialInputForTests` isn't thread-safe if `pendingTextQueue` is accessed off-main.

### Blockers
1. **Arbitrary File Write / Path Traversal over Socket**: In `TerminalController.swift`, `v2SnapshotCreate` accepts `params["path"]` and passes it to `WorkspaceSnapshotStore.write(to:)`. `v2SnapshotRestore` accepts `params["snapshot_id"]` and resolves it using `appendingPathComponent`. Since the socket is accessible to agents, a malicious agent can provide absolute paths (e.g., `/Users/user/.claude/settings.json`) to overwrite critical configuration files with the snapshot JSON, or use `../../` to read arbitrary `.json` files. The CLI needs `--out <path>`, but exposing this over the unauthenticated socket without restricting the destination directory is a critical vulnerability. ✅ Confirmed

2. **Phase 0 Executor Behavior Change**: In `Sources/WorkspaceLayoutExecutor.swift` (Step 7), Phase 0 executed `command` as long as `!command.isEmpty`. Phase 1 trims the explicit command first: `if let explicit = explicitCommand, !explicit.isEmpty`. If the command is entirely whitespace (e.g., `" "`), `explicit.isEmpty` is true, and it falls back to the registry. If the registry returns `nil`, the command is skipped. This violates the bit-exact preservation requirement for Phase 0 `c11 workspace apply` calls. ✅ Confirmed

### Important
1. **`AgentRestartRegistry` Key Trimming Mismatch**: In `Sources/AgentRestartRegistry.swift`, `resolveCommand` trims the incoming `terminalType` query, but the initializer `init(rows:)` does not trim `row.terminalType` when inserting into the `rowsByType` map. If a future Phase 5 row is added with trailing whitespace, it will silently become un-resolvable. ⬇️ Real but lower priority than initially thought

2. **Fractional Seconds Omitted**: `WorkspaceSnapshotStore.swift` sets `encoder.dateEncodingStrategy = .iso8601`. The default Swift `ISO8601DateFormatter` does not include fractional seconds. The plan specifically dictated "ISO-8601 with fractional seconds". This requires a custom formatter with `.withFractionalSeconds`. ✅ Confirmed

### Potential
1. **`ApplyOptions` Codable Fragility**: `ApplyOptions` intentionally drops `restartRegistry` during `Codable` encode/decode. While this matches the immediate plan requirements, if `ApplyOptions` is ever round-tripped for debugging or passed through another layer, the registry will silently disappear. ❓ Likely but hard to verify

2. **Test-Only Thread Safety Risk**: `pendingInitialInputForTests` iterates over `pendingTextQueue` to build a string. If the Ghostty terminal queues input on a background thread while the test reads this property, it will crash. 

---

### Closing
This code is **NOT ready for production**. The arbitrary file write vulnerability exposed through the `snapshot.create` socket method is a critical security blocker that must be fixed before this branch can be merged. The socket handlers must validate that all paths (or at least those provided by non-CLI clients, if differentiable) stay within `~/.c11-snapshots/` or a temporary directory. The executor's whitespace-skipping behavior must also be reverted to preserve Phase 0 parity. Fix the path traversal and executor logic, and it's good to go.