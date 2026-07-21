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

    /// A hand-authored §2.1 fixture: follow-recent default, a blank-slate
    /// (`replace` + "") config, `field_sources`, and `initial_prompt`/`env`
    /// overlays. The `systemPrompt` key is camelCase exactly as §2.1 writes it.
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
        XCTAssertEqual(file.default.mode, .followRecent)

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

    func testEffectiveDefaultFollowRecentReturnsRecentConfig() throws {
        let opus = SavedAgentConfig(id: "OPUS", name: "Opus deep", order: 0,
            config: AgentLaunchConfig(harness: "claude-code", model: "opus", effort: "high"))
        let codex = SavedAgentConfig(id: "CDX", name: "Codex hi", order: 1,
            config: AgentLaunchConfig(harness: "codex", model: "gpt-5.2", effort: "high"))
        let file = AgentConfigLibraryFile(
            configs: [opus, codex],
            default: AgentConfigDefault(mode: .followRecent, configId: "OPUS"),
            recent: RecentAgentConfig(configId: "CDX", harness: "codex", model: "gpt-5.2")
        )
        try store.write(file)
        let resolved = store.effectiveDefault()
        XCTAssertEqual(resolved.id, "CDX")
        XCTAssertEqual(resolved.config.harness, "codex")
    }

    func testEffectiveDefaultFollowRecentNilRecentFallsBackToPinned() throws {
        let opus = SavedAgentConfig(id: "OPUS", name: "Opus deep", order: 0,
            config: AgentLaunchConfig(harness: "claude-code", model: "opus"))
        let file = AgentConfigLibraryFile(
            configs: [opus],
            default: AgentConfigDefault(mode: .followRecent, configId: "OPUS"),
            recent: nil
        )
        try store.write(file)
        XCTAssertEqual(store.effectiveDefault().id, "OPUS")
    }

    func testEffectiveDefaultFollowRecentSynthesizesWhenConfigMissing() throws {
        let opus = SavedAgentConfig(id: "OPUS", name: "Opus deep", order: 0,
            config: AgentLaunchConfig(harness: "claude-code", model: "opus"))
        // recent points at a config id no longer in the library, but carries axes.
        let file = AgentConfigLibraryFile(
            configs: [opus],
            default: AgentConfigDefault(mode: .followRecent, configId: "OPUS"),
            recent: RecentAgentConfig(configId: "GONE", harness: "codex", model: "gpt-5.2", effort: "high")
        )
        try store.write(file)
        let resolved = store.effectiveDefault()
        XCTAssertEqual(resolved.config.harness, "codex")
        XCTAssertEqual(resolved.config.model, "gpt-5.2")
        XCTAssertEqual(resolved.config.effort, "high")
        // Synthesized transient: no library order, blank id (the dangling
        // recent.config_id is not carried through as a re-resolvable id).
        XCTAssertEqual(resolved.order, -1)
        XCTAssertEqual(resolved.id, "")
        XCTAssertTrue(resolved.name.contains("gpt-5.2"))
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

    func testSetDefaultPinsAndSetModeToggles() throws {
        let a = SavedAgentConfig(id: "A", name: "A", order: 0, config: AgentLaunchConfig(harness: "codex"))
        let b = SavedAgentConfig(id: "B", name: "B", order: 1, config: AgentLaunchConfig(harness: "grok"))
        try store.write(AgentConfigLibraryFile(
            configs: [a, b], default: AgentConfigDefault(mode: .followRecent, configId: "A")))
        try store.setDefault(configId: "B")
        XCTAssertEqual(store.current.default.mode, .pinned)  // setDefault forces pinned
        XCTAssertEqual(store.current.default.configId, "B")

        try store.setMode(.followRecent)
        XCTAssertEqual(store.current.default.mode, .followRecent)
        XCTAssertEqual(store.current.default.configId, "B")  // config unchanged
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
