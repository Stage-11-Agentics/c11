import Combine
import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-112: an hc terminal that starts with no Ghostty surface (locked screen, hidden workspace), takes
/// input through hc, and gives way to a real surface. The surface-free pieces are driven for real here; the
/// TerminalSurface wiring is host-only and covered by the guest row.
final class HCHeadlessStartTests: XCTestCase {
    // MARK: policy

    func testNewPanelsStartAfterTheGraceAndRestoredPanelsAtOnce() {
        XCTAssertEqual(HCHeadless.startPolicy(persistent: true, hasNativeSurface: false, hasHeadlessAttachment: false, restoring: false), .afterGrace)
        XCTAssertEqual(HCHeadless.startPolicy(persistent: true, hasNativeSurface: false, hasHeadlessAttachment: false, restoring: true), .now)
    }

    func testNothingStartsWhenASurfaceOrAHeadlessAttachmentExistsOrTheTerminalIsNotHCManaged() {
        XCTAssertEqual(HCHeadless.startPolicy(persistent: true, hasNativeSurface: true, hasHeadlessAttachment: false, restoring: false), .leave)
        XCTAssertEqual(HCHeadless.startPolicy(persistent: true, hasNativeSurface: false, hasHeadlessAttachment: true, restoring: true), .leave)
        XCTAssertEqual(HCHeadless.startPolicy(persistent: false, hasNativeSurface: false, hasHeadlessAttachment: false, restoring: false), .leave)
    }

    // MARK: send-key vocabulary

    @MainActor
    func testEveryNamedKeyTheSurfaceRouteKnowsHasHeadlessBytesAndNoOtherDoes() {
        let names = ["ctrl-c", "ctrl+c", "sigint", "ctrl-d", "eof", "ctrl-z", "sigtstp", "ctrl-\\", "sigquit", "enter", "return",
                     "tab", "escape", "esc", "backspace", "bs", "delete", "del", "forward-delete", "space", "up", "arrow-up",
                     "down", "left", "right", "arrowright", "home", "end", "pageup", "page-up", "pgup", "pagedown", "pgdn",
                     "f1", "f4", "f5", "f10", "f12", "ctrl-a", "ctrl+x", "CTRL-L", "nonsense", "ctrl-", "ctrl-ab", "f13", ""]
        for name in names {
            XCTAssertEqual(HCHeadless.keyText(forNamedKey: name) != nil, TerminalController.namedKeyEvent(for: name) != nil, name)
        }
    }

    func testNamedKeyBytes() {
        XCTAssertEqual(HCHeadless.keyText(forNamedKey: "ctrl-c"), "\u{03}")
        XCTAssertEqual(HCHeadless.keyText(forNamedKey: "enter"), "\r")
        XCTAssertEqual(HCHeadless.keyText(forNamedKey: "up"), "\u{1B}[A")
        XCTAssertEqual(HCHeadless.keyText(forNamedKey: "Ctrl-L"), "\u{0C}")
        XCTAssertEqual(HCHeadless.keyText(forNamedKey: "backspace"), "\u{7F}")
    }

    // MARK: encoder

    func testTheEncoderTypesTextAndAddsAReturnFrameOnRequest() async throws {
        let request = HCInputRequest(operationID: UUID(), panelID: UUID(), key: HCTerminalKey(owningCoreID: "c", localAddress: "t1"),
            attachmentGeneration: 1, source: .socket, payload: Data("echo hi\nsecond".utf8), submitReturn: true)
        let frames = try await HCHeadlessInputEncoder().encode(request).get()
        guard frames.count == 2, case .data(let body) = frames[0], case .submitReturnAfter(let ret, _) = frames[1] else {
            return XCTFail("\(frames)")
        }
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "echo hi\rsecond")
        XCTAssertEqual(ret, Data([13]))
    }

    /// C11H-298: typed bytes reach the program as one burst, and Claude Code and Codex take a Return inside it as
    /// text. The Return waits the screen path's settle, per source; a bare Return has no burst to wait out.
    func testTheReturnWaitsOutTheTypedBurst() async throws {
        func request(_ text: String, source: HCInputSource) -> HCInputRequest {
            HCInputRequest(operationID: UUID(), panelID: UUID(), key: HCTerminalKey(owningCoreID: "c", localAddress: "t1"),
                attachmentGeneration: 1, source: source, payload: Data(text.utf8), submitReturn: true)
        }
        func returnDelay(_ frames: [HCOutboundFrame]) -> UInt64? {
            for frame in frames { if case .submitReturnAfter(_, let delay) = frame { return delay } }
            return nil
        }
        let socket = try await HCHeadlessInputEncoder().encode(request("Read the brief and follow it.", source: .socket)).get()
        XCTAssertEqual(returnDelay(socket), UInt64(TextBoxBehavior.returnKeyDelayMs) * 1_000_000)
        XCTAssertGreaterThanOrEqual(returnDelay(socket) ?? 0, 200_000_000)
        let mailbox = try await HCHeadlessInputEncoder().encode(request("c11 mail waiting", source: .mailbox)).get()
        XCTAssertEqual(returnDelay(mailbox), UInt64(FeedAnswerTiming.returnDelayMilliseconds(
            baseDelayMs: TextBoxBehavior.returnKeyDelayMs, debugHoldMs: 0)) * 1_000_000)
        let bare = try await HCHeadlessInputEncoder().encode(request("", source: .socket)).get()
        XCTAssertEqual(returnDelay(bare), 0)
    }

    func testABareReturnIsOneFrameAndNothingAtAllIsRefused() async throws {
        func request(_ text: String, submit: Bool) -> HCInputRequest {
            HCInputRequest(operationID: UUID(), panelID: UUID(), key: HCTerminalKey(owningCoreID: "c", localAddress: "t1"),
                attachmentGeneration: 1, source: .socket, payload: Data(text.utf8), submitReturn: submit)
        }
        let bare = try await HCHeadlessInputEncoder().encode(request("", submit: true)).get()
        XCTAssertEqual(bare.count, 1)
        let nothing = await HCHeadlessInputEncoder().encode(request("", submit: false))
        XCTAssertThrowsError(try nothing.get())
    }

    // MARK: the headless bridge is a real attachment

    @MainActor
    func testSendReachesTheTerminalThroughHCWithNoSurface() async throws {
        let panel = UUID()
        let key = HCTerminalKey(owningCoreID: "c", localAddress: "t1")
        let writer = HeadlessWriter()
        let bridge = HCNativeBridge.headless(panelID: panel, report: { _ in })
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCHeadless.grid, facts: HCDisplayFacts(), focused: false)
        let prepared = try await HCBackendComposition.prepareAttachment(key: key, generation: 1, sink: bridge, proposedDisplay: display)
        XCTAssertEqual(prepared.grid, HCGridSize(columns: 80, rows: 24))   // the default grid, no surface to size it
        let attachment = try await HCBackendComposition.makeAttachment(key: key, generation: 1,
            channel: HeadlessChannel(writer), sink: bridge, display: prepared)
        // The runtime's reconnect policy opens a bound port to programmatic input (HCPanelSession.bind).
        (attachment as? HCPanelAttachment)?.setAdmission(true)
        // send-text
        let text = await attachment.submit(HCInputRequest(operationID: UUID(), panelID: panel, key: key, attachmentGeneration: 1,
            source: .socket, payload: Data("ls".utf8), submitReturn: true))
        guard case .written(let receipt) = text else { return XCTFail("\(text)") }
        XCTAssertTrue(receipt.returnWritten)
        // send-key ctrl-c
        let keyText = try XCTUnwrap(HCHeadless.keyText(forNamedKey: "ctrl-c"))
        let keyOutcome = await attachment.submit(HCInputRequest(operationID: UUID(), panelID: panel, key: key, attachmentGeneration: 1,
            source: .socket, payload: Data(keyText.utf8), submitReturn: false))
        guard case .written = keyOutcome else { return XCTFail("\(keyOutcome)") }
        XCTAssertEqual(writer.received, Data("ls".utf8) + Data([13]) + Data([3]))
        withExtendedLifetime(attachment) {}
    }

    @MainActor
    func testTheHeadlessSinkConsumesOutputWithoutASurface() async throws {
        let bridge = HCNativeBridge.headless(panelID: UUID(), report: { _ in })
        let key = HCTerminalKey(owningCoreID: "c", localAddress: "t1")
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCHeadless.grid, facts: HCDisplayFacts(), focused: false)
        let prepared = try await HCBackendComposition.prepareAttachment(key: key, generation: 1, sink: bridge, proposedDisplay: display)
        let attachment = try await HCBackendComposition.makeAttachment(key: key, generation: 1,
            channel: HeadlessChannel(HeadlessWriter()), sink: bridge, display: prepared)
        defer { withExtendedLifetime(attachment) {} }          // a released attachment detaches and retires its sink
        let outcome = await bridge.consume(HCOutputChunk(attachmentGeneration: 1, watermark: 1, bytes: Data("hello".utf8)))
        XCTAssertEqual(String(describing: outcome), String(describing: HCOutputConsumption.consumed))
    }
}

/// The production call sites, driven for real (a `Workspace`, a `WorkspaceManager`, a session snapshot) with
/// `TerminalSurface.headlessRequestSink` observing the request. Removing a call site turns these red.
@MainActor
final class HCHeadlessRequestPathTests: XCTestCase {
    private var requests: [(UUID, Bool)] = []
    private let studio = HCRemoteTarget(machine: "studio", cwd: "/work")

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        requests = []
        TerminalSurface.headlessRequestSink = { [unowned self] surface, restoring in self.requests.append((surface.id, restoring)) }
    }

    override func tearDown() {
        TerminalSurface.headlessRequestSink = nil
        super.tearDown()
    }

    private func snapshot(_ id: UUID, remote: HCRemoteTarget?) -> SessionPanelSnapshot {
        SessionPanelSnapshot(id: id, type: .terminal, title: "Fixture", customTitle: nil,
            directory: "/fixture", isPinned: false, isManuallyUnread: false, gitBranch: nil, listeningPorts: [], ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: remote == nil ? "/fixture" : nil, scrollback: nil,
                hcIdentity: HCPanelIdentity(panelID: id, persistence: .nonpersistent), hcRemoteTarget: remote),
            browser: nil, markdown: nil)
    }

    private func workspaceSnapshot(_ panels: [SessionPanelSnapshot]) -> SessionWorkspaceSnapshot {
        let ids = panels.map(\.id)
        return SessionWorkspaceSnapshot(id: UUID(), processTitle: "Fixture", customTitle: nil, customColor: nil, isPinned: false,
            currentDirectory: "/fixture", focusedPanelId: ids[0],
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: ids, selectedPanelId: ids[0])), panels: panels,
            statusEntries: [], logEntries: [], progress: nil, gitBranch: nil)
    }

    func testEveryNewTerminalLocalOrRemoteRequestsTheHeadlessStart() throws {
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let source = try XCTUnwrap(workspace.focusedTerminalPanel)
        let local = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false, machine: .local))
        let remote = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false, machine: .on("studio")))
        let split = try XCTUnwrap(workspace.newTerminalSplit(from: source.id, orientation: .horizontal, focus: false))
        for panel in [local, remote, split] {
            XCTAssertTrue(requests.contains { $0.0 == panel.id && $0.1 == false }, "\(panel.id)")
        }
    }

    func testRestoringAWorkspaceRequestsTheRestoredStartForEveryTerminal() {
        let local = UUID(), remote = UUID(), hiddenLocal = UUID()
        let manager = WorkspaceManager()
        manager.restoreSessionSnapshot(SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [
            workspaceSnapshot([snapshot(local, remote: nil)]),
            workspaceSnapshot([snapshot(remote, remote: studio), snapshot(hiddenLocal, remote: nil)])]))
        for id in [local, remote, hiddenLocal] {
            XCTAssertTrue(requests.contains { $0.0 == id && $0.1 == true }, "\(id)")
        }
    }

    func testTheMenusNewTerminalOnAtlasRequestsTheHeadlessStart() throws {
        let manager = WorkspaceManager()
        let before = Set(manager.selectedWorkspace?.panels.keys.map { $0 } ?? [])
        manager.newSurface(onMachine: "studio")
        let created = try XCTUnwrap(manager.selectedWorkspace).panels.keys.filter { !before.contains($0) }
        XCTAssertEqual(created.count, 1)
        XCTAssertTrue(created.allSatisfy { id in requests.contains { $0.0 == id } })
    }
}

/// The lifecycle, driven through the production start/handoff/reconnect code with a fake hc session: what the
/// panel creates, when, how many times, and what retires. Only the Ghostty-dependent part of the start
/// (`TerminalSurface.headlessStartSink`) is replaced.
@MainActor
final class HCHeadlessLifecycleTests: XCTestCase {
    private var starts: [(UUID, HCNativeBridge)] = []
    private var gateWasOpen = false
    private var savedGrace: UInt64 = 0
    private var savedLiveWait: TimeInterval = 0
    private let studio = HCRemoteTarget(machine: "studio", cwd: "/work")
    private let key = HCTerminalKey(owningCoreID: "c", localAddress: "t1")

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        starts = []
        gateWasOpen = HCBackendComposition.shared.isInitialRestoreReady
        HCBackendComposition.shared.setInitialRestoreReady(false)
        savedGrace = HCHeadless.graceNanoseconds
        savedLiveWait = HCHeadless.restoredLiveWaitSeconds
        TerminalSurface.headlessStartSink = { [unowned self] surface, bridge in self.starts.append((surface.id, bridge)) }
    }

    override func tearDown() {
        TerminalSurface.headlessStartSink = nil
        HCHeadless.graceNanoseconds = savedGrace
        HCHeadless.restoredLiveWaitSeconds = savedLiveWait
        HCBackendComposition.shared.setInitialRestoreReady(gateWasOpen)
        super.tearDown()
    }

    private func restoredPanel() throws -> (Workspace, TerminalPanel, HCPanelSession, UUID) {
        let id = UUID()
        let panel = SessionPanelSnapshot(id: id, type: .terminal, title: "Fixture", customTitle: nil,
            directory: "/fixture", isPinned: false, isManuallyUnread: false, gitBranch: nil, listeningPorts: [], ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: nil, scrollback: nil,
                hcIdentity: HCPanelIdentity(panelID: id, key: key), hcRemoteTarget: studio), browser: nil, markdown: nil)
        let snapshot = SessionWorkspaceSnapshot(id: UUID(), processTitle: "Fixture", customTitle: nil, customColor: nil,
            isPinned: false, currentDirectory: "/fixture", focusedPanelId: id,
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: [id], selectedPanelId: id)), panels: [panel],
            statusEntries: [], logEntries: [], progress: nil, gitBranch: nil)
        let workspace = Workspace(restoringSession: true)
        workspace.restoreSessionSnapshot(snapshot)
        let terminal = try XCTUnwrap(workspace.panels[id] as? TerminalPanel)
        return (workspace, terminal, try XCTUnwrap(terminal.hcSession), id)
    }

    private func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    private func waitUntil(_ condition: @MainActor () -> Bool, _ seconds: Double = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if condition() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    private func record() -> HCTerminalRecord { HCTerminalRecord(key: key, state: .running, labels: [:], pid: 7) }

    // MARK: when a headless start happens

    func testARestoredLivePanelStartsHeadlessOnlyAfterTheRestoreGateOpens() async throws {
        let (workspace, panel, runtime, id) = try restoredPanel()
        defer { workspace.retireForSessionRestore(); HCPanelRestoreState.shared.remove(panelID: id) }
        runtime.publish(.live(record()))
        panel.surface.requestHCHeadlessStart(restoring: true)
        await settle()
        XCTAssertTrue(starts.isEmpty, "nothing is created before the restore gate opens")
        HCBackendComposition.shared.setInitialRestoreReady(true)
        let started = await waitUntil { self.starts.count == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(starts.first?.0, id)
        XCTAssertNotNil(panel.surface.hcHeadlessBridge)
    }

    func testARestoredPanelThatIsNotLiveIsNeverStartedHeadless() async throws {
        let (workspace, panel, runtime, id) = try restoredPanel()
        defer { workspace.retireForSessionRestore(); HCPanelRestoreState.shared.remove(panelID: id) }
        _ = runtime       // never resolved to live: the restored identity has not been found in hc
        HCHeadless.restoredLiveWaitSeconds = 0.15
        panel.surface.requestHCHeadlessStart(restoring: true)
        HCBackendComposition.shared.setInitialRestoreReady(true)
        await settle(0.8)       // past the live-wait: it gave up, and still created nothing
        XCTAssertTrue(starts.isEmpty, "a restored terminal not known live keeps today's policy: nothing is created for it here")
        XCTAssertNil(panel.surface.hcHeadlessBridge)
    }

    func testARestoredPanelStillStartsWhenLivenessArrivesAfterTheInitialWait() async throws {
        let (workspace, panel, runtime, id) = try restoredPanel()
        defer { workspace.retireForSessionRestore(); HCPanelRestoreState.shared.remove(panelID: id) }
        HCHeadless.restoredLiveWaitSeconds = 0.05
        var outcomes: [String] = []
        runtime.diagnosticSink = { event in
            if case .attachmentProgress(_, "headless", let outcome, _) = event { outcomes.append(outcome) }
        }
        panel.surface.requestHCHeadlessStart(restoring: true)
        panel.surface.requestHCHeadlessStart(restoring: true)
        HCBackendComposition.shared.setInitialRestoreReady(true)
        await settle(0.2)
        XCTAssertTrue(starts.isEmpty)
        runtime.publish(.live(record()))
        let started = await waitUntil { self.starts.count == 1 }
        XCTAssertTrue(started, "a slow inventory must not leave a restored terminal without an attachment")
        panel.surface.requestHCHeadlessStart(restoring: true)
        await settle(0.1)
        XCTAssertEqual(starts.count, 1, "one restored terminal gets one bridge")
        XCTAssertEqual(outcomes.filter { $0 == "live" }.count, 1, "duplicate requests share one subscription")
    }

    func testALiveNotificationSupersededByAnEndCannotStartAHeadlessTerminal() async throws {
        let (workspace, panel, runtime, id) = try restoredPanel()
        defer { workspace.retireForSessionRestore(); HCPanelRestoreState.shared.remove(panelID: id) }
        panel.surface.requestHCHeadlessStart(restoring: true)
        HCBackendComposition.shared.setInitialRestoreReady(true)
        await settle(0.1)
        runtime.publish(.live(record()))
        runtime.publish(.ended(HCEndEvidence(id: UUID(), key: key,
            revision: HCRevision(connectionGeneration: 1, sequence: 2), kind: .finished)))
        await settle(0.2)
        XCTAssertTrue(starts.isEmpty, "a queued @Published notification must not restart a terminal that ended")
    }

    func testANewPanelStartsAfterTheGraceAndTheGateButNotIfASurfaceAppearsFirst() async throws {
        HCHeadless.graceNanoseconds = 40_000_000
        let (workspace, panel, runtime, id) = try restoredPanel()
        defer { workspace.retireForSessionRestore(); HCPanelRestoreState.shared.remove(panelID: id) }
        runtime.publish(.live(record()))
        panel.surface.requestHCHeadlessStart(restoring: false)
        XCTAssertTrue(starts.isEmpty, "not before the grace")
        await settle(0.25)
        XCTAssertTrue(starts.isEmpty, "the grace passed but the restore gate is closed")
        HCBackendComposition.shared.setInitialRestoreReady(true)
        let started = await waitUntil { self.starts.count == 1 }
        XCTAssertTrue(started)
        // A second panel whose surface appears inside the grace is never started headless.
        let (workspace2, panel2, runtime2, id2) = try restoredPanel()
        defer { workspace2.retireForSessionRestore(); HCPanelRestoreState.shared.remove(panelID: id2) }
        runtime2.publish(.live(record()))
        let before = starts.count
        panel2.surface.requestHCHeadlessStart(restoring: false)
        panel2.surface.installFakeNativeSurfaceForTesting(UnsafeMutableRawPointer(bitPattern: 0x10))
        await settle(0.25)
        panel2.surface.installFakeNativeSurfaceForTesting(nil)
        XCTAssertEqual(starts.count, before, "a surface that exists first is the panel's terminal")
    }

    // MARK: handoff and reconnect keep one terminal and one attachment

    private func attachedHeadless() async throws -> (LifecycleSession, HCPanelSession, HCNativeBridge, any HCAttachment, TerminalPanel, Workspace, UUID) {
        let session = LifecycleSession(key: key)
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let id = panel.id          // the runtime and its bridges belong to this panel, as in production
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: id, origin: .fresh), session: session)
        let launch = HCPanelLaunchSpec(argv: ["/bin/sh"], cwd: nil, environment: [:], initialInput: nil)
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCHeadless.grid, facts: HCDisplayFacts(), focused: false)
        let headless = HCNativeBridge.headless(panelID: id, report: { _ in })
        let first = try await runtime.attachSurface(launch: launch, bridge: headless, display: display)
        panel.surface.installHCSessionForTesting(runtime)
        panel.surface.setHeadlessBridgeForTesting(headless)
        panel.surface.setLaunchSpecForTesting(launch)
        return (session, runtime, headless, first, panel, workspace, id)
    }

    func testAHandoffRetiresTheHeadlessAttachmentAndTheNextAttachCreatesNothing() async throws {
        let (session, runtime, _, first, panel, workspace, id) = try await attachedHeadless()
        defer { HCPanelRestoreState.shared.remove(panelID: id); withExtendedLifetime(workspace) {} }
        XCTAssertEqual(session.creates, 1)
        XCTAssertTrue(runtime.attachment === first)
        let real = HCNativeBridge.headless(panelID: id, report: { _ in })      // stands in for the native bridge
        panel.surface.handOffHeadlessHC(to: real)
        XCTAssertNil(runtime.attachment, "the old attachment is retired before the new surface attaches")
        XCTAssertNil(panel.surface.hcHeadlessBridge)
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCGridSize(columns: 132, rows: 40), facts: HCDisplayFacts(), focused: true)
        let second = try await runtime.attachSurface(launch: HCPanelLaunchSpec(argv: ["/bin/sh"], cwd: nil, environment: [:],
            initialInput: nil), bridge: real, display: display)
        XCTAssertEqual(session.creates, 1, "exactly one creation through the handoff")
        XCTAssertEqual(session.writers.count, 2)
        XCTAssertFalse(first === second)
        XCTAssertTrue(runtime.attachment === second)
        // Input goes to the current attachment once, and never to the retired one.
        let request = { (generation: UInt64) in HCInputRequest(operationID: UUID(), panelID: id, key: self.key,
            attachmentGeneration: generation, source: .socket, payload: Data("ls".utf8), submitReturn: true) }
        let stale = await first.submit(request(first.generation))
        guard case .refused = stale else { return XCTFail("a retired attachment took input: \(stale)") }
        let current = await second.submit(request(second.generation))
        guard case .written = current else { return XCTFail("\(current)") }
        XCTAssertEqual(session.writers[0].received, Data())
        XCTAssertEqual(session.writers[1].received, Data("ls".utf8) + Data([13]))
    }

    func testReconnectWithNoGhosttySurfaceReplacesTheHeadlessAttachment() async throws {
        let (session, runtime, oldBridge, first, panel, workspace, id) = try await attachedHeadless()
        defer { HCPanelRestoreState.shared.remove(panelID: id); withExtendedLifetime(workspace) {} }
        XCTAssertNil(panel.surface.surface)
        let attached = try await panel.surface.recreateHCAttachment(record())
        XCTAssertEqual(session.creates, 1, "recovery reattaches the live terminal; it never creates a second")
        XCTAssertEqual(session.writers.count, 2)
        XCTAssertTrue(runtime.attachment === attached)
        XCTAssertFalse(first === attached)
        XCTAssertFalse(panel.surface.hcHeadlessBridge === oldBridge, "the dead headless bridge was replaced")
        XCTAssertNotNil(panel.surface.hcHeadlessBridge)
        let outcome = await attached.submit(HCInputRequest(operationID: UUID(), panelID: id, key: key,
            attachmentGeneration: attached.generation, source: .socket, payload: Data("pwd".utf8), submitReturn: true))
        guard case .written = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(session.writers[1].received, Data("pwd".utf8) + Data([13]))
        XCTAssertEqual(session.writers[0].received, Data())
    }
}

/// C11H-112 option (b): what a send to a terminal with no screen does, from hc's own status.
@MainActor
final class HCHeadlessSendDecisionTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "c", localAddress: "t1")

    private func record(status: String?, agent: Bool, state: HCTerminalState = .running,
                        availability: HCMachineAvailability = .local) -> HCTerminalRecord {
        HCTerminalRecord(key: key, state: state, labels: [:], machineAvailability: availability, pid: 7,
            foreground: HCForeground(name: agent ? "claude" : "zsh", argv: agent ? ["claude"] : ["zsh"]), status: status)
    }

    func testWithASurfaceTheScreenGuardIsUnchangedAndWithoutOneHCStatusDecides() {
        XCTAssertEqual(HCHeadless.sendRoute(hasSurface: true, hasHeadlessBridge: false), .screenGuard)
        XCTAssertEqual(HCHeadless.sendRoute(hasSurface: true, hasHeadlessBridge: true), .screenGuard)
        XCTAssertEqual(HCHeadless.sendRoute(hasSurface: false, hasHeadlessBridge: true), .statusDecision)
        XCTAssertEqual(HCHeadless.sendRoute(hasSurface: false, hasHeadlessBridge: false), .notHeadless)
    }

    func testAnIdleOrDoneAgentReceivesTheSend() {
        XCTAssertEqual(HCHeadless.sendDecision(record: record(status: "idle", agent: true), allowUnguarded: false), .deliver)
        XCTAssertEqual(HCHeadless.sendDecision(record: record(status: "done", agent: true), allowUnguarded: false), .deliver)
    }

    func testAWorkingAgentReceivesTheSend() {
        XCTAssertEqual(HCHeadless.sendDecision(record: record(status: "working", agent: true), allowUnguarded: false), .deliver)
    }

    func testABlockedAgentIsRefusedNamingTheStatusAndTheOverrideDelivers() {
        XCTAssertEqual(HCHeadless.sendDecision(record: record(status: "blocked", agent: true), allowUnguarded: false),
                       .refuse(status: "blocked"))
        XCTAssertEqual(HCHeadless.sendDecision(record: record(status: "blocked", agent: true), allowUnguarded: true), .deliver)
    }

    func testASendWhileADoorbellIsBetweenItsLineAndItsReturnIsBusyWhateverTheOverride() {
        let idle = record(status: "idle", agent: true)
        XCTAssertEqual(HCHeadless.sendDecision(record: idle, allowUnguarded: false, doorbellInFlight: true), .busy)
        XCTAssertEqual(HCHeadless.sendDecision(record: idle, allowUnguarded: true, doorbellInFlight: true), .busy)
        XCTAssertEqual(HCHeadless.sendDecision(record: idle, allowUnguarded: false, doorbellInFlight: false), .deliver)
    }

    func testAPlainShellReceivesTheSend() {
        XCTAssertEqual(HCHeadless.sendDecision(record: record(status: nil, agent: false), allowUnguarded: false), .deliver)
    }

    func testAnAgentWithUnknownOrStaleStatusFailsClosed() {
        XCTAssertEqual(HCHeadless.sendDecision(record: record(status: nil, agent: true), allowUnguarded: false),
                       .refuse(status: "no_current_status"), "an agent with no status yet")
        XCTAssertEqual(HCHeadless.sendDecision(record: record(status: "error", agent: true), allowUnguarded: false),
                       .refuse(status: "no_current_status"), "an unrecognised status")
        XCTAssertEqual(HCHeadless.sendDecision(record: record(status: "idle", agent: true, availability: .disconnected),
                                               allowUnguarded: false), .refuse(status: "no_current_status"),
                       "a record from a machine that is no longer connected is stale")
        XCTAssertEqual(HCHeadless.sendDecision(record: nil, allowUnguarded: false), .refuse(status: "no_current_status"))
        XCTAssertEqual(HCHeadless.sendDecision(record: record(status: nil, agent: true), allowUnguarded: true), .deliver,
                       "the explicit override lifts an unknown status")
    }

    /// C11H-298: hc keeps a program's last status until the terminal ends, so only an agent in hc's foreground
    /// makes a send wait for a turn. The guest run that found it: the line launching a program into a shell left
    /// by an exited agent came back `send_unconfirmed`.
    func testASendWaitsForAnAgentTurnOnlyWhenAnAgentHasTheTerminal() {
        func record(status: String?, name: String?, argv0: String? = nil) -> HCTerminalRecord {
            HCTerminalRecord(key: key, state: .running, labels: [:], machineAvailability: .local, pid: 7,
                foreground: name.map { HCForeground(name: $0, argv: [argv0 ?? $0]) }, status: status)
        }
        XCTAssertTrue(HCHeadless.sendTargetsAgent(record(status: "idle", name: "claude")))
        XCTAssertTrue(HCHeadless.sendTargetsAgent(record(status: "idle", name: "codex")))
        XCTAssertTrue(HCHeadless.sendTargetsAgent(record(status: "idle", name: "perl", argv0: "claude")),
                      "a harness a launcher names by argv[0]")
        XCTAssertFalse(HCHeadless.sendTargetsAgent(record(status: "idle", name: "zsh")), "a stale status under a shell")
        XCTAssertFalse(HCHeadless.sendTargetsAgent(record(status: "idle", name: "vim")), "under an editor")
        XCTAssertFalse(HCHeadless.sendTargetsAgent(record(status: "idle", name: "python3")), "under a REPL")
        XCTAssertFalse(HCHeadless.sendTargetsAgent(record(status: "idle", name: nil)))
    }

    func testATerminalThatIsNotRunningIsNeverSentTo() {
        XCTAssertEqual(HCHeadless.sendDecision(record: record(status: "idle", agent: true, state: .finished), allowUnguarded: true),
                       .refuse(status: "not_running"))
    }

    func testEachRefusedSendWritesOneDiagnosticsLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hc-headless-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hc-diagnostics.log")
        let recorder = HCDiagnosticRecorder(logFile: file, counterFile: directory.appendingPathComponent("counter"))
        let panel = UUID(), caller = UUID()
        recorder.recordHeadlessSendRefused(panelID: panel, terminal: "t7", status: "blocked", callerPanelID: caller)
        recorder.recordHeadlessSendRefused(panelID: panel, terminal: "t7", status: "blocked", callerPanelID: caller)
        recorder.recordHeadlessSendRefused(panelID: panel, terminal: "t7", status: "typed secret text", callerPanelID: caller)
        let lines = try String(contentsOf: file).split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "one line per refused send; an unknown status token is never written")
        let line = String(lines[0])
        for needle in ["event=headless_send_refused", "panel_id=\(panel.uuidString)", "terminal=t7", "status=blocked", "caller=\(caller.uuidString)"] {
            XCTAssertTrue(line.contains(needle), "\(needle) in \(line)")
        }
    }
}

