import XCTest
import CoreGraphics

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Unit tests for `PaneSizePolicy` — the pure size-aware split decision core.
/// Host-free: runs in the fast `c11LogicTests` target.
final class PaneSizePolicyTests: XCTestCase {

    // A realistic cell size (≈13pt monospaced) so cols×rows → points is concrete.
    private let cell = CGSize(width: 8.0, height: 17.0)

    // MARK: Per-kind minimums

    func testAgentKindsRecognized() {
        XCTAssertTrue(PaneSizePolicy.isAgentKind("claude-code"))
        XCTAssertTrue(PaneSizePolicy.isAgentKind("codex"))
        XCTAssertTrue(PaneSizePolicy.isAgentKind("opencode-run"))
        XCTAssertTrue(PaneSizePolicy.isAgentKind("  Claude-Code "))  // trimmed + lowercased
        XCTAssertFalse(PaneSizePolicy.isAgentKind("shell"))
        XCTAssertFalse(PaneSizePolicy.isAgentKind("unknown"))
        XCTAssertFalse(PaneSizePolicy.isAgentKind(nil))
        XCTAssertFalse(PaneSizePolicy.isAgentKind(""))
    }

    func testMinCellsByKind() {
        XCTAssertEqual(PaneSizePolicy.minCells(forKind: "claude-code"), PaneSizePolicy.agentMin)
        XCTAssertEqual(PaneSizePolicy.minCells(forKind: "shell"), PaneSizePolicy.terminalMin)
        XCTAssertEqual(PaneSizePolicy.minCells(forKind: nil), PaneSizePolicy.terminalMin)
    }

    func testPointsConversionAndFallback() {
        let m = PaneCellSize(cols: 80, rows: 20)
        let pts = PaneSizePolicy.points(m, cellSize: cell)
        XCTAssertEqual(pts.width, 640, accuracy: 0.001)
        XCTAssertEqual(pts.height, 340, accuracy: 0.001)

        // Zero cell size falls back to the default so we never divide by / multiply by 0.
        let fb = PaneSizePolicy.points(m, cellSize: .zero)
        XCTAssertEqual(fb.width, 80 * PaneSizePolicy.fallbackCellSize.width, accuracy: 0.001)
        XCTAssertEqual(fb.height, 20 * PaneSizePolicy.fallbackCellSize.height, accuracy: 0.001)
    }

    // MARK: Geometry

    func testChildSizeHalvesTheRightAxis() {
        let frame = CGSize(width: 1000, height: 600)
        XCTAssertEqual(PaneSizePolicy.childSize(.horizontal, paneFrame: frame), CGSize(width: 500, height: 600))
        XCTAssertEqual(PaneSizePolicy.childSize(.vertical, paneFrame: frame), CGSize(width: 1000, height: 300))
    }

    func testAdmissibility() {
        let frame = CGSize(width: 1000, height: 600)
        let min = CGSize(width: 640, height: 340)
        // Horizontal child = 500×600: width 500 < 640 → not admissible.
        XCTAssertFalse(PaneSizePolicy.admissible(.horizontal, paneFrame: frame, minPoints: min))
        // Vertical child = 1000×300: height 300 < 340 → not admissible.
        XCTAssertFalse(PaneSizePolicy.admissible(.vertical, paneFrame: frame, minPoints: min))
        // A roomier pane admits both.
        let big = CGSize(width: 2000, height: 1400)
        XCTAssertTrue(PaneSizePolicy.admissible(.horizontal, paneFrame: big, minPoints: min))
        XCTAssertTrue(PaneSizePolicy.admissible(.vertical, paneFrame: big, minPoints: min))
    }

    // MARK: Decision — escape hatches

