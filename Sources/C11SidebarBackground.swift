import AppKit
import SwiftUI

/// c11's own look (C11H-32): what the workspace sidebar draws behind its cards.
///
/// The default, From theme, draws the active theme's `[backdrop]`
/// (docs/c11-theme-schema-2.md). In the Dark theme slot a theme without one
/// shows Sunset Mall, so every install that keeps `stage11` looks as it did; in
/// the Light theme slot it leaves c11's material and Light Mode Tint. Sunset Mall
/// and Outrun Horizon override the theme in the Dark theme slot; None always
/// leaves the material. Plain c11 grey is `stage11` with None.
///
/// The choice lives under a c11-only key, read from c11's own defaults domain.
/// c11 never writes it, and the first-install settings import refuses every `c11.`
/// key (`scripts/c11-install.sh`), so the default holds whatever c11 theme and
/// sidebar settings were imported. Nothing here reads or writes c11's domain.
/// Settings > Workspace & Sidebar > Sidebar Background picks it.
///
/// The background is drawn by `SidebarBackdrop` (the sidebar container), never by
/// `WorkspaceRowView`: cards keep their opaque fills, so card text contrast is
/// unchanged (measured in `notes/ux-wave-1/C11H-32-vaporwave-sidebar.html`).
enum C11SidebarBackground: String, CaseIterable, Identifiable {
    /// The active theme's `[backdrop]`; without one, Sunset Mall in the Dark
    /// theme slot and c11's material in the Light theme slot.
    case fromTheme
    case sunsetMall
    case outrunHorizon
    /// No background: the sidebar shows c11's material and tint.
    case off

    static let storageKey = "c11.sidebar.backgroundDark"
    static let defaultValue: C11SidebarBackground = .fromTheme

    var id: String { rawValue }

    /// The stored choice; a missing or unknown value is the default.
    static func resolve(_ raw: String?) -> C11SidebarBackground {
        raw.flatMap(C11SidebarBackground.init(rawValue:)) ?? defaultValue
    }

    /// The fixed style that overrides the theme: only in the Dark theme slot, and
    /// never for From theme or None.
    static func shown(raw: String?, colorScheme: ColorScheme) -> C11SidebarBackground? {
        guard colorScheme == .dark else { return nil }
        switch resolve(raw) {
        case .sunsetMall: return .sunsetMall
        case .outrunHorizon: return .outrunHorizon
        case .fromTheme, .off: return nil
        }
    }

    /// What the sidebar draws over its material: an override, the theme's
    /// backdrop, Sunset Mall for a Dark-slot theme without one, or nothing
    /// (None, or a Light-slot theme without a backdrop).
    static func backdrop(raw: String?, colorScheme: ColorScheme, theme: SidebarBackdropStyle?) -> SidebarBackdropStyle? {
        if resolve(raw) == .off { return nil }
        if let override = shown(raw: raw, colorScheme: colorScheme) { return override.backdropStyle }
        if let theme { return theme }
        return colorScheme == .dark ? sunsetMall.backdropStyle : nil
    }

    var label: String {
        switch self {
        case .fromTheme:
            return String(localized: "settings.sidebarBackground.fromTheme", defaultValue: "From Theme")
        case .sunsetMall:
            return String(localized: "settings.sidebarBackground.sunsetMall", defaultValue: "Sunset Mall")
        case .outrunHorizon:
            return String(localized: "settings.sidebarBackground.outrunHorizon", defaultValue: "Outrun Horizon")
        case .off:
            return String(localized: "settings.sidebarBackground.none", defaultValue: "None")
        }
    }

    /// Gradient stops, top to bottom. Both styles end on a deep foot so the
    /// footer's help icon keeps WCAG 3:1 or better.
    var stops: [(location: Double, rgb: UInt32)] {
        switch self {
        case .sunsetMall:
            // Violet into a magenta glow low in the sidebar.
            return [(0.0, 0x2D1060), (0.42, 0x6B1F8F), (0.72, 0xC2307F), (1.0, 0x4A1366)]
        case .outrunHorizon:
            // Night sky, a neon horizon, then a dark floor that carries the grid.
            return [(0.0, 0x26104F), (0.5, 0x4A1A82), (0.64, 0xE2367F), (0.69, 0xFF9F45), (0.71, 0x3A1066), (1.0, 0x2A0B4C)]
        case .fromTheme, .off:
            return []
        }
    }

