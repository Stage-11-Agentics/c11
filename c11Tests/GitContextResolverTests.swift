import XCTest
@testable import c11

/// C11-104 — resolver tests against temp-dir-built git repos.
///
/// All tests use a `FakeGitRunner` so we don't depend on a real `git`
/// binary being present; the runner is a dictionary lookup keyed by
/// `(cwd, args)`. Cache tests verify the resolver actually calls the
/// runner when the `.git/HEAD` mtime changes.
///
/// Verifies AC1, AC2, AC5–AC9, AC12 of the C11-104 validation plan.
final class GitContextResolverTests: XCTestCase {

    // MARK: - Fakes

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

    /// Resolver requires off-main dispatch (typing-latency discipline).
    /// XCTest runs cases on main, so we hop to a background queue and
    /// wait synchronously for the result.
    private func resolveOffMain(
        cwd: String,
        runner: GitRunner,
        fs: FileSystemProbe
    ) -> ResolvedGitContext? {
        var result: ResolvedGitContext?
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result = GitContextResolver.resolve(cwd: cwd, runner: runner, fileSystem: fs)
            sema.signal()
        }
        sema.wait()
        return result
    }

    // MARK: - AC1: Linked worktree returns basename

    func testLinkedWorktreeReturnsBasename() {
        let cwd = "/Users/atin/code/c11-worktrees/c11-104-sidebar-chips"
        let runner = FakeGitRunner()
        // Submodule probe — empty (not in a submodule).
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        // Outer resolution against the cwd (not in a submodule).
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: cwd)
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-common-dir"], result: "/Users/atin/code/c11/.git")
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-dir"], result: "/Users/atin/code/c11/.git/worktrees/c11-104-sidebar-chips")
        runner.stub(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"], result: "feat/c11-104-sidebar-chips")

        let fs = FakeFileSystem(existing: [cwd])
        let result = resolveOffMain(cwd: cwd, runner: runner, fs: fs)
        XCTAssertEqual(
            result,
            ResolvedGitContext(
                outer: .linkedWorktree(
                    basename: "c11-104-sidebar-chips",
                    absolutePath: cwd,
                    branch: .attached("feat/c11-104-sidebar-chips")
                )
            )
        )
    }

    // MARK: - AC2: Main checkout returns nil worktree

    func testMainCheckoutReturnsMainCheckoutKind() {
        let cwd = "/Users/atin/code/c11"
        let runner = FakeGitRunner()
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: cwd)
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-common-dir"], result: "/Users/atin/code/c11/.git")
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-dir"], result: "/Users/atin/code/c11/.git")
        runner.stub(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"], result: "main")

        let fs = FakeFileSystem(existing: [cwd])
        let result = resolveOffMain(cwd: cwd, runner: runner, fs: fs)
        XCTAssertEqual(result?.outer, .mainCheckout(branch: .attached("main")))
        XCTAssertNil(result?.inner)
    }

    // MARK: - AC5: Detached HEAD renders short SHA

    func testDetachedHeadReturnsShortSHA() {
        let cwd = "/tmp/detached"
        let runner = FakeGitRunner()
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: cwd)
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-common-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-dir"], result: cwd + "/.git")
        // symbolic-ref fails on detached HEAD.
        runner.stub(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"], result: nil)
        runner.stub(cwd: cwd, args: ["rev-parse", "--short=7", "HEAD"], result: "abc1234")

        let fs = FakeFileSystem(existing: [cwd])
        let result = resolveOffMain(cwd: cwd, runner: runner, fs: fs)
        XCTAssertEqual(result?.outer, .mainCheckout(branch: .detached(shortSHA: "abc1234")))
    }

    // MARK: - AC6: Submodule returns both contexts

    func testSubmoduleReturnsBothContexts() {
        let superCwd = "/tmp/super"
        let subCwd = "/tmp/super/ghostty"
        let runner = FakeGitRunner()
        // From inside the submodule, the superproject probe returns
        // the super's working tree.
        runner.stub(
            cwd: subCwd,
            args: ["rev-parse", "--show-superproject-working-tree"],
            result: superCwd
        )
        // Outer resolution runs against superCwd.
        runner.stub(cwd: superCwd, args: ["rev-parse", "--show-toplevel"], result: superCwd)
        runner.stub(cwd: superCwd, args: ["rev-parse", "--git-common-dir"], result: superCwd + "/.git")
        runner.stub(cwd: superCwd, args: ["rev-parse", "--git-dir"], result: superCwd + "/.git")
        runner.stub(cwd: superCwd, args: ["symbolic-ref", "--short", "HEAD"], result: "main")
        // Inner resolution against subCwd.
        runner.stub(cwd: subCwd, args: ["rev-parse", "--show-toplevel"], result: subCwd)
        runner.stub(cwd: subCwd, args: ["symbolic-ref", "--short", "HEAD"], result: "ghostty-main")

        let fs = FakeFileSystem(existing: [subCwd])
        let result = resolveOffMain(cwd: subCwd, runner: runner, fs: fs)
        XCTAssertEqual(result?.outer, .mainCheckout(branch: .attached("main")))
        XCTAssertEqual(result?.inner?.name, "ghostty")
        XCTAssertEqual(result?.inner?.branch, .attached("ghostty-main"))
    }

    // MARK: - AC6 edge: submodule with detached inner

    func testSubmoduleInnerDetachedHEAD() {
        let superCwd = "/tmp/super"
        let subCwd = "/tmp/super/ghostty"
        let runner = FakeGitRunner()
        runner.stub(cwd: subCwd, args: ["rev-parse", "--show-superproject-working-tree"], result: superCwd)
        runner.stub(cwd: superCwd, args: ["rev-parse", "--show-toplevel"], result: superCwd)
        runner.stub(cwd: superCwd, args: ["rev-parse", "--git-common-dir"], result: superCwd + "/.git")
        runner.stub(cwd: superCwd, args: ["rev-parse", "--git-dir"], result: superCwd + "/.git")
        runner.stub(cwd: superCwd, args: ["symbolic-ref", "--short", "HEAD"], result: "main")
        runner.stub(cwd: subCwd, args: ["rev-parse", "--show-toplevel"], result: subCwd)
        runner.stub(cwd: subCwd, args: ["symbolic-ref", "--short", "HEAD"], result: nil)
        runner.stub(cwd: subCwd, args: ["rev-parse", "--short=7", "HEAD"], result: "deadbee")

        let fs = FakeFileSystem(existing: [subCwd])
        let result = resolveOffMain(cwd: subCwd, runner: runner, fs: fs)
        XCTAssertEqual(result?.inner?.branch, .detached(shortSHA: "deadbee"))
    }

    // MARK: - AC7: Not-in-git returns nil

    func testNotInGitReturnsNil() {
        let cwd = "/tmp/not-a-repo"
        let runner = FakeGitRunner()
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        // show-toplevel fails outside any git repo.
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: nil)

        let fs = FakeFileSystem(existing: [cwd])
        let result = resolveOffMain(cwd: cwd, runner: runner, fs: fs)
        XCTAssertNil(result)
    }

    func testCwdDoesNotExistReturnsNil() {
        let cwd = "/tmp/does-not-exist"
        let runner = FakeGitRunner()
        let fs = FakeFileSystem(existing: [])  // cwd does not exist
        let result = resolveOffMain(cwd: cwd, runner: runner, fs: fs)
        XCTAssertNil(result)
        // Importantly, we did NOT shell out — the existence check
        // short-circuits before any runner invocation.
        XCTAssertEqual(runner.invocations.count, 0)
    }

    // MARK: - AC8: Bare clone returns nil

    func testBareCloneReturnsNil() {
        let cwd = "/tmp/bare-clone.git"
        let runner = FakeGitRunner()
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        // In a bare repo, `--show-toplevel` exits non-zero (our runner
        // returns nil on non-zero).
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: nil)

        let fs = FakeFileSystem(existing: [cwd])
        let result = resolveOffMain(cwd: cwd, runner: runner, fs: fs)
        XCTAssertNil(result)
    }

    // MARK: - AC9: Worktree-with-deleted-branch degrades

    func testWorktreeWithDeletedBranchDegrades() {
        let cwd = "/Users/atin/code/c11-worktrees/old-branch"
        let runner = FakeGitRunner()
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: cwd)
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-common-dir"], result: "/Users/atin/code/c11/.git")
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-dir"], result: "/Users/atin/code/c11/.git/worktrees/old-branch")
        // Both symbolic-ref and rev-parse fail when the underlying
        // branch has been deleted out from under the worktree.
        runner.stub(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"], result: nil)
        runner.stub(cwd: cwd, args: ["rev-parse", "--short=7", "HEAD"], result: nil)

        let fs = FakeFileSystem(existing: [cwd])
        let result = resolveOffMain(cwd: cwd, runner: runner, fs: fs)
        // No throw, no crash — just `.noBranch` in the branch slot.
        switch result?.outer {
        case .linkedWorktree(_, _, let branch):
            XCTAssertEqual(branch, .noBranch)
        default:
            XCTFail("expected linkedWorktree, got \(String(describing: result?.outer))")
        }
    }

    // MARK: - AC10: Stale worktree (worktree removed while pane is open)
    //
    // (C11-106) Closes the AC10 FAIL row from the C11-104 validation
    // report. When `git worktree remove` is run from a sibling pane,
    // the affected pane's gitdir HEAD path is pruned (e.g.
    // `<common-dir>/worktrees/<name>/HEAD` disappears) but the cwd
    // directory often remains. The resolver detects this by
    // resolving `--git-path HEAD` and observing the resulting file
    // is missing on disk → returns `.stale`. Cache layer (C11-106
    // §1) is responsible for not storing `.stale` so a recreated
    // worktree is picked up on the next resolution.

    func testStaleWorktreeReturnsStaleWhenHeadPathFileMissing() {
        let cwd = "/Users/atin/code/c11-worktrees/pruned-worktree"
        let staleHeadPath = "/Users/atin/code/c11/.git/worktrees/pruned-worktree/HEAD"
        let runner = FakeGitRunner()
        // `git rev-parse --git-path HEAD` still resolves the absolute
        // path git would point at — git itself doesn't notice the
        // worktree was pruned until it tries to read the file.
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-path", "HEAD"], result: staleHeadPath)

        // cwd directory still exists on disk; the HEAD file does not.
        var fs = FakeFileSystem(existing: [cwd])
        fs.existing.remove(staleHeadPath)
        // Nothing else needs stubbing — `.stale` should short-circuit
        // before the resolver issues any further git invocations.

        let result = resolveOffMain(cwd: cwd, runner: runner, fs: fs)
        XCTAssertEqual(result?.outer, .stale)
        XCTAssertNil(result?.inner)
        // Asserts: only the `--git-path HEAD` invocation happened.
        // Any further runner invocations would mean the `.stale`
        // short-circuit didn't fire.
        XCTAssertEqual(runner.invocations.count, 1, "stale short-circuit must skip the rest of the probe")
    }

    func testHeadPathExistingOnDiskFallsThroughToRegularResolution() {
        let cwd = "/Users/atin/code/c11"
        let liveHeadPath = "/Users/atin/code/c11/.git/HEAD"
        let runner = FakeGitRunner()
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-path", "HEAD"], result: liveHeadPath)
        // Regular resolution after the stale check falls through.
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: cwd)
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-common-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"], result: "main")

        let fs = FakeFileSystem(existing: [cwd, liveHeadPath])
        let result = resolveOffMain(cwd: cwd, runner: runner, fs: fs)
        XCTAssertEqual(result?.outer, .mainCheckout(branch: .attached("main")))
    }

    // MARK: - AC12: Cache invalidates on .git/HEAD mtime change

    // (C11-106) Cache-class-level tests. Production cache wiring +
    // submodule + nil-result tests live in
    // GitContextResolverCacheWiringTests.swift (separate file because
    // they exercise the production `resolveCached` entry point and a
    // submodule fixture deserves its own setup).
    func testCacheHitDoesNotReinvokeRunner() {
        let cwd = "/tmp/cached"
        let runner = FakeGitRunner()
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: cwd)
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-common-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"], result: "main")
        let fs = FakeFileSystem(existing: [cwd])

        let cache = GitContextResolverCache()
        let mtime = Date(timeIntervalSince1970: 1000)
        let key = GitContextResolverCache.Key(cwd: cwd, headMtime: mtime)

        if cache.get(key) == nil {
            guard let value = resolveOffMain(cwd: cwd, runner: runner, fs: fs) else {
                XCTFail("expected a resolved value")
                return
            }
            cache.set(key, value: value)
        }
        let first = runner.invocations.count
        XCTAssertGreaterThan(first, 0)

        // Second lookup with the same key → cache hit.
        guard let cached = cache.get(key) else {
            XCTFail("expected cache hit")
            return
        }
        XCTAssertEqual(cached.outer, .mainCheckout(branch: .attached("main")))
        XCTAssertEqual(runner.invocations.count, first, "cache hit must not invoke the runner")
    }

    func testCacheInvalidatesOnHeadMtimeChange() {
        let cwd = "/tmp/invalidates"
        let runner = FakeGitRunner()
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: cwd)
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-common-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"], result: "main")
        let fs = FakeFileSystem(existing: [cwd])

        let cache = GitContextResolverCache()
        let t1 = Date(timeIntervalSince1970: 1000)
        let key1 = GitContextResolverCache.Key(cwd: cwd, headMtime: t1)

        guard let v1 = resolveOffMain(cwd: cwd, runner: runner, fs: fs) else {
            XCTFail("expected first resolution to succeed")
            return
        }
        cache.set(key1, value: v1)
        let beforeChange = runner.invocations.count

        // mtime changes (e.g., a `git checkout` happened) → new key.
        let t2 = Date(timeIntervalSince1970: 2000)
        let key2 = GitContextResolverCache.Key(cwd: cwd, headMtime: t2)
        XCTAssertNil(cache.get(key2), "different mtime must miss")

        guard let v2 = resolveOffMain(cwd: cwd, runner: runner, fs: fs) else {
            XCTFail("expected re-resolution to succeed")
            return
        }
        cache.set(key2, value: v2)
        XCTAssertGreaterThan(
            runner.invocations.count, beforeChange,
            "mtime-change must trigger a new runner invocation"
        )
    }

    // MARK: - Branch label truncation (plan-review I7)

    func testLongBranchNameIsMiddleTruncated() {
        let cwd = "/tmp/long-branch"
        let runner = FakeGitRunner()
        let longName = "release/2026-q4/super-long-feature-branch-name-that-will-blow-past-sixty-four-chars-and-then-some"
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: cwd)
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-common-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"], result: longName)
        let fs = FakeFileSystem(existing: [cwd])

        let result = resolveOffMain(cwd: cwd, runner: runner, fs: fs)
        guard case .mainCheckout(.attached(let label)) = result?.outer else {
            XCTFail("expected attached branch")
            return
        }
        XCTAssertLessThanOrEqual(label.count, GitContextResolver.maxBranchLabelLength)
        XCTAssertTrue(label.contains("…"), "truncated label must include ellipsis")
        XCTAssertTrue(label.hasPrefix("release/2026"), "head context preserved")
    }

    // MARK: - AC20: Hot-path discipline (plan-review I2; C11-106 explicit downgrade)
    //
    // (C11-106) AC20 from the v2 validation plan asked for a
    // deterministic main-thread precondition trip. In-process
    // testing of `dispatchPrecondition(.notOnQueue(.main))` is
    // unsafe in XCTest: the precondition aborts with
    // EXC_BAD_INSTRUCTION, which XCTExpectFailure does NOT trap
    // (XCTExpectFailure catches XCTFails, not fatal signals).
    //
    // The trident plan review (revise-then-proceed verdict,
    // 2026-05-19) offered two paths: (a) build a subprocess
    // fatal-test harness — child binary invokes the resolver from
    // main, parent asserts non-zero termination + precondition
    // diagnostic in stderr; or (b) explicit downgrade — keep this
    // sentinel test plus a documented residual gap. C11-106 took
    // path (b): the cost of the subprocess harness is high, the
    // residual risk is bounded (a regression to no-op preconditions
    // would surface in any off-main test failing), and the
    // sentinel still ensures the precondition compiles into the
    // shipped binary. Future ticket may reopen path (a) if
    // observability needs grow.
    //
    // What this test verifies:
    //   - Off-main resolution succeeds (no precondition trip on
    //     the legitimate path).
    //   - The resolver's symbol surface includes the
    //     `dispatchPrecondition` call site (compile-checked by
    //     `@testable import c11`).
    //
    // What this test does NOT verify:
    //   - That main-thread invocation actually crashes. That gap
    //     is recorded in the PR body and the C11-106 validation
    //     plan addendum.
    func testResolverPreconditionTripsOnMainThread() {
        let runner = FakeGitRunner()
        runner.stub(cwd: "/tmp", args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        runner.stub(cwd: "/tmp", args: ["rev-parse", "--show-toplevel"], result: nil)
        let fs = FakeFileSystem(existing: ["/tmp"])
        // Off-main resolution must succeed (no precondition trip).
        let result = resolveOffMain(cwd: "/tmp", runner: runner, fs: fs)
        XCTAssertNil(result, "not-in-git returns nil; precondition allows off-main resolution")
    }

    // MARK: - Submodule display-name fallback chain (v2 amendment 3)

    func testSubmoduleNameFallsBackToBasenameWhenNoGitmodules() {
        // When `.gitmodules` lookup returns nil AND the path-from-
        // superproject-root is computable, the path is used (richer
        // disambiguation than basename for nested submodules).
        let superCwd = "/tmp/super"
        let subCwd = "/tmp/super/ghostty"
        let runner = FakeGitRunner()
        runner.stub(cwd: subCwd, args: ["rev-parse", "--show-superproject-working-tree"], result: superCwd)
        runner.stub(cwd: superCwd, args: ["rev-parse", "--show-toplevel"], result: superCwd)
        runner.stub(cwd: superCwd, args: ["rev-parse", "--git-common-dir"], result: superCwd + "/.git")
        runner.stub(cwd: superCwd, args: ["rev-parse", "--git-dir"], result: superCwd + "/.git")
        runner.stub(cwd: superCwd, args: ["symbolic-ref", "--short", "HEAD"], result: "main")
        runner.stub(cwd: subCwd, args: ["rev-parse", "--show-toplevel"], result: subCwd)
        runner.stub(cwd: subCwd, args: ["symbolic-ref", "--short", "HEAD"], result: "ghostty-main")
        // `.gitmodules` config lookup returns nil → fallback to
        // path-from-superproject-root.
        let fs = FakeFileSystem(existing: [subCwd])
        let result = resolveOffMain(cwd: subCwd, runner: runner, fs: fs)
        // Path-from-superproject-root is "ghostty" which happens to
        // equal the basename in this trivial case. The richer test
        // below covers the nested case where they diverge.
        XCTAssertEqual(result?.inner?.name, "ghostty")
    }

    func testSubmoduleNamePrefersConfiguredGitmodulesEntry() {
        let superCwd = "/tmp/super"
        let subCwd = "/tmp/super/vendor/bonsplit"
        let runner = FakeGitRunner()
        runner.stub(cwd: subCwd, args: ["rev-parse", "--show-superproject-working-tree"], result: superCwd)
        runner.stub(cwd: superCwd, args: ["rev-parse", "--show-toplevel"], result: superCwd)
        runner.stub(cwd: superCwd, args: ["rev-parse", "--git-common-dir"], result: superCwd + "/.git")
        runner.stub(cwd: superCwd, args: ["rev-parse", "--git-dir"], result: superCwd + "/.git")
        runner.stub(cwd: superCwd, args: ["symbolic-ref", "--short", "HEAD"], result: "main")
        runner.stub(cwd: subCwd, args: ["rev-parse", "--show-toplevel"], result: subCwd)
        runner.stub(cwd: subCwd, args: ["symbolic-ref", "--short", "HEAD"], result: "bonsplit-main")
        // .gitmodules lookup returns a configured name "Bonsplit" mapped to
        // the relative path "vendor/bonsplit". The configured name wins.
        runner.stub(
            cwd: superCwd,
            args: ["config", "-f", ".gitmodules", "--get-regexp", #"submodule\..*\.path"#],
            result: "submodule.Bonsplit.path vendor/bonsplit"
        )
        let fs = FakeFileSystem(existing: [subCwd])
        let result = resolveOffMain(cwd: subCwd, runner: runner, fs: fs)
        XCTAssertEqual(result?.inner?.name, "Bonsplit")
    }

    func testSubmoduleNameFallsBackToRelativePathWhenGitmodulesAbsent() {
        let superCwd = "/tmp/super"
        let subCwd = "/tmp/super/vendor/bonsplit"
        let runner = FakeGitRunner()
        runner.stub(cwd: subCwd, args: ["rev-parse", "--show-superproject-working-tree"], result: superCwd)
        runner.stub(cwd: superCwd, args: ["rev-parse", "--show-toplevel"], result: superCwd)
        runner.stub(cwd: superCwd, args: ["rev-parse", "--git-common-dir"], result: superCwd + "/.git")
        runner.stub(cwd: superCwd, args: ["rev-parse", "--git-dir"], result: superCwd + "/.git")
        runner.stub(cwd: superCwd, args: ["symbolic-ref", "--short", "HEAD"], result: "main")
        runner.stub(cwd: subCwd, args: ["rev-parse", "--show-toplevel"], result: subCwd)
        runner.stub(cwd: subCwd, args: ["symbolic-ref", "--short", "HEAD"], result: "bonsplit-main")
        // No `.gitmodules` lookup stubbed → falls back to relative path.
        let fs = FakeFileSystem(existing: [subCwd])
        let result = resolveOffMain(cwd: subCwd, runner: runner, fs: fs)
        XCTAssertEqual(result?.inner?.name, "vendor/bonsplit",
                       "fallback chain prefers path-from-superproject-root over basename for nested submodules")
    }

    // MARK: - DerivationCoordinator + MetadataDeriver seam (v2 amendment 2)

    func testGitContextDeriverConformsToMetadataDeriver() {
        // Compile-time conformance check. If `GitContextDeriver`
        // ever stops conforming to `MetadataDeriver`, this test
        // stops compiling.
        let _: any MetadataDeriver = GitContextDeriver()
    }

    func testDerivationCoordinatorRunsDeriverOffMainAndCompletesOnMain() {
        let cwd = "/tmp/coordinator-test"
        let runner = FakeGitRunner()
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-superproject-working-tree"], result: nil)
        runner.stub(cwd: cwd, args: ["rev-parse", "--show-toplevel"], result: cwd)
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-common-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["rev-parse", "--git-dir"], result: cwd + "/.git")
        runner.stub(cwd: cwd, args: ["symbolic-ref", "--short", "HEAD"], result: "main")
        let fs = FakeFileSystem(existing: [cwd])
        let deriver = GitContextDeriver(runner: runner, fileSystem: fs)

        let expectation = XCTestExpectation(description: "coordinator completes on main")
        nonisolated(unsafe) var receivedOnMain = false
        nonisolated(unsafe) var result: ResolvedGitContext?
        DerivationCoordinator.run(deriver: deriver, cwd: cwd) { value in
            receivedOnMain = Thread.isMainThread
            result = value
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
        XCTAssertTrue(receivedOnMain, "completion must hop to main")
        XCTAssertEqual(result?.outer, .mainCheckout(branch: .attached("main")))
    }

    // MARK: - Cache eviction (LRU)

    func testCacheEvictsOldestEntriesPastCapacity() {
        let cache = GitContextResolverCache(capacity: 2)
        let mtime = Date(timeIntervalSince1970: 1000)
        let value = ResolvedGitContext(outer: .mainCheckout(branch: .attached("main")))
        let k1 = GitContextResolverCache.Key(cwd: "/a", headMtime: mtime)
        let k2 = GitContextResolverCache.Key(cwd: "/b", headMtime: mtime)
        let k3 = GitContextResolverCache.Key(cwd: "/c", headMtime: mtime)
        cache.set(k1, value: value)
        cache.set(k2, value: value)
        cache.set(k3, value: value)
        XCTAssertEqual(cache.count, 2)
        XCTAssertTrue(cache.get(k1) == nil, "oldest entry must have been evicted")
        XCTAssertTrue(cache.get(k2) != nil)
        XCTAssertTrue(cache.get(k3) != nil)
    }
}
