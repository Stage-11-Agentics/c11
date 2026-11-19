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

    static let cmuxThemeOverrideBundleIdentifier = C11Identity.releaseBundleIdentifier
    static let cmuxThemesReloadNotificationName = C11Identity.themesReloadNotificationName

    struct ThemeSelection {
        let rawValue: String?
        let light: String?
        let dark: String?
        let sourcePath: String?
    }

    struct ThemeReloadStatus {
        let requested: Bool
        let targetBundleIdentifier: String
    }

    enum ThemePickerTargetMode: String {
        case both
        case light
        case dark
    }

    func shouldUseInteractiveThemePicker(jsonOutput: Bool) -> Bool {
        guard !jsonOutput else { return false }
        return isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    func runInteractiveThemes() throws {
        guard let helperURL = bundledHelperURL(named: "ghostty") else {
            throw CLIError(message: "Bundled Ghostty terminal theme picker helper not found")
        }

        let selection = currentThemeSelection()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_THEME_PICKER_CONFIG"] = try cmuxThemeOverrideConfigURL().path
        environment["CMUX_THEME_PICKER_BUNDLE_ID"] = currentCmuxAppBundleIdentifier() ?? Self.cmuxThemeOverrideBundleIdentifier
        environment["CMUX_THEME_PICKER_TARGET"] = defaultThemePickerTargetMode(current: selection).rawValue
        environment["CMUX_THEME_PICKER_COLOR_SCHEME"] = defaultAppearancePrefersDarkThemes() ? "dark" : "light"
        if let light = selection.light {
            environment["CMUX_THEME_PICKER_INITIAL_LIGHT"] = light
        }
        if let dark = selection.dark {
            environment["CMUX_THEME_PICKER_INITIAL_DARK"] = dark
        }
        if let resourcesURL = bundledGhosttyResourcesURL() {
            environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        }

        try execInteractiveHelper(
            executablePath: helperURL.path,
            arguments: ["+list-themes"],
            environment: environment
        )
    }

    func defaultThemePickerTargetMode(current: ThemeSelection) -> ThemePickerTargetMode {
        if let light = current.light,
           let dark = current.dark,
           light.caseInsensitiveCompare(dark) == .orderedSame {
            return .both
        }
        return defaultAppearancePrefersDarkThemes() ? .dark : .light
    }

    func defaultAppearancePrefersDarkThemes() -> Bool {
        let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let interfaceStyle = (globalDefaults?["AppleInterfaceStyle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return interfaceStyle?.caseInsensitiveCompare("Dark") == .orderedSame
    }

    func bundledHelperURL(named helperName: String) -> URL? {
        let fileManager = FileManager.default
        guard let executableURL = resolvedExecutableURL() else { return nil }

        var candidates: [URL] = [
            executableURL.deletingLastPathComponent().appendingPathComponent(helperName, isDirectory: false)
        ]

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.lastPathComponent == "Contents" {
                candidates.append(
                    current
                        .appendingPathComponent("Resources", isDirectory: true)
                        .appendingPathComponent("bin", isDirectory: true)
                        .appendingPathComponent(helperName, isDirectory: false)
                )
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
            let repoHelper = current
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("zig-out", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent(helperName, isDirectory: false)
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.isExecutableFile(atPath: repoHelper.path) {
                candidates.append(repoHelper)
                break
            }

            guard let parent = parentSearchURL(for: current) else { break }
            current = parent
        }

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    func execInteractiveHelper(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> Never {
        var argv = ([executablePath] + arguments).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        var envp = environment
            .map { key, value in strdup("\(key)=\(value)") }
        defer {
            for item in envp {
                free(item)
            }
        }
        envp.append(nil)

        execve(executablePath, &argv, &envp)
        let code = errno
        throw CLIError(message: "Failed to launch interactive Ghostty terminal theme picker: \(String(cString: strerror(code)))")
    }

    func bundledGhosttyResourcesURL() -> URL? {
        let fileManager = FileManager.default
        guard let executableURL = resolvedExecutableURL() else { return nil }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.lastPathComponent == "Contents" {
                let candidate = current
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("ghostty", isDirectory: true)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj", isDirectory: false)
            let repoResources = current
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("ghostty", isDirectory: true)
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.fileExists(atPath: repoResources.path) {
                return repoResources
            }

            guard let parent = parentSearchURL(for: current) else { break }
            current = parent
        }

        return Bundle.main.resourceURL?.appendingPathComponent("ghostty", isDirectory: true)
    }

    func runThemes(commandArgs: [String], jsonOutput: Bool) throws {
        if commandArgs.isEmpty {
            if shouldUseInteractiveThemePicker(jsonOutput: jsonOutput) {
                try runInteractiveThemes()
                return
            }
            try printThemesList(jsonOutput: jsonOutput)
            return
        }

        guard let subcommand = commandArgs.first else {
            try printThemesList(jsonOutput: jsonOutput)
            return
        }

        switch subcommand {
        case "list":
            if commandArgs.count > 1 {
                throw CLIError(message: "terminal-theme list does not take any positional arguments")
            }
            try printThemesList(jsonOutput: jsonOutput)
        case "set":
            try runThemesSet(
                args: Array(commandArgs.dropFirst()),
                jsonOutput: jsonOutput
            )
        case "clear":
            if commandArgs.count > 1 {
                throw CLIError(message: "terminal-theme clear does not take any positional arguments")
            }
            try runThemesClear(jsonOutput: jsonOutput)
        default:
            if subcommand.hasPrefix("-") {
                throw CLIError(message: "Unknown terminal-theme subcommand '\(subcommand)'. Run 'c11 terminal-theme --help'.")
            }

            try runThemesSet(
                args: commandArgs,
                jsonOutput: jsonOutput
            )
        }
    }

    func printThemesList(jsonOutput: Bool) throws {
        let themes = availableThemeNames()
        let current = currentThemeSelection()
        let configPath = try cmuxThemeOverrideConfigURL().path

        if jsonOutput {
            let currentPayload: [String: Any] = [
                "raw_value": current.rawValue ?? NSNull(),
                "light": current.light ?? NSNull(),
                "dark": current.dark ?? NSNull(),
                "source_path": current.sourcePath ?? NSNull()
            ]
            let payload: [String: Any] = [
                "themes": themes.map { theme in
                    [
                        "name": theme,
                        "current_light": current.light?.caseInsensitiveCompare(theme) == .orderedSame,
                        "current_dark": current.dark?.caseInsensitiveCompare(theme) == .orderedSame
                    ]
                },
                "current": currentPayload,
                "config_path": configPath
            ]
            print(jsonString(payload))
            return
        }

        print("Terminal light: \(current.light ?? "inherit")")
        print("Terminal dark: \(current.dark ?? "inherit")")
        print("Ghostty config: \(configPath)")
        if let sourcePath = current.sourcePath {
            print("Source: \(sourcePath)")
        }
        print("")

        guard !themes.isEmpty else {
            print("No Ghostty terminal themes found.")
            return
        }

        for theme in themes {
            var badges: [String] = []
            if current.light?.caseInsensitiveCompare(theme) == .orderedSame {
                badges.append("light")
            }
            if current.dark?.caseInsensitiveCompare(theme) == .orderedSame {
                badges.append("dark")
            }
            let badgeText = badges.isEmpty ? "" : "  [\(badges.joined(separator: ", "))]"
            print("\(theme)\(badgeText)")
        }
    }

    func runThemesSet(args: [String], jsonOutput: Bool) throws {
        let (lightOpt, rem0) = parseOption(args, name: "--light")
        let (darkOpt, rem1) = parseOption(rem0, name: "--dark")

        if let unknown = rem1.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "terminal-theme set: unknown flag '\(unknown)'. Known flags: --light <terminal-theme>, --dark <terminal-theme>")
        }

        let availableThemes = availableThemeNames()
        let current = currentThemeSelection()

        let lightTheme: String?
        let darkTheme: String?

        if lightOpt == nil && darkOpt == nil {
            let joinedTheme = rem1.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joinedTheme.isEmpty else {
                throw CLIError(message: "terminal-theme set requires a terminal theme name or --light/--dark flags")
            }
            let resolved = try validatedThemeName(joinedTheme, availableThemes: availableThemes)
            lightTheme = resolved
            darkTheme = resolved
        } else {
            if !rem1.isEmpty {
                throw CLIError(message: "terminal-theme set: unexpected argument '\(rem1.joined(separator: " "))'")
            }
            lightTheme = try lightOpt.map { try validatedThemeName($0, availableThemes: availableThemes) } ?? current.light
            darkTheme = try darkOpt.map { try validatedThemeName($0, availableThemes: availableThemes) } ?? current.dark
        }

        let written = try applyTerminalThemes(light: lightTheme, dark: darkTheme)

        if jsonOutput {
            var payload = written.payload
            payload["ok"] = true
            print(jsonString(payload))
            return
        }

        print("OK \(written.summary)")
    }

    struct TerminalThemeWrite {
        let light: String?
        let dark: String?
        let rawValue: String
        let configURL: URL
        let reload: ThemeReloadStatus

        var payload: [String: Any] {
            [
                "light": light ?? NSNull(),
                "dark": dark ?? NSNull(),
                "raw_value": rawValue,
                "config_path": configURL.path,
                "reload_requested": reload.requested,
                "reload_target_bundle_id": reload.targetBundleIdentifier
            ]
        }

        var summary: String {
            "terminal_light=\(light ?? "-") terminal_dark=\(dark ?? "-") ghostty_config=\(configURL.path) reload=\(reload.requested ? "requested" : "skipped")"
        }
    }

    /// The terminal-theme path: c11's managed override in its own `config.ghostty`
    /// (never the operator's Ghostty config), then a reload request to the app.
    func applyTerminalThemes(light: String?, dark: String?) throws -> TerminalThemeWrite {
        // Ghostty accepts a light/dark pair only with both halves: a slot with no theme
        // takes the other's.
        let light = light ?? dark
        let dark = dark ?? light
        guard let rawThemeValue = encodedThemeValue(light: light, dark: dark) else {
            throw CLIError(message: "terminal-theme set requires at least one terminal theme")
        }
        let configURL = try writeManagedThemeOverride(rawThemeValue: rawThemeValue)
        let reloadStatus = reloadThemesIfPossible()
        return TerminalThemeWrite(light: light, dark: dark, rawValue: rawThemeValue, configURL: configURL, reload: reloadStatus)
    }

    func runThemesClear(jsonOutput: Bool) throws {
        let configURL = try clearManagedThemeOverride()
        let reloadStatus = reloadThemesIfPossible()

        if jsonOutput {
            let payload: [String: Any] = [
                "ok": true,
                "cleared": true,
                "config_path": configURL.path,
                "reload_requested": reloadStatus.requested,
                "reload_target_bundle_id": reloadStatus.targetBundleIdentifier
            ]
            print(jsonString(payload))
            return
        }

        print("OK cleared ghostty_config=\(configURL.path) reload=requested")
    }

    func currentThemeSelection() -> ThemeSelection {
        var rawValue: String?
        var sourcePath: String?

        for url in themeConfigSearchURLs() {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let nextValue = lastThemeDirective(in: contents) else {
                continue
            }
            rawValue = nextValue
            sourcePath = url.path
        }

        return parseThemeSelection(rawValue: rawValue, sourcePath: sourcePath)
    }

    func parseThemeSelection(rawValue: String?, sourcePath: String?) -> ThemeSelection {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return ThemeSelection(rawValue: nil, light: nil, dark: nil, sourcePath: sourcePath)
        }

        var fallbackTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                if fallbackTheme == nil {
                    fallbackTheme = entry
                }
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                if lightTheme == nil {
                    lightTheme = value
                }
            case "dark":
                if darkTheme == nil {
                    darkTheme = value
                }
            default:
                if fallbackTheme == nil {
                    fallbackTheme = value
                }
            }
        }

        let resolvedLight = lightTheme ?? fallbackTheme ?? darkTheme
        let resolvedDark = darkTheme ?? fallbackTheme ?? lightTheme
        return ThemeSelection(rawValue: rawValue, light: resolvedLight, dark: resolvedDark, sourcePath: sourcePath)
    }

    func encodedThemeValue(light: String?, dark: String?) -> String? {
        let normalizedLight = light?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDark = dark?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (normalizedLight?.isEmpty == false ? normalizedLight : nil, normalizedDark?.isEmpty == false ? normalizedDark : nil) {
        case let (lightTheme?, darkTheme?):
            return "light:\(lightTheme),dark:\(darkTheme)"
        case let (lightTheme?, nil):
            return "light:\(lightTheme),dark:\(lightTheme)"
        case let (nil, darkTheme?):
            return "light:\(darkTheme),dark:\(darkTheme)"
        case (nil, nil):
            return nil
        }
    }

    // MARK: - `c11 themes`, `c11 ui themes` + `c11 workspace-color` (CMUX-35)

    func runUi(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let first = commandArgs.first else {
            throw CLIError(message: "ui requires a subcommand. Try: c11 themes list")
        }
        let sub = first.lowercased()
        let rest = Array(commandArgs.dropFirst())

        switch sub {
        case "themes":
            try runUiThemes(
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                allowAuthoringHelpers: true
            )
        default:
            throw CLIError(message: "Unknown ui subcommand: \(first)")
        }
    }

    func runUiThemes(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        allowAuthoringHelpers: Bool
    ) throws {
        guard let first = commandArgs.first else {
            try runUiThemesList(client: client, jsonOutput: jsonOutput)
            return
        }
        let sub = first.lowercased()
        var rest = Array(commandArgs.dropFirst())

        // c11 (C11H-197): `--window <ref>` (or the global --window) targets one
        // window's own theme instead of the app theme.
        if ["get", "set", "clear"].contains(sub) {
            let (windowRaw, withoutWindow) = parseOption(rest, name: "--window")
            if let target = windowRaw ?? client.scopedWindow {
                try runWindowTheme(sub: sub, args: withoutWindow, windowRaw: target, client: client, jsonOutput: jsonOutput)
                return
            }
            rest = withoutWindow
        }

        switch sub {
        case "list":
            try runUiThemesList(client: client, jsonOutput: jsonOutput)
        case "get":
            try runUiThemesGet(args: rest, client: client, jsonOutput: jsonOutput)
        case "set":
            try runUiThemesSet(args: rest, client: client, jsonOutput: jsonOutput)
        case "clear":
            try runUiThemesClear(client: client, jsonOutput: jsonOutput)
        case "reload":
            try runUiThemesReload(client: client, jsonOutput: jsonOutput)
        case "path":
            try runUiThemesPath(client: client, jsonOutput: jsonOutput)
        case "dump":
            try runUiThemesDump(args: rest, client: client, jsonOutput: jsonOutput)
        case "validate":
            try runUiThemesValidate(args: rest, client: client, jsonOutput: jsonOutput)
        case "diff":
            try runUiThemesDiff(args: rest, client: client, jsonOutput: jsonOutput)
        case "inherit":
            if allowAuthoringHelpers {
                try runUiThemesInherit(args: rest, client: client, jsonOutput: jsonOutput)
            } else {
                throw CLIError(message: "Unknown themes subcommand: \(first)")
            }
        default:
            throw CLIError(message: "Unknown themes subcommand: \(first)")
        }
    }

    func runUiThemesList(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "theme.list")
        if jsonOutput {
            print(jsonString(response))
            return
        }
        print("Theme: \(response["active"] as? String ?? "?")")
        print("")

        let items = response["themes"] as? [[String: Any]] ?? []
        for item in items {
            let name = item["name"] as? String ?? "?"
            let source = item["source"] as? String ?? "?"
            let display = item["display_name"] as? String ?? name
            let tags = [(item["is_active"] as? Bool == true) ? "active" : nil, source].compactMap { $0 }
            let tagText = tags.isEmpty ? "" : " [\(tags.joined(separator: ","))]"
            let pairText = TerminalThemePairing.normalized(item[TerminalThemePairing.pairKey] as? String)
                .map { "  terminal: \($0)" } ?? ""
            print("\(name)  \"\(display)\"\(tagText)\(pairText)")
            if let warning = item["warning"] as? String {
                print("  warning: \(warning)")
            }
        }
    }

    /// c11 shows one theme day and night; `--slot` from the day/night design is refused
    /// with the command that replaces it.
    func refuseRetiredThemeSlot(_ args: [String], command: String) throws {
        if args.contains(where: { $0 == "--slot" || $0.hasPrefix("--slot=") }) {
            throw CLIError(message: "themes \(command): c11 has one theme for day and night, so --slot is gone. Run 'c11 themes \(command)\(command == "set" ? " <name>" : "")'.")
        }
    }

    func runUiThemesGet(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        try refuseRetiredThemeSlot(args, command: "get")
        guard args.isEmpty else {
            throw CLIError(message: "themes get: unexpected argument '\(args[0])'")
        }
        let response = try client.sendV2(method: "theme.get")
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let pair = TerminalThemePairing.normalized(response[TerminalThemePairing.pairKey] as? String)
            .map { " (terminal: \($0))" } ?? ""
        print("Theme: \(response["name"] as? String ?? "?")\(pair)")
    }

    func runUiThemesSet(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        try refuseRetiredThemeSlot(args, command: "set")
        let (rest, withTerminal) = parseFlag(args, name: "--with-terminal")
        let positional = rest.filter { !$0.hasPrefix("-") }
        guard let name = positional.first else {
            throw CLIError(message: "themes set requires a theme name. Example: c11 themes set nocturne")
        }
        if positional.count > 1 {
            throw CLIError(message: "themes set: unexpected extra argument '\(positional[1])'")
        }
        // The pair is read and checked before anything changes, so a broken pair changes nothing.
        let pair: String? = try withTerminal ? pairedTerminalThemeBeforeSet(name: name, client: client) : nil
        let response = try client.sendV2(method: "theme.set_active", params: ["name": name])
        let ok = (response["ok"] as? Bool) == true
        guard withTerminal, ok else {
            if jsonOutput {
                print(jsonString(response))
                return
            }
            guard ok else {
                let msg = response["error"] as? String ?? "failed"
                throw CLIError(message: "themes set failed: \(msg)")
            }
            print("OK theme=\(name)")
            return
        }

        func output(_ terminal: [String: Any]) {
            var payload = response
            payload["terminal"] = terminal
            print(jsonString(payload))
        }
        guard let pair else {
            if jsonOutput {
                output(terminalThemePayload(pair: nil, written: nil, reason: "no_pair"))
                return
            }
            print("OK theme=\(name) terminal=unchanged (\(name) names no paired terminal theme)")
            return
        }
        // The chrome is already set: a failure from here says so, and what it left alone.
        func fail(_ reason: String, _ detail: String) throws -> Never {
            if jsonOutput {
                output(terminalThemePayload(pair: pair, written: nil, reason: reason, error: detail))
            }
            throw CLIError(message: "themes set --with-terminal: theme set to \(name); terminal unchanged: \(detail)")
        }
        let written: TerminalThemeWrite
        do {
            written = try applyTerminalThemes(light: pair, dark: pair)
        } catch {
            try fail("write_failed", (error as? CLIError)?.message ?? error.localizedDescription)
        }
        if jsonOutput {
            output(terminalThemePayload(pair: pair, written: written, reason: nil))
            return
        }
        print("OK theme=\(name) \(written.summary)")
    }

    /// The `terminal` object of `themes set --with-terminal --json`: the same keys in every
    /// case, null where a case has no value.
    func terminalThemePayload(pair: String?, written: TerminalThemeWrite?, reason: String?, error: String? = nil) -> [String: Any] {
        [
            "applied": written != nil,
            "reason": reason ?? NSNull(),
            "error": error ?? NSNull(),
            "paired_theme": TerminalThemePairing.payloadValue(pair),
            "light": written?.light ?? NSNull(),
            "dark": written?.dark ?? NSNull(),
            "raw_value": written?.rawValue ?? NSNull(),
            "config_path": written?.configURL.path ?? NSNull(),
            "reload_requested": written?.reload.requested ?? false,
            "reload_target_bundle_id": written?.reload.targetBundleIdentifier ?? NSNull()
        ]
    }

    /// The installed Ghostty theme `name` pairs with, or nil when it names none. Throws,
    /// changing nothing, when the app cannot report pairs or the pair is not installed.
    func pairedTerminalThemeBeforeSet(name: String, client: SocketClient) throws -> String? {
        let listing = try client.sendV2(method: "theme.list")
        guard listing["ok"] as? Bool != false, let items = listing["themes"] as? [[String: Any]] else {
            let detail = listing["error"] as? String ?? "the app returned no theme list"
            throw CLIError(message: "themes set --with-terminal: could not read terminal pairs (\(detail)); nothing changed")
        }
        // An unknown name is left to theme.set_active, which reports it.
        guard let item = items.first(where: { $0["name"] as? String == name }) else { return nil }
        switch TerminalThemePairing.lookup(in: item) {
        case .unsupported:
            throw CLIError(message: "themes set --with-terminal: this c11 app does not report terminal pairs; nothing changed")
        case .unpaired:
            return nil
        case let .paired(pair):
            guard let installed = try? validatedThemeName(pair, availableThemes: availableThemeNames()) else {
                throw CLIError(message: "themes set --with-terminal: '\(name)' pairs with terminal theme '\(pair)', which is not installed; nothing changed. Run 'c11 terminal-theme list'.")
            }
            return installed
        }
    }

    /// c11 (C11H-197): `themes get|set|clear --window <ref>`. A window theme
    /// repaints that window's chrome; terminal colours stay app-wide.
    func runWindowTheme(sub: String, args: [String], windowRaw: String, client: SocketClient, jsonOutput: Bool) throws {
        try refuseRetiredThemeSlot(args, command: sub)
        let windowId = try resolveWindowTarget(windowRaw, client: client)
        switch sub {
        case "get":
            guard args.isEmpty else { throw CLIError(message: "themes get: unexpected argument '\(args[0])'") }
            let response = try client.sendV2(method: "theme.get", params: ["window_id": windowId])
            if jsonOutput {
                print(jsonString(response))
                return
            }
            let window = response["window"] as? [String: Any] ?? [:]
            let effective = window["effective"] as? String ?? "?"
            let ref = window["ref"] as? String ?? windowId
            let source = window["override"] is String ? "window theme" : "app theme"
            print("Theme: \(effective) (\(source), window \(ref))")
        case "set", "clear":
            var name: String?
            if sub == "set" {
                let (rest, withTerminal) = parseFlag(args, name: "--with-terminal")
                if withTerminal {
                    throw CLIError(message: "themes set --window: terminal colours are app-wide, so --with-terminal cannot target one window; nothing changed")
                }
                let positional = rest.filter { !$0.hasPrefix("-") }
                guard let first = positional.first else {
                    throw CLIError(message: "themes set requires a theme name. Example: c11 themes set nocturne --window window:2")
                }
                if positional.count > 1 { throw CLIError(message: "themes set: unexpected extra argument '\(positional[1])'") }
                name = first
            } else if let extra = args.first {
                throw CLIError(message: "themes clear: unexpected argument '\(extra)'")
            }
            let response = try CapabilityFeatures.current.dispatch(.windowTheme) {
                try client.sendV2(method: "window.set_theme", params: ["window_id": windowId, "theme": name ?? NSNull()])
            }
            if jsonOutput {
                print(jsonString(response))
                return
            }
            let ref = response["window_ref"] as? String ?? windowId
            if let name {
                print("OK window=\(ref) theme=\(name)")
            } else {
                let effective = (response["theme"] as? [String: Any])?["effective"] as? String ?? "app"
                print("OK window=\(ref) theme cleared (follows the app theme, \(effective))")
            }
        default:
            throw CLIError(message: "Unknown themes subcommand: \(sub)")
        }
    }

    func runUiThemesClear(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "theme.clear_active")
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK cleared active c11 chrome theme overrides")
        }
    }

    func runUiThemesReload(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "theme.reload")
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK c11 chrome themes reloaded")
        }
    }

    func runUiThemesPath(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "theme.paths")
        if jsonOutput {
            print(jsonString(response))
            return
        }
        if let user = response["user_themes_directory"] as? String {
            print("user:    \(user)")
        }
        if let bundled = response["bundled_themes_directory"] as? String {
            print("bundled: \(bundled)")
        }
    }

    func runUiThemesDump(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (schemeOpt, rest) = parseOption(args, name: "--color-scheme")
        let wantJson = jsonOutput || rest.contains("--json")
        var params: [String: Any] = [:]
        if let scheme = schemeOpt { params["color_scheme"] = scheme }
        let response = try client.sendV2(method: "theme.dump", params: params)
        guard let json = response["dump_json"] as? String else {
            throw CLIError(message: "themes dump: missing dump_json")
        }
        if wantJson {
            print(json)
        } else {
            print(json)
        }
    }

    func runUiThemesValidate(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let path = args.first else {
            throw CLIError(message: "themes validate requires a file path")
        }
        let absolutePath = resolvePath(path)
        let response = try client.sendV2(method: "theme.validate", params: ["path": absolutePath])
        if jsonOutput {
            print(jsonString(response))
            return
        }
        if (response["ok"] as? Bool) == true {
            let name = response["name"] as? String ?? "?"
            print("OK \(absolutePath): parses as '\(name)'")
        } else {
            let msg = response["error"] as? String ?? "invalid"
            print("FAIL \(absolutePath): \(msg)")
            throw CLIError(message: "validation failed")
        }
    }

    func runUiThemesDiff(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard args.count >= 2 else {
            throw CLIError(message: "themes diff requires two c11 chrome theme names or paths")
        }
        let response = try client.sendV2(
            method: "theme.diff",
            params: ["a": args[0], "b": args[1]]
        )
        if jsonOutput {
            print(jsonString(response))
            return
        }
        if (response["ok"] as? Bool) == true {
            let a = response["a"] as? String ?? args[0]
            let b = response["b"] as? String ?? args[1]
            let count = response["changed_role_count"] as? Int ?? 0
            print("\(a) vs \(b): \(count) role(s) differ")
            if let changed = response["changed_roles"] as? [String] {
                for role in changed { print("  \(role)") }
            }
        } else {
            let msg = response["error"] as? String ?? "diff failed"
            throw CLIError(message: msg)
        }
    }

    func runUiThemesInherit(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (asOpt, rest) = parseOption(args, name: "--as")
        guard let parent = rest.first, let child = asOpt else {
            throw CLIError(message: "themes inherit requires a parent theme and --as <new-name>")
        }
        let response = try client.sendV2(
            method: "theme.inherit",
            params: ["parent": parent, "as": child]
        )
        if jsonOutput {
            print(jsonString(response))
            return
        }
        if (response["ok"] as? Bool) == true, let path = response["path"] as? String {
            print("OK wrote \(path)")
        } else {
            let msg = response["error"] as? String ?? "inherit failed"
            throw CLIError(message: msg)
        }
    }
}
