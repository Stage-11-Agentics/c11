# Waiting Agent + Workspace Nav Cluster

Design spec for replacing the current "Next Notification ⌥V" sidebar button with a two-row cluster: a renamed and restyled **Waiting Agent** button, plus a stacked pair of workspace-navigation arrows.

## Motivation

The existing "Next Notification" button has two problems:

1. **The label truncates** even on large displays ("Next Notifica… ⌥V"), so operators can't actually read the button they're meant to recognize at a glance.
2. **The solid yellow lit-state** is loud and fights the rest of the void-dominant chrome. It reads as a generic notification dot rather than something specifically Stage 11.

This redesign also adds positional workspace navigation (prev/next workspace) which currently has no visible affordance, surfacing a primitive that operators with many workspaces use constantly.

## Conceptual frame

Two ways an operator navigates workspaces, two controls:

- **Waiting Agent** — jump by *attention demand* (semantic, "take me to whoever needs me").
- **Up / Down arrows** — step by *position* (sequential, "let me scrub through these in order").

The two controls stack vertically as a cohesive cluster, sharing one rest-state visual language and two distinct active-state vocabularies.

## Layout

```
┌─────────────────────────────────────┐
│                                →    │  ← row 1: Waiting Agent
│  Waiting Agent                      │     (taller, full width)
│                              ⌥V     │
├──────────────────┬──────────────────┤
│        ▲         │         ▼        │  ← row 2: prev/next workspace
└──────────────────┴──────────────────┘     (shorter, split 50/50)
```

### Row 1: Waiting Agent

Full width, taller than row 2.

- **Left**: label "Waiting Agent", vertically centered.
- **Right column** stacks two glyphs:
  - **Top**: → sharp arrow. Action affordance, "this takes you somewhere." Full paper-white at rest.
  - **Bottom**: ⌥V keyboard shortcut. Smaller, paper-white at ~50% opacity (subdued).

### Row 2: Workspace navigation

Full width, shorter than row 1, split 50/50 horizontally.

- **Left half**: ▲ filled triangle, centered. No label.
- **Right half**: ▼ filled triangle, centered. No label.
- Tooltips on hover surface the existing prev/next workspace keyboard shortcuts.

## State and color language

One rest-state language across the entire cluster. Two different active-state languages, distinguished by state *duration*.

| State | Treatment |
|---|---|
| **Rest** (everywhere) | Void fill. Paper-white glyphs and labels. Subdued elements (the ⌥V shortcut) at ~50% opacity. |
| **Waiting Agent lit** (sustained: agent is waiting on operator) | Off-white paper fill, warm tone, ~85–90% brightness (e.g. `#E8E2D0` to `#DDD6C2`). All content (label, →, ⌥V) flips to void. ⌥V stays subdued at ~60% void opacity. Thin ~0.5–1px Stage 11 gold (`#F5C518`) hairline at the edge of the fill. **No motion** — the inversion does the attention work. |
| **Arrow hover or press** (momentary) | Gold stroke (~1.5px). Glyph also switches to gold. |
| **Arrow disabled** (at first/last workspace) | Paper-white glyph at ~30% opacity. No hover response. |

**Cluster-wide visual rule**

- Rest: paper-white-on-void.
- Momentary active (arrow hover/press): gold-stroke + gold-glyph.
- Sustained active (Waiting Agent lit): paper-fill inversion with thin gold hairline.

The visual logic: gold-stroke means "you're touching this, briefly." Paper-fill inversion means "this is in a different mode and you should look here." Different signal vocabularies for different signal durations.

## Behavior

- **▲ at top workspace** and **▼ at bottom workspace**: disabled. No wraparound — wrap on a sidebar list disorients because the scroll position lags the action.
- **Press-and-hold** on either arrow: auto-repeat for fast workspace scrubbing.
- **Waiting Agent button**: existing ⌥V keyboard shortcut and jump behavior are unchanged. This is a rename and a restyle, not a behavior change.

## Rename rationale

"Next Notification" → "Waiting Agent" because:

- It fits the operator:agent mental model the rest of c11 is built around.
- It eliminates the truncation problem at sidebar widths.
- It names the *destination state* the button takes you to, which is what operators care about.

Alternatives considered: "Next Agent" (more imperative but slightly imprecise), "Next Ping" (event-focused, but "ping" is overloaded). "Waiting Agent" won on clarity.

## Adaptive sizing

Two tiers when vertical space tightens:

- **Tier 1**: ⌥V chip on row 1 moves from visible to tooltip-only. Row 1 collapses to single-line height (label left, → right). Row 2 unchanged.
- **Tier 2**: both rows halve. Row 1 stays single-line, gets smaller. Row 2 triangles tighten.

Synchronous halving was considered and rejected because row 1 is intentionally taller (it has stacked right-column content), so halving both at the same rate doesn't map cleanly. Sacrificing the keyboard shortcut chip first preserves the row's primary content the longest.

## Implementation notes (designer's call, not blocking)

- **Exact off-white shade**: somewhere in the warm-paper range `#E8E2D0` to `#DDD6C2`. Dial against the live sidebar.
- **Container treatment**: whether the two rows share a rounded card outline or sit as two distinct buttons. Defaulting to *distinct* (matches the rest of the sidebar's button language), but worth eyeballing in-app.
- **Cluster anchor location**: replace the existing Next Notification button in place. Row 2 (arrows) sits directly below row 1.
- **Disabled arrow visual**: 30% opacity is a starting point; may need adjustment so the glyph still reads as present-but-inactive rather than nearly-invisible.

## Out of scope

- Any change to the keyboard shortcut itself (⌥V stays).
- Any change to the *behavior* of the existing Next Notification jump (just the name and visual).
- Color-customization or theming of the cluster (use the existing Stage 11 brand tokens, no new toggles).
- A third "urgent" tier of lit state (white-fill could be the future urgent treatment, but isn't part of v1).

## Decision provenance

Decisions captured during operator dialogue 2026-05-26:

- Rename to "Waiting Agent" (over "Next Agent", "Next Ping").
- Row 1 above, Row 2 (arrows) below.
- Off-white paper fill for lit state (over gold-stroke-on-void or muted gold).
- Thin gold hairline at the edge of the lit fill.
- → sharp arrow on row 1 (over ► triangle for glyph-family unification).
- Two-tier adaptive sizing (over synchronous halving or no responsive logic).
- Arrows: void fill, paper-white glyphs, gold stroke on hover.
