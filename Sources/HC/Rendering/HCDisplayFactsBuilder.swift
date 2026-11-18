import AppKit

/// Display facts hc answers terminal color queries from (OSC 10/11/12) and
/// uses for pixel reports (SPIKE-0B row 12; matrix T5.7).
///
/// Built on main from values main already owns, then handed down as a value.
/// The spike's `DispatchQueue.main.sync` from the control queue is gone.
enum HCDisplayFactsBuilder {
    /// sRGB bytes, rounding like the spike's `#rrggbb` (`viewers.rs` `rgb`).
    /// Colors in other spaces (P3, calibrated, catalog) are converted first;
    /// a color with no RGB form yields nil rather than a guess.
    static func rgb(_ color: NSColor) -> HCRGBColor? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt8 {
            UInt8(max(0, min(255, (v * 255).rounded())))
        }
        return HCRGBColor(red: byte(c.redComponent), green: byte(c.greenComponent), blue: byte(c.blueComponent))
    }

    static func facts(
        foreground: NSColor,
        background: NSColor,
        cursor: NSColor?,
        cellWidthPixels: UInt32,
        cellHeightPixels: UInt32
    ) -> HCDisplayFacts {
        let fg = rgb(foreground)
        func cell(_ v: UInt32) -> UInt16? { v > 0 && v <= UInt32(UInt16.max) ? UInt16(v) : nil }
        let width = cell(cellWidthPixels)
        let height = cell(cellHeightPixels)
        return HCDisplayFacts(
            foreground: fg,
            background: rgb(background),
            cursor: cursor.flatMap(rgb) ?? fg,
            cellWidth: width != nil && height != nil ? width : nil,
            cellHeight: width != nil && height != nil ? height : nil
        )
    }
}

/// One attachment's last display state, so a theme change that posts two
/// notifications (config reload, then default background) sends one FACTS,
/// and a resize with unchanged facts sends no FACTS at all.
struct HCDisplayStateTracker: Sendable {
    private(set) var last: HCDisplayState?
    private(set) var displayGeneration: UInt64 = 0

    /// Returns the state to send, or nil when nothing hc sees changed.
    mutating func next(
        attachmentGeneration: UInt64,
        grid: HCGridSize,
        facts: HCDisplayFacts,
        focused: Bool,
        force: Bool = false
    ) -> HCDisplayState? {
        if !force, let last, last.revision.attachmentGeneration == attachmentGeneration,
           last.grid == grid, last.facts == facts, last.focused == focused {
            return nil
        }
        displayGeneration &+= 1
        let state = HCDisplayState(
            revision: HCDisplayRevision(attachmentGeneration: attachmentGeneration, displayGeneration: displayGeneration),
            grid: grid,
            facts: facts,
            focused: focused
        )
        last = state
        return state
    }

    /// The same display, now known under the attachment's real generation
    /// (`HCPanelRendering`'s provisional attach state). Keeps its display
    /// generation: hc already has exactly this content.
    mutating func rekey(_ state: HCDisplayState, to attachmentGeneration: UInt64) -> HCDisplayState {
        let rekeyed = HCDisplayState(
            revision: HCDisplayRevision(
                attachmentGeneration: attachmentGeneration, displayGeneration: state.revision.displayGeneration
            ),
            grid: state.grid,
            facts: state.facts,
            focused: state.focused
        )
        last = rekeyed
        return rekeyed
    }
}
