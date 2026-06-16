import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class MailboxSurfaceResolverTests: XCTestCase {

    private var workspaceId: UUID!
    private var store: SurfaceMetadataStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Fresh workspace UUID per test keeps us isolated from the shared
        // SurfaceMetadataStore singleton — no other tests use our UUIDs.
        workspaceId = UUID()
        store = SurfaceMetadataStore.shared
    }

    // MARK: - Helpers

    private func seedSurface(name: String?, extraMailbox: [String: String] = [:]) -> UUID {
        let surfaceId = UUID()
        var partial: [String: Any] = [:]
        if let name { partial[MetadataKey.title] = name }
        for (key, value) in extraMailbox {
            partial[key] = value
        }
        _ = try? store.setMetadata(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            partial: partial,
            mode: .merge,
            source: .explicit
        )
        return surfaceId
    }

    private func makeResolver(candidates: [UUID]) -> MailboxSurfaceResolver {
        MailboxSurfaceResolver(
            workspaceId: workspaceId,
            metadataStore: store,
            liveSurfaces: { candidates }
        )
    }

    // MARK: - Name → surface

    func testSurfaceIdsByNameMatchesExactTitle() {
        let builder = seedSurface(name: "builder")
        let watcher = seedSurface(name: "watcher")

        let resolver = makeResolver(candidates: [builder, watcher])
        XCTAssertEqual(resolver.surfaceIds(forName: "builder"), [builder])
        XCTAssertEqual(resolver.surfaceIds(forName: "watcher"), [watcher])
    }

    func testSurfaceIdsByNameReturnsEmptyForUnknownName() {
        let builder = seedSurface(name: "builder")
        let resolver = makeResolver(candidates: [builder])
        XCTAssertEqual(resolver.surfaceIds(forName: "unknown"), [])
    }

    func testSurfaceIdsByNameReturnsAllDuplicates() {
        // Shouldn't happen in practice but must not collapse silently —
        // dispatcher logs a warning when count > 1.
        let a = seedSurface(name: "twin")
        let b = seedSurface(name: "twin")
        let resolver = makeResolver(candidates: [a, b])
        let result = Set(resolver.surfaceIds(forName: "twin"))
        XCTAssertEqual(result, [a, b])
    }

    func testSurfaceIdsByNameIgnoresUnnamed() {
        let unnamed = seedSurface(name: nil)
        let resolver = makeResolver(candidates: [unnamed])
        XCTAssertEqual(resolver.surfaceIds(forName: ""), [])
    }

    // MARK: - Surface name

    func testSurfaceNameReturnsTitle() {
        let surfaceId = seedSurface(name: "my-agent")
        let resolver = makeResolver(candidates: [surfaceId])
        XCTAssertEqual(resolver.surfaceName(for: surfaceId), "my-agent")
    }

    func testSurfaceNameReturnsNilWhenNoTitle() {
        let surfaceId = seedSurface(name: nil)
        let resolver = makeResolver(candidates: [surfaceId])
        XCTAssertNil(resolver.surfaceName(for: surfaceId))
    }

    // MARK: - Mailbox metadata enumeration

    func testEnumeratesMailboxMetadataForTitledSurfaces() {
        let watcher = seedSurface(
            name: "watcher",
            extraMailbox: [
                "mailbox.delivery": "stdin,watch",
                "mailbox.subscribe": "build.*,deploy.green",
                "mailbox.retention_days": "14",
            ]
        )
        let silent = seedSurface(
            name: "vim",
            extraMailbox: ["mailbox.delivery": "silent"]
        )
        let untitled = seedSurface(name: nil)

        let resolver = makeResolver(candidates: [watcher, silent, untitled])
        let rows = resolver.surfacesWithMailboxMetadata()
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })

        XCTAssertEqual(rows.count, 2, "untitled surfaces are filtered out")

        let watcherRow = try? XCTUnwrap(byName["watcher"])
        XCTAssertEqual(watcherRow?.delivery, ["stdin", "watch"])
        XCTAssertEqual(watcherRow?.subscribe, ["build.*", "deploy.green"])
        XCTAssertEqual(watcherRow?.retentionDays, 14)

        let silentRow = try? XCTUnwrap(byName["vim"])
        XCTAssertEqual(silentRow?.delivery, ["silent"])
        XCTAssertEqual(silentRow?.subscribe, [])
        XCTAssertNil(silentRow?.retentionDays)
    }

    func testEnumerateIgnoresNonMailboxKeys() {
        let s = seedSurface(
            name: "mixed",
            extraMailbox: [
                "mailbox.delivery": "stdin",
                "status": "busy",
                "role": "assistant",
            ]
        )
        let resolver = makeResolver(candidates: [s])
        let row = resolver.surfacesWithMailboxMetadata().first
        XCTAssertEqual(row?.mailboxKeys.keys.sorted(), ["mailbox.delivery"])
    }

    // MARK: - Stable address / role identity (C11-143)

    func testSurfaceMetadataExposesAddressAndRole() {
        let s = seedSurface(
            name: "builder-display",
            extraMailbox: [
                "mailbox.address": "01HSTABLEADDR",
                "mailbox.role": "builder",
            ]
        )
        let row = makeResolver(candidates: [s]).surfacesWithMailboxMetadata().first
        XCTAssertEqual(row?.address, "01HSTABLEADDR")
        XCTAssertEqual(row?.role, "builder")
        XCTAssertEqual(
            row?.identity,
            MailboxIdentity(title: "builder-display", address: "01HSTABLEADDR", role: "builder")
        )
    }

    func testSurfaceMetadataAddressAndRoleNilWhenUnset() {
        let s = seedSurface(name: "title-only")
        let row = makeResolver(candidates: [s]).surfacesWithMailboxMetadata().first
        XCTAssertNil(row?.address)
        XCTAssertNil(row?.role)
        XCTAssertEqual(row?.identity, MailboxIdentity(title: "title-only", address: nil, role: nil))
    }

    func testSurfaceMetadataRoleDoesNotFallBackToCanonicalRole() {
        // Canonical `role` is NOT a mailbox.* key — role addressing is opt-in
        // via mailbox.role so bare-name resolution stays title-stable.
        let s = seedSurface(name: "agent", extraMailbox: ["role": "reviewer"])
        let row = makeResolver(candidates: [s]).surfacesWithMailboxMetadata().first
        XCTAssertNil(row?.role)
    }
}