    func testOffModeAlwaysProceedsRequested() {
        let frame = CGSize(width: 200, height: 120) // way too small
        let min = CGSize(width: 640, height: 340)
        let d = PaneSizePolicy.decide(paneFrame: frame, requested: .vertical, minPoints: min, mode: .off, force: false)
        XCTAssertEqual(d.outcome, .proceed(.vertical))
        XCTAssertFalse(d.flipped)
    }

    func testForceBypassesPolicyEvenInBalance() {
        let frame = CGSize(width: 200, height: 120)
        let min = CGSize(width: 640, height: 340)
        let d = PaneSizePolicy.decide(paneFrame: frame, requested: .horizontal, minPoints: min, mode: .balance, force: true)
        XCTAssertEqual(d.outcome, .proceed(.horizontal))
        XCTAssertFalse(d.flipped)
    }

    // MARK: Decision — balance

    func testBalanceProceedsWhenRequestedFits() {
        let frame = CGSize(width: 2000, height: 1400)
        let min = CGSize(width: 640, height: 340)
        let d = PaneSizePolicy.decide(paneFrame: frame, requested: .horizontal, minPoints: min, mode: .balance, force: false)
        XCTAssertEqual(d.outcome, .proceed(.horizontal))
        XCTAssertFalse(d.flipped)
        XCTAssertEqual(d.status, .ok)
    }

    func testBalanceFlipsToRoomierAxis() {
        // Wide & short: a horizontal (side-by-side) split keeps full height; a vertical
        // (stacked) split would halve the already-marginal height.
        let frame = CGSize(width: 2000, height: 360)
        let min = CGSize(width: 640, height: 340)
        // Requested vertical: child = 2000×180 → height 180 < 340, not admissible.
        // Horizontal: child = 1000×360 → both ≥ min, admissible. Expect a flip.
        let d = PaneSizePolicy.decide(paneFrame: frame, requested: .vertical, minPoints: min, mode: .balance, force: false)
        XCTAssertEqual(d.outcome, .proceed(.horizontal))
        XCTAssertTrue(d.flipped)
        XCTAssertEqual(d.appliedAxis, .horizontal)
    }

    func testBalanceRefusesWhenNeitherAxisFits() {
        let frame = CGSize(width: 700, height: 360)
        let min = CGSize(width: 640, height: 340)
        // Horizontal child = 350×360 → width 350 < 640.
        // Vertical child = 700×180 → height 180 < 340. Neither fits → refuse.
        let d = PaneSizePolicy.decide(paneFrame: frame, requested: .horizontal, minPoints: min, mode: .balance, force: false)
        XCTAssertEqual(d.outcome, .refuse)
        XCTAssertEqual(d.status, .undersized)
    }

    func testTabModeFallsBackToTabWhenNeitherAxisFits() {
        let frame = CGSize(width: 700, height: 360)
        let min = CGSize(width: 640, height: 340)
        let d = PaneSizePolicy.decide(paneFrame: frame, requested: .horizontal, minPoints: min, mode: .tab, force: false)
        XCTAssertEqual(d.outcome, .addTab)
    }

    func testWarnModeNeverBlocksButReportsUndersized() {
        let frame = CGSize(width: 700, height: 360)
        let min = CGSize(width: 640, height: 340)
        let d = PaneSizePolicy.decide(paneFrame: frame, requested: .horizontal, minPoints: min, mode: .warn, force: false)
        XCTAssertEqual(d.outcome, .proceed(.horizontal))
        XCTAssertFalse(d.flipped)
        XCTAssertEqual(d.status, .undersized)
        XCTAssertNotNil(PaneSizePolicy.warningText(for: d, kindLabel: "claude-code"))
    }

    // MARK: The motivating repros

    func test584x173AgentPaneIsRefused() {
        // The observed unusable pane: ≈584×173pt holding a coding agent.
        let frame = CGSize(width: 584, height: 173)
        let min = PaneSizePolicy.points(PaneSizePolicy.agentMin, cellSize: cell)  // 640×340
        for axis in [SplitAxis.horizontal, .vertical] {
            let d = PaneSizePolicy.decide(paneFrame: frame, requested: axis, minPoints: min, mode: .balance, force: false)
            XCTAssertEqual(d.outcome, .refuse, "axis \(axis) should refuse for an already-tiny agent pane")
        }
    }

