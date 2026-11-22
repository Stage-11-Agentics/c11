import WebKit
import XCTest
@testable import c11

/// C11H-386: the guarded show viewer's own-address block. The rule tests read the serialised list
/// WebKit compiles, against URLs written as WebKit's URL parser writes them. The install tests
/// compile real lists in a temporary store and install them on real content controllers through
/// scripted address reads. The browser panel's held first load and WebKit's live blocking are proved
/// in the guest.
final class ShowViewerLoopbackBlockerRuleTests: XCTestCase {

    private func blocks(_ canonicalURL: String, own: Set<String> = []) -> Bool {
        ShowViewerLoopbackBlocker.blocks(
            canonicalURL: canonicalURL,
            ruleListJSON: ShowViewerLoopbackBlocker.ruleListJSON(ownAddresses: own)
        )
    }

    // MARK: - Static loopback (guard: staticHostPatterns loopback entries)

    func testLoopbackIsBlockedInEverySpelling() {
        // WebKit writes `2130706433`, `0x7f.1`, `0177.0.0.1` and `127.1` as 127.0.0.1 before matching.
        for host in ["127.0.0.1", "127.0.0.2", "127.255.255.254", "0.0.0.0",
                     "localhost", "localhost.", "sub.localhost", "ip6-localhost", "ip6-loopback"] {
            XCTAssertTrue(blocks("http://\(host):18386/x.png"), "expected \(host) blocked")
            XCTAssertTrue(blocks("https://\(host)/x"), "expected https \(host) blocked")
            XCTAssertTrue(blocks("ws://\(host):18386/s"), "expected ws \(host) blocked")
            XCTAssertTrue(blocks("http://user@\(host)/"), "expected userinfo \(host) blocked")
        }
        for host in ["[::1]", "[::]"] {
            XCTAssertTrue(blocks("http://\(host):18386/x.png"), "expected \(host) blocked")
        }
    }

    // MARK: - IPv4-mapped literals (guard: the \[::ffff:…\] pattern)

    func testEveryIPv4MappedLiteralIsBlocked() {
        // As WebKit writes them: [::ffff:192.168.64.6] is [::ffff:c0a8:4006], [::ffff:169.254.77.77]
        // is [::ffff:a9fe:4d4d], [::ffff:127.0.0.1] is [::ffff:7f00:1].
        XCTAssertTrue(blocks("http://[::ffff:c0a8:4006]:18386/x", own: ["192.168.64.6"]))
        XCTAssertTrue(blocks("http://[::ffff:a9fe:4d4d]/x"))
        XCTAssertTrue(blocks("http://[::ffff:7f00:1]/x"))
        XCTAssertTrue(blocks("http://[::ffff:0:0]/x"))
        XCTAssertTrue(blocks("wss://[::ffff:a01:203]/s"))
        // Mapped forms are blocked whether or not the IPv4 is this Mac's: no page needs one.
        XCTAssertTrue(blocks("http://[::ffff:c0a8:4007]/x", own: ["192.168.64.6"]))
    }

    // MARK: - Link-local (guard: the 169.254 and fe80::/10 patterns)

    func testLinkLocalIsBlockedAcrossTheWholeRange() {
        XCTAssertTrue(blocks("http://169.254.77.77:18386/x"))
        XCTAssertTrue(blocks("http://169.254.0.1/x"))
        for host in ["[fe80::1]", "[fe80::aede:48ff:fe00:1122]", "[fe90::1234]", "[fea0::1]", "[febf::1]"] {
            XCTAssertTrue(blocks("http://\(host):18386/x"), "expected \(host) blocked")
        }
        // Just outside fe80::/10.
        XCTAssertFalse(blocks("http://[fe7f::1]/x"))
        XCTAssertFalse(blocks("http://[fec0::1]/x"))
    }

    // MARK: - This Mac's own interface addresses (guard: ownAddressPattern inclusion)

