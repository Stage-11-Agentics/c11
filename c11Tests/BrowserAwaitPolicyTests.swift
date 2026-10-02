import XCTest
import WebKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-209. Behavioural tests for the three bounds that keep a browser JS await
/// from freezing the socket control plane:
///
///   1. `v2ClampBrowserTimeoutMs` — a caller cannot request an unbounded hold.
///   2. `CmuxWebView.hasIssuedLoad` — the predicate that says whether a JS eval
///      can expect a completion handler at all. Only the cases that never ask
///      WebKit to load anything live here; the `load*`/`reload` overrides need a
///      real web process and therefore a test host, so they are in
///      `c11Tests/CmuxWebViewLoadTrackingTests.swift`.
///   3. `v2AwaitCallbackPumpingMainRunLoop` — what the nested run-loop pump can
///      and cannot receive while it sits inside a main-queue drain.
///
/// The third group reconstructs the exact frame captured from the wedged
/// process — background queue → `DispatchQueue.main.asyncAndWait` → the pump —
/// because the constraint only exists inside an *in-progress* main-queue drain.
/// Run the same code from a plain main-thread test and the main queue drains
/// normally, which would make the assertions vacuous.
final class BrowserAwaitPolicyTests: XCTestCase {

    // MARK: - Timeout clamp

    func testClampRejectsNonPositiveTimeouts() {
        XCTAssertEqual(TerminalController.v2ClampBrowserTimeoutMs(0), 1)
        XCTAssertEqual(TerminalController.v2ClampBrowserTimeoutMs(-5_000), 1)
    }

    func testClampPassesOrdinaryTimeoutsThrough() {
        XCTAssertEqual(TerminalController.v2ClampBrowserTimeoutMs(1), 1)
        XCTAssertEqual(TerminalController.v2ClampBrowserTimeoutMs(5_000), 5_000)
        XCTAssertEqual(TerminalController.v2ClampBrowserTimeoutMs(30_000), 30_000)
    }

    func testClampBoundsPathologicalTimeouts() {
        let maximum = TerminalController.v2BrowserMaxTimeoutMs
        XCTAssertEqual(TerminalController.v2ClampBrowserTimeoutMs(maximum), maximum)
        XCTAssertEqual(TerminalController.v2ClampBrowserTimeoutMs(maximum + 1), maximum)
        XCTAssertEqual(TerminalController.v2ClampBrowserTimeoutMs(600_000), maximum)
        XCTAssertEqual(TerminalController.v2ClampBrowserTimeoutMs(.max), maximum)
    }

    // C11-217: the three browser operations that can wait for WebKit or a
    // download event must never enter the main-actor socket path. This is the
    // executable policy seam used by the dispatcher, not a source-text check.
    func testBrowserWaitFamilyUsesSocketWorkerPolicy() {
        XCTAssertEqual(
            TerminalController.executionPolicy(forV2Method: "browser.eval"),
            .socketWorker
        )
        XCTAssertEqual(
            TerminalController.executionPolicy(forV2Method: "browser.wait"),
            .socketWorker
        )
        XCTAssertEqual(
            TerminalController.executionPolicy(forV2Method: "browser.download.wait"),
            .socketWorker
        )
        XCTAssertEqual(
            TerminalController.executionPolicy(forV2Method: "browser.snapshot"),
            .socketWorker
        )
        XCTAssertEqual(
            TerminalController.executionPolicy(forV2Method: "browser.cookies.clear"),
            .socketWorker
        )
        XCTAssertEqual(
            TerminalController.executionPolicy(forV2Method: "browser.state.load"),
            .socketWorker
        )
    }

    // B006: these remaining cookie/state calls wait for WebKit callbacks too.
    // Exercise the same policy decision used before socket dispatch.
    func testCookieAndStateSaveWaitsUseSocketWorkerPolicy() {
        for method in ["browser.cookies.get", "browser.cookies.set", "browser.state.save"] {
            XCTAssertEqual(TerminalController.executionPolicy(forV2Method: method), .socketWorker, method)
        }
    }