    func testOrchestratorFanoutFlipsThenRefuses() {
        // A 2400-wide, 800-tall pane fanned out by repeated side-by-side splits.
        let min = PaneSizePolicy.points(PaneSizePolicy.agentMin, cellSize: cell) // 640×340
        // First split of 2400×800 horizontally → child 1200×800: fine.
        var d = PaneSizePolicy.decide(paneFrame: CGSize(width: 2400, height: 800), requested: .horizontal, minPoints: min, mode: .balance, force: false)
        XCTAssertEqual(d.outcome, .proceed(.horizontal))
        // Splitting a 1200×800 child again horizontally → 600×800: width 600 < 640.
        // Vertical → 1200×400: both ≥ min → flip to vertical.
        d = PaneSizePolicy.decide(paneFrame: CGSize(width: 1200, height: 800), requested: .horizontal, minPoints: min, mode: .balance, force: false)
        XCTAssertEqual(d.outcome, .proceed(.vertical))
        XCTAssertTrue(d.flipped)
        // A 600×400 pane: horizontal → 300×400 (w<640), vertical → 600×200 (h<340) → refuse.
        d = PaneSizePolicy.decide(paneFrame: CGSize(width: 600, height: 400), requested: .horizontal, minPoints: min, mode: .balance, force: false)
        XCTAssertEqual(d.outcome, .refuse)
    }

    // MARK: Status classification

    func testStatusClassification() {
        let min = CGSize(width: 100, height: 100)
        XCTAssertEqual(PaneSizePolicy.status(child: CGSize(width: 200, height: 200), minPoints: min), .ok)
        XCTAssertEqual(PaneSizePolicy.status(child: CGSize(width: 105, height: 200), minPoints: min), .near)
        XCTAssertEqual(PaneSizePolicy.status(child: CGSize(width: 90, height: 200), minPoints: min), .undersized)
    }

    // MARK: Messages

    func testRefusalMessageIsActionable() {
        let frame = CGSize(width: 700, height: 360)
        let min = CGSize(width: 640, height: 340)
        let d = PaneSizePolicy.decide(paneFrame: frame, requested: .horizontal, minPoints: min, mode: .balance, force: false)
        let msg = PaneSizePolicy.refusalMessage(for: d, kindLabel: "claude-code", paneRefLabel: "pane:3")
        XCTAssertTrue(msg.contains("pane:3"))
        XCTAssertTrue(msg.contains("new-surface"))
        XCTAssertTrue(msg.contains("--allow-undersized"))
        XCTAssertTrue(msg.contains("claude-code"))
    }

    func testFlippedWarningMentionsBothAxes() {
        let frame = CGSize(width: 2000, height: 360)
        let min = CGSize(width: 640, height: 340)
        let d = PaneSizePolicy.decide(paneFrame: frame, requested: .vertical, minPoints: min, mode: .balance, force: false)
        let warn = PaneSizePolicy.warningText(for: d, kindLabel: "claude-code")
        XCTAssertNotNil(warn)
        XCTAssertTrue(warn!.contains("stacked"))
        XCTAssertTrue(warn!.contains("side-by-side"))
    }

    // MARK: Settings parsing

    func testModeParsing() {
        XCTAssertEqual(PaneSizeMode.parse("balance"), .balance)
        XCTAssertEqual(PaneSizeMode.parse(" TAB "), .tab)
        XCTAssertEqual(PaneSizeMode.parse("off"), .off)
        XCTAssertNil(PaneSizeMode.parse("nonsense"))
        XCTAssertNil(PaneSizeMode.parse(nil))
        XCTAssertEqual(PaneSizeMode.default, .balance)
    }
}
