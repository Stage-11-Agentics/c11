import Foundation

/// C11H-306: one read of a headless terminal's composer through hc.
///
/// A panel restored with no Ghostty surface (a hidden workspace after a relaunch, a locked screen) still has a
/// terminal whose screen hc keeps in its own libghostty-vt. `terminal.attach` with `observe: true` opens a second,
/// watch-only viewer on it: hc never resizes for an observer and never takes input from it, and its first paint
/// is that screen rendered by Ghostty's VT formatter, styles and cursor included. The read takes the paint, closes
/// its own channel, and leaves the panel's own attachment (its input, its size) untouched.
///
/// A read never costs the shared connection: its sink only consumes or goes stale (which closes this channel
/// alone), a timed-out or cancelled attach is closed by the engine when its late reply comes, and a paint that does
/// not parse is c11's own business. It never connects or launches a core; with no live connection it fails.
enum HCComposerReadFailure: String, Error, Sendable, Equatable {
    /// No verified connection to the core right now.
    case unreachable = "hc_unreachable"
    /// The inventory does not list the terminal as running, or it has no wire address.
    case unavailable
    /// hc refused or did not answer the attach.
    case refused = "attach_refused"
    case timedOut = "attach_timeout"
    /// hc's end of the screen (`HCPaint`) did not arrive within the read's bound: the paint is not whole.
    case unterminated = "paint_unterminated"
    /// More bytes than any paint of a bounded screen.
    case oversize
    /// hc ended the stream before the paint settled (the terminal ended).
    case ended
    /// What arrived was not hc 0.1.16's paint (`HCPaint.prelude`).
    case noPaint = "no_paint"
    /// This terminal's previous read's attach is still unanswered on this connection: no second attach behind it
    /// until hc's late reply, so a core that stopped answering cannot fill the connection's budget of unanswered
    /// attaches.
    case attachUnanswered = "attach_unanswered"
    case cancelled
}

struct HCComposerPaint: Sendable, Equatable {
    let bytes: Data
    let grid: HCGridSize
}

/// One read's channel sink. It only collects; it never fails the shared engine (`.failed` would close the
/// connection every terminal shares). Past its byte limit it goes stale, which closes this channel alone.
final class HCComposerPaintSink: HCOutputSink, @unchecked Sendable {
    struct State {
        var bytes = Data()
        var overflowed = false
        var retired = false
    }

    private let lock = NSLock()
    private var state = State()
    let limit: Int

    init(limit: Int) { self.limit = limit }

    func consume(_ chunk: HCOutputChunk) async -> HCOutputConsumption {
        lock.lock()
        defer { lock.unlock() }
        guard !state.overflowed, !state.retired else { return .stale }
        guard chunk.bytes.count <= limit - state.bytes.count else {
            state.overflowed = true
            return .stale
        }
        state.bytes.append(chunk.bytes)
        return .consumed
    }

    func retire(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        state.retired = true
        lock.unlock()
        completion()
    }

    var snapshot: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

enum HCComposerPaintRead {
    /// A paint of the largest bounded screen (1024 x 512 cells, styled) stays well under this.
    nonisolated(unsafe) static var byteLimit = 256 * 1024
    /// How long the whole paint may take to arrive after the attach reply. A paint is judged only once hc's own
    /// end of the screen has arrived (`HCPaint.section`), never after a quiet time.
    nonisolated(unsafe) static var capNanoseconds: UInt64 = 1_000_000_000
    /// The attach's reply bound, from when the request reached the socket.
    nonisolated(unsafe) static var attachSeconds: TimeInterval = 2
    /// How long the attach may wait to be sent: behind other panels' input on the shared connection (a delayed
    /// Return holds every RPC behind it), so a fleet burst delays a read rather than failing it.
    nonisolated(unsafe) static var queueSeconds: TimeInterval = 15
    static let pollNanoseconds: UInt64 = 2_000_000

