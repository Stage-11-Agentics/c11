import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class MailboxLayoutTests: XCTestCase {

    private let stateURL = URL(fileURLWithPath: "/tmp/c11-test-state", isDirectory: true)

    private func stubWorkspace() -> UUID {
        // Fixed UUID keeps the expected path stable across runs.
        UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    }

    // MARK: - Path shape

    func testMailboxesRoot() {
        let ws = stubWorkspace()
        let url = MailboxLayout.mailboxesRoot(state: stateURL, workspaceId: ws)
        XCTAssertEqual(
            url.path,
            "/tmp/c11-test-state/workspaces/\(ws.uuidString)/mailboxes"
        )
    }

    func testOutboxURL() {
        let ws = stubWorkspace()
        let url = MailboxLayout.outboxURL(state: stateURL, workspaceId: ws)
        XCTAssertEqual(
            url.path,
            "/tmp/c11-test-state/workspaces/\(ws.uuidString)/mailboxes/_outbox"
        )
    }

    func testProcessingURL() {
        let ws = stubWorkspace()
        let url = MailboxLayout.processingURL(state: stateURL, workspaceId: ws)
        XCTAssertEqual(url.lastPathComponent, "_processing")
    }

    func testRejectedURL() {
        let ws = stubWorkspace()
        let url = MailboxLayout.rejectedURL(state: stateURL, workspaceId: ws)
        XCTAssertEqual(url.lastPathComponent, "_rejected")
    }

    func testBlobsURL() {
        let ws = stubWorkspace()
        let url = MailboxLayout.blobsURL(state: stateURL, workspaceId: ws)
        XCTAssertEqual(url.lastPathComponent, "blobs")
    }

    func testDispatchLogURL() {
        let ws = stubWorkspace()
        let url = MailboxLayout.dispatchLogURL(state: stateURL, workspaceId: ws)
        XCTAssertEqual(url.lastPathComponent, "_dispatch.log")
        XCTAssertFalse(url.hasDirectoryPath)
    }

    func testInboxURLIsKeyedOnLowercasedTabUUID() {
        let ws = stubWorkspace()
        let panel = UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000BEEF")!
        let url = MailboxLayout.inboxURL(state: stateURL, workspaceId: ws, panelId: panel)
        XCTAssertEqual(
            url.path,
            "/tmp/c11-test-state/workspaces/\(ws.uuidString)/mailboxes/a1b2c3d4-0000-4000-8000-00000000beef"
        )
    }

    func testLegacyInboxURLKeepsSafeTitles() {
        let ws = stubWorkspace()
        XCTAssertEqual(
            MailboxLayout.legacyInboxURL(state: stateURL, workspaceId: ws, panelName: "build watcher")?
                .lastPathComponent,
            "build watcher"
        )
        XCTAssertEqual(
            MailboxLayout.legacyInboxURL(state: stateURL, workspaceId: ws, panelName: "ビルダー")?
                .lastPathComponent,
            "ビルダー"
        )
    }

    /// Titles that could never have been a directory, or that name the tree's
    /// own directories, have no legacy inbox.
    func testLegacyInboxURLRejectsUnsafeAndReservedTitles() {
        let ws = stubWorkspace()
        let long = "MRQ-214 [review]: " + String(repeating: "x", count: 90)
        for title in ["a/b: c", long, "../escape", ".hidden", "", "_outbox", "_read", "blobs"] {
            XCTAssertNil(
                MailboxLayout.legacyInboxURL(state: stateURL, workspaceId: ws, panelName: title),
                title
            )
        }
    }

    func testRecvInboxURLsReadsCanonicalThenExistingLegacy() throws {
        let state = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let ws = stubWorkspace()
        let panel = UUID()

        // No legacy directory on disk: only the canonical inbox.
        XCTAssertEqual(
            MailboxLayout.recvInboxURLs(state: state, workspaceId: ws, panelId: panel, panelName: "watcher"),
            [MailboxLayout.inboxURL(state: state, workspaceId: ws, panelId: panel)]
        )

        let legacy = try XCTUnwrap(
            MailboxLayout.legacyInboxURL(state: state, workspaceId: ws, panelName: "watcher")
        )
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertEqual(
            MailboxLayout.recvInboxURLs(state: state, workspaceId: ws, panelId: panel, panelName: "watcher"),
            [MailboxLayout.inboxURL(state: state, workspaceId: ws, panelId: panel), legacy]
        )
        // Tab UUID unknown (a `--surface` name c11 could not resolve): legacy only.
        XCTAssertEqual(
            MailboxLayout.recvInboxURLs(state: state, workspaceId: ws, panelId: nil, panelName: "watcher"),
            [legacy]
        )
        // A title-unsafe name never yields a legacy path.
        XCTAssertEqual(
            MailboxLayout.recvInboxURLs(state: state, workspaceId: ws, panelId: panel, panelName: "a/b: c"),
            [MailboxLayout.inboxURL(state: state, workspaceId: ws, panelId: panel)]
        )
    }

    func testReadURLIsInsideInbox() {
        let inbox = MailboxLayout.inboxURL(state: stateURL, workspaceId: stubWorkspace(), panelId: UUID())
        XCTAssertEqual(MailboxLayout.readURL(inbox: inbox).deletingLastPathComponent().path, inbox.path)
        XCTAssertEqual(MailboxLayout.readURL(inbox: inbox).lastPathComponent, "_read")
    }

    // MARK: - Filenames

    func testEnvelopeFilename() {
        XCTAssertEqual(
            MailboxLayout.envelopeFilename(id: "01K3A2B7X8PQRTVWYZ0123456J"),
            "01K3A2B7X8PQRTVWYZ0123456J.msg"
        )
    }

    func testTempFilename() {
        XCTAssertEqual(
            MailboxLayout.tempFilename(id: "01K3A2B7X8PQRTVWYZ0123456J"),
            ".01K3A2B7X8PQRTVWYZ0123456J.tmp"
        )
    }

    func testRejectedErrorFilename() {
        XCTAssertEqual(
            MailboxLayout.rejectedErrorFilename(id: "01K3A2B7X8PQRTVWYZ0123456J"),
            "01K3A2B7X8PQRTVWYZ0123456J.err"
        )
    }

    // MARK: - Surface-name validation

    func testRejectsEmpty() {
        XCTAssertThrowsError(try MailboxLayout.validateSurfaceName("")) { error in
            XCTAssertEqual(
                error as? MailboxLayout.Error,
                .invalidSurfaceName(name: "", reason: .empty)
            )
        }
    }

    func testRejectsForwardSlash() {
        XCTAssertThrowsError(try MailboxLayout.validateSurfaceName("nested/path")) { error in
            XCTAssertEqual(
                error as? MailboxLayout.Error,
                .invalidSurfaceName(name: "nested/path", reason: .containsPathSeparator)
            )
        }
    }

    func testRejectsNullByte() {
        let evil = "foo\u{0}bar"
        XCTAssertThrowsError(try MailboxLayout.validateSurfaceName(evil)) { error in
            XCTAssertEqual(
                error as? MailboxLayout.Error,
                .invalidSurfaceName(name: evil, reason: .containsNullByte)
            )
        }
    }

    func testRejectsParentReference() {
        XCTAssertThrowsError(try MailboxLayout.validateSurfaceName("..")) { error in
            XCTAssertEqual(
                error as? MailboxLayout.Error,
                .invalidSurfaceName(name: "..", reason: .parentReference)
            )
        }
        XCTAssertThrowsError(try MailboxLayout.validateSurfaceName(".")) { error in
            XCTAssertEqual(
                error as? MailboxLayout.Error,
                .invalidSurfaceName(name: ".", reason: .parentReference)
            )
        }
    }

    func testRejectsLeadingDot() {
        XCTAssertThrowsError(try MailboxLayout.validateSurfaceName(".hidden")) { error in
            XCTAssertEqual(
                error as? MailboxLayout.Error,
                .invalidSurfaceName(name: ".hidden", reason: .leadingDot)
            )
        }
    }

    func testRejectsOverlongName() {
        // 65 ASCII bytes → over the 64-byte cap.
        let overlong = String(repeating: "x", count: MailboxLayout.maxSurfaceNameBytes + 1)
        XCTAssertThrowsError(try MailboxLayout.validateSurfaceName(overlong)) { error in
            XCTAssertEqual(
                error as? MailboxLayout.Error,
                .invalidSurfaceName(name: overlong, reason: .tooLong)
            )
        }
    }

    func testAcceptsNameAtByteCap() {
        let exactly64 = String(repeating: "x", count: MailboxLayout.maxSurfaceNameBytes)
        XCTAssertNoThrow(try MailboxLayout.validateSurfaceName(exactly64))
    }
}

