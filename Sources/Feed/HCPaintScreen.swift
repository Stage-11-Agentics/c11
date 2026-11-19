import Foundation

/// hc's first paint, as stock hc 0.1.16 writes it (`viewers.rs` `first_paint`): CAN and Ghostty's reset prelude
/// (`ghostty-vt` `Terminal::paint`), the screen as Ghostty's VT formatter renders it, then hc's own win32-input
/// mode, `CSI ? 9001 h` or `l`, then its status reports and any half-received sequence of live output. Ghostty
/// has no mode 9001, so that mode closes the screen: a paint is judged only once it has arrived, after the exact
/// prelude. A paint cut short, a prelude that differs (another hc's format) or anything after the mode (status,
/// live output) never reaches the replay.
enum HCPaint {
    static let prelude = Data(("\u{18}\u{1B}[!p\u{1B}[?2026l\u{1B}[?9l\u{1B}[?1000l\u{1B}[?1001l\u{1B}[?1002l\u{1B}[?1003l"
        + "\u{1B}[?1004l\u{1B}[?1005l\u{1B}[?1006l\u{1B}[?1015l\u{1B}[?1016l\u{1B}[?2004l\u{1B}[?1l\u{1B}[?66l"
        + "\u{1B}[?2031l\u{1B}[?2048l\u{1B}[=0;1u\u{1B}[?1049l\u{1B}[?1047l\u{1B}[?47l\u{1B}[H\u{1B}[2J").utf8)
    static let ends = [Data("\u{1B}[?9001h".utf8), Data("\u{1B}[?9001l".utf8)]

    enum Section: Equatable {
        /// The screen: everything between the prelude and hc's mode.
        case screen(Data)
        /// The prelude so far, and no end yet: more may come.
        case unterminated
        /// Not hc 0.1.16's paint.
        case unrecognized
    }

    static func section(_ bytes: Data) -> Section {
        guard bytes.count >= prelude.count else {
            return prelude.starts(with: bytes) ? .unterminated : .unrecognized
        }
        guard bytes.starts(with: prelude) else { return .unrecognized }
        let body = bytes[(bytes.startIndex + prelude.count)...]
        let found = ends.compactMap { body.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        guard let end = found else { return .unterminated }
        return .screen(Data(body[..<end.lowerBound]))
    }
}

/// C11H-306: the screen of a terminal with no Ghostty surface, rebuilt from hc's paint (`HCPaint`).
///
/// The screen section is what Ghostty's VT formatter writes for the core's own screen: the modes that differ from
/// their defaults, the tab stops, every row's cells with their style as SGR (blank cells as spaces, rows ended by
/// CR LF), the scroll region, and last the cursor (a pending wrap restored by reprinting the cell at the right
/// edge), its pen, hyperlink, protection, keyboard flags and character sets. It is the paint a Ghostty surface gets
/// when the panel is shown. This replays it onto a grid cell for cell and cuts the two windows the native reader
/// takes (`ghostty/src/terminal/prompt_region.zig`), so the screen path's `PromptInputClassifier` reads a
/// headless panel's composer.
///
/// The replay accepts only that vocabulary (`ghostty/src/terminal/formatter.zig`, and Ghostty's mode table). Any
/// other sequence or mode, a row that would wrap or scroll, or a sequence cut off at the end leaves the screen
/// incomplete, which classifies as unknown: mail holds rather than guess. The paint ends every row with CR LF, so
/// no row carries a soft wrap, exactly as on a surface fed the same paint.
struct HCPaintScreen {
    struct Cell: Equatable {
        /// The cell's grapheme; empty for the spacer half of a wide character.
        var text: String
        var faint = false
        var italic = false
        /// Explicit truecolor only (SGR 38;2 / 48;2), as the native reader reports them.
        var fg: UInt32? = nil
        var bg: UInt32? = nil

        static let blank = Cell(text: " ")
    }

