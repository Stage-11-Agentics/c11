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
        XCTAssertFalse(names.contains { $0.hasPrefix(".directory.") && $0.hasSuffix(".tmp") })
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
