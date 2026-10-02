import Foundation

/// Lowest-level I/O primitives for the mailbox. Pure helpers — no queueing,
/// no logging. Callers must have already created the destination directory.
enum MailboxIO {

    enum Error: Swift.Error, Equatable {
        case parentDirectoryMissing(URL)
        case renameFailed(source: URL, destination: URL, underlying: String)
        case claimFailed(errno: Int32)
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

    /// Outcome of one C3 claim attempt.
    enum ClaimResult: Equatable {
        /// Renamed into `_read/`; the caller owns the message now.
        case claimed(URL)
        /// Not in the inbox root: another consumer took it first.
        case gone
        /// The rename (or creating `_read/`) failed. The envelope is still in
        /// the inbox root; the caller must not hand it over.
        case failed(errno: Int32)
    }

    /// C3 claim: rename `<inbox>/<id>.msg` to `<inbox>/_read/<id>.msg`. The
    /// rename is the lock between the stdin push and `recv --drain`: whoever
    /// renames first owns the message.
    static func claimResult(
        id: String,
        inbox: URL,
        fileManager: FileManager = .default
    ) -> ClaimResult {
        let source = inbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        let readDir = MailboxLayout.readURL(inbox: inbox)
        let destination = readDir.appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        guard fileManager.fileExists(atPath: source.path) else { return .gone }
        do {
            try fileManager.createDirectory(
                at: readDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .failed(errno: posixCode(of: error))
        }
        // rename(2) directly, so a peer that won the race between the
        // existence check and here reads as a plain ENOENT.
        if Darwin.rename(source.path, destination.path) != 0 {
            let code = errno
            return code == ENOENT ? .gone : .failed(errno: code)
        }
        return .claimed(destination)
    }

    /// Throwing form of `claimResult`: the claimed URL, `nil` when another
    /// consumer took the envelope, or `Error.claimFailed` with the errno.
    @discardableResult
    static func claim(
        id: String,
        inbox: URL,
        fileManager: FileManager = .default
    ) throws -> URL? {
        switch claimResult(id: id, inbox: inbox, fileManager: fileManager) {
        case .claimed(let url): return url
        case .gone: return nil
        case .failed(let code): throw Error.claimFailed(errno: code)
        }
    }

    private static func posixCode(of error: Swift.Error) -> Int32 {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return EIO
    }

    /// Undo a claim after the consumer failed to hand the message over, so
    /// the next consumer finds it in the inbox root again. Best effort;
    /// returns whether the envelope is back in the inbox root.
    @discardableResult
    static func unclaim(
        id: String,
        inbox: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let claimed = MailboxLayout.readURL(inbox: inbox)
            .appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        let restored = inbox.appendingPathComponent(MailboxLayout.envelopeFilename(id: id))
        return Darwin.rename(claimed.path, restored.path) == 0
    }
}
