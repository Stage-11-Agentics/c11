import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Host-free unit tests for `SurfaceTypeAvailability` — the pure gate that both
/// the UI spawn affordances and the socket/CLI creation handlers consult to
/// decide whether a browser or markdown surface may be created.
final class TabTypeAvailabilityTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "TabTypeAvailabilityTests.\(UUID().uuidString)")!
    }

    // MARK: - Terminal is never gated

    func testTerminalAlwaysEnabledRegardlessOfDefaultsOrEnv() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: PanelTypeAvailability.internalBrowserEnabledKey)
        defaults.set(false, forKey: PanelTypeAvailability.markdownPanelsEnabledKey)
        let env = [
            PanelTypeAvailability.disableBrowserEnvKey: "1",
            PanelTypeAvailability.disableMarkdownEnvKey: "1",
        ]
        XCTAssertTrue(PanelTypeAvailability.isEnabled(.terminal, defaults: defaults, environment: env))
    }

    // MARK: - Defaults (no keys, no env) → everything enabled

    func testBrowserEnabledByDefaultWhenKeyUnset() {
        let defaults = freshDefaults()
        XCTAssertTrue(PanelTypeAvailability.isEnabled(.browser, defaults: defaults, environment: [:]))
    }

    func testMarkdownEnabledByDefaultWhenKeyUnset() {
        let defaults = freshDefaults()
        XCTAssertTrue(PanelTypeAvailability.isEnabled(.markdown, defaults: defaults, environment: [:]))
    }

    // MARK: - Persisted toggle drives each type independently

    func testBrowserDisabledWhenKeyFalse() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: PanelTypeAvailability.internalBrowserEnabledKey)
        XCTAssertFalse(PanelTypeAvailability.isEnabled(.browser, defaults: defaults, environment: [:]))
        // Markdown is unaffected by the browser switch.
        XCTAssertTrue(PanelTypeAvailability.isEnabled(.markdown, defaults: defaults, environment: [:]))
    }

    func testMarkdownDisabledWhenKeyFalse() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: PanelTypeAvailability.markdownPanelsEnabledKey)
        XCTAssertFalse(PanelTypeAvailability.isEnabled(.markdown, defaults: defaults, environment: [:]))
        // Browser is unaffected by the markdown switch.
        XCTAssertTrue(PanelTypeAvailability.isEnabled(.browser, defaults: defaults, environment: [:]))
    }

    func testExplicitTrueKeyKeepsTypeEnabled() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: PanelTypeAvailability.internalBrowserEnabledKey)
        defaults.set(true, forKey: PanelTypeAvailability.markdownPanelsEnabledKey)
        XCTAssertTrue(PanelTypeAvailability.isEnabled(.browser, defaults: defaults, environment: [:]))
        XCTAssertTrue(PanelTypeAvailability.isEnabled(.markdown, defaults: defaults, environment: [:]))
    }

    // MARK: - Environment override forces disable (and only disable)

    func testBrowserEnvOverrideDisablesEvenWhenKeyTrue() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: PanelTypeAvailability.internalBrowserEnabledKey)
        let env = [PanelTypeAvailability.disableBrowserEnvKey: "1"]
        XCTAssertFalse(PanelTypeAvailability.isEnabled(.browser, defaults: defaults, environment: env))
        // Only browser; markdown stays enabled.
        XCTAssertTrue(PanelTypeAvailability.isEnabled(.markdown, defaults: defaults, environment: env))
    }

    func testMarkdownEnvOverrideDisablesEvenWhenKeyTrue() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: PanelTypeAvailability.markdownPanelsEnabledKey)
        let env = [PanelTypeAvailability.disableMarkdownEnvKey: "1"]
        XCTAssertFalse(PanelTypeAvailability.isEnabled(.markdown, defaults: defaults, environment: env))
        XCTAssertTrue(PanelTypeAvailability.isEnabled(.browser, defaults: defaults, environment: env))
    }

    func testEnvOverrideAcceptsCommonTruthyTokens() {
        let defaults = freshDefaults()
        for token in ["1", "true", "yes", "on", "TRUE", "On"] {
            let env = [PanelTypeAvailability.disableBrowserEnvKey: token]
            XCTAssertFalse(
                PanelTypeAvailability.isEnabled(.browser, defaults: defaults, environment: env),
                "token \(token) should disable the browser"
            )
        }
    }

    func testEnvOverrideIgnoresEmptyOrFalsyTokens() {
        let defaults = freshDefaults()
        for token in ["", "0", "false", "no", "off", "  "] {
            let env = [PanelTypeAvailability.disableBrowserEnvKey: token]
            XCTAssertTrue(
                PanelTypeAvailability.isEnabled(.browser, defaults: defaults, environment: env),
                "token \(token.debugDescription) should not disable the browser"
            )
        }
    }

    // MARK: - Disabled messages name the type and where to re-enable

    func testDisabledMessagesAreActionable() {
        let browser = PanelTypeAvailability.disabledMessage(for: .browser)
        XCTAssertTrue(browser.contains("browser"))
        XCTAssertTrue(browser.contains("Settings"))

        let markdown = PanelTypeAvailability.disabledMessage(for: .markdown)
        XCTAssertTrue(markdown.contains("markdown"))
        XCTAssertTrue(markdown.contains("Settings"))
    }
}
