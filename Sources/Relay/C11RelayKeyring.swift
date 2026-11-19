import Foundation
import Darwin

/// Where the relay's link secrets come from (C11H-176). One secret per (local
/// hc session, linked machine): a tagged build's session never shares a
/// secret with the release build's.
protocol C11RelayLinkSecrets: AnyObject, Sendable {
    /// The current secret, or nil when none was made (no credential can verify).
    func secret(session: String, machine: String) -> C11RelayAuth.LinkSecret?
    /// The current secret, made on first use.
    func secretCreatingIfNeeded(session: String, machine: String) -> C11RelayAuth.LinkSecret?
    /// Deletes the machine's secret in each of these sessions: every
    /// credential made from it stops verifying. Returns how many were removed.
    @discardableResult
    func revoke(machine: String, sessions: [String]) -> Int
}

/// The link secrets on the Mac, one JSON file each under c11's support
/// folder (`relay/keys/<session>/<machine>.json`): 0600 files in 0700
/// folders owned by this user, never read or written through a symlink, and
/// never sent anywhere. The same user on the Mac is outside the relay's
/// threat model (C11H-45); the modes are hygiene.
final class C11RelayKeyring: C11RelayLinkSecrets, @unchecked Sendable {
    static let shared: C11RelayKeyring = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return C11RelayKeyring(directory: support.appendingPathComponent(C11Identity.stateDirectoryName, isDirectory: true)
            .appendingPathComponent("relay/keys", isDirectory: true))
    }()

    private let directory: URL
    private let lock = NSLock()
    private var cache: [String: C11RelayAuth.LinkSecret] = [:]

    init(directory: URL) { self.directory = directory }

    /// hc session and machine names as path components: plain tokens only.
    static func isName(_ value: String) -> Bool {
        guard let first = value.utf8.first, value.utf8.count <= 64, first != UInt8(ascii: ".") else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
        }
    }

    private func fileURL(session: String, machine: String) -> URL? {
        guard Self.isName(session), Self.isName(machine) else { return nil }
        return directory.appendingPathComponent(session, isDirectory: true).appendingPathComponent("\(machine).json")
    }

    func secret(session: String, machine: String) -> C11RelayAuth.LinkSecret? {
        guard let url = fileURL(session: session, machine: machine) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[url.path] { return cached }
        guard let loaded = Self.read(url) else { return nil }
        cache[url.path] = loaded
        return loaded
    }

    func secretCreatingIfNeeded(session: String, machine: String) -> C11RelayAuth.LinkSecret? {
        guard let url = fileURL(session: session, machine: machine) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[url.path] { return cached }
        if let loaded = Self.read(url) { cache[url.path] = loaded; return loaded }
        // A file read whole that does not hold a secret (empty after a crash
        // mid-write, damaged) is moved aside, never left to block every later
        // create; no credential made from it could verify anyway. A file that
        // could not be read just now (no descriptor, a short read) is left
        // alone and nothing is made: replacing a good secret would cut off
        // every terminal on that machine.
        switch Self.readState(url) {
        case .damaged: _ = rename(url.path, url.path + ".bad-\(Int64(Date().timeIntervalSince1970 * 1000))")
        case .unreadable: return nil
        case .absent, .secret: break
        }
        guard let made = C11RelayAuth.LinkSecret.make(), Self.write(made, to: url) else { return nil }
        // Another writer may have won the exclusive create: use what is on disk.
        guard let stored = Self.read(url) else { return nil }
        cache[url.path] = stored
        return stored
    }

    @discardableResult
    func revoke(machine: String, sessions: [String]) -> Int {
        lock.lock(); defer { lock.unlock() }
        var removed = 0
        for session in Set(sessions) {
            guard let url = fileURL(session: session, machine: machine) else { continue }
            cache.removeValue(forKey: url.path)
            if unlink(url.path) == 0 { removed += 1 }
        }
        return removed
    }

    // MARK: Files

    private struct Stored: Codable {
        let v: Int
        let id: String
        let key: String
        let created_ms: Int64
    }

    private enum ReadState {
        case absent
        case unreadable
        case damaged
        case secret(C11RelayAuth.LinkSecret)
    }

    private static func read(_ url: URL) -> C11RelayAuth.LinkSecret? {
        if case .secret(let secret) = readState(url) { return secret }
        return nil
    }

    /// A regular file owned by this user, opened without following a
    /// symlink. Group or other access is removed before it is read.
    private static func readState(_ url: URL) -> ReadState {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .absent : .unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .unreadable }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_size < 4096 else { return .unreadable }
        if info.st_mode & 0o077 != 0 { _ = fchmod(fd, 0o600) }
        guard info.st_size > 0 else { return .damaged }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard Darwin.read(fd, &bytes, bytes.count) == bytes.count else { return .unreadable }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: Data(bytes)), stored.v == 1,
              let key = C11RelayAuth.data(hex: stored.key),
              let secret = C11RelayAuth.LinkSecret(id: stored.id, key: key) else { return .damaged }
        return .secret(secret)
    }

    /// Exclusive, atomic create (never replaces a secret in use): the whole
    /// 0600 file is written beside the target and linked into place, so a
    /// crash leaves either no file or a complete one. 0700 folders owned by
    /// this user; refuses a symlinked folder.
    private static func write(_ secret: C11RelayAuth.LinkSecret, to url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard ensureFolder(folder.deletingLastPathComponent()), ensureFolder(folder) else { return false }
        let stored = Stored(v: 1, id: secret.id, key: C11RelayAuth.hex(secret.key),
                            created_ms: Int64(Date().timeIntervalSince1970 * 1000))
        guard let data = try? JSONEncoder().encode(stored),
              let temp = writeTemporary(data, beside: url) else { return false }
        defer { unlink(temp) }
        return link(temp, url.path) == 0 || errno == EEXIST
    }

    /// A complete, synced 0600 file beside `url`; its path, or nil.
    static func writeTemporary(_ data: Data, beside url: URL) -> String? {
        let temp = url.path + ".tmp-\(getpid())-\(UUID().uuidString.prefix(8))"
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced else { unlink(temp); return nil }
        return temp
    }

    /// Creates the folder (and its parents) 0700, then checks that it is a
    /// real folder owned by this user and closes group and other access.
    static func ensureFolder(_ url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { return false }
        if info.st_mode & 0o077 != 0 { _ = chmod(url.path, 0o700) }
        return true
    }
}

