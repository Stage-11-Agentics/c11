import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Round-trip tests for the Markdown blueprint format introduced by
/// CMUX-37 workstream 1. Pure value-level tests: serialise, parse, compare
/// equality on `WorkspaceBlueprintFile` / `WorkspaceApplyPlan`. No AppKit.
///
/// Per `CLAUDE.md`, never run locally — CI only.
final class WorkspaceBlueprintMarkdownTests: XCTestCase {

    // MARK: - Helpers

    private func roundTrip(_ file: WorkspaceBlueprintFile) throws -> WorkspaceBlueprintFile {
        let data = try WorkspaceBlueprintMarkdown.serialize(file)
        return try WorkspaceBlueprintMarkdown.parse(data)
    }

    // MARK: - Round-trips at the value level

    func testRoundTripSingleTerminalLeaf() throws {
        let file = WorkspaceBlueprintFile(
            name: "Single Terminal",
            description: "One terminal pane",
            plan: WorkspaceApplyPlan(
                version: 1,
                workspace: WorkspaceSpec(title: "Single Terminal"),
                layout: .pane(.init(surfaceIds: ["s1"])),
                surfaces: [
                    SurfaceSpec(id: "s1", kind: .terminal, title: "Main", workingDirectory: "~/work")
                ]
            )
        )
        let roundtripped = try roundTrip(file)
        XCTAssertEqual(roundtripped, file)
    }

    func testRoundTripHorizontalSplitTerminalAndBrowser() throws {
        let file = WorkspaceBlueprintFile(
            name: "Two Pane",
            description: nil,
            plan: WorkspaceApplyPlan(
                version: 1,
                workspace: WorkspaceSpec(title: "Two Pane"),
                layout: .split(.init(
                    orientation: .horizontal,
                    dividerPosition: 0.5,
                    first: .pane(.init(surfaceIds: ["s1"])),
                    second: .pane(.init(surfaceIds: ["s2"]))
                )),
                surfaces: [
                    SurfaceSpec(id: "s1", kind: .terminal, title: "shell"),
                    SurfaceSpec(id: "s2", kind: .browser, title: "docs", url: "https://stage11.ai")
                ]
            )
        )
        let r = try roundTrip(file)
        XCTAssertEqual(r, file)
    }

    func testRoundTripNestedSplitMatchesSchemaExample() throws {
        // Mirrors the operator-approved schema in the plan: horizontal split,
        // right side splits vertically into browser + markdown.
        let file = WorkspaceBlueprintFile(
            name: "Agent Room",
            description: "Three-pane orchestration layout",
            plan: WorkspaceApplyPlan(
                version: 1,
                workspace: WorkspaceSpec(title: "Agent Room", customColor: "#9D8048"),
                layout: .split(.init(
                    orientation: .horizontal,
                    dividerPosition: 0.5,
                    first: .pane(.init(surfaceIds: ["s1"])),
                    second: .split(.init(
                        orientation: .vertical,
                        dividerPosition: 0.6,
                        first: .pane(.init(surfaceIds: ["s2"])),
                        second: .pane(.init(surfaceIds: ["s3"]))
                    ))
                )),
                surfaces: [
                    SurfaceSpec(id: "s1", kind: .terminal, title: "Main terminal", workingDirectory: "~/Projects/Stage11/code/c11"),
                    SurfaceSpec(id: "s2", kind: .browser, title: "Lattice", url: "http://localhost:8799/"),
                    SurfaceSpec(id: "s3", kind: .markdown, title: "Notes", filePath: "~/notes/today.md")
                ]
            )
        )
        let r = try roundTrip(file)
        XCTAssertEqual(r, file)
    }

    func testRoundTripPreservesCustomColor() throws {
        let file = WorkspaceBlueprintFile(
            name: "Colored",
            description: nil,
            plan: WorkspaceApplyPlan(
                version: 1,
                workspace: WorkspaceSpec(title: "Colored", customColor: "#C0392B"),
                layout: .pane(.init(surfaceIds: ["s1"])),
                surfaces: [SurfaceSpec(id: "s1", kind: .terminal)]
            )
        )
        let r = try roundTrip(file)
        XCTAssertEqual(r.plan.workspace.customColor, "#C0392B")
    }

    func testRoundTripPreservesWorkspaceTitleDifferentFromName() throws {
        let file = WorkspaceBlueprintFile(
            name: "agent-room",                 // file/blueprint identifier
            description: nil,
            plan: WorkspaceApplyPlan(
                version: 1,
                workspace: WorkspaceSpec(title: "Agent Room"),  // human-friendly
                layout: .pane(.init(surfaceIds: ["s1"])),
                surfaces: [SurfaceSpec(id: "s1", kind: .terminal)]
            )
        )
        let r = try roundTrip(file)
        XCTAssertEqual(r.name, "agent-room")
        XCTAssertEqual(r.plan.workspace.title, "Agent Room")
    }

