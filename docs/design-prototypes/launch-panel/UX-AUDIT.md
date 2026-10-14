# UX audit — c11 launch panel v2

**Verdict:** the two-object concept is strong, and the panel is materially more legible than the shipped popover, but implementation should not start until the blocker findings below are resolved. The largest risk is not visual polish; it is an incomplete interaction contract at the exact point where a launch changes persistent system behavior.

## Scope and evidence

Reviewed:

- `launch-panel/README.md` and the full two-stage `index.html` prototype.
- The live prototype in a c11 browser surface: panel toggle, Escape dismissal, row-focus sequence, model dropdown selection, changed-value treatment, and both launch-panel and Settings layouts.
- The v1 rationale in `model-picker/README.md`.
- The shipped v1 `AgentPickerView.swift` and its launch/presenter integration at `origin/main` commit `0d6838bb0`. The current `workspace-pulse-prototype` branch predates that file, so the shipped source was read from the exact `origin/main` commit.
- `void-popover-aesthetic.md`.

The live prototype successfully demonstrates instant toggle/close and pointer-based dropdown changes. It does not demonstrate the stated keyboard behavior: a real Arrow Down event does not move selection, and the prototype’s rows, dropdowns, gear, and close control are not focusable elements. That prototype limitation is not itself a product defect, but it exposes places where the design contract is not yet implementable without inventing behavior.

## Blockers

### B1. The keyboard contract cannot operate the interface it describes

**Scenario.** An operator opens the panel with ⌘⇧A, moves to the Claude Code harness row, and wants to change both model and effort before launching. The only promised keys are ↑↓, Return, and Escape. ↑↓ already owns row selection; Return is documented as launch. There is no command that enters a dropdown, moves between model and effort, opens a menu, or commits a menu choice.

The prototype’s synthetic focus order walks every configuration in the left column, then jumps from the bottom-left row to the top-right harness row. Its recent strip says “relaunch ↵” but is not in that focus order.

**Why it hurts.** The design promises keyboard efficiency while making the right half pointer-only. Implementers will otherwise invent incompatible focus rules late, and a global key monitor risks swallowing terminal arrows and Return.

**Proposed fix.** Choose and document one complete state machine before implementation. My recommendation is to relax “↑↓ + ↵ only” for nested controls and use platform conventions:

- ↑↓ moves the row cursor.
- Tab / Shift-Tab moves through a focused harness row’s Model, Effort, and Launch controls.
- Space or Return opens/selects a dropdown; Return on Launch launches.
- Escape closes a menu first, then the panel.

If the restricted key set is non-negotiable, a harness row needs an explicit edit submode: first Return enters Model, ↑↓ changes it, Return advances to Effort, and a final Return launches. That mode must be visible, and configuration rows must retain one-Return launch. Do not ship a hidden custom state machine.

### B2. An ad-hoc harness launch has no representable default identity

**Scenario.** The operator changes Claude Code from its base `opus / deep` to `sonnet / high` and launches. The copy calls this a “one-off,” but the decided rule says every panel launch becomes the system default for the next plain A-click. The result is not a saved User Configuration, so no left-column row can carry the ● marker. Settings’ default strip expects a named configuration, and the open question in the README leaves this unresolved.

**Why it hurts.** This is a data-model hole expressed as a UX contradiction. Either the launch does not set the default, violating the decided rule, or the default becomes an anonymous recipe that neither view can faithfully display or manage. Deleting or later editing the underlying harness base makes the ambiguity worse.

**Proposed fix.** Make the last successful panel launch a first-class, persisted default snapshot with exact resolved harness, model, effort, and system-prompt axes plus an optional configuration ID:

- A saved-configuration launch displays its name and marks that left row.
- An ad-hoc harness launch displays `Last launch · Claude Code · sonnet · high`, marks the matching right row, and appears verbatim in Settings’ read-only default strip.
- Plain A-click launches that snapshot, not whatever the harness base later becomes.
- Offer `Save as configuration…` as a quiet post-launch action, but do not silently mint library entries.

Commit the new default only after resolution, preflight, surface creation, and command enqueue succeed. A failed or unavailable harness must not poison plain A-click.

### B3. Persistent visibility has no post-launch focus contract

**Scenario.** The operator presses Return to launch into the pane under the panel. c11 creates and focuses the new terminal surface, but the launch panel deliberately remains open. It is unspecified whether the panel or the terminal is now first responder. If the panel retains its key monitor, arrows and Return intended for the new TUI are captured. If the terminal owns the keys, the panel still shows a gold keyboard cursor that is no longer active.

