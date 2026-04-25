import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Codable round-trip tests for `WorkspaceBlueprintFile` and
/// `WorkspaceBlueprintIndex`. No AppKit. Pure struct tests.
///
/// Per `CLAUDE.md`, never run locally — CI only.
final class WorkspaceBlueprintFileCodableTests: XCTestCase {

    // MARK: - Helpers

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        return try JSONDecoder().decode(type, from: data)
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try encode(value)
        let decoded = try decode(T.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    private func minimalPlan() -> WorkspaceApplyPlan {
        WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(title: "Blueprint Test"),
            layout: .pane(.init(surfaceIds: ["a"])),
            surfaces: [SurfaceSpec(id: "a", kind: .terminal)]
        )
    }

    // MARK: - WorkspaceBlueprintFile

    func testBlueprintFileRoundTripsSingleTerminalPlan() throws {
        let file = WorkspaceBlueprintFile(
            name: "Single Terminal",
            description: "One terminal pane",
            plan: minimalPlan()
        )
        try roundTrip(file)
    }

    func testBlueprintFileRoundTripsMultiSurfacePlan() throws {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(title: "Multi Surface"),
            layout: .split(
                .init(
                    orientation: .horizontal,
                    dividerPosition: 0.5,
                    first: .pane(.init(surfaceIds: ["term"])),
                    second: .split(
                        .init(
                            orientation: .vertical,
                            dividerPosition: 0.5,
                            first: .pane(.init(surfaceIds: ["browser"])),
                            second: .pane(.init(surfaceIds: ["md"]))
                        )
                    )
                )
            ),
            surfaces: [
                SurfaceSpec(id: "term", kind: .terminal, title: "shell", command: "bash"),
                SurfaceSpec(id: "browser", kind: .browser, title: "docs", url: "https://stage11.ai"),
                SurfaceSpec(id: "md", kind: .markdown, title: "notes", filePath: "/tmp/notes.md")
            ]
        )
        let file = WorkspaceBlueprintFile(
            name: "Multi Surface Layout",
            description: "Terminal, browser, and markdown",
            plan: plan
        )
        try roundTrip(file)
    }

    func testBlueprintFileMissingDescriptionDecodesAsNil() throws {
        let json = Data("""
        {
            "version": 1,
            "name": "No Description",
            "plan": {
                "version": 1,
                "workspace": {},
                "layout": {"type": "pane", "pane": {"surfaceIds": ["a"]}},
                "surfaces": [{"id": "a", "kind": "terminal"}]
            }
        }
        """.utf8)
        let decoded = try decode(WorkspaceBlueprintFile.self, from: json)
        XCTAssertNil(decoded.description)
        XCTAssertEqual(decoded.name, "No Description")
    }

    func testBlueprintFileVersionDefaultsToOne() throws {
        let file = WorkspaceBlueprintFile(name: "Version Default", plan: minimalPlan())
        XCTAssertEqual(file.version, 1)
        let data = try encode(file)
        let decoded = try decode(WorkspaceBlueprintFile.self, from: data)
        XCTAssertEqual(decoded.version, 1)
    }

    // MARK: - WorkspaceBlueprintIndex

    func testBlueprintIndexRoundTripsRepoSource() throws {
        let index = WorkspaceBlueprintIndex(
            name: "Repo Blueprint",
            description: "Committed alongside the project",
            url: "/Users/op/repo/.cmux/blueprints/dev.json",
            source: .repo,
            modifiedAt: Date(timeIntervalSince1970: 1_745_000_000)
        )
        try roundTrip(index)
    }

    func testBlueprintIndexRoundTripsUserSource() throws {
        let index = WorkspaceBlueprintIndex(
            name: "User Blueprint",
            description: nil,
            url: "/Users/op/.config/cmux/blueprints/scratch.json",
            source: .user,
            modifiedAt: Date(timeIntervalSince1970: 1_745_001_000)
        )
        try roundTrip(index)
    }

    func testBlueprintIndexRoundTripsBuiltInSource() throws {
        let index = WorkspaceBlueprintIndex(
            name: "Welcome Quad",
            description: "Four-pane welcome layout",
            url: "/Applications/c11.app/Contents/Resources/Blueprints/welcome-quad.json",
            source: .builtIn,
            modifiedAt: Date(timeIntervalSince1970: 1_740_000_000)
        )
        try roundTrip(index)
    }

    func testBlueprintIndexSourceUsesWireNames() throws {
        let index = WorkspaceBlueprintIndex(
            name: "Wire Names",
            description: nil,
            url: "/tmp/wire.json",
            source: .builtIn,
            modifiedAt: Date(timeIntervalSince1970: 1_745_000_000)
        )
        let data = try encode(index)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"built-in\""), "builtIn source serializes as 'built-in'")
        XCTAssertTrue(json.contains("\"modified_at\""), "modifiedAt uses snake_case on the wire")
    }
}
