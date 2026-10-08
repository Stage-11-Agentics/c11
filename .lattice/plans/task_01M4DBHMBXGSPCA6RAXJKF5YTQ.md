# C11-359 implementation plan

Replace MarkdownUI and external fenced rendering with a lazy WKWebView retained by MarkdownPanel. Serve only bundled renderer assets and scoped sibling image files through a custom scheme; reject traversal, symlink escapes, remote requests and executable resources. Cancel navigation and route user links through c11. Use the R1 bridge once available; keep renderer code owned by R1.

Files: MarkdownPanel.swift (presentation model, retained lazy renderer), MarkdownPanelView.swift (WebKit host plus existing empty/drop/flash paths), a native renderer/scheme helper, SessionPersistence.swift and Workspace.swift (optional state snapshot), project.pbxproj and Package.resolved (bundle/dependency cleanup), old fenced-renderer files and registration, behavioral tests, markdown skill and threat notes.

Acceptance proof: state/default/fallback and snapshot round-trip tests plus scheme containment and link-policy tests; Atlas md-359 narrowed logic run and tagged app; offline Mermaid, hostile fixture, live reload/scroll, scale shortcuts, session restore; compare 20-panel creation and memory with tagged origin/main and record load. Preserve markdown.get_content and existing open/drop/focus paths. Lazy construction must happen only when visible, no new per-keystroke work or synchronous telemetry hops.

Cut line: minimal existing filename row; no R3 chrome or R4 CLI features, no editor, diff UI or linked-doc history. New errors reuse localized keys where possible; new strings get six translations. Per-panel theme/typeface/outline defaults and scale persist independently with field-local decoding fallbacks. No installed skill sync: Merge Captain owns that per launch contract.

## Amendment after automatic plan review

R1's final image amendment is accepted: c11md-asset://doc/ relative encoded paths inside the document directory subtree. Each WKWebView owns its own scheme handler/capabilities and controller; only process pool/nonpersistent data store are shared. Native denies raw HTML/SVG/script image resources and validates actual raster content. R2 owns pbxproj's folder reference per its owner brief.

WebKit integration: share the drag-type filter with the browser; route native Command equivalents through the main menu and shared app-level handler; keep MarkdownWKWebView separate from CmuxWebView/browser focus lookups. A focused mounted markdown view can become first responder; hidden/unfocused views cannot auto-acquire it. User pointer focus remains available. No app-wide per-keystroke work is added. Add tab drag, Cmd-W/D/1, scrolling and copy to sandbox proof.

Link allowlist: anchors stay local; only relative .md/.markdown/.mdown files open a markdown panel in the source area; HTTP(S) uses the shared terminal/browser-settings routing helper with the same preferred-browser-area or new-split placement and Option override. Executables, arbitrary files, absolute/file URLs and all other schemes are refused. Add executable/application links to hostile fixtures.

Weight proof includes all c11/WebKit RSS and process counts in an isolated guest, with guest and Atlas load averages. Measure twenty never-shown panels, then visit all twenty. RSS is explicitly approximate (shared pages may be counted more than once); do not represent it as physical footprint. Keep an eviction change out of this implementation until measured evidence warrants a design change.

Queue latest model settings/content until ready; hide the page until its first rendered event; keep pageZoom=1 and magnification/back-forward gestures off. Recover terminated WebContent by loading latest settings/content, then restoring its last visible line. Pass effective appearance and localized strings. State restore defaults are distinct from interactive zoom clamping. Ship names match R1's accepted registry IDs; adding names requires updating the native validated registry until a shared manifest is introduced.

MarkdownUI's second consumer is handled within removal: replace expanded title-bar descriptions with native SwiftUI blocks and Foundation inline attributed text, preserving existing sanitization, heading/list/quote/rule support, inactive links and height cap. Behavioral tests cover that replacement. Existing root and Xcode workspace Package.resolved are both cleaned.


Orchestrator eviction ruling (2026-10-08): retain every actually visible markdown WebKit renderer plus a process-wide LRU of four hidden renderers (single named constant). Model-only policy tests cover ordering, visible protection, query pinning and removal. Native cache tracks weak panels and candidate epochs; capture visible() before close and revalidate hidden/pin status before teardown. Every renderer.call pins its renderer until completion. The panel retains first line, lines.offset, mode and find query; evicted reloads update text only. Recreation sends settings/load and restores mode/find then scrollToLine(line,offset) before removing first-paint opacity. No focus or window activation on eviction/recreation. R1-approved additive bridge lines.offset and scrollToLine(line,offset=0) arrives on side branch.

Repeat the same origin/main and integrated 20-panel guest scenario using physical footprint per c11/WebKit process, record hidden/visited counts/load and median10 evicted re-show latency. Runtime screenshot pair must show same mid-document line after evict/re-show. Existing raw-content query remains model-only. Add lifecycle/query/restore host tests and model-policy logic tests. No installed skills sync.
