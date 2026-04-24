# C11-15 Implementation Plan
## Reorder first-launch onboarding: TCC primer before initial shell spawn

---

## Key Architectural Insight

The ticket description says the change lives in `sendWelcomeCommandWhenReady` (AppDelegate.swift:6202–6218). That is where the chained primer calls live today, but **the real gate is earlier**: the shell spawns inside `Workspace.init()`, which is called from `addWorkspace`, which is called from `openWelcomeWorkspace` — all *before* `sendWelcomeCommandWhenReady` is ever invoked.

Sequence today:
```
openWelcomeWorkspace()
  → addWorkspace(autoWelcomeIfNeeded: false)
      → Workspace.init()          ← TerminalPanel created here (Workspace.swift:5426)
      → tabs = updatedTabs        ← SwiftUI re-renders on next runloop tick
                                      → GhosttyTerminalView added to window
                                          → PTY created, shell spawned
                                              → rc files execute → TCC prompts fire
  → sendWelcomeCommandWhenReady(to: workspace)
      → runWhenInitialTerminalReady { initialPanel in
            performQuadLayout           ← shell already running by here
            asyncAfter(1.2s) {
                AgentSkills → TCC primer  ← primer appears AFTER prompts
            }
        }
```

The only reliable way to ensure the primer appears before any shell activity is to defer `addWorkspace` (and therefore `Workspace.init()`) until after primer dismissal.

**Two sites need changes:** `openWelcomeWorkspace` (the key architectural change) and `sendWelcomeCommandWhenReady` (simplified).

---

## 1. Changes to `openWelcomeWorkspace` (AppDelegate.swift ~line 6190)

Restructure so workspace creation is deferred into a completion chain.

**Current:**
```swift
func openWelcomeWorkspace() {
    guard let context = preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: "welcome") else { return }
    if let window = context.window ?? windowForMainWindowId(context.windowId) {
        setActiveMainWindow(window)
        bringToFront(window)
    }
    let workspace = context.tabManager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
    sendWelcomeCommandWhenReady(to: workspace)
}
```

**New:**
```swift
func openWelcomeWorkspace() {
    guard let context = preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: "welcome") else { return }
    if let window = context.window ?? windowForMainWindowId(context.windowId) {
        setActiveMainWindow(window)
        bringToFront(window)
    }
    // Present primer first if needed; workspace is created only in the completion.
    if TCCPrimer.shouldPresent() {
        presentTCCPrimer { [weak self] in
            guard let self else { return }
            if AgentSkillsOnboarding.shouldPresent() {
                self.presentAgentSkillsOnboarding { [weak self] in
                    self?.continueWelcomeWorkspaceSetup(context: context)
                }
            } else {
                self.continueWelcomeWorkspaceSetup(context: context)
            }
        }
    } else if AgentSkillsOnboarding.shouldPresent() {
        presentAgentSkillsOnboarding { [weak self] in
            self?.continueWelcomeWorkspaceSetup(context: context)
        }
    } else {
        continueWelcomeWorkspaceSetup(context: context)
    }
}

private func continueWelcomeWorkspaceSetup(context: WindowCreationContext) {
    // Context was captured when openWelcomeWorkspace ran; guard that the
    // target window is still alive (user may have closed it during primer).
    guard context.tabManager.isValid else { return }
    let workspace = context.tabManager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
    sendWelcomeCommandWhenReady(to: workspace)
}
```

`WindowCreationContext` (or whatever the return type of `preferredMainWindowContextForWorkspaceCreation` is — check the actual type) is captured by value at call time. If the user dismisses the primer after the window is closed, `context.tabManager.isValid` or a nil-check on the tab manager prevents a stale workspace from being created. Add whatever guard fits the existing `context` type.

Note: `bringToFront(window)` still happens before the primer so the c11 window is behind the primer sheet, not hidden.

---

## 2. Changes to `sendWelcomeCommandWhenReady` (AppDelegate.swift:6202–6218)

By the time this function is called from `continueWelcomeWorkspaceSetup`, both the primer and AgentSkills have already presented and dismissed. Remove the 1.2s delay and the entire if/else primer-chain.

