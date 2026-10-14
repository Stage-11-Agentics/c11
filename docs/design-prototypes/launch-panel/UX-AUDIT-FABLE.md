# UX Audit: Launch Panel v2 (C11-175 rev 2)

*Auditor: Fable 5, 2026-07-24. Method: full read of `README.md`, `index.html` (source), the v1
`model-picker/README.md`, and `docs/void-popover-aesthetic.md`; then hands-on driving of the
prototype in a c11 browser surface (panel toggle, keyboard-focus cycling, dropdown open/change,
escape layering, close/reopen persistence, computed-style checks on state treatments).*

*Scope note: the brief points at `Sources/AgentPickerView.swift` as the shipped v1 popover; that
file is not on this branch, so shipped-popover context comes from the v1 README and the aesthetic
guide, which cite it as canonical.*

The decided semantics are respected as fixed except where a finding is a genuine hazard, and those
are flagged as such. Findings are ranked blocker / serious / minor / polish.

---

## Blockers

### B1. The keyboard model cannot reach the panel's headline feature

**Scenario.** An operator wants the panel's marquee one-off flow: claude code row, flip effort
from `deep` to `low`, press ↵. The decided keyboard contract is "↑↓ and ↵ only, esc closes."
↑↓ moves row focus; ↵ launches the focused row. There is no key that enters, opens, changes, or
leaves a dropdown. In the prototype the dropdowns are mouse-only, and the harness column's own
header sells the flow the keyboard cannot perform: "dropdowns preset to defaults — tweak & ↵."

**Why it hurts.** The tweak-and-↵ story is the reason the harness column exists (README §3). As
specified, it is half keyboard, half mouse: hands leave the keyboard to click a 9.5px dropdown,
then return for ↵. Worse, the two decided rules contradict each other silently: implementers will
either invent an undocumented traversal (divergence risk) or ship dropdowns that a keyboard user
discovers are dead. This is also an accessibility floor issue and, per the repo's own bar, an
agent-drivability issue (computer-use validation agents will face the same 9.5px targets).

**Fix (needs an operator decision before implementation, hence blocker).** Two honest options:

1. *Stay literally within ↑↓ ↵:* declare the dropdowns pointer-only, explicitly, and make ↵ on a
   harness row always launch what the dropdowns currently show. Change the column hint to
   "click to tweak · ↵ launches shown recipe." Cheap, but concedes the flagship flow to the mouse.
2. *Minimal extension (recommended):* keep ↑↓ ↵ as the whole row-level grammar and add exactly one
   axis: ←→ moves a sub-cursor across [row · model dd · effort dd] on harness rows; ↵ on a dropdown
   opens it, ↑↓ selects within, ↵ commits, esc closes the dropdown (see B3-adjacent esc note in
   S5). On configuration rows ←→ is inert. This is one new key pair, spatially honest (the
   dropdowns are literally to the right), and keeps ↵-from-row-focus as instant launch.

Either answer is fine; shipping without answering is not.

### B2. Focus ownership of a persistent panel over a live terminal is undefined

**Scenario.** The panel is non-transient: it stays open across launches and clicks elsewhere. The
operator opens it, gets distracted, clicks into the terminal beneath (or another pane) and types.
Where do the keystrokes go? If the panel holds key focus while visible, the terminal under it is
silently dead and typed commands vanish into ↑↓/↵ handling; ↵ would *launch an agent*. If focus
follows clicks as normal, the panel remains on screen looking active while ↑↓/↵ no longer do
anything, and the operator's next ↵ press "at the panel" goes to a shell instead.

**Why it hurts.** Popovers dodge this by being transient: visible implies focused. A persistent
panel breaks that equivalence and the design says nothing about the unfocused state. Both failure
directions are nasty: stolen-focus makes the terminal lie; ambient-focus makes the panel lie. An
accidental ↵ in the wrong model either launches a surprise agent (which then *becomes the system
default* under rule 6, compounding the damage) or executes a shell line.

