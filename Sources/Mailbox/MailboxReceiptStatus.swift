import Darwin
import Foundation

/// C11-550: per-message receipts, built only from records c11 already keeps.
///
/// - **Sent**: the `copied` row in the dispatching workspace's `_dispatch.log`
///   (`rejected` means it never reached an inbox).
/// - **Delivered**: a stdin `doorbell` row for the envelope whose reason is
///   `submitted`, `stranded_return`, `native_late_accept` or
///   `native_already_admitted`. A ring logs one row
///   for every envelope it covers, so each id carries its own. A later hold
///   row never undoes it. A recipient claim with no ring row counts as
///   delivered by that claim.
/// - **Held**: the latest stdin row is a hold (draft, question, unreadable
///   prompt, stranded line, rate cap, or an unconfirmed native invitation such
///   as Claude's chooser). Held is never delivered.
/// - **Read**: the recipient's copy sits in `_read/` and the drain's `claimed`
///   row says the recipient panel itself claimed it. Another panel draining
///   that inbox is `taken`, not read.
///
/// The query is bounded: it stats each workspace log, binary-searches the
/// logs written since the envelope's ULID time, byte-searches forward for the
/// id, and stats two paths per recipient. It never lists an inbox.
enum MailboxReceiptStatus {

    // MARK: - Model

    enum Failure: Error, Equatable {
        case invalidId(String)
        case notFound(String)
        /// The byte budget ran out before every log since the send was read.
        case scanLimit(String)
    }

    enum Delivery: String {
        /// Ring submitted, native invitation confirmed, or claimed by the recipient.
        case delivered
        /// The invitation is being typed.
        case delivering
        /// The recipient's composer or a chooser is holding the doorbell.
        case held
        /// Queued for the recipient's next idle prompt.
        case pending
        /// An attempt failed; the mail stays queued for the next attempt.
        case failed
        /// The doorbell does not ring this recipient (opted out, not an agent, ...).
        case notRung = "not_rung"
        /// The recipient has no push handler; the mail waits in its inbox.
        case notPushed = "not_pushed"
    }

    enum Read: String {
        case read
        case unread
        /// Claimed by a panel other than the recipient.
        case taken
        /// In `_read/` with no claim row (an older CLI, or a claim without a panel).
        case claimedUnknown = "claimed_unknown"
        /// Neither in the inbox nor in `_read/` (swept, expired, or removed).
        case gone
        /// The recipient panel is not recorded (a log row from before receipts).
        case unknown
    }

    struct Recipient {
        var name: String
        var panelId: UUID?
        var sentAt: Date?
        var copyFailed = false
        var usageLimit: String?
        var delivery: Delivery = .notPushed
        var deliveryReason: String?
        var deliveryRoute: String?
        var deliveredAt: Date?
        var read: Read = .unknown
        var readAt: Date?
        var claimedBy: UUID?
    }

    enum State: String {
        case sent
        /// Written to an outbox; no dispatcher has taken it yet.
        case queued
        case rejected
    }

    struct Report {
        var id: String
        var workspaceId: UUID?
        var state: State
        var from: String?
        var to: String?
        var topic: String?
        var acceptedAt: Date?
        var rejectedReason: String?
        var recipients: [Recipient]
        var scannedBytes: Int
        var scanTruncated: Bool
    }

    /// Scan limits. `maxScanBytes` bounds one call across every log.
    struct Limits {
        var maxScanBytes = 64 * 1024 * 1024
        /// How far before the ULID time each log is read. Covers rows stamped
        /// out of order (a `claimed` row written while the dispatcher queue
        /// was stalled) and small clock steps; the binary search assumes `ts`
        /// otherwise only increases.
        var lookBack: TimeInterval = 120
        var chunkBytes = 1024 * 1024

        static let standard = Limits()
    }

    // MARK: - ULID time

    private static let crockford: [UInt8: UInt64] = {
        var map: [UInt8: UInt64] = [:]
        for (index, byte) in MailboxULID.alphabet.enumerated() {
            map[byte] = UInt64(index)
            if let lower = String(UnicodeScalar(byte)).lowercased().utf8.first { map[lower] = UInt64(index) }
        }
        return map
    }()

