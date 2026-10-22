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
    /// Runaway guard. Once-per-idle already stops a second ring in one turn,
    /// so this only catches a panel that keeps submitting the line.
    static let rateCap = 20
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
        /// The panel's text box holds unsent text. That is a draft: the next
        /// submit would splice the doorbell line onto it.
        var textBoxUnsent: Bool = false
        var prompt: PromptInputState? = .empty
        /// A Codex interruption and its next task start can land on separate
        /// main hops. Recheck after the short transition window before typing.
        var journalInterruptionSettling: Bool = false
        var epoch: String = ""
        var now: Date = Date(timeIntervalSince1970: 0)
        /// Unread envelope ids. Empty means the caller did not name them, and
        /// a ring is not treated as already covered.
        var unreadIds: Set<String> = []
        /// Ids a submitted ring already covered.
        var coveredIds: Set<String> = []
        /// A refused Return may have left the doorbell line in the composer.
        var strandedPending: Bool = false

        static let absent = Input(hasUnread: false, prompt: nil)
    }

    /// Per-panel ring memory. Mark the epoch when an attempt starts, including
    /// a failed paste, so the same idle period is not retried.
    struct Ledger: Equatable {
        var epoch: String?
        var rungEpoch: String?
        var inFlight = false
        var attempts: [Date] = []
        /// Envelopes a submitted ring covered. Later idle edges do not ring
        /// while every unread id is in this set.
        var coveredIds: Set<String> = []
        var draftWatch: MailboxDoorbellSequence.DraftWatch?
        /// Set when a Return was refused after the line was typed. Cleared by
        /// a submit, or by a look that finds the composer without the line.
        var strandedPending = false

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

        /// A Return pressed on a stranded line. It counts toward the cap like
        /// a ring. A Return refused before the key typed nothing and does not.
        mutating func recordStrandedReturn(at now: Date, epoch: String) {
            self.epoch = epoch
            rungEpoch = epoch
            attempts.append(now)
            attempts.removeAll { now.timeIntervalSince($0) >= MailboxDoorbell.rateWindow }
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
        // Before the screen read. A covered set must not look like an
        // unreadable prompt, and it must not start a draft backoff.
        if MailboxDoorbellSequence.unreadIsCovered(
            unreadIds: input.unreadIds,
            coveredIds: input.coveredIds
        ) {
            return .skip(reason: "already_covered")
        }
        if input.textBoxUnsent { return .skip(reason: "draft") }
        if input.focused, let age = input.operatorKeyAge, age < quietWindow {
            let remaining = age >= 0 ? (quietWindow - age) : quietWindow
            return .deferRing(after: remaining)
        }
        if input.journalInterruptionSettling {
            return .deferRing(after: MailboxDoorbellSequence.shortRecheck)
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

}

/// The ring sequence Workspace runs, with the AppKit effects left outside.
/// A test breaks one of these functions and a named probe goes red.
enum MailboxDoorbellSequence {
    /// When to run the ring decision again. `.none` means the next idle edge
    /// is the only later look, or that nothing is waiting.
    enum Rearm: Equatable {
        case none
        case after(TimeInterval)
        case at(Date)
    }

    struct Plan: Equatable {
        var arrival: MailboxDoorbell.Arrival
        var rearm: Rearm
        /// The held-composer backoff after this decision. Nil when this skip
        /// is not a held composer, or when that backoff has not started.
        var draftWatch: DraftWatch?
        /// Set when `rearm` is a look on the held-composer series: `draft`,
        /// `unknown_prompt`, or `stranded` (the composer still holds the
        /// doorbell line). The caller writes one dispatch line for it.
        var relook: String? = nil
    }

    /// One held-composer series, started for a set of unread ids. A draft,
    /// an unreadable prompt, and a stranded doorbell line share it.
    /// `exhausted` means the 10 minute schedule is over. The same ids keep a
    /// 60 second look. A new id, or a new epoch, starts again at 5 seconds.
    struct DraftWatch: Equatable {
        var startedAt: Date
        var steps: Int
        var epoch: String
        /// Unread ids this series started for. A later id is a new series.
        var ids: Set<String>
        var exhausted: Bool
    }

    /// First looks after a held-composer skip, then `draftRecheckInterval`.
    /// Past `draftRecheckBound` the same mail stays on that interval.
    static let draftRecheckDelays: [TimeInterval] = [5, 15, 30]
    static let draftRecheckInterval: TimeInterval = 60
    static let draftRecheckBound: TimeInterval = 600

    /// Captures of a busy renderer before the read is given up.
    static let busyAttempts = 3
    /// Gap between those captures.
    static let busyRetryGap: TimeInterval = 0.075
    /// Later look after a busy read, a failed paste, or an open prompt whose
    /// input transaction is still active.
    static let shortRecheck: TimeInterval = 0.5

    /// Skips that hold mail at an open prompt until the composer changes.
    /// Each looks again on the held-composer series. Nothing else re-arms a
    /// ring there, so without the series the mail waits for the next envelope.
    static let heldComposerReasons: Set<String> = ["draft", "unknown_prompt"]

    static func shouldRetryBusy(tryIndex: Int) -> Bool {
        tryIndex >= 0 && tryIndex + 1 < busyAttempts
    }

    /// True when a submitted ring already covered every unread id. An empty
    /// unread set is not covered: the caller did not name the envelopes.
    static func unreadIsCovered(unreadIds: Set<String>, coveredIds: Set<String>) -> Bool {
        !unreadIds.isEmpty && unreadIds.isSubset(of: coveredIds)
    }

    /// The ids a submitted ring covers: everything unread at submit time.
    static func coveredIds(for unreadIds: Set<String>) -> Set<String> {
        unreadIds
    }

    /// Ids named from the queued envelopes. An empty queue names nothing.
    static func unreadIds(in entries: [MailboxStdinBuffer.Entry]) -> Set<String> {
        Set(entries.map(\.id))
    }

    /// The coverage fields the idle path decides on.
    static func namingUnread(
        _ input: MailboxDoorbell.Input,
        entries: [MailboxStdinBuffer.Entry],
        coveredIds: Set<String>
    ) -> MailboxDoorbell.Input {
        var named = input
        named.unreadIds = unreadIds(in: entries)
        named.coveredIds = coveredIds
        return named
    }

    /// Record a submitted ring. The queue it saw is covered, and the draft
    /// series ends. A failed paste does not call this.
    static func coverAfterSubmit(ledger: inout MailboxDoorbell.Ledger, unread: Set<String>) {
        ledger.coveredIds = coveredIds(for: unread)
        ledger.draftWatch = nil
        ledger.strandedPending = false
    }

    /// Nothing still unread ends the series. The next envelope must not
    /// inherit a watch whose mail is already gone.
    static func draftWatchAfterPrune(watch: DraftWatch?, liveIds: Set<String>) -> DraftWatch? {
        liveIds.isEmpty ? nil : watch
    }

    /// True when this series is still about the same turn and the same mail.
    /// An id the watch did not start with is a new series, even past the bound.
    static func draftSeriesContinues(_ watch: DraftWatch, epoch: String, unreadIds: Set<String>) -> Bool {
        watch.epoch == epoch && unreadIds.isSubset(of: watch.ids)
    }

    /// The next look after a plain draft skip. A turn change, or an unread id
    /// this series did not start with, starts again at 5 seconds. The same
    /// mail keeps a 60 second look after the 10 minute schedule.
    static func nextDraftRecheck(
        watch: DraftWatch?,
        epoch: String,
        unreadIds: Set<String> = [],
        now: Date
    ) -> (rearm: Rearm, watch: DraftWatch?) {
        let continues = watch.map { draftSeriesContinues($0, epoch: epoch, unreadIds: unreadIds) } ?? false
        if continues, let watch, watch.exhausted {
            return (.after(draftRecheckInterval), watch)
        }
        var current: DraftWatch
        if continues, let watch {
            current = watch
        } else {
            current = DraftWatch(
                startedAt: now,
                steps: 0,
                epoch: epoch,
                ids: unreadIds,
                exhausted: false
            )
        }
        let gap = current.steps < draftRecheckDelays.count
            ? draftRecheckDelays[current.steps]
            : draftRecheckInterval
        if now.addingTimeInterval(gap).timeIntervalSince(current.startedAt) > draftRecheckBound {
            current.exhausted = true
            return (.after(draftRecheckInterval), current)
        }
        current.steps += 1
        return (.after(gap), current)
    }

    /// `rate_capped` looks again when the oldest attempt leaves the window.
    /// A busy read that has used its captures looks again after `shortRecheck`.
    /// A draft, an unreadable prompt, and a composer that still holds the
    /// doorbell line look again on the held-composer series; this plan never
    /// retypes the line. A covered ring waits for a new envelope. Any other
    /// keep waits for a later edge.
    static func plan(
        decision: MailboxDoorbell.Decision,
        attempts: [Date],
        now: Date,
        busyExhausted: Bool,
        strandedDoorbell: Bool,
        draftWatch: DraftWatch? = nil,
        epoch: String = "",
        unreadIds: Set<String> = []
    ) -> Plan {
        let arrival = MailboxDoorbell.arrival(for: decision)
        let rearm: Rearm
        var watch = draftWatch
        var relook: String?
        switch decision {
        case .deferRing(let after):
            rearm = .after(after)
            watch = nil
        case .skip(let reason) where reason == "rate_capped":
            let live = attempts.filter { now.timeIntervalSince($0) < MailboxDoorbell.rateWindow }
            if let oldest = live.min() {
                rearm = .at(oldest.addingTimeInterval(MailboxDoorbell.rateWindow))
            } else {
                rearm = .after(0)
            }
            watch = nil
        case .skip(let reason) where reason == "unavailable" && busyExhausted:
            rearm = .after(shortRecheck)
            watch = nil
        case .skip(let reason) where heldComposerReasons.contains(reason):
            let step = nextDraftRecheck(
                watch: draftWatch,
                epoch: epoch,
                unreadIds: unreadIds,
                now: now
            )
            rearm = step.rearm
            watch = step.watch
            relook = reason == "draft" && strandedDoorbell ? "stranded" : reason
        default:
            rearm = .none
            watch = nil
        }
        return Plan(arrival: arrival, rearm: rearm, draftWatch: watch, relook: relook)
    }

    /// Ids from the pre-hop snapshot that are no longer in the inbox root.
    /// An id absent from the snapshot arrived during the hop and stays.
    static func droppedIds(snapshot: [String], stillPending: Set<String>) -> [String] {
        snapshot.filter { !stillPending.contains($0) }
    }

    enum Start: Equatable {
        case type
        case fail(String)
    }

    /// Whether typing may start. A refusal has not used the idle period.
    static func start(
        hasSurface: Bool,
        inputTransactionActive: Bool,
        feedAnswerBegan: Bool
    ) -> Start {
        guard hasSurface, !inputTransactionActive, feedAnswerBegan else {
            return .fail("unavailable")
        }
        return .type
    }

    /// `.type` records the attempt. `.fail` clears the reservation and does
    /// not record one.
    static func apply(start: Start, ledger: inout MailboxDoorbell.Ledger, now: Date, epoch: String) {
        switch start {
        case .type:
            ledger.beginAttempt(at: now, epoch: epoch)
        case .fail:
            ledger.endAttempt()
        }
    }

    /// Nil means submit. The composer compare lives here, against the doorbell
    /// line. A changed composer, a lost row, or a terminal the agent no longer
    /// owns refuses.
    static func preReturn(
        rowIsCurrent: Bool,
        operatorInputUnchanged: Bool,
        agentOwnsTerminal: Bool,
        captured: Bool,
        prompt: PromptInputState?,
        composer: String?,
        journalTurnOpen: Bool = false,
        journalInterruptionSettling: Bool = false
    ) -> FeedAnswerSubmitOutcome? {
        // Codex can report turn_aborted and task_started on separate main
        // hops. A fresh working edge during the paste delay keeps the old
        // doorbell invitation from being submitted into that new turn.
        guard !journalTurnOpen, !journalInterruptionSettling else { return .pastedNotSubmitted }
        if let outcome = FeedAnswerPreReturnCheck.outcome(
            targetIsCurrent: true,
            rowIsCurrent: rowIsCurrent,
            operatorInputUnchanged: operatorInputUnchanged,
            composer: nil
        ) {
            return outcome
        }
        guard captured else { return .pastedNotSubmitted }
        let compared = FeedAnswerComposerCheck.compare(
            state: prompt ?? .unavailable,
            composer: composer,
            expected: MailboxDoorbell.text
        )
        if let outcome = FeedAnswerPreReturnCheck.outcome(
            targetIsCurrent: true,
            rowIsCurrent: true,
            operatorInputUnchanged: true,
            composer: compared
        ) {
            return outcome
        }
        guard agentOwnsTerminal else { return .targetLost }
        return nil
    }

    /// After a paste that did not submit. The caller logs and does not type
    /// again over a line that is still sitting there.
    static func rearmAfterPasteFailure(
        outcome: FeedAnswerSubmitOutcome,
        state: PromptInputState?,
        composer: String?
    ) -> Rearm {
        switch outcome {
        case .targetLost, .submitted:
            return .none
        case .pastedNotSubmitted, .submitUnconfirmed:
            if let state {
                switch state {
                case .draft:
                    guard let composer else { return .none }
                    let compared = FeedAnswerComposerCheck.compare(
                        state: .draft,
                        composer: composer,
                        expected: MailboxDoorbell.text
                    )
                    // `.matches` is the invitation, wrapped or not. `.notVisible`
                    // is a prefix of it still sitting in the composer. An edit
                    // is `.changed` and is not polled.
                    return compared == .changed ? .none : .after(shortRecheck)
                case .empty, .suggestion:
                    return .after(shortRecheck)
                case .dialog, .unknown, .unavailable:
                    return .none
                }
            }
            return .after(shortRecheck)
        }
    }

    /// The ring checks for a doorbell line a refused Return left in the
    /// composer. Once-per-idle guards retyping, and this types nothing, so it
    /// is left out. The prompt read is what finds the line.
    private static func strandedProbe(_ input: MailboxDoorbell.Input) -> MailboxDoorbell.Input {
        var probe = input
        probe.rungThisEpoch = false
        probe.prompt = .empty
        return probe
    }

    /// A look in the idle period whose ring was refused, while the line may
    /// still be in the composer. Once-per-idle would end it with no later look.
    static func isStrandedLook(_ input: MailboxDoorbell.Input) -> Bool {
        input.rungThisEpoch && input.strandedPending
    }

    /// True when a stranded look should read the prompt: every other ring
    /// check passes and the prompt has not been read yet.
    static func needsStrandedLook(_ input: MailboxDoorbell.Input) -> Bool {
        guard input.prompt == nil, isStrandedLook(input) else { return false }
        return MailboxDoorbell.decide(strandedProbe(input)) == .ring
    }

    /// Press Return on a stranded doorbell line. Only the whole line, read
    /// back exactly, qualifies; a prefix or an edit stays held. Every other
    /// ring check applies, including the quiet window and the rate cap.
    static func submitsStranded(_ input: MailboxDoorbell.Input, composer: FeedAnswerComposerCheck?) -> Bool {
        guard composer == .matches else { return false }
        return MailboxDoorbell.decide(strandedProbe(input)) == .ring
    }

    enum Look: Equatable {
        /// Press Return on the line already in the composer.
        case submitStranded
        /// Plan from this decision, as any other look does.
        case decide(MailboxDoorbell.Decision)
    }

    /// One look's decision. `composer` is the doorbell-line compare of a
    /// draft (nil when there is no draft or it was not read). A stranded look
    /// plans from its own checks: a defer, a cap, or a held composer looks
    /// again instead of stopping at once-per-idle.
    static func look(
        _ input: MailboxDoorbell.Input,
        composer: FeedAnswerComposerCheck?,
        busyExhausted: Bool
    ) -> Look {
        if submitsStranded(input, composer: composer) { return .submitStranded }
        guard isStrandedLook(input) else { return .decide(MailboxDoorbell.decide(input)) }
        let probe = MailboxDoorbell.decide(strandedProbe(input))
        guard probe == .ring else { return .decide(probe) }
        if input.prompt == nil, busyExhausted { return .decide(.skip(reason: "unavailable")) }
        if input.prompt == .draft, composer == .notVisible { return .decide(.skip(reason: "draft")) }
        return .decide(MailboxDoorbell.decide(input))
    }

    /// Whether the line may still be in the composer after this read.
    /// An unread or unreadable prompt keeps the current belief.
    static func strandedPendingAfterRead(
        current: Bool,
        prompt: PromptInputState?,
        composer: FeedAnswerComposerCheck?
    ) -> Bool {
        switch prompt {
        case .draft:
            return composer == .matches || composer == .notVisible
        case .empty, .suggestion:
            return false
        case .dialog, .unknown, .unavailable, nil:
            return current
        }
    }

    /// Hold only a flag this panel raised for itself. A dispatch flag or an
    /// operator-designated flag (any other caller, or none) still rings.
    static func holdsForFlag(isFlagged: Bool, callerPanelId: UUID?, surfaceId: UUID) -> Bool {
        isFlagged && callerPanelId == surfaceId
    }

    /// Lowering a flag runs the ring decision again while mail is unread.
    static func rearmAfterFlagLower(unreadQueued: Bool) -> Rearm {
        unreadQueued ? .after(0) : .none
    }

    /// The quiet window uses the newer of a terminal key and text-box input.
    /// Nil when the operator has not touched the panel.
    static func operatorKeyAge(keyAt: Date?, inputAt: Date?, now: Date) -> TimeInterval? {
        let newest = [keyAt, inputAt].compactMap { $0 }.max()
        return newest.map { now.timeIntervalSince($0) }
    }

    /// Unsent text-box text. Whitespace does not count: a submit of it would
    /// not splice a message onto the doorbell line.
    static func textBoxHoldsUnsent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
