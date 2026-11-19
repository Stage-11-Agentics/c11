import AppKit
import CoreText
import SwiftUI

// Schema 2 roles (docs/c11-theme-schema-2.md).
//
// Every role here is unset by default: a theme that leaves one out resolves to nil,
// and the view keeps the value it draws today. That is how `stage11` and every
// schema-1 theme render unchanged. Roles are keyed by their TOML path.

public enum ThemeStyleValueKind: Equatable, Sendable {
    case color
    case number
    case boolean
    /// Free text, e.g. a font family name.
    case string
    /// One of a fixed set of words; anything else is a load error (a typo, not a future value).
    case choice([String])
    /// `"<color expr> <pct>%, <color expr> <pct>%, …"`; a single colour expression is a one-stop gradient.
    case gradient

    var label: String {
        switch self {
        case .color: return "color"
        case .number: return "number"
        case .boolean: return "boolean"
        case .string: return "string"
        case let .choice(values): return values.joined(separator: " | ")
        case .gradient: return "gradient"
        }
    }
}

public struct ThemeStyleRoleDefinition: Equatable, Sendable {
    public let path: String
    public let kind: ThemeStyleValueKind
    public let owningSurface: String
    /// Numbers outside this range are clamped when resolved.
    public let range: ClosedRange<Double>?
}

/// The text styles a theme can set under `[type.<style>]`.
public enum ThemeTextStyleName: String, CaseIterable, Sendable {
    case windowTitle
    case cardTitle
    case cardLabel
    case agentRow
    case tab
    case chip
    case pill

    var owningSurface: String {
        switch self {
        case .windowTitle: return "ContentView.customTitlebar"
        case .cardTitle, .cardLabel, .agentRow: return "ContentView.WorkspaceRowView"
        case .tab: return "bonsplit TabItemView"
        case .chip: return "PanelTitleBarView chip"
        case .pill: return "ContentView.WaitingAgentRow"
        }
    }
}

public struct ThemeStyleRole: Hashable, Sendable, CustomStringConvertible {
    public let path: String

    public init(_ path: String) {
        self.path = path
    }

    public var description: String { path }

    public var definition: ThemeStyleRoleDefinition? {
        ThemeStyleRoleRegistry.byPath[path]
    }

    // Families
    public static let typeUI = ThemeStyleRole("type.ui")
    public static let typeDisplay = ThemeStyleRole("type.display")
    public static let typeMono = ThemeStyleRole("type.mono")

    public static func text(_ style: ThemeTextStyleName, _ attribute: ThemeTextStyleAttribute) -> ThemeStyleRole {
        ThemeStyleRole("type.\(style.rawValue).\(attribute.rawValue)")
    }

    // Geometry
    public static let cardRadius = ThemeStyleRole("geometry.cardRadius")
    public static let cardBorderPt = ThemeStyleRole("geometry.cardBorderPt")
    public static let cardActiveBorderPt = ThemeStyleRole("geometry.cardActiveBorderPt")
    public static let cardPaddingPt = ThemeStyleRole("geometry.cardPaddingPt")
    public static let pillRadius = ThemeStyleRole("geometry.pillRadius")
    public static let controlRadius = ThemeStyleRole("geometry.controlRadius")
    public static let chipRadius = ThemeStyleRole("geometry.chipRadius")
    public static let markRadius = ThemeStyleRole("geometry.markRadius")
    public static let progressHeightPt = ThemeStyleRole("geometry.progressHeightPt")
    public static let progressRadius = ThemeStyleRole("geometry.progressRadius")
    public static let tabSelection = ThemeStyleRole("geometry.tabSelection")

