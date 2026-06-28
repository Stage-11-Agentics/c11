import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Host-free unit tests for `SurfaceTypeAvailability` — the pure gate that both
/// the UI spawn affordances and the socket/CLI creation handlers consult to
/// decide whether a browser or markdown surface may be created.
final class SurfaceTypeAvailabilityTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SurfaceTypeAvailabilityTests.\(UUID().uuidString)")!
    }

    // MARK: - Terminal is never gated

    func testTerminalAlwaysEnabledRegardlessOfDefaultsOrEnv() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: SurfaceTypeAvailability.internalBrowserEnabledKey)
        defaults.set(false, forKey: SurfaceTypeAvailability.markdownSurfacesEnabledKey)
        let env = [
            SurfaceTypeAvailability.disableBrowserEnvKey: "1",
            SurfaceTypeAvailability.disableMarkdownEnvKey: "1",
        ]
        XCTAssertTrue(SurfaceTypeAvailability.isEnabled(.terminal, defaults: defaults, environment: env))
    }

    // MARK: - Defaults (no keys, no env) → everything enabled

    func testBrowserEnabledByDefaultWhenKeyUnset() {
        let defaults = freshDefaults()
        XCTAssertTrue(SurfaceTypeAvailability.isEnabled(.browser, defaults: defaults, environment: [:]))
    }

    func testMarkdownEnabledByDefaultWhenKeyUnset() {
        let defaults = freshDefaults()
        XCTAssertTrue(SurfaceTypeAvailability.isEnabled(.markdown, defaults: defaults, environment: [:]))
    }

    // MARK: - Persisted toggle drives each type independently

    func testBrowserDisabledWhenKeyFalse() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: SurfaceTypeAvailability.internalBrowserEnabledKey)
        XCTAssertFalse(SurfaceTypeAvailability.isEnabled(.browser, defaults: defaults, environment: [:]))
        // Markdown is unaffected by the browser switch.
        XCTAssertTrue(SurfaceTypeAvailability.isEnabled(.markdown, defaults: defaults, environment: [:]))
    }

    func testMarkdownDisabledWhenKeyFalse() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: SurfaceTypeAvailability.markdownSurfacesEnabledKey)
        XCTAssertFalse(SurfaceTypeAvailability.isEnabled(.markdown, defaults: defaults, environment: [:]))
        // Browser is unaffected by the markdown switch.
        XCTAssertTrue(SurfaceTypeAvailability.isEnabled(.browser, defaults: defaults, environment: [:]))
    }

    func testExplicitTrueKeyKeepsTypeEnabled() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: SurfaceTypeAvailability.internalBrowserEnabledKey)
        defaults.set(true, forKey: SurfaceTypeAvailability.markdownSurfacesEnabledKey)
        XCTAssertTrue(SurfaceTypeAvailability.isEnabled(.browser, defaults: defaults, environment: [:]))
        XCTAssertTrue(SurfaceTypeAvailability.isEnabled(.markdown, defaults: defaults, environment: [:]))
    }

    // MARK: - Environment override forces disable (and only disable)

    func testBrowserEnvOverrideDisablesEvenWhenKeyTrue() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: SurfaceTypeAvailability.internalBrowserEnabledKey)
        let env = [SurfaceTypeAvailability.disableBrowserEnvKey: "1"]
        XCTAssertFalse(SurfaceTypeAvailability.isEnabled(.browser, defaults: defaults, environment: env))
        // Only browser; markdown stays enabled.
        XCTAssertTrue(SurfaceTypeAvailability.isEnabled(.markdown, defaults: defaults, environment: env))
    }

    func testMarkdownEnvOverrideDisablesEvenWhenKeyTrue() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: SurfaceTypeAvailability.markdownSurfacesEnabledKey)
        let env = [SurfaceTypeAvailability.disableMarkdownEnvKey: "1"]
        XCTAssertFalse(SurfaceTypeAvailability.isEnabled(.markdown, defaults: defaults, environment: env))
        XCTAssertTrue(SurfaceTypeAvailability.isEnabled(.browser, defaults: defaults, environment: env))
    }

    func testEnvOverrideAcceptsCommonTruthyTokens() {
        let defaults = freshDefaults()
        for token in ["1", "true", "yes", "on", "TRUE", "On"] {
            let env = [SurfaceTypeAvailability.disableBrowserEnvKey: token]
            XCTAssertFalse(
                SurfaceTypeAvailability.isEnabled(.browser, defaults: defaults, environment: env),
                "token \(token) should disable the browser"
            )
        }
    }

    func testEnvOverrideIgnoresEmptyOrFalsyTokens() {
        let defaults = freshDefaults()
        for token in ["", "0", "false", "no", "off", "  "] {
            let env = [SurfaceTypeAvailability.disableBrowserEnvKey: token]
            XCTAssertTrue(
                SurfaceTypeAvailability.isEnabled(.browser, defaults: defaults, environment: env),
                "token \(token.debugDescription) should not disable the browser"
            )
        }
    }

    // MARK: - Disabled messages name the type and where to re-enable

    func testDisabledMessagesAreActionable() {
        let browser = SurfaceTypeAvailability.disabledMessage(for: .browser)
        XCTAssertTrue(browser.contains("browser"))
        XCTAssertTrue(browser.contains("Settings"))

        let markdown = SurfaceTypeAvailability.disabledMessage(for: .markdown)
        XCTAssertTrue(markdown.contains("markdown"))
        XCTAssertTrue(markdown.contains("Settings"))
    }
}
