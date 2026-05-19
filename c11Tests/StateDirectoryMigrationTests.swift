import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Behavioral tests for the C11-103 per-entry merge fix. Each test runs the
/// migration against an isolated temp dir treated as the fake Application
/// Support root, so tests never touch the real `~/Library/Application Support`.
final class StateDirectoryMigrationTests: XCTestCase {

    private var tempAppSupport: URL!
    private let legacyName = StateDirectoryMigration.legacyName
    private let currentName = StateDirectoryMigration.currentName

    override func setUpWithError() throws {
        try super.setUpWithError()
        StateDirectoryMigration.resetForTests()
        tempAppSupport = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("c11-103-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempAppSupport,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempAppSupport {
            try? FileManager.default.removeItem(at: tempAppSupport)
        }
        // Intentionally do NOT reset `didRun` here. Each test method's call to
        // `ensureMigrated(appSupport: tempAppSupport)` latches `didRun = true`,
        // and we want that latch to outlive this test class so subsequent
        // suites in the same xctest process cannot trigger the migration
        // against the operator's real `~/Library/Application Support/`.
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var legacyURL: URL {
        tempAppSupport.appendingPathComponent(legacyName, isDirectory: true)
    }

    private var currentURL: URL {
        tempAppSupport.appendingPathComponent(currentName, isDirectory: true)
    }

    private func makeLegacy() throws {
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
    }

    private func makeCurrent() throws {
        try FileManager.default.createDirectory(at: currentURL, withIntermediateDirectories: true)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func runMigration() {
        StateDirectoryMigration.ensureMigrated(
            fileManager: .default,
            appSupport: tempAppSupport
        )
    }

    // MARK: - AC1: clean-rename happy path preserved

    func testCleanRenameWhenOnlyLegacyExists() throws {
        try makeLegacy()
        let legacySession = legacyURL.appendingPathComponent("session-com.stage11.c11.json")
        try write("legacy-session", to: legacySession)

        runMigration()

        let currentSession = currentURL.appendingPathComponent("session-com.stage11.c11.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentSession.path),
                      "Session file should land in current dir")
        XCTAssertEqual(try read(currentSession), "legacy-session")

        // Legacy should now be a symlink pointing at current (relative).
        let attrs = try FileManager.default.attributesOfItem(atPath: legacyURL.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: legacyURL.path)
        XCTAssertEqual(target, currentName)
    }

    // MARK: - AC2: prod-bundle-id session in legacy, debug files in current

    func testDualDirMigratesProdSessionWhenCurrentHasOnlyDebugFiles() throws {
        try makeLegacy()
        try makeCurrent()
        let prodSession = legacyURL.appendingPathComponent("session-com.stage11.c11.json")
        let debugSession = currentURL.appendingPathComponent("session-com.stage11.c11.debug.tag.json")
        try write("real-state", to: prodSession)
        try write("debug-build-state", to: debugSession)

        runMigration()

        let movedProd = currentURL.appendingPathComponent("session-com.stage11.c11.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedProd.path),
                      "Prod session must migrate into current")
        XCTAssertEqual(try read(movedProd), "real-state")
        // Debug session untouched.
        XCTAssertEqual(try read(debugSession), "debug-build-state")
        // Legacy was emptied of its single entry and replaced by a symlink.
        // (`fileExists` follows the symlink, so checking prodSession.path
        // would resolve back to the moved file in current — instead check
        // the legacy dir itself is now a symlink.)
        let attrs = try FileManager.default.attributesOfItem(atPath: legacyURL.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "Legacy dir should be a symlink after its only entry migrated")
    }

    // MARK: - AC3: same-name collision → current wins

    func testFileCollisionLeavesCurrentBytesIntact() throws {
        try makeLegacy()
        try makeCurrent()
        let legacyFile = legacyURL.appendingPathComponent("foo.json")
        let currentFile = currentURL.appendingPathComponent("foo.json")
        try write("legacy-bytes", to: legacyFile)
        try write("current-bytes", to: currentFile)

        runMigration()

        XCTAssertEqual(try read(currentFile), "current-bytes",
                       "Current file must not be overwritten")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path),
                      "Legacy file stays put when there's a name collision in current")
        XCTAssertEqual(try read(legacyFile), "legacy-bytes")
    }

    // MARK: - AC4: workspaces/<uuid>/ shallow recursion

