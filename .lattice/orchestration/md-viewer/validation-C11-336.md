# C11-336 Markdown Viewer Validation (interim)

**Run state:** Interim, 2026-10-08 14:44 PDT. Validation is continuing until 15:15 PDT.
**Builds:** Initial guest used `22786494a86a2d32ab7cddc901b8464e139333e0`; fresh guest is on exact `origin/main` `f440a14f0ee6047982d69d4399a5507258f3e717`. The intervening diff did not change Markdown viewer sources or docs. Evidence filenames link into `validation-C11-336/`.
**Progress:** 11/14 items exercised to some degree. Partial and failed items remain counted as exercised; item 14 is untouched.

| # | Status | Evidence and result |
|---|---|---|
| 1 | PASS | `validation-C11-336/layout-narrow-560.png`, `wide-target.png`, `rendering-table-stacked-560.png`, `rendering-code-copy-final.png`. Prose, tables, and code copy were checked against the prototype. The fixture has no footnotes or callouts, so those subcases were not present. |
| 2 | PASS | `mermaid-01-architecture.png` through `mermaid-07-end-to-end.png`; `mermaid-01-expanded.png`, `mermaid-01-pan.png`, `mermaid-01-zoomed.png`, `mermaid-01-reset-100.png`. Seven diagrams, including a sequence diagram, rendered; expand, pan, zoom, and reset worked. This is from the initial guest; repeat on the fresh exact-head guest is pending. |
| 3 | FAIL | Fresh exact-head evidence: `fresh-outline-shortcut.png`, `fresh-outline-filter.png`, `fresh-outline-jump.png`, `fresh-outline-escape-first.png`, `fresh-outline-escape-second.png`, `fresh-new-panel-preference-selected.png`, `fresh-panel6-after-new.png`. Shortcut, filter, and jump work. Escape first clears the filter, then closes the outline on the next press; this is the specified order and passes. **Failure repro:** at wide width, explicitly close the outline on panel 6; confirm it stays closed (`fresh-panel6-after-new.png`); create a new Markdown panel in the same workspace with `c11 new-panel --type markdown --file <fixture> --workspace workspace:2 --area area:6`; the new panel 8 opens with the outline docked (`fresh-new-panel-preference-selected.png`). The closed choice did not become the new-panel default, contrary to the design doc. |
| 4 | PASS | Fresh exact-head evidence: `fresh-find-cmd-f.png`, `fresh-find-mailbox.png`, `fresh-find-next.png`, `fresh-find-escape.png`. Cmd+F and the toolbar opened find; match count advanced from 1/83 to 2/83; Escape closed find. |
| 5 | PARTIAL | Fresh exact-head evidence: `fresh-source-before.png`, `fresh-source-view.png`, `fresh-source-outline.png`. Source mode preserved the document location across the rendered/code-fence transition. The narrow outline overlay covers source text as designed; docked-outline coverage at wide width still needs validation. |
| 6 | PASS | `system-theme-light-appearance.png`, `system-theme-dark-appearance.png`, `theme-dark-with-dark-appearance.png`, `theme-light-with-light-appearance.png`, `theme-dark-with-light-appearance.png`. System/light/dark were checked in both c11 appearances; glyphs were visible. Initial guest evidence. |
| 7 | PARTIAL | `wide-theme-light-serif.png`, `typeface-sans.png`, `typeface-mono-size-120.png`. Default serif, Literata, SF Pro, and mono selection were exercised; the requested numerical measure was not recorded. Initial guest evidence. |
| 8 | PASS | Fresh exact-head evidence: `fresh-size-plus.png`, `fresh-size-minus-final.png`. Toolbar plus/minus and Cmd+=, Cmd+−, Cmd+0 were exercised; CLI readout tracked 110%, 120%, 90%, and reset to 100%. The same document heading/line neighborhood remained visible and page zoom did not change. |
| 9 | PARTIAL | Fresh exact-head evidence: `fresh-layout-560.png`, `fresh-resized-full.png`, `fresh-single-panel-wide.png`. Exact 560 px content width and wide layout were inspected; resize sweep through 430/600 px and outline threshold was not completed. |
| 10 | PASS | Fresh exact-head evidence: `fresh-open-external-tooltip.png`, `fresh-open-external-result.png`. Tooltip identified TextEdit and the action opened the current Markdown file in TextEdit. |
| 11 | PARTIAL | Initial guest live-reload evidence is in `validation-C11-336/` (see `session-restore.png` and the `reload-*` captures). Append-below, insert-above, and edit-current were exercised while scrolled, then the fixture was restored byte-for-byte. Repeat on the fresh exact-head guest is pending. |
| 12 | PARTIAL | Initial guest exercised guest-terminal CLI scroll, visible JSON, visible watch, theme, typeface, font, and open-external against a background workspace without changing selected workspace. Fresh exact-head background-panel pass is pending. `c11 conversation capture-runtime` was attempted once on the fresh guest and returned `missing_runtime_id: CODEX_THREAD_ID required`; no runtime ID was available to supply. |
| 13 | PARTIAL | Initial guest restored non-default size (1.2), dark theme, mono typeface, and outline after quit/resume; evidence `before-restore-quit.png`, `session-restore.png`. The document returned to the top; explicit hidden-outline override semantics were not checked. Fresh exact-head repeat is pending. |
| 14 | PENDING | 20-panel weight/visit check, process count, physical footprint, and load average have not been measured. |

## Known acceptance failures

1. Closing the outline explicitly on an existing wide panel did not persist that choice as the default for a newly opened wide Markdown panel. Reproduction is recorded under item 3; see `fresh-panel6-after-new.png` and `fresh-new-panel-preference-selected.png`.

This is an interim record. Current exact-head reruns and remaining checks will be added before closeout.
