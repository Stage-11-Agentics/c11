import AppKit
import JavaScriptCore
import WebKit
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-377: what a page may do on its own (N5 to N9), through the seams the
/// WebKit delegates call. No real DNS: every resolver here is a fake.
final class BrowserPageGuardTests: XCTestCase {
    private let own = ShowURLPolicy.OwnAddresses(names: ["laptop"], addresses: ["192.168.1.20", "fe80::1"])
    private var savedLookup: (@Sendable (String) -> [String]?)!

    override func setUp() {
        super.setUp()
        savedLookup = ShowHostResolver.lookup
    }

    override func tearDown() {
        ShowHostResolver.lookup = savedLookup
        ShowOwnAddresses.provider = nil
        super.tearDown()
    }

    // MARK: N6, N5: names judged by what they resolve to

    func testResolvedAnswersOnThisMacOrItsLinkAreRefused() {
        let refused: [[String]] = [
            ["127.0.0.1"], ["127.8.9.10"], ["::1"], ["0.0.0.0"], ["0.1.2.3"], ["::"], ["169.254.169.254"],
            ["fe80::abcd"], ["fe80::abcd%en0"], ["::ffff:127.0.0.1"], ["::ffff:169.254.1.1"], ["192.168.1.20"],
            ["203.0.113.5", "127.0.0.1"], ["not-an-address"],
        ]
        for answers in refused {
            XCTAssertNotNil(ShowURLPolicy.refusalForResolved(host: "probe.localtest.me", addresses: answers, own: own), "\(answers)")
        }
        for answers in [["203.0.113.5"], ["10.0.0.7"], ["192.168.1.21"], ["2001:db8::1"], ["203.0.113.5", "2001:db8::2"]] {
            XCTAssertNil(ShowURLPolicy.refusalForResolved(host: "studio", addresses: answers, own: own), "\(answers)")
        }
        // A name that does not resolve in time is refused, not waved through.
        XCTAssertNotNil(ShowURLPolicy.refusalForResolved(host: "slow.example", addresses: nil, own: own))
        XCTAssertNotNil(ShowURLPolicy.refusalForResolved(host: "slow.example", addresses: [], own: own))
    }

    func testLiteralLinkLocalAndAllOfZeroSlashEightAreRefused() {
        for url in ["http://169.254.169.254/", "http://0.1.2.3/", "http://[fe80::2]/", "http://[::ffff:169.254.1.1]/"] {
            XCTAssertNotNil(ShowURLPolicy.refusalForRemote(url, own: .empty), url)
        }
        XCTAssertNil(ShowURLPolicy.refusalForRemote("http://169.255.0.1/", own: .empty))
    }

    func testRelayedPreflightResolvesTheName() {
        ShowOwnAddresses.provider = { [own] in own }
        ShowHostResolver.lookup = { host in host.hasSuffix(".localtest.me") ? ["127.0.0.1"] : ["203.0.113.10"] }
        let remote = ShowOrigin.remote(machine: "peer", container: nil)
        XCTAssertNotNil(ShowPreflight.urlRefusal("http://probe.localtest.me:18080/", origin: remote))
        XCTAssertNotNil(ShowPreflight.urlRefusal("https://x.localtest.me/", origin: remote))
        XCTAssertNil(ShowPreflight.urlRefusal("https://example.com/page", origin: remote))
        // An address literal needs no lookup; a local show has no URL rule.
        XCTAssertNil(ShowPreflight.urlRefusal("http://203.0.113.9/", origin: remote))
        XCTAssertNil(ShowPreflight.urlRefusal("http://probe.localtest.me:18080/", origin: .local))
    }

    @MainActor
    func testGuardResolvesEveryHop() {
        final class Calls: @unchecked Sendable { var names: [String] = [] }
        let calls = Calls()
        var pageGuard = ShowPageGuard()
        pageGuard.ownAddresses = { .empty }
        pageGuard.resolve = { name in calls.names.append(name); return name == "redir.example" ? ["203.0.113.1"] : ["127.0.0.1"] }
        func decide(_ raw: String) -> String?? {
            let done = expectation(description: raw)
            var outcome: String?? = .none
            pageGuard.resolvedRefusal(for: URL(string: raw)!) { refusal in outcome = .some(refusal); done.fulfill() }
            wait(for: [done], timeout: 2)
            return outcome
        }
        XCTAssertEqual(decide("http://redir.example:18080/r2"), .some(nil))
        XCTAssertNotEqual(decide("http://probe.localtest.me:18080/"), .some(nil))   // the redirect hop
        XCTAssertNotEqual(decide("http://127.0.0.1:18080/"), .some(nil))
        XCTAssertEqual(decide("c11-show://peer/page.html"), .some(nil))
        XCTAssertEqual(calls.names, ["redir.example", "probe.localtest.me"])
    }

