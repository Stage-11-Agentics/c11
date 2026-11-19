import Foundation
import OSLog

/// Input submitted to a persistent terminal before its first hc attachment is
/// bound, such as a freshly created agent panel's launcher line. It is held in
/// a small bounded queue owned by the creation, sent once in order when the
/// first attachment is bound, and never replayed: items are removed before they
/// are submitted, and a panel that has already been bound refuses input while it
/// reconnects instead of queueing it for a replacement port.
@MainActor
final class HCPendingInput {
    struct Item {
        let text: String
        let submit: Bool
        let source: HCInputSource
        let screenGuard: HCInputGuard?
        let returnGuard: HCInputGuard?
        let completion: ((HCInputOutcome) -> Void)?
    }

    static let maxItems = 16
    static let maxBytes = HCLimits.transactionBytes

    private var items: [Item] = []
    private var bytes = 0
    /// Drains whose items have not all returned from the port yet.
    private var flushing = 0
    /// Direct sends (port already bound) that have not returned yet.
    private var inFlight = 0
    var count: Int { items.count }

    /// True while this queue holds, drains or sends input. The port admits one
    /// programmatic writer at a time, so `HCInputReadyQueue` waits behind this
    /// instead of colliding with it (refused `queueFull`, one input dropped).
    /// Set synchronously by `drain` and `submit`, before any waiter can resume.
    var isBusy: Bool { !items.isEmpty || flushing > 0 || inFlight > 0 }

    nonisolated init() {}

    /// Sends now when a port is bound, holds the item when the first attachment
    /// is still being created (and `allowQueue`), and otherwise refuses visibly.
    /// `demandStart` runs once when the item is held: held input is the demand
    /// that starts a panel whose surface was deferred (a hidden tab).
    func submit(_ item: Item, runtime: HCPanelSession, panelID: UUID, allowQueue: Bool,
                demandStart: (@MainActor () -> Void)? = nil) {
        let size = item.text.utf8.count
        guard size <= HCLimits.transactionBytes else { return refuse(item, .tooLarge, runtime) }
        if let attachment = runtime.attachment {
            send(item, on: attachment, runtime: runtime, panelID: panelID)
            return
        }
        guard allowQueue, runtime.isAwaitingFirstAttachment else { return refuse(item, .unavailable, runtime) }
        guard items.count < Self.maxItems, bytes + size <= Self.maxBytes else { return refuse(item, .queueFull, runtime) }
        items.append(item)
        bytes += size
        demandStart?()
    }

    /// Called once the first attachment is bound. Submits strictly in order.
    func drain(runtime: HCPanelSession, panelID: UUID) {
        guard runtime.attachment != nil, !items.isEmpty else { return }
        let held = items
        items.removeAll()
        bytes = 0
        flushing += 1
        Task { @MainActor in
            defer { flushing -= 1 }
            for item in held {
                guard let attachment = runtime.attachment else { refuse(item, .unavailable, runtime); continue }
                await perform(item, on: attachment, runtime: runtime, panelID: panelID)
            }
        }
    }

    /// The creation failed or the panel went away: nothing was sent, say so.
    func failAll(_ reason: HCInputRefusal, runtime: HCPanelSession?) {
        let held = items
        items.removeAll()
        bytes = 0
        for item in held { refuse(item, reason, runtime) }
    }

    private func send(_ item: Item, on attachment: any HCAttachment, runtime: HCPanelSession, panelID: UUID) {
        inFlight += 1
        Task { @MainActor in
            defer { inFlight -= 1 }
            await perform(item, on: attachment, runtime: runtime, panelID: panelID)
        }
    }

    private func perform(_ item: Item, on attachment: any HCAttachment, runtime: HCPanelSession,
                         panelID: UUID) async {
        let request = HCInputRequest(operationID: UUID(), panelID: panelID, key: attachment.key,
            attachmentGeneration: attachment.generation, source: item.source, payload: Data(item.text.utf8),
            submitReturn: item.submit, screenGuard: item.screenGuard, returnGuard: item.returnGuard)
        let outcome = await runtime.submitInput(request)
        item.completion?(outcome)
    }

    private func refuse(_ item: Item, _ reason: HCInputRefusal, _ runtime: HCPanelSession?) {
        let outcome = HCInputOutcome.refused(reason)
        runtime?.recordInputOutcome(outcome)
        item.completion?(outcome)
    }
}

