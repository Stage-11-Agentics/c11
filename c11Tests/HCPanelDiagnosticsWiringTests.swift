import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// `c11 hc-diagnostics --json` listed no panels while hc served six terminals:
/// the recorder makes a row from the events a panel session sends it or from the
/// panel bindings in the session's snapshots, and neither existed. These tests
/// cover the events: they drive a real panel session into a real recorder and
/// read the JSON the CLI prints. `HCSessionTests` covers the bindings. Nothing here launches a process or touches the user's
/// log directory.
private actor ScriptedSession: HCSession {
    private(set) var resolveCalls = 0
    private(set) var createCalls = 0
    private(set) var activeResolves = 0
    private(set) var maximumActiveResolves = 0
    private var heldResolve: CheckedContinuation<Void, Never>?
    private var holdNextResolve = false
    func holdResolution() { holdNextResolve = true }
    func releaseResolution() { heldResolve?.resume(); heldResolve = nil }
    var resolved: HCLifecycle = .new
    var created: HCCreateResult = .rejectedBeforeTransmission(.coreUnreachable)
    var attachError: HCUnavailableReason = .inventoryPending
    /// Attachments `attach` hands out, in order, when `attachError` is cleared.
    private var attachments: [any HCAttachment] = []
    private var failsAttach = true
    func queueAttachments(_ list: [any HCAttachment]) { attachments = list; failsAttach = false }

    func script(resolved: HCLifecycle? = nil, created: HCCreateResult? = nil, attachError: HCUnavailableReason? = nil) {
        if let resolved { self.resolved = resolved }
        if let created { self.created = created }
        if let attachError { self.attachError = attachError }
    }

    nonisolated func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation { HCObservation() }
    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle {
        resolveCalls += 1
        activeResolves += 1
        maximumActiveResolves = max(maximumActiveResolves, activeResolves)
        defer { activeResolves -= 1 }
        let answer = resolved
        if holdNextResolve {
            holdNextResolve = false
            await withCheckedContinuation { heldResolve = $0 }
        }
        return answer
    }
    func create(_ request: HCCreateRequest) async -> HCCreateResult { createCalls += 1; return created }
    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        if failsAttach || attachments.isEmpty { throw attachError }
        return attachments.removeFirst()
    }
    func end(_ key: HCTerminalKey) async -> HCEndResult { .unresolved(key, .backendNotInstalled) }
    func diagnostics() async -> HCDiagnostics { await HCUnavailableRuntime().diagnostics() }
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { .refused(.backendNotInstalled) }
}