/// C11H-116: a launch on a terminal with no Ghostty surface keeps its command and prompt, delivers the prompt
/// only when hc says the agent is at its prompt, fails visibly otherwise, and is not made twice.
@MainActor
final class HCHeadlessLaunchTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "c", localAddress: "t1")

    private func record(status: String?, state: HCTerminalState = .running) -> HCTerminalRecord {
        HCTerminalRecord(key: key, state: state, labels: [:], pid: 7, status: status)
    }

    func testReadinessComesFromHCsAgentStatus() {
        XCTAssertEqual(HCHeadless.promptReadiness(record(status: "idle")), .ready)
        XCTAssertEqual(HCHeadless.promptReadiness(record(status: "done")), .ready)
        XCTAssertEqual(HCHeadless.promptReadiness(record(status: "blocked")), .blocked)
        XCTAssertEqual(HCHeadless.promptReadiness(record(status: "working")), .waiting)
        XCTAssertEqual(HCHeadless.promptReadiness(record(status: nil)), .waiting, "a plain shell reports no status")
        XCTAssertEqual(HCHeadless.promptReadiness(record(status: "idle", state: .finished)), .waiting)
        XCTAssertEqual(HCHeadless.promptReadiness(nil), .waiting)
    }

    private struct Run {
        var submitted: [String] = []
        var failures: [String] = []
        var finished = false
        var polls = 0
    }

    /// Drives the real LaunchPostBootSequence with an explicit clock: every scheduled retry runs in order.
    private func run(readiness: @escaping (Int) -> HCAgentReadiness?, dialog: Bool = false) -> Run {
        var out = Run()
        var queue: [@MainActor () -> Void] = []
        let sequence = LaunchPostBootSequence(
            launcher: "claude --model x", prompt: "do the task", isLive: { true }, isReady: { true },
            submit: { text, done in out.submitted.append(text); done(true) },
            isBlockedByDialog: { dialog },
            headlessReadiness: { out.polls += 1; return readiness(out.polls) },
            onFailure: { out.failures.append($0) }, onFinished: { out.finished = true },
            schedule: { _, work in queue.append(work) })
        sequence.start()
        var steps = 0
        while !queue.isEmpty, steps < 5000 { queue.removeFirst()(); steps += 1 }
        return out
    }

    func testTheLauncherLineAndThePromptBothReachAHeadlessAgentOnceItIsAtItsPrompt() {
        let out = run(readiness: { $0 >= 4 ? .ready : .waiting })
        XCTAssertEqual(out.submitted, ["claude --model x", "do the task"], "the full argv, then the prompt")
        XCTAssertTrue(out.failures.isEmpty)
        XCTAssertTrue(out.finished)
    }

    func testABlockedAgentGetsNoPromptAndTheLaunchFailsWithTheReason() {
        let out = run(readiness: { $0 >= 3 ? .blocked : .waiting })
        XCTAssertEqual(out.submitted, ["claude --model x"], "the prompt is never typed into a dialog")
        XCTAssertEqual(out.failures, ["blocked"])
        XCTAssertTrue(out.finished)
    }

    func testAnAgentThatNeverReachesItsPromptFailsTheLaunchAtTheDeadline() {
        let out = run(readiness: { _ in .waiting })
        XCTAssertEqual(out.submitted, ["claude --model x"])
        XCTAssertEqual(out.failures, ["timeout"])
        XCTAssertEqual(out.polls, LaunchPostBootSequence.maxHeadlessWaits + 1)
    }

    func testWithASurfaceTheScreenPathIsUnchanged() {
        // headlessReadiness nil: the dialog check holds the prompt, and past its limit drops it as before.
        let out = run(readiness: { _ in nil }, dialog: true)
        XCTAssertEqual(out.submitted, ["claude --model x"])
        XCTAssertTrue(out.failures.isEmpty)
        XCTAssertTrue(out.finished)
    }

    // MARK: argv and prompt through hc

    private func headlessPanel(encoder: any HCInputEncoder = HCHeadlessInputEncoder()) async throws
        -> (LifecycleSession, TerminalPanel, Workspace, UUID) {
        let session = LifecycleSession(key: key)
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel.id, origin: .fresh), session: session)
        runtime.installReconnectPolicy()          // as HCBackendComposition.prepare does for every panel runtime
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCHeadless.grid, facts: HCDisplayFacts(), focused: false)
        let bridge = HCNativeBridge.headless(panelID: panel.id, report: { _ in }, encoder: encoder)
        _ = try await runtime.attachSurface(launch: HCPanelLaunchSpec(argv: ["/bin/sh"], cwd: nil, environment: [:], initialInput: nil),
                                            bridge: bridge, display: display)
        panel.surface.installHCSessionForTesting(runtime)
        panel.surface.setHeadlessBridgeForTesting(bridge)
        return (session, panel, workspace, panel.id)
    }

    private func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline { if condition() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    func testTheLaunchLineAndThePromptAreTypedIntoTheHeadlessTerminalThroughHC() async throws {
        let (session, panel, workspace, id) = try await headlessPanel()
        defer { HCPanelRestoreState.shared.remove(panelID: id); withExtendedLifetime(workspace) {} }
        panel.surface.sendSubmitFormText("claude --model x")
        let line = await wait { session.writers[0].received == Data("claude --model x".utf8) + Data([13]) }
        XCTAssertTrue(line, "the launch line reaches the terminal through hc: \(session.writers[0].received)")
        var delivered: Bool?
        panel.surface.sendSubmitFormText("do the task", shouldSubmit: { true }, completion: { delivered = $0 })
        let prompt = await wait { delivered == true }
        XCTAssertTrue(prompt, "the prompt is delivered through hc with no surface")
        XCTAssertTrue(String(decoding: session.writers[0].received, as: UTF8.self).hasSuffix("do the task\r"))
    }

    /// C11H-362: a drop onto an hc terminal is a paste whatever it holds. A dropped path with a Tab (escaped, as
    /// drops are) goes through Ghostty's paste encoder, fenced, and never through the key encoder.
    func testADropReachesTheTerminalAsAPasteNeverAsKeys() async throws {
        let recorder = HCControlTextTests.Recorder()
        let (session, panel, workspace, id) = try await headlessPanel(
            encoder: HCControlTextTests.ghosttyEncoder(bracketed: true, recorder: recorder))
        defer { HCPanelRestoreState.shared.remove(panelID: id); withExtendedLifetime(workspace) {} }
        XCTAssertTrue(panel.hostedView.debugSimulateFileDrop(paths: ["/tmp/c11 drop\tnext"]))
        let pasted = await wait { !session.writers[0].received.isEmpty }
        XCTAssertTrue(pasted, "the drop reached the terminal")
        XCTAssertEqual(recorder.keyCalls, 0, "a drop is never typed as keys")
        XCTAssertEqual(recorder.pasteCalls, 1)
        XCTAssertEqual(session.writers[0].received, Data("\u{1b}[200~/tmp/c11\\ drop\\\tnext\u{1b}[201~".utf8))
    }

    func testAHeadlessTerminalsInputGenerationStaysCurrent() async throws {
        let (_, panel, workspace, id) = try await headlessPanel()
        defer { HCPanelRestoreState.shared.remove(panelID: id); withExtendedLifetime(workspace) {} }
        let stamp = panel.surface.captureInputGeneration()
        XCTAssertTrue(panel.surface.isInputGenerationCurrent(stamp), "the launch sequence's generation check needs no surface")
    }

    // MARK: production wiring: TerminalPanel.submitLaunchPlan

    private func publishStatus(_ session: LifecycleSession, _ status: String?) async {
        session.setStatus(status)
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    func testALaunchStaysPendingUntilItsLauncherLineIsDelivered() async throws {
        let session = LifecycleSession(key: key)
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel.id, origin: .fresh), session: session)
        runtime.installReconnectPolicy()
        panel.surface.installHCSessionForTesting(runtime)
        TerminalSurface.headlessStartSink = { _, _ in }
        defer { TerminalSurface.headlessStartSink = nil; HCPanelRestoreState.shared.remove(panelID: panel.id); withExtendedLifetime(workspace) {} }
        panel.launchKey = "k"
        panel.submitLaunchPlan(LaunchPromptDelivery.Plan(launchLine: "claude --x", delayedPrompt: nil),
                               isLive: { true }, requestBackgroundStart: false)
        XCTAssertTrue(panel.isLaunchPending, "queued before the terminal exists: still pending")
        XCTAssertTrue(workspace.pendingLaunchPanel(forKey: "k") === panel, "a retry now finds this panel, not a second agent")
        // The terminal comes up (headless) and the queued launcher is delivered once.
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCHeadless.grid, facts: HCDisplayFacts(), focused: false)
        let bridge = HCNativeBridge.headless(panelID: panel.id, report: { _ in })
        _ = try await runtime.attachSurface(launch: HCPanelLaunchSpec(argv: ["/bin/sh"], cwd: nil, environment: [:], initialInput: nil),
                                            bridge: bridge, display: display)
        panel.surface.setHeadlessBridgeForTesting(bridge)
        panel.surface.drainHCPendingInputForTesting()
        let delivered = await wait { session.writers.first?.received == Data("claude --x".utf8) + Data([13]) }
        XCTAssertTrue(delivered, "one launcher delivery: \(String(describing: session.writers.first?.received))")
        let settled = await wait { !panel.isLaunchPending }
        XCTAssertTrue(settled, "delivered: no longer pending")
        XCTAssertNil(workspace.pendingLaunchPanel(forKey: "k"))
    }

    /// C11H-218 (`launch-agent --on studio`, 13:54 on 2026-11-05): the launcher is held for the terminal's first
    /// bind, and a surface start moves the input generation while the start's attach is in flight. The attach
    /// that lands bound still types the launcher once, and the panel takes input afterwards.
    func testAHeldLauncherIsDeliveredWhenASurfaceStartMovesTheGenerationDuringTheAttach() async throws {
        let session = LifecycleSession(key: key)
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel.id, origin: .fresh), session: session)
        runtime.installReconnectPolicy()
        panel.surface.installHCSessionForTesting(runtime)
        TerminalSurface.headlessStartSink = { _, _ in }
        defer { TerminalSurface.headlessStartSink = nil; HCPanelRestoreState.shared.remove(panelID: panel.id); withExtendedLifetime(workspace) {} }
        panel.launchKey = "k"
        panel.submitLaunchPlan(LaunchPromptDelivery.Plan(launchLine: "claude --x", delayedPrompt: nil),
                               isLive: { true }, requestBackgroundStart: false)
        XCTAssertTrue(panel.isLaunchPending, "held for the first bind")
        // The headless start begins its attach at this generation.
        let bridge = HCNativeBridge.headless(panelID: panel.id, report: { _ in })
        panel.surface.setHeadlessBridgeForTesting(bridge)
        let startGeneration = panel.surface.nativeInputGenerationForTesting
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCHeadless.grid, facts: HCDisplayFacts(), focused: false)
        let attachment = try await runtime.attachSurface(launch: HCPanelLaunchSpec(argv: ["/bin/sh"], cwd: nil, environment: [:], initialInput: nil),
                                                         bridge: bridge, display: display)
        // Meanwhile a surface start moved the generation (createSurface does, before it can park or fail).
        // This models the parked or failed createSurface case; a full hand-off detaches the attachment instead.
        // tryStartHCSession calls finishHCStart with the generation it started at, as this test does.
        panel.surface.replaceNativeSurfaceForTesting()
        XCTAssertNotEqual(panel.surface.nativeInputGenerationForTesting, startGeneration)
        panel.surface.finishHCStart(runtime: runtime, attachment: attachment, generation: startGeneration)
        let delivered = await wait { session.writers.first?.received == Data("claude --x".utf8) + Data([13]) }
        XCTAssertTrue(delivered, "the bound terminal gets the launcher once: \(String(describing: session.writers.first?.received))")
        let settled = await wait { !panel.isLaunchPending }
        XCTAssertTrue(settled, "delivered: no longer pending")
        XCTAssertNil(workspace.pendingLaunchPanel(forKey: "k"))
        // Nothing is left holding the panel's input: a later send goes through.
        let after = await panel.surface.submitHCInput("echo ok", submit: true, source: .socket, waitSeconds: 1)
        guard case .written = after else { return XCTFail("a later send is refused: \(after)") }
    }

    func testTheHeadlessPromptWaitsForHCStatusIdleAndNeverGoesToAWorkingOrBlockedAgent() async throws {
        LaunchPostBootSequence.promptDelay = 0.05
        LaunchPostBootSequence.headlessRecheck = 0.05
        defer { LaunchPostBootSequence.promptDelay = 2.5; LaunchPostBootSequence.headlessRecheck = 0.5 }
        let (session, panel, workspace, id) = try await headlessPanel()
        defer { HCPanelRestoreState.shared.remove(panelID: id); withExtendedLifetime(workspace) {} }
        await publishStatus(session, "working")
        panel.submitLaunchPlan(LaunchPromptDelivery.Plan(launchLine: "claude", delayedPrompt: "do it"),
                               isLive: { true }, requestBackgroundStart: false)
        let launcher = await wait { session.writers[0].received == Data("claude".utf8) + Data([13]) }
        XCTAssertTrue(launcher)
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(session.writers[0].received, Data("claude".utf8) + Data([13]), "a working agent gets no prompt yet")
        await publishStatus(session, "idle")
        let prompt = await wait { String(decoding: session.writers[0].received, as: UTF8.self).hasSuffix("do it\r") }
        XCTAssertTrue(prompt, "idle at its prompt: the prompt is delivered through hc")
        let finished = await wait { !panel.isLaunchPending }
        XCTAssertTrue(finished)
    }

    func testAnAgentBlockedOnADialogFailsTheLaunchVisiblyAndNeverReceivesThePrompt() async throws {
        LaunchPostBootSequence.promptDelay = 0.05
        LaunchPostBootSequence.headlessRecheck = 0.05
        defer { LaunchPostBootSequence.promptDelay = 2.5; LaunchPostBootSequence.headlessRecheck = 0.5 }
        var failures: [String] = []
        TerminalPanel.launchFailureSink = { _, reason in failures.append(reason) }
        defer { TerminalPanel.launchFailureSink = nil }
        let (session, panel, workspace, id) = try await headlessPanel()
        defer { HCPanelRestoreState.shared.remove(panelID: id); withExtendedLifetime(workspace) {} }
        await publishStatus(session, "blocked")
        panel.submitLaunchPlan(LaunchPromptDelivery.Plan(launchLine: "claude", delayedPrompt: "do it"),
                               isLive: { true }, requestBackgroundStart: false)
        let failed = await wait { !failures.isEmpty }
        XCTAssertTrue(failed, "the launch fails visibly")
        XCTAssertEqual(failures, ["blocked"])
        XCTAssertEqual(session.writers[0].received, Data("claude".utf8) + Data([13]), "nothing typed into the dialog")
        XCTAssertFalse(panel.isLaunchPending, "a failed launch is no longer pending")
    }

    func testTwoLaunchesAreTheSameOnlyWhenEverythingThatShapesThemMatches() {
        let ws = UUID()
        func request(task: String = "t", prompt: String = "p", env: [String: String] = [:], override: String? = nil,
                     model: String? = nil) -> AgentLaunchRequest {
            AgentLaunchRequest(kind: "claude", model: model, effort: nil, task: task, prompt: prompt, systemPrompt: nil,
                               extraEnv: env, commandOverride: override)
        }
        func key(_ r: AgentLaunchRequest, cwd: String? = "/work/a", machine: String = "studio", workspace: UUID? = nil) -> String {
            LaunchIdentity.key(workspaceID: workspace ?? ws, machine: machine, request: r, cwd: cwd)
        }
        let base = key(request())
        XCTAssertEqual(base, key(request()), "an identical retry is the same launch")
        XCTAssertNotEqual(base, key(request(), cwd: "/work/b"), "another worktree is another launch")
        XCTAssertNotEqual(base, key(request(env: ["A": "1"])), "another environment")
        XCTAssertNotEqual(base, key(request(override: "claude --other")), "another command recipe")
        XCTAssertNotEqual(base, key(request(prompt: "q")), "another prompt")
        XCTAssertNotEqual(base, key(request(task: "u")), "another task")
        XCTAssertNotEqual(base, key(request(model: "m")), "another model")
        XCTAssertNotEqual(base, key(request(), machine: "local"), "another machine")
        XCTAssertNotEqual(base, key(request(), workspace: UUID()), "another workspace")
    }

    // MARK: a retry while pending is the same launch

    func testAPendingLaunchIsFoundByItsKeyAndOnlyWhilePending() throws {
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        XCTAssertNil(workspace.pendingLaunchPanel(forKey: "k"))
        panel.launchKey = "k"
        panel.isLaunchPending = true
        XCTAssertTrue(workspace.pendingLaunchPanel(forKey: "k") === panel, "a retry finds the pending launch")
        XCTAssertNil(workspace.pendingLaunchPanel(forKey: "other"), "a different launch is not deduplicated")
        panel.isLaunchPending = false
        XCTAssertNil(workspace.pendingLaunchPanel(forKey: "k"), "a finished launch can be launched again")
        panel.isLaunchPending = true
        panel.reportLaunchPromptNotDelivered(reason: "blocked")
        XCTAssertNil(workspace.pendingLaunchPanel(forKey: "k"), "a failed launch is no longer pending")
        panel.isLaunchPending = true
        _ = workspace.closePanel(panel.id, force: true)
        XCTAssertNil(workspace.pendingLaunchPanel(forKey: "k"), "a closed panel is not a pending launch")
    }
}

private final class LifecycleSession: HCSession, @unchecked Sendable {
    let feed = HCSessionFeed()
    private let unavailable = HCUnavailableRuntime()
    private let lock = NSLock()
    private let key: HCTerminalKey
    private var made = 0
    private var live: HCTerminalRecord?
    private var all: [HeadlessWriter] = []
    init(key: HCTerminalKey) { self.key = key }
    var creates: Int { lock.lock(); defer { lock.unlock() }; return made }
    var writers: [HeadlessWriter] { lock.lock(); defer { lock.unlock() }; return all }
    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        feed.observe(on: queue, handler: handler)
    }
    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle {
        lock.lock(); defer { lock.unlock() }
        return live.map { .live($0) } ?? .new
    }
    func create(_ request: HCCreateRequest) async -> HCCreateResult {
        lock.lock(); defer { lock.unlock() }
        made += 1
        let record = HCTerminalRecord(key: key, state: .running, labels: [:], pid: 7,
            foreground: HCForeground(name: "claude", argv: ["claude"]), status: "idle")
        live = record
        publishLocked(record)
        return .bound(record)
    }

    private var sequence: UInt64 = 0
    private func publishLocked(_ record: HCTerminalRecord) {
        // hc's inventory lists the terminal, as it does for a live one: the reconnect owner must not conclude a loss.
        sequence += 1
        let revision = HCRevision(connectionGeneration: 1, sequence: sequence)
        let build = HCBuildIdentity(pin: .current, executablePath: "/owned/hc",
            fileIdentity: HCFileIdentity(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 5),
            process: HCProcessIdentity(pid: 42, startTimeMicroseconds: 6), coreID: key.owningCoreID, protocolGeneration: 1)
        feed.publish(HCInventorySnapshot(readiness: .ready(revision), revision: revision, records: [key: record],
                                         buildIdentity: build))
    }

    /// hc reports a new agent status for the terminal (OSC 7501), through the same inventory feed.
    func setStatus(_ status: String?) {
        lock.lock(); defer { lock.unlock() }
        let record = HCTerminalRecord(key: key, state: .running, labels: [:], pid: 7,
            foreground: HCForeground(name: "claude", argv: ["claude"]), status: status)
        live = record
        publishLocked(record)
    }
    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        let writer = HeadlessWriter()
        lock.lock(); all.append(writer); let generation = UInt64(all.count); lock.unlock()
        let prepared = try await HCBackendComposition.prepareAttachment(key: key, generation: generation, sink: sink, proposedDisplay: display)
        let attachment = try await HCBackendComposition.makeAttachment(key: key, generation: generation,
            channel: HeadlessChannel(writer), sink: sink, display: prepared)
        (attachment as? HCPanelAttachment)?.setAdmission(true)
        return attachment
    }
    func end(_ key: HCTerminalKey) async -> HCEndResult { await unavailable.end(key) }
    func diagnostics() async -> HCDiagnostics { await unavailable.diagnostics() }
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { await unavailable.recoverSession(reason: reason) }
}

private final class HeadlessWriter: HCFrameWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var pause: (@Sendable () async -> Void)?
    var received: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    private var returned: (@Sendable () async -> Void)?
    private var body: (@Sendable () async -> Void)?
    private var checking: (@Sendable (_ before: Bool) -> Void)?
    private var refusing: HCInputRefusal?
    /// C11H-327: every write is refused before its first byte, as a port that stays shut refuses it.
    func refuseWrites(_ refusal: HCInputRefusal?) { lock.lock(); refusing = refusal; lock.unlock() }
    /// C11H-306: runs once a write that carries no Return has put its text out (the doorbell line, before the read
    /// that must find it in the composer).
    func afterBody(_ hook: (@Sendable () async -> Void)?) { lock.lock(); body = hook; lock.unlock() }
    /// C11H-306: told just before and just after a Return's check runs.
    func aroundReturnCheck(_ spy: (@Sendable (_ before: Bool) -> Void)?) { lock.lock(); checking = spy; lock.unlock() }
    /// C11H-304: runs after the body is out and before the Return's check, as a slow settle would allow.
    func pauseBeforeReturn(_ hook: (@Sendable () async -> Void)?) { lock.lock(); pause = hook; lock.unlock() }
    /// C11H-306: runs once a Return is out, as the agent's turn would start.
    func afterReturn(_ hook: (@Sendable () async -> Void)?) { lock.lock(); returned = hook; lock.unlock() }
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome {
        lock.lock(); let refusal = refusing; lock.unlock()
        if let refusal { return .refused(refusal) }
        return .reserved(HCWriteReservation(id: UUID(), operationID: operationID, attachmentGeneration: attachmentGeneration,
                                            connectionGeneration: 1, encodedByteCount: encodedByteCount))
    }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome {
        var body = 0, returned = false
        for frame in batch.frames {
            switch frame {
            case .data(let data): lock.lock(); bytes.append(data); lock.unlock(); body += data.count
            case .submitReturn(let data), .submitReturnAfter(let data, delayNanoseconds: _):
                lock.lock(); let hook = pause; lock.unlock()
                if let hook { await hook() }
                // As HCControlWriter: the Return waits for beforeReturn; a no after the body is uncertain.
                lock.lock(); let spy = checking; lock.unlock()
                spy?(true)
                let allowed = await (batch.beforeReturn?() ?? true)
                spy?(false)
                if !allowed {
                    let receipt = HCWriteReceipt(operationID: batch.operationID, attachmentGeneration: batch.attachmentGeneration,
                                                 bodyBytesWritten: body, returnWritten: false)
                    return body == 0 ? .refused(.unavailable) : .uncertain(receipt)
                }
                lock.lock(); bytes.append(data); let after = self.returned; lock.unlock(); returned = true
                if let after { await after() }
            default: break
            }
        }
        if body > 0 && !returned {
            lock.lock(); let hook = self.body; lock.unlock()
            if let hook { await hook() }
        }
        return .written(HCWriteReceipt(operationID: batch.operationID, attachmentGeneration: batch.attachmentGeneration,
                                       bodyBytesWritten: body, returnWritten: returned))
    }
    func cancel(_ reservation: HCWriteReservation) {}
    func control(_ control: HCControl) async -> HCControlOutcome { .written }
}

private final class HeadlessChannel: HCChannel, @unchecked Sendable {
    let channelID: UInt32 = 1
    let connectionGeneration: UInt64 = 1
    private let writer: HeadlessWriter
    init(_ writer: HeadlessWriter) { self.writer = writer }
    func activate() async throws {}
    func close() {}
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome {
        writer.reserve(operationID: operationID, attachmentGeneration: attachmentGeneration, encodedByteCount: encodedByteCount)
    }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome {
        await writer.write(batch, reservation: reservation)
    }
    func cancel(_ reservation: HCWriteReservation) { writer.cancel(reservation) }
    func control(_ control: HCControl) async -> HCControlOutcome { .written }
}

