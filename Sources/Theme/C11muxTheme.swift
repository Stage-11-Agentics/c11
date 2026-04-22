import Foundation

public enum ThemeLoadError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingKey(String)
    case invalidType(path: String, expected: String)
    case invalidHex(path: String, value: String)
    case reservedMagicVariableOverride(String)
    case variableExpression(name: String, message: String)
    case variableCycle([String])
    case schemaMismatch(Int)

    public var description: String {
        switch self {
        case let .missingKey(key):
            return "Missing required key: \(key)"
        case let .invalidType(path, expected):
            return "Invalid type at \(path); expected \(expected)"
        case let .invalidHex(path, value):
            return "Invalid hex at \(path): \(value)"
        case let .reservedMagicVariableOverride(name):
            return "Reserved magic variable cannot be overridden: \(name)"
        case let .variableExpression(name, message):
            return "Invalid variable expression for \(name): \(message)"
        case let .variableCycle(cycle):
            return "Variable cycle detected: \(cycle.joined(separator: " -> "))"
        case let .schemaMismatch(schema):
            return "Unsupported theme schema: \(schema)"
        }
    }
}

public struct C11muxTheme: Codable, Equatable, Sendable {
    public struct Identity: Codable, Equatable, Sendable {
        public var name: String
        public var displayName: String
        public var author: String
        public var version: String
        public var schema: Int

        enum CodingKeys: String, CodingKey {
            case name
            case displayName = "display_name"
            case author
            case version
            case schema
        }

        public init(name: String, displayName: String, author: String, version: String, schema: Int) {
            self.name = name
            self.displayName = displayName
            self.author = author
            self.version = version
            self.schema = schema
        }
    }

    public struct ChromeSections: Codable, Equatable, Sendable {
        public struct WindowFrame: Codable, Equatable, Sendable {
            public var color: String?
            public var thicknessPt: Double?
            public var inactiveOpacity: Double?
            public var unfocusedOpacity: Double?

            public init(
                color: String? = nil,
                thicknessPt: Double? = nil,
                inactiveOpacity: Double? = nil,
                unfocusedOpacity: Double? = nil
            ) {
                self.color = color
                self.thicknessPt = thicknessPt
                self.inactiveOpacity = inactiveOpacity
                self.unfocusedOpacity = unfocusedOpacity
            }
        }

        public struct Sidebar: Codable, Equatable, Sendable {
            public var tintOverlay: String?
            public var tintBase: String?
            public var tintBaseOpacity: Double?
            public var activeTabFill: String?
            public var activeTabFillFallback: String?
            public var activeTabRail: String?
            public var activeTabRailFallback: String?
            public var activeTabRailOpacity: Double?
            public var inactiveTabCustomOpacity: Double?
            public var inactiveTabMultiSelectOpacity: Double?
            public var badgeFill: String?
            public var borderLeading: String?

            public init(
                tintOverlay: String? = nil,
                tintBase: String? = nil,
                tintBaseOpacity: Double? = nil,
                activeTabFill: String? = nil,
                activeTabFillFallback: String? = nil,
                activeTabRail: String? = nil,
                activeTabRailFallback: String? = nil,
                activeTabRailOpacity: Double? = nil,
                inactiveTabCustomOpacity: Double? = nil,
                inactiveTabMultiSelectOpacity: Double? = nil,
                badgeFill: String? = nil,
                borderLeading: String? = nil
            ) {
                self.tintOverlay = tintOverlay
                self.tintBase = tintBase
                self.tintBaseOpacity = tintBaseOpacity
                self.activeTabFill = activeTabFill
                self.activeTabFillFallback = activeTabFillFallback
                self.activeTabRail = activeTabRail
                self.activeTabRailFallback = activeTabRailFallback
                self.activeTabRailOpacity = activeTabRailOpacity
                self.inactiveTabCustomOpacity = inactiveTabCustomOpacity
                self.inactiveTabMultiSelectOpacity = inactiveTabMultiSelectOpacity
                self.badgeFill = badgeFill
                self.borderLeading = borderLeading
            }
        }

        public struct Dividers: Codable, Equatable, Sendable {
            public var color: String?
            public var thicknessPt: Double?

            public init(color: String? = nil, thicknessPt: Double? = nil) {
                self.color = color
                self.thicknessPt = thicknessPt
            }
        }

