# c11mux Module 5 — Stage 11 Brand Identity Spec

Canonical specification for Module 5 of the [c11mux charter](./c11mux-charter.md). Where Module 2 is a protocol, M5 is a design document: it names the visual identity c11mux ships with and the runtime seams through which an agent can verify that identity from a built bundle.

Status: specification, not yet implemented. The rename-surface agent (sibling pane `pane:25`) is concurrently rewriting `cmux → c11mux` across `Sources/`, `Info.plist`, and project metadata. Strings cited below reflect read-time state; the mechanical rename and the M5 visual work compose without conflict.

---

## Goals

- c11mux is **recognizably Stage 11** at a glance — in the Dock, in the menu bar, in the About box, in the README, and inside the app chrome.
- The default visual language is the **void-dominant, gold-accented** system from `company/brand/visual-aesthetic.md`. Nothing else competes with the terminal content.
- Every identity decision is **agentically verifiable** from a built artifact or a runtime seam — never from a source file read.
- Bundle/icon/feed variants (stable, DEV, NIGHTLY, STAGING) remain mutually isolated so agents can run them side-by-side without crosstalk.
- Upstream cmux's functional defaults — Ghostty config read-through, blue notification ring semantics, sidebar metadata shape — keep working; M5 recolors, it does not rewire.

## Non-goals

- **No plugin theming system.** Users can still override the terminal palette via `~/.config/ghostty/config`. They cannot yet theme the app chrome — that's a separate module if it ships.
- **No light-mode redesign.** c11mux is void-dominant; a light-mode variant of the app chrome is explicitly out of scope for v1 (see "Light mode" below). Built system controls (menu bar, window chrome) still respond to `NSAppearance`.
- **No final asset delivery.** This spec prescribes the concepts, the palette mapping, the runtime API, and the test surface. PNG generation for the AppIcon sets happens in implementation, not here.
- **No website / docs-site refresh.** That's separate Stage 11 brand work. M5 covers the app bundle + README + in-repo badges.
- **No upstream-contributable changes.** Everything in M5 is Stage-11-specific and stays in the fork. Matches charter's "Keep Stage-11-specific opinions in the fork."

---

## Terminology

- **Brand palette** — the seven-token palette defined in `company/brand/visual-aesthetic.md` (`--black`, `--surface`, `--rule`, `--dim`, `--white`, `--gold`, `--gold-faint`). All hex values in this spec are pulled from that file and are canonical.
- **Accent** — the single gold accent `#c9a84c`. Replaces cmux's current blue accent (`#0091FF` dark / `#0088FF` light, `Sources/ContentView.swift:43-59`).
- **BrandColors** — the Swift API M5 introduces (see "Runtime palette API" below) that the rest of the app resolves accent/chrome colors through. This is the seam that makes the palette runtime-assertable.
- **Channel** — one of `stable`, `nightly`, `staging`, `dev`. Each channel has its own display name, bundle ID, icon, socket path, and Sparkle feed.

---

## App icon concepts

### Design constraints

- Must read at both **16px** (menu-bar dock tile, sidebar favicon) and **512px** (About box, Finder Get Info). At 16px the icon reduces to ~4 distinguishable pixel clusters — anything more fails.
- Must survive macOS's squircle mask (Sequoia+ standard squircle, `AppIcon.icon` modern format already used by upstream — see `/Users/atin/Projects/Stage11/code/cmux/AppIcon.icon`).
- Must be visually distinct from upstream's chevron icon (`design/cmux-icon-chevron.png`) at thumbnail size — we are a fork, not a re-skin.
- Must honor the visual-aesthetic register: **dark-dominant, ancient-future, abstract, void-emergent**. Not retro-futuristic. Not clean sci-fi.

### Concept A — "Spike" (recommended)

A single vertical gold mark rising from the lower edge of a void squircle. A narrow tapered wedge — wider at the base, narrow at the tip — a minimal stylization of Stage 11's "spike" primitive.

- **Primary shape:** one vertical gold wedge, centered, rising from ~20% to ~80% of the icon height. Base width ~8% of icon, tip width ~1.5%. A single form; no second element.
- **Palette:** fill `#c9a84c` gold on `#0a0a0a` (`--surface`) squircle. The squircle carries a 1px internal `#c9a84c33` (`--gold-faint`) inner stroke at 1x; ~4px at 10x. Thin, whispered.
- **Stage 11 nod:** the spike is the central Stage 11 metaphor — "the front of the spike … its nature is penetration" (`brand-voice.md`). One mark = one spike = one c11mux instance.
- **At 16px:** two or three gold pixels in a vertical column over a near-black tile. Still reads as "a Stage 11 thing in the Dock."
- **Render pipeline:** one SVG source at `design/c11mux-spike.svg`. macOS `.icon` bundle authored once in Icon Composer; exports populate `Assets.xcassets/AppIcon.appiconset/*.png` at all mac-required sizes (16/32/128/256/512 @ 1x/2x) plus a liquid-glass layered representation for macOS 15+.

