import AppKit
import Combine
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
            let lowerName = lower[nameStart...].joined()
            if lowerName.hasPrefix(q.joined()) { score += 20 }
            // An exact name beats a longer name that merely starts with it.
            if lowerName == q.joined() { score += 10 }
            return RecentMatch(score: score, indices: idx)
        }

        // Contiguous substring anywhere in the path. The best occurrence wins:
        // one that ends at the end of the path (a suffix such as
        // `greenwood-tech/site`), then ones lined up with folder boundaries, so
        // a query with a slash in it does not tie across every path containing it.
        let needle = q
        if lower.count >= needle.count {
            var best: RecentMatch?
            for start in 0...(lower.count - needle.count) {
                var ok = true
                for k in 0..<needle.count where lower[start + k] != needle[k] { ok = false; break }
                guard ok else { continue }
                let end = start + needle.count
                var score = 5
                if end == chars.count { score += 10 }
                if start == 0 || chars[start - 1] == "/" { score += 5 }
                if end == chars.count || chars[end] == "/" { score += 3 }
                if best == nil || score > best!.score {
                    best = RecentMatch(score: score, indices: Array(start..<end))
                }
            }
            if let best { return best }
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

    /// Height of every section except the list, measured on the real window:
    /// 689 with two rows of pins (the most the grid ever shows), 595 with none
    /// or one row.
    static func fixedHeight(pinRows: Int) -> CGFloat {
        pinRows >= 2 ? 689 : 595
    }

    /// The list is always sized against the tallest state (two pin rows), so
    /// adding pins mid-use can never grow the window past the screen.
    static let budgetPinRows = 2

    private static func available(visibleHeight: CGFloat) -> CGFloat {
        visibleHeight - windowChrome - screenMargin
    }

    /// Rows for the list: as many as the screen leaves, 5 at least, 16 at most.
    static func listRows(visibleHeight: CGFloat) -> Int {
        let spare = available(visibleHeight: visibleHeight) - fixedHeight(pinRows: budgetPinRows)
        return max(minRows, min(maxRows, Int((spare / rowHeight).rounded(.down))))
    }

    /// True when even the minimum list overflows the screen: the sheet scrolls.
    static func needsScroll(visibleHeight: CGFloat) -> Bool {
        fixedHeight(pinRows: budgetPinRows) + CGFloat(minRows) * rowHeight > available(visibleHeight: visibleHeight)
    }

    static func maxContentHeight(visibleHeight: CGFloat) -> CGFloat {
        available(visibleHeight: visibleHeight)
    }

    /// Total window height for a list of `rows` and the given pin rows.
    static func windowHeight(rows: Int, pinRows: Int) -> CGFloat {
        windowChrome + fixedHeight(pinRows: pinRows) + CGFloat(rows) * rowHeight
    }

    /// Bottom-left y for a window of `height`, wanting its top at `desiredTop`,
    /// kept wholly inside `minY ... maxY`. The top edge is clamped as well as
    /// the bottom; a window taller than the span sits on its top edge.
    static func originY(desiredTop: CGFloat, height: CGFloat, minY: CGFloat, maxY: CGFloat) -> CGFloat {
        let y = desiredTop - height
        return min(max(y, minY), maxY - height)
    }
}

/// Live sizing for the picker: recomputed when the window changes screens.
final class CreateWorkspaceSizing: ObservableObject {
    @Published private(set) var listRows: Int
    /// Non-nil when even the minimum list does not fit: the sheet scrolls in
    /// this height.
    @Published private(set) var maxContentHeight: CGFloat?

    init(visibleHeight: CGFloat) {
        listRows = CreateWorkspaceSheetMetrics.listRows(visibleHeight: visibleHeight)
        maxContentHeight = CreateWorkspaceSheetMetrics.needsScroll(visibleHeight: visibleHeight)
            ? CreateWorkspaceSheetMetrics.maxContentHeight(visibleHeight: visibleHeight)
            : nil
    }

