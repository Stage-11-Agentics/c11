import Foundation

/// Whether to type the mailbox invitation into an already-idle agent.
///
/// State in, decision and arrival out. The AppKit side only fills `Input`
/// and performs the effect. It does not activate the app or change focus.
enum MailboxDoorbell {
    /// Focused panel: an operator key newer than this waits out the rest of
    /// the window. A key exactly this old does not defer.
    static let quietWindow: TimeInterval = 3
    /// Ring attempts older than this no longer count toward `rateCap`.
    /// An attempt exactly this old has expired.
    static let rateWindow: TimeInterval = 600
    static let rateCap = 3
    /// Typed into the agent. Not chrome, so it is not localized.
    static let text = "You have mail: run c11 mailbox recv when you want to receive it."

    enum Decision: Equatable {
        case ring
        /// Not an attempt. `after` is the remaining quiet time.
        case deferRing(after: TimeInterval)
        case skip(reason: String)
    }

    /// What to do with the entry that was just enqueued.
    enum Arrival: Equatable {
        /// Today's `<c11-msg>` paste.
        case push
        case ring
        case deferRing(TimeInterval)
        /// Leave the entry queued for a later prompt-edge flush.
        case keep(reason: String)
        /// Remove this entry from the flush queue. The inbox still holds it.
        case drop(reason: String, capped: Bool)
    }

    struct Input: Equatable {
        var hasUnread: Bool = true
        var stdinDelivery: Bool = true
        var optedOut: Bool = false
        var inFlight: Bool = false
        var flagged: Bool = false
        /// Read by callers. Suppression is never a skip: a parent is waiting.
        var suppressed: Bool = false
        var working: Bool = false
        var waiting: Bool = false
        var confirmedLive: Bool = true
        var phaseIdle: Bool = true
        var turnOutcomeCompleted: Bool = true
        var reportsBlocked: Bool = true
        var rungThisEpoch: Bool = false
        var recentAttempts: Int = 0
        var focused: Bool = false
        var operatorKeyAge: TimeInterval? = nil
        var prompt: PromptInputState? = .empty
        var epoch: String = ""
        var now: Date = Date(timeIntervalSince1970: 0)

        static let absent = Input(
            hasUnread: false,
            confirmedLive: false,
            phaseIdle: false,
            turnOutcomeCompleted: false,
            reportsBlocked: false,
            prompt: nil
        )
    }

    /// Per-panel ring memory. Mark the epoch when an attempt starts, including
    /// a failed paste, so the same idle period is not retried.
    struct Ledger: Equatable {
        var epoch: String?
        var rungEpoch: String?
        var inFlight = false
        var attempts: [Date] = []

        func rung(in epoch: String) -> Bool { rungEpoch == epoch }

        func rings(at now: Date) -> Int {
            attempts.reduce(into: 0) { count, attempt in
                if now.timeIntervalSince(attempt) < MailboxDoorbell.rateWindow {
                    count += 1
                }
            }
        }

        mutating func beginAttempt(at now: Date, epoch: String) {
            inFlight = true
            self.epoch = epoch
            rungEpoch = epoch
            attempts.append(now)
            attempts.removeAll { now.timeIntervalSince($0) >= MailboxDoorbell.rateWindow }
        }

        mutating func endAttempt() {
            inFlight = false
        }
    }

    struct Ledgers: Equatable {
        private var bySurface: [UUID: Ledger] = [:]

        var surfaceIds: Set<UUID> { Set(bySurface.keys) }

        func ledger(for surfaceId: UUID) -> Ledger {
            bySurface[surfaceId] ?? Ledger()
        }

        mutating func update(surfaceId: UUID, _ body: (inout Ledger) -> Void) {
            var ledger = bySurface[surfaceId] ?? Ledger()
            body(&ledger)
            bySurface[surfaceId] = ledger
        }

