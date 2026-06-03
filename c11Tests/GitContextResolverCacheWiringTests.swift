import XCTest
@testable import c11

/// C11-106 — tests for the production cache wiring (`GitContextResolver.resolveCached`).
///
/// The legacy class-level cache tests in `GitContextResolverTests`
/// covered the `GitContextResolverCache` LRU + mtime-keyed
/// invalidation in isolation; those still apply. This file exercises
/// the higher-level entry point `GitContextResolver.resolveCached(...)`
/// that `TabManager.initialWorkspaceGitMetadataSnapshot(for:)` calls
/// in production. It also covers the linked-worktree + submodule
/// fixtures + nil-result re-resolution policy that the C11-104
/// validation report's AC12 / B2 / B3 called for but were missing
/// from the v2 ship.
///
/// All seams (`GitRunner`, `FileSystemProbe`) are pluggable — no
/// real git is invoked. Tests use stub HEAD paths and fake mtimes
/// for deterministic invalidation behavior.
final class GitContextResolverCacheWiringTests: XCTestCase {

    // MARK: - Fakes (mirrors GitContextResolverTests' shape)

    private final class FakeGitRunner: GitRunner {
        struct Key: Hashable {
            let cwd: String
            let args: [String]
        }
        var responses: [Key: String?] = [:]
        private(set) var invocations: [Key] = []

        func run(cwd: String, args: [String]) -> String? {
            let key = Key(cwd: cwd, args: args)
            invocations.append(key)
            return responses[key] ?? nil
        }

        func stub(cwd: String, args: [String], result: String?) {
            responses[Key(cwd: cwd, args: args)] = result
        }
    }

    private struct FakeFileSystem: FileSystemProbe {
        var existing: Set<String> = []
        var mtimes: [String: Date] = [:]
        func fileExists(atPath path: String) -> Bool {
            return existing.contains(path)
        }
        func mtime(atPath path: String) -> Date? {
            return mtimes[path]
        }
    }