    // MARK: The connection pin

    /// The proxy's listening port. A start takes a free port number from a
    /// throwaway bind and then binds the listener to that number, so on a
    /// loaded host another socket can take the number in between and that
    /// start fails at once (C11H-402). The next start picks a new number, as a
    /// viewer's next pin does; these tests are about what a started proxy does.
    /// Remove this retry when C11H-403 binds the listener to port 0.
    private func startedPort(_ proxy: ShowGuardProxy) throws -> UInt16 {
        for _ in 0..<4 {
            if let port = proxy.ensureStarted() { return port }
        }
        return try XCTUnwrap(proxy.ensureStarted())
    }

    /// C11H-402: a start right after a failed one starts. The failed
    /// listener's callback used to wait on the proxy's lock on the listener
    /// queue, so the next start, holding that lock, waited out
    /// `startTimeout` for a callback queued behind it and returned nil. A
    /// port the echo fixture already listens on forces each failed start.
    ///
    /// A held start waits out `startTimeout` and then returns nil. A fresh number
    /// another socket took in between fails at once (C11H-403, 0.02 s under the
    /// gate's parallel load); only that is retried, as `startedPort` does, and the
    /// whole follow-up must finish inside one `startTimeout`. A follow-up that has
    /// used one `startTimeout` has failed: the test stops there, so a held start
    /// costs about two `startTimeout`s, never one per retry and round.
    func testAStartRightAfterAFailedOneIsNotHeldBehindIt() throws {
        let taken = try EchoFixture()
        defer { taken.close() }
        for round in 0..<5 {
            // The taken port first, then a number picked at the moment of each later start.
            let picks = PortPicks([taken.port])
            let proxy = ShowGuardProxy(policy: .init(resolve: { _ in nil }, isForbidden: { _ in true }),
                                       secret: "s3cret", portSource: { picks.next() ?? ShowGuardProxy.freeLoopbackPort() })
            defer { proxy.stop() }
            XCTAssertNil(proxy.ensureStarted(), "round \(round): a port already in use cannot be bound")
            let followUp = DispatchTime.now().uptimeNanoseconds
            var port: UInt16?
            var held: TimeInterval = 0
            for _ in 0..<4 {
                port = proxy.ensureStarted()
                held = Double(DispatchTime.now().uptimeNanoseconds - followUp) / 1e9
                if port != nil || held >= ShowGuardProxy.startTimeout { break }
            }
            XCTAssertNotNil(port, "round \(round): the next start starts")
            XCTAssertLessThan(held, ShowGuardProxy.startTimeout, "round \(round): the next start is not held behind the failed one")
            guard let port, held < ShowGuardProxy.startTimeout else { return }
            XCTAssertNotEqual(port, taken.port, "round \(round): the next start listens on a new port, not the failed one")
        }
    }

    func testProxyRefusesAForbiddenAnswerAndDialsNothing() throws {
        let fixture = try EchoFixture()
        defer { fixture.close() }
        let proxy = ShowGuardProxy(policy: .init(resolve: { _ in ["127.0.0.1"] }, isForbidden: { _ in true }), secret: "s3cret")
        defer { proxy.stop() }
        let port = try startedPort(proxy)
        let client = try SOCKSClient(port: port)
        defer { client.close() }
        XCTAssertEqual(try client.authenticate(user: ShowGuardProxy.username, password: "s3cret"), 0)
        XCTAssertEqual(try client.connect(name: "probe.localtest.me", port: fixture.port), ShowSOCKS.Reply.notAllowed.rawValue)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(fixture.accepted, 0)
    }

    func testProxyDialsTheAddressItCheckedAndNeverAsksAgain() throws {
        let fixture = try EchoFixture()
        defer { fixture.close() }
        final class Answers: @unchecked Sendable {
            var calls = 0
            func next() -> [String] { calls += 1; return calls == 1 ? ["127.0.0.1"] : ["198.51.100.66"] }
        }
        let answers = Answers()
        // Only the fixture's address is allowed here; a second lookup would
        // answer elsewhere, so the echo proves the first answer was dialed.
        let proxy = ShowGuardProxy(policy: .init(resolve: { _ in answers.next() }, isForbidden: { $0 != "127.0.0.1" }),
                                   secret: "s3cret")
        defer { proxy.stop() }
        let port = try startedPort(proxy)
        let client = try SOCKSClient(port: port)
        defer { client.close() }
        XCTAssertEqual(try client.authenticate(user: ShowGuardProxy.username, password: "s3cret"), 0)
        XCTAssertEqual(try client.connect(name: "fixture.example", port: fixture.port), ShowSOCKS.Reply.succeeded.rawValue)
        XCTAssertEqual(try client.roundTrip("ping"), "ping")
        XCTAssertEqual(answers.calls, 1)
        XCTAssertEqual(fixture.accepted, 1)
    }