**Fix.** Define the focus contract explicitly: the panel takes key focus on open; clicking any
terminal moves focus out and the panel drops to a visibly dimmed "unfocused" state (e.g. gold
spine and goldFaint row fill fall back to the gray ladder, header text steps down one opacity
rung); clicking the panel or pressing ⌘⇧A re-focuses it. The aesthetic guide already has the
vocabulary for this (white-wash vs gold states); the design just needs to commit. Also specify:
does esc close the panel when focus is in the terminal? (Recommend: no; esc is the terminal's.)

---

## Serious

### S1. Launch-sets-default churns silently; the cost lands later, somewhere else

**Scenario.** Default is `Opus deep`. The operator wants one quick throwaway triage agent, opens
the panel, launches `Sonnet quick`, closes the panel, moves on. Twenty minutes later they A-click
to spin up a serious build agent and get sonnet. Nothing at launch time said "this is now your
default"; the only traces are the ● migrating inside a panel that is now closed, and a 1.5px gold
underline on the A button that was already there before (it encodes "a default exists," not "the
default changed").

**Why it hurts.** Rule 6 makes every launch a *write to global state*, but the write is free of
feedback at the moment it happens, and its consequence surfaces at the next plain A-click, which
may be minutes or days later, possibly in a different workspace, possibly after an agent-driven
session where the operator forgot the one-off entirely. The failure is not the rule (it is a
defensible "recency is intent" bet); the failure is that the rule is invisible at write time.

**Fix (stays fully inside the decided semantics).**
- On every launch that *changes* the default, show the aesthetic guide's toast (§6: surface2 card,
  2px gold left spine, 1.2s decay): `sonnet quick launched · now your A-click default`. No toast
  when the launch matches the existing default, so the noise is proportional to the churn.
- Make the A button tooltip always name the effective default ("Launch: Sonnet quick · claude
  code · sonnet"), as v1 already specced. The mock currently has no tooltip on A.
- Optional third rail: the recent strip (see S4) becomes the undo surface: show the *previous*
  default there with "↩ restore default" so one misfire is one click to repair.

### S2. Settings contradicts the launch-sets-default rule: two sources of default truth

**Scenario.** The README declares the Settings default strip "read-only (default = last
launched)." But the Settings mock gives every configuration row a hover pin button (● / ○, title
"set default"), and the default strip itself is rendered as `def-pick`, a control-styled chip with
hover affordance and pointer cursor. An operator clicks the ○ pin on `Codex yolo`: either it does
nothing (a dead control wearing a control's clothes) or it sets the default (and now the panel's
"last launched = default" caption is false, because the default is something never launched).

**Why it hurts.** The single boldest decision in this design (rule 6, no pin ceremony) is
undermined inside its own settings page. Whichever way the pins resolve, one of the two surfaces
is lying, and "what will plain A-click do" stops having one answer derivable from one rule.

**Fix.** Pick one authority. Recommended: last-launched is the only writer. Remove the pin
buttons from Settings rows entirely, restyle the default strip as plain text (no chip, no hover,
no pointer), and let it read like the status line it is: `Default on plain A-click: Opus deep ·
set by launching · 2m ago`. If the operator instead wants a manual escape hatch, keep exactly one
pin *in Settings only* and rewrite the rule everywhere as "last launched or explicitly pinned,"
but do not ship the current both-and-neither state.

### S3. The panel occludes the pane it launches into, and its geometry ignores real splits

**Scenario A (occlusion).** The panel centers on the pane whose A was clicked: the very pane the
new agent will appear in. Launching keeps the panel open (decided). Measured in the prototype, the
panel covers 43% of the terminal area of a *full-window* pane. The operator presses ↵ and the new
agent boots invisibly behind the panel. The strongest confirmation a launch worked (the agent's
terminal coming alive) is exactly what the panel hides.

**Scenario B (small panes).** The panel is a fixed 780×410. In a real c11 layout a quarter-pane
can be ~500px wide. Centered on that pane, the panel overflows onto two or three neighbors, and
"centered on the pane" stops communicating *which* pane it belongs to — the one thing the
centering was for. With ⌘⇧A (open question 2) the ambiguity doubles: nothing visually ties the
panel to the focused pane.

**Fix (within "panel, centered, stays open").**
- Clamp: `width = min(780, paneWidth − 24)`, clamp position inside the pane's bounds; below a
  floor (~460px) fall back to centering on the *window* while keeping the pane link (next point).
- Pane link: while the panel is open, mark the target pane, e.g. a 1px goldFaint inset ring on the
  pane border (the §7 launch-ring treatment, held rather than decaying). This answers "which pane"
  at any size and for the ⌘⇧A path.
- Launch feedback that survives occlusion: flash the launched row (1.4s goldFaint decay, already
  in the motion vocabulary) and rely on the new tab flashing in the tab bar, which sits above the
  panel and stays visible. With those two, "stays open" is livable; without them ↵ feels inert.

### S4. "Default" means three different things, and the recent strip mostly duplicates one of them

**Scenario.** In one panel view: the header says `default: Opus deep` (system default), the left
column header says `last launched = default` (same thing, second phrasing), the right column
header says `dropdowns preset to defaults` (harness *base* recipes, a different object), dropdown
menus mark `base` options (same second object, third word), and Settings adds "base: opus" per
harness card. A new operator has to learn that "default" sometimes means "what A-click launches"
and sometimes "what this harness's dropdowns rest at," from context alone.

