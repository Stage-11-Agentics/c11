import Foundation

/// Writes the envelope as a `<c11-msg>` framed block into the recipient
/// surface's PTY. Formatting is a pure function (off-main); the PTY write
/// itself is a main-actor hop.
///
/// **The 500 ms `timeout` is a reporting bound, not a runtime bound.**
/// `MainActor.run { writer(...) }` is synchronous, and Swift task
/// cancellation is cooperative — the `withTaskGroup` race returns
/// `.timeout` after 500 ms but cannot interrupt a `writer` closure that
/// is already executing on the main thread. If Ghostty's PTY write blocks
/// for three seconds, main is blocked for three seconds, we log "timeout"
/// after 500 ms, and the dispatcher moves on. The main thread's actual
/// occupancy is governed by the writer closure, not this deadline.
///
/// In practice the production writer at `Sources/Workspace.swift` calls
/// `TerminalPanel.sendText(text)` which is a buffered byte append — it
/// returns in microseconds. But "in practice" is not a guarantee, and
/// the honest path forward (genuine async-cancellable PTY writes) is
/// follow-up work. The reporting bound keeps the dispatcher live; that
/// is what this code enforces, and what tests here verify.
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

    /// Closure the dispatcher injects so the handler can resolve a
    /// TerminalPanel (or whatever write sink) on the main actor.
    ///
    /// The outcome set is deliberately narrow: Stage 2's production writer
    /// (`Sources/Workspace.swift`) returns `.ok` / `.surfaceNotFound` /
    /// `.surfaceNotTerminal` and never surfaces PTY write errors. EIO /
    /// EPIPE propagation from `GhosttyTerminalView.sendText()` is
    /// follow-up work — tracked with the genuine async-cancellable
    /// writer (see plan risks, Stage 2 P0 #5/#6). Until that lands,
    /// "real PTY write failure → dispatcher log" is not a Stage 2
    /// contract.
    typealias Writer = @MainActor (_ surfaceId: UUID, _ bytes: String) -> WriteOutcome

    enum WriteOutcome: Equatable {
        case ok(bytes: Int)
        case surfaceNotFound
        case surfaceNotTerminal
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
        let writer = self.writer
        let timeoutDuration = self.timeout

        // We need the timeout branch to return *immediately* when it fires —
        // a `withTaskGroup` race would wait for both child tasks to finish
        // before the group closure returns, which means a writer that blocks
        // its thread (Thread.sleep on the main actor, a synchronous PTY
        // write that stalls) would pin deliver for the full block. The
        // continuation pattern races two unstructured Tasks and resumes on
        // whichever signals first; the loser keeps running until the system
        // collects it, which matches the reporting-bound contract documented
        // above.
        let gate = ContinuationGate()
        return await withCheckedContinuation { (cont: CheckedContinuation<MailboxDispatcher.HandlerInvocationResult, Never>) in
            let elapsedMs: @Sendable () -> Int = {
                Int(Date().timeIntervalSince(start) * 1000)
            }

            Task {
                let outcome: WriteOutcome = await MainActor.run {
                    writer(surfaceId, block)
                }
                let result: MailboxDispatcher.HandlerInvocationResult
                switch outcome {
                case .ok(let bytes):
                    result = .init(outcome: .ok, bytes: bytes, elapsedMs: elapsedMs())
                case .surfaceNotFound, .surfaceNotTerminal:
                    result = .init(outcome: .closed, bytes: 0, elapsedMs: elapsedMs())
                }
                if gate.tryFire() { cont.resume(returning: result) }
            }

            Task {
                try? await Task.sleep(nanoseconds: Self.nanoseconds(from: timeoutDuration))
                if gate.tryFire() {
                    cont.resume(returning: .init(outcome: .timeout, bytes: 0, elapsedMs: elapsedMs()))
                }
            }
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

/// One-shot latch that lets exactly one of the writer/timeout tasks resume the
/// `withCheckedContinuation` in `StdinMailboxHandler.deliver`. The loser still
/// runs to completion (Swift task cancellation is cooperative; a main-thread
/// `Thread.sleep` won't react), but it won't fire the continuation a second
/// time and trip the checked-continuation trap.
private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func tryFire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
