import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-126 part 2: Add Machine's steps against a fake runner (no ssh, no hc).
final class HCMachineSetupTests: XCTestCase {
    private var tmp: URL!
    private var resources: HCMachineSetupResources!
    private var configuration: HCLaunchConfiguration!
    private let pin = HCPin(version: "0.1.16", archiveSHA256: String(repeating: "a", count: 64),
                            executableSHA256: String(repeating: "b", count: 64), protocolGeneration: 1)

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("machinesetup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for name in ["link.sh", "relay.sh", "c11", "herdr-core"] {
            try Data(name.utf8).write(to: tmp.appendingPathComponent(name))
        }
        resources = HCMachineSetupResources(linkScript: tmp.appendingPathComponent("link.sh"),
                                            relayScript: tmp.appendingPathComponent("relay.sh"),
                                            cli: tmp.appendingPathComponent("c11"))
        configuration = HCLaunchConfiguration(
            executableURL: tmp.appendingPathComponent("herdr-core"), session: "c11",
            socketURL: tmp.appendingPathComponent("c11.sock"), stateDirectory: tmp, intentDirectory: tmp,
            environment: ["HC_SESSION": "c11", "HC_SOCKET": tmp.appendingPathComponent("c11.sock").path], pin: pin)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Pure parts

    func testHostsNamesAndDefaults() {
        XCTAssertTrue(HCMachineSetup.isValidHost("studio"))
        XCTAssertTrue(HCMachineSetup.isValidHost("me@studio.local"))
        XCTAssertFalse(HCMachineSetup.isValidHost("-oProxyCommand=x"), "never an ssh option")
        XCTAssertFalse(HCMachineSetup.isValidHost("studio;rm"))
        XCTAssertFalse(HCMachineSetup.isValidHost(""))
        XCTAssertEqual(HCMachineSetup.defaultName(forHost: "me@Studio.lan"), "studio")
        XCTAssertTrue(HCMachineSetup.isValidName("studio-2"))
        XCTAssertFalse(HCMachineSetup.isValidName("local"), "this Mac's word")
        XCTAssertFalse(HCMachineSetup.isValidName("Studio"))
    }

    func testSSHFailuresSayWhatToFix() {
        func code(_ stderr: String) -> String? {
            HCMachineSetup.classifySSH(status: 255, stderr: stderr, host: "studio")?.code
        }
        XCTAssertEqual(code("Host key verification failed."), "host_key_unknown")
        XCTAssertEqual(code("me@studio: Permission denied (publickey)."), "auth_refused")
        XCTAssertEqual(code("ssh: Could not resolve hostname studio: nodename nor servname provided"), "unknown_host")
        XCTAssertEqual(code("ssh: connect to host studio port 22: Operation timed out"), "unreachable")
        XCTAssertEqual(code("ssh: connect to host studio port 22: Connection refused"), "unreachable")
        XCTAssertEqual(code("Connection closed by ::1 port 22"), "unreachable", "Remote Login refusing this user")
        XCTAssertNil(HCMachineSetup.classifySSH(status: 1, stderr: "boom", host: "studio"), "only ssh's own 255")
        XCTAssertTrue(HCMachineSetupFailure.authRefused("studio").message.contains("ssh-copy-id studio"))
    }

    func testProbeAndMachineListParsing() throws {
        let probe = try XCTUnwrap(HCMachineSetupProbe.parse("os=Darwin\narch=arm64\nhome=/Users/me\nuser=me\nclt=yes\npin=ABC\n"))
        XCTAssertTrue(probe.isAppleSiliconMac)
        XCTAssertEqual(probe.pinSHA256, "abc")
        XCTAssertNil(HCMachineSetupProbe.parse("os=Darwin\n"), "a half answer is no answer")

        let list = try XCTUnwrap(HCMachineSetup.parseMachineList(
            #"{"machines":[{"name":"studio","state":"connected","version":"0.1.15","host":"studio"},{"name":"linuxbox","state":"needs_update"}]}"#))
        XCTAssertEqual(list.map(\.name), ["studio", "linuxbox"])
        XCTAssertTrue(HCMachineSetup.needsUpdate(list[0], pinVersion: "0.1.16"), "older hc there")
        XCTAssertFalse(HCMachineSetup.needsUpdate(list[0], pinVersion: "0.1.15"))
        XCTAssertTrue(HCMachineSetup.needsUpdate(list[1], pinVersion: "0.1.16"), "hc says so itself")
    }

    func testAViaIsReadBack() throws {
        let info = try XCTUnwrap(HCMachineSetup.ViaInfo.parse(Self.via(version: "0.1.15-abcdef012345")))
        XCTAssertEqual(info.target, "me@studio.local")
        XCTAssertEqual(info.hc, "/Users/me/.local/share/c11/hc/0.1.15-abcdef012345/herdr-core", "hash-keyed paths too")
        XCTAssertEqual(info.session, "c11")
        XCTAssertEqual(info.socket, "/Users/me/.local/share/c11/run/c11.sock")
        XCTAssertEqual(info.allowedServing(pin: String(repeating: "b", count: 64)), [String(repeating: "b", count: 64)],
                       "a via without a pin may stop only this build's core")
        XCTAssertNil(HCMachineSetup.ViaInfo.parse("#!/bin/sh\nexec /usr/bin/nc -U /tmp/bridge.sock\n"), "a bridge via has no ssh target")
        XCTAssertNil(HCMachineSetup.ViaInfo.parse(Self.via(version: "0.1.15").replacingOccurrences(of: "me@studio.local", with: "-oProxyCommand=x")))
    }

    /// The switches every link ssh carries (C11H-361), spelled out here so a
    /// test never derives its expectation from the code under test.
    static let forwardingOff = "-o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no -k"

    /// A via as `c11-atlas-link.sh render --mode ssh` writes it; `forwardingOff: false`
    /// is one an older c11 rendered before C11H-361.
    static func via(version: String, home: String = "/Users/me", sha: String? = nil, forwardingOff: Bool = true) -> String {
        let pin = sha.map { "sha256=\($0) " } ?? ""
        let switches = forwardingOff ? " " + Self.forwardingOff : ""
        let remote = "exec /usr/bin/env -i HOME=\(home) USER=me LOGNAME=me SHELL=/bin/zsh LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin HC_SESSION=c11 HC_SOCKET=\(home)/.local/share/c11/run/c11.sock HC_SPAWN_MS=10000 XDG_CONFIG_HOME=\(home)/.local/share/c11/config /usr/bin/python3 -I -c \\\"import base64,sys; exec(base64.b64decode(sys.argv[1]).decode())\\\" QUJD \(pin)\(home)/.local/share/c11/hc/\(version)/herdr-core connect --session c11"
        return "#!/bin/sh\nstarted=$(date +%s)\n/usr/bin/ssh -T -o BatchMode=yes -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=10\(switches) -- me@studio.local '\(remote)' <&0 &\nchild=$!\n"
    }

    func testLiveTerminalsOnAMachineFromHcLs() {
        let json = #"{"terminals":[{"address":"t1","state":"live"},{"address":"far/t2","state":"live"},{"address":"far/t3","state":"finished"},{"address":"farm/t4","state":"live"}]}"#
        XCTAssertEqual(HCMachineSetup.liveTerminals(on: "far", lsJSON: json), ["far/t2"], "only that machine's live ones")
        XCTAssertEqual(HCMachineSetup.liveTerminals(on: "far", lsJSON: "not json"), [])
    }

    // MARK: The flow

    func testAddsAMacInstallingHCAndTheRelay() {
        let runner = FakeRunner(probe: mac, verifyStates: ["connecting", "connected"])
        var seen: [HCMachineSetupProgress] = []
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "me@studio.local", name: nil)) { seen.append($0) }
        guard case .success(let result) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(result.name, "studio")
        XCTAssertTrue(result.installedHC)
        XCTAssertEqual(seen.filter { $0.state == .done }.map(\.step), [.reach, .install, .secure, .relay, .link, .verify])
        XCTAssertEqual(seen.first { $0.step == .reach && $0.state == .done }?.detail, "me@studio.local, Darwin arm64")
        // The hc binary goes over ssh's stdin into the install command, with this app's pin.
        let install = runner.calls.first { $0.argv.last?.contains("install --pin 0.1.16 --sha \(String(repeating: "b", count: 64))") == true }
        XCTAssertEqual(install?.stdin?.lastPathComponent, "herdr-core")
        XCTAssertTrue(install?.argv.last?.contains("/.local/share/c11/setup-") == true, "a staging folder of its own")
        XCTAssertNotNil(runner.calls.first { $0.argv.last?.contains("config/herdr-core") == true && $0.argv.last?.contains("[ ! -e") == true },
                        "c11's own hc config is written there, never over an existing one")
        let render = runner.calls.first { $0.argv.contains("render") }
        XCTAssertEqual(render.map { value(after: "--home", in: $0.argv) }, "/Users/me")
        XCTAssertEqual(render.map { value(after: "--sha", in: $0.argv) }, String(repeating: "b", count: 64),
                       "C11H-332: the via checks this build's hc hash at every dial")
        XCTAssertEqual(render.map { value(after: "--target", in: $0.argv) }, "me@studio.local")
        let add = runner.calls.first { $0.argv.contains("add") }
        XCTAssertEqual(add.map { value(after: "--session", in: $0.argv) }, "c11")
        XCTAssertEqual(add?.environment["HC_SESSION"], "c11", "the add runs against c11's own core")
        XCTAssertNotNil(runner.calls.last { $0.argv.last?.hasPrefix("rm -rf") == true }, "staging is cleaned up")
        let host = runner.calls.first { $0.argv.first == HCMachineSetup.sshPath }?.argv
        XCTAssertEqual(host.flatMap { $0.firstIndex(of: "--") }.map { host![$0 + 1] }, "me@studio.local",
                       "the host comes after --, never as an ssh option")
    }

    // C11H-332: an hc is kept only when it hashes to this build's pin.