// MARK: - C11H-439: whose folder the mailbox tree lives in

final class MailboxStateRootTests: XCTestCase {
    private let appSupport = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
    private let temporary = URL(fileURLWithPath: "/private/var/folders/xx/T", isDirectory: true)

    private func resolve(_ environment: [String: String], bundle: String?, isApp: Bool = true,
                         hostsXCTest: Bool = false, existing: Set<String> = []) -> MailboxStateRoot.Resolved {
        MailboxStateRoot.resolve(appSupport: appSupport, environment: environment, bundleIdentifier: bundle,
                                 isApp: isApp, hostsXCTest: hostsXCTest, temporaryDirectory: temporary,
                                 processIdentifier: 4242, isDirectory: { existing.contains($0) })
    }

    func testOnlyTheReleaseChannelsUseTheReleaseFolder() {
        for id in ["com.stage11.c11", "com.stage11.c11.staging", "com.stage11.c11.nightly", nil, "com.example.other"] {
            let resolved = resolve([:], bundle: id)
            XCTAssertEqual(resolved.kind, .release, id ?? "nil")
            XCTAssertEqual(resolved.url.path, appSupport.path + "/c11", id ?? "nil")
        }
    }

    func testDebugAndTaggedBuildsUseTheirOwnFolder() {
        for id in ["com.stage11.c11.debug", "com.stage11.c11.debug.c11-439", "com.stage11.c11.nightly.rc", "com.stage11.c11.staging.x"] {
            let resolved = resolve([:], bundle: id)
            XCTAssertEqual(resolved.kind, .build(id))
            XCTAssertEqual(resolved.url.path, appSupport.path + "/c11-dev/" + id)
        }
    }

