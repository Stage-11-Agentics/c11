# c11 — TextBox Input Port Plan

**Date**: 2026-04-18
**Status**: Draft v2 — revised post-Trident plan review (see `docs/c11mux-textbox-port-plan-review-pack-2026-04-18T1255/`)
**Target branch**: feature branch off `main` (e.g. `m9-textbox-input`), worked in a git worktree
**Source**: [`alumican/cmux-tb`](https://github.com/alumican/cmux-tb) — 135 commits ahead of `manaflow-ai/cmux` main, 189 behind

## Revision history

- **v1 (2026-04-18)** — Initial draft.
- **v2 (2026-04-18)** — Revised after Trident review (9 agents across Claude/Codex/Gemini; Gemini Standard failed on capacity). Applied verified factual fixes: shortcut collision, missing `defaultForegroundColor` symbol, missing title-sync hook, drag-routing scope expansion, Japanese translations already present in fork, `[cmux-tb]` tag stripping, tier-1 persistence coordination. Architectural open questions (rename, AgentDetector wiring, settings count, coupling model, PR split) moved to §8 for decisions before Phase 1.

---

## 1. Summary

Port the TextBox Input feature from the alumican/cmux-tb fork into c11. The feature adds a native macOS text-input box mounted below each terminal surface, giving users (and AI agents) a friendlier way to compose and submit multi-line text to the shell.

**Rationale**: The feature is meaningful for a real subset of users — especially AI-agent workflows where multi-line prompt editing in-terminal is awkward. It is self-contained (one 1246-line Swift file does most of the work) and integrates via a small number of additive hooks. Porting is cheaper than reimplementing.

**Shape of the port**: Selective forward-port, not a merge. The fork is 189 commits behind upstream and has fork-specific release/branding artifacts we do not want. We copy the one new file verbatim and hand-apply the integration hooks to c11's current `main`.

---

## 2. What the feature is

### User-facing behavior

- **Location**: A thin bordered text box mounted directly below each terminal pane.
- **Toggle**: `Cmd+Option+T` shows/hides or focuses/unfocuses, per user setting.
- **Auto-grow**: Expands from 2 visible lines up to 8, then scrolls internally.
- **Theme sync**: Inherits the terminal's background (with opacity), foreground color, and font.
- **Send**: `Return` submits, `Shift+Return` inserts a newline. Swappable in settings.
- **Send button**: Paperplane icon to the right of the text box.
- **Placeholder**: Dynamic, reflects the current send-key setting.
- **Drag & drop**: File drops onto the TextBox shell-escape and insert as paths.

### AI-agent-specific behavior

- Detects Claude Code (title regex `Claude Code|^[✱✳⠂] `) and Codex (title contains `Codex`).
- When detected AND the TextBox is empty:
  - `/` and `@` are forwarded to the terminal and focus moves back to the terminal (agent menu triggers).
  - `?` is forwarded as a key event but focus stays in the TextBox (help).

### Submission mechanism

Text is sent via PTY bracket-paste (`\x1b[200~…\x1b[201~`) to preserve multi-line input. A synthetic `Return` is sent 200ms later — this delay is empirically the minimum reliable value because zsh and Claude CLI finish paste processing before accepting `\r`.

### Settings

Four controls, all persisted via `UserDefaults` (AppStorage keys):

| Setting | Values | Fork default |
|---|---|---|
| Enable Mode | on / off | **on** |
| Send on Return | Return=send (Shift+Return=newline) / inverse | Return=send |
| Escape key | Send ESC to terminal / Move focus to terminal | Send ESC |
| Toggle shortcut behavior | Toggle display (show/hide) / Toggle focus (keep visible) | Toggle focus |

---

## 3. Architecture (source-of-truth file: `Sources/TextBoxInput.swift`)

Single 1246-line file containing:

### Constants & enums
- `TextBoxLayout`, `TextBoxInputViewLayout`, `TextBoxBehavior` — layout/timing constants
- `TextBoxToggleTarget` — `.active` (single pane) or `.all` (all tabs)
- `TextBoxAppDetection` — title-regex-based agent detection
- `TextBoxFocusState` — `.hidden`, `.visibleUnfocused`, `.visibleFocused`
- `TextBoxShortcutBehavior`, `TextBoxEscapeBehavior` — user-setting enums

### Key routing
- `TextBoxKeyInput` — normalized keystroke form (ctrl / key / text / command)
- `TextBoxKeyRouting` — 10-rule top-down routing table
- `TextBoxKeyAction` — decision output (emacsEdit / forwardControl / forwardPrefix / submit / insertNewline / escape / etc.)
- `TextBoxSubmit` — bracket-paste + delayed `Return`

### SwiftUI / AppKit bridge
- `TextBoxInputContainer: View` — the SwiftUI wrapper (bindings + send button + height handling)
- `TextBoxInputView: NSViewRepresentable` — the `NSTextView` bridge (styling, IME-safe update)
- `InputTextView: NSTextView` — custom subclass intercepting `keyDown`, `insertText`, `doCommand`, plus custom `draw(_:)` for the placeholder and `insertDroppedFilePaths(_:)` for drag-and-drop

### Settings
- `TextBoxInputSettings` — centralized `UserDefaults` keys, getters, and `resetAll()`

---

## 4. Integration surface — per-file plan

For each file, `delta` is the fork's diff against upstream `main`. `c11 risk` reflects how much the current c11 file diverges in ways that could collide with the fork's edits.

### 4.1 New files (copy with small edits)

| File | Lines | Action |
|---|---|---|
| `Sources/TextBoxInput.swift` | 1246 | Copy with four edits: (1) `defaultEnabled = false` (§8 Q2); (2) strip `[cmux-tb]` inline tags / fork-author metadata; (3) change default shortcut constant from `"t"` to `"b"` (§4.5); (4) rewrite `TextBoxAppDetection` to read `SurfaceMetadataStore.terminalType` first and fall back to the fork's title regex (§8 Q4). |
| `cmuxTests/TextBoxInputTests.swift` | 360 | Copy; verify `@testable import` matches c11's target (fork uses `cmux_DEV` + `cmux`, matching c11's existing convention — so likely no change needed). Update `defaultEnabled` assertion to `false` to match our flipped default. Key assertion `"b"` already matches our chosen shortcut. |

