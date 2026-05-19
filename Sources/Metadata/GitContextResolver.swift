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
/// (`applyWorkspaceGitMetadataSnapshot`).
///
/// (C11-106) Production status: `DerivationCoordinator` is a
/// **forward seam, not load-bearing in production.** The cache layer
/// (`GitContextResolverCache` + `GitContextResolver.resolveCached`)
/// is wired into `TabManager.initialWorkspaceGitMetadataSnapshot(for:)`
/// directly because the existing `initialWorkspaceGitProbeQueue`
/// already provides the off-main scheduling + cancellation that the
/// coordinator's async-completes-on-main shape would duplicate. The
/// coordinator stays here as the integration point for future
/// multi-deriver fan-out (host/SSH target, container, kubectl, AWS
/// profile, Lattice task). Adding a second deriver flips the cost
/// balance: see `skills/c11/references/metadata.md` § "How to add a
/// MetadataDeriver" for the contract a new deriver must satisfy.

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
    ///
    /// (C11-106) Renamed from `.unknown` to match the v2 SPEC's
    /// `BranchValue.noBranch` case name. Behavior is unchanged.
    case noBranch
}

public enum GitContextKind: Equatable, Sendable {
    case mainCheckout(branch: BranchValue)
    case linkedWorktree(basename: String, absolutePath: String, branch: BranchValue)
    /// (C11-106) Reserved for future explicit "cwd is not under a git
    /// tree" signals — the existing nil-`ResolvedGitContext` semantic
    /// still represents this case in production today, so the resolver
    /// does not construct `.notInRepo` directly. Future derivers and
    /// callers that want an explicit non-Optional return path can use
    /// this case without changing the type signature.
    case notInRepo
    /// (C11-106) Returned when `git rev-parse --git-path HEAD` resolves
    /// to a path that does not exist on disk — typical cause is a
    /// sibling pane running `git worktree remove`, which prunes the
    /// linked worktree's `.git/worktrees/<name>/HEAD` while the cwd
    /// directory may remain. The sidebar treats this the same as
    /// `.notInRepo` (chips clear); the cache MUST NOT store `.stale`
    /// results so that a recreated worktree is picked up on the next
    /// resolution.
    case stale
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
///
/// (C11-106) Defaults remain unchanged from C11-104 — `/usr/bin/env`
/// invokes the real `git` binary on PATH with a 5-second timeout. The
/// `executable` + `argPrefix` constructor params exist purely so AC14
/// tests can substitute a deterministic slow command (e.g.
/// `/bin/sh -c 'sleep …'`) without forking the production code path.
/// The 5-second timeout is the v2 SPEC's amended value — see PR body
/// for the SPEC-amendment note replacing the original 2s suggestion.
public struct ProcessGitRunner: GitRunner {
    public let executable: String
    public let argPrefix: [String]
    public let timeout: TimeInterval

    public init(
        executable: String = "/usr/bin/env",
        argPrefix: [String] = ["git"],
        timeout: TimeInterval = 5.0
    ) {
        self.executable = executable
        self.argPrefix = argPrefix
        self.timeout = timeout
    }

    public func run(cwd: String, args: [String]) -> String? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = argPrefix + args
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

