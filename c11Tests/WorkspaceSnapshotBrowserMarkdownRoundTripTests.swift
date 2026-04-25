import XCTest
import Bonsplit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Round-trip coverage for CMUX-37 browser and markdown surface kinds.
///
/// Each test applies a plan containing browser and/or markdown surfaces,
/// captures the live workspace via `LiveWorkspaceSnapshotSource`, and asserts
/// that surface kinds, metadata, and the markdown filePath survive the cycle.
///
/// Browser `currentURL` is NOT round-tripped because `BrowserPanel.currentURL`
/// is set by WKNavigationDelegate callbacks — not at creation time — and those
/// never fire in the headless test harness. The test verifies the correct
/// surface kind and nil-URL behaviour instead.
///
/// CI-only per `CLAUDE.md` testing policy. Never run locally.
@MainActor
final class WorkspaceSnapshotBrowserMarkdownRoundTripTests: XCTestCase {

    private var tabManager: TabManager!

    override func setUp() {
        super.setUp()
        tabManager = TabManager()
    }

    override func tearDown() {
        tabManager = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// Apply a plan with one terminal + one browser, capture, check kinds.
    func testBrowserSurfaceKindRoundTrips() throws {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(),
            layout: .split(LayoutTreeSpec.SplitSpec(
                orientation: .horizontal,
                dividerPosition: 0.5,
                first: .pane(LayoutTreeSpec.PaneSpec(surfaceIds: ["s1"])),
                second: .pane(LayoutTreeSpec.PaneSpec(surfaceIds: ["s2"]))
            )),
            surfaces: [
                SurfaceSpec(id: "s1", kind: .terminal),
                SurfaceSpec(id: "s2", kind: .browser, url: "https://example.com")
            ]
        )

        let deps = makeDependencies()
        let result = WorkspaceLayoutExecutor.apply(
            plan, options: ApplyOptions(select: false), dependencies: deps
        )
        XCTAssertFalse(result.workspaceRef.isEmpty, "workspaceRef populated")
        XCTAssertTrue(
            result.failures.isEmpty,
            "no apply failures: \(result.failures)"
        )

        let workspace = try XCTUnwrap(
            resolveWorkspace(from: result.workspaceRef),
            "workspaceRef resolves to live Workspace"
        )
        let source = LiveWorkspaceSnapshotSource(
            tabManager: tabManager, c11Version: "test+0"
        )
        let captured = try XCTUnwrap(
            source.capture(workspaceId: workspace.id, origin: .manual),
            "LiveWorkspaceSnapshotSource returns an envelope"
        )

        let kinds = captured.plan.surfaces.map { $0.kind }
        XCTAssertTrue(kinds.contains(.browser), "captured plan contains a browser surface; got: \(kinds)")
        XCTAssertTrue(kinds.contains(.terminal), "captured plan contains a terminal surface; got: \(kinds)")
        XCTAssertEqual(captured.plan.surfaces.count, 2)

        // currentURL is nil without WebKit — the walker correctly captures nil.
        let browserSpec = try XCTUnwrap(captured.plan.surfaces.first { $0.kind == .browser })
        XCTAssertNil(
            browserSpec.url,
            "browser url is nil in headless test (no WKNavigationDelegate callbacks)"
        )
    }

    /// Apply a plan with one markdown surface, capture, check filePath round-trips.
    func testMarkdownFilePathRoundTrips() throws {
        let fixturePath = "/tmp/c11-test-fixture.md"
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(),
            layout: .pane(LayoutTreeSpec.PaneSpec(surfaceIds: ["s1"])),
            surfaces: [
                SurfaceSpec(id: "s1", kind: .markdown, filePath: fixturePath)
            ]
        )

        let deps = makeDependencies()
        let result = WorkspaceLayoutExecutor.apply(
            plan, options: ApplyOptions(select: false), dependencies: deps
        )
        XCTAssertTrue(
            result.failures.isEmpty,
            "no apply failures: \(result.failures)"
        )

        let workspace = try XCTUnwrap(resolveWorkspace(from: result.workspaceRef))
        let source = LiveWorkspaceSnapshotSource(
            tabManager: tabManager, c11Version: "test+0"
        )
        let captured = try XCTUnwrap(source.capture(workspaceId: workspace.id, origin: .manual))