        public struct TitleBar: Codable, Equatable, Sendable {
            public var background: String?
            public var backgroundOpacity: Double?
            public var foreground: String?
            public var foregroundSecondary: String?
            public var borderBottom: String?

            public init(
                background: String? = nil,
                backgroundOpacity: Double? = nil,
                foreground: String? = nil,
                foregroundSecondary: String? = nil,
                borderBottom: String? = nil
            ) {
                self.background = background
                self.backgroundOpacity = backgroundOpacity
                self.foreground = foreground
                self.foregroundSecondary = foregroundSecondary
                self.borderBottom = borderBottom
            }
        }

        public struct TabBar: Codable, Equatable, Sendable {
            public var background: String?
            public var activeFill: String?
            public var divider: String?
            public var activeIndicator: String?

            public init(
                background: String? = nil,
                activeFill: String? = nil,
                divider: String? = nil,
                activeIndicator: String? = nil
            ) {
                self.background = background
                self.activeFill = activeFill
                self.divider = divider
                self.activeIndicator = activeIndicator
            }
        }

        public struct BrowserChrome: Codable, Equatable, Sendable {
            public var background: String?
            public var omnibarFill: String?

            public init(background: String? = nil, omnibarFill: String? = nil) {
                self.background = background
                self.omnibarFill = omnibarFill
            }
        }

        public struct MarkdownChrome: Codable, Equatable, Sendable {
            public var background: String?

            public init(background: String? = nil) {
                self.background = background
            }
        }

        public var windowFrame: WindowFrame
        public var sidebar: Sidebar
        public var dividers: Dividers
        public var titleBar: TitleBar
        public var tabBar: TabBar
        public var browserChrome: BrowserChrome
        public var markdownChrome: MarkdownChrome

        public init(
            windowFrame: WindowFrame = .init(),
            sidebar: Sidebar = .init(),
            dividers: Dividers = .init(),
            titleBar: TitleBar = .init(),
            tabBar: TabBar = .init(),
            browserChrome: BrowserChrome = .init(),
            markdownChrome: MarkdownChrome = .init()
        ) {
            self.windowFrame = windowFrame
            self.sidebar = sidebar
            self.dividers = dividers
            self.titleBar = titleBar
            self.tabBar = tabBar
            self.browserChrome = browserChrome
            self.markdownChrome = markdownChrome
        }
    }

    public struct Behavior: Codable, Equatable, Sendable {
        public var animateWorkspaceCrossfade: Bool?

        public init(animateWorkspaceCrossfade: Bool? = nil) {
            self.animateWorkspaceCrossfade = animateWorkspaceCrossfade
        }
    }

    public var identity: Identity
    public var palette: [String: String]
    public var variables: [String: String]
    public var chrome: ChromeSections
    public var behavior: Behavior

    public init(
        identity: Identity,
        palette: [String: String],
        variables: [String: String],
        chrome: ChromeSections,
        behavior: Behavior = .init()
    ) {
        self.identity = identity
        self.palette = palette
        self.variables = variables
        self.chrome = chrome
        self.behavior = behavior
    }

