import AppKit
import XCTest
@testable import c11

final class ThemeResolvedSnapshotArtifactTests: XCTestCase {
    func testStage11ResolvedSnapshotMatchesGoldenArtifact() throws {
        let snapshot = ResolvedThemeSnapshot(theme: .fallbackStage11)
        let context = ThemeContext(
            workspaceColor: "#C0392B",
            colorScheme: .dark,
            forceBright: false,
            ghosttyBackgroundGeneration: 0,
            isWindowFocused: true,
            workspaceState: nil
        )

        var resolved: [String: String] = [:]
        for role in artifactRoles {
            let path = role.definition.path
            switch role.definition.expectedType {
            case .color:
                if let color = snapshot.resolveColor(role: role, context: context) {
                    resolved[path] = color.hexString(includeAlpha: color.alphaComponent < 0.999)
                }
            case .number:
                if let number = snapshot.resolveNumber(role: role, context: context) {
                    resolved[path] = String(format: "%.6f", number)
                }
            case .boolean:
                if let flag = snapshot.resolveBoolean(role: role, context: context) {
                    resolved[path] = flag ? "true" : "false"
                }
            }
        }

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("golden")
            .appendingPathComponent("stage11-resolved-snapshot.json")
        let expectedData = try Data(contentsOf: fixtureURL)
        let expected = try XCTUnwrap(
            JSONSerialization.jsonObject(with: expectedData, options: []) as? [String: String]
        )

        XCTAssertEqual(resolved, expected)
    }

    private var artifactRoles: [ThemeRole] {
        [
            .windowFrame_color,
            .windowFrame_thicknessPt,
            .windowFrame_inactiveOpacity,
            .windowFrame_unfocusedOpacity,
            .sidebar_tintBase,
            .sidebar_tintBaseOpacity,
            .sidebar_tintOverlay,
            .sidebar_activeTabFill,
            .sidebar_activeTabFillFallback,
            .sidebar_activeTabRail,
            .sidebar_activeTabRailFallback,
            .sidebar_activeTabRailOpacity,
            .sidebar_inactiveTabCustomOpacity,
            .sidebar_inactiveTabMultiSelectOpacity,
            .sidebar_badgeFill,
            .sidebar_borderLeading,
            .dividers_color,
            .dividers_thicknessPt,
            .titleBar_background,
            .titleBar_backgroundOpacity,
            .titleBar_foreground,
            .titleBar_foregroundSecondary,
            .titleBar_borderBottom,
            .markdownChrome_background,
            .behavior_animateWorkspaceCrossfade,
        ]
    }
}
