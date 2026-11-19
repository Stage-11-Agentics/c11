import SwiftUI
import Combine
import AppKit
import Bonsplit

// M7 — Surface title bar.
//
// Renders above every terminal surface (and, when mounted, browser/markdown).
// Shows the live description (the surface's `description` metadata key), the
// mailbox cell and, on a terminal, a fixed chip naming the machine. The tab
// already carries the title, so the bar never repeats it. A terminal always has
// the bar (its mailbox cell is permanent); another panel with no description,
// no mail and no chip takes no height. Collapsed it is one truncated line;
// expanded it is the full description (Markdown subset), capped and scrollable.
// Title and description editing live on the tab (context menu and the metadata
// CLI), not in this bar.

/// The persistence mark drawn in the session chip. `.none` still reserves its slot.
enum SessionMark: Equatable {
    case none
    case notKept
    case reconnecting
}

/// Wiring audit gap 6: the producer of the "where it runs" chip for LOCAL
/// terminals. Remote terminals are fed by `HCRemoteStatusBinding`; a local one
/// follows its own hc lifecycle here. Local inventory records carry no machine
/// name (the address is `tN`, not `machine/tN`), so the feed supplies this
/// computer's name on every note, or the name a live record did carry, which it
/// keeps for the `.unresolved` and `.new` states that have no record. A remote
/// terminal gets no subscription, so the two producers never write one panel.
enum LocalSessionPlacementFeed {
    /// This computer's name, read once. Not `Host.name`, which can wait on DNS.
    static let localHostName: String = {
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? ProcessInfo.processInfo.hostName : name
    }()

    private final class Retained { var name: String? }

    static func follow<P: Publisher>(
        lifecycle: P,
        persistence: @escaping () -> HCPersistence,
        isRemote: Bool,
        hostName: String = LocalSessionPlacementFeed.localHostName,
        note: @escaping (HCLifecycle, HCPersistence, String?) -> Void
    ) -> AnyCancellable? where P.Output == HCLifecycle, P.Failure == Never {
        guard !isRemote else { return nil }
        let retained = Retained()
        return lifecycle.sink { value in
            if case .live(let record) = value,
               let name = record.machineName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                retained.name = name
            }
            note(value, persistence(), retained.name ?? hostName)
        }
    }
}

/// Fixed-width host chip for one terminal. Built from `HCLifecycle` by `make`;
/// the title bar copies it and does not measure fonts on the sidebar path.
struct SessionPlacement: Equatable {
    var machineName: String
    var mark: SessionMark
    /// C11H-126: the machine's roster id (`local` for this Mac, else hc's
    /// lower-cased machine name). Empty when no machine is known yet.
    var machineKey: String = ""
    /// The roster color, filled in at draw time by `applyingRoster`. Stored
    /// placements keep it nil, so a roster edit never touches workspace state.
    var tint: String? = nil

    /// English samples the width is measured from. A translation must not move the chip.
    static let hostSample = "Notebook"
    static let notKeptSample = "not kept"
    static let reconnectingSample = "Reconnecting"
    static let layoutSpace = "titlebar.session.layout"
    static let chipAccessibilityIdentifier = "titlebar.session.chip"

    /// Map a lifecycle onto the chip. `.live` reads `machineName` from the record
    /// and, when that is empty, the retained name, so a local terminal still
    /// shows its host. A record name wins. The side `machineName` is that
    /// retained name, also used for `.unresolved` and `.new`. `.unresolved` is
    /// Reconnecting and never "not kept", whatever `persistence` says, except
    /// for a fresh terminal that has no session yet, which shows its machine.
    /// `.ended` draws nothing: the evidence has no machine.
    static func make(
        lifecycle: HCLifecycle,
        persistence: HCPersistence,
        machineName: String?,
        isLocal: Bool = false
    ) -> SessionPlacement? {
        let retained = normalized(machineName)
        switch lifecycle {
        case .new:
            guard persistence == .nonpersistent else { return nil }
            return chip(machine: retained, mark: .notKept, isLocal: isLocal)
        case .live(let record):
            let mark: SessionMark = persistence == .nonpersistent ? .notKept : .none
            let name = normalized(record.machineName)
            return chip(machine: name.isEmpty ? retained : name, mark: mark, isLocal: isLocal)
        case .ended:
            return nil
        case .unresolved(let identity, .creationPending) where identity.origin == .fresh && identity.key == nil:
            // C11H-205: a new terminal that has never had a session is
            // starting, not reconnecting; "this session is unchanged" was false.
            return chip(machine: retained, mark: .none, isLocal: isLocal)
        case .unresolved:
            return chip(machine: retained, mark: .reconnecting, isLocal: isLocal)
        }
    }

    /// C11H-126: the chip as drawn, with the roster's name and color for this
    /// machine. Unset roster fields keep the name the chip had and no tint.
    func applyingRoster(_ entry: MachineRosterEntry?) -> SessionPlacement {
        var resolved = self
        if let name = entry?.name { resolved.machineName = name }
        resolved.tint = entry?.color
        return resolved
    }

    func applyingRoster(_ roster: MachineRoster) -> SessionPlacement {
        guard !machineKey.isEmpty else { return self }
        return applyingRoster(roster.entry(id: machineKey))
    }

    /// Terminals draw the stored chip. Browsers, markdown, and a missing panel do not.
    static func shown(on panelType: PanelType?, stored: SessionPlacement?) -> SessionPlacement? {
        guard panelType == .terminal else { return nil }
        return stored
    }

    /// C11H-126: the host slot is as wide as the widest configured roster
    /// name, never narrower than `hostSample` and never wider than
    /// twice it. One roster drives every panel, so every chip is the same
    /// width; a longer name truncates.
    static let hostSlotCapFactor: CGFloat = 2

    static func hostSlot(font: NSFont, configuredNames: [String]) -> CGFloat {
        let floor = ceil(textWidth(hostSample, font: font))
        let widest = configuredNames.map { ceil(textWidth($0, font: font)) }.max() ?? 0
        return min(max(floor, widest), ceil(floor * hostSlotCapFactor))
    }

    static func metrics(multiplier: CGFloat, configuredNames: [String] = []) -> SessionChipMetrics {
        metrics(multiplier: multiplier) { font in
            hostSlot(font: font, configuredNames: configuredNames)
        }
    }

    /// The live chip metrics: the roster's names, measured once per change.
    static func metrics(multiplier: CGFloat, roster: MachineRoster) -> SessionChipMetrics {
        metrics(multiplier: multiplier) { font in
            roster.widthCache.width(fontSize: font.pointSize) {
                hostSlot(font: font, configuredNames: roster.configuredNames())
            }
        }
    }

    /// The live chip metrics in a theme's `[type.chip]`. The slots are measured
    /// in the themed font (cached per style, size and roster revision); the row
    /// height stays the system font's, so the bar never changes height.
    static func metrics(multiplier: CGFloat, roster: MachineRoster, textStyle: ThemeTextStyle) -> SessionChipMetrics {
        guard !textStyle.isUnset else { return metrics(multiplier: multiplier, roster: roster) }
        let key = ThemedChipMetricsCache.Key(multiplier: multiplier, style: textStyle, rosterRevision: roster.revision)
        if let cached = ThemedChipMetricsCache.shared.value(for: key) { return cached }
        let style = SessionChipTheme(textStyle: textStyle)
        let base = metrics(multiplier: multiplier)
        var themed = metrics(multiplier: multiplier, hostSlot: { font in
            let names = roster.configuredNames().map { textStyle.apply($0) }
            return hostSlot(font: font, configuredNames: names, sample: textStyle.apply(hostSample), kern: style.kern(font.pointSize))
        }, font: { style.nsFont($0) }, kern: { style.kern($0) }, transform: { textStyle.apply($0) })
        themed.rowHeight = base.rowHeight
        ThemedChipMetricsCache.shared.store(themed, for: key)
        return themed
    }

    static func hostSlot(font: NSFont, configuredNames: [String], sample: String, kern: CGFloat?) -> CGFloat {
        let floor = ceil(textWidth(sample, font: font, kern: kern))
        let widest = configuredNames.map { ceil(textWidth($0, font: font, kern: kern)) }.max() ?? 0
        return min(max(floor, widest), ceil(floor * hostSlotCapFactor))
    }