    // B006 round 1: every socket method with a direct or transitive browser
    // await must use the worker. Includes navigation's optional post-snapshot,
    // retries/diagnostics, telemetry bootstrap and screenshot completion.
    func testEveryBrowserAwaitRouteUsesSocketWorkerPolicy() {
        let methods = [
            "browser.snapshot",
            "browser.click",
            "browser.dblclick",
            "browser.hover",
            "browser.focus",
            "browser.type",
            "browser.fill",
            "browser.press",
            "browser.keydown",
            "browser.keyup",
            "browser.check",
            "browser.uncheck",
            "browser.select",
            "browser.scroll",
            "browser.scroll_into_view",
            "browser.screenshot",
            "browser.get.text",
            "browser.get.html",
            "browser.get.value",
            "browser.get.attr",
            "browser.get.count",
            "browser.get.box",
            "browser.get.styles",
            "browser.is.visible",
            "browser.is.enabled",
            "browser.is.checked",
            "browser.find.role",
            "browser.find.text",
            "browser.find.label",
            "browser.find.placeholder",
            "browser.find.alt",
            "browser.find.title",
            "browser.find.testid",
            "browser.find.first",
            "browser.find.last",
            "browser.find.nth",
            "browser.frame.select",
            "browser.dialog.accept",
            "browser.dialog.dismiss",
            "browser.storage.get",
            "browser.storage.set",
            "browser.storage.clear",
            "browser.console.list",
            "browser.console.clear",
            "browser.errors.list",
            "browser.highlight",
            "browser.addinitscript",
            "browser.addscript",
            "browser.addstyle",
            "browser.open_split",
            "browser.navigate",
            "browser.back",
            "browser.forward",
            "browser.reload",
        ]
        for method in methods {
            XCTAssertEqual(TerminalController.executionPolicy(forV2Method: method), .socketWorker, method)
        }
    }

