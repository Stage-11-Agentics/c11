import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Unit tests for `ChromeScaleSettings` — preset enum, multiplier table, and
/// the parameter-seam `preset(defaults:)` resolver. (C11-6)
final class ChromeScaleSettingsTests: XCTestCase {

    // MARK: - preset(for:)

    func testPresetForNilFallsBackToDefault() {
        XCTAssertEqual(ChromeScaleSettings.preset(for: nil), .standard)
    }

    func testPresetForEmptyStringFallsBackToDefault() {
        XCTAssertEqual(ChromeScaleSettings.preset(for: ""), .standard)
    }

    func testPresetForUnknownStringFallsBackToDefault() {
        XCTAssertEqual(ChromeScaleSettings.preset(for: "tiny"), .standard)
    }

    func testPresetForKnownStringsResolves() {
        XCTAssertEqual(ChromeScaleSettings.preset(for: "compact"), .compact)
        XCTAssertEqual(ChromeScaleSettings.preset(for: "standard"), .standard)
        XCTAssertEqual(ChromeScaleSettings.preset(for: "large"), .large)
        XCTAssertEqual(ChromeScaleSettings.preset(for: "extraLarge"), .extraLarge)
        XCTAssertEqual(ChromeScaleSettings.preset(for: "custom"), .custom)
    }

    // MARK: - preset(defaults:)

    func testPresetDefaultsRoundtripsThroughUserDefaults() {
        let suite = "ChromeScaleSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ChromeScaleSettings.preset(defaults: defaults), .standard)

        defaults.set("large", forKey: ChromeScaleSettings.presetKey)
        XCTAssertEqual(ChromeScaleSettings.preset(defaults: defaults), .large)

        defaults.set("extraLarge", forKey: ChromeScaleSettings.presetKey)
        XCTAssertEqual(ChromeScaleSettings.preset(defaults: defaults), .extraLarge)

        defaults.set("custom", forKey: ChromeScaleSettings.presetKey)
        XCTAssertEqual(ChromeScaleSettings.preset(defaults: defaults), .custom)
    }

    func testPresetDefaultsFallsBackOnGarbage() {
        let suite = "ChromeScaleSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("not-a-preset", forKey: ChromeScaleSettings.presetKey)
        XCTAssertEqual(ChromeScaleSettings.preset(defaults: defaults), .standard)
    }

    // MARK: - multiplier(for:)

    func testMultiplierTable() {
        XCTAssertEqual(ChromeScaleSettings.multiplier(for: .compact),    0.85, accuracy: 0.0001)
        XCTAssertEqual(ChromeScaleSettings.multiplier(for: .standard),   1.00, accuracy: 0.0001)
        XCTAssertEqual(ChromeScaleSettings.multiplier(for: .large),      1.25, accuracy: 0.0001)
        XCTAssertEqual(ChromeScaleSettings.multiplier(for: .extraLarge), 1.55, accuracy: 0.0001)
        XCTAssertEqual(
            ChromeScaleSettings.multiplier(for: .custom),
            ChromeScaleSettings.defaultCustomMultiplier,
            accuracy: 0.0001
        )
    }

    // MARK: - multiplier(preset:defaults:) — Custom slider

    func testCustomMultiplierReadsFromDefaults() {
        let suite = "ChromeScaleSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(1.75, forKey: ChromeScaleSettings.customMultiplierKey)
        XCTAssertEqual(
            ChromeScaleSettings.multiplier(preset: .custom, defaults: defaults),
            1.75,
            accuracy: 0.0001
        )
    }

    func testCustomMultiplierClampsAboveMax() {
        let suite = "ChromeScaleSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(99.0, forKey: ChromeScaleSettings.customMultiplierKey)
        XCTAssertEqual(
            ChromeScaleSettings.multiplier(preset: .custom, defaults: defaults),
            ChromeScaleSettings.customMultiplierRange.upperBound,
            accuracy: 0.0001
        )
    }

    func testCustomMultiplierClampsBelowMin() {
        let suite = "ChromeScaleSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(0.10, forKey: ChromeScaleSettings.customMultiplierKey)
        XCTAssertEqual(
            ChromeScaleSettings.multiplier(preset: .custom, defaults: defaults),
            ChromeScaleSettings.customMultiplierRange.lowerBound,
            accuracy: 0.0001
        )
    }

    func testCustomMultiplierFallsBackOnMissingKey() {
        let suite = "ChromeScaleSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // No custom value persisted — should not collapse to 0.
        XCTAssertEqual(
            ChromeScaleSettings.multiplier(preset: .custom, defaults: defaults),
            ChromeScaleSettings.defaultCustomMultiplier,
            accuracy: 0.0001
        )
    }

    func testNonCustomPresetIgnoresCustomKey() {
        let suite = "ChromeScaleSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(2.5, forKey: ChromeScaleSettings.customMultiplierKey)
        XCTAssertEqual(
            ChromeScaleSettings.multiplier(preset: .large, defaults: defaults),
            1.25,
            accuracy: 0.0001
        )
    }

    // MARK: - multiplier(presetRaw:customMultiplier:) — SwiftUI helper

    func testMultiplierFromRawHonorsCustomValue() {
        XCTAssertEqual(
            ChromeScaleSettings.multiplier(presetRaw: "custom", customMultiplier: 2.0),
            2.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ChromeScaleSettings.multiplier(presetRaw: "compact", customMultiplier: 2.0),
            0.85,
            accuracy: 0.0001
        )
    }

    func testMultiplierFromRawClampsCustomValue() {
        XCTAssertEqual(
            ChromeScaleSettings.multiplier(presetRaw: "custom", customMultiplier: 99.0),
            ChromeScaleSettings.customMultiplierRange.upperBound,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ChromeScaleSettings.multiplier(presetRaw: "custom", customMultiplier: 0.0),
            ChromeScaleSettings.defaultCustomMultiplier,
            accuracy: 0.0001
        )
    }

    // MARK: - Preset.displayName

    func testEveryPresetHasNonEmptyDisplayName() {
        for preset in ChromeScaleSettings.Preset.allCases {
            XCTAssertFalse(preset.displayName.isEmpty, "Empty displayName for preset \(preset.rawValue)")
        }
    }

    // MARK: - Preset basics

    func testAllCasesContainsFive() {
        XCTAssertEqual(ChromeScaleSettings.Preset.allCases.count, 5)
    }

    func testIdMatchesRawValue() {
        for preset in ChromeScaleSettings.Preset.allCases {
            XCTAssertEqual(preset.id, preset.rawValue)
        }
    }
}
