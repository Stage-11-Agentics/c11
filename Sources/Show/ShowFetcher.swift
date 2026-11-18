import Foundation
import Darwin

/// Size and modification time of a shown file: the live-reload signal.
struct ShowFileStat: Equatable, Sendable {
    var size: Int64
    /// The modification time as the machine printed it (seconds, maybe with a fraction).
    var mtime: String
}

enum ShowFetchError: Error, Equatable {
    case notFound
    case notFile
    case tooLarge(Int64)
    case outsideRoot
    case unreachable(String)

    var code: String {
        switch self {
        case .notFound: return ShowSpec.Code.notFound
        case .notFile: return ShowSpec.Code.notFile
        case .tooLarge: return ShowSpec.Code.tooLarge
        case .outsideRoot: return ShowSpec.Code.badDir
        case .unreachable: return ShowSpec.Code.unreachable
        }
    }

    var message: String {
        switch self {
        case .notFound: return String(localized: "show.fetch.notFound", defaultValue: "no such file")
        case .notFile: return String(localized: "show.fetch.notFile", defaultValue: "not a regular file")
        case .tooLarge(let size):
            return String(format: String(localized: "show.fetch.tooLarge", defaultValue: "%lld MB: %@"),
                          Int64((Double(size) / 1_048_576).rounded(.up)), ShowSpec.tooLargeMessage())
        case .outsideRoot: return String(localized: "show.fetch.outsideRoot", defaultValue: "outside the shown folder")
        case .unreachable(let reason):
            if reason.isEmpty { return String(localized: "show.fetch.unreachablePlain", defaultValue: "the machine did not answer") }
            return String(format: String(localized: "show.fetch.unreachable", defaultValue: "the machine did not answer: %@"), reason)
        }
    }
}

/// Where a viewer reads its bytes. Every call runs off main; implementations
/// never touch AppKit. `root`, when set, is an absolute folder the file must
/// lie strictly inside after the machine that holds it resolves symlinks.
protocol ShowFetcher: Sendable {
    func stat(_ path: String) async throws -> ShowFileStat
    func read(_ path: String, root: String?, maxBytes: Int) async throws -> Data
}

/// A file on c11's own Mac. Assets under a root go through
/// `MarkdownAssetRoot` (pinned folder, no symlink escape, no traversal).
struct ShowLocalFetcher: ShowFetcher {
    func stat(_ path: String) async throws -> ShowFileStat {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var info = Darwin.stat()
        guard fstatat(AT_FDCWD, real, &info, 0) == 0 else { throw ShowFetchError.notFound }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ShowFetchError.notFile }
        let mtime = "\(info.st_mtimespec.tv_sec).\(String(format: "%09ld", info.st_mtimespec.tv_nsec))"
        return ShowFileStat(size: Int64(info.st_size), mtime: mtime)
    }

    func read(_ path: String, root: String?, maxBytes: Int) async throws -> Data {
        if let root {
            let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
            guard let pinned = MarkdownAssetRoot(directory: rootURL) else { throw ShowFetchError.notFound }
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard ShowAssetPath.isInside(real, root: pinned.directory.path) else { throw ShowFetchError.outsideRoot }
            let relative = String(real.dropFirst(pinned.directory.path.count + 1))
            do { return try pinned.read(path: relative, maximumBytes: maxBytes) }
            catch let error as CocoaError where error.code == .fileReadTooLarge {
                throw ShowFetchError.tooLarge(Int64(maxBytes) + 1)
            } catch {
                throw FileManager.default.fileExists(atPath: real) ? ShowFetchError.outsideRoot : ShowFetchError.notFound
            }
        }
        let info = try await stat(path)
        guard info.size <= Int64(maxBytes) else { throw ShowFetchError.tooLarge(info.size) }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: real, options: [.uncached]) else { throw ShowFetchError.notFound }
        guard data.count <= maxBytes else { throw ShowFetchError.tooLarge(Int64(data.count)) }
        return data
    }
}

/// What one `machine.exec` answered: exit code (nil when a signal or the
/// timeout ended it), stdout, and whether hc kept only the first 8 MB.
struct ShowExecResult: Equatable, Sendable {
    var code: Int32?
    var stdout: Data
    var truncated: Bool = false
}

/// The hc calls a remote fetch needs (`machine.exec` with `on`). The relay's
/// session host implements it; tests pass a fake.
protocol ShowExecHost: Sendable {
    /// Runs `argv` on `machine` as given, no shell.
    func showExec(machine: String, argv: [String], timeout: TimeInterval) async throws -> ShowExecResult
}