    public static var fallbackStage11: C11muxTheme {
        C11muxTheme(
            identity: .init(
                name: "stage11",
                displayName: "Stage 11",
                author: "Stage 11 Agentics",
                version: "0.01.001",
                schema: 1
            ),
            palette: [
                "void": "#0A0C0F",
                "surface": "#121519",
                "gold": "#C4A561",
                "fog": "#2A2F36",
                "text": "#E9EAEB",
                "textDim": "#8A8F96",
            ],
            variables: [
                "background": "$palette.void",
                "surface": "$palette.surface",
                "foreground": "$palette.text",
                "foregroundSecondary": "$palette.textDim",
                "accent": "$palette.gold",
                "separator": "$palette.fog",
                "workspaceColor": "$workspaceColor",
                "ghosttyBackground": "$ghosttyBackground",
            ],
            chrome: .init(
                windowFrame: .init(
                    color: "$workspaceColor",
                    thicknessPt: 1.5,
                    inactiveOpacity: 0.25,
                    unfocusedOpacity: 0.6
                ),
                sidebar: .init(
                    tintOverlay: "#00000000",
                    tintBase: "$background",
                    tintBaseOpacity: 0.18,
                    activeTabFill: "$workspaceColor",
                    activeTabFillFallback: "$surface",
                    activeTabRail: "$workspaceColor",
                    activeTabRailFallback: "$accent",
                    activeTabRailOpacity: 0.95,
                    inactiveTabCustomOpacity: 0.70,
                    inactiveTabMultiSelectOpacity: 0.35,
                    badgeFill: "$accent",
                    borderLeading: "$separator"
                ),
                dividers: .init(color: "$workspaceColor.mix($background, 0.65)", thicknessPt: 1.0),
                titleBar: .init(
                    background: "$surface",
                    backgroundOpacity: 0.85,
                    foreground: "$foreground",
                    foregroundSecondary: "$foregroundSecondary",
                    borderBottom: "$separator"
                ),
                tabBar: .init(
                    background: "$ghosttyBackground",
                    activeFill: "$ghosttyBackground.lighten(0.04)",
                    divider: "$separator",
                    activeIndicator: "$workspaceColor"
                ),
                browserChrome: .init(
                    background: "$ghosttyBackground",
                    omnibarFill: "$surface.mix($background, 0.15)"
                ),
                markdownChrome: .init(background: "$background")
            ),
            behavior: .init(animateWorkspaceCrossfade: false)
        )
    }

    public static func fromToml(_ table: TomlTable) throws -> C11muxTheme {
        let identity = try parseIdentity(from: table)
        guard identity.schema == 1 else {
            throw ThemeLoadError.schemaMismatch(identity.schema)
        }

        let paletteTable = try requiredTable(at: ["palette"], in: table)
        let palette = try parseStringMap(at: "palette", table: paletteTable, validateHex: true)

        let variablesTable = try requiredTable(at: ["variables"], in: table)
        let variables = try parseStringMap(at: "variables", table: variablesTable, validateHex: false)

        try validateReservedMagicVariables(variables)
        try validateVariableExpressions(variables)

        let chromeTable = try optionalTable(at: ["chrome"], in: table) ?? [:]
        let behaviorTable = try optionalTable(at: ["behavior"], in: table) ?? [:]

        return C11muxTheme(
            identity: identity,
            palette: palette,
            variables: variables,
            chrome: try parseChrome(chromeTable),
            behavior: try parseBehavior(behaviorTable)
        )
    }

    public func stringValue(for role: ThemeRole) -> String? {
        switch role {
        case .windowFrame_color:
            return chrome.windowFrame.color
        case .sidebar_tintOverlay:
            return chrome.sidebar.tintOverlay
        case .sidebar_tintBase:
            return chrome.sidebar.tintBase
        case .sidebar_activeTabFill:
            return chrome.sidebar.activeTabFill
        case .sidebar_activeTabFillFallback:
            return chrome.sidebar.activeTabFillFallback
        case .sidebar_activeTabRail:
            return chrome.sidebar.activeTabRail
        case .sidebar_activeTabRailFallback:
            return chrome.sidebar.activeTabRailFallback
        case .sidebar_badgeFill:
            return chrome.sidebar.badgeFill
        case .sidebar_borderLeading:
            return chrome.sidebar.borderLeading
        case .dividers_color:
            return chrome.dividers.color
        case .titleBar_background:
            return chrome.titleBar.background
        case .titleBar_foreground:
            return chrome.titleBar.foreground
        case .titleBar_foregroundSecondary:
            return chrome.titleBar.foregroundSecondary
        case .titleBar_borderBottom:
            return chrome.titleBar.borderBottom
        case .tabBar_background:
            return chrome.tabBar.background
        case .tabBar_activeFill:
            return chrome.tabBar.activeFill
        case .tabBar_divider:
            return chrome.tabBar.divider
        case .tabBar_activeIndicator:
            return chrome.tabBar.activeIndicator
        case .browserChrome_background:
            return chrome.browserChrome.background
        case .browserChrome_omnibarFill:
            return chrome.browserChrome.omnibarFill
        case .markdownChrome_background:
            return chrome.markdownChrome.background
        default:
            return nil
        }
    }