    // Card
    public static let cardFill = ThemeStyleRole("chrome.card.fill")
    public static let cardFillActive = ThemeStyleRole("chrome.card.fillActive")
    public static let cardBorder = ThemeStyleRole("chrome.card.border")
    public static let cardBorderActive = ThemeStyleRole("chrome.card.borderActive")
    public static let cardBorderWaiting = ThemeStyleRole("chrome.card.borderWaiting")
    public static let cardText = ThemeStyleRole("chrome.card.text")
    public static let cardTextSecondary = ThemeStyleRole("chrome.card.textSecondary")
    public static let cardTextDim = ThemeStyleRole("chrome.card.textDim")
    public static let cardRule = ThemeStyleRole("chrome.card.rule")
    public static let cardAccent = ThemeStyleRole("chrome.card.accent")
    public static let cardProgress = ThemeStyleRole("chrome.card.progress")
    public static let cardProgressTrack = ThemeStyleRole("chrome.card.progressTrack")
    public static let cardSheen = ThemeStyleRole("chrome.card.sheen")
    public static let cardGlow = ThemeStyleRole("chrome.card.glow")

    // Waiting Agent pill
    public static let pillStyle = ThemeStyleRole("chrome.pill.style")
    public static let pillFill = ThemeStyleRole("chrome.pill.fill")
    public static let pillInk = ThemeStyleRole("chrome.pill.ink")
    public static let pillBorder = ThemeStyleRole("chrome.pill.border")

    // Panel strip text (beside the schema-1 tabBar colours)
    public static let tabText = ThemeStyleRole("chrome.tabBar.text")
    public static let tabTextSecondary = ThemeStyleRole("chrome.tabBar.textSecondary")
    public static let tabActiveText = ThemeStyleRole("chrome.tabBar.activeText")
    public static let tabNumber = ThemeStyleRole("chrome.tabBar.number")

    // Description bar chip
    public static let chipFill = ThemeStyleRole("chrome.descriptionBar.chipFill")
    public static let chipBorder = ThemeStyleRole("chrome.descriptionBar.chipBorder")
    public static let chipText = ThemeStyleRole("chrome.descriptionBar.chipText")

    // Titlebar controls
    public static let controlFill = ThemeStyleRole("chrome.titleBar.controlFill")
    public static let controlForeground = ThemeStyleRole("chrome.titleBar.controlForeground")

    // Area frames (the focused area, the area whose agent waits)
    public static let areaFocusBorder = ThemeStyleRole("chrome.area.focusBorder")
    public static let areaWaitingBorder = ThemeStyleRole("chrome.area.waitingBorder")
    public static let areaThicknessPt = ThemeStyleRole("chrome.area.thicknessPt")

    // Sidebar backdrop
    public static let backdropKind = ThemeStyleRole("backdrop.kind")
    public static let backdropColor = ThemeStyleRole("backdrop.color")
    public static let backdropGradient = ThemeStyleRole("backdrop.gradient")
    public static let backdropGrid = ThemeStyleRole("backdrop.grid")
    public static let backdropGridColor = ThemeStyleRole("backdrop.gridColor")
    public static let backdropGridTop = ThemeStyleRole("backdrop.gridTop")

    // State colours (colours only; attention semantics stay c11's)
    public static let stateWaiting = ThemeStyleRole("states.waiting")
    public static let stateWaitingInk = ThemeStyleRole("states.waitingInk")
    public static let stateRunning = ThemeStyleRole("states.running")
    public static let stateIdle = ThemeStyleRole("states.idle")
    public static let stateCold = ThemeStyleRole("states.cold")
    public static let stateFlag = ThemeStyleRole("states.flag")
    public static let stateUnread = ThemeStyleRole("states.unread")
    public static let stateNotification = ThemeStyleRole("states.notification")
    public static let stateUsageLimit = ThemeStyleRole("states.usageLimit")

    // Ornaments: features behind a switch, off unless a theme names them
    public static let ornamentBust = ThemeStyleRole("ornaments.bust")
    public static let ornamentScanlines = ThemeStyleRole("ornaments.scanlines")
    public static let ornamentTitlebarClock = ThemeStyleRole("ornaments.titlebarClock")
    public static let ornamentStateTags = ThemeStyleRole("ornaments.stateTags")
    public static let ornamentHoverBrackets = ThemeStyleRole("ornaments.hoverBrackets")
    public static let ornamentCardHeader = ThemeStyleRole("ornaments.cardHeader")
    public static let ornamentSidebarLegend = ThemeStyleRole("ornaments.sidebarLegend")

