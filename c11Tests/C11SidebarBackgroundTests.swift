import SwiftUI
import AppKit
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-32, C11H-146, C11H-438: what c11 draws behind the sidebar. From Theme
/// (the default) draws the theme's `[backdrop]`, else c11's material in both
/// theme slots; Sunset Mall and Outrun Horizon override it in the Dark theme
/// slot; None leaves the material.
final class C11SidebarBackgroundTests: XCTestCase {
    private let dark = ThemeContext(workspaceColor: nil, colorScheme: .dark, ghosttyBackgroundGeneration: 0)

    func testDarkSlotDrawsTheChosenOverride() {
        XCTAssertEqual(C11SidebarBackground.shown(raw: "sunsetMall", colorScheme: .dark), .sunsetMall)
        XCTAssertEqual(C11SidebarBackground.shown(raw: "outrunHorizon", colorScheme: .dark), .outrunHorizon)
        XCTAssertNil(C11SidebarBackground.shown(raw: "off", colorScheme: .dark))
        XCTAssertNil(C11SidebarBackground.shown(raw: "fromTheme", colorScheme: .dark))
    }

    func testLightSlotNeverDrawsAnOverride() {
        for style in C11SidebarBackground.allCases {
            XCTAssertNil(C11SidebarBackground.shown(raw: style.rawValue, colorScheme: .light), style.rawValue)
        }
        XCTAssertNil(C11SidebarBackground.shown(raw: nil, colorScheme: .light))
    }

    /// From Theme by default, under a key the first-install import refuses (it
    /// drops every `c11.` key coming from c11; tests/c11_install_test.py), so
    /// imported c11 settings can't change it. A missing or unknown stored value
    /// is the default too.
    func testDefaultIsFromThemeUnderAC11hOnlyKey() {
        XCTAssertEqual(C11SidebarBackground.defaultValue, .fromTheme)
        XCTAssertTrue(C11SidebarBackground.storageKey.hasPrefix("c11."))
        XCTAssertEqual(C11SidebarBackground.resolve(nil), .fromTheme)
        XCTAssertEqual(C11SidebarBackground.resolve("vaporwave-from-elsewhere"), .fromTheme)
        XCTAssertNil(C11SidebarBackground.shown(raw: nil, colorScheme: .dark))
    }

    func testBackdropFollowsTheThemeUnlessOverriddenOrNone() throws {
        let theme = SidebarBackdropStyle(fill: .solid(.black), grid: nil)
        let sunset = try XCTUnwrap(C11SidebarBackground.sunsetMall.backdropStyle)

        // Dark slot.
        XCTAssertEqual(C11SidebarBackground.backdrop(raw: nil, colorScheme: .dark, theme: theme), theme)
        XCTAssertEqual(C11SidebarBackground.backdrop(raw: "fromTheme", colorScheme: .dark, theme: theme), theme)
        XCTAssertNil(C11SidebarBackground.backdrop(raw: nil, colorScheme: .dark, theme: nil))
        XCTAssertNil(C11SidebarBackground.backdrop(raw: "fromTheme", colorScheme: .dark, theme: nil))
        XCTAssertEqual(C11SidebarBackground.backdrop(raw: "sunsetMall", colorScheme: .dark, theme: theme), sunset)
        XCTAssertEqual(C11SidebarBackground.backdrop(raw: "sunsetMall", colorScheme: .dark, theme: nil), sunset)
        XCTAssertNil(C11SidebarBackground.backdrop(raw: "off", colorScheme: .dark, theme: theme))

        // Light slot: overrides are Dark-only, so the theme shows; without one the
        // material shows; None still wins.
        XCTAssertEqual(C11SidebarBackground.backdrop(raw: "sunsetMall", colorScheme: .light, theme: theme), theme)
        XCTAssertNil(C11SidebarBackground.backdrop(raw: "sunsetMall", colorScheme: .light, theme: nil))
        XCTAssertNil(C11SidebarBackground.backdrop(raw: nil, colorScheme: .light, theme: nil))
        XCTAssertNil(C11SidebarBackground.backdrop(raw: "off", colorScheme: .light, theme: theme))
    }

