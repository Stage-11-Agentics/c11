import AppKit
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
private final class FakeRenderingHost: HCRenderingHost {
    var grid: HCGridSize? = HCGridSize(columns: 80, rows: 24)
    var cell: (UInt32, UInt32) = (16, 32)
    var foreground = NSColor(srgbRed: 0x4a / 255.0, green: 0x45 / 255.0, blue: 0x43 / 255.0, alpha: 1)
    var background = NSColor(srgbRed: 0x28 / 255.0, green: 0x2c / 255.0, blue: 0x34 / 255.0, alpha: 1)
    var visible = true
    var refreshes: [String] = []

    func renderingSurfaceGrid() -> (grid: HCGridSize, cellWidth: UInt32, cellHeight: UInt32)? {
        grid.map { ($0, cell.0, cell.1) }
    }
    func renderingThemeColors() -> (foreground: NSColor, background: NSColor, cursor: NSColor?) {
        (foreground, background, nil)
    }
    var renderingIsVisible: Bool { visible }
    func renderingForceRefresh(reason: String) { refreshes.append(reason) }
}

private final class NoInput: HCInputPort {
    func submit(_ request: HCInputRequest) async -> HCInputOutcome { .refused(.unavailable) }
    func receiveRaw(_ bytes: Data, kind: HCRawInputKind, generation: UInt64) {}
    func invalidate(generation: UInt64, reason: HCInputRefusal) {}
}

private final class FakeAttachment: HCAttachment, @unchecked Sendable {
    let key = HCTerminalKey(owningCoreID: "core", localAddress: "t1")
    let generation: UInt64
    let input: any HCInputPort = NoInput()
    private let lock = NSLock()
    private var sent: [HCDisplayState] = []
    /// Delay per call index, to let a later call race an earlier one.
    var delays: [UInt64] = []
    private var calls = 0

    init(generation: UInt64) { self.generation = generation }

    var displays: [HCDisplayState] { lock.lock(); defer { lock.unlock() }; return sent }

    func submit(_ request: HCInputRequest) async -> HCInputOutcome { .refused(.unavailable) }
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { nil }
    func updateDisplay(_ display: HCDisplayState) async -> HCControlOutcome {
        lock.lock()
        let index = calls
        calls += 1
        let delay = index < delays.count ? delays[index] : 0
        lock.unlock()
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        lock.lock()
        sent.append(display)
        lock.unlock()
        return .written
    }
    func detach() {}
}

/// What reaches hc, in writer order.
private final class FakeWriter: @unchecked Sendable {
    enum Frame: Equatable { case resize(HCGridSize), data(String), facts }
    private let lock = NSLock()
    private var frames: [Frame] = []
    func append(_ frame: Frame) { lock.lock(); frames.append(frame); lock.unlock() }
    var all: [Frame] { lock.lock(); defer { lock.unlock() }; return frames }
    var resizes: [HCGridSize] { all.compactMap { if case .resize(let g) = $0 { return g } else { return nil } } }
}

/// 2C's attachment as the ledger contract requires: a display update's
/// RESIZE is decided by `admitDisplayResize` at the moment it enters the
/// ordered writer; updates can be held to model a send queued behind others.
private final class OrderedAttachment: HCAttachment, @unchecked Sendable {
    let key = HCTerminalKey(owningCoreID: "core", localAddress: "t1")
    let generation: UInt64
    let input: any HCInputPort = NoInput()
    let writer: FakeWriter
    weak var rendering: HCPanelRendering?
    private let lock = NSLock()
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(generation: UInt64, writer: FakeWriter) { self.generation = generation; self.writer = writer }

    func hold() { lock.lock(); holding = true; lock.unlock() }
    func release() {
        lock.lock(); holding = false; let waiting = held; held.removeAll(); lock.unlock()
        for c in waiting { c.resume() }
    }

    func submit(_ request: HCInputRequest) async -> HCInputOutcome { .refused(.unavailable) }
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { nil }
    func updateDisplay(_ display: HCDisplayState) async -> HCControlOutcome {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if holding { held.append(c); lock.unlock() } else { lock.unlock(); c.resume() }
        }
        if rendering?.admitDisplayResize(display) == true { writer.append(.resize(display.grid)) }
        writer.append(.facts)
        return .written
    }
    func detach() {}

    /// 2C's in-band lane: RESIZE (if the ledger says hc lacks the grid) and
    /// the 2048 report go into the writer together.
    func inBandReport(_ grid: HCGridSize) {
        if rendering?.claimInBandGrid(columns: grid.columns, rows: grid.rows) == true { writer.append(.resize(grid)) }
        writer.append(.data("2048 \(grid.rows);\(grid.columns)"))
    }
}

