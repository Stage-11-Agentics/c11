# c11 development

A one-screen map of the codebase so a new contributor — or their agent — can land somewhere useful on the first grep instead of the fifteenth.

This doc is *where things live*. For *how to work* — setup, build, reload, commit style, PR flow — see [`../CONTRIBUTING.md`](../CONTRIBUTING.md). For *why things are shaped the way they are*, see [`../PHILOSOPHY.md`](../PHILOSOPHY.md).

## Top-level layout

```
c11/
├── Sources/            Swift app code (the c11 macOS app)
├── CLI/                The `c11` CLI binary (single Swift file, ~16k lines)
├── Resources/          Bundled assets (Info.plist, xcstrings, shell integration, welcome.md, themes)
├── skills/             Agent-facing skill files (c11, c11-browser, c11-markdown, c11-hotload, release)
├── ghostty/            Submodule — fork of Ghostty rendering the terminals
├── vendor/
│   └── bonsplit/       Submodule — tab bar and split chrome
├── homebrew-c11/       Submodule — Homebrew tap for the `c11` cask
├── web/                Next.js marketing site
├── daemon/             Remote daemon prototype (see docs/remote-daemon-spec.md)
├── c11Tests/           Swift unit tests (XCTest)
├── c11UITests/         Swift UI tests (XCUITest, run in CI)
├── tests/              Shell + Python v1 tests (older)
├── tests_v2/           Python socket tests (newer, preferred for new socket work)
├── scripts/            Build / reload / release automation
├── docs/               You are here
├── design/             Design assets, mockups, references
└── GhosttyTabs.xcodeproj   Xcode project (original project name, pre-rename)
```

## The Xcode project

The project file is still called `GhosttyTabs.xcodeproj` from before the cmux → c11 rename. Cheap to rename, expensive in merge-conflict risk — so we left it. Schemes inside it use the current names:

- **c11** — full app, Debug/Release configurations
- **c11-unit** — unit test target only; no app launch, safe to run from Xcode

## `Sources/` tour

The app is ~50 top-level Swift files plus subdirs. Entry points and the most-touched areas:

### App lifecycle & window shell

| File | Role |
|---|---|
| `c11App.swift` | SwiftUI `App` entry point |
| `AppDelegate.swift` | NSApplicationDelegate — 13k LOC — lifecycle, menu bar, tab/workspace routing, IPC |
| `ContentView.swift` | Root SwiftUI view — 14k LOC — sidebar + workspace split + tab bar |
| `WindowAccessor.swift`, `WindowDecorationsController.swift`, `WindowToolbarController.swift`, `WindowDragHandleView.swift` | Window chrome and AppKit-SwiftUI bridge |

### Terminals, browsers, markdown (the surface types)

| Area | Files |
|---|---|
| Terminal | `TerminalView.swift`, `GhosttyTerminalView.swift`, `GhosttyConfig.swift`, `TerminalController.swift`, `TerminalWindowPortal.swift` |
| Browser | `BrowserWindowPortal.swift`, `Panels/BrowserPanel.swift`, `Panels/BrowserPanelView.swift`, `Panels/CmuxWebView.swift` |
| Markdown | `Panels/MarkdownPanel.swift`, `Panels/MarkdownPanelView.swift`, `Panels/FencedCodeRenderer.swift`, `Panels/MermaidRenderer.swift` |
| Panel base | `Panels/Panel.swift`, `Panels/PanelContentView.swift`, `Panels/PaneInteraction.swift` |

### Panes, tabs, workspaces

| File | Role |
|---|---|
| `TabManager.swift` | Tab lifecycle |
| `Workspace.swift`, `WorkspaceContentView.swift`, `WorkspaceMetadataKeys.swift` | Workspace model & view |
| `SessionPersistence.swift`, `PersistedMetadata.swift` | Restore across launches |

### Agent-facing surface (metadata / skills / status)

| File | Role |
|---|---|
| `AgentDetector.swift` | Identifies which agent (Claude Code / Codex / Gemini / shell) is running in a pane |
| `AgentChip.swift`, `AgentChipBadge.swift` | Sidebar chip UI |
| `AgentSkillsView.swift`, `SkillInstaller.swift` | Skills onboarding sheet |
| `PaneMetadataStore.swift`, `SurfaceMetadataStore.swift`, `SurfaceTitleBarView.swift` | The surface manifest — the open JSON blob agents read/write over the socket |

### Theming

`Sources/Theme/` is its own small world — canonicalization, AST, evaluator, socket methods, directory watcher. If you're adding theme keys, start with `ThemeRoleRegistry.swift` and `ThemeCanonicalizer.swift`.

### Update (Sparkle)

`Sources/Update/` holds the Sparkle integration (controller, delegate, UI pill, test URL protocol). Sparkle keys, appcast generation, and the signing story live in `scripts/sparkle_*`.

### Find / search overlay

`Sources/Find/SurfaceSearchOverlay.swift` is the terminal find UI. **It must be mounted from `GhosttySurfaceScrollView` in `GhosttyTerminalView.swift`** (the AppKit portal layer), not from SwiftUI panel containers — portal-hosted terminal views can sit above SwiftUI during split churn. See the note in [`../CLAUDE.md`](../CLAUDE.md) before moving it.

## The CLI and socket

`CLI/c11.swift` is one enormous Swift file — the `c11` binary. It:

