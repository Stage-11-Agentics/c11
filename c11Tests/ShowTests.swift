import XCTest
import Darwin
import WebKit
import AppKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// C11H-228: `c11 show`. Pure rules, the fetchers against real files, the
// live-reload poller with a fake machine, and the load judge.

/// Runs the remote fetcher's argv on this Mac, as hc's `machine.exec` would
/// on the far machine, so the shell program itself is under test.
private final class LocalExecHost: ShowExecHost, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }

    func showExec(machine: String, argv: [String], timeout: TimeInterval) async throws -> ShowExecResult {
        lock.lock(); _calls.append(argv); lock.unlock()
        let process = Process()
        // As hc does: the program is found on PATH, the argv passed as given.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShowExecResult(code: process.terminationReason == .exit ? process.terminationStatus : nil, stdout: data)
    }
}

/// A host that never runs anything (argv shape tests).
private struct LocalExecHostForGate: ShowExecHost {
    func showExec(machine: String, argv: [String], timeout: TimeInterval) async throws -> ShowExecResult {
        ShowExecResult(code: 1, stdout: Data())
    }
}

/// A machine whose file changes when the test says, counting every call.
private final class FakeFetcher: ShowFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var stat_ = ShowFileStat(size: 10, mtime: "1.0")
    private(set) var statCalls = 0
    private(set) var readCalls = 0
    private(set) var statOnMain: [Bool] = []

    func set(_ stat: ShowFileStat) { lock.lock(); stat_ = stat; lock.unlock() }
    var counts: (stat: Int, read: Int) { lock.lock(); defer { lock.unlock() }; return (statCalls, readCalls) }
    var mainFlags: [Bool] { lock.lock(); defer { lock.unlock() }; return statOnMain }

    func stat(_ path: String) async throws -> ShowFileStat {
        lock.lock(); defer { lock.unlock() }
        statCalls += 1
        statOnMain.append(Thread.isMainThread)
        return stat_
    }

    func read(_ path: String, root: String?, maxBytes: Int) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        readCalls += 1
        return Data("x".utf8)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}

/// One `c11-show:` request, as WebKit would hand it to the scheme handler
/// (whose callbacks it receives on main).
private final class FakeSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var response: URLResponse?
    private(set) var finished = false

    init(url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) {}
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { finished = true }
}

