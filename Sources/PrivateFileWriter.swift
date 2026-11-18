import Darwin
import Foundation

enum PrivateFileWriter {
    enum ReadError: LocalizedError, Equatable {
        case invalidSizeLimit
        case unsafeFile
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidSizeLimit:
                return String(localized: "browser.state.file.invalidSizeLimit", defaultValue: "State file size limit must be nonnegative")
            case .unsafeFile:
                return String(localized: "browser.state.file.unsafeWithACL", defaultValue: "State file must be a regular file (not a symlink) owned by the current user, not writable by group or others, and without allow ACLs")
            case .tooLarge:
                return String(localized: "browser.state.file.tooLarge", defaultValue: "State file exceeds the maximum allowed size")
            }
        }
    }

    /// `description` is the localized text, so a caller that prints the error
    /// (`"\(error)"`, the CLI's `Error: …`) shows the sentence, not the case.
    enum DirectoryError: LocalizedError, Equatable, CustomStringConvertible {
        /// The path is a symlink, not a folder, or a folder another uid owns.
        case unsafeDirectory(String)

        var errorDescription: String? {
            switch self {
            case .unsafeDirectory(let path):
                return String(localized: "privateFile.directory.unsafe", defaultValue: "Refusing to use \(path): it must be a folder owned by the current user, not a symlink.")
            }
        }

        var description: String { errorDescription ?? "" }
    }

    /// What `writeCopy` found at its destination. Prints as its localized text.
    enum CopyError: LocalizedError, Equatable, CustomStringConvertible {
        /// The destination is a folder with something in it. Nothing was written or deleted.
        case destinationIsNonEmptyDirectory(String)

        var errorDescription: String? {
            switch self {
            case .destinationIsNonEmptyDirectory(let path):
                return String(localized: "privateFile.copy.nonEmptyDirectory", defaultValue: "\(path) is a folder that is not empty. Nothing was written there.")
            }
        }

        var description: String { errorDescription ?? "" }
    }

    /// The roots of c11's own private stores under `home` (C11H-364 L15, L17,
    /// L18): `~/.c11-snapshots`, `~/.cmuxterm` (the CLI's tmux-compat store)
    /// and `~/.c11` (Claude hook state). An operator's
    /// `CMUX_CLAUDE_HOOK_STATE_PATH` folder is theirs and is not one of them.
    static func storeRoots(home: URL) -> [URL] {
        [
            C11Identity.snapshotDirectory(home: home),
            home.appendingPathComponent(".cmuxterm", isDirectory: true),
            C11Identity.claudeHookStateFile(home: home).deletingLastPathComponent(),
        ]
    }

    /// Sets each existing store root to 0700, once at launch, so a store an
    /// earlier c11 left 0755 is closed before c11 next writes there. Modes
    /// only: a missing root stays missing, a symlink is never followed (the
    /// migration's alias is tightened at its next write), a folder another
    /// account owns is left as it is, and the files inside are untouched,
    /// since a 0700 folder already closes them. Returns the roots it changed.
    @discardableResult
    static func tightenExistingStoreRoots(_ roots: [URL], expectedOwner: uid_t = getuid()) -> [URL] {
        var changed: [URL] = []
        for root in roots {
            let path = root.standardizedFileURL.path
            var info = stat()
            guard lstat(path, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  info.st_mode & mode_t(0o7777) != mode_t(0o700) else { continue }
            do {
                try verifyOwnedDirectory(path: path, expectedOwner: expectedOwner, chmodTo: 0o700)
                changed.append(root)
            } catch {
                continue
            }
        }
        return changed
    }

    /// Makes `url` a private folder: missing folders (parents included) are
    /// created 0700. An existing folder at `url` must be owned by
    /// `expectedOwner` and not be a symlink; `tightenExisting` sets it to 0700.
    /// Existing parents are left as they are.
    ///
    /// `allowOwnSymlink` is for stores under the home folder, where c11's own
    /// migration may leave `~/.c11-snapshots` as a link to the folder it
    /// adopted: a link `expectedOwner` owns is followed, and the folder it
    /// names must itself be owned by `expectedOwner` (and is tightened).
    /// Nothing in a shared folder passes it.
    static func ensurePrivateDirectory(
        at url: URL,
        tightenExisting: Bool = true,
        expectedOwner: uid_t = getuid(),
        allowOwnSymlink: Bool = false
    ) throws {
        let path = url.standardizedFileURL.path
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw posixError() }
            let parent = url.standardizedFileURL.deletingLastPathComponent()
            if parent.path != path {
                try createMissingPrivateDirectories(at: parent)
            }
            if mkdir(path, mode_t(0o700)) != 0, errno != EEXIST { throw posixError() }
            // Created here (or raced by our own process): always exactly 0700.
            try verifyOwnedDirectory(path: path, expectedOwner: expectedOwner, chmodTo: 0o700)
            return
        }
        let followLink = allowOwnSymlink
            && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
            && info.st_uid == expectedOwner
        try verifyOwnedDirectory(
            path: path,
            expectedOwner: expectedOwner,
            chmodTo: tightenExisting ? 0o700 : nil,
            followLink: followLink
        )
    }

    /// Creates any missing folders on the way to `url` 0700 and leaves existing
    /// ones untouched (an operator-chosen `--out` folder may be `~/Desktop`).
    static func createMissingPrivateDirectories(at url: URL) throws {
        let path = url.standardizedFileURL.path
        var info = stat()
        if lstat(path, &info) == 0 || path == "/" { return }
        guard errno == ENOENT else { throw posixError() }
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        if parent.path != path {
            try createMissingPrivateDirectories(at: parent)
        }
        if mkdir(path, mode_t(0o700)) != 0, errno != EEXIST { throw posixError() }
    }

    /// Writes an operator-requested copy (`state save --out`, `snapshot --out`)
    /// 0600 through `write(_:to:)`. Missing parents are created 0700; an
    /// existing parent keeps its mode. A file or symlink at `url` is replaced
    /// by the rename and never followed. An empty folder at `url` is removed
    /// with `rmdir` and replaced; a folder with anything in it is refused and
    /// left exactly as it was.
    static func writeCopy(_ data: Data, to url: URL) throws {
        try createMissingPrivateDirectories(at: url.deletingLastPathComponent())
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
            guard rmdir(url.path) == 0 else {
                if errno == ENOTEMPTY || errno == EEXIST {
                    throw CopyError.destinationIsNonEmptyDirectory(url.path)
                }
                throw posixError()
            }
        }
        try write(data, to: url)
    }

    /// Writes one of c11's own store files (`~/.cmuxterm`, `~/.c11`): the
    /// folder is made private (`ensurePrivateDirectory`, or only its missing
    /// parts when `tightenFolder` is false, for an operator's override path),
    /// then the file is written 0600 through `write(_:to:)` (C11H-364 L17, L18).
    static func writePrivateStore(_ data: Data, to url: URL, tightenFolder: Bool = true) throws {
        let folder = url.deletingLastPathComponent()
        if tightenFolder {
            try ensurePrivateDirectory(at: folder, allowOwnSymlink: true)
        } else {
            try createMissingPrivateDirectories(at: folder)
        }
        try write(data, to: url)
    }

    private static func verifyOwnedDirectory(
        path: String,
        expectedOwner: uid_t,
        chmodTo mode: mode_t?,
        followLink: Bool = false
    ) throws {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (followLink ? 0 : O_NOFOLLOW)
        let descriptor = open(path, flags)
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw DirectoryError.unsafeDirectory(path) }
            throw posixError()
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == expectedOwner else {
            throw DirectoryError.unsafeDirectory(path)
        }
        if let mode, info.st_mode & mode_t(0o7777) != mode {
            guard fchmod(descriptor, mode) == 0 else { throw posixError() }
        }
    }

    static func write(_ data: Data, to url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".c11-state.\(UUID().uuidString).tmp")
        let descriptor = try openPrivateTemporaryFile(at: temporaryURL)

        var descriptorIsOpen = true
        var temporaryFileExists = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
            if temporaryFileExists { unlink(temporaryURL.path) }
        }

        #if os(macOS)
        guard let emptyACL = acl_init(0) else { throw posixError() }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        if acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED) != 0,
           !isACLUnsupported(errno) {
            throw posixError()
        }
        #endif
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw posixError() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError() }

        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else { throw posixError() }
        guard rename(temporaryURL.path, url.path) == 0 else { throw posixError() }
        temporaryFileExists = false
    }

    static func openPrivateTemporaryFile(at url: URL) throws -> Int32 {
        #if !os(macOS)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
        #else
        guard let emptyACL = acl_init(0) else { throw posixError() }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }

        var flagset: acl_flagset_t?
        guard acl_get_flagset_np(UnsafeMutableRawPointer(emptyACL), &flagset) == 0,
              let flagset else {
            throw posixError()
        }
        guard acl_add_flag_np(flagset, ACL_FLAG_NO_INHERIT) == 0 else { throw posixError() }

        guard let fileSecurity = filesec_init() else { throw posixError() }
        defer { filesec_free(fileSecurity) }

        var aclValue: acl_t? = emptyACL
        guard filesec_set_property(fileSecurity, FILESEC_ACL, &aclValue) == 0 else { throw posixError() }
        var mode = mode_t(0o600)
        guard filesec_set_property(fileSecurity, FILESEC_MODE, &mode) == 0 else { throw posixError() }

        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let descriptor = openx_np(url.path, flags, fileSecurity)
        guard descriptor < 0 else { return descriptor }
        if errno == EINVAL || isACLUnsupported(errno) {
            let fallbackDescriptor = open(url.path, flags, mode_t(0o600))
            guard fallbackDescriptor >= 0 else { throw posixError() }
            return fallbackDescriptor
        }
        throw posixError()
        #endif
    }

    static func readPrivateFile(at url: URL, maxBytes: Int) throws -> Data {
        guard maxBytes >= 0 else { throw ReadError.invalidSizeLimit }

        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ReadError.unsafeFile }
            throw posixError()
        }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              info.st_mode & mode_t(0o022) == 0 else {
            throw ReadError.unsafeFile
        }
        if try hasExtendedAllowACL(descriptor) { throw ReadError.unsafeFile }
        guard info.st_size >= 0 else { throw ReadError.unsafeFile }
        guard info.st_size <= off_t(maxBytes) else { throw ReadError.tooLarge }

        var data = Data()
        if info.st_size > 0 {
            data.reserveCapacity(Int(info.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = maxBytes - data.count
            let bytesToRead = remaining == Int.max ? buffer.count : min(buffer.count, remaining + 1)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!, bytesToRead)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw posixError() }
            guard count > 0 else { return data }
            guard count <= remaining else { throw ReadError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func isACLUnsupported(_ error: Int32) -> Bool {
        error == ENOTSUP || error == EOPNOTSUPP
    }

    private static func hasExtendedAllowACL(_ descriptor: Int32) throws -> Bool {
        #if !os(macOS)
        return false   // Linux has no extended allow ACLs; mode and owner are checked above
        #else
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || isACLUnsupported(errno) { return false }
            throw posixError()
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        var entry: acl_entry_t?
        var result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        if result < 0 {
            if errno == EINVAL { return false }
            throw posixError()
        }

        while result == 0 {
            guard let currentEntry = entry else { throw POSIXError(.EIO) }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(currentEntry, &tag) == 0 else { throw posixError() }
            if tag == ACL_EXTENDED_ALLOW { return true }

            result = acl_get_entry(acl, ACL_NEXT_ENTRY.rawValue, &entry)
            if result < 0 {
                if errno == EINVAL { return false }
                throw posixError()
            }
        }
        return false
        #endif
    }
}
