import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-138: the machine picker's decisions, the saved-config machine field,
/// and where an agent launch goes.
final class MachinePickerTests: XCTestCase {

    func testAsksOnlyWhenEnabledAndAnotherMachineIsConnected() {
        XCTAssertFalse(MachinePickerModel.shouldAsk(enabled: true, machines: [:]), "no machine: today's behavior")
        XCTAssertFalse(MachinePickerModel.shouldAsk(enabled: true, machines: ["studio": false]), "only a down link")
        XCTAssertTrue(MachinePickerModel.shouldAsk(enabled: true, machines: ["studio": true, "linuxbox": false]))
        XCTAssertFalse(MachinePickerModel.shouldAsk(enabled: false, machines: ["studio": true]), "the switch is off")
    }

    func testTheSwitchDefaultsOnAndFollowsItsKey() {
        let suite = "c11.machinePicker.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(MachinePickerSettings.isEnabled(defaults: defaults))
        defaults.set(false, forKey: MachinePickerSettings.askKey)
        XCTAssertFalse(MachinePickerSettings.isEnabled(defaults: defaults))
    }

    func testRowsPutThisMacFirstThenMachinesByNameWithNumberKeys() {
        let roster: [String: MachineRosterEntry] = [
            "local": MachineRosterEntry(id: "local", name: "Desk Mac", color: "#F5A623"),
            "studio": MachineRosterEntry(id: "studio", name: "Studio Prime", color: "#3FA7D6"),
        ]
        let rows = MachinePickerModel.rows(
            machines: ["linuxbox": false, "studio": true],
            roster: { roster[$0.lowercased()] },
            localHostName: "Laptop"
        )
        XCTAssertEqual(rows.map(\.id), ["local", "linuxbox", "studio"])
        XCTAssertEqual(rows.map(\.key), [1, 2, 3])
        XCTAssertEqual(rows[0].name, "Desk Mac")
        XCTAssertEqual(rows[0].color, "#F5A623")
        XCTAssertEqual(rows[0].request, .local)
        XCTAssertEqual(rows[1].name, "Linuxbox", "no roster entry: hc's name, first letter raised")
        XCTAssertFalse(rows[1].isEnabled, "a down link is shown but cannot be picked")
        XCTAssertEqual(rows[2].name, "Studio Prime")
        XCTAssertEqual(rows[2].request, .on("studio"))
        XCTAssertTrue(rows[2].isEnabled)

        let many = MachinePickerModel.rows(
            machines: Dictionary(uniqueKeysWithValues: (1...10).map { (String(format: "m%02d", $0), true) }),
            roster: { _ in nil },
            localHostName: "Laptop"
        )
        XCTAssertEqual(many.count, 11)
        XCTAssertEqual(many[8].key, 9)
        XCTAssertNil(many[9].key, "past nine, a row has no number key")
    }

    func testKeysPickAtOnceReturnPicksThisMacAndEscapeCancels() {
        let rows = MachinePickerModel.rows(machines: ["studio": true, "linuxbox": false], roster: { _ in nil }, localHostName: "Laptop")
        XCTAssertEqual(MachinePickerModel.action(digit: 1, rows: rows), .choose(.local))
        XCTAssertEqual(MachinePickerModel.action(digit: 2, rows: rows), .ignore, "down link")
        XCTAssertEqual(MachinePickerModel.action(digit: 3, rows: rows), .choose(.on("studio")))
        XCTAssertEqual(MachinePickerModel.action(digit: 7, rows: rows), .ignore, "no such row")
        XCTAssertEqual(MachinePickerModel.returnAction, .choose(.local))
        XCTAssertEqual(MachinePickerModel.escapeAction, .cancel)
    }

    /// C11H-274: a machine whose stored link c11 won't use is listed with the
    /// reason and cannot be picked, by key or click, even while connected.
    func testAMachineWithAnUnusableLinkIsListedButNotPickable() {
        let rows = MachinePickerModel.rows(machines: ["studio": true, "far": true], unusable: ["far"],
                                           roster: { _ in nil }, localHostName: "Laptop")
        XCTAssertEqual(rows.map(\.id), [MachineRoster.localID, "far", "studio"], "still listed")
        XCTAssertEqual(MachinePickerModel.action(digit: 2, rows: rows), .ignore, "far's link is unusable")
        XCTAssertEqual(MachinePickerModel.action(digit: 3, rows: rows), .choose(.on("studio")))
        XCTAssertFalse(rows[1].isEnabled)
        XCTAssertTrue(rows[1].stateText.contains("Update or Remove"), rows[1].stateText)
    }

