import Foundation

/// A parsed mailbox recipient address.
///
/// The mailbox `to` field is an opaque string (envelope schema v1), so stable
/// addressing rides entirely in how that string is *interpreted* — no schema
/// change. A `to` value is one of three forms:
///
///   * `surface:<addr>` — match **only** surfaces whose `mailbox.address` equals
///     `<addr>`. The stable, rename-proof handle an agent declares once.
///   * `role:<name>` — match **only** surfaces whose `mailbox.role` equals
///     `<name>`. Opt-in role addressing.
///   * bare `<x>` — precedence resolution: `mailbox.address`, then `mailbox.role`,
///     then `title`. Title is the fallback, so a send by display name keeps
///     working unchanged for surfaces that declare no stable identity.
///
/// Both the cross-workspace resolver (`MailboxGlobalResolver`) and the
/// per-workspace dispatcher (`MailboxSurfaceResolver` / `MailboxDispatcher`) run
/// the same `MailboxMatcher.select` over this type, so global routing and local
/// delivery always agree on who a `to` resolves to.
enum MailboxAddress: Equatable {
    /// `surface:<address>` — match `mailbox.address` exactly.
    case surface(String)
    /// `role:<name>` — match `mailbox.role` exactly.
    case role(String)
    /// Bare name — precedence: address, then role, then title.
    case name(String)

    static let surfacePrefix = "surface:"
    static let rolePrefix = "role:"

    /// Parse a raw `to` string. An empty value after a recognized prefix (e.g.
    /// `surface:`) yields that scheme with an empty payload — which matches
    /// nothing, the honest answer, rather than silently degrading to a bare name.
    static func parse(_ raw: String) -> MailboxAddress {
        if raw.hasPrefix(surfacePrefix) {
            return .surface(String(raw.dropFirst(surfacePrefix.count)))
        }
        if raw.hasPrefix(rolePrefix) {
            return .role(String(raw.dropFirst(rolePrefix.count)))
        }
        return .name(raw)
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

    init(title: String?, address: String?, role: String?) {
        self.title = MailboxIdentity.nonEmpty(title)
        self.address = MailboxIdentity.nonEmpty(address)
        self.role = MailboxIdentity.nonEmpty(role)
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
enum MailboxMatcher {

    static func select<Item>(
        _ address: MailboxAddress,
        from items: [Item],
        identity: (Item) -> MailboxIdentity
    ) -> [Item] {
        switch address {
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
