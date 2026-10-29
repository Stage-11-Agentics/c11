import XCTest
import WebKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-497. Download Image, Download Linked File, Open Link in New Panel and
/// Open Link in Default Browser act on the element under the cursor.
///
/// Each check sends a right-mouse-down event at a window point through
/// `willOpenMenu`, then dispatches the menu item the way AppKit does. The web
/// view sits inset in a larger window, as it does below the tab bar and
/// beside the sidebar, so a capture that skips or mis-targets the
/// window-to-view conversion fails.
///
/// The page stacks two linked images, each half the viewport tall. Their URLs
/// point at a closed loopback port, so nothing leaves the machine and the
/// page finishes loading at once.
///
/// Host-required (`c11Tests`): WebKit needs the app's main bundle.
@MainActor
final class BrowserContextMenuHitTestTests: XCTestCase {
    private static let webViewFrame = NSRect(x: 50, y: 70, width: 400, height: 300)
    private static let base = "http://127.0.0.1:9"
    private static let page = """
        <!doctype html>
        <style>html,body{margin:0;overflow:hidden}img{display:block;width:100vw;height:50vh}</style>
        <a href="\(base)/top-link"><img src="\(base)/top.png"></a>
        <a href="\(base)/bottom-link"><img src="\(base)/bottom.png"></a>
        """

    func testMenuActsOnTheImageAndLinkUnderTheCursor() throws {
        let fixture = try loadPage()

        // 60pt below the web view's top edge, then 60pt above its bottom.
        XCTAssertEqual(try fixture.downloadImage(pointsFromTop: 60), "top.png")
        XCTAssertEqual(try fixture.openLinkInDefaultBrowser(pointsFromTop: 60), "top-link")
        XCTAssertEqual(try fixture.downloadImage(pointsFromTop: 240), "bottom.png")
        XCTAssertEqual(try fixture.openLinkInDefaultBrowser(pointsFromTop: 240), "bottom-link")
    }

    /// A page with an image at the top, a mailto: link in the middle and an
    /// iframe at the bottom, each 100pt tall.
    private static let scopePage = """
        <!doctype html>
        <style>html,body{margin:0;overflow:hidden}#logo,a,iframe{display:block;width:100vw;height:100px;border:0;margin:0}</style>
        <img id="logo" src="\(base)/logo.png">
        <a href="mailto:someone@example.com">mail</a>
        <iframe src="\(base)/frame.html"></iframe>
        """

    /// C11-504. Download Linked File on a link it cannot download hands back to
    /// WebKit; it must not climb to <body> and download the page's first image.
    func testDownloadLinkedFileOnAMailtoLinkDoesNotTakeAnotherImage() throws {
        let fixture = try loadPage(Self.scopePage)

        XCTAssertEqual(try fixture.download(.linkedFile, pointsFromTop: 150), .fellBack)
        XCTAssertEqual(try fixture.download(.image, pointsFromTop: 50), .downloaded("logo.png"))
    }

    /// C11-504. A frame's content is not in the page's document, so Download
    /// Image over an iframe hands back to WebKit instead of downloading the
    /// frame's page.
    func testDownloadImageOverAFrameDoesNotDownloadTheFramePage() throws {
        let fixture = try loadPage(Self.scopePage)

        XCTAssertEqual(try fixture.download(.image, pointsFromTop: 250), .fellBack)
    }

    func testMenuAccountsForPageZoom() throws {
        let fixture = try loadPage()
        fixture.webView.pageZoom = 2

        // At 2x each image is 150pt tall on screen but 75 CSS pixels tall, so
        // 110pt down is still the top image and 190pt down is the bottom one.
        XCTAssertEqual(try fixture.downloadImage(pointsFromTop: 110), "top.png")
        XCTAssertEqual(try fixture.openLinkInDefaultBrowser(pointsFromTop: 110), "top-link")
        XCTAssertEqual(try fixture.downloadImage(pointsFromTop: 190), "bottom.png")
        XCTAssertEqual(try fixture.openLinkInDefaultBrowser(pointsFromTop: 190), "bottom-link")
    }

    // MARK: - Fixture

    private func loadPage(_ html: String? = nil) throws -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        window.contentView = content
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = CmuxWebView(frame: Self.webViewFrame, configuration: configuration)
        content.addSubview(webView)
        addTeardownBlock { window.close() }