private final class FakeAttachment: HCAttachment, Sendable {
    let key: HCTerminalKey
    let generation: UInt64
    let input: any HCInputPort = HCUnavailableRuntime()
    init(key: HCTerminalKey, generation: UInt64) { self.key = key; self.generation = generation }
    func submit(_ request: HCInputRequest) async -> HCInputOutcome { .refused(.unavailable) }
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { nil }
    func updateDisplay(_ display: HCDisplayState) async -> HCControlOutcome { .unavailable(.backendNotInstalled) }
    func detach() {}
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [HCDiagnosticEvent] = []
    func append(_ event: HCDiagnosticEvent) { lock.lock(); stored.append(event); lock.unlock() }
    var events: [HCDiagnosticEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    /// The event names in order, for assertions that do not need the payload.
    var names: [String] {
        events.compactMap { event -> String? in
            switch event {
            case .attachmentProgress: return nil
            case .attach: return "attach"
            case .reattach: return "reattach"
            case .attachFailed: return "attachFailed"
            case .coreUnreachable: return "coreUnreachable"
            case .coreUnresolved: return "coreUnresolved"
            case .fallback: return "fallback"
            case .panelNew: return "panelNew"
            case .panelEnded: return "panelEnded"
            case .panelClosed: return "panelClosed"
            default: return "other"
            }
        }
    }
}

final class HCPanelDiagnosticsWiringTests: XCTestCase {
    private var directory: URL!
    private var recorder: HCDiagnosticRecorder!
    private let captured = Captured()
    private let key = HCTerminalKey(owningCoreID: "core1", localAddress: "t1b")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-panel-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        recorder = HCDiagnosticRecorder(logFile: directory.appendingPathComponent("hc-diagnostics.log"),
                                        counterFile: directory.appendingPathComponent("holder-lost.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func makePanel(identity: HCPanelIdentity, session: any HCSession = ScriptedSession()) -> HCPanelSession {
        let panel = HCPanelSession(identity: identity, session: session)
        let recorder = recorder!, captured = captured
        panel.diagnosticSink = { captured.append($0); recorder.record($0) }
        addTeardownBlock { HCPanelRestoreState.shared.remove(panelID: identity.panelID) }
        return panel
    }

    private var rows: [[String: Any]] { recorder.jsonObject()["panels"] as? [[String: Any]] ?? [] }
    private func row(_ panelID: UUID) -> [String: Any]? { rows.first { $0["panel_id"] as? String == panelID.uuidString } }
    private func count(_ needle: String) -> Int { recorder.logText().components(separatedBy: needle).count - 1 }

    @MainActor
    private func attachSurface(_ panel: HCPanelSession, machine: String? = nil) async -> Error? {
        let bridge = HCNativeBridge(panelID: panel.identity.panelID, rendering: HCUnavailableRenderingAdapter(),
                                    encoder: HCUnavailableInputEncoder(), report: { _ in })
        let launch = HCPanelLaunchSpec(argv: ["/bin/zsh", "-l"], cwd: "/Users/me", environment: [:], initialInput: nil,
                                       machine: machine)
        do {
            _ = try await panel.attachSurface(launch: launch, bridge: bridge,
                display: HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: 0, displayGeneration: 1),
                                        grid: HCGridSize(columns: 80, rows: 24)))
            return nil
        } catch { return error }
    }

    // MARK: attach and reattach

    @MainActor
    func testRepeatedResolutionOutcomesKeepTheFirstWaitAndLogOnlyTransitions() async {
        let identity = HCPanelIdentity(panelID: UUID(), origin: .restored)
        let session = ScriptedSession()
        let panel = makePanel(identity: identity, session: session)
        await session.script(resolved: .unresolved(identity, .inventoryPending))
        _ = await panel.resolveIdentity()
        func lines() -> [String] {
            recorder.logText().components(separatedBy: "\n").filter {
                $0.contains("panel_id=\(identity.panelID.uuidString)") && $0.contains("phase=resolve")
            }
        }
        let first = lines()
        XCTAssertEqual(first.count, 1)
        for _ in 0..<20 { _ = await panel.resolveIdentity() }
        XCTAssertEqual(lines(), first, "identical outcomes must preserve the first line and its wait_ms")

        await session.script(resolved: .new)
        for _ in 0..<20 { _ = await panel.resolveIdentity() }
        await session.script(resolved: .unresolved(identity, .inventoryPending))
        for _ in 0..<20 { _ = await panel.resolveIdentity() }
        let transitions = lines()
        XCTAssertEqual(transitions.count, 3)
        XCTAssertTrue(transitions.first?.contains("outcome=inventory_pending") == true)
        XCTAssertTrue(transitions.dropFirst().first?.contains("outcome=new") == true)
        XCTAssertTrue(transitions.last?.contains("outcome=inventory_pending") == true,
                      "returning to an earlier outcome is still a transition")
        panel.detachSurface()
    }