    /// The millisecond time a ULID carries, or nil when the string is not one.
    static func ulidTime(_ id: String) -> Date? {
        let bytes = Array(id.utf8)
        guard bytes.count == MailboxULID.totalLength else { return nil }
        var ms: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            guard let value = crockford[byte] else { return nil }
            if index < MailboxULID.timestampLength { ms = (ms << 5) | value }
        }
        // The first character holds only 3 bits of a 48-bit time.
        guard ms <= 0x0000_FFFF_FFFF_FFFF else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    // MARK: - Query

    /// Looks the envelope up across every workspace under `workspacesRoot`.
    static func status(
        id rawId: String,
        workspacesRoot: URL,
        limits: Limits = .standard,
        fileManager: FileManager = .default
    ) throws -> Report {
        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let sentAt = ulidTime(id) else { throw Failure.invalidId(rawId) }
        let since = sentAt.addingTimeInterval(-limits.lookBack)
        let workspaceDirs = (try? fileManager.contentsOfDirectory(atPath: workspacesRoot.path)) ?? []

        // One stat per workspace: only logs written since the send can hold it.
        var candidates: [(UUID, URL)] = []
        for name in workspaceDirs {
            guard let workspaceId = UUID(uuidString: name) else { continue }
            let log = workspacesRoot
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(MailboxLayout.mailboxesDirectoryName, isDirectory: true)
                .appendingPathComponent(MailboxLayout.dispatchLogFileName, isDirectory: false)
            var info = stat()
            guard stat(log.path, &info) == 0 else { continue }
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            if modified >= since.timeIntervalSince1970 { candidates.append((workspaceId, log)) }
        }

        // Every log written since the send: a panel that moved workspaces
        // keeps its inbox (and `copied`/`claimed` rows) in the old workspace
        // while its doorbell rows land in the new one. Each log is read only
        // from just before the send, under one shared byte budget.
        var budget = limits.maxScanBytes
        var scanned = 0
        var truncated = false
        var found: [(workspace: UUID, root: URL, rows: [[String: Any]])] = []
        for (workspaceId, log) in candidates {
            guard budget > 0 else { truncated = true; break }
            let scan = LogScan(url: log, id: id, since: since,
                               chunkBytes: limits.chunkBytes, budget: budget)
            let rows = scan.run()
            scanned += scan.scannedBytes
            budget -= scan.scannedBytes
            if scan.hitBudget { truncated = true }
            if !rows.isEmpty { found.append((workspaceId, log.deletingLastPathComponent(), rows)) }
        }
        if !found.isEmpty {
            // The dispatching log is the one that copied it into an inbox.
            func has(_ event: String, _ rows: [[String: Any]]) -> Bool { rows.contains { $0["event"] as? String == event } }
            let home = found.first { has("copied", $0.rows) } ?? found.first { has("received", $0.rows) } ?? found[0]
            let merged = found.flatMap(\.rows).enumerated().sorted { lhs, rhs in
                let l = (lhs.element["ts"] as? String).flatMap(parseTimestamp)
                let r = (rhs.element["ts"] as? String).flatMap(parseTimestamp)
                if let l, let r, l != r { return l < r }
                return lhs.offset < rhs.offset
            }.map(\.element)
            var report = build(id: id, workspaceId: home.workspace, rows: merged,
                               mailboxesRoot: home.root, fileManager: fileManager)
            report.scannedBytes = scanned
            report.scanTruncated = truncated
            return report
        }

        // Not dispatched yet: is it still waiting in an outbox?
        let filename = MailboxLayout.envelopeFilename(id: id)
        for name in workspaceDirs {
            guard let workspaceId = UUID(uuidString: name) else { continue }
            let pending = workspacesRoot
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(MailboxLayout.mailboxesDirectoryName, isDirectory: true)
                .appendingPathComponent(MailboxLayout.outboxDirectoryName, isDirectory: true)
                .appendingPathComponent(filename, isDirectory: false)
            if fileManager.fileExists(atPath: pending.path) {
                return Report(id: id, workspaceId: workspaceId, state: .queued, acceptedAt: nil,
                              recipients: [], scannedBytes: scanned, scanTruncated: truncated)
            }
        }
        // Not every log was read: say so rather than claim it does not exist.
        if truncated { throw Failure.scanLimit(id) }
        throw Failure.notFound(id)
    }

