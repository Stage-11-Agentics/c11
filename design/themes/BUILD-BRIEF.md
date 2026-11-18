# Build brief: the c11h theme system, all seven themes

Atin, 2026-11-02 (evening): "All of these themes are approved. Let's create a new c11 surface,
load Opus, and have it build this all out. Use Sonnet sub-agents as appropriate to build the
individual themes." You are that Opus agent, the **Theme Engine Lead** for this work.

## What exists

- **The prototypes.** `design/themes/c11h-themes.html` is the c11h window rebuilt in HTML with
  seven switchable themes (keys 1 to 7): c11, Datasheet Mono, Terminal Grid, c11h today, Outrun
  Horizon, Nocturne, Big Board. Atin approved every one. The CSS per theme is the design: a
  `[data-theme="x"]` token block plus flourishes. `README.md` beside it lists the themes and the
  rulings (too much red was cut from Datasheet Mono and Terminal Grid; keep it cut).
- **A chrome theme engine already ships** in `Sources/Theme/` (schema 1): TOML files, two slots
  (light, dark), hot reload from `~/Library/Application Support/c11h/themes`, bundled themes in
  `Resources/c11-themes/`, CLI `c11h themes list|set|get|dump|validate|reload|path|diff`, socket
  methods in `ThemeSocketMethods.swift`, roles in `ThemeRoleRegistry.swift`, tests in
  `c11LogicTests`. The original plan is `docs/c11-theming-plan.md`.
- **Three colour registers are already theme files:** `design/themes/toml/{nocturne,bigboard,
  datasheet-mono}.toml`, validated, installed in the user themes folder. Nocturne is active on
  Atin's dark slot right now (`c11h themes get`). Do not change his active theme without asking.
- **c11h's sidebar backdrop** (the Sunset Mall gradient) is a separate c11h-only setting:
  `Sources/C11HSidebarBackground.swift`, key `c11h.sidebar.backgroundDark`. It is the proof of
  concept for a backdrop layer and should fold into the theme schema.

## What schema 1 cannot carry, and the prototypes need

Schema 1 themes colours, opacities and divider/frame thickness only. The approved themes also need:

1. **Type roles**: a chrome font family (UI, title, mono) and label treatment (uppercase, tracking,
   size) for sidebar labels, the panel strip, the description bar chip and the titlebar.
2. **Geometry**: corner radius for cards, tabs, pills and controls (Datasheet Mono, Grid, Big Board
   are square; Nocturne 3 to 4 pt; c11 and Outrun keep today's radii).
3. **Sidebar backdrop**: a gradient (Sunset Mall, Outrun), a drawn grid (Outrun floor, Terminal
   Grid legend), or none. Cards keep opaque fills so text contrast never depends on the backdrop
   (that is how C11H-32 was measured).
4. **Ornaments and overlays**: the Outrun bust in the Waiting Agent pill, Outrun's scanlines, Big
   Board's titlebar clock and LIVE/HOLD tags, Datasheet Mono's hover brackets and inverted
   selected tab, Terminal Grid's box-drawing card headers. Some of these are features behind a
   theme switch rather than tokens; decide which, and say so in the design.
5. **State colours as roles**: waiting, running, flag, unread mail, cold, so a theme can make
   "needs you" amber (Nocturne) or orange (Datasheet) without touching c11's attention semantics.

## The job

Make every approved theme real in c11h, selectable with `c11h themes set <name>`, so Atin can
live in any of them. In order:

1. **Orient.** Load the `c11` and `c11h` skills, run `c11h guide`, name your panel
   (`Theme Engine Lead`), set `mailbox.address` to `theme-engine-lead` and `mailbox.delivery`
   to `stdin`. Read `C11.md`, `CLAUDE.md`, the files above, and the prototype page in a c11
   browser panel (`c11h browser open file://…/c11h-themes.html`; `keep-live on` before any
   screenshot). Find the c11h Lead in `c11h tree --all` and send them one mailbox line: who you
   are, what you are building, that you will file tickets on the board and open PRs.
2. **Design schema 2** as a short doc, `docs/c11h-theme-schema-2.md`: the new sections and
   roles, defaults that keep every schema-1 theme rendering unchanged, what is a token and what
   is a feature behind a switch, and the test plan. Keep it under two pages. Put the open
   questions for Atin at the top; he arrives cold.
3. **File the work** on the hosted Lattice board (`lattice remote status` shows the binding):
   one epic, tickets per capability (type roles, geometry, backdrop, state colours, ornaments)
   and one per theme. Non-trivial tickets run through `lattice-hosted-orchestrator` per
   `CLAUDE.md`; you may be the Orchestrator yourself. Builds go to the build host through
   `scripts/remote-build.sh` with one tag per seat; respect the slot rules.
4. **Build the engine changes** first, with `c11LogicTests` coverage (Theme is a logic target),
   then **the seven theme files**, translated from the prototype CSS. Use Sonnet sub-agents for
   the individual theme files and for mechanical translation; keep the schema design and the
   Swift rendering changes with you or an Opus seat. Each theme ships as a bundled file in
   `Resources/c11-themes/` with a screenshot in `design/themes/shots/` taken from a tagged build
   in a sandbox guest (`c11-computer-use`), compared against the prototype.
5. **Prove it as Atin sees it.** A tagged build on the build host, every theme set and screenshotted,
   zero regressions on `stage11`. Then PRs, the landing gate in `CLAUDE.md`, and main stays
   shareable throughout. Never push to `manaflow-ai/*`.

## Rules

- Atin is the customer of one; be aggressive visually and autonomously, inside the repo's
  guardrails. He calibrates by looking: when a theme needs a taste call, screenshot and ask,
  numbered, with your recommendation. Never ask him to compile or test.
- Report to Atin in your panel. First line: `Needs you: nothing` or numbered questions, each with
  what hangs on the answer. Under 100 words unless he asked for more.
- Local time, never UTC. No fast mode. No em-dashes in prose.
- Leave a stone: record what you learn about the engine in `docs/c11h-theme-schema-2.md` and
  `design/themes/README.md` as you go.