    private static func metrics(
        multiplier: CGFloat,
        hostSlot measureHost: (NSFont) -> CGFloat,
        font makeFont: (CGFloat) -> NSFont = { NSFont.systemFont(ofSize: $0, weight: .semibold) },
        kern: (CGFloat) -> CGFloat? = { _ in nil },
        transform: (String) -> String = { $0 }
    ) -> SessionChipMetrics {
        let hostFontSize = (12 * multiplier) + 1
        let markFontSize = (12 * multiplier) - 1
        let hostFont = makeFont(hostFontSize)
        let markFont = makeFont(markFontSize)
        let titleFont = NSFont.systemFont(ofSize: 12 * multiplier)
        let hostSlot = measureHost(hostFont)
        let markKern = kern(markFont.pointSize)
        let markSlot = ceil(max(
            textWidth(transform(notKeptSample), font: markFont, kern: markKern),
            textWidth(transform(reconnectingSample), font: markFont, kern: markKern)
        ))
        let pad = ceil(6 * multiplier)
        let gap = ceil(6 * multiplier)
        let titleLine = ceil(titleFont.ascender - titleFont.descender + titleFont.leading) + 4
        let hostLine = ceil(hostFont.ascender - hostFont.descender + hostFont.leading) + 4
        return SessionChipMetrics(
            pad: pad,
            gap: gap,
            hostFontSize: hostFontSize,
            markFontSize: markFontSize,
            hostSlot: hostSlot,
            markSlot: markSlot,
            width: pad + hostSlot + gap + markSlot + pad,
            rowHeight: max(titleLine, hostLine, 18)
        )
    }

    static func chipWidth(multiplier: CGFloat) -> CGFloat {
        metrics(multiplier: multiplier).width
    }

    static func chipRowHeight(multiplier: CGFloat) -> CGFloat {
        metrics(multiplier: multiplier).rowHeight
    }

    var markText: String {
        switch mark {
        case .none:
            return ""
        case .notKept:
            return String(localized: "titlebar.session.notKept", defaultValue: "not kept")
        case .reconnecting:
            return String(localized: "titlebar.session.reconnecting", defaultValue: "Reconnecting")
        }
    }

    var help: String? {
        switch mark {
        case .none:
            return nil
        case .notKept:
            return String(
                localized: "titlebar.session.notKept.help",
                defaultValue: "This session will not survive a restart. Plain-shell fallback."
            )
        case .reconnecting:
            return String(
                localized: "titlebar.session.reconnecting.help",
                defaultValue: "This session is unchanged. c11 is waiting to reach it again."
            )
        }
    }

    /// What VoiceOver reads as the chip's label: where the terminal runs. A bare
    /// host name carries no context, so the label says what it names. When the
    /// chip has only a mark (no machine known yet) the label names the chip.
    var accessibilityLabel: String {
        guard !machineName.isEmpty else {
            return String(
                localized: "titlebar.session.accessibility.label.noMachine",
                defaultValue: "Where this terminal runs"
            )
        }
        return String(
            format: String(
                localized: "titlebar.session.accessibility.label.machine",
                defaultValue: "Runs on %@"
            ),
            machineName
        )
    }

    /// The chip's accessibility value: the visible mark word ("not kept",
    /// "Reconnecting"), or empty when the session is simply running.
    var accessibilityValue: String { markText }

    /// C11H-166: what VoiceOver says and AXDescription carries: where it runs,
    /// then the mark when there is one ("Runs on Studio, Reconnecting").
    var spokenLabel: String {
        markText.isEmpty ? accessibilityLabel : "\(accessibilityLabel), \(markText)"
    }

    private static func normalized(_ name: String?) -> String {
        name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func chip(machine: String, mark: SessionMark, isLocal: Bool) -> SessionPlacement? {
        guard !machine.isEmpty || mark != .none else { return nil }
        // hc names machines in lower case ("studio"); the chip reads "Studio".
        let key: String
        if isLocal {
            key = MachineRoster.localID
        } else {
            key = MachineRoster.normalizedID(machine) ?? ""
        }
        return SessionPlacement(machineName: HCMachineTarget.displayName(machine), mark: mark, machineKey: key)
    }

    private static func textWidth(_ text: String, font: NSFont, kern: CGFloat? = nil) -> CGFloat {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let kern { attributes[.kern] = kern }
        return (text as NSString).size(withAttributes: attributes).width
    }
}

/// The description chip in a schema-2 theme: `chipFill`, `chipBorder`,
/// `chipText`, `geometry.chipRadius` and `[type.chip]`. Every field is
/// optional; `.unset` draws today's chip.
struct SessionChipTheme: Equatable {
    var fill: Color?
    var border: Color?
    var text: Color?
    var radius: CGFloat?
    var textStyle: ThemeTextStyle = .unset

    static let unset = SessionChipTheme()

    /// The chip's text at `size` (the view's own size): semibold system type
    /// today, else the theme's family, scale, weight, case and tracking.
    func styled(_ string: String, size: CGFloat) -> Text {
        guard !textStyle.isUnset else {
            return Text(string).font(.system(size: size, weight: .semibold))
        }
        let text = Text(textStyle.apply(string))
            .font(textStyle.font(baseSize: size, defaultWeight: .semibold))
        guard textStyle.tracking != nil else { return text }
        return text.tracking(textStyle.trackingPoints(baseSize: size))
    }

    /// The AppKit font the chip measures with, at the view's own `size`.
    func nsFont(_ size: CGFloat) -> NSFont {
        let scaled = size * CGFloat(textStyle.scale ?? 1)
        let weight: NSFont.Weight
        switch textStyle.weight {
        case "regular": weight = .regular
        case "medium": weight = .medium
        case "bold": weight = .bold
        case "heavy": weight = .heavy
        default: weight = .semibold
        }
        return ThemeFontFamily.nsFont(named: textStyle.familyName, size: scaled, weight: weight, monospaced: false)
    }

    /// Kerning for an already-scaled font of `size`, or nil when the style sets none.
    func kern(_ size: CGFloat) -> CGFloat? {
        textStyle.tracking.map { CGFloat($0) * size }
    }
}

/// Themed chip metrics, keyed by style, size and roster revision. Small and
/// bounded: a theme switch or roster edit adds a key, and the cache resets past 32.
final class ThemedChipMetricsCache: @unchecked Sendable {
    struct Key: Hashable {
        var multiplier: CGFloat
        var family: String?
        var scale: Double?
        var weight: String?
        var uppercase: Bool?
        var tracking: Double?
        var rosterRevision: Int

        init(multiplier: CGFloat, style: ThemeTextStyle, rosterRevision: Int) {
            self.multiplier = multiplier
            family = style.familyName
            scale = style.scale
            weight = style.weight
            uppercase = style.uppercase
            tracking = style.tracking
            self.rosterRevision = rosterRevision
        }
    }

    static let shared = ThemedChipMetricsCache()

    private let lock = NSLock()
    private var values: [Key: SessionChipMetrics] = [:]

    func value(for key: Key) -> SessionChipMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func store(_ metrics: SessionChipMetrics, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if values.count >= 32 { values.removeAll() }
        values[key] = metrics
    }
}

struct SessionChipMetrics: Equatable {
    var pad: CGFloat
    var gap: CGFloat
    var hostFontSize: CGFloat
    var markFontSize: CGFloat
    var hostSlot: CGFloat
    var markSlot: CGFloat
    var width: CGFloat
    var rowHeight: CGFloat
}

/// C11H-126: the where-it-runs chip. It observes the machine roster, so a
/// name or color set in Settings or by `c11 machine set` repaints every open
/// chip at once. Every chip shares one width (`SessionPlacement.metrics`).
struct SessionChipView: View {
    let placement: SessionPlacement
    let multiplier: CGFloat
    let rowHeight: CGFloat
    let foreground: Color
    let secondaryForeground: Color
    let border: Color
    /// The bar's background in the current appearance, for the text contrast.
    let barBackground: NSColor
    let colorScheme: ColorScheme
    /// Schema-2 `[chrome.descriptionBar]`, `chipRadius` and `[type.chip]`; `.unset` draws today's chip.
    var theme: SessionChipTheme = .unset

    @ObservedObject private var roster = MachineRoster.shared

