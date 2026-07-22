import Foundation

// MARK: - Durable and transient companion state

/// Durable browser-to-agent association. The stable surface UUID is the
/// authority; the last known name exists only to explain an orphaned link.
struct AgentSurfaceLink: Codable, Equatable, Sendable {
    var surfaceID: UUID
    var lastKnownName: String?
}

/// A live surface identity. Refs and ordinals are live presentation hints and
/// must never be copied into durable companion state.
struct CompanionSurfaceIdentity: Equatable, Sendable {
    var surfaceID: UUID
    var surfaceRef: String?
    var surfaceOrdinal: Int?
    var displayName: String
}

struct AgentDescriptor: Equatable, Sendable {
    var identity: CompanionSurfaceIdentity
    var terminalKind: String
}

struct AgentContextState: Equatable, Sendable {
    var activeAgentSurfaceID: UUID?
    var generation: UInt64
}

/// A reveal is valid only for one exact browser/link/context generation.
struct CompanionRevealGrant: Equatable, Hashable, Sendable {
    var browserSurfaceID: UUID
    var linkedAgentSurfaceID: UUID
    var activeAgentSurfaceID: UUID?
    var contextGeneration: UInt64
}

enum BrowserCompanionPresentation: Equatable, Sendable {
    case unlinked
    case linkedNoContext(linked: AgentDescriptor)
    case aligned(linked: AgentDescriptor)
    case veiled(linked: AgentDescriptor, active: AgentDescriptor)
    case revealed(linked: AgentDescriptor, active: AgentDescriptor)
    case orphaned(link: AgentSurfaceLink)
    case orphanedRevealed(link: AgentSurfaceLink)

    var state: BrowserCompanionPresentationState {
        switch self {
        case .unlinked: return .unlinked
        case .linkedNoContext: return .linkedNoContext
        case .aligned: return .aligned
        case .veiled: return .veiled
        case .revealed: return .revealed
        case .orphaned: return .orphaned
        case .orphanedRevealed: return .orphanedRevealed
        }
    }

    var isWebContentInteractive: Bool {
        switch self {
        case .unlinked, .linkedNoContext, .aligned, .revealed, .orphanedRevealed:
            return true
        case .veiled, .orphaned:
            return false
        }
    }
}

/// The only reducer from independent durable/transient inputs to presentation.
/// It intentionally has no AppKit, SwiftUI, Workspace, or persistence dependency.
enum BrowserCompanionPolicy {
    static func presentation(
        browserSurfaceID: UUID,
        link: AgentSurfaceLink?,
        context: AgentContextState,
        liveAgents: [AgentDescriptor],
        revealGrant: CompanionRevealGrant?
    ) -> BrowserCompanionPresentation {
        guard let link else { return .unlinked }

        let linkedAgent = liveAgents.first { $0.identity.surfaceID == link.surfaceID }
        let grantIsValid = revealGrant.map {
            $0.browserSurfaceID == browserSurfaceID
                && $0.linkedAgentSurfaceID == link.surfaceID
                && $0.activeAgentSurfaceID == context.activeAgentSurfaceID
                && $0.contextGeneration == context.generation
        } ?? false

        guard let linkedAgent else {
            return grantIsValid ? .orphanedRevealed(link: link) : .orphaned(link: link)
        }

        guard let activeID = context.activeAgentSurfaceID,
              let activeAgent = liveAgents.first(where: { $0.identity.surfaceID == activeID })
        else {
            return .linkedNoContext(linked: linkedAgent)
        }

        if activeID == link.surfaceID {
            return .aligned(linked: linkedAgent)
        }

        return grantIsValid
            ? .revealed(linked: linkedAgent, active: activeAgent)
            : .veiled(linked: linkedAgent, active: activeAgent)
    }
}

// MARK: - Shared agent identity policy

/// One recognition and fallback policy shared by pane sizing, chips, companion
/// context, and link validation.
enum AgentIdentityPolicy {
    static let compatibilityAgentKind = "opencode-run"

    static let recognizedKinds: Set<String> = {
        var kinds: Set<String> = [compatibilityAgentKind]
        for manifest in AgentRegistry.shared.all where manifest.isCanonicalTerminalType {
            kinds.insert(manifest.kind)
        }
        return kinds
    }()

    static func normalizedKind(_ kind: String?) -> String? {
        guard let normalized = kind?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty
        else { return nil }
        return normalized
    }

