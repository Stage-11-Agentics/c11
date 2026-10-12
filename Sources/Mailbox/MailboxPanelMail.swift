import Foundation

/// C11-397: what the subtitle bar's mailbox cell and drawer know about one
/// panel's mail, read from that panel's inbox alone.
///
/// A panel's inbox is `<mailboxes>/<panel-uuid-lowercased>/`. An envelope in
/// the inbox root is **unread**: no consumer (`recv --drain` or a hook drain)
/// has claimed it yet. The doorbell ring does not claim, so a rung envelope
/// stays unread until one of those does. A claim renames it into `_read/`,
/// so everything in both places is everything the panel has **received**.
/// Opening the drawer never claims anything; the counts describe the agent,
/// not the operator.
///
/// Pure file I/O, no app state, so `c11LogicTests` covers it directly.
enum MailboxPanelMail {

    /// How long a newly landed unread message keeps the cell's highlight.
    static let freshWindow: TimeInterval = 180

    /// The drawer lists at most this many messages, newest first.
    static let drawerLimit = 200

    /// Envelope files larger than this are not parsed for the drawer. The
    /// schema caps an inline body at 4 KiB, so a real envelope is far smaller.
    static let maxEnvelopeBytes = 64 * 1024

    /// A `body_ref` file is shown up to this many bytes, then marked truncated.
    static let maxReferencedBytes = 64 * 1024

    // MARK: - Counts

    struct Summary: Equatable {
        var unread: Int = 0
        var received: Int = 0
        /// Arrival time of the newest unread envelope, when there is one.
        var newestUnreadAt: Date?
        /// Arrival time of the oldest unread envelope, when there is one.
        var oldestUnreadAt: Date?

        static let empty = Summary()

        var hasMail: Bool { received > 0 }

        /// The newest unread message landed within `freshWindow` of `now`.
        func isFresh(now: Date) -> Bool {
            guard let newestUnreadAt else { return false }
            let age = now.timeIntervalSince(newestUnreadAt)
            return age >= -60 && age < MailboxPanelMail.freshWindow
        }

        /// When the highlight should go out, if it is on at `now`.
        func freshUntil(now: Date) -> Date? {
            guard isFresh(now: now), let newestUnreadAt else { return nil }
            return newestUnreadAt.addingTimeInterval(MailboxPanelMail.freshWindow)
        }
    }

    static func inboxURL(mailboxesRoot: URL, panelId: UUID) -> URL {
        mailboxesRoot.appendingPathComponent(panelId.uuidString.lowercased(), isDirectory: true)
    }

    /// Two directory listings and a stat per unread file; file contents are
    /// never read. An unread message landed when it was written into the inbox
    /// (its modification time) or, if the clock says otherwise, when it was
    /// sent (its ULID), whichever is later: mail that waited in the outbox
    /// still lights the cell when it finally lands.
    static func summary(inbox: URL, fileManager: FileManager = .default) -> Summary {
        let unread = envelopeFiles(in: inbox, fileManager: fileManager)
        let read = envelopeFiles(in: MailboxDrain.readURL(inbox: inbox), fileManager: fileManager)
        var result = Summary(unread: unread.count, received: unread.count + read.count)
        for file in unread {
            guard let date = landingDate(of: file, fileManager: fileManager) else { continue }
            if result.newestUnreadAt.map({ date > $0 }) ?? true { result.newestUnreadAt = date }
            if result.oldestUnreadAt.map({ date < $0 }) ?? true { result.oldestUnreadAt = date }
        }
        return result
    }

    static func envelopeFiles(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { $0.pathExtension == MailboxLayout.envelopeExtension }
    }

    /// When a message was sent: its ULID, or the file's modification time for
    /// a hand-dropped file whose name is not a ULID.
    static func arrivalDate(of file: URL, fileManager: FileManager = .default) -> Date? {
        if let date = ulidDate(file.deletingPathExtension().lastPathComponent) { return date }
        return modificationDate(of: file, fileManager: fileManager)
    }

    static func landingDate(of file: URL, fileManager: FileManager = .default) -> Date? {
        let sent = ulidDate(file.deletingPathExtension().lastPathComponent)
        let written = modificationDate(of: file, fileManager: fileManager)
        switch (sent, written) {
        case let (sent?, written?): return max(sent, written)
        default: return sent ?? written
        }
    }

