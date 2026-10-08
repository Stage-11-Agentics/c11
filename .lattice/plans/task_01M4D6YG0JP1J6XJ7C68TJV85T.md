# C11-357: Markdown viewer: navigate linked docs in place (history, peek, jump palette, backlinks)

Atin (2026-10-08): split out of C11-336 as its own ticket. Builds on C11-336's WKWebView markdown renderer.

Design reference: the navigator prototype, docs/design-prototypes/markdown-viewer/navigator/index.html (round 1, not yet iterated with Atin; iterate it before building).

Scope:
- Relative links and in-doc anchors open in the same markdown tab, with per-tab back/forward history (Cmd[ / Cmd]) and a breadcrumb. Cmd-click opens in a new c11 tab; a toggle sets which is the default.
- Hover peek: a link previews the target section's real content. Broken anchors suggest the closest heading.
- Cmd+K jump palette over headings across docs plus file names.
- Referenced-by backlinks for the current doc and section.
- Ticket IDs (C11-123) auto-link to Lattice with a hover card.
- Agent-native: `c11 markdown open --tab <t> <file>#<anchor>` moves an existing tab and pushes history instead of spawning a new one, without stealing focus; `c11 markdown history --json`; `c11 markdown links --broken --json`.

Open questions for the iteration round: the corpus boundary for Cmd+K and backlinks (the workspace root? the repo? open tabs only?), and whether Vimium-style link hints (`f`) belong.