- parses subcommands (`c11 split`, `c11 send`, `c11 tree`, `c11 browser ...`, `c11 set-metadata`, etc.)
- talks to the running app over a Unix socket (`/tmp/c11.sock` in production, `/tmp/c11-debug-<tag>.sock` for tagged dev builds)
- doubles as a compat shim for the legacy `cmux` command (hardlink in the bundle)

The socket protocol it speaks is documented in [`socket-api-reference.md`](socket-api-reference.md). New CLI commands almost always pair with a new socket method on the app side — the canonical pattern is: add the socket method in `AppDelegate.swift` or a domain-specific handler (e.g., `Theme/ThemeSocketMethods.swift`), wire it into the CLI dispatch in `CLI/c11.swift`, and add a Python test in `tests_v2/`.

## Latency-sensitive paths — read before editing

A small number of code paths are called on every keystroke. Work added here shows up as visible typing lag. Full detail in [`../CLAUDE.md`](../CLAUDE.md); the short version:

- **`WindowTerminalHostView.hitTest()`** in `TerminalWindowPortal.swift` — all divider/sidebar/drag routing is gated to pointer events only. Don't add work outside the `isPointerEvent` guard.
- **`TabItemView` in `ContentView.swift`** — uses `Equatable` + `.equatable()` to skip body re-evaluation during typing. Don't add `@EnvironmentObject`, `@ObservedObject` (besides `tab`), or `@Binding` without updating `==`. Don't remove `.equatable()` from the `ForEach`.
- **`TerminalSurface.forceRefresh()`** in `GhosttyTerminalView.swift` — no allocations, file I/O, or formatting here.

## Socket threading — read before adding a socket command

Default new socket commands to **off-main** handling. Only commands that directly mutate AppKit / Ghostty UI state (focus, open/close, send-key, synchronous snapshot queries) should run on main. Telemetry hot paths (`report_*`, status/progress updates) must not use `DispatchQueue.main.sync`. See the "Socket command threading policy" in [`../CLAUDE.md`](../CLAUDE.md).

## Tests

c11 has four test surfaces, roughly in order of how often you'll touch them:

| Suite | Where | How to run | When to use |
|---|---|---|---|
| Swift unit | `c11Tests/` (~60 files) | `xcodebuild -scheme c11-unit` or from Xcode | Pure logic, metadata store, theme evaluator, CLI arg parsing |
| Python socket v2 | `tests_v2/` (~140 files) | `C11_SOCKET=/tmp/c11-debug-<tag>.sock ./scripts/run-tests-v2.sh` against a tagged Debug build | New socket commands, CLI flows, browser automation, pane/workspace lifecycle |
| Python socket v1 | `tests/` (~90 files, shell + python) | `./scripts/run-tests-v1.sh` | Older coverage; generally don't add new tests here, prefer v2 |
| Swift UI | `c11UITests/` (~16 files) | `gh workflow run test-e2e.yml`, or Xcode (slow, flaky on low-RAM) | Full app flows — menu routing, dialogs, drag/drop, keybind regressions |

**Test quality rule** ([`../CLAUDE.md`](../CLAUDE.md#test-quality-policy)): tests must verify observable runtime behavior. Tests that grep source text, assert on `Info.plist` shape, or check AST fragments get rejected. If a behavior isn't exercisable end-to-end yet, add a runtime seam first and test through it.

## Build & reload

Covered in [`../CONTRIBUTING.md`](../CONTRIBUTING.md#the-hot-reload-loop) and deeply in [`../skills/c11-hotload/SKILL.md`](../skills/c11-hotload/SKILL.md). The one-liner for day-to-day dev:

```bash
./scripts/reload.sh --tag <your-branch-slug>
```

## Release

Release machinery lives in `scripts/` (signing, notarization, DMG assembly, appcast, Homebrew cask bump) and `.github/workflows/release.yml`. The flow is documented in [`../skills/release/SKILL.md`](../skills/release/SKILL.md) and triggered by the `/release` command.

## Ghostty submodule

The `ghostty/` submodule tracks [`manaflow-ai/ghostty`](https://github.com/manaflow-ai/ghostty), a fork carrying c11-specific patches. Fork status, merge hygiene, and conflict notes live in [`ghostty-fork.md`](ghostty-fork.md) and [`upstream-sync.md`](upstream-sync.md). Always push the submodule commit to the fork before bumping the parent pointer — detached-HEAD commits are orphaned.

## Where the upstream lineage shows

c11 is a fork of [`manaflow-ai/cmux`](https://github.com/manaflow-ai/cmux). Lots of code paths still carry the upstream shape — file names, module names, socket protocol. If you touch code that clearly came from upstream and your fix isn't c11-specific, flag it in the PR description so we can decide whether to also float the change back upstream. Shared improvements should flow both ways; silent divergence on shared code makes future merges painful and costs both projects wins they'd otherwise share. See the "cmux ↔ c11 relationship" section in [`../CLAUDE.md`](../CLAUDE.md).

## Further reading

- [`../PHILOSOPHY.md`](../PHILOSOPHY.md) — the worldview
- [`../CLAUDE.md`](../CLAUDE.md) — operational guardrails (testing, threading, latency, submodules)
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — human contributor workflow
- [`contributing-with-your-agent.md`](contributing-with-your-agent.md) — agent-operator supplement
- [`socket-api-reference.md`](socket-api-reference.md) — socket protocol reference
- [`browser-automation-reference.md`](browser-automation-reference.md) — browser surface automation
- [`../skills/c11/SKILL.md`](../skills/c11/SKILL.md) — the agent-facing how-to-use-c11
