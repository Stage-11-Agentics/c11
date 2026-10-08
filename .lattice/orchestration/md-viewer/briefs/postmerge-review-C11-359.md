# Post-merge discovery review: C11-359 (native markdown panel on WKWebView)

C11-359 is **merged** to `main` as `a95823705c3912d8def621e3b2b7ed3384f47a4c` (squash of PR #621). It is on the large-ticket track: dependents now build on it, and you, a fresh pair (one Claude Fable, one Codex Astra), review the merged change against the normal-use bar. The Opus synthesis seat (`Synth 359`) merges both reviews, reproduces each finding or drops it, and runs any follow-up repair loop. You are read-only: never edit tracked files, push, or mint tickets.

## Identity
- Your launch prompt names your seat letter: **f** (Fable) or **a** (Astra). Panel title `Fable PM 359` or `Astra PM 359`; actor `agent:fable-md-pm-359` or `agent:astra-md-pm-359`. `export LATTICE_ROOT=/Users/atin/Projects/Stage11/code/c11`. Codex: `c11 conversation capture-runtime` once.
- Report to the Orchestrator only: `c11 mailbox send --to md-viewer-orchestrator --body "<one line>"`.

## Target
- Worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/md-pm-359-<letter>`, detached at `a95823705c3912d8def621e3b2b7ed3384f47a4c` (assert it). The change is `git show a95823705c3912d8def621e3b2b7ed3384f47a4c`; read the code it touches as it now sits on main.
- Prior history, so you don't repeat it: the pre-merge reviews and synthesis in `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/` (`review-C11-359-f.md`, `review-C11-359-a.md`, `synthesis-C11-359.md`, `synthesis-C11-359-verify1.md`, `synthesis-C11-359-verify2.md`) and the run's hardening list in `run-state.md`. Everything there is known; look for what nobody found.
- Contract, invariants, the bar and the method: `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/briefs/review-C11-359.md` (same rules: Atlas-only builds with tag `pm-359-<letter>`, demonstrate with mutations, the normal-use bar). Pay particular attention to seams the pre-merge reviews treated lightly: the description renderer swap (every place a panel description renders), session restore of old and new snapshots, live reload against eviction, the drag filter and link routing shared with the terminal and browser panels, and localization of every new string.

## Output
`$TMPDIR/pm-review-C11-359-<letter>.md`, copied to `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/pm-review-C11-359-<letter>.md`; post it with `lattice comment C11-359 --role review --file <it> --actor <your actor>`; send `VERDICT C11-359 PASS|FAIL a95823705c3912d8def621e3b2b7ed3384f47a4c <path>`. Then you're done.