/// A file on a linked machine, read through hc's link with `machine.exec`.
/// Every argv is fixed and literal: a known program (`realpath`, `stat`,
/// `cat`), its fixed options, `--`, then the absolute path as one argument.
/// No shell runs, so no path (a leading `-`, spaces, quotes, `$`, `;`) can
/// change the command. Symlinks are resolved on the machine that holds the
/// file, so `--dir` is checked where it lives. A container caller's file is
/// reached through `incus exec <container> --` on that machine.
struct ShowHCFetcher: ShowFetcher {
    let host: any ShowExecHost
    let machine: String
    /// The Incus container the caller runs in, from hc's own facts about its terminal.
    let container: String?
    /// C11H-359 (L3): the link this fetcher reads through; the stat flavor
    /// learned on one link is never another's.
    var link: C11RelayLinkRef? = nil
    var statTimeout: TimeInterval = 5
    var readTimeout: TimeInterval = 30

    /// GNU and BSD `stat` take different format options; the one a machine
    /// speaks is learned once and kept.
    enum StatFlavor: String, CaseIterable, Sendable {
        case gnu, bsd
        var options: [String] {
            switch self {
            case .gnu: return ["-L", "-c", "%F|%s|%.9Y"]
            case .bsd: return ["-L", "-f", "%HT|%z|%Fm"]
            }
        }
    }

    static let flavors = ShowFlavorCache()

    /// The full argv for `program` with its fixed options and the path last, after `--`.
    func argv(_ program: String, _ options: [String], path: String) -> [String] {
        let command = [program] + options + ["--", path]
        guard let container else { return command }
        return ["incus", "exec", container, "--"] + command
    }

    private var cacheKey: String {
        [link?.session ?? "", machine, link?.linkID ?? "", container ?? ""].joined(separator: "\u{1F}")
    }

    func stat(_ path: String) async throws -> ShowFileStat {
        guard path.hasPrefix("/") else { throw ShowFetchError.notFound }
        let known = Self.flavors.flavor(for: cacheKey)
        for flavor in known.map({ [$0] }) ?? StatFlavor.allCases {
            let result = try await run(argv("stat", flavor.options, path: path), timeout: statTimeout)
            guard result.code == 0 else {
                if known != nil { throw ShowFetchError.notFound }
                continue
            }
            Self.flavors.set(flavor, for: cacheKey)
            guard let parsed = Self.parseStat(result.stdout) else { throw ShowFetchError.unreachable(
                String(localized: "show.fetch.unreadableStat", defaultValue: "unreadable stat answer")) }
            guard parsed.isRegular else { throw ShowFetchError.notFile }
            return parsed.stat
        }
        throw ShowFetchError.notFound
    }

    func read(_ path: String, root: String?, maxBytes: Int) async throws -> Data {
        guard path.hasPrefix("/") else { throw ShowFetchError.notFound }
        var target = path
        if let root {
            guard root.hasPrefix("/") else { throw ShowFetchError.outsideRoot }
            let resolvedRoot = try await realpath(root)
            target = try await realpath(path)
            guard ShowAssetPath.isInside(target, root: resolvedRoot) else { throw ShowFetchError.outsideRoot }
        }
        let result = try await run(argv("cat", [], path: target), timeout: readTimeout)
        guard result.code == 0 else { throw ShowFetchError.notFound }
        guard !result.truncated, result.stdout.count <= maxBytes else {
            throw ShowFetchError.tooLarge(Int64(max(result.stdout.count, maxBytes + 1)))
        }
        return result.stdout
    }

    func realpath(_ path: String) async throws -> String {
        let result = try await run(argv("realpath", [], path: path), timeout: statTimeout)
        guard result.code == 0 else { throw ShowFetchError.notFound }
        let resolved = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard resolved.hasPrefix("/") else { throw ShowFetchError.notFound }
        return resolved
    }

    private func run(_ argv: [String], timeout: TimeInterval) async throws -> ShowExecResult {
        do {
            return try await host.showExec(machine: machine, argv: argv, timeout: timeout)
        } catch let error as ShowFetchError {
            throw error
        } catch {
            throw ShowFetchError.unreachable("\(error)")
        }
    }

    /// `<type>|<size>|<mtime>`, from either flavor.
    static func parseStat(_ data: Data) -> (stat: ShowFileStat, isRegular: Bool)? {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let size = Int64(parts[1]), !parts[2].isEmpty else { return nil }
        return (ShowFileStat(size: size, mtime: parts[2]), parts[0].lowercased().hasPrefix("regular"))
    }
}

final class ShowFlavorCache: @unchecked Sendable {
    private let lock = NSLock()
    private var flavors: [String: ShowHCFetcher.StatFlavor] = [:]
    func flavor(for key: String) -> ShowHCFetcher.StatFlavor? { lock.lock(); defer { lock.unlock() }; return flavors[key] }
    func set(_ flavor: ShowHCFetcher.StatFlavor, for key: String) { lock.lock(); flavors[key] = flavor; lock.unlock() }
}