    func testProxyNeedsItsSecret() throws {
        let proxy = ShowGuardProxy(policy: .init(resolve: { _ in ["203.0.113.1"] }, isForbidden: { _ in false }), secret: "s3cret")
        defer { proxy.stop() }
        let port = try startedPort(proxy)
        let client = try SOCKSClient(port: port)
        defer { client.close() }
        XCTAssertEqual(try client.authenticate(user: ShowGuardProxy.username, password: "guess"), 1)
        let noAuth = try SOCKSClient(port: port)
        defer { noAuth.close() }
        XCTAssertEqual(try noAuth.greet(methods: [0]), [5, 0xFF])
    }

    func testSOCKSRequestParsing() {
        XCTAssertEqual(ShowSOCKS.parseRequest([5, 1, 0, 3, 3, 0x61, 0x62, 0x63, 0x1F, 0x90]),
                       .done(.init(host: "abc", port: 8080, isName: true), consumed: 10))
        XCTAssertEqual(ShowSOCKS.parseRequest([5, 1, 0, 1, 127, 0, 0, 1, 0, 80]),
                       .done(.init(host: "127.0.0.1", port: 80, isName: false), consumed: 10))
        XCTAssertEqual(ShowSOCKS.parseRequest([5, 1, 0, 3, 3, 0x61]), .needMore)
        XCTAssertEqual(ShowSOCKS.parseRequest([5, 2, 0, 1, 127, 0, 0, 1, 0, 80]), .invalid)   // BIND
    }

    // MARK: N6: a viewer's plain-HTTP list

