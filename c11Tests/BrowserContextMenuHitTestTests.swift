import XCTest
import WebKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-497. Download Image, Download Linked File and Open Link act on the
/// element the context menu resolves under the cursor. The menu point comes
/// from the window event, so these tests start from window coordinates (origin
/// bottom-left, the same for every view) and let AppKit convert them, exactly
/// as `willOpenMenu` does.
///
/// The page stacks two linked images, each half the viewport tall.
///
/// Host-required (`c11Tests`): WebKit needs the app's main bundle.
final class BrowserContextMenuHitTestTests: XCTestCase {
    private static let height: CGFloat = 300
    private static let page = """
        <!doctype html>
        <style>html,body{margin:0;overflow:hidden}img{display:block;width:100vw;height:50vh}</style>
        <a href="http://hit.test/top-link"><img src="http://hit.test/top.png"></a>
        <a href="http://hit.test/bottom-link"><img src="http://hit.test/bottom.png"></a>
        """

    @MainActor
    func testMenuPointResolvesTheImageAndLinkUnderTheCursor() throws {
        let fixture = try loadPage()

        // 60pt below the top edge, then 60pt above the bottom edge.
        XCTAssertEqual(try resolve(fixture, pointsFromTop: 60), .init(image: "top.png", link: "top-link"))
        XCTAssertEqual(try resolve(fixture, pointsFromTop: 240), .init(image: "bottom.png", link: "bottom-link"))
    }

    @MainActor
    func testMenuPointAccountsForPageZoom() throws {
        let fixture = try loadPage()
        fixture.webView.pageZoom = 2

        // At 2x each image is 150pt tall on screen but 75 CSS pixels tall, so
        // 110pt down is still the top image and 190pt down is the bottom one.
        XCTAssertEqual(try resolve(fixture, pointsFromTop: 110), .init(image: "top.png", link: "top-link"))
        XCTAssertEqual(try resolve(fixture, pointsFromTop: 190), .init(image: "bottom.png", link: "bottom-link"))
    }

    // MARK: - Fixture

    private struct Fixture {
        let window: NSWindow
        let webView: CmuxWebView
        let navigation: FinishWaiter
    }

    private struct Hit: Equatable {
        let image: String?
        let link: String?
    }

    @MainActor
    private func loadPage() throws -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: Self.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = CmuxWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: Self.height),
            configuration: configuration
        )
        window.contentView = webView
        addTeardownBlock { window.close() }

        let navigation = FinishWaiter()
        webView.navigationDelegate = navigation
        let finished = expectation(description: "page loaded")
        navigation.onFinish = { finished.fulfill() }
        XCTAssertNotNil(webView.loadHTMLString(Self.page, baseURL: URL(string: "http://hit.test/")))
        wait(for: [finished], timeout: 15)
        return Fixture(window: window, webView: webView, navigation: navigation)
    }

    /// Resolves the image and link the context menu would act on for a
    /// right-click `pointsFromTop` below the window's top edge.
    @MainActor
    private func resolve(_ fixture: Fixture, pointsFromTop: CGFloat) throws -> Hit {
        let windowPoint = NSPoint(x: 200, y: Self.height - pointsFromTop)
        let viewPoint = fixture.webView.convert(windowPoint, from: nil)

        var image: URL?
        var link: URL?
        let imageResolved = expectation(description: "image resolved")
        let linkResolved = expectation(description: "link resolved")
        fixture.webView.findImageURLAtPoint(viewPoint) { url in
            image = url
            imageResolved.fulfill()
        }
        fixture.webView.findLinkURLAtPoint(viewPoint) { url in
            link = url
            linkResolved.fulfill()
        }
        wait(for: [imageResolved, linkResolved], timeout: 10)
        return Hit(image: image?.lastPathComponent, link: link?.lastPathComponent)
    }
}

private final class FinishWaiter: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
        onFinish = nil
    }
}