**Current:**
```swift
func sendWelcomeCommandWhenReady(to workspace: Workspace, markShownOnSend: Bool = false) {
    runWhenInitialTerminalReady(in: workspace) { [weak self] initialPanel in
        if markShownOnSend {
            UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
        }
        WelcomeSettings.performQuadLayout(on: workspace, initialPanel: initialPanel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let self else { return }
            if AgentSkillsOnboarding.shouldPresent() {
                self.presentAgentSkillsOnboarding()
            } else {
                self.presentTCCPrimerIfNeeded()
            }
        }
    }
}
```

**New:**
```swift
func sendWelcomeCommandWhenReady(to workspace: Workspace, markShownOnSend: Bool = false) {
    runWhenInitialTerminalReady(in: workspace) { initialPanel in
        if markShownOnSend {
            UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
        }
        WelcomeSettings.performQuadLayout(on: workspace, initialPanel: initialPanel)
    }
}
```

The `DispatchQueue.main.asyncAfter` block with `presentAgentSkillsOnboarding` / `presentTCCPrimerIfNeeded` is fully removed. The `[weak self]` capture is no longer needed.

> **Note on the `autoWelcomeIfNeeded` path:** `TabManager.addWorkspace` also calls `sendWelcomeCommandWhenReady(to:, markShownOnSend: true)` when `autoWelcomeIfNeeded: true` and `WelcomeSettings.shownKey` is not yet set (TabManager.swift:1211–1213). After this change, that path will also omit the chained onboarding sheets. That is correct: any workspace created via that path is not the first-launch welcome flow, so it shouldn't trigger onboarding panels.

---

## 3. AgentSkills + TCC Primer Sequencing

**Old order:** AgentSkills → TCC primer (chained via `willClose` observer in `presentAgentSkillsOnboarding`)

**New order:** TCC primer → AgentSkills → workspace creation

Rationale: the primer is the time-critical piece — it must appear before the shell spawns. AgentSkills is informational (install skill files) and has no relationship to the TCC prompt cascade. Placing the primer first ensures the user understands what's about to happen (TCC permission prompts) before anything triggers them. The new call site in `openWelcomeWorkspace` enforces this order explicitly rather than relying on a `willClose` chain.

---

## 4. `presentTCCPrimer` and `presentAgentSkillsOnboarding` — Completion Callbacks

Both functions need an optional `onCompletion` parameter. The `willClose` observer fires the callback after cleanup.

**`presentTCCPrimer` signature change** (AppDelegate.swift ~line 6304):
```swift
// Before:
func presentTCCPrimer()

// After:
func presentTCCPrimer(onCompletion: (() -> Void)? = nil)
```

In the `willClose` observer body (currently lines 6337–6345), after the cleanup (nil-out window, remove observer), add:
```swift
onCompletion?()
```

The completion fires on both "Continue without it" (closes window via SwiftUI) and the red close button (triggers willClose directly). The "Grant Full Disk Access" button marks shown + opens Settings but does NOT close the window — completion fires only when the user manually closes the primer after returning from Settings (follow-up ticket adds auto-close on FDA grant).

**`presentAgentSkillsOnboarding` signature change** (AppDelegate.swift ~line 6240):
```swift
// Before:
func presentAgentSkillsOnboarding()

// After:
func presentAgentSkillsOnboarding(onCompletion: (() -> Void)? = nil)
```

In the `willClose` observer body (currently lines 6271–6284), after cleanup and `markDismissedThisLaunch()`, remove the existing `presentTCCPrimerIfNeeded()` call (that chain no longer applies) and add:
```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
    onCompletion?()
}
```

Keep the 0.35s delay that was already there for close-animation smoothness.

The existing `presentAgentSkillsOnboardingIfNeeded()` and `presentTCCPrimerIfNeeded()` helper functions remain unchanged (still used by other call sites if any).

---

## 5. Changes to `TCCPrimerSheet` (TCCPrimerView.swift)

### Button layout

**Current footer (lines 138–162):**
```
[secondary: "Open Privacy & Security"]  [primary: "Got it"]
```

