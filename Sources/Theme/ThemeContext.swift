import Foundation

public struct ThemeContext: Hashable, Sendable {
    public enum ColorScheme: String, Hashable, Sendable, Codable {
        case light
        case dark
    }

    public var workspaceColor: String?
    public var colorScheme: ColorScheme
    public var forceBright: Bool
    public var ghosttyBackgroundGeneration: UInt64
    public var isWindowFocused: Bool
    public var workspaceState: WorkspaceState?
    /// c11 (C11H-197): the theme the hosting window overrides the app theme
    /// with, or nil when the window follows the app theme. `ThemeManager`
    /// resolves against that theme's snapshot; an unknown name falls back to
    /// the app theme.
    public var windowThemeName: String?

    public init(
        workspaceColor: String? = nil,
        colorScheme: ColorScheme,
        forceBright: Bool = false,
        ghosttyBackgroundGeneration: UInt64,
        isWindowFocused: Bool = true,
        workspaceState: WorkspaceState? = nil,
        windowThemeName: String? = nil
    ) {
        self.workspaceColor = workspaceColor
        self.colorScheme = colorScheme
        self.forceBright = forceBright
        self.ghosttyBackgroundGeneration = ghosttyBackgroundGeneration
        self.isWindowFocused = isWindowFocused
        self.workspaceState = workspaceState
        self.windowThemeName = windowThemeName
    }
}

public struct WorkspaceState: Hashable, Sendable, Codable {
    public var environment: String?
    public var risk: String?
    public var mode: String?
    public var tags: [String: String]

    public init(
        environment: String? = nil,
        risk: String? = nil,
        mode: String? = nil,
        tags: [String: String] = [:]
    ) {
        self.environment = environment
        self.risk = risk
        self.mode = mode
        self.tags = tags
    }
}
