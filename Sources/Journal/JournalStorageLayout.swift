import Foundation
import Darwin

struct JournalBudgets {
    var historyMs: Int64 = 14 * 86_400_000
    var receiptMs: Int64 = 86_400_000
    var currentBytes = 16 * 1024 * 1024
    var ownerBytes = 8 * 1024
    var totalBytes: Int64 = 256 * 1024 * 1024
    var reclaimStart: Int64 = 192 * 1024 * 1024
    var reclaimTarget: Int64 = 128 * 1024 * 1024
    var reserveBytes: Int64 = 1024 * 1024
    var checkpointBytes: Int64 = 4 * 1024 * 1024
    var walLimit: Int64 = 16 * 1024 * 1024
    var spoolBytes: Int64 = 16 * 1024 * 1024
    var spoolFiles = 1024
    var spoolFileBytes = 64 * 1024
    var queueEntries = 256
    var queueBytes = 1024 * 1024
}

struct JournalStorageLayout {
    let directory: URL
    var database: URL { directory.appendingPathComponent("lifecycle.sqlite3") }
    var spool: URL { directory.appendingPathComponent("spool", isDirectory: true) }

    static func resolve(bundleID: String?, supportDirectory: URL? = nil) throws -> JournalStorageLayout {
        guard let bundleID, bundleID.hasPrefix("com.stage11.c11"), bundleID.utf8.count <= 128,
              bundleID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45 }),
              !bundleID.contains("..") else { throw JournalError.unavailable }
        let support = supportDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return JournalStorageLayout(directory: support.appendingPathComponent("c11/journal/\(bundleID)", isDirectory: true))
    }

    func prepare() throws {
        // Reject symlink components before creating any private storage below them.
        var cursor = directory
        while cursor.path != "/" {
            var st = stat()
            if lstat(cursor.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK {
                // macOS exposes its root-owned temporary directories through these
                // system links. User-owned links inside the storage path stay rejected.
                guard st.st_uid == 0, ["/var", "/tmp"].contains(cursor.path) else { throw JournalError.unavailable }
            }
            cursor.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.privateDirectory(directory)
        guard mkdir(spool.path, 0o700) == 0 || errno == EEXIST else { throw JournalError.unavailable }
        try Self.privateDirectory(spool)
        for suffix in ["", "-wal", "-shm"] {
            let path = database.path + suffix
            var st = stat()
            if lstat(path, &st) == 0 {
                guard st.st_uid == getuid(), (st.st_mode & S_IFMT) == S_IFREG else { throw JournalError.unavailable }
                guard chmod(path, 0o600) == 0 else { throw JournalError.unavailable }
            }
        }
    }

    static func privateDirectory(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_uid == getuid(), (st.st_mode & S_IFMT) == S_IFDIR,
              chmod(url.path, 0o700) == 0 else { throw JournalError.unavailable }
    }

    static func physicalBytes(_ path: String) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return 0 }
        return Int64(st.st_blocks) * 512
    }

    func physicalBytes() -> Int64 {
        let db = ["", "-wal", "-shm"].reduce(Int64(0)) { $0 + Self.physicalBytes(database.path + $1) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: spool.path)) ?? []
        return names.reduce(db) { $0 + Self.physicalBytes(spool.appendingPathComponent($1).path) }
    }
}
