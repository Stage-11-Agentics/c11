import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// c11 does not import `c11mux`, `c11`, or `cmux` trees.
final class StateDirectoryMigrationTests: XCTestCase {
    private var tempAppSupport: URL!
    private let legacyName = StateDirectoryMigration.legacyName
    private let currentName = StateDirectoryMigration.currentName

    override func setUpWithError() throws {
        try super.setUpWithError()
        StateDirectoryMigration.resetForTests()
        tempAppSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempAppSupport, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempAppSupport {
            try? FileManager.default.removeItem(at: tempAppSupport)
        }
        try super.tearDownWithError()
    }

    private var legacyURL: URL {
        tempAppSupport.appendingPathComponent(legacyName, isDirectory: true)
    }

    private var currentURL: URL {
        tempAppSupport.appendingPathComponent(currentName, isDirectory: true)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    func testLegacyTreeIsLeftUntouched() throws {
        XCTAssertEqual(currentName, "c11")
        try write("legacy-session", to: legacyURL.appendingPathComponent("session-com.stage11.c11.json"))
        try write("legacy-workspace", to: legacyURL
            .appendingPathComponent("workspaces/A0000000-0000-0000-0000-000000000000/snapshot.json"))

        StateDirectoryMigration.ensureMigrated(fileManager: .default, appSupport: tempAppSupport)
        StateDirectoryMigration.ensureMigrated(fileManager: .default, appSupport: tempAppSupport)

        XCTAssertEqual(
            try String(contentsOf: legacyURL.appendingPathComponent("session-com.stage11.c11.json"), encoding: .utf8),
            "legacy-session"
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: legacyURL.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentURL.path))
    }

    func testExistingCurrentBytesStayPut() throws {
        try write("legacy-bytes", to: legacyURL.appendingPathComponent("foo.json"))
        try write("current-bytes", to: currentURL.appendingPathComponent("foo.json"))

        StateDirectoryMigration.ensureMigrated(fileManager: .default, appSupport: tempAppSupport)

        XCTAssertEqual(try String(contentsOf: currentURL.appendingPathComponent("foo.json"), encoding: .utf8), "current-bytes")
        XCTAssertEqual(try String(contentsOf: legacyURL.appendingPathComponent("foo.json"), encoding: .utf8), "legacy-bytes")
        let attrs = try FileManager.default.attributesOfItem(atPath: legacyURL.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeDirectory)
    }

    func testFreshInstallCreatesNothing() {
        StateDirectoryMigration.ensureMigrated(fileManager: .default, appSupport: tempAppSupport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentURL.path))
    }
}