    func testOwnInterfaceAddressesAreBlockedOnlyWhenKnown() {
        let own: Set<String> = ["192.168.64.6", "10.1.2.3", "fd00:dead:beef::aabb:ccdd"]
        XCTAssertTrue(blocks("http://192.168.64.6:18386/x", own: own))
        XCTAssertTrue(blocks("http://10.1.2.3/x", own: own))
        XCTAssertTrue(blocks("http://[fd00:dead:beef::aabb:ccdd]:8080/x", own: own))
        // The same addresses, when they are not this Mac's, are a real remote host.
        XCTAssertFalse(blocks("http://192.168.64.6:18386/x"))
        XCTAssertFalse(blocks("http://10.1.2.3/x"))
        XCTAssertFalse(blocks("http://[fd00:dead:beef::aabb:ccdd]/x"))
    }

    func testOwnIPv6IsWrittenAsWebKitWritesTheHost() {
        // However the address read spells it, the rule names the host WebKit matches.
        XCTAssertTrue(blocks("http://[fd00:dead:beef::aabb:ccdd]/x", own: ["FD00:DEAD:BEEF:0:0:0:AABB:CCDD"]))
        XCTAssertTrue(blocks("http://[fd00:dead:beef::aabb:ccdd]/x", own: ["fd00:dead:beef:0000::aabb:ccdd%en0"]))
        let pairs: [(String, String)] = [
            ("2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1"),
            ("2001:db8:0:1:0:0:0:1", "2001:db8:0:1::1"),
            ("2001:db8:1:2:3:4:5:6", "2001:db8:1:2:3:4:5:6"),
            ("2001:db8:0:1:2:3:4:5", "2001:db8:0:1:2:3:4:5"),
            ("0:0:0:0:0:0:0:0", "::"),
            ("fe80:0:0:0:0:0:0:1", "fe80::1"),
            ("1:0:0:0:0:0:0:0", "1::"),
        ]
        for (input, written) in pairs {
            let bytes = ShowURLPolicy.ipv6(input)
            XCTAssertEqual(bytes.map(ShowViewerLoopbackBlocker.urlHostIPv6), written, input)
        }
        XCTAssertNil(ShowViewerLoopbackBlocker.ownAddressPattern("not-an-address"))
    }

    // MARK: - Allowed destinations stay allowed

    func testOrdinaryRemoteHostsAreNotBlocked() {
        for url in ["https://example.com/page", "http://93.184.216.34/x", "https://cdn.example.net:8443/a.css",
                    "http://192.0.2.10/x", "http://[2001:db8::1]/x", "https://example.com/?next=http://127.0.0.1/",
                    "c11-show://localhost/file"] {
            XCTAssertFalse(blocks(url, own: ["192.168.64.6"]), "expected \(url) allowed")
        }
    }

    // MARK: - The seam reads what WebKit compiles

