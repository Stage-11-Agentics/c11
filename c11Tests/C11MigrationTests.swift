import CryptoKit
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-266: the first-launch migration on a scratch home. Real files and links,
/// the executor's own steps and journal; only the settings store is in memory.
final class C11MigrationTests: XCTestCase {
    private var home: URL!
    private var store: [String: [String: Any]] = [:]
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        // Short: hc refuses socket paths over 103 bytes.
        home = URL(fileURLWithPath: "/tmp/c11m-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = [:]
        converge = true
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var layout: C11MigrationLayout { C11MigrationLayout(home: home) }

    private func write(_ rel: String, _ text: String) throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ rel: String) -> String? {
        try? String(contentsOf: home.appendingPathComponent(rel), encoding: .utf8)
    }

    private func executor(fault: ((String) throws -> Void)? = nil) -> C11MigrationExecutor {
        let defaults = C11MigrationDefaults(read: { [unowned self] in self.store[$0] },
                                            replace: { [unowned self] in self.store[$0] = $1 })
        return C11MigrationExecutor(layout: layout,
                                    log: C11MigrationLog(url: layout.logsDirectory.appendingPathComponent("migration.log"), run: "test"),
                                    defaults: defaults, fault: fault, now: { [clock] in clock })
    }

    /// Convergence is on in these tests unless a test turns it off (C11H-283 owns it).
    private var converge = true

    private func plan(alive: Bool, legacyRunning: Bool = false, owner: String = "com.stage11.c11") throws -> C11MigrationDecision {
        C11MigrationPlanner.decide(record: try C11MigrationState.load(home: home),
                                   inventory: C11MigrationInventory.read(layout, oneXDefaults: store["com.stage11.c11"], worldAlive: alive),
                                   legacyRunning: legacyRunning, allowed: true, owner: owner, convergeEnabled: converge)
    }

    private func launch(alive: Bool, fault: ((String) throws -> Void)? = nil) throws {
        try executor(fault: fault).run(plan(alive: alive))
    }

    private let legacySnapshotPath = "Library/Application Support/c11h/session-com.stage11.c11h.json"  // c11-2.0:legacy
    private let ownSnapshot = "Library/Application Support/c11/session-com.stage11.c11.json"
    private let installID = "6D5E2A50-7F12-4B9C-9B7E-0A1B2C3D4E5F"
    private let migrationPanelID = "00000000-0000-0000-0000-000000000101"