/// Cross-workspace recipient resolution. Pure — drives `MailboxGlobalResolver`
/// with an injected surface list, no app or metadata store needed.
final class MailboxGlobalResolverTests: XCTestCase {

    private let wsA = UUID()
    private let wsB = UUID()
    private let wsC = UUID()

    private func surface(_ ws: UUID, _ name: String) -> MailboxGlobalResolver.Surface {
        MailboxGlobalResolver.Surface(workspaceId: ws, surfaceId: UUID(), name: name)
    }

    private func surface(
        _ ws: UUID,
        title: String,
        address: String? = nil,
        role: String? = nil
    ) -> MailboxGlobalResolver.Surface {
        MailboxGlobalResolver.Surface(
            workspaceId: ws,
            surfaceId: UUID(),
            name: title,
            address: address,
            role: role
        )
    }

    private func resolver(_ surfaces: [MailboxGlobalResolver.Surface]) -> MailboxGlobalResolver {
        MailboxGlobalResolver(surfaces: { surfaces })
    }

    // MARK: - Local-first

    func testLocalMatchWinsOverRemoteSameName() {
        // "Reviewer" exists in both the sender's workspace and a remote one;
        // the local one must win so same-workspace sends never reach out.
        let local = surface(wsA, "Reviewer")
        let remote = surface(wsB, "Reviewer")
        let resolution = resolver([local, remote]).resolve(
            name: "Reviewer",
            senderWorkspaceId: wsA
        )
        XCTAssertEqual(resolution, .unique(workspaceId: wsA, surfaceIds: [local.surfaceId]))
    }

    func testLocalDuplicateNamesFanOut() {
        // Two "Builder" surfaces in the sender's workspace → both delivered.
        let a = surface(wsA, "Builder")
        let b = surface(wsA, "Builder")
        let resolution = resolver([a, b]).resolve(name: "Builder", senderWorkspaceId: wsA)
        guard case let .unique(workspaceId, surfaceIds) = resolution else {
            return XCTFail("expected unique, got \(resolution)")
        }
        XCTAssertEqual(workspaceId, wsA)
        XCTAssertEqual(Set(surfaceIds), [a.surfaceId, b.surfaceId])
    }

    // MARK: - Cross-workspace

    func testResolvesToRemoteWorkspaceWhenNoLocalMatch() {
        // Sender is in wsA; "Reviewer" only lives in wsB → deliver to wsB.
        let remote = surface(wsB, "Reviewer")
        let resolution = resolver([surface(wsA, "Builder"), remote]).resolve(
            name: "Reviewer",
            senderWorkspaceId: wsA
        )
        XCTAssertEqual(resolution, .unique(workspaceId: wsB, surfaceIds: [remote.surfaceId]))
    }

    func testUnknownNameIsUnresolved() {
        let resolution = resolver([surface(wsA, "Builder")]).resolve(
            name: "Nobody",
            senderWorkspaceId: wsA
        )
        XCTAssertEqual(resolution, .unresolved)
    }

