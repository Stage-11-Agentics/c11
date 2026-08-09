import Foundation

// Thin CLI shim for the `c11 config` family (C11-180, design §6). All logic
// lives in `Sources/ConfigCommandCore.swift` (linked into both the app and this
// CLI target, and unit-locked under c11-logic). `list/recent/stats/save/edit/
// rm/reorder/default` operate directly on the state-root files — app-down, no
// socket — and are dispatched from CLI/c11.swift BEFORE the socket connect.
// `config launch` is the one socket-bound subcommand (spawning a surface needs
// the running app) and is handled in the post-connect switch.

// MARK: - Local arg helpers (self-contained: the c11.swift private helpers are
// file-scoped, so this file parses its own subArgs).

private func cfgOption(_ args: [String], _ name: String) -> String? {
    var i = 0
    while i < args.count {
        if args[i] == name, i + 1 < args.count { return args[i + 1] }
        if args[i].hasPrefix(name + "=") { return String(args[i].dropFirst(name.count + 1)) }
        i += 1
    }
    return nil
}

private func cfgFlag(_ args: [String], _ name: String) -> Bool {
    args.contains(name)
}

private func cfgFirstPositional(_ args: [String]) -> String? {
    var i = 0
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            // Skip a value-taking flag's value unless it's `--flag=value` form.
            if !a.contains("="), i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                i += 2; continue
            }
            i += 1; continue
        }
        return a
    }
    return nil
}

private func cfgEnv(_ args: [String]) throws -> [String: String]? {
    var out: [String: String] = [:]
    var i = 0
    while i < args.count {
        if args[i] == "--env", i + 1 < args.count {
            let entry = args[i + 1]
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else {
                throw CLIError(message: "config: --env expects KEY=VALUE (got: \(entry))")
            }
            out[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            i += 2
        } else {
            i += 1
        }
    }
    return out.isEmpty ? nil : out
}

private func cfgResolvePath(_ path: String) -> String {
    if path.hasPrefix("~") {
        return (path as NSString).expandingTildeInPath
    }
    if path.hasPrefix("/") { return path }
    return FileManager.default.currentDirectoryPath + "/" + path
}

/// Build `ConfigFields` from subArgs, honoring `--system-prompt-file` and the
/// clear-to-inherit empty-string convention (present-but-empty vs absent).
private func cfgFields(_ args: [String]) throws -> ConfigFields {
    var sysText = cfgOption(args, "--system-prompt")
    if let file = cfgOption(args, "--system-prompt-file") {
        if sysText != nil {
            throw CLIError(message: "config: --system-prompt and --system-prompt-file are mutually exclusive")
        }
        guard let contents = try? String(contentsOfFile: cfgResolvePath(file), encoding: .utf8) else {
            throw CLIError(message: "config: failed to read --system-prompt-file: \(file)")
        }
        sysText = contents
    }
    return ConfigFields(
        harness: cfgOption(args, "--harness"),
        model: cfgOption(args, "--model"),
        effort: cfgOption(args, "--effort"),
        systemPromptMode: cfgOption(args, "--system-prompt-mode"),
        systemPromptText: sysText,
        command: cfgOption(args, "--command"),
        initialPrompt: cfgOption(args, "--initial-prompt"),
        env: try cfgEnv(args)
    )
}

private func cfgPrint(json: Bool, object: @autoclosure () -> [String: Any], human: @autoclosure () -> String) {
    if json {
        let obj = object()
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
            return
        }
        print("{}")
    } else {
        print(human())
    }
}

private func cfgCLIError(_ e: ConfigCoreError) -> CLIError {
    CLIError(message: "\(e.message) [\(e.code)]")
}

// MARK: - App-down subcommands (list/recent/stats/save/edit/rm/reorder/default)

