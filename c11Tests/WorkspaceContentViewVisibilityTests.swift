import AppKit
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class WorkspaceContentViewVisibilityTests: XCTestCase {
    func testBackgroundPrimedWorkspaceStaysMountedButNotPanelVisible() {
        XCTAssertEqual(
            MountedWorkspacePresentationPolicy.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: false,
                shouldPrimeInBackground: true
            ),
            MountedWorkspacePresentation(
                isRenderedVisible: false,
                isPanelVisible: false,
                renderOpacity: 0.001
            )
        )
    }

    func testRetiringWorkspaceStaysPanelVisibleDuringHandoff() {
        XCTAssertEqual(
            MountedWorkspacePresentationPolicy.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: true,
                shouldPrimeInBackground: false
            ),
            MountedWorkspacePresentation(
                isRenderedVisible: true,
                isPanelVisible: true,
                renderOpacity: 1
            )
        )
    }

    func testPanelVisibleInUIReturnsFalseWhenWorkspaceHidden() {
        XCTAssertFalse(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: false,
                isSelectedInPane: true,
                isFocused: true
            )
        )
    }

    func testPanelVisibleInUIReturnsTrueForSelectedPanel() {
        XCTAssertTrue(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: true,
                isFocused: false
            )
        )
    }

    func testPanelVisibleInUIReturnsTrueForFocusedPanelDuringTransientSelectionGap() {
        XCTAssertTrue(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: false,
                isFocused: true
            )
        )
    }

    func testPanelVisibleInUIReturnsFalseWhenNeitherSelectedNorFocused() {
        XCTAssertFalse(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: false,
                isFocused: false
            )
        )
    }
}

/// C11-578: the workspace frame rounds a corner only where it sits on one of
/// the window's rounded corners. Window coordinates are AppKit (y up).
final class WorkspaceFrameCornerPolicyTests: XCTestCase {
    private let window = NSRect(x: 0, y: 0, width: 1200, height: 800)

    func testSidebarAndTitlebarLeaveOnlyTheBottomTrailingCornerRounded() {
        // Sidebar on the left (240pt), titlebar above (28pt): the frame's
        // top-left meets the square tab strip, not a window corner.
        let corners = WorkspaceFrameCorners.resolve(
            frame: NSRect(x: 240, y: 0, width: 960, height: 772),
            windowBounds: window,
            windowRadius: 16
        )
        XCTAssertFalse(corners.topLeading, "Top-left beside the sidebar must be square")
        XCTAssertFalse(corners.topTrailing, "Top-right under the titlebar must be square")
        XCTAssertFalse(corners.bottomLeading, "Bottom-left beside the sidebar must be square")
        XCTAssertTrue(corners.bottomTrailing, "Bottom-right sits on the window corner")
        XCTAssertEqual(corners.topLeadingRadius, 0)
        XCTAssertEqual(corners.bottomTrailingRadius, 16)
    }

    func testContentFillingTheWindowRoundsEveryCorner() {
        let corners = WorkspaceFrameCorners.resolve(frame: window, windowBounds: window, windowRadius: 16)
        XCTAssertEqual(
            corners,
            WorkspaceFrameCorners(radius: 16, topLeading: true, topTrailing: true, bottomLeading: true, bottomTrailing: true)
        )
    }

    func testMinimalModeWithSidebarRoundsOnlyTheTrailingCorners() {
        let corners = WorkspaceFrameCorners.resolve(
            frame: NSRect(x: 240, y: 0, width: 960, height: 800),
            windowBounds: window,
            windowRadius: 16
        )
        XCTAssertEqual(
            corners,
            WorkspaceFrameCorners(radius: 16, topLeading: false, topTrailing: true, bottomLeading: false, bottomTrailing: true)
        )
    }

    func testHiddenSidebarUnderTheTitlebarRoundsBothBottomCorners() {
        let corners = WorkspaceFrameCorners.resolve(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 772),
            windowBounds: window,
            windowRadius: 16
        )
        XCTAssertEqual(
            corners,
            WorkspaceFrameCorners(radius: 16, topLeading: false, topTrailing: false, bottomLeading: true, bottomTrailing: true)
        )
    }

    func testPreMacOS26RadiusIsCarriedOnlyOnWindowCorners() {
        let corners = WorkspaceFrameCorners.resolve(
            frame: NSRect(x: 240, y: 0, width: 960, height: 772),
            windowBounds: window,
            windowRadius: 10
        )
        XCTAssertEqual(corners.bottomTrailingRadius, 10)
        XCTAssertEqual(corners.topLeadingRadius, 0)
    }

    func testFractionalLayoutStillMatchesTheWindowCorner() {
        let corners = WorkspaceFrameCorners.resolve(
            frame: NSRect(x: 240.5, y: 0.5, width: 959.0, height: 771.0),
            windowBounds: window,
            windowRadius: 16
        )
        XCTAssertTrue(corners.bottomTrailing)
        XCTAssertFalse(corners.topLeading)
    }

    func testSquareWindowCornersOrDetachedFrameStaySquare() {
        XCTAssertEqual(
            WorkspaceFrameCorners.resolve(frame: window, windowBounds: window, windowRadius: 0),
            .square,
            "Full screen has square window corners"
        )
        XCTAssertEqual(
            WorkspaceFrameCorners.resolve(
                frame: NSRect(x: 240, y: 20, width: 900, height: 700),
                windowBounds: window,
                windowRadius: 16
            ),
            .square,
            "A frame touching no window corner has no rounded corner"
        )
    }
}
