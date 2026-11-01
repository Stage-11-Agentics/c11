import Foundation

/// A short-lived, forward-only transcript observer. It never returns transcript
/// contents to the caller and never scans session history for an old invitation.
final class ClaudeMailboxAcceptance {
    static let invitation = "c11 mail waiting: run c11 mailbox recv --ack"
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

/// Pure checks for the Grok leader route. The sidecar holds no transcript and
/// reads only Grok's session registry and the leader's protocol echoes.
enum GrokMailboxAcceptance {
    /// Grok exposes no "displayed session" signal. Its registry lists every
    /// session a TUI process has open, so native delivery is allowed only while
    /// this process holds exactly the bound session. Any `/new`, `/resume` or
    /// dashboard dispatch adds an entry, and the panel falls back to typed mail.
    static func showsOnlyBoundSession(registry: Data, pid: Int32, birthMicros: UInt64?,
                                      sessionID: String) -> Bool {
        guard registry.count <= 1024 * 1024,
              let entries = (try? JSONSerialization.jsonObject(with: registry)) as? [[String: Any]] else { return false }
        let mine = entries.filter { entry in
            guard (entry["pid"] as? NSNumber)?.int64Value == Int64(pid) else { return false }
            // A recorded start time far from this process's birth is a reused PID.
            if let start = (entry["pid_start"] as? NSNumber)?.uint64Value, let birthMicros {
                let delta = start > birthMicros ? start - birthMicros : birthMicros - start
                if delta > 2_000_000 { return false }
            }
            return true
        }
        guard mine.count == 1, let session = mine[0]["session_id"] as? String else { return false }
        return session.lowercased() == sessionID.lowercased()
    }

    /// True for a leader echo showing the invitation entered the bound session:
    /// its prompt queue entry, or its user message.
    static func confirms(frame: [String: Any], sessionID: String) -> Bool {
        guard let params = frame["params"] as? [String: Any],
              (params["sessionId"] as? String)?.lowercased() == sessionID.lowercased() else { return false }
        switch frame["method"] as? String {
        case "_x.ai/queue/changed":
            return (params["entries"] as? [[String: Any]] ?? []).contains {
                ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == ClaudeMailboxAcceptance.invitation
            }
        case "session/update":
            guard let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "user_message_chunk",
                  let content = update["content"] as? [String: Any],
                  let text = content["text"] as? String else { return false }
            return text.contains(ClaudeMailboxAcceptance.invitation)
        default:
            return false
        }
    }
}