    /// C11H-438: the default theme, stage11, has no backdrop, so the default
    /// From Theme leaves its Dark-slot sidebar plain (c11's material and tint, as
    /// in c11 1.8), not Sunset Mall. Picking Sunset Mall still draws it.
    func testStage11DarkSlotIsPlainUnlessSunsetMallIsPicked() throws {
        let sunsetStyle = try XCTUnwrap(C11SidebarBackground.sunsetMall.backdropStyle)
        let stage11 = Self.themeBackdrop(try Self.bundledTheme("stage11"), context: dark)
        XCTAssertNil(C11SidebarBackground.backdrop(raw: nil, colorScheme: .dark, theme: stage11))
        XCTAssertNil(C11SidebarBackground.backdrop(raw: "fromTheme", colorScheme: .dark, theme: stage11))
        XCTAssertEqual(C11SidebarBackground.backdrop(raw: "sunsetMall", colorScheme: .dark, theme: stage11), sunsetStyle)
    }

    /// The bundled `c11` theme keeps Sunset Mall as its own backdrop: From Theme
    /// draws exactly that gradient.
    func testTheC11ThemeDrawsItsOwnSunsetMallBackdrop() throws {
        let c11 = try Self.bundledTheme("c11")
        XCTAssertEqual(c11.identity.schema, 2)
        let backdrop = try XCTUnwrap(Self.themeBackdrop(c11, context: dark))
        let sunset = try XCTUnwrap(C11SidebarBackground.sunsetMall.backdropStyle)
        guard case let .gradient(themed)? = backdrop.fill, case let .gradient(fixed)? = sunset.fill else {
            return XCTFail("expected two gradients, got \(String(describing: backdrop.fill)) and \(String(describing: sunset.fill))")
        }
        XCTAssertEqual(themed.stops.map(\.location), fixed.stops.map(\.location))
        XCTAssertEqual(themed.stops.map { Self.hex($0.color) }, fixed.stops.map { Self.hex($0.color) })
        XCTAssertNil(backdrop.grid)
        XCTAssertEqual(C11SidebarBackground.backdrop(raw: nil, colorScheme: .dark, theme: backdrop), backdrop)
    }

    /// stage11 has no backdrop: From Theme leaves the Light slot on c11's material.
    func testStage11HasNoBackdrop() throws {
        let stage11 = Self.themeBackdrop(try Self.bundledTheme("stage11"), context: dark)
        XCTAssertNil(stage11)
        XCTAssertNil(C11SidebarBackground.backdrop(raw: nil, colorScheme: .light, theme: stage11))
    }

    func testThemeBackdropKinds() throws {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let twoStops = ThemeGradient(stops: [.init(color: red, location: 0), .init(color: blue, location: 1)])
        let oneStop = ThemeGradient(stops: [.init(color: blue, location: 0)])

        XCTAssertNil(SidebarBackdropStyle.fromTheme(kind: nil, color: nil, gradient: nil, grid: nil, gridColor: nil, gridTop: nil))
        // kind = "material" is an explicit choice, not "no backdrop".
        let material = try XCTUnwrap(SidebarBackdropStyle.fromTheme(kind: "material", color: red, gradient: nil, grid: "none", gridColor: nil, gridTop: nil))
        XCTAssertNil(material.fill)
        XCTAssertNil(material.grid)
        XCTAssertEqual(C11SidebarBackground.backdrop(raw: nil, colorScheme: .dark, theme: material), material)
        XCTAssertNil(SidebarBackdropStyle.fromTheme(kind: "solid", color: nil, gradient: nil, grid: nil, gridColor: nil, gridTop: nil))

        XCTAssertEqual(SidebarBackdropStyle.fromTheme(kind: "solid", color: red, gradient: twoStops, grid: nil, gridColor: nil, gridTop: nil)?.fill, .solid(red))
        XCTAssertEqual(SidebarBackdropStyle.fromTheme(kind: "gradient", color: red, gradient: twoStops, grid: nil, gridColor: nil, gridTop: nil)?.fill, .gradient(twoStops))
        XCTAssertEqual(SidebarBackdropStyle.fromTheme(kind: "gradient", color: red, gradient: nil, grid: nil, gridColor: nil, gridTop: nil)?.fill, .solid(red))
        XCTAssertEqual(SidebarBackdropStyle.fromTheme(kind: nil, color: nil, gradient: oneStop, grid: nil, gridColor: nil, gridTop: nil)?.fill, .solid(blue))

        // A grid can sit over the material alone; its floor is clamped inside the sidebar.
        let floor = try XCTUnwrap(SidebarBackdropStyle.fromTheme(kind: "material", color: nil, gradient: nil, grid: "perspective", gridColor: nil, gridTop: 2))
        XCTAssertNil(floor.fill)
        XCTAssertEqual(floor.grid?.top, 0.95)
        XCTAssertEqual(floor.grid?.color, SidebarBackdropStyle.defaultGridColor)
        XCTAssertEqual(SidebarBackdropStyle.fromTheme(kind: "solid", color: red, gradient: nil, grid: "perspective", gridColor: blue, gridTop: nil)?.grid,
                       SidebarBackdropStyle.Grid(color: blue, top: SidebarBackdropStyle.defaultGridTop))
    }

