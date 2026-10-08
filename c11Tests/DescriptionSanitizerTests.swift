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

    func testStripsImageSyntax() {
        let input = "![alt](x.png) hello"
        let output = sanitizeDescriptionMarkdown(input)
        XCTAssertEqual(output, " hello")
    }

    func testStripsFencedCodeBlock() {
        let input = "line\n```swift\ncode\n```\nafter"
        let output = sanitizeDescriptionMarkdown(input)
        // The sanitizer removes both fence lines AND the content between them
        // (see Sources/SurfaceTitleBarView.swift:246-254), then joins the
        // remaining lines with single newlines — so "line" and "after" end up
        // separated by one newline, not two. The earlier expectation predated
        // the current join-then-collapse implementation.
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
        XCTAssertEqual(titleBarDescriptionBlocks(input), [
            .heading(level: 1, text: "Main"),
            .heading(level: 2, text: "Sub"),
            .heading(level: 3, text: "Detail"),
            .listItem(marker: "•", text: "**one**", depth: 0),
            .listItem(marker: "•", text: "nested", depth: 1),
            .listItem(marker: "2.", text: "two", depth: 0),
            .quote("quote\ncontinued"),
            .rule,
            .paragraph("plain continuation")
        ])
    }

    func testNativeBlockParserKeepsOrdinaryHashAndMinusTextAsParagraphs() {
        XCTAssertEqual(titleBarDescriptionBlocks("#tag\n-plain\n* emphasis *"), [
            .paragraph("#tag -plain"),
            .listItem(marker: "•", text: "emphasis *", depth: 0)
        ])
        XCTAssertEqual(titleBarDescriptionBlocks("* * *\n_ _ _\n---"), [.rule, .rule, .rule])
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
        XCTAssertEqual(titleBarDescriptionBlocks(sanitizeDescriptionMarkdown(input)), [
            .heading(level: 1, text: "Heading"),
            .paragraph("After `code`.")
        ])
    }
}
