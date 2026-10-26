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
