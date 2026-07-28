# c11 Agent-State Mark Vocabulary

The four lifecycle marks drawn beside every surface. Every state is distinguishable from
every other **by shape alone** — no reliance on color or opacity. Color is thereby free for
the flagged modifier (flat violet recolor), per `docs/c11-flagged-agent-plan.md`.
Suppression consumes no visual channel at all — it is a lifecycle projection, not a
treatment (see below).

## The set

Idiom: a hard-edged 9pt terminal cell. The structural logic in one sentence: **the mark shows
what is inside the cell — full of output, holding a payload, empty, or collapsed.**

| State | Mark | Why the shape carries the state |
|---|---|---|
| `working` | 3×3 grid of dots over a faint base square | a cell full of typed output; identically the end state of the animated fill |
| `waiting` (needs attention) | heavy hollow frame holding a solid core | a stopped frame — same family as idle — with a payload inside for the operator; waiting is literally derived from an unread notification, and the core is the unread thing |
| `idle` | thin hollow frame | a stopped, empty cell: process present, nothing inside |
| `cold` | flat line | the collapsed cell: no process |

Priority order for any UI that ranks states: **needs attention · working · idle · cold.**

### Geometry (9pt cell)

- **working** — base: full 9pt square in the mark color at 25% opacity. Dots: 3pt pitch,
  2pt square dots, 0.5pt inset within each 3pt sub-cell.
- **waiting** — 1.5pt frame stroke, 1pt gap, 4pt solid core, all concentric.
- **idle** — 1pt frame stroke.
- **cold** — 9×2pt line, vertically centered in the cell.

The waiting frame is deliberately heavier than idle's (1.5pt vs 1pt) so the highest-priority
state also carries the most stroke weight.

**Marks render at 9pt, always.** The sidebar must not compress marks to 8pt in crowded
workspaces; the mark row's slot floors at 9pt and the row yields width instead. The marks are
the signal — they are not the element that shrinks.

Every state occupies the same uniform slot so titles never shift horizontally on state change.

### Colors

Unchanged — dark theme values from `Sources/Workspace.swift` (`workspacePulseColors`):
working `#E8E8E8`, waiting `#D0AA45` gold, idle `#9AA0A9`, cold `#62676F`.
Color remains the fast day-to-day read — redundant reinforcement rather than the
load-bearing channel.

## Behavior under the modifiers

**Flat violet recolor (flagged).** All four marks remain mutually distinguishable: dotted
grid, frame+core, empty frame, line. In particular, flagged-and-working and
flagged-and-needing-attention are structurally distinct — the recolor is lossless.

**A flag arrives from either side, and it round-trips.** The operator may flag an agent at
dispatch — a critical mission they want to watch — or an unflagged agent may, rarely, flag
itself mid-run when it hits an urgent issue only a human can clear or one whose blast radius
crosses agents. Either way the marks snap violet at that moment, mid-lifecycle, whatever
state they are in; and when the flag lowers (attention received), the marks return to normal
lifecycle colors. A flag can scope to a moment (one decision, then back) or to a whole
mission (flagged at dispatch, violet for its lifetime). Nothing about a mark is pre-declared
as "flag-capable," and the working expectation is that **at least nine in ten agents never
carry a flag** — rarity is what the tier's visual strength is buying.

**Flagged + needs attention is the alarm.** The one combination where the agent has both
raised a flag and stopped for the operator flashes its **core violet↔white** — a hard square
wave, 0.4s cycle, no easing — inside a steady violet frame. The frame holding still keeps the
mark's shape identity legible mid-flash; the payload is the thing that strobes. It runs
**regardless of the Static marks setting**: flag-tier motion is the standing exception to
the static-set rule, and this is
its strongest form. White is admitted into the vocabulary here and only here — the flag tier
is exactly what that intensity is reserved for. For the other flagged combinations
(flagged-and-working, -idle, -cold) the mark breathes as the flagged-agent plan specifies;
the waiting combination alone flashes instead of breathing.

**Suppressed: a lifecycle projection, not a treatment.** A suppressed surface **never enters
the waiting state**; the record survives even though the state does not. Its mark renders in
normal lifecycle colors and only ever shows **working, idle, or cold** — on stop it reads
idle, while the notification record still lands in the store. There is **no visual indicator
of suppression at all**: a suppressed idle mark and an ordinary idle mark are identical.
That is deliberate — suppression is a promise of visual silence, and a badge would partly
break it; `get-metadata` is the record of the modifier. The glance-read given up: a
suppressed agent that finished is indistinguishable in the sidebar from one that was always
idle; the notifications list remains the record of what it would have said.

The natural fit for suppression is **subagents under an orchestrator**: the orchestrator is
the party watching them, so the operator's sidebar stays quiet while the coordination happens
one level down. A suppressed subagent that hits a genuine emergency still has the flag, which
overrides suppression entirely.

Implementation-wise this is a simplification: suppression filters in the pulse projector
(the state simply never resolves to waiting), a pure function covered by `c11-logic` tests,
and neither renderer builds a dim modifier at all. The signal-layer filtering in
`TerminalNotificationStore` (badge, ⌥V jump, events) stands unchanged.

**The flag tier overrides suppression outright.** A suppressed agent that raises a flag
renders the full flag treatment — violet marks, true lifecycle state, and the violet↔white
alarm flash when it is also waiting. Anything less breaks the feature's headline promise:
*do not tell me when you finish, do tell me if you get stuck.* Suppression governs unflagged
marks only.

## Animation (default) and the "Static marks" setting