    static func isAgentKind(_ kind: String?) -> Bool {
        guard let normalized = normalizedKind(kind) else { return false }
        return recognizedKinds.contains(normalized)
    }

    /// Manifest-backed visual fallback for canonical kinds. `opencode-run` is
    /// a detected compatibility kind rather than a launchable manifest, so it
    /// deliberately borrows the canonical OpenCode descriptor.
    static func fallbackManifest(for kind: String?) -> AgentManifest? {
        guard let normalized = normalizedKind(kind), isAgentKind(normalized) else { return nil }
        let manifestKind = normalized == compatibilityAgentKind ? "opencode" : normalized
        return AgentRegistry.shared.manifest(forKind: manifestKind)
    }

    static func fallbackDisplayName(for kind: String?) -> String? {
        fallbackManifest(for: kind)?.displayName
    }

    /// Resolve one live descriptor without ever treating shell, unknown, or a
    /// noncanonical custom terminal kind as an agent link target.
    static func descriptor(
        surfaceID: UUID,
        surfaceRef: String?,
        surfaceOrdinal: Int?,
        displayName: String?,
        terminalKind: String?
    ) -> AgentDescriptor? {
        guard let normalizedKind = normalizedKind(terminalKind), isAgentKind(normalizedKind) else {
            return nil
        }
        let explicitName = displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = explicitName.flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackDisplayName(for: normalizedKind)
            ?? normalizedKind
        return AgentDescriptor(
            identity: CompanionSurfaceIdentity(
                surfaceID: surfaceID,
                surfaceRef: surfaceRef,
                surfaceOrdinal: surfaceOrdinal,
                displayName: resolvedName
            ),
            terminalKind: normalizedKind
        )
    }
}

// MARK: - Preference-aware identity formatting

enum CompanionIdentityFormatting {
    static func live(
        _ identity: CompanionSurfaceIdentity,
        showSurfaceIDs: Bool
    ) -> String {
        TitleFormatting.ordinalPrefixed(
            ordinal: identity.surfaceOrdinal,
            title: identity.displayName,
            show: showSurfaceIDs
        )
    }

    static func orphan(
        _ link: AgentSurfaceLink,
        visibleLinks: [AgentSurfaceLink],
        showSurfaceIDs: Bool
    ) -> String {
        let trimmedName = link.lastKnownName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.flatMap { $0.isEmpty ? nil : $0 }
            ?? String(
                localized: "agentCompanion.identity.unknownAgent",
                defaultValue: "Unknown agent"
            )
        guard showSurfaceIDs else { return name }

        let prefix = TitleFormatting.collisionSafeUUIDPrefix(
            for: link.surfaceID,
            among: visibleLinks.map(\.surfaceID)
        )
        return "\(name) · orphan \(prefix)"
    }
}

// MARK: - Frozen vocabulary

enum AgentContextFocusProvenance: Equatable, Sendable {
    case operatorInteraction
    case explicitFocusCommand
    case restore
    case maintenance
}

enum BrowserCompanionLinkMode: String, Codable, Sendable {
    case automatic
    case workspace
}

enum BrowserCompanionLinkResult: String, Codable, Sendable {
    case automatic
    case workspace
    case noCaller = "no_caller"
    case callerNotFound = "caller_not_found"
    case callerWorkspaceMismatch = "caller_workspace_mismatch"
    case callerNotAgent = "caller_not_agent"
}

enum BrowserCompanionLinkError: String, Error, Codable, Equatable, Sendable {
    case browserNotFound = "browser_not_found"
    case targetNotBrowser = "target_not_browser"
    case agentNotFound = "agent_not_found"
    case targetNotTerminal = "target_not_terminal"
    case linkWorkspaceMismatch = "link_workspace_mismatch"
    case agentNotRecognized = "agent_not_recognized"
    case noActiveAgent = "no_active_agent"
}

enum CompanionPlanDiagnosticCode: String, Codable, Equatable, Sendable {
    case orphanOmitted = "companion_link_orphan_omitted"
    case sourceNotBrowser = "companion_link_source_not_browser"
    case targetMissing = "companion_link_target_missing"
    case targetNotTerminal = "companion_link_target_not_terminal"
    case targetNotAgent = "companion_link_target_not_agent"
    case applyFailed = "companion_link_apply_failed"
    case duplicateSurfaceID = "blueprint_duplicate_surface_id"
    case invalidAgentKind = "blueprint_invalid_agent_kind"
}