/// A remote fetcher bound to the link that verified its caller rather than a
/// live connection. C11H-359 (L3): with no link, or once that link's secret
/// has changed, it reads nothing; another link to the same machine name never
/// stands in for it.
struct ShowLinkedFetcher: ShowFetcher {
    let hosts: ShowHosts
    let machine: String
    let container: String?
    let link: C11RelayLinkRef?

    private func resolved() throws -> ShowHCFetcher {
        guard let link, link.machine == machine, let host = hosts.host(for: link) else { throw ShowFetchError.unreachable(
            String(format: String(localized: "show.fetch.noLink", defaultValue: "no link to %@"), machine)) }
        return ShowHCFetcher(host: host, machine: machine, container: container, link: link)
    }

    func stat(_ path: String) async throws -> ShowFileStat { try await resolved().stat(path) }

    func read(_ path: String, root: String?, maxBytes: Int) async throws -> Data {
        try await resolved().read(path, root: root, maxBytes: maxBytes)
    }
}

/// What c11 needs from a machine link for `c11 show`: run the read
/// program, leave a point-and-say screenshot, and keep the durable record.
protocol ShowLinkHost: ShowExecHost {
    func showWriteFile(machine: String, path: String, data: Data) async throws -> String
}

/// The hc link for each linked machine, kept by the relay service as
/// machines come up, so a viewer can fetch after a restart or a Feed open.
/// C11H-359 (L3): kept per local session (shard) and machine, and handed out
/// only for the link secret a caller was verified with: a link to the same
/// machine name in another shard, or one re-made since, is never used.
final class ShowHosts: @unchecked Sendable {
    struct Link {
        let host: any ShowLinkHost
        let records: any ShowRecordStore
        /// The id of the link's current secret (nil when it has none).
        var currentLinkID: @Sendable () -> String? = { nil }
    }

    private struct Key: Hashable {
        let session: String
        let machine: String
    }

    static let shared = ShowHosts()
    private let lock = NSLock()
    private var links: [Key: Link] = [:]

    func set(_ link: Link?, session: String, machine: String) {
        lock.lock(); defer { lock.unlock() }
        links[Key(session: session, machine: machine)] = link
    }

    /// The link `ref` names, while its secret is still the one `ref` was verified with.
    func link(for ref: C11RelayLinkRef) -> Link? {
        lock.lock()
        let link = links[Key(session: ref.session, machine: ref.machine)]
        lock.unlock()
        guard let link, link.currentLinkID() == ref.linkID else { return nil }
        return link
    }

    func host(for ref: C11RelayLinkRef) -> (any ShowExecHost)? { link(for: ref)?.host }
}

/// Where a show's bytes live, resolved by c11, never by the request.
enum ShowOrigin: Equatable, Sendable {
    /// c11's own Mac.
    case local
    /// A linked machine, optionally inside one of its Incus containers,
    /// reached through the link that verified the caller (C11H-359).
    case remote(machine: String, container: String?, link: C11RelayLinkRef? = nil)

    var machineName: String {
        switch self {
        case .local: return ShowSpec.localMachine
        case .remote(let machine, let container, _): return container.map { "\(machine)-\($0)" } ?? machine
        }
    }

    var isRemote: Bool { if case .remote = self { return true }; return false }

    /// The fetcher for this origin. A remote one looks its machine's link up
    /// on each call, so a viewer restored before the link is back starts
    /// working when it is.
    func fetcher(hosts: ShowHosts = .shared) -> any ShowFetcher {
        switch self {
        case .local: return ShowLocalFetcher()
        case .remote(let machine, let container, let link):
            return ShowLinkedFetcher(hosts: hosts, machine: machine, container: container, link: link)
        }
    }

    /// The Incus container a remote terminal runs in, from its hc foreground
    /// (`incus exec <container> [options] -- …`), or nil. The process is
    /// `incus` by its name or its argv[0]: `<host>-seat` launches with
    /// `exec -a <harness>`, so argv[0] names the harness while the process
    /// stays `incus` (the same fact `AgentDetector` reads).
    static func container(foregroundName: String?, argv: [String]?) -> String? {
        guard let argv, argv.count >= 3 else { return nil }
        let program = (argv[0] as NSString).lastPathComponent
        let process = foregroundName.map { ($0 as NSString).lastPathComponent }
        guard program == "incus" || process == "incus", argv[1] == "exec" else { return nil }
        let name = argv[2]
        guard isContainerName(name) else { return nil }
        return name
    }

    static func container(fromForegroundArgv argv: [String]?) -> String? { container(foregroundName: nil, argv: argv) }

    static func isContainerName(_ name: String) -> Bool {
        !name.hasPrefix("-") && name.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,62}$"#, options: .regularExpression) != nil
    }
}
