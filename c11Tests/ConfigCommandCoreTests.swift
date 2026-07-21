import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure-logic tests for the `c11 config` runtime (C11-180). No Workspace/
/// TabManager construction — stores rooted at an injected temp dir, stats clock
/// pinned. c11LogicTests-only (the `DefaultAgentLaunchCompositionTests`
/// precedent).
final class ConfigCommandCoreTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfgcore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeCore(now: Date = Date(timeIntervalSince1970: 1_770_000_000)) -> (ConfigCommandCore, AgentConfigLibraryStore, AgentLaunchStatsStore) {
        let library = AgentConfigLibraryStore(directory: tmp)
        let stats = AgentLaunchStatsStore(directory: tmp, clock: { now })
        return (ConfigCommandCore(library: library, stats: stats), library, stats)
    }

    // MARK: list / factory

    func testListEmptyReturnsFactorySeed() {
        let (core, _, _) = makeCore()
        let result = core.list()
        XCTAssertEqual(result.file.configs.count, 1)
        XCTAssertEqual(result.file.configs.first?.name, "Opus deep")
        let json = result.jsonObject()
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertNotNil(json["configs"])
        XCTAssertNotNil(json["default"])
    }

    func testSaveThenListRoundTrip() throws {
        let (core, _, _) = makeCore()
        let saved = try core.save(name: "Codex hi", fields: ConfigFields(harness: "codex", model: "gpt-5.2", effort: "high"))
        XCTAssertFalse(saved.id.isEmpty)
        let names = core.list().file.configs.map(\.name)
        XCTAssertTrue(names.contains("Codex hi"))
        let stored = try core.resolveConfig(nameOrId: "Codex hi")
        XCTAssertEqual(stored.config.model, "gpt-5.2")
        XCTAssertEqual(stored.config.effort, "high")
    }

    // MARK: save validation

    func testSaveRejectsUnknownHarness() {
        let (core, _, _) = makeCore()
        XCTAssertThrowsError(try core.save(name: "x", fields: ConfigFields(harness: "nonsense-harness"))) {
            XCTAssertEqual(($0 as? ConfigCoreError)?.code, "invalid_harness")
        }
    }

    func testSaveRejectsInvalidEffort() {
        let (core, _, _) = makeCore()
        // claude-code declares effort values low..max; "turbo" is not one.
        XCTAssertThrowsError(try core.save(name: "x", fields: ConfigFields(harness: "claude-code", effort: "turbo"))) {
            XCTAssertEqual(($0 as? ConfigCoreError)?.code, "invalid_effort")
        }
    }

    func testSaveRejectsEffortOnHarnessWithoutEffortAxis() {
        let (core, _, _) = makeCore()
        // grok declares no effort flag (effortValues == nil) → effort unsupported.
        // (codex has a free-form effort axis, so it is NOT the right harness here.)
        XCTAssertThrowsError(try core.save(name: "x", fields: ConfigFields(harness: "grok", effort: "high"))) {
            XCTAssertEqual(($0 as? ConfigCoreError)?.code, "effort_flag_unsupported")
        }
    }

    func testSaveAcceptsFreeFormEffortOnCodex() throws {
        let (core, _, _) = makeCore()
        // codex has a configKV effort axis with no fixed value set → any accepted.
        let saved = try core.save(name: "cdx", fields: ConfigFields(harness: "codex", effort: "high"))
        XCTAssertEqual(saved.config.effort, "high")
    }

    func testSaveRejectsInvalidSystemPromptMode() {
        let (core, _, _) = makeCore()
        XCTAssertThrowsError(try core.save(name: "x", fields: ConfigFields(harness: "claude-code", systemPromptMode: "sideways"))) {
            XCTAssertEqual(($0 as? ConfigCoreError)?.code, "invalid_system_prompt_mode")
        }
    }

    func testSaveBlankSlateSystemPromptPersists() throws {
        let (core, _, _) = makeCore()
        let saved = try core.save(name: "Greg", fields: ConfigFields(harness: "claude-code", systemPromptMode: "replace", systemPromptText: ""))
        XCTAssertEqual(saved.config.systemPrompt?.mode, .replace)
        XCTAssertEqual(saved.config.systemPrompt?.text, "")
    }

    // MARK: edit

    func testEditChangesOnlySuppliedFieldsAndPreservesId() throws {
        let (core, _, _) = makeCore()
        let saved = try core.save(name: "A", fields: ConfigFields(harness: "claude-code", model: "opus", effort: "high"))
        let edited = try core.edit(nameOrId: "A", fields: ConfigFields(model: "sonnet"))
        XCTAssertEqual(edited.id, saved.id)
        XCTAssertEqual(edited.config.model, "sonnet")
        XCTAssertEqual(edited.config.effort, "high")   // untouched
    }

    func testEditEmptyStringClearsToInherit() throws {
        let (core, _, _) = makeCore()
        _ = try core.save(name: "A", fields: ConfigFields(harness: "claude-code", model: "opus", effort: "high"))
        let edited = try core.edit(nameOrId: "A", fields: ConfigFields(effort: ""))
        XCTAssertNil(edited.config.effort)
    }

    func testEditUnknownRefThrowsNotFound() {
        let (core, _, _) = makeCore()
        XCTAssertThrowsError(try core.edit(nameOrId: "ghost", fields: ConfigFields(model: "x"))) {
            XCTAssertEqual(($0 as? ConfigCoreError)?.code, "config_not_found")
        }
    }

    // MARK: rm / reorder

    func testRemoveById() throws {
        let (core, _, _) = makeCore()
        let saved = try core.save(name: "A", fields: ConfigFields(harness: "claude-code"))
        _ = try core.remove(nameOrId: saved.id)
        XCTAssertFalse(core.list().file.configs.contains { $0.id == saved.id })
    }

    func testReorderOutOfRangeThrows() throws {
        let (core, _, _) = makeCore()
        _ = try core.save(name: "A", fields: ConfigFields(harness: "claude-code"))
        XCTAssertThrowsError(try core.reorder(nameOrId: "A", to: 99)) {
            XCTAssertEqual(($0 as? ConfigCoreError)?.code, "index_out_of_range")
        }
    }

    // MARK: default

    func testSetDefaultPins() throws {
        let (core, library, _) = makeCore()
        let saved = try core.save(name: "Codex", fields: ConfigFields(harness: "codex", model: "gpt-5.2"))
        _ = try core.setDefault(nameOrId: "Codex")
        XCTAssertEqual(library.current.default.mode, .pinned)
        XCTAssertEqual(library.current.default.configId, saved.id)
    }

    func testFollowRecentSetsModeOnly() throws {
        let (core, library, _) = makeCore()
        let pinnedId = library.current.default.configId
        try core.setFollowRecent()
        XCTAssertEqual(library.current.default.mode, .followRecent)
        XCTAssertEqual(library.current.default.configId, pinnedId)   // pin unchanged
    }

    func testPinCurrentSnapshotsRecentAndPins() throws {
        let (core, library, _) = makeCore()
        try library.recordRecent(RecentAgentConfig(configId: nil, harness: "codex", model: "gpt-5.2", effort: nil, observedAt: Date(), source: "launch"))
        let pinned = try core.pinCurrent(name: nil)
        XCTAssertEqual(pinned.config.harness, "codex")
        XCTAssertEqual(pinned.config.model, "gpt-5.2")
        XCTAssertEqual(library.current.default.configId, pinned.id)
        XCTAssertEqual(library.current.default.mode, .pinned)
    }

    func testPinCurrentWithNoRecentThrows() {
        let (core, _, _) = makeCore()
        XCTAssertThrowsError(try core.pinCurrent(name: nil)) {
            XCTAssertEqual(($0 as? ConfigCoreError)?.code, "no_recent")
        }
    }

    // MARK: resolve

    func testResolveAmbiguousName() throws {
        let (core, _, _) = makeCore()
        _ = try core.save(name: "dup", fields: ConfigFields(harness: "claude-code"))
        _ = try core.save(name: "dup", fields: ConfigFields(harness: "codex"))
        XCTAssertThrowsError(try core.resolveConfig(nameOrId: "dup")) {
            XCTAssertEqual(($0 as? ConfigCoreError)?.code, "ambiguous_name")
        }
    }

    func testResolveNotFoundListsAvailable() {
        let (core, _, _) = makeCore()
        XCTAssertThrowsError(try core.resolveConfig(nameOrId: "missing")) {
            XCTAssertEqual(($0 as? ConfigCoreError)?.code, "config_not_found")
        }
    }

    // MARK: buildLaunchRequest

    func testBuildLaunchRequestMapsRecipeAndPromptFallback() {
        let cfg = AgentLaunchConfig(
            harness: "claude-code",
            model: "opus",
            effort: "high",
            systemPrompt: SystemPromptSetting(mode: .replace, text: ""),
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "hello from config",
            env: ["K": "V"]
        )
        let saved = SavedAgentConfig(id: "id1", name: "n", order: 0, config: cfg)
        // No prompt override → falls back to config.initialPrompt.
        let r1 = ConfigCommandCore.buildLaunchRequest(from: saved, promptOverride: nil)
        XCTAssertEqual(r1.kind, "claude-code")
        XCTAssertEqual(r1.model, "opus")
        XCTAssertEqual(r1.effort, "high")
        XCTAssertEqual(r1.systemPrompt?.mode, .replace)
        XCTAssertEqual(r1.commandOverride, "claude --dangerously-skip-permissions")
        XCTAssertEqual(r1.extraEnv, ["K": "V"])
        XCTAssertEqual(r1.prompt, "hello from config")
        // Override wins.
        let r2 = ConfigCommandCore.buildLaunchRequest(from: saved, promptOverride: "override")
        XCTAssertEqual(r2.prompt, "override")
    }

    // MARK: window / axis parsing

    func testParseWindowAcceptsCanonicalAndDays() throws {
        XCTAssertEqual(try ConfigCommandCore.parseWindow(nil), .all)
        XCTAssertEqual(try ConfigCommandCore.parseWindow("today"), .today)
        XCTAssertEqual(try ConfigCommandCore.parseWindow("all"), .all)
        XCTAssertEqual(try ConfigCommandCore.parseWindow("30d"), .days(30))
        XCTAssertEqual(try ConfigCommandCore.parseWindow("7d"), .days(7))
    }

    func testParseWindowRejectsGarbage() {
        for bad in ["30", "week", "-5d", "0d"] {
            XCTAssertThrowsError(try ConfigCommandCore.parseWindow(bad)) {
                XCTAssertEqual(($0 as? ConfigCoreError)?.code, "invalid_window", "for \(bad)")
            }
        }
    }

    func testParseAxisValidAndInvalid() throws {
        XCTAssertEqual(try ConfigCommandCore.parseAxis(nil), .model)
        XCTAssertEqual(try ConfigCommandCore.parseAxis("provider"), .provider)
        XCTAssertThrowsError(try ConfigCommandCore.parseAxis("cost")) {
            XCTAssertEqual(($0 as? ConfigCoreError)?.code, "invalid_axis")
        }
    }

    // MARK: parseLaunchInputs

    func testParseLaunchInputsPlacementConflict() {
        XCTAssertThrowsError(try ConfigCommandCore.parseLaunchInputs(
            nameOrId: "a", pane: "pane:1", workspace: nil, newWorkspace: true,
            cwd: nil, prompt: nil, promptFile: nil, promptFileContents: nil, json: false)) {
            XCTAssertEqual(($0 as? ConfigCoreError)?.code, "placement_conflict")
        }
    }

    func testParseLaunchInputsPromptPrecedence() throws {
        let inputs = try ConfigCommandCore.parseLaunchInputs(
            nameOrId: "a", pane: nil, workspace: nil, newWorkspace: false,
            cwd: nil, prompt: "inline", promptFile: "/x", promptFileContents: "fromfile", json: false)
        XCTAssertEqual(inputs.prompt, "inline")   // inline wins over file
    }

    // MARK: stats

    func testStatsAllAndTodayWindows() {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let library = AgentConfigLibraryStore(directory: tmp)
        let stats = AgentLaunchStatsStore(directory: tmp, clock: { now })
        stats.recordLaunch(ResolvedLaunch(harness: "claude-code", model: "opus"), source: .aButton)
        stats.recordLaunch(ResolvedLaunch(harness: "claude-code", model: "opus"), source: .aButton)
        stats.recordLaunch(ResolvedLaunch(harness: "codex", model: "gpt-5.2"), source: .launchAgent)
        stats.flush()
        let core = ConfigCommandCore(library: library, stats: stats)
        let all = core.statsView(window: .all, by: .model, now: now)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.tally.first?.key, "opus")   // most-frequent first
        XCTAssertEqual(all.tally.first?.count, 2)
        let byHarness = core.statsView(window: .all, by: .harness, now: now)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: byHarness.tally.map { ($0.key, $0.count) })["claude-code"], 2)
        let json = all.jsonObject()
        XCTAssertEqual(json["count"] as? Int, 3)
    }
}