```
┌──────────────────────┐    at 16px:
│                      │    ┌──────────┐
│                      │    │          │
│          ▲           │    │    .     │
│          █           │    │    █     │
│          █           │    │    █     │
│          █           │    │    █     │
│          █           │    │    .     │
│          █           │    │          │
│          █           │    └──────────┘
│                      │
└──────────────────────┘
```

### Concept B — "Lattice-over-void"

A micro-lattice of crystalline gold rule lines — 3×3 grid — the whole grid sized to fit inside the squircle's inner rect. References the Stage 11 lattice imagery (`gregorovitch/art/`, hundreds of lattice generations). Looks like the artifact of a civilization that engineers at quantum scale.

- **Primary shape:** 9-intersection lattice (2 vertical + 2 horizontal rule lines) etched across ~60% of icon width, centered.
- **Palette:** `#c9a84c` lines at 0.5px (1x) on `#000000` squircle. Background `#000000` true void (slightly darker than Concept A's `--surface`). Intersections get a 1.5×-line-width dot.
- **At 16px:** likely illegible — reduces to a gold smudge. **This is the failure mode.** B is the fallback if Concept A reads as too plain in internal review.
- **Render pipeline:** SVG source, same export path.

### Concept C — "Squircle-of-one"

A single gold ring flush against the squircle's inner edge, with a tiny filled gold dot at the center.

- **Primary shape:** ~1px gold inner ring + 4px gold center disc.
- **Palette:** `#c9a84c` ring + dot on `#0a0a0a` squircle.
- **At 16px:** ring disappears; only the dot survives — icon reduces to "one gold pixel." That can work, but it fails the "visually distinct from a cursor caret" test.
- **Render pipeline:** SVG source, same export path.

### Recommendation

**Ship Concept A.** One gold mark on void. Reads at 16px, carries the spike metaphor, survives squircle masking, and is the cheapest concept to iterate on (one shape, one fill). B is the fallback if A tests as underdifferentiated at icon-grid density; C is rejected for 16px collapse.

### 16px readability gate (blocking)

Concept A ships **only after passing both** of the following checks. Neither is optional.

1. **Pixel-render test** (`test_m5_icon_16px_render.py`, lands in `tests_v2/`). Exports the 1× 16×16 PNG from `Assets.xcassets/AppIcon.appiconset/16.png` and asserts:
   - At least 2 and no more than 5 pixels in the image have a gold channel signature (R ≥ 160, G ≥ 128, B ≤ 100, A ≥ 200). Outside this band the spike is either invisible (≤1 pixel, fails "reads at 16px") or bled into a smudge (≥6 pixels, fails "still a spike").
   - The gold pixels all sit within the vertical center column (x ∈ [6, 9]) and span a contiguous y-range ≥ 3 pixels. Off-axis gold means the spike has drifted under squircle masking.
   - Mean luminance of the remaining ~250 non-gold pixels is ≤ 0.10 (near-void, not a grey smear).
   Run as part of the `test_m5_built_bundle.py` suite against the built bundle's compiled asset catalog output. Failure blocks the icon commit.
2. **Named human review checkpoint.** Before the first AppIcon assets land on `main`, Atin signs off in writing (Lattice task or PR approval comment stating "c11mux icon 16px legibility: approved") after viewing the icon in three real contexts: macOS Dock at default zoom, Finder sidebar (16×16 favicon slot), and Cmd+Tab switcher (which uses the 2× 32px representation — a proxy for stress-testing the 16px reduction). The review artifact: a single screenshot of all three side-by-side attached to the commit.

Both gates must be green before `AppIcon.appiconset/*.png` files are committed. If either fails, fall back to Concept B, re-run both gates.

### Debug / Nightly / Staging overlays

Keep the existing corner-banner pattern that `scripts/generate_nightly_icon.py` uses — it's well-tested and preserves the icon's silhouette. Three overlays:

| Channel | Banner color | Banner text | Rationale |
|---------|--------------|-------------|-----------|
| `dev` | `#c9a84c` (gold, 70% opacity) | `DEV` | Gold-on-void keeps the aesthetic; opacity distinguishes from stable |
| `nightly` | `#8c3cdc` (existing purple from `generate_nightly_icon.py`) | `NIGHTLY` | Already implemented; purple is the one palette exception the brand tolerates for channel differentiation |
| `staging` | `#555555` (`--dim`) | `STAGING` | Near-invisible — staging should feel drab, not loud |

Generator scripts live under `scripts/generate_*_icon.py` (pattern established by `generate_dark_icon.py` and `generate_nightly_icon.py`). M5 rewrites them to operate on the spike source rather than the upstream chevron.

---

## Palette mapping

All hex values canonical, pulled from `company/brand/visual-aesthetic.md`.

### Tokens → UI surfaces

| Token | Hex | Where it lands |
|-------|-----|----------------|
| `--black` | `#000000` | Terminal default background (when Ghostty config is absent). Main window background. |
| `--surface` | `#0a0a0a` | Sidebar background. Toolbar background. Title bar (module 7) background. Find bar background. Markdown viewer background. |
| `--rule` | `#333333` | Pane dividers. Tab separators. Sidebar section rules. Scrollbar track. Browser toolbar bottom border. |
| `--dim` | `#555555` | Secondary sidebar metadata (git branch, port numbers, timestamps). Placeholder text. Disabled controls. Unread-count text on read rows. |
| `--white` | `#e8e8e8` | Primary sidebar text (tab titles). Terminal default foreground. Markdown body text. Browser URL bar text. |
| `--gold` | `#c9a84c` | Accent everywhere: selected-tab highlight, selected-workspace background, notification ring (replaces the current blue ring), focus outlines, progress bars, the dot in the unread-notification badge, brand chip on the title bar. |
| `--gold-faint` | `#c9a84c33` | Ghost borders: hover states on sidebar tabs, inner stroke on the icon squircle, inactive focus rings, grid lines in the markdown code-block chrome. |

### Surface-by-surface

- **App chrome (window title bar + toolbar).** Background `--surface`. System traffic lights unchanged (Apple's, we do not override). When the app is focused, the traffic-light region gets a `--gold-faint` 1px bottom rule.
- **Sidebar.**
  - Background: `--surface`.
  - Tab row default: text `--white` 300wt, metadata `--dim`.
  - Tab row hover: background `--gold-faint`.
  - Tab row selected: background `--gold` (replacing the current `cmuxAccentNSColor()` blue at `Sources/ContentView.swift:115-117`), text remains `--white`. The gold sits as a solid bar, full row width.
  - Notification ring on a pane: `--gold` at 100% alpha. Today this is blue (`Sources/cmuxApp.swift:4424` "blue ring around panes with unread notifications"). The string and the rendered color both flip.
  - Status pills: background `--gold-faint`, text `--gold`. Status colors that must encode meaning (error, success) are a v2 concern — v1 uses gold for "something." Charter parking lot.
- **Terminal panel chrome.** Surround margins `--surface`. Find bar background `--surface` with a 1px `--rule` top border, text `--white`, active-match highlight `--gold`. Scrollbar track `--rule`, thumb `--dim`, thumb-on-drag `--gold-faint`.
- **Browser chrome.** Address bar background `--surface`, border `--rule` 1px, text `--white`, placeholder `--dim`. Back/forward/reload glyphs `--white` at 75%, hover `--white` at 100%, disabled `--dim`. Loading indicator `--gold` bar sliding under the address bar.
- **Markdown viewer.**
  - Background `--surface`, body text `--white`, heading accents `--gold` (H1 rule underline in gold at 1px; H2/H3 no rule, weight-only differentiation).
  - Code blocks: background `#000000` (true void, one step deeper than page `--surface`), text `--white`, inline code `--gold` on `--gold-faint` pill.
  - Mermaid nodes: fill `--surface`, stroke `--gold`, text `--white`. Edges `--dim` default, `--gold` when the source marks them. This coordinates with M6's Mermaid rendering (see charter §6).
- **Update pill** (`Sources/Update/UpdatePill.swift`, `UpdateBadge.swift`): background `--gold-faint`, foreground `--gold`, downloading-progress `--gold` on `--rule` track.

### Light mode

Stage 11 is void-dominant. c11mux **does not ship a light-mode app-chrome palette**. The resolved palette is identical regardless of `NSAppearance`. Rationale:
- The terminal content palette is user-owned via Ghostty config — users who want a light terminal already have one.
- Chrome surfaces represent <10% of the visible pixels; splitting them into a second palette doubles test surface for marginal gain.
- The brand is explicit: "The void is always dominant. Gold is always singular" (`visual-aesthetic.md`).

This is a **departure from upstream cmux**, which currently maintains separate light/dark accent values (`cmuxAccentNSColor(for: colorScheme)` returns `#0088FF` for light, `#0091FF` for dark — `Sources/ContentView.swift:43-59`). M5 collapses this: both branches of the switch return `#c9a84c`. Note the existing `AppIconLight.imageset` and `AppIconDark.imageset` both continue to exist — the icon dark variant generator (`scripts/generate_dark_icon.py`) still runs, it just operates on void+gold rather than white+chevron.

---

## Runtime palette API

The palette is accessible from Swift through a single type, introduced by M5:

```swift
enum BrandColors {
    static let black: NSColor      // #000000
    static let surface: NSColor    // #0a0a0a
    static let rule: NSColor       // #333333
    static let dim: NSColor        // #555555
    static let white: NSColor      // #e8e8e8
    static let gold: NSColor       // #c9a84c
    static let goldFaint: NSColor  // #c9a84c33
}

extension BrandColors {
    /// SwiftUI bridges. Generated, not hand-written.
    static var goldSwiftUI: Color { Color(nsColor: gold) }
    // ... one per token
}
```

Migration path:
- `cmuxAccentNSColor(...)` and `cmuxAccentColor()` (`Sources/ContentView.swift:43-76`) keep their signatures and become thin aliases that return `BrandColors.gold` / `BrandColors.goldSwiftUI`. All current call sites (there are >20 — see `Sources/ContentView.swift`, `Sources/NotificationsPage.swift`, `Sources/BrowserWindowPortal.swift`, `Sources/Panels/BrowserPanelView.swift`) continue to compile unchanged.
- `sidebarSelectedWorkspaceBackgroundNSColor(...)` (`Sources/ContentView.swift:115`) similarly forwards to `BrandColors.gold`.
- New call sites prefer `BrandColors.*` directly. Keep the alias layer; do not do a big-bang rename in M5.

**API surface scope.** `BrandColors` is **internal to the c11mux app target** — not part of any public Swift module interface, not vended to external consumers, not covered by a stability contract. It exists as the internal seam through which app code resolves colors; its shape can change whenever a refactor needs it to. The only guaranteed-stable read-back surface for external / test consumers is the `system.brand` socket method defined below. Agentic tests MUST assert the palette through `system.brand`, not by importing Swift symbols or linking against the app target.

Rationale: one enum, one place to read/override. In-process call sites hit `BrandColors.gold` directly; out-of-process verification hits `system.brand`. No source-file grep, no render-pixel scraping of chrome. See "Test surface" below.

---

## Bundle naming & channel identity

Confirms the charter's expectation and names every knob per channel.

| Field | `stable` | `dev` (tagged) | `nightly` | `staging` |
|-------|----------|----------------|-----------|-----------|
| `CFBundleDisplayName` | `c11mux` | `c11mux DEV <tag>` | `c11mux NIGHTLY` | `c11mux STAGING` |
| `CFBundleName` | `c11mux` | `c11mux DEV <tag>` | `c11mux NIGHTLY` | `c11mux STAGING` |
| `CFBundleIdentifier` | `com.stage11.c11mux` | `com.stage11.c11mux.debug.<tag-id>` | `com.stage11.c11mux.nightly` | `com.stage11.c11mux.staging` |
| `CFBundleIconName` | `AppIcon` | `AppIcon-Debug` | `AppIcon-Nightly` | `AppIcon-Staging` (new — M5 adds) |
| Socket path | `/tmp/c11mux.sock` | `/tmp/c11mux-debug-<tag>.sock` | `/tmp/c11mux-nightly.sock` | `/tmp/c11mux-staging.sock` (or tagged override) |
| Sparkle feed URL | `https://github.com/Stage-11-Agentics/c11mux/releases/latest/download/appcast.xml` | (none — local build) | `https://github.com/Stage-11-Agentics/c11mux/releases/download/nightly/appcast-nightly.xml` | (none — staging is local/CI only) |
| Derived data | `~/Library/Developer/Xcode/DerivedData/cmux-<hash>` | `~/Library/Developer/Xcode/DerivedData/cmux-<tag-slug>` | (CI build output) | `/tmp/c11mux-staging-<tag-slug>` (from `scripts/reloads.sh`) |

**Conflicts flagged for rename-surface agent (pane:25):**

- `Resources/Info.plist:153-154` already carries the stable Sparkle feed URL pointing at `Stage-11-Agentics/c11mux`. Good — no change.
- `GhosttyTabs.xcodeproj/project.pbxproj` has `PRODUCT_BUNDLE_IDENTIFIER = com.stage11.c11mux` (Release, line 969) and `com.stage11.c11mux.debug` (Debug, line 928). Good — matches.
- The `.nightly` bundle ID is **not** currently declared in the Xcode project. M5 requires the rename-surface agent (or a follow-up) to add a Nightly scheme/xcconfig that sets `PRODUCT_BUNDLE_IDENTIFIER = com.stage11.c11mux.nightly` and `CFBundleIconName = AppIcon-Nightly`. Flag for coordination.
- The `AppIcon-Staging.appiconset` directory does **not** exist yet. Generator script must produce it from the spike source + `--dim` banner. Until then, staging falls back to `AppIcon-Debug`.
- `scripts/reload.sh` uses `c11mux DEV <tag>` display name and `com.stage11.c11mux.debug.<tag-id>` — matches the table above. No change.
- `scripts/reloads.sh` uses `c11mux STAGING` and `com.stage11.c11mux.staging` — matches. No change.

---

## Default terminal palette

When `~/.config/ghostty/config` is absent or does not specify a palette, c11mux supplies a Stage-11-tuned default. Ghostty config always wins when present — this is the **default only**.

### Background / foreground

- `background` = `#000000`
- `foreground` = `#e8e8e8`
- `cursor-color` = `#c9a84c`
- `cursor-text` = `#000000`
- `selection-background` = `#c9a84c33`
- `selection-foreground` = `#e8e8e8`

### 16 ANSI colors

Grounded in the brand palette where possible; the six chromatic slots (red/green/yellow/blue/magenta/cyan) borrow tones that align with the void+gold register rather than neon-terminal defaults. Gold takes the yellow slot, because yellow is what gold is in ANSI space.

| Slot | Name | Normal (0-7) | Bright (8-15) |
|------|------|--------------|---------------|
| 0 | black | `#000000` | `#333333` |
| 1 | red | `#8b3a3a` | `#b04a4a` |
| 2 | green | `#6b8a4c` | `#8baa5a` |
| 3 | yellow (gold) | `#c9a84c` | `#e0c060` |
| 4 | blue | `#3a5a8b` | `#4a7aaa` |
| 5 | magenta | `#7a4a8b` | `#9a5aaa` |
| 6 | cyan | `#4a8a8b` | `#5aaaaa` |
| 7 | white | `#c8c8c8` | `#e8e8e8` |

Rationale: the chromatic slots are desaturated (~50% saturation target), so that when code highlighting splashes them across the screen the feel is still "gold on void," not "pride flag on void." Bright variants lift luminance ~15-20%, not saturation.

### Delivery

This palette ships as a Ghostty config fragment at `Resources/ghostty/c11mux-default.conf`. At terminal surface creation, if the user's Ghostty config does not set `background` / `foreground` / `palette`, c11mux layers this fragment in. Implementation anchor: `Sources/GhosttyConfig.swift` already synthesizes a sidebar background from Ghostty's `background` (line 158). The same path injects defaults.

---

## Typography

Stage 11's canonical face is **JetBrains Mono** (`visual-aesthetic.md`). c11mux honors it where we own the text:

| Surface | Font | Weight |
|---------|------|--------|
| Terminal content | **Ghostty config, not c11mux.** Do not override. |
| Sidebar tab titles | JetBrains Mono | 400 |
| Sidebar metadata (branch, port, PR) | JetBrains Mono | 300 |
| Title bar (module 7) title | JetBrains Mono | 500 (small, spaced, uppercase — per aesthetic doc) |
| Title bar description | JetBrains Mono | 300 |
| Markdown viewer body | JetBrains Mono | 300 |
| Markdown viewer headings | JetBrains Mono | 500 |
| About box app name | JetBrains Mono | 500 |
| Menu items, context menus | SF (system) | default — macOS HIG wins here. Breaking system menus with a custom face is hostile. |
| README / docs | JetBrains Mono via `<pre>`-like code blocks; body inherits GitHub's rendering | — |

JetBrains Mono ships in `Resources/Fonts/` as OFL-licensed `.ttf` files registered via `UIAppFonts`/`ATSApplicationFontsPath` in Info.plist. This is new — cmux does not currently bundle a font. All existing `.font(.system(size: 13, weight: .regular))` call sites in `Sources/ContentView.swift` (e.g. lines 3326, 3481, 3532) are left alone in M5; a single helper `BrandFont.body(size:)` wraps `.custom("JetBrainsMono-Light", size: size)` with a `.system` fallback if the font fails to load, and future refactors adopt it incrementally. M5 lands the registration + the helper; call-site migration is not in scope.

---

## README & homepage copy

### Header

Replace the current upstream `<h1>cmux</h1>` block (`README.md:1-8`) with:

```markdown
<h1 align="center">c11mux</h1>
<p align="center">
  <i>the Stage 11 terminal multiplexer for AI coding agents</i>
</p>
<p align="center">
  <img src="./docs/assets/c11mux-header.png" alt="c11mux" width="720" />
</p>
```

- **Tagline:** *the Stage 11 terminal multiplexer for AI coding agents.* (Lowercase. Internal register — this is how Stage 11 talks to its team and its operators.)
- **Header image** (`docs/assets/c11mux-header.png`): a 720×240 PNG built from the spike icon, a thin `--gold-faint` horizontal rule spanning the image, and the word `c11mux` set in JetBrains Mono 500 at ~80px on `--surface`. Rendered in Figma; source committed alongside the PNG at `docs/assets/c11mux-header.figma`.

### Fork-acknowledgment paragraph

The rename-surface agent already inserted a Fork notice (`README.md:22-30`). M5 does not rewrite it — the prose is accurate and respects upstream. Leave as-is. Coordination note: if `pane:25` is mid-rewrite, the final copy should retain the two testable markers this spec's test surface grep for: the string `Stage 11 Agentics fork of [cmux](https://github.com/manaflow-ai/cmux)` and the string `AGPL-3.0-or-later`.

### The Zen of cmux section

Kept verbatim (`README.md:116-124`). It's upstream prose about the primitive philosophy — swapping Stage 11 voice onto it would be dishonest to the fork notice ("All credit … belongs to the upstream authors"). The c11mux-specific positioning lives in the header tagline only.

### Download badge

Replace `docs/assets/macos-badge.png` with a Stage-11-palette version:
- Width 180px, height 56px.
- Background `--surface`, border `--gold-faint` 1px.
- Text `Download for macOS` in JetBrains Mono 500, `--white`.
- A single `--gold` dot (4px) left-aligned as the lone accent.

### Homebrew tap badge

No separate badge file today — README uses plain text + code fence (`README.md:89-98`). Keep the text block; no badge graphic is added in M5. If a homebrew-tap shield is added later, it inherits the palette above.

---

## Interaction with other modules

- **Module 2 (metadata).** M5 does not introduce canonical metadata keys. It does consume them: `role`, `status`, `task`, `model`, `progress`, `title`, `description` all render through palette surfaces defined here. Status pill colors use `--gold` + `--gold-faint`. Progress bars fill in `--gold` on a `--rule` track.
- **Module 1 (TUI detection) + Module 3 (sidebar chip).** Agent chip backgrounds `--gold-faint`, foreground `--gold`, icon monochrome-ized to `--white`. The chip inherits typography from Module 3; M5 only supplies the palette.
- **Module 4 (integration installers).** The `cmux install <agent>` confirmation diff viewer uses the markdown-viewer palette defined here. No new surfaces introduced by M5.
- **Module 6 (markdown surface polish).** Palette mapping for the markdown viewer lives in this spec (section above). M6 owns the mount/flag work; M5 owns how it looks. Mermaid node styling in particular is cited in both specs — the palette is the source of truth.
- **Module 7 (title bar).** Title bar chrome colors (`--surface` background, `--gold` brand dot, `--white` title text, `--dim` description text) are defined here. M7 owns layout, focus behavior, and storage in M2's canonical `title`/`description` keys.
- **Module 8 (`cmux tree`).** Spatial rendering colors (ASCII-art floor plan uses `--gold` for focused pane border, `--dim` for unfocused). No palette conflicts.

---

## Runtime read-back (for testability)

For agents to verify the brand landed, M5 exposes **two read-back surfaces**:

### 1. `system.brand` socket method (new)

Returns the resolved brand palette + channel info + icon metadata from the running process. Lives alongside `system.ping` / `system.capabilities` / `system.identify` (see `Sources/TerminalController.swift:2021-2028`).

```json
{"id":"b1","method":"system.brand","params":{}}
```

Response:

```json
{
  "id": "b1",
  "ok": true,
  "result": {
    "channel": "stable",
    "bundle": {
      "identifier": "com.stage11.c11mux",
      "display_name": "c11mux",
      "name": "c11mux",
      "icon_name": "AppIcon",
      "short_version": "0.2.0",
      "build": "42"
    },
    "palette": {
      "black":      "#000000",
      "surface":    "#0a0a0a",
      "rule":       "#333333",
      "dim":        "#555555",
      "white":      "#e8e8e8",
      "gold":       "#c9a84c",
      "gold_faint": "#c9a84c33"
    },
    "accent_hex": "#c9a84c",
    "font_family": "JetBrains Mono"
  }
}
```

The `palette` values come from `BrandColors.*` resolved to 6-digit (or 8-digit for alpha) sRGB hex. `bundle.*` reads `Bundle.main.infoDictionary[...]` at runtime — so asserting it verifies the built plist, not the source-tree plist. `channel` is derived from the bundle identifier suffix (`.debug.*` → `dev`, `.nightly` → `nightly`, `.staging` → `staging`, else `stable`).

Threading: off-main (parse/validate) → main-actor snapshot of `Bundle.main` (fast, no mutation) → off-main serialize. Fits the socket threading policy.

### 2. `cmux brand` CLI

Sugar over the socket method. `cmux brand` prints a human-readable summary; `cmux brand --json` emits the raw socket result. No workspace/window scoping — brand is app-level.

### Error codes

| Code | When |
|------|------|
| `brand_unavailable` | `BrandColors` has not been initialized (should not happen post-launch; surfaces indicate a boot-order bug in tests). |

No other errors — the method takes no parameters.

---

## Test surface (mandatory)

Tests land in `tests_v2/` following the existing socket-test pattern (e.g. `tests_v2/test_cli_sidebar_metadata_commands.py`). The policy in `code/cmux/CLAUDE.md` "Test quality policy" **forbids reading `Resources/Info.plist`, `project.pbxproj`, or source files to assert string existence** — every assertion below reads a built artifact or a runtime value.

### Built-bundle artifact assertions (`test_m5_built_bundle.py`)

Resolve the built app path from the tagged debug build's derived-data tree (pattern: `~/Library/Developer/Xcode/DerivedData/cmux-<tag>/Build/Products/Debug/c11mux DEV <tag>.app/` — the debug socket tests already know how to locate this) and assert:

1. `<app>/Contents/Info.plist` parses. `CFBundleIdentifier` matches `^com\.stage11\.c11mux(\.(debug|nightly|staging)(\..+)?)?$`. `CFBundleDisplayName` starts with `c11mux`. `CFBundleIconName` ∈ `{AppIcon, AppIcon-Debug, AppIcon-Nightly, AppIcon-Staging}`.
2. The resolved `.icns` (or modern `.car`-compiled asset catalog output) at `<app>/Contents/Resources/AppIcon.icns` (or equivalent) exists and contains image representations at sizes 16, 32, 128, 256, 512 — at both 1× and 2×. Use `iconutil -c iconset <path>` or `Quick Look`-equivalent inspection (`sips -g pixelWidth -g pixelHeight`) to assert dimensions per representation.
3. JetBrains Mono is bundled: `<app>/Contents/Resources/Fonts/JetBrainsMono-Light.ttf` exists and is a valid TTF (magic bytes `00 01 00 00` or `true`). Same for `-Regular.ttf` and `-Medium.ttf`.
4. `CFBundleShortVersionString` matches the three-tier Stage 11 format `^\d+\.\d+\.\d+$` (see top-level CLAUDE.md "Versioning Convention"). If the rename-surface agent has not yet normalized to three-tier, this test is the forcing function.
5. **16px icon legibility** — runs the assertions from "16px readability gate (blocking)" above (`test_m5_icon_16px_render.py`). Extracts the 1× 16×16 representation from the compiled asset catalog and verifies gold-pixel count, column position, and mean luminance of the non-gold field. Failure is a test failure; the human-review checkpoint is not testable headlessly and runs out-of-band.

Reads **only** from the built bundle path — zero reads from the repo source tree. Per policy.

### Runtime palette assertions (`test_m5_palette_runtime.py`)

Via the socket, against a running tagged debug instance (same pattern as existing `tests_v2` — `CMUX_SOCKET=/tmp/c11mux-debug-<tag>.sock`):

```python
r = rpc("system.brand")
assert r["ok"]
assert r["result"]["palette"]["gold"].lower() == "#c9a84c"
assert r["result"]["palette"]["surface"].lower() == "#0a0a0a"
assert r["result"]["palette"]["gold_faint"].lower() == "#c9a84c33"
assert r["result"]["accent_hex"].lower() == "#c9a84c"
assert r["result"]["font_family"] == "JetBrains Mono"
```

Verifies the runtime resolution of `BrandColors.*` — not the source file. If someone regresses the palette in Swift, this fails.

### Channel identity (`test_m5_channel_identity.py`)

Launch via `reload.sh --tag m5-ch-test`; assert `system.brand` reports `channel == "dev"` and `bundle.identifier.startswith("com.stage11.c11mux.debug.")`. Launch via `reloads.sh`; assert `channel == "staging"` and `bundle.identifier == "com.stage11.c11mux.staging"`. (Nightly has no `reload` script entry; nightly channel identity asserted from a CI-produced artifact, covered by the bundle-artifact test above.)

### README snapshot (`test_m5_readme_markers.py`)

The test policy forbids asserting source *code* strings; README markdown is documentation, not source. Assertions on the repo's `README.md`:

1. First 5 lines contain the literal string `c11mux` as `<h1 align="center">c11mux</h1>`.
2. The tagline `the Stage 11 terminal multiplexer for AI coding agents` appears exactly once (case-sensitive).
3. The fork-acknowledgment marker `Stage 11 Agentics fork of [cmux](https://github.com/manaflow-ai/cmux)` appears exactly once.
4. The license marker `AGPL-3.0-or-later` appears.

If GitHub's rendered HTML is easier to snapshot later, prefer that. For now, README-on-disk suffices because the README is a **rendered artifact for humans**, not a source file in the sense the test policy restricts.

### What M5 cannot test headlessly

Named explicitly, per the common brief's "name what this module cannot test headlessly" requirement:

- **"The icon reads at 16px."** Headless test **added** as a blocking gate (see "16px readability gate (blocking)" and `test_m5_icon_16px_render.py` above) — it asserts gold-pixel count, column position, and luminance on the rendered 16×16 PNG. The test catches objective regressions (spike disappears, smudges, drifts off-axis). The subjective "does this look right to a human in the Dock" portion remains a human checkpoint and is the named review artifact required before the first AppIcon commit.
- **"Gold on void feels right at scale."** No headless test. Covered by human review; the runtime palette test pins the values so regressions to the hex codes are caught even if the aesthetic judgment isn't.
- **"The download badge is on-brand."** No headless test. Covered by human review; dimensions/palette confirmed at artifact level (`docs/assets/macos-badge.png` is a 180×56 PNG whose dominant color histogram matches `--surface`+`--gold`).
- **"Mermaid diagrams look right."** The palette values feed Mermaid via Module 6; visual rightness is a human review. The palette test locks the inputs.

Screen-scraping the PTY buffer is not used for any brand assertion. Pixel comparison of the icon is not in the test suite.

---

## Implementation notes (non-normative)

Starting points for whoever builds this:

1. **Introduce `BrandColors`** in a new file `Sources/BrandColors.swift`. Keep it flat — no theme abstraction. Seven static `NSColor` values, seven static SwiftUI `Color` bridges, nothing else.
2. **Rewrite `cmuxAccentNSColor(for:)` at `Sources/ContentView.swift:43-66`** to return `BrandColors.gold` regardless of `ColorScheme` / `NSAppearance`. Keep the function signatures (call-site compatibility). The existing call sites at `Sources/ContentView.swift:3341, 10463, 10681, 10689, 11129`, `Sources/NotificationsPage.swift:196, 200`, `Sources/BrowserWindowPortal.swift:1610-1611`, `Sources/Panels/BrowserPanelView.swift:74, 474, 475, 1099` keep working unmodified.
3. **Rewrite `sidebarSelectedWorkspaceBackgroundNSColor` at `Sources/ContentView.swift:115`** to return `BrandColors.gold`; no other change.
4. **Terminal default palette fragment.** Write `Resources/ghostty/c11mux-default.conf` per the table above. Wire it into the Ghostty config-loading path (`Sources/GhosttyConfig.swift`, which at line 158 already has `sidebarBackground = color` — same file, broaden the synthesis).
5. **Bundle JetBrains Mono.** Download OFL-licensed `.ttf` from the JetBrains release, drop into `Resources/Fonts/`, add `ATSApplicationFontsPath` key to `Info.plist` pointing to `Fonts/`. Register once in `AppDelegate.applicationDidFinishLaunching` if needed for UI font resolution.
6. **Add `system.brand` handler.** Extend the system-method switch in `Sources/TerminalController.swift:2021-2028`. Add `"system.brand"` to the capability list at `Sources/TerminalController.swift:2426-2427`. Off-main parse, main-actor snapshot of `Bundle.main`, off-main serialize. Add `cmux brand` CLI in the same PR.
7. **Icon asset generation.** Rewrite `scripts/generate_dark_icon.py` and `scripts/generate_nightly_icon.py` to operate on `design/c11mux-spike.svg` as the source rather than `design/cmux-icon-chevron.png`. Produce `AppIcon.appiconset`, `AppIcon-Debug.appiconset` (gold banner), `AppIcon-Nightly.appiconset` (purple banner), `AppIcon-Staging.appiconset` (dim banner) — all ten sizes from the existing `SIZES` list.
8. **Nightly Xcode scheme.** The Nightly bundle ID is not in the `.pbxproj` today. Add a Nightly scheme or a build-time xcconfig that overrides `PRODUCT_BUNDLE_IDENTIFIER = com.stage11.c11mux.nightly` and `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon-Nightly`. Coordinate with the rename-surface agent — if they're mid-rewrite of project metadata, stacking this lands cleaner as a follow-up commit.
9. **README header image.** New file `docs/assets/c11mux-header.png`, 720×240. Figma source at `docs/assets/c11mux-header.figma`. Commit both.
10. **Do not touch typography in `Sources/ContentView.swift`** as part of M5. Font migration is incremental — land `BrandFont` (a thin helper in `Sources/BrandFont.swift`), then migrate one surface at a time in follow-ups. The constraint from `code/cmux/CLAUDE.md` about `TabItemView` equatability (line 54 of that doc — "Do not add `@EnvironmentObject`, `@ObservedObject`") means typography changes on the tab row need care.

---

## Open questions

- **OSS Stage 11 brand usage.** c11mux is a public fork. Is the Stage 11 palette / "spike" concept something we are comfortable shipping under AGPL where downstream rebrands could reuse the spike mark? Recommend: keep the mark, add a trademark-style notice in `NOTICE` reserving "Stage 11" and the spike icon (code license separate from brand license is normal).
- **Third-party terminal palette overrides.** If Ghostty's config sets only `background` but not `palette`, do we inject the 16 ANSI colors anyway? Current spec says the full fragment is a unit — revisit if it causes surprise.
- **Light mode as a future option.** Spec forbids light-mode app chrome in v1. If enough user friction surfaces (accessibility, photosensitive users), the escape hatch is adding `BrandColors.accent(for: NSAppearance)` and wiring it from `cmuxAccentNSColor(for:)` — the seam is preserved.
- **Sparkle feed for the nightly channel.** Whether the nightly feed URL lands in the Nightly bundle's `SUFeedURL` vs. an xcconfig lookup is a CI-pipeline question, not a brand question. Named here so it doesn't get lost.
- **JetBrains Mono inside the terminal.** Ghostty's config ultimately chooses terminal font. If a user has no Ghostty config, we don't currently force-push a font. Should c11mux's default Ghostty fragment also set `font-family = "JetBrains Mono"`? Leaning yes for consistency, parked to avoid surprise for users who like their system default.
- **Channel icon for the iOS/mobile companion** (charter's Founder's Edition teaser). Out of scope for M5, but when that ships it will need its own icon derivation from the same spike source.