        let fixture = Fixture(test: self, window: window, webView: webView)
        let finished = expectation(description: "page loaded")
        fixture.navigation.onSettled = { error in
            if let error { XCTFail("Page load failed: \(error)") }
            finished.fulfill()
        }
        XCTAssertNotNil(webView.loadHTMLString(html ?? Self.page, baseURL: URL(string: "\(Self.base)/")))
        wait(for: [finished], timeout: 15)
        return fixture
    }

    @MainActor
    private final class Fixture {
        let window: NSWindow
        let webView: CmuxWebView
        let navigation = FinishWaiter()
        private let downloads = DownloadURLRecorder()
        private unowned let test: XCTestCase

        init(test: XCTestCase, window: NSWindow, webView: CmuxWebView) {
            self.test = test
            self.window = window
            self.webView = webView
            webView.navigationDelegate = navigation
            webView.contextMenuDownloadDelegate = downloads
        }

        enum DownloadItem {
            case image
            case linkedFile
        }

        enum Outcome: Equatable {
            /// WebKit was asked to download a file with this name.
            case downloaded(String)
            /// The menu handed back to WebKit's own menu item.
            case fellBack
        }

        /// Right-clicks `pointsFromTop` below the web view's top edge, chooses
        /// Download Image, and returns the file name WebKit was asked to fetch.
        func downloadImage(pointsFromTop: CGFloat) throws -> String? {
            guard case .downloaded(let name) = try download(.image, pointsFromTop: pointsFromTop) else { return nil }
            return name
        }

        /// Right-clicks `pointsFromTop` below the web view's top edge, chooses
        /// the download item, and reports what the menu did with it.
        func download(_ kind: DownloadItem, pointsFromTop: CGFloat) throws -> Outcome {
            let webKitItem = FallbackRecorder()
            let item = NSMenuItem(title: kind == .image ? "Download Image" : "Download Linked File", action: #selector(FallbackRecorder.record(_:)), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(kind == .image ? "WKMenuItemIdentifierDownloadImage" : "WKMenuItemIdentifierDownloadLinkToDisk")
            item.target = webKitItem
            let menu = NSMenu()
            menu.addItem(item)
            rightClick(menu, pointsFromTop: pointsFromTop)

            let settled = test.expectation(description: "download requested or handed back")
            var outcome: Outcome?
            downloads.onRequest = { requestedURL in
                outcome = .downloaded(requestedURL?.lastPathComponent ?? "")
                settled.fulfill()
            }
            webKitItem.onRecord = {
                outcome = .fellBack
                settled.fulfill()
            }
            XCTAssertTrue(item.target === webView, "The download item was not taken over")
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            test.wait(for: [settled], timeout: 10)
            downloads.onRequest = nil
            return try XCTUnwrap(outcome)
        }

        /// Right-clicks a link, chooses Open Link in Default Browser, and
        /// returns the link's last path component.
        func openLinkInDefaultBrowser(pointsFromTop: CGFloat) throws -> String? {
            let openLink = NSMenuItem(title: "Open Link", action: nil, keyEquivalent: "")
            openLink.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLink")
            let menu = NSMenu()
            menu.addItem(openLink)
            rightClick(menu, pointsFromTop: pointsFromTop)
            let item = try XCTUnwrap(menu.items.first { $0.target === webView && $0 !== openLink })

            let opened = test.expectation(description: "link opened")
            var url: URL?
            webView.contextMenuDefaultBrowserOpener = { openedURL in
                url = openedURL
                opened.fulfill()
                return true
            }
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            test.wait(for: [opened], timeout: 10)
            return url?.lastPathComponent
        }

        private func rightClick(_ menu: NSMenu, pointsFromTop: CGFloat) {
            let frame = BrowserContextMenuHitTestTests.webViewFrame
            let windowPoint = NSPoint(x: frame.midX, y: frame.maxY - pointsFromTop)
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
            webView.willOpenMenu(menu, with: event)
        }
    }
}

private final class FinishWaiter: NSObject, WKNavigationDelegate {
    var onSettled: ((Error?) -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        settle(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        settle(error)
    }

    private func settle(_ error: Error?) {
        let callback = onSettled
        onSettled = nil
        callback?(error)
    }
}

/// Reports the URL of each download WebKit starts for the context menu. The
/// downloads go to a closed port and fail at once.
private final class DownloadURLRecorder: NSObject, WKDownloadDelegate {
    var onRequest: ((URL?) -> Void)?

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        completionHandler(nil)
        report(download)
    }

    func downloadDidFinish(_ download: WKDownload) {
        report(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        report(download)
    }

    private func report(_ download: WKDownload) {
        let callback = onRequest
        onRequest = nil
        callback?(download.originalRequest?.url)
    }
}

/// Stands in for WebKit's own menu item, which the menu falls back to.
private final class FallbackRecorder: NSObject {
    var onRecord: (() -> Void)?

    @objc func record(_ sender: Any?) {
        let callback = onRecord
        onRecord = nil
        callback?()
    }
}
