import Foundation
import SQLite3
import Darwin

private final class JournalReadStore {
    private var db: OpaquePointer?
    let layout: JournalStorageLayout

    init(layout: JournalStorageLayout) throws {
        self.layout = layout
        guard FileManager.default.fileExists(atPath: layout.database.path) else {
            throw CLIError(message: "journal: storage_unavailable")
        }
        guard sqlite3_open_v2(layout.database.path, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            throw CLIError(message: "journal: storage_unavailable")
        }
        sqlite3_busy_timeout(db, 100)
        do {
            try execute("PRAGMA query_only=ON")
            guard try scalar("PRAGMA user_version") == 1,
                  try scalar("SELECT value FROM journal_meta WHERE key='fold_version'") == 1 else {
                throw CLIError(message: "journal: unsupported_version")
            }
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private enum Bind { case integer(Int64) }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func statement(_ sql: String, _ values: [Bind] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CLIError(message: "journal: storage_unavailable")
        }
        for (index, value) in values.enumerated() {
            let result: Int32
            switch value {
            case .integer(let integer): result = sqlite3_bind_int64(stmt, Int32(index + 1), integer)
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw CLIError(message: "journal: storage_unavailable")
            }
        }
        return stmt
    }

    private func execute(_ sql: String) throws {
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw CLIError(message: "journal: storage_unavailable") }
    }

    private func scalar(_ sql: String) throws -> Int64 {
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw CLIError(message: "journal: storage_unavailable") }
        return sqlite3_column_int64(stmt, 0)
    }

    private func blob(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    func coverage() throws -> (firstAvailable: Int64, highWater: Int64, retainedFrom: Int64, lastObservation: Int64) {
        let stmt = try statement("""
            SELECT
              COALESCE((SELECT value FROM journal_meta WHERE key='coverage_low_water'),1),
              COALESCE((SELECT seq FROM sqlite_sequence WHERE name='journal_events'),0),
              COALESCE((SELECT MIN(committed_at_ms) FROM journal_events),
                       (SELECT value FROM journal_meta WHERE key='last_writer_observation')),
              COALESCE((SELECT value FROM journal_meta WHERE key='last_writer_observation'),0)
            """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw CLIError(message: "journal: storage_unavailable") }
        return (sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1),
                sqlite3_column_int64(stmt, 2), sqlite3_column_int64(stmt, 3))
    }

    func readPage(after: Int64, through: Int64, limit: Int = 500) throws -> [JournalEvent] {
        let stmt = try statement(
            "SELECT event FROM journal_events WHERE sequence>? AND sequence<=? ORDER BY sequence LIMIT ?",
            [.integer(after), .integer(through), .integer(Int64(max(1, min(500, limit))))]
        )
        defer { sqlite3_finalize(stmt) }
        var result: [JournalEvent] = []
        var code = sqlite3_step(stmt)
        while code == SQLITE_ROW {
            result.append(try JSONDecoder().decode(JournalEvent.self, from: blob(stmt, 0)))
            code = sqlite3_step(stmt)
        }
        guard code == SQLITE_DONE else { throw CLIError(message: "journal: storage_unavailable") }
        return result
    }

    func baselines() throws -> [JournalSnapshot] {
        let stmt = try statement("SELECT state FROM journal_current ORDER BY owner")
        defer { sqlite3_finalize(stmt) }
        var result: [JournalSnapshot] = []
        var code = sqlite3_step(stmt)
        while code == SQLITE_ROW {
            result.append(try JSONDecoder().decode(JournalSnapshot.self, from: blob(stmt, 0)))
            code = sqlite3_step(stmt)
        }
        guard code == SQLITE_DONE else { throw CLIError(message: "journal: storage_unavailable") }
        return result
    }
}

enum JournalQueryCommand {
    private struct Arguments {
        let subcommand: String
        var json = false
        var agent: String?
        var model: String?
        var workspace: UUID?
        var from: String?
        var to: String?
        var stallMs: Int64 = 900_000
        var bundleID: String?
        var output: String?
        var yes = false
    }

