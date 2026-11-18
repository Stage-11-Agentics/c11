import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// c11-2.0:begin-keep (`c11h` is the retired sidecar's name, on purpose)
/// C11H-269: c11 installs the bundled skills its `MANIFEST.json` lists, as c11 1.x did. The
/// retired line's sidecar, `c11h`, folded into `c11`: a copy c11 stamped under that name is
/// removed when c11's skills are installed or removed, and a folder c11 did not stamp is never
/// touched. A temporary HOME stands in for the operator's.
final class SkillInstallerSidecarTests: XCTestCase {
    private var sandbox: URL!
    private var home: URL!
    private var source: URL!
    private let fm = FileManager.default
    private let identity = SkillInstaller.AppIdentity(version: "2.0.0", build: "200", commitShort: "fixture")

    override func setUpWithError() throws {
        sandbox = fm.temporaryDirectory.appendingPathComponent("SkillInstallerSidecar-\(UUID().uuidString)", isDirectory: true)
        home = sandbox.appendingPathComponent("home", isDirectory: true)
        source = sandbox.appendingPathComponent("bundled-skills", isDirectory: true)
        try fm.createDirectory(at: SkillInstallerTarget.claude.configRoot(home: home), withIntermediateDirectories: true)
        try writeBundled(c11Version: "1")
    }

    override func tearDownWithError() throws {
        if let sandbox { try fm.removeItem(at: sandbox) }
    }

    private var skills: URL { SkillInstallerTarget.claude.skillsDir(home: home) }

    /// The bundle: `c11` and `c11-browser` are installable; `release` is a maintainer skill the
    /// manifest leaves out.
    private func writeBundled(c11Version: String) throws {
        for (name, version) in [("c11", c11Version), ("c11-browser", "1"), ("release", "1")] {
            let dir = source.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("---\nname: \(name)\nversion: \(version)\ndescription: fixture \(name)\n---\nbody of \(name)\n".utf8)
                .write(to: dir.appendingPathComponent("SKILL.md"))
        }
        try Data("{\"installable\":[\"c11\",\"c11-browser\"]}\n".utf8).write(to: source.appendingPathComponent("MANIFEST.json"))
    }

    private func install(force: Bool = false, packages: Set<String>? = nil) throws -> SkillInstallerApplyResult {
        try SkillInstaller.c11Install(target: .claude, home: home, sourceDir: source, force: force,
                                      packages: packages, appIdentity: identity)
    }

    private func installedNames() throws -> [String] {
        guard fm.fileExists(atPath: skills.path) else { return [] }
        return try fm.contentsOfDirectory(atPath: skills.path).sorted()
    }

    /// A copy of the retired sidecar as c11h's installer left it: stamped under the current
    /// schema with the hash of what it wrote (`installedBy` says who wrote it).
    @discardableResult
    private func plantStampedC11hCopy(installedBy: String = SkillInstallerRecord.installedByApp) throws -> URL {
        let dir = skills.appendingPathComponent("c11h")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("---\nname: c11h\nversion: 1\n---\nthe retired sidecar\n".utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        let hash = try SkillInstaller.contentHash(of: dir, skipInstallerManifest: true)
        let record = SkillInstallerRecord(
            schema: SkillInstallerRecord.schemaVersion, packageName: "c11h", skillVersion: "1",
            installedAt: "2026-11-01T00:00:00Z", appVersion: "1.8.1", appBuild: "150",
            commitShort: "old", sourceContentHash: hash, installedBy: installedBy)
        try JSONEncoder().encode(record).write(to: dir.appendingPathComponent(SkillInstaller.manifestFilename))
        return dir
    }

    /// A folder named c11h that c11 did not stamp: the operator's own.
    private func plantUnstampedC11hFolder() throws -> URL {
        let dir = skills.appendingPathComponent("c11h")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("the operator's own c11h folder\n".utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        try Data("{\"package\":\"c11h\"}\n".utf8).write(to: dir.appendingPathComponent(SkillInstaller.manifestFilename))
        return dir
    }

    // MARK: installs what the manifest lists

    func testInstallWritesEveryManifestPackageAndNothingElse() throws {
        let result = try install()
        XCTAssertEqual(result.installed.sorted(), ["c11", "c11-browser"])
        XCTAssertEqual(try installedNames(), ["c11", "c11-browser"], "the maintainer skill the manifest omits is not installed")
        let installed = skills.appendingPathComponent("c11")
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("SKILL.md")),
                       try String(contentsOf: source.appendingPathComponent("c11/SKILL.md")))
        let record = try JSONDecoder().decode(
            SkillInstallerRecord.self, from: Data(contentsOf: installed.appendingPathComponent(SkillInstaller.manifestFilename)))
        XCTAssertEqual(record.packageName, "c11")
        XCTAssertEqual(record.installedBy, SkillInstallerRecord.installedByApp)
    }

