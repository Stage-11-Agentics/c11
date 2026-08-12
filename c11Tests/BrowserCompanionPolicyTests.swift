import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Executable contract tests for the AppKit/SwiftUI-free ACB-00 foundation.
final class BrowserCompanionPolicyTests: XCTestCase {
    private let browserID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let agentAID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let agentBID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    private func descriptor(
        _ id: UUID,
        name: String,
        ordinal: Int,
        kind: String = "codex"
    ) -> AgentDescriptor {
        AgentDescriptor(
            identity: CompanionSurfaceIdentity(
                surfaceID: id,
                surfaceRef: "surface:\(ordinal)",
                surfaceOrdinal: ordinal,
                displayName: name
            ),
            terminalKind: kind
        )
    }

    private var agentA: AgentDescriptor { descriptor(agentAID, name: "Maya", ordinal: 3) }
    private var agentB: AgentDescriptor { descriptor(agentBID, name: "Build Agent", ordinal: 5) }
    private var linkA: AgentSurfaceLink { AgentSurfaceLink(surfaceID: agentAID, lastKnownName: "Maya") }

    private func presentation(
        link: AgentSurfaceLink?,
        active: UUID?,
        generation: UInt64 = 0,
        agents: [AgentDescriptor]? = nil,
        grant: CompanionRevealGrant? = nil
    ) -> BrowserCompanionPresentation {
        BrowserCompanionPolicy.presentation(
            browserSurfaceID: browserID,
            link: link,
            context: AgentContextState(activeAgentSurfaceID: active, generation: generation),
            liveAgents: agents ?? [agentA, agentB],
            revealGrant: grant
        )
    }

    // MARK: - Seven-state truth table

    func testPresentationTruthTableCoversAllSevenStates() {
        XCTAssertEqual(presentation(link: nil, active: nil), .unlinked)
        XCTAssertEqual(presentation(link: linkA, active: nil), .linkedNoContext(linked: agentA))
        XCTAssertEqual(presentation(link: linkA, active: agentAID), .aligned(linked: agentA))
        XCTAssertEqual(
            presentation(link: linkA, active: agentBID),
            .veiled(linked: agentA, active: agentB)
        )

        let mismatchGrant = CompanionRevealGrant(
            browserSurfaceID: browserID,
            linkedAgentSurfaceID: agentAID,
            activeAgentSurfaceID: agentBID,
            contextGeneration: 7
        )
        XCTAssertEqual(
            presentation(link: linkA, active: agentBID, generation: 7, grant: mismatchGrant),
            .revealed(linked: agentA, active: agentB)
        )

        XCTAssertEqual(
            presentation(link: linkA, active: agentBID, agents: [agentB]),
            .orphaned(link: linkA)
        )
        XCTAssertEqual(
            presentation(
                link: linkA,
                active: agentBID,
                generation: 7,
                agents: [agentB],
                grant: mismatchGrant
            ),
            .orphanedRevealed(link: linkA)
        )
    }

    func testOnlyVeiledAndOrphanedStatesBlockWebContent() {
        let cases: [(BrowserCompanionPresentation, Bool)] = [
            (.unlinked, true),
            (.linkedNoContext(linked: agentA), true),
            (.aligned(linked: agentA), true),
            (.veiled(linked: agentA, active: agentB), false),
            (.revealed(linked: agentA, active: agentB), true),
            (.orphaned(link: linkA), false),
            (.orphanedRevealed(link: linkA), true),
        ]
        for (state, expectedInteractive) in cases {
            XCTAssertEqual(state.isWebContentInteractive, expectedInteractive, "state=\(state.state)")
            XCTAssertEqual(BrowserPortalCompanionState(presentation: state).blocksWebContent, !expectedInteractive)
        }
    }

    // MARK: - Reveal grant identity and generation

