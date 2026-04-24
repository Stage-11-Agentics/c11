import Foundation

/// Writes the envelope as a `<c11-msg>` framed block into the recipient
/// surface's PTY. Formatting is a pure function (off-main); the PTY write
/// is a main-actor hop bounded by a 500 ms deadline per the plan.
///
/// Framed block shape (exact, byte-for-byte, trailing newline included):
///
///     \n
///     <c11-msg from="builder" id="01K..." ts="..." to="watcher">\n
///     escaped body bytes\n
///     </c11-msg>\n
///
/// Attribute values and the body are XML-escaped (`<`, `>`, `&`, `"`) so a
/// literal `</c11-msg>` in the body cannot forge a closing tag. This is a
/// deliberate security property of the framing per design doc §prose.
final class StdinMailboxHandler: MailboxHandler {

    /// Closure the dispatcher injects so the handler can resolve a TerminalPanel
    /// (or whatever write sink) on the main actor. Returning nil → `eio`.
    typealias Writer = @MainActor (_ surfaceId: UUID, _ bytes: String) -> WriteOutcome

    enum WriteOutcome: Equatable {
        case ok(bytes: Int)
        case surfaceNotFound
        case surfaceNotTerminal
        case closed
        case eio
    }

    let writer: Writer
    let timeout: Duration

    init(
        writer: @escaping Writer,
        timeout: Duration = .milliseconds(500)
    ) {
        self.writer = writer
        self.timeout = timeout
    }

    func deliver(
        envelope: MailboxEnvelope,
        to surfaceId: UUID,
        surfaceName: String
    ) async -> MailboxDispatcher.HandlerInvocationResult {
        let block = Self.formatFramedBlock(envelope: envelope)
        let start = Date()

        return await withTaskGroup(
            of: MailboxDispatcher.HandlerInvocationResult.self
        ) { group in
            let writer = self.writer
            let elapsed: () -> Int = {
                Int(Date().timeIntervalSince(start) * 1000)
            }

            group.addTask {
                let outcome: WriteOutcome = await MainActor.run {
                    writer(surfaceId, block)
                }
                switch outcome {
                case .ok(let bytes):
                    return .init(
                        outcome: .ok,
                        bytes: bytes,
                        elapsedMs: elapsed()
                    )
                case .surfaceNotFound, .surfaceNotTerminal:
                    return .init(outcome: .closed, bytes: 0, elapsedMs: elapsed())
                case .closed:
                    return .init(outcome: .closed, bytes: 0, elapsedMs: elapsed())
                case .eio:
                    return .init(outcome: .eio, bytes: 0, elapsedMs: elapsed())
                }
            }

            group.addTask { [timeout] in
                try? await Task.sleep(nanoseconds: Self.nanoseconds(from: timeout))
                return .init(outcome: .timeout, bytes: 0, elapsedMs: elapsed())
            }

            let first = await group.next() ?? .init(outcome: .timeout)
            group.cancelAll()
            return first
        }
    }

    private static func nanoseconds(from duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        let nanos = UInt64(seconds) * 1_000_000_000
            + UInt64(attoseconds / 1_000_000_000)
        return nanos
    }

    // MARK: - Formatting

    /// Deterministic attribute order: the schema's required/optional ordering
    /// preserved so tests can pin the exact byte shape. Optional attributes
    /// are emitted only when present.
    static let attributeOrder: [String] = [
        "from", "id", "ts",
        "to", "topic",
        "reply_to", "in_reply_to",
        "urgent", "ttl_seconds",
    ]

    static func formatFramedBlock(envelope: MailboxEnvelope) -> String {
        var attrs: [(String, String)] = []
        attrs.append(("from", envelope.from))
        attrs.append(("id", envelope.id))
        attrs.append(("ts", envelope.ts))
        if let to = envelope.to { attrs.append(("to", to)) }
        if let topic = envelope.topic { attrs.append(("topic", topic)) }
        if let replyTo = envelope.replyTo { attrs.append(("reply_to", replyTo)) }
        if let inReplyTo = envelope.inReplyTo { attrs.append(("in_reply_to", inReplyTo)) }
        if envelope.urgent == true { attrs.append(("urgent", "true")) }
        if let ttl = envelope.ttlSeconds { attrs.append(("ttl_seconds", String(ttl))) }

        let attrString = attrs
            .map { "\($0.0)=\"\(xmlEscapeAttribute($0.1))\"" }
            .joined(separator: " ")
        let openTag = "<c11-msg " + attrString + ">"
        let body = xmlEscapeBody(envelope.body)

        return "\n\(openTag)\n\(body)\n</c11-msg>\n"
    }

    /// XML escaping for attribute values — covers `<`, `>`, `&`, and `"`.
    static func xmlEscapeAttribute(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            case "\"": result.append("&quot;")
            default: result.append(ch)
            }
        }
        return result
    }

    /// XML escaping for body text — covers `<`, `>`, `&`. Quotes are fine in
    /// body text; only attribute values need them escaped.
    static func xmlEscapeBody(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            default: result.append(ch)
            }
        }
        return result
    }
}
