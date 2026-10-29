import Foundation
import SQLite3

/// Server-owned payload keys captured only by an authenticated OpenCode TUI
/// wrapper claim. The version marker is present even when the process had no
/// path overrides; its presence prevents recovery from borrowing c11's own
/// process environment for a TUI that used a different launch context.
enum OpencodeRecoveryStoreContextKey {
    static let version = "opencode_recovery_context_version"
    static let home = "opencode_recovery_home"
    static let xdgDataHome = "opencode_recovery_xdg_data_home"
    static let databaseOverride = "opencode_recovery_database_override"
}

struct OpencodeRecoveryStoreContext: Sendable, Equatable {
    let homeDirectory: URL?
    let environment: [String: String]

    /// `nil` means no authenticated launch marker exists. A malformed marker
    /// is represented by a non-nil context with `isUsable == false`, so the
    /// caller can fail closed instead of falling back to c11's environment.
    let isUsable: Bool

    static func isMarked(_ payload: [String: PersistedJSONValue]?) -> Bool {
        payload?[OpencodeRecoveryStoreContextKey.version] != nil
    }

    init?(payload: [String: PersistedJSONValue]?) {
        guard let payload,
              payload[OpencodeRecoveryStoreContextKey.version] != nil else {
            return nil
        }

        var valid = false
        if case .number(let version)? = payload[OpencodeRecoveryStoreContextKey.version],
           version == 1 {
            valid = true
        }

        let home: String?
        if case .string(let value)? = payload[OpencodeRecoveryStoreContextKey.home] {
            home = value
            if !value.hasPrefix("/") || value.utf8.count > Self.maximumPathBytes || value.contains("\0") {
                valid = false
            }
        } else if payload[OpencodeRecoveryStoreContextKey.home] != nil {
            home = nil
            valid = false
        } else {
            home = nil
        }

        var environment: [String: String] = [:]
        if case .string(let value)? = payload[OpencodeRecoveryStoreContextKey.xdgDataHome] {
            guard value.utf8.count <= Self.maximumPathBytes, !value.contains("\0") else {
                self.homeDirectory = nil
                self.environment = [:]
                self.isUsable = false
                return
            }
            environment["XDG_DATA_HOME"] = value
        } else if payload[OpencodeRecoveryStoreContextKey.xdgDataHome] != nil {
            valid = false
        }

        if case .string(let value)? = payload[OpencodeRecoveryStoreContextKey.databaseOverride] {
            guard value.utf8.count <= Self.maximumPathBytes, !value.contains("\0") else {
                self.homeDirectory = nil
                self.environment = [:]
                self.isUsable = false
                return
            }
            // Preserve empty and :memory: values exactly. They are explicit
            // non-disk configurations, never a reason to use the default DB.
            environment["OPENCODE_DB"] = value
        } else if payload[OpencodeRecoveryStoreContextKey.databaseOverride] != nil {
            valid = false
        }

        self.homeDirectory = home.map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.environment = environment
        self.isUsable = valid
    }

    private static let maximumPathBytes = 4_096
}

/// Read-only SQLite I/O over OpenCode's global data path. v1 uses the
/// `session` table; v2 uses `session_v2`.
///
/// **Privacy contract**: exact recovery reads only the requested session ID.
/// Directory scrape reads only `id`, `directory`, and `time_updated`. The
/// `message` and `part` tables (transcript content) are NEVER opened, copied,
/// or logged.
struct OpencodeScraper: Sendable, OpencodeSessionLookup {
    let kind: String = "opencode"
    static let defaultMaxCandidates: Int = 16

    let maxCandidates: Int
    let homeDirectory: URL?
    let environment: [String: String]

    init(
        homeDirectory: URL? = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maxCandidates: Int = OpencodeScraper.defaultMaxCandidates
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.maxCandidates = maxCandidates
    }