    func testThisBuildsHCAlreadyThereIsKeptAndVerified() {
        let runner = FakeRunner(probe: mac + "pin=\(String(repeating: "b", count: 64))\n", verifyStates: ["connected"])
        var states: [HCMachineSetupStep: HCMachineSetupState] = [:]
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "studio", name: nil)) { states[$0.step] = $0.state }
        guard case .success(let result) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(result.installedHC)
        XCTAssertEqual(states[.install], .skipped)
        XCTAssertEqual(states[.secure], .done)
        XCTAssertNil(runner.calls.first { $0.argv.last?.contains(" install --pin") == true })
        let kinds = auditRecords().map(\.kind)
        XCTAssertEqual(kinds, ["hc_verified", "link"])
    }

    func testADifferentHCAtThePinPathIsReplacedNeverKept() {
        let runner = FakeRunner(probe: mac + "pin=\(String(repeating: "c", count: 64))\n", verifyStates: ["connected"])
        var states: [HCMachineSetupStep: HCMachineSetupState] = [:]
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "studio", name: nil)) { states[$0.step] = $0.state }
        guard case .success(let result) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(result.installedHC, "a different file at the pin path is replaced with this build's hc")
        XCTAssertEqual(states[.install], .done)
        XCTAssertNotNil(runner.calls.first { $0.argv.last?.contains(" install --pin 0.1.16 --sha \(String(repeating: "b", count: 64))") == true })
        let mismatch = auditRecords().first { $0.kind == "hc_hash_mismatch" }
        XCTAssertEqual(mismatch?.outcome, "replaced")
        XCTAssertEqual(mismatch?.detail, "found cccccccccccc, expected bbbbbbbbbbbb")
    }

    func testARunningDifferentHCIsRefusedAndAudited() {
        let runner = FakeRunner(probe: mac + "pin=\(String(repeating: "c", count: 64))\n", verifyStates: ["connected"], installStatus: 3)
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in })
        guard case .failure(let failure) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(failure, .installRefusedInUse("studio"))
        XCTAssertNil(runner.calls.first { $0.argv.contains("add") })
        let records = auditRecords()
        XCTAssertEqual(records.map(\.kind), ["hc_hash_mismatch", "link"])
        XCTAssertEqual(records.first?.outcome, "refused")
        XCTAssertEqual(records.last?.outcome, "failed")
        XCTAssertEqual(records.last?.code, "hc_in_use")
    }

    func testAnHCThatStillDiffersAfterInstallIsNeverLinked() {
        let runner = FakeRunner(probe: mac, verifyStates: ["connected"],
                                secure: "sha=\(String(repeating: "d", count: 64))\n")
        var states: [HCMachineSetupStep: HCMachineSetupState] = [:]
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "studio", name: nil)) { states[$0.step] = $0.state }
        guard case .failure(let failure) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(failure, .hcHashMismatch(host: "studio", found: String(repeating: "d", count: 64),
                                                expected: String(repeating: "b", count: 64)))
        XCTAssertEqual(failure.code, "hc_hash_mismatch")
        XCTAssertTrue(failure.message.contains("dddddddddddd") && failure.message.contains("bbbbbbbbbbbb"), failure.message)
        XCTAssertEqual(states[.secure], .failed)
        XCTAssertNil(runner.calls.first { $0.argv.contains("render") }, "no via is written for a wrong hc")
        XCTAssertNil(runner.calls.first { $0.argv.contains("add") }, "a wrong hc is never linked")
        let records = auditRecords()
        XCTAssertEqual(records.map(\.kind), ["hc_hash_mismatch", "link"])
        XCTAssertEqual(records.first?.outcome, "refused")
        XCTAssertEqual(records.last?.code, "hc_hash_mismatch")
        let missing = FakeRunner(probe: mac, verifyStates: ["connected"], secure: "sha=missing\n")
        guard case .failure(.hcHashMismatch(_, let found, _)) = flow(missing).run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in }) else {
            return XCTFail("a missing hc was linked")
        }
        XCTAssertEqual(found, "missing")
    }

    func testLooseFoldersThereAreMadePrivateAndAudited() {
        let runner = FakeRunner(probe: mac, verifyStates: ["connected"], secure: """
            sha=\(String(repeating: "b", count: 64))
            repaired=/Users/me/.local/share/c11/run 755
            created=/Users/me/.local/state/herdr-core/c11
            serving=none

            """)
        var seen: [HCMachineSetupProgress] = []
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "studio", name: nil)) { seen.append($0) }
        guard case .success = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(seen.first { $0.step == .secure && $0.state == .done }?.detail, "hc 0.1.16, 2 folders made private")
        let repaired = auditRecords().first { $0.kind == "dir_repaired" }
        XCTAssertEqual(repaired?.path, "/Users/me/.local/share/c11/run")
        XCTAssertEqual(repaired?.detail, "mode 755 to 700")
        XCTAssertEqual(repaired?.machine, "studio")
    }

    /// C11H-365 (L11): the machine being linked can't flood the audit log
    /// through its folder report. Only one line per folder c11 walks (computed
    /// here) and one refusal are accepted; any other report is invalid, fails
    /// the step and is recorded once. Fails with the parse's bounds removed.
    func testAnOversizedOrForeignFolderReportIsOneInvalidRecord() {
        let sha = "sha=\(String(repeating: "b", count: 64))\n"
        let flood = (0..<24_000).map { "repaired=/Users/me/f\($0) 755" }.joined(separator: "\n")
        let invalid = [
            sha + flood + "\nserving=none\n",
            // A folder the walk does not touch.
            sha + "repaired=/Users/me/elsewhere 755\nserving=none\n",
            // One walked folder twice.
            sha + "repaired=/Users/me/.local/share/c11/run 755\ncreated=/Users/me/.local/share/c11/run\nserving=none\n",
            // Two refusals.
            sha + "refused=/Users/me/.local/state/herdr-core symlink\nrefused=/Users/me/.local/state symlink\n",
        ]
        for report in invalid {
            let before = auditRecords().count
            let outcome = flow(FakeRunner(probe: mac, verifyStates: ["connected"], secure: report))
                .run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in })
            guard case .failure = outcome else { return XCTFail("an invalid folder report was accepted") }
            let added = Array(auditRecords().dropFirst(before))
            XCTAssertEqual(added.filter { $0.kind == "dir_refused" }.map(\.code), ["secure_report_invalid"], "\(added.map(\.kind))")
            XCTAssertEqual(added.filter { $0.kind == "dir_repaired" }.count, 0, "no record per report line")
            XCTAssertLessThanOrEqual(added.count, 3, "\(added.map(\.kind))")
        }
        // The walk's own three folders, each once, still parse.
        let folders = HCMachineSetup.securedFolders(home: "/Users/me", session: "c11", socket: "/Users/me/.local/share/c11/run/c11.sock")
        XCTAssertEqual(folders, ["/Users/me/.local/share/c11/run", "/Users/me/.local/state/herdr-core", "/Users/me/.local/state/herdr-core/c11"])
        let valid = sha + "repaired=/Users/me/.local/share/c11/run 755\ncreated=/Users/me/.local/state/herdr-core\n"
            + "created=/Users/me/.local/state/herdr-core/c11\nserving=none\n"
        XCTAssertEqual(HCMachineSetup.SecureReport.parse(valid, folders: folders)?.created.count, 2)
    }

    /// C11H-365 (L11): each of the report's other bounds on its own. A second
    /// `sha` line, a second `serving` line, or a report past 64 lines (here a
    /// valid report behind 60 lines of the login shell's start-up output)
    /// fails the step with one invalid-report record. A line that is not one
    /// of the report's keys is start-up output, ignored as before: a valid
    /// report beside three such lines still links. Fails with any one of the
    /// three bounds removed.
    func testARepeatedHashOrServingLineOrAnOverlongReportIsOneInvalidRecord() {
        let sha = "sha=\(String(repeating: "b", count: 64))\n"
        let valid = sha + "repaired=/Users/me/.local/share/c11/run 755\ncreated=/Users/me/.local/state/herdr-core\n"
            + "created=/Users/me/.local/state/herdr-core/c11\nserving=none\n"
        let startup = (0..<60).map { "start-up output \($0)" }.joined(separator: "\n") + "\n"
        let invalid = [
            ("a second sha line", valid + sha),
            ("a second serving line", valid + "serving=none\n"),
            ("65 lines", startup + valid),
        ]
        for (name, report) in invalid {
            let before = auditRecords().count
            let outcome = flow(FakeRunner(probe: mac, verifyStates: ["connected"], secure: report))
                .run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in })
            guard case .failure = outcome else { return XCTFail("a report with \(name) was accepted") }
            let added = Array(auditRecords().dropFirst(before))
            XCTAssertEqual(added.filter { $0.kind == "dir_refused" }.map(\.code), ["secure_report_invalid"],
                           "\(name): \(added.map(\.kind))")
        }
        let chatty = "Last login: Mon Nov 16 19:58 on ttys001\nLANG=en_US.UTF-8\nwelcome to studio\n" + valid
        let outcome = flow(FakeRunner(probe: mac, verifyStates: ["connected"], secure: chatty))
            .run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in })
        guard case .success = outcome else { return XCTFail("start-up output beside a valid report: \(outcome)") }
    }

    func testAFolderThatCantBeMadePrivateStopsTheLink() {
        let runner = FakeRunner(probe: mac, verifyStates: ["connected"], secure: """
            sha=\(String(repeating: "b", count: 64))
            refused=/Users/me/.local/state/herdr-core symlink

            """)
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in })
        guard case .failure(let failure) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(failure, .folderRefused(host: "studio", path: "/Users/me/.local/state/herdr-core", reason: "symlink"))
        XCTAssertNil(runner.calls.first { $0.argv.contains("add") })
        XCTAssertEqual(auditRecords().first { $0.kind == "dir_refused" }?.code, "symlink")
    }

    // C11H-332 repair 1.

    func testAForeignServingCoreThereIsRefusedNeverUsed() {
        let found = String(repeating: "e", count: 64)
        let runner = FakeRunner(probe: mac, verifyStates: ["connected"],
                                secure: "sha=\(String(repeating: "b", count: 64))\nserving=mismatch 4242 \(found)\n")
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in })
        guard case .failure(let failure) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(failure, .hcServingMismatch(host: "studio", pid: 4242, found: found))
        XCTAssertEqual(failure.code, "hc_serving_mismatch")
        XCTAssertNil(runner.calls.first { $0.argv.contains("render") }, "no via for a machine whose serving core isn't this build's")
        XCTAssertNil(runner.calls.first { $0.argv.contains("add") })
        XCTAssertNil(runner.calls.first { $0.argv.last?.contains("server stop") == true || $0.argv.last?.contains("kill") == true },
                     "the foreign core is never stopped or signalled")
        let refused = auditRecords().first { $0.kind == "hc_serving_mismatch" }
        XCTAssertEqual(refused?.outcome, "refused")
        XCTAssertEqual(refused?.detail, "pid 4242, found eeeeeeeeeeee")
        // A report that names no serving line is unverified, never assumed safe.
        let silent = FakeRunner(probe: mac, verifyStates: ["connected"], secure: "sha=\(String(repeating: "b", count: 64))\n")
        guard case .failure(.hcServingMismatch(_, 0, "unknown")) = flow(silent).run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in }) else {
            return XCTFail("an unverified serving core was accepted")
        }
        // This build's own core serving there is fine.
        let ours = FakeRunner(probe: mac, verifyStates: ["connected"],
                              secure: "sha=\(String(repeating: "b", count: 64))\nserving=ok 77\n")
        guard case .success = flow(ours).run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in }) else {
            return XCTFail("this build's serving core was refused")
        }
    }

    func testAnUpdateIsBoundToTheHostTheMachineIsLinkedThrough() throws {
        let oldVia = tmp.appendingPathComponent(".local/share/c11/vias/studio-via.sh")
        try FileManager.default.createDirectory(at: oldVia.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.via(version: "0.1.15").write(to: oldVia, atomically: true, encoding: .utf8)
        let runner = FakeRunner(probe: mac, verifyStates: ["connected"], linked: ["studio"], linkedVersion: "0.1.15",
                                linkedTarget: oldVia.path)
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "another-host", name: "studio", update: true), progress: { _ in })
        guard case .failure(let failure) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(failure, .updateTargetChanged(name: "studio", linked: "me@studio.local", requested: "another-host"))
        XCTAssertTrue(runner.calls.allSatisfy { $0.argv.first != HCMachineSetup.sshPath }, "nothing reaches either host")
        XCTAssertNil(runner.calls.first { $0.argv.contains("rm") }, "the existing link is kept")
        let unread = FakeRunner(probe: mac, verifyStates: ["connected"], linked: ["studio"], linkedVersion: "0.1.15", linkedTarget: nil)
        guard case .failure(.updateTargetUnknown("studio")) = flow(unread).run(HCMachineSetupRequest(host: "me@studio.local", name: "studio", update: true), progress: { _ in }) else {
            return XCTFail("an update went ahead without a readable target")
        }
        XCTAssertTrue(unread.calls.allSatisfy { $0.argv.first != HCMachineSetup.sshPath })
    }

    func testAFailedLinksAuditCarriesNoRawInputOrOutput() {
        let secret = "SECRET-SENTINEL-7731"
        _ = flow(FakeRunner(probe: mac, verifyStates: ["connected"]))
            .run(HCMachineSetupRequest(host: "ssh://alice:\(secret)@studio", name: nil), progress: { _ in })
        _ = flow(FakeRunner(probe: mac, verifyStates: ["connected"], sshFailure: "kex_exchange_identification: \(secret)"))
            .run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in })
        _ = flow(FakeRunner(probe: mac, verifyStates: ["connected"],
                            secure: "sha=\(String(repeating: "b", count: 64))\nrefused=/Users/me/\u{1B}]52;c;\(secret)\u{07} symlink\nserving=none\n"))
            .run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in })
        let records = auditRecords()
        XCTAssertEqual(records.filter { $0.kind == "link" }.map(\.code), ["invalid_host", "ssh_failed", "dir_refused"])
        XCTAssertEqual(records.first?.host, "invalid", "a rejected host is never recorded as typed")
        XCTAssertEqual(records.first { $0.kind == "dir_refused" }?.path, "invalid", "a path the far machine printed is checked")
        let text = (try? String(contentsOf: audit.fileURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(text.contains(secret), "no secret from an input or another program's output")
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 }, "no control characters")
    }

    func testAViaWithoutThePinNeedsUpdateAndStopsOnlyAfterACheck() {
        let pin = String(repeating: "b", count: 64)
        let machine = HCMachineSetup.ListedMachine(name: "studio", state: "connected", version: "0.1.16", host: nil)
        XCTAssertTrue(HCMachineSetup.needsUpdate(machine, pinVersion: "0.1.16", pinSHA256: pin, viaScript: Self.via(version: "0.1.16")),
                      "a via from before the pin was required needs Update")
        XCTAssertTrue(HCMachineSetup.needsUpdate(machine, pinVersion: "0.1.16", pinSHA256: pin,
                                                 viaScript: Self.via(version: "0.1.16", sha: String(repeating: "c", count: 64))))
        XCTAssertFalse(HCMachineSetup.needsUpdate(machine, pinVersion: "0.1.16", pinSHA256: pin,
                                                  viaScript: Self.via(version: "0.1.16", sha: pin)))
        let info = HCMachineSetup.ViaInfo.parse(Self.via(version: "0.1.16", sha: pin))
        XCTAssertEqual(info?.sha256, pin)
        XCTAssertNil(HCMachineSetup.ViaInfo.parse(Self.via(version: "0.1.16"))?.sha256)
        let prior = String(repeating: "c", count: 64)
        let older = HCMachineSetup.ViaInfo.parse(Self.via(version: "0.1.15", sha: prior))
        XCTAssertEqual(Set(older?.allowedServing(pin: pin) ?? []), [pin, prior], "an update may stop the old link's own pinned core")
        let stop = HCMachineSetup.stopCoreCommand(session: "c11", socket: "/Users/me/.local/share/c11/run/c11.sock",
                                                  hc: "/Users/me/.local/share/c11/hc/0.1.16/herdr-core", sha256: pin, allow: [prior], dir: "/d")
        XCTAssertEqual(stop, "/bin/sh \"/d/c11-atlas-link.sh\" stop --session c11 --socket /Users/me/.local/share/c11/run/c11.sock --hc /Users/me/.local/share/c11/hc/0.1.16/herdr-core --sha \(pin) --allow \([pin, prior].sorted().joined(separator: ","))")
    }

    // C11H-332 repair 2.

    func testAnUpdateNeverStopsAForeignServingCore() throws {
        let oldVia = tmp.appendingPathComponent(".local/share/c11/vias/studio-via.sh")
        try FileManager.default.createDirectory(at: oldVia.deletingLastPathComponent(), withIntermediateDirectories: true)
        let prior = String(repeating: "c", count: 64)
        try Self.via(version: "0.1.16", sha: prior).write(to: oldVia, atomically: true, encoding: .utf8)
        let foreign = String(repeating: "e", count: 64)
        let runner = FakeRunner(probe: mac, verifyStates: ["connected"], linked: ["studio"], linkedVersion: "0.1.15",
                                linkedTarget: oldVia.path, secure: "sha=\(String(repeating: "b", count: 64))\nserving=mismatch 4242 \(foreign)\n")
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "me@studio.local", name: "studio", update: true), progress: { _ in })
        guard case .failure(let failure) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(failure, .hcServingMismatch(host: "me@studio.local", pid: 4242, found: foreign), "the machine stays linked")
        XCTAssertNil(runner.calls.first { $0.argv.dropFirst().starts(with: ["machine", "rm"]) }, "nothing is unlinked")
        XCTAssertNil(runner.calls.first { $0.argv.last?.contains(" stop --session") == true || $0.argv.last?.contains("server stop") == true },
                     "a foreign serving core is never stopped")
        // The old link's own pinned core is the one an update may stop.
        let ours = FakeRunner(probe: mac, verifyStates: ["connected"], linked: ["studio"], linkedVersion: "0.1.15",
                              linkedTarget: oldVia.path, secure: "sha=\(String(repeating: "b", count: 64))\nserving=mismatch 77 \(prior)\n")
        guard case .success = flow(ours).run(HCMachineSetupRequest(host: "me@studio.local", name: "studio", update: true), progress: { _ in }) else {
            return XCTFail("the old link's own core blocked its update")
        }
        let stop = ours.calls.first { $0.argv.last?.contains(" stop --session") == true }?.argv.last ?? ""
        XCTAssertTrue(stop.contains("--allow \([String(repeating: "b", count: 64), prior].sorted().joined(separator: ","))"), stop)
    }

    /// The link script this build ships, from the built app beside the tests.
    private func bundledLinkScript() throws -> URL {
        var products = Bundle(for: Self.self).bundleURL
        for _ in 0..<6 {
            for appName in ["c11 DEV.app", "c11.app"] {
                let script = products.appendingPathComponent(appName + "/Contents/Resources/bin/c11-atlas-link.sh")
                if FileManager.default.isReadableFile(atPath: script.path) { return script }
            }
            products.deleteLastPathComponent()
        }
        throw XCTSkip("no built c11 app beside the tests")
    }

    /// C11H-332: an older c11's pinless stored via is migrated through the
    /// bundled link script: re-rendered with the pin from its own values,
    /// audited once; a second review finds it pinned. Fails with the
    /// migration removed (the via stays pinless).
    func testAStoredPinlessViaIsMigratedWithThePin() throws {
        let script = try bundledLinkScript()
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let vias = home.appendingPathComponent(".local/share/c11/vias", isDirectory: true)
        try FileManager.default.createDirectory(at: vias, withIntermediateDirectories: true)
        let via = vias.appendingPathComponent("studio-via.sh")
        try Self.via(version: "0.1.16").write(to: via, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(via.path, 0o700), 0)
        let pin = String(repeating: "b", count: 64)
        // A slow audit write: the record must still be on disk when review
        // returns (an app quit right after a migration lost a queued one).
        audit.afterOpenForTesting = { usleep(300_000) }
        let verdict = HCStoredLinks.review(machine: "studio", viaPath: via.path, home: home, pinSHA256: pin, mayWrite: true,
                                           linkScript: script, adopted: false, audit: audit)
        XCTAssertEqual(verdict, .migrated)
        // The file itself, not read(): read() waits on the writer's lock.
        let written = (try? String(contentsOf: audit.fileURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(written.contains("\"outcome\":\"migrated\""), "written before review returned")
        audit.afterOpenForTesting = nil
        let after = try String(contentsOf: via, encoding: .utf8)
        XCTAssertTrue(after.contains(" sha256=\(pin) /Users/me/.local/share/c11/hc/0.1.16/herdr-core connect --session c11"), after)
        XCTAssertEqual(HCMachineSetup.ViaInfo.parse(after)?.target, "me@studio.local", "the same host")
        XCTAssertEqual(HCMachineSetup.ViaInfo.parse(after)?.socket, "/Users/me/.local/share/c11/run/c11.sock", "the same core")
        XCTAssertEqual(HCStoredLinks.review(machine: "studio", viaPath: via.path, home: home, pinSHA256: pin, mayWrite: true,
                                            linkScript: script, adopted: false, audit: audit), .pinned)
        let records = auditRecords().filter { $0.kind == "link" && $0.outcome == "migrated" }
        XCTAssertEqual(records.map(\.machine), ["studio"], "audited once")
    }

    /// C11H-332: where migration can't happen, the link is unusable with its
    /// reason, and nothing is changed: a read-only shard, a via outside c11's
    /// folder, a folder c11 can't write, and no link script.
    func testAStoredLinkThatCantBeMigratedIsUnusableWithItsReason() throws {
        let script = try bundledLinkScript()
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let vias = home.appendingPathComponent(".local/share/c11/vias", isDirectory: true)
        try FileManager.default.createDirectory(at: vias, withIntermediateDirectories: true)
        let via = vias.appendingPathComponent("studio-via.sh")
        let original = Self.via(version: "0.1.16")
        try original.write(to: via, atomically: true, encoding: .utf8)
        let pin = String(repeating: "b", count: 64)
        func review(_ path: String?, mayWrite: Bool = true, linkScript: URL? = nil) -> HCStoredLinks.Verdict {
            HCStoredLinks.review(machine: "studio", viaPath: path, home: home, pinSHA256: pin, mayWrite: mayWrite,
                                 linkScript: linkScript, adopted: false, audit: audit)
        }
        XCTAssertEqual(review(via.path, mayWrite: false, linkScript: script), .unusable("read_only_shard"))
        XCTAssertEqual(review(via.path, linkScript: nil), .unusable("migrate_failed"))
        let outside = tmp.appendingPathComponent("outside-via.sh")
        try original.write(to: outside, atomically: true, encoding: .utf8)
        XCTAssertEqual(review(outside.path, linkScript: script), .unusable("via_outside"))
        XCTAssertEqual(review(nil, linkScript: script), .unusable("via_outside"), "a link with no via c11 can read")
        XCTAssertEqual(chmod(vias.path, 0o500), 0)
        defer { _ = chmod(vias.path, 0o700) }
        XCTAssertEqual(review(via.path, linkScript: script), .unusable("migrate_failed"), "the folder can't be written")
        for path in [via, outside] {
            XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), original, "nothing changed at \(path.lastPathComponent)")
        }
        XCTAssertEqual(chmod(vias.path, 0o700), 0)
        XCTAssertEqual(review(via.path, linkScript: script), .migrated, "and it is tried again once it can be")
    }

    // MARK: C11H-361: link ssh forwards nothing

    /// Fails unless every forwarding switch sits among ssh's options, before `--`.
    private func assertForwardsNothing(_ argv: [String], file: StaticString = #filePath, line: UInt = #line) {
        guard let dash = argv.firstIndex(of: "--") else { return XCTFail("no -- in \(argv)", file: file, line: line) }
        let options = Array(argv[..<dash])
        let values = Set(options.indices.compactMap { options[$0] == "-o" && $0 + 1 < options.count ? options[$0 + 1] : nil })
        for expected in ["ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes", "PermitLocalCommand=no"] {
            XCTAssertTrue(values.contains(expected), "\(expected) missing before --: \(argv)", file: file, line: line)
        }
        XCTAssertTrue(options.contains("-k"), "GSSAPI delegation (-k) missing before --: \(argv)", file: file, line: line)
        XCTAssertTrue(values.contains("ControlMaster=no") && values.contains("ControlPath=none"),
                      "connection sharing stays off: \(argv)", file: file, line: line)
    }

    /// Every ssh that Add Machine, Update and Remove actually run turns agent,
    /// X11 and port forwarding off. Fails with any switch removed from `sshArgv`.
    func testEveryLinkSSHForwardsNothing() throws {
        var argvs: [[String]] = []
        let add = FakeRunner(probe: mac, verifyStates: ["connected"])
        guard case .success = flow(add).run(HCMachineSetupRequest(host: "me@studio.local", name: nil), progress: { _ in }) else {
            return XCTFail("add failed")
        }
        argvs += add.calls.map(\.argv)
        let oldVia = tmp.appendingPathComponent(".local/share/c11/vias/studio-via.sh")
        try FileManager.default.createDirectory(at: oldVia.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.via(version: "0.1.15", forwardingOff: false).write(to: oldVia, atomically: true, encoding: .utf8)
        let update = FakeRunner(probe: mac, verifyStates: ["connected"], linked: ["studio"], linkedVersion: "0.1.15",
                                linkedTarget: oldVia.path)
        guard case .success = flow(update).run(HCMachineSetupRequest(host: "me@studio.local", name: "studio", update: true),
                                               progress: { _ in }) else { return XCTFail("update failed") }
        argvs += update.calls.map(\.argv)
        let remove = UnlinkRunner(state: "connected", liveRounds: 0)
        _ = MachineRemoval.unlink(machine: "far", configuration: configuration, runner: remove, verifyCore: { nil },
                                  viaScript: Self.via(version: "0.1.16", forwardingOff: false), keyring: C11RelayMemoryKeyring(),
                                  sleep: { _ in }, audit: audit, linkScript: resources.linkScript)
        argvs += remove.calls
        for (flow, calls) in [("add", add.calls.map(\.argv)), ("update", update.calls.map(\.argv)), ("remove", remove.calls)] {
            XCTAssertTrue(calls.contains { $0.first == HCMachineSetup.sshPath }, "\(flow) ran its own ssh steps")
        }
        for argv in argvs where argv.first == HCMachineSetup.sshPath { assertForwardsNothing(argv) }
    }

    /// ssh itself, given `sshArgv` and a config that forwards everything,
    /// resolves every forwarding off (`ssh -G` prints and exits; it opens no
    /// connection and reads no other config). Fails with any switch removed.
    /// The fixture says `ForwardAgent yes`, not a socket path: with a path,
    /// `ssh -G` prints that path even under `-o ForwardAgent=no`, while the
    /// agent request follows the flag the command line set to no.
    func testLinkSSHOverridesAConfigThatForwardsEverything() throws {
        guard FileManager.default.isExecutableFile(atPath: HCMachineSetup.sshPath) else { throw XCTSkip("no ssh") }
        let config = tmp.appendingPathComponent("ssh_config")
        try """
        Host *
          ForwardAgent yes
          ForwardX11 yes
          ForwardX11Trusted yes
          LocalForward 9999 localhost:22
          RemoteForward 9998 localhost:22
          DynamicForward 9997
          PermitLocalCommand yes
          LocalCommand true
          GSSAPIDelegateCredentials yes
          ControlMaster auto
          ControlPath /tmp/never-%C

        """.write(to: config, atomically: true, encoding: .utf8)
        let argv = HCMachineSetup.sshArgv(host: "me@studio.local", remoteCommand: "true")
        let output = HCMachineSetupProcessRunner().run([HCMachineSetup.sshPath, "-G", "-F", config.path] + argv.dropFirst(),
                                                       stdin: nil, environment: ["PATH": "/usr/bin:/bin", "HOME": tmp.path],
                                                       timeout: 10)
        XCTAssertEqual(output.status, 0, output.stderr)
        var resolved: [String: [String]] = [:]
        for line in output.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 { resolved[parts[0], default: []].append(parts[1]) }
        }
        XCTAssertEqual(resolved["forwardagent"], ["no"])
        XCTAssertEqual(resolved["forwardx11"], ["no"])
        XCTAssertEqual(resolved["clearallforwardings"], ["yes"])
        XCTAssertEqual(resolved["permitlocalcommand"], ["no"])
        if let delegation = resolved["gssapidelegatecredentials"] { XCTAssertEqual(delegation, ["no"]) }
        for forward in ["localforward", "remoteforward", "dynamicforward"] {
            XCTAssertNil(resolved[forward], "\(forward) survived: \(resolved[forward] ?? [])")
        }
        XCTAssertEqual(resolved["controlmaster"], ["false"], "connection sharing stays off")
    }

    /// A stored via that checks a pin but still forwards is not current; one
    /// that turns forwarding off is. Without a link script it can't be fixed,
    /// so it is unusable rather than used as it is.
    func testAStoredViaThatForwardsIsNotUsedAsItIs() throws {
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let vias = home.appendingPathComponent(".local/share/c11/vias", isDirectory: true)
        try FileManager.default.createDirectory(at: vias, withIntermediateDirectories: true)
        let pin = String(repeating: "b", count: 64)
        let current = vias.appendingPathComponent("current-via.sh"), forwarding = vias.appendingPathComponent("studio-via.sh")
        try Self.via(version: "0.1.16", sha: pin).write(to: current, atomically: true, encoding: .utf8)
        try Self.via(version: "0.1.16", sha: pin, forwardingOff: false).write(to: forwarding, atomically: true, encoding: .utf8)
        func review(_ via: URL) -> HCStoredLinks.Verdict {
            HCStoredLinks.review(machine: "studio", viaPath: via.path, home: home, pinSHA256: pin, mayWrite: true,
                                 linkScript: nil, adopted: false, audit: audit)
        }
        XCTAssertEqual(review(current), .pinned)
        XCTAssertEqual(review(forwarding), .unusable("migrate_failed"))
    }

    /// C11H-361 repair 1: a same-version, same-pin via that still forwards and
    /// that c11 couldn't migrate (here a read-only shard) reads in Settings as a
    /// link c11 won't use, with Update offered. Pin and version alone don't
    /// catch it. The same via with the switches is current. Fails with
    /// `linkUnchecked` asking `isPinned` again.
    @MainActor
    func testSettingsFlagsAViaThatForwardsAndCouldNotBeMigrated() throws {
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let vias = home.appendingPathComponent(".local/share/c11/vias", isDirectory: true)
        try FileManager.default.createDirectory(at: vias, withIntermediateDirectories: true)
        let pin = String(repeating: "b", count: 64)
        let forwarding = vias.appendingPathComponent("studio-via.sh"), current = vias.appendingPathComponent("good-via.sh")
        let forwardingText = Self.via(version: "0.1.16", sha: pin, forwardingOff: false)
        try forwardingText.write(to: forwarding, atomically: true, encoding: .utf8)
        try Self.via(version: "0.1.16", sha: pin).write(to: current, atomically: true, encoding: .utf8)
        XCTAssertEqual(HCStoredLinks.review(machine: "studio", viaPath: forwarding.path, home: home, pinSHA256: pin, mayWrite: false,
                                            linkScript: nil, adopted: false, audit: audit), .unusable("read_only_shard"),
                       "the session won't use it and can't migrate it")
        let studio = HCMachineSetup.ListedMachine(name: "studio", state: "connected", version: "0.1.16", host: nil, target: forwarding.path)
        XCTAssertFalse(HCMachineSetup.needsUpdate(studio, pinVersion: "0.1.16", pinSHA256: pin, viaScript: forwardingText),
                       "same version and pin: only the forwarding check can see it")
        let status = MachineHCStatus()
        status.home = home
        status.apply([studio, HCMachineSetup.ListedMachine(name: "good", state: "connected", version: "0.1.16", host: nil,
                                                          target: current.path)])
        XCTAssertTrue(status.linkUnchecked("studio"), "Settings says c11 won't use this link")
        XCTAssertTrue(status.needsUpdate("studio"), "and offers Update")
        XCTAssertFalse(status.linkUnchecked("good"), "the same via with the switches is current")
    }

    /// A pinned via from before C11H-361 is re-rendered through the bundled
    /// link script with the switches and its own pin (not this build's: its
    /// hc path names that pin's version), audited once as `forwarding_off`;
    /// a second review finds it current.
    func testAStoredViaThatForwardsIsMigratedKeepingItsOwnPin() throws {
        let script = try bundledLinkScript()
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let vias = home.appendingPathComponent(".local/share/c11/vias", isDirectory: true)
        try FileManager.default.createDirectory(at: vias, withIntermediateDirectories: true)
        let via = vias.appendingPathComponent("studio-via.sh")
        let own = String(repeating: "c", count: 64), pin = String(repeating: "b", count: 64)
        try Self.via(version: "0.1.15", sha: own, forwardingOff: false).write(to: via, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(via.path, 0o700), 0)
        func review() -> HCStoredLinks.Verdict {
            HCStoredLinks.review(machine: "studio", viaPath: via.path, home: home, pinSHA256: pin, mayWrite: true,
                                 linkScript: script, adopted: false, audit: audit)
        }
        XCTAssertEqual(review(), .migrated)
        let after = try String(contentsOf: via, encoding: .utf8)
        XCTAssertTrue(after.contains(" \(Self.forwardingOff) -- me@studio.local '"), after)
        XCTAssertTrue(after.contains(" sha256=\(own) /Users/me/.local/share/c11/hc/0.1.15/herdr-core connect --session c11"),
                      "its own pin and hc: \(after)")
        XCTAssertFalse(after.contains(pin), "never this build's pin over another version's hc")
        XCTAssertEqual(review(), .pinned)
        let records = auditRecords().filter { $0.kind == "link" && $0.outcome == "migrated" }
        XCTAssertEqual(records.map(\.code), ["forwarding_off"], "audited once")
    }

    func testRefusals() {
        func failure(probe: String, name: String? = nil, linked: [String] = [], ssh255: String? = nil,
                     installStatus: Int32 = 0, core: String? = nil) -> (HCMachineSetupFailure?, FakeRunner) {
            let runner = FakeRunner(probe: probe, verifyStates: ["connected"], linked: linked,
                                    sshFailure: ssh255, installStatus: installStatus)
            if case .failure(let error) = flow(runner, core: core).run(HCMachineSetupRequest(host: "studio", name: name), progress: { _ in }) {
                return (error, runner)
            }
            return (nil, runner)
        }
        func code(_ result: (HCMachineSetupFailure?, FakeRunner)) -> HCMachineSetupFailure? {
            XCTAssertNil(result.1.calls.first { $0.argv.contains("add") }, "\(String(describing: result.0)) added a machine")
            XCTAssertNil(result.1.calls.first { $0.argv.contains("render") }, "\(String(describing: result.0)) wrote a via")
            return result.0
        }
        XCTAssertEqual(code(failure(probe: "os=Linux\narch=x86_64\nhome=/home/me\nuser=me\n")), .needsPython("studio"),
                       "C11H-392: an x86-64 Linux machine is checked for what c11's link needs there")
        XCTAssertEqual(code(failure(probe: "os=Linux\narch=aarch64\nhome=/home/me\nuser=me\npython3=yes\nsha=yes\n")),
                       .unsupported(host: "studio", system: "Linux aarch64"))
        XCTAssertEqual(code(failure(probe: "os=Darwin\narch=x86_64\nhome=/Users/me\nuser=me\nclt=yes\n")),
                       .unsupported(host: "studio", system: "Darwin x86_64"))
        XCTAssertEqual(code(failure(probe: "os=Darwin\narch=arm64\nhome=/Users/me\nuser=me\nclt=no\n")), .needsCommandLineTools("studio"))
        // C11H-398: a Mac's relay step unpacks its kit with tar too.
        let noTar = failure(probe: "os=Darwin\narch=arm64\nhome=/Users/me\nuser=me\nclt=yes\n")
        XCTAssertEqual(code(noTar), .needsTar("studio"))
        XCTAssertEqual(noTar.1.calls.filter { $0.argv.first == HCMachineSetup.sshPath && $0.argv.last != "/bin/sh -s" }.count, 0,
                       "a Mac without tar was sent something")
        XCTAssertEqual(code(failure(probe: mac, linked: ["studio"])), .nameTaken("studio"), "hc's own list decides")
        XCTAssertEqual(code(failure(probe: mac, name: "here")), .invalidName("here"))
        XCTAssertEqual(code(failure(probe: mac, ssh255: "Host key verification failed.")), .hostKeyUnknown("studio"))
        XCTAssertEqual(code(failure(probe: mac, installStatus: 3)), .installRefusedInUse("studio"))
        let foreign = failure(probe: mac, core: "socket owned by another core")
        XCTAssertEqual(code(foreign), .coreUnavailable("socket owned by another core"))
        XCTAssertTrue(foreign.1.calls.isEmpty, "nothing runs against a core that isn't c11's")
    }

    // MARK: Linux machines (C11H-392)

    private static let linuxHC = Data("linux hc".utf8)
    private static let linuxCLI = Data("linux c11".utf8)
    private var linuxSHA: String { HCRemoteArtifactStore.sha256(Self.linuxHC) }
    private let linux = "os=Linux\narch=x86_64\nhome=/home/me\nuser=me\npython3=yes\nsha=yes\ntar=yes\nmanager=yes\nlinger=yes\nnofile=524288\n"

    /// The Linux files this build names, served by a stand-in for the release.
    private func linuxFiles(serving hc: Data = HCMachineSetupTests.linuxHC, manifest: Bool = true) throws -> HCMachineSetupLinuxFiles {
        func entry(_ name: String, _ bytes: Data) -> [String: Any] {
            ["platform": "linux-x86_64", "name": name, "version": "0.1.16", "sha256": HCRemoteArtifactStore.sha256(bytes),
             "asset": "\(name)-linux-x86_64", "url": "https://example.invalid/\(name)-linux-x86_64"]
        }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "artifacts": [entry("herdr-core", Self.linuxHC), entry("c11", Self.linuxCLI)]])
        let dir = tmp!
        let store = HCRemoteArtifactStore(cacheRoot: dir.appendingPathComponent("artifact-cache"), fetch: { url, _ in
            let file = dir.appendingPathComponent("download-\(UUID().uuidString)")
            try? (url.lastPathComponent.hasPrefix("herdr-core") ? hc : Self.linuxCLI).write(to: file)
            return .success(file)
        }, overrideBase: nil)
        return HCMachineSetupLinuxFiles(manifest: manifest ? HCRemoteArtifactManifest.parse(data) : nil, store: store)
    }

    private func linuxFlow(_ runner: FakeRunner, files: HCMachineSetupLinuxFiles?) -> HCMachineSetupFlow {
        HCMachineSetupFlow(configuration: configuration, resources: resources, runner: runner, localHome: tmp,
                           verifyCore: { nil }, verifyAttempts: 3, verifyInterval: 0, sleep: { _ in },
                           audit: audit, origin: "settings", linuxFiles: files)
    }

    /// Nothing but the probe reaches a machine Add Machine refuses.
    private func onlyProbed(_ runner: FakeRunner, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let sent = runner.calls.filter { $0.argv.first == HCMachineSetup.sshPath && $0.argv.last != "/bin/sh -s" }
        XCTAssertEqual(sent.map { $0.argv.last ?? "" }, [], message, file: file, line: line)
        XCTAssertNil(runner.calls.first { $0.argv.contains("render") }, message, file: file, line: line)
    }

    func testALinuxMachineIsCheckedForWhatItsCoreNeedsBeforeAnythingIsSent() throws {
        let base = "os=Linux\narch=x86_64\nhome=/home/me\nuser=me\n"
        let cases: [(String, HCMachineSetupFailure)] = [
            (base, .needsPython("studio")),
            (base + "python3=yes\n", .needsSHA256("studio")),
            // C11H-398: the relay step unpacks its kit with tar there.
            (base + "python3=yes\nsha=yes\n", .needsTar("studio")),
            (base + "python3=yes\nsha=yes\ntar=yes\n", .needsUserManager("studio")),
            (base + "python3=yes\nsha=yes\ntar=yes\nmanager=yes\n", .needsLinger(host: "studio", user: "me")),
            (base + "python3=yes\nsha=yes\ntar=yes\nmanager=yes\nlinger=yes\nnofile=1024\n", .needsNoFile(host: "studio", limit: 1024)),
            (base + "python3=yes\nsha=yes\ntar=yes\nmanager=yes\nlinger=yes\nnofile=\n", .needsNoFile(host: "studio", limit: 0)),
        ]
        for (probe, expected) in cases {
            let runner = FakeRunner(probe: probe, verifyStates: ["connected"])
            let outcome = linuxFlow(runner, files: try linuxFiles()).run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in })
            XCTAssertEqual(outcome, .failure(expected), probe)
            onlyProbed(runner, "\(expected.code) sent something")
        }
        XCTAssertTrue(HCMachineSetupFailure.needsLinger(host: "studio", user: "me").message.contains("“sudo loginctl enable-linger me”"))
        XCTAssertTrue(HCMachineSetupFailure.needsNoFile(host: "studio", limit: 1024).message.contains("DefaultLimitNOFILE=524288"))
        let infinite = try XCTUnwrap(HCMachineSetupProbe.parse(base + "python3=yes\nsha=yes\ntar=yes\nmanager=yes\nlinger=yes\nnofile=infinity\n"))
        XCTAssertNil(infinite.missing(host: "studio"))
        XCTAssertEqual(infinite.platform, .linuxX86_64)
        // A build that names no Linux files refuses before anything is written there.
        let runner = FakeRunner(probe: linux, verifyStates: ["connected"])
        XCTAssertEqual(linuxFlow(runner, files: try linuxFiles(manifest: false)).run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in }),
                       .failure(.linuxFilesMissing("studio")))
        onlyProbed(runner, "a build without Linux files sent something")
    }

    /// C11H-398: the real probe, run here by `/bin/sh -s` as ssh runs it
    /// there, reports tar only when the shell finds one on its PATH.
    func testTheProbeReportsTarOnlyWhenTheMachineHasOne() throws {
        let probeFile = tmp.appendingPathComponent("probe.sh")
        try HCMachineSetup.probeScript(pinVersion: "0.1.16").write(to: probeFile, atomically: true, encoding: .utf8)
        let bare = tmp.appendingPathComponent("bare-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        for tool in ["uname", "id", "awk", "shasum"] {
            let found = ["/usr/bin/\(tool)", "/bin/\(tool)"].first { FileManager.default.isExecutableFile(atPath: $0) }
            try FileManager.default.createSymbolicLink(atPath: bare.appendingPathComponent(tool).path,
                                                       withDestinationPath: try XCTUnwrap(found, tool))
        }
        func probe(path: String) throws -> HCMachineSetupProbe {
            let output = HCMachineSetupProcessRunner().run(["/bin/sh", "-s"], stdin: probeFile,
                                                           environment: ["HOME": tmp.path, "PATH": path], timeout: 30)
            XCTAssertEqual(output.status, 0, output.stderr)
            return try XCTUnwrap(HCMachineSetupProbe.parse(output.stdout), output.stdout)
        }
        XCTAssertTrue(try probe(path: "/usr/bin:/bin").hasTar, "the probe missed this machine's tar")
        let without = try probe(path: bare.path)
        XCTAssertFalse(without.hasTar, "the probe reported a tar the shell can't find")
        XCTAssertTrue(without.hasSHA256)
        if without.platform == .macArm64, without.hasCommandLineTools {
            XCTAssertEqual(without.missing(host: "studio"), .needsTar("studio"))
        }
    }

    func testALinuxMachineGetsTheHCAndCLIItsBuildNames() throws {
        let runner = FakeRunner(probe: linux, verifyStates: ["connected"], secure: "sha=\(linuxSHA)\nserving=none\n")
        let files = try linuxFiles()
        let outcome = linuxFlow(runner, files: files).run(HCMachineSetupRequest(host: "me@studio", name: nil), progress: { _ in })
        guard case .success(let result) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(result.name, "studio")
        let hc = try XCTUnwrap(files.manifest?.artifact(platform: "linux-x86_64", name: "herdr-core"))
        let install = runner.calls.first { $0.argv.last?.contains(" install --pin 0.1.16 --sha \(linuxSHA)") == true }
        XCTAssertEqual(install?.stdin, files.store.cachedURL(hc), "the Linux hc, from c11's checked cache, never this Mac's")
        XCTAssertNotNil(runner.calls.first { $0.argv.last?.contains("/\(HCMachineSetup.kitArchiveName)\" && chmod 700") == true },
                        "the relay kit goes over as one archive (its Linux c11: testAFreshKitThereCarriesTheClaudeWrapperItsNoteAndTheSkill)")
        let render = runner.calls.first { $0.argv.contains("render") }
        XCTAssertEqual(render.map { value(after: "--platform", in: $0.argv) }, "linux")
        XCTAssertEqual(render.map { value(after: "--sha", in: $0.argv) }, linuxSHA, "the via checks the Linux pin at every dial")
        XCTAssertEqual(render.map { value(after: "--home", in: $0.argv) }, "/home/me")
        // A Mac's link is rendered as before.
        let macRunner = FakeRunner(probe: mac, verifyStates: ["connected"])
        _ = linuxFlow(macRunner, files: files).run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in })
        XCTAssertEqual(macRunner.calls.first { $0.argv.contains("render") }.map { $0.argv.contains("--platform") }, false)
        XCTAssertEqual(macRunner.calls.first { $0.argv.last?.contains(" install --pin") == true }?.stdin?.lastPathComponent, "herdr-core")
    }

    /// C11H-392 (Astra 1 on #384): a fresh Add Machine, Linux or Mac, leaves a
    /// relay kit with c11's Claude wrapper, its agent note, Info.plist and the
    /// c11 skill. What the flow stages runs through the real installer into an
    /// empty home, and a bash with the kit's rc finds the kit's claude first.
    func testAFreshKitThereCarriesTheClaudeWrapperItsNoteAndTheSkill() throws {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let contents = tmp.appendingPathComponent("App.app/Contents", isDirectory: true)
        let appBin = contents.appendingPathComponent("Resources/bin", isDirectory: true)
        try fm.createDirectory(at: appBin, withIntermediateDirectories: true)
        try fm.copyItem(at: repo.appendingPathComponent("Resources/Info.plist"), to: contents.appendingPathComponent("Info.plist"))
        for name in HCMachineSetup.kitWrapperFiles {
            try fm.copyItem(at: repo.appendingPathComponent("Resources/bin/\(name)"), to: appBin.appendingPathComponent(name))
        }
        try fm.createDirectory(at: contents.appendingPathComponent("Resources/skills"), withIntermediateDirectories: true)
        try fm.copyItem(at: repo.appendingPathComponent("skills/c11"), to: contents.appendingPathComponent("Resources/skills/c11"))
        let kitResources = HCMachineSetupResources(linkScript: resources.linkScript,
                                                   relayScript: repo.appendingPathComponent("scripts/c11-atlas-relay.sh"),
                                                   cli: resources.cli, kitContents: contents)
        let files = try linuxFiles()
        for (probe, cli, pinned) in [(linux, Self.linuxCLI, linuxSHA), (mac, Data("c11".utf8), String(repeating: "b", count: 64))] {
            let home = tmp.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
            let standIn = home.appendingPathComponent("stand-in", isDirectory: true)
            try fm.createDirectory(at: standIn, withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho stand-in\n".utf8).write(to: standIn.appendingPathComponent("claude"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: standIn.appendingPathComponent("claude").path)
            let runner = LoopbackRelayRunner(fake: FakeRunner(probe: probe, verifyStates: ["connected"], secure: "sha=\(pinned)\nserving=none\n"),
                                             home: home)
            let flow = HCMachineSetupFlow(configuration: configuration, resources: kitResources, runner: runner, localHome: tmp,
                                          verifyCore: { nil }, verifyAttempts: 3, verifyInterval: 0, sleep: { _ in },
                                          audit: audit, origin: "settings", linuxFiles: files)
            let outcome = flow.run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in })
            guard case .success = outcome else { return XCTFail("\(probe): \(outcome)") }
            let kit = home.appendingPathComponent(".local/share/c11/relay/c11", isDirectory: true)
            let app = kit.appendingPathComponent("c11-relay.app/Contents", isDirectory: true)
            XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Resources/bin/c11")), cli, "the kit's c11 is that machine's")
            for rel in ["bin/claude", "libexec/claude"] {
                XCTAssertTrue(fm.isExecutableFile(atPath: kit.appendingPathComponent(rel).path), "\(probe): no \(rel)")
            }
            for rel in HCMachineSetup.kitWrapperFiles.map({ "Resources/bin/\($0)" }) + ["Info.plist", "Resources/skills/c11/SKILL.md"] {
                XCTAssertTrue(fm.fileExists(atPath: app.appendingPathComponent(rel).path), "\(probe): no \(rel)")
            }
            // What c11's launch line runs for a bash shell there, with another claude on PATH.
            let shell = HCMachineSetupProcessRunner().run(
                ["/bin/bash", "--rcfile", kit.appendingPathComponent("bash/rc").path, "-i", "-c", "command -v claude"], stdin: nil,
                environment: ["HOME": home.path, "PATH": "\(standIn.path):/usr/bin:/bin", "TERM": "dumb",
                              "C11_RELAY_BIN": kit.appendingPathComponent("bin").path,
                              "C11_RELAY_BASHRC": kit.appendingPathComponent("bash/rc").path,
                              "C11_SOCKET_PATH": kit.appendingPathComponent("no-socket").path],
                timeout: 20)
            XCTAssertEqual(shell.stdout.trimmingCharacters(in: .whitespacesAndNewlines), kit.appendingPathComponent("bin/claude").path,
                           "\(probe): \(shell.stderr)")
            let left = (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(".local/share/c11").path)) ?? []
            XCTAssertEqual(left.filter { $0.hasPrefix("setup-") }, [], "the staging folder is removed")
        }
    }

    func testALinuxFileThatDoesNotHashToItsPinIsNeverSent() throws {
        let runner = FakeRunner(probe: linux, verifyStates: ["connected"])
        let wrong = Data("someone else's hc".utf8)
        let outcome = linuxFlow(runner, files: try linuxFiles(serving: wrong)).run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in })
        XCTAssertEqual(outcome, .failure(.linuxFileMismatch(name: "herdr-core", found: HCRemoteArtifactStore.sha256(wrong), expected: linuxSHA)))
        onlyProbed(runner, "a mismatched Linux hc was sent")
    }

    func testALinuxLinkPinnedToThisBuildsLinuxHCIsCurrent() {
        let machine = HCMachineSetup.ListedMachine(name: "cube", state: "connected", version: "0.1.16", host: nil)
        let via = Self.via(version: "0.1.16", home: "/home/me", sha: linuxSHA)
        XCTAssertTrue(HCMachineSetup.needsUpdate(machine, pinVersion: "0.1.16", pinSHA256: String(repeating: "b", count: 64), viaScript: via),
                      "without the Linux pin it reads as another build's")
        XCTAssertFalse(HCMachineSetup.needsUpdate(machine, pinVersion: "0.1.16", pinSHA256: String(repeating: "b", count: 64), viaScript: via,
                                                  otherPins: [linuxSHA]))
    }

    func testAFailedAddRemovesTheViaItRendered() {
        let runner = FakeRunner(probe: mac, verifyStates: ["connected"], addStatus: 1)
        let via = HCMachineSetup.viaURL(home: tmp, name: "studio")
        runner.onRender = { try? FileManager.default.createDirectory(at: via.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("via".utf8).write(to: via) }
        guard case .failure(.addFailed) = flow(runner).run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in }) else {
            return XCTFail("expected add_failed")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: via.path))
    }

    func testUpdateStopsTheOldHCAndRelinksAtThisVersion() throws {
        let oldVia = tmp.appendingPathComponent(".local/share/c11/vias/studio-via.sh")
        try FileManager.default.createDirectory(at: oldVia.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.via(version: "0.1.15").write(to: oldVia, atomically: true, encoding: .utf8)
        let runner = FakeRunner(probe: mac, verifyStates: ["connected"], linked: ["studio"], linkedVersion: "0.1.15",
                                linkedTarget: oldVia.path)
        var states: [HCMachineSetupStep: HCMachineSetupState] = [:]
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "me@studio.local", name: "studio", update: true)) { states[$0.step] = $0.state }
        guard case .success(let result) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(result.version, "0.1.16")
        let verbs = runner.calls.map { $0.argv.dropFirst().prefix(2).joined(separator: " ") }
        let stop = runner.calls.firstIndex { $0.argv.last?.contains(" stop --session") == true }
        let rm = verbs.firstIndex(of: "machine rm"), add = runner.calls.firstIndex { $0.argv.contains("add") }
        let stopLine = stop.flatMap { runner.calls[$0].argv.last } ?? ""
        XCTAssertTrue(stopLine.contains(" stop --session c11 --socket /Users/me/.local/share/c11/run/c11.sock --hc /Users/me/.local/share/c11/hc/0.1.16/herdr-core"),
                      "C11H-332: the old core is stopped through the checked stop, with this build's hc: \(stopLine)")
        let secure = runner.calls.firstIndex { $0.argv.last?.contains(" secure --session") == true }
        if let secure, let rm { XCTAssertLessThan(secure, rm, "the serving core is identified before anything is unlinked") }
        else { XCTFail("missing secure/rm") }
        if let stop, let rm, let add { XCTAssertTrue(rm < stop && stop < add, "unlink, stop the old hc, then link anew") }
        else { XCTFail("missing stop/rm/add") }
        XCTAssertEqual(runner.calls.first { $0.argv.contains("render") }.map { value(after: "--hc", in: $0.argv) },
                       "/Users/me/.local/share/c11/hc/0.1.16/herdr-core", "the new via runs this build's hc")
    }

    func testUpdateRefusesWhileTerminalsRunThere() throws {
        let oldVia = tmp.appendingPathComponent(".local/share/c11/vias/studio-via.sh")
        try FileManager.default.createDirectory(at: oldVia.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.via(version: "0.1.15").write(to: oldVia, atomically: true, encoding: .utf8)
        let runner = FakeRunner(probe: mac, verifyStates: ["connected"], linked: ["studio"], linkedVersion: "0.1.15",
                                linkedTarget: oldVia.path, liveOnMachine: ["studio/t1", "studio/t2"])
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "me@studio.local", name: "studio", update: true), progress: { _ in })
        guard case .failure(let failure) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(failure, .updateNeedsNoTerminals("studio", 2))
        XCTAssertTrue(runner.calls.allSatisfy { $0.argv.first != HCMachineSetup.sshPath }, "nothing touched there")
    }

    func testVerifyWaitsForThisBuildsVersion() {
        let runner = FakeRunner(probe: mac, verifyStates: ["connected"], verifyVersion: "0.1.15")
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in })
        guard case .failure(let failure) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(failure, .notConnected("studio", "connected, hc 0.1.15"))
    }

    func testALinkThatNeverConnectsIsReported() {
        let runner = FakeRunner(probe: mac, verifyStates: ["unreachable"])
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "studio", name: nil), progress: { _ in })
        guard case .failure(let failure) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(failure, .notConnected("studio", "unreachable, hc 0.1.16"))
    }

    // MARK: Remove

    func testUnlinkEndsTerminalsAndStopsTheCoreBeforeRemoving() {
        let runner = UnlinkRunner(state: "connected", liveRounds: 2)
        // C11H-176: removing the machine revokes its relay secret in this app's session.
        let keyring = C11RelayMemoryKeyring()
        _ = keyring.secretCreatingIfNeeded(session: configuration.session, machine: "far")
        _ = keyring.secretCreatingIfNeeded(session: configuration.session, machine: "near")
        let outcome = MachineRemoval.unlink(machine: "far", configuration: configuration, runner: runner,
                                            verifyCore: { nil }, viaScript: Self.via(version: "0.1.16"), keyring: keyring,
                                            sleep: { _ in }, audit: audit, linkScript: resources.linkScript)
        guard case .success(let value) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(value.leftRunning)
        let unlinked = auditRecords().last
        XCTAssertEqual(unlinked?.kind, "unlink", "C11H-332: an unlink is a line in the audit log")
        XCTAssertEqual(unlinked?.outcome, "ok")
        XCTAssertEqual(unlinked?.machine, "far")
        XCTAssertNil(keyring.secret(session: configuration.session, machine: "far"), "every credential made for far stops verifying")
        XCTAssertNotNil(keyring.secret(session: configuration.session, machine: "near"))
        let verbs = runner.calls.map { $0.dropFirst().prefix(2).joined(separator: " ") }
        let kill = verbs.firstIndex(of: "kill far/t2"), rm = verbs.firstIndex(of: "machine rm")
        let stop = runner.calls.firstIndex { $0.first == HCMachineSetup.sshPath && $0.last?.contains(" stop --session") == true }
        if let kill, let stop, let rm {
            XCTAssertLessThan(kill, rm, "terminals end while the link is up")
            XCTAssertLessThan(rm, stop, "the far core stops only once hc can no longer dial it back up")
        } else { XCTFail("missing kill/rm/stop: \(verbs)") }
        XCTAssertTrue(runner.calls[stop ?? 0].contains("me@studio.local"), "over the via's own ssh target")
        XCTAssertTrue(runner.calls[stop ?? 0].last?.contains("--sha \(String(repeating: "b", count: 64)) --allow \(String(repeating: "b", count: 64))") == true,
                      "C11H-332: a via from before the pin is stopped only as this build's pinned core: \(runner.calls[stop ?? 0].last ?? "")")
    }

    /// C11H-391 (Astra 1 on #382): one name linked in two of this app's
    /// sessions, c11h's old link and c11's links session, each serving a
    /// relay. Removing one session's link revokes that session's secret and
    /// forgets its pickups; the other session's terminals keep theirs, so
    /// their signed calls still verify. Either session alone, the other kept.
    func testRemovingOneSessionsLinkRevokesOnlyThatSessionsRelayCredentials() {
        let other = "c11-astra1-\(UUID().uuidString.prefix(8))"
        _ = C11RelayServices.shared.service(for: other)
        XCTAssertTrue(C11RelayServices.shared.sessions.contains(other), "the app serves both sessions' relays")
        for removed in [configuration.session, other] {
            let kept = removed == other ? configuration.session : other
            let keyring = C11RelayMemoryKeyring()
            let keptSecret = keyring.secretCreatingIfNeeded(session: kept, machine: "far")
            _ = keyring.secretCreatingIfNeeded(session: removed, machine: "far")
            let ledgers = [removed: C11RelayPickupLedger(url: nil), kept: C11RelayPickupLedger(url: nil)]
            for (session, ledger) in ledgers {
                ledger.add(.init(machine: "far", name: "pickup.\(session)", creation: session, masked: "x", at: 1))
            }
            let removing = HCLaunchConfiguration(
                executableURL: configuration.executableURL, session: removed, socketURL: configuration.socketURL,
                stateDirectory: configuration.stateDirectory, intentDirectory: configuration.intentDirectory,
                environment: configuration.environment, pin: configuration.pin)
            let outcome = MachineRemoval.unlink(machine: "far", configuration: removing, runner: UnlinkRunner(state: "connected", liveRounds: 1),
                                                verifyCore: { nil }, viaScript: Self.via(version: "0.1.16"), keyring: keyring,
                                                pickups: { ledgers[$0] ?? C11RelayPickupLedger(url: nil) },
                                                sleep: { _ in }, audit: audit, linkScript: resources.linkScript)
            guard case .success = outcome else { return XCTFail("\(outcome)") }
            XCTAssertNil(keyring.secret(session: removed, machine: "far"), "removing \(removed)'s link revokes its credentials")
            XCTAssertNotNil(keptSecret)
            XCTAssertEqual(keyring.secret(session: kept, machine: "far"), keptSecret,
                           "\(kept)'s terminals on far keep verifying after \(removed)'s link goes")
            XCTAssertTrue(ledgers[removed]?.pending(machine: "far", olderThan: .max).isEmpty == true)
            XCTAssertEqual(ledgers[kept]?.pending(machine: "far", olderThan: .max).map(\.name), ["pickup.\(kept)"],
                           "\(kept)'s pickups wait for its terminals")
        }
    }

    /// C11H-274: a link an adopted c11h made. Remove ends its terminals, runs
    /// no stop there (c11's checked stop refuses c11h's session, and c11 never
    /// stops an hc it didn't install) and says so, not "its link was down".
    func testUnlinkOfAC11hLinkEndsItsTerminalsAndSaysC11hsHcStillRuns() {
        let c11hVia = Self.via(version: "0.1.16", forwardingOff: false)
            .replacingOccurrences(of: "/.local/share/c11/", with: "/.local/share/c11h/")
            .replacingOccurrences(of: "run/c11.sock", with: "run/c11h.sock")
            .replacingOccurrences(of: "HC_SESSION=c11 ", with: "HC_SESSION=c11h ")
            .replacingOccurrences(of: "--session c11", with: "--session c11h")
        XCTAssertEqual(HCMachineSetup.ViaInfo.parse(c11hVia, adopted: true)?.session, "c11h", "the fixture is a c11h via")
        let runner = UnlinkRunner(state: "connected", liveRounds: 1)
        let outcome = MachineRemoval.unlink(machine: "far", configuration: configuration, runner: runner,
                                            verifyCore: { nil }, viaScript: c11hVia, keyring: C11RelayMemoryKeyring(),
                                            sleep: { _ in }, audit: audit, linkScript: resources.linkScript)
        guard case .success(let value) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(value.c11hLink)
        XCTAssertTrue(value.linkWasUp)
        let verbs = runner.calls.map { $0.dropFirst().prefix(2).joined(separator: " ") }
        XCTAssertTrue(verbs.contains("kill far/t2") && verbs.contains("machine rm"), "its terminals end and the link goes: \(verbs)")
        XCTAssertFalse(runner.calls.contains { $0.first == HCMachineSetup.sshPath }, "no stop is attempted on c11h's hc")
        let detail = auditRecords().last?.detail ?? ""
        XCTAssertTrue(detail.contains("ended its c11h terminals") && detail.contains("c11h's hc there still runs"), detail)
        XCTAssertFalse(detail.contains("link was down"), detail)

        XCTAssertTrue(MachineRemoval.isC11hLink(viaPath: "/Users/me/.local/share/c11h/vela-via.sh", session: nil, home: URL(fileURLWithPath: "/Users/me")))
        XCTAssertTrue(MachineRemoval.isC11hLink(viaPath: nil, session: "c11h-s2", home: URL(fileURLWithPath: "/Users/me")))
        XCTAssertFalse(MachineRemoval.isC11hLink(viaPath: "/Users/me/.local/share/c11/vias/far-via.sh", session: "c11",
                                                 home: URL(fileURLWithPath: "/Users/me")))
    }

    func testUnlinkKeepsTheMachineWhenTerminalsWontEnd() {
        let runner = UnlinkRunner(state: "connected", liveRounds: 100)
        let outcome = MachineRemoval.unlink(machine: "far", configuration: configuration, runner: runner,
                                            verifyCore: { nil }, viaScript: Self.via(version: "0.1.16"), keyring: C11RelayMemoryKeyring(), sleep: { _ in }, audit: audit, linkScript: resources.linkScript)
        guard case .failure(let failure) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(failure.code, "remove_incomplete")
        XCTAssertFalse(runner.calls.contains { $0.contains("rm") && $0.contains("machine") }, "nothing removed")
        XCTAssertEqual(auditRecords().map { "\($0.kind) \($0.outcome) \($0.code ?? "")" }, ["unlink failed remove_incomplete"])
    }

    func testUnlinkOfADownMachineSaysWhatMayStillRun() {
        let runner = UnlinkRunner(state: "unreachable", liveRounds: 0, sshStatus: 255)
        let outcome = MachineRemoval.unlink(machine: "far", configuration: configuration, runner: runner,
                                            verifyCore: { nil }, viaScript: Self.via(version: "0.1.16"), keyring: C11RelayMemoryKeyring(), sleep: { _ in }, audit: audit, linkScript: resources.linkScript)
        guard case .success(let value) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(value.leftRunning)
        XCTAssertFalse(runner.calls.contains { $0.contains("kill") }, "no hc call reaches a down machine")
    }

    /// C11H-332: a failed unlink is audited by code; hc's own output stays out.
    func testAFailedUnlinksAuditCarriesNoRawOutput() {
        let secret = "SECRET-SENTINEL-7731"
        let runner = UnlinkRunner(state: "connected", liveRounds: 0, rmFailure: "remove failed: \(secret)")
        let outcome = MachineRemoval.unlink(machine: "far", configuration: configuration, runner: runner,
                                            verifyCore: { nil }, viaScript: Self.via(version: "0.1.16"), keyring: C11RelayMemoryKeyring(), sleep: { _ in }, audit: audit, linkScript: resources.linkScript)
        guard case .failure(let failure) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(failure.message.contains(secret), "the operator still sees hc's reason")
        let record = auditRecords().last
        XCTAssertEqual(record?.kind, "unlink")
        XCTAssertEqual(record?.code, "remove_failed")
        XCTAssertNil(record?.detail)
        XCTAssertFalse(((try? String(contentsOf: audit.fileURL, encoding: .utf8)) ?? "").contains(secret))
    }

    func testAStopThatRefusesAnUncheckedHCSaysSo() {
        for status: Int32 in [7, 8] {
            let runner = UnlinkRunner(state: "connected", liveRounds: 0, sshStatus: status)
            let outcome = MachineRemoval.unlink(machine: "far", configuration: configuration, runner: runner,
                                                verifyCore: { nil }, viaScript: Self.via(version: "0.1.16"), keyring: C11RelayMemoryKeyring(), sleep: { _ in }, audit: audit, linkScript: resources.linkScript)
            guard case .success(let value) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertTrue(value.stopRefused, "C11H-332: Remove never stops a core it can't confirm as its own (exit \(status))")
            XCTAssertNil(runner.calls.first { $0.last?.contains("server stop") == true }, "no unchecked stop is ever sent")
        }
        let runner = UnlinkRunner(state: "connected", liveRounds: 0, sshStatus: 7)
        let outcome = MachineRemoval.unlink(machine: "far", configuration: configuration, runner: runner,
                                            verifyCore: { nil }, viaScript: Self.via(version: "0.1.16"), keyring: C11RelayMemoryKeyring(), sleep: { _ in }, audit: audit, linkScript: resources.linkScript)
        guard case .success(let value) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(value.leftRunning)
        XCTAssertTrue(value.stopRefused, "C11H-332: a hash that didn't match is named, not reported as a down link")
        XCTAssertEqual(auditRecords().last?.detail, "c11 couldn't confirm the hc there is its own, so it didn't stop it")
    }

    func testAStopThatFailsIsReportedAsLeftRunning() {
        let runner = UnlinkRunner(state: "connected", liveRounds: 0, sshStatus: 1)
        let outcome = MachineRemoval.unlink(machine: "far", configuration: configuration, runner: runner,
                                            verifyCore: { nil }, viaScript: Self.via(version: "0.1.16"), keyring: C11RelayMemoryKeyring(), sleep: { _ in }, audit: audit, linkScript: resources.linkScript)
        guard case .success(let value) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(value.leftRunning, "only a confirmed stop counts")
    }

    func testAnUnreadableViaIsReportedAsLeftRunning() {
        let runner = UnlinkRunner(state: "connected", liveRounds: 0)
        let outcome = MachineRemoval.unlink(machine: "far", configuration: configuration, runner: runner,
                                            verifyCore: { nil }, viaScript: "#!/bin/sh\nexec /usr/bin/nc -U /tmp/x.sock\n", keyring: C11RelayMemoryKeyring(), sleep: { _ in }, audit: audit, linkScript: resources.linkScript)
        guard case .success(let value) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(value.leftRunning)
    }

    // MARK: Add Machine while adopted (C11H-391)

    /// C11H-391 (Astra 3 on #382): c11h's old link and c11's own link of one
    /// name, kept while c11h's agents finish. c11's own link is updated or
    /// repaired from its own session, as if alone (Update, `update: true`,
    /// its own entry's SSH target); c11h's link is noted and removed on its
    /// own. A usable own link offers no Update. Link Again only while c11's
    /// own link is absent.
    func testWithBothLinksC11sOwnLinkIsUpdatedFromItsOwnSession() {
        let outdated = "Runs hc 0.1.15; this c11 uses 0.1.16."
        let beside = MachineLinkActions.c11hLinkNote(beside: true)
        let both = MachineLinkActions.decide(own: "c11", c11h: "c11h", isLocal: false, ownNote: outdated, ownOffersUpdate: true)
        XCTAssertTrue(both.offersUpdate, "c11's own link needs an update: Update is offered while c11h's link remains")
        XCTAssertFalse(both.linksAgain, "it reads Update, not Link Again")
        XCTAssertTrue(both.update)
        XCTAssertEqual(both.targetSession, "c11", "Update takes the SSH target from c11's own entry")
        XCTAssertEqual(both.removeSession, "c11")
        XCTAssertEqual(both.removeC11hLinkSession, "c11h", "Remove c11h's Link stays beside it")
        XCTAssertEqual(both.note, "\(outdated) \(beside)", "both notes")

        let usable = MachineLinkActions.decide(own: "c11", c11h: "c11h", isLocal: false, ownNote: nil, ownOffersUpdate: true)
        XCTAssertFalse(usable.offersUpdate, "c11's own link is current: no Update")
        XCTAssertEqual(usable.note, beside)
        XCTAssertEqual(usable.removeC11hLinkSession, "c11h")

        let onlyC11h = MachineLinkActions.decide(own: nil, c11h: "c11h", isLocal: false, ownNote: outdated, ownOffersUpdate: true)
        XCTAssertTrue(onlyC11h.offersUpdate && onlyC11h.linksAgain, "only c11h's link: Link Again")
        XCTAssertFalse(onlyC11h.update, "a first link in c11's own session")
        XCTAssertEqual(onlyC11h.targetSession, "c11h", "prefilled from c11h's entry")
        XCTAssertNil(onlyC11h.removeC11hLinkSession)
        XCTAssertEqual(onlyC11h.note, MachineLinkActions.c11hLinkNote(beside: false))

        let own = MachineLinkActions.decide(own: "c11", c11h: nil, isLocal: false, ownNote: outdated, ownOffersUpdate: false)
        XCTAssertEqual(own, MachineLinkActions(note: outdated, offersUpdate: false, linksAgain: false, targetSession: "c11",
                                               update: true, removeSession: "c11", removeC11hLinkSession: nil),
                       "one link: the row as before this ticket")
    }

    /// Opus on #382 (Blocking 2): Add Machine and Update from Settings, while
    /// adopted, run their steps in the links session's configuration (c11's
    /// own), never shard 0's adopted one, and start that session's core first.
    @MainActor
    func testSettingsAddMachineWhileAdoptedRunsInTheLinksSession() async throws {
        struct NoCore: HCConnectionFactory {
            func connect(_ request: HCConnectionRequest, verify: @escaping HCServingBuildVerifier) async throws -> any HCConnection {
                throw HCUnavailableReason.coreUnreachable
            }
        }
        struct NoLaunch: HCCoreLaunching {
            func start(_ configuration: HCLaunchConfiguration, deadlineUptimeNanoseconds: UInt64) async throws -> HCLaunchLimitReport {
                throw HCUnavailableReason.pinMismatch
            }
        }
        struct NoVerifier: HCPeerVerifying {
            func verify(_ peer: HCPeerEvidence, configuration: HCLaunchConfiguration) async throws -> HCVerifiedPeer { throw HCUnavailableReason.foreignSession }
            func validateOwnedState(_ configuration: HCLaunchConfiguration, coreID: String) async throws {}
        }
        let adoptedShard0 = HCLaunchConfiguration(
            executableURL: configuration.executableURL, session: "c11h", socketURL: tmp.appendingPathComponent("c11h.sock"),
            stateDirectory: tmp, intentDirectory: tmp, environment: ["HC_SESSION": "c11h"], pin: pin)
        let links = HCManagedSession(configuration: configuration, connections: NoCore(), verifier: NoVerifier(), launcher: NoLaunch(),
                                     intents: HCCreationIntentStore(directory: tmp.appendingPathComponent("intents")),
                                     prepareAttachment: { _, _, _, display in display }, startLog: HCCoreStartLog { _ in })
        let composition = HCBackendComposition()
        composition.composeLinksForTesting(configuration: adoptedShard0, links: links)
        let model = MachineSetupModel()
        model.composition = composition
        var chosen: [String] = []
        model.makeFlow = { [unowned self] picked in
            chosen.append(picked.session)
            return HCMachineSetupFlow(configuration: picked, resources: resources, runner: FakeRunner(probe: mac, verifyStates: ["connected"]),
                                      localHome: tmp, verifyCore: { nil }, verifyAttempts: 3, verifyInterval: 0, sleep: { _ in },
                                      audit: audit, origin: "settings")
        }
        model.start(host: "me@studio.local", name: "studio")
        XCTAssertEqual(chosen, [configuration.session], "the links session's configuration, never c11h's shard 0")
        for _ in 0..<300 where model.running { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.result?.name, "studio", model.failure ?? "")
    }

    /// While this app runs c11h's adopted sessions, a new link lands in c11's
    /// own session (the links session `L`, exactly the converged shard 0),
    /// never `c11h`: the far scripts refuse c11h's session, and c11h's state
    /// folder there belongs to a core c11 never checked. Every far command,
    /// the via and `hc machine add` name `c11`.
    func testWhileAdoptedAMachineIsLinkedInC11sOwnSessionNeverC11hs() throws {
        let home = URL(fileURLWithPath: "/Users/tester")
        let adopted = C11AdoptionRecord(owner: "com.stage11.c11")
        let members = try HCBackendComposition.memberConfigurations(home: home, tag: nil, inherited: [:], namespace: adopted)
        XCTAssertEqual(members.first { $0.0 == 0 }?.1.session, "c11h", "this Mac's terminals stay in the adopted pool")
        // Opus on #382 (Blocking 2): the one choice `c11 machine link` and the pool's links member both make.
        let links = try XCTUnwrap(try HCLaunchPolicy.linksConfiguration(home: home, tag: nil, inherited: [:], namespace: adopted))
        XCTAssertEqual(members.first { $0.0 == HCShardID.links.index }?.1.socketURL, links.socketURL,
                       "the pool composes the session c11 machine link links in")
        XCTAssertNil(try HCLaunchPolicy.linksConfiguration(home: home, tag: nil, inherited: [:], namespace: nil),
                     "not adopted: no links session; shard 0 is c11's own")
        let converged = try XCTUnwrap(try HCBackendComposition.memberConfigurations(home: home, tag: nil, inherited: [:],
                                                                                    namespace: nil).first { $0.0 == 0 }?.1)
        XCTAssertEqual(links.session, "c11")
        XCTAssertEqual(links.socketURL.path, "/Users/tester/.local/share/c11/run/c11.sock")
        XCTAssertEqual(links.stateDirectory.path, "/Users/tester/.local/state/herdr-core/c11", "no folder shared with c11h's core")
        XCTAssertEqual(links.socketURL, converged.socketURL, "the converged shard 0, so the link needs no carrying")
        XCTAssertEqual(links.acceptedServing.map(\.executableURL), converged.acceptedServing.map(\.executableURL),
                       "it trusts only this build's hc and its own retained helpers")
        XCTAssertFalse(try HCBackendComposition.memberConfigurations(home: home, tag: nil, inherited: [:], namespace: nil)
                        .contains { $0.0 == HCShardID.links.index }, "no adoption record, no links session")
        // Opus on #382 (NB6): an adoption record naming c11's own base and root
        // would put the links session on an adopted member's socket: no `L`.
        var own = C11AdoptionRecord(owner: "com.stage11.c11")
        own.base = "c11"
        own.root = ".local/share/c11"
        XCTAssertFalse(try HCBackendComposition.memberConfigurations(home: home, tag: nil, inherited: [:], namespace: own)
                        .contains { $0.0 == HCShardID.links.index }, "never two managed sessions on one socket")
        let taggedRecord = C11AdoptionRecord(owner: "com.stage11.c11.debug.orch15")
        let tagged = try HCBackendComposition.memberConfigurations(home: home, tag: "orch15", inherited: [:], namespace: taggedRecord)
        XCTAssertEqual(tagged.first { $0.0 == HCShardID.links.index }?.1.session, "c11-orch15")
        XCTAssertEqual(try HCLaunchPolicy.linksConfiguration(home: home, tag: "orch15", inherited: [:], namespace: taggedRecord)?.session,
                       "c11-orch15")
        configuration = HCLaunchConfiguration(
            executableURL: tmp.appendingPathComponent("herdr-core"), session: links.session,
            socketURL: tmp.appendingPathComponent("c11.sock"), stateDirectory: tmp, intentDirectory: tmp,
            environment: ["HC_SESSION": links.session, "HC_SOCKET": tmp.appendingPathComponent("c11.sock").path], pin: pin)
        let runner = FakeRunner(probe: mac, verifyStates: ["connected"])
        let outcome = flow(runner).run(HCMachineSetupRequest(host: "me@studio.local", name: "studio")) { _ in }
        guard case .success = outcome else { return XCTFail("\(outcome)") }
        var sessions: [String] = []
        for call in runner.calls {
            let text = call.argv.joined(separator: " ")
            XCTAssertFalse(text.contains("c11h"), "nothing names c11h's session or folders: \(text)")
            var rest = Substring(text)
            while let range = rest.range(of: "--session ") {
                rest = rest[range.upperBound...]
                sessions.append(String(rest.prefix { !$0.isWhitespace }))
            }
        }
        XCTAssertEqual(Set(sessions), ["c11"])
        XCTAssertGreaterThanOrEqual(sessions.count, 4, "secure, relay, the via and hc machine add: \(sessions)")
        let render = runner.calls.first { $0.argv.contains("render") }
        XCTAssertEqual(render.map { value(after: "--socket", in: $0.argv) }, "/Users/me/.local/share/c11/run/c11.sock")
    }

    /// C11H-391: Settings reads the links session's machine list only once it
    /// lists a machine, since `hc machine ls` starts a core for the session it
    /// names: opening Settings while adopted starts no idle core for c11.
    func testSettingsReadsTheLinksSessionOnlyOnceItListsAMachine() throws {
        let members = try HCBackendComposition.memberConfigurations(home: URL(fileURLWithPath: "/Users/tester"), tag: nil,
                                                                    inherited: [:], namespace: C11AdoptionRecord(owner: "com.stage11.c11"))
        let links = try XCTUnwrap(members.first { $0.0 == HCShardID.links.index }?.1)
        let primary = try XCTUnwrap(members.first { $0.0 == 0 }?.1)
        XCTAssertEqual(MachineHCStatus.reads(links: links, primary: primary) { _ in false }.map(\.session), ["c11h"],
                       "an unlinked links session is never asked, so nothing starts its core")
        XCTAssertEqual(MachineHCStatus.reads(links: links, primary: primary) { $0 == links.stateDirectory }.map(\.session),
                       ["c11", "c11h"], "once it lists a machine it is read, c11's own first")
        XCTAssertEqual(MachineHCStatus.reads(links: nil, primary: primary) { _ in true }.map(\.session), ["c11h"])
        let state = tmp.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        XCTAssertFalse(HCBackendComposition.listsMachines(stateDirectory: state), "no machines.json")
        try Data("[]".utf8).write(to: state.appendingPathComponent("machines.json"))
        XCTAssertFalse(HCBackendComposition.listsMachines(stateDirectory: state), "an empty list")
        try Data(#"[{"name":"far","session":"c11"}]"#.utf8).write(to: state.appendingPathComponent("machines.json"))
        XCTAssertTrue(HCBackendComposition.listsMachines(stateDirectory: state))
    }

    /// C11H-391: the far end keeps refusing c11h's session (a link always
    /// lands in c11's own), while the links session's name passes the same check.
    func testTheFarLinkScriptStillRefusesC11hsSession() throws {
        let script = try bundledLinkScript()
        func secure(_ session: String) -> HCMachineSetupOutput {
            HCMachineSetupProcessRunner().run(["/bin/sh", script.path, "secure", "--session", session,
                                               "--socket", tmp.appendingPathComponent("x.sock").path,
                                               "--hc", tmp.appendingPathComponent("nohc").path,
                                               "--sha", String(repeating: "b", count: 64)],
                                              stdin: nil, environment: ["PATH": "/usr/bin:/bin", "HOME": tmp.path], timeout: 20)
        }
        let refused = secure("c11h")  // c11-2.0:legacy
        XCTAssertEqual(refused.status, 2)
        XCTAssertTrue(refused.stderr.contains("bad session: c11h"), refused.stderr)  // c11-2.0:legacy
        XCTAssertFalse(secure("c11-orch15").stderr.contains("bad session"), "the links session's name is c11's own")
    }

    // MARK: Helpers

    private let mac = "os=Darwin\narch=arm64\nhome=/Users/me\nuser=me\nclt=yes\ntar=yes\n"

    private func flow(_ runner: FakeRunner, core: String? = nil) -> HCMachineSetupFlow {
        HCMachineSetupFlow(configuration: configuration, resources: resources, runner: runner, localHome: tmp,
                           verifyCore: { core }, verifyAttempts: 3, verifyInterval: 0, sleep: { _ in },
                           audit: audit, origin: "settings")
    }

    /// One log for the whole test: `flush()` waits on this instance's own queue.
    private lazy var audit = C11AuditLog(directory: tmp.appendingPathComponent("audit", isDirectory: true))

    private func auditRecords() -> [C11AuditRecord] {
        audit.flush()
        return audit.read()
    }

    private func sha256Hex(_ data: Data) -> String {
        let output = HCMachineSetupProcessRunner().run(["/usr/bin/shasum", "-a", "256"], stdin: {
            let url = tmp.appendingPathComponent("hash-input-\(UUID().uuidString)")
            try? data.write(to: url)
            return url
        }(), environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
        return String(output.stdout.prefix(64))
    }

    private func value(after flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return nil }
        return argv[index + 1]
    }
}

