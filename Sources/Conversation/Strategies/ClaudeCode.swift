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
        if let refusal = conversationResumeCwdRefusal(ref.cwd) { return refusal }
        let quoted = conversationShellQuote(ref.id)
        var text = "\(withAutoApprove("claude")) --resume \(quoted)"
        if let cwd = ref.cwd, !cwd.isEmpty {
            text = "cd \(conversationShellQuote(cwd)) && \(text)"
        }
        return .typeCommand(text: text, submitWithReturn: true)
    }

    func isValidId(_ id: String) -> Bool {
        isValidConversationUUID(id)
    }

    /// Crash-recovery verification: stat the transcript Claude Code keeps at
    /// `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`. Stat only — the
    /// transcript bytes are never opened (privacy contract).
    ///
    /// C11H-196: a ref with no `cwd` (the SessionStart bridge captures only
    /// the id), or one whose cwd slug misses, is looked up by id in every
    /// project directory. Only a missing HOME or an invalid id is "can't
    /// tell" (`nil`); a session absent from every project is `false`.
    func transcriptExists(
        for ref: ConversationRef,
        filesystem: ConversationFilesystem
    ) -> Bool? {
        guard isValidConversationUUID(ref.id) else { return nil }
        switch Self.lookupTranscript(id: ref.id, cwd: ref.cwd, filesystem: filesystem) {
        case .found: return true
        case .missing: return false
        case .unavailable: return nil
        }
    }

    /// C11H-196: the folder Claude was started in, for the resume's `cd`,
    /// when the ref's own cwd does not lead to its transcript. Read from the
    /// transcript's capped head; only `cwd` values are scanned, and only one
    /// whose slug is the transcript's own project directory is returned.
    func recoveredCwd(
        for ref: ConversationRef,
        filesystem: ConversationFilesystem
    ) -> String? {
        guard isValidConversationUUID(ref.id),
              case .found(let path, let slug) = Self.lookupTranscript(id: ref.id, cwd: ref.cwd, filesystem: filesystem)
        else { return nil }
        if let cwd = ref.cwd, !cwd.isEmpty, Self.projectSlug(forCwd: cwd) == slug { return nil }
        guard let head = filesystem.readSessionPrefix(atPath: path, maxBytes: Self.transcriptHeadMaxBytes) else {
            return nil
        }
        return Self.cwds(inHead: head).first { Self.projectSlug(forCwd: $0) == slug }
    }

    func transcriptModifiedAt(
        for ref: ConversationRef,
        filesystem: ConversationFilesystem
    ) -> Date? {
        guard isValidConversationUUID(ref.id),
              case .found(let path, _) = Self.lookupTranscript(id: ref.id, cwd: ref.cwd, filesystem: filesystem)
        else { return nil }
        return filesystem.modificationDate(atPath: path)
    }

    /// Where one session's transcript is, by id.
    enum TranscriptLookup: Equatable {
        case found(path: String, projectSlug: String)
        case missing
        case unavailable
    }

    /// Enough of a transcript's head to reach its first `cwd` field (the
    /// first few records carry no cwd; the first message record does).
    static let transcriptHeadMaxBytes = 256 * 1024

    static func lookupTranscript(id: String, cwd: String?, filesystem: ConversationFilesystem) -> TranscriptLookup {
        guard let home = filesystem.homeDirectory else { return .unavailable }
        let projects = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let fileName = "\(id).jsonl"
        if let cwd, !cwd.isEmpty {
            let slug = projectSlug(forCwd: cwd)
            let path = projects.appendingPathComponent(slug, isDirectory: true)
                .appendingPathComponent(fileName, isDirectory: false).path
            if filesystem.fileExists(atPath: path) { return .found(path: path, projectSlug: slug) }
        }
        for entry in filesystem.listDirectoryByMtime(projects, max: Int.max) {
            let path = entry.url.appendingPathComponent(fileName, isDirectory: false).path
            if filesystem.fileExists(atPath: path) { return .found(path: path, projectSlug: entry.fileName) }
        }
        return .missing
    }

    /// Every `cwd` string value in a capped transcript head, in order. Each
    /// line is scanned only for that key (`CodexScraper.parseCodexCwd`).
    static func cwds(inHead head: String) -> [String] {
        head.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            CodexScraper.parseCodexCwd(fromHead: String($0))
        }
    }

    /// Claude Code derives the per-project transcript directory by replacing
    /// **every character that is not an ASCII letter or digit** with `-`
    /// (JavaScript `cwd.replace(/[^a-zA-Z0-9]/g, "-")`). So `/`, `.`, `_`,
    /// spaces — all separators — map to `-`, while existing `-` and letter/
    /// digit case are preserved. Examples:
    /// `/Users/demo/src/c11` →
    /// `-Users-demo-src-c11`; a `/.claude` segment collapses
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