    @MainActor
    func testAnUnstartedPlaceholderDoesNotResolveItsOwnUnchangedInventoryAgain() async {
        let identity = HCPanelIdentity(panelID: UUID(), origin: .restored)
        let session = ScriptedSession()
        let panel = makePanel(identity: identity, session: session)
        let first = HCRevision(connectionGeneration: 1, sequence: 2)
        let ready = HCInventorySnapshot(readiness: .ready(first), revision: first)
        panel.receiveInventory(ready)
        for _ in 0..<100 { await Task.yield() }
        let once = await session.resolveCalls
        XCTAssertEqual(once, 1)
        // HCManagedSession.resolve republishes its current snapshot. That is
        // not new evidence and must not feed another resolve back into itself.
        panel.receiveInventory(ready)
        for _ in 0..<100 { await Task.yield() }
        let unchanged = await session.resolveCalls
        XCTAssertEqual(unchanged, once)
        let next = HCRevision(connectionGeneration: 1, sequence: 3)
        panel.receiveInventory(HCInventorySnapshot(readiness: .ready(next), revision: next))
        for _ in 0..<100 { await Task.yield() }
        let changed = await session.resolveCalls
        XCTAssertEqual(changed, once + 1, "a real inventory change still retries the lookup")
        panel.receiveInventory(HCInventorySnapshot(readiness: .ready(next), revision: next,
            source: HCShardID(index: 1)))
        for _ in 0..<100 { await Task.yield() }
        let anotherShard = await session.resolveCalls
        XCTAssertEqual(anotherShard, changed + 1, "identical revisions in different shards are different evidence")
        panel.detachSurface()
    }

    @MainActor
    func testReadyInventoryDuringLookupIsCoalescedWithoutCancellingOrLosingIt() async {
        let identity = HCPanelIdentity(panelID: UUID(), creationID: UUID(), origin: .restored)
        let session = ScriptedSession()
        await session.script(resolved: .unresolved(identity, .inventoryPending))
        await session.holdResolution()
        let panel = makePanel(identity: identity, session: session)
        panel.beginHiddenResolution()
        for _ in 0..<100 { await Task.yield() }
        let record = HCTerminalRecord(key: key, state: .running, pid: 41)
        await session.script(resolved: .live(record))
        let revision = HCRevision(connectionGeneration: 1, sequence: 2)
        let ready = HCInventorySnapshot(readiness: .ready(revision), revision: revision, records: [key: record])
        panel.receiveInventory(ready)
        panel.receiveInventory(ready)
        for _ in 0..<100 { await Task.yield() }
        let callsWhileHeld = await session.resolveCalls
        XCTAssertEqual(callsWhileHeld, 1, "ready updates join the current lookup")
        await session.releaseResolution()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(panel.identity.key, key, "the ready update must still get a lookup after the pending answer")
        let calls = await session.resolveCalls, maximum = await session.maximumActiveResolves
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(maximum, 1)
        panel.detachSurface()
        panel.beginHiddenResolution()
        for _ in 0..<100 { await Task.yield() }
        let afterDisposal = await session.resolveCalls
        XCTAssertEqual(afterDisposal, calls, "disposed runtimes cannot restart hidden resolution")
    }

    @MainActor
    func testKeylessRestoreReconcilesWhenInventoryBecomesReadyAfterFirstLookup() async {
        let identity = HCPanelIdentity(panelID: UUID(), creationID: UUID(), origin: .restored)
        let session = ScriptedSession()
        await session.script(resolved: .unresolved(identity, .inventoryPending))
        let panel = makePanel(identity: identity, session: session)
        panel.beginHiddenResolution()
        for _ in 0..<100 { await Task.yield() }
        let initialCalls = await session.resolveCalls
        XCTAssertEqual(initialCalls, 1)
        XCTAssertNil(panel.identity.key)

        let record = HCTerminalRecord(key: key, state: .running,
            labels: ["c11.panel": identity.panelID.uuidString,
                     "c11.creation": identity.creationID!.uuidString], pid: 41)
        await session.script(resolved: .live(record))
        let revision = HCRevision(connectionGeneration: 1, sequence: 2)
        panel.receiveInventory(HCInventorySnapshot(readiness: .ready(revision),
            revision: revision, records: [key: record]))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(panel.identity.key, key, "a pending first lookup must not strand a keyless restore")
        guard case .live = panel.lifecycle else { return XCTFail("restore never reconciled") }
        let creations = await session.createCalls
        XCTAssertEqual(creations, 0, "inventory reconciliation never starts another terminal")
        let log = recorder.logText()
        XCTAssertTrue(log.contains("phase=resolve outcome=inventory_pending wait_ms="))
        XCTAssertTrue(log.contains("terminal=t1b"))
        XCTAssertTrue(log.contains("phase=resolve outcome=live wait_ms="))
        panel.detachSurface()
    }

