import Foundation

/// The existing Claude Stop summary, with transcript work bounded independently
/// of the duration of the session. Runs in the short-lived CLI hook process.
public enum ClaudeStopTranscript {
    public static let defaultMaxTailBytes = 256 * 1024

    public struct ReadResult {
        public let lastAssistantMessage: String?
        public let bytesRead: Int
    }

    public static func read(
        path: String,
        maxTailBytes: Int = defaultMaxTailBytes
    ) -> ReadResult? {
        guard maxTailBytes > 0 else { return nil }
        let path = NSString(string: path).expandingTildeInPath
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            return read(fileSize: size, maxTailBytes: maxTailBytes) { offset, length in
                try handle.seek(toOffset: offset)
                return try handle.read(upToCount: length) ?? Data()
            }
        } catch {
            return nil
        }
    }

    /// The production file wrapper uses this same seam. The reader receives
    /// exactly one request, bounded by the cap and the observed file size.
    public static func read(
        fileSize: UInt64,
        maxTailBytes: Int = defaultMaxTailBytes,
        read: (UInt64, Int) throws -> Data
    ) -> ReadResult? {
        guard maxTailBytes > 0 else { return nil }
        let length = Int(min(fileSize, UInt64(maxTailBytes)))
        let offset = fileSize - UInt64(length)
        guard let data = try? read(offset, length) else { return nil }
        let bytesRead = data.count
        var completeRecords = data[...]
        if offset > 0 {
            // Discard the partial JSONL record before decoding: the cutoff can
            // be inside a UTF-8 scalar. An oversized final record falls back.
            guard let newline = completeRecords.firstIndex(of: 0x0A) else {
                return ReadResult(lastAssistantMessage: nil, bytesRead: bytesRead)
            }
            completeRecords = completeRecords.suffix(from: completeRecords.index(after: newline))
        }
        guard let content = String(data: completeRecords, encoding: .utf8) else { return nil }
        var lastAssistantMessage: String?
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  message["role"] as? String == "assistant",
                  let text = messageText(message), !text.isEmpty else { continue }
            lastAssistantMessage = truncate(normalizedSingleLine(text), maxLength: 120)
        }
        return ReadResult(lastAssistantMessage: lastAssistantMessage, bytesRead: bytesRead)
    }

    public static func summary(
        cwd: String?,
        lastAssistantMessage: String?,
        fallbackBody: String?,
        fallbackSubtitle: String?
    ) -> (subtitle: String, body: String)? {
        let projectName: String? = {
            guard let cwd, !cwd.isEmpty else { return nil }
            let path = NSString(string: cwd).expandingTildeInPath
            let tail = URL(fileURLWithPath: path).lastPathComponent
            return tail.isEmpty ? path : tail
        }()
        if let lastAssistantMessage {
            let subtitle = projectName.map { "Completed in \($0)" } ?? "Completed"
            return (subtitle, truncate(lastAssistantMessage, maxLength: 200))
        }
        let lastMessage = fallbackBody ?? fallbackSubtitle
        guard cwd != nil || lastMessage != nil else { return nil }
        var body = "Claude session completed"
        if let projectName, !projectName.isEmpty { body += " in \(projectName)" }
        if let lastMessage, !lastMessage.isEmpty { body += ". Last: \(lastMessage)" }
        return ("Completed", body)
    }

    private static func messageText(_ message: [String: Any]) -> String? {
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let blocks = message["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text", let text = block["text"] as? String else { return nil }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let joined = texts.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func normalizedSingleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxLength - 1))
        return String(value[..<index]) + "…"
    }
}
