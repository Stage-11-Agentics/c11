import AppKit

/// `TerminalSurface` as ticket 5's rendering host. Reads only; the one action
/// is c11's existing `forceRefresh`, called as is.
extension TerminalSurface: HCRenderingHost {
    func renderingSurfaceGrid() -> (grid: HCGridSize, cellWidth: UInt32, cellHeight: UInt32)? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return nil }
        return (HCGridSize(columns: size.columns, rows: size.rows), size.cell_width_px, size.cell_height_px)
    }

    func renderingThemeColors() -> (foreground: NSColor, background: NSColor, cursor: NSColor?) {
        let app = GhosttyApp.shared
        var cursor: NSColor?
        if let config = app.config {
            var color = ghostty_config_color_s()
            let key = "cursor-color"
            if ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) {
                cursor = NSColor(
                    red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1
                )
            }
        }
        return (app.defaultForegroundColor, app.defaultBackgroundColor, cursor)
    }

    var renderingIsVisible: Bool { uiWindow != nil }

    func renderingForceRefresh(reason: String) {
        forceRefresh(reason: reason)
    }
}