@MainActor
final class HCPanelRenderingTests: XCTestCase {
    private func makeRendering(_ host: FakeRenderingHost) -> HCPanelRendering {
        HCPanelRendering(
            host: host, pinVersion: "0.1.16",
            probe: HCLatencyProbeState(enabled: false),
            hopToMain: { work in DispatchQueue.main.async { MainActor.assumeIsolated { work() } } },
            observeTheme: false
        )
    }

    private func drainMain(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testAttachStateCarriesGridAndThemeFacts() throws {
        let host = FakeRenderingHost()
        let rendering = makeRendering(host)
        let state = try XCTUnwrap(rendering.displayStateForAttach(attachmentGeneration: 1, focused: true))
        XCTAssertEqual(state.grid, HCGridSize(columns: 80, rows: 24))
        XCTAssertEqual(state.facts.background, HCRGBColor(red: 0x28, green: 0x2c, blue: 0x34))
        XCTAssertEqual(state.facts.foreground, HCRGBColor(red: 0x4a, green: 0x45, blue: 0x43))
        XCTAssertEqual(state.facts.cellWidth, 16)
        XCTAssertTrue(state.focused)
    }

    func testScreenCurrentFollowsTheParsedPaintAndDiesWithTheAttachment() async throws {
        let host = FakeRenderingHost()
        let rendering = makeRendering(host)
        let state = try XCTUnwrap(rendering.displayStateForAttach(attachmentGeneration: 7, focused: false))
        rendering.attached(FakeAttachment(generation: 7))
        rendering.didParse(HCOutputChunk(attachmentGeneration: 7, watermark: 0, bytes: HCPaintFixture.paint()))
        let receipt = await rendering.screenCurrent(after: state.revision)
        XCTAssertEqual(receipt?.columns, 80)

        rendering.detached()
        let afterDetach = await rendering.screenCurrent(after: state.revision)
        XCTAssertNil(afterDetach)
    }

    func testAReattachInvalidatesTheOldAttachmentsReceipts() async throws {
        let host = FakeRenderingHost()
        let rendering = makeRendering(host)
        let old = try XCTUnwrap(rendering.displayStateForAttach(attachmentGeneration: 1, focused: false))
        rendering.didParse(HCOutputChunk(attachmentGeneration: 1, watermark: 0, bytes: HCPaintFixture.paint()))
        _ = rendering.displayStateForAttach(attachmentGeneration: 2, focused: false)
        let stale = await rendering.screenCurrent(after: old.revision)
        XCTAssertNil(stale, "a receipt for the replaced attachment must not be issued")
    }

    func testOneThemeChangeSendsOneDisplayUpdate() async throws {
        let host = FakeRenderingHost()
        let rendering = makeRendering(host)
        _ = rendering.displayStateForAttach(attachmentGeneration: 1, focused: false)
        let attachment = FakeAttachment(generation: 1)
        rendering.attached(attachment)
        drainMain()
        let before = attachment.displays.count

        host.background = NSColor(srgbRed: 0x09 / 255.0, green: 0x03 / 255.0, blue: 0, alpha: 1)
        rendering.themeChanged() // config reload
        rendering.themeChanged() // default background changed, same theme
        try await Task.sleep(nanoseconds: 200_000_000)
        let updates = Array(attachment.displays.dropFirst(before))
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.facts.background, HCRGBColor(red: 9, green: 3, blue: 0))
    }

    func testDisplayUpdatesReachHCInGenerationOrder() async throws {
        let host = FakeRenderingHost()
        let rendering = makeRendering(host)
        _ = rendering.displayStateForAttach(attachmentGeneration: 1, focused: false)
        let attachment = FakeAttachment(generation: 1)
        attachment.delays = [150_000_000, 0, 0]
        rendering.attached(attachment)
        host.background = .black
        rendering.themeChanged()
        host.background = .white
        rendering.themeChanged()
        try await Task.sleep(nanoseconds: 500_000_000)
        let generations = attachment.displays.map(\.revision.displayGeneration)
        XCTAssertEqual(generations, generations.sorted(), "an older display state must never land after a newer one")
        XCTAssertEqual(attachment.displays.last?.facts.background, HCRGBColor(red: 255, green: 255, blue: 255))
    }