    static func run(_ rawArguments: [String], socketPath: String,
                    explicitPassword: String?, globalJSON: Bool) throws {
        if rawArguments.isEmpty || rawArguments.contains("--help") || rawArguments.contains("-h") {
            print(usage())
            return
        }
        let arguments = try parse(rawArguments, globalJSON: globalJSON)
        if arguments.subcommand == "clear" && !arguments.yes {
            throw CLIError(message: "journal clear requires --yes; no data was deleted")
        }

        let live = try connectIfAvailable(socketPath: socketPath, explicitPassword: explicitPassword)
        defer { live?.close() }
        let liveBundleID = try liveBundleID(from: live)
        let liveWriterInstanceID = try liveWriterInstanceID(from: live)
        if let requested = arguments.bundleID, let liveBundleID, requested != liveBundleID {
            throw CLIError(message: "journal: --bundle-id does not match the running app namespace")
        }
        let bundleID = liveBundleID ?? arguments.bundleID

        if arguments.subcommand == "clear", let live {
            let response = try live.sendV2(method: "journal.clear", params: ["yes": true])
            printPayload(response, json: arguments.json, human: "cleared journal")
            return
        }

        guard let bundleID else {
            throw CLIError(message: "journal \(arguments.subcommand): app is down; pass --bundle-id <identifier>")
        }
        let layout: JournalStorageLayout
        do { layout = try JournalStorageLayout.resolve(bundleID: bundleID) }
        catch { throw CLIError(message: "journal: invalid bundle id") }

        if arguments.subcommand == "clear" {
            try clearOffline(layout)
            printPayload(["cleared": true, "bundle_id": bundleID], json: arguments.json, human: "cleared journal")
            return
        }

        let store = try JournalReadStore(layout: layout)
        let frozen = try store.coverage()
        let filters = try makeFilters(arguments: arguments, retainedFromMs: frozen.retainedFrom,
                                      lastObservationMs: frozen.lastObservation)
        let baselines = try store.baselines()
        let coverage = JournalQueryCoverage(
            retainedFromMs: frozen.retainedFrom,
            firstAvailableSequence: frozen.firstAvailable,
            highWaterSequence: frozen.highWater,
            incomplete: frozen.firstAvailable > 1,
            uncertainCount: 0,
            censoredCount: 0,
            sources: [:],
            lastObservationMs: frozen.lastObservation
        )

        switch arguments.subcommand {
        case "query":
            let stream = JournalQuery.Stream(baselines: baselines, coverage: coverage,
                                             filters: filters, writerInstanceID: liveWriterInstanceID)
            var cursor = max(0, frozen.firstAvailable - 1)
            while cursor < frozen.highWater {
                let page = try autoreleasepool {
                    try store.readPage(after: cursor, through: frozen.highWater, limit: 500)
                }
                guard !page.isEmpty else { break }
                page.forEach(stream.consume)
                cursor = page.last!.sequence
            }
            let result = stream.finish()
            if arguments.json {
                printJSON(result.object)
            } else {
                print(result.humanText)
            }
        case "export":
            let destination = try JournalExport.openOutput(arguments.output)
            defer { if destination.path != nil { try? destination.handle.close() } }
            let writer = try JournalExport.StreamWriter(handle: destination.handle, coverage: coverage, filters: filters)
            var cursor = max(0, frozen.firstAvailable - 1)
            while cursor < frozen.highWater {
                let nextCursor: Int64? = try autoreleasepool {
                    let page = try store.readPage(after: cursor, through: frozen.highWater, limit: 500)
                    guard let nextCursor = page.last?.sequence else { return nil }
                    try writer.consume(page)
                    return nextCursor
                }
                guard let nextCursor else { break }
                cursor = nextCursor
            }
            try writer.finish(baselines: baselines)
            if let path = destination.path {
                try destination.handle.synchronize()
                try destination.handle.close()
                if arguments.json {
                    printJSON(["exported": true, "path": path])
                } else {
                    print("exported \(path)")
                }
            }
        default:
            throw CLIError(message: "journal: unknown subcommand")
        }
    }

