import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Unit tests for `sanitizeDescriptionMarkdown(_:)` — the render-time subset
/// gate that removes images, fenced code blocks, and table rows before feeding
/// the string to the native description renderer. Pure functions, no view mounting required.
final class DescriptionSanitizerTests: XCTestCase {

    private enum NativeBlock: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case listItem(marker: String, text: String, depth: Int)
        case quote(String)
        case rule
    }

    private func nativeBlocks(_ blocks: [TitleBarDescriptionBlock]) -> [NativeBlock] {
        blocks.map { block in
            switch block {
            case .paragraph(let text):
                return .paragraph(String(text.characters))
            case .heading(let level, let text):
                return .heading(level: level, text: String(text.characters))
            case .listItem(let marker, let text, let depth):
                return .listItem(marker: marker, text: String(text.characters), depth: depth)
            case .quote(let text):
                return .quote(String(text.characters))
            case .rule:
                return .rule
            }
        }
    }

    func testStripsImageSyntax() {
        let input = "![alt](x.png) hello"
        let output = sanitizeDescriptionMarkdown(input)
        XCTAssertEqual(output, " hello")
    }

    func testStripsFencedCodeBlock() {
        let input = "line\n```swift\ncode\n```\nafter"
        let output = sanitizeDescriptionMarkdown(input)
        // The sanitizer removes both fence lines AND the content between them
        // (see Sources/PanelTitleBarView.swift), then joins the remaining
        // lines with a single newline.
        XCTAssertEqual(output, "line\nafter")
    }

    func testStripsTableRows() {
        let input = "| a | b |\n|---|---|\n| 1 | 2 |"
        let output = sanitizeDescriptionMarkdown(input)
        XCTAssertEqual(output, "")
    }

    func testPreservesInlineBoldAndItalic() {
        let input = "**bold** and *italic*"
        XCTAssertEqual(sanitizeDescriptionMarkdown(input), input)
    }

    func testPreservesLists() {
        let input = "- list item\n- another"
        XCTAssertEqual(sanitizeDescriptionMarkdown(input), input)
    }

    func testPreservesLinks() {
        let input = "[link text](https://example.com)"
        XCTAssertEqual(sanitizeDescriptionMarkdown(input), input)
    }

    func testPreservesInlineCodeAndHeadings() {
        let input = "# Heading\n\nUses `inline code` inside text."
        XCTAssertEqual(sanitizeDescriptionMarkdown(input), input)
    }

    func testStripsMultipleImagesOnOneLine() {
        let input = "start ![a](1.png) mid ![b](2.png) end"
        XCTAssertEqual(sanitizeDescriptionMarkdown(input), "start  mid  end")
    }

    func testNativeDescriptionBlocksPreserveHeadingsListsQuotesAndRules() {
        let input = "# Main\n## Sub\n### Detail\n- **one**\n  + nested\n2. two\n> quote\n> continued\n\n---\nplain\ncontinuation"
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks(input)), [
            .heading(level: 1, text: "Main"),
            .heading(level: 2, text: "Sub"),
            .heading(level: 3, text: "Detail"),
            .listItem(marker: "•", text: "one", depth: 0),
            .listItem(marker: "•", text: "nested", depth: 1),
            .listItem(marker: "2.", text: "two", depth: 0),
            .quote("quote continued"),
            .rule,
            .paragraph("plain continuation")
        ])
    }

    func testNativeBlockParserKeepsOrdinaryHashAndMinusTextAsParagraphs() {
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("#tag\n-plain\n* emphasis *")), [
            .paragraph("#tag -plain"),
            .listItem(marker: "•", text: "emphasis *", depth: 0)
        ])
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("* * *\n_ _ _\n---")), [.rule, .rule, .rule])
    }

    func testNativeInlineRendererKeepsEmphasisAndCodeButRemovesLinkNavigation() {
        let rendered = titleBarDescriptionInline("**bold** *italic* `code` [label](https://example.com)")
        XCTAssertEqual(String(rendered.characters), "bold italic code label")
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(rendered.runs.allSatisfy { $0.link == nil })
    }

    func testSanitizedDescriptionFeedsOnlySupportedNativeBlocks() {
        let input = "# Heading\n![image](https://example.com/a.png)\n```swift\nsecret block\n```\n| a | b |\nAfter `code`."
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks(sanitizeDescriptionMarkdown(input))), [
            .heading(level: 1, text: "Heading"),
            .paragraph("After code.")
        ])
    }

    func testReviewSetextHeadingKeepsHeadingSemantics() {
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("Status\n======")), [
            .heading(level: 1, text: "Status")
        ])
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("Status\n------")), [
            .heading(level: 2, text: "Status")
        ])
    }

    func testReviewClosingATXHashesAreNotRenderedAsText() {
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("## Status ##")), [
            .heading(level: 2, text: "Status")
        ])
    }

    func testReviewWrappedListContinuationStaysInItem() {
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("- Deploy the change\n  after CI passes")), [
            .listItem(marker: "•", text: "Deploy the change after CI passes", depth: 0)
        ])
    }

    func testReviewRepeatedOrderedMarkersRenderSequentially() {
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("1. First\n1. Second")), [
            .listItem(marker: "1.", text: "First", depth: 0),
            .listItem(marker: "2.", text: "Second", depth: 0)
        ])
    }

    func testReviewReferenceLinkAcrossBlocksKeepsLabelAndRemovesNavigation() {
        let blocks = titleBarDescriptionBlocks("See [plan][p].\n\n[p]: https://example.invalid/plan")
        XCTAssertEqual(nativeBlocks(blocks), [.paragraph("See plan.")])
        guard case .paragraph(let text) = blocks[0] else { return XCTFail("Missing paragraph") }
        XCTAssertTrue(text.runs.allSatisfy { $0.link == nil })
    }

    func testReviewHardLineBreakStaysVisible() {
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("First line  \nSecond line")), [
            .paragraph("First line\nSecond line")
        ])
    }

    func testFullMarkdownParseRetainsInlineStylesAndInertLinkText() {
        let blocks = titleBarDescriptionBlocks("**bold** *italic* `code` [label](https://example.com)")
        guard case .paragraph(let text) = blocks.first else { return XCTFail("Missing paragraph") }

        XCTAssertEqual(String(text.characters), "bold italic code label")
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(text.runs.allSatisfy { $0.link == nil })
    }

    func testOrderedListStartingNumberIsPreserved() {
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("3. a\n4. b")), [
            .listItem(marker: "3.", text: "a", depth: 0),
            .listItem(marker: "4.", text: "b", depth: 0)
        ])
    }

    func testThematicRuleBetweenParagraphsRemainsItsOwnBlock() {
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("before\n\n---\n\nafter")), [
            .paragraph("before"),
            .rule,
            .paragraph("after")
        ])
    }

    func testQuoteSoftAndHardBreaksKeepMarkdownLineBreakSemantics() {
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("> first\n> second")), [
            .quote("first second")
        ])
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("> first  \n> second")), [
            .quote("first\nsecond")
        ])
    }

    func testIndentedCodeBlockIsPreservedAsMonospacedNativeParagraph() {
        let blocks = titleBarDescriptionBlocks("    let answer = 42")
        XCTAssertEqual(nativeBlocks(blocks), [.paragraph("let answer = 42")])
        guard case .paragraph(let text) = blocks[0] else { return XCTFail("Missing code block") }
        XCTAssertTrue(text.runs.contains { run in
            run.presentationIntent?.components.contains(where: {
                if case .codeBlock = $0.kind { return true }
                return false
            }) == true && run.font == .system(size: 11, design: .monospaced)
        })
    }

    func testOrderedMarkerTwoDoesNotInterruptAnOrdinaryParagraph() {
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("Step\n2. two")), [
            .paragraph("Step 2. two")
        ])
    }
}


