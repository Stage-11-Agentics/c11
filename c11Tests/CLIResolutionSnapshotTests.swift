import XCTest
import Darwin

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class CLIResolutionSnapshotTests: XCTestCase {

    private let codexID = "ddd11111-2222-3333-4444-555566667777"

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

    // MARK: - C11-206 shared resume decisions

    private func resumeInput(
        mode: ResumeRecoveryMode,
        ownership: ResumeOwnershipStatus = .unique,
        placeholder: Bool = false,
        state: ResumePersistedState = .suspended,
        idValid: Bool = true,
        transcript: ResumeTranscriptEvidence = .verified
    ) -> ResumeDecisionInput {
        ResumeDecisionInput(
            mode: mode,
            ownership: ownership,
            kind: "codex",
            id: codexID,
            placeholder: placeholder,
            state: state,
            exactIDValid: idValid,
            transcriptEvidence: transcript
        )
    }

    func testCodexCleanDecisionEmitsExactResumeCommand() {
        XCTAssertEqual(
            ResumeDecisionEngine.decide(resumeInput(mode: .clean, transcript: .notRequired)),
            .command(ResumeCommand(text: "codex resume --yolo '\(codexID)'"))
        )
    }

    func testCodexDirtyDecisionRequiresVerifiedTranscript() {
        XCTAssertEqual(
            ResumeDecisionEngine.decide(resumeInput(mode: .dirty, transcript: .verified)),
            .command(ResumeCommand(text: "codex resume --yolo '\(codexID)'"))
        )
        guard case .skip(let code, _) = ResumeDecisionEngine.decide(
            resumeInput(mode: .dirty, transcript: .missing)
        ) else {
            return XCTFail("missing dirty transcript must skip")
        }
        XCTAssertEqual(code, .transcriptMissing)
    }

    func testNoResumeOverridesUnauditedOwnership() {
        guard case .skip(let code, _) = ResumeDecisionEngine.decide(
            resumeInput(mode: .noResume, ownership: .unaudited)
        ) else {
            return XCTFail("no-resume must always skip")
        }
        XCTAssertEqual(code, .policyNoResume)
    }

    func testUnsafeIdentityIsATypedSkip() {
        guard case .skip(let duplicate, _) = ResumeDecisionEngine.decide(
            resumeInput(mode: .clean, ownership: .duplicate)
        ) else {
            return XCTFail("duplicate ownership must skip")
        }
        XCTAssertEqual(duplicate, .duplicateOwnership)

        guard case .skip(let placeholder, _) = ResumeDecisionEngine.decide(
            resumeInput(mode: .clean, placeholder: true)
        ) else {
            return XCTFail("placeholder must skip")
        }
        XCTAssertEqual(placeholder, .placeholder)
    }

    func testDelayedFinalStoreReadReturnsCompletedValueNotEmptyFallback() {
        let outcome: BoundedLifecycleOutcome<[String: String]> = BoundedLifecycleWait.run(
            timeout: 1.0
        ) {
            try await Task.sleep(nanoseconds: 20_000_000)
            return ["surface-1": "newly-resolved-exact-id"]
        }
        guard case .completed(let rows) = outcome else {
            return XCTFail("delayed read within budget must complete")
        }
        XCTAssertEqual(rows, ["surface-1": "newly-resolved-exact-id"])
    }

    func testTimedOutFinalStoreReadCannotBecomeEmptySuccess() {
        let outcome: BoundedLifecycleOutcome<[String: String]> = BoundedLifecycleWait.run(
            timeout: 0.005
        ) {
            try await Task.sleep(nanoseconds: 100_000_000)
            return ["surface-1": "late-value"]
        }
        guard case .timedOut = outcome else {
            return XCTFail("late store read must report timeout, not an empty map")
        }
        XCTAssertFalse(CleanPersistencePromotionPolicy.allowsPromotion(
            resolutionCompleted: true,
            finalStoreReadCompleted: false,
            durableSnapshotWriteCompleted: true
        ))
    }

    func testDelayedDurableWriteMustCompleteBeforeCleanPromotion() {
        XCTAssertFalse(CleanPersistencePromotionPolicy.allowsPromotion(
            resolutionCompleted: true,
            finalStoreReadCompleted: true,
            durableSnapshotWriteCompleted: false
        ))

        let outcome: BoundedLifecycleOutcome<Bool> = BoundedLifecycleWait.run(timeout: 1.0) {
            try await Task.sleep(nanoseconds: 20_000_000)
            return true
        }
        guard case .completed(let durable) = outcome else {
            return XCTFail("durable write should complete inside budget")
        }
        XCTAssertTrue(CleanPersistencePromotionPolicy.allowsPromotion(
            resolutionCompleted: true,
            finalStoreReadCompleted: true,
            durableSnapshotWriteCompleted: durable
        ))
    }

    func testFailedOrTimedOutDurableWriteNeverPromotesClean() {
        for tuple in [
            (resolution: false, read: true, write: true),
            (resolution: true, read: false, write: true),
            (resolution: true, read: true, write: false),
        ] {
            XCTAssertFalse(CleanPersistencePromotionPolicy.allowsPromotion(
                resolutionCompleted: tuple.resolution,
                finalStoreReadCompleted: tuple.read,
                durableSnapshotWriteCompleted: tuple.write
            ))
        }
    }

    func testAppRecoveryModeResolverFailsClosedAndNoResumeOverrides() {
        let states: [(ShutdownSentinel.PriorShutdown, ResumeRecoveryMode)] = [
            (.clean(at: Date(timeIntervalSince1970: 1)), .clean),
            (.dirty(launchedAt: nil), .dirty),
            (.missing, .dirty),
            (.unreadable, .dirty),
            (.invalid, .dirty),
        ]
        for (prior, expected) in states {
            XCTAssertEqual(
                ShutdownSentinel.resolveRecoveryMode(
                    explicitNoResume: false,
                    priorShutdown: prior
                ),
                expected
            )
            XCTAssertEqual(
                ShutdownSentinel.resolveRecoveryMode(
                    explicitNoResume: true,
                    priorShutdown: prior
                ),
                .noResume
            )
        }
    }

    private var panelTargetReadCommands: [[String]] {
        [
            ["identify"],
            ["read-screen"],
            ["read-selection"],
            ["input-state"],
            ["get-metadata"],
            ["get-titlebar-state"],
            ["family"],
            ["panel-color", "get"],
            ["markdown-content"],
            ["markdown", "backlinks"],
            ["markdown", "visible"],
            ["markdown", "history"],
            ["markdown", "links"],
            ["browser", "get-url"],
            ["browser", "snapshot"],
            ["browser", "identify"],
            ["browser", "eval"],
            ["browser", "wait", "--selector", ".ready"],
            ["browser", "screenshot"],
            ["browser", "get", "title"],
            ["browser", "is", "visible"],
            ["browser", "find", "text"],
            ["browser", "panel", "list"],
            ["browser", "state", "save"],
            ["browser", "network", "requests"],
            ["browser", "cookies", "get"],
            ["browser", "storage", "local", "get"],
            ["browser", "console", "list"],
            ["browser", "errors", "list"],
            ["get-url"],
            ["is-webview-focused"],
            ["conversation", "list"],
            ["conversation", "get"],
            ["mailbox", "recv"],
            ["mailbox", "inbox-dir"],
            ["capture-pane"],
            ["capturep"],
            ["pipe-pane", "--command", "cat"],
        ]
    }

    func testPanelTargetReadCommandsRejectEmptyRefsBeforeSocketIO() {
        for command in panelTargetReadCommands {
            for flag in ["--panel", "--surface", "--tab"] {
                guard assertPanelTargetRejected(
                    expected: "empty_ref: --panel was provided but empty",
                    command: command,
                    flag: flag,
                    value: ""
                ) else { return }
            }
        }
        for command in panelTargetReadCommands {
            for flag in ["--panel=", "--surface=", "--tab="] {
                guard assertPanelTargetRejected(
                    expected: "empty_ref: --panel was provided but empty",
                    command: command,
                    flag: flag
                ) else { return }
            }
        }
    }

    func testPanelTargetReadCommandsReportMissingValuesBeforeSocketIO() {
        for command in panelTargetReadCommands {
            for flag in ["--panel", "--surface", "--tab"] {
                guard assertPanelTargetRejected(
                    expected: "--panel requires a value",
                    command: command,
                    flag: flag
                ) else { return }
            }
        }
    }

    func testClosePanelRejectsEmptyAndMissingTargetsBeforeSocketIO() {
        for flag in ["--panel", "--surface", "--tab"] {
            guard assertPanelTargetRejected(
                expected: "empty_ref: --panel was provided but empty",
                command: ["close-panel"],
                flag: flag,
                value: ""
            ) else { return }
            guard assertPanelTargetRejected(
                expected: "--panel requires a value",
                command: ["close-panel"],
                flag: flag
            ) else { return }
        }
        for flag in ["--panel=", "--surface=", "--tab="] {
            guard let result = runCLI(["close-panel", flag]) else { return }
            XCTAssertEqual(result.status, 1)
            XCTAssertEqual(result.stdout, "")
            XCTAssertEqual(result.stderr, "Error: empty_ref: --panel was provided but empty\n")
        }
        guard let afterTerminator = runCLI(["close-panel", "--", "--panel"]) else { return }
        XCTAssertEqual(afterTerminator.status, 1)
        XCTAssertEqual(afterTerminator.stdout, "")
        XCTAssertEqual(afterTerminator.stderr, "Error: --panel requires a value\n")
    }

    func testValidAliasesAndOmittedPanelRefsReachReadRequest() {
        let workspaceID = "11111111-2222-3333-4444-555566667777"
        let cases: [(flag: String, reference: String, expectedPanelID: String)] = [
            ("--panel", codexID, codexID),
            ("--surface", "panel:1", "panel:1"),
            ("--tab", "1", "panel:1"),
        ]
        for item in cases {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(
                ["read-screen", "--workspace", workspaceID, item.flag, item.reference],
                socketPath: socket.path,
                environmentOverrides: ["C11_TRACE": "1"]
            ) else { return }
            XCTAssertEqual(result.status, 0, "\(result.stderr) requests=\(socket.requests)")
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving")
            let read = socket.requests.first(where: { $0["method"] as? String == "panel.read_text" })
            let params = read?["params"] as? [String: Any]
            XCTAssertEqual(params?["panel_id"] as? String, item.expectedPanelID)
            XCTAssertEqual(params?["workspace_id"] as? String, workspaceID)
        }

        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let result = runCLI(
            ["read-screen"],
            socketPath: socket.path,
            environmentOverrides: [
                "C11_TRACE": "1",
                "CMUX_WORKSPACE_ID": workspaceID,
                "C11_PANEL_ID": codexID,
            ]
        ) else { return }
        XCTAssertEqual(result.status, 0, "\(result.stderr) requests=\(socket.requests)")
        XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving")
        let read = socket.requests.first(where: { $0["method"] as? String == "panel.read_text" })
        let params = read?["params"] as? [String: Any]
        XCTAssertEqual(params?["panel_id"] as? String, codexID)
        XCTAssertEqual(params?["workspace_id"] as? String, workspaceID)

        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let result = runCLI(
            ["browser", "panel:1", "eval", "--panel", "--json"],
            socketPath: socket.path
        ) else { return }
        XCTAssertEqual(result.status, 0, "\(result.stderr) requests=\(socket.requests)")
        XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving")
        let eval = socket.requests.first(where: { $0["method"] as? String == "browser.eval" })
        let evalParams = eval?["params"] as? [String: Any]
        XCTAssertEqual(evalParams?["panel_id"] as? String, "panel:1")
        XCTAssertEqual(evalParams?["script"] as? String, "--panel")

        let browserReads: [(command: [String], method: String)] = [
            (["browser", "panel:1", "wait", "--selector", ".ready"], "browser.wait"),
            (["browser", "--panel", "panel:1", "wait", "--selector", ".ready"], "browser.wait"),
            (["browser", "panel:1", "screenshot"], "browser.screenshot"),
            (["browser", "--surface", "panel:1", "screenshot"], "browser.screenshot"),
            (["browser", "panel:1", "console", "list"], "browser.console.list"),
            (["browser", "--tab", "panel:1", "console", "list"], "browser.console.list"),
            (["browser", "panel:1", "errors", "list"], "browser.errors.list"),
            (["browser", "--panel", "panel:1", "errors", "list"], "browser.errors.list"),
        ]
        for item in browserReads {
            guard assertBrowserReadReachesSocket(item.command, method: item.method) else { return }
        }
    }

    func testPanelPreflightMatchesCommandOptionBoundaries() {
        guard let help = runCLI(["read-screen", "--help", "--panel"]) else { return }
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.stdout.contains("Usage: c11 read-screen"))
        XCTAssertEqual(help.stderr, "")

        guard let missing = runCLI(["identify", "--title", "--panel"]) else { return }
        XCTAssertEqual(missing.status, 1)
        XCTAssertEqual(missing.stdout, "")
        XCTAssertEqual(missing.stderr, "Error: --panel requires a value\n")

        guard let emptyAfterTerminator = runCLI(["identify", "--", "--panel", ""]) else { return }
        XCTAssertEqual(emptyAfterTerminator.status, 1)
        XCTAssertEqual(emptyAfterTerminator.stdout, "")
        XCTAssertEqual(emptyAfterTerminator.stderr, "Error: empty_ref: --panel was provided but empty\n")

        guard let missingPanelAfterMissingEvent = runCLI(["mailbox", "recv", "--event", "--panel"]) else { return }
        XCTAssertEqual(missingPanelAfterMissingEvent.status, 1)
        XCTAssertEqual(missingPanelAfterMissingEvent.stdout, "")
        XCTAssertEqual(missingPanelAfterMissingEvent.stderr, "Error: --panel requires a value\n")

    }

    func testBrowserReadSubcommandsRejectInvalidPanelFlagsBeforeSocketIO() {
        let cases: [(command: [String], flag: String, value: String?, expected: String)] = [
            (
                ["browser", "panel:1", "get", "title", "--selector"],
                "--panel=",
                nil,
                "empty_ref: --panel was provided but empty"
            ),
            (
                ["browser", "panel:1", "is", "visible"],
                "--panel",
                nil,
                "--panel requires a value"
            ),
            (
                ["browser", "panel:1", "find", "text", "needle"],
                "--surface",
                nil,
                "--panel requires a value"
            ),
            (
                ["browser", "panel:1", "wait", "--selector", ".ready"],
                "--tab=",
                nil,
                "empty_ref: --panel was provided but empty"
            ),
            (
                ["browser", "panel:1", "screenshot"],
                "--panel",
                nil,
                "--panel requires a value"
            ),
            (
                ["browser", "panel:1", "console", "list"],
                "--surface",
                nil,
                "--panel requires a value"
            ),
            (
                ["browser", "panel:1", "errors", "list"],
                "--panel=",
                nil,
                "empty_ref: --panel was provided but empty"
            ),
        ]
        for item in cases {
            _ = assertPanelTargetRejected(
                expected: item.expected,
                command: item.command,
                flag: item.flag,
                value: item.value
            )
        }
    }

    func testBrowserStatePathMayLookLikePanelFlag() {
        for verb in ["save", "load"] {
            guard let result = runCLI(["browser", "panel:1", "state", verb, "--panel"]) else { return }
            XCTAssertEqual(result.status, 1)
            XCTAssertFalse(result.stderr.contains("--panel requires a value"), result.stderr)
            XCTAssertFalse(result.stderr.contains("empty_ref: --panel was provided but empty"), result.stderr)
            XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("socket"), result.stderr)
        }
    }

    func testValueOptionDoesNotHideEmptyPanelFlag() {
        let aliases = ["--panel", "--surface", "--tab"]
        for alias in aliases {
            for value in ["", nil] as [String?] {
                var command = ["get-metadata", "--key", alias]
                if let value { command.append(value) }
                guard let result = runCLI(command) else { return }
                XCTAssertEqual(result.status, 1, "\(command): \(result.stderr)")
                XCTAssertEqual(result.stdout, "", "\(command)")
                XCTAssertEqual(
                    result.stderr,
                    value == nil
                        ? "Error: --panel requires a value\n"
                        : "Error: empty_ref: --panel was provided but empty\n",
                    "\(command)"
                )
            }
        }

        let invalidPanelTargets: [[String]] = [
            ["read-screen", "--lines", "--panel", ""],
            ["capture-pane", "--lines", "--panel", ""],
            ["capturep", "--lines", "--panel", ""],
            ["pipe-pane", "--command", "--panel", ""],
            ["pipe-pane", "--command", "--panel"],
        ]
        for command in invalidPanelTargets {
            guard let result = runCLI(command) else { return }
            XCTAssertEqual(result.status, 1, "\(command): \(result.stderr)")
            XCTAssertEqual(result.stdout, "", "\(command)")
            XCTAssertEqual(
                result.stderr,
                command.last == "--panel"
                    ? "Error: --panel requires a value\n"
                    : "Error: empty_ref: --panel was provided but empty\n",
                "\(command)"
            )
        }

        let literalValues: [[String]] = [
            ["browser", "eval", "--script", "--panel"],
            ["markdown", "scroll", "--panel", "panel:1", "--heading", "--panel"],
            ["browser", "panel:1", "state", "save", "--panel"],
        ]
        for command in literalValues {
            guard let result = runCLI(command) else { return }
            XCTAssertEqual(result.status, 1, "\(command): \(result.stderr)")
            XCTAssertEqual(result.stdout, "", "\(command)")
            XCTAssertFalse(result.stderr.contains("--panel requires a value"), "\(command): \(result.stderr)")
            XCTAssertFalse(result.stderr.contains("empty_ref: --panel was provided but empty"), "\(command): \(result.stderr)")
            XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("socket"), "\(command): \(result.stderr)")
        }
    }

    func testMailboxSendBodyThatLooksLikePanelFlagRemainsBodyText() {
        for flagShapedBody in ["--panel", "--surface", "--tab"] {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(
                ["mailbox", "send", "--body", flagShapedBody],
                socketPath: socket.path
            ) else { return }
            XCTAssertEqual(result.status, 1)
            XCTAssertEqual(result.stdout, "")
            XCTAssertEqual(result.stderr, "Error: A mailbox envelope needs --to or --topic.\n")
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving")
            XCTAssertTrue(socket.requests.isEmpty, "mailbox send should reject before writing to the socket")
        }
    }

    func testFlagShapedOptionValuesAreNotMistakenForPanelTargets() {
        for args in [
            ["new-workspace", "--title", "--panel"],
            ["markdown", "scroll", "--panel", "panel:1", "--heading", "--panel"],
            ["browser", "eval", "--script", "--panel"],
        ] {
            guard let result = runCLI(args) else { return }
            XCTAssertEqual(result.status, 1, result.stderr)
            XCTAssertFalse(result.stderr.contains("--panel requires a value"), result.stderr)
            XCTAssertFalse(result.stderr.contains("empty_ref: --panel was provided but empty"), result.stderr)
        }
    }

    func testBooleanOptionDoesNotHideMissingPanelValue() {
        guard let result = runCLI(["read-selection", "--json", "--panel"]) else { return }
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "Error: --panel requires a value\n")
    }

    func testUnknownFlagsFailBeforeSocketDiscovery() {
        let cases: [[String]] = [
            ["new-workspace", "--title", "C11-334 probe", "--not-a-real-flag"],
            ["new-split", "right", "--not-a-real-flag"],
            ["launch-agent", "--type", "codex", "--not-a-real-flag"],
            ["browser", "open", "https://example.invalid", "--not-a-real-flag"],
            ["browser", "open", "https://example.invalid", "--selector", ".ready"],
            ["guide", "--not-a-real-flag"],
            ["usage", "--not-a-real-flag"],
            ["report", "--not-a-real-flag"],
            ["journal", "query", "--not-a-real-flag"],
            ["agent-event", "append", "--not-a-real-flag"],
            ["themes", "clear", "--json"],
            ["model-costs", "rm", "claude-opus-4-7", "--in", "1"],
            ["history", "back", "--limit", "5"],
            ["history", "--limit", "5", "back"],
            ["feed", "list", "--workspace", "workspace:1"],
            ["feed", "open", "panel:1", "--scope", "all"],
            ["workspace", "recents", "unpin", "~/Projects/site", "--at", "1"],
            ["state", "save", "--scrollback", "--", "--bogus"],
            ["__tmux-compat", "new-window", "--not-a-real-flag"],
            ["claude-mailbox", "--not-a-real-flag"],
        ]

        for command in cases {
            guard let result = runCLI(command) else { return }
            XCTAssertNotEqual(result.status, 0, "\(command)")
            XCTAssertEqual(result.stdout, "", "\(command)")
            XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
            XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("socket not found"), result.stderr)
        }
    }

    func testUnknownCreateFlagDoesNotReachMutationHandler() {
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let result = runCLI(
            ["new-split", "right", "--not-a-real-flag"],
            socketPath: socket.path
        ) else { return }
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
        XCTAssertFalse(
            socket.requests.contains(where: { $0["method"] as? String == "panel.split" }),
            "unknown option reached panel.split: \(socket.requests)"
        )
    }

    func testKnownFlagsAndHiddenAliasesStillReachTheirHandlers() {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let cases: [(command: [String], method: String)] = [
            (["new-workspace", "--title", "C11-334 documented flag"], "workspace.create"),
            (["new-panel", "--no-focus"], "panel.create"),
            (["launch-agent", "--type", "codex", "--no-focus"], "agent.launch"),
            (["break-pane", "--no-focus"], "area.break"),
            (["join-pane", "--target-pane", "area:1", "--no-focus"], "area.join"),
            (["focus-tab", "--tab", panelID], "panel.focus"),
            (["focus-tab", "--surface", panelID], "panel.focus"),
            (["focus-area", "--pane", panelID], "area.focus"),
            (["conversation", "list", "--tab", panelID], "conversation.list"),
            (["workspace-color", "set", "--workspace", "workspace:1", "teal"], "workspace.set_custom_color"),
            (["panel-color", "get", "--workspace", "workspace:1", "--panel", panelID], "panel.list"),
            (["feed", "list", "--scope", "all", "--json"], "feed.list"),
            (["workspace", "recents", "list", "--pinned", "--json"], "workspace.recents.list"),
            (["history", "--limit", "5", "--json"], "history.list"),
            (["app", "restart", "--no-resume"], "app.restart"),
        ]

        for item in cases {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(item.command, socketPath: socket.path) else { return }
            XCTAssertEqual(result.status, 0, "\(item.command): \(result.stderr)")
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving \(item.command)")
            XCTAssertTrue(
                socket.requests.contains(where: { $0["method"] as? String == item.method }),
                "Expected \(item.method) for \(item.command), got \(socket.requests)"
            )
            if item.command.contains("--no-focus"),
               let request = socket.requests.first(where: { $0["method"] as? String == item.method }) {
                XCTAssertEqual(
                    (request["params"] as? [String: Any])?["focus"] as? Bool,
                    false,
                    "--no-focus must reach \(item.method) as focus=false"
                )
            }
        }
    }

    func testBrowserScriptAndStyleOptionsReachHandlers() {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let cases: [([String], String)] = [
            (["browser", "--panel", panelID, "addscript", "--script", "console.log(1)"], "browser.addscript"),
            (["browser", "--panel", panelID, "addstyle", "--css", "body{}"], "browser.addstyle"),
        ]

        for (command, method) in cases {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(command, socketPath: socket.path) else { return }
            XCTAssertEqual(result.status, 0, "\(command): \(result.stderr)")
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving \(command)")
            XCTAssertTrue(
                socket.requests.contains(where: { $0["method"] as? String == method }),
                "Expected \(method) for \(command), got \(socket.requests)"
            )
        }
    }

    func testPreviouslyAcceptedFlagsAcrossSpecializedParsersPassPreflight() throws {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let laterErrorsAreNotPreflightRejections: [[String]] = [
            ["feed", "open", "--tab", panelID, "--workspace", "workspace:1"],
            ["navigate", "https://example.invalid", "--allow-insecure-http"],
            ["browser-reload", "--snapshot-after"],
            ["mailbox", "inbox-dir", "--tab", panelID],
            ["agent-hook", "working", "--native-event", "agent_start"],
        ]
        for command in laterErrorsAreNotPreflightRejections {
            guard let result = runCLI(command) else { return }
            XCTAssertNotEqual(result.status, 0, "These probes need runtime state: \(command)")
            XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), "\(command): \(result.stderr)")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-cli-preflight-\(UUID().uuidString)", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let claude = root.appendingPathComponent("claude", isDirectory: true)
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for command in [
            ["usage", "--journal", state.appendingPathComponent("journal.sqlite3").path,
             "--state-root", state.path, "--claude-root", claude.path, "--codex-root", codex.path,
             "--since", "all", "--utc", "--json"],
            ["report", "--state-root", state.path, "--claude-root", claude.path, "--codex-root", codex.path,
             "--instance", "test-instance", "--by", "panel", "--format", "json"],
        ] {
            guard let result = runCLI(command) else { return }
            XCTAssertEqual(result.status, 0, "\(command): \(result.stderr)")
            XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), "\(command): \(result.stderr)")
        }

        guard let skillPath = runCLI(["skill", "path", "--json"]) else { return }
        XCTAssertEqual(skillPath.status, 0, skillPath.stderr)
        XCTAssertTrue(skillPath.stdout.contains("\"path\""), skillPath.stdout)

        guard let journalQuery = runCLI([
            "journal", "query", "--bundle-id", "com.stage11.c11", "--agent", "codex",
            "--model", "codex", "--workspace", "00000000-0000-0000-0000-000000000001",
            "--from", "0", "--to", "1", "--stall-ms", "1000",
        ]) else { return }
        XCTAssertFalse(journalQuery.stderr.localizedCaseInsensitiveContains("unknown option"), journalQuery.stderr)
        XCTAssertFalse(journalQuery.stderr.localizedCaseInsensitiveContains("unknown flag"), journalQuery.stderr)

        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex", isDirectory: true), withIntermediateDirectories: true)
        guard let skillInstall = runCLI(
            ["skill", "install", "--tool", "codex", "--home", home.path, "--dry-run"],
            environmentOverrides: ["HOME": home.path]
        ) else { return }
        XCTAssertEqual(skillInstall.status, 0, skillInstall.stderr)
        XCTAssertFalse(skillInstall.stderr.localizedCaseInsensitiveContains("unknown flag"), skillInstall.stderr)
    }

    func testClaudeTeamsForwardsChildFlagsWithoutC11Preflight() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-cli-claude-teams-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let received = root.appendingPathComponent("claude-args.txt")
        let claude = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$C11_CLI_TEST_CLAUDE_ARGS\"\nexit 17\n"
            .write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        guard let result = runCLI(
            ["claude-teams", "--continue", "--model", "sonnet"],
            environmentOverrides: [
                "PATH": bin.path,
                "HOME": home.path,
                "C11_CLI_TEST_CLAUDE_ARGS": received.path,
            ]
        ) else { return }
        XCTAssertEqual(result.status, 17, result.stderr)
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
        XCTAssertEqual(
            try String(contentsOf: received, encoding: .utf8),
            "--teammate-mode\nauto\n--continue\n--model\nsonnet\n"
        )
    }

    func testCustomFlagSpecsRecognizeHiddenAliasesBeforeLaterUnknownFlags() {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let cases: [([String], String)] = [
            (["conversation", "list", "--tab", panelID, "--not-a-real-flag"], "--not-a-real-flag"),
            (["default-agent", "launch", "--agent", "codex", "--in-tab", panelID, "--not-a-real-flag"], "--not-a-real-flag"),
        ]

        for (command, expectedFlag) in cases {
            guard let result = runCLI(command) else { return }
            XCTAssertEqual(result.status, 1, "\(command): \(result.stderr)")
            XCTAssertTrue(result.stderr.contains("unknown flag '\(expectedFlag)'"), result.stderr)
            XCTAssertFalse(result.stderr.contains("unknown flag '--tab'"), result.stderr)
            XCTAssertFalse(result.stderr.contains("unknown flag '--in-tab'"), result.stderr)
        }
    }

    func testTmuxCompatValueFlagPassesPreflight() {
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let result = runCLI(
            ["__tmux-compat", "new-window", "-n", "C11-334 probe"],
            socketPath: socket.path
        ) else { return }
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
        XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving tmux compatibility request")
        XCTAssertTrue(
            socket.requests.contains(where: { $0["method"] as? String == "workspace.create" }),
            "Expected tmux new-window to reach workspace.create, got \(socket.requests)"
        )
    }

    func testMailboxSendKeepsFlagShapedBodyAfterTerminator() {
        guard let result = runCLI(["mailbox", "send", "--to", "watcher", "--", "--nope"]) else { return }
        XCTAssertNotEqual(result.status, 0, "A runtime socket is required to send mailbox content")
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown option"), result.stderr)
    }

    func testFocusTabRejectsUnknownWorkspaceBeforeFocusMutation() {
        for workspaceOption in [["--workspace", "workspace:9999"], ["--workspace=workspace:9999"]] {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(
                ["focus-tab", "--tab", socket.panelIDForAssertions] + workspaceOption,
                socketPath: socket.path
            ) else { return }
            XCTAssertNotEqual(result.status, 0, "\(workspaceOption): \(result.stderr)")
            XCTAssertTrue(result.stderr.contains("not_found"), "\(workspaceOption): \(result.stderr)")
            XCTAssertFalse(
                socket.requests.contains(where: { $0["method"] as? String == "panel.focus" }),
                "invalid workspace reached panel.focus: \(socket.requests)"
            )
        }
    }

    private func assertPanelTargetRejected(
        expected: String,
        command: [String],
        flag: String,
        value: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        var args = command + [flag]
        if let value { args.append(value) }
        guard let result = runCLI(args, file: file, line: line) else { return false }
        guard result.status == 1,
              result.stdout.isEmpty,
              result.stderr == "Error: \(expected)\n" else {
            XCTFail(
                "Expected CLI to reject before socket I/O with 'Error: \(expected)', " +
                "got status \(result.status), stdout=\(result.stdout.debugDescription), " +
                "stderr=\(result.stderr.debugDescription)",
                file: file,
                line: line
            )
            return false
        }
        return true
    }

    private func assertBrowserReadReachesSocket(
        _ command: [String],
        method: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket", file: file, line: line)
            return false
        }
        guard let result = runCLI(command, socketPath: socket.path, file: file, line: line) else { return false }
        guard result.status == 0 else {
            XCTFail("Expected (command) to succeed, got stderr=\(result.stderr.debugDescription)", file: file, line: line)
            return false
        }
        guard socket.waitUntilFinished() else {
            XCTFail("fake socket did not finish serving (command)", file: file, line: line)
            return false
        }
        guard let request = socket.requests.first(where: { $0["method"] as? String == method }) else {
            XCTFail("Expected (method) request, got \(socket.requests)", file: file, line: line)
            return false
        }
        let params = request["params"] as? [String: Any]
        guard params?["panel_id"] as? String == "panel:1" else {
            XCTFail("Expected panel_id panel:1, got \(String(describing: params?["panel_id"]))", file: file, line: line)
            return false
        }
        return true
    }

    private func runCLI(
        _ args: [String],
        socketPath: String? = nil,
        environmentOverrides: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (status: Int32, stdout: String, stderr: String)? {
        do {
            let cli = try bundledCLI()
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = cli
            process.arguments = ["--socket", socketPath ?? "/tmp/c11-panel-target-test-\(UUID().uuidString).sock"] + args
            var environment = ProcessInfo.processInfo.environment
            for key in [
                "C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET", "CMUX_SOCKET_PATH",
                "C11_PANEL_ID", "C11_TAB_ID", "C11_SURFACE_ID",
                "CMUX_PANEL_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID",
                "C11_WORKSPACE_ID", "CMUX_WORKSPACE_ID",
            ] {
                environment.removeValue(forKey: key)
            }
            environment.merge(environmentOverrides) { _, new in new }
            process.environment = environment
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(decoding: stdoutData, as: UTF8.self),
                String(decoding: stderrData, as: UTF8.self)
            )
        } catch {
            XCTFail("Could not run bundled c11 CLI: \(error)", file: file, line: line)
            return nil
        }
    }

    private func bundledCLI() throws -> URL {
        var products = Bundle(for: Self.self).bundleURL
        for _ in 0..<6 {
            for appName in ["c11 DEV.app", "c11.app"] {
                let cli = products.appendingPathComponent(appName + "/Contents/Resources/bin/c11")
                if FileManager.default.isExecutableFile(atPath: cli.path) { return cli }
            }
            products.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: products.path])
    }

    private final class CapturedCLISocket {
        let path = "/tmp/c11-cli-panel-target-\(UUID().uuidString).sock"
        private let listenerFD: Int32
        private let lock = NSLock()
        private let finished = DispatchSemaphore(value: 0)
        private var capturedRequests: [[String: Any]] = []
        private let panelID = "ddd11111-2222-3333-4444-555566667777"
        var panelIDForAssertions: String { panelID }

        var requests: [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return capturedRequests
        }

        init() throws {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Self.posixError("socket") }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathCapacity = MemoryLayout.size(ofValue: address.sun_path) - 1
            path.withCString { source in
                withUnsafeMutablePointer(to: &address.sun_path) { destination in
                    let raw = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
                    strncpy(raw, source, pathCapacity)
                }
            }
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                Darwin.close(fd)
                throw Self.posixError("bind")
            }
            guard Darwin.listen(fd, 1) == 0 else {
                Darwin.close(fd)
                Darwin.unlink(path)
                throw Self.posixError("listen")
            }
            listenerFD = fd
            DispatchQueue.global(qos: .userInitiated).async { [self] in serveOneClient() }
        }

        deinit {
            Darwin.close(listenerFD)
            Darwin.unlink(path)
        }

        func waitUntilFinished() -> Bool {
            finished.wait(timeout: .now() + 2) == .success
        }

        private func serveOneClient() {
            defer { finished.signal() }
            var clientAddress = sockaddr_un()
            var clientAddressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.accept(listenerFD, sockaddrPointer, &clientAddressLength)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = bytes.withUnsafeMutableBufferPointer { buffer in
                    Darwin.read(clientFD, buffer.baseAddress, buffer.count)
                }
                if count <= 0 { return }
                pending.append(contentsOf: bytes[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                        if String(data: line, encoding: .utf8)?.hasPrefix("auth ") == true {
                            respond("OK", on: clientFD)
                            continue
                        }
                        lock.lock()
                        capturedRequests.append(["invalid_frame": true])
                        lock.unlock()
                        continue
                    }
                    lock.lock()
                    capturedRequests.append(request)
                    lock.unlock()
                    respond(to: request, on: clientFD)
                }
            }
        }

        private func respond(to request: [String: Any], on clientFD: Int32) {
            let method = request["method"] as? String ?? ""
            let result: [String: Any]
            switch method {
            case "system.capabilities":
                result = ["features": [["id": "vocabulary.workspace_area_panel"]]]
            case "panel.list":
                result = ["panels": [["id": panelID, "ref": "panel:1", "index": 1]]]
            case "panel.read_text":
                result = ["text": "captured"]
            case "browser.eval":
                result = ["value": "evaluated"]
            default:
                result = [:]
            }
            let envelope: [String: Any] = [
                "id": request["id"] ?? "test",
                "ok": true,
                "result": result,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
            respond(String(decoding: data, as: UTF8.self), on: clientFD)
        }

        private func respond(_ response: String, on clientFD: Int32) {
            var output = Array((response + "\n").utf8)
            while !output.isEmpty {
                let written = output.withUnsafeBytes { raw in
                    Darwin.write(clientFD, raw.baseAddress, raw.count)
                }
                if written <= 0 { return }
                output.removeFirst(written)
            }
        }

        private static func posixError(_ operation: String) -> NSError {
            NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "CLI fake socket \(operation) failed"]
            )
        }
    }
}
