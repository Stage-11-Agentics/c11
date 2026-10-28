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

// MARK: - `cmux skill` subcommand
//
// Active install is scoped to Claude Code — matching the grandfathered
// `Resources/bin/claude` precedent. For every other TUI the CLI reports
// detection and prints a copy-paste snippet; c11 does not write into
// `~/.codex/`, `~/.kimi/`, or `~/.opencode/` unless the operator explicitly
// passes `--tool <name>` (a deliberate operator-directed act).

extension CMUXCLI {
    func runSkillCommand(commandArgs: [String], jsonOutput: Bool) throws {
        guard let sub = commandArgs.first else {
            print(skillCommandUsage())
            return
        }
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "help", "-h", "--help":
            print(skillCommandUsage())
        case "path":
            try runSkillPath(args: rest, jsonOutput: jsonOutput)
        case "status", "list":
            try runSkillStatus(args: rest, jsonOutput: jsonOutput)
        case "install":
            try runSkillInstall(args: rest, jsonOutput: jsonOutput)
        case "remove", "uninstall":
            try runSkillRemove(args: rest, jsonOutput: jsonOutput)
        default:
            throw CLIError(message: "Unknown skill subcommand: \(sub). Try `c11 skill help`.")
        }
    }

    // MARK: Structured skill-subcommand parser.
    //
    // The global optionValue/hasFlag helpers are permissive: they don't
    // understand `--flag=value`, don't reject unknown flags, and happily
    // consume the next flag as a value. For `cmux skill`, a user mistyping
    // `--home --json` previously resolved the home override to the string
    // `--json`, which is worse than failing. Each skill subcommand declares
    // its allowed flags and this parser rejects anything outside the list.

    struct SkillFlagSpec {
        enum Kind { case flag, value }
        let name: String
        let kind: Kind
    }

    struct ParsedSkillArgs {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []

        func value(_ name: String) -> String? { values[name] }
        func has(_ name: String) -> Bool { flags.contains(name) }
    }

    func parseSkillSubcommandArgs(
        _ args: [String],
        spec: [SkillFlagSpec]
    ) throws -> ParsedSkillArgs {
        let byName = Dictionary(uniqueKeysWithValues: spec.map { ($0.name, $0) })
        var out = ParsedSkillArgs()
        var i = 0
        while i < args.count {
            let raw = args[i]
            if raw.hasPrefix("--") {
                let name: String
                let inlineValue: String?
                if let eq = raw.firstIndex(of: "=") {
                    name = String(raw[..<eq])
                    inlineValue = String(raw[raw.index(after: eq)...])
                } else {
                    name = raw
                    inlineValue = nil
                }
                guard let flag = byName[name] else {
                    throw CLIError(message: "Unknown flag '\(name)' for this subcommand.")
                }
                switch flag.kind {
                case .flag:
                    if inlineValue != nil {
                        throw CLIError(message: "Flag '\(name)' does not take a value.")
                    }
                    out.flags.insert(name)
                case .value:
                    if let v = inlineValue {
                        out.values[name] = v
                    } else {
                        guard i + 1 < args.count else {
                            throw CLIError(message: "Flag '\(name)' requires a value.")
                        }
                        let next = args[i + 1]
                        if next.hasPrefix("--") {
                            throw CLIError(message: "Flag '\(name)' requires a value, got another flag '\(next)'.")
                        }
                        out.values[name] = next
                        i += 1
                    }
                }
            } else {
                out.positional.append(raw)
            }
            i += 1
        }
        return out
    }

    /// JSON encoder for `cmux skill *` output. Forces `.sortedKeys` so
    /// scripts parsing the output get deterministic key order across builds.
    func skillJSONString(_ object: Any) -> String {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }

    func skillCommandUsage() -> String {
        return """
        c11 skill — manage the c11 skill file for detected agent tools.

        Subcommands:
          path                           Print the bundled skill source directory.
          status [--tool NAME] [--json]  Show detection + install status per tool.
          install [--tool NAME]          Install (default: claude only).
                  [--dry-run] [--force]  Dry-run, or force re-copy even if hash matches.
                                         Copies synced from a checkout or edited
                                         are kept unless --force replaces them.
                  [--home PATH]          Override $HOME (useful for tests).
          remove  [--tool NAME]          Remove c11-installed skills from the tool.
                  [--home PATH] [--force]  Local copies are kept unless --force.

        Tools: claude, codex, kimi, opencode.

        Principle:
          Claude Code is the default active install (grandfathered exception).
          For every other tool, c11 prints the manual command and only writes
          to disk when --tool is passed explicitly — the operator stays in charge.

        OpenCode runtime plugin:
          The bundled PATH wrapper loads the notification/status plugin for
          that process only. Skill install/remove never writes or deletes
          ~/.config/opencode/plugins/. Older copies remain for operator review.
        """
    }

    func homeFromParsedSkillArgs(_ parsed: ParsedSkillArgs) -> URL {
        if let override = parsed.value("--home") {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        let envHome = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: envHome, isDirectory: true).standardizedFileURL
    }

    func targetFromParsedSkillArgs(
        _ parsed: ParsedSkillArgs,
        defaultTarget: SkillInstallerTarget
    ) throws -> SkillInstallerTarget {
        guard let raw = parsed.value("--tool") else { return defaultTarget }
        guard let tool = SkillInstallerTarget(rawValue: raw.lowercased()) else {
            throw CLIError(message: "Unknown tool '\(raw)'. Supported: \(SkillInstallerTarget.allCases.map { $0.rawValue }.joined(separator: ", "))")
        }
        return tool
    }

    func resolveSkillSource(jsonOutput: Bool) throws -> URL {
        let exec = resolvedExecutableURL()
        guard let source = SkillInstaller.defaultSourceURL(executableURL: exec) else {
            throw CLIError(message: "Could not locate the bundled skills directory. Set C11_SKILLS_SOURCE to override.")
        }
        return source
    }

    func runSkillPath(args: [String], jsonOutput: Bool) throws {
        let parsed = try parseSkillSubcommandArgs(args, spec: [
            SkillFlagSpec(name: "--json", kind: .flag),
        ])
        let source = try resolveSkillSource(jsonOutput: jsonOutput)
        if jsonOutput || parsed.has("--json") {
            print(skillJSONString(["path": source.path]))
        } else {
            print(source.path)
        }
    }

    func runSkillStatus(args: [String], jsonOutput: Bool) throws {
        let parsed = try parseSkillSubcommandArgs(args, spec: [
            SkillFlagSpec(name: "--tool", kind: .value),
            SkillFlagSpec(name: "--home", kind: .value),
            SkillFlagSpec(name: "--json", kind: .flag),
        ])
        let source = try resolveSkillSource(jsonOutput: jsonOutput)
        let home = homeFromParsedSkillArgs(parsed)
        let emitJSON = jsonOutput || parsed.has("--json")

        var targets = SkillInstallerTarget.allCases
        if let raw = parsed.value("--tool") {
            guard let target = SkillInstallerTarget(rawValue: raw.lowercased()) else {
                throw CLIError(message: "Unknown tool '\(raw)'.")
            }
            targets = [target]
        }

        var rows: [[String: Any]] = []
        for target in targets {
            let detected = target.isDetected(home: home)
            var packageRows: [[String: Any]] = []
            var errorPayload: [String: Any]? = nil
            if detected {
                do {
                    let statuses = try SkillInstaller.status(for: target, home: home, sourceDir: source)
                    packageRows = statuses.map { st in
                        var row: [String: Any] = [
                            "package": st.package.name,
                            "state": st.state.rawValue,
                            "dest": st.destinationDir.path,
                            "source_sha256": st.sourceContentHash,
                        ]
                        if let record = st.record {
                            row["installed_sha256"] = record.sourceContentHash
                            row["installed_at"] = record.installedAt
                            row["app_version"] = record.appVersion
                            row["installed_by"] = record.installedBy ?? SkillInstallerRecord.installedByApp
                            row["commit"] = record.commitShort
                        }
                        return row
                    }
                } catch let err as SkillInstallerError {
                    var payload: [String: Any] = [
                        "code": err.code.rawValue,
                        "message": err.message,
                    ]
                    if let p = err.path { payload["path"] = p }
                    errorPayload = payload
                } catch {
                    errorPayload = [
                        "code": "unknown",
                        "message": "\(error)",
                    ]
                }
            }
            var row: [String: Any] = [
                "tool": target.rawValue,
                "display_name": target.displayName,
                "detected": detected,
                "skills_dir": target.skillsDir(home: home).path,
                "packages": packageRows,
            ]
            if let err = errorPayload { row["error"] = err }
            rows.append(row)
        }

        if emitJSON {
            print(skillJSONString(["targets": rows, "source": source.path]))
            return
        }
        print("Bundled skills: \(source.path)")
        print("")
        for row in rows {
            let tool = (row["tool"] as? String) ?? "?"
            let display = (row["display_name"] as? String) ?? tool
            let detected = (row["detected"] as? Bool) ?? false
            let dir = (row["skills_dir"] as? String) ?? ""
            let detectTag = detected ? "detected" : "not detected"
            print("\(display) [\(tool)] — \(detectTag)")
            print("  skills dir: \(dir)")
            if let err = row["error"] as? [String: Any] {
                let code = (err["code"] as? String) ?? "error"
                let msg = (err["message"] as? String) ?? ""
                print("  error [\(code)]: \(msg)")
                continue
            }
            let packageRows = (row["packages"] as? [[String: Any]]) ?? []
            if !detected {
                print("  (\(display) config dir not present; install skipped)")
                continue
            }
            if packageRows.isEmpty {
                print("  (no bundled packages found)")
                continue
            }
            for pkg in packageRows {
                let name = (pkg["package"] as? String) ?? "?"
                let state = (pkg["state"] as? String) ?? "?"
                let version: String
                if pkg["installed_by"] as? String == SkillInstallerRecord.installedBySync {
                    version = " synced from \((pkg["commit"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "a checkout")"
                } else {
                    version = (pkg["app_version"] as? String).map { " v\($0)" } ?? ""
                }
                let installed = (pkg["installed_at"] as? String).map { " @ \($0)" } ?? ""
                print("  - \(name): \(state)\(version)\(installed)")
            }
        }
    }

    func runSkillInstall(args: [String], jsonOutput: Bool) throws {
        let parsed = try parseSkillSubcommandArgs(args, spec: [
            SkillFlagSpec(name: "--tool", kind: .value),
            SkillFlagSpec(name: "--home", kind: .value),
            SkillFlagSpec(name: "--json", kind: .flag),
            SkillFlagSpec(name: "--force", kind: .flag),
            SkillFlagSpec(name: "--dry-run", kind: .flag),
        ])
        let source = try resolveSkillSource(jsonOutput: jsonOutput)
        let home = homeFromParsedSkillArgs(parsed)
        let target = try targetFromParsedSkillArgs(parsed, defaultTarget: .claude)
        let dryRun = parsed.has("--dry-run")
        let force = parsed.has("--force")
        let emitJSON = jsonOutput || parsed.has("--json")

        if !target.isDetected(home: home) {
            let msg = "Tool '\(target.rawValue)' config dir \(target.configRoot(home: home).path) not found. Install \(target.displayName) first, or pass --tool <other> if you meant a different target."
            if emitJSON {
                print(skillJSONString(["error": "target_not_detected", "tool": target.rawValue, "message": msg]))
                exit(2)
            }
            throw CLIError(message: msg)
        }

        if dryRun {
            let statuses = try SkillInstaller.status(for: target, home: home, sourceDir: source)
            let planned = statuses.filter { force || ($0.state != .installedCurrent && !$0.state.isLocalCopy) }
                .map { $0.package.name }
            let skipped = statuses.filter { !force && $0.state == .installedCurrent }.map { $0.package.name }
            let kept = statuses.filter { !force && $0.state.isLocalCopy }.map { $0.package.name }
            if emitJSON {
                print(skillJSONString([
                    "dry_run": true,
                    "tool": target.rawValue,
                    "planned": planned,
                    "skipped": skipped,
                    "kept_local": kept,
                    "dest": target.skillsDir(home: home).path,
                ]))
            } else {
                print("Dry run — \(target.displayName) (\(target.skillsDir(home: home).path))")
                if planned.isEmpty {
                    print("  nothing to do; all packages current")
                } else {
                    print("  would write: \(planned.joined(separator: ", "))")
                }
                if !skipped.isEmpty {
                    print("  would skip (up-to-date): \(skipped.joined(separator: ", "))")
                }
                if !kept.isEmpty {
                    print("  would keep (local copy; --force replaces): \(kept.joined(separator: ", "))")
                }
            }
            return
        }

        let result = try SkillInstaller.install(
            target: target,
            home: home,
            sourceDir: source,
            force: force
        )

        if emitJSON {
            print(skillJSONString([
                "tool": target.rawValue,
                "dest": result.destDir.path,
                "installed": result.installed,
                "refreshed": result.refreshed,
                "skipped": result.skipped,
                "kept_local": result.keptLocal,
            ]))
        } else {
            print("Installed skill for \(target.displayName) at \(result.destDir.path)")
            if !result.installed.isEmpty {
                print("  installed: \(result.installed.joined(separator: ", "))")
            }
            if !result.refreshed.isEmpty {
                print("  refreshed: \(result.refreshed.joined(separator: ", "))")
            }
            if !result.skipped.isEmpty {
                print("  skipped (up-to-date): \(result.skipped.joined(separator: ", "))")
            }
            if !result.keptLocal.isEmpty {
                print("  kept (local copy; --force replaces): \(result.keptLocal.joined(separator: ", "))")
            }
        }

        // For TUIs that support plugins (OpenCode), install those too.
        if target.supportsPlugins {
            let pluginResult = try SkillInstaller.installPlugins(
                target: target,
                home: home,
                sourceDir: source,
                force: force
            )
            if emitJSON {
                // Re-print as a combined object — but the skills result was
                // already printed above. For JSON mode, callers who want the
                // plugin result should check stdout is two JSON objects. This
                // is acceptable because the primary install target is skills;
                // plugins are a bonus side-effect for OpenCode.
                if !pluginResult.installed.isEmpty || !pluginResult.skipped.isEmpty {
                    print(skillJSONString([
                        "tool": target.rawValue,
                        "plugins_dest": pluginResult.destDir.path,
                        "plugins_installed": pluginResult.installed,
                        "plugins_skipped": pluginResult.skipped,
                    ]))
                }
            } else {
                if !pluginResult.installed.isEmpty {
                    print("  plugins installed: \(pluginResult.installed.joined(separator: ", "))")
                }
                if !pluginResult.skipped.isEmpty {
                    print("  plugins skipped (up-to-date): \(pluginResult.skipped.joined(separator: ", "))")
                }
            }
        }
    }

    func runSkillRemove(args: [String], jsonOutput: Bool) throws {
        let parsed = try parseSkillSubcommandArgs(args, spec: [
            SkillFlagSpec(name: "--tool", kind: .value),
            SkillFlagSpec(name: "--home", kind: .value),
            SkillFlagSpec(name: "--json", kind: .flag),
            SkillFlagSpec(name: "--force", kind: .flag),
        ])
        let source = try resolveSkillSource(jsonOutput: jsonOutput)
        let home = homeFromParsedSkillArgs(parsed)
        let target = try targetFromParsedSkillArgs(parsed, defaultTarget: .claude)
        let emitJSON = jsonOutput || parsed.has("--json")

        let result = try SkillInstaller.remove(
            target: target, home: home, sourceDir: source, force: parsed.has("--force"))
        if emitJSON {
            print(skillJSONString([
                "tool": target.rawValue,
                "dest": result.destDir.path,
                "removed": result.removed,
                "skipped": result.skipped,
                "kept_local": result.keptLocal,
            ]))
        } else {
            print("Removed skill for \(target.displayName) from \(result.destDir.path)")
            if !result.removed.isEmpty {
                print("  removed: \(result.removed.joined(separator: ", "))")
            }
            if !result.skipped.isEmpty {
                print("  skipped: \(result.skipped.joined(separator: ", "))")
            }
            if !result.keptLocal.isEmpty {
                print("  kept (local copy; --force removes): \(result.keptLocal.joined(separator: ", "))")
            }
        }

        // Remove plugins for TUIs that support them (OpenCode).
        if target.supportsPlugins {
            let pluginResult = try SkillInstaller.removePlugins(
                target: target,
                home: home,
                sourceDir: source
            )
            if emitJSON {
                if !pluginResult.removed.isEmpty || !pluginResult.skipped.isEmpty {
                    print(skillJSONString([
                        "tool": target.rawValue,
                        "plugins_removed": pluginResult.removed,
                        "plugins_skipped": pluginResult.skipped,
                    ]))
                }
            } else {
                if !pluginResult.removed.isEmpty {
                    print("  plugins removed: \(pluginResult.removed.joined(separator: ", "))")
                }
                if !pluginResult.skipped.isEmpty {
                    print("  plugins skipped: \(pluginResult.skipped.joined(separator: ", "))")
                }
            }
        }
    }
}