    func testACompletedPaintNudgesAVisibleSurfaceOnce() throws {
        let host = FakeRenderingHost()
        let rendering = makeRendering(host)
        _ = rendering.displayStateForAttach(attachmentGeneration: 1, focused: false)
        rendering.didParse(HCOutputChunk(attachmentGeneration: 1, watermark: 0, bytes: HCPaintFixture.paint()))
        drainMain()
        XCTAssertEqual(host.refreshes, ["c11.paint"])
        XCTAssertEqual(rendering.paintNudges, 1)
    }

    func testAHiddenSurfaceIsNotNudged() throws {
        let host = FakeRenderingHost()
        host.visible = false
        let rendering = makeRendering(host)
        _ = rendering.displayStateForAttach(attachmentGeneration: 1, focused: false)
        rendering.didParse(HCOutputChunk(attachmentGeneration: 1, watermark: 0, bytes: HCPaintFixture.paint()))
        rendering.attached(FakeAttachment(generation: 1))
        host.grid = HCGridSize(columns: 60, rows: 20)
        rendering.surfaceSizeChanged()
        drainMain()
        XCTAssertTrue(host.refreshes.isEmpty)
    }

    func testASettledResizeSendsTheGridAndNudgesOnce() throws {
        let host = FakeRenderingHost()
        let rendering = makeRendering(host)
        _ = rendering.displayStateForAttach(attachmentGeneration: 1, focused: false)
        let attachment = FakeAttachment(generation: 1)
        rendering.attached(attachment)
        drainMain()
        host.refreshes.removeAll()
        host.grid = HCGridSize(columns: 57, rows: 42)
        rendering.surfaceSizeChanged()
        rendering.surfaceSizeChanged()
        drainMain(0.3)
        XCTAssertEqual(host.refreshes, ["c11.resize"])
        XCTAssertEqual(attachment.displays.last?.grid, HCGridSize(columns: 57, rows: 42))
    }

    func testNewTerminalArgvIsGatedForThePanelsSize() {
        let host = FakeRenderingHost()
        let rendering = makeRendering(host)
        let argv = rendering.wrapNewTerminalArgv(["/bin/zsh", "-l"])
        XCTAssertEqual(argv.first, "/bin/sh")
        XCTAssertTrue(argv.contains("24 80"))
        XCTAssertEqual(Array(argv.suffix(2)), ["/bin/zsh", "-l"])
    }

    func testTheInBandPathAndTheDebouncedPathShareOneLedger() {
        let host = FakeRenderingHost()
        let rendering = makeRendering(host)
        _ = rendering.displayStateForAttach(attachmentGeneration: 1, focused: false)
        XCTAssertFalse(rendering.claimInBandGrid(columns: 80, rows: 24), "the attach already carried 80x24")
        XCTAssertTrue(rendering.claimInBandGrid(columns: 57, rows: 42))
        XCTAssertFalse(rendering.claimInBandGrid(columns: 57, rows: 42))
    }

    func testAProvisionalAttachStateIsRekeyedWithoutANewGeneration() async throws {
        let host = FakeRenderingHost()
        let rendering = makeRendering(host)
        let provisional = try XCTUnwrap(rendering.displayStateForAttach(
            attachmentGeneration: HCPanelRendering.provisionalAttachmentGeneration, focused: false))
        let real = try XCTUnwrap(rendering.displayStateForAttach(attachmentGeneration: 5, focused: false))
        XCTAssertEqual(real.revision, HCDisplayRevision(attachmentGeneration: 5,
                                                         displayGeneration: provisional.revision.displayGeneration))
        XCTAssertEqual(real.grid, provisional.grid)
        let attachment = FakeAttachment(generation: 5)
        rendering.attached(attachment)
        rendering.didParse(HCOutputChunk(attachmentGeneration: 5, watermark: 0, bytes: HCPaintFixture.paint()))
        let receipt = await rendering.screenCurrent(after: real.revision)
        XCTAssertEqual(receipt?.revision, real.revision, "hc already has this state: no update is needed for a receipt")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(attachment.displays.isEmpty)
    }

