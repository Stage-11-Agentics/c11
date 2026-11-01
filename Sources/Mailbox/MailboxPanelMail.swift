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
        /// The panel has a `_sent/` ledger (C11-399): it sent something the
        /// dispatcher could attribute, so its Sent view has content even with
        /// nothing received. One directory stat, no listing.
        var hasSent = false

        static let empty = Summary()

        /// The mailbox cell shows once the panel has received or sent mail.
        var hasMail: Bool { received > 0 || hasSent }

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

    /// Two directory listings, a stat of `_sent/` and a stat per unread file; file contents are
    /// never read. An unread message landed when it was written into the inbox
    /// (its modification time) or, if the clock says otherwise, when it was
    /// sent (its ULID), whichever is later: mail that waited in the outbox
    /// still lights the cell when it finally lands.
    static func summary(inbox: URL, fileManager: FileManager = .default) -> Summary {
        let unread = envelopeFiles(in: inbox, fileManager: fileManager)
        let read = envelopeFiles(in: MailboxDrain.readURL(inbox: inbox), fileManager: fileManager)
        var result = Summary(unread: unread.count, received: unread.count + read.count)
        var isDirectory: ObjCBool = false
        result.hasSent = fileManager.fileExists(atPath: MailboxSentLedger.directory(inbox: inbox).path, isDirectory: &isDirectory)
            && isDirectory.boolValue
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

    /// The widest count the cell shows, in characters. Every slot is sized
    /// for it, so a count changing never moves the bar.
    static let countSlotCharacters = 5

    /// A count as the cell shows it: exact through 99999, then whole
    /// thousands (`123k`) or millions (`12M`), never wider than the slot.
    static func countText(_ count: Int) -> String {
        let count = max(0, count)
        if count <= 99_999 { return String(count) }
        if count <= 999_999 { return "\(count / 1000)k" }
        return "\(min(count / 1_000_000, 9999))M"
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
        /// Trailing newlines and spaces go (a `body_ref` file nearly always
        /// ends in one), so a paste into a shell does not end in Return;
        /// inner newlines stay.
        var fullText: String {
            var pieces: [String] = []
            if !body.isEmpty { pieces.append(body) }
            if case .text(let text, _, _)? = reference?.content { pieces.append(text) }
            var text = pieces.joined(separator: "\n\n")
            while let last = text.last, last.isWhitespace { text.removeLast() }
            return text
        }

        /// Long enough that the drawer folds it behind "Show all". Computed once
        /// when the listing loads, off the main thread.
        let isLong: Bool

        /// The panel the dispatcher stamped as sender (C11-399); nil on mail sent
        /// before the stamp existed or from a sender it could not pin down.
        var senderPanelId: UUID? = nil

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

    // MARK: - Sent (C11-399)

    /// Where one recipient's copy of a sent message stands right now.
    enum SentState: Equatable {
        /// In the recipient's inbox root: its agent has not taken it.
        case unread
        /// In the recipient's `_read/`: its agent has taken it.
        case read
        /// In neither: swept, expired or the panel's mailbox is gone.
        case gone
    }

    struct SentRecipient: Equatable {
        let panelId: UUID?
        let name: String
        let state: SentState
    }

    /// One message the panel sent, as the Sent view shows it.
    struct SentMessage: Identifiable, Equatable {
        var id: String { entryId }
        let entryId: String
        let sentAt: Date?
        let to: String?
        let topic: String?
        let recipients: [SentRecipient]
        /// The first recipient copy still on disk, for the body. Nil when every
        /// copy is gone.
        let message: Message?
    }

    struct SentListing: Equatable {
        var messages: [SentMessage] = []
        /// Every entry the panel has, including any past the limit.
        var total: Int = 0

        var hiddenCount: Int { max(0, total - messages.count) }
    }

    /// Newest first, at most `limit`: one listing of the sender's `_sent/`, then
    /// two stats per recipient and one envelope read per message. No other
    /// panel's directory is listed. Only recipient panels the sender's own
    /// entries name are looked at, so the view cannot reach mail the sender
    /// did not send. Call it off the main thread.
    static func sentListing(
        senderInbox: URL,
        mailboxesRoot: URL,
        limit: Int = drawerLimit,
        fileManager: FileManager = .default
    ) -> SentListing {
        let (entries, total) = MailboxSentLedger.entries(senderInbox: senderInbox, limit: limit, fileManager: fileManager)
        // The sender's own panel id, from its directory name: a recipient copy
        // counts as this panel's only if the dispatcher stamped it with that id.
        let sender = UUID(uuidString: senderInbox.lastPathComponent)
        let messages = entries.map { entry -> SentMessage in
            var firstCopy: Message?
            let recipients = entry.recipients.map { recipient -> SentRecipient in
                guard let panel = UUID(uuidString: recipient.panel) else {
                    return SentRecipient(panelId: nil, name: recipient.name, state: .gone)
                }
                let inbox = inboxURL(mailboxesRoot: mailboxesRoot, panelId: panel)
                let file = MailboxLayout.envelopeFilename(id: entry.id)
                let unreadURL = inbox.appendingPathComponent(file)
                let readURL = MailboxDrain.readURL(inbox: inbox).appendingPathComponent(file)
                let state: SentState
                let copy: URL?
                if fileManager.fileExists(atPath: unreadURL.path) {
                    state = .unread; copy = unreadURL
                } else if fileManager.fileExists(atPath: readURL.path) {
                    state = .read; copy = readURL
                } else {
                    state = .gone; copy = nil
                }
                // A copy this panel did not send is not shown, whatever the entry
                // says, and its `body_ref` is not followed.
                guard let copy, let sender, stampedSender(of: copy) == sender else {
                    return SentRecipient(panelId: panel, name: recipient.name, state: .gone)
                }
                if firstCopy == nil {
                    firstCopy = message(at: copy, isUnread: state == .unread, arrivedAt: arrivalDate(of: copy, fileManager: fileManager), fileManager: fileManager)
                }
                return SentRecipient(panelId: panel, name: recipient.name, state: state)
            }
            return SentMessage(
                entryId: entry.id,
                sentAt: entry.ts.flatMap(parseTimestamp) ?? ulidDate(entry.id),
                to: entry.to,
                topic: entry.topic,
                recipients: recipients,
                message: firstCopy
            )
        }
        return SentListing(messages: messages, total: total)
    }

    /// The sender stamp in an envelope file, read without following `body_ref`.
    static func stampedSender(of file: URL) -> UUID? {
        guard case .success(let read) = readRegularFilePrefix(path: file.path, limit: maxEnvelopeBytes, followSymlinks: false),
              !read.truncated,
              let raw = (try? JSONSerialization.jsonObject(with: read.data)) as? [String: Any] else { return nil }
        return ((raw["ext"] as? [String: Any])?[MailboxEnvelope.senderPanelKey] as? String)
            .flatMap(UUID.init(uuidString:))
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
            isLong: isLong(body) || isLong(referencedText),
            senderPanelId: ((raw["ext"] as? [String: Any])?[MailboxEnvelope.senderPanelKey] as? String)
                .flatMap(UUID.init(uuidString:))
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
        let byteLimit = max(0, limit)
        let (wanted, overflow) = byteLimit.addingReportingOverflow(1)
        guard !overflow else {
            let reason = "read limit is too large"
            return .failure(ReadFailure(description: reason, referenceContent: .unreadable(reason)))
        }
        let fileSize = max(off_t(0), info.st_size)
        let initialCapacity = fileSize >= off_t(wanted) ? wanted : Int(fileSize) + 1
        var buffer = Data(count: initialCapacity)
        var filled = 0
        while true {
            if filled == buffer.count {
                guard buffer.count < wanted else { break }
                // The file grew after fstat. Expand only on that uncommon path;
                // ordinary small envelopes allocate only their actual size.
                var expanded = Data(count: wanted)
                if filled > 0 {
                    buffer.withUnsafeBytes { source in
                        expanded.withUnsafeMutableBytes { destination in
                            destination.baseAddress!.copyMemory(
                                from: source.baseAddress!,
                                byteCount: filled
                            )
                        }
                    }
                }
                buffer = expanded
            }
            let remaining = buffer.count - filled
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress!.advanced(by: filled), remaining)
            }
            if count < 0 {
                if errno == EINTR { continue }
                let reason = String(cString: strerror(errno))
                return .failure(ReadFailure(description: reason, referenceContent: .unreadable(reason)))
            }
            if count == 0 { break }
            filled += count
        }
        let truncated = filled > byteLimit
        let byteCount = min(filled, byteLimit)
        if byteCount < buffer.count {
            buffer.removeSubrange(byteCount..<buffer.endIndex)
        }
        return .success(PrefixRead(data: buffer, truncated: truncated, size: Int(info.st_size)))
    }

    /// Opens a regular file without blocking, seeks to its last `limit` bytes,
    /// and reads no more than that many bytes. If the read starts mid-file,
    /// the first partial line is discarded before the bytes are returned.
    static func readRegularFileTail(path: String, limit: Int, followSymlinks: Bool) -> Result<Data, ReadFailure> {
        guard limit > 0 else {
            let reason = "read limit must be positive"
            return .failure(ReadFailure(description: reason, referenceContent: .unreadable(reason)))
        }

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

        let (readLimit, overflow) = limit.addingReportingOverflow(1)
        guard !overflow else {
            let reason = "read limit is too large"
            return .failure(ReadFailure(description: reason, referenceContent: .unreadable(reason)))
        }
        let startOffset = max(0, info.st_size - off_t(limit))
        let readOffset = startOffset > 0 ? startOffset - 1 : 0
        guard lseek(fd, readOffset, SEEK_SET) >= 0 else {
            let reason = String(cString: strerror(errno))
            return .failure(ReadFailure(description: reason, referenceContent: .unreadable(reason)))
        }

        let available = max(off_t(0), info.st_size - readOffset)
        let capacity = Int(min(available, off_t(readLimit)))
        var buffer = Data(count: capacity)
        var filled = 0
        while filled < capacity {
            let remaining = capacity - filled
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress!.advanced(by: filled), remaining)
            }
            if count < 0 {
                if errno == EINTR { continue }
                let reason = String(cString: strerror(errno))
                return .failure(ReadFailure(description: reason, referenceContent: .unreadable(reason)))
            }
            if count == 0 { break }
            filled += count
        }

        var resultStart = 0
        if startOffset > 0 {
            guard let newline = buffer[..<filled].firstIndex(of: 0x0A) else { return .success(Data()) }
            resultStart = buffer.index(after: newline)
        }
        return .success(Data(buffer[resultStart..<filled]))
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

