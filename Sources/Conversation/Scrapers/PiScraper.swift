import Foundation

/// Bounded filesystem I/O over `~/.pi/agent/sessions/`, where pi stores
/// per-cwd transcripts as `<cwd-slug>/<ISO-ts>_<uuid>.jsonl`.
///
/// **Privacy contract** (see architecture doc §"Privacy contract for scrape"):
/// reads metadata only — filename + mtime + size. Filename carries the session
/// id. Transcript bytes are NEVER opened, copied, or logged.
///
/// Two divergences from `ClaudeCodeScraper`/`CodexScraper`:
///
/// 1. **Filename grammar.** pi's filename is `<ISO-ts>_<uuid>.jsonl`, not
///    `<uuid>.jsonl`. The ISO timestamp (`2026-06-27T21-35-42-003Z`) uses
///    dashes/`T`/`Z` and contains no `_`, so the session id is the substring
///    after the **last** `_` of the filename stem. `isValidConversationUUID`
///    rejects anything that isn't an 8-4-4-4-12 hex UUID (pi mints UUIDv7,
///    which is that shape), so a filename with no `_` or a non-UUID tail is
///    dropped.
///
/// 2. **cwd-scoped lookup.** pi stores sessions under a **per-cwd slug
///    directory** (`~/.pi/agent/sessions/<slug>/`) and resolves sessions by
///    cwd itself. Unlike codex, pi has no wrapper-claim time floor and no
///    SessionStart hook, so a whole-tree top-N scrape would return candidates
///    from every project and `PiStrategy.capture` would see them all as
///    ambiguous (its cwd filter can't help once every candidate is stamped
///    with the surface cwd). To make the cwd actually narrow — so exact
///    resume can fire — when a `cwd` is known the scraper scopes its walk to
///    that cwd's slug directory (pi's own model). With no `cwd` it falls back
///    to the whole-tree top-N (best-effort, e.g. a surface with no recorded
///    directory).
struct PiScraper: ConversationScraper {
    let kind: String = "pi"
    static let defaultMaxCandidates: Int = 16

    /// Filesystem dependency. Tests pass a mock that produces fixture
    /// session-storage layouts without touching the real `~/.pi/`.
    let filesystem: ConversationFilesystem
    let maxCandidates: Int

    init(
        filesystem: ConversationFilesystem = DefaultConversationFilesystem(),
        maxCandidates: Int = PiScraper.defaultMaxCandidates
    ) {
        self.filesystem = filesystem
        self.maxCandidates = maxCandidates
    }

    /// Resolve `~/.pi/agent/sessions/`. Returns nil if HOME isn't set.
    func sessionsRoot() -> URL? {
        guard let home = filesystem.homeDirectory else { return nil }
        return home
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// pi's per-cwd session-directory name. Mirrors pi's encoding exactly
    /// (`@earendil-works/pi-coding-agent` `migrations.js`):
    /// `"--" + cwd.drop(leading "/" or "\") with [/\\:] -> "-" + "--"`. Note
    /// pi does NOT map `.` (unlike Claude's project slug), so dots are kept.
    static func sessionSlug(forCwd cwd: String) -> String {
        var stripped = Substring(cwd)
        if let first = stripped.first, first == "/" || first == "\\" {
            stripped = stripped.dropFirst()
        }
        let mapped = String(stripped.map { ($0 == "/" || $0 == "\\" || $0 == ":") ? "-" : $0 })
        return "--\(mapped)--"
    }

    /// Top-N candidates by mtime. Empty list when the session store (or the
    /// cwd's slug directory) doesn't exist. When `cwd` is known, lists just
    /// that cwd's slug directory (sessions live directly under it, one level
    /// deep); otherwise walks the whole tree recursively.
    func candidates(cwd: String? = nil) -> [ScrapeCandidate] {
        guard let root = sessionsRoot() else { return [] }
        let entries: [ConversationFilesystemEntry]
        if let cwd, !cwd.isEmpty {
            let slugDir = root.appendingPathComponent(
                Self.sessionSlug(forCwd: cwd), isDirectory: true
            )
            entries = filesystem.listDirectoryByMtime(slugDir, max: maxCandidates)
        } else {
            entries = filesystem.listSessionsRecursivelyByMtime(
                root, extensionFilter: "jsonl", max: maxCandidates
            )
        }
        return entries.compactMap { entry in
            // `listDirectoryByMtime` returns every file in the slug dir, so
            // filter the extension here (the recursive lister already did).
            guard entry.fileName.hasSuffix(".jsonl") else { return nil }
            let stem = String(entry.fileName.dropLast(".jsonl".count))
            // Session id is the substring after the last `_`; the ISO
            // timestamp before it contains no `_`.
            guard let underscore = stem.lastIndex(of: "_") else { return nil }
            let id = String(stem[stem.index(after: underscore)...])
            guard isValidConversationUUID(id) else { return nil }
            return ScrapeCandidate(
                id: id,
                filePath: entry.url.path,
                mtime: entry.mtime,
                size: entry.size,
                cwd: cwd
            )
        }
    }
}
