# The Void Popover Aesthetic

*An aesthetic guide distilled from the model-picker popover (C11-175/181) — the A-button launch
picker and its tier-2 configure sheet. This is the look the operator called out as worth applying
elsewhere in the app. Canonical sources: `docs/design-prototypes/model-picker/index.html` (binding
prototype), `Sources/AgentPickerView.swift` (`PickerPalette`), `Sources/BrandColors.swift`, and
`company/brand/visual-aesthetic.md` upstream of all of it.*

---

## 1. The feel, in one paragraph

Void-first, gold-scarce, monospace throughout. The surface is nearly black; structure comes from
hairline rules and two barely-lighter grays, not from cards or fills. Gold is a *signal*, never a
decoration: it marks the default, the selection, the focused row, the one number that matters.
Everything else speaks in a five-step gray ladder. Type is small, light (300), and disciplined —
hierarchy is built from size, weight, letterspacing, and uppercase tracking rather than color
variety. Motion is nearly subliminal: 130–160 ms entrances, 1.1–1.4 s decay flashes for "something
just happened here."

## 2. Palette

### Core tokens (`BrandColors` — the shared, canonical layer)

| Token | Hex | Role |
|---|---|---|
| `black` | `#000000` | The void. Window and terminal ground. |
| `surface` | `#0a0a0a` | Chrome ground: popovers, sheets, sidebars, tab bars. |
| `rule` | `#333333` | Hairline borders and separators. |
| `dim` | `#555555` | Secondary/tertiary text, inactive icons, labels. |
| `white` | `#e8e8e8` | Primary text. Never pure white. |
| `gold` | `#c9a84c` | The accent. See §4 for the discipline. |
| `goldFaint` | `gold @ 0.20` | Selected-row fill, accent borders. |
| `paperFill` | `#E8E2D0` | (Reserved; not used in this surface.) |

### Popover-local extensions (promote to `BrandColors` when a second surface needs them)

| Token | Value | Role |
|---|---|---|
| `surface2` | `#1f1f22` | Raised elements: inputs, cards, kbd chips, toasts, tooltips. |
| `surface3` | `#2d2d32` | Highest step: chip fills, scrollbar thumbs, bar tracks. |
| `goldGhost` | `gold @ 0.10` | Selected-card/chip fill — quieter than `goldFaint`. |

Note the deliberate hue shift: `surface2`/`surface3` drift slightly blue-cool (`#1f1f22`, `#2d2d32`)
rather than staying neutral. Raised elements feel like a different material, not just a lighter gray.

### The white-opacity ladder

Intermediate grays are **not** new hex values — they are `#e8e8e8` at fixed opacities over the void.
This keeps the ladder consistent on any surface step:

| Opacity | Use |
|---|---|
| `1.0` | Primary text, row names |
| `0.8` | Body/secondary emphasis (footer rows, tooltip text) |
| `0.75` | Chip text, unselected control labels |
| `0.68–0.7` | Cost figures, numeric columns |
| `0.55` | Provider segments, recent glyphs |
| `0.45` | Hint text, kbd-bar captions |
| `0.25` | Separator dots (`·`) |
| `0.03–0.035` | Hover washes (see §5) |
| `0.02` | Header sheen gradient |

Two hardcoded deep-grays exist below `dim`: `#4a4a4a` (placeholders, inherited-state chips,
axis-off notes) and `#3d3d3d` (drag grips at rest). Treat them as "quieter than dim."

## 3. Typography

- **One family everywhere:** JetBrains Mono (fallbacks: SF Mono, ui-monospace, Menlo). Chrome only —
  terminal content belongs to the user's Ghostty config.
- **Base weight is 300.** Light is the default voice. `500` is emphasis (row names, chip text,
  labels); `600` is reserved for sheet titles and the gold CTA. Nothing heavier.
- **Size scale (px):** 8 · 8.5 · 9 · 9.5 · 10 · 10.5 · 11 · 11.5 · 12 · 12.5 · 13 · 17.
  13 is body/row-name size; 17 appears once, as the sheet `h1`. Sub-lines sit at 10.5, metadata at
  9.5–10, micro-badges at 8–9. The scale is dense and half-pixel-granular — embrace it.
