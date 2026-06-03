import SwiftUI

private struct C11ThemeManagerEnvironmentKey: EnvironmentKey {
    static let defaultValue: ThemeManager? = nil
}

private struct C11ThemeContextEnvironmentKey: EnvironmentKey {
    static let defaultValue: ThemeContext? = nil
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
}
