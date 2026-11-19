# c11 2.0 education: prototype (C11H-335)

How c11 2.0 teaches what c11 1.x users have never seen: terminals that outlive the app, linked
machines, and agent mail. Atin, 2026-11-15 15:03: "we're adding a bunch of functionality, and we
need to do a really good job of educating users about it."

**Open it:** `c11 show docs/design-prototypes/c11-2.0-education/index.html` from the repo root.
One self-contained page, light and dark, keys 1 to 6 switch views.

| Key | Surface | State |
|---|---|---|
| 1 | What's New in c11 2.0, first run: three short pages, three audiences (from 1.x, fresh install, from c11h) | Approved; phase 2 builds it in `Sources/WhatsDifferentView.swift` |
| 2 | The link consent screen | A pointer: C11H-332 owns the screen, its words and the trust page (`c11 guide trust`) |
| 3 | Docs landing page | Approved; a static page beside the download page (C11H-177) |
| 4 | Launch post outline | Outline with a proposed headline and first lines; nothing is published without Atin's go |
| 5 | The 2.0 CHANGELOG edits | Made in this branch |
| 6 | Decisions | Ruled by Atin |

## Decisions (Atin, 2026-11-18 13:45, through the C11 Captain)

1. **Shape of What's New:** one page per concept, three pages, the must-know first.
2. **Captains:** Captains and the fleet belong to Flagship, an optional, opinionated expansion of
   c11 that is a separate thing (possibly its own private, invite-only repo). What's New has no
   Captains page; the changelog keeps the workspace captain key only as a plain c11 primitive.
3. **Docs landing page:** a static page beside the download page (C11H-177).
4. **Launch post:** lead with terminals that keep running, in Atin's framing: herdr-core keeps
   terminals running; local or on servers, all the same, all orchestrated. That's c11. On GitHub
   release notes and the Stage 11 site.
5. **Phase 2:** C11H-335 builds the sheet in Swift, in English plus ja, uk, ko, zh-Hans, zh-Hant
   and ru, as its own PR.

The link consent screen is not a decision here: C11H-332 chose its form (a page after Add, "Link
<host> to c11?") and owns its words and the trust page. These surfaces link to them.

## Rules the copy follows

- Every claim traces to the 2.0.0 CHANGELOG entry or the c11 skill pages.
- Mock machine names only (`studio`, `build-box`); no Stage 11 host, machine or path names.
- In-app copy matches the existing sheet's voice and strings; external pages use standard case and
  "you".
- Nothing waits on a click: terminals run whether the sheet is open, closed or never seen.