    func update(visibleHeight: CGFloat) {
        let rows = CreateWorkspaceSheetMetrics.listRows(visibleHeight: visibleHeight)
        let scroll = CreateWorkspaceSheetMetrics.needsScroll(visibleHeight: visibleHeight)
            ? CreateWorkspaceSheetMetrics.maxContentHeight(visibleHeight: visibleHeight)
            : nil
        if rows != listRows { listRows = rows }
        if scroll != maxContentHeight { maxContentHeight = scroll }
    }
}

// MARK: - Path mode (query starts with ~ or /)

/// When the query starts with `~` or `/` the search field stops filtering
/// recents and becomes a path: the first row creates in the typed path,
/// followed by the directories under it.
enum RecentsPathMode {
    static func isPathQuery(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.hasPrefix("~") || q.hasPrefix("/")
    }

    struct Resolution: Equatable {
        /// The typed path, normalized (`~` expanded, trailing slash gone).
        var typedPath: String
        /// The directory whose children are offered.
        var listDirectory: String
        /// Case-insensitive prefix a child name must have ("" lists all).
        var namePrefix: String
    }

    /// `~/Pro` lists the children of `~` starting with "Pro"; `~/Projects/`
    /// lists the children of `~/Projects`.
    static func resolve(query: String) -> Resolution {
        let q = query.trimmingCharacters(in: .whitespaces)
        let typed = RecentsPath.normalize(q)
        if q.hasSuffix("/") || q == "~" {
            return Resolution(typedPath: typed, listDirectory: typed, namePrefix: "")
        }
        let parent = RecentsPath.parent(typed)
        let list = parent.isEmpty ? "/" : parent
        return Resolution(typedPath: typed, listDirectory: list, namePrefix: RecentsPath.lastComponent(typed))
    }

    /// Immediate subdirectories of `directory` whose names start with
    /// `prefix`, sorted by name. Hidden folders appear only when the prefix
    /// starts with a dot. Blocking file I/O: call off the main thread.
    static func listChildren(of directory: String, prefix: String, limit: Int = 200) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        let showHidden = prefix.hasPrefix(".")
        let lowered = prefix.lowercased()
        var out: [String] = []
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            if !showHidden, name.hasPrefix(".") { continue }
            if !lowered.isEmpty, !name.lowercased().hasPrefix(lowered) { continue }
            var isDir: ObjCBool = false
            let full = (directory as NSString).appendingPathComponent(name)
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            out.append(full)
            if out.count >= limit { break }
        }
        return out
    }

    struct Row: Equatable {
        enum Kind: Equatable { case typed, child }
        var kind: Kind
        var path: String
        /// True when the path is also a recent (its history is shown).
        var isRecent: Bool
    }

    /// The typed path first, then filesystem children merged with known
    /// recents under the same directory, alphabetically, without duplicates.
    static func rows(
        resolution: Resolution,
        children: [String],
        recents: [RecentDirectory]
    ) -> [Row] {
        let recentSet = Set(recents.map(\.path))
        var rows = [Row(kind: .typed, path: resolution.typedPath, isRecent: recentSet.contains(resolution.typedPath))]
        var seen: Set<String> = [resolution.typedPath]
        let base = resolution.listDirectory == "/" ? "" : resolution.listDirectory
        let lowered = resolution.namePrefix.lowercased()
        var merged = children
        for r in recents {
            let p = r.path
            guard p.hasPrefix(base + "/"), p != resolution.listDirectory else { continue }
            let rest = p.dropFirst(base.count + 1)
            // Only direct children, or deeper recents whose first segment matches.
            let first = String(rest.split(separator: "/").first ?? "")
            guard !first.isEmpty, lowered.isEmpty || first.lowercased().hasPrefix(lowered) else { continue }
            merged.append(p)
        }
        for p in merged.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where seen.insert(p).inserted {
            rows.append(Row(kind: .child, path: p, isRecent: recentSet.contains(p)))
        }
        return rows
    }

    /// Text the field takes when Tab completes `path`: a `~/` query keeps its
    /// `~`, and the trailing slash lets the next Tab go one level deeper.
    static func completion(of path: String, forQuery query: String, home: String) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = q.hasPrefix("~") ? RecentsPath.displayPath(path, home: home) : path
        return shown.hasSuffix("/") ? shown : shown + "/"
    }
}

