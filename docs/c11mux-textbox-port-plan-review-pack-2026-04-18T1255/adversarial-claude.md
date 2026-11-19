# Adversarial Plan Review — c11mux TextBox Input Port

- **Plan ID:** c11mux-textbox-port-plan
- **Model:** Claude
- **Timestamp:** 2026-04-18 12:55
- **Role:** Designated adversary. Not balanced by design.

---

## Executive Summary

The plan reads as a well-organized mechanical port, but mechanical confidence is exactly the failure mode this plan is most likely to hit. The one-line in-file comment from the fork itself — "Default: Cmd+Opt+T (upstream cmux PR uses Cmd+Opt+B to avoid conflict with close-other-tabs)" — is load-bearing context that the plan missed. c11mux **already binds Cmd+Option+T to close-other-tabs-with-confirmation** at `Sources/AppDelegate.swift:9498`. This is not a Phase 5 implementation detail; it's a sign the plan's "verified not currently used" rigor is thinner than the confident tone suggests. The deeper pattern: the author of the plan appears to have skimmed the fork's delta stats (+74/-19 etc.) and assumed "additive + low risk," but the fork was cut from a much older c11mux baseline — several of the "verbatim copy" and "small delta" claims collapse when you actually diff against current `main`.

The single biggest issue: **the scope of the real integration work is substantially larger than "copy one file + 8 small hand-edits,"** and the plan's phase structure gives no room for the drift-driven refactoring that will actually be required.

