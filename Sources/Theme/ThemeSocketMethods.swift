import Foundation

/// Socket handlers for the `theme.*` and `workspace.set_custom_color` method families.
///
/// Read-only `theme.list`, `theme.get`, `theme.paths`, `theme.dump`, `theme.validate`, `theme.diff`
/// are safe to call from unauthenticated clients. Mutating methods (`theme.set_active`,
/// `theme.clear_active`, `theme.reload`, `theme.inherit`, `workspace.set_custom_color`) must be
/// dispatched by the CLI after authentication (the socket layer already gates them).
///
/// All handlers parse/validate off the calling thread; the only main-actor hop is the minimal
/// state update (`ThemeManager.shared.setActiveTheme(name:)` / `forceReloadUserThemes()`).
/// This keeps the socket focus policy intact — no commands below steal macOS focus.
public enum ThemeSocketMethods {

    public static let readOnlyMethods: Set<String> = [
        "theme.list",
        "theme.get",
        "theme.paths",
        "theme.dump",
        "theme.validate",
        "theme.diff"
    ]

    public static let mutatingMethods: Set<String> = [
        "theme.set_active",
        "theme.clear_active",
        "theme.reload",
        "theme.inherit",
        "workspace.set_custom_color"
    ]

    // MARK: - Read-only

    public static func list() -> [String: Any] {
        let (descriptors, activeName, pairs): ([ThemeManager.ThemeDescriptor], String, [String: String]) =
            Self.mainSync {
                let themes = ThemeManager.shared
                let descriptors = themes.availableThemes
                var pairs: [String: String] = [:]
                for descriptor in descriptors {
                    let name = descriptor.identity.name
                    if let pair = themes.theme(named: name)?.pairedTerminalTheme { pairs[name] = pair }
                }
                // The theme on screen: a stored name that no longer loads shows stage11.
                return (descriptors, themes.active.identity.name, pairs)
            }
        return listPayload(descriptors: descriptors, active: activeName, pairs: pairs)
    }

    /// `theme.list`'s reply. `pairs` maps a theme name to the Ghostty theme it pairs with.
    static func listPayload(
        descriptors: [ThemeManager.ThemeDescriptor],
        active activeName: String,
        pairs: [String: String]
    ) -> [String: Any] {
        let items: [[String: Any]] = descriptors.map { descriptor in
            var payload: [String: Any] = [
                "name": descriptor.identity.name,
                "display_name": descriptor.identity.displayName,
                "author": descriptor.identity.author,
                "version": descriptor.identity.version,
                "schema": descriptor.identity.schema,
                "source": descriptor.source.rawValue
            ]
            if let path = descriptor.sourcePath {
                payload["source_path"] = path
            }
            if let warning = descriptor.warning {
                payload["warning"] = warning
            }
            payload["is_active"] = descriptor.identity.name == activeName
            payload[TerminalThemePairing.pairKey] = TerminalThemePairing.payloadValue(pairs[descriptor.identity.name])
            return payload
        }

        return [
            "themes": items,
            "active": activeName
        ]
    }

    /// The one active theme and its terminal pair. c11 has no day or night slot, so a
    /// `slot` parameter from an older caller is ignored.
    public static func get(params: [String: Any]) -> [String: Any] {
        let (name, pair): (String, String?) = Self.mainSync {
            let themes = ThemeManager.shared
            let name = themes.active.identity.name
            return (name, themes.active.pairedTerminalTheme)
        }
        return getPayload(active: name, pair: pair)
    }

    /// `theme.get`'s reply.
    static func getPayload(active name: String, pair: String?) -> [String: Any] {
        ["name": name, TerminalThemePairing.pairKey: TerminalThemePairing.payloadValue(pair)]
    }

    public static func paths(pathsOverride: ThemeManager.PathsOverride? = nil) -> [String: Any] {
        let userDir = ThemeManager.userThemesDirectory(override: pathsOverride)
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent(ThemeManager.bundledThemesDirectoryName, isDirectory: true)
            .path ?? "<bundled>"
        return [
            "user_themes_directory": userDir.path,
            "bundled_themes_directory": bundled
        ]
    }

    public static func dumpActive(params: [String: Any]) -> [String: Any] {
        let colorScheme: ThemeContext.ColorScheme
        switch (params["color_scheme"] as? String)?.lowercased() {
        case "light":
            colorScheme = .light
        case "dark":
            colorScheme = .dark
        default:
            colorScheme = Self.mainSync { ThemeManager.currentColorScheme() }
        }

        let json = Self.mainSync {
            let context = ThemeManager.shared.makeContext(colorScheme: colorScheme)
            return ThemeManager.shared.dumpActiveThemeJSON(context: context)
        }

        return ["dump_json": json]
    }

    public static func validate(params: [String: Any]) -> [String: Any] {
        guard let path = params["path"] as? String else {
            return ["ok": false, "error": "missing required parameter: path"]
        }
        let url = URL(fileURLWithPath: path)
        return validateURL(url)
    }

    public static func validateURL(_ url: URL) -> [String: Any] {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            return ["ok": false, "error": "unable to read file: \(url.path)"]
        }

