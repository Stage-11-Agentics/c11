import Foundation
import Combine
import OSLog

enum HCInputNotice: Equatable, Sendable {
    case refused(HCInputRefusal)
    case interrupted(HCWriteReceipt?)

    var message: String {
        switch self {
        case .interrupted:
            return String(localized: "hc.input.interrupted", defaultValue: "Input interrupted. Some input may have arrived. Previous input will not be sent again.")
        case .refused(.unavailable):
            return String(localized: "hc.input.reconnecting", defaultValue: "Input was not sent while this terminal reconnects.")
        case .refused(.tooLarge):
            return String(localized: "hc.input.tooLarge", defaultValue: "Input was not sent because it is too large. Try a smaller paste.")
        case .refused(.queueFull):
            return String(localized: "hc.input.queueFull", defaultValue: "Input was not sent because the terminal input queue is full. Try again when it responds.")
        case .refused(.guardRefused):
            return String(localized: "hc.input.guardRefused", defaultValue: "Input was not sent because the prompt changed. Check the terminal before trying again.")
        case .refused(.screenUnavailable):
            return String(localized: "hc.input.screenUnavailable", defaultValue: "Input was not sent because the terminal screen is not ready.")
        case .refused(.staleIdentity):
            return String(localized: "hc.input.staleIdentity", defaultValue: "Input was not sent because the terminal connection changed.")
        case .refused(.inputFault):
            return String(localized: "hc.input.fault", defaultValue: "Input is paused after an interruption. Check the terminal, then choose Retry input.")
        case .refused(.cancelled):
            return String(localized: "hc.input.cancelled", defaultValue: "Input was cancelled before it was sent.")
        }
    }

    /// The text an agent reads on a socket error (C11H-124). An agent cannot choose
    /// the operator's Retry button, so a paused panel names the commands that
    /// recover it: `retry-input` clears the pause, then `send-key` clears the line.
    func agentMessage(panelRef: String) -> String {
        switch self {
        case .interrupted:
            return String(format: String(localized: "hc.input.interruptedAgent",
                defaultValue: "Input interrupted. Some input may have arrived. Previous input will not be sent again. Run c11 retry-input --panel %1$@, then clear the line with c11 send-key --panel %1$@ ctrl+u."), panelRef)
        case .refused(.inputFault):
            return String(format: String(localized: "hc.input.faultAgent",
                defaultValue: "Input is paused after an interruption. Run c11 retry-input --panel %1$@, then clear the line with c11 send-key --panel %1$@ ctrl+u."), panelRef)
        default:
            return message
        }
    }

    static var retryTitle: String {
        String(localized: "hc.input.retry", defaultValue: "Retry input")
    }
}

/// What the socket answers for a paused panel (C11H-124). Held apart from the
/// handlers so the answers are testable without a window.
enum HCPausedInputGate {
    /// A key sent to a panel whose input is paused is refused: the coordinator
    /// would drop it and the caller would be told it was sent.
    @MainActor
    static func keyRefusal(policy: HCDisconnectedInput?, panelRef: String) -> TerminalController.V2CallResult? {
        guard policy?.isFaulted == true else { return nil }
        return .err(code: "hc_input_" + HCInputRefusal.inputFault.rawValue,
                    message: HCInputNotice.refused(.inputFault).agentMessage(panelRef: panelRef),
                    data: ["outcome": "refused", "delivered": false])
    }