    func testRevealGrantMustMatchEveryIdentityField() {
        let valid = CompanionRevealGrant(
            browserSurfaceID: browserID,
            linkedAgentSurfaceID: agentAID,
            activeAgentSurfaceID: agentBID,
            contextGeneration: 9
        )
        XCTAssertEqual(
            presentation(link: linkA, active: agentBID, generation: 9, grant: valid).state,
            .revealed
        )

        let wrongBrowser = CompanionRevealGrant(
            browserSurfaceID: UUID(),
            linkedAgentSurfaceID: valid.linkedAgentSurfaceID,
            activeAgentSurfaceID: valid.activeAgentSurfaceID,
            contextGeneration: valid.contextGeneration
        )
        let wrongLink = CompanionRevealGrant(
            browserSurfaceID: valid.browserSurfaceID,
            linkedAgentSurfaceID: agentBID,
            activeAgentSurfaceID: valid.activeAgentSurfaceID,
            contextGeneration: valid.contextGeneration
        )
        let wrongContext = CompanionRevealGrant(
            browserSurfaceID: valid.browserSurfaceID,
            linkedAgentSurfaceID: valid.linkedAgentSurfaceID,
            activeAgentSurfaceID: agentAID,
            contextGeneration: valid.contextGeneration
        )
        let wrongGeneration = CompanionRevealGrant(
            browserSurfaceID: valid.browserSurfaceID,
            linkedAgentSurfaceID: valid.linkedAgentSurfaceID,
            activeAgentSurfaceID: valid.activeAgentSurfaceID,
            contextGeneration: valid.contextGeneration - 1
        )

        for staleGrant in [wrongBrowser, wrongLink, wrongContext, wrongGeneration] {
            XCTAssertEqual(
                presentation(link: linkA, active: agentBID, generation: 9, grant: staleGrant).state,
                .veiled
            )
        }
    }

    func testAtoBtoADoesNotRetainOldReveal() {
        let revealWhileBIsActive = CompanionRevealGrant(
            browserSurfaceID: browserID,
            linkedAgentSurfaceID: agentAID,
            activeAgentSurfaceID: agentBID,
            contextGeneration: 2
        )
        XCTAssertEqual(
            presentation(link: linkA, active: agentBID, generation: 2, grant: revealWhileBIsActive).state,
            .revealed
        )
        XCTAssertEqual(
            presentation(link: linkA, active: agentAID, generation: 3, grant: revealWhileBIsActive).state,
            .aligned
        )
        XCTAssertEqual(
            presentation(link: linkA, active: agentBID, generation: 4, grant: revealWhileBIsActive).state,
            .veiled
        )
    }

    // MARK: - Shared agent identity

    func testAgentIdentityPolicyRecognizesOnlyCanonicalAgentsAndCompatibilityKind() {
        for manifest in AgentRegistry.shared.all where manifest.isCanonicalTerminalType {
            XCTAssertTrue(AgentIdentityPolicy.isAgentKind(manifest.kind), manifest.kind)
        }
        XCTAssertTrue(AgentIdentityPolicy.isAgentKind(" opencode-run "))
        XCTAssertTrue(AgentIdentityPolicy.isAgentKind("CLAUDE-CODE"))
        XCTAssertFalse(AgentIdentityPolicy.isAgentKind("shell"))
        XCTAssertFalse(AgentIdentityPolicy.isAgentKind("unknown"))
        XCTAssertFalse(AgentIdentityPolicy.isAgentKind("custom"))
        XCTAssertFalse(AgentIdentityPolicy.isAgentKind("my-private-agent"))
        XCTAssertFalse(AgentIdentityPolicy.isAgentKind(nil))
    }

    func testOpencodeRunHasDeterministicFallbackDescriptorAndChipAssets() {
        let resolved = AgentIdentityPolicy.descriptor(
            surfaceID: agentAID,
            surfaceRef: "surface:3",
            surfaceOrdinal: 3,
            displayName: "  ",
            terminalKind: "opencode-run"
        )
        XCTAssertEqual(resolved?.identity.displayName, "OpenCode")
        XCTAssertEqual(resolved?.terminalKind, "opencode-run")
        XCTAssertEqual(
            AgentChipResolver.iconAssetName(forTerminalType: "opencode-run"),
            AgentChipResolver.iconAssetName(forTerminalType: "opencode")
        )
        XCTAssertEqual(
            AgentChipResolver.sfSymbolFallback(forTerminalType: "opencode-run"),
            AgentChipResolver.sfSymbolFallback(forTerminalType: "opencode")
        )
    }