    /// C11H-82 (F13): after a core restart the surface's own start bound an
    /// attachment, then the reconnect owner retired that surface and reattached.
    /// `attachSurface` returned the bound (dead) attachment, so the panel refused
    /// every key as `staleIdentity`. A reattach releases it first.
    @MainActor
    func testAReattachGetsANewAttachmentNotTheDeadOneStillBound() async throws {
        let identity = HCPanelIdentity(panelID: UUID(), key: key)
        let session = ScriptedSession()
        let record = HCTerminalRecord(key: key, state: .running, pid: 41)
        await session.script(resolved: .live(record))
        let first = FakeAttachment(key: key, generation: 1)
        let second = FakeAttachment(key: key, generation: 2)
        await session.queueAttachments([first, second])
        let panel = makePanel(identity: identity, session: session)

        let firstError = await attachSurface(panel)
        XCTAssertNil(firstError)
        XCTAssertTrue(panel.attachment === first)
        // Without the release the second attach is answered by the bound one: the bug.
        let secondError = await attachSurface(panel)
        XCTAssertNil(secondError)
        XCTAssertTrue(panel.attachment === first, "control: a bound attachment is returned as it stands")

        panel.prepareReattach()
        XCTAssertNil(panel.attachment, "a reattach starts from no attachment")
        let thirdError = await attachSurface(panel)
        XCTAssertNil(thirdError)
        XCTAssertTrue(panel.attachment === second, "the reattach must bind the new attachment")
    }

    @MainActor
    func testBindingAnAttachmentCreatesTheRowTheCLIPrints() {
        let identity = HCPanelIdentity(panelID: UUID(), key: key)
        let panel = makePanel(identity: identity)
        XCTAssertTrue(rows.isEmpty, "control: before any attach the list is empty, as the guest saw")

        panel.publish(.live(HCTerminalRecord(key: key, state: .running, tty: "/dev/ttys004")))
        XCTAssertTrue(panel.bind(FakeAttachment(key: key, generation: 1),
                                 display: HCDisplayRevision(attachmentGeneration: 1, displayGeneration: 1)))

        let live = row(identity.panelID)
        XCTAssertEqual(live?["lifecycle"] as? String, "live")
        XCTAssertEqual(live?["terminal"] as? String, "t1b")
        XCTAssertEqual(live?["tty"] as? String, "/dev/ttys004")
        XCTAssertEqual(live?["serving_build"] as? String, HCPin.current.version)
        XCTAssertEqual(captured.names, ["attach"])
        XCTAssertEqual(count("event=attach "), 1)
    }

    @MainActor
    func testASecondAttachmentOfTheSamePanelIsAReattach() {
        let identity = HCPanelIdentity(panelID: UUID(), key: key)
        let panel = makePanel(identity: identity)
        panel.publish(.live(HCTerminalRecord(key: key, state: .running)))
        XCTAssertTrue(panel.bind(FakeAttachment(key: key, generation: 1),
                                 display: HCDisplayRevision(attachmentGeneration: 1, displayGeneration: 1)))
        XCTAssertTrue(panel.bind(FakeAttachment(key: key, generation: 2),
                                 display: HCDisplayRevision(attachmentGeneration: 2, displayGeneration: 1)))

        XCTAssertEqual(captured.names, ["attach", "reattach"])
        XCTAssertEqual(count("event=attach "), 1)
        XCTAssertEqual(count("event=reattach "), 1)
        XCTAssertEqual(rows.count, 1, "one panel is one row")
        XCTAssertEqual(row(identity.panelID)?["lifecycle"] as? String, "live")
    }