    /// `retry-input`'s reply. A panel that is not paused is refused, not a success.
    /// A refused retry carries the same reason the operator's bar shows.
    static func retryReply(_ outcome: HCDisconnectedInput.RetryOutcome, refusal: HCRetryRefusal? = nil,
                           envelope: [String: Any]) -> TerminalController.V2CallResult {
        var envelope = envelope
        switch outcome {
        case .recovered:
            envelope["state"] = "recovered"; envelope["recovered"] = true
            return .ok(envelope)
        case .notPaused:
            return .err(code: "hc_input_not_paused", message: String(localized: "socket.retry_input.not_paused",
                defaultValue: "Input was not paused."), data: ["state": "not_paused"])
        case .reconnecting:
            return .err(code: "hc_input_unavailable", message: String(localized: "socket.retry_input.reconnecting",
                defaultValue: "Input is paused and the terminal is still reconnecting. Try again in a few seconds."),
                data: refusalData("reconnecting", refusal))
        case .failed:
            let message = refusal.map {
                String(format: String(localized: "socket.retry_input.failedReason",
                    defaultValue: "Input could not be resumed: %@. Try again."), $0.text)
            } ?? String(localized: "socket.retry_input.failed",
                defaultValue: "Input could not be resumed because the screen did not settle. Try again.")
            return .err(code: "hc_input_retry_failed", message: message, data: refusalData("failed", refusal))
        }
    }

    private static func refusalData(_ state: String, _ refusal: HCRetryRefusal?) -> [String: Any] {
        guard let refusal else { return ["state": state] }
        return ["state": state, "reason": refusal.reason.rawValue, "guard": refusal.check]
    }
}

/// Who made an input whose outcome reaches the policy (C11H-443).
enum HCInputAttribution: String, Sendable {
    /// The operator's paste or drop.
    case operatorInput = "operator"
    /// A program: a socket send, the text box, the feed, the mailbox, a launch line, resume or
    /// initial input.
    case program
    /// An outcome from Ghostty's native write callback, not classified. That callback carries
    /// the operator's keys and Ghostty's own replies and reports alike.
    case native
    /// A native write shaped like a keystroke (`HCRawInputClass`): the operator's keys, a key
    /// binding, Dictation, an accessibility client or `send-key`.
    case keystroke
    /// A native write made only of report shapes: a query reply or a size, colour or focus
    /// report. Ghostty sends these by itself, but a key binding can send them too.
    case terminal

    init(_ source: HCInputSource) { self = source.isOperatorPaste ? .operatorInput : .program }
}

/// Presentation and retry policy above 2C's input coordinator. It retains no
/// payload, queue or Return; transport outcomes are returned without rewriting.
/// Native callbacks stay off-main and publish only their fault/outcome here.
@MainActor
final class HCDisconnectedInput: ObservableObject {
    typealias ResetFault = @MainActor (any HCAttachment, HCScreenReceipt) async -> Bool
    /// The owner's atomic reset, naming the guard that refused (nil: cleared).
    typealias ClearFault = @MainActor (any HCAttachment, HCScreenReceipt) async -> HCRetryRefusal?
    /// Composition creates replacement ports with admission closed before
    /// exposing them to native callbacks. This synchronous hook controls only
    /// admission, never clears a fault or retains/replays refused raw input.
    typealias SetAdmission = @MainActor (any HCAttachment, Bool) -> Void

