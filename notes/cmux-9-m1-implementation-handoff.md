# CMUX-9 M1: Implementation Handoff for Clear Codex

**Bundled**: M1a (engine + parser + default theme, no call-sites) + M1b (surface-by-surface adoption, snapshot-gated) from `docs/c11mux-theming-plan.md` v2.1 §10.
**Parent Lattice**: CMUX-9 (`task_01KPHCQNQH2BKT128552QP46RE`).
**This ticket**: CMUX-21 (`subtask_of` CMUX-9).
**Worktree**: `~/src/cmux-worktrees/cmux-9-m1` on branch `cmux-9-m1-theme-foundation`.
**Scope**: one complete-story PR covering M1a + M1b; **not** M2+.
**Author of this brief**: Opus, in dialogue with the operator (Atin), 2026-04-19.
**Implementation agent**: you (Clear Codex — headless, full-auto).

---

## 0. First thing you do when you start

1. `cd` into the worktree: `~/src/cmux-worktrees/cmux-9-m1`. All commands below assume this CWD.
2. Register a Lattice session: `lattice session start --name "codex-cmux9-m1" --model "gpt-5-codex" --framework "codex-cli" --agent-type "advance" --prompt "CMUX-9 M1 implementation" --parent "agent:claude-opus-4-7" --quiet` → capture the disambiguated session name and pass it as `--name <session>` to every subsequent `lattice` command.
3. `lattice update CMUX-21 --status in_progress --name <session> --reason "Codex kickoff"`.
4. `./scripts/setup.sh` — initializes submodules (already done for you) and warms the GhosttyKit cache. Should finish in <30s because the cache is hot from the main checkout.
5. Read these three files in full before writing any code:
   - `docs/c11mux-theming-plan.md` (v2.1; 1464 lines — this is your spec).
   - `CLAUDE.md` at repo root — project conventions, pitfalls, test policy.
   - `notes/cmux-9-m1-implementation-handoff.md` (this file — your execution recipe).
6. Keep a running progress log at `notes/cmux-9-m1-progress.md` in the worktree. Append brief entries as you complete commits, hit blockers, or discover surprises. This is your lifeline if we hand off further.

**You are expected to push through normal decision points autonomously.** When the plan or this brief resolves a question, don't re-open it. When you hit a genuine ambiguity that isn't answered here *or* in `docs/c11mux-theming-plan.md`, write the question into `notes/cmux-9-m1-progress.md` under a `## Blockers` section, pick the most conservative interpretation, proceed, and flag it in the PR description. **Do not email or ping.**

---

## 1. What you are building (one paragraph)

A unified theme engine for c11mux chrome surfaces. A Codable `C11muxTheme` struct loaded from TOML, a hand-written TOML subset parser, an AST + evaluator for value expressions (hex literals, `$variable` references, modifier chains like `$color.opacity(0.5).mix($other, 0.3)`), a `ThemeManager` singleton that exposes `resolve<T>(_ role: ThemeRole, context: ThemeContext) -> T?` with a per-section publisher architecture, and a built-in default `stage11.toml`. Then — in the same PR — every c11mux chrome surface (sidebar tint, titlebar, browser chrome panel, markdown chrome panel, workspace bonsplit appearance, pane title bar) refactored to read through the manager, behind per-surface `@AppStorage("theme.m1b.<surface>.migrated", default: false)` rollback flags. Defaults are calibrated so the engine produces **pixel-identical output** to today — visual change is zero.

---

## 2. What is NOT in scope (do not touch)

