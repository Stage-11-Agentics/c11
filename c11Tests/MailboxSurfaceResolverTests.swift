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
}