    // MARK: - Fold rows into a report

    /// Rows in log order for one envelope, folded per recipient. Inbox state
    /// comes from two stats per recipient panel.
    static func build(
        id: String,
        workspaceId: UUID?,
        rows: [[String: Any]],
        mailboxesRoot: URL,
        fileManager: FileManager = .default
    ) -> Report {
        var report = Report(id: id, workspaceId: workspaceId, state: .sent, recipients: [],
                            scannedBytes: 0, scanTruncated: false)
        var recipients: [Recipient] = []
        var claims: [(recipient: UUID?, by: UUID?, at: Date?)] = []
        var inboxWorkspaces: [UUID: UUID] = [:]

        func index(name: String?, panel: UUID?) -> Int? {
            if let panel, let found = recipients.firstIndex(where: { $0.panelId == panel }) { return found }
            guard let name else { return nil }
            let named = recipients.indices.filter { recipients[$0].name == name }
            // A same-title pair is told apart only by panel ids.
            if named.count == 1, panel == nil || recipients[named[0]].panelId == nil { return named[0] }
            return nil
        }

        for row in rows {
            let event = row["event"] as? String
            let at = (row["ts"] as? String).flatMap(parseTimestamp)
            let name = row["recipient"] as? String
            let panel = (row["recipient_panel"] as? String).flatMap(UUID.init(uuidString:))
            switch event {
            case "received":
                report.from = row["from"] as? String
                report.to = row["to"] as? String
                report.topic = row["topic"] as? String
                report.acceptedAt = report.acceptedAt ?? at
            case "copied":
                guard let name else { continue }
                if let panel, let workspace = (row["recipient_workspace"] as? String).flatMap(UUID.init(uuidString:)) {
                    inboxWorkspaces[panel] = workspace
                }
                if let existing = index(name: name, panel: panel) {
                    recipients[existing].sentAt = recipients[existing].sentAt ?? at
                } else {
                    var recipient = Recipient(name: name, panelId: panel, sentAt: at)
                    recipient.usageLimit = row["recipient_usage_limit"] as? String
                    recipients.append(recipient)
                }
            case "rejected":
                report.state = .rejected
                report.rejectedReason = row["reason"] as? String
            case "handler":
                let handler = row["handler"] as? String
                if handler == "_copy" {
                    if let found = index(name: name, panel: panel) {
                        recipients[found].copyFailed = true
                    } else if let name {
                        var recipient = Recipient(name: name, panelId: panel)
                        recipient.copyFailed = true
                        recipients.append(recipient)
                    }
                    continue
                }
                guard handler == "stdin", let found = index(name: name, panel: panel) else { continue }
                apply(row: row, at: at, to: &recipients[found])
            case "claimed":
                claims.append((panel, (row["by_panel"] as? String).flatMap(UUID.init(uuidString:)), at))
            default:
                continue
            }
        }

        let filename = MailboxLayout.envelopeFilename(id: id)
        for index in recipients.indices {
            guard let panel = recipients[index].panelId, !recipients[index].copyFailed else { continue }
            // A shared view can dispatch from one workspace into its root
            // owner's inbox in another. Older rows retain the original root.
            let recipientRoot = inboxWorkspaces[panel].map { workspace in
                mailboxesRoot.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent(workspace.uuidString, isDirectory: true)
                    .appendingPathComponent(MailboxLayout.mailboxesDirectoryName, isDirectory: true)
            } ?? mailboxesRoot
            let inbox = recipientRoot.appendingPathComponent(MailboxLayout.inboxDirectoryName(panelId: panel), isDirectory: true)
            if fileManager.fileExists(atPath: inbox.appendingPathComponent(filename).path) {
                recipients[index].read = .unread
            } else if fileManager.fileExists(atPath: MailboxDrain.readURL(inbox: inbox).appendingPathComponent(filename).path) {
                let mine = claims.last { $0.recipient == panel }
                if let mine, let by = mine.by {
                    recipients[index].claimedBy = by
                    recipients[index].readAt = mine.at
                    recipients[index].read = by == panel ? .read : .taken
                } else {
                    recipients[index].readAt = mine?.at
                    recipients[index].read = .claimedUnknown
                }
            } else {
                recipients[index].read = .gone
            }
            // The recipient claimed it with no ring: its own read is the delivery.
            if recipients[index].read == .read, recipients[index].delivery != .delivered {
                recipients[index].delivery = .delivered
                recipients[index].deliveryReason = "claim"
                recipients[index].deliveryRoute = nil
                recipients[index].deliveredAt = recipients[index].readAt
            }
        }
        report.recipients = recipients
        return report
    }