    private func seedLegacy() throws {
        try write(legacySnapshotPath, #"{"version":1,"panels":[{"id":"00000000-0000-0000-0000-000000000101","terminal":{"hcSession":"c11h-s3"}},{"id":"00000000-0000-0000-0000-000000000102","terminal":{"hcSession" : "c11h"}},{"id":"00000000-0000-0000-0000-000000000103","terminal":{"hcSession":"c11h-staging-x"}}]}"#)  // c11-2.0:legacy
        try write("Library/Application Support/c11h/workspaces/W1/mailboxes/_outbox/a.msg", "mail")  // c11-2.0:legacy
        try write("Library/Application Support/c11h/HC/c11h-s3/intent.json", "{}")  // c11-2.0:legacy
        try write("Library/Application Support/c11h/jev-key", "jev")  // c11-2.0:legacy
        try write("Library/Application Support/c11h/socket-control-password", "pw")  // c11-2.0:legacy
        try write("Library/Application Support/c11h/c11h.sock", "not a socket")  // c11-2.0:legacy
        try write(".c11h/claude-hook-sessions.json", "{}")  // c11-2.0:legacy
        try write(".c11h/runtime/shutdown.com.stage11.c11h.clean", "c11h quit")  // c11-2.0:legacy
        try write(".config/c11h/agents/a.md", "agent")  // c11-2.0:legacy
        try write("Library/WebKit/com.stage11.c11h/WebsiteDataStore/x/blob", "cookies")  // c11-2.0:legacy
        store["com.stage11.c11h"] = ["c11h.appInstallID": installID, "c11h.shards.enabled": true,  // c11-2.0:legacy
                                     "SUEnableAutomaticChecks": false, "posthog.lastActiveDayUTC": "d", "theme.active.light": "t"]
    }

    private func seedOneX() throws {
        try write(ownSnapshot, #"{"version":1,"oneX":true}"#)
        try write(".c11/runtime/shutdown.com.stage11.c11.clean", "1x")
        store["com.stage11.c11"] = ["SULastCheckTime": "now", "theme.active.dark": "1x"]
    }

    // MARK: Planner

    func testPlannerCoversEveryRecordState() throws {
        XCTAssertEqual(try plan(alive: false), .fresh)
        try seedOneX()
        XCTAssertEqual(try plan(alive: false), .inPlace1x)
        try seedLegacy()
        XCTAssertEqual(try plan(alive: true), .adopt(keepOneXAside: true))
        XCTAssertEqual(try plan(alive: false), .converge(keepOneXAside: true, fromAdoption: false))
        XCTAssertEqual(try plan(alive: true, legacyRunning: true), .waitForLegacyApp)
        var state = C11MigrationState(owner: "com.stage11.c11", phase: .adopting, origin: "both", keepOneX: true,
                                      startedAt: "t", updatedAt: "t")
        let table: [(C11MigrationState.Phase, Bool, C11MigrationDecision)] = [
            (.adopting, true, .adopt(keepOneXAside: true)), (.adopted, true, .stayAdopted),
            (.adopted, false, .converge(keepOneXAside: false, fromAdoption: true)),
            (.converged, false, .alreadyDone), (.fresh, false, .alreadyDone), (.inPlace1x, false, .alreadyDone),
        ]
        for (phase, alive, expected) in table {
            state.phase = phase
            try state.write(home: home)
            XCTAssertEqual(try plan(alive: alive), expected, "\(phase)")
            XCTAssertEqual(try plan(alive: alive, legacyRunning: true), .waitForLegacyApp, "a running c11h always waits")  // c11-2.0:legacy
        }
        state.phase = .converging
        state.fromAdoption = true
        try state.write(home: home)
        XCTAssertEqual(try plan(alive: false), .converge(keepOneXAside: true, fromAdoption: true))
        guard case .stop = try plan(alive: false, owner: "com.stage11.c11.debug.other") else {
            return XCTFail("another bundle's record must stop the launch")
        }
        try Data("{".utf8).write(to: C11MigrationState.url(home: home))
        XCTAssertThrowsError(try C11MigrationState.load(home: home))
        XCTAssertFalse(C11MigrationPlanner.allowed(bundleIdentifier: "com.stage11.c11.debug.x", destBundleIdentifier: "com.stage11.c11",
                                                   environment: ["C11_MIGRATION_QA": "1"]))
        XCTAssertTrue(C11MigrationPlanner.allowed(bundleIdentifier: "com.stage11.c11.debug.x", destBundleIdentifier: "com.stage11.c11",
                                                  environment: ["C11_MIGRATION_QA": "1", "C11_QA_LAUNCH": "resume"]))
    }

    // MARK: Adopt, then converge

    func testAdoptThenConvergeOnAMacWithBoth() throws {
        try seedOneX()
        try seedLegacy()
        let legacyBefore = read(legacySnapshotPath)
        let oneXBefore = read(ownSnapshot)

        try launch(alive: true)
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .adopted)
        let adoption = try XCTUnwrap(C11AdoptionRecord.resolve(home: home, bundleIdentifier: "com.stage11.c11"))
        XCTAssertEqual(adoption.base, "c11h")  // c11-2.0:legacy
        XCTAssertNil(C11AdoptionRecord.resolve(home: home, bundleIdentifier: "com.stage11.c11.debug.other"))
        XCTAssertEqual(C11MigrationLayout.linkTarget(layout.destSupport), "c11h")  // c11-2.0:legacy
        XCTAssertEqual(read(ownSnapshot), legacyBefore, "2.0's names lead into c11h's folders while adopted")  // c11-2.0:legacy
        XCTAssertEqual(read(".c11/runtime/shutdown.com.stage11.c11.clean"), "c11h quit")  // c11-2.0:legacy
        XCTAssertEqual(store["com.stage11.c11"]?["c11.appInstallID"] as? String, installID)
        XCTAssertEqual(store["com.stage11.c11"]?["c11.shards.enabled"] as? Bool, true)
        XCTAssertFalse(store["com.stage11.c11"]!.keys.contains { $0.hasPrefix(C11Identity.Legacy.defaultsKeyPrefix) })
        XCTAssertNil(store["com.stage11.c11"]?["SUEnableAutomaticChecks"])
        XCTAssertEqual(store["com.stage11.c11"]?[C11MigrationExecutor.originKey] as? String, "both")
        XCTAssertEqual(read("Library/WebKit/com.stage11.c11/WebsiteDataStore/x/blob"), "cookies")
        let kept = try XCTUnwrap(try C11MigrationState.load(home: home)?.keptDirectory)
        let base = "Library/Application Support/\(kept)"
        XCTAssertEqual(read("\(base)/home/Library/Application Support/c11/session-com.stage11.c11.json"), oneXBefore)
        XCTAssertEqual(read("\(base)/home/.c11/runtime/shutdown.com.stage11.c11.clean"), "1x")
        let exported = try XCTUnwrap(NSDictionary(contentsOf: home.appendingPathComponent("\(base)/defaults-com.stage11.c11.plist")))
        XCTAssertEqual(exported["theme.active.dark"] as? String, "1x")
        XCTAssertEqual(try plan(alive: true), .stayAdopted)

        // 2.0 runs adopted and writes through its links; then the terminals end.
        try write(ownSnapshot, #"{"panels":[{"id":"00000000-0000-0000-0000-000000000101","terminal":{"hcSession":"c11h-s5"}}]}"#)  // c11-2.0:legacy
        try write("Library/Application Support/c11h/workspaces/W1/mailboxes/_outbox/b.msg", "survivor mail")  // c11-2.0:legacy
        store["com.stage11.c11"]?["theme.active.light"] = "changed in 2.0"
        try launch(alive: false)
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .converged)
        XCTAssertNil(C11AdoptionRecord.resolve(home: home, bundleIdentifier: "com.stage11.c11"))
        for folder in layout.switchedFolders {
            XCTAssertTrue(C11MigrationLayout.isRealDirectory(layout.url(folder.path)), folder.path)
        }
        let converted = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: layout.url(ownSnapshot))) as? [String: Any])
        let convertedPanel = try XCTUnwrap((converted["panels"] as? [[String: Any]])?.first)
        let convertedTerminal = try XCTUnwrap(convertedPanel["terminal"] as? [String: Any])
        XCTAssertEqual(convertedPanel["id"] as? String, migrationPanelID)
        XCTAssertNil(convertedTerminal["hcIdentity"], "the active dead-core identity is dropped")
        XCTAssertNil(convertedTerminal["hcSession"], "the old pool is no longer selected")
        XCTAssertNotNil(convertedTerminal["hcMigrationEnd"], "the fresh panel retains the proven end for recovery")
        XCTAssertEqual(read("Library/Application Support/c11/workspaces/W1/mailboxes/_outbox/b.msg"), "survivor mail")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/c11/HC/c11h-s3").path))  // c11-2.0:legacy
        XCTAssertNil(read("Library/Application Support/c11/c11h.sock"))  // c11-2.0:legacy
        XCTAssertEqual(read(".c11/claude-hook-sessions.json"), "{}")
        XCTAssertEqual(read(".config/c11/agents/a.md"), "agent")
        XCTAssertEqual(store["com.stage11.c11"]?["theme.active.light"] as? String, "changed in 2.0")
        XCTAssertEqual(read(legacySnapshotPath), legacyBefore)
        XCTAssertNotNil(read("Library/Application Support/c11h/HC/c11h-s3/intent.json"))  // c11-2.0:legacy
        XCTAssertEqual(store["com.stage11.c11h"]?.count, 5)  // c11-2.0:legacy
        XCTAssertEqual(try plan(alive: false), .alreadyDone)
    }

    func testDirectConvergeCarriesNamesKeysAndCredentials() throws {
        try seedLegacy()
        try launch(alive: false)
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .converged)
        let own = try XCTUnwrap(read(ownSnapshot))
        XCTAssertEqual(own.components(separatedBy: "hcSession").count - 1, 1, "only the tagged session's panel keeps one")
        XCTAssertTrue(own.contains(#""hcSession":"c11h-staging-x""#), "a tagged session is not 2.0's to settle")  // c11-2.0:legacy
        XCTAssertTrue(try XCTUnwrap(read(legacySnapshotPath)).contains(#""c11h-s3""#))  // c11-2.0:legacy
        XCTAssertEqual(read("Library/Application Support/c11/jev-key"), "jev")
        XCTAssertEqual(read("Library/Application Support/c11/socket-control-password"), "pw")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/c11/HC/c11h-s3").path))  // c11-2.0:legacy
        XCTAssertEqual(read(".c11/runtime/shutdown.com.stage11.c11.clean"), "c11h quit")  // c11-2.0:legacy
        XCTAssertEqual(store["com.stage11.c11"]?["c11.appInstallID"] as? String, installID)
        XCTAssertEqual(store["com.stage11.c11"]?[C11MigrationExecutor.originKey] as? String, "c11h")  // c11-2.0:legacy
        XCTAssertEqual(try plan(alive: false), .alreadyDone)
    }

    // MARK: A crash anywhere equals a clean run

    /// Walk each requested tree explicitly. A symlink is a leaf; Foundation's
    /// enumerator already treats it that way, so skipDescendants() on the link
    /// can skip an unrelated real subtree and hide preserved files from checks.
    private func fileManifest(roots: [String], normalizeProvenance: Bool = false) throws -> [String: String] {
        var out: [String: String] = [:]
        func visit(_ relative: String) throws {
            if relative == "Library/Logs" || relative.hasPrefix("Library/Logs/") { return }
            let url = layout.url(relative)
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { return }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                out[relative] = "-> " + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            case S_IFDIR:
                for child in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                    try visit(relative.isEmpty ? child : relative + "/" + child)
                }
            case S_IFREG:
                var data = try Data(contentsOf: url)
                if normalizeProvenance,
                   [C11MigrationState.fileName, ".c11-migration-stage.json"].contains(url.lastPathComponent),
                   var record = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Only cross-fixture clean-run comparisons normalize stamps:
                    // source paths/mtimes differ across homes. Preservation checks
                    // below hash exact bytes, including any provenance fields.
                    record["sourceStamp"] = nil
                    data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                }
                out[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            default:
                out[relative] = "special:\(info.st_mode)"
            }
        }
        for root in roots { try visit(root) }
        return out
    }

    /// Every file, link and setting under the scratch home, with contents hashed.
    private func manifest() throws -> [String: String] {
        var out = try fileManifest(roots: [""], normalizeProvenance: true)
        for (domain, values) in store {
            out["defaults:" + domain] = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: ";")
        }
        return out
    }

    private enum Scenario: CaseIterable { case adoptBoth, directConverge, convergeFromAdoption }

    private func seed(_ scenario: Scenario) throws {
        try seedLegacy()
        switch scenario {
        case .adoptBoth, .directConverge: try seedOneX()
        case .convergeFromAdoption: try launch(alive: true)
        }
    }

    /// Launches until the scenario settles; an injected fault ends one launch.
    private func finish(_ scenario: Scenario, fault: ((String) throws -> Void)? = nil) throws {
        let alive = scenario == .adoptBoth
        for _ in 0..<3 {
            do { try launch(alive: alive, fault: fault) } catch C11MigrationExecutor.Failure.injected { continue }
            let next = try plan(alive: alive)
            if next == .alreadyDone || next == .stayAdopted { return }
        }
        XCTFail("\(scenario) did not settle")
    }

    func testACrashAtEveryStepResumesToTheCleanResult() throws {
        let points: [Scenario: [String]] = [
            .adoptBoth: ["keep_1x", "keep_1x_mid", "defaults", "adopt_files", "adopt_links"],
            .directConverge: ["keep_1x", "keep_1x_mid", "c_stage", "c_defaults", "c_switch_mid", "c_switch"],
            .convergeFromAdoption: ["c_stage", "c_defaults", "c_switch_mid", "c_switch"],
        ]
        for scenario in Scenario.allCases {
            try tearDownWithError(); try setUpWithError()
            try seed(scenario)
            try finish(scenario)
            let clean = try manifest()
            for point in points[scenario]! {
                try tearDownWithError(); try setUpWithError()
                try seed(scenario)
                var fired = false
                try finish(scenario) { step in
                    guard step == point, !fired else { return }
                    fired = true
                    throw C11MigrationExecutor.Failure.injected(step)
                }
                XCTAssertTrue(fired, "\(scenario): fault point \(point) was never reached")
                let after = try manifest()
                let differing = Set(after.keys).symmetricDifference(clean.keys).sorted()
                    + clean.keys.filter { after[$0] != nil && after[$0] != clean[$0] }.sorted()
                XCTAssertTrue(differing.isEmpty, "\(scenario): a crash at \(point) must resume to the clean result; differs at \(differing.prefix(6))")
                let kept = try FileManager.default.contentsOfDirectory(atPath: layout.appSupport.path)
                    .filter { $0.contains(C11Migration.keptPrefix) }.count
                XCTAssertEqual(kept, scenario == .convergeFromAdoption ? 0 : 1, "\(scenario) at \(point): one kept folder")
            }
        }
    }

    // MARK: C11H-283 observed-layout reconciliation

    /// An ordinary source installation may never have saved a snapshot or
    /// blueprint. Exercise the real stores through the adopted destination
    /// paths, then ensure convergence carries those newly saved files.
    private func checkAdoptedWritesWithMissingOptionalFolders(rollback: Bool, repairCommitted: Bool = false) throws {
        try seedLegacy()
        try FileManager.default.removeItem(at: layout.url(".config/c11h"))  // c11-2.0:legacy
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.url(".c11h-snapshots").path))  // c11-2.0:legacy
        if rollback {
            try interrupt(at: "c_switch", alive: false)
        }
        try launch(alive: true)
        if repairCommitted {
            // A record written by the former reconciler can already contain
            // exact but dangling links. The committed-layout check must repair it.
            for source in [".c11h-snapshots", ".config/c11h"] {  // c11-2.0:legacy
                let url = layout.url(source)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            XCTAssertThrowsError(try executor().verifyCommittedLayout())
            try launch(alive: true)
        }
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .adopted)
        let plan = WorkspaceApplyPlan(version: 1, workspace: WorkspaceSpec(title: "Adopted write fixture"),
            layout: .pane(.init(surfaceIds: ["a"])), surfaces: [PanelSpec(id: "a", kind: .terminal)])
        let snapshots = WorkspaceSnapshotStore(currentDirectory: layout.url(".c11-snapshots"),
            legacyDirectory: layout.url(".c11-snapshots"))
        let snapshotURL = try snapshots.writeToDefaultDirectory(WorkspaceSnapshotFile(snapshotId: "x",
            createdAt: clock, c11Version: "fixture", origin: .manual, plan: plan))
        let blueprintURL = layout.url(".config/c11/blueprints/x.json")
        let blueprints = WorkspaceBlueprintStore(directoryOverride: blueprintURL.deletingLastPathComponent())
        try blueprints.write(WorkspaceBlueprintFile(name: "Adopted fixture", plan: plan), to: blueprintURL)
        let snapshotBytes = try Data(contentsOf: snapshotURL)
        let blueprintBytes = try Data(contentsOf: blueprintURL)
        XCTAssertEqual(try Data(contentsOf: layout.url(".c11h-snapshots/x.json")), snapshotBytes)  // c11-2.0:legacy
        XCTAssertEqual(try Data(contentsOf: layout.url(".config/c11h/blueprints/x.json")), blueprintBytes)  // c11-2.0:legacy
        try launch(alive: false)
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .converged)
        XCTAssertEqual(try Data(contentsOf: snapshotURL), snapshotBytes)
        XCTAssertEqual(try Data(contentsOf: blueprintURL), blueprintBytes)
        try executor().verifyCommittedLayout()
    }

    func testAdoptedSnapshotAndBlueprintWritesSurviveConvergence() throws {
        try checkAdoptedWritesWithMissingOptionalFolders(rollback: false)
    }

    func testRollbackPublishesWritableSnapshotAndBlueprintPaths() throws {
        try checkAdoptedWritesWithMissingOptionalFolders(rollback: true)
    }

    func testPreviouslyCommittedDanglingAdoptionIsRepairedBeforeWrites() throws {
        try checkAdoptedWritesWithMissingOptionalFolders(rollback: false, repairCommitted: true)
    }

    func testDirectConvergenceStampsMaterializedOptionalSources() throws {
        try seedLegacy()
        try FileManager.default.removeItem(at: layout.url(".config/c11h"))  // c11-2.0:legacy
        try launch(alive: false)
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .converged)
        for source in [".c11h-snapshots", ".config/c11h"] {  // c11-2.0:legacy
            XCTAssertTrue(C11MigrationLayout.isRealDirectory(layout.url(source)), source)
        }
        XCTAssertEqual(try C11MigrationState.load(home: home)?.sourceStamp, try executor().sourceStamp())
        try executor().verifyCommittedLayout()
    }

    private let legacyMail = "Library/Application Support/c11h/workspaces/W1/mailboxes/_outbox/a.msg"  // c11-2.0:legacy
    private let migratedMail = "Library/Application Support/c11/workspaces/W1/mailboxes/_outbox/a.msg"

    /// Reset only this test's disposable home. Never addresses an app or live process.
    private func resetForReconciliation(adopted: Bool = true, keepOneX: Bool = true) throws {
        try tearDownWithError()
        try setUpWithError()
        if keepOneX { try seedOneX() }
        try seedLegacy()
        if adopted { try launch(alive: true) }
    }

    private struct PreservedManifest: Equatable {
        let source: [String: String]
        let keptOneX: [String: String]
    }

    /// Collect the legacy roots and every kept 1.x tree independently, so aliases
    /// or staging layout cannot change which originals are inspected.
    private func preservedManifest() throws -> PreservedManifest {
        let sourceRoots = layout.switchedFolders.map(\.source) + layout.bundleDataItems.map(\.source)
        var source = try fileManifest(roots: sourceRoots).filter { path, _ in
            // Adoption may add these destination-named aliases beside originals.
            // Exclude only the exact alias paths, never matching nested user files.
            if path == layout.switchedFolders[0].source + "/" + layout.destSnapshotName
                || path == layout.switchedFolders[0].source + "/" + layout.destPanelAllocations { return false }
            let runtime = layout.sourceHomeDirectory + "/runtime/"
            let aliases = ["shutdown.", "relaunch."].flatMap { kind in
                [".clean", ".dirty", ".json"].map { runtime + kind + layout.destBundleIdentifier + $0 }
            }
            return !aliases.contains(path)
        }
        if let values = store[layout.sourceBundleIdentifier] {
            source["defaults:" + layout.sourceBundleIdentifier] = values.keys.sorted()
                .map { "\($0)=\(values[$0]!)" }.joined(separator: ";")
        }
        let keptRoots = try FileManager.default.contentsOfDirectory(atPath: layout.appSupport.path)
            .filter { $0.hasPrefix(layout.destSupportName + C11Migration.keptPrefix) }
            .map { "Library/Application Support/" + $0 }
        return PreservedManifest(source: source, keptOneX: try fileManifest(roots: keptRoots))
    }

    private func interrupt(at point: String, alive: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        var reached = false
        XCTAssertThrowsError(try launch(alive: alive) { step in
            guard step == point else { return }
            reached = true
            throw CocoaError(.fileWriteOutOfSpace)
        }, point, file: file, line: line)
        XCTAssertTrue(reached, "fault was not reached: \(point)", file: file, line: line)
    }

    private func assertReconciled(adopted: Bool, mail: String, context: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, adopted ? .adopted : .converged,
                       context, file: file, line: line)
        for folder in layout.switchedFolders {
            let final = layout.url(folder.path)
            if adopted {
                XCTAssertEqual(C11MigrationLayout.linkTarget(final), folder.target,
                               "\(context): \(folder.path)", file: file, line: line)
            } else {
                XCTAssertTrue(C11MigrationLayout.isRealDirectory(final),
                              "\(context): \(folder.path)", file: file, line: line)
                XCTAssertNil(C11MigrationLayout.linkTarget(final), context, file: file, line: line)
            }
        }
        XCTAssertEqual(read(migratedMail), mail, context, file: file, line: line)
    }

    /// A rollback chosen on an earlier launch finishes before new liveness can
    /// choose another direction. A later dead-world launch may then converge.
    private func finishReconciliation(alive: Bool) throws {
        for _ in 0..<3 {
            try launch(alive: alive)
            let phase = try C11MigrationState.load(home: home)?.phase
            if phase == (alive ? .adopted : .converged) { return }
        }
        XCTFail("reconciliation did not reach its target")
    }

    private func checkForwardFaults(pathIndex: Int) throws {
        for operation in ["park", "install"] {
            for edge in ["before", "after"] {
                let point = "forward.\(pathIndex).\(operation).\(edge)"
                for alive in [false, true] {
                    for changed in [false, true] {
                        try resetForReconciliation()
                        try interrupt(at: point, alive: false)
                        if changed { try write(legacyMail, "source changed after \(point)") }
                        let source = try preservedManifest()
                        let expected = try XCTUnwrap(read(legacyMail))
                        let context = "\(point), alive=\(alive), changed=\(changed)"
                        try finishReconciliation(alive: alive)
                        try assertReconciled(adopted: alive, mail: expected, context: context)
                        XCTAssertEqual(try preservedManifest(), source, context)
                        let settled = try manifest()
                        try launch(alive: alive)
                        XCTAssertEqual(try manifest(), settled, "\(context): repeated launch is inert")
                    }
                }
            }
        }
    }

    // Split by path so each narrowed invocation stays small and a failure names
    // the directory whose crash boundary failed.
    func testForwardFaultMatrixSupport() throws { try checkForwardFaults(pathIndex: 0) }
    func testForwardFaultMatrixHome() throws { try checkForwardFaults(pathIndex: 1) }
    func testForwardFaultMatrixSnapshots() throws { try checkForwardFaults(pathIndex: 2) }
    func testForwardFaultMatrixConfig() throws { try checkForwardFaults(pathIndex: 3) }

    private func checkEmptyStageCreation(pathIndex: Int) throws {
        let point = "stage.\(pathIndex).created"
        for alive in [false, true] {
            for changed in [false, true] {
                try resetForReconciliation()
                try interrupt(at: point, alive: false)
                let stage = URL(fileURLWithPath: layout.url(layout.switchedFolders[pathIndex].path).path + C11Migration.stagingSuffix)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path), [], point)
                if changed { try write(legacyMail, "changed at empty stage") }
                let source = try preservedManifest()
                let expected = try XCTUnwrap(read(legacyMail))
                let context = "\(point), alive=\(alive), changed=\(changed)"
                try finishReconciliation(alive: alive)
                try assertReconciled(adopted: alive, mail: expected, context: context)
                XCTAssertEqual(try preservedManifest(), source, context)
            }
        }
    }

    func testEmptyStageCreationGapSupport() throws { try checkEmptyStageCreation(pathIndex: 0) }
    func testEmptyStageCreationGapHome() throws { try checkEmptyStageCreation(pathIndex: 1) }
    func testEmptyStageCreationGapSnapshots() throws { try checkEmptyStageCreation(pathIndex: 2) }
    func testEmptyStageCreationGapConfig() throws { try checkEmptyStageCreation(pathIndex: 3) }

    private func checkInterruptedStageDiscard(pathIndex: Int) throws {
        for edge in ["entry.before", "entry.after", "marker.after"] {
            let point = "discard.\(pathIndex).\(edge)"
            for alive in [false, true] {
                for changed in [false, true] {
                    try resetForReconciliation()
                    // Ensure the snapshots candidate also has payload to delete.
                    try write(".c11h-snapshots/saved.json", "snapshot payload")  // c11-2.0:legacy
                    try interrupt(at: "c_switch", alive: false)
                    try interrupt(at: point, alive: true)
                    let stage = URL(fileURLWithPath: layout.url(layout.switchedFolders[pathIndex].path).path + C11Migration.stagingSuffix)
                    if edge == "marker.after" {
                        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path), [], point)
                    } else {
                        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent(".c11-migration-stage.json").path),
                                      "payload deletion retains ownership until the final entry is gone")
                    }
                    if changed { try write(legacyMail, "changed during discard") }
                    let source = try preservedManifest()
                    let expected = try XCTUnwrap(read(legacyMail))
                    let context = "\(point), alive=\(alive), changed=\(changed)"
                    try launch(alive: alive)
                    try assertReconciled(adopted: true, mail: expected, context: context)
                    XCTAssertEqual(try preservedManifest(), source, context)
                    try finishReconciliation(alive: alive)
                    try assertReconciled(adopted: alive, mail: expected, context: context)
                    XCTAssertEqual(try preservedManifest(), source, context)
                }
            }
        }
    }

    func testInterruptedStageDiscardSupport() throws { try checkInterruptedStageDiscard(pathIndex: 0) }
    func testInterruptedStageDiscardHome() throws { try checkInterruptedStageDiscard(pathIndex: 1) }
    func testInterruptedStageDiscardSnapshots() throws { try checkInterruptedStageDiscard(pathIndex: 2) }
    func testInterruptedStageDiscardConfig() throws { try checkInterruptedStageDiscard(pathIndex: 3) }

    func testLegacyNilStampCanResumeAfterDiscardingItsStageMarker() throws {
        for pathIndex in layout.switchedFolders.indices {
            for alive in [false, true] {
                try resetForReconciliation()
                try interrupt(at: "c_stage", alive: false)
                for folder in layout.switchedFolders {
                    let stage = URL(fileURLWithPath: layout.url(folder.path).path + C11Migration.stagingSuffix)
                    try FileManager.default.removeItem(at: stage.appendingPathComponent(".c11-migration-stage.json"))
                }
                var state = try XCTUnwrap(try C11MigrationState.load(home: home))
                state.target = nil
                state.sourceStamp = nil
                state.steps["c_stage"] = .running
                try state.write(home: home)
                let point = "discard.\(pathIndex).marker.after"
                try interrupt(at: point, alive: true)
                XCTAssertNil(try C11MigrationState.load(home: home)?.sourceStamp)
                let source = try preservedManifest()
                try launch(alive: alive)
                try assertReconciled(adopted: true, mail: "mail", context: point)
                try finishReconciliation(alive: alive)
                try assertReconciled(adopted: alive, mail: "mail", context: point)
                XCTAssertEqual(try preservedManifest(), source, point)
            }
        }
    }

    private func checkEveryOneXMoveInterruption(alive: Bool) throws {
        for occurrence in 1...layout.oneXItems.count {
            try resetForReconciliation(adopted: false)
            for path in layout.oneXItems {
                // Seed every movable family, including the standalone cookies file.
                try write(path + (path.hasSuffix(".binarycookies") ? "" : "/one-x-fixture"), "old: " + path)
            }
            let originalOneX = try fileManifest(roots: layout.oneXItems)
            let originalDefaults = try XCTUnwrap(store[layout.oneXBundleIdentifier]) as NSDictionary
            let originalSource = try preservedManifest().source
            var reached = 0
            XCTAssertThrowsError(try launch(alive: false) { step in
                guard step == "keep_1x_mid" else { return }
                reached += 1
                if reached == occurrence { throw CocoaError(.fileWriteOutOfSpace) }
            })
            XCTAssertEqual(reached, occurrence)
            let keptName = try XCTUnwrap(try C11MigrationState.load(home: home)?.keptDirectory)
            try finishReconciliation(alive: alive)
            let context = "keep_1x_mid occurrence=\(occurrence), alive=\(alive)"
            try assertReconciled(adopted: alive, mail: "mail", context: context)
            XCTAssertEqual(try preservedManifest().source, originalSource, context)
            XCTAssertEqual(try C11MigrationState.load(home: home)?.keptDirectory, keptName, context)
            let kept = "Library/Application Support/" + keptName
            let prefix = kept + "/home/"
            let preservedOneX = try fileManifest(roots: [kept + "/home"])
            let originalPaths = Dictionary(uniqueKeysWithValues: preservedOneX.map {
                (String($0.key.dropFirst(prefix.count)), $0.value)
            })
            XCTAssertEqual(originalPaths, originalOneX, "\(context): every 1.x byte is kept once")
            let exported = try XCTUnwrap(NSDictionary(contentsOf: layout.url(kept + "/defaults-" + layout.oneXBundleIdentifier + ".plist")))
            XCTAssertEqual(exported, originalDefaults, context)
            XCTAssertNotNil(read(kept + "/KEPT.md"), context)
            let settled = try preservedManifest()
            try launch(alive: alive)
            XCTAssertEqual(try preservedManifest(), settled, context)
        }
    }

    func testEveryOneXMoveInterruptionCanResumeDead() throws { try checkEveryOneXMoveInterruption(alive: false) }
    func testEveryOneXMoveInterruptionCanReturnToAliveAdoption() throws { try checkEveryOneXMoveInterruption(alive: true) }

    private func checkRollbackFaults(pathIndex: Int) throws {
        for operation in ["park", "install"] {
            for edge in ["before", "after"] {
                let point = "rollback.\(pathIndex).\(operation).\(edge)"
                for alive in [false, true] {
                    for changed in [false, true] {
                        try resetForReconciliation()
                        try interrupt(at: "c_switch", alive: false)
                        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .converging)
                        try interrupt(at: point, alive: true)
                        if changed { try write(legacyMail, "source changed after \(point)") }
                        let source = try preservedManifest()
                        let expected = try XCTUnwrap(read(legacyMail))
                        let context = "\(point), alive=\(alive), changed=\(changed)"
                        // In particular, dead-on-retry cannot skip the interrupted
                        // rollback and falsely publish its partially linked tree.
                        try launch(alive: alive)
                        try assertReconciled(adopted: true, mail: expected, context: context)
                        XCTAssertEqual(try preservedManifest(), source, context)
                        try finishReconciliation(alive: alive)
                        try assertReconciled(adopted: alive, mail: expected, context: context)
                        let settled = try manifest()
                        try launch(alive: alive)
                        XCTAssertEqual(try manifest(), settled, "\(context): repeated launch is inert")
                    }
                }
            }
        }
    }

    func testRollbackFaultMatrixSupport() throws { try checkRollbackFaults(pathIndex: 0) }
    func testRollbackFaultMatrixHome() throws { try checkRollbackFaults(pathIndex: 1) }
    func testRollbackFaultMatrixSnapshots() throws { try checkRollbackFaults(pathIndex: 2) }
    func testRollbackFaultMatrixConfig() throws { try checkRollbackFaults(pathIndex: 3) }

    /// Verification 2's exact failure: all four real directories were installed,
    /// but the phase did not commit before the operator changed the legacy world.
    func testEveryForwardStageRevalidatesChangedSourceIncludingAfterSwitch() throws {
        for point in ["c_stage", "c_switch_mid", "c_switch"] {
            for adopted in [false, true] {
                try resetForReconciliation(adopted: adopted)
                try interrupt(at: point, alive: false)
                try write(legacyMail, "new mail after \(point)")
                let source = try preservedManifest()
                try finishReconciliation(alive: false)
                try assertReconciled(adopted: false, mail: "new mail after \(point)",
                                     context: "\(point), fromAdoption=\(adopted)")
                XCTAssertEqual(try preservedManifest(), source)
            }
        }
    }

    func testChangedInputsAcrossEveryStagedSourceFamily() throws {
        let carried: [(source: String, destination: String, before: String, after: String)] = [
            ("Library/Application Support/c11h/session-com.stage11.c11.json", ownSnapshot,  // c11-2.0:legacy
             #"{"version":1,"panels":[],"fixture":"before"}"#, #"{"version":1,"panels":[],"fixture":"after"}"#),
            ("Library/Application Support/c11h/panel-allocations-com.stage11.c11.json",  // c11-2.0:legacy
             "Library/Application Support/c11/panel-allocations-com.stage11.c11.json", "before", "after"),
            (legacyMail, migratedMail, "before", "after"),
            ("Library/Application Support/c11h/jev-key", "Library/Application Support/c11/jev-key", "before", "after"),  // c11-2.0:legacy
            ("Library/Application Support/c11h/socket-control-password", "Library/Application Support/c11/socket-control-password", "before", "after"),  // c11-2.0:legacy
            (".c11h/claude-hook-sessions.json", ".c11/claude-hook-sessions.json", "before", "after"),  // c11-2.0:legacy
            (".c11h/runtime/shutdown.com.stage11.c11.clean", ".c11/runtime/shutdown.com.stage11.c11.clean", "before", "after"),  // c11-2.0:legacy
            (".c11h-snapshots/saved.json", ".c11-snapshots/saved.json", "before", "after"),  // c11-2.0:legacy
            (".config/c11h/agents/a.md", ".config/c11/agents/a.md", "before", "after"),  // c11-2.0:legacy
            ("Library/Application Support/c11h/session-history/saved.json", "Library/Application Support/c11/session-history/saved.json", "before", "after"),  // c11-2.0:legacy
        ]
        for item in carried {
            for point in ["c_stage", "c_switch"] {
                try resetForReconciliation()
                try write(item.source, item.before)
                try interrupt(at: point, alive: false)
                try write(item.source, item.after)
                let source = try preservedManifest()
                try finishReconciliation(alive: false)
                XCTAssertEqual(read(item.destination), item.after, "\(point): \(item.source)")
                XCTAssertEqual(try preservedManifest(), source)
            }
        }
    }

    func testRetryChoosesSnapshotWithShutdownWorldAndNewestAllocations() throws {
        let sourceSnapshot = legacySnapshotPath
        let adoptedSnapshot = "Library/Application Support/c11h/" + layout.destSnapshotName  // c11-2.0:legacy
        let sourceAllocations = "Library/Application Support/c11h/" + layout.sourcePanelAllocations  // c11-2.0:legacy
        let adoptedAllocations = "Library/Application Support/c11h/" + layout.destPanelAllocations  // c11-2.0:legacy
        let destinationAllocations = "Library/Application Support/c11/" + layout.destPanelAllocations
        func stampedWrite(_ path: String, _ text: String, _ offset: TimeInterval) throws {
            try write(path, text)
            try FileManager.default.setAttributes([.modificationDate: clock.addingTimeInterval(offset)],
                                                   ofItemAtPath: layout.url(path).path)
        }
        for point in ["c_stage", "c_switch"] {
            for legacySnapshotWins in [false, true] {
                for legacyAllocationsWin in [false, true] {
                    try resetForReconciliation()
                    try stampedWrite(sourceSnapshot, #"{"version":1,"panels":[],"fixture":"legacy-before"}"#, -20)
                    try stampedWrite(adoptedSnapshot, #"{"version":1,"panels":[],"fixture":"own-before"}"#, -10)
                    try stampedWrite(".c11h/runtime/shutdown.com.stage11.c11h.clean", "legacy quit", -20)  // c11-2.0:legacy
                    try stampedWrite(".c11h/runtime/shutdown.com.stage11.c11.clean", "own quit", -10)  // c11-2.0:legacy
                    try stampedWrite(sourceAllocations, "legacy allocations before", -20)
                    try stampedWrite(adoptedAllocations, "own allocations before", -10)
                    try interrupt(at: point, alive: false)
                    // Real timestamps, spaced apart deliberately: no assumption that
                    // two rapid writes get different filesystem clock ticks.
                    let chosenSnapshot = legacySnapshotWins ? sourceSnapshot : adoptedSnapshot
                    let chosenAllocations = legacyAllocationsWin ? sourceAllocations : adoptedAllocations
                    let expectedSnapshot = #"{"version":1,"panels":[],"fixture":"chosen-after"}"#
                    try stampedWrite(chosenSnapshot, expectedSnapshot, 10)
                    let latestBundle = legacySnapshotWins ? layout.sourceBundleIdentifier : layout.destBundleIdentifier
                    try stampedWrite(".c11h/runtime/shutdown.\(latestBundle).clean", "newest quit", 10)  // c11-2.0:legacy
                    try stampedWrite(chosenAllocations, "chosen allocations after", 20)
                    let source = try preservedManifest()
                    try finishReconciliation(alive: false)
                    let context = "\(point), legacy snapshot=\(legacySnapshotWins), legacy allocations=\(legacyAllocationsWin)"
                    XCTAssertEqual(read(ownSnapshot), expectedSnapshot, context)
                    XCTAssertEqual(read(destinationAllocations), "chosen allocations after", context)
                    XCTAssertEqual(try preservedManifest(), source)
                }
            }
        }
    }

    func testRetryChoosesNewerRuntimeMarkersFromEitherApp() throws {
        for point in ["c_stage", "c_switch"] {
            for legacyWins in [false, true] {
                try resetForReconciliation()
                let legacy = ".c11h/runtime/shutdown.com.stage11.c11h.clean"  // c11-2.0:legacy
                let adopted = ".c11h/runtime/shutdown.com.stage11.c11.clean"  // c11-2.0:legacy
                try write(legacy, "legacy before")
                try write(adopted, "own before")
                try FileManager.default.setAttributes([.modificationDate: clock.addingTimeInterval(-20)],
                                                       ofItemAtPath: layout.url(legacy).path)
                try FileManager.default.setAttributes([.modificationDate: clock.addingTimeInterval(-10)],
                                                       ofItemAtPath: layout.url(adopted).path)
                try interrupt(at: point, alive: false)
                let selected = legacyWins ? legacy : adopted
                try write(selected, "newest quit")
                try FileManager.default.setAttributes([.modificationDate: clock.addingTimeInterval(10)],
                                                       ofItemAtPath: layout.url(selected).path)
                let source = try preservedManifest()
                try finishReconciliation(alive: false)
                XCTAssertEqual(read(".c11/runtime/shutdown.com.stage11.c11.clean"), "newest quit", point)
                XCTAssertEqual(try preservedManifest(), source)
            }
        }
    }

    private func checkSnapshotAndShutdownSetStayTogether(legacyLatest: Bool) throws {
        for point in ["c_stage", "c_switch"] {
            for dirty in [false, true] {
                try resetForReconciliation()
                let runtime = layout.url(".c11h/runtime")  // c11-2.0:legacy
                let selected = legacyLatest ? layout.sourceBundleIdentifier : layout.destBundleIdentifier
                let other = legacyLatest ? layout.destBundleIdentifier : layout.sourceBundleIdentifier
                let selectedSnapshot = "Library/Application Support/c11h/session-\(selected).json"  // c11-2.0:legacy
                let otherSnapshot = "Library/Application Support/c11h/session-\(other).json"  // c11-2.0:legacy
                let expected = #"{"version":1,"panels":[],"fixture":"selected shutdown world"}"#
                try write(selectedSnapshot, expected)
                try write(otherSnapshot, #"{"version":1,"panels":[],"fixture":"other world"}"#)
                for (bundle, offset) in [(other, -20.0), (selected, -10.0)] {
                    XCTAssertTrue(ShutdownSentinel.promoteToClean(bundleId: bundle, at: clock.addingTimeInterval(offset), directory: runtime))
                    try FileManager.default.setAttributes([.modificationDate: clock.addingTimeInterval(offset)],
                        ofItemAtPath: try XCTUnwrap(ShutdownSentinel.cleanURL(bundleId: bundle, directory: runtime)).path)
                }
                try write(".c11h/runtime/relaunch.\(selected).json", "selected relaunch")  // c11-2.0:legacy
                try write(".c11h/runtime/relaunch.\(other).json", "other relaunch")  // c11-2.0:legacy
                try interrupt(at: point, alive: false)
                let latest = clock.addingTimeInterval(10)
                if dirty {
                    XCTAssertTrue(ShutdownSentinel.writeDirty(bundleId: selected, at: latest, directory: runtime))
                } else {
                    XCTAssertTrue(ShutdownSentinel.writeDirty(bundleId: other, at: clock, directory: runtime))
                    try FileManager.default.setAttributes([.modificationDate: clock],
                        ofItemAtPath: try XCTUnwrap(ShutdownSentinel.dirtyURL(bundleId: other, directory: runtime)).path)
                    XCTAssertTrue(ShutdownSentinel.promoteToClean(bundleId: selected, at: latest, directory: runtime))
                }
                let latestMarker = dirty
                    ? ShutdownSentinel.dirtyURL(bundleId: selected, directory: runtime)
                    : ShutdownSentinel.cleanURL(bundleId: selected, directory: runtime)
                try FileManager.default.setAttributes([.modificationDate: latest], ofItemAtPath: try XCTUnwrap(latestMarker).path)
                // A competing snapshot's mtime cannot pair its world with this
                // app's shutdown semantics. The selected sentinel owns both.
                try FileManager.default.setAttributes([.modificationDate: clock.addingTimeInterval(30)], ofItemAtPath: layout.url(otherSnapshot).path)
                let source = try preservedManifest()
                try finishReconciliation(alive: false)
                let destinationRuntime = layout.url(".c11/runtime")
                let prior = ShutdownSentinel.readPriorShutdown(bundleId: layout.destBundleIdentifier, directory: destinationRuntime)
                XCTAssertEqual(prior, dirty ? .dirty(launchedAt: latest) : .clean(at: latest), point)
                XCTAssertEqual(ShutdownSentinel.resolveRecoveryMode(explicitNoResume: false, priorShutdown: prior), dirty ? .dirty : .clean)
                XCTAssertEqual(read(ownSnapshot), expected, "snapshot and shutdown set must describe the same app")
                XCTAssertEqual(read(".c11/runtime/relaunch.\(layout.destBundleIdentifier).json"), "selected relaunch")
                let absent = dirty
                    ? ShutdownSentinel.cleanURL(bundleId: layout.destBundleIdentifier, directory: destinationRuntime)
                    : ShutdownSentinel.dirtyURL(bundleId: layout.destBundleIdentifier, directory: destinationRuntime)
                XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(absent).path), "the other app's opposite marker is never mixed in")
                XCTAssertEqual(try preservedManifest(), source)
            }
        }
    }

    func testOwnShutdownSetNeverMixesWithLegacyMarkers() throws {
        try checkSnapshotAndShutdownSetStayTogether(legacyLatest: false)
    }

    func testLegacyShutdownSetNeverMixesWithOwnMarkers() throws {
        try checkSnapshotAndShutdownSetStayTogether(legacyLatest: true)
    }

    func testSourceAdditionsAndDeletionsInvalidateTheSwitchedCopy() throws {
        for folderIndex in layout.switchedFolders.indices {
            try resetForReconciliation()
            let folder = layout.switchedFolders[folderIndex]
            // Support's carried entries are explicit; the other three trees carry
            // their own documented files. Keep the fixture inside that contract.
            let suffix = ["workspaces/W1/delete.msg", "claude-hook-sessions.json", "delete.json", "agents/delete.md"][folderIndex]
            let source = folder.source + "/" + suffix
            let destination = folder.path + "/" + suffix
            try write(source, "removed after switch")
            try interrupt(at: "c_switch", alive: false)
            try FileManager.default.removeItem(at: layout.url(source))
            let kept = try preservedManifest()
            try finishReconciliation(alive: false)
            XCTAssertNil(read(destination), "deleted source must not survive: \(source)")
            XCTAssertEqual(try preservedManifest(), kept)
        }
        // A source tree absent while staging can appear after the complete switch.
        try resetForReconciliation()
        try interrupt(at: "c_switch", alive: false)
        try write(".c11h-snapshots/new.json", "created after switch")  // c11-2.0:legacy
        try finishReconciliation(alive: false)
        XCTAssertEqual(read(".c11-snapshots/new.json"), "created after switch")
    }

    func testDirectRetryRefreshesDefaultsAndBrowserData() throws {
        try resetForReconciliation(adopted: false)
        try interrupt(at: "c_switch", alive: false)
        store["com.stage11.c11h"]?["theme.active.light"] = "legacy changed after switch"  // c11-2.0:legacy
        try write("Library/WebKit/com.stage11.c11h/WebsiteDataStore/x/blob", "new cookies")  // c11-2.0:legacy
        let source = try preservedManifest()
        try finishReconciliation(alive: false)
        XCTAssertEqual(store["com.stage11.c11"]?["theme.active.light"] as? String, "legacy changed after switch")
        XCTAssertEqual(read("Library/WebKit/com.stage11.c11/WebsiteDataStore/x/blob"), "new cookies")
        XCTAssertEqual(try preservedManifest(), source)
    }

    private enum ObservedCase: CaseIterable {
        case linkAndStage, missingWithAside, missingWithStage, realWithAside, realWithoutAside
        case linkWithoutStage, missingWithoutStage
    }

    private func arrangeObservedCase(_ observed: ObservedCase, pathIndex: Int) throws {
        let folder = layout.switchedFolders[pathIndex]
        let final = layout.url(folder.path)
        let stage = URL(fileURLWithPath: final.path + C11Migration.stagingSuffix)
        let aside = URL(fileURLWithPath: final.path + C11Migration.asideSuffix)
        let fm = FileManager.default
        switch observed {
        case .linkAndStage: break
        case .missingWithAside:
            try fm.moveItem(at: final, to: aside)
        case .missingWithStage:
            try fm.removeItem(at: final)
        case .realWithAside:
            try fm.moveItem(at: final, to: aside)
            try fm.moveItem(at: stage, to: final)
        case .realWithoutAside:
            try fm.removeItem(at: final)
            try fm.moveItem(at: stage, to: final)
        case .linkWithoutStage:
            try fm.removeItem(at: stage)
        case .missingWithoutStage:
            try fm.removeItem(at: final)
            try fm.removeItem(at: stage)
        }
    }

    private func checkObservedLayoutMatrix(pathIndex: Int) throws {
        for observed in ObservedCase.allCases {
            for alive in [false, true] {
                try resetForReconciliation()
                try interrupt(at: "c_stage", alive: false)
                try arrangeObservedCase(observed, pathIndex: pathIndex)
                // The old executor trusts these flags even when the disk says
                // otherwise. Keep the lying journal as an explicit regression input.
                var state = try XCTUnwrap(try C11MigrationState.load(home: home))
                state.steps["c_stage"] = .done
                state.steps["c_switch"] = .done
                try state.write(home: home)
                let source = try preservedManifest()
                try finishReconciliation(alive: alive)
                try assertReconciled(adopted: alive, mail: "mail",
                                     context: "\(observed), path=\(pathIndex), alive=\(alive)")
                XCTAssertEqual(try preservedManifest(), source)
            }
        }
    }

    func testObservedLayoutMatrixSupport() throws { try checkObservedLayoutMatrix(pathIndex: 0) }
    func testObservedLayoutMatrixHome() throws { try checkObservedLayoutMatrix(pathIndex: 1) }
    func testObservedLayoutMatrixSnapshots() throws { try checkObservedLayoutMatrix(pathIndex: 2) }
    func testObservedLayoutMatrixConfig() throws { try checkObservedLayoutMatrix(pathIndex: 3) }

    func testUnownedFinalObjectsArePreservedForEitherTarget() throws {
        for pathIndex in layout.switchedFolders.indices {
            for alive in [false, true] {
                for kind in ["file", "directory", "wrong-link"] {
                    try resetForReconciliation()
                    try interrupt(at: "c_stage", alive: false)
                    let final = layout.url(layout.switchedFolders[pathIndex].path)
                    try FileManager.default.removeItem(at: final)
                    switch kind {
                    case "file": try Data("unowned file".utf8).write(to: final)
                    case "directory":
                        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
                        try Data("unowned contents".utf8).write(to: final.appendingPathComponent("operator-data"))
                    default:
                        try FileManager.default.createSymbolicLink(atPath: final.path, withDestinationPath: "unowned-target")
                    }
                    let source = try preservedManifest()
                    let before = try manifest()
                    XCTAssertThrowsError(try launch(alive: alive), "\(pathIndex), \(kind), alive=\(alive)")
                    let after = try manifest()
                    let prefix = layout.switchedFolders[pathIndex].path
                    XCTAssertEqual(after.filter { $0.key == prefix || $0.key.hasPrefix(prefix + "/") },
                                   before.filter { $0.key == prefix || $0.key.hasPrefix(prefix + "/") })
                    XCTAssertEqual(try preservedManifest(), source)
                    XCTAssertNotEqual(try C11MigrationState.load(home: home)?.phase, .converged)
                }
            }
        }
    }

    func testLegacyDoneJournalRecoversPostSwitchAndHalfRollbackFromDisk() throws {
        for halfRollback in [false, true] {
            for alive in [false, true] {
                for changed in [false, true] {
                    try resetForReconciliation()
                    try interrupt(at: "c_switch", alive: false)
                    if halfRollback {
                        for index in [0, 1] {
                            let final = layout.url(layout.switchedFolders[index].path)
                            let stage = URL(fileURLWithPath: final.path + C11Migration.stagingSuffix)
                            let aside = URL(fileURLWithPath: final.path + C11Migration.asideSuffix)
                            try FileManager.default.moveItem(at: final, to: stage)
                            if index == 0 { try FileManager.default.moveItem(at: aside, to: final) }
                            else { try FileManager.default.removeItem(at: aside) }
                        }
                    }
                    // Construct the actual old representation: no intent target or
                    // carried directory provenance, but an allegedly done switch.
                    for folder in layout.switchedFolders {
                        for candidate in [layout.url(folder.path), URL(fileURLWithPath: layout.url(folder.path).path + C11Migration.stagingSuffix)] {
                            guard C11MigrationLayout.isRealDirectory(candidate) else { continue }
                            try FileManager.default.removeItem(at: candidate.appendingPathComponent(".c11-migration-stage.json"))
                        }
                    }
                    var state = try XCTUnwrap(try C11MigrationState.load(home: home))
                    state.target = nil
                    state.steps["c_stage"] = .done
                    state.steps["c_switch"] = .done
                    try state.write(home: home)
                    if changed { try write(legacyMail, "changed after old executor stopped") }
                    let source = try preservedManifest()
                    let expected = try XCTUnwrap(read(legacyMail))
                    try finishReconciliation(alive: alive)
                    try assertReconciled(adopted: alive, mail: expected,
                                         context: "legacy halfRollback=\(halfRollback), alive=\(alive), changed=\(changed)")
                    XCTAssertEqual(try preservedManifest(), source)
                }
            }
        }
    }

    func testInterruptedIntentAndCleanupReconcileBeforePublishing() throws {
        // The before/after move cases above cover individual paths. These cover
        // the intent that precedes them, global cleanup and phase publication.
        let points = ["stage.intent", "c_stage", "c_defaults", "c_switch", "converged.commit.before"]
            + (0..<4).flatMap { ["cleanup.\($0).before", "cleanup.\($0).after"] }
        for point in points {
            for alive in [false, true] {
                try resetForReconciliation()
                try interrupt(at: point, alive: false)
                try write(legacyMail, "updated after \(point)")
                let source = try preservedManifest()
                try finishReconciliation(alive: alive)
                try assertReconciled(adopted: alive, mail: "updated after \(point)", context: point)
                XCTAssertEqual(try preservedManifest(), source)
            }
        }
        for point in ["rollback.intent", "adopted.commit.before", "adopted.commit.after"] {
            for alive in [false, true] {
                try resetForReconciliation()
                try interrupt(at: "c_switch", alive: false)
                try interrupt(at: point, alive: true)
                try write(legacyMail, "updated during rollback")
                let source = try preservedManifest()
                try finishReconciliation(alive: alive)
                try assertReconciled(adopted: alive, mail: "updated during rollback", context: point)
                XCTAssertEqual(try preservedManifest(), source)
            }
        }
    }

    func testCommittedConvergenceKeepsItsOwnNewerWorld() throws {
        try resetForReconciliation()
        try launch(alive: false)
        try write(migratedMail, "c11 authoritative mail")
        try write(legacyMail, "legacy changed after commit")
        let before = try manifest()
        for alive in [false, true] {
            try launch(alive: alive)
            try assertReconciled(adopted: false, mail: "c11 authoritative mail", context: "already committed")
            XCTAssertEqual(try manifest(), before)
        }
    }

    func testPostCommitInterruptionNeverReimportsTheLegacyWorld() throws {
        for adopted in [false, true] {
            try resetForReconciliation(adopted: adopted)
            try interrupt(at: "converged.commit.after", alive: false)
            XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .converged)
            try write(legacyMail, "legacy changed after the commit")
            try launch(alive: true)
            try assertReconciled(adopted: false, mail: "mail", context: "post-commit interruption")
            XCTAssertEqual(store["com.stage11.c11"]?[C11MigrationExecutor.originKey] as? String, "both",
                           "the commit boundary must not lose the first-run origin")
        }
    }

    func testCommittedPhaseNeverAcceptsAMissingDirectory() throws {
        for pathIndex in layout.switchedFolders.indices {
            try resetForReconciliation()
            try launch(alive: false)
            let final = layout.url(layout.switchedFolders[pathIndex].path)
            // Retain the contents elsewhere: an external move must not be mistaken
            // for a complete migration merely because the record says converged.
            let retained = URL(fileURLWithPath: final.path + ".test-retained")
            try FileManager.default.moveItem(at: final, to: retained)
            XCTAssertThrowsError(try launch(alive: false), "missing \(pathIndex) must fail closed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
            XCTAssertTrue(C11MigrationLayout.isRealDirectory(retained))
        }
    }

    // MARK: Names and keys

    func testNamesAndKeysFollowTheDestination() {
        for key in ["window.primaryWindowId", "sidebar.backgroundDark", "tips.shown", "whatsDifferent.shownVersion",
                    "shards.enabled", "massSignalEnd.autoResume", "chaos.rootPath", "appInstallID"] {
            XCTAssertEqual(C11MigrationDefaults.renamedKey("c11h." + key), "c11." + key)  // c11-2.0:legacy
        }
        XCTAssertEqual(C11MigrationDefaults.renamedKey("theme.active.light"), "theme.active.light")
        XCTAssertEqual(C11MigrationExecutor.rehomeSessionName("c11h", from: "c11h", to: "c11"), "c11")  // c11-2.0:legacy
        XCTAssertEqual(C11MigrationExecutor.rehomeSessionName("c11h-s8", from: "c11h", to: "c11"), "c11-s8")  // c11-2.0:legacy
        XCTAssertNil(C11MigrationExecutor.rehomeSessionName("c11h-s9", from: "c11h", to: "c11"))  // c11-2.0:legacy
        XCTAssertNil(C11MigrationExecutor.rehomeSessionName("c11h-staging-x", from: "c11h", to: "c11"))  // c11-2.0:legacy
        // A tagged build's own pool is `c11-<tag>[-sN]`; its convergence targets that.
        let tagged = HCShardID.base(tag: "c20-mig")
        XCTAssertEqual(tagged, "c11-c20-mig")
        XCTAssertEqual(C11MigrationExecutor.rehomeSessionName("c11h-s3", from: "c11h", to: tagged), "c11-c20-mig-s3")  // c11-2.0:legacy
        XCTAssertEqual(C11MigrationExecutor.rehomeSessions(#"{"hcSession":"c11h-s3"}"#, from: "c11h", to: tagged).0,  // c11-2.0:legacy
                       #"{"hcSession":"c11-c20-mig-s3"}"#)
    }

    // MARK: hc

    private func helperFixture(_ bundle: URL, bytes: String) throws -> String {
        let helper = HCCoreBinary.helperURL(bundle: bundle)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: helper)
        let sha = SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
        let manifest = HCCoreBinary.Manifest(version: "0.1.16", protocolGeneration: 1,
                                             sourceSHA256: String(repeating: "a", count: 64), executableSHA256: sha)
        let url = HCCoreBinary.manifestURL(bundle: bundle)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: url)
        return sha
    }

    func testAdoptedNamespaceNamesLegacySessionsAndAcceptsRetainedHelpers() throws {
        let app = home.appendingPathComponent("Applications/c11h.app", isDirectory: true)  // c11-2.0:legacy
        let retained = HCCoreBinary.retainedRootURL(bundle: app).appendingPathComponent("c11h-h14.app", isDirectory: true)  // c11-2.0:legacy
        let shaCurrent = try helperFixture(app, bytes: "h15 helper")
        let shaRetained = try helperFixture(retained, bytes: "h14 helper")
        let trust = HCRetainedTrust(shipped: [shaCurrent, shaRetained], team: nil, satisfies: { _, _ in false })
        let ns = C11AdoptionRecord(owner: "com.stage11.c11", servingApp: app.path)
        let configuration = try HCLaunchPolicy.configuration(home: home, tag: "c20-mig", shard: 3, inherited: [:],
                                                             binary: HCCoreBinary.external(home: home, pin: HCCoreBinary.externalPin),
                                                             retainedTrust: trust, namespace: ns)
        XCTAssertEqual(configuration.session, "c11h-s3")  // c11-2.0:legacy
        XCTAssertEqual(configuration.socketURL.path, home.appendingPathComponent(".local/share/c11h/run/c11h-s3.sock").path)  // c11-2.0:legacy
        let accepted = Set(configuration.servingBinaries.map(\.executableURL.path))
        XCTAssertTrue(accepted.contains(HCCoreBinary.helperURL(bundle: app).path))
        XCTAssertTrue(accepted.contains(HCCoreBinary.helperURL(bundle: retained).path), "a retained c11h helper serves adopted cores")  // c11-2.0:legacy
        let untrusted = try HCLaunchPolicy.configuration(home: home, tag: nil, shard: 3, inherited: [:],
                                                         binary: HCCoreBinary.external(home: home, pin: HCCoreBinary.externalPin),
                                                         retainedTrust: HCRetainedTrust(shipped: [], team: nil, satisfies: { _, _ in false }),
                                                         namespace: ns)
        XCTAssertFalse(untrusted.servingBinaries.contains { $0.executableURL.path.contains("c11h-h14") })  // c11-2.0:legacy
    }

    /// Remote: an adopted session's c11h-era kit is found where it was installed.  c11-2.0:legacy
    func testAdoptedRemoteKitPaths() {
        let adopted = C11AdoptionRecord(owner: "com.stage11.c11")
        XCTAssertEqual(C11Relay.Manifest.relativePaths(session: "c11h-s3", adoption: adopted),  // c11-2.0:legacy
                       [".local/share/c11/relay/c11h-s3/manifest.json", ".local/share/c11h/relay/c11h-s3/manifest.json"])  // c11-2.0:legacy
        XCTAssertEqual(C11Relay.Manifest.relativePaths(session: "c11-s3", adoption: nil),
                       [".local/share/c11/relay/c11-s3/manifest.json"])
    }

    // MARK: Repair 2

    /// Rule A: a dead terminal bound to a core 2.0 will never run restores as a
    /// fresh panel the production resolver can create, not one stuck pending.
    func testDeadBoundTerminalConvergesToAFreshPanel() async throws {
        try seedLegacy()
        let panel = UUID(), creation = UUID()
        let legacyHC = home.appendingPathComponent("Library/Application Support/c11h/HC/c11h-s3", isDirectory: true)  // c11-2.0:legacy
        try FileManager.default.removeItem(at: legacyHC.appendingPathComponent("intent.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacyHC.path)
        let store = HCCreationIntentStore(directory: legacyHC)
        _ = try await store.claim(HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh), creationID: creation,
                                                  argv: ["/bin/zsh"]),
                                  coreID: "deadcore", process: HCProcessIdentity(pid: 42, startTimeMicroseconds: 100))
        try await store.markTransmitted(panelID: panel, creationID: creation)
        let key = HCTerminalKey(owningCoreID: "deadcore", localAddress: "t7")
        try await store.bind(panelID: panel, creationID: creation, key: key)
        let p = panel.uuidString, c = creation.uuidString
        try write(legacySnapshotPath, #"{"version":1,"windows":[{"panels":[{"id":"\#(p)","type":"terminal","terminal":{"workingDirectory":"/tmp","hcSession":"c11h-s3","hcIdentity":{"panelID":"\#(p)","creationID":"\#(c)","persistence":"persistent","origin":"restored","key":{"owningCoreID":"deadcore","localAddress":"t7"}}}}]}]}"#)  // c11-2.0:legacy

        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let newCore = HCInventorySnapshot(readiness: .ready(revision), revision: revision, records: [:])
        // Control: the copied identity and intent, against 2.0's fresh core, never settle.
        let old = HCPanelIdentity(panelID: panel, key: key, persistence: .persistent, creationID: creation, origin: .restored)
        let oldIntent = try await store.read(panelID: panel)
        guard case .unresolved(_, .creationPending) = HCLifecycleResolver.resolve(old, snapshot: newCore, intent: oldIntent) else {
            return XCTFail("control: a bound intent on a dead core stays pending")
        }

        try launch(alive: false)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(ownSnapshot))) as? [String: Any]
        let windows = try XCTUnwrap(root?["windows"] as? [[String: Any]])
        let terminal = try XCTUnwrap(((windows[0]["panels"] as? [[String: Any]])?[0])?["terminal"])
        let saved = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self,
                                             from: JSONSerialization.data(withJSONObject: terminal))
        XCTAssertEqual(saved.workingDirectory, "/tmp")
        let restored = try XCTUnwrap(try saved.restoredHCIdentity(panelID: panel, backendActive: true))
        let carried = home.appendingPathComponent("Library/Application Support/c11/HC", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: carried.appendingPathComponent("c11h-s3").path))  // c11-2.0:legacy
        XCTAssertFalse(FileManager.default.fileExists(atPath: carried.appendingPathComponent("c11-s3").path))
        guard case .new = HCLifecycleResolver.resolve(restored, snapshot: newCore, intent: nil) else {
            return XCTFail("a settled dead terminal gets a fresh terminal")
        }
        let kept = try await store.read(panelID: panel)
        XCTAssertNotNil(kept, "c11h's own intent is untouched")  // c11-2.0:legacy
    }

    func testConvergencePreservesRemoteIntentsAndTheirReplayLedger() async throws {
        for adopted in [false, true] {
            try resetForReconciliation(adopted: false, keepOneX: false)
            let sourceHC = layout.sourceSupport.appendingPathComponent("HC/c11h-s3")  // c11-2.0:legacy
            try FileManager.default.removeItem(at: sourceHC.appendingPathComponent("intent.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sourceHC.path)
            let sourceStore = HCCreationIntentStore(directory: sourceHC)
            let localPanel = UUID(), remotePanel = UUID(), olderRemotePanel = UUID()
            let local = HCCreateRequest(identity: HCPanelIdentity(panelID: localPanel, origin: .fresh),
                                        creationID: UUID(), argv: ["fixture-shell"])
            let remote = HCCreateRequest(identity: HCPanelIdentity(panelID: remotePanel, origin: .fresh),
                                         creationID: UUID(), argv: ["fixture-shell"], machine: "fixture-remote")
            // Old records have no machine field; the saved remote panel remains
            // authoritative even though its local core is proven dead.
            let olderRemote = HCCreateRequest(identity: HCPanelIdentity(panelID: olderRemotePanel, origin: .fresh),
                                              creationID: UUID(), argv: ["fixture-shell"])
            let process = HCProcessIdentity(pid: 42, startTimeMicroseconds: 100)
            for request in [local, remote, olderRemote] {
                _ = try await sourceStore.claim(request, coreID: "old-core", process: process)
                try await sourceStore.markTransmitted(panelID: request.identity.panelID, creationID: request.creationID)
                try await sourceStore.bind(panelID: request.identity.panelID, creationID: request.creationID,
                                            key: HCTerminalKey(owningCoreID: "old-core", localAddress: request.identity.panelID.uuidString))
            }
            let remoteBefore = try await sourceStore.read(panelID: remotePanel)
            let olderRemoteBefore = try await sourceStore.read(panelID: olderRemotePanel)
            try write(legacySnapshotPath, #"{"version":1,"panels":[{"id":"\#(localPanel.uuidString)","terminal":{"hcSession":"c11h-s3"}},{"id":"\#(olderRemotePanel.uuidString)","terminal":{"hcSession":"c11h-s3","hcRemoteTarget":{"machine":"fixture-remote"}}}]}"#)  // c11-2.0:legacy
            let tagged = "Library/Application Support/c11h/HC/c11h-tagged-fixture/creation-intents.json"  // c11-2.0:legacy
            try write(tagged, "tagged ledger is not interpreted")
            if adopted { try launch(alive: true) }
            let originals = try preservedManifest()
            let sourceLedger = try Data(contentsOf: sourceHC.appendingPathComponent("creation-intents.json"))
            try launch(alive: false)
            let carriedHC = layout.destSupport.appendingPathComponent("HC/c11h-s3")  // c11-2.0:legacy
            let carriedStore = HCCreationIntentStore(directory: carriedHC)
            let actualRemote = try await carriedStore.read(panelID: remotePanel)
            let actualOlderRemote = try await carriedStore.read(panelID: olderRemotePanel)
            let actualLocal = try await carriedStore.read(panelID: localPanel)
            XCTAssertEqual(actualRemote, remoteBefore, "machine-tagged remote intent survives without a snapshot panel")
            XCTAssertEqual(actualOlderRemote, olderRemoteBefore, "older remote intent survives by saved panel target")
            XCTAssertNil(actualLocal, "the dead local intent must not block a new local terminal")
            let carriedLedger = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: carriedHC.appendingPathComponent("creation-intents.json"))) as? [String: Any])
            let sourceDocument = try XCTUnwrap(try JSONSerialization.jsonObject(with: sourceLedger) as? [String: Any])
            XCTAssertEqual(carriedLedger["usedCreationIDs"] as? [String], sourceDocument["usedCreationIDs"] as? [String],
                           "all consumed creation IDs survive, including the removed local intent")
            do {
                _ = try await carriedStore.claim(local, coreID: "new-core", process: process)
                XCTFail("a consumed local creation ID must remain rejected after migration")
            } catch {
                XCTAssertEqual(error as? HCUnavailableReason, .creationPending)
            }
            XCTAssertEqual(read("Library/Application Support/c11/HC/c11h-tagged-fixture/creation-intents.json"),  // c11-2.0:legacy
                           "tagged ledger is not interpreted")
            XCTAssertEqual(try Data(contentsOf: sourceHC.appendingPathComponent("creation-intents.json")), sourceLedger)
            XCTAssertEqual(try preservedManifest(), originals, "all legacy snapshot, intent and other bytes remain unchanged")
        }
    }

    /// C11H-391: links an adopted c11 2.0 makes live in its own links session
    /// (`c11`), which convergence never waits on and carries as it is: a
    /// non-empty `c11/machines.json` leaves the adopted world dead, the links
    /// session's intents (`HC/c11`) come through unchanged, and a remote panel
    /// saved in that session keeps it, so after convergence it is shard 0's.
    func testTheLinksSessionNeverHoldsAdoptionAndIsCarriedAsItIs() async throws {
        try resetForReconciliation(adopted: false, keepOneX: false)
        try write(".local/state/herdr-core/c11/machines.json", #"[{"id":"far"}]"#)
        guard case .dead = C11MigrationLaunch.linkedMachineLiveness(layout) else {
            return XCTFail("the links session's machines never hold adoption")
        }
        let linksHC = layout.sourceSupport.appendingPathComponent("HC/c11")
        try FileManager.default.createDirectory(at: linksHC, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let store = HCCreationIntentStore(directory: linksHC)
        let panel = UUID()
        let remote = HCCreateRequest(identity: HCPanelIdentity(panelID: panel, origin: .fresh),
                                     creationID: UUID(), argv: ["fixture-shell"], machine: "far")
        let process = HCProcessIdentity(pid: 42, startTimeMicroseconds: 100)
        _ = try await store.claim(remote, coreID: "links-core", process: process)
        try await store.markTransmitted(panelID: panel, creationID: remote.creationID)
        try await store.bind(panelID: panel, creationID: remote.creationID,
                             key: HCTerminalKey(owningCoreID: "far-core", localAddress: "t1"))
        let before = try await store.read(panelID: panel)
        try launch(alive: true)
        try launch(alive: false)
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .converged)
        let carried = try await HCCreationIntentStore(directory: layout.destSupport.appendingPathComponent("HC/c11")).read(panelID: panel)
        XCTAssertEqual(carried, before, "the links session's remote intent is carried as it is")
        let saved = #"{"version":1,"panels":[{"id":"\#(panel.uuidString)","terminal":{"hcSession":"c11","hcRemoteTarget":{"machine":"far"}}}]}"#
        let (settled, count) = try C11MigrationExecutor.settleDeadTerminals(Data(saved.utf8), legacyBase: "c11h")  // c11-2.0:legacy
        XCTAssertEqual(count, 0)
        XCTAssertTrue(String(decoding: settled, as: UTF8.self).contains(#""hcSession":"c11""#), "its saved session is kept")
    }

    /// Rule B: the operator went back to c11h between convergence launches. The  c11-2.0:legacy
    /// world is alive again: roll back to adoption, then converge later with fresh state.
    func testResumedConvergenceRollsBackWhenTheWorldIsAliveAgain() throws {
        try seedLegacy()
        try launch(alive: true)
        XCTAssertThrowsError(try launch(alive: false) { if $0 == "c_switch_mid" { throw C11MigrationExecutor.Failure.injected($0) } })
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .converging)
        try write("Library/Application Support/c11h/workspaces/W1/mailboxes/_outbox/back.msg", "written back in c11h")  // c11-2.0:legacy
        XCTAssertEqual(try plan(alive: true), .rollBackConvergence)
        try launch(alive: true)
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .adopted)
        for folder in layout.switchedFolders {
            XCTAssertEqual(C11MigrationLayout.linkTarget(layout.url(folder.path)), folder.target, folder.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.url(folder.path).path + C11Migration.stagingSuffix))
        }
        XCTAssertEqual(read("Library/Application Support/c11/workspaces/W1/mailboxes/_outbox/back.msg"), "written back in c11h")  // c11-2.0:legacy
        try launch(alive: false)
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .converged)
        XCTAssertTrue(C11MigrationLayout.isRealDirectory(layout.destSupport))
        XCTAssertEqual(read("Library/Application Support/c11/workspaces/W1/mailboxes/_outbox/back.msg"), "written back in c11h")  // c11-2.0:legacy
    }

    /// Rule B: the source changed between launches after the stage was built:
    /// the stage is rebuilt before the switch.
    func testResumedConvergenceRebuildsAStaleStage() throws {
        try seedLegacy()
        try launch(alive: true)
        XCTAssertThrowsError(try launch(alive: false) { if $0 == "c_stage" { throw C11MigrationExecutor.Failure.injected($0) } })
        try write("Library/Application Support/c11h/workspaces/W1/mailboxes/_outbox/late.msg", "after the stage")  // c11-2.0:legacy
        XCTAssertEqual(try plan(alive: false), .converge(keepOneXAside: false, fromAdoption: true))
        try launch(alive: false)
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .converged)
        XCTAssertEqual(read("Library/Application Support/c11/workspaces/W1/mailboxes/_outbox/late.msg"), "after the stage")
    }

    /// The liveness probe stays inside its budget with many dead sockets, and
    /// runs only when the plan needs it.
    func testLivenessProbeBudgetAndWhenItRuns() throws {
        let run = home.appendingPathComponent(".local/share/c11h/run", isDirectory: true)  // c11-2.0:legacy
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        var names = ["c11h"] + (1...8).map { "c11h-s\($0)" }  // c11-2.0:legacy
        names += (1...8).map { "c11h-s\($0).holder.abcd" }  // c11-2.0:legacy
        for name in names {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let path = Array(run.appendingPathComponent(name + ".sock").path.utf8)
            withUnsafeMutableBytes(of: &addr.sun_path) { buffer in for (i, b) in path.enumerated() { buffer[i] = b } }
            let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            XCTAssertEqual(bound, 0)
            close(fd)  // a socket file with nobody listening, as after a reboot
        }
        let started = Date()
        XCTAssertFalse(C11MigrationLaunch.coresAlive(layout))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.6, "\(names.count) dead sockets stay inside the 0.4 s budget")

        var state = C11MigrationState(owner: "com.stage11.c11", phase: .converged, origin: "c11h", startedAt: "t", updatedAt: "t")  // c11-2.0:legacy
        XCTAssertFalse(C11MigrationLaunch.needsLivenessProbe(record: state, legacyState: true, convergeEnabled: true), "a converged launch never probes")
        state.phase = .adopted
        XCTAssertTrue(C11MigrationLaunch.needsLivenessProbe(record: state, legacyState: true, convergeEnabled: true))
        XCTAssertFalse(C11MigrationLaunch.needsLivenessProbe(record: state, legacyState: true, convergeEnabled: false),
                       "with convergence off nothing needs the answer")
        state.phase = .converging
        XCTAssertTrue(C11MigrationLaunch.needsLivenessProbe(record: state, legacyState: false, convergeEnabled: true))
        XCTAssertTrue(C11MigrationLaunch.needsLivenessProbe(record: nil, legacyState: true, convergeEnabled: true))
        XCTAssertFalse(C11MigrationLaunch.needsLivenessProbe(record: nil, legacyState: false, convergeEnabled: true))
        XCTAssertEqual(C11MigrationLaunch.destinationBase(environment: [:], bundleIdentifier: "com.stage11.c11"), "c11")
        XCTAssertEqual(C11MigrationLaunch.destinationBase(environment: [:], bundleIdentifier: "com.stage11.c11.debug.c20.mig"), "c11-c20-mig")
    }

    // C11H-283: the visible gate keeps main free while its worker touches only fixtures.
    @MainActor
    func testMigrationGateWorkerServicesMainAndReturnsFailure() async {
        enum FixtureError: Error { case stopped }
        let mainServiced = expectation(description: "main remains available")
        let completed = expectation(description: "worker failure arrives on main")
        let releaseWorker = DispatchSemaphore(value: 0)
        C11MigrationGate.runWorker({
            XCTAssertFalse(Thread.isMainThread, "migration scans and copies run off main")
            DispatchQueue.main.async {
                mainServiced.fulfill()
                releaseWorker.signal()
            }
            XCTAssertEqual(releaseWorker.wait(timeout: .now() + 1), .success,
                           "main must run while the migration worker is busy")
            throw FixtureError.stopped
        }) { result in
            XCTAssertTrue(Thread.isMainThread)
            guard case .failure(FixtureError.stopped) = result else {
                XCTFail("the gate must display a worker failure, not reopen normal startup")
                completed.fulfill()
                return
            }
            completed.fulfill()
        }
        await fulfillment(of: [mainServiced, completed], timeout: 3)
    }

    @MainActor
    func testMigrationWorkerDefaultsStayOnMain() async {
        let completed = expectation(description: "fixture defaults carried through gate")
        var readCount = 0
        var writeCount = 0
        let fixture = C11MigrationDefaults(read: { domain in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(domain, "fixture-source")
            readCount += 1
            return ["fixture-setting": "kept"]
        }, replace: { domain, values in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(domain, "fixture-destination")
            XCTAssertEqual(values["fixture-setting"] as? String, "kept")
            writeCount += 1
        })
        let defaults = C11MigrationLaunch.mainThreadDefaults(fixture)
        C11MigrationGate.runWorker({
            XCTAssertFalse(Thread.isMainThread)
            let values = defaults.read("fixture-source") ?? [:]
            defaults.replace("fixture-destination", values)
        }) { result in
            if case .failure(let error) = result { XCTFail("unexpected worker failure: \(error)") }
            XCTAssertEqual(readCount, 1)
            XCTAssertEqual(writeCount, 1)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 3)
    }

    func testMigrationGateLauncherPropagatesSpawnFailure() {
        enum FixtureError: Error { case spawn }
        var called = false
        XCTAssertThrowsError(try C11MigrationLaunch.launchAfterParentExit(
            executable: "/fixture/c11", arguments: ["--c11-migration-gate", "reconcile"], parentPID: 42,
            start: { process in
                called = true
                XCTAssertEqual(process.executableURL?.path, "/bin/sh")
                XCTAssertEqual(Array((process.arguments ?? []).suffix(3)),
                               ["/fixture/c11", "--c11-migration-gate", "reconcile"])
                throw FixtureError.spawn
            })) { error in
                guard case FixtureError.spawn = error else { return XCTFail("spawn error was swallowed") }
            }
        XCTAssertTrue(called)
    }

    func testMigrationSocketProbeDistinguishesLiveDeadAndUnknown() throws {
        let path = home.appendingPathComponent("probe.sock").path
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        var open = true
        defer { if open { close(descriptor) } }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(descriptor, 4), 0)
        XCTAssertEqual(C11MigrationLaunch.socketLiveness(path, deadline: ProcessInfo.processInfo.systemUptime + 0.1), .alive)
        close(descriptor)
        open = false
        XCTAssertEqual(C11MigrationLaunch.socketLiveness(path, deadline: ProcessInfo.processInfo.systemUptime + 0.1), .dead,
                       "a stale socket refuses after its fixture listener closes")
        try FileManager.default.removeItem(atPath: path)
        try Data("not a socket".utf8).write(to: URL(fileURLWithPath: path))
        guard case .unknown = C11MigrationLaunch.socketLiveness(path, deadline: ProcessInfo.processInfo.systemUptime + 0.1) else {
            return XCTFail("an invalid endpoint is not proven dead")
        }
        XCTAssertTrue(C11MigrationLaunch.connects(path), "compatibility bridge preserves uncertain endpoints")
    }

    func testLivenessUnknownNeverBecomesDeath() throws {
        guard case .dead = C11MigrationLaunch.adoptedWorldLiveness(layout) else {
            return XCTFail("missing core and link roots are known absent")
        }
        let ownMachines = ".local/state/herdr-core/c11h-s3/machines.json"  // c11-2.0:legacy
        try write(ownMachines, "{")
        guard case .unknown = C11MigrationLaunch.linkedMachineLiveness(layout) else {
            return XCTFail("an unreadable linked-machine inventory is not proof of no links")
        }
        XCTAssertTrue(C11MigrationLaunch.adoptedWorldAlive(layout), "the bool compatibility seam must hold adoption on uncertainty")
        try write(ownMachines, "[]")
        guard case .dead = C11MigrationLaunch.linkedMachineLiveness(layout) else {
            return XCTFail("an empty owned link list is known absent")
        }
        try write(ownMachines, #"[{"id":"fixture-remote"}]"#)
        guard case .alive = C11MigrationLaunch.adoptedWorldLiveness(layout) else {
            return XCTFail("an owned machine link keeps its world adopted without a local core")
        }
        try write(ownMachines, "[]")
        try write(".local/state/herdr-core/c11h-tagged-fixture/machines.json", "{")  // c11-2.0:legacy
        guard case .dead = C11MigrationLaunch.linkedMachineLiveness(layout) else {
            return XCTFail("another tagged build's malformed inventory is outside this namespace")
        }
        try write(".local/share/c11h/run", "not a directory")  // c11-2.0:legacy
        guard case .unknown = C11MigrationLaunch.coreLiveness(layout) else {
            return XCTFail("a failed core-directory inventory is not proof of dead terminals")
        }
        XCTAssertTrue(C11MigrationLaunch.coresAlive(layout), "uncertain core inventory must hold adoption")
    }

    /// The normal launch converges; an explicit diagnostic hold still adopts.
    func testConvergenceDefaultsOnAndExplicitZeroHoldsAdoption() throws {
        XCTAssertTrue(C11MigrationPlanner.convergeEnabled(environment: [:]))
        XCTAssertTrue(C11MigrationPlanner.convergeEnabled(environment: ["C11_MIGRATION_CONVERGE": "1"]))
        XCTAssertFalse(C11MigrationPlanner.convergeEnabled(environment: ["C11_MIGRATION_CONVERGE": "0"]))
        converge = false
        try seedLegacy()
        XCTAssertEqual(try plan(alive: false), .adopt(keepOneXAside: false), "no core alive still adopts")
        try launch(alive: false)
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .adopted)
        XCTAssertEqual(try plan(alive: false), .stayAdopted, "an adopted Mac never converges with it off")
        XCTAssertEqual(C11MigrationLayout.linkTarget(layout.destSupport), "c11h")  // c11-2.0:legacy

        // Every record phase, with convergence off.
        var state = C11MigrationState(owner: "com.stage11.c11", phase: .adopting, origin: "c11h", startedAt: "t", updatedAt: "t")  // c11-2.0:legacy
        for alive in [true, false] {
            for (phase, expected) in [(C11MigrationState.Phase.adopting, C11MigrationDecision.adopt(keepOneXAside: false)),
                                      (.adopted, .stayAdopted), (.converged, .alreadyDone),
                                      (.fresh, .alreadyDone), (.inPlace1x, .alreadyDone)] {
                state.phase = phase
                try state.write(home: home)
                XCTAssertEqual(try plan(alive: alive), expected, "\(phase), alive \(alive)")
            }
            state.phase = .converging
            try state.write(home: home)
            guard case .stop = try plan(alive: alive) else { return XCTFail("converging with it off must stop, alive \(alive)") }
        }
    }

    /// An interrupted convergence retried with the explicit diagnostic hold stops
    /// and changes nothing.
    func testInterruptedConvergenceStopsWhenRetriedWithExplicitHold() throws {
        try seedLegacy()
        try launch(alive: true)
        XCTAssertThrowsError(try launch(alive: false) { if $0 == "c_stage" { throw C11MigrationExecutor.Failure.injected($0) } })
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .converging)
        converge = false
        let before = try manifest()
        let decision = try plan(alive: false)
        guard case .stop = decision else { return XCTFail("expected stop, got \(decision)") }
        try launch(alive: false)
        XCTAssertEqual(try manifest(), before, "a stop changes nothing")
        XCTAssertEqual(try C11MigrationState.load(home: home)?.phase, .converging)
    }
}