    func testSettingsLabelsAreDistinct() {
        let labels = C11SidebarBackground.allCases.map(\.label)
        XCTAssertFalse(labels.contains(where: \.isEmpty))
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    func testStopsAreOrderedAndSpanTheSidebar() {
        XCTAssertTrue(C11SidebarBackground.off.stops.isEmpty)
        XCTAssertTrue(C11SidebarBackground.fromTheme.stops.isEmpty)
        XCTAssertNil(C11SidebarBackground.fromTheme.backdropStyle)
        XCTAssertNil(C11SidebarBackground.off.backdropStyle)
        for style in [C11SidebarBackground.sunsetMall, .outrunHorizon] {
            let locations = style.stops.map(\.location)
            XCTAssertEqual(locations.first, 0, style.rawValue)
            XCTAssertEqual(locations.last, 1, style.rawValue)
            XCTAssertEqual(locations, locations.sorted(), style.rawValue)
        }
    }

    /// Only Outrun Horizon has a grid; its lines stay inside the sidebar and
    /// start at the horizon.
    func testOutrunGridSitsOnTheFloor() throws {
        XCTAssertNil(C11SidebarBackground.sunsetMall.grid)
        let grid = try XCTUnwrap(C11SidebarBackground.outrunHorizon.grid)
        let lines = C11SidebarBackground.gridSegments(top: grid.top)
        XCTAssertEqual(lines.count, 20)
        for l in lines {
            // Each line starts inside the sidebar (verticals fan out past the
            // edges toward the bottom and are clipped by the Canvas).
            XCTAssertTrue((0...1).contains(l.x0), "x0 \(l.x0)")
            for v in [l.y0, l.y1] { XCTAssertTrue((grid.top...1).contains(v), "y \(v) above the floor") }
        }
    }

    /// The footer's help icon is `.secondary` (white at 55%) drawn at the foot of
    /// the sidebar: it needs WCAG 3:1 against each style's bottom stop
    /// (prototype: Sunset Mall 4.94:1, Outrun Horizon 5.72:1).
    func testHelpIconKeepsNonTextContrastAtTheFoot() throws {
        let expected: [C11SidebarBackground: Double] = [.sunsetMall: 4.94, .outrunHorizon: 5.72]
        for (style, measured) in expected {
            let bottom = try XCTUnwrap(style.stops.last)
            let bg = C11SidebarBackground.components(bottom.rgb)
            let alpha = 0.55
            let icon = (red: alpha + bg.red * (1 - alpha),
                        green: alpha + bg.green * (1 - alpha),
                        blue: alpha + bg.blue * (1 - alpha))
            let ratio = Self.contrast(icon, bg)
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(style.rawValue) help icon contrast \(ratio)")
            XCTAssertEqual(ratio, measured, accuracy: 0.01, style.rawValue)
        }
    }

    static func bundledTheme(_ name: String) throws -> C11Theme {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/c11-themes/\(name).toml")
        let table = try TomlSubsetParser.parse(file: url.path, source: try String(contentsOf: url, encoding: .utf8))
        return try C11Theme.fromToml(table)
    }

    static func themeBackdrop(_ theme: C11Theme, context: ThemeContext) -> SidebarBackdropStyle? {
        let snapshot = ResolvedThemeSnapshot(theme: theme)
        return SidebarBackdropStyle.fromTheme(
            kind: snapshot.resolveStyleString(.backdropKind),
            color: snapshot.resolveStyleColor(.backdropColor, context: context),
            gradient: snapshot.resolveStyleGradient(.backdropGradient, context: context),
            grid: snapshot.resolveStyleString(.backdropGrid),
            gridColor: snapshot.resolveStyleColor(.backdropGridColor, context: context),
            gridTop: snapshot.resolveStyleNumber(.backdropGridTop)
        )
    }

    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "?" }
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
            .map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }

    private static func contrast(_ a: (red: Double, green: Double, blue: Double),
                                 _ b: (red: Double, green: Double, blue: Double)) -> Double {
        func channel(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func luminance(_ c: (red: Double, green: Double, blue: Double)) -> Double {
            0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}


/// C11H-144, C11H-145, C11H-148: the schema-2 values the sidebar draws, resolved
/// once per theme. Unset means today's drawing.
final class SidebarThemeStyleTests: XCTestCase {
    private let dark = ThemeContext(workspaceColor: nil, colorScheme: .dark, ghosttyBackgroundGeneration: 0)

    private func style(_ body: String) throws -> SidebarThemeStyle {
        let source = """
        [identity]
        name = "t"
        display_name = "T"
        author = "test"
        version = "0.01.001"
        schema = 2

        [palette]
        ink = "#101010"
        hot = "#FF4F1F"
        paper = "#F0F0F0"

        [variables]
        background = "$palette.ink"
        accent = "$palette.hot"

        \(body)
        """
        let theme = try C11Theme.fromToml(try TomlSubsetParser.parse(file: "t.toml", source: source))
        return SidebarThemeStyle(snapshot: ResolvedThemeSnapshot(theme: theme), context: dark)
    }

    private func assertUnset(_ s: SidebarThemeStyle, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let colors: [(String, Color?)] = [
            ("cardFill", s.cardFill), ("cardFillActive", s.cardFillActive), ("cardBorder", s.cardBorder),
            ("cardBorderActive", s.cardBorderActive), ("cardBorderWaiting", s.cardBorderWaiting),
            ("cardText", s.cardText), ("cardTextSecondary", s.cardTextSecondary), ("cardTextDim", s.cardTextDim),
            ("cardRule", s.cardRule), ("cardAccent", s.cardAccent), ("cardProgressTrack", s.cardProgressTrack),
            ("cardGlow", s.cardGlow), ("pillFillFirst", s.pillFillFirst), ("pillInk", s.pillInk),
            ("pillBorder", s.pillBorder), ("stateWaiting", s.stateWaiting), ("stateWaitingInk", s.stateWaitingInk),
            ("stateFlag", s.stateFlag), ("stateUsageLimit", s.stateUsageLimit),
        ]
        for (key, value) in colors { XCTAssertNil(value, "\(name) \(key)", file: file, line: line) }
        let numbers: [(String, CGFloat?)] = [
            ("cardRadius", s.cardRadius), ("cardBorderPt", s.cardBorderPt), ("cardActiveBorderPt", s.cardActiveBorderPt),
            ("cardPaddingPt", s.cardPaddingPt), ("pillRadius", s.pillRadius), ("controlRadius", s.controlRadius),
            ("markRadius", s.markRadius), ("progressHeightPt", s.progressHeightPt), ("progressRadius", s.progressRadius),
        ]
        for (key, value) in numbers { XCTAssertNil(value, "\(name) \(key)", file: file, line: line) }
        XCTAssertNil(s.cardProgress, name, file: file, line: line)
        XCTAssertNil(s.pillFill, name, file: file, line: line)
        XCTAssertNil(s.cardSheen, name, file: file, line: line)
        XCTAssertNil(s.pillStyle, name, file: file, line: line)
        XCTAssertNil(s.monoFamily, name, file: file, line: line)
        for text in [s.cardTitle, s.cardLabel, s.agentRow, s.pill] {
            XCTAssertTrue(text.isUnset, name, file: file, line: line)
        }
        XCTAssertFalse(s.bust || s.stateTags || s.hoverBrackets || s.sidebarLegend, name, file: file, line: line)
        XCTAssertEqual(s.cardHeader, .none, name, file: file, line: line)
        XCTAssertFalse(s.ownsCardEdge, name, file: file, line: line)
        let pad = s.cardPadding
        XCTAssertEqual([pad.horizontal, pad.top, pad.bottom], [13, 13, 11], name, file: file, line: line)
    }

    /// Zero regression: stage11 and the c11 theme (stage11 plus a backdrop) leave
    /// every card, pill and ornament value unset, so the sidebar draws as today.
    func testStage11AndC11hLeaveTheSidebarAsToday() throws {
        for name in ["stage11", "c11"] {
            let theme = try C11SidebarBackgroundTests.bundledTheme(name)
            let s = SidebarThemeStyle(snapshot: ResolvedThemeSnapshot(theme: theme), context: dark)
            assertUnset(s, name)
            XCTAssertEqual(s.fingerprint, "", name)
        }
        assertUnset(.unset, "unset")
    }

    func testCardValuesResolve() throws {
        let s = try style("""
        [type]
        mono = "JetBrains Mono"

        [type.cardTitle]
        scale = 0.7
        case  = "upper"

        [geometry]
        cardRadius         = 0
        cardBorderPt       = 1
        cardActiveBorderPt = 1.5
        cardPaddingPt      = 10
        markRadius         = 1
        progressHeightPt   = 2

        [chrome.card]
        fill         = "$background"
        borderActive = "$accent"
        sheen        = false
        glow         = "$accent"
        progress     = "#FF3F8E 0%, #FF9F45 100%"

        [states]
        flag = "$palette.paper"
        """)
        XCTAssertNotNil(s.cardFill)
        XCTAssertNil(s.cardFillActive)
        XCTAssertTrue(s.ownsCardEdge)
        XCTAssertEqual(s.cardRadius, 0)
        XCTAssertEqual(s.cardActiveBorderPt, 1.5)
        XCTAssertEqual(s.markRadius, 1)
        XCTAssertEqual(s.progressHeightPt, 2)
        XCTAssertEqual(s.cardSheen, false)
        XCTAssertNotNil(s.cardGlow)
        XCTAssertNotNil(s.stateFlag)
        XCTAssertNotNil(s.cardProgress)
        XCTAssertEqual(s.monoFamily, "JetBrains Mono")
        XCTAssertEqual(s.cardTitle.uppercase, true)
        XCTAssertEqual(s.cardTitle.apply("Glass V2"), "GLASS V2")
        XCTAssertTrue(s.cardLabel.isUnset)
        let pad = s.cardPadding
        XCTAssertEqual([pad.horizontal, pad.top, pad.bottom], [10, 10, 8])
    }

    func testPillAndOrnamentsResolve() throws {
        let outline = try style("""
        [chrome.pill]
        style  = "outline"
        ink    = "$accent"

        [ornaments]
        stateTags  = true
        cardHeader = "console"
        """)
        XCTAssertEqual(outline.pillStyle, .outline)
        XCTAssertNotNil(outline.pillInk)
        XCTAssertNil(outline.pillFill)
        XCTAssertTrue(outline.stateTags)
        XCTAssertEqual(outline.cardHeader, .console)
        XCTAssertFalse(outline.bust)

        let filled = try style("""
        [chrome.pill]
        style = "filled"
        fill  = "#FF3F8E 0%, #FF9F45 100%"

        [ornaments]
        bust          = true
        hoverBrackets = true
        sidebarLegend = true
        cardHeader    = "boxDrawing"
        """)
        XCTAssertEqual(filled.pillStyle, .filled)
        XCTAssertEqual(filled.pillFill?.stops.count, 2)
        XCTAssertNotNil(filled.pillFillFirst)
        XCTAssertTrue(filled.bust && filled.hoverBrackets && filled.sidebarLegend)
        XCTAssertEqual(filled.cardHeader, .boxDrawing)
    }

    /// The row compares the style by its stamp only. The stamp advances only when
    /// the resolved content changes: a theme version bump that changes nothing
    /// (a Ghostty background change under stage11) keeps every card's `==` true.
    func testStampAdvancesOnlyWhenContentChanges() throws {
        var generation: UInt64 = 0
        let unsetAgain = SidebarThemeStyleCache.advance(.unset, to: .unset, generation: &generation)
        XCTAssertEqual(unsetAgain.stamp, 0)
        XCTAssertEqual(generation, 0)

        let square = try style("[geometry]\ncardRadius = 0")
        let first = SidebarThemeStyleCache.advance(unsetAgain, to: square, generation: &generation)
        XCTAssertEqual(first.stamp, 1)
        XCTAssertNotEqual(first, unsetAgain)

        let same = SidebarThemeStyleCache.advance(first, to: try style("[geometry]\ncardRadius = 0"), generation: &generation)
        XCTAssertEqual(same.stamp, 1)
        XCTAssertEqual(same, first)

        let round = SidebarThemeStyleCache.advance(same, to: try style("[geometry]\ncardRadius = 4"), generation: &generation)
        XCTAssertEqual(round.stamp, 2)
        XCTAssertNotEqual(round, same)

        let recoloured = SidebarThemeStyleCache.advance(round, to: try style("[geometry]\ncardRadius = 4\n[chrome.card]\nfill = \"$accent\""), generation: &generation)
        XCTAssertEqual(recoloured.stamp, 3)

        // The values the Beacon selection draws from: selection ink, glow,
        // selected edge width and card padding (which sets the bar's reserve).
        var previous = recoloured
        for (index, toml) in [
            "[geometry]\ncardRadius = 4\n[chrome.card]\nfill = \"$accent\"\nborderActive = \"#2DE2E6\"",
            "[geometry]\ncardRadius = 4\n[chrome.card]\nfill = \"$accent\"\nborderActive = \"#2DE2E6\"\nglow = \"#FF3F8E\"",
            "[geometry]\ncardRadius = 4\ncardActiveBorderPt = 1\n[chrome.card]\nfill = \"$accent\"\nborderActive = \"#2DE2E6\"\nglow = \"#FF3F8E\"",
            "[geometry]\ncardRadius = 4\ncardActiveBorderPt = 1\ncardPaddingPt = 10\n[chrome.card]\nfill = \"$accent\"\nborderActive = \"#2DE2E6\"\nglow = \"#FF3F8E\"",
        ].enumerated() {
            let next = SidebarThemeStyleCache.advance(previous, to: try style(toml), generation: &generation)
            XCTAssertEqual(next.stamp, UInt64(4 + index), "step \(index) should advance the stamp")
            XCTAssertNotEqual(next, previous)
            let again = SidebarThemeStyleCache.advance(next, to: try style(toml), generation: &generation)
            XCTAssertEqual(again, next, "step \(index) unchanged should keep the stamp")
            previous = again
        }

        let back = SidebarThemeStyleCache.advance(previous, to: .unset, generation: &generation)
        XCTAssertEqual(back.stamp, 0)
        XCTAssertEqual(back, .unset)
    }

    /// LIVE and HOLD share one slot as wide as the wider tag, whatever the order.
    @MainActor
    func testStateTagSlotFitsTheWiderTag() {
        let short = SidebarStateTagMetrics.slotWidth(family: nil, size: 8, tracking: 1.12, tags: ["LIVE", "HOLD"])
        let swapped = SidebarStateTagMetrics.slotWidth(family: nil, size: 8, tracking: 1.12, tags: ["HOLD", "LIVE"])
        let wide = SidebarStateTagMetrics.slotWidth(family: nil, size: 8, tracking: 1.12, tags: ["LIVE", "ОЖИДАНИЕ"])
        XCTAssertEqual(short, swapped)
        XCTAssertGreaterThan(wide, short)
        XCTAssertGreaterThanOrEqual(short, 16)
        XCTAssertEqual(SidebarStateTagMetrics.slotWidth(family: nil, size: 8, tracking: 1.12, tags: ["LIVE", "HOLD"]), short)
    }
}