        do {
            let table = try TomlSubsetParser.parse(file: url.path, source: source)
            let theme = try C11Theme.fromToml(table)
            return [
                "ok": true,
                "name": theme.identity.name,
                "display_name": theme.identity.displayName,
                "schema": theme.identity.schema
            ]
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    public static func diff(params: [String: Any]) -> [String: Any] {
        guard let a = params["a"] as? String, let b = params["b"] as? String else {
            return ["ok": false, "error": "missing required parameters: a, b"]
        }

        let themeA = resolveThemeForDiff(nameOrPath: a)
        let themeB = resolveThemeForDiff(nameOrPath: b)

        guard let themeA else {
            return ["ok": false, "error": "theme or path not found: \(a)"]
        }
        guard let themeB else {
            return ["ok": false, "error": "theme or path not found: \(b)"]
        }

        let canonicalA = ThemeCanonicalizer.canonicalize(themeA)
        let canonicalB = ThemeCanonicalizer.canonicalize(themeB)
        let changedRoles = ThemeRole.allCases.filter { role in
            themeA.stringValue(for: role) != themeB.stringValue(for: role)
                || themeA.numberValue(for: role) != themeB.numberValue(for: role)
                || themeA.boolValue(for: role) != themeB.boolValue(for: role)
        }
        return [
            "ok": true,
            "a": themeA.identity.name,
            "b": themeB.identity.name,
            "identical": canonicalA == canonicalB,
            "changed_role_count": changedRoles.count,
            "changed_roles": changedRoles.map(\.definition.path)
        ]
    }

    // MARK: - Mutating

    public static func setActive(params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return ["ok": false, "error": "missing required parameter: name"]
        }
        // c11 shows one theme day and night; an older caller's `slot` is ignored.
        let ok: Bool = Self.mainSync { ThemeManager.shared.setActiveTheme(name: name) }
        if !ok {
            return ["ok": false, "error": "unknown theme: \(name)"]
        }
        let pair = Self.mainSync { ThemeManager.shared.theme(named: name)?.pairedTerminalTheme }
        return ["ok": true, "name": name, TerminalThemePairing.pairKey: TerminalThemePairing.payloadValue(pair)]
    }

    public static func clearActive() -> [String: Any] {
        Self.mainSync {
            ThemeManager.shared.clearActiveOverrides()
        }
        return ["ok": true]
    }

    public static func reload() -> [String: Any] {
        Self.mainSync {
            ThemeManager.shared.forceReloadUserThemes()
        }
        return ["ok": true]
    }

    public static func inherit(params: [String: Any]) -> [String: Any] {
        guard let parent = params["parent"] as? String,
              let childName = params["as"] as? String else {
            return ["ok": false, "error": "missing required parameters: parent, as"]
        }

        let parentTheme: C11Theme? = Self.mainSync {
            ThemeManager.shared.theme(named: parent)
        }
        guard let parentTheme else {
            return ["ok": false, "error": "unknown parent theme: \(parent)"]
        }

        let cloned = C11Theme(
            identity: .init(
                name: childName,
                displayName: childName,
                author: parentTheme.identity.author,
                version: "0.01.001",
                schema: parentTheme.identity.schema
            ),
            palette: parentTheme.palette,
            variables: parentTheme.variables,
            chrome: parentTheme.chrome,
            behavior: parentTheme.behavior
        )

        let rendered = ThemeCanonicalizer.canonicalize(cloned)
        let userDir = ThemeManager.userThemesDirectory()
        let outputURL = userDir.appendingPathComponent("\(childName).toml")

        let fm = FileManager.default
        if !fm.fileExists(atPath: userDir.path) {
            try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        }

        do {
            try rendered.write(to: outputURL, atomically: true, encoding: .utf8)
        } catch {
            return ["ok": false, "error": "failed to write \(outputURL.path): \(error)"]
        }

        return [
            "ok": true,
            "parent": parent,
            "name": childName,
            "path": outputURL.path
        ]
    }

    // MARK: - Helpers

    /// Hop to main when needed, run inline when already on main.
    ///
    /// Bare `DispatchQueue.main.sync` would self-deadlock if a caller is already on main —
    /// post-C11-26 the v2 dispatcher routes default-policy commands through main, so any
    /// theme.* handler reached via `processCommand` is now invoked on the main thread.
    /// libdispatch detects the self-wait and traps with EXC_BREAKPOINT
    /// (`__DISPATCH_WAIT_FOR_QUEUE__`). Mirrors `GhosttyTerminalView.performOnMain`
    /// and `TerminalController.v2MainSync`; ThemeSocketMethods isn't @MainActor itself,
    /// so the body has to be marked `@MainActor` explicitly.
    private static func mainSync<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { body() }
        }
    }

    private static func resolveThemeForDiff(nameOrPath: String) -> C11Theme? {
        if nameOrPath.contains("/") || nameOrPath.hasSuffix(".toml") {
            let url = URL(fileURLWithPath: nameOrPath)
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                  let table = try? TomlSubsetParser.parse(file: url.path, source: source),
                  let theme = try? C11Theme.fromToml(table) else {
                return nil
            }
            return theme
        }
        return Self.mainSync { ThemeManager.shared.theme(named: nameOrPath) }
    }
}
