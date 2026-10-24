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

    struct SSHCommandOptions {
        let destination: String
        let port: Int?
        let identityFile: String?
        let workspaceName: String?
        let sshOptions: [String]
        let extraArguments: [String]
        let localSocketPath: String
        let remoteRelayPort: Int
    }

    struct RemoteDaemonManifest: Decodable {
        struct Entry: Decodable {
            let goOS: String
            let goArch: String
            let assetName: String
            let downloadURL: String
            let sha256: String
        }

        let schemaVersion: Int
        let appVersion: String
        let releaseTag: String
        let releaseURL: String
        let checksumsAssetName: String
        let checksumsURL: String
        let entries: [Entry]

        func entry(goOS: String, goArch: String) -> Entry? {
            entries.first { $0.goOS == goOS && $0.goArch == goArch }
        }
    }

    func generateSSHSessionID() -> Int {
        // Retain the numeric lifecycle identifier expected by ssh-session-end.
        // This value no longer represents a listening port.
        Int.random(in: 49152...65535)
    }

    func runSSH(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let sshStartedAt = Date()
        // Use the socket path from this invocation (supports --socket overrides).
        let localSocketPath = client.socketPath
        let remoteRelayPort = generateSSHSessionID()
        let sshOptions = try parseSSHCommandOptions(commandArgs, localSocketPath: localSocketPath, remoteRelayPort: remoteRelayPort)
        func logSSHTiming(_ stage: String, extra: String = "") {
            let elapsedMs = Int(Date().timeIntervalSince(sshStartedAt) * 1000)
            let suffix = extra.isEmpty ? "" : " \(extra)"
            cliDebugLog(
                "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
                "stage=\(stage) elapsedMs=\(elapsedMs)\(suffix)"
            )
        }

        logSSHTiming("parsed")
        let terminfoSource = localXtermGhosttyTerminfoSource()
        cliDebugLog(
            "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
            "stage=terminfo elapsedMs=0 mode=deferred term=xterm-256color " +
            "source=\(terminfoSource == nil ? 0 : 1)"
        )
        let shellFeaturesValue = scopedGhosttyShellFeaturesValue()
        let remoteTerminalBootstrapScript = sshOptions.extraArguments.isEmpty
            ? buildInteractiveRemoteShellScript(
                remoteRelayPort: sshOptions.remoteRelayPort,
                shellFeatures: shellFeaturesValue,
                terminfoSource: terminfoSource
            )
            : nil
        let remoteTerminalSSHCommand = buildSSHCommandText(
            sshOptions,
            remoteBootstrapScript: remoteTerminalBootstrapScript
        )
        let initialSSHCommand = remoteTerminalSSHCommand
        let initialSSHStartupCommand = try buildSSHStartupCommand(
            sshCommand: initialSSHCommand,
            shellFeatures: "",
            remoteRelayPort: sshOptions.remoteRelayPort
        )
        let remoteTerminalSSHStartupCommand = try buildSSHStartupCommand(
            sshCommand: remoteTerminalSSHCommand,
            shellFeatures: shellFeaturesValue,
            remoteRelayPort: sshOptions.remoteRelayPort
        )
        let remoteSSHOptions = effectiveSSHOptions(
            sshOptions.sshOptions,
            remoteRelayPort: sshOptions.remoteRelayPort
        )

        cliDebugLog(
            "cli.ssh.start target=\(sshOptions.destination) port=\(sshOptions.port.map(String.init) ?? "nil") " +
            "relayPort=\(sshOptions.remoteRelayPort) localSocket=\(sshOptions.localSocketPath) " +
            "controlPath=\(sshOptionValue(named: "ControlPath", in: remoteSSHOptions) ?? "nil") " +
            "workspaceName=\(sshOptions.workspaceName?.replacingOccurrences(of: " ", with: "_") ?? "nil") " +
            "extraArgs=\(sshOptions.extraArguments.count)"
        )

        var workspaceCreateParams: [String: Any] = [
            "initial_command": initialSSHStartupCommand,
        ]
        try addCallingPanel(to: &workspaceCreateParams)

        let workspaceCreateStartedAt = Date()
        let workspaceCreate = try client.sendV2(method: "workspace.create", params: workspaceCreateParams)
        guard let workspaceId = workspaceCreate["workspace_id"] as? String, !workspaceId.isEmpty else {
            throw CLIError(message: "workspace.create did not return workspace_id")
        }
        let workspaceWindowId = (workspaceCreate["window_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cliDebugLog(
            "cli.ssh.workspace.created workspace=\(String(workspaceId.prefix(8))) " +
            "window=\(workspaceWindowId.map { String($0.prefix(8)) } ?? "nil")"
        )
        cliDebugLog(
            "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
            "workspace=\(String(workspaceId.prefix(8))) stage=workspace.create elapsedMs=\(Int(Date().timeIntervalSince(workspaceCreateStartedAt) * 1000))"
        )
        let configuredPayload: [String: Any]
        do {
            if let workspaceName = sshOptions.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceName.isEmpty {
                _ = try client.sendV2(method: "workspace.rename", params: [
                    "workspace_id": workspaceId,
                    "title": workspaceName,
                ])
            }

            var configureParams: [String: Any] = [
                "workspace_id": workspaceId,
                "destination": sshOptions.destination,
                "auto_connect": true,
            ]
            if let port = sshOptions.port {
                configureParams["port"] = port
            }
            if let identityFile = normalizedSSHIdentityPath(sshOptions.identityFile) {
                configureParams["identity_file"] = identityFile
            }
            if !remoteSSHOptions.isEmpty {
                configureParams["ssh_options"] = remoteSSHOptions
            }
            if sshOptions.remoteRelayPort > 0 {
                // Legacy wire key used only to match local SSH session-end notifications.
                configureParams["relay_port"] = sshOptions.remoteRelayPort
            }
            configureParams["terminal_startup_command"] = remoteTerminalSSHStartupCommand

            cliDebugLog(
                "cli.ssh.remote.configure workspace=\(String(workspaceId.prefix(8))) " +
                "target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
                "controlPath=\(sshOptionValue(named: "ControlPath", in: remoteSSHOptions) ?? "nil") " +
                "sshOptions=\(remoteSSHOptions.joined(separator: "|"))"
            )
            let configureStartedAt = Date()
            // deadline: .none — SSH handshake and remote setup can exceed 10 s on slow
            // VPNs or distant hosts; the server governs the timeout for this operation.
            configuredPayload = try client.sendV2(method: "workspace.remote.configure", params: configureParams, deadline: .none)
            let remoteState = ((configuredPayload["remote"] as? [String: Any])?["state"] as? String) ?? "unknown"
            cliDebugLog(
                "cli.ssh.remote.configure.ok workspace=\(String(workspaceId.prefix(8))) state=\(remoteState)"
            )
            cliDebugLog(
                "cli.ssh.timing target=\(sshOptions.destination) relayPort=\(sshOptions.remoteRelayPort) " +
                "workspace=\(String(workspaceId.prefix(8))) stage=workspace.remote.configure elapsedMs=\(Int(Date().timeIntervalSince(configureStartedAt) * 1000))"
            )
        } catch {
            cliDebugLog(
                "cli.ssh.remote.configure.error workspace=\(String(workspaceId.prefix(8))) error=\(String(describing: error))"
            )
            do {
                _ = try client.sendV2(method: "workspace.close", params: ["workspace_id": workspaceId])
            } catch {
                let warning = "Warning: failed to rollback workspace \(workspaceId): \(error)\n"
                FileHandle.standardError.c11SafeWrite(Data(warning.utf8))
            }
            throw error
        }

        var payload = configuredPayload

        payload["ssh_command"] = initialSSHCommand
        payload["ssh_startup_command"] = initialSSHStartupCommand
        payload["ssh_terminal_command"] = remoteTerminalSSHCommand
        payload["ssh_terminal_startup_command"] = remoteTerminalSSHStartupCommand
        payload["ssh_env_overrides"] = [
            "GHOSTTY_SHELL_FEATURES": shellFeaturesValue,
        ]
        payload["ssh_session_id"] = remoteRelayPort
        logSSHTiming("complete", extra: "workspace=\(String(workspaceId.prefix(8)))")
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? workspaceId
            let remote = payload["remote"] as? [String: Any]
            let state = (remote?["state"] as? String) ?? "unknown"
            print("OK workspace=\(workspaceHandle) target=\(sshOptions.destination) state=\(state)")
        }
    }

    func parseSSHCommandOptions(_ commandArgs: [String], localSocketPath: String = "", remoteRelayPort: Int = 0) throws -> SSHCommandOptions {
        var destination: String?
        var port: Int?
        var identityFile: String?
        var workspaceName: String?
        var sshOptions: [String] = []
        var extraArguments: [String] = []

        var passthrough = false
        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if passthrough {
                extraArguments.append(arg)
                index += 1
                continue
            }

            switch arg {
            case "--":
                passthrough = true
                index += 1
            case "--port":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --port requires a value")
                }
                guard let parsed = Int(commandArgs[index + 1]), parsed > 0, parsed <= 65535 else {
                    throw CLIError(message: "ssh: --port must be 1-65535")
                }
                port = parsed
                index += 2
            case "--identity":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --identity requires a path")
                }
                identityFile = commandArgs[index + 1]
                index += 2
            case "--name":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --name requires a workspace title")
                }
                workspaceName = commandArgs[index + 1]
                index += 2
            case "--ssh-option":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --ssh-option requires a value")
                }
                let value = commandArgs[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    sshOptions.append(value)
                }
                index += 2
            default:
                if arg.hasPrefix("--") {
                    throw CLIError(message: "ssh: unknown flag '\(arg)'")
                }
                if destination == nil {
                    if arg.hasPrefix("-") {
                        throw CLIError(
                            message: "ssh: destination must be <user@host>. Use --port/--identity/--ssh-option for SSH flags and `--` for remote command args."
                        )
                    }
                    destination = arg
                } else {
                    extraArguments.append(arg)
                }
                index += 1
            }
        }

        guard let destination else {
            throw CLIError(message: "ssh requires a destination (example: c11 ssh user@host)")
        }
        return SSHCommandOptions(
            destination: destination,
            port: port,
            identityFile: identityFile,
            workspaceName: workspaceName,
            sshOptions: sshOptions,
            extraArguments: extraArguments,
            localSocketPath: localSocketPath,
            remoteRelayPort: remoteRelayPort
        )
    }

    func buildSSHCommandText(
        _ options: SSHCommandOptions,
        remoteBootstrapScript: String? = nil
    ) -> String {
        var parts = baseSSHArguments(options)
        let trimmedRemoteBootstrap = remoteBootstrapScript?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if options.extraArguments.isEmpty {
            if let trimmedRemoteBootstrap, !trimmedRemoteBootstrap.isEmpty {
                let remoteCommand = sshPercentEscapedRemoteCommand(
                    encodedRemoteBootstrapCommand(trimmedRemoteBootstrap)
                )
                parts += ["-o", "RemoteCommand=\(remoteCommand)"]
            }
            if !hasSSHOptionKey(options.sshOptions, key: "RequestTTY") {
                parts.append("-tt")
            }
            parts.append(options.destination)
        } else {
            parts.append(options.destination)
            parts.append(contentsOf: options.extraArguments)
        }
        return parts.map(shellQuote).joined(separator: " ")
    }

    func effectiveSSHOptions(_ options: [String], remoteRelayPort: Int? = nil) -> [String] {
        var merged = sshOptionsWithControlSocketDefaults(options, remoteRelayPort: remoteRelayPort)
        if !hasSSHOptionKey(merged, key: "StrictHostKeyChecking") {
            merged.append("StrictHostKeyChecking=accept-new")
        }
        return merged
    }

    func buildInteractiveRemoteShellScript(
        remoteRelayPort: Int,
        shellFeatures: String,
        terminfoSource: String? = nil
    ) -> String {
        let remoteTerminalLines = interactiveRemoteTerminalSetupLines(terminfoSource: terminfoSource)
        let remoteEnvExportLines = interactiveRemoteShellExportLines(shellFeatures: shellFeatures)
        let shellStateDir = "$HOME/.cmux/ssh/\(max(remoteRelayPort, 0)).shell"
        let unavailableMessage = "c11 commands are not available over c11 ssh in this version"
        let socketVariables = "C11_SOCKET C11_SOCKET_PATH CMUX_SOCKET CMUX_SOCKET_PATH CMUX_SOCKET_PASSWORD CMUX_RELAY_TOKEN"
        let commonShellLines = remoteTerminalLines
            + remoteEnvExportLines
            + [
                "unset \(socketVariables)",
                "export PATH=\"\(shellStateDir)/bin:$PATH\"",
                "unalias c11 cmux >/dev/null 2>&1 || true",
                "c11() { printf '%s\\n' \(shellQuote(unavailableMessage)) >&2; return 1; }",
                "cmux() { c11 \"$@\"; }",
            ]
            + [
                "hash -r >/dev/null 2>&1 || true",
                "rehash >/dev/null 2>&1 || true",
            ]
        let zshEnvLines = [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zshenv\" ] && source \"$CMUX_REAL_ZDOTDIR/.zshenv\"",
            "if [ -n \"${ZDOTDIR:-}\" ] && [ \"$ZDOTDIR\" != \"\(shellStateDir)\" ]; then export CMUX_REAL_ZDOTDIR=\"$ZDOTDIR\"; fi",
            "export ZDOTDIR=\"\(shellStateDir)\"",
        ]
        let zshProfileLines = [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zprofile\" ] && source \"$CMUX_REAL_ZDOTDIR/.zprofile\"",
        ]
        let zshRCLines = [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zshrc\" ] && source \"$CMUX_REAL_ZDOTDIR/.zshrc\"",
        ] + commonShellLines
        let zshLoginLines = [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zlogin\" ] && source \"$CMUX_REAL_ZDOTDIR/.zlogin\"",
        ] + commonShellLines
        let bashRCLines = [
            "if [ -f \"$HOME/.bash_profile\" ]; then . \"$HOME/.bash_profile\"; elif [ -f \"$HOME/.bash_login\" ]; then . \"$HOME/.bash_login\"; elif [ -f \"$HOME/.profile\" ]; then . \"$HOME/.profile\"; fi",
            "[ -f \"$HOME/.bashrc\" ] && . \"$HOME/.bashrc\"",
        ] + commonShellLines
        let fishSetup = [
            "set -e \(socketVariables.replacingOccurrences(of: " ", with: "; set -e "))",
            "set -gx PATH \"\(shellStateDir)/bin\" $PATH",
            "function c11; printf '%s\\n' \(shellQuote(unavailableMessage)) >&2; return 1; end",
            "function cmux; c11 $argv; end",
        ].joined(separator: "; ")

        var outerLines: [String] = [
            "cmux_original_umask=$(umask)",
            "umask 077",
            "cmux_shell_dir=\"\(shellStateDir)\"",
            "mkdir -p \"$cmux_shell_dir/bin\" || exit 1",
            "cat > \"$cmux_shell_dir/bin/c11\" <<'CMUXDISABLED'",
            "#!/bin/sh",
            "printf '%s\\n' \(shellQuote(unavailableMessage)) >&2",
            "exit 1",
            "CMUXDISABLED",
            "chmod 700 \"$cmux_shell_dir/bin/c11\" || exit 1",
            "cp \"$cmux_shell_dir/bin/c11\" \"$cmux_shell_dir/bin/cmux\" || exit 1",
            "CMUX_LOGIN_SHELL=\"${SHELL:-/bin/zsh}\"",
            "case \"${CMUX_LOGIN_SHELL##*/}\" in",
            "  zsh)",
            "    cmux_shell_dir=\"\(shellStateDir)\"",
            "    mkdir -p \"$cmux_shell_dir\"",
            "    cat > \"$cmux_shell_dir/.zshenv\" <<'CMUXZSHENV'",
        ]
        outerLines.append(contentsOf: zshEnvLines)
        outerLines += [
            "CMUXZSHENV",
            "    cat > \"$cmux_shell_dir/.zprofile\" <<'CMUXZSHPROFILE'",
        ]
        outerLines.append(contentsOf: zshProfileLines)
        outerLines += [
            "CMUXZSHPROFILE",
            "    cat > \"$cmux_shell_dir/.zshrc\" <<'CMUXZSHRC'",
        ]
        outerLines.append(contentsOf: zshRCLines)
        outerLines += [
            "CMUXZSHRC",
            "    cat > \"$cmux_shell_dir/.zlogin\" <<'CMUXZSHLOGIN'",
        ]
        outerLines.append(contentsOf: zshLoginLines)
        outerLines += [
            "CMUXZSHLOGIN",
            "    chmod 600 \"$cmux_shell_dir/.zshenv\" \"$cmux_shell_dir/.zprofile\" \"$cmux_shell_dir/.zshrc\" \"$cmux_shell_dir/.zlogin\" >/dev/null 2>&1 || true",
        ]
        outerLines += [
            "    export CMUX_REAL_ZDOTDIR=\"${ZDOTDIR:-$HOME}\"",
            "    export ZDOTDIR=\"$cmux_shell_dir\"",
            "    umask \"$cmux_original_umask\"",
            "    exec \"$CMUX_LOGIN_SHELL\" -il",
            "    ;;",
            "  bash)",
            "    cmux_shell_dir=\"\(shellStateDir)\"",
            "    mkdir -p \"$cmux_shell_dir\"",
            "    cat > \"$cmux_shell_dir/.bashrc\" <<'CMUXBASHRC'",
        ]
        outerLines.append(contentsOf: bashRCLines)
        outerLines += [
            "CMUXBASHRC",
            "    chmod 600 \"$cmux_shell_dir/.bashrc\" >/dev/null 2>&1 || true",
        ]
        outerLines += [
            "    umask \"$cmux_original_umask\"",
            "    exec \"$CMUX_LOGIN_SHELL\" --rcfile \"$cmux_shell_dir/.bashrc\" -i",
            "    ;;",
            "  fish)",
        ]
        outerLines.append(contentsOf: remoteTerminalLines + remoteEnvExportLines)
        outerLines += [
            "    unset \(socketVariables)",
            "    umask \"$cmux_original_umask\"",
            "    exec \"$CMUX_LOGIN_SHELL\" -i --init-command \(shellQuote(fishSetup))",
            "    ;;",
            "  *)",
        ]
        outerLines.append(contentsOf: commonShellLines)
        outerLines += [
            "umask \"$cmux_original_umask\"",
            "exec \"$CMUX_LOGIN_SHELL\" -i",
            ";;",
            "esac",
        ]

        return outerLines.joined(separator: "\n")
    }

    func buildInteractiveRemoteShellCommand(
        remoteRelayPort: Int,
        shellFeatures: String,
        terminfoSource: String? = nil
    ) -> String {
        let script = buildInteractiveRemoteShellScript(
            remoteRelayPort: remoteRelayPort,
            shellFeatures: shellFeatures,
            terminfoSource: terminfoSource
        )
        return "/bin/sh -c \(shellQuote(script))"
    }

    func interactiveRemoteTerminalSetupLines(terminfoSource: String?) -> [String] {
        var lines: [String] = [
            "cmux_term='xterm-256color'",
            "if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then",
            "  cmux_term='xterm-ghostty'",
            "fi",
            "export TERM=\"$cmux_term\"",
        ]
        guard let terminfoSource else { return lines }
        let trimmedTerminfoSource = terminfoSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerminfoSource.isEmpty else { return lines }
        lines += [
            "if [ \"$cmux_term\" != 'xterm-ghostty' ]; then",
            "  (",
            "    command -v tic >/dev/null 2>&1 || exit 0",
            "    mkdir -p \"$HOME/.terminfo\" 2>/dev/null || exit 0",
            "    cat <<'CMUXTERMINFO' | tic -x - >/dev/null 2>&1",
            trimmedTerminfoSource,
            "CMUXTERMINFO",
            "  ) >/dev/null 2>&1 &",
            "fi",
        ]
        return lines
    }

    func interactiveRemoteShellExportLines(shellFeatures: String) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let colorTerm = Self.normalizedEnvValue(environment["COLORTERM"]) ?? "truecolor"
        let termProgram = Self.normalizedEnvValue(environment["TERM_PROGRAM"]) ?? "ghostty"
        let termProgramVersion = Self.normalizedEnvValue(environment["TERM_PROGRAM_VERSION"])
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? ""
        let trimmedShellFeatures = shellFeatures.trimmingCharacters(in: .whitespacesAndNewlines)

        var exports: [String] = [
            "export COLORTERM=\(shellQuote(colorTerm))",
            "export TERM_PROGRAM=\(shellQuote(termProgram))",
        ]
        if !termProgramVersion.isEmpty {
            exports.append("export TERM_PROGRAM_VERSION=\(shellQuote(termProgramVersion))")
        }
        if !trimmedShellFeatures.isEmpty {
            exports.append("export GHOSTTY_SHELL_FEATURES=\(shellQuote(trimmedShellFeatures))")
        }
        return exports
    }

    func baseSSHArguments(_ options: SSHCommandOptions) -> [String] {
        let effectiveSSHOptions = effectiveSSHOptions(
            options.sshOptions,
            remoteRelayPort: options.remoteRelayPort
        )
        var parts: [String] = ["ssh"]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "SetEnv") {
            parts += ["-o", "SetEnv COLORTERM=truecolor"]
        }
        if !hasSSHOptionKey(effectiveSSHOptions, key: "SendEnv") {
            parts += ["-o", "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION"]
        }
        if let port = options.port {
            parts += ["-p", String(port)]
        }
        if let identityFile = normalizedSSHIdentityPath(options.identityFile) {
            parts += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            parts += ["-o", option]
        }
        return parts
    }

    func localXtermGhosttyTerminfoSource() -> String? {
        let result = runProcess(
            executablePath: "/usr/bin/infocmp",
            arguments: ["-0", "-x", "xterm-ghostty"]
        )
        guard result.status == 0 else { return nil }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    func sshOptionsWithControlSocketDefaults(
        _ options: [String],
        remoteRelayPort: Int? = nil
    ) -> [String] {
        var merged: [String] = []
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            merged.append(trimmed)
        }
        if !hasSSHOptionKey(merged, key: "ControlMaster") {
            merged.append("ControlMaster=auto")
        }
        if !hasSSHOptionKey(merged, key: "ControlPersist") {
            merged.append("ControlPersist=600")
        }
        if !hasSSHOptionKey(merged, key: "ControlPath") {
            merged.append("ControlPath=\(defaultSSHControlPathTemplate(remoteRelayPort: remoteRelayPort))")
        }
        return merged
    }

    func scopedGhosttyShellFeaturesValue() -> String {
        let rawExisting = ProcessInfo.processInfo.environment["GHOSTTY_SHELL_FEATURES"] ?? ""
        var seen: Set<String> = []
        var merged: [String] = []

        for token in rawExisting.split(separator: ",") {
            let feature = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !feature.isEmpty else { continue }
            if seen.insert(feature).inserted {
                merged.append(feature)
            }
        }

        for required in ["ssh-env", "ssh-terminfo"] {
            if seen.insert(required).inserted {
                merged.append(required)
            }
        }

        return merged.joined(separator: ",")
    }

    func encodedRemoteBootstrapCommand(_ remoteBootstrapScript: String) -> String {
        let encodedScript = Data(remoteBootstrapScript.utf8).base64EncodedString()
        let encodedLiteral = shellQuote(encodedScript)
        let command = [
            "cmux_tmp=$(mktemp \"${TMPDIR:-/tmp}/cmux-ssh-bootstrap.XXXXXX\") || exit 1",
            "(printf %s \(encodedLiteral) | base64 -d 2>/dev/null || printf %s \(encodedLiteral) | base64 -D 2>/dev/null) > \"$cmux_tmp\" || { rm -f \"$cmux_tmp\"; exit 1; }",
            "chmod 700 \"$cmux_tmp\" >/dev/null 2>&1 || true",
            "/bin/sh \"$cmux_tmp\"",
            "cmux_status=$?",
            "rm -f \"$cmux_tmp\"",
            "exit $cmux_status",
        ].joined(separator: "; ")
        return "/bin/sh -c \(shellQuote(command))"
    }

    func sshPercentEscapedRemoteCommand(_ remoteCommand: String) -> String {
        remoteCommand.replacingOccurrences(of: "%", with: "%%")
    }

    func buildSSHStartupCommand(
        sshCommand: String,
        shellFeatures: String,
        remoteRelayPort: Int
    ) throws -> String {
        let trimmedFeatures = shellFeatures.trimmingCharacters(in: .whitespacesAndNewlines)
        let shellFeaturesBootstrap: String = trimmedFeatures.isEmpty
            ? ""
            : "export GHOSTTY_SHELL_FEATURES=\(shellQuote(trimmedFeatures))"
        let lifecycleCleanup = buildSSHSessionEndShellCommand(remoteRelayPort: remoteRelayPort)
        var scriptLines: [String] = []
        if !shellFeaturesBootstrap.isEmpty {
            scriptLines.append(shellFeaturesBootstrap)
        }
        scriptLines += [
            "CMUX_SSH_SESSION_ENDED=0",
            "cmux_ssh_session_end() { if [ \"${CMUX_SSH_SESSION_ENDED:-0}\" = 1 ]; then return; fi; CMUX_SSH_SESSION_ENDED=1; \(lifecycleCleanup); }",
            "trap 'cmux_ssh_session_end' EXIT HUP INT TERM",
        ]
        scriptLines.append("command \(sshCommand)")
        scriptLines += [
            "cmux_ssh_status=$?",
            "trap - EXIT HUP INT TERM",
            "cmux_ssh_session_end",
            "exit $cmux_ssh_status",
        ]
        let script = scriptLines.joined(separator: "\n")
        return try writeSSHStartupScript(script, remoteRelayPort: remoteRelayPort)
    }

    func writeSSHStartupScript(_ scriptBody: String, remoteRelayPort: Int) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(
            "cmux-ssh-startup-\(remoteRelayPort)-\(UUID().uuidString.lowercased()).sh"
        )
        let script = "#!/bin/sh\n\(scriptBody)\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return shellQuote(scriptURL.path)
    }

    func buildSSHSessionEndShellCommand(remoteRelayPort: Int) -> String {
        [
            "if [ -n \"${CMUX_BUNDLED_CLI_PATH:-}\" ]",
            "&& [ -x \"${CMUX_BUNDLED_CLI_PATH}\" ]",
            "&& [ -n \"${CMUX_SOCKET_PATH:-}\" ]",
            "&& [ -n \"${CMUX_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${CMUX_SURFACE_ID:-}\" ]; then",
            "\"${CMUX_BUNDLED_CLI_PATH}\" --socket \"${CMUX_SOCKET_PATH}\" ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${CMUX_WORKSPACE_ID}\" --surface \"${CMUX_SURFACE_ID}\" >/dev/null 2>&1 || true;",
            "elif command -v c11 >/dev/null 2>&1",
            "&& [ -n \"${CMUX_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${CMUX_SURFACE_ID:-}\" ]; then",
            "c11 ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${CMUX_WORKSPACE_ID}\" --surface \"${CMUX_SURFACE_ID}\" >/dev/null 2>&1 || true;",
            "elif command -v cmux >/dev/null 2>&1",
            "&& [ -n \"${CMUX_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${CMUX_SURFACE_ID:-}\" ]; then",
            "cmux ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${CMUX_WORKSPACE_ID}\" --surface \"${CMUX_SURFACE_ID}\" >/dev/null 2>&1 || true;",
            "fi",
        ].joined(separator: " ")
    }

    func runSSHSessionEnd(commandArgs: [String], client: SocketClient) throws {
        guard let relayPortRaw = optionValue(commandArgs, name: "--relay-port"),
              let relayPort = Int(relayPortRaw),
              relayPort > 0 else {
            throw CLIError(message: "ssh-session-end requires --relay-port <port>")
        }
        let workspaceRaw = optionValue(commandArgs, name: "--workspace") ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let surfaceRaw = optionValue(commandArgs, name: "--panel") ?? Self.callerPanelEnv()
        guard let workspaceRaw,
              let workspaceId = try normalizeWorkspaceHandle(workspaceRaw, client: client),
              !workspaceId.isEmpty else {
            throw CLIError(message: "ssh-session-end requires --workspace or CMUX_WORKSPACE_ID")
        }
        guard let surfaceRaw,
              let surfaceId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceId),
              !surfaceId.isEmpty else {
            throw CLIError(message: "ssh-session-end requires --panel or C11_PANEL_ID")
        }
        _ = try client.sendV2(method: "workspace.remote.terminal_session_end", params: [
            "workspace_id": workspaceId,
            "panel_id": surfaceId,
            "relay_port": relayPort,
        ])
    }

    func runRemoteDaemonStatus(commandArgs: [String], jsonOutput: Bool) throws {
        let requestedOS = optionValue(commandArgs, name: "--os")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedArch = optionValue(commandArgs, name: "--arch")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = resolvedVersionInfo()
        let manifest = remoteDaemonManifest()
        let platform = defaultRemoteDaemonPlatform(requestedOS: requestedOS, requestedArch: requestedArch)
        let cacheURL = remoteDaemonCacheURL(version: manifest?.appVersion ?? remoteDaemonVersionString(from: info), goOS: platform.goOS, goArch: platform.goArch)
        let cacheExists = FileManager.default.fileExists(atPath: cacheURL.path)
        let cacheSHA = cacheExists ? try? sha256Hex(forFile: cacheURL) : nil
        let entry = manifest?.entry(goOS: platform.goOS, goArch: platform.goArch)
        let cacheVerified = (entry != nil && cacheSHA?.lowercased() == entry?.sha256.lowercased())
        let releaseTag = manifest?.releaseTag ?? "unknown"
        let assetName = entry?.assetName ?? "unknown"
        let downloadURL = entry?.downloadURL ?? "unknown"
        let checksumsAssetName = manifest?.checksumsAssetName ?? "unknown"
        let checksumsURL = manifest?.checksumsURL ?? "unknown"
        let downloadCommand = "gh release download \(releaseTag) --repo Stage-11-Agentics/c11 --pattern \(assetName)"
        let downloadChecksumsCommand = "gh release download \(releaseTag) --repo Stage-11-Agentics/c11 --pattern \(checksumsAssetName)"
        let checksumVerifyCommand = "shasum -a 256 -c \(checksumsAssetName) --ignore-missing"
        let signerWorkflow = releaseTag == "nightly"
            ? "Stage-11-Agentics/c11/.github/workflows/nightly.yml"
            : "Stage-11-Agentics/c11/.github/workflows/release.yml"
        let verifyCommand = "gh attestation verify ./\(assetName) --repo Stage-11-Agentics/c11 --signer-workflow \(signerWorkflow)"

        let payload: [String: Any] = [
            "app_version": remoteDaemonVersionString(from: info),
            "build": info["CFBundleVersion"] ?? NSNull(),
            "commit": info["CMUXCommit"] ?? NSNull(),
            "manifest_present": manifest != nil,
            "release_tag": releaseTag,
            "release_url": manifest?.releaseURL ?? NSNull(),
            "target_goos": platform.goOS,
            "target_goarch": platform.goArch,
            "asset_name": assetName,
            "download_url": downloadURL,
            "checksums_asset_name": checksumsAssetName,
            "checksums_url": checksumsURL,
            "expected_sha256": entry?.sha256 ?? NSNull(),
            "cache_path": cacheURL.path,
            "cache_exists": cacheExists,
            "cache_sha256": cacheSHA ?? NSNull(),
            "cache_verified": cacheVerified,
            "dev_local_build_fallback": ProcessInfo.processInfo.environment["CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1",
            "download_command": downloadCommand,
            "download_checksums_command": downloadChecksumsCommand,
            "checksum_verify_command": checksumVerifyCommand,
            "attestation_verify_command": verifyCommand,
        ]

        if jsonOutput {
            print(jsonString(payload))
            return
        }

        print("app version: \(payload["app_version"] as? String ?? "unknown")")
        if let build = payload["build"] as? String {
            print("build: \(build)")
        }
        if let commit = payload["commit"] as? String {
            print("commit: \(commit)")
        }
        print("manifest: \(manifest != nil ? "present" : "missing")")
        print("platform: \(platform.goOS)/\(platform.goArch)")
        print("release: \(releaseTag)")
        print("asset: \(assetName)")
        print("download url: \(downloadURL)")
        print("checksums asset: \(checksumsAssetName)")
        print("checksums: \(checksumsURL)")
        if let expectedSHA = entry?.sha256 {
            print("expected sha256: \(expectedSHA)")
        }
        print("cache: \(cacheURL.path)")
        print("cache exists: \(cacheExists ? "yes" : "no")")
        if let cacheSHA {
            print("cache sha256: \(cacheSHA)")
        }
        print("cache verified: \(cacheVerified ? "yes" : "no")")
        print("download command: \(downloadCommand)")
        print("download checksums: \(downloadChecksumsCommand)")
        print("verify checksum: \(checksumVerifyCommand)")
        print("attestation verify: \(verifyCommand)")
        if manifest == nil {
            print("note: this build has no embedded remote daemon manifest. Set CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 only for dev builds.")
        }
    }

    func defaultRemoteDaemonPlatform(requestedOS: String?, requestedArch: String?) -> (goOS: String, goArch: String) {
        let normalizedOS = requestedOS?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedArch = requestedArch?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let goOS = (normalizedOS?.isEmpty == false ? normalizedOS! : hostGoOS())
        let goArch = (normalizedArch?.isEmpty == false ? normalizedArch! : hostGoArch())
        return (goOS, goArch)
    }

    func hostGoOS() -> String {
#if os(macOS)
        return "darwin"
#elseif os(Linux)
        return "linux"
#else
        return "unknown"
#endif
    }

    func hostGoArch() -> String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "amd64"
#else
        return "unknown"
#endif
    }

    func remoteDaemonManifest() -> RemoteDaemonManifest? {
        for plistURL in candidateInfoPlistURLs() {
            guard let raw = NSDictionary(contentsOf: plistURL) as? [String: Any],
                  let rawManifest = raw["CMUXRemoteDaemonManifestJSON"] as? String,
                  let data = rawManifest.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let manifest = try? JSONDecoder().decode(RemoteDaemonManifest.self, from: data) else {
                continue
            }
            return manifest
        }
        return nil
    }

    func remoteDaemonVersionString(from info: [String: String]) -> String {
        info["CFBundleShortVersionString"] ?? "dev"
    }

    func remoteDaemonCacheURL(version: String, goOS: String, goArch: String) -> URL {
        let root: URL
        do {
            root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("c11-remote-daemons", isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
                .appendingPathComponent("c11d-remote", isDirectory: false)
        }
        return root
            .appendingPathComponent("c11", isDirectory: true)
            .appendingPathComponent("remote-daemons", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("c11d-remote", isDirectory: false)
    }

    func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let token = trimmed.split(whereSeparator: { $0 == "=" || $0.isWhitespace }).first.map(String.init)?.lowercased()
            if token == loweredKey {
                return true
            }
        }
        return false
    }

    func defaultSSHControlPathTemplate(remoteRelayPort: Int? = nil) -> String {
        if let remoteRelayPort, remoteRelayPort > 0 {
            return "/tmp/cmux-ssh-\(getuid())-\(remoteRelayPort)-%C"
        }
        return "/tmp/cmux-ssh-\(getuid())-%C"
    }

    func normalizedSSHIdentityPath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if !expanded.isEmpty {
                return expanded
            }
        }
        return trimmed
    }

    func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func sshOptionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == loweredKey {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    func cliDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        let trimmedExplicit = ProcessInfo.processInfo.environment["CMUX_DEBUG_LOG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String? = {
            if let trimmedExplicit, !trimmedExplicit.isEmpty {
                return trimmedExplicit
            }
            guard let marker = try? String(contentsOfFile: "/tmp/cmux-last-debug-log-path", encoding: .utf8) else {
                return nil
            }
            let trimmedMarker = marker.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedMarker.isEmpty ? nil : trimmedMarker
        }()
        guard let path else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [cmux-cli] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
#endif
    }

    func runProcess(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        timeout: TimeInterval? = nil
    ) -> (status: Int32, stdout: String, stderr: String) {
        let result = CLIProcessRunner.runProcess(
            executablePath: executablePath,
            arguments: arguments,
            stdinText: stdinText,
            timeout: timeout
        )
        return (result.status, result.stdout, result.stderr)
    }
}
