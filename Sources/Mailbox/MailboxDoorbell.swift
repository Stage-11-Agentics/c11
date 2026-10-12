import Foundation

/// Whether to type the one-line mailbox invitation.
///
/// The stdin gate decides the moment (an open agent prompt, including the
/// quiet-window recheck). This type decides whether that moment may type.
/// It never asks for a `<c11-msg>` paste. The AppKit side fills `Input` and
/// performs the effect. It does not activate the app or change focus.
enum MailboxDoorbell {
    /// Focused panel: an operator key newer than this waits out the rest of
    /// the window. A key exactly this old does not defer.
    static let quietWindow: TimeInterval = 3
    /// Ring attempts older than this no longer count toward `rateCap`.
    /// An attempt exactly this old has expired.
    static let rateWindow: TimeInterval = 600
    static let rateCap = 3
    /// Typed into the agent. Not chrome, so it is not localized.
    static let text = "You have mail: run c11 mailbox recv --ack when you want to receive it."

    enum Decision: Equatable {
        case ring
        /// Not an attempt. `after` is the remaining quiet time.
        case deferRing(after: TimeInterval)
        case skip(reason: String)
    }

    /// What to do with the entry that was just enqueued. There is no paste.
    enum Arrival: Equatable {
        case ring
        case deferRing(TimeInterval)
        /// Leave the entry queued. Nothing is typed.
        case keep(reason: String)
    }

    struct Input: Equatable {
        var hasUnread: Bool = true
        var stdinDelivery: Bool = true
        var optedOut: Bool = false
        var inFlight: Bool = false
        var flagged: Bool = false
        /// Read by callers. Suppression is never a skip: a parent is waiting.
        var suppressed: Bool = false
        var rungThisEpoch: Bool = false
        var recentAttempts: Int = 0
        var focused: Bool = false
        var operatorKeyAge: TimeInterval? = nil
        var prompt: PromptInputState? = .empty
        var epoch: String = ""
        var now: Date = Date(timeIntervalSince1970: 0)

        static let absent = Input(hasUnread: false, prompt: nil)
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

        /// Hold a second ring off while this one's inbox check is in flight.
        /// Does not consume the idle period.
        mutating func reserve() {
            inFlight = true
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

    /// One idle period is one agent prompt edge. The gate's turn clock, not
    /// the journal phase: a harness that never reports `blocked` still moves
    /// this when its turn does.
    static func promptEpoch(since: Date, atPrompt: Bool) -> String {
        let ms = Int64((since.timeIntervalSince1970 * 1000).rounded())
        return "\(ms)|\(atPrompt ? "prompt" : "turn")"
    }

    static func decide(_ input: Input) -> Decision {
        if !input.hasUnread { return .skip(reason: "no_mail") }
        if !input.stdinDelivery { return .skip(reason: "not_stdin") }
        if input.optedOut { return .skip(reason: "opted_out") }
        if input.inFlight { return .skip(reason: "in_flight") }
        if input.flagged { return .skip(reason: "flagged") }
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

    /// A skip leaves the queue. The next idle period can ring. Nothing maps
    /// to a block paste.
    static func arrival(for decision: Decision) -> Arrival {
        switch decision {
        case .ring:
            return .ring
        case .deferRing(let after):
            return .deferRing(after)
        case .skip(let reason):
            return .keep(reason: reason)
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

    /// Mail still queued at an idle edge. A keep (already rung this period,
    /// capped, opted out, a draft) is not a ring. The queue stays either way,
    /// so unread mail can ring on the next idle period.
    static func arrivalAfterIdleFlush(
        delivered: Bool,
        stillPending: Bool,
        input: Input
    ) -> Arrival? {
        guard !delivered, stillPending else { return nil }
        let effect = arrival(for: decide(input))
        if case .keep = effect { return nil }
        return effect
    }
}