- **`vendor/bonsplit`**. `DividerStyle` struct lands in M2a, separately. Leave the submodule alone. Do not commit a submodule pointer bump.
- **`ghostty` submodule**. Never touched by any theming milestone.
- **`WorkspaceFrame` rendering**. You ship the *stub* in `Sources/Theme/WorkspaceFrame.swift` per §7.3 — the type definition + `.idle` case + `WorkspaceFrameState` enum with source attribution. You do **not** mount it as an overlay on `WorkspaceContentView` yet (that's M2c).
- **Sidebar tint overlay rendering** (the `$workspaceColor.opacity(0.08)` overlay). Reserved for M2c.
- **Divider color wiring through bonsplit `borderHex`**. M2b.
- **User themes directory / hot reload / `phosphor.toml`**. M3.
- **Settings picker / `cmux ui themes` CLI / socket methods**. M4.

When in doubt, consult `docs/c11mux-theming-plan.md` §10 milestone table. If a task belongs to M2+, you are done with it for this PR.

---

## 3. Hard constraints (read these once; enforce every commit)

These are not negotiable. If any commit violates one, that commit is wrong and should be amended or reverted.

| # | Constraint | Source |
|---|---|---|
| C1 | **Hand-written TOML subset parser, zero deps.** Do not add any TOML library to `Package.swift` / `Package.resolved`. §12 #7 locks this. Realistic scope per §6.1: 400–600 lines; budget 2–3 engineer-days of care. |
| C2 | **Typing-latency paths untouched.** `WindowTerminalHostView.hitTest()` — do not modify. `TabItemView` — no new `@EnvironmentObject`/`@ObservedObject`/`@Binding` inside the view; theme reads arrive via pre-computed `let` parameters; `.equatable()` and the `==` function at `Sources/ContentView.swift:10607-10608` must remain intact. `TerminalSurface.forceRefresh()` — do not touch. See `CLAUDE.md` → "Pitfalls". |
| C3 | **Per-bundle-ID `@AppStorage` isolation.** All theme-related `@AppStorage` keys route through `UserDefaults(suiteName: Bundle.main.bundleIdentifier)`. §12 #14. Build a small `ThemeAppStorage` wrapper if needed. |
| C4 | **Per-surface migration flag, default `false`.** Every M1b surface migration reads `@AppStorage("theme.m1b.<surfaceKey>.migrated", default: false)`. When `false`, the surface runs the pre-M1 legacy code path verbatim. When `true`, it reads through `ThemeManager.resolve`. Default false means this PR ships as a no-op visually — operator flips flags surface-by-surface via Debug menu after tagged-build eyeball. See §9.4 for the Debug menu entry. |
| C5 | **Rollback surfaces.** Implement exactly three, per §8.1: `CMUX_DISABLE_THEME_ENGINE=1` env var (launch-time; forces pre-M1 paths from process start; highest precedence); `@AppStorage("theme.engine.disabledRuntime", default: false)` (runtime toggle; flips via Debug menu); `@AppStorage("theme.workspaceFrame.enabled", default: true)` (scoped to frame only; unused in M1 since frame is a stub, but wire the key so M2c has it). |
| C6 | **Runtime contract §6.4.a — all clauses.** Parse-time cycle detection in `[variables]`; invalid-hex = load-time error (fall back to default theme, OSLog warning); out-of-range modifier args (`opacity(1.5)`, etc.) clamp to `[0, 1]` + OSLog warning once per key; unknown modifier = load-time error; negative thickness clamps to 0, thickness > 8 clamps to 8; `sRGB`-only resolution; `$workspaceColor` and `$ghosttyBackground` are reserved identifiers (writing to them in `[variables]` is a load-time error); the resolved-color memoization cache key is the **full** `ThemeContext` hash. |
| C7 | **Localization.** Every user-facing string added by this PR (including OSLog user-visible messages in the Settings picker preview — though M4 builds the picker, any string you add for Debug menu in M1b is in scope) uses `String(localized: "key.name", defaultValue: "English text")`. Keys added to `Resources/Localizable.xcstrings` with **English and Japanese** translations. No bare string literals in any SwiftUI `Text()`, `Button()`, menu item, or alert title. |
| C8 | **No `xcodebuild test` locally.** You run `xcodebuild ... build` only, and only with a tagged `-derivedDataPath /tmp/cmux-cmux9-m1`. Tests are declared and committed, they run in CI. See `CLAUDE.md` → "Testing policy" and memory `feedback_cmux_never_run_xcodebuild_test.md`. |
| C9 | **Test quality policy** (CLAUDE.md). No tests that grep source text or check for a string's presence in a file. All tests exercise observable runtime behavior through executable paths. |
| C10 | **Socket command threading** — N/A for this PR (no new socket commands; those ship in M4). If a place tempts you to add one, don't. |
| C11 | **Never run `cmux DEV.app` untagged.** Never run `./scripts/reloadp.sh` (kills all running instances). If you need to launch a tagged debug build for eyeball verification, use `./scripts/reload.sh --tag cmux9-m1`; note that tagged builds need a manual quit before the next tag. Prefer `xcodebuild ... -derivedDataPath /tmp/cmux-cmux9-m1 build` for compile-only verification. |
| C12 | **Forward-only Lattice.** Reference CMUX-21 and CMUX-9 in commit trailers. Do not invent sibling tickets for things that belong in this PR. |

---

## 4. Build order (in this sequence — do not reorder)

Each phase is one or more focused commits. Each commit compiles. Each commit either adds dead code (nothing reads it yet) or adds code flag-gated to default-off (invisible). No commit introduces user-visible change.

### Phase 1 — Parser + AST + Fuzz Corpus (M1a unit 1)

This is the single biggest risk item in M1. Land parser, AST producer, and fuzz corpus together — not as three separate commits. The parser's quality is judged by the fuzz corpus; shipping them apart invites regression.

**New files**:
- `Sources/Theme/ThemedValueAST.swift` — enum representing parsed value expressions. Nodes: `.hex(UInt32)`, `.variableRef([String])` (dot-path), `.modifier(op: ModifierOp, args: [AST])`, `.structured(StructuredValue)` where `StructuredValue` is `.disabled | .opacityValue(Double) | .hexLiteral(UInt32) | ...`. Modifier ops: `.opacity | .mix | .darken | .lighten | .saturate | .desaturate`.
- `Sources/Theme/TomlSubsetParser.swift` — hand-written subset parser. Handles:
  - Comments: `# ...` until EOL (except inside a quoted string).
  - Whitespace: BOM (consume once at start), CRLF/LF, tabs, spaces.
  - Tables: `[table]` and `[table.subtable]`. Nested tables map to nested dictionaries.
  - Key-value pairs: `key = value` inside the current table.
  - Values: strings (double-quoted, with escapes `\n \t \" \\ \uXXXX`), numbers (int and float), booleans.
  - Inline tables: `{ enabled = false }` — single-line only, comma-separated.
  - Not supported (out of subset): arrays, arrays-of-tables, multi-line strings, datetime, inline arrays. If encountered, load-time error with file:line:column.
  - Duplicate keys (same table, same key) = load-time error.
  - Error reporting: every error carries `file`, `line`, `column`, and an `expected_tokens` hint (e.g., "expected `=` or `.`, saw `]`").
- `cmuxTests/TomlSubsetParserTests.swift` — happy-path tests: every construct listed above, round-trip for `stage11.toml` (once that file exists).
- `cmuxTests/TomlSubsetParserFuzzTests.swift` — fuzz corpus reader. Iterates over every file under `cmuxTests/Fixtures/toml-fuzz/` and asserts either `parse_ok.<slug>.toml` loads without error, or `parse_err.<slug>.toml` fails with the expected error kind (file name encodes the expected outcome).
- `cmuxTests/Fixtures/toml-fuzz/` — corpus files. At minimum:
  - `parse_ok.bom_utf8.toml` — starts with `\uFEFF` BOM.
  - `parse_ok.crlf.toml` — CRLF line endings.
  - `parse_ok.comment_before_table.toml`.
  - `parse_ok.empty_table.toml`.
  - `parse_ok.deeply_nested_tables.toml` (≥5 levels).
  - `parse_ok.hex_value_looks_like_comment.toml` — contains `color = "#FF0000"` in a quoted string context.
  - `parse_err.unquoted_hex.toml` — `color = #FF0000` (unquoted; expect "expected value, saw `#`").
  - `parse_err.duplicate_key.toml` — same key twice in same table.
  - `parse_err.missing_equals.toml`.
  - `parse_err.unterminated_string.toml`.
  - `parse_err.array_value.toml` — `colors = ["#FF0000"]` (arrays not in subset).
  - `parse_err.multiline_string.toml` — triple-quoted (not in subset).
  - `parse_err.trailing_comma.toml` — `{ a = 1, }` (JSON-style).

**Commit**: `feat(theme): TOML subset parser, AST, and fuzz corpus (CMUX-9 M1a)`. Mention the 400–600 line target in the body. Reference CMUX-21.

### Phase 2 — Value Grammar & Evaluator (M1a unit 2)

**New files**:
- `Sources/Theme/ThemedValueParser.swift` — takes a TOML string leaf like `"$workspaceColor.opacity(0.5).mix($background, 0.3)"` and produces a `ThemedValueAST`. Disambiguates dot-paths from modifier chains per §6.4.a #2: an identifier segment beginning with a lowercase letter and with no parenthesized args is a dot-path component; an identifier followed by `(...)` is a modifier.
- `Sources/Theme/ThemedValueEvaluator.swift` — takes an AST + `ThemeContext` + lookup closures for palette and variables, returns `NSColor` (in `sRGB`). Evaluates modifier chains strictly left-to-right (§6.4.a #3). Clamps out-of-range modifier args to `[0, 1]` with a one-shot warning (`ThemeWarnings.emitOnce(key: ...)` helper). Returns `nil` and logs on load-time errors (callers fall back to the default theme's value for that key).
- `Sources/Theme/ThemeContext.swift`:
  ```swift
  public struct ThemeContext: Hashable, Sendable {
      public var workspaceColor: String?          // hex, as stored on Workspace.customColor
      public var colorScheme: ColorScheme         // .light | .dark
      public var forceBright: Bool                // mirrors leftRail forceBright path
      public var ghosttyBackgroundGeneration: UInt64
      public var isWindowFocused: Bool = true     // for M2c frame; unused in M1 but present
      public var workspaceState: WorkspaceState?  // RESERVED in v1 — always nil; keep the field so cache keys are stable
  }
  public struct WorkspaceState: Hashable, Sendable {
      public var environment: String?
      public var risk: String?
      public var mode: String?
      public var tags: [String: String] = [:]
  }
  ```
- `cmuxTests/ThemedValueParserTests.swift` — grammar disambiguation tests: `$palette.void`, `$workspaceColor.opacity(0.5)`, `$palette.void.opacity(0.5)` (chain of dot-path then modifier), `$a.mix($b, 0.3)` with nested variable reference.
- `cmuxTests/ThemedValueEvaluatorTests.swift` — resolution fixtures:
  - `$foreground` → expected `NSColor` in `sRGB`.
  - `$workspaceColor.opacity(0.08)` given a workspace color context → expected alpha-multiplied value.
  - `$background.mix($accent, 0.5)` → expected linear-RGB interpolation.
  - `$x.opacity(0.5).mix($y, 0.3)` vs `$x.mix($y, 0.3).opacity(0.5)` — two different expected values (lock evaluation order).
  - Clamp tests: `$x.opacity(1.5)` → clamped to 1.0 + warning emitted.

**Commit**: `feat(theme): ThemedValue grammar, AST evaluator, ThemeContext (CMUX-9 M1a)`.

### Phase 3 — Theme struct, role registry, manager (M1a unit 3)

**New files**:
- `Sources/Theme/C11muxTheme.swift` — `Codable` struct matching the schema at `docs/c11mux-theming-plan.md` §6.3. Fields: `identity` (name, displayName, author, version, schema), `palette: [String: String]`, `variables: [String: String]`, `chrome: ChromeSections`. Custom `init(from:)` if needed to convert TOML-parsed dictionary into typed struct. Enforce §6.4.a #1 (reserved magic variables cannot be overridden in `[variables]`) at decode time.
- `Sources/Theme/ThemeRoleRegistry.swift` — single source of truth. A `ThemeRole` enum with one case per chrome role (e.g., `.sidebar_activeTabFill`, `.titleBar_background`, `.dividers_color`, `.dividers_thicknessPt`, `.windowFrame_color`, `.windowFrame_thicknessPt`, `.windowFrame_inactiveOpacity`, `.windowFrame_unfocusedOpacity`, `.browserChrome_background`, `.browserChrome_omnibarFill`, `.markdownChrome_background`, `.tabBar_background`, `.tabBar_activeFill`, `.tabBar_divider`, `.tabBar_activeIndicator`, `.sidebar_tintBase`, `.sidebar_tintBaseOpacity`, `.sidebar_tintOverlay`, `.sidebar_activeTabFillFallback`, `.sidebar_activeTabRail`, `.sidebar_activeTabRailFallback`, `.sidebar_activeTabRailOpacity`, `.sidebar_inactiveTabCustomOpacity`, `.sidebar_inactiveTabMultiSelectOpacity`, `.sidebar_badgeFill`, `.sidebar_borderLeading`, `.titleBar_backgroundOpacity`, `.titleBar_foreground`, `.titleBar_foregroundSecondary`, `.titleBar_borderBottom`). Each role declares: default value (for fallback when active theme omits the key), owning surface (for diagnostics), expected type (`NSColor | CGFloat | Bool`), fallback behavior (specific value or "use default theme's value"). Drive `cmux ui themes dump --json` later (M4); for now its presence is tested in isolation.
- `Sources/Theme/ResolvedThemeSnapshot.swift` — immutable snapshot. Built at each theme-change / file-reload / context change. Cache is a `[ResolvedKey: NSColor]` where `ResolvedKey = (role: ThemeRole, context: ThemeContext)`. Snapshot exposes `resolve(role:context:)`; cache misses populate.
- `Sources/Theme/ThemeManager.swift` — `@MainActor` singleton. Exposes:
  - `var active: C11muxTheme { get }` — current theme.
  - `var snapshot: ResolvedThemeSnapshot { get }` — current snapshot.
  - `func resolve<T>(_ role: ThemeRole, context: ThemeContext) -> T?` — the generic (§3).
  - Per-section publishers: `sidebarPublisher`, `titleBarPublisher`, `dividerPublisher`, `framePublisher`, `browserChromePublisher`, `markdownChromePublisher`, `tabBarPublisher` (Combine `PassthroughSubject<Void, Never>` wrappers fire when their section's resolved values would change).
  - `var version: UInt64 { get }` — increments on any theme change, used for full-reload events.
  - Load-from-bundle helper that reads `Resources/c11mux-themes/<name>.toml`.
  - Rollback: reads `CMUX_DISABLE_THEME_ENGINE` env at init; reads `theme.engine.disabledRuntime` AppStorage; when either is true, `resolve` returns `nil` and callers fall back to their legacy paths.
- `Sources/Theme/ThemeDiagnostics.swift` — OSLog subsystem `com.stage11.c11mux`, categories `theme.engine`, `theme.loader`, `theme.resolver`. Dedup warnings per (theme, key) pair per load.
- `cmuxTests/ThemeRegistryTests.swift` — every `ThemeRole` case declares a non-nil default.
- `cmuxTests/ThemeManagerLifecycleTests.swift` — load a theme, assert `active` is populated, assert `version` increments on re-load.
- `cmuxTests/ResolverCacheKeyTests.swift` — changing any single `ThemeContext` field invalidates the cache for affected keys; unaffected keys reuse cached values.

**Commit**: `feat(theme): ThemeManager, ResolvedThemeSnapshot, role registry (CMUX-9 M1a)`.

### Phase 4 — Default theme + round-trip golden + perf regression (M1a unit 4)

**New files**:
- `Resources/c11mux-themes/stage11.toml` — exact content from `docs/c11mux-theming-plan.md` Appendix A.1 (copied verbatim below in §7 of this brief). Bundled as a resource.
- `cmuxTests/Fixtures/golden/stage11-snapshot.json` — the resolved-snapshot golden. CI diffs the M1a output against this.
- `cmuxTests/C11muxThemeLoaderTests.swift` — loads `stage11.toml`, encodes as JSON via the `C11muxTheme` `Codable` conformance, diffs against the golden.
- `cmuxTests/ThemeResolverBenchmarks.swift` — 10,000 resolutions of the hottest roles against representative contexts (3 workspaces × 2 color schemes × light/dark mix). Assert p95 <10ms total and per-lookup <1µs amortized. Gate M1a merge.
- `cmuxTests/ThemeResolvedSnapshotArtifactTests.swift` — at test time, serializes the default-theme resolved snapshot under the canonical default context, diffs against `cmuxTests/Fixtures/golden/stage11-resolved-snapshot.json`. Catches semantics drift before visual drift.
- `cmuxTests/ThemeCycleAndInvalidValueTests.swift` — synthesizes malformed themes (cycle, bad hex, unknown modifier, clamp cases) and asserts expected load-time behavior.

**Commit**: `feat(theme): default stage11 theme, round-trip golden, perf regression (CMUX-9 M1a)`.

Phases 1–4 complete M1a. No call-site changes. Engine loads, resolves, is tested end-to-end. Nothing visible has changed.

### Phase 5 — M1b surface migrations (one commit per surface, flag-gated)

For each surface below, land a commit that:
1. Adds the per-surface `@AppStorage` migration flag with default `false`.
2. Refactors the surface's color path to: if `ThemeManager.shared.isEnabled && migrationFlag`, read from `ThemeManager.resolve(...)`; else run the exact pre-M1 legacy code path.
3. Adds a Debug menu entry `"Debug: Theme M1b / Toggle <surface>"` that flips the AppStorage flag live.
4. Adds the corresponding snapshot test under `cmuxTests/Snapshots/`.

Surfaces in order (low-risk first, per §10 M1b):

1. **`SurfaceTitleBarView`** — `Sources/SurfaceTitleBarView.swift`. Roles: `titleBar_background` (default `$surface`), `titleBar_backgroundOpacity` (default `0.85`), `titleBar_foreground` (default `$foreground`), `titleBar_borderBottom` (default `$separator`). Flag: `theme.m1b.surfaceTitleBar.migrated`.
2. **`BrowserPanelView`** — `Sources/Panels/BrowserPanelView.swift:205-243`. Roles: `browserChrome_background` (default `$ghosttyBackground`), `browserChrome_omnibarFill`. Flag: `theme.m1b.browserChrome.migrated`.
3. **`MarkdownPanelView`** — `Sources/Panels/MarkdownPanelView.swift:270-274`. Role: `markdownChrome_background`. Flag: `theme.m1b.markdownChrome.migrated`.
4. **`Workspace.bonsplitAppearance`** — `Sources/Workspace.swift:5084-5154`. Takes a new `ThemeContext` parameter. Resolves `chromeColors.backgroundHex` through the manager (default resolves `$ghosttyBackground` to today's value). **Do not** wire `borderHex` or `dividerStyle.thicknessPt` yet — those are M2b (and require the bonsplit submodule bump in M2a). Flag: `theme.m1b.bonsplitAppearance.migrated`.
5. **`ContentView.TabItemView`** — `Sources/ContentView.swift:11471-11520` (`resolvedCustomTabColor`, `backgroundColor`, `explicitRailColor`). Theme reads via **pre-computed `let` parameters** passed into `TabItemView` from the parent `ForEach`. Do not add `@EnvironmentObject`/`@ObservedObject`/`@Binding` inside `TabItemView`. Preserve `.equatable()` at the `ForEach` call site and the `==` function. Flag: `theme.m1b.sidebarTabItem.migrated`.
6. **`ContentView.customTitlebar`** — `Sources/ContentView.swift:2200-2242`. Roles: `titleBar_background` defaults to `$ghosttyBackground` (preserves current behavior); `titleBar_borderBottom` defaults to `$separator`. Flag: `theme.m1b.customTitlebar.migrated`.
7. **`WorkspaceContentView`** — `Sources/WorkspaceContentView.swift`. Inject `ThemeManager.shared` + a computed `ThemeContext` into the environment so M2c child views can read it. No visible change. Flag: `theme.m1b.workspaceContentViewContext.migrated`.

**Per surface, commit shape**: `feat(theme): M1b adopt theme engine in <surface> (CMUX-9 M1b)`. Body: what changed, the new flag name, the snapshot test path, and the audit note confirming typing-latency invariants preserved (if applicable — especially for `TabItemView`).

### Phase 6 — Snapshot tests (M1b acceptance)

Add the 24-dim sidebar snapshot, 4-dim titlebar snapshot, 6-dim browser-chrome snapshot per §10 M1b acceptance. Baselines are captured by running the tests once in CI with the flags **on** — these are the expected outputs. Since the default theme produces pixel-identical output, these same snapshots should match a baseline captured with flags **off** (legacy paths) within one pixel tolerance.

- `cmuxTests/Snapshots/sidebar-m1b/` — 24 files: cross-product of {light, dark} × {`.solidFill`, `.leftRail`} × {active, inactive, multi-selected} × {has-custom-color, no-custom-color}. Captured on both Retina (@2x) and non-Retina (@1x) — so actually 48 files if you want full coverage. §10 says 24 so stick to 24 at the primary Retina @2x level; document the @1x delta as a follow-up if drift appears.
- `cmuxTests/Snapshots/titlebar-m1b/` — 4 files: light/dark × {Ghostty-default-background, custom-workspace-background}.
- `cmuxTests/Snapshots/browserChrome-m1b/` — 6 files: light/dark × 3 system appearances.
- `cmuxTests/SidebarSnapshotTests.swift`, `cmuxTests/TitlebarSnapshotTests.swift`, `cmuxTests/BrowserChromeSnapshotTests.swift` — drive the captures.

**Commit**: `test(theme): M1b snapshot acceptance (CMUX-9 M1b)`.

### Phase 7 — Debug menu + rollback plumbing

Wire the Debug menu entries per §9.4 (all `#if DEBUG`):

- "Debug: Dump Active Theme" → opens a new markdown surface with the resolved theme as JSON. (`cmux surface new markdown` + `lattice` not needed — use the existing markdown panel with in-memory content.)
- "Debug: Toggle Theme Engine" → flips `@AppStorage("theme.engine.disabledRuntime")`.
- "Debug: Show Theme Folder" → no-op for M1 (no user themes dir yet); wire as a TODO stub that does `open -R <bundle>/c11mux-themes/stage11.toml` as a placeholder.
- "Debug: Show Resolution Trace" → attached to a submenu for each role; prints the variable chain and fallbacks.
- Per-surface toggles: `"Debug: Theme M1b / Toggle <surface>"` for each of the seven flags above.

See `skills/cmux-debug-windows` conventions (read the skill first if Debug-menu plumbing is unfamiliar).

**Commit**: `feat(theme): Debug menu entries for M1b rollback and diagnostics (CMUX-9 M1)`.

### Phase 8 — PR prep

- Compile check: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-cmux9-m1 build`. Must succeed.
- Read `notes/cmux-9-m1-progress.md` end-to-end — any lingering TODOs or `## Blockers` entries should be surfaced in the PR description.
- Commit any remaining `notes/` files.
- Open the PR with `gh pr create`:
  - Title: `CMUX-9 M1: Theme engine foundation + surface adoption (M1a+M1b)`
  - Body (HEREDOC):
    ```
    ## Summary
    Bundled M1a + M1b from docs/c11mux-theming-plan.md v2.1 §10. Ships the C11muxTheme engine (hand-written TOML subset parser, AST + evaluator, ThemeManager with per-section publishers), the built-in stage11.toml default, and refactors every c11mux chrome surface to read through the engine behind per-surface rollback flags (default off — operator flips per surface after tagged-build verify). Visual change: zero (default theme produces pixel-identical output; all flags default off).

    Closes CMUX-21 (subtask of CMUX-9).

    ## What's new
    - `Sources/Theme/` — 8 new files (parser, AST, evaluator, context, role registry, theme struct, resolved snapshot, manager, workspace-frame stub).
    - `Resources/c11mux-themes/stage11.toml` — bundled default.
    - 7 chrome surfaces migrated behind `theme.m1b.<surface>.migrated` flags.
    - Rollback: `CMUX_DISABLE_THEME_ENGINE` env, `theme.engine.disabledRuntime` AppStorage, per-surface flags.
    - Debug menu: Dump Active Theme, Toggle Engine, Show Resolution Trace, per-surface toggles.

    ## Out of scope (follow-up milestones)
    - M2a: bonsplit DividerStyle struct (submodule).
    - M2b: c11mux wires divider color + thickness through bonsplit borderHex.
    - M2c: WorkspaceFrame overlay + sidebar tint overlay rendering.
    - M3: user themes dir, hot reload, phosphor.toml.
    - M4: Settings picker, `cmux ui themes` CLI.

    ## Test plan
    - [ ] CI: parser fuzz corpus passes.
    - [ ] CI: resolver benchmarks (p95 <10ms / 10k resolutions, <1µs per lookup amortized).
    - [ ] CI: round-trip golden + resolved-snapshot artifact diff.
    - [ ] CI: cycle/invalid-value/unknown-modifier tests.
    - [ ] CI: 24-dim sidebar snapshot, 4-dim titlebar snapshot, 6-dim browser-chrome snapshot.
    - [ ] Local: tagged build (`./scripts/reload.sh --tag cmux9-m1`) launches; `Debug: Dump Active Theme` shows expected resolved values.
    - [ ] Local: flip each M1b flag via Debug menu; surface visually unchanged (default theme = pixel-identical).
    - [ ] Local: set `CMUX_DISABLE_THEME_ENGINE=1`, relaunch; all surfaces run legacy paths (no theme engine activity in OSLog).
    ```
- Merge is operator-driven via `gh pr merge --admin` per §13.9.

**Commit**: `docs: CMUX-9 M1 progress log + PR prep`.

---

## 5. Runtime contract essentials (condensed from §6.4.a)

Enforce these at load time, not render time. Violations fall back to the default theme + OSLog warning.

| Rule | Behavior |
|---|---|
| Reserved magic variables (`$workspaceColor`, `$ghosttyBackground`) cannot be written to in `[variables]` | Load-time error; fall back to default theme |
| Variable dot-path vs modifier disambiguation | Lowercase-letter + no-parens = dot-path segment; identifier + `(...)` = modifier |
| Modifier chain evaluation order | Strictly left-to-right; `$x.opacity(0.5).mix($y, 0.3)` ≠ `$x.mix($y, 0.3).opacity(0.5)` |
| Variable cycle detection | Parse-time topological sort over `[variables]`; cycle = load-time error |
| Out-of-range modifier args (`opacity(1.5)`, `mix($y, -0.2)`) | Clamp to `[0.0, 1.0]`, emit OSLog warning once per key |
| Invalid hex (`#GGG`, `#FF`, `#AABBCCDD00`) | Load-time error; fall back to default theme's value for that key |
| Unknown modifier (`.unknown(0.5)`) | Load-time error |
| Negative thickness | Clamp to 0 |
| Thickness > 8 | Clamp to 8 |
| Disable-signal | Support `{ enabled = false }` inline table AND TOML `null` literal |
| Color space | `sRGB` only; convert P3 inputs on ingress; cross-space `.mix()` is a load-time error |
| Cache key | Full `ThemeContext` hash — not a subset; any future field added automatically becomes part of the cache key |
| Schema version mismatch | Theme with `schema = 2` loaded by v1 cmux = fail closed, fall back to default + warning; theme with `schema = 1` loaded by v2 cmux = v2's problem (not yours) |
| Unknown chrome keys (`chrome.futureSurface.foo`) | Warn-and-ignore via OSLog (forward compatibility for future cmux versions) |
| Reserved-for-M5 keys (`[when.*]` except `when.appearance`; `[identity].inherits`; `chrome.windowFrame.style`; `chrome.dividers.insetLeading/Trailing/opacity`; `behavior.animateWorkspaceCrossfade`) | Warn-and-ignore via OSLog |

---

## 6. `ThemeContext` + helpers

```swift
public enum ColorScheme: Sendable { case light, dark }

public struct ThemeContext: Hashable, Sendable {
    public var workspaceColor: String?          // hex from Workspace.customColor; nil when workspace has no custom color
    public var colorScheme: ColorScheme
    public var forceBright: Bool                // mirrors existing .leftRail forceBright path (§5.2)
    public var ghosttyBackgroundGeneration: UInt64  // increments on ghosttyDefaultBackgroundDidChange
    public var isWindowFocused: Bool = true     // M2c uses this; M1 always true
    public var workspaceState: WorkspaceState? = nil  // RESERVED v1; always nil; always in cache key

    public init(
        workspaceColor: String? = nil,
        colorScheme: ColorScheme,
        forceBright: Bool = false,
        ghosttyBackgroundGeneration: UInt64,
        isWindowFocused: Bool = true,
        workspaceState: WorkspaceState? = nil
    ) { ... }
}

public struct WorkspaceState: Hashable, Sendable {
    public var environment: String?
    public var risk: String?
    public var mode: String?
    public var tags: [String: String] = [:]

    public init() {}
}
```

`$workspaceColor` resolution must go through `WorkspaceTabColorSettings.displayNSColor(hex:colorScheme:forceBright:)` — do **not** re-implement the brightening math. M1 audits that this helper returns `sRGB`; if it returns a non-`sRGB` `NSColor`, convert on ingress in the evaluator.

`$ghosttyBackground` resolves from `GhosttyApp.shared.defaultBackgroundColor` at each call. Subscribe the `ThemeManager` to `ghosttyDefaultBackgroundDidChange` and increment `ghosttyBackgroundGeneration` on each notification — this is what invalidates the resolver cache for `$ghosttyBackground`-derived roles.

---

## 7. `stage11.toml` — verbatim content

Copy this into `Resources/c11mux-themes/stage11.toml` exactly. Whitespace and key order matter for the round-trip golden.

```toml
[identity]
name         = "stage11"
display_name = "Stage 11"
author       = "Stage 11 Agentics"
version      = "0.01.001"
schema       = 1

[palette]
void    = "#0A0C0F"
surface = "#121519"
gold    = "#C4A561"
fog     = "#2A2F36"
text    = "#E9EAEB"
textDim = "#8A8F96"

[variables]
background          = "$palette.void"
surface             = "$palette.surface"
foreground          = "$palette.text"
foregroundSecondary = "$palette.textDim"
accent              = "$palette.gold"
separator           = "$palette.fog"
workspaceColor      = "$workspaceColor"
ghosttyBackground   = "$ghosttyBackground"

[chrome.windowFrame]
color            = "$workspaceColor"
thicknessPt      = 1.5
inactiveOpacity  = 0.25
unfocusedOpacity = 0.6

[chrome.sidebar]
tintOverlay                   = "$workspaceColor.opacity(0.08)"
tintBase                      = "$background"
tintBaseOpacity               = 0.18
activeTabFill                 = "$workspaceColor"
activeTabFillFallback         = "$surface"
activeTabRail                 = "$workspaceColor"
activeTabRailFallback         = "$accent"
activeTabRailOpacity          = 0.95
inactiveTabCustomOpacity      = 0.70
inactiveTabMultiSelectOpacity = 0.35
badgeFill                     = "$accent"
borderLeading                 = "$separator"

[chrome.dividers]
color       = "$workspaceColor.mix($background, 0.65)"
thicknessPt = 1.0

[chrome.titleBar]
background          = "$surface"
backgroundOpacity   = 0.85
foreground          = "$foreground"
foregroundSecondary = "$foregroundSecondary"
borderBottom        = "$separator"

[chrome.tabBar]
background       = "$ghosttyBackground"
activeFill       = "$ghosttyBackground.lighten(0.04)"
divider          = "$separator"
activeIndicator  = "$workspaceColor"

[chrome.browserChrome]
background   = "$ghosttyBackground"
omnibarFill  = "$surface.mix($background, 0.15)"

[chrome.markdownChrome]
background = "$background"

[behavior]
animateWorkspaceCrossfade = false
```

---

## 8. Commit discipline

- **One logical unit per commit.** Phase 1 is one commit (parser+AST+fuzz). Phases 2, 3, 4 are one commit each. Phase 5 is seven commits (one per surface). Phase 6 is one or three commits (one is fine; three if they naturally split per snapshot group). Phase 7 is one commit. Phase 8 is one commit.
- **Every commit compiles.** Run `xcodebuild ... build` before each commit. If a commit doesn't compile, back it out or amend.
- **Commit trailer**: `Refs: CMUX-21` and `Refs: CMUX-9` in the body. Co-author line per CLAUDE.md global instructions:
  ```
  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
  ```
  (Opus drafted this brief; Codex implements. The co-author is accurate.)
- **No amends to published commits** unless fixing a CI break before pushing.
- **Regression-test-first applies where applicable.** M1b surface migrations don't fit the pattern (they're net-new + flag-gated). Cycle/invalid-value tests DO — write the failing test in one commit, add the fix in the next. But Phase 4's cycle test lands alongside the fix (the evaluator is what's being tested; test-first doesn't apply to initial implementation).

---

## 9. Verification

**Build-only (after every commit)**:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-cmux9-m1 build
```

**Tagged debug app (before Phase 8 PR open — eyeball verification)**:
```bash
./scripts/reload.sh --tag cmux9-m1
# Quit with cmd+q before re-launching. Debug log at /tmp/cmux-debug-cmux9-m1.log.
```

**Never**: `xcodebuild test`, `./scripts/reloadp.sh`, bare `cmux DEV.app` from DerivedData.

---

## 10. Escalation / pause rules

Stop and write to `notes/cmux-9-m1-progress.md` → `## Blockers` when:

- A tool or script fails in a way this brief doesn't anticipate, after one retry.
- A test fails in a way that isn't fixable with a local code change (e.g., the snapshot baseline differs from pre-M1 in ways that can't be explained by the refactor).
- You discover an ambiguity in the plan that isn't resolved here or in `docs/c11mux-theming-plan.md`.
- You're about to touch a file that's explicitly out of scope (`vendor/bonsplit`, `ghostty`, M2+ surfaces).
- Any "Hard constraint" in §3 of this brief is about to be violated by the path you were taking.

When blocked: pick the most conservative interpretation, proceed, and note it in the blockers log. The operator will review before merge.

When finished: update `notes/cmux-9-m1-progress.md` with a final status, run the PR-prep checklist in Phase 8, and open the PR. Then:
```bash
lattice update CMUX-21 --status review --name <your-session> --reason "M1 PR open; awaiting operator review"
```

---

## 11. Reference materials

- `docs/c11mux-theming-plan.md` (v2.1) — your spec.
- `CLAUDE.md` at repo root — project-level conventions.
- `~/.claude/CLAUDE.md` — global conventions (you don't have access, but the project CLAUDE.md references the rules that matter to you).
- `skills/cmux-debug-windows/SKILL.md` — Debug-menu plumbing patterns.
- `skills/lattice/SKILL.md` — Lattice CLI patterns.

End of brief. Go.