/// C11H-160: a holder loss in a workspace nobody is looking at. The panel's runtime goes through a real
/// `HCShardPool` route to a pool shard; its terminal ends `holder_lost` there, and the mid-session replacement
/// is created in that same shard with no window, at once. Startup's own resolution still waits to be shown.
@MainActor
final class HCHiddenHolderLossReplacementTests: XCTestCase {
    func testAHiddenPanelsHolderLostTerminalIsReplacedInItsShardWithoutBeingShown() async throws {
        _ = NSApplication.shared
        let home = URL(fileURLWithPath: "/Users/tester")      // as HCShardPoolTests: configuration paths only, nothing on disk
        let fakes = (0...1).map { PoolShardFake(index: $0) }
        let shards = try fakes.map { fake in
            HCShard(index: fake.index, configuration: try HCLaunchPolicy.configuration(home: home, tag: nil, shard: fake.index,
                inherited: [:]), session: fake, intents: nil)
        }
        let pool = HCShardPool(shards: shards, placement: HCShardPlacement())
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let id = panel.id
        defer { HCPanelRestoreState.shared.remove(panelID: id); withExtendedLifetime(workspace) {} }
        let target = try XCTUnwrap(pool.creationTarget(panelID: id, workspaceID: workspace.id, machine: nil))
        XCTAssertEqual(target.index, 1)
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: id, origin: .fresh), session: pool.route(panelID: id))
        runtime.installReconnectPolicy()      // as production composition does for every runtime (input goes through it)
        var launch = HCPanelLaunchSpec(argv: ["/bin/sh"], cwd: nil, environment: [:], initialInput: nil, workspaceID: workspace.id)
        launch.shard = target.id
        let headless = HCNativeBridge.headless(panelID: id, report: { _ in })
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCHeadless.grid, facts: HCDisplayFacts(), focused: false)
        do { _ = try await runtime.attachSurface(launch: launch, bridge: headless, display: display) }
        catch { return XCTFail("the first creation threw \(error)") }
        panel.surface.installHCSessionForTesting(runtime)
        panel.surface.setHeadlessBridgeForTesting(headless)
        panel.surface.setLaunchSpecForTesting(launch)
        guard case .live(let first) = runtime.lifecycle else { return XCTFail("live after creation: \(runtime.lifecycle)") }
        XCTAssertEqual(first.key.owningCoreID, "core-1")

        // The shard's holder dies: hc's event reaches the panel through the pool, with no socket call.
        fakes[1].finish(first.key, reason: "holder_lost")
        let ended = await waitUntil { if case .ended = runtime.lifecycle { return true }; return false }
        XCTAssertTrue(ended, "the holder loss is noticed from the shard's own event: \(runtime.lifecycle)")

        // Startup's rule is unchanged: a hidden panel's end waits for the panel to be shown.
        do { try await panel.surface.replaceEndedHCWithShell(evenWhenHidden: false); XCTFail("startup replaced a hidden panel") }
        catch { XCTAssertEqual(error as? HCUnavailableReason, .cancelled) }
        XCTAssertEqual(fakes[1].creates, 1)

        // A mid-session end is replaced now, in its own shard, still with no window shown to anyone.
        do { try await panel.surface.replaceEndedHCWithShell(evenWhenHidden: true) }
        catch { return XCTFail("the hidden replacement threw \(error)") }
        XCTAssertEqual(fakes[1].creates, 2, "one replacement, in the shard that lost its holder")
        XCTAssertEqual(fakes[0].creates, 0, "never shard 0")
        guard case .live(let replacement) = runtime.lifecycle else { return XCTFail("replaced: \(runtime.lifecycle)") }
        XCTAssertEqual(replacement.key.owningCoreID, "core-1")
        XCTAssertNotEqual(replacement.key, first.key)

        // C11H-167: the conversation resume reaches the headless replacement at once. A headless terminal never
        // returns a screen receipt, so the screen-guarded route is refused there (the bug); the resume route
        // decides from hc's status instead (a plain shell takes it) and writes the command and its Return.
        let attachment = try XCTUnwrap(runtime.attachment)
        let screenGuarded = await HCConversationResumeSubmission().submit(panelID: id, runtime: runtime, attachment: attachment,
            text: "never", submitReturn: true, permitsResume: { true },
            screenGuard: { receipt in receipt.revision == runtime.currentDisplayRevision },
            returnGuard: { receipt in receipt.revision == runtime.currentDisplayRevision })
        guard case .refused = screenGuarded else { return XCTFail("the screen-guarded route wrote into a headless terminal: \(screenGuarded)") }
        XCTAssertEqual(fakes[1].writers.last?.received, Data(), "nothing reached the terminal by the screen-guarded route")
        let resumed = await panel.surface.submitHCConversationResume(text: "claude --resume abc", submitReturn: true,
            runtime: runtime, attachment: attachment, permitsResume: { true })
        guard case .written = resumed else { return XCTFail("the resume into the headless replacement: \(resumed)") }
        let received = try XCTUnwrap(fakes[1].writers.last).received
        XCTAssertEqual(received, Data("claude --resume abc".utf8) + Data([13]))
        // permitsResume still holds: a shell that has not reported its prompt is not typed into.
        let held = await panel.surface.submitHCConversationResume(text: "again", submitReturn: true,
            runtime: runtime, attachment: attachment, permitsResume: { false })
        guard case .refused(.guardRefused) = held else { return XCTFail("a shell not at its prompt is not typed into: \(held)") }
    }

    /// Astra's verify of #194: the old terminal had a native surface; retiring it runs the production removal (a new
    /// input generation, no pointer, no bridge). That is not a competing start: with nobody else attaching, the
    /// hidden panel still gets exactly one replacement in its shard, and input reaches it.
    func testANativeBackedEndedPanelIsReplacedOnceWhenItsOwnRetirementMovesTheGeneration() async throws {
        _ = NSApplication.shared
        let home = URL(fileURLWithPath: "/Users/tester")
        let fakes = (0...1).map { PoolShardFake(index: $0) }
        let shards = try fakes.map { fake in
            HCShard(index: fake.index, configuration: try HCLaunchPolicy.configuration(home: home, tag: nil, shard: fake.index,
                inherited: [:]), session: fake, intents: nil)
        }
        let pool = HCShardPool(shards: shards, placement: HCShardPlacement())
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let id = panel.id
        defer { panel.surface.installFakeNativeSurfaceForTesting(nil); HCPanelRestoreState.shared.remove(panelID: id); withExtendedLifetime(workspace) {} }
        let target = try XCTUnwrap(pool.creationTarget(panelID: id, workspaceID: workspace.id, machine: nil))
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: id, origin: .fresh), session: pool.route(panelID: id))
        var launch = HCPanelLaunchSpec(argv: ["/bin/sh"], cwd: nil, environment: [:], initialInput: nil, workspaceID: workspace.id)
        launch.shard = target.id
        let old = HCNativeBridge.headless(panelID: id, report: { _ in })
        let pointer = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: 0x10))
        panel.surface.installHCSessionForTesting(runtime)
        panel.surface.setLaunchSpecForTesting(launch)
        panel.surface.installNativeBackedBridgeForTesting(old, pointer: pointer)
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCHeadless.grid, facts: HCDisplayFacts(), focused: false)
        do { _ = try await runtime.attachSurface(launch: launch, bridge: old, display: display) }
        catch { return XCTFail("the first creation threw \(error)") }
        guard case .live(let first) = runtime.lifecycle else { return XCTFail("live: \(runtime.lifecycle)") }
        let generationBefore = panel.surface.nativeInputGenerationForTesting
        fakes[1].finish(first.key, reason: "holder_lost")
        let ended = await waitUntil { if case .ended = runtime.lifecycle { return true }; return false }
        XCTAssertTrue(ended)
        do { try await panel.surface.replaceEndedHCWithShell(evenWhenHidden: true) }
        catch { return XCTFail("the replacement threw \(error): its own retirement was taken for a competing start") }
        XCTAssertNil(panel.surface.surface, "the old pointer left use through the production removal")
        XCTAssertNotEqual(panel.surface.nativeInputGenerationForTesting, generationBefore, "the removal moved the generation")
        XCTAssertFalse(panel.surface.nativeBridgeForTesting === old, "the retired bridge is not the replacement's")
        XCTAssertEqual(fakes[1].creates, 2, "exactly one replacement")
        XCTAssertEqual(fakes[0].creates, 0)
        guard case .live(let replacement) = runtime.lifecycle else { return XCTFail("replaced: \(runtime.lifecycle)") }
        XCTAssertNotEqual(replacement.key, first.key)
        let attachment = try XCTUnwrap(runtime.attachment)
        let input = await attachment.submit(HCInputRequest(operationID: UUID(), panelID: id, key: replacement.key,
            attachmentGeneration: attachment.generation, source: .socket, payload: Data("claude --resume x".utf8), submitReturn: true))
        guard case .written = input else { return XCTFail("input to the replacement: \(input)") }
    }

    /// Astra on #194: the panel is shown while the old bridge retires, and its native start begins in that window.
    /// The replacement must adopt that start: one creation, the native bridge and its input generation kept, input
    /// and display updates through the native attachment.
    func testAPanelShownWhileTheOldBridgeRetiresKeepsTheNativeStartThatWon() async throws {
        _ = NSApplication.shared
        let home = URL(fileURLWithPath: "/Users/tester")
        let fakes = (0...1).map { PoolShardFake(index: $0) }
        let shards = try fakes.map { fake in
            HCShard(index: fake.index, configuration: try HCLaunchPolicy.configuration(home: home, tag: nil, shard: fake.index,
                inherited: [:]), session: fake, intents: nil)
        }
        let pool = HCShardPool(shards: shards, placement: HCShardPlacement())
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let id = panel.id
        defer {
            TerminalSurface.replacementRetiredBarrierForTesting = nil
            HCPanelRestoreState.shared.remove(panelID: id); withExtendedLifetime(workspace) {}
        }
        let target = try XCTUnwrap(pool.creationTarget(panelID: id, workspaceID: workspace.id, machine: nil))
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: id, origin: .fresh), session: pool.route(panelID: id))
        var launch = HCPanelLaunchSpec(argv: ["/bin/sh"], cwd: nil, environment: [:], initialInput: nil, workspaceID: workspace.id)
        launch.shard = target.id
        let headless = HCNativeBridge.headless(panelID: id, report: { _ in })
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCHeadless.grid, facts: HCDisplayFacts(), focused: false)
        do { _ = try await runtime.attachSurface(launch: launch, bridge: headless, display: display) }
        catch { return XCTFail("the first creation threw \(error)") }
        panel.surface.installHCSessionForTesting(runtime)
        panel.surface.setHeadlessBridgeForTesting(headless)
        panel.surface.setLaunchSpecForTesting(launch)
        guard case .live(let first) = runtime.lifecycle else { return XCTFail("live: \(runtime.lifecycle)") }
        fakes[1].finish(first.key, reason: "holder_lost")
        let ended = await waitUntil { if case .ended = runtime.lifecycle { return true }; return false }
        XCTAssertTrue(ended)

        // The barrier: right after the old bridge retired, the operator shows the panel; its surface installs the
        // native bridge (a new input generation) and starts its attach, which is in flight when retirement is released.
        let native = HCNativeBridge.headless(panelID: id, report: { _ in })      // stands in for the native bridge
        var nativeGeneration: UInt64 = 0
        var nativeStart: Task<(any HCAttachment)?, Never>?
        TerminalSurface.replacementRetiredBarrierForTesting = { surface in
            surface.installNativeBridgeForTesting(native)
            nativeGeneration = surface.nativeInputGenerationForTesting
            let shownDisplay = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                grid: HCGridSize(columns: 132, rows: 40), facts: HCDisplayFacts(), focused: true)
            nativeStart = Task { @MainActor in try? await runtime.attachSurface(launch: launch, bridge: native, display: shownDisplay) }
            for _ in 0..<200 where !runtime.isStartingAttachment { await Task.yield() }
            XCTAssertTrue(runtime.isStartingAttachment, "the native start is in flight when retirement is released")
        }
        do { try await panel.surface.replaceEndedHCWithShell(evenWhenHidden: true) }
        catch { return XCTFail("the replacement threw \(error) instead of adopting the native start") }
        _ = await nativeStart?.value
        XCTAssertEqual(fakes[1].creates, 2, "exactly one replacement")
        XCTAssertEqual(fakes[0].creates, 0)
        XCTAssertTrue(panel.surface.nativeBridgeForTesting === native, "the native start's bridge is kept, not overwritten")
        XCTAssertEqual(panel.surface.nativeInputGenerationForTesting, nativeGeneration, "its input generation is kept")
        let attachment = try XCTUnwrap(runtime.attachment)
        guard case .live(let replacement) = runtime.lifecycle else { return XCTFail("replaced: \(runtime.lifecycle)") }
        XCTAssertNotEqual(replacement.key, first.key)
        let input = await attachment.submit(HCInputRequest(operationID: UUID(), panelID: id, key: replacement.key,
            attachmentGeneration: attachment.generation, source: .socket, payload: Data("claude --resume x".utf8), submitReturn: true))
        guard case .written = input else { return XCTFail("input through the kept attachment: \(input)") }
        let resized = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: attachment.generation, displayGeneration: 1),
            grid: HCGridSize(columns: 100, rows: 30), facts: HCDisplayFacts(), focused: true)
        let update = await attachment.updateDisplay(resized)
        guard case .written = update else { return XCTFail("display update through the kept attachment: \(update)") }
    }

    // MARK: C11H-167 (Astra on #196): the headless resume's guards, each on a fresh terminal through the production entry

    /// A hidden panel whose shard-1 terminal ended holder_lost and was replaced headless.
    private func headlessReplacement() async throws -> (TerminalPanel, HCPanelSession, any HCAttachment, PoolShardFake, Workspace) {
        let home = URL(fileURLWithPath: "/Users/tester")
        let fresh = UUID().uuidString.prefix(8)      // fresh terminal keys: the shared resume ledger never saw them
        let fakes = (0...1).map { PoolShardFake(index: $0, coreID: "core-\($0)-\(fresh)") }
        let shards = try fakes.map { fake in
            HCShard(index: fake.index, configuration: try HCLaunchPolicy.configuration(home: home, tag: nil, shard: fake.index,
                inherited: [:]), session: fake, intents: nil)
        }
        let pool = HCShardPool(shards: shards, placement: HCShardPlacement())
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let target = try XCTUnwrap(pool.creationTarget(panelID: panel.id, workspaceID: workspace.id, machine: nil))
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel.id, origin: .fresh), session: pool.route(panelID: panel.id))
        runtime.installReconnectPolicy()
        var launch = HCPanelLaunchSpec(argv: ["/bin/sh"], cwd: nil, environment: [:], initialInput: nil, workspaceID: workspace.id)
        launch.shard = target.id
        let headless = HCNativeBridge.headless(panelID: panel.id, report: { _ in })
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCHeadless.grid, facts: HCDisplayFacts(), focused: false)
        _ = try await runtime.attachSurface(launch: launch, bridge: headless, display: display)
        panel.surface.installHCSessionForTesting(runtime)
        panel.surface.setHeadlessBridgeForTesting(headless)
        panel.surface.setLaunchSpecForTesting(launch)
        guard case .live(let first) = runtime.lifecycle else { throw HCUnavailableReason.inventoryPending }
        fakes[1].finish(first.key, reason: "holder_lost")
        _ = await waitUntil { if case .ended = runtime.lifecycle { return true }; return false }
        try await panel.surface.replaceEndedHCWithShell(evenWhenHidden: true)
        return (panel, runtime, try XCTUnwrap(runtime.attachment), fakes[1], workspace)
    }

    func testAHeadlessResumeIsNeverTypedIntoABlockedOrStatuslessAgentOrAShellNotAtItsPrompt() async throws {
        for (label, status, permits) in [("blocked agent", "blocked", true), ("agent with no status", nil, true),
                                         ("shell not at its prompt", "shell", false)] as [(String, String?, Bool)] {
            let (panel, runtime, attachment, shard, workspace) = try await headlessReplacement()
            defer { HCPanelRestoreState.shared.remove(panelID: panel.id); withExtendedLifetime(workspace) {} }
            if status != "shell", let key = runtime.lifecycle.liveRecordForTesting?.key {
                shard.setAgent(key, status: status)
                let seen = await waitUntil { runtime.lifecycle.liveRecordForTesting?.foreground?.name == "claude" }
                XCTAssertTrue(seen, label)
            }
            let outcome = await panel.surface.submitHCConversationResume(text: "claude --resume x", submitReturn: true,
                runtime: runtime, attachment: attachment, permitsResume: { permits })
            guard case .refused = outcome else { XCTFail("\(label): typed: \(outcome)"); continue }
            XCTAssertEqual(shard.writers.last?.received, Data(), "\(label): zero bytes")
        }
    }

    func testEligibilityLostAfterTheFirstCheckStopsTheBodyOrTheReturnAndIsNeverReplayed() async throws {
        // Lost before the body (the shell left its prompt while the write was encoded): zero bytes.
        do {
            let (panel, runtime, attachment, shard, workspace) = try await headlessReplacement()
            defer { HCPanelRestoreState.shared.remove(panelID: panel.id); withExtendedLifetime(workspace) {} }
            var asks = 0
            let outcome = await panel.surface.submitHCConversationResume(text: "claude --resume x", submitReturn: true,
                runtime: runtime, attachment: attachment, permitsResume: { asks += 1; return asks <= 1 })
            guard case .refused = outcome else { return XCTFail("before the body: \(outcome)") }
            XCTAssertEqual(shard.writers.last?.received, Data(), "before the body: zero bytes")
        }
        // Lost before the Return (the body is out): uncertain, no Return byte, and never typed again.
        do {
            let (panel, runtime, attachment, shard, workspace) = try await headlessReplacement()
            defer { HCPanelRestoreState.shared.remove(panelID: panel.id); withExtendedLifetime(workspace) {} }
            // Eligible until the body has reached the terminal, then not (the shell left its prompt meanwhile).
            let outcome = await panel.surface.submitHCConversationResume(text: "claude --resume x", submitReturn: true,
                runtime: runtime, attachment: attachment, permitsResume: { shard.writers.last?.received.isEmpty ?? true })
            guard case .uncertain(let receipt) = outcome else { return XCTFail("before the Return: \(outcome)") }
            XCTAssertFalse(receipt.returnWritten)
            XCTAssertEqual(shard.writers.last?.received, Data("claude --resume x".utf8), "the body, and no Return")
            let again = await panel.surface.submitHCConversationResume(text: "claude --resume x", submitReturn: true,
                runtime: runtime, attachment: attachment, permitsResume: { true })
            guard case .refused = again else { return XCTFail("replayed: \(again)") }
            XCTAssertEqual(shard.writers.last?.received, Data("claude --resume x".utf8), "never typed again")
        }
    }

    func testWithAScreenTheVisibleRouteStillRefusesAStaleScreen() async throws {
        let (panel, runtime, attachment, shard, workspace) = try await headlessReplacement()
        defer {
            panel.surface.installFakeNativeSurfaceForTesting(nil)
            HCPanelRestoreState.shared.remove(panelID: panel.id); withExtendedLifetime(workspace) {}
        }
        // A surface appears (the panel is shown): the screen route applies, and this renderer has no current screen.
        panel.surface.installFakeNativeSurfaceForTesting(UnsafeMutableRawPointer(bitPattern: 0x10))
        let outcome = await panel.surface.submitHCConversationResume(text: "claude --resume x", submitReturn: true,
            runtime: runtime, attachment: attachment, permitsResume: { true })
        guard case .refused = outcome else { return XCTFail("the visible route typed without a current screen: \(outcome)") }
        XCTAssertEqual(shard.writers.last?.received, Data())
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, _ seconds: Double = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if condition() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }
}