    // The pin's wiring: a linked machine's viewer connects only through the
    // guard proxy, never directly when the proxy fails. An ordinary panel's
    // store has no proxy.
    @MainActor
    func testAGuardedViewersStoreConnectsOnlyThroughTheGuardProxy() throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("proxy configurations need macOS 14") }
        _ = NSApplication.shared
        let viewer = BrowserPanel(workspaceId: UUID(), showViewer: viewerSession(.remote(machine: "studio", container: nil)))
        let pinned = viewer.webView.configuration.websiteDataStore.proxyConfigurations
        XCTAssertEqual(pinned.count, 1, "a linked machine's viewer connects without the guard proxy")
        XCTAssertEqual(pinned.first?.allowFailover, false, "the guard proxy falls back to a direct connection")
        let ordinary = BrowserPanel(workspaceId: UUID())
        XCTAssertEqual(ordinary.webView.configuration.websiteDataStore.proxyConfigurations.count, 0)
    }

    // c11's own favicon fetch would dial outside the pin, so a guarded viewer
    // starts none. An ordinary panel still does.
    @MainActor
    func testAGuardedViewerStartsNoFaviconFetchOfItsOwn() {
        _ = NSApplication.shared
        let page = URL(string: "https://example.com/shown")!
        func fetches(_ origin: ShowOrigin?) -> [URL] {
            let panel = BrowserPanel(workspaceId: UUID(), showViewer: origin.map { viewerSession($0) })
            var started: [URL] = []
            panel.faviconFetchRecorder = { started.append($0) }
            panel.refreshFavicon(from: panel.webView, pageURL: page)
            return started
        }
        XCTAssertEqual(fetches(.remote(machine: "studio", container: nil)), [], "a guarded viewer fetched its favicon itself")
        XCTAssertEqual(fetches(nil), [page], "an ordinary panel no longer fetches its favicon")
    }

    func testViewerPlainHTTPListDropsLocaltestMe() {
        XCTAssertFalse(BrowserInsecureHTTPSettings.isHostAllowed("probe.localtest.me", rawAllowlist: nil, forShowViewer: true))
        XCTAssertFalse(BrowserInsecureHTTPSettings.isHostAllowed("x.localtest.me", rawAllowlist: "*.localtest.me\nlocaltest.me", forShowViewer: true))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("localhost", rawAllowlist: nil, forShowViewer: true))
        // An ordinary panel keeps it: a c11 ssh workspace reaches its remote loopback through the alias.
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("c11-loopback.localtest.me", rawAllowlist: nil))
        XCTAssertFalse(browserShouldBlockInsecureHTTPURL(URL(string: "http://c11-loopback.localtest.me:3000/")!, rawAllowlist: nil))
        XCTAssertTrue(browserShouldBlockInsecureHTTPURL(URL(string: "http://probe.localtest.me:18080/")!, rawAllowlist: nil,
                                                        forShowViewer: true))
    }

    // MARK: N7: downloads

    func testShowViewerNeverDownloads() {
        let now = Date()
        XCTAssertEqual(BrowserDownloadPolicy.decide(isShowViewer: true, lastActivation: now, now: now), .refuseViewer)
        XCTAssertEqual(BrowserDownloadPolicy.decide(isShowViewer: true, lastActivation: nil, now: now), .refuseViewer)
    }

    func testDownloadNeedsRecentActivation() {
        let now = Date()
        XCTAssertEqual(BrowserDownloadPolicy.decide(isShowViewer: false, lastActivation: nil, now: now), .refuseNoActivation)
        XCTAssertEqual(BrowserDownloadPolicy.decide(isShowViewer: false, lastActivation: now.addingTimeInterval(-3), now: now), .allow)
        XCTAssertEqual(BrowserDownloadPolicy.decide(isShowViewer: false, lastActivation: now.addingTimeInterval(-11), now: now),
                       .refuseNoActivation)
        XCTAssertEqual(BrowserDownloadPolicy.decide(isShowViewer: false, lastActivation: now.addingTimeInterval(5), now: now),
                       .refuseNoActivation)
    }

    func testClosingCancelsEveryDownloadAndRemovesItsFile() throws {
        final class FakeDownload {}
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("c11h377-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let downloads = BrowserActiveDownloads<FakeDownload>()
        let first = FakeDownload(), second = FakeDownload()
        for (index, handle) in [first, second].enumerated() {
            let file = folder.appendingPathComponent("\(index).part")
            try Data("partial".utf8).write(to: file)
            XCTAssertTrue(downloads.add(.init(handle: handle, tempURL: file, suggestedFilename: "f")))
        }
        var cancelled: [ObjectIdentifier] = []
        let removed = downloads.cancelAll { cancelled.append(ObjectIdentifier($0)) }
        XCTAssertEqual(Set(cancelled), [ObjectIdentifier(first), ObjectIdentifier(second)])
        XCTAssertEqual(removed.count, 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        XCTAssertFalse(downloads.add(.init(handle: FakeDownload(), tempURL: folder.appendingPathComponent("late"), suggestedFilename: "f")))
    }

    // An agent only reading a page (get.title on main; snapshot, wait and
    // get.text on a worker) never opens the download window, so a page's own
    // timed download stays refused. A click or a reload aimed at the panel
    // opens it. Every call goes through the real command router.
    @MainActor
    func testOnlyAnAgentActingOnThePageOpensTheDownloadWindow() async throws {
        _ = NSApplication.shared
        let manager = WorkspaceManager()
        let workspace = manager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
        let pane = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        func browser() throws -> BrowserPanel {
            try XCTUnwrap(workspace.newBrowserSurface(inPane: pane, url: nil, focus: false, sticksAsPreferred: false))
        }
        let controller = TerminalController.makeForTesting()
        controller.setActiveWorkspaceManager(manager)
        func call(_ method: String, _ panel: BrowserPanel, _ extra: [String: Any] = [:]) async throws -> [String: Any] {
            let params = extra.merging(["workspace_id": workspace.id.uuidString, "surface_id": panel.id.uuidString]) { $1 }
            let data = try JSONSerialization.data(withJSONObject: ["id": 377, "method": method, "params": params])
            let command = String(decoding: data, as: UTF8.self)
            let response = await Task.detached { controller.processCommandUsingSocketExecutionPolicy(command) }.value
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        }
        func errorCode(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }
        func decision(_ panel: BrowserPanel) -> BrowserDownloadDecision {
            BrowserDownloadPolicy.decide(isShowViewer: false, lastActivation: panel.lastDownloadActivation, now: Date())
        }

        let watched = try browser()
        let title = try await call("browser.get.title", watched)
        XCTAssertEqual(title["ok"] as? Bool, true, "\(title)")
        // Each worker read reaches the panel: it is refused for having no
        // document, after the point where an acting command is stamped.
        let reads: [(String, [String: Any])] = [("browser.snapshot", [:]), ("browser.wait", [:]),
                                                ("browser.get.text", ["selector": "body"])]
        for (method, extra) in reads {
            let response = try await call(method, watched, extra)
            XCTAssertEqual(errorCode(response), "no_document", "\(method): \(response)")
        }
        XCTAssertNil(watched.lastDownloadActivation, "a read opened the download window")
        XCTAssertEqual(decision(watched), .refuseNoActivation)

        let clicked = try browser()
        let click = try await call("browser.click", clicked, ["selector": "#download"])
        XCTAssertEqual(errorCode(click), "no_document", "\(click)")
        XCTAssertEqual(decision(clicked), .allow, "an agent's click did not open the download window")
        let reloaded = try browser()
        let reload = try await call("browser.reload", reloaded)
        XCTAssertEqual(reload["ok"] as? Bool, true, "\(reload)")
        XCTAssertEqual(decision(reloaded), .allow, "an agent's reload did not open the download window")
    }

    // A show viewer's context menu offers no download, local or linked, so
    // neither the HTTP nor the data: route reaches a Save panel. An ordinary
    // panel keeps both items, routed through c11.
    @MainActor
    func testAShowViewersMenuOffersNoDownload() throws {
        _ = NSApplication.shared
        let downloadIDs = ["WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierDownloadImage"]
        let webKitActions = ["WKMenuItemIdentifierDownloadLinkedFile": NSSelectorFromString("downloadLinkToDisk:"),
                             "WKMenuItemIdentifierDownloadImage": NSSelectorFromString("downloadImageToDisk:")]
        func openMenu(_ origin: ShowOrigin?) throws -> (CmuxWebView, NSMenu) {
            let panel = BrowserPanel(workspaceId: UUID(), showViewer: origin.map { viewerSession($0) })
            let webView = try XCTUnwrap(panel.webView as? CmuxWebView)
            let menu = NSMenu()
            for (title, id) in zip(["Open Link", "Download Linked File", "Download Image"],
                                   ["WKMenuItemIdentifierOpenLink"] + downloadIDs) {
                let item = NSMenuItem(title: title, action: webKitActions[id], keyEquivalent: "")
                item.identifier = NSUserInterfaceItemIdentifier(id)
                menu.addItem(item)
            }
            let rightClick = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            webView.willOpenMenu(menu, with: rightClick)
            return (webView, menu)
        }
        for origin in [ShowOrigin.remote(machine: "studio", container: nil), .local] {
            let (_, menu) = try openMenu(origin)
            let ids = menu.items.compactMap { $0.identifier?.rawValue }
            XCTAssertTrue(ids.contains("WKMenuItemIdentifierOpenLink"), "\(origin): \(ids)")
            XCTAssertTrue(Set(ids).isDisjoint(with: downloadIDs), "a viewer's menu offers a download (\(origin)): \(ids)")
        }
        let (webView, menu) = try openMenu(nil)
        for id in downloadIDs {
            let item = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == id }, "an ordinary panel lost \(id)")
            XCTAssertTrue(item.target === webView, id)
            XCTAssertNotEqual(item.action, webKitActions[id], id)
        }
    }

    // MARK: N8: popups and dialogs

    func testPopupNeedsRecentOperatorInputOnScreen() {
        let now = Date()
        XCTAssertFalse(BrowserPopupPolicy.allows(lastOperatorInput: nil, onScreen: true, now: now))
        XCTAssertTrue(BrowserPopupPolicy.allows(lastOperatorInput: now.addingTimeInterval(-1), onScreen: true, now: now))
        XCTAssertFalse(BrowserPopupPolicy.allows(lastOperatorInput: now.addingTimeInterval(-1), onScreen: false, now: now))
        XCTAssertFalse(BrowserPopupPolicy.allows(lastOperatorInput: now.addingTimeInterval(-6), onScreen: true, now: now))
    }

    private func decideDialog(viewer: Bool = false, onScreen: Bool = true, focused: Bool = false, input: Date? = nil,
                              limiter: BrowserJSDialogRateLimiter = BrowserJSDialogRateLimiter(), now: Date) -> BrowserJSDialogDecision {
        BrowserJSDialogPolicy.decide(isShowViewer: viewer, onScreen: onScreen, operatorFocused: focused,
                                     lastOperatorInput: input, limiter: limiter, now: now)
    }

    func testShowViewerDialogResolvesAtOnce() {
        let now = Date()
        XCTAssertEqual(decideDialog(viewer: true, focused: true, input: now, now: now), .safeDefault(.showViewer))
    }

    func testDialogWaitsForAnOnScreenPageTheOperatorIsWith() {
        let now = Date()
        XCTAssertEqual(decideDialog(onScreen: false, focused: true, input: now, now: now), .queue)
        XCTAssertEqual(decideDialog(now: now), .queue)
        XCTAssertEqual(decideDialog(input: now.addingTimeInterval(-6), now: now), .queue)
        XCTAssertEqual(decideDialog(focused: true, now: now), .present)
        XCTAssertEqual(decideDialog(input: now.addingTimeInterval(-2), now: now), .present)
    }

    func testDialogsAreRateLimited() {
        let now = Date()
        var full = BrowserJSDialogRateLimiter()
        for offset in [-3.0, -2.0, -1.0] { full.record(now: now.addingTimeInterval(offset)) }
        XCTAssertEqual(decideDialog(focused: true, limiter: full, now: now), .safeDefault(.rateLimited))
        XCTAssertEqual(decideDialog(focused: true, limiter: full, now: now.addingTimeInterval(8)), .present)
    }

    @MainActor
    func testDialogGateWaitsForTheOperatorAndRateLimits() {
        var clock = Date()
        var onScreen = true, focused = false
        let gate = BrowserJSDialogGate(isShowViewer: false)
        gate.now = { clock }
        gate.onScreen = { _ in onScreen }
        gate.operatorFocused = { _ in focused }
        var notices = 0
        gate.showNotice = { _, _ in notices += 1 }
        let page = NSView()
        var presented = 0
        var answers: [NSApplication.ModalResponse] = []
        let present: BrowserJSDialogGate.Present = { done in presented += 1; done(.alertFirstButtonReturn) }
        func ask() {
            gate.request(for: page, safeDefault: .alertSecondButtonReturn, lastOperatorInput: nil, present: present) { answers.append($0) }
        }
        // Unfocused page: the dialog waits and nothing is shown.
        ask()
        XCTAssertEqual([presented, gate.waitingCount, notices, answers.count], [0, 1, 1, 0])
        // A second request while one waits resolves at once.
        ask()
        XCTAssertEqual(answers, [.alertSecondButtonReturn])
        // The operator clicks in the page: the waiting one is shown.
        gate.operatorDidInteract(with: page, at: clock)
        XCTAssertEqual([presented, gate.waitingCount], [1, 0])
        // Focused: two more are shown, the fourth in ten seconds is not.
        focused = true
        ask(); ask(); ask()
        XCTAssertEqual(presented, 3)
        XCTAssertEqual(answers.last, .alertSecondButtonReturn)
        clock = clock.addingTimeInterval(11)
        ask()
        XCTAssertEqual(presented, 4)
        // Off screen it waits; closing the panel answers the safe default.
        onScreen = false
        ask()
        XCTAssertEqual(gate.waitingCount, 1)
        gate.flush(page)
        XCTAssertEqual(gate.waitingCount, 0)
        XCTAssertEqual(answers.last, .alertSecondButtonReturn)
    }

    @MainActor
    func testShowViewerGateNeverPresents() {
        let gate = BrowserJSDialogGate(isShowViewer: true)
        gate.onScreen = { _ in true }
        gate.operatorFocused = { _ in true }
        var presented = false
        var answer: NSApplication.ModalResponse?
        gate.request(for: NSView(), safeDefault: .alertSecondButtonReturn, lastOperatorInput: Date(),
                     present: { _ in presented = true }) { answer = $0 }
        XCTAssertFalse(presented)
        XCTAssertEqual(answer, .alertSecondButtonReturn)
    }

    // A dialog waiting for the operator is answered exactly once, with its
    // safe default, when its page's web view is replaced (here a workspace
    // context reset; hibernate, a profile switch and reattach swap it the
    // same way) or the panel closes. A dialog from the new view still waits.
    @MainActor
    func testAReplacedOrClosedPageAnswersItsWaitingDialogOnce() {
        _ = NSApplication.shared
        let panel = BrowserPanel(workspaceId: UUID(), initialURL: URL(string: "https://example.com/page")!,
                                 pendingHibernate: true)
        let gate = panel.dialogGate
        gate.onScreen = { _ in false }
        gate.showNotice = { _, _ in }
        var answers: [String: [NSApplication.ModalResponse]] = [:]
        func ask(_ name: String) {
            gate.request(for: panel.webView, safeDefault: .alertSecondButtonReturn, lastOperatorInput: nil,
                         present: { _ in XCTFail("a hidden page's dialog was shown") }) { answers[name, default: []].append($0) }
        }
        ask("old")
        XCTAssertEqual(gate.waitingCount, 1)
        XCTAssertEqual(answers["old"], nil)
        let oldView = panel.webView
        panel.resetForWorkspaceContextChange(reason: "test")
        XCTAssertFalse(panel.webView === oldView, "the reset kept its web view")
        XCTAssertEqual(answers["old"], [.alertSecondButtonReturn], "the replaced page's dialog was not answered once")
        XCTAssertEqual(gate.waitingCount, 0)
        ask("new")
        XCTAssertEqual(gate.waitingCount, 1, "the new page's dialog did not wait")
        XCTAssertEqual(answers["new"], nil)
        panel.close()
        XCTAssertEqual(answers["new"], [.alertSecondButtonReturn], "closing did not answer the waiting dialog once")
        XCTAssertEqual(answers["old"], [.alertSecondButtonReturn])
        XCTAssertEqual(gate.waitingCount, 0)
    }

    func testServedPageCSPSandboxesTheDocument() throws {
        let directives = ShowPageGuard.contentSecurityPolicy.components(separatedBy: "; ")
        let sandbox = try XCTUnwrap(directives.first { $0.hasPrefix("sandbox") })
        XCTAssertEqual(sandbox.split(separator: " ").map(String.init), ["sandbox", "allow-scripts", "allow-same-origin"])
    }

    // MARK: N9: the focus script

    @MainActor
    func testFocusTrackingInstallsInC11sOwnWorld() {
        final class Sink: BrowserFocusTrackingSink {
            var scripts: [(world: String?, mainOnly: Bool)] = []
            var handlers: [(world: String?, name: String)] = []
            func addScript(_ source: String, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool, in world: WKContentWorld) {
                scripts.append((world.name, forMainFrameOnly))
            }
            func addHandler(_ handler: WKScriptMessageHandler, in world: WKContentWorld, name: String) {
                handlers.append((world.name, name))
            }
        }
        let sink = Sink()
        BrowserFocusTracking.install(into: sink, handler: BrowserFocusStateHandler())
        XCTAssertEqual(sink.scripts.map(\.world), ["c11-focus"])
        XCTAssertEqual(sink.scripts.map(\.mainOnly), [false])
        XCTAssertEqual(sink.handlers.map(\.world), ["c11-focus"])
        XCTAssertEqual(sink.handlers.map(\.name), [BrowserFocusTracking.handlerName])
    }

    func testFocusScriptReportsOnlyFocusToC11AndNothingToTheTopPage() throws {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in XCTFail("JS: \(exception?.toString() ?? "?")") }
        context.evaluateScript(Self.stubDOM)
        context.evaluateScript(BrowserFocusTracking.bootstrapScript)
        // A password field in a cross-origin frame takes focus, then four keys.
        context.evaluateScript("""
        var pw = makeField("input", "password"); document.activeElement = pw; fire("focusin", pw);
        for (var i = 1; i <= 4; i++) { pw.selectionStart = i; pw.selectionEnd = i; fire("input", pw); fire("selectionchange", pw); }
        """)
        XCTAssertEqual(context.evaluateScript("JSON.stringify(posted)").toString(), #"["{\"focused\":true}"]"#)
        XCTAssertEqual(context.evaluateScript("topPosts").toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("attributeWrites").toInt32(), 0)
        // c11 restores the field and its caret from the frame's own state.
        context.evaluateScript("document.activeElement = null; pw.selectionStart = 0; pw.selectionEnd = 0;")
        XCTAssertEqual(context.evaluateScript(BrowserFocusTracking.restoreScript).toString(), "restored")
        XCTAssertEqual(context.evaluateScript("[document.activeElement === pw, pw.selectionStart].join()").toString(), "true,4")
        // A click on something that is not a field clears it.
        context.evaluateScript(#"fire("mousedown", makeField("div", ""));"#)
        XCTAssertEqual(context.evaluateScript("posted[posted.length - 1]").toString(), #"{"focused":false}"#)
        XCTAssertEqual(context.evaluateScript(BrowserFocusTracking.restoreScript).toString(), "no_state")
    }

    func testFocusMessagesCarryOnlyWhetherAFieldIsFocused() {
        XCTAssertEqual(BrowserFocusTracking.focused(fromMessageBody: ["focused": true]), true)
        XCTAssertNil(BrowserFocusTracking.focused(fromMessageBody: ["selectionStart": 3]))
        let handler = BrowserFocusStateHandler()
        handler.note(focused: true, frame: nil)
        XCTAssertTrue(handler.hasFocusedField)
        handler.note(focused: false, frame: nil)
        XCTAssertFalse(handler.hasFocusedField)
    }

    @MainActor
    private func viewerSession(_ origin: ShowOrigin) -> ShowViewerSession {
        ShowViewerSession(caller: UUID(), source: .url("https://example.com/shown"), origin: origin, fetcher: nil, callerTitle: "A")
    }

    /// Just enough DOM for the focus script, with counters for what it must never do.
    private static let stubDOM = """
    var posted = [], topPosts = 0, attributeWrites = 0, listeners = {};
    function makeField(tag, type) {
      return { tagName: tag, type: type, isContentEditable: false, isConnected: true, selectionStart: 0, selectionEnd: 0,
               ownerDocument: document,
               setAttribute: function () { attributeWrites++; }, getAttribute: function () { return null; },
               focus: function () { document.activeElement = this; },
               matches: function () { return document.activeElement === this; },
               setSelectionRange: function (a, b) { this.selectionStart = a; this.selectionEnd = b; } };
    }
    var document = { activeElement: null, addEventListener: function (name, f) { (listeners[name] = listeners[name] || []).push(f); } };
    var window = { top: { postMessage: function () { topPosts++; } },
                   postMessage: function () { topPosts++; },
                   addEventListener: function (name, f) { (listeners["w:" + name] = listeners["w:" + name] || []).push(f); },
                   webkit: { messageHandlers: { c11FocusState: { postMessage: function (m) { posted.push(JSON.stringify(m)); } } } } };
    var parent = window.top;
    function fire(name, target) { (listeners[name] || []).forEach(function (f) { f({ target: target }); }); }
    """
}

// MARK: - Socket helpers (loopback only, disposable)

/// Hands out the given ports in order, then nil.
private final class PortPicks: @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [UInt16?]
    init(_ ports: [UInt16?]) { self.ports = ports }
    func next() -> UInt16? {
        lock.lock(); defer { lock.unlock() }
        return ports.isEmpty ? nil : ports.removeFirst()
    }
}