    let panelID: UUID
    @Published private(set) var notice: HCInputNotice?
    @Published private(set) var isFaulted = false
    @Published private(set) var isRetrying = false
    /// Why the last Retry input did not resume input; the bar shows it until the
    /// next retry, a recovery, or a new interruption.
    @Published private(set) var retryFailure: HCRetryRefusal?
    /// True while a retry waits for a fresh attachment before it can start.
    @Published private(set) var isAwaitingRetry = false
    @Published private var attachment: (any HCAttachment)?
    @Published private var display: HCDisplayState?
    private var faultRevision: UInt64 = 0
    private var faultAttachmentGeneration: UInt64?
    private var pendingSubmits = 0
    private var staged: (attachment: any HCAttachment, display: HCDisplayState)?
    private let clearFault: ClearFault
    /// The owner's current display for the bound port. Display changes reach this
    /// policy through a main-actor hop, so its copy can lag the port's; Retry
    /// input reads the owner's before asking the parser for a receipt.
    private let currentDisplay: @MainActor () -> HCDisplayState?
    /// Where refused retries are logged (one notice line per refusal). Tests
    /// replace it.
    var retryLog: @MainActor (String) -> Void = { HCDisconnectedInput.logger.notice("\($0, privacy: .public)") }
    private let setAdmission: SetAdmission
    private let reattach: @MainActor () -> Void
    private let changed: @MainActor (HCDisconnectedInput) -> Void
    /// When the operator last pressed a key in this panel (C11H-443). Read only when a native
    /// write was refused, or when a write went through while the operator's notice is up; the
    /// keystroke path itself never calls it.
    private let lastOperatorKey: @MainActor () -> Date?
    private let clock: @MainActor () -> Date
    /// When this panel last stopped taking input: creation, a disconnect, or a replacement
    /// staged behind an old write. A refused native write is the operator's only when the
    /// operator pressed a key after this.
    private var closedAt: Date
    /// Who raised the reconnect notice on show (`unavailable`, `staleIdentity`), nil for any
    /// other notice. A program's clears when input works again: on bind, or on the next write
    /// that goes through. The operator's outlives a bind, because those keys really were
    /// dropped, and clears only when their own input goes through: a keystroke-shaped native
    /// write, or their paste or drop.
    private enum ReconnectNotice { case program, operatorInput }
    private var reconnectNotice: ReconnectNotice?
    /// Turns the bound port's attribution of successful raw writes on or off. The policy turns
    /// it on only while the operator's notice is up, so a write it clears on says who made it.
    private let attributeWrites: @MainActor (any HCAttachment, Bool) -> Void

    init(panelID: UUID,
         setAdmission: @escaping SetAdmission,
         clearFault: @escaping ClearFault,
         currentDisplay: @escaping @MainActor () -> HCDisplayState? = { nil },
         reattach: @escaping @MainActor () -> Void = {},
         lastOperatorKey: @escaping @MainActor () -> Date? = { nil },
         clock: @escaping @MainActor () -> Date = { Date() },
         attributeWrites: @escaping @MainActor (any HCAttachment, Bool) -> Void = { _, _ in },
         changed: @escaping @MainActor (HCDisconnectedInput) -> Void = { _ in }) {
        self.panelID = panelID
        self.attributeWrites = attributeWrites
        self.clearFault = clearFault
        self.currentDisplay = currentDisplay
        self.setAdmission = setAdmission
        self.reattach = reattach
        self.lastOperatorKey = lastOperatorKey
        self.clock = clock
        self.changed = changed
        closedAt = clock()
    }

    /// A reset hook that answers only yes or no; a no is reported as the owner's refusal.
    convenience init(panelID: UUID,
                     setAdmission: @escaping SetAdmission,
                     resetFault: @escaping ResetFault,
                     reattach: @escaping @MainActor () -> Void = {},
                     lastOperatorKey: @escaping @MainActor () -> Date? = { nil },
                     clock: @escaping @MainActor () -> Date = { Date() },
                     attributeWrites: @escaping @MainActor (any HCAttachment, Bool) -> Void = { _, _ in },
                     changed: @escaping @MainActor (HCDisconnectedInput) -> Void = { _ in }) {
        self.init(panelID: panelID, setAdmission: setAdmission, clearFault: { attachment, receipt in
            await resetFault(attachment, receipt) ? nil : HCRetryRefusal(.stateMismatch, "owner.resetRefused")
        }, reattach: reattach, lastOperatorKey: lastOperatorKey, clock: clock,
           attributeWrites: attributeWrites, changed: changed)
    }

    /// True while the reconnect notice is the operator's own and so outlives a bind.
    var noticeIsOperators: Bool {
        if case .operatorInput? = reconnectNotice { return true }
        return false
    }

