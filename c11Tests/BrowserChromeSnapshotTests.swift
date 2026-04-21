import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserChromeSnapshotTests: XCTestCase {
    private struct BrowserChromeFixture: Codable {
        let colorScheme: String
        let systemAppearance: String
        let expectedBackgroundHex: String
        let expectedOmnibarHex: String
    }

    func testBrowserChromeM1bSnapshotsMatchFixtures() throws {
        let fixtures = try loadFixtures(directoryName: "browserChrome-m1b")
        XCTAssertEqual(fixtures.count, 6)

        var deterministicTheme = C11muxTheme.fallbackStage11
        deterministicTheme.chrome.browserChrome.background = "$surface"
        deterministicTheme.chrome.browserChrome.omnibarFill = "$surface"

        let snapshot = ResolvedThemeSnapshot(theme: deterministicTheme)

        for (url, fixture) in fixtures {
            let context = ThemeContext(
                workspaceColor: nil,
                colorScheme: fixture.colorScheme == "dark" ? .dark : .light,
                forceBright: false,
                ghosttyBackgroundGeneration: 0
            )

            let background = try XCTUnwrap(snapshot.resolveColor(role: .browserChrome_background, context: context))
            let omnibar = try XCTUnwrap(snapshot.resolveColor(role: .browserChrome_omnibarFill, context: context))

            XCTAssertEqual(background.hexString(includeAlpha: true), fixture.expectedBackgroundHex, "Background mismatch for \(url.lastPathComponent)")
            XCTAssertEqual(omnibar.hexString(includeAlpha: true), fixture.expectedOmnibarHex, "Omnibar mismatch for \(url.lastPathComponent)")
        }
    }

    private func loadFixtures(directoryName: String) throws -> [(URL, BrowserChromeFixture)] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Snapshots")
            .appendingPathComponent(directoryName)

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = JSONDecoder()
        return try urls.map { url in
            let data = try Data(contentsOf: url)
            return (url, try decoder.decode(BrowserChromeFixture.self, from: data))
        }
    }
}