**On the two-commit regression-test pattern.** CLAUDE.md's red-then-green split is for bug-fix PRs — it asserts the test genuinely catches the bug. These tests validate a newly-ported feature, not a c11 bug fix. The pattern does not apply here. Call this out in the PR description to preempt reviewer confusion.

**Strip fork-author metadata.** Grep the file for `[cmux-tb]` and any `alumican`/`fork-release` references. These are maintenance markers tied to the upstream fork's release channel and must not ship in c11.

### 4.2 Model: `Sources/Panels/TerminalPanel.swift` (fork delta: +14)

Add three properties to the existing `TerminalPanel` ObservableObject:

```swift
@Published var isTextBoxActive: Bool = TextBoxInputSettings.isEnabled()
@Published var textBoxContent: String = ""
weak var inputTextView: InputTextView?
```

**c11 risk**: none. Pure additions; no existing logic touched.

### 4.3 View: `Sources/Panels/TerminalPanelView.swift` (fork delta: +74 / −19)

Wrap the existing terminal view in a VStack and conditionally mount `TextBoxInputContainer` below it. Add three `@AppStorage` properties (`textBoxEnabled`, `enterToSend`, `shortcutBehavior`), a `showTextBox` computed property, and two `onChange` observers that auto-focus or force-show on setting toggles.

**c11 risk**: low. c11 has sidebar and theming work here but the insertion pattern (VStack + conditional view below terminal) slots cleanly underneath any existing content.

**Review point**: verify c11's `TerminalPanelView` still has the search-overlay layering constraint documented in CLAUDE.md — the overlay must continue to be portal-mounted from `GhosttySurfaceScrollView`, not from this panel. Mounting the TextBox below the terminal should not disturb this.

### 4.4 Model: `Sources/Workspace.swift` (fork delta: +83)

Add one method, `toggleTextBoxMode(_:)` (~70 lines), that:

1. Resolves the target set (active panel vs. all tabs).
2. For `.toggleDisplay`: flips `panel.isTextBoxActive`.
3. For `.toggleFocus`: detects which side currently has focus by checking `panel.inputTextView === firstResponder`, then swaps.
4. Dispatches focus changes via `DispatchQueue.main.async` to avoid reentrancy.

