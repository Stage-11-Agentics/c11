import Foundation

/// The c11-owned location of the live agent-traffic page.
enum MessagesPageLayout {
    static let directoryName = "messages"
    static let fileName = "messages.html"

    private static let productionBundleIdentifier = "com.stage11.c11"

    static func directoryURL(state: URL) -> URL {
        state.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func pageURL(
        state: URL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> URL {
        directoryURL(state: state).appendingPathComponent(
            pageFileName(bundleIdentifier: bundleIdentifier),
            isDirectory: false
        )
    }

    static func defaultPageURL() throws -> URL {
        pageURL(state: try EventLogLayout.defaultStateURL())
    }

    static func pageFileName(bundleIdentifier: String?) -> String {
        guard let bundleIdentifier,
              !bundleIdentifier.isEmpty,
              bundleIdentifier != productionBundleIdentifier else {
            return fileName
        }
        let safeBundleIdentifier = bundleIdentifier.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return "messages-\(safeBundleIdentifier.isEmpty ? "c11" : safeBundleIdentifier).html"
    }

    static func isMessagesPageURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let name = url.lastPathComponent
        let isPage = name == fileName
            || (name.hasPrefix("messages-") && name.hasSuffix(".html"))
        return isPage && url.deletingLastPathComponent().lastPathComponent == directoryName
    }
}

/// One decoded line from the event stream (v1 or v2). The page deliberately keeps the
/// payload as JSON values so a new mailbox field can be displayed before the
/// page writer needs a schema migration of its own. `type` holds the canonical
/// (v2) spelling and `surface` the subject panel from either envelope key.
struct MessagesPageEvent {
    let instance: String?
    let sequence: UInt64?
    let timestamp: String
    let type: String
    let workspace: String?
    let surface: String?
    let payload: [String: Any]

    init?(line: String) {
        guard let data = line.data(using: .utf8) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        self.init(object: dictionary)
    }

    init?(object: [String: Any]) {
        guard let timestamp = MessagesPageJSON.string(object["ts"]),
              let type = MessagesPageJSON.string(object["type"]) else {
            return nil
        }
        self.instance = MessagesPageJSON.string(object["instance"])
        self.sequence = MessagesPageJSON.uint64(object["seq"])
        self.timestamp = timestamp
        // C11-337: v1 lines (`tab.input_sent`, `surface`) are read as their v2 forms.
        self.type = EventEnvelope.canonicalType(type)
        self.workspace = MessagesPageJSON.string(object["workspace"])
        self.surface = EventEnvelope.panelRef(in: object)
        self.payload = object["payload"] as? [String: Any] ?? [:]
    }
}

struct MessagesPageLifecycle: Equatable {
    let state: String
    let timestamp: String
    let detail: String?

    var jsonObject: [String: Any] {
        var result: [String: Any] = [
            "state": state,
            "timestamp": timestamp,
        ]
        if let detail, !detail.isEmpty {
            result["detail"] = detail
        }
        return result
    }
}

/// The stable data shape embedded in messages.html. It intentionally has one
/// record type for both explicit sends and mailbox traffic so the first page is
/// useful before the final visual design is chosen.
struct MessagesPageRecord: Equatable {
    var id: String
    var channel: String
    var timestamp: String
    var sequence: UInt64?
    var workspace: String?
    var surface: String?
    var sender: String?
    var senderID: String?
    var callerTitle: String?
    var recipient: String?
    var targetTitle: String?
    var kind: String?
    var topic: String?
    var body: String
    var bodyRef: String?
    var replyTo: String?
    var inReplyTo: String?
    var urgent: Bool?
    var submitted: Bool?
    var queued: Bool?
    var truncated: Bool
    var status: String
    var lifecycle: [MessagesPageLifecycle]

    var jsonObject: [String: Any] {
        var result: [String: Any] = [
            "id": id,
            "channel": channel,
            "timestamp": timestamp,
            "body": body,
            "truncated": truncated,
            "status": status,
            "lifecycle": lifecycle.map(\.jsonObject),
        ]
        if let sequence { result["sequence"] = sequence }
        if let workspace { result["workspace"] = workspace }
        if let surface { result["surface"] = surface }
        if let sender { result["sender"] = sender }
        if let senderID { result["sender_id"] = senderID }
        if channel == "send" {
            result["caller_title"] = callerTitle ?? NSNull()
            result["caller_tab_id"] = senderID ?? NSNull()
        }
        if let recipient { result["recipient"] = recipient }
        if let targetTitle { result["target_title"] = targetTitle }
        if let kind { result["kind"] = kind }
        if let topic { result["topic"] = topic }
        if let bodyRef { result["body_ref"] = bodyRef }
        if let replyTo { result["reply_to"] = replyTo }
        if let inReplyTo { result["in_reply_to"] = inReplyTo }
        if let urgent { result["urgent"] = urgent }
        if let submitted { result["submitted"] = submitted }
        if let queued { result["queued"] = queued }
        return result
    }
}

struct MessagesPageSnapshot: Equatable {
    let generatedAt: String
    let totalObserved: Int
    let messageLimit: Int
    let messageByteLimit: Int
    let estimatedMessageBytes: Int
    let messages: [MessagesPageRecord]

    var wasBounded: Bool {
        totalObserved > messages.count || estimatedMessageBytes > messageByteLimit
    }

    var wasByteBounded: Bool {
        estimatedMessageBytes > messageByteLimit
    }