    /// C11H-274: each session's unusable links merge into one set that the
    /// File menu, the picker and the socket's `--on` check all read.
    @MainActor
    func testUnusableLinksMergeAcrossSessionsForTheMenuPickerAndSocket() {
        let directory = HCMachineDirectory()
        defer { HCLinkedMachines.shared.setUnusable(bySession: [:]) }
        directory.setUnusable(["far"], session: "c11h")
        directory.setUnusable(["cube"], session: "c11h-s1")
        XCTAssertEqual(directory.unusable, ["far", "cube"])
        XCTAssertEqual(HCLinkedMachines.shared.unusable(), ["far", "cube"], "the socket worker's --on check reads the same set")
        directory.setUnusable([], session: "c11h")
        XCTAssertEqual(directory.unusable, ["cube"], "a session's review that clears its own set leaves the others")
        let entries = HCMachineDirectory.entries(["cube": .connected, "studio": .connected], unusable: directory.unusable)
        XCTAssertEqual(entries.map { "\($0.machine) \($0.connected) \($0.usable)" }, ["cube true false", "studio true true"])
    }

    /// C11H-391: the File menu and the picker list each name once, from the
    /// link a new terminal there uses: a name c11h links unusably and c11's
    /// links session links usably is offered; one only c11h links is listed
    /// and not offered. The socket's copy is the same per-session state.
    @MainActor
    func testTheMenuAndPickerOfferANameAnotherSessionLinksUsably() {
        let directory = HCMachineDirectory()
        defer { HCLinkedMachines.shared.setUnusable(bySession: [:]) }
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        directory.apply(HCInventorySnapshot(readiness: .ready(revision), revision: revision,
            machines: ["far": .connected, "cube": .connected],
            sessionMachines: [HCSessionMachines(shard: .legacy, session: "c11h", machines: ["far": .connected, "cube": .connected]),
                              HCSessionMachines(shard: .links, session: "c11", machines: ["far": .connected])]))
        directory.setUnusable(["far", "cube"], session: "c11h")
        XCTAssertEqual(directory.unusable, ["cube"])
        XCTAssertEqual(directory.entries.map { "\($0.machine) \($0.usable)" }, ["cube false", "far true"])
        XCTAssertEqual(HCLinkedMachines.shared.unusableSessions(), ["c11h": ["far", "cube"]])
        XCTAssertEqual(directory.links(of: "far").map { "\($0.session) \($0.usable)" }, ["c11h false", "c11 true"],
                       "Settings sees both links of the name")
        let rows = MachinePickerModel.rows(machines: Dictionary(uniqueKeysWithValues: directory.entries.map { ($0.machine, $0.connected) }),
                                           unusable: directory.unusable, roster: { _ in nil }, localHostName: "Laptop")
        XCTAssertEqual(rows.map { "\($0.id) \($0.isEnabled)" }, ["\(MachineRoster.localID) true", "cube false", "far true"])
    }

    /// C11H-391 (Opus on #380, NB6): two overlapping stored-link reviews can
    /// publish out of order; only the newest one counts.
    @MainActor
    func testAnOlderUnusablePublishNeverReplacesANewerOne() {
        let directory = HCMachineDirectory()
        defer { HCLinkedMachines.shared.setUnusable(bySession: [:]) }
        directory.setUnusable(["far"], session: "c11h", generation: 2)
        directory.setUnusable([], session: "c11h", generation: 1)
        XCTAssertEqual(directory.unusable, ["far"], "the older review's empty set arrived last and is dropped")
        directory.setUnusable([], session: "c11h", generation: 3)
        XCTAssertEqual(directory.unusable, [])
    }

    /// C11H-391 (Opus on #380, NB3): a split of a terminal on another machine,
    /// or a named machine, is refused before any panel exists when the link a
    /// new terminal there would use is unusable; a restored panel never is.
    @MainActor
    func testASplitOfATerminalOnAnUnusableLinkIsRefusedUpFront() {
        let far = HCRemoteTarget(machine: "far")
        XCTAssertEqual(Workspace.hcRemoteRefusal(.inherit, target: far, unusable: ["far"]), .linkUnusable("far"))
        XCTAssertEqual(Workspace.hcRemoteRefusal(.on("far"), target: far, unusable: ["far"]), .linkUnusable("far"))
        XCTAssertNil(Workspace.hcRemoteRefusal(.inherit, target: far, unusable: []), "usable: opens, routed to the usable link")
        XCTAssertNil(Workspace.hcRemoteRefusal(.restored(far), target: far, unusable: ["far"]), "a restored panel reattaches")
        XCTAssertNil(Workspace.hcRemoteRefusal(.inherit, target: nil, unusable: ["far"]), "a split of a local terminal")
    }

    // MARK: Agent launch target

