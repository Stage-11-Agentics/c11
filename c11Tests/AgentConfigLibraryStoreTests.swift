import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure-logic tests for the agent-config library store (C11-176). No
/// Workspace/TabManager construction — safe for the bare `c11-logic` runner.
/// Each test injects a fresh temp directory so the real state root never leaks.
final class AgentConfigLibraryStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: AgentConfigLibraryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-config-tests-\(UUID().uuidString)", isDirectory: true)
        store = AgentConfigLibraryStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        store = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - AC #1: §2.1 schema round-trips

    func testFactoryFileRoundTrips() throws {
        let factory = AgentConfigLibraryFile.factory
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(factory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentConfigLibraryFile.self, from: data)
        XCTAssertEqual(decoded, factory)
    }

    func testFactoryOnDiskShapeMatchesSchema() throws {
        try store.write(.factory)
        let raw = try Data(contentsOf: store.fileURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])

        XCTAssertEqual(json["schema_version"] as? Int, 1)
        let configs = try XCTUnwrap(json["configs"] as? [[String: Any]])
        XCTAssertEqual(configs.count, 1)
        let opus = configs[0]
        XCTAssertEqual(opus["name"] as? String, "Opus deep")
        XCTAssertEqual(opus["harness"] as? String, "claude-code")
        XCTAssertEqual(opus["model"] as? String, "opus")
        XCTAssertEqual(opus["order"] as? Int, 0)
        // Unset recipe fields are absent (inherit), not null. Effort is UNSET
        // on the seed (byte-identical to today's pin: no --effort flag).
        XCTAssertNil(opus["effort"])
        XCTAssertNil(opus["command"])
        XCTAssertNil(opus["initial_prompt"])
        XCTAssertNil(opus["systemPrompt"])
        XCTAssertNil(opus["env"])

        let def = try XCTUnwrap(json["default"] as? [String: Any])
        XCTAssertEqual(def["mode"] as? String, "pinned")
        XCTAssertEqual(def["config_id"] as? String, opus["id"] as? String)
        // recent unset → absent.
        XCTAssertNil(json["recent"])
    }

    /// A hand-authored §2.1 fixture carrying a legacy `follow-recent` default, a
    /// blank-slate (`replace` + "") config, `field_sources`, and
    /// `initial_prompt`/`env` overlays. The `systemPrompt` key is camelCase
    /// exactly as §2.1 writes it. C11-203 B2: the retired mode migrates to
    /// pinned on read, and every other field survives untouched.
    func testAuthoredSchemaFixtureRoundTrips() throws {
        let fixture = """
        {
          "schema_version": 1,
          "configs": [
            { "id": "01JOPUS", "name": "Opus deep", "order": 0,
              "harness": "claude-code", "model": "opus", "effort": "high",
              "systemPrompt": { "mode": "inherit", "text": "" } },
            { "id": "01JGREG", "name": "Gregorovich", "order": 1,
              "harness": "claude-code", "model": "opus",
              "systemPrompt": { "mode": "replace", "text": "" },
              "initial_prompt": "hello",
              "env": { "FOO": "bar" } },
            { "id": "01JCDX", "name": "Codex hi", "order": 2,
              "harness": "codex", "model": "gpt-5.2", "effort": "high" }
          ],
          "default": { "mode": "follow-recent", "config_id": "01JOPUS" },
          "recent": { "config_id": "01JCDX", "harness": "codex", "model": "gpt-5.2",
                      "effort": "high", "observed_at": "2026-07-20T21:14:00.000Z",
                      "source": "launch",
                      "field_sources": { "model": "launch", "effort": "launch" } }
        }
        """.data(using: .utf8)!

        // Decode through the store's own decoder path by writing then reading.
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try fixture.write(to: store.fileURL, options: .atomic)
        let file = store.current

        XCTAssertEqual(file.schemaVersion, 1)
        XCTAssertEqual(file.configs.count, 3)
        // Legacy mode migrated, `config_id` preserved — no heal-to-factory.
        XCTAssertEqual(file.default.mode, .pinned)
        XCTAssertEqual(file.default.configId, "01JOPUS")

        // Blank-slate case actually decodes: replace + empty text, not nil.
        let greg = try XCTUnwrap(file.configs.first { $0.name == "Gregorovich" })
        XCTAssertEqual(greg.config.systemPrompt?.mode, .replace)
        XCTAssertEqual(greg.config.systemPrompt?.text, "")
        XCTAssertEqual(greg.config.initialPrompt, "hello")
        XCTAssertEqual(greg.config.env, ["FOO": "bar"])
        // Inherit config: systemPrompt present but inert.
        let opus = try XCTUnwrap(file.configs.first { $0.name == "Opus deep" })
        XCTAssertEqual(opus.config.systemPrompt?.mode, .inherit)
        XCTAssertNil(opus.config.command)

        XCTAssertEqual(file.recent?.configId, "01JCDX")
        XCTAssertEqual(file.recent?.model, "gpt-5.2")
        XCTAssertEqual(file.recent?.fieldSources?["model"], "launch")

        // Re-encode and re-read: stable.
        try store.write(file)
        XCTAssertEqual(store.current, file)
    }

    func testBlankSlateSurvivesStoreRoundTrip() throws {
        let blank = SavedAgentConfig(
            id: "BLANK1", name: "Greg", order: 0,
            config: AgentLaunchConfig(
                harness: "claude-code",
                systemPrompt: SystemPromptSetting(mode: .replace, text: "")
            )
        )
        let file = AgentConfigLibraryFile(
            configs: [blank],
            default: AgentConfigDefault(mode: .pinned, configId: "BLANK1")
        )
        try store.write(file)
        let back = try XCTUnwrap(store.current.configs.first)
        XCTAssertEqual(back.config.systemPrompt, SystemPromptSetting(mode: .replace, text: ""))
    }

    // MARK: - AC #2: §3 effectiveDefault branch

    func testEffectiveDefaultPinnedReturnsPinnedConfig() throws {
        try store.write(.factory)
        let resolved = store.effectiveDefault()
        XCTAssertEqual(resolved.name, "Opus deep")
        XCTAssertEqual(resolved.config.harness, "claude-code")
        XCTAssertEqual(resolved.config.model, "opus")
    }

    /// The seed must resolve to today's exact launch axes: claude-code +
    /// model=opus + NO effort (byte-identical to the current pin; C11-179
    /// regression AC). Effort UNSET means no `--effort` flag is injected.
    func testFactorySeedIsByteIdenticalToTodaysPin() {
        let seed = AgentConfigLibraryFile.factory.configs[0]
        XCTAssertEqual(seed.config.harness, "claude-code")
        XCTAssertEqual(seed.config.model, "opus")
        XCTAssertNil(seed.config.effort)          // no --effort at launch
        XCTAssertNil(seed.config.command)         // inherit factory command
        XCTAssertNil(seed.config.systemPrompt)    // inherit system prompt
        XCTAssertNil(seed.config.initialPrompt)
        XCTAssertNil(seed.config.env)
    }

    /// C11-203 B2: `recent` is telemetry, not a resolution input. A file whose
    /// `recent` names a different config still resolves to the pin.
    func testEffectiveDefaultIgnoresRecent() throws {
        let opus = SavedAgentConfig(id: "OPUS", name: "Opus deep", order: 0,
            config: AgentLaunchConfig(harness: "claude-code", model: "opus", effort: "high"))
        let codex = SavedAgentConfig(id: "CDX", name: "Codex hi", order: 1,
            config: AgentLaunchConfig(harness: "codex", model: "gpt-5.2", effort: "high"))
        let file = AgentConfigLibraryFile(
            configs: [opus, codex],
            default: AgentConfigDefault(mode: .pinned, configId: "OPUS"),
            recent: RecentAgentConfig(configId: "CDX", harness: "codex", model: "gpt-5.2")
        )
        try store.write(file)
        let resolved = store.effectiveDefault()
        XCTAssertEqual(resolved.id, "OPUS")
        XCTAssertEqual(resolved.config.harness, "claude-code")
        // The record itself is still persisted for `c11 config recent`.
        XCTAssertEqual(store.current.recent?.configId, "CDX")
    }

    /// A legacy on-disk `follow-recent` file resolves to its pinned config and
    /// keeps every saved config — the migration must never look like corruption.
    func testLegacyFollowRecentFileMigratesWithoutDataLoss() throws {
        let fixture = """
        {
          "schema_version": 1,
          "configs": [
            { "id": "OPUS", "name": "Opus deep", "order": 0, "harness": "claude-code", "model": "opus" },
            { "id": "CDX", "name": "Codex hi", "order": 1, "harness": "codex", "model": "gpt-5.2" }
          ],
          "default": { "mode": "follow-recent", "config_id": "OPUS" },
          "recent": { "config_id": "CDX", "harness": "codex", "model": "gpt-5.2" }
        }
        """.data(using: .utf8)!
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try fixture.write(to: store.fileURL, options: .atomic)

        let file = store.current
        XCTAssertEqual(file.configs.map(\.id), ["OPUS", "CDX"])   // nothing dropped
        XCTAssertEqual(file.default.mode, .pinned)
        XCTAssertEqual(store.effectiveDefault().id, "OPUS")
        XCTAssertEqual(file.recent?.configId, "CDX")               // telemetry kept

        // Re-writing normalizes the mode on disk without touching the pointer.
        try store.write(file)
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        )
        let def = try XCTUnwrap(raw["default"] as? [String: Any])
        XCTAssertEqual(def["mode"] as? String, "pinned")
        XCTAssertEqual(def["config_id"] as? String, "OPUS")
    }

    /// An unknown future mode is treated the same way: pinned, no data loss.
    func testUnknownDefaultModeMigratesToPinned() throws {
        let fixture = """
        {
          "schema_version": 1,
          "configs": [
            { "id": "OPUS", "name": "Opus deep", "order": 0, "harness": "claude-code", "model": "opus" }
          ],
          "default": { "mode": "some-future-mode", "config_id": "OPUS" }
        }
        """.data(using: .utf8)!
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try fixture.write(to: store.fileURL, options: .atomic)
        XCTAssertEqual(store.current.configs.count, 1)
        XCTAssertEqual(store.current.default.mode, .pinned)
        XCTAssertEqual(store.effectiveDefault().id, "OPUS")
    }

    func testEffectiveDefaultPinnedDanglingIdFallsBackToFactory() throws {
        let file = AgentConfigLibraryFile(
            configs: [SavedAgentConfig(id: "REAL", name: "Real", order: 0,
                config: AgentLaunchConfig(harness: "codex"))],
            default: AgentConfigDefault(mode: .pinned, configId: "DANGLING")
        )
        try store.write(file)
        // Pointer dangles → factory seed, never a crash.
        let resolved = store.effectiveDefault()
        XCTAssertEqual(resolved.name, "Opus deep")
        XCTAssertEqual(resolved.config.model, "opus")
    }

    // MARK: - AC #3: corrupt/missing → factory (§5.6)

    func testMissingFileFallsBackToFactory() {
        // Fresh temp dir, nothing written.
        XCTAssertEqual(store.current, .factory)
    }

    func testGarbageFileFallsBackToFactory() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("not json {{{".utf8).write(to: store.fileURL, options: .atomic)
        XCTAssertEqual(store.current, .factory)
    }

    func testWrongSchemaVersionFallsBackToFactory() throws {
        let future = """
        { "schema_version": 2, "configs": [], "default": { "mode": "pinned", "config_id": "x" } }
        """.data(using: .utf8)!
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try future.write(to: store.fileURL, options: .atomic)
        XCTAssertEqual(store.current, .factory)
    }

    func testDanglingDefaultStillResolvesToValidConfig() throws {
        // A structurally-valid file whose pinned id names no config: current is
        // returned as-is (not corrupt), but effectiveDefault heals.
        let file = AgentConfigLibraryFile(
            configs: [SavedAgentConfig(id: "A", name: "A", order: 0,
                config: AgentLaunchConfig(harness: "codex"))],
            default: AgentConfigDefault(mode: .pinned, configId: "MISSING")
        )
        try store.write(file)
        XCTAssertFalse(store.current.hasResolvablePinnedDefault)
        XCTAssertEqual(store.effectiveDefault().name, "Opus deep")  // factory heal
    }

    // MARK: - C11-203 A2: healing an unlaunchable library

    /// The real specimen captured from the operator's
    /// `~/Library/Application Support/c11/agent-configs.json` on 2026-08-08: the
    /// factory seed rewritten to `harness: "custom"` with the model dropped, and
    /// still pinned — the exact state that left the A button dead. Inlined
    /// verbatim so the fixture needs no test-bundle resource.
    private static let corruptSpecimen = """
    {
      "configs" : [
        {
          "harness" : "custom",
          "id" : "0000000000AGENTOPUSDEEP001",
          "name" : "Opus deep",
          "order" : 0
        },
        {
          "harness" : "omp",
          "id" : "01KZHX6WJAETWCCQV7PJ74JNBR",
          "name" : "oh-my-pi",
          "order" : 1
        },
        {
          "harness" : "codex",
          "id" : "01KZHXSAYF5BCJ1P6SF6MAME83",
          "name" : "Codex",
          "order" : 2
        }
      ],
      "default" : {
        "config_id" : "0000000000AGENTOPUSDEEP001",
        "mode" : "pinned"
      },
      "recent" : {
        "config_id" : "0000000000AGENTOPUSDEEP001",
        "field_sources" : {
          "effort" : "launch",
          "model" : "launch"
        },
        "harness" : "custom",
        "observed_at" : "2026-08-06T18:41:21.516Z",
        "source" : "launch"
      },
      "schema_version" : 1
    }
    """

    private func writeSpecimen() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data(Self.corruptSpecimen.utf8).write(to: store.fileURL, options: .atomic)
    }

    /// The specimen's pinned default is unlaunchable as written, which is what
    /// left the A button silently dead. On load it heals back to the seed recipe
    /// and resolves to a launchable claude-code launch.
    func testCorruptFactorySeedHealsOnLoad() throws {
        try writeSpecimen()
        let resolved = store.effectiveDefault()
        XCTAssertEqual(resolved.id, AgentConfigLibraryFile.factorySeedConfigId)
        XCTAssertEqual(resolved.config.harness, "claude-code")
        XCTAssertEqual(resolved.config.model, "opus")
        XCTAssertFalse(resolved.config.isProvablyUnlaunchable)
        // The operator's other configs and their order are untouched.
        XCTAssertEqual(store.current.configs.map(\.id), [
            AgentConfigLibraryFile.factorySeedConfigId,
            "01KZHX6WJAETWCCQV7PJ74JNBR",
            "01KZHXSAYF5BCJ1P6SF6MAME83",
        ])
        // The operator's name for the seed row survives the recipe repair.
        XCTAssertEqual(resolved.name, "Opus deep")
    }

    /// The heal is not a read-only illusion: the next mutation persists it, so a
    /// second process (the CLI, app-down) reads the repaired recipe too.
    func testHealPersistsOnNextWrite() throws {
        try writeSpecimen()
        try store.recordRecent(RecentAgentConfig(harness: "claude-code"))
        let reopened = AgentConfigLibraryStore(directory: tempDir)
        let seed = try XCTUnwrap(reopened.current.configs.first {
            $0.id == AgentConfigLibraryFile.factorySeedConfigId
        })
        XCTAssertEqual(seed.config.harness, "claude-code")
        XCTAssertEqual(seed.config.model, "opus")
    }

    /// A seed row the operator deliberately re-pointed at a *launchable* recipe
    /// is theirs; the heal only fires on the unlaunchable state.
    func testHealLeavesLaunchableFactorySeedAlone() throws {
        let edited = SavedAgentConfig(
            id: AgentConfigLibraryFile.factorySeedConfigId, name: "Sonnet quick", order: 0,
            config: AgentLaunchConfig(harness: "claude-code", model: "sonnet"))
        try store.write(AgentConfigLibraryFile(
            configs: [edited],
            default: AgentConfigDefault(mode: .pinned, configId: edited.id)))
        XCTAssertEqual(store.effectiveDefault().config.model, "sonnet")
        XCTAssertEqual(store.current.configs[0].name, "Sonnet quick")
    }

    /// An operator-authored unlaunchable config is never rewritten — it stays in
    /// the library, editable — but it cannot hold the default.
    func testOperatorAuthoredUnlaunchableConfigIsKeptButNotResolved() throws {
        let broken = SavedAgentConfig(id: "BROKEN", name: "Aider", order: 0,
            config: AgentLaunchConfig(harness: "custom"))
        let good = SavedAgentConfig(id: "GOOD", name: "Codex", order: 1,
            config: AgentLaunchConfig(harness: "codex"))
        try store.write(AgentConfigLibraryFile(
            configs: [broken, good],
            default: AgentConfigDefault(mode: .pinned, configId: "BROKEN")))

        let file = store.current
        // Kept verbatim.
        XCTAssertEqual(file.configs.first { $0.id == "BROKEN" }?.config,
                       AgentLaunchConfig(harness: "custom"))
        // But it is not what a plain left-click launches.
        XCTAssertEqual(file.default.configId, "GOOD")
        XCTAssertEqual(store.effectiveDefault().id, "GOOD")
    }

    /// A custom config that carries its own command is launchable, so it keeps
    /// the pin — the escape hatch still works.
    func testCustomConfigWithCommandStaysPinned() throws {
        let aider = SavedAgentConfig(id: "AIDER", name: "Aider", order: 0,
            config: AgentLaunchConfig(harness: "custom", command: "aider --model sonnet"))
        try store.write(AgentConfigLibraryFile(
            configs: [aider],
            default: AgentConfigDefault(mode: .pinned, configId: "AIDER")))
        XCTAssertEqual(store.effectiveDefault().id, "AIDER")
        XCTAssertFalse(aider.config.isProvablyUnlaunchable)
    }

    /// With nothing launchable to fall back to, the pointer is left alone rather
    /// than invented — the launch path surfaces the decline (A1).
    func testAllUnlaunchableLeavesPointerAlone() throws {
        let broken = SavedAgentConfig(id: "BROKEN", name: "Aider", order: 0,
            config: AgentLaunchConfig(harness: "custom", command: "   "))
        try store.write(AgentConfigLibraryFile(
            configs: [broken],
            default: AgentConfigDefault(mode: .pinned, configId: "BROKEN")))
        XCTAssertEqual(store.current.default.configId, "BROKEN")
        XCTAssertEqual(store.effectiveDefault().id, "BROKEN")
    }

    func testSetDefaultRefusesUnlaunchableConfig() throws {
        let good = SavedAgentConfig(id: "GOOD", name: "Codex", order: 0,
            config: AgentLaunchConfig(harness: "codex"))
        let broken = SavedAgentConfig(id: "BROKEN", name: "Aider", order: 1,
            config: AgentLaunchConfig(harness: "custom"))
        try store.write(AgentConfigLibraryFile(
            configs: [good, broken],
            default: AgentConfigDefault(mode: .pinned, configId: "GOOD")))
        XCTAssertThrowsError(try store.setDefault(configId: "BROKEN")) { error in
            XCTAssertEqual(error as? AgentConfigLibraryStore.StoreError,
                           .configUnlaunchable("BROKEN"))
        }
        XCTAssertEqual(store.current.default.configId, "GOOD")  // pointer untouched
    }

    // MARK: - AC #4: mutators + file-is-the-contract

    func testAddAssignsIdAndOrderAndPersists() throws {
        try store.write(.factory)
        let added = try store.add(SavedAgentConfig(
            id: "", name: "Cheap router", order: 999,
            config: AgentLaunchConfig(harness: "omp", model: "deepseek/deepseek-chat-v3.1")))
        XCTAssertFalse(added.id.isEmpty)
        XCTAssertEqual(added.order, 1)  // next slot after the seed's order 0

        // A fresh store instance over the same dir sees it (recompute-on-access).
        let reopened = AgentConfigLibraryStore(directory: tempDir)
        XCTAssertEqual(reopened.current.configs.count, 2)
        XCTAssertTrue(reopened.current.configs.contains { $0.name == "Cheap router" })
    }

    func testRemoveReindexesAndRepointsDefault() throws {
        let a = SavedAgentConfig(id: "A", name: "A", order: 0, config: AgentLaunchConfig(harness: "codex"))
        let b = SavedAgentConfig(id: "B", name: "B", order: 1, config: AgentLaunchConfig(harness: "grok"))
        try store.write(AgentConfigLibraryFile(
            configs: [a, b], default: AgentConfigDefault(mode: .pinned, configId: "A")))
        try store.remove(id: "A")
        let file = store.current
        XCTAssertEqual(file.configs.count, 1)
        XCTAssertEqual(file.configs[0].id, "B")
        XCTAssertEqual(file.configs[0].order, 0)  // reindexed dense
        XCTAssertEqual(file.default.configId, "B")  // repointed off the removed pin
    }

    func testRemoveLastConfigReseedsFactory() throws {
        let a = SavedAgentConfig(id: "A", name: "A", order: 0, config: AgentLaunchConfig(harness: "codex"))
        try store.write(AgentConfigLibraryFile(
            configs: [a], default: AgentConfigDefault(mode: .pinned, configId: "A")))
        try store.remove(id: "A")
        let file = store.current
        XCTAssertEqual(file.configs.count, 1)
        XCTAssertEqual(file.configs[0].name, "Opus deep")
        XCTAssertTrue(file.hasResolvablePinnedDefault)
    }

    func testRemoveMissingThrows() throws {
        try store.write(.factory)
        XCTAssertThrowsError(try store.remove(id: "nope")) { error in
            XCTAssertEqual(error as? AgentConfigLibraryStore.StoreError,
                           .configNotFound("nope"))
        }
    }

    func testReorderReindexesSequence() throws {
        let configs = (0..<3).map { i in
            SavedAgentConfig(id: "C\(i)", name: "C\(i)", order: i, config: AgentLaunchConfig(harness: "codex"))
        }
        try store.write(AgentConfigLibraryFile(
            configs: configs, default: AgentConfigDefault(mode: .pinned, configId: "C0")))
        try store.reorder(id: "C0", to: 2)
        let ordered = store.current.configs.sorted { $0.order < $1.order }
        XCTAssertEqual(ordered.map { $0.id }, ["C1", "C2", "C0"])
        XCTAssertEqual(ordered.map { $0.order }, [0, 1, 2])
    }

    func testReorderOutOfRangeThrows() throws {
        try store.write(.factory)
        XCTAssertThrowsError(try store.reorder(id: AgentConfigLibraryFile.factorySeedConfigId, to: 5)) { error in
            XCTAssertEqual(error as? AgentConfigLibraryStore.StoreError, .indexOutOfRange(5))
        }
    }

    func testSetDefaultPins() throws {
        let a = SavedAgentConfig(id: "A", name: "A", order: 0, config: AgentLaunchConfig(harness: "codex"))
        let b = SavedAgentConfig(id: "B", name: "B", order: 1, config: AgentLaunchConfig(harness: "grok"))
        try store.write(AgentConfigLibraryFile(
            configs: [a, b], default: AgentConfigDefault(mode: .pinned, configId: "A")))
        try store.setDefault(configId: "B")
        XCTAssertEqual(store.current.default.mode, .pinned)
        XCTAssertEqual(store.current.default.configId, "B")
        XCTAssertEqual(store.effectiveDefault().id, "B")
    }

    func testSetDefaultMissingThrows() throws {
        try store.write(.factory)
        XCTAssertThrowsError(try store.setDefault(configId: "ghost")) { error in
            XCTAssertEqual(error as? AgentConfigLibraryStore.StoreError, .configNotFound("ghost"))
        }
    }

    func testRecordRecentPersists() throws {
        try store.write(.factory)
        let recent = RecentAgentConfig(
            configId: "CDX", harness: "codex", model: "gpt-5.2", effort: "high",
            observedAt: Date(timeIntervalSince1970: 1_768_000_000), source: "launch",
            fieldSources: ["model": "launch"])
        try store.recordRecent(recent)
        let reopened = AgentConfigLibraryStore(directory: tempDir)
        XCTAssertEqual(reopened.current.recent?.configId, "CDX")
        XCTAssertEqual(reopened.current.recent?.source, "launch")
        XCTAssertEqual(reopened.current.recent?.fieldSources?["model"], "launch")
        // Pin the store's fractional-seconds ISO-8601 date path directly.
        XCTAssertEqual(reopened.current.recent?.observedAt, recent.observedAt)
    }

    func testRemoveLastConfigReseedsEvenWhenPinDangles() throws {
        // A write()-composed document whose pinned id already dangles; removing
        // the only real config must still reseed (not leave configs empty).
        let a = SavedAgentConfig(id: "A", name: "A", order: 0, config: AgentLaunchConfig(harness: "codex"))
        try store.write(AgentConfigLibraryFile(
            configs: [a], default: AgentConfigDefault(mode: .pinned, configId: "DANGLING")))
        try store.remove(id: "A")
        let file = store.current
        XCTAssertFalse(file.configs.isEmpty)
        XCTAssertEqual(file.configs[0].name, "Opus deep")
        XCTAssertTrue(file.hasResolvablePinnedDefault)
    }

    // MARK: - Atomicity smoke

    func testSequentialSavesLeaveOneValidFile() throws {
        try store.write(.factory)
        try store.add(SavedAgentConfig(id: "", name: "One", order: 0, config: AgentLaunchConfig(harness: "codex")))
        try store.add(SavedAgentConfig(id: "", name: "Two", order: 0, config: AgentLaunchConfig(harness: "grok")))
        // Exactly one file, last write wins, decodes cleanly.
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(contents.filter { $0 == AgentConfigLibraryStore.fileName }.count, 1)
        XCTAssertEqual(store.current.configs.count, 3)
    }

    // MARK: - Id generator

    func testGeneratedIdsAreDistinctAnd26Chars() {
        let a = AgentConfigID.generate()
        let b = AgentConfigID.generate()
        XCTAssertEqual(a.count, 26)
        XCTAssertEqual(b.count, 26)
        XCTAssertNotEqual(a, b)
    }
}
