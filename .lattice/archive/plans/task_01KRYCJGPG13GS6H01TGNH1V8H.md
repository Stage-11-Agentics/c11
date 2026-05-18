# C11-98: Restore c11 CI + test pipeline signal (post-v0.48.0 audit)

Restore the c11 CI + test signal after v0.48.0 shipped via admin-merge (build job red on every main commit for 50+ runs because c11-unit test step misdiagnosed as "hang"). Full audit: `notes/build-test-pipeline-audit-2026-05-18.md`.

**Summary of findings**

1. **Not a hang.** c11Tests runs ~10 min and reliably brushes the 15-min `timeout-minutes` ceiling. One outlier test (`AppDelegateShortcutRoutingTests.testMinimalModeUsesZeroTopSafeAreaForMainWindowContentView`, 104s) consumes 22% of suite time. The suite ends with 32 real `XCTestExpectation` 1-second timeouts losing races on shared-tenant runners.
2. **Operator's c11 dies under local `xcodebuild test`** because the test host's untagged `c11 DEV.app` binds `/tmp/c11-debug.sock` — same path any debug build the operator is running uses. Fix surface is one resolver function (`SocketControlSettings.socketPath()`, ~6 lines).
3. **Release path is healthy.** v0.48.0 round-tripped clean. Universal DMG verified via `lipo`. Sign/notarize/Sparkle/Homebrew all green.
4. **Adjacent bit-rot.** `nightly.yml` red 15 consecutive runs since 2026-05-04 (missing `continue-on-error` on Sentry step). `claude.yml` references missing secret + floating tags. `test-e2e.yml` hardcodes stale `cmuxUITests` scheme.

**Four components** (each a child task linked via `subtask_of`):

1. **CI unblock** — `nightly.yml` Sentry flag, `ci.yml` timeout 15→25, slow-test `XCTSkip`, scheme split into hard-gate + advisory. (≤1 PR, hours.)
2. **Local test runnability** — `SocketControlSettings` runtime guard, scheme env var, `scripts/test-unit-local.sh`, CLAUDE.md rule drop. (~1 PR, ~1 day.) Enables iterating on #3 locally.
3. **c11Tests stabilization** — triage 32 expectation-timeout failures + profile the 104s slow test; exit criterion is flipping #1's advisory flag back to hard-fail. (Multi-day, owner-driven.)
4. **Workflow hygiene** — `update-homebrew.yml` timeout, `sparkle_generate_appcast.sh` defaults, `bump-version.sh` floor-curl hard-fail, `claude.yml` + `test-e2e.yml` keep-or-delete decisions, CLAUDE.md ghostty remote naming alignment. (~1 small PR + 2 decisions.)

**Dependencies**
- 1 → 3 (advisory becomes hard-fail once 3 is done)
- 2 → 3 (ergonomic: lets 3's owner iterate locally)
- 4 is independent

**Explicit non-goals**
- Adding explicit `ARCHS="arm64 x86_64"` to `release.yml`. Shipped DMG is already universal (`ONLY_ACTIVE_ARCH = NO` in pbxproj). Belt-and-braces, not a fix.
- Rewriting the "self-referential" Homebrew SHA gate. It validates heredoc substitution correctness, which is what's needed; download integrity is already gated by the 5-retry HTTP loop.
