import Foundation

public enum ThemeRoleValueType: String, Codable, Sendable {
    case color
    case number
    case boolean
}

public enum ThemeSection: String, Codable, CaseIterable, Sendable {
    case sidebar
    case titleBar
    case divider
    case frame
    case browserChrome
    case markdownChrome
    case tabBar
    case behavior
}

public enum ThemeRoleDefaultValue: Codable, Equatable, Sendable {
    case colorExpression(String)
    case number(Double)
    case boolean(Bool)
}

public struct ThemeRoleDefinition: Codable, Equatable, Sendable {
    public let path: String
    public let expectedType: ThemeRoleValueType
    public let owningSurface: String
    public let section: ThemeSection
    public let defaultValue: ThemeRoleDefaultValue

    public init(
        path: String,
        expectedType: ThemeRoleValueType,
        owningSurface: String,
        section: ThemeSection,
        defaultValue: ThemeRoleDefaultValue
    ) {
        self.path = path
        self.expectedType = expectedType
        self.owningSurface = owningSurface
        self.section = section
        self.defaultValue = defaultValue
    }

    public var defaultColorExpression: String? {
        guard case let .colorExpression(value) = defaultValue else { return nil }
        return value
    }

    public var defaultNumber: Double? {
        guard case let .number(value) = defaultValue else { return nil }
        return value
    }

    public var defaultBoolean: Bool? {
        guard case let .boolean(value) = defaultValue else { return nil }
        return value
    }
}

public enum ThemeRole: String, CaseIterable, Codable, Sendable {
    case sidebar_activeTabFill
    case titleBar_background
    case dividers_color
    case dividers_thicknessPt
    case windowFrame_color
    case windowFrame_thicknessPt
    case windowFrame_inactiveOpacity
    case windowFrame_unfocusedOpacity
    case browserChrome_background
    case browserChrome_omnibarFill
    case markdownChrome_background
    case tabBar_background
    case tabBar_activeFill
    case tabBar_divider
    case tabBar_activeIndicator
    case sidebar_tintBase
    case sidebar_tintBaseOpacity
    case sidebar_tintOverlay
    case sidebar_activeTabFillFallback
    case sidebar_activeTabRail
    case sidebar_activeTabRailFallback
    case sidebar_activeTabRailOpacity
    case sidebar_inactiveTabCustomOpacity
    case sidebar_inactiveTabMultiSelectOpacity
    case sidebar_badgeFill
    case sidebar_borderLeading
    case titleBar_backgroundOpacity
    case titleBar_foreground
    case titleBar_foregroundSecondary
    case titleBar_borderBottom
    case behavior_animateWorkspaceCrossfade

    public var definition: ThemeRoleDefinition {
        ThemeRoleRegistry.definition(for: self)
    }
}