    var body: some View {
        // `revision` is read so a roster change redraws this chip.
        let _ = roster.revision
        let metrics = SessionPlacement.metrics(multiplier: multiplier, roster: roster, textStyle: theme.textStyle)
        let shown = placement.applyingRoster(roster)
        // c11h: the machine a terminal runs on is the bar's focal point
        // (Atin, 2026-11-03): white on black inside a strong white border, in
        // every theme and appearance. The roster names the machine, and its
        // color is a small square before the name.
        let radius = theme.radius ?? 4
        let tint = shown.tint.flatMap(MachineRosterColor.nsColor)
        let dot = Self.colorSlot(multiplier: multiplier, roster: roster)
        let chip = HStack(spacing: metrics.gap) {
            if dot > 0 {
                Rectangle()
                    .fill(tint.map { Color(nsColor: $0) } ?? Color.clear)
                    .frame(width: dot - metrics.gap, height: dot - metrics.gap)
            }
            theme.styled(shown.machineName, size: metrics.hostFontSize)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: metrics.hostSlot, alignment: .leading)
            theme.styled(shown.markText, size: metrics.markFontSize)
                .foregroundColor(markColor(shown.mark, text: shown.mark == .reconnecting ? Color.white.opacity(0.7) : nil))
                .lineLimit(1)
                .frame(width: metrics.markSlot, alignment: .leading)
        }
        .padding(.horizontal, metrics.pad)
        .frame(width: metrics.width + dot, height: rowHeight, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: radius)
                .fill(Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Color.white, lineWidth: 1.5)
        )
        // C11H-166: one plain text element for AppKit. A container with its
        // children ignored and an empty value reached AX with no description.
        .accessibilityRepresentation {
            Text(shown.spokenLabel)
        }
        .accessibilityLabel(Text(shown.spokenLabel))
        .accessibilityIdentifier(SessionPlacement.chipAccessibilityIdentifier)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)

        if let help = shown.help {
            chip.help(help)
        } else {
            chip
        }
    }

    /// c11h: the width a roster color square takes inside every chip (its
    /// side plus a gap), or zero when no machine has a color. Every chip
    /// reserves it alike, so all chips stay one width.
    static func colorSlot(multiplier: CGFloat, roster: MachineRoster) -> CGFloat {
        roster.all().contains(where: { $0.color != nil }) ? ceil(8 * multiplier) + 4 : 0
    }

    /// On a tinted chip the mark uses the contrast color too: orange or gray
    /// on an arbitrary tint can be unreadable.
    private func markColor(_ mark: SessionMark, text: Color?) -> Color {
        switch mark {
        case .none:
            return .clear
        case .notKept:
            return text ?? .orange
        case .reconnecting:
            return text?.opacity(0.8) ?? secondaryForeground
        }
    }

    /// Black or white, whichever reads better on the tint composited over the
    /// bar in this appearance.
    static func contrastText(fill: String, background: NSColor, scheme: ColorScheme) -> Color {
        let white = MachineRosterColor.prefersWhiteText(
            fill: fill,
            background: srgb(background, dark: scheme == .dark)
        )
        return white ? .white : .black
    }

    /// The bar color in sRGB as this appearance draws it. A translucent theme
    /// color is taken as drawn over a neutral window background.
    static func srgb(_ color: NSColor, dark: Bool) -> (r: Double, g: Double, b: Double) {
        let fallback: (r: Double, g: Double, b: Double) = dark ? (0.12, 0.12, 0.12) : (0.93, 0.93, 0.93)
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return fallback }
        var result = fallback
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            let a = Double(rgb.alphaComponent)
            result = (
                Double(rgb.redComponent) * a + fallback.r * (1 - a),
                Double(rgb.greenComponent) * a + fallback.g * (1 - a),
                Double(rgb.blueComponent) * a + fallback.b * (1 - a)
            )
        }
        return result
    }
}

struct PanelTitleBarState: Equatable {
    var title: String?
    var description: String?
    var titleSource: MetadataSource?
    var descriptionSource: MetadataSource?
    /// C11H-278: when the description text last changed; drives its age label.
    var descriptionUpdatedAt: Date? = nil
    var visible: Bool = true
    var collapsed: Bool = true
    /// The panel's `mailbox.address`, shown in the mailbox drawer's header.
    var mailboxAddress: String?
    /// The bar shows the mailbox cell (C11-397); see `showsMailbox(panelType:hasMail:)`.
    var showsMailbox: Bool = false
    /// Terminal session chip. Nil hides it and, with no description or mail, the whole bar.
    var placement: SessionPlacement? = nil
    /// c11h: a terminal reserves the ⓘ and chip slots before its placement
    /// arrives and after its session ends, so the mailbox cell and the
    /// subtitle after them never move.
    var isTerminal: Bool = false

