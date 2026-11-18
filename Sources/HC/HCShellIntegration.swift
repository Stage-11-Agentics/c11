import Foundation

/// A port of Ghostty's automatic shell-integration setup
/// (`src/termio/shell_integration.zig`, applied by `termio/Exec.zig`) for the
/// hc launch path. The native exec path calls it before it launches the shell;
/// an hc terminal is launched by the core from an argv and an environment, so
/// the same transformations must be applied here or fish, elvish, nushell and
/// (with c11's sidebar integration off) zsh/bash lose cwd tracking and prompt
/// marks. Pure: file checks are injected so every shell mode is testable.
enum HCShellIntegration {
    typealias Command = HCNativeLaunchSnapshot.Command

    enum Shell: Equatable { case bash, elvish, fish, nushell, zsh }

    struct Result: Equatable {
        /// The command to launch: the integrated one, or the original.
        let command: Command
        let environment: [String: String]
        /// Nil when no automatic integration was injected.
        let shell: Shell?
    }

    struct Probe {
        var isDirectory: (String) -> Bool
        var isReadableFile: (String) -> Bool
        var homeDirectory: () -> String?

        static let live = Probe(
            isDirectory: { var isDir: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue },
            isReadableFile: { FileManager.default.isReadableFile(atPath: $0) },
            homeDirectory: { NSHomeDirectory() })
    }

    /// `mode` is the `shell-integration` config value (none, detect, bash,
    /// elvish, fish, nushell, zsh). A failed setup leaves the command as given
    /// and, exactly as the native code does, may keep partial environment
    /// changes made before the failure.
    static func apply(command: Command?, environment: [String: String], mode: String,
                      resourcesDir: String?, probe: Probe = .live) -> Result {
        let original = command ?? .shell("sh")
        guard mode != "none", let resourcesDir, !resourcesDir.isEmpty else {
            return Result(command: original, environment: environment, shell: nil)
        }
        let forced: Shell?
        switch mode {
        case "bash": forced = .bash
        case "elvish": forced = .elvish
        case "fish": forced = .fish
        case "nushell": forced = .nushell
        case "zsh": forced = .zsh
        default: forced = nil
        }
        guard let shell = forced ?? detect(original) else {
            return Result(command: original, environment: environment, shell: nil)
        }
        var env = environment
        let integrated: Command?
        switch shell {
        case .bash: integrated = bash(original, resourcesDir, &env, probe)
        case .nushell: integrated = nushell(original, resourcesDir, &env, probe)
        case .zsh: integrated = zsh(original, resourcesDir, &env, probe)
        case .elvish, .fish: integrated = xdgDataDirs(resourcesDir, &env, probe) ? original : nil
        }
        guard let integrated else { return Result(command: original, environment: env, shell: nil) }
        return Result(command: integrated, environment: env, shell: shell)
    }

    /// The command and environment an hc terminal is launched with, assembled in
    /// the order Ghostty's native exec path uses: the process-derived `base`,
    /// shell integration (which may rewrite the command), then the explicit
    /// overrides. The overrides are the global config `env` entries with the
    /// panel's own launch environment laid over them, so a saved recipe's value
    /// beats a global one and a wrapper variable the panel set (ZDOTDIR) beats
    /// both integration and config. hc identity variables are added last.
    static func launchTuple(command: Command?, base: [String: String], globalOverrides: [String: String],
                            panel: [String: String], mode: String,
                            configuration: HCLaunchConfiguration?,
                            probe: Probe = .live) -> (command: Command?, environment: [String: String]) {
        var launchCommand = command
        var environment = base
        if let command {
            let integration = apply(command: command, environment: base, mode: mode,
                                    resourcesDir: base["GHOSTTY_RESOURCES_DIR"], probe: probe)
            launchCommand = integration.command
            environment = integration.environment
        }
        let overrides = globalOverrides.merging(panel) { _, panelValue in panelValue }
        return (launchCommand, HCLaunchPolicy.terminalEnvironment(managed: environment, configured: overrides,
                                                                  intendedXDG: [:], configuration: configuration))
    }

    // MARK: detection

    static func detect(_ command: Command) -> Shell? {
        guard let arg0 = arguments(command).first else { return nil }
        let exe = (arg0 as NSString).lastPathComponent
        if exe == "bash" {
            // Apple's patched /bin/bash 3.2 disables the ENV-based startup path.
            return arg0 == "/bin/bash" ? nil : .bash
        }
        switch exe {
        case "elvish": return .elvish
        case "fish": return .fish
        case "nu": return .nushell
        case "zsh": return .zsh
        default: return nil
        }
    }

    /// Zig's `ArgIteratorGeneral` with default options: whitespace separates,
    /// double quotes group, backslashes before a quote follow the CRT rules and
    /// single quotes are ordinary characters.
    static func arguments(_ command: Command) -> [String] {
        switch command {
        case .direct(let args): return args
        case .shell(let line): return splitShellLine(line)
        }
    }

