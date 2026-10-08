Checkpoint 4 (orchestrator, 2026-10-08 12:45 PDT): all of C11-336's code is merged.

Finished:
- C11-358 web renderer: c37ced9d78 (#620).
- C11-359 native WKWebView panel: a95823705c (#621) plus follow-up fd263426f9 (#622).
- C11-360 reader chrome: bdb91b1e12 (#623).
- C11-361 agent CLI: 22786494a8 (#624).

In flight:
- A fresh Codex computer-use validator is proving C11-336 on an Atlas tagged build of main 22786494a8, against the round-4 prototype. Checks: the messaging doc with Mermaid, outline, find, source, themes and typefaces in both appearances, text size, 560 px and wide layouts, open-externally, live reload mid-scroll, the agent CLI on a background panel, restore, and a 20-panel memory check.
- C11-362 N1 navigation: GO (owner panel:133).
- C11-363 N2 corpus: pre-warmed.

Blockers: none.

Waiting on Atin: review depth for N1 and N2, running them in parallel, and C11-357 scope (asked in the orchestrator panel). Until he answers, N1 and N2 run serially with two reviews each.

Known, not ours: the main backstop test BrowserDeveloperToolsVisibilityPersistenceTests has been failing since 2026-10-06.