func runConfigCommand(commandArgs: [String], jsonOutput: Bool) throws {
    guard let sub = commandArgs.first?.lowercased() else {
        throw CLIError(message: "config: missing subcommand. Known: list, recent, stats, save, edit, rm, reorder, default, launch")
    }
    let args = Array(commandArgs.dropFirst())
    let json = jsonOutput || cfgFlag(args, "--json")
    let core = ConfigCommandCore()

    do {
        switch sub {
        case "list":
            let r = core.list()
            cfgPrint(json: json, object: r.jsonObject(), human: r.humanText())

        case "recent":
            let r = core.recent()
            cfgPrint(json: json, object: r.jsonObject(), human: r.humanText())

        case "stats":
            let window = try ConfigCommandCore.parseWindow(cfgOption(args, "--window"))
            let axis = try ConfigCommandCore.parseAxis(cfgOption(args, "--by"))
            let r = core.statsView(window: window, by: axis)
            cfgPrint(json: json, object: r.jsonObject(), human: r.humanText())

        case "save":
            guard let name = cfgFirstPositional(args) else {
                throw CLIError(message: "config save requires a <name> (e.g. c11 config save \"Opus deep\" --harness claude-code --model opus)")
            }
            let saved = try core.save(name: name, fields: try cfgFields(args))
            cfgPrint(json: json, object: (try? ConfigJSON.object(from: saved)) ?? [:],
                     human: "saved config '\(saved.name)' (\(saved.id))")

        case "edit":
            guard let ref = cfgFirstPositional(args) else {
                throw CLIError(message: "config edit requires a <name|id>")
            }
            let saved = try core.edit(nameOrId: ref, fields: try cfgFields(args))
            cfgPrint(json: json, object: (try? ConfigJSON.object(from: saved)) ?? [:],
                     human: "edited config '\(saved.name)' (\(saved.id))")

        case "rm":
            guard let ref = cfgFirstPositional(args) else {
                throw CLIError(message: "config rm requires a <name|id>")
            }
            let removed = try core.remove(nameOrId: ref)
            cfgPrint(json: json, object: ["removed": (try? ConfigJSON.object(from: removed)) ?? [:]],
                     human: "removed config '\(removed.name)' (\(removed.id))")

        case "reorder":
            guard let ref = cfgFirstPositional(args) else {
                throw CLIError(message: "config reorder requires a <name|id>")
            }
            guard let toRaw = cfgOption(args, "--to"), let to = Int(toRaw) else {
                throw CLIError(message: "config reorder requires --to <index>")
            }
            let moved = try core.reorder(nameOrId: ref, to: to)
            cfgPrint(json: json, object: (try? ConfigJSON.object(from: moved)) ?? [:],
                     human: "reordered config '\(moved.name)' to index \(to)")

        case "default":
            if cfgFlag(args, "--pin-current") {
                // Deviation (§6 extended): optional name overrides the auto label.
                let saved = try core.pinCurrent(name: cfgFirstPositional(args))
                cfgPrint(json: json, object: ["pinned": (try? ConfigJSON.object(from: saved)) ?? [:]],
                         human: "pinned current as '\(saved.name)' (\(saved.id))")
            } else if let ref = cfgFirstPositional(args) {
                let saved = try core.setDefault(nameOrId: ref)
                cfgPrint(json: json, object: ["pinned": (try? ConfigJSON.object(from: saved)) ?? [:]],
                         human: "default pinned to '\(saved.name)' (\(saved.id))")
            } else {
                throw CLIError(message: "config default requires <name|id> or --pin-current")
            }

        case "launch":
            throw CLIError(message: "internal: `config launch` is socket-bound and handled after connect")

        default:
            throw CLIError(message: "config: unknown subcommand '\(sub)'. Known: list, recent, stats, save, edit, rm, reorder, default, launch")
        }
    } catch let e as ConfigCoreError {
        throw cfgCLIError(e)
    }
}

// MARK: - config launch (socket-bound; builds params for the config.launch method)

/// Parse `config launch` subArgs into the socket param dict. Placement/prompt
/// validation reuses `ConfigCommandCore.parseLaunchInputs` so the CLI and socket
/// surfaces share one rulebook. Returns the params for the `config.launch`
/// method plus whether JSON output was requested.
func buildConfigLaunchParams(subArgs: [String]) throws -> (params: [String: Any], json: Bool) {
    guard let ref = cfgFirstPositional(subArgs) else {
        throw CLIError(message: "config launch requires a <name|id>")
    }
    let promptInline = cfgOption(subArgs, "--prompt")
    let promptFile = cfgOption(subArgs, "--prompt-file")
    var promptFileContents: String?
    if let promptFile {
        guard let contents = try? String(contentsOfFile: cfgResolvePath(promptFile), encoding: .utf8),
              !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: "config launch: failed to read --prompt-file: \(promptFile)")
        }
        promptFileContents = contents
    }
    let inputs: ConfigLaunchInputs
    do {
        inputs = try ConfigCommandCore.parseLaunchInputs(
            nameOrId: ref,
            pane: cfgOption(subArgs, "--pane"),
            workspace: cfgOption(subArgs, "--workspace"),
            newWorkspace: cfgFlag(subArgs, "--new-workspace"),
            cwd: cfgOption(subArgs, "--cwd").map(cfgResolvePath),
            prompt: promptInline,
            promptFile: promptFile,
            promptFileContents: promptFileContents,
            json: cfgFlag(subArgs, "--json")
        )
    } catch let e as ConfigCoreError {
        throw cfgCLIError(e)
    }
    var params: [String: Any] = ["config": inputs.nameOrId]
    switch inputs.placement {
    case .newWorkspace: params["new_workspace"] = true
    case .pane(let p): params["pane"] = p
    case .workspace(let w): params["workspace"] = w
    case .defaultPlacement: break
    }
    if let cwd = inputs.cwd { params["cwd"] = cwd }
    if let prompt = inputs.prompt { params["prompt"] = prompt }
    return (params, inputs.json)
}