    @MainActor
    func testWorkerAwaitAllowsMainQueueCallbackDelivery() {
        let controller = TerminalController.shared
        let done = expectation(description: "worker received callback")
        let heartbeat = expectation(description: "main queue remains available")
        DispatchQueue.global().async {
            let result: String? = controller.v2AwaitCallback(timeout: 2.0) { finish in
                DispatchQueue.main.async {
                    // Model a pending WebKit callback while unrelated main work runs.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        finish("cookie result")
                    }
                    DispatchQueue.main.async { heartbeat.fulfill() }
                }
            }
            XCTAssertEqual(result, "cookie result")
            done.fulfill()
        }
        wait(for: [heartbeat, done], timeout: 5.0)
    }

    // C11-311 B078: a clear request without a scope must not silently become
    // a profile-wide delete, and explicit `all` cannot be mixed with filters.
    func testCookieClearFilterRequiresAnUnambiguousScope() {
        XCTAssertNil(BrowserCookieClearFilter(params: [:]))
        XCTAssertNil(BrowserCookieClearFilter(params: ["all": false]))
        XCTAssertNil(BrowserCookieClearFilter(params: ["all": true, "name": "sid"]))
        XCTAssertNotNil(BrowserCookieClearFilter(params: ["all": true]))
        XCTAssertNotNil(BrowserCookieClearFilter(params: ["name": "sid"]))
    }

    // C11-311 B078: URL matching follows cookie domain/path/secure scope, not
    // substring matching that would include an unrelated host or path.
    func testCookieClearURLFilterMatchesCookieScope() {
        let filter = BrowserCookieClearFilter(params: [
            "url": "https://app.example.com/account/settings"
        ])!

        // A host-only parent cookie does not apply to its subdomains.
        XCTAssertFalse(filter.matches(makeCookie(domain: "example.com", path: "/account", secure: true)))
        // Host-only cookies match their exact host.
        XCTAssertTrue(filter.matches(makeCookie(domain: "app.example.com", path: "/account", secure: true)))
        // A leading dot marks a domain cookie, which applies to subdomains.
        XCTAssertTrue(filter.matches(makeCookie(domain: ".example.com", path: "/account", secure: true)))
        let parentHostFilter = BrowserCookieClearFilter(params: [
            "url": "https://example.com/account/settings"
        ])!
        XCTAssertTrue(parentHostFilter.matches(makeCookie(domain: "example.com", path: "/account", secure: true)))
        XCTAssertFalse(filter.matches(makeCookie(domain: "deep.app.example.com", path: "/account", secure: true)))
        XCTAssertFalse(filter.matches(makeCookie(domain: "notexample.com", path: "/account", secure: true)))
        XCTAssertFalse(filter.matches(makeCookie(domain: "example.com", path: "/accounts", secure: true)))
        XCTAssertFalse(filter.matches(makeCookie(domain: "example.com", path: "/account", secure: false)))
        XCTAssertTrue(filter.matches(makeCookie(domain: ".example.com", path: "/account", secure: false)))

        let httpFilter = BrowserCookieClearFilter(params: [
            "url": "http://app.example.com/account/settings"
        ])!
        XCTAssertFalse(httpFilter.matches(makeCookie(domain: ".example.com", path: "/account", secure: true)))
        XCTAssertFalse(httpFilter.matches(makeCookie(domain: "example.com", path: "/account", secure: false)))
        XCTAssertTrue(httpFilter.matches(makeCookie(domain: ".example.com", path: "/account", secure: false)))
    }

    private func makeCookie(domain: String, path: String, secure: Bool) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "session",
            .value: "value",
            .domain: domain,
            .path: path
        ]
        if secure {
            properties[.secure] = "TRUE"
        }
        return HTTPCookie(properties: properties)!
    }

    // MARK: - hasIssuedLoad

    @MainActor
    func testFreshWebViewHasNotIssuedALoad() {
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        XCTAssertFalse(webView.hasIssuedLoad)
        // The guard reads through this helper, which must agree.
        XCTAssertFalse(TerminalController.v2BrowserWebViewHasIssuedLoad(webView))
    }

    @MainActor
    func testMarkLoadIssuedFlipsThePredicate() {
        // `markLoadIssued()` is the entry point the navigation delegate uses for
        // navigations that never pass through the `load*` overrides — in-page
        // navigation, session restore, simulated requests. `BrowserNavigationDelegate`
        // is private to BrowserPanel.swift, so the delegate call itself is not
        // reachable from here; the live path is covered by the phase-4 validation.
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        XCTAssertFalse(webView.hasIssuedLoad)
        webView.markLoadIssued()
        XCTAssertTrue(webView.hasIssuedLoad)
    }

    @MainActor
    func testPlainWKWebViewIsTreatedAsLoaded() {
        // A view the app did not create cannot be interrogated, so the guard
        // must assume it works rather than invent a failure.
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        XCTAssertTrue(TerminalController.v2BrowserWebViewHasIssuedLoad(webView))
    }

    // MARK: - The nested pump, inside a real main-queue drain

    /// Runs `body` in the frame the wedge was captured in: a socket-worker queue
    /// hopping to main via `asyncAndWait`, so the pump runs inside an
    /// in-progress `_dispatch_main_queue_drain`.
    private func inMainQueueDrain(_ body: @escaping () -> Void) {
        let done = expectation(description: "drain frame completed")
        DispatchQueue(label: "c11-209-socket-worker").async {
            DispatchQueue.main.asyncAndWait {
                XCTAssertTrue(Thread.isMainThread)
                body()
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 10.0)
    }

    func testOffMainDeliveryResolvesThePump() {
        // The fix: a callback delivered from off the main thread now resolves
        // the main-thread await. Before C11-209 the flags were unsynchronised
        // and this route was not supported.
        var outcome: String??
        var elapsed: TimeInterval = 0
        inMainQueueDrain {
            let started = ProcessInfo.processInfo.systemUptime
            outcome = TerminalController.v2AwaitCallbackPumpingMainRunLoop(timeout: 3.0) { finish in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    finish("delivered")
                }
            }
            elapsed = ProcessInfo.processInfo.systemUptime - started
        }
        XCTAssertEqual(outcome ?? nil, "delivered")
        XCTAssertLessThan(elapsed, 1.5, "off-main delivery should resolve promptly, not at the deadline")
    }

    func testSynchronousDeliveryResolvesThePumpWithoutWaiting() {
        var outcome: String??
        inMainQueueDrain {
            outcome = TerminalController.v2AwaitCallbackPumpingMainRunLoop(timeout: 3.0) { finish in
                finish("immediate")
            }
        }
        XCTAssertEqual(outcome ?? nil, "immediate")
    }

    func testMainQueueDeliveryCannotResolveThePump() {
        // This is the constraint the shipped comment used to deny, and the
        // reason `browser.download.wait`'s three main-queue routes had to move.
        // libdispatch will not re-enter a main-queue drain already on the stack,
        // so this callback cannot run until the pump has already given up.
        var outcome: String??
        var elapsed: TimeInterval = 0
        inMainQueueDrain {
            let started = ProcessInfo.processInfo.systemUptime
            outcome = TerminalController.v2AwaitCallbackPumpingMainRunLoop(timeout: 0.4) { finish in
                DispatchQueue.main.async {
                    finish("should never arrive in time")
                }
            }
            elapsed = ProcessInfo.processInfo.systemUptime - started
        }
        XCTAssertNil(outcome ?? nil)
        XCTAssertGreaterThanOrEqual(elapsed, 0.4)
    }

    func testNeverFiredCallbackUnwindsAtTheDeadline() {
        var outcome: String??
        var elapsed: TimeInterval = 0
        inMainQueueDrain {
            let started = ProcessInfo.processInfo.systemUptime
            outcome = TerminalController.v2AwaitCallbackPumpingMainRunLoop(timeout: 0.4) { _ in }
            elapsed = ProcessInfo.processInfo.systemUptime - started
        }
        XCTAssertNil(outcome ?? nil)
        XCTAssertGreaterThanOrEqual(elapsed, 0.4)
        XCTAssertLessThan(elapsed, 2.0, "the deadline loop must unwind on time, not hang")
    }

    func testOnlyTheFirstResolutionWins() {
        var outcome: String??
        inMainQueueDrain {
            outcome = TerminalController.v2AwaitCallbackPumpingMainRunLoop(timeout: 3.0) { finish in
                DispatchQueue.global().async {
                    finish("first")
                    finish("second")
                }
            }
        }
        XCTAssertEqual(outcome ?? nil, "first")
    }
}
