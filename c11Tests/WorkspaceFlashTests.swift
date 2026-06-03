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
        UserDefaults.standard.set(true, forKey: NotificationPaneFlashSettings.enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: NotificationFlashDurationSettings.storageKey)
        UserDefaults.standard.removeObject(forKey: NotificationPaneFlashSettings.enabledKey)
        super.tearDown()
    }

    func testOneShotFlashFansOutToSidebarTokenWithoutRegisteringPersistentState() {
        let workspace = Workspace(title: "flash-test")
        let panelId = UUID()
        let initialToken = workspace.sidebarFlashToken

        workspace.triggerFocusFlash(
            panelId: panelId,
            appearance: FlashAppearance.current(envelope: .paneRing)
        )

        XCTAssertEqual(workspace.sidebarFlashToken, initialToken &+ 1)
        XCTAssertNil(workspace.persistentFlashPanels[panelId])
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

    func testPaneFlashDisabledGuardSilencesAllChannels() {
        UserDefaults.standard.set(false, forKey: NotificationPaneFlashSettings.enabledKey)
        defer { UserDefaults.standard.set(true, forKey: NotificationPaneFlashSettings.enabledKey) }

        let workspace = Workspace(title: "flash-test")
        let panelId = UUID()
        let initialToken = workspace.sidebarFlashToken

        workspace.triggerFocusFlash(
            panelId: panelId,
            appearance: FlashAppearance.current(envelope: .paneRing),
            persistent: true
        )

        XCTAssertEqual(workspace.sidebarFlashToken, initialToken)
        XCTAssertNil(workspace.persistentFlashPanels[panelId])
    }
}