        /// No-op when the panel was already forgotten, so a late paste
        /// callback does not recreate the ledger.
        mutating func endAttemptIfPresent(surfaceId: UUID) {
            guard var ledger = bySurface[surfaceId] else { return }
            ledger.endAttempt()
            bySurface[surfaceId] = ledger
        }

        mutating func remove(_ surfaceId: UUID) {
            bySurface.removeValue(forKey: surfaceId)
        }

        mutating func retainOnly(surfaceIds: Set<UUID>) {
            bySurface = bySurface.filter { surfaceIds.contains($0.key) }
        }
    }

    static func epoch(sinceMs: Int64, phase: String, turnOutcome: String?) -> String {
        "\(sinceMs)|\(phase)|\(turnOutcome ?? "")"
    }

    static func decide(_ input: Input) -> Decision {
        if !input.hasUnread { return .skip(reason: "no_mail") }
        if !input.stdinDelivery { return .skip(reason: "not_stdin") }
        if input.optedOut { return .skip(reason: "opted_out") }
        if input.inFlight { return .skip(reason: "in_flight") }
        if input.flagged { return .skip(reason: "flagged") }
        if input.working { return .skip(reason: "working") }
        if input.waiting { return .skip(reason: "waiting") }
        if !input.confirmedLive || !input.phaseIdle || !input.turnOutcomeCompleted {
            return .skip(reason: "not_idle")
        }
        if !input.reportsBlocked { return .skip(reason: "harness_ambiguous") }
        if input.rungThisEpoch { return .skip(reason: "once_per_idle") }
        if input.recentAttempts >= rateCap { return .skip(reason: "rate_capped") }
        if input.focused, let age = input.operatorKeyAge, age < quietWindow {
            let remaining = age >= 0 ? (quietWindow - age) : quietWindow
            return .deferRing(after: remaining)
        }
        guard let prompt = input.prompt else { return .skip(reason: "unavailable") }
        if !FeedAnswerPromptCommit.admits(prompt) {
            return .skip(reason: FeedAnswerPromptCommit.refusalReason(prompt))
        }
        return .ring
    }

    static func arrival(for decision: Decision) -> Arrival {
        switch decision {
        case .ring:
            return .ring
        case .deferRing(let after):
            return .deferRing(after)
        case .skip(let reason):
            switch reason {
            case "harness_ambiguous", "opted_out", "not_idle", "not_stdin":
                return .push
            case "once_per_idle":
                return .drop(reason: reason, capped: false)
            case "rate_capped":
                return .drop(reason: reason, capped: true)
            default:
                return .keep(reason: reason)
            }
        }
    }

    /// True when every check except the prompt would ring, and the prompt
    /// has not been read yet. Callers skip the screen read otherwise.
    static func needsPrompt(_ input: Input) -> Bool {
        guard input.prompt == nil else { return false }
        var probe = input
        probe.prompt = .empty
        if case .ring = decide(probe) { return true }
        return false
    }

    /// Mail that was buffered while the agent was working, observed again
    /// at the idle edge. A flush that already delivered it is not also a
    /// ring. Mail still sitting in the queue is rung once when the panel
    /// is an idle Claude Code or OpenCode seat.
    static func arrivalAfterIdleFlush(
        delivered: Bool,
        stillPending: Bool,
        input: Input
    ) -> Arrival? {
        guard !delivered, stillPending else { return nil }
        let effect = arrival(for: decide(input))
        switch effect {
        case .push, .keep(_):
            return nil
        case .ring, .deferRing(_), .drop(_, _):
            return effect
        }
    }

    /// On a submitted invitation, drop the flush queue so those blocks are
    /// not pasted later as `<c11-msg>`. A failed submit leaves the queue.
    static func commitFlushSuppression(
        buffer: inout MailboxStdinBuffer,
        surfaceId: UUID,
        submitted: Bool
    ) -> [MailboxStdinBuffer.Entry] {
        guard submitted else { return [] }
        return buffer.takeQueue(surfaceId: surfaceId)
    }
}