    func bind(_ attachment: any HCAttachment, display: HCDisplayState) {
        if pendingSubmits > 0, self.attachment !== attachment {
            // Outcomes belong to the old port until its last submit returns.
            // Letting the replacement accept a body now could cancel its
            // Return when the old outcome subsequently reports uncertainty.
            setAdmission(attachment, false)
            if let previous = self.attachment { setAdmission(previous, false) }
            self.attachment = nil
            self.display = nil
            staged = (attachment, display)
            closedAt = clock()
            changed(self)
            return
        }
        self.attachment = attachment
        self.display = display
        if isFaulted {
            attachment.input.invalidate(generation: attachment.generation, reason: .inputFault)
        } else {
            setAdmission(attachment, true)
            // C11H-443: input works again. A reconnect notice no operator input raised (a
            // program's send, which its caller already heard refused) has nothing left to say.
            if case .program? = reconnectNotice { clearNotice(cause: "bind") }
        }
        syncWriteAttribution()
        changed(self)
    }

    /// The bound port classifies its successful raw writes only while the operator's notice
    /// is up (C11H-443). Runs on a bind, a refusal and a clear, never per write.
    private func syncWriteAttribution() {
        if let attachment { attributeWrites(attachment, noticeIsOperators) }
    }

    func updateDisplay(_ display: HCDisplayState) {
        if let staged, display.revision.attachmentGeneration == staged.attachment.generation {
            self.staged = (staged.attachment, display)
            return
        }
        self.display = display
    }

    /// True when `attachment` is the port this policy has opened. A staged
    /// replacement or a disconnected panel is not yet bound.
    func isBound(to attachment: any HCAttachment) -> Bool { self.attachment === attachment }

    var canRetryInput: Bool { isFaulted && retryBlocker == nil }

    /// Why Retry input cannot start now, before any screen is read.
    private var retryBlocker: HCRetryRefusal? {
        guard isFaulted else { return HCRetryRefusal(.notPaused, "policy.notPaused") }
        guard !isRetrying else { return HCRetryRefusal(.retrying, "policy.retrying") }
        guard pendingSubmits == 0 else {
            return HCRetryRefusal(.inputInFlight, "policy.pendingSubmits", "pending=\(pendingSubmits)")
        }
        guard let attachment else { return HCRetryRefusal(.reconnecting, "policy.noAttachment") }
        guard isFresh(attachment) else {
            return HCRetryRefusal(.reconnecting, "policy.freshAttachment",
                                  "port=\(attachment.generation) interrupted=\(faultAttachmentGeneration.map(String.init) ?? "nil")")
        }
        return nil
    }

    func disconnect() {
        if let attachment {
            setAdmission(attachment, false)
            // Input stopped now. A second disconnect for the same loss, or one after a
            // replacement was staged, keeps the first time.
            closedAt = clock()
        }
        // A staged port was never opened; discard it so a late completion
        // cannot resurrect an attachment the owner has already retired.
        staged = nil
        attachment = nil
        display = nil
        // Refused/uncertain notices persist until the operator can see them.
        changed(self)
    }

    func submit(_ request: HCInputRequest) async -> HCInputOutcome {
        let from = HCInputAttribution(request.source)
        guard request.panelID == panelID else { return refuse(.staleIdentity, from: from) }
        guard let attachment else { return refuse(.unavailable, from: from) }
        guard request.key == attachment.key, request.attachmentGeneration == attachment.generation else {
            return refuse(.staleIdentity, from: from)
        }
        guard !isFaulted else { return refuse(.inputFault, from: from) }
        pendingSubmits += 1
        let outcome = await attachment.submit(request)
        // An old in-flight write may complete after reattach. Its uncertainty
        // still belongs to this panel and must latch the new input port too.
        record(outcome, from: from)
        pendingSubmits -= 1
        if pendingSubmits == 0, let staged {
            self.staged = nil
            bind(staged.attachment, display: staged.display)
        }
        return outcome
    }