    // MARK: - Collision across workspaces

    func testNameInMultipleRemoteWorkspacesIsAmbiguous() {
        // Sender wsA has no "Reviewer"; both wsB and wsC do → ambiguous.
        let b = surface(wsB, "Reviewer")
        let c = surface(wsC, "Reviewer")
        let resolution = resolver([b, c]).resolve(name: "Reviewer", senderWorkspaceId: wsA)
        guard case let .ambiguous(candidates) = resolution else {
            return XCTFail("expected ambiguous, got \(resolution)")
        }
        XCTAssertEqual(Set(candidates.map(\.workspaceId)), [wsB, wsC])
    }

    func testWorkspaceQualifierDisambiguates() {
        let b = surface(wsB, "Reviewer")
        let c = surface(wsC, "Reviewer")
        let resolution = resolver([b, c]).resolve(
            name: "Reviewer",
            senderWorkspaceId: wsA,
            workspaceQualifier: wsC
        )
        XCTAssertEqual(resolution, .unique(workspaceId: wsC, surfaceIds: [c.surfaceId]))
    }

    func testQualifierWithNoMatchIsUnresolved() {
        let b = surface(wsB, "Reviewer")
        let resolution = resolver([b]).resolve(
            name: "Reviewer",
            senderWorkspaceId: wsA,
            workspaceQualifier: wsC
        )
        XCTAssertEqual(resolution, .unresolved)
    }

    // MARK: - Stable address / role (C11-143)

    func testBareNamePrefersAddressOverTitle() {
        // wsA: one surface titled "delegator", a different one whose stable
        // address is "delegator". A bare send to "delegator" must hit the
        // address holder (precedence address > title), not the title holder.
        let titled = surface(wsA, title: "delegator")
        let addressed = surface(wsA, title: "delegator-display", address: "delegator")
        let resolution = resolver([titled, addressed]).resolve(
            name: "delegator",
            senderWorkspaceId: wsA
        )
        XCTAssertEqual(resolution, .unique(workspaceId: wsA, surfaceIds: [addressed.surfaceId]))
    }

    func testBareNamePrefersRoleOverTitle() {
        let titled = surface(wsA, title: "builder")
        let roled = surface(wsA, title: "builder-display", role: "builder")
        let resolution = resolver([titled, roled]).resolve(
            name: "builder",
            senderWorkspaceId: wsA
        )
        XCTAssertEqual(resolution, .unique(workspaceId: wsA, surfaceIds: [roled.surfaceId]))
    }

    func testBareNameAddressBeatsRole() {
        let roled = surface(wsA, title: "r-display", role: "lead")
        let addressed = surface(wsA, title: "a-display", address: "lead")
        let resolution = resolver([roled, addressed]).resolve(
            name: "lead",
            senderWorkspaceId: wsA
        )
        XCTAssertEqual(resolution, .unique(workspaceId: wsA, surfaceIds: [addressed.surfaceId]))
    }

    func testBareNameFallsBackToTitleWhenNoStableIdentity() {
        // Back-compat: only titles set → identical to pre-C11-143 behavior.
        let a = surface(wsA, title: "watcher")
        let resolution = resolver([a]).resolve(name: "watcher", senderWorkspaceId: wsA)
        XCTAssertEqual(resolution, .unique(workspaceId: wsA, surfaceIds: [a.surfaceId]))
    }

    func testSurfaceQualifierMatchesAddressOnly() {
        // `surface:<addr>` resolves only by mailbox.address — a surface merely
        // titled the same is NOT matched.
        let titled = surface(wsA, title: "addr-1")
        let addressed = surface(wsA, title: "real", address: "addr-1")
        let resolution = resolver([titled, addressed]).resolve(
            name: "surface:addr-1",
            senderWorkspaceId: wsA
        )
        XCTAssertEqual(resolution, .unique(workspaceId: wsA, surfaceIds: [addressed.surfaceId]))
    }

    func testRoleQualifierMatchesRoleOnly() {
        let titled = surface(wsA, title: "delegator")
        let roled = surface(wsA, title: "worker", role: "delegator")
        let resolution = resolver([titled, roled]).resolve(
            name: "role:delegator",
            senderWorkspaceId: wsA
        )
        XCTAssertEqual(resolution, .unique(workspaceId: wsA, surfaceIds: [roled.surfaceId]))
    }