    @MainActor
    func testARefusedBindReportsNothing() {
        let identity = HCPanelIdentity(panelID: UUID(), key: key)
        let panel = makePanel(identity: identity)
        let other = HCTerminalKey(owningCoreID: "core1", localAddress: "t2c")
        XCTAssertFalse(panel.bind(FakeAttachment(key: other, generation: 1),
                                  display: HCDisplayRevision(attachmentGeneration: 1, displayGeneration: 1)))
        XCTAssertTrue(captured.events.isEmpty)
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: attach failure

    @MainActor
    func testAFailedAttachIsReportedWithItsPublicReason() async throws {
        let identity = HCPanelIdentity(panelID: UUID(), key: key)
        let session = ScriptedSession()
        await session.script(resolved: .live(HCTerminalRecord(key: key, state: .running)), attachError: .inventoryPending)
        let panel = makePanel(identity: identity, session: session)

        let error = await attachSurface(panel)
        XCTAssertEqual(error as? HCUnavailableReason, .inventoryPending)

        XCTAssertEqual(captured.names, ["attachFailed"])
        let failed = row(identity.panelID)
        XCTAssertEqual(failed?["terminal"] as? String, "t1b")
        XCTAssertEqual(failed?["reason"] as? String, "inventory_pending")
        XCTAssertEqual(count("event=attach_failed "), 1)
    }

    @MainActor
    func testACancelledAttachIsNotAFailure() async {
        let identity = HCPanelIdentity(panelID: UUID(), key: key)
        let session = ScriptedSession()
        await session.script(resolved: .live(HCTerminalRecord(key: key, state: .running)), attachError: .cancelled)
        let panel = makePanel(identity: identity, session: session)

        _ = await attachSurface(panel)

        XCTAssertFalse(captured.names.contains("attachFailed"), "a superseded attach is not a diagnosis")
    }

    // MARK: outage and end

    @MainActor
    func testAnUnreachableCoreIsReportedOncePerOutage() {
        let identity = HCPanelIdentity(panelID: UUID(), key: key)
        let panel = makePanel(identity: identity)

        panel.publish(.unresolved(identity, .coreUnreachable))
        panel.publish(.unresolved(identity, .coreUnreachable))
        panel.publish(.unresolved(identity, .coreUnreachable))
        XCTAssertEqual(captured.names, ["coreUnresolved"], "every inventory snapshot republishes the outage")
        let down = row(identity.panelID)
        XCTAssertEqual(down?["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(down?["reason"] as? String, "core_unreachable")
        XCTAssertEqual(down?["configured_build"] as? String, HCPin.current.version)

        panel.publish(.live(HCTerminalRecord(key: key, state: .running)))
        panel.publish(.unresolved(identity, .coreUnreachable))
        XCTAssertEqual(captured.names, ["coreUnresolved", "coreUnresolved"], "the next outage is a new occurrence")
    }

    @MainActor
    func testAnotherReasonIsNotReportedAsAnUnreachableCore() {
        let identity = HCPanelIdentity(panelID: UUID(), key: key)
        let panel = makePanel(identity: identity)
        panel.publish(.unresolved(identity, .inventoryPending))
        panel.publish(.unresolved(identity, .connectionLost))
        XCTAssertTrue(captured.events.isEmpty)
        XCTAssertTrue(rows.isEmpty)
    }

    @MainActor
    func testAnEndedTerminalIsReportedOnceWithItsReason() {
        let identity = HCPanelIdentity(panelID: UUID(), key: key)
        let panel = makePanel(identity: identity)
        func ended() -> HCLifecycle {
            // The evidence id is new on every snapshot, as receiveInventory builds it.
            .ended(HCEndEvidence(id: UUID(), key: key, revision: HCRevision(connectionGeneration: 1, sequence: 9),
                                 kind: .finished, hcReason: "holder_lost"))
        }
        panel.publish(.live(HCTerminalRecord(key: key, state: .running)))
        XCTAssertTrue(panel.bind(FakeAttachment(key: key, generation: 1),
                                 display: HCDisplayRevision(attachmentGeneration: 1, displayGeneration: 1)))
        panel.publish(ended())
        panel.publish(ended())

        XCTAssertEqual(captured.names, ["attach", "panelEnded"])
        let finished = row(identity.panelID)
        XCTAssertEqual(finished?["lifecycle"] as? String, "ended")
        XCTAssertEqual(finished?["reason"] as? String, "holder_lost")
        XCTAssertEqual(recorder.jsonObject()["holder_lost_count"] as? Int, 0, "an end event does not count a holder loss")
    }

    // MARK: new panels

    @MainActor
    func testACreationThatStaysUncertainShowsTheNewPanel() async {
        let identity = HCPanelIdentity(panelID: UUID(), origin: .fresh)
        let session = ScriptedSession()
        await session.script(resolved: .new, created: .unresolved(identity, .creationUncertain))
        let panel = makePanel(identity: identity, session: session)

        _ = await attachSurface(panel)

        XCTAssertEqual(captured.names.first, "panelNew")
        let new = row(identity.panelID)
        XCTAssertEqual(new?["lifecycle"] as? String, "new")
        XCTAssertEqual(new?["persistence"] as? String, "persistent")
    }

    @MainActor
    func testAFreshPanelWhoseCoreIsUnreachableIsListedAsAFallback() async {
        let identity = HCPanelIdentity(panelID: UUID(), origin: .fresh)
        let session = ScriptedSession()
        await session.script(resolved: .new, created: .rejectedBeforeTransmission(.coreUnreachable))
        let panel = makePanel(identity: identity, session: session)
        var fellBack = false
        panel.onFallback = { fellBack = true }

        _ = await attachSurface(panel)

        XCTAssertTrue(fellBack, "control: this is the plain-shell fallback path")
        XCTAssertEqual(captured.names, ["panelNew", "fallback"], "the fallback branch is the one place that says so")
        let fallback = row(identity.panelID)
        XCTAssertEqual(fallback?["lifecycle"] as? String, "fallback")
        XCTAssertEqual(fallback?["persistence"] as? String, "nonpersistent")
        XCTAssertEqual(fallback?["reason"] as? String, "core_unreachable")
    }

    // MARK: an unreachable core is not a fallback

    /// A fresh terminal whose `terminal.run` reply was lost has an outstanding
    /// creation that may still be running. Losing the core afterwards leaves it
    /// persistent and unresolved; only the real fallback branch says "fallback".
    @MainActor
    func testAnOutstandingCreationThatLosesTheCoreStaysUnresolvedAndPersistent() async {
        let identity = HCPanelIdentity(panelID: UUID(), origin: .fresh)
        let session = ScriptedSession()
        await session.script(resolved: .new, created: .unresolved(identity, .creationUncertain))
        let panel = makePanel(identity: identity, session: session)
        var fellBack = false
        panel.onFallback = { fellBack = true }
        _ = await attachSurface(panel)
        XCTAssertNotNil(panel.identity.creationID, "control: the creation is outstanding")

        // The initial-attach recovery resolves again and finds no core.
        panel.publish(.unresolved(panel.identity, .coreUnreachable))

        let waiting = row(identity.panelID)
        XCTAssertEqual(waiting?["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(waiting?["persistence"] as? String, "persistent")
        XCTAssertEqual(waiting?["reason"] as? String, "core_unreachable")
        XCTAssertFalse(recorder.logText().contains("event=fallback"))
        XCTAssertFalse(captured.names.contains("fallback"))
        XCTAssertFalse(fellBack, "the plain-shell fallback never ran")
        XCTAssertEqual(panel.identity.persistence, .persistent)
    }

    /// Before any creation starts a fresh panel has no creation ID, and hidden
    /// resolution can already find the core gone. Nothing has been decided: the
    /// panel is waiting, not a shell.
    @MainActor
    func testAFreshPanelThatMerelyFindsNoCoreIsUnresolvedBeforeAnyDecision() {
        let identity = HCPanelIdentity(panelID: UUID(), origin: .fresh)
        let panel = makePanel(identity: identity)

        panel.publish(.unresolved(identity, .coreUnreachable))

        let waiting = row(identity.panelID)
        XCTAssertEqual(waiting?["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(waiting?["persistence"] as? String, "persistent")
        XCTAssertFalse(recorder.logText().contains("event=fallback"))
        XCTAssertEqual(captured.names, ["coreUnresolved"])
    }

    /// The fallback branch excludes a panel placed on another machine, so a
    /// fresh Studio panel refused because the local core is unreachable waits.
    @MainActor
    func testAnUnreachableRemoteCreationIsUnresolvedNotAFallback() async {
        let identity = HCPanelIdentity(panelID: UUID(), origin: .fresh)
        let session = ScriptedSession()
        await session.script(resolved: .new, created: .rejectedBeforeTransmission(.coreUnreachable))
        let panel = makePanel(identity: identity, session: session)
        var fellBack = false
        panel.onFallback = { fellBack = true }

        _ = await attachSurface(panel, machine: "studio")

        let waiting = row(identity.panelID)
        XCTAssertEqual(waiting?["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(waiting?["persistence"] as? String, "persistent")
        XCTAssertFalse(recorder.logText().contains("event=fallback"))
        XCTAssertFalse(captured.names.contains("fallback"))
        XCTAssertFalse(fellBack)
    }

    /// The recorder's own inference (ingest, `coreUnreachable`) no longer reads a
    /// pending creation as a shell, and the explicit events decide the rest.
    func testTheRecorderOnlyInfersFallbackWithoutAnOutstandingCreation() {
        let pending = HCPanelIdentity(panelID: UUID(), persistence: .persistent, creationID: UUID(), origin: .fresh)
        let bare = HCPanelIdentity(panelID: UUID(), persistence: .persistent, origin: .fresh)
        recorder.record(.coreUnreachable(panel: pending, configuredBuild: HCPin.current.version))
        recorder.record(.coreUnreachable(panel: bare, configuredBuild: HCPin.current.version))
        XCTAssertEqual(row(pending.panelID)?["lifecycle"] as? String, "unresolved", "an outstanding creation is waiting")
        XCTAssertEqual(row(bare.panelID)?["lifecycle"] as? String, "fallback", "control: the recorded inference for a bare fresh panel")

        let named = HCPanelIdentity(panelID: UUID(), persistence: .persistent, origin: .fresh)
        recorder.record(.coreUnresolved(panel: named, configuredBuild: HCPin.current.version))
        XCTAssertEqual(row(named.panelID)?["lifecycle"] as? String, "unresolved", "explicitly unresolved beats the inference")
        recorder.record(.fallback(panel: HCPanelIdentity(panelID: named.panelID, persistence: .nonpersistent, origin: .fresh),
                                  configuredBuild: HCPin.current.version))
        XCTAssertEqual(row(named.panelID)?["lifecycle"] as? String, "fallback")
        XCTAssertEqual(row(named.panelID)?["persistence"] as? String, "nonpersistent")
        recorder.record(.coreUnresolved(panel: named, configuredBuild: HCPin.current.version))
        XCTAssertEqual(row(named.panelID)?["lifecycle"] as? String, "fallback", "a shell that fell back stays one")
    }
}
