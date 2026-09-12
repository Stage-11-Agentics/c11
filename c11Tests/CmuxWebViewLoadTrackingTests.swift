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
/// These live in the **host-required** `c11Tests` target, not `c11LogicTests`:
/// in the bare xctest runner there is no usable main bundle
/// (`bundleProxyForCurrentProcess is nil`) and a crash here restarts the runner,
/// which takes ~15 other host-sensitive suites down with it.
///
/// `loadHTMLString` is deliberately **not** covered. It traps with
/// `Signal 5: System trap` inside `super` in *both* the bare runner and the
/// app-hosted one — WebKit cannot bring up a web process under XCTest here — so
/// any test of it is a guaranteed crash rather than an assertion. Its override is
/// three lines, identical in shape to the four exercised below; the live path is
/// covered by the error-page flow in `BrowserPanel.loadErrorPage` and by phase-4
/// validation, not by a test that cannot run.
///
/// The predicate's non-loading cases, the timeout clamp, and the run-loop pump are
/// covered in `BrowserAwaitPolicyTests` in the logic target.
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
