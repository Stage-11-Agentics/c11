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
