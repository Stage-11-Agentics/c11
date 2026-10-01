import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Drives the real launch stamps (not hand-built sources) and asserts the tier
/// each lands at, then that detection and an agent's own declaration order
/// correctly against them.
@MainActor
final class AgentLaunchModelTierTests: XCTestCase {
    private var workspace: Workspace!
    private var surface: UUID!

    override func setUp() {
        super.setUp()
        workspace = Workspace()
        surface = UUID()
    }

    override func tearDown() {
        TabMetadataStore.shared.removeSurface(workspaceId: workspace.id, surfaceId: surface)
        super.tearDown()
    }

    private func snapshot() -> (values: [String: Any], sources: [String: MetadataSource]) {
        let (values, raw) = TabMetadataStore.shared.getMetadata(workspaceId: workspace.id, surfaceId: surface)
        var sources: [String: MetadataSource] = [:]
        for (key, entry) in raw {
            if let name = entry["source"] as? String, let source = MetadataSource(rawValue: name) { sources[key] = source }
        }
        return (values, sources)
    }

    private func effective() -> (model: String?, label: String?) {
        let (values, sources) = snapshot()
        return AgentModelPrecedence.effective(
            model: values["model"] as? String, modelSource: sources["model"],
            modelLabel: values["model_label"] as? String, labelSource: sources["model_label"],
            detected: values[AgentModelDetector.MetadataKeys.detected] as? String
        )
    }

    func testLaunchAgentStampsIdentityAtDeclareAndTheModelAtTheLaunchTier() {
        workspace.stampAgentLaunchIdentity(surfaceId: surface, kind: "claude-code", model: "claude-opus-4-7", task: nil, title: nil)
        let (values, sources) = snapshot()
        XCTAssertEqual(values["model"] as? String, "claude-opus-4-7")
        XCTAssertEqual(sources["model"], .heuristic)
        XCTAssertEqual(sources["terminal_type"], .declare, "identity stays declared")
    }

    func testLaunchAgentWithANonKebabModelStampsTheLabelAtTheLaunchTier() {
        workspace.stampAgentLaunchIdentity(surfaceId: surface, kind: "codex", model: "gpt-5.2", task: nil, title: nil)
        let (values, sources) = snapshot()
        XCTAssertEqual(values["model_label"] as? String, "gpt-5.2")
        XCTAssertEqual(sources["model_label"], .heuristic)
    }

    func testTheAButtonStampIsAtTheLaunchTierToo() {
        workspace.stampLaunchIdentity(surfaceId: surface, resolvedModel: "claude-sonnet-4-6")
        XCTAssertEqual(snapshot().sources["model"], .heuristic)
    }

    func testADetectedModelOutranksTheLaunchStampButNotTheAgentsOwnDeclaration() {
        workspace.stampAgentLaunchIdentity(surfaceId: surface, kind: "claude-code", model: "claude-opus-4-7", task: nil, title: nil)
        XCTAssertEqual(effective().model, "claude-opus-4-7", "launch stamp shows until something better")

        TabMetadataStore.shared.setInternal(
            workspaceId: workspace.id, surfaceId: surface,
            key: AgentModelDetector.MetadataKeys.detected, value: "claude-sonnet-4-6", source: .derived
        )
        XCTAssertEqual(effective().model, "claude-sonnet-4-6", "a /model switch shows over the launch stamp")

        // What `c11 set-agent --model` (and nothing else now) writes: tier declare.
        _ = try? TabMetadataStore.shared.setMetadata(
            workspaceId: workspace.id, surfaceId: surface,
            partial: ["model": "claude-haiku-4-5"], mode: .merge, source: .declare
        )
        XCTAssertEqual(effective().model, "claude-haiku-4-5")
    }
}
