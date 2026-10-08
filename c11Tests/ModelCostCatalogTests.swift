// ModelCostCatalogTests.swift
//
// Pure-logic tests for the model token-cost catalog (picker cost column +
// `c11 model-costs` core). Everything runs against an injected temp directory;
// no Workspace/TabManager construction.

import XCTest
@testable import c11

final class ModelCostCatalogTests: XCTestCase {
    private var tempDir: URL!
    private var store: ModelCostCatalogStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-costs-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ModelCostCatalogStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func entry(_ inUSD: Double, _ outUSD: Double) -> ModelCostEntry {
        ModelCostEntry(inUSD: inUSD, outUSD: outUSD, source: nil, observedAt: nil, notes: nil)
    }

    // MARK: Store

    func testEmptyCatalogReturnsNoCost() {
        XCTAssertTrue(store.catalog().isEmpty)
        XCTAssertNil(store.cost(forModel: "opus"))
        XCTAssertNil(store.cost(forModel: nil))
        XCTAssertNil(store.cost(forModel: "  "))
    }

    func testSetThenLookupExactAndCaseInsensitive() throws {
        try store.set(model: "opus", entry: entry(15, 75))
        XCTAssertEqual(store.cost(forModel: "opus")?.inUSD, 15)
        XCTAssertEqual(store.cost(forModel: "Opus")?.outUSD, 75)
        XCTAssertNil(store.cost(forModel: "opus-mini"))
    }

    func testProviderPrefixedLookupFallsBackToStrippedForm() throws {
        try store.set(model: "deepseek-chat-v3.1", entry: entry(0.27, 1.10))
        let hit = store.cost(forModel: "deepseek/deepseek-chat-v3.1")
        XCTAssertEqual(hit?.inUSD, 0.27)
        // The exact prefixed key wins over the stripped form when both exist.
        try store.set(model: "deepseek/deepseek-chat-v3.1", entry: entry(0.5, 2))
        XCTAssertEqual(store.cost(forModel: "deepseek/deepseek-chat-v3.1")?.inUSD, 0.5)
    }

    func testRemoveAndPersistenceAcrossInstances() throws {
        try store.set(model: "sonnet", entry: entry(3, 15))
        let reread = ModelCostCatalogStore(directory: tempDir)
        XCTAssertEqual(reread.cost(forModel: "sonnet")?.inUSD, 3)
        XCTAssertTrue(try reread.remove(model: "sonnet"))
        XCTAssertFalse(try reread.remove(model: "sonnet"))
        XCTAssertNil(ModelCostCatalogStore(directory: tempDir).cost(forModel: "sonnet"))
    }

    func testCorruptFileDegradesToEmpty() throws {
        let url = tempDir.appendingPathComponent(ModelCostCatalogStore.fileName)
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(store.catalog().isEmpty)
        // A write recovers the file.
        try store.set(model: "opus", entry: entry(15, 75))
        XCTAssertEqual(store.cost(forModel: "opus")?.inUSD, 15)
    }

    func testImportMergesByDefaultAndReplacesOnRequest() throws {
        try store.set(model: "opus", entry: entry(15, 75))
        try store.importCatalog(["haiku": entry(0.8, 4)], replace: false)
        XCTAssertEqual(store.catalog().count, 2)
        try store.importCatalog(["sonnet": entry(3, 15)], replace: true)
        XCTAssertEqual(store.catalog().count, 1)
        XCTAssertNil(store.cost(forModel: "opus"))
    }