    var hasDescription: Bool {
        !(description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// The bar renders when the workspace shows title bars and the surface has a
    /// description, a mailbox, or a session chip. Everything that reserves space
    /// for the bar (the portal's top frame edge included) keys off this.
    var rendersBar: Bool {
        visible && (hasDescription || showsMailbox || placement != nil)
    }

    /// Every terminal panel shows the mailbox cell from the start, mail or
    /// not, so a new agent's mailbox is reachable and the bar never appears
    /// when an agent is detected or its first mail lands. A browser or
    /// markdown panel shows it once it has received or sent mail.
    static func showsMailbox(panelType: PanelType?, hasMail: Bool) -> Bool {
        panelType == .terminal || hasMail
    }
}

/// Maximum description render region: ~5 × line height at 11pt.
/// Used as an explicit frame cap when the description exceeds 5 lines.
let titleBarDescriptionMaxHeight: CGFloat = 90

struct PanelTitleBarView: View {
    let state: PanelTitleBarState
    /// Layout oracle. Nil in production, so the bar mounts no GeometryReader for it.
    /// It stays ahead of `onToggleCollapsed` so a trailing closure is still the toggle.
    var onLayout: ((String, CGRect) -> Void)? = nil
    var onToggleCollapsed: () -> Void = {}
    /// The panel's workspace and id, for the mailbox cell (C11-397). Without
    /// them the bar shows only the description.
    var workspace: Workspace? = nil
    var panelId: UUID? = nil
    var isVisibleInUI: Bool = true

    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chromeScaleTokens) private var chromeTokens
    /// c11 (C11H-197): the hosting window's theme override.
    @Environment(\.c11WindowThemeName) private var windowThemeName
    @AppStorage(ThemeAppStorage.Keys.m1bSurfaceTitleBarMigrated, store: ThemeAppStorage.defaults)
    private var m1bSurfaceTitleBarMigrated = false
    @State private var measuredDescriptionHeight: CGFloat = 0
    /// The width the description gets beside the mailbox cell and chevron slot.
    @State private var descriptionWidth: CGFloat = 0
    @StateObject private var drawerPresenter = CollapsedSheetPresenter()
    @StateObject private var drawerGeometry = MailboxDrawerGeometry()
    @State private var isDrawerOpen = false
    @State private var showsHerderCores = false
    @State private var barWidth: CGFloat = 0
    /// This bar's mailbox cell is counted as on screen by the badge store.
    @State private var cellRegistered = false
    /// C11H-278: the age's style for this bar's width (`nextAgeStyle`).
    @State private var ageStyle: DescriptionAge.Style = .compact

    private var descriptionText: String {
        state.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var effectiveCollapsed: Bool {
        state.collapsed
    }

    private var themeContext: ThemeContext {
        themeManager.makeContext(colorScheme: colorScheme, windowThemeName: windowThemeName)
    }

    private var useThemeMigrationPath: Bool {
        themeManager.themedPathLive(flag: m1bSurfaceTitleBarMigrated, windowThemeName: windowThemeName)
    }

    private var resolvedBackgroundColor: NSColor {
        guard useThemeMigrationPath,
              let color: NSColor = themeManager.resolve(.titleBar_background, context: themeContext) else {
            return NSColor.windowBackgroundColor
        }
        return color
    }

    private var resolvedBackgroundOpacity: Double {
        guard useThemeMigrationPath,
              let opacity: Double = themeManager.resolve(.titleBar_backgroundOpacity, context: themeContext) else {
            return 0.85
        }
        return opacity
    }

    private var resolvedForegroundColor: Color {
        guard useThemeMigrationPath,
              let color: NSColor = themeManager.resolve(.titleBar_foreground, context: themeContext) else {
            return .primary
        }
        return Color(nsColor: color)
    }

    private var resolvedSecondaryForegroundColor: Color {
        guard useThemeMigrationPath,
              let color: NSColor = themeManager.resolve(.titleBar_foregroundSecondary, context: themeContext) else {
            return .secondary
        }
        return Color(nsColor: color)
    }

    private var resolvedBottomBorderColor: Color {
        guard useThemeMigrationPath,
              let color: NSColor = themeManager.resolve(.titleBar_borderBottom, context: themeContext) else {
            return Color(nsColor: NSColor.separatorColor)
        }
        return Color(nsColor: color)
    }

    var body: some View {
        if !state.rendersBar {
            EmptyView()
        } else {
            descriptionBar
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .padding(.trailing, mailboxModel == nil ? 12 : 6)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(nsColor: resolvedBackgroundColor)
                        .opacity(resolvedBackgroundOpacity)
                )
                .overlay(
                    Rectangle()
                        .fill(resolvedBottomBorderColor)
                        .frame(height: 1),
                    alignment: .bottom
                )
                .overlay {
                    if let opacity = ThemeOrnaments.scanlinesOpacity(themeManager, windowThemeName: windowThemeName) {
                        BonsplitScanlines(opacity: opacity)
                    }
                }
                // The mailbox drawer hangs flush under the whole bar.
                .background(CollapsedSheetAnchorReader { drawerPresenter.anchorView = $0 })
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { barWidth = geometry.size.width }
                            .onChange(of: geometry.size.width) { barWidth = $0 }
                    }
                )
                .accessibilityElement(children: .contain)
                // An open drawer follows the area's width in place; the
                // presenter re-hangs it when its size changes.
                .onChange(of: barWidth) { _ in if isDrawerOpen { updateDrawerGeometry() } }
                .onChange(of: isVisibleInUI) { visible in
                    if !visible { closeDrawer(animated: false) }
                    updateCellRegistration(visible && mailboxModel != nil)
                }
                .onDisappear {
                    closeDrawer(animated: false)
                    updateCellRegistration(false)
                }
        }
    }

    // MARK: - Mailbox (C11-397)

    private var mailboxModel: MailboxBadgeModel? {
        guard state.showsMailbox, let workspace, let panelId else { return nil }
        return MailboxBadgeStore.shared.model(workspace: workspace, panelId: panelId)
    }

    private var drawerStyle: MailboxDrawerStyle {
        MailboxDrawerStyle(
            background: resolvedBackgroundColor.withAlphaComponent(1),
            foreground: resolvedForegroundColor,
            secondary: resolvedSecondaryForegroundColor,
            border: resolvedBottomBorderColor,
            scale: chromeTokens.surfaceTitleBarTitle / 12
        )
    }

    private func toggleDrawer() {
        if isDrawerOpen {
            closeDrawer(animated: true)
        } else {
            presentDrawer()
        }
    }

    private func closeDrawer(animated: Bool) {
        guard isDrawerOpen || drawerPresenter.isPresented else { return }
        isDrawerOpen = false
        drawerPresenter.onDismiss = nil
        if animated { drawerPresenter.dismissAnimated() } else { drawerPresenter.dismiss() }
    }

    /// Kept-alive hidden workspaces stay mounted, so "on screen" also needs
    /// the panel to be visible; the store reconciles on-screen cells faster.
    private func updateCellRegistration(_ registered: Bool) {
        guard let panelId, registered != cellRegistered else { return }
        cellRegistered = registered
        if registered {
            MailboxBadgeStore.shared.cellAppeared(panelId: panelId)
        } else {
            MailboxBadgeStore.shared.cellDisappeared(panelId: panelId)
        }
    }

    /// The drawer is its area's width (320 pt minimum) and at most 70% of
    /// the window's height.
    private func updateDrawerGeometry() {
        let window = drawerPresenter.anchorView?.window
        let windowHeight = window?.contentLayoutRect.height ?? 800
        let screenWidth = window?.screen?.visibleFrame.width ?? 4000
        drawerGeometry.update(
            width: min(max(barWidth, 320), screenWidth),
            maxHeight: max(220, windowHeight * 0.7)
        )
    }

    private func presentDrawer() {
        guard let model = mailboxModel, let workspace, let panelId else { return }
        updateDrawerGeometry()
        let workspaceId = workspace.id
        let drawer = MailboxDrawerView(
            model: model,
            panelTitle: state.title,
            panelNumber: TerminalController.shared.surfaceOrdinal(forSurfaceUUID: panelId),
            mailboxAddress: state.mailboxAddress,
            inboxURL: MailboxBadgeStore.shared.inboxURL(workspaceId: workspaceId, panelId: panelId),
            geometry: drawerGeometry,
            style: drawerStyle,
            resolveSenders: { names in Self.resolveSenders(names, preferring: workspaceId) },
            onClose: { [weak presenter = drawerPresenter, open = $isDrawerOpen] in
                // Same path as a second click on the envelope.
                open.wrappedValue = false
                presenter?.onDismiss = nil
                presenter?.dismissAnimated()
            },
            resolvePanels: { ids in Self.resolvePanels(ids) },
            onOpenGlobalView: { [weak presenter = drawerPresenter, weak workspace, open = $isDrawerOpen] in
                open.wrappedValue = false
                presenter?.onDismiss = nil
                presenter?.dismissAnimated()
                guard let workspace else { return }
                MessagesPageWeb.open(centredOn: panelId, in: workspace)
            }
        )
        // Capture the binding, not the view: the view holds the presenter and
        // the workspace, and the presenter holds this closure.
        let open = $isDrawerOpen
        drawerPresenter.onDismiss = { open.wrappedValue = false }
        // Opening is a reason to recount: a hand-dropped file would otherwise
        // wait for the reconcile while the drawer already lists it.
        MailboxBadgeStore.inboxChanged(workspaceId: workspaceId, panelId: panelId)
        isDrawerOpen = true
        drawerPresenter.present(rootView: AnyView(drawer))
        if !drawerPresenter.isPresented { isDrawerOpen = false }
    }

    /// Matches each `from` the way the dispatcher matches a `to` (address,
    /// then role, then title), preferring a panel in the reader's workspace.
    static func resolveSenders(_ names: [String], preferring workspaceId: UUID) -> [String: MailboxDrawerSender] {
        let panels = AppDelegate.shared?.mailboxAddressableSurfaces() ?? []
        var result: [String: MailboxDrawerSender] = [:]
        for name in names where !name.isEmpty {
            let matches = MailboxMatcher.select(MailboxAddress.parse(name), from: panels, identity: { $0.identity })
            guard let match = matches.first(where: { $0.workspaceId == workspaceId }) ?? matches.first else {
                result[name] = MailboxDrawerSender(panelNumber: nil, address: nil, isOpen: false)
                continue
            }
            result[name] = MailboxDrawerSender(
                panelNumber: TerminalController.shared.surfaceOrdinal(forSurfaceUUID: match.surfaceId),
                address: match.address,
                isOpen: true
            )
        }
        return result
    }

    /// Names the panels a conversation is with by id, as the dispatcher's
    /// stamp and the sent ledger record them: an open panel by its number,
    /// address and title; a closed one by the number it had this session, if
    /// any. A panel that is gone is never given a new number.
    static func resolvePanels(_ ids: [UUID]) -> [UUID: MailboxDrawerSender] {
        guard !ids.isEmpty else { return [:] }
        let live = Dictionary(
            (AppDelegate.shared?.mailboxAddressableSurfaces() ?? []).map { ($0.surfaceId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let controller = TerminalController.shared
        let prefix = "\(TerminalController.V2HandleKind.surface.rawValue):"
        var result: [UUID: MailboxDrawerSender] = [:]
        for id in ids {
            if let record = live[id] {
                result[id] = MailboxDrawerSender(
                    panelNumber: controller.surfaceOrdinal(forSurfaceUUID: id),
                    address: record.address,
                    isOpen: true,
                    title: record.name.isEmpty ? nil : record.name
                )
            } else {
                let number = controller.v2RefByUUID[.surface]?[id].flatMap { Int($0.dropFirst(prefix.count)) }
                result[id] = MailboxDrawerSender(panelNumber: number, address: nil, isOpen: false)
            }
        }
        return result
    }

    private var chevronAccessibilityLabel: String {
        if displaysCollapsed {
            return String(localized: "titlebar.chevron.expand",
                          defaultValue: "Expand title bar")
        } else {
            return String(localized: "titlebar.chevron.collapse",
                          defaultValue: "Collapse title bar")
        }
    }

    /// The description with its toggle chevron: one truncated line collapsed,
    /// the full Markdown description (capped, scrollable) expanded.
    private var descriptionBar: some View {
        HStack(alignment: .top, spacing: 6) {
            if state.isTerminal || state.placement != nil {
                herderCoresButton(machineKey: state.placement?.machineKey ?? "")
                if let placement = state.placement {
                    sessionChip(placement)
                } else {
                    SessionChipSlot(multiplier: chromeTokens.topBarMultiplier, textStyle: chipTheme.textStyle)
                }
            }
            // c11h: the mailbox sits beside the machine it belongs to, away
            // from the crowded top-right corner (Atin, 2026-11-03).
            mailboxCell
            Group {
                if displaysCollapsed {
                    collapsedDescription
                } else {
                    // An expanded mail-only bar renders the placeholder the way
                    // it renders a description, so one arriving does not move it.
                    expandedDescription(Self.collapsedLine(descriptionText).isPlaceholder
                        ? Self.collapsedLine(descriptionText).text : descriptionText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: TitleBarDescriptionWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(TitleBarDescriptionWidthKey.self) { newValue in
                if abs(newValue - descriptionWidth) > 0.5 { descriptionWidth = newValue }
                let next = Self.nextAgeStyle(current: ageStyle, descriptionWidth: newValue,
                                             fontSize: chromeTokens.surfaceTitleBarTitle)
                if next != ageStyle { ageStyle = next }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .titleBarMeasure("description", observer: onLayout)
            descriptionAgeSlot
                .titleBarMeasure("descriptionAge", observer: onLayout)
            Button(action: onToggleCollapsed) {
                Image(systemName: displaysCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: chromeTokens.surfaceTitleBarAccessory, weight: .semibold))
                    .foregroundColor(resolvedSecondaryForegroundColor)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(chevronAccessibilityLabel))
            // The chevron shows only when there is more to see: a collapsed
            // line that is cut off, or an expanded description taller than a
            // line. Its slot stays either way, so neither the description nor
            // the mailbox cell moves when it appears.
            .opacity(showsChevron ? 1 : 0)
            .disabled(!showsChevron)
            .accessibilityHidden(!showsChevron)
        }
        .coordinateSpace(name: SessionPlacement.layoutSpace)
        // One height for every collapsed bar (placeholder or description,
        // mailbox cell or not, empty mark or not), so the panel below never
        // moves. Expanded, the bar only grows from there.
        .frame(minHeight: rowHeight, maxHeight: displaysCollapsed ? rowHeight : nil, alignment: .top)
    }

    /// C11H-278: how long ago the description was edited, in a fixed slot
    /// before the chevron that stays when there is none, so neither the
    /// description nor the chevron moves. A panel not on screen (a kept-alive
    /// hidden workspace) holds the empty slot and listens to no clock.
    @ViewBuilder
    private var descriptionAgeSlot: some View {
        let size = chromeTokens.surfaceTitleBarTitle
        if isVisibleInUI {
            DescriptionAgeLabel(
                updatedAt: state.hasDescription ? state.descriptionUpdatedAt : nil,
                style: ageStyle,
                fontSize: size,
                color: resolvedSecondaryForegroundColor.opacity(0.8)
            )
            .padding(.vertical, 2)
        } else {
            Color.clear
                .frame(width: DescriptionAgeMetrics.slotWidth(style: ageStyle, fontSize: size), height: 1)
        }
    }

    /// The subtitle keeps at least this much beside a full-style age.
    static let minimumSubtitleWidth: CGFloat = 240

    /// C11H-278: "edited 12 min ago" where the bar has room, "12m" (full text
    /// on hover) where it does not, so a narrow panel keeps its subtitle. The
    /// subtitle and the age share one width (the subtitle's measured width
    /// plus the slot beside it), which the style does not change, so the
    /// choice cannot flip back and forth. It changes only with the panel's
    /// width, never as the age moves.
    static func nextAgeStyle(current: DescriptionAge.Style, descriptionWidth: CGFloat, fontSize: CGFloat) -> DescriptionAge.Style {
        // An unmeasured bar starts compact and stays so until it has room; a
        // bar squeezed to nothing falls back to compact too.
        let shared = descriptionWidth + DescriptionAgeMetrics.slotWidth(style: current, fontSize: fontSize)
        let full = DescriptionAgeMetrics.slotWidth(style: .full, fontSize: fontSize)
        return shared - full >= minimumSubtitleWidth ? .full : .compact
    }

    private var showsChevron: Bool {
        Self.needsMoreThanOneLine(
            description: descriptionText,
            fontSize: chromeTokens.surfaceTitleBarTitle,
            availableWidth: descriptionWidth
        )
    }

    /// What the bar draws: collapsed when the panel says so, and also when the
    /// description fits on one line, since expanding it would show the same
    /// line. A short description is never stuck expanded with no way back.
    private var displaysCollapsed: Bool {
        Self.displaysCollapsed(
            collapsed: effectiveCollapsed,
            description: descriptionText,
            fontSize: chromeTokens.surfaceTitleBarTitle,
            availableWidth: descriptionWidth
        )
    }

    /// The description needs more than the one collapsed line: that line is
    /// cut off, or the text has its own line breaks. Content alone decides,
    /// so the chevron (shown exactly when this holds) means the same thing
    /// whether the bar is expanded or collapsed. Before the bar has a width
    /// it is false.
    static func needsMoreThanOneLine(description: String, fontSize: CGFloat, availableWidth: CGFloat) -> Bool {
        guard !description.isEmpty, availableWidth > 0 else { return false }
        if description.contains(where: \.isNewline) { return true }
        return lineOverflows(collapsedLine(description).text, fontSize: fontSize, width: availableWidth)
    }

    /// Until the bar has a width, it follows the panel's state so the first
    /// frame matches the last; after that a one-line description draws collapsed.
    static func displaysCollapsed(collapsed: Bool, description: String, fontSize: CGFloat, availableWidth: CGFloat) -> Bool {
        if collapsed { return true }
        guard availableWidth > 0 else { return false }
        return !needsMoreThanOneLine(description: description, fontSize: fontSize, availableWidth: availableWidth)
    }

    /// The line is wider than `width` in the bar's font. Biased by 2 pt
    /// toward overflowing, so a line SwiftUI truncates by a hair still gets
    /// its chevron.
    static func lineOverflows(_ text: String, fontSize: CGFloat, width: CGFloat) -> Bool {
        let natural = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
        return ceil(natural) > width - 2
    }

    /// Fixed width, pinned to the first line beside the machine chip: the
    /// description starts after it and truncates at the bar's end.
    @ViewBuilder
    private var mailboxCell: some View {
        if let model = mailboxModel {
            MailboxCellView(
                model: model,
                isOpen: isDrawerOpen,
                fontSize: chromeTokens.surfaceTitleBarTitle - 1,
                secondary: resolvedSecondaryForegroundColor,
                unreadColor: themeManager.themeOwnsChrome(windowThemeName: windowThemeName)
                    ? themeManager.style(.stateUnread, context: themeContext)
                    : nil,
                unreadTrailing: true,
                action: toggleDrawer
            )
            .background(CollapsedSheetTrailingAnchorReader { drawerPresenter.trailingAnchorView = $0 })
            .onAppear { updateCellRegistration(isVisibleInUI) }
            .onDisappear { updateCellRegistration(false) }
        }
    }

    /// c11h: the ⓘ at the bar's far left. It opens where c11's herder cores
    /// run and how to add another machine.
    private func herderCoresButton(machineKey: String) -> some View {
        Button { showsHerderCores.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: chromeTokens.surfaceTitleBarTitle, weight: .regular))
                .foregroundColor(resolvedSecondaryForegroundColor)
                .frame(width: 16, height: rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "titlebar.herderCores.help", defaultValue: "Where your terminals run, and how to add a machine"))
        .accessibilityLabel(Text(String(localized: "titlebar.herderCores.accessibility", defaultValue: "Herder cores")))
        .accessibilityIdentifier("titlebar.herderCores")
        .popover(isPresented: $showsHerderCores, arrowEdge: .bottom) {
            HerderCoresPopover(currentMachineKey: machineKey) { showsHerderCores = false }
        }
    }

    /// Fixed chip on the first line. The description truncates before this slot.
    private func sessionChip(_ placement: SessionPlacement) -> some View {
        SessionChipView(
            placement: placement,
            multiplier: chromeTokens.topBarMultiplier,
            rowHeight: rowHeight,
            foreground: resolvedForegroundColor,
            secondaryForeground: resolvedSecondaryForegroundColor,
            border: resolvedBottomBorderColor,
            barBackground: resolvedBackgroundColor,
            colorScheme: colorScheme,
            theme: chipTheme
        )
        .titleBarMeasure("chip", observer: onLayout)
    }

    /// Schema-2 chip values. Schema-1 themes define none, so this is `.unset`.
    private var chipTheme: SessionChipTheme {
        // Only schema-2 themes carry chip values; skip the context and lookups
        // on every other bar render (title churn from spinners).
        guard themeManager.themeOwnsChrome(windowThemeName: windowThemeName) else { return .unset }
        let context = themeContext
        return SessionChipTheme(
            fill: themeManager.style(.chipFill, context: context),
            border: themeManager.style(.chipBorder, context: context),
            text: themeManager.style(.chipText, context: context),
            radius: themeManager.style(.chipRadius, context: context),
            textStyle: themeManager.textStyle(.chip, context: context)
        )
    }

    /// The collapsed row's height. A chip uses the fixed metric (host line of
    /// the host font, the description line, or 18), equal for every mark.
    /// Font measurement stays here, off `panelTitleBarState`.
    private var rowHeight: CGFloat {
        if state.placement != nil {
            return SessionPlacement.chipRowHeight(multiplier: chromeTokens.topBarMultiplier)
        }
        let font = NSFont.systemFont(ofSize: chromeTokens.surfaceTitleBarTitle)
        return max(ceil(font.ascender - font.descender + font.leading) + 4, 18)
    }

    private var collapsedDescription: some View {
        // A bar with no description (every terminal shows its mailbox cell) reads a dim placeholder in the same font, so a real
        // description takes its place on the same line without a jump.
        let line = Self.collapsedLine(descriptionText)
        return Text(line.text)
            .font(.system(size: chromeTokens.surfaceTitleBarTitle))
            // c11h: the subtitle reads gray so the machine chip carries the
            // bar's focus (Atin, 2026-11-03). The placeholder is dimmer still.
            .foregroundColor(line.isPlaceholder ? resolvedSecondaryForegroundColor.opacity(0.7) : resolvedSecondaryForegroundColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.vertical, 2)
    }

    /// The collapsed line: the description on one line, or the placeholder
    /// when the bar shows only for its mailbox cell.
    static func collapsedLine(_ description: String) -> (text: String, isPlaceholder: Bool) {
        let line = singleLine(description)
        if line.isEmpty {
            return (String(localized: "titlebar.description.placeholder", defaultValue: "No subtitle set"), true)
        }
        return (line, false)
    }

    /// Newlines and runs of whitespace collapse to single spaces.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    @ViewBuilder
    private func expandedDescription(_ description: String) -> some View {
        let sanitized = sanitizeDescriptionMarkdown(description)
        let markdown = TitleBarDescriptionMarkdown(text: sanitized)
            .environment(\.openURL, OpenURLAction { _ in .discarded })
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TitleBarDescriptionHeightKey.self,
                        value: proxy.size.height
                    )
                }
            )

        Group {
            if measuredDescriptionHeight > titleBarDescriptionMaxHeight {
                ScrollView(.vertical, showsIndicators: true) {
                    markdown
                }
                .frame(height: titleBarDescriptionMaxHeight)
            } else {
                markdown
            }
        }
        .onPreferenceChange(TitleBarDescriptionHeightKey.self) { newValue in
            if abs(newValue - measuredDescriptionHeight) > 0.5 {
                measuredDescriptionHeight = newValue
            }
        }
    }

    private var accessibilityText: String {
        Self.collapsedLine(descriptionText).text
    }
}

