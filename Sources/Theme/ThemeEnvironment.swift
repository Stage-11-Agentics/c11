import SwiftUI

private struct C11ThemeManagerEnvironmentKey: EnvironmentKey {
    static let defaultValue: ThemeManager? = nil
}

private struct C11ThemeContextEnvironmentKey: EnvironmentKey {
    static let defaultValue: ThemeContext? = nil
}

/// c11 (C11H-197): the theme name the hosting main window overrides the app
/// theme with; nil follows the app theme. `ContentView` injects it at each
/// window's root.
private struct C11WindowThemeNameEnvironmentKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var c11ThemeManager: ThemeManager? {
        get { self[C11ThemeManagerEnvironmentKey.self] }
        set { self[C11ThemeManagerEnvironmentKey.self] = newValue }
    }

    var c11ThemeContext: ThemeContext? {
        get { self[C11ThemeContextEnvironmentKey.self] }
        set { self[C11ThemeContextEnvironmentKey.self] = newValue }
    }

    var c11WindowThemeName: String? {
        get { self[C11WindowThemeNameEnvironmentKey.self] }
        set { self[C11WindowThemeNameEnvironmentKey.self] = newValue }
    }
}
