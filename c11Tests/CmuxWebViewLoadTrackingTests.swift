import XCTest
import WebKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-209. The `CmuxWebView.hasIssuedLoad` cases that ask WebKit to actually
/// load something.
///
/// These live in the **host-required** `c11Tests` target, not `c11LogicTests`.
/// `loadHTMLString` traps with `Signal 5: System trap` inside `super` in the
/// bare xctest runner (no host app, so no usable main bundle —
/// `bundleProxyForCurrentProcess is nil`), and the runner restart that follows
/// takes ~15 other host-sensitive suites down with it. The predicate's non-loading
/// cases, the timeout clamp, and the run-loop pump are all covered in
/// `BrowserAwaitPolicyTests` in the logic target.
final class CmuxWebViewLoadTrackingTests: XCTestCase {

    @MainActor
    func testLoadRequestMarksLoadIssued() {
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        XCTAssertFalse(webView.hasIssuedLoad)
        _ = webView.load(URLRequest(url: URL(string: "about:blank")!))
        XCTAssertTrue(webView.hasIssuedLoad)
        XCTAssertTrue(TerminalController.v2BrowserWebViewHasIssuedLoad(webView))
    }

    @MainActor
    func testLoadHTMLStringMarksLoadIssued() {
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        XCTAssertFalse(webView.hasIssuedLoad)
        _ = webView.loadHTMLString("<p>hello</p>", baseURL: nil)
        XCTAssertTrue(webView.hasIssuedLoad)
        XCTAssertTrue(TerminalController.v2BrowserWebViewHasIssuedLoad(webView))
    }

    @MainActor
    func testReloadMarksLoadIssued() {
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        XCTAssertFalse(webView.hasIssuedLoad)
        _ = webView.reload()
        XCTAssertTrue(webView.hasIssuedLoad)
    }

    @MainActor
    func testGoBackMarksLoadIssued() {
        // No back entry exists, so `super` returns nil — but the flag must still
        // flip, because the guard's job is to say "a load was attempted on this
        // instance", not "a navigation succeeded".
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        _ = webView.goBack()
        XCTAssertTrue(webView.hasIssuedLoad)
    }
}