**Why it hurts.** This can make a newly launched agent appear wedged, prevent interaction with setup/authentication prompts, or send input to the wrong target. The shipped v1 avoids the conflict by closing on launch; v2 removes that safety property.

**Proposed fix.** Define explicit active and inactive panel states:

1. Opening or clicking the panel makes it active and gives it keyboard ownership.
2. A successful launch transfers first responder to the new terminal and immediately removes/suspends the panel key monitor.
3. The panel may remain visible, but loses its focus spine and shows a quiet `Launched …` inactive state.
4. Clicking the panel or toggling A reactivates it.

Add runtime tests that type arrows and Return into the new terminal while the inactive panel is still visible. If a reliable inactive state cannot be built, close on successful launch; persistence is not worth ambiguous input routing.

### B4. The pane-centered panel has no adaptive geometry or growth policy

**Scenario.** An operator opens the fixed 780 px panel in a narrow split, or has twelve configurations and eight enabled harnesses. The prototype has a fixed width, no pane-relative maximum size, no per-column scrolling, and no compact layout. Even at the intended width, the right-column explanatory caption is visibly truncated.

**Why it hurts.** Narrow panes are a primary c11 use case, not an edge case. The panel can cover adjacent panes, clip controls, or push its close/hint regions outside the pane. Unbounded row growth also turns a launch command into a search-and-scroll task.

**Proposed fix.**

- Clamp the frame to the clicked pane’s usable content rect with 12–16 pt insets.
- Set a pane-relative maximum height and make each column independently scrollable beneath sticky column headers.
- Keep the panel header and keyboard hint bar fixed.
- Define a compact breakpoint. Below the width needed for two usable columns, stack the same two sections or use a segmented `Configurations / Harnesses` view rather than shrinking type and controls.
- Preserve the selected row when the pane resizes, and scroll it into view.

Test at full width, half, third, and deliberately tiny panes, with empty, typical, and long libraries.

### B5. Settings claims to edit harness bases but provides no harness-base editor

**Scenario.** The operator selects the Codex harness card to change its base model, effort vocabulary, or command—the exact values that populate the panel’s right-column dropdowns. The prototype provides cards and enable toggles, but no editor for the selected harness. The only visible editor edits the selected User Configuration.

**Why it hurts.** Half of the proposed two-object model cannot perform its stated job. Implementers do not have a decided layout or save model for the values that configurations inherit.

**Proposed fix.** Add a selected-harness inline editor below the harness grid, parallel to the configuration editor, covering:

- executable/command and detected path,
- enabled state and availability,
- base model,
- base effort and the harness-specific effort vocabulary,
- supported/unsupported axes,
- reset-to-factory behavior.

Show which saved configurations inherit from the base before applying a change. Keep harness edits transactional with Save/Revert rather than mutating inherited launches on each keystroke.

## Serious findings

### S1. The persistent default side effect is substantially under-signaled

**Scenario.** The operator hovers a harness row and sees `launch ↵`, after reading that dropdown changes make a “quick one-off launch.” They launch for a single task. The small footer note—`launch sets the default`—is the only warning that every later plain A-click, in every workspace/window, has changed.

**Why it hurts.** “Launch,” “one-off,” and “set the system default” describe different levels of consequence. The current A-button gold underline only says that some state exists; it does not reveal which model is now default. A tooltip is invisible to keyboard users and easy to miss after the change.

**Proposed fix.**

- Replace the harness row’s trailing `launch ↵` with `launch + make default`.
- When a dropdown leaves base, show a local consequence line beside it, not only in the footer.
- After success, show `Default everywhere → Claude Code · sonnet · high`.
- Update every A button’s exact tooltip immediately. Keep the subtle accent, but do not treat it as sufficient communication.
- If “system” actually means user-wide, window-wide, or workspace-wide, use that exact scope in the confirmation.

### S2. Keeping the full panel open hides the surface the operator just launched

**Scenario.** The agent starts beneath a 780 px panel and immediately prints a missing-binary error, permission prompt, OAuth URL, or orientation message. The operator sees the still-open picker instead of the launch result.

**Why it hurts.** The pane being occluded is precisely the pane whose state now matters. Persistence favors repeated launches but penalizes the common single-launch flow and delays detection of failures.

