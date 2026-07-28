# Flagged and Suppressed Agents

Design spec for two modifiers on the existing attention model: **flagged** agents that explicitly request human involvement and jump the queue, and **suppressed** agents that produce no routine attention signal unless a flag overrides suppression.

## Motivation

Waiting works. Every agent eventually goes quiet, the sidebar lights gold, and the operator sweeps them with ⌥V. That is the right default and it does not change.

But waiting is a flat tier, and it applies uniformly. Two failures follow:

1. **Nothing rises.** In a fleet of ten agents, the one genuinely blocked on a human decision is indistinguishable from the nine that merely finished a turn. The operator opens each to find out which is which, and that scan cost grows linearly with fleet size, which is exactly the scale c11 is built for.
2. **Nothing stays quiet.** An agent fired off to run a long sweep eventually finishes and lights the sidebar, demanding attention it does not need. Every such agent is a false positive that trains the operator to trust the signal less.

A **flag** is the agent saying: *work has stopped and only you can restart it.*
**Suppression** is the operator saying: *keep working, just do not tell me about it.*

## The model: two orthogonal modifiers over one lifecycle

The existing lifecycle (`working` / `waiting` / `idle` / `cold`) is unchanged and remains the substrate. Flagged and suppressed are **modifiers over it**, not new lifecycle states:

| Field | Type | Set by | Meaning |
|---|---|---|---|
| `flag` | reason string, or none | agent mid-run, or operator at dispatch | a human must act, or this mission is one the operator intends to watch |
| `suppressed` | Bool | operator (usually at dispatch) or agent | routine attention is withheld; a direct flag escalation still reaches the operator |

A flagged agent still has a full lifecycle: it can be flagged-and-working, flagged-and-idle, flagged-and-waiting. Flagging qualifies the state without replacing it. Suppression works differently: it *restricts* which states are reachable, barring needs-attention entirely (below).

**A suppressed agent can still raise a flag, and that combination is the most valuable one in the feature.** "Do not tell me when you finish, do tell me if you get stuck" is the overnight sweep, the long migration, the background research run. A linear `suppressed | normal | flagged` enum cannot represent it. Two modifiers can.

### A suppressed surface never enters the waiting state

This is the load-bearing rule. Suppression restricts the lifecycle to `working` / `idle` / `cold`. On stop, a suppressed surface reads **idle**, never needs-attention.

| | Suppressed, unflagged surface |
|---|---|
| Lifecycle state | `working` / `idle` / `cold` only; **never** `waiting` |
| Sidebar mark | rendered in **normal lifecycle colors**, no dimming |
| Waiting count / Waiting Agent button | **excluded** |
| ⌥V destination | **excluded** |
| Routine waiting-derived system notification | **not delivered** |
| Direct `flag.raise` system notification | **delivered when flagged** |
| `waiting.entered` event | **not emitted** |
| Notification store record | **written**, readable in the notifications list |

Once that surface raises a flag, the flag tier overrides every restriction in
this table, including waiting reachability, `waiting.entered`, ⌥V priority, and
direct external delivery.

**Known cost, accepted deliberately.** A suppressed agent that finished and one that stalled both read as idle. The glance-read of "this one is done" is given up; the notifications list remains the record. This is the trade the operator opts into by suppressing, and it is the price of the mark never implying a demand the operator asked not to receive.

The word remains **suppressed** rather than silent because the record survives even though the state does not. The agent has something to say; it was written down instead of shown.

**Opacity is now a completely free channel**, unused by lifecycle, flagged, or suppressed. Worth knowing as headroom before anyone spends it.

## Flagged

### Semantics

|  | Waiting | Flagged |
|---|---|---|
| Origin | derived from an unread notification | explicitly declared by the agent |
| Reason | optional | **required**, one line, surfaced everywhere |
| Clears when | operator reads it | operator dismisses it, or the agent lowers it |
| Reaches | in-app sidebar | in-app sidebar, in-surface banner, system notification |
| Expected frequency | constant | rare |

**Waiting is derived; flagged is declared.** That is the load-bearing distinction. Today `TerminalNotificationStore` fires `waiting.entered` on the per-tab unread 0→1 edge (`Sources/TerminalNotificationStore.swift:702`); no agent ever says "I am waiting." A flag exists only because an agent asserted it, and persists until someone acts.

