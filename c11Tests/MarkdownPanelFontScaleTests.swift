import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class MarkdownPanelFontScaleTests: XCTestCase {
    private let lastUsedDefaultsKey = "markdown.fontScale.lastUsed"
    private var savedLastUsed: Any?

    override func setUp() async throws {
        savedLastUsed = UserDefaults.standard.object(forKey: lastUsedDefaultsKey)
        UserDefaults.standard.removeObject(forKey: lastUsedDefaultsKey)
    }

    override func tearDown() async throws {
        if let savedLastUsed {
            UserDefaults.standard.set(savedLastUsed, forKey: lastUsedDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastUsedDefaultsKey)
        }
    }

    // MARK: - Scale normalization

    func testNormalizedFontScaleClampsToRange() {
        XCTAssertEqual(MarkdownPanel.normalizedFontScale(0.1), MarkdownPanel.fontScaleRange.lowerBound)
        XCTAssertEqual(MarkdownPanel.normalizedFontScale(10.0), MarkdownPanel.fontScaleRange.upperBound)
        XCTAssertEqual(MarkdownPanel.normalizedFontScale(1.0), 1.0)
    }

    func testNormalizedFontScaleRoundsToOneStep() {
        // Repeated float additions like 1.0 + 0.1 + 0.1 drift; the normalizer
        // must land on exact tenths so equality short-circuits work.
        XCTAssertEqual(MarkdownPanel.normalizedFontScale(1.0 + 0.1 + 0.1), 1.2)
        XCTAssertEqual(MarkdownPanel.normalizedFontScale(0.9999999), 1.0)
    }

    // MARK: - Zoom stepping on a live panel

    func testZoomInOutAndResetStepTheScale() {
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }

        XCTAssertEqual(panel.fontScale, 1.0)
        panel.zoomIn()
        XCTAssertEqual(panel.fontScale, 1.1)
        panel.zoomIn()
        XCTAssertEqual(panel.fontScale, 1.2)
        panel.zoomOut()
        XCTAssertEqual(panel.fontScale, 1.1)
        panel.resetZoom()
        XCTAssertEqual(panel.fontScale, 1.0)
    }

    func testZoomOutClampsAtLowerBound() {
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }

        for _ in 0..<100 { panel.zoomOut() }
        XCTAssertEqual(panel.fontScale, MarkdownPanel.fontScaleRange.lowerBound)
        for _ in 0..<100 { panel.zoomIn() }
        XCTAssertEqual(panel.fontScale, MarkdownPanel.fontScaleRange.upperBound)
    }

    func testNewPanelsInheritLastUsedScale() {
        let first = MarkdownPanel(workspaceId: UUID())
        first.zoomIn()
        first.zoomIn()
        XCTAssertEqual(first.fontScale, 1.2)
        first.close()

        let second = MarkdownPanel(workspaceId: UUID())
        defer { second.close() }
        XCTAssertEqual(second.fontScale, 1.2)
    }

    func testApplyRestoredFontScaleDoesNotChangeLastUsedDefault() {
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }

        panel.applyRestoredFontScale(2.0)
        XCTAssertEqual(panel.fontScale, 2.0)

        let next = MarkdownPanel(workspaceId: UUID())
        defer { next.close() }
        XCTAssertEqual(next.fontScale, 1.0, "restore must not leak into the new-panel default")
    }

    func testRestoredInvalidScaleFallsBackRatherThanClamping() {
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }
        for value in [0.1, 10, Double.nan, Double.infinity] {
            panel.applyRestoredFontScale(value)
            XCTAssertEqual(panel.fontScale, 1.0)
        }
        XCTAssertNil(panel.renderer, "hidden model never creates a web view")
    }
}