**Proposed fix.** After a successful launch, keep persistence without keeping full occlusion: collapse the panel to its header plus a one-line launch/default confirmation. A-click or clicking the collapsed panel expands it in place. If repeated batch launching is an important workflow, offer an explicit `Keep expanded` session control in Settings rather than making every launch pay the cost.

### S3. The Settings prototype contradicts the decided default rule

**Scenario.** The README says the Settings default strip is read-only and there is no pin ceremony. The prototype still renders ●/○ controls with `set default` tooltips on every configuration, plus a default strip styled like a clickable picker.

**Why it hurts.** This restores the very alternate default-setting gesture the v2 decision removed. A user can no longer infer whether default means “last launched” or “selected in Settings,” and implementation teams have two conflicting sources of truth.

**Proposed fix.** Remove the pin controls and pointer affordance from the default strip. Render the strip as status with:

- exact current default snapshot,
- source (`last panel launch`),
- time,
- `Save as configuration…` only when the snapshot is anonymous.

Also specify what happens if the named configuration is edited or deleted. Prefer retaining the resolved snapshot until another successful launch changes it.

### S4. Inheritance is described, but not resolved where the decision is made

**Scenario.** In the configuration editor, `Model ● override` sits beside chips including `inherit`; the Harness label says `from: claude code base`, even though the harness is the base reference, not an inherited value. An operator considering Inherit cannot see the resulting model without cross-referencing the harness cards.

**Why it hurts.** ○/● encodes provenance, but the launch consequence is the resolved value. Duplicate state—an override badge plus an `inherit` value chip—adds cognitive work and can become contradictory.

**Proposed fix.**

- Treat Harness as an explicit required reference with no inherit marker.
- For each overridable field, use one control whose inherited choice reads, for example, `Inherit — opus from Claude Code base`.
- Keep a single provenance label: `○ inherited` or `● override`.
- Show a compact resolved-recipe preview before Save.

### S5. The recent strip is semantically unscoped and keyboard-orphaned

**Scenario.** The strip shows `Opus deep · just now · relaunch ↵`. If it is the last panel launch, it duplicates the default. If it includes CLI or in-TUI activity, it may not be the default under the new rule. In the prototype it visually advertises Return but is omitted from keyboard focus.

**Why it hurts.** A third object—recent activity—re-enters a design whose stated strength is “one mental model, two objects.” It also creates a false keyboard affordance.

**Proposed fix.** Either remove the strip, or explicitly define it as `Last launch outside this panel` and explain that relaunching it will make it the default. If retained, put it in the focus order and represent its anonymous-default state using the snapshot model from B2.

### S6. “Changes reflect live” conflicts with Save/Revert and inheritance propagation

**Scenario.** Settings says changes reflect in the panel live, while the configuration editor has Save and Revert. A base-harness edit can also alter every inheriting configuration. It is unclear whether typing, chip selection, toggle changes, or Save updates the open launch panel.

**Why it hurts.** Operators cannot predict whether exploratory edits immediately change launch behavior. With launch-set-default, a half-edited recipe becoming live is especially risky.

**Proposed fix.** Make the contract explicit:

- Editors are drafts; the panel observes committed state only.
- Save atomically updates the panel and shows a short confirmation.
- Revert discards the draft.
- Enable toggles may be immediate, but must be labeled and confirmed separately.
- Base changes show `Affects N inherited configurations` before Save.

### S7. Gold no longer has one meaning

**Scenario.** The panel can simultaneously show a gold default dot/tag, gold keyboard focus, gold changed dropdown, gold system-prompt chip, gold consequence copy, and gold A accent. Settings adds selected configuration, override labels, selected chips, selected harness border, multiple enabled toggles, and the stats leader.

**Why it hurts.** The aesthetic contract says gold means “this is the one” and warns against reaching for it repeatedly. Here it communicates default, focus, dirty state, enablement, unusual prompt behavior, and analytics leadership. The operator must read every label because color stops carrying a stable signal.

**Proposed fix.** Reserve full-strength gold for active keyboard focus and the effective default. Use neutral raised-material treatments for enabled toggles, a quiet white/dim `edited` marker for changed dropdowns, and goldGhost only for exceptional system-prompt modes. In Settings, only the currently edited object should carry a gold spine; its enabled toggle should not also be solid gold.

## Minor findings

### M1. “Agent,” “model,” and “harness” are overloaded

**Scenario.** The right column is Harnesses, each row names an agent application, and the README calls the first dropdown `agent (model)`.

**Why it hurts.** A first-time operator can reasonably think the dropdown switches Claude Code to Codex rather than Opus to Sonnet.