/// Contract L2: programmatic input to a persistent terminal waits for its
/// pinned attachment and, when guarded, for screen readiness, instead of being
/// refused because it arrived first. One queue per terminal surface, on main;
/// callers suspend (the socket worker is the only thread that blocks).
///
/// - Order: each submission takes a turn at entry and sends only at the head,
///   after the one before it has finished, so waits never reorder input.
/// - Once: nothing is sent while waiting; a refusal leaves no bytes, and a
///   submission is handed to `send` at most once.
/// - Bounded: `waitSeconds` (the caller's deadline) ends the wait with the
///   reason it was still waiting for. Zero keeps the immediate answer.
/// - Real failures (`.failed`) refuse at once.
@MainActor
final class HCInputReadyQueue {
    enum Readiness {
        /// The port is bound and open for programmatic input.
        case ready(any HCAttachment)
        /// Attaching or reattaching; the reason a timed-out wait reports.
        case waiting(HCInputRefusal)
        /// Will not become ready for this submission.
        case failed(HCInputRefusal)
    }

    typealias Clock = @Sendable () -> UInt64
    typealias Sleep = @Sendable (UInt64) async -> Void

    /// What the socket send command waits within. Its worker gives the whole
    /// command 5 s; this leaves the write itself the rest.
    static let socketWaitSeconds: TimeInterval = 3.5
    static let pollNanoseconds: UInt64 = 20_000_000
    /// While the head still waits, how often it asks again for a start. A
    /// first start can be parked (restore gate) or blocked (no grid yet), and
    /// one ask at entry would leave the rest of the bound unused.
    static let demandIntervalNanoseconds: UInt64 = 250_000_000

    private var turns: [UUID] = []
    /// What the head is waiting for; a turn that times out before reaching the
    /// head reports this, or `queueFull` while the head is sending.
    private var headReason = HCInputRefusal.unavailable
    private let now: Clock
    private let sleep: Sleep

    nonisolated init(now: @escaping Clock = { DispatchTime.now().uptimeNanoseconds },
                     sleep: @escaping Sleep = { try? await Task.sleep(nanoseconds: $0) }) {
        self.now = now
        self.sleep = sleep
    }

    /// Submissions holding or waiting for a turn.
    var count: Int { turns.count }

    /// - Parameters:
    ///   - screenReady: guarded input only. Answers whether the attachment's
    ///     screen is current, waiting at most the nanoseconds given.
    ///   - demandStart: called at entry when the terminal is still waiting,
    ///     then again every `demandIntervalNanoseconds` while the head still
    ///     waits, within the same bound. A panel whose surface was deferred (a
    ///     hidden tab whose view was never mounted) attaches only once something
    ///     asks, as a native terminal starts for a send; the caller gates it
    ///     with `needsStart(_:current:hasNativeSurface:)`, so asking again
    ///     never starts a second terminal.
    ///   - send: called at most once, at the head of the queue, with the
    ///     attachment that was ready.
    func submit(waitSeconds: TimeInterval,
                readiness: @MainActor () -> Readiness,
                screenReady: (@MainActor (any HCAttachment, UInt64) async -> Bool)?,
                demandStart: (@MainActor () -> Void)? = nil,
                send: @MainActor (any HCAttachment) async -> HCInputOutcome) async -> HCInputOutcome {
        let turn = UUID()
        turns.append(turn)
        defer { turns.removeAll { $0 == turn } }
        var lastAsk: UInt64?
        if let demandStart, case .waiting = readiness() { lastAsk = now(); demandStart() }
        let waits = waitSeconds > 0
        let deadline = now() &+ (waits ? UInt64(waitSeconds * 1_000_000_000) : 0)
        var reason = HCInputRefusal.unavailable
        while true {
            guard !Task.isCancelled else { return .refused(.cancelled) }
            if turns.first == turn {
                switch readiness() {
                case .failed(let failure):
                    return .refused(failure)
                case .waiting(let waiting):
                    reason = waiting
                    headReason = waiting
                    if let demandStart {
                        let asked = now()
                        if lastAsk.map({ asked &- $0 >= Self.demandIntervalNanoseconds }) ?? true {
                            lastAsk = asked
                            demandStart()
                        }
                    }
                case .ready(let attachment):
                    headReason = .queueFull
                    // Without a wait the coordinator's own bounded screen check
                    // answers, exactly as before.
                    guard waits, let screenReady else { return await send(attachment) }
                    let started = now()
                    let remaining = deadline > started ? deadline - started : 0
                    if remaining > 0, await screenReady(attachment, remaining) {
                        guard !Task.isCancelled else { return .refused(.cancelled) }
                        if case .ready(let current) = readiness(), current === attachment {
                            return await send(attachment)
                        }
                        continue
                    }
                    reason = .screenUnavailable
                    headReason = .screenUnavailable
                }
            } else {
                reason = headReason
            }
            let current = now()
            guard waits, current < deadline else { return .refused(reason) }
            await sleep(min(Self.pollNanoseconds, deadline - current))
        }
    }

