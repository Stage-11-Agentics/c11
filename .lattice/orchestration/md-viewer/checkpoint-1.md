Checkpoint 1 (orchestrator, 2026-10-08 ~02:05 PDT): run started.

Finished: none. Remaining: all six child tickets.
Split: C11-336 → C11-358 R1 web renderer bundle, C11-359 R2 native WKWebView panel, C11-360 R3 reader chrome, C11-361 R4 agent CLI + skill. C11-357 → C11-362 N1 in-panel navigation, C11-363 N2 palette/backlinks/ticket links.
Active: R1 and R2 owners (Codex Sol High) building in parallel. R1 pushes the JS bridge contract first so R2 can build against it, and R2 lands after R1. Merge Captain (Sol) is up. Fleet workspace: "md viewer build".
Blockers: none.
Decisions taken (our assumptions; Atin can overrule):
1. 357 corpus for ⌘K and backlinks = the git repo containing the open file, falling back to its directory; skip .git, node_modules and build outputs.
2. Ticket IDs link only when that repo has a .lattice/ board (read-only hover card); otherwise they stay plain text.
3. Vimium-style link hints are out.
4. Toolbar is native SwiftUI (the doc names the browser buttons it mirrors). R3 decides whether outline and find live natively or in the web view.
5. Reviews: Claude Opus first, Grok second. R2 gets the large-ticket track (Fable + Astra discovery, Opus synthesis, post-merge review) because it carries the security boundary.
6. Builds, tests and computer use run on Atlas tagged builds; the laptop runs only the inner loop. A watchdog on Atlas DMs Atin on Telegram if the orchestrator goes silent for 30+ minutes.
