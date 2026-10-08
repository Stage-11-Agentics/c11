Checkpoint 2 (orchestrator, 2026-10-08 04:35 PDT): first merge.

Finished:
- C11-358 R1 web renderer, merged as c37ced9d78 (PR #620) and completed in Lattice. Reviews: Opus Review 1 and Grok Review 2 both failed the first head (four blockers: diagram re-render drift, a sanitizer regex stripping links, KaTeX and icons, source toggle inside fences, scrollToLine stopping at block level). Both passed the repaired head; every fix was proven red when reverted.

Remaining:
- C11-359 R2 native panel: in repair. The large-track synthesis (Fable PASS, Astra FAIL, Opus reproduced on Atlas) found one blocker: the native panel-description renderer regresses ordinary Markdown that MarkdownUI handled. R2 is fixing it, adding missing guard witnesses, and rebasing onto main.
- C11-360 R3 reader chrome and C11-361 R4 agent CLI: pre-warmed, waiting on C11-359.
- C11-362 N1 and C11-363 N2: after R3 and R4.

Blockers: none.

Decisions since checkpoint 1:
1. Codex seats moved from Sol to Luna max (Atin). The global Codex default was left unchanged.
2. C11-359 weight: lazy creation alone kept every visited panel's WebKit process (25 processes, about 2.9 GB more RSS after visiting 20). Ruled bounded eviction in-ticket: visible panels plus 4 recent, with the reading position restored. Measured at 960 MiB physical footprint across 10 processes.
3. Bridge v1.1 adds a pixel offset for exact restore. Local images inside the document folder render through a native-validated scheme; everything else stays inert.
4. C11-359 is reviewed as a stacked PR while R1 repaired, instead of waiting for R1 to merge.
5. mailto: links are restored, since base opened them; no other link scheme widens.
