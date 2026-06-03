import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Behavioral tests for the `--cwd` flag validation shared by `new-split`
/// (`surface.split`) and `new-pane` (`pane.create`). Exercises the pure
/// `CwdParamResolution.resolve(_:)` seam against the real filesystem (temp
/// directories) so we verify the actual existence/directory checks, not source
/// shape.
final class CwdParamResolutionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-cwd-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - inherit (default) outcomes

    func testNilParamInherits() {
        XCTAssertEqual(CwdParamResolution.resolve(nil), .inherit)
    }

    func testEmptyStringInherits() {
        XCTAssertEqual(CwdParamResolution.resolve(""), .inherit)
        XCTAssertEqual(CwdParamResolution.resolve("   "), .inherit)
    }

    func testInheritKeywordInherits() {
        XCTAssertEqual(CwdParamResolution.resolve("inherit"), .inherit)
    }

    func testInheritKeywordIsCaseInsensitiveAndTrimmed() {
        XCTAssertEqual(CwdParamResolution.resolve("INHERIT"), .inherit)
        XCTAssertEqual(CwdParamResolution.resolve("  Inherit  "), .inherit)
    }

    // MARK: - valid path outcomes

    func testExistingDirectoryResolvesToStandardizedAbsolutePath() throws {
        // standardizingPath resolves /var -> /private/var on macOS; resolve the
        // expected value the same way so the assertion is path-canonical.
        let expected = NSString(string: tempDir.path).standardizingPath
        guard case .path(let resolved) = CwdParamResolution.resolve(tempDir.path) else {
            return XCTFail("expected .path for an existing directory")
        }
        XCTAssertEqual(resolved, expected)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testTrailingWhitespaceTrimmedBeforeResolving() throws {
        let expected = NSString(string: tempDir.path).standardizingPath
        guard case .path(let resolved) = CwdParamResolution.resolve("  \(tempDir.path)  ") else {
            return XCTFail("expected .path after trimming whitespace")
        }
        XCTAssertEqual(resolved, expected)
    }

    func testTildeIsExpanded() throws {
        // ~ expands to the real home directory, which exists and is a directory.
        guard case .path(let resolved) = CwdParamResolution.resolve("~") else {
            return XCTFail("expected ~ to expand to an existing home directory")
        }
        let expectedHome = NSString(string: NSString(string: "~").expandingTildeInPath).standardizingPath
        XCTAssertEqual(resolved, expectedHome)
        XCTAssertTrue(resolved.hasPrefix("/"))
    }

    // MARK: - invalid outcomes

    func testNonStringIsInvalid() {
        guard case .invalid(let code, _, let path) = CwdParamResolution.resolve(42) else {
            return XCTFail("expected .invalid for a non-string value")
        }
        XCTAssertEqual(code, "invalid_params")
        XCTAssertNil(path)
    }

    func testNonexistentPathIsNotFound() {
        let missing = tempDir.appendingPathComponent("does-not-exist", isDirectory: true).path
        guard case .invalid(let code, _, let path) = CwdParamResolution.resolve(missing) else {
            return XCTFail("expected .invalid for a nonexistent path")
        }
        XCTAssertEqual(code, "not_found")
        XCTAssertEqual(path, NSString(string: missing).standardizingPath)
    }

    func testFilePathIsRejectedAsNotADirectory() throws {
        let fileURL = tempDir.appendingPathComponent("a-file.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)
        guard case .invalid(let code, let message, let path) = CwdParamResolution.resolve(fileURL.path) else {
            return XCTFail("expected .invalid for a regular file")
        }
        XCTAssertEqual(code, "invalid_params")
        XCTAssertTrue(message.contains("not a directory"))
        XCTAssertEqual(path, NSString(string: fileURL.path).standardizingPath)
    }

    func testRelativePathIsRejectedAsNonAbsolute() {
        // A bare relative segment that does not begin with / or ~ stays
        // relative after expansion and must be rejected — the CLI is
        // responsible for resolving relative paths to absolute before sending.
        guard case .invalid(let code, _, _) = CwdParamResolution.resolve("some/relative/dir") else {
            return XCTFail("expected .invalid for a relative path")
        }
        XCTAssertEqual(code, "invalid_params")
    }
}
