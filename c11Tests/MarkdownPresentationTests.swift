import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class MarkdownPresentationTests: XCTestCase {
    func testDefaultsLetRendererChooseOutlineVisibility() {
        XCTAssertEqual(MarkdownPresentation().fontScale, 1.0)
        XCTAssertEqual(MarkdownPresentation().theme, "system")
        XCTAssertEqual(MarkdownPresentation().typeface, "theme")
        XCTAssertNil(MarkdownPresentation().outlineOpen)
    }

    func testScaleValidationFallsBackAndRoundsValidSteps() {
        for value in [-1.0, 0.49, 3.01, Double.infinity, -Double.infinity, Double.nan] {
            XCTAssertEqual(MarkdownPresentation(fontScale: value).fontScale, 1.0)
        }
        XCTAssertEqual(MarkdownPresentation(fontScale: 0.5).fontScale, 0.5)
        XCTAssertEqual(MarkdownPresentation(fontScale: 3.0).fontScale, 3.0)
        XCTAssertEqual(MarkdownPresentation(fontScale: 1.0 + 0.1 + 0.1).fontScale, 1.2)
        XCTAssertEqual(MarkdownPresentation(fontScale: 1.9999999).fontScale, 2.0)
    }

    func testRegisteredNamesAreAcceptedAndUnknownNamesFallBack() {
        for theme in ["system", "light", "dark"] {
            XCTAssertEqual(MarkdownPresentation(theme: theme).theme, theme)
        }
        for typeface in ["theme", "serif", "sans", "mono"] {
            XCTAssertEqual(MarkdownPresentation(typeface: typeface).typeface, typeface)
        }
        for unknown in ["", "future-name", "DARK", " dark "] {
            let presentation = MarkdownPresentation(theme: unknown, typeface: unknown)
            XCTAssertEqual(presentation.theme, "system")
            XCTAssertEqual(presentation.typeface, "theme")
        }
    }

    func testPresentationDecodingFallsBackPerField() throws {
        let examples: [(String, MarkdownPresentation)] = [
            (#"{}"#, .default),
            (#"{"fontScale": [], "theme":"dark", "typeface":"mono", "outlineOpen":false}"#,
             MarkdownPresentation(theme: "dark", typeface: "mono", outlineOpen: false)),
            (#"{"fontScale":1.7, "theme":{}, "typeface":"sans", "outlineOpen":true}"#,
             MarkdownPresentation(fontScale: 1.7, typeface: "sans", outlineOpen: true)),
            (#"{"fontScale":2.3, "theme":"light", "typeface":false, "outlineOpen":true}"#,
             MarkdownPresentation(fontScale: 2.3, theme: "light", outlineOpen: true)),
            (#"{"fontScale":0.8, "theme":"dark", "typeface":"serif", "outlineOpen":1}"#,
             MarkdownPresentation(fontScale: 0.8, theme: "dark", typeface: "serif")),
            (#"{"fontScale":8, "theme":"unknown", "typeface":"unknown", "outlineOpen":false}"#,
             MarkdownPresentation(outlineOpen: false)),
            (#"{"fontScale":null,"theme":null,"typeface":null,"outlineOpen":null}"#, .default)
        ]
        for (json, expected) in examples {
            XCTAssertEqual(try decode(MarkdownPresentation.self, json), expected, json)
        }
    }

    func testPopulatedPresentationRoundTripsIncludingExplicitOutlineChoices() throws {
        for outlineOpen in [true, false] {
            let original = MarkdownPresentation(
                fontScale: 1.8, theme: "dark", typeface: "serif", outlineOpen: outlineOpen
            )
            let data = try JSONEncoder().encode(original)
            XCTAssertEqual(try JSONDecoder().decode(MarkdownPresentation.self, from: data), original)
        }
        let data = try JSONEncoder().encode(MarkdownPresentation.default)
        XCTAssertEqual(try JSONDecoder().decode(MarkdownPresentation.self, from: data), .default)
    }

    func testLegacySnapshotKeepsOptionalFieldsAndUsesBuiltInDefaults() throws {
        let legacy = try decode(SessionMarkdownPanelSnapshot.self, #"{"filePath":"/tmp/legacy.md"}"#)
        XCTAssertEqual(legacy.filePath, "/tmp/legacy.md")
        XCTAssertNil(legacy.fontScale)
        XCTAssertNil(legacy.theme)
        XCTAssertNil(legacy.typeface)
        XCTAssertNil(legacy.outlineOpen)
        XCTAssertEqual(legacy.presentation, .default)

        let scaleOnly = try decode(
            SessionMarkdownPanelSnapshot.self, #"{"filePath":"/tmp/legacy.md","fontScale":1.4}"#
        )
        XCTAssertEqual(scaleOnly.presentation, MarkdownPresentation(fontScale: 1.4))
    }

    func testSnapshotMalformedFieldsDoNotDiscardValidNeighborsOrFilePath() throws {
        let examples: [(String, MarkdownPresentation)] = [
            (#"{"fontScale":"1.6","theme":"dark","typeface":"mono","outlineOpen":false}"#,
             MarkdownPresentation(theme: "dark", typeface: "mono", outlineOpen: false)),
            (#"{"fontScale":false,"theme":"light","typeface":"serif","outlineOpen":true}"#,
             MarkdownPresentation(theme: "light", typeface: "serif", outlineOpen: true)),
            (#"{"fontScale":2.2,"theme":[],"typeface":"sans","outlineOpen":false}"#,
             MarkdownPresentation(fontScale: 2.2, typeface: "sans", outlineOpen: false)),
            (#"{"fontScale":1.1,"theme":"dark","typeface":{},"outlineOpen":true}"#,
             MarkdownPresentation(fontScale: 1.1, theme: "dark", outlineOpen: true)),
            (#"{"fontScale":1.9,"theme":"light","typeface":"mono","outlineOpen":"true"}"#,
             MarkdownPresentation(fontScale: 1.9, theme: "light", typeface: "mono")),
            (#"{"fontScale":9,"theme":"future","typeface":"future","outlineOpen":false}"#,
             MarkdownPresentation(outlineOpen: false))
        ]
        for (fields, expected) in examples {
            let json = #"{"filePath":"/tmp/presentation.md","# + fields.dropFirst()
            let snapshot = try decode(SessionMarkdownPanelSnapshot.self, json)
            XCTAssertEqual(snapshot.filePath, "/tmp/presentation.md", json)
            XCTAssertEqual(snapshot.presentation, expected, json)
        }
    }

    func testUnreadableSnapshotPathDoesNotDiscardPresentation() throws {
        let snapshot = try decode(
            SessionMarkdownPanelSnapshot.self,
            #"{"filePath":{},"fontScale":1.3,"theme":"dark","typeface":"mono","outlineOpen":false}"#
        )
        XCTAssertNil(snapshot.filePath)
        XCTAssertEqual(
            snapshot.presentation,
            MarkdownPresentation(fontScale: 1.3, theme: "dark", typeface: "mono", outlineOpen: false)
        )
    }

    func testPopulatedSnapshotRoundTripsEveryPresentationField() throws {
        let original = SessionMarkdownPanelSnapshot(
            filePath: "/tmp/populated.md", fontScale: 2.1, theme: "light", typeface: "sans", outlineOpen: false
        )
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(SessionMarkdownPanelSnapshot.self, from: data)
        XCTAssertEqual(restored.filePath, original.filePath)
        XCTAssertEqual(restored.fontScale, original.fontScale)
        XCTAssertEqual(restored.theme, original.theme)
        XCTAssertEqual(restored.typeface, original.typeface)
        XCTAssertEqual(restored.outlineOpen, original.outlineOpen)
        XCTAssertEqual(restored.presentation, original.presentation)
    }

    func testLastUsedPreferencesRoundTripInIsolatedSuite() throws {
        try withDefaults { defaults in
            XCTAssertEqual(MarkdownPresentation.lastUsed(in: defaults), .default)
            let original = MarkdownPresentation(
                fontScale: 1.6, theme: "dark", typeface: "mono", outlineOpen: false
            )
            original.saveLastUsed(in: defaults)
            XCTAssertEqual(MarkdownPresentation.lastUsed(in: defaults), original)
            MarkdownPresentation(outlineOpen: true).saveLastUsed(in: defaults, fields: [.outlineOpen])
            XCTAssertEqual(MarkdownPresentation.lastUsed(in: defaults).outlineOpen, true)
        }
    }

    func testSavingOneFieldDoesNotPublishOtherRestoredPreferences() throws {
        try withDefaults { defaults in
            MarkdownPresentation(fontScale: 1.2, theme: "light", typeface: "sans", outlineOpen: false)
                .saveLastUsed(in: defaults)
            let restored = SessionMarkdownPanelSnapshot(
                filePath: "/tmp/restored.md", fontScale: 2.4, theme: "dark", typeface: "mono", outlineOpen: true
            )
            var changed = restored.presentation
            changed.fontScale = 2.5
            changed.saveLastUsed(in: defaults, fields: [.fontScale])
            XCTAssertEqual(
                MarkdownPresentation.lastUsed(in: defaults),
                MarkdownPresentation(fontScale: 2.5, theme: "light", typeface: "sans", outlineOpen: false)
            )
            XCTAssertEqual(restored.presentation.theme, "dark")
        }
    }

    func testCorruptLastUsedValuesFallBackIndependentlyWithoutCoercion() throws {
        try withDefaults { defaults in
            defaults.set("1.7", forKey: "markdown.fontScale.lastUsed")
            defaults.set("dark", forKey: "markdown.theme.lastUsed")
            defaults.set("mono", forKey: "markdown.typeface.lastUsed")
            defaults.set(false, forKey: "markdown.outlineOpen.lastUsed")
            XCTAssertEqual(
                MarkdownPresentation.lastUsed(in: defaults),
                MarkdownPresentation(theme: "dark", typeface: "mono", outlineOpen: false)
            )

            defaults.set(true, forKey: "markdown.fontScale.lastUsed")
            defaults.set(15, forKey: "markdown.theme.lastUsed")
            defaults.set(["mono"], forKey: "markdown.typeface.lastUsed")
            defaults.set(1, forKey: "markdown.outlineOpen.lastUsed")
            XCTAssertEqual(MarkdownPresentation.lastUsed(in: defaults), .default)

            defaults.set(10.0, forKey: "markdown.fontScale.lastUsed")
            defaults.set("future-theme", forKey: "markdown.theme.lastUsed")
            defaults.set("future-face", forKey: "markdown.typeface.lastUsed")
            defaults.set("false", forKey: "markdown.outlineOpen.lastUsed")
            XCTAssertEqual(MarkdownPresentation.lastUsed(in: defaults), .default)
        }
    }

    func testSavingAutomaticOutlineRemovesExplicitChoiceWithoutOtherChanges() throws {
        try withDefaults { defaults in
            MarkdownPresentation(fontScale: 1.5, theme: "dark", typeface: "serif", outlineOpen: false)
                .saveLastUsed(in: defaults)
            MarkdownPresentation().saveLastUsed(in: defaults, fields: [.outlineOpen])
            XCTAssertNil(defaults.object(forKey: "markdown.outlineOpen.lastUsed"))
            XCTAssertEqual(
                MarkdownPresentation.lastUsed(in: defaults),
                MarkdownPresentation(fontScale: 1.5, theme: "dark", typeface: "serif")
            )
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "com.stage11.c11.tests.markdown-presentation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
