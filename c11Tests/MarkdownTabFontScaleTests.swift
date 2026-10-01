import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class MarkdownTabFontScaleTests: XCTestCase {
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
        XCTAssertEqual(MarkdownTab.normalizedFontScale(0.1), MarkdownTab.fontScaleRange.lowerBound)
        XCTAssertEqual(MarkdownTab.normalizedFontScale(10.0), MarkdownTab.fontScaleRange.upperBound)
        XCTAssertEqual(MarkdownTab.normalizedFontScale(1.0), 1.0)
    }

    func testNormalizedFontScaleRoundsToOneStep() {
        // Repeated float additions like 1.0 + 0.1 + 0.1 drift; the normalizer
        // must land on exact tenths so equality short-circuits work.
        XCTAssertEqual(MarkdownTab.normalizedFontScale(1.0 + 0.1 + 0.1), 1.2)
        XCTAssertEqual(MarkdownTab.normalizedFontScale(0.9999999), 1.0)
    }

    // MARK: - Zoom stepping on a live panel

    func testZoomInOutAndResetStepTheScale() {
        let panel = MarkdownTab(workspaceId: UUID())
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
        let panel = MarkdownTab(workspaceId: UUID())
        defer { panel.close() }

        for _ in 0..<100 { panel.zoomOut() }
        XCTAssertEqual(panel.fontScale, MarkdownTab.fontScaleRange.lowerBound)
        for _ in 0..<100 { panel.zoomIn() }
        XCTAssertEqual(panel.fontScale, MarkdownTab.fontScaleRange.upperBound)
    }

    func testNewTabsInheritLastUsedScale() {
        let first = MarkdownTab(workspaceId: UUID())
        first.zoomIn()
        first.zoomIn()
        XCTAssertEqual(first.fontScale, 1.2)
        first.close()

        let second = MarkdownTab(workspaceId: UUID())
        defer { second.close() }
        XCTAssertEqual(second.fontScale, 1.2)
    }

    func testApplyRestoredFontScaleDoesNotChangeLastUsedDefault() {
        let panel = MarkdownTab(workspaceId: UUID())
        defer { panel.close() }

        panel.applyRestoredFontScale(2.0)
        XCTAssertEqual(panel.fontScale, 2.0)

        let next = MarkdownTab(workspaceId: UUID())
        defer { next.close() }
        XCTAssertEqual(next.fontScale, 1.0, "restore must not leak into the new-panel default")
    }

    // MARK: - Segment identity

    func testSegmentIdChangesWhenContentBeyondPrefixChanges() {
        // Regression: the ID hashed only the first 64 chars, so a fenced
        // block edited past that prefix kept its ID and its stale rendered
        // image was preserved indefinitely.
        let prefix = String(repeating: "a", count: 64)
        let original = prefix + "graph TD; A-->B"
        let edited = prefix + "graph TD; A-->C"

        XCTAssertNotEqual(
            MarkdownTab.segmentId(index: 0, content: original),
            MarkdownTab.segmentId(index: 0, content: edited)
        )
    }

    func testSegmentIdStableForIdenticalContent() {
        let content = "## Heading\n\nsome body text"
        XCTAssertEqual(
            MarkdownTab.segmentId(index: 3, content: content),
            MarkdownTab.segmentId(index: 3, content: content)
        )
        XCTAssertNotEqual(
            MarkdownTab.segmentId(index: 3, content: content),
            MarkdownTab.segmentId(index: 4, content: content)
        )
    }
}
