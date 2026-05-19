import Foundation

/// C11-104 — `MetadataDeriver` protocol seam (E1 reframe per the
/// trident plan-review). The idea: c11 will accumulate several
/// derived metadata sources over time (worktree/branch from gitfs;
/// host / SSH target; container; kubectl context; AWS profile; …).
/// A tiny uniform interface lets the next deriver land in a day, not
/// a week.
///
/// `GitContextDeriver` is the first concrete deriver. A
/// `DerivationCoordinator` runs derivers off-main on a shared queue
/// and hops back to the main actor with the result. Apply-side
/// gen-token + expected-cwd guards live in the caller — `TabManager`
/// already implements them for the existing probe path
/// (`applyWorkspaceGitMetadataSnapshot`). The coordinator is
/// intentionally lightweight in this PR; full integration with the
/// staggered TabManager probe is deferred (the current implementation
/// continues to call `GitContextResolver.resolve` directly from
/// `initialWorkspaceGitMetadataSnapshot`).

public protocol MetadataDeriver: Sendable {
    /// Each deriver returns its own value type — git returns
    /// `ResolvedGitContext`; a future host deriver returns its own.
    associatedtype Output: Sendable

    /// Run off-main. Implementations MUST trap main-thread invocation
    /// with `dispatchPrecondition(condition: .notOnQueue(.main))` so
    /// a typing-latency regression is caught at runtime.
    func derive(cwd: String) -> Output?
}

/// Concrete deriver wrapping `GitContextResolver.resolve`. A struct
/// (not a singleton) so each coordinator can hold its own runner /
/// filesystem / timeout configuration without contention.
public struct GitContextDeriver: MetadataDeriver {
    public let runner: GitRunner
    public let fileSystem: FileSystemProbe

    public init(
        runner: GitRunner = ProcessGitRunner(),
        fileSystem: FileSystemProbe = DefaultFileSystemProbe()
    ) {
        self.runner = runner
        self.fileSystem = fileSystem
    }

    public func derive(cwd: String) -> ResolvedGitContext? {
        return GitContextResolver.resolve(
            cwd: cwd,
            runner: runner,
            fileSystem: fileSystem
        )
    }
}

/// Lightweight coordinator that runs a deriver off-main on a known
/// queue and hops back to main with the result. Future expansion:
/// gen-token + expected-cwd guard pattern (currently lives in
/// `TabManager.applyWorkspaceGitMetadataSnapshot`).
public enum DerivationCoordinator {
    /// Shared background queue. Distinct label from the legacy
    /// `initialWorkspaceGitProbeQueue` so failures can be traced
    /// per-mechanism; both run at `.userInitiated`.
    public static let queue = DispatchQueue(
        label: "com.stage11.c11.metadata-derivers",
        qos: .userInitiated
    )