    func testAgentChipPreservesIntentionalShellFallback() {
        let surfaceID = UUID()
        let chip = AgentChipResolver.resolve(
            focusedSurfaceId: surfaceID,
            metadata: [MetadataKey.terminalType: "shell"],
            sources: [MetadataKey.terminalType: .heuristic]
        )
        XCTAssertEqual(chip?.terminalType, "shell")
        XCTAssertEqual(chip?.iconAsset, "AgentIcons/shell")
        XCTAssertEqual(AgentChipResolver.sfSymbolFallback(forTerminalType: "shell"), "terminal.fill")
    }

    func testDuplicateNamesAndRenameNeverChangeUUIDIdentity() {
        let duplicateA = descriptor(agentAID, name: "Builder", ordinal: 3)
        let duplicateB = descriptor(agentBID, name: "Builder", ordinal: 5)
        let duplicatePresentation = BrowserCompanionPolicy.presentation(
            browserSurfaceID: browserID,
            link: linkA,
            context: AgentContextState(activeAgentSurfaceID: agentBID, generation: 1),
            liveAgents: [duplicateA, duplicateB],
            revealGrant: nil
        )
        XCTAssertEqual(duplicatePresentation, .veiled(linked: duplicateA, active: duplicateB))

        let renamedA = descriptor(agentAID, name: "Renamed Agent", ordinal: 3)
        let renamedPresentation = BrowserCompanionPolicy.presentation(
            browserSurfaceID: browserID,
            link: linkA,
            context: AgentContextState(activeAgentSurfaceID: agentAID, generation: 1),
            liveAgents: [renamedA, duplicateB],
            revealGrant: nil
        )
        XCTAssertEqual(renamedPresentation, .aligned(linked: renamedA))
        XCTAssertEqual(linkA.surfaceID, renamedA.identity.surfaceID)
        XCTAssertEqual(linkA.lastKnownName, "Maya", "presentation rename does not mutate durable link")
    }

    // MARK: - Live and orphan formatting

    func testLiveIdentityFormattingTracksExistingPreferenceWithoutStateMutation() {
        let identity = agentA.identity
        let linkBefore = linkA
        let grantBefore = CompanionRevealGrant(
            browserSurfaceID: browserID,
            linkedAgentSurfaceID: agentAID,
            activeAgentSurfaceID: agentBID,
            contextGeneration: 2
        )

        XCTAssertEqual(CompanionIdentityFormatting.live(identity, showSurfaceIDs: false), "Maya")
        XCTAssertEqual(CompanionIdentityFormatting.live(identity, showSurfaceIDs: true), "3: Maya")
        XCTAssertEqual(linkA, linkBefore)
        XCTAssertEqual(grantBefore.contextGeneration, 2)
    }

    func testOrphanFormattingExpandsCollidingPrefixesAndNeverUsesStaleRef() {
        let first = AgentSurfaceLink(
            surfaceID: UUID(uuidString: "7F2A8C00-0000-0000-0000-000000000000")!,
            lastKnownName: "Maya"
        )
        let second = AgentSurfaceLink(
            surfaceID: UUID(uuidString: "7F2A8C10-0000-0000-0000-000000000000")!,
            lastKnownName: "Maya"
        )
        let visible = [first, second]

        XCTAssertEqual(
            CompanionIdentityFormatting.orphan(first, visibleLinks: visible, showSurfaceIDs: false),
            "Maya"
        )
        let firstVisible = CompanionIdentityFormatting.orphan(
            first,
            visibleLinks: visible,
            showSurfaceIDs: true
        )
        let secondVisible = CompanionIdentityFormatting.orphan(
            second,
            visibleLinks: visible,
            showSurfaceIDs: true
        )
        XCTAssertEqual(firstVisible, "Maya · orphan 7F2A8C0")
        XCTAssertEqual(secondVisible, "Maya · orphan 7F2A8C1")
        XCTAssertFalse(firstVisible.contains("surface:"))
        XCTAssertFalse(firstVisible.contains("3:"))
    }