    // Terminal pairing: a Ghostty theme name, applied only by `themes set --with-terminal`
    public static let terminalPairedTheme = ThemeStyleRole("terminal.pairedTheme")
}

public enum ThemeTextStyleAttribute: String, CaseIterable, Sendable {
    case family
    case scale
    case weight
    case `case`
    case tracking
}

public enum ThemeStyleRoleRegistry {
    public static let familyChoices = ["ui", "display", "mono"]
    public static let weightChoices = ["regular", "medium", "semibold", "bold", "heavy"]
    public static let caseChoices = ["none", "upper"]
    public static let tabSelectionChoices = ["indicator", "overline", "underline", "invert"]
    public static let pillStyleChoices = ["filled", "outline"]
    public static let backdropKindChoices = ["material", "solid", "gradient"]
    public static let backdropGridChoices = ["none", "perspective"]
    public static let cardHeaderChoices = ["none", "boxDrawing", "console"]

    /// Every schema-2 role, in a stable order (sections in the order of the spec).
    public static let all: [ThemeStyleRoleDefinition] = {
        var defs: [ThemeStyleRoleDefinition] = []
        func add(_ role: ThemeStyleRole, _ kind: ThemeStyleValueKind, _ surface: String, _ range: ClosedRange<Double>? = nil) {
            defs.append(ThemeStyleRoleDefinition(path: role.path, kind: kind, owningSurface: surface, range: range))
        }
        let radius: ClosedRange<Double> = 0...24
        let border: ClosedRange<Double> = 0...6

        add(.typeUI, .string, "chrome text in the ui family")
        add(.typeDisplay, .string, "chrome text in the display family")
        add(.typeMono, .string, "chrome text in the mono family")
        for style in ThemeTextStyleName.allCases {
            add(.text(style, .family), .choice(familyChoices), style.owningSurface)
            add(.text(style, .scale), .number, style.owningSurface, 0.5...3)
            add(.text(style, .weight), .choice(weightChoices), style.owningSurface)
            add(.text(style, .case), .choice(caseChoices), style.owningSurface)
            add(.text(style, .tracking), .number, style.owningSurface, -0.1...0.5)
        }

        let card = "ContentView.WorkspaceRowView"
        add(.cardRadius, .number, card, radius)
        add(.cardBorderPt, .number, card, border)
        add(.cardActiveBorderPt, .number, card, border)
        add(.cardPaddingPt, .number, card, 0...32)
        add(.pillRadius, .number, "ContentView.WaitingAgentRow", radius)
        add(.controlRadius, .number, "TitlebarControlsView, New Group", radius)
        add(.chipRadius, .number, "PanelTitleBarView chip", radius)
        add(.markRadius, .number, "WorkspacePulseMark", 0...6)
        add(.progressHeightPt, .number, "SidebarProgressIndicator", 1...12)
        add(.progressRadius, .number, "SidebarProgressIndicator", 0...12)
        add(.tabSelection, .choice(tabSelectionChoices), "bonsplit TabItemView")

        add(.cardFill, .color, card)
        add(.cardFillActive, .color, card)
        add(.cardBorder, .color, card)
        add(.cardBorderActive, .color, card)
        add(.cardBorderWaiting, .color, card)
        add(.cardText, .color, card)
        add(.cardTextSecondary, .color, card)
        add(.cardTextDim, .color, card)
        add(.cardRule, .color, card)
        add(.cardAccent, .color, card)
        add(.cardProgress, .gradient, card)
        add(.cardProgressTrack, .color, card)
        add(.cardSheen, .boolean, card)
        add(.cardGlow, .color, card)

        let pill = "ContentView.WaitingAgentRow"
        add(.pillStyle, .choice(pillStyleChoices), pill)
        add(.pillFill, .gradient, pill)
        add(.pillInk, .color, pill)
        add(.pillBorder, .color, pill)

        let tab = "bonsplit TabItemView"
        add(.tabText, .color, tab)
        add(.tabTextSecondary, .color, tab)
        add(.tabActiveText, .color, tab)
        add(.tabNumber, .color, tab)

        let chip = "PanelTitleBarView chip"
        add(.chipFill, .color, chip)
        add(.chipBorder, .color, chip)
        add(.chipText, .color, chip)

        add(.controlFill, .color, "TitlebarControlsView")
        add(.controlForeground, .color, "TitlebarControlsView")

        add(.areaFocusBorder, .color, "area frame")
        add(.areaWaitingBorder, .color, "area frame")
        add(.areaThicknessPt, .number, "area frame", border)

        let backdrop = "SidebarBackdrop"
        add(.backdropKind, .choice(backdropKindChoices), backdrop)
        add(.backdropColor, .color, backdrop)
        add(.backdropGradient, .gradient, backdrop)
        add(.backdropGrid, .choice(backdropGridChoices), backdrop)
        add(.backdropGridColor, .color, backdrop)
        add(.backdropGridTop, .number, backdrop, 0...1)

        let states = "lifecycle ramp, marks, badges, mailbox cell"
        for role in [ThemeStyleRole.stateWaiting, .stateWaitingInk, .stateRunning, .stateIdle, .stateCold,
                     .stateFlag, .stateUnread, .stateNotification, .stateUsageLimit] {
            add(role, .color, states)
        }

        add(.ornamentBust, .boolean, "Waiting Agent pill")
        add(.ornamentScanlines, .number, "chrome overlay (opacity, 0 is off)", 0...1)
        add(.ornamentTitlebarClock, .boolean, "titlebar right slot")
        add(.ornamentStateTags, .boolean, "card state row")
        add(.ornamentHoverBrackets, .boolean, "hovered card, tab, pill")
        add(.ornamentCardHeader, .choice(cardHeaderChoices), card)
        add(.ornamentSidebarLegend, .boolean, "sidebar foot")

        add(.terminalPairedTheme, .string, "c11 themes set --with-terminal")
        return defs
    }()