/// C11H-196: the 2026-11-04 reboot. A hidden agent panel whose terminal ended with the host is decided once
/// (however many inventory revisions republish the end), gets its fresh terminal headless through the staggered
/// queue without being shown, and has its saved conversation typed exactly once, into that fresh shell only.
@MainActor
final class HCHostEndRecoveryTests: XCTestCase {
    /// C11H-232: holds a transcript check until the test opens it.
    private final class Gate: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var entered = false
        var hasWaiter: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        func open() { semaphore.signal() }
        func pass() {
            lock.lock(); entered = true; lock.unlock()
            semaphore.wait(); semaphore.signal()
        }
    }

    private struct TranscriptDisk: ConversationFilesystem {
        let present: Set<String>
        var gate: Gate? = nil
        var homeDirectory: URL? { URL(fileURLWithPath: "/Users/tester") }
        func fileExists(atPath path: String) -> Bool { gate?.pass(); return present.contains(path) }
        func listDirectoryByMtime(_ directory: URL, max: Int) -> [ConversationFilesystemEntry] { [] }
        func listSessionsRecursivelyByMtime(_ root: URL, extensionFilter: String, max: Int) -> [ConversationFilesystemEntry] { [] }
    }

    private var savedFilesystem: (@Sendable () -> ConversationFilesystem)?
    private var savedInterval: TimeInterval = 0
    private var savedSettle: TimeInterval = 0
    private var resetGhostty: (@MainActor () -> Void)?
    private var resetDiagnostics: (@MainActor () -> Void)?
    private var diagnosticDirectory: URL?
    private var fixtureWorkspaces: [Workspace] = []

    override func setUp() async throws {
        resetGhostty = GhosttyApp.installConfigFreeFixtureForTesting()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c11-recovery-fixture-\(UUID().uuidString)")
        diagnosticDirectory = directory
        resetDiagnostics = HCDiagnosticRecorder.installFixtureForTesting(directory: directory)
        HCMassSignalEnd.shared.resetForTesting()
        savedFilesystem = Workspace.hostEndTranscriptFilesystem
        Workspace.hostEndTranscriptFilesystem = { TranscriptDisk(present: []) }
        savedInterval = HCHostEndResumeQueue.shared.interval
        savedSettle = HCHostEndResumeQueue.shared.settle
        HCHostEndResumeQueue.shared.interval = 0
        HCHostEndResumeQueue.shared.settle = 0
    }

    override func tearDown() async throws {
        fixtureWorkspaces.forEach { $0.retireForSessionRestore() }
        fixtureWorkspaces.removeAll()
        if let savedFilesystem { Workspace.hostEndTranscriptFilesystem = savedFilesystem }
        HCMassSignalEnd.shared.resetForTesting()
        HCHostEndResumeQueue.shared.interval = savedInterval
        HCHostEndResumeQueue.shared.settle = savedSettle
        XCTAssertNil(GhosttyApp.shared.app)
        XCTAssertNil(GhosttyApp.shared.config)
        resetGhostty?()
        resetGhostty = nil
        resetDiagnostics?()
        resetDiagnostics = nil
        if let diagnosticDirectory { try FileManager.default.removeItem(at: diagnosticDirectory) }
        diagnosticDirectory = nil
    }

    private struct Rig {
        let fakes: [PoolShardFake]
        let workspace: Workspace
        let panel: TerminalPanel
        let runtime: HCPanelSession
        let first: HCTerminalKey
        let conversation: String
        let cwd: String
    }

    /// A hidden panel with a live terminal in shard 1 and a saved Claude conversation, observed for recovery the
    /// way the app observes every persistent panel. `onDisk` says whether the transcript is there.
    private func rig(onDisk: Bool, machine: HCMachineRequest = .local, observeRecovery: Bool = true,
                     capturedAt: Date = Date()) async throws -> Rig {
        _ = NSApplication.shared
        let home = URL(fileURLWithPath: "/Users/tester")
        // Unique core ids: the once-per-terminal resume ledger is process-wide.
        let fakes = (0...1).map { PoolShardFake(index: $0, coreID: "core-196-\($0)-\(UUID().uuidString.prefix(6))") }
        let shards = try fakes.map { fake in
            HCShard(index: fake.index, configuration: try HCLaunchPolicy.configuration(home: home, tag: nil, shard: fake.index,
                inherited: [:], binary: HCCoreBinary.external(home: home, pin: HCCoreBinary.externalPin),
                retainedTrust: HCRetainedTrust(shipped: [], team: nil, satisfies: { _, _ in false }), namespace: nil),
                session: fake, intents: nil)
        }
        let pool = HCShardPool(shards: shards, placement: HCShardPlacement())
        let workspace = Workspace()
        fixtureWorkspaces.append(workspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false, machine: machine))
        let id = panel.id
        let target = try XCTUnwrap(pool.creationTarget(panelID: id, workspaceID: workspace.id, machine: nil))
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: id, origin: .fresh),
            session: pool.route(panelID: id), registrar: { _, _ in })
        runtime.diagnosticSink = { _ in }
        runtime.installReconnectPolicy()
        HCRestoreLifecycleStore.shared.observe(runtime)
        var launch = HCPanelLaunchSpec(argv: ["/bin/sh"], cwd: nil, environment: [:], initialInput: nil, workspaceID: workspace.id)
        launch.shard = target.id
        let headless = HCNativeBridge.headless(panelID: id, report: { _ in })
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCHeadless.grid, facts: HCDisplayFacts(), focused: false)
        _ = try await runtime.attachSurface(launch: launch, bridge: headless, display: display)
        panel.surface.installHCSessionForTesting(runtime)
        panel.surface.setHeadlessBridgeForTesting(headless)
        panel.surface.setLaunchSpecForTesting(launch)
        panel.surface.replacementLaunchSnapshotForTesting = HCNativeLaunchSnapshot(
            command: .direct(["/bin/sh"]), environment: [:], overrides: [:], workingDirectory: nil)
        guard case .live(let first) = runtime.lifecycle else { throw XCTSkip("no live terminal: \(runtime.lifecycle)") }
        let conversation = UUID().uuidString.lowercased()
        let cwd = "/Users/tester/work_196.proj"
        _ = await ConversationStore.shared.push(surfaceId: id.uuidString, kind: "claude-code", id: conversation,
                                                source: .hook, cwd: cwd, capturedAt: capturedAt, state: .alive)
        let slug = ClaudeCodeStrategy.projectSlug(forCwd: cwd)
        let present: Set<String> = onDisk ? ["/Users/tester/.claude/projects/\(slug)/\(conversation).jsonl"] : []
        Workspace.hostEndTranscriptFilesystem = { TranscriptDisk(present: present) }
        if observeRecovery { workspace.observePersistentRecovery(panel) }
        return Rig(fakes: fakes, workspace: workspace, panel: panel, runtime: runtime, first: first.key,
                   conversation: conversation, cwd: cwd)
    }

    private func cleanUp(_ rig: Rig) async {
        await ConversationStore.shared.clear(surfaceId: rig.panel.id.uuidString)
        HCHostEndResumeQueue.shared.cancel(panelID: rig.panel.id)
        HCPanelRestoreState.shared.remove(panelID: rig.panel.id)
        withExtendedLifetime(rig.workspace) {}
    }

    func testAHiddenPanelEndedByTheHostResumesOnceHeadlessAndIsDecidedOnce() async throws {
        let rig = try await rig(onDisk: true)
        defer { Task { @MainActor in await cleanUp(rig) } }
        XCTAssertFalse(rig.panel.surface.isShownInRealWindow, "the panel is never shown")
        rig.fakes[1].finish(rig.first, reason: "stopped_by_restart")
        // hc republishes the same end on every inventory revision.
        for _ in 0..<40 { rig.fakes[1].republish() }
        let replaced = await waitUntil { rig.fakes[1].creates == 2 }
        XCTAssertTrue(replaced, "one fresh terminal, headless, in its own shard: \(rig.runtime.lifecycle)")
        XCTAssertEqual(rig.fakes[0].creates, 0)
        XCTAssertEqual(rig.workspace.resumeDecisionCounts[rig.panel.id], 1, "decided once, not once per revision")
        XCTAssertFalse(rig.panel.surface.isShownInRealWindow)
        // Nothing is typed until the fresh shell reports its prompt.
        XCTAssertEqual(rig.fakes[1].writers.last?.received, Data())
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        let typed = await waitUntil { !(rig.fakes[1].writers.last?.received.isEmpty ?? true) }
        XCTAssertTrue(typed, "the resume reaches the headless replacement")
        let text = String(decoding: rig.fakes[1].writers.last?.received ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("cd '\(rig.cwd)' && claude"), text)
        XCTAssertTrue(text.contains("--resume '\(rig.conversation)'"), text)
        XCTAssertTrue(text.hasSuffix("\r"), "submitted with Return")
        // More revisions and prompt edges type nothing more and decide nothing more.
        for _ in 0..<20 { rig.fakes[1].republish() }
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .commandRunning)
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(String(decoding: rig.fakes[1].writers.last?.received ?? Data(), as: UTF8.self), text, "typed exactly once")
        XCTAssertEqual(rig.workspace.resumeDecisionCounts[rig.panel.id], 1)
        XCTAssertEqual(rig.fakes[1].creates, 2)
        XCTAssertEqual(rig.panel.hcHostEnd?.phase, .resumed)
        XCTAssertNil(rig.panel.hcRestoreNotice, "no stale host-stopped notice on the working replacement")
        XCTAssertNil(rig.panel.visibleHCHostEnd)
    }

    /// C11H-283: the production migration and Workspace restore feed the same
    /// recovery observer and guarded transport used by ordinary host ends.
    /// Only external HC, transcript disk and native configuration inputs are
    /// fixtures; restore, recovery, creation and guarded submission are real.
    func testConvergenceRestoresTheSavedConversationExactlyOnceAcrossLifecycleAndRelaunch() async throws {
        XCTAssertNil(GhosttyApp.shared.app)
        XCTAssertNil(GhosttyApp.shared.config)
        _ = NSApplication.shared
        let id = UUID()
        let oldKey = HCTerminalKey(owningCoreID: "legacy-core-\(UUID().uuidString)", localAddress: "old")
        let ref = ConversationRef(kind: "claude-code", id: UUID().uuidString.lowercased(), cwd: "/fixture/migrated",
                                  capturedVia: .hook, state: .alive)
        let panelSnapshot = SessionPanelSnapshot(id: id, type: .terminal, title: "Migrated", customTitle: nil,
            directory: ref.cwd, isPinned: false, isManuallyUnread: false, gitBranch: nil, listeningPorts: [], ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: ref.cwd,
                hcIdentity: HCPanelIdentity(panelID: id, key: oldKey, creationID: UUID()), hcSession: "c11h-s3"), // c11-2.0:legacy (source-world fixture)
            browser: nil, markdown: nil, surfaceConversations: PanelConversations(active: ref))
        let legacy = SessionWorkspaceSnapshot(id: UUID(), processTitle: "Migration fixture", customTitle: nil,
            customColor: nil, isPinned: false, currentDirectory: ref.cwd ?? "/fixture", focusedPanelId: id,
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: [id], selectedPanelId: id)), panels: [panelSnapshot],
            statusEntries: [], logEntries: [], progress: nil, gitBranch: nil)
        let (data, changed) = try C11MigrationExecutor.settleDeadTerminals(JSONEncoder().encode(legacy), legacyBase: "c11h") // c11-2.0:legacy (source-world fixture)
        XCTAssertEqual(changed, 1)
        let converted = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        XCTAssertNil(converted.panels[0].terminal?.hcIdentity)
        XCTAssertEqual(converted.panels[0].terminal?.hcMigrationEnd?.key, oldKey)
        let core = PoolShardFake(index: 0, coreID: "destination-core-\(UUID().uuidString)")
        let slug = ClaudeCodeStrategy.projectSlug(forCwd: ref.cwd ?? "/fixture")
        Workspace.hostEndTranscriptFilesystem = { TranscriptDisk(present: [
            "/Users/tester/.claude/projects/\(slug)/\(ref.id).jsonl"
        ]) }
        _ = await ConversationStore.shared.push(surfaceId: id.uuidString, kind: ref.kind, id: ref.id,
                                                 source: .hook, cwd: ref.cwd, state: .alive)
        func restore(_ snapshot: SessionWorkspaceSnapshot) throws -> (Workspace, TerminalPanel, HCPanelSession) {
            let workspace = Workspace(restoringSession: true)
            fixtureWorkspaces.append(workspace)
            workspace.restoreSessionSnapshot(snapshot)
            let panel = try XCTUnwrap(workspace.panels[id] as? TerminalPanel)
            panel.hcSession?.detachSurface()
            let identity = try XCTUnwrap(HCPanelRestoreState.shared.entry(for: id)?.identity)
            let runtime = HCPanelSession(identity: identity, session: core, registrar: { _, _ in })
            runtime.diagnosticSink = { _ in }
            runtime.installReconnectPolicy()
            panel.surface.installHCSessionForTesting(runtime)
            HCRestoreLifecycleStore.shared.observe(runtime)
            panel.surface.setLaunchSpecForTesting(HCPanelLaunchSpec(argv: ["/bin/sh"], cwd: ref.cwd,
                environment: [:], initialInput: nil, workspaceID: nil))
            panel.surface.replacementLaunchSnapshotForTesting = HCNativeLaunchSnapshot(
                command: .direct(["/bin/sh"]), environment: [:], overrides: [:], workingDirectory: ref.cwd)
            workspace.observePersistentRecovery(panel)
            return (workspace, panel, runtime)
        }
        let (workspace, panel, runtime) = try restore(converted)
        defer {
            workspace.retireForSessionRestore()
            Task { @MainActor in
                await ConversationStore.shared.clear(surfaceId: id.uuidString)
                HCHostEndResumeQueue.shared.cancel(panelID: id)
                HCPanelRestoreState.shared.remove(panelID: id)
            }
        }
        _ = await runtime.resolveIdentity()
        let created = await waitUntil { core.creates == 1 && runtime.attachment != nil }
        XCTAssertTrue(created, "converted hidden panel creates its fresh destination shell: \(runtime.lifecycle)")
        XCTAssertEqual(workspace.resumeDecisionCounts[id], 1)
        XCTAssertEqual(core.writers.last?.received, Data(), "no input before the shell reaches its prompt")
        workspace.updatePanelShellActivityState(panelId: id, state: .promptIdle)
        let resumed = await waitUntil { panel.hcHostEnd?.phase == .resumed }
        XCTAssertTrue(resumed)
        let writer = try XCTUnwrap(core.writers.last)
        let sent = writer.received
        let command = String(decoding: sent, as: UTF8.self)
        XCTAssertTrue(command.contains("--resume '\(ref.id)'"), command)
        XCTAssertTrue(command.hasSuffix("\r"))
        for _ in 0..<20 { core.republish() }
        workspace.updatePanelShellActivityState(panelId: id, state: .commandRunning)
        workspace.updatePanelShellActivityState(panelId: id, state: .promptIdle)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(writer.received, sent)
        XCTAssertEqual(core.creates, 1)
        let saved = workspace.sessionSnapshot(includeScrollback: false,
            conversationsByPanelId: [id.uuidString: PanelConversations(active: ref)])
        XCTAssertEqual(saved.panels.first?.terminal?.hcMigrationEnd?.key, oldKey)
        XCTAssertTrue(saved.panels.first?.terminal?.hcHostEnd?.decidedKeys.contains(oldKey) == true)
        let savedBytes = try JSONEncoder().encode(saved)
        workspace.retireForSessionRestore()
        HCPanelRestoreState.shared.remove(panelID: id)
        let (next, nextPanel, nextRuntime) = try restore(JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: savedBytes))
        defer { next.retireForSessionRestore() }
        _ = await nextRuntime.resolveIdentity()
        for _ in 0..<20 { core.republish() }
        next.updatePanelShellActivityState(panelId: id, state: .promptIdle)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(nextPanel.plannedHCEndedKeys.contains(oldKey), "the ordinary saved decision is restored")
        XCTAssertNil(nextPanel.pendingHCConversationRecovery)
        XCTAssertNil(next.resumeDecisionCounts[id], "a relaunch does not plan that end again")
        XCTAssertEqual(writer.received, sent)
        XCTAssertEqual(core.creates, 1)
        XCTAssertNil(GhosttyApp.shared.app, "model recovery never initializes native Ghostty")
        XCTAssertNil(GhosttyApp.shared.config, "the fixture never loads host Ghostty configuration")
    }

    /// C11H-321, panel 1901 on 2026-11-15: a panel restored as working whose terminal ended with the host and was
    /// not resumed had no terminal for 38 minutes and drew working throughout. The ended terminal takes the
    /// lifecycle with it; while the terminal was live the restored working stood.
    func testAPanelWhoseTerminalEndedNoLongerDrawsTheWorkingItWasRestoredWith() async throws {
        let rig = try await rig(onDisk: false)
        defer { Task { @MainActor in await cleanUp(rig) } }
        let store = PanelMetadataStore.shared
        let ws = rig.workspace.id, id = rig.panel.id
        defer { store.removeSurface(workspaceId: ws, surfaceId: id) }
        // What the restore seeds from the last session for an opencode panel.
        _ = store.setInternal(workspaceId: ws, surfaceId: id, key: MetadataKey.terminalType, value: "opencode", source: .declare)
        _ = store.setInternal(workspaceId: ws, surfaceId: id, key: MetadataKey.activity,
                          value: SidebarActivityState.working.rawValue, source: .derived)
        rig.workspace.setDerivedActivity(.working, forSurface: id)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(rig.workspace.resolvedSurfacePanelActivityState(panelId: id), .running,
                       "a live terminal keeps the lifecycle it was restored with")
        // A reconnecting terminal is not an end: its last phase is kept.
        rig.runtime.publish(.unresolved(rig.runtime.identity, .connectionLost))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(rig.workspace.resolvedSurfacePanelActivityState(panelId: id), .running, "reconnecting keeps working")
        XCTAssertEqual(store.getMetadata(workspaceId: ws, surfaceId: id).metadata[MetadataKey.activity] as? String,
                       SidebarActivityState.working.rawValue)

        rig.fakes[1].finish(rig.first, reason: "stopped_by_restart")
        let cleared = await waitUntil { rig.workspace.derivedActivityByPanel[id] == nil }
        XCTAssertTrue(cleared, "\(String(describing: rig.workspace.derivedActivityByPanel[id])) \(rig.runtime.lifecycle)")
        XCTAssertNil(store.getMetadata(workspaceId: ws, surfaceId: id).metadata[MetadataKey.activity] as? String)
        XCTAssertEqual(rig.workspace.resolvedSurfacePanelActivityState(panelId: id), .idle, "never working")
        XCTAssertEqual(rig.fakes[1].creates, 1, "not resumed: no terminal for the sweep to visit")
    }

    /// C11H-321: the end clears only c11's own derived lifecycle. An activity an agent or the operator set
    /// explicitly outranks it and stays, in the store and on the mark.
    func testAnExplicitActivityOutlivesTheTerminalEnd() async throws {
        let rig = try await rig(onDisk: false)
        defer { Task { @MainActor in await cleanUp(rig) } }
        let store = PanelMetadataStore.shared
        let ws = rig.workspace.id, id = rig.panel.id
        defer { store.removeSurface(workspaceId: ws, surfaceId: id) }
        _ = store.setInternal(workspaceId: ws, surfaceId: id, key: MetadataKey.terminalType, value: "opencode", source: .declare)
        _ = store.setInternal(workspaceId: ws, surfaceId: id, key: MetadataKey.activity,
                              value: SidebarActivityState.working.rawValue, source: .explicit)
        rig.workspace.setDerivedActivity(.working, forSurface: id)

        rig.fakes[1].finish(rig.first, reason: "stopped_by_restart")
        let ended = await waitUntil { rig.panel.hcHostEnd != nil }
        XCTAssertTrue(ended, "\(rig.runtime.lifecycle)")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.getMetadata(workspaceId: ws, surfaceId: id).metadata[MetadataKey.activity] as? String,
                       SidebarActivityState.working.rawValue, "explicit outranks the end's derived clear")
        XCTAssertEqual(store.getSource(workspaceId: ws, surfaceId: id, key: MetadataKey.activity), .explicit)
        XCTAssertEqual(rig.workspace.resolvedSurfacePanelActivityState(panelId: id), .running)
    }

    /// C11H-321 repair: an agent that dies with its terminal (crash, kill or reboot) sends no SessionEnd, so its
    /// journal still reads live and working. The end disconnects that journal through the reducer's
    /// `connection_lost` and clears past the live-journal veto; the old live projection cannot paint working again.
    func testATerminalThatEndsUnderALiveWorkingJournalStopsDrawingWorking() async throws {
        let rig = try await rig(onDisk: false)
        defer { Task { @MainActor in await cleanUp(rig) } }
        let store = PanelMetadataStore.shared
        let coordinator = JournalCoordinator.shared
        let ws = rig.workspace.id, id = rig.panel.id
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c11h-321-journal-\(UUID().uuidString)")
        let previous = coordinator.replaceStoreForTesting(try JournalStore(layout: JournalStorageLayout(directory: directory)))
        defer {
            coordinator.remove(panelID: id)
            _ = coordinator.replaceStoreForTesting(previous)
            try? FileManager.default.removeItem(at: directory)
            store.removeSurface(workspaceId: ws, surfaceId: id)
        }
        _ = store.setInternal(workspaceId: ws, surfaceId: id, key: MetadataKey.terminalType, value: "claude-code", source: .declare)
        coordinator.register(panelID: id, workspaceID: ws)
        coordinator.setOwner(panelID: id, owner: JournalOwner(panelID: id, agentKind: "claude-code", sessionID: rig.conversation))
        var submit = try XCTUnwrap(ClaudeHookMapping.map(subcommand: "prompt-submit", object: ["session_id": rig.conversation]))
        submit.panelID = id
        submit.workspaceID = ws
        _ = try coordinator.append(submit)
        let working = try XCTUnwrap(coordinator.snapshot(panelID: id))
        XCTAssertEqual(working.connection, .live)
        XCTAssertEqual(working.phase, .working)
        // What the app's journal sink paints (not installed under XCTest): the store, then the projection.
        PanelLivenessDeriver.onJournalProjection(panelID: id, snapshot: working, boundary: nil)
        let stored = await waitUntil {
            store.getMetadata(workspaceId: ws, surfaceId: id).metadata[MetadataKey.activity] as? String == "working"
        }
        XCTAssertTrue(stored)
        rig.workspace.setDerivedActivity(.working, forSurface: id)
        rig.workspace.setJournalSnapshot(working, forPanel: id)
        XCTAssertEqual(rig.workspace.resolvedSurfacePanelActivityState(panelId: id), .running)

        rig.fakes[1].finish(rig.first, reason: "stopped_by_restart")
        let cleared = await waitUntil { rig.workspace.derivedActivityByPanel[id] == nil }
        XCTAssertTrue(cleared, "\(String(describing: rig.workspace.derivedActivityByPanel[id])) \(rig.runtime.lifecycle)")
        XCTAssertNil(store.getMetadata(workspaceId: ws, surfaceId: id).metadata[MetadataKey.activity] as? String)
        XCTAssertEqual(coordinator.snapshot(panelID: id)?.connection, .disconnected, "the dead agent's journal is not live")
        XCTAssertEqual(rig.workspace.resolvedSurfacePanelActivityState(panelId: id), .idle)

        // The old live projection, and the journal's current one, arriving late.
        PanelLivenessDeriver.onJournalProjection(panelID: id, snapshot: working, boundary: nil)
        PanelLivenessDeriver.onJournalProjection(panelID: id, snapshot: coordinator.snapshot(panelID: id), boundary: nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(store.getMetadata(workspaceId: ws, surfaceId: id).metadata[MetadataKey.activity] as? String,
                     "no projection of the ended terminal's journal paints working again")
    }

    /// C11H-323: a survivor after a relaunch. Its journal row is the quitting c11's, mid-turn and no longer live
    /// (what a relaunch projects), and its agent ended that turn while c11 was down: hc keeps the agent's own
    /// `done`. Whichever arrives first, the panel never draws the working its row was saved with; hc's later word
    /// moves it until the agent's next hook makes the journal live, which then owns the panel.
    func testASurvivorsLifecycleIsHCsWordNotItsRestoredWorking() async throws {
        let rig = try await rig(onDisk: false)
        defer { Task { @MainActor in await cleanUp(rig) } }
        let store = PanelMetadataStore.shared
        let coordinator = JournalCoordinator.shared
        let ws = rig.workspace.id, id = rig.panel.id
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c11h-323-journal-\(UUID().uuidString)")
        let previous = coordinator.replaceStoreForTesting(try JournalStore(layout: JournalStorageLayout(directory: directory)))
        defer {
            coordinator.remove(panelID: id)
            _ = coordinator.replaceStoreForTesting(previous)
            try? FileManager.default.removeItem(at: directory)
            store.removeSurface(workspaceId: ws, surfaceId: id)
        }
        func activity() -> String? { store.getMetadata(workspaceId: ws, surfaceId: id).metadata[MetadataKey.activity] as? String }
        _ = store.setInternal(workspaceId: ws, surfaceId: id, key: MetadataKey.terminalType, value: "claude-code", source: .declare)
        coordinator.register(panelID: id, workspaceID: ws)
        coordinator.setOwner(panelID: id, owner: JournalOwner(panelID: id, agentKind: "claude-code", sessionID: rig.conversation))
        var submit = try XCTUnwrap(ClaudeHookMapping.map(subcommand: "prompt-submit", object: ["session_id": rig.conversation]))
        submit.panelID = id
        submit.workspaceID = ws
        _ = try coordinator.append(submit)
        _ = try coordinator.append(JournalDraft(kind: .stateChanged, emittedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            panelID: id, workspaceID: ws, sessionID: rig.conversation, agentKind: "claude-code", source: .c11, adapter: .c11,
            nativeEvent: "connection_lost", signal: .connectionLost))
        let restored = try XCTUnwrap(coordinator.snapshot(panelID: id))
        XCTAssertEqual(restored.phase, .working)
        XCTAssertTrue(restored.isHistorical)

        // The replay first: hc has not spoken, so the panel has no lifecycle, never the saved working.
        PanelLivenessDeriver.onJournalProjection(panelID: id, snapshot: restored, boundary: nil)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(activity())
        XCTAssertEqual(rig.workspace.resolvedSurfacePanelActivityState(panelId: id), .idle)

        // hc's record: the agent ended its turn while c11 was down.
        rig.fakes[1].setAgent(rig.first, status: "done")
        let rested = await waitUntil { activity() == "idle" && rig.workspace.derivedActivityByPanel[id] == .idle }
        XCTAssertTrue(rested, "\(String(describing: activity())) \(rig.runtime.lifecycle)")
        // The replay again (late, or after hc): hc's word stands.
        PanelLivenessDeriver.onJournalProjection(panelID: id, snapshot: restored, boundary: nil)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(activity(), "idle")

        // hc's next word moves it: the agent took a turn.
        rig.fakes[1].setAgent(rig.first, status: "working")
        let working = await waitUntil { rig.workspace.resolvedSurfacePanelActivityState(panelId: id) == .running }
        XCTAssertTrue(working, "\(String(describing: activity()))")

        // The agent's next hook: the journal is live and owns the panel; hc's word no longer moves it.
        var stop = try XCTUnwrap(ClaudeHookMapping.map(subcommand: "stop", object: ["session_id": rig.conversation]))
        stop.panelID = id
        stop.workspaceID = ws
        _ = try coordinator.append(stop)
        let live = try XCTUnwrap(coordinator.snapshot(panelID: id))
        XCTAssertEqual(live.connection, .live)
        PanelLivenessDeriver.onJournalProjection(panelID: id, snapshot: live, boundary: nil)
        let journalIdle = await waitUntil { activity() == "idle" }
        XCTAssertTrue(journalIdle)
        rig.fakes[1].setAgent(rig.first, status: "blocked")
        rig.fakes[1].setAgent(rig.first, status: "working")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(activity(), "idle", "a live journal owns the panel")
    }

    func testAHostEndWithNoTranscriptIsDecidedOnceSaysWhyAndResumesOnTheOperatorsWord() async throws {
        let rig = try await rig(onDisk: false)
        defer { Task { @MainActor in await cleanUp(rig) } }
        rig.fakes[1].finish(rig.first, reason: "stopped_by_restart")
        let decided = await waitUntil {
            if case .notResumed = rig.panel.hcHostEnd?.phase { return true }; return false
        }
        XCTAssertTrue(decided, "\(String(describing: rig.panel.hcHostEnd))")
        // The same end, republished with a fresh evidence id as the runtime did
        // on every inventory revision before C11H-196, is not decided again.
        for sequence in UInt64(100)..<UInt64(140) {
            rig.runtime.publish(.ended(HCEndEvidence(id: UUID(), key: rig.first,
                revision: HCRevision(connectionGeneration: 1, sequence: sequence), kind: .finished,
                hcReason: "stopped_by_restart")))
        }
        for _ in 0..<40 { rig.fakes[1].republish() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(rig.workspace.resumeDecisionCounts[rig.panel.id], 1, "a skip is decided once too")
        XCTAssertEqual(rig.fakes[1].creates, 1, "nothing is started for a conversation that will not resume")
        let status = try XCTUnwrap(rig.panel.visibleHCHostEnd, "the banner says why")
        XCTAssertTrue(status.offersResume)
        XCTAssertEqual(status.conversation?.id, rig.conversation)
        XCTAssertTrue(status.detail.contains("no saved conversation was found on disk"), status.detail)

        // Resume conversation: the operator's request is the consent.
        XCTAssertNil(rig.workspace.resumeHostEndedConversation(panelId: rig.panel.id))
        let replaced = await waitUntil { rig.fakes[1].creates == 2 }
        XCTAssertTrue(replaced)
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        let typed = await waitUntil { !(rig.fakes[1].writers.last?.received.isEmpty ?? true) }
        XCTAssertTrue(typed)
        let text = String(decoding: rig.fakes[1].writers.last?.received ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains("--resume '\(rig.conversation)'"), text)
        XCTAssertEqual(rig.panel.hcHostEnd?.phase, .resumed)
    }

    /// C11H-232: the child-exit path as the app wires it: keep or close.
    private func wireChildExit(_ rig: Rig) -> () -> [Bool] {
        var outcomes: [Bool] = []
        rig.runtime.onEnded = { [weak workspace = rig.workspace, weak runtime = rig.runtime, id = rig.panel.id] evidence in
            outcomes.append(workspace?.keepPanelAfterOutsideSignal(panelId: id, evidence: evidence,
                                                                    lastLive: runtime?.lastLiveRecord) ?? false)
        }
        return { outcomes }
    }

    /// C11H-232: a broad `pkill -f` SIGTERMs the root of a terminal an agent runs in. The panel stays, says
    /// what ended it, never resumes unasked, and resumes once on the operator's word (or `restore run`).
    func testAnOutsideSigtermKeepsTheAgentsPanelAndOffersResumeWithoutTypingIt() async throws {
        let rig = try await rig(onDisk: true)
        defer { Task { @MainActor in await cleanUp(rig) } }
        let outcomes = wireChildExit(rig)
        rig.fakes[1].setAgent(rig.first, status: "working")
        let agentSeen = await waitUntil { rig.runtime.lastLiveRecord?.foreground?.name == "claude" }
        XCTAssertTrue(agentSeen)
        rig.fakes[1].finish(rig.first, reason: "exited", signal: SIGTERM)
        let kept = await waitUntil { outcomes() == [true] }
        XCTAssertTrue(kept, "\(outcomes())")
        let offered = await waitUntil { rig.panel.hcHostEnd?.offersResume == true }
        XCTAssertTrue(offered, "offered once the transcript check settles: \(String(describing: rig.panel.hcHostEnd))")
        let status = try XCTUnwrap(rig.panel.visibleHCHostEnd, "the banner shows")
        XCTAssertEqual(status.cause, .outsideSignal(at: status.endedAt, signal: SIGTERM))
        XCTAssertEqual(status.causeToken, "outside_signal")
        XCTAssertTrue(status.headline.contains("SIGTERM"), status.headline)
        XCTAssertTrue(status.offersResume)
        XCTAssertTrue(status.needsOperator)
        XCTAssertEqual(status.recordState, "skipped")
        XCTAssertEqual(status.conversation?.id, rig.conversation)
        // hc republishes; the recovery observer runs; nothing is started or typed, and nothing decides again.
        for _ in 0..<40 { rig.fakes[1].republish() }
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(outcomes(), [true], "the end reaches the child-exit path once")
        XCTAssertEqual(rig.fakes[1].creates, 1, "no fresh terminal until the operator asks")
        XCTAssertNil(rig.workspace.resumeDecisionCounts[rig.panel.id], "never resumed unasked")
        XCTAssertEqual(rig.panel.hcHostEnd?.recordState, "skipped")

        XCTAssertNil(rig.workspace.resumeHostEndedConversation(panelId: rig.panel.id))
        let replaced = await waitUntil { rig.fakes[1].creates == 2 }
        XCTAssertTrue(replaced)
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        let typed = await waitUntil { !(rig.fakes[1].writers.last?.received.isEmpty ?? true) }
        XCTAssertTrue(typed)
        let text = String(decoding: rig.fakes[1].writers.last?.received ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains("--resume '\(rig.conversation)'"), text)
        XCTAssertEqual(rig.panel.hcHostEnd?.phase, .resumed)
    }

    // C11H-271: SessionEnd can beat hc's end callback. Neither a login root
    // nor a foreground snapshot taken during teardown supplies agent_kind.
    func testSignalKeepsRecordedConversationAfterSessionEndForEveryRootForm() async throws {
        for foreground in [HCForeground(name: "login", argv: ["/usr/bin/login", "-flp", "tester"]),
                           HCForeground(name: "bash", argv: ["/bin/bash", "--noprofile"]),
                           HCForeground(name: "custom-root", argv: ["custom-root"]), nil] {
            let rig = try await rig(onDisk: true)
            let rootEndMs = Int64(Date().timeIntervalSince1970 * 1000) + 1000
            _ = await ConversationStore.shared.push(surfaceId: rig.panel.id.uuidString, kind: "claude-code",
                id: rig.conversation, source: .hook,
                capturedAt: Date(timeIntervalSince1970: Double(rootEndMs + 1) / 1000),
                state: .unknown, sessionEnded: true)
            rig.fakes[1].setForeground(rig.first, foreground: foreground)
            let observed = await waitUntil { rig.runtime.lastLiveRecord?.foreground == foreground }
            XCTAssertTrue(observed)
            XCTAssertNil(HCLiveAgent.kind(rig.runtime.lastLiveRecord))
            let outcomes = wireChildExit(rig)
            rig.fakes[1].finish(rig.first, reason: "exited", signal: SIGTERM, at: rootEndMs)
            let kept = await waitUntil { outcomes() == [true] }
            XCTAssertTrue(kept)
            let offered = await waitUntil { rig.panel.hcHostEnd?.offersResume == true }
            XCTAssertTrue(offered)
            XCTAssertEqual(rig.panel.hcHostEnd?.conversation?.id, rig.conversation)
            XCTAssertEqual(rig.panel.hcHostEnd?.conversation?.cwd, rig.cwd)
            XCTAssertEqual(rig.panel.hcHostEnd?.conversation?.state, .suspended)
            XCTAssertEqual(rig.fakes[1].creates, 1)
            XCTAssertTrue(rig.fakes[1].writers.allSatisfy { $0.received.isEmpty })
            await cleanUp(rig)
        }
    }

    func testAgentThatEndedOneMillisecondBeforeRootSignalIsNotOffered() async throws {
        let rig = try await rig(onDisk: true)
        let rootEndMs = Int64(Date().timeIntervalSince1970 * 1000) + 1000
        _ = await ConversationStore.shared.push(surfaceId: rig.panel.id.uuidString, kind: "claude-code",
            id: rig.conversation, source: .hook,
            capturedAt: Date(timeIntervalSince1970: Double(rootEndMs - 1) / 1000),
            state: .unknown, sessionEnded: true)
        let end = HCEndEvidence(id: UUID(), key: rig.first,
            revision: HCRevision(connectionGeneration: 1, sequence: 904), kind: .finished,
            hcReason: "exited", exitSignal: SIGTERM, endedAtMilliseconds: rootEndMs)
        XCTAssertFalse(rig.workspace.keepPanelAfterOutsideSignal(panelId: rig.panel.id, evidence: end, lastLive: nil))
        XCTAssertNil(rig.panel.hcHostEnd)
        await cleanUp(rig)
    }

    func testEndAllStillRefusesTheOutsideSignalOffer() async throws {
        let rig = try await rig(onDisk: true)
        rig.panel.retainsAfterEndAllSessions = true
        let end = HCEndEvidence(id: UUID(), key: rig.first,
            revision: HCRevision(connectionGeneration: 1, sequence: 905), kind: .finished,
            hcReason: "exited", exitSignal: SIGTERM)
        XCTAssertFalse(rig.workspace.keepPanelAfterOutsideSignal(panelId: rig.panel.id, evidence: end, lastLive: nil))
        XCTAssertNil(rig.panel.hcHostEnd)
        await cleanUp(rig)
    }

    func testRemoteTerminalStillDoesNotGetALocalSignalOffer() async throws {
        let rig = try await rig(onDisk: true, machine: .on("fixture-remote"))
        let end = HCEndEvidence(id: UUID(), key: rig.first,
            revision: HCRevision(connectionGeneration: 1, sequence: 906), kind: .finished,
            hcReason: "exited", exitSignal: SIGTERM)
        XCTAssertNotNil(rig.panel.hcRemoteTarget)
        XCTAssertFalse(rig.workspace.keepPanelAfterOutsideSignal(panelId: rig.panel.id, evidence: end, lastLive: nil))
        XCTAssertNil(rig.panel.hcHostEnd)
        await cleanUp(rig)
    }

    func testHiddenSignalRecoveryUsesTheSamePostSignalSessionEndEvidence() async throws {
        let rig = try await rig(onDisk: true)
        let rootEndMs = Int64(Date().timeIntervalSince1970 * 1000) + 1000
        _ = await ConversationStore.shared.push(surfaceId: rig.panel.id.uuidString, kind: "claude-code",
            id: rig.conversation, source: .hook,
            capturedAt: Date(timeIntervalSince1970: Double(rootEndMs + 1) / 1000),
            state: .unknown, sessionEnded: true)
        XCTAssertNil(rig.runtime.onEnded)
        rig.fakes[1].finish(rig.first, reason: "exited", signal: SIGTERM, at: rootEndMs)
        let offered = await waitUntil { rig.panel.hcHostEnd?.offersResume == true }
        XCTAssertTrue(offered)
        XCTAssertEqual(rig.panel.hcHostEnd?.conversation?.id, rig.conversation)
        XCTAssertEqual(rig.panel.hcHostEnd?.signal, SIGTERM)
        XCTAssertEqual(rig.fakes[1].creates, 1)
        await cleanUp(rig)
    }

    func testHiddenRejectedSignalIsDecidedBeforeAReplacementConversationStartsAndExits() async throws {
        for hadConversation in [false, true] {
            let rig = try await rig(onDisk: true)
            let rootEndMs = Int64(Date().timeIntervalSince1970 * 1000) + 1000
            if hadConversation {
                _ = await ConversationStore.shared.push(surfaceId: rig.panel.id.uuidString, kind: "claude-code",
                    id: rig.conversation, source: .hook,
                    capturedAt: Date(timeIntervalSince1970: Double(rootEndMs - 1) / 1000),
                    state: .unknown, sessionEnded: true)
            } else {
                await ConversationStore.shared.clear(surfaceId: rig.panel.id.uuidString)
            }
            XCTAssertNil(rig.runtime.onEnded)
            rig.fakes[1].finish(rig.first, reason: "exited", signal: SIGTERM, at: rootEndMs)
            let decided = await waitUntil { rig.panel.plannedHCEndedKeys.contains(rig.first) }
            XCTAssertTrue(decided, "a rejected hidden end must be settled on its first pass")
            XCTAssertNil(rig.panel.hcHostEnd)

            try await rig.panel.surface.replaceEndedHCWithShell(evenWhenHidden: true)
            let replacement = try XCTUnwrap(rig.runtime.lifecycle.liveRecordForTesting?.key)
            XCTAssertEqual(HCPanelRestoreState.shared.entry(for: rig.panel.id)?.creation?.replaces?.key, rig.first)
            let nextID = UUID().uuidString.lowercased()
            _ = await ConversationStore.shared.push(surfaceId: rig.panel.id.uuidString, kind: "claude-code",
                id: nextID, source: .hook, cwd: rig.cwd,
                capturedAt: Date(timeIntervalSince1970: Double(rootEndMs + 1000) / 1000))
            rig.fakes[1].setAgent(replacement, status: "working")
            let agentSeen = await waitUntil { rig.workspace.hcLiveAgentKind(panelId: rig.panel.id) != nil }
            XCTAssertTrue(agentSeen)
            _ = await ConversationStore.shared.push(surfaceId: rig.panel.id.uuidString, kind: "claude-code",
                id: nextID, source: .hook,
                capturedAt: Date(timeIntervalSince1970: Double(rootEndMs + 2000) / 1000),
                state: .unknown, sessionEnded: true)
            rig.fakes[1].setForeground(replacement, foreground: HCForeground(name: "zsh", argv: ["-zsh"]))
            let shellSeen = await waitUntil { rig.runtime.lifecycle.liveRecordForTesting?.foreground?.name == "zsh" }
            XCTAssertTrue(shellSeen)
            for _ in 0..<5 { rig.fakes[1].republish() }
            try? await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertNil(rig.panel.hcHostEnd, "a later voluntary exit is unrelated to the old SIGTERM")
            XCTAssertTrue(rig.panel.plannedHCEndedKeys.contains(rig.first))
            let after = await ConversationStore.shared.snapshot()[rig.panel.id.uuidString]?.active
            XCTAssertEqual(after?.state, .unknown)
            XCTAssertTrue(rig.fakes[1].writers.allSatisfy { $0.received.isEmpty })
            await cleanUp(rig)
        }
    }

    func testReplacementAgentResolvingDuringHiddenAuditIsKeptWithoutASignalOffer() async throws {
        let rig = try await rig(onDisk: true, observeRecovery: false)
        defer { Task { @MainActor in await cleanUp(rig) } }
        let rootEndMs = Int64(Date().timeIntervalSince1970 * 1000) + 1000
        rig.fakes[1].finish(rig.first, reason: "exited", signal: SIGTERM, at: rootEndMs)
        let ended = await waitUntil { if case .ended = rig.runtime.lifecycle { return true }; return false }
        XCTAssertTrue(ended)
        try await rig.panel.surface.replaceEndedHCWithShell(evenWhenHidden: true)
        let replacement = try XCTUnwrap(rig.runtime.lifecycle.liveRecordForTesting?.key)
        let retainedEnd = try XCTUnwrap(HCPanelRestoreState.shared.entry(for: rig.panel.id)?.creation?.replaces)
        XCTAssertEqual(retainedEnd.exitSignal, SIGTERM)
        XCTAssertEqual(retainedEnd.endedAtMilliseconds, rootEndMs)
        rig.fakes[1].setAgent(replacement, status: "working")
        let seen = await waitUntil { rig.workspace.hcLiveAgentKind(panelId: rig.panel.id) != nil }
        XCTAssertTrue(seen)
        rig.fakes[1].setReady(false)
        let unresolved = await waitUntil { if case .unresolved = rig.runtime.lifecycle { return true }; return false }
        XCTAssertTrue(unresolved)
        let gate = Gate()
        defer { gate.open() }
        let slug = ClaudeCodeStrategy.projectSlug(forCwd: rig.cwd)
        Workspace.hostEndTranscriptFilesystem = {
            TranscriptDisk(present: ["/Users/tester/.claude/projects/\(slug)/\(rig.conversation).jsonl"], gate: gate)
        }
        rig.workspace.observePersistentRecovery(rig.panel)
        let auditing = await waitUntil { gate.hasWaiter }
        XCTAssertTrue(auditing)
        rig.fakes[1].setReady(true)
        let liveAgain = await waitUntil { rig.workspace.hcLiveAgentKind(panelId: rig.panel.id) != nil }
        XCTAssertTrue(liveAgain)
        let liveKind = try XCTUnwrap(rig.workspace.hcLiveAgentKind(panelId: rig.panel.id))
        gate.open()
        let decided = await waitUntil { rig.panel.plannedHCEndedKeys.contains(rig.first) }
        XCTAssertTrue(decided)
        XCTAssertNil(rig.panel.hcHostEnd, "the recovered live agent is not an old signal's resume candidate")
        XCTAssertEqual(rig.workspace.launchResumeOutcomes[rig.panel.id], .kept(agentKind: liveKind))
        XCTAssertTrue(rig.fakes[1].writers.allSatisfy { $0.received.isEmpty })
    }

    /// C11H-232: every end that is not an outside signal on an agent still reaches the close.
    func testAnExitTheStopKeysHcsOwnKillAndAPlainShellStillClose() async throws {
        let rig = try await rig(onDisk: true)
        defer { Task { @MainActor in await cleanUp(rig) } }
        func evidence(_ reason: String, code: Int32? = nil, signal: Int32? = nil) -> HCEndEvidence {
            HCEndEvidence(id: UUID(), key: rig.first, revision: HCRevision(connectionGeneration: 1, sequence: 900),
                          kind: .finished, hcReason: reason, exitCode: code, exitSignal: signal)
        }
        let agent = HCTerminalRecord(key: rig.first, state: .running, labels: [:], pid: 101,
                                     foreground: HCForeground(name: "claude", argv: ["claude"]))
        for (label, end) in [("clean exit", evidence("exited", code: 0)), ("exit 1", evidence("exited", code: 1)),
                             ("Ctrl-C", evidence("exited", signal: SIGINT)), ("Ctrl-\\", evidence("exited", signal: SIGQUIT)),
                             ("End Session", evidence("killed", signal: SIGHUP)), ("killed", evidence("killed", code: 1))] {
            XCTAssertFalse(rig.workspace.keepPanelAfterOutsideSignal(panelId: rig.panel.id, evidence: end, lastLive: agent), label)
        }
        XCTAssertNil(rig.panel.hcHostEnd)
        // A plain shell: no agent in front and no conversation.
        await ConversationStore.shared.clear(surfaceId: rig.panel.id.uuidString)
        let cleared = await waitUntil { ConversationStorePanelRefCache.shared.snapshot(surfaceId: rig.panel.id)?.active == nil }
        XCTAssertTrue(cleared)
        let shell = HCTerminalRecord(key: rig.first, state: .running, labels: [:], pid: 101,
                                     foreground: HCForeground(name: "zsh", argv: ["-zsh"]))
        XCTAssertFalse(rig.workspace.keepPanelAfterOutsideSignal(panelId: rig.panel.id,
            evidence: evidence("exited", signal: SIGKILL), lastLive: shell))
        // An agent in front with no conversation saved yet: nothing to resume, so it closes too.
        XCTAssertFalse(rig.workspace.keepPanelAfterOutsideSignal(panelId: rig.panel.id,
            evidence: evidence("exited", signal: SIGKILL), lastLive: agent))
        XCTAssertNil(rig.panel.hcHostEnd)
    }

    /// C11H-232 (Review 1 verification, finding 2): Resume is not offered while the transcript check that
    /// supplies the conversation's cwd is still running, however long it takes.
    func testResumeIsOfferedOnlyAfterTheTranscriptCheck() async throws {
        let rig = try await rig(onDisk: true)
        defer { Task { @MainActor in await cleanUp(rig) } }
        let gate = Gate()
        let slug = ClaudeCodeStrategy.projectSlug(forCwd: rig.cwd)
        let present: Set<String> = ["/Users/tester/.claude/projects/\(slug)/\(rig.conversation).jsonl"]
        Workspace.hostEndTranscriptFilesystem = { TranscriptDisk(present: present, gate: gate) }
        let end = HCEndEvidence(id: UUID(), key: rig.first, revision: HCRevision(connectionGeneration: 1, sequence: 902),
                                kind: .finished, hcReason: "exited", exitSignal: SIGTERM)
        XCTAssertTrue(rig.workspace.keepPanelAfterOutsideSignal(panelId: rig.panel.id, evidence: end, lastLive: nil))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rig.panel.hcHostEnd?.phase, .deciding, "held while the check runs")
        XCTAssertEqual(rig.panel.hcHostEnd?.offersResume, false, "the banner, strip and restore run offer nothing yet")
        XCTAssertEqual(rig.panel.hcHostEnd?.recordState, "pending")
        gate.open()
        let offered = await waitUntil { rig.panel.hcHostEnd?.offersResume == true }
        XCTAssertTrue(offered, "\(String(describing: rig.panel.hcHostEnd))")
        XCTAssertEqual(rig.panel.hcHostEnd?.conversation?.state, .suspended, "the checked ref, verified on disk")
        XCTAssertEqual(rig.fakes[1].creates, 1)
    }

    /// C11H-232 (Review 1 verification, finding 1): an outside signal found by the host-end recovery on a panel
    /// with no live conversation is an ordinary end: no signal record, and the child-exit path closes it.
    func testAnOutsideSignalWithNoLiveConversationGetsNoRecordAndCloses() async throws {
        let rig = try await rig(onDisk: true)
        defer { Task { @MainActor in await cleanUp(rig) } }
        await ConversationStore.shared.clear(surfaceId: rig.panel.id.uuidString)
        let cleared = await waitUntil { ConversationStorePanelRefCache.shared.snapshot(surfaceId: rig.panel.id)?.active == nil }
        XCTAssertTrue(cleared)
        rig.fakes[1].finish(rig.first, reason: "exited", signal: SIGKILL)
        let ended = await waitUntil { if case .ended = rig.runtime.lifecycle { return true }; return false }
        XCTAssertTrue(ended)
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(rig.panel.hcHostEnd, "no signal record without a live conversation")
        guard case .ended(let evidence) = rig.runtime.lifecycle else { return XCTFail("\(rig.runtime.lifecycle)") }
        XCTAssertFalse(rig.workspace.keepPanelAfterOutsideSignal(panelId: rig.panel.id, evidence: evidence,
                                                                 lastLive: rig.runtime.lastLiveRecord),
                       "a later child-exit pass closes it")
        XCTAssertEqual(rig.fakes[1].creates, 1)
    }

    /// C11H-232 (Review 1, finding 1): an end the child-exit path never sees (a hidden restored panel whose
    /// attachment never started, an end found at launch) is classified by the host-end recovery: offered with
    /// the signal's banner, never resumed unasked, resumed once on the operator's word.
    func testAnOutsideSignalWithNoChildExitCallbackIsOfferedNotResumed() async throws {
        let rig = try await rig(onDisk: true)
        defer { Task { @MainActor in await cleanUp(rig) } }
        XCTAssertNil(rig.runtime.onEnded, "no child-exit callback, as for a hidden restored panel")
        rig.fakes[1].finish(rig.first, reason: "exited", signal: SIGKILL)
        let decided = await waitUntil {
            if case .notResumed = rig.panel.hcHostEnd?.phase { return true }; return false
        }
        XCTAssertTrue(decided, "\(String(describing: rig.panel.hcHostEnd))")
        let status = try XCTUnwrap(rig.panel.visibleHCHostEnd)
        XCTAssertEqual(status.signal, SIGKILL)
        XCTAssertEqual(status.causeToken, "outside_signal")
        XCTAssertEqual(status.reasonToken, HCHostEndStatus.outsideSignalReason)
        XCTAssertTrue(status.offersResume)
        XCTAssertEqual(status.conversation?.id, rig.conversation)
        for _ in 0..<40 { rig.fakes[1].republish() }
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(rig.fakes[1].creates, 1, "no fresh terminal unasked")
        XCTAssertTrue(rig.fakes[1].writers.allSatisfy { $0.received.isEmpty }, "nothing typed")
        XCTAssertNil(rig.workspace.resumeDecisionCounts[rig.panel.id])

        XCTAssertNil(rig.workspace.resumeHostEndedConversation(panelId: rig.panel.id))
        let replaced = await waitUntil { rig.fakes[1].creates == 2 }
        XCTAssertTrue(replaced)
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        let typed = await waitUntil { !(rig.fakes[1].writers.last?.received.isEmpty ?? true) }
        XCTAssertTrue(typed)
        let text = String(decoding: rig.fakes[1].writers.last?.received ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("cd '\(rig.cwd)' && claude"), text)
        XCTAssertTrue(text.contains("--resume '\(rig.conversation)'"), text)
    }

    /// C11H-232: the record waits on the operator across a relaunch, and the relaunch's own child-exit pass
    /// keeps the panel without deciding the end again.
    func testAnOutsideSignalRecordSurvivesARelaunchDecidedOnce() async throws {
        let rig = try await rig(onDisk: true, capturedAt: Date(timeIntervalSince1970: 1_793_999_990))
        defer { Task { @MainActor in await cleanUp(rig) } }
        let end = HCEndEvidence(id: UUID(), key: rig.first, revision: HCRevision(connectionGeneration: 1, sequence: 901),
                                kind: .finished, hcReason: "exited", exitSignal: SIGTERM,
                                endedAtMilliseconds: 1_794_000_000_000)
        XCTAssertTrue(rig.workspace.keepPanelAfterOutsideSignal(panelId: rig.panel.id, evidence: end, lastLive: nil),
                      "the conversation alone is enough")
        let settled = await waitUntil { rig.panel.hcHostEnd?.offersResume == true }
        XCTAssertTrue(settled)
        let record = try XCTUnwrap(rig.panel.hcHostEnd)
        XCTAssertEqual(record.endedAt, end.endedAt)
        let saved = try XCTUnwrap(HCSavedHostEnd.capture(decided: rig.panel.plannedHCEndedKeys, record: record,
            relevant: [rig.first], found: [], unsettled: [], dismissedKey: nil))
        let decoded = try JSONDecoder().decode(HCSavedHostEnd.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.record, record)
        XCTAssertEqual(decoded.record?.signal, SIGTERM)
        XCTAssertEqual(decoded.decidedKeys, [rig.first])

        // The next launch: a fresh panel object takes the record back, then hc's finished record reaches it.
        let pane = try XCTUnwrap(rig.workspace.bonsplitController.allPaneIds.first)
        let next = try XCTUnwrap(rig.workspace.newTerminalSurface(inPane: pane, focus: false))
        next.surface.installHCSessionForTesting(rig.runtime)
        next.restoreSavedHostEnd(decoded)
        XCTAssertTrue(rig.workspace.keepPanelAfterOutsideSignal(panelId: next.id, evidence: end, lastLive: nil))
        XCTAssertEqual(next.hcHostEnd, record, "kept as it was, not decided again")
        XCTAssertTrue(next.visibleHCHostEnd?.offersResume == true)
    }

    /// Review 1: the operator's Resume conversation never lands on a half-typed command in a live fresh shell.
    func testTheOperatorsResumeRefusesAPromptWithSomethingTypedOnIt() async throws {
        let rig = try await rig(onDisk: false)
        defer { Task { @MainActor in await cleanUp(rig) } }
        rig.fakes[1].finish(rig.first, reason: "stopped_by_restart")
        let decided = await waitUntil { rig.panel.hcHostEnd?.offersResume == true }
        XCTAssertTrue(decided)
        // The operator opens the panel: a fresh shell, at its prompt, with a command typed and not run.
        try await rig.panel.surface.startHostEndReplacement()
        let live = await waitUntil { if case .live = rig.runtime.lifecycle { return true }; return false }
        XCTAssertTrue(live)
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .commandRunning)
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        rig.panel.surface.lastOperatorKeyAt = Date().addingTimeInterval(1)
        XCTAssertNotNil(rig.workspace.resumeHostEndedConversation(panelId: rig.panel.id), "refused: something is typed")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(rig.fakes[1].writers.last?.received, Data(), "nothing typed onto the draft")
        // An empty Return redraws the prompt (a repeated idle report, no state change): it is empty
        // again, and the resume goes in once.
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        XCTAssertNil(rig.workspace.resumeHostEndedConversation(panelId: rig.panel.id))
        let typed = await waitUntil { !(rig.fakes[1].writers.last?.received.isEmpty ?? true) }
        XCTAssertTrue(typed)
        let text = String(decoding: rig.fakes[1].writers.last?.received ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains("--resume '\(rig.conversation)'"), text)
    }

    /// Never typed into a live agent: an agent in the fresh terminal's foreground holds the resume.
    func testAnAgentAlreadyRunningInTheFreshTerminalIsNeverTypedInto() async throws {
        let rig = try await rig(onDisk: true)
        defer { Task { @MainActor in await cleanUp(rig) } }
        rig.fakes[1].finish(rig.first, reason: "holder_lost")
        let replaced = await waitUntil { rig.fakes[1].creates == 2 }
        XCTAssertTrue(replaced)
        guard case .live(let fresh) = rig.runtime.lifecycle else { return XCTFail("\(rig.runtime.lifecycle)") }
        rig.fakes[1].setAgent(fresh.key, status: "idle")
        let seen = await waitUntil { rig.workspace.hcLiveAgentKind(panelId: rig.panel.id) != nil }
        XCTAssertTrue(seen)
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rig.fakes[1].writers.last?.received, Data(), "nothing typed into the running agent")
    }

    // MARK: C11H-203, the re-review's findings

    /// A hidden, launch-scoped host end while the operator is asked (Ask at launch).
    private func askingRig() async throws -> Rig {
        let rig = try await rig(onDisk: true)
        // Let the live terminal's first observation spend its startup check, then mark it the way the
        // snapshot restore does, so the end below is this launch's startup resolution.
        try? await Task.sleep(nanoseconds: 150_000_000)
        rig.workspace.markLaunchRestoredForTesting(rig.panel.id)
        LaunchResumeGate.shared.begin(asking: true)
        LaunchResumeGate.shared.releaseStagger = 0
        rig.fakes[1].finish(rig.first, reason: "stopped_by_restart")
        for _ in 0..<5 { rig.fakes[1].republish() }
        return rig
    }

    private func resetGate() {
        LaunchResumeGate.shared.begin(asking: false)
        LaunchResumeGate.shared.releaseStagger = SessionPersistencePolicy.agentRestartStagger
    }

    /// Finding 1: no fresh terminal starts while the operator is asked. Not now leaves the panel ended (its resume is
    /// offered again after a relaunch) with Resume conversation, instead of a bare shell that owes a resume.
    func testWhileAskingNoFreshTerminalStartsAndNotNowLeavesThePanelEnded() async throws {
        let rig = try await askingRig()
        defer { resetGate(); Task { @MainActor in await cleanUp(rig) } }
        let held = await waitUntil { LaunchResumeGate.shared.held.contains { $0.id == rig.panel.id } }
        XCTAssertTrue(held, "\(String(describing: rig.panel.hcHostEnd))")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rig.fakes[1].creates, 1, "no fresh terminal while asking")
        XCTAssertEqual(rig.panel.hcHostEnd?.phase, .queued)
        LaunchResumeGate.shared.decline()
        let declined = await waitUntil { rig.panel.hcHostEnd?.offersResume == true }
        XCTAssertTrue(declined, "\(String(describing: rig.panel.hcHostEnd))")
        XCTAssertNil(rig.panel.pendingHCConversationRecovery)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(rig.fakes[1].creates, 1, "Not now starts nothing")
        if case .ended = rig.runtime.lifecycle {} else { XCTFail("still ended: \(rig.runtime.lifecycle)") }
    }

    /// Finding 1: Resume all starts the held fresh terminal and types the resume once, without asking again.
    func testResumeAllAfterAskingStartsTheFreshTerminalAndResumesOnce() async throws {
        let rig = try await askingRig()
        defer { resetGate(); Task { @MainActor in await cleanUp(rig) } }
        let held = await waitUntil { LaunchResumeGate.shared.held.contains { $0.id == rig.panel.id } }
        XCTAssertTrue(held)
        LaunchResumeGate.shared.resumeAll()
        let replaced = await waitUntil { rig.fakes[1].creates == 2 }
        XCTAssertTrue(replaced, "\(rig.runtime.lifecycle)")
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        let typed = await waitUntil { rig.panel.hcHostEnd?.phase == .resumed }
        XCTAssertTrue(typed, "chosen once, not asked again: \(String(describing: rig.panel.hcHostEnd))")
        let text = String(decoding: rig.fakes[1].writers.last?.received ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains("--resume '\(rig.conversation)'"), text)
        for _ in 0..<10 { rig.fakes[1].republish() }
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(String(decoding: rig.fakes[1].writers.last?.received ?? Data(), as: UTF8.self), text, "once")
        XCTAssertEqual(rig.fakes[1].creates, 2)
    }

    /// Review 2: queue-bound resumes are released together (the queue orders and spaces them); others keep the
    /// gate's spacing.
    func testResumeAllReleasesQueueBoundResumesTogether() async {
        let gate = LaunchResumeGate()
        gate.begin(asking: true)
        gate.releaseStagger = 30
        var ran: [String] = []
        for name in ["c", "b"] {
            _ = gate.intercept(panelID: UUID(), workspaceTitle: "W", panelTitle: name,
                               run: { ran.append(name) }, spaced: false)
        }
        _ = gate.intercept(panelID: UUID(), workspaceTitle: "W", panelTitle: "a",
                           run: { ran.append("a") })
        _ = gate.intercept(panelID: UUID(), workspaceTitle: "W", panelTitle: "z",
                           run: { ran.append("z") })
        gate.resumeAll()
        let released = await waitUntil { ran.count >= 3 }
        XCTAssertTrue(released, "\(ran)")
        XCTAssertEqual(Set(ran.prefix(2)), ["b", "c"], "queue-bound first, together")
        XCTAssertEqual(ran.count, 3, "the second spaced resume waits its stagger: \(ran)")
    }

    /// Review 2: a held resume that no longer stands leaves the question (End All Sessions here), and Resume all
    /// then starts nothing for it.
    func testAHeldResumeEndedOnPurposeLeavesTheQuestion() async throws {
        let rig = try await askingRig()
        defer { resetGate(); Task { @MainActor in await cleanUp(rig) } }
        let held = await waitUntil { LaunchResumeGate.shared.held.contains { $0.id == rig.panel.id } }
        XCTAssertTrue(held)
        rig.workspace.prepareForEndAllSessions([rig.panel.id])
        XCTAssertFalse(LaunchResumeGate.shared.held.contains { $0.id == rig.panel.id }, "not offered any more")
        LaunchResumeGate.shared.resumeAll()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rig.fakes[1].creates, 1)
    }

    /// Review 2: the operator's own Resume conversation, made while the launch question is open, answers to them:
    /// Not now does not cancel it.
    func testTheOperatorsResumeIsNotCancelledByNotNow() async throws {
        let rig = try await askingRig()
        defer { resetGate(); Task { @MainActor in await cleanUp(rig) } }
        let held = await waitUntil { LaunchResumeGate.shared.held.contains { $0.id == rig.panel.id } }
        XCTAssertTrue(held)
        XCTAssertNil(rig.workspace.resumeHostEndedConversation(panelId: rig.panel.id))
        let planned = await waitUntil { rig.panel.pendingHCConversationRecovery?.launchScoped == false }
        XCTAssertTrue(planned, "\(String(describing: rig.panel.pendingHCConversationRecovery))")
        XCTAssertFalse(LaunchResumeGate.shared.held.contains { $0.id == rig.panel.id })
        LaunchResumeGate.shared.decline()
        let replaced = await waitUntil { rig.fakes[1].creates == 2 }
        XCTAssertTrue(replaced, "\(String(describing: rig.panel.hcHostEnd))")
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        let typed = await waitUntil { rig.panel.hcHostEnd?.phase == .resumed }
        XCTAssertTrue(typed, "\(String(describing: rig.panel.hcHostEnd))")
    }

    /// Finding 4, the socket route: `c11 send --no-submit` text that arrived is a draft; a refused send, a send with
    /// Return and an empty body are not.
    func testOnlyArrivedSocketTextWithoutReturnIsADraft() async throws {
        let rig = try await rig(onDisk: true)
        defer { Task { @MainActor in await cleanUp(rig) } }
        let surface = rig.panel.surface
        let receipt = HCWriteReceipt(operationID: UUID(), attachmentGeneration: 0, bodyBytesWritten: 2, returnWritten: false)
        surface.lastOperatorKeyAt = nil
        surface.noteHCSocketSend(body: "ls", wantsReturn: true, outcome: .written(receipt))
        surface.noteHCSocketSend(body: "", wantsReturn: false, outcome: .written(receipt))
        surface.noteHCSocketSend(body: "ls", wantsReturn: false, outcome: .refused(.guardRefused))
        XCTAssertNil(surface.lastOperatorKeyAt)
        surface.noteHCSocketSend(body: "ls", wantsReturn: false, outcome: .written(receipt))
        XCTAssertNotNil(surface.lastOperatorKeyAt)
        // Review 2: the shared hc input path never stamps by itself, so a key (Ctrl-C into a headless terminal,
        // sent through it by `send-key`) is not a draft.
        surface.lastOperatorKeyAt = nil
        _ = await surface.submitHCInput("\u{3}", submit: false, source: .socket)
        XCTAssertNil(surface.lastOperatorKeyAt, "a key is not a draft")
    }

    /// Finding 2: an idle report and inventory revisions arriving together start one submission; the record never
    /// shows a failure on its way to resumed.
    func testTriggersArrivingTogetherSubmitOnceAndNeverShowAFailure() async throws {
        let rig = try await rig(onDisk: true)
        defer { Task { @MainActor in await cleanUp(rig) } }
        var phases: [HCHostEndStatus.Phase] = []
        let watch = rig.panel.$hcHostEnd.sink { if let phase = $0?.phase { phases.append(phase) } }
        defer { watch.cancel() }
        rig.fakes[1].finish(rig.first, reason: "stopped_by_restart")
        let replaced = await waitUntil {
            if case .resuming = rig.panel.hcHostEnd?.phase { return rig.fakes[1].creates == 2 }; return false
        }
        XCTAssertTrue(replaced, "\(String(describing: rig.panel.hcHostEnd))")
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        for _ in 0..<6 { rig.fakes[1].republish() }
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        let done = await waitUntil { rig.panel.hcHostEnd?.phase == .resumed }
        XCTAssertTrue(done, "\(String(describing: rig.panel.hcHostEnd))")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(phases.contains { if case .failed = $0 { return true }; return false }, "\(phases)")
        XCTAssertEqual(rig.panel.hcHostEnd?.phase, .resumed)
    }

    /// Finding 3: a conversation that changed before typing ends the plan; later prompts retry nothing.
    func testAConversationThatChangedBeforeTypingEndsThePlan() async throws {
        let rig = try await rig(onDisk: true)
        defer { Task { @MainActor in await cleanUp(rig) } }
        rig.fakes[1].finish(rig.first, reason: "stopped_by_restart")
        let replaced = await waitUntil {
            if case .resuming = rig.panel.hcHostEnd?.phase { return rig.fakes[1].creates == 2 }; return false
        }
        XCTAssertTrue(replaced)
        // The panel's saved conversation is gone by the time its turn comes.
        await ConversationStore.shared.clear(surfaceId: rig.panel.id.uuidString)
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        let failed = await waitUntil { if case .failed = rig.panel.hcHostEnd?.phase { return true }; return false }
        XCTAssertTrue(failed, "\(String(describing: rig.panel.hcHostEnd))")
        XCTAssertNil(rig.panel.pendingHCConversationRecovery, "final: no plan left to retry")
        XCTAssertEqual(rig.fakes[1].writers.last?.received, Data(), "nothing typed")
    }

    /// Finding 4: text sent without a Return into the fresh shell before its turn is a draft; the resume is not
    /// appended to it.
    func testASendWithoutReturnBeforeTheResumeIsADraftNotAPrefix() async throws {
        let rig = try await rig(onDisk: true)
        defer { Task { @MainActor in await cleanUp(rig) } }
        rig.fakes[1].finish(rig.first, reason: "stopped_by_restart")
        let replaced = await waitUntil {
            if case .resuming = rig.panel.hcHostEnd?.phase { return rig.fakes[1].creates == 2 }; return false
        }
        XCTAssertTrue(replaced)
        rig.panel.surface.sendText("echo half")
        let drafted = await waitUntil { rig.fakes[1].writers.last?.received == Data("echo half".utf8) }
        XCTAssertTrue(drafted)
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        let said = await waitUntil { if case .notResumed = rig.panel.hcHostEnd?.phase { return true }; return false }
        XCTAssertTrue(said, "\(String(describing: rig.panel.hcHostEnd))")
        XCTAssertEqual(rig.fakes[1].writers.last?.received, Data("echo half".utf8), "nothing appended to the draft")
        XCTAssertTrue(rig.panel.hcHostEnd?.offersResume == true)
    }

    /// C11H-206: on a loaded Mac hc's inventory lists a new terminal after its create answers. The start waits for
    /// the listing (found by creation id, never creating twice), attaches, and the resume is typed once.
    func testAFreshTerminalListedLateStillAttachesAndResumesOnce() async throws {
        try await lateListedTerminalResumesOnce(reason: .inventoryPending)
    }

    /// C11H-206 review: the create's confirming refresh timed out after hc ran the terminal.
    func testAFreshTerminalWhoseCreateTimedOutStillAttachesAndResumesOnce() async throws {
        try await lateListedTerminalResumesOnce(reason: .deadlineExceeded)
    }

    private func lateListedTerminalResumesOnce(reason: HCUnavailableReason) async throws {
        let savedPoll = HCPanelSession.creationListingPollNanoseconds
        HCPanelSession.creationListingPollNanoseconds = 20_000_000
        defer { HCPanelSession.creationListingPollNanoseconds = savedPoll }
        let rig = try await rig(onDisk: true)
        defer { Task { @MainActor in await cleanUp(rig) } }
        rig.fakes[1].listCreatesAfter = 4
        rig.fakes[1].pendingCreateReason = reason
        rig.fakes[1].finish(rig.first, reason: "stopped_by_restart")
        let live = await waitUntil {
            if case .live(let record) = rig.runtime.lifecycle { return record.key != rig.first }; return false
        }
        XCTAssertTrue(live, "the late-listed terminal is adopted: \(rig.runtime.lifecycle)")
        XCTAssertEqual(rig.fakes[1].creates, 2, "one fresh terminal, not one per lookup")
        rig.workspace.updatePanelShellActivityState(panelId: rig.panel.id, state: .promptIdle)
        let typed = await waitUntil { rig.panel.hcHostEnd?.phase == .resumed }
        XCTAssertTrue(typed, "\(String(describing: rig.panel.hcHostEnd))")
        let text = String(decoding: rig.fakes[1].writers.last?.received ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains("--resume '\(rig.conversation)'"), text)
        XCTAssertEqual(rig.fakes[1].creates, 2)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, _ seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if condition() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }
}

