import Foundation

/// c11's managed terminal-theme block in its own `config.ghostty`, never the operator's
/// Ghostty config. The CLI (`terminal-theme set`, `themes set --with-terminal`) and
/// Settings' theme picker both write it through here, so they agree on the block.
public enum TerminalThemeOverride {
    public static let blockStart = "# cmux themes start"
    public static let blockEnd = "# cmux themes end"

    /// The `theme =` value that gives the terminal `pair` by day and by night.
    public static func value(pairing pair: String) -> String {
        "light:\(pair),dark:\(pair)"
    }

    /// `existing` with the managed block replaced by one that sets `theme = rawValue`.
    public static func contents(settingTheme rawValue: String, in existing: String) -> String {
        let stripped = removingBlock(from: existing).trimmingCharacters(in: .whitespacesAndNewlines)
        let block = "\(blockStart)\ntheme = \(rawValue)\n\(blockEnd)"
        return stripped.isEmpty ? "\(block)\n" : "\(stripped)\n\n\(block)\n"
    }

    /// `contents` without the managed block; everything else is kept as written.
    public static func removingBlock(from contents: String) -> String {
        let pattern = #"(?ms)\n?# cmux themes start\n.*?\n# cmux themes end\n?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return contents }
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return regex.stringByReplacingMatches(in: contents, options: [], range: range, withTemplate: "")
    }

    /// Writes the block into `configURL`, creating its folder and keeping the rest of the file.
    public static func write(settingTheme rawValue: String, to configURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        try contents(settingTheme: rawValue, in: existing).write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// The `config.ghostty` this app reads for its managed block:
    /// `~/Library/Application Support/<bundle id>/`. A test build has its own bundle id,
    /// so it never writes the installed app's file.
    public static func appConfigURL(
        bundleIdentifier: String,
        applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> URL? {
        guard let applicationSupport, !bundleIdentifier.isEmpty else { return nil }
        return applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
    }
}