// MARK: - Description height measurement

private struct TitleBarDescriptionWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TitleBarDescriptionHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Markdown subset enforcement

/// Strips markdown constructs that the title-bar subset does not allow before
/// the string reaches the native renderer. Preserves inline code, bold, italic, lists,
/// headings, blockquotes, rules, and links (link navigation is disabled
/// elsewhere via OpenURLAction { .discarded }).
///
/// Removed:
/// - Images `![alt](url)` — graphics are parking-lot.
/// - Fenced code blocks ```` ``` ```` — too large for a 5-line cap.
/// - Table rows — lines matching `^\s*\|.*\|\s*$`.
func sanitizeDescriptionMarkdown(_ input: String) -> String {
    var s = input

    // 1. Strip images: ![alt text](url) — both lazy and link-style.
    // Regex matches ! followed by [any chars] followed by (any chars).
    if let imgRegex = try? NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\([^)]*\\)", options: []) {
        let range = NSRange(s.startIndex..., in: s)
        s = imgRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }

    // 2. Strip fenced code blocks. Split by lines, skip content between
    //    matching ``` fences (and the fence lines themselves).
    do {
        let lines = s.components(separatedBy: "\n")
        var result: [String] = []
        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            result.append(line)
        }
        s = result.joined(separator: "\n")
    }

    // 3. Strip table rows: lines that look like `| ... |`.
    do {
        let lines = s.components(separatedBy: "\n")
        let kept = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            return !(trimmed.hasPrefix("|") && trimmed.hasSuffix("|"))
        }
        s = kept.joined(separator: "\n")
    }

    return s
}

