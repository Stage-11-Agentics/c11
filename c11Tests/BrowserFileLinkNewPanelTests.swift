import XCTest
import WebKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-505. A web page decides the link the context menu resolves, and a link
/// opened in a new panel loads with read access to its folder. WebKit never
/// lets a web page load a `file:` URL, so neither may Open Link in New Panel,
/// Cmd-click, target=_blank or window.open. A local page may still open local
/// links.
///
/// Host-required (`c11Tests`): WebKit needs the app's main bundle.
@MainActor
final class BrowserFileLinkNewPanelTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-505-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testWebPageMenuDoesNotOpenALocalFileInANewPanel() throws {
        let webView = try loadedWebView { $0.loadHTMLString("<p>site a</p>", baseURL: URL(string: "https://site-a.test/")) }
        let secret = try writeFile("secret.txt")

        XCTAssertNil(openLinkInNewPanelFromMenu(webView, resolving: secret), "A web page opened a local file in a new panel")
        let web = URL(string: "https://site-b.test/page")!
        XCTAssertEqual(openLinkInNewPanelFromMenu(webView, resolving: web), web)
    }

    func testLocalPageMenuOpensALocalFileInANewPanel() throws {
        let page = try writeFile("page.html", contents: "<p>local page</p>")
        let webView = try loadedWebView { $0.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        let notes = try writeFile("notes.txt")

        XCTAssertEqual(openLinkInNewPanelFromMenu(webView, resolving: notes), notes)
    }

    /// Cmd-click, target=_blank, window.open and the menu all reach
    /// `openLinkInNewPanel`, which decides from the panel's own page.
    func testBrowserPanelOpensLocalLinksOnlyFromALocalPage() throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        let notes = try writeFile("notes.txt")
        let web = URL(string: "https://site-b.test/page")!

        try load(panel.webView) { $0.loadHTMLString("<p>site a</p>", baseURL: URL(string: "https://site-a.test/")) }
        XCTAssertFalse(panel.shouldOpenLinkInNewPanel(notes), "A web page may open a local file in a new panel")
        XCTAssertTrue(panel.shouldOpenLinkInNewPanel(web))

        let page = try writeFile("page.html", contents: "<p>local page</p>")
        try load(panel.webView) { $0.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        XCTAssertTrue(panel.shouldOpenLinkInNewPanel(notes))
        XCTAssertTrue(panel.shouldOpenLinkInNewPanel(web))
    }

    // MARK: - Fixture

    private func writeFile(_ name: String, contents: String = "local file") throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func loadedWebView(_ start: (CmuxWebView) -> WKNavigation?) throws -> CmuxWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        try load(webView) { start($0 as! CmuxWebView) }
        return webView
    }

    /// Starts a load and waits until the page is shown and settled.
    private func load(_ webView: WKWebView, _ start: (WKWebView) -> WKNavigation?) throws {
        XCTAssertNotNil(start(webView))
        let deadline = Date().addingTimeInterval(15)
        while (webView.isLoading || webView.url == nil), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(webView.isLoading, "The page did not finish loading")
    }

    /// Right-clicks, then chooses Open Link in New Panel with the menu's link
    /// resolving to `link`. Returns the URL handed on to open, if any.
    private func openLinkInNewPanelFromMenu(_ webView: CmuxWebView, resolving link: URL) -> URL? {
        webView.contextMenuLinkURLProvider = { _, _, completion in completion(link) }
        var opened: URL?
        webView.onContextMenuOpenLinkInNewPanel = { opened = $0 }

        let item = NSMenuItem(title: "Open Link in New Window", action: NSSelectorFromString("openLinkInNewWindow:"), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
        item.target = NSObject()
        let menu = NSMenu()
        menu.addItem(item)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 200, y: 150),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        webView.willOpenMenu(menu, with: event)
        XCTAssertTrue(item.target === webView, "Open Link in New Window was not retargeted to a new panel")
        if let action = item.action {
            XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        }
        return opened
    }
}
