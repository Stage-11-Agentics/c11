import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Behavioral tests for the saved-config **overlay** composition (C11-179,
/// design §1.3): `DefaultAgentResolver.mergeOverlay(_:onto:)` /
/// `resolveOverlay(...)` and the resolved-default tooltip formatter. The overlay
/// is layered over the harness Settings base; a pure-inherit overlay reproduces
/// today's launch byte-for-byte, and the existing per-field flag injection
/// (model/effort/system-prompt, with hardcoded-in-command detection) applies to
/// the overlaid values.
///
/// Pure logic — no `Workspace`/`TabManager`/AppKit construction (the documented
/// NSApp-nil xctest crash), so these run under `c11LogicTests`, matching
/// `DefaultAgentLaunchCompositionTests`.
final class AgentLaunchOverlayCompositionTests: XCTestCase {

    // A claude-code Settings base with a distinctive command so inherit-vs-
    // override is unambiguous. claude-code declares model/effort/system-prompt
    // axes, so every field exercises real injection.
    private func claudeBase(
        command: String = "claude --dangerously-skip-permissions",
        initialPrompt: String = "",
        env: String = "",
        model: String = "opus",
        effort: String = "",
        systemPrompt: SystemPromptSetting? = nil
    ) -> AgentConfig {
        AgentConfig(
            command: command,
            initialPrompt: initialPrompt,
            envOverridesText: env,
            model: model,
            effort: effort,
            systemPrompt: systemPrompt
        )
    }

    private func overlay(
        harness: String = "claude-code",
        model: String? = nil,
        effort: String? = nil,
        systemPrompt: SystemPromptSetting? = nil,
        command: String? = nil,
        initialPrompt: String? = nil,
        env: [String: String]? = nil
    ) -> AgentLaunchConfig {
        AgentLaunchConfig(
            harness: harness,
            model: model,
            effort: effort,
            systemPrompt: systemPrompt,
            command: command,
            initialPrompt: initialPrompt,
            env: env
        )
    }

    private func saved(_ config: AgentLaunchConfig, name: String = "Test", id: String = "TESTID") -> SavedAgentConfig {
        SavedAgentConfig(id: id, name: name, order: 0, config: config)
    }

    // MARK: - Per-field precedence ladder (design §1.3): overlay wins, nil inherits

    func testCommandOverlayWinsElseInheritsBase() {
        let base = claudeBase(command: "base-cmd")
        XCTAssertEqual(DefaultAgentResolver.mergeOverlay(overlay(command: "over-cmd"), onto: base).config.command, "over-cmd")
        XCTAssertEqual(DefaultAgentResolver.mergeOverlay(overlay(command: nil), onto: base).config.command, "base-cmd")
    }

    func testInitialPromptOverlayWinsElseInheritsBase() {
        let base = claudeBase(initialPrompt: "base-prompt")
        XCTAssertEqual(DefaultAgentResolver.mergeOverlay(overlay(initialPrompt: "over-prompt"), onto: base).config.initialPrompt, "over-prompt")
        XCTAssertEqual(DefaultAgentResolver.mergeOverlay(overlay(initialPrompt: nil), onto: base).config.initialPrompt, "base-prompt")
    }

    func testModelOverlayWinsElseInheritsBase() {
        let base = claudeBase(model: "opus")
        XCTAssertEqual(DefaultAgentResolver.mergeOverlay(overlay(model: "sonnet"), onto: base).config.model, "sonnet")
        XCTAssertEqual(DefaultAgentResolver.mergeOverlay(overlay(model: nil), onto: base).config.model, "opus")
    }

    func testEffortOverlayWinsElseInheritsBase() {
        let base = claudeBase(effort: "high")
        XCTAssertEqual(DefaultAgentResolver.mergeOverlay(overlay(effort: "low"), onto: base).config.effort, "low")
        XCTAssertEqual(DefaultAgentResolver.mergeOverlay(overlay(effort: nil), onto: base).config.effort, "high")
    }

    func testSystemPromptOverlayWinsElseInheritsBase() {
        let baseSetting = SystemPromptSetting(mode: .append, text: "base")
        let base = claudeBase(systemPrompt: baseSetting)
        let over = SystemPromptSetting(mode: .replace, text: "over")
        XCTAssertEqual(DefaultAgentResolver.mergeOverlay(overlay(systemPrompt: over), onto: base).config.systemPrompt, over)
        XCTAssertEqual(DefaultAgentResolver.mergeOverlay(overlay(systemPrompt: nil), onto: base).config.systemPrompt, baseSetting)
    }

    // MARK: - env merge: factory ◁ settings ◁ config, overlay wins per key

    func testEnvMergeOverlayWinsPerKeyAndUnionsKeys() {
        let base = claudeBase(env: "A=base_a\nB=base_b")
        let merged = DefaultAgentResolver.mergeOverlay(
            overlay(env: ["B": "over_b", "C": "over_c"]),
            onto: base
        ).env
        XCTAssertEqual(merged["A"], "base_a", "base-only key preserved")
        XCTAssertEqual(merged["B"], "over_b", "overlay wins on collision")
        XCTAssertEqual(merged["C"], "over_c", "overlay-only key added")
    }

    func testEnvNilOverlayInheritsBaseEnv() {
        let base = claudeBase(env: "A=base_a")
        let merged = DefaultAgentResolver.mergeOverlay(overlay(env: nil), onto: base).env
        XCTAssertEqual(merged, ["A": "base_a"])
    }

    func testMergedConfigEnvMapIsBaseOnlyNotOverlayMerged() {
        // Contract (MINOR-3): merged env lives ONLY in the returned dict; the
        // merged AgentConfig.envMap reflects the base and must not be read for
        // the resolved env.
        let base = claudeBase(env: "A=base_a")
        let result = DefaultAgentResolver.mergeOverlay(overlay(env: ["C": "over_c"]), onto: base)
        XCTAssertNil(result.config.envMap["C"], "overlay env must not leak into merged.envMap")
        XCTAssertEqual(result.env["C"], "over_c", "resolved env is the returned dict")
    }

    // MARK: - Byte-identical regression (the AC)

    func testPureInheritOverlayIsByteIdenticalToHarnessBaseLaunch() {
        // A pure-inherit overlay (every field nil) must reproduce the raw-harness
        // launch exactly — the mechanism the regression AC governs.
        let userDefault = DefaultAgentConfig.factory
        let baseResolved = DefaultAgentResolver.resolve(
            explicitAgent: .claudeCode, userDefault: userDefault, projectConfig: nil
        )
        let overlayResolved = DefaultAgentResolver.resolveOverlay(
            savedConfig: saved(overlay(harness: "claude-code")),
            userDefault: userDefault,
            projectConfig: nil
        )
        XCTAssertNotNil(overlayResolved)
        XCTAssertEqual(overlayResolved?.launch.command, baseResolved.launch.command)
        XCTAssertEqual(overlayResolved?.launch.bareCommand, baseResolved.launch.bareCommand)
    }

    func testShippedFactorySeedResolvesToTodaysDefaultCommand() {
        // O1 (orchestrator ruling): the shipped `Opus deep` seed is opus-only
        // (no effort), so effectiveDefault()'s resolved command is byte-identical
        // to today's default launch (`--model opus`, no `--effort`). Pins the
        // ACTUAL shipped default, not just the synthetic pure-inherit proof.
        let seed = AgentConfigLibraryFile.factory.configs[0]
        XCTAssertNil(seed.config.effort, "factory seed must not pin effort (O1)")
        let userDefault = DefaultAgentConfig.factory
        let resolved = DefaultAgentResolver.resolveOverlay(
            savedConfig: seed, userDefault: userDefault, projectConfig: nil
        )
        let today = DefaultAgentResolver.resolve(
            explicitAgent: .claudeCode, userDefault: userDefault, projectConfig: nil
        )
        XCTAssertEqual(resolved?.launch.command, today.launch.command)
        XCTAssertFalse(resolved?.launch.command.contains("--effort") ?? true, "default launch injects no --effort")
    }

    func testHardcodedModelInCommandIsNotDoubleInjectedByOverlay() {
        // An operator who hardcoded --model in the base command owns the axis;
        // an overlay model must not add a second flag (reuses existing detection).
        let base = claudeBase(command: "claude --model sonnet", model: "")
        let userDefault = DefaultAgentConfig(defaultAgent: .claudeCode, agents: [.claudeCode: base])
        let resolved = DefaultAgentResolver.resolveOverlay(
            savedConfig: saved(overlay(model: "opus")),
            userDefault: userDefault,
            projectConfig: nil
        )
        let occurrences = resolved?.launch.command.components(separatedBy: "--model").count ?? 0
        XCTAssertEqual(occurrences, 2, "exactly one --model (split yields count 2); overlay did not double-inject")
        XCTAssertTrue(resolved?.launch.command.contains("--model sonnet") ?? false, "hardcoded model wins")
    }

    // MARK: - Flag injection reuse for overlay values

    func testOverlayModelAndEffortInjectViaTemplate() {
        let userDefault = DefaultAgentConfig.factory
        let resolved = DefaultAgentResolver.resolveOverlay(
            savedConfig: saved(overlay(model: "sonnet", effort: "high")),
            userDefault: userDefault,
            projectConfig: nil
        )
        XCTAssertTrue(resolved?.launch.command.contains("--model sonnet") ?? false)
        XCTAssertTrue(resolved?.launch.command.contains("--effort high") ?? false)
    }

    func testOverlayReplaceBlankSlateSystemPromptRendersEmptyFlag() {
        let userDefault = DefaultAgentConfig.factory
        let resolved = DefaultAgentResolver.resolveOverlay(
            savedConfig: saved(overlay(systemPrompt: SystemPromptSetting(mode: .replace, text: ""))),
            userDefault: userDefault,
            projectConfig: nil
        )
        XCTAssertTrue(resolved?.launch.command.contains("--system-prompt ''") ?? false, "replace+\"\" is the blank slate")
    }

    // MARK: - Resolved scalars exposed on mergedConfig (feed stamp + stats)

    func testMergedConfigExposesResolvedAxes() {
        let userDefault = DefaultAgentConfig.factory
        let resolved = DefaultAgentResolver.resolveOverlay(
            savedConfig: saved(overlay(model: "sonnet", effort: "high", systemPrompt: SystemPromptSetting(mode: .append, text: "x"))),
            userDefault: userDefault,
            projectConfig: nil
        )
        XCTAssertEqual(resolved?.mergedConfig.model, "sonnet")
        XCTAssertEqual(resolved?.mergedConfig.effort, "high")
        XCTAssertEqual(resolved?.mergedConfig.systemPrompt?.mode, .append)
    }

    // MARK: - Custom/unknown harness → nil (caller falls back)

    func testUnknownHarnessReturnsNil() {
        let resolved = DefaultAgentResolver.resolveOverlay(
            savedConfig: saved(overlay(harness: "totally-made-up-kind")),
            userDefault: .factory,
            projectConfig: nil
        )
        XCTAssertNil(resolved)
    }

    // MARK: - effectiveDefault() composition (store rooted at a temp dir)

    private func tempStore() -> (AgentConfigLibraryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-overlay-tests-\(UUID().uuidString)", isDirectory: true)
        return (AgentConfigLibraryStore(directory: dir), dir)
    }

    func testEffectiveDefaultPinnedReturnsFactorySeedOnFreshStore() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let eff = store.effectiveDefault()
        XCTAssertEqual(eff.name, "Opus deep")
        XCTAssertEqual(eff.config.model, "opus")
        XCTAssertNil(eff.config.effort)
    }

    func testEffectiveDefaultPinnedFollowsSetDefault() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let added = try store.add(saved(overlay(model: "sonnet"), name: "Sonnet mid", id: ""))
        try store.setDefault(configId: added.id)
        XCTAssertEqual(store.effectiveDefault().id, added.id)
        XCTAssertEqual(store.effectiveDefault().config.model, "sonnet")
    }

    /// C11-203 B2: recording a launch no longer moves the effective default —
    /// `recent` is telemetry, the pin is the answer.
    func testRecordingRecentDoesNotMoveEffectiveDefault() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let added = try store.add(saved(overlay(model: "sonnet"), name: "Sonnet mid", id: ""))
        try store.recordRecent(RecentAgentConfig(configId: added.id, harness: "claude-code", model: "sonnet", observedAt: Date(), source: "launch"))
        XCTAssertEqual(store.effectiveDefault().name, "Opus deep", "the pin still wins")
        XCTAssertEqual(store.current.recent?.configId, added.id, "the observation is still recorded")
    }

    // MARK: - C11-203 A1: a declined launch always names its reason

    /// The contract is "never a silent no-op": every decline `launchAgentSurface`
    /// can return must carry a non-empty, distinguishable operator-facing
    /// sentence, and the two harness-bearing cases must name the harness so the
    /// operator knows which recipe to fix.
    func testEveryLaunchDeclineHasADistinctNonEmptyMessage() {
        let declines: [Workspace.AgentLaunchDecline] = [
            .emptyCommand(harness: "custom"),
            .surfaceCreationFailed,
            .unresolvableRecipe(harness: "aider"),
        ]
        let messages = declines.map(\.message)
        for message in messages {
            XCTAssertFalse(
                message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "a decline with no message is the silent no-op this ticket removes"
            )
        }
        XCTAssertEqual(Set(messages).count, declines.count, "reasons must be distinguishable")
        XCTAssertTrue(messages[0].contains("custom"))
        XCTAssertTrue(messages[2].contains("aider"))
    }

    /// `.launched` is the only outcome that reports a launch, and it is the only
    /// one without a reason to show.
    func testLaunchOutcomeMapsToDidLaunchAndDecline() {
        let launched = Workspace.AgentSurfaceLaunchOutcome.launched
        XCTAssertTrue(launched.didLaunch)
        XCTAssertNil(launched.decline)

        let declined = Workspace.AgentSurfaceLaunchOutcome
            .declined(.emptyCommand(harness: "custom"))
        XCTAssertFalse(declined.didLaunch)
        XCTAssertEqual(declined.decline, .emptyCommand(harness: "custom"))
    }

    /// A refused pin (C11-203 A2) explains itself too, and says something
    /// different from a generic store failure.
    func testPinRefusalMessagesNameTheConfigAndDifferByCause() {
        let unlaunchable = Workspace.pinRefusalMessage(
            for: AgentConfigLibraryStore.StoreError.configUnlaunchable("BROKEN"),
            configName: "Aider"
        )
        let generic = Workspace.pinRefusalMessage(
            for: AgentConfigLibraryStore.StoreError.configNotFound("BROKEN"),
            configName: "Aider"
        )
        XCTAssertTrue(unlaunchable.contains("Aider"))
        XCTAssertTrue(generic.contains("Aider"))
        XCTAssertNotEqual(unlaunchable, generic)
    }

    // MARK: - Tooltip formatter (§5.3 v1)

    func testTooltipFormatsNameModelEffortWithFamilyDisplayName() {
        let s = DefaultAgentResolver.formatAgentTooltip(name: "Opus deep", model: "opus", effort: "high")
        XCTAssertEqual(s, "Launch Agent — Opus deep · Opus · high")
    }

    func testTooltipOmitsEmptyEffortSegment() {
        let s = DefaultAgentResolver.formatAgentTooltip(name: "Opus deep", model: "opus", effort: "")
        XCTAssertEqual(s, "Launch Agent — Opus deep · Opus")
    }

    func testTooltipShowsNonFamilyModelVerbatim() {
        let s = DefaultAgentResolver.formatAgentTooltip(name: "Codex hi", model: "gpt-5.2", effort: "high")
        XCTAssertEqual(s, "Launch Agent — Codex hi · gpt-5.2 · high")
    }

    func testResolvedDefaultTooltipFromFreshStoreShowsSeed() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = DefaultAgentResolver.resolvedDefaultTooltip(library: store, userDefault: .factory)
        XCTAssertEqual(s, "Launch Agent — Opus deep · Opus", "seed is opus-only → no effort segment")
    }

    // MARK: - Validation: rendered command matrix + sink data path (in_validation)

    /// Renders the resolved launch line for a matrix of overlays over the same
    /// claude-code base, proving the full composition end-to-end. The printed
    /// lines are the validation evidence; the assertions pin the distinguishing
    /// injected flags per row.
    func testValidationCommandMatrixRendersThroughOverlay() {
        let userDefault = DefaultAgentConfig.factory
        let base = userDefault.config(for: .claudeCode)
        func render(_ o: AgentLaunchConfig) -> String {
            DefaultAgentResolver.resolveOverlay(savedConfig: saved(o), userDefault: userDefault, projectConfig: nil)!.launch.command
        }

        let inheritAll = render(overlay(harness: "claude-code"))
        let modelOnly = render(overlay(model: "sonnet"))
        let fullRecipe = render(overlay(
            model: "sonnet", effort: "high",
            systemPrompt: SystemPromptSetting(mode: .append, text: "be terse"),
            command: "claude --dangerously-skip-permissions",
            initialPrompt: "go"
        ))
        let blankSlate = render(overlay(systemPrompt: SystemPromptSetting(mode: .replace, text: "")))

        print("=== C11-179 overlay command matrix ===")
        print("inherit-all  : \(inheritAll)")
        print("model-only   : \(modelOnly)")
        print("full-recipe  : \(fullRecipe)")
        print("blank-slate  : \(blankSlate)")

        // inherit-all == raw harness base (byte-identical), no overlay flags.
        let raw = DefaultAgentResolver.resolve(explicitAgent: .claudeCode, userDefault: userDefault, projectConfig: nil).launch.command
        XCTAssertEqual(inheritAll, raw)
        // model-only swaps the model, keeps everything else.
        XCTAssertTrue(modelOnly.contains("--model sonnet"))
        XCTAssertFalse(modelOnly.contains("--effort"))
        // full-recipe injects model+effort+append-system-prompt+positional prompt.
        XCTAssertTrue(fullRecipe.contains("--model sonnet"))
        XCTAssertTrue(fullRecipe.contains("--effort high"))
        XCTAssertTrue(fullRecipe.contains("--append-system-prompt 'be terse'"))
        XCTAssertTrue(fullRecipe.hasSuffix("'go'"), "claude initial prompt rides as a trailing positional")
        // blank-slate emits the empty replace flag.
        XCTAssertTrue(blankSlate.contains("--system-prompt ''"))
        // sanity: the base isn't accidentally mutated by any render.
        XCTAssertEqual(userDefault.config(for: .claudeCode).command, base.command)
    }

    /// End-to-end data path for the A-button overlay launch → the C11-178 sink:
    /// resolve the overlay, build the `ResolvedLaunch` the launch site records,
    /// and confirm the persisted stats carry the overlay `config_id`, the
    /// resolved model, and the launch source. Proves "recordLaunch fires with the
    /// overlay-resolved config + source" for the path this ticket rewired.
    func testValidationOverlayLaunchReachesStatsSinkWithConfigId() throws {
        let userDefault = DefaultAgentConfig.factory
        let savedCfg = saved(overlay(model: "sonnet", effort: "high"), name: "Sonnet hi", id: "CFGSONNETHI0000000000000A")
        let resolved = try XCTUnwrap(
            DefaultAgentResolver.resolveOverlay(savedConfig: savedCfg, userDefault: userDefault, projectConfig: nil)
        )
        // Mirror exactly what Workspace.launchAgentSurface builds for the sink.
        let stats = ResolvedLaunch(
            harness: resolved.agent.rawValue,
            model: resolved.mergedConfig.model,
            effort: resolved.mergedConfig.effort,
            systemPromptMode: resolved.mergedConfig.systemPrompt?.mode.rawValue,
            configId: savedCfg.id
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-sink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = AgentLaunchStatsStore(directory: dir)
        sink.recordLaunch(stats, source: .aButton)
        sink.flush()

        let recent = try XCTUnwrap(sink.recent())
        XCTAssertEqual(recent.configId, "CFGSONNETHI0000000000000A", "overlay config_id reached the sink")
        XCTAssertEqual(recent.model, "sonnet", "resolved model recorded")
        XCTAssertEqual(recent.harness, "claude-code")
        XCTAssertEqual(recent.provider, "anthropic", "provider derived in the sink")
        XCTAssertEqual(sink.aggregate().totals.byModel["sonnet"], 1, "aggregate bumped for the resolved model")
    }
}
