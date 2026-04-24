import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Unit tests for `sanitizeDescriptionMarkdown(_:)` — the render-time subset
/// gate that removes images, fenced code blocks, and table rows before feeding
/// the string to MarkdownUI. Pure function, no view mounting required.
final class DescriptionSanitizerTests: XCTestCase {

    func testStripsImageSyntax() {
        let input = "![alt](x.png) hello"
        let output = sanitizeDescriptionMarkdown(input)
        XCTAssertEqual(output, " hello")
    }

    func testStripsFencedCodeBlock() {
        let input = "line\n```swift\ncode\n```\nafter"
        let output = sanitizeDescriptionMarkdown(input)
        XCTAssertEqual(output, "line\n\nafter")
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
}