    func testSeamFollowsTheSerialisedActionsAndTriggers() {
        let url = "http://127.0.0.1/x"
        let filter = #"^https?://127[.]"#
        func rules(_ list: [[String: Any]]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]), as: UTF8.self)
        }
        XCTAssertTrue(ShowViewerLoopbackBlocker.blocks(canonicalURL: url, ruleListJSON: rules([
            ["trigger": ["url-filter": filter], "action": ["type": "block"]],
        ])))
        // An action that is not a block, a trigger narrowed to one load type, or a later
        // ignore-previous-rules does not block every load.
        XCTAssertFalse(ShowViewerLoopbackBlocker.blocks(canonicalURL: url, ruleListJSON: rules([
            ["trigger": ["url-filter": filter], "action": ["type": "css-display-none", "selector": "img"]],
        ])))
        XCTAssertFalse(ShowViewerLoopbackBlocker.blocks(canonicalURL: url, ruleListJSON: rules([
            ["trigger": ["url-filter": filter, "resource-type": ["image"]], "action": ["type": "block"]],
        ])))
        XCTAssertFalse(ShowViewerLoopbackBlocker.blocks(canonicalURL: url, ruleListJSON: rules([
            ["trigger": ["url-filter": filter], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*"], "action": ["type": "ignore-previous-rules"]],
        ])))
    }

    // MARK: - WebKit compiles it, under one identifier

    func testRuleListCompilesInWebKitUnderOneIdentifier() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("c11-own-address-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        for own in [Set(["192.168.64.6", "fd00:dead:beef::1"]), Set(["10.1.2.3"])] {
            let compiled = expectation(description: "compile")
            var list: WKContentRuleList?
            ShowViewerLoopbackBlocker.compile(ShowViewerLoopbackBlocker.ruleListJSON(ownAddresses: own), in: store) {
                list = $0
                compiled.fulfill()
            }
            wait(for: [compiled], timeout: 15)
            XCTAssertEqual(list?.identifier, ShowViewerLoopbackBlocker.identifier, "WebKit refused the list for \(own)")
        }
        // A second address set overwrites the first: the store keeps one list, not one per set.
        let listed = expectation(description: "identifiers")
        var identifiers: [String]?
        store.getAvailableContentRuleListIdentifiers {
            identifiers = $0
            listed.fulfill()
        }
        wait(for: [listed], timeout: 15)
        XCTAssertEqual(identifiers, [ShowViewerLoopbackBlocker.identifier])
    }
}

/// The install and refresh state machine, with real lists on real content controllers.
@MainActor
final class ShowViewerLoopbackBlockerInstallTests: XCTestCase {

    /// A scripted address read: each call takes the next set; the last one repeats.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var sets: [Set<String>]
        private var calls = 0

        init(_ sets: [Set<String>]) { self.sets = sets }