        // (C11-106) `.stale` detection per v2 SPEC I6: if git resolves
        // a HEAD path but the file is missing on disk, the worktree
        // pointer was pruned (typical cause: `git worktree remove`
        // from a sibling pane). Return `.stale` so the sidebar can
        // clear chips and the cache wrapper can avoid storing the
        // result.
        if let resolvedHead = headPath(forCwd: cwd, runner: runner),
           !fileSystem.fileExists(atPath: resolvedHead) {
            return ResolvedGitContext(outer: .stale, inner: nil)
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
        // graceful-degrade case. (C11-106: renamed from `.unknown` to
        // `.noBranch` to match the v2 SPEC.)
        return .noBranch
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

    /// (C11-106) Cache-aware variant of `resolve(...)`. This is the
    /// **production entry point** wired into
    /// `TabManager.initialWorkspaceGitMetadataSnapshot(for:)`. The
    /// underlying `resolve(...)` remains the test-friendly direct
    /// path.
    ///
    /// Cache policy (C11-106 B2 + B3):
    ///   - Key = `(cwd, mtime(headPath), mtime(superHeadPath?))`. For
    ///     a submodule cwd, the superproject HEAD mtime is included
    ///     so a superproject branch change invalidates the combined
    ///     outer+inner context even when the inner submodule HEAD is
    ///     stable.
    ///   - `nil` results, `.stale` outer, and `.notInRepo` outer
    ///     bypass the cache entirely. A `git init` / `git worktree
    ///     add` / repaired HEAD is therefore picked up on the very
    ///     next resolve, not on cache TTL.
    ///   - Missing `headPath` (git can't resolve the HEAD path at
    ///     all) OR missing mtime (the file doesn't exist) also
    ///     bypass the cache for the same reason.
    ///
    /// Threading: same contract as `resolve(...)` — must run off the
    /// main thread. `GitContextResolverCache` is internally
    /// thread-safe (NSLock); the cache itself can therefore be
    /// shared across surfaces and queues, but the caller still
    /// reserves the right to choose its scheduling queue. In
    /// production (`TabManager`), this is invoked on
    /// `initialWorkspaceGitProbeQueue`.
    public static func resolveCached(
        cwd: String,
        cache: GitContextResolverCache,
        runner: GitRunner = ProcessGitRunner(),
        fileSystem: FileSystemProbe = DefaultFileSystemProbe()
    ) -> ResolvedGitContext? {
        dispatchPrecondition(condition: .notOnQueue(.main))

        // Build the cache key from the resolved HEAD path mtime. If
        // git can't resolve the HEAD path or the file is missing,
        // skip the cache entirely (B3 nil-result policy).
        guard let resolvedHead = headPath(forCwd: cwd, runner: runner),
              let headMtime = fileSystem.mtime(atPath: resolvedHead) else {
            cache.recordSkipNoHead()
            return resolve(cwd: cwd, runner: runner, fileSystem: fileSystem)
        }

        // For submodules: include the superproject's HEAD mtime in
        // the key. This is the v2 SPEC § B2 correctness fix. If
        // the superproject HEAD path is unavailable or its mtime
        // can't be read, we set the field to `nil` — the key still
        // disambiguates from non-submodule resolutions, and a
        // subsequent superproject HEAD mtime change re-resolves on
        // its own when the cwd's own HEAD mtime advances (covers
        // the common case of `git checkout` updating both at once).
        var superHeadMtime: Date? = nil
        if let superRoot = runner.run(
            cwd: cwd,
            args: ["rev-parse", "--show-superproject-working-tree"]
        ), !superRoot.isEmpty,
           let superHead = headPath(forCwd: superRoot, runner: runner),
           let m = fileSystem.mtime(atPath: superHead) {
            superHeadMtime = m
        }

        let key = GitContextResolverCache.Key(
            cwd: cwd,
            headMtime: headMtime,
            superHeadMtime: superHeadMtime
        )

        if let cached = cache.get(key) {
            return cached
        }
        cache.recordMiss()

        let resolved = resolve(cwd: cwd, runner: runner, fileSystem: fileSystem)

        // B3: don't cache nil / .stale / .notInRepo.
        guard let resolved else {
            cache.recordSkipNotInRepo()
            return nil
        }
        switch resolved.outer {
        case .stale:
            cache.recordSkipStale()
            return resolved
        case .notInRepo:
            cache.recordSkipNotInRepo()
            return resolved
        case .mainCheckout, .linkedWorktree:
            cache.set(key, value: resolved)
            return resolved
        }
    }
}

/// Cache for resolver results keyed by `(cwd, headMtime, superHeadMtime?)`.
///
/// Lives on the off-main probe queue alongside `GitContextResolver`. LRU
/// evicts at `capacity`. Cache invalidation is implicit:
///   - cwd change → different key.
///   - `.git/HEAD` mtime change (post-checkout, post-rename) → different key.
///   - Inside a submodule, the superproject's HEAD mtime is *also*
///     part of the key (C11-106 B2 fix). A superproject branch
///     change while the submodule HEAD is stable invalidates the
///     combined outer+inner context.
///
/// **What the cache stores.** The cache only stores results whose
/// outer is `.mainCheckout` or `.linkedWorktree`. `.stale`, `.notInRepo`,
/// and nil results bypass the cache entirely (C11-106 B3 policy) so a
/// recovered worktree / `git init` / repaired HEAD is picked up on the
/// next resolve.
///
/// TODO(c11-followup): FSEvents-based invalidation is the structural
/// replacement for mtime polling. See plan-review pack
/// `.lattice/orchestration/c11-106/c11-106-plan-review-pack-2026-05-19T0935/`
/// § S3. Out of scope for C11-106.
public final class GitContextResolverCache: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public let cwd: String
        public let headMtime: Date
        /// Superproject HEAD mtime when `cwd` is inside a submodule;
        /// `nil` when there is no superproject. Including it in the
        /// key keeps the submodule-combined context invalidated when
        /// the outer (superproject) HEAD changes even if the inner
        /// (submodule) HEAD is stable — C11-106 v2 SPEC § B2.
        public let superHeadMtime: Date?
        public init(cwd: String, headMtime: Date, superHeadMtime: Date? = nil) {
            self.cwd = cwd
            self.headMtime = headMtime
            self.superHeadMtime = superHeadMtime
        }
    }