    /// XCTest runs on main; resolver must run off-main.
    private func resolveCachedOffMain(
        cwd: String,
        cache: GitContextResolverCache,
        runner: GitRunner,
        fs: FileSystemProbe
    ) -> ResolvedGitContext? {
        var result: ResolvedGitContext?
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result = GitContextResolver.resolveCached(
                cwd: cwd, cache: cache, runner: runner, fileSystem: fs
            )
            sema.signal()
        }
        sema.wait()
        return result
    }

    // MARK: - AC12 linked-worktree fixture: cache invalidates on HEAD mtime change

    func testLinkedWorktreeResultIsCachedAndInvalidatedByHeadMtime() {
        let commonGitDir = "/Users/atin/code/c11/.git"
        let cwd = "/Users/atin/code/c11-worktrees/c11-106-followups"
        let worktreeHeadPath = "\(commonGitDir)/worktrees/c11-106-followups/HEAD"

        let runner = FakeGitRunner()
        // First stub: rev-parse --git-path HEAD returns the linked
        // worktree's HEAD (this is the production behavior of git
        // for a linked worktree — the path lives under the common
        // gitdir's `worktrees/<name>/` subtree, not under <cwd>/.git/).
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-path", "HEAD"], result: worktreeHeadPath)
        // No superproject (not in a submodule).
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        // Outer resolution: this is a linked worktree (--git-common-dir
        // != --git-dir).
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: cwd)
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-common-dir"], result: commonGitDir)
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-dir"], result: "\(commonGitDir)/worktrees/c11-106-followups")
        runner.stub(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"], result: "feat/c11-106-followups")

        var fs = FakeFileSystem(existing: [cwd, worktreeHeadPath])
        fs.mtimes[worktreeHeadPath] = Date(timeIntervalSince1970: 1000)

        let cache = GitContextResolverCache()

        // First call → miss → resolve → cache.
        let first = resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs)
        guard case .linkedWorktree(let basename, _, let branch) = first?.outer else {
            XCTFail("expected linkedWorktree, got \(String(describing: first?.outer))")
            return
        }
        XCTAssertEqual(basename, "c11-106-followups")
        XCTAssertEqual(branch, .attached("feat/c11-106-followups"))
        let invocationsAfterFirst = runner.invocations.count

        // Second call with the SAME mtime → must hit the cache (no
        // new runner invocations beyond the cheap headPath +
        // superproject probes).
        let second = resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs)
        XCTAssertEqual(first, second, "second call must return the cached value")
        // Allow up to 2 extra invocations (headPath + superproject
        // probe always run before the cache lookup). Anything more
        // means the cache was bypassed.
        XCTAssertLessThanOrEqual(
            runner.invocations.count - invocationsAfterFirst, 2,
            "cache hit must not re-shell to git for the body of the resolve"
        )

        // HEAD mtime advances (e.g., `git checkout` happened).
        fs.mtimes[worktreeHeadPath] = Date(timeIntervalSince1970: 2000)
        let before = runner.invocations.count
        _ = resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs)
        XCTAssertGreaterThan(
            runner.invocations.count, before + 2,
            "mtime change must re-shell for the full resolve body, not just the cache-key probes"
        )
    }

    // MARK: - AC12 / B2 submodule fixture: cache invalidates on EITHER inner OR outer HEAD change

    func testSubmoduleCacheInvalidatesOnInnerHEADChange() {
        let (cwd, superCwd, innerHead, outerHead) = makeSubmoduleStubs()
        let runner = makeSubmoduleRunner(cwd: cwd, superCwd: superCwd, innerHead: innerHead, outerHead: outerHead)
        var fs = makeSubmoduleFs(cwd: cwd, innerHead: innerHead, outerHead: outerHead, innerMtime: 1000, outerMtime: 1000)

        let cache = GitContextResolverCache()
        let first = resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs)
        XCTAssertNotNil(first?.inner, "expected a submodule inner context")
        let invocationsAfterFirst = runner.invocations.count

        // Same mtimes → cache hit on second call.
        _ = resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs)
        XCTAssertLessThanOrEqual(
            runner.invocations.count - invocationsAfterFirst, 3,
            "cache hit must not re-shell to git for the body of the resolve (allow headPath + superproject + superHeadPath probes)"
        )

        // Inner (submodule) HEAD mtime advances → new key → miss → resolve.
        fs.mtimes[innerHead] = Date(timeIntervalSince1970: 2000)
        let before = runner.invocations.count
        _ = resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs)
        XCTAssertGreaterThan(
            runner.invocations.count, before + 3,
            "inner HEAD mtime change must re-shell for the full resolve"
        )
    }

    func testSubmoduleCacheInvalidatesOnOuterHEADChangeEvenIfInnerStable() {
        // This is the C11-106 v2 SPEC § B2 correctness test: if the
        // superproject HEAD changes (e.g., the parent project
        // checked out a different branch) but the submodule's own
        // HEAD is stable, a one-HEAD cache key would serve a stale
        // outer-branch value. The multi-HEAD key fixes this.
        let (cwd, superCwd, innerHead, outerHead) = makeSubmoduleStubs()
        let runner = makeSubmoduleRunner(cwd: cwd, superCwd: superCwd, innerHead: innerHead, outerHead: outerHead)
        var fs = makeSubmoduleFs(cwd: cwd, innerHead: innerHead, outerHead: outerHead, innerMtime: 1000, outerMtime: 1000)

        let cache = GitContextResolverCache()
        _ = resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs)
        let invocationsAfterFirst = runner.invocations.count

        // Inner HEAD unchanged. Outer (superproject) HEAD mtime
        // advances. Multi-HEAD cache key invalidates.
        fs.mtimes[outerHead] = Date(timeIntervalSince1970: 2000)
        _ = resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs)
        XCTAssertGreaterThan(
            runner.invocations.count, invocationsAfterFirst + 3,
            "outer HEAD mtime change must invalidate the submodule cache (B2 multi-HEAD key)"
        )
    }

    // MARK: - B3 nil-result policy: never cached, always re-resolved

    func testNilResultIsNotCachedAndReResolves() {
        let cwd = "/tmp/not-a-repo"
        let runner = FakeGitRunner()
        // headPath returns nil → cache layer skips entirely and
        // delegates to resolve.
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-path", "HEAD"], result: nil)
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: nil)
        let fs = FakeFileSystem(existing: [cwd])

        let cache = GitContextResolverCache()
        XCTAssertNil(resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs))
        let invocationsAfterFirst = runner.invocations.count
        XCTAssertGreaterThan(invocationsAfterFirst, 0)

        // Second call must re-shell — nil result is not cacheable.
        XCTAssertNil(resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs))
        XCTAssertGreaterThan(
            runner.invocations.count, invocationsAfterFirst,
            "B3 policy: (cwd, nil-head) results must not be cached"
        )

        XCTAssertEqual(cache.count, 0)
    }

    func testHeadPathExistsButMtimeMissingBypassesCache() {
        // Edge case: git resolves a HEAD path but the FS probe can't
        // read its mtime (file vanished mid-probe, permission denied
        // on attributesOfItem, etc.). Treat the same as no headPath
        // — bypass cache so we don't poison it with a stale key.
        let cwd = "/tmp/exotic-fs"
        let head = "/tmp/exotic-fs/.git/HEAD"
        let runner = FakeGitRunner()
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-path", "HEAD"], result: head)
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: cwd)
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-common-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"], result: "main")
        // headPath exists in FS, but mtimes lookup returns nil.
        let fs = FakeFileSystem(existing: [cwd, head], mtimes: [:])

        let cache = GitContextResolverCache()
        _ = resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs)
        XCTAssertEqual(cache.count, 0, "nil-mtime results must bypass the cache (B3)")
    }

    // MARK: - .stale outer never cached (C11-106 Section 4)

    func testStaleOuterIsNotStoredInCache() {
        let cwd = "/tmp/pruned"
        let staleHead = "/tmp/pruned/.git/HEAD"
        let runner = FakeGitRunner()
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-path", "HEAD"], result: staleHead)
        // resolve() short-circuits to .stale because the HEAD file is
        // missing. resolveCached's pre-key probe also sees the missing
        // head file (via mtime nil) — but in this test we set up the
        // mtime explicitly to force the key-build path, then the
        // resolver-level .stale detection fires.
        // (Both bypass-paths converge to "do not cache.")
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        var fs = FakeFileSystem(existing: [cwd])
        // staleHead is NOT in existing — fileExists is false.
        // Provide a mtime nevertheless so the cache key build succeeds.
        fs.mtimes[staleHead] = Date(timeIntervalSince1970: 1000)

        let cache = GitContextResolverCache()
        let result = resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs)
        XCTAssertEqual(result?.outer, .stale)
        XCTAssertEqual(cache.count, 0, ".stale results must not be cached (B3 policy)")
    }

    // MARK: - E3 diagnostic counters

    func testDiagnosticCountersReflectHitsMissesAndSkips() {
        let cwd = "/tmp/diag"
        let head = "/tmp/diag/.git/HEAD"
        let runner = FakeGitRunner()
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-path", "HEAD"], result: head)
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: cwd)
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-common-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"], result: "main")
        var fs = FakeFileSystem(existing: [cwd, head])
        fs.mtimes[head] = Date(timeIntervalSince1970: 1000)

        let cache = GitContextResolverCache()
        _ = resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs)  // miss → cached
        _ = resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs)  // hit

        let snapshot = cache.diagnosticSnapshot()
        XCTAssertEqual(snapshot.misses, 1)
        XCTAssertEqual(snapshot.hits, 1)
        XCTAssertEqual(snapshot.entryCount, 1)
    }

    func testDiagnosticCountersIncludeSkipsForStaleAndNoHead() {
        // Hit a .stale path and a no-head path; both should
        // increment the appropriate skip counter without populating
        // the cache.
        let cache = GitContextResolverCache()

        // .stale path: HEAD file missing on disk.
        do {
            let cwd = "/tmp/stale"
            let head = "/tmp/stale/.git/HEAD"
            let runner = FakeGitRunner()
            runner.stub(cwd: cwd, args: ["rev-parse", "--git-path", "HEAD"], result: head)
            runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
            var fs = FakeFileSystem(existing: [cwd])
            fs.mtimes[head] = Date(timeIntervalSince1970: 1000)
            _ = resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs)
        }

        // No-head path: rev-parse --git-path HEAD returns nil.
        do {
            let cwd = "/tmp/nogit"
            let runner = FakeGitRunner()
            runner.stub(cwd: cwd, args: ["rev-parse", "--git-path", "HEAD"], result: nil)
            runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
            runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: nil)
            let fs = FakeFileSystem(existing: [cwd])
            _ = resolveCachedOffMain(cwd: cwd, cache: cache, runner: runner, fs: fs)
        }

        let snapshot = cache.diagnosticSnapshot()
        XCTAssertGreaterThanOrEqual(snapshot.skipsStale, 1)
        XCTAssertGreaterThanOrEqual(snapshot.skipsNoHead, 1)
        XCTAssertEqual(snapshot.entryCount, 0)
    }

    // MARK: - Helpers (submodule fixture setup)

    private func makeSubmoduleStubs() -> (cwd: String, superCwd: String, innerHead: String, outerHead: String) {
        let superCwd = "/tmp/superproject"
        let cwd = "/tmp/superproject/ghostty"
        let outerHead = "/tmp/superproject/.git/HEAD"
        let innerHead = "/tmp/superproject/.git/modules/ghostty/HEAD"
        return (cwd, superCwd, innerHead, outerHead)
    }

    private func makeSubmoduleRunner(
        cwd: String,
        superCwd: String,
        innerHead: String,
        outerHead: String
    ) -> FakeGitRunner {
        let runner = FakeGitRunner()
        // headPath probe (cwd's HEAD).
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-path", "HEAD"], result: innerHead)
        // Superproject probe (the cache layer uses this to compute
        // superHeadMtime; resolve() also calls it for the two-pass
        // submodule resolution).
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: superCwd)
        // headPath probe against the superproject root.
        runner.stub(cwd: superCwd, args: ["rev-parse", "--git-path", "HEAD"], result: outerHead)
        // Outer resolution against the superproject root.
        runner.stub(cwd: superCwd, args: ["rev-parse", "--show-toplevel"], result: superCwd)
        runner.stub(cwd: superCwd, args: ["rev-parse", "--git-common-dir"], result: superCwd + "/.git")
        runner.stub(cwd: superCwd, args: ["rev-parse", "--git-dir"], result: superCwd + "/.git")
        runner.stub(cwd: superCwd, args: ["symbolic-ref", "--short", "HEAD"], result: "main")
        // Inner (submodule) resolution.
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: cwd)
        runner.stub(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"], result: "submodule-main")
        return runner
    }

    private func makeSubmoduleFs(
        cwd: String,
        innerHead: String,
        outerHead: String,
        innerMtime: TimeInterval,
        outerMtime: TimeInterval
    ) -> FakeFileSystem {
        var fs = FakeFileSystem(existing: [cwd, innerHead, outerHead])
        fs.mtimes[innerHead] = Date(timeIntervalSince1970: innerMtime)
        fs.mtimes[outerHead] = Date(timeIntervalSince1970: outerMtime)
        return fs
    }
}
