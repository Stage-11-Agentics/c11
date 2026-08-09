import XCTest
@testable import c11

/// Pure-logic tests for the tier-1 agent launch picker view-model (C11-181).
/// No Workspace / TabManager / NSApp — safe on the bare local `c11-logic` runner.
/// Verifies the binding prototype's row anatomy, degrade paths (§5.6), and the
/// keyboard state machine (↑↓/⏎/⌥⏎/1–9/esc).
final class AgentPickerModelTests: XCTestCase {

    // MARK: Builders

    private func cfg(
        _ id: String, _ name: String, order: Int,
        harness: String, model: String? = nil, effort: String? = nil,
        sys: SystemPromptSetting? = nil
    ) -> SavedAgentConfig {
        SavedAgentConfig(
            id: id, name: name, order: order,
            config: AgentLaunchConfig(harness: harness, model: model, effort: effort, systemPrompt: sys)
        )
    }

    /// Deterministic display-name map (avoids String(localized:) nondeterminism).
    private let names: (String) -> String = { h in
        [
            "claude-code": "Claude Code", "codex": "Codex", "grok": "Grok Build",
            "kimi": "Kimi", "opencode": "OpenCode", "github-copilot": "GitHub Copilot",
            "pi": "Pi", "omp": "oh-my-pi", "custom": "Custom",
        ][h] ?? h
    }

    /// Environment using the REAL central provider helper (design §1.2), stubbing
    /// the rest so the test is deterministic.
    private func env(
        installed: @escaping (String) -> Bool = { _ in true },
        cost: @escaping (String?) -> (inUSD: Double, outUSD: Double)? = { _ in nil }
    ) -> AgentPickerEnvironment {
        AgentPickerEnvironment(
            displayName: names,
            provider: { AgentLaunchStats.provider(harness: $0, model: $1) },
            isInstalled: installed,
            costFor: cost
        )
    }

    private func library(
        _ configs: [SavedAgentConfig],
        default def: AgentConfigDefault,
        recent: RecentAgentConfig? = nil
    ) -> AgentConfigLibraryFile {
        AgentConfigLibraryFile(configs: configs, default: def, recent: recent)
    }

    // A representative library mirroring the prototype's mock data.
    private func sampleConfigs() -> [SavedAgentConfig] {
        [
            cfg("c1", "Opus deep", order: 0, harness: "claude-code", model: "opus", effort: "high"),
            cfg("c2", "Gregorovich", order: 1, harness: "claude-code", model: "opus",
                sys: SystemPromptSetting(mode: .replace, text: "")),
            cfg("c3", "Fable max", order: 2, harness: "claude-code", model: "fable", effort: "max"),
            cfg("c4", "Codex hi", order: 3, harness: "codex", model: "gpt-5.2", effort: "high"),
            cfg("c5", "Cheap router", order: 4, harness: "omp", model: "deepseek/deepseek-chat-v3.1"),
        ]
    }

    // MARK: 1. Ordering + count