- **Uppercase labels carry wide tracking:** section labels and micro-tags pair
  `text-transform: uppercase` with letterspacing from `0.10em` (DEFAULT tag) through `0.12–0.14em`
  (field labels, proto badges). Never uppercase without tracking.
- **Line height:** tight for chrome (1.0–1.2 implicit), 1.5–1.65 only inside prose-ish blocks
  (tooltips, terminal mock).

## 4. Gold discipline — the load-bearing rule

Gold means **"this is the one"**: the pinned default (● dot, DEFAULT tag), the keyboard-focused row,
the selected card/chip, the focused input border, the leader bar in stats, the flash of a fresh
save. It is a *state marker and attention vector*, not a theme color.

Rules of thumb:

1. **Full-strength gold** (`#c9a84c`) for glyphs, text, and the 2 px focus spine only. Large fills
   never exceed `goldFaint` (0.20); resting fills use `goldGhost` (0.10).
2. **One solid-gold element per surface, maximum** — the CTA (`Save & Launch`). It is the only
   place gold becomes a background with black text (`weight 600`; hover brightens to `#d4b45c`).
3. **Selected ≠ hovered.** Selection is gold (`goldFaint` fill + gold spine/text); hover is a
   white wash (§5). The two never share a mechanism.
4. **Gold borders come pre-faded:** `goldFaint` for tags/chips at rest, `gold @ 0.5` for focused
   inputs, full gold only on selected cards.
5. A whisper of gold is allowed in elevation: shadows carry a `0 0 0 0.5px rgba(gold, 0.07–0.08)`
   outer ring — an almost-invisible gilt edge on floating surfaces.

If a new surface finds itself reaching for gold a third time in one view, the design is wrong.

## 5. Interaction states

| State | Treatment |
|---|---|
| Hover (row) | `white @ 0.03` wash; reveal quiet affordances (pin ghost, drag grip) |
| Hover (control) | Border/text step up one ladder rung (`rule`→`dim` border, dim→white text) |
| Keyboard focus / selected | `goldFaint` fill + **2 px gold left spine** (`::before` bar) |
| Focused input | Border → `gold @ 0.5`; no glow, no ring |
| Disabled / not-installed | Whole-row `opacity: 0.42–0.45`; hover suppressed; stays clickable where §5.6 applies |
| Default marker | Gold ● (16 px circle); hover shows ○ ghost at `white @ 0.4`, gold on direct hover |

The **left spine** is the signature focus treatment — a 2 px full-height gold bar hugging the left
edge of the selected row. Reuse it anywhere a list has a cursor.

## 6. Shape, depth, and layering

- **Radius scale:** 3 px (tags, kbd, micro-chips) · 4–5 px (buttons, small rows) · 6–7 px (inputs,
  cards, panels, toasts) · 9 px (popover) · 11 px (sheet). Bigger surface, bigger radius — nothing
  beyond 11.
- **Borders are 1 px `rule`,** stepping down to `0.5 px` for intra-list separators (at reduced
  alpha: `rgba(51,51,51,0.35–0.55)`) and for chip outlines. Hairlines do the work fills would do
  elsewhere.
- **Elevation = shadow depth + the gilt ring:**
  - Popover: `0 18px 60px rgba(0,0,0,0.75)` + gold ring @ 0.07
  - Sheet: `0 30px 90px rgba(0,0,0,0.85)` + gold ring @ 0.08
  - Toast: `0 10px 40px rgba(0,0,0,0.7)` + **2 px gold left border** (the spine again)
- **Scrims** are `rgba(0,0,0,0.62)`.
- **Zone tinting inside a surface:** header gets a breath of light
  (`linear-gradient(white @ 0.02, transparent)`); footers and section rules sink back toward the
  void (`rgba(10,10,10,0.5–0.75)`). Content rows sit on plain `surface`. This vertical
  light-to-dark rhythm is what makes the popover read as one carved object.
