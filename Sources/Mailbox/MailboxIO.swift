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
}