    private struct Pen: Equatable {
        var faint = false
        var italic = false
        var fg: UInt32? = nil
        var bg: UInt32? = nil
    }

    private enum Charset: Equatable { case ascii, other }

    private enum State {
        case ground
        case escape
        case charset(UInt8)
        case csi
        case osc
        case oscEscape
    }

    /// Ghostty's modes (`modes.zig`): the formatter emits only these. ANSI and DEC private. 1048 (save or restore
    /// the cursor) is left out: a cursor the replay cannot place holds.
    static let ansiModes: Set<Int> = [2, 4, 12, 20]
    static let decModes: Set<Int> = [1, 3, 4, 5, 6, 7, 8, 9, 12, 25, 40, 45, 47, 66, 67, 69, 1000, 1002, 1003, 1004,
                                     1005, 1006, 1007, 1015, 1016, 1035, 1036, 1039, 1045, 1047, 1049, 2004,
                                     2026, 2027, 2031, 2033, 2048, 5522]
    /// The OSCs the formatter writes: title, working directory, hyperlink.
    static let oscs: Set<Int> = [2, 7, 8]

    let columns: Int
    let rows: Int
    private(set) var cursorX = 0
    private(set) var cursorY = 0
    private(set) var pendingWrap = false
    /// Why the screen is not a faithful copy of hc's; nil while it is.
    private(set) var incompleteReason: String?

    private var main: [[Cell]]
    private var alternate: [[Cell]]
    private var onAlternate = false
    private var pen = Pen()
    private var autowrap = true
    private var originMode = false
    private var insertMode = false
    private var newlineMode = false
    private var synchronized = false
    private var scrollTop = 0
    private var scrollBottom: Int
    private var tabStops: Set<Int>
    private var charsets: [Charset] = [.ascii, .ascii, .ascii, .ascii]
    private var shift = 0

    private var state: State = .ground
    private var sequence: [UInt8] = []
    private var stringBytes = 0
    private var utf8: [UInt8] = []
    private var utf8Expected = 0

    /// Bounds a malformed stream: a parameter run or string longer than these is not hc's paint.
    static let maxSequenceBytes = 256
    static let maxStringBytes = 64 * 1024
    static let maxColumns = 1024
    static let maxRows = 512

    init?(columns: Int, rows: Int) {
        guard columns > 0, rows > 0, columns <= Self.maxColumns, rows <= Self.maxRows else { return nil }
        self.columns = columns
        self.rows = rows
        let blankGrid = Array(repeating: Array(repeating: Cell.blank, count: columns), count: rows)
        main = blankGrid
        alternate = blankGrid
        scrollBottom = rows - 1
        tabStops = Set(stride(from: 8, to: columns, by: 8))
    }

    /// The screen a paint draws. A paint that is not whole or not hc's (`HCPaint.section`) is an incomplete screen.
    /// Nil only for a grid size out of bounds.
    static func replay(_ paint: Data, columns: Int, rows: Int) -> HCPaintScreen? {
        guard var screen = HCPaintScreen(columns: columns, rows: rows) else { return nil }
        switch HCPaint.section(paint) {
        case .screen(let section):
            screen.feed(section)
            screen.finish()
        case .unterminated:
            screen.markIncomplete("unterminated")
        case .unrecognized:
            screen.markIncomplete("unrecognized")
        }
        return screen
    }

    var isComplete: Bool { incompleteReason == nil }

    /// One active-screen row, for tests and diagnostics.
    func cells(row: Int) -> [Cell] { activeGrid[row] }

    func text(row: Int) -> String { activeGrid[row].map(\.text).joined() }

    private var activeGrid: [[Cell]] { onAlternate ? alternate : main }

    // MARK: Feeding

    private mutating func feed(_ bytes: Data) {
        for byte in bytes {
            guard incompleteReason == nil else { return }
            consume(byte)
        }
    }

