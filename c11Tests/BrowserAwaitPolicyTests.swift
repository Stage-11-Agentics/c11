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
