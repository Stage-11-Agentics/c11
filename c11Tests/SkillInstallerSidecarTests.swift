import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// c11-2.0:begin-keep (`c11h` is the retired sidecar's name, on purpose)
/// C11H-269: c11 installs the bundled skills its `MANIFEST.json` lists, as c11 1.x did. The
/// retired line's sidecar, `c11h`, folded into `c11`, and `c11-debug-windows` retired
/// (C11H-437): a copy c11 stamped under either name is removed when c11's skills are installed
/// or removed, an edited one is kept, and a folder c11 did not stamp is never touched. A copy a
/// checkout synced is kept by the app and retired by `scripts/sync-installed-skills.sh`. A
/// temporary HOME stands in for the operator's.
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

    /// A copy of a retired skill as an earlier installer left it: stamped under the current
    /// schema with the hash of what it wrote (`installedBy` says who wrote it).
    @discardableResult
    private func plantStampedCopy(
        _ name: String = "c11h", in target: SkillInstallerTarget = .claude,
        installedBy: String = SkillInstallerRecord.installedByApp
    ) throws -> URL {
        let dir = target.skillsDir(home: home).appendingPathComponent(name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("---\nname: \(name)\nversion: 1\n---\na retired skill\n".utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        let hash = try SkillInstaller.contentHash(of: dir, skipInstallerManifest: true)
        let record = SkillInstallerRecord(
            schema: SkillInstallerRecord.schemaVersion, packageName: name, skillVersion: "1",
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

    func testInstallRetiresStampedCopiesOfTheRetiredSkills() throws {
        try plantStampedCopy("c11h")
        try plantStampedCopy("c11-debug-windows")
        let result = try install(packages: ["c11"])
        XCTAssertEqual(result.retired, ["c11-debug-windows", "c11h"])
        XCTAssertEqual(try installedNames(), ["c11"])
        XCTAssertEqual(try install(packages: ["c11"]).retired, [], "twice is harmless")
    }

    func testEditedStampedCopiesOfTheRetiredSkillsAreKeptUnlessForced() throws {
        let dirs = try ["c11h", "c11-debug-windows"].map { try plantStampedCopy($0) }
        for dir in dirs {
            try Data("the operator's own instructions\n".utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        }
        let kept = try install(packages: ["c11"])
        XCTAssertEqual(kept.retired, [])
        XCTAssertEqual(kept.keptLocal, ["c11-debug-windows", "c11h"])
        for dir in dirs {
            XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("SKILL.md")), "the operator's own instructions\n")
        }
        XCTAssertEqual(try install(force: true, packages: ["c11"]).retired, ["c11-debug-windows", "c11h"])
        for dir in dirs { XCTAssertFalse(fm.fileExists(atPath: dir.path)) }
    }

    /// The copies on a maintainer's Mac were written by `scripts/sync-installed-skills.sh`.
    /// The app keeps those as copies from a checkout; the script, run with no names as after
    /// a pull, retires an unedited one in every harness and keeps an edited one.
    func testTheSyncScriptRetiresASyncedDebugWindowsCopyTheAppKeeps() throws {
        let sync = SkillInstallerRecord.installedBySync
        let synced = try plantStampedCopy("c11-debug-windows", installedBy: sync)
        let syncedPi = try plantStampedCopy("c11-debug-windows", in: .pi, installedBy: sync)
        let edited = try plantStampedCopy("c11-debug-windows", in: .codex, installedBy: sync)
        try Data("the operator's own notes\n".utf8).write(to: edited.appendingPathComponent("SKILL.md"))

        let app = try install(packages: ["c11"])
        XCTAssertEqual(app.retired, [])
        XCTAssertEqual(app.keptLocal, ["c11-debug-windows"], "the app keeps a copy a checkout synced")
        XCTAssertTrue(fm.fileExists(atPath: synced.path))

        let log = try runSyncScript()
        XCTAssertFalse(fm.fileExists(atPath: synced.path), log)
        XCTAssertFalse(fm.fileExists(atPath: syncedPi.path), log)
        XCTAssertEqual(try String(contentsOf: edited.appendingPathComponent("SKILL.md")), "the operator's own notes\n", log)
        XCTAssertTrue(log.contains("2 retired"), log)
    }

    /// What an installer never writes, added to a stamped copy by hand. The content hash reads
    /// only regular files, so none of these changes it.
    private enum LocalStructure: CaseIterable { case fileSymlink, directorySymlink, linkedStamp, fifo }

    private func add(_ structure: LocalStructure, to dir: URL) throws {
        switch structure {
        case .fileSymlink:
            let notes = sandbox.appendingPathComponent("notes-\(UUID().uuidString).md")
            try Data("my notes\n".utf8).write(to: notes)
            try fm.createSymbolicLink(at: dir.appendingPathComponent("my-notes.md"), withDestinationURL: notes)
        case .directorySymlink:
            let folder = sandbox.appendingPathComponent("folder-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("my file\n".utf8).write(to: folder.appendingPathComponent("mine.txt"))
            try fm.createSymbolicLink(at: dir.appendingPathComponent("my-folder"), withDestinationURL: folder)
        case .linkedStamp:
            let stamp = dir.appendingPathComponent(SkillInstaller.manifestFilename)
            let elsewhere = sandbox.appendingPathComponent("stamp-\(UUID().uuidString).json")
            try fm.moveItem(at: stamp, to: elsewhere)
            try fm.createSymbolicLink(at: stamp, withDestinationURL: elsewhere)
        case .fifo:
            XCTAssertEqual(mkfifo(dir.appendingPathComponent("my-pipe").path, 0o644), 0)
        }
    }

    /// One stamped `c11-debug-windows` copy per case, each in its own harness, plus an untouched
    /// copy in `.copilot` that is retired.
    private let structureTargets: [SkillInstallerTarget] = [.claude, .codex, .pi, .omp]

    private func plantCopiesHoldingLocalStructure(installedBy: String) throws -> (kept: [URL], control: URL) {
        var kept: [URL] = []
        for (target, structure) in zip(structureTargets, LocalStructure.allCases) {
            let dir = try plantStampedCopy("c11-debug-windows", in: target, installedBy: installedBy)
            try add(structure, to: dir)
            kept.append(dir)
        }
        return (kept, try plantStampedCopy("c11-debug-windows", in: .copilot, installedBy: installedBy))
    }

    func testInstallKeepsARetiredCopyHoldingLocalStructure() throws {
        let copies = try plantCopiesHoldingLocalStructure(installedBy: SkillInstallerRecord.installedByApp)
        for (target, dir) in zip(structureTargets, copies.kept) {
            let result = try SkillInstaller.c11Install(target: target, home: home, sourceDir: source, force: false,
                                                       packages: ["c11"], appIdentity: identity)
            XCTAssertEqual(result.retired, [], "\(target)")
            XCTAssertEqual(result.keptLocal, ["c11-debug-windows"], "\(target)")
            XCTAssertTrue(fm.fileExists(atPath: dir.path), "\(target)")
        }
        let control = try SkillInstaller.c11Install(target: .copilot, home: home, sourceDir: source, force: false,
                                                    packages: ["c11"], appIdentity: identity)
        XCTAssertEqual(control.retired, ["c11-debug-windows"])
        XCTAssertFalse(fm.fileExists(atPath: copies.control.path))
    }

    func testTheSyncScriptKeepsARetiredCopyHoldingLocalStructure() throws {
        let copies = try plantCopiesHoldingLocalStructure(installedBy: SkillInstallerRecord.installedBySync)
        let log = try runSyncScript()
        for (target, dir) in zip(structureTargets, copies.kept) {
            XCTAssertTrue(fm.fileExists(atPath: dir.path), "\(target): \(log)")
        }
        XCTAssertFalse(fm.fileExists(atPath: copies.control.path), log)
        XCTAssertTrue(log.contains("1 retired"), log)
    }

    /// One argument that holds the replacement's name among other words names no package, so
    /// it retires nothing.
    func testTheSyncScriptMatchesTheReplacementByWholeArgument() throws {
        let sync = SkillInstallerRecord.installedBySync
        let copies = try ["c11h", "c11-debug-windows"].map { try plantStampedCopy($0, installedBy: sync) }
        let log = try runSyncScript(arguments: ["not c11 package"])
        for dir in copies { XCTAssertTrue(fm.fileExists(atPath: dir.path), log) }
        XCTAssertTrue(log.contains("0 retired"), log)
    }

    func testACheckoutSyncedC11hCopyIsKeptByAnUnforcedRemove() throws {
        let dir = try plantStampedCopy(installedBy: SkillInstallerRecord.installedBySync)
        let removed = try SkillInstaller.c11Remove(target: .claude, home: home, sourceDir: source)
        XCTAssertEqual(removed.retired, [])
        XCTAssertEqual(removed.keptLocal, ["c11h"])
        XCTAssertTrue(fm.fileExists(atPath: dir.path))
    }

    func testInstallingAnotherPackageLeavesTheSidecarAlone() throws {
        let dir = try plantStampedCopy()
        XCTAssertEqual(try install(packages: ["c11-browser"]).retired, [])
        XCTAssertTrue(fm.fileExists(atPath: dir.path))
    }

    func testANamedRemoveRemovesOnlyThatPackage() throws {
        _ = try install()
        try plantStampedCopy()
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
        _ = try plantStampedCopy()
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

        _ = try plantStampedCopy()
        let model = AgentSkillsModel(home: home, sourceOverride: source)
        model.install(target: .claude, force: false)
        XCTAssertEqual(try installedNames(), ["c11", "c11-browser"])

        model.remove(target: .claude)
        XCTAssertEqual(try installedNames(), [])
    }

    /// Runs this checkout's `scripts/sync-installed-skills.sh` (with no names unless given), with
    /// the fixture HOME as the only harness home it can see.
    private func runSyncScript(arguments: [String] = []) throws -> String {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/sync-installed-skills.sh")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment.removeValue(forKey: "C11_SKILL_ROOTS")
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let log = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, log)
        return log
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
