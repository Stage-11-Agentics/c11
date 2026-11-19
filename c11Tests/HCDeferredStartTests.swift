import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// The hc start of a panel's native surface runs once per surface. When an
/// input is missing at that moment (the grid is empty until the surface has
/// been sized, and a panel first shown after a no-window deferral is created
/// before its layout), the start must wait and run when the input arrives;
/// before, it published unresolved(backendNotInstalled) and never ran again,
/// so the panel had a live surface, no attachment, and refused every send.
@MainActor
final class HCDeferredStartTests: XCTestCase {
    /// A stand-in for the surface: its grid is empty until `size()`.
    private final class Surface {
        var hasGrid = false
        var starts = 0
        var tries = 0
        func size() { hasGrid = true }
        func attempt() -> HCStartOutcome {
            tries += 1
            guard hasGrid else { return .blocked(.surfaceGrid) }
            starts += 1
            return .started
        }
    }

    func testAStartThatLacksTheGridRunsWhenTheSurfaceIsSized() {
        let surface = Surface()
        let gate = HCDeferredStart()
        gate.begin(firstSurface: false) { _ in surface.attempt() }
        XCTAssertEqual(surface.starts, 0)
        XCTAssertTrue(gate.isWaiting)
        XCTAssertEqual(gate.blocker, .surfaceGrid)

        surface.size()
        gate.inputsMayHaveArrived()

        XCTAssertEqual(surface.starts, 1, "the start must run once the grid exists")
        XCTAssertFalse(gate.isWaiting)
        XCTAssertNil(gate.blocker)
    }

    func testAStartThatCanRunNowHoldsNothingAndNeverRunsTwice() {
        let surface = Surface()
        surface.size()
        let gate = HCDeferredStart()
        gate.begin(firstSurface: false) { _ in surface.attempt() }
        XCTAssertEqual(surface.starts, 1)
        XCTAssertFalse(gate.isWaiting)

        gate.inputsMayHaveArrived()
        gate.inputsMayHaveArrived()
        XCTAssertEqual(surface.starts, 1, "a started panel is never started again")
        XCTAssertEqual(surface.tries, 1)
    }

    func testARetryThatStillLacksTheInputKeepsWaitingWithoutAnotherReport() {
        let surface = Surface()
        var reported: [HCStartBlocker] = []
        let gate = HCDeferredStart(onBlocked: { reported.append($0) })
        gate.begin(firstSurface: false) { _ in surface.attempt() }
        gate.inputsMayHaveArrived()
        gate.inputsMayHaveArrived()
        XCTAssertEqual(surface.tries, 3)
        XCTAssertEqual(reported, [.surfaceGrid], "the missing condition is reported once, not once per retry")
        XCTAssertTrue(gate.isWaiting)

        surface.size()
        gate.inputsMayHaveArrived()
        XCTAssertEqual(surface.starts, 1)
    }

    func testADifferentMissingInputIsReportedAgain() {
        var missing: HCStartBlocker? = .hcConfiguration
        var reported: [HCStartBlocker] = []
        var started = 0
        let gate = HCDeferredStart(onBlocked: { reported.append($0) })
        gate.begin(firstSurface: false) { _ in
            if let missing { return .blocked(missing) }
            started += 1
            return .started
        }
        missing = .surfaceGrid
        gate.inputsMayHaveArrived()
        XCTAssertEqual(reported, [.hcConfiguration, .surfaceGrid])
        missing = nil
        gate.inputsMayHaveArrived()
        XCTAssertEqual(started, 1)
    }

    func testAnAttemptForAGoneSurfaceIsDroppedNotRetried() {
        var tries = 0
        let gate = HCDeferredStart()
        gate.begin(firstSurface: false) { _ in tries += 1; return .abandoned }
        XCTAssertFalse(gate.isWaiting)
        gate.inputsMayHaveArrived()
        XCTAssertEqual(tries, 1)
    }

    func testCancelStopsAWaitingStart() {
        let surface = Surface()
        let gate = HCDeferredStart()
        gate.begin(firstSurface: false) { _ in surface.attempt() }
        gate.cancel()
        surface.size()
        gate.inputsMayHaveArrived()
        XCTAssertEqual(surface.starts, 0, "a torn-down surface must not start")
        XCTAssertFalse(gate.isWaiting)
    }

    func testANewBeginReplacesAWaitingStart() {
        let old = Surface()
        let new = Surface()
        let gate = HCDeferredStart()
        gate.begin(firstSurface: false) { _ in old.attempt() }
        gate.begin(firstSurface: false) { _ in new.attempt() }
        old.size()
        new.size()
        gate.inputsMayHaveArrived()
        XCTAssertEqual(old.starts, 0)
        XCTAssertEqual(new.starts, 1)
    }

    /// The operator's `initial-command` applies to the app's first native
    /// surface only. The app-wide "a surface was created" flag flips as soon
    /// as the surface exists, so a start that waited for its grid must keep
    /// the selection it began with.
    func testARetryKeepsTheFirstSurfaceSelectionTheStartBeganWith() {
        var appHasCreatedASurface = false
        var grid = false
        var selected: [String] = []
        // What production does: capture(initial:) picks the command.
        func capture(initial: Bool) -> String { initial ? "initial-command" : "command" }
        let gate = HCDeferredStart()
        gate.begin(firstSurface: !appHasCreatedASurface) { firstSurface in
            guard grid else { return .blocked(.surfaceGrid) }
            selected.append(capture(initial: firstSurface))
            return .started
        }
        appHasCreatedASurface = true   // createSurface does this right after the start
        grid = true
        gate.inputsMayHaveArrived()
        gate.inputsMayHaveArrived()
        XCTAssertEqual(selected, ["initial-command"], "once, with the selection the start began with")
    }

    func testALaterSurfaceStartsWithTheRegularCommandAcrossRetries() {
        var grid = false
        var selected: [String] = []
        let gate = HCDeferredStart()
        gate.begin(firstSurface: false) { firstSurface in
            guard grid else { return .blocked(.surfaceGrid) }
            selected.append(firstSurface ? "initial-command" : "command")
            return .started
        }
        grid = true
        gate.inputsMayHaveArrived()
        XCTAssertEqual(selected, ["command"])
    }
}
