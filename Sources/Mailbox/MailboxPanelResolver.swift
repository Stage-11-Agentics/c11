import Foundation

/// Name-to-surface resolution for the mailbox dispatcher.
///
/// The dispatcher uses this to answer "which live surfaces in this workspace
/// match `to`/`topic`?" at dispatch time. Reads from `SurfaceMetadataStore`
/// every call — no caching, no change-notification wiring. At Stage 2
/// volumes (tens of messages per minute), re-reading is cheaper than
/// observer plumbing (see plan §7).
///
/// Live-surface enumeration is injected via a closure so:
///   * The dispatcher can bind to `Workspace.orderedPanels` (main-thread) at
///     construction time.
///   * Tests can inject a fixed list without spinning up a Workspace.
struct MailboxPanelResolver {

    /// Reserved metadata prefix owned by C11-13 per CMUX-37 alignment doc §2.
    static let metadataPrefix = "mailbox."

    let workspaceId: UUID
    let metadataStore: PanelMetadataStore
    let livePanels: () -> [UUID]
    let canonicalOwner: (UUID) -> (panelID: UUID, workspaceID: UUID)?
    /// What the app knows about this workspace's panels beyond their metadata,
    /// read in one main-thread pass per dispatch.
    let panelFacts: () -> [UUID: PanelFacts]
    /// C11H-445: the kind detection sees in any panel on this Mac, for a
    /// shared OpenCode owner that may be in another workspace.
    let detectedKindAnywhere: (UUID) -> String?
    /// C11H-360: whether a panel on this Mac, in any workspace, answers to an
    /// address. Asked only when every match here is a linked panel.
    let localAnswersAnywhere: (MailboxAddress) -> Bool

    struct PanelFacts: Equatable {
        /// C11H-360: the linked machine the panel's terminal runs on; nil here.
        var linkedMachine: String?
        /// C11H-445: the kind detection sees in the panel's foreground
        /// (`shell` once its agent exits, a remote agent hc names); nil when
        /// detection has no word and the declared `terminal_type` stands.
        var detectedKind: String?
    }

    init(
        workspaceId: UUID,
        metadataStore: PanelMetadataStore = .shared,
        canonicalOwner: @escaping (UUID) -> (panelID: UUID, workspaceID: UUID)? = { _ in nil },
        linkedMachines: @escaping () -> [UUID: String] = { [:] },
        detectedKinds: @escaping () -> [UUID: String] = { [:] },
        detectedKindAnywhere: @escaping (UUID) -> String? = { _ in nil },
        localAnswersAnywhere: @escaping (MailboxAddress) -> Bool = { _ in false },
        livePanels: @escaping () -> [UUID]
    ) {
        self.init(workspaceId: workspaceId, metadataStore: metadataStore, canonicalOwner: canonicalOwner,
                  panelFacts: {
                      var facts: [UUID: PanelFacts] = [:]
                      for (panel, machine) in linkedMachines() { facts[panel, default: PanelFacts()].linkedMachine = machine }
                      for (panel, kind) in detectedKinds() { facts[panel, default: PanelFacts()].detectedKind = kind }
                      return facts
                  },
                  detectedKindAnywhere: detectedKindAnywhere,
                  localAnswersAnywhere: localAnswersAnywhere, livePanels: livePanels)
    }

    init(
        workspaceId: UUID,
        metadataStore: PanelMetadataStore = .shared,
        canonicalOwner: @escaping (UUID) -> (panelID: UUID, workspaceID: UUID)? = { _ in nil },
        panelFacts: @escaping () -> [UUID: PanelFacts],
        detectedKindAnywhere: @escaping (UUID) -> String? = { _ in nil },
        localAnswersAnywhere: @escaping (MailboxAddress) -> Bool = { _ in false },
        livePanels: @escaping () -> [UUID]
    ) {
        self.workspaceId = workspaceId
        self.metadataStore = metadataStore
        self.livePanels = livePanels
        self.canonicalOwner = canonicalOwner
        self.panelFacts = panelFacts
        self.detectedKindAnywhere = detectedKindAnywhere
        self.localAnswersAnywhere = localAnswersAnywhere
    }

    // MARK: - Name → surface

