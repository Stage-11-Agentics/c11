// C11-317: split out of CLI/c11.swift by scripts/split-cli.py.
import Foundation
import CryptoKit
import Darwin
import SQLite3
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

extension CMUXCLI {

    // MARK: - C11-131: state save / verify

    func stateUsage() -> String {
        return """
        Usage: c11 state <subcommand> [flags]

        Subcommands:
          save [--out <path>] [--scrollback]   Force a synchronous full-app
                                               session snapshot now. Prints the
                                               snapshot path + counts.
          verify --mode <clean|dirty|no-resume> [<path>]
                                               Read-only resume-decision dry run.
                                               Per terminal panel: kind, id,
                                               persisted state, transcript check,
                                               and whether it would resume.
                                               Exit 0 iff every ref would resume.
                                               Needs no running app.
        """
    }

    func runStateCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let subArgs = Array(commandArgs.dropFirst())
        switch subcommand {
        case "save":
            try runStateSave(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "verify":
            // Also reachable here when an app is running; the pre-connect
            // short-circuit handles the no-app case.
            try runStateVerify(subArgs: subArgs, jsonOutput: jsonOutput)
        case "help", "--help", "-h":
            print(stateUsage())
        default:
            throw CLIError(message: "Unknown state subcommand: \(subcommand)")
        }
    }

    func runStateSave(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        var params: [String: Any] = [
            "include_scrollback": hasFlag(subArgs, name: "--scrollback")
        ]
        if let out = optionValue(subArgs, name: "--out"), !out.isEmpty {
            params["out"] = out
        }
        let response = try client.sendV2(method: "session.save", params: params)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let path = response["snapshot_path"] as? String ?? "?"
        let windows = response["windows"] as? Int ?? 0
        let workspaces = response["workspaces"] as? Int ?? 0
        let panels = response["terminal_panels"] as? Int ?? 0
        let refs = response["refs"] as? Int ?? 0
        print("OK state save")
        print("  snapshot: \(path)")
        if let out = response["out_path"] as? String { print("  copy: \(out)") }
        print("  windows=\(windows) workspaces=\(workspaces) terminal_panels=\(panels) refs=\(refs)")
    }

    /// Default canonical snapshot path for the production bundle. `state
    /// verify` with no argument inspects this; the Tier-2 harness always
    /// passes an explicit path written by `state save --out`.
    func defaultStateSnapshotPath() -> String {
        let appSupport = (NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first) ?? (NSHomeDirectory() + "/Library/Application Support")
        return appSupport + "/c11/session-com.stage11.c11.json"
    }

    /// Claude Code's per-project transcript directory slug: every character
    /// that is not an ASCII letter or digit becomes `-`. Mirrors
    /// `ClaudeCodeStrategy.projectSlug` (the CLI is a separate build target
    /// and cannot import it).
    func claudeProjectSlug(_ cwd: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(cwd.unicodeScalars.count)
        for scalar in cwd.unicodeScalars {
            let value = scalar.value
            let isASCIIAlphanumeric =
                (value >= 48 && value <= 57)
                || (value >= 65 && value <= 90)
                || (value >= 97 && value <= 122)
            out.unicodeScalars.append(isASCIIAlphanumeric ? scalar : "-")
        }
        return out
    }

