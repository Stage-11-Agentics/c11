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

        private func splitCommaSeparated(_ value: String?) -> [String] {
            guard let value, !value.isEmpty else { return [] }
            return value
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
}
