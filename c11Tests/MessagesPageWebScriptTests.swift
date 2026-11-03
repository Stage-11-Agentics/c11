import XCTest
import WebKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Runs the rendered messages page's conversation-web script in a real
/// WKWebView, so a script error that blanks the Web view fails a test rather
/// than an operator's page. The page's own CSP stays in force.
@MainActor
final class MessagesPageWebScriptTests: XCTestCase {
    private var directory: URL!
    private var webView: WKWebView?

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-messages-web-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        webView = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Fixtures

    private let alpha = UUID(), bravo = UUID(), charlie = UUID()

    private func record(
        id: String,
        channel: String = "mailbox",
        sender: String?,
        senderID: String? = nil,
        surface: UUID?,
        recipient: String? = "role",
        recipients: [UUID] = [],
        body: String = "hello"
    ) -> MessagesPageRecord {
        var result = MessagesPageRecord(
            id: id, channel: channel, timestamp: "2026-10-02T00:00:0\(id.count % 10).000Z", sequence: nil,
            workspace: nil, surface: surface?.uuidString, sender: sender, senderID: senderID,
            callerTitle: channel == "send" ? "Alpha caller" : nil, recipient: recipient, targetTitle: nil,
            kind: nil, topic: nil, body: body, bodyRef: nil, replyTo: nil, inReplyTo: nil, urgent: nil,
            submitted: nil, queued: nil, truncated: false, status: "delivered", lifecycle: []
        )
        result.recipientPanelIDs = recipients.map(\.uuidString)
        return result
    }

    private func snapshot(_ messages: [MessagesPageRecord], titles: [UUID: String] = [:]) -> MessagesPageSnapshot {
        let workspace = UUID().uuidString
        var result = MessagesPageSnapshot(
            generatedAt: "2026-10-02T00:00:10.000Z", totalObserved: messages.count,
            messageLimit: 10_000, messageByteLimit: 16 * 1024 * 1024,
            estimatedMessageBytes: 0, messages: messages
        )
        result.directory = MessagesPageDirectory(
            panels: [alpha, bravo].map {
                .init(id: $0.uuidString, title: titles[$0] ?? "Panel \($0.uuidString.prefix(4))", workspace: workspace,
                      live: true, type: "terminal", agent: nil, address: $0 == alpha ? "alpha" : nil, parent: nil)
            },
            workspaces: [.init(id: workspace, title: "Fixture", live: true)]
        )
        return result
    }

    // MARK: Harness

    /// Loads the page, waits for it, and returns uncaught errors and
    /// `console.error` lines collected from the first script onward.
    private func load(_ snapshot: MessagesPageSnapshot, fragment: String? = nil) async throws -> WKWebView {
        let page = directory.appendingPathComponent("messages.html")
        try MessagesPageRenderer.render(snapshot: snapshot).write(to: page, atomically: true, encoding: .utf8)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            window.__cwErrors = [];
            window.addEventListener("error", (e) => window.__cwErrors.push(String(e.message)));
            const __cwConsoleError = console.error.bind(console);
            console.error = (...args) => { window.__cwErrors.push(args.map(String).join(" ")); __cwConsoleError(...args); };
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900), configuration: configuration)
        webView = view
        let target = fragment.map { MessagesPageWeb.url(page: page, fragment: $0) } ?? page
        view.loadFileURL(target, allowingReadAccessTo: directory)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" {
                return view
            }
        }
        XCTFail("the messages page did not finish loading")
        return view
    }

    private func value(_ view: WKWebView, _ script: String) async throws -> Any? {
        try await view.evaluateJavaScript(script)
    }

    private func assertNoScriptErrors(_ view: WKWebView, file: StaticString = #filePath, line: UInt = #line) async throws {
        let errors = try await value(view, "window.__cwErrors.join(' | ')") as? String
        XCTAssertEqual(errors, "", "page script errors", file: file, line: line)
    }

    // MARK: Tests

    func testWebViewDrawsSendersWhoseAddressesHoldKeySeparators() async throws {
        let view = try await load(snapshot([
            record(id: "a1", channel: "send", sender: nil, senderID: alpha.uuidString, surface: bravo),
            record(id: "a2", sender: "evil|pipe>gt", surface: bravo),
            record(id: "a3", sender: "id:\(alpha.uuidString)", surface: bravo, recipients: [bravo, charlie]),
        ]))

        try await assertNoScriptErrors(view)
        let observed1 = try await value(view, "document.body.className") as? String
        XCTAssertEqual(observed1, "view-web")
        let observed2 = try await value(view, "document.querySelectorAll('.cw-node').length") as? Int
        XCTAssertEqual(observed2, 4)
        let observed3 = try await value(view, "document.querySelectorAll('.cw-edge').length") as? Int
        XCTAssertEqual(observed3, 3)
        let labels = try await value(view, "[...document.querySelectorAll('.cw-lbl')].map(t => t.textContent).join('\\n')") as? String
        XCTAssertTrue(labels?.contains("evil|pipe>gt") == true)
        let observed4 = try await value(view, "document.getElementById('cw-inspector').children.length > 0") as? Bool
        XCTAssertEqual(observed4, true)
    }

    func testDeepLinkToAPanelThePageHasNotSeenStillDraws() async throws {
        let unseen = UUID()
        let view = try await load(
            snapshot([record(id: "b1", sender: "alpha", surface: bravo)]),
            fragment: MessagesPageWeb.deepLinkFragment(panelID: unseen, nonce: 7)
        )

        try await assertNoScriptErrors(view)
        let observed5 = try await value(view, "document.querySelector('#cw-scope [aria-pressed=true]').dataset.v") as? String
        XCTAssertEqual(observed5, "panel")
        let title = try await value(view, "document.querySelector('.cw-title2').textContent") as? String
        XCTAssertEqual(title, "panel \(unseen.uuidString.prefix(8))")
    }

    func testWorkspaceScopeWithNoMessagesDoesNotThrow() async throws {
        let view = try await load(snapshot([]))
        _ = try await value(view, "document.querySelector('#cw-scope [data-v=workspace]').click(); 0")

        try await assertNoScriptErrors(view)
        let observed6 = try await value(view, "document.querySelector('.cw-title2').textContent") as? String
        XCTAssertEqual(observed6, "No workspace has messages yet")
        let observed7 = try await value(view, "document.getElementById('cw-empty').hidden") as? Bool
        XCTAssertEqual(observed7, false)
    }

    func testAgentChosenTitlesAndBodiesRenderAsText() async throws {
        let hostile = #"<img src=x onerror="document.title='owned'">"#
        let view = try await load(snapshot(
            [record(id: "c1", sender: "alpha", surface: bravo, body: hostile + "<script>document.title='owned'</script>")],
            titles: [bravo: hostile]
        ))
        _ = try await value(view, "document.querySelector('#cw-inspector tr.cw-row').click(); 0")

        try await assertNoScriptErrors(view)
        let observed8 = try await value(view, "document.querySelectorAll('#cw img, #cw-inspector script').length") as? Int
        XCTAssertEqual(observed8, 0)
        let observed9 = try await value(view, "document.title") as? String
        XCTAssertNotEqual(observed9, "owned")
        let thread = try await value(view, "document.querySelector('.cw-msg .cw-body').textContent") as? String
        XCTAssertTrue(thread?.hasPrefix(hostile) == true)
        let heading = try await value(view, "document.querySelector('.cw-title2').textContent") as? String
        XCTAssertTrue(heading?.contains(hostile) == true)
    }
}