        XCTAssertEqual(captured.plan.surfaces.count, 1)
        let spec = try XCTUnwrap(captured.plan.surfaces.first)
        XCTAssertEqual(spec.kind, .markdown, "surface kind round-trips as markdown")
        XCTAssertEqual(spec.filePath, fixturePath, "markdown filePath round-trips through capture")
        XCTAssertNil(spec.url, "markdown surface has no url")
    }

    /// Apply a three-surface plan (terminal + browser + markdown), verify all
    /// kinds survive capture and no surface is dropped.
    func testMixedThreeSurfacePlanRoundTrips() throws {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(title: "mixed"),
            layout: .split(LayoutTreeSpec.SplitSpec(
                orientation: .horizontal,
                dividerPosition: 0.6,
                first: .pane(LayoutTreeSpec.PaneSpec(surfaceIds: ["s1"])),
                second: .split(LayoutTreeSpec.SplitSpec(
                    orientation: .vertical,
                    dividerPosition: 0.5,
                    first: .pane(LayoutTreeSpec.PaneSpec(surfaceIds: ["s2"])),
                    second: .pane(LayoutTreeSpec.PaneSpec(surfaceIds: ["s3"]))
                ))
            )),
            surfaces: [
                SurfaceSpec(id: "s1", kind: .terminal),
                SurfaceSpec(id: "s2", kind: .browser, url: "https://docs.example.com"),
                SurfaceSpec(id: "s3", kind: .markdown, filePath: "/tmp/notes.md")
            ]
        )

        let deps = makeDependencies()
        let result = WorkspaceLayoutExecutor.apply(
            plan, options: ApplyOptions(select: false), dependencies: deps
        )
        XCTAssertTrue(result.failures.isEmpty, "no apply failures: \(result.failures)")

        let workspace = try XCTUnwrap(resolveWorkspace(from: result.workspaceRef))
        let source = LiveWorkspaceSnapshotSource(
            tabManager: tabManager, c11Version: "test+0"
        )
        let captured = try XCTUnwrap(source.capture(workspaceId: workspace.id, origin: .manual))

        XCTAssertEqual(captured.plan.surfaces.count, 3, "all three surfaces captured")
        let capturedKinds = Set(captured.plan.surfaces.map { $0.kind })
        XCTAssertEqual(capturedKinds, [.terminal, .browser, .markdown])

        let md = try XCTUnwrap(captured.plan.surfaces.first { $0.kind == .markdown })
        XCTAssertEqual(md.filePath, "/tmp/notes.md", "markdown filePath in mixed plan round-trips")
    }

    /// Blueprint exporter produces the correct surface kinds for browser/markdown.
    func testBlueprintExporterBrowserMarkdownKinds() throws {
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: WorkspaceSpec(),
            layout: .split(LayoutTreeSpec.SplitSpec(
                orientation: .horizontal,
                dividerPosition: 0.5,
                first: .pane(LayoutTreeSpec.PaneSpec(surfaceIds: ["s1"])),
                second: .pane(LayoutTreeSpec.PaneSpec(surfaceIds: ["s2"]))
            )),
            surfaces: [
                SurfaceSpec(id: "s1", kind: .browser),
                SurfaceSpec(id: "s2", kind: .markdown)
            ]
        )

        let deps = makeDependencies()
        let result = WorkspaceLayoutExecutor.apply(
            plan, options: ApplyOptions(select: false), dependencies: deps
        )
        XCTAssertTrue(result.failures.isEmpty, "no apply failures: \(result.failures)")

        let workspace = try XCTUnwrap(resolveWorkspace(from: result.workspaceRef))
        let exporter = WorkspaceBlueprintExporter(tabManager: tabManager)
        let file = try XCTUnwrap(
            exporter.export(workspaceId: workspace.id, name: "test-bp", description: "desc"),
            "exporter returns a file for the live workspace"
        )

        XCTAssertEqual(file.name, "test-bp")
        XCTAssertEqual(file.description, "desc")
        XCTAssertEqual(file.plan.surfaces.count, 2)
        let kinds = Set(file.plan.surfaces.map { $0.kind })
        XCTAssertEqual(kinds, [.browser, .markdown])
    }

    // MARK: - Helpers

    private func makeDependencies() -> WorkspaceLayoutExecutorDependencies {
        WorkspaceLayoutExecutorDependencies(
            tabManager: tabManager,
            workspaceRefMinter: { "workspace:\($0.uuidString)" },
            surfaceRefMinter: { "surface:\($0.uuidString)" },
            paneRefMinter: { "pane:\($0.uuidString)" }
        )
    }

    private func resolveWorkspace(from ref: String) -> Workspace? {
        guard let uuidString = ref.split(separator: ":").last,
              let uuid = UUID(uuidString: String(uuidString)) else { return nil }
        return tabManager.tabs.first { $0.id == uuid }
    }
}
