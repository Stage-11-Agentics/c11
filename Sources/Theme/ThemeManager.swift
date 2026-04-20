import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()

    @Published public private(set) var active: C11muxTheme
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

    public var isEnabled: Bool {
        guard !disabledByEnvironment else { return false }
        return !ThemeAppStorage.bool(forKey: ThemeAppStorage.Keys.engineDisabledRuntime, default: false)
    }

    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        self.disabledByEnvironment = ProcessInfo.processInfo.environment["CMUX_DISABLE_THEME_ENGINE"] == "1"

        let loaded = ThemeManager.loadThemeFromBundle(named: "stage11") ?? C11muxTheme.fallbackStage11
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
        guard let loaded = ThemeManager.loadThemeFromBundle(named: name) else {
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

        let payload: [String: Any] = [
            "theme": [
                "identity": [
                    "name": active.identity.name,
                    "display_name": active.identity.displayName,
                    "version": active.identity.version,
                    "schema": active.identity.schema,
                ],
                "source_path": "<bundled>",
                "context": [
                    "workspaceColor": context.workspaceColor as Any,
                    "colorScheme": context.colorScheme.rawValue,
                    "ghosttyBackgroundGeneration": context.ghosttyBackgroundGeneration,
                ],
                "roles": rolesPayload,
                "warnings": [],
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

    private static func loadThemeFromBundle(named name: String) -> C11muxTheme? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return C11muxTheme.fallbackStage11
        }

        let themeURL = resourceURL
            .appendingPathComponent("c11mux-themes", isDirectory: true)
            .appendingPathComponent("\(name).toml")

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