    private static func parse(_ raw: [String], globalJSON: Bool) throws -> Arguments {
        guard let subcommand = raw.first?.lowercased(), ["query", "export", "clear"].contains(subcommand) else {
            throw CLIError(message: "usage: c11 journal query|export|clear [options]")
        }
        var result = Arguments(subcommand: subcommand, json: globalJSON)
        var index = 1
        while index < raw.count {
            let value = raw[index]
            switch value {
            case "--json": result.json = true; index += 1
            case "--yes": result.yes = true; index += 1
            case "--agent": result.agent = try next(raw, &index, value)
            case "--model": result.model = try next(raw, &index, value)
            case "--workspace":
                let rawWorkspace = try next(raw, &index, value)
                guard let workspace = UUID(uuidString: rawWorkspace) else {
                    throw CLIError(message: "journal: --workspace must be a UUID")
                }
                result.workspace = workspace
            case "--from": result.from = try next(raw, &index, value)
            case "--to": result.to = try next(raw, &index, value)
            case "--stall-ms":
                let value = try next(raw, &index, value)
                guard let stall = Int64(value), stall > 0 else { throw CLIError(message: "journal: --stall-ms must be positive") }
                result.stallMs = stall
            case "--bundle-id": result.bundleID = try next(raw, &index, value)
            case "--output": result.output = try next(raw, &index, value)
            default:
                throw CLIError(message: "journal: unknown option '\(value)'")
            }
        }
        if subcommand != "export", result.output != nil { throw CLIError(message: "journal: --output is only valid for export") }
        if subcommand != "clear", result.yes { throw CLIError(message: "journal: --yes is only valid for clear") }
        return result
    }

