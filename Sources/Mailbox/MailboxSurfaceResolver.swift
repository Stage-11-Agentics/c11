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
struct MailboxSurfaceResolver {

    /// Reserved metadata prefix owned by C11-13 per CMUX-37 alignment doc §2.
    static let metadataPrefix = "mailbox."

    let workspaceId: UUID
    let metadataStore: SurfaceMetadataStore
    let liveSurfaces: () -> [UUID]

    init(
        workspaceId: UUID,
        metadataStore: SurfaceMetadataStore = .shared,
        liveSurfaces: @escaping () -> [UUID]
    ) {
        self.workspaceId = workspaceId
        self.metadataStore = metadataStore
        self.liveSurfaces = liveSurfaces
    }

    // MARK: - Name → surface

    /// Returns all live surfaces whose `title` metadata equals `name`. In
    /// practice 0 or 1; we tolerate duplicates by returning a list and leave
    /// duplicate-warning logging to the dispatcher (design doc §2).
    func surfaceIds(forName name: String) -> [UUID] {
        liveSurfaces().filter { surfaceId in
            surfaceName(for: surfaceId) == name
        }
    }

    /// Returns the surface's current `title` metadata, if any. Used by CLI
    /// helpers that auto-fill the sender's `from` from its own surface.
    func surfaceName(for surfaceId: UUID) -> String? {
        let (metadata, _) = metadataStore.getMetadata(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        return metadata[MetadataKey.title] as? String
    }

    // MARK: - Mailbox metadata enumeration

    /// One tuple per live surface that has a `title`:
    ///   * surface UUID
    ///   * the title (mailbox address)
    ///   * every `mailbox.*` key it carries, as strings (alignment doc §3:
    ///     v1 metadata values are strings; non-string entries are dropped).
    ///
    /// Surfaces without a title can't be addressed and are filtered out.
    func surfacesWithMailboxMetadata() -> [SurfaceMetadata] {
        liveSurfaces().compactMap { surfaceId in
            let (metadata, _) = metadataStore.getMetadata(
                workspaceId: workspaceId,
                surfaceId: surfaceId
            )
            guard let title = metadata[MetadataKey.title] as? String else {
                return nil
            }
            var mailboxKeys: [String: String] = [:]
            for (key, value) in metadata where key.hasPrefix(Self.metadataPrefix) {
                if let stringValue = value as? String {
                    mailboxKeys[key] = stringValue
                }
            }
            return SurfaceMetadata(
                surfaceId: surfaceId,
                name: title,
                mailboxKeys: mailboxKeys
            )
        }
    }

    struct SurfaceMetadata: Equatable {
        let surfaceId: UUID
        let name: String
        /// Parsed from mailbox.* metadata keys. Comma-split helpers live on
        /// the type so callers don't re-implement the alignment-doc contract.
        let mailboxKeys: [String: String]

        var delivery: [String] {
            splitCommaSeparated(mailboxKeys["mailbox.delivery"])
        }

        var subscribe: [String] {
            splitCommaSeparated(mailboxKeys["mailbox.subscribe"])
        }

        var retentionDays: Int? {
            mailboxKeys["mailbox.retention_days"].flatMap { Int($0) }
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
            MailboxIdentity(title: name, address: address, role: role)
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
    struct Surface: Equatable {
        let workspaceId: UUID
        let surfaceId: UUID
        let name: String
        let address: String?
        let role: String?

        init(
            workspaceId: UUID,
            surfaceId: UUID,
            name: String,
            address: String? = nil,
            role: String? = nil
        ) {
            self.workspaceId = workspaceId
            self.surfaceId = surfaceId
            self.name = name
            self.address = MailboxIdentity.nonEmpty(address)
            self.role = MailboxIdentity.nonEmpty(role)
        }

        var identity: MailboxIdentity {
            MailboxIdentity(title: name, address: address, role: role)
        }
    }

    enum Resolution: Equatable {
        /// Deliver into `workspaceId`; `surfaceIds` are the matching surfaces.
        case unique(workspaceId: UUID, surfaceIds: [UUID])
        /// `name` matches surfaces in more than one workspace and no qualifier
        /// was supplied. Carries the candidates for a helpful error message.
        case ambiguous(candidates: [Surface])
        /// No live surface carries `name` (within the qualifier, if given).
        case unresolved
    }

    /// Enumerates all addressable surfaces. Injected so the resolver is pure:
    /// tests pass a fixed list, the socket handler binds it to the live
    /// windows' workspaces.
    let surfaces: () -> [Surface]

    /// `name` is the raw `to` string. It may be a bare name (precedence
    /// address > role > title) or a qualifier form (`surface:<addr>` /
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
