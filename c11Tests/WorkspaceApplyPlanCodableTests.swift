import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Codable round-trip tests for the `WorkspaceApplyPlan` value types.
/// Phase 1 Snapshot capture and Phase 2 Blueprint parsing both serialize
/// through this schema; these tests lock the wire shape so either can land
/// without a compat layer.
final class WorkspaceApplyPlanCodableTests: XCTestCase {

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

    // MARK: - WorkspaceSpec

    func testWorkspaceSpecRoundTripsFullyPopulated() throws {
        let spec = WorkspaceSpec(
            title: "Debug Auth",
            customColor: "#C0392B",
            workingDirectory: "/Users/op/repo",
            metadata: ["description": "auth module work", "icon": "shield"]
        )
        try roundTrip(spec)
    }

    func testWorkspaceSpecRoundTripsEmpty() throws {
        try roundTrip(WorkspaceSpec())
    }

    // MARK: - SurfaceSpec

    func testSurfaceSpecTerminalRoundTrips() throws {
        let spec = SurfaceSpec(
            id: "main",
            kind: .terminal,
            title: "driver",
            description: "cc on auth",
            workingDirectory: "/Users/op/repo",
            command: "cc --resume abc123",
            metadata: [
                "role": .string("driver"),
                "status": .string("ready"),
                "model": .string("claude-opus-4-7")
            ],
            paneMetadata: [
                "mailbox.delivery": .string("stdin,watch"),
                "mailbox.subscribe": .string("build.*,deploy.green"),
                "mailbox.retention_days": .string("7")
            ]
        )
        try roundTrip(spec)
    }

    func testSurfaceSpecBrowserRoundTrips() throws {
        let spec = SurfaceSpec(
            id: "docs",
            kind: .browser,
            title: "docs",
            url: "https://stage11.ai"
        )
        try roundTrip(spec)
    }

    func testSurfaceSpecMarkdownRoundTrips() throws {
        let spec = SurfaceSpec(
            id: "notes",
            kind: .markdown,
            title: "plan",
            filePath: "/Users/op/notes/plan.md"
        )
        try roundTrip(spec)
    }

    func testSurfaceSpecPreservesMailboxStarKeysVerbatim() throws {
        // Per docs/c11-13-cmux-37-alignment.md: the mailbox.* namespace
        // round-trips without normalization. The string-value type guard
        // lives in the executor, not the Codable layer, so a non-string value
        // must still decode cleanly on the wire.
        let spec = SurfaceSpec(
            id: "watcher",
            kind: .terminal,
            paneMetadata: [
                "mailbox.delivery": .string("silent"),
                "mailbox.advertises": .array([.string("build.*"), .string("deploy.*")]),
                "mailbox.retention_days": .number(14)
            ]
        )
        let data = try encode(spec)
        let decoded = try decode(SurfaceSpec.self, from: data)
        XCTAssertEqual(decoded.paneMetadata?["mailbox.delivery"], .string("silent"))
        XCTAssertEqual(
            decoded.paneMetadata?["mailbox.advertises"],
            .array([.string("build.*"), .string("deploy.*")])
        )
        XCTAssertEqual(decoded.paneMetadata?["mailbox.retention_days"], .number(14))
    }

    // MARK: - LayoutTreeSpec

    func testLayoutTreeSpecSinglePaneRoundTrips() throws {
        let tree = LayoutTreeSpec.pane(
            .init(surfaceIds: ["main"], selectedIndex: 0)
        )
        try roundTrip(tree)
    }

    func testLayoutTreeSpecNestedSplitRoundTrips() throws {
        let tree = LayoutTreeSpec.split(
            .init(
                orientation: .horizontal,
                dividerPosition: 0.5,
                first: .pane(.init(surfaceIds: ["tl"])),
                second: .split(
                    .init(
                        orientation: .vertical,
                        dividerPosition: 0.5,
                        first: .pane(.init(surfaceIds: ["tr"])),
                        second: .pane(.init(surfaceIds: ["br"], selectedIndex: 0))
                    )
                )
            )
        )
        try roundTrip(tree)
    }

    func testLayoutTreeSpecDiscriminatorIsTypeKey() throws {
        let tree = LayoutTreeSpec.pane(.init(surfaceIds: ["s"]))
        let data = try encode(tree)
        let string = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(string.contains("\"type\":\"pane\""))
    }

    func testLayoutTreeSpecRejectsUnknownType() throws {
        let bogus = Data("""
        {"type":"triple-pane","extra":{}}
        """.utf8)
        XCTAssertThrowsError(try decode(LayoutTreeSpec.self, from: bogus)) { error in
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("expected .dataCorrupted, got \(error)")
                return
            }
        }
    }

    // MARK: - Full plan

    func testWorkspaceApplyPlanRoundTripsMixedLayout() throws {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(
                title: "Welcome Quad",
                workingDirectory: "/Users/op"
            ),
            layout: .split(
                .init(
                    orientation: .horizontal,
                    dividerPosition: 0.5,
                    first: .split(
                        .init(
                            orientation: .vertical,
                            dividerPosition: 0.5,
                            first: .pane(.init(surfaceIds: ["tl"])),
                            second: .pane(.init(surfaceIds: ["bl"]))
                        )
                    ),
                    second: .split(
                        .init(
                            orientation: .vertical,
                            dividerPosition: 0.5,
                            first: .pane(.init(surfaceIds: ["tr"])),
                            second: .pane(.init(surfaceIds: ["br"]))
                        )
                    )
                )
            ),
            surfaces: [
                SurfaceSpec(id: "tl", kind: .terminal, title: "driver", command: "c11 welcome\n"),
                SurfaceSpec(id: "tr", kind: .browser, title: "spike", url: "https://stage11.ai"),
                SurfaceSpec(id: "bl", kind: .markdown, title: "welcome", filePath: "/tmp/welcome.md"),
                SurfaceSpec(id: "br", kind: .terminal, title: "claude", command: "claude\n")
            ]
        )
        try roundTrip(plan)
    }

    // MARK: - ApplyOptions / ApplyResult

    func testApplyOptionsDefaultsRoundTrip() throws {
        try roundTrip(ApplyOptions())
        try roundTrip(ApplyOptions(select: false, perStepTimeoutMs: 0, autoWelcomeIfNeeded: true))
    }

    func testApplyResultRoundTripsWithWarningsAndFailures() throws {
        let result = ApplyResult(
            workspaceRef: "workspace:1",
            surfaceRefs: ["main": "surface:1", "logs": "surface:2"],
            paneRefs: ["main": "pane:1", "logs": "pane:2"],
            timings: [
                StepTiming(step: "validate", durationMs: 0.3),
                StepTiming(step: "workspace.create", durationMs: 12.1),
                StepTiming(step: "total", durationMs: 180.5)
            ],
            warnings: ["mailbox.retention_days dropped: non-string value"],
            failures: [
                ApplyFailure(
                    code: "mailbox_non_string_value",
                    step: "metadata.pane[main].write",
                    message: "mailbox.retention_days must be a string in v1"
                )
            ]
        )
        try roundTrip(result)
    }
}
