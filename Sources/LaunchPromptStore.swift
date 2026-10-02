import Darwin
import Foundation

/// Owns prompt copies independently of caller files. Files remain readable until
/// their actual TerminalTab's owner token is released, including delayed startup.
/// There is intentionally no age/cross-process sweep: a crashed process can leave
/// its private namespace behind, but cannot cause another instance's deletion.
final class LaunchPromptStore: @unchecked Sendable {
    static let shared = LaunchPromptStore()

    struct StagedPrompt: Sendable, Equatable {
        let url: URL
        fileprivate let id: UUID
        fileprivate let storeID: UUID
    }

    enum StoreError: Swift.Error, LocalizedError, Equatable {
        case emptyPrompt
        case unsafeDirectory
        case unsafeFile
        case unknownPrompt
        case ownerReleased
        case alreadyRetained
        case io(operation: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case .emptyPrompt: return "Launch prompt is empty."
            case .unsafeDirectory: return "Launch prompt directory is unsafe or unavailable."
            case .unsafeFile: return "Launch prompt file was replaced or is unsafe."
            case .unknownPrompt: return "Launch prompt is no longer owned by this process."
            case .ownerReleased: return "Launch prompt target has already closed."
            case .alreadyRetained: return "Launch prompt already belongs to another target."
            case let .io(operation, code): return "Launch prompt \(operation) failed (errno \(code))."
            }
        }
    }

    private struct Entry: Sendable {
        let prompt: StagedPrompt
        let device: dev_t
        let inode: ino_t
        var owner: UUID?
    }

    // Main launch/close only uses registryLock. Disk operations never hold it,
    // so one large staging write cannot stall an unrelated tab's main commit.
    private let registryLock = NSLock()
    private let ioLock = NSLock()
    private let cleanupQueue = DispatchQueue(label: "c11.launch-prompts.cleanup", qos: .utility)
    private let storeID = UUID()
    private let rootDirectory: URL
    private let namespaceName: String
    private let nextFileID: () -> UUID
    private var directoryFD: Int32 = -1
    private var entries: [UUID: Entry] = [:]
    private var releasedOwners: Set<UUID> = []

    init(rootDirectory: URL? = nil, namespaceID: UUID = UUID(), nextFileID: @escaping () -> UUID = UUID.init) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.rootDirectory = rootDirectory ?? support.appendingPathComponent("c11/runtime/launch-prompts", isDirectory: true)
        namespaceName = "\(getpid())-\(namespaceID.uuidString)"
        self.nextFileID = nextFileID
    }

    deinit {
        if directoryFD >= 0 { Darwin.close(directoryFD) }
    }

    /// Filesystem work: call off main. Whitespace is only an emptiness check;
    /// the original UTF-8 body is written without trimming or normalization.
    func stage(prompt: String) throws -> StagedPrompt {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.emptyPrompt
        }
        ioLock.lock()
        defer { ioLock.unlock() }
        try prepareDirectory()
        let id = nextFileID()
        let filename = "\(id.uuidString).txt"
        let fd = openat(directoryFD, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw StoreError.io(operation: "create", code: errno) }
        var succeeded = false
        defer {
            Darwin.close(fd)
            if !succeeded { unlinkat(directoryFD, filename, 0) }
        }
        guard fchmod(fd, mode_t(0o600)) == 0 else { throw StoreError.io(operation: "permissions", code: errno) }
        let data = Data(prompt.utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StoreError.io(operation: "write", code: count < 0 ? errno : EIO) }
                offset += count
            }
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw StoreError.io(operation: "inspect", code: errno) }
        let staged = StagedPrompt(
            url: rootDirectory.appendingPathComponent(namespaceName, isDirectory: true).appendingPathComponent(filename),
            id: id,
            storeID: storeID
        )
        registryLock.lock()
        entries[id] = Entry(prompt: staged, device: info.st_dev, inode: info.st_ino)
        registryLock.unlock()
        succeeded = true
        return staged
    }

    /// `owner` must be a token stored on the TerminalTab object, not its UUID.
    /// Memory-only, safe for the main launch commit after off-main staging.
    func retain(_ prompt: StagedPrompt, owner: UUID) throws {
        registryLock.lock()
        defer { registryLock.unlock() }
        guard !releasedOwners.contains(owner) else { throw StoreError.ownerReleased }
        guard prompt.storeID == storeID, var entry = entries[prompt.id], entry.prompt == prompt else {
            throw StoreError.unknownPrompt
        }
        guard entry.owner == nil || entry.owner == owner else { throw StoreError.alreadyRetained }
        entry.owner = owner
        entries[prompt.id] = entry
    }

    /// Optional off-main revalidation before committing a delayed staged launch.
    /// Rejects replaced files and symlinks without following their targets.
    func validate(_ prompt: StagedPrompt) throws {
        registryLock.lock()
        let entry = prompt.storeID == storeID ? entries[prompt.id] : nil
        registryLock.unlock()
        guard let entry, entry.prompt == prompt else {
            throw StoreError.unknownPrompt
        }
        ioLock.lock()
        defer { ioLock.unlock() }
        try verifyDirectoryPath()
        guard matchesFile(entry) else { throw StoreError.unsafeFile }
    }

    /// Safe on main: remove bindings synchronously, then unlink off main. A late
    /// retain racing with close is rejected even before queued cleanup starts.
    func release(owner: UUID) {
        registryLock.lock()
        releasedOwners.insert(owner)
        let removed = entries.values.filter { $0.owner == owner }
        for entry in removed { entries.removeValue(forKey: entry.prompt.id) }
        registryLock.unlock()
        cleanupQueue.async { [self] in
            ioLock.lock()
            defer { ioLock.unlock() }
            for entry in removed { removeIfUnchanged(entry) }
        }
    }

    /// Immediate failure cleanup, off main. Bound files cannot be discarded by
    /// an obsolete launch callback, and tokens from other instances do nothing.
    func discard(_ prompt: StagedPrompt) {
        registryLock.lock()
        guard prompt.storeID == storeID, let entry = entries[prompt.id], entry.prompt == prompt,
              entry.owner == nil else {
            registryLock.unlock()
            return
        }
        entries.removeValue(forKey: prompt.id)
        registryLock.unlock()
        ioLock.lock()
        defer { ioLock.unlock() }
        removeIfUnchanged(entry)
    }

    /// A deterministic barrier for behavioral tests; product close never waits.
    func waitForPendingCleanup() { cleanupQueue.sync {} }

    private func prepareDirectory() throws {
        if directoryFD >= 0 { try verifyDirectoryPath(); return }
        try Self.ensureDirectory(rootDirectory)
        let rootFD = open(rootDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw StoreError.unsafeDirectory }
        defer { Darwin.close(rootFD) }
        var info = stat()
        guard fstat(rootFD, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o700 == 0o700 else {
            throw StoreError.unsafeDirectory
        }
        guard fchmod(rootFD, mode_t(0o700)) == 0 else { throw StoreError.io(operation: "permissions", code: errno) }
        guard mkdirat(rootFD, namespaceName, mode_t(0o700)) == 0 else {
            throw StoreError.io(operation: "directory creation", code: errno)
        }
        let fd = openat(rootFD, namespaceName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.unsafeDirectory }
        guard fchmod(fd, mode_t(0o700)) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw StoreError.io(operation: "permissions", code: code)
        }
        directoryFD = fd
        try verifyDirectoryPath()
    }

    private func verifyDirectoryPath() throws {
        let rootFD = open(rootDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw StoreError.unsafeDirectory }
        defer { Darwin.close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0, rootInfo.st_uid == getuid(), rootInfo.st_mode & 0o777 == 0o700 else {
            throw StoreError.unsafeDirectory
        }
        let currentFD = openat(rootFD, namespaceName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard currentFD >= 0 else { throw StoreError.unsafeDirectory }
        defer { Darwin.close(currentFD) }
        var expected = stat()
        var current = stat()
        guard fstat(directoryFD, &expected) == 0, fstat(currentFD, &current) == 0,
              current.st_dev == expected.st_dev, current.st_ino == expected.st_ino,
              current.st_uid == getuid(), current.st_mode & 0o777 == 0o700 else {
            throw StoreError.unsafeDirectory
        }
    }

    private func matchesFile(_ entry: Entry) -> Bool {
        var info = stat()
        return fstatat(directoryFD, entry.prompt.url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0
            && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && info.st_dev == entry.device && info.st_ino == entry.inode
            && info.st_uid == getuid() && info.st_nlink == 1 && info.st_mode & 0o777 == 0o600
    }

    private func removeIfUnchanged(_ entry: Entry) {
        // fd-relative deletion remains in our namespace even if a path is
        // replaced. A substituted symlink/file is never followed or deleted.
        if matchesFile(entry) { unlinkat(directoryFD, entry.prompt.url.lastPathComponent, 0) }
    }

    private static func ensureDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw StoreError.unsafeDirectory }
            return
        }
        guard errno == ENOENT else { throw StoreError.io(operation: "directory inspection", code: errno) }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { throw StoreError.unsafeDirectory }
        try ensureDirectory(parent)
        if mkdir(url.path, mode_t(0o700)) != 0 && errno != EEXIST {
            throw StoreError.io(operation: "directory creation", code: errno)
        }
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw StoreError.unsafeDirectory
        }
    }
}
