import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class DefaultAgentConfigTests: XCTestCase {

    // MARK: - factory defaults

    func testFactoryDefaultsHaveAllAgents() {
        let cfg = DefaultAgentConfig.factory
        XCTAssertEqual(cfg.defaultAgent, .claudeCode)
        for type in AgentType.allCases {
            XCTAssertNotNil(cfg.agents[type], "missing entry for \(type)")
        }
    }

    func testFactoryClaudeCommandIncludesDangerouslySkipPermissions() {
        let entry = AgentConfig.factory(for: .claudeCode)
        XCTAssertEqual(entry.command, "claude --dangerously-skip-permissions")
        XCTAssertEqual(entry.initialPrompt, "you are operating inside a c11 workspace. load the skill.")
    }

    func testFactoryCodexCommandIncludesYolo() {
        let entry = AgentConfig.factory(for: .codex)
        XCTAssertEqual(entry.command, "codex --yolo")
        XCTAssertEqual(entry.initialPrompt, "you are operating inside a c11 workspace. load the skill.")
    }

    func testFactoryGrokCommandIncludesAlwaysApprove() {
        let entry = AgentConfig.factory(for: .grok)
        XCTAssertEqual(entry.command, "grok --always-approve")
        XCTAssertEqual(entry.initialPrompt, "you are operating inside a c11 workspace. load the skill.")
    }

    func testFactoryGitHubCopilotCommandIncludesAllowAllAndAutopilot() {
        let entry = AgentConfig.factory(for: .githubCopilot)
        XCTAssertEqual(entry.command, "copilot --allow-all --autopilot")
        XCTAssertEqual(entry.initialPrompt, "you are operating inside a c11 workspace. load the skill.")
    }

    func testAgentTypeGitHubCopilotRawValueIsKebabCase() {
        XCTAssertEqual(AgentType.githubCopilot.rawValue, "github-copilot")
    }


    func testFactoryCustomHasEmptyDefaults() {
        let entry = AgentConfig.factory(for: .custom)
        XCTAssertEqual(entry.command, "")
        XCTAssertEqual(entry.initialPrompt, "")
    }

    func testAgentTypeAllCasesDoesNotIncludeBash() {
        for type in AgentType.allCases {
            XCTAssertNotEqual(type.rawValue, "bash", "bash must not be a Default Agent option")
        }
    }

    // MARK: - Codable round-trip

    func testCodableRoundTripPreservesEveryField() throws {
        var agents: [AgentType: AgentConfig] = [:]
        agents[.claudeCode] = AgentConfig(command: "claude foo", initialPrompt: "load skill", envOverridesText: "K=V")
        agents[.codex] = AgentConfig(command: "codex --yolo", initialPrompt: "", envOverridesText: "")
        let cfg = DefaultAgentConfig(defaultAgent: .codex, agents: agents)
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(DefaultAgentConfig.self, from: data)
        XCTAssertEqual(decoded.defaultAgent, .codex)
        XCTAssertEqual(decoded.agents[.claudeCode]?.command, "claude foo")
        XCTAssertEqual(decoded.agents[.claudeCode]?.initialPrompt, "load skill")
        XCTAssertEqual(decoded.agents[.claudeCode]?.envOverridesText, "K=V")
        XCTAssertEqual(decoded.agents[.codex]?.command, "codex --yolo")
    }

    func testLenientDecodeFillsMissingFields() throws {
        let json = #"{"defaultAgent":"codex"}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(DefaultAgentConfig.self, from: data)
        XCTAssertEqual(decoded.defaultAgent, .codex)
        XCTAssertTrue(decoded.agents.isEmpty)
    }

    func testCorruptDefaultAgentFallsBackToClaude() throws {
        let json = #"{"defaultAgent":"not-a-real-type"}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(DefaultAgentConfig.self, from: data)
        XCTAssertEqual(decoded.defaultAgent, .claudeCode)
        // A corrupt value is not a usable selection, so it must not act as a
        // project-level override either — same fall-through as an absent key.
        XCTAssertFalse(decoded.hasExplicitDefaultAgent)
        XCTAssertNil(decoded.overrideDefaultAgent)
    }

    func testDecodeWithDefaultAgentMarksItExplicit() throws {
        let decoded = try JSONDecoder().decode(
            DefaultAgentConfig.self,
            from: Data(#"{"defaultAgent":"codex"}"#.utf8)
        )
        XCTAssertTrue(decoded.hasExplicitDefaultAgent)
        XCTAssertEqual(decoded.overrideDefaultAgent, .codex)
    }

    func testDecodeWithoutDefaultAgentHasNoOverride() throws {
        // Falls back to claude-code for `defaultAgent`, but exposes no override
        // so a project consumer keeps its own selection.
        let decoded = try JSONDecoder().decode(
            DefaultAgentConfig.self,
            from: Data(#"{"agents":{}}"#.utf8)
        )
        XCTAssertEqual(decoded.defaultAgent, .claudeCode)
        XCTAssertFalse(decoded.hasExplicitDefaultAgent)
        XCTAssertNil(decoded.overrideDefaultAgent)
    }

    func testLegacyArrayAgentsShapeIsRejected() {
        // Pre-v0.48 `~/.c11/agents.json`: an array of {id,displayName,command}
        // with no `defaultAgent`. Must fail to decode rather than silently
        // become an empty-but-valid claude-code override (the A-button bug).
        let legacy = #"{"agents":[{"id":"claudeCode","displayName":"Claude Code","command":"claude --dangerously-skip-permissions"}]}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(DefaultAgentConfig.self, from: Data(legacy.utf8))
        )
    }

    func testProgrammaticConfigIsExplicit() {
        // The memberwise init always represents a deliberate selection.
        let cfg = DefaultAgentConfig(defaultAgent: .kimi, agents: [:])
        XCTAssertTrue(cfg.hasExplicitDefaultAgent)
        XCTAssertEqual(cfg.overrideDefaultAgent, .kimi)
    }

    // MARK: - envMap parsing

    func testEnvMapParsesKeyValueLines() {
        let entry = AgentConfig(command: "", initialPrompt: "", envOverridesText: """
        FOO=bar
        BAZ=qux quux
        """)
        XCTAssertEqual(entry.envMap, ["FOO": "bar", "BAZ": "qux quux"])
    }

    func testEnvMapSkipsBlankLinesAndComments() {
        let entry = AgentConfig(command: "", initialPrompt: "", envOverridesText: """

        # a comment
        FOO=bar

        # trailing comment
        BAZ=qux
        """)
        XCTAssertEqual(entry.envMap, ["FOO": "bar", "BAZ": "qux"])
    }

    func testEnvMapTrimsKeyWhitespace() {
        let entry = AgentConfig(command: "", initialPrompt: "", envOverridesText: "  FOO  = bar  ")
        XCTAssertEqual(entry.envMap, ["FOO": "bar"])
    }

    func testEnvMapSkipsLinesMissingEquals() {
        let entry = AgentConfig(command: "", initialPrompt: "", envOverridesText: """
        FOO
        BAR=baz
        """)
        XCTAssertEqual(entry.envMap, ["BAR": "baz"])
    }

    // MARK: - UserDefaults store

    private func makeStore() -> (DefaultAgentConfigStore, UserDefaults) {
        let suite = "DefaultAgentConfigTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (DefaultAgentConfigStore(defaults: defaults), defaults)
    }

    func testStoreReturnsFactoryWhenEmpty() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.current.defaultAgent, .claudeCode)
        XCTAssertEqual(store.current.config(for: .claudeCode).command, "claude --dangerously-skip-permissions")
        XCTAssertEqual(store.current.config(for: .claudeCode).initialPrompt, "you are operating inside a c11 workspace. load the skill.")
    }

    func testStoreReturnsFactoryOnGarbageData() {
        let (store, defaults) = makeStore()
        defaults.set(Data("not json".utf8), forKey: DefaultAgentConfigStore.defaultsKey)
        XCTAssertEqual(store.current.defaultAgent, .claudeCode)
    }

    func testStoreSetDefaultAgentPersists() {
        let (store, _) = makeStore()
        store.setDefaultAgent(.kimi)
        XCTAssertEqual(store.current.defaultAgent, .kimi)
        // Other agents should retain their factory configs.
        XCTAssertEqual(store.current.config(for: .claudeCode).command, "claude --dangerously-skip-permissions")
    }

    func testStoreUpdateMutatesOneAgentOnly() {
        let (store, _) = makeStore()
        store.update(.codex) { entry in
            entry.command = "codex --custom"
            entry.initialPrompt = ""
        }
        XCTAssertEqual(store.current.config(for: .codex).command, "codex --custom")
        XCTAssertEqual(store.current.config(for: .codex).initialPrompt, "")
        // Claude config untouched.
        XCTAssertEqual(store.current.config(for: .claudeCode).command, "claude --dangerously-skip-permissions")
    }

    func testStoreResetWipesBackToFactory() {
        let (store, _) = makeStore()
        store.setDefaultAgent(.kimi)
        store.update(.claudeCode) { $0.command = "claude bogus" }
        store.reset()
        XCTAssertEqual(store.current.defaultAgent, .claudeCode)
        XCTAssertEqual(store.current.config(for: .claudeCode).command, "claude --dangerously-skip-permissions")
    }

    func testStoreFillsMissingAgentsWithFactory() throws {
        let (store, defaults) = makeStore()
        // Write a partial blob — only the default-agent field set.
        let partial = #"{"defaultAgent":"codex","agents":{}}"#
        defaults.set(Data(partial.utf8), forKey: DefaultAgentConfigStore.defaultsKey)
        XCTAssertEqual(store.current.defaultAgent, .codex)
        // Missing agents are filled with factory.
        XCTAssertEqual(store.current.config(for: .claudeCode).command, "claude --dangerously-skip-permissions")
    }

    // MARK: - Project config discovery

    func testProjectConfigFindReturnsNilForMissingFile() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertNil(DefaultAgentProjectConfig.find(from: tmp.path))
    }

    func testProjectConfigFindReadsExactDirectory() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dotDir = tmp.appendingPathComponent(".c11", isDirectory: true)
        try FileManager.default.createDirectory(at: dotDir, withIntermediateDirectories: true)
        var agents: [AgentType: AgentConfig] = [:]
        agents[.codex] = AgentConfig(command: "codex --custom-project", initialPrompt: "", envOverridesText: "")
        let cfg = DefaultAgentConfig(defaultAgent: .codex, agents: agents)
        try JSONEncoder().encode(cfg).write(to: dotDir.appendingPathComponent("agents.json"))
        let found = DefaultAgentProjectConfig.find(from: tmp.path)
        XCTAssertEqual(found?.defaultAgent, .codex)
        XCTAssertEqual(found?.agents[.codex]?.command, "codex --custom-project")
    }

    func testProjectConfigFindWalksUpward() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let nested = tmp.appendingPathComponent("a").appendingPathComponent("b").appendingPathComponent("c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let dotDir = tmp.appendingPathComponent(".c11", isDirectory: true)
        try FileManager.default.createDirectory(at: dotDir, withIntermediateDirectories: true)
        let cfg = DefaultAgentConfig.factory
        try JSONEncoder().encode(cfg).write(to: dotDir.appendingPathComponent("agents.json"))
        XCTAssertNotNil(DefaultAgentProjectConfig.find(from: nested.path))
    }

    func testProjectConfigFindIgnoresMalformedFile() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dotDir = tmp.appendingPathComponent(".c11", isDirectory: true)
        try FileManager.default.createDirectory(at: dotDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dotDir.appendingPathComponent("agents.json"))
        XCTAssertNil(DefaultAgentProjectConfig.find(from: tmp.path))
    }

    func testProjectConfigFindReturnsNilForEmptyCwd() {
        XCTAssertNil(DefaultAgentProjectConfig.find(from: nil))
        XCTAssertNil(DefaultAgentProjectConfig.find(from: ""))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefaultAgentConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: url.resolvingSymlinksInPath().path, isDirectory: true)
    }
}