    /// Resolve OpenCode's database override or the platform data path.
    /// Absolute `OPENCODE_DB` paths are used directly; relative paths are
    /// resolved inside OpenCode's data directory. `:memory:` is intentionally
    /// not opened as a fallback to the on-disk database. Relative XDG paths
    /// are ignored per the XDG directory specification.
    func databasePath() -> URL? {
        let dataDirectory: URL?
        if let rawDataHome = environment["XDG_DATA_HOME"],
           !rawDataHome.isEmpty,
           rawDataHome.hasPrefix("/") {
            dataDirectory = URL(fileURLWithPath: rawDataHome, isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
        } else if let home = homeDirectory {
            dataDirectory = home
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
        } else {
            dataDirectory = nil
        }

        let url: URL
        if let override = environment["OPENCODE_DB"] {
            guard !override.isEmpty, override != ":memory:", !override.contains("\0") else { return nil }
            if override.hasPrefix("/") {
                url = URL(fileURLWithPath: override)
            } else {
                guard let dataDirectory else { return nil }
                url = dataDirectory.appendingPathComponent(override).standardizedFileURL
            }
        } else {
            guard let dataDirectory else { return nil }
            url = dataDirectory.appendingPathComponent("opencode.db", isDirectory: false)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Open the OpenCode DB read-only with a 2 s busy-timeout. Returns nil on
    /// any failure. Caller owns `sqlite3_close`.
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
        sqlite3_busy_timeout(database, 2_000)
        return database
    }

    /// Exact-ID crash-recovery lookup.
    ///
    /// - `true`: a row with this ID exists in a supported schema. OpenCode's
    ///   `findSession` accepts archived rows too, so archive time is not a
    ///   reason to report absence.
    /// - `false`: every present supported schema was queried successfully and
    ///   no matching row exists.
    /// - `nil`: malformed ID, unavailable/corrupt/locked DB, no supported
    ///   session table, unsupported table shape, or query failure.
    ///
    /// Never substitutes another session and never reads transcript tables.
    func sessionExists(id: String) -> Bool? {
        guard isValidOpencodeSessionId(id), let database = openDatabase() else { return nil }
        defer { sqlite3_close(database) }
        guard let tables = sessionTables(in: database), !tables.isEmpty else { return nil }

        var queriedSupportedSchema = false
        var encounteredUnsupportedSchema = false
        for table in tables {
            guard let columns = tableColumns(table, in: database),
                  columns.isSuperset(of: ["id", "directory", "time_updated"]) else {
                encounteredUnsupportedSchema = true
                continue
            }
            queriedSupportedSchema = true
            switch exactIDExists(id, table: table, in: database) {
            case .some(true): return true
            case .some(false): break
            case .none: encounteredUnsupportedSchema = true
            }
        }
        guard queriedSupportedSchema, !encounteredUnsupportedSchema else { return nil }
        return false
    }

    /// Top-N sessions for `cwd`, combined across supported session schemas.
    /// An incomplete or unsupported table returns no scrape candidates rather
    /// than implying that the remaining table is complete.
    func scrape(cwd: String) -> [ConversationRef] {
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCwd.isEmpty, let database = openDatabase() else { return [] }
        defer { sqlite3_close(database) }
        guard let tables = sessionTables(in: database), !tables.isEmpty else { return [] }

        var rows: [(id: String, timeUpdatedMs: Int64)] = []
        for table in tables {
            guard let columns = tableColumns(table, in: database),
                  columns.isSuperset(of: ["id", "directory", "time_updated"]),
                  let tableRows = scrapeRows(table, cwd: trimmedCwd, in: database) else {
                // A partial cross-schema listing could omit a newer exact match.
                return []
            }
            rows.append(contentsOf: tableRows)
        }

        var seen: Set<String> = []
        return Array(rows.sorted { $0.timeUpdatedMs > $1.timeUpdatedMs }.compactMap { row in
            guard seen.insert(row.id).inserted, isValidOpencodeSessionId(row.id) else { return nil }
            return ConversationRef(
                kind: kind,
                id: row.id,
                placeholder: false,
                cwd: trimmedCwd,
                capturedAt: Date(timeIntervalSince1970: Double(row.timeUpdatedMs) / 1_000.0),
                capturedVia: .scrape,
                state: .unknown,
                diagnosticReason: "scrape: exact session row in OpenCode data database"
            )
        }.prefix(maxCandidates))
    }

    private enum SessionTable: String, CaseIterable {
        case v2 = "session_v2"
        case legacy = "session"
    }

    private func sessionTables(in database: OpaquePointer) -> [SessionTable]? {
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('session_v2', 'session')"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var found: Set<SessionTable> = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let text = sqlite3_column_text(statement, 0),
                      let table = SessionTable(rawValue: String(cString: text)) else { continue }
                found.insert(table)
            case SQLITE_DONE:
                return SessionTable.allCases.filter(found.contains)
            default:
                return nil
            }
        }
    }

    private func tableColumns(_ table: SessionTable, in database: OpaquePointer) -> Set<String>? {
        // The identifier is selected from the fixed enum, never user input.
        let sql = "PRAGMA table_info(\(table.rawValue))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var columns: Set<String> = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let text = sqlite3_column_text(statement, 1) else { continue }
                columns.insert(String(cString: text))
            case SQLITE_DONE:
                return columns.isEmpty ? nil : columns
            default:
                return nil
            }
        }
    }

    private func exactIDExists(_ id: String, table: SessionTable, in database: OpaquePointer) -> Bool? {
        let sql = "SELECT 1 FROM \(table.rawValue) WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        return id.withCString { cString in
            guard sqlite3_bind_text(statement, 1, cString, -1, nil) == SQLITE_OK else { return nil }
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: return nil
            }
        }
    }

    private func scrapeRows(
        _ table: SessionTable,
        cwd: String,
        in database: OpaquePointer
    ) -> [(id: String, timeUpdatedMs: Int64)]? {
        let sql = "SELECT id, time_updated FROM \(table.rawValue) WHERE directory = ? ORDER BY time_updated DESC LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 2, Int64(maxCandidates)) == SQLITE_OK else { return nil }
        return cwd.withCString { cString in
            guard sqlite3_bind_text(statement, 1, cString, -1, nil) == SQLITE_OK else { return nil }
            var rows: [(id: String, timeUpdatedMs: Int64)] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard let text = sqlite3_column_text(statement, 0) else { continue }
                    rows.append((String(cString: text), sqlite3_column_int64(statement, 1)))
                case SQLITE_DONE:
                    return rows
                default:
                    return nil
                }
            }
        }
    }
}