    /// The end of the screen section: a sequence or character cut off there, or a synchronized update left open,
    /// is not a screen to judge.
    private mutating func finish() {
        guard incompleteReason == nil else { return }
        if utf8Expected > 0 { markIncomplete("cut_character"); return }
        guard case .ground = state else { markIncomplete("cut_sequence"); return }
        if synchronized { markIncomplete("synchronized_update") }
    }

    private mutating func markIncomplete(_ why: String) {
        if incompleteReason == nil { incompleteReason = why }
    }

    private mutating func consume(_ byte: UInt8) {
        switch state {
        case .ground:
            ground(byte)
        case .escape:
            escape(byte)
        case .charset(let intermediate):
            state = .ground
            designate(intermediate, final: byte)
        case .csi:
            csiByte(byte)
        case .osc:
            if byte == 0x1B {
                state = .oscEscape
            } else if byte == 0x07 {
                endOSC()
            } else {
                sequence.append(byte)
                stringBytes += 1
                if stringBytes > Self.maxStringBytes { markIncomplete("string_too_long") }
            }
        case .oscEscape:
            if byte == 0x5C { endOSC() } else { markIncomplete("osc_unterminated") }
        }
    }

    private mutating func ground(_ byte: UInt8) {
        if utf8Expected > 0 {
            guard byte & 0xC0 == 0x80 else { markIncomplete("utf8"); return }
            utf8.append(byte)
            utf8Expected -= 1
            if utf8Expected == 0 {
                guard let scalar = String(bytes: utf8, encoding: .utf8)?.unicodeScalars.first else {
                    markIncomplete("utf8"); return
                }
                utf8.removeAll()
                printScalar(scalar)
            }
            return
        }
        switch byte {
        case 0x1B:
            state = .escape
        case 0x0D:
            pendingWrap = false
            cursorX = 0
        case 0x0A:
            lineFeed()
            if newlineMode { pendingWrap = false; cursorX = 0 }
        case 0x0E:
            shift = 1
        case 0x0F:
            shift = 0
        case 0x20..<0x7F:
            printScalar(Unicode.Scalar(byte))
        case 0xC2...0xDF:
            utf8 = [byte]; utf8Expected = 1
        case 0xE0...0xEF:
            utf8 = [byte]; utf8Expected = 2
        case 0xF0...0xF4:
            utf8 = [byte]; utf8Expected = 3
        default:
            markIncomplete(String(format: "control_x%02x", byte))
        }
    }

    private mutating func escape(_ byte: UInt8) {
        state = .ground
        switch byte {
        case UInt8(ascii: "["):
            state = .csi
            sequence.removeAll()
        case UInt8(ascii: "]"):
            state = .osc
            sequence.removeAll()
            stringBytes = 0
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"):
            state = .charset(byte)
        case UInt8(ascii: "H"):
            tabStops.insert(cursorX)
        default:
            markIncomplete("escape_\(Self.printable(byte))")
        }
    }

    /// The formatter's character-set designations (`ESC ( B` and kin); printing through anything but ASCII is not
    /// modelled.
    private mutating func designate(_ intermediate: UInt8, final: UInt8) {
        switch final {
        case UInt8(ascii: "B"):
            charsets[Int(intermediate - UInt8(ascii: "("))] = .ascii
        case UInt8(ascii: "A"), UInt8(ascii: "0"):
            charsets[Int(intermediate - UInt8(ascii: "("))] = .other
        default:
            markIncomplete("charset_\(Self.printable(final))")
        }
    }

    /// The title (2), the working directory (7) and a hyperlink (8) carry nothing for the cells.
    private mutating func endOSC() {
        state = .ground
        let digits = sequence.prefix { (0x30...0x39).contains($0) }
        guard let number = Int(String(decoding: digits, as: UTF8.self)), Self.oscs.contains(number),
              sequence.count == digits.count || sequence[digits.count] == UInt8(ascii: ";") else {
            markIncomplete("osc")
            return
        }
    }

    // MARK: CSI