    public func numberValue(for role: ThemeRole) -> Double? {
        switch role {
        case .windowFrame_thicknessPt:
            return chrome.windowFrame.thicknessPt
        case .windowFrame_inactiveOpacity:
            return chrome.windowFrame.inactiveOpacity
        case .windowFrame_unfocusedOpacity:
            return chrome.windowFrame.unfocusedOpacity
        case .sidebar_tintBaseOpacity:
            return chrome.sidebar.tintBaseOpacity
        case .sidebar_activeTabRailOpacity:
            return chrome.sidebar.activeTabRailOpacity
        case .sidebar_inactiveTabCustomOpacity:
            return chrome.sidebar.inactiveTabCustomOpacity
        case .sidebar_inactiveTabMultiSelectOpacity:
            return chrome.sidebar.inactiveTabMultiSelectOpacity
        case .dividers_thicknessPt:
            return chrome.dividers.thicknessPt
        case .titleBar_backgroundOpacity:
            return chrome.titleBar.backgroundOpacity
        default:
            return nil
        }
    }

    public func boolValue(for role: ThemeRole) -> Bool? {
        switch role {
        case .behavior_animateWorkspaceCrossfade:
            return behavior.animateWorkspaceCrossfade
        default:
            return nil
        }
    }

    private static func parseIdentity(from root: TomlTable) throws -> Identity {
        let table = try requiredTable(at: ["identity"], in: root)

        let name = try requiredString("identity.name", in: table, key: "name")
        let displayName = try requiredString("identity.display_name", in: table, key: "display_name")
        let author = try requiredString("identity.author", in: table, key: "author")
        let version = try requiredString("identity.version", in: table, key: "version")
        let schema = try requiredInt("identity.schema", in: table, key: "schema")

        return Identity(
            name: name,
            displayName: displayName,
            author: author,
            version: version,
            schema: schema
        )
    }

    private static func parseChrome(_ table: TomlTable) throws -> ChromeSections {
        let windowFrame = try optionalTable(at: ["windowFrame"], in: table) ?? [:]
        let sidebar = try optionalTable(at: ["sidebar"], in: table) ?? [:]
        let dividers = try optionalTable(at: ["dividers"], in: table) ?? [:]
        let titleBar = try optionalTable(at: ["titleBar"], in: table) ?? [:]
        let tabBar = try optionalTable(at: ["tabBar"], in: table) ?? [:]
        let browserChrome = try optionalTable(at: ["browserChrome"], in: table) ?? [:]
        let markdownChrome = try optionalTable(at: ["markdownChrome"], in: table) ?? [:]

        return ChromeSections(
            windowFrame: .init(
                color: try themedString("chrome.windowFrame.color", in: windowFrame, key: "color"),
                thicknessPt: try optionalNumber("chrome.windowFrame.thicknessPt", in: windowFrame, key: "thicknessPt"),
                inactiveOpacity: try optionalNumber("chrome.windowFrame.inactiveOpacity", in: windowFrame, key: "inactiveOpacity"),
                unfocusedOpacity: try optionalNumber("chrome.windowFrame.unfocusedOpacity", in: windowFrame, key: "unfocusedOpacity")
            ),
            sidebar: .init(
                tintOverlay: try themedString("chrome.sidebar.tintOverlay", in: sidebar, key: "tintOverlay"),
                tintBase: try themedString("chrome.sidebar.tintBase", in: sidebar, key: "tintBase"),
                tintBaseOpacity: try optionalNumber("chrome.sidebar.tintBaseOpacity", in: sidebar, key: "tintBaseOpacity"),
                activeTabFill: try themedString("chrome.sidebar.activeTabFill", in: sidebar, key: "activeTabFill"),
                activeTabFillFallback: try themedString("chrome.sidebar.activeTabFillFallback", in: sidebar, key: "activeTabFillFallback"),
                activeTabRail: try themedString("chrome.sidebar.activeTabRail", in: sidebar, key: "activeTabRail"),
                activeTabRailFallback: try themedString("chrome.sidebar.activeTabRailFallback", in: sidebar, key: "activeTabRailFallback"),
                activeTabRailOpacity: try optionalNumber("chrome.sidebar.activeTabRailOpacity", in: sidebar, key: "activeTabRailOpacity"),
                inactiveTabCustomOpacity: try optionalNumber("chrome.sidebar.inactiveTabCustomOpacity", in: sidebar, key: "inactiveTabCustomOpacity"),
                inactiveTabMultiSelectOpacity: try optionalNumber("chrome.sidebar.inactiveTabMultiSelectOpacity", in: sidebar, key: "inactiveTabMultiSelectOpacity"),
                badgeFill: try themedString("chrome.sidebar.badgeFill", in: sidebar, key: "badgeFill"),
                borderLeading: try themedString("chrome.sidebar.borderLeading", in: sidebar, key: "borderLeading")
            ),
            dividers: .init(
                color: try themedString("chrome.dividers.color", in: dividers, key: "color"),
                thicknessPt: try optionalNumber("chrome.dividers.thicknessPt", in: dividers, key: "thicknessPt")
            ),
            titleBar: .init(
                background: try themedString("chrome.titleBar.background", in: titleBar, key: "background"),
                backgroundOpacity: try optionalNumber("chrome.titleBar.backgroundOpacity", in: titleBar, key: "backgroundOpacity"),
                foreground: try themedString("chrome.titleBar.foreground", in: titleBar, key: "foreground"),
                foregroundSecondary: try themedString("chrome.titleBar.foregroundSecondary", in: titleBar, key: "foregroundSecondary"),
                borderBottom: try themedString("chrome.titleBar.borderBottom", in: titleBar, key: "borderBottom")
            ),
            tabBar: .init(
                background: try themedString("chrome.tabBar.background", in: tabBar, key: "background"),
                activeFill: try themedString("chrome.tabBar.activeFill", in: tabBar, key: "activeFill"),
                divider: try themedString("chrome.tabBar.divider", in: tabBar, key: "divider"),
                activeIndicator: try themedString("chrome.tabBar.activeIndicator", in: tabBar, key: "activeIndicator")
            ),
            browserChrome: .init(
                background: try themedString("chrome.browserChrome.background", in: browserChrome, key: "background"),
                omnibarFill: try themedString("chrome.browserChrome.omnibarFill", in: browserChrome, key: "omnibarFill")
            ),
            markdownChrome: .init(
                background: try themedString("chrome.markdownChrome.background", in: markdownChrome, key: "background")
            )
        )
    }

