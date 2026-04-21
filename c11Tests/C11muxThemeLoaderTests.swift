import Foundation
import XCTest
@testable import cmux

final class C11muxThemeLoaderTests: XCTestCase {
    func testStage11TomlRoundTripsAgainstGoldenSnapshot() throws {
        let stage11URL = try stage11ThemeURL()
        let source = try String(contentsOf: stage11URL, encoding: .utf8)

        let table = try TomlSubsetParser.parse(file: stage11URL.path, source: source)
        let theme = try C11muxTheme.fromToml(table)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let actualJSON = try encoder.encode(theme)

        let goldenURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("golden")
            .appendingPathComponent("stage11-snapshot.json")

        let expectedJSON = try Data(contentsOf: goldenURL)
        let expectedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: expectedJSON) as? NSDictionary)
        let actualObject = try XCTUnwrap(JSONSerialization.jsonObject(with: actualJSON) as? NSDictionary)
        XCTAssertEqual(actualObject, expectedObject)

        XCTAssertEqual(theme.identity.name, "stage11")
        XCTAssertEqual(theme.identity.schema, 1)
    }

    private func stage11ThemeURL() throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("c11-themes")
            .appendingPathComponent("stage11.toml")

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("stage11.toml is not present")
        }

        return url
    }
}
