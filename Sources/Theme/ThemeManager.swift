import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()
    public nonisolated static let bundledThemesDirectoryName = "c11-themes"
    public nonisolated static let userThemesApplicationSupportDirectoryName = C11Identity.stateDirectoryName

    public struct ThemeDescriptor: Equatable, Sendable {
        public enum Source: String, Equatable, Sendable {
            case builtin
            case user
        }

        public let identity: C11Theme.Identity
        public let source: Source
        public let sourcePath: String?
        public let warning: String?

        public init(identity: C11Theme.Identity, source: Source, sourcePath: String?, warning: String? = nil) {
            self.identity = identity
            self.source = source
            self.sourcePath = sourcePath
            self.warning = warning
        }
    }

    @Published public private(set) var active: C11Theme
    @Published public private(set) var availableThemes: [ThemeDescriptor] = []
    @Published public private(set) var version: UInt64 = 1

    public private(set) var snapshot: ResolvedThemeSnapshot
    /// Where the one active theme's name is stored.
    private let selectionDefaults: UserDefaults

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
    private var loadedThemeCache: [String: C11Theme] = [:]
    private var lastKnownGoodThemes: [String: C11Theme] = [:]
    private var malformedThemes: [String: String] = [:]
    /// c11 (C11H-197): snapshots of the themes windows override the app theme
    /// with, by name. Dropped wherever the active snapshot is rebuilt or its
    /// caches are invalidated, so an override never outlives a reload.
    private var overrideSnapshots: [String: ResolvedThemeSnapshot] = [:]

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
        pathsOverride: PathsOverride? = nil,
        selectionDefaults: UserDefaults = ThemeAppStorage.defaults
    ) {
        self.notificationCenter = notificationCenter
        self.selectionDefaults = selectionDefaults
        self.disabledByEnvironment = ProcessInfo.processInfo.environment["CMUX_DISABLE_THEME_ENGINE"] == "1"
        self.pathsOverride = pathsOverride

        ThemeFontFamily.registerBundledFonts()

        let loaded = ThemeManager.loadThemeFromBundle(named: "stage11", override: pathsOverride)
            ?? C11Theme.fallbackStage11
        self.active = loaded
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
        Self.migrateToOneTheme(selectionDefaults) { [themesByName] in themesByName[$0] != nil }
        applyActiveSelections()
    }

    public func resolve<T>(_ role: ThemeRole, context: ThemeContext) -> T? {
        guard isEnabled else {
            return nil
        }
        let snapshot = self.snapshot(for: context)

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

    // MARK: Schema 2

    /// True when the active theme is schema 2. Such a theme owns the chrome: every
    /// themed path draws from it, as if its `theme.m1b.*` debug flag were on.
    /// Window chrome asks `themeOwnsChrome(windowThemeName:)` instead.
    public var activeThemeOwnsChrome: Bool {
        isEnabled && active.identity.schema >= 2
    }

    /// Whether a themed path is live: its debug flag, or a schema-2 active theme.
    public func themedPathLive(flag: Bool) -> Bool {
        isEnabled && (flag || active.identity.schema >= 2)
    }

    // MARK: Per-window theme (C11H-197)

    /// The snapshot a window with this theme override paints its chrome from: the
    /// named theme's when it is loaded and differs from the app theme, else the
    /// app theme's. An unknown or malformed name silently follows the app theme.
    public func snapshot(windowThemeName: String?) -> ResolvedThemeSnapshot {
        guard let name = windowThemeName, !name.isEmpty, name != active.identity.name else {
            return snapshot
        }
        if let cached = overrideSnapshots[name] { return cached }
        guard let overrideTheme = self.theme(named: name) else { return snapshot }
        let built = ResolvedThemeSnapshot(theme: overrideTheme)
        overrideSnapshots[name] = built
        return built
    }

    /// `snapshot(windowThemeName:)` for the context's window.
    public func snapshot(for context: ThemeContext) -> ResolvedThemeSnapshot {
        snapshot(windowThemeName: context.windowThemeName)
    }

    /// The theme a window with this override paints its chrome with.
    public func theme(windowThemeName: String?) -> C11Theme {
        snapshot(windowThemeName: windowThemeName).theme
    }

    /// The theme the context's window paints its chrome with.
    public func theme(for context: ThemeContext) -> C11Theme {
        snapshot(for: context).theme
    }

    /// The name of the theme a window with this override actually shows: the
    /// override when it resolves, else the app theme's name.
    public func effectiveThemeName(windowThemeName: String?) -> String {
        theme(windowThemeName: windowThemeName).identity.name
    }

    /// `activeThemeOwnsChrome` for a window: true when the theme it shows is schema 2.
    public func themeOwnsChrome(windowThemeName: String?) -> Bool {
        isEnabled && theme(windowThemeName: windowThemeName).identity.schema >= 2
    }

    public func themeOwnsChrome(context: ThemeContext) -> Bool {
        themeOwnsChrome(windowThemeName: context.windowThemeName)
    }

    /// `themedPathLive(flag:)` for a window.
    public func themedPathLive(flag: Bool, windowThemeName: String?) -> Bool {
        isEnabled && (flag || theme(windowThemeName: windowThemeName).identity.schema >= 2)
    }

    public func themedPathLive(flag: Bool, context: ThemeContext) -> Bool {
        themedPathLive(flag: flag, windowThemeName: context.windowThemeName)
    }

    private func dropOverrideSnapshots() {
        if !overrideSnapshots.isEmpty { overrideSnapshots.removeAll() }
    }

    /// A schema-2 value from the context's theme (the window's override, else the
    /// active theme); nil when the theme leaves it unset.
    /// Supports NSColor, Color, Double, CGFloat, Bool, String and ThemeGradient.
    public func style<T>(_ role: ThemeStyleRole, context: ThemeContext) -> T? {
        guard isEnabled else { return nil }
        let snapshot = self.snapshot(for: context)
        if T.self == NSColor.self || T.self == Color.self {
            // A gradient-kind role asked for one colour answers with its first stop.
            let color = role.definition?.kind == .gradient
                ? snapshot.resolveStyleGradient(role, context: context)?.firstColor
                : snapshot.resolveStyleColor(role, context: context)
            if T.self == Color.self { return color.map { Color(nsColor: $0) } as? T }
            return color as? T
        }
        if T.self == ThemeGradient.self {
            if role.definition?.kind == .color {
                return snapshot.resolveStyleColor(role, context: context)
                    .map { ThemeGradient(stops: [.init(color: $0, location: 0)]) } as? T
            }
            return snapshot.resolveStyleGradient(role, context: context) as? T
        }
        if T.self == Double.self {
            return snapshot.resolveStyleNumber(role) as? T
        }
        if T.self == CGFloat.self {
            return snapshot.resolveStyleNumber(role).map { CGFloat($0) } as? T
        }
        if T.self == Bool.self {
            return snapshot.resolveStyleBool(role) as? T
        }
        if T.self == String.self {
            return snapshot.resolveStyleString(role) as? T
        }
        return nil
    }

    /// A resolved `[type.<style>]` of the active theme; `.unset` when the theme sets none of it.
    public func textStyle(_ style: ThemeTextStyleName) -> ThemeTextStyle {
        guard isEnabled else { return .unset }
        return snapshot.resolveTextStyle(style)
    }

    /// A resolved `[type.<style>]` of the theme a window shows.
    public func textStyle(_ style: ThemeTextStyleName, windowThemeName: String?) -> ThemeTextStyle {
        guard isEnabled else { return .unset }
        return snapshot(windowThemeName: windowThemeName).resolveTextStyle(style)
    }

    public func textStyle(_ style: ThemeTextStyleName, context: ThemeContext) -> ThemeTextStyle {
        textStyle(style, windowThemeName: context.windowThemeName)
    }

    public func makeContext(
        workspaceColor: String? = nil,
        colorScheme: ThemeContext.ColorScheme,
        forceBright: Bool = false,
        isWindowFocused: Bool = true,
        workspaceState: WorkspaceState? = nil,
        windowThemeName: String? = nil
    ) -> ThemeContext {
        ThemeContext(
            workspaceColor: workspaceColor,
            colorScheme: colorScheme,
            forceBright: forceBright,
            ghosttyBackgroundGeneration: ghosttyBackgroundGeneration,
            isWindowFocused: isWindowFocused,
            workspaceState: workspaceState,
            windowThemeName: windowThemeName
        )
    }

    public func makeContext(
        workspaceColor: String? = nil,
        colorScheme: ColorScheme,
        forceBright: Bool = false,
        isWindowFocused: Bool = true,
        workspaceState: WorkspaceState? = nil,
        windowThemeName: String? = nil
    ) -> ThemeContext {
        makeContext(
            workspaceColor: workspaceColor,
            colorScheme: colorScheme.themeContextColorScheme,
            forceBright: forceBright,
            isWindowFocused: isWindowFocused,
            workspaceState: workspaceState,
            windowThemeName: windowThemeName
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
    /// divider, frame, and tab-indicator colors re-resolve without
    /// a Ghostty event or theme swap. Bumps `version` so `@ObservedObject`
    /// dependents re-render; per-section publishers fire for narrower subscribers.
    public func invalidateForWorkspaceColorChange() {
        snapshot.invalidateCaches()
        dropOverrideSnapshots()
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

        // Schema-2 roles appear only when the theme sets them (unset keeps today's look).
        for definition in ThemeStyleRoleRegistry.all {
            let role = ThemeStyleRole(definition.path)
            guard let raw = active.styleValue(role) else { continue }
            let expression = raw.string ?? raw.number.map { String($0) } ?? raw.bool.map { $0 ? "true" : "false" }
            var resolved: String? = expression
            switch definition.kind {
            case .color:
                resolved = (style(role, context: context) as NSColor?)
                    .map { $0.hexString(includeAlpha: $0.alphaComponent < 0.999) }
            case .gradient:
                resolved = (style(role, context: context) as ThemeGradient?)?.stops
                    .map { "\($0.color.hexString(includeAlpha: $0.color.alphaComponent < 0.999)) \(Int(($0.location * 100).rounded()))%" }
                    .joined(separator: ", ")
            default:
                break
            }
            rolesPayload[definition.path] = [
                "expression": expression,
                "resolved": resolved,
                "inherited_from": nil,
            ]
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

    /// The scheme the app renders in, for resolving theme values. c11App forces dark.
    public static func currentColorScheme() -> ThemeContext.ColorScheme {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        if match == .darkAqua {
            return .dark
        }
        return .light
    }

    // MARK: - User themes + hot reload (M3)

    /// The one theme c11 shows, day and night. The key keeps its old name so an
    /// upgrade reads the theme the operator already picked.
    public static let activeThemeKey = "theme.active.light"
    /// The retired night theme. Read once by the upgrade, then removed.
    static let retiredNightThemeKey = "theme.active.dark"

    /// The upgrade to one theme keeps the day theme. When the day theme is unset or no
    /// longer exists (one of the themes c11 stopped shipping), an existing night theme
    /// takes its place. Either way the night key is gone afterwards.
    static func migrateToOneTheme(_ defaults: UserDefaults, isAvailable: (String) -> Bool) {
        guard let night = defaults.string(forKey: retiredNightThemeKey) else { return }
        let day = defaults.string(forKey: activeThemeKey)
        if day.map(isAvailable) != true, isAvailable(night) {
            defaults.set(night, forKey: activeThemeKey)
        }
        defaults.removeObject(forKey: retiredNightThemeKey)
    }

    public var userThemesDirectory: URL {
        ThemeManager.userThemesDirectory(override: pathsOverride)
    }

    public var activeThemeName: String {
        selectionDefaults.string(forKey: Self.activeThemeKey) ?? "stage11"
    }

    public func descriptor(named name: String) -> ThemeDescriptor? {
        themesByName[name]
    }

    public func theme(named name: String) -> C11Theme? {
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

    /// Makes `name` the one theme and repaints. False, changing nothing, for an unknown name.
    @discardableResult
    public func setActiveTheme(name: String) -> Bool {
        guard themesByName[name] != nil else {
            ThemeDiagnostics.loader("setActiveTheme: unknown theme '\(name)'")
            return false
        }
        selectionDefaults.set(name, forKey: Self.activeThemeKey)
        applyActiveSelections()
        return true
    }

    public func clearActiveOverrides() {
        selectionDefaults.removeObject(forKey: Self.activeThemeKey)
        selectionDefaults.removeObject(forKey: Self.retiredNightThemeKey)
        applyActiveSelections()
    }

    private func rescanThemes() {
        var descriptors: [ThemeDescriptor] = []
        var byName: [String: ThemeDescriptor] = [:]
        var loaded: [String: C11Theme] = [:]
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
            let stage11 = C11Theme.fallbackStage11
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
        loaded: inout [String: C11Theme],
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
                let theme = try C11Theme.fromToml(table)

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
        let chosen = resolvedTheme(for: activeThemeName)
        active = chosen
        snapshot = ResolvedThemeSnapshot(theme: chosen)
        ThemeFontFamily.resetAvailabilityCache()
        bumpVersionAndPublishAll()
    }

    private func resolvedTheme(for name: String) -> C11Theme {
        if let theme = loadedThemeCache[name] { return theme }
        if let fallback = lastKnownGoodThemes[name] { return fallback }
        return loadedThemeCache["stage11"] ?? C11Theme.fallbackStage11
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
        dropOverrideSnapshots()
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
        // Every caller has just rebuilt the active snapshot or rescanned themes.
        dropOverrideSnapshots()
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
    ) -> C11Theme? {
        let resourceURL: URL?
        if let override, let dir = override.builtinDirectory {
            resourceURL = dir
        } else {
            resourceURL = Bundle.main.resourceURL?
                .appendingPathComponent(Self.bundledThemesDirectoryName, isDirectory: true)
        }

        guard let resourceURL else {
            return C11Theme.fallbackStage11
        }

        let themeURL = resourceURL.appendingPathComponent("\(name).toml")

        guard let source = try? String(contentsOf: themeURL, encoding: .utf8) else {
            if name == "stage11" {
                return C11Theme.fallbackStage11
            }
            return nil
        }

        do {
            let table = try TomlSubsetParser.parse(file: themeURL.path, source: source)
            return try C11Theme.fromToml(table)
        } catch {
            ThemeDiagnostics.loader("failed to load '\(name).toml': \(error)")
            if name == "stage11" {
                return C11Theme.fallbackStage11
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
