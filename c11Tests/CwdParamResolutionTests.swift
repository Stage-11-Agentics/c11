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

/// `c11TwinKey` decides which managed surface env vars get a canonical `C11_*`
/// twin exported alongside the legacy `CMUX_*` name, so agents can rely on
/// `$C11_SURFACE_ID` / `$C11_TAB_ID` / `$C11_SHELL_INTEGRATION` etc.
final class C11TwinKeyTests: XCTestCase {
    func testMapsManagedCmuxKeysToC11() {
        XCTAssertEqual(c11TwinKey(forCmuxKey: "CMUX_SURFACE_ID"), "C11_SURFACE_ID")
        XCTAssertEqual(c11TwinKey(forCmuxKey: "CMUX_TAB_ID"), "C11_TAB_ID")
        XCTAssertEqual(c11TwinKey(forCmuxKey: "CMUX_WORKSPACE_ID"), "C11_WORKSPACE_ID")
        XCTAssertEqual(c11TwinKey(forCmuxKey: "CMUX_SHELL_INTEGRATION"), "C11_SHELL_INTEGRATION")
    }

    func testReturnsNilForNonCmuxKeys() {
        // Already-canonical and unrelated keys must not be re-twinned.
        XCTAssertNil(c11TwinKey(forCmuxKey: "C11_SURFACE_ID"))
        XCTAssertNil(c11TwinKey(forCmuxKey: "PATH"))
        XCTAssertNil(c11TwinKey(forCmuxKey: "ZDOTDIR"))
        XCTAssertNil(c11TwinKey(forCmuxKey: ""))
    }

    func testBarePrefixMapsToBareC11Prefix() {
        // Degenerate but well-defined: the suffix after CMUX_ is empty.
        XCTAssertEqual(c11TwinKey(forCmuxKey: "CMUX_"), "C11_")
    }
}

/// `c11EnvAliasOverrides` reads the 11mux input aliases (`MUX11_*`,
/// `ELEVENMUX_*`, `MUXELEVEN_*`) as fill-only fallbacks for `C11_*` / `CMUX_*`.
final class C11EnvAliasOverrideTests: XCTestCase {
    func testAliasFillsBothCanonicalNames() {
        let result = c11EnvAliasOverrides(in: ["MUX11_SOCKET_PATH": "/tmp/a.sock"])
        XCTAssertEqual(result.values, ["C11_SOCKET_PATH": "/tmp/a.sock", "CMUX_SOCKET_PATH": "/tmp/a.sock"])
        XCTAssertEqual(result.conflicts, [])
    }

    func testEachAliasPrefixIsRead() {
        let result = c11EnvAliasOverrides(in: [
            "ELEVENMUX_PANEL_ID": "p1",
            "MUXELEVEN_WORKSPACE_ID": "w1",
        ])
        XCTAssertEqual(result.values["C11_PANEL_ID"], "p1")
        XCTAssertEqual(result.values["C11_WORKSPACE_ID"], "w1")
    }

    func testSetCanonicalValueWinsOverAlias() {
        // Launchers and panels set C11_* / CMUX_* explicitly; a stray exported
        // alias must not redirect them (C11-155 inheritance hazard).
        XCTAssertEqual(c11EnvAliasOverrides(in: [
            "C11_SOCKET_PATH": "/launcher.sock",
            "MUX11_SOCKET_PATH": "/stray.sock",
        ]).values, [:])
        XCTAssertEqual(c11EnvAliasOverrides(in: [
            "CMUX_SOCKET_PATH": "/legacy.sock",
            "MUX11_SOCKET_PATH": "/stray.sock",
        ]).values, [:])
    }

    func testEmptyValuesAreUnset() {
        XCTAssertEqual(c11EnvAliasOverrides(in: ["MUX11_SOCKET_PATH": "  "]).values, [:])
        // An empty canonical value does not block the alias.
        XCTAssertEqual(c11EnvAliasOverrides(in: [
            "C11_SOCKET_PATH": "",
            "MUX11_SOCKET_PATH": "/a.sock",
        ]).values["C11_SOCKET_PATH"], "/a.sock")
    }

    func testPrecedenceAndConflictNotice() {
        let result = c11EnvAliasOverrides(in: [
            "MUXELEVEN_SOCKET_PATH": "/c.sock",
            "ELEVENMUX_SOCKET_PATH": "/b.sock",
            "MUX11_SOCKET_PATH": "/a.sock",
        ])
        XCTAssertEqual(result.values["C11_SOCKET_PATH"], "/a.sock")
        XCTAssertEqual(result.conflicts, [
            "MUX11_SOCKET_PATH and ELEVENMUX_SOCKET_PATH disagree; using MUX11_SOCKET_PATH",
            "MUX11_SOCKET_PATH and MUXELEVEN_SOCKET_PATH disagree; using MUX11_SOCKET_PATH",
        ])
    }

    func testAgreeingAliasesRaiseNoNotice() {
        let result = c11EnvAliasOverrides(in: ["MUX11_TAG": "x", "ELEVENMUX_TAG": "x"])
        XCTAssertEqual(result.values["C11_TAG"], "x")
        XCTAssertEqual(result.conflicts, [])
    }

    func testIgnoresBarePrefixesAndUnrelatedKeys() {
        let result = c11EnvAliasOverrides(in: [
            "MUX11_": "bare",
            "MUX11": "no-underscore",
            "PATH": "/usr/bin",
        ])
        XCTAssertEqual(result.values, [:])
        XCTAssertEqual(result.conflicts, [])
    }

    private func repoFile(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func aliasBlock(_ source: String) -> String? {
        guard let start = source.range(of: "/// Input-only aliases for the `C11_*` environment namespace"),
              let end = source.range(of: "// Mirrors CMUX_* ↔ C11_* env vars", range: start.upperBound..<source.endIndex)
        else { return nil }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    func testCLICopyMatchesAppCopy() throws {
        // The CLI target compiles its own copy; only the app copy is unit tested.
        let app = try XCTUnwrap(aliasBlock(repoFile("Sources/AppDelegate.swift")))
        let cli = try XCTUnwrap(aliasBlock(repoFile("CLI/c11.swift")))
        XCTAssertEqual(cli, app)
    }

    func testBuildPhaseLinksEveryAliasName() throws {
        // The app bundle's symlinks are made by a shell build phase; keep its
        // list equal to c11CLICommandNames minus the real binary and cmux.
        let project = try repoFile("GhosttyTabs.xcodeproj/project.pbxproj")
        let marker = "for alias_name in "
        let line = try XCTUnwrap(project.components(separatedBy: "\\n").first { $0.hasPrefix(marker) })
        let names = line.dropFirst(marker.count).replacingOccurrences(of: "; do", with: "")
            .split(separator: " ").map(String.init)
        XCTAssertEqual(names, c11CLICommandNames.filter { $0 != "c11" && $0 != "cmux" })
    }
}