    private static func parseBehavior(_ table: TomlTable) throws -> Behavior {
        Behavior(
            animateWorkspaceCrossfade: try optionalBool(
                "behavior.animateWorkspaceCrossfade",
                in: table,
                key: "animateWorkspaceCrossfade"
            )
        )
    }

    private static func parseStringMap(
        at path: String,
        table: TomlTable,
        validateHex: Bool
    ) throws -> [String: String] {
        var output: [String: String] = [:]

        for (key, value) in table {
            guard case let .string(stringValue) = value else {
                throw ThemeLoadError.invalidType(path: "\(path).\(key)", expected: "string")
            }
            if validateHex, !isValidHexColor(stringValue) {
                throw ThemeLoadError.invalidHex(path: "\(path).\(key)", value: stringValue)
            }
            output[key] = stringValue
        }

        return output
    }

    private static func validateReservedMagicVariables(_ variables: [String: String]) throws {
        let reserved: [String: String] = [
            "workspaceColor": "$workspaceColor",
            "ghosttyBackground": "$ghosttyBackground",
        ]

        for (name, requiredExpression) in reserved {
            guard let value = variables[name] else { continue }
            if value != requiredExpression {
                throw ThemeLoadError.reservedMagicVariableOverride(name)
            }
        }
    }

    private static func validateVariableExpressions(_ variables: [String: String]) throws {
        var dependencies: [String: Set<String>] = [:]

        for (name, expression) in variables {
            let ast: ThemedValueAST
            do {
                ast = try ThemedValueParser.parse(expression)
            } catch {
                throw ThemeLoadError.variableExpression(name: name, message: String(describing: error))
            }

            let deps = extractVariableDependencies(from: ast, variables: variables)
            dependencies[name] = Set(deps)
        }

        enum VisitState {
            case visiting
            case visited
        }

        var visited: [String: VisitState] = [:]

        func dfs(_ key: String, trail: [String]) throws {
            if visited[key] == .visited {
                return
            }
            if visited[key] == .visiting {
                let cycleStart = trail.firstIndex(of: key) ?? 0
                let cycle = Array(trail[cycleStart...]) + [key]
                throw ThemeLoadError.variableCycle(cycle)
            }

            visited[key] = .visiting
            let nextTrail = trail + [key]
            for dependency in dependencies[key] ?? [] {
                try dfs(dependency, trail: nextTrail)
            }
            visited[key] = .visited
        }

        for key in variables.keys.sorted() {
            try dfs(key, trail: [])
        }
    }

