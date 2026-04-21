import XCTest
@testable import cmux

final class TomlSubsetParserTests: XCTestCase {
    func testParsesScalarsAndComments() throws {
        let source = """
        # comment before table
        [identity]
        name = "stage11"
        schema = 1
        enabled = true
        opacity = 0.85
        quoted = "#FF0000"
        """

        let root = try TomlSubsetParser.parse(file: "identity.toml", source: source)

        XCTAssertEqual(stringValue(in: root, path: ["identity", "name"]), "stage11")
        XCTAssertEqual(intValue(in: root, path: ["identity", "schema"]), 1)
        XCTAssertEqual(boolValue(in: root, path: ["identity", "enabled"]), true)
        XCTAssertEqual(doubleValue(in: root, path: ["identity", "opacity"]), 0.85, accuracy: 0.0001)
        XCTAssertEqual(stringValue(in: root, path: ["identity", "quoted"]), "#FF0000")
    }

    func testParsesNestedTables() throws {
        let source = """
        [chrome]
       
        [chrome.titleBar]
        background = "#121519"

        [chrome.titleBar.deep.one.two.three]
        marker = "ok"
        """

        let root = try TomlSubsetParser.parse(file: "nested.toml", source: source)
        XCTAssertEqual(stringValue(in: root, path: ["chrome", "titleBar", "background"]), "#121519")
        XCTAssertEqual(
            stringValue(in: root, path: ["chrome", "titleBar", "deep", "one", "two", "three", "marker"]),
            "ok"
        )
    }

    func testParsesInlineTable() throws {
        let source = """
        [chrome.sidebar]
        tintOverlay = { enabled = false }
        """

        let root = try TomlSubsetParser.parse(file: "inline.toml", source: source)
        let inline = tableValue(in: root, path: ["chrome", "sidebar", "tintOverlay"])
        XCTAssertEqual(boolValue(in: inline ?? [:], path: ["enabled"]), false)
    }

    func testParsesStringEscapes() throws {
        let source = """
        [strings]
        value = "line1\\nline2\\t\\"quoted\\" \\ \\u2603"
        """

        let root = try TomlSubsetParser.parse(file: "escapes.toml", source: source)
        XCTAssertEqual(stringValue(in: root, path: ["strings", "value"]), "line1\nline2\t\"quoted\" \\ ☃")
    }

    func testParsesBundledStage11ThemeWhenPresent() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stage11URL = repoRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("c11mux-themes")
            .appendingPathComponent("stage11.toml")

        guard FileManager.default.fileExists(atPath: stage11URL.path) else {
            throw XCTSkip("stage11.toml not present until Phase 4")
        }

        let source = try String(contentsOf: stage11URL, encoding: .utf8)
        let root = try TomlSubsetParser.parse(file: stage11URL.path, source: source)
        XCTAssertFalse(root.isEmpty)
        XCTAssertEqual(stringValue(in: root, path: ["identity", "name"]), "stage11")
    }

    private func value(in table: TomlTable, path: [String]) -> TomlValue? {
        guard !path.isEmpty else { return nil }

        var currentTable = table
        for key in path.dropLast() {
            guard case let .table(next)? = currentTable[key] else {
                return nil
            }
            currentTable = next
        }

        return currentTable[path.last ?? ""]
    }

    private func tableValue(in table: TomlTable, path: [String]) -> TomlTable? {
        guard case let .table(value)? = self.value(in: table, path: path) else {
            return nil
        }
        return value
    }

    private func stringValue(in table: TomlTable, path: [String]) -> String? {
        guard case let .string(value)? = self.value(in: table, path: path) else {
            return nil
        }
        return value
    }

    private func intValue(in table: TomlTable, path: [String]) -> Int64? {
        guard case let .integer(value)? = self.value(in: table, path: path) else {
            return nil
        }
        return value
    }

    private func doubleValue(in table: TomlTable, path: [String]) -> Double? {
        guard case let .double(value)? = self.value(in: table, path: path) else {
            return nil
        }
        return value
    }

    private func boolValue(in table: TomlTable, path: [String]) -> Bool? {
        guard case let .boolean(value)? = self.value(in: table, path: path) else {
            return nil
        }
        return value
    }
}