    func testSurfaceQualifierAcrossWorkspaceIsAmbiguousWhenSplit() {
        // Address routing still honors local-first / ambiguity. Two remote
        // workspaces each hold the address → ambiguous (no local match).
        let b = surface(wsB, title: "b", address: "shared-addr")
        let c = surface(wsC, title: "c", address: "shared-addr")
        let resolution = resolver([b, c]).resolve(
            name: "surface:shared-addr",
            senderWorkspaceId: wsA
        )
        guard case let .ambiguous(candidates) = resolution else {
            return XCTFail("expected ambiguous, got \(resolution)")
        }
        XCTAssertEqual(Set(candidates.map(\.workspaceId)), [wsB, wsC])
    }

    func testRoleAddressLocalFirstWins() {
        // Same role in local and remote workspace → local wins, unchanged
        // local-first contract.
        let local = surface(wsA, title: "a", role: "delegator")
        let remote = surface(wsB, title: "b", role: "delegator")
        let resolution = resolver([local, remote]).resolve(
            name: "role:delegator",
            senderWorkspaceId: wsA
        )
        XCTAssertEqual(resolution, .unique(workspaceId: wsA, surfaceIds: [local.surfaceId]))
    }

    func testUnknownStableAddressIsUnresolved() {
        let a = surface(wsA, title: "real", address: "addr-1")
        let resolution = resolver([a]).resolve(
            name: "surface:nope",
            senderWorkspaceId: wsA
        )
        XCTAssertEqual(resolution, .unresolved)
    }
}

/// Parser + precedence selector for stable addressing (C11-143). Pure — no
/// store, no app.
final class MailboxAddressTests: XCTestCase {

    // MARK: - parse

    func testParseSurfaceQualifier() {
        XCTAssertEqual(MailboxAddress.parse("surface:01HABC"), .surface("01HABC"))
    }

    func testParseRoleQualifier() {
        XCTAssertEqual(MailboxAddress.parse("role:delegator"), .role("delegator"))
    }

    func testParseBareName() {
        XCTAssertEqual(MailboxAddress.parse("watcher"), .name("watcher"))
    }

    func testParseEmptyPayloadAfterPrefixIsHonored() {
        // `surface:` with nothing after it parses as a surface address with an
        // empty payload — which matches nothing, rather than degrading to a
        // bare name that could match a real title.
        XCTAssertEqual(MailboxAddress.parse("surface:"), .surface(""))
        XCTAssertEqual(MailboxAddress.parse("role:"), .role(""))
    }

    func testParseNameContainingColonIsBareUnlessKnownScheme() {
        XCTAssertEqual(MailboxAddress.parse("ci:status"), .name("ci:status"))
    }

    // MARK: - matcher precedence

    private func id(_ title: String?, address: String? = nil, role: String? = nil) -> MailboxIdentity {
        MailboxIdentity(title: title, address: address, role: role)
    }

    private func select(_ raw: String, _ ids: [MailboxIdentity]) -> [MailboxIdentity] {
        MailboxMatcher.select(MailboxAddress.parse(raw), from: ids, identity: { $0 })
    }

    func testMatcherBareNamePrecedenceAddressFirst() {
        let titled = id("x")
        let addressed = id("display", address: "x")
        let roled = id("display2", role: "x")
        XCTAssertEqual(select("x", [titled, addressed, roled]), [addressed])
    }

    func testMatcherBareNameRoleBeforeTitle() {
        let titled = id("x")
        let roled = id("display", role: "x")
        XCTAssertEqual(select("x", [titled, roled]), [roled])
    }

    func testMatcherBareNameTitleFallback() {
        let titled = id("x")
        XCTAssertEqual(select("x", [titled]), [titled])
    }

    func testMatcherSurfaceQualifierIgnoresTitleAndRole() {
        let titled = id("addr")
        let roled = id("display", role: "addr")
        let addressed = id("display2", address: "addr")
        XCTAssertEqual(select("surface:addr", [titled, roled, addressed]), [addressed])
    }

    func testMatcherRoleQualifierIgnoresTitleAndAddress() {
        let titled = id("dele")
        let addressed = id("display", address: "dele")
        let roled = id("display2", role: "dele")
        XCTAssertEqual(select("role:dele", [titled, addressed, roled]), [roled])
    }

    func testMatcherEmptyPayloadMatchesNothing() {
        let addressed = id("display", address: "")
        XCTAssertEqual(select("surface:", [addressed, id("x")]), [])
    }

    func testMatcherFansOutToAllSameAddress() {
        let a = id("d1", address: "shared")
        let b = id("d2", address: "shared")
        XCTAssertEqual(select("surface:shared", [a, b]), [a, b])
    }

    func testMatcherBlankIdentityNeverMatchesBlankQuery() {
        // A surface with an empty title/address is normalized to nil and must
        // not match an (also empty) query.
        let blank = id("", address: nil, role: nil)
        XCTAssertEqual(select("surface:", [blank]), [])
    }
}