- **Section rules** are centered labels flanked by 1 px lines (`flex` with `::before`/`::after`),
  on a sunken band — not bare `<hr>`s.

## 7. Motion

Fast in, slow fade — entrances are near-instant, confirmations linger:

| Animation | Duration / curve | Shape |
|---|---|---|
| Popover in | 130 ms ease-out | fade + 5 px drop from above |
| Sheet in | 160 ms ease-out | fade + `scale(0.985)` + 6 px rise |
| Toast | 150 ms opacity/transform | rises 8 px into place |
| Row saved flash | 1.4 s ease-out | `goldFaint` → transparent |
| Tab flash (new) | 1.2 s ease-out | `goldFaint` bg + inset gold underline → rest |
| Launch ring | 1.1 s ease-out | 1.5 px gold inset border fading out |
| Disclosure caret | 120 ms | 90° rotation |

No bounces, no springs, no easing theatrics. Nothing moves unless it is appearing, confirming, or
decaying.

## 8. Component recipes

Copy these wholesale when building a new surface:

- **kbd chip:** 9.5 px @ 500, `white @ 0.78` on `surface3`, 0.5 px `rule` border, 3 px radius,
  `0 4px` padding. Always paired with a `hint-dim` caption (`white @ 0.45`, 10–10.5 px).
- **Neutral chip (effort):** 9 px @ 500, `white @ 0.75` on `surface3`, 0.5 px `rule` border.
- **Accent chip (system-prompt / active):** same geometry, gold text on `goldGhost` with
  `goldFaint` border.
- **Micro-tag (DEFAULT):** 8.5 px @ 500 uppercase, `0.1em` tracking, gold text, `goldFaint`
  0.5 px border, 3 px radius.
- **Checkbox:** 13 px square, 3 px radius; off = `dim` border/hollow; on = solid gold fill with
  black check. Binary, instant, no animation.
- **Segmented control:** `surface2` segments in one 6 px-radius `rule` frame; selected segment =
  gold text on `goldGhost`.
- **Ghost button:** transparent, `rule` border, `white @ 0.8`; hover lifts border to `dim` and
  text to white. The gold CTA (§4.2) is its sole sibling.
- **Stat bar:** 14 px track on `surface2`, 3 px radius; leader fill is a
  `90deg gold@0.55 → gold` gradient; all others fill `surface3`.
- **Tooltip/info:** ⓘ is a 13 px circle, 0.5 px `rule` border, dim glyph, gold on hover; the tip is
  a `surface2` card, 6 px radius, 10 px text @ `white @ 0.8`, line-height 1.5.
- **Scrollbars:** 8 px, `surface3` thumb, 4 px radius, transparent track.

## 9. Applying it elsewhere — the checklist

When bringing this aesthetic to another c11 surface:

1. **Ground on `surface` (#0a0a0a), not black** — black is for the terminal void behind everything.
2. **Structure with hairlines and zone tints,** not filled cards. If you're drawing a box with a
   fill, ask whether a 1 px rule and 8 px of padding does it better.
3. **Pick the surface's single gold moment** before laying anything out. Everything else stays on
   the gray ladder.
4. **Use the white-opacity ladder** for every gray between `dim` and `white` — no new hex grays.
5. **Left spine for cursors, white wash for hover, goldFaint for selection.** Don't invent a fourth
   state treatment.
6. **Type: mono, 300, small.** Reach for tracking-and-uppercase before reaching for size or color.
7. **Pin dark.** This palette is dark-committed (`.darkAqua` on the popover host); a light variant
   is a deliberate follow-up project, not a per-surface improvisation.
8. **Promote tokens as you go:** the first reuse of `surface2`/`surface3`/`goldGhost` outside the
   picker should move them from `PickerPalette` into `BrandColors` so shims never multiply.

---

*Sources of truth, in precedence order: `company/brand/visual-aesthetic.md` → `BrandColors.swift` →
the C11-175 prototype → this guide. If they disagree, fix the disagreement upstream, not here.*