// MARK: - Compact native markdown subset

/// Block structure stays native and lightweight: expanded descriptions never
/// create a web view. The caller sanitizes unsupported constructs first.
enum TitleBarDescriptionBlock: Equatable {
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case listItem(marker: String, text: AttributedString, depth: Int)
    case quote(AttributedString)
    case rule
}

private enum TitleBarDescriptionBlockKind: Equatable {
    case paragraph
    case heading(Int)
    case listItem(marker: String, depth: Int)
    case quote
    case codeBlock
    case rule
}

/// Uses semantic block identity to group runs from one native row. List items
/// and block quotes can span multiple paragraph intents, so they key by item or
/// quote identity instead of paragraph identity.
private struct TitleBarDescriptionBlockKey: Equatable {
    let enclosingIdentity: Int
    let blockIdentity: Int
    let kind: TitleBarDescriptionBlockKind
}

func titleBarDescriptionBlocks(_ text: String) -> [TitleBarDescriptionBlock] {
    guard let parsed = try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .full)
    ) else {
        return text.isEmpty ? [] : [.paragraph(AttributedString(text))]
    }

    var blocks: [TitleBarDescriptionBlock] = []
    var currentKey: TitleBarDescriptionBlockKey?
    var currentText = AttributedString()
    var currentParagraphIdentity: Int?

    func flushCurrentBlock() {
        guard let key = currentKey else { return }
        let content = titleBarDescriptionTrimmed(currentText)

        switch key.kind {
        case .paragraph:
            guard !content.characters.isEmpty else { break }
            blocks.append(.paragraph(titleBarDescriptionInertLinks(content)))
        case .codeBlock:
            guard !content.characters.isEmpty else { break }
            var code = titleBarDescriptionInertLinks(content)
            for run in code.runs {
                code[run.range].font = .system(size: 11, design: .monospaced)
            }
            blocks.append(.paragraph(code))
        case .heading(let level):
            guard !content.characters.isEmpty else { break }
            blocks.append(.heading(level: level, text: titleBarDescriptionInertLinks(content)))
        case .listItem(let marker, let depth):
            guard !content.characters.isEmpty else { break }
            let task = titleBarDescriptionTaskListItem(content)
            blocks.append(.listItem(
                marker: task?.marker ?? marker,
                text: titleBarDescriptionInertLinks(task?.text ?? content),
                depth: depth
            ))
        case .quote:
            guard !content.characters.isEmpty else { break }
            blocks.append(.quote(titleBarDescriptionInertLinks(content)))
        case .rule:
            blocks.append(.rule)
        }

        currentKey = nil
        currentText = AttributedString()
        currentParagraphIdentity = nil
    }

    for (runIndex, run) in parsed.runs.enumerated() {
        let key = titleBarDescriptionBlockKey(
            for: run.presentationIntent,
            fallbackIdentity: runIndex
        )
        let paragraphIdentity = titleBarDescriptionParagraphIdentity(for: run.presentationIntent)

        if currentKey != key {
            flushCurrentBlock()
            currentKey = key
        } else if titleBarDescriptionJoinsParagraphs(key.kind),
                  let previousParagraphIdentity = currentParagraphIdentity,
                  let paragraphIdentity,
                  previousParagraphIdentity != paragraphIdentity {
            currentText.append(AttributedString("\n"))
        }
        currentParagraphIdentity = paragraphIdentity

        var fragment = AttributedString(parsed[run.range])
        if key.kind == .rule {
            fragment = AttributedString(String(fragment.characters).replacingOccurrences(of: "\u{2E3B}", with: ""))
        }
        currentText.append(fragment)
    }
    flushCurrentBlock()
    return blocks
}

private func titleBarDescriptionTaskListItem(_ text: AttributedString) -> (marker: String, text: AttributedString)? {
    let value = String(text.characters)
    let marker: String
    if value.hasPrefix("[ ] ") { marker = "☐" }
    else if value.hasPrefix("[x] ") || value.hasPrefix("[X] ") { marker = "☑" }
    else { return nil }

    var remaining = text
    let end = remaining.index(remaining.startIndex, offsetByCharacters: 4)
    remaining.removeSubrange(remaining.startIndex..<end)
    return (marker, titleBarDescriptionTrimmed(remaining))
}

