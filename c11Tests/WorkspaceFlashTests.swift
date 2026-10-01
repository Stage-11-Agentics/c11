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

    func testOneShotFlashFansOutToSidebarTokenWithoutRegisteringPersistentState() {
        let workspace = Workspace(title: "flash-test")
        let panelId = UUID()
        let initialToken = workspace.sidebarFlashToken

        workspace.triggerFocusFlash(
            panelId: panelId,
            appearance: FlashAppearance.current(envelope: .paneRing)
        )

        XCTAssertEqual(workspace.sidebarFlashToken, initialToken &+ 1)
        XCTAssertNil(workspace.persistentFlashTabs[panelId])
    }

    func testPersistentFlashRegistersStateAndKeepsRegistrationUntilCancel() {
        let workspace = Workspace(title: "flash-test")
        let panelId = UUID()

        workspace.triggerFocusFlash(
            panelId: panelId,
            appearance: FlashAppearance.current(envelope: .paneRing),
            persistent: true
        )

        let registered = workspace.persistentFlashTabs[panelId]
        XCTAssertNotNil(registered, "Persistent flash should register state on the workspace")

        workspace.cancelPersistentFlash(panelId: panelId)
        XCTAssertNil(workspace.persistentFlashTabs[panelId])
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
        XCTAssertEqual(workspace.persistentFlashTabs.count, 2)

        workspace.cancelAllPersistentFlashes()
        XCTAssertTrue(workspace.persistentFlashTabs.isEmpty)
    }

    func testCancelOnUnregisteredTabIsIdempotent() {
        let workspace = Workspace(title: "flash-test")
        let panelId = UUID()
        // No prior persistent flash; cancel should not crash or alter state.
        workspace.cancelPersistentFlash(panelId: panelId)
        XCTAssertTrue(workspace.persistentFlashTabs.isEmpty)
    }

    func testRetriggerPersistentReplacesExistingTimerWithoutLeaking() {
        let workspace = Workspace(title: "flash-test")
        let panelId = UUID()

        workspace.triggerFocusFlash(
            panelId: panelId,
            appearance: FlashAppearance.current(envelope: .paneRing),
            persistent: true
        )
        let firstTimer = workspace.persistentFlashTabs[panelId]?.timer

        workspace.triggerFocusFlash(
            panelId: panelId,
            appearance: FlashAppearance(color: .blue, envelope: .paneRing),
            persistent: true
        )
        let secondTimer = workspace.persistentFlashTabs[panelId]?.timer

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

    func testTeardownAllTabsCancelsEveryPersistentFlash() {
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
        let timerA = workspace.persistentFlashTabs[panelA]?.timer
        let timerB = workspace.persistentFlashTabs[panelB]?.timer
        XCTAssertEqual(workspace.persistentFlashTabs.count, 2)

        workspace.teardownAllPanels()

        XCTAssertTrue(workspace.persistentFlashTabs.isEmpty)
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
            capturedTimer = workspace.persistentFlashTabs[panelId]?.timer
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
        let initialToken = workspace.sidebarFlashToken

        workspace.triggerFocusFlash(
            panelId: panelId,
            appearance: FlashAppearance.current(envelope: .paneRing),
            persistent: true
        )

        XCTAssertEqual(workspace.sidebarFlashToken, initialToken)
        XCTAssertNil(workspace.persistentFlashTabs[panelId])
    }
}
