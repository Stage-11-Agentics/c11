import XCTest
import AppKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// CMUX-10: hex parser feeding both `c11 trigger-flash --color` and the
/// socket re-validation path. Ensures the same shapes the CLI's local
/// `isValidFlashColorHex` accepts also produce a usable NSColor server-side.
final class FlashColorParsingTests: XCTestCase {
    func testParsesSixDigitHexWithLeadingHash() throws {
        let color = try XCTUnwrap(FlashAppearance.parseHex("#F5C518"))
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        XCTAssertEqual(srgb.redComponent, 0xF5 / 255.0, accuracy: 0.001)
        XCTAssertEqual(srgb.greenComponent, 0xC5 / 255.0, accuracy: 0.001)
        XCTAssertEqual(srgb.blueComponent, 0x18 / 255.0, accuracy: 0.001)
        XCTAssertEqual(srgb.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testParsesSixDigitHexWithoutLeadingHash() throws {
        let color = try XCTUnwrap(FlashAppearance.parseHex("F5C518"))
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        XCTAssertEqual(srgb.redComponent, 0xF5 / 255.0, accuracy: 0.001)
    }

    func testParsesEightDigitHexWithAlpha() throws {
        let color = try XCTUnwrap(FlashAppearance.parseHex("#F5C51880"))
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        XCTAssertEqual(srgb.redComponent, 0xF5 / 255.0, accuracy: 0.001)
        XCTAssertEqual(srgb.alphaComponent, 0x80 / 255.0, accuracy: 0.001)
    }

    func testIsCaseInsensitive() throws {
        let lower = try XCTUnwrap(FlashAppearance.parseHex("#f5c518"))
        let upper = try XCTUnwrap(FlashAppearance.parseHex("#F5C518"))
        XCTAssertEqual(
            lower.usingColorSpace(.sRGB)?.redComponent,
            upper.usingColorSpace(.sRGB)?.redComponent
        )
    }

    func testRejectsThreeDigitShorthand() {
        XCTAssertNil(FlashAppearance.parseHex("#F5C"))
        XCTAssertNil(FlashAppearance.parseHex("FFF"))
    }

    func testRejectsNonHexCharacters() {
        XCTAssertNil(FlashAppearance.parseHex("#GGGGGG"))
        XCTAssertNil(FlashAppearance.parseHex("#12345Z"))
    }

    func testRejectsEmptyAndWhitespaceOnly() {
        XCTAssertNil(FlashAppearance.parseHex(""))
        XCTAssertNil(FlashAppearance.parseHex("   "))
    }

    func testRejectsWrongLength() {
        XCTAssertNil(FlashAppearance.parseHex("#F5C5"))
        XCTAssertNil(FlashAppearance.parseHex("#F5C5180000"))
    }

    func testTrimsLeadingAndTrailingWhitespace() throws {
        let color = try XCTUnwrap(FlashAppearance.parseHex("  #F5C518\n"))
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        XCTAssertEqual(srgb.redComponent, 0xF5 / 255.0, accuracy: 0.001)
    }

    func testDefaultColorMatchesCmux10Yellow() throws {
        let srgb = try XCTUnwrap(FlashAppearance.defaultColor.usingColorSpace(.sRGB))
        XCTAssertEqual(srgb.redComponent, 0xF5 / 255.0, accuracy: 0.001)
        XCTAssertEqual(srgb.greenComponent, 0xC5 / 255.0, accuracy: 0.001)
        XCTAssertEqual(srgb.blueComponent, 0x18 / 255.0, accuracy: 0.001)
        XCTAssertEqual(srgb.alphaComponent, 1.0, accuracy: 0.001)
    }
}
