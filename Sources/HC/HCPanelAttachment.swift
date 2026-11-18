import Foundation

final class HCPanelAttachment: HCAttachment, @unchecked Sendable {
    let key: HCTerminalKey
    let generation: UInt64
    let coordinator: HCInputCoordinator
    var input: any HCInputPort { coordinator }
    private let channel: any HCChannel
    private let sink: any HCOutputSink
    private let rendering: any HCRenderingAdapter
    private let displayChanged: @Sendable (HCDisplayState) -> Void
    var currentDisplayState: HCDisplayState { state.read() }
    private let state: HCDisplayStateCell
    private let lock = NSLock()
    private var detached = false

    init(panelID: UUID, key: HCTerminalKey, generation: UInt64, channel: any HCChannel,
         sink: any HCOutputSink, rendering: any HCRenderingAdapter, display: HCDisplayState,
         encoder: any HCInputEncoder,
         report: @escaping @Sendable (HCInputOutcome) -> Void,
         displayChanged: @escaping @Sendable (HCDisplayState) -> Void = { _ in }) {
        self.key = key
        self.generation = generation
        self.channel = channel
        self.sink = sink
        self.rendering = rendering
        self.displayChanged = displayChanged
        let state = HCDisplayStateCell(display)
        self.state = state
        coordinator = HCInputCoordinator(panelID: panelID, key: key, generation: generation,
            writer: channel, encoder: encoder, screen: rendering,
            displayRevision: { state.read().revision }, report: report,
            claimInBandGrid: { rendering.claimInBandGrid(columns: $0, rows: $1) },
            // Replacement ports are exposed to native callbacks closed; the
            // reconnect policy opens them once the new port is adopted.
            admitted: false,
            // Callers submit through HCPanelSession.submitInput, which records
            // each outcome once. Backend-owned initial input has no such caller.
            reportedSources: [.initial])
    }

    func setAdmission(_ open: Bool) { coordinator.setAdmission(open) }

    func submit(_ request: HCInputRequest) async -> HCInputOutcome { await coordinator.submit(request) }
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? {
        await rendering.screenCurrent(after: revision)
    }
    /// Attach starts an unfocused viewer; only an initially focused panel needs
    /// this first FOCUS. Subsequent changes are owned by the rendering adapter.
    func initializeFocus() async throws {
        guard state.read().focused else { return }
        if case .unavailable(let reason) = await channel.control(.focus(true)) { throw reason }
    }
    func updateDisplay(_ display: HCDisplayState) async -> HCControlOutcome {
        guard display.revision.attachmentGeneration == generation else { return .unavailable(.staleIdentity) }
        // Renderer's caller serializes display revisions. Each dependent raw
        // size report uses an ordered RESIZE+DATA batch on the same writer.
        var controls: [HCControl] = []
        // The adapter decides at admission; a vetoed RESIZE never reaches the
        // writer, while FACTS and FOCUS for this update still do.
        if rendering.admitDisplayResize(display) { controls.append(.resize(display.grid)) }
        controls.append(.facts(display.facts))
        if state.read().focused != display.focused { controls.append(.focus(display.focused)) }
        for control in controls {
            if case .unavailable(let reason) = await channel.control(control) { return .unavailable(reason) }
        }
        state.store(display)
        displayChanged(display)
        return .written
    }
    func detach() {
        lock.lock()
        guard !detached else { lock.unlock(); return }
        detached = true
        lock.unlock()
        coordinator.invalidate(generation: generation, reason: .staleIdentity)
        channel.close()
        sink.retire {}
        let rendering = rendering
        Task { @MainActor in rendering.detached() }
    }

    deinit { detach() }
}

private final class HCDisplayStateCell: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HCDisplayState
    init(_ value: HCDisplayState) { self.value = value }
    func read() -> HCDisplayState { lock.lock(); defer { lock.unlock() }; return value }
    func store(_ value: HCDisplayState) { lock.lock(); self.value = value; lock.unlock() }
}
