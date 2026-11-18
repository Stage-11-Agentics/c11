import XCTest
import AppKit
import Combine
import SwiftUI
@testable import c11

@MainActor
final class ThemeManagerLifecycleTests: XCTestCase {
    func testBundledThemesLoadFromC11ThemesDirectory() {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundledThemesDirectory = repoRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(ThemeManager.bundledThemesDirectoryName, isDirectory: true)
        let userThemesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-theme-test-\(UUID().uuidString)", isDirectory: true)

        let manager = ThemeManager(
            notificationCenter: NotificationCenter(),
            pathsOverride: .init(
                userThemesDirectory: userThemesDirectory,
                builtinDirectory: bundledThemesDirectory
            )
        )

        let names = Set(manager.availableThemes.map(\.identity.name))
        XCTAssertEqual(names, ["stage11", "c11", "nocturne", "bigboard", "datasheet-mono", "terminal-grid", "outrun-horizon"])
    }

    func testDefaultThemeUserDirectoryUsesC11ApplicationSupportName() {
        let userThemesDirectory = ThemeManager.userThemesDirectory()

        XCTAssertEqual(userThemesDirectory.lastPathComponent, "themes")
        XCTAssertEqual(userThemesDirectory.deletingLastPathComponent().lastPathComponent, C11Identity.stateDirectoryName)
    }

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
            colorScheme: ThemeContext.ColorScheme.dark
        )
        let color: NSColor? = manager.resolve(.dividers_color, context: context)
        XCTAssertNotNil(color, "dividers_color should resolve against $workspaceColor.mix formula")

        let nilContext = manager.makeContext(
            workspaceColor: nil,
            colorScheme: ThemeContext.ColorScheme.dark
        )
        let fallbackColor: NSColor? = manager.resolve(.dividers_color, context: nilContext)
        // Without a workspace color, $workspaceColor falls back to theme defaults; still returns a color.
        XCTAssertNotNil(fallbackColor)
    }

    func testDividerThicknessResolvesToNumber() throws {
        let center = NotificationCenter()
        let manager = ThemeManager(notificationCenter: center)

        let context = manager.makeContext(colorScheme: ThemeContext.ColorScheme.light)
        let thickness = try XCTUnwrap(manager.resolve(.dividers_thicknessPt, context: context) as CGFloat?)
        XCTAssertEqual(Double(thickness), 1.0, accuracy: 0.0001)
    }
}

/// C11H-187: Settings draws every bundled theme as a live preview. The render is saved as a
/// PNG (path printed as C11_GALLERY_PNG=) so a reviewer can see the real page.
@MainActor
final class ThemeGalleryRenderTests: XCTestCase {
    func testTheGalleryDrawsEveryBundledThemeAsAPreview() throws {
        let width: CGFloat = 720
        let host = NSHostingView(rootView: ThemePreviewGallery().frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 1400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1400)
        host.layoutSubtreeIfNeeded()
        host.frame.size.height = max(host.fittingSize.height, 300)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c11-theme-gallery.png")
        try png.write(to: url)
        print("C11_GALLERY_PNG=\(url.path)")

        XCTAssertEqual(ThemeManager.shared.availableThemes.filter { $0.source == .builtin }.count, 7)
        // Seven differently coloured previews leave many distinct colours; a blank or
        // single-theme page leaves few.
        var colours = Set<UInt32>()
        let step = 6
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colours.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31))
            }
        }
        XCTAssertGreaterThan(colours.count, 40, "the gallery drew too few colours to hold seven previews")
    }
}
