import XCTest
import CoreGraphics

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Unit tests for `PaneSizePolicy` — the pure size-aware split decision core.
/// Host-free: runs in the fast `c11LogicTests` target.
final class AreaSizePolicyTests: XCTestCase {

    // A realistic cell size (≈13pt monospaced) so cols×rows → points is concrete.
    private let cell = CGSize(width: 8.0, height: 17.0)

    // MARK: Per-kind minimums

    func testAgentKindsRecognized() {
        XCTAssertTrue(AreaSizePolicy.isAgentKind("claude-code"))
        XCTAssertTrue(AreaSizePolicy.isAgentKind("codex"))
        XCTAssertTrue(AreaSizePolicy.isAgentKind("opencode-run"))
        XCTAssertTrue(AreaSizePolicy.isAgentKind("  Claude-Code "))  // trimmed + lowercased
        XCTAssertFalse(AreaSizePolicy.isAgentKind("shell"))
        XCTAssertFalse(AreaSizePolicy.isAgentKind("unknown"))
        XCTAssertFalse(AreaSizePolicy.isAgentKind(nil))
        XCTAssertFalse(AreaSizePolicy.isAgentKind(""))
    }

    func testMinCellsByKind() {
        XCTAssertEqual(AreaSizePolicy.minCells(forKind: "claude-code"), AreaSizePolicy.agentMin)
        XCTAssertEqual(AreaSizePolicy.minCells(forKind: "shell"), AreaSizePolicy.terminalMin)
        XCTAssertEqual(AreaSizePolicy.minCells(forKind: nil), AreaSizePolicy.terminalMin)
    }

    func testPointsConversionAndFallback() {
        let m = AreaCellSize(cols: 80, rows: 20)
        let pts = AreaSizePolicy.points(m, cellSize: cell)
        XCTAssertEqual(pts.width, 640, accuracy: 0.001)
        XCTAssertEqual(pts.height, 340, accuracy: 0.001)

        // Zero cell size falls back to the default so we never divide by / multiply by 0.
        let fb = AreaSizePolicy.points(m, cellSize: .zero)
        XCTAssertEqual(fb.width, 80 * AreaSizePolicy.fallbackCellSize.width, accuracy: 0.001)
        XCTAssertEqual(fb.height, 20 * AreaSizePolicy.fallbackCellSize.height, accuracy: 0.001)
    }

    // MARK: Geometry

    func testChildSizeHalvesTheRightAxis() {
        let frame = CGSize(width: 1000, height: 600)
        XCTAssertEqual(AreaSizePolicy.childSize(.horizontal, paneFrame: frame), CGSize(width: 500, height: 600))
        XCTAssertEqual(AreaSizePolicy.childSize(.vertical, paneFrame: frame), CGSize(width: 1000, height: 300))
    }

    func testAdmissibility() {
        let frame = CGSize(width: 1000, height: 600)
        let min = CGSize(width: 640, height: 340)
        // Horizontal child = 500×600: width 500 < 640 → not admissible.
        XCTAssertFalse(AreaSizePolicy.admissible(.horizontal, paneFrame: frame, minPoints: min))
        // Vertical child = 1000×300: height 300 < 340 → not admissible.
        XCTAssertFalse(AreaSizePolicy.admissible(.vertical, paneFrame: frame, minPoints: min))
        // A roomier pane admits both.
        let big = CGSize(width: 2000, height: 1400)
        XCTAssertTrue(AreaSizePolicy.admissible(.horizontal, paneFrame: big, minPoints: min))
        XCTAssertTrue(AreaSizePolicy.admissible(.vertical, paneFrame: big, minPoints: min))
    }

    // MARK: Decision — escape hatches

    func testOffModeAlwaysProceedsRequested() {
        let frame = CGSize(width: 200, height: 120) // way too small
        let min = CGSize(width: 640, height: 340)
        let d = AreaSizePolicy.decide(paneFrame: frame, requested: .vertical, minPoints: min, mode: .off, force: false)
        XCTAssertEqual(d.outcome, .proceed(.vertical))
        XCTAssertFalse(d.flipped)
    }

    func testForceBypassesPolicyEvenInBalance() {
        let frame = CGSize(width: 200, height: 120)
        let min = CGSize(width: 640, height: 340)
        let d = AreaSizePolicy.decide(paneFrame: frame, requested: .horizontal, minPoints: min, mode: .balance, force: true)
        XCTAssertEqual(d.outcome, .proceed(.horizontal))
        XCTAssertFalse(d.flipped)
    }

    // MARK: Decision — balance

    func testBalanceProceedsWhenRequestedFits() {
        let frame = CGSize(width: 2000, height: 1400)
        let min = CGSize(width: 640, height: 340)
        let d = AreaSizePolicy.decide(paneFrame: frame, requested: .horizontal, minPoints: min, mode: .balance, force: false)
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
        let d = AreaSizePolicy.decide(paneFrame: frame, requested: .vertical, minPoints: min, mode: .balance, force: false)
        XCTAssertEqual(d.outcome, .proceed(.horizontal))
        XCTAssertTrue(d.flipped)
        XCTAssertEqual(d.appliedAxis, .horizontal)
    }

    func testBalanceRefusesWhenNeitherAxisFits() {
        let frame = CGSize(width: 700, height: 360)
        let min = CGSize(width: 640, height: 340)
        // Horizontal child = 350×360 → width 350 < 640.
        // Vertical child = 700×180 → height 180 < 340. Neither fits → refuse.
        let d = AreaSizePolicy.decide(paneFrame: frame, requested: .horizontal, minPoints: min, mode: .balance, force: false)
        XCTAssertEqual(d.outcome, .refuse)
        XCTAssertEqual(d.status, .undersized)
    }