    func testAChangeBetweenProvisionalAndRealIsSentOnAttach() async throws {
        let host = FakeRenderingHost()
        let rendering = makeRendering(host)
        let provisional = try XCTUnwrap(rendering.displayStateForAttach(
            attachmentGeneration: HCPanelRendering.provisionalAttachmentGeneration, focused: false))
        host.grid = HCGridSize(columns: 100, rows: 30) // resized while the attach was in flight
        let real = try XCTUnwrap(rendering.displayStateForAttach(attachmentGeneration: 5, focused: false))
        XCTAssertEqual(real.revision.displayGeneration, provisional.revision.displayGeneration + 1)
        XCTAssertEqual(real.grid, HCGridSize(columns: 100, rows: 30))
        let attachment = FakeAttachment(generation: 5)
        rendering.attached(attachment)
        rendering.didParse(HCOutputChunk(attachmentGeneration: 5, watermark: 0, bytes: HCPaintFixture.paint()))
        let receipt = await rendering.screenCurrent(after: real.revision)
        XCTAssertEqual(receipt?.revision, real.revision)
        XCTAssertEqual(receipt?.columns, 100)
        XCTAssertEqual(attachment.displays.filter { $0.revision == real.revision }.count, 1,
                       "hc received the provisional grid; the newer state must be sent exactly once")
    }

    func testEachFocusTransitionSendsOneDisplayWithTheNewFocus() async throws {
        let host = FakeRenderingHost()
        let rendering = makeRendering(host)
        _ = rendering.displayStateForAttach(attachmentGeneration: 3, focused: false)
        let attachment = FakeAttachment(generation: 3)
        rendering.attached(attachment)
        try await Task.sleep(nanoseconds: 100_000_000)
        let before = attachment.displays.count
        rendering.focusChanged(true)
        rendering.focusChanged(true) // the same transition reported twice
        rendering.focusChanged(false)
        try await Task.sleep(nanoseconds: 200_000_000)
        let focusSends = attachment.displays.dropFirst(before).map(\.focused)
        XCTAssertEqual(focusSends, [true, false], "one FOCUS per real transition: hc reports every frame to the program")
    }

    // MARK: Astra PR #12 finding 2: RESIZE order at the writer

    private func orderedRendering(_ host: FakeRenderingHost, _ writer: FakeWriter) -> (HCPanelRendering, OrderedAttachment) {
        let rendering = makeRendering(host)
        _ = rendering.displayStateForAttach(attachmentGeneration: 1, focused: false)
        let attachment = OrderedAttachment(generation: 1, writer: writer)
        attachment.rendering = rendering
        rendering.attached(attachment)
        return (rendering, attachment)
    }

    func testAQueuedOlderDisplaySizeNeverLandsAfterANewerInBandResize() async throws {
        let host = FakeRenderingHost()
        let writer = FakeWriter()
        let (rendering, attachment) = orderedRendering(host, writer)
        try await Task.sleep(nanoseconds: 100_000_000)
        attachment.hold()
        let g1 = HCGridSize(columns: 57, rows: 42), g2 = HCGridSize(columns: 100, rows: 30)
        host.grid = g1
        rendering.surfaceSizeChanged()
        try await Task.sleep(nanoseconds: 150_000_000) // debounce fired; the g1 update is held
        host.grid = g2
        attachment.inBandReport(g2) // the next reflow's report goes out first
        attachment.release()
        rendering.surfaceSizeChanged()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(writer.resizes, [g2], "hc must end at the newest grid, with no stale RESIZE after it")
        XCTAssertEqual(writer.all.first, .resize(g2))
    }

    func testAScheduledDisplaySizeDoesNotSuppressTheReportsResize() async throws {
        let host = FakeRenderingHost()
        let writer = FakeWriter()
        let (rendering, attachment) = orderedRendering(host, writer)
        try await Task.sleep(nanoseconds: 100_000_000)
        attachment.hold()
        let g2 = HCGridSize(columns: 100, rows: 30)
        host.grid = g2
        rendering.surfaceSizeChanged()
        try await Task.sleep(nanoseconds: 150_000_000) // the g2 update is scheduled, not yet written
        attachment.inBandReport(g2)
        attachment.release()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(writer.all.prefix(2), [.resize(g2), .data("2048 30;100")],
                       "the report must have its RESIZE ahead of it in the writer")
        XCTAssertEqual(writer.resizes, [g2], "the later display update must not resend the grid")
    }

