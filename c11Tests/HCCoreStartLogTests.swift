import CryptoKit
import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// A fresh install that cannot start its core must say why. Each test breaks one
/// precondition of the core-start path and asserts the step and public reason
/// that reach the log sink. Every case fails before a process would be spawned:
/// no core, helper or app is ever started.
final class HCCoreStartLogTests: XCTestCase {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [HCCoreStartLog.Event] = []
        var log: HCCoreStartLog { HCCoreStartLog { [self] event in lock.lock(); items.append(event); lock.unlock() } }
        var events: [HCCoreStartLog.Event] { lock.lock(); defer { lock.unlock() }; return items }
        var failures: [HCCoreStartLog.Event] { events.filter { $0.outcome == .failed } }
    }

    private let version = "9.9.9"
    private var home: URL!

    override func setUpWithError() throws {
        // Short on purpose: the production socket path must fit sockaddr_un.
        home = URL(fileURLWithPath: "/tmp/hcl\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func configuration(pinContents: Data = Data("fake core".utf8)) throws -> HCLaunchConfiguration {
        let pin = HCPin(version: version, archiveSHA256: "", executableSHA256: sha(pinContents), protocolGeneration: 1)
        return try HCLaunchPolicy.configuration(home: home, tag: "t", inherited: [:], pin: pin)
    }

    private func install(_ c: HCLaunchConfiguration, contents: Data = Data("fake core".utf8), mode: mode_t = 0o755) throws {
        try FileManager.default.createDirectory(at: c.executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: c.executableURL)
        XCTAssertEqual(chmod(c.executableURL.path, mode), 0)
    }

    private func start(_ c: HCLaunchConfiguration, _ collector: Collector) async -> Error? {
        let launcher = HCLauncher(verifier: HCBuildVerifier(), startLog: collector.log)
        do { _ = try await launcher.start(c, deadlineUptimeNanoseconds: HCMonotonic.deadline(after: 5)); return nil }
        catch { return error }
    }

    private func assertFailure(_ collector: Collector, step: HCCoreStartLog.Step, reason: String,
                               detailContains: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let failure = collector.failures.first else { return XCTFail("nothing was logged", file: file, line: line) }
        XCTAssertEqual(collector.failures.count, 1, "exactly one failure should be logged", file: file, line: line)
        XCTAssertEqual(failure.step, step, file: file, line: line)
        XCTAssertEqual(failure.reason, reason, file: file, line: line)
        XCTAssertTrue(failure.detail?.contains(detailContains) == true, "detail \(failure.detail ?? "nil")", file: file, line: line)
    }

    // MARK: launcher steps 1 to 3

    func testMissingPinnedCoreIsLoggedAsCoreUnreachableWithItsPath() async throws {
        let c = try configuration(), log = Collector()
        let error = await start(c, log)
        XCTAssertEqual(error as? HCUnavailableReason, .coreUnreachable)
        assertFailure(log, step: .launchPin, reason: "coreUnreachable", detailContains: "hc/\(version)/herdr-core")
    }

    func testWrongHashGroupWritableAndSymlinkedPinsAreLoggedAsPinMismatch() async throws {
        let c = try configuration()
        for (label, prepare) in [
            ("wrong contents", { try self.install(c, contents: Data("different".utf8)) }),
            ("group-writable", { try self.install(c, mode: 0o775) }),
            ("symlink", {
                try FileManager.default.createDirectory(at: c.executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let real = self.home.appendingPathComponent("real-core")
                try Data("fake core".utf8).write(to: real)
                _ = chmod(real.path, 0o755)
                try FileManager.default.createSymbolicLink(at: c.executableURL, withDestinationURL: real)
            }),
        ] as [(String, () throws -> Void)] {
            try? FileManager.default.removeItem(at: c.executableURL.deletingLastPathComponent())
            try prepare()
            let log = Collector()
            let error = await start(c, log)
            XCTAssertEqual(error as? HCUnavailableReason, .pinMismatch, label)
            assertFailure(log, step: .launchPin, reason: "pinMismatch", detailContains: "herdr-core")
        }
    }

    func testForeignCoreLockIsLoggedAtTheStateStep() async throws {
        let c = try configuration(), log = Collector()
        try install(c)
        try FileManager.default.createDirectory(at: c.stateDirectory, withIntermediateDirectories: true)
        let lock = c.stateDirectory.appendingPathComponent("core.lock")
        try Data("/somewhere/else.sock".utf8).write(to: lock)
        XCTAssertEqual(chmod(lock.path, 0o600), 0)
        let error = await start(c, log)
        XCTAssertEqual(error as? HCUnavailableReason, .foreignSession)
        XCTAssertEqual(log.events.first?.step, .launchPin)
        XCTAssertEqual(log.events.first?.outcome, .ok, "the pin step is logged as passed")
        assertFailure(log, step: .launchState, reason: "foreignSession", detailContains: c.stateDirectory.lastPathComponent)
    }

    func testARefusedRunDirectoryIsLoggedWithTheOffendingPath() async throws {
        let c = try configuration(), log = Collector()
        try install(c)
        // C11H-332: a loose folder is repaired now; a symlinked one is still refused.
        let run = c.socketURL.deletingLastPathComponent()
        let elsewhere = home.appendingPathComponent("elsewhere-run", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(elsewhere.path, 0o700), 0)
        try FileManager.default.createDirectory(at: run.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: run, withDestinationURL: elsewhere)
        let error = await start(c, log)
        XCTAssertEqual(error as? HCUnavailableReason, .invalidLaunchTuple)
        XCTAssertEqual(log.events.map(\.step), [.launchPin, .launchState, .launchDirectories])
        XCTAssertEqual(log.events.map(\.outcome), [.ok, .ok, .failed])
        assertFailure(log, step: .launchDirectories, reason: "invalidLaunchTuple", detailContains: "/run")
    }

    // MARK: reason tokens

    func testReasonTokensAreStableAndPublic() {
        XCTAssertEqual(HCCoreStartLog.reason(HCUnavailableReason.fileDescriptorLimit), "fileDescriptorLimit")
        XCTAssertEqual(HCCoreStartLog.reason(HCRPCFailure(reason: .deadlineExceeded, transmission: .none, remoteCode: nil)), "deadlineExceeded")
        XCTAssertEqual(HCCoreStartLog.reason(POSIXError(.EACCES)), "posix:\(POSIXErrorCode.EACCES.rawValue)")
        XCTAssertEqual(HCCoreStartLog.reason(NSError(domain: NSPOSIXErrorDomain, code: 13)), "posix:13")
        XCTAssertTrue(HCCoreStartLog.reason(CocoaError(.fileNoSuchFile)).hasPrefix("error:"))
    }

    // MARK: activation (app start)

    @MainActor
    func testActivationFailureIsLoggedAndPersistentPanelsStayUnavailable() {
        let log = Collector()
        let composition = HCBackendComposition()
        composition.activateOrUnavailable(home: home, tag: "bad/tag", inherited: [:], startLog: log.log, installAdmission: { _ in })
        XCTAssertEqual(log.failures.count, 1)
        XCTAssertEqual(log.failures.first?.step, .activation)
        XCTAssertEqual(log.failures.first?.reason, "invalidLaunchTuple")
        XCTAssertTrue(log.failures.first?.detail?.contains("bad/tag") == true, "the offending tag must be named")
        XCTAssertTrue(composition.session is HCUnavailableRuntime, "no exec fallback and no live core")
        // An overlong home makes the socket path unusable: same step and reason.
        let overlong = Collector()
        HCBackendComposition().activateOrUnavailable(home: URL(fileURLWithPath: "/tmp/" + String(repeating: "h", count: 120)),
            tag: nil, inherited: [:], startLog: overlong.log, installAdmission: { _ in })
        XCTAssertEqual(overlong.failures.first?.reason, "invalidLaunchTuple")
    }

    // MARK: connect or start (session)

    func testConnectFailureLogsTheStartAttemptAndTheFinalReason() async throws {
        struct Absent: HCConnectionFactory {
            func connect(_ request: HCConnectionRequest, verify: @escaping HCServingBuildVerifier) async throws -> any HCConnection {
                throw HCUnavailableReason.coreUnreachable
            }
        }
        struct Refusing: HCCoreLaunching {
            func start(_ configuration: HCLaunchConfiguration, deadlineUptimeNanoseconds: UInt64) async throws -> HCLaunchLimitReport {
                throw HCUnavailableReason.pinMismatch
            }
        }
        struct NoVerifier: HCPeerVerifying {
            func verify(_ peer: HCPeerEvidence, configuration: HCLaunchConfiguration) async throws -> HCVerifiedPeer { throw HCUnavailableReason.foreignSession }
            func validateOwnedState(_ configuration: HCLaunchConfiguration, coreID: String) async throws {}
        }
        let c = try configuration(), log = Collector()
        let session = HCManagedSession(configuration: c, connections: Absent(), verifier: NoVerifier(), launcher: Refusing(),
            intents: HCCreationIntentStore(directory: home.appendingPathComponent("intents")),
            prepareAttachment: { _, _, _, display in display }, startLog: log.log)
        let lifecycle = await session.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
        guard case .unresolved(_, let reason) = lifecycle else { return XCTFail("a missing core must leave the panel unresolved") }
        XCTAssertEqual(reason, .pinMismatch)
        XCTAssertEqual(log.failures.map(\.reason), ["coreUnreachable", "pinMismatch"],
                       "first the absent core that triggers a start, then why the start failed")
        XCTAssertTrue(log.failures.allSatisfy { $0.step == .connect })
        XCTAssertTrue(log.failures.last?.detail?.contains(c.session) == true)
    }

    // MARK: private directory guard (symlinked ancestors, symlinked leaf)

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & 0o777
    }

    /// C11H-402: hc's private folders are made private by their own mode,
    /// never by borrowing the process umask, which every other thread's new
    /// files share. Fails with `umask(0o077)` put back around the `mkdirat`.
    func testMakingHCPrivateFoldersNeverChangesTheProcessUmask() throws {
        let audit = C11AuditLog(directory: home.appendingPathComponent("audit", isDirectory: true))
        let parent = home.appendingPathComponent("run", isDirectory: true)
        try HCLauncher.preparePrivateDirectory(parent, audit: audit)
        let probe = UmaskLeakProbe(folder: home)
        probe.start()
        var folders: [URL] = []
        for index in 0..<200 {
            let leaf = parent.appendingPathComponent("leaf-\(index)", isDirectory: true)
            try HCLauncher.preparePrivateDirectory(leaf, audit: audit)
            folders.append(leaf)
        }
        let seen = probe.stop()
        XCTAssertGreaterThan(seen.probes, 0, "the probe made folders while hc's were made")
        XCTAssertEqual(seen.lost.map { String($0, radix: 8) }, [], "another thread's 0755 folder lost bits")
        XCTAssertEqual(folders.filter { mode($0) != 0o700 }, [], "every hc folder is private")
    }

    func testMissingDirectoryUnderASymlinkedParentIsCreatedPrivate() throws {
        // Ordinary layouts have symlinked ancestors (/var, /tmp, a moved home).
        // The old URL-equality guard rejected a not-yet-existing directory there.
        let real = home.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        for target in [link.appendingPathComponent("run", isDirectory: true), link.appendingPathComponent("run2")] {
            try HCLauncher.preparePrivateDirectory(target)
            XCTAssertEqual(mode(target), 0o700, target.path)
        }
        // The system temporary directory is itself under a /var -> /private/var symlink.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("hcl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try HCLauncher.preparePrivateDirectory(temp)
        XCTAssertEqual(mode(temp), 0o700)
        // Idempotent for an existing private directory, with or without a slash.
        try HCLauncher.preparePrivateDirectory(temp)
        try HCLauncher.preparePrivateDirectory(URL(fileURLWithPath: temp.path + "/"))
    }

    /// C11H-332: hc's own folders are made private rather than refused, and
    /// the change is a line in c11's audit log. Fails with the repair removed
    /// (the old check threw invalidLaunchTuple for a 0755 folder).
    func testALooseHCFolderIsMadePrivateAndAudited() throws {
        let audit = C11AuditLog(directory: home.appendingPathComponent("audit", isDirectory: true))
        let run = home.appendingPathComponent("loose-run", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(run.path, 0o755), 0)
        try HCLauncher.preparePrivateDirectory(run, audit: audit)
        XCTAssertEqual(mode(run), 0o700)
        audit.flush()
        let records = audit.read()
        XCTAssertEqual(records.map(\.kind), ["dir_repaired"])
        XCTAssertEqual(records.first?.path, HCLauncher.normalizedPath(run))
        XCTAssertEqual(records.first?.detail, "mode 755 to 700")
        try HCLauncher.preparePrivateDirectory(run, audit: audit)
        audit.flush()
        XCTAssertEqual(audit.read().count, 1, "a private folder is left alone and not logged again")
    }

    /// The same repair for a core c11 adopted: existing folders only, nothing created.
    func testAnAdoptedCoresFoldersAreRepairedButNeverCreated() throws {
        let audit = C11AuditLog(directory: home.appendingPathComponent("audit", isDirectory: true))
        let root = home.appendingPathComponent(".local/state/herdr-core", isDirectory: true)
        let state = root.appendingPathComponent("c11-adopted", isDirectory: true)
        let run = home.appendingPathComponent(".local/share/c11/run", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertEqual(chmod(state.path, 0o750), 0)
        let c = HCLaunchConfiguration(executableURL: home.appendingPathComponent("hc"), session: "c11-adopted",
                                      socketURL: run.appendingPathComponent("c11-adopted.sock"), stateDirectory: state,
                                      intentDirectory: home, environment: [:],
                                      pin: HCPin(version: "0.1.16", archiveSHA256: String(repeating: "a", count: 64),
                                                 executableSHA256: String(repeating: "b", count: 64), protocolGeneration: 1))
        XCTAssertEqual(HCLauncher.privateFolders(c).map(HCLauncher.normalizedPath),
                       [run, root, state].map(HCLauncher.normalizedPath))
        HCLauncher.repairPrivateFolders(c, audit: audit)
        XCTAssertEqual(mode(root), 0o700)
        XCTAssertEqual(mode(state), 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.path), "a missing folder is not created for a core c11 did not start")
        audit.flush()
        XCTAssertEqual(Set(audit.read().compactMap(\.path)), Set([root, state].map(HCLauncher.normalizedPath)))
    }

    /// C11H-332: a read-only shard's folders are inspected, never changed:
    /// a loose one refuses the core and keeps its mode.
    func testAReadOnlyShardsLooseFolderIsRefusedNotChanged() throws {
        let audit = C11AuditLog(directory: home.appendingPathComponent("audit", isDirectory: true))
        let run = home.appendingPathComponent(".local/share/c11/run", isDirectory: true)
        let state = home.appendingPathComponent(".local/state/herdr-core/c11-ro", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(run.path, 0o755), 0)
        let c = HCLaunchConfiguration(executableURL: home.appendingPathComponent("hc"), session: "c11-ro",
                                      socketURL: run.appendingPathComponent("c11-ro.sock"), stateDirectory: state,
                                      intentDirectory: home, environment: [:],
                                      pin: HCPin(version: "0.1.16", archiveSHA256: String(repeating: "a", count: 64),
                                                 executableSHA256: String(repeating: "b", count: 64), protocolGeneration: 1))
        XCTAssertFalse(HCLauncher.repairPrivateFolders(c, repair: false, audit: audit))
        XCTAssertEqual(mode(run), 0o755, "inspection changes nothing")
        audit.flush()
        XCTAssertEqual(audit.read(.init(kind: "dir_refused")).first?.code, "not_private")
        XCTAssertTrue(HCLauncher.repairPrivateFolders(c, repair: true, audit: audit), "a writable shard repairs it")
        XCTAssertEqual(mode(run), 0o700)
    }

    /// C11H-332: a symlinked state root stops the walk: the adoption check
    /// returns false and nothing under the symlink's target is changed or
    /// created; the refusal is audited once.
    func testARefusedParentStopsTheFolderWalk() throws {
        let audit = C11AuditLog(directory: home.appendingPathComponent("audit", isDirectory: true))
        let outside = home.appendingPathComponent("outside", isDirectory: true)
        let outsideChild = outside.appendingPathComponent("c11-walk", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideChild, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(outside.path, 0o755), 0)
        XCTAssertEqual(chmod(outsideChild.path, 0o755), 0)
        let stateParent = home.appendingPathComponent(".local/state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateParent, withIntermediateDirectories: true)
        let root = stateParent.appendingPathComponent("herdr-core", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        let run = home.appendingPathComponent(".local/share/c11/run", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let c = HCLaunchConfiguration(executableURL: home.appendingPathComponent("hc"), session: "c11-walk",
                                      socketURL: run.appendingPathComponent("c11-walk.sock"),
                                      stateDirectory: root.appendingPathComponent("c11-walk", isDirectory: true),
                                      intentDirectory: home, environment: [:],
                                      pin: HCPin(version: "0.1.16", archiveSHA256: String(repeating: "a", count: 64),
                                                 executableSHA256: String(repeating: "b", count: 64), protocolGeneration: 1))
        XCTAssertFalse(HCLauncher.repairPrivateFolders(c, audit: audit))
        XCTAssertEqual(mode(outside), 0o755, "the symlink's target is untouched")
        XCTAssertEqual(mode(outsideChild), 0o755, "nothing under a refused parent is changed")
        try FileManager.default.removeItem(at: outsideChild)
        XCTAssertThrowsError(try HCLauncher.preparePrivateDirectory(root, audit: audit))
        XCTAssertFalse(HCLauncher.repairPrivateFolders(c, audit: audit))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideChild.path), "nothing is created through a refused parent")
        audit.flush()
        let refused = audit.read(.init(kind: "dir_refused"))
        XCTAssertEqual(refused.map(\.path), [HCLauncher.normalizedPath(root)], "audited once, with the refused folder")
        XCTAssertEqual(refused.first?.code, "symlink")
    }

    func testSymlinkedLeafIsRefusedAndLeftUntouched() throws {
        let real = home.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(real.path, 0o700), 0)
        let leaf = home.appendingPathComponent("leaf")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: real)
        // A symlink is 0755 by default, which the permission check alone would
        // refuse. Make the link itself private and owned by us so that only the
        // directory-type check can reject it.
        XCTAssertEqual(lchmod(leaf.path, 0o700), 0)
        var linkInfo = stat()
        XCTAssertEqual(lstat(leaf.path, &linkInfo), 0)
        XCTAssertEqual(linkInfo.st_mode & 0o777, 0o700, "fixture must pass the mode and owner checks")
        XCTAssertEqual(linkInfo.st_uid, getuid())
        XCTAssertEqual(linkInfo.st_mode & S_IFMT, S_IFLNK)
        for url in [leaf, URL(fileURLWithPath: leaf.path, isDirectory: true)] {
            XCTAssertThrowsError(try HCLauncher.preparePrivateDirectory(url)) {
                XCTAssertEqual($0 as? HCUnavailableReason, .invalidLaunchTuple)
            }
        }
        XCTAssertEqual(mode(real), 0o700)
        let detail = HCLauncher.describe(leaf)
        XCTAssertTrue(detail.contains("kind=symlink"), detail)
        XCTAssertTrue(detail.contains("resolves-to="), "both the asked and the resolved path are logged: \(detail)")
    }

    func testPrivateRegularFileWhereTheDirectoryShouldBeIsRefused() throws {
        // Owned by us and 0700, so only the directory-type check can refuse it.
        let leaf = home.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: leaf)
        XCTAssertEqual(chmod(leaf.path, 0o700), 0)
        var info = stat()
        XCTAssertEqual(lstat(leaf.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertThrowsError(try HCLauncher.preparePrivateDirectory(leaf)) {
            XCTAssertEqual($0 as? HCUnavailableReason, .invalidLaunchTuple)
        }
        XCTAssertEqual(try Data(contentsOf: leaf), Data("x".utf8), "the file must be left alone")
        XCTAssertTrue(HCLauncher.describe(leaf).contains("kind=other"))
    }

    func testRefusedSymlinkedRunDirectoryIsLoggedWithBothPaths() async throws {
        let c = try configuration(), log = Collector()
        try install(c)
        let run = c.socketURL.deletingLastPathComponent()
        let elsewhere = home.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: run, withDestinationURL: elsewhere)
        XCTAssertEqual(lchmod(run.path, 0o700), 0, "private link: only the type check may refuse it")
        let error = await start(c, log)
        XCTAssertEqual(error as? HCUnavailableReason, .invalidLaunchTuple)
        assertFailure(log, step: .launchDirectories, reason: "invalidLaunchTuple", detailContains: "kind=symlink")
        XCTAssertTrue(log.failures.first?.detail?.contains("resolves-to=") == true)
    }

    // MARK: session name (launch tag)

    func testHCLaunchTagFollowsTheBundleLikeTheSocketPathDoes() {
        let base = SocketControlSettings.baseDebugBundleIdentifier
        // A tagged Debug app, launched without C11_TAG, still runs session c11-<tag>.
        XCTAssertEqual(SocketControlSettings.hcLaunchTag(environment: [:], bundleIdentifier: base + ".c11.b"), "c11-b")
        XCTAssertEqual(SocketControlSettings.hcLaunchTag(environment: [:], bundleIdentifier: base + ".qa"), "qa")
        // A literal C11_TAG wins over the bundle.
        XCTAssertEqual(SocketControlSettings.hcLaunchTag(environment: ["C11_TAG": "from-env"], bundleIdentifier: base + ".c11.b"), "from-env")
        XCTAssertEqual(SocketControlSettings.hcLaunchTag(environment: ["C11_TAG": "  "], bundleIdentifier: base + ".c11.b"), "c11-b")
        // Only release and unknown bundles have no tag (session c11).
        XCTAssertNil(SocketControlSettings.hcLaunchTag(environment: [:], bundleIdentifier: "com.stage11.c11"))
        XCTAssertNil(SocketControlSettings.hcLaunchTag(environment: [:], bundleIdentifier: nil))
        // The derived tag is accepted by the launch policy and names the session.
        let tag = SocketControlSettings.hcLaunchTag(environment: [:], bundleIdentifier: base + ".c11.b")
        XCTAssertEqual(try? HCLaunchPolicy.configuration(home: URL(fileURLWithPath: "/Users/u"), tag: tag, inherited: [:]).session,
                       "c11-c11-b")
    }

    /// C11H-205 decision 1: a staging build adopted 31 of release's terminals
    /// into its Recovered because staging, nightly and the untagged Debug build
    /// all ran release's session. Each now runs its own.
    func testEveryNonReleaseBuildRunsItsOwnSession() {
        let cases: [(String, String)] = [
            ("com.stage11.c11.debug", "c11-debug"),
            ("com.stage11.c11.staging", "c11-staging"),
            ("com.stage11.c11.nightly", "c11-nightly"),
            ("com.stage11.c11.staging.corners", "c11-staging-corners"),
            ("com.stage11.c11.staging.c11-110.build", "c11-staging-c11-110-build"),
            // A Debug tag that would name a channel's session gets its own.
            ("com.stage11.c11.debug.staging", "c11-tag-staging"),
            ("com.stage11.c11.debug.nightly.x", "c11-tag-nightly-x"),
            // Any other build under c11's identifier never falls back to release's.
            ("com.stage11.c11.preview", "c11-app-preview"),
        ]
        var sessions: Set<String> = ["c11"]
        for (bundle, session) in cases {
            let tag = SocketControlSettings.hcLaunchTag(environment: [:], bundleIdentifier: bundle)
            XCTAssertEqual(C11Identity.hcLaunchTag(environment: [:], bundleIdentifier: bundle), tag,
                           "app and c11-core name the same core for \(bundle)")
            let configured = try? HCLaunchPolicy.configuration(home: URL(fileURLWithPath: "/Users/u"), tag: tag, inherited: [:])
            XCTAssertEqual(configured?.session, session, bundle)
            XCTAssertTrue(sessions.insert(session).inserted, "\(bundle) shares \(session)")
        }
        XCTAssertEqual(SocketControlSettings.hcLaunchTag(environment: [:], bundleIdentifier: "com.stage11.c11.staging."), "staging")
        XCTAssertNil(SocketControlSettings.hcLaunchTag(environment: [:], bundleIdentifier: "com.stage11.c11hx"))
        // A literal C11_TAG still wins for a staging launch.
        XCTAssertEqual(SocketControlSettings.hcLaunchTag(environment: ["C11_TAG": "qa"], bundleIdentifier: "com.stage11.c11.staging"), "qa")
    }
}
