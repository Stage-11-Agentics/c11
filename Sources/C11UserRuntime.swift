import CryptoKit
import Darwin
import Foundation

/// c11's per-user runtime folder, `$(getconf DARWIN_USER_TEMP_DIR)c11`, and
/// the only ways c11 writes there or into shared `/tmp` (C11H-364).
///
/// Non-release sockets, dev and debug logs, build logs, breadcrumbs and
/// `wait-for` channels live in this folder, which is 0700 and ours: another
/// local account cannot create, replace or plant an entry in it. Shared
/// `/tmp` names that older readers still use are written only through
/// `writeBreadcrumb` and `installLegacyAlias`, which never write through an
/// entry another account owns. Scripts mirror the folder and the socket-name
/// rule in `scripts/lib/c11-user-paths.sh`.
///
/// Compiled into the app and the `c11-cli` target. Every function that
/// touches the filesystem takes its folder, so tests use their own roots.
enum C11UserRuntime {
    static let folderName = "c11"
    /// `sun_path` holds 104 bytes, including the terminating NUL.
    static let socketPathMaxBytes = 103
    /// Room kept for the `-<pid>` sibling c11 binds when a live peer of the
    /// same build holds the name (`TerminalController.safeAlternateSocketPath`).
    static let pidSiblingReserveBytes = 6
    static let socketExtension = ".sock"
    static let lastSocketPathFileName = "c11-last-socket-path"
    static let lastDebugLogPathFileName = "c11-last-debug-log-path"
    static let waitForFolderName = "wait-for"

    // MARK: - The folder

    /// The user's own temp folder (`confstr(_CS_DARWIN_USER_TEMP_DIR)`, what
    /// `getconf DARWIN_USER_TEMP_DIR` prints), never `$TMPDIR`: agent
    /// harnesses override `TMPDIR`, and `env -i` drops it.
    static func userTempDirectory() -> String? {
        #if !os(macOS)
        // C11H-392: Linux has no per-user temp folder in confstr.
        return nil
        #else
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 else { return nil }
        let value = String(cString: buffer)
        return value.hasPrefix("/") ? value : nil
        #endif
    }

    /// `<user temp>c11`, or `<base>/c11` when a test passes its own root.
    /// With no answer from `confstr` (never seen on macOS) it is a folder in
    /// the user's Caches, never `/tmp`.
    static func directoryPath(base: String? = nil) -> String {
        let root = base ?? userTempDirectory() ?? (NSHomeDirectory() + "/Library/Caches")
        return join(root, folderName)
    }

    /// Creates or verifies the folder: 0700, owned by us, not a symlink. An
    /// existing looser folder of ours is tightened; anything else throws.
    @discardableResult
    static func ensureDirectory(base: String? = nil) throws -> String {
        let path = directoryPath(base: base)
        try PrivateFileWriter.ensurePrivateDirectory(at: URL(fileURLWithPath: path, isDirectory: true))
        return path
    }

