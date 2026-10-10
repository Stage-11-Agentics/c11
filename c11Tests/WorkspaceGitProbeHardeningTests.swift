import Foundation
import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// The workspace git probe (branch, dirty state, worktree chips) runs in a
/// terminal's working directory, which can sit in a checkout whose `.git/`
/// arrived from anywhere. Its config must not get to run a program.
final class WorkspaceGitProbeHardeningTests: XCTestCase {
    func testHostileWorkspaceRepositoryRunsNoProgramAndProbeStillReportsBranchAndDirtyState() throws {
        // The superproject names an fsmonitor hook and a clean filter for every
        // file; its submodule names a clean filter of its own, which git would
        // run from the `git status` child it starts in the submodule. Every
        // tracked file is stat-dirty, as in a freshly extracted archive, so
        // `git status` hashes each one through its filter. The filters pass
        // content through and write a marker file when they run.
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let markers = temp.appendingPathComponent("markers", isDirectory: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let fsmonitor = try markerScript(temp, named: "fsmonitor", markers: markers)
        let superClean = try markerScript(temp, named: "super-clean", markers: markers)
        let subClean = try markerScript(temp, named: "sub-clean", markers: markers)

        let source = temp.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try runGit(source, ["init", "-q"])
        try Data("sub\n".utf8).write(to: source.appendingPathComponent("s.txt"))
        try Data("* filter=evil2\n".utf8).write(to: source.appendingPathComponent(".gitattributes"))
        try commitAll(source)

        let root = temp.appendingPathComponent("repo", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try runGit(root, ["init", "-q"])
        try runGit(root, ["symbolic-ref", "HEAD", "refs/heads/trunk"])
        try Data("top\n".utf8).write(to: root.appendingPathComponent("top.txt"))
        try Data("doc\n".utf8).write(to: docs.appendingPathComponent("notes.txt"))
        try Data("* filter=evil\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        try commitAll(root)
        try runGit(root, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", source.path, "sub"])
        try commitAll(root)

        try appendConfig(root.appendingPathComponent(".git/config"), """
        [core]
        \tfsmonitor = \(fsmonitor.path)
        [filter "evil"]
        \tclean = \(superClean.path)
        \trequired = true

        """)
        try appendConfig(root.appendingPathComponent(".git/modules/sub/config"), """
        [filter "evil2"]
        \tclean = \(subClean.path)

        """)

        // The fixture is live: plain git status runs all three programs.
        try makeStatDirty(root)
        _ = try gitOutput(docs, ["status", "--porcelain", "-uno"])
        XCTAssertEqual(markerNames(markers), ["fsmonitor", "sub-clean", "super-clean"], "fixture: plain git status should run every program")
        try clearMarkers(markers)

        // From a subdirectory of the superproject: branch, dirty state and
        // the worktree chip context all come from the hardened probe.
        try makeStatDirty(root)
        let clean = probe(docs.path)
        XCTAssertEqual(markerNames(markers), [], "the workspace probe ran a repository-configured program")
        XCTAssertEqual(clean.branch, "trunk")
        XCTAssertFalse(clean.isDirty, "pass-through filters leave every file unchanged, as plain git reports")
        XCTAssertNotNil(clean.gitContext)

        // Real changes still register, in the superproject and in the
        // submodule (plain git reports the latter as ` M sub`).
        try Data("changed\n".utf8).write(to: docs.appendingPathComponent("notes.txt"))
        try makeStatDirty(root)
        XCTAssertTrue(probe(docs.path).isDirty)
        XCTAssertEqual(markerNames(markers), [], "the workspace probe ran a repository-configured program")

        try Data("doc\n".utf8).write(to: docs.appendingPathComponent("notes.txt"))
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("sub/s.txt"))
        XCTAssertEqual(try gitOutput(root, ["status", "--porcelain", "-uno"]), " M sub", "plain git reports the submodule")
        try clearMarkers(markers)
        try makeStatDirty(root)
        XCTAssertTrue(probe(docs.path).isDirty)
        XCTAssertEqual(markerNames(markers), [], "the workspace probe ran a repository-configured program")

        // From inside the submodule, where the resolver also asks git for the
        // superproject's working tree.
        try makeStatDirty(root)
        let insideSubmodule = probe(root.appendingPathComponent("sub").path)
        XCTAssertTrue(insideSubmodule.isDirty)
        XCTAssertNotNil(insideSubmodule.gitContext?.inner, "the resolver sees the superproject")
        XCTAssertEqual(markerNames(markers), [], "the workspace probe ran a repository-configured program")
    }

    func testFilterNameThatCommandLineConfigCannotExpressRefusesTheDirtyCheck() throws {
        // `-c filter.a=b.clean=` would parse as key `filter.a`, so a driver
        // named `a=b` could not be switched off. The probe must not run
        // status at all rather than run it with that filter live.
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let markers = temp.appendingPathComponent("markers", isDirectory: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let clean = try markerScript(temp, named: "clean", markers: markers)
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(root, ["init", "-q"])
        try Data("text\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("* filter=a=b\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        try commitAll(root)
        try appendConfig(root.appendingPathComponent(".git/config"), "[filter \"a=b\"]\n\tclean = \(clean.path)\n")

        try makeStatDirty(root)
        _ = try gitOutput(root, ["status", "--porcelain", "-uno"])
        XCTAssertEqual(markerNames(markers), ["clean"], "fixture: plain git status should run the filter")
        try clearMarkers(markers)

        try makeStatDirty(root)
        XCTAssertNil(UntrustedRepositoryGit.run(
            in: root,
            arguments: ["status", "--porcelain", "-uno"],
            discovery: .enclosingRepository,
            readsFileContent: true
        ))
        XCTAssertEqual(markerNames(markers), [])
    }

    func testDirtyCheckInAnOrdinaryRepositoryMatchesPlainGit() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("repo", isDirectory: true)
        let nested = root.appendingPathComponent("src/app", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try runGit(root, ["init", "-q"])
        try Data("one\n".utf8).write(to: nested.appendingPathComponent("a.txt"))
        try Data("two\n".utf8).write(to: root.appendingPathComponent("b.txt"))
        try commitAll(root)

        try makeStatDirty(root)
        let plainClean = try gitOutput(nested, ["status", "--porcelain", "-uno"])
        XCTAssertEqual(hardenedStatus(nested), plainClean)
        XCTAssertFalse(probe(nested.path).isDirty)

        try Data("changed\n".utf8).write(to: root.appendingPathComponent("b.txt"))
        let plainDirty = try gitOutput(nested, ["status", "--porcelain", "-uno"])
        XCTAssertEqual(plainDirty, " M b.txt")
        XCTAssertEqual(hardenedStatus(nested), plainDirty)
        XCTAssertTrue(probe(nested.path).isDirty)
    }

    func testFilterTheOperatorDefinesGloballyStillRunsWhenTheRepositoryRedefinesIt() throws {
        // Git LFS installs its filter in the operator's global config. A
        // repository that redefines the driver's command locally must get the
        // operator's command back, not its own and not none.
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let markers = temp.appendingPathComponent("markers", isDirectory: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let globalClean = try markerScript(temp, named: "global-clean", markers: markers)
        let localClean = try markerScript(temp, named: "local-clean", markers: markers)
        let globalConfig = temp.appendingPathComponent("global.gitconfig")
        try Data("[filter \"lfsish\"]\n\tclean = \(globalClean.path)\n\trequired = true\n".utf8).write(to: globalConfig)

        let previous = ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"]
        setenv("GIT_CONFIG_GLOBAL", globalConfig.path, 1)
        defer {
            if let previous { setenv("GIT_CONFIG_GLOBAL", previous, 1) } else { unsetenv("GIT_CONFIG_GLOBAL") }
        }

        let root = temp.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(root, ["init", "-q"])
        try Data("payload\n".utf8).write(to: root.appendingPathComponent("a.bin"))
        try Data("*.bin filter=lfsish\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        try commitAll(root)
        try clearMarkers(markers)
        try appendConfig(root.appendingPathComponent(".git/config"), "[filter \"lfsish\"]\n\tclean = \(localClean.path)\n")

        try makeStatDirty(root)
        XCTAssertEqual(hardenedStatus(root), "")
        XCTAssertEqual(markerNames(markers), ["global-clean"])
    }

    // MARK: - Fixture helpers

    /// The probe asserts it is off the main queue, as it is in the app.
    private func probe(_ path: String) -> WorkspaceManager.InitialWorkspaceGitMetadataSnapshot {
        var snapshot: WorkspaceManager.InitialWorkspaceGitMetadataSnapshot?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            snapshot = WorkspaceManager.initialWorkspaceGitMetadataSnapshot(for: path)
            done.signal()
        }
        done.wait()
        return snapshot!
    }

    private func hardenedStatus(_ directory: URL) -> String? {
        UntrustedRepositoryGit.run(
            in: directory,
            arguments: ["status", "--porcelain", "-uno"],
            discovery: .enclosingRepository,
            readsFileContent: true
        ).map { String(decoding: $0.output, as: UTF8.self).trimmingCharacters(in: .newlines) }
    }


    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func markerScript(_ directory: URL, named name: String, markers: URL) throws -> URL {
        let script = directory.appendingPathComponent("\(name).sh")
        let marker = markers.appendingPathComponent(name)
        try Data("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\nexec /bin/cat\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func markerNames(_ markers: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: markers.path)) ?? []).sorted()
    }

    private func clearMarkers(_ markers: URL) throws {
        for name in markerNames(markers) {
            try FileManager.default.removeItem(at: markers.appendingPathComponent(name))
        }
    }

    private var statDirtySteps = 0

    /// Moves every regular file's mtime to a time no earlier call used, so its
    /// stat data no longer matches the index and git must hash it.
    private func makeStatDirty(_ root: URL) throws {
        statDirtySteps += 1
        let later = Date().addingTimeInterval(3_600 + TimeInterval(statDirtySteps * 60))
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == ".git" { enumerator?.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        }
    }

    private func appendConfig(_ file: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func commitAll(_ directory: URL) throws {
        try runGit(directory, ["add", "-A"])
        try runGit(directory, ["-c", "user.name=c11", "-c", "user.email=c11@example.invalid",
                               "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", "fixture"])
    }

    private func runGit(_ directory: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    private func gitOutput(_ directory: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