**New footer:**
```
[secondary: "Continue without it"]  [primary: "Grant Full Disk Access"]
```

Primary is on the right (`.primary` kind) — "Grant Full Disk Access". Secondary is on the left — "Continue without it".

### Callback semantics

**Current callbacks:** `onGotIt`, `onOpenSettings`, `onDismiss`
**New callbacks:** `onGrantFDA`, `onContinueWithout`, `onDismiss`

Rename the parameters in `TCCPrimerSheet`:

```swift
struct TCCPrimerSheet: View {
    let onGrantFDA: () -> Void        // primary button: opens Settings, marks shown, stays open
    let onContinueWithout: () -> Void // secondary button: marks shown, closes window
    let onDismiss: () -> Void         // close button path (handled by willClose; this is a no-op safety fallback)

    init(
        onGrantFDA: @escaping () -> Void = {},
        onContinueWithout: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void = {}
    ) { ... }
}
```

In `presentTCCPrimer`, update the `TCCPrimerSheet` construction:
```swift
let rootView = TCCPrimerSheet(
    onGrantFDA: {
        UserDefaults.standard.set(true, forKey: TCCPrimer.shownKey)
        TCCPrimer.openFullDiskAccessPane()
        // Do NOT close window — follow-up ticket handles auto-close on FDA grant
    },
    onContinueWithout: { [weak window] in
        UserDefaults.standard.set(true, forKey: TCCPrimer.shownKey)
        window?.close()
    },
    onDismiss: { [weak window] in window?.close() }
)
```

### `TCCPrimerAction` enum

**Current:**
```swift
private enum TCCPrimerAction: CaseIterable {
    case openSettings
    case gotIt
    // allCases = [.openSettings, .gotIt] — keyboard default .gotIt
}
@State private var selectedAction: TCCPrimerAction = .gotIt
```

**New:**
```swift
private enum TCCPrimerAction: CaseIterable {
    case continueWithout
    case grantFDA
    // allCases = [.continueWithout, .grantFDA] — keyboard default .grantFDA
}
@State private var selectedAction: TCCPrimerAction = .grantFDA
```

Update `activateSelectedAction()` accordingly:
```swift
private func activateSelectedAction() {
    switch selectedAction {
    case .grantFDA:
        onGrantFDA()
    case .continueWithout:
        onContinueWithout()
    }
}
```

`moved(from:direction:)` logic is unchanged structurally; it navigates the `allCases` array regardless of case names.

### Copy refresh

The body copy must be refreshed to make FDA the recommended path. Specific wording is the implementor's call, but the key tone shift:

- **Old frame:** "Here's why you'll see prompts. FDA is an option if you don't want to click each one."
- **New frame:** "Grant Full Disk Access now to avoid the cascade. This is what iTerm2, Warp, and Ghostty recommend. Or continue without it and click each prompt individually."

The `tccPrimer.title` currently reads "macOS will ask about folders." — this is still accurate but could be updated to something like "Before your first shell opens." to signal that the user is acting before the fact, not after.

`tccPrimer.body.fullDisk` should move higher in the copy hierarchy or be reframed as the primary recommendation rather than a footnote.

---

## 6. Gate for Fresh Installs — `migrateExistingUserIfNeeded` Untouched

`TCCPrimer.migrateExistingUserIfNeeded` runs at line 2348 in `applicationDidFinishLaunching`, well before `openWelcomeWorkspace` is ever called. For any user who had previously completed the welcome workspace (`WelcomeSettings.shownKey = true`), this sets `TCCPrimer.shownKey = true`. When `openWelcomeWorkspace` later calls `TCCPrimer.shouldPresent()`, it returns false, and the primer is skipped entirely.

No changes to `migrateExistingUserIfNeeded`. The gate works correctly in the new ordering because the migration runs at launch init, before any workspace-creation paths.

For testing the new flow: reset with `defaults delete com.stage11.c11 cmuxTCCPrimerShown` (and also `cmuxWelcomeShown` if testing true fresh-install) on a tagged dev build.

---

## 7. Localization Strings

