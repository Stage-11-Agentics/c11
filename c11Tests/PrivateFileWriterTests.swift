import Darwin
import Foundation
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class PrivateFileWriterTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PrivateFileWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try FileManager.default.removeItem(at: sandbox) }
    }

    func testFreshWriteUses0600With022Umask() throws {
        let destination = sandbox.appendingPathComponent("fresh.json")
        let bytes = Data("private state".utf8)
        let previousUmask = umask(mode_t(0o022))
        defer { _ = umask(previousUmask) }

        try PrivateFileWriter.write(bytes, to: destination)

        XCTAssertEqual(try permissions(destination), 0o600)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testWriteReplacesExisting0644FileWith0600File() throws {
        let destination = sandbox.appendingPathComponent("existing.json")
        try Data("old state".utf8).write(to: destination)
        XCTAssertEqual(chmod(destination.path, mode_t(0o644)), 0)

        let bytes = Data("new state".utf8)
        try PrivateFileWriter.write(bytes, to: destination)

        XCTAssertEqual(try permissions(destination), 0o600)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testWriteReplacesSymlinkWithoutChangingItsTarget() throws {
        let destination = sandbox.appendingPathComponent("state.json")
        let target = sandbox.appendingPathComponent("outside.json")
        let targetBytes = Data("outside state".utf8)
        try targetBytes.write(to: target)
        XCTAssertEqual(chmod(target.path, mode_t(0o644)), 0)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)

        let bytes = Data("private replacement".utf8)
        try PrivateFileWriter.write(bytes, to: destination)

        XCTAssertEqual(try fileType(destination), mode_t(S_IFREG))
        XCTAssertEqual(try permissions(destination), 0o600)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try permissions(target), 0o644)
        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
    }

    func testWriteToMissingParentThrows() {
        let destination = sandbox.appendingPathComponent("missing/state.json")
        XCTAssertThrowsError(try PrivateFileWriter.write(Data("state".utf8), to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
    }

    func testWriteOverDirectoryThrowsAndRemovesTemporaryFile() throws {
        let destination = sandbox.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(try PrivateFileWriter.write(Data("state".utf8), to: destination))

        let names = try FileManager.default.contentsOfDirectory(atPath: sandbox.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".c11-state.") && $0.hasSuffix(".tmp") })
    }

    func testWriteSupportsLongDestinationBasename() throws {
        let destination = sandbox.appendingPathComponent(String(repeating: "s", count: 240))
        let bytes = Data("private state".utf8)

        try PrivateFileWriter.write(bytes, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try permissions(destination), 0o600)
    }

    func testWriteClearsInheritedAllowACL() throws {
        let fixtureDirectory = sandbox.appendingPathComponent("acl-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let directoryACL = try makeACL("everyone allow read,file_inherit", on: fixtureDirectory)
        defer { acl_free(UnsafeMutableRawPointer(directoryACL)) }
        XCTAssertEqual(acl_set_file(sandbox.path, ACL_TYPE_EXTENDED, directoryACL), 0)

        let probe = sandbox.appendingPathComponent(".c11-state.probe.tmp")
        let descriptor = try PrivateFileWriter.openPrivateTemporaryFile(at: probe)
        defer {
            Darwin.close(descriptor)
            unlink(probe.path)
        }
        errno = 0
        let descriptorACL = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
        if let descriptorACL {
            acl_free(UnsafeMutableRawPointer(descriptorACL))
            XCTFail("temporary file inherited an extended ACL at creation")
        } else {
            XCTAssertEqual(errno, ENOENT)
        }

        let destination = sandbox.appendingPathComponent("inherited.json")
        try PrivateFileWriter.write(Data("private state".utf8), to: destination)

        errno = 0
        let writtenACL = acl_get_file(destination.path, ACL_TYPE_EXTENDED)
        if let writtenACL {
            acl_free(UnsafeMutableRawPointer(writtenACL))
            XCTFail("written state file retained an extended ACL")
        } else {
            XCTAssertEqual(errno, ENOENT)
        }
    }

    func testAllowACLOnReadableFileIsRefused() throws {
        let source = sandbox.appendingPathComponent("acl-readable.json")
        try Data("{}".utf8).write(to: source)
        XCTAssertEqual(chmod(source.path, mode_t(0o644)), 0)
        let aclFixture = sandbox.appendingPathComponent("acl-fixture.json")
        try Data("{}".utf8).write(to: aclFixture)
        let allowACL = try makeACL("everyone allow write", on: aclFixture)
        defer { acl_free(UnsafeMutableRawPointer(allowACL)) }
        XCTAssertEqual(acl_set_file(source.path, ACL_TYPE_EXTENDED, allowACL), 0)

        XCTAssertThrowsError(try PrivateFileWriter.readPrivateFile(at: source, maxBytes: 1024)) { error in
            XCTAssertEqual(error as? PrivateFileWriter.ReadError, .unsafeFile)
        }
    }

    func testOwnerOwned0644FileLoads() throws {
        let source = sandbox.appendingPathComponent("readable.json")
        let bytes = Data("{\"cookies\":[]}".utf8)
        try bytes.write(to: source)
        XCTAssertEqual(chmod(source.path, mode_t(0o644)), 0)

        XCTAssertEqual(try PrivateFileWriter.readPrivateFile(at: source, maxBytes: 1024), bytes)
    }

    func testGroupOrOtherWritableFileIsRefused() throws {
        let source = sandbox.appendingPathComponent("writable.json")
        try Data("{}".utf8).write(to: source)
        XCTAssertEqual(chmod(source.path, mode_t(0o666)), 0)

        XCTAssertThrowsError(try PrivateFileWriter.readPrivateFile(at: source, maxBytes: 1024)) { error in
            XCTAssertEqual(error as? PrivateFileWriter.ReadError, .unsafeFile)
        }
    }

    func testFileOverReadLimitIsRefused() throws {
        let source = sandbox.appendingPathComponent("large.json")
        try Data(repeating: 0x61, count: 33).write(to: source)

        XCTAssertThrowsError(try PrivateFileWriter.readPrivateFile(at: source, maxBytes: 32)) { error in
            XCTAssertEqual(error as? PrivateFileWriter.ReadError, .tooLarge)
        }
    }

    func testFIFOIsRefusedPromptly() throws {
        let source = sandbox.appendingPathComponent("state.fifo")
        XCTAssertEqual(mkfifo(source.path, mode_t(0o600)), 0)
        let start = ProcessInfo.processInfo.systemUptime

        XCTAssertThrowsError(try PrivateFileWriter.readPrivateFile(at: source, maxBytes: 1024)) { error in
            XCTAssertEqual(error as? PrivateFileWriter.ReadError, .unsafeFile)
        }

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.0)
    }

    func testSymlinkLoadIsRefused() throws {
        let target = sandbox.appendingPathComponent("target.json")
        let link = sandbox.appendingPathComponent("link.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try PrivateFileWriter.readPrivateFile(at: link, maxBytes: 1024)) { error in
            XCTAssertEqual(error as? PrivateFileWriter.ReadError, .unsafeFile)
        }
    }

    // MARK: - C11H-364: private folders, store writes, operator copies

    func testEnsurePrivateDirectoryCreatesMissingFolders0700() throws {
        let previousUmask = umask(mode_t(0o022))
        defer { _ = umask(previousUmask) }
        let folder = sandbox.appendingPathComponent("a/b/store", isDirectory: true)

        try PrivateFileWriter.ensurePrivateDirectory(at: folder)

        XCTAssertEqual(try permissions(folder), 0o700)
        XCTAssertEqual(try permissions(sandbox.appendingPathComponent("a/b", isDirectory: true)), 0o700)
    }

    func testEnsurePrivateDirectoryTightensExisting0755Folder() throws {
        let folder = sandbox.appendingPathComponent("loose", isDirectory: true)
        XCTAssertEqual(mkdir(folder.path, mode_t(0o755)), 0)
        XCTAssertEqual(chmod(folder.path, mode_t(0o755)), 0)

        try PrivateFileWriter.ensurePrivateDirectory(at: folder)

        XCTAssertEqual(try permissions(folder), 0o700)
    }

    func testEnsurePrivateDirectoryRefusesSymlinkAndLeavesItsTarget() throws {
        let target = sandbox.appendingPathComponent("elsewhere", isDirectory: true)
        XCTAssertEqual(mkdir(target.path, mode_t(0o755)), 0)
        XCTAssertEqual(chmod(target.path, mode_t(0o755)), 0)
        let link = sandbox.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try PrivateFileWriter.ensurePrivateDirectory(at: link)) { error in
            XCTAssertEqual(error as? PrivateFileWriter.DirectoryError, .unsafeDirectory(link.standardizedFileURL.path))
        }
        XCTAssertEqual(try permissions(target), 0o755)
    }

    func testEnsurePrivateDirectoryFollowsOwnLinkOnlyWhenAllowed() throws {
        // c11's migration leaves ~/.c11-snapshots as the user's own link to
        // the folder it adopted; a home store may follow it.
        let target = sandbox.appendingPathComponent("adopted", isDirectory: true)
        XCTAssertEqual(mkdir(target.path, mode_t(0o755)), 0)
        XCTAssertEqual(chmod(target.path, mode_t(0o755)), 0)
        let link = sandbox.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try PrivateFileWriter.ensurePrivateDirectory(at: link, allowOwnSymlink: true)

        XCTAssertEqual(try permissions(target), 0o700)
        // A link another account owns is never followed.
        XCTAssertThrowsError(try PrivateFileWriter.ensurePrivateDirectory(
            at: link, expectedOwner: getuid() &+ 1, allowOwnSymlink: true))
    }

    func testEnsurePrivateDirectoryRefusesFolderAnotherUserOwns() throws {
        let folder = sandbox.appendingPathComponent("theirs", isDirectory: true)
        XCTAssertEqual(mkdir(folder.path, mode_t(0o777)), 0)
        XCTAssertEqual(chmod(folder.path, mode_t(0o777)), 0)

        // Another account's folder, as seen from this uid: the owner differs.
        XCTAssertThrowsError(try PrivateFileWriter.ensurePrivateDirectory(at: folder, expectedOwner: getuid() &+ 1))
        XCTAssertEqual(try permissions(folder), 0o777)
    }

    func testWritePrivateStoreTightensFolderAndWrites0600() throws {
        let previousUmask = umask(mode_t(0o022))
        defer { _ = umask(previousUmask) }
        let folder = sandbox.appendingPathComponent(".cmuxterm", isDirectory: true)
        XCTAssertEqual(mkdir(folder.path, mode_t(0o755)), 0)
        let store = folder.appendingPathComponent("tmux-compat-store.json")
        try Data("old".utf8).write(to: store)
        XCTAssertEqual(chmod(store.path, mode_t(0o644)), 0)

        try PrivateFileWriter.writePrivateStore(Data("captured pane text".utf8), to: store)

        XCTAssertEqual(try permissions(folder), 0o700)
        XCTAssertEqual(try permissions(store), 0o600)
        XCTAssertEqual(try Data(contentsOf: store), Data("captured pane text".utf8))
    }

    func testWritePrivateStoreOverrideFolderKeepsItsModeButFileIs0600() throws {
        let previousUmask = umask(mode_t(0o022))
        defer { _ = umask(previousUmask) }
        let folder = sandbox.appendingPathComponent("override", isDirectory: true)
        XCTAssertEqual(mkdir(folder.path, mode_t(0o755)), 0)
        let store = folder.appendingPathComponent("claude-hook-sessions.json")

        try PrivateFileWriter.writePrivateStore(Data("{}".utf8), to: store, tightenFolder: false)

        XCTAssertEqual(try permissions(folder), 0o755)
        XCTAssertEqual(try permissions(store), 0o600)
    }

    func testWriteCopyRefusesNonEmptyFolderAndDeletesNothing() throws {
        let out = sandbox.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let keep = out.appendingPathComponent("nested/keep.txt")
        try Data("operator file".utf8).write(to: keep)

        XCTAssertThrowsError(try PrivateFileWriter.writeCopy(Data("snapshot".utf8), to: out)) { error in
            XCTAssertEqual(error as? PrivateFileWriter.CopyError, .destinationIsNonEmptyDirectory(out.path))
        }
        XCTAssertEqual(try Data(contentsOf: keep), Data("operator file".utf8))
        XCTAssertEqual(try fileType(out), mode_t(S_IFDIR))
    }

    func testWriteCopyReplacesEmptyFolderWith0600File() throws {
        let previousUmask = umask(mode_t(0o022))
        defer { _ = umask(previousUmask) }
        let out = sandbox.appendingPathComponent("empty", isDirectory: true)
        XCTAssertEqual(mkdir(out.path, mode_t(0o755)), 0)

        try PrivateFileWriter.writeCopy(Data("snapshot".utf8), to: out)

        XCTAssertEqual(try fileType(out), mode_t(S_IFREG))
        XCTAssertEqual(try permissions(out), 0o600)
    }

    func testWriteCopyCreatesMissingParents0700AndKeepsExistingParentMode() throws {
        let previousUmask = umask(mode_t(0o022))
        defer { _ = umask(previousUmask) }
        let existing = sandbox.appendingPathComponent("Desktop", isDirectory: true)
        XCTAssertEqual(mkdir(existing.path, mode_t(0o755)), 0)
        XCTAssertEqual(chmod(existing.path, mode_t(0o755)), 0)
        let out = existing.appendingPathComponent("new/session.json")

        try PrivateFileWriter.writeCopy(Data("snapshot".utf8), to: out)

        XCTAssertEqual(try permissions(existing), 0o755)
        XCTAssertEqual(try permissions(existing.appendingPathComponent("new", isDirectory: true)), 0o700)
        XCTAssertEqual(try permissions(out), 0o600)
    }

    func testWriteCopyReplacesSymlinkWithoutWritingThroughIt() throws {
        let target = sandbox.appendingPathComponent("victim.txt")
        try Data("victim".utf8).write(to: target)
        let out = sandbox.appendingPathComponent("session.json")
        try FileManager.default.createSymbolicLink(at: out, withDestinationURL: target)

        try PrivateFileWriter.writeCopy(Data("snapshot".utf8), to: out)

        XCTAssertEqual(try fileType(out), mode_t(S_IFREG))
        XCTAssertEqual(try Data(contentsOf: target), Data("victim".utf8))
    }

    // The CLI prints `Error: \(error)`; the refusal must read as its sentence.
    func testDirectoryErrorPrintsItsLocalizedText() throws {
        let notAFolder = sandbox.appendingPathComponent(".cmuxterm")
        try Data("a file".utf8).write(to: notAFolder)

        XCTAssertThrowsError(try PrivateFileWriter.writePrivateStore(
            Data("{}".utf8), to: notAFolder.appendingPathComponent("tmux-compat-store.json"))) { error in
            XCTAssertTrue(error is PrivateFileWriter.DirectoryError, "\(type(of: error))")
            XCTAssertEqual(String(describing: error), error.localizedDescription)
            XCTAssertTrue("\(error)".contains(notAFolder.path), "\(error)")
        }
    }

    func testCopyErrorPrintsItsLocalizedText() throws {
        let out = sandbox.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: out.appendingPathComponent("keep.txt"))

        XCTAssertThrowsError(try PrivateFileWriter.writeCopy(Data("snapshot".utf8), to: out)) { error in
            XCTAssertTrue(error is PrivateFileWriter.CopyError, "\(type(of: error))")
            XCTAssertEqual(String(describing: error), error.localizedDescription)
            XCTAssertTrue("\(error)".contains(out.path), "\(error)")
        }
    }

    func testTightenExistingStoreRootsSetsRootsTo0700AndCreatesNothing() throws {
        let home = sandbox.appendingPathComponent("home", isDirectory: true)
        XCTAssertEqual(mkdir(home.path, mode_t(0o755)), 0)
        // mkdir honours the process umask, which this test does not own.
        XCTAssertEqual(chmod(home.path, mode_t(0o755)), 0)
        let roots = PrivateFileWriter.storeRoots(home: home)
        let snapshots = home.appendingPathComponent(".c11-snapshots", isDirectory: true)
        let cmuxterm = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        let hookState = home.appendingPathComponent(".c11", isDirectory: true)
        XCTAssertEqual(roots.map(\.lastPathComponent), [".c11-snapshots", ".cmuxterm", ".c11"])
        // A 1.x store: a 0755 folder holding a 0644 file.
        XCTAssertEqual(mkdir(snapshots.path, mode_t(0o755)), 0)
        XCTAssertEqual(chmod(snapshots.path, mode_t(0o755)), 0)
        let old = snapshots.appendingPathComponent("01OLD.json")
        try Data("{}".utf8).write(to: old)
        XCTAssertEqual(chmod(old.path, mode_t(0o644)), 0)
        // A store that is the user's link to a 0755 folder is not followed.
        let adopted = home.appendingPathComponent("adopted", isDirectory: true)
        XCTAssertEqual(mkdir(adopted.path, mode_t(0o755)), 0)
        XCTAssertEqual(chmod(adopted.path, mode_t(0o755)), 0)
        try FileManager.default.createSymbolicLink(at: hookState, withDestinationURL: adopted)

        let changed = PrivateFileWriter.tightenExistingStoreRoots(roots)

        XCTAssertEqual(changed.map(\.lastPathComponent), [".c11-snapshots"])
        XCTAssertEqual(try permissions(snapshots), 0o700)
        XCTAssertEqual(try permissions(old), 0o644, "files inside are left alone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cmuxterm.path), "a missing root stays missing")
        XCTAssertEqual(try fileType(hookState), mode_t(S_IFLNK))
        XCTAssertEqual(try permissions(adopted), 0o755)
        XCTAssertEqual(try permissions(home), 0o755)
    }

    private func makeACL(_ text: String, on url: URL) throws -> acl_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", text, url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return acl
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func fileType(_ url: URL) throws -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & mode_t(S_IFMT)
    }
}