/// An echo server on 127.0.0.1 that counts the connections it accepts. Only
/// its accept thread uses and closes the listening socket, and `close` waits
/// for that thread: a thread still headed for `accept` on a closed fixture's
/// descriptor number would otherwise take and drop a connection meant for
/// whatever socket a later test opened under that number (C11H-402).
private final class EchoFixture {
    let port: UInt16
    private let state = State()
    private let finished = DispatchSemaphore(value: 0)
    var accepted: Int { state.read { $0.accepted } }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var accepted = 0
        private var stopping = false
        func read<T>(_ body: ((accepted: Int, stopping: Bool)) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body((accepted, stopping))
        }
        func countAccept() { lock.lock(); accepted += 1; lock.unlock() }
        func stop() { lock.lock(); stopping = true; lock.unlock() }
    }

    init() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Non-blocking, so a connection that resets between poll and accept
        // cannot park the accept thread where `close` would wait on it.
        _ = fcntl(sock, F_SETFL, fcntl(sock, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(sock, 8) == 0 else { Darwin.close(sock); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        let listener = sock, state = self.state, finished = self.finished
        Thread.detachNewThread {
            defer { Darwin.close(listener); finished.signal() }
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            while !state.read({ $0.stopping }) {
                guard poll(&ready, 1, 20) > 0 else { continue }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                state.countAccept()
                // An accepted socket inherits O_NONBLOCK; the echo loop blocks.
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                Thread.detachNewThread {
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while true {
                        let count = read(client, &buffer, buffer.count)
                        if count <= 0 { break }
                        _ = write(client, buffer, count)
                    }
                    Darwin.close(client)
                }
            }
        }
    }

    func close() {
        state.stop()
        finished.wait()
    }
}

private final class SOCKSClient {
    let fd: Int32

    init(port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        var opened: Int32 = -1
        for _ in 0..<20 {
            // A socket whose connect was refused cannot connect again: a fresh one each try.
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if connected == 0 { opened = sock; break }
            Darwin.close(sock)
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard opened >= 0 else { throw POSIXError(.ECONNREFUSED) }
        fd = opened
    }

    func send(_ bytes: [UInt8]) { _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) } }

    func receive(_ count: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: count)
        while out.count < count {
            let got = read(fd, &buffer, count - out.count)
            guard got > 0 else { throw POSIXError(.ETIMEDOUT) }
            out.append(contentsOf: buffer[0..<got])
        }
        return out
    }

    func greet(methods: [UInt8]) throws -> [UInt8] {
        send([5, UInt8(methods.count)] + methods)
        return try receive(2)
    }

    /// The RFC 1929 status: 0 accepted.
    func authenticate(user: String, password: String) throws -> UInt8 {
        guard try greet(methods: [2]) == [5, 2] else { return 0xFF }
        send([1, UInt8(user.utf8.count)] + Array(user.utf8) + [UInt8(password.utf8.count)] + Array(password.utf8))
        return try receive(2)[1]
    }

    /// The SOCKS reply code for CONNECT to a name.
    func connect(name: String, port: UInt16) throws -> UInt8 {
        send([5, 1, 0, 3, UInt8(name.utf8.count)] + Array(name.utf8) + [UInt8(port >> 8), UInt8(port & 0xff)])
        return try receive(10)[1]
    }

    func roundTrip(_ text: String) throws -> String {
        send(Array(text.utf8))
        return String(decoding: try receive(text.utf8.count), as: UTF8.self)
    }

    func close() { Darwin.close(fd) }
}