private func titleBarDescriptionBlockKey(
    for intent: PresentationIntent?,
    fallbackIdentity: Int
) -> TitleBarDescriptionBlockKey {
    let components = intent?.components ?? []
    let enclosingIdentity = components.first?.identity ?? fallbackIdentity

    if let itemIndex = components.firstIndex(where: {
        if case .listItem = $0.kind { return true }
        return false
    }), case .listItem(let ordinal) = components[itemIndex].kind {
        let item = components[itemIndex]
        let parentList = components.dropFirst(itemIndex + 1).first(where: {
            switch $0.kind {
            case .orderedList, .unorderedList: return true
            default: return false
            }
        })
        let marker: String
        if let parentList, case .orderedList = parentList.kind {
            marker = "\(ordinal)."
        } else {
            marker = "•"
        }
        let depth = max(0, components.reduce(into: 0) { count, component in
            switch component.kind {
            case .orderedList, .unorderedList: count += 1
            default: break
            }
        } - 1)
        return TitleBarDescriptionBlockKey(
            enclosingIdentity: item.identity,
            blockIdentity: item.identity,
            kind: .listItem(marker: marker, depth: depth)
        )
    }

    if let heading = components.last(where: {
        if case .header = $0.kind { return true }
        return false
    }), case .header(let level) = heading.kind {
        return TitleBarDescriptionBlockKey(
            enclosingIdentity: enclosingIdentity,
            blockIdentity: heading.identity,
            kind: .heading(level)
        )
    }

    if let rule = components.last(where: {
        if case .thematicBreak = $0.kind { return true }
        return false
    }) {
        return TitleBarDescriptionBlockKey(
            enclosingIdentity: enclosingIdentity,
            blockIdentity: rule.identity,
            kind: .rule
        )
    }

    if let codeBlock = components.last(where: {
        if case .codeBlock = $0.kind { return true }
        return false
    }) {
        return TitleBarDescriptionBlockKey(
            enclosingIdentity: enclosingIdentity,
            blockIdentity: codeBlock.identity,
            kind: .codeBlock
        )
    }

    if let quote = components.first(where: {
        if case .blockQuote = $0.kind { return true }
        return false
    }) {
        return TitleBarDescriptionBlockKey(
            enclosingIdentity: quote.identity,
            blockIdentity: quote.identity,
            kind: .quote
        )
    }

    if let paragraph = components.last(where: {
        if case .paragraph = $0.kind { return true }
        return false
    }) {
        return TitleBarDescriptionBlockKey(
            enclosingIdentity: enclosingIdentity,
            blockIdentity: paragraph.identity,
            kind: .paragraph
        )
    }

    return TitleBarDescriptionBlockKey(
        enclosingIdentity: enclosingIdentity,
        blockIdentity: fallbackIdentity,
        kind: .paragraph
    )
}

private func titleBarDescriptionParagraphIdentity(for intent: PresentationIntent?) -> Int? {
    intent?.components.first(where: {
        if case .paragraph = $0.kind { return true }
        return false
    })?.identity
}

private func titleBarDescriptionJoinsParagraphs(_ kind: TitleBarDescriptionBlockKind) -> Bool {
    switch kind {
    case .listItem, .quote: return true
    default: return false
    }
}

private func titleBarDescriptionTrimmed(_ input: AttributedString) -> AttributedString {
    guard let first = input.characters.firstIndex(where: { !$0.isWhitespace }),
          let last = input.characters.lastIndex(where: { !$0.isWhitespace }) else {
        return AttributedString()
    }
    return AttributedString(input[first..<input.index(afterCharacter: last)])
}

/// Full Markdown parsing retains inline styling while the native block mapper
/// consumes presentation intents. Drop links after parsing so labels remain
/// visible without creating controls or navigation.
private func titleBarDescriptionInertLinks(_ input: AttributedString) -> AttributedString {
    var result = input
    for run in result.runs where run.link != nil {
        result[run.range].foregroundColor = Color.accentColor
        result[run.range].link = nil
    }
    return result
}

/// Foundation supplies inline emphasis/code parsing for this compatibility
/// helper. Drop the URL attribute entirely so links retain their text but
/// cannot navigate or become controls.
func titleBarDescriptionInline(_ text: String) -> AttributedString {
    let parsed = (try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
    return titleBarDescriptionInertLinks(parsed)
}

private struct TitleBarDescriptionMarkdown: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(titleBarDescriptionBlocks(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }

    private func inline(_ text: AttributedString, size: CGFloat = 11) -> Text {
        var attributed = titleBarDescriptionInertLinks(text)
        for run in attributed.runs {
            let isCodeBlock = run.presentationIntent?.components.contains(where: {
                if case .codeBlock = $0.kind { return true }
                return false
            }) ?? false
            guard isCodeBlock || run.inlinePresentationIntent?.contains(.code) == true else { continue }
            attributed[run.range].font = .system(size: size, design: .monospaced)
            attributed[run.range].foregroundColor = colorScheme == .dark
                ? Color(red: 0.85, green: 0.6, blue: 0.95)
                : Color(red: 0.6, green: 0.2, blue: 0.7)
        }
        return Text(attributed)
    }

    @ViewBuilder
    private func blockView(_ block: TitleBarDescriptionBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
                .padding(.vertical, 2)
        case .heading(let level, let text):
            let size: CGFloat = level == 1 ? 13 : (level == 2 ? 12 : 11)
            inline(text, size: size)
                .font(.system(size: size, weight: level < 3 ? .bold : (level < 5 ? .semibold : .medium)))
                .foregroundColor(level == 6 ? .secondary : .primary)
                .padding(.top, level < 3 ? 4 : (level < 5 ? 3 : 2))
                .padding(.bottom, 2)
        case .listItem(let marker, let text, let depth):
            HStack(alignment: .top, spacing: 5) {
                Text(verbatim: marker)
                    .monospacedDigit()
                    .frame(minWidth: 12, alignment: .trailing)
                inline(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 12)
            .padding(.vertical, 2)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.2) : Color.gray.opacity(0.4))
                    .frame(width: 2)
                inline(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 3)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}

private extension View {
    /// Optional rendered-layout oracle. Production passes nil and mounts no GeometryReader.
    func titleBarMeasure(_ name: String, observer: ((String, CGRect) -> Void)?) -> some View {
        background {
            if let observer {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { observer(name, proxy.frame(in: .named(SessionPlacement.layoutSpace))) }
                        .onChange(of: proxy.frame(in: .named(SessionPlacement.layoutSpace))) { _, frame in
                            observer(name, frame)
                        }
                }
            }
        }
    }
}

// MARK: - c11: the chip's slot before a terminal has a placement

/// Empty space exactly as wide as a chip, for a terminal whose placement has
/// not arrived yet or whose session ended, so nothing after it moves.
struct SessionChipSlot: View {
    let multiplier: CGFloat
    var textStyle: ThemeTextStyle = .unset
    @ObservedObject private var roster = MachineRoster.shared

    var body: some View {
        let _ = roster.revision
        let metrics = SessionPlacement.metrics(multiplier: multiplier, roster: roster, textStyle: textStyle)
        Color.clear
            .frame(width: metrics.width + SessionChipView.colorSlot(multiplier: multiplier, roster: roster), height: metrics.rowHeight)
            .accessibilityHidden(true)
    }
}

// MARK: - c11: herder cores (the bar's ⓘ)

/// Where c11's terminals run: this Mac's herder core (hc) and every machine
/// it has linked, with each one's link state, hc version and how many of
/// c11's terminals it holds; then how to add another machine. Opened from
/// the ⓘ at the far left of a terminal's panel bar.
struct HerderCoresPopover: View {
    /// The roster id of the machine the panel that opened this runs on.
    let currentMachineKey: String
    let onClose: () -> Void

    @ObservedObject private var roster = MachineRoster.shared
    @ObservedObject private var directory = HCMachineDirectory.shared
    @ObservedObject private var hcStatus = MachineHCStatus.shared
    /// Terminal counts, taken when the popover opens: walking every window's
    /// panels on each redraw of a busy bar would be wasted work.
    @State private var counts: (byMachine: [String: Int], local: Int) = ([:], 0)

    struct Core: Equatable, Identifiable {
        let id: String
        let name: String
        let isLocal: Bool
        let isCurrent: Bool
        /// nil for this Mac (its core is the one c11 runs on).
        let connected: Bool?
        let linked: Bool
        let version: String?
        let terminals: Int
    }

    /// One row per core: this Mac first, then linked machines, then roster
    /// entries hc no longer links. Terminal counts come from c11's panels.
    static func cores(
        rows: [MachineRosterRow],
        versions: [String: String],
        terminalsByMachine: [String: Int],
        localTerminals: Int,
        currentMachineKey: String
    ) -> [Core] {
        rows.map { row in
            Core(
                id: row.id,
                name: row.displayName,
                isLocal: row.isLocal,
                isCurrent: row.id == (currentMachineKey.isEmpty ? MachineRoster.localID : currentMachineKey),
                connected: row.connected,
                linked: row.linked,
                version: versions[row.id],
                terminals: row.isLocal ? localTerminals : terminalsByMachine[row.id] ?? 0
            )
        }
    }

