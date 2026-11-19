import Darwin
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-37: `c11-core`, against a fake core and a fake process table. Nothing
/// here starts, signals or connects to a real core; the plain client is tested
/// against an in-process socket.
final class HCCoreUtilityTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/demo")
    private let coreID = "c11-core-id"

    private func configuration(tag: String? = nil) throws -> HCLaunchConfiguration {
        try HCLaunchPolicy.configuration(home: home, tag: tag, inherited: [:])
    }

    // MARK: fakes

    final class FakeLink: HCCoreLink {
        var peerUID: UInt32?
        var peerPID: Int32?
        var hello: [String: Any]
        var answers: [String: [String: Any]]
        var calls: [String] = []
        var closed = false
        var onCall: ((String) -> Void)?

        init(peerUID: UInt32?, peerPID: Int32?, hello: [String: Any], answers: [String: [String: Any]]) {
            self.peerUID = peerUID; self.peerPID = peerPID; self.hello = hello; self.answers = answers
        }

        func call(_ method: String, _ params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
            let key = method == "terminal.get" ? "terminal.get:\(params["terminal"] as? String ?? "")" : method
            calls.append(key)
            onCall?(method)
            guard let answer = answers[key] else { throw HCCoreRPCError(code: "not_found", message: key) }
            return answer
        }

        func close() { closed = true }
    }

    final class FakeHost: HCCoreHost {
        var uid: UInt32 = 501
        var machineName = "Laptop"
        var clock = Date(timeIntervalSince1970: 1_793_570_000)
        var socket: HCCoreSocketFacts? = HCCoreSocketFacts(isSocket: true, ownerUID: 501)
        var links: [FakeLink] = []
        var connects = 0
        var stateError: Error?
        var pinned = true
        var verifyError: Error?
        var servedPath = "/Users/demo/.local/share/c11/hc/0.1.16/herdr-core"
        var processes: [Int32: HCCoreProcessFacts] = [:]
        var table: [HCCoreProcessSample] = []
        var tty: [Int32: Date] = [:]
        var panels: [String: HCCorePanelRef] = [:]
        var onSleep: (() -> Void)?

        func now() -> Date { clock }
        func socketFacts(_ path: String) -> HCCoreSocketFacts? { socket }
        func connect(_ path: String) throws -> HCCoreLink {
            connects += 1
            guard !links.isEmpty else { throw HCCoreRPCError(code: "connect", message: "nothing") }
            return links.count == 1 ? links[0] : links.removeFirst()
        }
        func verifyStateEndpoint(_ configuration: HCLaunchConfiguration, coreID: String) throws {
            if let stateError { throw stateError }
        }
        func verifyPeer(_ evidence: HCPeerEvidence, _ configuration: HCLaunchConfiguration) throws -> HCVerifiedPeer {
            if let verifyError { throw verifyError }
            let pin = pinned ? configuration.pin : HCPin(version: "0.1.17", archiveSHA256: "", executableSHA256: String(repeating: "9", count: 64), protocolGeneration: 1)
            return HCVerifiedPeer(identity: HCBuildIdentity(
                pin: pin, executablePath: pinned ? configuration.executableURL.path : servedPath,
                fileIdentity: HCFileIdentity(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 0),
                process: HCProcessIdentity(pid: evidence.pid, startTimeMicroseconds: 1),
                coreID: evidence.coreID, protocolGeneration: evidence.protocolGeneration), isPinnedBuild: pinned)
        }
        func process(_ pid: Int32) -> HCCoreProcessFacts? { processes[pid] }
        func processTable() -> [HCCoreProcessSample] { table }
        func ttyLastOutput(pid: Int32) -> Date? { tty[pid] }
        func panelMap() -> [String: HCCorePanelRef] { panels }
        func sleep(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds); onSleep?() }
    }

    private func hello(pid: Int32 = 400, id: String? = nil) -> [String: Any] {
        ["core": ["id": id ?? coreID], "version": "0.1.16", "generation": 1,
         "methods": ["server.status", "server.restart", "terminal.run", "terminal.attach", "events.subscribe", "terminal.list", "terminal.get", "machine.list"],
         "features": ["framed", "attach", "events", "status"]]
    }

    private func status(pid: Int32 = 400, id: String? = nil) -> [String: Any] {
        ["core": ["id": id ?? coreID], "version": "0.1.16", "pid": pid]
    }

    private func link(pid: Int32 = 400, id: String? = nil, extra: [String: [String: Any]] = [:]) -> FakeLink {
        var answers: [String: [String: Any]] = ["server.status": status(pid: pid, id: id)]
        answers.merge(extra) { _, new in new }
        return FakeLink(peerUID: 501, peerPID: pid, hello: hello(pid: pid, id: id), answers: answers)
    }

    private func refusal(_ result: HCCoreOpenResult) -> HCCoreRefusal? {
        if case .refused(let refusal, _, _) = result { return refusal }
        return nil
    }

    // MARK: the session is c11's own, for this build

    func testTheSessionComesFromThisBuildAndNeverFromHCVariables() throws {
        XCTAssertNil(C11Identity.hcLaunchTag(environment: ["HC_SESSION": "default", "HC_SOCKET": "/tmp/x.sock"],
                                              bundleIdentifier: "com.stage11.c11"))
        XCTAssertEqual(C11Identity.hcLaunchTag(environment: [:], bundleIdentifier: "com.stage11.c11.debug.c11.5"), "c11-5")
        XCTAssertEqual(C11Identity.hcLaunchTag(environment: ["C11_TAG": "qa"], bundleIdentifier: "com.stage11.c11.debug.c11.5"), "qa")
        for bundle in ["com.stage11.c11.debug.c11.5", "com.stage11.c11", "com.stage11.c11.debug",
                       "com.stage11.c11.staging", "com.stage11.c11.nightly", nil] {
            XCTAssertEqual(C11Identity.hcLaunchTag(environment: [:], bundleIdentifier: bundle),
                           SocketControlSettings.hcLaunchTag(environment: [:], bundleIdentifier: bundle), "app and c11-core name the same core")
        }
        let release = try configuration()
        XCTAssertEqual(release.session, "c11")
        XCTAssertEqual(release.socketURL.path, "/Users/demo/.local/share/c11/run/c11.sock")
        XCTAssertEqual(release.executableURL.path, "/Users/demo/.local/share/c11/hc/0.1.16/herdr-core")
        XCTAssertEqual(release.environment["HC_SESSION"], "c11")
        XCTAssertEqual(try configuration(tag: "c11-5").session, "c11-c11-5")
    }

    // MARK: verification before anything else

    func testNoSocketIsCoreNotRunningAndNothingConnects() throws {
        let host = FakeHost()
        host.socket = nil
        XCTAssertEqual(refusal(HCCoreUtility.open(try configuration(), host: host)), .coreNotRunning)
        XCTAssertEqual(host.connects, 0)
        XCTAssertEqual(HCCoreRefusal.coreNotRunning.exitCode, 4)
    }

    func testASocketThatIsNotOursIsRefusedBeforeConnecting() throws {
        let host = FakeHost()
        host.links = [link()]
        host.socket = HCCoreSocketFacts(isSocket: true, ownerUID: 0)
        XCTAssertEqual(refusal(HCCoreUtility.open(try configuration(), host: host)), .socketNotOwned)
        host.socket = HCCoreSocketFacts(isSocket: false, ownerUID: 501)
        XCTAssertEqual(refusal(HCCoreUtility.open(try configuration(), host: host)), .socketNotOwned)
        XCTAssertEqual(host.connects, 0)
        XCTAssertEqual(HCCoreRefusal.socketNotOwned.exitCode, 3)
    }

    func testAPeerWhoseUIDOrPIDDisagreesIsRefusedAndNothingIsRead() throws {
        for (uid, pid) in [(UInt32(0), Int32(400)), (UInt32(501), Int32(999))] {
            let host = FakeHost()
            let peer = link()
            peer.peerUID = uid; peer.peerPID = pid
            host.links = [peer]
            XCTAssertEqual(refusal(HCCoreUtility.open(try configuration(), host: host)), .socketNotOwned)
            XCTAssertEqual(peer.calls, ["server.status"], "only the status needed to check it")
            XCTAssertTrue(peer.closed)
        }
    }

    func testAnotherSessionsCoreIsRefused() throws {
        let host = FakeHost()
        let peer = link()
        host.links = [peer]
        host.stateError = HCUnavailableReason.foreignSession
        XCTAssertEqual(refusal(HCCoreUtility.open(try configuration(), host: host)), .wrongSession)
        XCTAssertEqual(peer.calls, ["server.status"])
    }

    func testABuildThatIsNotThePinIsRefusedAndNamed() throws {
        let host = FakeHost()
        let peer = link()
        host.links = [peer]
        host.pinned = false
        host.servedPath = "/opt/homebrew/bin/herdr-core"
        guard case .refused(let refusal, let checks, let detail) = HCCoreUtility.open(try configuration(), host: host) else {
            return XCTFail("a foreign build was admitted")
        }
        XCTAssertEqual(refusal, .notC11hPin)
        XCTAssertTrue(detail.contains("/opt/homebrew/bin/herdr-core"), detail)
        XCTAssertEqual(checks.last?.ok, false)
        XCTAssertEqual(peer.calls, ["server.status"], "nothing is read from a core that is not c11's")
        host.pinned = true
        host.verifyError = HCUnavailableReason.pinMismatch
        host.links = [link()]
        XCTAssertEqual(self.refusal(HCCoreUtility.open(try configuration(), host: host)), .notC11hPin)
    }

    func testC11hsPinnedCoreIsVerifiedWithEveryCheck() throws {
        let host = FakeHost()
        host.links = [link()]
        guard case .verified(let connection) = HCCoreUtility.open(try configuration(), host: host) else {
            return XCTFail("c11's own core was refused")
        }
        XCTAssertEqual(connection.checks.map(\.check), ["socket_owner", "peer", "session", "pin"])
        XCTAssertTrue(connection.checks.allSatisfy(\.ok))
        XCTAssertEqual(connection.corePID, 400)
        let json = HCCoreUtility.refusalJSON(.notC11hPin, checks: [], detail: "x", configuration: try configuration())
        XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? String, "not_c11_pin")
    }

    // MARK: snapshot and c11.core/1

    private func snapshotFixture() throws -> (FakeHost, HCCoreSnapshot) {
        let host = FakeHost()
        let now = host.clock
        let panel = "4D61BE24-E499-47C9-AC15-0FE57E787C42"
        let local: [String: Any] = [
            "address": "t1", "state": "live", "pid": 410, "agent": "claude", "status": ["state": "working"],
            "status_ms": (now.timeIntervalSince1970 - 300) * 1000, "turn": 14, "cwd": "/Users/demo",
            "foreground": ["name": "claude", "pid": 420, "cwd": "/Users/demo/Projects/c11"],
            "created_ms": (now.timeIntervalSince1970 - 3600) * 1000, "cols": 132, "rows": 41, "screen": "exact",
            "labels": ["c11.panel": panel]]
        let shell: [String: Any] = [
            "address": "t2", "state": "live", "pid": 430, "agent": "sh", "status": NSNull(), "status_ms": NSNull(),
            "foreground": ["name": "zsh", "pid": 431], "created_ms": (now.timeIntervalSince1970 - 1800) * 1000,
            "cols": 80, "rows": 24, "screen": "inexact", "labels": [:]]
        let remote: [String: Any] = [
            "address": "studio/t4", "state": "live", "pid": 77, "agent": "codex", "status": ["state": "idle"],
            "status_ms": (now.timeIntervalSince1970 - 60) * 1000, "foreground": ["name": "codex", "pid": 78],
            "created_ms": (now.timeIntervalSince1970 - 900) * 1000, "cols": 120, "rows": 36, "screen": "exact",
            "labels": ["c11.panel": "EFD61E57-391B-4699-B7F9-C4F6ACD797D4"]]
        let finished: [String: Any] = [
            "address": "t1f", "state": "finished", "exit_code": 0, "agent": "sh",
            "created_ms": (now.timeIntervalSince1970 - 600) * 1000, "screen": "exact", "labels": [:]]
        let peer = link(extra: [
            "terminal.list": ["terminals": [["address": "t1"], ["address": "t2"], ["address": "studio/t4"], ["address": "t1f"]]],
            "terminal.get:t1": ["terminal": local], "terminal.get:t2": ["terminal": shell],
            "terminal.get:studio/t4": ["terminal": remote], "terminal.get:t1f": ["terminal": finished],
            "machine.list": ["machines": [["name": "studio", "state": "connected", "version": "0.1.16"]]]])
        host.links = [peer]
        host.processes = [
            400: HCCoreProcessFacts(pid: 400, parentPID: 1, uid: 501, startedAt: now.addingTimeInterval(-7200)),
            405: HCCoreProcessFacts(pid: 405, parentPID: 1, uid: 501, startedAt: now.addingTimeInterval(-86400)),
            410: HCCoreProcessFacts(pid: 410, parentPID: 405, uid: 0, startedAt: now.addingTimeInterval(-3600)),
            430: HCCoreProcessFacts(pid: 430, parentPID: 405, uid: 0, startedAt: now.addingTimeInterval(-1800))]
        host.table = [
            HCCoreProcessSample(pid: 410, parentPID: 405, cpuPercent: 0, residentBytes: 1_000),
            HCCoreProcessSample(pid: 411, parentPID: 410, cpuPercent: 0.5, residentBytes: 2_000),
            HCCoreProcessSample(pid: 420, parentPID: 411, cpuPercent: 11.5, residentBytes: 400_000_000),
            HCCoreProcessSample(pid: 430, parentPID: 405, cpuPercent: 0, residentBytes: 4_000_000),
            HCCoreProcessSample(pid: 999, parentPID: 1, cpuPercent: 50, residentBytes: 9_000_000)]
        host.tty = [420: now.addingTimeInterval(-5), 431: now.addingTimeInterval(-2460), 78: now]
        host.panels = [panel.lowercased(): HCCorePanelRef(ref: "panel:1", workspace: "c11 build")]
        guard case .verified(let connection) = HCCoreUtility.open(try configuration(), host: host) else {
            throw XCTSkip("fixture did not verify")
        }
        return (host, try HCCoreUtility.snapshot(connection, host: host))
    }

    private func item(_ json: [String: Any], _ address: String) throws -> [String: Any] {
        let items = try XCTUnwrap((json["terminals"] as? [String: Any])?["items"] as? [[String: Any]])
        return try XCTUnwrap(items.first { $0["address"] as? String == address })
    }

    func testTheJSONCarriesEveryPerTerminalStatInItsDocumentedShape() throws {
        let (_, snapshot) = try snapshotFixture()
        let json = HCCoreUtility.json(snapshot)
        XCTAssertEqual(json["schema"] as? String, "c11.core/1")
        XCTAssertEqual(json["session"] as? String, "c11")
        XCTAssertEqual((json["core"] as? [String: Any])?["pid"] as? Int32, 400)
        XCTAssertEqual((json["core"] as? [String: Any])?["uptime_s"] as? Int, 7200)
        XCTAssertEqual((json["holder"] as? [String: Any])?["pid"] as? Int32, 405)
        XCTAssertEqual((json["holder"] as? [String: Any])?["terminals_owned"] as? Int, 2)
        let count = try XCTUnwrap((json["terminals"] as? [String: Any])?["count"] as? [String: Int])
        XCTAssertEqual(count, ["live": 3, "finished": 1, "starting": 0])

        let t1 = try item(json, "t1")
        XCTAssertEqual((t1["agent"] as? [String: Any])?["name"] as? String, "claude")
        XCTAssertEqual((t1["agent"] as? [String: Any])?["status"] as? String, "working")
        XCTAssertEqual((t1["agent"] as? [String: Any])?["turn"] as? Int, 14)
        XCTAssertEqual((t1["foreground"] as? [String: Any])?["pid"] as? Int32, 420)
        XCTAssertEqual(t1["cwd"] as? String, "/Users/demo/Projects/c11", "the foreground's directory")
        XCTAssertNotNil(t1["launched_at"] as? String)
        XCTAssertEqual((t1["last_active"] as? [String: Any])?["source"] as? String, "tty", "output 5 s ago beats a status 5 min ago")
        XCTAssertEqual(t1["cpu_percent"] as? Double, 12.0, "the terminal's whole process tree")
        XCTAssertEqual(t1["memory_bytes"] as? UInt64, 400_003_000)
        XCTAssertEqual(t1["size"] as? [String: Int], ["cols": 132, "rows": 41])
        XCTAssertEqual(t1["screen_copy"] as? String, "exact")
        let panel = try XCTUnwrap(t1["c11_panel"] as? [String: Any])
        XCTAssertEqual(panel["ref"] as? String, "panel:1")
        XCTAssertEqual(panel["workspace"] as? String, "c11 build")
        XCTAssertEqual(panel["link"] as? String, "c11://panel/4d61be24-e499-47c9-ac15-0fe57e787c42")
        XCTAssertEqual((t1["open"] as? [String: Any])?["watch"] as? String, "c11-core open t1")

        let t2 = try item(json, "t2")
        XCTAssertTrue(t2["agent"] is NSNull, "a plain shell has no agent")
        XCTAssertEqual(t2["screen_copy"] as? String, "rebuilt", "hc's inexact")
        XCTAssertTrue(t2["c11_panel"] is NSNull)

        let remote = try item(json, "studio/t4")
        XCTAssertEqual(remote["machine"] as? String, "studio")
        XCTAssertTrue((remote["foreground"] as? [String: Any])?["pid"] is NSNull, "remote pids are never read")
        XCTAssertTrue(remote["cpu_percent"] is NSNull)
        XCTAssertTrue(remote["memory_bytes"] is NSNull)
        XCTAssertEqual((remote["last_active"] as? [String: Any])?["source"] as? String, "status", "no remote tty is read")

        let done = try item(json, "t1f")
        XCTAssertEqual(done["exit_code"] as? Int, 0)
        XCTAssertTrue(done["open"] is NSNull)
        let machines = try XCTUnwrap(json["machines"] as? [[String: Any]])
        XCTAssertEqual(machines.last?["pin_ok"] as? Bool, true)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(HCCoreUtility.encode(json).utf8)))
    }

    func testTheStatusScreenShowsTheC11PanelAndExplainsScreenCopyWithin120Columns() throws {
        let (_, snapshot) = try snapshotFixture()
        let text = HCCoreUtility.renderStatus(snapshot, style: .plain, home: "/Users/demo", insideC11h: true)
        XCTAssertTrue(text.contains("C11 PANEL"))
        XCTAssertTrue(text.contains("SCREEN COPY"))
        XCTAssertTrue(text.contains("exact: hc holds a faithful copy of the screen."))
        XCTAssertTrue(text.contains("panel:1 ↗"))
        XCTAssertTrue(text.contains("rebuilt"))
        XCTAssertTrue(text.contains("(st)"), "a remote terminal's last active comes from its status")
        XCTAssertFalse(text.contains("\u{1B}"), "plain style writes no escapes")
        for line in text.split(separator: "\n") { XCTAssertLessThanOrEqual(line.count, 120, String(line)) }
        let linked = HCCoreUtility.renderStatus(snapshot, style: HCCoreStyle(color: false, links: true), home: "/Users/demo", insideC11h: true)
        XCTAssertTrue(linked.contains("\u{1B}]8;;c11://panel/4d61be24-e499-47c9-ac15-0fe57e787c42\u{1B}\\"))
        let outside = HCCoreUtility.renderStatus(snapshot, style: .plain, home: "/Users/demo", insideC11h: false)
        XCTAssertTrue(outside.contains("jump: inside c11"))
        let show = HCCoreUtility.renderShow(try XCTUnwrap(snapshot.terminals.first { $0.address == "t1" }), snapshot: snapshot,
                                            style: .plain, home: "/Users/demo", insideC11h: false)
        XCTAssertTrue(show.contains("Terminal.app cannot open c11 links"))
        XCTAssertTrue(show.contains("c11-core open t1 --take-over"))
        let watch = HCCoreUtility.renderWatch(snapshot, selected: 0, style: .plain, home: "/Users/demo", insideC11h: true)
        XCTAssertTrue(watch.contains("▸ t1"))
    }

    func testTheJumpLinkResolvesThroughC11hsOwnPanelLinkRoute() throws {
        // C11H-51 (#104): c11 opens c11://, never c11://. The link c11-core
        // emits, in its rows and in its JSON, must be one PanelLinkTarget opens.
        let (_, snapshot) = try snapshotFixture()
        let panel = try XCTUnwrap(UUID(uuidString: "4D61BE24-E499-47C9-AC15-0FE57E787C42"))
        let terminal = try XCTUnwrap(snapshot.terminals.first { $0.address == "t1" })
        let link = try XCTUnwrap(terminal.panelLink)
        XCTAssertTrue(link.hasPrefix("c11://"), link)
        XCTAssertEqual(PanelLinkTarget(link), .panel(panel))
        XCTAssertTrue(PanelLinkTarget.usesScheme(link))
        let item = try self.item(HCCoreUtility.json(snapshot), "t1")
        let jsonLink = try XCTUnwrap((item["c11_panel"] as? [String: Any])?["link"] as? String)
        XCTAssertEqual(PanelLinkTarget(jsonLink), .panel(panel))
    }

    // MARK: open in Terminal.app: watch-only by default

    func testOpenIsWatchOnlyByDefaultAndTakeOverIsExplicit() throws {
        let c = try configuration()
        let watch = try HCCoreUtility.openPlan(address: "t1b", takeOver: false, configuration: c)
        XCTAssertTrue(watch.script.contains("'/Users/demo/.local/share/c11/hc/0.1.16/herdr-core' attach --observe 't1b'"), watch.script)
        XCTAssertTrue(watch.script.contains("HC_SESSION='c11' HC_SOCKET='/Users/demo/.local/share/c11/run/c11.sock'"))
        XCTAssertTrue(watch.script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(watch.fileName.hasSuffix(".command"))
        let take = try HCCoreUtility.openPlan(address: "t1b", takeOver: true, configuration: c)
        XCTAssertTrue(take.script.contains("herdr-core' attach 't1b'"))
        XCTAssertFalse(take.script.contains("--observe"))
    }

    // MARK: C11H-357: only hc's address shape reaches a .command script

    private let hostileAddresses = [
        "studio/t1\necho marker > /tmp/c11-marker #", "t1\necho marker #", "t1\r", "studio/t1\r\necho marker",
        "t1;id", "studio/t1;id", "t1$(id)", "studio/t1$(id)", "studio/t1`id`", "t1 #", "x'y", "studio/t1\u{1B}]2;x\u{07}",
        "", "t", "t0", "T1", "t1a", "t1l", "/t1", "studio/", "studio/../t1", "studio/t1/t2", "local/t1", "-studio/t1",
        "studio;id/t1", "studio$(id)/t1", "stud\u{0456}o/t1", "studio\n/t1", "_studio/t1", ".studio/t1", "stu dio/t1",
        "t1" + String(repeating: "0", count: 300), String(repeating: "a", count: 200) + "/t1",
    ]
    private let goodAddresses = ["t1", "t1b", "t20", "t9z", "studio/t1b", "studio-2/t3", "mac.lan/t1", "Studio-1/t4", "studio_2/t3"]

    func testOpenRefusesEveryAddressThatIsNotHCsShape() throws {
        let c = try configuration()
        for address in hostileAddresses {
            XCTAssertFalse(HCCoreUtility.isTerminalAddress(address), address.debugDescription)
            for takeOver in [false, true] {
                XCTAssertThrowsError(try HCCoreUtility.openPlan(address: address, takeOver: takeOver, configuration: c),
                                     address.debugDescription) { XCTAssertEqual($0 as? HCCoreInvalidAddress, HCCoreInvalidAddress()) }
            }
        }
    }

    func testAGoodAddressEntersTheScriptOnlyAsTheQuotedExecArgument() throws {
        let c = try configuration()
        for address in goodAddresses {
            XCTAssertTrue(HCCoreUtility.isTerminalAddress(address), address)
            for takeOver in [false, true] {
                let plan = try HCCoreUtility.openPlan(address: address, takeOver: takeOver, configuration: c)
                let lines = plan.script.components(separatedBy: "\n")
                XCTAssertEqual(lines.count, 6, plan.script)
                XCTAssertTrue(lines[1].hasPrefix("# c11-core open"), lines[1])
                let carrying = lines.filter { $0.contains(address) }
                XCTAssertEqual(carrying, [lines[4]], "the address is on the exec line only:\n\(plan.script)")
                XCTAssertTrue(lines[4].hasPrefix("exec '"), lines[4])
                XCTAssertTrue(lines[4].hasSuffix(" " + HCCoreUtility.shellQuote(address)), lines[4])
                XCTAssertTrue(plan.fileName.unicodeScalars.allSatisfy {
                    $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ".")
                }, plan.fileName)
            }
        }
    }

    private struct FixtureDidNotVerify: Error {}

    private func readSnapshot(_ host: FakeHost) throws -> HCCoreSnapshot {
        guard case .verified(let connection) = HCCoreUtility.open(try configuration(), host: host) else {
            XCTFail("fixture did not verify")
            throw FixtureDidNotVerify()
        }
        return try HCCoreUtility.snapshot(connection, host: host)
    }

    func testTheSnapshotKeepsOnlyRecordsWithHCsAddressThatAnswerForThemselves() throws {
        let host = FakeHost()
        let now = host.clock
        func record(_ address: String, created: Bool = true) -> [String: Any] {
            var value: [String: Any] = ["address": address, "state": "live", "agent": "sh", "labels": [:]]
            if created { value["created_ms"] = (now.timeIntervalSince1970 - 60) * 1000 }
            return value
        }
        // With no created_ms a record would sort first, where watch's cursor starts.
        let crafted = "studio/t1\necho marker > /tmp/c11-marker #"
        let peer = link(extra: [
            "terminal.list": ["terminals": [
                ["address": crafted], ["address": "t1"], ["address": "studio/t2"], ["address": "studio/t3"],
                ["address": "studio/t4"], ["address": "t1$(id)"], ["state": "live"], ["address": 7], ["address": "t1"],
                ["address": "t1\r"], ["address": "t1;id"], ["address": "studio/t1`id`"],
                ["address": "t1" + String(repeating: "0", count: 23)], ["address": "Kbox/t1"]]],
            "terminal.get:t1": ["terminal": record("t1")],
            "terminal.get:studio/t2": ["terminal": record("studio/t2")],
            "terminal.get:studio/t3": ["terminal": record("studio/t5", created: false)],
            "terminal.get:studio/t4": ["terminal": record("studio/t4\nid #", created: false)],
            "terminal.get:\(crafted)": ["terminal": record(crafted, created: false)],
            "terminal.get:t1$(id)": ["terminal": record("t1$(id)", created: false)],
            // KELVIN SIGN: canonically equivalent to `K`, so Swift's `==` calls it the same address.
            "terminal.get:Kbox/t1": ["terminal": record("\u{212A}box/t1", created: false)],
            "machine.list": ["machines": [["name": "studio", "state": "connected", "version": "0.1.16"]]]])
        host.links = [peer]
        let snapshot = try readSnapshot(host)
        XCTAssertEqual(snapshot.terminals.map(\.address), ["studio/t2", "t1"])
        XCTAssertEqual(snapshot.refused, 11, "six bad listed addresses, two rows without one, three replies for another address")
        XCTAssertFalse(peer.calls.contains("terminal.get:\(crafted)"), "a bad listed address is never asked about")
        XCTAssertFalse(peer.calls.contains("terminal.get:t1$(id)"))
        XCTAssertEqual(peer.calls.filter { $0 == "terminal.get:t1" }.count, 1, "a repeated address is read once")
        XCTAssertTrue(peer.calls.contains("terminal.get:Kbox/t1"), "a good listed address is asked about")
        XCTAssertEqual((HCCoreUtility.json(snapshot)["terminals"] as? [String: Any])?["refused"] as? Int, 11)
        let status = HCCoreUtility.renderStatus(snapshot, style: .plain, home: "/Users/demo", insideC11h: false)
        XCTAssertTrue(status.contains("11 hc record(s) not shown"), status)
        let watch = HCCoreUtility.renderWatch(snapshot, selected: 0, style: .plain, home: "/Users/demo", insideC11h: false)
        XCTAssertTrue(watch.contains("▸ studio/t2"), watch)
        XCTAssertTrue(watch.contains("11 hc record(s) not shown"), watch)
    }

    func testRefusedArgumentsPrintWithTheirControlCharactersShown() {
        // C11CoreCLI prints these refusals; no test target compiles that file, so the text is built here.
        for message in [HCCoreUtility.linkNameRefusal("studio\u{1B}[2J"), HCCoreUtility.addressRefusal("open", "studio\u{1B}[2J")] {
            XCTAssertFalse(message.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) },
                           message.debugDescription)
            XCTAssertTrue(message.contains("studio\\x1B[2J"), message)
        }
    }

    func testRemoteTextPrintsWithItsControlCharactersShown() throws {
        let host = FakeHost()
        let now = host.clock
        let remote: [String: Any] = [
            "address": "studio/t2", "state": "live", "agent": "claude\u{1B}]2;owned\u{07}", "status": ["state": "work\ning"],
            "status_ms": (now.timeIntervalSince1970 - 60) * 1000, "created_ms": (now.timeIntervalSince1970 - 60) * 1000,
            "foreground": ["name": "vim\r\u{9B}2J", "cwd": "/srv/x\n\u{7F}y"],
            "labels": ["c11.panel": "\u{1B}]8;;https://example.invalid\u{1B}\\"]]
        let panel = "EFD61E57-391B-4699-B7F9-C4F6ACD797D4"
        let odd: [String: Any] = ["address": "studio/t3", "state": "gone\u{1B}[2J", "agent": "sh", "labels": ["c11.panel": panel]]
        host.panels = [panel.lowercased(): HCCorePanelRef(ref: "panel:9\u{1B}[1m", workspace: "ws\u{1B}]0;x\u{07}")]
        host.links = [link(extra: [
            "terminal.list": ["terminals": [["address": "studio/t2"], ["address": "studio/t3"]]],
            "terminal.get:studio/t2": ["terminal": remote], "terminal.get:studio/t3": ["terminal": odd],
            "machine.list": ["machines": [["name": "studio", "state": "dial\u{1B}[31mfail", "version": "0.1.16\n"],
                                          ["name": "far\u{9B}2J", "state": "connected"]]]])]
        let snapshot = try readSnapshot(host)
        let t2 = try XCTUnwrap(snapshot.terminals.first { $0.address == "studio/t2" })
        let t3 = try XCTUnwrap(snapshot.terminals.first { $0.address == "studio/t3" })
        XCTAssertNil(t2.panelID, "a c11.panel label that is not a UUID is not c11's")
        let screens = [
            HCCoreUtility.renderStatus(snapshot, style: .plain, home: "/Users/demo", all: true, insideC11h: true),
            HCCoreUtility.renderShow(t2, snapshot: snapshot, style: .plain, home: "/Users/demo", insideC11h: true),
            HCCoreUtility.renderShow(t3, snapshot: snapshot, style: .plain, home: "/Users/demo", insideC11h: true),
            HCCoreUtility.renderWatch(snapshot, selected: 0, style: .plain, home: "/Users/demo", insideC11h: true),
            HCCoreUtility.takeOverWarning(t2),
            HCCoreUtility.takeOverWarning(t3),
        ]
        for screen in screens {
            for line in screen.components(separatedBy: "\n") {
                XCTAssertFalse(line.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) },
                               line.debugDescription)
            }
        }
        XCTAssertTrue(screens[0].contains("dial\\x1B[31mfail"), screens[0])
        XCTAssertTrue(screens[0].contains("far\\x9B2J"), screens[0])
        XCTAssertTrue(screens[3].contains("far\\x9B2J"), screens[3])
        XCTAssertTrue(screens[2].contains("panel:9\\x1B[1m ↗"), screens[2])
        XCTAssertTrue(screens[2].contains("workspace ws\\x1B]0;x\\x07"), screens[2])
        XCTAssertTrue(screens[5].contains("(panel:9\\x1B[1m)"), screens[5])
        XCTAssertTrue(screens[1].contains("claude\\x1B]2;owned\\x07 · work\\x0Aing"), screens[1])
        XCTAssertTrue(screens[1].contains("/srv/x\\x0A\\x7Fy"), screens[1])
        XCTAssertTrue(screens[1].contains("vim\\x0D\\x9B2J"), screens[1])
        XCTAssertTrue(screens[2].contains("gone\\x1B[2J"), screens[2])
        XCTAssertTrue(screens[3].contains("/srv/x\\x0A\\x7Fy"), screens[3])
        XCTAssertEqual(HCCoreUtility.printable("a\nb\u{1B}c", keepLineFeeds: true), "a\nb\\x1Bc")

        // --json carries the exact values, with no control byte raw on the terminal.
        let json = HCCoreUtility.encode(HCCoreUtility.json(snapshot))
        XCTAssertFalse(json.unicodeScalars.contains { ($0.value < 0x20 && $0.value != 0x0A) || (0x7F...0x9F).contains($0.value) }, json)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((try item(decoded, "studio/t2")["foreground"] as? [String: Any])?["name"] as? String, "vim\r\u{9B}2J")
        XCTAssertEqual(try item(decoded, "studio/t2")["cwd"] as? String, "/srv/x\n\u{7F}y")
        XCTAssertEqual(HCCoreUtility.printable("é ↗ ok"), "é ↗ ok", "printable text is unchanged")
    }

    func testARecordTimeFarInTheFutureIsNoTimeAndUndatedRecordsListLast() throws {
        let host = FakeHost()
        let now = host.clock
        let far: [String: Any] = ["address": "studio/t2", "state": "live", "agent": "codex", "status": ["state": "idle"],
                                  "created_ms": 1e300, "status_ms": Double.greatestFiniteMagnitude, "labels": [:]]
        let undated: [String: Any] = ["address": "studio/t3", "state": "live", "agent": "sh", "labels": [:]]
        let local: [String: Any] = ["address": "t1", "state": "live", "agent": "sh", "labels": [:],
                                    "created_ms": (now.timeIntervalSince1970 - 60) * 1000]
        host.links = [link(extra: [
            "terminal.list": ["terminals": [["address": "studio/t2"], ["address": "studio/t3"], ["address": "t1"]]],
            "terminal.get:studio/t2": ["terminal": far], "terminal.get:studio/t3": ["terminal": undated],
            "terminal.get:t1": ["terminal": local]])]
        let snapshot = try readSnapshot(host)
        XCTAssertEqual(snapshot.terminals.map(\.address), ["t1", "studio/t2", "studio/t3"],
                       "watch's cursor starts on a dated record, never an undated one")
        let t2 = try XCTUnwrap(snapshot.terminals.first { $0.address == "studio/t2" })
        XCTAssertNil(t2.launchedAt)
        XCTAssertNil(t2.agent?.statusAt)
        // Each screen does whole-second arithmetic on these times; none may trap.
        XCTAssertFalse(HCCoreUtility.renderStatus(snapshot, style: .plain, home: "/Users/demo", insideC11h: false).isEmpty)
        XCTAssertFalse(HCCoreUtility.renderShow(t2, snapshot: snapshot, style: .plain, home: "/Users/demo", insideC11h: false).isEmpty)
        XCTAssertTrue(HCCoreUtility.renderWatch(snapshot, selected: 0, style: .plain, home: "/Users/demo", insideC11h: false)
            .contains("▸ t1"))
    }

    // MARK: restart

    func testRestartWaitsForTheOldCoreThenAVerifiedNewOneOfTheSameSession() throws {
        let host = FakeHost()
        let old = link(pid: 400)
        let next = link(pid: 500)
        host.links = [old, next]
        host.processes[400] = HCCoreProcessFacts(pid: 400, parentPID: 1, uid: 501, startedAt: host.clock)
        var sleeps = 0
        host.onSleep = {
            sleeps += 1
            if sleeps == 3 { host.processes[400] = nil }
        }
        guard case .verified(let connection) = HCCoreUtility.open(try configuration(), host: host) else { return XCTFail() }
        guard case .restarted(let after) = HCCoreUtility.restart(connection, host: host) else { return XCTFail("restart failed") }
        XCTAssertEqual(old.calls, ["server.status", "server.restart"])
        XCTAssertTrue(old.closed)
        XCTAssertEqual(after.corePID, 500)
        XCTAssertGreaterThanOrEqual(sleeps, 3, "it waited for the old process to exit")
    }

    func testRestartNeverAcceptsAnotherCoreAndGivesUpInBoundedTime() throws {
        let host = FakeHost()
        host.links = [link(pid: 400), link(pid: 500, id: "someone-else")]
        guard case .verified(let connection) = HCCoreUtility.open(try configuration(), host: host) else { return XCTFail() }
        let start = host.clock
        guard case .failed(let detail) = HCCoreUtility.restart(connection, host: host, timeout: 5) else {
            return XCTFail("a core with another id was accepted as the restarted core")
        }
        XCTAssertTrue(detail.contains("no verified core"), detail)
        XCTAssertLessThanOrEqual(host.clock.timeIntervalSince(start), 6)
    }

    // MARK: link <machine>

    func testLinkUsesOnlyAViaScriptThatRunsThePinForThisSession() throws {
        let c = try configuration()
        let via = URL(fileURLWithPath: "/Users/demo/.local/share/c11/studio-via.sh")
        guard case .refused = HCCoreUtility.linkPlan(via: via, script: nil, machine: "studio", configuration: c) else { return XCTFail() }
        guard case .refused = HCCoreUtility.linkPlan(via: via, script: "exec ssh studio herdr-core connect", machine: "studio", configuration: c) else {
            return XCTFail("a via script that runs a PATH herdr-core was accepted")
        }
        let binary = HCAtlasLink.pinExecutable(home: URL(fileURLWithPath: "/Users/remote"), pin: c.pin).path
        let pin = "sha256=\(c.pin.executableSHA256.lowercased())"
        let good = "exec /usr/bin/ssh -T -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no -k -- studio 'exec /usr/bin/env -i XDG_CONFIG_HOME=/Users/remote/.local/share/c11/config \(pin) \(binary) connect --session c11'"
        // C11H-332: a via without this build's pin before the executable, or with another pin, is refused.
        for bad in [good.replacingOccurrences(of: "\(pin) ", with: ""),
                    good.replacingOccurrences(of: pin, with: "sha256=\(String(repeating: "0", count: 64))"),
                    good.replacingOccurrences(of: "XDG_CONFIG_HOME", with: "XDG_CACHE_HOME"),
                    good.replacingOccurrences(of: "XDG_CONFIG_HOME=/Users/remote", with: "XDG_CONFIG_HOME=/Users/local"),
                    good.replacingOccurrences(of: String(c.pin.executableSHA256.prefix(12)), with: "000000000000"),
                    good.replacingOccurrences(of: "connect --session c11'", with: "connect --session c11-other'")] {
            guard case .refused = HCCoreUtility.linkPlan(via: via, script: bad, machine: "studio", configuration: c) else {
                return XCTFail("accepted a different pin, session or config: \(bad)")
            }
        }
        // C11H-361: a via whose ssh may forward the agent, X11 or ports is refused, whichever switch it lacks.
        for forwarding in ["-o ForwardAgent=no ", "-o ForwardX11=no ", "-o ClearAllForwardings=yes ", "-o PermitLocalCommand=no ", "-k "] {
            let bad = good.replacingOccurrences(of: forwarding, with: "")
            guard case .refused = HCCoreUtility.linkPlan(via: via, script: bad, machine: "studio", configuration: c) else {
                return XCTFail("accepted a via without \(forwarding): \(bad)")
            }
        }
        XCTAssertEqual(HCCoreUtility.linkPlan(via: via, script: good, machine: "studio", configuration: c),
                       .ready(["machine", "add", "--name", "studio", "--session", "c11", "--via", via.path]))
    }

    /// C11H-332: `c11-core link`'s admission audits a refused via; an admitted one writes nothing.
    func testARefusedCoreLinkAdmissionIsAudited() throws {
        let c = try configuration()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("core-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audit = C11AuditLog(directory: folder)
        let via = URL(fileURLWithPath: "/Users/demo/.local/share/c11/studio-via.sh")
        let binary = HCAtlasLink.pinExecutable(home: URL(fileURLWithPath: "/Users/remote"), pin: c.pin).path
        let good = "exec /usr/bin/ssh -T -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no -k -- studio 'exec /usr/bin/env -i XDG_CONFIG_HOME=/Users/remote/.local/share/c11/config sha256=\(c.pin.executableSHA256.lowercased()) \(binary) connect --session c11'"
        let pinless = good.replacingOccurrences(of: "sha256=\(c.pin.executableSHA256.lowercased()) ", with: "")
        guard case .ready = HCCoreUtility.admitLink(via: via, script: good, machine: "studio", configuration: c, audit: audit) else { return XCTFail() }
        guard case .refused = HCCoreUtility.admitLink(via: via, script: pinless, machine: "studio", configuration: c, audit: audit) else { return XCTFail() }
        guard case .refused = HCCoreUtility.admitLink(via: via, script: nil, machine: "studio", configuration: c, audit: audit) else { return XCTFail() }
        let records = audit.read(.init(kind: "link"))
        XCTAssertEqual(records.map(\.code), ["via_unchecked", "via_missing"])
        XCTAssertTrue(records.allSatisfy { $0.outcome == "refused" && $0.via == "c11-core" && $0.machine == "studio" })
    }

    /// C11H-332: `c11-core link` on an existing machine whose stored via
    /// can't be migrated (here with no app beside the CLI, so no link script)
    /// records `link unusable` before it returns: read from the file itself.
    /// A pinned one records nothing.
    func testCoreLinkRecordsAnUnusableExistingLinkBeforeReturning() throws {
        let c = try configuration()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("core-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let vias = home.appendingPathComponent(".local/share/c11/vias", isDirectory: true)
        try FileManager.default.createDirectory(at: vias, withIntermediateDirectories: true)
        let audit = C11AuditLog(directory: home.appendingPathComponent("audit", isDirectory: true))
        audit.afterOpenForTesting = { usleep(200_000) }
        let binary = HCAtlasLink.pinExecutable(home: URL(fileURLWithPath: "/Users/remote"), pin: c.pin).path
        let pinned = "exec /usr/bin/ssh -T -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no -k -- studio 'exec /usr/bin/env -i sha256=\(c.pin.executableSHA256.lowercased()) \(binary) connect --session c11'\n"
        let pinless = pinned.replacingOccurrences(of: "sha256=\(c.pin.executableSHA256.lowercased()) ", with: "")
        let good = vias.appendingPathComponent("good-via.sh"), old = vias.appendingPathComponent("studio-via.sh")
        try pinned.write(to: good, atomically: true, encoding: .utf8)
        try pinless.write(to: old, atomically: true, encoding: .utf8)
        XCTAssertEqual(HCCoreUtility.reviewExistingLink(machine: "good", viaPath: good.path, home: home, configuration: c,
                                                        linkScript: nil, adopted: false, audit: audit), .pinned)
        XCTAssertEqual(HCCoreUtility.reviewExistingLink(machine: "studio", viaPath: old.path, home: home, configuration: c,
                                                        linkScript: nil, adopted: false, audit: audit), .unusable("migrate_failed"))
        let lines = ((try? String(contentsOf: audit.fileURL, encoding: .utf8)) ?? "").split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "one record, written before return: \(lines)")
        let record = try XCTUnwrap(lines.first.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        XCTAssertEqual(record["kind"] as? String, "link")
        XCTAssertEqual(record["via"] as? String, "c11-core")
        XCTAssertEqual(record["outcome"] as? String, "unusable")
        XCTAssertEqual(record["machine"] as? String, "studio")
        XCTAssertEqual(record["session"] as? String, c.session)
        XCTAssertEqual(record["code"] as? String, "migrate_failed")
        audit.afterOpenForTesting = nil
    }

    /// C11H-284: `link` names no machine of its own. Whatever name the
    /// operator passes is the name hc gets, in the same argv `link` always ran.
    func testLinkAddsTheMachineItIsGivenAndRefusesANonName() throws {
        let c = try configuration()
        let via = URL(fileURLWithPath: "/Users/demo/.local/share/c11/studio-via.sh")
        let binary = HCAtlasLink.pinExecutable(home: URL(fileURLWithPath: "/Users/remote"), pin: c.pin).path
        let good = "exec /usr/bin/ssh -T -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no -k -- box 'exec /usr/bin/env -i XDG_CONFIG_HOME=/Users/remote/.local/share/c11/config sha256=\(c.pin.executableSHA256.lowercased()) \(binary) connect --session c11'"
        for name in ["studio", "Build-2.lan", "mac_mini"] {
            XCTAssertTrue(HCCoreUtility.isLinkMachineName(name), name)
            XCTAssertEqual(HCCoreUtility.linkPlan(via: via, script: good, machine: name, configuration: c),
                           .ready(["machine", "add", "--name", name, "--session", "c11", "--via", via.path]))
        }
        for name in ["default", "", "-x", "a b", ".hidden", "studio;rm", "studio\n", "studio\r\n", "local",
                     "stud\u{0456}o", String(repeating: "a", count: 65)] {
            XCTAssertFalse(HCCoreUtility.isLinkMachineName(name), name.debugDescription)
        }
    }

    /// C11H-365: inside a c11 terminal, whichever c11 variable marks it,
    /// `link --yes` is refused; without `--yes` (the typed question) or
    /// outside a c11 terminal it goes on. Fails with the guard removed.
    func testLinkRefusesYesOnlyInsideAC11Terminal() {
        for key in ["C11_PANEL_ID", "C11_SURFACE_ID", "CMUX_SURFACE_ID"] {
            let environment = [key: "11111111-2222-4333-8444-555555555555", "HOME": "/Users/demo"]
            let refusal = HCCoreUtility.linkYesRefusal(machine: "studio", yes: true, environment: environment)
            XCTAssertTrue(refusal?.contains("--yes isn't accepted inside a c11 terminal") == true, "\(key): \(refusal ?? "nil")")
            XCTAssertTrue(refusal?.contains("a shell on studio as you") == true, "\(key): \(refusal ?? "nil")")
            XCTAssertTrue(HCCoreUtility.insideC11Terminal(environment), key)
            XCTAssertNil(HCCoreUtility.linkYesRefusal(machine: "studio", yes: false, environment: environment),
                         "\(key): without --yes the operator is asked")
        }
        XCTAssertNil(HCCoreUtility.linkYesRefusal(machine: "studio", yes: true, environment: ["HOME": "/Users/demo"]),
                     "a plain terminal may pass --yes")
        XCTAssertNil(HCCoreUtility.linkYesRefusal(machine: "studio", yes: true, environment: ["C11_PANEL_ID": "", "CMUX_SURFACE_ID": ""]),
                     "an empty variable is not a c11 terminal")
    }

    /// C11H-365: the plan names the ssh target the via dials, read from the
    /// rendered via, and says so when it can't be read.
    func testLinkPlanNamesTheViasSSHTarget() throws {
        let c = try configuration()
        let binary = HCAtlasLink.pinExecutable(home: URL(fileURLWithPath: "/Users/remote"), pin: c.pin).path
        let remote = "exec /usr/bin/env -i HOME=/Users/remote USER=remote LOGNAME=remote SHELL=/bin/zsh LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin HC_SESSION=c11 HC_SOCKET=/Users/remote/.local/share/c11/run/c11.sock HC_SPAWN_MS=10000 XDG_CONFIG_HOME=/Users/remote/.local/share/c11/config sha256=\(c.pin.executableSHA256.lowercased()) \(binary) connect --session c11"
        let script = "#!/bin/sh\nstarted=$(date +%s)\n/usr/bin/ssh -T -o BatchMode=yes -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=10 -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no -k -- me@build.example '\(remote)' <&0 &\nchild=$!\n"
        let via = "/Users/demo/.local/share/c11/atlas-via.sh"
        // A via `link` admits, so these are the lines it prints before asking.
        guard case .ready = HCCoreUtility.linkPlan(via: URL(fileURLWithPath: via), script: script, machine: "studio", configuration: c) else {
            return XCTFail("the fixture is not a via link admits")
        }
        XCTAssertEqual(HCCoreUtility.linkSSHTarget(script: script), "me@build.example")
        let lines = HCCoreUtility.linkPlanLines(machine: "studio", viaPath: via, script: script)
        XCTAssertEqual(lines.first, "Plan (nothing changes until you say yes):")
        XCTAssertTrue(lines.contains { $0.contains("machine add studio, through \(via) (ssh target me@build.example)") },
                      lines.joined(separator: "\n"))
        for unreadable in [nil, "exec ssh studio herdr-core connect"] as [String?] {
            XCTAssertNil(HCCoreUtility.linkSSHTarget(script: unreadable))
            let shown = HCCoreUtility.linkPlanLines(machine: "studio", viaPath: via, script: unreadable).joined(separator: "\n")
            XCTAssertTrue(shown.contains("(ssh target unreadable)"), shown)
        }
    }

    // MARK: reconnect, consent, running the pin

    func testReconnectIsMachineLoginOnly() {
        XCTAssertEqual(HCCoreUtility.reconnectPlan(machine: "studio"), ["machine", "login", "studio"],
                       "hc 0.1.16 has no other redial than machine login")
    }

    func testTakeOverAndEveryActionAskFirstAndNeverPromptWithoutATerminal() {
        typealias C = HCCoreConsent
        // Watch-only open needs no consent, in every mode.
        for (json, tty) in [(false, true), (true, true), (false, false)] {
            XCTAssertEqual(HCCoreUtility.consent(required: false, yes: false, json: json, tty: tty, answer: nil), C.proceed)
            XCTAssertFalse(HCCoreUtility.shouldAsk(required: false, yes: false, json: json, tty: tty))
        }
        // A take-over (or restart, reconnect, link) asks on a terminal, and only "yes" proceeds.
        XCTAssertTrue(HCCoreUtility.shouldAsk(required: true, yes: false, json: false, tty: true))
        XCTAssertEqual(HCCoreUtility.consent(required: true, yes: false, json: false, tty: true, answer: true), C.proceed)
        XCTAssertEqual(HCCoreUtility.consent(required: true, yes: false, json: false, tty: true, answer: false), C.declined)
        XCTAssertEqual(HCCoreUtility.consent(required: true, yes: false, json: false, tty: true, answer: nil), C.declined)
        // Without --yes, --json or no terminal never prompts and never proceeds.
        XCTAssertEqual(HCCoreUtility.consent(required: true, yes: false, json: true, tty: true, answer: nil), C.needsYes)
        XCTAssertEqual(HCCoreUtility.consent(required: true, yes: false, json: false, tty: false, answer: nil), C.needsYes)
        XCTAssertFalse(HCCoreUtility.shouldAsk(required: true, yes: false, json: true, tty: true))
        XCTAssertFalse(HCCoreUtility.shouldAsk(required: true, yes: false, json: false, tty: false))
        // --yes is the consent.
        XCTAssertEqual(HCCoreUtility.consent(required: true, yes: true, json: true, tty: false, answer: nil), C.proceed)
        XCTAssertFalse(HCCoreUtility.shouldAsk(required: true, yes: true, json: false, tty: true))
    }

    /// `/bin/sh` stands in for the pinned binary; nothing else is run.
    private func shell() throws -> HCLaunchConfiguration {
        let c = try configuration()
        return HCLaunchConfiguration(executableURL: URL(fileURLWithPath: "/bin/sh"), session: c.session, socketURL: c.socketURL,
                                     stateDirectory: c.stateDirectory, intentDirectory: c.intentDirectory,
                                     environment: c.environment, pin: c.pin)
    }

    func testRunningThePinTimesOutAChildThatNeverFinishes() throws {
        let start = Date()
        let result = HCCoreUtility.runPinned(["-c", "sleep 8"], configuration: try shell(), timeout: 1)
        XCTAssertEqual(result.status, -1)
        XCTAssertTrue(result.output.contains("timed out"), result.output)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the timeout applies even while the pipe stays open")
    }

    func testRunningThePinReadsLargeOutputAndItsStatus() throws {
        let big = HCCoreUtility.runPinned(["-c", "head -c 200000 /dev/zero | tr '\\000' a"], configuration: try shell(), timeout: 10)
        XCTAssertEqual(big.status, 0)
        XCTAssertEqual(big.output.count, 200_000, "a full pipe never blocks the child")
        let small = HCCoreUtility.runPinned(["-c", "echo hi; exit 3"], configuration: try shell(), timeout: 10)
        XCTAssertEqual(small.status, 3)
        XCTAssertEqual(small.output, "hi")
    }

    // MARK: stats and c11's own files

    func testProcessTreeUsageAndPSParsing() {
        let rows = HCCoreSystemHost.parsePS("  410   405   0.0   1000\n  411   410   2,5   2000\nnonsense\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].cpuPercent, 2.5)
        XCTAssertEqual(rows[0].residentBytes, 1_024_000)
        let usage = HCCoreUtility.treeUsage(root: 410, table: rows)
        XCTAssertEqual(usage?.cpu, 2.5)
        XCTAssertEqual(usage?.memory, 3_072_000)
        XCTAssertNil(HCCoreUtility.treeUsage(root: 1, table: rows))
    }

    func testThePanelMapReadsC11hsAllocationsAndSessionSnapshot() throws {
        let allocations = try JSONSerialization.data(withJSONObject: ["version": 1, "panels": [["id": "AAAA0000-0000-0000-0000-000000000001", "number": 7]]])
        let session = try JSONSerialization.data(withJSONObject: ["windows": [["tabManager": ["workspaces": [
            ["id": "w", "customTitle": "", "processTitle": "Studio fleet", "panels": [["id": "AAAA0000-0000-0000-0000-000000000001"]]]]]]]])
        let map = HCCoreSystemHost.panelMap(session: session, allocations: allocations)
        XCTAssertEqual(map["aaaa0000-0000-0000-0000-000000000001"], HCCorePanelRef(ref: "panel:7", workspace: "Studio fleet"))
        XCTAssertTrue(HCCoreSystemHost.panelMap(session: nil, allocations: nil).isEmpty)
    }

    // MARK: the plain client, against an in-process socket

    func testThePlainClientSaysHelloReadsItsPeerAndSkipsNotifications() throws {
        let path = "/tmp/c11h37-\(UUID().uuidString.prefix(8)).sock"
        let server = try OneShotServer(path: path) { request in
            let id = request["id"] ?? NSNull()
            switch request["method"] as? String {
            case "hello": return [["jsonrpc": "2.0", "method": "event", "params": [:]],
                                  ["jsonrpc": "2.0", "id": id, "result": ["version": "0.1.16", "core": ["id": "x"]]]]
            case "terminal.get": return [["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "no such terminal", "data": ["kind": "not_found"]]]]
            default: return [["jsonrpc": "2.0", "id": id, "result": ["pid": 7]]]
            }
        }
        defer { server.stop() }
        let client = try HCCorePlainClient(path: path, timeout: 2)
        defer { client.close() }
        XCTAssertEqual(client.hello["version"] as? String, "0.1.16")
        XCTAssertEqual(client.peerPID, getpid(), "LOCAL_PEERPID names the serving process")
        XCTAssertEqual(client.peerUID, getuid())
        XCTAssertEqual(try client.call("server.status")["pid"] as? Int, 7)
        XCTAssertThrowsError(try client.call("terminal.get", ["terminal": "t9"])) {
            XCTAssertEqual(($0 as? HCCoreRPCError)?.code, "not_found")
        }
        XCTAssertThrowsError(try HCCorePlainClient(path: path + ".absent", timeout: 1))
    }

    private final class OneShotServer {
        private let fd: Int32
        private let path: String
        init(path: String, reply: @escaping ([String: Any]) -> [[String: Any]]) throws {
            self.path = path
            fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
            path.withCString { source in
                withUnsafeMutablePointer(to: &address.sun_path) {
                    strncpy(UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self), source, capacity)
                }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, Darwin.listen(fd, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
            let listener = fd
            Thread.detachNewThread {
                let client = Darwin.accept(listener, nil, nil)
                guard client >= 0 else { return }
                defer { Darwin.close(client) }
                var pending = Data()
                var bytes = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(client, &bytes, bytes.count)
                    if count <= 0 { return }
                    pending.append(contentsOf: bytes[0..<count])
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                        for object in reply(request) {
                            var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
                            data.append(0x0A)
                            _ = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
                        }
                    }
                }
            }
        }
        func stop() {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            Darwin.unlink(path)
        }
    }
}
