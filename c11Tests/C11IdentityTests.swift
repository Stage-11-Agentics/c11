import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// c11-2.0:begin-keep (2.0 is c11; the retired c11h line is the foreign one here)

/// c11 must run beside a live c11h without reading, writing, or binding its state.
final class C11IdentityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testEnsureMigratedLeavesLegacyTreesAndResolversStayUnderC11() throws {
        let fm = FileManager.default
        let c11h = root.appendingPathComponent("c11h", isDirectory: true)
        let cmux = root.appendingPathComponent("cmux", isDirectory: true)
        try fm.createDirectory(at: c11h, withIntermediateDirectories: true)
        try fm.createDirectory(at: cmux, withIntermediateDirectories: true)
        let marker = c11h.appendingPathComponent("marker.txt")
        try Data("c11h-bytes".utf8).write(to: marker)
        try Data("cmux-bytes".utf8).write(to: cmux.appendingPathComponent("marker.txt"))
        let legacyLink = root.appendingPathComponent("c11mux")
        try fm.createSymbolicLink(at: legacyLink, withDestinationURL: c11h)
        let crumb = root.appendingPathComponent("c11h-last-socket-path")
        try Data("/tmp/c11h.sock\n".utf8).write(to: crumb)

        StateDirectoryMigration.ensureMigrated(fileManager: fm, appSupport: root)

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "c11h-bytes")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: legacyLink.path), c11h.path)
        XCTAssertEqual(try String(contentsOf: crumb, encoding: .utf8), "/tmp/c11h.sock\n")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("c11").path))

        let snapshot = try XCTUnwrap(
            SessionPersistenceStore.defaultSnapshotFileURL(
                bundleIdentifier: C11Identity.releaseBundleIdentifier,
                appSupportDirectory: root
            )
        )
        XCTAssertTrue(snapshot.path.contains("/c11/session-com.stage11.c11.json"))
        XCTAssertFalse(snapshot.path.contains("/c11h/"))

        let password = try XCTUnwrap(
            SocketControlPasswordStore.defaultPasswordFileURL(appSupportDirectory: root)
        )
        XCTAssertTrue(password.path.contains("/c11/socket-control-password"))
        XCTAssertFalse(password.path.contains("/c11h/"))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("c11").path))
    }

    func testLegacyReadersAreNeverCalled() {
        var domainReads: [String] = []
        let imported = AppDelegate.importedLegacyPreferenceCount { domain in
            domainReads.append(domain)
            return ["cmuxWelcomeShown": true]
        }
        XCTAssertEqual(imported, 0)
        XCTAssertTrue(domainReads.isEmpty)

        var lookups = 0
        var deletes = 0
        SocketControlPasswordStore.migrateLegacyKeychainPasswordIfNeeded(
            defaults: UserDefaults(),
            fileURL: root.appendingPathComponent("password"),
            loadLegacyPassword: {
                lookups += 1
                return "legacy-secret"
            },
            deleteLegacyPassword: {
                deletes += 1
                return true
            }
        )
        XCTAssertEqual(lookups, 0)
        XCTAssertEqual(deletes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("password").path))
        for bundle in ["com.stage11.c11h", "com.stage11.c11", "", "com.stage11.c11h.debug"] {
            XCTAssertTrue(AppDelegate.legacyMigrationShouldSkip(bundleId: bundle, env: [:]))
            XCTAssertTrue(AppDelegate.legacyMigrationShouldSkip(
                bundleId: bundle,
                env: ["CMUX_DISABLE_LEGACY_MIGRATION": "0"]
            ))
        }
    }

    func testImplicitDiscoveryIgnoresC11hAndCmuxSockets() {
        let c11Default = "/tmp/c11.sock"
        let foreign = C11Identity.ImplicitSocketDiscovery(
            environment: [
                "C11_SOCKET_PATH": "/tmp/c11h.sock",
                "CMUX_SOCKET_PATH": "/tmp/cmux.sock",
            ],
            defaultPath: c11Default,
            socketListings: [
                "/tmp": ["c11h.sock", "cmux.sock", "c11h-debug.sock", "c11-debug-tag.sock"],
            ],
            breadcrumbFiles: [
                "/tmp/c11h-last-socket-path": "/tmp/c11h.sock",
                "/tmp/cmux-last-socket-path": "/tmp/cmux.sock",
            ],
            connectable: ["/tmp/c11h.sock", "/tmp/cmux.sock", "/tmp/c11h-debug.sock"],
            existingSocketFiles: ["/tmp/c11h.sock", "/tmp/cmux.sock", "/tmp/c11h-debug.sock"]
        )
        XCTAssertEqual(C11Identity.resolveImplicitSocket(foreign), c11Default)
        XCTAssertFalse(C11Identity.implicitSocketCandidates(foreign).contains("/tmp/c11h.sock"))

        var onlyTagged = foreign
        onlyTagged.connectable = ["/tmp/c11-debug-tag.sock"]
        XCTAssertEqual(C11Identity.resolveImplicitSocket(onlyTagged), "/tmp/c11-debug-tag.sock")
    }

    /// C11H-282: what a socket variable names decides what the CLI does with it.
    func testSocketOverrideKindSeparatesOwnOtherProductsAndForeign() {
        let home = "/Users/someone/Library/Application Support"
        let cases: [(String, C11Identity.SocketOverrideKind)] = [
            ("\(home)/c11/c11.sock", .own),
            ("/tmp/c11.sock", .own),
            ("/private/tmp/c11-debug-tag.sock", .own),
            ("/tmp/c11.staging.sock", .own),
            ("\(home)/c11h/c11h.sock", .otherProduct),
            ("\(home)/cmux/cmux.sock", .otherProduct),
            ("/tmp/c11h.sock", .otherProduct),
            ("/tmp/c11h-debug-tag.sock", .otherProduct),
            ("/private/tmp/cmux-nightly.sock", .otherProduct),
            ("/tmp/cmux.sock", .otherProduct),
            ("/tmp/mine.sock", .foreign),
            ("/tmp/c11hx.sock", .foreign),
            ("/tmp/cmuxer.sock", .foreign),
            ("/tmp/sub/c11h.sock", .foreign),
            ("\(home)/c11hx/c11.sock", .foreign),
            ("/Users/someone/.local/share/c11/relay/c11-s1/no-socket", .foreign),
            ("/var/run/docker.sock", .foreign),
        ]
        for (path, kind) in cases {
            XCTAssertEqual(C11Identity.socketOverrideKind(path), kind, path)
        }
    }

    func testForeignSocketOverrideIsNotABind() {
        let foreignPaths = [
            "/tmp/c11h.sock",
            "/tmp/c11h-debug.sock",
            "/tmp/cmux.sock",
        ]
        for foreign in foreignPaths {
            for key in ["C11_SOCKET_PATH", "CMUX_SOCKET_PATH"] {
                let path = SocketControlSettings.socketPath(
                    environment: [
                        key: foreign,
                        "C11_ALLOW_SOCKET_OVERRIDE": "1",
                    ],
                    bundleIdentifier: C11Identity.releaseBundleIdentifier,
                    isDebugBuild: false,
                    probeStableDefaultPathEntry: { _ in .missing }
                )
                XCTAssertEqual(path, SocketControlSettings.stableDefaultSocketPath, "\(key)=\(foreign)")
                XCTAssertNotEqual(path, foreign)
            }
        }

        let own = "/tmp/c11-debug-c11-b.sock"
        let kept = SocketControlSettings.socketPath(
            environment: [
                "C11_SOCKET_PATH": own,
                "C11_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.stage11.c11.debug.c11.b",
            isDebugBuild: true,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertEqual(kept, own)
    }

    func testJournalAndHealthStayInsideTheC11Family() throws {
        XCTAssertThrowsError(try JournalStorageLayout.resolve(
            bundleID: "com.stage11.c11h",
            supportDirectory: root
        ))
        let layout = try JournalStorageLayout.resolve(
            bundleID: C11Identity.releaseBundleIdentifier,
            supportDirectory: root
        )
        XCTAssertTrue(layout.directory.path.contains("/c11/journal/com.stage11.c11"))
        XCTAssertFalse(layout.directory.path.contains("/Application Support/c11h/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.directory.path))

        let fm = FileManager.default
        let c11hEnvelope = root.appendingPathComponent(
            "Library/Caches/com.stage11.c11h/io.sentry/envelopes/c11h.json"
        )
        let c11Envelope = root.appendingPathComponent(
            "Library/Caches/com.stage11.c11/io.sentry/envelopes/c11.json"
        )
        let c11hMetric = root.appendingPathComponent("Library/Logs/c11h/metrickit/2026-01-01T00-00-00.000Z-diagnostic.json")
        let c11Metric = root.appendingPathComponent("Library/Logs/c11/metrickit/2026-01-01T00-00-00.000Z-diagnostic.json")
        for url in [c11hEnvelope, c11Envelope, c11hMetric, c11Metric] {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url)
        }

        let resolved = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let sentry = scanSentryQueued(home: root.path, since: .distantPast)
        XCTAssertEqual(sentry.map { resolved($0.path) }, [resolved(c11Envelope.path)])
        let metrics = scanMetricKit(home: root.path, since: .distantPast)
        XCTAssertEqual(metrics.map { resolved($0.path) }, [resolved(c11Metric.path)])
    }

    /// C11H-269: a `c11h` folder c11 did not stamp stays byte for byte while c11 installs and
    /// removes its own skills (a stamp c11 cannot decode is not c11's).
    func testSkillInstallAndRemoveLeaveAnUnstampedC11hFolderAlone() throws {
        let fm = FileManager.default
        let sourceDir = root.appendingPathComponent("source", isDirectory: true)
        let bundled = sourceDir.appendingPathComponent("c11", isDirectory: true)
        try fm.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data("---\nname: c11\nversion: 1\n---\nbody\n".utf8).write(to: bundled.appendingPathComponent("SKILL.md"))
        try Data("{\"installable\":[\"c11\"]}\n".utf8).write(to: sourceDir.appendingPathComponent("MANIFEST.json"))
        let dest = SkillInstallerTarget.claude.skillsDir(home: root)
            .appendingPathComponent("c11h", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let skill = dest.appendingPathComponent("SKILL.md")
        let stamp = dest.appendingPathComponent(SkillInstaller.manifestFilename)
        try Data("managed-bytes".utf8).write(to: skill)
        try Data("{\"stamp\":1}\n".utf8).write(to: stamp)
        let beforeSkill = try Data(contentsOf: skill)
        let beforeStamp = try Data(contentsOf: stamp)

        let installed = try SkillInstaller.c11Install(target: .claude, home: root, sourceDir: sourceDir, force: true)
        XCTAssertEqual(installed.installed, ["c11"])
        XCTAssertEqual(installed.retired, [])
        let removed = try SkillInstaller.c11Remove(target: .claude, home: root, sourceDir: sourceDir, force: true)
        XCTAssertEqual(removed.removed, ["c11"])
        XCTAssertEqual(removed.retired, [])
        XCTAssertEqual(try Data(contentsOf: skill), beforeSkill)
        XCTAssertEqual(try Data(contentsOf: stamp), beforeStamp)
    }

    func testCLISymlinkClaimsOnlyC11App() throws {
        XCTAssertFalse(C11Identity.claimsCLISymlink(
            rawTargetPath: "/Applications/c11h.app/Contents/Resources/bin/c11"
        ))
        XCTAssertTrue(C11Identity.claimsCLISymlink(
            rawTargetPath: "/Applications/c11.app/Contents/Resources/bin/c11"
        ))

        let fm = FileManager.default
        let source = root.appendingPathComponent("live/c11.app/Contents/Resources/bin/c11")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: source)
        let destination = root.appendingPathComponent("usr/local/bin/c11")
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staleC11H = root.appendingPathComponent("old/c11h.app/Contents/Resources/bin/c11")
        try fm.createSymbolicLink(at: destination, withDestinationURL: staleC11H)
        let installer = CmuxCLIPathInstaller(
            fileManager: fm,
            destinationURL: destination,
            bundledCLIURLProvider: { source },
            expectedBundledCLIPath: source.path,
            privilegedInstaller: { _, _ in XCTFail("c11h.app must not be replaced") }
        )
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: destination.path), staleC11H.path)

        try fm.removeItem(at: destination)
        let staleC11 = root.appendingPathComponent("old/c11.app/Contents/Resources/bin/c11")
        try fm.createSymbolicLink(at: destination, withDestinationURL: staleC11)
        let claim = CmuxCLIPathInstaller(
            fileManager: fm,
            destinationURL: destination,
            bundledCLIURLProvider: { source },
            expectedBundledCLIPath: source.path,
            privilegedInstaller: { _, _ in XCTFail("the dangling c11 link is claimable without privileges") }
        )
        _ = try claim.install()
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: destination.path), source.path)
    }

    func testSparkleStartsOnC11sFeedForEveryC11Bundle() {
        let feed = "https://github.com/Stage-11-Agentics/c11/releases/latest/download/appcast.xml"
        for bundle in [
            "com.stage11.c11",
            "com.stage11.c11.debug",
            "com.stage11.c11.debug.c11.b",
        ] {
            XCTAssertTrue(C11Identity.shouldStartSparkleUpdater(bundleIdentifier: bundle, feedURL: feed))
            XCTAssertFalse(C11Identity.shouldStartSparkleUpdater(bundleIdentifier: bundle, feedURL: " "))
            let resolved = UpdateFeedResolver.resolvedFeedURLString(infoFeedURL: feed, bundleIdentifier: bundle)
            XCTAssertEqual(resolved.url, feed)
            XCTAssertFalse(resolved.usedFallback)
        }
    }

    func testBrowserHistoryNamespaceStaysOffC11H() {
        XCTAssertEqual(
            C11Identity.browserHistoryNamespace(for: "com.stage11.c11.debug.c11.b"),
            "com.stage11.c11.debug"
        )
        XCTAssertEqual(
            C11Identity.browserHistoryNamespace(for: "com.stage11.c11.debug"),
            "com.stage11.c11.debug"
        )
        XCTAssertEqual(
            C11Identity.browserHistoryNamespace(for: "com.stage11.c11.staging.rel"),
            "com.stage11.c11.staging"
        )
        XCTAssertEqual(
            C11Identity.browserHistoryNamespace(for: "com.stage11.c11"),
            "com.stage11.c11"
        )
        for foreign in ["com.stage11.c11h", "com.stage11.c11h.debug.tag", "com.stage11.c11h.staging", "cmux", ""] {
            XCTAssertEqual(
                C11Identity.browserHistoryNamespace(for: foreign),
                "com.stage11.c11",
                foreign
            )
        }
    }

    func testPortDefaultIs29100OnAFreshSuite() {
        let name = "c11-port-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(C11Identity.portBase(defaults: defaults), 29100)
        defaults.set(0, forKey: C11Identity.portBaseDefaultsKey)
        XCTAssertEqual(C11Identity.portBase(defaults: defaults), 29100)
        defaults.set(29250, forKey: C11Identity.portBaseDefaultsKey)
        XCTAssertEqual(C11Identity.portBase(defaults: defaults), 29250)
    }

    func testProcessOwnershipRejectsC11hAndCmux() {
        let yes: [(String, String)] = [
            ("com.stage11.c11", "/Applications/c11.app/Contents/MacOS/c11"),
            ("com.stage11.c11.debug.c11.b", "/tmp/build/c11 DEV c11-b.app/Contents/MacOS/c11"),
            ("com.stage11.c11.staging", "/Applications/c11 STAGING.app/Contents/MacOS/c11"),
        ]
        let no: [(String, String)] = [
            ("com.stage11.c11h", "/Applications/c11h.app/Contents/MacOS/c11h"),
            ("com.stage11.c11h.debug", "/Applications/c11h DEV.app/Contents/MacOS/c11h"),
            ("com.stage11.c11", "/Applications/c11h.app/Contents/MacOS/c11h"),
            ("com.stage11.c11", "/Applications/c11h DEV.app/Contents/MacOS/c11h"),
            ("com.stage11.c11", "/Applications/cmux.app/Contents/MacOS/cmux"),
            ("com.stage11.c11", "/usr/local/bin/c11"),
        ]
        for (bundle, path) in yes {
            XCTAssertTrue(C11Identity.ownsProcess(bundleIdentifier: bundle, executablePath: path), path)
        }
        for (bundle, path) in no {
            XCTAssertFalse(C11Identity.ownsProcess(bundleIdentifier: bundle, executablePath: path), path)
        }
    }

    func testDefaultStateRootsStayUnderC11() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let launchPrompts = LaunchPromptStore.defaultRootDirectory(applicationSupport: support)
        let shutdown = try XCTUnwrap(ShutdownSentinel.defaultDirectory(home: home))
        let snapshots = WorkspaceSnapshotStore.defaultDirectory(home: home)
        let legacySnapshots = WorkspaceSnapshotStore.defaultLegacyDirectory(home: home)
        let hook = C11Identity.claudeHookStateFile(home: home)
        let agents = C11Identity.userAgentsDirectory(home: home)
        let blueprints = C11Identity.userBlueprintsDirectory(home: home)
        let themes = ThemeManager.userThemesDirectory()

        XCTAssertEqual(snapshots.path, legacySnapshots.path)
        for path in [launchPrompts.path, shutdown.path, snapshots.path, hook.path, agents.path, blueprints.path, themes.path] {
            assertC11IdentityPath(path)
        }
        XCTAssertEqual(themes.lastPathComponent, "themes")
        XCTAssertEqual(themes.deletingLastPathComponent().lastPathComponent, C11Identity.stateDirectoryName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchPrompts.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shutdown.path))
    }

    func testSnapshotListIgnoresC11hAndCmuxHomes() throws {
        let fm = FileManager.default
        let home = root.appendingPathComponent("home", isDirectory: true)
        let own = WorkspaceSnapshotStore.defaultDirectory(home: home)
        let c11h = home.appendingPathComponent(".c11h-snapshots", isDirectory: true)
        let cmux = home.appendingPathComponent(".cmux-snapshots", isDirectory: true)
        for dir in [own, c11h, cmux] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("{".utf8).write(to: own.appendingPathComponent("own-snap.json"))
        try Data("{".utf8).write(to: c11h.appendingPathComponent("foreign-c11h.json"))
        try Data("{".utf8).write(to: cmux.appendingPathComponent("foreign-cmux.json"))

        let store = WorkspaceSnapshotStore(
            currentDirectory: WorkspaceSnapshotStore.defaultDirectory(home: home),
            legacyDirectory: WorkspaceSnapshotStore.defaultLegacyDirectory(home: home)
        )
        let ids = try store.list().map(\.snapshotId)
        XCTAssertEqual(ids, ["own-snap"])
    }

    func testUserBlueprintsAndAgentsIgnoreC11AndCmuxHomes() throws {
        let fm = FileManager.default
        let home = root.appendingPathComponent("home", isDirectory: true)
        let ownBlueprints = C11Identity.userBlueprintsDirectory(home: home)
        let c11hBlueprints = home.appendingPathComponent(".config/c11h/blueprints", isDirectory: true)
        let cmuxBlueprints = home.appendingPathComponent(".config/cmux/blueprints", isDirectory: true)
        let ownAgents = C11Identity.userAgentsDirectory(home: home)
        let c11hAgents = home.appendingPathComponent(".config/c11h/agents", isDirectory: true)
        for dir in [ownBlueprints, c11hBlueprints, cmuxBlueprints, ownAgents, c11hAgents] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("{".utf8).write(to: ownBlueprints.appendingPathComponent("own.json"))
        try Data("{".utf8).write(to: c11hBlueprints.appendingPathComponent("foreign.json"))
        try Data("# cmux\n".utf8).write(to: cmuxBlueprints.appendingPathComponent("legacy.md"))
        try Data("{\"command\":\"echo c11\"}\n".utf8).write(to: ownAgents.appendingPathComponent("review.json"))
        try Data("{\"command\":\"echo c11h\"}\n".utf8).write(to: c11hAgents.appendingPathComponent("review.json"))

        let listed = WorkspaceBlueprintStore().perUserBlueprintURLs(home: home).map(\.lastPathComponent)
        XCTAssertEqual(listed, ["own.json"])
        let loaded = UserAgentLaunchTemplate.load(kind: "review", home: home)
        XCTAssertEqual(loaded?.command, "echo c11")
        XCTAssertTrue(ConfigCommandCore.customTemplateExists(kind: "review", home: home))

        try fm.removeItem(at: ownAgents)
        XCTAssertNil(UserAgentLaunchTemplate.load(kind: "review", home: home))
        XCTAssertFalse(ConfigCommandCore.customTemplateExists(kind: "review", home: home))
    }

    func testPortalLogTruncatesOnlyTheC11Path() throws {
        let foreign = root.appendingPathComponent("c11h-portal.log")
        let own = root.appendingPathComponent("c11-portal.log")
        let sentinel = Data("keep-c11h-portal\n".utf8)
        try sentinel.write(to: foreign)
        try Data("old-c11\n".utf8).write(to: own)

        var truncated = false
        C11PortalDebug.truncateOnFirstOpen(path: own.path, alreadyTruncated: &truncated)
        C11PortalDebug.truncateOnFirstOpen(path: own.path, alreadyTruncated: &truncated)

        XCTAssertEqual(try Data(contentsOf: foreign), sentinel)
        XCTAssertEqual(try Data(contentsOf: own), Data())
        XCTAssertEqual(C11PortalDebug.resolveLogPath(environment: [:]), C11Identity.portalLogPath)
        XCTAssertEqual(C11PortalDebug.resolveLogPath(environment: ["C11_PORTAL_LOG": ""]), C11Identity.portalLogPath)
        XCTAssertEqual(C11PortalDebug.resolveLogPath(environment: ["C11_PORTAL_LOG": own.path]), own.path)
        assertC11IdentityPath(C11Identity.portalLogPath)
    }

    func testTaggedDebugForeignSocketOverrideIsNotABind() {
        let bundle = "com.stage11.c11.debug.c11.b"
        let expected = C11Identity.taggedDebugSocketPath(slug: "c11-b")
        let foreignPaths = ["/tmp/c11h.sock", "/tmp/c11h-debug.sock", "/tmp/cmux.sock"]
        for foreign in foreignPaths {
            for key in ["C11_SOCKET_PATH", "CMUX_SOCKET_PATH"] {
                let path = SocketControlSettings.socketPath(
                    environment: [
                        key: foreign,
                        "C11_ALLOW_SOCKET_OVERRIDE": "1",
                    ],
                    bundleIdentifier: bundle,
                    isDebugBuild: true,
                    probeStableDefaultPathEntry: { _ in .missing }
                )
                XCTAssertEqual(path, expected, "\(key)=\(foreign)")
                XCTAssertNotEqual(path, foreign)
            }
        }

        let kept = SocketControlSettings.socketPath(
            environment: [
                "C11_SOCKET_PATH": expected,
                "C11_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: bundle,
            isDebugBuild: true,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertEqual(kept, expected)
    }

    private func assertC11IdentityPath(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        let parts = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        let owned = parts.contains { part in
            part == "c11" || part == ".c11" || part == ".c11-snapshots"
                || part.hasPrefix("c11-") || part.hasPrefix("c11.") || part.hasPrefix(".c11")
        }
        XCTAssertTrue(owned, "missing c11 component in \(path)", file: file, line: line)
        let foreign = parts.contains { part in
            part == "c11h" || part == ".c11h" || part == "cmux" || part == ".cmux"
                || part == "c11mux" || part == ".cmuxterm" || part == ".c11h-snapshots"
                || part == ".cmux-snapshots" || part.hasPrefix("c11h-") || part.hasPrefix(".c11h-")
                || part.hasPrefix("cmux") || part.hasPrefix(".cmux")
        }
        XCTAssertFalse(foreign, "foreign identity component in \(path)", file: file, line: line)
    }

    // MARK: Wire and stored labels keep the retired line's names (C11H-265)

    /// A relay kit a c11h app installed and a c11 2.0 app share one terminal
    /// credential; their MACs agree only while these labels keep their bytes.
    /// The goldens were computed with the c11h-era labels, outside this code.
    func testRelayAndShowLabelsStillProduceTheMACsOlderKitsCompute() {
        let key = Data(0..<32)
        let golden: [(String, String)] = [
            (C11RelayAuth.requestLabel, "d07601ab6acf54f8b8a405ea718951a052d552480e5a41976adacf7b8cab607d"),
            (C11RelayAuth.replyLabel, "54124ceb83cf05a94793cb821e773321df16a9224c9e1275213c795db08fa147"),
            (C11RelayAuth.refusalLabel, "97944398bb179b700e510d46f3dd5d95f2ec04093411bddb561954ea1b2deb2f"),
            (ShowRecord.Entry.macLabel, "b282dfbaa2ffef2c34c5a7a8c5fc972daeedf8264db84effb4cd3f88ea3cea25"),
        ]
        for (label, mac) in golden {
            XCTAssertEqual(C11RelayAuth.mac(key: key, label: label, fields: ["req-1", "payload"]), mac, label)
        }
        // A Show record an older build left on a terminal is still found by name.
        let panel = UUID()
        XCTAssertEqual(ShowRecord.panel(fromName: "c11h.show." + panel.uuidString.lowercased()), panel)
    }

    /// C11H-392: one whole request's MAC, computed outside this code with
    /// Python's `hmac` over the length-prefixed fields. The Linux relay CLI
    /// signs with swift-crypto and this app checks with CryptoKit; both must
    /// give standard HMAC-SHA256, or a Linux machine's every call is refused.
    func testARelayRequestSignsToTheStandardHMACVector() {
        let request = C11Relay.Request(id: "req-392", at: 1_763_372_400_000, panel: "1b4e28ba-2fa1-11d2-883f-0016d3cca427",
                                       workspace: nil, term: "term-7", framing: .json,
                                       line: #"{"method":"system.ping","params":{}}"#, timeoutMilliseconds: 10_000,
                                       nonce: "nonce-1", creation: "6f1c0a52-9d3e-4c8a-b0c1-2a3b4c5d6e7f", linkID: "link-a")
        XCTAssertEqual(C11RelayAuth.sign(request, key: Data(0..<32)),
                       "9e1d829ba6252873785626c3d06961b793fac8b4fa6b4079bb8dbcd67eaa63ed")
    }

    // MARK: The retired line's names are hidden aliases (C11H-265)

    func testRetiredNamesStillWorkAsHiddenAliases() throws {
        XCTAssertTrue(ShowAddressInput.isShowInput("c11h-show://studio/p/x.html"))
        XCTAssertTrue(ShowAddressInput.isShowInput("C11H-SHOW:anything"))
        XCTAssertEqual(ShowSpec.canonicalScheme("c11h-show"), ShowSpec.scheme)
        XCTAssertTrue(CLIInvokedName.isCoreUtilityName("c11h-core"))
        XCTAssertTrue(CLIInvokedName.isCoreUtilityName("c11-core"))
        XCTAssertFalse(CLIInvokedName.isCoreUtilityName("c11h"))
        XCTAssertEqual(CLIInvokedName.name(from: "c11h"), "c11", "hints never say the old name")

        let skill = root.appendingPathComponent("skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill.appendingPathComponent("references"), withIntermediateDirectories: true)
        try Data("---\nname: c11\nversion: 2\n---\ncard\n".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        try Data("persistence page\n".utf8).write(to: skill.appendingPathComponent("references/persistence.md"))
        let page = try BundledSkill(root: skill).load(page: "c11h")
        XCTAssertEqual(page.name, "persistence")
        XCTAssertEqual(page.body, "persistence page\n")
    }

    // MARK: C11H_ names as hidden fallbacks (C11H-265)

    func testLegacyProductNamesFillOnlyMissingCurrentNamesAndNeverSelectors() {
        let old = C11Identity.Legacy.environmentPrefix
        let inherited = [
            old + "RELAY_BIN": "/kit/bin",
            old + "RELAY_SESSION": "old-session",
            "C11_RELAY_SESSION": "current-session",
            // A proof harness's knobs beside the terminal's real selector.
            old + "SOCKET": "/tmp/c11-debug-proof.sock",
            old + "TAG": "proof",
            "C11_SOCKET_PATH": "/tmp/c11.sock",
        ]
        var filled: [String: String] = [:]
        fillC11EnvFromLegacyNames(environment: inherited) { filled[$0] = $1 }
        XCTAssertEqual(filled, ["C11_RELAY_BIN": "/kit/bin"])
        XCTAssertNil(filled["C11_SOCKET"], "a tooling knob never becomes the CLI's socket")
        XCTAssertNil(filled["C11_TAG"], "or its launch tag")
    }
}

// c11-2.0:end-keep