### Removed keys
- `tccPrimer.button.gotIt` — superseded by `tccPrimer.button.continueWithout`
- `tccPrimer.button.openSettings` — superseded by `tccPrimer.button.grantFDA`

Do not delete from xcstrings until translations land to keep the diff reviewable. Mark as `"state": "needs_review"` or simply replace the English defaultValue and let the translator pass regenerate all locales.

### New keys
- `tccPrimer.button.grantFDA` — English: `"Grant Full Disk Access"`
- `tccPrimer.button.continueWithout` — English: `"Continue without it"`

### Likely-changed keys (body copy refresh)
- `tccPrimer.title` — may change based on copy refresh
- `tccPrimer.body.why` — may change if framing shifts to proactive FDA recommendation
- `tccPrimer.body.fullDisk` — will change; FDA becomes the primary pitch, not a footnote

### Unchanged keys (expected to stay)
- `tccPrimer.windowTitle` — "c11 and macOS permissions" is still accurate
- `tccPrimer.body.whoAsks` — explains the "c11 wants to access…" dialog attribution; still relevant
- `tccPrimer.body.sayNo.lead` / `.tail` — still relevant for "Continue without it" path
- `tccPrimer.learnMore.title` / `.learnMore.body` — trigger taxonomy is unchanged

**Translator delegation:** After English lands, spawn one sub-agent per locale (6 parallel) covering: ja, uk, ko, zh-Hans, zh-Hant, ru. Each sub-agent reads the updated English values and writes the translated xcstrings entries for its locale.

---

## 8. Risk: Typing-Latency Hot Paths

Changed sites:
| Site | Type | Hot path? |
|------|------|-----------|
| `openWelcomeWorkspace` | Called once per welcome launch | No |
| `continueWelcomeWorkspaceSetup` | Called once, after primer dismissal | No |
| `sendWelcomeCommandWhenReady` | Called once per welcome workspace | No |
| `presentTCCPrimer` | Called once on first launch | No |
| `presentAgentSkillsOnboarding` | Called once on first launch | No |
| `TCCPrimerSheet` body | SwiftUI view shown once | No |
| `TCCPrimerAction` | Enum used only in TCCPrimerSheet | No |

None of these touch:
- `WindowTerminalHostView.hitTest()` — per-keystroke pointer/keyboard event routing
- `TabItemView` — uses `.equatable()` to skip re-evaluation during typing
- `TerminalSurface.forceRefresh()` — called on every keystroke

**Confirmed: no typing-latency risk from these changes.**

---

## 9. Build Verification

After implementation:

```bash
xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme c11 \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/c11-c11-15 \
  build
```

Manual smoke-test for acceptance criteria:

```bash
# Simulate fresh install:
defaults delete com.stage11.c11 cmuxTCCPrimerShown 2>/dev/null
defaults delete com.stage11.c11 cmuxWelcomeShown 2>/dev/null
defaults delete com.stage11.c11 agentSkillsOnboardingDismissed 2>/dev/null
# Then launch a tagged dev build (./scripts/reload.sh --tag c11-15)
```

Verify:
1. TCC primer appears BEFORE any terminal pane or shell activity
2. "Grant Full Disk Access" opens System Settings → Privacy & Security
3. "Continue without it" closes primer → welcome workspace assembles → quad layout appears
4. For existing users (run without clearing defaults): primer does NOT appear

---

## Summary of Key Design Decisions

1. **`openWelcomeWorkspace` is the real change site**, not just `sendWelcomeCommandWhenReady`. The shell spawns inside `Workspace.init()` (via `addWorkspace`), which happens before `sendWelcomeCommandWhenReady` is called. Deferring `addWorkspace` to a primer-completion callback is the only reliable gate.

2. **New ordering is TCC primer → AgentSkills → workspace**, reversing the current AgentSkills → TCC primer chain. The primer is time-critical (must precede shell spawn); AgentSkills is not.

3. **"Grant Full Disk Access" does not close the primer window** (for this ticket). The window stays open so the user can grant FDA in Settings and return. The primer closes when the user manually closes it; the `willClose` observer fires the completion that creates the workspace. The follow-up ticket adds FDA-grant auto-detection to close it automatically.
