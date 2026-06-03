import Foundation

/// C11-104 — color palette for the worktree chip's dot prefix.
///
/// A small, stable, theme-neutral palette: 10 hues picked to remain
/// legible against both the Light and Dark theme slots' sidebar
/// backgrounds. Hash-derived from the absolute worktree path so a
/// given worktree gets the same color across launches.
///
/// Palette tuned for chroma ~50–70%, lightness ~55–65% — bright
/// enough to read on Dark, not so saturated that it shouts on Light.
public enum WorktreeColorPalette {
    /// Hex strings (uppercase, no `#`) in RGB sRGB. Order is meaningful:
    /// the hash function returns `index % entries.count`.
    public static let entries: [String] = [
        "5FB3FF", // sky
        "FF8FB1", // rose
        "9CE07F", // pistachio
        "FFC857", // amber
        "B49DFF", // lavender
        "5EE6CC", // turquoise
        "FF9D5C", // tangerine
        "C5E063", // chartreuse
        "F285E6", // pink
        "7FD8F5", // ice
    ]

    /// Map an absolute path → palette hex via DJB2-on-UTF8.
    ///
    /// DJB2 is chosen for deterministic, salt-free output (Swift's
    /// `Hasher` is salted across launches and unsuitable for
    /// stable-across-launches identity).
    public static func color(for absolutePath: String) -> String {
        let bytes = Array(absolutePath.utf8)
        var hash: UInt64 = 5381
        for b in bytes {
            hash = (hash &* 33) &+ UInt64(b)
        }
        let index = Int(hash % UInt64(entries.count))
        return entries[index]
    }
}
