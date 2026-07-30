import Foundation

/// Operator-facing availability gate for c11's non-terminal surface types.
///
/// Two independent switches — the internal browser and markdown surfaces —
/// each default **on**. Disabling a type blocks *creating new* surfaces of
/// that type everywhere: the tab-bar spawn affordances are hidden and the
/// CLI/socket creation commands reject the request with an actionable error.
/// Surfaces that are already open keep running until the operator closes them;
/// this gate never tears anything down.
///
/// The gate lives at the creation-request layer (socket handlers + the
/// Bonsplit `didRequestNewTab` delegate), **not** inside the low-level
/// `Workspace.newBrowser*` / `newMarkdown*` methods. Snapshot/restore rebuilds
/// saved layouts through those low-level methods directly, so restoring an
/// existing browser or markdown surface still works even while the type is
/// disabled — restoring saved state is not the same as creating something new.
///
/// Mirrors `SocketControlSettings`: persisted `@AppStorage` booleans plus an
/// environment override (`C11_DISABLE_BROWSER` / `C11_DISABLE_MARKDOWN`) for
/// headless runs and tests. The environment override only ever *disables* a
/// type; it never force-enables one the operator turned off.
enum SurfaceTypeAvailability {
    /// `@AppStorage` key — `true` (or unset) means the internal browser can be spawned.
    static let internalBrowserEnabledKey = "internalBrowserEnabled"
    /// `@AppStorage` key — `true` (or unset) means markdown surfaces can be spawned.
    static let markdownSurfacesEnabledKey = "markdownSurfacesEnabled"
    /// `@AppStorage` key — `true` (or unset) shows the Markdown spawn button in
    /// the tab bar. Distinct from `markdownSurfacesEnabledKey`: hiding the
    /// button keeps markdown surfaces fully available to the CLI, socket, and
    /// command palette — it only reclaims the toolbar slot.
    static let markdownSpawnButtonVisibleKey = "markdownSpawnButtonVisible"

    /// Truthy in the environment forces the internal browser off (tests/headless).
    static let disableBrowserEnvKey = "C11_DISABLE_BROWSER"
    /// Truthy in the environment forces markdown surfaces off (tests/headless).
    static let disableMarkdownEnvKey = "C11_DISABLE_MARKDOWN"

    /// Both switches default on — no behavior change unless the operator opts out.
    static let defaultEnabled = true

    /// Single source of truth for the gate. Terminal surfaces are never gated.
    static func isEnabled(
        _ type: PanelType,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switch type {
        case .terminal:
            return true
        case .browser:
            return resolve(
                storageKey: internalBrowserEnabledKey,
                disableEnvKey: disableBrowserEnvKey,
                defaults: defaults,
                environment: environment
            )
        case .markdown:
            return resolve(
                storageKey: markdownSurfacesEnabledKey,
                disableEnvKey: disableMarkdownEnvKey,
                defaults: defaults,
                environment: environment
            )
        }
    }

    /// Whether the tab bar shows the Markdown spawn button. Requires markdown
    /// surfaces to be enabled at all; on top of that, the visibility toggle
    /// (default on) can reclaim the toolbar slot without disabling the surface
    /// type.
    static func isMarkdownSpawnButtonVisible(defaults: UserDefaults = .standard) -> Bool {
        guard isEnabled(.markdown, defaults: defaults) else { return false }
        if defaults.object(forKey: markdownSpawnButtonVisibleKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: markdownSpawnButtonVisibleKey)
    }

    private static func resolve(
        storageKey: String,
        disableEnvKey: String,
        defaults: UserDefaults,
        environment: [String: String]
    ) -> Bool {
        if SocketControlSettings.isTruthy(environment[disableEnvKey]) {
            return false
        }
        if defaults.object(forKey: storageKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: storageKey)
    }

    /// Actionable message for a blocked creation attempt. Plain English — these
    /// surface as CLI/socket error envelopes, not localized in-app UI strings.
    static func disabledMessage(for type: PanelType) -> String {
        switch type {
        case .browser:
            return "browser surfaces are disabled (Settings → General → Surfaces → Internal Browser)"
        case .markdown:
            return "markdown surfaces are disabled (Settings → General → Surfaces → Markdown Surfaces)"
        case .terminal:
            return "terminal surfaces cannot be disabled"
        }
    }
}

/// KVO bridge so each `Workspace` (an `ObservableObject`, not an `NSObject`)
/// can react to surface-availability toggles live, without an app restart.
/// Mirrors `ChromeScaleObserver`: observe the two `@AppStorage` keys, hop to
/// the main actor, invoke the callback (which rebuilds the Bonsplit config so
/// the spawn buttons appear/disappear).
final class SurfaceAvailabilityObserver: NSObject {
    private let onChange: () -> Void
    private static let observedKeys = [
        SurfaceTypeAvailability.internalBrowserEnabledKey,
        SurfaceTypeAvailability.markdownSurfacesEnabledKey,
        SurfaceTypeAvailability.markdownSpawnButtonVisibleKey,
    ]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, onChange: @escaping () -> Void) {
        self.defaults = defaults
        self.onChange = onChange
        super.init()
        for key in Self.observedKeys {
            defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        }
    }

    deinit {
        for key in Self.observedKeys {
            defaults.removeObserver(self, forKeyPath: key)
        }
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard let keyPath, Self.observedKeys.contains(keyPath) else { return }
        let onChange = self.onChange
        Task { @MainActor in onChange() }
    }
}
