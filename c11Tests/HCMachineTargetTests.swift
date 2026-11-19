import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// Ticket 12 (C11H-14): `--on <machine>`, placement and the remote launch spec.

private let ready = HCRevision(connectionGeneration: 1, sequence: 4)

private func inventory(_ machines: [String: HCMachineAvailability], ready isReady: Bool = true) -> HCInventorySnapshot {
    HCInventorySnapshot(readiness: isReady ? .ready(ready) : .pending(.inventoryPending), revision: ready, machines: machines)
}

private func atlasRecord(cwd: String? = "/Users/demo", foreground: String? = nil) -> HCTerminalRecord {
    HCTerminalRecord(key: HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t7"), state: .running,
        machineName: "studio", machineAvailability: .connected, pid: 77, cwd: cwd,
        foreground: foreground.map { HCForeground(pid: 78, name: "zsh", cwd: $0) })
}

final class HCMachineTargetTests: XCTestCase {
    /// Pathfinder: a remote terminal with no folder named starts in the
    /// workspace root's home-relative path there, else at that machine's home.
    func testStartDirectoryHintMapsOnlyPathsUnderTheLocalHome() {
        let hint = { HCMachineTarget.startDirectoryHint(localRoot: $0, localHome: "/Users/demo") }
        XCTAssertEqual(hint("/Users/demo/Projects/Stage11/code/platform"), "Projects/Stage11/code/platform")
        XCTAssertEqual(hint("/Users/demo/Projects/x/"), "Projects/x")
        XCTAssertNil(hint("/Users/demo"))
        XCTAssertNil(hint("/Users/demonstration/Projects"))
        XCTAssertNil(hint("/opt/work"))
        XCTAssertNil(hint(nil))
        XCTAssertNil(HCMachineTarget.startDirectoryHint(localRoot: "/x/y", localHome: "/"))
        XCTAssertTrue(HCMachineTarget.portableKeys.contains(HCMachineTarget.startDirectoryVariable))
    }