    /// Returns all live surfaces whose `title` metadata equals `name`. In
    /// practice 0 or 1; we tolerate duplicates by returning a list and leave
    /// duplicate-warning logging to the dispatcher (design doc §2).
    ///
    /// Test-only helper: recipient routing resolves through
    /// `MailboxMatcher.select` (see `MailboxDispatcher.resolveRecipients`),
    /// which honors address > role > title precedence. This title-only lookup
    /// has no production caller; it survives as a focused unit-test fixture.
    func surfaceIds(forName name: String) -> [UUID] {
        livePanels().filter { surfaceId in
            panelName(for: surfaceId) == name
        }
    }

    /// Returns the surface's current `title` metadata, if any. Used by CLI
    /// helpers that auto-fill the sender's `from` from its own surface.
    func panelName(for surfaceId: UUID) -> String? {
        let (metadata, _) = metadataStore.getMetadata(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        return metadata[MetadataKey.title] as? String
    }

    // MARK: - Mailbox metadata enumeration

    /// One tuple per live panel, including untitled panels so `id:<uuid>` can
    /// address them without introducing fake title matches:
    ///   * surface UUID
    ///   * the title (mailbox address)
    ///   * every `mailbox.*` key it carries, as strings (alignment doc §3:
    ///     v1 metadata values are strings; non-string entries are dropped).
    ///
    func panelsWithMailboxMetadata() -> [PanelMetadata] {
        let panels = livePanels()
        let facts = panelFacts()
        return panels.compactMap { panelId in
            let (metadata, sources) = metadataStore.getMetadata(
                workspaceId: workspaceId,
                surfaceId: panelId
            )
            let title = metadata[MetadataKey.title] as? String ?? ""
            var mailboxKeys: [String: String] = [:]
            for (key, value) in metadata where key.hasPrefix(Self.metadataPrefix) {
                if let stringValue = value as? String {
                    mailboxKeys[key] = stringValue
                }
            }
            var record = PanelMetadata(
                surfaceId: panelId,
                name: title,
                mailboxKeys: mailboxKeys
            )
            record.linkedMachine = facts[panelId]?.linkedMachine
            record.titleFromOSC = Self.isOSCSource(sources[MetadataKey.title])
            // C11H-445: the live agent kind, as the sidebar and the doorbell read it.
            record.agentKind = PanelActivityTerminalKindResolver.resolve(
                detectedTerminalType: facts[panelId]?.detectedKind,
                declaredTerminalType: metadata[MetadataKey.terminalType] as? String
            )
            return record
        }
    }

    /// Whether a metadata source record says `osc`.
    static func isOSCSource(_ source: Any?) -> Bool {
        if let text = source as? String { return text == MetadataSource.osc.rawValue }
        if let record = source as? [String: Any], let text = record["source"] as? String {
            return text == MetadataSource.osc.rawValue
        }
        return false
    }

    /// C11H-445: the same recipient with its mailbox keys and live kind read
    /// again now. The dispatcher asks this after the inbox copy is published,
    /// for a recipient whose kind gave it no delivery, so mail never falls
    /// between that resolution and the panel's inbox rescan.
    func refreshed(_ recipient: PanelMetadata) -> PanelMetadata {
        let home = recipient.inboxWorkspaceId ?? workspaceId
        let (metadata, _) = metadataStore.getMetadata(workspaceId: home, surfaceId: recipient.surfaceId)
        let keys = metadata.reduce(into: [String: String]()) { result, entry in
            if entry.key.hasPrefix(Self.metadataPrefix), let value = entry.value as? String {
                result[entry.key] = value
            }
        }
        var result = PanelMetadata(surfaceId: recipient.surfaceId, name: recipient.name, mailboxKeys: keys)
        result.inboxWorkspaceId = recipient.inboxWorkspaceId
        result.linkedMachine = recipient.linkedMachine
        result.titleFromOSC = recipient.titleFromOSC
        let detected = recipient.inboxWorkspaceId == nil
            ? panelFacts()[recipient.surfaceId]?.detectedKind
            : detectedKindAnywhere(recipient.surfaceId)
        result.agentKind = PanelActivityTerminalKindResolver.resolve(
            detectedTerminalType: detected,
            declaredTerminalType: metadata[MetadataKey.terminalType] as? String
        )
        return result
    }

    func canonicalRecipient(_ requested: PanelMetadata) -> PanelMetadata {
        guard let owner = canonicalOwner(requested.surfaceId), owner.panelID != requested.surfaceId else {
            return requested
        }
        let (metadata, _) = metadataStore.getMetadata(workspaceId: owner.workspaceID, surfaceId: owner.panelID)
        let keys = metadata.reduce(into: [String: String]()) { result, entry in
            if entry.key.hasPrefix(Self.metadataPrefix), let value = entry.value as? String {
                result[entry.key] = value
            }
        }
        var result = PanelMetadata(surfaceId: owner.panelID, name: metadata[MetadataKey.title] as? String ?? "",
                                   mailboxKeys: keys)
        result.inboxWorkspaceId = owner.workspaceID
        // C11H-445: the owner's live kind, by the same rule as every reader,
        // never the alias's kind.
        result.agentKind = PanelActivityTerminalKindResolver.resolve(
            detectedTerminalType: detectedKindAnywhere(owner.panelID),
            declaredTerminalType: metadata[MetadataKey.terminalType] as? String
        )
        return result
    }

    /// Shared inboxes widen ordinary recv, so only a matching tool session
    /// follows them. Child tools and pending/unbound routes keep the caller's
    /// own panel identity and inbox, exactly as before shared routing existed.
    static func recipientPayload(
        panelID: UUID,
        surfaces: [MailboxGlobalResolver.PanelRecord],
        sharedOwner: (panelID: UUID, sessionID: String, members: [UUID])?,
        expectedSession: String?,
        unavailableReason: (UUID) -> String?
    ) -> [String: Any] {
        let shared = expectedSession == nil || expectedSession == sharedOwner?.sessionID ? sharedOwner : nil
        let ownerID = shared?.panelID ?? panelID
        guard let owner = surfaces.first(where: { $0.surfaceId == ownerID }) else { return [:] }
        let unavailable = unavailableReason(ownerID)
        var result: [String: Any] = [
            "requested_panel_id": panelID.uuidString,
            "panel_id": ownerID.uuidString,
            "workspace_id": owner.workspaceId.uuidString,
            "name": owner.name.isEmpty ? "id:\(ownerID.uuidString)" : owner.name,
            "can_ring": unavailable == nil
        ]
        if let unavailable { result["doorbell_unavailable_reason"] = unavailable }
        if let shared {
            result["session_id"] = shared.sessionID
            result["shared_inboxes"] = surfaces.filter { shared.members.contains($0.surfaceId) }.map {
                ["panel_id": $0.surfaceId.uuidString, "workspace_id": $0.workspaceId.uuidString, "name": $0.name]
            }
        }
        return result
    }

    struct PanelMetadata: Equatable {
        let surfaceId: UUID
        let name: String
        /// Parsed from mailbox.* metadata keys. Comma-split helpers live on
        /// the type so callers don't re-implement the alignment-doc contract.
        let mailboxKeys: [String: String]
        var inboxWorkspaceId: UUID? = nil
        /// C11H-360: the linked machine this panel's terminal runs on, nil here.
        var linkedMachine: String? = nil
        /// C11H-360: the title came from the terminal's own OSC 0/2 output.
        var titleFromOSC = false
        /// C11H-445: the panel's live agent kind (detected over declared).
        var agentKind: String? = nil

        /// The handlers the dispatcher runs: the panel's own value, or the
        /// default for an agent kind with a doorbell (`MailboxDeliveryPolicy`).
        var delivery: [String] {
            deliveryEffective.handlers
        }

        var deliveryEffective: MailboxDeliveryPolicy.Effective {
            MailboxDeliveryPolicy.effective(
                delivery: mailboxKeys[MailboxDeliveryPolicy.deliveryKey],
                doorbell: mailboxKeys[MailboxDeliveryPolicy.doorbellKey],
                agentKind: agentKind
            )
        }

        var subscribe: [String] {
            splitCommaSeparated(mailboxKeys["mailbox.subscribe"])
        }

        var retentionDays: Int? {
            mailboxKeys["mailbox.retention_days"].flatMap { Int($0) }
        }

        /// Stable event/log label for panels without an operator title.
        var displayName: String {
            name.isEmpty ? "id:\(surfaceId.uuidString)" : name
        }

        /// `mailbox.address` — the stable, rename-proof handle. Empty → nil.
        var address: String? {
            MailboxIdentity.nonEmpty(mailboxKeys["mailbox.address"])
        }

        /// `mailbox.role` — opt-in role handle. Empty → nil. Deliberately does
        /// not fall back to the canonical `role` key: role addressing is
        /// opt-in via `mailbox.role` so bare-name resolution stays identical
        /// for the many surfaces that set `title` + canonical `role` but no
        /// `mailbox.*` identity.
        var role: String? {
            MailboxIdentity.nonEmpty(mailboxKeys["mailbox.role"])
        }

        /// The address-precedence view (`title`/`address`/`role`) used by
        /// `MailboxMatcher`.
        var identity: MailboxIdentity {
            MailboxIdentity.panel(title: name, address: address, role: role, panelId: surfaceId,
                                  linkedMachine: linkedMachine, titleFromOSC: titleFromOSC)
        }

        private func splitCommaSeparated(_ value: String?) -> [String] {
            guard let value, !value.isEmpty else { return [] }
            return value
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
}

/// C11H-445: a panel's mail delivery, decided in one place for every reader:
/// the dispatcher's handlers, the doorbell, `can_ring`, `mailbox status`,
/// `get-metadata` and `fleet`. Nothing is written back. A panel's own
/// `mailbox.delivery` wins verbatim (`off` or `none` runs no handler). Without
/// one, a panel whose live agent kind has a typed composer reader or a native
/// route takes `stdin`, unless it set `mailbox.doorbell=off`. The default only
/// makes a panel eligible: every ring check still applies (the wrapper's
/// interactive PID and the kernel's foreground check, native ancestry, the
/// composer, holds, flags, the cap), so a plain shell or a one-shot command is
/// never rung.
enum MailboxDeliveryPolicy {
    static let deliveryKey = "mailbox.delivery"
    static let doorbellKey = "mailbox.doorbell"
    static let offWords: Set<String> = ["off", "none"]

    enum Source: String {
        /// The panel set `mailbox.delivery`.
        case explicit
        /// No value set; the panel's agent kind has a doorbell.
        case `default`
        /// No value set, and the panel set `mailbox.doorbell=off`.
        case doorbellOff = "doorbell_off"
        /// No value set, and no agent with a doorbell is in the panel.
        case none
    }

    struct Effective: Equatable {
        let handlers: [String]
        let source: Source

        var includesStdin: Bool {
            handlers.contains { $0.caseInsensitiveCompare("stdin") == .orderedSame }
        }

        /// The value a reader prints: the handlers, or `off` when none run.
        var value: String {
            handlers.isEmpty ? "off" : handlers.joined(separator: ",")
        }

        var jsonObject: [String: Any] {
            ["value": value, "source": source.rawValue]
        }
    }

    /// Claude Code, Codex, Grok, OpenCode, Pi (typed readers) and omp (native
    /// only). Copilot, unknown programs and shells have neither.
    static func hasReaderOrNativeRoute(_ kind: String?) -> Bool {
        guard let kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !kind.isEmpty else { return false }
        return PromptInputClassifier.supportsComposer(harness: kind)
            || MailboxNativeDoorbell.Route.forKind(kind) != nil
    }

    static func effective(delivery: String?, doorbell: String?, agentKind: String?) -> Effective {
        if let raw = delivery?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let handlers = raw.split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !offWords.contains($0.lowercased()) }
            return Effective(handlers: handlers, source: .explicit)
        }
        if doorbell?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "off" {
            return Effective(handlers: [], source: .doorbellOff)
        }
        return hasReaderOrNativeRoute(agentKind)
            ? Effective(handlers: ["stdin"], source: .default)
            : Effective(handlers: [], source: .none)
    }

    /// The same decision from a panel's metadata dictionary.
    static func effective(metadata: [String: Any], agentKind: String?) -> Effective {
        effective(delivery: metadata[deliveryKey] as? String,
                  doorbell: metadata[doorbellKey] as? String,
                  agentKind: agentKind)
    }
}

/// Cross-workspace recipient resolution for `c11 mailbox send`.
///
/// Each workspace runs its own `MailboxDispatcher`, and that dispatcher only
/// resolves names against surfaces in *its* workspace. So a `--to` naming a
/// surface in another workspace resolves to an empty recipient set and the
/// message is dropped. This resolver closes that gap: it answers "which
/// workspace should this envelope be delivered into?" by scanning every live,
/// addressable surface in the running c11 instance, so the CLI can route the
/// envelope into the recipient's workspace outbox (where that workspace's own
/// dispatcher then delivers it locally, unchanged).
///
/// Precedence is deterministic (documented in `docs/c11-mailbox-guide.md`):
///   1. **Local-first.** If `name` matches one or more surfaces in the
///      sender's own workspace, deliver there. This preserves the
///      pre-cross-workspace behavior exactly — a same-workspace send never
///      reaches into another workspace, even if a same-named surface exists
///      elsewhere.
///   2. Otherwise, among the other workspaces:
///        * exactly one workspace matches  → deliver there;
///        * more than one workspace matches → `.ambiguous` (the caller must
///          disambiguate with a workspace qualifier);
///        * none match → `.unresolved` (the caller surfaces a non-zero error).
///   A `workspaceQualifier` short-circuits the precedence: only surfaces in
///   that workspace are considered, and the result is `.unique` or
///   `.unresolved`.
///
/// Multiple same-named surfaces inside the chosen workspace are returned
/// together; the dispatcher fans out to all of them, matching how
/// same-workspace duplicate names already behave.
struct MailboxGlobalResolver {

