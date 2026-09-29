import XCTest
@testable import c11

/// Pure-logic tests for the New Workspace recents store (C11-240): the cap,
/// pin order, migration from the v2 blob, path normalization, and fail-soft
/// decoding. Each test uses its own UserDefaults suite.
final class CreateWorkspaceRecentsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "c11.tests.recents.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func entry(_ path: String, age: TimeInterval, count: Int = 1, pinned: Bool = false) -> RecentDirectory {
        RecentDirectory(
            path: path,
            lastOpenedAt: Date(timeIntervalSince1970: 1_000_000 - age),
            openCount: count,
            pinned: pinned
        )
    }

    private func writeV2(_ entries: [RecentDirectory]) throws {
        defaults.set(try JSONEncoder().encode(entries), forKey: CreateWorkspaceRecents.storageKey)
    }

    // MARK: Path normalization

    func testNormalizeStripsTrailingSlashDotsAndWhitespace() {
        XCTAssertEqual(RecentsPath.normalize("/tmp/a/"), "/tmp/a")
        XCTAssertEqual(RecentsPath.normalize("  /tmp/a//b/../c/ \n"), "/tmp/a/c")
        XCTAssertEqual(RecentsPath.normalize("/"), "/")
        XCTAssertEqual(RecentsPath.normalize("   "), "")
        XCTAssertEqual(
            RecentsPath.normalize("~/x/"),
            FileManager.default.homeDirectoryForCurrentUser.path + "/x"
        )
    }

    func testRecordMergesTrailingSlashVariantsIntoOneEntry() {
        CreateWorkspaceRecents.record("/tmp/proj", defaults: defaults)
        CreateWorkspaceRecents.record("/tmp/proj/", defaults: defaults)
        CreateWorkspaceRecents.record(" /tmp/./proj ", defaults: defaults)
        let list = CreateWorkspaceRecents.load(defaults: defaults)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].path, "/tmp/proj")
        XCTAssertEqual(list[0].openCount, 3)
    }

    func testRecordHealsAnUnnormalizedStoredPathAndItsPin() throws {
        try writeV2([entry("/tmp/proj/", age: 10, pinned: true)])
        CreateWorkspaceRecents.record("/tmp/proj", defaults: defaults)
        let state = CreateWorkspaceRecents.loadState(defaults: defaults)
        XCTAssertEqual(state.entries.map(\.path), ["/tmp/proj"])
        XCTAssertEqual(state.pins, ["/tmp/proj"])
    }

    // MARK: Cap

    func testEvictionAtCapDropsOldestUnpinnedNeverAPin() {
        var state = CreateWorkspaceRecents.State()
        let cap = CreateWorkspaceRecents.maxCount
        // The oldest entry is pinned; it must survive.
        // /d/0 is the oldest ... /d/(cap-1) the newest.
        state.entries = (0..<cap).map { entry("/d/\($0)", age: Double(cap - $0)) }
        state.pins = ["/d/0"]
        state.syncPinnedFlags()

        state.record("/d/new", now: Date(timeIntervalSince1970: 2_000_000))

        XCTAssertEqual(state.entries.count, cap)
        XCTAssertTrue(state.entries.contains { $0.path == "/d/0" }, "the oldest entry is a pin and must stay")
        XCTAssertFalse(state.entries.contains { $0.path == "/d/1" }, "the oldest unpinned entry goes")
        XCTAssertTrue(state.entries.contains { $0.path == "/d/new" })
        XCTAssertEqual(state.pins, ["/d/0"])
    }

    func testEvictionNeverDropsAnyPinWhenEverythingOldIsPinned() {
        var state = CreateWorkspaceRecents.State()
        state.entries = (0..<10).map { entry("/d/\($0)", age: Double(10 - $0)) }
        state.pins = (0..<10).map { "/d/\($0)" }
        state.syncPinnedFlags()
        state.record("/d/new", now: Date(timeIntervalSince1970: 2_000_000), maxCount: 10)
        // Every old entry is a pin and the new one is the entry just recorded:
        // nothing is evictable, so the list stays over the cap by one.
        XCTAssertEqual(state.entries.count, 11)
        XCTAssertEqual(Set(state.pins), Set((0..<10).map { "/d/\($0)" }))
        XCTAssertTrue(state.entries.contains { $0.path == "/d/new" })
    }

    func testCapIsTwoHundredFifty() {
        XCTAssertEqual(CreateWorkspaceRecents.maxCount, 250)
    }

    func testLoadDoesNotTruncateAStoredListOverTheCap() throws {
        let many = (0..<300).map { entry("/d/\($0)", age: Double($0)) }
        try writeV2(many)
        XCTAssertEqual(CreateWorkspaceRecents.load(defaults: defaults).count, 300)
    }

    // MARK: Pins

    func testPinOrderPersistsAndReorders() {
        for name in ["a", "b", "c", "d"] { CreateWorkspaceRecents.record("/p/\(name)", defaults: defaults) }
        CreateWorkspaceRecents.pin("/p/c", defaults: defaults)
        CreateWorkspaceRecents.pin("/p/a", defaults: defaults)
        CreateWorkspaceRecents.pin("/p/d", defaults: defaults)
        XCTAssertEqual(CreateWorkspaceRecents.pins(defaults: defaults), ["/p/c", "/p/a", "/p/d"])

        CreateWorkspaceRecents.movePin("/p/d", to: 0, defaults: defaults)
        XCTAssertEqual(CreateWorkspaceRecents.pins(defaults: defaults), ["/p/d", "/p/c", "/p/a"])

        CreateWorkspaceRecents.pin("/p/b", at: 1, defaults: defaults)
        XCTAssertEqual(CreateWorkspaceRecents.pins(defaults: defaults), ["/p/d", "/p/b", "/p/c", "/p/a"])

        // A fresh read from the same defaults sees the same order.
        let state = CreateWorkspaceRecents.loadState(defaults: defaults)
        XCTAssertEqual(state.pins, ["/p/d", "/p/b", "/p/c", "/p/a"])
        XCTAssertEqual(Set(state.entries.filter(\.pinned).map(\.path)), Set(state.pins))
    }

    func testPerEntryPinnedFlagIsStillWrittenForOlderBuilds() throws {
        CreateWorkspaceRecents.record("/p/a", defaults: defaults)
        CreateWorkspaceRecents.record("/p/b", defaults: defaults)
        CreateWorkspaceRecents.pin("/p/a", defaults: defaults)
        let raw = try JSONDecoder().decode(
            [RecentDirectory].self,
            from: try XCTUnwrap(defaults.data(forKey: CreateWorkspaceRecents.storageKey))
        )
        XCTAssertEqual(raw.first { $0.path == "/p/a" }?.pinned, true)
        XCTAssertEqual(raw.first { $0.path == "/p/b" }?.pinned, false)
    }

    func testPinningAPathThatIsNotARecentIsRefused() {
        var state = CreateWorkspaceRecents.State()
        XCTAssertFalse(state.pin("/nope"))
        XCTAssertTrue(state.pins.isEmpty)
    }

    func testRemoveDropsTheEntryAndItsPin() {
        CreateWorkspaceRecents.record("/p/a", defaults: defaults)
        CreateWorkspaceRecents.record("/p/b", defaults: defaults)
        CreateWorkspaceRecents.pin("/p/a", defaults: defaults)
        CreateWorkspaceRecents.remove("/p/a", defaults: defaults)
        let state = CreateWorkspaceRecents.loadState(defaults: defaults)
        XCTAssertEqual(state.entries.map(\.path), ["/p/b"])
        XCTAssertTrue(state.pins.isEmpty)
    }

    // MARK: Migration

    func testMigrationFromV2BlobKeepsEveryEntryAndPinInDisplayOrder() throws {
        // A v2 blob as an older build wrote it: pinned flags, no pins key.
        let stored = [
            entry("/p/old-pin", age: 500, count: 9, pinned: true),
            entry("/p/plain-1", age: 5, count: 2),
            entry("/p/new-pin", age: 50, count: 1, pinned: true),
            entry("/p/plain-2", age: 700, count: 40),
            entry("/p/mid-pin", age: 100, count: 3, pinned: true),
        ]
        try writeV2(stored)
        XCTAssertNil(defaults.data(forKey: CreateWorkspaceRecents.pinsKey))

        let state = CreateWorkspaceRecents.loadState(defaults: defaults)
        XCTAssertEqual(state.entries.map(\.path), stored.map(\.path), "no entry is lost or reordered")
        XCTAssertEqual(state.entries.map(\.openCount), stored.map(\.openCount))
        // Pinned first, most recent first: the order the old list drew them in.
        XCTAssertEqual(state.pins, ["/p/new-pin", "/p/mid-pin", "/p/old-pin"])
        // The migrated order is now stored, so later loads do not re-derive it.
        let second = CreateWorkspaceRecents.pins(defaults: defaults)
        XCTAssertEqual(second, state.pins)
        XCTAssertNotNil(defaults.data(forKey: CreateWorkspaceRecents.pinsKey))
    }

    func testMigrationFromLegacyStringArray() {
        defaults.set(["/l/a", "/l/b"], forKey: CreateWorkspaceRecents.legacyKey)
        let state = CreateWorkspaceRecents.loadState(defaults: defaults)
        XCTAssertEqual(state.entries.map(\.path), ["/l/a", "/l/b"])
        XCTAssertTrue(state.pins.isEmpty)
        XCTAssertNil(defaults.array(forKey: CreateWorkspaceRecents.legacyKey))
    }

    func testOnceThePinsKeyExistsItIsTheSourceOfTruth() throws {
        // The flag says pinned, the pins key says otherwise: the key wins.
        try writeV2([entry("/p/a", age: 1, pinned: true), entry("/p/b", age: 2)])
        defaults.set(try JSONEncoder().encode(["/p/b"]), forKey: CreateWorkspaceRecents.pinsKey)
        let state = CreateWorkspaceRecents.loadState(defaults: defaults)
        XCTAssertEqual(state.pins, ["/p/b"])
        XCTAssertEqual(state.entries.first { $0.path == "/p/a" }?.pinned, false)
    }

    // MARK: Fail soft

    func testUnreadableStoredDataIsNeverOverwritten() {
        let junk = Data("not json".utf8)
        defaults.set(junk, forKey: CreateWorkspaceRecents.storageKey)

        XCTAssertTrue(CreateWorkspaceRecents.load(defaults: defaults).isEmpty)
        CreateWorkspaceRecents.record("/p/new", defaults: defaults)
        CreateWorkspaceRecents.pin("/p/new", defaults: defaults)
        CreateWorkspaceRecents.remove("/p/new", defaults: defaults)

        XCTAssertEqual(defaults.data(forKey: CreateWorkspaceRecents.storageKey), junk)
        XCTAssertNil(defaults.data(forKey: CreateWorkspaceRecents.pinsKey))
        XCTAssertFalse(CreateWorkspaceRecents.mutate(defaults: defaults) { _ in })
    }

    func testUnreadablePinsKeyIsNeverOverwritten() throws {
        try writeV2([entry("/p/a", age: 1)])
        let junk = Data("{".utf8)
        defaults.set(junk, forKey: CreateWorkspaceRecents.pinsKey)
        CreateWorkspaceRecents.record("/p/b", defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: CreateWorkspaceRecents.pinsKey), junk)
        XCTAssertEqual(CreateWorkspaceRecents.loadState(defaults: defaults).entries.count, 0)
    }

    // MARK: Ordering

    func testPinnedEntriesKeepTheirNormalSortedPosition() {
        let entries = [
            entry("/p/a", age: 30, count: 1, pinned: true),
            entry("/p/b", age: 10, count: 5),
            entry("/p/c", age: 20, count: 9, pinned: true),
        ]
        XCTAssertEqual(RecentsOrdering.sorted(entries, by: .recent).map(\.path), ["/p/b", "/p/c", "/p/a"])
        XCTAssertEqual(RecentsOrdering.sorted(entries, by: .opened).map(\.path), ["/p/c", "/p/b", "/p/a"])
    }
}