    static func splitShellLine(_ line: String) -> [String] {
        let chars = Array(line)
        var result: [String] = []
        var index = 0
        func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" }
        while true {
            while index < chars.count, isSpace(chars[index]) { index += 1 }
            if index >= chars.count { break }
            var arg = ""
            var inQuote = false
            while index < chars.count {
                var slashes = 0
                while index < chars.count, chars[index] == "\\" { slashes += 1; index += 1 }
                if index < chars.count, chars[index] == "\"" {
                    arg += String(repeating: "\\", count: slashes / 2)
                    if slashes % 2 == 1 { arg += "\""; index += 1; continue }
                    index += 1
                    if inQuote, index < chars.count, chars[index] == "\"" { arg += "\""; index += 1; continue }
                    inQuote.toggle()
                    continue
                }
                arg += String(repeating: "\\", count: slashes)
                guard index < chars.count else { break }
                if !inQuote, isSpace(chars[index]) { break }
                arg.append(chars[index]); index += 1
            }
            result.append(arg)
        }
        return result
    }

    // MARK: shells

    private static func join(_ args: [String]) -> Command {
        // ShellCommandBuilder: space-separated, empty arguments skipped.
        .shell(args.filter { !$0.isEmpty }.joined(separator: " "))
    }

    private static func bash(_ command: Command, _ resourcesDir: String,
                             _ env: inout [String: String], _ probe: Probe) -> Command? {
        var iterator = arguments(command).makeIterator()
        guard let exe = iterator.next() else { return nil }
        var out = [exe, "--posix"]
        var inject = "1"
        var rcfile: String?
        while let arg = iterator.next() {
            if arg == "--posix" {
                return nil
            } else if arg == "--norc" {
                inject += " --norc"
            } else if arg == "--noprofile" {
                inject += " --noprofile"
            } else if arg == "--rcfile" || arg == "--init-file" {
                rcfile = iterator.next()
            } else if arg.count > 1, arg.hasPrefix("-"), !arg.hasPrefix("--") {
                if arg.contains("c") { return nil }
                out.append(arg)
            } else if arg == "-" || arg == "--" {
                out.append(arg)
                while let rest = iterator.next() { out.append(rest) }
                break
            } else {
                out.append(arg)
            }
        }
        let script = resourcesDir + "/shell-integration/bash/ghostty.bash"
        guard probe.isReadableFile(script) else { return nil }
        if let previous = env["ENV"] { env["GHOSTTY_BASH_ENV"] = previous }
        env["ENV"] = script
        env["GHOSTTY_BASH_INJECT"] = inject
        if let rcfile { env["GHOSTTY_BASH_RCFILE"] = rcfile }
        // POSIX mode defaults HISTFILE to ~/.sh_history; restore bash's own.
        if env["HISTFILE"] == nil, let home = probe.homeDirectory() {
            env["HISTFILE"] = home + "/.bash_history"
            env["GHOSTTY_BASH_UNEXPORT_HISTFILE"] = "1"
        }
        return join(out)
    }

    private static func nushell(_ command: Command, _ resourcesDir: String,
                                _ env: inout [String: String], _ probe: Probe) -> Command? {
        // The autoload directory is added even when a later check aborts.
        guard xdgDataDirs(resourcesDir, &env, probe) else { return nil }
        var iterator = arguments(command).makeIterator()
        guard let exe = iterator.next() else { return nil }
        var out = [exe, "--execute 'use ghostty *'"]
        while let arg = iterator.next() {
            if arg == "--command" || arg == "--lsp" {
                return nil
            } else if arg.count > 1, arg.hasPrefix("-"), !arg.hasPrefix("--") {
                if arg.contains("c") { return nil }
                out.append(arg)
            } else if arg == "-" || arg == "--" {
                out.append(arg)
                while let rest = iterator.next() { out.append(rest) }
                break
            } else {
                out.append(arg)
            }
        }
        return join(out)
    }

    private static func zsh(_ command: Command, _ resourcesDir: String,
                            _ env: inout [String: String], _ probe: Probe) -> Command? {
        if let previous = env["ZDOTDIR"] { env["GHOSTTY_ZSH_ZDOTDIR"] = previous }
        let directory = resourcesDir + "/shell-integration/zsh"
        guard probe.isDirectory(directory) else { return nil }
        env["ZDOTDIR"] = directory
        return command
    }

    /// fish and elvish (and nushell's autoload) find integration through
    /// XDG_DATA_DIRS; the shell integration removes our entry again itself.
    private static func xdgDataDirs(_ resourcesDir: String, _ env: inout [String: String],
                                    _ probe: Probe) -> Bool {
        let directory = resourcesDir + "/shell-integration"
        guard probe.isDirectory(directory) else { return false }
        env["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = directory
        let current = env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
        env["XDG_DATA_DIRS"] = current.isEmpty ? directory : directory + ":" + current
        return true
    }
}
