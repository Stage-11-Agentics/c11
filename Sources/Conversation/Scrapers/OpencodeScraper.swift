import Foundation
import SQLite3

/// Read-only SQLite I/O over `~/.local/share/opencode/opencode.db`, where
/// opencode stores one row per session in the `session` table.
///
/// **Privacy contract** (see architecture doc §"Privacy contract for scrape"):
/// stat-equivalent — queries `session.id` and `session.time_updated` only.
/// The `message` and `part` tables (transcript content) are NEVER opened,
/// copied, or logged. The query is bounded (`LIMIT 16`) and filtered to the
/// surface's cwd via the `directory` column.
///
/// Scope:
/// - At most 16 most-recent sessions for the cwd by `time_updated` DESC.
/// - Id grammar: `ses_` + 26-char **base62** body (validated via
///   `isValidOpencodeSessionId` as defence-in-depth — the DB is the source
///   of truth, but a corrupt row cannot leak into a synthesized ref).
/// - DB-locked / absent / corrupt: returns `[]`. Never crashes the caller.
///   A 2 s busy-timeout is configured so a transient opencode write does
///   not fail the read.
///
/// This scraper deviates from `ClaudeCodeScraper` / `CodexScraper` by
/// returning `[ConversationRef]` directly rather than `[ScrapeCandidate]`:
/// opencode has no on-disk transcript file (sessions live in SQLite), so
/// the filesystem-shaped `ScrapeCandidate` fields (`filePath`, `size`)
/// have no meaningful value. Callers that feed the strategy-inputs
/// pipeline can lift each ref into a `ScrapeCandidate` if needed.
struct OpencodeScraper: Sendable, OpencodeSessionLookup {
    let kind: String = "opencode"
    static let defaultMaxCandidates: Int = 16

    let maxCandidates: Int
    let homeDirectory: URL?

    init(
        homeDirectory: URL? = FileManager.default.homeDirectoryForCurrentUser,
        maxCandidates: Int = OpencodeScraper.defaultMaxCandidates
    ) {
        self.homeDirectory = homeDirectory
        self.maxCandidates = maxCandidates
    }

    /// Resolve `~/.local/share/opencode/opencode.db`. Returns nil if HOME
    /// isn't available or the file doesn't exist (opencode never ran on
    /// this machine).
    func databasePath() -> URL? {
        guard let home = homeDirectory else { return nil }
        let url = home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.db", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Open the opencode DB read-only with a 2 s busy-timeout. Returns nil
    /// (and closes any partial handle) on any failure. Caller owns
    /// `sqlite3_close`.
    private func openDatabase() -> OpaquePointer? {
        guard let dbURL = databasePath() else { return nil }
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(
            dbURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        // 2 s busy-timeout: a transient opencode write should not fail the
        // read. `SQLITE_BUSY` past the timeout degrades to nil/[].
        sqlite3_busy_timeout(database, 2_000)
        return database
    }

    /// Stat-equivalent existence check for a specific session id. The
    /// crash-recovery backing for `OpencodeStrategy.transcriptExists`.
    ///
    /// - `nil`: id is malformed, or the DB is absent / cannot be opened or
    ///   prepared (cannot verify).
    /// - `true`: a `session` row with this id exists.
    /// - `false`: the DB was queried and no such row exists.
    ///
    /// Reads `session.id` only — never transcript content. Never crashes.
    func sessionExists(id: String) -> Bool? {
        guard isValidOpencodeSessionId(id) else { return nil }
        guard let database = openDatabase() else { return nil }
        defer { sqlite3_close(database) }

        let sql = "SELECT 1 FROM session WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        return id.withCString { cString -> Bool? in
            guard sqlite3_bind_text(statement, 1, cString, -1, nil) == SQLITE_OK else {
                return nil
            }
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return true
            case SQLITE_DONE:
                return false
            default:
                // SQLITE_BUSY past timeout / SQLITE_ERROR: cannot verify.
                return nil
            }
        }
    }

    /// Top-N sessions for `cwd` by `time_updated` DESC. Empty when the DB
    /// is absent, locked past the busy-timeout, or corrupt. Never throws.
    func scrape(cwd: String) -> [ConversationRef] {
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCwd.isEmpty else { return [] }
        guard let database = openDatabase() else { return [] }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT id, time_updated
            FROM session
            WHERE directory = ?
            ORDER BY time_updated DESC
            LIMIT ?
            """
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        let limitBindResult = sqlite3_bind_int64(statement, 2, Int64(maxCandidates))
        guard limitBindResult == SQLITE_OK else { return [] }

        // Bind cwd as UTF-8 text. `withCString` guarantees a stable
        // NUL-terminated buffer for the lifetime of the closure, so
        // SQLITE_STATIC (nil destructor) is safe — SQLite reads but
        // does not retain the bytes.
        return trimmedCwd.withCString { cString in
            let cwdBindResult = sqlite3_bind_text(
                statement, 1, cString, -1, nil
            )
            guard cwdBindResult == SQLITE_OK else { return [] }

            var refs: [ConversationRef] = []
            refs.reserveCapacity(min(maxCandidates, 16))
            while true {
                let stepCode = sqlite3_step(statement)
                if stepCode == SQLITE_ROW {
                    guard let idC = sqlite3_column_text(statement, 0) else { continue }
                    let id = String(cString: idC)
                    let timeUpdatedMs = sqlite3_column_int64(statement, 1)
                    let capturedAt = Date(timeIntervalSince1970: Double(timeUpdatedMs) / 1_000.0)
                    guard isValidOpencodeSessionId(id) else { continue }
                    refs.append(ConversationRef(
                        kind: kind,
                        id: id,
                        placeholder: false,
                        cwd: trimmedCwd,
                        capturedAt: capturedAt,
                        capturedVia: .scrape,
                        state: .unknown,
                        diagnosticReason: "scrape: session row in ~/.local/share/opencode/opencode.db"
                    ))
                    continue
                }
                if stepCode == SQLITE_DONE {
                    break
                }
                // Any other step code (SQLITE_BUSY past timeout, SQLITE_ERROR,
                // ...): the query is incomplete. Return what we have rather
                // than crashing — partial results are still useful for
                // crash recovery.
                return refs
            }
            return refs
        }
    }
}