/// An in-memory keyring for tests and for a run with no support folder.
final class C11RelayMemoryKeyring: C11RelayLinkSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: C11RelayAuth.LinkSecret] = [:]

    init() {}

    private func key(_ session: String, _ machine: String) -> String { "\(session)\u{0}\(machine)" }

    func secret(session: String, machine: String) -> C11RelayAuth.LinkSecret? {
        lock.lock(); defer { lock.unlock() }
        return secrets[key(session, machine)]
    }

    func secretCreatingIfNeeded(session: String, machine: String) -> C11RelayAuth.LinkSecret? {
        lock.lock(); defer { lock.unlock() }
        if let existing = secrets[key(session, machine)] { return existing }
        let made = C11RelayAuth.LinkSecret.make()
        secrets[key(session, machine)] = made
        return made
    }

    @discardableResult
    func revoke(machine: String, sessions: [String]) -> Int {
        lock.lock(); defer { lock.unlock() }
        return Set(sessions).reduce(0) { count, session in
            secrets.removeValue(forKey: key(session, machine)) == nil ? count : count + 1
        }
    }
}

/// A small relay state file on the Mac (0600 in 0700 folders, replaced
/// atomically), kept in memory once read. `url` nil keeps it in memory only
/// (tests). Used for the spool's high-water marks and the pickup ledger.
final class C11RelayStateFile<Value: Codable>: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var value: Value
    private var loaded = false

    init(url: URL?, empty: Value) {
        self.url = url
        self.value = empty
    }

    func read<T>(_ body: (Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        load()
        return body(value)
    }

    @discardableResult
    func update<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        load()
        let result = body(&value)
        save()
        return result
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let url else { return }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_size > 0, info.st_size < 4 << 20 else { return }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard Darwin.read(fd, &bytes, bytes.count) == bytes.count,
              let decoded = try? JSONDecoder().decode(Value.self, from: Data(bytes)) else { return }
        value = decoded
    }

    private func save() {
        guard let url, C11RelayKeyring.ensureFolder(url.deletingLastPathComponent()),
              let data = try? JSONEncoder().encode(value),
              let temp = C11RelayKeyring.writeTemporary(data, beside: url) else { return }
        if rename(temp, url.path) != 0 { unlink(temp) }
    }
}

/// C11H-176: per terminal (machine, panel, creation), the ids of spooled
/// records c11 has applied and when, kept on disk for a day and a bit
/// longer than a spooled record may live, so a copy is refused across c11
/// restarts. Bounded per terminal; terminals that no longer run are dropped.
final class C11RelaySpoolMarks: @unchecked Sendable {
    private let file: C11RelayStateFile<[String: [String: Int64]]>
    static let keepMilliseconds: Int64 = C11RelayAuth.spoolMaxAgeMilliseconds + 60 * 60 * 1000
    static let perTerminalLimit = 8192

    init(url: URL?) { file = C11RelayStateFile(url: url, empty: [:]) }

