import AppKit
import Foundation

// Pure logic behind the New Workspace picker (C11-240): sort, fuzzy search,
// relative time, and the pin-tile text layout. No SwiftUI, no defaults, no
// filesystem, so it runs on the bare `c11-logic` runner.

// MARK: - Sort

enum RecentsOrdering {
    /// Sort keys shared by the sheet and the CLI listing.
    enum Key { case recent, opened }

    /// Pins keep their normal sorted position; nothing floats to the top.
    static func sorted(_ entries: [RecentDirectory], by key: Key) -> [RecentDirectory] {
        entries.enumerated().sorted { a, b in
            switch key {
            case .recent:
                if a.element.lastOpenedAt != b.element.lastOpenedAt {
                    return a.element.lastOpenedAt > b.element.lastOpenedAt
                }
            case .opened:
                if a.element.openCount != b.element.openCount {
                    return a.element.openCount > b.element.openCount
                }
                if a.element.lastOpenedAt != b.element.lastOpenedAt {
                    return a.element.lastOpenedAt > b.element.lastOpenedAt
                }
            }
            return a.offset < b.offset
        }.map(\.element)
    }
}

// MARK: - Relative time

enum RecentsRelativeTime {
    /// Compact "3h ago" style label. `justNow` is passed in so the localized
    /// string stays at the call site.
    static func label(since date: Date, now: Date = Date(), justNow: String) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return justNow }
        let m = Int(delta / 60)
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        let d = h / 24
        if d < 7 { return "\(d)d ago" }
        let w = d / 7
        if w < 5 { return "\(w)w ago" }
        return "\(d / 30)mo ago"
    }
}

// MARK: - Fuzzy search

struct RecentMatch: Equatable {
    var score: Int
    /// Character offsets into the display path that matched.
    var indices: [Int]
}

enum RecentsFuzzy {
    /// A subsequence inside the directory name scores highest (prefix and
    /// word-boundary bonuses). Elsewhere in the path only a contiguous
    /// substring counts: a loose subsequence over a whole path matches almost
    /// everything.
    static func match(query: String, displayPath: String) -> RecentMatch? {
        let q = query.lowercased().filter { !$0.isWhitespace }.map { String($0) }
        guard !q.isEmpty else { return RecentMatch(score: 0, indices: []) }
        let chars = Array(displayPath)
        let lower = chars.map { String($0).lowercased() }
        let name = RecentsPath.lastComponent(displayPath)
        let nameStart = max(0, chars.count - name.count)

        // Subsequence within the name.
        var idx: [Int] = []
        var j = 0
        var score = 0
        var prev = -2
        var i = nameStart
        while i < chars.count, j < q.count {
            if lower[i] == q[j] {
                idx.append(i)
                score += 1
                if i == prev + 1 { score += 3 }
                let local = i - nameStart
                if local == 0 || "/-_. ".contains(chars[i - 1]) { score += 4 }
                prev = i
                j += 1
            }
            i += 1
        }
        if j == q.count {
            score += 20
            if lower[nameStart...].joined().hasPrefix(q.joined()) { score += 20 }
            return RecentMatch(score: score, indices: idx)
        }

        // Contiguous substring anywhere in the path.
        let needle = q
        if lower.count >= needle.count {
            for start in 0...(lower.count - needle.count) {
                var ok = true
                for k in 0..<needle.count where lower[start + k] != needle[k] { ok = false; break }
                if ok {
                    return RecentMatch(score: 5, indices: Array(start..<(start + needle.count)))
                }
            }
        }
        return nil
    }

    struct Hit: Equatable {
        var entry: RecentDirectory
        var match: RecentMatch
    }

    /// Ranked hits for a query: score descending, ties by most recent open.
    static func rank(query: String, entries: [RecentDirectory], home: String) -> [Hit] {
        let hits: [(offset: Int, hit: Hit)] = entries.enumerated().compactMap { offset, entry in
            let display = RecentsPath.displayPath(entry.path, home: home)
            guard let m = match(query: query, displayPath: display) else { return nil }
            return (offset, Hit(entry: entry, match: m))
        }
        return hits.sorted { a, b in
            if a.hit.match.score != b.hit.match.score { return a.hit.match.score > b.hit.match.score }
            if a.hit.entry.lastOpenedAt != b.hit.entry.lastOpenedAt {
                return a.hit.entry.lastOpenedAt > b.hit.entry.lastOpenedAt
            }
            return a.offset < b.offset
        }.map(\.hit)
    }
}

// MARK: - Pin tile text layout

/// How a pin tile draws its directory name. SwiftUI's `lineLimit` plus
/// `minimumScaleFactor` breaks an over-long word between characters, so the
/// choice is made here, by measuring seam segments.
struct PinTileNameLayout: Equatable {
    /// One or two lines. A middle-ellipsized name is always a single line.
    var lines: [String]
    var fontSize: CGFloat
    var ellipsized: Bool

    static let baseFontSize: CGFloat = 14
    static let minFontSize: CGFloat = 11.5

    typealias Measure = (_ text: String, _ fontSize: CGFloat) -> CGFloat