final class ShowTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("show-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("site/css"), withIntermediateDirectories: true)
        try Data("<html><title>T</title><body>hi</body></html>".utf8).write(to: tmp.appendingPathComponent("site/index.html"))
        try Data("body{}".utf8).write(to: tmp.appendingPathComponent("site/css/app.css"))
        try Data("secret".utf8).write(to: tmp.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(at: tmp.appendingPathComponent("site/escape.css"),
                                                   withDestinationURL: tmp.appendingPathComponent("outside.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private var site: String { tmp.appendingPathComponent("site").path }

    // MARK: 1, 2: dedupe, operator close, cap

    func testReShowRefreshesTheSameViewer() {
        var registry = ShowRegistry()
        let caller = UUID(), panel = UUID()
        XCTAssertEqual(registry.decide(caller: caller, sourceKey: "a"), .open(replacing: nil, reopening: false))
        registry.opened(panel: panel, caller: caller, sourceKey: "a", at: Date())
        XCTAssertEqual(registry.decide(caller: caller, sourceKey: "a"), .refresh(panel: panel))
        // Another caller showing the same file gets its own viewer.
        XCTAssertEqual(registry.decide(caller: UUID(), sourceKey: "a"), .open(replacing: nil, reopening: false))
    }

    func testOperatorClosedViewerStaysClosedUntilShownAgain() {
        var registry = ShowRegistry()
        let caller = UUID(), panel = UUID()
        registry.opened(panel: panel, caller: caller, sourceKey: "a", at: Date())
        registry.closed(panel: panel, byOperator: true)
        // A save (live reload) may not touch it: it is no longer a live viewer.
        XCTAssertFalse(registry.mayRefresh(panel: panel))
        XCTAssertTrue(registry.isOperatorClosed(caller: caller, sourceKey: "a"))
        // An explicit re-show reopens it.
        XCTAssertEqual(registry.decide(caller: caller, sourceKey: "a"), .open(replacing: nil, reopening: true))
        let again = UUID()
        registry.opened(panel: again, caller: caller, sourceKey: "a", at: Date())
        XCTAssertFalse(registry.isOperatorClosed(caller: caller, sourceKey: "a"))
        XCTAssertTrue(registry.mayRefresh(panel: again))
    }

    func testNinthViewerFromOneCallerReplacesTheOldest() {
        var registry = ShowRegistry()
        let caller = UUID()
        var panels: [UUID] = []
        for index in 0..<ShowSpec.maxViewersPerCaller {
            let panel = UUID()
            panels.append(panel)
            XCTAssertEqual(registry.decide(caller: caller, sourceKey: "s\(index)"), .open(replacing: nil, reopening: false))
            registry.opened(panel: panel, caller: caller, sourceKey: "s\(index)", at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(registry.decide(caller: caller, sourceKey: "ninth"), .open(replacing: panels[0], reopening: false))
        registry.closed(panel: panels[0], byOperator: false)
        registry.opened(panel: UUID(), caller: caller, sourceKey: "ninth", at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(registry.viewers(of: caller).count, ShowSpec.maxViewersPerCaller)
        // An agent-side close is not an operator close.
        XCTAssertFalse(registry.isOperatorClosed(caller: caller, sourceKey: "s0"))
    }

    // MARK: 4: remote URL refusals

    func testRemoteURLRefusesFileLoopbackAndTheMacItself() {
        let own = ShowURLPolicy.OwnAddresses(names: ["laptop", "laptop.local", "laptop.tail1234.example"],
                                             addresses: ["198.51.100.20", "192.168.1.20", "fe80::1"])
        let refused = [
            "file:///etc/passwd", "FILE:///Users/x", "ftp://example.com/x", "javascript:alert(1)",
            "http://localhost:5173", "http://LOCALHOST./", "http://app.localhost/", "http://127.0.0.1/", "http://127.1/",
            "http://127.0.0.2:8080/", "http://0.0.0.0/", "http://0/", "http://2130706433/", "http://0x7f000001/",
            "http://0x7f.0.0.1/", "http://0177.0.0.1/", "http://017700000001/", "http://[::1]/",
            "http://[0:0:0:0:0:0:0:1]/", "http://[::ffff:127.0.0.1]/", "http://[::ffff:7f00:1]/", "http://[::]/",
            "http://[::127.0.0.1]/", "http://laptop:8737/", "http://Laptop.local/", "http://laptop.tail1234.example/",
            "http://198.51.100.20:3000/", "http://[::ffff:198.51.100.20]/", "http://192.168.1.20/", "http://[fe80::1]/",
            "http://user:pw@example.com/",
        ]
        for url in refused {
            XCTAssertNotNil(ShowURLPolicy.refusalForRemote(url, own: own), url)
        }
        for url in ["http://studio:5173/", "https://example.com/x#y", "http://203.0.113.5:8080/", "http://[2001:db8::1]/"] {
            XCTAssertNil(ShowURLPolicy.refusalForRemote(url, own: own), url)
        }
    }

    func testLocalCallerURLRule() {
        XCTAssertNil(ShowPreflight.urlRefusal("http://localhost:5173", origin: .local))
        XCTAssertNotNil(ShowPreflight.urlRefusal("http://localhost:5173", origin: .remote(machine: "studio", container: nil)))
        XCTAssertNotNil(ShowPreflight.urlRefusal("ssh://host", origin: .local))
    }

    // MARK: 5: --dir

    func testAssetPathRefusesTraversalEncodingAndBackslash() {
        let root = "/home/agent/site"
        for raw in ["/../etc/passwd", "/a/../../x.css", "/%2e%2e/x.css", "/%2E%2E%2Fx.css", "/%252e%252e/x.css",
                    "/a\\..\\x.css", "/a%5c..%5cx.css", "//x.css", "/./x.css", "/a/%00.css", "/x.svg", "/x.sh"] {
            if case .success(let path) = ShowAssetPath.resolve(rawPath: raw, urlBase: "/", root: root) {
                XCTFail("\(raw) resolved to \(path)")
            }
        }
        XCTAssertEqual(ShowAssetPath.resolve(rawPath: "/css/app%20x.css", urlBase: "/", root: root),
                       .success("/home/agent/site/css/app x.css"))
    }

    func testServeScopeMapsOnlyTheEntryAndAssetsUnderDir() {
        let home = "/Users/a"
        let withDir = ShowServeScope(source: .path("/Users/a/p/site/index.html", dir: "/Users/a/p/site", home: home))
        XCTAssertEqual(withDir.target(percentEncodedPath: "/p/site/index.html"), .entry)
        XCTAssertEqual(withDir.target(percentEncodedPath: "/p/site/css/app.css"), .asset(path: "/Users/a/p/site/css/app.css"))
        XCTAssertEqual(withDir.target(percentEncodedPath: "/p/other/x.css"), .refused(.outsideRoot))
        XCTAssertEqual(withDir.target(percentEncodedPath: "/p/site/%2e%2e/secret.css"), .refused(.traversal))
        let noDir = ShowServeScope(source: .path("/Users/a/p/site/index.html", home: home))
        XCTAssertEqual(noDir.target(percentEncodedPath: "/p/site/css/app.css"), .refused(.outsideRoot))
        let outside = ShowServeScope(source: .path("/opt/x/page.html", home: home))
        XCTAssertEqual(outside.entryURLPath, "/_/opt/x/page.html")
        XCTAssertEqual(ShowAddress.absolutePath(forURLPath: outside.entryURLPath, home: home), "/opt/x/page.html")
    }

    func testLocalFetcherRefusesSymlinkEscapeFromDir() async throws {
        let fetcher = ShowLocalFetcher()
        let css = try await fetcher.read(site + "/css/app.css", root: site, maxBytes: 1024)
        XCTAssertEqual(String(decoding: css, as: UTF8.self), "body{}")
        do {
            _ = try await fetcher.read(site + "/escape.css", root: site, maxBytes: 1024)
            XCTFail("a symlink out of the root was served")
        } catch let error as ShowFetchError {
            XCTAssertEqual(error, .outsideRoot)
        }
    }

    func testRemoteFetcherProgramResolvesSymlinksWhereTheFileLives() async throws {
        let host = LocalExecHost()
        let fetcher = ShowHCFetcher(host: host, machine: "studio", container: nil)
        let css = try await fetcher.read(site + "/css/app.css", root: site, maxBytes: 1024)
        XCTAssertEqual(String(decoding: css, as: UTF8.self), "body{}")
        await XCTAssertThrowsShowError(.outsideRoot) { _ = try await fetcher.read(self.site + "/escape.css", root: self.site, maxBytes: 1024) }
        await XCTAssertThrowsShowError(.notFound) { _ = try await fetcher.stat(self.site + "/missing.html") }
        await XCTAssertThrowsShowError(.notFile) { _ = try await fetcher.stat(self.site + "/css") }
        let stat = try await fetcher.stat(site + "/index.html")
        XCTAssertEqual(stat.size, 44)
        XCTAssertFalse(stat.mtime.isEmpty)
        XCTAssertEqual(ShowHCFetcher(host: host, machine: "linuxbox", container: "ws-1").argv("cat", [], path: "/home/agent/x.html"),
                       ["incus", "exec", "ws-1", "--", "cat", "--", "/home/agent/x.html"])
    }

    // 15: every machine.exec argv is fixed and literal, no shell; the path is
    // absolute, last, after `--`, and nothing in it can change the command.
    func testRemoteArgvIsLiteralAndAPathCannotChangeTheCommand() async throws {
        let hostile = tmp.appendingPathComponent("site/-rf 'q\" $(touch pwned); `id` y.html")
        try Data("<p>ok</p>".utf8).write(to: hostile)
        let host = LocalExecHost()
        let fetcher = ShowHCFetcher(host: host, machine: "studio", container: nil)
        let stat = try await fetcher.stat(hostile.path)
        XCTAssertEqual(stat.size, 9)
        let data = try await fetcher.read(hostile.path, root: site, maxBytes: 1024)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "<p>ok</p>")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("site/pwned").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "pwned"))
        for argv in host.calls {
            XCTAssertTrue(["stat", "cat", "realpath"].contains(argv[0]), "\(argv)")
            XCTAssertFalse(argv.contains { ["sh", "/bin/sh", "bash", "/bin/bash", "zsh", "env"].contains($0) }, "no shell: \(argv)")
            let dashes = try XCTUnwrap(argv.firstIndex(of: "--"))
            XCTAssertEqual(dashes, argv.count - 2, "the path is the one argument after --")
            XCTAssertTrue(argv.last!.hasPrefix("/"))
        }
        // A path that is not absolute (one starting with `-`) never reaches the machine.
        let before = host.calls.count
        await XCTAssertThrowsShowError(.notFound) { _ = try await fetcher.stat("-rf /") }
        await XCTAssertThrowsShowError(.notFound) { _ = try await fetcher.read("--version", root: nil, maxBytes: 10) }
        XCTAssertEqual(host.calls.count, before)
    }

    // MARK: 10: size

    func testOverEightMegabytesIsRefused() async throws {
        let big = tmp.appendingPathComponent("big.html")
        try Data(count: ShowSpec.maxBytes + 1).write(to: big)
        let host = LocalExecHost()
        await XCTAssertThrowsShowError(.tooLarge(Int64(ShowSpec.maxBytes + 1))) {
            _ = try await ShowHCFetcher(host: host, machine: "studio", container: nil).read(big.path, root: nil, maxBytes: ShowSpec.maxBytes)
        }
        do {
            _ = try await ShowLocalFetcher().read(big.path, root: nil, maxBytes: ShowSpec.maxBytes)
            XCTFail("an over-cap file was read")
        } catch let error as ShowFetchError {
            guard case .tooLarge = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.message.contains(ShowSpec.tooLargeMessage()))
        }
    }

    // MARK: 7, 12: live reload

    func testReloadRuleFetchesOnlyOnChange() {
        var rule = ShowReloadRule(last: ShowFileStat(size: 1, mtime: "1"))
        XCTAssertEqual(rule.step(visible: false), .idle)
        XCTAssertEqual(rule.step(visible: true), .stat)
        XCTAssertEqual(rule.observe(ShowFileStat(size: 1, mtime: "1")), .unchanged)
        XCTAssertEqual(rule.observe(ShowFileStat(size: 1, mtime: "2")), .changed)
        XCTAssertEqual(rule.step(visible: true), .idle, "one load at a time")
        rule.loaded(ShowFileStat(size: 1, mtime: "2"))
        XCTAssertEqual(rule.observe(ShowFileStat(size: 1, mtime: "2")), .unchanged)
        XCTAssertEqual(rule.observe(ShowFileStat(size: 2, mtime: "2")), .changed)
    }

    func testPollerAsksNothingWhileHiddenOneCheckOnRevealAndRunsOffMain() async {
        let fetcher = FakeFetcher()
        let visible = Flag(false)
        let changes = Flag(false)
        let poller = ShowReloadPoller(fetcher: fetcher, path: "/x.html", interval: 60,
                                      isVisible: { visible.get() }, onChange: { _ in changes.set(true) })
        poller.prime(ShowFileStat(size: 10, mtime: "1.0"))
        await poller.tick()
        await poller.tick()
        XCTAssertEqual(fetcher.counts.stat, 0, "a hidden viewer must not reach the machine")
        visible.set(true)
        await poller.tick()
        XCTAssertEqual(fetcher.counts.stat, 1, "one check on reveal")
        XCTAssertFalse(changes.get(), "unchanged size and mtime fetch nothing")
        fetcher.set(ShowFileStat(size: 11, mtime: "2.0"))
        await poller.tick()
        XCTAssertTrue(changes.get())
        XCTAssertEqual(fetcher.counts.read, 0, "the poller itself never fetches; the viewer does on change")
        XCTAssertEqual(fetcher.mainFlags, [false, false], "stat never runs on the main thread")
    }

    // MARK: 8: load check

    func testLoadJudge() {
        XCTAssertEqual(ShowLoadJudge.judge(failure: "Could not connect to the server.", entryStatus: nil, page: nil, refusedAssets: 0).status, .failed)
        let missing = ShowLoadJudge.judge(failure: nil, entryStatus: 404, page: .init(textLength: 0, elements: 0, media: 0, scriptErrors: 0), refusedAssets: 0)
        XCTAssertEqual(missing.status, .failed)
        XCTAssertEqual(missing.httpStatus, 404)
        XCTAssertTrue(missing.reason?.contains("404") == true)
        let blank = ShowLoadJudge.judge(failure: nil, entryStatus: 200, page: .init(textLength: 0, elements: 1, media: 0, scriptErrors: 2), refusedAssets: 1)
        XCTAssertEqual(blank.status, .blank)
        XCTAssertEqual(blank.scriptErrors, 2)
        XCTAssertEqual(blank.refusedAssets, 1)
        XCTAssertEqual(ShowLoadJudge.judge(failure: nil, entryStatus: 200, page: .init(textLength: 0, elements: 1, media: 1, scriptErrors: 0), refusedAssets: 0).status, .loaded)
        let loaded = ShowLoadJudge.judge(failure: nil, entryStatus: 200, page: .init(textLength: 120, elements: 40, media: 0, scriptErrors: 3), refusedAssets: 0)
        XCTAssertEqual(loaded.status, .loaded)
        XCTAssertEqual(loaded.dictionary["script_errors"] as? Int, 3)
    }

    func testLoadCheckSettlesOnceAndTimesOut() {
        let check = ShowLoadCheck()
        let waited = DispatchSemaphore(value: 0)
        var result: ShowLoadResult?
        DispatchQueue.global().async {
            result = check.wait(seconds: 0.2)
            waited.signal()
        }
        XCTAssertEqual(waited.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(result?.status, .timeout)
        check.finish(ShowLoadResult(status: .loaded))
        XCTAssertEqual(check.wait(seconds: 0.01).status, .timeout, "the first result wins")
    }

    // MARK: Wire contract and records

    func testSourceSpecRoundTripAndRefusals() {
        let spec = ShowSourceSpec.path("/Users/a/x.md", dir: "/Users/a", home: "/Users/a")
        XCTAssertEqual(ShowSourceSpec(spec.dictionary), spec)
        XCTAssertTrue(spec.isMarkdown)
        XCTAssertNil(ShowSourceSpec(["kind": "path", "path": "relative/x.html"]))
        XCTAssertNil(ShowSourceSpec(["kind": "url", "url": "http://x", "dir": "/a"]))
        XCTAssertNil(ShowSourceSpec(["kind": "path", "path": "/a\nb"]))
        XCTAssertEqual(ShowSourceSpec.path("/a", home: "/x").key, ShowSourceSpec.path("/a", home: "/y").key)
    }

    func testContainerComesOnlyFromHCForegroundArgv() {
        XCTAssertEqual(ShowOrigin.container(fromForegroundArgv: ["incus", "exec", "ws-agent-3", "--", "claude"]), "ws-agent-3")
        XCTAssertEqual(ShowOrigin.container(fromForegroundArgv: ["/usr/bin/incus", "exec", "c1", "--env", "X=1", "--", "sh"]), "c1")
        XCTAssertNil(ShowOrigin.container(fromForegroundArgv: ["incus", "exec", "--project", "x"]))
        XCTAssertNil(ShowOrigin.container(fromForegroundArgv: ["claude"]))
        XCTAssertNil(ShowOrigin.container(fromForegroundArgv: ["incus", "exec", "a;rm -rf /"]))
    }

    func testRecordKeepsOneEntryPerSourceAndCaps() {
        let panel = UUID()
        var record = ShowRecord(panel: panel)
        record.upsert(id: UUID().uuidString, source: .path("/a.html"), at: 1, state: .waiting)
        let second = UUID().uuidString
        record.upsert(id: second, source: .path("/a.html"), at: 2, state: .live)
        XCTAssertEqual(record.entries.count, 1)
        XCTAssertEqual(record.entries.first?.id, second)
        for index in 0..<(ShowRecord.maxEntries + 3) {
            record.upsert(id: UUID().uuidString, source: .path("/f\(index).html"), at: Int64(index), state: .waiting)
        }
        XCTAssertEqual(record.entries.count, ShowRecord.maxEntries)
        XCTAssertEqual(ShowRecord(panel: panel, value: record.dictionary), record)
        XCTAssertNil(ShowRecord(panel: UUID(), value: record.dictionary), "a record names its own panel")
        XCTAssertEqual(ShowRecord.panel(fromName: ShowRecord.name(panel: panel)), panel)
        XCTAssertNil(ShowRecord.panel(fromName: "c11h.show." + panel.uuidString))
    }
}

// MARK: - Relay, records, Feed, point and say (phases 3 and 4)

/// hc's document store for one machine, in memory, with compare-and-set.
private final class FakeRecordStore: ShowRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var docs: [UUID: (Any?, UInt64)] = [:]
    func put(_ record: ShowRecord) { lock.lock(); docs[record.panel] = (record.dictionary, (docs[record.panel]?.1 ?? 0) + 1); lock.unlock() }
    func record(_ panel: UUID) -> ShowRecord? { lock.lock(); defer { lock.unlock() }; return ShowRecord(panel: panel, value: docs[panel]?.0) }
    func load(machine: String, panel: UUID) async throws -> (record: ShowRecord?, version: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let (value, version) = docs[panel] ?? (nil, 0)
        return (ShowRecord(panel: panel, value: value), version)
    }
    func save(machine: String, record: ShowRecord, version: UInt64) async throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard (docs[record.panel]?.1 ?? 0) == version else { throw C11RelayStoreError.conflict }
        docs[record.panel] = (record.dictionary, version + 1)
        return version + 1
    }
}

final class ShowRelayTests: XCTestCase {
    private let panel = UUID(uuidString: "6B7A1D2E-0000-4000-8000-0000000000AA")!
    private let workspace = UUID(uuidString: "6B7A1D2E-0000-4000-8000-0000000000BB")!

    private func admit(_ params: String, method: String = "show.open") -> Result<C11RelayPolicy.Admitted, C11RelayPolicy.Refusal> {
        let request = C11Relay.Request(id: UUID().uuidString, at: 1, panel: panel.uuidString, workspace: workspace.uuidString,
                                        term: "t3", framing: .json,
                                        line: #"{"id":"1","method":"\#(method)","params":\#(params)}"#, timeoutMilliseconds: 5000)
        let caller = C11RelayPolicy.VerifiedCaller(panel: panel, workspace: workspace, machine: "studio", terminal: "t3")
        return C11RelayPolicy.admit(request, caller: caller)
    }

    // 3: no placement, machine or container parameter passes the relay.
    func testRelayedShowRefusesEveryTargetMachineAndContainerParameter() throws {
        let source = #"{"kind":"path","path":"/Users/a/x.html"}"#
        for key in ["panel_id", "surface_id", "tab_id", "panel_ref", "pane_id", "area_id", "workspace_id", "workspace_ref",
                    "window_id", "window_ref", "target_panel_id", "source_surface_id", "machine", "on", "container", "host"] {
            let result = admit(#"{"source":\#(source),"\#(key)":"x"}"#)
            guard case .failure(let refusal) = result else { return XCTFail("\(key) passed the relay") }
            XCTAssertEqual(refusal.code, "relay_target_refused", key)
        }
        for method in ["show.open", "show.close"] {
            let admitted = try admit(#"{"source":\#(source),"caller_panel_id":"\#(UUID().uuidString)"}"#, method: method).get()
            guard case .v2(_, _, let params, _) = admitted else { return XCTFail() }
            XCTAssertEqual(params["caller_panel_id"] as? String, panel.uuidString, "attribution is the verified caller")
        }
        // Browser and markdown stay refused, with the way forward.
        guard case .failure(let refusal) = admit("{}", method: "browser.open_split") else { return XCTFail() }
        XCTAssertEqual(refusal.code, "relay_not_allowed")
        XCTAssertTrue(refusal.message.contains("c11 show"))
    }

    // 3: the path is always read on the caller's verified machine (and its
    // container, from hc's own foreground facts), never what params say.
    func testShowOriginComesFromTheVerifiedCallerOnly() {
        XCTAssertEqual(TerminalController.showOrigin(caller: panel, context: nil), .local)
        let local = SocketCommandContext(method: "show.open", allowsFocus: false, callerPanelId: panel)
        XCTAssertEqual(TerminalController.showOrigin(caller: panel, context: local), .local)
        let record = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "core-1", localAddress: "t3"), state: .running,
                                      labels: ["c11.panel": panel.uuidString], machineName: "linuxbox",
                                      machineAvailability: .connected,
                                      foreground: HCForeground(name: "incus", argv: ["incus", "exec", "ws-7", "--", "claude"]))
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let inventory = HCInventorySnapshot(readiness: .ready(revision), revision: revision, records: [record.key: record],
                                            machines: ["linuxbox": .connected])
        let relayed = SocketCommandContext(method: "connection", allowsFocus: false, callerPanelId: panel, hcInventory: inventory)
        relayed.relayMachine = "linuxbox"
        XCTAssertEqual(TerminalController.showOrigin(caller: panel, context: relayed), .remote(machine: "linuxbox", container: "ws-7"))
        relayed.relayMachine = "studio"
        XCTAssertEqual(TerminalController.showOrigin(caller: panel, context: relayed), .remote(machine: "studio", container: nil))
    }

    // 11: a show while c11 was away becomes one Feed row, surfaced once, and
    // a restart's re-read rebuilds the same row, not a second.
    func testDrainSurfacesSignedWaitingEntriesOnceAndSurvivesARestart() async throws {
        let store = FakeRecordStore()
        let key = Data(repeating: 7, count: 32)
        let credential = C11RelayAuth.Credential(linkID: String(repeating: "a", count: 32), creation: UUID(), key: key)
        var record = ShowRecord(panel: panel)
        record.upsert(id: UUID().uuidString, source: .path("/Users/a/flag-lanes.html"), at: 10, state: .waiting, credential: credential)
        record.upsert(id: UUID().uuidString, source: .path("/Users/a/live.html"), at: 11, state: .live, credential: credential)
        record.upsert(id: UUID().uuidString, source: .path("/Users/a/forged.html"), at: 12, state: .waiting)   // unsigned
        store.put(record)
        let verify: (ShowRecord.Entry) -> Bool = { [panel] in $0.isSigned(panel: panel, key: key) }
        let drained = await ShowRecordDrain.drain(store: store, machine: "studio", panel: panel,
                                                  signer: ShowEntrySigner(credential), verified: verify)
        let first = try XCTUnwrap(drained)
        XCTAssertEqual(first.map(\.source.target), ["/Users/a/flag-lanes.html"])
        XCTAssertEqual(store.record(panel)?.entries.first?.state, .noticed, "the record itself remembers it was surfaced")
        let redrained = await ShowRecordDrain.drain(store: store, machine: "studio", panel: panel,
                                                    signer: ShowEntrySigner(credential), verified: verify)
        let afterRestart = try XCTUnwrap(redrained)
        XCTAssertEqual(afterRestart.map(\.id), first.map(\.id))

        let published = await MainActor.run { () -> [FeedShowFact?] in
            let away = ShowAwayShows()
            var facts: [FeedShowFact?] = []
            away.workspaceOf = { [workspace] _ in workspace }
            away.publish = { _, fact in facts.append(fact) }
            let items = first.map { ShowAwayEntry(panel: self.panel, machine: "studio", container: nil, entry: $0) }
            away.reconcile(panel: self.panel, items: items)
            away.reconcile(panel: self.panel, items: items)   // the doc event after link-up drain: no second row
            away.reconcile(panel: self.panel, items: afterRestart.map { ShowAwayEntry(panel: self.panel, machine: "studio", container: nil, entry: $0) })
            XCTAssertTrue(ShowViewerController.shared.registry.viewers(of: self.panel).isEmpty, "nothing opens unasked")
            return facts
        }
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first??.names, ["flag-lanes.html"])
        let rows = FeedProjector.project(journalRows: [], attention: [], notes: [:], scope: .attention,
                                         shows: published.compactMap { $0 })
        XCTAssertEqual(rows.map(\.kind), [.show])
        XCTAssertTrue(rows.first?.prompt?.contains("flag-lanes.html") == true)
        XCTAssertEqual(FeedProjectionSnapshot(rows: rows).attentionRows.count, 1)
    }

    func testEntrySignatureCoversSourceAndPanel() {
        let key = Data(repeating: 3, count: 32)
        let credential = C11RelayAuth.Credential(linkID: String(repeating: "b", count: 32), creation: UUID(), key: key)
        let entry = ShowRecord.Entry(id: UUID().uuidString, source: .path("/a.html"), at: 5, state: .waiting)
            .signed(panel: panel, credential: credential)
        XCTAssertTrue(entry.isSigned(panel: panel, key: key))
        XCTAssertFalse(entry.isSigned(panel: UUID(), key: key), "another panel cannot claim it")
        var moved = entry
        moved.source = .path("/etc/passwd")
        XCTAssertFalse(moved.isSigned(panel: panel, key: key), "a rewritten source is not signed")
        XCTAssertFalse(entry.isSigned(panel: panel, key: Data(repeating: 4, count: 32)))
        // The state is signed too: flipping a closed or opened entry back to
        // `waiting` without the terminal's key leaves it unsigned.
        var flipped = entry
        flipped.state = .closed
        XCTAssertFalse(flipped.isSigned(panel: panel, key: key))
        var record = ShowRecord(panel: panel, entries: [entry])
        record.setState(.noticed, id: entry.id)                       // no key: c11 will not surface it
        XCTAssertFalse(record.entries[0].isSigned(panel: panel, key: key))
        record.setState(.noticed, id: entry.id, signer: ShowEntrySigner(credential))
        XCTAssertTrue(record.entries[0].isSigned(panel: panel, key: key))
        var replayed = record.entries[0]
        replayed.state = .waiting
        XCTAssertFalse(replayed.isSigned(panel: panel, key: key), "a noticed entry cannot be replayed as waiting")
    }

    // 7: a failed load (link not back yet) loads again on the next answered stat.
    func testStaleViewerReloadsOnNextStat() {
        var rule = ShowReloadRule(last: ShowFileStat(size: 1, mtime: "1"))
        rule.markStale()
        XCTAssertEqual(rule.observe(ShowFileStat(size: 1, mtime: "1")), .changed)
        rule.loaded(ShowFileStat(size: 1, mtime: "1"))
        XCTAssertEqual(rule.observe(ShowFileStat(size: 1, mtime: "1")), .unchanged)
    }

    // 6: a viewer's website data store is its own and not persistent.
    @MainActor
    func testViewerUsesItsOwnNonPersistentStore() {
        let first = ShowViewerSession(caller: panel, source: .path("/a.html"), origin: .local, fetcher: ShowLocalFetcher(), callerTitle: "A")
        let second = ShowViewerSession(caller: panel, source: .url("https://example.com"), origin: .local, fetcher: nil, callerTitle: "A")
        XCTAssertFalse(first.dataStore.isPersistent)
        XCTAssertFalse(second.dataStore.isPersistent)
        XCTAssertFalse(first.dataStore === WKWebsiteDataStore.default())
        XCTAssertFalse(first.dataStore === second.dataStore)
        XCTAssertNotNil(first.schemeHandler, "a shown file is served by its own scheme handler")
        XCTAssertEqual(first.address.scheme, ShowSpec.scheme)
    }

    // C11H-353: a viewer of a linked machine's page never reaches this Mac.
    // Every navigation passes the remote-URL rule; script runs only in a page
    // c11 serves. A show from this Mac has no fence.
    @MainActor
    func testLinkedMachineViewerRefusesThisMacAndRunsScriptOnlyInServedPages() throws {
        let remote = ShowViewerSession(caller: panel, source: .path("/a.html"), origin: .remote(machine: "studio", container: nil),
                                       fetcher: FakeFetcher(), callerTitle: "A")
        let remoteURL = ShowViewerSession(caller: panel, source: .url("https://example.com/"),
                                          origin: .remote(machine: "studio", container: "seat"), fetcher: nil, callerTitle: "A")
        let local = ShowViewerSession(caller: panel, source: .path("/a.html"), origin: .local, fetcher: FakeFetcher(), callerTitle: "A")
        XCTAssertNil(local.pageGuard, "a show from this Mac keeps its script and navigation as before")
        XCTAssertNotNil(remoteURL.pageGuard)
        var pageGuard = try XCTUnwrap(remote.pageGuard)
        let own = ShowURLPolicy.OwnAddresses(names: ["operator-mac", "operator-mac.local"], addresses: ["192.168.1.20", "fd7a::5"])
        pageGuard.ownAddresses = { own }

        for refused in ["http://localhost:8737/", "http://127.0.0.1:9/x", "ws://127.0.0.1:9/", "http://[::1]/", "http://0.0.0.0/",
                        "http://2130706433/", "http://0x7f.1/", "http://app.localhost/", "https://192.168.1.20/",
                        "http://[fd7a::5]:3000/", "http://operator-mac.local:3000/", "http://OPERATOR-MAC/",
                        "file:///etc/hosts", "data:text/html,x", "blob:c11-show://studio/1", "javascript:void(0)", "about:config"] {
            XCTAssertNotNil(pageGuard.refusal(for: URL(string: refused)!), "\(refused) must be refused in a linked machine's viewer")
        }
        for allowed in [remote.address.absoluteString, "\(C11Identity.Legacy.showScheme)://studio/a.html",
                        "https://example.com/docs", "http://studio:5173/", "about:blank", "about:srcdoc"] {
            XCTAssertNil(pageGuard.refusal(for: URL(string: allowed)!), "\(allowed) is not this Mac")
        }
        XCTAssertTrue(pageGuard.allowsServedScript, "this WebKit can turn WebRTC off, so served pages keep script")
        XCTAssertTrue(pageGuard.allowsScript(for: remote.address))
        XCTAssertTrue(pageGuard.allowsScript(for: URL(string: "\(C11Identity.Legacy.showScheme)://studio/a.html")!))
        for noScript in ["https://example.com/", "http://studio:5173/", "about:blank"] {
            XCTAssertFalse(pageGuard.allowsScript(for: URL(string: noScript)!), "\(noScript) runs no script there")
        }
        // Where WebRTC cannot be turned off, no page in the viewer runs script.
        pageGuard.allowsServedScript = false
        XCTAssertFalse(pageGuard.allowsScript(for: remote.address))
    }

    // C11H-353: a CSP does not govern WebRTC, whose ICE reaches loopback. The
    // web view a linked machine's viewer is made with has peer connections and
    // content script off; a local viewer's keeps both.
    @MainActor
    func testALinkedMachineViewersWebViewIsMadeWithoutWebRTCOrPageScript() {
        let remote = ShowViewerSession(caller: panel, source: .path("/a.html"), origin: .remote(machine: "studio", container: nil),
                                       fetcher: FakeFetcher(), callerTitle: "A")
        let local = ShowViewerSession(caller: panel, source: .path("/a.html"), origin: .local, fetcher: FakeFetcher(), callerTitle: "A")
        let fenced = BrowserPanel.makeConfiguration(profileID: UUID(), websiteDataStore: remote.dataStore, showViewer: remote)
        XCTAssertEqual(fenced.preferences.value(forKey: "peerConnectionEnabled") as? Bool, false,
                       "a linked machine's viewer is made with WebRTC on")
        XCTAssertFalse(fenced.defaultWebpagePreferences.allowsContentJavaScript)
        let open = BrowserPanel.makeConfiguration(profileID: UUID(), websiteDataStore: local.dataStore, showViewer: local)
        XCTAssertEqual(open.preferences.value(forKey: "peerConnectionEnabled") as? Bool, true)
        XCTAssertTrue(open.defaultWebpagePreferences.allowsContentJavaScript)
    }

    // C11H-353: a viewer, local or a linked machine's, is never offered for
    // reopen (Cmd+Shift+T), which would bring its page back as an ordinary,
    // unfenced panel. An ordinary browser panel still is.
    @MainActor
    func testAClosedViewerIsNeverOfferedForReopen() throws {
        _ = NSApplication.shared
        let workspace = Workspace()
        var offered = 0
        workspace.onClosedBrowserPanel = { _ in offered += 1 }
        let pane = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        for origin in [ShowOrigin.remote(machine: "studio", container: nil), .local] {
            let viewer = try XCTUnwrap(workspace.newBrowserSurface(inPane: pane, url: nil, focus: false, sticksAsPreferred: false,
                                                                   showViewer: viewerSession(origin)))
            XCTAssertTrue(workspace.closePanel(viewer.id, force: true))
            drainMainQueue()
        }
        XCTAssertEqual(offered, 0, "a closed viewer was offered for reopen as an ordinary panel")
        let ordinary = try XCTUnwrap(workspace.newBrowserSurface(inPane: pane, url: nil, focus: false))
        XCTAssertTrue(workspace.closePanel(ordinary.id, force: true))
        drainMainQueue()
        XCTAssertEqual(offered, 1, "an ordinary browser panel is still offered for reopen")
    }

    // C11H-353: Duplicate Tab never copies a viewer into an ordinary panel.
    @MainActor
    func testDuplicateTabNeverCopiesAViewer() throws {
        _ = NSApplication.shared
        let workspace = Workspace()
        let pane = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        for origin in [ShowOrigin.remote(machine: "studio", container: nil), .local] {
            let viewer = try XCTUnwrap(workspace.newBrowserSurface(inPane: pane, url: nil, focus: false, sticksAsPreferred: false,
                                                                   showViewer: viewerSession(origin)))
            let tabId = try XCTUnwrap(workspace.bonsplitTabIdFromTabId(viewer.id))
            let tab = try XCTUnwrap(workspace.bonsplitController.tabs(inPane: pane).first { $0.id == tabId })
            let before = workspace.panels.count
            workspace.splitTabBar(workspace.bonsplitController, didRequestTabContextAction: .duplicate, for: tab, inPane: pane)
            drainMainQueue()
            XCTAssertEqual(workspace.panels.count, before, "Duplicate Tab copied a viewer into an ordinary panel")
        }
    }

    // C11H-353: the toolbar's Open in Default Browser never hands a linked
    // machine's page to an unfenced browser. An ordinary panel and a local
    // viewer still do.
    @MainActor
    func testTheToolbarNeverHandsALinkedMachinesPageToTheDefaultBrowser() {
        _ = NSApplication.shared
        let shown = URL(string: "https://example.com/shown")!
        var opened: [URL] = []
        func panel(_ origin: ShowOrigin?) -> BrowserPanel {
            let made = BrowserPanel(workspaceId: UUID(), initialURL: shown, pendingHibernate: true,
                                    showViewer: origin.map { viewerSession($0) })
            made.externalBrowserOpener = { opened.append($0); return true }
            return made
        }
        let guarded = panel(.remote(machine: "studio", container: nil))
        XCTAssertFalse(guarded.opensInDefaultBrowser, "the toolbar offers a linked machine's viewer the default browser")
        XCTAssertFalse(guarded.openCurrentURLInDefaultBrowser())
        XCTAssertEqual(opened, [], "a linked machine's page reached the default browser")
        XCTAssertTrue(panel(nil).openCurrentURLInDefaultBrowser())
        XCTAssertTrue(panel(.local).openCurrentURLInDefaultBrowser())
        XCTAssertEqual(opened, [shown, shown], "an ordinary panel and a local viewer still hand their page out")
    }

    // C11H-395: a local viewer's Open in Default Browser hands macOS the file
    // its scheme handler serves for the page, never the `c11-show:` address.
    // A page outside what the show serves, a symlink out of `--dir`, a file
    // macOS would run or follow (a Finder alias, a script), and a linked
    // machine's viewer hand out nothing; an http(s) page is itself.
    @MainActor
    func testOpenInDefaultBrowserHandsOutTheShownFileNeverTheShowAddress() throws {
        _ = NSApplication.shared
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("show-open-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let site = tmp.appendingPathComponent("site").path
        try FileManager.default.createDirectory(atPath: site, withIntermediateDirectories: true)
        for name in ["index.html", "about.html"] { try Data("<html>\(name)</html>".utf8).write(to: URL(fileURLWithPath: site + "/" + name)) }
        try Data("secret".utf8).write(to: tmp.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(atPath: site + "/escape.txt", withDestinationPath: tmp.path + "/outside.txt")
        // In the folder but not a served type behind a served name, and a folder with a page's name.
        try FileManager.default.createDirectory(atPath: site + "/tools", withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: site + "/tools/setup.command"))
        try FileManager.default.createSymbolicLink(atPath: site + "/guide.html", withDestinationPath: site + "/tools/setup.command")
        try FileManager.default.createDirectory(atPath: site + "/sub.html", withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(site + "/pipe.html", 0o600), 0)
        // A Finder alias with a page's name, made the way Finder makes one, to the same command.
        let bookmark = try URL(fileURLWithPath: site + "/tools/setup.command")
            .bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: URL(fileURLWithPath: site + "/alias.html"))
        // A served name for a script (JavaScript), a Markdown page, and shown
        // entries of a log (plain text) and a Python script.
        try Data("alert(1)".utf8).write(to: URL(fileURLWithPath: site + "/app.js"))
        try Data("# notes".utf8).write(to: URL(fileURLWithPath: site + "/notes.md"))
        try Data("build ok".utf8).write(to: URL(fileURLWithPath: site + "/build.log"))
        try Data("print(1)".utf8).write(to: URL(fileURLWithPath: site + "/tool.py"))
        // C11H-399: an app, an executable with no extension, and a location
        // file. No hand-off type covers them, so they are refused by default.
        try FileManager.default.createDirectory(atPath: site + "/Tool.app/Contents/MacOS", withIntermediateDirectories: true)
        try Data("<plist><dict/></plist>".utf8).write(to: URL(fileURLWithPath: site + "/Tool.app/Contents/Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: site + "/Tool.app/Contents/MacOS/Tool"))
        try Data("#!/bin/sh\necho run\n".utf8).write(to: URL(fileURLWithPath: site + "/run"))
        XCTAssertEqual(chmod(site + "/run", 0o755), 0)
        try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.com/"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: site + "/link.webloc"))
        let entry = site + "/index.html"
        var opened: [URL] = []
        func viewer(_ origin: ShowOrigin, entry shown: String? = nil, at page: (ShowViewerSession) -> URL) -> BrowserPanel {
            let session = ShowViewerSession(caller: panel, source: .path(shown ?? entry, dir: site), origin: origin,
                                            fetcher: ShowLocalFetcher(), callerTitle: "A")
            let made = BrowserPanel(workspaceId: UUID(), initialURL: page(session), pendingHibernate: true, showViewer: session)
            made.externalBrowserOpener = { opened.append($0); return true }
            return made
        }
        func address(_ session: ShowViewerSession, _ path: String) -> URL {
            ShowAddress.url(machine: session.origin.machineName, path: path, home: nil)!
        }
        func file(_ path: String) -> URL { URL(fileURLWithPath: path).resolvingSymlinksInPath() }
        // What the context menu's Open Link in Default Browser hands macOS for a link.
        func link(_ viewer: BrowserPanel, _ url: URL) throws -> URL? {
            try XCTUnwrap(viewer.webView as? CmuxWebView).defaultBrowserTarget(forLink: url)
        }
        // The real menu item on a link: whether the menu offers it, and what it opened.
        func menuOpen(_ viewer: BrowserPanel, _ url: URL) throws -> (offered: Bool, opened: [URL]) {
            let webView = try XCTUnwrap(viewer.webView as? CmuxWebView)
            var menuOpened: [URL] = []
            webView.contextMenuLinkURLProvider = { _, _, completion in completion(url) }
            webView.contextMenuDefaultBrowserOpener = { menuOpened.append($0); return true }
            let menu = NSMenu()
            let openLink = NSMenuItem(title: "Open Link", action: nil, keyEquivalent: "")
            openLink.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLink")
            menu.addItem(openLink)
            let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                                                         timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                         clickCount: 1, pressure: 1))
            webView.willOpenMenu(menu, with: click)
            guard let item = menu.items.first(where: { $0.title == "Open Link in Default Browser" }) else { return (false, []) }
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            return (true, menuOpened)
        }

        // The shown page, and pages a link inside the show reached (HTML and Markdown).
        for (path, expected) in [(entry, entry), (site + "/about.html", site + "/about.html"), (site + "/notes.md", site + "/notes.md")] {
            opened = []
            let local = viewer(.local) { address($0, path) }
            XCTAssertEqual(local.urlForDefaultBrowser?.path, path, "the toolbar's button is not enabled for a shown page")
            XCTAssertTrue(local.openCurrentURLInDefaultBrowser())
            XCTAssertEqual(opened, [file(expected)], "the default browser was not handed the shown file")
        }
        // The retired line's show address (the operator's repro) maps the same way.
        opened = []
        let legacy = viewer(.local) { session in
            var components = URLComponents(url: session.address, resolvingAgainstBaseURL: false)!
            components.scheme = C11Identity.Legacy.showScheme
            return components.url!
        }
        XCTAssertTrue(legacy.openCurrentURLInDefaultBrowser())
        XCTAssertEqual(opened, [file(entry)], "a c11h-show: page did not open as its file")

        // The context menu's Open Link in Default Browser maps a show link the same way.
        let local = viewer(.local) { $0.address }
        XCTAssertEqual(try link(local, address(local.showViewer!, site + "/about.html")),
                       file(site + "/about.html"), "a show link does not open as its file")
        XCTAssertEqual(try link(local, URL(string: "https://example.com/x")!),
                       URL(string: "https://example.com/x")!)
        XCTAssertNil(try link(local, address(local.showViewer!, tmp.path + "/outside.txt")),
                     "a show link outside the shown folder opens a file")

        // The real menu item: Open Link in Default Browser on a show link opens its file.
        let viaMenu = try menuOpen(local, address(local.showViewer!, site + "/about.html"))
        XCTAssertTrue(viaMenu.offered)
        XCTAssertEqual(viaMenu.opened, [file(site + "/about.html")], "the menu item did not open the show link's file")

        // Outside the shown folder (by path or by traversal): nothing to hand out.
        opened = []
        let outsidePages: [(ShowViewerSession) -> URL] = [
            { address($0, tmp.path + "/outside.txt") },
            { URL(string: $0.address.absoluteString.replacingOccurrences(of: "/index.html", with: "/../outside.txt"))! },
        ]
        for page in outsidePages {
            let outside = viewer(.local, at: page)
            XCTAssertNil(outside.urlForDefaultBrowser, "the button is enabled for a page the show does not serve")
            XCTAssertFalse(outside.openCurrentURLInDefaultBrowser())
        }
        // A symlink in the folder that resolves outside it: the handler refuses it, and so does the button.
        let escape = viewer(.local) { address($0, site + "/escape.txt") }
        XCTAssertFalse(escape.openCurrentURLInDefaultBrowser())
        XCTAssertNil(try link(escape, address(escape.showViewer!, site + "/escape.txt")))
        // A page the show would serve but that is missing on disk, a folder, or
        // a served name linked to a type macOS would run: nothing opens.
        // Refused by name (a script, an app, an executable with no extension,
        // a `.webloc`): the button is disabled. Refused only on
        // disk (missing, a folder, a FIFO, a page name linked to a `.command`,
        // a Finder alias named like a page): the button stays enabled (no disk
        // read while drawing) and the click opens nothing. Through the toolbar
        // and the real menu item, nothing opens.
        for (name, enabled) in [("app.js", false), ("missing.html", true), ("sub.html", true), ("pipe.html", true),
                                ("guide.html", true), ("alias.html", true), ("Tool.app", false), ("run", false),
                                ("link.webloc", false)] {
            let page = viewer(.local) { address($0, site + "/" + name) }
            XCTAssertEqual(page.urlForDefaultBrowser != nil, enabled, "\(name): the button's state")
            XCTAssertFalse(page.openCurrentURLInDefaultBrowser(), "\(name) reached the default browser")
            XCTAssertNil(try link(page, address(page.showViewer!, site + "/" + name)), "\(name) opened from a link")
            XCTAssertEqual(try menuOpen(page, address(page.showViewer!, site + "/" + name)).opened, [],
                           "\(name) opened from the menu item")
        }
        // A shown Python script: disabled, opens nothing. A shown log: opens as itself.
        let script = viewer(.local, entry: site + "/tool.py") { $0.address }
        XCTAssertNil(script.urlForDefaultBrowser, "the button is enabled for a shown script")
        XCTAssertFalse(script.openCurrentURLInDefaultBrowser())
        XCTAssertEqual(opened, [], "a file the hand-off refuses reached the default browser")
        let log = viewer(.local, entry: site + "/build.log") { $0.address }
        XCTAssertTrue(log.openCurrentURLInDefaultBrowser())
        XCTAssertEqual(opened, [file(site + "/build.log")], "a shown log did not open as itself")
        opened = []
        // A show viewer's `file:` page passes the same rules.
        let filePage = { (name: String) in viewer(.local) { _ in URL(fileURLWithPath: site + "/" + name) } }
        XCTAssertNil(filePage("app.js").urlForDefaultBrowser, "the button is enabled for a script's file: page")
        XCTAssertFalse(filePage("guide.html").openCurrentURLInDefaultBrowser(), "a file: page linked to a .command opened")
        XCTAssertEqual(opened, [], "a file: page the hand-off refuses reached the default browser")
        XCTAssertTrue(filePage("about.html").openCurrentURLInDefaultBrowser())
        XCTAssertEqual(opened, [file(site + "/about.html")])
        opened = []

        // A linked machine's viewer hands out neither its page nor a show link.
        let linked = viewer(.remote(machine: "studio", container: nil)) { $0.address }
        XCTAssertNil(linked.urlForDefaultBrowser)
        XCTAssertFalse(linked.openCurrentURLInDefaultBrowser())
        XCTAssertNil(try link(linked, linked.showViewer!.address),
                     "a linked machine's show link opened as a file on this Mac")
        XCTAssertNil(try link(linked, URL(string: "https://example.com/x")!), "a linked machine's https link left its fence")
        XCTAssertFalse(try menuOpen(linked, URL(string: "https://example.com/x")!).offered,
                       "a linked machine's viewer offers Open Link in Default Browser")
        XCTAssertEqual(opened, [], "a linked machine's page reached the default browser")
        // C11H-399: the session itself maps nothing for a linked machine, for
        // any caller, though the same path names a file this show serves here.
        let linkedSession = try XCTUnwrap(linked.showViewer)
        for path in [entry, site + "/about.html"] {
            XCTAssertNil(linkedSession.servedPathForDefaultBrowser(address(linkedSession, path)),
                         "a linked machine's address mapped to a path on this Mac")
            XCTAssertNil(linkedSession.defaultBrowserFile(address(linkedSession, path)),
                         "a linked machine's address mapped to a file on this Mac")
        }
        XCTAssertNotNil(local.showViewer!.defaultBrowserFile(address(local.showViewer!, site + "/about.html")),
                        "the same page of a local viewer maps to its file")

        // C11H-399: the web view's refusal comes from its session and fails
        // closed: one built outside a panel refuses a linked session's links
        // with no flag set, and keeps refusing once a local session is gone.
        let detached = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        detached.attachShowViewer(linkedSession)
        XCTAssertNil(detached.defaultBrowserTarget(forLink: URL(string: "https://example.com/x")!),
                     "a linked session's web view handed out an https link")
        let orphaned = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        autoreleasepool {
            let session = ShowViewerSession(caller: panel, source: .path(entry, dir: site), origin: .local,
                                            fetcher: ShowLocalFetcher(), callerTitle: "A")
            orphaned.attachShowViewer(session)
            XCTAssertEqual(orphaned.defaultBrowserTarget(forLink: URL(string: "https://example.com/x")!),
                           URL(string: "https://example.com/x")!, "a live local session's web view refused an https link")
        }
        XCTAssertNil(orphaned.showViewer, "the session outlived its last owner")
        XCTAssertNil(orphaned.defaultBrowserTarget(forLink: URL(string: "https://example.com/x")!),
                     "a show viewer's web view whose session is gone handed out an https link")
        XCTAssertTrue(orphaned.refusesDefaultBrowser, "a show viewer's web view whose session is gone offers the menu item")

        // A page the viewer navigated to over https opens as itself.
        let navigated = viewer(.local) { _ in URL(string: "https://example.com/next")! }
        XCTAssertTrue(navigated.openCurrentURLInDefaultBrowser())
        XCTAssertEqual(opened, [URL(string: "https://example.com/next")!])

        // An ordinary panel never hands macOS a `c11-show:` address.
        let plain = BrowserPanel(workspaceId: UUID(), initialURL: local.showViewer!.address, pendingHibernate: true)
        plain.externalBrowserOpener = { opened.append($0); return true }
        XCTAssertNil(plain.urlForDefaultBrowser)
        XCTAssertFalse(plain.openCurrentURLInDefaultBrowser())
        XCTAssertNil(try link(plain, local.showViewer!.address))
        XCTAssertEqual(try link(plain, URL(string: "https://example.com/x")!), URL(string: "https://example.com/x")!,
                       "an ordinary panel's menu refuses an https link")
        XCTAssertEqual(opened, [URL(string: "https://example.com/next")!], "a c11-show: address reached macOS")
    }

    // C11H-353: the insecure-HTTP prompt in a linked machine's viewer offers
    // no default browser, whichever button answers it. An ordinary panel's
    // first button still opens the default browser.
    @MainActor
    func testTheInsecureHTTPPromptNeverHandsALinkedMachinesPageToTheDefaultBrowser() {
        _ = NSApplication.shared
        final class AnsweringAlert: NSAlert {
            var answer: NSApplication.ModalResponse = .alertFirstButtonReturn
            override func beginSheetModal(for sheetWindow: NSWindow,
                                          completionHandler handler: ((NSApplication.ModalResponse) -> Void)?) {
                handler?(answer)
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let plain = URL(string: "http://studio.example/page")!
        var opened: [URL] = []
        func prompt(_ origin: ShowOrigin?, answer: NSApplication.ModalResponse) -> AnsweringAlert {
            let made = BrowserPanel(workspaceId: UUID(), showViewer: origin.map { viewerSession($0) })
            made.externalBrowserOpener = { opened.append($0); return true }
            let alert = AnsweringAlert()
            alert.answer = answer
            made.configureInsecureHTTPAlertHooksForTesting(alertFactory: { alert }, windowProvider: { window })
            made.presentInsecureHTTPAlertForTesting(url: plain)
            return alert
        }
        for answer in [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn] {
            let alert = prompt(.remote(machine: "studio", container: nil), answer: answer)
            XCTAssertEqual(alert.buttons.count, 2, "a linked machine's viewer's prompt offers the default browser")
        }
        XCTAssertEqual(opened, [], "a linked machine's page reached the default browser from the prompt")
        let ordinary = prompt(nil, answer: .alertFirstButtonReturn)
        XCTAssertEqual(ordinary.buttons.count, 3)
        XCTAssertEqual(opened, [plain], "an ordinary panel's prompt still opens the default browser")
    }

    @MainActor
    private func viewerSession(_ origin: ShowOrigin) -> ShowViewerSession {
        ShowViewerSession(caller: panel, source: .url("https://example.com/shown"), origin: origin, fetcher: nil, callerTitle: "A")
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    // C11H-353: every response a linked machine's viewer serves carries a
    // policy that keeps loads and connections inside what was shown.
    @MainActor
    func testLinkedMachinePageIsServedUnderTheFence() async throws {
        let remote = ShowViewerSession(caller: panel, source: .path("/a.html"), origin: .remote(machine: "studio", container: nil),
                                       fetcher: FakeFetcher(), callerTitle: "A")
        let local = ShowViewerSession(caller: panel, source: .path("/a.html"), origin: .local, fetcher: FakeFetcher(), callerTitle: "A")

        let fenced = try await served(remote, url: remote.address)
        XCTAssertEqual(fenced.statusCode, 200)
        let header = try XCTUnwrap(fenced.value(forHTTPHeaderField: "Content-Security-Policy"),
                                   "a linked machine's page is served without a Content-Security-Policy")
        var policy: [String: [String]] = [:]
        for directive in header.split(separator: ";") {
            let words = directive.split(separator: " ").map(String.init)
            if let name = words.first { policy[name] = Array(words.dropFirst()) }
        }
        let showSources = Set(ShowSpec.acceptedSchemes.map { $0 + ":" })
        for name in ["default-src", "frame-src", "worker-src", "object-src", "base-uri", "form-action"] {
            XCTAssertEqual(policy[name], ["'none'"], "\(name)")
        }
        XCTAssertEqual(Set(policy["connect-src"] ?? ["missing"]), showSources, "fetch and WebSocket reach only the shown files")
        let fetchable = ["script-src", "style-src", "img-src", "font-src", "media-src", "connect-src"]
        for name in fetchable {
            let outside = (policy[name] ?? []).filter { !showSources.contains($0) && !["'unsafe-inline'", "'unsafe-eval'", "data:", "blob:"].contains($0) }
            XCTAssertEqual(outside, [], "\(name) must load only from the show scheme")
        }
        // A refused asset still carries the fence.
        let refused = try await served(remote, url: URL(string: "\(ShowSpec.scheme)://studio/elsewhere.html")!)
        XCTAssertNotNil(refused.value(forHTTPHeaderField: "Content-Security-Policy"))

        let open = try await served(local, url: local.address)
        XCTAssertEqual(open.statusCode, 200)
        XCTAssertNil(open.value(forHTTPHeaderField: "Content-Security-Policy"), "a show from this Mac is served as before")
    }

    @MainActor
    private func served(_ session: ShowViewerSession, url: URL) async throws -> HTTPURLResponse {
        let handler = try XCTUnwrap(session.schemeHandler)
        let task = FakeSchemeTask(url: url)
        handler.start(task)
        let deadline = Date().addingTimeInterval(5)
        while !task.finished, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        return try XCTUnwrap(task.response as? HTTPURLResponse)
    }

    // Display only: no browser verb drives a viewer, from any caller.
    func testBrowserVerbsAreRefusedOnAViewer() {
        let viewer = UUID()
        ShowViewerIndex.shared.insert(viewer)
        defer { ShowViewerIndex.shared.remove(viewer) }
        for method in ["browser.eval", "browser.click", "browser.navigate", "browser.snapshot", "browser.fill", "browser.screenshot"] {
            guard case .err(let code, _, _)? = TerminalController.showViewerBrowserRefusal(method: method, params: ["surface_id": viewer.uuidString]) else {
                return XCTFail(method)
            }
            XCTAssertEqual(code, ShowSpec.Code.displayOnly)
        }
        XCTAssertNil(TerminalController.showViewerBrowserRefusal(method: "browser.open_split", params: ["surface_id": viewer.uuidString]))
        XCTAssertNil(TerminalController.showViewerBrowserRefusal(method: "browser.eval", params: ["surface_id": UUID().uuidString]))
    }

    // 13: only an Option mouse-down on a viewer starts point and say; the mail
    // names the showing panel exactly and carries selector, text, shot and hash.
    func testPointAndSayGateAndMail() throws {
        XCTAssertTrue(ShowPointAndSay.accepts(type: .leftMouseDown, modifiers: [.option], isViewer: true))
        XCTAssertFalse(ShowPointAndSay.accepts(type: .leftMouseDown, modifiers: [.option], isViewer: false))
        XCTAssertFalse(ShowPointAndSay.accepts(type: .leftMouseDown, modifiers: [], isViewer: true))
        XCTAssertFalse(ShowPointAndSay.accepts(type: .leftMouseDown, modifiers: [.option, .command], isViewer: true))
        XCTAssertFalse(ShowPointAndSay.accepts(type: .keyDown, modifiers: [.option], isViewer: true))

        let element = ShowPointAndSay.Element(selector: "#lanes > li:nth-of-type(2)", tag: "li", text: "Merge lane",
                                              rect: CGRect(x: 10, y: 20, width: 100, height: 30), hash: "#state=3",
                                              url: "c11-show://studio/p/x.html#state=3", title: "Flag Lanes")
        let body = ShowPointAndSay.body(line: "make this lane red", element: element, address: "c11-show://studio/p/x.html",
                                        screenshot: "/home/a/.local/share/c11/show/shots/1.png")
        for part in ["make this lane red", "#lanes > li:nth-of-type(2)", "Merge lane", "c11-show://studio/p/x.html#state=3",
                     "/home/a/.local/share/c11/show/shots/1.png"] {
            XCTAssertTrue(body.contains(part), part)
        }
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("show-mail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let id = try ShowPointAndSay.mail(to: panel, workspace: workspace, body: body, stateURL: state)
        let file = MailboxLayout.outboxURL(state: state, workspaceId: workspace).appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        let envelope = try MailboxEnvelope.validate(data: Data(contentsOf: file))
        XCTAssertEqual(envelope.raw["to"] as? String, "id:" + panel.uuidString)
        XCTAssertEqual(envelope.raw["topic"] as? String, ShowPointAndSay.topic)
        let crop = ShowPointAndSay.cropRect(element: element.rect, zoom: 2, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(crop, CGRect(x: 8, y: 28, width: 224, height: 84))
    }

    // MARK: Review 1 repairs

    private func signedEntry(_ source: ShowSourceSpec, at: Int64, state: ShowRecord.State = .noticed) -> ShowRecord.Entry {
        ShowRecord.Entry(id: UUID().uuidString, source: source, at: at, state: state)
    }

    // R1.1: a show recorded while away passes the same preflight as a live one:
    // a refused URL never becomes a Feed row and never reaches the opener, and
    // the controller itself refuses it.
    @MainActor
    func testAwayRecordOpeningRunsTheSamePreflight() async {
        ShowOwnAddresses.provider = { .init(names: ["laptop"], addresses: ["198.51.100.20"]) }
        defer { ShowOwnAddresses.provider = nil }
        let away = ShowAwayShows()
        var opened: [String] = []
        away.workspaceOf = { [workspace] _ in workspace }
        away.publish = { _, _ in }
        away.opener = { request, done in opened.append(request.source.target); done(nil) }
        let bad = ["http://localhost:5173", "file:///Users/a/page.html", "ssh://studio", "http://laptop:8737/", "http://[::1]/"]
        let items = (bad + ["https://example.com/ok"]).enumerated().map { index, url in
            ShowAwayEntry(panel: panel, machine: "studio", container: nil, entry: signedEntry(.url(url), at: Int64(index)))
        }
        away.reconcile(panel: panel, items: ShowAwayShows.admissible(items))
        XCTAssertEqual(away.pending[panel]?.values.map(\.entry.source.target), ["https://example.com/ok"])
        away.operatorOpened(panel: panel)
        XCTAssertEqual(opened, ["https://example.com/ok"])
        for url in bad {
            let request = ShowOpenRequest(caller: panel, source: .url(url), origin: .remote(machine: "studio", container: nil),
                                          fetcher: nil, initialStat: nil)
            guard case .failure(.refused) = ShowViewerController.shared.open(request) else { return XCTFail(url) }
            let checked = await ShowPreflight.check(.url(url), origin: .remote(machine: "studio", container: nil), fetcher: nil)
            guard case .failure(let refused) = checked else { return XCTFail(url) }
            XCTAssertEqual(refused.code, ShowSpec.Code.refusedURL)
        }
    }

    // R1.2: a link a viewer opens in a new panel stays in the viewer.
    func testViewerNewPanelLinksStayInTheViewer() {
        XCTAssertEqual(ShowViewerNavigation.newPanelLink(isViewer: true), .sameViewer)
        XCTAssertEqual(ShowViewerNavigation.newPanelLink(isViewer: false), .newPanel)
    }

    // R1.3: an address the Mac gains after the first check is refused at once.
    func testOwnAddressesAreReadFreshOnEachCheck() {
        var addresses: Set<String> = ["192.168.1.20"]
        ShowOwnAddresses.provider = { .init(names: [], addresses: addresses) }
        defer { ShowOwnAddresses.provider = nil }
        let origin = ShowOrigin.remote(machine: "studio", container: nil)
        XCTAssertNil(ShowPreflight.urlRefusal("http://10.0.0.7:3000/", origin: origin))
        addresses.insert("10.0.0.7")   // the laptop joined another network
        XCTAssertNotNil(ShowPreflight.urlRefusal("http://10.0.0.7:3000/", origin: origin))
    }

    // R1.4: a redirect's final page settles the load; the initial blank
    // document does not. A re-show reloads in place only on the shown page.
    func testRedirectSettlesTheLoadAndReShowReturnsToTheSource() {
        XCTAssertTrue(ShowLoadJudge.countsAsLoad("https://host/docs/"))
        XCTAssertTrue(ShowLoadJudge.countsAsLoad("c11-show://local/p/x.html#state=2"))
        XCTAssertFalse(ShowLoadJudge.countsAsLoad("about:blank"))
        XCTAssertFalse(ShowLoadJudge.countsAsLoad(nil))
        let address = URL(string: "c11-show://studio/p/x.html")!
        XCTAssertEqual(ShowRefresh.decide(currentURL: URL(string: "c11-show://studio/p/x.html#state=3"), address: address), .reloadInPlace)
        XCTAssertEqual(ShowRefresh.decide(currentURL: URL(string: "https://example.com/next"), address: address), .returnToSource)
        XCTAssertEqual(ShowRefresh.decide(currentURL: URL(string: "c11-show://studio/p/other.html"), address: address), .returnToSource)
        XCTAssertEqual(ShowRefresh.decide(currentURL: nil, address: address), .returnToSource)
        // A query is part of the source: a link to ?version=2 is another page.
        let report = URL(string: "https://example.com/report?version=1")!
        XCTAssertEqual(ShowRefresh.decide(currentURL: URL(string: "https://example.com/report?version=2"), address: report), .returnToSource)
        XCTAssertEqual(ShowRefresh.decide(currentURL: URL(string: "https://example.com/report?version=1#tab=3"), address: report), .reloadInPlace)
    }

    // R1.5: empty markdown is blank, not loaded.
    @MainActor
    func testEmptyMarkdownIsBlank() {
        let session = ShowViewerSession(caller: panel, source: .path("/Users/a/empty.md"), origin: .local,
                                        fetcher: ShowLocalFetcher(), callerTitle: "A")
        let check = ShowLoadCheck()
        ShowViewerController.shared.awaitMarkdownRender(session, text: " \n\t\n", check: check)
        XCTAssertEqual(check.wait(seconds: 0.1).status, .blank)
    }

    // R1.6: an unprimed viewer (restored) loads on its first stat, and a failed
    // changed-file load is retried on the same stat after the link returns.
    func testReloadNeverLosesAChange() {
        var restored = ShowReloadRule()
        XCTAssertEqual(restored.observe(ShowFileStat(size: 5, mtime: "9")), .changed, "hidden restore, edit, reveal")
        var rule = ShowReloadRule(last: ShowFileStat(size: 1, mtime: "1"))
        let changed = ShowFileStat(size: 2, mtime: "2")
        XCTAssertEqual(rule.observe(changed), .changed)
        rule.failed()                                     // the read failed in a link outage
        XCTAssertEqual(rule.last, ShowFileStat(size: 1, mtime: "1"), "a stat counts only once its bytes loaded")
        XCTAssertEqual(rule.observe(changed), .changed, "same stat after reconnect still loads")
        rule.loaded(changed)
        XCTAssertEqual(rule.observe(changed), .unchanged)
    }

    // R1.7: Feed holds exactly what each record read says: a closed or
    // replaced away show disappears; close matching is one rule everywhere.
    @MainActor
    func testFeedReconcilesClosedAndReplacedAwayShows() async throws {
        let store = FakeRecordStore()
        var record = ShowRecord(panel: panel)
        let first = signedEntry(.path("/a/x.html", dir: "/a"), at: 1, state: .waiting)
        record.entries = [first]
        store.put(record)
        let verify: (ShowRecord.Entry) -> Bool = { _ in true }
        let away = ShowAwayShows()
        away.workspaceOf = { [workspace] _ in workspace }
        var facts: [FeedShowFact?] = []
        away.publish = { _, fact in facts.append(fact) }
        func drainInto() async throws {
            let drained = await ShowRecordDrain.drain(store: store, machine: "studio", panel: panel, verified: verify)
            let entries = try XCTUnwrap(drained)
            away.reconcile(panel: panel, items: entries.map { ShowAwayEntry(panel: self.panel, machine: "studio", container: nil, entry: $0) })
        }
        try await drainInto()
        XCTAssertEqual(away.pending[panel]?.count, 1)
        // Re-shown while away: the record keeps one entry for the source, with a new id.
        var replaced = try XCTUnwrap(store.record(panel))
        replaced.upsert(id: UUID().uuidString, source: first.source, at: 2, state: .waiting)
        store.put(replaced)
        try await drainInto()
        XCTAssertEqual(away.pending[panel]?.count, 1)
        XCTAssertNotEqual(away.pending[panel]?.keys.first, first.id)
        // Closed remotely while away: the row goes.
        var closed = try XCTUnwrap(store.record(panel))
        closed.close(source: .path("/a/x.html"))   // no --dir: still names the --dir show
        store.put(closed)
        try await drainInto()
        XCTAssertNil(away.pending[panel])
        XCTAssertEqual(facts.last, .some(nil))
        // A live `show close` without --dir drops a row shown with --dir.
        away.reconcile(panel: panel, items: [ShowAwayEntry(panel: panel, machine: "studio", container: nil,
                                                          entry: signedEntry(.path("/a/x.html", dir: "/a"), at: 3))])
        away.drop(panel: panel, source: .path("/a/x.html"))
        XCTAssertNil(away.pending[panel])
        XCTAssertTrue(ShowSourceSpec.closes(.path("/a/x.html"), .path("/a/x.html", dir: "/a")))
        XCTAssertFalse(ShowSourceSpec.closes(.path("/a/x.html", dir: "/b"), .path("/a/x.html", dir: "/a")))
        XCTAssertTrue(ShowSourceSpec.closes(nil, .url("https://x")))
    }

    func testUnreadableRecordChangesNothing() async {
        final class Failing: ShowRecordStore, @unchecked Sendable {
            func load(machine: String, panel: UUID) async throws -> (record: ShowRecord?, version: UInt64) {
                throw C11RelayStoreError.unavailable("down")
            }
            func save(machine: String, record: ShowRecord, version: UInt64) async throws -> UInt64 { 0 }
        }
        let entries = await ShowRecordDrain.drain(store: Failing(), machine: "studio", panel: panel, verified: { _ in true })
        XCTAssertNil(entries)
        let gone = await ShowRecordDrain.drain(store: FakeRecordStore(), machine: "studio", panel: panel, verified: { _ in true })
        XCTAssertEqual(gone, [])
    }

    // R1.8: a restored viewer keeps its saved page, its hibernation and its age.
    @MainActor
    func testRestoreKeepsSavedPageHibernationAndAge() {
        let local = ShowViewerSession(caller: panel, source: .path("/a/x.html"), origin: .local, fetcher: ShowLocalFetcher(), callerTitle: "A")
        let saved = URL(string: "c11-show://local/a/x.html#state=3")!
        XCTAssertEqual(ShowViewerController.restoredLoad(session: local, savedURL: saved, hibernated: false), .savedURL)
        XCTAssertEqual(ShowViewerController.restoredLoad(session: local, savedURL: saved, hibernated: true), .hibernated)
        XCTAssertEqual(ShowViewerController.restoredLoad(session: local, savedURL: nil, hibernated: false), .source)
        let remoteURL = ShowViewerSession(caller: panel, source: .url("http://studio:5173/"), origin: .remote(machine: "studio", container: nil),
                                          fetcher: nil, callerTitle: "A")
        let savedRemote = URL(string: "http://studio:5173/#tab=2")!
        XCTAssertEqual(ShowViewerController.restoredLoad(session: remoteURL, savedURL: savedRemote, hibernated: false), .preflight(savedRemote))
        // Age: the ninth show replaces the oldest original viewer, not the first restored.
        var registry = ShowRegistry()
        let panels = (0..<ShowSpec.maxViewersPerCaller).map { _ in UUID() }
        for (index, viewer) in panels.enumerated().reversed() {   // restored in reverse order
            registry.opened(panel: viewer, caller: panel, sourceKey: "s\(index)", at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(registry.decide(caller: panel, sourceKey: "ninth"), .open(replacing: panels[0], reopening: false))
    }

    // R1 Grok NB4: a remote markdown viewer's tab shows the file's name.
    @MainActor
    func testRemoteMarkdownViewerTitleIsTheFileName() {
        let panel = MarkdownPanel(workspaceId: workspace, remoteShowKey: "c11-show://studio/p/docs/notes%20v2.md")
        XCTAssertEqual(panel.displayTitle, "notes v2.md")
        panel.close()
    }

    // R1.9: `--dir` equal to home serves sibling assets.
    func testDirEqualToHomeServesSiblings() {
        let scope = ShowServeScope(source: .path("/Users/a/index.html", dir: "/Users/a", home: "/Users/a"))
        XCTAssertEqual(scope.entryURLPath, "/index.html")
        XCTAssertEqual(scope.rootURLBase, "/")
        XCTAssertEqual(scope.target(percentEncodedPath: "/index.html"), .entry)
        XCTAssertEqual(scope.target(percentEncodedPath: "/app.css"), .asset(path: "/Users/a/app.css"))
        XCTAssertEqual(scope.target(percentEncodedPath: "/css/app.css"), .asset(path: "/Users/a/css/app.css"))
        let trailing = ShowServeScope(source: .path("/Users/a/index.html", dir: "/Users/a/", home: "/Users/a/"))
        XCTAssertEqual(trailing.target(percentEncodedPath: "/app.css"), .asset(path: "/Users/a/app.css"))
        XCTAssertEqual(ShowAddress.urlPath(forAbsolute: "/Users/a", home: "/Users/a"), "/")
    }

    // R1 NB2: the worker's request context rides along to main.
    func testMainHopCarriesTheRequestContext() {
        let caller = UUID()
        let done = expectation(description: "hop")
        var seen: UUID?
        var focusAllowed: Bool?
        DispatchQueue.global().async {
            let context = SocketCommandContext(method: ShowSpec.openMethod, allowsFocus: false, callerPanelId: caller)
            SocketCommandContext.withContext(context) {
                _ = ShowMainHop.run(seconds: 5) {
                    seen = SocketCommandContext.current?.callerPanelId
                    focusAllowed = SocketCommandContext.current?.allowsFocus
                }
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 6)
        XCTAssertEqual(seen, caller)
        XCTAssertEqual(focusAllowed, false)
    }

    // MARK: Review 2 repairs

    // R2.1: a `linuxbox-seat` caller (`exec -a <harness> incus exec …`): argv[0] is
    // the harness, the process is incus. Its files are read in its container.
    func testVelaSeatForegroundIsAContainer() {
        let wrapped = ["claude", "exec", "ws-54f6260c-f7d201d7", "--user", "1000", "--env", "C11_AGENT_TYPE=claude-code",
                       "--", "bash", "-lc", "exec \"$@\"", "bash", "claude", "--model", "claude-sonnet-5-5"]
        XCTAssertEqual(ShowOrigin.container(foregroundName: "incus", argv: wrapped), "ws-54f6260c-f7d201d7")
        XCTAssertNil(ShowOrigin.container(foregroundName: "claude", argv: wrapped), "not incus at all")
        XCTAssertNil(ShowOrigin.container(foregroundName: "incus", argv: ["claude", "exec", "--project", "x"]))
        let record = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "core-1", localAddress: "t9"), state: .running,
                                      labels: ["c11.panel": panel.uuidString], machineName: "linuxbox", machineAvailability: .connected,
                                      foreground: HCForeground(name: "incus", argv: wrapped))
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let inventory = HCInventorySnapshot(readiness: .ready(revision), revision: revision, records: [record.key: record],
                                            machines: ["linuxbox": .connected])
        let context = SocketCommandContext(method: "connection", allowsFocus: false, callerPanelId: panel, hcInventory: inventory)
        context.relayMachine = "linuxbox"
        XCTAssertEqual(TerminalController.showOrigin(caller: panel, context: context),
                       .remote(machine: "linuxbox", container: "ws-54f6260c-f7d201d7"))
    }

    // R2.2: a container agent's screenshot is pushed into its container and the
    // mail names that path; every argv passes the session's exec gate.
    func testPointAndSayScreenshotReachesAContainerAgent() async {
        final class Link: ShowLinkHost, @unchecked Sendable {
            let lock = NSLock()
            var execs: [[String]] = []
            var writes: [String] = []
            func showExec(machine: String, argv: [String], timeout: TimeInterval) async throws -> ShowExecResult {
                lock.lock(); execs.append(argv); lock.unlock()
                return ShowExecResult(code: 0, stdout: Data())
            }
            func showWriteFile(machine: String, path: String, data: Data) async throws -> String {
                lock.lock(); writes.append(path); lock.unlock()
                return "/home/u/" + path
            }
        }
        let link = Link()
        let hosts = ShowHosts()
        let ref = C11RelayLinkRef(session: "c11", machine: "linuxbox", linkID: "0123456789abcdef")
        hosts.set(.init(host: link, records: FakeRecordStore(), currentLinkID: { ref.linkID }), session: ref.session, machine: ref.machine)
        let name = "6b7a1d2e-0000-4000-8000-0000000000cc.png"
        let path = await ShowPointAndSayController.store(png: Data([1, 2, 3]), origin: .remote(machine: "linuxbox", container: "ws-7", link: ref),
                                                         hosts: hosts, name: name)
        XCTAssertEqual(path, "/tmp/c11-show/shots/" + name)
        XCTAssertEqual(link.writes, [".local/share/c11/show/shots/" + name])
        XCTAssertEqual(link.execs.first, ["incus", "file", "push", "--create-dirs", "--mode", "0644", "--",
                                          "/home/u/.local/share/c11/show/shots/" + name, "ws-7/tmp/c11-show/shots/" + name])
        for argv in link.execs { XCTAssertTrue(ShowExecGate.allowsArgv(argv), "\(argv)") }
        let plain = await ShowPointAndSayController.store(png: Data([1]), origin: .remote(machine: "linuxbox", container: nil, link: ref),
                                                          hosts: hosts, name: name)
        XCTAssertEqual(plain, "/home/u/.local/share/c11/show/shots/" + name)
    }

    // MARK: C11H-359 (L3): a show reads through the link that verified its caller

    private final class NamedLink: ShowLinkHost, @unchecked Sendable {
        let name: String
        private let lock = NSLock()
        private var runs: [[String]] = []
        init(_ name: String) { self.name = name }
        var execs: [[String]] { lock.lock(); defer { lock.unlock() }; return runs }
        func showExec(machine: String, argv: [String], timeout: TimeInterval) async throws -> ShowExecResult {
            lock.lock(); runs.append(argv); lock.unlock()
            if argv.contains("stat") { return ShowExecResult(code: 0, stdout: Data("regular file|5|1.0".utf8)) }
            return ShowExecResult(code: 0, stdout: Data(name.utf8))
        }
        func showWriteFile(machine: String, path: String, data: Data) async throws -> String { "/\(name)/\(path)" }
    }

    /// Two shards each link a machine under the same name, to different
    /// accounts. A caller verified on one link reads through that link only,
    /// whichever registered last; a link whose secret changed since reads
    /// nothing; a viewer with no link (saved before links were kept) reads nothing.
    func testAShowReadsOnlyThroughTheLinkThatVerifiedItsCaller() async throws {
        final class Secrets: @unchecked Sendable {
            private let lock = NSLock()
            private var ids: [String: String] = [:]
            func set(_ id: String?, for session: String) { lock.lock(); ids[session] = id; lock.unlock() }
            func id(_ session: String) -> String? { lock.lock(); defer { lock.unlock() }; return ids[session] }
        }
        let hosts = ShowHosts(), secrets = Secrets()
        let operatorLink = NamedLink("operator"), otherLink = NamedLink("other")
        secrets.set("aaaaaaaaaaaaaaaa", for: "c11")
        secrets.set("bbbbbbbbbbbbbbbb", for: "c11-s1")
        hosts.set(.init(host: operatorLink, records: FakeRecordStore(), currentLinkID: { secrets.id("c11") }),
                  session: "c11", machine: "studio")
        hosts.set(.init(host: otherLink, records: FakeRecordStore(), currentLinkID: { secrets.id("c11-s1") }),
                  session: "c11-s1", machine: "studio")
        let fromOther = C11RelayLinkRef(session: "c11-s1", machine: "studio", linkID: "bbbbbbbbbbbbbbbb")
        let fromOperator = C11RelayLinkRef(session: "c11", machine: "studio", linkID: "aaaaaaaaaaaaaaaa")
        let read = try await ShowOrigin.remote(machine: "studio", container: nil, link: fromOther).fetcher(hosts: hosts)
            .read("/Users/x/plan.md", root: nil, maxBytes: 100)
        XCTAssertEqual(String(decoding: read, as: UTF8.self), "other")
        XCTAssertTrue(operatorLink.execs.isEmpty, "the other shard's caller never reads through the operator's link")
        _ = try await ShowOrigin.remote(machine: "studio", container: nil, link: fromOperator).fetcher(hosts: hosts).stat("/a")
        XCTAssertEqual(operatorLink.execs.count, 1)
        // The link was re-made: its secret is new, and the old caller's viewer reads nothing.
        secrets.set("cccccccccccccccc", for: "c11-s1")
        for origin in [ShowOrigin.remote(machine: "studio", container: nil, link: fromOther),
                       ShowOrigin.remote(machine: "studio", container: nil)] {
            do {
                _ = try await origin.fetcher(hosts: hosts).stat("/a")
                XCTFail("\(origin): fails closed")
            } catch let error as ShowFetchError {
                guard case .unreachable = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(otherLink.execs.count, 1)
        // A ref naming another machine than the origin's never stands in.
        let crossed = ShowOrigin.remote(machine: "vm", container: nil, link: fromOperator)
        do { _ = try await crossed.fetcher(hosts: hosts).stat("/a"); XCTFail("a link to another machine") } catch {}
        XCTAssertEqual(operatorLink.execs.count, 1)
    }

    /// A link host whose `stat` finds nothing: a relayed `show` ends at its
    /// preflight, with no viewer opened.
    private final class EmptyLink: ShowLinkHost, @unchecked Sendable {
        private let lock = NSLock()
        private var runs: [[String]] = []
        var execs: [[String]] { lock.lock(); defer { lock.unlock() }; return runs }
        func showExec(machine: String, argv: [String], timeout: TimeInterval) async throws -> ShowExecResult {
            lock.lock(); runs.append(argv); lock.unlock()
            return ShowExecResult(code: 1, stdout: Data())
        }
        func showWriteFile(machine: String, path: String, data: Data) async throws -> String { path }
    }

    /// End to end through the relay executor and the socket dispatcher (which
    /// rebuilds the request context): a relayed `show` reads through the link
    /// that verified its caller. With only another shard's link to the same
    /// machine name registered, it reads nothing and says there is no link.
    func testARelayedShowReadsThroughTheVerifyingLinkEndToEnd() async throws {
        let session = "c11-l3-\(UUID().uuidString.prefix(8).lowercased())"
        let ref = C11RelayLinkRef(session: session, machine: "studio", linkID: "0123456789abcdef")
        let verifying = EmptyLink(), stranger = EmptyLink()
        defer {
            ShowHosts.shared.set(nil, session: session, machine: "studio")
            ShowHosts.shared.set(nil, session: session + "-other", machine: "studio")
        }
        ShowHosts.shared.set(.init(host: stranger, records: FakeRecordStore(), currentLinkID: { "fedcba9876543210" }),
                             session: session + "-other", machine: "studio")
        let admitted = try admit(#"{"source":{"kind":"path","path":"/Users/a/x.html"}}"#).get()
        var caller = C11RelayPolicy.VerifiedCaller(panel: panel, workspace: workspace, machine: "studio", terminal: "t3")
        caller.link = ref
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let snapshot = HCInventorySnapshot(readiness: .ready(revision), revision: revision, machines: ["studio": .connected])
        let executor = C11RelaySocketExecutor(controller: TerminalController.shared)
        let refused = await executor.execute(admitted, caller: caller, originHost: "studio", machines: ["studio"], snapshot: snapshot)
        XCTAssertTrue(refused.contains(ShowSpec.Code.unreachable), refused)
        XCTAssertTrue(stranger.execs.isEmpty, "another shard's link to the same name is never read through")
        ShowHosts.shared.set(.init(host: verifying, records: FakeRecordStore(), currentLinkID: { ref.linkID }),
                             session: session, machine: "studio")
        let read = await executor.execute(admitted, caller: caller, originHost: "studio", machines: ["studio"], snapshot: snapshot)
        XCTAssertFalse(verifying.execs.isEmpty, "the verifying link reads the file: \(read)")
        XCTAssertTrue(verifying.execs.allSatisfy { $0.last == "/Users/a/x.html" }, "\(verifying.execs)")
        XCTAssertTrue(stranger.execs.isEmpty)
    }

    /// The id of a link's current secret, as a test re-makes it.
    private final class LinkSecret: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String
        init(_ value: String) { self.value = value }
        var id: String {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    /// An away show is opened through the link that signed its entry, and its
    /// record is marked opened through that link only while the link's secret
    /// is still the one it signed with: a row from before a re-link still
    /// opens, but writes no mark through the re-made link.
    @MainActor
    func testAnAwayShowOpensThroughTheLinkThatSignedIt() async throws {
        let ref = C11RelayLinkRef(session: "c11-s1", machine: "studio", linkID: "0123456789abcdef")
        let secret = LinkSecret(ref.linkID)
        let store = FakeRecordStore(), hosts = ShowHosts()
        hosts.set(.init(host: NamedLink("signing"), records: store, currentLinkID: { secret.id }),
                  session: ref.session, machine: ref.machine)
        let away = ShowAwayShows()
        away.hosts = hosts
        away.workspaceOf = { [workspace] _ in workspace }
        away.publish = { _, _ in }
        var origins: [ShowOrigin] = []
        away.opener = { request, done in origins.append(request.origin); done(nil) }
        let first = signedEntry(.path("/a/x.html"), at: 1, state: .waiting)
        let second = signedEntry(.path("/a/y.html"), at: 2, state: .waiting)
        var record = ShowRecord(panel: panel)
        record.entries = [first, second]
        store.put(record)
        func state(_ id: String) -> ShowRecord.State? { store.record(panel)?.entries.first { $0.id == id }?.state }
        away.reconcile(panel: panel, items: [ShowAwayEntry(panel: panel, machine: "studio", container: "seat", entry: first, link: ref)])
        away.operatorOpened(panel: panel)
        XCTAssertEqual(origins, [.remote(machine: "studio", container: "seat", link: ref)])
        let deadline = Date().addingTimeInterval(5)
        while state(first.id) != .opened, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(state(first.id), .opened, "marked through the link that signed it")
        // The link was re-made: its secret is new.
        secret.id = "relinked-secret"
        away.reconcile(panel: panel, items: [ShowAwayEntry(panel: panel, machine: "studio", container: "seat", entry: second, link: ref)])
        away.operatorOpened(panel: panel)
        XCTAssertEqual(origins.count, 2)
        XCTAssertNil(away.pending[panel], "the row leaves Feed once its viewer opened")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(state(second.id), .waiting, "no mark is written through the re-made link")
    }

    @MainActor
    private func served(_ viewer: ShowViewerSession) async throws -> HTTPURLResponse {
        let handler = try XCTUnwrap(viewer.schemeHandler)
        let task = FakeSchemeTask(url: viewer.address)
        handler.start(task)
        let deadline = Date().addingTimeInterval(5)
        while !task.finished, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        return try XCTUnwrap(task.response as? HTTPURLResponse)
    }

    /// A re-show keeps its viewer as it is only when the viewer reads through
    /// the request's link. A viewer saved without a link, or holding a link
    /// re-made since, takes the request's verified link where it stands: its
    /// page and the file it watches come through that link, and it saves that
    /// link. In another container the source is another file: its own viewer.
    @MainActor
    func testAReShowGivesAViewerWithoutItsCurrentLinkTheRequestsLink() async throws {
        let current = C11RelayLinkRef(session: "c11", machine: "studio", linkID: "aaaaaaaaaaaaaaaa")
        let remade = C11RelayLinkRef(session: "c11", machine: "studio", linkID: "bbbbbbbbbbbbbbbb")
        let hosts = ShowHosts(), link = NamedLink("current")
        hosts.set(.init(host: link, records: FakeRecordStore(), currentLinkID: { current.linkID }), session: "c11", machine: "studio")
        let requested = ShowOrigin.remote(machine: "studio", container: nil, link: current)
        let request = ShowOpenRequest(caller: panel, source: .path("/a/x.html"), origin: requested,
                                      fetcher: requested.fetcher(hosts: hosts), initialStat: nil)
        for stale in [ShowOrigin.remote(machine: "studio", container: nil), .remote(machine: "studio", container: nil, link: remade)] {
            XCTAssertFalse(ShowViewerController.keepsSession(existing: stale, requested: requested), "\(stale)")
            let viewer = ShowViewerSession(caller: panel, source: .path("/a/x.html"), origin: stale,
                                           fetcher: stale.fetcher(hosts: hosts), callerTitle: "A")
            let dark = try await served(viewer)
            XCTAssertEqual(dark.statusCode, 502, "\(stale) reads nothing")
            XCTAssertTrue(ShowViewerController.takeReshow(request, into: viewer))
            XCTAssertEqual(viewer.origin, requested, "\(stale)")
            let page = try await served(viewer)
            XCTAssertEqual(page.statusCode, 200, "\(stale): the page comes through the request's link")
            // The fetcher its reload poller and markdown loads read through.
            let fetcher = try XCTUnwrap(viewer.fetcher)
            let stat = try await fetcher.stat("/a/x.html")
            XCTAssertEqual(stat, ShowFileStat(size: 5, mtime: "1.0"))
            XCTAssertEqual(try XCTUnwrap(ShowViewerSession.restored(from: viewer.metadataValue)).origin, requested,
                           "\(stale): it saves the new link")
        }
        XCTAssertTrue(link.execs.contains { $0.first == "cat" }, "\(link.execs)")
        // Kept as it is: a viewer on the request's link, and one from this Mac.
        XCTAssertTrue(ShowViewerController.keepsSession(existing: requested, requested: requested))
        XCTAssertTrue(ShowViewerController.keepsSession(existing: .local, requested: .local))
        let viewer = ShowViewerSession(caller: panel, source: .path("/a/x.html"), origin: requested,
                                       fetcher: requested.fetcher(hosts: hosts), callerTitle: "A")
        var moved = request
        moved.origin = .remote(machine: "studio", container: "seat", link: current)
        XCTAssertFalse(ShowViewerController.takeReshow(moved, into: viewer))
        XCTAssertEqual(viewer.origin, requested)
    }

    /// A link host whose `stat` speaks one dialect only: GNU (`-c`) or BSD (`-f`).
    private final class DialectLink: ShowLinkHost, @unchecked Sendable {
        let option: String
        init(_ option: String) { self.option = option }
        func showExec(machine: String, argv: [String], timeout: TimeInterval) async throws -> ShowExecResult {
            guard argv.contains("stat"), argv.contains(option) else { return ShowExecResult(code: 1, stdout: Data()) }
            return ShowExecResult(code: 0, stdout: Data("regular file|7|2.5".utf8))
        }
        func showWriteFile(machine: String, path: String, data: Data) async throws -> String { path }
    }

    /// The stat dialect learned on one link is never another's. Link A speaks
    /// GNU stat and link B only BSD stat, under one machine name: after a stat
    /// through A, a stat through B still finds the file. Each case has its own
    /// machine name, as the dialect cache is shared by the process.
    func testAStatDialectLearnedOnOneLinkIsNotAnotherShardsLink() async throws {
        try await assertStatDialectStaysWithItsLink(machine: "rigel-l3-dialect-shard", remade: false)
    }

    /// The same, with B the same shard's link re-made (a new secret, a new host).
    func testAStatDialectLearnedOnOneLinkIsNotTheLinkReMadeSince() async throws {
        try await assertStatDialectStaysWithItsLink(machine: "rigel-l3-dialect-remade", remade: true)
    }

    private func assertStatDialectStaysWithItsLink(machine: String, remade: Bool) async throws {
        let hosts = ShowHosts()
        let a = C11RelayLinkRef(session: "c11", machine: machine, linkID: "aaaaaaaaaaaaaaaa")
        let b = C11RelayLinkRef(session: remade ? "c11" : "c11-s1", machine: machine, linkID: "bbbbbbbbbbbbbbbb")
        hosts.set(.init(host: DialectLink("-c"), records: FakeRecordStore(), currentLinkID: { a.linkID }), session: a.session, machine: machine)
        let throughA = try await ShowOrigin.remote(machine: machine, container: nil, link: a).fetcher(hosts: hosts).stat("/srv/x.html")
        XCTAssertEqual(throughA, ShowFileStat(size: 7, mtime: "2.5"))
        hosts.set(.init(host: DialectLink("-f"), records: FakeRecordStore(), currentLinkID: { b.linkID }), session: b.session, machine: machine)
        do {
            let throughB = try await ShowOrigin.remote(machine: machine, container: nil, link: b).fetcher(hosts: hosts).stat("/srv/x.html")
            XCTAssertEqual(throughB, ShowFileStat(size: 7, mtime: "2.5"))
        } catch {
            XCTFail("the file on link B was taken for missing: \(error)")
        }
    }

    /// The relayed caller's link reaches `show`'s origin, survives the
    /// dispatch and command-policy rebuilds of the context, and a viewer
    /// saves and restores it.
    @MainActor
    func testTheVerifyingLinkRidesTheContextAndTheSavedViewer() throws {
        let panel = UUID()
        let ref = C11RelayLinkRef(session: "c11-s2", machine: "studio", linkID: "0123456789abcdef")
        let context = SocketCommandContext(method: "connection", allowsFocus: false, callerPanelId: panel)
        context.relayMachine = "studio"
        context.relayLink = ref
        XCTAssertEqual(TerminalController.showOrigin(caller: panel, context: context),
                       .remote(machine: "studio", container: nil, link: ref))
        let rebuilt = SocketCommandContext.withContext(context) {
            TerminalController.shared.withSocketCommandPolicy(commandKey: "show.open", isV2: true) { SocketCommandContext.current }
        }
        XCTAssertEqual(rebuilt?.relayLink, ref)
        XCTAssertEqual(rebuilt?.relayMachine, "studio")
        let viewer = ShowViewerSession(caller: panel, source: .path("/a.html"), origin: .remote(machine: "studio", container: nil, link: ref),
                                       fetcher: nil, callerTitle: "A")
        let restored = try XCTUnwrap(ShowViewerSession.restored(from: viewer.metadataValue))
        XCTAssertEqual(restored.origin, .remote(machine: "studio", container: nil, link: ref))
        var older = viewer.metadataValue
        older["session"] = nil; older["link_id"] = nil
        XCTAssertEqual(try XCTUnwrap(ShowViewerSession.restored(from: older)).origin, .remote(machine: "studio", container: nil))
    }

    // R2 NB3: the relay session runs only what `c11 show` builds.
    func testExecGateAdmitsOnlyTheShowsShapes() {
        let fetcher = ShowHCFetcher(host: LocalExecHostForGate(), machine: "m", container: "ws-1")
        for argv in [fetcher.argv("cat", [], path: "/a/b.html"), fetcher.argv("realpath", [], path: "/a"),
                     fetcher.argv("stat", ShowHCFetcher.StatFlavor.gnu.options, path: "/a"),
                     ShowHCFetcher(host: LocalExecHostForGate(), machine: "m", container: nil).argv("stat", ShowHCFetcher.StatFlavor.bsd.options, path: "/a")] {
            XCTAssertTrue(ShowExecGate.allowsArgv(argv), "\(argv)")
        }
        for argv in [["sh", "-c", "id"], ["cat", "/etc/passwd"], ["cat", "--", "relative"], ["cat", "-v", "--", "/a"],
                     ["incus", "exec", "ws-1", "--", "sh", "--", "/a"], ["incus", "exec", "-x", "--", "cat", "--", "/a"],
                     ["rm", "-f", "--", "/home/u/.ssh/id_ed25519"], ["stat", "-c", "%n", "--", "/a"],
                     ["incus", "file", "push", "--create-dirs", "--mode", "0644", "--", "/etc/passwd", "ws-1/tmp/c11-show/shots/x.png"]] {
            XCTAssertFalse(ShowExecGate.allowsArgv(argv), "\(argv)")
        }
        XCTAssertFalse(ShowExecGate.allows(method: "machine.exec", params: ["line": .string("cat /etc/passwd")]))
        XCTAssertFalse(ShowExecGate.allows(method: "machine.exec",
                                           params: ["argv": .array([.string("cat"), .string("--"), .string("/a")]), "input": .string("eA==")]))
        XCTAssertTrue(ShowExecGate.allows(method: "file.write",
                                          params: ["path": .string(".local/share/c11/show/shots/6b7a1d2e-0000-4000-8000-0000000000cc.png")]))
        XCTAssertFalse(ShowExecGate.allows(method: "file.write", params: ["path": .string(".ssh/authorized_keys")]))
        XCTAssertFalse(ShowExecGate.allows(method: "file.write", params: ["path": .string(".local/share/c11/show/shots/../../x.png")]))
        XCTAssertTrue(ShowExecGate.allows(method: "doc.get", params: [:]))
    }

    // R2 NB2: a turn that ended after an unopened show wins the row and names the show.
    func testNewerTurnEndIsNotHiddenByAPendingShow() throws {
        var start = JournalTestData.draft(.turnStarted)
        start.turnID = "turn-1"
        let working = try XCTUnwrap(JournalTestData.fold(nil, start, seq: 1).snapshot)
        var stop = JournalTestData.draft(.turnCompleted)
        stop.turnID = "turn-1"
        let ended = try XCTUnwrap(JournalTestData.fold(working, stop, seq: 2).snapshot)
        let older = FeedShowFact(workspaceID: JournalTestData.workspace, panelID: JournalTestData.panel, names: ["x.html"],
                                 atMs: ended.sinceMs - 1, count: 1)
        let row = try XCTUnwrap(FeedProjector.project(journalRows: [ended], attention: [], notes: [:], scope: .all, shows: [older]).first)
        XCTAssertEqual(row.kind, .turnEnd)
        XCTAssertTrue(row.prompt?.contains("x.html") == true, "the show stays named on the row that opens it")
        var newer = older
        newer.atMs = ended.sinceMs + 1
        XCTAssertEqual(FeedProjector.project(journalRows: [ended], attention: [], notes: [:], scope: .all, shows: [newer]).first?.kind, .show)
    }

    // MARK: Verification repairs

    // V1: a show whose file is briefly unreachable stays in Feed with the
    // reason, and leaves only once its viewer opened.
    @MainActor
    func testAwayShowStaysUntilItsViewerOpens() {
        let away = ShowAwayShows()
        away.workspaceOf = { [workspace] _ in workspace }
        var facts: [FeedShowFact?] = []
        away.publish = { _, fact in facts.append(fact) }
        var outcome: String? = "show_not_found: /a/x.html: no such file"
        var attempts = 0
        away.opener = { _, done in attempts += 1; done(outcome) }
        let item = ShowAwayEntry(panel: panel, machine: "studio", container: nil,
                                 entry: signedEntry(.path("/a/x.html"), at: 1))
        away.reconcile(panel: panel, items: [item])
        away.operatorOpened(panel: panel)
        XCTAssertEqual(away.pending[panel]?.count, 1, "a failed open keeps the row")
        XCTAssertTrue(facts.last??.prompt.contains("no such file") == true, "the row says why")
        outcome = nil
        away.operatorOpened(panel: panel)
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(away.pending[panel])
        XCTAssertEqual(facts.last, .some(nil))
    }

    // V2: Feed filtering and the controller's last check never resolve host
    // names on the main thread; the off-main filter does.
    @MainActor
    func testNoHostNameResolutionOnMain() async {
        let saved = ShowOwnAddresses.resolveNames
        final class Calls: @unchecked Sendable { var main = 0, off = 0 }
        let calls = Calls()
        ShowOwnAddresses.resolveNames = { if Thread.isMainThread { calls.main += 1 } else { calls.off += 1 }; return [] }
        defer { ShowOwnAddresses.resolveNames = saved }
        let item = ShowAwayEntry(panel: panel, machine: "studio", container: nil, entry: signedEntry(.url("https://example.com/"), at: 1))
        let away = ShowAwayShows()
        away.publish = { _, _ in }
        away.reconcile(panel: panel, items: [item])
        _ = ShowViewerController.shared.open(ShowOpenRequest(caller: UUID(), source: .url("http://localhost:1/"),
                                                             origin: .remote(machine: "studio", container: nil), fetcher: nil, initialStat: nil))
        XCTAssertEqual(calls.main, 0)
        _ = await Task.detached { ShowAwayShows.admissible([item]) }.value
        XCTAssertEqual(calls.main, 0)
    }

    // V3: a new-panel link that loads in the viewer keeps the operator's
    // one-time plain-HTTP consent for that link's host only.
    func testSameViewerLinkKeepsTheOneTimeHTTPConsent() {
        let link = URL(string: "http://dev-box:5173/page")!
        XCTAssertEqual(ShowViewerNavigation.carriedConsent("dev-box", for: link), "dev-box")
        XCTAssertNil(ShowViewerNavigation.carriedConsent("other-host", for: link))
        XCTAssertNil(ShowViewerNavigation.carriedConsent("dev-box", for: URL(string: "https://dev-box/page")!))
        XCTAssertNil(ShowViewerNavigation.carriedConsent(nil, for: link))
    }
}

// C11H-247: point and say names its recipient, never sends into the void,
// and tells the truth about the page; the viewer keeps its own address.
final class ShowPointAndSayTruthTests: XCTestCase {
    private let shown = URL(string: "c11-show://studio/p/x.html")!

    // 1: the line above the field names the agent and its machine.
    func testRecipientLineNamesTitleAndMachine() {
        let line = ShowPointAndSay.recipientLine(title: "Show test (Studio)", machine: "Studio")
        XCTAssertTrue(line.contains("Show test (Studio)"), line)
        XCTAssertTrue(line.hasSuffix("Studio"), line)
        XCTAssertNotEqual(line, "Show test (Studio)")
    }

    // 2: "Sent" only from the dispatcher's own per-message record: a copy
    // that landed for the showing panel. A rejection, a failed inbox write,
    // and a note between folders (the old race) are never a delivery.
    func testDeliveryFollowsTheRealDispatcher() throws {
        let state = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("show-dispatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let workspace = UUID(), caller = UUID()
        for dir in [MailboxLayout.outboxURL(state: state, workspaceId: workspace),
                    MailboxLayout.processingURL(state: state, workspaceId: workspace),
                    MailboxLayout.rejectedURL(state: state, workspaceId: workspace)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        func dispatcher(live: [UUID]) -> MailboxDispatcher {
            MailboxDispatcher(workspaceId: workspace, stateURL: state,
                              resolver: MailboxPanelResolver(workspaceId: workspace, livePanels: { live }))
        }
        func outboxFile(_ id: String) -> URL {
            MailboxLayout.outboxURL(state: state, workspaceId: workspace).appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        }

        // Delivered: the copy landed.
        let ok = try ShowPointAndSay.mail(to: caller, workspace: workspace, body: "ok", stateURL: state)
        XCTAssertEqual(ShowPointAndSay.delivery(id: ok, stateURL: state), .pending)
        let live = dispatcher(live: [caller])
        live.dispatchOne(url: outboxFile(ok))
        live.log.flush()
        XCTAssertEqual(ShowPointAndSay.delivery(id: ok, stateURL: state), .delivered)

        // The inbox cannot be written: the dispatcher cleans up, but no copy landed.
        let inbox = MailboxLayout.inboxURL(state: state, workspaceId: workspace, panelId: caller)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: inbox.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path) }
        let blocked = try ShowPointAndSay.mail(to: caller, workspace: workspace, body: "blocked", stateURL: state)
        live.dispatchOne(url: outboxFile(blocked))
        live.log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: outboxFile(blocked).path))
        XCTAssertEqual(ShowPointAndSay.delivery(id: blocked, stateURL: state), .copyFailed)
        XCTAssertEqual(ShowPointAndSay.failureText(.copyFailed), ShowPointAndSay.Text.copyFailed)
        XCTAssertTrue(ShowPointAndSay.mayRetry(.copyFailed))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path)

        // Between folders (taken from the outbox, not yet rejected): still pending.
        let racing = try ShowPointAndSay.mail(to: caller, workspace: workspace, body: "racing", stateURL: state)
        let processing = MailboxLayout.processingURL(state: state, workspaceId: workspace)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: racing))
        try FileManager.default.moveItem(at: outboxFile(racing), to: processing)
        XCTAssertEqual(ShowPointAndSay.delivery(id: racing, stateURL: state), .pending)

        // The showing panel is gone: rejected, with the dispatcher's reason.
        let gone = try ShowPointAndSay.mail(to: caller, workspace: workspace, body: "gone", stateURL: state)
        let closed = dispatcher(live: [])
        closed.dispatchOne(url: outboxFile(gone))
        closed.log.flush()
        guard case .rejected(let reason) = ShowPointAndSay.delivery(id: gone, stateURL: state) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertTrue(reason.hasPrefix("no live panel"), reason)
        XCTAssertEqual(ShowPointAndSay.failureText(.rejected(reason)), ShowPointAndSay.Text.agentGone)
        XCTAssertTrue(ShowPointAndSay.mayRetry(.rejected(reason)))
        XCTAssertNil(ShowPointAndSay.failureText(.delivered))

        // A shared session: the dispatcher routes the panel's mail to its
        // session's mailbox owner in another workspace. That copy is the note
        // delivered, not a note still waiting.
        let alias = UUID(), owner = UUID(), ownerWorkspace = UUID()
        _ = try PanelMetadataStore.shared.setMetadata(workspaceId: ownerWorkspace, surfaceId: owner,
            partial: [MetadataKey.title: "owner", "mailbox.delivery": "stdin"], mode: .merge, source: .explicit)
        let shared = MailboxDispatcher(workspaceId: workspace, stateURL: state,
            resolver: MailboxPanelResolver(workspaceId: workspace,
                canonicalOwner: { $0 == alias ? (owner, ownerWorkspace) : nil }, livePanels: { [alias] }))
        shared.registerHandler(name: "stdin") { _, _, _ in .init(outcome: .ok) }
        let routed = try ShowPointAndSay.mail(to: alias, workspace: workspace, body: "shared", stateURL: state)
        shared.dispatchOne(url: outboxFile(routed))
        shared.log.flush()
        let ownerCopy = MailboxLayout.inboxURL(state: state, workspaceId: ownerWorkspace, panelId: owner)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: routed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerCopy.path))
        XCTAssertEqual(ShowPointAndSay.delivery(id: routed, stateURL: state), .delivered)
    }

    // 5: the watch outlasts a slow dispatcher: a rejection that lands after
    // the old three-second cut-off is still seen.
    func testDeliveryWatchSeesALateRejection() async {
        let start = Date()
        let late = await ShowPointAndSayController.watchDelivery(interval: 0.1) {
            Date().timeIntervalSince(start) < 3.2 ? .pending : .rejected("no live panel named 'id:X'")
        }
        XCTAssertEqual(late, .rejected("no live panel named 'id:X'"))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 3.2)
        XCTAssertGreaterThan(ShowPointAndSayController.deliveryWatchSeconds, 60)
    }

    // 4 (V1): running out of the close watch is "still on its way", never a
    // failure and never a retry. The note stays queued past the first phase,
    // the dispatcher then delivers it, the follow-up phase sees that, and
    // exactly one note exists.
    func testUnansweredNoteStaysPendingThenLandsOnce() async throws {
        let state = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("show-pending-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let workspace = UUID(), caller = UUID()
        for dir in [MailboxLayout.outboxURL(state: state, workspaceId: workspace),
                    MailboxLayout.processingURL(state: state, workspaceId: workspace),
                    MailboxLayout.rejectedURL(state: state, workspaceId: workspace)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let id = try ShowPointAndSay.mail(to: caller, workspace: workspace, body: "slow", stateURL: state)
        let probe: @Sendable () -> ShowPointAndSay.Delivery = { ShowPointAndSay.delivery(id: id, stateURL: state) }

        // The close watch runs out with the note still queued.
        let first = await ShowPointAndSayController.watchDelivery(seconds: 0.3, interval: 0.05, probe: probe)
        XCTAssertEqual(first, .pending)
        XCTAssertNil(ShowPointAndSay.failureText(first))
        XCTAssertFalse(ShowPointAndSay.mayRetry(first))

        // The stalled dispatcher recovers while the follow-up phase watches.
        let dispatcher = MailboxDispatcher(workspaceId: workspace, stateURL: state,
            resolver: MailboxPanelResolver(workspaceId: workspace, livePanels: { [caller] }))
        defer { dispatcher.log.flush() }
        Task.detached {
            try? await Task.sleep(nanoseconds: 300_000_000)
            dispatcher.dispatchOne(url: MailboxLayout.outboxURL(state: state, workspaceId: workspace)
                .appendingPathComponent(MailboxLayout.envelopeFilename(id: id)))
            dispatcher.log.flush()
        }
        let outcome = await ShowPointAndSayController.followDelivery(phases: [(0.1, 0.05), (5, 0.05)], probe: probe)
        XCTAssertEqual(outcome, .delivered)

        // One note, one copy: nothing was written a second time.
        let inbox = MailboxLayout.inboxURL(state: state, workspaceId: workspace, panelId: caller)
        let copies = try FileManager.default.contentsOfDirectory(atPath: inbox.path).filter { $0.hasSuffix("." + MailboxLayout.envelopeExtension) }
        XCTAssertEqual(copies, [MailboxLayout.envelopeFilename(id: id)])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: MailboxLayout.outboxURL(state: state, workspaceId: workspace).path).isEmpty)
    }

    // 4 (V2): an unanswered note is never dropped. Both watch phases run
    // out with it still queued, the composer is closed, then the dispatcher
    // rejects it: the follow-up still sees the rejection, the page says so
    // with the note's words, and exactly one envelope was ever written.
    func testUnansweredNoteIsTrackedToItsFinalResult() async throws {
        let state = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("show-final-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let workspace = UUID(), caller = UUID()
        let outbox = MailboxLayout.outboxURL(state: state, workspaceId: workspace)
        let rejected = MailboxLayout.rejectedURL(state: state, workspaceId: workspace)
        for dir in [outbox, MailboxLayout.processingURL(state: state, workspaceId: workspace), rejected] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let id = try ShowPointAndSay.mail(to: caller, workspace: workspace, body: "late", stateURL: state)
        let probe: @Sendable () -> ShowPointAndSay.Delivery = { ShowPointAndSay.delivery(id: id, stateURL: state) }

        // The caller has closed: the dispatcher, once it runs, refuses the note.
        let dispatcher = MailboxDispatcher(workspaceId: workspace, stateURL: state,
            resolver: MailboxPanelResolver(workspaceId: workspace, livePanels: { [] }))
        defer { dispatcher.log.flush() }
        let start = Date()
        Task.detached {
            try? await Task.sleep(nanoseconds: 600_000_000)
            dispatcher.dispatchOne(url: outbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id)))
            dispatcher.log.flush()
        }
        // Both phases (0.4 s in all) end long before the dispatcher answers.
        let outcome = await ShowPointAndSayController.followDelivery(phases: [(0.2, 0.05), (0.2, 0.05)],
                                                                     tailInterval: 0.05, probe: probe)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.6)
        guard case .rejected = outcome else { return XCTFail("expected a rejection, got \(outcome)") }

        // The composer is closed: the page carries the final result, sticky.
        let surface = ShowPointAndSay.surface(for: outcome, composerOpen: false, title: "Show test", line: "late")
        XCTAssertEqual(surface, .page(ShowPointAndSay.Text.lateFailure("Show test", ShowPointAndSay.Text.agentGone, "late"),
                                      sticky: true))
        // Still open, the composer would say it and offer the retry.
        XCTAssertEqual(ShowPointAndSay.surface(for: outcome, composerOpen: true, title: "Show test", line: "late"),
                       .composer(ShowPointAndSay.Text.notSent(ShowPointAndSay.Text.agentGone), retry: true))
        // A late delivery is said too; still on its way is not an answer.
        XCTAssertEqual(ShowPointAndSay.surface(for: .delivered, composerOpen: false, title: "Show test", line: "late"),
                       .page(ShowPointAndSay.Text.lateDelivered("Show test"), sticky: false))
        XCTAssertNil(ShowPointAndSay.surface(for: .pending, composerOpen: false, title: "Show test", line: "late"))

        // One envelope, ever: nothing in the outbox, one in _rejected.
        let ext = "." + MailboxLayout.envelopeExtension
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outbox.path).filter { $0.hasSuffix(ext) }.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rejected.path).filter { $0.hasSuffix(ext) },
                       [MailboxLayout.envelopeFilename(id: id)])
    }

    // 4 (V3): a closed viewer ends its unanswered note. The note outlives
    // both watch phases; closing its viewer cancels the wait at once (its
    // sleep included), forgets the note, releases the session and web view,
    // and the one envelope stays the only one.
    @MainActor
    func testClosedViewerEndsItsUnansweredNote() async throws {
        let state = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("show-closed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let workspace = UUID()
        let outbox = MailboxLayout.outboxURL(state: state, workspaceId: workspace)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        // No dispatcher runs: the note stays unanswered.
        let id = try ShowPointAndSay.mail(to: UUID(), workspace: workspace, body: "unanswered", stateURL: state)
        let probe: @Sendable () -> ShowPointAndSay.Delivery = { ShowPointAndSay.delivery(id: id, stateURL: state) }

        final class Note {
            let session: ShowViewerSession
            let webView: WKWebView
            init(session: ShowViewerSession, webView: WKWebView) { self.session = session; self.webView = webView }
        }
        let tracker = ShowNoteTracker<Note>()
        let viewer = UUID(), token = UUID()
        weak var weakSession: ShowViewerSession?
        weak var weakWebView: WKWebView?
        autoreleasepool {
            let session = ShowViewerSession(caller: UUID(), source: .path("/a/x.html"), origin: .local,
                                            fetcher: ShowLocalFetcher(), callerTitle: "A")
            let webView = WKWebView(frame: .zero)
            weakSession = session
            weakWebView = webView
            tracker.track(token, note: Note(session: session, webView: webView), viewer: viewer)
        }
        let task = Task.detached {
            _ = await ShowPointAndSayController.followDelivery(phases: [(0.1, 0.02), (0.1, 0.02)],
                                                               tailInterval: 30, probe: probe)
        }
        tracker.attach(task, to: token)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(tracker.count, 1, "past both phases the note is still followed")
        XCTAssertNotNil(weakSession)

        let closed = Date()
        tracker.viewerClosed(viewer)
        XCTAssertEqual(tracker.count, 0)
        XCTAssertNil(tracker.note(token))
        XCTAssertTrue(task.isCancelled)
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(closed), 5, "the 30 s tail sleep ended on cancellation")
        XCTAssertNil(weakSession, "the session is released")
        XCTAssertNil(weakWebView, "the web view is released")

        // One envelope, ever, still waiting where it was written.
        let ext = "." + MailboxLayout.envelopeExtension
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outbox.path).filter { $0.hasSuffix(ext) },
                       [MailboxLayout.envelopeFilename(id: id)])
    }

    // 1/3: a host end is a record, not a dead terminal. The caller is gone
    // while its end is unresolved, and live again once resumed, kept, or when
    // it showed this after the end; a fresh plain shell counts once live.
    func testCallerEndedFollowsTheRecoveryPhase() {
        let endedAt = Date(timeIntervalSince1970: 1_000)
        let before = endedAt.addingTimeInterval(-60), after = endedAt.addingTimeInterval(60)
        func end(_ phase: HCHostEndStatus.Phase) -> HCHostEndStatus {
            HCHostEndStatus(endedKey: HCTerminalKey(owningCoreID: "core", localAddress: "t1"),
                            cause: .hostStopped(at: endedAt), phase: phase, conversation: nil)
        }
        XCTAssertFalse(ShowViewerController.callerEnded(hostEnd: nil, sessionLive: false, lastShownAt: before))
        // Ended, then each step of the real recovery path.
        for phase: HCHostEndStatus.Phase in [.deciding, .queued, .starting, .resuming,
                                             .notResumed(reason: "r"), .failed(reason: "r"), .interrupted(reason: "r")] {
            XCTAssertTrue(ShowViewerController.callerEnded(hostEnd: end(phase), sessionLive: true, lastShownAt: before), "\(phase)")
        }
        XCTAssertFalse(ShowViewerController.callerEnded(hostEnd: end(.resumed), sessionLive: false, lastShownAt: before))
        XCTAssertFalse(ShowViewerController.callerEnded(hostEnd: end(.kept(reason: "r")), sessionLive: false, lastShownAt: before))
        XCTAssertTrue(ShowViewerController.callerEnded(hostEnd: end(.noConversation), sessionLive: false, lastShownAt: before))
        XCTAssertFalse(ShowViewerController.callerEnded(hostEnd: end(.noConversation), sessionLive: true, lastShownAt: before))
        // A re-show after the end proves the caller is back, whatever the record says.
        XCTAssertFalse(ShowViewerController.callerEnded(hostEnd: end(.failed(reason: "r")), sessionLive: false, lastShownAt: after))
        XCTAssertTrue(ShowViewerController.callerEnded(hostEnd: end(.failed(reason: "r")), sessionLive: false, lastShownAt: nil))
    }

    // 1 (V1): a viewer restored at launch is not a show. Its caller's
    // unresolved end still holds; a real show request afterwards proves it back.
    @MainActor
    func testRestoredViewerIsNotAShow() throws {
        let endedAt = Date().addingTimeInterval(-600)
        let end = HCHostEndStatus(endedKey: HCTerminalKey(owningCoreID: "core", localAddress: "t1"),
                                  cause: .outsideSignal(at: endedAt, signal: 15), phase: .notResumed(reason: "r"), conversation: nil)
        let original = ShowViewerSession(caller: UUID(), source: .path("/a/x.html"), origin: .local,
                                         fetcher: ShowLocalFetcher(), callerTitle: "A")
        let restored = try XCTUnwrap(ShowViewerSession.restored(from: original.metadataValue))
        XCTAssertNil(restored.lastShownAt)
        XCTAssertTrue(ShowViewerController.callerEnded(hostEnd: end, sessionLive: true, lastShownAt: restored.lastShownAt))
        restored.noteShown()
        XCTAssertFalse(ShowViewerController.callerEnded(hostEnd: end, sessionLive: true, lastShownAt: restored.lastShownAt))
    }

    // 3: work bound to a document: a hash change is the same page; a new
    // load, another document or a foreign page ends it.
    func testPendingNoteIsBoundToItsDocument() {
        let doc = ShowPointAndSay.documentKey("c11-show://studio/p/x.html#a")
        XCTAssertEqual(doc, "c11-show://studio/p/x.html")
        XCTAssertTrue(ShowPointAndSay.isSameDocument(pending: doc, current: "c11-show://studio/p/x.html#b",
                                                     isLoading: false, address: shown))
        XCTAssertFalse(ShowPointAndSay.isSameDocument(pending: doc, current: "c11-show://studio/p/x.html",
                                                      isLoading: true, address: shown))
        XCTAssertFalse(ShowPointAndSay.isSameDocument(pending: doc, current: "c11-show://studio/p/detail.html",
                                                      isLoading: false, address: shown))
        XCTAssertFalse(ShowPointAndSay.isSameDocument(pending: doc, current: "https://example.com/",
                                                      isLoading: false, address: shown))
        XCTAssertFalse(ShowPointAndSay.isSameDocument(pending: nil, current: "c11-show://studio/p/x.html",
                                                      isLoading: false, address: shown))
    }

    // 4 (V2): WebKit's own frame reports mark the document the viewer
    // displays, never its address. A History API change of path or query
    // (no commit) keeps the mark; a fresh main-frame commit clears it; a
    // back/forward restore, or an address that moved without a commit after
    // any framed document, fails closed; an unknown page counts as framed.
    @MainActor
    func testEmbeddedContentIsRecordedPerDocument() {
        let session = ShowViewerSession(caller: UUID(), source: .path("/a/x.html"), origin: .local,
                                        fetcher: ShowLocalFetcher(), callerTitle: "A")
        let page = "c11-show://local/a/x.html", other = "c11-show://local/a/y.html"
        XCTAssertTrue(session.hasEmbeddedContent(page), "no commit seen yet")
        session.noteNavigation(.committed(url: page, freshLoad: true), currentURL: page)
        let first = session.documentGeneration
        XCTAssertFalse(session.hasEmbeddedContent(page))
        XCTAssertFalse(session.hasEmbeddedContent(page + "?view=2"), "an unframed page may change its own address")
        session.noteNavigation(.subframe, currentURL: page)
        XCTAssertTrue(session.hasEmbeddedContent(page))
        XCTAssertTrue(session.hasEmbeddedContent(page + "#tab=2"))
        // replaceState/pushState: same document, new path and query, no commit.
        XCTAssertTrue(session.hasEmbeddedContent(page + "?view=2"))
        XCTAssertTrue(session.hasEmbeddedContent("c11-show://local/a/elsewhere/z.html"))
        XCTAssertEqual(session.documentGeneration, first)
        // A fresh commit is a new document, with no frames yet.
        session.noteNavigation(.committed(url: other, freshLoad: true), currentURL: other)
        XCTAssertGreaterThan(session.documentGeneration, first)
        XCTAssertFalse(session.hasEmbeddedContent(other))
        // Its address moving without a commit cannot be told from a cached
        // earlier document once frames were seen: closed.
        XCTAssertTrue(session.hasEmbeddedContent(other + "?view=2"))
        // A back/forward restore may be the cached framed document: closed.
        session.noteNavigation(.committed(url: page, freshLoad: false), currentURL: page)
        XCTAssertTrue(session.hasEmbeddedContent(page))
        session.noteNavigation(.committed(url: page, freshLoad: true), currentURL: page)
        XCTAssertFalse(session.hasEmbeddedContent(page))
        XCTAssertTrue(session.hasEmbeddedContent(nil))

        let element = ShowPointAndSay.Element(selector: "#a", tag: "div", text: "", rect: .zero, hash: "", url: page, title: "")
        let body = ShowPointAndSay.body(line: "x", element: element, address: page, screenshot: ShowPointAndSay.screenshotOmittedEmbedded)
        XCTAssertTrue(body.contains("screenshot: omitted (the page has embedded content)"), body)
    }

    // 3: the viewer's bar says its agent is gone, and no longer offers Option-click.
    @MainActor
    func testBarLineSaysTheAgentIsGone() {
        let live = ShowViewerController.barLine(callerTitle: "Show test", updatedAt: Date(), address: shown)
        let gone = ShowViewerController.barLine(callerTitle: "Show test", updatedAt: Date(), address: shown, callerGone: true)
        XCTAssertTrue(live.contains("Option-click"))
        XCTAssertFalse(gone.contains("Option-click"), gone)
        XCTAssertTrue(gone.contains("closed"), gone)
        XCTAssertTrue(gone.contains("Show test") && gone.contains(shown.absoluteString), gone)
    }

    // 4: its own address reloads the shown page; any other c11-show input,
    // in a viewer or not, is refused; nothing else is touched.
    func testAddressBarKeepsTheViewersOwnAddress() {
        XCTAssertEqual(ShowAddressInput.decide("c11-show://studio/p/x.html", viewerAddress: shown), .reloadShown)
        XCTAssertEqual(ShowAddressInput.decide("  C11-SHOW://Studio/p/x.html#cobssid=s ", viewerAddress: shown), .reloadShown)
        // The retired line's scheme is a hidden alias: its saved address names the same page.
        XCTAssertEqual(ShowAddressInput.decide("  C11H-SHOW://Studio/p/x.html#cobssid=s ", viewerAddress: shown), .reloadShown) // c11-2.0:keep
        XCTAssertEqual(ShowAddressInput.decide("c11h-show://studio/p/other.html", viewerAddress: shown), .refused) // c11-2.0:keep
        XCTAssertEqual(ShowRefresh.decide(currentURL: URL(string: "c11h-show://studio/p/x.html"), address: shown), .reloadInPlace) // c11-2.0:keep
        XCTAssertEqual(ShowAddressInput.decide("c11-show://studio/p/other.html", viewerAddress: shown), .refused)
        XCTAssertEqual(ShowAddressInput.decide("c11-show://linuxbox/p/x.html", viewerAddress: shown), .refused)
        XCTAssertEqual(ShowAddressInput.decide("c11-show:nonsense with spaces", viewerAddress: shown), .refused)
        XCTAssertEqual(ShowAddressInput.decide("c11-show://studio/p/x.html", viewerAddress: nil), .refused)
        XCTAssertEqual(ShowAddressInput.decide("https://example.com", viewerAddress: shown), .notShow)
        XCTAssertEqual(ShowAddressInput.decide("flag lanes", viewerAddress: shown), .notShow)
    }

    // 4: the omnibar offers no search row and no remote query for c11-show input.
    func testOmnibarNeverOffersASearchForAShowAddress() {
        for query in ["c11-show://studio/p/x.html", "c11-show:studio"] {
            let rows = buildOmnibarSuggestions(query: query, engineName: "Google", historyEntries: [],
                                               remoteQueries: ["c11-show studio"], resolvedURL: nil)
            for row in rows {
                if case .search = row.kind { XCTFail("search row for \(query)") }
                if case .remote = row.kind { XCTFail("remote row for \(query)") }
            }
        }
        let ordinary = buildOmnibarSuggestions(query: "flag lanes", engineName: "Google", historyEntries: [],
                                               remoteQueries: [], resolvedURL: nil)
        XCTAssertTrue(ordinary.contains { if case .search = $0.kind { return true }; return false })
    }

    // 5: point and say is offered on the shown page and pages of the same
    // source; a page the viewer wandered to is not.
    func testPageScope() {
        XCTAssertEqual(ShowPointAndSay.scope(currentURL: "c11-show://studio/p/x.html#s=1", address: shown), .shown)
        XCTAssertEqual(ShowPointAndSay.scope(currentURL: "c11-show://studio/p/detail.html", address: shown), .sameSource)
        XCTAssertEqual(ShowPointAndSay.scope(currentURL: "c11h-show://studio/p/detail.html", address: shown), .sameSource) // c11-2.0:keep
        XCTAssertEqual(ShowPointAndSay.scope(currentURL: "c11h-show://linuxbox/p/x.html", address: shown), .foreign) // c11-2.0:keep
        XCTAssertEqual(ShowPointAndSay.scope(currentURL: "https://www.google.com/search?q=x#cobssid=s", address: shown), .foreign)
        XCTAssertEqual(ShowPointAndSay.scope(currentURL: "c11-show://linuxbox/p/x.html", address: shown), .foreign)
        XCTAssertEqual(ShowPointAndSay.scope(currentURL: nil, address: shown), .foreign)
        let dev = URL(string: "http://studio:5173/")!
        XCTAssertEqual(ShowPointAndSay.scope(currentURL: "http://studio:5173/", address: dev), .shown)
        XCTAssertEqual(ShowPointAndSay.scope(currentURL: "http://studio:5173/settings", address: dev), .sameSource)
        XCTAssertEqual(ShowPointAndSay.scope(currentURL: "http://studio:8080/", address: dev), .foreign)
    }

    // 5: the mail's page is the page pointed at, and says when it is not the shown one.
    func testMailReportsTheRealPage() {
        let element = ShowPointAndSay.Element(selector: "#logo", tag: "img", text: "", rect: .zero, hash: "#tab=2",
                                              url: "c11-show://studio/p/detail.html#tab=2", title: "Detail")
        let off = ShowPointAndSay.body(line: "this one", element: element, address: shown.absoluteString,
                                       screenshot: nil, scope: .sameSource)
        XCTAssertTrue(off.contains("page: c11-show://studio/p/detail.html#tab=2"), off)
        XCTAssertTrue(off.contains("note: not the shown page; shown: c11-show://studio/p/x.html"), off)
        XCTAssertFalse(off.contains("page: c11-show://studio/p/x.html"), off)

        var onPage = element
        onPage.url = "c11-show://studio/p/x.html#tab=2"
        let on = ShowPointAndSay.body(line: "this one", element: onPage, address: shown.absoluteString, screenshot: nil)
        XCTAssertTrue(on.contains("page: c11-show://studio/p/x.html#tab=2"), on)
        XCTAssertFalse(on.contains("note:"), on)
    }
}

private func XCTAssertThrowsShowError(_ expected: ShowFetchError, file: StaticString = #filePath, line: UInt = #line,
                                      _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as ShowFetchError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected \(error)", file: file, line: line)
    }
}