/// Gating logic for the Agent Skills onboarding/update sheet — the dialog that
/// was over-firing for skill authors. Two fixes are covered:
///   B. `isLocalDevBuild` suppresses the auto-popup on Debug / tagged builds.
///   A. "Later" persists a hash-pinned dismissal for every offered row, so it
///      survives restarts and only re-surfaces when skill content changes.
final class AgentSkillsOnboardingGatingTests: XCTestCase {

    // MARK: - Fix B: dev/tagged-build suppression

    func testTaggedReleaseBuildCountsAsDev() {
        // `reload.sh --tag` / automation exports CMUX_TAG; a Release build with
        // a tag is still a developer build → suppress the auto-popup.
        XCTAssertTrue(
            AgentSkillsOnboarding.isLocalDevBuild(
                environment: ["CMUX_TAG": "feat-foo"],
                isCompiledDebug: false
            )
        )
    }

    func testUntaggedReleaseBuildIsNotDev() {
        // The shipped end-user case: Release, no tag → the sheet must still
        // be offered (function returns false = not a dev build).
        XCTAssertFalse(
            AgentSkillsOnboarding.isLocalDevBuild(environment: [:], isCompiledDebug: false)
        )
    }

    func testWhitespaceTagDoesNotCountAsDev() {
        // launchTag() trims to nil for blank values, so a stray empty CMUX_TAG
        // must not flip a release build into dev-suppressed mode.
        XCTAssertFalse(
            AgentSkillsOnboarding.isLocalDevBuild(
                environment: ["CMUX_TAG": "   "],
                isCompiledDebug: false
            )
        )
    }