    private static func next(_ args: [String], _ index: inout Int, _ option: String) throws -> String {
        guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
            throw CLIError(message: "journal: \(option) requires a value")
        }
        index += 2
        return args[index - 1]
    }

    private static func makeFilters(arguments: Arguments, retainedFromMs: Int64?, lastObservationMs: Int64) throws -> JournalQueryFilters {
        let stableDefaultTo = lastObservationMs == Int64.max ? lastObservationMs : lastObservationMs + 1
        let to = try parseTime(arguments.to) ?? stableDefaultTo
        let from = try parseTime(arguments.from) ?? retainedFromMs ?? max(0, to - 14 * 86_400_000)
        guard from <= to else { throw CLIError(message: "journal: --from must be before --to") }
        return JournalQueryFilters(agent: arguments.agent, model: arguments.model, workspace: arguments.workspace,
                                   fromMs: from, toMs: to, stallMs: arguments.stallMs)
    }

    private static func parseTime(_ raw: String?) throws -> Int64? {
        guard let raw else { return nil }
        if let integer = Int64(raw) { guard integer >= 0 else { throw CLIError(message: "journal: time must be non-negative") }; return integer }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        throw CLIError(message: "journal: invalid time '\(raw)'; use epoch ms or ISO8601")
    }

    private static func connectIfAvailable(socketPath: String, explicitPassword: String?) throws -> SocketClient? {
        let client = SocketClient(path: socketPath)
        do {
            try client.connect()
            if let password = SocketPasswordResolver.resolve(explicit: explicitPassword, socketPath: socketPath) {
                let response = try client.send(command: "auth \(password)")
                if response.hasPrefix("ERROR:") && !response.contains("Unknown command 'auth'") {
                    throw CLIError(message: response)
                }
            }
            return client
        } catch let error as CLIError {
            client.close()
            if isUnavailable(error) { return nil }
            throw error
        } catch {
            client.close()
            return nil
        }
    }

    private static func liveBundleID(from client: SocketClient?) throws -> String? {
        guard let client else { return nil }
        let brand = try client.sendV2(method: "system.brand")
        guard let bundle = brand["bundle"] as? [String: Any], let identifier = bundle["identifier"] as? String,
              !identifier.isEmpty else { throw CLIError(message: "journal: running app did not identify its bundle") }
        return identifier
    }

    private static func liveWriterInstanceID(from client: SocketClient?) throws -> UUID? {
        guard let client else { return nil }
        guard let status = try? client.sendV2(method: "journal.status"),
              status["health"] as? String == "ok",
              let raw = status["writer_instance_id"] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    private static func isUnavailable(_ error: CLIError) -> Bool {
        let message = error.message
        return message.contains("Socket not found") || message.contains("Failed to connect")
            || message.contains("not a Unix socket")
    }

    private static func clearOffline(_ layout: JournalStorageLayout) throws {
        let expected = "/Library/Application Support/c11/journal/"
        guard layout.directory.path.contains(expected), layout.directory.path.hasPrefix(NSHomeDirectory()) else {
            throw CLIError(message: "journal: refusing unsafe namespace path")
        }
        do {
            try layout.prepare()
            let descriptor = Darwin.open(layout.database.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw CLIError(message: "journal: storage_unavailable") }
            close(descriptor)
            var db: OpaquePointer?
            guard sqlite3_open_v2(layout.database.path, &db,
                                  SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
                  let db else { throw CLIError(message: "journal: storage_unavailable") }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 100)
            try execute(db, "PRAGMA journal_mode=WAL")
            let version = try scalar(db, "PRAGMA user_version")
            if version == 0 {
                try execute(db, "PRAGMA auto_vacuum=INCREMENTAL")
                try execute(db, "BEGIN IMMEDIATE")
                do {
                    try execute(db, "CREATE TABLE journal_events (sequence INTEGER PRIMARY KEY AUTOINCREMENT,event_id TEXT NOT NULL UNIQUE,committed_at_ms INTEGER NOT NULL,tab_id TEXT,session_id TEXT,agent_kind TEXT NOT NULL,model_id TEXT,workspace_id TEXT,draft BLOB NOT NULL,event BLOB)")
                    try execute(db, "CREATE INDEX journal_owner_sequence ON journal_events(tab_id,session_id,sequence)")
                    try execute(db, "CREATE INDEX journal_dimensions ON journal_events(committed_at_ms,agent_kind,model_id,workspace_id)")
                    try execute(db, "CREATE TABLE journal_current (owner TEXT PRIMARY KEY,state BLOB NOT NULL,observed_at_ms INTEGER NOT NULL,protected INTEGER NOT NULL)")
                    try execute(db, "CREATE TABLE journal_meta (key TEXT PRIMARY KEY,value INTEGER NOT NULL)")
                    try execute(db, "INSERT INTO journal_meta VALUES('fold_version',1),('coverage_low_water',1),('last_writer_observation',0)")
                    try execute(db, "PRAGMA user_version=1")
                    try execute(db, "COMMIT")
                } catch {
                    try? execute(db, "ROLLBACK")
                    throw error
                }
            } else if version != 1 {
                throw CLIError(message: "journal: unsupported_version")
            }
            guard try scalar(db, "SELECT value FROM journal_meta WHERE key='fold_version'") == 1 else {
                throw CLIError(message: "journal: unsupported_version")
            }
            try JournalSpool(layout: layout).clearTogether {
                try execute(db, "BEGIN IMMEDIATE")
                do {
                    try execute(db, "DELETE FROM journal_events")
                    try execute(db, "DELETE FROM journal_current")
                    try execute(db, "UPDATE journal_meta SET value=COALESCE((SELECT seq+1 FROM sqlite_sequence WHERE name='journal_events'),1) WHERE key='coverage_low_water'")
                    try execute(db, "UPDATE journal_meta SET value=\(Int64(Date().timeIntervalSince1970 * 1000)) WHERE key='last_writer_observation'")
                    try execute(db, "COMMIT")
                } catch {
                    try? execute(db, "ROLLBACK")
                    throw error
                }
            }
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError(message: "journal: clear failed")
        }
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CLIError(message: "journal: storage_unavailable")
        }
    }

    private static func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CLIError(message: "journal: storage_unavailable")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CLIError(message: "journal: storage_unavailable") }
        return sqlite3_column_int64(statement, 0)
    }

    private static func printPayload(_ payload: [String: Any], json: Bool, human: String) {
        if json {
            printJSON(payload)
        } else {
            print(human)
        }
    }

    private static func printJSON(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("{}")
        }
    }

    private static func usage() -> String {
        """
        Usage: c11 journal <query|export|clear> [options]

        query   Read lifecycle metrics. Use --json for a machine-readable report.
        export  Write body-free, ordered NDJSON to stdout or --output <path>.
        clear   Delete this c11 namespace's journal history; requires --yes.

        Options: --agent <slug> --model <id> --workspace <uuid>
                 --from <epoch-ms|ISO8601> --to <epoch-ms|ISO8601>
                 --stall-ms <milliseconds> --bundle-id <identifier>
                 export only: --output <local-path>
        App-down query/export/clear requires --bundle-id.

        Operator-response coverage: an unmodified Return or Enter in the ask's
        terminal tab and the text box Send are observed. A Claude AskUserQuestion
        picker answer is not observed (its commit key is unknown, so c11 records
        nothing), so a mixed window under-counts operator responses.
        """
    }
}
