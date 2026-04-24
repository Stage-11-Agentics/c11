import XCTest
@testable import c11

final class TomlSubsetParserFuzzTests: XCTestCase {
    func testFuzzCorpus() throws {
        let fixturesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("toml-fuzz", isDirectory: true)

        let files = try FileManager.default.contentsOfDirectory(
            at: fixturesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "toml" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(files.isEmpty, "fuzz corpus should contain fixtures")

        for fileURL in files {
            let name = fileURL.lastPathComponent
            let source = try String(contentsOf: fileURL, encoding: .utf8)

            if name.hasPrefix("parse_ok.") {
                XCTAssertNoThrow(
                    try TomlSubsetParser.parse(file: name, source: source),
                    "expected parser success for \(name)"
                )
                continue
            }

            guard name.hasPrefix("parse_err.") else {
                XCTFail("unexpected corpus fixture name: \(name)")
                continue
            }

            let expectedKind = expectedErrorKind(for: name)
            do {
                _ = try TomlSubsetParser.parse(file: name, source: source)
                XCTFail("expected parser failure for \(name)")
            } catch let error as TomlParseError {
                if let expectedKind {
                    XCTAssertEqual(error.kind, expectedKind, "unexpected error kind for \(name): \(error)")
                }
            } catch {
                XCTFail("unexpected error type for \(name): \(error)")
            }
        }
    }

    private func expectedErrorKind(for fixtureName: String) -> TomlParseErrorKind? {
        switch fixtureName {
        case "parse_err.unquoted_hex.toml":
            return .syntax
        case "parse_err.duplicate_key.toml":
            return .duplicateKey
        case "parse_err.missing_equals.toml":
            return .syntax
        case "parse_err.unterminated_string.toml":
            return .unterminatedString
        case "parse_err.array_value.toml":
            return .unsupportedFeature
        case "parse_err.multiline_string.toml":
            return .unsupportedFeature
        case "parse_err.trailing_comma.toml":
            return .unsupportedFeature
        default:
            return nil
        }
    }
}
