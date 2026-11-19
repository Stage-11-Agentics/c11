import Foundation

/// A parsed mailbox recipient address.
///
/// The mailbox `to` field is an opaque string (envelope schema v1), so stable
/// addressing rides entirely in how that string is *interpreted* — no schema
/// change. A `to` value is one of three forms:
///
///   * `panel:<addr>` — match **only** panels whose `mailbox.address` equals
///     `<addr>`. The stable, rename-proof handle an agent declares once.
///     `tab:<addr>` and `surface:<addr>` are the same form (persisted envelopes
///     hold them).
///   * `role:<name>` — match **only** surfaces whose `mailbox.role` equals
///     `<name>`. Opt-in role addressing.
///   * `id:<uuid>` — match **only** the panel UUID, independent of title or
///     workspace. Used when sending to a known lineage parent.
///   * bare `<x>` — precedence resolution: `mailbox.address`, then `mailbox.role`,
///     then `title`. Title is the fallback, so a send by display name keeps
///     working unchanged for surfaces that declare no stable identity.
///
/// Both the cross-workspace resolver (`MailboxGlobalResolver`) and the
/// per-workspace dispatcher (`MailboxSurfaceResolver` / `MailboxDispatcher`) run
/// the same `MailboxMatcher.select` over this type, so global routing and local
/// delivery always agree on who a `to` resolves to.
enum MailboxAddress: Equatable {
    /// `panel:<address>` (or the legacy `tab:` / `surface:`) — match
    /// `mailbox.address` exactly.
    case surface(String)
    /// `id:<uuid>` — exact panel UUID match.
    case id(UUID?)
    /// `role:<name>` — match `mailbox.role` exactly.
    case role(String)
    /// Bare name — precedence: address, then role, then title.
    case name(String)

    static let panelPrefix = "panel:"
    // C11-337: legacy spellings, accepted forever.
    static let surfacePrefix = "surface:"
    static let tabPrefix = "tab:"
    static let rolePrefix = "role:"
    static let idPrefix = "id:"

    /// Parse a raw `to` string. An empty value after a recognized prefix (e.g.
    /// `panel:`) yields that scheme with an empty payload — which matches
    /// nothing, the honest answer, rather than silently degrading to a bare name.
    static func parse(_ raw: String) -> MailboxAddress {
        if raw.hasPrefix(panelPrefix) {
            return .surface(String(raw.dropFirst(panelPrefix.count)))
        }
        if raw.hasPrefix(tabPrefix) {
            return .surface(String(raw.dropFirst(tabPrefix.count)))
        }
        if raw.hasPrefix(surfacePrefix) {
            return .surface(String(raw.dropFirst(surfacePrefix.count)))
        }
        if raw.hasPrefix(rolePrefix) {
            return .role(String(raw.dropFirst(rolePrefix.count)))
        }
        if raw.hasPrefix(idPrefix) {
            return .id(UUID(uuidString: String(raw.dropFirst(idPrefix.count))))
        }
        return .name(raw)
    }

    /// The canonical `to` string for this address: `panel:<addr>`,
    /// `role:<name>`, or the bare name.
    var canonical: String {
        switch self {
        case .surface(let address): return Self.panelPrefix + address
        case .id(let uuid): return Self.idPrefix + (uuid?.uuidString.lowercased() ?? "")
        case .role(let name): return Self.rolePrefix + name
        case .name(let name): return name
        }
    }
}

/// The keys a surface can be addressed by, in precedence order. Built from a
/// surface's metadata at resolution time by whichever resolver is matching.
struct MailboxIdentity: Equatable {
    /// The `title` metadata — the display name and the inbox directory key.
    let title: String?
    /// `mailbox.address` — the stable, rename-proof handle.
    let address: String?
    /// `mailbox.role` — the opt-in role handle.
    let role: String?
    /// Exact panel identity; independent of user metadata.
    let panelId: UUID?
    /// C11H-360: the panel's terminal runs on a linked machine. A name a panel
    /// on this Mac answers to is never answered by a linked panel.
    let isLinked: Bool

    init(title: String?, address: String?, role: String?, panelId: UUID? = nil, isLinked: Bool = false) {
        self.title = MailboxIdentity.nonEmpty(title)
        self.address = MailboxIdentity.nonEmpty(address)
        self.role = MailboxIdentity.nonEmpty(role)
        self.panelId = panelId
        self.isLinked = isLinked
    }

    /// A panel's identity as both resolvers build it. A linked panel's title
    /// that its terminal set itself (an OSC 0/2 title, source `osc`) is not a
    /// mail name: output on the other machine never chooses whose mail it gets.
    static func panel(title: String?, address: String?, role: String?, panelId: UUID?,
                      linkedMachine: String?, titleFromOSC: Bool) -> MailboxIdentity {
        let linked = linkedMachine != nil
        return MailboxIdentity(title: linked && titleFromOSC ? nil : title, address: address, role: role,
                               panelId: panelId, isLinked: linked)
    }

    /// Treats empty strings as absent so a blank metadata value never matches a
    /// blank `to` payload.
    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// Selects the subset of candidate surfaces that a parsed address resolves to,
/// applying the address > role > title precedence for bare names. Pure and
/// generic over the candidate type so both resolvers share one implementation.
///
/// C11H-360: every name form (bare, `panel:`, `role:`) matches panels on this
/// Mac first; linked-machine panels answer only when no panel here does.
/// `id:<uuid>` stays exact.
enum MailboxMatcher {

    static func select<Item>(
        _ address: MailboxAddress,
        from items: [Item],
        identity: (Item) -> MailboxIdentity
    ) -> [Item] {
        if case .id(let target) = address {
            guard let target else { return [] }
            return items.filter { identity($0).panelId == target }
        }
        let local = selectByName(address, from: items.filter { !identity($0).isLinked }, identity: identity)
        if !local.isEmpty { return local }
        return selectByName(address, from: items.filter { identity($0).isLinked }, identity: identity)
    }

    /// Whether a panel on this Mac answers to `address` (any name form).
    static func localAnswers<Item>(
        _ address: MailboxAddress,
        from items: [Item],
        identity: (Item) -> MailboxIdentity
    ) -> Bool {
        if case .id = address { return false }
        return !selectByName(address, from: items.filter { !identity($0).isLinked }, identity: identity).isEmpty
    }

    private static func selectByName<Item>(
        _ address: MailboxAddress,
        from items: [Item],
        identity: (Item) -> MailboxIdentity
    ) -> [Item] {
        switch address {
        case .id:
            return []
        case .surface(let target):
            guard let target = MailboxIdentity.nonEmpty(target) else { return [] }
            return items.filter { identity($0).address == target }
        case .role(let target):
            guard let target = MailboxIdentity.nonEmpty(target) else { return [] }
            return items.filter { identity($0).role == target }
        case .name(let target):
            guard let target = MailboxIdentity.nonEmpty(target) else { return [] }
            let byAddress = items.filter { identity($0).address == target }
            if !byAddress.isEmpty { return byAddress }
            let byRole = items.filter { identity($0).role == target }
            if !byRole.isEmpty { return byRole }
            return items.filter { identity($0).title == target }
        }
    }
}