    func testWorkspacesShallowRecursionMergesUuidsOneLevelDeep() throws {
        try makeLegacy()
        try makeCurrent()
        let legacyWS = legacyURL.appendingPathComponent("workspaces", isDirectory: true)
        let currentWS = currentURL.appendingPathComponent("workspaces", isDirectory: true)
        let uuidA = "A0000000-0000-0000-0000-000000000000"
        let uuidB = "B0000000-0000-0000-0000-000000000000"
        let uuidC = "C0000000-0000-0000-0000-000000000000"
        // Legacy has {A, B}, current has {B, C}.
        try write("A-legacy", to: legacyWS.appendingPathComponent(uuidA).appendingPathComponent("snapshot.json"))
        try write("B-legacy", to: legacyWS.appendingPathComponent(uuidB).appendingPathComponent("snapshot.json"))
        try write("B-current", to: currentWS.appendingPathComponent(uuidB).appendingPathComponent("snapshot.json"))
        try write("C-current", to: currentWS.appendingPathComponent(uuidC).appendingPathComponent("snapshot.json"))

        runMigration()

        let afterMerge = Set(
            try FileManager.default.contentsOfDirectory(atPath: currentWS.path)
        )
        XCTAssertEqual(afterMerge, Set([uuidA, uuidB, uuidC]),
                       "Current workspaces should contain union of UUIDs")
        // B in current must remain the current copy.
        XCTAssertEqual(
            try read(currentWS.appendingPathComponent(uuidB).appendingPathComponent("snapshot.json")),
            "B-current"
        )
        // A's snapshot came from legacy.
        XCTAssertEqual(
            try read(currentWS.appendingPathComponent(uuidA).appendingPathComponent("snapshot.json")),
            "A-legacy"
        )
    }

    // MARK: - AC5: fresh install (neither dir exists)

    func testFreshInstallIsNoOp() throws {
        // tempAppSupport exists but contains neither c11 nor c11mux.
        runMigration()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path),
                       "Fresh install should not create legacy dir")
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentURL.path),
                       "Fresh install should not create current dir")
    }

    // MARK: - AC6: didRun guard prevents re-execution

    func testDidRunGuardSkipsSecondCall() throws {
        try makeLegacy()
        try write("first-run", to: legacyURL.appendingPathComponent("snapshot.json"))

        runMigration()
        // After first run: snapshot landed in current; legacy is a symlink.
        let firstHop = currentURL.appendingPathComponent("snapshot.json")
        XCTAssertEqual(try read(firstHop), "first-run")

        // Plant a new file at the *legacy resolved path* (which is now a
        // symlink pointing at current). To prove the guard, plant a file
        // somewhere the migration WOULD move if it ran a second time.
        // We restore a non-symlink legacy dir + a fresh file, then call
        // ensureMigrated() again without resetForTests.
        try FileManager.default.removeItem(at: legacyURL)
        try makeLegacy()
        let postRunFile = legacyURL.appendingPathComponent("second-run.json")
        try write("would-move-if-not-guarded", to: postRunFile)

        // Second call must be a no-op because didRun is still latched.
        StateDirectoryMigration.ensureMigrated(
            fileManager: .default,
            appSupport: tempAppSupport
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: postRunFile.path),
                      "didRun guard must prevent the second migration from moving anything")
        let currentSecond = currentURL.appendingPathComponent("second-run.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentSecond.path),
                       "second-run.json must not appear in current")
    }

    // MARK: - AC8: symlink only when legacy is empty after merge

    func testSymlinkCreatedWhenLegacyEmptyAfterMerge() throws {
        try makeLegacy()
        try write("payload", to: legacyURL.appendingPathComponent("a.json"))

        runMigration()

        let attrs = try FileManager.default.attributesOfItem(atPath: legacyURL.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "Empty legacy should be replaced with a symlink")
    }

    func testSymlinkNotCreatedWhenLegacyRetainsCollidedEntries() throws {
        try makeLegacy()
        try makeCurrent()
        // Force a collision so legacy keeps the file.
        try write("legacy", to: legacyURL.appendingPathComponent("foo.json"))
        try write("current", to: currentURL.appendingPathComponent("foo.json"))

        runMigration()

        // Legacy should still be a real directory with foo.json inside.
        let attrs = try FileManager.default.attributesOfItem(atPath: legacyURL.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeDirectory,
                       "Legacy must remain a directory when collisions kept entries")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: legacyURL.appendingPathComponent("foo.json").path
        ))
    }
}