    /// Run a deriver off-main and call `completion` on the main
    /// actor with its output.
    public static func run<D: MetadataDeriver>(
        deriver: D,
        cwd: String,
        completion: @escaping @Sendable (D.Output?) -> Void
    ) {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.async {
            let result = deriver.derive(cwd: cwd)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

/// C11-104 — derived sidebar metadata for "which worktree + which branch."
///
/// `GitContextResolver` runs `git rev-parse` against a cwd off the main
/// thread and returns a structured value the sidebar can project into
/// chips. The resolver is pure-logic (no SwiftUI / AppKit) so it can run
/// inside `c11LogicTests` against temp-dir-built repos.
///
/// Hot-path discipline: do not call this on the main actor. The OSC 7
/// cwd-update handler in `TabManager` already dispatches to a background
/// queue; the resolver shares that queue.

public enum BranchValue: Equatable, Sendable {
    case attached(String)
    case detached(shortSHA: String)
    /// Worktree pointing at a deleted branch, or any other "git couldn't
    /// name a ref" degraded state. Rendered as "(no branch)" in the
    /// sidebar — never thrown.
    case unknown
}

public enum GitContextKind: Equatable, Sendable {
    case mainCheckout(branch: BranchValue)
    case linkedWorktree(basename: String, absolutePath: String, branch: BranchValue)
}

public struct GitSubmoduleContext: Equatable, Sendable {
    public let name: String           // basename of submodule's working tree
    public let absolutePath: String   // submodule worktree path (for hashing if ever needed)
    public let branch: BranchValue

    public init(name: String, absolutePath: String, branch: BranchValue) {
        self.name = name
        self.absolutePath = absolutePath
        self.branch = branch
    }
}

public struct ResolvedGitContext: Equatable, Sendable {
    public let outer: GitContextKind
    public let inner: GitSubmoduleContext?

    public init(outer: GitContextKind, inner: GitSubmoduleContext? = nil) {
        self.outer = outer
        self.inner = inner
    }
}

/// Pluggable seam for `git` invocation so tests can stub deterministic
/// behavior without spawning real processes. Default production
/// implementation is `ProcessGitRunner` below.
public protocol GitRunner: Sendable {
    /// Run `git <args>` with `cwd` as the working directory.
    /// Return trimmed stdout on success; nil on failure (non-zero exit,
    /// timeout, exec error, or empty stdout). Test doubles may also
    /// return nil to simulate a failure path.
    func run(cwd: String, args: [String]) -> String?
}

/// Pluggable seam for filesystem checks (cwd existence, HEAD mtime).
public protocol FileSystemProbe: Sendable {
    func fileExists(atPath: String) -> Bool
    func mtime(atPath: String) -> Date?
}

public struct DefaultFileSystemProbe: FileSystemProbe {
    public init() {}
    public func fileExists(atPath path: String) -> Bool {
        return FileManager.default.fileExists(atPath: path)
    }
    public func mtime(atPath path: String) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.modificationDate] as? Date
    }
}

/// Process-backed runner. Bounded by a soft timeout to avoid stalling
/// the background queue if git ever hangs.
public struct ProcessGitRunner: GitRunner {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 5.0) {
        self.timeout = timeout
    }