        func next() -> Set<String> {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return sets.count > 1 ? sets.removeFirst() : sets[0]
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    /// Compiles into a temporary store, either at once or when the test releases each request.
    @MainActor
    private final class Compiler {
        let store: WKContentRuleListStore
        var deferred = false
        /// Request numbers (from 1) that fail instead of compiling.
        var failing: Set<Int> = []
        private(set) var requests: [String] = []
        private var waiting: [Int: (String, (WKContentRuleList?) -> Void)] = [:]

        init(store: WKContentRuleListStore) { self.store = store }

        func compile(_ encoded: String, _ completion: @escaping (WKContentRuleList?) -> Void) {
            requests.append(encoded)
            let number = requests.count
            if deferred {
                waiting[number] = (encoded, completion)
            } else {
                finish(number, encoded, completion)
            }
        }

        func release(_ number: Int) {
            guard let (encoded, completion) = waiting.removeValue(forKey: number) else { return }
            finish(number, encoded, completion)
        }

        private func finish(_ number: Int, _ encoded: String, _ completion: @escaping (WKContentRuleList?) -> Void) {
            if failing.contains(number) {
                DispatchQueue.main.async { completion(nil) }
            } else {
                ShowViewerLoopbackBlocker.compile(encoded, in: store, completion: completion)
            }
        }
    }

    private let a: Set<String> = ["127.0.0.1", "::1", "192.168.64.6"]
    private let ab: Set<String> = ["127.0.0.1", "::1", "192.168.64.6", "10.77.0.2"]
    private var folder: URL!
    private var compiler: Compiler!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("c11-own-address-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        compiler = Compiler(store: try XCTUnwrap(WKContentRuleListStore(url: folder)))
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func makeBlocker(_ reads: Reads, retryDelay: TimeInterval = 0.05) -> ShowViewerLoopbackBlocker {
        let compiler: Compiler = self.compiler
        return ShowViewerLoopbackBlocker(seams: .init(
            readAddresses: { reads.next() },
            compile: { encoded, completion in compiler.compile(encoded, completion) },
            retryDelay: retryDelay,
            watchesInterfaces: false
        ))
    }

    private func waitUntil(_ condition: () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(condition(), "timed out: \(message)", file: file, line: line)
    }

    /// Runs main briefly, for checks that something does not happen.
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

    private func install(_ blocker: ShowViewerLoopbackBlocker, _ controller: WKUserContentController) -> Bool? {
        var result: Bool?
        blocker.install(into: controller) { result = $0 }
        waitUntil({ result != nil }, "install completion")
        return result
    }

    func testInstallHoldsTheListForTheSetItRead() {
        let blocker = makeBlocker(Reads([a]))
        let controller = WKUserContentController()
        XCTAssertEqual(install(blocker, controller), true)
        XCTAssertEqual(blocker.installedAddresses(on: controller), a)
        XCTAssertEqual(blocker.registeredCount, 1)
    }

    // Guard: an empty read is a failed read, never a ready list.
    func testEmptyReadAtInstallLoadsNothing() {
        let blocker = makeBlocker(Reads([[]]))
        let controller = WKUserContentController()
        XCTAssertEqual(install(blocker, controller), false)
        XCTAssertNil(blocker.installedAddresses(on: controller))
        XCTAssertTrue(compiler.requests.isEmpty, "a list was compiled for an empty read")
    }

    func testFailedCompileAtInstallLoadsNothing() {
        compiler.failing = [1]
        let blocker = makeBlocker(Reads([a]))
        let controller = WKUserContentController()
        XCTAssertEqual(install(blocker, controller), false)
        XCTAssertNil(blocker.installedAddresses(on: controller))
    }

    // Guard: a set read while the first install compiles is the one the viewer gets (route 1).
    func testChangeDuringFirstInstallInstallsTheNewerSet() {
        compiler.deferred = true
        let blocker = makeBlocker(Reads([a, ab]))
        let controller = WKUserContentController()
        var result: Bool?
        blocker.install(into: controller) { result = $0 }
        waitUntil({ compiler.requests.count == 1 }, "first compile requested")
        blocker.refresh()
        waitUntil({ blocker.latestGeneration == 2 }, "the interface change read")
        compiler.release(1)
        waitUntil({ compiler.requests.count == 2 }, "the newer set compiles next")
        settle()
        XCTAssertNil(result, "the install completed with the older set")
        XCTAssertTrue(compiler.requests[1].contains(#"10[.]77[.]0[.]2"#))
        compiler.release(2)
        waitUntil({ result != nil }, "install completion")
        XCTAssertEqual(result, true)
        XCTAssertEqual(blocker.installedAddresses(on: controller), ab)
    }

    // Guard: a newer set one viewer's install reads is swapped onto every open viewer (route 2).
    func testSecondViewersNewerSetReachesTheFirst() {
        let blocker = makeBlocker(Reads([a, ab]))
        let first = WKUserContentController()
        let second = WKUserContentController()
        XCTAssertEqual(install(blocker, first), true)
        XCTAssertEqual(blocker.installedAddresses(on: first), a)
        XCTAssertEqual(install(blocker, second), true)
        XCTAssertEqual(blocker.installedAddresses(on: second), ab)
        XCTAssertEqual(blocker.installedAddresses(on: first), ab, "the first viewer kept the old list")
    }

    func testRefreshSwapsEveryOpenViewerAndDropsClosedOnes() throws {
        let reads = Reads([a, a, a, ab])
        let blocker = makeBlocker(reads)
        let first = WKUserContentController()
        let second = WKUserContentController()
        XCTAssertEqual(install(blocker, first), true)
        XCTAssertEqual(install(blocker, second), true)
        weak var closedProbe: WKUserContentController?
        autoreleasepool {
            let closed = WKUserContentController()
            closedProbe = closed
            XCTAssertEqual(install(blocker, closed), true)
        }
        try XCTSkipIf(closedProbe != nil, "the closed viewer's controller outlived its last reference")
        blocker.refresh()
        waitUntil({ blocker.installedAddresses(on: first) == ab }, "refresh swap")
        XCTAssertEqual(blocker.installedAddresses(on: second), ab)
        XCTAssertEqual(blocker.registeredCount, 2)
    }

    // Guard: a failed refresh read keeps every viewer's list, then reads again.
    func testEmptyRefreshReadKeepsTheListAndRetries() {
        let reads = Reads([a, [], ab])
        let blocker = makeBlocker(reads, retryDelay: 0.5)
        let controller = WKUserContentController()
        XCTAssertEqual(install(blocker, controller), true)
        blocker.refresh()
        waitUntil({ reads.count >= 2 }, "refresh read")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(blocker.installedAddresses(on: controller), a, "an empty read replaced the list")
        waitUntil({ blocker.installedAddresses(on: controller) == ab }, "retry after the empty read")
    }

    func testFailedRefreshCompileKeepsTheListAndRetries() {
        compiler.failing = [2]
        let blocker = makeBlocker(Reads([a, ab]), retryDelay: 0.5)
        let controller = WKUserContentController()
        XCTAssertEqual(install(blocker, controller), true)
        blocker.refresh()
        waitUntil({ compiler.requests.count >= 2 }, "refresh compile")
        XCTAssertEqual(blocker.installedAddresses(on: controller), a)
        waitUntil({ blocker.installedAddresses(on: controller) == ab }, "retry after the failed compile")
        XCTAssertGreaterThanOrEqual(compiler.requests.count, 3)
    }

    func testViewerClosedBeforeTheListIsReadyIsAnsweredFalse() throws {
        compiler.deferred = true
        let blocker = makeBlocker(Reads([a]))
        var result: Bool?
        weak var probe: WKUserContentController?
        autoreleasepool {
            let controller = WKUserContentController()
            probe = controller
            blocker.install(into: controller) { result = $0 }
        }
        waitUntil({ compiler.requests.count == 1 }, "compile requested")
        try XCTSkipIf(probe != nil, "the controller outlived its last reference")
        compiler.release(1)
        waitUntil({ result != nil }, "install completion")
        XCTAssertEqual(result, false)
        XCTAssertEqual(blocker.registeredCount, 0)
    }
}

/// The browser panel's one load gate (C11H-386 with #370's c11 ssh hold).
final class BrowserLoadGateTests: XCTestCase {
    private typealias Gate = BrowserLoadGate<String>

    private func state(remote: Bool = true, endpoint: Bool = false, remoteList: Bool = false,
                       guarded: Bool = true, showList: Bool = false) -> Gate.State {
        Gate.State(usesRemoteWorkspaceProxy: remote, remoteEndpointReady: endpoint, remoteLoopbackBlockReady: remoteList,
                   guardedShowViewer: guarded, showViewerBlockReady: showList)
    }

    // Guard: a load queued for a c11 ssh workspace resumes only once the show list is in too.
    func testRemoteQueuedLoadResumesOnlyOnceBothHoldsAreIn() {
        var gate = Gate()
        XCTAssertNil(gate.admit("page", in: state()))
        XCTAssertEqual(gate.heldFor, .remoteWorkspace)
        // The broker and its loopback list come in; the show list is still compiling.
        XCTAssertNil(gate.resume(in: state(endpoint: true, remoteList: true)))
        XCTAssertEqual(gate.heldFor, .showViewerBlock)
        XCTAssertEqual(gate.held, "page")
        XCTAssertEqual(gate.resume(in: state(endpoint: true, remoteList: true, showList: true)), "page")
        XCTAssertNil(gate.held)
    }

    func testShowListFirstStillWaitsForTheBroker() {
        var gate = Gate()
        XCTAssertNil(gate.admit("page", in: state()))
        XCTAssertNil(gate.resume(in: state(showList: true)))
        XCTAssertEqual(gate.heldFor, .remoteWorkspace)
        XCTAssertEqual(gate.resume(in: state(endpoint: true, remoteList: true, showList: true)), "page")
    }

    func testAGuardedViewerWithoutItsListNeverLoadsAndTheNewestLoadWaits() {
        var gate = Gate()
        let ready = state(remote: false)
        XCTAssertNil(gate.admit("first", in: ready))
        XCTAssertNil(gate.resume(in: ready))
        XCTAssertNil(gate.admit("second", in: ready))
        XCTAssertEqual(gate.held, "second")
        XCTAssertEqual(gate.resume(in: state(remote: false, showList: true)), "second")
    }

    func testALoadHeldForAWorkspaceResumesOnlyThroughItsBroker() {
        var gate = Gate()
        XCTAssertNil(gate.admit("page", in: state(guarded: false)))
        // The panel left the c11 ssh workspace with no broker: #370 keeps the load held.
        XCTAssertNil(gate.resume(in: state(remote: false, guarded: false)))
        XCTAssertEqual(gate.resume(in: state(remote: false, endpoint: true, guarded: false)), "page")
    }

    func testAnOrdinaryPanelLoadsAtOnce() {
        var gate = Gate()
        XCTAssertEqual(gate.admit("page", in: state(remote: false, guarded: false)), "page")
        XCTAssertNil(gate.held)
        gate.holdIfIdle("taken-down", for: .remoteWorkspace)
        XCTAssertEqual(gate.held, "taken-down")
        gate.holdIfIdle("later", for: .remoteWorkspace)
        XCTAssertEqual(gate.held, "taken-down")
    }
}

/// C11H-390: WebKit keeps a content controller alive while it holds a script message handler, so a
/// browser configuration's controller is freed only once nothing holds its handler lease. Each case
/// makes the real objects inside a pool, keeps only weak probes (checked while the objects lived),
/// drains the main run loop briefly, and asserts the controller is gone.
@MainActor
final class BrowserConfigurationReleaseTests: XCTestCase {
    private static let guarded = ShowOrigin.remote(machine: "studio", container: nil)

    private func viewerSession(_ origin: ShowOrigin) -> ShowViewerSession {
        ShowViewerSession(caller: UUID(), source: .url("https://example.com/shown"), origin: origin, fetcher: nil, callerTitle: "A")
    }

    /// Its own pool, so what main-queue work autoreleases while it runs is freed here, not when the
    /// test returns.
    private func drainMainRunLoop() {
        autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
    }

    /// c11's shared process pool keeps the page it closed last, with its controller, until the
    /// next page made in that pool closes: one slot, not a leak. Closing one more page here frees
    /// that slot, so the probe sees only what still holds the case's own controller.
    private func closeOneMorePageInTheSharedPool() {
        drainMainRunLoop()
        autoreleasepool {
            let config = BrowserPanel.makeConfiguration(profileID: UUID(), websiteDataStore: .nonPersistent())
            let page = WKWebView(frame: .zero, configuration: config)
            withExtendedLifetime(page) {}
        }
        drainMainRunLoop()
    }

    private func label(_ origin: ShowOrigin?) -> String {
        switch origin {
        case nil: return "no viewer"
        case .local?: return "local viewer"
        case .remote?: return "guarded viewer"
        }
    }

    private func assertConfigurationControllerIsFreed(_ origin: ShowOrigin?, makesWebView: Bool,
                                                      file: StaticString = #filePath, line: UInt = #line) {
        weak var controller: WKUserContentController?
        weak var webView: WKWebView?
        weak var session: ShowViewerSession?
        autoreleasepool {
            let viewer = origin.map { viewerSession($0) }
            let config = BrowserPanel.makeConfiguration(profileID: UUID(), websiteDataStore: viewer?.dataStore ?? .nonPersistent(),
                                                        showViewer: viewer)
            controller = config.userContentController
            session = viewer
            if makesWebView {
                let made = WKWebView(frame: .zero, configuration: config)
                webView = made
                XCTAssertNotNil(webView, file: file, line: line)
            }
            XCTAssertNotNil(controller, "the probe was never set", file: file, line: line)
        }
        if makesWebView { closeOneMorePageInTheSharedPool() } else { drainMainRunLoop() }
        let what = "\(label(origin)), \(makesWebView ? "with" : "without") a web view"
        XCTAssertNil(webView, "the web view outlived its last owner (\(what))", file: file, line: line)
        if origin != nil { XCTAssertNil(session, "the viewer session outlived its last owner (\(what))", file: file, line: line) }
        XCTAssertNil(controller, "makeConfiguration's content controller outlived every owner (\(what))", file: file, line: line)
    }

    func testAConfigurationsControllerIsFreedWithoutAWebView() {
        _ = NSApplication.shared
        for origin in [nil, ShowOrigin.local, Self.guarded] {
            assertConfigurationControllerIsFreed(origin, makesWebView: false)
        }
    }

    func testAConfigurationsControllerIsFreedWithItsWebView() {
        _ = NSApplication.shared
        for origin in [nil, ShowOrigin.local, Self.guarded] {
            assertConfigurationControllerIsFreed(origin, makesWebView: true)
        }
    }

    func testAClosedPanelsControllerIsFreed() {
        _ = NSApplication.shared
        for origin in [nil, Self.guarded] {
            weak var controller: WKUserContentController?
            weak var webView: WKWebView?
            weak var panel: BrowserPanel?
            autoreleasepool {
                let made = BrowserPanel(workspaceId: UUID(), showViewer: origin.map { viewerSession($0) })
                panel = made
                webView = made.webView
                controller = made.webView.configuration.userContentController
                XCTAssertNotNil(controller, "the probe was never set")
                made.close()
            }
            closeOneMorePageInTheSharedPool()
            XCTAssertNil(panel, "the closed panel outlived its last owner (\(label(origin)))")
            XCTAssertNil(webView, "the closed panel's web view outlived it (\(label(origin)))")
            XCTAssertNil(controller, "the closed panel's content controller outlived it (\(label(origin)))")
        }
    }

    // The lease belongs to the web view, not to the configuration it was made from: once the
    // configuration is gone, the open panel's page still reaches c11's focus handler.
    func testAnOpenPanelsFocusHandlerStillHearsItsPage() {
        _ = NSApplication.shared
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        guard let handler = (panel.webView as? CmuxWebView)?.focusStateHandler else { return XCTFail("the panel has no focus handler") }
        drainMainRunLoop()
        XCTAssertTrue(focusReport(from: panel.webView, reaches: handler), "the page's focus report never reached c11's handler")
    }

    /// Loads a page with a field into `webView` and fires `focusin` on it until c11's focus
    /// handler hears it, for up to 10 s. The report goes through the content controller's script
    /// message handler, so it arrives only while that handler is installed.
    private func focusReport(from webView: WKWebView, reaches handler: BrowserFocusStateHandler) -> Bool {
        webView.loadHTMLString("<html><body><input id=\"f\"></body></html>", baseURL: URL(string: "https://c11-fixture.example/"))
        let focusIn = "(() => { const f = document.getElementById('f'); "
            + "if (f) f.dispatchEvent(new FocusEvent('focusin', { bubbles: true })); return 0; })();"
        let deadline = Date().addingTimeInterval(10)
        while !handler.hasFocusedField, Date() < deadline {
            webView.evaluateJavaScript(focusIn, completionHandler: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        return handler.hasFocusedField
    }

    /// Opens a popup through `createFloatingPopup`, the path `window.open` takes, without a window
    /// on screen. WebKit hands a popup a configuration that shares its opener's content controller;
    /// the opener's own configuration does the same here, and the test checks that it does.
    private func openHiddenPopup(from panel: BrowserPanel, file: StaticString = #filePath, line: UInt = #line) -> WKWebView? {
        let saved = BrowserPopupWindowController.presentsWindows
        BrowserPopupWindowController.presentsWindows = false
        defer { BrowserPopupWindowController.presentsWindows = saved }
        let opener = panel.webView
        let popup = panel.createFloatingPopup(configuration: opener.configuration, windowFeatures: WKWindowFeatures())
        XCTAssertNotNil(popup?.window, "the popup has no window", file: file, line: line)
        XCTAssertTrue(popup?.configuration.userContentController === opener.configuration.userContentController,
                      "the popup does not share its opener's content controller", file: file, line: line)
        return popup
    }

    // REPAIR-1: a profile switch or a workspace context reset replaces the opener's web view and
    // leaves its popups open. The popup still holds the shared controller's lease, so its page
    // still reaches c11's handlers, and the controller is freed only once the popup goes too.
    // Everything is made inside a pool: AppKit autoreleases a web view while making it, and the
    // test's own pool would keep the opener alive until the test returns.
    func testAPopupKeepsTheSharedHandlersWhenItsOpenerIsReplaced() {
        _ = NSApplication.shared
        weak var controller: WKUserContentController?
        weak var opener: WKWebView?
        weak var popup: WKWebView?
        var panel: BrowserPanel?
        var handler: BrowserFocusStateHandler?
        var popupView: WKWebView?
        autoreleasepool {
            let made = BrowserPanel(workspaceId: UUID(), initialURL: URL(string: "https://example.com/opener")!,
                                    pendingHibernate: true)
            panel = made
            opener = made.webView
            controller = made.webView.configuration.userContentController
            handler = (made.webView as? CmuxWebView)?.focusStateHandler
            popupView = openHiddenPopup(from: made)
            popup = popupView
        }
        autoreleasepool {
            panel?.resetForWorkspaceContextChange(reason: "test")
            XCTAssertFalse(panel?.webView === opener, "the reset kept the opener's web view")
        }
        closeOneMorePageInTheSharedPool()
        XCTAssertNil(opener, "the replaced opener's web view outlived its replacement")
        autoreleasepool {
            guard let handler, let popupView else { return XCTFail("no focus handler or no popup") }
            XCTAssertTrue(focusReport(from: popupView, reaches: handler),
                          "the popup's page lost c11's handlers when its opener's web view was replaced")
            popupView.window?.close()
        }
        autoreleasepool {
            popupView = nil
            handler = nil
        }
        closeOneMorePageInTheSharedPool()
        XCTAssertNil(popup, "the closed popup's web view outlived it")
        XCTAssertNil(controller, "the shared controller outlived the popup, its last holder")
        autoreleasepool {
            panel?.close()
            panel = nil
        }
    }

    // REPAIR-1, the other order: closing the popup first leaves the open opener's handlers
    // callable, and the shared controller is freed once the opener closes.
    func testClosingAPopupFirstLeavesItsOpenersHandlers() {
        _ = NSApplication.shared
        weak var controller: WKUserContentController?
        weak var popup: WKWebView?
        weak var opener: BrowserPanel?
        autoreleasepool {
            let panel = BrowserPanel(workspaceId: UUID())
            opener = panel
            controller = panel.webView.configuration.userContentController
            autoreleasepool {
                let made = openHiddenPopup(from: panel)
                popup = made
                made?.window?.close()
            }
            closeOneMorePageInTheSharedPool()
            XCTAssertNil(popup, "the closed popup's web view outlived it")
            guard let handler = (panel.webView as? CmuxWebView)?.focusStateHandler else { return XCTFail("the panel has no focus handler") }
            XCTAssertTrue(focusReport(from: panel.webView, reaches: handler), "closing the popup took its opener's handlers")
            panel.close()
        }
        closeOneMorePageInTheSharedPool()
        XCTAssertNil(opener, "the closed opener outlived its last owner")
        XCTAssertNil(controller, "the shared controller outlived the popup and its opener")
    }
}