    static func detail(_ core: Core) -> String {
        let terminals = core.terminals == 1
            ? String(localized: "titlebar.herderCores.oneTerminal", defaultValue: "1 terminal")
            : String(format: String(localized: "titlebar.herderCores.terminals", defaultValue: "%d terminals"), core.terminals)
        let state: String
        if core.isLocal {
            state = String(localized: "titlebar.herderCores.thisMac", defaultValue: "This Mac")
        } else if !core.linked {
            state = String(localized: "titlebar.herderCores.notLinked", defaultValue: "Not linked")
        } else if core.connected == true {
            state = String(localized: "titlebar.herderCores.connected", defaultValue: "Connected")
        } else {
            state = String(localized: "titlebar.herderCores.unreachable", defaultValue: "Unreachable")
        }
        let version = core.version.map { "hc " + $0 }
        return [state, version, core.linked ? terminals : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private var cores: [Core] {
        _ = roster.revision
        let rows = MachineRosterRow.rows(
            roster: roster.all(),
            linked: Dictionary(directory.entries.map { ($0.machine, $0.connected) }, uniquingKeysWith: { a, _ in a }),
            localHostName: LocalSessionPlacementFeed.localHostName
        )
        var versions: [String: String] = [:]
        for (name, listed) in hcStatus.machines {
            if let id = MachineRoster.normalizedID(name), let version = listed.version { versions[id] = version }
        }
        if let pin = hcStatus.pinVersion { versions[MachineRoster.localID] = pin }
        return Self.cores(rows: rows, versions: versions, terminalsByMachine: counts.byMachine,
                          localTerminals: counts.local, currentMachineKey: currentMachineKey)
    }

    private static func terminalCounts() -> (byMachine: [String: Int], local: Int) {
        var byMachine: [String: Int] = [:]
        var local = 0
        for workspace in AppDelegate.shared?.allMainWindowWorkspaces() ?? [] {
            for panel in workspace.panels.values {
                guard let terminal = panel as? TerminalPanel else { continue }
                if let machine = terminal.hcRemoteTarget?.machine, let id = MachineRoster.normalizedID(machine) {
                    byMachine[id, default: 0] += 1
                } else {
                    local += 1
                }
            }
        }
        return (byMachine, local)
    }

    var body: some View {
        let cores = cores
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "titlebar.herderCores.title", defaultValue: "Herder cores"))
                    .font(.system(size: 15, weight: .semibold))
                Text(String(localized: "titlebar.herderCores.lede",
                            defaultValue: "Each machine runs a herder core (hc) that holds its terminals. They keep running when c11 quits, and c11 shows them all here."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(cores) { core in
                    HStack(alignment: .center, spacing: 10) {
                        Rectangle()
                            .fill(core.isLocal || core.connected == true ? Color.green : core.linked ? Color.orange : Color.gray)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(core.name)
                                    .font(.system(size: 13, weight: .semibold))
                                if core.isCurrent {
                                    Text(String(localized: "titlebar.herderCores.thisPanel", defaultValue: "THIS PANEL"))
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary, lineWidth: 1))
                                }
                            }
                            Text(Self.detail(core))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    Divider()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "titlebar.herderCores.addTitle", defaultValue: "Add another machine"))
                    .font(.system(size: 13, weight: .semibold))
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 12, alignment: .trailing)
                        Text(step)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button(String(localized: "titlebar.herderCores.addButton", defaultValue: "Add Machine…")) {
                    onClose()
                    SettingsWindowController.shared.show(navigationTarget: .machines)
                }
                .controlSize(.small)
                .padding(.top, 2)
                .accessibilityIdentifier("titlebar.herderCores.add")
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            counts = Self.terminalCounts()
            hcStatus.refresh()
        }
    }

    static var steps: [String] {
        [
            String(localized: "titlebar.herderCores.step1",
                   defaultValue: "Pick a machine this Mac can reach over SSH with your key, no password prompt (a Tailscale name works): a Mac with Apple silicon and the Command Line Tools, or an x86-64 Linux machine with systemd, Python 3 and linger on."),
            String(localized: "titlebar.herderCores.step2",
                   defaultValue: "Click Add Machine… and give its SSH name. c11 installs a herder core there and links it; nothing else on that machine changes."),
            String(localized: "titlebar.herderCores.step3",
                   defaultValue: "New Terminal then asks where to run, and the chip in each panel's bar names the machine its terminal runs on."),
        ]
    }
}

// MARK: - Description age (C11H-278)

/// The fixed slot an age label takes, measured once per style, size and
/// weight from the localized widest samples in tabular digits. The language
/// is fixed for the process, so a translation never moves the label later.
enum DescriptionAgeMetrics {
    private struct Key: Hashable {
        let style: DescriptionAge.Style
        let fontSize: CGFloat
        let weight: CGFloat
    }

    private static let lock = NSLock()
    private static var widths: [Key: CGFloat] = [:]

    static func slotWidth(style: DescriptionAge.Style, fontSize: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        let key = Key(style: style, fontSize: fontSize, weight: weight.rawValue)
        lock.lock()
        defer { lock.unlock() }
        if let cached = widths[key] { return cached }
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
        let widest = DescriptionAge.widthSamples
            .map { ceil(($0.text(style) as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 0
        if widths.count >= 32 { widths.removeAll() }
        widths[key] = widest
        return widest
    }
}

/// How long ago a description was edited, in a fixed-width slot that stays
/// reserved when there is no description. It listens to the coarse
/// `SidebarDecayClock` (paused while no window is visible) and changes its own
/// state only when its text would change, so a tick re-evaluates this label at
/// most once a minute and never the row, bar or window around it.
struct DescriptionAgeLabel: View {
    let updatedAt: Date?
    let style: DescriptionAge.Style
    let fontSize: CGFloat
    var weight: NSFont.Weight = .regular
    let color: Color
    var alignment: Alignment = .trailing

    /// The clock time the label last moved to. Ticks that leave the text as it
    /// is do not touch it, so they invalidate nothing.
    @State private var now = Date()

    static let accessibilityIdentifier = "description.age"

    var body: some View {
        // C11H-238 meter: counts this body, so a run can show ticks re-render
        // only age labels. Off, one static Bool load.
        let _ = GraphChurnMeter.note(.descriptionAgeBody)
        let age = updatedAt.map { DescriptionAge(updatedAt: $0, now: now) }
        let fullText = age?.text(.full) ?? ""
        Text(verbatim: age?.text(style) ?? "")
            .font(.system(size: fontSize, weight: Font.Weight(weight)))
            .monospacedDigit()
            .foregroundColor(color)
            .lineLimit(1)
            .frame(width: DescriptionAgeMetrics.slotWidth(style: style, fontSize: fontSize, weight: weight),
                   alignment: alignment)
            // The compact "12m" says the rest on hover.
            .safeHelp(style == .compact ? fullText : "")
            .accessibilityLabel(Text(verbatim: fullText))
            .accessibilityIdentifier(Self.accessibilityIdentifier)
            .accessibilityHidden(age == nil)
            .onReceive(Self.liveTicks) { tick in
                if Self.shouldAdvance(updatedAt: updatedAt, shown: now, tick: tick) { now = tick }
            }
            .onChange(of: updatedAt) { _ in now = Date() }
    }

    /// Fresh clock times only. A `@Published` publisher replays its current
    /// value on subscribe, which can be up to a tick older than the label's
    /// own `now`; dropping it keeps a new label from reading a younger age.
    /// Every later value is the wall clock at a tick or a resume.
    static func ticks(of clock: SidebarDecayClock) -> Publishers.Drop<Published<Date>.Publisher> {
        clock.$now.dropFirst()
    }

    /// One shared instance, so SwiftUI sees the same publisher on every update.
    static let liveTicks = ticks(of: .shared)

    /// A tick moves the label only when it changes what the label reads, in
    /// either direction: a clock set back moves "12 min ago" to "2 min ago" at
    /// once, as the socket's age does.
    static func shouldAdvance(updatedAt: Date?, shown: Date, tick: Date) -> Bool {
        guard let updatedAt else { return false }
        return DescriptionAge(updatedAt: updatedAt, now: tick) != DescriptionAge(updatedAt: updatedAt, now: shown)
    }
}

private extension Font.Weight {
    init(_ weight: NSFont.Weight) {
        switch weight {
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        default: self = .regular
        }
    }
}