// MARK: - Query resolution for `c11 workspace new --dir`

/// Resolves a path-or-fuzzy-query with the same ranking as the picker.
enum RecentsQueryResolver {
    enum Outcome: Equatable {
        /// An explicit path (`~`, `/`, `.`, `..` prefix).
        case path(String)
        /// The single best recent.
        case match(String)
        /// The top two hits tie; the caller must fail and list these.
        case ambiguous([String])
        case none
    }

    /// `cwd/<query>` for a bare (not path-like) query, so a real subdirectory
    /// of the caller's directory can be preferred over a fuzzy guess. nil for
    /// `~`, `/` and `./`-style queries, which are already paths.
    static func cwdCandidate(query: String, cwd: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !q.hasPrefix("~"), !q.hasPrefix("/"), !q.hasPrefix("."), !cwd.isEmpty else { return nil }
        return RecentsPath.normalize((cwd as NSString).appendingPathComponent(q))
    }

    static func resolve(
        query: String,
        entries: [RecentDirectory],
        home: String,
        cwd: String
    ) -> Outcome {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .none }
        if q.hasPrefix("~") || q.hasPrefix("/") { return .path(RecentsPath.normalize(q)) }
        if q.hasPrefix("./") || q.hasPrefix("../") || q == "." || q == ".." {
            return .path(RecentsPath.normalize((cwd as NSString).appendingPathComponent(q)))
        }
        let hits = RecentsFuzzy.rank(query: q, entries: entries, home: home)
        guard let top = hits.first else { return .none }
        if hits.count > 1, hits[1].match.score == top.match.score {
            let tied = hits.prefix { $0.match.score == top.match.score }.map(\.entry.path)
            return .ambiguous(Array(tied.prefix(8)))
        }
        return .match(top.entry.path)
    }
}

// MARK: - Directory existence probe

/// Existence checks that cannot wedge the picker or the socket on a hung
/// network mount: a fixed-width pool (not a job per path), one job per path
/// however many callers ask, a per-check deadline, and no further checks under
/// a mount after one of its paths hangs. Use one instance per open of the
/// sheet (or per socket call), so the hang memory does not outlive its context.
final class DirectoryProbe {
    enum Result: Equatable {
        case exists
        case missing
        /// No answer within the deadline, or the path is under a mount that
        /// already hung. Neither "exists" nor "missing" is known.
        case timedOut
    }

    private struct Job {
        var waiters: [(queue: DispatchQueue, completion: (Result) -> Void)]
    }

    private let stat: (String) -> Bool
    private let pool: OperationQueue
    private let timers = DispatchQueue(label: "c11.directory-probe.timers", qos: .utility)
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var hungRoots: [String] = []

    init(
        width: Int = 4,
        stat: @escaping (String) -> Bool = { path in
            Workspace.isExistingDirectory((path as NSString).expandingTildeInPath)
        }
    ) {
        self.stat = stat
        pool = OperationQueue()
        pool.maxConcurrentOperationCount = max(1, width)
        pool.qualityOfService = .utility
    }

    /// The prefix to stop probing after `path` hangs: the mount root for
    /// `/Volumes/<name>/...` and `/net/...`-style mounts, else the parent.
    static func hangRoot(of path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "Volumes" { return "/Volumes/" + parts[1] }
        if parts.count >= 2, parts[0] == "net" || parts[0] == "mnt" { return "/" + parts[0] + "/" + parts[1] }
        let parent = RecentsPath.parent(path)
        return parent.isEmpty ? path : parent
    }

