import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-23 (plan ticket 3, part 3B): panel numbers, the high-water mark and
/// port reservations survive restarts, keyed by UUID, never by order.
@MainActor
final class PanelAllocationRegistryTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("panel-allocations-test.json") }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelAllocationRegistryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Arithmetic fixture for range layout (base 9100, size 10). The app's
    /// own default is c11's base; see `testDefaultPortBaseIsC11hsOwnRange`.
    private let fixture = PortAllocationSettings(base: 9100, size: 10)

    private func makeRegistry(
        settings: PortAllocationSettings? = nil,
        writer: PanelAllocationWriter? = nil
    ) -> PanelAllocationRegistry {
        let settings = settings ?? fixture
        return PanelAllocationRegistry(fileURL: fileURL, portSettings: { settings }, writer: writer)
    }

    /// A clean quit: everything scheduled reaches disk, then a new process loads it.
    private func restart(
        _ registry: PanelAllocationRegistry,
        settings: PortAllocationSettings? = nil
    ) -> PanelAllocationRegistry {
        registry.flushSynchronously()
        return makeRegistry(settings: settings)
    }

    // MARK: Numbers

    func testReorderedAndGappedPanelsKeepTheirNumbersAcrossRestart() {
        let registry = makeRegistry()
        let ids = (0..<6).map { _ in UUID() }
        let before = ids.map { registry.panelNumber(for: $0) }
        XCTAssertEqual(before, [1, 2, 3, 4, 5, 6])
        registry.releasePanels([ids[2], ids[4]])

        let restarted = restart(registry)
        // Restore asks in a different order than creation (a reorder).
        let survivors = [ids[3], ids[0], ids[5], ids[1]]
        let after = survivors.map { restarted.panelNumber(for: $0) }
        XCTAssertEqual(after, [4, 1, 6, 2])
        XCTAssertEqual(restarted.panelId(forNumber: 4), ids[3])
        XCTAssertNil(restarted.panelId(forNumber: 3), "a closed panel's number names nothing")
        XCTAssertEqual(restarted.panelNumber(for: UUID()), 7, "a new panel lands above the old high-water mark")
    }

    func testClosedNumbersAreNotReusedAfterRestartEvenWhenTheNewestCloses() {
        let registry = makeRegistry()
        let ids = (0..<3).map { _ in UUID() }
        ids.forEach { _ = registry.panelNumber(for: $0) }
        registry.releasePanels(Set(ids))

        let restarted = restart(registry)
        XCTAssertEqual(restarted.panelNumber(for: UUID()), 4)
    }

    func testTwoWindowsRestoredInReversedOrderKeepNumbersAndRanges() {
        let registry = makeRegistry()
        let windowA = (workspace: UUID(), panels: [UUID(), UUID()])
        let windowB = (workspace: UUID(), panels: [UUID(), UUID()])
        var recorded: [UUID: PanelAllocationRegistry.LaunchAllocation] = [:]
        for window in [windowA, windowB] {
            for panel in window.panels {
                recorded[panel] = registry.allocationForLaunch(panelId: panel, workspaceId: window.workspace)
            }
        }

        let restarted = restart(registry)
        for window in [windowB, windowA] {
            for panel in window.panels.reversed() {
                let again = restarted.allocationForLaunch(panelId: panel, workspaceId: window.workspace)
                XCTAssertEqual(again.panelNumber, recorded[panel]?.panelNumber)
                XCTAssertEqual(again.ports, recorded[panel]?.ports)
            }
        }
        XCTAssertNotEqual(recorded[windowA.panels[0]]?.ports, recorded[windowB.panels[0]]?.ports)
    }

    // MARK: Ports

    func testNewWorkspaceAfterRestartGetsARangeDisjointFromEveryLoadedRange() throws {
        let registry = makeRegistry()
        let first = registry.allocationForLaunch(panelId: UUID(), workspaceId: UUID())
        let second = registry.allocationForLaunch(panelId: UUID(), workspaceId: UUID())

        let restarted = restart(registry)
        let fresh = restarted.allocationForLaunch(panelId: UUID(), workspaceId: UUID())
        let freshPorts = try XCTUnwrap(fresh.ports)
        for old in [first, second] {
            XCTAssertFalse(freshPorts.overlaps(try XCTUnwrap(old.ports)), "\(freshPorts) overlaps \(String(describing: old.ports))")
        }
        XCTAssertGreaterThan(fresh.panelNumber, second.panelNumber)
    }

    func testChangedPortSettingsKeepExistingRangesAndAvoidThem() throws {
        let registry = makeRegistry(settings: PortAllocationSettings(base: 9100, size: 10))
        let workspace = UUID()
        let original = try XCTUnwrap(registry.allocationForLaunch(panelId: UUID(), workspaceId: workspace).ports)
        XCTAssertEqual(original, PortReservation(start: 9100, end: 9109))

        let restarted = restart(registry, settings: PortAllocationSettings(base: 9105, size: 20))
        let kept = try XCTUnwrap(restarted.allocationForLaunch(panelId: UUID(), workspaceId: workspace).ports)
        XCTAssertEqual(kept, original, "a surviving workspace's range never moves with the settings")

        let fresh = try XCTUnwrap(restarted.allocationForLaunch(panelId: UUID(), workspaceId: UUID()).ports)
        XCTAssertEqual(fresh.size, 20)
        XCTAssertFalse(fresh.overlaps(original))
        XCTAssertEqual(fresh, PortReservation(start: 9125, end: 9144))
    }

    func testAMovedPanelKeepsItsOwnRangeReservedAfterItsWorkspaceCloses() throws {
        let registry = makeRegistry()
        let panel = UUID()
        let oldWorkspace = UUID()
        let held = try XCTUnwrap(registry.allocationForLaunch(panelId: panel, workspaceId: oldWorkspace).ports)
        // The panel moved elsewhere (or into Recovered); its old workspace closed.
        registry.releaseWorkspaces([oldWorkspace])

        let restarted = restart(registry)
        let fresh = try XCTUnwrap(restarted.allocationForLaunch(panelId: UUID(), workspaceId: UUID()).ports)
        XCTAssertFalse(fresh.overlaps(held))
        XCTAssertEqual(restarted.record(for: panel)?.ports, held)
    }

    /// Review finding (PR 15): a closed exec workspace's background jobs
    /// (`nohup`, a dev server) can outlive it, so its range must not go to the
    /// next workspace in the same app run. main never reused one in-process.
    func testClosedWorkspaceRangeIsNotReusedInTheSameRun() throws {
        let registry = makeRegistry()
        let (panelA, workspaceA) = (UUID(), UUID())
        let a = try XCTUnwrap(registry.allocationForLaunch(panelId: panelA, workspaceId: workspaceA).ports)
        let b = try XCTUnwrap(registry.allocationForLaunch(panelId: UUID(), workspaceId: UUID()).ports)
        // Close A the way the app does: its panels close for good, then the workspace.
        registry.releasePanels([panelA])
        registry.releaseWorkspacesClosedForGood([workspaceA], isTerminatingApp: false)
        XCTAssertNil(registry.record(for: panelA))

        let c = try XCTUnwrap(registry.allocationForLaunch(panelId: UUID(), workspaceId: UUID()).ports)
        XCTAssertFalse(c.overlaps(a), "\(c) reuses closed workspace range \(a)")
        XCTAssertFalse(c.overlaps(b))
        XCTAssertEqual(c, PortReservation(start: 9120, end: 9129))
    }

    func testQuittingKeepsWorkspaceReservationsForTheRestore() throws {
        let registry = makeRegistry()
        let workspace = UUID()
        let held = try XCTUnwrap(registry.allocationForLaunch(panelId: UUID(), workspaceId: workspace).ports)
        registry.releaseWorkspacesClosedForGood([workspace], isTerminatingApp: true)

        let restarted = restart(registry)
        XCTAssertEqual(restarted.ledger.workspacePorts[workspace], held)
    }

    /// Merge-gate finding (PR 15 vs #17): c11 hands out its own range
    /// (29100 by default, from this app's defaults), never c11's 9100.
    func testDefaultPortBaseIsC11hsOwnRange() throws {
        let name = "c11-panel-allocations-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertEqual(PortAllocationSettings.default.base, C11Identity.defaultPortBase)
        XCTAssertEqual(PortAllocationSettings.current(defaults: defaults), PortAllocationSettings(base: 29100, size: 10))
        let registry = PanelAllocationRegistry(fileURL: fileURL, portSettings: { .current(defaults: defaults) })
        XCTAssertEqual(
            registry.allocationForLaunch(panelId: UUID(), workspaceId: UUID()).ports,
            PortReservation(start: 29100, end: 29109)
        )

        defaults.set(29250, forKey: C11Identity.portBaseDefaultsKey)
        defaults.set(20, forKey: "cmuxPortRange")
        XCTAssertEqual(PortAllocationSettings.current(defaults: defaults), PortAllocationSettings(base: 29250, size: 20))
        defaults.set(0, forKey: C11Identity.portBaseDefaultsKey)
        XCTAssertEqual(PortAllocationSettings.current(defaults: defaults).base, 29100, "a non-positive base falls back to c11's, not c11's")
    }

    func testExhaustionNeverWrapsIntoAReservedRange() {
        let settings = PortAllocationSettings(base: 65_516, size: 10)
        let registry = makeRegistry(settings: settings)
        let a = registry.allocationForLaunch(panelId: UUID(), workspaceId: UUID())
        let b = registry.allocationForLaunch(panelId: UUID(), workspaceId: UUID())
        XCTAssertEqual(a.ports, PortReservation(start: 65_516, end: 65_525))
        XCTAssertEqual(b.ports, PortReservation(start: 65_526, end: 65_535))

        let exhaustedWorkspace = UUID()
        let c = registry.allocationForLaunch(panelId: UUID(), workspaceId: exhaustedWorkspace)
        XCTAssertNil(c.ports)
        XCTAssertEqual(registry.takeIssues(), [.portsExhausted(workspaceId: exhaustedWorkspace)])
        _ = registry.allocationForLaunch(panelId: UUID(), workspaceId: exhaustedWorkspace)
        XCTAssertEqual(registry.takeIssues(), [], "reported once per workspace")
    }

    func testFirstFitSkipsAnOverlappingUnalignedReservation() {
        let reserved = [PortReservation(start: 9105, end: 9124)]
        let fresh = PanelAllocationLedger.firstFreeRange(settings: fixture, reserved: reserved)
        XCTAssertEqual(fresh, PortReservation(start: 9130, end: 9139), "next aligned slot past the blocker")
    }

    // MARK: Orphans and restore

    func testPersistentOrphanKeepsNumberAndRangeThroughRestoreWhileDeadPanelsGo() throws {
        let registry = makeRegistry()
        let workspace = UUID()
        let orphan = UUID()
        let deadShell = UUID()
        let restored = UUID()
        let orphanAllocation = registry.allocationForLaunch(panelId: orphan, workspaceId: workspace, outlivesApp: true)
        let deadAllocation = registry.allocationForLaunch(panelId: deadShell, workspaceId: workspace)
        let restoredAllocation = registry.allocationForLaunch(panelId: restored, workspaceId: UUID())

        let restarted = restart(registry)
        // The orphan's workspace did not come back; only `restored` is in the graph.
        restarted.reconcileAfterRestore(livePanels: [restored], liveWorkspaces: [])
        XCTAssertEqual(restarted.record(for: orphan)?.number, orphanAllocation.panelNumber)
        XCTAssertEqual(restarted.record(for: orphan)?.ports, orphanAllocation.ports)
        XCTAssertEqual(restarted.panelId(forNumber: orphanAllocation.panelNumber), orphan)
        XCTAssertNil(restarted.record(for: deadShell), "a local shell died with the old app")
        XCTAssertEqual(restarted.record(for: restored)?.number, restoredAllocation.panelNumber)

        let fresh = restarted.allocationForLaunch(panelId: UUID(), workspaceId: UUID())
        XCTAssertFalse(try XCTUnwrap(fresh.ports).overlaps(try XCTUnwrap(orphanAllocation.ports)))
        XCTAssertGreaterThan(fresh.panelNumber, deadAllocation.panelNumber)
        XCTAssertEqual(restarted.takeIssues(), [])
    }

    /// Review finding (PR 15): a session saved by an older build, with no
    /// allocation file, must be reported whatever order restore runs in.
    func testSavedSessionWithoutAnAllocationFileReportsMigrationAtLoad() throws {
        let session = directory.appendingPathComponent("session-test.json")
        try Data("{}".utf8).write(to: session)
        let registry = PanelAllocationRegistry(fileURL: fileURL, sessionSnapshotURL: session)
        _ = registry.panelNumber(for: UUID())   // the launch placeholder mints first
        XCTAssertEqual(registry.takeIssues(), [.migratedWithoutAllocations])

        registry.flushSynchronously()
        let next = PanelAllocationRegistry(fileURL: fileURL, sessionSnapshotURL: session)
        _ = next.panelNumber(for: UUID())
        XCTAssertEqual(next.takeIssues(), [], "reported once: the file exists from then on")
    }

    func testFirstLaunchWithoutASavedSessionIsNotAMigration() {
        let registry = PanelAllocationRegistry(
            fileURL: fileURL,
            sessionSnapshotURL: directory.appendingPathComponent("session-missing.json")
        )
        _ = registry.panelNumber(for: UUID())
        XCTAssertEqual(registry.takeIssues(), [])
    }

    /// Review finding (PR 15): the displaced launch placeholder must not keep
    /// a number a restored or surviving shell could be confused with.
    func testDisplacedLocalPanelsReleaseButOnesThatOutliveTheAppStay() throws {
        let registry = makeRegistry()
        let placeholder = UUID()
        let survivor = UUID()
        let placeholderAllocation = registry.allocationForLaunch(panelId: placeholder, workspaceId: UUID())
        let survivorAllocation = registry.allocationForLaunch(panelId: survivor, workspaceId: UUID(), outlivesApp: true)

        registry.releaseDisplacedPanels([placeholder, survivor])
        XCTAssertNil(registry.record(for: placeholder))
        XCTAssertNil(registry.panelId(forNumber: placeholderAllocation.panelNumber))
        XCTAssertEqual(registry.panelId(forNumber: survivorAllocation.panelNumber), survivor)
        let fresh = try XCTUnwrap(registry.allocationForLaunch(panelId: UUID(), workspaceId: UUID()).ports)
        XCTAssertFalse(fresh.overlaps(try XCTUnwrap(placeholderAllocation.ports)), "its shell ran in this app run")
    }

    /// Fleet mints every agent row's ref in one pass (C11H-320); each must be
    /// the ref `tree` prints, minted or not, after a restart included.
    func testFleetsBatchOfPanelRefsMatchesTheRefsTreePrints() {
        let registry = makeRegistry()
        let controller = TerminalController.makeForTesting(panelAllocations: registry)
        let shown = (0..<4).map { _ in UUID() }
        let single = shown.map { controller.surfaceRefOnly(forSurfaceUUID: $0) }
        let fresh = UUID()
        let batch = controller.v2PanelRefs(shown + [fresh])
        XCTAssertEqual(shown.map { batch[$0] }, single)
        XCTAssertEqual(batch[fresh], controller.surfaceRefOnly(forSurfaceUUID: fresh), "a new panel is minted as tree mints it")
        let restarted = TerminalController.makeForTesting(panelAllocations: restart(registry))
        XCTAssertEqual(restarted.v2PanelRefs(shown).values.sorted(), single.sorted(), "durable numbers survive a restart")
    }

    /// The controller's `panel:N` refs come from the registry: after a
    /// restart, a number resolves to its panel before this process has shown
    /// it, and a known panel keeps its number.
    func testControllerRefsSurviveARestartThroughTheRegistry() {
        let (a, b) = (UUID(), UUID())
        let before = makeRegistry()
        let firstRun = TerminalController.makeForTesting(panelAllocations: before)
        let numberA = firstRun.surfaceOrdinal(forSurfaceUUID: a)
        let numberB = firstRun.surfaceOrdinal(forSurfaceUUID: b)

        let after = restart(before)
        let secondRun = TerminalController.makeForTesting(panelAllocations: after)
        XCTAssertEqual(secondRun.v2ResolveHandleRef("panel:\(numberB)"), b)
        XCTAssertEqual(secondRun.v2ResolveHandleRef("surface:\(numberB)"), b)
        XCTAssertEqual(secondRun.surfaceOrdinal(forSurfaceUUID: a), numberA)
        XCTAssertEqual(secondRun.surfaceRefOnly(forSurfaceUUID: a), "panel:\(numberA)")
        XCTAssertGreaterThan(secondRun.surfaceOrdinal(forSurfaceUUID: UUID()), numberB)
    }

    // MARK: Crash between creation and autosave

    /// Reproduces the gap: until the write lands, a crash loses the
    /// allocation and the next launch hands its number and range to another
    /// panel. A launch that may outlive the app must wait for it.
    func testUndurableAllocationIsLostOnCrashAndTheBarrierHasNotOpened() {
        // The process dies before the write: it never reaches the disk.
        let processAlive = DispatchSemaphore(value: 0)
        defer { processAlive.signal() }
        let registry = makeRegistry(writer: PanelAllocationWriter(fileURL: fileURL, write: { _, _ in
            processAlive.wait()
        }))
        let allocation = registry.allocationForLaunch(panelId: UUID(), workspaceId: UUID(), outlivesApp: true)
        XCTAssertFalse(registry.writer.isDurable(allocation.generation))

        // Crash: no flush. The next process reads what is on disk.
        let afterCrash = makeRegistry()
        let other = afterCrash.allocationForLaunch(panelId: UUID(), workspaceId: UUID())
        XCTAssertEqual(other.panelNumber, allocation.panelNumber, "the lost number is minted again")
        XCTAssertEqual(other.ports, allocation.ports, "the lost range is handed out again")
    }

    func testAllocationIsOnDiskOnceTheLaunchBarrierOpens() async throws {
        let slow = PanelAllocationWriter(fileURL: fileURL, write: { file, url in
            Thread.sleep(forTimeInterval: 0.3)
            try PanelAllocationWriter.atomicWrite(file, url)
        })
        let registry = makeRegistry(writer: slow)
        let orphan = UUID()
        let allocation = registry.allocationForLaunch(panelId: orphan, workspaceId: UUID(), outlivesApp: true)
        let durable = await registry.waitUntilDurable(allocation)
        XCTAssertTrue(durable)

        // Crash right after the launch proceeds: no flush, read the disk.
        let afterCrash = makeRegistry()
        XCTAssertEqual(afterCrash.record(for: orphan)?.number, allocation.panelNumber)
        XCTAssertEqual(afterCrash.record(for: orphan)?.ports, allocation.ports)
        XCTAssertEqual(afterCrash.record(for: orphan)?.outlivesApp, true)
        let next = afterCrash.allocationForLaunch(panelId: UUID(), workspaceId: UUID())
        XCTAssertGreaterThan(next.panelNumber, allocation.panelNumber)
        XCTAssertFalse(try XCTUnwrap(next.ports).overlaps(try XCTUnwrap(allocation.ports)))
    }

    func testBarrierReportsAFailedWrite() async {
        struct Refused: Error {}
        let failing = PanelAllocationWriter(fileURL: fileURL, write: { _, _ in throw Refused() })
        let registry = makeRegistry(writer: failing)
        let allocation = registry.allocationForLaunch(panelId: UUID(), workspaceId: UUID(), outlivesApp: true)
        let durable = await registry.waitUntilDurable(allocation)
        XCTAssertFalse(durable)
    }

    /// Review finding (PR 15): a waiter that registers after a failure is
    /// published, while the drain is still running, must still resolve false
    /// instead of hanging the launch it guards.
    func testWaiterArrivingWhileAFailedDrainRetiresStillResolvesFalse() async {
        struct Refused: Error {}
        let writer = PanelAllocationWriter(fileURL: fileURL, write: { _, _ in throw Refused() })
        let resolved = expectation(description: "late waiter resolved")
        let result = ResultBox()
        writer.onFailure = { [weak writer] _ in
            guard let writer else { return }
            // Still inside the drain: the failure is published, the drain is not idle yet.
            Task.detached {
                result.set(await writer.waitUntilDurable(1))
                resolved.fulfill()
            }
            let deadline = Date().addingTimeInterval(2)
            while writer.pendingWaiterCount == 0, Date() < deadline { usleep(1_000) }
        }
        writer.schedule(PanelAllocationLedger().file, generation: 1)
        await fulfillment(of: [resolved], timeout: 5)
        XCTAssertEqual(result.value, false)
    }

    func testIssuesAfterStartupGoStraightToTheSink() {
        let registry = PanelAllocationRegistry(
            fileURL: fileURL,
            portSettings: { PortAllocationSettings(base: 65_526, size: 10) }
        )
        var delivered: [PanelAllocationIssue] = []
        registry.issueSink = { delivered.append($0) }
        _ = registry.allocationForLaunch(panelId: UUID(), workspaceId: UUID())
        let starved = UUID()
        _ = registry.allocationForLaunch(panelId: UUID(), workspaceId: starved)
        XCTAssertEqual(delivered, [.portsExhausted(workspaceId: starved)])
        XCTAssertEqual(registry.takeIssues(), [])
    }

    // MARK: Bad files fail visibly

    func testUnreadableFileIsQuarantinedNotOverwrittenAndReported() throws {
        try Data("{not json".utf8).write(to: fileURL)
        let registry = makeRegistry()
        XCTAssertEqual(registry.panelNumber(for: UUID()), 1)
        registry.flushSynchronously()

        let issues = registry.takeIssues()
        guard case .unreadableFile(let quarantined?) = issues.first else {
            return XCTFail("expected a quarantined unreadable file, got \(issues)")
        }
        let moved = directory.appendingPathComponent(quarantined)
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "{not json")
    }

    func testNewerVersionIsQuarantinedAndReported() throws {
        try Data(#"{"version": 99, "panelHighWater": 40, "panels": [], "workspaces": []}"#.utf8).write(to: fileURL)
        let registry = makeRegistry()
        _ = registry.panelNumber(for: UUID())
        guard case .unsupportedVersion(99, let quarantined?) = registry.takeIssues().first else {
            return XCTFail("expected an unsupported version")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(quarantined).path))
    }

    func testConflictingNumbersAreDroppedButNeverMintedAgain() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let file = PanelAllocationLedger.File(
            version: 1,
            panelHighWater: 2,
            panels: [
                .init(id: a, number: 5, ports: nil, outlivesApp: true),
                .init(id: b, number: 5, ports: nil, outlivesApp: true),
                .init(id: c, number: 3, ports: nil, outlivesApp: false),
            ],
            workspaces: []
        )
        try JSONEncoder().encode(file).write(to: fileURL)
        let registry = makeRegistry()
        XCTAssertNil(registry.record(for: a))
        XCTAssertNil(registry.record(for: b))
        XCTAssertEqual(registry.record(for: c)?.number, 3)
        XCTAssertEqual(registry.takeIssues(), [.conflictingPanelNumber(5)])
        XCTAssertNotEqual(registry.panelNumber(for: a), 5, "neither claimant is silently given 5")
        XCTAssertEqual(registry.panelNumber(for: UUID()), 7, "the mark covers every number seen")
    }

    func testOverlappingWorkspaceRangesKeepTheFirstAndReportTheRest() throws {
        let first = UUID(), second = UUID()
        let file = PanelAllocationLedger.File(
            version: 1,
            panelHighWater: 0,
            panels: [],
            workspaces: [
                .init(id: first, ports: PortReservation(start: 9100, end: 9109)),
                .init(id: second, ports: PortReservation(start: 9105, end: 9114)),
            ]
        )
        try JSONEncoder().encode(file).write(to: fileURL)
        let registry = makeRegistry()
        XCTAssertEqual(registry.ledger.workspacePorts[first], PortReservation(start: 9100, end: 9109))
        XCTAssertNil(registry.ledger.workspacePorts[second])
        XCTAssertEqual(registry.takeIssues(), [.conflictingWorkspacePorts(second)])
        let fresh = registry.allocationForLaunch(panelId: UUID(), workspaceId: second).ports
        XCTAssertEqual(fresh, PortReservation(start: 9110, end: 9119))
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
}