/// C11H-196: the staggered queue, on a fake clock.
@MainActor
final class HCHostEndResumeQueueTests: XCTestCase {
    private final class Clock { var now: UInt64 = 0 }

    private func queue(interval: TimeInterval = 1.5, maxInFlight: Int = 3, slotTimeout: TimeInterval = 3600,
                       clock: Clock) -> HCHostEndResumeQueue {
        let queue = HCHostEndResumeQueue(interval: interval, maxInFlight: maxInFlight, slotTimeout: slotTimeout)
        queue.settle = 0
        queue.now = { clock.now }
        queue.sleep = { nanoseconds in clock.now &+= nanoseconds; try? await Task.sleep(nanoseconds: 1_000_000) }
        return queue
    }

    private let key = HCTerminalKey(owningCoreID: "c", localAddress: "t")

    func testShownPanelsGoFirstThenHiddenInOrderOneAdmissionPerInterval() async {
        let clock = Clock()
        let q = queue(clock: clock)
        var order: [String] = []
        var times: [UInt64] = []
        func add(_ name: String, _ priority: HCHostEndResumeQueue.Priority) {
            let id = UUID()
            q.enqueue(panelID: id, endedKey: key, priority: priority, admit: {
                order.append(name); times.append(clock.now); q.finished(panelID: id)
            }, abandon: { _ in XCTFail("abandoned \(name)") })
        }
        add("hidden-1", .hidden); add("hidden-2", .hidden); add("shown", .shown); add("operator", .operatorRequest)
        add("hidden-3", .hidden)
        let done = await waitUntil { order.count == 5 }
        XCTAssertTrue(done)
        XCTAssertEqual(order, ["operator", "shown", "hidden-1", "hidden-2", "hidden-3"])
        for (a, b) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 1_500_000_000, "spaced by the interval")
        }
    }

    /// Hidden panels go most recently active first; one with no activity known goes last.
    /// A batch starting from idle waits `settle`, so decisions landing together are ordered together.
    func testHiddenPanelsGoMostRecentlyActiveFirstAfterTheSettle() async {
        let clock = Clock()
        let q = queue(interval: 0, clock: clock)
        q.settle = 1
        var order: [String] = []
        let now = Date()
        for (name, activity) in [("unknown", nil), ("old", now.addingTimeInterval(-3600)), ("recent", now),
                                 ("middle", now.addingTimeInterval(-60))] as [(String, Date?)] {
            let id = UUID()
            q.enqueue(panelID: id, endedKey: key, priority: .hidden, activity: activity,
                      admit: { order.append(name); q.finished(panelID: id) }, abandon: { _ in })
        }
        let done = await waitUntil { order.count == 4 }
        XCTAssertTrue(done)
        XCTAssertEqual(order, ["recent", "middle", "old", "unknown"])
        XCTAssertGreaterThanOrEqual(clock.now, 1_000_000_000, "the first admission waited for the settle")
    }

    func testAtMostMaxInFlightUntilOneFinishesOrTimesOut() async {
        let clock = Clock()
        let q = queue(interval: 0, maxInFlight: 2, clock: clock)
        var admitted: [UUID] = []
        let ids = (0..<3).map { _ in UUID() }
        for id in ids {
            q.enqueue(panelID: id, endedKey: key, priority: .hidden, admit: { admitted.append(id) }, abandon: { _ in })
        }
        let two = await waitUntil { admitted.count == 2 }
        XCTAssertTrue(two)
        XCTAssertEqual(admitted.count, 2, "the third waits for a slot")
        q.finished(panelID: ids[0])
        let three = await waitUntil { admitted.count == 3 }
        XCTAssertTrue(three)
    }

    /// Review 2: a start that never returns holds only its own slot. After the
    /// slot timeout it is reported stalled and the queue moves on.
    func testAHungStartNeverHoldsTheQueue() async {
        let clock = Clock()
        let q = queue(interval: 0, maxInFlight: 1, slotTimeout: 2, clock: clock)
        var stalled: [String] = []
        var admitted: [String] = []
        q.enqueue(panelID: UUID(), endedKey: key, priority: .hidden, admit: {
            admitted.append("hung")
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }, abandon: { stalled.append($0) })
        let next = UUID()
        q.enqueue(panelID: next, endedKey: key, priority: .hidden, admit: {
            admitted.append("next"); q.finished(panelID: next)
        }, abandon: { _ in XCTFail("the next one is not abandoned") })
        let moved = await waitUntil({ admitted == ["hung", "next"] }, 5)
        XCTAssertTrue(moved, "\(admitted)")
        XCTAssertEqual(stalled, [HCHostEndResumeQueue.stalledReason])
    }

    func testAFailedStartIsRetriedThenAbandonedNeverReDecided() async {
        let clock = Clock()
        let q = queue(interval: 0, clock: clock)
        var attempts = 0
        var abandoned: String?
        q.enqueue(panelID: UUID(), endedKey: key, priority: .hidden, admit: {
            attempts += 1; throw HCUnavailableReason.cancelled
        }, abandon: { abandoned = $0 })
        let gaveUp = await waitUntil { abandoned != nil }
        XCTAssertTrue(gaveUp)
        XCTAssertEqual(attempts, 3)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, _ seconds: Double = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if condition() { return true }; try? await Task.sleep(nanoseconds: 5_000_000) }
        return condition()
    }
}