    func testATestProcessUsesItsOwnTemporaryFolder() {
        let resolved = resolve(["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"], bundle: "com.stage11.c11")
        XCTAssertEqual(resolved.kind, .test)
        XCTAssertEqual(resolved.url.path, temporary.path + "/c11-test-mailboxes-4242")
    }

    /// The CLI tests run c11 with `CFFIXED_USER_HOME` set: that home is already disposable.
    func testATestThatRelocatedTheHomeResolvesThereAsAnAppWould() {
        let env = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration", "CFFIXED_USER_HOME": "/tmp/home"]
        XCTAssertEqual(resolve(env, bundle: nil).kind, .release)
    }

    /// The CLI has no bundle of its own; it follows the app whose terminal it
    /// runs in, else the app it ships inside.
    func testTheCLIFollowsItsTerminalsAppThenItsOwnApp() throws {
        let env = ["CMUX_BUNDLE_ID": "com.stage11.c11.debug.c11-439"]
        XCTAssertEqual(MailboxStateRoot.bundleIdentifier(main: nil, environment: env, executablePath: nil),
                       "com.stage11.c11.debug.c11-439")
        XCTAssertEqual(MailboxStateRoot.bundleIdentifier(main: "com.apple.dt.xctest.tool", environment: env, executablePath: nil),
                       "com.stage11.c11.debug.c11-439")
        // An app launched from another build's terminal keeps its own.
        XCTAssertEqual(MailboxStateRoot.bundleIdentifier(main: "com.stage11.c11", environment: env, executablePath: nil),
                       "com.stage11.c11")

        // A scrubbed environment (a guest's `sandbox-exec`): the app the CLI ships in.
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-439-\(UUID().uuidString)/c11 DEV x.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let bin = app.appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.stage11.c11.debug.x"],
                                                       format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(MailboxStateRoot.bundleIdentifier(main: nil, environment: [:],
                                                         executablePath: bin.appendingPathComponent("c11").path),
                       "com.stage11.c11.debug.x")
    }

    /// The app stamps its folder on each terminal; the CLI there follows it.
    func testTheCLIFollowsTheFolderItsAppStamped() {
        let stamp = "/Users/someone/Library/Application Support/c11-dev/com.stage11.c11.debug.x"
        // A test's child CLI inherits the XCTest variables but loads no XCTest: it follows the stamp.
        let env = [MailboxStateRoot.stampEnvironmentKey: stamp, "XCTestConfigurationFilePath": "/tmp/x"]
        XCTAssertEqual(resolve(env, bundle: "com.stage11.c11", isApp: false, existing: [stamp]),
                       .init(kind: .stamped, url: URL(fileURLWithPath: stamp, isDirectory: true)))
        // A test runner started from a c11 terminal hosts XCTest: it keeps to its own folder.
        XCTAssertEqual(resolve(env, bundle: "com.stage11.c11", isApp: false, hostsXCTest: true, existing: [stamp]).kind,
                       .test)
        XCTAssertEqual(resolve([MailboxStateRoot.stampEnvironmentKey: stamp], bundle: nil, isApp: false,
                               hostsXCTest: true, existing: [stamp]).kind, .test)
        // An app ignores a stamp it inherited from another build's terminal.
        XCTAssertEqual(resolve([MailboxStateRoot.stampEnvironmentKey: stamp], bundle: "com.stage11.c11",
                               existing: [stamp]).kind, .release)
        // A stamp naming no folder here (a terminal on a linked machine) is ignored.
        XCTAssertEqual(resolve([MailboxStateRoot.stampEnvironmentKey: stamp], bundle: nil, isApp: false).kind, .release)
    }