**Sticky-until-acted-on is the whole point.** If glancing at the pane clears a flag, the tier degrades back into waiting within a week of real use.

**A flag is independent of run state.** An agent can raise one mid-turn and keep working. The flag says a human is needed; the lifecycle says what the process is doing. Both are true at once.

**A flag arrives from either side and it round-trips.** The operator may flag at dispatch (a critical mission they intend to watch), or an agent may flag itself mid-run on a blocker or an issue whose blast radius crosses agents. Marks snap violet at that moment, whatever lifecycle state they are in, and return to normal lifecycle colors when the flag lowers. Scope is either a moment (one decision, then back) or a whole mission (flagged at dispatch, violet for its lifetime).

**Rarity is the design target: at least nine in ten agents should never carry a flag.** The tier's visual strength is bought entirely by its scarcity. This is a stated expectation, not an enforced limit.

### Primitive

```
c11 raise-flag --surface "$C11_SURFACE_ID" "Need a call on schema migration vs dual-write"
c11 lower-flag --surface "$C11_SURFACE_ID"
c11 launch-agent ... --flag "<reason>"      # operator flagging a mission at dispatch
```

Socket methods `flag.raise`, `flag.lower`, `flag.list`. The reason is required on raise; a raise without one is `invalid_params`, not an empty string.

Backed by a canonical metadata key at the `explicit` tier in `SurfaceMetadataStore` (joining `status`, `task`, `role`, `model`, `progress` at `Sources/SurfaceMetadataStore.swift:13`), so it persists across relaunch on the path that already exists and round-trips through `get-metadata` without new persistence code.

**A flag does not write to `TerminalNotificationStore`.** If it did, the workspace would count as both waiting and flagged and the pulse would double-count. The system notification is delivered directly off the raise.

### Lowering

Either party can lower. In practice the operator will do it almost every time.

- **Operator dismiss** (the banner X, below) emits `flag.lowered` with `by: "operator"`.
- **Agent lower** emits `flag.lowered` with `by: "agent"`. Rare: the agent unblocked itself, or the question went stale.

The `by` field matters. An agent whose flag is dismissed without an answer can distinguish "seen and deferred" from "nobody looked," and decide whether to re-raise. Without it, a dismissed agent sits blocked forever assuming it was never seen.

Terminal input does not auto-lower in v1. Explicit dismissal only, so a stray keystroke cannot silently discard the signal.

## Suppressed

### Primitive

```
c11 suppress --surface "$C11_SURFACE_ID"
c11 unsuppress --surface "$C11_SURFACE_ID"
c11 launch-agent ... --suppressed          # the common case: set at dispatch
```

Socket methods `flag.suppress`, `flag.unsuppress` (same domain; the two modifiers are one attention model). Stored as a canonical metadata key alongside the flag, persisting on the same path.

The dominant path is operator-set at dispatch. Agent-set suppression is legitimate (a long autonomous sweep declaring itself background work) but expected to be rarer.

**The shape this serves is orchestrator and subagents.** An orchestrator dispatches a fleet of workers it will collect from itself; the operator wants the orchestrator's signal, not thirty completion pings from its children. Suppressing the subagents is what makes that fleet legible.

Suppression never suppresses a flag. It is a promise not to interrupt routinely, not a gag.

### Implementation

Suppression filters in two places, and the notification record survives both.

**In the projector.** A suppressed surface never resolves to `.waiting`; it falls through to `working` / `idle` / `cold`. This is a pure-function change covered by `c11-logic` tests, and it is what makes the mark correct with no dim modifier to build.

**In the notification store's signal layer.** `TerminalNotificationStore.unreadCount` drives the Waiting Agent badge directly, and `emitWaitingEdges` fires on the raw per-tab unread edge. Suppressed surfaces must be excluded there too, while their notifications stay in the array:

- A **signal-eligible unread count** distinct from raw unread, computed in `buildIndexes` (`Sources/TerminalNotificationStore.swift:638`).
- `emitWaitingEdges` firing on the signal-eligible edge, so a suppressed agent's completion emits no `waiting.entered`.
- `jumpToLatestUnread` (`Sources/AppDelegate.swift:10361`) skipping suppressed surfaces.

The notification itself is still written and still readable in the notifications list. Only its contribution to state and to signalling is filtered.

## Glyphs

### Prerequisite: the mark vocabulary rebuild

