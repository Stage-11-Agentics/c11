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
                surfaces: [PanelSpec(id: "a", kind: .terminal)]
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
        let userDir: URL = tmpRoot
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
        let userDir: URL = tmpRoot
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

    // MARK: - Layout reference resolution

    func testStarterReferencesIgnoreRepoAndUserShadows() throws {
        let store = makeStore()
        let cwd = tmpRoot.appendingPathComponent("repo/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let repoURL = tmpRoot.appendingPathComponent("repo/.c11/blueprints/layout.json")
        var shadow = sampleBlueprint(name: "basic-terminal")
        shadow.plan.surfaces[0].command = "echo repo-blueprint-command"
        shadow.plan.surfaces[0].submitCommand = true
        try store.write(shadow, to: repoURL)
        try store.write(shadow, to: tmpRoot.appendingPathComponent("user-shadow.json"))

        let references = [
            "starter:one-column": "basic-terminal", "single": "basic-terminal", "one-column": "basic-terminal",
            "basic-terminal": "basic-terminal", "starter:two-columns": "side-by-side",
            "two-columns": "side-by-side", "side-by-side": "side-by-side",
            "starter:quad": "quad-terminal", "quad": "quad-terminal", "quad-terminal": "quad-terminal",
            "starter:two-by-three": "two-by-three", "two-by-three": "two-by-three", "agent-room": "agent-room",
        ]
        for name in Set(references.values) {
            try store.write(
                sampleBlueprint(name: name),
                to: tmpRoot.appendingPathComponent("Blueprints/\(name).json")
            )
        }
        var agentShadow = shadow
        agentShadow.name = "agent-room"
        try store.write(agentShadow, to: tmpRoot.appendingPathComponent("repo/.c11/blueprints/agent.json"))
        try store.write(agentShadow, to: tmpRoot.appendingPathComponent("agent-shadow.json"))

        let first = try XCTUnwrap(store.merged(cwd: cwd).first { $0.name == "basic-terminal" })
        XCTAssertEqual(first.source, .repo, "merged listing retains the repo-first picker order")
        XCTAssertEqual(try store.read(url: URL(fileURLWithPath: first.url)), shadow)
        let attackPlan = try store.read(url: URL(fileURLWithPath: first.url)).plan
        XCTAssertNotNil(attackPlan.surfaces.first?.command)
        XCTAssertEqual(attackPlan.surfaces.first?.submitCommand, true)

        let builtIn = try XCTUnwrap(store.builtInEntry(named: "basic-terminal"))
        XCTAssertEqual(builtIn.source, .builtIn)
        XCTAssertEqual(try store.read(url: URL(fileURLWithPath: builtIn.url)), sampleBlueprint(name: "basic-terminal"))
        for (reference, name) in references {
            let resolved = try XCTUnwrap(store.resolveLayoutReference(reference, cwd: cwd), reference)
            XCTAssertEqual(resolved.source, .builtIn, reference)
            XCTAssertEqual(resolved.name, name, reference)
            let plan = try store.read(url: URL(fileURLWithPath: resolved.url)).plan
            XCTAssertEqual(plan.surfaces.count, 1, reference)
            XCTAssertEqual(plan.surfaces.first?.kind, .terminal, reference)
            XCTAssertNil(plan.surfaces.first?.command, reference)
            XCTAssertEqual(plan.surfaces.first?.submitCommand, false, reference)
        }

        let explicit = try XCTUnwrap(store.resolveLayoutReference("saved:\(first.url)", cwd: cwd))
        XCTAssertEqual(explicit.source, .repo)
        XCTAssertEqual(explicit.url, first.url)
        XCTAssertEqual(try store.read(url: URL(fileURLWithPath: explicit.url)), shadow)
    }

    func testLayoutNamesPreferUserAndKeepRepoOnlyBlueprints() throws {
        let store = makeStore()
        let cwd = tmpRoot.appendingPathComponent("repo/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let repoOnlyURL = tmpRoot.appendingPathComponent("repo/.c11/blueprints/repo-only.json")
        let repoSharedURL = tmpRoot.appendingPathComponent("repo/.c11/blueprints/shared.json")
        let userURL = tmpRoot.appendingPathComponent("shared.json")
        try store.write(sampleBlueprint(name: "repo-only"), to: repoOnlyURL)
        try store.write(sampleBlueprint(name: "shared-layout"), to: repoSharedURL)
        try store.write(sampleBlueprint(name: "shared-layout"), to: userURL)

        let repoEntry = try XCTUnwrap(store.merged(cwd: cwd).first { $0.name == "repo-only" })
        for reference in ["repo-only", "saved:\(repoEntry.url)"] {
            let resolved = try XCTUnwrap(store.resolveLayoutReference(reference, cwd: cwd))
            XCTAssertEqual(resolved.source, .repo)
            XCTAssertEqual(resolved, repoEntry)
            XCTAssertEqual(try store.read(url: URL(fileURLWithPath: resolved.url)), sampleBlueprint(name: "repo-only"))
        }
        let shared = try XCTUnwrap(store.resolveLayoutReference("shared-layout", cwd: cwd))
        XCTAssertEqual(shared.source, .user)
        let userEntry = try XCTUnwrap(store.merged(cwd: cwd).first { $0.name == "shared-layout" && $0.source == .user })
        XCTAssertEqual(shared, userEntry)
        XCTAssertNil(store.resolveLayoutReference("missing-layout", cwd: cwd))
    }

    func testMissingBuiltInStarterNeverFallsBackToRepoOrUser() throws {
        let store = makeStore()
        let cwd = tmpRoot.appendingPathComponent("repo", isDirectory: true)
        try store.write(sampleBlueprint(name: "basic-terminal"), to: cwd.appendingPathComponent(".c11/blueprints/layout.json"))
        try store.write(sampleBlueprint(name: "basic-terminal"), to: tmpRoot.appendingPathComponent("user.json"))

        XCTAssertNil(store.builtInEntry(named: "basic-terminal"))
        for reference in ["starter:one-column", "single", "one-column", "basic-terminal"] {
            XCTAssertNil(store.resolveLayoutReference(reference, cwd: cwd), reference)
        }
    }

    func testReservedReferencesNormalizeCaseAndWhitespace() throws {
        let store = makeStore()
        let cwd = tmpRoot.appendingPathComponent("repo", isDirectory: true)
        for name in ["basic-terminal", "quad-terminal", "agent-room"] {
            try store.write(sampleBlueprint(name: name), to: tmpRoot.appendingPathComponent("Blueprints/\(name).json"))
        }
        for name in ["Single", "Quad", "Basic-Terminal", "AGENT-ROOM", "starter:unknown", "saved:missing"] {
            var shadow = sampleBlueprint(name: name)
            shadow.plan.surfaces[0].command = "echo shadow"
            shadow.plan.surfaces[0].submitCommand = true
            try store.write(shadow, to: cwd.appendingPathComponent(".c11/blueprints/\(name).json"))
        }
        for (reference, name) in [" Single ": "basic-terminal", "Quad": "quad-terminal",
                                  "quad \n": "quad-terminal", " Basic-Terminal ": "basic-terminal",
                                  "STARTER:QUAD": "quad-terminal", "AGENT-ROOM": "agent-room"] {
            let entry = try XCTUnwrap(store.resolveLayoutReference(reference, cwd: cwd), reference)
            XCTAssertEqual(entry.source, .builtIn, reference)
            XCTAssertEqual(entry.name, name, reference)
            XCTAssertTrue(store.isReservedLayoutReference(reference), reference)
            XCTAssertNil(try store.read(url: URL(fileURLWithPath: entry.url)).plan.surfaces.first?.command)
        }
        for reference in ["starter:unknown", " STARTER:missing.json ", "saved:missing", "SAVED:/missing.json"] {
            XCTAssertTrue(store.isReservedLayoutReference(reference), reference)
            XCTAssertNil(store.resolveLayoutReference(reference, cwd: cwd), reference)
        }
        XCTAssertFalse(store.isReservedLayoutReference("./quad"))
        XCTAssertFalse(store.isReservedLayoutReference("repo-only"))
    }

    func testOnlyExplicitPathShapesAllowFileFallback() {
        for reference in ["./quad", "/tmp/quad", "~/quad", ".quad", "layout.JSON", "layout.MD", "repo/layout"] {
            XCTAssertTrue(WorkspaceBlueprintStore.looksLikeLayoutPath(reference), reference)
        }
        for reference in ["quad", "unknown", "single ", "agent-room"] {
            XCTAssertFalse(WorkspaceBlueprintStore.looksLikeLayoutPath(reference), reference)
        }
    }

    func testStoredDefaultsAcceptOnlyKnownStarterIds() {
        for stored in [nil, "saved:/tmp/repo.json", "/tmp/repo.json", "repo-only", "quad", "starter:unknown"] {
            XCTAssertEqual(WorkspaceBlueprintStore.defaultLayoutReference(explicit: nil, stored: stored), "starter:one-column")
        }
        for stored in ["starter:one-column", "starter:two-columns", "starter:quad", "starter:two-by-three"] {
            XCTAssertEqual(WorkspaceBlueprintStore.defaultLayoutReference(explicit: nil, stored: stored), stored)
        }
        XCTAssertEqual(WorkspaceBlueprintStore.defaultLayoutReference(explicit: "saved:/tmp/repo.json", stored: "starter:quad"), "saved:/tmp/repo.json")
        XCTAssertEqual(WorkspaceBlueprintStore.defaultLayoutReference(explicit: "Single", stored: "starter:quad"), "Single")
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

        // Write a real markdown blueprint via the store's .md write path.
        let blueprint = sampleBlueprint(name: "Markdown Extension")
        let mdStore = WorkspaceBlueprintStore(directoryOverride: overrideDir)
        let mdURL = overrideDir.appendingPathComponent("blueprint.md")
        try mdStore.write(blueprint, to: mdURL)

        let found = mdStore.perUserBlueprintURLs()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.pathExtension, "md")

        // The .md file should appear in merged() with source .user. The name
        // now comes from the frontmatter `title:` populated on serialise.
        let merged = mdStore.merged(cwd: nil)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.name, "Markdown Extension")
        XCTAssertEqual(merged.first?.source, .user)
    }

    // MARK: - Per-repo dual-path discovery

    func testPerRepoBlueprintURLsCollectsBothC11AndCmuxDirsAtSameAncestor() throws {
        let projectRoot = tmpRoot.appendingPathComponent("project", isDirectory: true)
        let c11Dir = projectRoot.appendingPathComponent(".c11/blueprints", isDirectory: true)
        let cmuxDir = projectRoot.appendingPathComponent(".cmux/blueprints", isDirectory: true)
        try FileManager.default.createDirectory(at: c11Dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cmuxDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: c11Dir.appendingPathComponent("modern.json"))
        try Data("{}".utf8).write(to: cmuxDir.appendingPathComponent("legacy.json"))

        let store = makeStore()
        let found = store.perRepoBlueprintURLs(cwd: projectRoot)

        XCTAssertEqual(found.count, 2)
        // .c11 entries must lead the list (so the picker prefers the
        // canonically-named directory when both exist).
        XCTAssertEqual(found.first?.lastPathComponent, "modern.json")
        XCTAssertTrue(found.contains(where: { $0.lastPathComponent == "legacy.json" }))
    }

    func testPerRepoBlueprintURLsFindsC11OnlyWhenCmuxAbsent() throws {
        let projectRoot = tmpRoot.appendingPathComponent("project", isDirectory: true)
        let c11Dir = projectRoot.appendingPathComponent(".c11/blueprints", isDirectory: true)
        try FileManager.default.createDirectory(at: c11Dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: c11Dir.appendingPathComponent("only.json"))

        let store = makeStore()
        let found = store.perRepoBlueprintURLs(cwd: projectRoot)

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.lastPathComponent, "only.json")
    }

    func testMDExtensionRoundTripsThroughStoreReadWrite() throws {
        let store = makeStore()
        let blueprint = WorkspaceBlueprintFile(
            name: "MD Round Trip",
            description: "End-to-end through the store",
            plan: WorkspaceApplyPlan(
                version: 1,
                workspace: WorkspaceSpec(title: "MD Round Trip", customColor: "#9D8048"),
                layout: .pane(.init(surfaceIds: ["a"])),
                surfaces: [PanelSpec(id: "a", kind: .terminal, title: "shell")]
            )
        )
        let url = tmpRoot.appendingPathComponent("md-roundtrip.md")
        try store.write(blueprint, to: url)
        let readBack = try store.read(url: url)
        XCTAssertEqual(readBack.name, blueprint.name)
        XCTAssertEqual(readBack.description, blueprint.description)
        XCTAssertEqual(readBack.plan.workspace.title, blueprint.plan.workspace.title)
        XCTAssertEqual(readBack.plan.workspace.customColor, blueprint.plan.workspace.customColor)
        XCTAssertEqual(readBack.plan.surfaces.count, 1)
        XCTAssertEqual(readBack.plan.surfaces.first?.kind, .terminal)
        XCTAssertEqual(readBack.plan.surfaces.first?.title, "shell")
    }

    // MARK: - C11-337 panel keys

    func testReadAcceptsLegacySurfaceKeyJSONAndWriteEmitsPanelKeys() throws {
        let store = makeStore()
        let legacyURL = tmpRoot.appendingPathComponent("legacy.json")
        try Data("""
        {
          "version": 1,
          "name": "Legacy Keys",
          "plan": {
            "version": 1,
            "workspace": {},
            "layout": {"type": "pane", "pane": {"surfaceIds": ["a", "b"]}},
            "surfaces": [{"id": "a", "kind": "terminal"}, {"id": "b", "kind": "terminal"}]
          }
        }
        """.utf8).write(to: legacyURL)

        let legacy = try store.read(url: legacyURL)
        XCTAssertEqual(legacy.plan.surfaces.map(\.id), ["a", "b"])
        XCTAssertEqual(legacy.plan.layout, .pane(.init(surfaceIds: ["a", "b"])))

        let rewrittenURL = tmpRoot.appendingPathComponent("rewritten.json")
        try store.write(legacy, to: rewrittenURL)
        let written = try XCTUnwrap(String(data: Data(contentsOf: rewrittenURL), encoding: .utf8))
        XCTAssertTrue(written.contains("\"panels\""))
        XCTAssertTrue(written.contains("\"panelIds\""))
        XCTAssertFalse(written.contains("\"surfaces\""))
        XCTAssertFalse(written.contains("\"surfaceIds\""))
        XCTAssertEqual(try store.read(url: rewrittenURL), legacy)
    }

    func testReadAcceptsLegacyTabsMarkdownAndWriteEmitsPanels() throws {
        let store = makeStore()
        let legacyURL = tmpRoot.appendingPathComponent("legacy.md")
        try Data("""
        ---
        title: Legacy Tabs
        ---

        ## Layout

        ```yaml
        layout:
          - tabs:
              - id: one
                type: terminal
              - id: two
                type: terminal
        ```
        """.utf8).write(to: legacyURL)

        let legacy = try store.read(url: legacyURL)
        XCTAssertEqual(legacy.plan.layout, .pane(.init(surfaceIds: ["one", "two"])))

        let rewrittenURL = tmpRoot.appendingPathComponent("rewritten.md")
        try store.write(legacy, to: rewrittenURL)
        let written = try XCTUnwrap(String(data: Data(contentsOf: rewrittenURL), encoding: .utf8))
        XCTAssertTrue(written.contains("panels:"))
        XCTAssertFalse(written.contains("tabs:"))
        XCTAssertEqual(try store.read(url: rewrittenURL).plan, legacy.plan)
    }

    func testBundledBlueprintsDecodeAndValidate() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        guard FileManager.default.fileExists(
            atPath: resources.appendingPathComponent("Blueprints").path
        ) else {
            throw XCTSkip("Resources/Blueprints is not present")
        }
        let store = WorkspaceBlueprintStore(directoryOverride: resources)
        let urls = store.builtInBlueprintURLs().filter { $0.pathExtension == "json" }
        XCTAssertFalse(urls.isEmpty, "expected bundled blueprints under \(resources.path)")
        for url in urls {
            let file = try store.read(url: url)
            XCTAssertFalse(file.plan.surfaces.isEmpty, url.lastPathComponent)
            XCTAssertNil(WorkspaceLayoutExecutor.validate(plan: file.plan), url.lastPathComponent)
        }
    }

}