    func testShippedDefaultsResolveWithoutWritingAndPreserveWholeOverrides() throws {
        let bundled = store.resolvedCatalog()["claude-sonnet-5-5"]
        XCTAssertEqual(bundled?.inUSD, 2)
        XCTAssertEqual(bundled?.cacheReadUSD, 0.1)
        XCTAssertEqual(bundled?.cacheWrite1hUSD, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(ModelCostCatalogStore.fileName).path))
        try store.set(model: "claude-sonnet-5-5", entry: entry(1, 2))
        XCTAssertEqual(store.resolvedCatalog()["claude-sonnet-5-5"]?.inUSD, 1)
        XCTAssertNil(store.resolvedCatalog()["claude-sonnet-5-5"]?.cacheReadUSD)
        XCTAssertTrue(try store.remove(model: "claude-sonnet-5-5"))
        XCTAssertEqual(store.resolvedCatalog()["claude-sonnet-5-5"]?.inUSD, 2)
    }

    func testCacheRateCLISetRoundTripsAndMissingRatesStayUnknown() throws {
        _ = try ModelCostsCommandCore.run(args: ["set", "example", "--in", "2", "--out", "10", "--cache-read", "0.1", "--cache-write", "2.5", "--cache-write-1h", "4"], store: store)
        let saved = ModelCostCatalogStore(directory: tempDir).catalog()["example"]
        XCTAssertEqual(saved?.cacheReadUSD, 0.1)
        XCTAssertEqual(saved?.cacheWriteUSD, 2.5)
        XCTAssertEqual(saved?.cacheWrite1hUSD, 4)
        XCTAssertThrowsError(try ModelCostsCommandCore.run(args: ["set", "bad", "--in", "2", "--out", "10", "--cache-read", "nan"], store: store))
        XCTAssertNil(store.catalog()["bad"])
    }

    // MARK: CLI core

    func testCoreSetStampsObservedAtAndListsIt() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000) // 2026-08-06 UTC
        _ = try ModelCostsCommandCore.run(
            args: ["set", "opus", "--in", "15", "--out", "75", "--source", "https://anthropic.com/pricing"],
            store: store,
            now: now
        )
        let stored = store.catalog()["opus"]
        XCTAssertEqual(stored?.observedAt, "2026-08-06")
        XCTAssertEqual(stored?.source, "https://anthropic.com/pricing")
        let listed = try ModelCostsCommandCore.run(args: ["list"], store: store)
        XCTAssertTrue(listed.contains("opus"))
        XCTAssertTrue(listed.contains("$15/$75"))
    }

    func testCoreSetRejectsMissingOrInvalidNumbers() {
        XCTAssertThrowsError(try ModelCostsCommandCore.run(args: ["set", "opus", "--in", "x", "--out", "75"], store: store))
        XCTAssertThrowsError(try ModelCostsCommandCore.run(args: ["set", "opus", "--in", "15"], store: store))
        XCTAssertThrowsError(try ModelCostsCommandCore.run(args: ["set"], store: store))
    }

    func testCacheRateFlagsRequireValuesWithoutWritingCatalog() {
        let base = ["set", "example", "--in", "2", "--out", "10"]
        for flag in ["--cache-read", "--cache-write", "--cache-write-1h"] {
            for suffix in [[flag], [flag, "--notes", "example"], [flag + "="]] {
                XCTAssertThrowsError(try ModelCostsCommandCore.run(args: base + suffix, store: store))
                XCTAssertTrue(store.catalog().isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(ModelCostCatalogStore.fileName).path))
            }
        }
    }

    func testCoreImportFromFileAndRm() throws {
        let path = tempDir.appendingPathComponent("draft.json").path
        let draft = #"{"opus": {"in_usd": 15, "out_usd": 75, "source": "s", "observed_at": "2026-07-30"}}"#
        try Data(draft.utf8).write(to: URL(fileURLWithPath: path))
        let imported = try ModelCostsCommandCore.run(args: ["import", path], store: store)
        XCTAssertTrue(imported.contains("1 entry"))
        XCTAssertEqual(store.cost(forModel: "opus")?.inUSD, 15)
        _ = try ModelCostsCommandCore.run(args: ["rm", "opus"], store: store)
        XCTAssertNil(store.cost(forModel: "opus"))
        XCTAssertThrowsError(try ModelCostsCommandCore.run(args: ["rm", "opus"], store: store))
    }

    func testCoreUnknownSubcommandAndHelp() throws {
        XCTAssertThrowsError(try ModelCostsCommandCore.run(args: ["frobnicate"], store: store))
        XCTAssertTrue(try ModelCostsCommandCore.run(args: ["help"], store: store).contains("model-costs"))
    }

    // MARK: Money formatting

    func testTrimFormatsLikeThePrototype() {
        XCTAssertEqual(ModelCostsCommandCore.trim(15), "15")
        XCTAssertEqual(ModelCostsCommandCore.trim(3.5), "3.5")
        XCTAssertEqual(ModelCostsCommandCore.trim(0.25), "0.25")
        XCTAssertEqual(ModelCostsCommandCore.trim(0.8), "0.80")
    }
}