**Also add the title-sync hook.** Inside `updatePanelTitle` (c11 `Workspace.swift` has a sibling of the fork's `updatePanelTitle`), when the panel is a `TerminalPanel` and the title actually changed, call `terminalPanel.updateTitle(trimmed)`. Fork adds this hook at its `Workspace.swift:7819–7823` with the comment *"Keep TerminalPanel.title in sync so TextBox key routing can detect running apps (Claude Code, Codex) by terminal process title."* Without this hook, the fork's title-regex agent detection silently never fires — shipping a broken `/`/`@`/`?` feature. Verified against fork source.

**c11 risk**: low. c11 has heavy churn in `Workspace.swift` around surface management and session restore, but the two additions (`toggleTextBoxMode` + title-sync line) are self-contained and do not touch existing lifecycle code.

**Review point**: confirm the focus-detection pattern (`firstResponder is InputTextView`) does not race with c11's own focus work — specifically any code that asynchronously restores focus after a workspace switch.

**Multi-window semantics**: confirm what `.all` scope means — all panels in the current workspace, all panels in the current window, or every panel across every window. Fork's implementation iterates `panels.values` (one workspace); multi-window is undefined.

### 4.5 Shortcuts: `Sources/KeyboardShortcutSettings.swift` (fork delta: +11)

- Add `case toggleTextBoxInput` to the `Action` enum.
- Add the localized label in the label switch.
- Add the default shortcut: **`Cmd+Option+B`** (not the fork's `Cmd+Option+T` — see collision note below).
- Add a `toggleTextBoxInputShortcut()` getter.

**Shortcut collision — `Cmd+Option+T` is already bound.** c11 binds this chord at `Sources/AppDelegate.swift:9498` (hardcoded, not through `KeyboardShortcutSettings`) to `closeOtherTabsInFocusedPaneWithConfirmation()`. The binding is guarded by `cmuxTests/AppDelegateShortcutRoutingTests.swift`. The fork's own `KeyboardShortcutSettings.swift:265` contains an inline comment acknowledging this: *"Default: Cmd+Opt+T (upstream cmux PR uses Cmd+Opt+B to avoid conflict with close-other-tabs)."* We take the upstream-safe choice: **`Cmd+Option+B`**. Zero migration cost.

**Fork test reconciliation.** With `B` as the default, the fork's `cmuxTests/TextBoxInputTests.swift:54` assertion `shortcut.key == "b"` already matches. However the fork source itself ships `"t"` — the fork's tests and source are internally inconsistent. Porting the test verbatim with our `"b"` default is correct and self-consistent.

**c11 risk**: none. Enum extension.

### 4.6 App shell: `Sources/AppDelegate.swift` (fork delta: +8)

In the global `sendEvent`/shortcut dispatch, intercept the configured TextBox shortcut and call `workspace.toggleTextBoxMode(.default)`.

**c11 risk**: very low. Pattern mirrors existing shortcut intercepts.

### 4.7 Settings UI: `Sources/cmuxApp.swift` (fork delta: +72 / −2)

Append a `SettingsSectionHeader("TextBox Input")` section with four controls matching the settings in §2. One line in the "Reset All Settings" flow to call `TextBoxInputSettings.resetAll()`.

**c11 risk**: low. Append-only addition to the settings panel.

### 4.8 Terminal bridge: `Sources/GhosttyTerminalView.swift` (fork delta: +84)

Additions to `TerminalSurface`:

- `focusTerminalView()` — moves first responder back to the surface view.
- `sendSyntheticKey(characters:keyCode:modifiers:)` — builds an `NSEvent` and calls `view.keyDown(with:)`.
- `sendKey(_ key: TextBoxKeyRouting.TerminalKey)` — named-key wrapper.
- `forwardKeyEvent(_ event: NSEvent)` — pass-through.
- `scrollbarOffset`, `isScrolledUp`, `scrollToRow(_:)` — scroll state save/restore (so TextBox resize does not snap the terminal to bottom).
- Focus guards: `if firstResponder is InputTextView { return }` before focus-stealing code paths. **Do a grep pass for every `makeFirstResponder(surfaceView)` / `view.window?.makeFirstResponder(view)` call site in c11 (not just the two the fork patched) and add a guard at each one.** c11 has additional focus-restore paths — e.g. `scheduleAutomaticFirstResponderApply`, `reassertTerminalSurfaceFocus` — that did not exist in upstream when the fork branched.

**New symbol needed: `GhosttyApp.shared.defaultForegroundColor`.** The fork's `TerminalPanelView` reads this property for theme sync; current c11 only exposes `defaultBackgroundColor` and `defaultBackgroundOpacity` (see `Sources/GhosttyTerminalView.swift:847-848`). Without adding it, the integration does not compile. Options:

1. Add a `private(set) var defaultForegroundColor: NSColor = .textColor` property to the `GhosttyApp` class, mirroring the existing `defaultBackgroundColor` pattern, and plumb updates through the same theme-change path. Recommended.
2. Read the foreground from `GhosttyConfig.foregroundColor` directly inside `TerminalPanelView`, skipping the `GhosttyApp` seam. Simpler but diverges from the fork's pattern.

Folded into Phase 3 (terminal-surface extensions) below.

**c11 risk**: very low — all additive. But `GhosttyTerminalView.swift` contains `TerminalSurface.forceRefresh()`, which CLAUDE.md flags as typing-latency-sensitive. None of these additions touch that method.

**Verified**: c11's Ghostty submodule defines `scroll_to_row` in `src/input/Binding.zig` — the binding the TextBox uses for scroll preservation is supported.

### 4.9 Drag routing: `Sources/ContentView.swift` (fork delta: +111 / −15) — **highest collision risk**

The drag-and-drop integration is NOT one entry point — it is the full NSDraggingDestination lifecycle. The fork modifies:

- `findTextBox(in:windowPoint:)` — a recursive `NSView` walker that returns the `InputTextView` under a window point, if any.
- `draggingEntered(_:)` — accept the drag session when it arrives over a TextBox.
- `draggingUpdated(_:)` — return `.copy` so macOS shows the green `+` badge over a valid TextBox drop target (otherwise the user sees a reject cursor over a target that *will* actually accept).
- `prepareForDragOperation(_:)` — prepare state for the pending drop.
- `performDragOperation(_:)` — call `insertDroppedFilePaths(_:)` with the shell-escaped paths.
- `concludeDragOperation(_:)` — finalize.

**c11-specific wrinkle.** c11's drag system uses portal-based hit testing and `activeDragWebView`/`preparedDragWebView` state (see `Sources/ContentView.swift:607-685`). The fork's simpler recursive-walker approach will not drop in cleanly on top of that state machine. Phase 5 must read the *current* c11 drag pipeline end-to-end before deciding whether to:

1. Slot a TextBox check in front of the existing web/browser/terminal ordering (likely correct priority: after browser/web, before terminal).
2. Extend the `activeDragWebView` pattern to a generalized `activeDragTarget` enum so TextBox, web, and terminal share one state machine.

Option 1 is closer to the fork. Option 2 is cleaner and reduces future drift. Pick one before writing code.

The fork also touches the Help menu to point at fork-specific URLs — **do not port**.

**c11 risk**: moderate-to-high. c11's `ContentView.swift` has the most churn of any integration point, and this is the only part of the port that mutates (rather than appends to) an actively contested file.

- Fork's `-15` lines include Help-menu URL edits we explicitly reject; the remaining `-` must be inspected to confirm they are only drag-routing adjustments.
- `TabItemView` in `ContentView.swift` is typing-latency-sensitive per CLAUDE.md. The fork's changes do **not** touch `TabItemView`; re-confirm during port.
- Recursive NSView walker on every drag event is O(depth). In deep bonsplit trees this has a measurable cost. Consider replacing with a localized `NSViewRepresentable` drop target on the `TextBoxInputContainer` as a follow-up.

### 4.10 Localization: `Resources/Localizable.xcstrings` (fork delta: ~18 strings)

Add the fork's ~18 new keys (settings section, menu entry, placeholder, send tooltip, enum option labels).

**Fork already ships Japanese translations.** Contrary to v1 of this plan, the fork's `Resources/Localizable.xcstrings` has `"ja"` values (`"translated"` state) for every TextBox string — e.g. `menu.view.toggleTextBoxInput` = `テキストボックス入力を切り替え`, `settings.section.textBoxInput` = `テキストボックス入力`. Verified against fork source.

**c11 ships 18 locales** (verified): `en`, `ja`, `zh-Hans`, `zh-Hant`, `ko`, `ar`, `bs`, `da`, `de`, `es`, `fr`, `it`, `nb`, `pl`, `pt-BR`, `ru`, `th`, `tr`. CLAUDE.md is explicit: *"All user-facing strings must be localized... Keys go in `Resources/Localizable.xcstrings` with translations for all supported languages (currently English and Japanese)."*

**Plan**: port the fork's English AND Japanese values verbatim in Phase 7. For the other 16 locales, follow c11's existing pattern (leave the keys untranslated so they fall back to English until translation passes run). Shipping EN-only would violate policy; shipping EN+JA matches existing practice.

**Open question in §8**: whether to hand-translate the other 16 locales now, batch-translate via LLM during the port, or defer to a follow-up PR.

**c11 risk**: none — additive; matches existing patterns.

### 4.11 Project file: `GhosttyTabs.xcodeproj/project.pbxproj`

Add two file references and two build-file entries:

- `TextBoxInput.swift` → main target Sources build phase.
- `TextBoxInputTests.swift` → `cmuxTests` target Sources build phase.

**c11 risk**: none. Standard Xcode file-add; do it through Xcode to avoid hand-editing the pbxproj.

---

## 5. What we do NOT port

| Artifact | Reason |
|---|---|
| `Resources/Info.plist` `SUFeedURL` change | Fork points Sparkle at its own appcast; would hijack c11's update channel. |
| `.github/workflows/release-tb.yml` | Fork-specific CI/release pipeline with alumican's signing identity. |
| `fork-release.md`, `upstream-sync.md` | Fork-maintenance docs, not applicable to c11. |
| Help-menu URL edits in `ContentView.swift` | Point at fork repo; would mis-route users. |
| `.vscode/launch.json` | Fork author's local editor config. |
| `scripts/sparkle_generate_appcast.sh` delta | Fork-specific release tweaks. |
| `tests/test_ci_scheme_testaction_debug.sh` delta | Fork CI-specific. |

**Optional** (port if desired):
- `docs/assets/textbox-*.{gif,mp4,png}` — screencasts of the feature. Useful for c11's own changelog/README if we want to showcase the feature.

---

## 6. Phased execution (done in a worktree)

Each phase is a logical commit. The worktree lives outside `/Users/atin/Projects/Stage11/code/cmux` so it does not disturb the working checkout.

### Worktree setup
```
git worktree add ../cmux-m9-textbox -b m9-textbox-input
cd ../cmux-m9-textbox
./scripts/setup.sh   # submodules + GhosttyKit
```

### Phase 0 — Preflight gate (do before Phase 1)

Pre-implementation decisions that must be locked before copying any code. Each answer goes into §8 of this plan, not into source:

- Shortcut default (this plan: `Cmd+Option+B`).
- `defaultForegroundColor` source strategy (recommended: add to `GhosttyApp`).
- Port strategy for agent detection: title-regex only, or wire to `AgentDetector` / `SurfaceMetadataStore`?
- Rename (TextBoxInput → ComposeSurface) yes/no — irreversible after first commit because `UserDefaults` keys ship.
- Settings count (4 fork-default vs. 2 minimal).
- PR split shape (single 8-commit PR vs. 3+5 split).

### Phase 1 — Drop in standalone code (scaffolding PR — no behavior change)
- Copy `Sources/TextBoxInput.swift` with three edits: `defaultEnabled = false`, strip `[cmux-tb]` tags, change default shortcut constant to `"b"`.
- Copy `cmuxTests/TextBoxInputTests.swift`, update `defaultEnabled` assertion to `false`.
- Add both to Xcode project.
- Build verification: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -derivedDataPath /tmp/cmux-m9-textbox build` — no launch, no untagged `.app`.

### Phase 2 — Model + shortcut registration + settings UI
- `TerminalPanel.swift`: three new properties.
- `KeyboardShortcutSettings.swift`: enum case + label + default `Cmd+Option+B` + getter.
- `cmuxApp.swift`: settings section + reset hook. **Specify target section** — recommend adding under an existing "Input" or "Terminal" section rather than creating a new top-level section. Record the chosen location in commit message.
- Build check (tagged derivedDataPath).

### Phase 3 — Terminal-surface extensions
- `GhosttyTerminalView.swift`: `focusTerminalView`, `sendSyntheticKey`, `sendKey`, `forwardKeyEvent`, scroll helpers (3 props), focus guards.
- **Add `defaultForegroundColor: NSColor` to `GhosttyApp`** mirroring the existing `defaultBackgroundColor` pattern (see §4.8).
- **Grep every `makeFirstResponder(surfaceView)` call site** (not just the two the fork patched) and add `if firstResponder is InputTextView { return }` where appropriate.
- Build check (tagged derivedDataPath).

**Scaffolding checkpoint.** Everything to here is additive with no user-visible change. Safe to pause and take a build inventory before starting view integration.

### Phase 4 — View integration
- `TerminalPanelView.swift`: mount `TextBoxInputContainer`, add `@AppStorage`, add `onChange` observers. Reconcile the signature drift (fork uses `paneId: PaneID`; c11 does not — port the TextBox-relevant slice only).
- Tagged reload: `./scripts/reload.sh --tag m9-textbox`. Smoke-test: enable in settings, confirm TextBox appears below terminal.

### Phase 5 — Shortcut + toggle wiring + title sync
- `AppDelegate.swift`: shortcut intercept.
- `Workspace.swift`: `toggleTextBoxMode(_:)` method + `terminalPanel.updateTitle(trimmed)` inside `updatePanelTitle` (see §4.4 "title-sync hook").
- Tagged reload. Smoke-test: `Cmd+Option+B` toggles; `.toggleDisplay` and `.toggleFocus` both work; `.all` scope flips every tab; opening `claude` shows title sync so `/`/`@` routing works.

### Phase 6 — Drag routing
- `ContentView.swift`: `findTextBox()` helper + the full drag lifecycle — `draggingEntered`, `draggingUpdated` (return `.copy` for TextBox hits to get the green `+` badge), `prepareForDragOperation`, `performDragOperation`, `concludeDragOperation`.
- **Do not** port the Help-menu URL changes or any fork-branded text.
- Tagged reload. Smoke-test the drag matrix: drop file onto TextBox (paths inserted, `+` badge shows), onto web pane (web handles it, badge appropriate), onto terminal (terminal fall-through), onto bonsplit divider (no-op).

### Phase 7 — Localization
- Add the fork's ~18 strings to `Resources/Localizable.xcstrings` with EN + JA values. Other 16 locales: leave untranslated and let them fall back to English (matches c11's existing pattern).
- Build check.

### Phase 8 — Validation
- Exercise the full matrix:
  - Toggle open / closed / focused / unfocused.
  - Submit single-line, multi-line, with/without Shift+Return inversion.
  - Claude Code detection: open `claude`, confirm `/` `@` `?` routing.
  - IME: open Kotoeri (JA) input AND Pinyin (ZH) input; type into TextBox.
  - Drag-drop: files from Finder, across all four drop targets.
  - Multi-tab `.all` scope toggle.
  - Close-other-tabs shortcut (`Cmd+Option+T`) still works — regression check for the shortcut collision.
  - VoiceOver: enable, navigate to TextBox, attempt to compose and submit. Report whether this works or not; if broken, file a follow-up ticket — do not block on it unless a11y is a merge blocker per §8 Q10.
- **Typing-latency measurement**: capture p95 keystroke-to-paint latency via the debug log with TextBox disabled (baseline) and with TextBox visible-but-unfocused (comparison). Record numbers in the PR description. Numeric pass criterion goes in §8 Q6.
- Push PR; let build-only PR CI run.

### Phase 9 — PR
- Merge via PR with the feature gated off by default (users opt in via settings).
- Note in PR description: two-commit regression-test pattern does not apply (this is a feature port, not a bug fix).

---

## 7. Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Drag-routing regression in `ContentView.swift` | Medium-High | Lifecycle is 5+ entry points, not 1 (see §4.9). Read c11's current `draggingEntered`/`draggingUpdated`/`prepareForDragOperation`/`performDragOperation`/`concludeDragOperation` end-to-end before inserting. Manual test every existing drop target (web, browser, terminal, TextBox). Consider unifying the `activeDragWebView` state machine into an `activeDragTarget` enum. |
| Focus-handling race with c11's workspace restore | Medium | `toggleTextBoxMode` uses `DispatchQueue.main.async`; verify no re-entry during workspace switch. **Grep every `makeFirstResponder(surfaceView)` call site** and guard each with `if firstResponder is InputTextView { return }` — c11 has focus-restore paths that did not exist in upstream (`scheduleAutomaticFirstResponderApply`, `reassertTerminalSurfaceFocus`). |
| Ghostty `scroll_to_row` unsupported | Resolved | Verified present in c11's submodule at `src/input/Binding.zig:427`. |
| `Cmd+Option+T` collision | **Active** | `Cmd+Option+T` IS bound in `AppDelegate.swift:9498` to close-other-tabs (hardcoded, not in `KeyboardShortcutSettings`). Mitigation: use `Cmd+Option+B` as documented in §4.5 — matches fork author's own stated preference. |
| `GhosttyApp.defaultForegroundColor` missing | **Active** | Symbol does not exist in c11. Add it in Phase 3 (see §4.8). Without this, Phase 4 fails to compile. |
| Missing title-sync hook in `Workspace.updatePanelTitle` | **Active** | Without `terminalPanel.updateTitle(trimmed)`, the fork's Claude Code / Codex title-regex detection silently never fires. Add in Phase 5 (see §4.4). |
| Coordination with tier-1 persistence plan | Medium | `docs/c11-tier1-persistence-plan.md` (in-flight) also touches per-panel state. `isTextBoxActive` and `textBoxContent` are candidates for future persistence. Sync with the tier-1 author before both land on `main`. |
| `defaultEnabled = true` surprises users | Low | Flip to `false`; feature is opt-in. |
| Typing-latency regression from TextBox observers | Low | No additions to `forceRefresh()` / `hitTest()` / `TabItemView`. **Define a numeric pass criterion in §8 Q6** (e.g. p95 keystroke-to-paint delta < X ms with TextBox disabled vs. a known baseline). "Eyeball the debug log" is not a pass criterion. |
| IME bugs in `InputTextView` | Low | Fork already skips text sync during `hasMarkedText()`; validate manually with Kotoeri (JA) and Pinyin (ZH) during Phase 8. |
| VoiceOver / accessibility regression | Unknown | Custom `NSTextView` subclass intercepting `keyDown` + custom `draw(_:)` can break VoiceOver. No fork validation exists. Flag as open question (§8). |
| Sparkle update overwrites feature | N/A | We explicitly do not port the fork's `SUFeedURL` change; c11's appcast stays. |
| Nondeterministic 200ms paste+Return delay | Low–Medium | Fork's empirical 200ms is calibrated for zsh + Claude CLI on a warm machine. Unverified for SSH, heavy CPU load, `codex`, `docker exec`, tmux-in-Ghostty. Making the constant configurable is cheap future-proofing. |
| PR size | Medium | **Single PR** (user decision 2026-04-18) with the 9-phase commit history preserved inside it. Feature ships as one logical unit. |

---

## 8. Open questions

Grouped by reversibility cost. Answered items reflect user decisions 2026-04-18 (after Trident review).

### Locked before Phase 1

1. ~~Rename from `TextBoxInput` → `ComposeSurface`?~~ **Decided: keep `TextBoxInput`.** Rationale: "compose surface" is more abstract than the feature is. Rename is reversible at modest cost (UserDefaults migration if we ever want it) — not worth the naming debate now.

2. **Default enabled state: `false`.** Decided — opt-in via settings.

3. **Default shortcut: `Cmd+Option+B`.** Decided.

4. **Agent detection: metadata-first with title-regex fallback.** Decided (user open to recommendation). Wire `TextBoxAppDetection` to read `SurfaceMetadataStore.terminalType` first and fall back to the fork's title regex if metadata is unset. ~10 LOC swap; unanimous reviewer recommendation; exploits c11's existing `AgentDetector` (process-based) infrastructure from M1/M2.

5. **Settings count: ship all 4.** Decided (user open to recommendation). Matches fork, already localized in both EN and JA, marginal cost. If any prove unused we can trim later.

6. **PR split: single PR.** Decided. All phases land as one logical feature; single PR with the 9-phase commit history inside it.

### Must decide before Phase 4 (affects integration)

7. **`defaultForegroundColor` source.** Add to `GhosttyApp` (mirrors existing `defaultBackgroundColor`), or read `GhosttyConfig.foregroundColor` inline? **Recommend**: add to `GhosttyApp`.

8. **Drag routing integration model.** Slot TextBox check into existing `activeDragWebView` state machine (minimal), or generalize to `activeDragTarget` enum (cleaner, reduces future drift)? Pick before Phase 6.

9. **`.all` scope semantics.** All panels in the current workspace, current window, or every panel across every window? Fork does one workspace. **Recommend**: current workspace.

### Validation criteria (locked)

10. **Typing-latency numeric pass criterion: ≤1ms p95 keystroke-to-paint delta** with TextBox visible-but-unfocused vs. TextBox-disabled baseline, measured via the debug event log on the user's primary machine. Typing must stay snappy — this is the hard floor. If we can't meet this, don't ship.

11. **VoiceOver / accessibility.** Not a merge blocker. Ship and file a follow-up if users hit issues.

12. **IME coverage.** Japanese (Kotoeri) mandatory. Chinese (Pinyin) and Korean also in Phase 8, or follow-up?

### Deferrable (can answer now or later)

13. **200ms paste+Return delay configurability.** Ship hardcoded (fork default), ship configurable (new setting), or ship hardcoded + a log line so we can tune based on field data? Reviewers flagged this as a fragility under SSH / slow PTYs.

14. **Rollback / kill switch.** Plan ships "default off" as the rollback. Do we want a more explicit runtime kill switch that disables the key-routing logic while keeping the UI mounted, for fast mitigation if a regression ships?

15. **Persistence of TextBox content.** Fork is transient. c11 has richer session restore + the in-flight tier-1 persistence plan. Save draft text per surface via `SurfaceMetadataStore`, or leave transient? **Recommend**: transient for v1, file follow-up.

16. **Translation breadth.** EN + JA ship (matches fork + policy). For the other 16 locales, leave untranslated (fall back to EN — matches current c11 pattern) or batch-translate now?

17. **Showcase assets.** Port `docs/assets/textbox-*.{gif,mp4,png}` for c11's own docs/README?

18. **Module numbering / branch name.** M9? Something else? Branch slug: `m9-textbox-input` or `m9-compose-surface` (depends on Q1)?

19. **Upstream contribution.** After it bakes, contribute back to `manaflow-ai/cmux`? Affects commit hygiene (cherry-pickability) and file organization.

20. **Fork-author provenance.** Was this feature offered upstream to manaflow-ai/cmux and rejected, or never offered? Low stakes for this port but worth knowing.

### Explicitly pushed back (not blockers)

- **Multimodal / `NSTextAttachment` future-proofing** (evolutionary reviewers want `InputTextView` designed to accept attachments from day one). Agreed for follow-up; not blocking this port.
- **Cross-pane broadcast, agent socket handshake, context pins, pre-flight inspection, composition-surface-as-canvas** — all evolutionary mutations. Out of scope for v1. File as follow-up tickets.

---

## 9. Acceptance criteria

- Feature is off by default; enabling it via Settings makes the TextBox appear below every terminal pane.
- `Cmd+Option+B` toggles TextBox according to the configured behavior. `Cmd+Option+T` still closes other tabs in the focused pane (regression check).
- Submission sends text via bracket-paste with a delayed `Return`; works in zsh, `claude`, and `codex`.
- Drag-dropping a file onto the TextBox inserts a shell-escaped path; `+` badge shows during hover; dropping on web/browser/terminal panes preserves existing behavior.
- Settings (however many ship per §8 Q5) persist across app restart.
- IME composition works (Japanese — required; Chinese / Korean per §8 Q12).
- `TextBoxInputTests.swift` passes in c11's test target.
- Typing latency meets the numeric pass criterion defined in §8 Q10. Recorded baseline + comparison in PR description.
- Tagged Debug build (`./scripts/reload.sh --tag m9-textbox`) launches cleanly.
- Japanese translations land in the same PR (per policy); remaining locales fall back to English per c11 convention.

## 10. Review traceability

This v2 was produced after a Trident plan review. The full review pack is at `docs/c11mux-textbox-port-plan-review-pack-2026-04-18T1255/` (8 individual reviews + 3 synthesis documents; `standard-gemini.md` unavailable due to API capacity).

Applied from the review synthesis:

- **Shortcut correction** (consensus across all three adversarial reviews + Standard-Claude + Standard-Codex): `Cmd+Option+T` → `Cmd+Option+B`.
- **`defaultForegroundColor` symbol** (unique to Evolutionary-Claude + Standard-Codex): added to Phase 3.
- **Title-sync hook** (unique to Standard-Claude): added to §4.4 + Phase 5.
- **Drag lifecycle expansion** (consensus): §4.9 rewritten; Phase 6 expanded.
- **Japanese translations** (consensus): §4.10 rewritten; Phase 7 updated; acceptance criteria updated.
- **`[cmux-tb]` tag stripping** (Evolutionary-Claude): §4.1 + §5.
- **Two-commit regression-test clarification** (Standard-Claude): §4.1.
- **Focus guard enumeration** (Standard-Claude + Adversarial-Claude): §4.8 + Phase 3.
- **Tier-1 persistence coordination** (Adversarial-Claude): risk register.
- **Typing-latency pass criterion** (consensus): §8 Q10 + acceptance criteria.
- **PR split recommendation** (consensus): risk register + Phase 3 split marker.

Deferred to §8 open questions (not applied because they are genuine decisions, not factual corrections):

- Rename to `ComposeSurface` (§8 Q1).
- Wire to `AgentDetector` / `SurfaceMetadataStore` (§8 Q4).
- Number of settings (§8 Q5).
- 200ms delay configurability (§8 Q13).
- Runtime kill switch beyond "default off" (§8 Q14).
- VoiceOver merge-blocker status (§8 Q11).
- `.all` scope semantics across windows (§8 Q9).
- Multimodal / attachment design (evolutionary, explicitly out of scope for v1).

Not applied (judged as out of scope or challenge to the project's premise, which is above this plan's pay grade):

- Adversarial challenge to the "AI-agent workflow" justification vs. existing `cmux send` primitive.
- Argument to reimplement 20% of the feature instead of porting 100%.
- Demand for telemetry / usage data / deprecation criteria before shipping.
- Architectural argument for a floating workspace-level palette instead of per-pane containers (Gemini).

These are legitimate challenges but outside the scope of "port the feature." If the user wants to challenge the premise, that's a separate conversation before Phase 0.
