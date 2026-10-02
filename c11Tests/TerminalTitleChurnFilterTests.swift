import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class TerminalTitleChurnFilterTests: XCTestCase {
    func testKnownStandaloneFramesNeverClearAnExistingTitle() {
        let frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⣷⣯⣟⡿⢿⣻⣽⣾✱✲✳✴✵✶✷✸✹✺✻✼✽✢·◐◓◑◒◴◵◶◷"
        for frame in frames {
            XCTAssertFalse(TerminalTitleChurnFilter.shouldPublish(previous: "claude", next: " \(frame) "), "\(frame)")
            XCTAssertFalse(TerminalTitleChurnFilter.shouldPublish(previous: nil, next: String(frame)), "\(frame)")
        }
    }

    func testSpinnerTokensAroundUnchangedWordsDoNotPublish() {
        for next in ["claude ◐", "◓ claude", "π ⠋ label", "π label ⠙"] {
            let previous = next.contains("π") ? "π label" : "claude"
            XCTAssertFalse(TerminalTitleChurnFilter.shouldPublish(previous: previous, next: next))
        }
    }

    func testBothRealTitleChangesAreAdmitted() {
        var filter = TerminalTitleChurnFilter()
        XCTAssertTrue(filter.admit("npm test"))
        XCTAssertTrue(filter.admit("git status"))
        XCTAssertEqual(filter.lastPublishedTitle, "git status")
    }

    func testNewLabelWithSpinnerPublishesRawTitleOnce() {
        var filter = TerminalTitleChurnFilter()
        XCTAssertTrue(filter.admit("zsh"))
        XCTAssertTrue(filter.admit("claude ◐"))
        XCTAssertEqual(filter.lastPublishedTitle, "claude ◐")
        XCTAssertFalse(filter.admit("claude ◓"))
        XCTAssertFalse(filter.admit("claude"))
    }

    func testEmptyTitleClearsOnceWithoutInventingAFallback() {
        var filter = TerminalTitleChurnFilter()
        XCTAssertFalse(filter.admit(""))
        XCTAssertTrue(filter.admit("npm test"))
        XCTAssertTrue(filter.admit(" \n "))
        XCTAssertEqual(filter.lastPublishedTitle, " \n ")
        XCTAssertFalse(filter.admit(""))
        XCTAssertFalse(filter.admit("⠋"))
        XCTAssertTrue(filter.admit("git status"))
    }

    func testRapidReturnToPreviousLabelUsesAdmittedStreamNotDownstreamState() {
        var filter = TerminalTitleChurnFilter()
        // All events arrive before a metadata coalescer has a chance to flush.
        let admitted = ["claude", "npm test", "claude ◐", "claude ◓"].filter { filter.admit($0) }
        XCTAssertEqual(admitted, ["claude", "npm test", "claude ◐"])
    }

    func testIndependentTerminalStreamsKeepIndependentBaselines() {
        var first = TerminalTitleChurnFilter()
        var second = TerminalTitleChurnFilter()
        XCTAssertTrue(first.admit("claude"))
        XCTAssertTrue(second.admit("npm test"))
        XCTAssertFalse(first.admit("claude ◐"))
        XCTAssertTrue(second.admit("claude ◐"))
    }

    func testEmbeddedAndUnrecognizedGlyphsRemainMeaningfulText() {
        var filter = TerminalTitleChurnFilter()
        for title in ["A·B", "AB", "block █ chart", "⠑", "|", "/", "-", "\\"] {
            XCTAssertTrue(filter.admit(title), title)
        }
        XCTAssertTrue(TerminalTitleChurnFilter.shouldPublish(previous: "AB", next: "A◐B"))
    }

    func testAdjacentGlyphRunsArePreservedAsTextOrArt() {
        XCTAssertTrue(TerminalTitleChurnFilter.shouldPublish(previous: "claude", next: "⠋⠙"))
        XCTAssertTrue(TerminalTitleChurnFilter.shouldPublish(previous: "hello", next: "⠋ ⠑⠇⠇⠕"))
        XCTAssertTrue(TerminalTitleChurnFilter.shouldPublish(previous: "claude", next: "◐◓ claude"))
    }

    func testWhitespaceAndDuplicateRealTitlesDoNotWakeObservers() {
        var filter = TerminalTitleChurnFilter()
        XCTAssertTrue(filter.admit("npm test"))
        XCTAssertFalse(filter.admit(" \tnpm test\n"))
        XCTAssertFalse(filter.admit("npm test"))
    }

    func testFortyTerminalSpinnerReplayAdmitsOnlyMeaningfulTransitions() {
        var filters = Array(repeating: TerminalTitleChurnFilter(), count: 40)
        var admitted = 0
        for index in filters.indices {
            if filters[index].admit("claude") { admitted += 1 }
            for _ in 0..<20 {
                for title in ["◐", "claude ◓", "⠋", "◑ claude"] {
                    if filters[index].admit(title) { admitted += 1 }
                }
            }
            if filters[index].admit("npm test") { admitted += 1 }
        }
        XCTAssertEqual(admitted, 80)
    }
}
