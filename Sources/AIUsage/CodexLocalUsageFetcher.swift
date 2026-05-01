import Foundation
import SQLite3

enum CodexAIUsageFetchError: Error, LocalizedError, C11AppOwnedError {
    case network
    case decoding

    var isAppOwned: Bool { true }

    var errorDescription: String? {
        switch self {
        case .network:
            return String(
                localized: "aiusage.codex.error.network",
                defaultValue: "Codex local database not found or unreadable."
            )
        case .decoding:
            return String(
                localized: "aiusage.codex.error.decoding",
                defaultValue: "Could not read Codex usage data."
            )
        }
    }
}

enum CodexLocalUsageFetcher {
    struct Entry {
        var timestamp: Date
        var model: String
        var tokensUsed: Int
    }

    private static let sessionWindowSeconds: TimeInterval = 18_000
    private static let weekWindowSeconds: TimeInterval = 604_800

    static func fetchUsage(account: AIUsageAccount) async throws -> AIUsageWindows {
        let entries = try allEntries()
        let now = Date()

        let sessionCutoff = now.addingTimeInterval(-sessionWindowSeconds)
        let weekCutoff = now.addingTimeInterval(-weekWindowSeconds)

        let sessionEntries = entries.filter { $0.timestamp >= sessionCutoff }
        let weekEntries = entries.filter { $0.timestamp >= weekCutoff }

        let sessionTokens = sessionEntries.reduce(0) { $0 + $1.tokensUsed }
        let weekTokens = weekEntries.reduce(0) { $0 + $1.tokensUsed }
        // tokens_used counts cumulative context size per request, not net billed tokens,
        // so derived cost figures are unreliable. Show token counts only.

        let limit = account.sessionTokenLimit
        let utilization: Int
        if limit > 0 {
            utilization = min(100, Int(Double(sessionTokens) / Double(limit) * 100.0))
        } else {
            utilization = 0
        }

        let resetsAt: Date?
        if let earliest = sessionEntries.first?.timestamp {
            resetsAt = earliest.addingTimeInterval(sessionWindowSeconds)
        } else {
            resetsAt = nil
        }

        let sessionWindow = AIUsageWindow(
            utilization: utilization,
            resetsAt: resetsAt,
            windowSeconds: sessionWindowSeconds,
            tokensUsed: sessionTokens,
            costUSD: 0
        )
        let weekWindow = AIUsageWindow(
            utilization: 0,
            resetsAt: nil,
            windowSeconds: weekWindowSeconds,
            tokensUsed: weekTokens,
            costUSD: 0
        )
        return AIUsageWindows(session: sessionWindow, week: weekWindow)
    }

    static func allEntries() throws -> [Entry] {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite").path

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            throw CodexAIUsageFetchError.network
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT created_at, model, tokens_used FROM threads WHERE tokens_used > 0 ORDER BY created_at ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CodexAIUsageFetchError.decoding
        }
        defer { sqlite3_finalize(stmt) }

        var entries: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_int64(stmt, 0)
            let modelPtr = sqlite3_column_text(stmt, 1)
            let model = modelPtr.map { String(cString: $0) } ?? "gpt-4o"
            let tokens = Int(sqlite3_column_int64(stmt, 2))
            guard tokens > 0 else { continue }
            entries.append(Entry(
                timestamp: Date(timeIntervalSince1970: Double(ts)),
                model: model,
                tokensUsed: tokens
            ))
        }
        return entries
    }

}