    /// 2C calls this for raw keys/paste/query failure as well as programmatic
    /// outcomes. The caller already owns exact operation/generation attribution;
    /// `from` says who made the input (C11H-443).
    func record(_ outcome: HCInputOutcome, from attribution: HCInputAttribution = .program) {
        switch outcome {
        case .refused(let reason):
            if reason == .inputFault {
                Self.logRefusal(panelID: panelID, reason, from: attribution, bar: "paused")
                if !isFaulted { latchFault(receipt: nil) }
            } else {
                show(reason, from: attribution)
            }
        case .uncertain(let receipt):
            Self.logger.notice("input uncertain panel=\(self.panelID.uuidString, privacy: .public) body_bytes=\(receipt.bodyBytesWritten) return_written=\(receipt.returnWritten)")
            latchFault(receipt: receipt)
        case .written:
            // C11H-443: one test on the hop every outcome already makes to main. With a notice
            // up, the write's own attribution decides; no timestamp is read on success.
            if reconnectNotice != nil { clearReconnectNotice(afterWriteFrom: attribution) }
        }
    }

    /// A write went through while a reconnect notice is up. A program's clears: input works.
    /// The operator's clears only on their own input: a keystroke-shaped native write (the
    /// port classifies its writes while this notice is up) or their paste or drop. A report,
    /// a program's send or an unclassified write leaves it.
    private func clearReconnectNotice(afterWriteFrom attribution: HCInputAttribution) {
        switch reconnectNotice {
        case nil:
            return
        case .program?:
            clearNotice(cause: "written")
        case .operatorInput?:
            switch attribution {
            case .keystroke: clearNotice(cause: "typed")
            case .operatorInput: clearNotice(cause: "pasted")
            case .program, .native, .terminal: return
            }
        }
    }

    private func clearNotice(cause: String) {
        reconnectNotice = nil
        notice = nil
        Self.logCleared(panelID: panelID, cause: cause)
        syncWriteAttribution()
        changed(self)
    }

    /// Logs every refusal and raises its notice only for input someone made (C11H-443).
    /// A refused native write is the operator's whenever they pressed a key since this panel
    /// stopped taking input, whatever its shape: a key binding can send report-shaped bytes.
    /// With no such key, a write made only of reports (Ghostty's own replies and size, colour
    /// and focus reports) raises no bar, and any other is a program's.
    private func show(_ reason: HCInputRefusal, from attribution: HCInputAttribution) {
        let byOperator: Bool
        switch attribution {
        case .operatorInput: byOperator = true
        case .program: byOperator = false
        case .native, .keystroke, .terminal:
            // The refused path is the only place this closure runs.
            if let key = lastOperatorKey(), key >= closedAt {
                byOperator = true
            } else if attribution == .terminal {
                Self.logRefusal(panelID: panelID, reason, from: attribution, bar: "none")
                return
            } else {
                byOperator = false
            }
        }
        // A repeated attempted send while faulted cannot overwrite the original
        // uncertain receipt or pretend that operation was refused before write.
        guard !isFaulted else {
            Self.logRefusal(panelID: panelID, reason, from: attribution, bar: "paused")
            return
        }
        if !Self.isReconnect(reason) {
            reconnectNotice = nil
        } else if byOperator {
            reconnectNotice = .operatorInput
        } else if reconnectNotice == nil {
            // A program's refusal keeps an operator's reconnect notice theirs.
            reconnectNotice = .program
        }
        Self.logRefusal(panelID: panelID, reason, from: attribution, bar: noticeIsOperators ? "held" : "shown")
        notice = .refused(reason)
        syncWriteAttribution()
        changed(self)
    }

    /// The refusals that mean only "this terminal is reconnecting".
    private static func isReconnect(_ reason: HCInputRefusal) -> Bool {
        reason == .unavailable || reason == .staleIdentity
    }

    /// Explicit Retry input enables future input only. It never resubmits the
    /// uncertain operation, and reattachment by itself never clears the latch.
    /// A refusal is logged with its guard and shown in the bar.
    @discardableResult
    func retryInput() async -> Bool {
        guard let refusal = await attemptRetry() else { return true }
        report(refusal)
        return false
    }