    /// One live, addressable surface anywhere in the instance. `name` is the
    /// `title` (the display name and inbox key); `address`/`role` are the
    /// optional stable identities a surface declares via `mailbox.address` /
    /// `mailbox.role`. Defaulted to nil so existing call sites that only know
    /// the title keep compiling.
    struct PanelRecord: Equatable {
        let workspaceId: UUID
        let surfaceId: UUID
        let name: String
        let address: String?
        let role: String?
        /// C11H-360: the linked machine this panel's terminal runs on, nil here.
        let linkedMachine: String?
        /// C11H-360: the title came from the terminal's own OSC 0/2 output.
        let titleFromOSC: Bool

        init(
            workspaceId: UUID,
            surfaceId: UUID,
            name: String,
            address: String? = nil,
            role: String? = nil,
            linkedMachine: String? = nil,
            titleFromOSC: Bool = false
        ) {
            self.workspaceId = workspaceId
            self.surfaceId = surfaceId
            self.name = name
            self.address = MailboxIdentity.nonEmpty(address)
            self.role = MailboxIdentity.nonEmpty(role)
            self.linkedMachine = linkedMachine
            self.titleFromOSC = titleFromOSC
        }

        var identity: MailboxIdentity {
            MailboxIdentity.panel(title: name, address: address, role: role, panelId: surfaceId,
                                  linkedMachine: linkedMachine, titleFromOSC: titleFromOSC)
        }
    }