// MARK: - Insights

extension MailboxPanelMail {

    /// The insights scan parses at most this many envelopes, newest first.
    /// Counts and activity come from file names and cover everything.
    static let insightsScanLimit = 5000
    /// Ranked lists show this many names before folding the rest into "others".
    static let insightsTopCount = 6
    static let insightsHours = 24
    static let insightsDays = 14

    /// One name in a ranked list, with how many messages it accounts for.
    struct Tally: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let count: Int
        /// Of `count`, how many are still unread (senders only).
        var unread: Int = 0
    }

    struct Ranking: Equatable {
        var top: [Tally] = []
        /// How many distinct names there are in all.
        var distinct = 0
        /// Messages from names past `top`.
        var others = 0
    }

    /// What the drawer's Insights view shows about one panel's mail.
    struct Insights: Equatable {
        var received = 0
        var unread = 0
        var firstAt: Date?
        var lastAt: Date?
        var oldestUnreadAt: Date?
        var lastHour = 0
        var lastDay = 0
        var lastWeek = 0
        /// Received per rolling hour, oldest first; the last bucket is the past hour.
        var hourly: [Int] = Array(repeating: 0, count: MailboxPanelMail.insightsHours)
        /// Received per calendar day, oldest first; the last bucket is today.
        var daily: [Int] = Array(repeating: 0, count: MailboxPanelMail.insightsDays)
        /// The start of each `daily` bucket's day.
        var dayStarts: [Date] = []

        /// Envelopes parsed for the breakdowns below, and those that would not parse.
        var scanned = 0
        var unparsed = 0
        var senders = Ranking()
        var topics = Ranking()
        var untitled = 0
        var urgent = 0
        var replies = 0
        var fileBodies = 0

        /// Messages this panel sent that the ledger still records.
        var sent = 0
        var recipients = Ranking()
        /// Recipient copies still on disk, and how many of those were taken.
        var sentCopies = 0
        var sentTaken = 0

        /// The ledger keeps only about its newest `retain` entries, so at that
        /// size older sends may be missing. A ledger between `retain` and its
        /// trim threshold may not have been trimmed yet; the note says "may".
        var sentIsTrimmed: Bool { sent >= MailboxSentLedger.retain }
        var scanIsPartial: Bool { scanned + unparsed < received }

        /// When the scan ran; rates are measured up to it.
        var scannedAt = Date()

        /// Received per day from the first message until the scan, when that
        /// spans a day or more. A burst long ago reads as a low rate now.
        var perDay: Double? {
            guard let firstAt else { return nil }
            let days = scannedAt.timeIntervalSince(firstAt) / 86400
            guard days >= 1 else { return nil }
            return Double(received) / days
        }
    }

    /// Reads one panel's inbox, `_read/` and `_sent/` ledger. Lists every
    /// envelope, parses the newest `scanLimit`, and stats each sent
    /// recipient's copy. Call it off the main thread.
    static func insights(
        inbox: URL,
        mailboxesRoot: URL,
        now: Date = Date(),
        scanLimit: Int = insightsScanLimit,
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) -> Insights {
        var result = Insights()
        result.scannedAt = now
        let unreadFiles = envelopeFiles(in: inbox, fileManager: fileManager)
        let readFiles = envelopeFiles(in: MailboxDrain.readURL(inbox: inbox), fileManager: fileManager)
        result.unread = unreadFiles.count
        result.received = unreadFiles.count + readFiles.count

        let today = calendar.startOfDay(for: now)
        result.dayStarts = (0..<insightsDays).map { offset in
            calendar.date(byAdding: .day, value: offset - (insightsDays - 1), to: today) ?? today
        }

        let dated = (unreadFiles.map { ($0, true) } + readFiles.map { ($0, false) }).map { entry in
            (url: entry.0, unread: entry.1, date: arrivalDate(of: entry.0, fileManager: fileManager))
        }
        for entry in dated {
            guard let date = entry.date else { continue }
            if result.firstAt.map({ date < $0 }) ?? true { result.firstAt = date }
            if result.lastAt.map({ date > $0 }) ?? true { result.lastAt = date }
            // Unread waits are measured from landing, as the cell measures them.
            if entry.unread, let landed = landingDate(of: entry.url, fileManager: fileManager),
               result.oldestUnreadAt.map({ landed < $0 }) ?? true {
                result.oldestUnreadAt = landed
            }
            let age = now.timeIntervalSince(date)
            if age >= 0 {
                if age < 3600 { result.lastHour += 1 }
                if age < 86400 {
                    result.lastDay += 1
                    result.hourly[insightsHours - 1 - Int(age / 3600)] += 1
                }
                if age < 7 * 86400 { result.lastWeek += 1 }
            }
            if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day,
               (0..<insightsDays).contains(days) {
                result.daily[insightsDays - 1 - days] += 1
            }
        }

        var senders: [String: (count: Int, unread: Int)] = [:]
        var topics: [String: Int] = [:]
        let newestFirst = dated.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        for entry in newestFirst.prefix(max(0, scanLimit)) {
            guard case .success(let read) = readRegularFilePrefix(path: entry.url.path, limit: maxEnvelopeBytes, followSymlinks: false),
                  !read.truncated,
                  let raw = (try? JSONSerialization.jsonObject(with: read.data)) as? [String: Any] else {
                result.unparsed += 1
                continue
            }
            result.scanned += 1
            let from = (raw["from"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
            senders[from, default: (0, 0)].count += 1
            if entry.unread { senders[from, default: (0, 0)].unread += 1 }
            if let topic = raw["topic"] as? String, !topic.isEmpty {
                topics[topic, default: 0] += 1
            } else {
                result.untitled += 1
            }
            if (raw["urgent"] as? Bool) == true { result.urgent += 1 }
            if let parent = raw["in_reply_to"] as? String, !parent.isEmpty { result.replies += 1 }
            if let ref = raw["body_ref"] as? String, !ref.isEmpty { result.fileBodies += 1 }
        }
        result.senders = ranking(senders.map { Tally(name: $0.key, count: $0.value.count, unread: $0.value.unread) })
        result.topics = ranking(topics.map { Tally(name: $0.key, count: $0.value) })

        let (entries, total) = MailboxSentLedger.entries(senderInbox: inbox, limit: Int.max, fileManager: fileManager)
        result.sent = total
        // Tallied by recipient panel, so direct and broadcast sends to one panel
        // share a row. A panel is named by the address of its newest direct
        // send when it had one (the dispatcher's label is often only a title),
        // else by its newest label. Entries come newest first.
        var recipientCounts: [String: Int] = [:]
        var directNames: [String: String] = [:]
        var labels: [String: String] = [:]
        for entry in entries {
            let direct = entry.recipients.count == 1 ? entry.to.flatMap { $0.isEmpty ? nil : $0 } : nil
            for recipient in entry.recipients {
                let key = recipient.panel.lowercased()
                recipientCounts[key, default: 0] += 1
                if let direct, directNames[key] == nil { directNames[key] = direct }
                if labels[key] == nil, !recipient.name.isEmpty { labels[key] = recipient.name }
                guard let panel = UUID(uuidString: recipient.panel) else { continue }
                let copyInbox = inboxURL(mailboxesRoot: mailboxesRoot, panelId: panel)
                let file = MailboxLayout.envelopeFilename(id: entry.id)
                if fileManager.fileExists(atPath: MailboxDrain.readURL(inbox: copyInbox).appendingPathComponent(file).path) {
                    result.sentCopies += 1
                    result.sentTaken += 1
                } else if fileManager.fileExists(atPath: copyInbox.appendingPathComponent(file).path) {
                    result.sentCopies += 1
                }
            }
        }
        result.recipients = ranking(recipientCounts.map { key, count in
            Tally(name: directNames[key] ?? labels[key] ?? key, count: count)
        })
        return result
    }

    /// Most messages first, then by name, so equal counts never reorder.
    static func ranking(_ tallies: [Tally], top: Int = insightsTopCount) -> Ranking {
        let ordered = tallies.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        let shown = Array(ordered.prefix(max(0, top)))
        return Ranking(
            top: shown,
            distinct: ordered.count,
            others: ordered.dropFirst(shown.count).reduce(0) { $0 + $1.count }
        )
    }
}