    var jsonObject: [String: Any] {
        var channels: [String: Int] = [:]
        var statuses: [String: Int] = [:]
        var workspaces: [String: Int] = [:]
        var edges: [String: Int] = [:]

        for message in messages {
            channels[message.channel, default: 0] += 1
            statuses[message.status, default: 0] += 1
            if let workspace = message.workspace {
                workspaces[workspace, default: 0] += 1
            }
            if let sender = message.sender, let recipient = message.recipient {
                let edge = "\(sender) → \(recipient)"
                edges[edge, default: 0] += 1
            }
        }

        return [
            "schema": 1,
            "generated_at": generatedAt,
            "total_observed": totalObserved,
            "message_limit": messageLimit,
            "message_byte_limit": messageByteLimit,
            "estimated_message_bytes": estimatedMessageBytes,
            "bounded": wasBounded,
            "summary": [
                "channels": channels,
                "statuses": statuses,
                "workspaces": workspaces,
                "edges": edges,
            ],
            "messages": messages.map(\.jsonObject),
        ]
    }

    func replacingMessages(_ messages: [MessagesPageRecord]) -> MessagesPageSnapshot {
        MessagesPageSnapshot(
            generatedAt: generatedAt,
            totalObserved: totalObserved,
            messageLimit: messageLimit,
            messageByteLimit: messageByteLimit,
            estimatedMessageBytes: MessagesPageBuilder.estimatedPageBytes(for: messages),
            messages: messages
        )
    }
}

/// A mailbox file or dispatch-log entry found while rebuilding the page.
struct MessagesPageMailboxArtifact {
    let workspace: String?
    let id: String
    let timestamp: String?
    let from: String?
    let to: String?
    let body: String?
    let bodyRef: String?
    let topic: String?
    let replyTo: String?
    let inReplyTo: String?
    let urgent: Bool?
    let truncated: Bool
    let fileState: String?
    let lifecycle: [MessagesPageLifecycle]
}

struct MessagesPageSourceData {
    let events: [MessagesPageEvent]
    let mailboxArtifacts: [MessagesPageMailboxArtifact]
}

private enum MessagesPageJSON {
    static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? String
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    static func uint64(_ value: Any?) -> UInt64? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber, number.int64Value >= 0 {
            return number.uint64Value
        }
        if let string = value as? String { return UInt64(string) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

private enum MessagesPageDates {
    static func now() -> String {
        format(Date())
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

enum MessagesPageBuilder {
    static let defaultMessageLimit = 10_000
    /// Keep the self-contained file in the tens-of-megabytes range even when
    /// individual event bodies approach Lane A's 256 KiB envelope limit.
    static let defaultMessageByteLimit = 16 * 1024 * 1024
    /// Reserve the fixed HTML, script, and snapshot-summary bytes before
    /// admitting records. The renderer still measures the complete output and
    /// trims by that exact measurement, but this keeps the common path to one
    /// render and makes the selection safe before HTML escaping is applied.
    static let pageOverheadByteAllowance = 128 * 1024
    /// Leave room for the per-record keys, lifecycle, routing metadata, and
    /// summary edges in addition to the escaped record JSON. Body text can
    /// expand to six bytes per raw byte when embedded in the script element.
    static let perMessageByteAllowance = 4 * 1024

    static func build(
        events: [MessagesPageEvent],
        mailboxArtifacts: [MessagesPageMailboxArtifact] = [],
        generatedAt: String = MessagesPageDates.now(),
        messageLimit: Int = defaultMessageLimit,
        messageByteLimit: Int = defaultMessageByteLimit
    ) -> MessagesPageSnapshot {
        var sends: [MessagesPageRecord] = []
        var mailbox: [String: MessagesPageRecord] = [:]

        for artifact in mailboxArtifacts {
            merge(artifact: artifact, into: &mailbox)
        }

        for (index, event) in events.enumerated() {
            if event.type == EventEnvelope.EventType.panelInputSent.rawValue {
                sends.append(makeSendRecord(event: event, fallbackIndex: index))
            } else if event.type.hasPrefix("mailbox.") {
                merge(mailboxEvent: event, into: &mailbox)
            }
        }

        let observed = (sends + Array(mailbox.values)).sorted(by: orderedBefore)
        let limit = max(1, messageLimit)
        let byteLimit = max(1, messageByteLimit)
        let candidates = observed.count > limit ? Array(observed.suffix(limit)) : observed
        var messages: [MessagesPageRecord] = []
        var estimatedBytes = pageOverheadByteAllowance
        for message in candidates.reversed() {
            let messageBytes = estimatedJSONBytes(for: message)
            // A single pathological record must not stop older, smaller
            // history from being considered. The renderer's exact pass will
            // enforce the final page bound after this conservative filter.
            if messageBytes > byteLimit {
                continue
            }
            if !messages.isEmpty && estimatedBytes + messageBytes > byteLimit {
                break
            }
            messages.append(message)
            estimatedBytes += messageBytes
        }
        messages.reverse()
        return MessagesPageSnapshot(
            generatedAt: generatedAt,
            totalObserved: observed.count,
            messageLimit: limit,
            messageByteLimit: byteLimit,
            estimatedMessageBytes: estimatedBytes,
            messages: messages
        )
    }

    static func estimatedPageBytes(for messages: [MessagesPageRecord]) -> Int {
        pageOverheadByteAllowance + messages.reduce(into: 0) { total, message in
            total += estimatedJSONBytes(for: message)
        }
    }

    private static func estimatedJSONBytes(for message: MessagesPageRecord) -> Int {
        // Measure the actual encoded record, then apply the same one-pass
        // escaping expansion used by the renderer. In particular, '<', '>',
        // and '&' each become a six-byte JSON escape inside the script tag.
        let encoded = (try? JSONSerialization.data(
            withJSONObject: message.jsonObject,
            options: [.sortedKeys]
        )) ?? Data()
        return MessagesPageRenderer.escapedJSONByteCount(encoded) + perMessageByteAllowance
    }

    private static func makeSendRecord(event: MessagesPageEvent, fallbackIndex: Int) -> MessagesPageRecord {
        let payload = event.payload
        let callerID = EventEnvelope.callerPanelId(inPayload: payload)
        let callerTitle = MessagesPageJSON.string(payload["caller_title"])
        let targetTitle = MessagesPageJSON.string(payload["target_title"])
        let submitted = MessagesPageJSON.bool(payload["submitted"])
        let queued = MessagesPageJSON.bool(payload["queued"])
        let kind = MessagesPageJSON.string(payload["kind"])
        let state: String
        if queued == true {
            state = "queued"
        } else if submitted == true {
            state = "submitted"
        } else {
            state = "sent"
        }
        let eventIdentity = event.instance ?? "unknown"
        let sequence = event.sequence.map(String.init) ?? String(fallbackIndex)
        let sender = callerTitle ?? callerID.map { "panel:\($0)" } ?? "unknown caller"

        return MessagesPageRecord(
            id: "send:\(eventIdentity):\(sequence)",
            channel: "send",
            timestamp: event.timestamp,
            sequence: event.sequence,
            workspace: event.workspace,
            surface: event.surface,
            sender: sender,
            senderID: callerID,
            callerTitle: callerTitle,
            recipient: targetTitle ?? event.surface,
            targetTitle: targetTitle,
            kind: kind,
            topic: nil,
            body: MessagesPageJSON.string(payload["text"]) ?? "",
            bodyRef: nil,
            replyTo: nil,
            inReplyTo: nil,
            urgent: nil,
            submitted: submitted,
            queued: queued,
            truncated: MessagesPageJSON.bool(payload["truncated"]) ?? false,
            status: state,
            lifecycle: [
                MessagesPageLifecycle(state: state, timestamp: event.timestamp, detail: kind)
            ]
        )
    }

    private static func merge(artifact: MessagesPageMailboxArtifact, into mailbox: inout [String: MessagesPageRecord]) {
        var record = mailbox[artifact.id] ?? MessagesPageRecord(
            id: artifact.id,
            channel: "mailbox",
            timestamp: artifact.timestamp ?? "",
            sequence: nil,
            workspace: artifact.workspace,
            surface: nil,
            sender: artifact.from,
            senderID: nil,
            callerTitle: nil,
            recipient: artifact.to,
            targetTitle: artifact.to,
            kind: nil,
            topic: artifact.topic,
            body: artifact.body ?? "",
            bodyRef: artifact.bodyRef,
            replyTo: artifact.replyTo,
            inReplyTo: artifact.inReplyTo,
            urgent: artifact.urgent,
            submitted: nil,
            queued: nil,
            truncated: artifact.truncated,
            status: artifact.fileState ?? "observed",
            lifecycle: []
        )

        record.channel = "mailbox"
        if record.timestamp.isEmpty { record.timestamp = artifact.timestamp ?? "" }
        if record.workspace == nil { record.workspace = artifact.workspace }
        if record.sender == nil { record.sender = artifact.from }
        if record.recipient == nil { record.recipient = artifact.to }
        if record.targetTitle == nil { record.targetTitle = artifact.to }
        if record.topic == nil { record.topic = artifact.topic }
        if record.body.isEmpty, let body = artifact.body { record.body = body }
        if record.bodyRef == nil { record.bodyRef = artifact.bodyRef }
        if record.replyTo == nil { record.replyTo = artifact.replyTo }
        if record.inReplyTo == nil { record.inReplyTo = artifact.inReplyTo }
        if record.urgent == nil { record.urgent = artifact.urgent }
        record.truncated = record.truncated || artifact.truncated
        if let fileState = artifact.fileState {
            record.status = mergedStatus(record.status, fileState)
        }
        append(lifecycle: artifact.lifecycle, to: &record)
        mailbox[artifact.id] = record
    }

    private static func merge(mailboxEvent event: MessagesPageEvent, into mailbox: inout [String: MessagesPageRecord]) {
        let payload = event.payload
        let suffix = event.type.dropFirst("mailbox.".count)
        let id = MessagesPageJSON.string(payload["id"])
            ?? "mailbox:\(event.instance ?? "unknown"):\(event.sequence.map(String.init) ?? event.timestamp)"
        var record = mailbox[id] ?? MessagesPageRecord(
            id: id,
            channel: "mailbox",
            timestamp: event.timestamp,
            sequence: event.sequence,
            workspace: event.workspace,
            surface: event.surface,
            sender: nil,
            senderID: nil,
            callerTitle: nil,
            recipient: nil,
            targetTitle: nil,
            kind: nil,
            topic: nil,
            body: "",
            bodyRef: nil,
            replyTo: nil,
            inReplyTo: nil,
            urgent: nil,
            submitted: nil,
            queued: nil,
            truncated: false,
            status: "observed",
            lifecycle: []
        )

        record.channel = "mailbox"
        if record.timestamp.isEmpty || event.timestamp < record.timestamp {
            record.timestamp = event.timestamp
        }
        if record.sequence == nil { record.sequence = event.sequence }
        if record.workspace == nil { record.workspace = event.workspace }
        if record.surface == nil { record.surface = event.surface }

        switch suffix {
        case "accepted":
            record.sender = record.sender ?? MessagesPageJSON.string(payload["from"])
            record.recipient = record.recipient ?? MessagesPageJSON.string(payload["to"])
            record.targetTitle = record.targetTitle ?? MessagesPageJSON.string(payload["to"])
            record.body = record.body.isEmpty ? (MessagesPageJSON.string(payload["body"]) ?? "") : record.body
            record.bodyRef = record.bodyRef ?? MessagesPageJSON.string(payload["body_ref"])
            record.topic = record.topic ?? MessagesPageJSON.string(payload["topic"])
            record.replyTo = record.replyTo ?? MessagesPageJSON.string(payload["reply_to"])
            record.inReplyTo = record.inReplyTo ?? MessagesPageJSON.string(payload["in_reply_to"])
            record.urgent = record.urgent ?? MessagesPageJSON.bool(payload["urgent"])
            record.truncated = record.truncated || (MessagesPageJSON.bool(payload["truncated"]) ?? false)
            record.status = mergedStatus(record.status, "accepted")
            append(
                lifecycle: [MessagesPageLifecycle(state: "accepted", timestamp: event.timestamp, detail: nil)],
                to: &record
            )
        case "delivered":
            record.recipient = record.recipient ?? MessagesPageJSON.string(payload["recipient"])
            record.targetTitle = record.targetTitle ?? MessagesPageJSON.string(payload["recipient"])
            record.status = mergedStatus(record.status, "delivered")
            append(
                lifecycle: [
                    MessagesPageLifecycle(
                        state: "delivered",
                        timestamp: event.timestamp,
                        detail: MessagesPageJSON.string(payload["via"])
                    )
                ],
                to: &record
            )
        default:
            let detail = MessagesPageJSON.string(payload["reason"])
                ?? MessagesPageJSON.string(payload["via"])
            let state = suffix.isEmpty ? "mailbox" : String(suffix)
            record.status = mergedStatus(record.status, state)
            append(
                lifecycle: [MessagesPageLifecycle(state: state, timestamp: event.timestamp, detail: detail)],
                to: &record
            )
        }

        mailbox[id] = record
    }

    private static func append(lifecycle: [MessagesPageLifecycle], to record: inout MessagesPageRecord) {
        for item in lifecycle where !record.lifecycle.contains(item) {
            record.lifecycle.append(item)
        }
        record.lifecycle.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.state < $1.state
        }
    }

    private static func mergedStatus(_ current: String, _ candidate: String) -> String {
        let priority: [String: Int] = [
            "observed": 0,
            "outbox": 1,
            "pending": 2,
            "accepted": 3,
            "read": 4,
            "delivered": 5,
            "rejected": 6,
        ]
        return (priority[candidate] ?? 3) >= (priority[current] ?? 3) ? candidate : current
    }

    private static func orderedBefore(_ lhs: MessagesPageRecord, _ rhs: MessagesPageRecord) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.sequence != rhs.sequence {
            switch (lhs.sequence, rhs.sequence) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
        }
        return lhs.id < rhs.id
    }
}

struct MessagesPageEventLogCache {
    fileprivate var eventsByURL: [URL: [MessagesPageEvent]] = [:]
    fileprivate var signatures: [URL: MessagesPageEventLogSignature] = [:]
}

fileprivate struct MessagesPageEventLogSignature: Equatable {
    let fileSize: Int
    let modificationDate: Date?
}

enum MessagesPageSource {
    /// Raw-byte prefilters for the send event: the v2 spelling and the v1
    /// spelling old logs keep (C11-337).
    private static let sendEventMarkers = [
        Data(#""type":"panel.input_sent""#.utf8),
        Data(#""type":"tab.input_sent""#.utf8),
    ]
    private static let mailboxEventMarker = Data(#""type":"mailbox."#.utf8)

    private struct DispatchHistory {
        var lifecycle: [MessagesPageLifecycle] = []
        var from: String?
        var to: String?
    }

    static func load(stateURL: URL, fileManager: FileManager = .default) -> MessagesPageSourceData {
        var eventLogCache = MessagesPageEventLogCache()
        return load(
            stateURL: stateURL,
            fileManager: fileManager,
            eventLogCache: &eventLogCache
        )
    }

    static func load(
        stateURL: URL,
        fileManager: FileManager = .default,
        eventLogCache: inout MessagesPageEventLogCache,
        mailboxArtifacts: [MessagesPageMailboxArtifact]? = nil
    ) -> MessagesPageSourceData {
        MessagesPageSourceData(
            events: readEvents(
                stateURL: stateURL,
                fileManager: fileManager,
                eventLogCache: &eventLogCache
            ),
            mailboxArtifacts: mailboxArtifacts
                ?? readMailboxArtifacts(stateURL: stateURL, fileManager: fileManager)
        )
    }

    private static func readEvents(
        stateURL: URL,
        fileManager: FileManager,
        eventLogCache: inout MessagesPageEventLogCache
    ) -> [MessagesPageEvent] {
        let directory = EventLogLayout.eventsDirectoryURL(state: stateURL)
        let urls = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix(EventLogLayout.logFilePrefix)
                    && (name.hasSuffix(".ndjson") || name.hasSuffix(".ndjson.1"))
            }
            .sorted { $0.path < $1.path }

        let currentURLs = Set(urls)
        eventLogCache.eventsByURL = eventLogCache.eventsByURL.filter { currentURLs.contains($0.key) }
        eventLogCache.signatures = eventLogCache.signatures.filter { currentURLs.contains($0.key) }

        var events: [MessagesPageEvent] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let signature = MessagesPageEventLogSignature(
                fileSize: values?.fileSize ?? -1,
                modificationDate: values?.contentModificationDate
            )
            if eventLogCache.signatures[url] == signature,
               let cachedEvents = eventLogCache.eventsByURL[url] {
                events.append(contentsOf: cachedEvents)
                continue
            }

            var parsedEvents: [MessagesPageEvent] = []
            guard let data = try? Data(contentsOf: url),
                  containsSendMarker(data) || data.range(of: mailboxEventMarker) != nil else {
                eventLogCache.signatures[url] = signature
                eventLogCache.eventsByURL[url] = []
                continue
            }
            // Event logs contain many lifecycle/UI records that the page does
            // not consume. Check the raw line for a message type before
            // invoking JSONSerialization, and cache only decoded message
            // events. This keeps a qualifying 8 MiB log from turning into a
            // retained dictionary for every unrelated event.
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard containsSendMarker(line)
                        || line.range(of: mailboxEventMarker) != nil else { continue }
                if let event = MessagesPageEvent(data: Data(line)) {
                    guard event.type == EventEnvelope.EventType.panelInputSent.rawValue
                            || event.type.hasPrefix("mailbox.") else {
                        continue
                    }
                    parsedEvents.append(event)
                }
            }
            eventLogCache.signatures[url] = signature
            eventLogCache.eventsByURL[url] = parsedEvents
            events.append(contentsOf: parsedEvents)
        }
        return events
    }

    private static func containsSendMarker(_ bytes: Data) -> Bool {
        sendEventMarkers.contains { bytes.range(of: $0) != nil }
    }

    /// Reads every envelope tree below each workspace mailbox root, not just
    /// the current event-log window. In particular, the undrained inbox,
    /// recipient `_read/` history, and root or nested `_rejected/` quarantine
    /// files are the durable source for older bodies after event-log rotation.
    private static func readMailboxArtifacts(stateURL: URL, fileManager: FileManager) -> [MessagesPageMailboxArtifact] {
        let workspaces = stateURL.appendingPathComponent(MailboxLayout.workspacesDirectoryName, isDirectory: true)
        let workspaceURLs = ((try? fileManager.contentsOfDirectory(at: workspaces, includingPropertiesForKeys: nil)) ?? [])
            .filter { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }

        var artifacts: [MessagesPageMailboxArtifact] = []
        for workspaceURL in workspaceURLs {
            let mailboxRoot = workspaceURL.appendingPathComponent(MailboxLayout.mailboxesDirectoryName, isDirectory: true)
            guard fileManager.fileExists(atPath: mailboxRoot.path) else { continue }
            let dispatch = readDispatchLog(
                at: mailboxRoot.appendingPathComponent(MailboxLayout.dispatchLogFileName),
                fileManager: fileManager
            )
            var seenIDs = Set<String>()
            if let enumerator = fileManager.enumerator(at: mailboxRoot, includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator where url.pathExtension == MailboxLayout.envelopeExtension {
                    let id = url.deletingPathExtension().lastPathComponent
                    guard !id.isEmpty else { continue }
                    // B/C may atomically move an envelope while this rebuild
                    // walks the tree. Do not publish a synthetic body-less
                    // pending record for a file that disappeared or could not
                    // be decoded during that race.
                    guard fileManager.fileExists(atPath: url.path),
                          let object = jsonObject(at: url, fileManager: fileManager) else {
                        continue
                    }
                    let state = fileState(for: url)
                    let artifact = mailboxArtifact(
                        object: object,
                        workspace: workspaceURL.lastPathComponent,
                        id: id,
                        state: state,
                        dispatch: dispatch[id]
                    )
                    artifacts.append(artifact)
                    seenIDs.insert(id)
                }
            }

            for (id, history) in dispatch where !seenIDs.contains(id) {
                let state = history.lifecycle.last?.state == "rejected" ? "rejected" : nil
                artifacts.append(
                    MessagesPageMailboxArtifact(
                        workspace: workspaceURL.lastPathComponent,
                        id: id,
                        timestamp: history.lifecycle.first?.timestamp,
                        from: history.from,
                        to: history.to,
                        body: nil,
                        bodyRef: nil,
                        topic: nil,
                        replyTo: nil,
                        inReplyTo: nil,
                        urgent: nil,
                        truncated: false,
                        fileState: state,
                        lifecycle: history.lifecycle
                    )
                )
            }
        }
        return artifacts
    }

    private static func mailboxArtifact(
        object: [String: Any]?,
        workspace: String,
        id: String,
        state: String,
        dispatch: DispatchHistory?
    ) -> MessagesPageMailboxArtifact {
        let object = object ?? [:]
        let body = boundedDurableBody(MessagesPageJSON.string(object["body"]))
        return MessagesPageMailboxArtifact(
            workspace: workspace,
            id: MessagesPageJSON.string(object["id"]) ?? id,
            timestamp: MessagesPageJSON.string(object["ts"]),
            from: MessagesPageJSON.string(object["from"]) ?? dispatch?.from,
            to: MessagesPageJSON.string(object["to"]) ?? dispatch?.to,
            body: body.value,
            bodyRef: MessagesPageJSON.string(object["body_ref"]),
            topic: MessagesPageJSON.string(object["topic"]),
            replyTo: MessagesPageJSON.string(object["reply_to"]),
            inReplyTo: MessagesPageJSON.string(object["in_reply_to"]),
            urgent: MessagesPageJSON.bool(object["urgent"]),
            truncated: body.truncated,
            fileState: state,
            lifecycle: dispatch?.lifecycle ?? []
        )
    }

    private static func boundedDurableBody(_ body: String?) -> (value: String?, truncated: Bool) {
        guard let body else { return (nil, false) }
        let bodyBytes = body.utf8
        guard bodyBytes.count > 256 * 1024 else { return (body, false) }
        return (
            String(decoding: bodyBytes.prefix(256 * 1024), as: UTF8.self),
            true
        )
    }

    private static func jsonObject(at url: URL, fileManager: FileManager) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    private static func fileState(for url: URL) -> String {
        let names = Set(url.pathComponents)
        if names.contains(MailboxLayout.rejectedDirectoryName) { return "rejected" }
        if names.contains("_read") { return "read" }
        if names.contains(MailboxLayout.outboxDirectoryName) { return "outbox" }
        if names.contains(MailboxLayout.processingDirectoryName) { return "processing" }
        return "pending"
    }

    private static func readDispatchLog(
        at url: URL,
        fileManager: FileManager
    ) -> [String: DispatchHistory] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: DispatchHistory] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  let id = MessagesPageJSON.string(dictionary["id"]),
                  let event = MessagesPageJSON.string(dictionary["event"]) else { continue }
            let timestamp = MessagesPageJSON.string(dictionary["ts"]) ?? ""
            var history = result[id] ?? DispatchHistory()
            if let from = MessagesPageJSON.string(dictionary["from"]) {
                history.from = from
            }
            if let to = MessagesPageJSON.string(dictionary["to"])
                ?? MessagesPageJSON.string(dictionary["recipient"]) {
                history.to = to
            }
            let detail: String?
            if event == "handler" {
                let handler = MessagesPageJSON.string(dictionary["handler"])
                let outcome = MessagesPageJSON.string(dictionary["outcome"])
                detail = [handler, outcome].compactMap { $0 }.joined(separator: ": ")
            } else if event == "resolved",
                      let recipients = dictionary["recipients"] as? [String] {
                detail = recipients.joined(separator: ", ")
            } else {
                detail = MessagesPageJSON.string(dictionary["reason"])
                    ?? MessagesPageJSON.string(dictionary["recipient"])
            }
            history.lifecycle.append(
                MessagesPageLifecycle(state: event, timestamp: timestamp, detail: detail)
            )
            result[id] = history
        }
        for id in result.keys {
            result[id]?.lifecycle.sort { $0.timestamp < $1.timestamp }
        }
        return result
    }
}