    /// The perspective grid on Outrun Horizon's floor: cyan lines and the fraction
    /// of the height where the floor starts.
    var grid: (rgb: UInt32, opacity: Double, top: Double)? {
        self == .outrunHorizon ? (0x2DE2E6, 0.45, 0.70) : nil
    }

    /// The override as a backdrop the sidebar draws; nil for From theme and None.
    var backdropStyle: SidebarBackdropStyle? {
        guard !stops.isEmpty else { return nil }
        let gradient = ThemeGradient(stops: stops.map {
            ThemeGradient.Stop(color: Self.nsColor($0.rgb), location: $0.location)
        })
        return SidebarBackdropStyle(
            fill: .gradient(gradient),
            grid: grid.map { SidebarBackdropStyle.Grid(color: Self.nsColor($0.rgb, opacity: $0.opacity), top: $0.top) }
        )
    }

    /// Grid lines in unit coordinates (0...1 on both axes): seven horizontals that
    /// crowd toward the horizon, and thirteen verticals fanning out from it.
    static func gridSegments(top: Double) -> [(x0: Double, y0: Double, x1: Double, y1: Double)] {
        var lines: [(x0: Double, y0: Double, x1: Double, y1: Double)] = []
        for i in 0...6 {
            let y = top + pow(Double(i) / 6, 1.8) * (1 - top)
            lines.append((0, y, 1, y))
        }
        for i in -6...6 {
            lines.append((0.5 + Double(i) * 0.028, top, 0.5 + Double(i) * 0.28, 1))
        }
        return lines
    }

    static func components(_ rgb: UInt32) -> (red: Double, green: Double, blue: Double) {
        (Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255)
    }

    static func color(_ rgb: UInt32, opacity: Double = 1) -> Color {
        let c = components(rgb)
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: opacity)
    }

    static func nsColor(_ rgb: UInt32, opacity: Double = 1) -> NSColor {
        let c = components(rgb)
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: opacity)
    }
}

/// A sidebar backdrop: a fill over c11's material and an optional perspective
/// grid. From a theme's `[backdrop]`, or from a fixed `C11SidebarBackground`.
struct SidebarBackdropStyle: Equatable {
    enum Fill: Equatable {
        case solid(NSColor)
        case gradient(ThemeGradient)
    }

    struct Grid: Equatable {
        var color: NSColor
        /// Fraction of the sidebar height where the floor starts.
        var top: Double
    }

    /// nil leaves c11's material visible (only the grid draws over it, if any).
    var fill: Fill?
    var grid: Grid?

    static let defaultGridTop = 0.70
    static let defaultGridColor = C11SidebarBackground.nsColor(0x2DE2E6, opacity: 0.45)

    /// A theme's `[backdrop]` values. nil when the theme sets no backdrop (no
    /// section, or a kind whose colour is missing), which lets the Dark slot fall
    /// back to Sunset Mall. `kind = "material"` is an explicit choice: a style with
    /// no fill (c11's material shows, under the grid if there is one).
    static func fromTheme(
        kind: String?,
        color: NSColor?,
        gradient: ThemeGradient?,
        grid: String?,
        gridColor: NSColor?,
        gridTop: Double?
    ) -> SidebarBackdropStyle? {
        func gradientFill(_ g: ThemeGradient) -> Fill {
            g.stops.count == 1 ? .solid(g.stops[0].color) : .gradient(g)
        }
        let fill: Fill?
        switch kind {
        case "material":
            fill = nil
        case "solid":
            fill = color.map(Fill.solid) ?? gradient.map(gradientFill)
        default:
            // "gradient", or no kind: whichever value the theme wrote.
            fill = gradient.map(gradientFill) ?? color.map(Fill.solid)
        }
        let floor: Grid? = grid == "perspective"
            ? Grid(color: gridColor ?? defaultGridColor, top: min(0.95, max(0.05, gridTop ?? defaultGridTop)))
            : nil
        guard fill != nil || floor != nil || kind == "material" else { return nil }
        return SidebarBackdropStyle(fill: fill, grid: floor)
    }
}