    private mutating func csiByte(_ byte: UInt8) {
        switch byte {
        case 0x20...0x3F:
            sequence.append(byte)
            if sequence.count > Self.maxSequenceBytes { markIncomplete("sequence_too_long") }
        case 0x40...0x7E:
            state = .ground
            dispatchCSI(final: byte)
        default:
            markIncomplete("csi_control")
        }
    }

    private struct CSIParameters {
        var marker: UInt8?
        var intermediates: [UInt8] = []
        var groups: [[Int?]] = []

        func value(_ index: Int, default fallback: Int) -> Int {
            guard index < groups.count, let value = groups[index].first ?? nil else { return fallback }
            return value
        }

        /// The common VT reading: 0 or missing means 1.
        func count(_ index: Int) -> Int { max(1, value(index, default: 1)) }

        var modes: [Int?] { groups.map { $0.first ?? nil } }
    }

    private func parseParameters() -> CSIParameters? {
        var parameters = CSIParameters()
        var bytes = sequence[...]
        if let first = bytes.first, (0x3C...0x3F).contains(first) {
            parameters.marker = first
            bytes = bytes.dropFirst()
        }
        var group: [Int?] = []
        var current: Int?
        var sawAny = false
        for byte in bytes {
            switch byte {
            case 0x30...0x39:
                guard parameters.intermediates.isEmpty else { return nil }
                current = min((current ?? 0) * 10 + Int(byte - 0x30), 65_535)
                sawAny = true
            case 0x3A:
                guard parameters.intermediates.isEmpty else { return nil }
                group.append(current); current = nil; sawAny = true
            case 0x3B:
                guard parameters.intermediates.isEmpty else { return nil }
                group.append(current); parameters.groups.append(group)
                group = []; current = nil; sawAny = true
            case 0x20...0x2F:
                parameters.intermediates.append(byte)
            default:
                return nil
            }
        }
        if sawAny || !group.isEmpty || current != nil {
            group.append(current)
            parameters.groups.append(group)
        }
        return parameters
    }

    /// Only what Ghostty's formatter writes: CUP, CHA, TBC, DECSTBM, SGR and modes; `CSI > 4 ; 2 m`
    /// (modifyOtherKeys), `CSI = n ; 1 u` (kitty keyboard flags) and `CSI 1 " q` (protection). Anything else holds.
    private mutating func dispatchCSI(final: UInt8) {
        guard let p = parseParameters() else { markIncomplete("csi_parameters"); return }
        let finalChar = Character(Unicode.Scalar(final))
        let intermediates = String(decoding: p.intermediates, as: UTF8.self)
        let marker = p.marker.map { String(UnicodeScalar($0)) } ?? ""
        switch (marker, intermediates, finalChar) {
        case ("", "", "H"):
            setPosition(row: p.count(0) - 1, column: p.count(1) - 1)
        case ("", "", "G"):
            pendingWrap = false
            cursorX = min(max(p.count(0) - 1, 0), columns - 1)
        case ("", "", "g"):
            switch p.value(0, default: 0) {
            case 0: tabStops.remove(cursorX)
            case 3: tabStops.removeAll()
            default: markIncomplete("csi_g")
            }
        case ("", "", "r"):
            setScrollRegion(top: p.value(0, default: 1), bottom: p.value(1, default: rows))
        case ("", "", "m"):
            selectGraphicRendition(p)
        case ("", "", "h"), ("", "", "l"):
            setModes(p.modes, known: Self.ansiModes, on: finalChar == "h", ansi: true)
        case ("?", "", "h"), ("?", "", "l"):
            setModes(p.modes, known: Self.decModes, on: finalChar == "h", ansi: false)
        case (">", "", "m"), ("=", "", "u"), ("", "\"", "q"):
            break  // key modifiers, kitty keyboard flags, protection: no cell effect
        default:
            markIncomplete("csi_\(marker)\(intermediates)\(finalChar)")
        }
    }

