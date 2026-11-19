# CMUX-9 M1 Progress Log

## Session
- Date: 2026-04-19
- Branch: `cmux-9-m1-theme-foundation`
- Worktree: `~/src/cmux-worktrees/cmux-9-m1`
- Lattice session: `codex-cmux9-m1-1`

## Progress
- Kickoff: read `/tmp/cmux-9-m1-codex-prompt.md` in full.
- Kickoff: read `docs/c11mux-theming-plan.md` in full.
- Re-read `CLAUDE.md` and `docs/c11mux-theming-plan.md` end-to-end before resuming implementation.
- Phase 5 continued:
  - `ContentView.customTitlebar` migrated behind `theme.m1b.customTitlebar.migrated` with themed background/border resolution and legacy fallback path preserved.
  - `WorkspaceContentView` now injects `ThemeManager` + `ThemeContext` into environment behind `theme.m1b.workspaceContentViewContext.migrated`.
  - `TabItemView` M1b migration remains precomputed-parameter-based; no new environment/binding state in `TabItemView`.
- Phase 6 added:
  - Snapshot fixture matrices under `cmuxTests/Snapshots/`:
    - `sidebar-m1b/` (24 fixtures)
    - `titlebar-m1b/` (4 fixtures)
    - `browserChrome-m1b/` (6 fixtures)
  - New tests:
    - `cmuxTests/SidebarSnapshotTests.swift`
    - `cmuxTests/TitlebarSnapshotTests.swift`
    - `cmuxTests/BrowserChromeSnapshotTests.swift`
- Phase 7 added:
  - DEBUG menu entries in `cmuxApp`:
    - Dump Active Theme
    - Toggle Theme Engine (runtime key)
    - Show Theme Folder (bundled `stage11.toml` reveal)
    - Show Resolution Trace submenu (all roles)
    - `Debug: Theme M1b` submenu with per-surface toggles for all seven M1b flags.
  - Added localization keys (English + Japanese) for all newly added debug menu strings.
- Project wiring updated for the new snapshot tests in `GhosttyTabs.xcodeproj/project.pbxproj`.
- Wrap-up:
  - Restored the ignored `GhosttyKit.xcframework` symlink from the existing cache for the checked-out `ghostty` SHA.
  - Fixed the missing `return` in `Sources/Panels/MarkdownPanelView.swift`.
  - Fixed the same mechanical missing-`return` compile error that surfaced next in `Sources/ContentView.swift`.
  - `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-cmux9-m1 build` now reports `BUILD SUCCEEDED`.
  - Work was split into the requested 14 Phase 1-8 commits, with each committed state build-checked.

## Prior Session Blockers

These blockers were from the earlier sandboxed codex-exec session. They did not reproduce in the wrap-up environment except for the missing framework symlink, which `./scripts/setup.sh` resolved from the existing GhosttyKit cache.

- `lattice update CMUX-21 ...` failed because short ID `CMUX-21` is not present in local `.lattice/tasks`. Retried with correct `field=value` syntax after CLI help lookup; still fails lookup. Conservative path: proceed work and update `CMUX-9` instead.
- Attempted `./scripts/setup.sh` twice; both failed under sandbox with `Operation not permitted` writing submodule config under `~/src/cmux/.git/worktrees/...`. Conservative path: continue because submodules are already present/hot per brief and no setup side-effects were required for current code edits.
- Build verification blocker: `xcodebuild ... build` cannot run in this sandbox due denied writes to `~/.cache/clang/ModuleCache` and `~/Library/Caches/org.swift.swiftpm/...` during package resolution. Retried with HOME/cache overrides to `/tmp`; Xcode still resolved to blocked user cache paths. Conservative path: proceed with static checks and keep each phase compile-oriented, but local compile execution is blocked by environment permissions.
- Phase 1 implementation files added and wired into project (`Sources/Theme/ThemedValueAST.swift`, `Sources/Theme/TomlSubsetParser.swift`, parser tests, fuzz corpus fixtures).
- Local fallback validation: `swiftc -typecheck Sources/Theme/ThemedValueAST.swift Sources/Theme/TomlSubsetParser.swift` passed.
- Commit blocker: `git add` fails with `Unable to create .../cmux/.git/worktrees/cmux-9-m1/index.lock: Operation not permitted` (worktree git metadata path is outside writable sandbox). Conservative path: continue implementing phases in-order and keep a clean, reviewable working tree diff; commit/PR commands are blocked in this environment.
- Runtime smoke check passed: compiled parser with `swiftc` and validated all fixtures under `cmuxTests/Fixtures/toml-fuzz` (`ok`).
- Phase 2 files added: `ThemedValueParser.swift`, `ThemedValueEvaluator.swift`, `ThemeContext.swift`, plus parser/evaluator tests.
- Local fallback validation: `swiftc -typecheck` across all `Sources/Theme/*.swift` succeeded.
- Runtime smoke check for parser+evaluator path succeeded (`ok`).
- Build verification blocker persists: reran required build command
  `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-cmux9-m1 build`.
  It still fails under sandbox due denied writes to:
  - `~/.cache/clang/ModuleCache/...`
  - `~/Library/Caches/org.swift.swiftpm/...`
  Conservative path: continue with file-level/static validation and keep blockers documented.
- Fallback static validation run for theme engine with local module-cache overrides and existing stubs:
  `swiftc -typecheck -module-cache-path /tmp/cmux-module-cache /tmp/theme-stubs.swift Sources/Theme/*.swift` (`ok`).
- Re-checked commitability after latest edits: `git add Sources/cmuxApp.swift` still fails with
  `.../cmux/.git/worktrees/cmux-9-m1/index.lock: Operation not permitted`.
