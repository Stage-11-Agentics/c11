# Action-Ready Synthesis: flash-tab

## Verdict
fix-then-merge

The 9 reviews split into two camps. Standard-claude, standard-codex, standard-gemini, evolutionary-{claude,codex,gemini}, and critical-{claude,codex} all read the change as small, well-shaped, and effectively merge-ready or merge-after-cleanup. Critical-gemini disagrees sharply: it asserts that channel (c) — the sidebar workspace pulse — is functionally **dead**, because the SwiftUI subscription topology cannot deliver `tab.sidebarFlashToken` updates to the threaded `let` parameter the row uses. That claim is the blocker. The critical-gemini reasoning matches a real SwiftUI gotcha (no observer of individual `Workspace`s exists in `VerticalTabsSidebar`; `@ObservedObject var tab` in the child only invalidates the child's body, it does not re-construct the struct, so the captured `let sidebarFlashToken` cannot refresh). The standard reviewers concluded the channel works by code inspection only — none of them ran the binary against this code path, and the smoke test mentioned in the context document only verified that `surface.trigger_flash` returns `OK`, not that the sidebar pulse renders.

Bias toward the more cautious verdict: the sidebar-channel observation question has to be settled by a real visual smoke test (or runtime probe) before merge. If the channel is in fact dead, the fix is small (subscribe to the published value, not the threaded `let`); if it works, the rest of this synthesis still has a real settings-copy contract bug and a small overflow bug that should land in the same PR.

## Apply by default

### Blockers (merge-blocking)

- **B1: Sidebar flash channel may never fire — `.onChange(of: sidebarFlashToken)` watches a stale `let`**
  - Location: `Sources/ContentView.swift:8489` (parent threading) and `Sources/ContentView.swift:11512-11522` (child `.onChange`)
  - Problem: `VerticalTabsSidebar` has no `@ObservedObject` / `@EnvironmentObject` on individual `Workspace`s, so `Workspace.sidebarFlashToken` publishing does not re-evaluate the parent body. The child `TabItemView` has `@ObservedObject var tab: Tab`, which invalidates the child's body when `tab` publishes — but the child's `let sidebarFlashToken: Int` is captured at parent-construction time and is not refreshed by child-only re-renders. `.onChange(of:)` on a captured `let` only fires when the parent re-passes a new value; with `Equatable`-gated reconstruction and no parent-side observer of the workspace, it likely never does. Critical-gemini reports verifying this with a SwiftUI test harness mimicking the same topology. The standard reviewers asserted the channel works but did so only by reading code, not by running it.
  - Fix: First, **verify** by adding a temporary `dlog("sidebar flash onchange fired for ws=…")` inside the `.onChange` and triggering a flash via `c11 trigger-flash`. If the log fires, the implementation is fine and B1 collapses to "no change needed; keep this comment for future maintainers." If it does **not** fire, change the subscription to read the published value directly: replace `.onChange(of: sidebarFlashToken) { _, newValue in … }` with `.onReceive(tab.$sidebarFlashToken) { newValue in … }`, OR change the `.onChange` source to `tab.sidebarFlashToken` so SwiftUI subscribes to the publisher rather than the captured `let`. Both fixes preserve the typing-latency invariant because they don't add a new property to the `==` comparator (the `let sidebarFlashToken` and its inclusion in `==` can stay as defense-in-depth, or be removed once the publisher subscription is the source of truth). After the fix, smoke-test by triggering a flash on a non-active workspace and confirming the row pulses.
  - Sources: critical-gemini (Blocker 1, with claimed runtime verification). Standard-claude, standard-codex, standard-gemini, critical-claude, critical-codex all asserted the channel works but **none ran the channel**; their confidence is inspection-only, so it does not override critical-gemini's runtime claim.

- **B2: Settings copy lies about what the "Pane Flash" toggle does**
  - Location: `Sources/c11App.swift:5683-5684`
  - Problem: The user-facing toggle still describes itself as "Briefly flash a blue outline when c11 highlights a pane." The implementation in `Sources/Workspace.swift:8811-8817` now uses that same setting to gate all three channels (pane ring, Bonsplit tab pulse, sidebar workspace row pulse). A user who reads the description and toggles it expecting only the pane-outline behavior is silently controlling two additional visual channels they have no idea exist.
  - Fix: Update the English `defaultValue:` in the `String(localized:)` for that setting description to reflect the new scope — something like "Briefly flash the pane, its tab, and its workspace row when c11 highlights a pane." Per `CLAUDE.md` Localization: write English only; spawn a translator sub-agent in a fresh c11 surface to update `Resources/Localizable.xcstrings` for the six other locales. Optionally rename the setting key from "Pane Flash" to "Highlight Flash" or similar; if you do, plumb a settings migration so existing users keep their toggle state.
  - Sources: critical-codex (Important #1, confirmed with file:line).

### Important (land in same PR)

- **I1: `newValue > 0` guard in Bonsplit `TabItemView` permanently disables tab flash on Int wrap**
  - Location: `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift:236-241`
  - Problem: `pane.flashTabGeneration &+= 1` wraps `Int.max` to `Int.min` (negative). The guard `guard newValue > 0, newValue != lastObservedFlashGeneration else { return }` fails forever after that wrap, silently bricking channel (b) for the rest of the session. Practically unreachable (9 quintillion flashes), but it's an inconsistency with the c11 sidebar's `!=`-only check and the kind of footgun a future maintainer copy-pastes. The `> 0` is also redundant: the parent's per-tab ternary `(pane.flashTabId == tab.id) ? pane.flashTabGeneration : 0` already guarantees siblings see 0, and `.onChange` doesn't fire on a 0→0 transition anyway.
  - Fix: Drop the `newValue > 0` half of the guard. Final line: `guard newValue != lastObservedFlashGeneration else { return }`. Commit in the bonsplit submodule first, push to `Stage-11-Agentics/bonsplit` `main`, then bump the parent pointer per `CLAUDE.md` submodule-safety order.
  - Sources: critical-claude (W3, confirmed), critical-gemini (Important #3, confirmed). Multi-reviewer consensus.

- **I2: Add debug counters for tab/sidebar channels and extend `tests_v2/test_trigger_flash.py`**
  - Location: new — extend the existing `debug.flash.count` socket command and add to `tests_v2/test_trigger_flash.py`
  - Problem: Channels (b) and (c) have no observable runtime counter. `tests_v2/test_trigger_flash.py` only asserts `flash_count` for the pane channel via `GhosttyTerminalView`. A future refactor that accidentally drops the bonsplit fan-out or the sidebar token bump would not be caught — and given B1 is a concrete instance of "channel silently doesn't fire," runtime coverage is exactly the missing piece.
  - Fix: Add two counters analogous to the existing `flash.count`: `debug.flash.tab_count` (incremented inside `BonsplitController.flashTab` or in `Workspace.triggerFocusFlash` after the bonsplit call) and `debug.flash.sidebar_count` (incremented at the `sidebarFlashToken &+= 1` line). Expose via the existing debug socket command pattern. Extend `tests_v2/test_trigger_flash.py` to assert all three counters increment when `surface.trigger_flash` fires, and assert all three stay at 0 when `notificationPaneFlashEnabled = false`. ~30 lines of code; follows `CLAUDE.md` "Test quality policy" because it tests observable runtime behavior, not source text.
  - Sources: critical-claude (M1, M4, recommended ship-blocker), critical-codex (What's Missing #1), evolutionary-codex (High Value #2), evolutionary-claude (Leverage Point #2). Multi-lens consensus.

### Straightforward mediums

- **M1: `surfaceIdFromPanelId` is O(n) and now on the flash hot path**
  - Location: `Sources/Workspace.swift:5793-5795`
  - Problem: The function is a linear scan: `surfaceIdToPanelId.first { $0.value == panelId }?.key`. Every flash now pays this cost (including the v2 socket `surface.trigger_flash` path, which already has the `surfaceId` in scope at `TerminalController.swift:6967`). Negligible for small workspaces, but unnecessary work that compounds with notification volume.
  - Fix: Either (a) maintain a reverse-lookup dict alongside `surfaceIdToPanelId` and update both on insert/remove, or (b) overload `triggerFocusFlash` to accept an optional `tabId` and have the v2 socket caller pass it directly, falling back to the lookup only for callers that don't have it. Option (b) is smaller and avoids a second source of truth.
  - Sources: critical-claude (W2, confirmed), standard-claude (#4, lower priority).

- **M2: `static var segments` recomputed on every read**
  - Location: `Sources/Panels/Panel.swift:74-86` (`SidebarFlashPattern.segments`); `Sources/Panels/Panel.swift:55-67` (existing `FocusFlashPattern.segments`); `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift:42-55` (`TabFlashPattern.segments`)
  - Problem: `static var segments: [FocusFlashSegment] { … }` is a computed property — each access re-runs `min(...)` and `(0..<stepCount).map { … }`, allocating a fresh array. The arrays are constants and never depend on input, so each access on the animation hot path allocates and maps unnecessarily.
  - Fix: Change `static var segments: [Type] { … }` to `static let segments: [Type] = { … }()` (immediately-invoked closure assigned to a `static let`) in all three pattern enums. The arrays are computed once at first access and cached. No behavior change. Apply consistently across `FocusFlashPattern`, `SidebarFlashPattern`, and `TabFlashPattern`.
  - Sources: critical-gemini (Potential #4, confirmed). Single reviewer but the citation is concrete and the fix is mechanical — `static var` of a pure expression is a verifiable Swift wart, not a subjective preference.

### Evolutionary clear wins

(none — every evolutionary item involves either a rename of a public API surface, a new abstraction, or a scope expansion that the user should weigh; nothing here is small-and-obvious enough to apply silently)

## Surface to user (do not apply silently)

- **S1: Notification fan-out scope is a unilateral product expansion**
  - Why deferred: design-needed
  - Summary: `triggerNotificationFocusFlash` (called from terminal notification routing in `TabManager.swift:2982,2995,3175` and `AppDelegate.swift:2760` — i.e., agent-finish notifications, Zulip-style pings) previously fired only the pane ring. After this PR it fans out through `triggerFocusFlash` to all three channels including the sidebar workspace row. Critical-claude flags this as a real product question: "polite peak 0.18 opacity" is calibrated for ambient signal, but with 8-12 active workspaces and many agents firing notifications, the operator may experience a sidebar that twitches several times per minute. The implementer made the call unilaterally without flagging the tradeoff. Possible answers: (a) accept the expansion as intended (and validate under realistic notification load), (b) bypass channel (c) for `triggerNotificationFocusFlash` callers — keep notification flashes pane-only, reserve the three-channel fan-out for explicit user-action paths (keyboard shortcut, right-click, v2 socket).
  - Sources: critical-claude (W1, the headline concern of that review), standard-claude (#3, related but framed only as "operator should eyeball during validation"), evolutionary-{claude,codex} both lean into the multi-channel future without flagging the calibration question.

- **S2: `NotificationPaneFlashSettings` toggle silences flashes but still allows focus-stealing**
  - Why deferred: pre-existing behavior, scope question
  - Summary: `triggerNotificationFocusFlash` calls `focusPanel(panelId)` before the gate check; an operator who toggles "Pane Flash" off expecting "stop yanking my focus on notifications" will be surprised. Pre-existing, not introduced by this PR. The new fan-out makes the setting more visible and more likely to get revisited, which is why critical-claude flagged it now. Either document the actual scope of the toggle in the description (paired naturally with B2's copy update), or split into two toggles ("flash" and "focus-on-notification"). The latter is design-needed.
  - Sources: critical-claude (W7, confirmed pre-existing).

- **S3: Sidebar overlay sits on top of the active-row leading rail**
  - Why deferred: visual subjective
  - Summary: At `Sources/ContentView.swift:11494-11520`, the flash overlay is appended after the leading-rail overlay. When the active workspace's row receives a flash, the accent fill briefly tints the rail. Peak 0.18 opacity makes this minor; whether it muddles the active-state signal or reads as a coherent unified pulse is an operator visual call. Easy to fix (reorder overlays so the rail sits on top of the flash) but requires the operator to actually look and decide.
  - Sources: critical-claude (W4, marked as visual nit).

- **S4: Stale `panelId` produces a sidebar pulse with no pane/tab flash**
  - Why deferred: defensive-vs-strict design choice
  - Summary: `triggerFocusFlash` currently does `panels[panelId]?.triggerFlash()` (optional), then `bonsplitController.flashTab(tabId)` if `surfaceIdFromPanelId(panelId)` returns non-nil, then unconditionally `sidebarFlashToken &+= 1`. If a stale or invalid `panelId` is passed, only the sidebar pulses. Today's callers all pass valid IDs, so this is not a present bug. Two reasonable fixes diverge: (a) `guard let panel = panels[panelId] else { return }` and bail entirely — strict, breaks future "draw attention to a workspace" use cases; (b) keep current behavior, document that workspace-level flash without a panel is allowed. Critical-codex prefers (a); evolutionary-{claude,codex} are pulling toward an "attention bus" that benefits from (b). User should decide direction.
  - Sources: standard-codex (Important #1), critical-codex (Potential #1).

- **S5: Bonsplit `TabItemView` is not `Equatable` — siblings re-evaluate body on every flash**
  - Why deferred: scope, upstream-friendliness tradeoff
  - Summary: c11's sidebar `TabItemView` is meticulously `Equatable` for typing-latency; Bonsplit's per-pane `TabItemView` is not. Every flash invalidates the parent and re-evaluates all sibling tabs' bodies, even though siblings receive `flashGeneration: 0` and don't animate. Negligible at current per-pane tab counts (1-15). Adding `Equatable` to Bonsplit's `TabItemView` would be a real architectural improvement, but it's also a bigger change to a vendored fork that may be PR'd upstream — worth a separate decision rather than rolled in here.
  - Sources: critical-claude (W5, confirmed).

- **S6: Lazy-mounted sidebar rows lose flashes that fire while scrolled out of view**
  - Why deferred: design-needed, follow-up
  - Summary: `LazyVStack` defers row creation; if a flash fires for a workspace whose row hasn't been materialized, the token bumps but no `.onChange` observer exists. When the operator scrolls the row in, `lastObservedSidebarFlashToken` initializes to 0 and the flash never replays. This is probably the right behavior (no point replaying a 5-second-old pulse on scroll-in), but it means the sidebar pulse is "best-effort, observable-while-mounted," not a reliable "this workspace had something happen" indicator. The proper mitigation is a separate "has unseen flash" sticky badge that decays, which is out of scope here. File as a follow-up.
  - Sources: critical-claude (W6, confirmed).

- **S7: Plan §9 verification checklist boxes left unchecked**
  - Why deferred: doc hygiene only
  - Summary: `notes/flash-extension-plan.md` §9 has three unchecked boxes (`NotificationPaneFlashSettings.isEnabled()` confirmed, `appearance.activeIndicatorColor` confirmed, sidebar row corner-radius confirmed). Critical-claude verified that all three were resolved correctly in the implementation, so the checklist is misleading documentation. Either tick the boxes or strike the section before merging. User should decide whether to keep `flash-extension-plan.md` as a checked-off historical artifact or trim it.
  - Sources: critical-claude (M6, confirmed).

## Evolutionary worth considering (do not apply silently)

- **E1: Name the attention bus before more callers script against `surface.trigger_flash`**
  - Summary: All three evolutionary reviewers independently arrived at the same observation — `Workspace.triggerFocusFlash(panelId:)` has stopped being a "pane flash" method and started being a workspace-scope attention dispatch. Naming it now (`drawAttention(panelId:intensity:layers:)` or similar) before agents start scripting against the v2 socket name `surface.trigger_flash` is cheaper than later. The current call becomes the `.normal` / `[.pane, .tab, .sidebar]` case; future calls (`agent_finished` ambient, `build_failed` urgent) compose through layer/intensity policy instead of adding bespoke methods.
  - Why worth a look: the rename cost is small now and grows fast; the underlying primitive opens per-channel toggles, agent-emitted attention requests over the socket, and a future per-workspace mute/route policy.
  - Sources: evolutionary-claude (#2 + Concrete #2), evolutionary-codex (Strategic #3), evolutionary-gemini (How This Could Evolve #1).

- **E2: Extract a shared SwiftUI generation-token pulse runner**
  - Summary: The same `reset opacity → for-segment-in-pattern asyncAfter → guard generation/token → withAnimation` shape now exists in four places: `MarkdownPanelView.triggerFocusFlashAnimation`, `BrowserPanelView.triggerFocusFlashAnimation`, the new `runSidebarFlashAnimation` in `ContentView.swift`, and Bonsplit's `runFlashAnimation` in `TabItemView.swift`. A small `@MainActor` helper in `Sources/Panels/Panel.swift` would collapse the c11-side three to one (Bonsplit keeps its own copy for module isolation). Future flash channels add in 5 lines instead of 30.
  - Why worth a look: removes duplication, lowers the cost of the next attention channel, and centralizes the timing-bug surface; downside is it's a refactor of working code with no behavior change, so the timing for "now" vs "after the next channel forces it" is a judgment call.
  - Sources: evolutionary-claude (Concrete #1), evolutionary-codex (Concrete #1), evolutionary-gemini (Concrete #1), standard-claude (#5). Multi-lens consensus on the observation; user should decide on the timing.

- **E3: Add `lastFlashedAt: Date?` next to `sidebarFlashToken`**
  - Summary: One extra `@Published` property on `Workspace`. Unlocks several future capabilities cheaply: a sidebar decay overlay (faint residue showing "this workspace flashed recently"), a "what flashed while I was at lunch" recap, per-workspace mute by recency, and a debug attention audit log. All optional; the field itself costs essentially nothing and doesn't change current behavior.
  - Why worth a look: it's a one-line change with disproportionate optionality for the attention-bus direction (E1) without committing to that direction yet.
  - Sources: evolutionary-claude (Concrete #3, How This Could Evolve #3).
