Merged as PR #457 (squash 711faff24), 2026-09-30, with Atin's explicit approval.

Review trail:
- Design: three HTML prototype rounds with Atin, plus a fresh-context design review (11 findings, folded into the spec before the build).
- Build: Sonnet worker, phases 1 and 2 in one PR (C11-241 and C11-242 folded in at Atin's request).
- Code: fresh-context review of the PR found 14 issues (1 must, 8 should, 4 nits, test gaps); all fixed. 68 picker unit tests pass.
- Atin's own click-through of the tagged build: pinning, double-click, keyboard shortcuts and search all work. Two changes followed: the name column hugs its width (path gets the rest), and the picker shows only the four standard layouts (custom blueprints stay CLI-only).
- Merged with origin/main (8 commits, bonsplit bump); the Debug build succeeds locally, and all CI checks pass on the merge head.

Not verified on screen: the final column-width change (built, not relaunched, so Atin's screen stayed free); window re-sizing when the picker moves to another display; VoiceOver labels.