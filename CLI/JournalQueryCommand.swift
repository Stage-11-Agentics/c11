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

    func coverage() throws -> (first: Int64?, highWater: Int64, lastObservation: Int64) {
        let first = try scalar("SELECT MIN(sequence) FROM journal_events")
        let highWater = try scalar("SELECT COALESCE(MAX(seq),0) FROM sqlite_sequence WHERE name='journal_events'")
        let observation = try scalar("SELECT value FROM journal_meta WHERE key='last_writer_observation'")
        return (first == 0 ? nil : first, highWater, observation)
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
        let snapshot = try load(store: store, arguments: arguments)
        let filters = try makeFilters(arguments: arguments, retainedFromMs: snapshot.retainedFromMs,
                                      nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        let coverage = JournalQueryCoverage(
            retainedFromMs: snapshot.retainedFromMs,
            firstAvailableSequence: snapshot.firstAvailableSequence,
            highWaterSequence: snapshot.highWaterSequence,
            incomplete: snapshot.firstAvailableSequence.map { $0 > 1 } ?? false,
            uncertainCount: 0,
            censoredCount: 0,
            sources: [:]
        )

        switch arguments.subcommand {
        case "query":
            let result = JournalQuery.evaluate(events: snapshot.events, baselines: snapshot.baselines,
                                               coverage: coverage, filters: filters)
            if arguments.json {
                printJSON(result.object)
            } else {
                print(result.humanText)
            }
        case "export":
            guard let data = try JournalExport.write(events: snapshot.events, baselines: snapshot.baselines,
                                                     coverage: coverage, filters: filters, output: arguments.output) else {
                if arguments.json {
                    printJSON(["exported": true, "path": arguments.output as Any? ?? NSNull()])
                } else {
                    print("exported \(arguments.output ?? "-")")
                }
                return
            }
            FileHandle.standardOutput.write(data)
        default:
            throw CLIError(message: "journal: unknown subcommand")
        }
    }

    private struct LoadedSnapshot {
        let events: [JournalEvent]
        let baselines: [JournalSnapshot]
        let firstAvailableSequence: Int64?
        let highWaterSequence: Int64
        let retainedFromMs: Int64?
    }

    private static func load(store: JournalReadStore, arguments: Arguments) throws -> LoadedSnapshot {
        let coverage = try store.coverage()
        var events: [JournalEvent] = []
        var cursor = max(0, (coverage.first ?? 1) - 1)
        while cursor < coverage.highWater {
            let page = try autoreleasepool {
                try store.readPage(after: cursor, through: coverage.highWater, limit: 500)
            }
            guard !page.isEmpty else { break }
            events.append(contentsOf: page)
            cursor = page.last!.sequence
        }
        let retainedFrom = events.first?.committedAtMs
        return LoadedSnapshot(events: events, baselines: try store.baselines(),
                              firstAvailableSequence: coverage.first,
                              highWaterSequence: coverage.highWater,
                              retainedFromMs: retainedFrom)
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

    private static func makeFilters(arguments: Arguments, retainedFromMs: Int64?, nowMs: Int64) throws -> JournalQueryFilters {
        let to = try parseTime(arguments.to) ?? nowMs
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
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = layout.database.path + suffix
            if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        }
        if fm.fileExists(atPath: layout.spool.path) {
            for item in try fm.contentsOfDirectory(at: layout.spool, includingPropertiesForKeys: nil) {
                try fm.removeItem(at: item)
            }
        }
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
        """
    }
}