/// C11H-196: the "terminal host stopped" notice clears once a replacement is live.
final class HCRestoreNoticeTests: XCTestCase {
    func testTheHostStoppedNoticeClearsWhenAReplacementIsLive() {
        let key = HCTerminalKey(owningCoreID: "c", localAddress: "t1")
        let ended = HCLifecycle.ended(HCEndEvidence(id: UUID(), key: key, revision: HCRevision(connectionGeneration: 1, sequence: 1),
                                                    kind: .finished, hcReason: "stopped_by_restart"))
        let notice = HCRestoreLifecycleProjection.notice(for: ended)
        XCTAssertEqual(notice, .holderLost)
        let live = HCLifecycle.live(HCTerminalRecord(key: HCTerminalKey(owningCoreID: "c", localAddress: "t2"), state: .running, pid: 9))
        XCTAssertNil(HCRestoreLifecycleProjection.notice(for: live, retaining: notice))
        XCTAssertEqual(HCRestoreLifecycleProjection.notice(for: live, retaining: notice, hostEndCovered: false),
                       .previousSessionEnded, "with no host-end record the shell says the previous session ended")
        XCTAssertFalse(HCRestoreLifecycleProjection.Notice.previousSessionEnded.message.contains("kept for recovery"))
    }

    /// C11H-205: panel 408 said "The terminal host stopped and ended this
    /// session" for a day while its resumed agent answered. A live terminal
    /// never says its session ended: with no host-end record covering it, it
    /// says the previous session ended and this is a new shell.
    @MainActor
    func testALivePanelNeverSaysItsSessionEndedWithoutAHostEndRecord() throws {
        try withRestoredPanel { workspace, panel, runtime, id, oldKey in
            runtime.publish(.ended(HCEndEvidence(id: UUID(), key: oldKey, revision: HCRevision(connectionGeneration: 1, sequence: 1),
                                                 kind: .finished, hcReason: "host_shutdown")))
            XCTAssertEqual(panel.hcRestoreNotice, .holderLost, "an ended terminal explains its end")
            // Agent resume off, or a no-resume launch: no host-end record covers it.
            panel.hcHostEnd = nil
            let replacement = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "owned", localAddress: "t16"), state: .running,
                                               labels: ["c11.panel": id.uuidString], pid: 289)
            runtime.publish(.live(replacement))
            XCTAssertEqual(panel.hcRestoreNotice, .previousSessionEnded,
                           "a live replacement is a new session; the notice says the previous one ended")
            runtime.publish(.live(replacement))
            XCTAssertEqual(panel.hcRestoreNotice, .previousSessionEnded, "an unchanged inventory keeps it")
            panel.dismissHCRestoreNotice()
            runtime.publish(.live(replacement))
            XCTAssertNil(panel.hcRestoreNotice, "a dismissal holds across inventory updates")
        }
    }

    /// C11H-205: the banner's end comes from hc's own end time, both while the
    /// panel is ended and once a replacement carries the end it replaced.
    func testTheHostEndRecordTakesHcsEndTime() {
        let key = HCTerminalKey(owningCoreID: "owned", localAddress: "t3")
        let end = HCEndEvidence(id: UUID(), key: key, revision: HCRevision(connectionGeneration: 1, sequence: 1),
                                kind: .finished, hcReason: "holder_lost", endedAtMilliseconds: 1_793_800_000_000)
        let at = Date(timeIntervalSince1970: 1_793_800_000)
        XCTAssertEqual(Workspace.hostEndEvidence(lifecycle: .ended(end), creation: nil)?.endedAt, at)
        let replacement = HCCreationProvenance(creationID: UUID(), replaces: end, outcome: .bound,
            boundKey: HCTerminalKey(owningCoreID: "owned", localAddress: "t16"))
        let live = HCLifecycle.live(HCTerminalRecord(key: HCTerminalKey(owningCoreID: "owned", localAddress: "t16"),
                                                     state: .running, pid: 289))
        XCTAssertEqual(Workspace.hostEndEvidence(lifecycle: live, creation: replacement)?.endedAt, at)
        XCTAssertEqual(Workspace.hostEndReason(lifecycle: live, creation: replacement), "holder_lost")
    }

    /// C11H-205: closing a panel whose session already ended (kept after a
    /// host end) has no session to end, so it takes the plain close, not
    /// "End session? ... ends its terminal session and every process".
    @MainActor
    func testClosingAPanelWhoseSessionEndedDoesNotPromiseToEndIt() throws {
        try withRestoredPanel { workspace, panel, runtime, id, oldKey in
            runtime.publish(.live(HCTerminalRecord(key: oldKey, state: .running, labels: ["c11.panel": id.uuidString], pid: 7)))
            XCTAssertTrue(workspace.closeEndsHCSession(panelIds: [id]), "a live session ends on close")
            runtime.publish(.ended(HCEndEvidence(id: UUID(), key: oldKey, revision: HCRevision(connectionGeneration: 1, sequence: 2),
                                                 kind: .finished, hcReason: "holder_lost")))
            XCTAssertFalse(workspace.closeEndsHCSession(panelIds: [id]), "an ended session has nothing left to end")
            XCTAssertTrue(workspace.panelNeedsConfirmClose(panelId: id, fallbackNeedsConfirmClose: false),
                          "it still asks: the panel may hold a recovery offer")
            XCTAssertTrue(workspace.closeHoldsHCSession(panelIds: [id]), "its close still sends hc the end request")
        }
    }

    /// C11H-209: a skipped resume (declined at Ask, a no-resume launch, a
    /// failure) used to be decided again at the next launch and resume by
    /// itself, its cause flipping to "host stopped". A settled record is saved
    /// with its panel; the relaunch shows the same record and Resume offer,
    /// and its ended key is already decided.
    @MainActor
    func testASettledHostEndIsKeptAcrossARelaunchAndNeverDecidedAgain() throws {
        let conversation = ConversationRef(kind: "claude-code", id: "1c9b6374-0000-4000-8000-000000000408",
                                           capturedVia: .wrapperClaim, state: .alive)
        let restartAt = Date(timeIntervalSince1970: 1_793_800_000)
        var saved: SessionWorkspaceSnapshot?
        var panelID: UUID?
        var record: HCHostEndStatus?
        try withRestoredPanel { workspace, panel, _, id, oldKey in
            panelID = id
            panel.plannedHCEndedKeys.insert(oldKey)
            panel.hcHostEnd = HCHostEndStatus(endedKey: oldKey, cause: .restart(at: restartAt),
                phase: .notResumed(reason: "you chose not to resume it at launch."), conversation: conversation)
            record = panel.hcHostEnd
            saved = workspace.sessionSnapshot(includeScrollback: false)
        }
        // Through JSON, as the session file carries it.
        let data = try JSONEncoder().encode(try XCTUnwrap(saved))
        let snapshot = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        let id = try XCTUnwrap(panelID)
        let workspace = Workspace(restoringSession: true)
        defer {
            workspace.retireForSessionRestore()
            HCPanelRestoreState.shared.remove(panelID: id)
        }
        workspace.restoreSessionSnapshot(snapshot)
        let panel = try XCTUnwrap(workspace.panels[id] as? TerminalPanel)
        let restored = try XCTUnwrap(panel.hcHostEnd, "the relaunch shows the record the quit left")
        XCTAssertEqual(restored, record)
        XCTAssertEqual(restored.cause, .restart(at: restartAt), "its cause stays the Mac restart")
        XCTAssertTrue(restored.offersResume, "Resume conversation is still offered")
        XCTAssertNotNil(panel.visibleHCHostEnd)
        XCTAssertTrue(panel.plannedHCEndedKeys.contains(restored.endedKey), "that end is never decided again")
    }

    /// C11H-209: only settled outcomes are kept. A resume still deciding,
    /// queued, starting or typing when c11 quits (a reboot in the middle of a
    /// restore) is decided again, and resumed, by the next launch. Only a record
    /// still waiting on the operator comes back: a resumed or dismissed one
    /// keeps just its decided key. Keys the panel can no longer resolve are
    /// dropped. A record the next build cannot read never loses the panel.
    func testOnlySettledHostEndOutcomesAreKept() throws {
        let key = HCTerminalKey(owningCoreID: "owned", localAddress: "t3")
        let older = HCTerminalKey(owningCoreID: "owned", localAddress: "t1")
        let gone = HCTerminalKey(owningCoreID: "owned", localAddress: "t0")
        let at = Date(timeIntervalSince1970: 1_793_800_000)
        let conversation = ConversationRef(kind: "claude-code", id: "1c9b6374-0000-4000-8000-000000000408",
                                           capturedVia: .wrapperClaim, state: .alive)
        let queued = HCHostEndStatus(endedKey: key, cause: .restart(at: at), phase: .queued, conversation: conversation)
        XCTAssertNil(HCSavedHostEnd.capture(decided: [key], record: queued, relevant: [key], found: [key],
                                            unsettled: [key], dismissedKey: nil),
                     "a reboot during its resume still resumes it at the next launch")
        let beside = try XCTUnwrap(HCSavedHostEnd.capture(decided: [key, older, gone], record: queued,
            relevant: [key, older], found: [key], unsettled: [key], dismissedKey: nil))
        XCTAssertEqual(beside.decidedKeys, [older], "an unsettled end is left out; a key the panel lost is dropped")
        XCTAssertEqual(beside.foundEndedKeys, [])
        XCTAssertNil(beside.record)

        let failed = HCHostEndStatus(endedKey: key, cause: .hostStopped(at: at),
                                     phase: .failed(reason: "its fresh terminal did not reach a prompt in time."),
                                     conversation: conversation)
        let offered = try XCTUnwrap(HCSavedHostEnd.capture(decided: [key], record: failed, relevant: [key],
                                                           found: [key], unsettled: [], dismissedKey: nil))
        XCTAssertEqual(offered.record, failed, "a failed resume still offers Resume after the relaunch")
        XCTAssertEqual(offered.decidedKeys, [key])
        XCTAssertEqual(offered.foundEndedKeys, [], "a decided end is not also an undecided one")
        for settled in [failed, HCHostEndStatus(endedKey: key, cause: .restart(at: at), phase: .resumed, conversation: conversation)] {
            let dismissed = settled.phase == .resumed ? nil : key
            let kept = try XCTUnwrap(HCSavedHostEnd.capture(decided: [], record: settled, relevant: [key],
                                                            found: [], unsettled: [], dismissedKey: dismissed))
            XCTAssertNil(kept.record, "\(settled.stateToken): no record, so no banner or strip row")
            XCTAssertEqual(kept.decidedKeys, [key], "\(settled.stateToken): still never decided again")
        }

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(offered)) as? [String: Any])
        var recordObject = try XCTUnwrap(object["record"] as? [String: Any])
        recordObject["phase"] = "queued"
        object["record"] = recordObject
        let decoded = try JSONDecoder().decode(HCSavedHostEnd.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.record, "an unsettled or unknown phase is not restored")
        XCTAssertEqual(decoded.decidedKeys, [key])
        // A value of the wrong shape (a future schema) decodes as nothing kept.
        let terminal = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self,
            from: Data(#"{"workingDirectory":"/fixture","hcHostEnd":"later"}"#.utf8))
        XCTAssertEqual(terminal.workingDirectory, "/fixture")
        XCTAssertEqual(terminal.hcHostEnd, HCSavedHostEnd(decidedKeys: [], record: nil))
    }

    /// C11H-205 decision 2: h10's first launch resumed four agents that had
    /// ended under h8 and sat ended through that whole session. An end the
    /// previous session found and planned nothing for is saved as found, and
    /// the next launch offers it; End All's ends are decided and never offered.
    func testAnEndThePreviousSessionFoundAndLeftIsOfferedNotResumed() throws {
        let key = HCTerminalKey(owningCoreID: "owned", localAddress: "t3")
        let found = try XCTUnwrap(HCSavedHostEnd.capture(decided: [], record: nil, relevant: [key],
                                                         found: [key], unsettled: [], dismissedKey: nil))
        XCTAssertEqual(found.foundEndedKeys, [key])
        XCTAssertEqual(found.decidedKeys, [])
        let endedOnPurpose = try XCTUnwrap(HCSavedHostEnd.capture(decided: [], record: nil, relevant: [key],
            found: [key], unsettled: [], dismissedKey: nil, endedOnPurpose: [key]))
        XCTAssertEqual(endedOnPurpose.decidedKeys, [key], "End All: never resumed or offered at the next launch")
        XCTAssertEqual(endedOnPurpose.foundEndedKeys, [])
        XCTAssertNil(HCSavedHostEnd.capture(decided: [], record: nil, relevant: [key], found: [key],
                                            unsettled: [key], dismissedKey: nil),
                     "an end whose resume is underway is the next launch's to resume")
    }

    /// C11H-209: an offer carried over from an earlier launch is listed but
    /// never brings up the restore strip by itself ("Restored 0 of 3").
    @MainActor
    func testACarriedOverOfferNeverBringsUpTheRestoreStrip() {
        let progress = HCRestoreProgress()
        let key = HCTerminalKey(owningCoreID: "owned", localAddress: "t3")
        let conversation = ConversationRef(kind: "claude-code", id: "1c9b6374-0000-4000-8000-000000000408",
                                           capturedVia: .wrapperClaim, state: .alive)
        let offer = HCHostEndStatus(endedKey: key, cause: .restart(at: Date()), phase: .notResumed(reason: "x"),
                                    conversation: conversation)
        progress.update(panelID: UUID(), workspaceID: UUID(), status: offer, carried: true)
        XCTAssertNil(progress.headline)
        XCTAssertEqual(progress.needingYou.count, 1, "still listed for Details and restore status")
        progress.update(panelID: UUID(), workspaceID: UUID(), status: offer)
        XCTAssertNotNil(progress.headline, "an end this launch decided brings it up")
        XCTAssertEqual(progress.stripSummary.total, 1, "and the strip counts only this launch's")
    }

    @MainActor
    private func withRestoredPanel(
        _ body: (Workspace, TerminalPanel, HCPanelSession, UUID, HCTerminalKey) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let id = UUID()
        let oldKey = HCTerminalKey(owningCoreID: "owned", localAddress: "t3")
        let panelSnapshot = SessionPanelSnapshot(id: id, type: .terminal, title: "Fixture", customTitle: nil,
            directory: "/fixture", isPinned: false, isManuallyUnread: false,
            gitBranch: nil, listeningPorts: [], ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: "/fixture", scrollback: nil,
                hcIdentity: HCPanelIdentity(panelID: id, key: oldKey)),
            browser: nil, markdown: nil)
        let snapshot = SessionWorkspaceSnapshot(id: UUID(), processTitle: "Fixture", customTitle: nil,
            customColor: nil, isPinned: false, currentDirectory: "/fixture", focusedPanelId: id,
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: [id], selectedPanelId: id)),
            panels: [panelSnapshot], statusEntries: [], logEntries: [], progress: nil, gitBranch: nil)
        let workspace = Workspace(restoringSession: true)
        defer {
            workspace.retireForSessionRestore()
            HCPanelRestoreState.shared.remove(panelID: id)
        }
        workspace.restoreSessionSnapshot(snapshot)
        let panel = try XCTUnwrap(workspace.panels[id] as? TerminalPanel)
        let runtime = try XCTUnwrap(panel.hcSession)
        try body(workspace, panel, runtime, id, oldKey)
    }

    /// Review 3: Not now (or a subset) is reported to each resume it leaves out.
    @MainActor
    func testTheAskGateReportsEveryResumeItDrops() async {
        let gate = LaunchResumeGate()
        gate.begin(asking: true)
        var dropped: [String] = []
        for name in ["a", "b", "c"] {
            await gate.submit(panelID: UUID(), workspaceTitle: "W", panelTitle: name, launchScoped: true,
                              dropped: { dropped.append(name) }, perform: { XCTFail("parked, never run") })
        }
        let keep = Set(gate.held.filter { $0.panelTitle == "b" }.map(\.id))
        gate.releaseStagger = 0
        gate.resume(only: keep)
        XCTAssertEqual(dropped.sorted(), ["a", "c"])
        await gate.submit(panelID: UUID(), workspaceTitle: "W", panelTitle: "late", launchScoped: true,
                          dropped: { dropped.append("late") }, perform: { XCTFail("declined, never run") })
        XCTAssertEqual(dropped.sorted(), ["a", "c", "late"])
    }

    /// C11H-196: one record per panel; the strip counts agent panels only.
    func testRestoreSummaryCountsRecordsAndWhoNeedsTheOperator() {
        let key = HCTerminalKey(owningCoreID: "c", localAddress: "t")
        let ref = ConversationRef(kind: "claude-code", id: UUID().uuidString, capturedVia: .hook, state: .alive)
        func status(_ phase: HCHostEndStatus.Phase, conversation: ConversationRef? = nil) -> HCHostEndStatus {
            HCHostEndStatus(endedKey: key, cause: .restart(at: Date()), phase: phase, conversation: conversation)
        }
        let statuses = [status(.resumed, conversation: ref), status(.resumed, conversation: ref), status(.queued, conversation: ref),
                        status(.failed(reason: "x"), conversation: ref), status(.notResumed(reason: "y"), conversation: ref),
                        status(.noConversation), status(.kept(reason: "Claude Code is still running"), conversation: ref)]
        let summary = HCRestoreProgress.summary(statuses)
        XCTAssertEqual(summary.total, 6, "a plain shell is not an agent to restore")
        XCTAssertEqual(summary.resumed, 2); XCTAssertEqual(summary.pending, 1)
        XCTAssertEqual(summary.failed, 1); XCTAssertEqual(summary.skipped, 2)
        XCTAssertEqual(summary.needYou, 2, "an agent already running there needs nobody")
        XCTAssertFalse(summary.isFinished)
        XCTAssertEqual(statuses.map(\.recordState), ["resumed", "resumed", "pending", "failed", "skipped", "skipped", "skipped"])
        var done = summary; done.pending = 0
        XCTAssertEqual(HCRestoreProgress.headline(done), "Restored 2 of 6 agents. 2 need you.")
    }

    func testARestartIsNamedOnlyWhenTheMacBootedAfterTheTerminalWasLastLive() {
        let saved = Date(timeIntervalSince1970: 1_000), boot = Date(timeIntervalSince1970: 1_060)
        let now = Date(timeIntervalSince1970: 1_200)
        XCTAssertEqual(HCHostEndStatus.cause(hcReason: "stopped_by_restart", observedAt: now, bootedAt: boot, lastKnownLive: saved),
                       .restart(at: boot))
        XCTAssertEqual(HCHostEndStatus.cause(hcReason: "stopped_by_restart", observedAt: now, bootedAt: Date(timeIntervalSince1970: 10),
                                             lastKnownLive: saved), .hostStopped(at: now), "cores killed without a reboot")
        XCTAssertEqual(HCHostEndStatus.cause(hcReason: "holder_lost", observedAt: now, bootedAt: boot, lastKnownLive: saved),
                       .hostStopped(at: now))
    }

    /// C11H-205: three panels ended under h8 read "The terminal host stopped
    /// at 12:31" because 12:31 was when h10 launched. hc's own end time wins.
    func testAHostStopIsDatedByHcsEndTimeNotByWhenC11hNoticed() {
        let saved = Date(timeIntervalSince1970: 1_000), boot = Date(timeIntervalSince1970: 10)
        let ended = Date(timeIntervalSince1970: 500), now = Date(timeIntervalSince1970: 1_200)
        XCTAssertEqual(HCHostEndStatus.cause(hcReason: "stopped_by_restart", observedAt: now, bootedAt: boot,
                                             lastKnownLive: saved, endedAt: ended), .hostStopped(at: ended))
        XCTAssertEqual(HCHostEndStatus.cause(hcReason: "holder_lost", observedAt: now, bootedAt: boot,
                                             lastKnownLive: saved, endedAt: nil), .hostStopped(at: now),
                       "an end hc did not time keeps the moment c11 learned of it")
        XCTAssertEqual(HCHostEndStatus.cause(hcReason: "holder_lost", observedAt: now, bootedAt: boot,
                                             lastKnownLive: saved, endedAt: Date(timeIntervalSince1970: 9_999)),
                       .hostStopped(at: now), "a clock-skewed end time never lies in the future")
    }
}