    private mutating func setModes(_ modes: [Int?], known: Set<Int>, on: Bool, ansi: Bool) {
        for mode in modes {
            guard let mode, known.contains(mode) else { markIncomplete(ansi ? "mode" : "private_mode"); return }
            switch (ansi, mode) {
            case (true, 4): insertMode = on
            case (true, 20): newlineMode = on
            case (false, 6):
                originMode = on
                setPosition(row: 0, column: 0)
            case (false, 7):
                autowrap = on
                if !on { pendingWrap = false }
            case (false, 47), (false, 1047), (false, 1049):
                switchScreen(alternate: on)
            case (false, 69):
                if on { markIncomplete("left_right_margins") }
            case (false, 2026):
                synchronized = on
            default:
                break  // reporting, mouse, cursor style and the other modes do not change cells
            }
        }
    }

    // MARK: SGR

    private mutating func selectGraphicRendition(_ p: CSIParameters) {
        if p.groups.isEmpty { pen = Pen(); return }
        var index = 0
        while index < p.groups.count {
            let group = p.groups[index]
            let code = group.first.flatMap { $0 } ?? 0
            switch code {
            case 0: pen = Pen()
            case 2: pen.faint = true
            case 3: pen.italic = true
            case 22: pen.faint = false
            case 23: pen.italic = false
            case 30...37, 90...97: pen.fg = nil
            case 39: pen.fg = nil
            case 40...47, 100...107: pen.bg = nil
            case 49: pen.bg = nil
            case 38, 48, 58:
                let (color, consumed) = Self.extendedColor(p.groups, at: index)
                if code == 38 { pen.fg = color } else if code == 48 { pen.bg = color }
                index += consumed
                continue
            default:
                break  // bold, underline, blink, inverse, invisible, strike, overline: not composer signals
            }
            index += 1
        }
    }

    /// An extended color starting at `index` (38, 48 or 58): its truecolor (nil for a palette color) and how
    /// many parameter groups it used. Both the colon form (`38:2::r:g:b`, `38:2:r:g:b`) and the semicolon
    /// form (`38;2;r;g;b`, `38;5;n`) are read.
    private static func extendedColor(_ groups: [[Int?]], at index: Int) -> (UInt32?, Int) {
        let group = groups[index]
        if group.count > 1 {
            let sub = group.dropFirst().map { $0 ?? 0 }
            if sub.first == 2 {
                let rgb = Array(sub.dropFirst())
                let channels = rgb.count >= 4 ? Array(rgb.suffix(3)) : rgb
                guard channels.count == 3 else { return (nil, 1) }
                return (pack(channels[0], channels[1], channels[2]), 1)
            }
            return (nil, 1)
        }
        guard index + 1 < groups.count else { return (nil, 1) }
        switch groups[index + 1].first.flatMap({ $0 }) {
        case 2:
            guard index + 4 < groups.count else { return (nil, groups.count - index) }
            let r = groups[index + 2].first.flatMap { $0 } ?? 0
            let g = groups[index + 3].first.flatMap { $0 } ?? 0
            let b = groups[index + 4].first.flatMap { $0 } ?? 0
            return (pack(r, g, b), 5)
        case 5:
            return (nil, min(3, groups.count - index))
        default:
            return (nil, 2)
        }
    }

    private static func pack(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        (UInt32(min(max(r, 0), 255)) << 16) | (UInt32(min(max(g, 0), 255)) << 8) | UInt32(min(max(b, 0), 255))
    }

    // MARK: Printing

