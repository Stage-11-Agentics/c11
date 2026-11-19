import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-16 seam with ticket 12: a terminal launched on another machine
/// carries that machine's relay env, and nothing from this Mac's paths.
final class C11RelayRemoteEnvTests: XCTestCase {
    private func manifest(_ session: String = "c11") throws -> C11Relay.Manifest {
        try XCTUnwrap(C11Relay.Manifest(data: try JSONSerialization.data(withJSONObject: [
            "relay_protocol": 1, "session": session, "home": "/Users/a",
            "bin": "/Users/a/.local/share/c11/relay/\(session)/bin", "zdotdir": "/Users/a/.local/share/c11/relay/\(session)/zdotdir",
            "sentinel": "/Users/a/.local/share/c11/relay/\(session)/no-socket", "cli_sha256": String(repeating: "c", count: 64)]),
            session: session))
    }

    func testRemotePlacementKeepsTheSelectedShardsRelayAlongsidePanelConfig() throws {
        let machine = "test-paired-shards"
        for session in ["c11-s1", "c11-s2"] {
            C11RelayEnvironment.shared.set(try manifest(session), for: machine, session: session)
        }
        defer {
            for session in ["c11-s1", "c11-s2"] {
                C11RelayEnvironment.shared.set(nil, for: machine, session: session)
            }
        }
        for session in ["c11-s1", "c11-s2"] {
            let spec = HCPanelLaunchSpec.placed(argv: ["/local/shell"], localCwd: nil,
                environment: ["XDG_CONFIG_HOME": "/local/app/config"], initialInput: nil,
                remote: HCRemoteTarget(machine: machine),
                panelEnvironment: ["XDG_CONFIG_HOME": "/remote/panel/config"], session: session)
            XCTAssertEqual(spec.environment["ZDOTDIR"], "/Users/a/.local/share/c11/relay/\(session)/zdotdir")
            XCTAssertEqual(spec.environment["C11_SOCKET_PATH"], "/Users/a/.local/share/c11/relay/\(session)/no-socket")
            XCTAssertEqual(spec.environment["XDG_CONFIG_HOME"], "/remote/panel/config")
            XCTAssertEqual(spec.argv, ["/bin/sh", "-c", HCMachineTarget.remoteLaunchLine])
        }
    }

    /// C11H-86: a remote terminal created while its machine has no relay
    /// environment says so in the debug log the operator and the kit read.
    func testARemoteTerminalWithNoRelayLogsNoManifestAndOneWithARelayDoesNot() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("c11-86-\(UUID().uuidString).log").path
        let previous = getenv("C11_DEBUG_LOG").map { String(cString: $0) }
        setenv("C11_DEBUG_LOG", log, 1)
        C11RelayEnvironment.shared.set(nil, for: "studio")
        defer {
            if let previous { setenv("C11_DEBUG_LOG", previous, 1) } else { unsetenv("C11_DEBUG_LOG") }
            C11RelayEnvironment.shared.set(nil, for: "studio")
            try? FileManager.default.removeItem(atPath: log)
        }
        func lines() -> [String] {
            ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
                .filter { $0.hasPrefix("hc.relay no_manifest") }
        }
        let bare = HCPanelLaunchSpec.placed(argv: ["/bin/zsh"], localCwd: nil, environment: ["C11_PANEL_ID": "p"],
                                            initialInput: nil, remote: HCRemoteTarget(machine: "studio"))
        XCTAssertNil(bare.environment["ZDOTDIR"])
        XCTAssertEqual(lines(), ["hc.relay no_manifest machine=studio"])

        C11RelayEnvironment.shared.set(try manifest(), for: "studio")
        let relayed = HCPanelLaunchSpec.placed(argv: ["/bin/zsh"], localCwd: nil, environment: ["C11_PANEL_ID": "p"],
                                               initialInput: nil, remote: HCRemoteTarget(machine: "studio"))
        XCTAssertEqual(relayed.environment["ZDOTDIR"], "/Users/a/.local/share/c11/relay/c11/zdotdir")
        XCTAssertEqual(lines(), ["hc.relay no_manifest machine=studio"], "a terminal with the relay logs nothing more")

        _ = HCPanelLaunchSpec.placed(argv: ["/bin/zsh"], localCwd: "/tmp", environment: [:], initialInput: nil, remote: nil)
        XCTAssertEqual(lines().count, 1, "a local terminal never logs no_manifest")
    }

    func testRemoteLaunchCarriesTheRelayEnvAndReplacesLocalSocketPaths() throws {
        let relay = C11RelayEnvironment()
        relay.set(try manifest(), for: "studio")
        let local = ["C11_PANEL_ID": "p", "PATH": "/Applications/c11.app/bin:/usr/bin", "ZDOTDIR": "/Applications/c11.app/zsh",
                     "C11_SOCKET_PATH": "/tmp/c11.sock", "CMUX_SOCKET_PATH": "/tmp/c11.sock", "LANG": "en_US.UTF-8"]
        let env = HCMachineTarget.remoteEnvironment(local, relay: relay.environment(for: "studio"))
        XCTAssertEqual(env["ZDOTDIR"], "/Users/a/.local/share/c11/relay/c11/zdotdir")
        XCTAssertEqual(env["C11_SOCKET_PATH"], "/Users/a/.local/share/c11/relay/c11/no-socket")
        XCTAssertEqual(env["CMUX_SOCKET_PATH"], "/Users/a/.local/share/c11/relay/c11/no-socket")
        XCTAssertEqual(env["C11_PANEL_ID"], "p")
        XCTAssertNil(env["PATH"], "this Mac's PATH never reaches the other machine")
    }

    func testWithoutAnInstalledRelayNothingIsAdded() {
        let local = ["C11_PANEL_ID": "p", "ZDOTDIR": "/Applications/c11.app/zsh", "C11_SOCKET_PATH": "/tmp/c11.sock"]
        let env = HCMachineTarget.remoteEnvironment(local, relay: C11RelayEnvironment().environment(for: "vps"))
        XCTAssertEqual(env, ["C11_PANEL_ID": "p"])
    }
}
