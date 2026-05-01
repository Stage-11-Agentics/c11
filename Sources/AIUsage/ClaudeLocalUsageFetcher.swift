import Foundation

enum ClaudeLocalUsageFetcher {
    struct Entry {
        var timestamp: Date
        var model: String
        var inputTokens: Int
        var outputTokens: Int
        var cacheCreation: Int
        var cacheRead: Int
    }

    private static let sessionWindowSeconds: TimeInterval = 18_000
    private static let weekWindowSeconds: TimeInterval = 604_800

    static func fetchUsage(account: AIUsageAccount) async throws -> AIUsageWindows {
        let entries = try await allEntries()
        let now = Date()

        let sessionCutoff = now.addingTimeInterval(-sessionWindowSeconds)
        let weekCutoff = now.addingTimeInterval(-weekWindowSeconds)

        let sessionEntries = entries.filter { $0.timestamp >= sessionCutoff }
        let weekEntries = entries.filter { $0.timestamp >= weekCutoff }

        let sessionTokens = sessionEntries.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens + $1.cacheCreation + $1.cacheRead
        }
        let weekTokens = weekEntries.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens + $1.cacheCreation + $1.cacheRead
        }
        let sessionCost = sessionEntries.reduce(0.0) { $0 + cost(for: $1) }
        let weekCost = weekEntries.reduce(0.0) { $0 + cost(for: $1) }

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
            costUSD: sessionCost
        )
        let weekWindow = AIUsageWindow(
            utilization: 0,
            resetsAt: nil,
            windowSeconds: weekWindowSeconds,
            tokensUsed: weekTokens,
            costUSD: weekCost
        )
        return AIUsageWindows(session: sessionWindow, week: weekWindow)
    }

    static func allEntries() async throws -> [Entry] {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return []
        }

        // Only read files touched within the longest window we care about (7 days).
        // ~/.claude/projects may have thousands of JSONL files; pre-filtering by
        // modification date avoids opening stale ones.
        let weekCutoff = Date().addingTimeInterval(-weekWindowSeconds)

        var jsonlFiles: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard values?.isRegularFile == true else { continue }
                guard let modDate = values?.contentModificationDate, modDate >= weekCutoff else { continue }
                jsonlFiles.append(url)
            }
        }

        let iso = ISO8601DateFormatter()
        var entries: [Entry] = []

        for file in jsonlFiles {
            let content: String
            do {
                content = try String(contentsOf: file, encoding: .utf8)
            } catch {
                continue
            }
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                guard (json["type"] as? String) == "assistant",
                      let message = json["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let model = message["model"] as? String,
                      let timestampStr = json["timestamp"] as? String,
                      let timestamp = iso.date(from: timestampStr)
                else { continue }

                entries.append(Entry(
                    timestamp: timestamp,
                    model: model,
                    inputTokens: (usage["input_tokens"] as? Int) ?? 0,
                    outputTokens: (usage["output_tokens"] as? Int) ?? 0,
                    cacheCreation: (usage["cache_creation_input_tokens"] as? Int) ?? 0,
                    cacheRead: (usage["cache_read_input_tokens"] as? Int) ?? 0
                ))
            }
        }

        return entries.sorted { $0.timestamp < $1.timestamp }
    }

    static func cost(for entry: Entry) -> Double {
        let model = entry.model.lowercased()
        let inputRate: Double
        let outputRate: Double
        let cacheCreateRate: Double
        let cacheReadRate: Double

        if model.contains("opus-4") {
            inputRate = 15.0; outputRate = 75.0
            cacheCreateRate = 18.75; cacheReadRate = 1.50
        } else if model.contains("haiku-4") {
            inputRate = 0.80; outputRate = 4.0
            cacheCreateRate = 1.0; cacheReadRate = 0.08
        } else {
            inputRate = 3.0; outputRate = 15.0
            cacheCreateRate = 3.75; cacheReadRate = 0.30
        }

        let m = 1_000_000.0
        return (Double(entry.inputTokens) * inputRate
              + Double(entry.outputTokens) * outputRate
              + Double(entry.cacheCreation) * cacheCreateRate
              + Double(entry.cacheRead) * cacheReadRate) / m
    }
}
