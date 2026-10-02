import Foundation

/// Lowest-level I/O primitives for the mailbox. Pure helpers — no queueing,
/// no logging. Callers must have already created the destination directory.
enum MailboxIO {

    enum Error: Swift.Error, Equatable {
        case parentDirectoryMissing(URL)
        case renameFailed(source: URL, destination: URL, underlying: String)
    }

    /// Writes `data` to a dot-prefixed, `.tmp`-suffixed sibling of `url`, then
    /// atomically renames onto `url`. Both paths share a directory (same FS)
    /// so the rename is a single POSIX `rename(2)` call inside
    /// `FileManager.moveItem`.
    ///
    /// Semantics:
    /// - On success: `url` exists with `data`'s bytes; temp file is gone.
    /// - On write failure: temp file may exist; `url` is unchanged.
    /// - On rename failure: temp file is best-effort-deleted; original error
    ///   is rethrown.
    /// - Writer crash between steps 1 and 2: a `.*.tmp` file lingers and is
    ///   GC'd by the dispatcher's stale-tmp sweep (Step 13).
    static func atomicWrite(
        data: Data,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let parent = url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard
            fileManager.fileExists(atPath: parent.path, isDirectory: &isDir),
            isDir.boolValue
        else {
            throw Error.parentDirectoryMissing(parent)
        }

        let tempURL = parent.appendingPathComponent(".\(UUID().uuidString).tmp")

        // `.atomic` lets Foundation use its own temp-file-and-rename, keeping
        // the dot-tmp write honest if the process crashes mid-write.
        try data.write(to: tempURL, options: .atomic)

        do {
            try fileManager.moveItem(at: tempURL, to: url)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw Error.renameFailed(
                source: tempURL,
                destination: url,
                underlying: (error as NSError).localizedDescription
            )
        }
    }

    /// C3 claim: rename `<inbox>/<id>.msg` to `<inbox>/_read/<id>.msg`. The
    /// rename is the lock between the stdin push and `recv --drain`: whoever
    /// renames first owns the message. Returns the claimed file's URL, or
    /// `nil` when the envelope is no longer in the inbox root (another
    /// consumer took it). Other failures throw.
    @discardableResult
    static func claim(
        id: String,
        inbox: URL,
        fileManager: FileManager = .default
    ) throws -> URL? {
        let source = inbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        let readDir = MailboxLayout.readURL(inbox: inbox)
        let destination = readDir.appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        try fileManager.createDirectory(
            at: readDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // rename(2) directly, so a peer that won the race between the
        // existence check and here reads as a plain ENOENT.
        if Darwin.rename(source.path, destination.path) != 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw Error.renameFailed(
                source: source,
                destination: destination,
                underlying: String(cString: strerror(code))
            )
        }
        return destination
    }

    /// Undo a claim after the consumer failed to hand the message over, so
    /// the next consumer finds it in the inbox root again. Best effort.
    static func unclaim(
        id: String,
        inbox: URL,
        fileManager: FileManager = .default
    ) {
        let claimed = MailboxLayout.readURL(inbox: inbox)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        let restored = inbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        _ = Darwin.rename(claimed.path, restored.path)
    }
}