    func testAnOldAttachmentsHeldUpdateNeverSuppressesTheReplacementsResize() async throws {
        // Reconnect: generation 1 has a display update for 57x42 held before
        // its writer admission; the panel reattaches as generation 2 at
        // 100x30; then the old update resumes.
        let host = FakeRenderingHost()
        let oldWriter = FakeWriter()
        let (rendering, oldAttachment) = orderedRendering(host, oldWriter)
        try await Task.sleep(nanoseconds: 100_000_000)
        oldAttachment.hold()
        let g1 = HCGridSize(columns: 57, rows: 42), g2 = HCGridSize(columns: 100, rows: 30)
        host.grid = g1
        rendering.surfaceSizeChanged()
        try await Task.sleep(nanoseconds: 150_000_000)
        rendering.detached()
        host.grid = g2
        _ = rendering.displayStateForAttach(attachmentGeneration: 2, focused: false)
        let newWriter = FakeWriter()
        let newAttachment = OrderedAttachment(generation: 2, writer: newWriter)
        newAttachment.rendering = rendering
        rendering.attached(newAttachment)
        oldAttachment.release()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(oldWriter.resizes.isEmpty, "a retired attachment's update is not admitted")
        // The replacement reflows to 57x42: its report needs its own RESIZE.
        host.grid = g1
        newAttachment.inBandReport(g1)
        XCTAssertEqual(newWriter.all.prefix(2), [.resize(g1), .data("2048 42;57")],
                       "the old update must not have marked the new attachment's ledger")
    }

    // MARK: Astra PR #12 finding 3: invalidation across replacement

    func testReplacingTheAttachmentAnswersItsPendingRequestWithNil() async throws {
        let host = FakeRenderingHost()
        let rendering = HCPanelRendering(
            host: host, pinVersion: "0.1.16", probe: HCLatencyProbeState(enabled: false),
            observeTheme: false, screenTimeout: 30, screenSchedule: { _, _ in }
        )
        let old = try XCTUnwrap(rendering.displayStateForAttach(attachmentGeneration: 1, focused: false))
        let box = HCReceiptBox()
        let done = expectation(description: "old request answered")
        Task {
            box.set(await rendering.screenCurrent(after: old.revision))
            done.fulfill()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = rendering.displayStateForAttach(attachmentGeneration: 2, focused: false)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertTrue(box.answered)
        XCTAssertNil(box.value)
    }
}

/// The live backend's composition must hand every terminal surface ticket 5's
/// rendering adapter. With the default unavailable adapter no screen is ever
/// current, so every guarded send is refused ("terminal screen is not ready").
/// The surface is constructed without a native handle; nothing is launched.
@MainActor
final class HCLiveCompositionRenderingTests: XCTestCase {
    private func makeSurface() -> TerminalSurface {
        TerminalSurface(workspaceId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                        configTemplate: nil, workingDirectory: nil)
    }

    func testTheLiveCompositionGivesEachSurfaceThePanelRenderingAdapter() throws {
        let composition = HCBackendComposition()
        let surface = makeSurface(), other = makeSurface()
        XCTAssertTrue(composition.makeRenderingAdapter(surface) is HCUnavailableRenderingAdapter,
                      "control: an uncomposed backend has no renderer")

        composition.installLiveSurfaceFactories()

        let adapter = composition.makeRenderingAdapter(surface)
        XCTAssertFalse(adapter is HCUnavailableRenderingAdapter, "the live composition must wire the rendering adapter")
        let rendering = try XCTUnwrap(adapter as? HCPanelRendering)
        XCTAssertEqual(rendering.pinVersion, HCPin.current.version)
        let second = try XCTUnwrap(composition.makeRenderingAdapter(other) as? HCPanelRendering)
        XCTAssertFalse(second === rendering, "each surface owns its own rendering state")
        XCTAssertFalse(composition.makeInputEncoder(surface) is HCUnavailableInputEncoder)
    }
}
