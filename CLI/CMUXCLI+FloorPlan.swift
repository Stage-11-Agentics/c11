// C11-317: split out of CLI/c11.swift by scripts/split-cli.py.
import Foundation
import CryptoKit
import Darwin
import SQLite3
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

extension CMUXCLI {

    // MARK: - M8 Floor plan

    /// Resolve the canvas width based on `--canvas-cols` override and TTY size.
    /// - Returns: the chosen width in columns (clamped). Caller should suppress
    ///   the plan if the result is < 40.
    func resolveFloorPlanCanvasWidth(override: Int?) -> Int {
        if let n = override {
            return n
        }
        if isatty(fileno(stdout)) != 0 {
            var ws = winsize()
            if ioctl(fileno(stdout), UInt(TIOCGWINSZ), &ws) == 0 && ws.ws_col > 0 {
                let cols = Int(ws.ws_col)
                return max(40, min(cols, 160))
            }
        }
        return 80
    }

    /// Render the floor-plan section for one workspace, or nil when there is
    /// nothing to draw (no panes, no content area, or canvas too narrow).
    func renderFloorPlan(workspace: [String: Any], canvasWidth: Int, idFormat: CLIIDFormat) -> String? {
        let title = (workspace["title"] as? String) ?? ""
        let workspaceHandle = textHandle(workspace, idFormat: idFormat)

        guard canvasWidth >= 40 else {
            return [
                "workspace \(workspaceHandle)\(title.isEmpty ? "" : " \"\(title)\"")",
                "[layout suppressed: canvas <40 cols]"
            ].joined(separator: "\n")
        }