/// Draws a `SidebarBackdropStyle`. Static: no state, no animation.
struct SidebarBackdropView: View {
    let style: SidebarBackdropStyle

    var body: some View {
        ZStack {
            switch style.fill {
            case let .solid(color)?:
                Color(nsColor: color)
            case let .gradient(gradient)?:
                LinearGradient(gradient: gradient.swiftUIGradient, startPoint: .top, endPoint: .bottom)
            case nil:
                EmptyView()
            }
            if let grid = style.grid {
                Canvas { context, size in
                    var path = Path()
                    for line in C11SidebarBackground.gridSegments(top: grid.top) {
                        path.move(to: CGPoint(x: line.x0 * size.width, y: line.y0 * size.height))
                        path.addLine(to: CGPoint(x: line.x1 * size.width, y: line.y1 * size.height))
                    }
                    context.stroke(path, with: .color(Color(nsColor: grid.color)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Sidebar theme style

/// Schema-2 values the workspace sidebar draws (C11H-144 to C11H-148), resolved
/// in `SidebarThemeStyleCache` and passed down as a value. Every field is
/// optional or off: nil keeps what the sidebar draws today, so `stage11` and
/// every schema-1 theme render unchanged.
///
/// `==` compares only the stamp, a generation that changes when the resolved
/// content does (not on every theme version bump: a Ghostty background change
/// bumps the version at up to 30 Hz). The Equatable workspace row stays a cheap
/// compare that holds under churn (CLAUDE.md, typing-latency paths).
struct SidebarThemeStyle: Equatable {

    enum CardHeader: String, Equatable {
        case none
        case boxDrawing
        case console
    }

    enum PillStyle: String, Equatable {
        case filled
        case outline
    }

    /// Content generation; 0 is the unset style.
    var stamp: UInt64 = 0
    /// Every resolved value as text, so the cache can tell whether a new theme
    /// version changed anything the sidebar draws.
    var fingerprint = ""

    // [chrome.card]
    var cardFill: Color?
    var cardFillActive: Color?
    var cardBorder: Color?
    var cardBorderActive: Color?
    var cardBorderWaiting: Color?
    var cardText: Color?
    var cardTextSecondary: Color?
    var cardTextDim: Color?
    var cardRule: Color?
    var cardAccent: Color?
    var cardProgress: Gradient?
    var cardProgressTrack: Color?
    var cardSheen: Bool?
    var cardGlow: Color?

    // [geometry]
    var cardRadius: CGFloat?
    var cardBorderPt: CGFloat?
    var cardActiveBorderPt: CGFloat?
    var cardPaddingPt: CGFloat?
    var pillRadius: CGFloat?
    var controlRadius: CGFloat?
    var markRadius: CGFloat?
    var progressHeightPt: CGFloat?
    var progressRadius: CGFloat?

    // [type]
    var cardTitle: ThemeTextStyle = .unset
    var cardLabel: ThemeTextStyle = .unset
    var agentRow: ThemeTextStyle = .unset
    var pill: ThemeTextStyle = .unset
    /// The theme's mono family, for the legend line.
    var monoFamily: String?

    // [chrome.pill]
    var pillStyle: PillStyle?
    var pillFill: Gradient?
    var pillFillFirst: Color?
    var pillInk: Color?
    var pillBorder: Color?

    // [states] the sidebar reads itself (the lifecycle ramp is Workspace's)
    var stateWaiting: Color?
    var stateWaitingInk: Color?
    var stateFlag: Color?
    var stateUsageLimit: Color?
    /// The lifecycle ramp's colours, handed to `Workspace.resolvedSurfaceTabActivityColors`.
    var statePalette: ThemeStatePalette = .unset

    // [ornaments]
    var bust = false
    var stateTags = false
    var cardHeader: CardHeader = .none
    var hoverBrackets = false
    var sidebarLegend = false

    static func == (lhs: SidebarThemeStyle, rhs: SidebarThemeStyle) -> Bool {
        lhs.stamp == rhs.stamp
    }

    /// Nothing themed: the sidebar as it draws today.
    static let unset = SidebarThemeStyle()

    /// The pill the theme draws: its `style`, or filled when it sets only the
    /// fill, ink or border. nil draws today's gold pill.
    var effectivePillStyle: PillStyle? {
        pillStyle ?? (pillFill != nil || pillInk != nil || pillBorder != nil ? .filled : nil)
    }

    /// The theme draws the card edge itself: one border, no gold selection inset.
    var ownsCardEdge: Bool {
        cardBorder != nil || cardBorderActive != nil || cardBorderWaiting != nil
    }

    init() {}

    /// Resolves every sidebar role. The stamp is left at 0; the cache assigns it.
    init(snapshot: ResolvedThemeSnapshot, context: ThemeContext) {
        var marks: [String] = []
        func record(_ role: ThemeStyleRole, _ value: String?) {
            if let value { marks.append("\(role.path)=\(value)") }
        }
        func color(_ role: ThemeStyleRole) -> Color? {
            let resolved = snapshot.resolveStyleColor(role, context: context)
            record(role, resolved.map(Self.colorKey))
            return resolved.map { Color(nsColor: $0) }
        }
        func number(_ role: ThemeStyleRole) -> CGFloat? {
            let resolved = snapshot.resolveStyleNumber(role)
            record(role, resolved.map { "\($0)" })
            return resolved.map { CGFloat(max(0, $0)) }
        }
        func gradient(_ role: ThemeStyleRole) -> ThemeGradient? {
            let resolved = snapshot.resolveStyleGradient(role, context: context)
            record(role, resolved.map { $0.stops.map { "\(Self.colorKey($0.color))@\($0.location)" }.joined(separator: ",") })
            return resolved
        }
        func bool(_ role: ThemeStyleRole) -> Bool? {
            let resolved = snapshot.resolveStyleBool(role)
            record(role, resolved.map { "\($0)" })
            return resolved
        }
        func string(_ role: ThemeStyleRole) -> String? {
            let resolved = snapshot.resolveStyleString(role)
            record(role, resolved)
            return resolved
        }
        func text(_ name: ThemeTextStyleName) -> ThemeTextStyle {
            let resolved = snapshot.resolveTextStyle(name)
            if !resolved.isUnset { marks.append("type.\(name.rawValue)=\(resolved)") }
            return resolved
        }

        cardFill = color(.cardFill)
        cardFillActive = color(.cardFillActive)
        cardBorder = color(.cardBorder)
        cardBorderActive = color(.cardBorderActive)
        cardBorderWaiting = color(.cardBorderWaiting)
        cardText = color(.cardText)
        cardTextSecondary = color(.cardTextSecondary)
        cardTextDim = color(.cardTextDim)
        cardRule = color(.cardRule)
        cardAccent = color(.cardAccent)
        cardProgress = gradient(.cardProgress)?.swiftUIGradient
        cardProgressTrack = color(.cardProgressTrack)
        cardSheen = bool(.cardSheen)
        cardGlow = color(.cardGlow)

        cardRadius = number(.cardRadius)
        cardBorderPt = number(.cardBorderPt)
        cardActiveBorderPt = number(.cardActiveBorderPt)
        cardPaddingPt = number(.cardPaddingPt)
        pillRadius = number(.pillRadius)
        controlRadius = number(.controlRadius)
        markRadius = number(.markRadius)
        progressHeightPt = number(.progressHeightPt)
        progressRadius = number(.progressRadius)

        cardTitle = text(.cardTitle)
        cardLabel = text(.cardLabel)
        agentRow = text(.agentRow)
        pill = text(.pill)
        monoFamily = string(.typeMono)

        pillStyle = string(.pillStyle).flatMap(PillStyle.init(rawValue:))
        let fill = gradient(.pillFill)
        pillFill = fill?.swiftUIGradient
        pillFillFirst = fill?.firstColor.map { Color(nsColor: $0) }
        pillInk = color(.pillInk)
        pillBorder = color(.pillBorder)

        stateWaiting = color(.stateWaiting)
        stateWaitingInk = color(.stateWaitingInk)
        stateFlag = color(.stateFlag)
        stateUsageLimit = color(.stateUsageLimit)
        statePalette = ThemeStatePalette.from(snapshot: snapshot, context: context)
        if statePalette != .unset { marks.append("states=\(statePalette)") }

        bust = bool(.ornamentBust) ?? false
        stateTags = bool(.ornamentStateTags) ?? false
        cardHeader = string(.ornamentCardHeader).flatMap(CardHeader.init(rawValue:)) ?? .none
        hoverBrackets = bool(.ornamentHoverBrackets) ?? false
        sidebarLegend = bool(.ornamentSidebarLegend) ?? false
        fingerprint = marks.joined(separator: ";")
    }

    private static func colorKey(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return color.description }
        return "\(c.redComponent),\(c.greenComponent),\(c.blueComponent),\(c.alphaComponent)"
    }

    /// The card's padding: today's 13/13/11, or the theme's value with the same
    /// two-point lighter foot.
    var cardPadding: (horizontal: CGFloat, top: CGFloat, bottom: CGFloat) {
        guard let pad = cardPaddingPt else { return (13, 13, 11) }
        return (pad, pad, max(0, pad - 2))
    }
}

/// Resolves the sidebar style; every sidebar view asks here instead of reading
/// the theme itself. A theme with no schema-2 values (stage11, every schema-1
/// theme) costs one check per theme version and always answers `.unset`. The
/// stamp advances only when the resolved content changes, so a version bump that
/// changes nothing the sidebar draws keeps every workspace row's `==` true.
///
/// c11 (C11H-197): one entry per theme shown, so two windows on different
/// themes keep their own styles instead of evicting each other on every render.
/// Stamps come from one generation, so two themes never share a stamp.
@MainActor
enum SidebarThemeStyleCache {
    private struct Key: Equatable {
        var manager: ObjectIdentifier
        var version: UInt64
        var dark: Bool
        var enabled: Bool
    }

    private struct Entry {
        var key: Key
        var style: SidebarThemeStyle
    }

    /// Keyed by the name of the theme the style was resolved from.
    private static var entries: [String: Entry] = [:]
    private static var generation: UInt64 = 0

    static func current(
        _ themeManager: ThemeManager,
        colorScheme: ColorScheme,
        windowThemeName: String? = nil
    ) -> SidebarThemeStyle {
        let snapshot = themeManager.snapshot(windowThemeName: windowThemeName)
        let slot = snapshot.theme.identity.name
        let key = Key(
            manager: ObjectIdentifier(themeManager),
            version: themeManager.version,
            dark: colorScheme == .dark,
            enabled: themeManager.isEnabled
        )
        let previous = entries[slot]
        if let previous, previous.key == key { return previous.style }
        let fresh = hasStyles(themeManager, theme: snapshot.theme)
            ? SidebarThemeStyle(
                snapshot: snapshot,
                context: themeManager.makeContext(colorScheme: colorScheme, windowThemeName: windowThemeName)
            )
            : .unset
        let next = advance(previous?.style ?? .unset, to: fresh, generation: &generation)
        entries[slot] = Entry(key: key, style: next)
        return next
    }

    /// Keeps `previous` (and its stamp) when nothing changed; otherwise stamps
    /// `fresh` with the next generation.
    nonisolated static func advance(_ previous: SidebarThemeStyle, to fresh: SidebarThemeStyle, generation: inout UInt64) -> SidebarThemeStyle {
        guard fresh.fingerprint != previous.fingerprint else { return previous }
        var next = fresh
        if fresh.fingerprint.isEmpty {
            next.stamp = 0
        } else {
            generation &+= 1
            next.stamp = generation
        }
        return next
    }

    private static func hasStyles(_ themeManager: ThemeManager, theme: C11Theme) -> Bool {
        themeManager.isEnabled && theme.styles?.isEmpty == false
    }

    /// The theme's backdrop for the sidebar container.
    static func backdrop(
        _ themeManager: ThemeManager,
        colorScheme: ColorScheme,
        windowThemeName: String? = nil
    ) -> SidebarBackdropStyle? {
        let snapshot = themeManager.snapshot(windowThemeName: windowThemeName)
        guard hasStyles(themeManager, theme: snapshot.theme) else { return nil }
        let context = themeManager.makeContext(colorScheme: colorScheme, windowThemeName: windowThemeName)
        return SidebarBackdropStyle.fromTheme(
            kind: snapshot.resolveStyleString(.backdropKind),
            color: snapshot.resolveStyleColor(.backdropColor, context: context),
            gradient: snapshot.resolveStyleGradient(.backdropGradient, context: context),
            grid: snapshot.resolveStyleString(.backdropGrid),
            gridColor: snapshot.resolveStyleColor(.backdropGridColor, context: context),
            gridTop: snapshot.resolveStyleNumber(.backdropGridTop)
        )
    }
}

// MARK: - Themed text

extension ThemeTextStyle {
    /// A font for chrome text: exactly today's system font when the theme leaves
    /// the style unset.
    func chromeFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        isUnset ? .system(size: size, weight: weight, design: design) : font(baseSize: size, defaultWeight: weight, defaultDesign: design)
    }

    /// Tracking in points; zero when unset.
    func chromeTracking(size: CGFloat) -> CGFloat {
        isUnset ? 0 : trackingPoints(baseSize: size)
    }
}

extension Text {
    /// Applies a theme text style; draws exactly as `.font(.system(...))` when unset.
    func chromeStyle(_ style: ThemeTextStyle, size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Text {
        let styled = font(style.chromeFont(size: size, weight: weight, design: design))
        return style.isUnset ? styled : styled.tracking(style.chromeTracking(size: size))
    }
}

extension View {
    /// Sets the foreground only when the theme supplies a colour, so an unset
    /// role leaves the inherited colour exactly as today.
    @ViewBuilder
    func themedForeground(_ color: Color?) -> some View {
        if let color {
            foregroundColor(color)
        } else {
            self
        }
    }

    /// The view-level counterpart of `Text.chromeStyle`.
    @ViewBuilder
    func chromeTextStyle(_ style: ThemeTextStyle, size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        if style.isUnset {
            font(.system(size: size, weight: weight, design: design))
        } else {
            font(style.font(baseSize: size, defaultWeight: weight, defaultDesign: design))
                .tracking(style.trackingPoints(baseSize: size))
        }
    }
}

// MARK: - Sidebar ornaments (C11H-145, C11H-148)

/// A lifecycle mark's 9pt cell: exactly `Rectangle` when the theme sets no
/// radius, else a rounded square (`geometry.markRadius`).
struct WorkspacePulseMarkCell: InsettableShape {
    var radius: CGFloat?
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard let radius, radius > 0 else { return Path(r) }
        return RoundedRectangle(cornerRadius: max(0, radius - insetAmount), style: .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> WorkspacePulseMarkCell {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// A card bar (composition rail, progress): square like today, or rounded by
/// `geometry.progressRadius`.
struct WorkspaceCardBarShape: Shape {
    var radius: CGFloat?

    func path(in rect: CGRect) -> Path {
        guard let radius, radius > 0 else { return Path(rect) }
        return RoundedRectangle(cornerRadius: min(radius, rect.height / 2), style: .continuous).path(in: rect)
    }
}

/// Outrun's bloom under the active card; no modifier at all without a glow.
struct WorkspaceCardGlow: ViewModifier {
    let color: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let color {
            content.shadow(color: color.opacity(0.5), radius: 11)
        } else {
            content
        }
    }
}

/// A one-point dotted rule (Terminal Grid).
struct WorkspaceCardDottedRule: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: proxy.size.width, y: 0.5))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
        }
        .allowsHitTesting(false)
    }
}

/// The card title row's header ornament. Box drawing adds a dotted rule under
/// the row, edge to edge. Console draws a band from the card's top edge to a
/// rule under the row: the card gives the row half its top padding, the row
/// takes it back below the title, so the card keeps its height.
struct WorkspaceCardHeaderOrnament: ViewModifier {
    let header: SidebarThemeStyle.CardHeader
    let padding: (horizontal: CGFloat, top: CGFloat, bottom: CGFloat)
    let borderWidth: CGFloat
    let cornerRadius: CGFloat
    let rule: Color
    let band: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        let edge = max(0, padding.horizontal - borderWidth)
        switch header {
        case .none:
            content
        case .boxDrawing:
            content.overlay(alignment: .bottom) {
                WorkspaceCardDottedRule(color: rule)
                    .frame(height: 1)
                    .padding(.horizontal, -edge)
            }
        case .console:
            let radius = max(0, cornerRadius - borderWidth)
            content
                .padding(.bottom, padding.top / 2)
                .background(alignment: .top) {
                    VStack(spacing: 0) {
                        band
                        rule.frame(height: 1)
                    }
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: radius,
                        topTrailingRadius: radius,
                        style: .continuous
                    ))
                    .padding(.horizontal, -edge)
                    .padding(.top, -max(0, padding.top / 2 - borderWidth))
                    .allowsHitTesting(false)
                }
        }
    }
}