    private func attemptRetry() async -> HCRetryRefusal? {
        if let blocker = retryBlocker { return blocker }
        guard let attachment else { return HCRetryRefusal(.reconnecting, "policy.noAttachment") }
        // Adopt the owner's newer display for this same port: a lagging copy would
        // ask the parser about a revision the owner has already moved past.
        if staged == nil, let owned = currentDisplay(),
           owned.revision.attachmentGeneration == attachment.generation, owned != display {
            display = owned
        }
        guard let display else { return HCRetryRefusal(.screenNotSettled, "policy.noDisplay") }
        guard display.revision.attachmentGeneration == attachment.generation else {
            return HCRetryRefusal(.connectionChanged, "policy.displayGeneration",
                                  "display=\(display.revision.attachmentGeneration) port=\(attachment.generation)")
        }
        let fault = faultRevision
        isRetrying = true
        retryFailure = nil
        changed(self)
        defer { isRetrying = false; changed(self) }
        guard let receipt = await attachment.screenCurrent(after: display.revision) else {
            return HCRetryRefusal(.screenNotSettled, "policy.screenUnavailable", "display=\(display.revision.logText)")
        }
        if let changedState = stateChanged(since: fault, attachment: attachment, display: display) { return changedState }
        guard receipt.revision == display.revision,
              receipt.columns == display.grid.columns, receipt.rows == display.grid.rows else {
            return HCRetryRefusal(.screenNotSettled, "policy.receipt",
                "receipt=\(receipt.revision.logText) \(receipt.columns)x\(receipt.rows) " +
                "display=\(display.revision.logText) \(display.grid.columns)x\(display.grid.rows)")
        }
        // HCPanelSession owns the underlying port's atomic reset. Its async
        // hook rechecks the parser and fault epoch too; do not clear our notice
        // if a newer fault/attachment/display arrived while that hook waited.
        guard !Task.isCancelled else { return HCRetryRefusal(.reconnecting, "policy.cancelled") }
        if let refusal = await clearFault(attachment, receipt) { return refusal }
        if let changedState = stateChanged(since: fault, attachment: attachment, display: display) { return changedState }
        isFaulted = false
        notice = nil
        setAdmission(attachment, true)
        return nil
    }

    private func stateChanged(since fault: UInt64, attachment: any HCAttachment,
                              display: HCDisplayState) -> HCRetryRefusal? {
        guard isFaulted else { return HCRetryRefusal(.notPaused, "policy.clearedMeanwhile") }
        guard faultRevision == fault else {
            return HCRetryRefusal(.newInterruption, "policy.faultRevision", "fault=\(faultRevision) expected=\(fault)")
        }
        guard self.attachment === attachment else {
            return HCRetryRefusal(.connectionChanged, "policy.attachmentChanged",
                                  "port=\(self.attachment.map { String($0.generation) } ?? "nil") expected=\(attachment.generation)")
        }
        guard self.display == display else {
            return HCRetryRefusal(.screenNotSettled, "policy.displayMoved",
                                  "display=\(self.display?.revision.logText ?? "nil") expected=\(display.revision.logText)")
        }
        return nil
    }

    private func report(_ refusal: HCRetryRefusal) {
        retryLog(refusal.logLine(panelID: panelID))
        // A pause that is gone needs no failure line.
        guard isFaulted else { return }
        retryFailure = refusal
        changed(self)
    }

    enum RetryOutcome: Equatable { case recovered, notPaused, reconnecting, failed }