    public static let byPath: [String: ThemeStyleRoleDefinition] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.path, $0) }
    )

    /// Top-level tables and `chrome.*` tables that only schema 2 defines.
    static let schema2Tables: Set<String> = ["type", "geometry", "backdrop", "states", "ornaments", "terminal"]
    static let schema2ChromeTables: Set<String> = ["card", "pill", "descriptionBar", "area"]
}

/// A schema-2 value as written in the file: exactly one field is set.
public struct ThemeStyleValue: Codable, Equatable, Sendable {
    public var string: String?
    public var number: Double?
    public var bool: Bool?

    public init(string: String? = nil, number: Double? = nil, bool: Bool? = nil) {
        self.string = string
        self.number = number
        self.bool = bool
    }
}

/// A resolved gradient: stops in order, locations 0...1.
public struct ThemeGradient: Equatable, Sendable {
    public struct Stop: Equatable, Sendable {
        public let color: NSColor
        public let location: Double
    }

    public let stops: [Stop]

    /// The colour a gradient stands for where a view can only draw one (its first stop).
    public var firstColor: NSColor? { stops.first?.color }

    public var swiftUIGradient: Gradient {
        Gradient(stops: stops.map { Gradient.Stop(color: Color(nsColor: $0.color), location: $0.location) })
    }
}

/// Parsing of the gradient string grammar. Colour expressions can contain commas
/// (`$a.mix($b, 0.3)`), so stops split only on commas outside parentheses.
enum ThemeGradientSyntax {
    struct RawStop: Equatable {
        let expression: String
        let location: Double?
    }

    struct SyntaxError: Error, Equatable, CustomStringConvertible {
        let description: String
    }