    private static func modificationDate(of file: URL, fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// The millisecond timestamp in a ULID's first ten characters, or nil when
    /// `value` is not a ULID.
    static func ulidDate(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count == MailboxULID.totalLength else { return nil }
        var ms: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            guard let digit = ulidDigit(byte) else { return nil }
            if index < MailboxULID.timestampLength { ms = (ms << 5) | UInt64(digit) }
        }
        // The first character can only carry 3 bits of a 48-bit timestamp.
        guard ms <= 0x0000_FFFF_FFFF_FFFF else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    private static func ulidDigit(_ byte: UInt8) -> UInt8? {
        var upper = byte
        if upper >= 0x61, upper <= 0x7A { upper -= 0x20 }
        guard let index = MailboxULID.alphabet.firstIndex(of: upper) else { return nil }
        return UInt8(index)
    }

    /// A count as the cell shows it: `99+` above 99, so a slot never grows.
    static func countText(_ count: Int) -> String {
        count > 99 ? "99+" : String(max(0, count))
    }

    // MARK: - Messages

    /// One envelope as the drawer shows it. Every string is untrusted text from
    /// another agent; the view renders all of it verbatim.
    struct Message: Identifiable, Equatable {
        /// Unique within a listing: the same file name can sit in both the
        /// inbox root and `_read/` after a re-delivery.
        var id: String { (isUnread ? "unread/" : "read/") + fileId }
        /// The file name without extension: the envelope id for anything the
        /// dispatcher wrote, the claim ULID for a hand-dropped file.
        let fileId: String
        let isUnread: Bool
        let arrivedAt: Date?
        let from: String
        let to: String?
        let topic: String?
        let sentAt: Date?
        let sentAtText: String?
        let inReplyTo: String?
        let replyTo: String?
        let ttlSeconds: Int?
        let urgent: Bool
        let contentType: String?
        let body: String
        let reference: Reference?
        /// Set when the file could not be read or parsed as an envelope.
        let problem: String?

        /// The inline body and any referenced text, as "Copy text" copies it.
        var fullText: String {
            var pieces: [String] = []
            if !body.isEmpty { pieces.append(body) }
            if case .text(let text, _, _)? = reference?.content { pieces.append(text) }
            return pieces.joined(separator: "\n\n")
        }

        /// Long enough that the drawer folds it behind "Show all". Computed once
        /// when the listing loads, off the main thread.
        let isLong: Bool

        /// The TTL ran out before `now`, measured from when it was sent.
        func isExpired(now: Date) -> Bool {
            guard let ttlSeconds, ttlSeconds > 0, let start = sentAt ?? arrivedAt else { return false }
            return now.timeIntervalSince(start) > TimeInterval(ttlSeconds)
        }

        func expiresAt() -> Date? {
            guard let ttlSeconds, ttlSeconds > 0, let start = sentAt ?? arrivedAt else { return nil }
            return start.addingTimeInterval(TimeInterval(ttlSeconds))
        }
    }

    struct Reference: Equatable {
        enum Content: Equatable {
            case text(String, truncated: Bool, byteCount: Int)
            case missing
            case notAbsolute
            case notRegularFile
            case notText(byteCount: Int)
            case unreadable(String)
        }

        let path: String
        let content: Content
    }

    struct Listing: Equatable {
        var messages: [Message] = []
        /// Every envelope the panel has received, including any past the limit.
        var total: Int = 0
        var unread: Int = 0

        var hiddenCount: Int { max(0, total - messages.count) }
    }

    /// Newest first, at most `limit`. Reads each listed envelope, and each
    /// `body_ref` file, from disk; call it off the main thread.
    static func listing(
        inbox: URL,
        limit: Int = drawerLimit,
        fileManager: FileManager = .default
    ) -> Listing {
        let unread = envelopeFiles(in: inbox, fileManager: fileManager).map { ($0, true) }
        let read = envelopeFiles(in: MailboxDrain.readURL(inbox: inbox), fileManager: fileManager).map { ($0, false) }
        let all = (unread + read).map { entry -> (url: URL, unread: Bool, date: Date?) in
            (entry.0, entry.1, arrivalDate(of: entry.0, fileManager: fileManager))
        }
        let ordered = all.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.url.lastPathComponent > rhs.url.lastPathComponent
            }
        }
        let messages = ordered.prefix(max(0, limit)).map { entry in
            message(at: entry.url, isUnread: entry.unread, arrivedAt: entry.date, fileManager: fileManager)
        }
        return Listing(messages: Array(messages), total: all.count, unread: unread.count)
    }

    static let foldedLineLimit = 12
    static let foldedCharacterLimit = 1400

    static func isLong(_ text: String) -> Bool {
        var lines = 1
        var characters = 0
        for character in text {
            characters += 1
            if character.isNewline { lines += 1 }
            if lines > foldedLineLimit || characters > foldedCharacterLimit { return true }
        }
        return false
    }

    static func message(at url: URL, isUnread: Bool, arrivedAt: Date?, fileManager: FileManager = .default) -> Message {
        let id = url.deletingPathExtension().lastPathComponent
        func failed(_ problem: String) -> Message {
            Message(
                fileId: id, isUnread: isUnread, arrivedAt: arrivedAt, from: "", to: nil, topic: nil,
                sentAt: nil, sentAtText: nil, inReplyTo: nil, replyTo: nil, ttlSeconds: nil,
                urgent: false, contentType: nil, body: "", reference: nil, problem: problem, isLong: false
            )
        }
        let data: Data
        // An envelope is opened only as a regular file and never through a
        // symlink, so a FIFO dropped into an inbox cannot block the read.
        switch readRegularFilePrefix(path: url.path, limit: maxEnvelopeBytes, followSymlinks: false) {
        case .success(let read):
            guard !read.truncated else {
                return failed(String(
                    localized: "mailbox.drawer.problem.tooLarge",
                    defaultValue: "This envelope is too large to show."
                ))
            }
            data = read.data
        case .failure(let failure):
            return failed(failure.description)
        }
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return failed(String(
                localized: "mailbox.drawer.problem.notEnvelope",
                defaultValue: "This file is not a readable mailbox envelope."
            ))
        }
        func string(_ key: String) -> String? {
            guard let value = raw[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        let sentAtText = string("ts")
        let reference = string("body_ref").map { referencedContent(path: $0) }
        let body = raw["body"] as? String ?? ""
        var referencedText = ""
        if case .text(let text, _, _)? = reference?.content { referencedText = text }
        return Message(
            fileId: id,
            isUnread: isUnread,
            arrivedAt: arrivedAt,
            from: string("from") ?? "",
            to: string("to"),
            topic: string("topic"),
            sentAt: sentAtText.flatMap(parseTimestamp),
            sentAtText: sentAtText,
            inReplyTo: string("in_reply_to"),
            replyTo: string("reply_to"),
            ttlSeconds: (raw["ttl_seconds"] as? NSNumber)?.intValue,
            urgent: (raw["urgent"] as? Bool) ?? false,
            contentType: string("content_type"),
            body: body,
            reference: reference,
            problem: nil,
            isLong: isLong(body) || isLong(referencedText)
        )
    }

    static func parseTimestamp(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// Reads a `body_ref` target for display. The file is opened non-blocking
    /// and checked through the open descriptor, so a FIFO or device named by
    /// another agent (or swapped in after a check) can never block or stream;
    /// at most `maxReferencedBytes` are read.
    static func referencedContent(path: String) -> Reference {
        guard path.hasPrefix("/") else { return Reference(path: path, content: .notAbsolute) }
        switch readRegularFilePrefix(path: path, limit: maxReferencedBytes, followSymlinks: true) {
        case .failure(let failure):
            return Reference(path: path, content: failure.referenceContent)
        case .success(let read):
            guard let text = decodeText(read.data, truncated: read.truncated) else {
                return Reference(path: path, content: .notText(byteCount: read.size))
            }
            return Reference(path: path, content: .text(text, truncated: read.truncated, byteCount: read.size))
        }
    }

    /// UTF-8 text without NUL bytes. A truncated read may end mid-character, so
    /// up to three trailing bytes are dropped before giving up.
    static func decodeText(_ data: Data, truncated: Bool) -> String? {
        guard !data.contains(0) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        guard truncated else { return nil }
        for drop in 1...3 where data.count > drop {
            if let text = String(data: data.dropLast(drop), encoding: .utf8) { return text }
        }
        return nil
    }

    struct ReadFailure: Error {
        let description: String
        let referenceContent: Reference.Content
    }

    struct PrefixRead {
        let data: Data
        let truncated: Bool
        /// The file's size from the open descriptor.
        let size: Int
    }

    /// Opens `path` read-only and non-blocking, confirms through `fstat` on the
    /// open descriptor that it is a regular file, then reads at most
    /// `limit + 1` bytes. With `followSymlinks` false a symlink is refused.
    static func readRegularFilePrefix(path: String, limit: Int, followSymlinks: Bool) -> Result<PrefixRead, ReadFailure> {
        var flags = O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC
        if !followSymlinks { flags |= O_NOFOLLOW }
        let fd = open(path, flags)
        guard fd >= 0 else {
            let code = errno
            switch code {
            case ENOENT, ENOTDIR:
                return .failure(ReadFailure(
                    description: String(
                        localized: "mailbox.drawer.problem.gone",
                        defaultValue: "This message was moved before it could be read."
                    ),
                    referenceContent: .missing
                ))
            case ELOOP:
                return .failure(notRegular)
            case EACCES, EPERM:
                let reason = String(
                    localized: "mailbox.drawer.problem.permission",
                    defaultValue: "c11 does not have permission to read it."
                )
                return .failure(ReadFailure(description: reason, referenceContent: .unreadable(reason)))
            default:
                let reason = String(cString: strerror(code))
                return .failure(ReadFailure(description: reason, referenceContent: .unreadable(reason)))
            }
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let reason = String(cString: strerror(errno))
            return .failure(ReadFailure(description: reason, referenceContent: .unreadable(reason)))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .failure(notRegular) }
        let wanted = max(0, limit) + 1
        var buffer = [UInt8](repeating: 0, count: wanted)
        var filled = 0
        while filled < wanted {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress!.advanced(by: filled), wanted - filled)
            }
            if count < 0 {
                if errno == EINTR { continue }
                let reason = String(cString: strerror(errno))
                return .failure(ReadFailure(description: reason, referenceContent: .unreadable(reason)))
            }
            if count == 0 { break }
            filled += count
        }
        let data = Data(buffer[0..<min(filled, max(0, limit))])
        return .success(PrefixRead(data: data, truncated: filled > limit, size: Int(info.st_size)))
    }

    private static var notRegular: ReadFailure {
        ReadFailure(
            description: String(
                localized: "mailbox.drawer.problem.notRegular",
                defaultValue: "This entry is not a regular file, so c11 did not open it."
            ),
            referenceContent: .notRegularFile
        )
    }
}