    private static func extractVariableDependencies(
        from ast: ThemedValueAST,
        variables: [String: String]
    ) -> [String] {
        switch ast {
        case let .variableRef(path):
            guard !path.isEmpty else { return [] }

            if path.first == "palette" || path.first == "workspaceColor" || path.first == "ghosttyBackground" {
                return []
            }

            let joined = path.joined(separator: ".")
            if variables[joined] != nil {
                return [joined]
            }
            if let first = path.first, variables[first] != nil {
                return [first]
            }
            return []

        case let .modifier(_, args):
            return args.flatMap { extractVariableDependencies(from: $0, variables: variables) }

        case .hex, .structured:
            return []
        }
    }

    private static func isValidHexColor(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return false }

        let body = String(trimmed.dropFirst())
        guard body.count == 6 || body.count == 8 else { return false }

        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return body.unicodeScalars.allSatisfy { hexDigits.contains($0) }
    }

    private static func requiredTable(at path: [String], in root: TomlTable) throws -> TomlTable {
        guard let table = try optionalTable(at: path, in: root) else {
            throw ThemeLoadError.missingKey(path.joined(separator: "."))
        }
        return table
    }

    private static func optionalTable(at path: [String], in root: TomlTable) throws -> TomlTable? {
        guard !path.isEmpty else { return root }

        var cursor = root
        for (index, segment) in path.enumerated() {
            guard let next = cursor[segment] else {
                return nil
            }

            guard case let .table(table) = next else {
                throw ThemeLoadError.invalidType(path: path.joined(separator: "."), expected: "table")
            }

            if index == path.count - 1 {
                return table
            }

            cursor = table
        }

        return nil
    }

    private static func requiredString(_ path: String, in table: TomlTable, key: String) throws -> String {
        guard let value = try optionalString(path, in: table, key: key) else {
            throw ThemeLoadError.missingKey(path)
        }
        return value
    }

    private static func optionalString(_ path: String, in table: TomlTable, key: String) throws -> String? {
        guard let value = table[key] else { return nil }

        guard case let .string(stringValue) = value else {
            throw ThemeLoadError.invalidType(path: path, expected: "string")
        }

        return stringValue
    }

    private static func themedString(_ path: String, in table: TomlTable, key: String) throws -> String? {
        guard let value = table[key] else { return nil }

        switch value {
        case let .string(stringValue):
            return stringValue
        case .null:
            return nil
        case let .table(entry):
            if let enabled = entry["enabled"] {
                guard case let .boolean(enabledValue) = enabled else {
                    throw ThemeLoadError.invalidType(path: "\(path).enabled", expected: "boolean")
                }
                if !enabledValue {
                    return nil
                }
            }
            throw ThemeLoadError.invalidType(path: path, expected: "string | null | { enabled = false }")
        default:
            throw ThemeLoadError.invalidType(path: path, expected: "string | null | { enabled = false }")
        }
    }

    private static func requiredInt(_ path: String, in table: TomlTable, key: String) throws -> Int {
        guard let value = try optionalNumber(path, in: table, key: key) else {
            throw ThemeLoadError.missingKey(path)
        }
        return Int(value)
    }

    private static func optionalNumber(_ path: String, in table: TomlTable, key: String) throws -> Double? {
        guard let value = table[key] else { return nil }

        switch value {
        case let .double(number):
            return number
        case let .integer(integer):
            return Double(integer)
        case .null:
            return nil
        default:
            throw ThemeLoadError.invalidType(path: path, expected: "number")
        }
    }

    private static func optionalBool(_ path: String, in table: TomlTable, key: String) throws -> Bool? {
        guard let value = table[key] else { return nil }

        switch value {
        case let .boolean(booleanValue):
            return booleanValue
        case .null:
            return nil
        default:
            throw ThemeLoadError.invalidType(path: path, expected: "boolean")
        }
    }
}
