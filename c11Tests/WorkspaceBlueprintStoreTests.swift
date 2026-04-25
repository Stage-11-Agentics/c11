import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Filesystem I/O tests for `WorkspaceBlueprintStore`.
/// All writes happen under per-test temp directories.
/// The real home dir and app bundle are never touched.
///
/// Per `CLAUDE.md`, never run locally — CI only.
final class WorkspaceBlueprintStoreTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUp() {
        super.setUp()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-blueprint-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpRoot)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore(override: URL? = nil) -> WorkspaceBlueprintStore {
        WorkspaceBlueprintStore(directoryOverride: override ?? tmpRoot)
    }

    private func sampleBlueprint(name: String = "Test Blueprint") -> WorkspaceBlueprintFile {
        WorkspaceBlueprintFile(
            name: name,
            description: "A test blueprint",
            plan: WorkspaceApplyPlan(
                version: 1,
                workspace: WorkspaceSpec(title: name),
                layout: .pane(.init(surfaceIds: ["a"])),
                surfaces: [SurfaceSpec(id: "a", kind: .terminal)]
            )
        )
    }

    // MARK: - perUserBlueprintURLs

    func testPerUserBlueprintURLsFindsJSONAndMDFiles() throws {
        let overrideDir = tmpRoot.appendingPathComponent("user-override", isDirectory: true)
        try FileManager.default.createDirectory(at: overrideDir, withIntermediateDirectories: true)
        // Write one .json and one .md file.
        let jsonURL = overrideDir.appendingPathComponent("dev.json")
        let mdURL = overrideDir.appendingPathComponent("scratch.md")
        try Data("{}".utf8).write(to: jsonURL)
        try Data("{}".utf8).write(to: mdURL)
        // A non-blueprint extension should not appear.
        let txtURL = overrideDir.appendingPathComponent("notes.txt")
        try Data("{}".utf8).write(to: txtURL)

        let store = WorkspaceBlueprintStore(directoryOverride: overrideDir)
        let found = store.perUserBlueprintURLs()

        XCTAssertEqual(found.count, 2)
        let names = Set(found.map { $0.lastPathComponent })
        XCTAssertTrue(names.contains("dev.json"))
        XCTAssertTrue(names.contains("scratch.md"))
        XCTAssertFalse(names.contains("notes.txt"))
    }

    // MARK: - perRepoBlueprintURLs

    func testPerRepoBlueprintURLsFindsFilesInDirectCWD() throws {
        let cwd = tmpRoot.appendingPathComponent("project", isDirectory: true)
        let blueprintDir = cwd.appendingPathComponent(".cmux/blueprints", isDirectory: true)
        try FileManager.default.createDirectory(at: blueprintDir, withIntermediateDirectories: true)
        let jsonURL = blueprintDir.appendingPathComponent("local.json")
        try Data("{}".utf8).write(to: jsonURL)

        let store = makeStore()
        let found = store.perRepoBlueprintURLs(cwd: cwd)

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.lastPathComponent, "local.json")
    }

    func testPerRepoBlueprintURLsWalksUpParentDirectories() throws {
        // Place .cmux/blueprints at the root of the project, not in cwd.
        let projectRoot = tmpRoot.appendingPathComponent("project", isDirectory: true)
        let blueprintDir = projectRoot.appendingPathComponent(".cmux/blueprints", isDirectory: true)
        try FileManager.default.createDirectory(at: blueprintDir, withIntermediateDirectories: true)
        let jsonURL = blueprintDir.appendingPathComponent("inherited.json")
        try Data("{}".utf8).write(to: jsonURL)

        // cwd is a subdirectory three levels deep.
        let deepCWD = projectRoot
            .appendingPathComponent("src/components/ui", isDirectory: true)
        try FileManager.default.createDirectory(at: deepCWD, withIntermediateDirectories: true)

        let store = makeStore()
        let found = store.perRepoBlueprintURLs(cwd: deepCWD)

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.lastPathComponent, "inherited.json")
    }

    // MARK: - merged

    func testMergedReturnsRepoThenUserThenBuiltIn() throws {
        // Set up three directories under the override root so directoryOverride
        // supplies the user-override dir, a Blueprints/ sub-dir for built-ins,
        // and a separate cwd for repo discovery.
        let userDir = tmpRoot
        let builtInDir = tmpRoot.appendingPathComponent("Blueprints", isDirectory: true)
        try FileManager.default.createDirectory(at: builtInDir, withIntermediateDirectories: true)

        let repoRoot = tmpRoot.appendingPathComponent("repo", isDirectory: true)
        let repoBlueprintDir = repoRoot.appendingPathComponent(".cmux/blueprints", isDirectory: true)
        try FileManager.default.createDirectory(at: repoBlueprintDir, withIntermediateDirectories: true)

        // Write one blueprint per source, with staggered timestamps so order
        // within each group is deterministic.
        let repoFile = sampleBlueprint(name: "Repo Blueprint")
        let userFile = sampleBlueprint(name: "User Blueprint")
        let builtInFile = sampleBlueprint(name: "BuiltIn Blueprint")

        let store = WorkspaceBlueprintStore(directoryOverride: userDir)
        try store.write(repoFile, to: repoBlueprintDir.appendingPathComponent("repo.json"))
        try store.write(userFile, to: userDir.appendingPathComponent("user.json"))
        try store.write(builtInFile, to: builtInDir.appendingPathComponent("builtin.json"))

        let merged = store.merged(cwd: repoRoot)

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].source, .repo,    "repo entries come first")
        XCTAssertEqual(merged[1].source, .user,    "user entries come second")
        XCTAssertEqual(merged[2].source, .builtIn, "built-in entries come last")
    }

    func testMergedSortsByModifiedAtDescWithinEachGroup() throws {
        let userDir = tmpRoot
        let store = WorkspaceBlueprintStore(directoryOverride: userDir)

        // Write two user blueprints in sequence so their mtime will differ.
        let older = sampleBlueprint(name: "Older")
        let newer = sampleBlueprint(name: "Newer")
        let olderURL = userDir.appendingPathComponent("older.json")
        let newerURL = userDir.appendingPathComponent("newer.json")
        try store.write(older, to: olderURL)
        // Small sleep to guarantee mtime difference on real filesystems.
        Thread.sleep(forTimeInterval: 0.05)
        try store.write(newer, to: newerURL)

        let merged = store.merged(cwd: nil)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].name, "Newer",  "most-recently-modified file is first")
        XCTAssertEqual(merged[1].name, "Older")
    }

    // MARK: - read

    func testReadCorrectlyDecodesABlueprintJSONFile() throws {
        let store = makeStore()
        let blueprint = sampleBlueprint(name: "Read Me")
        let url = tmpRoot.appendingPathComponent("read-me.json")
        try store.write(blueprint, to: url)

        let read = try store.read(url: url)
        XCTAssertEqual(read.name, "Read Me")
        XCTAssertEqual(read.description, "A test blueprint")
        XCTAssertEqual(read.version, 1)
        XCTAssertEqual(read.plan.surfaces.count, 1)
    }

    // MARK: - write

    func testWriteCreatesFileAtomicallyAndIsReadableAfterWrite() throws {
        let store = makeStore()
        let blueprint = sampleBlueprint(name: "Atomic Write")
        let url = tmpRoot.appendingPathComponent("subdir/atomic.json")

        try store.write(blueprint, to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "file must exist after write")
        let readBack = try store.read(url: url)
        XCTAssertEqual(readBack, blueprint)
    }

    func testWriteCreatesIntermediateDirectories() throws {
        let store = makeStore()
        let blueprint = sampleBlueprint()
        let deepURL = tmpRoot
            .appendingPathComponent("a/b/c/d.json")

        try store.write(blueprint, to: deepURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: deepURL.path))
    }

    // MARK: - .md extension

    func testMDExtensionFilesAreAcceptedByPerUserBlueprintURLs() throws {
        let overrideDir = tmpRoot.appendingPathComponent("md-test", isDirectory: true)
        try FileManager.default.createDirectory(at: overrideDir, withIntermediateDirectories: true)

        // Write valid blueprint JSON with a .md extension.
        let blueprint = sampleBlueprint(name: "Markdown Extension")
        let mdStore = WorkspaceBlueprintStore(directoryOverride: overrideDir)
        let mdURL = overrideDir.appendingPathComponent("blueprint.md")
        try mdStore.write(blueprint, to: mdURL)

        let found = mdStore.perUserBlueprintURLs()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.pathExtension, "md")

        // The .md file should also appear in merged() with source .user.
        let merged = mdStore.merged(cwd: nil)
        XCTAssertEqual(merged.count, 1)
        // For .md files the store uses the filename stem as the name.
        XCTAssertEqual(merged.first?.name, "blueprint")
        XCTAssertEqual(merged.first?.source, .user)
    }
}