    /// Attaches as an observer, collects the first paint until hc's end of the screen has arrived, closes the
    /// channel. `grid` is the size the caller knows; the attach reply's own record wins when it carries one, since
    /// the paint is drawn at that size.
    /// `lateReply`, when given, follows the attach after the read stops waiting for it (C11H-327).
    static func read(connection: any HCConnection, address: String, grid: HCGridSize, lateReply: HCLateReply? = nil) async
        -> Result<HCComposerPaint, HCComposerReadFailure> {
        let params: HCJSONValue = .object([
            "terminal": .string(address),
            "cols": .integer(Int64(grid.columns)),
            "rows": .integer(Int64(grid.rows)),
            "history": .integer(0),
            "observe": .bool(true),
        ])
        let reply: HCJSONValue
        do {
            reply = try await connection.request(HCRPCRequest(method: "terminal.attach", params: params,
                deadlineUptimeNanoseconds: HCMonotonic.deadline(after: queueSeconds),
                responseNanosecondsAfterTransmission: UInt64(attachSeconds * 1_000_000_000), lateReply: lateReply))
        } catch let failure as HCRPCFailure {
            switch failure.reason {
            case .cancelled: return .failure(.cancelled)
            case .deadlineExceeded: return .failure(.timedOut)
            default: return .failure(.refused)
            }
        } catch {
            return .failure(Task.isCancelled ? .cancelled : .refused)
        }
        guard case .integer(let raw) = reply["channel"], let channelID = UInt32(exactly: raw), channelID > 0 else {
            return .failure(.refused)
        }
        var size = grid
        if case .integer(let cols) = reply["terminal"]["cols"], case .integer(let rows) = reply["terminal"]["rows"],
           let c = UInt16(exactly: cols), let r = UInt16(exactly: rows), c > 0, r > 0 {
            size = HCGridSize(columns: c, rows: r)
        }
        let sink = HCComposerPaintSink(limit: byteLimit)
        let channel: any HCChannel
        do {
            channel = try await connection.registerChannel(channelID, attachmentGeneration: 0, sink: sink)
        } catch {
            return .failure(Task.isCancelled ? .cancelled : .refused)
        }
        defer { channel.close() }
        do {
            try await channel.activate()
        } catch {
            if Task.isCancelled { return .failure(.cancelled) }
            return .failure(sink.snapshot.overflowed ? .oversize : .ended)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        while true {
            if Task.isCancelled { return .failure(.cancelled) }
            let state = sink.snapshot
            if state.overflowed { return .failure(.oversize) }
            switch HCPaint.section(state.bytes) {
            case .screen:
                return .success(HCComposerPaint(bytes: state.bytes, grid: size))
            case .unrecognized:
                return .failure(.noPaint)
            case .unterminated:
                break
            }
            if state.retired { return .failure(.ended) }
            if DispatchTime.now().uptimeNanoseconds &- started >= capNanoseconds {
                return .failure(state.bytes.isEmpty ? .noPaint : .unterminated)
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }
}

/// What a headless composer read came to, in the screen path's terms.
struct HCComposerObservation: Sendable, Equatable {
    let state: PromptInputState
    /// Why the read is `unknown` or `unavailable`: a read failure or why the paint was not a faithful screen.
    let why: String?
    /// The typed text of a draft, for the exact doorbell comparison before a Return. Transient: never stored,
    /// logged or sent anywhere.
    let composer: String?

    static func failed(_ failure: HCComposerReadFailure) -> Self {
        Self(state: .unavailable, why: failure.rawValue, composer: nil)
    }

    /// The paint replayed and classified exactly as the screen path classifies its own capture.
    static func classify(_ paint: HCComposerPaint, harness: String?) -> Self {
        guard let screen = HCPaintScreen.replay(paint.bytes, columns: Int(paint.grid.columns), rows: Int(paint.grid.rows)) else {
            return Self(state: .unknown, why: "grid", composer: nil)
        }
        guard screen.isComplete, let region = screen.promptRegion(harness: harness) else {
            return Self(state: .unknown, why: "paint_" + (screen.incompleteReason ?? "unread"), composer: nil)
        }
        let classification = PromptInputClassifier.classify(region, harness: harness)
        let composer: String? = classification.state == .draft
            ? PromptInputClassifier.composerText(region, harness: harness) : nil
        let why = classification.state == .unknown ? "composer_shape" : nil
        return Self(state: classification.state, why: why, composer: composer)
    }

    static func from(_ result: Result<HCComposerPaint, HCComposerReadFailure>, harness: String?) -> Self {
        switch result {
        case .success(let paint): return classify(paint, harness: harness)
        case .failure(let failure): return failed(failure)
        }
    }
}

/// C11H-306: a session that can read a terminal's paint: the managed session (one core), and the shard routers
/// in front of it. Not part of `HCSession`, which the CLI also compiles.
protocol HCComposerPaintReading: Sendable {
    func readComposerPaint(_ key: HCTerminalKey) async -> Result<HCComposerPaint, HCComposerReadFailure>
}

extension HCManagedSession: HCComposerPaintReading {}
extension HCShardPool: HCComposerPaintReading {}
extension HCShardRoute: HCComposerPaintReading {}

/// C11H-306: one read and its classification, off the main thread. `harness` is the panel's terminal type.
enum HCHeadlessComposer {
    static func read(session: any HCSession, key: HCTerminalKey, harness: String?) async -> HCComposerObservation {
        guard let reader = session as? any HCComposerPaintReading else { return .failed(.unavailable) }
        return await classify(reader.readComposerPaint(key), harness: harness)
    }

    static func classify(_ result: Result<HCComposerPaint, HCComposerReadFailure>, harness: String?) async
        -> HCComposerObservation {
        HCComposerObservation.from(result, harness: harness)
    }
}