    public func run(cwd: String, args: [String]) -> String? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = stdout
        process.standardError = stderr
        // 1-byte stdin so a paranoid hang in a child waiting on stdin
        // cannot stall us. Same shape as TabManager.runCommandResult.
        let stdin = Pipe()
        process.standardInput = stdin

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }
        stdin.fileHandleForWriting.closeFile()

        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 0.2)
            }
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum GitContextResolver {
    /// Maximum branch label length surfaced to consumers. The canonical
    /// `branch` metadata key is capped at 64 chars (`SurfaceMetadataStore`);
    /// resolver-side enforcement keeps the value renderable even when a
    /// real-world branch name exceeds the cap. Middle-truncate with `…`.
    public static let maxBranchLabelLength = 64

    /// Resolve the worktree + branch context for `cwd`.
    /// Returns nil for:
    ///   - cwd doesn't exist on disk
    ///   - cwd is not inside a git working tree
    ///   - cwd is a bare clone
    ///
    /// Must run off the main thread. The resolver shells out to `git`
    /// and is bounded by a soft timeout per call — running this on main
    /// will block typing latency. A `dispatchPrecondition` traps the
    /// misuse at the entry point so test runs catch it deterministically.
    public static func resolve(
        cwd: String,
        runner: GitRunner = ProcessGitRunner(),
        fileSystem: FileSystemProbe = DefaultFileSystemProbe()
    ) -> ResolvedGitContext? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !cwd.isEmpty, fileSystem.fileExists(atPath: cwd) else {
            return nil
        }

        // Step 1: superproject probe — runs first so that for any cwd
        // inside a submodule we can resolve BOTH contexts and stack
        // them per the spec.
        let superprojectRoot = runner.run(
            cwd: cwd,
            args: ["rev-parse", "--show-superproject-working-tree"]
        )

        // Step 2: outer resolution. If we're in a submodule, point at
        // the superproject; otherwise this is the working tree itself.
        let outerCwd = superprojectRoot ?? cwd
        guard let outer = resolveOuter(cwd: outerCwd, runner: runner) else {
            return nil
        }

        // Step 3: inner (submodule) resolution. Only run when we
        // actually detected a superproject.
        var inner: GitSubmoduleContext?
        if superprojectRoot != nil {
            inner = resolveSubmodule(cwd: cwd, runner: runner)
        }

        return ResolvedGitContext(outer: outer, inner: inner)
    }

    // MARK: - Internal

    /// Resolve "outer" — either a main checkout or a linked worktree.
    static func resolveOuter(cwd: String, runner: GitRunner) -> GitContextKind? {
        // Step A: discover the working tree top-level. Fails for
        // non-git directories and for bare clones (rev-parse
        // --show-toplevel errors in a bare repo). This single call
        // covers AC7 + AC8.
        guard let toplevel = runner.run(
            cwd: cwd,
            args: ["rev-parse", "--show-toplevel"]
        ), !toplevel.isEmpty else {
            return nil
        }

        // Step B: linked worktree vs main checkout.
        // --git-common-dir points at the shared .git/ for all worktrees;
        // --git-dir points at this worktree's own .git directory (which
        // for a linked worktree lives under common/.git/worktrees/<name>).
        // If they differ → linked worktree. Otherwise → main checkout.
        let commonDir = runner.run(cwd: cwd, args: ["rev-parse", "--git-common-dir"])
        let gitDir = runner.run(cwd: cwd, args: ["rev-parse", "--git-dir"])
        let isLinkedWorktree: Bool = {
            guard let common = commonDir, let mine = gitDir else { return false }
            // Normalize both to absolute paths before comparing — `--git-dir`
            // often returns "." inside a main checkout and the common dir
            // returns a relative form too.
            let commonAbs = absolutePath(of: common, relativeTo: cwd)
            let mineAbs = absolutePath(of: mine, relativeTo: cwd)
            return commonAbs != mineAbs
        }()

        let branch = resolveBranch(cwd: cwd, runner: runner)

        if isLinkedWorktree {
            let basename = (toplevel as NSString).lastPathComponent
            return .linkedWorktree(
                basename: basename,
                absolutePath: toplevel,
                branch: branch
            )
        } else {
            return .mainCheckout(branch: branch)
        }
    }

    static func resolveSubmodule(cwd: String, runner: GitRunner) -> GitSubmoduleContext? {
        guard let toplevel = runner.run(
            cwd: cwd,
            args: ["rev-parse", "--show-toplevel"]
        ), !toplevel.isEmpty else {
            return nil
        }
        let superprojectRoot = runner.run(
            cwd: cwd,
            args: ["rev-parse", "--show-superproject-working-tree"]
        )
        let name = resolveSubmoduleName(
            submoduleToplevel: toplevel,
            superprojectRoot: superprojectRoot,
            runner: runner
        )
        let branch = resolveBranch(cwd: cwd, runner: runner)
        return GitSubmoduleContext(
            name: name,
            absolutePath: toplevel,
            branch: branch
        )
    }

    /// Submodule display-name fallback chain (plan-review v2):
    ///   1. `.gitmodules` configured submodule name (the
    ///      `[submodule "<name>"]` section header in
    ///      `<superproject>/.gitmodules`).
    ///   2. Path from the superproject root (e.g., `vendor/bonsplit`).
    ///   3. Basename of the submodule's working tree (e.g.,
    ///      `bonsplit`).
    static func resolveSubmoduleName(
        submoduleToplevel: String,
        superprojectRoot: String?,
        runner: GitRunner
    ) -> String {
        let basename = (submoduleToplevel as NSString).lastPathComponent

        guard let superprojectRoot, !superprojectRoot.isEmpty else {
            return basename
        }

        // Path-from-superproject-root.
        let relativePath = relativePathFromSuperproject(
            superprojectRoot: superprojectRoot,
            submoduleToplevel: submoduleToplevel
        )

        // Try `.gitmodules` configured name. The submodule.<name>.path
        // entry maps the configured name to the relative path. We
        // look up by relative path and pull the section name.
        if let relative = relativePath,
           let configured = configuredSubmoduleName(
               superprojectRoot: superprojectRoot,
               relativePath: relative,
               runner: runner
           ) {
            return configured
        }

        if let relative = relativePath, !relative.isEmpty {
            return relative
        }
        return basename
    }

    static func relativePathFromSuperproject(
        superprojectRoot: String,
        submoduleToplevel: String
    ) -> String? {
        let superNorm = (superprojectRoot as NSString).standardizingPath
        let subNorm = (submoduleToplevel as NSString).standardizingPath
        let withSlash = superNorm.hasSuffix("/") ? superNorm : superNorm + "/"
        guard subNorm.hasPrefix(withSlash) else { return nil }
        let rel = String(subNorm.dropFirst(withSlash.count))
        return rel.isEmpty ? nil : rel
    }

    static func configuredSubmoduleName(
        superprojectRoot: String,
        relativePath: String,
        runner: GitRunner
    ) -> String? {
        // `git config -f .gitmodules --get-regexp 'submodule\..*\.path'`
        // returns lines like `submodule.vendor/bonsplit.path vendor/bonsplit`.
        // Caveat: configured names can contain dots, so the regex above
        // is greedy. Match against the trailing value (relative path)
        // and pull the section name in between.
        guard let output = runner.run(
            cwd: superprojectRoot,
            args: ["config", "-f", ".gitmodules", "--get-regexp", #"submodule\..*\.path"#]
        ) else {
            return nil
        }
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = parts[1]
            guard value == relativePath else { continue }
            // key is `submodule.<name>.path` — strip `submodule.`
            // prefix and `.path` suffix.
            guard key.hasPrefix("submodule.") && key.hasSuffix(".path") else { continue }
            let trimmed = String(key.dropFirst("submodule.".count).dropLast(".path".count))
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func resolveBranch(cwd: String, runner: GitRunner) -> BranchValue {
        // Attached ref?
        if let attached = runner.run(
            cwd: cwd,
            args: ["symbolic-ref", "--short", "HEAD"]
        ), !attached.isEmpty {
            return .attached(truncateBranchLabel(attached))
        }
        // Detached HEAD?
        if let short = runner.run(
            cwd: cwd,
            args: ["rev-parse", "--short=7", "HEAD"]
        ), !short.isEmpty {
            return .detached(shortSHA: short)
        }
        // Worktree pointing at a deleted branch, broken HEAD, or other
        // graceful-degrade case.
        return .unknown
    }

    /// Middle-truncate a branch label so the canonical metadata cap is
    /// never breached. Long branch names (e.g., release/2025-q3/...) are
    /// shortened to `<prefix>…<suffix>` keeping head and tail context.
    /// Plan-review I7.
    static func truncateBranchLabel(_ raw: String) -> String {
        guard raw.count > maxBranchLabelLength else { return raw }
        let budget = maxBranchLabelLength - 1  // 1 char for "…"
        let head = budget / 2
        let tail = budget - head
        let prefix = raw.prefix(head)
        let suffix = raw.suffix(tail)
        return "\(prefix)…\(suffix)"
    }

    // MARK: - Path utilities

    /// Resolve a git-reported path (which may be relative to `cwd` or
    /// already absolute) to an absolute filesystem path.
    static func absolutePath(of path: String, relativeTo cwd: String) -> String {
        if path.hasPrefix("/") {
            return (path as NSString).standardizingPath
        }
        let joined = (cwd as NSString).appendingPathComponent(path)
        return (joined as NSString).standardizingPath
    }

    /// Returns the absolute path of `.git/HEAD` for cache invalidation,
    /// using `git rev-parse --git-path HEAD` so worktree gitfile
    /// indirection is handled correctly.
    public static func headPath(
        forCwd cwd: String,
        runner: GitRunner = ProcessGitRunner()
    ) -> String? {
        guard let raw = runner.run(cwd: cwd, args: ["rev-parse", "--git-path", "HEAD"]) else {
            return nil
        }
        return absolutePath(of: raw, relativeTo: cwd)
    }
}

/// Cache for resolver results keyed by `(cwd, headMtime)`.
///
/// Lives on the off-main probe queue alongside `GitContextResolver`.
/// LRU evicts at `capacity`. Cache invalidation is implicit: a cwd
/// change yields a different key, and a `.git/HEAD` mtime change
/// (post-checkout, post-rename) yields a different key.
public final class GitContextResolverCache: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public let cwd: String
        public let headMtime: Date?
        public init(cwd: String, headMtime: Date?) {
            self.cwd = cwd
            self.headMtime = headMtime
        }
    }

    private let capacity: Int
    private var entries: [Key: ResolvedGitContext?] = [:]
    private var order: [Key] = []
    private let lock = NSLock()

    public init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    public func get(_ key: Key) -> ResolvedGitContext?? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = entries[key] else { return nil }
        // Bump recency.
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return .some(cached)
    }

    public func set(_ key: Key, value: ResolvedGitContext?) {
        lock.lock()
        defer { lock.unlock() }
        if entries[key] == nil {
            order.append(key)
        } else if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        entries[key] = value
        while order.count > capacity, let oldest = order.first {
            entries.removeValue(forKey: oldest)
            order.removeFirst()
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