    /// A migration guest proof runs a tagged build as the release app: it keeps
    /// the release folder, where the migration puts the mail.
    func testAMigrationQALaunchKeepsTheReleaseFolder() {
        let env = ["C11_MIGRATION_QA": "1", "C11_QA_LAUNCH": "fresh"]
        XCTAssertEqual(resolve(env, bundle: "com.stage11.c11.debug.mig").kind, .release)
        XCTAssertEqual(resolve(["C11_MIGRATION_QA": "1"], bundle: "com.stage11.c11.debug.mig").kind,
                       .build("com.stage11.c11.debug.mig"))
        XCTAssertTrue(C11Identity.isMigrationQALaunch(environment: env))
    }

    /// Through the entry `defaultStateURL` uses: a migration QA app, and its
    /// CLI (no bundle of its own, no stamp) with and without the two variables.
    func testTheProcessEntryAppliesTheMigrationRuleToTheAppAndItsCLI() {
        let tagged = "com.stage11.c11.debug.mig"
        let flags = ["C11_MIGRATION_QA": "1", "C11_QA_LAUNCH": "resume"]
        func root(main: String?, _ environment: [String: String]) -> MailboxStateRoot.Resolved {
            MailboxStateRoot.forProcess(main: main, executablePath: nil, environment: environment, appSupport: appSupport,
                                        hostsXCTest: false, temporaryDirectory: temporary, processIdentifier: 4242)
        }
        XCTAssertEqual(root(main: tagged, flags).kind, .release, "the migration QA app")
        XCTAssertEqual(root(main: tagged, [:]).kind, .build(tagged), "the same app launched normally")
        var cli = flags
        cli["CMUX_BUNDLE_ID"] = tagged
        XCTAssertEqual(root(main: nil, cli).kind, .release, "its CLI with the two variables")
        XCTAssertEqual(root(main: nil, ["CMUX_BUNDLE_ID": tagged]).kind, .build(tagged), "its CLI without them")
        XCTAssertEqual(root(main: "com.apple.dt.xctest.tool", cli).kind, .release, "a runner is not an app")
        XCTAssertFalse(C11Identity.isMigrationQALaunch(environment: ["C11_MIGRATION_QA": "1", "C11_QA_LAUNCH": ""]))
    }

    /// The Opus review's repro, in-process: this test runner carries a c11
    /// terminal's stamp (a slice run from a c11 2.0 terminal). Its mailbox
    /// root stays its own temporary folder, not the stamped one.
    func testATestRunStartedFromAC11TerminalIgnoresTheStamp() throws {
        continueAfterFailure = false
        let stamp = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-439-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stamp, withIntermediateDirectories: true)
        let key = MailboxStateRoot.stampEnvironmentKey
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, stamp.path, 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
            try? FileManager.default.removeItem(at: stamp)
        }
        XCTAssertEqual(ProcessInfo.processInfo.environment[key], stamp.path, "the stamp did not reach this process")
        let state = try MailboxLayout.defaultStateURL()
        XCTAssertNotEqual(state.standardizedFileURL.path, stamp.standardizedFileURL.path, "a test run followed the stamp")
        XCTAssertTrue(state.lastPathComponent.hasPrefix(MailboxStateRoot.testDirectoryPrefix), state.path)
    }

    /// This process is a test run: its mailbox tree is not the release app's,
    /// and a workspace it opens and closes leaves nothing there.
    func testATestRunLeavesTheReleaseFolderUntouched() throws {
        // Stop at the first miss: past it, the dispatcher below would write the release folder.
        continueAfterFailure = false
        let state = try MailboxLayout.defaultStateURL()
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let releaseWorkspaces = support.appendingPathComponent("c11/workspaces", isDirectory: true)
        XCTAssertNotEqual(state.standardizedFileURL, support.appendingPathComponent("c11").standardizedFileURL)
        XCTAssertTrue(state.lastPathComponent.hasPrefix(MailboxStateRoot.testDirectoryPrefix), state.path)

        let workspace = UUID()
        let dispatcher = MailboxDispatcher(workspaceId: workspace, stateURL: state,
                                           resolver: MailboxPanelResolver(workspaceId: workspace, livePanels: { [] }))
        XCTAssertTrue(dispatcher.start())
        XCTAssertTrue(FileManager.default.fileExists(atPath: MailboxLayout.outboxURL(state: state, workspaceId: workspace).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: releaseWorkspaces.appendingPathComponent(workspace.uuidString).path))
        let retired = expectation(description: "retired")
        var outcome: MailboxWorkspaceFolder.Outcome?
        dispatcher.retire { outcome = $0; retired.fulfill() }
        wait(for: [retired], timeout: 10)
        XCTAssertEqual(outcome, .removed)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: releaseWorkspaces.appendingPathComponent(workspace.uuidString).path))
    }
}

