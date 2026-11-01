import Darwin
import Foundation

/// A projection of one root's C11.md, never persisted or used as workspace identity.
struct WorkspaceMission: Equatable, Hashable, Sendable {
    let path: String
    let summary: String
    let paragraph: String

    var tooltip: String { paragraph + "\n\n" + path }
}

enum WorkspaceMissionFile {
    static let byteLimit = 64 * 1024

    static func path(root: String?) -> String? {
        guard let root, root.hasPrefix("/"), !root.isEmpty else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("C11.md").path
    }

    /// Only call on a worker. Nonblocking open plus fstat rejects FIFOs/devices;
    /// a bounded descriptor read also handles a file that grows after the stat.
    static func read(root: String?) -> WorkspaceMission? {
        guard let path = path(root: root) else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= off_t(byteLimit) else { return nil }
        var bytes = [UInt8](repeating: 0, count: byteLimit + 1)
        var length = 0
        let succeeded = bytes.withUnsafeMutableBytes { buffer -> Bool in
            while length < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: length), buffer.count - length)
                if count < 0 && errno == EINTR { continue }
                if count < 0 { return false }
                if count == 0 { return true }
                length += count
            }
            return true
        }
        guard succeeded, length <= byteLimit,
              let text = String(bytes: bytes.prefix(length), encoding: .utf8),
              !text.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
              }),
              let paragraph = missionParagraph(text) else { return nil }
        var sentence = paragraph
        paragraph.enumerateSubstrings(in: paragraph.startIndex..<paragraph.endIndex, options: .bySentences) {
            substring, _, _, stop in
            if let substring { sentence = substring.trimmingCharacters(in: .whitespacesAndNewlines) }
            stop = true
        }
        return WorkspaceMission(path: path, summary: String(sentence.prefix(512)), paragraph: String(paragraph.prefix(2_000)))
    }

    /// First marked mission wins for the entire root. Workspace headings are
    /// notes, not selectors. With no marker, accept the first prose paragraph.
    static func missionParagraph(_ text: String) -> String? {
        let text = text.replacingOccurrences(of: "(?s)<!--.*?(?:-->|$)", with: "", options: .regularExpression)
        var fence: Character?
        var paragraph: [String] = []
        var fallback: String?
        var marked = false
        var pendingMission = false
        func joined() -> String? {
            let value = plainText(paragraph.joined(separator: " "))
            return value.isEmpty ? nil : value
        }
        for raw in text.components(separatedBy: .newlines) + [""] {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{feff}", with: "")
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if fence == line.first { fence = nil }
                else if fence == nil { fence = line.first }
                continue
            }
            if fence != nil { continue }
            let heading = line.range(of: "^#{1,6}\\s+", options: .regularExpression) != nil
            let label = line.range(of: "^(?:\\*\\*Mission[.:]?\\*\\*[:.]?|Mission:)\\s*", options: [.regularExpression, .caseInsensitive])
            if line.isEmpty || heading || label != nil {
                if let value = joined() {
                    if marked { return value }
                    if fallback == nil { fallback = value }
                }
                paragraph = []
                marked = false
            }
            if heading {
                pendingMission = line.range(of: "^#{1,6}\\s+Mission\\s*#*\\s*$", options: [.regularExpression, .caseInsensitive]) != nil
                continue
            }
            if line.isEmpty { continue }
            if let label {
                pendingMission = true
                let rest = String(line[label.upperBound...])
                if !rest.isEmpty { paragraph.append(rest); marked = true; pendingMission = false }
                continue
            }
            // A prose fallback must not be a separator, list, table or HTML tag.
            if paragraph.isEmpty && !pendingMission &&
                line.range(of: "^(?:[-*_]{3,}|[-*+]\\s|[0-9]+[.)]\\s|[|<])", options: .regularExpression) != nil {
                continue
            }
            if paragraph.isEmpty { marked = pendingMission; pendingMission = false }
            paragraph.append(line)
        }
        return fallback
    }

    private static func plainText(_ text: String) -> String {
        let text = text.replacingOccurrences(of: "!?\\[([^]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        return text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Shares one low-frequency stat/read per root. No timer or filesystem work
/// lives in WorkspaceRowView, and unchanged bytes produce no main publication.
final class WorkspaceMissionMonitor: @unchecked Sendable {
    static let shared = WorkspaceMissionMonitor()
    typealias Receiver = @MainActor @Sendable (WorkspaceMission?) -> Void

    final class Subscription: @unchecked Sendable {
        private let cancel: @Sendable () -> Void
        init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
        deinit { cancel() }
    }

    private struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        init?(_ root: String) {
            guard let path = WorkspaceMissionFile.path(root: root) else { return nil }
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            device = info.st_dev; inode = info.st_ino; mode = info.st_mode; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    private struct Entry {
        var receivers: [UUID: Receiver] = [:]
        var stamp: Stamp?
        var value: WorkspaceMission?
        var loaded = false
    }

    private let queue = DispatchQueue(label: "c11.workspace-mission", qos: .utility)
    private let interval: TimeInterval
    private let reader: @Sendable (String) -> WorkspaceMission?
    private var entries: [String: Entry] = [:]
    private var timer: DispatchSourceTimer?

    init(interval: TimeInterval = 2, reader: @escaping @Sendable (String) -> WorkspaceMission? = { WorkspaceMissionFile.read(root: $0) }) {
        self.interval = interval
        self.reader = reader
    }

    func observe(root: String, receive: @escaping Receiver) -> Subscription {
        let id = UUID()
        queue.async {
            var entry = self.entries[root] ?? Entry()
            entry.receivers[id] = receive
            self.entries[root] = entry
            if entry.loaded {
                let value = entry.value
                DispatchQueue.main.async { receive(value) }
            }
            self.poll(root: root)
            if self.timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + self.interval, repeating: self.interval)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    for root in Array(self.entries.keys) { self.poll(root: root) }
                }
                self.timer = timer
                timer.resume()
            }
        }
        return Subscription { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.entries[root]?.receivers.removeValue(forKey: id)
                if self.entries[root]?.receivers.isEmpty == true { self.entries.removeValue(forKey: root) }
                if self.entries.isEmpty { self.timer?.cancel(); self.timer = nil }
            }
        }
    }

    private func poll(root: String) {
        guard var entry = entries[root] else { return }
        let stamp = Stamp(root)
        guard !entry.loaded || stamp != entry.stamp else { return }
        let value = reader(root)
        let changed = !entry.loaded || value != entry.value
        entry.stamp = stamp; entry.value = value; entry.loaded = true
        entries[root] = entry
        if changed {
            for receive in entry.receivers.values { DispatchQueue.main.async { receive(value) } }
        }
    }
}

