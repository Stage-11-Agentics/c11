import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// The Chaos Wizard's pure logic (C11H-199): seeded draws, DECK.md, the
/// prompt's one hard rule, ensemble picks and the 2x2 placement. The cast's
/// launches are proven against the real app, not here.
final class ChaosDeckTests: XCTestCase {
    func testTheSameSeedDrawsTheSamePiecesWithDistinctPremises() {
        let deck = ChaosDeck.builtIn
        let a = deck.draw(count: 4, seed: 42)
        XCTAssertEqual(a, deck.draw(count: 4, seed: 42))
        XCTAssertNotEqual(a, deck.draw(count: 4, seed: 43))
        XCTAssertEqual(Set(a.map(\.premise.title)).count, 4)
        XCTAssertEqual(Set(a.map(\.medium)).count, 4)
        XCTAssertEqual(Set(a.map(\.constraint)).count, 4)
    }

    func testDeckMarkdownRoundTripsAndMissingSectionsFallBack() {
        XCTAssertEqual(ChaosDeck.parse(markdown: ChaosDeck.builtIn.markdown()), .builtIn)
        let partial = ChaosDeck.parse(markdown: """
        # My deck
        ## Premises
        - Tiny Parliament: a parliament of houseflies
        * a premise with no colon at all
        ## Something else
        - ignored
        """)
        XCTAssertEqual(partial.premises, [
            ChaosPremise(title: "Tiny Parliament", text: "a parliament of houseflies"),
            ChaosPremise(title: "a premise with", text: "a premise with no colon at all"),
        ])
        XCTAssertEqual(partial.media, ChaosDeck.builtIn.media)
        XCTAssertEqual(partial.constraints, ChaosDeck.builtIn.constraints)
    }

    func testStudioNamesAreFolderSafe() {
        XCTAssertEqual(ChaosDeck.slug("The Moon's Tax Return"), "the-moon-s-tax-return")
        XCTAssertEqual(ChaosDeck.slug("  ***  "), "piece")
        XCTAssertLessThanOrEqual(ChaosDeck.slug(String(repeating: "word ", count: 30)).count, 32)
        let piece = ChaosPiece(premise: .init(title: "Pigeon Mesh", text: "x"), medium: "m", constraint: "c")
        XCTAssertEqual(piece.studioName(index: 2), "3-pigeon-mesh")
    }

    func testThePromptConfinesTheAgentToItsStudio() {
        let piece = ChaosDeck.builtIn.draw(count: 1, seed: 1)[0]
        let studio = "/tmp/Chaos/2026-11-04-1432/1-x"
        let prompt = ChaosPrompt.compose(piece: piece, studio: studio, artistCount: 4)
        XCTAssertTrue(prompt.contains("Your studio is \"\(studio)\". Create, change and delete files only inside it"))
        XCTAssertTrue(prompt.contains("Use no network"))
        XCTAssertTrue(prompt.contains("never cast Chaos yourself"))
        XCTAssertTrue(prompt.contains("c11 rename-panel --panel \"$C11_PANEL_ID\""))
        XCTAssertTrue(prompt.contains("c11 browser open \"file://\(studio)/index.html\""))
        XCTAssertTrue(prompt.contains(piece.premise.text))
        XCTAssertTrue(prompt.contains("one of 4 artists"))
        XCTAssertFalse(ChaosPrompt.compose(piece: piece, studio: studio, artistCount: 1).contains("one of"))
    }

    func testTheHeadlineShowsThePieceOnOneLine() {
        let piece = ChaosDeck.builtIn.draw(count: 4, seed: 9)[1]
        let line = ChaosPrompt.headline(piece: piece, index: 1, artistCount: 2)
        XCTAssertTrue(line.hasPrefix("Chaos Wizard commission 2 of 2: "))
        for part in [piece.premise.title, piece.premise.text, piece.medium, piece.constraint] {
            XCTAssertTrue(line.contains(part), part)
        }
        XCTAssertEqual(LaunchPromptDelivery.sanitizedHeadline(line), line, "fits and needs no cleanup")

        let dotted = ChaosPiece(premise: .init(title: "T", text: "a premise."), medium: "zine.", constraint: "one rule!")
        XCTAssertEqual(ChaosPrompt.headline(piece: dotted, index: 0, artistCount: 1),
                       "Chaos Wizard commission: \"T\", a premise. Medium: zine. Constraint: one rule.")
    }

    func testAnEnsembleTakesANewHarnessForEachPieceThenRepeats() {
        func config(_ id: String, _ harness: String, _ order: Int) -> SavedAgentConfig {
            SavedAgentConfig(id: id, name: id, order: order, config: AgentLaunchConfig(harness: harness))
        }
        let opus = config("opus", "claude-code", 0)
        let sonnet = config("sonnet", "claude-code", 1)
        let codex = config("codex", "codex", 2)
        let grok = config("grok", "grok", 3)
        let all = [grok, sonnet, opus, codex]
        XCTAssertEqual(ChaosEnsemble.artists(mode: .ensemble, count: 4, configs: all, defaultConfig: opus).map(\.id),
                       ["opus", "codex", "grok", "sonnet"])
        XCTAssertEqual(ChaosEnsemble.artists(mode: .ensemble, count: 3, configs: [opus], defaultConfig: opus).map(\.id),
                       ["opus", "opus", "opus"])
        XCTAssertEqual(ChaosEnsemble.artists(mode: .four, count: 4, configs: all, defaultConfig: codex).map(\.id),
                       ["codex", "codex", "codex", "codex"])
    }

    func testFourPiecesFillTwoColumnsOfTwo() {
        XCTAssertNil(ChaosCaster.placement(index: 0))
        XCTAssertEqual(ChaosCaster.placement(index: 1)?.anchor, 0)
        XCTAssertEqual(ChaosCaster.placement(index: 1)?.split, "right")
        XCTAssertEqual(ChaosCaster.placement(index: 2)?.anchor, 0)
        XCTAssertEqual(ChaosCaster.placement(index: 2)?.split, "down")
        XCTAssertEqual(ChaosCaster.placement(index: 3)?.anchor, 1)
        XCTAssertEqual(ChaosCaster.placement(index: 3)?.split, "down")
    }

    func testRunNamesUseLocalTime() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-04T22:32:00Z"))
        let names = ChaosCaster.names(at: date, timeZone: zone)
        XCTAssertEqual(names.folder, "2026-11-04-1432")
        XCTAssertEqual(names.title, "Chaos 14:32")
    }

    func testGalleryPagesEscapeWhatTheDeckSays() {
        let piece = ChaosPiece(premise: .init(title: "<b>Bold</b>", text: "a & b"), medium: "m", constraint: "c")
        let page = ChaosGallery.runPage(title: "Chaos 14:32",
                                        entries: [.init(studio: "1-bold b", piece: piece, agent: "Opus High")])
        XCTAssertTrue(page.contains("&lt;b&gt;Bold&lt;/b&gt;"))
        XCTAssertTrue(page.contains("a &amp; b"))
        XCTAssertTrue(page.contains("href=\"./1-bold%20b/index.html\""))
        XCTAssertTrue(page.contains("rel=\"icon\""))
    }
}