    /// Widths as the tile draws it: semibold system font.
    static let defaultMeasure: Measure = { text, size in
        (text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
        ]).width
    }

    /// Split a name into pieces that may sit on separate lines. A seam is
    /// after `-`, `_` or `.`, at a lower-to-upper camelCase step, and at a
    /// letter-to-digit step.
    static func segments(of name: String) -> [String] {
        let chars = Array(name)
        guard !chars.isEmpty else { return [] }
        var out: [String] = []
        var cur = ""
        for (i, c) in chars.enumerated() {
            cur.append(c)
            guard i + 1 < chars.count else { break }
            let next = chars[i + 1]
            let seam = "-_.".contains(c)
                || (c.isLowercase && next.isUppercase)
                || (c.isLetter && next.isASCII && next.isNumber)
            if seam {
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func layout(name: String, width: CGFloat, measure: Measure = defaultMeasure) -> PinTileNameLayout {
        let segs = segments(of: name)
        guard !segs.isEmpty else {
            return PinTileNameLayout(lines: [name], fontSize: baseFontSize, ellipsized: false)
        }
        var size = baseFontSize
        while size >= minFontSize {
            if measure(name, size) <= width {
                return PinTileNameLayout(lines: [name], fontSize: size, ellipsized: false)
            }
            if segs.count > 1, segs.allSatisfy({ measure($0, size) <= width }) {
                // Best two-line split: both halves fit, the wider one as
                // narrow as possible.
                var best: (max: CGFloat, lines: [String])?
                for k in 1..<segs.count {
                    let a = segs[..<k].joined()
                    let b = segs[k...].joined()
                    let wa = measure(a, size), wb = measure(b, size)
                    guard wa <= width, wb <= width else { continue }
                    let widest = max(wa, wb)
                    if best == nil || widest < best!.max { best = (widest, [a, b]) }
                }
                if let best {
                    return PinTileNameLayout(lines: best.lines, fontSize: size, ellipsized: false)
                }
            }
            size -= 0.5
        }
        // One unbreakable piece is still too wide at the smallest size: one
        // line, middle ellipsis, keeping the start and the end.
        let full = Array(name)
        var keep = full.count - 1
        var text = name
        while keep > 4 {
            let head = (keep + 1) / 2
            let tail = keep / 2
            text = String(full[..<head]) + "…" + String(full[(full.count - tail)...])
            if measure(text, minFontSize) <= width { break }
            keep -= 1
        }
        return PinTileNameLayout(lines: [text], fontSize: minFontSize, ellipsized: true)
    }
}

enum PinTileParentLine {
    typealias Measure = (_ text: String, _ fontSize: CGFloat) -> CGFloat

    static let defaultMeasure: Measure = { text, size in
        (text as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
        ]).width
    }

    /// The last two folders of the parent, dropping to one ("…/greenwood-tech")
    /// before the view truncates the tail.
    static func fit(
        parentPath: String,
        width: CGFloat,
        fontSize: CGFloat = 10,
        measure: Measure = defaultMeasure
    ) -> String {
        let parts = parentPath.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return parentPath }
        let lead = parentPath.hasPrefix("/") ? "/" : ""
        var candidate = parentPath
        for k in stride(from: min(2, parts.count), through: 1, by: -1) {
            let tail = parts.suffix(k).joined(separator: "/")
            candidate = k < parts.count ? "…/" + tail : lead + tail
            if measure(candidate, fontSize) <= width { return candidate }
        }
        return candidate
    }
}

// MARK: - Pin grid shape

enum PinGridShape {
    static let perRow = 5

    /// Row-major: one row of up to five, then a second row; past two full rows
    /// the columns keep growing and the strip scrolls horizontally.
    static func columns(forPinCount n: Int) -> Int {
        guard n > 0 else { return 0 }
        return n <= perRow ? n : max(perRow, (n + 1) / 2)
    }

    static func rows(forPinCount n: Int) -> Int {
        n <= 0 ? 0 : (n <= perRow ? 1 : 2)
    }

    /// Pin paths split into rows (row-major fill).
    static func rowsOfPins(_ pins: [String]) -> [[String]] {
        let cols = columns(forPinCount: pins.count)
        guard cols > 0 else { return [] }
        var out: [[String]] = []
        var i = 0
        while i < pins.count {
            out.append(Array(pins[i..<min(pins.count, i + cols)]))
            i += cols
        }
        return out
    }
}

// MARK: - Sheet height budget

enum CreateWorkspaceSheetMetrics {
    static let rowHeight: CGFloat = 28
    static let minRows = 5
    static let maxRows = 16
    /// Title bar of the sheet's window.
    static let windowChrome: CGFloat = 28
    /// Breathing room kept between the window and the screen edges.
    static let screenMargin: CGFloat = 6

    /// Height of every section except the list, measured on the real window
    /// for none/one row of pins (595) and two rows (689). Zero pins is sized
    /// like one row so adding a first pin does not resize the window.
    static func fixedHeight(pinRows: Int) -> CGFloat {
        pinRows >= 2 ? 689 : 595
    }

    private static func available(visibleHeight: CGFloat) -> CGFloat {
        visibleHeight - windowChrome - screenMargin
    }

    /// Rows for the list: as many as the screen leaves, 5 at least, 16 at most.
    static func listRows(visibleHeight: CGFloat, pinRows: Int = 2) -> Int {
        let spare = available(visibleHeight: visibleHeight) - fixedHeight(pinRows: pinRows)
        return max(minRows, min(maxRows, Int((spare / rowHeight).rounded(.down))))
    }

    /// True when even the minimum list overflows the screen: the sheet scrolls.
    static func needsScroll(visibleHeight: CGFloat, pinRows: Int = 2) -> Bool {
        fixedHeight(pinRows: pinRows) + CGFloat(minRows) * rowHeight > available(visibleHeight: visibleHeight)
    }

    static func maxContentHeight(visibleHeight: CGFloat) -> CGFloat {
        available(visibleHeight: visibleHeight)
    }
}
