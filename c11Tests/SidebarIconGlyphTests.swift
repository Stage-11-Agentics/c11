import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-343: one icon value for workspace groups and workspaces, what a group
/// may store, how each draws, and what the picker offers.
final class SidebarIconGlyphTests: XCTestCase {
    private let knownSymbols: Set<String> = ["folder.fill", "server.rack", "star.fill"]
    private var symbols: (String) -> Bool { { [knownSymbols] in knownSymbols.contains($0) } }

    func testGroupAcceptsOneEmojiIncludingSequences() {
        // The family is joined by U+200D and the Scotland flag by tag
        // characters: format characters, never controls.
        for emoji in ["🚀", "👨‍👩‍👧", "🇯🇵", "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}", "❤️", "👍🏽", "1️⃣"] {
            XCTAssertEqual(SidebarIconGlyph.normalizedGroupIcon(emoji, symbolExists: symbols), emoji, emoji)
        }
        XCTAssertEqual(SidebarIconGlyph.normalizedGroupIcon("  🧪 ", symbolExists: symbols), "🧪")
    }

    func testGroupAcceptsSymbolNamesBareOrPrefixedAndStoresThemBare() {
        XCTAssertEqual(SidebarIconGlyph.normalizedGroupIcon("server.rack", symbolExists: symbols), "server.rack")
        XCTAssertEqual(SidebarIconGlyph.normalizedGroupIcon("sf:server.rack", symbolExists: symbols), "server.rack")
        // The real lookup: every symbol a group saved before still validates.
        XCTAssertEqual(SidebarIconGlyph.normalizedGroupIcon("folder.fill"), "folder.fill")
    }

    func testGroupRejectsUnknownSymbolsWordsAndSeveralEmoji() {
        for junk in ["not.a.real.c11.symbol", "sf:not.a.real.c11.symbol", "sf:", "ab", "rocket",
                     "🚀🚀", "", "   ", "\u{7}", "\n"] {
            XCTAssertNil(SidebarIconGlyph.normalizedGroupIcon(junk, symbolExists: symbols), junk)
        }
    }

    func testSavedGroupSymbolDrawsAsSymbolAndUnknownValueFallsBack() {
        XCTAssertEqual(SidebarIconGlyph.forGroupIcon("folder.fill", symbolExists: symbols), .symbol("folder.fill"))
        XCTAssertEqual(SidebarIconGlyph.forGroupIcon("🚀", symbolExists: symbols), .text("🚀"))
        // nil: the header keeps drawing its folder.fill fallback, as before.
        XCTAssertNil(SidebarIconGlyph.forGroupIcon("gone.in.this.macos", symbolExists: symbols))
        XCTAssertNil(SidebarIconGlyph.forGroupIcon(nil, symbolExists: symbols))
    }

    func testWorkspaceIconDrawsSymbolsEmojiAndOnlyTheFirstCharacter() {
        XCTAssertEqual(SidebarIconGlyph.forWorkspaceIcon("sf:star.fill", symbolExists: symbols), .symbol("star.fill"))
        XCTAssertEqual(SidebarIconGlyph.forWorkspaceIcon("star.fill", symbolExists: symbols), .symbol("star.fill"))
        XCTAssertEqual(SidebarIconGlyph.forWorkspaceIcon("🧪 lab", symbolExists: symbols), .text("🧪"))
        XCTAssertEqual(SidebarIconGlyph.forWorkspaceIcon("👨‍👩‍👧", symbolExists: symbols), .text("👨‍👩‍👧"))
        XCTAssertNil(SidebarIconGlyph.forWorkspaceIcon("sf:nope", symbolExists: symbols))
        XCTAssertNil(SidebarIconGlyph.forWorkspaceIcon("  ", symbolExists: symbols))
        XCTAssertNil(SidebarIconGlyph.forWorkspaceIcon(nil, symbolExists: symbols))
    }

    /// The workspace card draws on every row evaluation; an emoji must not
    /// pay for an SF Symbol lookup.
    func testEmojiNeverPaysForASymbolLookup() {
        var lookups: [String] = []
        let recording: (String) -> Bool = { lookups.append($0); return false }
        XCTAssertEqual(SidebarIconGlyph.forWorkspaceIcon("🚀", symbolExists: recording), .text("🚀"))
        XCTAssertEqual(SidebarIconGlyph.forGroupIcon("🚀", symbolExists: recording), .text("🚀"))
        XCTAssertEqual(lookups, [])
    }

    /// What the picker writes is what the sidebar then draws, for both owners.
    func testPickerValuesRoundTripThroughBothDrawPaths() {
        for glyph in [SidebarIconGlyph.text("🚀"), .text("🇯🇵"), .symbol("server.rack")] {
            XCTAssertEqual(SidebarIconGlyph.forGroupIcon(glyph.groupValue, symbolExists: symbols), glyph)
            XCTAssertEqual(SidebarIconGlyph.forWorkspaceIcon(glyph.workspaceMetadataValue, symbolExists: symbols), glyph)
        }
        XCTAssertEqual(SidebarIconGlyph.symbol("server.rack").workspaceMetadataValue, "sf:server.rack")
        XCTAssertEqual(SidebarIconGlyph.symbol("server.rack").groupValue, "server.rack")
    }