    /// True when `path`'s parent folder is c11's per-user folder.
    static func isInsideDirectory(_ path: String, base: String? = nil) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let folder = directoryPath(base: base)
        return parent == folder || parent == "/private" + folder
    }

    // MARK: - Socket names

    /// `<directory>/<stem>.sock`. When that path, with a `-<pid>` sibling
    /// added, would not fit `sun_path`, the stem becomes its first bytes plus
    /// `-` and the first 8 hex digits of its SHA-256, cut so it fits.
    static func socketPath(stem: String, directory: String) -> String {
        join(directory, fittedSocketStem(stem, directory: directory) + socketExtension)
    }

    static func fittedSocketStem(_ stem: String, directory: String) -> String {
        let budget = socketPathMaxBytes - directory.utf8.count - 1
            - socketExtension.utf8.count - pidSiblingReserveBytes
        guard stem.utf8.count > budget else { return stem }
        let digest = SHA256.hash(data: Data(stem.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(8)
        let keep = max(0, budget - 9)
        let prefix = String(decoding: stem.utf8.prefix(keep), as: UTF8.self)
        return prefix + "-" + digest
    }

    /// The shared `/tmp` name builds before C11H-364 used for the same stem.
    static func legacySocketPath(stem: String) -> String {
        "/tmp/" + stem + socketExtension
    }

    // MARK: - Breadcrumbs

    /// Writes a one-line breadcrumb 0600 through an exclusive, no-follow
    /// temporary file and a rename. An entry another account owns is left
    /// alone (in sticky `/tmp` the rename could not replace it anyway), and a
    /// symlink or hard link at the name is replaced, never written through.
    @discardableResult
    static func writeBreadcrumb(_ value: String, to path: String, expectedOwner: uid_t = getuid()) -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == expectedOwner else { return false }
            guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) else { return false }
        }
        do {
            try PrivateFileWriter.write(Data((value + "\n").utf8), to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    /// Reads a breadcrumb only when it is a regular file we own with a single
    /// link; a value another account planted is never read.
    static func readBreadcrumb(at path: String, maxBytes: Int = 4096, expectedOwner: uid_t = getuid()) -> String? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == expectedOwner,
              info.st_nlink == 1,
              info.st_size <= off_t(maxBytes) else { return nil }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, maxBytes) }
        guard count > 0 else { return nil }
        let text = String(decoding: buffer.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Logs

    /// Opens a log for appending. `O_NOFOLLOW` refuses a symlink, and the
    /// descriptor must then be a regular file we own with one link: a planted
    /// hard link passes `O_NOFOLLOW` alone. `O_NONBLOCK` keeps a planted fifo
    /// from hanging the writer. Returns nil, having written nothing, otherwise.
    static func openLogForAppend(_ path: String, expectedOwner: uid_t = getuid()) -> Int32? {
        let descriptor = open(
            path,
            O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == expectedOwner,
              info.st_nlink == 1 else {
            Darwin.close(descriptor)
            return nil
        }
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }
        return descriptor
    }

    /// Appends `data` through `openLogForAppend`. Creates c11's per-user
    /// folder first when the log lives there.
    @discardableResult
    static func appendLog(_ data: Data, to path: String) -> Bool {
        if isInsideDirectory(path) { _ = try? ensureDirectory() }
        guard let descriptor = openLogForAppend(path) else { return false }
        defer { Darwin.close(descriptor) }
        return writeAll(descriptor, data)
    }

    /// The default path for a dev log: `<folder>/<name>`, folder created.
    static func logPath(_ name: String, base: String? = nil) -> String {
        let folder = (try? ensureDirectory(base: base)) ?? directoryPath(base: base)
        return join(folder, name)
    }

    /// Where a Debug build's log goes when nothing safe can be made: writes vanish.
    static let unwritableDebugLogSink = "/dev/null"

    /// Debug builds: sets both `C11_DEBUG_LOG` and `CMUX_DEBUG_LOG` to
    /// `debugLogChoice` before anything logs. bonsplit's `dlog` appends to that
    /// path by name and, with neither variable set, would fall back to a fixed
    /// name in shared /tmp; it reads them on its first `dlog`, so this must run
    /// before it (C11H-364 L21). `defaultName` is the build's own log name
    /// (`c11-debug-<tag>.log`, or `c11-debug.log`).
    static func secureDebugLogEnvironment(
        defaultName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let named = (environment["C11_DEBUG_LOG"] ?? environment["CMUX_DEBUG_LOG"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chosen = debugLogChoice(environment: environment, defaultName: defaultName)
        if !named.isEmpty, chosen != named {
            FileHandle.standardError.write(Data("c11: refusing debug log \(named) (a link or not this user's file); logging to \(chosen)\n".utf8))
        }
        setenv("C11_DEBUG_LOG", chosen, 1)
        setenv("CMUX_DEBUG_LOG", chosen, 1)
    }

    /// The debug log path, primed as this user's own file: a named path
    /// (`C11_DEBUG_LOG`, else `CMUX_DEBUG_LOG`) keeps `securedDebugLogPath`'s
    /// rule; an unset or blank one takes `<per-user folder>/<defaultName>`
    /// (under `base` in tests). When nothing can be made safe it is
    /// `unwritableDebugLogSink`, never a /tmp fallback.
    static func debugLogChoice(environment: [String: String], defaultName: String, base: String? = nil) -> String {
        let named = (environment["C11_DEBUG_LOG"] ?? environment["CMUX_DEBUG_LOG"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = named.isEmpty ? logPath(defaultName, base: base) : named
        if isInsideDirectory(path, base: base) { _ = try? ensureDirectory(base: base) }
        return securedDebugLogPath(path, base: base) ?? unwritableDebugLogSink
    }

    /// `path` itself once it is primed as this user's own single-link file;
    /// otherwise the same name in c11's per-user folder (under `base` in
    /// tests), primed; nil when neither can be made safe.
    static func securedDebugLogPath(_ path: String, base: String? = nil, expectedOwner: uid_t = getuid()) -> String? {
        if let descriptor = openLogForAppend(path, expectedOwner: expectedOwner) {
            Darwin.close(descriptor)
            return path
        }
        let replacement = logPath((path as NSString).lastPathComponent, base: base)
        guard replacement != path,
              let descriptor = openLogForAppend(replacement, expectedOwner: expectedOwner) else { return nil }
        Darwin.close(descriptor)
        return replacement
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { bytes -> Bool in
            guard var pointer = bytes.baseAddress else { return true }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
            return true
        }
    }

    // MARK: - Peer credentials

    /// The uid of the process on the other end of a connected Unix socket.
    static func peerUserID(of descriptor: Int32) -> uid_t? {
        #if !os(macOS)
        // C11H-392: SO_PEERCRED on Linux.
        return LinuxProc.peerCredentials(descriptor)?.uid
        #else
        var credential = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credential, &length) == 0 else { return nil }
        return credential.cr_uid
        #endif
    }

    /// True only when the listener on `descriptor` runs as `expected`.
    static func peerIsUser(_ descriptor: Int32, expected: uid_t = getuid()) -> Bool {
        peerUserID(of: descriptor) == expected
    }

    // MARK: - Legacy /tmp socket alias

    enum LegacyAliasOutcome: Equatable {
        /// The name is (now) our symlink to the socket.
        case installed
        /// Another account owns the name; c11 never touches it.
        case keptForeign(owner: uid_t)
        /// Our own socket with a live listener (an older build of this tag).
        case keptLivePeer
        /// Our own file or folder that is not a socket or a link; left alone.
        case keptOther
        case failed(errno: Int32)
    }

    /// Keeps `legacyPath` (a pre-C11H-364 `/tmp` socket name) as a symlink to
    /// `target`, so a shell stamped with the old name before this build was
    /// installed still reaches c11. The name is replaced only when it is
    /// missing, our own symlink, or our own socket with no listener. The link
    /// is made under a random name in the same folder and renamed into place,
    /// so the name never goes missing; in sticky `/tmp` the rename cannot
    /// replace an entry another account created meanwhile. The alias is never
    /// removed: while c11 is down it dangles, and the name stays ours.
    static func installLegacyAlias(
        at legacyPath: String,
        target: String,
        expectedOwner: uid_t = getuid(),
        hasLiveListener: (String) -> Bool
    ) -> LegacyAliasOutcome {
        var info = stat()
        if lstat(legacyPath, &info) == 0 {
            guard info.st_uid == expectedOwner else { return .keptForeign(owner: info.st_uid) }
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFLNK):
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: legacyPath)) == target {
                    return .installed
                }
            case mode_t(S_IFSOCK):
                if hasLiveListener(legacyPath) { return .keptLivePeer }
            default:
                return .keptOther
            }
        } else if errno != ENOENT {
            return .failed(errno: errno)
        }
        let folder = (legacyPath as NSString).deletingLastPathComponent
        let temporary = join(folder, ".c11-alias.\(UUID().uuidString)")
        guard symlink(target, temporary) == 0 else { return .failed(errno: errno) }
        guard rename(temporary, legacyPath) == 0 else {
            let code = errno
            unlink(temporary)
            return .failed(errno: code)
        }
        return .installed
    }

    // MARK: - wait-for channels

    enum WaitForState: Equatable {
        case signalled
        case notSignalled
        /// Something other than our own signal file is at the channel's name.
        case refused
    }

    enum WaitForError: Error, Equatable {
        case unsafeChannel(String)
        case unavailable(String, errno: Int32)
    }

    /// `<folder>/wait-for/<name>.sig`, the name reduced to `[A-Za-z0-9._-]`.
    static func waitForChannelPath(name: String, directory: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return join(join(directory, waitForFolderName), sanitized + ".sig")
    }

    /// Ensures the channel folder (0700, ours) and returns it.
    @discardableResult
    static func ensureWaitForFolder(directory: String) throws -> String {
        try PrivateFileWriter.ensurePrivateDirectory(at: URL(fileURLWithPath: directory, isDirectory: true))
        let folder = join(directory, waitForFolderName)
        try PrivateFileWriter.ensurePrivateDirectory(at: URL(fileURLWithPath: folder, isDirectory: true))
        return folder
    }

    /// Signals a channel: creates its file exclusive, no-follow, 0600. A
    /// channel already signalled by us stays signalled; anything else at the
    /// name throws rather than reporting success.
    static func signalWaitFor(at path: String, expectedOwner: uid_t = getuid()) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        if descriptor >= 0 {
            Darwin.close(descriptor)
            return
        }
        let code = errno
        guard code == EEXIST else { throw WaitForError.unavailable(path, errno: code) }
        guard isOwnSignalFile(path, expectedOwner: expectedOwner) else {
            throw WaitForError.unsafeChannel(path)
        }
    }

    /// Consumes a channel's signal: only a regular file we own with one link
    /// counts, and it is removed. A link, a foreign file, a folder or a fifo
    /// at the name is `refused`, never `signalled`.
    static func consumeWaitForSignal(at path: String, expectedOwner: uid_t = getuid()) -> WaitForState {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT ? .notSignalled : .refused
        }
        guard isOwnSignalFile(path, expectedOwner: expectedOwner) else { return .refused }
        guard unlink(path) == 0 else {
            return errno == ENOENT ? .notSignalled : .refused
        }
        return .signalled
    }

    private static func isOwnSignalFile(_ path: String, expectedOwner: uid_t) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && info.st_uid == expectedOwner
            && info.st_nlink == 1
    }

    // MARK: -

    private static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}