Meanwhile, under rule 6 the recent strip is *definitionally* the default row: last launched IS the
default. In the steady state the panel shows `Opus deep` with a gold ● and DEFAULT tag in the left
column, `Opus deep` in the header, and `Opus deep · just now · relaunch ↵` in the recent strip.
Three namings of one fact in a 410px-tall surface (four counting the A tooltip).

**Why it hurts.** First-use legibility (audit dimension 1) hinges on the two-column model being
learnable in one glance. Overloading its one keyword against itself is the main thing standing in
the way, and the redundant recent strip spends a whole panel band restating what the ● already
says, while the genuinely useful recent case (an ad-hoc tweaked launch, open question 3) is the
one the mock doesn't show.

**Fix.** Reserve "default" exclusively for the system default. Rename the harness-side concept
"base" everywhere it appears: right column hint `preset to base · tweak & ↵`, dropdown marks stay
`base`, Settings harness cards stay `base:`. Then re-scope the recent strip per the open-question
answer below (Q3): it earns its row only when recent ≠ default or when it can carry the S1 undo
affordance; otherwise drop it and give the panel 30px back.

### S5. Escape layering: one key, two scopes, prototype collapses them

**Scenario.** Operator opens the effort dropdown, decides against changing it, presses esc to back
out of the dropdown. Verified in the prototype: the entire panel closes, and the dropdown is left
open in its detached state (reopening the panel shows the dropdown still hanging open). A
persistent panel invites exactly this muscle memory: esc means "back out one level," not "tear
down the surface I deliberately keep open."

**Why it hurts.** The panel's persistence is a feature ("stays open while you click around");
having the dismiss-everything key bound while inner transients are open makes the panel feel
fragile, and re-opening costs a re-orientation. Combined with B1's dropdown keyboard story, esc is
the natural "close dropdown" key and must not be overloaded.

**Fix.** Esc closes the topmost transient first: open dropdown → close dropdown; no dropdown →
close panel. One line of spec, standard macOS layering.

---

## Minor

### M1. One-off dropdown tweaks persist silently across close/reopen

Verified: change claude code's model to `sonnet`, close the panel, reopen: the dropdown still says
`sonnet` (gold), though the column header claims "preset to defaults." Spec is silent on tweak
lifetime. Recommend: tweaks reset to base whenever the panel closes (a one-off is a one-off; the
saved-recipe path is User Configurations, and rule 6 already captures repeat intent by making the
launch the default). If tweaks are meant to persist per-session, the header copy must stop
claiming "preset to base," and the harness row needs a visible "modified, reset ↩" affordance.

### M2. The inert "—" effort dropdown is a clickable control that does nothing

Harnesses without an effort axis (gemini, opencode, kimi) render an effort dropdown styled
identically to live ones, with a caret, hover states, and an openable menu containing the single
option "— no effort axis." A control that invites interaction and then explains it shouldn't exist
is worse than no control. Render static dim text (`—`) with no border, caret, hover, or menu;
column alignment can be held with a fixed-width slot. (Aesthetic guide §5 backs this: disabled
things get suppressed hover, not a working menu.)

### M3. Keyboard focus cannot reach the recent strip or the disabled-harness rollup

The ↑↓ ring covers the 10 config/harness rows only (verified: `data-kbrow` count is 10). The
recent strip advertises `relaunch ↵` but can never be the ↵ target; the "+3 more — enable in
Settings ›" foot and the header ⚙ are likewise pointer-only. Either include the recent strip in
the traversal ring (it advertises a keyboard action, so it must be reachable) or remove its `↵`
hint. The rollup and ⚙ can stay pointer-only, but then the hint bar should carry `⌘,` so Settings
has *a* keyboard route (the ⌘, binding exists per the README but appears nowhere in the panel
except the gear tooltip, which keyboard users never see).

### M4. The disabled-harness rollup miscounts its own story

Panel says "+ 3 more detected but disabled — enable in Settings ›". Settings shows grok and pi as
detected-but-disabled, and github copilot as *not detected*. Copilot cannot be enabled, only
installed; the rollup's claim and CTA are both wrong for a third of its contents. Use "+ 2
disabled · 1 not detected — Settings ›", or the honest generic "+ 3 more — Settings ›".

### M5. Harness base recipes are declared editable in Settings, but no editing surface exists