    func testTabModeFallsBackToTabWhenNeitherAxisFits() {
        let frame = CGSize(width: 700, height: 360)
        let min = CGSize(width: 640, height: 340)
        let d = AreaSizePolicy.decide(paneFrame: frame, requested: .horizontal, minPoints: min, mode: .tab, force: false)
        XCTAssertEqual(d.outcome, .addTab)
    }

    func testWarnModeNeverBlocksButReportsUndersized() {
        let frame = CGSize(width: 700, height: 360)
        let min = CGSize(width: 640, height: 340)
        let d = AreaSizePolicy.decide(paneFrame: frame, requested: .horizontal, minPoints: min, mode: .warn, force: false)
        XCTAssertEqual(d.outcome, .proceed(.horizontal))
        XCTAssertFalse(d.flipped)
        XCTAssertEqual(d.status, .undersized)
        XCTAssertNotNil(AreaSizePolicy.warningText(for: d, kindLabel: "claude-code"))
    }

    // MARK: The motivating repros

    func test584x173AgentAreaIsRefused() {
        // The observed unusable pane: ≈584×173pt holding a coding agent.
        let frame = CGSize(width: 584, height: 173)
        let min = AreaSizePolicy.points(AreaSizePolicy.agentMin, cellSize: cell)  // 640×340
        for axis in [SplitAxis.horizontal, .vertical] {
            let d = AreaSizePolicy.decide(paneFrame: frame, requested: axis, minPoints: min, mode: .balance, force: false)
            XCTAssertEqual(d.outcome, .refuse, "axis \(axis) should refuse for an already-tiny agent pane")
        }
    }

    func testOrchestratorFanoutFlipsThenRefuses() {
        // A 2400-wide, 800-tall pane fanned out by repeated side-by-side splits.
        let min = AreaSizePolicy.points(AreaSizePolicy.agentMin, cellSize: cell) // 640×340
        // First split of 2400×800 horizontally → child 1200×800: fine.
        var d = AreaSizePolicy.decide(paneFrame: CGSize(width: 2400, height: 800), requested: .horizontal, minPoints: min, mode: .balance, force: false)
        XCTAssertEqual(d.outcome, .proceed(.horizontal))
        // Splitting a 1200×800 child again horizontally → 600×800: width 600 < 640.
        // Vertical → 1200×400: both ≥ min → flip to vertical.
        d = AreaSizePolicy.decide(paneFrame: CGSize(width: 1200, height: 800), requested: .horizontal, minPoints: min, mode: .balance, force: false)
        XCTAssertEqual(d.outcome, .proceed(.vertical))
        XCTAssertTrue(d.flipped)
        // A 600×400 pane: horizontal → 300×400 (w<640), vertical → 600×200 (h<340) → refuse.
        d = AreaSizePolicy.decide(paneFrame: CGSize(width: 600, height: 400), requested: .horizontal, minPoints: min, mode: .balance, force: false)
        XCTAssertEqual(d.outcome, .refuse)
    }

    // MARK: Status classification

    func testStatusClassification() {
        let min = CGSize(width: 100, height: 100)
        XCTAssertEqual(AreaSizePolicy.status(child: CGSize(width: 200, height: 200), minPoints: min), .ok)
        XCTAssertEqual(AreaSizePolicy.status(child: CGSize(width: 105, height: 200), minPoints: min), .near)
        XCTAssertEqual(AreaSizePolicy.status(child: CGSize(width: 90, height: 200), minPoints: min), .undersized)
    }

    // MARK: Messages

    func testRefusalMessageIsActionable() {
        let frame = CGSize(width: 700, height: 360)
        let min = CGSize(width: 640, height: 340)
        let d = AreaSizePolicy.decide(paneFrame: frame, requested: .horizontal, minPoints: min, mode: .balance, force: false)
        let msg = AreaSizePolicy.refusalMessage(for: d, kindLabel: "claude-code", paneRefLabel: "area:3")
        XCTAssertTrue(msg.contains("area:3"))
        XCTAssertTrue(msg.contains("new-panel"))
        XCTAssertTrue(msg.contains("--allow-undersized"))
        XCTAssertTrue(msg.contains("claude-code"))
    }

    func testFlippedWarningMentionsBothAxes() {
        let frame = CGSize(width: 2000, height: 360)
        let min = CGSize(width: 640, height: 340)
        let d = AreaSizePolicy.decide(paneFrame: frame, requested: .vertical, minPoints: min, mode: .balance, force: false)
        let warn = AreaSizePolicy.warningText(for: d, kindLabel: "claude-code")
        XCTAssertNotNil(warn)
        XCTAssertTrue(warn!.contains("stacked"))
        XCTAssertTrue(warn!.contains("side-by-side"))
    }

    // MARK: Settings parsing

    func testModeParsing() {
        XCTAssertEqual(AreaSizeMode.parse("balance"), .balance)
        XCTAssertEqual(AreaSizeMode.parse(" TAB "), .tab)
        XCTAssertEqual(AreaSizeMode.parse("panel"), .tab)
        XCTAssertEqual(AreaSizeMode.tab.rawValue, "tab")
        XCTAssertEqual(AreaSizeMode.parse("off"), .off)
        XCTAssertNil(AreaSizeMode.parse("nonsense"))
        XCTAssertNil(AreaSizeMode.parse(nil))
        XCTAssertEqual(AreaSizeMode.default, .balance)
    }
}