enum MessagesPageRenderer {
    static func render(snapshot: MessagesPageSnapshot) -> String {
        renderUnbounded(snapshot: boundedSnapshot(snapshot))
    }

    /// Count the bytes produced by `escapeEmbeddedJSON` without allocating the
    /// escaped string. This is shared by the builder's conservative selection
    /// pass and the renderer's final exact-bound pass.
    static func escapedJSONByteCount(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        var count = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0xE2, index + 2 < bytes.count,
               bytes[index + 1] == 0x80,
               bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9 {
                count += 6
                index += 3
                continue
            }
            switch bytes[index] {
            case 0x26, 0x3C, 0x3E: // &, <, > -> six ASCII bytes (\u00XX)
                count += 6
                index += 1
            default:
                count += 1
                index += 1
            }
        }
        return count
    }

    private static func boundedSnapshot(_ snapshot: MessagesPageSnapshot) -> MessagesPageSnapshot {
        guard !snapshot.messages.isEmpty else { return snapshot }
        let limit = snapshot.messageByteLimit
        guard renderedByteCount(snapshot) > limit else { return snapshot }

        // Keep the newest suffix and use binary search so a pathological page
        // needs O(log n) complete renders, not one render for every discarded
        // record. The final rendered output is always measured again before it
        // is returned to the writer.
        var lowerBound = 0
        var upperBound = snapshot.messages.count
        while lowerBound < upperBound {
            let candidateCount = (lowerBound + upperBound + 1) / 2
            let candidate = snapshot.replacingMessages(
                Array(snapshot.messages.suffix(candidateCount))
            )
            if renderedByteCount(candidate) <= limit {
                lowerBound = candidateCount
            } else {
                upperBound = candidateCount - 1
            }
        }
        return snapshot.replacingMessages(Array(snapshot.messages.suffix(lowerBound)))
    }

    private static func renderedByteCount(_ snapshot: MessagesPageSnapshot) -> Int {
        Data(renderUnbounded(snapshot: snapshot).utf8).count
    }

    private static func renderUnbounded(snapshot: MessagesPageSnapshot) -> String {
        let data: Data
        if let encoded = try? JSONSerialization.data(
            withJSONObject: snapshot.jsonObject,
            options: [.sortedKeys]
        ) {
            data = encoded
        } else {
            data = Data("{}".utf8)
        }
        // A JSON string inside a script element must not be allowed to close
        // that element. Escaping the HTML-significant bytes keeps all agent
        // text data-only while preserving JSON semantics in the browser.
        let embeddedJSON = escapeEmbeddedJSON(data)

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'none'; base-uri 'none'; form-action 'none'">
          <title>c11 messages</title>
          <style>
            :root { color-scheme: light dark; font: 14px -apple-system, BlinkMacSystemFont, sans-serif; }
            body { margin: 0; padding: 20px; background: Canvas; color: CanvasText; }
            main { max-width: 1100px; margin: 0 auto; }
            header { display: flex; align-items: baseline; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
            h1 { margin: 0; font-size: 24px; }
            h2 { margin: 24px 0 8px; font-size: 17px; }
            .muted { color: color-mix(in srgb, CanvasText 62%, transparent); }
            .controls { display: flex; gap: 8px; margin: 16px 0; flex-wrap: wrap; }
            input, select { min-height: 32px; border: 1px solid GrayText; border-radius: 5px; padding: 4px 8px; background: Canvas; color: CanvasText; }
            input { flex: 1 1 260px; }
            .date-control { display: flex; flex-direction: column; gap: 2px; font-size: 11px; color: GrayText; }
            .date-control input { min-width: 145px; }
            .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 8px; }
            .card, article, details { border: 1px solid color-mix(in srgb, CanvasText 24%, transparent); border-radius: 6px; padding: 10px; }
            .card strong { display: block; font-size: 20px; margin-bottom: 3px; }
            article { margin: 8px 0; }
            article header { font-size: 12px; }
            .route { font-weight: 600; }
            pre { white-space: pre-wrap; overflow-wrap: anywhere; margin: 10px 0 0; font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
            ul { margin: 8px 0 0; padding-left: 20px; }
            .empty { padding: 18px 0; }
            details { margin: 8px 0; }
            summary { cursor: pointer; }
          </style>
        </head>
        <body>
          <main>
            <header>
              <div><h1>c11 messages</h1><div id="generated" class="muted"></div></div>
              <div id="bound" class="muted"></div>
            </header>
            <div class="controls">
              <input id="search" type="search" placeholder="Search messages, routes, workspaces">
              <select id="channel"><option value="all">All channels</option><option value="send">c11 send</option><option value="mailbox">Mailbox</option></select>
              <select id="workspace"><option value="">All workspaces</option></select>
              <select id="agent"><option value="">All agents</option></select>
              <label class="date-control" for="date">Date (UTC)<input id="date" type="date" aria-label="Filter by date (UTC)"></label>
            </div>
            <section aria-labelledby="health-heading"><h2 id="health-heading">Health</h2><div id="health" class="summary"></div></section>
            <section aria-labelledby="graph-heading"><h2 id="graph-heading">Connections</h2><div id="graph" class="summary"></div></section>
            <section aria-labelledby="mailbox-heading"><h2 id="mailbox-heading">Per-mailbox</h2><div id="mailboxes"></div></section>
            <section aria-labelledby="timeline-heading"><h2 id="timeline-heading">Timeline</h2><div id="timeline"></div></section>
          </main>
          <script id="messages-data" type="application/json">\(embeddedJSON)</script>
          <script>
          (() => {
            "use strict";
            const data = JSON.parse(document.getElementById("messages-data").textContent || "{}");
            const messages = Array.isArray(data.messages) ? data.messages : [];
            const stateStorageKey = "c11.messages.state.v1";
            const defaultState = {
              search: "", channel: "all", workspace: "", agent: "", date: "",
              selectedMessageID: null, openMailboxes: [], scrollY: 0
            };
            const parseState = (raw) => {
              try {
                const value = JSON.parse(raw);
                return Object.assign({}, defaultState, value || {});
              } catch (_) { return null; }
            };
            const readState = () => {
              try {
                const stored = sessionStorage.getItem(stateStorageKey);
                const parsed = stored ? parseState(stored) : null;
                if (parsed) return parsed;
              } catch (_) {}
              try {
                if (location.hash.startsWith("#state=")) {
                  const parsed = parseState(decodeURIComponent(location.hash.slice(7)));
                  if (parsed) return parsed;
                }
              } catch (_) {}
              return Object.assign({}, defaultState);
            };
            const state = readState();
            let selectedMessageID = state.selectedMessageID || null;
            const text = (parent, tag, value, className) => {
              const element = document.createElement(tag);
              if (className) element.className = className;
              element.textContent = value == null ? "" : String(value);
              parent.appendChild(element);
              return element;
            };
            const clear = (element) => { while (element.firstChild) element.removeChild(element.firstChild); };
            const messageBody = (message) => {
              const body = message.body || (message.body_ref ? `body_ref: ${message.body_ref}` : "(no inline body)");
              return message.truncated ? `${body}\n\n[body truncated at source]` : body;
            };
            const mailboxKey = (message) => {
              const recipient = message.recipient || message.target_title || message.sender_id || senderLabel(message) || "unknown mailbox";
              return `${message.workspace || "unknown workspace"}::${recipient}`;
            };
            const saveState = () => {
              const next = {
                search: document.getElementById("search").value,
                channel: document.getElementById("channel").value,
                workspace: document.getElementById("workspace").value,
                agent: document.getElementById("agent").value,
                date: document.getElementById("date").value,
                selectedMessageID,
                openMailboxes: [...document.querySelectorAll("#mailboxes details[open]")].map((item) => item.dataset.mailboxKey),
                scrollY: window.scrollY || 0
              };
              try { sessionStorage.setItem(stateStorageKey, JSON.stringify(next)); } catch (_) {}
              try { history.replaceState(null, "", `#state=${encodeURIComponent(JSON.stringify(next))}`); } catch (_) {}
            };
            const card = (parent, title, value, detail) => {
              const element = document.createElement("div");
              element.className = "card";
              text(element, "strong", value);
              text(element, "span", title);
              if (detail) text(element, "div", detail, "muted");
              parent.appendChild(element);
            };
            const queryText = (message) => [message.body, message.sender, message.sender_id, message.caller_title, message.recipient, message.workspace, message.topic, message.status].filter(Boolean).join(" ").toLowerCase();
            const senderLabel = (message) => message.caller_title || message.sender || (message.sender_id ? `panel:${message.sender_id}` : "unknown caller");
            const filtered = () => {
              const query = document.getElementById("search").value.trim().toLowerCase();
              const channel = document.getElementById("channel").value;
              const workspace = document.getElementById("workspace").value;
              const agent = document.getElementById("agent").value;
              const date = document.getElementById("date").value;
              return messages.filter((message) => {
                const participants = [senderLabel(message), message.sender, message.sender_id, message.recipient].filter(Boolean);
                return (channel === "all" || message.channel === channel)
                  && (!workspace || message.workspace === workspace)
                  && (!agent || participants.includes(agent))
                  && (!date || String(message.timestamp || "").startsWith(date))
                  && (!query || queryText(message).includes(query));
              });
            };
            const populate = (id, values) => {
              const target = document.getElementById(id);
              [...new Set(values.filter(Boolean).map(String))].sort().forEach((value) => {
                const option = document.createElement("option");
                option.value = value;
                option.textContent = value;
                target.appendChild(option);
              });
            };
            const formatBytes = (value) => {
              const bytes = Number(value || 0);
              if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KiB`;
              return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
            };
            const renderHealth = () => {
              const target = document.getElementById("health");
              clear(target);
              const counts = {};
              messages.forEach((message) => { counts[message.status] = (counts[message.status] || 0) + 1; });
              card(target, "shown", messages.length, data.bounded ? `latest ${data.message_limit} of ${data.total_observed}` : "all observed");
              card(target, "send", messages.filter((message) => message.channel === "send").length);
              card(target, "mailbox", messages.filter((message) => message.channel === "mailbox").length);
              Object.keys(counts).sort().forEach((status) => card(target, status, counts[status]));
            };
            const renderGraph = () => {
              const target = document.getElementById("graph");
              clear(target);
              const edges = {};
              messages.forEach((message) => {
                if (message.sender && message.recipient) {
                  const key = `${message.sender} → ${message.recipient}`;
                  edges[key] = (edges[key] || 0) + 1;
                }
              });
              const keys = Object.keys(edges).sort();
              if (!keys.length) return text(target, "div", "No routed messages yet.", "muted");
              keys.forEach((key) => card(target, key, edges[key], "messages"));
            };
            const renderMailboxes = () => {
              const target = document.getElementById("mailboxes");
              clear(target);
              const groups = {};
              messages.filter((message) => message.channel === "mailbox").forEach((message) => {
                const key = mailboxKey(message);
                groups[key] = groups[key] || [];
                groups[key].push(message);
              });
              const keys = Object.keys(groups).sort();
              if (!keys.length) return text(target, "div", "No mailbox traffic yet.", "muted");
              keys.forEach((key) => {
                const details = document.createElement("details");
                details.dataset.mailboxKey = key;
                details.open = Array.isArray(state.openMailboxes) && state.openMailboxes.includes(key);
                const first = groups[key][0];
                const summary = document.createElement("summary");
                summary.textContent = `${first.workspace || "unknown workspace"} · ${first.recipient || first.target_title || "?"} · ${groups[key].length} messages`;
                details.appendChild(summary);
                groups[key].forEach((message) => {
                  text(details, "div", `${message.timestamp} · ${message.status}`, "muted");
                  text(details, "pre", messageBody(message));
                });
                details.addEventListener("toggle", saveState);
                target.appendChild(details);
              });
            };
            const renderTimeline = () => {
              const target = document.getElementById("timeline");
              clear(target);
              const visible = filtered();
              if (!visible.length) return text(target, "div", "No messages match the current filter.", "empty muted");
              visible.slice().reverse().forEach((message) => {
                const article = document.createElement("article");
                article.dataset.messageId = message.id;
                if (message.id === selectedMessageID) article.classList.add("selected");
                article.addEventListener("click", () => {
                  selectedMessageID = message.id;
                  renderTimeline();
                  saveState();
                });
                const heading = document.createElement("header");
                text(heading, "span", message.channel === "send" ? "c11 send" : "mailbox");
                text(heading, "span", message.timestamp, "muted");
                article.appendChild(heading);
                const route = [senderLabel(message), "→", message.recipient || message.target_title || message.surface || "?"];
                text(article, "div", route.join(" "), "route");
                text(article, "div", [message.status, message.queued === true ? "queued at send" : null, message.submitted === true ? "submitted" : null, message.truncated ? "body truncated" : null, message.workspace, message.topic].filter(Boolean).join(" · "), "muted");
                text(article, "pre", messageBody(message));
                const lifecycle = Array.isArray(message.lifecycle) ? message.lifecycle : [];
                if (lifecycle.length) {
                  const list = document.createElement("ul");
                  lifecycle.forEach((item) => text(list, "li", [item.timestamp, item.state, item.detail].filter(Boolean).join(" · "), "muted"));
                  article.appendChild(list);
                }
                target.appendChild(article);
              });
            };
            document.getElementById("generated").textContent = `Generated ${data.generated_at || "unknown"}`;
            document.getElementById("bound").textContent = data.bounded
              ? `Showing latest ${data.message_limit} messages / ${formatBytes(data.message_byte_limit)} page budget of ${data.total_observed} observed`
              : `Showing all observed traffic / ${formatBytes(data.message_byte_limit)} page budget`;
            populate("workspace", messages.map((message) => message.workspace));
            populate("agent", messages.flatMap((message) => [senderLabel(message), message.sender_id, message.recipient]));
            document.getElementById("search").value = state.search || "";
            document.getElementById("channel").value = state.channel || "all";
            document.getElementById("workspace").value = state.workspace || "";
            document.getElementById("agent").value = state.agent || "";
            document.getElementById("date").value = state.date || "";
            document.getElementById("search").addEventListener("input", () => { renderTimeline(); saveState(); });
            document.getElementById("channel").addEventListener("change", () => { renderTimeline(); saveState(); });
            document.getElementById("workspace").addEventListener("change", () => { renderTimeline(); saveState(); });
            document.getElementById("agent").addEventListener("change", () => { renderTimeline(); saveState(); });
            document.getElementById("date").addEventListener("change", () => { renderTimeline(); saveState(); });
            window.addEventListener("scroll", saveState, { passive: true });
            renderHealth();
            renderGraph();
            renderMailboxes();
            renderTimeline();
            if (state.scrollY) window.scrollTo(0, state.scrollY);
          })();
          </script>
        </body>
        </html>
        """
    }

    private static func escapeEmbeddedJSON(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var escaped: [UInt8] = []
        escaped.reserveCapacity(escapedJSONByteCount(data))
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0xE2, index + 2 < bytes.count,
               bytes[index + 1] == 0x80,
               bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9 {
                escaped.append(contentsOf: bytes[index + 2] == 0xA8
                    ? [0x5C, 0x75, 0x32, 0x30, 0x32, 0x38]
                    : [0x5C, 0x75, 0x32, 0x30, 0x32, 0x39])
                index += 3
                continue
            }
            switch bytes[index] {
            case 0x26:
                escaped.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, 0x32, 0x36])
            case 0x3C:
                escaped.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, 0x33, 0x43])
            case 0x3E:
                escaped.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, 0x33, 0x45])
            default:
                escaped.append(bytes[index])
            }
            index += 1
        }
        return String(decoding: escaped, as: UTF8.self)
    }
}