    /// One stdin row's effect. Delivered sticks; otherwise the latest row decides.
    static func apply(row: [String: Any], at: Date?, to recipient: inout Recipient) {
        guard recipient.delivery != .delivered else { return }
        let outcome = row["outcome"] as? String ?? ""
        let reason = row["reason"] as? String
        func set(_ delivery: Delivery, _ why: String? = reason) {
            recipient.delivery = delivery
            recipient.deliveryReason = why
        }
        switch outcome {
        case "doorbell":
            switch reason {
            case "submitted", "stranded_return", "native_late_accept", "native_already_admitted":
                set(.delivered)
                recipient.deliveredAt = at
                recipient.deliveryRoute = row["route"] as? String
            default:
                set(.delivering)
                recipient.deliveryRoute = row["route"] as? String
            }
        case "doorbell_recheck":
            // `working_decay` waits on a turn edge, and `turnless_idle` on the
            // re-ring interval of a panel with no turn edges; neither is a
            // composer hold.
            if reason == "working_decay" {
                set(.pending, "working")
            } else if reason == "turnless_idle" {
                set(.pending, "turnless_idle")
            } else {
                set(.held)
            }
        case "doorbell_capped":
            set(.held, reason ?? "rate_capped")
        case "doorbell_failed":
            // A Claude chooser holds an unconfirmed invitation: held, not failed.
            if reason == "native_unconfirmed" { set(.held, "unconfirmed") } else { set(.failed) }
        case "doorbell_skipped":
            switch reason {
            case "draft", "dialog", "unknown_prompt", "stranded":
                set(.held)
            case "unavailable":
                // An unreadable or busy prompt read; retried like a hold.
                set(.held, "unknown_prompt")
            case "once_per_idle", "already_covered", "in_flight", "native_attempt_unconfirmed",
                 "operator_active", "input_transaction", "gate_closed", "input_unavailable", "agent_not_foreground":
                if [.notPushed, .pending, .notRung].contains(recipient.delivery) {
                    set(.pending)
                }
            default:
                set(.notRung)
            }
        case "buffered":
            set(.pending, "waiting_for_idle")
        case "skipped":
            // Already claimed by a drain: the read state says the rest.
            break
        case "closed":
            set(.notRung, outcome)
        case "eio", "timeout", "evicted", "expired":
            if recipient.delivery == .notPushed { set(.pending, outcome) }
        default:
            // The dispatcher's own handler row: the push is under way.
            if recipient.delivery == .notPushed { set(.pending, nil) }
        }
    }

    // MARK: - Timestamps

