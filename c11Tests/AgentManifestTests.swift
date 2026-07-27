import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Golden-lock tests for the Phase-0 agent registry.
///
/// The point of these tests: `AgentManifest` carries data that today *also*
/// lives in per-agent switches (`AgentType`, `AgentDetector`, `AgentChip`,
/// `MetadataKey.canonicalTerminalTypes`, `ConversationStrategyRegistry`,
/// `AgentRestartRegistry.phase1`). Each test asserts the manifest reproduces
/// the matching switch *exactly*. As long as these stay green, a later phase
/// can delete a switch and read the manifest with provably zero behavior
/// change. If someone edits a switch without updating the manifest (or vice
/// versa), the relevant test fails and points at the drift.
final class AgentManifestTests: XCTestCase {
    private var registry: AgentRegistry { .shared }

    /// Every `AgentType` case has exactly one manifest, and the registry has no
    /// extras. Adding a new `AgentType` without a manifest fails here.
    func testRegistryCoversAllAgentTypesExactly() {
        let manifestKinds = Set(registry.all.map(\.kind))
        let enumKinds = Set(AgentType.allCases.map(\.rawValue))
        XCTAssertEqual(manifestKinds, enumKinds,
                       "AgentRegistry.shared must hold exactly one manifest per AgentType case")
        XCTAssertEqual(registry.all.count, AgentType.allCases.count,
                       "no duplicate or orphan manifests")
    }

    /// `DefaultAgentConfig` surfaces: display name, factory command, factory
    /// initial prompt.
    func testDisplayNameAndFactoryParity() {
        for agent in AgentType.allCases {
            guard let m = registry.manifest(for: agent) else {
                XCTFail("missing manifest for \(agent.rawValue)"); continue
            }
            XCTAssertEqual(m.displayName, agent.displayName,
                           "displayName drift for \(agent.rawValue)")
            XCTAssertEqual(m.factoryCommand, agent.factoryCommand,
                           "factoryCommand drift for \(agent.rawValue)")
            XCTAssertEqual(m.factoryInitialPrompt, agent.factoryInitialPrompt,
                           "factoryInitialPrompt drift for \(agent.rawValue)")
        }
    }

    /// `AgentDetector.classify`: every declared comm and node-args substring
    /// classifies back to the manifest's kind.
    func testDetectorParity() {
        for m in registry.all {
            for comm in m.detectComms {
                XCTAssertEqual(AgentDetector.classify(comm: comm, args: ""), m.kind,
                               "comm '\(comm)' should classify as \(m.kind)")
            }
            for sub in m.detectNodeArgsSubstrings {
                XCTAssertEqual(AgentDetector.classify(comm: "node", args: sub), m.kind,
                               "node args '\(sub)' should classify as \(m.kind)")
            }
        }
    }

    /// `AgentChip` icon + SF Symbol mappings (branded agents only).
    func testChipIconParity() {
        for m in registry.all {
            if let icon = m.iconAsset {
                XCTAssertEqual(AgentChipResolver.iconAssetName(forTerminalType: m.kind), icon,
                               "iconAsset drift for \(m.kind)")
            }
            if let sf = m.sfSymbolFallback {
                XCTAssertEqual(AgentChipResolver.sfSymbolFallback(forTerminalType: m.kind), sf,
                               "sfSymbol drift for \(m.kind)")
            }
        }
    }

    /// `MetadataKey.canonicalTerminalTypes` membership.
    func testCanonicalTerminalTypeParity() {
        for m in registry.all {
            XCTAssertEqual(m.isCanonicalTerminalType,
                           MetadataKey.canonicalTerminalTypes.contains(m.kind),
                           "canonical-terminal-type flag drift for \(m.kind)")
        }
    }

    /// `ConversationStrategyRegistry.v1` strategy presence.
    func testConversationStrategyPresenceParity() {
        for m in registry.all {
            XCTAssertEqual(m.hasConversationStrategy,
                           ConversationStrategyRegistry.v1.contains(kind: m.kind),
                           "strategy-presence flag drift for \(m.kind)")
        }
    }

