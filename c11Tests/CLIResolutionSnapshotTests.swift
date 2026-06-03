import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class CLIResolutionSnapshotTests: XCTestCase {

    private func makeInputs(
        env: [String: String],
        commands: [String: String?] = [:],
        existing: Set<String> = [],
        versions: [String: String] = [:]
    ) -> CLIResolutionInputs {
        return CLIResolutionInputs(
            environment: env,
            commandLookup: { name in commands[name] ?? nil },
            executableExists: { path in existing.contains(path) },
            versionLookup: { path in versions[path] }
        )
    }

    // MARK: - Status classification

    func testStatusOkWhenBundledAndPathAgree() {
        let bundled = "/Applications/c11.app/Contents/Resources/bin/c11"
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": bundled,
                "PATH": "/Applications/c11.app/Contents/Resources/bin:/usr/local/bin:/usr/bin",
            ],
            commands: ["c11": bundled, "cmux": nil],
            existing: [bundled]
        ))
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertTrue(snapshot.pathFixApplied)
        XCTAssertEqual(snapshot.bundledCliPath, bundled)
        XCTAssertEqual(snapshot.c11OnPath, bundled)
        XCTAssertNil(snapshot.cmuxOnPath)
        XCTAssertTrue(snapshot.notes.isEmpty)
    }

    func testStatusMismatchWhenC11OnPathIsNotBundled() {
        let bundled = "/Applications/c11.app/Contents/Resources/bin/c11"
        let stale = "/usr/local/bin/c11"
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": bundled,
                "PATH": "/usr/local/bin:/usr/bin",
            ],
            commands: ["c11": stale, "cmux": nil],
            existing: [bundled, stale]
        ))
        XCTAssertEqual(snapshot.status, .mismatch)
        XCTAssertFalse(snapshot.pathFixApplied, "bundled bin dir is not first on PATH")
        XCTAssertEqual(snapshot.c11OnPath, stale)
        XCTAssertTrue(snapshot.notes.contains(where: { $0.contains("not the active bundle") }))
    }

    func testStatusMissingWhenC11NotOnPath() {
        let bundled = "/Applications/c11.app/Contents/Resources/bin/c11"
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": bundled,
                "PATH": "/usr/bin:/bin",
            ],
            commands: ["c11": nil, "cmux": nil],
            existing: [bundled]
        ))
        XCTAssertEqual(snapshot.status, .missing)
        XCTAssertNil(snapshot.c11OnPath)
        XCTAssertTrue(snapshot.notes.contains(where: { $0.contains("_cmux_fix_path") }))
    }

    func testStatusNoBundleWhenEnvUnset() {
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: ["PATH": "/usr/local/bin:/usr/bin"],
            commands: ["c11": "/usr/local/bin/c11", "cmux": "/usr/local/bin/cmux"]
        ))
        XCTAssertEqual(snapshot.status, .noBundle)
        XCTAssertNil(snapshot.bundledCliPath)
        XCTAssertEqual(snapshot.c11OnPath, "/usr/local/bin/c11")
        XCTAssertTrue(snapshot.notes.contains(where: { $0.contains("CMUX_BUNDLED_CLI_PATH") }))
    }

    func testStatusMismatchWhenBundledFileMissing() {
        let bundled = "/Applications/c11.app/Contents/Resources/bin/c11"
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": bundled,
                "PATH": "/usr/bin",
            ],
            commands: ["c11": "/usr/bin/c11", "cmux": nil],
            existing: ["/usr/bin/c11"]  // bundled file does not exist
        ))
        XCTAssertEqual(snapshot.status, .mismatch)
        XCTAssertTrue(snapshot.notes.contains(where: { $0.contains("not an executable file") }))
    }

    // MARK: - cmux coexistence note

    func testCmuxNoteFiresWhenUpstreamCmuxOnPath() {
        let bundled = "/Applications/c11.app/Contents/Resources/bin/c11"
        let upstreamCmux = "/opt/homebrew/bin/cmux"
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": bundled,
                "PATH": "/Applications/c11.app/Contents/Resources/bin:/opt/homebrew/bin",
            ],
            commands: ["c11": bundled, "cmux": upstreamCmux],
            existing: [bundled, upstreamCmux]
        ))
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.cmuxOnPath, upstreamCmux)
        XCTAssertTrue(
            snapshot.notes.contains(where: { $0.contains("intentional") }),
            "Doctor should explain that an upstream cmux is intentional, not a bug"
        )
    }

    // MARK: - Trimming and edge cases

    func testWhitespaceAroundEnvValuesIsTolerated() {
        let bundled = "/Applications/c11.app/Contents/Resources/bin/c11"
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": "  \(bundled)  ",
                "PATH": "/Applications/c11.app/Contents/Resources/bin:/usr/bin",
            ],
            commands: ["c11": "  \(bundled)\n", "cmux": nil],
            existing: [bundled]
        ))
        XCTAssertEqual(snapshot.bundledCliPath, bundled)
        XCTAssertEqual(snapshot.c11OnPath, bundled)
        XCTAssertEqual(snapshot.status, .ok)
    }

    func testEmptyEnvValuesAreNormalizedToNil() {
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": "   ",
                "PATH": "/usr/bin",
            ]
        ))
        XCTAssertNil(snapshot.bundledCliPath)
        XCTAssertEqual(snapshot.status, .noBundle)
    }

    // MARK: - JSON shape

    func testJSONShapeIsStable() {
        let bundled = "/Applications/c11.app/Contents/Resources/bin/c11"
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: [
                "CMUX_BUNDLED_CLI_PATH": bundled,
                "PATH": "/Applications/c11.app/Contents/Resources/bin:/usr/bin",
            ],
            commands: ["c11": bundled, "cmux": nil],
            existing: [bundled],
            versions: [bundled: "0.46.0"]
        ))
        let dict = snapshot.toJSONDictionary()

        XCTAssertEqual(dict["status"] as? String, "ok")
        XCTAssertEqual(dict["bundled_cli_path"] as? String, bundled)
        XCTAssertEqual(dict["c11_on_path"] as? String, bundled)
        XCTAssertEqual(dict["bundled_cli_version"] as? String, "0.46.0")
        XCTAssertEqual(dict["c11_on_path_version"] as? String, "0.46.0")
        XCTAssertEqual(dict["path_fix_applied"] as? Bool, true)
        XCTAssertEqual(dict["path"] as? [String], [
            "/Applications/c11.app/Contents/Resources/bin",
            "/usr/bin",
        ])
        XCTAssertEqual(dict["notes"] as? [String], [])
        XCTAssertNil(dict["cmux_on_path"], "Omit unset fields rather than serialize null")
    }

    func testJSONOmitsAbsentBundleAndCommands() {
        let snapshot = CLIResolutionSnapshot.collect(inputs: makeInputs(
            env: ["PATH": "/usr/bin"]
        ))
        let dict = snapshot.toJSONDictionary()

        XCTAssertEqual(dict["status"] as? String, "no_bundle")
        XCTAssertNil(dict["bundled_cli_path"])
        XCTAssertNil(dict["c11_on_path"])
        XCTAssertNil(dict["cmux_on_path"])
    }

    // MARK: - Argument parsing

    func testParseDoctorArgsDefault() throws {
        let opts = try parseDoctorCLIArgs([])
        XCTAssertFalse(opts.json)
    }

    func testParseDoctorArgsJsonFlag() throws {
        let opts = try parseDoctorCLIArgs(["--json"])
        XCTAssertTrue(opts.json)
    }

    func testParseDoctorArgsRejectsUnknownFlag() {
        XCTAssertThrowsError(try parseDoctorCLIArgs(["--unknown"])) { error in
            guard let err = error as? DoctorCLIError else {
                XCTFail("expected DoctorCLIError, got \(error)")
                return
            }
            switch err {
            case .unknownFlag(let f): XCTAssertEqual(f, "--unknown")
            }
        }
    }

    func testParseDoctorArgsTolerablesHelp() throws {
        // Help is dispatched upstream; the parser should not error on it.
        let opts = try parseDoctorCLIArgs(["--help"])
        XCTAssertFalse(opts.json)
    }

    // MARK: - Default command lookup helper

    func testDefaultCommandLookupSkipsEmptyPathEntries() {
        // PATH is allowed to contain empty entries (e.g. "::"). Make sure we
        // don't try to resolve them as ".".
        let env = ["PATH": "::/usr/bin"]
        // Use a name that almost certainly doesn't exist so the lookup
        // exhausts the path without crashing on the empty entries.
        let result = defaultCommandLookup("__c11_doctor_does_not_exist__", environment: env)
        XCTAssertNil(result)
    }
}
