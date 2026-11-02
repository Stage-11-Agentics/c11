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

    // MARK: - CMUX-37 Phase 1: snapshot commands

    /// `c11 snapshot [--workspace <ref>] [--out <path>] [--all] [--json]`. Defaults
    /// to the current workspace (`$C11_WORKSPACE_ID`). Prints the resolved
    /// path + snapshot id. Backed by `snapshot.create` v2.
    ///
    /// `--out <path>` is honoured in the CLI process, not over the socket.
    /// The socket always writes to the default directory (B3: socket-initiated
    /// captures cannot choose their destination). After the socket returns,
    /// the CLI — running with the user's real FS permissions — moves the
    /// emitted file to the requested path.
    ///
    /// `--all` captures every open workspace. Mutually exclusive with
    /// `--workspace` and `--out`.
    func runSnapshotCreate(
        _ args: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let (workspaceOpt, afterWorkspace) = parseOption(args, name: "--workspace")
        let (outOpt, afterOut) = parseOption(afterWorkspace, name: "--out")
        let (afterAll, hasAll) = parseFlag(afterOut, name: "--all")
        if let unknown = afterAll.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "snapshot: unknown flag '\(unknown)'. Known flags: --workspace <ref>, --out <path>, --all")
        }

        if hasAll {
            if workspaceOpt != nil {
                throw CLIError(message: "snapshot: --all and --workspace are mutually exclusive")
            }
            if outOpt != nil {
                throw CLIError(message: "snapshot: --all and --out are mutually exclusive")
            }
            let payload = try client.sendV2(method: "snapshot.create", params: ["all": true])
            let snapshots = payload["snapshots"] as? [[String: Any]] ?? []
            if jsonOutput {
                print(jsonString(payload))
                return
            }
            var anyFailure = false
            for snap in snapshots {
                let wsRef = (snap["workspace_ref"] as? String) ?? "?"
                if let err = snap["error"] as? String {
                    print("ERROR workspace=\(wsRef) reason=\(err)")
                    anyFailure = true
                } else {
                    let id = (snap["snapshot_id"] as? String) ?? "?"
                    let path = (snap["path"] as? String) ?? "?"
                    let count = (snap["panel_count"] as? Int) ?? 0
                    let selected = (snap["selected"] as? Bool) == true ? " (selected)" : ""
                    print("OK snapshot=\(id) panels=\(count) workspace=\(wsRef) path=\(path)\(selected)")
                }
            }
            if let setId = payload["set_id"] as? String,
               let setPath = payload["set_path"] as? String {
                print("OK set=\(setId) path=\(setPath)")
            } else if let setErr = payload["set_error"] as? String {
                print("ERROR manifest reason=\(setErr)")
                anyFailure = true
            }
            if anyFailure {
                throw CLIError(message: "snapshot --all: one or more writes failed")
            }
            return
        }

        var params: [String: Any] = [:]
        if let wsRaw = workspaceOpt {
            // Route through the standard resolver so `workspace:2`
            // (index-form ref), `workspace:<uuid>` (handle-form ref), bare
            // UUID, and bare integer index all work — matches what the
            // help text advertises (Trident I3). `parseUUIDFromRef` only
            // knew the UUID shapes.
            params["workspace_id"] = try resolveWorkspaceId(wsRaw, client: client)
        }
        let payload = try client.sendV2(method: "snapshot.create", params: params)
        let id = (payload["snapshot_id"] as? String) ?? "?"
        var resolvedPath = (payload["path"] as? String) ?? "?"
        let count = (payload["panel_count"] as? Int) ?? 0
        let wsRef = (payload["workspace_ref"] as? String) ?? "?"
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
                throw CLIError(message: "snapshot: --out move failed: \(error)")
            }
        }
        if jsonOutput {
            var mutable = payload
            mutable["path"] = resolvedPath
            print(jsonString(mutable))
            return
        }
        print("OK snapshot=\(id) panels=\(count) workspace=\(wsRef) path=\(resolvedPath)")
    }

    /// `c11 restore <snapshot-id-or-path> [--json]`. Reads
    /// `C11_SESSION_RESUME` / `CMUX_SESSION_RESUME` at this site only;
    /// when set (any non-empty non-"0"/"false" value) threads
    /// `{"restart_registry": "phase1"}` into the v2 call so cc terminals
    /// resume via `cc --resume <session-id>`.
    ///
    /// Path targets are resolved in the CLI process, not over the socket
    /// (B3: the socket never reads caller-supplied paths — it would turn
    /// the restore handler into an arbitrary-.json-parser primitive). The
    /// CLI reads the file with the user's real FS permissions, extracts
    /// the `snapshot_id`, plants the file under
    /// `~/.c11-snapshots/<snapshot_id>.json` if it isn't already there,
    /// and then submits `snapshot.restore` by id.
    func runSnapshotRestore(
        _ args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        // `--select` was advertised in help but silently ignored — the
        // socket focus policy (`CLAUDE.md` "Socket focus policy" section)
        // forbids `snapshot.restore` from stealing focus, and
        // `v2SnapshotRestore` cleared `options.select` unconditionally.
        // Per Trident I4 option (b), drop the promise rather than grant a
        // focus-intent exception. The flag is no longer accepted.
        //
        // I2: `--in-place` / `--replace` (aliases) replaces the current
        // workspace's content with the restored plan instead of creating
        // a fresh workspace. Without it, running `c11 restore <id>` twice
        // produces two duplicate workspaces.
        var inPlace = false
        var positional: [String] = []
        for arg in args {
            switch arg {
            case "--in-place", "--replace":
                inPlace = true
            default:
                if arg.hasPrefix("--") {
                    throw CLIError(message: "restore: unknown flag '\(arg)'. Known flags: --in-place / --replace")
                }
                positional.append(arg)
            }
        }
        guard let target = positional.first else {
            throw CLIError(message: "restore: missing snapshot id or path")
        }
        if positional.count > 1 {
            throw CLIError(message: "restore: unexpected trailing argument '\(positional[1])'")
        }
        var params: [String: Any] = [:]
        var isSetRestore = false
        // Path-like targets (absolute / `~` / extension `.json`) get
        // resolved in the CLI. Everything else is treated as a snapshot
        // id and submitted as-is; the handler's traversal guard catches
        // any shenanigans there.
        if target.hasPrefix("/")
            || target.lowercased().hasSuffix(".json")
            || target.hasPrefix("~")
            || target.contains("/") {
            let resolvedPath = resolvePath(target)
            let (id, kind) = try importSnapshotOrSetFileForRestore(pathOnDisk: resolvedPath)
            switch kind {
            case .single:
                params["snapshot_id"] = id
            case .set:
                isSetRestore = true
                params["set_id"] = id
            }
        } else {
            // Bare-id form: probe `~/.c11-snapshots/sets/<id>.json` first
            // (the manifest path) and only fall through to single-snapshot
            // restore if no manifest exists. Both ids share the ULID
            // grammar so we cannot disambiguate by shape alone.
            if isLocalSnapshotSetId(target) {
                isSetRestore = true
                params["set_id"] = target
            } else {
                params["snapshot_id"] = target
            }
        }
        // Env gate: mirrored by `mirrorC11CmuxEnv()` so either variable works.
        let env = ProcessInfo.processInfo.environment
        let raw = env["C11_SESSION_RESUME"] ?? env["CMUX_SESSION_RESUME"]
        if let raw, isTruthyFlag(raw) {
            params["restart_registry"] = "phase1"
        }
        if isSetRestore && inPlace {
            throw CLIError(message: "restore: --in-place is not supported for snapshot sets (a set creates several fresh workspaces)")
        }
        if inPlace {
            params["in_place"] = true
            // Resolve the target workspace. Destructive commands must
            // prefer the caller's own workspace (CMUX_WORKSPACE_ID /
            // C11_WORKSPACE_ID) per the socket focus policy in CLAUDE.md:
            // a background agent running `c11 restore --in-place` should
            // replace its own workspace, not whatever the operator
            // currently has selected. Only when the CLI is invoked
            // outside a c11 surface (no env) do we fall back to
            // `workspace.current`.
            let callerWs = client.scopedWindow == nil ? (env["CMUX_WORKSPACE_ID"] ?? env["C11_WORKSPACE_ID"]) : nil
            if let trimmed = callerWs?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty,
               UUID(uuidString: trimmed) != nil {
                params["target_workspace_id"] = trimmed
            } else {
                let currentPayload = try client.sendV2(method: "workspace.current", params: [:])
                if let wsId = currentPayload["workspace_id"] as? String,
                   UUID(uuidString: wsId) != nil {
                    params["target_workspace_id"] = wsId
                } else if let ref = currentPayload["workspace_ref"] as? String,
                          let uuid = parseUUIDFromRef(ref) {
                    params["target_workspace_id"] = uuid.uuidString
                } else {
                    throw CLIError(message: "restore: --in-place could not resolve the target workspace (set CMUX_WORKSPACE_ID or invoke from a c11 panel)")
                }
            }
        }
        let method = isSetRestore ? "snapshot.restore_set" : "snapshot.restore"
        let payload = try client.sendV2(method: method, params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        if isSetRestore {
            let setId = (payload["set_id"] as? String) ?? "?"
            let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
            let selected = (payload["selected_workspace_ref"] as? String) ?? ""
            print("OK set=\(setId) workspaces=\(workspaces.count)\(selected.isEmpty ? "" : " selected=\(selected)")")
            for entry in workspaces {
                if let err = entry["error"] as? String {
                    let snap = (entry["snapshot_id"] as? String) ?? "?"
                    let wsRef = (entry["original_workspace_ref"] as? String) ?? (entry["workspace_ref"] as? String) ?? "?"
                    print("  ERROR snapshot=\(snap) original=\(wsRef) reason=\(err)")
                    continue
                }
                let snap = (entry["snapshot_id"] as? String) ?? "?"
                let ref = (entry["workspaceRef"] as? String) ?? "?"
                let surfaceRefs = entry["panelRefs"] as? [String: String] ?? [:]
                let isSel = (entry["selected"] as? Bool) == true ? " (selected)" : ""
                print("  OK snapshot=\(snap) workspace=\(ref) panels=\(surfaceRefs.count)\(isSel)")
            }
            let warnings = payload["warnings"] as? [String] ?? []
            if !warnings.isEmpty {
                print("warnings: \(warnings.count)")
                for w in warnings { print("  - \(w)") }
            }
            return
        }
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

    /// Whether `~/.c11-snapshots/sets/<id>.json` exists. Used by the
    /// polymorphic `c11 restore <id>` dispatch.
    func isLocalSnapshotSetId(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return false
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home
            .appendingPathComponent(".c11-snapshots/sets")
            .appendingPathComponent("\(trimmed).json")
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Read a snapshot file at `pathOnDisk`, extract `snapshot_id`, and
    /// ensure a copy exists under `~/.c11-snapshots/<snapshot_id>.json` so
    /// the v2 handler's id-based lookup can find it. Returns the
    /// snapshot_id.
    ///
    /// Exists because the socket rejects caller-supplied paths (B3). The
    /// CLI holds the user's real FS permissions, so reading and copying
    /// the file here is safe in a way reading via the socket is not.
    func importSnapshotFileForRestore(pathOnDisk: String) throws -> String {
        let (id, kind) = try importSnapshotOrSetFileForRestore(pathOnDisk: pathOnDisk)
        guard kind == .single else {
            throw CLIError(message: "restore: '\(pathOnDisk)' is a set manifest; use `c11 restore <set-id>` directly")
        }
        return id
    }

    enum SnapshotImportKind { case single, set }

    /// Read a snapshot or snapshot-set file on disk (with the user's real
    /// FS permissions), classify it, and stage it under the canonical
    /// `~/.c11-snapshots/` location so the v2 id-based handlers can find
    /// it. Returns the id and which kind of artifact it was.
    ///
    /// Classification: a single snapshot envelope carries a top-level
    /// `snapshot_id` and `plan` key; a set manifest carries `set_id` and
    /// `snapshots` (list). Anything else is rejected.
    func importSnapshotOrSetFileForRestore(pathOnDisk: String) throws -> (id: String, kind: SnapshotImportKind) {
        let srcURL = URL(fileURLWithPath: pathOnDisk)
        let data: Data
        do {
            data = try Data(contentsOf: srcURL)
        } catch {
            throw CLIError(message: "restore: failed to read '\(pathOnDisk)': \(error)")
        }
        let dict: [String: Any]
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            guard let asDict = obj as? [String: Any] else {
                throw CLIError(message: "restore: '\(pathOnDisk)' is not a JSON object")
            }
            dict = asDict
        } catch let err as CLIError {
            throw err
        } catch {
            throw CLIError(message: "restore: file '\(pathOnDisk)' is not valid JSON: \(error)")
        }

        let id: String
        let kind: SnapshotImportKind
        let stagingSubdir: String
        if let setId = dict["set_id"] as? String, !setId.isEmpty,
           dict["snapshots"] is [Any] {
            id = setId
            kind = .set
            stagingSubdir = ".c11-snapshots/sets"
        } else if let snapId = dict["snapshot_id"] as? String, !snapId.isEmpty,
                  dict["plan"] != nil {
            id = snapId
            kind = .single
            stagingSubdir = ".c11-snapshots"
        } else {
            throw CLIError(message: "restore: '\(pathOnDisk)' is not a recognised snapshot envelope (missing snapshot_id+plan or set_id+snapshots)")
        }

        // Reject traversal-shaped ids before we touch disk — matches the
        // grammar the v2 handler enforces on the other side.
        let idRange = NSRange(location: 0, length: (id as NSString).length)
        let safePattern = try NSRegularExpression(
            pattern: "^[A-Za-z0-9_-]{1,128}$",
            options: []
        )
        if safePattern.firstMatch(in: id, options: [], range: idRange) == nil {
            throw CLIError(message: "restore: id '\(id)' is not a safe filename stem")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stagingDir = home.appendingPathComponent(stagingSubdir, isDirectory: true)
        let destURL = stagingDir.appendingPathComponent("\(id).json")
        if destURL.standardizedFileURL.path == srcURL.standardizedFileURL.path {
            return (id, kind)
        }
        do {
            try FileManager.default.createDirectory(
                at: stagingDir,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: srcURL, to: destURL)
        } catch {
            throw CLIError(message: "restore: failed to stage '\(pathOnDisk)' into ~/\(stagingSubdir)/: \(error)")
        }
        return (id, kind)
    }

    /// `c11 list-snapshots [--json] [--sets] [--all]`. Columns by default:
    /// SNAPSHOT_ID, CREATED_AT, WORKSPACE_TITLE, SURFACES, ORIGIN, SOURCE.
    ///
    /// `--sets` switches to the manifest table
    /// (SET_ID, CREATED_AT, COUNT, C11_VERSION). `--all` prints both
    /// tables back-to-back. `--json` is accepted both as a global
    /// pre-subcommand flag (handled by the main parser and threaded in
    /// via `jsonOutput`) and as a subcommand-local flag.
    func runListSnapshots(
        _ args: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        var localJson = false
        var listSets = false
        var listAll = false
        for arg in args {
            switch arg {
            case "--json":
                localJson = true
            case "--sets":
                listSets = true
            case "--all":
                listAll = true
            default:
                if arg.hasPrefix("--") {
                    throw CLIError(message: "list-snapshots: unknown flag '\(arg)'. Known flags: --json, --sets, --all")
                }
                throw CLIError(message: "list-snapshots: unexpected argument '\(arg)'")
            }
        }
        let wantJson = jsonOutput || localJson
        if listSets && listAll {
            throw CLIError(message: "list-snapshots: --sets and --all are mutually exclusive")
        }
        // --sets: only the manifest table.
        if listSets {
            try printSnapshotSetsTable(client: client, wantJson: wantJson)
            return
        }
        // --all: per-snapshot table, blank line, then the manifest table.
        if listAll {
            try printSnapshotsTable(client: client, wantJson: wantJson)
            if !wantJson { print("") }
            try printSnapshotSetsTable(client: client, wantJson: wantJson)
            return
        }
        try printSnapshotsTable(client: client, wantJson: wantJson)
    }

    /// `c11 list-snapshots --sets`: enumerate set manifests under
    /// `~/.c11-snapshots/sets/`. Columns: SET_ID, CREATED_AT, COUNT,
    /// C11_VERSION.
    func printSnapshotSetsTable(client: SocketClient, wantJson: Bool) throws {
        let payload = try client.sendV2(method: "snapshot.list_sets", params: [:])
        if wantJson {
            print(jsonString(payload))
            return
        }
        let sets = payload["sets"] as? [[String: Any]] ?? []
        if sets.isEmpty {
            print("no snapshot sets")
            return
        }
        func pad(_ s: String, _ width: Int) -> String {
            if s.count >= width { return s }
            return s + String(repeating: " ", count: width - s.count)
        }
        print(
            pad("SET_ID", 26) + "  "
            + pad("CREATED_AT", 24) + "  "
            + pad("COUNT", 6) + "  "
            + pad("C11_VERSION", 18)
        )
        for entry in sets {
            let id = (entry["set_id"] as? String) ?? "?"
            let created = (entry["created_at"] as? String) ?? "?"
            let count = (entry["snapshot_count"] as? Int).map(String.init) ?? "?"
            let version = (entry["c11_version"] as? String) ?? ""
            print(
                pad(id, 26) + "  "
                + pad(created, 24) + "  "
                + pad(count, 6) + "  "
                + pad(version, 18)
            )
        }
    }

    /// `c11 list-snapshots`: enumerate per-workspace snapshots.
    func printSnapshotsTable(client: SocketClient, wantJson: Bool) throws {
        let payload = try client.sendV2(method: "snapshot.list", params: [:])
        guard let snapshotsAny = payload["snapshots"] as? [[String: Any]] else {
            if wantJson {
                print(jsonString(payload))
                return
            }
            print("no snapshots")
            return
        }
        if wantJson {
            print(jsonString(payload))
            return
        }
        if snapshotsAny.isEmpty {
            print("no snapshots")
            return
        }
        // Format fixed-width columns. Titles are free-form so we truncate
        // long ones rather than bloat the row. `%s` does not work with
        // Swift `String` (only with `CVarArg`-bridged `NSString`), so pad
        // natively via `String.padding(toLength:withPad:startingAt:)` —
        // emits garbage or crashes with the printf-style form (Trident I5).
        let rows: [(String, String, String, String, String, String)] = snapshotsAny.map { entry in
            let id = (entry["snapshot_id"] as? String) ?? "?"
            let created = (entry["created_at"] as? String) ?? "?"
            let origin = (entry["origin"] as? String) ?? "?"
            let source = (entry["source"] as? String) ?? "current"
            // I8: unreadable rows carry a `{"status": "unreadable", "reason": "..."}`
            // payload under `readability`. Show `UNREADABLE` in the title
            // column and `?` in the surfaces column so operators can see
            // the bad file without losing sight of the healthy rows. The
            // reason is preserved on the wire (`--json`) for machine
            // consumers.
            let readability = entry["readability"] as? [String: Any]
            if (readability?["status"] as? String) == "unreadable" {
                let unreadableLabel = String(localized: "cli.listSnapshots.column.unreadable",
                                             defaultValue: "UNREADABLE")
                return (id, created, truncate(unreadableLabel, max: 32), "?", origin, source)
            }
            let title = (entry["workspace_title"] as? String) ?? "(no title)"
            let surfaces = (entry["panel_count"] as? Int).map(String.init) ?? "?"
            return (id, created, truncate(title, max: 32), surfaces, origin, source)
        }
        func pad(_ s: String, _ width: Int) -> String {
            if s.count >= width { return s }
            return s + String(repeating: " ", count: width - s.count)
        }
        print(
            pad("SNAPSHOT_ID", 26) + "  "
            + pad("CREATED_AT", 24) + "  "
            + pad("WORKSPACE_TITLE", 32) + "  "
            + pad("PANELS", 8) + "  "
            + pad("ORIGIN", 12) + "  "
            + pad("SOURCE", 8)
        )
        for r in rows {
            print(
                pad(r.0, 26) + "  "
                + pad(r.1, 24) + "  "
                + pad(r.2, 32) + "  "
                + pad(r.3, 8) + "  "
                + pad(r.4, 12) + "  "
                + pad(r.5, 8)
            )
        }
        // I8: after the main table, show the reason for each unreadable
        // row so operators have enough to investigate (the path and the
        // parse error). The tabular form keeps `UNREADABLE` in the title
        // column; the per-row reason goes here.
        let unreadables = snapshotsAny.compactMap { entry -> (String, String, String)? in
            guard let readability = entry["readability"] as? [String: Any],
                  (readability["status"] as? String) == "unreadable" else { return nil }
            let id = (entry["snapshot_id"] as? String) ?? "?"
            let path = (entry["path"] as? String) ?? "?"
            let reason = (readability["reason"] as? String) ?? ""
            return (id, path, reason)
        }
        if !unreadables.isEmpty {
            let prefix = String(localized: "cli.listSnapshots.unreadable.prefix",
                                defaultValue: "unreadable: ")
            print("")
            for (id, path, reason) in unreadables {
                print("  \(prefix)\(id) [\(path)]: \(reason)")
            }
        }
    }

    /// `parseUUIDFromRef("workspace:abc…")` → UUID. Also accepts a bare
    /// UUID string. Returns nil on anything else.
    func parseUUIDFromRef(_ raw: String) -> UUID? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: trimmed) { return uuid }
        if let colon = trimmed.firstIndex(of: ":") {
            let suffix = String(trimmed[trimmed.index(after: colon)...])
            return UUID(uuidString: suffix)
        }
        return nil
    }

    /// Truthiness rule used by `C11_SESSION_RESUME`: any non-empty value
    /// that isn't `"0"` or `"false"` (case-insensitive) counts as on.
    func isTruthyFlag(_ raw: String) -> Bool {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.isEmpty { return false }
        return v != "0" && v != "false" && v != "no" && v != "off"
    }

    func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        let idx = s.index(s.startIndex, offsetBy: max - 1)
        return String(s[..<idx]) + "…"
    }

    func sanitizedFilenameComponent(_ raw: String) -> String {
        let sanitized = raw.replacingOccurrences(
            of: #"[^\p{L}\p{N}._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "item" : trimmed
    }

    func bestEffortPruneTemporaryFiles(
        in directoryURL: URL,
        keepingMostRecent maxCount: Int = 50,
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let datedEntries = entries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in datedEntries.enumerated() {
            if index >= maxCount || now.timeIntervalSince(entry.date) > maxAge {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }
}
