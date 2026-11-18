import AppKit

/// What ticket 5 needs from a terminal panel's native surface. Main thread.
/// `TerminalSurface` conforms in `HCTerminalSurfaceRenderingHost.swift`; tests
/// supply a fake.
@MainActor
protocol HCRenderingHost: AnyObject {
    /// Ghostty's grid and cell size in pixels; nil without a sized surface.
    func renderingSurfaceGrid() -> (grid: HCGridSize, cellWidth: UInt32, cellHeight: UInt32)?
    /// Default foreground, background and (when configured) cursor colors.
    func renderingThemeColors() -> (foreground: NSColor, background: NSColor, cursor: NSColor?)
    /// True when the surface sits in a real window (not hidden, not the
    /// headless bootstrap window): only then is a repaint nudge worth its cost.
    var renderingIsVisible: Bool { get }
    /// c11's existing repaint: display-id reassert, then refresh. Called,
    /// never modified (it is on the typing path).
    func renderingForceRefresh(reason: String)
}

/// Ticket 5's per-panel rendering state behind 2C's `HCRenderingAdapter`
/// extension points (contract ownership row "5 rendering/screenCurrent/
/// resize/facts"; the Orchestrator's ruling on C11H-6's plan):
///
/// - `wrapNewTerminalArgv`: the 200x120 size gate, new local creations only;
/// - `noteRawInput` / `noteOutput` / `didParse`: the latency probe and the
///   paint scanner on 2C's native lanes;
/// - display state for attach and `updateDisplay`: grid, theme facts, cell
///   size, deduplicated;
/// - the debounced resize path and the shared sent-grid ledger;
/// - `screenCurrent(after:)` per attachment;
/// - repaint nudges after a settled resize and after each completed paint
///   (the 0.1.16 stale-after-core-kill case, Pathfinder row 15).
final class HCPanelRendering: @unchecked Sendable {
    typealias Nudge = @Sendable (_ work: @escaping @MainActor () -> Void) -> Void

    let pinVersion: String
    let probe: HCLatencyProbeState

    // Shared with lanes; guarded by `stateLock`.
    private let stateLock = NSLock()
    private var tracker: HCScreenTracker?
    private var ledger: HCSentGridLedger?

    // Main only.
    @MainActor private weak var host: HCRenderingHost?
    @MainActor private var attachment: (any HCAttachment)?
    @MainActor private var displays = HCDisplayStateTracker()
    @MainActor private var focused = false
    @MainActor private var nudgePending = false
    /// Display updates go out in display-generation order: each waits for the
    /// one before it, so a theme change and a resize never reach hc swapped.
    @MainActor private var lastDisplaySend: Task<Void, Never>?
    /// The provisional attach state, until the real generation re-keys it.
    @MainActor private var provisional: HCDisplayState?
    /// A state newer than what the attach RPC carried, sent once attached.
    @MainActor private var sendOnAttach: HCDisplayState?
    @MainActor private lazy var resize = HCResizeCoordinator(
        readGrid: { [weak self] in MainActor.assumeIsolated { self?.host?.renderingSurfaceGrid()?.grid } },
        settled: { [weak self] grid in
            MainActor.assumeIsolated { self?.resizeSettled(grid) }
        }
    )
    private let hopToMain: Nudge
    private let screenTimeout: TimeInterval
    private let screenSchedule: HCScreenTracker.Scheduler?
    /// Display generation -> the ledger observation of its grid, until the
    /// writer admits (or, without 2C's admission call, until the send ends).
    /// Guarded by `stateLock`.
    private var pendingObservations: [UInt64: UInt64] = [:]
    private var observers: [NSObjectProtocol] = []

    /// Counts for proofs (T5.5) and diagnostics.
    @MainActor private(set) var resizeNudges: UInt64 = 0
    @MainActor private(set) var paintNudges: UInt64 = 0

