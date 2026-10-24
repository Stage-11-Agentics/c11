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
            ["themes", "clear", "--not-a-real-flag"],
            ["model-costs", "rm", "claude-opus-4-7", "--in", "1"],
            ["history", "back", "--limit", "5"],
            ["history", "--limit", "5", "back"],
            ["feed", "list", "--workspace", "workspace:1"],
            ["feed", "open", "panel:1", "--scope", "all"],
            ["workspace", "recents", "unpin", "~/Projects/site", "--at", "1"],
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

    func testMissingWorkspaceOptionValueDoesNotFallBackToCallerTarget() {
        let workspaceID = "11111111-2222-3333-4444-555566667777"
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let result = runCLI(
            ["close-panel", "--workspace"],
            socketPath: socket.path,
            environmentOverrides: ["C11_WORKSPACE_ID": workspaceID, "C11_PANEL_ID": panelID]
        ) else { return }
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("--workspace requires a value"), result.stderr)
        XCTAssertFalse(
            socket.requests.contains(where: { $0["method"] as? String == "panel.close" }),
            "missing --workspace value fell back to the caller target: \(socket.requests)"
        )
    }

    func testStateSaveRejectsUnexpectedArgumentAfterEndOfOptionsBeforeMutation() {
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let result = runCLI(
            ["state", "save", "--scrollback", "--", "--bogus"],
            socketPath: socket.path
        ) else { return }
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("unexpected argument"), result.stderr)
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
        XCTAssertFalse(
            socket.requests.contains(where: { $0["method"] as? String == "session.save" }),
            "unexpected state save argument reached mutation: \(socket.requests)"
        )
    }

    func testClearNotificationsRejectsUnexpectedTextAfterEndOfOptionsBeforeMutation() {
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let result = runCLI(
            ["clear-notifications", "--", "--not-a-real-flag"],
            socketPath: socket.path
        ) else { return }
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("unexpected argument"), result.stderr)
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
        XCTAssertFalse(
            socket.requests.contains(where: { ($0["legacy_command"] as? String)?.hasPrefix("clear_notifications") == true }),
            "unexpected clear-notifications text reached mutation: \(socket.requests)"
        )
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

    func testFlagAfterEndOfOptionsDoesNotMutate() {
        let workspaceID = "11111111-2222-3333-4444-555566667777"
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let cases: [([String], Set<String>)] = [
            (["close-panel", "--", "--not-a-real-flag"], ["panel.close"]),
            (["new-panel", "--", "--not-a-real-flag"], ["panel.create"]),
            (["new-split", "right", "--", "--not-a-real-flag"], ["panel.split"]),
            (["clear-log", "--", "--not-a-real-flag"], []),
            (["clear-progress", "--", "--not-a-real-flag"], []),
            (["set-progress", "0.5", "--", "--not-a-real-flag"], []),
            (["set-status", "build", "ok", "--", "--not-a-real-flag"], []),
            (["notify", "--title", "t", "--", "-body"], ["notification.create_for_panel"]),
            (["notify", "--", "--not-a-real-flag"], ["notification.create_for_panel"]),
        ]

        for (command, mutatingMethods) in cases {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(
                command,
                socketPath: socket.path,
                environmentOverrides: ["C11_WORKSPACE_ID": workspaceID, "C11_PANEL_ID": panelID]
            ) else { return }
            XCTAssertNotEqual(result.status, 0, "\(command): \(result.stderr)")
            XCTAssertTrue(
                result.stderr.localizedCaseInsensitiveContains("unknown flag")
                    || result.stderr.localizedCaseInsensitiveContains("unexpected argument"),
                "Expected a flag validation error for \(command), got \(result.stderr)"
            )
            XCTAssertFalse(
                socket.requests.contains(where: { mutatingMethods.contains($0["method"] as? String ?? "") }),
                "Mutation reached the socket for \(command): \(socket.requests)"
            )
            XCTAssertTrue(socket.legacyCommands.isEmpty, "Legacy mutation reached the socket for \(command): \(socket.legacyCommands)")
        }
    }

    func testKnownFlagsAndHiddenAliasesStillReachTheirHandlers() {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let cases: [(command: [String], method: String)] = [
            (["new-workspace", "--title", "C11-334 documented flag"], "workspace.create"),
            (["new-split", "right", "--force"], "panel.split"),
            (["new-area", "right", "--force"], "area.create"),
            (["new-panel", "--no-focus"], "panel.create"),
            (["rename-panel", "--title", "C11-334 renamed panel"], "panel.action"),
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
            (["restore", "snap", "--replace"], "snapshot.restore"),
            (["markdown-content", "--panel", panelID], "markdown.get_content"),
            (["ssh-session-end", "--relay-port", "1", "--workspace", "11111111-2222-3333-4444-555566667777", "--panel", panelID], "workspace.remote.terminal_session_end"),
        ]

        for item in cases {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            let environmentOverrides = item.command.first == "restore"
                ? ["C11_WORKSPACE_ID": "11111111-2222-3333-4444-555566667777"]
                : [:]
            guard let result = runCLI(
                item.command,
                socketPath: socket.path,
                environmentOverrides: environmentOverrides
            ) else { return }
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

    func testReadSelectionJsonIsNotAnUnknownFlag() {
        XCTAssertTrue(assertCommandReachesSocket(
            ["read-selection", "--panel", "ddd11111-2222-3333-4444-555566667777", "--json"],
            method: "panel.read_selection"
        ))
    }

    func testSidebarStateJsonIsNotAnUnknownFlag() {
        XCTAssertTrue(assertCommandReachesSocket(
            ["sidebar-state", "--json", "--workspace", "11111111-2222-3333-4444-555566667777"],
            method: "sidebar.state"
        ))
    }

    func testDragPanelToSplitJsonIsNotAnUnknownFlag() {
        XCTAssertTrue(assertCommandReachesSocket(
            ["drag-panel-to-split", "--workspace", "11111111-2222-3333-4444-555566667777",
             "--panel", "ddd11111-2222-3333-4444-555566667777", "right", "--json"],
            method: "panel.drag_to_split"
        ))
    }

    func testClearStatusRejectsWindowFlagBeforeMutation() {
        guard let result = runCLI(["clear-status", "build", "--window", "window:1"]) else { return }
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("unknown flag '--window'"), result.stderr)
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("socket not found"), result.stderr)
    }

    func testBrowserScrollSnapshotAfterReachesHandler() {
        XCTAssertTrue(assertCommandReachesSocket(
            ["browser", "--panel", "ddd11111-2222-3333-4444-555566667777",
             "scroll", "--dy", "100", "--snapshot-after"],
            method: "browser.scroll"
        ))
    }

    func testSidebarMetadataParserOptionsAndAliasesReachHandlers() {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let cases: [[String]] = [
            ["set-status", "k", "v", "--panel", panelID, "--priority", "5", "--url", "http://x", "--format", "markdown"],
            ["set-status", "k", "v", "--tab", "panel:1"],
            ["set-status", "k", "v", "--panel=panel:1"],
            ["set-progress", "0.5", "--panel", panelID, "--label", "build"],
            ["log", "--level", "error", "--source", "build", "--panel", panelID, "--", "- literal"],
            ["clear-status", "build", "--panel", panelID],
        ]
        for command in cases {
            XCTAssertTrue(assertCommandReachesSocket(command), "Rejected or failed to reach socket: \(command)")
        }
    }

    func testParserAcceptedMetadataAndAttentionOptionsReachHandlers() {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let workspaceID = "11111111-2222-3333-4444-555566667777"
        let cases: [([String], String)] = [
            (["set-metadata", "--panel", panelID, "--json-input", "{\"k\":\"v\"}"], "panel.set_metadata"),
            (["set-metadata", "--panel", panelID, "--body", "{\"k\":\"v\"}"], "panel.set_metadata"),
            (["get-metadata", "--panel", panelID, "--include-sources"], "panel.get_metadata"),
            (["get-workspace-metadata", "--workspace", workspaceID, "--key", "description"], "workspace.get_metadata"),
            (["set-workspace-description", "--workspace", workspaceID, "--value", "hello"], "workspace.set_metadata"),
            (["set-workspace-icon", "--workspace", workspaceID, "--value", "sf:star.fill"], "workspace.set_metadata"),
            (["raise-flag", "--workspace", workspaceID, "--panel", panelID, "--by", "operator", "--json", "reason"], "flag.raise"),
            (["lower-flag", "--window", "window:1", "--panel", panelID, "--json"], "flag.lower"),
        ]
        for (command, method) in cases {
            XCTAssertTrue(assertCommandReachesSocket(command, method: method), "Rejected or missed \(method): \(command)")
        }
        XCTAssertTrue(assertCommandReachesSocket(
            ["clear-notifications", "--workspace", workspaceID]
        ))
    }

    func testLeadingDashTextAndEndOfOptionsRemainLiteral() {
        let panelID = "ddd11111-2222-3333-4444-555566667777"
        let workspaceID = "11111111-2222-3333-4444-555566667777"
        let cases: [([String], String?, String?)] = [
            (["set-status", "k", "- item", "--panel", panelID], "- item", nil),
            (["set-status", "k", "-3 failing", "--panel", panelID], "-3 failing", nil),
            (["set-status", "k", "--", "-3 failing", "--panel", panelID], "-3 failing", nil),
            (["set-progress", "-0.5", "--panel", panelID], "-0.5", nil),
            (["log", "- bullet", "--panel", panelID], "- bullet", nil),
            (["send", "--", "-n"], nil, "panel.send_text"),
            (["set-title", "--panel", panelID, "--", "-draft"], nil, "panel.set_metadata"),
            (["rename-workspace", "--", "--backend"], nil, "workspace.rename"),
            (["notify", "--title", "t", "--body", "-body"], nil, "notification.create_for_panel"),
            (["browser", panelID, "type", "sel", "--", "--literal"], nil, "browser.type"),
            (["browser", panelID, "fill", "sel", "--", "--x"], nil, "browser.fill"),
        ]
        for (command, legacyText, method) in cases {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(
                command,
                socketPath: socket.path,
                environmentOverrides: ["C11_WORKSPACE_ID": workspaceID, "C11_PANEL_ID": panelID]
            ) else { return }
            XCTAssertEqual(result.status, 0, "\(command): \(result.stderr)")
            XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving \(command)")
            if let legacyText {
                XCTAssertTrue(
                    socket.legacyCommands.contains(where: { $0.contains(legacyText) }),
                    "Expected literal text \(legacyText.debugDescription) in \(socket.legacyCommands)"
                )
            }
            if let method {
                guard let request = socket.requests.first(where: { $0["method"] as? String == method }) else {
                    XCTFail("Expected \(method) for \(command), got \(socket.requests)")
                    continue
                }
                let params = request["params"] as? [String: Any]
                if command.first == "set-title" {
                    XCTAssertEqual((params?["metadata"] as? [String: String])?["title"], "-draft")
                } else if command.first == "notify" {
                    XCTAssertEqual(params?["title"] as? String, "t")
                    XCTAssertEqual(params?["body"] as? String, "-body")
                } else if command.first == "rename-workspace" {
                    XCTAssertEqual(params?["title"] as? String, "--backend")
                } else {
                    let expectedText = command.first == "send" ? "-n" : (command.last == "--x" ? "--x" : "--literal")
                    XCTAssertEqual(params?["text"] as? String, expectedText)
                }
            }
        }
    }

    func testClaudeTeamsTmuxConfigurationCommandsRemainNoOps() {
        let cases: [[String]] = [
            ["__tmux-compat", "select-layout", "-t", "@1", "tiled"],
            ["__tmux-compat", "select-layout", "-t", "@1", "main-vertical"],
            ["__tmux-compat", "set-option", "-p", "-t", "%1", "pane-border-style", "fg=blue"],
            ["__tmux-compat", "set-option", "-w", "-t", "@1", "pane-border-status", "top"],
            ["__tmux-compat", "set-option", "-p", "-t", "%1", "remain-on-exit", "failed"],
            ["__tmux-compat", "set-window-option", "-t", "@1", "pane-base-index", "1"],
            ["__tmux-compat", "setw", "-t", "@1", "pane-base-index", "1"],
            ["__tmux-compat", "source-file", "-q", "~/.tmux.conf"],
            ["__tmux-compat", "refresh-client", "-S"],
            ["__tmux-compat", "attach-session", "-t", "@1"],
            ["__tmux-compat", "detach-client", "-E"],
        ]
        for command in cases {
            guard let socket = try? CapturedCLISocket() else {
                XCTFail("Could not create a fake CLI socket")
                return
            }
            guard let result = runCLI(command, socketPath: socket.path) else { return }
            XCTAssertEqual(result.status, 0, "\(command): \(result.stderr)")
            XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("unknown flag"), result.stderr)
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving \(command)")
            XCTAssertTrue(socket.requests.isEmpty, "no-op issued a request: \(socket.requests)")
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

        guard let setTitleFromFile = runCLI(["set-title", "--from-file", "/dev/null"]) else { return }
        XCTAssertNotEqual(setTitleFromFile.status, 0, "An empty title must fail")
        XCTAssertFalse(setTitleFromFile.stderr.localizedCaseInsensitiveContains("unknown flag"), setTitleFromFile.stderr)

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

        guard let workspaceApply = runCLI(["workspace-apply", "--file", "/dev/null"]) else { return }
        XCTAssertNotEqual(workspaceApply.status, 0, "An empty plan file must fail")
        XCTAssertFalse(workspaceApply.stderr.localizedCaseInsensitiveContains("unknown flag"), workspaceApply.stderr)

        guard let treeSocket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return
        }
        guard let treeOptions = runCLI(
            ["tree", "--window", "--layout", "--no-layout", "--canvas-cols", "80", "--out", "/dev/null", "--report"],
            socketPath: treeSocket.path
        ) else { return }
        XCTAssertNotEqual(treeOptions.status, 0, "Conflicting tree layout flags must fail")
        XCTAssertTrue(treeOptions.stderr.contains("--layout and --no-layout"), treeOptions.stderr)
        XCTAssertFalse(treeOptions.stderr.localizedCaseInsensitiveContains("unknown flag"), treeOptions.stderr)
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

    @discardableResult
    private func assertCommandReachesSocket(
        _ command: [String],
        method: String? = nil,
        environmentOverrides: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket", file: file, line: line)
            return false
        }
        var environment = [
            "C11_WORKSPACE_ID": "11111111-2222-3333-4444-555566667777",
            "C11_PANEL_ID": socket.panelIDForAssertions,
        ]
        environment.merge(environmentOverrides) { _, new in new }
        guard let result = runCLI(command, socketPath: socket.path, environmentOverrides: environment, file: file, line: line) else {
            return false
        }
        guard result.status == 0 else {
            XCTFail("Expected \(command) to succeed, got stderr=\(result.stderr.debugDescription)", file: file, line: line)
            return false
        }
        guard !result.stderr.localizedCaseInsensitiveContains("unknown flag") else {
            XCTFail("Preflight rejected \(command): \(result.stderr)", file: file, line: line)
            return false
        }
        guard socket.waitUntilFinished() else {
            XCTFail("Expected \(command) to reach the fake socket", file: file, line: line)
            return false
        }
        guard !socket.requests.isEmpty else {
            XCTFail("Expected a request for \(command)", file: file, line: line)
            return false
        }
        if let method,
           !socket.requests.contains(where: { $0["method"] as? String == method }) {
            XCTFail("Expected \(method) for \(command), got \(socket.requests)", file: file, line: line)
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
        private var capturedLegacyCommands: [String] = []
        private let panelID = "ddd11111-2222-3333-4444-555566667777"
        var panelIDForAssertions: String { panelID }

        var requests: [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return capturedRequests
        }

        var legacyCommands: [String] {
            lock.lock()
            defer { lock.unlock() }
            return capturedLegacyCommands
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
            // Its own thread, not a GCD worker: hundreds of these in one test
            // must not exhaust the shared pool.
            let server = Thread { [self] in serveOneClient() }
            server.stackSize = 1 << 18
            server.start()
        }

        deinit {
            Darwin.close(listenerFD)
            Darwin.unlink(path)
        }

        func waitUntilFinished() -> Bool {
            finished.wait(timeout: .now() + 2) == .success
        }

        private var resultOverrides: [String: [String: Any]] = [:]

        /// Answer `method` with `result` instead of the default reply.
        func reply(to method: String, with result: [String: Any]) {
            lock.lock()
            resultOverrides[method] = result
            lock.unlock()
        }

        private func serveOneClient() {
            defer { finished.signal() }
            // A CLI that never connects (a preflight rejection) must not hold
            // this thread forever.
            var descriptor = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 20_000) > 0 else { return }
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
                        guard let legacyCommand = String(data: line, encoding: .utf8) else { continue }
                        if legacyCommand.hasPrefix("auth ") {
                            respond("OK", on: clientFD)
                            continue
                        }
                        lock.lock()
                        capturedLegacyCommands.append(legacyCommand)
                        capturedRequests.append(["legacy_command": legacyCommand])
                        lock.unlock()
                        respond("OK", on: clientFD)
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
            lock.lock()
            let override = resultOverrides[method]
            lock.unlock()
            let result: [String: Any]
            switch method {
            case _ where override != nil:
                result = override ?? [:]
            case "system.capabilities":
                result = ["features": [["id": "vocabulary.workspace_area_panel"]]]
            case "panel.list":
                result = ["panels": [["id": panelID, "ref": "panel:1", "index": 1]]]
            case "panel.read_text":
                result = ["text": "captured"]
            case "browser.eval":
                result = ["value": "evaluated"]
            case "panel.set_metadata":
                result = ["applied": ["title": true, "description": true], "reasons": [:]]
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

// MARK: - C11-334: declared flags match what each parser reads

extension CLIResolutionSnapshotTests {
    private static let declPanelID = "ddd11111-2222-3333-4444-555566667777"
    private static let declWorkspaceID = "11111111-2222-3333-4444-555566667777"

    /// Argv that c11 1.1.3 accepted and the r1/r2 reviews of PR #737 found
    /// rejected: trailing `--json`, `--name=value`, parser-read aliases, and
    /// words the parser takes as text. Run with no socket, so nothing mutates;
    /// a preflight rejection is the only "unknown flag" these can print.
    private static let previouslyAcceptedArgv: [[String]] = [
        // r1 kit
        ["set-status", "k", "v", "--panel", "panel:1"], ["set-status", "k", "v", "--tab", "panel:1"],
        ["set-status", "k", "v", "--panel=panel:1"], ["set-status", "k", "v", "--priority", "5"],
        ["set-status", "k", "v", "--url", "http://x"], ["set-status", "k", "v", "--format", "markdown"],
        ["set-progress", "0.5", "--panel", "panel:1"], ["log", "--panel", "panel:1", "msg"],
        ["log", "--level", "error", "--panel", "panel:1", "--", "msg"], ["clear-status", "k", "--panel", "panel:1"],
        ["identify", "--json"], ["capabilities", "--json"], ["read-selection", "--panel", "panel:1", "--json"],
        ["list-panels", "--json"], ["sidebar-state", "--json"], ["drag-panel-to-split", "--panel", "panel:1", "right", "--json"],
        ["refresh-panels", "--json"], ["new-split", "right", "--json"], ["focus-panel", "--panel", "panel:1", "--json"],
        ["raise-flag", "--panel", "panel:1", "--json", "why"], ["raise-flag", "--workspace", "workspace:1", "--panel", "panel:1", "why"],
        ["lower-flag", "--window", "window:1", "--panel", "panel:1"], ["clear-notifications", "--workspace", "workspace:1"],
        ["set-metadata", "--panel", "panel:1", "--json-input", "{\"a\":1}"], ["set-metadata", "--panel", "panel:1", "--body", "{\"a\":1}"],
        ["get-metadata", "--panel", "panel:1", "--include-sources"], ["get-workspace-metadata", "--key", "description"],
        ["set-workspace-description", "--value", "hello"], ["set-workspace-icon", "--value", "x"],
        ["browser", "panel:1", "scroll", "--dy", "800", "--snapshot-after"],
        ["set-status", "k", "- item"], ["set-status", "k", "-3", "failing"], ["set-status", "k", "--", "-3", "failing"],
        ["log", "- bullet"], ["set-title", "--panel", "panel:1", "--", "-draft"],
        ["browser", "panel:1", "type", "sel", "--", "--literal"], ["browser", "panel:1", "fill", "sel", "--", "--x"],
        ["__tmux-compat", "select-layout", "-t", "@1", "tiled"],
        ["__tmux-compat", "set-option", "-p", "-t", "%1", "pane-border-style", "fg=blue"],
        ["new-split", "right", "--force"], ["new-area", "right", "--force"], ["restore", "snap", "--replace"],
        // r2 kit
        ["tree", "--json"], ["tree", "--all", "--json"], ["family", "--json"], ["family", "--panel", "panel:1", "--json"],
        ["agents", "--json"], ["doctor", "--json"], ["health", "--json"], ["guide", "--json"], ["guide", "api", "--json"],
        ["list-snapshots", "--json"], ["reorder-workspaces", "--order", "workspace:1", "--dry-run", "--json"],
        ["get-metadata", "--panel", "panel:1", "--json"], ["get-workspace-metadata", "--json"],
        ["clear-workspace-metadata", "--key", "k", "--json"], ["markdown-content", "--panel", "panel:1", "--json"],
        ["ping", "--json"], ["list-windows", "--json"], ["current-workspace", "--json"], ["list-areas", "--json"],
        ["list-area-panels", "--json"], ["close-panel", "--panel", "panel:1", "--json"],
        ["send", "--panel", "panel:1", "hi", "--json"], ["notify", "--title", "t", "--json"],
        ["set-agent", "--panel", "panel:1", "--type", "claude-code", "--json"], ["themes", "list", "--json"],
        ["events", "tail", "--json"], ["capture-pane", "--panel", "panel:1", "--json"],
        ["get-metadata", "--panel", "panel:1", "--key=title"], ["clear-metadata", "--panel", "panel:1", "--key=title"],
        ["clear-workspace-metadata", "--key=description"], ["config", "stats", "--window=7d"], ["config", "stats", "--by=harness"],
        ["skill", "status", "--tool=claude"],
        ["usage", "--since=1d", "--state-root=/nonexistent-c11-334", "--claude-root=/nonexistent-c11-334", "--codex-root=/nonexistent-c11-334"],
        ["conversation", "claim", "--panel", "panel:1", "--kind", "claude-code", "--id", "abc"],
        ["conversation", "tombstone", "--tab", "panel:1", "--kind", "claude-code", "--id", "abc"],
        ["feed", "--tab", "panel:1", "open"], ["browser", "panel:1", "scrollintoview", "--selector", "#x"],
        ["browser", "--panel", "panel:1", "scrollinto", "#x", "--snapshot-after"],
        ["respawn-pane", "--panel", "panel:1", "ls", "-la"], ["pipe-pane", "--panel", "panel:1", "grep", "-v", "foo"],
        ["set-hook", "pane-exited", "echo", "-n", "done"],
        ["__tmux-compat", "send-keys", "-t", "%1", "git", "log", "--oneline", "Enter"],
        ["__tmux-compat", "split-window", "-v", "npm", "run", "dev", "--port", "3000"],
        // r2 grok and the r2 text-region findings
        ["rpc", "system.capabilities", "--json"], ["paste", "--json", "hello"],
        ["clear-metadata", "--key", "title", "--json"], ["clear-workspace-metadata", "description", "--json"],
        ["browser", "panel:1", "type", "#q", "--verbose"], ["browser", "panel:1", "fill", "#q", "hello", "--world"],
        ["browser", "panel:1", "dialog", "accept", "--force"], ["browser", "panel:1", "addscript", "x", "=", "--y"],
        ["notify", "--title", "t", "--body", "-body"],
    ]

    func testPreviouslyAcceptedArgvFromReviewCorporaPassesPreflight() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("c11-334-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var rejected: [String] = []
        for argv in Self.previouslyAcceptedArgv {
            guard let result = runCLI(
                argv,
                socketPath: "/tmp/c11-334-no-socket-\(UUID().uuidString).sock",
                environmentOverrides: ["HOME": home.path]
            ) else { return }
            if result.stderr.localizedCaseInsensitiveContains("unknown flag")
                || result.stderr.localizedCaseInsensitiveContains("requires a value")
                || result.stderr.localizedCaseInsensitiveContains("unexpected argument") {
                rejected.append("\(argv.joined(separator: " ")) -> \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        XCTAssertEqual(rejected, [], rejected.joined(separator: "\n"))
    }

    /// `--name=value` reaches the parser as `--name value`, so every parser
    /// reads the `=` form of every declared value option.
    func testInlineValueOptionReachesParserAsSeparatedValue() {
        func request(_ argv: [String]) -> [String: Any]? {
            guard let socket = try? CapturedCLISocket(),
                  let result = runCLI(argv, socketPath: socket.path) else { return nil }
            XCTAssertEqual(result.status, 0, "\(argv): \(result.stderr)")
            XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving \(argv)")
            return socket.requests.first(where: { $0["method"] as? String == "panel.get_metadata" })?["params"] as? [String: Any]
        }
        let panel = Self.declPanelID
        let separated = request(["get-metadata", "--panel", panel, "--key", "title"])
        let inline = request(["get-metadata", "--panel=\(panel)", "--key=title"])
        XCTAssertEqual(separated?["keys"] as? [String], ["title"])
        XCTAssertEqual(inline?["keys"] as? [String], ["title"])
        XCTAssertEqual(inline?["panel_id"] as? String, separated?["panel_id"] as? String)
        XCTAssertNotNil(inline?["panel_id"])
    }

    /// A post-command `--json` is the global output switch, so handlers that
    /// print JSON only for `c11 --json <command>` honor it too.
    func testPostCommandJSONMatchesGlobalJSON() {
        func stdout(_ argv: [String]) -> String? {
            guard let socket = try? CapturedCLISocket(),
                  let result = runCLI(argv, socketPath: socket.path) else { return nil }
            XCTAssertEqual(result.status, 0, "\(argv): \(result.stderr)")
            XCTAssertTrue(socket.requests.contains(where: { $0["method"] as? String == "panel.get_metadata" }), "\(socket.requests)")
            return result.stdout
        }
        let global = stdout(["--json", "get-metadata", "--panel", Self.declPanelID])
        let trailing = stdout(["get-metadata", "--panel", Self.declPanelID, "--json"])
        XCTAssertEqual(trailing, global)
        XCTAssertTrue(trailing?.hasPrefix("{") ?? false, trailing ?? "")
    }

    /// Words after a trailing-command parser's options are the command line.
    func testTrailingCommandTextReachesHandler() {
        guard let socket = try? CapturedCLISocket(),
              let result = runCLI(["respawn-pane", "--panel", Self.declPanelID, "ls", "-la"], socketPath: socket.path)
        else { return }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(socket.waitUntilFinished(), "fake socket did not finish serving respawn-pane")
        let text = socket.requests.first(where: { $0["method"] as? String == "panel.send_text" })?["params"]
            .flatMap { ($0 as? [String: Any])?["text"] as? String }
        XCTAssertTrue(text?.hasSuffix("ls -la\n") ?? false, String(describing: text))
    }

    /// Declared options reach the request with their values in every position
    /// a parser reads them: inline targets before a verb, inline options in
    /// browser text verbs, and trailing-command options. Literal text keeps
    /// its words (PR #737 r3).
    func testDeclaredOptionsReachRequestPayloadsWithTheirValues() {
        let p = Self.declPanelID
        let cases: [(argv: [String], method: String, expected: [String: String])] = [
            (["respawn-pane", "--panel=\(p)", "--command=echo hello"], "panel.send_text", ["panel_id": p, "text": "echo hello\n"]),
            (["respawn-pane", "--panel", p, "ls", "-la"], "panel.send_text", ["text": "ls -la\n"]),
            (["respawn-pane", "ls", "-la"], "panel.send_text", ["text": "ls -la\n"]),
            (["browser", "--panel=\(p)", "click", "--selector", "#x"], "browser.click", ["panel_id": p, "selector": "#x"]),
            (["browser", "--tab=\(p)", "click", "--selector", "#x"], "browser.click", ["panel_id": p, "selector": "#x"]),
            (["browser", "--surface=\(p)", "click", "--selector", "#x"], "browser.click", ["panel_id": p, "selector": "#x"]),
            (["markdown", "--panel=\(p)", "scroll", "--heading=Intro"], "markdown.scroll", ["panel_id": p, "heading": "Intro"]),
            (["browser", p, "type", "--selector=#x", "--text=hello"], "browser.type", ["selector": "#x", "text": "hello"]),
            (["browser", p, "fill", "--selector=#x", "--text=hello"], "browser.fill", ["selector": "#x", "text": "hello"]),
            (["browser", p, "fill", "--selector", "#x", "--text=hello"], "browser.fill", ["text": "hello"]),
            (["browser", p, "type", "#x", "--", "--text=hello"], "browser.type", ["selector": "#x", "text": "--text=hello"]),
            (["browser", p, "type", "#x", "--verbose"], "browser.type", ["text": "--verbose"]),
            (["browser", p, "fill", "#x", "hello", "--world"], "browser.fill", ["text": "hello --world"]),
            (["browser", p, "eval", "--script=1+1"], "browser.eval", ["script": "1+1"]),
            (["browser", p, "eval", "1+1", "--x"], "browser.eval", ["script": "1+1 --x"]),
            (["browser", p, "addinitscript", "--script=window.x=1"], "browser.addinitscript", ["script": "window.x=1"]),
            (["browser", p, "addscript", "--script=window.x=1"], "browser.addscript", ["script": "window.x=1"]),
            (["browser", p, "addstyle", "--css=body{color:red}"], "browser.addstyle", ["css": "body{color:red}"]),
        ]
        for (argv, method, expected) in cases {
            guard let socket = try? CapturedCLISocket(),
                  let result = runCLI(argv, socketPath: socket.path) else { return }
            XCTAssertEqual(result.status, 0, "\(argv): \(result.stderr)")
            _ = socket.waitUntilFinished()
            guard let params = socket.requests.first(where: { $0["method"] as? String == method })?["params"] as? [String: Any] else {
                XCTFail("\(argv): expected \(method), got \(socket.requests)")
                continue
            }
            for (key, value) in expected {
                XCTAssertEqual(params[key] as? String, value, "\(argv): \(key)")
            }
        }
    }

    /// A target-shaped word that is another option's value is text: it never
    /// retargets the command and keeps all its characters (PR #737 r4 V1).
    func testTargetShapedOptionValueStaysTextAndKeepsCallerTarget() {
        let caller = Self.declPanelID
        let other = "eee11111-2222-3333-4444-555566667777"
        let otherWorkspace = "fff11111-2222-3333-4444-555566667777"
        let cases: [(argv: [String], method: String, expected: [String: String], absent: [String])] = [
            (["notify", "--body", "--panel=\(other)"], "notification.create_for_panel", ["panel_id": caller, "body": "--panel=\(other)"], []),
            (["notify", "--body", "--tab=\(other)"], "notification.create_for_panel", ["panel_id": caller, "body": "--tab=\(other)"], []),
            (["notify", "--body", "--surface=\(other)"], "notification.create_for_panel", ["panel_id": caller, "body": "--surface=\(other)"], []),
            (["notify", "--body", "--workspace=\(otherWorkspace)"], "notification.create_for_panel", ["panel_id": caller, "body": "--workspace=\(otherWorkspace)"], ["workspace_id"]),
            (["respawn-pane", "--command", "--panel=\(other)"], "panel.send_text", ["text": "--panel=\(other)\n"], ["panel_id"]),
        ]
        for (argv, method, expected, absent) in cases {
            guard let socket = try? CapturedCLISocket(),
                  let result = runCLI(argv, socketPath: socket.path, environmentOverrides: ["C11_PANEL_ID": caller])
            else { return }
            XCTAssertEqual(result.status, 0, "\(argv): \(result.stderr)")
            _ = socket.waitUntilFinished()
            guard let params = socket.requests.first(where: { $0["method"] as? String == method })?["params"] as? [String: Any] else {
                XCTFail("\(argv): expected \(method), got \(socket.requests)")
                continue
            }
            for (key, value) in expected {
                XCTAssertEqual(params[key] as? String, value, "\(argv): \(key)")
            }
            for key in absent {
                XCTAssertNil(params[key], "\(argv): unexpected \(key)")
            }
        }
    }

    /// With `--script`, `eval` takes no positional text, so an unknown flag
    /// fails before any browser request (PR #737 r4 V2).
    func testBrowserEvalWithScriptOptionRejectsUnknownFlag() {
        for argv in [
            ["browser", Self.declPanelID, "eval", "--script", "1+1", "--not-a-real-flag"],
            ["browser", Self.declPanelID, "eval", "--script=1+1", "--not-a-real-flag"],
        ] {
            guard let socket = try? CapturedCLISocket(),
                  let result = runCLI(argv, socketPath: socket.path) else { return }
            XCTAssertNotEqual(result.status, 0, "\(argv)")
            XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("unknown flag"), "\(argv): \(result.stderr)")
            XCTAssertFalse(socket.requests.contains(where: { $0["method"] as? String == "browser.eval" }), "\(argv): \(socket.requests)")
        }
    }

    /// An unknown option beside a trailing-command parser's own options fails
    /// before the CLI connects; words after the first positional stay text.
    func testTrailingCommandParsersRejectUnknownOptionsBeforeConnecting() {
        let cases: [[String]] = [
            ["respawn-pane", "--command", "true", "--not-a-real-flag"],
            ["pipe-pane", "--command", "cat", "--not-a-real-flag"],
            ["set-hook", "--list", "--not-a-real-flag"],
        ]
        for argv in cases {
            guard let socket = try? CapturedCLISocket(),
                  let result = runCLI(argv, socketPath: socket.path) else { return }
            XCTAssertNotEqual(result.status, 0, "\(argv)")
            XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("unknown flag"), "\(argv): \(result.stderr)")
            XCTAssertTrue(socket.requests.isEmpty, "\(argv) reached the socket: \(socket.requests)")
            XCTAssertTrue(socket.legacyCommands.isEmpty, "\(argv) reached the socket: \(socket.legacyCommands)")
        }
    }

    /// One argv per command path. A parser queries every option name on the
    /// path it takes, present or not, so one run checks the whole path.
    private static let declarationPaths: [[String]] = {
        let p = declPanelID
        let w = declWorkspaceID
        return [
            ["ping"], ["capabilities"], ["brand"], ["identify"], ["list-windows"], ["current-window"],
            ["focus-window", "--window", "window:1"], ["move-workspace-to-window", "--workspace", w, "--window", "window:1"],
            ["move-panel", "--panel", p, "--workspace", w], ["reorder-panel", "--panel", p, "--index", "0"],
            ["reorder-workspace", "--workspace", w, "--index", "0"], ["reorder-workspaces", "--order", w, "--dry-run"],
            ["workspace-group", "list"], ["workspace-group", "create", "--name", "g"],
            ["workspace-action", "--action", "pin", "--workspace", w], ["panel-action", "--action", "pin", "--panel", p],
            ["rename-panel", "--panel", p, "title"], ["set-title", "--panel", p, "t"], ["set-description", "--panel", p, "d"],
            ["set-panel-icon", "--panel", p, "x"], ["set-panel-color", "--panel", p, "teal"], ["get-titlebar-state", "--panel", p],
            ["list-workspaces"], ["snapshot", "--workspace", w], ["list-snapshots"], ["new-workspace", "--title", "t"],
            ["new-split", "right", "--panel", p], ["list-areas"], ["list-area-panels"], ["tree"], ["tree", "--all"],
            ["family", "--panel", p], ["focus-area", "--area", "area:1"], ["new-area", "right"],
            ["launch-agent", "--type", "codex", "--workspace", w], ["raise-flag", "--panel", p, "why"], ["lower-flag", "--panel", p],
            ["delegate", "--panel", p], ["new-panel", "--type", "terminal"], ["close-panel", "--panel", p],
            ["area-confirm", "--panel", p, "--title", "t"], ["drag-panel-to-split", "--panel", p, "right"], ["refresh-panels"],
            ["panel-health"], ["trigger-flash", "--panel", p], ["cancel-flash", "--panel", p], ["list-panels"],
            ["focus-panel", "--panel", p], ["close-workspace", "--workspace", w], ["select-workspace", "--workspace", w],
            ["rename-workspace", "--workspace", w, "name"], ["rename-window", "name"],
            ["set-workspace-root", "--workspace", w, "/tmp"], ["get-workspace-root", "--workspace", w], ["current-workspace"],
            ["read-selection", "--panel", p], ["input-state", "--panel", p], ["read-screen", "--panel", p],
            ["send", "--panel", p, "--workspace", w, "hi"], ["paste", "--panel", p, "--workspace", w, "hi"],
            ["send-key", "--panel", p, "--workspace", w, "enter"], ["notify", "--title", "t"],
            ["feed", "list"], ["feed", "open", p], ["list-notifications"], ["clear-notifications"],
            ["set-status", "k", "v"], ["clear-status", "k"], ["list-status"], ["set-progress", "0.5"], ["clear-progress"],
            ["log", "msg"], ["clear-log"], ["list-log"], ["sidebar-state"], ["set-agent", "--panel", p, "--type", "codex"],
            ["set-metadata", "--panel", p, "--key", "k", "--value", "v"], ["get-metadata", "--panel", p],
            ["clear-metadata", "--panel", p, "--key", "k"], ["set-workspace-metadata", "--key", "k", "--value", "v"],
            ["get-workspace-metadata"], ["clear-workspace-metadata", "--key", "k"],
            ["set-workspace-description", "--value", "d"], ["set-workspace-icon", "--value", "x"],
            ["conversation", "get", "--panel", p], ["conversation", "list"], ["conversation", "claim", "--panel", p, "--kind", "codex", "--id", "abc"],
            ["conversation", "push", "--panel", p, "--kind", "codex", "--id", "abc"],
            ["conversation", "tombstone", "--panel", p, "--kind", "codex", "--id", "abc"],
            ["app", "status"], ["capture-pane", "--panel", p], ["resize-pane", "--pane", "area:1", "-L"],
            ["pipe-pane", "--panel", p, "--command", "cat"], ["swap-pane", "--pane", "area:1", "--target-pane", "area:2"],
            ["last-pane"], ["clear-history", "--panel", p], ["paste-buffer", "--name", "missing-c11-334"],
            ["respawn-pane", "--panel", p, "true"], ["display-message", "-p", "hi"],
            ["browser", p, "url"], ["browser", p, "snapshot"], ["browser", p, "eval", "1"], ["browser", p, "wait", "--selector", "x"],
            ["browser", p, "click", "#x"], ["browser", p, "type", "#x", "hi"], ["browser", p, "press", "enter"],
            ["browser", p, "select", "#x", "v"], ["browser", p, "scroll", "--dy", "1"], ["browser", p, "get", "text", "#x"],
            ["browser", p, "get", "attr", "#x", "--attr", "a"], ["browser", p, "is", "visible", "#x"],
            ["browser", p, "find", "role", "button"], ["browser", p, "frame", "main"], ["browser", p, "dialog", "dismiss"],
            ["browser", p, "cookies", "get"], ["browser", p, "storage", "local", "get"], ["browser", p, "panel", "list"],
            ["browser", p, "console", "list"], ["browser", p, "highlight", "#x"], ["browser", p, "addscript", "1"],
            ["browser", p, "network", "requests"], ["browser", p, "keep-live", "status"], ["browser", "identify"],
            ["browser", "profiles", "list"], ["open-browser", "https://example.invalid"], ["get-url", "--panel", p],
            ["markdown", "visible", "--panel", p], ["markdown", "links", "--panel", p], ["markdown-content", "--panel", p],
            ["themes", "list"], ["workspace-color", "get"], ["panel-color", "get", "--panel", p],
            ["mailbox", "inbox-dir", "--panel", p], ["mailbox", "view"], ["messages", "view"],
            ["workspace", "recents", "list"], ["guide"], ["history", "--limit", "1"],
            ["config", "list"], ["config", "stats"], ["config", "launch", "missing-c11-334"],
            ["doctor"], ["health"], ["agents"], ["events", "tail"], ["journal", "query"], ["skill", "status"],
            ["model-costs", "list"], ["report"], ["state", "verify"], ["default-agent", "launch"], ["new-window"],
            ["close-window", "--window", "window:1"], ["workspace-group", "add", "--group", "g", "--workspaces", w],
            ["themes", "get"], ["ui", "themes", "list"], ["set-app-focus", "clear"], ["simulate-app-active"],
            ["ssh-session-end", "--relay-port", "1"], ["mailbox", "recv", "--peek"], ["markdown", "open", "/tmp/c11-334.md"],
            ["workspace", "export-blueprint", "--workspace", w, "--out", "/dev/null"], ["get-titlebar-state"],
            ["resize-window", "--window", "window:1", "10", "10"], ["break-pane", "--pane", "area:1"],
            ["join-pane", "--target-pane", "area:1"], ["browser", p, "screenshot", "--out", "/dev/null"],
            ["browser", p, "download", "--path", "/dev/null"], ["browser", p, "dom", "--selector", "x"],
            ["browser", p, "locator", "--selector", "x"], ["browser", p, "back"], ["browser", p, "goto", "https://example.invalid"],
        ]
    }()

    /// Names a parser reads only to reject them, keyed by command path.
    /// Preflight rejects them before discovery instead: same outcome, earlier.
    private static let readOnlyToReject: [String: Set<String>] = [
        // "--workspace is not supported in v1"
        "conversation list": ["--workspace"],
        // `feed` takes these before its verb, then rejects the ones a verb does not use.
        "feed list": ["--panel", "--surface", "--tab", "--workspace"],
        "feed open": ["--scope"],
        // Markdown agent verbs reject routing flags other than --panel.
        "markdown links": ["--area", "--pane", "--window", "--workspace"],
        "markdown visible": ["--area", "--pane", "--window", "--workspace"],
    ]

    func testEveryFlagAParserReadsIsDeclared() throws {
        signal(SIGPIPE, SIG_IGN)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c11-334-reads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = try bundledCLI()
        let lock = NSLock()
        var findings: [String] = []
        let paths = Self.declarationPaths
        // Each path is its own CLI process, socket and log; run them side by
        // side so the whole command surface fits the per-test time limit.
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            let argv = paths[index]
            let finding = Self.declarationFinding(argv: argv, cli: cli, directory: directory) {
                try CapturedCLISocket()
            }
            if let finding {
                lock.lock()
                findings.append(finding)
                lock.unlock()
            }
        }
        XCTAssertEqual(findings.sorted(), [], findings.sorted().joined(separator: "\n"))
    }

    /// Runs one path with the read log on. Returns nil when every name the
    /// parser read is declared and the path declares its positional arity,
    /// else a line naming what is wrong.
    private static func declarationFinding(
        argv: [String],
        cli: URL,
        directory: URL,
        makeSocket: () throws -> CapturedCLISocket
    ) -> String? {
        switch declarationRun(argv: argv, cli: cli, directory: directory, makeSocket: makeSocket) {
        case .failure(let message):
            return message
        case .success(let run):
            let label = argv.joined(separator: " ")
            var problems: [String] = []
            let undeclared = run.queried
                .subtracting(run.accepted)
                .subtracting(readOnlyToReject.first(where: { label.hasPrefix($0.key + " ") || label == $0.key })?.value ?? [])
                .subtracting(["--help", "-h"])
            if !undeclared.isEmpty { problems.append("parser reads \(undeclared.sorted()) not declared") }
            if run.arity == "unchecked" { problems.append("no positional arity declared") }
            return problems.isEmpty ? nil : "\(label): " + problems.joined(separator: "; ")
        }
    }

    private struct DeclarationRun {
        var stderr: String
        var queried: Set<String>
        var accepted: Set<String>
        var arity: String
        var positionals: Int
        var requests: [[String: Any]]
    }

    private enum DeclarationRunResult {
        case success(DeclarationRun)
        case failure(String)
    }

    private static func declarationRun(
        argv: [String],
        cli: URL,
        directory: URL,
        expectRejection: Bool = false,
        makeSocket: () throws -> CapturedCLISocket
    ) -> DeclarationRunResult {
        let label = argv.joined(separator: " ")
        guard let socket = try? makeSocket() else { return .failure("\(label): could not create a fake socket") }
        let log = directory.appendingPathComponent("\(UUID().uuidString).json")
        let process = Process()
        process.executableURL = cli
        process.arguments = ["--socket", socket.path] + argv
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("C11_") || key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["C11_CLI_FLAG_READ_LOG"] = log.path
        environment["C11_WORKSPACE_ID"] = declWorkspaceID
        environment["C11_PANEL_ID"] = declPanelID
        environment["HOME"] = directory.path
        process.environment = environment
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .failure("\(label): could not run the CLI: \(error)") }
        if exited.wait(timeout: .now() + 15) == .timedOut {
            process.terminate()
            return .failure("\(label): CLI did not exit within 15 seconds")
        }
        let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if expectRejection {
            // A rejected argv never connects; give a connection that did
            // happen a moment to be read before reporting its requests.
            Thread.sleep(forTimeInterval: 0.2)
            return .success(DeclarationRun(stderr: errorText, queried: [], accepted: [], arity: "", positionals: 0, requests: socket.requests))
        }
        if errorText.localizedCaseInsensitiveContains("unknown flag")
            || errorText.localizedCaseInsensitiveContains("unexpected argument") {
            return .failure("\(label): rejected by preflight: \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard let data = try? Data(contentsOf: log),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queried = object["queried"] as? [String],
              let acceptedByCommand = object["accepted"] as? [String: [String]],
              let arityByCommand = object["arity"] as? [String: String],
              let positionalsByCommand = object["positionals"] as? [String: Int],
              let command = acceptedByCommand.keys.first else {
            return .failure("\(label): no read log (the path wrote no declaration)")
        }
        return .success(DeclarationRun(
            stderr: errorText,
            queried: Set(queried),
            accepted: Set(acceptedByCommand.values.flatMap { $0 }),
            arity: arityByCommand[command] ?? "unchecked",
            positionals: positionalsByCommand[command] ?? 0,
            requests: socket.requests
        ))
    }

    /// For every path with a bounded arity, one word past the bound fails
    /// before the socket with "unexpected argument".
    func testEveryBoundedArityRejectsOneMoreWord() throws {
        // The fake socket may answer a CLI that already exited.
        signal(SIGPIPE, SIG_IGN)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c11-481-arity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = try bundledCLI()
        let lock = NSLock()
        var findings: [String] = []
        var bounded = 0
        let paths = Self.declarationPaths
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            let argv = paths[index]
            guard case .success(let run) = Self.declarationRun(argv: argv, cli: cli, directory: directory, makeSocket: { try CapturedCLISocket() }),
                  run.arity.hasPrefix("atMost:"), let limit = Int(run.arity.dropFirst("atMost:".count)) else { return }
            let extra = Array(repeating: "stray-c11-481", count: max(1, limit - run.positionals + 1))
            let label = (argv + extra).joined(separator: " ")
            var finding: String?
            switch Self.declarationRun(argv: argv + extra, cli: cli, directory: directory, expectRejection: true, makeSocket: { try CapturedCLISocket() }) {
            case .failure(let message):
                finding = message
            case .success(let rejected):
                if !rejected.stderr.contains("unexpected argument 'stray-c11-481'") {
                    finding = "\(label): not rejected as a stray word: \(rejected.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                } else if !rejected.requests.isEmpty {
                    finding = "\(label): reached the socket: \(rejected.requests)"
                }
            }
            lock.lock()
            bounded += 1
            if let finding { findings.append(finding) }
            lock.unlock()
        }
        XCTAssertEqual(findings.sorted(), [], findings.sorted().joined(separator: "\n"))
        XCTAssertGreaterThan(bounded, 50, "expected most paths to declare a bound")
    }
}

// MARK: - C11-481: positional arity and explicit close targets

extension CLIResolutionSnapshotTests {
    private static let closeCaller = "ddd11111-2222-3333-4444-555566667777"
    private static let closeOther = "eee11111-2222-3333-4444-555566667777"
    private static let closeWorkspace = "11111111-2222-3333-4444-555566667777"

    private func runClose(_ argv: [String], environment: [String: String]? = nil, configure: (CapturedCLISocket) -> Void = { _ in })
        -> (result: (status: Int32, stdout: String, stderr: String), socket: CapturedCLISocket)? {
        guard let socket = try? CapturedCLISocket() else {
            XCTFail("Could not create a fake CLI socket")
            return nil
        }
        configure(socket)
        let env = environment ?? ["C11_PANEL_ID": Self.closeCaller, "C11_WORKSPACE_ID": Self.closeWorkspace]
        guard let result = runCLI(argv, socketPath: socket.path, environmentOverrides: env) else { return nil }
        return (result, socket)
    }

    /// The C11-481 incident: a stray ref is rejected before the CLI connects,
    /// and the hint names an option only when the command takes it.
    func testStrayPositionalFailsBeforeSocketWithOptionHint() {
        let cases: [(argv: [String], stderr: String)] = [
            (["close-panel", "panel:268"], "Error: close-panel: unexpected argument 'panel:268'. Did you mean --panel panel:268?\n"),
            (["close-tab", "--panel", "panel:1", "panel:268"], "Error: close-panel: unexpected argument 'panel:268'. Did you mean --panel panel:268?\n"),
            (["close-panel", "--panel", "panel:1", "--", "panel:268"], "Error: close-panel: unexpected argument 'panel:268'. Did you mean --panel panel:268?\n"),
            (["identify", "panel:268"], "Error: identify: unexpected argument 'panel:268'. Did you mean --panel panel:268?\n"),
            (["close-workspace", "--workspace", "workspace:1", "workspace:2"], "Error: close-workspace: unexpected argument 'workspace:2'. Did you mean --workspace workspace:2?\n"),
            (["ping", "panel:268"], "Error: ping: unexpected argument 'panel:268'.\n"),
            (["list-windows", "extra"], "Error: list-windows: unexpected argument 'extra'.\n"),
        ]
        for (argv, stderr) in cases {
            guard let run = runClose(argv) else { return }
            XCTAssertNotEqual(run.result.status, 0, "\(argv)")
            XCTAssertEqual(run.result.stderr, stderr, "\(argv)")
            XCTAssertTrue(run.socket.requests.isEmpty, "\(argv) reached the socket: \(run.socket.requests)")
        }
    }

    /// No close falls back to `C11_PANEL_ID` or the focused panel.
    func testCloseCommandsWithoutTargetFailBeforeSocket() {
        let cases: [[String]] = [
            ["close-panel"], ["close-tab"], ["close-surface"],
            ["close-panel", "--workspace", Self.closeWorkspace],
            ["panel-action", "--action", "close-right"], ["panel-action", "close-others"],
            ["panel-action", "--workspace", Self.closeWorkspace, "--action", "close-left"],
            ["workspace-action", "close-below"], ["workspace-action", "--action", "close-above"],
            // The handler runs the last --action and trims it, as the server does.
            ["panel-action", "--action", "pin", "--action", "close-right"],
            ["panel-action", "--action=pin", "--action=close-right"],
            ["panel-action", " close-right"], ["panel-action", "--action", " Close-Others "],
            ["tab-action", "--action", "pin", "--action", "close-left"],
            ["workspace-action", "--action", "pin", "--action", "close-below"],
            ["workspace-action", "--action=pin", "--action=close-above"],
            ["workspace-action", " close-below"],
        ]
        for argv in cases {
            guard let run = runClose(argv) else { return }
            XCTAssertNotEqual(run.result.status, 0, "\(argv)")
            XCTAssertTrue(run.result.stderr.contains(" require"), "\(argv): \(run.result.stderr)")
            XCTAssertTrue(run.socket.requests.isEmpty, "\(argv) reached the socket: \(run.socket.requests)")
        }
    }

    /// An explicit ref, or `self`, closes exactly that target.
    func testCloseCommandsCloseExactlyTheNamedOrSelfTarget() {
        let cases: [(argv: [String], method: String, key: String, value: String)] = [
            (["close-panel", "--panel", Self.closeOther], "panel.close", "panel_id", Self.closeOther),
            (["close-panel", "--panel=\(Self.closeOther)"], "panel.close", "panel_id", Self.closeOther),
            (["close-panel", "--panel", "self"], "panel.close", "panel_id", Self.closeCaller),
            (["close-tab", "--tab", "self"], "panel.close", "panel_id", Self.closeCaller),
            (["close-surface", "--surface", "self"], "panel.close", "panel_id", Self.closeCaller),
            (["close-workspace", "--workspace", "self"], "workspace.close", "workspace_id", Self.closeWorkspace),
            (["panel-action", "--panel", "self", "--action", "close-right"], "panel.action", "panel_id", Self.closeCaller),
            (["workspace-action", "--workspace", "self", "close-below"], "workspace.action", "workspace_id", Self.closeWorkspace),
        ]
        for (argv, method, key, value) in cases {
            guard let run = runClose(argv) else { return }
            XCTAssertEqual(run.result.status, 0, "\(argv): \(run.result.stderr)")
            _ = run.socket.waitUntilFinished()
            let params = run.socket.requests.first(where: { $0["method"] as? String == method })?["params"] as? [String: Any]
            XCTAssertEqual(params?[key] as? String, value, "\(argv): \(run.socket.requests)")
        }
    }

    func testCloseWindowSelfClosesTheCallersWindow() {
        let window = "bbb11111-2222-3333-4444-555566667777"
        guard let run = runClose(["close-window", "--window", "self"], configure: {
            $0.reply(to: "system.identify", with: ["caller": ["window_id": window]])
        }) else { return }
        XCTAssertEqual(run.result.status, 0, run.result.stderr)
        _ = run.socket.waitUntilFinished()
        let identify = run.socket.requests.first(where: { $0["method"] as? String == "system.identify" })?["params"] as? [String: Any]
        XCTAssertEqual((identify?["caller"] as? [String: Any])?["workspace_id"] as? String, Self.closeWorkspace)
        XCTAssertEqual(run.socket.legacyCommands, ["close_window \(window)"])
    }

    /// `self` with no caller in the environment is an error, not the focused panel.
    func testSelfCloseTargetWithoutCallerEnvironmentFails() {
        for argv in [["close-panel", "--panel", "self"], ["close-workspace", "--workspace", "self"]] {
            guard let run = runClose(argv, environment: [:]) else { return }
            XCTAssertNotEqual(run.result.status, 0, "\(argv)")
            XCTAssertTrue(run.result.stderr.contains("self needs a c11 terminal"), "\(argv): \(run.result.stderr)")
            XCTAssertFalse(
                run.socket.requests.contains(where: { ["panel.close", "workspace.close"].contains($0["method"] as? String ?? "") }),
                "\(argv): \(run.socket.requests)"
            )
        }
    }

    /// The skill documents tmux's `resize-pane -L 500`; the amount word is
    /// read, not dropped, now that a stray word would be rejected.
    func testResizePaneReadsTmuxStyleAmountWord() {
        for (argv, amount) in [(["resize-pane", "--pane", "area:1", "-L", "500"], 500), (["resize-pane", "--pane", "area:1", "-R", "--amount", "7"], 7)] {
            guard let run = runClose(argv) else { return }
            XCTAssertEqual(run.result.status, 0, "\(argv): \(run.result.stderr)")
            _ = run.socket.waitUntilFinished()
            let params = run.socket.requests.first(where: { $0["method"] as? String == "area.resize" })?["params"] as? [String: Any]
            XCTAssertEqual(params?["amount"] as? Int, amount, "\(argv): \(run.socket.requests)")
        }
    }

    func testTmuxKillVerbsRequireATarget() {
        for argv in [
            ["__tmux-compat", "kill-pane"], ["__tmux-compat", "kill-window"],
            ["__tmux-compat", "killp"], ["__tmux-compat", "killw"],
            ["__tmux-compat", "kill-pane", "-t", ""], ["__tmux-compat", "kill-window", "-t", ""],
            ["__tmux-compat", "killp", "-t", "  "], ["__tmux-compat", "killw", "-t", " "],
        ] {
            guard let run = runClose(argv) else { return }
            XCTAssertNotEqual(run.result.status, 0, "\(argv)")
            XCTAssertTrue(run.result.stderr.contains("requires -t"), "\(argv): \(run.result.stderr)")
            XCTAssertFalse(
                run.socket.requests.contains(where: { ["panel.close", "workspace.close"].contains($0["method"] as? String ?? "") }),
                "\(argv): \(run.socket.requests)"
            )
        }
    }
}