The Settings copy says "each harness's base (command, default model, effort vocabulary) is edited
here — favorites inherit from it," and the panel's whole dropdown-preset story leans on those
bases. But harness cards only offer the enable toggle (a selected state exists on the claude card
with no editor attached). The configuration mini-editor shows the ○/● inheritance chips working
well; the *other end* of that inheritance chain has no UI. Before implementation, sketch the
harness-side editor (a mini-editor twin below the grid for the selected card would mirror the
configurations pattern cleanly), or the inheritance model ships half-inspectable.

### M6. Gold discipline: the panel spends gold on prose

Aesthetic guide §4: gold is a state marker; "if a new surface reaches for gold a third time in one
view, the design is wrong." Legitimate state gold here: the ● + DEFAULT tag, kb-focus spine/fill,
changed dropdowns, system-prompt chips. On top of those, the panel adds gold *text* twice: the
header's `default: Opus deep` value and the hint bar's "launch sets the default" sentence. Both
are labels, not states, and both name the same fact the ● already marks (see S4). Drop the hint
bar phrase to the standard `white @ 0.45` hint color and let the header value sit at `white @ 0.8`;
gold stays reserved for the marker itself.

---

## Polish

### P1. Changed-dropdown gold dissolves inside the focused row's gold fill

Computed in the browser: a `.changed` dropdown is gold text on `goldGhost` (gold @ 0.10) sitting
on the kb-focused row's `goldFaint` fill (gold @ 0.20). The chip's background is *darker* than its
surroundings and the border disappears entirely; the one signal that says "this launch is off
base" is weakest on exactly the row you're about to ↵. Give `.changed` inside `.kb-focus` a
stepped-up treatment (full `goldFaint` fill + `gold @ 0.5` border, or invert to gold-on-surface2).

### P2. No overflow strategy for either column

Both columns render at natural height with no max-height or scroll. Five configs and five
harnesses already make 410px; the v1 open question about libraries growing past ~8 got no answer
in v2. Since the panel must fit inside a pane (S3), specify: columns scroll independently past N
rows, panel height caps at ~60% of pane height, kb-focus auto-scrolls into view.

### P3. Mock vocabulary drift

The claude effort menu offers `low / medium / high / deep`; "deep" is not a claude-code effort
tier, and the v1 design was careful that effort chips speak "the harness's own vocabulary." Mocks
teach implementers; use the real ladder (or the harness's real flag values) in the binding
prototype.

### P4. Prototype accessibility shape

`snapshot --interactive` over the prototype finds four real controls in the entire panel: every
row, dropdown, pin, gear, and close glyph is a div with a click handler. Fine for an HTML mock,
but carry the lesson into Swift: every row and dropdown needs a real accessibility element with a
role and label, both for VoiceOver and because c11's own validation pattern (computer-use agents
driving the UI) depends on the accessibility tree being honest.

---

## Answers to the README's open questions, from the audit's perspective

1. **Post-launch "save as configuration…" toast action?** Yes, and it does double duty: the S1
   default-change toast already has to exist; adding a second action word (`save as config…`) to
   the same toast when the launch had changed dropdowns costs no new surface and answers the mint
   path without touching the panel. Settings remains the only *deliberate* mint path.
2. **⌘⇧A centering.** Focused pane, yes, but only with the S3 pane-link ring; keyboard invocation
   has no click to anchor the association.
3. **Do tweaked harness launches become the default?** They should, or rule 6 grows an asterisk
   ("launch sets the default, except some launches"), which is exactly the kind of conditional the
   no-pin design was meant to kill. Represent it as an anonymous recipe: ● moves out of the config
   column entirely and the *harness row* carries the DEFAULT tag with its tweaked, gold dropdowns
   shown; the def-strip in Settings prints the resolved axes (`claude code · sonnet · low`). The
   recent strip then only appears when it differs from the default (S4) or to carry undo (S1).

---

## The three changes I would make before implementation starts

1. **Settle the keyboard/focus contract (B1 + B2 + S5) as one spec paragraph.** Recommended shape:
   panel takes focus on open with a visible unfocused fallback state; ↑↓ rows, ←→ into a harness
   row's dropdowns, ↵ opens/commits, esc peels one layer (dropdown → panel); recent strip in the
   traversal ring iff it survives S4. This is the difference between a panel that feels engineered
   and one that feels like a mock that shipped.
2. **Make the default-write visible at write time (S1 + S2).** Toast on default *change*, A-button
   tooltip always naming the effective default, Settings pins deleted so last-launched is the only
   writer. Rule 6 is a good bet only if every write is felt.
3. **Bind the panel to its pane geometrically (S3).** Clamp size to the pane, hold a goldFaint
   ring on the target pane while open, flash the launched row and lean on the tab-bar flash for
   launch confirmation. This is what makes "centered on the pane" mean something in a real
   thirty-agent layout instead of only in a one-pane mock.