/// Datasheet Mono's hover brackets: four L corners just outside a clickable
/// thing's frame, drawn only under the pointer. Changes no layout.
struct SidebarHoverBrackets: View {
    let color: Color
    var arm: CGFloat = 7
    var outset: CGFloat = 5
    var lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let near = -outset + lineWidth / 2
            let reach = -outset + arm
            Path { path in
                // top leading
                path.move(to: CGPoint(x: near, y: reach))
                path.addLine(to: CGPoint(x: near, y: near))
                path.addLine(to: CGPoint(x: reach, y: near))
                // top trailing
                path.move(to: CGPoint(x: w - reach, y: near))
                path.addLine(to: CGPoint(x: w - near, y: near))
                path.addLine(to: CGPoint(x: w - near, y: reach))
                // bottom trailing
                path.move(to: CGPoint(x: w - near, y: h - reach))
                path.addLine(to: CGPoint(x: w - near, y: h - near))
                path.addLine(to: CGPoint(x: w - reach, y: h - near))
                // bottom leading
                path.move(to: CGPoint(x: reach, y: h - near))
                path.addLine(to: CGPoint(x: near, y: h - near))
                path.addLine(to: CGPoint(x: near, y: h - reach))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .miter))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Terminal Grid's legend line above the sidebar foot.