    private let capacity: Int
    private var entries: [Key: ResolvedGitContext] = [:]
    private var order: [Key] = []
    private let lock = NSLock()

    // MARK: - Diagnostic counters (C11-106 E3, DEBUG-only readers)
    // Internal so the resolver and tests can bump them; readers below
    // are DEBUG-gated. Production never reads these — they exist for
    // future observability work and to surface cache hit-rate during
    // local debugging.
    internal var _hits: Int = 0
    internal var _misses: Int = 0
    internal var _skipsStale: Int = 0       // .stale results bypass cache
    internal var _skipsNoHead: Int = 0       // headPath / mtime unavailable
    internal var _skipsNotInRepo: Int = 0    // nil-result / .notInRepo bypass

    public init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    /// Look up `key`. Returns the cached non-nil result, or nil for
    /// "not in cache." Cache hits bump recency. `(C11-106)` The
    /// return type is `ResolvedGitContext?` — non-nil means "cache
    /// hit, here's the value"; nil means "cache miss, caller must
    /// resolve."
    public func get(_ key: Key) -> ResolvedGitContext? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = entries[key] else { return nil }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        _hits += 1
        return cached
    }

    /// Store a non-nil resolver result. Callers MUST NOT pass
    /// `.stale` or `.notInRepo` outer values — those are bypass
    /// states (C11-106 B3). The runtime caller checks; this method
    /// asserts in DEBUG to catch regressions.
    public func set(_ key: Key, value: ResolvedGitContext) {
        #if DEBUG
        switch value.outer {
        case .mainCheckout, .linkedWorktree:
            break
        case .stale, .notInRepo:
            assertionFailure("GitContextResolverCache.set called with non-cacheable outer \(value.outer); caller must short-circuit per C11-106 B3 policy.")
            return
        }
        #else
        switch value.outer {
        case .mainCheckout, .linkedWorktree:
            break
        case .stale, .notInRepo:
            return
        }
        #endif
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

    internal func recordMiss() {
        lock.lock()
        defer { lock.unlock() }
        _misses += 1
    }

    internal func recordSkipStale() {
        lock.lock()
        defer { lock.unlock() }
        _skipsStale += 1
    }

    internal func recordSkipNoHead() {
        lock.lock()
        defer { lock.unlock() }
        _skipsNoHead += 1
    }

    internal func recordSkipNotInRepo() {
        lock.lock()
        defer { lock.unlock() }
        _skipsNotInRepo += 1
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
        _hits = 0
        _misses = 0
        _skipsStale = 0
        _skipsNoHead = 0
        _skipsNotInRepo = 0
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    #if DEBUG
    /// Diagnostic snapshot (C11-106 E3). DEBUG-only so production has
    /// no observability surface to mis-rely on — pair this with `dlog`
    /// when investigating cache behavior.
    public struct DiagnosticSnapshot: Equatable {
        public let hits: Int
        public let misses: Int
        public let skipsStale: Int
        public let skipsNoHead: Int
        public let skipsNotInRepo: Int
        public let entryCount: Int
    }

    public func diagnosticSnapshot() -> DiagnosticSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DiagnosticSnapshot(
            hits: _hits,
            misses: _misses,
            skipsStale: _skipsStale,
            skipsNoHead: _skipsNoHead,
            skipsNotInRepo: _skipsNotInRepo,
            entryCount: entries.count
        )
    }
    #endif
}
