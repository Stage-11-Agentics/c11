import Foundation

/// Append-only NDJSON log of dispatch events for one workspace. Writes ride
/// through a dedicated serial queue at `.utility` QoS so the dispatcher hot
/// path can fire-and-forget; tests and shutdown paths use `flush()` to block
/// until the queue drains.
///
/// Schema matches `docs/c11-messaging-primitive-design.md` §6. Event types:
/// `received`, `resolved`, `copied`, `handler`, `rejected`, `cleaned`,
/// `replayed`, `gc`.
final class MailboxDispatchLog {

    let url: URL

    private let queue: DispatchQueue
    private var fileHandle: FileHandle?

    init(url: URL, label: String = "com.stage11.c11.mailbox.log") {
        self.url = url
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    deinit {
        try? fileHandle?.close()
    }

    /// Enqueues an append on the log queue; returns immediately.
    func append(_ event: Event, now: Date = Date()) {
        let line = Self.serialize(event: event, at: now)
        queue.async { [weak self] in
            self?.writeLine(line)
        }
    }

    /// Blocks until all previously-enqueued appends have completed.
    func flush() {
        queue.sync { }
    }

    // MARK: - Event model

    enum Event {
        case received(id: String, from: String, to: String?, topic: String?)
        case resolved(id: String, recipients: [String])
        case copied(id: String, recipient: String)
        case handler(
            id: String,
            recipient: String,
            handler: String,
            outcome: HandlerOutcome,
            bytes: Int?,
            elapsedMs: Int?
        )
        case rejected(id: String?, reason: String)
        case cleaned(id: String)
        case replayed(id: String)
        case gc(tempFilesRemoved: Int)
    }

    /// Dispatcher-observable outcomes for a single handler invocation.
    ///
    /// - `ok`: handler signalled success (bytes written, silent drop, etc.).
    /// - `timeout`: dispatcher gave up waiting for the handler Task. This
    ///   is a reporting bound — the handler closure may still be running;
    ///   see `StdinMailboxHandler` docs for the honest story.
    /// - `closed`: recipient surface is not available (missing, wrong
    ///   panel type, etc.). Emitted by the stdin handler when the surface
    ///   lookup fails.
    /// - `eio`: the dispatcher itself failed to stage the envelope for the
    ///   handler — inbox write failure or unknown handler name. Not the
    ///   same as "real PTY write errno 5"; Stage 2 does not propagate
    ///   PTY write errors (follow-up; see plan risks).
    ///
    /// The previously-declared `.epipe` variant was never produced and
    /// was removed in review cycle 1 rework.
    enum HandlerOutcome: String {
        case ok, timeout, eio, closed
    }

    // MARK: - File I/O

    private func writeLine(_ line: String) {
        do {
            if fileHandle == nil {
                let parent = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let fh = try FileHandle(forWritingTo: url)
                try fh.seekToEnd()
                fileHandle = fh
            }
            if let data = line.data(using: .utf8) {
                try fileHandle?.write(contentsOf: data)
            }
        } catch {
            // Best-effort: on failure, drop the handle so the next call retries
            // from scratch. Log write failures are intentionally silent — the
            // dispatcher must not block on observability.
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    // MARK: - Serialization

    /// Emits one NDJSON line (trailing '\n'). Keys sort-encoded so tails are
    /// stable across runs. Omits nil fields rather than encoding `null`.
    static func serialize(event: Event, at now: Date) -> String {
        var payload: [String: Any] = [
            "ts": formatTimestamp(now),
        ]
        switch event {
        case .received(let id, let from, let to, let topic):
            payload["event"] = "received"
            payload["id"] = id
            payload["from"] = from
            if let to { payload["to"] = to }
            if let topic { payload["topic"] = topic }
        case .resolved(let id, let recipients):
            payload["event"] = "resolved"
            payload["id"] = id
            payload["recipients"] = recipients
        case .copied(let id, let recipient):
            payload["event"] = "copied"
            payload["id"] = id
            payload["recipient"] = recipient
        case .handler(let id, let recipient, let handler, let outcome, let bytes, let elapsedMs):
            payload["event"] = "handler"
            payload["id"] = id
            payload["recipient"] = recipient
            payload["handler"] = handler
            payload["outcome"] = outcome.rawValue
            if let bytes { payload["bytes"] = bytes }
            if let elapsedMs { payload["elapsed_ms"] = elapsedMs }
        case .rejected(let id, let reason):
            payload["event"] = "rejected"
            if let id { payload["id"] = id }
            payload["reason"] = reason
        case .cleaned(let id):
            payload["event"] = "cleaned"
            payload["id"] = id
        case .replayed(let id):
            payload["event"] = "replayed"
            payload["id"] = id
        case .gc(let removed):
            payload["event"] = "gc"
            payload["temp_files_removed"] = removed
        }

        guard
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            ),
            let line = String(data: data, encoding: .utf8)
        else {
            return "\n"
        }
        return line + "\n"
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