/// Binds asynchronous reads to one workspace root. An old read cannot paint
/// a newly assigned root, even if the operator switches away and back quickly.
@MainActor
final class WorkspaceMissionBinding {
    private let monitor: WorkspaceMissionMonitor
    private let receive: WorkspaceMissionMonitor.Receiver
    private var subscription: WorkspaceMissionMonitor.Subscription?
    private var root: String?
    private var observationID = UUID()

    init(monitor: WorkspaceMissionMonitor = .shared, receive: @escaping WorkspaceMissionMonitor.Receiver) {
        self.monitor = monitor
        self.receive = receive
    }

    func setRoot(_ root: String?) {
        guard self.root != root else { return }
        self.root = root
        let id = UUID()
        observationID = id
        subscription = nil
        receive(nil)
        guard let root else { return }
        subscription = monitor.observe(root: root) { [weak self] value in
            guard let self, self.observationID == id else { return }
            self.receive(value)
        }
    }
}

/// Only a path is carried into the harness, through the environment. Mission
/// content stays in the operator-owned file, and the launch prompt is never
/// touched: a launch with no task stays a plain session.
struct WorkspaceMissionLaunchContext: Sendable {
    static let environmentKey = "C11_MISSION_FILE"
    let mission: WorkspaceMission?

    /// Apply after shell startup too, including an existing panel. An empty
    /// value clears inherited context without guessing from the panel's cwd.
    func command(_ command: String) -> String {
        "export \(Self.environmentKey)=\(DefaultAgentResolver.shellQuote(mission?.path ?? "")); " + command
    }

    func environment(_ original: [String: String]) -> [String: String] {
        var env = original
        env[Self.environmentKey] = mission?.path ?? ""
        return env
    }
}
