import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class BundledSkillTests: XCTestCase {
    /// Exercise the actual copied CLI + bundled resources in the existing
    /// c11-logic CI gate. This never launches the app or connects to its socket.
    func testBuiltCLIPrintsOfflineGuide() throws {
        let products = Bundle(for: BundledSkillTests.self).bundleURL.deletingLastPathComponent()
        let appName: String
        #if DEBUG
        appName = "c11 DEV.app"
        #else
        appName = "c11.app"
        #endif
        let cli = products.appendingPathComponent(appName + "/Contents/Resources/bin/c11")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli.path), "Missing built CLI at \(cli.path)")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tests_v2/test_guide_and_features.py")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "--offline"]
        var environment = ProcessInfo.processInfo.environment
        environment["C11_CLI"] = cli.path
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testBundlePagesAndTraversal() throws {
        try withFixture { root in
            let skill = "---\nname: c11\nversion: 7\n---\n# Fixture skill\n"
            try skill.write(to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            let references = root.appendingPathComponent("references")
            try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
            try "Fixture API\n".write(to: references.appendingPathComponent("api.md"), atomically: true, encoding: .utf8)
            let loader = BundledSkill(root: root)
            XCTAssertEqual(try loader.load().body, skill)
            XCTAssertEqual(try loader.load().version, "7")
            XCTAssertEqual(try loader.load(page: "api").body, "Fixture API\n")
            for page in ["../SKILL", "references/api", "..", "", "missing"] {
                XCTAssertThrowsError(try loader.load(page: page))
            }
        }
    }

    func testMissingSkillIsAnError() throws {
        try withFixture { root in
            XCTAssertThrowsError(try BundledSkill(root: root).load())
        }
    }

    func testIdentityReadsBuiltC11StampAndDoesNotInferCheckoutIdentity() throws {
        try withFixture { root in
            let bundle = root.appendingPathComponent("Fixture.app")
            let contents = bundle.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["C11Commit": "ABCDEF0123456789", "CFBundleShortVersionString": "1.2", "CFBundleVersion": "42"]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            let identity = C11BuildIdentity(bundleURL: bundle)
            XCTAssertEqual(identity.commit, "abcdef0123456789")
            XCTAssertEqual(identity.shortVersion, "1.2")
            XCTAssertEqual(identity.build, "42")
            XCTAssertNil(C11BuildIdentity(bundleURL: root).commit)
            XCTAssertNil(C11BuildIdentity(info: [:]).commit)
            XCTAssertEqual(C11BuildIdentity(info: ["CMUXCommit": "abcdef012"]).commit, "abcdef012")
            XCTAssertEqual(C11BuildIdentity(info: ["C11Commit": "abcdef012", "CMUXCommit": "111111111"]).commit, "abcdef012")
        }
    }

    func testCommitComparisonUsesBothStamps() {
        XCTAssertEqual(C11BuildIdentity.commitsMatch("ABCDEF012", "abcdef0123456789"), true)
        XCTAssertEqual(C11BuildIdentity.commitsMatch("abcdef012", "111111111"), false)
        XCTAssertNil(C11BuildIdentity.commitsMatch(nil, "abcdef012"))
        XCTAssertNil(C11BuildIdentity.commitsMatch("unknown", "abcdef012"))
    }

    func testSymlinkedCLIUsesItsContainingAppOnly() throws {
        try withFixture { root in
            let bundle = root.appendingPathComponent("Fixture.app")
            let bin = bundle.appendingPathComponent("Contents/Resources/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let executable = bin.appendingPathComponent("c11")
            try Data().write(to: executable)
            let link = root.appendingPathComponent("c11")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
            XCTAssertEqual(BundledSkill.containingBundle(executableURL: link), bundle.resolvingSymlinksInPath())
            XCTAssertNil(BundledSkill.containingBundle(executableURL: root.appendingPathComponent("standalone")))
        }
    }
}