    func testCommonPageIsFiveRowsOfEmojiAGroupAccepts() {
        XCTAssertEqual(SidebarEmojiCatalog.common.count, SidebarIconPicker.columns * SidebarIconPicker.visibleRows)
        XCTAssertEqual(Set(SidebarEmojiCatalog.common).count, SidebarEmojiCatalog.common.count)
        for emoji in SidebarEmojiCatalog.common {
            XCTAssertEqual(SidebarIconGlyph.normalizedGroupIcon(emoji), emoji, emoji)
        }
    }

    func testSearchFindsEmojiByUnicodeNameExactFirst() {
        XCTAssertEqual(SidebarEmojiCatalog.search("rocket").first?.glyph, "🚀")
        XCTAssertTrue(SidebarEmojiCatalog.search("folder").contains { $0.glyph == "📁" })
        XCTAssertTrue(SidebarEmojiCatalog.search("Red Apple").contains { $0.glyph == "🍎" })
        XCTAssertEqual(SidebarEmojiCatalog.search("zzqqx"), [])
        XCTAssertEqual(SidebarEmojiCatalog.search("   "), [])
        // No lone skin tones or regional-indicator letters to click.
        XCTAssertFalse(SidebarEmojiCatalog.all.contains { $0.glyph.unicodeScalars.first!.properties.isEmojiModifier })
        XCTAssertFalse(SidebarEmojiCatalog.all.contains { (0x1F1E6...0x1F1FF).contains($0.glyph.unicodeScalars.first!.value) })
    }

    func testPickerCellsForWhatTheOperatorTypes() {
        XCTAssertEqual(SidebarIconPicker.cells(for: "", symbolExists: symbols).count, SidebarEmojiCatalog.common.count)
        XCTAssertEqual(SidebarIconPicker.cells(for: "🚀", symbolExists: symbols), [.text("🚀")])
        XCTAssertEqual(SidebarIconPicker.cells(for: "🚀🧪🚀", symbolExists: symbols), [.text("🚀"), .text("🧪")])
        XCTAssertEqual(SidebarIconPicker.cells(for: "rocket", symbolExists: symbols).first, .text("🚀"))
        XCTAssertEqual(SidebarIconPicker.cells(for: "sf:folder.fill", symbolExists: symbols), [.symbol("folder.fill")])
        XCTAssertEqual(SidebarIconPicker.cells(for: "server.rack", symbolExists: symbols), [.symbol("server.rack")])
        XCTAssertEqual(SidebarIconPicker.cells(for: "sf:nope", symbolExists: symbols), [])
        // Words in another script match no English name and offer no letters.
        XCTAssertEqual(SidebarIconPicker.cells(for: "café", symbolExists: symbols), [])
    }

    /// Pasted emoji with text presentation: Unicode also calls ℹ, Ⓜ and the
    /// blood-type letters letters, and a pasted keycap may come without U+FE0F.
    func testPickerTakesTextPresentationEmojiAndBareKeycaps() {
        for emoji in ["ℹ", "Ⓜ", "🅰", "🅱", "🅾", "🅿", "1\u{20E3}", "#\u{20E3}", "©"] {
            XCTAssertEqual(SidebarIconPicker.cells(for: emoji, symbolExists: symbols), [.text(emoji)], emoji)
            XCTAssertEqual(SidebarIconGlyph.normalizedGroupIcon(emoji, symbolExists: symbols), emoji, emoji)
            XCTAssertEqual(SidebarIconGlyph.forWorkspaceIcon(emoji, symbolExists: symbols), .text(emoji), emoji)
        }
        // Negative controls: letters, a bare digit, punctuation and a control
        // beside an emoji offer only the emoji.
        XCTAssertEqual(SidebarIconPicker.cells(for: "é1.\u{7}🚀!", symbolExists: symbols), [.text("🚀")])
        XCTAssertEqual(SidebarIconPicker.cells(for: "🚀.", symbolExists: symbols), [.text("🚀")])
        XCTAssertEqual(SidebarIconPicker.cells(for: "猫é", symbolExists: symbols), [])
    }

    /// The workspace store caps `icon` at 32 characters; the picker must say
    /// so instead of closing as if a long `sf:` name were set.
    func testWorkspaceValueIsRefusedBeforeTheStoreWouldRefuseIt() throws {
        let long = SidebarIconGlyph.symbol("rectangle.portrait.and.arrow.right.fill")
        XCTAssertThrowsError(try long.checkedWorkspaceMetadataValue()) { error in
            XCTAssertEqual(error as? SidebarIconError,
                           .workspaceIconTooLong(limit: WorkspaceMetadataValidator.maxIconLen))
            XCTAssertFalse((error as? LocalizedError)?.errorDescription?.isEmpty ?? true)
        }
        XCTAssertEqual(try SidebarIconGlyph.symbol("star.fill").checkedWorkspaceMetadataValue(), "sf:star.fill")
        XCTAssertEqual(try SidebarIconGlyph.text("🚀").checkedWorkspaceMetadataValue(), "🚀")
    }

    func testWorkspaceIconWithAControlCharacterDrawsNothing() {
        XCTAssertNil(SidebarIconGlyph.forWorkspaceIcon("\u{7}🚀", symbolExists: symbols))
        XCTAssertNil(SidebarIconGlyph.forWorkspaceIcon("🚀\u{1B}[2J", symbolExists: symbols))
    }

    /// Hair and other emoji components only make sense inside a sequence.
    func testCatalogLeavesOutEmojiComponents() {
        XCTAssertFalse(SidebarEmojiCatalog.all.contains { $0.glyph.unicodeScalars.first!.value == 0x1F9B0 })
        XCTAssertEqual(SidebarEmojiCatalog.search("red hair").map(\.glyph), [])
    }
}