/// One pool shard in memory: creations bind new terminals of this shard's core, `finish` ends one with hc's reason
/// and publishes it on the shard's feed, as hc's event stream does.
private final class PoolShardFake: HCShardSession, @unchecked Sendable {
    let index: Int
    private let feed = HCSessionFeed()
    private let unavailable = HCUnavailableRuntime()
    private let lock = NSLock()
    private var records: [HCTerminalKey: HCTerminalRecord] = [:]
    private var made = 0
    private var sequence: UInt64 = 0
    private var isReady = true
    /// Its core's id: `core-<index>` unless a test needs keys no other test has used (the resume ledger is shared).
    let coreID: String
    init(index: Int, coreID: String? = nil) { self.index = index; self.coreID = coreID ?? "core-\(index)"; publishLocked() }
    var creates: Int { lock.lock(); defer { lock.unlock() }; return made }

    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        feed.observe(on: queue, handler: handler)
    }
    func snapshot() async -> HCInventorySnapshot { lock.lock(); defer { lock.unlock() }; return currentLocked() }
    func refresh() async -> HCInventorySnapshot { await snapshot() }
    func connectIfServing() async -> Bool { true }
    /// C11H-206: a created terminal is listed only after this many more lookups (a loaded Mac's slow inventory);
    /// its create meanwhile answers unresolved, as hc's does when inventory has not caught up.
    var listCreatesAfter = 0
    /// What such a create answers: inventory still catching up, or its confirming refresh timed out.
    var pendingCreateReason: HCUnavailableReason = .inventoryPending
    private var unlisted: [UUID: (record: HCTerminalRecord, lookups: Int)] = [:]
    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle {
        lock.lock(); defer { lock.unlock() }
        guard isReady else { return .unresolved(identity, .connectionLost) }
        // As the real resolver: a creation in flight is found by its creation id first.
        if let creationID = identity.creationID {
            if var pending = unlisted[creationID] {
                pending.lookups -= 1
                guard pending.lookups <= 0 else { unlisted[creationID] = pending; return .unresolved(identity, .creationPending) }
                unlisted.removeValue(forKey: creationID)
                records[pending.record.key] = pending.record
                publishLocked()
            }
            if let listed = records.values.first(where: { $0.labels["c11.creation"] == creationID.uuidString }) {
                return listed.state == .finished
                    ? .ended(HCEndEvidence(id: UUID(), key: listed.key, revision: currentLocked().revision, kind: .finished,
                                           hcReason: listed.endReason, exitCode: listed.exitCode, exitSignal: listed.exitSignal,
                                           endedAtMilliseconds: listed.finishedMilliseconds))
                    : .live(listed)
            }
        }
        guard let key = identity.key, let record = records[key] else { return .new }
        if record.state == .finished {
            return .ended(HCEndEvidence(id: UUID(), key: key, revision: currentLocked().revision, kind: .finished,
                                        hcReason: record.endReason, exitCode: record.exitCode, exitSignal: record.exitSignal,
                                        endedAtMilliseconds: record.finishedMilliseconds))
        }
        return .live(record)
    }
    func create(_ request: HCCreateRequest) async -> HCCreateResult {
        lock.lock(); defer { lock.unlock() }
        made += 1
        let key = HCTerminalKey(owningCoreID: coreID, localAddress: "t\(made)")
        let record = HCTerminalRecord(key: key, state: .running, labels: ["c11.panel": request.identity.panelID.uuidString,
                                                                          "c11.creation": request.creationID.uuidString],
                                      pid: Int32(100 + made))
        if listCreatesAfter > 0 {
            unlisted[request.creationID] = (record, listCreatesAfter)
            return .unresolved(request.identity, pendingCreateReason)
        }
        records[key] = record
        publishLocked()
        return .bound(record)
    }
    /// hc reports an agent in the terminal with this status (nil: an agent with no status yet).
    func setAgent(_ key: HCTerminalKey, status: String?) {
        lock.lock(); defer { lock.unlock() }
        guard let record = records[key] else { return }
        records[key] = HCTerminalRecord(key: key, state: .running, labels: record.labels, pid: record.pid,
            foreground: HCForeground(name: "claude", argv: ["claude"]), status: status)
        publishLocked()
    }
    func setForeground(_ key: HCTerminalKey, foreground: HCForeground?) {
        lock.lock(); defer { lock.unlock() }
        guard let record = records[key] else { return }
        records[key] = HCTerminalRecord(key: key, state: .running, labels: record.labels, pid: record.pid,
                                        foreground: foreground)
        publishLocked()
    }
    func finish(_ key: HCTerminalKey, reason: String, exitCode: Int32? = nil, signal: Int32? = nil, at: Int64? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let record = records[key] else { return }
        records[key] = HCTerminalRecord(key: key, state: .finished, labels: record.labels, exitCode: exitCode,
                                        exitSignal: signal, endReason: reason, finishedMilliseconds: at)
        publishLocked()
    }
    /// A new inventory revision with nothing changed, as hc sends on every event.
    func republish() { lock.lock(); defer { lock.unlock() }; publishLocked() }
    func setReady(_ ready: Bool) { lock.lock(); defer { lock.unlock() }; isReady = ready; publishLocked() }
    private var allWriters: [HeadlessWriter] = []
    var writers: [HeadlessWriter] { lock.lock(); defer { lock.unlock() }; return allWriters }
    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        let writer = HeadlessWriter()
        lock.lock(); allWriters.append(writer); lock.unlock()
        let prepared = try await HCBackendComposition.prepareAttachment(key: key, generation: 1, sink: sink, proposedDisplay: display)
        let attachment = try await HCBackendComposition.makeAttachment(key: key, generation: 1,
            channel: HeadlessChannel(writer), sink: sink, display: prepared)
        (attachment as? HCPanelAttachment)?.setAdmission(true)
        return attachment
    }
    func end(_ key: HCTerminalKey) async -> HCEndResult { await unavailable.end(key) }
    func diagnostics() async -> HCDiagnostics { await unavailable.diagnostics() }
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { await unavailable.recoverSession(reason: reason) }

    private func currentLocked() -> HCInventorySnapshot {
        let revision = HCRevision(connectionGeneration: 1, sequence: sequence)
        let build = HCBuildIdentity(pin: .current, executablePath: "/owned/hc",
            fileIdentity: HCFileIdentity(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 5),
            process: HCProcessIdentity(pid: Int32(40 + index), startTimeMicroseconds: 6), coreID: coreID,
            protocolGeneration: 1)
        return HCInventorySnapshot(readiness: isReady ? .ready(revision) : .pending(.connectionLost),
                                   revision: revision, records: records, buildIdentity: build)
    }
    private func publishLocked() { sequence += 1; feed.publish(currentLocked()) }
}

private extension HCLifecycle {
    var liveRecordForTesting: HCTerminalRecord? { if case .live(let record) = self { return record }; return nil }
}

/// Pure signal/process facts drive the same resolver the real child-exit and
/// hidden-panel paths call. No signals or process probes run in these tests.
final class HCSessionEndRootWitnessTests: XCTestCase {
    private let panel = UUID()
    private let workspace = UUID()
    private let session = "00000000-0000-4000-8000-000000000271"
    private let key = HCTerminalKey(owningCoreID: "fixture", localAddress: "t1")
    private let agent = JournalRuntimeIdentity(pid: 42, startTimeMicroseconds: 500_000)
    private typealias Process = MailboxAgentForeground.ProcessTerminalInfo

    private func process(start: UInt64, parent: pid_t, zombie: Bool = false) -> Process {
        // The controlling tty is gone after HUP; ancestry and the previously
        // verified process birth must suffice without weakening mailbox input.
        Process(processGroup: 42, terminalForegroundGroup: -1, terminalDevice: -1,
            isZombie: zombie, startTime: start, parentPID: parent)
    }
    private var processes: [pid_t: Process] {
        [42: process(start: 500_000, parent: 1), 43: process(start: 600_000, parent: 42)]
    }
    private var draft: JournalDraft {
        JournalDraft(kind: .sessionEnded, emittedAtMs: 9_000, panelID: panel, workspaceID: workspace,
            sessionID: session, agentKind: "claude-code", source: .hook, adapter: .claudeHook,
            nativeEvent: "SessionEnd")
    }
    private var conversation: ConversationRef {
        ConversationRef(kind: "claude-code", id: session, capturedAt: Date(timeIntervalSince1970: 1),
            capturedVia: .hook, state: .alive)
    }
    private var prior: JournalSnapshot {
        var value = JournalSnapshot(owner: draft.owner!, workspaceID: workspace, appInstanceID: UUID())
        value.runtimeIdentity = agent
        return value
    }
    private func entry(machine: String? = nil, persistence: HCPersistence = .persistent) -> HCPanelRestoreState.Entry {
        HCPanelRestoreState.Entry(identity: HCPanelIdentity(panelID: panel, key: key, persistence: persistence),
            lifecycle: .live(HCTerminalRecord(key: key, state: .running, labels: [:], machineName: machine, pid: 99)),
            creation: nil)
    }
    private var end: HCEndEvidence {
        HCEndEvidence(id: UUID(), key: key, revision: HCRevision(connectionGeneration: 1, sequence: 1),
            kind: .finished, hcReason: "exited", exitSignal: SIGTERM, endedAtMilliseconds: 10_000)
    }
    private func witness(processes: [pid_t: Process]? = nil, absent: Bool = true,
                         prior: JournalSnapshot? = nil, conversation: ConversationRef? = nil,
                         entry: HCPanelRestoreState.Entry? = nil, caller: Int32 = 43) -> JournalRootExitWitness? {
        let facts = processes ?? self.processes
        return HCSessionEndRootWitness.resolve(draft: draft, interactivePID: 42, callerPID: caller,
            prior: prior ?? self.prior, conversation: conversation ?? self.conversation, entry: entry ?? self.entry(),
            processInfo: { facts[$0] }, isAbsent: { $0 == 99 && absent })
    }

    func testRealAppendAndStoreRecoveryKeepAnEarlyHookOnlyWhenItsRootAlreadyExited() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JournalStore(layout: JournalStorageLayout(directory: directory), clock: { 12_000 })
        var start = draft
        start.eventID = UUID(); start.kind = .sessionStarted; start.nativeEvent = "SessionStart"; start.emittedAtMs = 1_000
        var context = JournalContext(eligible: true)
        context.verifiedRuntimeIdentity = agent
        let started = try XCTUnwrap(journal.append(draft: start, context: context).changedSnapshot)
        XCTAssertEqual(started.runtimeIdentity, agent)
        context.verifiedRuntimeIdentity = nil
        context.sessionEndRootExit = try XCTUnwrap(witness(prior: started))
        let ended = try XCTUnwrap(journal.append(draft: draft, context: context).changedSnapshot)
        XCTAssertEqual(ended.sessionEndedAtMs, 9_000)
        let stored = try XCTUnwrap(journal.current(owner: draft.owner!))
        XCTAssertEqual(stored, ended)
        let persisted = try JSONDecoder().decode(JournalSnapshot.self, from: JSONEncoder().encode(stored))

        for endPushArrived in [false, true] {
            let store = ConversationStore()
            _ = await store.seed(from: [panel.uuidString: PanelConversations(active: conversation)])
            if endPushArrived {
                _ = await store.push(surfaceId: panel.uuidString, kind: conversation.kind, id: session,
                    source: .hook, capturedAt: Date(timeIntervalSince1970: 9.1), state: .unknown, sessionEnded: true)
            }
            let current = await store.snapshot()[panel.uuidString]?.active
            let ref = try XCTUnwrap(current)
            let prepared = await store.prepareOutsideSignalRecovery(surfaceId: panel, expected: ref,
                evidence: end, journal: persisted)
            XCTAssertEqual(prepared?.state, .suspended, "both alive-cache and ended-cache delivery orders keep the agent")
            var foreign = persisted
            foreign.sessionEndedRootExit = JournalRootExitWitness(coreID: "different-core", terminalAddress: "t1")
            XCTAssertNil(HCOutsideSignalConversation.resolve(panelID: panel, evidence: end, conversation: ref, journal: foreign))
            foreign.sessionEndedRootExit = JournalRootExitWitness(coreID: "fixture", terminalAddress: "t2")
            XCTAssertNil(HCOutsideSignalConversation.resolve(panelID: panel, evidence: end, conversation: ref, journal: foreign))
            var voluntary = persisted; voluntary.sessionEndedRootExit = nil
            XCTAssertNil(HCOutsideSignalConversation.resolve(panelID: panel, evidence: end, conversation: ref, journal: voluntary))
        }
    }

    func testVoluntaryExitUnknownKernelFactsAndUnboundHooksCannotWitnessRootDeath() throws {
        XCTAssertNotNil(witness())
        var liveRoot = processes; liveRoot[99] = process(start: 100_000, parent: 1)
        XCTAssertNil(witness(processes: liveRoot), "the root still exists during voluntary SessionEnd")
        XCTAssertNil(witness(absent: false), "an unreadable process is not a dead process")
        var zombieRoot = processes; zombieRoot[99] = process(start: 100_000, parent: 1, zombie: true)
        XCTAssertNotNil(witness(processes: zombieRoot))
        var recycled = processes; recycled[42] = process(start: 700_000, parent: 1)
        recycled[43] = process(start: 800_000, parent: 42)
        XCTAssertNil(witness(processes: recycled))
        var unrelated = processes; unrelated[43] = process(start: 600_000, parent: 1)
        XCTAssertNil(witness(processes: unrelated))
        var wrongOwner = prior; wrongOwner.owner = JournalOwner(panelID: UUID(), agentKind: "claude-code", sessionID: session)
        XCTAssertNil(witness(prior: wrongOwner))
        var oldEnd = conversation; oldEnd.state = .unknown; oldEnd.sessionEndedAt = Date(timeIntervalSince1970: 8)
        XCTAssertNil(witness(conversation: oldEnd), "a delayed second hook cannot recast a voluntary exit")
        var inferred = conversation; inferred.capturedVia = .scrape
        XCTAssertNil(witness(conversation: inferred))
        var newer = conversation; newer.identityCapturedAt = Date(timeIntervalSince1970: 10)
        XCTAssertNil(witness(conversation: newer))
        XCTAssertNil(witness(entry: entry(machine: "remote")))
        XCTAssertNil(witness(entry: entry(persistence: .nonpersistent)))
    }

    func testHistoricalEndCannotAcquireLiveRootProofAndANewProcessResetsOldProof() throws {
        var context = JournalContext(eligible: true)
        context.sessionEndRootExit = try XCTUnwrap(witness())
        let instance = UUID()
        let ended = try XCTUnwrap(JournalReducer.fold(previous: prior, draft: draft, sequence: 1,
            committedAtMs: 12_000, tick: 1, instanceID: instance, context: context).snapshot)
        XCTAssertNotNil(ended.sessionEndedRootExit)
        context.historical = true
        let historical = try XCTUnwrap(JournalReducer.fold(previous: nil, draft: draft, sequence: 1,
            committedAtMs: 12_000, tick: 1, instanceID: instance, context: context).snapshot)
        XCTAssertNil(historical.sessionEndedRootExit)
        var start = draft; start.eventID = UUID(); start.kind = .sessionStarted; start.nativeEvent = "SessionStart"
        start.emittedAtMs = 13_000
        context.historical = false; context.sessionEndRootExit = nil
        context.verifiedRuntimeIdentity = JournalRuntimeIdentity(pid: 52, startTimeMicroseconds: 12_000_000)
        let resumed = try XCTUnwrap(JournalReducer.fold(previous: ended, draft: start, sequence: 2,
            committedAtMs: 14_000, tick: 2, instanceID: instance, context: context).snapshot)
        XCTAssertEqual(resumed.runtimeIdentity, context.verifiedRuntimeIdentity)
        XCTAssertNil(resumed.sessionEndedAtMs)
        XCTAssertNil(resumed.sessionEndedRootExit)
        // C11H-322: the newly verified process is at its prompt, and live.
        XCTAssertEqual(resumed.phase, .idle)
        XCTAssertEqual(resumed.connection, .live)
        XCTAssertGreaterThan(resumed.lastSequence, ended.lastSequence,
            "the coordinator must reject an older end published after the new process identity")
    }
}

final class HCOutsideSignalConversationTests: XCTestCase {
    private let panel = UUID()
    private let rootEndMs: Int64 = 10_000
    private var evidence: HCEndEvidence {
        HCEndEvidence(id: UUID(), key: HCTerminalKey(owningCoreID: "fixture", localAddress: "t1"),
            revision: HCRevision(connectionGeneration: 1, sequence: 1), kind: .finished,
            hcReason: "exited", exitSignal: SIGTERM, endedAtMilliseconds: rootEndMs)
    }
    private func ref(_ state: ConversationState = .alive, capturedAt: Date = Date(timeIntervalSince1970: 1)) -> ConversationRef {
        ConversationRef(kind: "claude-code", id: "00000000-0000-4000-8000-000000000271",
            capturedAt: capturedAt, capturedVia: .hook, state: state)
    }
    private func journalEnd(at ms: Int64) throws -> JournalSnapshot {
        let draft = JournalDraft(kind: .sessionEnded, emittedAtMs: ms, panelID: panel,
            sessionID: ref().id, agentKind: "claude-code", source: .hook, adapter: .claudeHook,
            nativeEvent: "SessionEnd")
        return try XCTUnwrap(JournalReducer.fold(previous: nil, draft: draft, sequence: 1,
            committedAtMs: 12_000, tick: 1, instanceID: UUID(), context: JournalContext(eligible: true)).snapshot)
    }
    private func resolve(_ ref: ConversationRef?, _ journal: JournalSnapshot? = nil) -> ConversationRef? {
        HCOutsideSignalConversation.resolve(panelID: panel, evidence: evidence, conversation: ref, journal: journal)
    }

    func testJournalEndBeforeSignalClosesEvenIfStoreStillSaysAlive() throws {
        let journal = try journalEnd(at: rootEndMs - 1)
        XCTAssertNil(resolve(ref(), journal))
    }

    func testDelayedEndPushUsesEarlierHookTimeNotDeliveryTime() throws {
        var ended = ref(.unknown)
        ended.sessionEndedAt = Date(timeIntervalSince1970: 11)
        XCTAssertNil(resolve(ended, try journalEnd(at: rootEndMs - 1)))
        XCTAssertEqual(resolve(ended, try journalEnd(at: rootEndMs + 1))?.id, ended.id)
    }

    func testUnknownTombstonePlaceholderAndQuarantineCannotBecomeOffers() throws {
        XCTAssertNil(resolve(nil))
        for state in [ConversationState.unknown, .tombstoned, .unsupported] {
            XCTAssertNil(resolve(ref(state), try journalEnd(at: rootEndMs + 1)))
        }
        var placeholder = ref(); placeholder.placeholder = true
        XCTAssertNil(resolve(placeholder))
        var quarantined = ref(); quarantined.quarantineReason = .conflictingCausalIdentity
        XCTAssertNil(resolve(quarantined))
        var shell = ref(); shell.kind = "terminal"
        XCTAssertNil(resolve(shell))
        var inferredEnd = ref(.unknown)
        inferredEnd.capturedVia = .scrape
        inferredEnd.sessionEndedAt = Date(timeIntervalSince1970: 11)
        XCTAssertNil(resolve(inferredEnd))
    }

    func testDifferentJournalOwnerCannotEndThisConversation() throws {
        let ended = try journalEnd(at: rootEndMs - 1)
        for owner in [JournalOwner(panelID: UUID(), agentKind: ref().kind, sessionID: ref().id),
                      JournalOwner(panelID: panel, agentKind: "codex", sessionID: ref().id),
                      JournalOwner(panelID: panel, agentKind: ref().kind, sessionID: "another-session")] {
            var foreign = ended; foreign.owner = owner
            XCTAssertNotNil(resolve(ref(), foreign))
        }
    }

    func testUntimedRootCannotRecoverAnEndedConversation() {
        var ended = ref(.unknown); ended.sessionEndedAt = Date(timeIntervalSince1970: 11)
        let untimed = HCEndEvidence(id: UUID(), key: evidence.key, revision: evidence.revision,
                                   kind: .finished, hcReason: "exited", exitSignal: SIGTERM)
        XCTAssertNil(HCOutsideSignalConversation.resolve(panelID: panel, evidence: untimed,
                                                         conversation: ended, journal: nil))
    }

    func testSessionEndCannotPromoteAGenericUnknownOrAnExplicitTombstone() async throws {
        for state in [ConversationState.unknown, .tombstoned, .unsupported] {
            let store = ConversationStore()
            let before = await store.push(surfaceId: panel.uuidString, kind: ref().kind, id: ref().id,
                source: .hook, capturedAt: ref().capturedAt, state: state)
            let after = await store.push(surfaceId: panel.uuidString, kind: ref().kind, id: ref().id,
                source: .hook, capturedAt: Date(timeIntervalSince1970: 11), state: .unknown, sessionEnded: true)
            XCTAssertEqual(after, before)
            XCTAssertNil(resolve(after))
        }
    }

    func testAResumedLiveCaptureSupersedesItsPreviousJournalEnd() throws {
        var current = ref(capturedAt: Date(timeIntervalSince1970: 9))
        XCTAssertNotNil(resolve(current, try journalEnd(at: 8_000)))
        current.state = .unknown
        current.sessionEndedAt = Date(timeIntervalSince1970: 11)
        XCTAssertNotNil(resolve(current, try journalEnd(at: 8_000)))
    }

    func testConversationFirstCapturedAfterTheRootEndCannotBeOffered() {
        var later = ref(capturedAt: Date(timeIntervalSince1970: 11))
        XCTAssertNil(resolve(later))
        later.state = .unknown
        later.sessionEndedAt = Date(timeIntervalSince1970: 12)
        XCTAssertNil(resolve(later))
    }

    func testLifecycleUpdatesPreserveTheCaptureTimeAndEarlierJournalEnd() async throws {
        for legacy in [false, true] {
            let store = ConversationStore()
            var original = ref()
            if legacy { original.identityCapturedAt = nil }
            _ = await store.seed(from: [panel.uuidString: PanelConversations(active: original)])
            await store.suspendAllAlive(at: Date(timeIntervalSince1970: 12))
            let afterSuspend = await store.snapshot()[panel.uuidString]?.active
            let suspended = try XCTUnwrap(afterSuspend)
            XCTAssertEqual(suspended.capturedAt, Date(timeIntervalSince1970: 12))
            XCTAssertEqual(suspended.identityCaptureTime, original.capturedAt)
            XCTAssertNotNil(resolve(suspended), "a lifecycle refresh does not make the conversation new")
            XCTAssertNil(resolve(suspended, try journalEnd(at: rootEndMs - 1)))
            await store.applyCrashTranscriptVerdicts([panel.uuidString:
                CrashTranscriptVerdict(id: original.id, exists: true, expectedRef: suspended)],
                at: Date(timeIntervalSince1970: 13))
            let afterAudit = await store.snapshot()[panel.uuidString]?.active
            let audited = try XCTUnwrap(afterAudit)
            XCTAssertEqual(audited.capturedAt, Date(timeIntervalSince1970: 13))
            XCTAssertEqual(audited.identityCaptureTime, original.capturedAt)
            let saved = try JSONDecoder().decode(ConversationRef.self, from: JSONEncoder().encode(audited))
            XCTAssertNotNil(resolve(saved))
            XCTAssertNil(resolve(saved, try journalEnd(at: rootEndMs - 1)))
        }
    }

    func testSessionEndRetainsIdentityAndRejectsStaleOrGenericUnknownRefs() async throws {
        let store = ConversationStore()
        _ = await store.push(surfaceId: panel.uuidString, kind: ref().kind, id: ref().id, source: .hook,
                             cwd: "/fixture/project", capturedAt: ref().capturedAt)
        let inferredEnd = await store.push(surfaceId: panel.uuidString, kind: ref().kind, id: ref().id,
            source: .scrape, capturedAt: Date(timeIntervalSince1970: 2), state: .unknown, sessionEnded: true)
        XCTAssertEqual(inferredEnd?.state, .alive, "an inferred push cannot end a causal hook owner")
        let staleWhileLive = await store.push(surfaceId: panel.uuidString, kind: ref().kind, id: "older-session",
            source: .hook, capturedAt: Date(timeIntervalSince1970: 2), state: .unknown, sessionEnded: true)
        XCTAssertEqual(staleWhileLive?.state, .alive)
        XCTAssertNil(staleWhileLive?.sessionEndedAt)
        let pushed = await store.push(surfaceId: panel.uuidString, kind: ref().kind, id: ref().id,
            source: .hook, capturedAt: Date(timeIntervalSince1970: 11), state: .unknown, sessionEnded: true)
        let ended = try XCTUnwrap(pushed)
        XCTAssertEqual(ended.cwd, "/fixture/project")
        XCTAssertEqual(ended.capturedAt, ref().capturedAt)
        XCTAssertEqual(resolve(ended)?.id, ref().id)
        let stale = await store.push(surfaceId: panel.uuidString, kind: ref().kind, id: "another-session",
            source: .hook, state: .unknown, sessionEnded: true)
        XCTAssertEqual(stale, ended)
        var replacement = ref(); replacement.id = "replacement"
        let prepared = await store.prepareOutsideSignalRecovery(surfaceId: panel, expected: replacement,
                                                                 evidence: evidence, journal: nil)
        XCTAssertNil(prepared)
        let remaining = await store.snapshot()[panel.uuidString]?.active
        XCTAssertEqual(remaining, ended)
        let restored = try JSONDecoder().decode(ConversationRef.self, from: JSONEncoder().encode(ended))
        XCTAssertEqual(resolve(restored)?.id, ref().id, "end provenance survives a saved snapshot")
    }
}