    func testAgentLaunchGoesWhereAskedThenWhereSavedThenHere() {
        let machines = ["studio": true, "linuxbox": false]
        func target(_ requested: HCMachineRequest?, _ saved: String?) -> Result<HCMachineRequest, Workspace.AgentLaunchDecline> {
            Workspace.agentLaunchMachine(requested: requested, saved: saved, machines: machines)
        }
        XCTAssertEqual(try target(nil, nil).get(), .local)
        XCTAssertEqual(try target(nil, "local").get(), .local)
        XCTAssertEqual(try target(nil, "Studio").get(), .on("studio"), "hc's spelling wins")
        XCTAssertEqual(try target(.local, "studio").get(), .local, "the operator's choice beats the saved machine")
        XCTAssertEqual(try target(.on("studio"), nil).get(), .on("studio"))
        XCTAssertThrowsError(try target(nil, "linuxbox").get()) {
            XCTAssertEqual($0 as? Workspace.AgentLaunchDecline, .machineUnavailable("linuxbox"))
        }
        XCTAssertThrowsError(try target(nil, "prime").get()) {
            XCTAssertEqual($0 as? Workspace.AgentLaunchDecline, .machineUnavailable("prime"))
        }
    }

    /// C11H-391 (Opus on #380, NB3): a saved config on a machine whose routed
    /// link c11 won't use is refused before any panel exists, with the action;
    /// once c11's own link of that name exists, the routed view offers it.
    func testASavedAgentConfigOnAnUnusableLinkIsRefusedUpFront() {
        let refused = Workspace.agentLaunchMachine(requested: nil, saved: "Far", machines: ["far": true], unusable: ["far"])
        XCTAssertEqual(refused, .failure(.machineLinkUnusable("far")), "connected is not enough")
        if case .failure(let decline) = refused { XCTAssertTrue(decline.message.contains("Update or Remove"), decline.message) }
        XCTAssertEqual(Workspace.agentLaunchMachine(requested: nil, saved: "far", machines: ["far": true], unusable: []),
                       .success(.on("far")))
    }

    func testAConfigSavedWithAnotherMachineIsNotGatedOnThisMacsPath() {
        let env = AgentPickerEnvironment(
            displayName: { $0 }, provider: { _, _ in nil }, isInstalled: { _ in false }, costFor: { _ in nil }
        )
        let config = AgentLaunchConfig(harness: "codex")
        XCTAssertFalse(AgentPickerModel.isLaunchable(SavedAgentConfig(id: "a", name: "A", order: 0, config: config), env: env))
        XCTAssertFalse(AgentPickerModel.isLaunchable(
            SavedAgentConfig(id: "b", name: "B", order: 1, config: config, machine: "local"), env: env))
        let remote = SavedAgentConfig(id: "c", name: "C", order: 2, config: config, machine: "studio")
        XCTAssertTrue(AgentPickerModel.isLaunchable(remote, env: env), "the harness runs on that machine")
        XCTAssertTrue(AgentPickerModel.subLine(for: remote, env: env).hasSuffix("on Studio"))
    }

    // MARK: Saved config machine

    func testSavedConfigMachineRoundTripsAndNormalizes() throws {
        let config = AgentLaunchConfig(harness: "claude-code", model: "opus")
        XCTAssertNil(SavedAgentConfig(id: "a", name: "A", order: 0, config: config, machine: "ask").machine)
        XCTAssertNil(SavedAgentConfig(id: "a", name: "A", order: 0, config: config, machine: "  ").machine)
        XCTAssertEqual(SavedAgentConfig(id: "a", name: "A", order: 0, config: config, machine: "Here").machine, "local")

        let onAtlas = SavedAgentConfig(id: "a", name: "Opus on Studio", order: 0, config: config, machine: "studio")
        let data = try JSONEncoder().encode(onAtlas)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["machine"] as? String, "studio", "flat on disk, beside the recipe")
        XCTAssertEqual(try JSONDecoder().decode(SavedAgentConfig.self, from: data), onAtlas)

        let plain = try JSONEncoder().encode(SavedAgentConfig(id: "b", name: "B", order: 1, config: config))
        let plainObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertNil(plainObject["machine"], "unset is omitted, so older builds read the file unchanged")
    }

    func testConfigCoreSavesEditsAndKeepsTheMachine() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("machinepicker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let library = AgentConfigLibraryStore(directory: tmp)
        let core = ConfigCommandCore(library: library, stats: nil)

        let saved = try core.save(name: "Opus on Studio", fields: ConfigFields(harness: "claude-code", model: "opus", machine: "studio"))
        XCTAssertEqual(saved.machine, "studio")
        let edited = try core.edit(nameOrId: "Opus on Studio", fields: ConfigFields(model: "sonnet"))
        XCTAssertEqual(edited.machine, "studio", "an edit that does not name the machine keeps it")
        let cleared = try core.edit(nameOrId: "Opus on Studio", fields: ConfigFields(machine: "ask"))
        XCTAssertNil(cleared.machine)
        XCTAssertNil(try core.resolveConfig(nameOrId: "Opus on Studio").machine)
    }
}
