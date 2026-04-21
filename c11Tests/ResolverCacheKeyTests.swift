import AppKit
import XCTest
@testable import cmux

final class ResolverCacheKeyTests: XCTestCase {
    func testFullThemeContextParticipatesInColorCacheKey() {
        let snapshot = ResolvedThemeSnapshot(theme: .fallbackStage11)

        let baseline = ThemeContext(
            workspaceColor: "#C0392B",
            colorScheme: .dark,
            forceBright: false,
            ghosttyBackgroundGeneration: 7,
            isWindowFocused: true,
            workspaceState: WorkspaceState(environment: "dev", risk: "low", mode: "edit", tags: ["owner": "stage11"])
        )

        let baseColor = try XCTUnwrap(snapshot.resolveColor(role: .windowFrame_color, context: baseline))
        let baseAgain = try XCTUnwrap(snapshot.resolveColor(role: .windowFrame_color, context: baseline))
        XCTAssertTrue(baseColor === baseAgain)

        let variants = contextsDifferingByOneField(from: baseline)
        for variant in variants {
            let variantColor = try XCTUnwrap(snapshot.resolveColor(role: .windowFrame_color, context: variant))
            let variantAgain = try XCTUnwrap(snapshot.resolveColor(role: .windowFrame_color, context: variant))

            XCTAssertTrue(variantColor === variantAgain)
            XCTAssertFalse(baseColor === variantColor)
        }
    }

    private func contextsDifferingByOneField(from base: ThemeContext) -> [ThemeContext] {
        var output: [ThemeContext] = []

        var workspaceColorChanged = base
        workspaceColorChanged.workspaceColor = "#1565C0"
        output.append(workspaceColorChanged)

        var colorSchemeChanged = base
        colorSchemeChanged.colorScheme = .light
        output.append(colorSchemeChanged)

        var forceBrightChanged = base
        forceBrightChanged.forceBright = true
        output.append(forceBrightChanged)

        var generationChanged = base
        generationChanged.ghosttyBackgroundGeneration = base.ghosttyBackgroundGeneration + 1
        output.append(generationChanged)

        var focusChanged = base
        focusChanged.isWindowFocused = false
        output.append(focusChanged)

        var workspaceStateChanged = base
        workspaceStateChanged.workspaceState = WorkspaceState(environment: "prod", risk: "high", mode: "review", tags: ["owner": "stage11"])
        output.append(workspaceStateChanged)

        return output
    }
}
