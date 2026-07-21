import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure-logic tests for the Saved Configs editor model (C11-182, design §1.2).
/// No SwiftUI / `NSApp` construction, so these run in `c11-logic` locally.
final class AgentConfigEditorModelTests: XCTestCase {

    // MARK: Model axis

    func testModelAxisClaudeIsFamilies() {
        guard case .families(let fams) = AgentConfigAxes.modelAxis(forHarness: "claude-code") else {
            return XCTFail("claude-code should be .families")
        }
        XCTAssertEqual(fams, ClaudeModelFamily.allCases)
        XCTAssertEqual(fams.map(\.rawValue), ["opus", "sonnet", "haiku", "fable"])
    }

    func testModelAxisRouterHarnesses() {
        for k in ["opencode", "pi", "omp"] {
            XCTAssertEqual(AgentConfigAxes.modelAxis(forHarness: k), .router, "\(k) should be .router")
        }
    }

    func testModelAxisFreeformHarnesses() {
        let expected: [String: String] = [
            "codex": "OpenAI", "grok": "xAI", "kimi": "Moonshot", "github-copilot": "GitHub",
        ]
        for (k, label) in expected {
            guard case .freeform(let providerLabel) = AgentConfigAxes.modelAxis(forHarness: k) else {
                return XCTFail("\(k) should be .freeform")
            }
            XCTAssertEqual(providerLabel, label)
        }
    }

    func testModelAxisCustomIsNone() {
        XCTAssertEqual(AgentConfigAxes.modelAxis(forHarness: "custom"), .none)
        XCTAssertEqual(AgentConfigAxes.modelAxis(forHarness: "unknown-kind"), .none)
    }

    // MARK: Effort axis

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

    func testEffortAxisNone() {
        for k in ["grok", "kimi", "opencode", "github-copilot", "custom"] {
            XCTAssertEqual(AgentConfigAxes.effortAxis(forHarness: k), .none, "\(k) should be .none")
        }
    }

    func testEffortChipValues() {
        XCTAssertEqual(AgentConfigAxes.effortChipValues(forHarness: "claude-code"),
                       ["low", "medium", "high", "xhigh", "max"])
        // codex passthrough → the curated suggestion set (matches the prototype).
        XCTAssertEqual(AgentConfigAxes.effortChipValues(forHarness: "codex"), ["low", "medium", "high"])
        XCTAssertEqual(AgentConfigAxes.effortChipValues(forHarness: "grok"), [])
    }

    // MARK: System-prompt axis

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

    // MARK: Provider identity

    func testProviderClass() {
        XCTAssertEqual(AgentConfigAxes.providerClass(forHarness: "claude-code"), .fixed(label: "Anthropic"))
        XCTAssertEqual(AgentConfigAxes.providerClass(forHarness: "codex"), .fixed(label: "OpenAI"))
        XCTAssertEqual(AgentConfigAxes.providerClass(forHarness: "opencode"), .router)
        XCTAssertEqual(AgentConfigAxes.providerClass(forHarness: "custom"), .custom)
    }

    func testProviderDisplayLabel() {
        XCTAssertEqual(AgentConfigAxes.providerDisplayLabel(forHarness: "grok"), "xAI")
        XCTAssertEqual(AgentConfigAxes.providerDisplayLabel(forHarness: "pi"), "OpenRouter")
        XCTAssertEqual(AgentConfigAxes.providerDisplayLabel(forHarness: "custom"), "")
    }

    // MARK: Harness-switch reconciliation (prototype index.html:1042-1053)

    func testReconcileDropsIncompatibleModelClaudeToRouter() {
        let c = AgentLaunchConfig(harness: "claude-code", model: "opus")
        let out = AgentConfigAxes.reconcileHarnessSwitch(c, to: "omp")
        XCTAssertEqual(out.harness, "omp")
        XCTAssertNil(out.model, "opus is not a router id → dropped")
    }

    func testReconcileDropsRouterModelToClaude() {
        let c = AgentLaunchConfig(harness: "omp", model: "deepseek/deepseek-chat-v3.1")
        let out = AgentConfigAxes.reconcileHarnessSwitch(c, to: "claude-code")
        XCTAssertNil(out.model, "slashed router id is not a claude family → dropped")
    }

    func testReconcileKeepsCompatibleModel() {
        let c = AgentLaunchConfig(harness: "claude-code", model: "sonnet")
        let out = AgentConfigAxes.reconcileHarnessSwitch(c, to: "claude-code")
        XCTAssertEqual(out.model, "sonnet")
    }

    func testReconcileDropsEffortOutsideTierSet() {
        let c = AgentLaunchConfig(harness: "claude-code", effort: "max")
        // grok has no effort axis → dropped.
        XCTAssertNil(AgentConfigAxes.reconcileHarnessSwitch(c, to: "grok").effort)
        // pi's tiers do not include "max" → dropped.
        XCTAssertNil(AgentConfigAxes.reconcileHarnessSwitch(c, to: "pi").effort)
        // claude keeps "max".
        XCTAssertEqual(AgentConfigAxes.reconcileHarnessSwitch(c, to: "claude-code").effort, "max")
    }