    static func parseTimestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// ISO-8601 with the local offset, for JSON a person may also read.
    static func localISO(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    // MARK: - Log scan

    /// Finds one envelope's rows in one dispatch log: a binary search to the
    /// first line at or after `since`, then a forward byte search for the id.
    final class LogScan {
        let url: URL
        let needle: Data
        let since: Date
        let chunkBytes: Int
        let budget: Int
        private(set) var scannedBytes = 0
        private(set) var hitBudget = false

        init(url: URL, id: String, since: Date, chunkBytes: Int, budget: Int) {
            self.url = url
            self.needle = Data("\"id\":\"\(id)\"".utf8)
            self.since = since
            self.chunkBytes = max(4096, chunkBytes)
            self.budget = budget
        }

        func run() -> [[String: Any]] {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd(), size > 0 else { return [] }
            var offset = startOffset(handle: handle, size: size)
            var rows: [[String: Any]] = []
            var carry = Data()
            while offset < size {
                guard scannedBytes < budget else { hitBudget = true; break }
                try? handle.seek(toOffset: offset)
                let want = min(UInt64(chunkBytes), size - offset)
                guard let chunk = try? handle.read(upToCount: Int(want)), !chunk.isEmpty else { break }
                offset += UInt64(chunk.count)
                scannedBytes += chunk.count
                var data = carry
                data.append(chunk)
                // Keep a trailing partial line for the next chunk.
                if offset < size {
                    guard let lastNewline = data.lastIndex(of: 0x0A) else {
                        carry = data
                        continue
                    }
                    carry = data.subdata(in: data.index(after: lastNewline)..<data.endIndex)
                    data = data.subdata(in: data.startIndex..<data.index(after: lastNewline))
                } else {
                    carry = Data()
                }
                rows.append(contentsOf: matches(in: data))
            }
            return rows
        }

        private func matches(in data: Data) -> [[String: Any]] {
            var rows: [[String: Any]] = []
            var searchStart = data.startIndex
            while searchStart < data.endIndex,
                  let hit = data.range(of: needle, options: [], in: searchStart..<data.endIndex) {
                let lineStart = data[data.startIndex..<hit.lowerBound].lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
                let lineEnd = data[hit.upperBound..<data.endIndex].firstIndex(of: 0x0A) ?? data.endIndex
                if let object = try? JSONSerialization.jsonObject(with: data.subdata(in: lineStart..<lineEnd)) as? [String: Any] {
                    rows.append(object)
                }
                searchStart = lineEnd
            }
            return rows
        }

        /// The byte offset of a line at or before the first line stamped at or
        /// after `since`. Lines are appended in time order by one writer per
        /// workspace, give or take the look-back.
        private func startOffset(handle: FileHandle, size: UInt64) -> UInt64 {
            var low: UInt64 = 0
            var high = size
            let probe = 64 * 1024
            while high - low > UInt64(probe) {
                let mid = low + (high - low) / 2
                guard let lineTs = firstTimestamp(handle: handle, at: mid, probe: probe) else {
                    high = mid
                    continue
                }
                if lineTs < since { low = mid } else { high = mid }
            }
            return low
        }

        private func firstTimestamp(handle: FileHandle, at offset: UInt64, probe: Int) -> Date? {
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: probe), !data.isEmpty else { return nil }
            var cursor = data.startIndex
            if offset > 0 {
                guard let newline = data.firstIndex(of: 0x0A) else { return nil }
                cursor = data.index(after: newline)
            }
            while cursor < data.endIndex, let end = data[cursor..<data.endIndex].firstIndex(of: 0x0A) {
                if let ts = Self.timestamp(ofLine: data.subdata(in: cursor..<end)) { return ts }
                cursor = data.index(after: end)
            }
            return nil
        }

        private static let tsKey = Data("\"ts\":\"".utf8)

        static func timestamp(ofLine line: Data) -> Date? {
            guard let key = line.range(of: tsKey) else { return nil }
            guard let close = line[key.upperBound..<line.endIndex].firstIndex(of: 0x22) else { return nil }
            guard let text = String(data: line.subdata(in: key.upperBound..<close), encoding: .utf8) else { return nil }
            return MailboxReceiptStatus.parseTimestamp(text)
        }
    }
}

/// C11-550: the `claimed` row a drain appends to the dispatch log of the
/// workspace whose inbox held the mail. `by_panel` is the claiming process's
/// panel (or the inbox owner for an authenticated shared OpenCode view), so
/// a receipt can tell the recipient's own read from another panel
/// draining its inbox. The file is opened `O_APPEND`, so this line and the
/// dispatcher's rows never overwrite each other.
enum MailboxClaimLog {