    func testShortlistFollowsOrderAndCount() {
        // Deliberately out-of-array-order `order` values to prove the model sorts.
        let configs = [
            cfg("b", "Second", order: 1, harness: "claude-code", model: "opus"),
            cfg("a", "First", order: 0, harness: "codex", model: "gpt-5.2"),
        ]
        let m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "a")),
            effectiveDefault: configs[1], env: env()
        )
        XCTAssertEqual(m.content.shortlist.map(\.name), ["First", "Second"])
        XCTAssertEqual(m.content.shortlist.map(\.keyBadge), [1, 2])
        XCTAssertEqual(m.content.shortlist.count, 2)
    }

    // MARK: 2. Default marking

    func testPinnedDefaultMarked() {
        let configs = sampleConfigs()
        let m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0], env: env()
        )
        XCTAssertTrue(m.content.shortlist[0].isPinnedDefault)
        XCTAssertFalse(m.content.shortlist[1].isPinnedDefault)
        // Exactly one row carries the dot.
        XCTAssertEqual(m.content.shortlist.filter(\.isPinnedDefault).count, 1)
    }

    /// C11-203 B1: a `recent` record on disk is telemetry now, so it changes
    /// nothing the popover renders — no extra row, no extra nav slot.
    func testRecentRecordDoesNotAffectRenderedContent() {
        let configs = sampleConfigs()
        let base = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0], env: env()
        )
        let withRecent = AgentPickerModel(
            library: library(
                configs,
                default: .init(mode: .pinned, configId: "c1"),
                recent: RecentAgentConfig(
                    configId: "c4", harness: "codex", model: "gpt-5.2", effort: "high",
                    observedAt: Date(timeIntervalSince1970: 999_000)
                )
            ),
            effectiveDefault: configs[0], env: env()
        )
        XCTAssertEqual(base.content, withRecent.content)
    }

    // MARK: 3. Provider derivation (real helper) + sub-line

    func testProviderAndSubLine() {
        let configs = sampleConfigs()
        let m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0], env: env()
        )
        XCTAssertEqual(m.content.shortlist[0].subLine, "claude code · Anthropic · opus")
        XCTAssertEqual(m.content.shortlist[3].subLine, "codex · Openai · gpt-5.2")
        // Router harness: provider rides the model prefix.
        XCTAssertEqual(m.content.shortlist[4].subLine, "oh-my-pi · Deepseek · deepseek-chat-v3.1")
    }

    func testRouterFallbackWhenNoPrefix() {
        // A router harness whose model carries no `provider/` prefix → "router".
        let configs = [cfg("c1", "Loose", order: 0, harness: "omp", model: "some-model")]
        let m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0], env: env()
        )
        XCTAssertEqual(m.content.shortlist[0].subLine, "oh-my-pi · router · some-model")
    }

    func testCustomHarnessHasNoProviderSegment() {
        let configs = [cfg("c1", "Bespoke", order: 0, harness: "custom", model: nil)]
        let m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0], env: env()
        )
        // custom → no provider, model inherits.
        XCTAssertEqual(m.content.shortlist[0].subLine, "custom · inherit")
    }

    // MARK: 4. modelLabel

    func testModelLabel() {
        XCTAssertEqual(AgentPickerModel.modelLabel(nil), "inherit")
        XCTAssertEqual(AgentPickerModel.modelLabel("  "), "inherit")
        XCTAssertEqual(AgentPickerModel.modelLabel("opus"), "opus")
        XCTAssertEqual(AgentPickerModel.modelLabel("deepseek/deepseek-chat-v3.1"), "deepseek-chat-v3.1")
        XCTAssertEqual(AgentPickerModel.modelLabel("anthropic/claude-opus-4-8"), "claude-opus-4-8")
    }

    // MARK: 5. Chips + cost

    func testEffortAndSystemPromptChips() {
        let configs = sampleConfigs()
        let m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0], env: env()
        )
        XCTAssertEqual(m.content.shortlist[0].effortChip, "high")     // Opus deep
        XCTAssertNil(m.content.shortlist[1].effortChip)               // Gregorovich (no effort)
        XCTAssertEqual(m.content.shortlist[1].sysChip, .blank)        // replace + empty = ·blank·
        XCTAssertNil(m.content.shortlist[0].sysChip)                  // inherit → no chip
    }

    func testSysChipAppendMode() {
        let configs = [cfg("c1", "Appender", order: 0, harness: "claude-code", model: "opus",
                           sys: SystemPromptSetting(mode: .append, text: "be terse"))]
        let m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0], env: env()
        )
        XCTAssertEqual(m.content.shortlist[0].sysChip, .mode("append"))
        XCTAssertEqual(m.content.shortlist[0].sysChip?.label, "sys:append")
    }

    func testCostPresentAndAbsent() {
        let configs = [cfg("c1", "Opus deep", order: 0, harness: "claude-code", model: "opus")]
        // Absent catalog → no cost column.
        let absent = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0], env: env()
        )
        XCTAssertNil(absent.content.shortlist[0].cost)
        // Present catalog → formatted "$5/$25" per the prototype's fmt rules.
        let present = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0],
            env: env(cost: { $0 == "opus" ? (5.0, 25.0) : nil })
        )
        XCTAssertEqual(present.content.shortlist[0].cost, "$5/$25")
    }

    func testCostFormatting() {
        XCTAssertEqual(AgentPickerModel.fmt(5.0), "5")
        XCTAssertEqual(AgentPickerModel.fmt(25.0), "25")
        XCTAssertEqual(AgentPickerModel.fmt(0.30), "0.30")
        XCTAssertEqual(AgentPickerModel.fmt(1.75), "1.75")
        XCTAssertEqual(AgentPickerModel.fmt(2.50), "2.5")   // trailing zero dropped ≥1
    }

    // MARK: 6. Keyboard state machine

    /// C11-203 B1: the recent row is gone, so ↑↓ clamps at the last shortlist
    /// row — a `recent` record on disk must not add a phantom nav slot.
    func testArrowNavigationClampsAtLastShortlistRow() {
        let configs = sampleConfigs() // 5 configs
        let recent = RecentAgentConfig(configId: "c4", harness: "codex", model: "gpt-5.2")
        var m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1"), recent: recent),
            effectiveDefault: configs[0], env: env()
        )
        XCTAssertEqual(m.selectedIndex, -1)
        _ = m.handleKey(.down); XCTAssertEqual(m.selectedIndex, 0)
        for _ in 0..<10 { _ = m.handleKey(.down) }
        XCTAssertEqual(m.selectedIndex, 4) // last shortlist row, clamped
        // The row past the old recent slot resolves to the last config, not a
        // phantom recent target.
        XCTAssertEqual(m.handleKey(.enter), .launch(configs[4]))
        _ = m.handleKey(.up); XCTAssertEqual(m.selectedIndex, 3)
        for _ in 0..<10 { _ = m.handleKey(.up) }
        XCTAssertEqual(m.selectedIndex, 0) // clamps at 0, never back to -1
    }

    func testArrowNavigationOnEmptyLibraryStaysUnfocused() {
        let seed = AgentConfigLibraryFile.factory.configs[0]
        var m = AgentPickerModel(
            library: library([], default: .init(mode: .pinned, configId: seed.id)),
            effectiveDefault: seed, env: env()
        )
        XCTAssertEqual(m.handleKey(.down), PickerAction.none)
        XCTAssertEqual(m.selectedIndex, -1)
        // ⏎ with nothing to focus still acts on the effective default.
        XCTAssertEqual(m.handleKey(.enter), .launch(seed))
    }

    func testEnterLaunchesSelectedElseEffectiveDefault() {
        let configs = sampleConfigs()
        var m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0], env: env()
        )
        // Nothing selected → effective default.
        XCTAssertEqual(m.handleKey(.enter), .launch(configs[0]))
        _ = m.handleKey(.down); _ = m.handleKey(.down) // select index 1
        XCTAssertEqual(m.handleKey(.enter), .launch(configs[1]))
    }

    func testOptionEnterPinsSelected() {
        let configs = sampleConfigs()
        var m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0], env: env()
        )
        _ = m.handleKey(.down) // select index 0
        XCTAssertEqual(m.handleKey(.enter, option: true), .pin(configs[0]))
    }

    func testDigitKeysLaunchNth() {
        let configs = sampleConfigs()
        var m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0], env: env()
        )
        XCTAssertEqual(m.handleKey(.digit(1)), .launch(configs[0]))
        XCTAssertEqual(m.handleKey(.digit(5)), .launch(configs[4]))
        XCTAssertEqual(m.handleKey(.digit(6)), .none) // past the shortlist
    }

    func testEscapeCloses() {
        let configs = sampleConfigs()
        var m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0], env: env()
        )
        XCTAssertEqual(m.handleKey(.escape), .close)
    }

    // MARK: 7. Not-installed

    func testNotInstalledRowStillPinsButPlainLaunchRefuses() {
        let configs = sampleConfigs()
        // codex (c4, index 3) is not installed.
        var m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0],
            env: env(installed: { $0 != "codex" })
        )
        XCTAssertFalse(m.content.shortlist[3].isInstalled)
        // Digit launch of the not-installed row → explicit refusal.
        XCTAssertEqual(m.handleKey(.digit(4)), .notInstalled(configs[3]))
        // ⌥⏎ still pins it.
        _ = m.handleKey(.down); _ = m.handleKey(.down); _ = m.handleKey(.down); _ = m.handleKey(.down) // idx 3
        XCTAssertEqual(m.selectedIndex, 3)
        XCTAssertEqual(m.handleKey(.enter, option: true), .pin(configs[3]))
        // A plain ⏎ on it returns the same explicit refusal.
        XCTAssertEqual(m.handleKey(.enter), .notInstalled(configs[3]))
    }

    // MARK: 8. Review-regression: default Enter honors pin/installed (F1/F2)

    func testEnterDefaultRespectsInstalledGuard() {
        let configs = sampleConfigs() // default c1 = claude-code
        var m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0],
            env: env(installed: { $0 != "claude-code" }) // default's harness not installed
        )
        XCTAssertEqual(m.selectedIndex, -1)
        XCTAssertEqual(m.handleKey(.enter), .notInstalled(configs[0]))
    }

    /// An effective default with a blank id (no matching shortlist row) still
    /// runs through the installed guard rather than launching blind.
    func testUnmatchedEffectiveDefaultRespectsInstalledGuard() {
        let configs = sampleConfigs()
        let transient = cfg(
            "",
            "Ad-hoc router",
            order: -1,
            harness: "opencode",
            model: "openai/gpt-5.2"
        )
        var m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: transient,
            env: env(installed: { $0 != "opencode" })
        )

        XCTAssertEqual(m.selectedIndex, -1)
        XCTAssertEqual(m.handleKey(.enter), .notInstalled(transient))
    }

    func testCommandEnterOpensViewAllNeverLaunches() {
        let configs = sampleConfigs()
        var m = AgentPickerModel(
            library: library(configs, default: .init(mode: .pinned, configId: "c1")),
            effectiveDefault: configs[0], env: env()
        )
        // ⌘⏎ = View all, from any selection state — never launches.
        XCTAssertEqual(m.handleKey(.enter, command: true), .viewAll)
        _ = m.handleKey(.down) // select row 0
        XCTAssertEqual(m.handleKey(.enter, command: true), .viewAll)
    }
}