/// Planner-side coverage for the C11-180 `commandOverride` addition.
final class AgentLaunchRequestCommandOverrideTests: XCTestCase {

    func testCommandOverrideReplacesBaseAndStillInjectsModel() {
        let base = DefaultAgentConfig.factory
        let request = AgentLaunchRequest(
            kind: "claude-code",
            model: "sonnet",
            commandOverride: "claude --dangerously-skip-permissions"
        )
        guard case .success(let plan) = AgentLaunchPlanner.plan(
            request: request, userDefault: base, projectConfig: nil, userTemplate: nil
        ) else {
            return XCTFail("plan failed")
        }
        XCTAssertTrue(plan.launchLine.hasPrefix("claude --dangerously-skip-permissions"))
        XCTAssertTrue(plan.launchLine.contains("sonnet"), "overlay model still injects: \(plan.launchLine)")
    }

    func testEmptyCommandOverrideFallsBackToBase() {
        let base = DefaultAgentConfig.factory
        let withOverride = AgentLaunchRequest(kind: "claude-code", commandOverride: "")
        let withoutOverride = AgentLaunchRequest(kind: "claude-code")
        guard case .success(let a) = AgentLaunchPlanner.plan(request: withOverride, userDefault: base, projectConfig: nil, userTemplate: nil),
              case .success(let b) = AgentLaunchPlanner.plan(request: withoutOverride, userDefault: base, projectConfig: nil, userTemplate: nil) else {
            return XCTFail("plan failed")
        }
        XCTAssertEqual(a.launchLine, b.launchLine)   // empty override → byte-identical
    }
}
