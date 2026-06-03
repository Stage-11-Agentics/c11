import XCTest
@testable import c11

/// C11-104 — projector tests.
///
/// Verifies AC3, AC4, AC5, AC6, AC7, AC14 by feeding constructed
/// `ResolvedGitContext` values into `WorktreeChipProjector.project` and
/// asserting on the chip shape.
final class WorktreeChipProjectorTests: XCTestCase {

    // MARK: - AC3: Main/master/trunk dim

    func testMainBranchIsDimmed() {
        let context = ResolvedGitContext(outer: .mainCheckout(branch: .attached("main")))
        let rows = WorktreeChipProjector.project(context, settingsEnabled: true)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].worktree)
        XCTAssertTrue(rows[0].branch.isDimmed)
        XCTAssertEqual(rows[0].branch.label, "main")
    }

    func testMasterBranchIsDimmed() {
        let context = ResolvedGitContext(outer: .mainCheckout(branch: .attached("master")))
        let rows = WorktreeChipProjector.project(context, settingsEnabled: true)
        XCTAssertTrue(rows[0].branch.isDimmed)
    }

    func testTrunkBranchIsDimmed() {
        let context = ResolvedGitContext(outer: .mainCheckout(branch: .attached("trunk")))
        let rows = WorktreeChipProjector.project(context, settingsEnabled: true)
        XCTAssertTrue(rows[0].branch.isDimmed)
    }

    func testFeatureBranchNotDimmed() {
        let context = ResolvedGitContext(outer: .mainCheckout(branch: .attached("feature/x")))
        let rows = WorktreeChipProjector.project(context, settingsEnabled: true)
        XCTAssertFalse(rows[0].branch.isDimmed)
        XCTAssertEqual(rows[0].branch.label, "feature/x")
    }

    // MARK: - AC4: Color stability + distinctness

    func testWorktreeColorStableAcrossCalls() {
        let path = "/Users/atin/code/c11-worktrees/c11-104-sidebar-chips"
        let context = ResolvedGitContext(
            outer: .linkedWorktree(
                basename: "c11-104-sidebar-chips",
                absolutePath: path,
                branch: .attached("feat/x")
            )
        )
        let a = WorktreeChipProjector.project(context, settingsEnabled: true)
        let b = WorktreeChipProjector.project(context, settingsEnabled: true)
        XCTAssertEqual(a[0].worktree?.dotColorHex, b[0].worktree?.dotColorHex)
    }

    func testDifferentWorktreesGetDifferentColors() {
        // Two paths chosen so that DJB2(path).bucket differs across the
        // 10-entry palette. Sanity-checked at authoring time.
        let pathA = "/Users/atin/code/c11-worktrees/c11-104-sidebar-chips"
        let pathB = "/Users/atin/code/c11-worktrees/c11-103-session-resume"
        let a = WorktreeChipProjector.project(
            ResolvedGitContext(outer: .linkedWorktree(
                basename: "a", absolutePath: pathA, branch: .attached("x")
            )),
            settingsEnabled: true
        )
        let b = WorktreeChipProjector.project(
            ResolvedGitContext(outer: .linkedWorktree(
                basename: "b", absolutePath: pathB, branch: .attached("x")
            )),
            settingsEnabled: true
        )
        XCTAssertNotEqual(a[0].worktree?.dotColorHex, b[0].worktree?.dotColorHex)
    }

    func testColorHexIsFromKnownPalette() {
        let path = "/Users/atin/code/c11-worktrees/c11-104-sidebar-chips"
        let context = ResolvedGitContext(
            outer: .linkedWorktree(
                basename: "any",
                absolutePath: path,
                branch: .attached("x")
            )
        )
        let rows = WorktreeChipProjector.project(context, settingsEnabled: true)
        XCTAssertTrue(WorktreeColorPalette.entries.contains(rows[0].worktree?.dotColorHex ?? ""))
    }

    // MARK: - AC5: Detached renders short SHA

    func testDetachedRendersShortSHA() {
        let context = ResolvedGitContext(
            outer: .mainCheckout(branch: .detached(shortSHA: "abc1234"))
        )
        let rows = WorktreeChipProjector.project(context, settingsEnabled: true)
        XCTAssertEqual(rows[0].branch.label, "(detached @ abc1234)")
        XCTAssertTrue(rows[0].branch.isDetached)
        XCTAssertFalse(rows[0].branch.isDimmed)
    }

    // MARK: - AC6: Submodule produces two rows

    func testSubmoduleProducesTwoRows() {
        let context = ResolvedGitContext(
            outer: .mainCheckout(branch: .attached("main")),
            inner: GitSubmoduleContext(
                name: "ghostty",
                absolutePath: "/super/ghostty",
                branch: .attached("ghostty-main")
            )
        )
        let rows = WorktreeChipProjector.project(context, settingsEnabled: true)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].indent, .none)
        XCTAssertEqual(rows[1].indent, .submodule)
        XCTAssertEqual(rows[1].worktree?.label, "ghostty")
        XCTAssertTrue(rows[1].worktree?.isSubmodule ?? false)
    }

    // MARK: - AC9: `noBranch` (renamed from `.unknown` in C11-106) renders fallback

    func testNoBranchRendersNoBranchFallback() {
        let context = ResolvedGitContext(
            outer: .linkedWorktree(
                basename: "wt",
                absolutePath: "/p",
                branch: .noBranch
            )
        )
        let rows = WorktreeChipProjector.project(context, settingsEnabled: true)
        XCTAssertEqual(rows[0].branch.label, "(no branch)")
        XCTAssertFalse(rows[0].branch.isDimmed)
        XCTAssertFalse(rows[0].branch.isDetached)
    }

    // MARK: - AC10 + new states: `.notInRepo` / `.stale` suppress the chip row

    func testNotInRepoOuterProducesEmptyRows() {
        let context = ResolvedGitContext(outer: .notInRepo, inner: nil)
        XCTAssertEqual(WorktreeChipProjector.project(context, settingsEnabled: true), [])
    }

    func testStaleOuterProducesEmptyRows() {
        let context = ResolvedGitContext(outer: .stale, inner: nil)
        XCTAssertEqual(WorktreeChipProjector.project(context, settingsEnabled: true), [])
    }

    func testStaleOuterDropsAnyInnerSubmoduleSurrogate() {
        // Defensive: even if some future code path constructs a
        // ResolvedGitContext with a stale outer + a non-nil inner,
        // the projector must not surface the inner submodule row
        // alone — it would be visually meaningless without an outer.
        let context = ResolvedGitContext(
            outer: .stale,
            inner: GitSubmoduleContext(name: "ghostty", absolutePath: "/p/g", branch: .attached("g"))
        )
        XCTAssertEqual(WorktreeChipProjector.project(context, settingsEnabled: true), [])
    }

    // MARK: - AC7: Nil context produces empty array

    func testNilContextProducesEmpty() {
        XCTAssertEqual(WorktreeChipProjector.project(nil, settingsEnabled: true), [])
    }

    // MARK: - AC14: Settings off produces empty even with valid context

    func testSettingsDisabledProducesEmpty() {
        let context = ResolvedGitContext(outer: .mainCheckout(branch: .attached("main")))
        XCTAssertEqual(WorktreeChipProjector.project(context, settingsEnabled: false), [])
    }

    // MARK: - Dirty marker (AC25 — preserved from legacy UX)

    func testDirtyWorkingTreeAppendsStarToBranchChip() {
        let context = ResolvedGitContext(outer: .mainCheckout(branch: .attached("feature/x")))
        let rows = WorktreeChipProjector.project(context, settingsEnabled: true, isDirty: true)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].branch.label, "feature/x*")
    }

    func testCleanWorkingTreeDoesNotAppendStar() {
        let context = ResolvedGitContext(outer: .mainCheckout(branch: .attached("feature/x")))
        let rows = WorktreeChipProjector.project(context, settingsEnabled: true, isDirty: false)
        XCTAssertEqual(rows[0].branch.label, "feature/x")
    }

    func testDirtyDetachedHeadAppendsStarAfterClosingParen() {
        let context = ResolvedGitContext(
            outer: .mainCheckout(branch: .detached(shortSHA: "abc1234"))
        )
        let rows = WorktreeChipProjector.project(context, settingsEnabled: true, isDirty: true)
        XCTAssertEqual(rows[0].branch.label, "(detached @ abc1234)*")
    }

    func testSubmoduleInnerRowDoesNotInheritDirty() {
        let context = ResolvedGitContext(
            outer: .mainCheckout(branch: .attached("main")),
            inner: GitSubmoduleContext(
                name: "ghostty",
                absolutePath: "/super/ghostty",
                branch: .attached("ghostty-main")
            )
        )
        let rows = WorktreeChipProjector.project(context, settingsEnabled: true, isDirty: true)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].branch.label, "main*", "outer carries dirty marker")
        XCTAssertEqual(rows[1].branch.label, "ghostty-main", "inner row has no dirty marker")
    }

    // MARK: - Linked worktree carries dot prefix

    func testLinkedWorktreeCarriesColoredDot() {
        let context = ResolvedGitContext(
            outer: .linkedWorktree(
                basename: "c11-104-sidebar-chips",
                absolutePath: "/Users/atin/code/c11-worktrees/c11-104-sidebar-chips",
                branch: .attached("feat/x")
            )
        )
        let rows = WorktreeChipProjector.project(context, settingsEnabled: true)
        let wt = rows[0].worktree
        XCTAssertNotNil(wt)
        XCTAssertEqual(wt?.label, "c11-104-sidebar-chips")
        XCTAssertFalse(wt?.isSubmodule ?? true)
        XCTAssertFalse(wt?.dotColorHex.isEmpty ?? true)
    }
}