    /// A persistent panel's readiness for awaited input. `current` is the
    /// surface's runtime now; `pendingBusy` is its `HCPendingInput.isBusy`.
    static func readiness(of runtime: HCPanelSession, current: HCPanelSession?, pendingBusy: Bool) -> Readiness {
        guard current === runtime, runtime.identity.persistence == .persistent else { return .failed(.unavailable) }
        if case .ended = runtime.lifecycle { return .failed(.unavailable) }
        if pendingBusy { return .waiting(.unavailable) }
        guard let attachment = runtime.attachment, runtime.identity.key == attachment.key,
              runtime.disconnectedInput?.isBound(to: attachment) == true else { return .waiting(.unavailable) }
        return .ready(attachment)
    }

    /// Whether input to this panel should start its terminal: the current
    /// persistent runtime has never attached and has no native surface, so
    /// nothing else will attach it (Ghostty creates surfaces only in a
    /// window, and a hidden tab is never mounted). A panel that attached
    /// before is reconnecting between surfaces and is never started again
    /// here: that would run a second creation.
    static func needsStart(_ runtime: HCPanelSession, current: HCPanelSession?, hasNativeSurface: Bool) -> Bool {
        current === runtime && !hasNativeSurface && runtime.isAwaitingFirstAttachment
    }

    /// What a start parked behind the restore gate does when the gate opens.
    enum ParkedStart: Equatable {
        /// The view is in a window: create the surface there, as parked.
        case create
        /// The view left its window (a headless start whose host the portal
        /// reclaimed) and the panel still needs a start: start it again in the
        /// headless window.
        case startHeadless
        /// Nothing to start (the panel is gone, or already started or
        /// attached): logged, never silently dropped.
        case drop
    }

    /// C11H-96: what creating a terminal on another machine does about starting it.
    /// A panel made through the socket in a background workspace has no view in a
    /// window, so its surface (and with it its hc terminal) waits to be shown, and
    /// an agent can never show it. A fresh remote create asks for the headless start
    /// at once, as a local panel gets on input; a restored panel keeps the restore
    /// deferral, and a panel that already has a surface has nothing to start.
    enum CreateStart: Equatable {
        case requestBackground
        case leave
    }

    nonisolated static func createStart(isRemote: Bool, restoring: Bool, hasNativeSurface: Bool) -> CreateStart {
        guard isRemote, !restoring, !hasNativeSurface else { return .leave }
        return .requestBackground
    }

    /// C11H-96: once a session restore has rebuilt a workspace, each remote
    /// terminal in it that has no surface asks for the headless start, shown
    /// workspace or not. The start parks behind the restore gate (see
    /// `parkedStart`) and runs when the gate opens; nothing waits for the
    /// workspace to come on screen. Local panels keep their lazy start.
    nonisolated static func afterRestoreStart(isRemote: Bool, hasNativeSurface: Bool) -> CreateStart {
        guard isRemote, !hasNativeSurface else { return .leave }
        return .requestBackground
    }

    nonisolated static func parkedStart(viewAlive: Bool, inWindow: Bool, needsStart: Bool) -> ParkedStart {
        guard viewAlive else { return .drop }
        if inWindow { return .create }
        return needsStart ? .startHeadless : .drop
    }

    private static let startLog = Logger(subsystem: "com.stage11.c11", category: "hc.lifecycle")

    /// Every parked start that does not create in place leaves a public line.
    nonisolated static func logParkedStart(_ action: ParkedStart, panelID: UUID) {
        switch action {
        case .create: return
        case .startHeadless:
            startLog.info("hc_parked_start panel=\(panelID.uuidString, privacy: .public) action=start_headless reason=view_left_window")
        case .drop:
            startLog.info("hc_parked_start panel=\(panelID.uuidString, privacy: .public) action=drop reason=nothing_to_start")
        }
    }

    /// The attachment's screen receipt within `nanoseconds`; false on timeout.
    /// The tracker's own bound still ends the inner wait.
    nonisolated static func screenCurrent(_ attachment: any HCAttachment, after revision: HCDisplayRevision,
                                          within nanoseconds: UInt64) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = HCResumeOnce(continuation)
            let timer = Task {
                try? await Task.sleep(nanoseconds: nanoseconds)
                once.resume(false)
            }
            Task {
                let receipt = await attachment.screenCurrent(after: revision)
                timer.cancel()
                once.resume(receipt != nil)
            }
        }
    }
}

private final class HCResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
