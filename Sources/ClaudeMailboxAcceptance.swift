import Foundation

/// A short-lived, forward-only transcript observer. It never returns transcript
/// contents to the caller and never scans session history for an old invitation.
final class ClaudeMailboxAcceptance {
    static let invitation = "You have mail: run c11 mailbox recv --ack when you want to receive it."
    private let path: String
    private let sessionID: String
    private let earliestNewFileRecord: Date?
    private var handle: FileHandle?
    private var pending = Data()
    private var discardingLine = false
    private static let lineLimit = 1024 * 1024

    init(path: String, sessionID: String) throws {
        self.path = path
        self.sessionID = sessionID
        let existed = FileManager.default.fileExists(atPath: path)
        // Claude records milliseconds. A file that appears after this offer
        // may contain restored history, so byte zero alone is not freshness.
        earliestNewFileRecord = existed ? nil : Date(timeIntervalSince1970:
            floor(Date().timeIntervalSince1970 * 1_000) / 1_000)
        if existed {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            _ = try file.seekToEnd()
            handle = file
        }
    }

    deinit { try? handle?.close() }

    /// Called only while one offered invitation awaits confirmation. Reading
    /// is bounded per call; a partial JSON line is retained until its newline.
    func observe() throws -> Bool {
        if handle == nil, FileManager.default.fileExists(atPath: path) {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        }
        guard let data = try handle?.read(upToCount: 64 * 1024), !data.isEmpty else { return false }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if discardingLine { discardingLine = false; continue }
            if Self.confirms(line, sessionID: sessionID, notBefore: earliestNewFileRecord) { return true }
        }
        if pending.count > Self.lineLimit {
            pending.removeAll(keepingCapacity: false)
            discardingLine = true
        }
        return false
    }

    static func confirms(_ line: Data, sessionID: String, notBefore: Date? = nil) -> Bool {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              record["type"] as? String == "user",
              record["sessionId"] as? String == sessionID,
              let message = record["message"] as? [String: Any],
              message["role"] as? String == "user" else { return false }
        if let notBefore {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let timestamp = record["timestamp"] as? String,
                  let created = formatter.date(from: timestamp), created >= notBefore else { return false }
        }
        let text: String
        if let content = message["content"] as? String {
            text = content
        } else if let blocks = message["content"] as? [[String: Any]],
                  blocks.count == 1, blocks[0]["type"] as? String == "text",
                  let content = blocks[0]["text"] as? String {
            text = content
        } else { return false }
        // Claude wraps inbox input as a peer message. A typed invitation, an
        // assistant quote, or a larger message mentioning it is not evidence.
        return text.hasPrefix("Another Claude session sent a message:\n\(invitation)\n\n")
    }
}
