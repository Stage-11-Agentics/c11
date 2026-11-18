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
    /// An idle period no edge closes after its ring (a harness that reports
    /// no turn edges, or only turn ends whose start nothing recorded) would
    /// hold every later envelope once-per-idle. There it holds only this long
    /// after the last ring; then mail no ring has covered may ring again
    /// (C11-555, C11H-163).
    static let turnlessReringInterval: TimeInterval = 300
    /// Typed into the agent. Not chrome, so it is not localized.
    static let text = "c11 mail waiting: run c11 mailbox recv --ack"

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
        /// Native routes never inspect or edit the composer.
        var nativeRoute: Bool = false
        var flagged: Bool = false
        /// Read by callers. Suppression is never a skip: a parent is waiting.
        var suppressed: Bool = false
        var rungThisEpoch: Bool = false
        /// No edge has closed the idle period since the last ring, and that
        /// ring is at least `turnlessReringInterval` old. Lifts only the
        /// once-per-idle hold.
        var turnlessReringDue: Bool = false
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
        /// C11H-304: the terminal has no screen (an hc terminal running headless, as a hidden workspace's panels
        /// are after a relaunch). hc's status and a read of hc's paint stand in for the screen (`MailboxHeadlessPrompt`).
        var headless: Bool = false
        /// C11H-304: why the panel with no screen is held instead of rung (`MailboxHeadlessHold`).
        var headlessHold: String? = nil
        /// C11H-304: a headless ring in this idle period was not confirmed, so its line may sit in the composer.
        var headlessStranded: Bool = false

        static let absent = Input(hasUnread: false, prompt: nil)
    }

    /// Per-panel ring memory. Mark the epoch when an attempt starts, including
    /// a failed paste, so the same idle period is not retried.
    struct Ledger: Equatable {
        var epoch: String?
        var rungEpoch: String?
        /// When `rungEpoch` was last marked.
        var rungAt: Date?
        var inFlight = false
        var attempts: [Date] = []
        /// Envelopes a submitted ring covered. Later idle edges do not ring
        /// while every unread id is in this set.
        var coveredIds: Set<String> = []
        var draftWatch: MailboxDoorbellSequence.DraftWatch?
        /// C11H-327: the held series the last ring decision replaced. A headless ring refused before its text
        /// continues it, so a refusal that persists looks again on the series' own backoff (5, 15, 30, then 60 s)
        /// instead of starting over at 5 s after every refused ring.
        var seriesBeforeRing: MailboxDoorbellSequence.DraftWatch?
        /// Set when a Return was refused after the line was typed. Cleared by
        /// a submit, or by a look that finds the composer without the line.
        var strandedPending = false
        /// C11H-304: the idle period of a headless ring that was not confirmed. No screen can clear it; the
        /// agent's next turn edge opens a new period, which ends the hold.
        var headlessStrandedEpoch: String?

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
            rungAt = now
            attempts.append(now)
            attempts.removeAll { now.timeIntervalSince($0) >= MailboxDoorbell.rateWindow }
        }

        mutating func endAttempt() {
            inFlight = false
        }

        /// C11H-306: an attempt that put no byte in front of the agent (a check refused it before its text). It was
        /// charged when it started; this gives the idle period and its place under the cap back exactly, so a
        /// later look can ring without a turn edge.
        mutating func refundAttempt(at started: Date, epoch: String, priorRungEpoch: String?, priorRungAt: Date?) {
            refundIdlePeriod(at: started, epoch: epoch, priorRungEpoch: priorRungEpoch, priorRungAt: priorRungAt)
            if let index = attempts.lastIndex(of: started) { attempts.remove(at: index) }
        }

        /// C11H-327: an attempt the read admitted but the input refused before its text (a latched input fault, no
        /// attachment): no byte reached the agent, so the idle period comes back and a later look can ring without
        /// a turn edge, but the attempt keeps its place under the cap. A refusal that persists is capped like any
        /// ring rather than retried with a clean slate each time.
        mutating func refundIdlePeriod(at started: Date, epoch: String, priorRungEpoch: String?, priorRungAt: Date?) {
            if rungEpoch == epoch, rungAt == started {
                rungEpoch = priorRungEpoch
                rungAt = priorRungAt
            }
        }

        /// A Return pressed on a stranded line. It counts toward the cap like
        /// a ring. A Return refused before the key typed nothing and does not.
        mutating func recordStrandedReturn(at now: Date, epoch: String) {
            self.epoch = epoch
            rungEpoch = epoch
            rungAt = now
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
        // C11H-304: a headless ring that was not confirmed is never typed again in the same idle period. A read
        // of the composer that no longer shows its line, or the agent's next turn, ends the hold (C11H-306).
        if input.headless, input.headlessStranded, !input.nativeRoute,
           !MailboxDoorbellSequence.unreadIsCovered(unreadIds: input.unreadIds, coveredIds: input.coveredIds) {
            return .skip(reason: "stranded")
        }
        if input.rungThisEpoch && !input.turnlessReringDue { return .skip(reason: "once_per_idle") }
        if input.recentAttempts >= rateCap { return .skip(reason: "rate_capped") }
        // Before the screen read. A covered set must not look like an
        // unreadable prompt, and it must not start a draft backoff.
        if MailboxDoorbellSequence.unreadIsCovered(
            unreadIds: input.unreadIds,
            coveredIds: input.coveredIds
        ) {
            return .skip(reason: "already_covered")
        }
        if input.nativeRoute { return .ring }
        if input.textBoxUnsent { return .skip(reason: "draft") }
        if input.focused, let age = input.operatorKeyAge, age < quietWindow {
            let remaining = age >= 0 ? (quietWindow - age) : quietWindow
            return .deferRing(after: remaining)
        }
        if input.journalInterruptionSettling {
            return .deferRing(after: MailboxDoorbellSequence.shortRecheck)
        }
        if let hold = input.headlessHold { return .skip(reason: hold) }
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
        guard !input.nativeRoute, input.prompt == nil else { return false }
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
    static let heldComposerReasons: Set<String> = ["draft", "dialog", "unknown_prompt", "stranded",
                                                   MailboxHeadlessHold.notIdle, MailboxHeadlessHold.unread]

    /// When once-per-idle stops holding a panel whose idle period no edge
    /// has closed since its last ring. The epoch is named by the turn edge
    /// (or the attach), so a ring in the current epoch means nothing has
    /// moved the clock since. Nil when the panel was not rung in this period.
    static func turnlessReringAt(
        ledger: MailboxDoorbell.Ledger,
        epoch: String
    ) -> Date? {
        guard ledger.rung(in: epoch), let rungAt = ledger.rungAt else { return nil }
        return rungAt.addingTimeInterval(MailboxDoorbell.turnlessReringInterval)
    }

    /// The envelope a re-look row names. A held composer names the oldest
    /// unread envelope. A turn-less wait names the oldest one no ring has
    /// covered: that is the mail it is waiting to ring for, and a trace of it
    /// should show why.
    static func relookEntry(
        _ entries: [MailboxStdinBuffer.Entry],
        relook: String,
        coveredIds: Set<String>
    ) -> MailboxStdinBuffer.Entry? {
        guard relook == "turnless_idle" else { return entries.first }
        return entries.first { !coveredIds.contains($0.id) }
    }

    static func turnlessReringDue(at reringAt: Date?, now: Date) -> Bool {
        guard let reringAt else { return false }
        return now >= reringAt
    }

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
    /// retypes the line. A covered ring waits for a new envelope.
    /// `once_per_idle` looks again at `turnlessReringAt` while uncovered
    /// mail waits; an edge before then opens a new idle period. Any other keep waits
    /// for a later edge.
    static func plan(
        decision: MailboxDoorbell.Decision,
        attempts: [Date],
        now: Date,
        busyExhausted: Bool,
        strandedDoorbell: Bool,
        draftWatch: DraftWatch? = nil,
        epoch: String = "",
        unreadIds: Set<String> = [],
        coveredIds: Set<String> = [],
        turnlessReringAt: Date? = nil
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
        case .skip(let reason) where reason == "once_per_idle":
            // The next idle edge opens a new period and rings. No edge may be
            // coming (a harness with none, or one whose turn start nothing
            // recorded): look again when the hold lifts, while mail no ring
            // covered is waiting.
            if let reringAt = turnlessReringAt, !unreadIds.isEmpty,
               !unreadIsCovered(unreadIds: unreadIds, coveredIds: coveredIds) {
                rearm = .after(max(0, reringAt.timeIntervalSince(now)))
                relook = "turnless_idle"
            } else {
                rearm = .none
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
        !input.nativeRoute && input.rungThisEpoch && input.strandedPending
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
        guard !input.nativeRoute, composer == .matches else { return false }
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

/// C11H-304, C11H-306: the names mail to a panel with no screen is held under, on the held-composer series.
enum MailboxHeadlessHold {
    /// hc does not report the agent idle or done: working, no status yet, or a core c11 cannot reach.
    static let notIdle = "headless_status"
    /// hc reports the agent idle or done, but its composer could not be read (hc unreachable, a screen still being
    /// drawn, a composer shape the classifier does not know). The row carries the read's why.
    static let unread = "composer_unread"
}

/// C11H-304, C11H-306: the prompt read for a terminal with no screen, such as a hidden workspace's panel restored
/// headless after a relaunch. hc's own record of the agent's status (OSC 7501) says whether it is at its prompt:
/// blocked is a dialog; working or no status yet holds the mail under its own name. At its prompt, the composer is
/// read from hc's paint of the screen (`HCComposerObservation`) and classified exactly as the screen path classifies
/// its own capture: an empty composer or a dim suggestion rings, typed text holds as a draft, a dialog holds.
enum MailboxHeadlessPrompt {

    struct Read: Equatable {
        var prompt: PromptInputState?
        var hold: String?
        /// Why the composer read failed.
        var why: String? = nil
        /// A draft's typed text, for the stranded look. Transient.
        var composer: String? = nil
    }

    /// Nil when the agent is at its prompt and its composer has not been read yet: the caller reads it first.
    static func read(readiness: HCAgentReadiness, composer: HCComposerObservation?) -> Read? {
        switch readiness {
        case .blocked: return Read(prompt: .dialog)
        case .waiting: return Read(prompt: nil, hold: MailboxHeadlessHold.notIdle)
        case .ready:
            guard let composer else { return nil }
            switch composer.state {
            case .empty, .suggestion, .draft, .dialog:
                return Read(prompt: composer.state, composer: composer.composer)
            case .unknown, .unavailable:
                return Read(prompt: nil, hold: MailboxHeadlessHold.unread, why: composer.why)
            }
        }
    }

    /// Before the doorbell's text: a fresh read shows an empty composer or a dim suggestion, as the screen path's
    /// guard requires.
    static func admitsText(_ composer: HCComposerObservation) -> Bool {
        FeedAnswerPromptCommit.admits(composer.state)
    }

    /// The hold a refused ring's read before its text explains: a draft or a dialog it saw, or a composer it could
    /// not read. Nil when the read admitted the text and something else refused it.
    static func heldReason(afterRefusedRead read: HCComposerObservation?) -> (reason: String, why: String?)? {
        switch read?.state {
        case .draft?: return ("draft", nil)
        case .dialog?: return ("dialog", nil)
        case .unknown?, .unavailable?: return (MailboxHeadlessHold.unread, read?.why)
        case .empty?, .suggestion?, nil: return nil
        }
    }

    /// How many reads before the Return wait for the agent to echo the line, and the gap between them.
    static let returnReadAttempts = 4
    static let returnReadGapNanoseconds: UInt64 = 250_000_000

    /// Before its Return: a fresh read shows exactly the doorbell line in the composer, the screen path's rule.
    static func admitsReturn(_ composer: HCComposerObservation) -> Bool {
        MailboxDoorbellSequence.preReturn(rowIsCurrent: true, operatorInputUnchanged: true, agentOwnsTerminal: true,
            captured: true, prompt: composer.state, composer: composer.composer, journalTurnOpen: false,
            journalInterruptionSettling: false) == nil
    }

    /// What one headless ring's Return came to. Mail is delivered only on the agent's own evidence of a turn;
    /// a Return that was not taken, or a line typed with its Return cut, is held as stranded with why.
    enum Result: Equatable {
        case delivered
        case stranded(why: String)
        case failed(reason: String)
    }

    /// The line's write, whether a read then showed exactly the line, and the Return's own write (nil when it was
    /// not sent). Text with no Return after it may be sitting in the composer: stranded, never typed again.
    static func result(text: HCInputOutcome, lineRead: Bool, returnOutcome: HCInputOutcome?,
                       verdict: SendSubmitConfirmation.Verdict?) -> Result {
        switch text {
        case .refused(let reason):
            return .failed(reason: "hc_input_" + reason.rawValue)
        case .uncertain(let receipt):
            return receipt.bodyBytesWritten > 0 ? .stranded(why: "return_cut") : .failed(reason: "hc_input_uncertain")
        case .written(let receipt):
            guard receipt.bodyBytesWritten > 0 else { return .failed(reason: "hc_input_uncertain") }
        }
        guard lineRead, case .written(let receipt)? = returnOutcome, receipt.returnWritten else {
            return .stranded(why: "return_cut")
        }
        switch verdict {
        case .confirmed?: return .delivered
        case .unconfirmed(let why)?: return .stranded(why: why)
        case .pending?, nil: return .stranded(why: "no_turn_start")
        }
    }

    /// The pause between the line and its Return: the encoder's own settle delay for mailbox input. Tests shorten it.
    nonisolated(unsafe) static var returnSettleOverrideNanoseconds: UInt64?
    static func returnSettleNanoseconds() -> UInt64 {
        returnSettleOverrideNanoseconds ?? HCHeadlessInputEncoder.settleDelayNanoseconds(.mailbox)
    }
}
