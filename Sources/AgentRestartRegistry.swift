import Foundation

/// UUIDv4 (Claude SessionStart `session_id`) grammar. Must match the exact
/// 8-4-4-4-12 hex shape with dashes. Anchored so any non-matching suffix or
/// prefix — shell metacharacters, embedded newlines, extra tokens — is
/// rejected. Declared `nonisolated` and file-scoped so
/// `SurfaceMetadataStore.validateReservedKey` (off the main actor) and the
/// `AgentRestartRegistry.phase1` resolver closure (Sendable) can share one
/// compiled regex without cross-actor traffic.
///
/// Defence in depth: the store rejects malformed writes at the boundary;
/// the registry re-validates at synthesis time so a value that somehow
/// slipped past the store (direct in-process writer, future bypass) still
/// cannot become a shell command.
let claudeSessionIdUUIDPattern: NSRegularExpression = {
    // swiftlint:disable:next force_try
    return try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        options: []
    )
}()

/// Returns true iff `candidate` matches the UUIDv4 shape exactly.
/// Trims nothing — callers are expected to normalise whitespace before
/// calling (the registry does, the store's reserved-key validator does not
/// because values it receives have already passed `WriteMode` normalisation).
func isValidClaudeSessionId(_ candidate: String) -> Bool {
    let range = NSRange(location: 0, length: (candidate as NSString).length)
    return claudeSessionIdUUIDPattern.firstMatch(in: candidate, options: [], range: range) != nil
}

/// Pure-value lookup table mapping a known terminal type + session hint to
/// the shell command that resumes it. Phase 1 ships a single row for
/// `claude-code`; rows for `codex`, `opencode`, `kimi` land in Phase 5
/// without schema changes.
///
/// The registry is **not Codable**. It flows through
/// `ApplyOptions.restartRegistry` as an in-process reference and is resolved
/// by name at the v2 handler boundary (`"phase1"` → `.phase1`). Keeping it
/// out of the wire format prevents snapshot files from locking in a specific
/// registry version — a snapshot written today stays restorable after Phase
/// 5 adds rows, because the registry is resolved app-side at restore time.
struct AgentRestartRegistry: Sendable {
    struct Row: Sendable {
        /// Canonical `terminal_type` string, matching the value written by
        /// `c11 set-agent --type <type>` and surfaced by the sidebar chip.
        let terminalType: String
        /// Pure resolver. Returns the command to run, or `nil` to decline
        /// (e.g., required session id missing). `metadata` is the full
        /// string-valued surface-metadata map; future rows may consult
        /// additional keys without schema changes.
        let resolve: @Sendable (_ sessionId: String?, _ metadata: [String: String]) -> String?

        init(
            terminalType: String,
            resolve: @escaping @Sendable (_ sessionId: String?, _ metadata: [String: String]) -> String?
        ) {
            self.terminalType = terminalType
            self.resolve = resolve
        }
    }

    /// Stable identity for `Equatable` comparisons. The registry carries
    /// closures (not `Equatable`); callers (the v2 handler, tests) identify
    /// a registry by the name it was minted with — `"phase1"` for the
    /// canonical singleton, test-chosen names for fixtures.
    let name: String
    private let rowsByType: [String: Row]

    init(name: String, rows: [Row]) {
        self.name = name
        var map: [String: Row] = [:]
        // Trim on insert to match the symmetric trim in `resolveCommand`;
        // avoids an asymmetric-trim footgun where a row registered with
        // surrounding whitespace is silently un-resolvable.
        for row in rows {
            let key = row.terminalType.trimmingCharacters(in: .whitespacesAndNewlines)
            map[key] = row
        }
        self.rowsByType = map
    }

    /// Consult the registry. Returns `nil` when the type is unknown or the
    /// matching row declines. Pure; never mutates.
    func resolveCommand(
        terminalType: String?,
        sessionId: String?,
        metadata: [String: String]
    ) -> String? {
        guard let type = terminalType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !type.isEmpty,
              let row = rowsByType[type] else { return nil }
        return row.resolve(sessionId, metadata)
    }

    /// Names the executor handler accepts in `snapshot.restore` params.
    /// `"phase1"` → `.phase1`; unknown names resolve to `nil` so an
    /// unrecognised wire value silently falls back to Phase 0 behavior
    /// rather than erroring the restore.
    static func named(_ name: String?) -> AgentRestartRegistry? {
        switch name {
        case "phase1": return .phase1
        default: return nil
        }
    }

    /// Phase 1 ships claude resume. Phase 5 added codex / opencode / kimi rows.
    ///
    /// The claude closure re-validates `sessionId` against the UUIDv4 grammar
    /// even though `SurfaceMetadataStore` already rejects non-UUID writes for
    /// the `claude.session_id` reserved key. The "never trust the metadata
    /// layer solely" belt-and-braces is deliberate: the synthesised string
    /// is interpolated into a shell command that runs on restore, and any
    /// future in-process writer that bypasses the store must not become a
    /// command-injection vector.
    ///
    /// The trailing `"\n"` is part of the row's output: the registry
    /// returns the **submit form** of the command, not the typed form.
    /// How to submit is the registry's concern, not the executor's —
    /// otherwise every executor caller would have to remember to append
    /// one. Without it, `TerminalPanel.sendText` writes the bytes verbatim
    /// and the command sits at the prompt unexecuted. Phase 5 rows for
    /// codex/opencode/kimi follow the same "return submit form" contract.
    ///
    /// Use `claude --dangerously-skip-permissions --resume <id>` rather than
    /// `cc`: `cc` resolves to the C compiler in c11 terminal environments,
    /// not Claude. The c11 wrapper at `Resources/bin/claude` intercepts the
    /// command, sees `--resume`, skips its own `--session-id` injection, and
    /// forwards to real claude with the hooks settings JSON intact.
    ///
    /// Codex uses `--last` best-effort to resume the most recent session
    /// globally. Opencode and kimi have no verified resume flag and launch
    /// fresh — best-effort is preferable to a broken flag.
    static let phase1: AgentRestartRegistry = .init(name: "phase1", rows: [
        Row(terminalType: "claude-code") { sessionId, _ in
            guard let raw = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  isValidClaudeSessionId(raw) else { return nil }
            return "claude --dangerously-skip-permissions --resume \(raw)\n"
        },
        Row(terminalType: "codex") { _, _ in
            // codex resume --last resumes the most recent codex session globally.
            // Best-effort: may not match the exact session in the snapshot.
            "codex resume --last\n"
        },
        Row(terminalType: "opencode") { _, _ in
            // no stable resume flag known; launches fresh.
            "opencode\n"
        },
        Row(terminalType: "kimi") { _, _ in
            // no stable resume flag known; launches fresh.
            "kimi\n"
        }
    ])
}