**This feature depends on `docs/c11-mark-vocabulary.md` landing first.** That is a separate ticket and it must merge before this one.

The old vocabulary could not carry these modifiers. Working and waiting were both solid squares separated by hue alone, so the flagged violet recolor would have collapsed them into one indistinguishable mark. (The in-code comment claiming the set "survives greyscale and a color-blind reader" was already false for that pair; fixing it is a real accessibility repair independent of this feature, and the bonsplit half is upstream-clean.)

The rebuilt set carries lifecycle in **shape alone**, which frees color for the flagged recolor (and leaves opacity unspent):

| State | Mark |
|---|---|
| working | 3×3 dot grid over a faint base square |
| waiting (needs attention) | 1.5pt heavy frame holding a 4pt solid core |
| idle | 1pt thin empty frame |
| cold | flat 2pt line |

**Marks pin to 9pt always.** The old `min(9, slot)` compression to 8pt is removed; the mark row's slot floors at 9pt and the row yields width instead. The marks are the signal, not the element that shrinks.

### Flagged: recolor, do not replace

**A flagged agent uses the same mark vocabulary as any other agent, rendered violet.** Flagged-and-working, flagged-and-idle, flagged-and-needing-attention are all meaningful, all render, and all stay mutually distinguishable under the flat recolor: dot grid, frame plus core, empty frame, line.

No information is lost to the recolor. This supersedes the earlier accepted working/waiting collapse, which was an artifact of the old vocabulary.

### Suppressed: restrict the lifecycle, change nothing visual

Suppression has **no visual treatment of its own**. A suppressed surface renders the standard mark for whatever state it is in, in normal lifecycle colors:

| Suppressed state | Mark |
|---|---|
| suppressed + working | dot grid, working color |
| suppressed + idle | thin empty frame, idle color |
| suppressed + cold | flat line, cold color |
| suppressed + waiting | **unreachable** — a suppressed surface reads idle on stop |

The suppression is expressed entirely by which states are reachable, not by how they are drawn. Frame-plus-core, the needs-attention mark, simply never appears on a suppressed surface unless a flag raises it.

**A flag overrides suppression outright.** A suppressed agent that flags renders the full violet treatment, including the core-only alarm flash when it stops (see Motion).

**Suppressed marks never animate** *while unflagged*. In practice this only binds on `working`, since idle and cold never animate anyway.

**No indicator distinguishes a suppressed surface from an ordinary one at rest.** A suppressed idle mark and an ordinary idle mark are identical. This is deliberate: suppression is a promise of visual silence, and any badge marking a surface as suppressed would partly break it. The operator's knowledge of what they dispatched, plus `get-metadata`, is the record.

### Motion

Base motion is **on by default**, with a **Static marks** opt-out in Settings (`docs/c11-mark-vocabulary.md`): working dots tick on a ~4s cycle, the needs-attention core dips on a 1.2s cycle.

**Flag-tier motion runs regardless of that setting**, in two forms:

| Flagged state | Motion |
|---|---|
| flagged + waiting | **core only** flashes violet↔white, hard square wave, 0.4s, no easing, inside a steady violet frame |
| flagged + working / idle / cold | breathe (slow opacity cycle) |

The frame holds still deliberately. Shape is the load-bearing channel in the rebuilt vocabulary, and the frame is this mark's shape signature; keeping it steady means the mark stays identifiable at every point in the cycle rather than momentarily reducing to a flat white square.

The flash supersedes the breathe for the waiting combination only, and replaces the needs-attention core dip. Two opacity cycles never stack; flag motion and base motion live in separate view layers so a future change cannot accidentally multiply them.

The escalation is the point: static violet says a flag is up, breathe says a flag is up on a live agent, the flash says the agent is flagged *and stopped*, which is the state where nothing moves until the operator acts.

#### Flag tier overrides suppression completely

`docs/c11-mark-vocabulary.md` states that suppressed marks never animate, and suppression otherwise bars the needs-attention state entirely. **Both rules yield to a flag.** A suppressed agent that raises a flag and stops reaches needs-attention and shows the full core-only violet↔white flash.

Suppression is a promise about routine signalling. The headline case for the whole feature is "do not tell me when you finish, do tell me if you get stuck," and a suppressed flagged-waiting mark held at idle would break exactly that promise. Where the rules meet, the flag wins outright: violet frame, flashing core, no state restriction, no motion suppression.

