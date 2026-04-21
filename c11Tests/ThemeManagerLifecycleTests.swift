import XCTest
import AppKit
import Combine
@testable import cmux

@MainActor
final class ThemeManagerLifecycleTests: XCTestCase {
    func testManagerLoadsActiveThemeAndIncrementsVersionOnReload() {
        let center = NotificationCenter()
        let manager = ThemeManager(notificationCenter: center)

        XCTAssertFalse(manager.active.identity.name.isEmpty)

        let initialVersion = manager.version
        manager.reloadFromBundle(named: "stage11")
        XCTAssertGreaterThan(manager.version, initialVersion)
    }

    func testGhosttyBackgroundNotificationBumpsGenerationAndVersion() {
        let center = NotificationCenter()
        let manager = ThemeManager(notificationCenter: center)

        let initialGeneration = manager.ghosttyBackgroundGeneration
        let initialVersion = manager.version

        center.post(name: .ghosttyDefaultBackgroundDidChange, object: nil)

        XCTAssertEqual(manager.ghosttyBackgroundGeneration, initialGeneration + 1)
        XCTAssertGreaterThan(manager.version, initialVersion)
    }

    // MARK: - CMUX-32 M2b/M2c

    func testInvalidateForWorkspaceColorChangeBumpsVersionAndFiresPublishers() {
        let center = NotificationCenter()
        let manager = ThemeManager(notificationCenter: center)
        let initialVersion = manager.version

        var dividerFired = 0
        var frameFired = 0
        var sidebarFired = 0
        var tabBarFired = 0
        let sinks: [AnyObject] = [
            manager.dividerPublisher.sink { dividerFired += 1 },
            manager.framePublisher.sink { frameFired += 1 },
            manager.sidebarPublisher.sink { sidebarFired += 1 },
            manager.tabBarPublisher.sink { tabBarFired += 1 },
        ]
        _ = sinks  // retain

        manager.invalidateForWorkspaceColorChange()

        XCTAssertGreaterThan(manager.version, initialVersion)
        XCTAssertEqual(dividerFired, 1)
        XCTAssertEqual(frameFired, 1)
        XCTAssertEqual(sidebarFired, 1)
        XCTAssertEqual(tabBarFired, 1)
    }

    func testDividerColorRoleResolvesAgainstWorkspaceColor() {
        let center = NotificationCenter()
        let manager = ThemeManager(notificationCenter: center)

        let context = manager.makeContext(
            workspaceColor: "#FF0000",
            colorScheme: .dark
        )
        let color: NSColor? = manager.resolve(.dividers_color, context: context)
        XCTAssertNotNil(color, "dividers_color should resolve against $workspaceColor.mix formula")

        let nilContext = manager.makeContext(
            workspaceColor: nil,
            colorScheme: .dark
        )
        let fallbackColor: NSColor? = manager.resolve(.dividers_color, context: nilContext)
        // Without a workspace color, $workspaceColor falls back to theme defaults; still returns a color.
        XCTAssertNotNil(fallbackColor)
    }

    func testDividerThicknessResolvesToNumber() {
        let center = NotificationCenter()
        let manager = ThemeManager(notificationCenter: center)

        let context = manager.makeContext(colorScheme: .light)
        let thickness: CGFloat? = manager.resolve(.dividers_thicknessPt, context: context)
        XCTAssertEqual(thickness, 1.0, accuracy: 0.0001)
    }
}
