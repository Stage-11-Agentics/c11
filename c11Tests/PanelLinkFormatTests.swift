import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class PanelLinkFormatTests: XCTestCase {
    private let id = UUID(uuidString: "ABCDEFAB-1234-4567-89AB-ABCDEFABCDEF")!

    func testCanonicalURLsRoundTripThroughActivationParser() {
        let panel = PanelLinkFormat(kind: .panel, id: id, title: "Agent")
        let workspace = PanelLinkFormat(kind: .workspace, id: id, title: "Project")
        XCTAssertEqual(panel.url, "c11://panel/abcdefab-1234-4567-89ab-abcdefabcdef")
        XCTAssertEqual(workspace.url, "c11://workspace/abcdefab-1234-4567-89ab-abcdefabcdef")
        XCTAssertEqual(PanelLinkTarget(panel.url), .panel(id))
        XCTAssertEqual(PanelLinkTarget(workspace.url), .workspace(id))
    }

    func testMarkdownCannotEscapeItsLabelOrInterpretMarkup() {
        let link = PanelLinkFormat(kind: .panel, id: id, title: "![agent](bad) *bold* _italic_ `code` <b> &amp; \\ end")
        XCTAssertEqual(link.markdown, #"[\!\[agent\](bad) \*bold\* \_italic\_ \`code\` \<b\> \&amp; \\ end]("# + link.url + ")")
    }

    func testMarkdownKeepsOrdinaryTitlePunctuationReadable() {
        let link = PanelLinkFormat(kind: .panel, id: id, title: "C11-525 Review v1.2 (ready): 100%")
        XCTAssertEqual(link.markdown, "[C11-525 Review v1.2 (ready): 100%](\(link.url))")
    }

    func testOSC8LabelCannotInjectTerminalControls() {
        let link = PanelLinkFormat(kind: .panel, id: id, title: "a\u{1B}]8;;bad\u{07}\u{009C}\u{009B}31m\tb\n c\r\u{202E}d\u{2066}")
        XCTAssertEqual(link.title, "a]8;;bad31m b c d")
        XCTAssertEqual(link.osc8, "\u{1B}]8;;\(link.url)\u{1B}\\\(link.title)\u{1B}]8;;\u{1B}\\")
        XCTAssertEqual(link.osc8.unicodeScalars.filter { $0.value == 0x1B }.count, 4)
        XCTAssertFalse(link.title.unicodeScalars.contains { $0.properties.generalCategory == .control })
    }

    func testSanitizationPreservesUnicodeAndBoundsLabels() {
        XCTAssertEqual(PanelLinkFormat.sanitizedTitle("  東京\n\t👩‍💻  Україна  "), "東京 👩‍💻 Україна")
        let long = PanelLinkFormat(kind: .workspace, id: id, title: String(repeating: "界", count: 500))
        XCTAssertEqual(long.title.unicodeScalars.count, PanelLinkFormat.maximumTitleScalars)
        XCTAssertTrue(long.title.hasSuffix("…"))
        let empty = PanelLinkFormat(kind: .panel, id: id, title: "\n\u{1B}\u{07}\u{202E} ")
        XCTAssertEqual(empty.title, empty.url)
    }

    func testJSONEscapesOSC8UntilDecoded() throws {
        let link = PanelLinkFormat(kind: .panel, id: id, title: "Agent")
        let data = try JSONSerialization.data(withJSONObject: ["osc8": link.osc8])
        XCTAssertFalse(data.contains(0x1B))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(decoded["osc8"], link.osc8)
    }
}