#### Reduce Motion is a hard override

When `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true, no mark animates, including the flagged breathe and the alarm flash, regardless of any setting. The static violet mark and the flagged sidebar row carry the signal without motion, so nothing is lost.

The flash itself is within safety thresholds (2.5 Hz is below the 3-per-second general flash threshold, and the flashing region is a 4pt core, far below the area threshold), so this is a comfort and preference obligation rather than a seizure-risk one. It is still not optional.

#### Latency gate and fallback

Constraints inherited from the vocabulary doc's performance contract:

1. **Leaf-isolated.** Own `@State` in its own small view so repaints cannot invalidate the workspace card or reach the tab row. `TabItemView` relies on `Equatable` + `.equatable()` to skip body re-evaluation during typing (`CLAUDE.md`, typing-latency-sensitive paths).
2. **Opacity and color only, never scale.** Scale forces layout every frame.
3. **Gated on a typing-latency check on a tagged build before merge.**

**Default-on changes the perf regime, and the gate is now a hard ship blocker.** Four additions the contract needs that an opt-in default did not:

**Measure at fleet scale, not with one mark.** Every working agent animates, in *two* renderers at once (the surface-tab chip and the sidebar card mark row). A twenty-agent fleet is forty-plus independently animating leaf views repainting continuously while the operator types. A single-mark latency test passes trivially and proves nothing. The gate runs against a realistic fleet.

**One shared clock, per-mark phase offset.** N marks owning N independent timers is both more expensive and visually worse than one app-level tick every mark reads from. Offset each mark's phase by a stable hash of its surface id so the fleet staggers instead of pulsing in unison: one timer, coalesced repaints, scattered appearance.

**Pause off-screen and in the background.** Marks in unselected workspaces, collapsed panes, or tabs scrolled out of the tab bar must not animate. Neither should anything while the app is not active. SwiftUI does not do this for you, and animating what nobody can see is pure battery burn at fleet scale.

**Validate the ladder order empirically.** The stated degradation is dip-only default, then static default. That is likely correct for a structural reason: the dip is a pure opacity change on a static shape, which the render server can composite without re-evaluating body, whereas the dot fill changes *which shapes are drawn* and forces body re-evaluation every beat. Likely, not certain. Measure both independently rather than assuming the cheaper one is the one that survives.

**Flag-tier motion needs its own fallback, because the opt-out is not one.** Static marks disables base motion only; flag motion runs regardless. If it fails the latency gate the fallback is explicit: **the flagged mark ships static violet.** The violet carries the state; motion is an amplifier, not the signal.

## Surfaces

### 1. Sidebar row

A **Flagged Agents** row above the existing Waiting Agent row in the cluster (`SidebarWaitingAgentCluster`, `Sources/ContentView.swift:10695`).

**The row appears only when at least one flag is up.** A permanent third button spends sidebar height forever on a rare state, and a new element *appearing* in the sidebar is a stronger signal than an existing button changing color. Zero flags, zero footprint.

Treatment: violet fill, void content, thin hairline, no motion (the row is large enough that fill alone carries it; motion belongs on the small marks).

### 2. One key, two-phase priority

**⌥V keeps its exact binding and gains a priority phase.** It already means "take me to whoever needs me most"; flags are a higher class of that, not a different question. One key, one point of interaction.

```
⌥V  ->  oldest unlowered flag, if any
    ->  else latest signal-eligible unread   (today's behavior, unchanged)
```

**Flags jump oldest-first; waiting stays latest-first.** A flag up for twenty minutes is more starved than one raised ten seconds ago. Flags are a queue; waiting is a stack.

The flagged sidebar row is a display carrying the count. Clicking it performs the same prioritized jump, so the two rows never disagree about where ⌥V goes.

### 3. In-surface banner

When the operator arrives at a flagged surface, the reason is visible without opening anything, with an X to dismiss.

**Mount it in the AppKit portal overlay layer, floating over terminal content.** Use the pattern the find overlay already uses: `NSHostingView<SurfaceSearchOverlay>` mounted from `GhosttySurfaceScrollView` (`Sources/GhosttyTerminalView.swift:6824`).

A banner in the layout flow above the terminal would resize the PTY on every raise and lower. That garbles TUI rendering in Claude Code and codex mid-run, a self-inflicted bug on a feature whose entire purpose is to interrupt cleanly. The overlay costs no reflow.

Position at the top edge under the surface title bar so it reads as a title-bar banner without being one. `SurfaceTitleBarView` itself is too thin for a sentence of reason text and already carries the description block.

Content: flag glyph, reason string, X. Clicking X lowers the flag.

### 4. System notification

A **flag raise** fires a `UNUserNotification` through the existing delivery path: surface title as the notification title, reason as the body. Waiting stays in-app only; a flag is exactly the signal that should reach the operator in another application.

Suppressed unflagged surfaces deliver no routine waiting-derived system
notification. The separate direct notification emitted by `flag.raise` is
exempt: a flag overrides suppression completely and therefore delivers even
when the surface is suppressed. This exception is centralized at the direct
flag-delivery call site; it does not make suppressed notification-store records
signal-eligible on their own.

v1 uses the existing notification sound setting. A dedicated flag sound is a reasonable follow-up, not a launch requirement.

## Color

**Violet, `#9D8AD9` as a starting point.**

Our gold is `#c9a84c` (`Sources/BrandColors.swift:17`), a muted antique gold rather than a bright yellow. The flag color sits next to it in the same desaturation register, on the opposite side of the wheel. It reads as a cousin of the gold, not an intruder. The mark-level violet may need a separate brighter value to hold up at 8pt against the `#E8E8E8` working mark; dial both against the live sidebar.

Rejected alternatives:

- **Cyan.** A saturated cyan clashes with a desaturated antique gold, and ANSI cyan is ubiquitous in terminal output. The flag banner floats over live terminal content, so a cyan banner over cyan text is a legibility bug waiting to happen.
- **Red / ember.** Most universally legible as urgent, and semantically wrong. A flag is not an error. Red says "this agent failed" when the meaning is "this agent needs you."
- **Paper-white** (`#E8E2D0`, reserved at `c11-waiting-agent-cluster-plan.md:108`). On-palette, but it collides with the paper-white used throughout the chrome as ordinary foreground, so it reads as emphasis rather than a distinct state.

Violet is also the rarest hue in a dev environment, and rarity is precisely what an escalation tier is buying.

## Projector

`WorkspacePulseState` keeps its four cases. Flagged and suppressed become **modifier fields on `WorkspacePulseAgent`** rather than new lifecycle cases, so the mark renderer receives (state, flagged, suppressed) and composes.

`WorkspacePulseSummary` gains `flaggedCount`. The `dominant` ladder puts any flagged agent above waiting. Suppressed surfaces are excluded from `waitingCount` but keep their true state on the agent record.

These are pure functions with no `UserDefaults` dependency, so the entire precedence and composition change is covered by fast logic tests in `c11-logic`.

## Events

Additions to the v1 taxonomy (`Sources/Events/EventEnvelope.swift:51`):

```
flag.raised       payload: { reason: String }
flag.lowered      payload: { by: "operator" | "agent" }
flag.suppressed   payload: { by: "operator" | "agent" }
flag.unsuppressed payload: { by: "operator" | "agent" }
```

This is what makes the attention model consumable outside the app. Overwatch can tail `c11 events tail` and route a flagged agent across workspaces without polling screens, and a cron sweep can escalate a flag that has been up for an hour.

## Skill contract

**The exact section is written and staged at `docs/c11-attention-model-skill-section.md`.** It drops into `skills/c11/SKILL.md` in the PR that ships the primitives, not before, since it documents commands that must exist when agents read it. Landing instructions are at the top of that file, including the `scripts/sync-installed-skills.sh c11` hard rule from `CLAUDE.md`.

What it covers, and why:

**When to flag.** Only when work has *stopped* and only a human can restart it. "I finished, please review" is waiting. "I need a call on schema migration versus dual-write and I cannot proceed either way" is flagged.

**Default posture.** If the operator is in the conversation with you, ask them directly; the flag is unnecessary. If you were dispatched and left alone, the flag is your channel back.

**Flag authority is granted at dispatch, not requested at raise.** An orchestrator launching high-priority work says "flag me if you get blocked" in the launch prompt. Requiring an agent to ask permission before raising a flag collapses on itself: an agent that can ask permission can just ask the question, so the only agents permitted to flag would be the ones that do not need to.

**Suppression does not gag you.** If you were launched suppressed and you hit a genuine blocker, raise the flag. Suppression is a promise not to interrupt routinely, not a prohibition on emergencies.

No enforcement mechanism, no soft cap, no rate limit. Scarcity self-regulates because a flag interrupts the operator, and an agent that interrupts for nothing gets told so. The skill states the target (at least nine in ten agents never flagged) as an expectation rather than a limit.

## Out of scope

- Flag priority levels. One tier. Adding levels inside the escalation tier defeats the escalation tier.
- Age-based visual escalation. Flags do not decay or change appearance with age in v1. `SidebarDecayClock` stays untouched.
- Auto-lower on terminal input.
- A dedicated flag notification sound.
- Cross-workspace flag aggregation in the UI. The events stream carries this for Overwatch; c11's own chrome stays workspace-local.
- Workspace-level suppression. Suppression is per-surface in v1.
- A predictive "this agent will need you soon" signal. Genuinely useful, deliberately not this, and it must not wear the flag color.

## Dependencies

**`docs/c11-mark-vocabulary.md` must land first.** It rebuilds the four lifecycle marks so they carry state in shape alone, pins marks to 9pt, and defines base motion plus the Static marks opt-out. Every glyph claim in this document assumes that vocabulary. It ships as its own ticket, touching `TabActivityMark` in vendored bonsplit (shape-only, upstream-clean) and `workspacePulseMark` plus the sidebar sizing rule in `Sources/ContentView.swift`.

## Decision provenance

Operator dialogue 2026-07-28:

- Flag is sticky, cleared by operator dismissal (banner X) or by the agent.
- Both parties can lower; agent-initiated lowering expected to be rare.
- Dedicated sidebar row above Waiting Agent, appearing on demand.
- System notification approved for flags.
- Scarcity left to self-regulate via skill guidance, no enforcement.
- Suppressed agents added as the complement: fired-off work that should not signal on completion.
- ⌥V unified rather than split across two shortcuts: one point of interaction, flags first, then waiting.
- Flag color: violet chosen over cyan.
- Both additions modeled as orthogonal modifiers over the existing lifecycle rather than as new lifecycle states, so a suppressed agent retains the ability to flag and a flagged agent retains a readable lifecycle.
- Flagged renders the existing mark vocabulary recolored violet, not a single new mark; the resulting working/waiting collapse inside the violet family is accepted.
- Dotted-stroke suppressed mark proposed and rejected on legibility; suppression became an opacity modifier.
- "Suppressed" adopted over "silent": the notification record survives even though the state does not.
- Suppression revised (later in the same dialogue) from a dimmed treatment to a lifecycle restriction: normal colors, `working`/`idle`/`cold` only, never needs-attention, reading idle on stop. The dimmed-mark treatment and the "done, would have pinged you, did not" glance-read are superseded and deliberately given up; the notifications list is the record. Opacity returns to being a free channel.
- Base mark vocabulary rebuilt as a prerequisite ticket rather than accepting the violet recolor collapse. The collapse section and flagged-state table from the earlier draft are superseded; see `docs/c11-mark-vocabulary.md`.
- Base motion folded into the vocabulary doc's mark-motion setting; flag-tier motion runs regardless of it.
- Motion default flipped to **on**, with a Static marks opt-out replacing the earlier opt-in toggle. The typing-latency gate becomes a hard ship blocker, measured at fleet scale, with a dip-only then static degradation ladder.
- Flags finalized as arriving from either side (operator at dispatch, or agent mid-run), round-tripping back to normal lifecycle colors on lower, and scoping to either a moment or a whole mission. Target rarity stated as at least nine in ten agents never flagged.
- Suppression framed as the orchestrator/subagent pattern: suppress the children so the orchestrator's signal is the one that reaches the operator.
- Skill section authored and staged at `docs/c11-attention-model-skill-section.md` for landing in the feature PR.
- Flagged-and-waiting escalated to a violet↔white hard square-wave flash on the core only, inside a steady violet frame; other flagged states breathe. White enters the palette at the flag tier only.
- Flagging established as a runtime transition: marks run normal lifecycle colors and snap violet the moment the agent raises its flag, mid-lifecycle.
- Flag tier resolved to override suppression outright, settling the collision between "flags survive suppression" and "suppressed marks never animate."
- Reduce Motion added as a hard override over every mark animation including the alarm flash.
- Static violet named as the explicit fallback if flag-tier motion fails the typing-latency gate, since the Static marks opt-out does not disable it.
