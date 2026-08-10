import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure-logic tests for the Saved Configs editor model (C11-182, re-shaped by
/// C11-203 Part C/E). No SwiftUI / `NSApp` construction, so these run in
/// `c11-logic`.
///
/// The catalog is a real `ModelCatalogIndex` built from a handful of raw
/// records, so the merge, the harness ordering and the per-harness flag
/// spellings are the shipping ones — only the enumeration is stubbed, and no
/// test shells out to a harness CLI.
final class AgentConfigEditorModelTests: XCTestCase {

    // MARK: Fixture catalog

    /// A miniature of the real catalog: one provider per interesting shape.
    private static let records: [RawCatalogRecord] = [
        // Anthropic. `opus` is claude-code's alone (exactly one harness can
        // serve it); `claude-opus-4-8` is reachable only through the routers,
        // which is the Part C cross-product.
        RawCatalogRecord(harness: "claude-code", rawID: "opus", displayName: "Opus", providerHint: "anthropic"),
        RawCatalogRecord(harness: "claude-code", rawID: "sonnet", displayName: "Sonnet", providerHint: "anthropic"),
        RawCatalogRecord(harness: "opencode", rawID: "anthropic/claude-opus-4-8", displayName: "Claude Opus 4.8"),
        RawCatalogRecord(harness: "pi", rawID: "openrouter/anthropic/claude-opus-4-8"),

        // OpenAI. Codex spells the id bare; opencode namespaces it. The three
        // codex rows carry three different ladders and three different
        // defaults, which is the whole reason effort cannot be hardcoded.
        RawCatalogRecord(harness: "codex", rawID: "gpt-5.6-sol", displayName: "GPT-5.6-Sol",
                         efforts: .values(["low", "medium", "high", "xhigh", "max", "ultra"]),
                         defaultEffort: "low", providerHint: "openai"),
        RawCatalogRecord(harness: "codex", rawID: "gpt-5.6-luna", displayName: "GPT-5.6-Luna",
                         efforts: .values(["low", "medium", "high", "xhigh", "max"]),
                         defaultEffort: "medium", providerHint: "openai"),
        RawCatalogRecord(harness: "codex", rawID: "gpt-5.4", displayName: "GPT-5.4",
                         efforts: .values(["low", "medium", "high", "xhigh"]),
                         defaultEffort: "medium", upgradeTo: "gpt-5.6-terra", providerHint: "openai"),
        RawCatalogRecord(harness: "codex", rawID: "gpt-5.6-astra", displayName: "GPT-5.6 Astra",
                         isComingSoon: true, providerHint: "openai"),
        RawCatalogRecord(harness: "opencode", rawID: "openai/gpt-5.6-sol", displayName: "GPT-5.6 Sol"),

        // Moonshot. K3 publishes effort levels; K2.7 explicitly publishes none
        // — and omp claims four levels for that same K2.7 model, which is true
        // for omp's `--thinking` and false for the kimi harness.
        RawCatalogRecord(harness: "kimi", rawID: "k3", displayName: "K3", contextWindow: 1_048_576,
                         efforts: .values(["low", "high", "max"]), providerHint: "moonshot"),
        RawCatalogRecord(harness: "kimi", rawID: "kimi-for-coding", displayName: "K2.7 Coding",
                         contextWindow: 262_144, efforts: .none, providerHint: "moonshot"),
        RawCatalogRecord(harness: "omp", rawID: "kimi/k3",
                         efforts: .values(["minimal", "low", "medium", "high", "xhigh"])),
        RawCatalogRecord(harness: "omp", rawID: "kimi/kimi-for-coding",
                         efforts: .values(["minimal", "low", "medium", "high"])),

        // xAI, and a long-tail provider so the overflow tier has something in it.
        RawCatalogRecord(harness: "grok", rawID: "grok-4.5", providerHint: "xai"),
        RawCatalogRecord(harness: "pi", rawID: "perplexity/sonar-pro"),
    ]

    private let catalog = StubModelCatalog(records)

    private func model(_ provider: String, _ id: String) -> CatalogModel {
        guard let hit = catalog.model(provider: provider, id: id) else {
            preconditionFailure("fixture catalog has no \(provider)/\(id)")
        }
        return hit
    }

    private func selection(
        provider: String?,
        harness: String,
        model: String? = nil,
        effort: String? = nil,
        env: [String: String]? = nil
    ) -> AgentConfigAxisSelection {
        AgentConfigAxisSelection(
            provider: provider,
            config: AgentLaunchConfig(harness: harness, model: model, effort: effort, env: env)
        )
    }

    // MARK: Provider axis

    func testProviderOptionsLeadWithTheKnownBrandsAndTailIntoOverflow() {
        let options = AgentConfigAxes.providerOptions(selected: nil, catalog: catalog)
        XCTAssertEqual(options.prominent, ["openai", "anthropic", "moonshot", "xai"],
                       "prominent is leadingOrder ∩ catalog, in leadingOrder's order")
        XCTAssertEqual(options.overflow, ["perplexity"], "the long tail lives behind the menu")
    }

    func testProviderOptionsPromoteTheCurrentSelectionOutOfTheTail() {
        let options = AgentConfigAxes.providerOptions(selected: "perplexity", catalog: catalog)
        XCTAssertTrue(options.prominent.contains("perplexity"),
                      "the recipe's own provider is always visible")
        XCTAssertFalse(options.overflow.contains("perplexity"))
    }

    func testDerivedProviderReadsAStoredRecipeBackOntoTheProviderAxis() {
        // Bare id under its native harness.
        XCTAssertEqual(
            AgentConfigAxes.derivedProvider(for: AgentLaunchConfig(harness: "claude-code", model: "opus"),
                                            catalog: catalog),
            "anthropic")
        // Namespaced id under opencode.
        XCTAssertEqual(
            AgentConfigAxes.derivedProvider(for: AgentLaunchConfig(harness: "opencode", model: "openai/gpt-5.6-sol"),
                                            catalog: catalog),
            "openai")
        // OpenRouter's gateway spelling flattens onto the real vendor.
        XCTAssertEqual(
            AgentConfigAxes.derivedProvider(
                for: AgentLaunchConfig(harness: "pi", model: "openrouter/anthropic/claude-opus-4-8"),
                catalog: catalog),
            "anthropic")
        // Inherit, and a model no catalog knows.
        XCTAssertNil(AgentConfigAxes.derivedProvider(for: AgentLaunchConfig(harness: "codex"), catalog: catalog))
        XCTAssertNil(AgentConfigAxes.derivedProvider(
            for: AgentLaunchConfig(harness: "codex", model: "gpt-9-imaginary"), catalog: catalog))
    }

    // MARK: Cascade — provider

    func testChangingProviderInvalidatesTheModelAndSnapsToThatProvidersHarness() {
        let before = selection(provider: "openai", harness: "codex", model: "gpt-5.6-sol", effort: "high")
        let after = AgentConfigAxes.selectingProvider("anthropic", in: before, catalog: catalog)

        XCTAssertEqual(after.provider, "anthropic")
        XCTAssertNil(after.config.model, "the model belonged to the old provider")
        XCTAssertEqual(after.config.harness, "claude-code", "Part C's default harness for Anthropic")
        XCTAssertEqual(after.config.effort, "high", "claude-code's tiers still carry 'high'")
    }

    func testChangingProviderDropsAnEffortTheNewHarnessCannotExpress() {
        let before = selection(provider: "anthropic", harness: "claude-code", model: "opus", effort: "max")
        // Moonshot's default harness is kimi, which has no effort at all until
        // a model with published levels is chosen.
        let after = AgentConfigAxes.selectingProvider("moonshot", in: before, catalog: catalog)
        XCTAssertEqual(after.config.harness, "kimi")
        XCTAssertNil(after.config.effort)
    }

    func testChoosingTheInheritProviderKeepsTheHarnessAndOpensEveryHarness() {
        let before = selection(provider: "openai", harness: "codex", model: "gpt-5.6-sol")
        let after = AgentConfigAxes.selectingProvider(nil, in: before, catalog: catalog)

        XCTAssertNil(after.provider)
        XCTAssertNil(after.config.model)
        XCTAssertEqual(after.config.harness, "codex", "going harness-first is deliberate; don't move it")
        let harnesses = AgentConfigAxes.harnessOptions(for: after, catalog: catalog)
        XCTAssertTrue(harnesses.contains("custom"), "Custom is only reachable with no model pinned")
        XCTAssertTrue(harnesses.contains("github-copilot"), "so is a harness no catalog enumerates")
    }

    // MARK: Cascade — model, and the harness filter

    func testHarnessOptionsAreEvidenceBasedWithThePartCDefaultOnTop() {
        let sol = selection(provider: "openai", harness: "codex", model: "gpt-5.6-sol")
        XCTAssertEqual(AgentConfigAxes.harnessOptions(for: sol, catalog: catalog), ["codex", "opencode"])

        // An Anthropic model only the routers carry: the cross-product stays
        // reachable, and claude-code is absent because it cannot serve it.
        let routed = selection(provider: "anthropic", harness: "opencode", model: "anthropic/claude-opus-4-8")
        XCTAssertEqual(AgentConfigAxes.harnessOptions(for: routed, catalog: catalog), ["opencode", "pi"])
    }

    func testExactlyOneQualifyingHarnessIsAutoSelected() {
        let before = selection(provider: "openai", harness: "codex", model: "gpt-5.6-sol")
        let after = AgentConfigAxes.selectingModel(model("anthropic", "opus"), in: before, catalog: catalog)

        XCTAssertEqual(after.config.harness, "claude-code")
        XCTAssertEqual(after.config.model, "opus")
        XCTAssertEqual(AgentConfigAxes.harnessOptions(for: after, catalog: catalog), ["claude-code"],
                       "one option — the editor renders it as resolved, not as a choice")
    }

    func testSelectingAModelKeepsAHarnessThatCanStillServeIt() {
        let before = selection(provider: "openai", harness: "opencode", model: "openai/gpt-5.6-sol")
        let after = AgentConfigAxes.selectingModel(model("anthropic", "claude-opus-4-8"), in: before, catalog: catalog)
        XCTAssertEqual(after.config.harness, "opencode", "opencode serves it, so the operator's pick survives")
        XCTAssertEqual(after.config.model, "anthropic/claude-opus-4-8")
    }

    func testAComingSoonModelIsNotSelectable() {
        let before = selection(provider: "openai", harness: "codex", model: "gpt-5.6-sol")
        let after = AgentConfigAxes.selectingModel(model("openai", "gpt-5.6-astra"), in: before, catalog: catalog)
        XCTAssertEqual(after, before, "the Astra row is dimmed; clicking it changes nothing")
    }

    func testSelectingInheritClearsTheModelButLeavesTheHarness() {
        let before = selection(provider: "openai", harness: "codex", model: "gpt-5.6-sol")
        let after = AgentConfigAxes.selectingModel(nil, in: before, catalog: catalog)
        XCTAssertNil(after.config.model)
        XCTAssertEqual(after.config.harness, "codex")
    }

    // MARK: Cascade — harness, and the per-harness flag spelling

    func testSwitchingHarnessRespellsTheModelForThatHarnessesFlag() {
        let before = selection(provider: "openai", harness: "codex", model: "gpt-5.6-sol")
        let after = AgentConfigAxes.selectingHarness("opencode", in: before, catalog: catalog)
        XCTAssertEqual(after.config.model, "openai/gpt-5.6-sol",
                       "opencode's -m takes provider/model, not the bare catalog id")

        let back = AgentConfigAxes.selectingHarness("codex", in: after, catalog: catalog)
        XCTAssertEqual(back.config.model, "gpt-5.6-sol")
    }

    func testSwitchingToCustomDropsTheModelBecauseCustomTakesNoModelFlag() {
        let before = selection(provider: "openai", harness: "codex", model: "gpt-5.6-sol")
        let after = AgentConfigAxes.selectingHarness("custom", in: before, catalog: catalog)
        XCTAssertEqual(after.config.harness, "custom")
        XCTAssertNil(after.config.model)
    }

    func testSwitchingToAHarnessWithNoSystemPromptFlagDropsTheSystemPrompt() {
        var config = AgentLaunchConfig(harness: "claude-code", model: "opus")
        config.systemPrompt = SystemPromptSetting(mode: .replace, text: "")
        let before = AgentConfigAxisSelection(provider: "anthropic", config: config)
        let after = AgentConfigAxes.selectingHarness("codex", in: before, catalog: catalog)
        XCTAssertNil(after.config.systemPrompt, "codex has no system-prompt axis")
    }

    func testSwitchingToASupportedHarnessLeavesTheSystemPromptNil() {
        // Seeding an explicit `.inherit` here would clobber a configured base
        // system prompt through mergeOverlay (C11-179 contract).
        let before = selection(provider: "openai", harness: "codex", model: "gpt-5.6-sol")
        let after = AgentConfigAxes.selectingHarness("claude-code", in: before, catalog: catalog)
        XCTAssertNil(after.config.systemPrompt)
    }

    // MARK: Effort — per (model, harness)

    func testKimiK3PublishesEffortsAndK27PublishesNone() {
        let k3 = selection(provider: "moonshot", harness: "kimi", model: "k3")
        XCTAssertEqual(AgentConfigAxes.effortOptions(for: k3, catalog: catalog), ["low", "high", "max"])

        let k27 = selection(provider: "moonshot", harness: "kimi", model: "kimi-for-coding")
        XCTAssertNil(AgentConfigAxes.effortOptions(for: k27, catalog: catalog),
                     "K2.7 is always_thinking — the control must not render at all")
    }

    func testTheSameK27ModelDoesHaveEffortUnderOmp() {
        // The trap this test exists for: omp publishes `--thinking` levels for
        // a model kimi says has none. Asking per pair is the only way to get
        // both answers right; `CatalogModel.supportedEfforts` carries only the
        // default harness's.
        let underOmp = selection(provider: "moonshot", harness: "omp", model: "kimi/kimi-for-coding")
        XCTAssertEqual(AgentConfigAxes.effortOptions(for: underOmp, catalog: catalog),
                       ["minimal", "low", "medium", "high"])
        XCTAssertEqual(model("moonshot", "kimi-for-coding").supportedEfforts, [],
                       "the merged field says 'none' because kimi is the native harness")
    }

    func testHarnessTiersAreIntersectedWithWhatTheHarnessPublishesForTheModel() {
        // omp's manifest tiers include `off`, which omp does not publish for
        // this model; the intersection is what the operator sees.
        let k3UnderOmp = selection(provider: "moonshot", harness: "omp", model: "kimi/k3")
        XCTAssertEqual(AgentConfigAxes.effortOptions(for: k3UnderOmp, catalog: catalog),
                       ["minimal", "low", "medium", "high", "xhigh"])
        XCTAssertFalse(AgentConfigAxes.effortOptions(for: k3UnderOmp, catalog: catalog)?.contains("off") ?? true)
    }

    func testAHarnessWithNoEffortFlagAndNoPublishedLevelsRendersNoControl() {
        // opencode's TUI takes no `--variant` (verified against the installed
        // binary), and grok declares no effort flag in its manifest.
        for pair in [("opencode", "openai/gpt-5.6-sol", "openai"), ("grok", "grok-4.5", "xai")] {
            let sel = selection(provider: pair.2, harness: pair.0, model: pair.1)
            XCTAssertNil(AgentConfigAxes.effortOptions(for: sel, catalog: catalog), "\(pair.0)")
        }
    }

    func testManifestTiersCarryWhenTheCatalogSaysNothing() {
        let claude = selection(provider: "anthropic", harness: "claude-code", model: "opus")
        XCTAssertEqual(AgentConfigAxes.effortOptions(for: claude, catalog: catalog),
                       ["low", "medium", "high", "xhigh", "max"])
    }

    func testCodexLaddersArePerModelAndReachPastWhatTheManifestKnows() {
        // Passthrough harness: the published ladder wins outright, because
        // codex validates the value and c11 would only be guessing.
        let sol = selection(provider: "openai", harness: "codex", model: "gpt-5.6-sol")
        XCTAssertEqual(AgentConfigAxes.effortOptions(for: sol, catalog: catalog),
                       ["low", "medium", "high", "xhigh", "max", "ultra"])

        // The same harness, a different cap.
        let luna = selection(provider: "openai", harness: "codex", model: "gpt-5.6-luna")
        XCTAssertEqual(AgentConfigAxes.effortOptions(for: luna, catalog: catalog),
                       ["low", "medium", "high", "xhigh", "max"])

        let older = selection(provider: "openai", harness: "codex", model: "gpt-5.4")
        XCTAssertEqual(AgentConfigAxes.effortOptions(for: older, catalog: catalog),
                       ["low", "medium", "high", "xhigh"])
    }

    func testCodexWithNoModelPinnedFallsBackToTheManifestSuggestion() {
        let inherit = selection(provider: "openai", harness: "codex")
        XCTAssertEqual(AgentConfigAxes.effortOptions(for: inherit, catalog: catalog),
                       ["low", "medium", "high", "xhigh"],
                       "no model means no known ladder cap — stay conservative")
    }

    // MARK: What "inherit" resolves to

    func testInheritLabelUsesThePublishersPerModelDefault() {
        let sol = selection(provider: "openai", harness: "codex", model: "gpt-5.6-sol")
        XCTAssertEqual(AgentConfigAxes.inheritedEffortLabel(for: sol, from: .factory, catalog: catalog), "low")

        let luna = selection(provider: "openai", harness: "codex", model: "gpt-5.6-luna")
        XCTAssertEqual(AgentConfigAxes.inheritedEffortLabel(for: luna, from: .factory, catalog: catalog), "medium")

        let noModel = selection(provider: "openai", harness: "codex")
        XCTAssertNil(AgentConfigAxes.inheritedEffortLabel(for: noModel, from: .factory, catalog: catalog))
    }

    func testInheritLabelIsNeverWrittenIntoTheRecipe() {
        // nil effort is the true inherit (C11-179); seeding the publisher's
        // default would turn every new recipe into an explicit override.
        let sol = selection(provider: "openai", harness: "codex")
        let after = AgentConfigAxes.selectingModel(model("openai", "gpt-5.6-sol"), in: sol, catalog: catalog)
        XCTAssertNil(after.config.effort)
    }

    func testTheDeprecationPointerIsAvailableForTheModelRow() {
        XCTAssertEqual(catalog.publishedUpgradeTarget(for: model("openai", "gpt-5.4")), "gpt-5.6-terra")
        XCTAssertNil(catalog.publishedUpgradeTarget(for: model("openai", "gpt-5.6-sol")))
    }

    // MARK: Effort delivery through the launch environment (Part E2)

    func testKimiEffortIsDeliveredAsALaunchEnvironmentOverride() {
        let k3 = selection(provider: "moonshot", harness: "kimi", model: "k3")
        let chosen = AgentConfigAxes.selectingEffort("max", in: k3, catalog: catalog)
        XCTAssertEqual(chosen.config.effort, "max")
        XCTAssertEqual(chosen.config.env?[AgentConfigAxes.kimiEffortEnvKey], "max",
                       "the kimi CLI has no effort flag; the binary reads this variable")
    }

    func testClearingTheKimiEffortRemovesTheInjectedVariable() {
        let k3 = selection(provider: "moonshot", harness: "kimi", model: "k3")
        let chosen = AgentConfigAxes.selectingEffort("high", in: k3, catalog: catalog)
        let cleared = AgentConfigAxes.selectingEffort(nil, in: chosen, catalog: catalog)
        XCTAssertNil(cleared.config.env?[AgentConfigAxes.kimiEffortEnvKey])
    }

    func testLeavingKimiRemovesTheInjectedVariable() {
        let k3 = selection(provider: "moonshot", harness: "kimi", model: "k3")
        let chosen = AgentConfigAxes.selectingEffort("max", in: k3, catalog: catalog)
        let moved = AgentConfigAxes.selectingHarness("omp", in: chosen, catalog: catalog)

        XCTAssertEqual(moved.config.model, "kimi/k3", "omp's own spelling for the same model")
        XCTAssertNil(moved.config.effort, "omp does not offer 'max' for this model")
        XCTAssertNil(moved.config.env?[AgentConfigAxes.kimiEffortEnvKey],
                     "a stale kimi override must not ride into an omp launch")
    }

    func testTheEffortVariableNeverClobbersAnUnrelatedEnvOverlay() {
        let k3 = selection(provider: "moonshot", harness: "kimi", model: "k3",
                           env: ["FOO": "bar"])
        let chosen = AgentConfigAxes.selectingEffort("low", in: k3, catalog: catalog)
        XCTAssertEqual(chosen.config.env?["FOO"], "bar")
        XCTAssertEqual(chosen.config.env?[AgentConfigAxes.kimiEffortEnvKey], "low")
    }

    func testPersistenceReappliesTheEffortDeliverySoAnyWritePathAgrees() {
        let config = AgentLaunchConfig(harness: "kimi", model: "k3", effort: "high")
        XCTAssertEqual(AgentConfigAxes.normalizedForPersistence(config).env?[AgentConfigAxes.kimiEffortEnvKey],
                       "high")
        // A non-kimi recipe never carries it.
        let claude = AgentLaunchConfig(harness: "claude-code", model: "opus", effort: "high")
        XCTAssertNil(AgentConfigAxes.normalizedForPersistence(claude).env?[AgentConfigAxes.kimiEffortEnvKey])
    }

    // MARK: Save guard (Part C4)

    func testSaveIsRefusedForACustomRecipeWithNoCommand() {
        XCTAssertEqual(AgentConfigAxes.saveRefusal(for: AgentLaunchConfig(harness: "custom")),
                       .customCommandEmpty)
        XCTAssertEqual(AgentConfigAxes.saveRefusal(for: AgentLaunchConfig(harness: "custom", command: "   ")),
                       .customCommandEmpty,
                       "whitespace is not a command")
        XCTAssertFalse(AgentConfigSaveRefusal.customCommandEmpty.message.isEmpty,
                       "the operator is told why nothing was written")
    }

    func testSaveIsAllowedForACustomRecipeThatHasACommand() {
        XCTAssertNil(AgentConfigAxes.saveRefusal(for: AgentLaunchConfig(harness: "custom", command: "aider --yes")))
    }

    func testSaveIsAllowedForEveryHarnessThatShipsItsOwnCommand() {
        for harness in ["claude-code", "codex", "kimi", "grok", "opencode", "pi", "omp"] {
            XCTAssertNil(AgentConfigAxes.saveRefusal(for: AgentLaunchConfig(harness: harness)),
                         "\(harness) inherits a factory command")
        }
    }

    func testTheRefusedShapeIsExactlyTheOneThatKilledTheAButton() {
        // The observed specimen: the factory seed rewritten to a command-less
        // custom recipe, then pinned as the default.
        let bricked = AgentLaunchConfig(harness: "custom", model: nil, command: nil)
        XCTAssertNotNil(AgentConfigAxes.saveRefusal(for: bricked))
        XCTAssertTrue(bricked.isProvablyUnlaunchable,
                      "the editor's refusal and the store's verdict are the same predicate")
    }

    // MARK: Model list

    func testModelOptionsListAProvidersModelsAndSearchNarrowsThem() {
        let all = AgentConfigAxes.modelOptions(provider: "anthropic", query: "", catalog: catalog)
        XCTAssertEqual(Set(all.map(\.id)), ["opus", "sonnet", "claude-opus-4-8"])

        let filtered = AgentConfigAxes.modelOptions(provider: "anthropic", query: "son", catalog: catalog)
        XCTAssertEqual(filtered.map(\.id), ["sonnet"])
    }

    func testModelOptionsWithNoProviderSearchTheWholeCatalog() {
        XCTAssertTrue(AgentConfigAxes.modelOptions(provider: nil, query: "", catalog: catalog).isEmpty,
                      "no provider and no query is the Inherit case, not a 628-row dump")
        let hits = AgentConfigAxes.modelOptions(provider: nil, query: "grok", catalog: catalog)
        XCTAssertEqual(hits.map(\.id), ["grok-4.5"])
    }

    // MARK: Manifest-derived axes

    func testEffortAxisTiers() {
        XCTAssertEqual(AgentConfigAxes.effortAxis(forHarness: "claude-code"),
                       .tiers(["low", "medium", "high", "xhigh", "max"]))
        XCTAssertEqual(AgentConfigAxes.effortAxis(forHarness: "pi"),
                       .tiers(["off", "minimal", "low", "medium", "high", "xhigh"]))
        XCTAssertEqual(AgentConfigAxes.effortAxis(forHarness: "omp"),
                       .tiers(["off", "minimal", "low", "medium", "high", "xhigh"]))
    }

    func testEffortAxisPassthroughForCodex() {
        XCTAssertEqual(AgentConfigAxes.effortAxis(forHarness: "codex"), .passthrough)
    }

    func testEffortAxisNoneWhereTheManifestDeclaresNoFlag() {
        for k in ["grok", "kimi", "opencode", "github-copilot", "custom"] {
            XCTAssertEqual(AgentConfigAxes.effortAxis(forHarness: k), .none, "\(k) should be .none")
        }
    }

    func testAcceptsModel() {
        XCTAssertTrue(AgentConfigAxes.acceptsModel(forHarness: "claude-code"))
        XCTAssertTrue(AgentConfigAxes.acceptsModel(forHarness: "opencode"))
        XCTAssertFalse(AgentConfigAxes.acceptsModel(forHarness: "custom"))
        XCTAssertFalse(AgentConfigAxes.acceptsModel(forHarness: "unknown-kind"))
    }

    func testSystemPromptAxisClaudeSupported() {
        guard case .supported(let appendFlag, let replaceFlag) =
                AgentConfigAxes.systemPromptAxis(forHarness: "claude-code") else {
            return XCTFail("claude-code should support system prompt")
        }
        XCTAssertEqual(appendFlag, "--append-system-prompt")
        XCTAssertEqual(replaceFlag, "--system-prompt")
    }

    func testSystemPromptAxisNoneForOthers() {
        for k in ["codex", "grok", "kimi", "opencode", "github-copilot", "pi", "omp", "custom"] {
            XCTAssertEqual(AgentConfigAxes.systemPromptAxis(forHarness: k), .none, "\(k) should be .none")
        }
    }

    // MARK: Persistence normalization

    func testNormalizedForPersistenceDropsInheritSysPrompt() {
        // An explicit `.inherit` collapses to nil (true inherit).
        let inherit = AgentLaunchConfig(harness: "claude-code", model: "opus",
                                        systemPrompt: SystemPromptSetting(mode: .inherit, text: "x"))
        XCTAssertNil(AgentConfigAxes.normalizedForPersistence(inherit).systemPrompt)
        // A real override survives untouched.
        let replace = AgentLaunchConfig(harness: "claude-code",
                                        systemPrompt: SystemPromptSetting(mode: .replace, text: ""))
        XCTAssertEqual(AgentConfigAxes.normalizedForPersistence(replace).systemPrompt,
                       SystemPromptSetting(mode: .replace, text: ""))
        // Already-nil stays nil.
        XCTAssertNil(AgentConfigAxes.normalizedForPersistence(AgentLaunchConfig(harness: "codex")).systemPrompt)
    }

    // MARK: Naming + description

    func testModelLabel() {
        XCTAssertEqual(AgentConfigAxes.modelLabel(AgentLaunchConfig(harness: "claude-code")), "inherit")
        XCTAssertEqual(AgentConfigAxes.modelLabel(AgentLaunchConfig(harness: "claude-code", model: "opus")), "opus")
        XCTAssertEqual(AgentConfigAxes.modelLabel(AgentLaunchConfig(harness: "omp", model: "deepseek/deepseek-r1")),
                       "deepseek-r1")
        XCTAssertEqual(
            AgentConfigAxes.modelLabel(AgentLaunchConfig(harness: "pi", model: "openrouter/anthropic/claude-opus-4-8")),
            "claude-opus-4-8",
            "the gateway spelling still reads as the model, not the route")
    }

    func testAutoName() {
        XCTAssertEqual(AgentConfigAxes.autoName(for: AgentLaunchConfig(harness: "claude-code", model: "opus")),
                       "Claude opus")
        // inherit model → just the first word of the display name.
        XCTAssertEqual(AgentConfigAxes.autoName(for: AgentLaunchConfig(harness: "codex")), "Codex")
    }

    func testDescribe() {
        XCTAssertEqual(AgentConfigAxes.describe(AgentLaunchConfig(harness: "claude-code", model: "opus", effort: "high")),
                       "claude-code · opus · high")
        XCTAssertEqual(AgentConfigAxes.describe(AgentLaunchConfig(harness: "omp", model: "deepseek/deepseek-chat-v3.1")),
                       "oh-my-pi · deepseek-chat-v3.1")
    }

    func testSubline() {
        // Non-blank recipe → plain describe.
        XCTAssertEqual(
            AgentConfigAxes.subline(AgentLaunchConfig(harness: "claude-code", model: "opus", effort: "high")),
            "claude-code · opus · high")
        // Blank-slate recipe → describe + the ·blank· suffix.
        XCTAssertEqual(
            AgentConfigAxes.subline(AgentLaunchConfig(harness: "claude-code", model: "opus",
                                                      systemPrompt: SystemPromptSetting(mode: .replace, text: ""))),
            "claude-code · opus · ·blank·")
    }

    func testIsBlankSlate() {
        XCTAssertTrue(AgentConfigAxes.isBlankSlate(
            AgentLaunchConfig(harness: "claude-code", systemPrompt: SystemPromptSetting(mode: .replace, text: ""))))
        XCTAssertFalse(AgentConfigAxes.isBlankSlate(
            AgentLaunchConfig(harness: "claude-code", systemPrompt: SystemPromptSetting(mode: .replace, text: "hi"))))
        XCTAssertFalse(AgentConfigAxes.isBlankSlate(
            AgentLaunchConfig(harness: "claude-code", systemPrompt: SystemPromptSetting(mode: .append, text: ""))))
        XCTAssertFalse(AgentConfigAxes.isBlankSlate(AgentLaunchConfig(harness: "claude-code")))
    }

    // MARK: Inherited model base

    func testInheritedModelBaseFactory() {
        // Factory: claude-code base model is opus.
        XCTAssertEqual(AgentConfigAxes.inheritedModelBase(forHarness: "claude-code", from: .factory), "opus")
        // codex has no base model out of the box → nil.
        XCTAssertNil(AgentConfigAxes.inheritedModelBase(forHarness: "codex", from: .factory))
        // unknown kind → nil.
        XCTAssertNil(AgentConfigAxes.inheritedModelBase(forHarness: "unknown-kind", from: .factory))
    }

    // MARK: Installed-probe core

    func testFirstBinaryToken() {
        XCTAssertEqual(AgentConfigAxes.firstBinaryToken("claude --dangerously-skip-permissions"), "claude")
        XCTAssertEqual(AgentConfigAxes.firstBinaryToken("opencode --auto"), "opencode")
        XCTAssertEqual(AgentConfigAxes.firstBinaryToken("FOO=bar mytool --x"), "mytool")
        XCTAssertEqual(AgentConfigAxes.firstBinaryToken("env BAR=baz tool"), "tool")
        XCTAssertNil(AgentConfigAxes.firstBinaryToken(""))
        XCTAssertNil(AgentConfigAxes.firstBinaryToken("   "))
    }
}

// MARK: - Stub catalog

/// `EditorModelCatalog` over a hand-written record set. The index is built by
/// the shipping `ModelCatalogBuilder`, so provider canonicalization, harness
/// ordering, per-harness flag spellings and the effort merge are all the real
/// implementations — only the CLI enumeration is replaced.
private final class StubModelCatalog: EditorModelCatalog {
    private let index: ModelCatalogIndex

    init(_ records: [RawCatalogRecord]) {
        index = ModelCatalogBuilder.build(records: records, source: .snapshot, generatedAt: nil)
    }

    func providers() -> [String] { index.providers }

    func models(forProvider provider: String) -> [CatalogModel] { index.models(forProvider: provider) }

    func harnesses(forModel model: CatalogModel) -> [String] { index.harnesses(forModel: model) }

    func refresh(completion: @escaping () -> Void) { completion() }

    func search(_ query: String, provider: String?, limit: Int) -> [CatalogModel] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = provider.map { models(forProvider: $0) } ?? index.allModels
        guard !needle.isEmpty else { return Array(pool.prefix(limit)) }
        let hits = pool.filter {
            $0.id.lowercased().contains(needle) || $0.displayName.lowercased().contains(needle)
        }
        return Array(hits.prefix(limit))
    }

    func modelFlagValue(for model: CatalogModel, harness: String) -> String {
        index.modelFlagValue(for: model, harness: harness) ?? model.id
    }

    func effortSupport(for model: CatalogModel, harness: String) -> ModelEffortSupport {
        index.effortSupport(for: model, harness: harness)
    }

    func publishedDefaultEffort(for model: CatalogModel, harness: String) -> String? {
        index.defaultEffort(for: model, harness: harness)
    }

    func publishedUpgradeTarget(for model: CatalogModel) -> String? {
        index.upgradeTarget(for: model)
    }

    func publishedUpgradeNote(for model: CatalogModel) -> String? {
        index.upgradeNote(for: model)
    }

    func model(provider: String, id: String) -> CatalogModel? { index.model(provider: provider, id: id) }
}