    @MainActor
    init(
        host: HCRenderingHost,
        pinVersion: String,
        probe: HCLatencyProbeState = HCLatencyProbeState(),
        hopToMain: @escaping Nudge = { work in DispatchQueue.main.async { MainActor.assumeIsolated { work() } } },
        observeTheme: Bool = true,
        screenTimeout: TimeInterval = HCLimits.screenSeconds,
        screenSchedule: HCScreenTracker.Scheduler? = nil
    ) {
        self.screenTimeout = screenTimeout
        self.screenSchedule = screenSchedule
        self.host = host
        self.pinVersion = pinVersion
        self.probe = probe
        self.hopToMain = hopToMain
        if observeTheme {
            for name in [Notification.Name.ghosttyConfigDidReload, .ghosttyDefaultBackgroundDidChange] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.themeChanged() }
                })
            }
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: 2C's extension points

    /// New local creation only. The panel's grid, when known, tells the gate
    /// what size to wait for.
    @MainActor
    func wrapNewTerminalArgv(_ argv: [String]) -> [String] {
        HCSizeGate.wrap(argv, panelGrid: host?.renderingSurfaceGrid()?.grid)
    }

    /// Ghostty IO thread, inside the native input callback.
    @inline(__always)
    func noteRawInput(_ ptr: UnsafeRawPointer, _ len: Int) {
        probe.noteRawInput(ptr, len)
    }

    /// Output lane, before `ghostty_surface_process_output`.
    func noteOutput(_ chunk: HCOutputChunk) {
        probe.noteOutput(chunk.bytes)
    }

    /// Output lane, after `ghostty_surface_process_output` returned.
    func didParse(_ chunk: HCOutputChunk) {
        currentTracker()?.didParse(chunk)
    }

    /// Ghostty IO thread: 2C's in-band 2048 path asks before sending RESIZE
    /// ahead of the report. True: send it; false: hc already has this grid.
    @inline(__always)
    func claimInBandGrid(columns: UInt16, rows: UInt16) -> Bool {
        currentLedger()?.admitInBand(HCGridSize(columns: columns, rows: rows)) ?? true
    }

    /// 2C's writer, at the moment a display update's RESIZE would enter the
    /// ordered writer (any thread). True: write RESIZE(state.grid) now. False:
    /// omit the RESIZE (hc already has the grid, or an in-band RESIZE observed
    /// later already went out); the update's other frames still go.
    func admitDisplayResize(_ state: HCDisplayState) -> Bool {
        stateLock.lock()
        // A state from a replaced or detached attachment never reaches the
        // current attachment's ledger: its bytes go to a retired channel, and
        // recording its grid here would suppress the replacement's own RESIZE
        // (Astra, PR #12 repair verification).
        guard let ledger = self.ledger,
              let tracker, tracker.attachmentGeneration == state.revision.attachmentGeneration else {
            stateLock.unlock()
            return false
        }
        let observation = pendingObservations.removeValue(forKey: state.revision.displayGeneration)
        stateLock.unlock()
        return ledger.admit(state.grid, observedAt: observation ?? ledger.observe())
    }

    // MARK: Attach lifecycle (main)

    /// Attachment generation 0 asks for the attach request's content before
    /// the session has assigned a generation (hc receives grid and facts in
    /// the attach RPC itself). The later call with the real generation re-keys
    /// that state, keeping its display generation when nothing changed.
    static let provisionalAttachmentGeneration: UInt64 = 0

    /// The display state an attach request carries.
    ///
    /// Ticket 5 numbers display generations per panel. Call with
    /// `provisionalAttachmentGeneration` before `session.attach` and send the
    /// result; call again with the real generation once it is known, and bind
    /// the returned revision (it is what receipts carry). The real-generation
    /// call starts this attachment's screen tracker; the previous tracker
    /// answers nil from then on. If grid or facts changed between the two
    /// calls, the returned state is newer than what hc received and
    /// `attached(_:)` sends it.
    @MainActor
    func displayStateForAttach(attachmentGeneration: UInt64, focused: Bool) -> HCDisplayState? {
        guard let host, let surface = host.renderingSurfaceGrid() else { return nil }
        self.focused = focused
        let facts = currentFacts(host, surface)
        if attachmentGeneration == Self.provisionalAttachmentGeneration {
            let state = displays.next(
                attachmentGeneration: attachmentGeneration, grid: surface.grid, facts: facts, focused: focused, force: true
            )
            provisional = state
            return state
        }
        let state: HCDisplayState
        let sent: HCDisplayState
        sendOnAttach = nil
        if let earlier = provisional {
            provisional = nil
            let hcHas = displays.rekey(earlier, to: attachmentGeneration)
            sent = hcHas
            if earlier.grid == surface.grid, earlier.facts == facts, earlier.focused == focused {
                state = hcHas
            } else if let newer = displays.next(
                attachmentGeneration: attachmentGeneration, grid: surface.grid, facts: facts, focused: focused, force: true
            ) {
                state = newer
                sendOnAttach = newer
            } else {
                state = hcHas
            }
        } else {
            guard let fresh = displays.next(
                attachmentGeneration: attachmentGeneration, grid: surface.grid, facts: facts, focused: focused, force: true
            ) else { return nil }
            state = fresh
            sent = fresh
        }
        let newTracker: HCScreenTracker
        if let screenSchedule {
            newTracker = HCScreenTracker(
                attachmentGeneration: attachmentGeneration, pinVersion: pinVersion,
                timeout: screenTimeout, schedule: screenSchedule,
                onPainted: { [weak self] _ in self?.paintCompleted() }
            )
        } else {
            newTracker = HCScreenTracker(
                attachmentGeneration: attachmentGeneration, pinVersion: pinVersion,
                timeout: screenTimeout,
                onPainted: { [weak self] _ in self?.paintCompleted() }
            )
        }
        let newLedger = HCSentGridLedger(initial: sent.grid)
        stateLock.lock()
        let old = tracker
        tracker = newTracker
        ledger = newLedger
        pendingObservations.removeAll()
        if let pending = sendOnAttach {
            // Its grid was read just now, after the attach RPC's.
            pendingObservations[pending.revision.displayGeneration] = newLedger.observe()
        }
        stateLock.unlock()
        old?.invalidate()
        newTracker.noteSurfaceGrid(surface.grid)
        newTracker.noteDisplaySent(sent.revision, grid: sent.grid)
        return state
    }

    /// The attach request with that state succeeded.
    @MainActor
    func attached(_ attachment: any HCAttachment) {
        guard attachment.generation == currentTracker()?.attachmentGeneration else { return }
        self.attachment = attachment
        if let pending = sendOnAttach, pending.revision.attachmentGeneration == attachment.generation {
            sendOnAttach = nil
            send(pending, via: attachment)
        }
        resize.attachmentReady()
    }

    /// The attachment is gone (detach, connection loss, replacement).
    @MainActor
    func detached() {
        attachment = nil
        lastDisplaySend = nil
        sendOnAttach = nil
        stateLock.lock()
        let old = tracker
        tracker = nil
        ledger = nil
        pendingObservations.removeAll()
        stateLock.unlock()
        old?.invalidate()
    }

    /// `screenCurrent(after:)` for whichever attachment the revision names.
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? {
        guard let tracker = currentTracker(), tracker.attachmentGeneration == revision.attachmentGeneration else {
            return nil
        }
        return await tracker.screenCurrent(after: revision)
    }

    // MARK: Size and theme (main)

    /// After every `ghostty_surface_set_size` or cell-size change.
    @MainActor
    func surfaceSizeChanged() {
        resize.noteSizeChanged()
    }

    @MainActor
    func themeChanged() {
        sendDisplayIfChanged()
    }

    /// Every real UI focus transition (2C calls it after
    /// `ghostty_surface_set_focus`). hc learns the focused viewer from the
    /// display state's FOCUS, which it needs for "who sets the size" whether
    /// or not the program asked for focus reports.
    ///
    /// hc 0.1.16 writes `CSI I`/`CSI O` to a program that set mode 1004 on
    /// *every* FOCUS frame (`viewers.rs` `viewer_focus`, no dedupe), so this
    /// must be the only FOCUS source for a transition: 2C's lane swallows the
    /// CSI I/O bytes Ghostty emits for the same transition instead of
    /// converting them. Repeating the current value sends nothing (the
    /// display tracker's dedupe).
    @MainActor
    func focusChanged(_ focused: Bool) {
        self.focused = focused
        sendDisplayIfChanged()
    }

    // MARK: Private

    private func currentTracker() -> HCScreenTracker? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tracker
    }

    private func currentLedger() -> HCSentGridLedger? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return ledger
    }

    @MainActor
    private func resizeSettled(_ grid: HCGridSize) {
        currentTracker()?.noteSurfaceGrid(grid)
        sendDisplayIfChanged()
        // Defect 2: an unfocused manual-IO surface keeps its pre-resize frame
        // until the next key unless its display id is reasserted and it is
        // refreshed. Visible surfaces only.
        nudge(reason: "c11.resize") { self.resizeNudges &+= 1 }
    }

    @MainActor
    private func currentFacts(
        _ host: HCRenderingHost, _ surface: (grid: HCGridSize, cellWidth: UInt32, cellHeight: UInt32)
    ) -> HCDisplayFacts {
        let colors = host.renderingThemeColors()
        return HCDisplayFactsBuilder.facts(
            foreground: colors.foreground, background: colors.background, cursor: colors.cursor,
            cellWidthPixels: surface.cellWidth, cellHeightPixels: surface.cellHeight
        )
    }

    @MainActor
    private func sendDisplayIfChanged() {
        guard let host, let attachment, let surface = host.renderingSurfaceGrid() else { return }
        let observation = currentLedger()?.observe()
        guard let state = displays.next(
            attachmentGeneration: attachment.generation, grid: surface.grid,
            facts: currentFacts(host, surface), focused: focused
        ) else { return }
        if let observation {
            stateLock.lock()
            pendingObservations[state.revision.displayGeneration] = observation
            stateLock.unlock()
        }
        send(state, via: attachment)
    }

    /// Display updates go out in display-generation order: each waits for the
    /// one before it. The tracker learns a revision only once hc has it, with
    /// the grid hc actually has (a stale RESIZE is dropped at admission).
    @MainActor
    private func send(_ state: HCDisplayState, via attachment: any HCAttachment) {
        let tracker = currentTracker()
        let ledger = currentLedger()
        let previous = lastDisplaySend
        lastDisplaySend = Task {
            await previous?.value
            let outcome = await attachment.updateDisplay(state)
            if case .unavailable = outcome { return }
            // A writer that never called admitDisplayResize still wrote this
            // grid: record it now, so the shared ledger stays true.
            self.recordUnadmitted(state, in: ledger)
            await MainActor.run { tracker?.noteDisplaySent(state.revision, grid: ledger?.current ?? state.grid) }
        }
    }

    private func recordUnadmitted(_ state: HCDisplayState, in ledger: HCSentGridLedger?) {
        stateLock.lock()
        let observation = pendingObservations.removeValue(forKey: state.revision.displayGeneration)
        stateLock.unlock()
        if let ledger, let observation { _ = ledger.admit(state.grid, observedAt: observation) }
    }

    private func paintCompleted() {
        hopToMain { [weak self] in
            self?.nudge(reason: "c11.paint") { self?.paintNudges &+= 1 }
        }
    }

    /// Coalesced: at most one nudge waits for main at a time.
    @MainActor
    private func nudge(reason: String, counted: @MainActor @escaping () -> Void) {
        guard let host, host.renderingIsVisible, !nudgePending else { return }
        nudgePending = true
        hopToMain { [weak self] in
            guard let self else { return }
            self.nudgePending = false
            guard let host = self.host, host.renderingIsVisible else { return }
            host.renderingForceRefresh(reason: reason)
            counted()
        }
    }
}

/// The composition's factory hands this to 2C's bridge and attachment.
extension HCPanelRendering: HCRenderingAdapter {}