    func testRepeatedVisibleLinksToSameOrphanDoNotArtificiallyExpandPrefix() {
        let repeated = AgentSurfaceLink(
            surfaceID: UUID(uuidString: "12345678-0000-0000-0000-000000000000")!,
            lastKnownName: nil
        )
        XCTAssertEqual(
            CompanionIdentityFormatting.orphan(
                repeated,
                visibleLinks: [repeated, repeated],
                showSurfaceIDs: true
            ),
            "Unknown agent · orphan 123456"
        )
    }

    // MARK: - Frozen wire and error vocabulary

    func testWireSnapshotEncodesExactKeysAndExplicitNulls() throws {
        let snapshot = CompanionContextWireSnapshot(
            browserSurfaceID: browserID,
            browserSurfaceRef: "surface:7",
            browserName: "Checkout Prototype",
            linkedAgentSurfaceID: nil,
            linkedAgentSurfaceRef: nil,
            linkedAgentName: nil,
            linkState: .unlinked,
            presentationState: .unlinked,
            activeAgentSurfaceID: nil,
            activeAgentSurfaceRef: nil,
            activeAgentName: nil
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "kind", "browser_surface_id", "browser_surface_ref", "browser_name",
                "linked_agent_surface_id", "linked_agent_surface_ref", "linked_agent_name",
                "link_state", "presentation_state", "active_agent_surface_id",
                "active_agent_surface_ref", "active_agent_name",
            ]
        )
        XCTAssertEqual(object["kind"] as? String, "agent_companion")
        XCTAssertEqual(object["link_state"] as? String, "unlinked")
        XCTAssertEqual(object["presentation_state"] as? String, "unlinked")
        XCTAssertTrue(object["linked_agent_surface_id"] is NSNull)
        XCTAssertTrue(object["active_agent_surface_id"] is NSNull)
    }

    func testFrozenLinkResultErrorAndDiagnosticStrings() {
        XCTAssertEqual(BrowserCompanionLinkResult.noCaller.rawValue, "no_caller")
        XCTAssertEqual(BrowserCompanionLinkResult.callerNotFound.rawValue, "caller_not_found")
        XCTAssertEqual(BrowserCompanionLinkResult.callerWorkspaceMismatch.rawValue, "caller_workspace_mismatch")
        XCTAssertEqual(BrowserCompanionLinkResult.callerNotAgent.rawValue, "caller_not_agent")

        let errors: [BrowserCompanionLinkError] = [
            .browserNotFound, .targetNotBrowser, .agentNotFound, .targetNotTerminal,
            .linkWorkspaceMismatch, .agentNotRecognized, .noActiveAgent,
        ]
        XCTAssertEqual(
            Set(errors.map(\.rawValue)),
            [
                "browser_not_found", "target_not_browser", "agent_not_found",
                "target_not_terminal", "link_workspace_mismatch",
                "agent_not_recognized", "no_active_agent",
            ]
        )

        let diagnostics: [CompanionPlanDiagnosticCode] = [
            .orphanOmitted, .sourceNotBrowser, .targetMissing, .targetNotTerminal,
            .targetNotAgent, .applyFailed, .duplicateSurfaceID, .invalidAgentKind,
        ]
        XCTAssertEqual(
            Set(diagnostics.map(\.rawValue)),
            [
                "companion_link_orphan_omitted", "companion_link_source_not_browser",
                "companion_link_target_missing", "companion_link_target_not_terminal",
                "companion_link_target_not_agent", "companion_link_apply_failed",
                "blueprint_duplicate_surface_id", "blueprint_invalid_agent_kind",
            ]
        )
    }

    // MARK: - Default-off feature switch

    func testFeatureSwitchDefaultsOffAndEnvironmentWins() {
        let suiteName = "BrowserCompanionPolicyTests.feature.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AgentCompanionBrowserFeature.isEnabled(defaults: defaults, environment: [:]))
        defaults.set(true, forKey: AgentCompanionBrowserFeature.defaultsKey)
        XCTAssertTrue(AgentCompanionBrowserFeature.isEnabled(defaults: defaults, environment: [:]))
        XCTAssertFalse(
            AgentCompanionBrowserFeature.isEnabled(
                defaults: defaults,
                environment: [AgentCompanionBrowserFeature.environmentKey: " off "]
            )
        )
        defaults.set(false, forKey: AgentCompanionBrowserFeature.defaultsKey)
        XCTAssertTrue(
            AgentCompanionBrowserFeature.isEnabled(
                defaults: defaults,
                environment: [AgentCompanionBrowserFeature.environmentKey: "TRUE"]
            )
        )
        XCTAssertFalse(
            AgentCompanionBrowserFeature.isEnabled(
                defaults: defaults,
                environment: [AgentCompanionBrowserFeature.environmentKey: "unsupported"]
            )
        )
    }
}