struct SidebarThemeLegend: View {
    let style: SidebarThemeStyle
    @Environment(\.chromeScaleTokens) private var chromeTokens

    var body: some View {
        Text(String(
            localized: "sidebar.themeLegend",
            defaultValue: "\u{2500} legend \u{2500}  \u{25C6} needs you  \u{25B6} running  \u{25A1} idle  \u{25AA} cold"
        ))
        .font(ThemeFontFamily.font(
            named: style.monoFamily ?? "system-mono",
            size: 9 * chromeTokens.multiplier,
            weight: .regular,
            defaultDesign: .monospaced
        ))
        .foregroundColor(style.cardTextDim ?? .secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// Outrun Horizon's marble bust (the prototype's SVG, viewBox 100 x 120).
struct SidebarMarbleBust: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 100
        let sy = rect.height / 120
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var path = Path()
        path.move(to: p(50, 4))
        path.addCurve(to: p(23, 28), control1: p(34, 4), control2: p(24, 14))
        path.addLine(to: p(20, 34))
        path.addCurve(to: p(12, 50), control1: p(18, 40), control2: p(13, 44))
        path.addLine(to: p(17, 54))
        path.addCurve(to: p(19, 62), control1: p(15, 58), control2: p(16, 60))
        path.addCurve(to: p(20, 70), control1: p(16, 64), control2: p(16, 68))
        path.addCurve(to: p(36, 76), control1: p(24, 74), control2: p(30, 76))
        path.addLine(to: p(40, 88))
        path.addCurve(to: p(18, 104), control1: p(38, 95), control2: p(28, 100))
        path.addLine(to: p(18, 116))
        path.addLine(to: p(82, 116))
        path.addLine(to: p(82, 104))
        path.addCurve(to: p(64, 86), control1: p(72, 100), control2: p(66, 94))
        path.addLine(to: p(66, 70))
        path.addCurve(to: p(78, 34), control1: p(76, 64), control2: p(80, 50))
        path.addCurve(to: p(50, 4), control1: p(78, 20), control2: p(70, 6))
        path.closeSubpath()
        // Curls.
        let curls: [(CGFloat, CGFloat, CGFloat)] = [(36, 11, 7), (47, 7, 7), (59, 8, 7), (69, 14, 7), (76, 24, 7), (79, 36, 6), (30, 18, 6)]
        for (cx, cy, r) in curls {
            path.addEllipse(in: CGRect(
                x: rect.minX + (cx - r) * sx,
                y: rect.minY + (cy - r) * sy,
                width: 2 * r * sx,
                height: 2 * r * sy
            ))
        }
        // Plinth.
        path.addRect(CGRect(x: rect.minX + 24 * sx, y: rect.minY + 112 * sy, width: 52 * sx, height: 8 * sy))
        return path
    }
}

/// The bust rising out of the Waiting Agent pill's bottom edge, behind its
/// text. Sized from the pill's height as in the prototype (62pt in a 48pt pill,
/// 9pt below the edge, 46pt from the trailing edge).
struct SidebarWaitingPillBust: View {
    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height * 62 / 48
            let width = height * 100 / 120
            SidebarMarbleBust()
                .fill(LinearGradient(
                    colors: [Color.white, Color(.sRGB, red: 1, green: 0xDC / 255, blue: 0xF4 / 255, opacity: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: width, height: height)
                .opacity(0.96)
                .shadow(color: Color.white.opacity(0.45), radius: 2.5)
                .position(
                    x: proxy.size.width - proxy.size.height * 46 / 48 - width / 2,
                    y: proxy.size.height + height * 9 / 62 - height / 2
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The Waiting Agent pill's lit colours (C11H-344: waiting is white), as hex.
///
/// c11's own pill (no theme `[chrome.pill]`) is a void button in both theme
/// slots: it rests on `BrandColors.surface`. So it lights with the Dark slot's
/// waiting colour and ink, white with near-black text, and in the Light slot it
/// also takes an edge in that slot's waiting colour (near-black), so the white
/// pill keeps its outline on a light sidebar. A theme pill keeps its own fill,
/// ink and border; these are only its last fallbacks, in the slot's colours.
/// A theme's `[states]` waiting and waitingInk win throughout.
struct SidebarWaitingPillColors: Equatable {
    let fillHex: String
    let inkHex: String
    let edgeHex: String

    static func resolve(states: ThemeStatePalette, lightSlot: Bool, themedPill: Bool) -> SidebarWaitingPillColors {
        let slot = Workspace.resolvedSurfaceTabActivityColors(lightBackground: lightSlot, states: states)
        let void = themedPill ? slot : Workspace.resolvedSurfaceTabActivityColors(lightBackground: false, states: states)
        let fill = void.waitingHex ?? slot.waitingHex ?? ""
        return SidebarWaitingPillColors(
            fillHex: fill,
            inkHex: void.waitingInkHex ?? "",
            edgeHex: themedPill ? fill : (slot.waitingHex ?? fill)
        )
    }

    var fill: Color { Self.color(fillHex) }
    var ink: Color { Self.color(inkHex) }
    var edge: Color { Self.color(edgeHex) }

    private static func color(_ hex: String) -> Color {
        Color(nsColor: NSColor(hex: hex) ?? BrandColors.white)
    }
}

/// The count badge in the Waiting Agent and Flagged pills: today's capsule, or
/// a near-square that follows a theme's `geometry.pillRadius`.
struct SidebarPillBadgeShape: Shape {
    var radius: CGFloat?

    func path(in rect: CGRect) -> Path {
        guard let radius else { return Capsule(style: .continuous).path(in: rect) }
        return RoundedRectangle(cornerRadius: min(radius / 2, 2), style: .continuous).path(in: rect)
    }
}

/// Big Board's LIVE and HOLD tags share one fixed slot per font, measured once
/// from the wider tag in the running language (translations differ in width).
@MainActor
enum SidebarStateTagMetrics {
    static let horizontalPadding: CGFloat = 4
    private static var widths: [String: CGFloat] = [:]

    static func slotWidth(family: String?, size: CGFloat, tracking: CGFloat, tags: [String]) -> CGFloat {
        let key = "\(family ?? "")|\(size)|\(tracking)|\(tags.joined(separator: "|"))"
        if let width = widths[key] { return width }
        let font = ThemeFontFamily.nsFont(named: family ?? "system-mono", size: size, weight: .semibold, monospaced: true)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: tracking]
        let text = tags.map { ceil(NSAttributedString(string: $0, attributes: attributes).size().width) }.max() ?? 0
        // One spare point covers SwiftUI's rounding of tracked text.
        let width = max(16, text + 2 * horizontalPadding + 1)
        widths[key] = width
        return width
    }
}

/// The selected card's pointer: a small triangle on the selection bar,
/// aimed out of the sidebar at the content it is showing.
struct WorkspaceCardBeaconPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