    static func parse(_ source: String) -> Result<[RawStop], SyntaxError> {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for ch in source {
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth < 0 { return .failure(SyntaxError(description: "unbalanced ')'")) }
            }
            if ch == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        guard depth == 0 else { return .failure(SyntaxError(description: "unbalanced '('")) }

        var stops: [RawStop] = []
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { return .failure(SyntaxError(description: "empty stop")) }
            // The location is the last word when it ends in %; the expression is the rest
            // (it may hold spaces inside its parentheses).
            let lastSpace = part.lastIndex(where: { $0.isWhitespace })
            let tail = lastSpace.map { String(part[part.index(after: $0)...]) } ?? ""
            if !tail.hasSuffix("%") {
                guard !part.contains(where: { $0.isWhitespace }) || part.contains("(") else {
                    return .failure(SyntaxError(description: "stop '\(part)' is not '<color> <0-100>%'"))
                }
                stops.append(RawStop(expression: part, location: nil))
            } else if let lastSpace, let pct = Double(tail.dropLast()), (0...100).contains(pct) {
                let expression = part[..<lastSpace].trimmingCharacters(in: .whitespaces)
                guard !expression.isEmpty else {
                    return .failure(SyntaxError(description: "stop '\(part)' has no colour"))
                }
                stops.append(RawStop(expression: expression, location: pct / 100))
            } else {
                return .failure(SyntaxError(description: "stop '\(part)' is not '<color> <0-100>%'"))
            }
        }
        if stops.count > 1, stops.contains(where: { $0.location == nil }) {
            return .failure(SyntaxError(description: "every stop of a multi-stop gradient needs a location"))
        }
        if zip(stops, stops.dropFirst()).contains(where: { ($0.location ?? 0) > ($1.location ?? 0) }) {
            return .failure(SyntaxError(description: "stop locations must not decrease"))
        }
        return .success(stops)
    }
}

/// A resolved `[type.<style>]`, plus the family it points at. Every field is optional:
/// nil means "keep what the view draws today".
public struct ThemeTextStyle: Equatable, Sendable {
    public var familyName: String?
    public var scale: Double?
    public var weight: String?
    public var uppercase: Bool?
    public var tracking: Double?

    public static let unset = ThemeTextStyle()

    public var isUnset: Bool { self == .unset }

    /// Text as the style shows it.
    public func apply(_ text: String) -> String {
        uppercase == true ? text.uppercased() : text
    }

    public var fontWeight: Font.Weight? {
        switch weight {
        case "regular": return .regular
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        default: return nil
        }
    }

    /// The font for this style at the view's own size. `baseSize` is the size the view
    /// uses today (already multiplied by Chrome Scale); `scale` multiplies it.
    public func font(baseSize: CGFloat, defaultWeight: Font.Weight = .regular, defaultDesign: Font.Design = .default) -> Font {
        let weight = fontWeight ?? defaultWeight
        return ThemeFontFamily.font(named: familyName, size: scaledSize(baseSize), weight: weight, defaultDesign: defaultDesign)
    }

    /// Legibility floor: a theme may shrink text, but never below 9 pt (or the view's own
    /// size, when that is already smaller).
    public static let minimumScaledSize: CGFloat = 9

    public func scaledSize(_ baseSize: CGFloat) -> CGFloat {
        let size = baseSize * CGFloat(scale ?? 1)
        return max(size, min(baseSize, Self.minimumScaledSize))
    }

    /// Tracking in points. `baseSize` is the same unscaled size passed to `font(baseSize:)`;
    /// tracking is stored in em of the final (scaled) size.
    public func trackingPoints(baseSize: CGFloat) -> CGFloat {
        CGFloat(tracking ?? 0) * scaledSize(baseSize)
    }
}

/// Font families by name. `system` is SF Pro, `system-mono` SF Mono, `system-rounded`
/// SF Pro Rounded; any other name must be an installed family, else SF Pro (or SF Mono
/// when the view is monospaced) stands in, logged once.
public enum ThemeFontFamily {
    private static let lock = NSLock()
    private static var availability: [String: Bool] = [:]
    private static var warned: Set<String> = []

