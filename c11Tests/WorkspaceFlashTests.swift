import XCTest
import AppKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// CMUX-10: persistent-flash registration + cancel + sidebar fan-out.
@MainActor
final class WorkspaceFlashTests: XCTestCase {
    /// A short pulse duration so persistent timers can't fire mid-test if the
    /// run is slower than expected. The tests don't assert on the timer
    /// firing — they assert on the registration/cancel state machine.
    private let pinnedMs: Int = 600

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(pinnedMs, forKey: NotificationFlashDurationSettings.storageKey)
        UserDefaults.standard.set(true, forKey: NotificationAreaFlashSettings.enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: NotificationFlashDurationSettings.storageKey)
        UserDefaults.standard.removeObject(forKey: NotificationAreaFlashSettings.enabledKey)
        super.tearDown()
    }

    func testOneShotFlashFansOutToSidebarRequestWithoutRegisteringPersistentState() {
        let workspace = Workspace(title: "flash-test")
        let panelId = UUID()
        XCTAssertNil(workspace.sidebarFlashRequest)

        workspace.triggerFocusFlash(
            panelId: panelId,
            appearance: FlashAppearance.current(envelope: .paneRing)
        )

        XCTAssertEqual(workspace.sidebarFlashRequest?.panelId, panelId)
        XCTAssertEqual(workspace.sidebarFlashRequest?.workspaceId, workspace.id)
        XCTAssertNil(workspace.persistentFlashPanels[panelId])
    }

    func testRepeatPublishesANewRequestWithTheCurrentColorAndOriginalTiming() {
        let workspace = Workspace(title: "flash-test")
        let panelId = UUID()
        let first = workspace.triggerFocusFlash(
            panelId: panelId, appearance: FlashAppearance(color: .red, envelope: .paneRing)
        )
        let time = FlashRequestTime()
        let second = workspace.triggerFocusFlash(
            panelId: panelId, appearance: FlashAppearance(color: .blue, envelope: .paneRing),
            source: "socket", requestedAt: time
        )
        XCTAssertNotEqual(first?.id, second?.id)
        XCTAssertEqual(workspace.sidebarFlashRequest, second)
        XCTAssertEqual(second?.appearance.color, NSColor.blue)
        XCTAssertEqual(second?.time, time)
        XCTAssertEqual(second?.source, "socket")
    }

    func testPersistentFlashRegistersStateAndKeepsRegistrationUntilCancel() {
        let workspace = Workspace(title: "flash-test")
        let panelId = UUID()

        workspace.triggerFocusFlash(
            panelId: panelId,
            appearance: FlashAppearance.current(envelope: .paneRing),
            persistent: true
        )

        let registered = workspace.persistentFlashPanels[panelId]
        XCTAssertNotNil(registered, "Persistent flash should register state on the workspace")

        workspace.cancelPersistentFlash(panelId: panelId)
        XCTAssertNil(workspace.persistentFlashPanels[panelId])
    }

    func testPersistentTimerPulsesKeepAnimatingWithoutRepeatingEvents() async throws {
        // EventLog reconciles its parent directory. Keep this fixture out of
        // the host's shared temporary directory and its unrelated history files.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flash-repeat-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("events.ndjson")
        let log = EventLog(url: url, instance: "flash-repeat")
        log.open()
        EventEmitter.shared.startForTesting(log: log, instance: "flash-repeat")
        let workspace = Workspace(title: "flash-repeat")
        let panelId = UUID()
        defer {
            workspace.cancelAllPersistentFlashes()
            EventEmitter.shared.resetForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let initial = try XCTUnwrap(workspace.triggerFocusFlash(
            panelId: panelId, appearance: FlashAppearance.current(), persistent: true, source: "socket"
        ))
        EventEmitter.shared.emitFlashDrawn(initial, channel: "sidebar")
        let timer = try XCTUnwrap(workspace.persistentFlashPanels[panelId]?.timer)
        var ids = Set([initial.id])
        for _ in 0..<3 {
            timer.fire()
            // The real timer enqueues its fan-out on main. Drain that hop.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            let pulse = try XCTUnwrap(workspace.sidebarFlashRequest)
            XCTAssertTrue(ids.insert(pulse.id).inserted, "Each timer tick must still start a fresh animation")
            EventEmitter.shared.emitFlashDrawn(pulse, channel: "sidebar")
        }
        EventEmitter.shared.flush()
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        for type in ["flash.requested", "flash.drawn"] {
            let matching = events.filter { $0["type"] as? String == type }
            XCTAssertEqual(matching.count, 1, "Only the initial persistent pulse records \(type)")
            XCTAssertEqual((matching.first?["payload"] as? [String: Any])?["request_id"] as? String,
                           initial.id.uuidString)
        }
    }

    func testCancelAllPersistentFlashesClearsEveryRegistration() {
        let workspace = Workspace(title: "flash-test")
        let panelA = UUID()
        let panelB = UUID()

        workspace.triggerFocusFlash(
            panelId: panelA,
            appearance: FlashAppearance.current(envelope: .paneRing),
            persistent: true
        )
        workspace.triggerFocusFlash(
            panelId: panelB,
            appearance: FlashAppearance(color: .red, envelope: .paneRing),
            persistent: true
        )
        XCTAssertEqual(workspace.persistentFlashPanels.count, 2)

        workspace.cancelAllPersistentFlashes()
        XCTAssertTrue(workspace.persistentFlashPanels.isEmpty)
    }

    func testCancelOnUnregisteredPanelIsIdempotent() {
        let workspace = Workspace(title: "flash-test")
        let panelId = UUID()
        // No prior persistent flash; cancel should not crash or alter state.
        workspace.cancelPersistentFlash(panelId: panelId)
        XCTAssertTrue(workspace.persistentFlashPanels.isEmpty)
    }

    func testRetriggerPersistentReplacesExistingTimerWithoutLeaking() {
        let workspace = Workspace(title: "flash-test")
        let panelId = UUID()

        workspace.triggerFocusFlash(
            panelId: panelId,
            appearance: FlashAppearance.current(envelope: .paneRing),
            persistent: true
        )
        let firstTimer = workspace.persistentFlashPanels[panelId]?.timer

        workspace.triggerFocusFlash(
            panelId: panelId,
            appearance: FlashAppearance(color: .blue, envelope: .paneRing),
            persistent: true
        )
        let secondTimer = workspace.persistentFlashPanels[panelId]?.timer

        XCTAssertNotNil(firstTimer)
        XCTAssertNotNil(secondTimer)
        XCTAssertFalse(firstTimer === secondTimer, "Re-trigger should replace the timer instance")
        // CMUX-10: identity-difference alone does not prove the previous
        // timer was invalidated. Without explicit `isValid == false`, a
        // regression that replaced the entry without calling
        // `existing.timer.invalidate()` would still pass.
        XCTAssertEqual(firstTimer?.isValid, false, "Re-trigger must invalidate the previous timer")

        workspace.cancelPersistentFlash(panelId: panelId)
    }

    func testTeardownAllPanelsCancelsEveryPersistentFlash() {
        let workspace = Workspace(title: "flash-test")
        let panelA = UUID()
        let panelB = UUID()

        workspace.triggerFocusFlash(
            panelId: panelA,
            appearance: FlashAppearance.current(envelope: .paneRing),
            persistent: true
        )
        workspace.triggerFocusFlash(
            panelId: panelB,
            appearance: FlashAppearance.current(envelope: .paneRing),
            persistent: true
        )
        let timerA = workspace.persistentFlashPanels[panelA]?.timer
        let timerB = workspace.persistentFlashPanels[panelB]?.timer
        XCTAssertEqual(workspace.persistentFlashPanels.count, 2)

        workspace.teardownAllPanels()

        XCTAssertTrue(workspace.persistentFlashPanels.isEmpty)
        XCTAssertEqual(timerA?.isValid, false, "teardown must invalidate persistent timers")
        XCTAssertEqual(timerB?.isValid, false, "teardown must invalidate persistent timers")
    }

    func testDeinitInvalidatesPersistentFlashTimers() {
        // Capture timers from a workspace that is allowed to deallocate.
        // Without `cancelPersistentFlash` cleanup in `deinit`, the run loop
        // would keep firing the timer forever after `[weak self]` resolves nil.
        weak var weakRef: Workspace?
        var capturedTimer: Timer?
        autoreleasepool {
            let workspace = Workspace(title: "flash-test")
            weakRef = workspace
            let panelId = UUID()
            workspace.triggerFocusFlash(
                panelId: panelId,
                appearance: FlashAppearance.current(envelope: .paneRing),
                persistent: true
            )
            capturedTimer = workspace.persistentFlashPanels[panelId]?.timer
            XCTAssertNotNil(capturedTimer)
        }
        // After the autoreleasepool drains, `Workspace` should deallocate;
        // `deinit` must invalidate the timer so the run loop drops its retain.
        XCTAssertNil(weakRef, "Workspace should deallocate")
        XCTAssertEqual(capturedTimer?.isValid, false, "deinit must invalidate persistent timers")
    }

    func testAreaFlashDisabledGuardSilencesAllChannels() {
        UserDefaults.standard.set(false, forKey: NotificationAreaFlashSettings.enabledKey)
        defer { UserDefaults.standard.set(true, forKey: NotificationAreaFlashSettings.enabledKey) }

        let workspace = Workspace(title: "flash-test")
        let panelId = UUID()
        let initialRequest = workspace.sidebarFlashRequest

        workspace.triggerFocusFlash(
            panelId: panelId,
            appearance: FlashAppearance.current(envelope: .paneRing),
            persistent: true
        )

        XCTAssertEqual(workspace.sidebarFlashRequest, initialRequest)
        XCTAssertNil(workspace.persistentFlashPanels[panelId])
    }
}
