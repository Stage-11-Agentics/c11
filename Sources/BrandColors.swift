import AppKit
import SwiftUI

/// Stage 11 brand palette resolved at runtime.
///
/// Values are canonical (from `company/brand/visual-aesthetic.md`) and are
/// the single source of truth for accent / chrome colors across c11.
///
/// API scope: internal to the c11 app target. Out-of-process verification
/// goes through the `system.brand` socket method (see module 5 spec).
enum BrandColors {
    static let blackHex      = "#000000"
    static let surfaceHex    = "#0a0a0a"
    static let ruleHex       = "#333333"
    static let dimHex        = "#555555"
    static let whiteHex      = "#e8e8e8"
    static let goldHex       = "#c9a84c"
    static let goldFaintHex  = "#c9a84c33"

    static let black: NSColor      = srgb(0x00, 0x00, 0x00)
    static let surface: NSColor    = srgb(0x0a, 0x0a, 0x0a)
    static let rule: NSColor       = srgb(0x33, 0x33, 0x33)
    static let dim: NSColor        = srgb(0x55, 0x55, 0x55)
    static let white: NSColor      = srgb(0xe8, 0xe8, 0xe8)
    static let gold: NSColor       = srgb(0xc9, 0xa8, 0x4c)
    static let goldFaint: NSColor  = srgb(0xc9, 0xa8, 0x4c, alpha: 0x33)

    static var blackSwiftUI: Color     { Color(nsColor: black) }
    static var surfaceSwiftUI: Color   { Color(nsColor: surface) }
    static var ruleSwiftUI: Color      { Color(nsColor: rule) }
    static var dimSwiftUI: Color       { Color(nsColor: dim) }
    static var whiteSwiftUI: Color     { Color(nsColor: white) }
    static var goldSwiftUI: Color      { Color(nsColor: gold) }
    static var goldFaintSwiftUI: Color { Color(nsColor: goldFaint) }

    private static func srgb(_ r: Int, _ g: Int, _ b: Int, alpha a: Int = 0xFF) -> NSColor {
        NSColor(
            srgbRed: CGFloat(r) / 255.0,
            green:   CGFloat(g) / 255.0,
            blue:    CGFloat(b) / 255.0,
            alpha:   CGFloat(a) / 255.0
        )
    }
}

extension BrandColors {
    /// Ordered palette tokens as emitted by `system.brand`.
    static let paletteHex: [(String, String)] = [
        ("black",      blackHex),
        ("surface",    surfaceHex),
        ("rule",       ruleHex),
        ("dim",        dimHex),
        ("white",      whiteHex),
        ("gold",       goldHex),
        ("gold_faint", goldFaintHex),
    ]

    /// Font family c11 ships with. Terminal content is owned by the
    /// user's Ghostty config; this is for chrome only.
    static let fontFamily = "JetBrains Mono"
}