Concerns in rough priority order:
1. **Shortcut collision with Cmd+Option+T** (hard collision, documented in the fork's own source).
2. **Drag routing plan is under-specified** vs what c11mux actually does (three entry points, not one).
3. **Fork baseline is old** — the "copy verbatim" TextBoxInput.swift references APIs/types that may not exist in c11mux verbatim.
4. **No typing-latency plan** that meets the CLAUDE.md bar for evidence (debug-log baseline/comparison) despite CLAUDE.md naming this as a hot path.
5. **Unstated agent-workflow assumption** — the feature is sold for "AI agent workflows" but the plan never shows this is actually better than existing c11mux primitives (sidebar status, send-to-pane, browser surface).

How worried should you be? Moderately. This is a 2-3 day port masquerading as a 1-day port, and if implemented exactly as written, at least two of Phases 4/5/6 will stall mid-phase and need replanning.

---

## How Plans Like This Fail

Cross-fork ports of medium-scale features reliably fail in one of four ways:

1. **Assumed-additive integration turns mutative.** The plan labels most integration points as "pure additions" or "append-only." In practice, every time two teams touch the same file for different reasons, you eventually have to make one side concede. `ContentView.swift` (13,581 lines in c11mux, 15,790 in the fork — both diverged heavily from the same ~7k-line ancestor) is exactly where this bites. The plan flags `ContentView.swift` as "moderate" risk but does not allocate engineering time for "understand c11mux's drag-routing model, then re-design the TextBox hook to match it." It plans to insert.
2. **Baseline drift invalidates verbatim copies.** The fork is 189 commits behind upstream (and c11mux is further ahead of upstream still). The plan's "copy `TextBoxInput.swift` verbatim" depends on public APIs — `TerminalSurface.sendText`, `performBindingAction`, `attachedView`, `sendKey`, `hostedView`, `GhosttyConfig.load`, `GhosttyApp.shared.defaultBackgroundColor`, etc. — having the same shape/behavior in c11mux as in the fork. Most of these appear to still match, but "appears to" is not "verified."
3. **Hidden keyboard/menu/shortcut collisions.** Plans find the documented collisions and miss the undocumented ones. The fork's own inline comment says to use Cmd+Opt+B on upstream; this plan chose Cmd+Opt+T because grep didn't surface a collision — but the collision is there, it's just hardcoded in `AppDelegate.swift` rather than in `KeyboardShortcutSettings`.
4. **Feature-for-a-subset becomes infrastructure-for-all.** "Off by default" is the plan's insurance against this. But shipping a 1,246-line Swift file, ~20 new strings, 4 settings, and 8 integration hooks is irreversible in practice — the maintenance cost is real even when the feature is off. Nobody will remove TextBoxInput.swift later because it's "free" when disabled. That's how a codebase accumulates 15-20% dead weight.

Where this plan is most vulnerable: (1) is the dominant risk here.

---

## Assumption Audit

**Load-bearing assumptions** (plan collapses or significantly changes if wrong):

| # | Assumption | Evidence in plan | Does it hold? |
|---|---|---|---|
| A1 | `Cmd+Option+T` is unbound in c11mux | §4.5 "verified not currently used" | **NO.** `AppDelegate.swift:9498` binds it to close-other-tabs. The fork's own source comment warns about this: "upstream cmux PR uses Cmd+Opt+B to avoid conflict with close-other-tabs" (KeyboardShortcutSettings.swift:265). |
| A2 | `TextBoxInput.swift` can be copied verbatim | §4.1 "Copy verbatim" | Partially. It depends on `TerminalSurface` APIs (`sendText`, `sendKey`, `focusTerminalView`, `performBindingAction`, `scrollbarOffset`, `isScrolledUp`, `scrollToRow`) — `focusTerminalView`, `sendKey`, `sendSyntheticKey`, `forwardKeyEvent`, `scrollbarOffset`, `isScrolledUp`, `scrollToRow` do **not yet exist** in c11mux; they are created in §4.8. So "verbatim" is really "verbatim if §4.8 lands exactly." This is fine, but it's a dependency not called out. |
| A3 | `TerminalPanelView.swift` integration is "+74 / -19" from current c11mux | §4.3 | The fork's `TerminalPanelView.swift` is 114 lines; current c11mux's is **56 lines**. The shapes differ: c11mux doesn't use `paneId: PaneID` in the view; the fork version does. The fork's `body` pulls `GhosttyConfig.load()` inside the view and reads `GhosttyApp.shared.defaultBackgroundColor` to style the TextBox inline. c11mux has similar primitives but this is an actual small refactor, not a copy-paste. |
| A4 | c11mux `Workspace.swift` has no focus-restore work that races with `toggleTextBoxMode` | §4.4 "c11mux has heavy churn... but the new method is self-contained" | Unknown. c11mux's `Workspace.swift` is 9,919 lines with async focus restore after workspace switch, tmux layout snapshots, notification dismiss flashes, etc. The plan's "self-contained" claim is a hope, not a verification. |
| A5 | Drag routing "insert the TextBox check at the correct priority" is a simple reorder | §4.9 | c11mux has three drag methods (`draggingEntered`, `draggingUpdated`, `performDragOperation`) using `updateDragTarget` + `activeDragWebView` state. The fork also changed `updateDragTarget` (to return `.copy` when a TextBox is under cursor — see `/tmp/cmux-tb-inspect/Sources/ContentView.swift:785`) **and** `performDragOperation`. The plan describes only the `performDragOperation` change. |
| A6 | 200ms Return delay after bracket-paste is the reliable minimum | §2 "empirically the minimum" | Probably true for the apps tested (zsh, Claude CLI). Unverified for: `claude` on faster M-series chips where processing may finish earlier, remote SSH terminals where round-trip dominates, `codex`, custom REPLs, `ipython`, `docker exec`, tmux-inside-ghostty, slow machines where 200ms is **too short**. |
| A7 | The feature is meaningful for "a subset of users, especially AI-agent workflows" | §1 rationale, additional user context | Unverified. c11mux already has socket commands to send text to any pane (`cmux send` via the skill). Agents don't need a text box — they already compose anywhere and send. The subset this really serves is **humans talking to agents in the terminal**. That subset is real but narrower than "AI-agent workflows," which reads like a feature-justification adjective more than a requirement. |
| A8 | "8 phases = 8 commits keeps review digestible" | §7 | 8 commits, **1,246 LOC in one file**, ~18 xcstrings, 4 pbxproj edits, and hand-applied integration hooks across 7 files. That is not a digestible PR by cmux's own standards; it's a medium-large one. PR-size risk is "Medium" in the risk register but the mitigation ("split into scaffolding + integration PRs") is buried and offered as a conditional, not a recommendation. |

**Cosmetic / safe assumptions:** The Xcode project-file edit is safe (§4.11). Ghostty `scroll_to_row` support (§4.8) is verified and correct. UserDefaults key namespacing (`textBoxEnabled` etc.) won't collide with existing c11mux keys. Fork's explicit non-ports (Sparkle feed, fork branding, Help menu) are correctly identified.

**Invisible assumptions** (present but unstated):

- That `InputTextView`'s custom `draw(_:)` for placeholder doesn't regress typing latency. NSTextView `draw(_:)` is called on every edit; the fork's implementation renders a placeholder string via `NSString.draw(at:withAttributes:)` each tick even after the first character is typed (it has an empty check but calls `draw` unconditionally). Not a hot-path scorcher, but unexamined.
- That focus loss from workspace switch doesn't corrupt `panel.inputTextView` (weak ref to an `NSTextView` that lives inside a SwiftUI view that may or may not be mounted). When the pane's SwiftUI body is not rendered (e.g., tab not active), the `NSViewRepresentable` tears down — is `inputTextView` still valid? The weak ref will go nil, which breaks the "toggle on all tabs" flow the plan wants.
- That `TextBoxInputTests.swift` passes without the app running. 360 lines of tests — are they unit tests (pure) or integration tests needing an AppKit window? Plan doesn't say. If the latter, CI-only testing (per CLAUDE.md policy) means they can't run locally.
- That "bracket-paste + 200 ms `Return`" does not break c11mux's scrollback/snapshot restore. If a session restore replays a partial paste, the `\x1b[200~` / `\x1b[201~` markers plus an orphaned Return could corrupt the restore.
- That users won't be surprised by `Return = send` when the existing terminal was accepting `Return = newline` in multi-line prompts (some REPLs). The placeholder reminds them, but muscle memory will win.

---

## Blind Spots

Things the plan never asks:

1. **Accessibility.** A new text input surface adds a VoiceOver target. Does it have a label? A role? Can a screen reader announce "TextBox, empty, accepts multi-line"? Is focus order sensible when tab-cycling from terminal → TextBox → send button? Fork likely didn't do this work. Plan doesn't mention it.
2. **Undo stack interactions.** NSTextView has its own undo manager. Does `Cmd+Z` while focused in TextBox inadvertently trigger c11mux's own undo (tab-close? layout?) through a responder-chain leak? Fork tested it in their environment; c11mux's responder chain is different (Bonsplit, portal views).
3. **Per-pane scroll restore contract.** The plan notes `scrollbarOffset`/`isScrolledUp`/`scrollToRow` are added so TextBox resize doesn't snap to bottom. Good. But the **terminal panel height change** goes through bonsplit's split-layout machinery. Are there other code paths that observe size changes and re-synchronize scroll (e.g., `handleLiveScroll`, `synchronizeScrollView`)? What if the user expands the TextBox from 2→8 lines, shrinking the terminal by 6 lines, while the shell prints new output? Does the scroll lock hold?
4. **Bracket-paste interaction with c11mux's shell integration.** c11mux relies on shell integration heuristics (e.g., `ghostty_surface_needs_confirm_quit`, command boundaries, scrollback snapshots). Does wrapping all commands in bracket-paste markers break any of these heuristics? The tab-dirty logic is hand-coded around them (TerminalPanel.swift:49); bracket-pasting every command might change what shell integration sees.
5. **Interaction with c11mux's own send-text primitives.** c11mux has `sendText` via socket, AppleScript, and the cmux CLI (`cmux send`). If the TextBox uses `surface.sendText(trimmed)`, it presumably goes through the same path, but the 200ms delayed Return is bespoke. Should other send paths adopt the same bracket-paste+delay for consistency? Or is TextBox intentionally different and the rest of c11mux is "wrong"?
6. **Session restore.** c11mux persists session state (SessionPersistence.swift). Should `textBoxContent` and `isTextBoxActive` per panel persist? Plan says "Recommend: no in this port." But `isTextBoxActive` is per-panel; if the user enables the feature, toggles some panes hidden, restarts the app, they come back with all panes showing TextBox (because the setting is global but the per-panel state is not restored). That's a UX surprise not called out.
7. **Tmux passthrough.** c11mux has tmux-layout work in Workspace.swift. If a user is inside `tmux`, what does `Cmd+Option+T` do? What does TextBox submission look like when the shell is a `tmux attach`? Bracket paste into tmux forwards to the inner pane — probably fine, but unverified.
8. **Command palette integration.** c11mux has command palette / sidebar. Should "Enable TextBox" / "Toggle TextBox" be reachable from the palette? Plan doesn't mention. Discoverability via a settings checkbox + undocumented hotkey is weak.
9. **Focus loss on mouse click.** If the user clicks the terminal while the TextBox is focused, does the TextBox lose focus (good) or does c11mux's `isPointerEvent` gate swallow the click (bad)? The CLAUDE.md `hitTest` note warns about this area.
10. **"Agent workflow" claim validation.** The plan's rationale leans on AI-agent workflows. But it never defines what an "agent workflow" means for this feature. If the target is "humans typing prompts into Claude Code in a terminal," that's valid and should be stated. If it's "agents controlling other agents," TextBox doesn't help — agents already drive via socket.
11. **Multi-window.** c11mux supports multiple terminal windows. `toggleTextBoxMode(.all)` toggles all tabs in **the current workspace**, or across all workspaces and windows? The fork code reads only `panels.values` for a single workspace. If a user has TextBox on in window A and off in window B, `Cmd+Opt+T` in A flips A but not B. Is that intended?
12. **Localization drift.** Opting to ship English-only adds 18 keys without Japanese equivalents. c11mux's policy per CLAUDE.md: **"All user-facing strings must be localized... Keys go in `Resources/Localizable.xcstrings` with translations for all supported languages (currently English and Japanese)."** Shipping English-only directly violates the stated policy. The plan handwaves past this; it shouldn't.
13. **Help menu.** Plan correctly excludes the fork's Help-menu URL edits but doesn't propose any help entry pointing at c11mux documentation. First-time users discover this feature how?

---

## Challenged Decisions

**Decision 1: Port rather than reimplement.**
- Counterargument: 1,246 lines of someone else's Swift, on top of which we'll need to debug focus races, drag routing, and IME edge cases — is the "cheaper than reimplementing" claim actually cheaper when you count understanding cost? Reimplementing a 200-line version that does 80% of what matters (multi-line send with bracket-paste) could ship in a day with half the ongoing maintenance.
- Is this deliberate or default? Feels like default. The plan never compares port vs. rewrite cost.

**Decision 2: `defaultEnabled = false` (opt-in).**
- Counterargument: If the feature is opt-in, discoverability is terrible. A setting checkbox named "Enable TextBox Input" in a sub-section of an already-large settings panel won't be found. Most "ship it off, let users find it" features die here.
- Better framing: ship it on for a 0.x-pre-release / nightly, gather feedback, then decide before next stable. Or put a dismissible banner / first-run tip.

**Decision 3: `Cmd+Option+T` as the default shortcut.**
- **Direct collision with c11mux's existing close-other-tabs.** Change this before you start. The fork's own comment suggests `Cmd+Option+B`, but that also collides with existing browser-panel toggles; check all such paths. Consider `Cmd+Option+I` (for "Input") or make it unbound by default so users opt in.

**Decision 4: Submit = `Return`, newline = `Shift+Return` (default).**
- Counterargument: In a terminal where bash/zsh commands span multiple lines via line continuation (`\` at end), users typing `Return` mid-command expecting a continuation will submit prematurely. The setting flip is there but muscle memory will cause repeated mis-submissions. The inverse (`Shift+Return` = send) is safer and matches Slack/Discord/web chat; macOS users are conditioned to this.
- Counter-counter: AI chat UIs train people to `Return` = send. Pick a lane, but don't treat it as obvious.

**Decision 5: `.toggleFocus` scope `.all` by default.**
- Counterargument: "Hitting a shortcut in one tab toggles every tab" is surprising. `.active` is the principle-of-least-surprise default. The fork chose `.all` because in their workflow they want global presence/absence. For a c11mux user who splits into web + terminal + terminal, `.all` affects terminals they weren't looking at.

**Decision 6: Ship English-only strings.**
- Counterargument: Violates CLAUDE.md's stated policy. "Velocity" is not a CLAUDE.md exception. Either commit to the policy or relax the policy — don't silently skip.

**Decision 7: 8 phases in one PR (with a conditional split).**
- Counterargument: The plan already knows the right answer ("split if too big"). Split the PR up-front: Phase 1–3 (scaffolding; compiles; no UI change) + Phase 4–8 (integration; user-visible). Reviewer cost goes down sharply, bisect surface goes up sharply, rollback surface stays clean.

**Decision 8: No automated tests for integration.**
- Counterargument: §8 Phase 8 is a manual test matrix. For a feature with 14 test categories (T1–T15 in the fork's source comments), a manual-only validation is thin. At minimum, assert `toggleTextBoxMode` in a unit test (no window) and the key-routing table in another (the fork already has 360 lines of tests for this — are any re-usable against c11mux? Plan doesn't say).

**Decision 9: No typing-latency measurement plan.**
- Counterargument: CLAUDE.md is explicit: "Typing-latency-sensitive paths... Do not add work outside the `isPointerEvent` guard." Plan handwaves: "verify with debug log during validation." How? What's the pass criterion? What's the baseline? There should be a numeric threshold (p50/p95 keystroke→paint delta) and a before/after measurement.

---

## Hindsight Preview — Two Years From Now

Things we'd say:

1. **"We should have caught the Cmd+Opt+T collision before coding."** The fork's own source told us about it. We didn't read carefully.
2. **"We should have shipped this behind a beta flag or a nightly build first."** Instead we spent three cycles tuning defaults because different users hit different defaults on first launch.
3. **"Why didn't we just use `cmux send` from an external editor?"** At some point an agent notices that c11mux already has socket-based text injection, and a minimal `cmux edit-and-send` CLI or a "compose pane" surface would have done 80% of this work with 10% of the maintenance.
4. **"The 200ms delay broke for users on slow machines."** Someone on an older Intel Mac, or over SSH to a remote shell, reports commands silently dropping. The fix involves detecting paste completion (impossible in general) or making the delay configurable.
5. **"We shouldn't have landed this as one file."** 1,246-line files get harder to split over time. Someone in 2027 will carve it into `TextBoxView.swift`, `TextBoxKeyRouting.swift`, `TextBoxSubmit.swift`, `TextBoxSettings.swift`. That could be done now, on port, with one extra hour of work.
6. **"The scroll-preserve heuristic had a bug."** When TextBox grows + new terminal output arrives + user is mid-scroll, the restore sometimes snaps. Nobody noticed during validation because single-threaded manual testing never hits the triple-race.
7. **"We should have persisted `textBoxContent` per panel."** Users get halfway through drafting a long prompt, accidentally restart the app, lose it. The "defer to follow-up" decision aged poorly.

**Early-warning signs the plan should watch for but doesn't:**

- First user bug report "Cmd+Opt+T doesn't work for close-other-tabs anymore."
- Typing-latency debug-log values creeping up after the PR (need a baseline to spot this).
- Japanese-IME users reporting marked-text dropping when terminal title updates rapidly (T3.4 in fork's test plan).
- SSH-remote users reporting premature Returns.
- Split-pane users reporting TextBox focus leaking between panes after pane-close.

---

## Reality Stress Test

The three most likely real-world disruptions and their combined effect:

1. **c11mux `main` gets a non-trivial refactor to `ContentView.swift` drag routing (already has `DragOverlayRoutingPolicy`, `BrowserWindowPortalRegistry`) while the worktree is in flight.** Rebase conflicts in the highest-risk file. Resolution takes an afternoon. Tests weren't automated, so regression discovery happens post-merge.
2. **User reports `Cmd+Option+T` collision on first dogfood.** Scramble to rebind. Everyone who tried the feature had muscle memory for close-other-tabs broken. Small trust hit.
3. **200ms delay is wrong for someone's setup.** Ticket filed. Fix requires either (a) making delay a hidden user default, (b) detecting shell type more precisely, or (c) rewriting submission to not need the delay. All three are Phase 10+ work the plan didn't anticipate.

Combined: PR re-does drag routing, hotkey is reassigned mid-review, and a follow-up configurability PR lands a week later. The **net impact** is a ~2x effort overrun vs. plan. That's the normal failure mode; not catastrophic, but bigger than the plan's "Medium" risks imply.

Add a fourth realistic disruption:

4. **Another agent is mid-flight on c11mux's tier-1 persistence work** (`docs/c11mux-tier1-persistence-plan.md` is on disk alongside this one). TextBox adds per-panel state (`isTextBoxActive`, `textBoxContent`) that persistence work needs to know about. Two plans that both touch "per-panel state" without coordination is a classic mid-flight double-collision.

---

## The Uncomfortable Truths

1. **The "it's cheap to port because the fork did the work" argument is a vibe, not an accounting.** 1,246 lines of unfamiliar code, eight integration points, and an undefined validation bar is not cheap. It's cheaper than *correctly* reimplementing from scratch, but more expensive than a minimal 200-line reimplementation.

2. **"The feature is meaningful for a subset of users, especially AI-agent workflows" is an undefended claim.** It could be true. It could be aspirational. The plan treats it as a premise instead of a hypothesis to validate. For a c11mux-specific agent workflow justification, the plan should show (a) which agent flow this unblocks, (b) why `cmux send` doesn't already handle it, (c) what the evidence is.

3. **"Verified not currently used in c11mux" — this claim is wrong and the fork told us so.** This is a small thing, but it's the kind of small thing that indicates the whole verification step was lighter than the plan implies. If this specific claim is wrong, which others are? (A5, A6, the "verbatim copy works" claim.)

4. **This is a fork by one developer (alumican), not a merged upstream contribution.** The fact that 135 commits of work did not merge to manaflow-ai/cmux main may be because the upstream maintainers rejected it, or didn't care, or the PR was never opened. Plan doesn't say. If upstream has a deliberate reason not to accept this feature, porting it into c11mux means diverging from that decision — worth a sentence on why.

5. **The feature adds **two** input modes to the terminal (terminal line editor + TextBox).** Two-mode editors have a long history of confusing users. Every user session will contain at least one "why didn't my keystroke do what I expected" moment while the user remembers which mode they're in.

6. **The plan assumes the integration is additive, but the responder chain isn't additive.** Every focus-stealing code path in c11mux now needs `if firstResponder is InputTextView { return }` guards. Plan names two (§4.8). There are probably more. When one is missed, focus loss is the symptom, and debugging is "which code path fired at the wrong time."

7. **The plan's phased execution doesn't correspond to anything a reviewer can actually validate.** Phase 1 compiles but does nothing. Phase 4 shows the UI but nothing toggles. Phase 5 toggles but drag doesn't work. A reviewer coming in mid-stream can't run the feature and have it make sense. The "each phase = one commit" structure is great for bisecting but poor for review — you need one "it works end-to-end" commit to anchor discussion.

8. **Shipping 18 English-only strings directly contradicts CLAUDE.md. The plan acknowledges this once, as "option 1," and recommends it.** An adversary would ask: do we actually take our own localization policy seriously? If yes, don't ship English-only. If no, delete the policy from CLAUDE.md so future plans don't have to handwave past it.

---

## Specific Code-Level Findings

Grounded in reading both trees:

- **Cmd+Option+T collision** (confirmed): `~/src/cmux/Sources/AppDelegate.swift:9498` — `StoredShortcut(key: "t", command: true, shift: false, option: true, control: false)` maps to `closeOtherTabsInFocusedPaneWithConfirmation()`. The fork's own source (`/tmp/cmux-tb-inspect/Sources/KeyboardShortcutSettings.swift:265`) says: *"Default: Cmd+Opt+T (upstream cmux PR uses Cmd+Opt+B to avoid conflict with close-other-tabs)"*. **Fix before starting.**

- **`TerminalPanelView.swift` is much smaller in c11mux than the fork's baseline** (`56 vs 114 lines`). The fork pulls `GhosttyConfig.load()` inside the view `body` and reads `GhosttyApp.shared.defaultBackgroundColor/Opacity` to style the TextBox. c11mux has these primitives elsewhere but the view itself does not currently use them. This is a real (small) integration refactor, not a copy. Include this in the plan's "low risk" acknowledgement.

- **Drag routing touches three methods, not one.** Current c11mux (`~/src/cmux/Sources/ContentView.swift:607–685`) has `draggingEntered`, `draggingUpdated`, `performDragOperation` routing through `updateDragTarget` with `activeDragWebView` state. The fork's TextBox patch also added a hit-test in `updateDragTarget` to return `.copy` (`/tmp/cmux-tb-inspect/Sources/ContentView.swift:785`) so the green `+` badge appears. Plan §4.9 mentions only `performDragOperation` and `findTextBox`. Without the `updateDragTarget` change, users get a "drop-rejected" cursor over a valid TextBox drop target.

- **Workspace `toggleTextBoxMode` references `focusedTerminalPanel` and `panels`** (`/tmp/cmux-tb-inspect/Sources/Workspace.swift:6555–6629`). c11mux has `focusedTerminalPanel` (line 6546 in fork baseline) but under a different workspace architecture (Bonsplit, portal layers). Verify the names match current c11mux before porting.

- **Fork's test file already uses `@testable import cmux_DEV` + `@testable import cmux`** (`/tmp/cmux-tb-inspect/cmuxTests/TextBoxInputTests.swift:5–7`). The plan says "update `@testable import` to c11mux's target name" — nothing to update; it already matches.

- **Scroll state properties (`scrollbarOffset`, `isScrolledUp`, `scrollToRow`) referenced by TextBox resize logic (§4.8)** do not yet exist in c11mux. Confirmed they exist in the fork's `GhosttyTerminalView.swift:4865-4879`. This is additive, but note that c11mux already calls `performBindingAction("scroll_to_row:\(row)")` at `Sources/GhosttyTerminalView.swift:8463` for its own scroll handling. Adding `TerminalSurface.scrollToRow(_:)` duplicates that path — either route both through one implementation or accept the duplication deliberately.

- **Bracket-paste `TextBoxSubmit.send` sends text then schedules `sendKey(.returnKey)` via `DispatchQueue.main.asyncAfter`.** The 200ms delay is explicit in source (`TextBoxInput.swift:690`). Captures `surface` weakly — fine. But there's no cancellation if the user submits twice in 200ms, or closes the pane, or switches workspaces. Second submission's delayed Return fires after the first one; pane-close leaves the `weak surface` nil (safe) but with no logging / test of that path.

---

## Hard Questions for the Plan Author

Numbered, unsoftened. Questions where "we don't know" is the current answer are flagged.

1. **Have you confirmed that `Cmd+Option+T` is free?** The fork's own source comment warns about this collision and c11mux has it bound in `AppDelegate.swift:9498`. What shortcut will you actually use? *(Current answer: the plan is wrong here and must change.)*
2. **Did you diff the fork's `TerminalPanelView.swift`, `Workspace.swift`, `ContentView.swift`, and `GhosttyTerminalView.swift` against current c11mux, or did you rely on "delta stats" from the fork branch vs. some upstream baseline?** If the latter, the per-file line numbers in §4 are meaningless. *(We don't know, based on how the plan reads.)*
3. **What's the pass criterion for "no typing-latency regression"?** A number (µs? ms? p95?) and a measurement method. *("Verify with debug log" is not a pass criterion.)*
4. **Is this feature really "especially for AI-agent workflows," or is it for humans typing at Claude Code?** They're different use cases with different designs; pick one.
5. **Why port instead of reimplement the 20% that matters?** Show the cost comparison. How many hours to port vs. how many to build a 200-line "Compose & Send" alternative?
6. **Was this ever offered upstream to manaflow-ai/cmux?** If it was and was rejected, why are we taking it? If it never was, did the fork author say why? *(We don't know.)*
7. **How does `toggleTextBoxMode(.all)` interact with multiple windows?** Single workspace, single window, or across all windows? Plan is silent.
8. **Will the 18 new strings be localized to Japanese at ship time?** If not, explicitly acknowledge that this is an exception to CLAUDE.md and say so in the PR description. Don't defer silently. *(Plan currently recommends silent deferral.)*
9. **Who owns the ongoing maintenance of `TextBoxInput.swift`?** 1,246 lines in a fork-maintained style (`[TextBox]` markers, lots of Japanese-English mixed comments) — who keeps it building when c11mux refactors `TerminalSurface`, `GhosttyNSView`, `Bonsplit`? That person should sign off on the port.
10. **How are the 360 lines of `TextBoxInputTests.swift` structured?** Unit (pure, offline) or integration (need window)? Will they run in c11mux's CI? *(We don't know from the plan.)*
11. **What happens on session restore when a user had TextBox open with unsubmitted content?** Content lost? Preserved? Do you want to file a follow-up or just accept it? Make the call, don't defer.
12. **Is there a collision with c11mux's own tier-1 persistence work** (`docs/c11mux-tier1-persistence-plan.md`)? Per-panel state is exactly what that plan touches. Coordinate now or fight later.
13. **Are there other hardcoded shortcuts in `AppDelegate.swift` the plan's audit missed?** Cmd+Opt+T was hardcoded, not in KeyboardShortcutSettings. Did you grep for `StoredShortcut(key:` across all of `Sources/`? *(Plan does not show evidence of doing this.)*
14. **How is the feature discovered?** Setting checkbox + undocumented hotkey. What's the first-run / onboarding plan?
15. **What's the rollback plan if a user enables TextBox, hits a bug, and can't get back to normal?** Hidden pref key? Safe-mode launch flag? Or just "quit and edit `~/.cmux/defaults.plist`"?
16. **Why 8 commits in one PR vs. the explicitly suggested 3+5 split?** The plan names the split as a fallback, but the split is clearly better from the start. Defend not splitting.
17. **Does the TextBox need to work in full-screen / stage-manager / hidden-dock modes?** c11mux users include heavy full-screen users. Any interactions with NSWindow style mask changes? *(Unexamined.)*
18. **Does `TextBoxInput.swift`'s `insertText` / `doCommand` path interact with accessibility or input-method engines** that have hooks in c11mux (SSH detection, bootstrap scripts)? Most likely no, but the plan doesn't enumerate these surfaces.
19. **If the feature ships disabled and has <5% opt-in rate after 3 months, what's the deprecation plan?** Or do we keep 1,246 lines around indefinitely?
20. **What's the budget for this port, in person-days?** The plan reads like "2 days." My estimate: 4-6 days to do correctly, plus another 2 post-ship fixing the surprises. Align expectations with the user explicitly before starting.

---

## Recommendations (compressed)

Things I'd fix **before** spinning up the worktree:

1. **Change the default shortcut** from `Cmd+Option+T` to something unbound (candidates: `Cmd+Option+I`, `Cmd+Option+K`, unbound-by-default). Verify by grepping for `StoredShortcut(` across all `Sources/`, not just KeyboardShortcutSettings.
2. **Re-diff the 7 integration files against current c11mux `main`**, not against the fork's internal "delta" view. Update §4 line counts to reality.
3. **Split the PR into scaffolding (Phases 1-3) + integration (Phases 4-8).** Do not wait for "if it gets too big."
4. **Commit to Japanese localization** at ship time, or explicitly document the CLAUDE.md exception in the PR description.
5. **Define a typing-latency pass criterion** (specific numbers, specific measurement method) and bake it into Phase 8.
6. **Coordinate with the tier-1 persistence work** regarding per-panel state (`isTextBoxActive`, `textBoxContent`) before either plan is committed to.
7. **Rewrite §4.9 (drag routing)** to include the `updateDragTarget` change, not just `performDragOperation`.
8. **Decide up-front: port-as-is or refactor-on-port.** 1,246 lines in one file is a choice. Splitting into 4 files now is an hour; doing it in 2027 is a day.
9. **Add a pre-port audit pass as Phase 0:** one commit's worth of "read c11mux's current `ContentView.swift`, `Workspace.swift`, `GhosttyTerminalView.swift`, and list every integration point's current shape." Then write the real plan.
10. **State the validation hypothesis explicitly.** Who is this for, what does success look like, what would make us remove it?

---

## Final Word

The plan is structured and organized, and the author clearly understands the shape of a Swift/SwiftUI port. The risk is not in the obvious places (copying one file, editing a pbxproj); it's in the assumption that integration is additive when `ContentView.swift`, `Workspace.swift`, and the responder/focus machinery have drifted far from where the fork branched. The Cmd+Option+T collision is a canary: if the plan missed that — and the fork's own source tried to warn us — other things are also light on verification. Fix the canary, do Phase 0 re-diffing, split the PR, and this becomes a reasonable 3-4 day effort instead of a 2-day plan that turns into a 6-day slog.