public enum ThemeRoleRegistry {
    public static func definition(for role: ThemeRole) -> ThemeRoleDefinition {
        switch role {
        case .sidebar_activeTabFill:
            return .init(
                path: "chrome.sidebar.activeTabFill",
                expectedType: .color,
                owningSurface: "ContentView.TabItemView",
                section: .sidebar,
                defaultValue: .colorExpression("$workspaceColor")
            )
        case .titleBar_background:
            return .init(
                path: "chrome.titleBar.background",
                expectedType: .color,
                owningSurface: "SurfaceTitleBarView, ContentView.customTitlebar",
                section: .titleBar,
                defaultValue: .colorExpression("$surface")
            )
        case .dividers_color:
            return .init(
                path: "chrome.dividers.color",
                expectedType: .color,
                owningSurface: "Workspace.bonsplitAppearance",
                section: .divider,
                defaultValue: .colorExpression("$workspaceColor.mix($background, 0.65)")
            )
        case .dividers_thicknessPt:
            return .init(
                path: "chrome.dividers.thicknessPt",
                expectedType: .number,
                owningSurface: "Workspace.bonsplitAppearance",
                section: .divider,
                defaultValue: .number(1.0)
            )
        case .windowFrame_color:
            return .init(
                path: "chrome.windowFrame.color",
                expectedType: .color,
                owningSurface: "WorkspaceFrame",
                section: .frame,
                defaultValue: .colorExpression("$workspaceColor")
            )
        case .windowFrame_thicknessPt:
            return .init(
                path: "chrome.windowFrame.thicknessPt",
                expectedType: .number,
                owningSurface: "WorkspaceFrame",
                section: .frame,
                defaultValue: .number(1.5)
            )
        case .windowFrame_inactiveOpacity:
            return .init(
                path: "chrome.windowFrame.inactiveOpacity",
                expectedType: .number,
                owningSurface: "WorkspaceFrame",
                section: .frame,
                defaultValue: .number(0.25)
            )
        case .windowFrame_unfocusedOpacity:
            return .init(
                path: "chrome.windowFrame.unfocusedOpacity",
                expectedType: .number,
                owningSurface: "WorkspaceFrame",
                section: .frame,
                defaultValue: .number(0.6)
            )
        case .browserChrome_background:
            return .init(
                path: "chrome.browserChrome.background",
                expectedType: .color,
                owningSurface: "BrowserPanelView",
                section: .browserChrome,
                defaultValue: .colorExpression("$ghosttyBackground")
            )
        case .browserChrome_omnibarFill:
            return .init(
                path: "chrome.browserChrome.omnibarFill",
                expectedType: .color,
                owningSurface: "BrowserPanelView",
                section: .browserChrome,
                defaultValue: .colorExpression("$surface.mix($background, 0.15)")
            )
        case .markdownChrome_background:
            return .init(
                path: "chrome.markdownChrome.background",
                expectedType: .color,
                owningSurface: "MarkdownPanelView",
                section: .markdownChrome,
                defaultValue: .colorExpression("$background")
            )
        case .tabBar_background:
            return .init(
                path: "chrome.tabBar.background",
                expectedType: .color,
                owningSurface: "Workspace.bonsplitAppearance",
                section: .tabBar,
                defaultValue: .colorExpression("$ghosttyBackground")
            )
        case .tabBar_activeFill:
            return .init(
                path: "chrome.tabBar.activeFill",
                expectedType: .color,
                owningSurface: "Workspace.bonsplitAppearance",
                section: .tabBar,
                defaultValue: .colorExpression("$ghosttyBackground.lighten(0.04)")
            )
        case .tabBar_divider:
            return .init(
                path: "chrome.tabBar.divider",
                expectedType: .color,
                owningSurface: "Workspace.bonsplitAppearance",
                section: .tabBar,
                defaultValue: .colorExpression("$separator")
            )
        case .tabBar_activeIndicator:
            return .init(
                path: "chrome.tabBar.activeIndicator",
                expectedType: .color,
                owningSurface: "Workspace.bonsplitAppearance",
                section: .tabBar,
                defaultValue: .colorExpression("$workspaceColor")
            )
        case .sidebar_tintBase:
            return .init(
                path: "chrome.sidebar.tintBase",
                expectedType: .color,
                owningSurface: "ContentView.sidebar",
                section: .sidebar,
                defaultValue: .colorExpression("$background")
            )
        case .sidebar_tintBaseOpacity:
            return .init(
                path: "chrome.sidebar.tintBaseOpacity",
                expectedType: .number,
                owningSurface: "ContentView.sidebar",
                section: .sidebar,
                defaultValue: .number(0.18)
            )
        case .sidebar_tintOverlay:
            return .init(
                path: "chrome.sidebar.tintOverlay",
                expectedType: .color,
                owningSurface: "ContentView.sidebar",
                section: .sidebar,
                defaultValue: .colorExpression("#00000000")
            )
        case .sidebar_activeTabFillFallback:
            return .init(
                path: "chrome.sidebar.activeTabFillFallback",
                expectedType: .color,
                owningSurface: "ContentView.TabItemView",
                section: .sidebar,
                defaultValue: .colorExpression("$surface")
            )
        case .sidebar_activeTabRail:
            return .init(
                path: "chrome.sidebar.activeTabRail",
                expectedType: .color,
                owningSurface: "ContentView.TabItemView",
                section: .sidebar,
                defaultValue: .colorExpression("$workspaceColor")
            )
        case .sidebar_activeTabRailFallback:
            return .init(
                path: "chrome.sidebar.activeTabRailFallback",
                expectedType: .color,
                owningSurface: "ContentView.TabItemView",
                section: .sidebar,
                defaultValue: .colorExpression("$accent")
            )
        case .sidebar_activeTabRailOpacity:
            return .init(
                path: "chrome.sidebar.activeTabRailOpacity",
                expectedType: .number,
                owningSurface: "ContentView.TabItemView",
                section: .sidebar,
                defaultValue: .number(0.95)
            )
        case .sidebar_inactiveTabCustomOpacity:
            return .init(
                path: "chrome.sidebar.inactiveTabCustomOpacity",
                expectedType: .number,
                owningSurface: "ContentView.TabItemView",
                section: .sidebar,
                defaultValue: .number(0.70)
            )
        case .sidebar_inactiveTabMultiSelectOpacity:
            return .init(
                path: "chrome.sidebar.inactiveTabMultiSelectOpacity",
                expectedType: .number,
                owningSurface: "ContentView.TabItemView",
                section: .sidebar,
                defaultValue: .number(0.35)
            )
        case .sidebar_badgeFill:
            return .init(
                path: "chrome.sidebar.badgeFill",
                expectedType: .color,
                owningSurface: "ContentView.TabItemView",
                section: .sidebar,
                defaultValue: .colorExpression("$accent")
            )
        case .sidebar_borderLeading:
            return .init(
                path: "chrome.sidebar.borderLeading",
                expectedType: .color,
                owningSurface: "ContentView.sidebar",
                section: .sidebar,
                defaultValue: .colorExpression("$separator")
            )
        case .titleBar_backgroundOpacity:
            return .init(
                path: "chrome.titleBar.backgroundOpacity",
                expectedType: .number,
                owningSurface: "SurfaceTitleBarView, ContentView.customTitlebar",
                section: .titleBar,
                defaultValue: .number(0.85)
            )
        case .titleBar_foreground:
            return .init(
                path: "chrome.titleBar.foreground",
                expectedType: .color,
                owningSurface: "SurfaceTitleBarView",
                section: .titleBar,
                defaultValue: .colorExpression("$foreground")
            )
        case .titleBar_foregroundSecondary:
            return .init(
                path: "chrome.titleBar.foregroundSecondary",
                expectedType: .color,
                owningSurface: "SurfaceTitleBarView",
                section: .titleBar,
                defaultValue: .colorExpression("$foregroundSecondary")
            )
        case .titleBar_borderBottom:
            return .init(
                path: "chrome.titleBar.borderBottom",
                expectedType: .color,
                owningSurface: "SurfaceTitleBarView, ContentView.customTitlebar",
                section: .titleBar,
                defaultValue: .colorExpression("$separator")
            )
        case .behavior_animateWorkspaceCrossfade:
            return .init(
                path: "behavior.animateWorkspaceCrossfade",
                expectedType: .boolean,
                owningSurface: "WorkspaceContentView",
                section: .behavior,
                defaultValue: .boolean(false)
            )
        }
    }
}
