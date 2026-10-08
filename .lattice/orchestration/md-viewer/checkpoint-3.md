Checkpoint 3 (orchestrator, 2026-10-08 08:35 PDT): the native panel is done.

Finished:
- C11-358 R1 web renderer: c37ced9d78 (#620).
- C11-359 R2 native WKWebView panel: a95823705c (#621) plus the post-merge follow-up fd263426f9 (#622).
  - Large-track review: Fable and Astra in parallel, synthesized by Opus.
  - Pre-merge: the native panel-description renderer regressed ordinary Markdown, and its fix then broke nested lists; both were fixed.
  - Post-merge: an evicted panel lost its place after edits above it, and the c11 appearance switch didn't reach system-theme readers; both were fixed in #622.
  - Weight: 20 visited panels use 960 MiB physical across 10 processes, thanks to bounded eviction.

Remaining:
- C11-360 R3 reader chrome: PR #623 in Review 1 (Opus).
- C11-361 R4 agent CLI: validating on Atlas.
- C11-362 N1: pre-warming. C11-363 N2: after N1.
- Final: a fresh computer-use validator on a tagged build (C11-336 and C11-357 acceptance).

Blockers: none.

Decision since checkpoint 2:
1. The outline and find bar render inside the web page. Native owns the toolbar, the outline toggle, ⇧⌘O and the persisted choice. R3 asked for a native outline; I chose in-page for exact fidelity and zero per-frame bridge traffic.