    /// The crux: `manifest.resumeCommand(...)` reproduces
    /// `AgentRestartRegistry.phase1.resolveCommand(...)` across representative
    /// inputs — valid id, valid id + project dir, invalid id, nil id. This
    /// proves the manifest can drive the restart registry in a later phase,
    /// including claude's cd-prefix special case and the absent-row agents.
    func testResumeCommandReproducesPhase1() {
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        let projectDir = "/Users/atin/Projects/example"
        let inputs: [(String?, [String: String])] = [
            (uuid, [:]),
            (uuid, [SurfaceMetadataKeyName.claudeSessionProjectDir: projectDir]),
            ("not-a-valid-uuid", [:]),
            (nil, [:])
        ]
        for m in registry.all {
            for (sessionId, metadata) in inputs {
                let fromManifest = m.resumeCommand(sessionId: sessionId, metadata: metadata)
                let fromPhase1 = AgentRestartRegistry.phase1.resolveCommand(
                    terminalType: m.kind, sessionId: sessionId, metadata: metadata)
                XCTAssertEqual(fromManifest, fromPhase1,
                               "resume drift for \(m.kind) (sid=\(sessionId ?? "nil"), meta=\(metadata))")
            }
        }
    }

    /// System-prompt axis seed: claude-code declares both flags; every other
    /// built-in has no system-prompt axis in v1 (`systemPromptArg == nil`), the
    /// same gating shape as `effortArg`. Locks the per-harness seed so a new
    /// harness that quietly grows a system-prompt flag (or claude losing one) is
    /// caught here.
    func testSystemPromptAxisSeed() {
        for m in registry.all {
            if m.kind == "claude-code" {
                let arg = m.launch.systemPromptArg
                XCTAssertNotNil(arg, "claude-code must declare a system-prompt axis")
                XCTAssertEqual(arg?.appendFlag, "--append-system-prompt")
                XCTAssertEqual(arg?.replaceFlag, "--system-prompt")
                XCTAssertEqual(arg?.flag(for: .append), "--append-system-prompt")
                XCTAssertEqual(arg?.flag(for: .replace), "--system-prompt")
                XCTAssertNil(arg?.flag(for: .inherit))
                XCTAssertEqual(Set(arg?.detectTokens ?? []),
                               ["--append-system-prompt", "--system-prompt"])
            } else {
                XCTAssertNil(m.launch.systemPromptArg,
                             "\(m.kind) must have no system-prompt axis in v1")
            }
        }
    }

    /// Spot-check the literal claude resume string (the cd-prefixed branch),
    /// so a regression in the shared evaluator is caught even if phase1 drifts
    /// in lockstep.
    func testClaudeResumeWithProjectDirIsCdPrefixed() {
        guard let m = registry.manifest(forKind: "claude-code") else {
            XCTFail("missing claude-code manifest"); return
        }
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        let out = m.resumeCommand(
            sessionId: uuid,
            metadata: [SurfaceMetadataKeyName.claudeSessionProjectDir: "/tmp/wt"])
        XCTAssertEqual(
            out,
            "cd '/tmp/wt' && claude --dangerously-skip-permissions --resume \(uuid)\n")
    }
}

/// Every rail that synthesizes a command line for an agent must carry that
/// agent's auto-approve flag. c11's contract is that an agent it launches
/// never stops on a permission prompt the operator didn't ask for — and a
/// *resumed* agent is still a launched agent.
///
/// The bug these tests lock out: `codex resume <id>` was typed on restore
/// without `--yolo`, so a resumed Codex pane sat on approval prompts while its
/// freshly-launched twin (`codex --yolo`) never did. The same drift existed on
/// opencode, kimi, omp, and github-copilot.
final class AgentAutoApproveCoverageTests: XCTestCase {
    private var registry: AgentRegistry { .shared }

    /// A ref each strategy accepts as resumable, keyed by kind. Ids match each
    /// strategy's documented grammar (UUID, opencode `ses_`+base62, or an
    /// opaque non-placeholder id for the fresh-launch kinds).
    private static let resumableIDs: [String: String] = [
        "claude-code": "550e8400-e29b-41d4-a716-446655440000",
        "codex": "550e8400-e29b-41d4-a716-446655440000",
        "omp": "019f0b94-be86-7000-bf88-d9b6dcae2616",
        "pi": "550e8400-e29b-41d4-a716-446655440000",
        "opencode": "ses_0fda89a49ffeLHwJXtrxnn4X6g",
        // grok resumes an exact UUID; kimi/copilot re-launch fresh and accept
        // any non-placeholder id.
        "grok": "550e8400-e29b-41d4-a716-446655440000",
        "kimi": "real-id",
        "github-copilot": "real-id",
    ]

