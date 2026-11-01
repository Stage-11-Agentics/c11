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

        /// The inline body and the referenced file's text with their links
        /// found (C11-524). Built once when the listing loads, off the main
        /// thread, so the drawer never parses a body while it renders.
        var bodyRich = AttributedString()
        var referenceRich: AttributedString? = nil

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
                .flatMap(UUID.init(uuidString:)),
            bodyRich: MailboxBodyLinks.attributed(body),
            referenceRich: referencedText.isEmpty ? nil : MailboxBodyLinks.attributed(referencedText)
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

    /// A slice lists at most this many messages, newest first.
    static let sliceMessageLimit = 50

    /// One name in a ranked list, with how many messages it accounts for.
    struct Tally: Equatable, Identifiable {
        var id: String { key ?? name }
        let name: String
        let count: Int
        /// Of `count`, how many are still unread (senders only).
        var unread: Int = 0
        /// What a click filters on, when it is not the name (a recipient panel).
        var key: String? = nil
    }

    /// The parts of an envelope Insights reads. Envelopes never change once
    /// written, so a header is cached by file name and parsed only once.
    struct Header: Equatable {
        let from: String
        let topic: String?
        let urgent: Bool
        let reply: Bool
        let fileBody: Bool
        /// The body's first line, at most `previewLimit` characters.
        let preview: String
        /// The preview with its links found (C11-524), built with the header.
        let previewRich: AttributedString
        /// The panel the dispatcher stamped as sender; nil on unstamped mail.
        /// Conversations key received mail by it, never by `from`.
        let senderPanel: UUID?
        /// The last path component of `body_ref`, capped, for a one-line preview.
        let fileName: String?

        static let previewLimit = 140
        /// Sender and topic are untrusted and cached for the app's life, so
        /// each is capped; a real address or topic is far shorter.
        static let fieldLimit = 256

        init(
            from: String,
            topic: String?,
            urgent: Bool,
            reply: Bool,
            fileBody: Bool,
            preview: String,
            senderPanel: UUID? = nil,
            fileName: String? = nil
        ) {
            self.from = from
            self.topic = topic
            self.urgent = urgent
            self.reply = reply
            self.fileBody = fileBody
            self.preview = preview
            self.previewRich = MailboxBodyLinks.attributed(preview)
            self.senderPanel = senderPanel
            self.fileName = fileName
        }

        init(raw: [String: Any]) {
            func string(_ key: String) -> String? {
                guard let value = raw[key] as? String, !value.isEmpty else { return nil }
                return value
            }
            from = string("from").map { String($0.prefix(Self.fieldLimit)) } ?? "?"
            topic = string("topic").map { String($0.prefix(Self.fieldLimit)) }
            urgent = (raw["urgent"] as? Bool) == true
            reply = string("in_reply_to") != nil
            fileBody = string("body_ref") != nil
            let body = raw["body"] as? String ?? ""
            let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            preview = String(firstLine.prefix(Self.previewLimit))
            previewRich = MailboxBodyLinks.attributed(preview)
            senderPanel = ((raw["ext"] as? [String: Any])?[MailboxEnvelope.senderPanelKey] as? String)
                .flatMap(UUID.init(uuidString:))
            fileName = string("body_ref")
                .map { String((($0 as NSString).lastPathComponent).prefix(Self.fieldLimit)) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// One parsed received message.
    struct Record: Equatable, Identifiable {
        var id: String { (unread ? "unread/" : "read/") + fileId }
        let fileId: String
        let unread: Bool
        /// When it was sent (its ULID), or the file time for a hand-dropped file.
        let date: Date?
        /// When an unread message landed, as the cell measures waits.
        let landed: Date?
        let header: Header
        /// Its `hourly` and `daily` buckets in the scan that read it, computed
        /// off the main thread so a click never touches the calendar.
        var hour: Int? = nil
        var day: Int? = nil
    }

    /// One message this panel sent, with where each recipient's copy stands.
    struct SentRecord: Equatable, Identifiable {
        var id: String { entryId }
        let entryId: String
        let sentAt: Date?
        let topic: String?
        /// Recipient panel key (lowercased UUID) to the state of its copy.
        let states: [String: SentState]
    }

    /// Process-wide cache of parsed headers, keyed by inbox and file name. A
    /// claim moves a file into `_read/` under the same name, so it stays
    /// cached. Bounded: past `capacity` it starts over.
    final class HeaderCache {
        static let shared = HeaderCache()
        static let capacity = 60_000

        private let lock = NSLock()
        private var headers: [String: Header] = [:]

        func header(for key: String) -> Header? {
            lock.lock(); defer { lock.unlock() }
            return headers[key]
        }

        func store(_ header: Header, for key: String) {
            lock.lock(); defer { lock.unlock() }
            if headers.count >= Self.capacity { headers.removeAll(keepingCapacity: true) }
            headers[key] = header
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return headers.count
        }
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

        /// The parsed messages, newest first: what a drill-down filters.
        var records: [Record] = []
        /// Every sent entry the ledger holds, newest first.
        var sentRecords: [SentRecord] = []

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

        /// Every figure that comes from parsing envelopes (senders, topics and
        /// the urgent, reply, file-body and no-topic counts) covers only the
        /// newest `scanLimit`. When the scan stopped short, this says so, next
        /// to those figures; nil when they cover everything.
        var sampleScopeNote: String? {
            guard scanIsPartial else { return nil }
            return String(
                localized: "mailbox.insights.note.sample",
                defaultValue: "Senders, topics and the urgent, reply, file-body and no-topic counts cover only the newest \(scanned + unparsed) of \(received) messages."
            )
        }

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
        cache: HeaderCache? = .shared,
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

        // Unread waits are measured from landing, as the cell measures them.
        let dated = (unreadFiles.map { ($0, true) } + readFiles.map { ($0, false) }).map { entry in
            (
                url: entry.0,
                unread: entry.1,
                date: arrivalDate(of: entry.0, fileManager: fileManager),
                landed: entry.1 ? landingDate(of: entry.0, fileManager: fileManager) : nil
            )
        }
        for entry in dated {
            if let landed = entry.landed, result.oldestUnreadAt.map({ landed < $0 }) ?? true {
                result.oldestUnreadAt = landed
            }
            guard let date = entry.date else { continue }
            if result.firstAt.map({ date < $0 }) ?? true { result.firstAt = date }
            if result.lastAt.map({ date > $0 }) ?? true { result.lastAt = date }
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
        let cachePrefix = inbox.standardizedFileURL.path + "/"
        result.records.reserveCapacity(min(newestFirst.count, max(0, scanLimit)))
        for entry in newestFirst.prefix(max(0, scanLimit)) {
            let name = entry.url.lastPathComponent
            let header: Header
            if let cached = cache?.header(for: cachePrefix + name) {
                header = cached
            } else {
                // A failed read is not cached: it may succeed next time.
                guard case .success(let read) = readRegularFilePrefix(path: entry.url.path, limit: maxEnvelopeBytes, followSymlinks: false),
                      !read.truncated,
                      let raw = (try? JSONSerialization.jsonObject(with: read.data)) as? [String: Any] else {
                    result.unparsed += 1
                    continue
                }
                header = Header(raw: raw)
                cache?.store(header, for: cachePrefix + name)
            }
            result.scanned += 1
            result.records.append(Record(
                fileId: entry.url.deletingPathExtension().lastPathComponent,
                unread: entry.unread,
                date: entry.date,
                landed: entry.landed,
                header: header,
                hour: entry.date.flatMap { hourIndex($0, now: now) },
                day: entry.date.flatMap { dayIndex($0, dayStarts: result.dayStarts, calendar: calendar) }
            ))
            senders[header.from, default: (0, 0)].count += 1
            if entry.unread { senders[header.from, default: (0, 0)].unread += 1 }
            if let topic = header.topic {
                topics[topic, default: 0] += 1
            } else {
                result.untitled += 1
            }
            if header.urgent { result.urgent += 1 }
            if header.reply { result.replies += 1 }
            if header.fileBody { result.fileBodies += 1 }
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
            var states: [String: SentState] = [:]
            for recipient in entry.recipients {
                let key = recipient.panel.lowercased()
                recipientCounts[key, default: 0] += 1
                if let direct, directNames[key] == nil { directNames[key] = direct }
                if labels[key] == nil, !recipient.name.isEmpty { labels[key] = recipient.name }
                guard let panel = UUID(uuidString: recipient.panel) else {
                    states[key] = .gone
                    continue
                }
                let copyInbox = inboxURL(mailboxesRoot: mailboxesRoot, panelId: panel)
                let file = MailboxLayout.envelopeFilename(id: entry.id)
                if fileManager.fileExists(atPath: MailboxDrain.readURL(inbox: copyInbox).appendingPathComponent(file).path) {
                    result.sentCopies += 1
                    result.sentTaken += 1
                    states[key] = .read
                } else if fileManager.fileExists(atPath: copyInbox.appendingPathComponent(file).path) {
                    result.sentCopies += 1
                    states[key] = .unread
                } else {
                    states[key] = .gone
                }
            }
            result.sentRecords.append(SentRecord(
                entryId: entry.id,
                sentAt: entry.ts.flatMap(parseTimestamp) ?? ulidDate(entry.id),
                topic: entry.topic.flatMap { $0.isEmpty ? nil : $0 },
                states: states
            ))
        }
        result.recipients = ranking(recipientCounts.map { key, count in
            Tally(name: directNames[key] ?? labels[key] ?? key, count: count, key: key)
        })
        return result
    }

    /// Most messages first, then by name, so equal counts never reorder. A
    /// `pinned` name (the selected filter) always shows, in the last slot if
    /// it would fall past the top, with a zero count if it has no messages.
    static func ranking(_ tallies: [Tally], top: Int = insightsTopCount, pinned: String? = nil) -> Ranking {
        let ordered = tallies.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        var shown = Array(ordered.prefix(max(0, top)))
        if let pinned, top > 0, !shown.contains(where: { $0.name == pinned }) {
            let tally = ordered.first { $0.name == pinned } ?? Tally(name: pinned, count: 0)
            if shown.count == top { shown[top - 1] = tally } else { shown.append(tally) }
        }
        // By identity, not name: two recipient panels can share a label.
        let shownIds = Set(shown.map(\.id))
        return Ranking(
            top: shown,
            distinct: ordered.count,
            others: ordered.reduce(0) { shownIds.contains($1.id) ? $0 : $0 + $1.count }
        )
    }

    // MARK: Drill-down

    /// What the reader clicked. Received filters stack (a sender, a topic and
    /// one time bucket); a recipient filter shows the sent side instead.
    struct InsightsFilter: Equatable {
        var from: String?
        var topic: String?
        /// A time range in absolute dates, so a rescan never slides it.
        var window: TimeWindow?
        /// A recipient panel key from the "Sent to" list, and the label its row
        /// showed when clicked, so the chip keeps a name if the row drops out.
        var recipient: String?
        var recipientName: String?

        var isEmpty: Bool { self == InsightsFilter() }

        enum Kind { case from, topic, time }

        /// Picking the selected value again clears it. A time range replaces
        /// any other, and the sent and received sides never mix.
        mutating func toggleFrom(_ value: String) { leaveSent(); from = from == value ? nil : value }
        mutating func toggleTopic(_ value: String) { leaveSent(); topic = topic == value ? nil : value }

        /// A received filter ends a recipient drill-down, name and all.
        private mutating func leaveSent() {
            recipient = nil
            recipientName = nil
        }

        /// Picks the hour bar `index` of this scan; the bar already selected clears.
        mutating func pickHour(_ index: Int, in insights: Insights) {
            leaveSent()
            if selectedHour(in: insights) == index { window = nil; return }
            window = Self.hourWindow(index, in: insights)
        }

        /// Picks the day bar `index`, a calendar day; the day already selected clears.
        mutating func pickDay(_ index: Int, in insights: Insights, calendar: Calendar = .current) {
            leaveSent()
            guard insights.dayStarts.indices.contains(index) else { return }
            if selectedDay(in: insights) == index { window = nil; return }
            let start = insights.dayStarts[index]
            window = TimeWindow(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400), isDay: true)
        }

        /// The hour bar whose range in this scan is exactly the selected one.
        /// Hour bars roll with each scan, so after a rescan no bar matches and
        /// none is highlighted; the chip still names the range.
        func selectedHour(in insights: Insights) -> Int? {
            guard let window, !window.isDay else { return nil }
            let ago = Int((insights.scannedAt.timeIntervalSince(window.end) / 3600).rounded())
            guard (0..<insightsHours).contains(ago) else { return nil }
            let index = insightsHours - 1 - ago
            return Self.hourWindow(index, in: insights) == window ? index : nil
        }

        static func hourWindow(_ index: Int, in insights: Insights) -> TimeWindow {
            let end = insights.scannedAt.addingTimeInterval(-TimeInterval(insightsHours - 1 - index) * 3600)
            return TimeWindow(start: end.addingTimeInterval(-3600), end: end, isDay: false)
        }

        func selectedDay(in insights: Insights) -> Int? {
            guard let window, window.isDay else { return nil }
            return insights.dayStarts.firstIndex(of: window.start)
        }

        mutating func toggleRecipient(_ key: String, name: String? = nil) {
            let same = recipient == key
            self = InsightsFilter()
            recipient = same ? nil : key
            recipientName = same ? nil : name
        }
    }

    struct TimeWindow: Equatable {
        let start: Date
        let end: Date
        let isDay: Bool

        func contains(_ date: Date) -> Bool { date >= start && date < end }
    }

    /// The received figures for one filter, computed from the parsed records.
    struct Slice: Equatable {
        var count = 0
        var unread = 0
        /// The oldest and newest matching messages.
        var firstAt: Date?
        var lastAt: Date?
        var lastHour = 0
        var lastDay = 0
        var lastWeek = 0
        var oldestUnreadAt: Date?
        /// Each chart ignores the time filter, so its other bars stay visible.
        var hourly: [Int] = Array(repeating: 0, count: MailboxPanelMail.insightsHours)
        var daily: [Int] = Array(repeating: 0, count: MailboxPanelMail.insightsDays)
        /// Each ranking ignores its own filter, so a reader can switch within it.
        var senders = Ranking()
        var topics = Ranking()
        var urgent = 0
        var replies = 0
        var fileBodies = 0
        var untitled = 0
        /// The newest `sliceMessageLimit` matching messages.
        var messages: [Record] = []
    }

    static func hourIndex(_ date: Date, now: Date) -> Int? {
        let age = now.timeIntervalSince(date)
        guard age >= 0, age < 86400 else { return nil }
        return insightsHours - 1 - Int(age / 3600)
    }

    static func dayIndex(_ date: Date, dayStarts: [Date], calendar: Calendar) -> Int? {
        guard let today = dayStarts.last,
              let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day,
              (0..<insightsDays).contains(days) else { return nil }
        return insightsDays - 1 - days
    }

    static func matches(
        _ record: Record,
        _ filter: InsightsFilter,
        ignoring kind: InsightsFilter.Kind? = nil,
        now: Date,
        dayStarts: [Date],
        calendar: Calendar
    ) -> Bool {
        if kind != .from, let from = filter.from, record.header.from != from { return false }
        if kind != .topic, let topic = filter.topic, record.header.topic != topic { return false }
        if kind != .time, let window = filter.window {
            guard let date = record.date, window.contains(date) else { return false }
        }
        return true
    }

    /// One pass over at most `insightsScanLimit` records per figure; pure, so
    /// a click recomputes it in well under a frame.
    static func slice(_ insights: Insights, filter: InsightsFilter, calendar: Calendar = .current) -> Slice {
        let now = insights.scannedAt
        let starts = insights.dayStarts
        var result = Slice()
        var senders: [String: (count: Int, unread: Int)] = [:]
        var topics: [String: Int] = [:]
        for record in insights.records {
            let all = matches(record, filter, now: now, dayStarts: starts, calendar: calendar)
            if all {
                result.count += 1
                if record.unread {
                    result.unread += 1
                    if let landed = record.landed ?? record.date, result.oldestUnreadAt.map({ landed < $0 }) ?? true {
                        result.oldestUnreadAt = landed
                    }
                }
                if let date = record.date {
                    if result.lastAt == nil { result.lastAt = date }
                    result.firstAt = date
                    let age = now.timeIntervalSince(date)
                    if age >= 0 {
                        if age < 3600 { result.lastHour += 1 }
                        if age < 86400 { result.lastDay += 1 }
                        if age < 7 * 86400 { result.lastWeek += 1 }
                    }
                }
                if record.header.urgent { result.urgent += 1 }
                if record.header.reply { result.replies += 1 }
                if record.header.fileBody { result.fileBodies += 1 }
                if record.header.topic == nil { result.untitled += 1 }
                if result.messages.count < sliceMessageLimit { result.messages.append(record) }
            }
            if record.hour != nil || record.day != nil,
               all || matches(record, filter, ignoring: .time, now: now, dayStarts: starts, calendar: calendar) {
                if let hour = record.hour { result.hourly[hour] += 1 }
                if let day = record.day { result.daily[day] += 1 }
            }
            if all || matches(record, filter, ignoring: .from, now: now, dayStarts: starts, calendar: calendar) {
                senders[record.header.from, default: (0, 0)].count += 1
                if record.unread { senders[record.header.from, default: (0, 0)].unread += 1 }
            }
            if let topic = record.header.topic,
               all || matches(record, filter, ignoring: .topic, now: now, dayStarts: starts, calendar: calendar) {
                topics[topic, default: 0] += 1
            }
        }
        result.senders = ranking(senders.map { Tally(name: $0.key, count: $0.value.count, unread: $0.value.unread) }, pinned: filter.from)
        result.topics = ranking(topics.map { Tally(name: $0.key, count: $0.value) }, pinned: filter.topic)
        return result
    }

    /// Up to `limit` sender names, most messages first: the ones worth
    /// resolving to panel numbers. Off the main thread, from the records.
    static func busiestSenders(_ insights: Insights, limit: Int = 200) -> [String] {
        var counts: [String: Int] = [:]
        for record in insights.records { counts[record.header.from, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    /// What this panel sent to one recipient panel.
    struct SentSlice: Equatable {
        var sent = 0
        var taken = 0
        var waiting = 0
        var gone = 0
        /// The newest `sliceMessageLimit`, each with this recipient's state.
        var messages: [SentItem] = []
    }

    struct SentItem: Equatable, Identifiable {
        var id: String { record.id }
        let record: SentRecord
        let state: SentState
    }

    static func sentSlice(_ insights: Insights, recipient key: String) -> SentSlice {
        var result = SentSlice()
        for record in insights.sentRecords {
            guard let state = record.states[key] else { continue }
            result.sent += 1
            switch state {
            case .read: result.taken += 1
            case .unread: result.waiting += 1
            case .gone: result.gone += 1
            }
            if result.messages.count < sliceMessageLimit { result.messages.append(SentItem(record: record, state: state)) }
        }
        return result
    }
}

// MARK: - Conversations

extension MailboxPanelMail {

    /// A thread reads full envelopes for at most this many of its newest messages.
    static let threadLimit = 200

    /// Who a conversation is with. Only the dispatcher's stamp identifies a
    /// panel: `from` is a name any writer can put on an envelope.
    enum PeerKey: Hashable {
        /// A panel by its UUID: the stamped sender of received mail, or a
        /// recipient panel of this panel's `_sent/` entries.
        case panel(UUID)
        /// Received mail without a sender stamp, by its `from`. It is never
        /// merged into a panel's conversation, whatever that panel is called.
        case name(String)

        var id: String {
            switch self {
            case .panel(let panel): return "panel/" + panel.uuidString.lowercased()
            case .name(let name): return "name/" + name
            }
        }

        var panelId: UUID? {
            if case .panel(let panel) = self { return panel }
            return nil
        }
    }

    enum Direction: Equatable { case received, sent }

    /// What a list row shows of a conversation's newest message.
    enum Preview: Equatable {
        /// The body's first line.
        case text(String)
        /// A `body_ref` body, by its file name.
        case file(String)
        /// A send whose copies are all gone, or carry no stamp of this panel.
        case copyGone
        case empty
    }

    /// One message of a conversation as the index knows it, before any body is read.
    struct ConversationRef: Equatable {
        let direction: Direction
        /// The envelope id: a received file's name, or a `_sent/` entry's id.
        let envelopeId: String
        /// When it was sent: its ULID, else its `ts` or the file's time.
        let date: Date?
        /// Received: the file's name and whether it is still in the inbox root.
        var fileName: String? = nil
        var unread = false
        /// Sent: the ledger entry.
        var entry: MailboxSentLedger.Entry? = nil
    }

    /// One conversation in the list, built from cached headers and the ledger.
    struct Conversation: Identifiable, Equatable {
        var id: String { key.id }
        let key: PeerKey
        /// What the mail itself calls the peer, for when no open panel names
        /// it: the `from` of its newest message, else the address of this
        /// panel's newest direct send to it, else its newest ledger label.
        var label = ""
        /// Every message, newest first.
        var refs: [ConversationRef] = []
        var received = 0
        var sent = 0
        var unread = 0
        var lastPreview: Preview = .empty
        /// Where the peer's copy of this panel's newest send to it stands;
        /// nil when the ledger records no send to it.
        var lastSendState: SentState?

        var count: Int { refs.count }
        var lastAt: Date? { refs.first?.date }
        var lastDirection: Direction? { refs.first?.direction }
        var lastSendAt: Date? { refs.first(where: { $0.direction == .sent })?.date }
    }

    struct ConversationIndex: Equatable {
        /// Newest activity first.
        var conversations: [Conversation] = []
        /// Every received envelope on disk, and how many the index read.
        var received = 0
        var scanned = 0
        var unparsed = 0
        /// When the `_sent/` ledger's oldest entry was sent. This panel's
        /// sends from before it are not recorded.
        var ledgerFloor: Date?

        var unread: Int { conversations.reduce(0) { $0 + $1.unread } }
        var scanIsPartial: Bool { scanned + unparsed < received }

        func conversation(_ key: PeerKey) -> Conversation? {
            conversations.first { $0.key == key }
        }
    }

    /// The conversation list: the newest `scanLimit` received headers, read
    /// through the header cache as Insights reads them, and every `_sent/`
    /// entry. No body is read; per conversation, at most a few recipient
    /// copies' cached headers for its newest send. Call it off the main thread.
    static func conversationIndex(
        inbox: URL,
        mailboxesRoot: URL,
        scanLimit: Int = insightsScanLimit,
        cache: HeaderCache? = .shared,
        fileManager: FileManager = .default
    ) -> ConversationIndex {
        var index = ConversationIndex()
        let unreadFiles = envelopeFiles(in: inbox, fileManager: fileManager)
        let readFiles = envelopeFiles(in: MailboxDrain.readURL(inbox: inbox), fileManager: fileManager)
        index.received = unreadFiles.count + readFiles.count
        let dated = (unreadFiles.map { ($0, true) } + readFiles.map { ($0, false) }).map { entry in
            (url: entry.0, unread: entry.1, date: arrivalDate(of: entry.0, fileManager: fileManager))
        }
        let newestFirst = dated.sorted {
            isNewer($0.date, $0.url.lastPathComponent, than: $1.date, $1.url.lastPathComponent)
        }

        var conversations: [PeerKey: Conversation] = [:]
        var newestHeaders: [PeerKey: Header] = [:]
        for entry in newestFirst.prefix(max(0, scanLimit)) {
            guard let header = cachedHeader(of: entry.url, inbox: inbox, cache: cache) else {
                index.unparsed += 1
                continue
            }
            index.scanned += 1
            let key = header.senderPanel.map(PeerKey.panel) ?? .name(header.from)
            var conversation = conversations[key] ?? Conversation(key: key)
            if newestHeaders[key] == nil {
                newestHeaders[key] = header
                if header.from != "?" { conversation.label = header.from }
            }
            conversation.received += 1
            if entry.unread { conversation.unread += 1 }
            conversation.refs.append(ConversationRef(
                direction: .received,
                envelopeId: entry.url.deletingPathExtension().lastPathComponent,
                date: entry.date,
                fileName: entry.url.lastPathComponent,
                unread: entry.unread
            ))
            conversations[key] = conversation
        }

        // A send is in the thread of every panel it landed in, broadcasts
        // included. Entries come newest first.
        let sender = UUID(uuidString: inbox.lastPathComponent)
        let entries = MailboxSentLedger.entries(senderInbox: inbox, limit: Int.max, fileManager: fileManager).entries
        var directNames: [UUID: String] = [:]
        var ledgerLabels: [UUID: String] = [:]
        for entry in entries {
            let date = sentDate(of: entry)
            if let date, index.ledgerFloor.map({ date < $0 }) ?? true { index.ledgerFloor = date }
            let direct = entry.recipients.count == 1 ? entry.to.flatMap { $0.isEmpty ? nil : $0 } : nil
            var seen = Set<UUID>()
            for recipient in entry.recipients {
                guard let panel = UUID(uuidString: recipient.panel), seen.insert(panel).inserted else { continue }
                let key = PeerKey.panel(panel)
                var conversation = conversations[key] ?? Conversation(key: key)
                conversation.sent += 1
                conversation.refs.append(ConversationRef(direction: .sent, envelopeId: entry.id, date: date, entry: entry))
                conversations[key] = conversation
                if let direct, directNames[panel] == nil { directNames[panel] = String(direct.prefix(Header.fieldLimit)) }
                if ledgerLabels[panel] == nil, !recipient.name.isEmpty {
                    ledgerLabels[panel] = String(recipient.name.prefix(Header.fieldLimit))
                }
            }
        }

        index.conversations = conversations.values.map { found -> Conversation in
            var conversation = found
            conversation.refs.sort { isNewer($0, $1) }
            switch conversation.key {
            case .name(let name):
                conversation.label = name
            case .panel(let panel):
                if conversation.label.isEmpty {
                    conversation.label = directNames[panel] ?? ledgerLabels[panel] ?? ""
                }
                if let entry = conversation.refs.first(where: { $0.direction == .sent })?.entry {
                    let own = sentCopy(id: entry.id, in: panel, sender: sender, mailboxesRoot: mailboxesRoot, cache: cache, fileManager: fileManager)
                    conversation.lastSendState = own.state
                    if conversation.lastDirection == .sent {
                        // A broadcast's text survives while any recipient's copy does.
                        var header = own.header
                        if header == nil {
                            for other in recipientPanels(of: entry) where other != panel {
                                header = sentCopy(id: entry.id, in: other, sender: sender, mailboxesRoot: mailboxesRoot, cache: cache, fileManager: fileManager).header
                                if header != nil { break }
                            }
                        }
                        conversation.lastPreview = header.map(preview(of:)) ?? .copyGone
                    }
                }
            }
            if conversation.lastDirection == .received, let header = newestHeaders[conversation.key] {
                conversation.lastPreview = preview(of: header)
            }
            return conversation
        }
        .sorted { lhs, rhs in
            switch (lhs.lastAt, rhs.lastAt) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.id < rhs.id
            }
        }
        return index
    }

    /// The message a reply points at, when it is in the thread.
    struct ThreadParent: Equatable {
        let id: String
        let topic: String?
        let date: Date?
    }

    /// One message of the open thread, read in full.
    struct ThreadItem: Identifiable, Equatable {
        /// Stable while the message is taken, and unique in the thread.
        let id: String
        let envelopeId: String
        let direction: Direction
        let date: Date?
        let topic: String?
        /// A send's `to`, as this panel addressed it.
        let to: String?
        /// Received: the envelope. Sent: a recipient copy that carries this
        /// panel's stamp, the peer's own when it has one; nil when none is
        /// left, so the text cannot be shown.
        let message: Message?
        /// Received: whether this panel's agent has taken it. Sent: where the
        /// peer's copy stands.
        let state: SentState
        /// A send's recipients, each with where its copy stands.
        let recipients: [SentRecipient]
        var parent: ThreadParent? = nil
    }

    struct ConversationThread: Equatable {
        let key: PeerKey
        /// Oldest first: the conversation's newest `limit` messages.
        var items: [ThreadItem] = []
        var total = 0
        var received = 0
        var sent = 0
        var unread = 0
        var firstUnreadId: String?
        /// When this panel's sent record starts. If the peer's side shows from
        /// before it, a marker goes before `ledgerFloorItemId`, or after the
        /// last message when that is nil.
        var ledgerFloor: Date?
        var showsLedgerFloor = false
        var ledgerFloorItemId: String?

        var hiddenCount: Int { max(0, total - items.count) }
    }

    /// Reads one conversation's newest `limit` messages in full, oldest
    /// first. A sent message's text comes only from a recipient copy that
    /// carries this panel's stamp. Call it off the main thread.
    static func thread(
        _ conversation: Conversation,
        inbox: URL,
        mailboxesRoot: URL,
        ledgerFloor: Date?,
        limit: Int = threadLimit,
        cache: HeaderCache? = .shared,
        fileManager: FileManager = .default
    ) -> ConversationThread {
        var thread = ConversationThread(key: conversation.key)
        thread.total = conversation.count
        thread.received = conversation.received
        thread.sent = conversation.sent
        thread.ledgerFloor = ledgerFloor
        let sender = UUID(uuidString: inbox.lastPathComponent)
        let shown = conversation.refs.prefix(max(0, limit))
        let hiddenUnread = conversation.refs.dropFirst(max(0, limit))
            .filter { $0.direction == .received && $0.unread }.count

        var items: [ThreadItem] = []
        var ids = Set<String>()
        for ref in shown.reversed() {
            let item: ThreadItem
            switch ref.direction {
            case .received:
                guard let received = receivedItem(ref, inbox: inbox, fileManager: fileManager) else { continue }
                item = received
            case .sent:
                guard let entry = ref.entry else { continue }
                item = sentItem(
                    entry, date: ref.date, peer: conversation.key.panelId, sender: sender,
                    mailboxesRoot: mailboxesRoot, cache: cache, fileManager: fileManager
                )
            }
            // The same file in the inbox root and `_read/` (a re-delivery).
            var id = item.id
            var copy = 2
            while ids.contains(id) { id = item.id + "#\(copy)"; copy += 1 }
            ids.insert(id)
            items.append(ThreadItem(
                id: id, envelopeId: item.envelopeId, direction: item.direction, date: item.date,
                topic: item.topic, to: item.to, message: item.message, state: item.state, recipients: item.recipients
            ))
        }

        // Received files and ledger entries are both named by envelope id, so
        // a reply links to its parent in either direction.
        var byEnvelope: [String: Int] = [:]
        for (offset, item) in items.enumerated() where byEnvelope[item.envelopeId] == nil {
            byEnvelope[item.envelopeId] = offset
        }
        for offset in items.indices {
            guard let replyTo = items[offset].message?.inReplyTo,
                  replyTo != items[offset].envelopeId,
                  let parentOffset = byEnvelope[replyTo] else { continue }
            let parent = items[parentOffset]
            items[offset].parent = ThreadParent(id: parent.id, topic: parent.topic, date: parent.date)
        }

        thread.items = items
        let unread = items.filter { $0.direction == .received && $0.state == .unread }
        thread.unread = unread.count + hiddenUnread
        thread.firstUnreadId = unread.first?.id
        if conversation.key.panelId != nil, let ledgerFloor,
           items.contains(where: { $0.direction == .received && ($0.date.map { $0 < ledgerFloor } ?? false) }) {
            thread.showsLedgerFloor = true
            thread.ledgerFloorItemId = items.first(where: { $0.date.map { $0 >= ledgerFloor } ?? false })?.id
        }
        return thread
    }

    private static func receivedItem(_ ref: ConversationRef, inbox: URL, fileManager: FileManager) -> ThreadItem? {
        guard let name = ref.fileName else { return nil }
        let readDirectory = MailboxDrain.readURL(inbox: inbox)
        // A claim between the index and this read renames the file into
        // `_read/` under the same name.
        var unread = ref.unread
        var url = (unread ? inbox : readDirectory).appendingPathComponent(name)
        if !fileManager.fileExists(atPath: url.path) {
            let other = (unread ? readDirectory : inbox).appendingPathComponent(name)
            if fileManager.fileExists(atPath: other.path) {
                url = other
                unread.toggle()
            }
        }
        let message = MailboxPanelMail.message(at: url, isUnread: unread, arrivedAt: ref.date, fileManager: fileManager)
        return ThreadItem(
            id: "in/" + ref.envelopeId,
            envelopeId: ref.envelopeId,
            direction: .received,
            date: ref.date,
            topic: message.topic,
            to: message.to,
            message: message,
            state: unread ? .unread : .read,
            recipients: []
        )
    }

    private static func sentItem(
        _ entry: MailboxSentLedger.Entry,
        date: Date?,
        peer: UUID?,
        sender: UUID?,
        mailboxesRoot: URL,
        cache: HeaderCache?,
        fileManager: FileManager
    ) -> ThreadItem {
        var recipients: [SentRecipient] = []
        var peerState = SentState.gone
        var peerCopy: URL?
        var otherCopy: URL?
        var seen = Set<UUID>()
        for recipient in entry.recipients {
            guard let panel = UUID(uuidString: recipient.panel) else {
                recipients.append(SentRecipient(panelId: nil, name: recipient.name, state: .gone))
                continue
            }
            guard seen.insert(panel).inserted else { continue }
            let copy = sentCopy(id: entry.id, in: panel, sender: sender, mailboxesRoot: mailboxesRoot, cache: cache, fileManager: fileManager)
            recipients.append(SentRecipient(panelId: panel, name: recipient.name, state: copy.state))
            if panel == peer {
                peerState = copy.state
                peerCopy = copy.file
            } else if otherCopy == nil {
                otherCopy = copy.file
            }
        }
        // The stamp is read again from the file itself right before the full
        // read, as Sent does, so a `body_ref` is followed only in this
        // panel's own mail.
        var message: Message?
        for file in [peerCopy, otherCopy].compactMap({ $0 }) {
            guard let sender, stampedSender(of: file) == sender else { continue }
            let read = MailboxPanelMail.message(at: file, isUnread: false, arrivedAt: date, fileManager: fileManager)
            guard read.senderPanelId == sender else { continue }
            message = read
            break
        }
        return ThreadItem(
            id: "out/" + entry.id,
            envelopeId: entry.id,
            direction: .sent,
            date: date,
            topic: entry.topic.flatMap { $0.isEmpty ? nil : $0 } ?? message?.topic,
            to: entry.to.flatMap { $0.isEmpty ? nil : $0 },
            message: message,
            state: peerState,
            recipients: recipients
        )
    }

    /// Where `panel`'s copy of a sent envelope stands. A copy counts only if
    /// the dispatcher stamped it with `sender`; any other copy is gone to
    /// this panel and nothing else in it is used. Two stats and the copy's
    /// header from the cache.
    static func sentCopy(
        id: String,
        in panel: UUID,
        sender: UUID?,
        mailboxesRoot: URL,
        cache: HeaderCache?,
        fileManager: FileManager
    ) -> (state: SentState, file: URL?, header: Header?) {
        let inbox = inboxURL(mailboxesRoot: mailboxesRoot, panelId: panel)
        let name = MailboxLayout.envelopeFilename(id: id)
        let unreadURL = inbox.appendingPathComponent(name)
        let readURL = MailboxDrain.readURL(inbox: inbox).appendingPathComponent(name)
        let state: SentState
        let file: URL
        if fileManager.fileExists(atPath: unreadURL.path) {
            state = .unread; file = unreadURL
        } else if fileManager.fileExists(atPath: readURL.path) {
            state = .read; file = readURL
        } else {
            return (.gone, nil, nil)
        }
        guard let sender,
              let header = cachedHeader(of: file, inbox: inbox, cache: cache),
              header.senderPanel == sender else { return (.gone, nil, nil) }
        return (state, file, header)
    }

    /// An envelope's header from `cache`, parsed and stored on a miss. Keyed
    /// as Insights keys it (inbox and file name), so a claim keeps it cached.
    /// A failed read is not cached: it may succeed next time.
    static func cachedHeader(of file: URL, inbox: URL, cache: HeaderCache?) -> Header? {
        let key = inbox.standardizedFileURL.path + "/" + file.lastPathComponent
        if let cached = cache?.header(for: key) { return cached }
        guard case .success(let read) = readRegularFilePrefix(path: file.path, limit: maxEnvelopeBytes, followSymlinks: false),
              !read.truncated,
              let raw = (try? JSONSerialization.jsonObject(with: read.data)) as? [String: Any] else { return nil }
        let header = Header(raw: raw)
        cache?.store(header, for: key)
        return header
    }

    static func preview(of header: Header) -> Preview {
        if !header.preview.isEmpty { return .text(header.preview) }
        if let fileName = header.fileName { return .file(fileName) }
        return .empty
    }

    /// When a send left: its id's ULID, else the entry's `ts`. Received mail
    /// is dated by the same id, so both sides of a thread share one clock.
    static func sentDate(of entry: MailboxSentLedger.Entry) -> Date? {
        ulidDate(entry.id) ?? entry.ts.flatMap(parseTimestamp)
    }

    private static func recipientPanels(of entry: MailboxSentLedger.Entry) -> [UUID] {
        var seen = Set<UUID>()
        return entry.recipients.compactMap { UUID(uuidString: $0.panel) }.filter { seen.insert($0).inserted }
    }

    /// Newest first by date, then by name, so equal times never reorder.
    private static func isNewer(_ lhsDate: Date?, _ lhsName: String, than rhsDate: Date?, _ rhsName: String) -> Bool {
        switch (lhsDate, rhsDate) {
        case let (l?, r?) where l != r: return l > r
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhsName > rhsName
        }
    }

    private static func isNewer(_ lhs: ConversationRef, _ rhs: ConversationRef) -> Bool {
        if lhs.date != rhs.date || lhs.envelopeId != rhs.envelopeId {
            return isNewer(lhs.date, lhs.envelopeId, than: rhs.date, rhs.envelopeId)
        }
        // One id twice: a file in both the inbox root and `_read/`, or a send
        // to this panel itself. A fixed order keeps the thread still.
        if lhs.direction != rhs.direction { return lhs.direction == .sent }
        return lhs.unread && !rhs.unread
    }
}