    // MARK: - Schema example parses

    func testParsesSchemaExampleFromOperatorPrompt() throws {
        let source = """
        ---
        title: Agent Room
        description: Three-pane orchestration layout
        custom_color: "#9D8048"
        ---

        # Agent Room

        Free-form prose body. Renders nicely in Obsidian. Parser ignores it.

        ## Layout

        ```yaml
        layout:
          - direction: horizontal
            split: 50/50
            children:
              - type: terminal
                title: Main terminal
                cwd: ~/Projects/Stage11/code/c11
              - direction: vertical
                split: 60/40
                children:
                  - type: browser
                    title: Lattice
                    url: http://localhost:8799/
                  - type: markdown
                    title: Notes
                    file: ~/notes/today.md
        ```
        """
        let parsed = try WorkspaceBlueprintMarkdown.parse(Data(source.utf8))
        XCTAssertEqual(parsed.name, "Agent Room")
        XCTAssertEqual(parsed.description, "Three-pane orchestration layout")
        XCTAssertEqual(parsed.plan.workspace.customColor, "#9D8048")
        XCTAssertEqual(parsed.plan.surfaces.count, 3)

        // Layout is split horizontally, second child is a vertical split.
        guard case .split(let outer) = parsed.plan.layout else {
            return XCTFail("expected outer split")
        }
        XCTAssertEqual(outer.orientation, .horizontal)
        XCTAssertEqual(outer.dividerPosition, 0.5, accuracy: 0.001)
        guard case .split(let inner) = outer.second else {
            return XCTFail("expected inner vertical split as second child")
        }
        XCTAssertEqual(inner.orientation, .vertical)
        XCTAssertEqual(inner.dividerPosition, 0.6, accuracy: 0.001)

        // Surface kinds in capture order: terminal, browser, markdown.
        let kinds = parsed.plan.surfaces.map { $0.kind }
        XCTAssertEqual(kinds, [.terminal, .browser, .markdown])

        // The terminal carries `cwd`, the browser carries `url`, the
        // markdown surface carries `file`.
        let terminal = parsed.plan.surfaces.first { $0.kind == .terminal }
        let browser  = parsed.plan.surfaces.first { $0.kind == .browser }
        let markdown = parsed.plan.surfaces.first { $0.kind == .markdown }
        XCTAssertEqual(terminal?.workingDirectory, "~/Projects/Stage11/code/c11")
        XCTAssertEqual(browser?.url,               "http://localhost:8799/")
        XCTAssertEqual(markdown?.filePath,         "~/notes/today.md")
    }

    // MARK: - Errors surface readable strings

    func testParseRejectsMissingLayoutSection() {
        let source = """
        ---
        title: Empty
        ---

        # Empty
        """
        XCTAssertThrowsError(try WorkspaceBlueprintMarkdown.parse(Data(source.utf8))) { err in
            guard let parseErr = err as? WorkspaceBlueprintMarkdown.ParseError else {
                return XCTFail("expected ParseError, got \(err)")
            }
            XCTAssertEqual(parseErr, .missingLayoutSection)
        }
    }

    func testParseRejectsMissingFencedCodeblock() {
        let source = """
        ---
        title: No Fence
        ---

        ## Layout

        (paragraph but no fenced YAML block)
        """
        XCTAssertThrowsError(try WorkspaceBlueprintMarkdown.parse(Data(source.utf8))) { err in
            guard let parseErr = err as? WorkspaceBlueprintMarkdown.ParseError else {
                return XCTFail("expected ParseError, got \(err)")
            }
            XCTAssertEqual(parseErr, .missingLayoutCodeblock)
        }
    }

    func testParseRejectsUnknownSurfaceKind() {
        let source = """
        ---
        title: Bad Kind
        ---

        ## Layout

        ```yaml
        layout:
          - type: spreadsheet
            title: nope
        ```
        """
        XCTAssertThrowsError(try WorkspaceBlueprintMarkdown.parse(Data(source.utf8))) { err in
            guard let parseErr = err as? WorkspaceBlueprintMarkdown.ParseError else {
                return XCTFail("expected ParseError, got \(err)")
            }
            switch parseErr {
            case .unsupportedSurfaceKind(let raw):
                XCTAssertEqual(raw, "spreadsheet")
            default:
                XCTFail("expected unsupportedSurfaceKind, got \(parseErr)")
            }
        }
    }

    func testParseRejectsSplitWithoutChildren() {
        let source = """
        ---
        title: Bad Split
        ---

        ## Layout

        ```yaml
        layout:
          - direction: horizontal
            split: 50/50
        ```
        """
        XCTAssertThrowsError(try WorkspaceBlueprintMarkdown.parse(Data(source.utf8)))
    }
}