        guard let contentArea = workspace["content_area"] as? [String: Any],
              let pixels = contentArea["pixels"] as? [String: Any],
              let widthRaw = pixels["width"],
              let heightRaw = pixels["height"],
              let contentWidth = doubleValue(widthRaw),
              let contentHeight = doubleValue(heightRaw),
              contentWidth > 0, contentHeight > 0 else {
            return [
                "workspace \(workspaceHandle)\(title.isEmpty ? "" : " \"\(title)\"")  content: not laid out yet",
                "[workspace not laid out — focus it once to populate]"
            ].joined(separator: "\n")
        }

        let panes = workspace["areas"] as? [[String: Any]] ?? []
        guard !panes.isEmpty else { return nil }

        // Canvas height: round(width * (h/w) * 0.5), floor 6, ceiling 60.
        let rawRows = Double(canvasWidth) * (contentHeight / contentWidth) * 0.5
        let canvasHeight = max(6, min(60, Int(rawRows.rounded())))

        let header = "workspace \(workspaceHandle)\(title.isEmpty ? "" : " \"\(title)\"")  content: \(Int(contentWidth.rounded()))×\(Int(contentHeight.rounded())) px"

        // Build per-pane box rectangles in canvas coordinates.
        struct AreaBox {
            let pane: [String: Any]
            // Inclusive col0..col1, row0..row1 ranges in the canvas grid.
            // Border characters live ON these rows/cols (the box body sits inside).
            var col0: Int
            var col1: Int
            var row0: Int
            var row1: Int
        }

        var boxes: [AreaBox] = []
        for pane in panes {
            guard let layout = pane["layout"] as? [String: Any],
                  let percent = layout["percent"] as? [String: Any],
                  let hArr = percent["H"] as? [Any],
                  let vArr = percent["V"] as? [Any],
                  hArr.count == 2, vArr.count == 2,
                  let h0 = doubleValue(hArr[0]),
                  let h1 = doubleValue(hArr[1]),
                  let v0 = doubleValue(vArr[0]),
                  let v1 = doubleValue(vArr[1]) else {
                continue
            }
            // Skip degenerate panes per spec Open Question 5.
            guard h1 > h0, v1 > v0 else { continue }

            // Map percent → canvas grid. Use canvas width-1/height-1 to leave room for closing borders.
            let col0 = Int((Double(canvasWidth - 1) * h0).rounded())
            let col1 = Int((Double(canvasWidth - 1) * h1).rounded())
            let row0 = Int((Double(canvasHeight - 1) * v0).rounded())
            let row1 = Int((Double(canvasHeight - 1) * v1).rounded())
            boxes.append(AreaBox(pane: pane, col0: col0, col1: max(col0 + 1, col1), row0: row0, row1: max(row0 + 1, row1)))
        }

        guard !boxes.isEmpty else { return header }

        // Snap the rightmost/bottommost edges to canvas extents so borders close.
        let maxCol = boxes.map { $0.col1 }.max() ?? (canvasWidth - 1)
        let maxRow = boxes.map { $0.row1 }.max() ?? (canvasHeight - 1)
        for i in boxes.indices {
            if boxes[i].col1 == maxCol { boxes[i].col1 = canvasWidth - 1 }
            if boxes[i].row1 == maxRow { boxes[i].row1 = canvasHeight - 1 }
        }

        // Initialize empty canvas.
        var grid: [[Character]] = Array(
            repeating: Array(repeating: " ", count: canvasWidth),
            count: canvasHeight
        )

        // Draw each box's borders (overwriting safely; junctions get cleaned up below).
        for box in boxes {
            // Horizontal edges.
            for c in box.col0...box.col1 {
                if grid[box.row0][c] == " " { grid[box.row0][c] = "─" }
                if grid[box.row1][c] == " " { grid[box.row1][c] = "─" }
            }
            // Vertical edges.
            for r in box.row0...box.row1 {
                if grid[r][box.col0] == " " { grid[r][box.col0] = "│" }
                if grid[r][box.col1] == " " { grid[r][box.col1] = "│" }
            }
            // Corners (unconditionally — corners are the strongest signal).
            grid[box.row0][box.col0] = "┌"
            grid[box.row0][box.col1] = "┐"
            grid[box.row1][box.col0] = "└"
            grid[box.row1][box.col1] = "┘"
        }

        // Emit T-junctions where vertical/horizontal lines meet a non-corner edge.
        // Junction promotion: pick the strongest character based on the directional
        // signature implied by adjacent panes. Computed by checking neighbor cells.
        for r in 0..<canvasHeight {
            for c in 0..<canvasWidth {
                let ch = grid[r][c]
                if ch != "┌" && ch != "┐" && ch != "└" && ch != "┘" && ch != "─" && ch != "│" {
                    continue
                }
                let up = r > 0 && isBoxChar(grid[r - 1][c])
                let down = r < canvasHeight - 1 && isBoxChar(grid[r + 1][c])
                let left = c > 0 && isBoxChar(grid[r][c - 1])
                let right = c < canvasWidth - 1 && isBoxChar(grid[r][c + 1])
                grid[r][c] = chooseBoxChar(up: up, down: down, left: left, right: right, fallback: ch)
            }
        }

        // Render box bodies (text inside each pane).
        for box in boxes {
            renderBoxBody(
                col0: box.col0, col1: box.col1,
                row0: box.row0, row1: box.row1,
                pane: box.pane,
                grid: &grid,
                idFormat: idFormat
            )
        }

        let planLines = grid.map { String($0).trimmingTrailingWhitespace() }
        return ([header] + planLines).joined(separator: "\n")
    }

    func isBoxChar(_ ch: Character) -> Bool {
        switch ch {
        case "─", "│", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼":
            return true
        default:
            return false
        }
    }

    func chooseBoxChar(up: Bool, down: Bool, left: Bool, right: Bool, fallback: Character) -> Character {
        switch (up, down, left, right) {
        case (true,  true,  true,  true ): return "┼"
        case (true,  true,  true,  false): return "┤"
        case (true,  true,  false, true ): return "├"
        case (false, true,  true,  true ): return "┬"
        case (true,  false, true,  true ): return "┴"
        case (true,  true,  false, false): return "│"
        case (false, false, true,  true ): return "─"
        case (true,  false, false, true ): return "└"
        case (true,  false, true,  false): return "┘"
        case (false, true,  false, true ): return "┌"
        case (false, true,  true,  false): return "┐"
        default: return fallback
        }
    }

    func renderBoxBody(
        col0: Int, col1: Int, row0: Int, row1: Int,
        pane: [String: Any],
        grid: inout [[Character]],
        idFormat: CLIIDFormat
    ) {
        let bodyCols = max(0, col1 - col0 - 1)
        let bodyRows = max(0, row1 - row0 - 1)
        if bodyCols < 1 || bodyRows < 1 { return }

        let paneRef = textHandle(pane, idFormat: idFormat)
        // Surface info for selected tab title (line 5) and tab count (line 4).
        let surfaces = pane["panels"] as? [[String: Any]] ?? []
        let surfaceCount = (pane["panel_count"] as? Int) ?? surfaces.count
        let selectedTitle: String = {
            for s in surfaces {
                if (s["selected"] as? Bool) == true || (s["focused"] as? Bool) == true {
                    return (s["title"] as? String) ?? ""
                }
            }
            return (surfaces.first?["title"] as? String) ?? ""
        }()

        // Layout info for lines 2/3.
        let percentLine: String
        let pixelLine: String
        if let layout = pane["layout"] as? [String: Any],
           let pct = layout["percent"] as? [String: Any],
           let hArr = pct["H"] as? [Any],
           let vArr = pct["V"] as? [Any],
           hArr.count == 2, vArr.count == 2,
           let h0 = doubleValue(hArr[0]),
           let h1 = doubleValue(hArr[1]),
           let v0 = doubleValue(vArr[0]),
           let v1 = doubleValue(vArr[1]) {
            let widthPct = Int(((h1 - h0) * 100).rounded())
            let heightPct = Int(((v1 - v0) * 100).rounded())
            percentLine = "\(widthPct)%W × \(heightPct)%H"
            if let pix = layout["pixels"] as? [String: Any],
               let pixH = pix["H"] as? [Any], pixH.count == 2,
               let pixV = pix["V"] as? [Any], pixV.count == 2,
               let ph0 = doubleValue(pixH[0]), let ph1 = doubleValue(pixH[1]),
               let pv0 = doubleValue(pixV[0]), let pv1 = doubleValue(pixV[1]) {
                pixelLine = "\(Int(ph1 - ph0))×\(Int(pv1 - pv0)) px"
            } else {
                pixelLine = "? px"
            }
        } else {
            percentLine = "?% × ?%"
            pixelLine = "? px"
        }
        let panelLine = surfaceCount == 1 ? "1 panel" : "\(surfaceCount) panels"
        let titleLine = "* \(selectedTitle)"

        // Narrow-pane single-line collapse (per spec): inside-body width < 13 (so box width < 15).
        if bodyCols < 13 {
            // Collapsed: single-line "p:N W%W×H%H px×px N panels", truncated with "…".
            // Use "p:N" prefix (drop "pane:" prefix).
            let shortRef: String = {
                if let r = pane["ref"] as? String, let colon = r.firstIndex(of: ":") {
                    return "p:\(r[r.index(after: colon)...])"
                }
                return paneRef
            }()
            let summary = "\(shortRef) \(percentLine.replacingOccurrences(of: " × ", with: "×")) \(pixelLine) \(panelLine)"
                .replacingOccurrences(of: "%W×", with: "%W×")
            let row = row0 + 1
            if row >= grid.count { return }
            writeStringIntoRow(&grid, row: row, col: col0 + 1, maxCols: bodyCols, text: summary)
            return
        }

        // Standard 5-line body. Drop lines from the bottom if not enough rows.
        var lines: [String] = [paneRef, percentLine, pixelLine, panelLine, titleLine]
        if bodyRows < 5 {
            // Drop line 5 first, then 4, then 3.
            let toKeep = max(2, bodyRows)
            lines = Array(lines.prefix(toKeep))
        }

        // Truncate line 5 if title too wide. If even "*…" doesn't fit, drop it.
        if lines.count >= 5 {
            let maxTitle = bodyCols - 2  // "* " prefix
            if maxTitle < 2 {
                lines.removeLast()
            } else if selectedTitle.count > maxTitle {
                let cut = max(0, maxTitle - 1)
                let prefix = String(selectedTitle.prefix(cut))
                lines[4] = "* \(prefix)…"
            }
        }

        for (i, line) in lines.enumerated() {
            let row = row0 + 1 + i
            if row >= row1 { break }
            writeStringIntoRow(&grid, row: row, col: col0 + 1, maxCols: bodyCols, text: line)
        }
    }

    func writeStringIntoRow(_ grid: inout [[Character]], row: Int, col: Int, maxCols: Int, text: String) {
        if row < 0 || row >= grid.count { return }
        var write = text
        if write.count > maxCols {
            // Truncate with ellipsis if there's room, else hard-cut.
            if maxCols >= 1 {
                write = String(write.prefix(max(0, maxCols - 1))) + "…"
            } else {
                return
            }
        }
        var c = col
        for ch in write {
            if c >= grid[row].count { break }
            if c >= col + maxCols { break }
            grid[row][c] = ch
            c += 1
        }
    }

    func doubleValue(_ raw: Any) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String, let d = Double(s) { return d }
        return nil
    }
}