    /// `retryInput` for a caller that cannot wait on a button (C11H-124): a pause
    /// asks for a fresh attachment, so ask again once, then wait for it, up to
    /// `seconds`, before giving up. The operator's button and `c11 retry-input`
    /// both come here; a refusal's reason is `retryFailure`.
    func retryInputWaiting(seconds: TimeInterval) async -> RetryOutcome {
        guard isFaulted else {
            report(HCRetryRefusal(.notPaused, "policy.notPaused", "isFaulted=false"))
            return .notPaused
        }
        isAwaitingRetry = true
        retryFailure = nil
        changed(self)
        defer { isAwaitingRetry = false; changed(self) }
        // The latch asked once already; a request lost on the way would leave the
        // pause waiting for a generation that never comes.
        if let attachment, !isFresh(attachment), pendingSubmits == 0, !isRetrying { reattach() }
        let deadline = Date().addingTimeInterval(seconds)
        while isFaulted, !canRetryInput, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard isFaulted else { return .recovered }
        if let blocker = retryBlocker {
            report(blocker)
            return blocker.reason == .reconnecting ? .reconnecting : .failed
        }
        // A caller that gave up (the socket's timeout cancels this task) was told
        // the retry failed; it must not then clear the pause.
        guard !Task.isCancelled else {
            report(HCRetryRefusal(.reconnecting, "policy.cancelled"))
            return .reconnecting
        }
        guard let refusal = await attemptRetry() else { return .recovered }
        report(refusal)
        switch refusal.reason {
        case .notPaused: return isFaulted ? .failed : .recovered
        case .reconnecting: return .reconnecting
        default: return .failed
        }
    }

    func dismissRefusal() {
        guard !isFaulted else { return }
        reconnectNotice = nil
        syncWriteAttribution()
        if notice != nil { Self.logCleared(panelID: panelID, cause: "dismissed") }
        notice = nil
        changed(self)
    }

    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.input")

    /// Every refused input, programmatic or raw, reaches this policy once
    /// (through `submit` or `record`); its code is the socket's error code.
    /// `from` is who made it and `bar` what the panel shows for it: `shown`,
    /// `held` (the operator's, outliving a bind), `paused`, or `none`.
    static func logRefusal(panelID: UUID, _ reason: HCInputRefusal,
                           from attribution: HCInputAttribution = .program, bar: String = "shown") {
        logger.notice("input refused panel=\(panelID.uuidString, privacy: .public) code=hc_input_\(reason.rawValue, privacy: .public) from=\(attribution.rawValue, privacy: .public) bar=\(bar, privacy: .public)")
    }

    /// C11H-443: a refused-input notice left the panel: `bind` or `written` (a program's
    /// reconnect notice once input works), `typed` or `pasted` (the operator's, once their own
    /// input went through) or `dismissed`.
    static func logCleared(panelID: UUID, cause: String) {
        logger.notice("input notice cleared panel=\(panelID.uuidString, privacy: .public) cause=\(cause, privacy: .public)")
    }

    private func refuse(_ reason: HCInputRefusal, from attribution: HCInputAttribution) -> HCInputOutcome {
        if reason == .inputFault {
            // Faulted already: the pause stays as it is.
            Self.logRefusal(panelID: panelID, reason, from: attribution, bar: "paused")
        } else {
            show(reason, from: attribution)
        }
        return .refused(reason)
    }

    private func latchFault(receipt: HCWriteReceipt?) {
        faultRevision &+= 1
        retryFailure = nil
        reconnectNotice = nil
        syncWriteAttribution()
        let interruptedGeneration = receipt?.attachmentGeneration ?? attachment?.generation
        if let interruptedGeneration {
            // HCManagedSession generations strictly increase across reattach.
            // A late old receipt cannot make a newer faulted port look fresh.
            faultAttachmentGeneration = max(faultAttachmentGeneration ?? interruptedGeneration, interruptedGeneration)
        }
        isFaulted = true
        if let receipt { notice = .interrupted(receipt) }
        else if case .interrupted = notice {} else { notice = .interrupted(nil) }
        if let attachment {
            attachment.input.invalidate(generation: attachment.generation, reason: .inputFault)
            // Queue/raw faults can happen without losing the core connection.
            // Ask the attachment owner for a fresh parsed generation, otherwise
            // Retry input could remain unavailable forever on a healthy core.
            if attachment.generation == interruptedGeneration { reattach() }
        }
        changed(self)
    }

    private func isFresh(_ attachment: any HCAttachment) -> Bool {
        guard let faultAttachmentGeneration else { return true }
        return attachment.generation > faultAttachmentGeneration
    }
}