// MARK: - C11H-439: a closed workspace that held nothing takes its folder with it

final class MailboxWorkspaceFolderTests: XCTestCase {
    private var state: URL!

    override func setUpWithError() throws {
        state = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-439-folders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: state)
    }

    private func dispatcher(_ workspace: UUID) -> MailboxDispatcher {
        MailboxDispatcher(workspaceId: workspace, stateURL: state,
                          resolver: MailboxPanelResolver(workspaceId: workspace, livePanels: { [] }))
    }

    private func retire(_ dispatcher: MailboxDispatcher) -> MailboxWorkspaceFolder.Outcome? {
        let done = expectation(description: "retired")
        var outcome: MailboxWorkspaceFolder.Outcome?
        dispatcher.retire { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        return outcome
    }

    private func folder(_ workspace: UUID) -> URL {
        MailboxWorkspaceFolder.folderURL(state: state, workspaceId: workspace)
    }

    func testAClosedWorkspaceThatHeldNothingTakesItsFolder() {
        let workspace = UUID()
        let open = dispatcher(workspace)
        XCTAssertTrue(open.start())
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder(workspace).path))
        XCTAssertEqual(retire(open), .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder(workspace).path))
    }

    func testAFolderWithAnyFileIsKeptWhole() throws {
        for relative in ["\(UUID().uuidString.lowercased())/_read/01K0000000000000000000439A.msg",
                         "_outbox/.01K0000000000000000000439B.tmp", "_dispatch.log"] {
            let workspace = UUID()
            let open = dispatcher(workspace)
            XCTAssertTrue(open.start())
            let file = MailboxLayout.mailboxesRoot(state: state, workspaceId: workspace).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: file)
            XCTAssertEqual(retire(open), .kept, relative)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), relative)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: MailboxLayout.outboxURL(state: state, workspaceId: workspace).path), relative)
        }
    }

    func testAFolderWhoseWorkspaceOpenedAgainStays() {
        let workspace = UUID()
        let first = dispatcher(workspace), again = dispatcher(workspace)
        XCTAssertTrue(first.start())
        XCTAssertTrue(again.start())
        XCTAssertEqual(retire(first), .live)
        XCTAssertTrue(FileManager.default.fileExists(atPath: MailboxLayout.outboxURL(state: state, workspaceId: workspace).path))
        XCTAssertEqual(retire(again), .removed)
    }
}

// MARK: - C11H-439: launch against a folder of many workspace folders

final class MailboxLaunchFixtureTests: XCTestCase {
    /// Raise to measure a larger folder; the suite keeps it small.
    private static let folderCount = 2_000
    private var state: URL!

