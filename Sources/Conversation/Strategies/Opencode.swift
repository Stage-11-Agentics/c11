import Foundation

/// Push-primary strategy for Opencode. The opencode plugin
/// (`skills/opencode-plugins/c11-notify.js`) reports the real session id on
/// `session.created` via `c11 conversation push --kind opencode`. Identity
/// is deterministic on the live path; resume re-attaches the interactive
/// TUI with `cd '<dir>' && opencode -s <id>`.
///
/// Id grammar: `ses_` + 26-char base62 (`isValidOpencodeSessionId`). NOT a
/// UUID and NOT Crockford base32 — opencode session ids routinely contain
/// `I/L/O/U`, which a Crockford alphabet would wrongly reject.
///
/// Resume flag note: the bare TUI accepts the auto-approve flag too — it is a
/// hidden alias of the documented `--auto`, wired on both the `$0 [project]`
/// and `run` commands (verified against opencode 1.18.0). The resume command
/// therefore carries the same flag the manifest's `factoryCommand` does; see
/// `AgentAutoApprove`. It does not appear in `--help`, and yargs silently
/// ignores flags it does not know, so a wrong spelling here would fail
/// open — into approval prompts — rather than erroring.
struct OpencodeStrategy: ConversationStrategy {
    let kind: String = "opencode"

    /// Injectable session-existence lookup for the crash-recovery
    /// `transcriptExists` seam. Defaults to a real `OpencodeScraper` reading
    /// `~/.local/share/opencode/opencode.db`; tests inject a scraper pointed
    /// at a temp DB.
    private let sessionLookup: @Sendable (_ homeDirectory: URL?) -> any OpencodeSessionLookup

    init(
        sessionLookup: @escaping @Sendable (_ homeDirectory: URL?) -> any OpencodeSessionLookup = { home in
            OpencodeScraper(homeDirectory: home)
        }
    ) {
        self.sessionLookup = sessionLookup
    }

    func capture(inputs: ConversationStrategyInputs) -> ConversationRef? {
        // Push-primary: the plugin's `session.created` hook value wins.
        if let push = inputs.push, !push.placeholder {
            return push
        }
        // Pull-fallback (Phase B wiring): a scrape candidate carrying the
        // session id in its `id` field. Left `.unknown` until the live
        // scrape-capture pipeline can confirm it.
        if let candidate = inputs.scrapeCandidates.first,
           isValidOpencodeSessionId(candidate.id) {
            return ConversationRef(
                kind: kind,
                id: candidate.id,
                placeholder: false,
                cwd: candidate.cwd ?? inputs.cwd,
                capturedAt: candidate.mtime,
                capturedVia: .scrape,
                state: .unknown,
                diagnosticReason: "scrape: session row in ~/.local/share/opencode/opencode.db"
            )
        }
        // Wrapper-claim only: nothing concrete to resume yet.
        return inputs.wrapperClaim
    }

    func resume(ref: ConversationRef) -> ResumeAction {
        guard !ref.placeholder else {
            return .skip(reason: "placeholder; no opencode session resolved yet")
        }
        switch ref.state {
        case .unknown:
            return .skip(reason: "state=unknown not auto-resumable")
        case .tombstoned, .unsupported:
            return .skip(reason: "state=\(ref.state.rawValue) not auto-resumable")
        case .alive, .suspended:
            break
        }
        guard isValidOpencodeSessionId(ref.id) else {
            return .skip(reason: "invalid id grammar")
        }
        let quotedId = conversationShellQuote(ref.id)
        var command = "\(withAutoApprove("opencode")) -s \(quotedId)"
        // cd into the recorded project dir first when present and valid —
        // opencode resolves session state relative to the launching cwd.
        if let cwd = ref.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cwd.isEmpty,
           isValidOpencodeSessionProjectDir(cwd) {
            command = "cd \(conversationShellQuote(cwd)) && \(command)"
        }
        return .typeCommand(text: command, submitWithReturn: true)
    }

    func isValidId(_ id: String) -> Bool {
        isValidOpencodeSessionId(id)
    }

    /// Crash-recovery verification: stat-equivalent existence check against
    /// the opencode SQLite `session` table. Never opens transcript content
    /// (the `message`/`part` tables) — privacy contract.
    ///
    /// Three-valued per the protocol: `nil` when the DB is unavailable or
    /// the id is malformed (cannot verify → caller leaves the ref
    /// `.unknown`); `true`/`false` when the DB can be read.
    func transcriptExists(
        for ref: ConversationRef,
        filesystem: ConversationFilesystem
    ) -> Bool? {
        sessionLookup(filesystem.homeDirectory).sessionExists(id: ref.id)
    }
}

/// Narrow seam over the opencode session store so `OpencodeStrategy` can be
/// unit-tested without a live `~/.local/share/opencode/opencode.db`.
protocol OpencodeSessionLookup: Sendable {
    /// `nil` = DB unavailable or id invalid (cannot verify); `true`/`false`
    /// = the DB was read and the session row is present/absent.
    func sessionExists(id: String) -> Bool?
}