enum CompanionPlanDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case warning
    case error
}

struct CompanionPlanDiagnostic: Codable, Equatable, Sendable {
    var code: CompanionPlanDiagnosticCode
    var severity: CompanionPlanDiagnosticSeverity
    var sourcePlanID: String
    var targetPlanID: String?
}

enum BrowserCompanionLinkState: String, Codable, Equatable, Sendable {
    case unlinked
    case resolved
    case orphaned
}

enum BrowserCompanionPresentationState: String, Codable, Equatable, Sendable {
    case unlinked
    case linkedNoContext = "linked_no_context"
    case aligned
    case veiled
    case revealed
    case orphaned
    case orphanedRevealed = "orphaned_revealed"
}

/// Canonical machine-facing companion snapshot. Optional identity fields are
/// encoded as explicit JSON nulls so all query surfaces can expose one exact
/// field set independent of the visual surface-ID preference.
struct CompanionContextWireSnapshot: Codable, Equatable, Sendable {
    var kind: String
    var browserSurfaceID: UUID
    var browserSurfaceRef: String
    var browserName: String
    var linkedAgentSurfaceID: UUID?
    var linkedAgentSurfaceRef: String?
    var linkedAgentName: String?
    var linkState: BrowserCompanionLinkState
    var presentationState: BrowserCompanionPresentationState
    var activeAgentSurfaceID: UUID?
    var activeAgentSurfaceRef: String?
    var activeAgentName: String?

    init(
        kind: String = "agent_companion",
        browserSurfaceID: UUID,
        browserSurfaceRef: String,
        browserName: String,
        linkedAgentSurfaceID: UUID?,
        linkedAgentSurfaceRef: String?,
        linkedAgentName: String?,
        linkState: BrowserCompanionLinkState,
        presentationState: BrowserCompanionPresentationState,
        activeAgentSurfaceID: UUID?,
        activeAgentSurfaceRef: String?,
        activeAgentName: String?
    ) {
        self.kind = kind
        self.browserSurfaceID = browserSurfaceID
        self.browserSurfaceRef = browserSurfaceRef
        self.browserName = browserName
        self.linkedAgentSurfaceID = linkedAgentSurfaceID
        self.linkedAgentSurfaceRef = linkedAgentSurfaceRef
        self.linkedAgentName = linkedAgentName
        self.linkState = linkState
        self.presentationState = presentationState
        self.activeAgentSurfaceID = activeAgentSurfaceID
        self.activeAgentSurfaceRef = activeAgentSurfaceRef
        self.activeAgentName = activeAgentName
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case browserSurfaceID = "browser_surface_id"
        case browserSurfaceRef = "browser_surface_ref"
        case browserName = "browser_name"
        case linkedAgentSurfaceID = "linked_agent_surface_id"
        case linkedAgentSurfaceRef = "linked_agent_surface_ref"
        case linkedAgentName = "linked_agent_name"
        case linkState = "link_state"
        case presentationState = "presentation_state"
        case activeAgentSurfaceID = "active_agent_surface_id"
        case activeAgentSurfaceRef = "active_agent_surface_ref"
        case activeAgentName = "active_agent_name"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(browserSurfaceID, forKey: .browserSurfaceID)
        try container.encode(browserSurfaceRef, forKey: .browserSurfaceRef)
        try container.encode(browserName, forKey: .browserName)
        try container.encode(linkedAgentSurfaceID, forKey: .linkedAgentSurfaceID)
        try container.encode(linkedAgentSurfaceRef, forKey: .linkedAgentSurfaceRef)
        try container.encode(linkedAgentName, forKey: .linkedAgentName)
        try container.encode(linkState, forKey: .linkState)
        try container.encode(presentationState, forKey: .presentationState)
        try container.encode(activeAgentSurfaceID, forKey: .activeAgentSurfaceID)
        try container.encode(activeAgentSurfaceRef, forKey: .activeAgentSurfaceRef)
        try container.encode(activeAgentName, forKey: .activeAgentName)
    }
}

// MARK: - Portal contract

/// Closure-free portal value. AppKit and SwiftUI both consume this same
/// presentation instead of storing independent `isVeiled` flags.
struct BrowserPortalCompanionState: Equatable, Sendable {
    var presentation: BrowserCompanionPresentation