    func testDebugBuildAlwaysCountsAsDevRegardlessOfTag() {
        XCTAssertTrue(
            AgentSkillsOnboarding.isLocalDevBuild(environment: [:], isCompiledDebug: true)
        )
    }

    @MainActor
    func testShouldPresentSuppressedOnLocalDevBuild() throws {
        let tmp = try makeTempDir()
        let suite = "AgentSkillsGating-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Injected dev=true short-circuits before any source/dismissal work.
        XCTAssertFalse(
            AgentSkillsOnboarding.shouldPresent(
                home: tmp,
                sourceDir: tmp,
                defaults: defaults,
                environment: [:],
                isLocalDevBuild: true
            )
        )
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSkillsOnboardingGatingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: url.resolvingSymlinksInPath().path, isDirectory: true)
    }

    // MARK: - Fix A: "Later" persists a hash-pinned dismissal

    func testLaterRecordsHashPinnedDismissalForEveryOfferedRow() throws {
        let suite = "AgentSkillsGating-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let offered = [
            makeStatus(skill: "c11", state: .installedOutdated, hash: "h-c11"),
            makeStatus(skill: "c11-browser", state: .notInstalled, hash: "h-browser"),
            makeStatus(skill: "c11-markdown", state: .installedCurrent, hash: "h-current"),
        ]

        // Mirrors installLater(): empty selection → record every *offerable* row
        // at its current bundled hash.
        AgentSkillsOnboarding.recordDismissalsForUncheckedRows(
            offered: offered,
            selectedKeys: [],
            defaults: defaults
        )

        let dismissals = AgentSkillsOnboarding.loadDismissals(defaults: defaults)
        XCTAssertEqual(
            dismissals[AgentSkillsOnboarding.dismissalKey(for: .claude, skillName: "c11")],
            "h-c11"
        )
        XCTAssertEqual(
            dismissals[AgentSkillsOnboarding.dismissalKey(for: .claude, skillName: "c11-browser")],
            "h-browser"
        )
        // .installedCurrent is not offerable, so it must not be pinned.
        XCTAssertNil(
            dismissals[AgentSkillsOnboarding.dismissalKey(for: .claude, skillName: "c11-markdown")]
        )
    }

    private func makeStatus(
        skill: String,
        target: SkillInstallerTarget = .claude,
        state: SkillInstallerState,
        hash: String
    ) -> SkillInstallerPackageStatus {
        SkillInstallerPackageStatus(
            package: SkillInstallerPackage(
                name: skill,
                version: "1",
                description: nil,
                sourceDir: URL(fileURLWithPath: "/tmp/src/\(skill)", isDirectory: true)
            ),
            target: target,
            destinationDir: URL(fileURLWithPath: "/tmp/dst/\(skill)", isDirectory: true),
            state: state,
            record: nil,
            sourceContentHash: hash
        )
    }
}