    private func resumeText(forKind kind: String) -> String? {
        guard let strategy = ConversationStrategyRegistry.v1.strategy(forKind: kind),
              let id = Self.resumableIDs[kind] else { return nil }
        let ref = ConversationRef(
            kind: kind,
            id: id,
            placeholder: false,
            cwd: nil,
            capturedAt: Date(),
            capturedVia: .hook,
            state: .alive
        )
        guard case .typeCommand(let text, _) = strategy.resume(ref: ref) else { return nil }
        return text
    }

    /// The operator-visible launch command carries the flag.
    func testFactoryCommandsCarryAutoApproveFlags() {
        for (kind, flags) in AgentAutoApprove.byKind {
            guard let m = registry.manifest(forKind: kind) else {
                XCTFail("no manifest for auto-approve kind \(kind)"); continue
            }
            XCTAssertTrue(
                m.factoryCommand.contains(flags),
                "\(kind) factoryCommand '\(m.factoryCommand)' is missing \(flags)")
        }
    }

    /// The snapshot-restore rail carries it too — this is the one that regressed.
    func testRestartRegistryResumeCommandsCarryAutoApproveFlags() {
        let registryRows = AgentRestartRegistry.phase1
        for m in registry.all {
            guard let flags = AgentAutoApprove.flags(forKind: m.kind) else { continue }
            guard let command = registryRows.resolveCommand(
                terminalType: m.kind,
                sessionId: Self.resumableIDs[m.kind],
                metadata: [:]
            ) else { continue }  // `.none` kinds re-launch through the normal path
            XCTAssertTrue(
                command.contains(flags),
                "\(m.kind) restart command '\(command)' is missing \(flags)")
        }
    }

    /// …and so does the conversation-store rail, which is what actually types
    /// the resume line for an exact captured session.
    func testConversationStrategyResumeCommandsCarryAutoApproveFlags() {
        for m in registry.all where m.hasConversationStrategy {
            guard let text = resumeText(forKind: m.kind) else {
                // Not `continue`: a kind whose strategy stops producing a
                // command for a plainly resumable ref would otherwise drop out
                // of this test's coverage silently.
                XCTFail("\(m.kind) strategy typed no resume command for a live ref")
                continue
            }
            guard let flags = AgentAutoApprove.flags(forKind: m.kind) else {
                continue  // pi: no auto-approve flag exists to carry
            }
            XCTAssertTrue(
                text.contains(flags),
                "\(m.kind) strategy resume '\(text)' is missing \(flags)")
        }
    }

    /// `ResumeDecisionEngine` re-spells the codex command because it also
    /// compiles into the CLI target, which does not link `AgentManifest`. Pin
    /// the two spellings together so the copy can't drift.
    func testResumeDecisionEngineCodexMatchesStrategy() {
        let id = Self.resumableIDs["codex"]!
        let decision = ResumeDecisionEngine.decide(ResumeDecisionInput(
            mode: .clean,
            auditComplete: true,
            ownership: .unique,
            kind: "codex",
            id: id,
            placeholder: false,
            state: .alive,
            exactIDValid: true,
            transcriptEvidence: .verified
        ))
        guard case .command(let command) = decision else {
            XCTFail("expected a codex resume command, got \(decision)"); return
        }
        XCTAssertEqual(command.text, resumeText(forKind: "codex"))
    }

    /// Kinds absent from the table are a deliberate statement ("this CLI has
    /// no auto-approve flag"), not an oversight. Locking the list means adding
    /// an agent forces a decision about its permission posture.
    func testKindsWithoutAutoApproveFlagsAreDeliberate() {
        let uncovered = Set(registry.all.map(\.kind))
            .subtracting(AgentAutoApprove.byKind.keys)
        XCTAssertEqual(
            uncovered, ["pi", "custom"],
            "an agent gained/lost an auto-approve flag: reconcile AgentAutoApprove")
    }
}
