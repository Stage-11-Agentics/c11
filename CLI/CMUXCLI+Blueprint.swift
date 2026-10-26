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

    /// Classification of an executor `ApplyFailure` for human-readable
    /// rendering. CMUX-37 workstream 3: the wire shape carried by
    /// `Sources/WorkspaceApplyPlan.swift`'s `ApplyFailure` stays unchanged;
    /// only this client-side classifier decides what surfaces under
    /// `failure:` versus the new `info:` line. A future caller with a
    /// different opinion can ignore this and read the structured payload.
    enum FailureSeverity {
        case failure
        case info
    }

    /// Classify a single failure entry. Two codes are treated as info-level
    /// because the executor emits them on every clean snapshot/restore round
    /// trip:
    ///
    /// - `metadata_override` — fires when a SurfaceSpec sets both `.title`
    ///   and `metadata["title"]` (or both descriptions). The capture-side
    ///   fix in `Sources/WorkspacePlanCapture.swift` strips the dup, so this
    ///   should rarely fire on a clean round-trip; the classification is the
    ///   belt for the suspenders.
    /// - `working_directory_not_applied` with a "seed terminal reuse" marker
    ///   in the message — fires on every restore whose first terminal had a
    ///   captured cwd. The seed shell is already running by the time the
    ///   executor sees the spec, so the cwd cannot apply. Expected, not a
    ///   real failure.
    ///
    /// Other emission sites of `working_directory_not_applied` (browser /
    /// markdown split, in-pane creation) are still real failures; they
    /// indicate the operator passed a cwd to a kind that can't accept one.
    ///
    /// CAUTION: detection of the seed-terminal case relies on the executor's
    /// emitted message containing the substring "seed terminal reuse". If
    /// `Sources/WorkspaceLayoutExecutor.swift`'s
    /// `reportWorkingDirectoryNotApplicable` call for the seedTerminal
    /// context (around L656) ever changes its `context:` argument, update
    /// the matcher below.
    static func failureSeverity(code: String, message: String) -> FailureSeverity {
        if code == "metadata_override" { return .info }
        if code == "working_directory_not_applied",
           message.contains("seed terminal reuse") {
            return .info
        }
        return .failure
    }

    /// Split an executor failure list into (real failures, info-level lines)
    /// while preserving original order so output stays stable across runs.
    static func partitionFailures(
        _ failures: [[String: Any]]
    ) -> (failures: [[String: Any]], info: [[String: Any]]) {
        var realFailures: [[String: Any]] = []
        var infoLines: [[String: Any]] = []
        for f in failures {
            let code = (f["code"] as? String) ?? ""
            let msg = (f["message"] as? String) ?? ""
            switch failureSeverity(code: code, message: msg) {
            case .failure: realFailures.append(f)
            case .info:    infoLines.append(f)
            }
        }
        return (failures: realFailures, info: infoLines)
    }

    func localizedBlueprintSourceLabel(_ raw: String) -> String {
        switch raw {
        case "repo":
            return String(localized: "workspace.blueprint.source.repo", defaultValue: "repo")
        case "user":
            return String(localized: "workspace.blueprint.source.user", defaultValue: "user")
        case "built-in":
            return String(localized: "workspace.blueprint.source.builtIn", defaultValue: "built-in")
        default:
            return raw
        }
    }

    func resolvePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(expanded)
    }

    /// Shared implementation for `c11 workspace apply` and its back-compat
    /// alias `c11 workspace-apply`. Reads a JSON `WorkspaceApplyPlan` from a
    /// file path (or `-` for stdin), POSTs it via `workspace.apply`, and
    /// prints the `ApplyResult`. `commandLabel` is threaded into error
    /// messages so operators know which spelling they invoked.
    func runWorkspaceApply(
        _ args: [String],
        client: SocketClient,
        commandLabel: String,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (fileOpt, remaining) = parseOption(args, name: "--file")
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "\(commandLabel): unknown flag '\(unknown)'. Known flags: --file <path|->")
        }
        guard let fileArg = fileOpt else {
            throw CLIError(message: "\(commandLabel) requires --file <path|->")
        }
        let planData: Data
        if fileArg == "-" {
            planData = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            let resolvedPath = resolvePath(fileArg)
            guard let data = FileManager.default.contents(atPath: resolvedPath) else {
                throw CLIError(message: "\(commandLabel): could not read '\(resolvedPath)'")
            }
            planData = data
        }
        guard let planObject = try? JSONSerialization.jsonObject(with: planData, options: []) else {
            throw CLIError(message: "\(commandLabel): --file contents are not valid JSON")
        }
        let payload = try client.sendV2(method: "workspace.apply", params: ["plan": planObject])
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let ref = (payload["workspaceRef"] as? String) ?? "?"
            let surfaceRefs = payload["panelRefs"] as? [String: String] ?? [:]
            let paneRefs = payload["areaRefs"] as? [String: String] ?? [:]
            let warnings = payload["warnings"] as? [String] ?? []
            let failures = payload["failures"] as? [[String: Any]] ?? []
            print("OK workspace=\(ref) panels=\(surfaceRefs.count) areas=\(paneRefs.count)")
            if !warnings.isEmpty {
                print("warnings: \(warnings.count)")
                for w in warnings { print("  - \(w)") }
            }
            if !failures.isEmpty {
                let (realFailures, infoLines) = Self.partitionFailures(failures)
                if !realFailures.isEmpty {
                    print("failures: \(realFailures.count)")
                    for f in realFailures {
                        let code = (f["code"] as? String) ?? "?"
                        let step = (f["step"] as? String) ?? "?"
                        let msg = (f["message"] as? String) ?? ""
                        print("  - [\(code)] \(step): \(msg)")
                    }
                }
                if !infoLines.isEmpty {
                    print("info: \(infoLines.count)")
                    for f in infoLines {
                        let code = (f["code"] as? String) ?? "?"
                        let step = (f["step"] as? String) ?? "?"
                        let msg = (f["message"] as? String) ?? ""
                        print("  - [\(code)] \(step): \(msg)")
                    }
                }
            }
        }
    }

    // MARK: - CMUX-37 Phase 2: blueprint commands

    /// `c11 workspace new [--blueprint <path>]`. Without `--blueprint` drops
    /// into an interactive picker that calls `workspace.list_blueprints` and
    /// lets the user choose by number. With `--blueprint <path>` reads the
    /// `WorkspaceBlueprintFile` JSON directly and applies its plan.
    func runWorkspaceBlueprintNew(
        _ args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (dirOpt, argsAfterDir) = parseOption(args, name: "--dir")
        if let dirOpt {
            try requireOptionValue(dirOpt, flag: "--dir", command: "workspace new")
            try runWorkspaceNewInDirectory(dirOpt, args: argsAfterDir, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
            return
        }
        let (blueprintOpt, remaining) = parseOption(args, name: "--blueprint")
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "workspace new: unknown flag '\(unknown)'. Known flags: --blueprint <path>, --dir <path-or-query>")
        }

        if jsonOutput && blueprintOpt == nil {
            print(#"{"ok": false, "error": {"code": "PICKER_NOT_SUPPORTED_IN_JSON_MODE", "message": "--json requires --blueprint; interactive picker is not available in JSON mode"}}"#)
            return
        }

        let planObject: Any
        if let bpArg = blueprintOpt {
            let resolved = resolvePath(bpArg)
            guard let data = FileManager.default.contents(atPath: resolved) else {
                throw CLIError(message: "workspace new: could not read '\(resolved)'")
            }
            planObject = try blueprintPlanFromFile(at: resolved, data: data, client: client)
        } else {
            planObject = try workspaceBlueprintPicker(client: client, jsonOutput: jsonOutput)
        }

        let payload = try client.sendV2(method: "workspace.apply", params: ["plan": planObject])
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let ref = (payload["workspaceRef"] as? String) ?? "?"
            let surfaceRefs = payload["panelRefs"] as? [String: String] ?? [:]
            let paneRefs = payload["areaRefs"] as? [String: String] ?? [:]
            let warnings = payload["warnings"] as? [String] ?? []
            let failures = payload["failures"] as? [[String: Any]] ?? []
            print("OK workspace=\(ref) panels=\(surfaceRefs.count) areas=\(paneRefs.count)")
            if !warnings.isEmpty {
                for w in warnings { print("  warning: \(w)") }
            }
            if !failures.isEmpty {
                let (realFailures, infoLines) = Self.partitionFailures(failures)
                for f in realFailures {
                    let code = (f["code"] as? String) ?? "?"
                    let step = (f["step"] as? String) ?? "?"
                    let msg = (f["message"] as? String) ?? ""
                    print("  failure: [\(code)] \(step): \(msg)")
                }
                for f in infoLines {
                    let code = (f["code"] as? String) ?? "?"
                    let step = (f["step"] as? String) ?? "?"
                    let msg = (f["message"] as? String) ?? ""
                    print("  info: [\(code)] \(step): \(msg)")
                }
            }
        }
    }

    /// `c11 workspace new --dir <path-or-query> [--layout <id|name>] [--name <n>] [--agent]`.
    /// The query is ranked exactly like the New Workspace picker; a tie fails
    /// loudly and lists the candidates. The open is recorded in recents.
    func runWorkspaceNewInDirectory(
        _ dir: String,
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (layoutOpt, r1) = parseOption(args, name: "--layout")
        let (nameOpt, r2) = parseOption(r1, name: "--name")
        if let layoutOpt { try requireOptionValue(layoutOpt, flag: "--layout", command: "workspace new --dir") }
        if let nameOpt { try requireOptionValue(nameOpt, flag: "--name", command: "workspace new --dir") }
        let launchAgent = hasFlag(r2, name: "--agent")
        let remaining = r2.filter { $0 != "--agent" }
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "workspace new --dir: unknown flag '\(unknown)'. Known flags: --layout <blueprint id|name>, --name <text>, --agent")
        }
        if let stray = remaining.first {
            throw CLIError(message: "workspace new --dir: unexpected argument '\(stray)'. Quote a query that contains spaces.")
        }
        var params: [String: Any] = [
            "dir": dir,
            "cwd": FileManager.default.currentDirectoryPath,
            "launch_agent": launchAgent,
        ]
        if let layoutOpt {
            let listing = try client.sendV2(method: "workspace.list_blueprints", params: ["cwd": FileManager.default.currentDirectoryPath])
            let reference = layoutOpt.trimmingCharacters(in: .whitespacesAndNewlines)
            let aliases = blueprintStarterAliases(listing)
            let entries = listing["blueprints"] as? [[String: Any]] ?? []
            // Reserved names remain names even when the repository has a matching file.
            params["layout"] = !isReservedBlueprintReference(reference, aliases: aliases, entries: entries)
                && blueprintReferenceLooksLikePath(reference) ? resolvePath(reference) : reference
        }
        if let nameOpt { params["name"] = nameOpt }
        try addCallingPanel(to: &params)
        let payload = try client.sendV2(method: "workspace.create_in_directory", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let ref = (payload["workspace_ref"] as? String) ?? "?"
            let path = (payload["path"] as? String) ?? dir
            print("OK workspace=\(ref) dir=\(path)")
        }
    }

    /// An option value that starts with `--` is the next flag, not a value.
    func requireOptionValue(_ value: String, flag: String, command: String) throws {
        if value.hasPrefix("--") {
            throw CLIError(message: "\(command): \(flag) needs a value (got '\(value)')")
        }
    }

    /// `c11 workspace recents list [--json] [--pinned]` and
    /// `pin|unpin|remove <path-or-query> [--at <n>]`. Shares the New Workspace
    /// picker's model, so an open picker updates live.
    func runWorkspaceRecents(_ args: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let sub = args.first else {
            throw CLIError(message: "workspace recents: missing subcommand. Known subcommands: list, pin, unpin, remove")
        }
        let rest = Array(args.dropFirst())
        let cwd = FileManager.default.currentDirectoryPath
        switch sub {
        case "list":
            let pinned = hasFlag(rest, name: "--pinned")
            let extra = rest.filter { $0 != "--pinned" && $0 != "--json" }
            if let unknown = extra.first {
                throw CLIError(message: "workspace recents list: unexpected '\(unknown)'. Known flags: --pinned, --json")
            }
            let payload = try client.sendV2(method: "workspace.recents.list", params: ["pinned": pinned])
            if jsonOutput || rest.contains("--json") {
                print(jsonString(payload))
                return
            }
            let items = payload["recents"] as? [[String: Any]] ?? []
            if items.isEmpty {
                print(pinned ? "No pinned directories." : "No recent directories.")
                return
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for item in items {
                let path = (item["path"] as? String) ?? "?"
                let shown = path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
                let pin = (item["pin_index"] as? Int).map { "*\($0)" } ?? "  "
                let open = (item["open"] as? Bool) == true ? "open" : "    "
                let missing = (item["exists"] as? Bool) == false ? "missing" : ""
                let count = (item["open_count"] as? Int) ?? 0
                let when = (item["last_opened_at"] as? String) ?? ""
                print("\(pin.padding(toLength: 3, withPad: " ", startingAt: 0)) \(open) \(shown)  x\(count)  \(when) \(missing)".trimmingCharacters(in: .whitespaces))
            }
        case "pin", "unpin", "remove":
            let (atOpt, r1) = parseOption(rest, name: "--at")
            if let atOpt { try requireOptionValue(atOpt, flag: "--at", command: "workspace recents \(sub)") }
            if let unknown = r1.first(where: { $0.hasPrefix("--") && $0 != "--json" }) {
                throw CLIError(message: "workspace recents \(sub): unknown flag '\(unknown)'. Known flags: --at <n> (pin only)")
            }
            let positionals = r1.filter { !$0.hasPrefix("--") }
            guard let target = positionals.first else {
                throw CLIError(message: "workspace recents \(sub): missing <path>")
            }
            if positionals.count > 1 {
                throw CLIError(message: "workspace recents \(sub): unexpected argument '\(positionals[1])'. Quote a query that contains spaces.")
            }
            var params: [String: Any] = ["path": target, "cwd": cwd]
            if let atOpt {
                guard sub == "pin" else {
                    throw CLIError(message: "workspace recents \(sub): --at applies to pin only")
                }
                guard let n = Int(atOpt), n >= 1 else {
                    throw CLIError(message: "workspace recents pin: --at needs an integer >= 1 (the number on the pin's cmd badge)")
                }
                params["at"] = n
            }
            let payload = try client.sendV2(method: "workspace.recents.\(sub)", params: params)
            if jsonOutput || rest.contains("--json") {
                print(jsonString(payload))
            } else {
                let path = (payload["path"] as? String) ?? target
                switch sub {
                case "pin":
                    print("OK pinned \(path) at \((payload["pin_index"] as? Int).map(String.init) ?? "?")")
                case "unpin":
                    print("OK unpinned \(path)")
                default:
                    print("OK removed \(path)")
                }
            }
        default:
            throw CLIError(message: "workspace recents: unknown subcommand '\(sub)'. Known subcommands: list, pin, unpin, remove")
        }
    }

    /// Fetches `workspace.list_blueprints`, prints a numbered picker, reads
    /// from stdin, and returns the selected plan object ready for
    /// `workspace.apply`. Throws `CLIError` on cancel ("q") or invalid input.
    func workspaceBlueprintPicker(client: SocketClient, jsonOutput: Bool) throws -> Any {
        let cwd = FileManager.default.currentDirectoryPath
        let payload = try client.sendV2(method: "workspace.list_blueprints", params: ["cwd": cwd])
        guard let blueprints = payload["blueprints"] as? [[String: Any]], !blueprints.isEmpty else {
            throw CLIError(message: String(localized: "workspace.blueprint.picker.noBlueprints",
                defaultValue: "workspace new: no blueprints found. Use --blueprint <path> to apply one directly."))
        }

        let maxBracketLen = blueprints.map {
            let src = $0["source"] as? String ?? ""
            return localizedBlueprintSourceLabel(src).count + 2 // +2 for "[]"
        }.max() ?? 0

        for (i, bp) in blueprints.enumerated() {
            let source = bp["source"] as? String ?? ""
            let name = bp["name"] as? String ?? "(unnamed)"
            let desc = bp["description"] as? String
            let bracketLabel = "[\(localizedBlueprintSourceLabel(source))]"
            let label = bracketLabel.padding(toLength: maxBracketLen, withPad: " ", startingAt: 0)
            let num = String(i + 1).leftPadded(to: String(blueprints.count).count)
            if let d = desc {
                print("  \(label)  \(num)  \(name) — \(d)")
            } else {
                print("  \(label)  \(num)  \(name)")
            }
        }
        print("")
        print(String(localized: "workspace.blueprint.picker.prompt",
            defaultValue: "Enter number to apply, or q to cancel: "), terminator: "")
        fflush(stdout)

        guard let line = readLine(strippingNewline: true) else {
            throw CLIError(message: "workspace new: cancelled")
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "q" || trimmed == "Q" {
            throw CLIError(message: "workspace new: cancelled")
        }
        guard let idx = Int(trimmed), idx >= 1, idx <= blueprints.count else {
            throw CLIError(message: "workspace new: invalid selection '\(trimmed)'")
        }

        let chosen = blueprints[idx - 1]
        guard let url = chosen["url"] as? String else {
            throw CLIError(message: "workspace new: selected blueprint has no url")
        }
        let resolved = resolvePath(url)
        guard let data = FileManager.default.contents(atPath: resolved) else {
            throw CLIError(message: "workspace new: could not read blueprint at '\(resolved)'")
        }
        return try blueprintPlanFromFile(at: resolved, data: data, client: client)
    }

    /// Resolve a blueprint file's bytes to a layout plan dict suitable for
    /// `workspace.apply`. Dispatches on extension: `.md` files are routed
    /// through the `workspace.parse_blueprint` v2 method (so the markdown
    /// parser stays out of the CLI binary's link surface); `.json` and
    /// other extensions are decoded as `WorkspaceBlueprintFile` JSON
    /// envelopes.
    func blueprintPlanFromFile(at path: String, data: Data, client: SocketClient) throws -> Any {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "md" {
            guard let content = String(data: data, encoding: .utf8) else {
                throw CLIError(message: "workspace new: '\(path)' is not valid UTF-8")
            }
            let parsed = try client.sendV2(
                method: "workspace.parse_blueprint",
                params: ["format": "md", "content": content]
            )
            guard let plan = parsed["plan"] else {
                throw CLIError(message: "workspace new: '\(path)' parse returned no plan")
            }
            return plan
        }
        guard
            let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let plan = file["plan"]
        else {
            throw CLIError(message: "workspace new: '\(path)' is not a valid blueprint file (missing 'plan' key)")
        }
        return plan
    }

    func normalizedBlueprintReference(_ reference: String) -> String {
        reference.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    func blueprintReferenceLooksLikePath(_ reference: String) -> Bool {
        let name = normalizedBlueprintReference(reference)
        return name.contains("/") || name.hasPrefix("~") || name.hasPrefix(".")
            || name.hasSuffix(".json") || name.hasSuffix(".md")
    }

    func blueprintStarterAliases(_ payload: [String: Any]) -> [String: String] {
        // Keep the reserved set when an older app omits aliases or a payload is malformed.
        var aliases = [
            "starter:one-column": "basic-terminal", "one-column": "basic-terminal", "single": "basic-terminal",
            "starter:two-columns": "side-by-side", "two-columns": "side-by-side",
            "starter:quad": "quad-terminal", "quad": "quad-terminal",
            "starter:two-by-three": "two-by-three", "two-by-three": "two-by-three",
            "basic-terminal": "basic-terminal", "side-by-side": "side-by-side", "quad-terminal": "quad-terminal",
        ]
        for (key, value) in payload["starter_aliases"] as? [String: Any] ?? [:] {
            if let value = value as? String {
                aliases[normalizedBlueprintReference(key)] = normalizedBlueprintReference(value)
            }
        }
        return aliases
    }

    func isReservedBlueprintReference(_ reference: String, aliases: [String: String], entries: [[String: Any]]) -> Bool {
        let name = normalizedBlueprintReference(reference)
        return name.hasPrefix("starter:") || name.hasPrefix("saved:") || aliases[name] != nil
            || entries.contains { ($0["source"] as? String) == "built-in"
                && normalizedBlueprintReference($0["name"] as? String ?? "") == name }
    }

    /// Resolve a blueprint reference (file path or name) to a layout dict
    /// `{plan: ...}` suitable for `workspace.create`'s `layout` param.
    func resolveBlueprintPlan(_ ref: String, client: SocketClient) throws -> [String: Any] {
        let payload = try client.sendV2(method: "workspace.list_blueprints", params: ["cwd": FileManager.default.currentDirectoryPath])
        let blueprints = payload["blueprints"] as? [[String: Any]] ?? []
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizedBlueprintReference(trimmed)
        let aliases = blueprintStarterAliases(payload)
        let reserved = isReservedBlueprintReference(trimmed, aliases: aliases, entries: blueprints)
        if !reserved, blueprintReferenceLooksLikePath(trimmed) {
            let pathToTry = resolvePath(trimmed)
            guard let data = FileManager.default.contents(atPath: pathToTry) else {
                throw CLIError(message: "new-workspace: could not read blueprint file '\(pathToTry)'")
            }
            return ["plan": try blueprintPlanFromFile(at: pathToTry, data: data, client: client)]
        }
        let match: [String: Any]?
        if normalized.hasPrefix("saved:") {
            let url = String(trimmed.dropFirst("saved:".count))
            match = blueprints.first { ($0["url"] as? String) == url }
        } else {
            let name = aliases[normalized] ?? normalized
            let matches = blueprints.filter { normalizedBlueprintReference($0["name"] as? String ?? "") == name }
            if reserved {
                match = matches.first { ($0["source"] as? String) == "built-in" }
            } else {
                match = matches.first { ($0["source"] as? String) != "repo" } ?? matches.first
            }
        }
        guard let match,
              let url = match["url"] as? String,
              let data = FileManager.default.contents(atPath: resolvePath(url)) else {
            throw CLIError(message: "new-workspace: blueprint '\(ref)' not found (tried as path and name)")
        }
        return ["plan": try blueprintPlanFromFile(at: url, data: data, client: client)]
    }

    /// `c11 workspace export-blueprint --name <name> [--workspace <ref>]
    /// [--description <text>] [--format md|json] [--out <path>] [--force]`.
    /// Captures the current (or named) workspace as a
    /// `WorkspaceBlueprintFile` and writes it. Default format is `md`
    /// (Obsidian-friendly markdown under `~/.config/c11/blueprints/`); pass
    /// `--format json` for the legacy JSON envelope. Without `--out`,
    /// prints the default path written by the socket handler. `--force`
    /// allows overwriting an existing blueprint with the same name.
    func runWorkspaceExportBlueprint(
        _ args: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let (workspaceOpt, a1) = parseOption(args, name: "--workspace")
        let (nameOpt, a2) = parseOption(a1, name: "--name")
        let (descOpt, a3) = parseOption(a2, name: "--description")
        let (formatOpt, a4) = parseOption(a3, name: "--format")
        let (outOpt, a5) = parseOption(a4, name: "--out")
        let forceFlag = a5.contains("--force")
        let a6 = a5.filter { $0 != "--force" }
        if let unknown = a6.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "workspace export-blueprint: unknown flag '\(unknown)'. Known flags: --workspace <ref>, --name <name>, --description <text>, --format md|json, --out <path>, --force")
        }
        guard let name = nameOpt else {
            throw CLIError(message: "workspace export-blueprint: --name <name> is required")
        }
        let format: String = {
            guard let raw = formatOpt?.lowercased(), !raw.isEmpty else { return "md" }
            return (raw == "markdown") ? "md" : raw
        }()
        if format != "md" && format != "json" {
            throw CLIError(message: "workspace export-blueprint: --format must be md or json (got '\(format)')")
        }

        var params: [String: Any] = ["name": name, "format": format]
        if let wsRaw = workspaceOpt {
            params["workspace_id"] = try resolveWorkspaceId(wsRaw, client: client)
        }
        if let desc = descOpt {
            params["description"] = desc
        }
        if forceFlag {
            params["force"] = true
        }

        let payload = try client.sendV2(method: "workspace.export_blueprint", params: params)
        var resolvedPath = (payload["path"] as? String) ?? "?"

        if let outRaw = outOpt {
            let src = URL(fileURLWithPath: resolvedPath)
            let dst = URL(fileURLWithPath: resolvePath(outRaw))
            do {
                try FileManager.default.createDirectory(
                    at: dst.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.moveItem(at: src, to: dst)
                resolvedPath = dst.path
            } catch {
                throw CLIError(message: "workspace export-blueprint: --out move failed: \(error)")
            }
        }

        if jsonOutput {
            var mutable = payload
            mutable["path"] = resolvedPath
            print(jsonString(mutable))
        } else {
            print("OK blueprint=\(name) format=\(format) path=\(resolvedPath)")
        }
    }
}