    private mutating func printScalar(_ scalar: Unicode.Scalar) {
        if charsets[shift] != .ascii, scalar.value >= 0x20, scalar.value < 0x7F {
            markIncomplete("charset")
            return
        }
        if (0x80...0x9F).contains(scalar.value) { markIncomplete("c1_control"); return }
        let width = HCCellWidth.of(scalar)
        if width == 0 {
            appendToPrevious(scalar)
            return
        }
        if pendingWrap {
            // A paint never needs one: its rows fit and end in CR LF. A wrap means the widths disagree.
            markIncomplete("autowrap")
            return
        }
        if width == 2 && cursorX == columns - 1 {
            markIncomplete("wide_at_edge")
            return
        }
        // The paint restores insert mode (IRM) before the screen's rows, so its rows print through it, as on a
        // surface: the cells from the cursor shift right by the character's width first.
        if insertMode { shiftCellsRight(width) }
        var cell = Cell(text: String(scalar), faint: pen.faint, italic: pen.italic, fg: pen.fg, bg: pen.bg)
        write(cell, x: cursorX, y: cursorY)
        if width == 2 {
            cell.text = ""
            write(cell, x: cursorX + 1, y: cursorY)
        }
        let next = cursorX + width
        if next >= columns {
            cursorX = columns - 1
            if autowrap { pendingWrap = true }
        } else {
            cursorX = next
        }
    }

    private mutating func appendToPrevious(_ scalar: Unicode.Scalar) {
        var x = pendingWrap ? cursorX : cursorX - 1
        guard x >= 0 else { return }
        if activeGrid[cursorY][x].text.isEmpty, x > 0 { x -= 1 }  // a wide character's spacer
        let y = cursorY, column = x
        modifyActive { grid in grid[y][column].text.unicodeScalars.append(scalar) }
    }

    private mutating func write(_ cell: Cell, x: Int, y: Int) {
        guard x >= 0, x < columns, y >= 0, y < rows else { return }
        let columns = self.columns
        modifyActive { grid in
            // Overwriting half of a wide character blanks its other half, as Ghostty does.
            if !cell.text.isEmpty, grid[y][x].text.isEmpty, x > 0 { grid[y][x - 1] = .blank }
            if HCCellWidth.isWide(grid[y][x].text), x + 1 < columns, grid[y][x + 1].text.isEmpty {
                grid[y][x + 1] = .blank
            }
            grid[y][x] = cell
        }
    }

    private mutating func shiftCellsRight(_ count: Int) {
        let y = cursorY
        let x = cursorX
        let columns = self.columns
        modifyActive { grid in
            var row = grid[y]
            let n = min(count, columns - x)
            row.removeLast(n)
            row.insert(contentsOf: Array(repeating: Cell.blank, count: n), at: x)
            grid[y] = row
        }
    }

    private mutating func modifyActive(_ body: (inout [[Cell]]) -> Void) {
        if onAlternate { body(&alternate) } else { body(&main) }
    }

    // MARK: Cursor

    /// Rows are separated by CR LF and the screen's rows all fit: a line feed past the last row would scroll,
    /// which a paint never does.
    private mutating func lineFeed() {
        pendingWrap = false
        guard cursorY < rows - 1 else { markIncomplete("scroll"); return }
        cursorY += 1
    }

    private mutating func setPosition(row: Int, column: Int) {
        pendingWrap = false
        let top = originMode ? scrollTop : 0
        let bottom = originMode ? scrollBottom : rows - 1
        cursorY = min(max(top + row, top), bottom)
        cursorX = min(max(column, 0), columns - 1)
    }

    private mutating func setScrollRegion(top: Int, bottom: Int) {
        let t = max(top, 1) - 1
        let b = min(bottom == 0 ? rows : bottom, rows) - 1
        guard t < b else { return }
        scrollTop = t
        scrollBottom = b
        setPosition(row: 0, column: 0)
    }

    private mutating func switchScreen(alternate on: Bool) {
        guard on != onAlternate else { return }
        onAlternate = on
        if on { alternate = Array(repeating: Array(repeating: Cell.blank, count: columns), count: rows) }
    }

    private static func printable(_ byte: UInt8) -> String {
        (0x21...0x7E).contains(byte) ? String(UnicodeScalar(byte)) : String(format: "x%02x", byte)
    }
}

// MARK: - The native reader's windows

extension HCPaintScreen {
    /// The native capture's limits (`prompt_region.zig`).
    static let windowRows = PromptInputClassifier.maxRows
    static let windowCells = PromptInputClassifier.maxCells
    static let windowTextBytes = PromptInputClassifier.maxTextBytes