    var blocksWebContent: Bool { !presentation.isWebContentInteractive }

    var showsRevealedMismatch: Bool {
        switch presentation {
        case .revealed, .orphanedRevealed: return true
        default: return false
        }
    }
}

struct BrowserPortalCompanionConfiguration {
    var state: BrowserPortalCompanionState
    var onReveal: @MainActor @Sendable () -> Void
    var onHide: @MainActor @Sendable () -> Void

    init(
        state: BrowserPortalCompanionState,
        onReveal: @escaping @MainActor @Sendable () -> Void,
        onHide: @escaping @MainActor @Sendable () -> Void
    ) {
        self.state = state
        self.onReveal = onReveal
        self.onHide = onHide
    }
}

// MARK: - Feature gate

enum AgentCompanionBrowserFeature {
    static let defaultsKey = "c11.agentCompanionBrowser.enabled"
    static let environmentKey = "C11_AGENT_COMPANION_BROWSER_ENABLED"

    static var isEnabled: Bool {
        isEnabled(defaults: .standard, environment: ProcessInfo.processInfo.environment)
    }

    static func isEnabled(
        defaults: UserDefaults,
        environment: [String: String]
    ) -> Bool {
        if let raw = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            if ["1", "true", "on"].contains(raw) { return true }
            if ["0", "false", "off"].contains(raw) { return false }
        }
        return defaults.object(forKey: defaultsKey) as? Bool ?? false
    }
}

// MARK: - Default-off Workspace adapter

@MainActor
protocol AgentCompanionWorkspaceAccess: AnyObject {
    var liveAgentDescriptors: [AgentDescriptor] { get }
    func companionPresentation(for browserID: UUID) -> BrowserCompanionPresentation
    func linkBrowser(_ browserID: UUID, toAgent agentID: UUID) throws
    func unlinkBrowser(_ browserID: UUID) throws
    func revealBrowser(_ browserID: UUID) throws
    func hideBrowser(_ browserID: UUID)
    func automaticLinkBrowser(
        _ browserID: UUID,
        callerSurfaceID: UUID?,
        mode: BrowserCompanionLinkMode
    ) -> BrowserCompanionLinkResult
    func companionWireSnapshot(for browserID: UUID) -> CompanionContextWireSnapshot?
}

private enum DisabledAgentCompanionWorkspaceError: Error {
    case featureDisabled
}

extension Workspace: AgentCompanionWorkspaceAccess {
    var liveAgentDescriptors: [AgentDescriptor] { [] }

    func companionPresentation(for browserID: UUID) -> BrowserCompanionPresentation {
        .unlinked
    }

    func linkBrowser(_ browserID: UUID, toAgent agentID: UUID) throws {
        throw DisabledAgentCompanionWorkspaceError.featureDisabled
    }

    func unlinkBrowser(_ browserID: UUID) throws {
        throw DisabledAgentCompanionWorkspaceError.featureDisabled
    }

    func revealBrowser(_ browserID: UUID) throws {
        throw DisabledAgentCompanionWorkspaceError.featureDisabled
    }

    func hideBrowser(_ browserID: UUID) {}

    func automaticLinkBrowser(
        _ browserID: UUID,
        callerSurfaceID: UUID?,
        mode: BrowserCompanionLinkMode
    ) -> BrowserCompanionLinkResult {
        .workspace
    }

    func companionWireSnapshot(for browserID: UUID) -> CompanionContextWireSnapshot? {
        nil
    }
}

#if DEBUG
extension BrowserCompanionPresentation {
    var debugStateDescription: String {
        switch self {
        case .unlinked: return "unlinked"
        case .linkedNoContext(let linked):
            return "linked_no_context linked=\(linked.identity.surfaceID.uuidString)"
        case .aligned(let linked):
            return "aligned linked=\(linked.identity.surfaceID.uuidString)"
        case .veiled(let linked, let active):
            return "veiled linked=\(linked.identity.surfaceID.uuidString) active=\(active.identity.surfaceID.uuidString)"
        case .revealed(let linked, let active):
            return "revealed linked=\(linked.identity.surfaceID.uuidString) active=\(active.identity.surfaceID.uuidString)"
        case .orphaned(let link):
            return "orphaned linked=\(link.surfaceID.uuidString)"
        case .orphanedRevealed(let link):
            return "orphaned_revealed linked=\(link.surfaceID.uuidString)"
        }
    }
}
#endif