    static func key(machine: String, panel: String, creation: String) -> String {
        "\(machine)|\(panel.lowercased())|\(creation.lowercased())"
    }

    func isApplied(key: String, id: String) -> Bool { file.read { $0[key]?[id] != nil } }

    /// Records ids as applied, in one write, before they run. Prunes inside
    /// the same update: ids past the keep time, the oldest past the limit,
    /// and this machine's terminals that no longer run (others' untouched).
    func recordApplied(_ entries: [(key: String, id: String)], machine: String, running: Set<String>, now: Int64) {
        file.update { state in
            for entry in entries { state[entry.key, default: [:]][entry.id] = now }
            let prefix = "\(machine)|"
            for key in Array(state.keys) {
                if key.hasPrefix(prefix), !running.contains(key) { state.removeValue(forKey: key); continue }
                var ids = state[key] ?? [:]
                ids = ids.filter { now - $0.value <= Self.keepMilliseconds }
                if ids.count > Self.perTerminalLimit {
                    for (id, _) in ids.sorted(by: { $0.value < $1.value }).prefix(ids.count - Self.perTerminalLimit) {
                        ids.removeValue(forKey: id)
                    }
                }
                state[key] = ids.isEmpty ? nil : ids
            }
        }
    }

    private static let lock = NSLock()
    private static var bySession: [String: C11RelaySpoolMarks] = [:]

    /// One per local session, under c11's support folder.
    static func shared(session: String) -> C11RelaySpoolMarks {
        lock.lock(); defer { lock.unlock() }
        if let existing = bySession[session] { return existing }
        let made = C11RelaySpoolMarks(url: C11RelayKeyring.isName(session)
            ? C11RelayPickupLedger.stateFolder.appendingPathComponent("spool-applied/\(session).json") : nil)
        bySession[session] = made
        return made
    }
}

/// C11H-176: pickup documents c11 wrote and has not seen claimed, and the
/// creations whose pickup was never claimed. Such a credential is refused
/// (whoever took the document, the terminal never did), and a document left
/// behind when c11 quit is removed at the machine's next link-up.
final class C11RelayPickupLedger: @unchecked Sendable {
    struct Pending: Codable, Equatable {
        let machine: String
        let name: String
        let creation: String
        let masked: String
        let at: Int64
    }

    struct State: Codable {
        var pending: [String: Pending] = [:]
        var revoked: [String: Int64] = [:]
    }

    static let revokedLimit = 1024
    private let file: C11RelayStateFile<State>

    init(url: URL?) { file = C11RelayStateFile(url: url, empty: State()) }

    static var stateFolder: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent(C11Identity.stateDirectoryName, isDirectory: true)
            .appendingPathComponent("relay", isDirectory: true)
    }

    func add(_ pending: Pending) { file.update { $0.pending[pending.name] = pending } }

    func pending(machine: String, olderThan cutoff: Int64) -> [Pending] {
        file.read { state in state.pending.values.filter { $0.machine == machine && $0.at <= cutoff }.sorted { $0.at < $1.at } }
    }

    /// The pickup was claimed (its document is gone): nothing to keep.
    func claimed(_ name: String) { file.update { $0.pending.removeValue(forKey: name) } }

    /// The pickup was never claimed: its document is removed and its
    /// credential refused from now on.
    func unclaimed(_ name: String, creation: String, at: Int64) {
        file.update { state in
            state.pending.removeValue(forKey: name)
            state.revoked[creation.lowercased()] = at
            if state.revoked.count > Self.revokedLimit,
               let oldest = state.revoked.min(by: { $0.value < $1.value })?.key {
                state.revoked.removeValue(forKey: oldest)
            }
        }
    }

    func isRevoked(creation: String) -> Bool { file.read { $0.revoked[creation.lowercased()] != nil } }

    /// A removed machine's pickups are settled by its revoked secret; they
    /// are not kept waiting for a link-up that never comes.
    func forget(machine: String) {
        guard file.read({ $0.pending.values.contains { $0.machine == machine } }) else { return }
        file.update { $0.pending = $0.pending.filter { $0.value.machine != machine } }
    }

    private static let lock = NSLock()
    private static var bySession: [String: C11RelayPickupLedger] = [:]

    /// One per local session, shared by the session that writes pickups and
    /// the relay service that checks them.
    static func shared(session: String) -> C11RelayPickupLedger {
        lock.lock(); defer { lock.unlock() }
        if let existing = bySession[session] { return existing }
        let made = C11RelayPickupLedger(url: C11RelayKeyring.isName(session)
            ? stateFolder.appendingPathComponent("pickups/\(session).json") : nil)
        bySession[session] = made
        return made
    }
}