    public static func isAvailable(_ family: String) -> Bool {
        if ["system", "system-mono", "system-rounded", "system-serif"].contains(family) { return true }
        lock.lock()
        if let cached = availability[family] {
            lock.unlock()
            return cached
        }
        // NSFontManager is not documented as thread-safe; one caller at a time.
        let available = NSFontManager.shared.availableMembers(ofFontFamily: family)?.isEmpty == false
        availability[family] = available
        let shouldWarn = !available && warned.insert(family).inserted
        lock.unlock()
        if shouldWarn {
            ThemeDiagnostics.loader("font family '\(family)' is not installed; using the system font")
        }
        return available
    }

    /// The bundled JetBrains Mono (OFL 1.1), registered for this process only when the
    /// family is not already installed, so every theme draws the same on every Mac and an
    /// operator's own install wins. Nothing is installed system-wide.
    public static let bundledFontFiles = ["JetBrainsMono-Variable"]
    private static var didRegisterBundledFonts = false

    @discardableResult
    public static func registerBundledFonts(bundle: Bundle = .main) -> [String] {
        lock.lock()
        guard !didRegisterBundledFonts else { lock.unlock(); return [] }
        didRegisterBundledFonts = true
        lock.unlock()

        var urls: [URL] = []
        for file in bundledFontFiles {
            guard let url = bundle.url(forResource: file, withExtension: "ttf") else {
                ThemeDiagnostics.loader("bundled font '\(file).ttf' is missing from the app")
                continue
            }
            urls.append(url)
        }
        return registerFonts(at: urls)
    }

    /// Registers each font file for this process unless its family is already installed.
    /// Returns the files it registered.
    @discardableResult
    public static func registerFonts(at urls: [URL]) -> [String] {
        var registered: [String] = []
        for url in urls {
            let file = url.deletingPathExtension().lastPathComponent
            let families = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? [])
                .compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
            if let family = families.first,
               NSFontManager.shared.availableMembers(ofFontFamily: family)?.isEmpty == false {
                continue
            }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                registered.append(file)
            } else {
                ThemeDiagnostics.loader("could not register bundled font '\(file)': \(String(describing: error?.takeRetainedValue()))")
            }
        }
        resetAvailabilityCache()
        return registered
    }

    /// Called on every theme load, so a font installed since the last load is found.
    public static func resetAvailabilityCache() {
        lock.lock()
        availability.removeAll()
        lock.unlock()
    }

    public static func font(named family: String?, size: CGFloat, weight: Font.Weight, defaultDesign: Font.Design) -> Font {
        switch family {
        case nil:
            return .system(size: size, weight: weight, design: defaultDesign)
        case "system":
            return .system(size: size, weight: weight, design: .default)
        case "system-mono":
            return .system(size: size, weight: weight, design: .monospaced)
        case "system-rounded":
            return .system(size: size, weight: weight, design: .rounded)
        case "system-serif":
            return .system(size: size, weight: weight, design: .serif)
        case let name?:
            guard isAvailable(name) else {
                let monoLike = name.localizedCaseInsensitiveContains("mono") || defaultDesign == .monospaced
                return .system(size: size, weight: weight, design: monoLike ? .monospaced : .default)
            }
            return Font.custom(name, size: size).weight(weight)
        }
    }

    /// AppKit counterpart, for bonsplit and titlebar AppKit views.
    public static func nsFont(named family: String?, size: CGFloat, weight: NSFont.Weight, monospaced: Bool) -> NSFont {
        func system() -> NSFont {
            monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        }
        switch family {
        case nil, "system":
            return family == nil ? system() : .systemFont(ofSize: size, weight: weight)
        case "system-mono":
            return .monospacedSystemFont(ofSize: size, weight: weight)
        case "system-rounded", "system-serif":
            let design: NSFontDescriptor.SystemDesign = family == "system-rounded" ? .rounded : .serif
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case let name?:
            guard isAvailable(name) else {
                return name.localizedCaseInsensitiveContains("mono") ? .monospacedSystemFont(ofSize: size, weight: weight) : system()
            }
            let descriptor = NSFontDescriptor(fontAttributes: [.family: name])
                .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
            return NSFont(descriptor: descriptor, size: size) ?? system()
        }
    }
}