    /// One window of the active screen, cut and budgeted exactly as `prompt_region.captureAt` does: the
    /// `.cursor` window holds up to 9 rows above and 6 below the cursor; the `.bottom` window the last 16 rows,
    /// read bottom up so a clipped row above the kept suffix is dropped rather than making the window
    /// incomplete. Each cell carries its grapheme (a blank as a space, a wide character's spacer as no text),
    /// faint, italic and explicit truecolor. Nil when the screen is not a faithful copy.
    func region(_ anchor: TerminalController.PromptRegionAnchor) -> PromptRegionSnapshot? {
        guard isComplete else { return nil }
        var complete = true
        var rowsOut: [PromptRegionRow] = []
        var cellsOut: [PromptRegionCell] = []
        var text = Data()
        let rowsBeforeCursor = Self.windowRows - 7
        let rowsAfterCursor = Self.windowRows - rowsBeforeCursor - 1
        let firstY: Int
        let lastY: Int
        switch anchor {
        case .cursor:
            firstY = cursorY - min(cursorY, rowsBeforeCursor)
            lastY = min(rows - 1, cursorY + rowsAfterCursor)
        case .bottom:
            firstY = rows - min(rows, Self.windowRows)
            lastY = rows - 1
        }
        let bottomUp = anchor == .bottom
        let order: [Int] = bottomUp ? Array(stride(from: lastY, through: firstY, by: -1)) : Array(firstY...lastY)
        let grid = activeGrid
        for y in order {
            if rowsOut.count >= Self.windowRows { complete = false; break }
            let rowStartText = text.count
            let rowStartComplete = complete
            var clipped = false
            var rowCells: [PromptRegionCell] = []
            for cell in grid[y] {
                if cellsOut.count + rowCells.count >= Self.windowCells { complete = false; clipped = true; break }
                let encoded = Data(cell.text.utf8)
                if text.count + encoded.count > Self.windowTextBytes { complete = false; clipped = true; break }
                let start = text.count
                text.append(encoded)
                rowCells.append(PromptRegionCell(textOffset: start, textLength: encoded.count, faint: cell.faint,
                                                 italic: cell.italic, fg: cell.fg, bg: cell.bg))
            }
            if clipped {
                if bottomUp, !rowsOut.isEmpty {
                    text.removeSubrange(rowStartText...)
                    complete = rowStartComplete
                } else {
                    complete = false
                }
                break
            }
            rowsOut.append(PromptRegionRow(screenY: y, cellRange: cellsOut.count..<(cellsOut.count + rowCells.count),
                                           softWrap: false, wrapContinuation: false))
            cellsOut.append(contentsOf: rowCells)
        }
        if bottomUp { rowsOut = Self.reorderBottomUp(rowsOut, cells: &cellsOut, text: &text) }
        // hc's paint carries no soft-wrap flags (C11H-320): the classifier must not trust their absence.
        return PromptRegionSnapshot(cursorX: cursorX, cursorY: cursorY, cursorPendingWrap: pendingWrap,
                                    complete: complete, rows: rowsOut, cells: cellsOut, text: text, wrapFlags: false)
    }

    /// The native reader reverses only its row records (cells and text stay in capture order). The classifier
    /// reads a row's cells by range and their text by offset, so both layouts read the same; this keeps cells in
    /// screen order for anything that walks them directly.
    private static func reorderBottomUp(_ rows: [PromptRegionRow], cells: inout [PromptRegionCell],
                                        text: inout Data) -> [PromptRegionRow] {
        let ordered = rows.reversed()
        var newCells: [PromptRegionCell] = []
        var newText = Data()
        var newRows: [PromptRegionRow] = []
        for row in ordered {
            let start = newCells.count
            for cell in cells[row.cellRange] {
                let bytes = text.subdata(in: cell.textOffset..<(cell.textOffset + cell.textLength))
                newCells.append(PromptRegionCell(textOffset: newText.count, textLength: bytes.count, faint: cell.faint,
                                                 italic: cell.italic, fg: cell.fg, bg: cell.bg))
                newText.append(bytes)
            }
            newRows.append(PromptRegionRow(screenY: row.screenY, cellRange: start..<newCells.count,
                                           softWrap: row.softWrap, wrapContinuation: row.wrapContinuation))
        }
        cells = newCells
        text = newText
        return newRows
    }

