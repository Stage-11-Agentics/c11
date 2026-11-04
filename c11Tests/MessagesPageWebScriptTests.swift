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
    private let fixtureWorkspace = UUID().uuidString

    private func record(
        id: String,
        channel: String = "mailbox",
        sender: String?,
        senderID: String? = nil,
        surface: UUID?,
        recipient: String? = "role",
        recipients: [UUID] = [],
        body: String = "hello",
        at: Date? = nil
    ) -> MessagesPageRecord {
        let stamp = at.map { date -> String in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        } ?? "2026-10-02T00:00:0\(id.count % 10).000Z"
        var result = MessagesPageRecord(
            id: id, channel: channel, timestamp: stamp, sequence: nil,
            workspace: nil, surface: surface?.uuidString, sender: sender, senderID: senderID,
            callerTitle: channel == "send" ? "Alpha caller" : nil, recipient: recipient, targetTitle: nil,
            kind: nil, topic: nil, body: body, bodyRef: nil, replyTo: nil, inReplyTo: nil, urgent: nil,
            submitted: nil, queued: nil, truncated: false, status: "delivered", lifecycle: []
        )
        result.recipientPanelIDs = recipients.map(\.uuidString)
        return result
    }

    private func snapshot(
        _ messages: [MessagesPageRecord],
        titles: [UUID: String] = [:],
        panels: [UUID]? = nil,
        descriptions: [UUID: String] = [:]
    ) -> MessagesPageSnapshot {
        let workspace = fixtureWorkspace
        var result = MessagesPageSnapshot(
            generatedAt: "2026-10-02T00:00:10.000Z", totalObserved: messages.count,
            messageLimit: 10_000, messageByteLimit: 16 * 1024 * 1024,
            estimatedMessageBytes: 0, messages: messages
        )
        result.directory = MessagesPageDirectory(
            panels: (panels ?? [alpha, bravo]).map {
                .init(id: $0.uuidString, title: titles[$0] ?? "Panel \($0.uuidString.prefix(4))", workspace: workspace,
                      live: true, type: "terminal", agent: nil, address: $0 == alpha ? "alpha" : nil, parent: nil,
                      description: descriptions[$0])
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
        try await waitForLoad(view)
        return view
    }

    /// What c11 does on new traffic: rewrite the page, then reload the panel.
    private func rewriteAndReload(_ view: WKWebView, _ snapshot: MessagesPageSnapshot) async throws {
        let page = directory.appendingPathComponent("messages.html")
        try MessagesPageRenderer.render(snapshot: snapshot).write(to: page, atomically: true, encoding: .utf8)
        view.reload()
        try await Task.sleep(nanoseconds: 200_000_000)
        try await waitForLoad(view)
    }

    private func waitForLoad(_ view: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" {
                return
            }
        }
        XCTFail("the messages page did not finish loading")
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
        XCTAssertEqual(title, "Unnamed panel \(unseen.uuidString.prefix(4))")
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

    func testWebViewRefitsWhenItsPanelIsLaidOutNarrower() async throws {
        // A browser panel is often created at one width and laid out at another.
        let view = try await load(snapshot([
            record(id: "d1", sender: "alpha", surface: bravo),
            record(id: "d2", sender: "id:\(bravo.uuidString)", surface: alpha),
        ]))
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 900)
        try await Task.sleep(nanoseconds: 600_000_000)

        try await assertNoScriptErrors(view)
        let box = try await value(view, """
            (() => { const s = document.getElementById("cw-stage").getBoundingClientRect();
              return [...document.querySelectorAll(".cw-node rect")].every((r) => {
                const b = r.getBoundingClientRect();
                return b.width > 0 && b.left >= s.left - 1 && b.right <= s.right + 1; }); })()
            """) as? Bool
        XCTAssertEqual(box, true, "every node sits inside the narrowed stage")
        let stageFits = try await value(
            view, "document.getElementById('cw-stage').getBoundingClientRect().right <= window.innerWidth + 1"
        ) as? Bool
        XCTAssertEqual(stageFits, true, "the stage is no wider than the panel")
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

    private func nodePositions(_ view: WKWebView) async throws -> [String: String] {
        let json = try await value(view, """
            JSON.stringify(Object.fromEntries([...document.querySelectorAll(".cw-node")]
              .map((g) => [g.dataset.id, g.getAttribute("transform")])))
            """) as? String
        return try JSONDecoder().decode([String: String].self, from: Data((json ?? "{}").utf8))
    }

    func testReloadWithNewTrafficLeavesEveryDrawnPanelInPlace() async throws {
        let first = [
            record(id: "e1", sender: "id:\(alpha.uuidString)", surface: bravo),
            record(id: "e2", sender: "id:\(bravo.uuidString)", surface: alpha),
        ]
        let view = try await load(snapshot(first))
        let before = try await nodePositions(view)
        XCTAssertEqual(before.count, 2)

        // A new panel joins the same workspace, and a larger group of
        // newcomers arrives: both used to re-lay-out the existing cluster.
        try await rewriteAndReload(view, snapshot(first + [
            record(id: "e3", sender: "id:\(alpha.uuidString)", surface: charlie),
            record(id: "e4", sender: "newcomer-1", surface: bravo),
            record(id: "e5", sender: "newcomer-2", surface: bravo),
            record(id: "e6", sender: "newcomer-3", surface: alpha),
        ], panels: [alpha, bravo, charlie]))

        try await assertNoScriptErrors(view)
        let after = try await nodePositions(view)
        XCTAssertEqual(after.count, 6)
        for (id, transform) in before {
            XCTAssertEqual(after[id], transform, "panel \(id) moved on reload")
        }
    }

    func testAnOpenedMessageStaysOpenAcrossAReload() async throws {
        let long = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let messages = [record(id: "f1", sender: "id:\(alpha.uuidString)", surface: bravo, body: long)]
        let view = try await load(snapshot(messages))
        _ = try await value(view, "document.querySelector('#cw-inspector tr.cw-row').click(); 0")
        _ = try await value(view, "document.querySelector('.cw-msg .cw-body').click(); 0")
        let opened = try await value(view, "document.querySelectorAll('.cw-body.open').length") as? Int
        XCTAssertEqual(opened, 1)

        try await rewriteAndReload(view, snapshot(messages + [record(id: "f2", sender: "gamma", surface: alpha)]))

        try await assertNoScriptErrors(view)
        let title = try await value(view, "document.querySelector('.cw-title2').textContent") as? String
        XCTAssertTrue(title?.contains("⇄") == true, "the thread is still selected")
        let stillOpen = try await value(view, "document.querySelectorAll('.cw-body.open').length") as? Int
        XCTAssertEqual(stillOpen, 1)
    }

    private func viewTransform(_ view: WKWebView) async throws -> String? {
        try await value(view, "document.getElementById('cw-view').getAttribute('transform')") as? String
    }

    func testNewTrafficBetweenDrawnPanelsMovesNeitherPanelsNorTheView() async throws {
        let first = [
            record(id: "g1", sender: "id:\(alpha.uuidString)", surface: bravo),
            record(id: "g2", sender: "id:\(bravo.uuidString)", surface: charlie),
        ]
        let view = try await load(snapshot(first, panels: [alpha, bravo, charlie]))
        let positions = try await nodePositions(view)
        let frame = try await viewTransform(view)

        // More traffic on the same edges, and a new edge between drawn panels.
        try await rewriteAndReload(view, snapshot(first + [
            record(id: "g3", sender: "id:\(alpha.uuidString)", surface: bravo),
            record(id: "g4", sender: "id:\(charlie.uuidString)", surface: alpha),
        ], panels: [alpha, bravo, charlie]))

        try await assertNoScriptErrors(view)
        let after = try await nodePositions(view)
        XCTAssertEqual(after, positions)
        let frameAfter = try await viewTransform(view)
        XCTAssertEqual(frameAfter, frame, "the view moved on a reload with nothing new to place")
    }

    func testAFilterTurnedOffAndOnAgainKeepsEveryPanelInPlace() async throws {
        let view = try await load(snapshot([
            record(id: "h1", sender: "id:\(alpha.uuidString)", surface: bravo),
            record(id: "h2", channel: "send", sender: nil, senderID: charlie.uuidString, surface: alpha),
        ], panels: [alpha, bravo, charlie]))
        let positions = try await nodePositions(view)
        XCTAssertEqual(positions.count, 3)

        _ = try await value(view, "document.querySelector('#cw-channels [data-v=send]').click(); 0")
        let hidden = try await nodePositions(view)
        XCTAssertEqual(hidden.count, 2, "send traffic is filtered out")
        _ = try await value(view, "document.querySelector('#cw-channels [data-v=send]').click(); 0")

        try await assertNoScriptErrors(view)
        let after = try await nodePositions(view)
        XCTAssertEqual(after, positions)
    }

    func testAThreadReadAtItsEndFollowsNewMessagesAcrossAReload() async throws {
        let long = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let thread = (1...30).map { record(id: "t\($0)", sender: "id:\(alpha.uuidString)", surface: bravo, body: long) }
        let view = try await load(snapshot(thread))
        _ = try await value(view, "document.querySelector('#cw-inspector tr.cw-row').click(); 0")
        let atEnd = "(() => { const i = document.getElementById('cw-inspector'); return i.scrollHeight > i.clientHeight + 50 && i.scrollHeight - i.scrollTop - i.clientHeight < 4; })()"
        let startsAtEnd = try await value(view, atEnd) as? Bool
        XCTAssertEqual(startsAtEnd, true)

        try await rewriteAndReload(view, snapshot(thread + [
            record(id: "t31", sender: "id:\(bravo.uuidString)", surface: alpha, body: long),
        ]))

        try await assertNoScriptErrors(view)
        let stillAtEnd = try await value(view, atEnd) as? Bool
        XCTAssertEqual(stillAtEnd, true, "the thread stopped following its newest message")
    }

    func testBuiltTimeNamesTheTimeZoneNotACity() async throws {
        let view = try await load(snapshot([record(id: "z1", sender: "alpha", surface: bravo)]))
        try await assertNoScriptErrors(view)
        let result = try await value(view, """
            (() => {
              const stamp = document.getElementById("cw-stamp").textContent;
              const zone = Intl.DateTimeFormat().resolvedOptions().timeZone || "";
              const city = zone.includes("/") ? zone.split("/").pop().replace(/_/g, " ") : "";
              return city && stamp.includes(city) ? "names the city " + city + ": " + stamp : "ok";
            })()
            """) as? String
        XCTAssertEqual(result, "ok")
    }

    // MARK: Scrubber, Open now, hover, names

    func testScrubberDetentsNarrowTheWebToTheChosenWindow() async throws {
        let view = try await load(snapshot([
            record(id: "s1", sender: "id:\(alpha.uuidString)", surface: bravo, at: Date().addingTimeInterval(-20 * 60)),
            record(id: "s2", sender: "id:\(charlie.uuidString)", surface: alpha, at: Date().addingTimeInterval(-3 * 86400)),
        ], panels: [alpha, bravo, charlie]))
        let all = try await value(view, "document.querySelectorAll('.cw-node').length") as? Int
        XCTAssertEqual(all, 3)

        _ = try await value(view, "[...document.querySelectorAll('.cw-tick')].find(b => b.textContent === '1H').click(); 0")
        let lastHour = try await value(view, "document.querySelectorAll('.cw-node').length") as? Int
        XCTAssertEqual(lastHour, 2, "the three-day-old message left the window")
        let label = try await value(view, "document.getElementById('cw-scrub-val').textContent") as? String
        XCTAssertEqual(label, "Last hour")

        // Dragged near a detent, the scrubber lands on it and means exactly that span.
        let snapped = try await value(view, """
            (() => {
              const s = document.getElementById('cw-scrub'), six = Number([...document.querySelectorAll('.cw-tick')].find(b => b.textContent === '6H').style.left.replace('%', '')) * 10;
              s.value = String(Math.round(six) + 9); s.dispatchEvent(new Event('input')); s.dispatchEvent(new Event('change'));
              return document.getElementById('cw-scrub-val').textContent;
            })()
            """) as? String
        XCTAssertEqual(snapped, "Last 6 hours")
        _ = try await value(view, "[...document.querySelectorAll('.cw-tick')].find(b => b.textContent === '7D').click(); 0")
        let week = try await value(view, "document.querySelectorAll('.cw-node').length") as? Int
        XCTAssertEqual(week, 3)
        try await assertNoScriptErrors(view)
    }

    func testOpenNowDrawsQuietOpenPanelsAndHistoryDoesNot() async throws {
        let view = try await load(snapshot([
            record(id: "o1", sender: "id:\(alpha.uuidString)", surface: bravo),
        ], panels: [alpha, bravo, charlie]))
        let history = try await value(view, "document.querySelectorAll('.cw-node').length") as? Int
        XCTAssertEqual(history, 2)

        _ = try await value(view, "document.querySelector('#cw-closed [data-v=hide]').click(); 0")
        let openNow = try await value(view, "document.querySelectorAll('.cw-node').length") as? Int
        XCTAssertEqual(openNow, 3, "the quiet open panel is drawn")
        let story = try await value(view, "document.querySelector('.cw-story').textContent") as? String
        XCTAssertTrue(story?.contains("1 more open panel said nothing") == true, story ?? "no story")
        try await assertNoScriptErrors(view)
    }

    func testHoverCardShowsTitleAndSubtitleWithoutItsLineage() async throws {
        let view = try await load(snapshot(
            [record(id: "h1", sender: "id:\(alpha.uuidString)", surface: bravo)],
            titles: [bravo: "Review Owner"],
            descriptions: [bravo: "Auditing the retry path; next, cancellation.\nLineage: Lead → Review Owner"]
        ))
        let card = try await value(view, """
            (() => {
              const g = [...document.querySelectorAll('.cw-node')].find(n => n.querySelector('.cw-lbl').textContent === 'Review Owner');
              g.dispatchEvent(new MouseEvent('mouseenter', { clientX: 200, clientY: 200 }));
              const c = document.getElementById('cw-card');
              return (c.hidden ? 'hidden' : 'shown') + '|' + c.textContent + '|' + document.querySelectorAll('.cw-node.near').length;
            })()
            """) as? String
        XCTAssertTrue(card?.hasPrefix("shown|Review OwnerAuditing the retry path; next, cancellation.") == true, card ?? "no card")
        XCTAssertFalse(card?.contains("Lineage") == true)
        XCTAssertTrue(card?.hasSuffix("|2") == true, "the panel and its peer light up")
        try await assertNoScriptErrors(view)
    }

    func testAPanelWithAGenericTitleIsNamedByWhatItSaysItIsDoing() async throws {
        let view = try await load(snapshot(
            // Addressed by id, so the panel has no mailbox address to be named by.
            [record(id: "n1", sender: "id:\(alpha.uuidString)", surface: bravo, recipient: "id:\(bravo.uuidString)")],
            titles: [bravo: "Terminal"],
            descriptions: [bravo: "Fixing the relay handshake"]
        ))
        let labels = try await value(view, "[...document.querySelectorAll('.cw-lbl')].map(t => t.textContent).join('|')") as? String
        XCTAssertTrue(labels?.contains("Fixing the relay handshake") == true, labels ?? "no labels")
        XCTAssertFalse(labels?.contains("Terminal") == true)
        try await assertNoScriptErrors(view)
    }
}
