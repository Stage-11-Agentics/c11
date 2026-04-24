import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class TitlebarSnapshotTests: XCTestCase {
    private struct TitlebarFixture: Codable {
        let colorScheme: String
        let workspaceColor: String?
        let expectedBackgroundHex: String
        let expectedBorderHex: String
        let expectedBackgroundOpacity: Double
    }

    func testTitlebarM1bSnapshotsMatchFixtures() throws {
        let fixtures = try loadFixtures(directoryName: "titlebar-m1b")
        XCTAssertEqual(fixtures.count, 4)

        let snapshot = ResolvedThemeSnapshot(theme: .fallbackStage11)

        for (url, fixture) in fixtures {
            let context = ThemeContext(
                workspaceColor: fixture.workspaceColor,
                colorScheme: fixture.colorScheme == "dark" ? .dark : .light,
                forceBright: false,
                ghosttyBackgroundGeneration: 0
            )

            let background = try XCTUnwrap(snapshot.resolveColor(role: .titleBar_background, context: context))
            let border = try XCTUnwrap(snapshot.resolveColor(role: .titleBar_borderBottom, context: context))
            let opacity = try XCTUnwrap(snapshot.resolveNumber(role: .titleBar_backgroundOpacity, context: context))

            XCTAssertEqual(background.hexString(includeAlpha: true), fixture.expectedBackgroundHex, "Background mismatch for \(url.lastPathComponent)")
            XCTAssertEqual(border.hexString(includeAlpha: true), fixture.expectedBorderHex, "Border mismatch for \(url.lastPathComponent)")
            XCTAssertEqual(opacity, fixture.expectedBackgroundOpacity, accuracy: 0.0001, "Opacity mismatch for \(url.lastPathComponent)")
        }
    }

    private func loadFixtures(directoryName: String) throws -> [(URL, TitlebarFixture)] {
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
            return (url, try decoder.decode(TitlebarFixture.self, from: data))
        }
    }
}