    func claudeProjectsRoot(
        home: String,
        environment: [String: String]
    ) -> URL {
        let taggedOrQA = ["C11_TAG", "CMUX_TAG", "C11_QA_LAUNCH"].contains { key in
            guard let value = environment[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if taggedOrQA,
           let rawOverride = environment["C11_QA_CLAUDE_PROJECTS_ROOT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawOverride.isEmpty {
            return URL(
                fileURLWithPath: (rawOverride as NSString).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    func isUUIDv4(_ id: String) -> Bool {
        let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count == 36 else { return false }
        let pattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
        return t.range(of: pattern, options: .regularExpression) != nil
    }

    /// Per-panel verify result.
    struct StateVerifyPanel {
        let kind: String
        let id: String
        let state: String
        let cwd: String?
        let ownership: ResumeOwnershipStatus
        let transcriptEvidence: ResumeTranscriptEvidence
        let wouldResume: Bool
        let action: String
        let skipCode: String?
    }

    struct StateVerifyRefInput {
        let kind: String
        let id: String
        let state: String
        let cwd: String?
        let placeholder: Bool
        let capturedVia: String?
        let quarantineReason: String?
        let diagnosticReason: String?
        let payload: [String: Any]?
    }

    /// Read-only resume-decision dry run. The recovery mode is mandatory and
    /// explicit: an arbitrary snapshot path cannot truthfully tell us whether
    /// the app selected clean, dirty, or no-resume recovery. Each row is fed
    /// through the same compiled `ResumeDecisionEngine` the app uses.
    func runStateVerify(subArgs: [String], jsonOutput: Bool) throws {
        guard let rawMode = optionValue(subArgs, name: "--mode"),
              let mode = ResumeRecoveryMode(rawValue: rawMode.lowercased()) else {
            throw CLIError(message: "state verify requires --mode <clean|dirty|no-resume>")
        }
        var positional: [String] = []
        var index = 0
        while index < subArgs.count {
            if subArgs[index] == "--mode" {
                index += 2
                continue
            }
            if subArgs[index].hasPrefix("-") {
                throw CLIError(message: "state verify: unknown option \(subArgs[index])")
            }
            positional.append(subArgs[index])
            index += 1
        }
        guard positional.count <= 1 else {
            throw CLIError(message: "state verify accepts at most one snapshot path")
        }
        let path = positional.first ?? defaultStateSnapshotPath()
        guard let data = FileManager.default.contents(atPath: path) else {
            throw CLIError(message: "state verify: snapshot not found at \(path)")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let windows = root["windows"] as? [[String: Any]] else {
            throw CLIError(message: "state verify: \(path) is not a valid session snapshot")
        }
        let home = NSHomeDirectory()
        var inputs: [StateVerifyRefInput] = []
        for window in windows {
            let tm = window["tabManager"] as? [String: Any]
            let workspaces = tm?["workspaces"] as? [[String: Any]] ?? []
            for ws in workspaces {
                // The session snapshot persists a workspace's tabs under the Codable key `panels`.
                let wsPanels = ws["panels"] as? [[String: Any]] ?? []
                for panel in wsPanels {
                    guard (panel["type"] as? String) == "terminal" else { continue }
                    guard let conv = panel["surface_conversations"] as? [String: Any],
                          let active = conv["active"] as? [String: Any] else { continue }
                    let kind = active["kind"] as? String ?? "?"
                    let id = active["id"] as? String ?? "?"
                    let state = active["state"] as? String ?? "?"
                    let cwd = active["cwd"] as? String
                    inputs.append(StateVerifyRefInput(
                        kind: kind,
                        id: id,
                        state: state,
                        cwd: cwd,
                        placeholder: active["placeholder"] as? Bool ?? false,
                        capturedVia: (active["captured_via"] ?? active["capturedVia"]) as? String,
                        quarantineReason: (active["quarantine_reason"] ?? active["quarantineReason"]) as? String,
                        diagnosticReason: (active["diagnostic_reason"] ?? active["diagnosticReason"]) as? String,
                        payload: active["payload"] as? [String: Any]
                    ))
                }
            }
        }
        let ownership = verifyOwnership(inputs: inputs)
        let panels = inputs.enumerated().map { index, input in
            return verifyDecision(
                input: input,
                ownership: ownership[index],
                mode: mode,
                home: home
            )
        }
        let refPanels = panels.count
        let resumable = panels.filter { $0.wouldResume }.count
        let allResume = panels.allSatisfy { $0.wouldResume }

        if jsonOutput {
            let panelNodes: [[String: Any]] = panels.map { p -> [String: Any] in
                    var d: [String: Any] = [
                        "kind": p.kind, "id": p.id, "state": p.state,
                        "ownership": p.ownership.rawValue,
                        "transcript_evidence": p.transcriptEvidence.rawValue,
                        "would_resume": p.wouldResume, "action": p.action
                    ]
                    if let cwd = p.cwd { d["cwd"] = cwd }
                    if let skipCode = p.skipCode { d["skip_code"] = skipCode }
                    return d
                }
            let payload: [String: Any] = [
                "snapshot_path": path,
                "mode": mode.rawValue,
                "ref_panels": refPanels,
                "would_resume": resumable,
                "all_resume": allResume,
                "panels": panelNodes
            ]
            print(jsonString(payload))
        } else {
            print("state verify: \(path)")
            print("  mode=\(mode.rawValue)")
            if panels.isEmpty {
                print("  (no terminal panels with captured conversations)")
            }
            for p in panels {
                let mark = p.wouldResume ? "RESUME" : "skip"
                print("  [\(mark)] kind=\(p.kind) id=\(p.id) state=\(p.state) ownership=\(p.ownership.rawValue) transcript=\(p.transcriptEvidence.rawValue) — \(p.action)")
            }
            print("  \(resumable)/\(refPanels) ref-bearing panels would resume")
        }
        // Exit 0 iff every ref-bearing panel would resume (vacuously true when
        // there are no refs).
        exit(allResume ? 0 : 1)
    }

    /// Mirror the app's two ownership audits without mutating the snapshot:
    /// exact-id conflicts are resolved by evidence tier, then repeated-cwd
    /// Codex refs quarantine only owners without eligible causal evidence.
    func verifyOwnership(
        inputs: [StateVerifyRefInput]
    ) -> [ResumeOwnershipStatus] {
        var ownership = inputs.map { input -> ResumeOwnershipStatus in
            switch input.quarantineReason {
            case "ambiguous_global_assignment", "same_cwd_without_causal_identity":
                return .ambiguous
            case .some(_):
                return .duplicate
            case .none:
                return .unique
            }
        }

        let exactIdentityIndices = Dictionary(grouping: inputs.indices.filter { index in
            let input = inputs[index]
            return !input.placeholder
                && !input.id.isEmpty
                && input.state != "tombstoned"
                && input.state != "unsupported"
        }) { index in
            let input = inputs[index]
            return "\(input.kind)\u{0}\(input.id)"
        }
        for indices in exactIdentityIndices.values where indices.count > 1 {
            let causal = indices.filter { isCausalCapture(inputs[$0]) }
            if causal.count == 1, let causalOwner = causal.first {
                for index in indices where index != causalOwner && ownership[index] == .unique {
                    ownership[index] = .duplicate
                }
            } else {
                for index in indices where ownership[index] == .unique {
                    ownership[index] = .duplicate
                }
            }
        }

        let codexCwdIndices = Dictionary(grouping: inputs.indices.compactMap { index -> (String, Int)? in
            let input = inputs[index]
            guard input.kind == "codex",
                  input.state != "tombstoned",
                  input.state != "unsupported",
                  let cwd = normalizedStateVerifyCwd(input.cwd) else { return nil }
            return (cwd, index)
        }, by: { $0.0 })
        for group in codexCwdIndices.values where group.count > 1 {
            for (_, index) in group {
                let input = inputs[index]
                let eligibleCausalOwner = isCausalCapture(input)
                    && input.quarantineReason == nil
                if !eligibleCausalOwner && ownership[index] == .unique {
                    ownership[index] = .ambiguous
                }
            }
        }
        return ownership
    }

    func isCausalCapture(_ input: StateVerifyRefInput) -> Bool {
        guard !input.placeholder else { return false }
        return input.capturedVia == "hook" || input.capturedVia == "runtimeEnv"
    }

    func normalizedStateVerifyCwd(_ cwd: String?) -> String? {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    func codexSessionsRoot(home: String, environment: [String: String]) -> URL {
        let taggedOrQA = ["C11_TAG", "CMUX_TAG", "C11_QA_LAUNCH"].contains { key in
            guard let value = environment[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if taggedOrQA,
           let rawOverride = environment["C11_QA_CODEX_SESSIONS_ROOT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawOverride.isEmpty {
            return URL(
                fileURLWithPath: (rawOverride as NSString).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    func codexTranscriptExists(id: String, home: String) -> Bool {
        let root = codexSessionsRoot(
            home: home,
            environment: ProcessInfo.processInfo.environment
        )
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasSuffix(".jsonl"),
                  let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey
                  ]),
                  values.isRegularFile == true else { continue }
            let stem = String(name.dropLast(".jsonl".count))
            if String(stem.suffix(36)) == id { return true }
        }
        return false
    }

    func opencodeDatabasePath(
        home: String,
        environment: [String: String]
    ) -> String {
        let taggedOrQA = ["C11_TAG", "CMUX_TAG", "C11_QA_LAUNCH"].contains { key in
            guard let value = environment[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if taggedOrQA,
           let override = environment["C11_QA_OPENCODE_DB_PATH"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return "\(home)/.local/share/opencode/opencode.db"
    }

    /// Read-only, stat-equivalent exact session check. Queries `session.id`
    /// only; message/part transcript tables are never touched.
    func opencodeSessionExists(id: String, home: String) -> Bool? {
        let path = opencodeDatabasePath(
            home: home,
            environment: ProcessInfo.processInfo.environment
        )
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM session WHERE id = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        return id.withCString { idCString -> Bool? in
            guard sqlite3_bind_text(statement, 1, idCString, -1, nil) == SQLITE_OK else {
                return nil
            }
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: return nil
            }
        }
    }

    func verifyDecision(
        input: StateVerifyRefInput,
        ownership: ResumeOwnershipStatus,
        mode: ResumeRecoveryMode,
        home: String
    ) -> StateVerifyPanel {
        let persistedState = ResumePersistedState(rawValue: input.state) ?? .unknown
        let idValid: Bool
        switch input.kind {
        case "codex", "claude-code", "omp", "grok":
            idValid = isUUIDv4(input.id)
        case "opencode":
            idValid = isValidOpencodeSessionId(input.id)
        default:
            idValid = false
        }

        let transcriptEvidence: ResumeTranscriptEvidence
        if mode != .dirty {
            transcriptEvidence = .notRequired
        } else if input.kind == "codex", idValid {
            transcriptEvidence = codexTranscriptExists(id: input.id, home: home) ? .verified : .missing
        } else if input.kind == "claude-code", idValid,
                  let cwd = input.cwd, !cwd.isEmpty {
            let slug = claudeProjectSlug(cwd)
            let path = claudeProjectsRoot(
                home: home,
                environment: ProcessInfo.processInfo.environment
            )
                .appendingPathComponent(slug, isDirectory: true)
                .appendingPathComponent("\(input.id).jsonl", isDirectory: false)
                .path
            transcriptEvidence = FileManager.default.fileExists(atPath: path)
                ? .verified
                : .missing
        } else if input.kind == "opencode", idValid {
            switch opencodeSessionExists(id: input.id, home: home) {
            case .some(let exists): transcriptEvidence = exists ? .verified : .missing
            case .none: transcriptEvidence = .unavailable
            }
        } else if input.kind == "omp", idValid,
                  let path = input.payload?["session_file_path"] as? String,
                  !path.isEmpty {
            transcriptEvidence = FileManager.default.fileExists(atPath: path)
                ? .verified
                : .missing
        } else if input.kind == "grok", idValid,
                  let path = input.payload?["session_directory_path"] as? String,
                  !path.isEmpty {
            transcriptEvidence = FileManager.default.fileExists(atPath: path)
                ? .verified
                : .missing
        } else {
            transcriptEvidence = .unavailable
        }

        let fallback: ResumeCommand?
        if input.kind == "claude-code", idValid {
            fallback = ResumeCommand(
                text: "claude --dangerously-skip-permissions --resume \(input.id)"
            )
        } else if input.kind == "opencode", idValid {
            var command = "opencode --auto -s '\(input.id)'"
            if let cwd = input.cwd, !cwd.isEmpty, isValidOpencodeSessionProjectDir(cwd) {
                command = "cd '\(cwd)' && \(command)"
            }
            fallback = ResumeCommand(text: command)
        } else if input.kind == "omp", idValid {
            fallback = ResumeCommand(
                text: "omp --auto-approve --resume=\(shellQuote(input.id))"
            )
        } else if input.kind == "grok", idValid {
            fallback = ResumeCommand(
                text: "grok --always-approve --resume \(shellQuote(input.id))"
            )
        } else {
            fallback = nil
        }

        let decision = ResumeDecisionEngine.decide(ResumeDecisionInput(
            mode: mode,
            ownership: ownership,
            kind: input.kind,
            id: input.id,
            placeholder: input.placeholder,
            state: persistedState,
            exactIDValid: idValid,
            transcriptEvidence: transcriptEvidence,
            diagnosticReason: input.diagnosticReason,
            fallbackCommand: fallback
        ))
        switch decision {
        case .command(let command):
            return StateVerifyPanel(
                kind: input.kind, id: input.id, state: input.state, cwd: input.cwd,
                ownership: ownership, transcriptEvidence: transcriptEvidence,
                wouldResume: true, action: command.text, skipCode: nil
            )
        case .skip(let code, let reason):
            return StateVerifyPanel(
                kind: input.kind, id: input.id, state: input.state, cwd: input.cwd,
                ownership: ownership, transcriptEvidence: transcriptEvidence,
                wouldResume: false, action: "skip: \(reason)", skipCode: code.rawValue
            )
        }
    }
}
