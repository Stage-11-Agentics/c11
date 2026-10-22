import Foundation

/// C11-399: what a panel sent, so the drawer's Sent view needs no scan of other
/// panels' inboxes.
///
/// When the dispatcher accepts an envelope whose sender it could pin to one
/// panel, it records one small entry in that panel's own mailbox directory,
/// `<sender>/_sent/<envelope-id>.sent`: the id, when, who it was addressed to,
/// and the panels it landed in. The body is never copied; the Sent view reads
/// each recipient's inbox or `_read/` copy by id, which also tells it whether
/// the recipient has taken the message yet. Mail sent before this existed has
/// no entry and simply does not appear in Sent.
///
/// Pure file I/O, no app state.
enum MailboxSentLedger {

    static let directoryName = "_sent"
    static let fileExtension = "sent"
    /// A panel keeps its newest `retain` entries; older ones go on the next write
    /// that finds more than `retain + trimSlack`, so a write is not a delete
    /// every time.
    static let retain = 300
    static let trimSlack = 50
    /// An entry larger than this is ignored, as is any non-regular file.
    static let maxEntryBytes = 16 * 1024

    struct Recipient: Codable, Equatable {
        /// The recipient panel's UUID, lowercased.
        let panel: String
        /// The label c11 used for it in the dispatch log when the mail landed.
        let name: String
    }

    struct Entry: Codable, Equatable {
        let id: String
        let ts: String?
        let to: String?
        let topic: String?
        let recipients: [Recipient]
    }

    static func directory(inbox: URL) -> URL {
        inbox.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Writes the entry atomically and trims the directory when it has grown
    /// past the retention bound. Best effort: a failure never affects delivery.
    @discardableResult
    static func record(_ entry: Entry, senderInbox: URL, fileManager: FileManager = .default) -> Bool {
        let dir = directory(inbox: senderInbox)
        do {
            try fileManager.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(entry)
            try MailboxIO.atomicWrite(data: data, to: dir.appendingPathComponent("\(entry.id).\(fileExtension)"))
        } catch {
            return false
        }
        trim(directory: dir, fileManager: fileManager)
        return true
    }

    private static func files(in dir: URL, fileManager: FileManager) -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == fileExtension }
    }

    private static func trim(directory dir: URL, fileManager: FileManager) {
        let all = files(in: dir, fileManager: fileManager)
        guard all.count > retain + trimSlack else { return }
        let oldestFirst = all.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in oldestFirst.prefix(all.count - retain) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Newest first (by envelope id, a ULID), at most `limit`, plus how many
    /// entries exist. One directory listing; reads only the listed entries.
    static func entries(
        senderInbox: URL,
        limit: Int,
        fileManager: FileManager = .default
    ) -> (entries: [Entry], total: Int) {
        let all = files(in: directory(inbox: senderInbox), fileManager: fileManager)
        let newestFirst = all.sorted { $0.lastPathComponent > $1.lastPathComponent }
        var result: [Entry] = []
        for url in newestFirst.prefix(max(0, limit)) {
            guard case .success(let read) = MailboxPanelMail.readRegularFilePrefix(
                path: url.path, limit: maxEntryBytes, followSymlinks: false
            ), !read.truncated,
                  let entry = try? JSONDecoder().decode(Entry.self, from: read.data) else { continue }
            result.append(entry)
        }
        return (result, all.count)
    }
}