    /// The panel the calling process runs in, from its environment.
    static func callerPanelId(_ env: [String: String] = ProcessInfo.processInfo.environment) -> UUID? {
        // Same keys and order as the CLI's `callerPanelEnv`.
        for key in ["C11_PANEL_ID", "C11_TAB_ID", "C11_SURFACE_ID", "CMUX_PANEL_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID"] {
            let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return UUID(uuidString: value) }
        }
        return nil
    }

    static func line(id: String, recipientPanel: UUID?, byPanel: UUID?, via: String, at now: Date) -> String {
        var payload: [String: Any] = [
            "event": "claimed",
            "id": id,
            "via": via,
            "ts": timestamp(now),
        ]
        if let recipientPanel { payload["recipient_panel"] = recipientPanel.uuidString.lowercased() }
        if let byPanel { payload["by_panel"] = byPanel.uuidString.lowercased() }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text + "\n"
    }

    /// Appends one `claimed` row per claimed id. Best effort: a failed write
    /// loses only the receipt detail, never the mail.
    static func append(
        ids: [String],
        recipientPanel: UUID?,
        byPanel: UUID?,
        via: String,
        mailboxesRoot: URL,
        now: Date = Date()
    ) {
        guard !ids.isEmpty else { return }
        let url = mailboxesRoot.appendingPathComponent(MailboxLayout.dispatchLogFileName, isDirectory: false)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        for id in ids {
            let bytes = Array(line(id: id, recipientPanel: recipientPanel, byPanel: byPanel, via: via, at: now).utf8)
            guard !bytes.isEmpty else { continue }
            _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

// MARK: - Output

extension MailboxReceiptStatus.Report {

    /// The `--json` document. Times are ISO-8601 with the local offset; no body.
    func jsonObject(timeZone: TimeZone = .current) -> [String: Any] {
        func time(_ date: Date?) -> Any {
            date.map { MailboxReceiptStatus.localISO($0, timeZone: timeZone) } ?? NSNull()
        }
        func value(_ text: String?) -> Any { text ?? NSNull() }
        return [
            "id": id,
            "workspace_id": workspaceId?.uuidString as Any? ?? NSNull(),
            "state": state.rawValue,
            "from": value(from),
            "to": value(to),
            "topic": value(topic),
            "accepted_at": time(acceptedAt),
            "rejected_reason": value(rejectedReason),
            "scanned_bytes": scannedBytes,
            "scan_truncated": scanTruncated,
            "recipients": recipients.map { recipient -> [String: Any] in
                [
                    "name": recipient.name,
                    "panel_id": recipient.panelId?.uuidString as Any? ?? NSNull(),
                    "sent": recipient.sentAt != nil && !recipient.copyFailed,
                    "sent_at": time(recipient.sentAt),
                    "delivered": recipient.delivery == .delivered,
                    "delivery": recipient.delivery.rawValue,
                    "delivery_reason": value(recipient.deliveryReason),
                    "delivery_route": value(recipient.deliveryRoute),
                    "delivered_at": time(recipient.deliveredAt),
                    "read": recipient.read == .read,
                    "read_state": recipient.read.rawValue,
                    "read_at": time(recipient.readAt),
                    "claimed_by_panel_id": recipient.claimedBy?.uuidString as Any? ?? NSNull(),
                    "usage_limit": value(recipient.usageLimit),
                ]
            },
        ]
    }

    /// Plain lines for a person: one block per recipient, local times.
    func humanText(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let clock = MailboxReceiptStatus.Clock(now: now, timeZone: timeZone)
        var lines: [String] = []
        var head = id
        if let from { head += "  from \(from)" }
        if let to { head += "  to \(to)" }
        if let topic { head += "  topic \(topic)" }
        lines.append(head)
        switch state {
        case .queued:
            lines.append(String(
                localized: "mailbox.status.queued",
                defaultValue: "queued: waiting in an outbox; c11 has not dispatched it yet"
            ))
        case .rejected:
            let reason = rejectedReason ?? "-"
            lines.append(String(
                localized: "mailbox.status.rejected",
                defaultValue: "rejected: \(reason)"
            ))
        case .sent:
            if recipients.isEmpty {
                lines.append(String(
                    localized: "mailbox.status.noRecipients",
                    defaultValue: "sent to no recipients"
                ))
            }
        }
        for recipient in recipients {
            let panel = recipient.panelId.map { " (\($0.uuidString.lowercased()))" } ?? ""
            lines.append("\(recipient.name)\(panel)")
            lines.append("  " + sentLine(recipient, clock))
            lines.append("  " + deliveredLine(recipient, clock))
            lines.append("  " + readLine(recipient, clock))
        }
        if scanTruncated {
            lines.append(String(
                localized: "mailbox.status.truncated",
                defaultValue: "note: the scan limit was reached; some rows may be missing"
            ))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func sentLine(_ recipient: MailboxReceiptStatus.Recipient, _ clock: MailboxReceiptStatus.Clock) -> String {
        if recipient.copyFailed {
            return String(localized: "mailbox.status.sent.failed", defaultValue: "sent       no, the inbox copy failed")
        }
        let at = clock.text(recipient.sentAt)
        return String(localized: "mailbox.status.sent.at", defaultValue: "sent       \(at)")
    }

    private func deliveredLine(_ recipient: MailboxReceiptStatus.Recipient, _ clock: MailboxReceiptStatus.Clock) -> String {
        let reason = recipient.deliveryReason ?? "-"
        switch recipient.delivery {
        case .delivered:
            let at = clock.text(recipient.deliveredAt)
            let via = recipient.deliveryRoute ?? reason
            return String(localized: "mailbox.status.delivered.at", defaultValue: "delivered  \(at) via \(via)")
        case .delivering:
            return String(localized: "mailbox.status.delivered.delivering", defaultValue: "delivered  no, the doorbell is being typed")
        case .held:
            let sentence = MailboxHoldNotice.sentence(outcome: "doorbell_recheck", reason: reason)
                ?? (reason == "unconfirmed"
                    ? String(localized: "mailbox.status.held.unconfirmed",
                             defaultValue: "held: the recipient has not confirmed the invitation (a chooser may be open)")
                    : String(localized: "mailbox.status.held.reason", defaultValue: "held: \(reason)"))
            return String(localized: "mailbox.status.delivered.held", defaultValue: "delivered  no, \(sentence)")
        case .pending:
            return String(localized: "mailbox.status.delivered.pending", defaultValue: "delivered  no, waiting for the recipient's next idle prompt")
        case .failed:
            return String(localized: "mailbox.status.delivered.failed", defaultValue: "delivered  no, the last attempt failed (\(reason)); c11 tries again")
        case .notRung:
            return String(localized: "mailbox.status.delivered.notRung", defaultValue: "delivered  no, the doorbell does not ring this panel (\(reason))")
        case .notPushed:
            return String(localized: "mailbox.status.delivered.notPushed", defaultValue: "delivered  no push; the mail waits in the inbox")
        }
    }

    private func readLine(_ recipient: MailboxReceiptStatus.Recipient, _ clock: MailboxReceiptStatus.Clock) -> String {
        switch recipient.read {
        case .read:
            let at = clock.text(recipient.readAt)
            return String(localized: "mailbox.status.read.at", defaultValue: "read       \(at)")
        case .unread:
            return String(localized: "mailbox.status.read.unread", defaultValue: "read       no")
        case .taken:
            let by = recipient.claimedBy?.uuidString.lowercased() ?? "-"
            let at = clock.text(recipient.readAt)
            return String(localized: "mailbox.status.read.taken", defaultValue: "read       no, taken by panel \(by) at \(at)")
        case .claimedUnknown:
            return String(localized: "mailbox.status.read.claimedUnknown", defaultValue: "read       claimed, by a panel c11 did not record")
        case .gone:
            return String(localized: "mailbox.status.read.gone", defaultValue: "read       no, the copy is gone (swept or expired)")
        case .unknown:
            return String(localized: "mailbox.status.read.unknown", defaultValue: "read       unknown; this copy predates receipts")
        }
    }
}

extension MailboxReceiptStatus {
    /// Local wall time: the clock alone today, the date too otherwise.
    struct Clock {
        let now: Date
        let timeZone: TimeZone

        func text(_ date: Date?) -> String {
            guard let date else { return "-" }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm:ss zzz" : "yyyy-MM-dd HH:mm:ss zzz"
            return formatter.string(from: date)
        }
    }
}
