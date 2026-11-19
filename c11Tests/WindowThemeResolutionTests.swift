import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import c11

/// C11H-197: a window's theme override paints that window's chrome; every other
/// window keeps the app theme. An unknown name follows the app theme.
@MainActor
final class WindowThemeResolutionTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var userThemesDir: URL!

    private var bundledThemesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/c11-themes", isDirectory: true)
    }

    override func setUp() async throws {
        suiteName = "c11-window-theme-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        userThemesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: userThemesDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: userThemesDir)
    }

    private func makeManager() -> ThemeManager {
        ThemeManager(
            notificationCenter: NotificationCenter(),
            pathsOverride: .init(userThemesDirectory: userThemesDir, builtinDirectory: bundledThemesDir),
            selectionDefaults: defaults
        )
    }

    private func writeUserTheme(_ name: String, titleBarBackground: String) throws {
        let source = """
        [identity]
        name = "\(name)"
        display_name = "\(name)"
        author = "test"
        version = "0.01.001"
        schema = 1

        [palette]
        ink = "#101010"

        [variables]
        background = "$palette.ink"

        [chrome.titleBar]
        background = "\(titleBarBackground)"
        """
        try source.write(to: userThemesDir.appendingPathComponent("\(name).toml"), atomically: true, encoding: .utf8)
    }

    /// `#RRGGBBAA`, rounded, so equal colours compare equal.
    private func hex(_ color: NSColor?) -> String? {
        guard let color = color?.usingColorSpace(.sRGB) else { return nil }
        return "#" + [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            .map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }

    private func titleBarHex(_ manager: ThemeManager, window: String?) -> String? {
        let context = manager.makeContext(colorScheme: ThemeContext.ColorScheme.dark, windowThemeName: window)
        return hex(manager.resolve(.titleBar_background, context: context))
    }

    func testAWindowThemeResolvesTheOverrideThemesColours() throws {
        let manager = makeManager()
        XCTAssertEqual(manager.active.identity.name, "stage11")
        let bigboard = try XCTUnwrap(manager.theme(named: "bigboard"))
        let expected = hex(ResolvedThemeSnapshot(theme: bigboard).resolveColor(
            role: .titleBar_background,
            context: ThemeContext(colorScheme: .dark, ghosttyBackgroundGeneration: manager.ghosttyBackgroundGeneration)
        ))

        let app = titleBarHex(manager, window: nil)
        let overridden = titleBarHex(manager, window: "bigboard")
        XCTAssertNotNil(overridden)
        XCTAssertEqual(overridden, expected)
        XCTAssertNotEqual(overridden, app, "the window paints with its own theme")

        XCTAssertEqual(manager.effectiveThemeName(windowThemeName: "bigboard"), "bigboard")
        XCTAssertTrue(manager.themeOwnsChrome(windowThemeName: "bigboard"), "bigboard is schema 2")
        XCTAssertFalse(manager.themeOwnsChrome(windowThemeName: nil), "stage11 is schema 1")
        XCTAssertFalse(manager.textStyle(.windowTitle, windowThemeName: "bigboard").isUnset)
        XCTAssertTrue(manager.textStyle(.windowTitle).isUnset, "the app theme is untouched")
        XCTAssertEqual(manager.active.identity.name, "stage11")
    }

    func testNilUnknownMalformedAndActiveNamesFollowTheAppTheme() throws {
        try "this is [not toml".write(
            to: userThemesDir.appendingPathComponent("broken.toml"), atomically: true, encoding: .utf8
        )
        let manager = makeManager()
        let app = titleBarHex(manager, window: nil)
        for name in [nil, "", "no-such-theme", "broken", "stage11"] as [String?] {
            XCTAssertTrue(manager.snapshot(windowThemeName: name) === manager.snapshot, "\(name ?? "nil")")
            XCTAssertEqual(manager.effectiveThemeName(windowThemeName: name), "stage11")
            XCTAssertEqual(titleBarHex(manager, window: name), app)
        }

        XCTAssertTrue(manager.setActiveTheme(name: "bigboard"))
        XCTAssertTrue(manager.snapshot(windowThemeName: "bigboard") === manager.snapshot,
                      "an override naming the app theme shares its snapshot")
    }

    func testOverrideSnapshotsAreDroppedOnReload() throws {
        try writeUserTheme("winthm", titleBarBackground: "#112233")
        let manager = makeManager()
        XCTAssertEqual(titleBarHex(manager, window: "winthm")?.prefix(7), "#112233")

        try writeUserTheme("winthm", titleBarBackground: "#445566")
        manager.forceReloadUserThemes()
        XCTAssertEqual(titleBarHex(manager, window: "winthm")?.prefix(7), "#445566",
                       "a hot reload repaints a window that overrides with that theme")

        let before = manager.snapshot(windowThemeName: "winthm")
        manager.reloadFromBundle(named: "stage11")
        XCTAssertFalse(manager.snapshot(windowThemeName: "winthm") === before)

        let beforeColour = manager.snapshot(windowThemeName: "winthm")
        manager.invalidateForWorkspaceColorChange()
        XCTAssertFalse(manager.snapshot(windowThemeName: "winthm") === beforeColour)
    }

    func testSidebarStyleCacheKeepsTwoThemesApart() {
        let manager = makeManager()
        let bigboard = SidebarThemeStyleCache.current(manager, colorScheme: .dark, windowThemeName: "bigboard")
        let datasheet = SidebarThemeStyleCache.current(manager, colorScheme: .dark, windowThemeName: "datasheet-mono")
        let app = SidebarThemeStyleCache.current(manager, colorScheme: .dark, windowThemeName: nil)

        XCTAssertFalse(bigboard.fingerprint.isEmpty)
        XCTAssertFalse(datasheet.fingerprint.isEmpty)
        XCTAssertNotEqual(bigboard.fingerprint, datasheet.fingerprint)
        XCTAssertNotEqual(bigboard.stamp, datasheet.stamp)
        XCTAssertEqual(app.stamp, 0, "stage11 has no schema-2 sidebar values")

        // Two windows rendering in turn each get their own style back, unchanged.
        let bigboardAgain = SidebarThemeStyleCache.current(manager, colorScheme: .dark, windowThemeName: "bigboard")
        let datasheetAgain = SidebarThemeStyleCache.current(manager, colorScheme: .dark, windowThemeName: "datasheet-mono")
        XCTAssertEqual(bigboardAgain.fingerprint, bigboard.fingerprint)
        XCTAssertEqual(bigboardAgain.stamp, bigboard.stamp)
        XCTAssertEqual(datasheetAgain.fingerprint, datasheet.fingerprint)
        XCTAssertEqual(datasheetAgain.stamp, datasheet.stamp)
        XCTAssertEqual(SidebarThemeStyleCache.current(manager, colorScheme: .dark, windowThemeName: nil).stamp, 0)

        XCTAssertNotNil(SidebarThemeStyleCache.backdrop(manager, colorScheme: .dark, windowThemeName: "bigboard"))
        XCTAssertNil(SidebarThemeStyleCache.backdrop(manager, colorScheme: .dark, windowThemeName: nil))
    }
}
