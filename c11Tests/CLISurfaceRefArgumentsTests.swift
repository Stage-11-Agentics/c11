import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// `c11 close-surface surface:101` once closed the *caller's* surface: the
/// positional was parsed by nothing, matched by nothing, and silently
/// discarded, so the resolver fell through to $CMUX_SURFACE_ID. It killed a
/// live operator session and the two sub-agents under it.
///
/// The invariant these tests pin: **an argument that names a target is honored
/// or refused, never discarded.** The caller's own surface stays the default
/// for a bare command line and nothing else.
final class CLISurfaceRefArgumentsTests: XCTestCase {

    private func plan(_ args: [String], file: StaticString = #filePath, line: UInt = #line)
        -> CLISurfaceRefArguments.CloseSurfacePlan? {
        switch CLISurfaceRefArguments.parseCloseSurface(args) {
        case .plan(let plan):
            return plan
        case .reject(let message):
            XCTFail("expected a plan, got reject: \(message)", file: file, line: line)
            return nil
        }
    }

    private func rejection(_ args: [String], file: StaticString = #filePath, line: UInt = #line) -> String? {
        switch CLISurfaceRefArguments.parseCloseSurface(args) {
        case .plan(let plan):
            XCTFail("expected a rejection, got plan surface=\(String(describing: plan.surface))", file: file, line: line)
            return nil
        case .reject(let message):
            return message
        }
    }

    // MARK: - The incident

    func testPositionalSurfaceHandleIsHonoredNotDiscarded() {
        guard let plan = plan(["surface:101"]) else { return }
        XCTAssertEqual(plan.surface, "surface:101")
        XCTAssertTrue(
            plan.namesSurface,
            "naming surface:101 must disable the $CMUX_SURFACE_ID fallback — this is the bug that killed a live session"
        )
    }

    func testPositionalHandleWithWorkspaceFlagInEitherOrder() {
        XCTAssertEqual(plan(["--workspace", "workspace:2", "surface:101"])?.surface, "surface:101")
        XCTAssertEqual(plan(["surface:101", "--workspace", "workspace:2"])?.surface, "surface:101")
        XCTAssertEqual(plan(["surface:101", "--workspace", "workspace:2"])?.workspace, "workspace:2")
    }

    func testUUIDPositionalIsHonored() {
        let uuid = "9E4C3E52-6E4E-4B0E-9E2E-0A1B2C3D4E5F"
        XCTAssertEqual(plan([uuid])?.surface, uuid)
    }

    // MARK: - The `=` form, which failed the same way

    func testInlineEqualsValueIsHonored() {
        // `optionValue` matches `--surface` exactly, so `--surface=surface:101`
        // was discarded and fell through to the caller's own surface — with the
        // operator having explicitly typed the flag.
        guard let plan = plan(["--surface=surface:101"]) else { return }
        XCTAssertEqual(plan.surface, "surface:101")
        XCTAssertTrue(plan.namesSurface)
    }

    func testInlineEqualsWorkspaceIsHonored() {
        XCTAssertEqual(plan(["--workspace=workspace:4"])?.workspace, "workspace:4")
    }

    // MARK: - The default that should stay

    func testBareCommandLineStillDefaultsToCaller() {
        guard let plan = plan([]) else { return }
        XCTAssertNil(plan.surface)
        XCTAssertNil(plan.workspace)
        XCTAssertFalse(plan.namesSurface, "a bare `c11 close-surface` must still close the caller's own surface")
    }

    func testExplicitFlagsStillWork() {
        XCTAssertEqual(plan(["--surface", "surface:3"])?.surface, "surface:3")
        XCTAssertEqual(plan(["--panel", "surface:3"])?.surface, "surface:3")
    }

    // MARK: - Refusals

    func testWrongKindHandlesAreRefusedWithGuidance() {
        XCTAssertTrue(rejection(["pane:46"])?.contains("c11 kill pane:46") == true)
        XCTAssertTrue(rejection(["workspace:2"])?.contains("close-workspace") == true)
        XCTAssertTrue(rejection(["tab:5"])?.contains("surface:5") == true)
        XCTAssertTrue(rejection(["window:1"])?.contains("close-window") == true)
    }

    func testBareIndexIsRefusedAsAmbiguous() {
        XCTAssertTrue(rejection(["3"])?.contains("--surface 3") == true)
    }

    func testUnknownPositionalIsRefused() {
        XCTAssertTrue(rejection(["banana"])?.contains("unexpected argument 'banana'") == true)
    }

    func testUnknownFlagIsRefused() {
        XCTAssertTrue(rejection(["--json"])?.contains("unknown flag '--json'") == true)
    }

    func testFlagMissingValueIsRefused() {
        XCTAssertTrue(rejection(["--surface"])?.contains("requires a value") == true)
        XCTAssertTrue(rejection(["--surface", "--workspace", "workspace:1"])?.contains("requires a value") == true)
    }

    func testEmptyFlagValuesAreRefusedClientSide() {
        XCTAssertTrue(rejection(["--surface="])?.contains("requires a non-empty value") == true)
        XCTAssertTrue(rejection(["--surface", " \t "])?.contains("requires a non-empty value") == true)
        XCTAssertTrue(rejection(["--panel="])?.contains("requires a non-empty value") == true)
        XCTAssertTrue(rejection(["--workspace="])?.contains("requires a non-empty value") == true)
    }

    func testConflictingTargetsAreRefused() {
        // Naming two different surfaces can only ever be a mistake; guessing
        // which one to destroy is not an option.
        XCTAssertTrue(rejection(["--surface", "surface:1", "surface:2"])?.contains("more than one surface") == true)
        XCTAssertTrue(rejection(["surface:1", "surface:2"])?.contains("more than one surface") == true)
        XCTAssertTrue(rejection(["--surface", "surface:1", "--panel", "surface:2"])?.contains("more than one surface") == true)
    }

    func testRepeatingTheSameTargetIsNotAConflict() {
        XCTAssertEqual(plan(["--surface", "surface:1", "surface:1"])?.surface, "surface:1")
    }

    // MARK: - tab-action positional safety

    func testEveryNonRenameTabActionRejectsEveryLeftoverPositionalShape() {
        let actions = [
            "clear-name",
            "close-left", "close-right", "close-others",
            "new-terminal-right", "new-browser-right",
            "reload", "duplicate", "pin", "unpin", "mark-unread",
            "future-action",
        ]
        let unexpected = [
            "surface:9",
            "9",
            "surface:",
            "ordinary text",
        ]

        for action in actions {
            for positional in unexpected {
                let rejection = CLISurfaceRefArguments.tabActionPositionalRejection(
                    action: action,
                    positional: [positional]
                )
                XCTAssertNotNil(
                    rejection,
                    "\(action) must reject leftover positional '\(positional)' instead of falling back to caller focus"
                )
                XCTAssertTrue(rejection?.contains("unexpected '\(positional)'") == true)
                XCTAssertTrue(rejection?.contains("--tab <id|ref|index>") == true)
            }
        }
    }

    func testNonRenameTabActionRejectsTheFirstOfMultipleLeftovers() {
        let rejection = CLISurfaceRefArguments.tabActionPositionalRejection(
            action: "close-others",
            positional: ["surface:", "ignored-second-token"]
        )
        XCTAssertTrue(rejection?.contains("unexpected 'surface:'") == true)
    }

    func testTabActionWithoutLeftoverPositionalIsAccepted() {
        XCTAssertNil(
            CLISurfaceRefArguments.tabActionPositionalRejection(
                action: "close-others",
                positional: []
            )
        )
    }

    func testRenamePreservesAllTrailingTitleSemantics() {
        let titles = [
            ["Session", "forensics"],
            ["3"],
            ["surface:9"],
            ["surface:"],
            ["notes:today"],
        ]

        for title in titles {
            XCTAssertNil(
                CLISurfaceRefArguments.tabActionPositionalRejection(
                    action: "ReNaMe",
                    positional: title
                ),
                "rename must preserve trailing title tokens \(title)"
            )
        }
    }
}