**Marks animate by default.** Settings exposes a **Static marks** option that disables
base-set motion and renders every state in its static form. (Flag-tier motion and the Reduce
Motion override follow their own rules below, regardless of this setting.) Animation touches
exactly two states:

- **working** — the dots tick in, typewriter order: bottom row left→right, then the next row
  up, like text being typed. One dot per beat, nine dots over ~3.6s, hold full, hard reset;
  4s total cycle. Hard cuts, no fades — cells appear, they do not fade in. The faint base
  square is always present, so a partially-filled working mark keeps its full footprint and
  cannot be misread as a suppressed mark.
- **needs attention** — the core dips: opacity 1.0 → 0.15 → 1.0 on a 1.2s ease cycle. The
  frame never moves. Opacity only, never scale.

The resulting motion hierarchy is the point: the fastest-moving thing in the sidebar is
always the agent that needs the operator; working ticks along slowly behind it; everything
else is still.

Rules:

- **Idle and cold never animate.**
- **Suppressed unflagged marks never animate**, even under the animated default — motion is
  a signal, and suppression is the promise not to signal. A suppressed working mark renders
  the static full grid. A raised flag overrides suppression (see above), so a
  suppressed+flagged+waiting mark still flashes at full strength.
- **Reduce Motion is a hard override.** When
  `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true, no mark animates at
  all — fill, dip, breathe, and the alarm flash included; every state renders its static
  form. For accuracy of obligation: the 2.5 Hz flash is below the 3-per-second general flash
  threshold and a 9pt mark is far below the area threshold, so this is a comfort/preference
  obligation rather than a seizure-risk one. It is still not optional.
- **Flag-tier motion replaces the core dip.** A flagged-and-waiting mark shows the
  violet↔white alarm flash; other flagged states breathe. In no case does the dip run
  concurrently — two opacity cycles never stack, and flag motion and base motion live in
  separate view layers so a future change cannot accidentally multiply them (same constraint
  the flagged-agent plan places on breathe × dim).

### Performance contract

The base set stays draw-once-per-state-change; the setting must not regress typing latency:

1. Each animated mark is **leaf-isolated** — its own small view owning its animation phase
   (driven by the shared clock of item 5, never a per-mark timer), so repaints cannot
   invalidate the tab row or workspace card (`TabItemView` relies on `Equatable` +
   `.equatable()` to skip body re-evaluation during typing).
2. The dot fill repaints **once per beat** (~2.5 fps), not per frame. The dip is a continuous
   opacity tween but is the same class as the already-approved flagged breathe. The alarm
   flash is a square wave — two repaints per 0.4s cycle on a mark that is rare by
   construction — and, like the breathe, it runs even with Static marks enabled.
3. Animation gates on a **typing-latency check on a tagged build** before merge — and with
   animation on by default, this gate is a hard blocker, not a formality: the fill runs on
   every working mark in every session unless the operator opts out. If the fill fails the
   gate, the default degrades to dip-only; if the dip also fails, the default becomes the
   static set (the Static marks toggle then simply has nothing to disable). Flag-tier motion
   runs regardless of the setting, so none of that ladder is a fallback for it: if flag
   motion fails the gate, the flagged mark ships **static violet** — the color carries the
   state, motion is an amplifier, not the signal.
4. **Measure at fleet scale.** Every working agent animates in two renderers simultaneously
   (bonsplit tab chip + sidebar card mark row), so a 20-agent fleet is 40+ independently
   animating leaf views repainting while the operator types. A single-mark latency test
   passes trivially and proves nothing; the gate runs against a realistic fleet.
5. **One shared clock, per-mark phase offset.** N marks owning N timers is both more
   expensive and visually worse than one app-level tick every mark reads. Offset each mark's
   phase by a stable hash of its surface id so the fleet staggers instead of pulsing in
   unison: one timer, coalesced repaints, scattered appearance.
6. **Pause off-screen and in background.** Unselected workspaces, collapsed panes, tabs
   scrolled out of the tab bar, and app-not-active all stop animating. SwiftUI does not do
   this for you; animating what nobody can see is pure battery burn at fleet scale.
7. **Validate the ladder order empirically.** The dip-before-fill degradation order is
   probably right for a reason worth stating: the dip is a pure opacity change on a static
   shape, which the render server can composite without re-evaluating view bodies, whereas
   the dot fill changes which shapes are drawn and forces body re-evaluation every beat. The
   continuous animation is plausibly the cheap one and the discrete one the expensive one —
   counterintuitive, and *probably* rather than certainly. Measure both independently rather
   than assuming.

## Call sites

Two renderers must change in agreement, plus the sidebar sizing rule:

1. **`vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift`** —
   `TabActivityMark` (the surface-tab chips) and `TabActivityMarkMetrics`. This vocabulary
   is what makes the file's doc comment — "survives greyscale and a color-blind reader" —
   accurate; keep the comment and the code in agreement. Keep the bonsplit
   change pure shape vocabulary with no c11-specific concepts — it is a clean accessibility
   fix to offer upstream (almonk/bonsplit via manaflow-ai/cmux).
2. **`Sources/ContentView.swift`** — `workspacePulseMark` (the sidebar workspace-card marks),
   plus the sidebar sizing at the `min(9, slot)` call site (~line 11324): marks pin to 9pt
   and the slot floors at 9pt instead of compressing to 8pt.

Colors (`Sources/Workspace.swift`) are untouched. The "Static marks" setting is a user
default (animation on unless set) consumed only by the two renderers' leaf views.