/// C11-204: browser modals must never be presented app-modally, so the host
/// window selection has to be explicit about when there is nothing to sheet
/// onto and the decision must fall back to its safe default instead.
final class BrowserModalHostWindowSelectionTests: XCTestCase {
    private func candidate(
        preferred: Bool = false,
        key: Bool = false,
        main: Bool = false,
        visible: Bool = true,
        miniaturized: Bool = false,
        sheet: Bool = false,
        titled: Bool = true
    ) -> BrowserModalHostWindowCandidate {
        BrowserModalHostWindowCandidate(
            isPreferred: preferred,
            isKey: key,
            isMain: main,
            isVisible: visible,
            isMiniaturized: miniaturized,
            isSheet: sheet,
            hasTitleBar: titled
        )
    }

    func testNoCandidatesYieldsNoHostWindow() {
        XCTAssertNil(browserSelectModalHostWindowIndex([]))
    }

    func testAllWindowsHiddenYieldsNoHostWindow() {
        let candidates = [
            candidate(preferred: true, visible: false),
            candidate(key: true, visible: false),
            candidate(visible: false)
        ]
        XCTAssertNil(browserSelectModalHostWindowIndex(candidates))
    }

    func testMiniaturizedAndSheetWindowsAreNotEligible() {
        let candidates = [
            candidate(preferred: true, miniaturized: true),
            candidate(key: true, sheet: true)
        ]
        XCTAssertNil(browserSelectModalHostWindowIndex(candidates))
    }

    func testPreferredWindowWinsOverKeyAndMain() {
        let candidates = [
            candidate(key: true),
            candidate(main: true),
            candidate(preferred: true)
        ]
        XCTAssertEqual(browserSelectModalHostWindowIndex(candidates), 2)
    }

    func testFallsBackToKeyThenMainWhenPreferredIsUnusable() {
        let withKey = [
            candidate(preferred: true, visible: false),
            candidate(main: true),
            candidate(key: true)
        ]
        XCTAssertEqual(browserSelectModalHostWindowIndex(withKey), 2)

        let withoutKey = [
            candidate(preferred: true, miniaturized: true),
            candidate(),
            candidate(main: true)
        ]
        XCTAssertEqual(browserSelectModalHostWindowIndex(withoutKey), 2)
    }

    /// The app is backgrounded during agent-driven navigation, so neither key
    /// nor main window exists. Any ordinary visible window still beats no
    /// prompt at all, and a titled window beats an untitled overlay.
    func testBackgroundedAppStillFindsAnOrdinaryWindow() {
        let candidates = [
            candidate(titled: false),
            candidate(titled: true)
        ]
        XCTAssertEqual(browserSelectModalHostWindowIndex(candidates), 1)
    }

    func testUntitledWindowIsUsedAsALastResort() {
        let candidates = [candidate(titled: false)]
        XCTAssertEqual(browserSelectModalHostWindowIndex(candidates), 0)
    }

    /// Cancel, so an unpromptable insecure-HTTP navigation is denied rather
    /// than proceeding, and the host is never added to the allowlist.
    func testUnpromptedInsecureHTTPResponseIsADenialThatDoesNotAllowlist() {
        let response = BrowserInsecureHTTPPromptPolicy.unpromptedResponse
        XCTAssertNotEqual(response, .alertFirstButtonReturn)
        XCTAssertNotEqual(response, .alertSecondButtonReturn)
        XCTAssertFalse(
            browserShouldPersistInsecureHTTPAllowlistSelection(
                response: response,
                suppressionEnabled: true
            )
        )
    }
}