// SYNTH PROBE: nested list markers must come from the innermost item and its list.
extension DescriptionSanitizerTests {
    private func synthMarkers(_ input: String) -> [String] {
        titleBarDescriptionBlocks(input).compactMap { block in
            if case .listItem(let marker, let text, let depth) = block { return "\(depth):\(marker) \(String(text.characters))" }
            return nil
        }
    }
    func testSynthNestedOrderedListNumbersItsOwnItems() {
        XCTAssertEqual(synthMarkers("1. Plan\n   1. read\n   2. write\n2. Ship"), ["0:1. Plan", "1:1. read", "1:2. write", "0:2. Ship"])
    }
    func testSynthOrderedListNestedUnderBulletKeepsNumbers() {
        XCTAssertEqual(synthMarkers("- a\n  1. x\n  2. y"), ["0:• a", "1:1. x", "1:2. y"])
    }
    func testSynthBulletsNestedUnderOrderedItemStayBullets() {
        XCTAssertEqual(synthMarkers("1. a\n   - x\n   - y\n2. b"), ["0:1. a", "1:• x", "1:• y", "0:2. b"])
    }
    func testSynthLooseItemSecondParagraphStaysInItem() {
        XCTAssertEqual(synthMarkers("- item one\n\n  second para\n- item two").count, 2)
    }
    func testSynthLooseItemParagraphsJoinWithOneLineBreak() {
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("- item one\n\n  second para\n- item two")), [
            .listItem(marker: "•", text: "item one\nsecond para", depth: 0),
            .listItem(marker: "•", text: "item two", depth: 0)
        ])
    }
    func testSynthMultiParagraphQuoteStaysInOneNativeBlock() {
        XCTAssertEqual(nativeBlocks(titleBarDescriptionBlocks("> first\n>\n> second")), [
            .quote("first\nsecond")
        ])
    }
}
