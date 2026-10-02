import Darwin
import Foundation
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class LaunchPromptStoreTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("LaunchPromptStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try FileManager.default.removeItem(at: sandbox) }
    }

    private var root: URL { sandbox.appendingPathComponent("Application Support/launch-prompts", isDirectory: true) }

    func testExactUTF8CopyIncludingWhitespaceAndShellCharacters() throws {
        let caller = sandbox.appendingPathComponent("caller original.txt")
        let body = " \n\t'quotes' `touch sentinel` $(echo injection) $HOME 🪨 café\n" + String(repeating: "長", count: 11_000) + "\n  "
        let bytes = Data(body.utf8)
        try bytes.write(to: caller)
        let store = LaunchPromptStore(rootDirectory: root)
        let prompt = try store.stage(prompt: String(contentsOf: caller, encoding: .utf8))
        XCTAssertNotEqual(prompt.url, caller)
        XCTAssertEqual(try Data(contentsOf: prompt.url), bytes)
        store.discard(prompt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prompt.url.path))
        XCTAssertEqual(try Data(contentsOf: caller), bytes)
    }

    func testPrivateDirectoryAndFileModes() throws {
        let store = LaunchPromptStore(rootDirectory: root)
        let prompt = try store.stage(prompt: "synthetic private fixture")
        XCTAssertEqual(try permissions(root), 0o700)
        XCTAssertEqual(try permissions(prompt.url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(prompt.url), 0o600)
    }

    func testActiveFileSurvivesOldTimestampAndLateReadUntilClose() throws {
        let store = LaunchPromptStore(rootDirectory: root)
        let prompt = try store.stage(prompt: "delayed synthetic fixture\n")
        let owner = UUID()
        try store.retain(prompt, owner: owner)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: prompt.url.path)
        // Subsequent staging cannot sweep an old file retained by a live tab.
        _ = try store.stage(prompt: "new launch")
        store.discard(prompt)
        XCTAssertEqual(try String(contentsOf: prompt.url, encoding: .utf8), "delayed synthetic fixture\n")
        store.release(owner: owner)
        store.waitForPendingCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: prompt.url.path))
    }

    func testCloseCleansAllFilesForOnlyThatActualOwner() throws {
        let store = LaunchPromptStore(rootDirectory: root)
        let first = try store.stage(prompt: "first")
        let second = try store.stage(prompt: "second")
        let other = try store.stage(prompt: "other")
        let closedOwner = UUID()
        let otherOwner = UUID()
        try store.retain(first, owner: closedOwner)
        try store.retain(second, owner: closedOwner)
        try store.retain(other, owner: otherOwner)
        store.release(owner: closedOwner)
        store.waitForPendingCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertEqual(try Data(contentsOf: other.url), Data("other".utf8))
    }

    func testCloseBeforeBindRejectsLateLaunchAndFailureDiscardRemovesFile() throws {
        let store = LaunchPromptStore(rootDirectory: root)
        let prompt = try store.stage(prompt: "not yet committed")
        let owner = UUID()
        store.release(owner: owner)
        XCTAssertThrowsError(try store.retain(prompt, owner: owner)) { error in
            XCTAssertEqual(error as? LaunchPromptStore.StoreError, .ownerReleased)
        }
        store.discard(prompt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prompt.url.path))
    }

    func testAnotherStoreCannotBindOrDeleteOurPrompt() throws {
        let firstStore = LaunchPromptStore(rootDirectory: root)
        let secondStore = LaunchPromptStore(rootDirectory: root)
        let first = try firstStore.stage(prompt: "first instance")
        let second = try secondStore.stage(prompt: "second instance")
        XCTAssertNotEqual(first.url.deletingLastPathComponent(), second.url.deletingLastPathComponent())
        XCTAssertThrowsError(try secondStore.retain(first, owner: UUID()))
        secondStore.discard(first)
        let owner = UUID()
        try firstStore.retain(first, owner: owner)
        firstStore.release(owner: owner)
        firstStore.waitForPendingCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(try Data(contentsOf: second.url), Data("second instance".utf8))
    }

    func testExclusiveCreationCannotOverwriteAnExistingPrompt() throws {
        let fixedID = UUID()
        let store = LaunchPromptStore(rootDirectory: root, nextFileID: { fixedID })
        let first = try store.stage(prompt: "original")
        XCTAssertThrowsError(try store.stage(prompt: "replacement"))
        XCTAssertEqual(try String(contentsOf: first.url, encoding: .utf8), "original")
    }

    func testSymlinkRootIsRefusedWithoutWritingTarget() throws {
        let target = sandbox.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
        let store = LaunchPromptStore(rootDirectory: root)
        XCTAssertThrowsError(try store.stage(prompt: "must not be written"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testSymlinkFileIsRefusedWithoutReadingOrDeletingTarget() throws {
        let store = LaunchPromptStore(rootDirectory: root)
        let prompt = try store.stage(prompt: "staged")
        let target = sandbox.appendingPathComponent("caller-owned.txt")
        try Data("caller-owned bytes".utf8).write(to: target)
        try FileManager.default.removeItem(at: prompt.url)
        try FileManager.default.createSymbolicLink(at: prompt.url, withDestinationURL: target)
        XCTAssertThrowsError(try store.validate(prompt)) { error in
            XCTAssertEqual(error as? LaunchPromptStore.StoreError, .unsafeFile)
        }
        store.discard(prompt)
        XCTAssertEqual(try Data(contentsOf: target), Data("caller-owned bytes".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: prompt.url.path), target.path)
    }

    func testExclusiveCreationRefusesAnExistingSymlink() throws {
        let fixedID = UUID()
        let store = LaunchPromptStore(rootDirectory: root, nextFileID: { fixedID })
        let prompt = try store.stage(prompt: "original")
        let target = sandbox.appendingPathComponent("external-original.txt")
        try Data("unchanged target".utf8).write(to: target)
        try FileManager.default.removeItem(at: prompt.url)
        try FileManager.default.createSymbolicLink(at: prompt.url, withDestinationURL: target)
        XCTAssertThrowsError(try store.stage(prompt: "must never reach target"))
        XCTAssertEqual(try Data(contentsOf: target), Data("unchanged target".utf8))
    }

    func testNamespaceReplacementIsRefusedAndCleanupUsesOriginalDirectory() throws {
        let store = LaunchPromptStore(rootDirectory: root)
        let prompt = try store.stage(prompt: "original private copy")
        let directory = prompt.url.deletingLastPathComponent()
        let moved = sandbox.appendingPathComponent("original namespace", isDirectory: true)
        let replacement = sandbox.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let externalFile = replacement.appendingPathComponent(prompt.url.lastPathComponent)
        try Data("other instance data".utf8).write(to: externalFile)
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: replacement)
        XCTAssertThrowsError(try store.validate(prompt))
        XCTAssertThrowsError(try store.stage(prompt: "must not stage into substitute"))
        store.discard(prompt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent(prompt.url.lastPathComponent).path))
        XCTAssertEqual(try Data(contentsOf: externalFile), Data("other instance data".utf8))
    }

    func testUnwritableRootFailsBeforeCreatingAFile() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        defer { chmod(root.path, 0o700) }
        let store = LaunchPromptStore(rootDirectory: root)
        XCTAssertThrowsError(try store.stage(prompt: "cannot stage"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testWhitespaceOnlyPromptDoesNotCreateRuntimeDirectory() {
        let store = LaunchPromptStore(rootDirectory: root)
        XCTAssertThrowsError(try store.stage(prompt: " \t\r\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRepeatedRetainIsIdempotentButCannotTransferOwnership() throws {
        let store = LaunchPromptStore(rootDirectory: root)
        let prompt = try store.stage(prompt: "bound once")
        let owner = UUID()
        try store.retain(prompt, owner: owner)
        try store.retain(prompt, owner: owner)
        XCTAssertThrowsError(try store.retain(prompt, owner: UUID())) { error in
            XCTAssertEqual(error as? LaunchPromptStore.StoreError, .alreadyRetained)
        }
        store.release(owner: owner)
        store.waitForPendingCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: prompt.url.path))
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