    override func setUpWithError() throws {
        state = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-439-launch-\(UUID().uuidString)", isDirectory: true)
        let workspaces = state.appendingPathComponent(MailboxLayout.workspacesDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        // The tree every opened workspace left before C11H-439.
        for _ in 0..<Self.folderCount {
            let mailboxes = workspaces.appendingPathComponent(UUID().uuidString).path
            XCTAssertEqual(mkdir(mailboxes, 0o700), 0)
            let root = mailboxes + "/mailboxes"
            XCTAssertEqual(mkdir(root, 0o700), 0)
            for name in ["_outbox", "_processing", "_rejected"] { XCTAssertEqual(mkdir(root + "/" + name, 0o700), 0) }
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: state)
    }

    private final class CountingFileManager: FileManager {
        private let lock = NSLock()
        private var count = 0
        var reads: Int { lock.withLock { count } }
        private func note() { lock.withLock { count += 1 } }
        override func fileExists(atPath path: String) -> Bool { note(); return super.fileExists(atPath: path) }
        override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            note(); return super.fileExists(atPath: path, isDirectory: isDirectory)
        }
        override func contentsOfDirectory(atPath path: String) throws -> [String] {
            note(); return try super.contentsOfDirectory(atPath: path)
        }
        override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                          options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
            note(); return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        }
    }

    private func recorder(_ fileManager: FileManager) -> MailboxReceiptRecorder {
        MailboxReceiptRecorder(emit: { _, _, _, _ in }, flush: {}, confirmedDeliveries: { _ in [] },
                               isRecording: { true }, eventsDirectory: { nil }, fileManager: fileManager)
    }

    private func seconds(_ block: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try block()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    /// Launch opens a workspace's dispatcher (which registers its receipt
    /// spool) and starts the messages page writer. Neither reads the other
    /// workspaces' folders: the work is the same for 2,000 folders as for none.
    func testLaunchReadsNoOtherWorkspaceFolder() throws {
        let workspacesRoot = state.appendingPathComponent(MailboxLayout.workspacesDirectoryName, isDirectory: true)
        let opened = UUID()
        let counting = CountingFileManager()
        let launchRecorder = recorder(counting)
        let writer = MessagesPageWriter(stateURL: state, debounceInterval: 0, observeEvents: false,
                                        allowStartUnderXCTest: true,
                                        label: "com.stage11.c11.c11-439-\(UUID().uuidString)")
        defer { writer.stopForTesting() }
        let launch = seconds {
            launchRecorder.watch(workspaceId: opened, mailboxesRoot: MailboxLayout.mailboxesRoot(state: state, workspaceId: opened),
                                 workspacesRoot: workspacesRoot)
            launchRecorder.sync()
            writer.start()
            writer.syncForTesting()
        }
        launchRecorder.unwatch(workspaceId: opened)
        launchRecorder.sync()
        XCTAssertLessThan(counting.reads, 10, "launch read \(counting.reads) paths for \(Self.folderCount) folders")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MessagesPageLayout.pageURL(state: state).path))

        // What launch did before: sweep every spool and read every tree for the page.
        let before = CountingFileManager()
        let oldRecorder = recorder(before)
        let previous = seconds {
            oldRecorder.sync { oldRecorder.sweepEveryWorkspace(workspacesRoot: workspacesRoot) }
            _ = MessagesPageSource.load(stateURL: state)
        }
        XCTAssertGreaterThanOrEqual(before.reads, Self.folderCount)
        print(String(format: "C11H-439 launch fixture folders=%d launch_s=%.4f launch_reads=%d before_s=%.4f before_reads=%d",
                     Self.folderCount, launch, counting.reads, previous, before.reads))
    }
}

// MARK: - C11H-439: the production callers remove the folder

/// Workspace close and session restore call `retireMailboxForGood()` with no
/// completion; the removal must still run. Waits through the dispatcher's
/// retirement seam, not a completion.
@MainActor
final class MailboxWorkspaceRetirementTests: XCTestCase {
    private func folder(_ id: UUID) throws -> URL {
        MailboxWorkspaceFolder.folderURL(state: try MailboxLayout.defaultStateURL(), workspaceId: id)
    }

    func testClosingAWorkspaceRemovesItsEmptyFolder() throws {
        let manager = WorkspaceManager()
        let kept = try XCTUnwrap(manager.workspaces.first)
        let closed = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try folder(closed.id).path))
        manager.closeWorkspace(closed)
        XCTAssertTrue(MailboxDispatcher.waitForRetirementsForTesting())
        XCTAssertFalse(FileManager.default.fileExists(atPath: try folder(closed.id).path), "a closed workspace left its folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try folder(kept.id).path), "an open workspace lost its folder")
    }

    func testRestoreRemovesTheDisplacedPlaceholdersEmptyFolder() throws {
        let source = WorkspaceManager()
        let saved = try XCTUnwrap(source.workspaces.first)
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        let restored = WorkspaceManager()
        let placeholder = try XCTUnwrap(restored.workspaces.first)
        XCTAssertNotEqual(placeholder.id, saved.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try folder(placeholder.id).path))
        restored.restoreSessionSnapshot(snapshot)
        XCTAssertTrue(MailboxDispatcher.waitForRetirementsForTesting())
        XCTAssertFalse(FileManager.default.fileExists(atPath: try folder(placeholder.id).path), "the placeholder left its folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try folder(saved.id).path), "the restored workspace lost its folder")
    }
}
