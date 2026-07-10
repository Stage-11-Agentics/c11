import Foundation

/// Push-primary strategy for Claude Code. The wrapper at
/// `Resources/bin/claude` injects `--session-id` and the SessionStart hook
/// reports the real session id via `c11 conversation push --kind claude-code`.
/// Identity is deterministic; resume types
/// `claude --dangerously-skip-permissions --resume <id>`.
///
/// Id grammar: UUID v4 (8-4-4-4-12 hex, anchored, case-insensitive). Mirrors
/// the existing `claudeSessionIdUUIDPattern` so the legacy
/// `claude.session_id` reserved-key validator and the new strategy share
/// one grammar.
struct ClaudeCodeStrategy: ConversationStrategy {
    let kind: String = "claude-code"

    init() {}

    func capture(inputs: ConversationStrategyInputs) -> ConversationRef? {
        // Push-primary: hook value wins on the live path.
        if let push = inputs.push, !push.placeholder {
            return push
        }
        // Pull-fallback: scrape produced a candidate (top-1 by mtime,
        // optionally cwd-filtered). Filename carries the session id
        // (Claude session filename pattern).
        if let candidate = inputs.scrapeCandidates.first,
           isValidConversationUUID(candidate.id) {
            return ConversationRef(
                kind: kind,
                id: candidate.id,
                placeholder: false,
                cwd: candidate.cwd ?? inputs.cwd,
                capturedAt: candidate.mtime,
                capturedVia: .scrape,
                state: .unknown,
                diagnosticReason: "scrape: top-by-mtime in ~/.claude/projects"
            )
        }
        // Wrapper-claim only: nothing to resume yet.
        if let claim = inputs.wrapperClaim {
            return claim
        }
        return nil
    }

    func resume(ref: ConversationRef) -> ResumeAction {
        guard !ref.placeholder else {
            return .skip(reason: "placeholder; no real session id captured yet")
        }
        guard ref.state == .alive || ref.state == .suspended else {
            return .skip(reason: "state=\(ref.state.rawValue) not auto-resumable")
        }
        guard isValidConversationUUID(ref.id) else {
            return .skip(reason: "invalid id grammar")
        }
        let quoted = conversationShellQuote(ref.id)
        let text = "claude --dangerously-skip-permissions --resume \(quoted)"
        return .typeCommand(text: text, submitWithReturn: true)
    }

    func isValidId(_ id: String) -> Bool {
        isValidConversationUUID(id)
    }

    /// Crash-recovery verification: stat the transcript Claude Code keeps at
    /// `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`. Stat only — the
    /// transcript bytes are never opened (privacy contract).
    ///
    /// Returns `nil` when the inputs to compute the path are missing (no
    /// `cwd`, invalid id, or no HOME) so the caller leaves the ref
    /// `.unknown` rather than guessing.
    func transcriptExists(
        for ref: ConversationRef,
        filesystem: ConversationFilesystem
    ) -> Bool? {
        guard isValidConversationUUID(ref.id) else { return nil }
        guard let cwd = ref.cwd, !cwd.isEmpty else { return nil }
        guard let home = filesystem.homeDirectory else { return nil }
        let slug = Self.projectSlug(forCwd: cwd)
        let path = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("\(ref.id).jsonl", isDirectory: false)
            .path
        return filesystem.fileExists(atPath: path)
    }

    /// Claude Code derives the per-project transcript directory by replacing
    /// **every character that is not an ASCII letter or digit** with `-`
    /// (JavaScript `cwd.replace(/[^a-zA-Z0-9]/g, "-")`). So `/`, `.`, `_`,
    /// spaces — all separators — map to `-`, while existing `-` and letter/
    /// digit case are preserved. Examples:
    /// `/Users/atin/Projects/Stage11/code/c11` →
    /// `-Users-atin-Projects-Stage11-code-c11`; a `/.claude` segment collapses
    /// to `--claude`; `…/singularist_salon` → `…-singularist-salon`.
    ///
    /// Matching this exactly is load-bearing for crash recovery: an
    /// underscore (or any other non-alphanumeric) left untranslated points
    /// `transcriptExists` at a directory Claude never created, so a perfectly
    /// resumable session is misclassified "transcript not found" and silently
    /// refused on restore.
    static func projectSlug(forCwd cwd: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(cwd.unicodeScalars.count)
        for scalar in cwd.unicodeScalars {
            let v = scalar.value
            let isASCIIAlphanumeric =
                (v >= 48 && v <= 57)   // 0-9
                || (v >= 65 && v <= 90)   // A-Z
                || (v >= 97 && v <= 122)  // a-z
            out.unicodeScalars.append(isASCIIAlphanumeric ? scalar : "-")
        }
        return out
    }
}