    func isUnderHungRoot(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hungRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// `completion` runs on `callbackQueue`. A path whose check is already
    /// running joins that check instead of starting another.
    func check(
        _ path: String,
        timeout: TimeInterval = 2,
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (Result) -> Void
    ) {
        lock.lock()
        if hungRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            lock.unlock()
            callbackQueue.async { completion(.timedOut) }
            return
        }
        if jobs[path] != nil {
            jobs[path]!.waiters.append((callbackQueue, completion))
            lock.unlock()
            return
        }
        jobs[path] = Job(waiters: [(callbackQueue, completion)])
        lock.unlock()

        pool.addOperation { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillWanted = self.jobs[path] != nil
            self.lock.unlock()
            // The deadline passed while this job waited for a slot: skip the stat.
            guard stillWanted else { return }
            let exists = self.stat(path)
            self.finish(path, exists ? .exists : .missing, hung: false)
        }
        timers.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(path, .timedOut, hung: true)
        }
    }

    private func finish(_ path: String, _ result: Result, hung: Bool) {
        lock.lock()
        guard let job = jobs.removeValue(forKey: path) else {
            lock.unlock()
            return
        }
        if hung {
            let root = Self.hangRoot(of: path)
            if !hungRoots.contains(root) { hungRoots.append(root) }
        }
        lock.unlock()
        for waiter in job.waiters {
            waiter.queue.async { waiter.completion(result) }
        }
    }

    /// Blocking convenience for callers on their own thread (the socket):
    /// definitive answers only; unanswered paths are absent.
    func statAll(_ paths: [String], deadline: TimeInterval = 2) -> [String: Bool] {
        let resultLock = NSLock()
        var results: [String: Bool] = [:]
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "c11.directory-probe.statall", qos: .userInitiated)
        for path in paths {
            group.enter()
            check(path, timeout: deadline, callbackQueue: queue) { result in
                resultLock.lock()
                if result == .exists { results[path] = true } else if result == .missing { results[path] = false }
                resultLock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + deadline + 1)
        resultLock.lock()
        defer { resultLock.unlock() }
        return results
    }
}

// MARK: - Picker key policy

/// Which keys belong to the picker window. Pure so the decisions are testable.
enum PickerShortcutPolicy {
    enum Action: Equatable {
        case pin(Int)
        case focusSearch
        case close
    }

    /// Modifier flags that mean something to a shortcut. Arrow keys carry
    /// `.numericPad` and `.function`, and caps lock is not a chord modifier, so
    /// those are dropped before any comparison.
    static func effectiveFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }

    /// The command chords the picker owns: cmd-1...9 (open a pin), cmd-F
    /// (focus search) and cmd-W (close the picker, never a pane of the window
    /// behind it).
    static func action(flags: NSEvent.ModifierFlags, chars: String) -> Action? {
        guard effectiveFlags(flags) == .command else { return nil }
        let c = chars.lowercased()
        if let digit = Int(c), (1...9).contains(digit) { return .pin(digit) }
        if c == "f" { return .focusSearch }
        if c == "w" { return .close }
        return nil
    }

    /// The app-level shortcut handler stands aside for exactly these keys when
    /// the picker window is the event's window.
    static func appShouldStandAside(flags: NSEvent.ModifierFlags, chars: String) -> Bool {
        action(flags: flags, chars: chars) != nil
    }

    /// -1 up, +1 down, for an unmodified (or shift-only) arrow key; nil otherwise.
    static func arrowDelta(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Int? {
        let f = effectiveFlags(flags)
        guard f.isEmpty || f == .shift else { return nil }
        switch keyCode {
        case 125: return +1
        case 126: return -1
        default: return nil
        }
    }

    /// Type-to-search: only plain (shift allowed) printable, non-space text.
    static func typeToSearchText(flags: NSEvent.ModifierFlags, characters: String?) -> String? {
        guard effectiveFlags(flags).subtracting(.shift).isEmpty,
              let typed = characters, !typed.isEmpty, typed != " ",
              typed.unicodeScalars.allSatisfy({ isPrintable($0) }) else { return nil }
        return typed
    }

    private static func isPrintable(_ s: Unicode.Scalar) -> Bool {
        if s.value < 0x20 || s.value == 0x7F { return false }
        if (0xF700...0xF8FF).contains(s.value) { return false }
        return true
    }
}
