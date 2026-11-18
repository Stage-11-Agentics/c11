import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Host tests only compose argv: they never launch or signal a process
/// (CLAUDE.md, Testing). The gate's live behaviour under a PTY (released by
/// the attach RESIZE with the pid kept, 1 s bound, immediate when already
/// sized, argv byte for byte, no stray sleep) is proven in a guest by
/// `tools/c11h-proofs/T5.8-gate.sh`, and end to end by `T5.8.sh` (both archived
/// in the private c11-ops repo).
final class HCSizeGateTests: XCTestCase {
    func testTheGateRunsTheProgramsArgvUnchangedAfterItsOwnArguments() {
        let argv = HCSizeGate.wrap(["/bin/zsh", "-l"], panelGrid: HCGridSize(columns: 100, rows: 40))
        XCTAssertEqual(argv, ["/bin/sh", "-c", HCSizeGate.script, "c11-size-gate", "40 100", "120 200", "1", "/bin/zsh", "-l"])
    }

    func testWithoutAPanelGridTheGateWaitsOnlyForTheHeadlessSizeToChange() {
        let argv = HCSizeGate.wrap(["/bin/zsh"], panelGrid: nil)
        XCTAssertEqual(argv[4], "", "no wanted size")
        XCTAssertEqual(argv[5], "120 200")
    }

    func testTheBoundAndHeadlessSizeAreParameters() {
        let argv = HCSizeGate.wrap(["/bin/zsh"], panelGrid: HCGridSize(columns: 80, rows: 24),
                                   headless: HCGridSize(columns: 160, rows: 50), boundSeconds: 2)
        XCTAssertEqual(Array(argv[4...6]), ["24 80", "50 160", "2"])
    }

    func testArgvWithSpacesAndQuotesIsPassedAsSeparateWords() {
        let tricky = ["a b", "$HOME", "*", "'q'", "\"dq\"", "-l", ""]
        let argv = HCSizeGate.wrap(["/bin/sh", "-c", "true", "argv0"] + tricky, panelGrid: nil)
        XCTAssertEqual(Array(argv.suffix(tricky.count)), tricky)
    }

    func testWrapNeverNestsAndLeavesEmptyArgvAlone() {
        let once = HCSizeGate.wrap(["/bin/zsh", "-l"], panelGrid: HCGridSize(columns: 80, rows: 24))
        XCTAssertEqual(HCSizeGate.wrap(once, panelGrid: HCGridSize(columns: 80, rows: 24)), once)
        XCTAssertEqual(HCSizeGate.wrap([], panelGrid: nil), [])
        XCTAssertEqual(HCSizeGate.wrap([""], panelGrid: nil), [""])
    }
}