/// C11H-346: XCTest releases an async teardown block's captures from its own Task, off main and sometimes after
/// the next test has begun. The last release of a rig or seat frees its `Workspace`, whose deinit must run on main
/// (`MainActor.assumeIsolated` traps, and the runner exits with code 6). Such a block captures this box instead
/// and calls `release()` in its body, on main, which also checks that nothing else still holds the value.
final class HCTeardownHold<Value: AnyObject>: @unchecked Sendable {
    private(set) var value: Value?
    init(_ value: Value) { self.value = value }

    @MainActor
    func release(file: StaticString = #filePath, line: UInt = #line) {
        weak var released = value
        value = nil
        XCTAssertNil(released, "freed here, on main: nothing else holds it", file: file, line: line)
    }
}

// C11H-304, C11H-306: the headless ring through the real `submitHCInput`, the input coordinator and a writer that
// pauses between the doorbell line and its Return. The composer is read from hc's paint (here a stand-in for the
// paint: Codex's composer showing whatever the writer typed since its last Return, as the TUI echoes it). Before the
// text a read must show an empty composer or the dim placeholder, before the Return exactly the line; any fact that
// changes in the pause stops the Return.
@MainActor
final class HCHeadlessDoorbellWireTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "local-core", localAddress: "t31")
    private let agentPID: pid_t = 4711
    private let device: dev_t = 0x1234
    private let born: UInt64 = 1_700_000_000_000_000
    private let line = Data(MailboxDoorbell.text.utf8)

    private final class Rig: @unchecked Sendable {
        let session: LifecycleSession
        let workspace: Workspace
        let panel: TerminalPanel
        var record: HCTerminalRecord?
        var foregroundGroup: pid_t
        var journal: JournalSnapshot?
        var headless = true
        var rings = 0
        /// What sat in the composer before c11 started (typed before the relaunch).
        var leftover = ""
        /// Text another input added to the composer.
        var extra = ""
        /// The agent took (or queued) everything in the composer.
        var taken = false
        var paintReads = 0
        /// Reads that fail before the next one succeeds (an attach that times out).
        var failNextReads = 0
        /// Each doorbell row: reason, why.
        var rows: [(outcome: MailboxDispatchLog.HandlerOutcome, reason: String, why: String?)] = []
        /// Each scheduled look's delay, unscaled.
        var rechecks: [TimeInterval] = []
        init(session: LifecycleSession, workspace: Workspace, panel: TerminalPanel, group: pid_t) {
            self.session = session; self.workspace = workspace; self.panel = panel; foregroundGroup = group
        }
        var writer: HeadlessWriter { session.writers[0] }
        @MainActor var ledger: MailboxDoorbell.Ledger { workspace.mailboxDoorbellLedgerForTesting(surfaceId: panel.id) }

        /// The composer as the TUI would draw it: what was typed since the last Return.
        var composer: String {
            if taken { return "" }
            let typed = String(decoding: session.writers.first?.received ?? Data(), as: UTF8.self)
            let tail = typed.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            return leftover + tail + extra
        }

        var paint: HCComposerPaint {
            let text = composer
            if text.isEmpty { return HCPaintScreenTests.codex(HCPaintScreenTests.faint("Ask Codex to do anything")) }
            return HCPaintScreenTests.codex(text, cursorColumn: 2 + text.count)
        }
    }

    private func record(_ status: String, turn: Int64) -> HCTerminalRecord {
        HCTerminalRecord(key: key, state: .running, machineAvailability: .local, pid: 4242,
                         foreground: HCForeground(pid: agentPID, name: "codex", argv: ["codex"]),
                         status: status, statusTimestampMilliseconds: nil, turn: turn, tty: "/dev/ttys042")
    }

    private func report(_ rig: Rig, _ status: String, turn: Int64) {
        rig.record = record(status, turn: turn)
        rig.workspace.noteHCLocalMailbox(panelId: rig.panel.id, record: rig.record)
    }

    /// A headless hc terminal (no surface, a headless bridge, a real coordinator) whose Codex has been idle since
    /// c11 started: hc's restore seed is the only report it has.
    private func rig(leftover: String = "") async throws -> Rig {
        let session = LifecycleSession(key: key)
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let runtime = HCPanelSession(identity: HCPanelIdentity(panelID: panel.id, origin: .restored), session: session)
        runtime.installReconnectPolicy()
        let display = HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 0),
                                     grid: HCHeadless.grid, facts: HCDisplayFacts(), focused: false)
        let bridge = HCNativeBridge.headless(panelID: panel.id, report: { _ in })
        _ = try await runtime.attachSurface(launch: HCPanelLaunchSpec(argv: ["/bin/sh"], cwd: nil, environment: [:], initialInput: nil),
                                            bridge: bridge, display: display)
        panel.surface.installHCSessionForTesting(runtime)
        panel.surface.setHeadlessBridgeForTesting(bridge)
        let rig = Rig(session: session, workspace: workspace, panel: panel, group: agentPID)
        rig.leftover = leftover
        _ = try PanelMetadataStore.shared.setMetadata(workspaceId: workspace.id, surfaceId: panel.id,
            partial: ["mailbox.delivery": "stdin"], mode: .merge, source: .explicit)
        let kind = try XCTUnwrap(HCRemoteStatus.classification(HCForeground(name: "codex", argv: ["codex"])))
        workspace.setDetectedTerminalType(kind, forSurface: panel.id)
        let pid = agentPID, device = device, born = born
        workspace.mailboxKernel = MailboxAgentForeground.Kernel(
            processInfo: { [weak rig] in
                guard let rig, $0 == pid else { return nil }
                return .init(processGroup: pid, terminalForegroundGroup: rig.foregroundGroup,
                             terminalDevice: device, isZombie: false, startTime: born)
            },
            ttyDevice: { $0.hasSuffix("ttys042") ? device : nil },
            isCanonical: { _ in false })
        workspace.hcLocalOwnershipRunForTesting = { compute, deliver in deliver(compute()) }
        // C11H-346: weak, never unowned. Production calls these whenever it looks (an arrival's composer read lands
        // after its own off-main hop), and a look that lands after the test has let go of its rig must not abort
        // the runner (Ghostty's crash handler turns that abort into "exited with code 5").
        workspace.mailboxJournalSnapshotForTesting = { [weak rig] _ in rig?.journal }
        workspace.mailboxHeadlessRecordForTesting = { [weak rig] _ in rig?.record }
        workspace.mailboxIsHeadlessForTesting = { [weak rig] _ in rig?.headless ?? true }
        workspace.mailboxHeadlessPaintForTesting = { [weak rig] _ in
            guard let rig else { return .failure(.unavailable) }
            rig.paintReads += 1
            guard rig.failNextReads == 0 else { rig.failNextReads -= 1; return .failure(.timedOut) }
            return .success(rig.paint)
        }
        workspace.onMailboxDoorbellRingForTesting = { [weak rig] in if $0 == panel.id { rig?.rings += 1 } }
        workspace.onMailboxDoorbellRecheckScheduledForTesting = { [weak rig] in if $0 == panel.id { rig?.rechecks.append($1) } }
        workspace.onMailboxDoorbellRowForTesting = { [weak rig] _, outcome, reason, why in
            rig?.rows.append((outcome, reason, why))
        }
        MailboxHeadlessPrompt.returnSettleOverrideNanoseconds = 20_000_000
        addTeardownBlock { MailboxHeadlessPrompt.returnSettleOverrideNanoseconds = nil }
        // C11H-346: a mail's arrival starts a composer read that no test awaits (an unstructured Task that holds the
        // workspace across its off-main classify, then looks again). Hold the rig until that read and its look have
        // landed, so neither runs inside the next test. Registered after the override's reset, so it runs first.
        // The rig is held in a box and let go inside the block, on main (`HCTeardownHold`).
        let hold = HCTeardownHold(rig)
        addTeardownBlock { @MainActor [hold] in
            let deadline = Date().addingTimeInterval(5)
            while hold.value?.workspace.mailboxHeadlessComposerReadInFlightForTesting == true, Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNotEqual(hold.value?.workspace.mailboxHeadlessComposerReadInFlightForTesting, true,
                              "the arrival's composer read landed")
            hold.release()
        }
        report(rig, "idle", turn: 1)    // hc's restore seed: idle since before c11 started
        XCTAssertEqual(workspace.mailboxDoorbellGateState(surfaceId: panel.id)?.ownsTerminal, true)
        return rig
    }

    private func mail(_ rig: Rig, _ id: String) {
        _ = rig.workspace.deliverOrBufferMailboxStdin(surfaceId: rig.panel.id, envelopeId: id,
                                                      recipientName: "c11-captain", block: "<c11-msg/>")
    }

    private func until(_ what: String, seconds: Double = 3, _ done: @MainActor () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(done(), what, file: file, line: line)
    }

    /// One ring with `flip` run in the pause between the line and its Return (after the line is out, before the
    /// read that must find it).
    private func ring(_ rig: Rig, flip: (@MainActor (Rig) -> Void)?) async {
        let saved = SendSubmitConfirmation.waitSeconds
        SendSubmitConfirmation.waitSeconds = 0.3
        defer { SendSubmitConfirmation.waitSeconds = saved }
        mail(rig, "01M7WIREPROBE000000000001")
        if let flip {
            // Weak: the rig owns its writer, so a strong rig here kept it alive forever (C11H-346).
            rig.writer.afterBody { [weak rig] in await MainActor.run { if let rig { flip(rig) } } }
        }
        await rig.workspace.ringHeadlessMailboxDoorbellForTesting(surfaceId: rig.panel.id)
    }

    private func assertNoReturn(after flip: @escaping @MainActor (Rig) -> Void, _ fact: String,
                                file: StaticString = #filePath, line codeLine: UInt = #line) async throws {
        let rig = try await rig()
        defer { withExtendedLifetime(rig.workspace) {} }
        await ring(rig, flip: flip)
        XCTAssertEqual(rig.writer.received, line, "\(fact): the line, then no Return", file: file, line: codeLine)
        XCTAssertTrue(rig.ledger.strandedPending, "\(fact): held as stranded (its Return was cut)", file: file, line: codeLine)
        XCTAssertTrue(rig.ledger.coveredIds.isEmpty, "\(fact): never delivered", file: file, line: codeLine)
    }

    func testWithNothingChangedTheReturnFollowsTheLine() async throws {
        let rig = try await rig()
        defer { withExtendedLifetime(rig.workspace) {} }
        await ring(rig, flip: { _ in })
        XCTAssertEqual(rig.writer.received, line + Data([13]), "the pause alone stops nothing")
        XCTAssertGreaterThanOrEqual(rig.paintReads, 2, "a read before the text and one before the Return")
    }

    /// The guest run's deadlock: every RPC on the connection waits behind an input write held at its Return check,
    /// so the composer read (an attach RPC) must never run inside that check. It runs between the two writes.
    func testNoComposerReadRunsInsideTheReturnCheck() async throws {
        let rig = try await rig()
        defer { withExtendedLifetime(rig.workspace) {} }
        let counts = ReadCounts()
        rig.workspace.mailboxHeadlessPaintForTesting = { [weak rig] _ in
            guard let rig else { return .failure(.unavailable) }
            counts.read(); return .success(rig.paint)
        }
        rig.writer.aroundReturnCheck { before in counts.mark(before: before) }
        await ring(rig, flip: nil)
        XCTAssertEqual(rig.writer.received, line + Data([13]))
        let (reads, before, after) = counts.snapshot
        XCTAssertGreaterThanOrEqual(reads, 2)
        XCTAssertNotNil(before, "the Return's check ran")
        XCTAssertEqual(before, after, "no read inside the Return's check")
    }

    private final class ReadCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var before: Int?
        private var after: Int?
        func read() { lock.lock(); reads += 1; lock.unlock() }
        func mark(before isBefore: Bool) {
            lock.lock(); if isBefore { before = reads } else { after = reads }; lock.unlock()
        }
        var snapshot: (Int, Int?, Int?) { lock.lock(); defer { lock.unlock() }; return (reads, before, after) }
    }

    /// Acceptance 1 and the ticket's first case: mail to an agent idle since c11 started, with its dim
    /// placeholder showing. The mail's own arrival reads the composer and rings; the ring types the line and its
    /// Return through hc, and the mail is delivered on the agent's turn. (A test workspace has no dispatcher, so
    /// the typing half is started at the ring itself.)
    func testAnAgentIdleSinceTheRelaunchIsRungAndDelivered() async throws {
        let rig = try await rig()
        defer { withExtendedLifetime(rig.workspace) {} }
        mail(rig, "01M7WIREIDLE00000000000001")
        await until("the arrival read the composer and rang") { rig.rings == 1 }
        XCTAssertGreaterThanOrEqual(rig.paintReads, 1)
        let saved = SendSubmitConfirmation.waitSeconds
        SendSubmitConfirmation.waitSeconds = 2
        defer { SendSubmitConfirmation.waitSeconds = saved }
        rig.writer.afterReturn { [weak rig, self] in await MainActor.run { if let rig { self.report(rig, "working", turn: 2) } } }
        await rig.workspace.ringHeadlessMailboxDoorbellForTesting(surfaceId: rig.panel.id)
        XCTAssertEqual(rig.writer.received, line + Data([13]))
        XCTAssertFalse(rig.ledger.coveredIds.isEmpty, "delivered on the agent's turn")
        XCTAssertFalse(rig.ledger.strandedPending)
    }

    /// A hold the buffered look decides is logged through the dispatcher a test workspace lacks; the next arrival
    /// decides on the same (fresh) read and records it.
    private func heldAs(_ rig: Rig, _ code: String, _ id: String,
                        file: StaticString = #filePath, line: UInt = #line) async {
        mail(rig, id + "1")
        await until("read once", { rig.paintReads >= 1 }, file: file, line: line)
        try? await Task.sleep(nanoseconds: 50_000_000)
        mail(rig, id + "2")
        await until("held as \(code)", { rig.workspace.mailboxWaitByPanel[rig.panel.id]?.code == code },
                    file: file, line: line)
    }

    /// Acceptance 2: text in the composer from before the relaunch is a draft. Nothing is typed.
    func testADraftTypedBeforeTheRelaunchHoldsAndNothingIsTyped() async throws {
        let rig = try await rig(leftover: "half typed draft")
        defer { withExtendedLifetime(rig.workspace) {} }
        await heldAs(rig, "draft", "01M7WIREDRAFT000000000000")
        XCTAssertEqual(rig.rings, 0)
        XCTAssertTrue(rig.writer.received.isEmpty, "zero bytes")
    }

    /// The ticket's second case: a line written to the agent while it worked, which its harness queued. Nothing
    /// infers a draft from that Return; once the agent is idle its composer reads empty and the mail rings.
    func testAReturnWrittenToAWorkingAgentThatQueuedTheLineDoesNotHoldMail() async throws {
        let rig = try await rig()
        defer { withExtendedLifetime(rig.workspace) {} }
        report(rig, "working", turn: 2)
        _ = await rig.panel.surface.submitHCInput("also check the logs", submit: true, source: .socket)
        mail(rig, "01M7WIREQUEUED000000000001")
        XCTAssertEqual(rig.rings, 0, "held while it works")
        report(rig, "idle", turn: 3)
        await until("rung once idle, its composer read empty") { rig.rings == 1 }
    }

    /// A read the doorbell cannot judge (not a settled screen) holds under its own name; nothing is typed.
    func testAComposerThatCannotBeReadHoldsWithItsName() async throws {
        let rig = try await rig()
        defer { withExtendedLifetime(rig.workspace) {} }
        rig.workspace.mailboxHeadlessPaintForTesting = { [weak rig] _ in rig?.paintReads += 1; return .failure(.unterminated) }
        await heldAs(rig, "composer_unread", "01M7WIREUNREAD00000000000")
        XCTAssertTrue(rig.writer.received.isEmpty)
    }

    /// Before the text: a draft that appeared since the decision gets zero bytes.
    func testADraftBeforeTheTextGetsNoBytes() async throws {
        let rig = try await rig()
        defer { withExtendedLifetime(rig.workspace) {} }
        mail(rig, "01M7WIRELATEDRAFT000000001")
        rig.extra = "typed meanwhile"
        await rig.workspace.ringHeadlessMailboxDoorbellForTesting(surfaceId: rig.panel.id)
        XCTAssertTrue(rig.writer.received.isEmpty, "the pre-text read saw a draft")
        XCTAssertTrue(rig.rows.contains { $0.outcome == .doorbellSkipped && $0.reason == "draft" }, "held as a draft: \(rig.rows)")
    }

    func testAnAgentThatStartedWorkingGetsNoReturn() async throws {
        try await assertNoReturn(after: { [self] rig in rig.record = record("working", turn: 4) }, "hc says working")
    }

    func testTextAddedDuringThePauseGetsNoReturn() async throws {
        try await assertNoReturn(after: { rig in rig.extra = " and more" }, "the composer holds more than the line")
    }

    func testALineTakenByAnotherReturnGetsNoSecondReturn() async throws {
        try await assertNoReturn(after: { rig in rig.taken = true }, "the composer no longer holds the line")
    }

    func testAnAgentNoLongerInFrontGetsNoReturn() async throws {
        try await assertNoReturn(after: { rig in rig.foregroundGroup = 9_999 }, "another program in front")
    }

    func testAnOpenJournalTurnGetsNoReturn() async throws {
        try await assertNoReturn(after: { rig in
            var working = JournalSnapshot(owner: JournalOwner(panelID: rig.panel.id, agentKind: "codex", sessionID: "s"),
                                          workspaceID: nil, appInstanceID: UUID())
            working.phase = .working
            working.confirmation = .confirmed
            working.connection = .live
            rig.journal = working
        }, "a journal turn opened")
    }

    func testASettlingCodexInterruptionGetsNoReturn() async throws {
        try await assertNoReturn(after: { rig in
            var settling = JournalSnapshot(owner: JournalOwner(panelID: rig.panel.id, agentKind: "codex", sessionID: "s"),
                                           workspaceID: nil, appInstanceID: UUID())
            settling.phase = .idle
            settling.adapter = .codexTranscript
            settling.turnOutcome = "interrupted"
            settling.confirmation = .confirmed
            settling.connection = .live
            settling.observedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            rig.journal = settling
        }, "a Codex interruption settling")
    }

    func testAPanelThatGotAScreenGetsNoHeadlessReturn() async throws {
        try await assertNoReturn(after: { rig in rig.headless = false }, "the panel is shown")
    }

    /// A line whose Return the agent did not take stays in the composer: the next look reads it there and holds,
    /// never typing it again; a read without it ends the hold.
    func testAnUntakenLineIsHeldWhileTheComposerShowsItAndNeverRetyped() async throws {
        let rig = try await rig()
        defer { withExtendedLifetime(rig.workspace) {} }
        rig.writer.afterReturn { [weak rig] in await MainActor.run { rig?.extra = MailboxDoorbell.text } }
        await ring(rig, flip: nil)
        XCTAssertEqual(rig.writer.received, line + Data([13]))
        XCTAssertTrue(rig.ledger.strandedPending, "no turn: stranded")
        rig.writer.afterReturn(nil)
        mail(rig, "01M7WIRESTRANDED000000002")
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(rig.writer.received, line + Data([13]), "never typed again while the line sits there")
        XCTAssertEqual(rig.rings, 0)
    }

    /// Repair 1, blocker 1: the ring's pre-text read times out, so nothing is written. The attempt gives back its
    /// idle period and its place under the cap, the held series looks again on its own timer, reads the composer
    /// and rings, and the retry delivers the line: no turn edge anywhere.
    func testARefusalBeforeTheTextGivesItsAttemptBackAndTheHeldSeriesRingsAgain() async throws {
        let rig = try await rig()
        defer { withExtendedLifetime(rig.workspace) {} }
        rig.workspace.mailboxDoorbellDelayScaleForTesting = 0.001
        rig.workspace.mailboxQueueLiveWithoutDispatcherForTesting = true
        mail(rig, "01M7WIREREFUSE00000000001")
        await until("the arrival read the composer and rang") { rig.rings == 1 }
        rig.failNextReads = 1
        await rig.workspace.ringHeadlessMailboxDoorbellForTesting(surfaceId: rig.panel.id)
        XCTAssertTrue(rig.writer.received.isEmpty, "zero bytes")
        XCTAssertNil(rig.ledger.rungEpoch, "the idle period is given back")
        XCTAssertTrue(rig.ledger.attempts.isEmpty, "and its place under the cap")
        XCTAssertTrue(rig.rows.contains { $0.outcome == .doorbellSkipped && $0.reason == "composer_unread" && $0.why == "attach_timeout" },
                      "held under the read's name, not as a failed attempt: \(rig.rows)")
        await until("the held series looked again and rang, with no turn edge", seconds: 6) { rig.rings == 2 }
        await rig.workspace.ringHeadlessMailboxDoorbellForTesting(surfaceId: rig.panel.id)
        XCTAssertEqual(rig.writer.received, line + Data([13]), "the retry typed the line and its Return")
    }

    /// C11H-327: the composer reads empty every time, but the input refuses every write before its text (a port
    /// that stays shut: a latched input fault, no attachment). Each refused ring gives back its idle period yet keeps
    /// its place under the cap, and the held series carries on across it, so the looks back off (5, 15, 30 s)
    /// instead of ringing every 5 s for good with the cap never counting a ring.
    func testARefusalThatPersistsBacksOffOnTheHeldSeriesAndCountsUnderTheCap() async throws {
        let rig = try await rig()
        defer { withExtendedLifetime(rig.workspace) {} }
        rig.workspace.mailboxDoorbellDelayScaleForTesting = 0.001
        rig.workspace.mailboxQueueLiveWithoutDispatcherForTesting = true
        rig.writer.refuseWrites(.unavailable)
        mail(rig, "01M7WIREPERSIST000000001")
        var next: [TimeInterval] = []
        for ring in 1...3 {
            await until("look \(ring) read an empty composer and rang", seconds: 6) { rig.rings == ring }
            let scheduled = rig.rechecks.count
            await rig.workspace.ringHeadlessMailboxDoorbellForTesting(surfaceId: rig.panel.id)
            XCTAssertEqual(rig.rechecks.count, scheduled + 1, "the refused ring schedules one look")
            next.append(rig.rechecks.last ?? -1)
            XCTAssertTrue(rig.writer.received.isEmpty, "zero bytes")
            XCTAssertNil(rig.ledger.rungEpoch, "the idle period is given back, so a look can ring with no turn edge")
            XCTAssertEqual(rig.ledger.attempts.count, ring, "each refused ring stays under the cap")
            XCTAssertTrue(rig.rows.contains { $0.outcome == .doorbellFailed && $0.reason == "hc_input_unavailable" },
                          "the row names the input's refusal: \(rig.rows)")
        }
        XCTAssertEqual(next, [5, 15, 30], "the held series carries on across the refused rings")
    }

    /// Repair 1, blocker 2: the ring's line was not taken (no turn), then the composer emptied while the agent
    /// stayed idle. The held series' next look reads the composer (read-only, typing nothing) and ends the hold, so
    /// the normal policy applies instead of a hold that only a shown panel could end.
    func testAStrandedLineThatLeavesTheComposerEndsItsHoldOnTheNextScheduledLook() async throws {
        let rig = try await rig()
        defer { withExtendedLifetime(rig.workspace) {} }
        rig.workspace.mailboxDoorbellDelayScaleForTesting = 0.001
        rig.workspace.mailboxQueueLiveWithoutDispatcherForTesting = true
        await ring(rig, flip: nil)
        XCTAssertTrue(rig.rows.contains { $0.reason == "stranded" }, "no turn: stranded: \(rig.rows)")
        await until("a scheduled look read the empty composer and ended the hold", seconds: 6) {
            rig.ledger.headlessStrandedEpoch == nil && !rig.ledger.strandedPending
        }
        XCTAssertEqual(rig.writer.received, line + Data([13]), "nothing typed, no second Return")
    }

    /// Repair 1b: a stranded line read back exactly, with hc idle, gets its bare Return (c11's own line and nothing
    /// else), through the ring's tail, and is delivered on the agent's turn. The line itself is typed once.
    func testAStrandedLineReadBackExactlyGetsItsReturnAndIsDelivered() async throws {
        let rig = try await rig()
        defer { withExtendedLifetime(rig.workspace) {} }
        rig.workspace.mailboxDoorbellDelayScaleForTesting = 0.001
        rig.workspace.mailboxQueueLiveWithoutDispatcherForTesting = true
        rig.writer.afterReturn { [weak rig] in await MainActor.run { rig?.extra = MailboxDoorbell.text } }
        await ring(rig, flip: nil)
        XCTAssertNotNil(rig.ledger.headlessStrandedEpoch, "no turn: stranded, the line still in the composer")
        let saved = SendSubmitConfirmation.waitSeconds
        SendSubmitConfirmation.waitSeconds = 2
        defer { SendSubmitConfirmation.waitSeconds = saved }
        rig.writer.afterReturn { [weak rig, self] in
            await MainActor.run { if let rig { rig.extra = ""; self.report(rig, "working", turn: 2) } }
        }
        await until("the held look's bare Return was taken", seconds: 6) { !rig.ledger.coveredIds.isEmpty }
        XCTAssertEqual(rig.writer.received, line + Data([13, 13]), "the line once, then a bare Return")
        XCTAssertNil(rig.ledger.headlessStrandedEpoch)
        XCTAssertFalse(rig.ledger.strandedPending)
    }

    /// Repair 1b: a `c11 send` to the same panel while a doorbell is between its line and its Return would be
    /// submitted with that line. The ring holds the panel for its whole length, and a send then is busy.
    func testASendDuringTheRingsPauseIsBusy() async throws {
        let rig = try await rig()
        defer { withExtendedLifetime(rig.workspace) {} }
        let seen = ReadCounts()
        await ring(rig, flip: { rig2 in
            if FeedAnswerInFlight.isActive(panelID: rig2.panel.id),
               HCHeadless.sendDecision(record: rig2.record, allowUnguarded: true, doorbellInFlight: true) == .busy {
                seen.read()
            }
        })
        XCTAssertEqual(seen.snapshot.0, 1, "between the line and its Return the panel is held and a send is busy")
        XCTAssertFalse(FeedAnswerInFlight.isActive(panelID: rig.panel.id), "released when the ring ends")
    }

    /// The Captain's #317 review, item 2: a panel that gets its screen looks again at once.
    func testAPanelThatGetsItsScreenLooksAgainAtOnce() async throws {
        let rig = try await rig(leftover: "half typed draft")
        defer { withExtendedLifetime(rig.workspace) {} }
        let saved = TerminalSurface.onLeftHeadless
        var handed: [(UUID, UUID?)] = []
        TerminalSurface.onLeftHeadless = { handed.append(($0, $1)) }
        defer { TerminalSurface.onLeftHeadless = saved }
        await heldAs(rig, "draft", "01M7WIRESHOWN000000000000")
        rig.panel.surface.handOffHeadlessHC(to: HCNativeBridge.headless(panelID: rig.panel.id, report: { _ in }))
        XCTAssertEqual(handed.map(\.0), [rig.panel.id], "the hand-off tells the workspace")
        rig.headless = false
        rig.workspace.mailboxDoorbellScreenForTesting = { _ in .empty }
        rig.workspace.mailboxPanelGotScreen(surfaceId: rig.panel.id)
        await until("rung on its screen without waiting for the held series") { rig.rings == 1 }
    }
}
