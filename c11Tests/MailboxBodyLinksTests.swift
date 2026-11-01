import XCTest
import SwiftUI

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-524: which parts of a mail body the drawer turns into links, and that
/// everything else stays exactly the text that was sent.
final class MailboxBodyLinksTests: XCTestCase {
    private let panelID = "01234567-89AB-CDEF-0123-456789ABCDEF"

    private func links(_ text: String) -> [MailboxBodyLinks.Segment] {
        MailboxBodyLinks.segments(text).filter { $0.url != nil }
    }

    private func rendered(_ text: String) -> String {
        String(MailboxBodyLinks.attributed(text).characters)
    }

    func testTitledPanelLinkShowsItsTitle() throws {
        let body = "Review is in [Review Seat](c11://panel/\(panelID)), take a look."
        let found = links(body)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.text, "Review Seat")
        let url = try XCTUnwrap(found.first?.url)
        XCTAssertEqual(PanelLinkTarget(url.absoluteString), .panel(UUID(uuidString: panelID)!))
        XCTAssertEqual(rendered(body), "Review is in Review Seat, take a look.")
    }

    func testTitledWorkspaceLink() throws {
        let found = links("[Ops](c11://workspace/\(panelID.lowercased()))")
        let url = try XCTUnwrap(found.first?.url)
        XCTAssertEqual(found.first?.text, "Ops")
        XCTAssertEqual(PanelLinkTarget(url.absoluteString), .workspace(UUID(uuidString: panelID)!))
    }

    func testBareC11LinkIsClickableAndKeepsSurroundingPunctuation() throws {
        let body = "See (c11://panel/\(panelID))."
        let found = links(body)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.text, "c11://panel/\(panelID)")
        let url = try XCTUnwrap(found.first?.url)
        XCTAssertEqual(PanelLinkTarget(url.absoluteString), .panel(UUID(uuidString: panelID)!))
        XCTAssertEqual(rendered(body), body)

        for sentence in ["see c11://panel/\(panelID).", "see c11://panel/\(panelID)!", "(c11://panel/\(panelID))"] {
            XCTAssertEqual(links(sentence).map(\.text), ["c11://panel/\(panelID)"], sentence)
            XCTAssertEqual(rendered(sentence), sentence)
        }
    }

    func testHTTPSLinksTitledAndBare() {
        let found = links("[docs](https://example.com/a?b=1) and http://example.org/x, done")
        XCTAssertEqual(found.map(\.text), ["docs", "http://example.org/x"])
        XCTAssertEqual(found.map { $0.url?.absoluteString }, ["https://example.com/a?b=1", "http://example.org/x"])
    }

    func testOtherSchemesStayPlainText() {
        let body = """
        [open](file:///etc/passwd) [share](smb://host/share) \
        [prefs](x-apple.systempreferences:com.apple.preference.security) \
        [app](myapp://do/thing) file:///tmp/x smb://host/y mailto:a@b.c \
        [nohost](https://) [creds](https://user:pw@example.com/)
        """
        XCTAssertTrue(links(body).isEmpty, "\(links(body))")
        XCTAssertEqual(rendered(body), body)
    }

    func testMalformedC11LinkIsStillALinkThatTargetsNothing() throws {
        for body in ["[Seat](c11://panel/panel:10)", "c11://panel/not-a-uuid", "[Seat](c11://panel/\(panelID)?x=1)", "c11://"] {
            let found = links(body)
            XCTAssertEqual(found.count, 1, body)
            let url = try XCTUnwrap(found.first?.url, body)
            XCTAssertTrue(PanelLinkTarget.usesScheme(url), body)
            XCTAssertNil(PanelLinkTarget(url.absoluteString), body)
        }
        XCTAssertEqual(rendered("[Seat](c11://panel/panel:10)"), "Seat")
    }

    func testPlainTextAndWhitespaceRenderVerbatim() {
        let body = "**not bold** _not italic_ `not code`\n\n  indented\tTAB\n[not a link]\n[x](relative.md) xhttp://nope"
        XCTAssertTrue(links(body).isEmpty)
        XCTAssertEqual(rendered(body), body)
        XCTAssertEqual(MailboxBodyLinks.attributed(body).runs.count, 1)
    }

    func testLinkRunsCarryOnlyTheLink() throws {
        let attributed = MailboxBodyLinks.attributed("a [T](c11://panel/\(panelID)) b")
        let linkRuns = attributed.runs.filter { $0.link != nil }
        XCTAssertEqual(linkRuns.count, 1)
        let run = try XCTUnwrap(linkRuns.first)
        XCTAssertEqual(String(attributed[run.range].characters), "T")
        XCTAssertNil(run.inlinePresentationIntent)
    }

    func testMessageListingParsesBodyOnceAtLoad() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-body-links-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = MailboxPanelMail.inboxURL(mailboxesRoot: root, panelId: UUID())
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let envelope: [String: Any] = ["from": "lead", "body": "go to [Seat](c11://panel/\(panelID))"]
        let file = inbox.appendingPathComponent("01JABCDEFGHJKMNPQRSTVWXYZ0.\(MailboxLayout.envelopeExtension)")
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)
        let message = try XCTUnwrap(MailboxPanelMail.listing(inbox: inbox).messages.first)
        XCTAssertEqual(String(message.bodyRich.characters), "go to Seat")
        XCTAssertEqual(message.bodyRich.runs.filter { $0.link != nil }.count, 1)
        XCTAssertEqual(message.body, "go to [Seat](c11://panel/\(panelID))")
    }

    // MARK: - C11-562: an Insights preview never links a URL its cut split

    private func preview(_ body: String) -> MailboxPanelMail.Header {
        MailboxPanelMail.Header(raw: ["from": "lead", "body": body])
    }

    private func linkTexts(_ attributed: AttributedString) -> [String] {
        attributed.runs.filter { $0.link != nil }.map { String(attributed[$0.range].characters) }
    }

    func testPreviewLeavesABareURLTheCutSplitAsPlainText() throws {
        let url = "https://example.com/a/very/long/path"
        let body = String(repeating: "x", count: 125) + " " + url + " tail"
        let header = preview(body)
        XCTAssertEqual(header.preview.count, MailboxPanelMail.Header.previewLimit)
        XCTAssertEqual(String(header.previewRich.characters), header.preview)
        XCTAssertEqual(linkTexts(header.previewRich), [])
        let full = MailboxBodyLinks.attributed(body)
        XCTAssertEqual(full.runs.compactMap { $0.link?.absoluteString }, [url])
    }

    func testPreviewLeavesATitledLinkTheCutSplitAsPlainText() {
        let filler = String(repeating: "x", count: 120) + " "
        let body = filler + "[Seat](c11://panel/\(panelID)) after"
        let header = preview(body)
        XCTAssertEqual(header.preview, filler + "[Seat](c11://panel/")
        XCTAssertEqual(String(header.previewRich.characters), header.preview)
        XCTAssertEqual(linkTexts(header.previewRich), [])
    }

    func testPreviewLeavesASplitPanelLinkPlain() {
        let body = String(repeating: "x", count: 120) + " c11://panel/\(panelID)"
        let header = preview(body)
        XCTAssertEqual(linkTexts(header.previewRich), [])
        XCTAssertEqual(String(header.previewRich.characters), header.preview)
    }

    func testPreviewKeepsLinksThatEndInsideTheCut() {
        let url = "https://example.com/x"
        let exact = String(repeating: "x", count: MailboxPanelMail.Header.previewLimit - url.count - 1) + " " + url
        XCTAssertEqual(exact.count, MailboxPanelMail.Header.previewLimit)
        let atCut = preview(exact + ". and then a lot more words after the cut")
        XCTAssertEqual(linkTexts(atCut.previewRich), [url])
        let early = preview("see [docs](\(url)) and \(url), then " + String(repeating: "y", count: 200))
        XCTAssertEqual(linkTexts(early.previewRich), ["docs", url])
        XCTAssertEqual(String(early.previewRich.characters).count,
                       MailboxPanelMail.Header.previewLimit - "[docs](\(url))".count + "docs".count)
    }
}
