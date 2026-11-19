import Foundation

/// `c11 themes set <name> --with-terminal`: a chrome theme may name a Ghostty terminal theme
/// in `[terminal] pairedTheme`. The app reports each theme's pair over the socket and the CLI
/// applies it through the terminal-theme override; both targets compile this file so they
/// read one rule.
public enum TerminalThemePairing {
    /// The socket key that carries a theme's pair. Its value is JSON null when the theme
    /// names none, so a missing key means the app predates pairing.
    public static let pairKey = "paired_terminal_theme"

    /// A pair as a theme writes it: trimmed, nil when empty.
    public static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// What a `theme.list` item says about its pair.
    public enum Lookup: Equatable {
        /// The key is absent: the app predates pairing, so no pair proves nothing.
        case unsupported
        case unpaired
        case paired(String)
    }

    public static func lookup(in item: [String: Any]) -> Lookup {
        guard let value = item[pairKey] else { return .unsupported }
        guard let name = normalized(value as? String) else { return .unpaired }
        return .paired(name)
    }

    /// The value a socket payload carries for a pair: the name, or null.
    public static func payloadValue(_ pair: String?) -> Any {
        normalized(pair) ?? NSNull()
    }
}
