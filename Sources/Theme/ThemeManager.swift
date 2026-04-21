import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()
    public nonisolated static let bundledThemesDirectoryName = "c11-themes"
    public nonisolated static let userThemesApplicationSupportDirectoryName = "c11"

    public struct ThemeDescriptor: Equatable, Sendable {
        public enum Source: String, Equatable, Sendable {
            case builtin
            case user
        }

        public let identity: C11muxTheme.Identity
        public let source: Source
        public let sourcePath: String?
        public let warning: String?

        public init(identity: C11muxTheme.Identity, source: Source, sourcePath: String?, warning: String? = nil) {
            self.identity = identity
            self.source = source
            self.sourcePath = sourcePath
            self.warning = warning
        }
    }

    @Published public private(set) var active: C11muxTheme
    @Published public private(set) var activeLight: C11muxTheme
    @Published public private(set) var activeDark: C11muxTheme
    @Published public private(set) var availableThemes: [ThemeDescriptor] = []
    @Published public private(set) var version: UInt64 = 1

    public private(set) var snapshot: ResolvedThemeSnapshot

    public let sidebarPublisher = PassthroughSubject<Void, Never>()
    public let titleBarPublisher = PassthroughSubject<Void, Never>()
    public let dividerPublisher = PassthroughSubject<Void, Never>()
    public let framePublisher = PassthroughSubject<Void, Never>()
    public let browserChromePublisher = PassthroughSubject<Void, Never>()
    public let markdownChromePublisher = PassthroughSubject<Void, Never>()
    public let tabBarPublisher = PassthroughSubject<Void, Never>()

    public private(set) var ghosttyBackgroundGeneration: UInt64 = 0

    private let notificationCenter: NotificationCenter
    private var cancellables: Set<AnyCancellable> = []
    private let disabledByEnvironment: Bool

    private var themesByName: [String: ThemeDescriptor] = [:]
    private var loadedThemeCache: [String: C11muxTheme] = [:]
    private var lastKnownGoodThemes: [String: C11muxTheme] = [:]
    private var malformedThemes: [String: String] = [:]

    private var watcher: ThemeDirectoryWatcher?
    private let pathsOverride: PathsOverride?

    public struct PathsOverride {
        public let userThemesDirectory: URL?
        public let builtinDirectory: URL?

        public init(userThemesDirectory: URL? = nil, builtinDirectory: URL? = nil) {
            self.userThemesDirectory = userThemesDirectory
            self.builtinDirectory = builtinDirectory
        }
    }

    public var isEnabled: Bool {
        guard !disabledByEnvironment else { return false }
        return !ThemeAppStorage.bool(forKey: ThemeAppStorage.Keys.engineDisabledRuntime, default: false)
    }

    public init(
        notificationCenter: NotificationCenter = .default,
        pathsOverride: PathsOverride? = nil
    ) {
        self.notificationCenter = notificationCenter
        self.disabledByEnvironment = ProcessInfo.processInfo.environment["CMUX_DISABLE_THEME_ENGINE"] == "1"
        self.pathsOverride = pathsOverride

        let loaded = ThemeManager.loadThemeFromBundle(named: "stage11", override: pathsOverride)
            ?? C11muxTheme.fallbackStage11
        self.active = loaded
        self.activeLight = loaded
        self.activeDark = loaded
        self.snapshot = ResolvedThemeSnapshot(theme: loaded)

        notificationCenter.publisher(for: .ghosttyDefaultBackgroundDidChange)
            .sink { [weak self] _ in
                self?.handleGhosttyBackgroundChange()
            }
            .store(in: &cancellables)

        if disabledByEnvironment {
            ThemeDiagnostics.engine("theme engine disabled by CMUX_DISABLE_THEME_ENGINE=1")
        }

        rescanThemes()
        applyActiveSelections()
    }

    public func resolve<T>(_ role: ThemeRole, context: ThemeContext) -> T? {
        guard isEnabled else {
            return nil
        }

        if T.self == NSColor.self {
            return snapshot.resolveColor(role: role, context: context) as? T
        }

        if T.self == CGFloat.self {
            guard let number = snapshot.resolveNumber(role: role, context: context) else {
                return nil
            }
            return CGFloat(number) as? T
        }

        if T.self == Double.self {
            return snapshot.resolveNumber(role: role, context: context) as? T
        }

        if T.self == Bool.self {
            return snapshot.resolveBoolean(role: role, context: context) as? T
        }

        return nil
    }

    public func makeContext(
        workspaceColor: String? = nil,
        colorScheme: ThemeContext.ColorScheme,
        forceBright: Bool = false,
        isWindowFocused: Bool = true,
        workspaceState: WorkspaceState? = nil
    ) -> ThemeContext {
        ThemeContext(
            workspaceColor: workspaceColor,
            colorScheme: colorScheme,
            forceBright: forceBright,
            ghosttyBackgroundGeneration: ghosttyBackgroundGeneration,
            isWindowFocused: isWindowFocused,
            workspaceState: workspaceState
        )
    }

    public func makeContext(
        workspaceColor: String? = nil,
        colorScheme: ColorScheme,
        forceBright: Bool = false,
        isWindowFocused: Bool = true,
        workspaceState: WorkspaceState? = nil
    ) -> ThemeContext {
        makeContext(
            workspaceColor: workspaceColor,
            colorScheme: colorScheme.themeContextColorScheme,
            forceBright: forceBright,
            isWindowFocused: isWindowFocused,
            workspaceState: workspaceState
        )
    }

    public func reloadFromBundle(named name: String = "stage11") {
        guard let loaded = ThemeManager.loadThemeFromBundle(named: name, override: pathsOverride) else {
            ThemeDiagnostics.loader("failed to load bundled theme '\(name)'; keeping active theme '\(active.identity.name)'")
            return
        }

        active = loaded
        snapshot = ResolvedThemeSnapshot(theme: loaded)
        bumpVersionAndPublishAll()
    }

    public func setRuntimeDisabled(_ disabled: Bool) {
        ThemeAppStorage.set(disabled, forKey: ThemeAppStorage.Keys.engineDisabledRuntime)
        bumpVersionAndPublishAll()
    }

    /// Invalidates cached resolutions that depend on `$workspaceColor`. Called by
    /// `WorkspaceContentView` when the active workspace's `customColor` changes so
    /// divider, frame, sidebar-overlay, and tab-indicator colors re-resolve without
    /// a Ghostty event or theme swap. Bumps `version` so `@ObservedObject`
    /// dependents re-render; per-section publishers fire for narrower subscribers.
    public func invalidateForWorkspaceColorChange() {
        snapshot.invalidateCaches()
        version &+= 1
        dividerPublisher.send()
        framePublisher.send()
        sidebarPublisher.send()
        tabBarPublisher.send()
    }

    public func toggleRuntimeDisabled() {
        let next = !ThemeAppStorage.bool(forKey: ThemeAppStorage.Keys.engineDisabledRuntime, default: false)
        setRuntimeDisabled(next)
    }

    public func dumpActiveThemeJSON(context: ThemeContext) -> String {
        var rolesPayload: [String: [String: String?]] = [:]

        for role in ThemeRole.allCases {
            switch role.definition.expectedType {
            case .color:
                let explicitExpression = active.stringValue(for: role)
                let expression = explicitExpression ?? role.definition.defaultColorExpression
                let resolved: String?
                if let color: NSColor = resolve(role, context: context) {
                    resolved = color.hexString(includeAlpha: color.alphaComponent < 0.999)
                } else {
                    resolved = nil
                }

                rolesPayload[role.definition.path] = [
                    "expression": expression,
                    "resolved": resolved,
                    "inherited_from": explicitExpression == nil ? "stage11" : nil,
                ]

            case .number:
                let resolved: String?
                if let value: Double = resolve(role, context: context) {
                    resolved = String(value)
                } else {
                    resolved = nil
                }

                rolesPayload[role.definition.path] = [
                    "expression": nil,
                    "resolved": resolved,
                    "inherited_from": active.numberValue(for: role) == nil ? "stage11" : nil,
                ]

            case .boolean:
                let resolved: String?
                if let value: Bool = resolve(role, context: context) {
                    resolved = value ? "true" : "false"
                } else {
                    resolved = nil
                }

                rolesPayload[role.definition.path] = [
                    "expression": nil,
                    "resolved": resolved,
                    "inherited_from": active.boolValue(for: role) == nil ? "stage11" : nil,
                ]
            }
        }

        let descriptor = themesByName[active.identity.name]
        let sourcePath = descriptor?.sourcePath ?? "<bundled>"
        let warnings: [String]
        if let warning = descriptor?.warning {
            warnings = [warning]
        } else {
            warnings = []
        }

        let payload: [String: Any] = [
            "theme": [
                "identity": [
                    "name": active.identity.name,
                    "display_name": active.identity.displayName,
                    "version": active.identity.version,
                    "schema": active.identity.schema,
                ],
                "source_path": sourcePath,
                "context": [
                    "workspaceColor": context.workspaceColor as Any,
                    "colorScheme": context.colorScheme.rawValue,
                    "ghosttyBackgroundGeneration": context.ghosttyBackgroundGeneration,
                ],
                "roles": rolesPayload,
                "warnings": warnings,
            ],
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{\n  \"error\": \"failed to encode theme dump\"\n}"
        }

        return json
    }

    public func resolutionTrace(for role: ThemeRole, context: ThemeContext) -> String {
        switch role.definition.expectedType {
        case .color:
            let expression = active.stringValue(for: role) ?? role.definition.defaultColorExpression ?? "<none>"
            let resolved = (resolve(role, context: context) as NSColor?)?.hexString(includeAlpha: true) ?? "nil"
            return "\(role.definition.path): \(expression) -> \(resolved)"
        case .number:
            let raw = active.numberValue(for: role).map { String($0) } ?? "<default>"
            let resolved = (resolve(role, context: context) as Double?)?.description ?? "nil"
            return "\(role.definition.path): raw=\(raw) -> \(resolved)"
        case .boolean:
            let raw = active.boolValue(for: role).map { $0 ? "true" : "false" } ?? "<default>"
            let resolved = (resolve(role, context: context) as Bool?).map { $0 ? "true" : "false" } ?? "nil"
            return "\(role.definition.path): raw=\(raw) -> \(resolved)"
        }
    }

    public static func currentColorScheme() -> ThemeContext.ColorScheme {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        if match == .darkAqua {
            return .dark
        }
        return .light
    }

    // MARK: - User themes + hot reload (M3)

    public static let defaultLightSlotKey = "theme.active.light"
    public static let defaultDarkSlotKey = "theme.active.dark"

    public var userThemesDirectory: URL {
        ThemeManager.userThemesDirectory(override: pathsOverride)
    }

    public var activeLightName: String {
        ThemeAppStorage.defaults.string(forKey: Self.defaultLightSlotKey) ?? "stage11"
    }

    public var activeDarkName: String {
        ThemeAppStorage.defaults.string(forKey: Self.defaultDarkSlotKey) ?? "stage11"
    }

    public func descriptor(named name: String) -> ThemeDescriptor? {
        themesByName[name]
    }

    public func theme(named name: String) -> C11muxTheme? {
        loadedThemeCache[name]
    }

    public func startWatchingUserThemes() {
        guard watcher == nil else { return }
        let dir = userThemesDirectory

        ensureUserThemesDirectoryExists(at: dir)

        let handler: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.rescanThemes()
                self?.applyActiveSelections()
            }
        }

        let w = ThemeDirectoryWatcher(url: dir, handler: handler)
        w.start()
        self.watcher = w
    }

    public func forceReloadUserThemes() {
        rescanThemes()
        applyActiveSelections()
    }

    public func setActiveTheme(name: String, for scheme: ThemeContext.ColorScheme) -> Bool {
        guard themesByName[name] != nil else {
            ThemeDiagnostics.loader("setActiveTheme: unknown theme '\(name)'")
            return false
        }
        switch scheme {
        case .light:
            ThemeAppStorage.defaults.set(name, forKey: Self.defaultLightSlotKey)
        case .dark:
            ThemeAppStorage.defaults.set(name, forKey: Self.defaultDarkSlotKey)
        }
        applyActiveSelections()
        return true
    }

    public func setActiveThemeForBothSlots(name: String) -> Bool {
        guard themesByName[name] != nil else { return false }
        ThemeAppStorage.defaults.set(name, forKey: Self.defaultLightSlotKey)
        ThemeAppStorage.defaults.set(name, forKey: Self.defaultDarkSlotKey)
        applyActiveSelections()
        return true
    }

    public func clearActiveOverrides() {
        ThemeAppStorage.defaults.removeObject(forKey: Self.defaultLightSlotKey)
        ThemeAppStorage.defaults.removeObject(forKey: Self.defaultDarkSlotKey)
        applyActiveSelections()
    }

    private func rescanThemes() {
        var descriptors: [ThemeDescriptor] = []
        var byName: [String: ThemeDescriptor] = [:]
        var loaded: [String: C11muxTheme] = [:]
        var malformed: [String: String] = [:]

        let builtinDir = pathsOverride?.builtinDirectory ?? Bundle.main.resourceURL?
            .appendingPathComponent(Self.bundledThemesDirectoryName, isDirectory: true)

        if let builtinDir {
            scan(
                directory: builtinDir,
                source: .builtin,
                descriptors: &descriptors,
                byName: &byName,
                loaded: &loaded,
                malformed: &malformed
            )
        }

        // Fallback: ensure `stage11` always enumerated even if the bundled file is missing.
        if byName["stage11"] == nil {
            let stage11 = C11muxTheme.fallbackStage11
            let desc = ThemeDescriptor(identity: stage11.identity, source: .builtin, sourcePath: nil)
            descriptors.append(desc)
            byName["stage11"] = desc
            loaded["stage11"] = stage11
        }

        let userDir = userThemesDirectory
        scan(
            directory: userDir,
            source: .user,
            descriptors: &descriptors,
            byName: &byName,
            loaded: &loaded,
            malformed: &malformed
        )

        self.themesByName = byName
        self.loadedThemeCache = loaded

        for (name, theme) in loaded {
            lastKnownGoodThemes[name] = theme
        }

        self.malformedThemes = malformed

        self.availableThemes = descriptors.sorted { lhs, rhs in
            lhs.identity.displayName.localizedCaseInsensitiveCompare(rhs.identity.displayName) == .orderedAscending
        }
    }

    private func scan(
        directory: URL,
        source: ThemeDescriptor.Source,
        descriptors: inout [ThemeDescriptor],
        byName: inout [String: ThemeDescriptor],
        loaded: inout [String: C11muxTheme],
        malformed: inout [String: String]
    ) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in contents where fileURL.pathExtension.lowercased() == "toml" {
            let name = fileURL.deletingPathExtension().lastPathComponent

            guard let source0 = try? String(contentsOf: fileURL, encoding: .utf8) else {
                malformed[name] = "unable to read file"
                continue
            }

            do {
                let table = try TomlSubsetParser.parse(file: fileURL.path, source: source0)
                let theme = try C11muxTheme.fromToml(table)

                guard theme.identity.name == name else {
                    let msg = "theme identity '\(theme.identity.name)' does not match filename '\(name)'"
                    ThemeDiagnostics.loader(msg)
                    malformed[name] = msg
                    continue
                }

                let descriptor = ThemeDescriptor(
                    identity: theme.identity,
                    source: source,
                    sourcePath: fileURL.path
                )

                if let existing = byName[name], existing.source == .builtin, source == .user {
                    // User wins: remove the built-in entry, insert the user version.
                    descriptors.removeAll(where: { $0.identity.name == name && $0.source == .builtin })
                }

                byName[name] = descriptor
                descriptors.append(descriptor)
                loaded[name] = theme
            } catch {
                let msg = "failed to parse '\(fileURL.lastPathComponent)': \(error)"
                ThemeDiagnostics.loader(msg)
                malformed[name] = String(describing: error)

                if let lastGood = lastKnownGoodThemes[name] {
                    loaded[name] = lastGood
                    let desc = ThemeDescriptor(
                        identity: lastGood.identity,
                        source: source,
                        sourcePath: fileURL.path,
                        warning: "using last-known-good: \(error)"
                    )
                    byName[name] = desc
                    descriptors.append(desc)
                }
            }
        }
    }

    private func applyActiveSelections() {
        let lightName = activeLightName
        let darkName = activeDarkName

        let lightTheme = resolvedTheme(for: lightName)
        let darkTheme = resolvedTheme(for: darkName)

        activeLight = lightTheme
        activeDark = darkTheme

        let currentScheme = Self.currentColorScheme()
        let chosen = currentScheme == .dark ? darkTheme : lightTheme
        active = chosen
        snapshot = ResolvedThemeSnapshot(theme: chosen)
        bumpVersionAndPublishAll()
    }

    private func resolvedTheme(for name: String) -> C11muxTheme {
        if let theme = loadedThemeCache[name] { return theme }
        if let fallback = lastKnownGoodThemes[name] { return fallback }
        return loadedThemeCache["stage11"] ?? C11muxTheme.fallbackStage11
    }

    private func ensureUserThemesDirectoryExists(at url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            let readmePath = url.appendingPathComponent("README.md").path
            if !fm.fileExists(atPath: readmePath),
               let seedURL = Bundle.main.resourceURL?
                   .appendingPathComponent(Self.bundledThemesDirectoryName, isDirectory: true)
                   .appendingPathComponent("README.md"),
               let data = try? Data(contentsOf: seedURL) {
                try? data.write(to: URL(fileURLWithPath: readmePath))
            }
        } catch {
            ThemeDiagnostics.loader("failed to create user themes directory: \(error)")
        }
    }

    public nonisolated static func userThemesDirectory(override: PathsOverride? = nil) -> URL {
        if let override, let dir = override.userThemesDirectory { return dir }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return base.appendingPathComponent(Self.userThemesApplicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
    }

    // MARK: - Internals

    private func handleGhosttyBackgroundChange() {
        ghosttyBackgroundGeneration &+= 1
        snapshot.invalidateCaches()
        version &+= 1

        // Only chrome sections that commonly reference `$ghosttyBackground` are signaled.
        titleBarPublisher.send()
        browserChromePublisher.send()
        markdownChromePublisher.send()
        tabBarPublisher.send()
        dividerPublisher.send()
        framePublisher.send()
        sidebarPublisher.send()
    }

    private func bumpVersionAndPublishAll() {
        version &+= 1
        sidebarPublisher.send()
        titleBarPublisher.send()
        dividerPublisher.send()
        framePublisher.send()
        browserChromePublisher.send()
        markdownChromePublisher.send()
        tabBarPublisher.send()
    }

    private static func loadThemeFromBundle(
        named name: String,
        override: PathsOverride? = nil
    ) -> C11muxTheme? {
        let resourceURL: URL?
        if let override, let dir = override.builtinDirectory {
            resourceURL = dir
        } else {
            resourceURL = Bundle.main.resourceURL?
                .appendingPathComponent(Self.bundledThemesDirectoryName, isDirectory: true)
        }

        guard let resourceURL else {
            return C11muxTheme.fallbackStage11
        }

        let themeURL = resourceURL.appendingPathComponent("\(name).toml")

        guard let source = try? String(contentsOf: themeURL, encoding: .utf8) else {
            if name == "stage11" {
                return C11muxTheme.fallbackStage11
            }
            return nil
        }

        do {
            let table = try TomlSubsetParser.parse(file: themeURL.path, source: source)
            return try C11muxTheme.fromToml(table)
        } catch {
            ThemeDiagnostics.loader("failed to load '\(name).toml': \(error)")
            if name == "stage11" {
                return C11muxTheme.fallbackStage11
            }
            return nil
        }
    }
}

private extension ColorScheme {
    var themeContextColorScheme: ThemeContext.ColorScheme {
        switch self {
        case .dark:
            return .dark
        case .light:
            return .light
        @unknown default:
            return .light
        }
    }
}