    func testStatusOffersTheManifestPackages() throws {
        XCTAssertEqual(try SkillInstaller.c11Status(for: .claude, home: home, sourceDir: source).map(\.package.name).sorted(),
                       ["c11", "c11-browser"])
    }

    func testANamedPackageInstallsOnlyThatOne() throws {
        let result = try install(packages: ["c11"])
        XCTAssertEqual(result.installed, ["c11"])
        XCTAssertEqual(try installedNames(), ["c11"])
    }

    // MARK: the retired sidecar

    func testInstallRetiresAStampedC11hCopy() throws {
        _ = try plantStampedC11hCopy()
        let result = try install(packages: ["c11"])
        XCTAssertEqual(result.retired, ["c11h"])
        XCTAssertEqual(try installedNames(), ["c11"])
        XCTAssertEqual(try install(packages: ["c11"]).retired, [], "twice is harmless")
    }

    func testAnEditedStampedC11hCopyIsKeptUnlessForced() throws {
        let dir = try plantStampedC11hCopy()
        try Data("the operator's own instructions\n".utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        let kept = try install(packages: ["c11"])
        XCTAssertEqual(kept.retired, [])
        XCTAssertEqual(kept.keptLocal, ["c11h"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("SKILL.md")), "the operator's own instructions\n")
        XCTAssertEqual(try install(force: true, packages: ["c11"]).retired, ["c11h"])
        XCTAssertFalse(fm.fileExists(atPath: dir.path))
    }

    func testACheckoutSyncedC11hCopyIsKeptByAnUnforcedRemove() throws {
        let dir = try plantStampedC11hCopy(installedBy: SkillInstallerRecord.installedBySync)
        let removed = try SkillInstaller.c11Remove(target: .claude, home: home, sourceDir: source)
        XCTAssertEqual(removed.retired, [])
        XCTAssertEqual(removed.keptLocal, ["c11h"])
        XCTAssertTrue(fm.fileExists(atPath: dir.path))
    }

    func testInstallingAnotherPackageLeavesTheSidecarAlone() throws {
        let dir = try plantStampedC11hCopy()
        XCTAssertEqual(try install(packages: ["c11-browser"]).retired, [])
        XCTAssertTrue(fm.fileExists(atPath: dir.path))
    }

    func testANamedRemoveRemovesOnlyThatPackage() throws {
        _ = try install()
        try plantStampedC11hCopy()
        let removed = try SkillInstaller.c11Remove(target: .claude, home: home, sourceDir: source, packages: ["c11"], retiring: [])
        XCTAssertEqual(removed.removed, ["c11"])
        XCTAssertEqual(removed.retired, [])
        XCTAssertEqual(try installedNames(), ["c11-browser", "c11h"])
        let retired = try SkillInstaller.c11Remove(target: .claude, home: home, sourceDir: source, packages: [], retiring: ["c11h"])
        XCTAssertEqual(retired.removed, [])
        XCTAssertEqual(retired.retired, ["c11h"])
        XCTAssertEqual(try installedNames(), ["c11-browser"])
    }

    func testAnUnstampedC11hFolderIsNeverTouched() throws {
        let theirs = try plantUnstampedC11hFolder()
        let before = try snapshot(theirs)
        XCTAssertEqual(try install().retired, [])
        _ = try install(force: true)
        XCTAssertEqual(try SkillInstaller.c11Remove(target: .claude, home: home, sourceDir: source, force: true).retired, [])
        XCTAssertEqual(try snapshot(theirs), before)
        XCTAssertEqual(try installedNames(), ["c11h"])
    }

    // MARK: idempotent, refreshes, uninstalls

    func testInstallIsIdempotentAndRefreshesOnlyWhenTheSkillChanged() throws {
        _ = try install()
        let stamp = skills.appendingPathComponent("c11/\(SkillInstaller.manifestFilename)")
        let first = try Data(contentsOf: stamp)

        let again = try install()
        XCTAssertEqual(again.installed, [])
        XCTAssertEqual(again.refreshed, [])
        XCTAssertEqual(again.skipped.sorted(), ["c11", "c11-browser"])
        XCTAssertEqual(try Data(contentsOf: stamp), first, "a current copy is not rewritten")

        try writeBundled(c11Version: "2")
        let changed = try install()
        XCTAssertEqual(changed.refreshed, ["c11"])
        XCTAssertTrue(try String(contentsOf: skills.appendingPathComponent("c11/SKILL.md")).contains("version: 2"))
    }

    func testRemoveDeletesOnlyManagedCopiesAndRetiresTheSidecar() throws {
        _ = try install()
        _ = try plantStampedC11hCopy()
        let other = skills.appendingPathComponent("user-owned")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("the operator's own skill\n".utf8).write(to: other.appendingPathComponent("SKILL.md"))
        let before = try snapshot(other)

        let removed = try SkillInstaller.c11Remove(target: .claude, home: home, sourceDir: source)
        XCTAssertEqual(removed.removed.sorted(), ["c11", "c11-browser"])
        XCTAssertEqual(removed.retired, ["c11h"])
        XCTAssertEqual(try installedNames(), ["user-owned"])
        XCTAssertEqual(try snapshot(other), before)
        XCTAssertEqual(try SkillInstaller.c11Remove(target: .claude, home: home, sourceDir: source).removed, [], "twice is harmless")
    }

    func testAFolderNamedC11ThatIsNotOurCopyIsNotReplacedOrRemovedWithoutForce() throws {
        let theirs = skills.appendingPathComponent("c11")
        try fm.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("not ours\n".utf8).write(to: theirs.appendingPathComponent("SKILL.md"))
        let before = try snapshot(theirs)

        XCTAssertThrowsError(try install(packages: ["c11"])) { error in
            XCTAssertEqual((error as? SkillInstallerError)?.code, .destNotManaged)
        }
        XCTAssertFalse(try SkillInstaller.c11Remove(target: .claude, home: home, sourceDir: source).removed.contains("c11"))
        XCTAssertEqual(try snapshot(theirs), before)
    }

    func testNothingElseUnderHomeIsWritten() throws {
        let other = SkillInstallerTarget.claude.configRoot(home: home).appendingPathComponent("settings.json")
        try Data("{\"tenant\":true}\n".utf8).write(to: other)
        let before = try Data(contentsOf: other)
        _ = try install()
        _ = try SkillInstaller.c11Remove(target: .claude, home: home, sourceDir: source)
        XCTAssertEqual(try Data(contentsOf: other), before)
        XCTAssertFalse(fm.fileExists(atPath: SkillInstallerTarget.codex.configRoot(home: home).path))
    }

    // MARK: the Settings page's model (Agent Skills) goes through the same entry points

    @MainActor
    func testSettingsModelOffersInstallsAndRemovesTheManifestPackagesAndRetiresTheSidecar() throws {
        let listed = AgentSkillsModel.computeSnapshot(executableURL: nil, home: home, fileManager: fm, sourceOverride: source)
        XCTAssertEqual(listed.rows.first(where: { $0.target == .claude })?.packages.map(\.package.name).sorted(),
                       ["c11", "c11-browser"])

        _ = try plantStampedC11hCopy()
        let model = AgentSkillsModel(home: home, sourceOverride: source)
        model.install(target: .claude, force: false)
        XCTAssertEqual(try installedNames(), ["c11", "c11-browser"])

        model.remove(target: .claude)
        XCTAssertEqual(try installedNames(), [])
    }

    private func snapshot(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for case let url as URL in try XCTUnwrap(fm.enumerator(at: dir, includingPropertiesForKeys: nil)) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                out[url.path.replacingOccurrences(of: dir.path, with: "")] = try Data(contentsOf: url)
            }
        }
        return out
    }
}
// c11-2.0:end-keep
