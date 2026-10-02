import Foundation
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class SkillInstallerPluginBoundaryTests: XCTestCase {
    private var sandbox: URL!
    private var home: URL!
    private var source: URL!
    private let identity = SkillInstaller.AppIdentity(version: "1.0", build: "269", commitShort: "fixture")

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillInstallerPluginBoundary-\(UUID().uuidString)", isDirectory: true)
        home = sandbox.appendingPathComponent("home", isDirectory: true)
        source = sandbox.appendingPathComponent("bundled-skills", isDirectory: true)
        try write(Data("{\"theme\":\"operator-owned\"}\n".utf8), to: configRoot.appendingPathComponent("opencode.json"))
        try write(Data([0, 1, 255, 0, 99]), to: configRoot.appendingPathComponent("tenant-state.bin"))
        try write(Data("user's independent skill\n".utf8),
                  to: SkillInstallerTarget.opencode.skillsDir(home: home).appendingPathComponent("user-owned/SKILL.md"))
        try writeSkill(version: "1", body: "Initial bundled fixture")
        try write(Data("export const bundledFixture = () => 'runtime-only';\n".utf8),
                  to: source.appendingPathComponent("opencode-plugins/c11-notify.js"))
    }

    override func tearDownWithError() throws {
        if let sandbox { try FileManager.default.removeItem(at: sandbox) }
    }

    private var configRoot: URL { SkillInstallerTarget.opencode.configRoot(home: home) }
    private var pluginRoot: URL { SkillInstallerTarget.opencode.pluginsDir(home: home) }

    func testAbsentPluginsDirectoryStaysAbsentWhileSkillsInstallRefreshAndRemove() throws {
        XCTAssertFalse(SkillInstallerTarget.opencode.supportsPlugins)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginRoot.path))
        try exerciseOrdinarySkillLifecyclePreservingTenantFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginRoot.path))
    }

    func testUnmanagedPluginAndUnrelatedTenantFilesStayByteIdentical() throws {
        try seedPlugin(body: "user-authored plugin, no c11 marker\n", marked: false)
        try exerciseOrdinarySkillLifecyclePreservingTenantFiles()
    }

    func testHistoricallyMarkedPluginAndSidecarStayByteIdentical() throws {
        try seedPlugin(body: "old bundled plugin copy\n", marked: true)
        try exerciseOrdinarySkillLifecyclePreservingTenantFiles()
    }

    func testEditedMarkedPluginAndSidecarStayByteIdentical() throws {
        try seedPlugin(body: "old bundled plugin copy\n", marked: true)
        // The marker remains from installation, while the user owns later edits.
        try Data("operator edited this plugin\nconst custom = 'preserve me';\n".utf8)
            .write(to: pluginRoot.appendingPathComponent("c11-notify.js"))
        try exerciseOrdinarySkillLifecyclePreservingTenantFiles()
    }

    func testDirectPluginCallsIgnoreMissingSourceAndDoNotCreateHome() throws {
        let missingHome = sandbox.appendingPathComponent("does-not-exist", isDirectory: true)
        let missingSource = sandbox.appendingPathComponent("no-source", isDirectory: true)
        for force in [false, true] {
            let result = try SkillInstaller.installPlugins(
                target: .opencode, home: missingHome, sourceDir: missingSource,
                force: force, appIdentity: identity,
                now: { XCTFail("No-op plugin installation must not consult the clock"); return Date() })
            assertNoPluginChanges(result)
        }
        assertNoPluginChanges(try SkillInstaller.removePlugins(
            target: .opencode, home: missingHome, sourceDir: missingSource))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingHome.path))
    }

    private func exerciseOrdinarySkillLifecyclePreservingTenantFiles() throws {
        let before = try tenantSnapshot()
        let bundledPlugin = source.appendingPathComponent("opencode-plugins/c11-notify.js")
        let bundledBytes = try Data(contentsOf: bundledPlugin)
        let skillFile = SkillInstallerTarget.opencode.skillsDir(home: home).appendingPathComponent("c11/SKILL.md")

        let installed = try SkillInstaller.install(
            target: .opencode, home: home, sourceDir: source, force: false, appIdentity: identity)
        XCTAssertEqual(installed.installed, ["c11"])
        XCTAssertEqual(try Data(contentsOf: skillFile), try Data(contentsOf: source.appendingPathComponent("c11/SKILL.md")))
        assertNoPluginChanges(try SkillInstaller.installPlugins(
            target: .opencode, home: home, sourceDir: source, force: false, appIdentity: identity))
        XCTAssertEqual(try tenantSnapshot(), before)

        try writeSkill(version: "2", body: "Updated bundled fixture")
        let refreshed = try SkillInstaller.install(
            target: .opencode, home: home, sourceDir: source, force: false, appIdentity: identity)
        XCTAssertEqual(refreshed.refreshed, ["c11"])
        XCTAssertEqual(try Data(contentsOf: skillFile), try Data(contentsOf: source.appendingPathComponent("c11/SKILL.md")))
        // Even force must have no authority over persistent plugin copies.
        assertNoPluginChanges(try SkillInstaller.installPlugins(
            target: .opencode, home: home, sourceDir: source, force: true, appIdentity: identity))
        XCTAssertEqual(try tenantSnapshot(), before)

        let removed = try SkillInstaller.remove(target: .opencode, home: home, sourceDir: source)
        XCTAssertEqual(removed.removed, ["c11"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillFile.path))
        assertNoPluginChanges(try SkillInstaller.removePlugins(target: .opencode, home: home, sourceDir: source))
        XCTAssertEqual(try tenantSnapshot(), before)
        // The runtime bundle plugin is independent of skill copy/removal.
        XCTAssertEqual(try Data(contentsOf: bundledPlugin), bundledBytes)
    }

    private func assertNoPluginChanges(_ result: SkillInstaller.SkillInstallerPluginResult,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.target, .opencode, file: file, line: line)
        XCTAssertEqual(result.installed, [], file: file, line: line)
        XCTAssertEqual(result.removed, [], file: file, line: line)
        XCTAssertEqual(result.skipped, [], file: file, line: line)
    }

    private func seedPlugin(body: String, marked: Bool) throws {
        let plugin = pluginRoot.appendingPathComponent("c11-notify.js")
        try write(Data(body.utf8), to: plugin)
        try write(Data("another user's plugin\n".utf8), to: pluginRoot.appendingPathComponent("unrelated-plugin.js"))
        try write(Data([13, 10, 0, 128]), to: pluginRoot.appendingPathComponent("unrelated-file.bin"))
        if marked {
            let record = SkillInstallerRecord(
                schema: SkillInstallerRecord.schemaVersion, packageName: "c11-notify.js",
                skillVersion: nil, installedAt: "2026-01-01T00:00:00Z",
                appVersion: "0.1", appBuild: "old", commitShort: "old",
                sourceContentHash: try SkillInstaller.fileContentHash(of: plugin))
            try write(JSONEncoder().encode(record), to: pluginRoot.appendingPathComponent("c11-notify.c11-plugin.json"))
        }
    }

    private func writeSkill(version: String, body: String) throws {
        try write(Data("---\nname: c11\nversion: \(version)\ndescription: Synthetic fixture\n---\n\(body)\n".utf8),
                  to: source.appendingPathComponent("c11/SKILL.md"))
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Snapshot every tenant file except the one ordinary skill c11 owns in
    /// this fixture. New, missing or changed plugin/config files fail equality.
    private func tenantSnapshot() throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: configRoot, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(configRoot.path.count + 1))
            if relative == "skills/c11" || relative.hasPrefix("skills/c11/") { continue }
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[relative] = try Data(contentsOf: url)
            }
        }
        return result
    }
}