    /// The composer region the screen path would capture for this harness (cursor window, plus the bottom
    /// window when the screen path reads it), through the screen path's own choice of windows.
    func promptRegion(harness: String?) -> PromptRegionSnapshot? {
        TerminalController.capturePromptInputRegion(harness: harness, forSupervisor: false) { anchor in
            region(anchor)
        }
    }
}

// MARK: - Cell widths

/// How many cells a scalar takes, by Ghostty's rules for the characters a composer holds: East Asian wide and
/// fullwidth characters and emoji presentation take two; combining marks, variation selectors, joiners and
/// skin-tone modifiers join the previous cell. A disagreement with Ghostty on a rare scalar shows up as an
/// autowrap or a shifted row: the first fails the read closed, the second still reads typed text as a draft.
enum HCCellWidth {
    static func of(_ scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v < 0x300 { return 1 }
        if isZeroWidth(scalar) { return 0 }
        return isWideValue(v) ? 2 : 1
    }

    static func isWide(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return of(first) == 2
    }

    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v == 0x200B || v == 0x200C || v == 0x200D || v == 0x2060 || v == 0xFEFF { return true }
        if (0xFE00...0xFE0F).contains(v) || (0xE0100...0xE01EF).contains(v) { return true }
        if (0x1F3FB...0x1F3FF).contains(v) || (0xE0020...0xE007F).contains(v) { return true }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private static func isWideValue(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0, 0x23F3,
             0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F, 0x2693, 0x26A1, 0x26AA...0x26AB,
             0x26BD...0x26BE, 0x26C4...0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F2...0x26F3, 0x26F5, 0x26FA, 0x26FD,
             0x2705, 0x270A...0x270B, 0x2728, 0x274C, 0x274E, 0x2753...0x2755, 0x2757, 0x2795...0x2797, 0x27B0,
             0x27BF, 0x2B1B...0x2B1C, 0x2B50, 0x2B55, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x16FE0...0x16FE4, 0x17000...0x18CFF,
             0x1AFF0...0x1B2FF, 0x1F004, 0x1F0CF, 0x1F18E, 0x1F191...0x1F19A, 0x1F200...0x1F251,
             0x1F260...0x1F265, 0x1F300...0x1F320, 0x1F32D...0x1F335, 0x1F337...0x1F37C, 0x1F37E...0x1F393,
             0x1F3A0...0x1F3CA, 0x1F3CF...0x1F3D3, 0x1F3E0...0x1F3F0, 0x1F3F4, 0x1F3F8...0x1F43E, 0x1F440,
             0x1F442...0x1F4FC, 0x1F4FF...0x1F53D, 0x1F54B...0x1F54E, 0x1F550...0x1F567, 0x1F57A,
             0x1F595...0x1F596, 0x1F5A4, 0x1F5FB...0x1F64F, 0x1F680...0x1F6C5, 0x1F6CC, 0x1F6D0...0x1F6D2,
             0x1F6D5...0x1F6D7, 0x1F6DC...0x1F6DF, 0x1F6EB...0x1F6EC, 0x1F6F4...0x1F6FC, 0x1F7E0...0x1F7EB,
             0x1F7F0, 0x1F90C...0x1F93A, 0x1F93C...0x1F945, 0x1F947...0x1F9FF, 0x1FA70...0x1FAFF,
             0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