    enum Resolution: Equatable {
        /// Deliver into `workspaceId`; `surfaceIds` are the matching surfaces.
        case unique(workspaceId: UUID, surfaceIds: [UUID])
        /// `name` matches surfaces in more than one workspace and no qualifier
        /// was supplied. Carries the candidates for a helpful error message.
        case ambiguous(candidates: [PanelRecord])
        /// No live surface carries `name` (within the qualifier, if given).
        case unresolved
    }

    /// Enumerates all addressable surfaces. Injected so the resolver is pure:
    /// tests pass a fixed list, the socket handler binds it to the live
    /// windows' workspaces.
    let surfaces: () -> [PanelRecord]

    /// `name` is the raw `to` string. It may be a bare name (precedence
    /// address > role > title) or a qualifier form (`panel:<addr>` /
    /// `role:<name>`) — see `MailboxAddress`. Workspace scoping is orthogonal:
    /// the address selects *which surfaces*, the qualifier/local-first logic
    /// selects *which workspace*.
    func resolve(
        name: String,
        senderWorkspaceId: UUID,
        workspaceQualifier: UUID? = nil
    ) -> Resolution {
        let matches = MailboxMatcher.select(
            MailboxAddress.parse(name),
            from: surfaces(),
            identity: { $0.identity }
        )

        if let qualifier = workspaceQualifier {
            let scoped = matches.filter { $0.workspaceId == qualifier }
            guard !scoped.isEmpty else { return .unresolved }
            return .unique(workspaceId: qualifier, surfaceIds: scoped.map(\.surfaceId))
        }

        // Local-first: a match in the sender's own workspace always wins.
        let local = matches.filter { $0.workspaceId == senderWorkspaceId }
        if !local.isEmpty {
            return .unique(workspaceId: senderWorkspaceId, surfaceIds: local.map(\.surfaceId))
        }

        guard !matches.isEmpty else { return .unresolved }
        let workspaceIds = Set(matches.map(\.workspaceId))
        if workspaceIds.count == 1, let only = workspaceIds.first {
            return .unique(workspaceId: only, surfaceIds: matches.map(\.surfaceId))
        }
        return .ambiguous(candidates: matches)
    }
}
