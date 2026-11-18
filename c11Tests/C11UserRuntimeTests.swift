import Darwin
import Foundation
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-364: c11's per-user runtime folder and the only ways c11 writes
/// into it or into shared /tmp. Every test works in its own temporary root;
/// none touches the real per-user folder, /tmp, or a running c11.
final class C11UserRuntimeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The user's own temp folder (never shared /tmp), and a short name so
        // a socket bound under it fits sun_path.
        let temp = try XCTUnwrap(C11UserRuntime.userTempDirectory())
        root = URL(fileURLWithPath: temp, isDirectory: true)
            .appendingPathComponent("u364-\(UUID().uuidString.prefix(8))", isDirectory: true)
        XCTAssertEqual(mkdir(root.path, mode_t(0o700)), 0)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Folder

    func testEnsureDirectoryCreatesPrivateFolderUnderBase() throws {
        let previousUmask = umask(mode_t(0o022))
        defer { _ = umask(previousUmask) }

        let path = try C11UserRuntime.ensureDirectory(base: root.path)

        XCTAssertEqual(path, root.path + "/c11")
        XCTAssertEqual(try mode(path), 0o700)
    }

    func testEnsureDirectoryTightensExistingLooseFolder() throws {
        let folder = root.path + "/c11"
        XCTAssertEqual(mkdir(folder, mode_t(0o755)), 0)
        XCTAssertEqual(chmod(folder, mode_t(0o755)), 0)

        try C11UserRuntime.ensureDirectory(base: root.path)

        XCTAssertEqual(try mode(folder), 0o700)
    }

    func testEnsureDirectoryRefusesSymlinkedFolder() throws {
        let elsewhere = root.path + "/elsewhere"
        XCTAssertEqual(mkdir(elsewhere, mode_t(0o777)), 0)
        XCTAssertEqual(symlink(elsewhere, root.path + "/c11"), 0)

        XCTAssertThrowsError(try C11UserRuntime.ensureDirectory(base: root.path))
    }

    func testDirectoryIsTheUserTempFolderNeverTmp() throws {
        let temp = try XCTUnwrap(C11UserRuntime.userTempDirectory())
        let folder = C11UserRuntime.directoryPath()
        XCTAssertEqual(folder, temp + "c11")
        XCTAssertFalse(folder.hasPrefix("/tmp"))
        XCTAssertFalse(folder.hasPrefix("/private/tmp"))
    }

    // MARK: - Socket names

    private let vectorDirectory = "/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/T/c11"

    func testShortStemIsKept() {
        XCTAssertEqual(
            C11UserRuntime.socketPath(stem: "c11-debug-c11-orch9", directory: vectorDirectory),
            vectorDirectory + "/c11-debug-c11-orch9.sock"
        )
        let longestKept = "c11-debug-" + String(repeating: "x", count: 29)
        XCTAssertEqual(C11UserRuntime.fittedSocketStem(longestKept, directory: vectorDirectory), longestKept)
    }

    /// The same vectors are asserted against scripts/lib/c11-user-paths.sh
    /// in tests/c11_user_paths_test.sh, so the app and the scripts agree.
    func testLongStemIsCutAndHashedToFitWithAPidSibling() {
        let oneOver = "c11-debug-" + String(repeating: "x", count: 30)
        XCTAssertEqual(
            C11UserRuntime.fittedSocketStem(oneOver, directory: vectorDirectory),
            "c11-debug-xxxxxxxxxxxxxxxxxxxx-7b75b09f"
        )
        let long = "c11-debug-a-very-long-tag-name-that-goes-on-and-on-far-past-every-sensible-length-and-then-some-more-text-xyz"
        let path = C11UserRuntime.socketPath(stem: long, directory: vectorDirectory)
        XCTAssertEqual(path, vectorDirectory + "/c11-debug-a-very-long-tag-name-a0aa9565.sock")
        XCTAssertLessThanOrEqual(path.utf8.count + C11UserRuntime.pidSiblingReserveBytes, C11UserRuntime.socketPathMaxBytes)
    }

    func testNonReleaseDefaultsLiveInThePerUserFolder() {
        let folder = C11UserRuntime.directoryPath()
        for path in [
            C11Identity.debugSocketPath,
            C11Identity.stagingSocketPath,
            C11Identity.nightlySocketPath,
            C11Identity.taggedDebugSocketPath(slug: "c11-orch9"),
            C11Identity.xctestSocketPath(processIdentifier: 4242),
            SocketControlSettings.defaultSocketPath(bundleIdentifier: "com.stage11.c11.debug.c11.orch9", isDebugBuild: true),
            SocketControlSettings.defaultSocketPath(bundleIdentifier: "com.stage11.c11.nightly", isDebugBuild: false),
            SocketControlSettings.defaultSocketPath(bundleIdentifier: "com.stage11.c11.staging", isDebugBuild: false),
        ] {
            XCTAssertEqual((path as NSString).deletingLastPathComponent, folder, path)
            XCTAssertTrue(C11Identity.isOwnSocketPath(path), path)
        }
    }

    func testReleaseSocketIsUnchanged() {
        let release = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.stage11.c11",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        XCTAssertTrue(release.hasSuffix("/Library/Application Support/c11/c11.sock"), release)
        XCTAssertEqual(C11Identity.tmpStableSocketPath, "/tmp/c11.sock")
    }

    func testLegacyAliasNamesTheOldTmpSocketForThisBuildsOwnDefault() {
        let tagged = SocketControlSettings.defaultSocketPath(bundleIdentifier: "com.stage11.c11.debug.c11.orch9", isDebugBuild: true)
        XCTAssertEqual(
            SocketControlSettings.legacyAliasPath(
                forBoundPath: tagged,
                environment: [:],
                bundleIdentifier: "com.stage11.c11.debug.c11.orch9",
                isDebugBuild: true
            ),
            "/tmp/c11-debug-c11-orch9.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.legacyAliasPath(
                forBoundPath: C11Identity.nightlySocketPath,
                environment: [:],
                bundleIdentifier: "com.stage11.c11.nightly",
                isDebugBuild: false
            ),
            "/tmp/c11-nightly.sock"
        )
        // A pid sibling or an explicit /tmp override gets no alias.
        XCTAssertNil(SocketControlSettings.legacyAliasPath(
            forBoundPath: TerminalController.safeAlternateSocketPath(afterPeerAliveAt: tagged, processIdentifier: 77),
            environment: [:],
            bundleIdentifier: "com.stage11.c11.debug.c11.orch9",
            isDebugBuild: true
        ))
        XCTAssertNil(SocketControlSettings.legacyAliasPath(
            forBoundPath: "/tmp/c11-sandbox-run.sock",
            environment: [:],
            bundleIdentifier: "com.stage11.c11.debug.c11.orch9",
            isDebugBuild: true
        ))

        // A tagged staging build (`reloads.sh --tag rel.v0.65.2`) keeps its pre-fix name.
        let staging = "com.stage11.c11.staging.rel.v0.65.2"
        let stagingBound = C11Identity.userSocketPath(stem: "c11-rel-v0-65-2")
        XCTAssertEqual(
            SocketControlSettings.legacyAliasPath(
                forBoundPath: stagingBound, environment: [:], bundleIdentifier: staging, isDebugBuild: false),
            "/tmp/c11-rel-v0-65-2.sock"
        )
        // A slug too long for sun_path binds the hashed name; the alias keeps the full one.
        let longSlug = "release-candidate-for-the-public-two-point-zero-push"
        XCTAssertGreaterThan(longSlug.utf8.count, 29)
        let longBound = C11Identity.userSocketPath(stem: "c11-" + longSlug)
        XCTAssertNotEqual(longBound, C11UserRuntime.directoryPath() + "/c11-\(longSlug).sock", "expected the hashed name")
        XCTAssertEqual(
            SocketControlSettings.legacyAliasPath(
                forBoundPath: longBound, environment: [:],
                bundleIdentifier: "com.stage11.c11.staging." + longSlug, isDebugBuild: false),
            "/tmp/c11-\(longSlug).sock"
        )
        XCTAssertNil(SocketControlSettings.legacyAliasPath(
            forBoundPath: TerminalController.safeAlternateSocketPath(afterPeerAliveAt: stagingBound, processIdentifier: 77),
            environment: [:],
            bundleIdentifier: staging,
            isDebugBuild: false
        ))
    }

    // MARK: - Breadcrumbs

    func testBreadcrumbIsWritten0600AndReadBack() throws {
        let previousUmask = umask(mode_t(0o022))
        defer { _ = umask(previousUmask) }
        let path = root.path + "/c11-last-socket-path"

        XCTAssertTrue(C11UserRuntime.writeBreadcrumb("/x/c11-debug.sock", to: path))

        XCTAssertEqual(try mode(path), 0o600)
        XCTAssertEqual(C11UserRuntime.readBreadcrumb(at: path), "/x/c11-debug.sock")
    }

    func testBreadcrumbReplacesPlantedSymlinkWithoutWritingThroughIt() throws {
        let victim = root.path + "/victim"
        try Data("untouched".utf8).write(to: URL(fileURLWithPath: victim))
        let path = root.path + "/crumb"
        XCTAssertEqual(symlink(victim, path), 0)

        XCTAssertTrue(C11UserRuntime.writeBreadcrumb("/x.sock", to: path))

        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "untouched")
        XCTAssertEqual(try fileType(path), mode_t(S_IFREG))
    }

    func testBreadcrumbOwnedByAnotherUserIsLeftAlone() throws {
        let path = root.path + "/crumb"
        try Data("theirs\n".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertFalse(C11UserRuntime.writeBreadcrumb("/x.sock", to: path, expectedOwner: getuid() &+ 1))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "theirs\n")
        XCTAssertNil(C11UserRuntime.readBreadcrumb(at: path, expectedOwner: getuid() &+ 1))
    }

    func testBreadcrumbReadRefusesSymlinkAndHardLink() throws {
        let real = root.path + "/real"
        try Data("/x.sock\n".utf8).write(to: URL(fileURLWithPath: real))
        XCTAssertEqual(symlink(real, root.path + "/soft"), 0)
        XCTAssertEqual(link(real, root.path + "/hard"), 0)

        XCTAssertNil(C11UserRuntime.readBreadcrumb(at: root.path + "/soft"))
        XCTAssertNil(C11UserRuntime.readBreadcrumb(at: root.path + "/hard"))
    }

    // MARK: - Logs

    func testLogAppendsToItsOwnFile0600() throws {
        let previousUmask = umask(mode_t(0o022))
        defer { _ = umask(previousUmask) }
        let path = root.path + "/c11-debug.log"

        XCTAssertTrue(C11UserRuntime.appendLog(Data("one\n".utf8), to: path))
        XCTAssertTrue(C11UserRuntime.appendLog(Data("two\n".utf8), to: path))

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "one\ntwo\n")
        XCTAssertEqual(try mode(path), 0o600)
    }

    func testLogRefusesPlantedSymlink() throws {
        let victim = root.path + "/rc"
        try Data("victim".utf8).write(to: URL(fileURLWithPath: victim))
        let path = root.path + "/c11-debug.log"
        XCTAssertEqual(symlink(victim, path), 0)

        XCTAssertNil(C11UserRuntime.openLogForAppend(path))
        XCTAssertFalse(C11UserRuntime.appendLog(Data("line\n".utf8), to: path))
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "victim")
    }

    func testLogRefusesPlantedHardLink() throws {
        let victim = root.path + "/rc"
        try Data("victim".utf8).write(to: URL(fileURLWithPath: victim))
        let path = root.path + "/c11-debug.log"
        XCTAssertEqual(link(victim, path), 0)

        XCTAssertNil(C11UserRuntime.openLogForAppend(path))
        XCTAssertFalse(C11UserRuntime.appendLog(Data("line\n".utf8), to: path))
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "victim")
    }

    func testLogRefusesFileAnotherUserOwnsAndAPlantedFifo() throws {
        let path = root.path + "/c11-debug.log"
        try Data().write(to: URL(fileURLWithPath: path))
        XCTAssertNil(C11UserRuntime.openLogForAppend(path, expectedOwner: getuid() &+ 1))

        let fifo = root.path + "/fifo.log"
        XCTAssertEqual(mkfifo(fifo, mode_t(0o600)), 0)
        XCTAssertNil(C11UserRuntime.openLogForAppend(fifo))
    }

    func testHangLogNeverWritesThroughALink() throws {
        let victim = root.path + "/big"
        let victimBytes = Data(repeating: 0x41, count: 4096)
        try victimBytes.write(to: URL(fileURLWithPath: victim))
        let logPath = root.path + "/c11-hang-x.log"
        XCTAssertEqual(symlink(victim, logPath), 0)

        var rotator = HangLogRotator(logURL: URL(fileURLWithPath: logPath), capBytes: 64, generations: 0)
        rotator.append(String(repeating: "h", count: 100), episodeBoundary: true)
        rotator.append(String(repeating: "h", count: 100), episodeBoundary: true)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: victim)), victimBytes)
    }

    func testDebugLogIsPrimedAsOurOwnFileOrMovedToThePrivateFolder() throws {
        // A free name is created as our own file, so nothing can be planted later.
        let fresh = root.path + "/c11-debug-free.log"
        XCTAssertEqual(C11UserRuntime.securedDebugLogPath(fresh, base: root.path), fresh)
        XCTAssertEqual(try fileType(fresh), mode_t(S_IFREG))
        XCTAssertEqual(try mode(fresh), 0o600)

        // A planted link is refused and the log moves to the private folder.
        let victim = root.path + "/rc"
        try Data("victim".utf8).write(to: URL(fileURLWithPath: victim))
        let planted = root.path + "/c11-debug-planted.log"
        XCTAssertEqual(symlink(victim, planted), 0)
        XCTAssertEqual(C11UserRuntime.securedDebugLogPath(planted, base: root.path), root.path + "/c11/c11-debug-planted.log")
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "victim")
    }

    func testDebugLogWithNoVariableIsThePerUserDefaultNeverTmp() throws {
        let previousUmask = umask(mode_t(0o022))
        defer { _ = umask(previousUmask) }
        let expected = root.path + "/c11/c11-debug-c11-orch9.log"

        // (i) No variable: the build's own name in the per-user folder, not bonsplit's /tmp fallback.
        XCTAssertEqual(
            C11UserRuntime.debugLogChoice(environment: [:], defaultName: "c11-debug-c11-orch9.log", base: root.path),
            expected)
        XCTAssertEqual(try fileType(expected), mode_t(S_IFREG))
        XCTAssertEqual(try mode(expected), 0o600)
        var info = stat()
        XCTAssertEqual(lstat(expected, &info), 0)
        XCTAssertEqual(info.st_uid, getuid())

        // (ii) A blank variable is the same as none.
        XCTAssertEqual(
            C11UserRuntime.debugLogChoice(
                environment: ["C11_DEBUG_LOG": " "], defaultName: "c11-debug-c11-orch9.log", base: root.path),
            expected)
    }

    func testDebugLogThatCannotBeMadeSafeIsDevNullNeverTmp() throws {
        // (iii) The named path is already the per-user name, and it is a hard
        // link to another file: there is nowhere safe left to move it.
        _ = try C11UserRuntime.ensureDirectory(base: root.path)
        let victim = root.path + "/victim"
        try Data("victim".utf8).write(to: URL(fileURLWithPath: victim))
        let named = root.path + "/c11/c11-debug-x.log"
        XCTAssertEqual(link(victim, named), 0)

        let choice = C11UserRuntime.debugLogChoice(
            environment: ["C11_DEBUG_LOG": named], defaultName: "c11-debug-x.log", base: root.path)

        XCTAssertEqual(choice, C11UserRuntime.unwritableDebugLogSink)
        XCTAssertEqual(choice, "/dev/null")
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "victim")
    }

    // MARK: - Peer credentials

    func testPeerUserIDOfASocketThisTestBinds() throws {
        let path = root.path + "/p.sock"
        let listener = try bindListener(at: path)
        defer { Darwin.close(listener) }
        let client = try connectClient(to: path)
        defer { Darwin.close(client) }

        XCTAssertEqual(C11UserRuntime.peerUserID(of: client), getuid())
        XCTAssertTrue(C11UserRuntime.peerIsUser(client))
        XCTAssertFalse(C11UserRuntime.peerIsUser(client, expected: getuid() &+ 1))
    }

    // MARK: - Legacy alias

    func testLegacyAliasIsCreatedWhenTheNameIsMissing() throws {
        let legacy = root.path + "/c11-debug-t.sock"
        let target = root.path + "/c11/c11-debug-t.sock"

        let outcome = C11UserRuntime.installLegacyAlias(at: legacy, target: target, hasLiveListener: { _ in false })

        XCTAssertEqual(outcome, .installed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: legacy), target)
    }

    func testLegacyAliasReplacesOurOwnLinkAndOurOwnDeadSocket() throws {
        let target = root.path + "/c11/new.sock"
        let link = root.path + "/c11-a.sock"
        XCTAssertEqual(symlink(root.path + "/old.sock", link), 0)
        XCTAssertEqual(C11UserRuntime.installLegacyAlias(at: link, target: target, hasLiveListener: { _ in false }), .installed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), target)

        let dead = root.path + "/c11-b.sock"
        let fd = try bindListener(at: dead)
        Darwin.close(fd)
        XCTAssertEqual(C11UserRuntime.installLegacyAlias(at: dead, target: target, hasLiveListener: { _ in false }), .installed)
        XCTAssertEqual(try fileType(dead), mode_t(S_IFLNK))
    }

    func testLegacyAliasLeavesALiveSocketAForeignEntryAndAFile() throws {
        let target = root.path + "/c11/new.sock"
        let live = root.path + "/c11-live.sock"
        let fd = try bindListener(at: live)
        defer { Darwin.close(fd) }
        XCTAssertEqual(C11UserRuntime.installLegacyAlias(at: live, target: target, hasLiveListener: { _ in true }), .keptLivePeer)
        XCTAssertEqual(try fileType(live), mode_t(S_IFSOCK))

        let foreign = root.path + "/c11-foreign.sock"
        XCTAssertEqual(symlink(root.path + "/their-listener.sock", foreign), 0)
        let other = getuid() &+ 1
        XCTAssertEqual(
            C11UserRuntime.installLegacyAlias(at: foreign, target: target, expectedOwner: other, hasLiveListener: { _ in false }),
            .keptForeign(owner: getuid())
        )
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: foreign), root.path + "/their-listener.sock")

        let file = root.path + "/c11-file.sock"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertEqual(C11UserRuntime.installLegacyAlias(at: file, target: target, hasLiveListener: { _ in false }), .keptOther)
    }

    // MARK: - wait-for

    func testWaitForSignalThenConsume() throws {
        let directory = root.path + "/c11"
        try C11UserRuntime.ensureWaitForFolder(directory: directory)
        let channel = C11UserRuntime.waitForChannelPath(name: "build done", directory: directory)
        XCTAssertEqual(channel, directory + "/wait-for/build_done.sig")
        XCTAssertEqual(try mode(directory + "/wait-for"), 0o700)

        XCTAssertEqual(C11UserRuntime.consumeWaitForSignal(at: channel), .notSignalled)
        try C11UserRuntime.signalWaitFor(at: channel)
        try C11UserRuntime.signalWaitFor(at: channel)  // a second signal is still a signal
        XCTAssertEqual(try mode(channel), 0o600)
        XCTAssertEqual(C11UserRuntime.consumeWaitForSignal(at: channel), .signalled)
        XCTAssertEqual(C11UserRuntime.consumeWaitForSignal(at: channel), .notSignalled)
    }

    func testWaitForRefusesALinkAFolderAFifoAHardLinkAndAForeignFile() throws {
        let directory = root.path + "/c11"
        try C11UserRuntime.ensureWaitForFolder(directory: directory)
        let victim = root.path + "/victim"
        try Data("victim".utf8).write(to: URL(fileURLWithPath: victim))

        let linked = C11UserRuntime.waitForChannelPath(name: "a", directory: directory)
        XCTAssertEqual(symlink(victim, linked), 0)
        XCTAssertThrowsError(try C11UserRuntime.signalWaitFor(at: linked))
        XCTAssertEqual(C11UserRuntime.consumeWaitForSignal(at: linked), .refused)

        let dangling = C11UserRuntime.waitForChannelPath(name: "b", directory: directory)
        XCTAssertEqual(symlink(root.path + "/nowhere", dangling), 0)
        XCTAssertThrowsError(try C11UserRuntime.signalWaitFor(at: dangling))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/nowhere"))

        let folder = C11UserRuntime.waitForChannelPath(name: "c", directory: directory)
        XCTAssertEqual(mkdir(folder, mode_t(0o700)), 0)
        XCTAssertEqual(C11UserRuntime.consumeWaitForSignal(at: folder), .refused)

        let fifo = C11UserRuntime.waitForChannelPath(name: "d", directory: directory)
        XCTAssertEqual(mkfifo(fifo, mode_t(0o600)), 0)
        XCTAssertEqual(C11UserRuntime.consumeWaitForSignal(at: fifo), .refused)

        let hard = C11UserRuntime.waitForChannelPath(name: "e", directory: directory)
        XCTAssertEqual(Darwin.link(victim, hard), 0)
        XCTAssertEqual(C11UserRuntime.consumeWaitForSignal(at: hard), .refused)

        let foreign = C11UserRuntime.waitForChannelPath(name: "f", directory: directory)
        try Data().write(to: URL(fileURLWithPath: foreign))
        XCTAssertThrowsError(try C11UserRuntime.signalWaitFor(at: foreign, expectedOwner: getuid() &+ 1))
        XCTAssertEqual(C11UserRuntime.consumeWaitForSignal(at: foreign, expectedOwner: getuid() &+ 1), .refused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign))
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "victim")
    }

    // MARK: - Helpers

    private func mode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o7777
    }

    private func fileType(_ path: String) throws -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        return info.st_mode & mode_t(S_IFMT)
    }

    private func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { source in
            withUnsafeMutablePointer(to: &addr.sun_path) { target in
                _ = strcpy(UnsafeMutableRawPointer(target).assumingMemoryBound(to: CChar.self), source)
            }
        }
        return addr
    }

    private func bindListener(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    private func connectClient(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = address(path)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }
}