    func testReconcileDropsSystemPromptWhenUnsupported() {
        let c = AgentLaunchConfig(harness: "claude-code",
                                  systemPrompt: SystemPromptSetting(mode: .replace, text: ""))
        let out = AgentConfigAxes.reconcileHarnessSwitch(c, to: "codex")
        XCTAssertNil(out.systemPrompt, "codex has no system-prompt axis → dropped")
    }

    func testReconcileSeedsInheritSystemPromptWhenSupported() {
        let c = AgentLaunchConfig(harness: "codex", model: "gpt-5.2")
        let out = AgentConfigAxes.reconcileHarnessSwitch(c, to: "claude-code")
        XCTAssertEqual(out.systemPrompt, SystemPromptSetting(mode: .inherit))
    }

    func testReconcileDropsFreeformModelWithSlashToRouter() {
        // freeform harness carrying a non-slash id → switching to router drops it.
        let c = AgentLaunchConfig(harness: "codex", model: "gpt-5.2")
        XCTAssertNil(AgentConfigAxes.reconcileHarnessSwitch(c, to: "opencode").model)
    }

    // MARK: Naming + description

    func testModelLabel() {
        XCTAssertEqual(AgentConfigAxes.modelLabel(AgentLaunchConfig(harness: "claude-code")), "inherit")
        XCTAssertEqual(AgentConfigAxes.modelLabel(AgentLaunchConfig(harness: "claude-code", model: "opus")), "opus")
        XCTAssertEqual(AgentConfigAxes.modelLabel(AgentLaunchConfig(harness: "omp", model: "deepseek/deepseek-r1")),
                       "deepseek-r1")
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
        XCTAssertEqual(AgentConfigAxes.firstBinaryToken("opencode run --dangerously-skip-permissions"), "opencode")
        XCTAssertEqual(AgentConfigAxes.firstBinaryToken("FOO=bar mytool --x"), "mytool")
        XCTAssertEqual(AgentConfigAxes.firstBinaryToken("env BAR=baz tool"), "tool")
        XCTAssertNil(AgentConfigAxes.firstBinaryToken(""))
        XCTAssertNil(AgentConfigAxes.firstBinaryToken("   "))
    }

    // MARK: Static seeds

    func testRouterCatalogNonEmpty() {
        XCTAssertFalse(AgentConfigAxes.routerModelCatalog.isEmpty)
        let flat = AgentConfigAxes.routerModelCatalog.flatMap { $0.models }
        XCTAssertTrue(flat.allSatisfy { $0.contains("/") }, "every router id carries a provider prefix")
        XCTAssertTrue(flat.contains("deepseek/deepseek-chat-v3.1"))
    }

    func testFreeformSuggestions() {
        XCTAssertEqual(AgentConfigAxes.freeformSuggestions(forHarness: "codex"),
                       ["gpt-5.2", "gpt-5.2-codex", "gpt-5.2-mini"])
        XCTAssertEqual(AgentConfigAxes.freeformSuggestions(forHarness: "kimi"), ["kimi-k2"])
        XCTAssertTrue(AgentConfigAxes.freeformSuggestions(forHarness: "opencode").isEmpty)
    }

    // MARK: Stats bars

    func testStatsBarsSortedWithLeader() {
        let result = LaunchStatsResult(
            window: .all, axis: .model,
            tally: ["opus": 412, "fable": 24, "sonnet": 19],
            count: 455, lastTs: nil
        )
        let bars = AgentLaunchStatsView.statsBars(from: result)
        XCTAssertEqual(bars.map(\.label), ["opus", "fable", "sonnet"])
        XCTAssertTrue(bars[0].isLeader)
        XCTAssertFalse(bars[1].isLeader)
        XCTAssertEqual(bars[0].widthOfMax, 1.0, accuracy: 0.0001)
        XCTAssertEqual(bars[0].shareOfTotal, 412.0 / 455.0, accuracy: 0.0001)
        XCTAssertEqual(bars[1].widthOfMax, 24.0 / 412.0, accuracy: 0.0001)
    }

    func testStatsBarsTieBreakByLabel() {
        let result = LaunchStatsResult(
            window: .today, axis: .model,
            tally: ["zeta": 5, "alpha": 5], count: 10, lastTs: nil
        )
        let bars = AgentLaunchStatsView.statsBars(from: result)
        XCTAssertEqual(bars.map(\.label), ["alpha", "zeta"], "ties break by label ascending")
    }

    func testStatsBarsEmpty() {
        let result = LaunchStatsResult(window: .all, axis: .model, tally: [:], count: 0, lastTs: nil)
        XCTAssertTrue(AgentLaunchStatsView.statsBars(from: result).isEmpty)
    }
}