**Proposed fix.** Label the controls `Model` and `Effort`. Keep `Harnesses` as the decided title, but add the plain-language subtitle `installed agent apps and their launch defaults`.

### M2. The disabled-harness rollup is factually inaccurate

**Scenario.** The panel says `+ 3 more detected but disabled`, while Settings shows two installed-but-disabled harnesses and one not detected.

**Why it hurts.** Detection state is operational information; combining unavailable and disabled tools makes troubleshooting harder.

**Proposed fix.** Use `2 disabled · 1 unavailable — manage in Settings`. If the gear is truly the panel’s single Settings route, make this status non-clickable; otherwise acknowledge that it is a second route.

### M3. Dense captions already truncate at the intended size

**Scenario.** The right-column heading’s `dropdowns preset to defaults — tweak & ↵` is clipped in the live prototype. Names, provider strings, model IDs, and translated labels can be longer still.

**Why it hurts.** The smallest, dimmest text carries the instructions needed to understand the novel right-column behavior.

**Proposed fix.** Put essential guidance on a second line or in persistent control labels, not a trailing 9 px caption. Test the panel in all shipped locales, with long model identifiers, increased system text size, and reduced-contrast displays.

### M4. Harness availability needs more than opacity

**Scenario.** Installed-disabled and not-detected harness cards share the same dimmed treatment and apparently interactive toggle. It is unclear whether an unavailable harness can be enabled, configured with a custom path, or only installed externally.

**Why it hurts.** The operator cannot tell whether clicking will fix the state, expose setup, or do nothing.

**Proposed fix.** Give each state a named action: `Enabled`, `Disabled — Enable`, `Not found — Locate executable…`, or `Unsupported`. Do not rely on 0.45 opacity alone.

### M5. Settings row actions are hover-only and under-specified

**Scenario.** Edit and delete controls appear only on hover, drag is the only reorder affordance, and deleting the current default has no specified result.

**Why it hurts.** Keyboard and assistive-technology users cannot discover the same management surface, and accidental deletion can break the default’s identity.

**Proposed fix.** Use real accessible buttons with labels, provide keyboard reorder actions, confirm destructive removal, and state the default-snapshot behavior described in B2/S3.

### M6. Fractional launch counts damage stats credibility

**Scenario.** Launch stats show `1.5` and `0.5` launches.

**Why it hurts.** A launch is an integer event. Fractional counts imply synthetic data or weighting without explanation.

**Proposed fix.** Use integer prototype data. If values are weighted, rename the measure and explain the weighting.

## Polish

### P1. Give icon-only controls explicit names

**Scenario.** A keyboard or VoiceOver user reaches the circled gear or close glyph without the visual context that makes the symbols obvious.

**Why it hurts.** The compact controls become unnamed targets, and their roughly 20 px prototype hit regions are less forgiving than the surrounding rows.

**Proposed fix.** Use native button semantics, accessible names, generous hit regions, and visible keyboard focus. Prefer the gear label/tooltip `Manage configurations and harnesses…` over repeating the Settings page title.

### P2. Remove stale copy before the design becomes a build contract

**Scenario.** An implementer follows the README’s “no footer rows” and read-only default strip while another follows the HTML’s “single footer row” and set-default pin controls.

**Why it hurts.** The same approved design yields two different products and reopens decisions during implementation.

**Proposed fix.** Resolve the contradictions in the prototype and README together, then treat those two artifacts as one versioned contract.

### P3. Separate consequence from instruction in the hint bar

**Scenario.** A scanning operator reads the keycaps but skips the unboxed phrase between them: `launch sets the default`.

**Why it hurts.** A persistent side effect is visually demoted to the same rhythm as shortcut help.

**Proposed fix.** Put the consequence in its own clearly worded status line or make it part of the launch action label.

## The three changes to make before implementation starts

1. **Resolve the launch/default/focus state machine.** Define an exact persisted default snapshot for ad-hoc harness launches, update all A-button representations, and specify success, failure, terminal focus, key-monitor suspension, and inactive/collapsed panel behavior.
2. **Replace the incomplete keyboard promise with a complete, testable contract.** Prefer standard nested-control navigation; if ↑↓/Return-only remains binding, design and prototype the explicit harness edit submode before coding.
3. **Finish responsive panel and Settings mechanics.** Specify pane-relative sizing/scrolling/compact layout, then add the missing harness-base editor and resolved inheritance preview so both halves of the two-object model are actually manageable.