private final class UnlinkRunner: HCMachineSetupRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var liveRounds: Int
    private let state: String
    private let sshStatus: Int32

    private let rmFailure: String?

    init(state: String, liveRounds: Int, sshStatus: Int32 = 0, rmFailure: String? = nil) {
        self.state = state
        self.liveRounds = liveRounds
        self.sshStatus = sshStatus
        self.rmFailure = rmFailure
    }

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func run(_ argv: [String], stdin: URL?, environment: [String: String], timeout: TimeInterval) -> HCMachineSetupOutput {
        lock.lock(); defer { lock.unlock() }
        recorded.append(argv)
        if argv.first == HCMachineSetup.sshPath {
            let command = argv.last ?? ""
            let status = command.contains(" stop --session") || sshStatus == 255 ? sshStatus : 0
            return HCMachineSetupOutput(status: status, stdout: "", stderr: "")
        }
        let verb = Array(argv.dropFirst())
        if verb.starts(with: ["machine", "ls"]) {
            return HCMachineSetupOutput(status: 0, stdout: #"{"machines":[{"name":"far","state":"\#(state)","version":"0.1.16"}]}"#, stderr: "")
        }
        if verb.starts(with: ["machine", "rm"]), let rmFailure {
            return HCMachineSetupOutput(status: 1, stdout: "", stderr: rmFailure)
        }
        if verb.first == "ls" {
            let live = liveRounds > 0
            liveRounds -= 1
            return HCMachineSetupOutput(status: 0, stdout: live
                ? #"{"terminals":[{"address":"far/t2","state":"live"}]}"#
                : #"{"terminals":[]}"#, stderr: "")
        }
        return HCMachineSetupOutput(status: 0, stdout: "{}", stderr: "")
    }
}

/// C11H-392: FakeRunner, except that the archive is packed here and the
/// staging writes, the relay install and the cleanup run here for real, under
/// /bin/sh with HOME a scratch folder: the far machine is an empty home.
private final class LoopbackRelayRunner: HCMachineSetupRunner, @unchecked Sendable {
    let fake: FakeRunner
    let home: URL

    init(fake: FakeRunner, home: URL) {
        self.fake = fake
        self.home = home
    }

    func run(_ argv: [String], stdin: URL?, environment: [String: String], timeout: TimeInterval) -> HCMachineSetupOutput {
        if argv.first == "/usr/bin/tar" { return HCMachineSetupProcessRunner().run(argv, stdin: stdin, environment: environment, timeout: timeout) }
        let command = argv.last ?? ""
        let staging = "\"$HOME/.local/share/c11/setup-"
        let local = argv.first == HCMachineSetup.sshPath && command.contains(staging)
            && (command.hasPrefix("umask 077; mkdir -p ") || command.contains("c11-atlas-relay.sh\" install --session ")
                || command.hasPrefix("rm -rf \(staging)"))
        guard local else { return fake.run(argv, stdin: stdin, environment: environment, timeout: timeout) }
        return HCMachineSetupProcessRunner().run(["/bin/sh", "-c", command], stdin: stdin,
                                                 environment: ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                                                 timeout: timeout)
    }
}

private final class FakeRunner: HCMachineSetupRunner, @unchecked Sendable {
    struct Call {
        let argv: [String]
        let stdin: URL?
        let environment: [String: String]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var verifyStates: [String]
    private var added = false
    let probe: String
    let linked: [String]
    let linkedVersion: String
    let linkedTarget: String?
    let verifyVersion: String
    let liveOnMachine: [String]
    let sshFailure: String?
    let installStatus: Int32
    let addStatus: Int32
    let secure: String
    var onRender: () -> Void = {}

    init(probe: String, verifyStates: [String], linked: [String] = [], linkedVersion: String = "0.1.16",
         linkedTarget: String? = nil, verifyVersion: String = "0.1.16", liveOnMachine: [String] = [], sshFailure: String? = nil,
         installStatus: Int32 = 0, addStatus: Int32 = 0, secure: String? = nil) {
        self.secure = secure ?? "sha=\(String(repeating: "b", count: 64))\nserving=none\n"
        self.probe = probe
        self.verifyStates = verifyStates
        self.linked = linked
        self.linkedVersion = linkedVersion
        self.linkedTarget = linkedTarget
        self.verifyVersion = verifyVersion
        self.liveOnMachine = liveOnMachine
        self.sshFailure = sshFailure
        self.installStatus = installStatus
        self.addStatus = addStatus
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func run(_ argv: [String], stdin: URL?, environment: [String: String], timeout: TimeInterval) -> HCMachineSetupOutput {
        lock.lock()
        recorded.append(Call(argv: argv, stdin: stdin, environment: environment))
        lock.unlock()
        if argv.first == HCMachineSetup.sshPath {
            if let sshFailure { return HCMachineSetupOutput(status: 255, stdout: "", stderr: sshFailure) }
            let command = argv.last ?? ""
            if command == "/bin/sh -s" { return HCMachineSetupOutput(status: 0, stdout: probe, stderr: "") }
            if command.contains("c11-atlas-link.sh\" secure --session") { return HCMachineSetupOutput(status: 0, stdout: secure, stderr: "") }
            if command.contains(" install --pin") {
                return HCMachineSetupOutput(status: installStatus, stdout: "installed", stderr: installStatus == 0 ? "" : "in use")
            }
            return HCMachineSetupOutput(status: 0, stdout: "", stderr: "")
        }
        let verb = Array(argv.dropFirst())
        if verb.first == "render" || argv.contains("render") { onRender(); return HCMachineSetupOutput(status: 0, stdout: "", stderr: "") }
        if verb.starts(with: ["machine", "add"]) {
            lock.lock(); added = addStatus == 0; lock.unlock()
            return HCMachineSetupOutput(status: addStatus, stdout: "{}", stderr: addStatus == 0 ? "" : "name_taken")
        }
        if verb.starts(with: ["machine", "ls"]) {
            lock.lock(); defer { lock.unlock() }
            guard added else {
                let target = linkedTarget.map { #","target":"\#($0)""# } ?? ""
                let entries = linked.map { #"{"name":"\#($0)","state":"connected","version":"\#(linkedVersion)"\#(target)}"# }
                return HCMachineSetupOutput(status: 0, stdout: #"{"machines":[\#(entries.joined(separator: ","))]}"#, stderr: "")
            }
            let state = verifyStates.count > 1 ? verifyStates.removeFirst() : (verifyStates.first ?? "unknown")
            return HCMachineSetupOutput(status: 0, stdout: #"{"machines":[{"name":"studio","state":"\#(state)","version":"\#(verifyVersion)"}]}"#, stderr: "")
        }
        if verb.first == "ls" {
            let entries = liveOnMachine.map { #"{"address":"\#($0)","state":"live"}"# }
            return HCMachineSetupOutput(status: 0, stdout: #"{"terminals":[\#(entries.joined(separator: ","))]}"#, stderr: "")
        }
        return HCMachineSetupOutput(status: 0, stdout: "", stderr: "")
    }
}

/// C11H-392: a Linux machine's hc and relay CLI come only from bytes that hash
/// to the pins the signed app names, whichever source supplied them.
final class HCRemoteArtifactTests: XCTestCase {
    private var tmp: URL!
    private let hcBytes = Data("linux hc".utf8)
    private let cliBytes = Data("linux c11".utf8)

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func manifestData(_ entries: [[String: Any]], version: Any = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "artifacts": entries])
    }

    private func entry(_ name: String, _ bytes: Data, url: String? = nil) -> [String: Any] {
        ["platform": "linux-x86_64", "name": name, "version": "0.1.16", "sha256": HCRemoteArtifactStore.sha256(bytes),
         "asset": "\(name)-linux-x86_64", "url": url ?? "https://example.invalid/releases/\(name)-linux-x86_64"]
    }

    private func artifact(_ name: String, _ bytes: Data) throws -> HCRemoteArtifact {
        try XCTUnwrap(HCRemoteArtifactManifest.parse(try manifestData([entry(name, bytes)]))?.artifact(platform: "linux-x86_64", name: name))
    }

    /// A fetch stand-in that serves `bytes` and records each URL it was asked for.
    private final class Served: @unchecked Sendable {
        var asked: [URL] = []
        var timeouts: [TimeInterval] = []
        var bytes: Data
        let dir: URL
        init(_ bytes: Data, dir: URL) { self.bytes = bytes; self.dir = dir }
        func fetch(_ url: URL, _ timeout: TimeInterval) -> Result<URL, HCRemoteArtifactStore.FetchFailure> {
            asked.append(url)
            timeouts.append(timeout)
            let file = dir.appendingPathComponent("download-\(UUID().uuidString)")
            do { try bytes.write(to: file) } catch { return .failure(.init(reason: "write")) }
            return .success(file)
        }
    }

    private func store(_ served: Served, override: URL? = nil) -> HCRemoteArtifactStore {
        HCRemoteArtifactStore(cacheRoot: tmp.appendingPathComponent("cache"), fetch: { served.fetch($0, $1) }, overrideBase: override)
    }

    /// C11H-392 (Astra 3 on #384): the store gives a download thirty minutes in
    /// all, and its session ends a transfer that receives nothing for a minute.
    func testADownloadGetsThirtyMinutesAndAMinuteOfSilence() throws {
        let served = Served(cliBytes, dir: tmp)
        _ = store(served).resolve(try artifact("c11", cliBytes))
        XCTAssertEqual(served.timeouts, [TimeInterval(30 * 60)])
        let session = HCRemoteArtifactStore.sessionConfiguration(timeout: served.timeouts.first ?? 0)
        XCTAssertEqual(session.timeoutIntervalForResource, 30 * 60)
        XCTAssertEqual(session.timeoutIntervalForRequest, 60)
    }

    func testTheManifestIsTakenWholeOrNotAtAll() throws {
        let both = try XCTUnwrap(HCRemoteArtifactManifest.parse(try manifestData([entry("herdr-core", hcBytes), entry("c11", cliBytes)])))
        XCTAssertEqual(both.artifact(platform: "linux-x86_64", name: "c11")?.sha256, HCRemoteArtifactStore.sha256(cliBytes))
        XCTAssertNil(both.artifact(platform: "linux-aarch64", name: "c11"))
        var badSHA = entry("c11", cliBytes); badSHA["sha256"] = "ABC"
        var otherName = entry("c11", cliBytes); otherName["name"] = "bash"
        var badAsset = entry("c11", cliBytes); badAsset["asset"] = "../c11"
        for refused in [[entry("c11", cliBytes, url: "http://example.invalid/c11")], [badSHA], [otherName], [badAsset],
                        [entry("c11", cliBytes), entry("c11", cliBytes)], []] {
            XCTAssertNil(HCRemoteArtifactManifest.parse(try manifestData(refused)), "\(refused)")
        }
        XCTAssertNil(HCRemoteArtifactManifest.parse(try manifestData([entry("c11", cliBytes)], version: 2)))
        for notOne: Any in [true, 1.5, "1"] {
            XCTAssertNil(HCRemoteArtifactManifest.parse(try manifestData([entry("c11", cliBytes)], version: notOne)), "version \(notOne)")
        }
    }

    func testADownloadThatHashesToThePinIsCachedAndUsedWithoutAnotherFetch() throws {
        let served = Served(cliBytes, dir: tmp)
        let c11 = try artifact("c11", cliBytes)
        let first = try store(served).resolve(c11).get()
        XCTAssertEqual(try Data(contentsOf: first), cliBytes)
        XCTAssertEqual(served.asked, [URL(string: c11.url)!])
        XCTAssertEqual(try store(served).resolve(c11).get(), first)
        XCTAssertEqual(served.asked.count, 1, "a cached copy that hashes to the pin needs no fetch")
        let mode = try FileManager.default.attributesOfItem(atPath: first.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }

    func testADownloadThatDoesNotHashToThePinIsRefusedAndNothingIsCached() throws {
        let served = Served(Data("something else".utf8), dir: tmp)
        let c11 = try artifact("c11", cliBytes)
        XCTAssertEqual(store(served).resolve(c11),
                       .failure(.hashMismatch(name: "c11", found: HCRemoteArtifactStore.sha256(Data("something else".utf8)),
                                              expected: c11.sha256)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store(served).cachedURL(c11).path))
    }

    func testATamperedCacheIsNeverUsedAndIsReplaced() throws {
        let served = Served(cliBytes, dir: tmp)
        let c11 = try artifact("c11", cliBytes)
        let cached = try store(served).resolve(c11).get()
        try Data("tampered".utf8).write(to: cached)
        XCTAssertEqual(try Data(contentsOf: try store(served).resolve(c11).get()), cliBytes)
        XCTAssertEqual(served.asked.count, 2)
        // A symlink in the cache's place is not followed either.
        try FileManager.default.removeItem(at: cached)
        let elsewhere = tmp.appendingPathComponent("elsewhere")
        try cliBytes.write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: cached, withDestinationURL: elsewhere)
        XCTAssertEqual(try Data(contentsOf: try store(served).resolve(c11).get()), cliBytes)
        XCTAssertEqual(served.asked.count, 3)
        XCTAssertFalse(HCRemoteArtifactStore.isSymlink(cached))
    }

    /// The local-file source: any regular file in the folder whose bytes hash
    /// to the pin, whatever its name; a symlink to one is not read. A folder
    /// with no match is a named refusal, never a download instead.
    func testAnImportFolderSuppliesAFileByItsHashAndNeverFollowsASymlink() throws {
        let served = Served(hcBytes, dir: tmp)
        let hc = try artifact("herdr-core", hcBytes)
        let folder = tmp.appendingPathComponent("import")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = tmp.appendingPathComponent("real-hc")
        try hcBytes.write(to: real)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("herdr-core"), withDestinationURL: real)
        try Data("not it".utf8).write(to: folder.appendingPathComponent("c11"))
        XCTAssertEqual(store(served).resolve(hc, importDirectory: folder),
                       .failure(.notInFolder(name: "herdr-core", folder: folder.path)),
                       "the symlink was skipped and no file in the folder is the pin")
        XCTAssertEqual(served.asked, [], "a named folder is the only source: nothing was downloaded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store(served).cachedURL(hc).path))
        try hcBytes.write(to: folder.appendingPathComponent("hc-from-the-release"))
        let before = served.asked.count
        XCTAssertEqual(try Data(contentsOf: try store(served).resolve(hc, importDirectory: folder).get()), hcBytes)
        XCTAssertEqual(served.asked.count, before, "an imported file needs no fetch")
    }

    /// The setup flow names the folder when it holds no match.
    func testAnImportFolderWithNoMatchIsANamedSetupFailure() throws {
        let manifest = try XCTUnwrap(HCRemoteArtifactManifest.parse(try manifestData([entry("herdr-core", hcBytes), entry("c11", cliBytes)])))
        let folder = tmp.appendingPathComponent("empty-import")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let served = Served(hcBytes, dir: tmp)
        let files = HCMachineSetupLinuxFiles(manifest: manifest, store: store(served), importDirectory: folder)
        let outcome = files.resolve(platform: "linux-x86_64", pinVersion: "0.1.16", host: "far").map(\.sha256)
        XCTAssertEqual(outcome, .failure(.linuxFileNotInFolder(name: "herdr-core", folder: folder.path)))
        XCTAssertEqual(HCMachineSetupFailure.linuxFileNotInFolder(name: "herdr-core", folder: folder.path).code, "remote_artifact_not_in_folder")
        XCTAssertEqual(served.asked, [])
    }

    func testTheQABaseReplacesOnlyWhereTheAssetIsFetchedFrom() throws {
        let served = Served(cliBytes, dir: tmp)
        let c11 = try artifact("c11", cliBytes)
        let base = try XCTUnwrap(HCRemoteArtifactStore.overrideBase([HCRemoteArtifactStore.overrideVariable: "http://127.0.0.1:8392/assets"]))
        _ = try store(served, override: base).resolve(c11).get()
        XCTAssertEqual(served.asked, [URL(string: "http://127.0.0.1:8392/assets/c11-linux-x86_64")!])
        XCTAssertNil(HCRemoteArtifactStore.overrideBase([HCRemoteArtifactStore.overrideVariable: "file:///tmp/assets"]))
        XCTAssertNil(HCRemoteArtifactStore.overrideBase([:]))
    }
}

/// C11H-392: the real downloader, with a stand-in for the network. A redirect
/// is followed only to https; one to http or `file:` is refused by name and
/// keeps no file, whatever the stand-in would have served there.
final class HCRemoteArtifactDownloadTests: XCTestCase {
    final class Network: URLProtocol {
        static let served = Data("pinned bytes".utf8)
        static let routes: [String: (status: Int, location: String?)] = [
            "https://a.test/plain": (200, nil),
            "https://a.test/to-https": (302, "https://b.test/plain"),
            "https://b.test/plain": (200, nil),
            "https://a.test/to-http": (302, "http://b.test/plain"),
            "http://b.test/plain": (200, nil),
            "https://a.test/to-file": (302, "file:///tmp/c11-artifact-test"),
            "file:///tmp/c11-artifact-test": (200, nil),
        ]
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, let route = Self.routes[url.absoluteString] else {
                client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return
            }
            if let location = route.location, let next = URL(string: location),
               let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: ["Location": location]) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: response)
                // A redirect the session follows ends this load itself (stopLoading,
                // then a new load of `next`): a cancel sent here could reach the task
                // before that decision under load and fail a followed redirect. One it
                // refuses needs this load ended; the refusal is queued on the session's
                // serial delegate queue ahead of the completion that cancel causes.
                if next.scheme != "https" {
                    client?.urlProtocol(self, didFailWithError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                }
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.served)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private let fetch = HCRemoteArtifactStore.downloader(protocolClasses: [Network.self])

    private func get(_ url: String) -> Result<URL, HCRemoteArtifactStore.FetchFailure> {
        fetch(URL(string: url)!, 10)
    }

    func testAPlainDownloadAndAnHTTPSRedirectAreFollowed() throws {
        for url in ["https://a.test/plain", "https://a.test/to-https"] {
            let file = try get(url).get()
            defer { try? FileManager.default.removeItem(at: file) }
            XCTAssertEqual(try Data(contentsOf: file), Network.served, url)
        }
    }

    func testARedirectToHTTPIsRefusedByName() {
        guard case .failure(let failure) = get("https://a.test/to-http") else { return XCTFail("an http redirect was followed") }
        XCTAssertEqual(failure.reason, "a redirect to http was refused")
    }

    func testARedirectToAFileURLIsRefusedByName() {
        guard case .failure(let failure) = get("https://a.test/to-file") else { return XCTFail("a file: redirect was followed") }
        XCTAssertEqual(failure.reason, "a redirect to file was refused")
    }

    // MARK: C11H-392 (Astra 3 on #384): a download that ends any way but well keeps no file

    /// stall.test answers and then sends nothing; broken.test drops the line
    /// mid-body; error.test answers 500; any other host serves the bytes.
    final class Trouble: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url else { return }
            let status = url.host == "error.test" ? 500 : 200
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            switch url.host {
            case "stall.test": return
            case "broken.test":
                client?.urlProtocol(self, didLoad: Data("half".utf8))
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            default:
                client?.urlProtocol(self, didLoad: Network.served)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() {}
    }

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private var keptFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("c11-artifact-") }
    }

    func testAStalledTransferFailsAtItsDeadlineAndKeepsNoFile() {
        let fetch = HCRemoteArtifactStore.downloader(protocolClasses: [Trouble.self], temporaryDirectory: folder, waitBudget: { _ in 0.5 })
        let start = Date()
        guard case .failure(let failure) = fetch(URL(string: "https://stall.test/c11")!, 30) else { return XCTFail("a stalled transfer succeeded") }
        XCTAssertEqual(failure.reason, "timed out")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the caller waits out its budget, not the transfer's")
        XCTAssertEqual(keptFiles, [])
    }

    func testAnHTTPErrorAndABrokenBodyKeepNoFile() {
        let fetch = HCRemoteArtifactStore.downloader(protocolClasses: [Trouble.self], temporaryDirectory: folder)
        guard case .failure(let http) = fetch(URL(string: "https://error.test/c11")!, 10) else { return XCTFail("an HTTP 500 was used") }
        XCTAssertEqual(http.reason, "HTTP 500")
        guard case .failure = fetch(URL(string: "https://broken.test/c11")!, 10) else { return XCTFail("a broken body was used") }
        XCTAssertEqual(keptFiles, [])
    }

    /// A completion that arrives as the caller gives up keeps nothing: one whose
    /// handler has only just started then, and one already keeping its file.
    func testACompletionThatOverlapsTheDeadlineKeepsNoFile() {
        for phase in [HCRemoteArtifactStore.DownloadPhase.completed, .keeping] {
            let fetch = HCRemoteArtifactStore.downloader(protocolClasses: [Trouble.self], temporaryDirectory: folder,
                                                         waitBudget: { _ in 0.3 },
                                                         hook: { if $0 == phase { Thread.sleep(forTimeInterval: 0.8) } })
            guard case .failure(let failure) = fetch(URL(string: "https://plain.test/c11")!, 30) else {
                XCTFail("\(phase): a completion after the deadline was used"); continue
            }
            XCTAssertEqual(failure.reason, "timed out", "\(phase)")
            Thread.sleep(forTimeInterval: 1.0) // the held handler finishes
            XCTAssertEqual(keptFiles, [], "\(phase): a completion after the deadline kept its file")
        }
    }
}