    /// The launch line tries the hinted folder and falls back to home, and the
    /// variable never reaches the shell.
    func testRemoteLaunchLineStartsInTheHintedFolderOrHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("c11-hint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Projects/x"), withIntermediateDirectories: true)
        for (hint, expected) in [("Projects/x", "Projects/x"), ("Projects/missing", ""), ("", "")] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", HCMachineTarget.remoteLaunchLine]
            var env = ["HOME": home.path, "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"]
            if !hint.isEmpty { env["C11_START_DIR"] = hint }
            process.environment = env
            process.currentDirectoryURL = home
            let input = Pipe(), output = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForWriting.write(Data("pwd -P; echo \"HINT=${C11_START_DIR-unset}\"\nexit\n".utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let target = expected.isEmpty ? home.path : home.appendingPathComponent(expected).path
            let resolved = realpath(target, nil)
            let want = resolved.map { String(cString: $0) } ?? target
            free(resolved)
            XCTAssertTrue(printed.contains(want + "\n") && printed.contains("HINT=unset"), "hint=\(hint): \(printed)")
        }
    }

    /// C11H-392: a bash shell with the relay kit's startup file starts as
    /// `bash --rcfile <file> -i`; any other shell, or no readable file, starts
    /// as a login shell, and the variable never reaches it.
    func testRemoteLaunchLineGivesBashTheRelayRcfileAndOtherShellsALogin() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c11-bashrc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rc = dir.appendingPathComponent("rc")
        try Data("# kit\n".utf8).write(to: rc)
        // Stand-in shells: each prints its own name, its arguments and whether the variable reached it.
        for name in ["bash", "zsh"] {
            let shell = dir.appendingPathComponent(name)
            try Data("#!/bin/sh\nprintf '%s|%s|%s' \"${0##*/}\" \"$*\" \"${C11_RELAY_BASHRC-unset}\"\n".utf8).write(to: shell)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        }
        func launch(shell: String, bashrc: String?) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", HCMachineTarget.remoteLaunchLine]
            var env = ["HOME": dir.path, "PATH": "/usr/bin:/bin", "SHELL": dir.appendingPathComponent(shell).path]
            if let bashrc { env["C11_RELAY_BASHRC"] = bashrc }
            process.environment = env
            let output = Pipe()
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        XCTAssertEqual(try launch(shell: "bash", bashrc: rc.path), "bash|--rcfile \(rc.path) -i|\(rc.path)")
        XCTAssertEqual(try launch(shell: "bash", bashrc: nil), "bash|-l|unset")
        XCTAssertEqual(try launch(shell: "bash", bashrc: dir.appendingPathComponent("missing").path), "bash|-l|unset")
        XCTAssertEqual(try launch(shell: "zsh", bashrc: rc.path), "zsh|-l|unset")
    }

    func testOnResolvesOnlyConnectedMachinesHCKnows() {
        let snapshot = inventory(["studio": .connected, "prime": .disconnected])
        XCTAssertEqual(HCMachineTarget.resolve(requested: "studio", snapshot: snapshot), .success("studio"))
        XCTAssertEqual(HCMachineTarget.resolve(requested: " Studio ", snapshot: snapshot), .success("studio"))
        XCTAssertEqual(HCMachineTarget.resolve(requested: "prime", snapshot: snapshot), .failure(.disconnected("prime")))
        XCTAssertEqual(HCMachineTarget.resolve(requested: "zeus", snapshot: snapshot),
                       .failure(.unknown(requested: "zeus", known: ["prime", "studio"])))
        XCTAssertEqual(HCMachineTarget.resolve(requested: "local", snapshot: nil), .success(nil))
        XCTAssertEqual(HCMachineTarget.resolve(requested: "HERE", snapshot: nil), .success(nil))
    }

    /// C11H-274: a machine whose stored link c11 won't use is refused before any
    /// panel exists, with the action to take, even while hc reports it connected.
    func testOnRefusesAMachineWhoseLinkIsUnusable() {
        let snapshot = inventory(["studio": .connected, "prime": .disconnected])
        let refused = HCMachineTarget.resolve(requested: " Studio ", snapshot: snapshot, unusable: ["studio", "prime"])
        XCTAssertEqual(refused, .failure(.linkUnusable("studio")))
        XCTAssertEqual(HCMachineTarget.resolve(requested: "prime", snapshot: snapshot, unusable: ["prime"]),
                       .failure(.linkUnusable("prime")), "the action to take beats 'not connected'")
        XCTAssertEqual(HCMachineTarget.resolve(requested: "studio", snapshot: snapshot, unusable: ["prime"]), .success("studio"))
        XCTAssertEqual(HCMachineTarget.resolve(requested: "local", snapshot: snapshot, unusable: ["studio"]), .success(nil))
        guard case .failure(let error) = refused else { return XCTFail("\(refused)") }
        XCTAssertEqual(error.code, "machine_link_unusable")
        XCTAssertTrue(error.message.contains("studio") && error.message.contains("Update or Remove the machine in Settings > Herder Topography"),
                      error.message)
    }

    /// C11H-391 (Astra on #380, blocking 1): the same name usable in one
    /// session and unusable in another resolves, because the creation goes to
    /// the usable link; it is refused only when the link a creation would use
    /// is unusable. With c11's own links session, its usable link wins.
    func testOnRefusesOnlyWhenTheLinkACreationWouldUseIsUnusable() {
        func pool(_ c11h: HCMachineAvailability?, _ links: HCMachineAvailability?, pool1: HCMachineAvailability? = nil) -> HCInventorySnapshot {
            var sessions: [HCSessionMachines] = []
            if let c11h { sessions.append(HCSessionMachines(shard: .legacy, session: "c11h", machines: ["far": c11h])) }
            if let pool1 { sessions.append(HCSessionMachines(shard: HCShardID(index: 1), session: "c11h-s1", machines: ["far": pool1])) }
            if let links { sessions.append(HCSessionMachines(shard: .links, session: "c11", machines: ["far": links])) }
            return HCInventorySnapshot(readiness: .ready(ready), revision: ready, machines: ["far": c11h ?? links ?? pool1 ?? .connected],
                                       sessionMachines: sessions)
        }
        let oldUnusable: [String: Set<String>] = ["c11h": ["far"]]
        XCTAssertEqual(HCMachineTarget.resolve(requested: "far", snapshot: pool(.connected, .connected), unusableBySession: oldUnusable),
                       .success("far"), "c11's own usable link of the name wins over c11h's")
        XCTAssertEqual(HCMachineTarget.resolve(requested: "Far", snapshot: pool(.connected, .connected), unusableBySession: ["c11": ["far"]]),
                       .success("far"), "and c11h's usable one wins over c11's unusable one")
        XCTAssertEqual(HCMachineTarget.resolve(requested: "far", snapshot: pool(.connected, .connected, pool1: .connected),
                                               unusableBySession: ["c11h": ["far"], "c11": ["far"]]),
                       .success("far"), "any session's usable link of the name")
        XCTAssertEqual(HCMachineTarget.resolve(requested: "far", snapshot: pool(.connected, nil), unusableBySession: oldUnusable),
                       .failure(.linkUnusable("far")), "only c11h links it: refused up front")
        XCTAssertEqual(HCMachineTarget.resolve(requested: "far", snapshot: pool(.connected, .connected),
                                               unusableBySession: ["c11h": ["far"], "c11": ["far"]]),
                       .failure(.linkUnusable("far")), "no session links it usably")
        XCTAssertEqual(HCMachineTarget.resolve(requested: "far", snapshot: pool(.connected, .disconnected), unusableBySession: oldUnusable),
                       .failure(.disconnected("far")), "the usable link is the one a creation uses, even while its line is down")
        XCTAssertEqual(HCMachineTarget.resolve(requested: "far", snapshot: pool(.connected, .connected), unusableBySession: [:]),
                       .success("far"))
    }

    /// C11H-396 (Opus NB5 on #382): for the seconds after launch before the
    /// links session's first report, a name its `machines.json` lists is not
    /// ready yet (hc_unavailable): never refused for c11h's older link, and
    /// never unknown. Its first report ends that; the routed answer stands.
    func testOnSaysNotReadyForANameTheStartingLinksSessionLists() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("c11h-396-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try Data(#"[{"name":"far","target":"user@far"},{"name":"cube","target":"cube"},{"target":"nameless"}]"#.utf8)
            .write(to: state.appendingPathComponent("machines.json"))
        let listed = HCBackendComposition.listedMachineNames(stateDirectory: state)
        XCTAssertEqual(listed, ["far", "cube"], "hc's own machine list, by name")

        let linked = HCLinkedMachines()
        linked.setUnusable(bySession: ["c11h": ["far"]])
        linked.setStartingLinks(listed)
        let c11hOnly = HCInventorySnapshot(readiness: .ready(ready), revision: ready, machines: ["far": .connected],
            sessionMachines: [HCSessionMachines(shard: .legacy, session: "c11h", machines: ["far": .connected])])
        XCTAssertEqual(HCMachineTarget.resolve(requested: "far", snapshot: c11hOnly, linked: linked), .failure(.unavailable),
                       "the starting links session may link far usably: not ready, not c11h's unusable link")
        XCTAssertEqual(HCMachineTarget.resolve(requested: "Cube", snapshot: c11hOnly, linked: linked), .failure(.unavailable),
                       "a name only the starting links session lists is coming, not unknown")
        XCTAssertEqual(HCMachineTarget.resolve(requested: "prime", snapshot: c11hOnly, linked: linked),
                       .failure(.unknown(requested: "prime", known: ["far"])))

        linked.updateSessions([HCSessionMachines(shard: .legacy, session: "c11h", machines: ["far": .connected]),
                               HCSessionMachines(shard: .links, session: "c11", machines: ["cube": .connected])])
        XCTAssertEqual(linked.startingLinks(), [], "the links session's first report ends its start")
        XCTAssertEqual(HCMachineTarget.resolve(requested: "far", snapshot: c11hOnly, linked: linked), .failure(.linkUnusable("far")),
                       "once it has reported, a name it doesn't link is refused for its own reason")
    }

    /// A pending or absent inventory never guesses; it refuses with hc_unavailable.
    func testOnRefusesWithoutAReadyInventory() {
        XCTAssertEqual(HCMachineTarget.resolve(requested: "studio", snapshot: nil), .failure(.unavailable))
        XCTAssertEqual(HCMachineTarget.resolve(requested: "studio", snapshot: inventory(["studio": .connected], ready: false)),
                       .failure(.unavailable))
    }

    /// Two names differing only by case are ambiguous for a folded match.
    func testCaseFoldingNeverPicksBetweenTwoMachines() {
        let snapshot = inventory(["studio": .connected, "Studio": .connected])
        XCTAssertEqual(HCMachineTarget.resolve(requested: "Studio", snapshot: snapshot), .success("Studio"))
        XCTAssertEqual(HCMachineTarget.resolve(requested: "STUDIO", snapshot: snapshot),
                       .failure(.unknown(requested: "STUDIO", known: ["Studio", "studio"])))
    }

    func testErrorsCarryStableCodes() {
        XCTAssertEqual(HCMachineTargetError.unavailable.code, "hc_unavailable")
        XCTAssertEqual(HCMachineTargetError.unknown(requested: "x", known: []).code, "machine_unknown")
        XCTAssertEqual(HCMachineTargetError.disconnected("x").code, "machine_unreachable")
        XCTAssertEqual(HCMachineTargetError.notTerminal.code, "remote_unsupported")
        XCTAssertTrue(HCMachineTargetError.unknown(requested: "zeus", known: ["studio"]).message.contains("studio"))
    }

    func testConnectedMachinesForMenus() {
        XCTAssertEqual(HCMachineTarget.connectedMachines(inventory(["prime": .disconnected, "studio": .connected, "b": .connected])),
                       ["b", "studio"])
        XCTAssertEqual(HCMachineTarget.connectedMachines(inventory(["studio": .connected], ready: false)), [])
    }

    /// Rows 29 and 43: a split of a Studio panel starts on Studio in the folder
    /// that terminal is in now (foreground cwd, then start cwd, then its own).
    func testSplitInheritsTheMachineAndItsCurrentRemoteFolder() {
        let source = HCRemoteSource(target: HCRemoteTarget(machine: "studio", cwd: "/start"),
                                    record: atlasRecord(cwd: "/Users/demo", foreground: "/tmp/x"))
        XCTAssertEqual(HCMachineTarget.placement(request: .inherit, explicitCwd: nil, source: source),
                       HCRemoteTarget(machine: "studio", cwd: "/tmp/x"))
        let noForeground = HCRemoteSource(target: source.target, record: atlasRecord(cwd: "/Users/demo"))
        XCTAssertEqual(noForeground.currentDirectory, "/Users/demo")
        let noRecord = HCRemoteSource(target: source.target, record: nil)
        XCTAssertEqual(noRecord.currentDirectory, "/start")
        XCTAssertEqual(HCMachineTarget.placement(request: .inherit, explicitCwd: "/srv", source: source),
                       HCRemoteTarget(machine: "studio", cwd: "/srv"))
    }

    /// A local source, or none, keeps every existing creation path local.
    func testInheritFromALocalPanelStaysLocal() {
        XCTAssertNil(HCMachineTarget.placement(request: .inherit, explicitCwd: "/Users/me", source: nil))
        XCTAssertNil(HCMachineTarget.placement(request: .local, explicitCwd: nil,
            source: HCRemoteSource(target: HCRemoteTarget(machine: "studio"), record: nil)))
    }

    /// `--on` names the machine; a folder carries over only from that machine.
    func testExplicitMachineTakesFolderOnlyFromTheSameMachine() {
        let studio = HCRemoteSource(target: HCRemoteTarget(machine: "studio"), record: atlasRecord(foreground: "/tmp/x"))
        XCTAssertEqual(HCMachineTarget.placement(request: .on("studio"), explicitCwd: nil, source: studio),
                       HCRemoteTarget(machine: "studio", cwd: "/tmp/x"))
        XCTAssertEqual(HCMachineTarget.placement(request: .on("prime"), explicitCwd: nil, source: studio),
                       HCRemoteTarget(machine: "prime", cwd: nil))
        XCTAssertEqual(HCMachineTarget.placement(request: .on("studio"), explicitCwd: nil, source: nil),
                       HCRemoteTarget(machine: "studio", cwd: nil))
        XCTAssertEqual(HCMachineTarget.placement(request: .restored(HCRemoteTarget(machine: "studio", cwd: "/a")),
                       explicitCwd: "/ignored", source: nil), HCRemoteTarget(machine: "studio", cwd: "/a"))
    }

    func testDisplayNameRaisesOnlyTheFirstLetter() {
        XCTAssertEqual(HCMachineTarget.displayName("studio"), "Studio")
        XCTAssertEqual(HCMachineTarget.displayName("prime-07"), "Prime-07")
        XCTAssertEqual(HCMachineTarget.displayName(""), "")
    }

    /// T12.2: hc's record says "studio"; the chip reads "Studio", and a down
    /// line reads Reconnecting, never "not kept".
    func testChipShowsAtlasAndReconnectingOnADownLine() {
        let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t3")
        let record = HCTerminalRecord(key: key, state: .running, machineName: "studio", pid: 1)
        XCTAssertEqual(SessionPlacement.make(lifecycle: .live(record), persistence: .persistent, machineName: nil),
                       SessionPlacement(machineName: "Studio", mark: .none, machineKey: "studio"))
        XCTAssertEqual(SessionPlacement.make(lifecycle: .unresolved(HCPanelIdentity(panelID: UUID(), key: key), .connectionLost),
                                             persistence: .persistent, machineName: "studio"),
                       SessionPlacement(machineName: "Studio", mark: .reconnecting, machineKey: "studio"))
    }

    /// A remote launch runs that machine's login shell with only the portable
    /// environment: no path into this Mac reaches Studio.
    func testRemoteLaunchSpecCarriesIdentityButNoLocalPaths() {
        let local: [String: String] = [
            "C11_PANEL_ID": "P", "C11_WORKSPACE_ID": "W", "CMUX_SURFACE_ID": "P", "C11_PANEL_NUM": "12",
            "C11_AGENT_TYPE": "claude-code", "LANG": "en_US.UTF-8", "LC_CTYPE": "UTF-8", "COLORTERM": "truecolor",
            "PATH": "/Applications/c11.app/Contents/Resources/bin:/usr/bin", "ZDOTDIR": "/Applications/c11.app/zsh",
            "TERMINFO": "/Applications/c11.app/terminfo", "C11_SOCKET_PATH": "/Users/me/Library/c11.sock",
            "GHOSTTY_RESOURCES_DIR": "/Applications/c11.app/ghostty", "CMUX_PORT": "9100",
        ]
        let initial = HCInitialInput(operationID: UUID(), payload: Data("claude\n".utf8), submitReturn: false)
        let remote = HCPanelLaunchSpec.placed(argv: ["/bin/zsh", "-l"], localCwd: "/Users/me/proj", environment: local,
                                              initialInput: initial, remote: HCRemoteTarget(machine: "studio", cwd: "/tmp/x"))
        XCTAssertEqual(remote.machine, "studio")
        XCTAssertEqual(remote.argv, ["/bin/sh", "-c", HCMachineTarget.remoteLaunchLine])
        XCTAssertEqual(remote.cwd, "/tmp/x")
        XCTAssertEqual(Set(remote.environment.keys),
                       ["C11_PANEL_ID", "C11_WORKSPACE_ID", "CMUX_SURFACE_ID", "C11_PANEL_NUM", "C11_AGENT_TYPE",
                        "LANG", "LC_CTYPE", "COLORTERM"])
        XCTAssertEqual(remote.initialInput?.operationID, initial.operationID)

        let same = HCPanelLaunchSpec.placed(argv: ["/bin/zsh", "-l"], localCwd: "/Users/me/proj", environment: local,
                                            initialInput: nil, remote: nil)
        XCTAssertNil(same.machine)
        XCTAssertEqual(same.argv, ["/bin/zsh", "-l"])
        XCTAssertEqual(same.cwd, "/Users/me/proj")
        XCTAssertEqual(same.environment, local)
    }

    func testRemoteConfigUsesOnlyExplicitPanelValue() {
        let local = ["XDG_CONFIG_HOME": "/local/app/config", "C11_PANEL_ID": "panel"]
        let target = HCRemoteTarget(machine: "test-no-relay")
        for panelValue in [nil, "/remote/panel/config", ""] as [String?] {
            let panel = panelValue.map { ["XDG_CONFIG_HOME": $0] } ?? [:]
            let spec = HCPanelLaunchSpec.placed(argv: ["/local/shell"], localCwd: "/local", environment: local,
                initialInput: nil, remote: target, panelEnvironment: panel)
            XCTAssertEqual(spec.environment["XDG_CONFIG_HOME"], panelValue)
            XCTAssertEqual(spec.argv, ["/bin/sh", "-c", HCMachineTarget.remoteLaunchLine])
        }
    }

    func testRemoteLaunchExecutesTheFarShellWithPanelConfigOrARealUnset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hc-remote-shell-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A remote shell unrelated to this Mac's zsh, with a space in its
        // path to require quoting. It records the argv and environment seen
        // after the real exec chain, without running hc or any user's rc file.
        let shell = root.appendingPathComponent("far shell")
        try Data(#"""
        #!/bin/sh
        printf '%s\n' "$0" "$#" "$1" "${XDG_CONFIG_HOME-unset}" "$$"
        """#.utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        for panelValue in [nil, "/remote/panel/config", ""] as [String?] {
            let spec = HCPanelLaunchSpec.placed(argv: ["/local/shell"], localCwd: "/local",
                environment: ["SHELL": "/local/shell", "XDG_CONFIG_HOME": "/local/app/config"],
                initialInput: nil, remote: HCRemoteTarget(machine: "test-non-zsh-no-relay"),
                panelEnvironment: panelValue.map { ["XDG_CONFIG_HOME": $0] } ?? [:])
            let params = HCLaunchPolicy.terminalRunParameters(argv: spec.argv, environment: spec.environment)
            let argv = try XCTUnwrap(params["argv"]?.array).compactMap(\.string)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: try XCTUnwrap(argv.first))
            process.arguments = Array(argv.dropFirst())
            process.environment = ["SHELL": shell.path, "HOME": root.path, "ZDOTDIR": root.path,
                                   "PATH": "/usr/bin:/bin", "XDG_CONFIG_HOME": "/remote/core/config"]
                .merging(spec.environment) { _, panel in panel }
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let pid = process.processIdentifier
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let observed = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            XCTAssertEqual(observed, [shell.path, "1", "-l", panelValue ?? "unset", String(pid), ""])
        }
    }

    /// The saved snapshot keeps the machine; a remote panel saves no local
    /// folder and no scrollback (hc on that machine owns the history).
    func testSnapshotKeepsTheMachineAndDropsLocalHistory() throws {
        let panel = UUID()
        let identity = HCPanelIdentity(panelID: panel, key: HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t7"))
        var scrollbackRead = false
        let saved = SessionTerminalPanelSnapshot.capture(workingDirectory: "/Users/me/local", hcIdentity: identity,
            hcRemoteTarget: HCRemoteTarget(machine: "studio", cwd: "/tmp/x")) { scrollbackRead = true; return "history" }
        XCTAssertFalse(scrollbackRead)
        XCTAssertNil(saved.workingDirectory)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.hcRemoteTarget, HCRemoteTarget(machine: "studio", cwd: "/tmp/x"))
        XCTAssertEqual(decoded.hcIdentity?.key, identity.key)

        let old = Data(#"{"workingDirectory":"/w","scrollback":"s"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: old).hcRemoteTarget)
    }

    /// Row 23: every dropped file is checked before any byte is sent; a
    /// folder or a file over hc's 8 MiB put limit refuses the whole drop.
    func testRemoteDropReadsFilesAndRefusesFoldersAndOversizeFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hcdrop\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let small = root.appendingPathComponent("shot one.png")
        try Data([1, 2, 3]).write(to: small)
        let big = root.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(HCRemoteFileDrop.maximumBytes + 1))
        try handle.close()
        let exact = root.appendingPathComponent("exact.bin")
        FileManager.default.createFile(atPath: exact.path, contents: nil)
        let exactHandle = try FileHandle(forWritingTo: exact)
        try exactHandle.truncate(atOffset: UInt64(HCRemoteFileDrop.maximumBytes))
        try exactHandle.close()

        XCTAssertEqual(try HCRemoteFileDrop.read([small]).get(), [HCRemoteFileDrop.Item(name: "shot one.png", data: Data([1, 2, 3]))])
        XCTAssertEqual(try HCRemoteFileDrop.read([exact]).get().first?.data.count, HCRemoteFileDrop.maximumBytes)
        XCTAssertEqual(HCRemoteFileDrop.read([small, big]), .failure(.tooLarge("big.bin")))
        XCTAssertEqual(HCRemoteFileDrop.read([small, root]), .failure(.notAFile(root.lastPathComponent)))
        XCTAssertEqual(HCRemoteFileDrop.read([root.appendingPathComponent("gone")]), .failure(.notAFile("gone")))
    }

    /// The pasted text is the remote paths, escaped like a local drop; a
    /// failed put pastes nothing.
    /// T12.1: a remote agent launch's prompt file is sent to the terminal's
    /// machine, and both positional and post-boot delivery name the path it
    /// landed at there, never this Mac's launch-prompts folder. A failed send
    /// yields no path, so nothing is launched.
    func testRemoteLaunchPromptLandsOnTheTargetAndTheLaunchNamesThatPath() async throws {
        actor Transfer: HCFileTransfer {
            var puts: [(HCTerminalKey, String, Data)] = []
            let fail: Bool
            init(fail: Bool) { self.fail = fail }
            func put(_ key: HCTerminalKey, name: String, data: Data) async throws -> String {
                if fail { throw HCUnavailableReason.connectionLost }
                puts.append((key, name, data))
                return "/home/atin/.local/state/hc/put/3/" + name
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hcprompt\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("launch-prompt-7.txt")
        try Data("Review this change".utf8).write(to: local)
        let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t3")
        let transfer = Transfer(fail: false)
        guard case .success(let remote) = await HCRemoteLaunchPrompt.send(prompt: local, to: key, via: transfer) else {
            return XCTFail("The prompt must be sent")
        }
        let puts = await transfer.puts
        XCTAssertEqual(puts.count, 1)
        XCTAssertEqual(puts.first?.0, key)
        XCTAssertEqual(puts.first.map { String(decoding: $0.2, as: UTF8.self) }, "Review this change")
        XCTAssertEqual(remote, "/home/atin/.local/state/hc/put/3/launch-prompt-7.txt")
        let positional = LaunchPromptDelivery.compose(command: "codex", delivery: .positional, promptFilePath: remote)
        let postBoot = LaunchPromptDelivery.compose(command: "codex", delivery: .postBoot, promptFilePath: remote)
        XCTAssertTrue(positional.launchLine.contains(remote))
        XCTAssertFalse(positional.launchLine.contains(local.path))
        XCTAssertEqual(postBoot.launchLine, "codex")
        XCTAssertEqual(postBoot.delayedPrompt, LaunchPromptDelivery.instruction(path: remote))
        guard case .failure(.transfer) = await HCRemoteLaunchPrompt.send(prompt: local, to: key, via: Transfer(fail: true)) else {
            return XCTFail("A failed send yields no path to launch with")
        }
    }

    func testRemoteDropPastesWhereFilesLandedOrNothing() async {
        actor Transfer: HCFileTransfer {
            var calls: [String] = []
            let failOn: String?
            init(failOn: String?) { self.failOn = failOn }
            func put(_ key: HCTerminalKey, name: String, data: Data) async throws -> String {
                calls.append(name)
                if name == failOn { throw HCUnavailableReason.connectionLost }
                return "/Users/demo/.local/state/herdr-core/c11/files/t7/\(name)"
            }
        }
        let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t7")
        let items = [HCRemoteFileDrop.Item(name: "a b.png", data: Data([1])), HCRemoteFileDrop.Item(name: "c.txt", data: Data([2]))]
        let escape: (String) -> String = { $0.replacingOccurrences(of: " ", with: "\\ ") }
        let ok = Transfer(failOn: nil)
        let sent = await HCRemoteFileDrop.send(items, to: key, via: ok, escape: escape)
        XCTAssertEqual(sent,
            .success("/Users/demo/.local/state/herdr-core/c11/files/t7/a\\ b.png /Users/demo/.local/state/herdr-core/c11/files/t7/c.txt"))
        let broken = Transfer(failOn: "c.txt")
        let failed = await HCRemoteFileDrop.send(items, to: key, via: broken, escape: escape)
        XCTAssertEqual(failed, .failure(.transfer("c.txt", .connectionLost)))
        let calls = await broken.calls
        XCTAssertEqual(calls, ["a b.png", "c.txt"])
    }

    func testRemoteTargetNormalizesAnEmptyFolder() {
        XCTAssertNil(HCRemoteTarget(machine: "studio", cwd: "  ").cwd)
        XCTAssertEqual(HCRemoteTarget(machine: "studio", cwd: " /tmp ").cwd, "/tmp")
    }

    /// The poll runs fast only while a machine is added.
    func testLinkPollIntervalFollowsWhetherAnyMachineIsAdded() {
        XCTAssertEqual(HCMachineLinkMonitor.interval(after: nil), HCMachineLinkMonitor.idleInterval)
        XCTAssertEqual(HCMachineLinkMonitor.interval(after: [:]), HCMachineLinkMonitor.idleInterval)
        XCTAssertEqual(HCMachineLinkMonitor.interval(after: ["studio": .disconnected]), HCMachineLinkMonitor.activeInterval)
    }

    /// The monitor polls before its first sleep, so machines added before
    /// activation are watched from the start, not after the idle interval.
    func testLinkMonitorPollsBeforeItsFirstSleep() async {
        let polled = expectation(description: "first poll before any sleep")
        let monitor = HCMachineLinkMonitor(poll: { polled.fulfill(); return ["studio": .connected] },
            sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
        await monitor.start()
        await fulfillment(of: [polled], timeout: 2)
        await monitor.stop()
    }

    func testLinkMonitorPollsUntilStopped() async throws {
        final class Count: @unchecked Sendable { let lock = NSLock(); var n = 0
            func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n } }
        let count = Count()
        let thrice = expectation(description: "three polls")
        let monitor = HCMachineLinkMonitor(poll: {
            if count.bump() == 3 { thrice.fulfill() }
            return ["studio": .connected]
        }, sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) })
        await monitor.start()
        await fulfillment(of: [thrice], timeout: 5)
        await monitor.stop()
        let running = await monitor.isRunning
        XCTAssertFalse(running)
    }
}
