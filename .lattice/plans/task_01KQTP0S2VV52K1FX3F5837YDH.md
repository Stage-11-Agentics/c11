# C11-24: Right-click menu: show surface manifest JSON

## Summary

Add a right-click (context menu) entry on every c11 surface — terminal, browser, markdown — that opens a viewer showing the **surface manifest** JSON: the arbitrary, broadcastable per-surface blob agents read/write via `c11 set-metadata` / `c11 get-metadata`. Goal: a one-click way for the operator (or an agent walking the operator through something) to *see* the JSON blob a surface is broadcasting, without dropping to the terminal to run `c11 get-metadata --surface ...`.

## Why

The surface manifest is a first-class extension surface for c11 (canonical keys + free-form keys, see `skills/c11/SKILL.md` "The surface manifest"). Today inspection is CLI-only — fine for agents, friction-heavy for the operator and for live demos / debugging dialogues. A right-click menu item collapses that to one gesture. Useful in three modes:

1. **Dialogue / demo** — explaining what each surface advertises while showing it.
2. **Debug** — confirming canonical keys (`role`, `status`, `task`, `model`, `progress`, `terminal_type`, `title`, `description`) and any third-party keys (Lattice, Mycelium) are what you expect.
3. **Test** — verifying agent writes landed on the right surface (especially after the `set-metadata` env-default footgun).

## Sketch

- Right-click on any c11 surface → context menu gains an entry, e.g. **"Show surface manifest…"** (exact label TBD; see open questions).
- Selecting it opens a panel/sheet/popover (TBD) rendering the manifest JSON pretty-printed and read-only at minimum. Stretch: include provenance (`--sources` style — who wrote each key, when), and a copy-to-clipboard action.
- Should work on every surface kind that has a manifest: terminal, browser, markdown.
- Scope creep guards: no editing in v1, no live subscribe (manifest is pull-on-demand per spec). Re-render on menu re-open is fine.

## Open questions (defer to plan phase)

- **Label.** "Show manifest", "Show surface JSON", "Inspect manifest", "Show metadata"? Pick one consistent with how the manifest is referred to in the rest of the UI/docs.
- **Surface (UI).** Floating panel? Sheet? Inspector pane? Reuse any existing JSON-viewer chrome we already have, or new component.
- **Pane manifest too?** Panes carry their own manifest layer (see "Pane-layer lineage" in c11 skill). Decide whether right-click on the pane (vs. the surface) shows the pane manifest, or whether one viewer toggles between them.
- **Provenance toggle.** Show the `--sources` view as default, on toggle, or not at all in v1.
- **Copy / export.** Copy-to-clipboard is cheap; "save to file" is probably out of scope.
- **Discoverability.** Whether to also add a keyboard shortcut, or leave that for a later pass.

## Related

- `CMUX-19` — Per-surface theme button (right-click menu): same context menu we'd be extending.
- `CMUX-14` — Lineage primitive on the surface manifest: same manifest, different feature.
- `skills/c11/SKILL.md` "The surface manifest" — canonical key reference; v1 viewer should render canonical and non-canonical keys legibly.

## Out of scope (v1)

- Editing the manifest from the viewer.
- Live subscribe / push updates (spec says pull-on-demand).
- Cross-surface manifest browser / aggregator UI.
