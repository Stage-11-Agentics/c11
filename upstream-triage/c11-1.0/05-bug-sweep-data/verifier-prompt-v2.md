# Upstream bug-fix verification (read-only research)

You are verifying upstream cmux bug fixes against c11, a fork of cmux. You are one of ten parallel verifiers (Codex and Grok agents in c11 tabs), each with one batch.

## Context
- c11 repo: `/Users/atin/Projects/Stage11/code/c11` (branch main). cmux is the `upstream` remote; `upstream/main` is fetched and current (2026-10-01). The fork point is `53910919` (2026-03-18). c11 has diverged a lot since (renamed cmux→c11, own sidebar/metadata/mailbox/markdown/browser work), and upstream has extracted much code into `Packages/macOS/*`.
- **STRICTLY READ ONLY.** No edits to the repo, no branches, commits, builds, tests, `git fetch`, `xcodebuild`, or `swift`. You may only `git show`, `git log`, `git grep`, `git diff`, read files, and `gh` (read). Write output only to the path given below. This machine is shared; no heavy work.
- PR → upstream commit map: `/Users/atin/Projects/Stage11/code/c11/upstream-triage/c11-1.0/05-bug-sweep-data/pr_sha.tsv` (pr, sha, kind). For kind=squash, `git show <sha>`; for kind=merge, `git diff <sha>^1 <sha>`. If a PR is missing from the map, use `gh pr diff <N> -R manaflow-ai/cmux` and `gh pr view <N> -R manaflow-ai/cmux --json title,body`.
- Upstream code at a point in time: `git show <sha>:<path>`. c11 code: the working tree (read files directly, cite `path:line`).

## c11's own known problems (cross-reference these)
1. **2026-08-25 freeze:** `Surface.deinit` teardown deadlock. Main joins io thread, io joins read thread, read thread blocked on `.forever` push into ghostty's shared 64-slot app mailbox that only main drains. Still unfixed in c11 (`ghostty/src/App.zig:571`, `ghostty/src/termio/stream_handler.zig:134,172`, `ghostty/src/termio/mailbox.zig:92`). Note: `notes/2026-08-25-freeze-surface-deinit-deadlock.md`.
2. **Main-thread congestion with many workspaces/agents:** SwiftUI AttributeGraph dirty-propagation storms in `VerticalTabsSidebar.body` / `SurfaceTitleBarView`; `runloop-idle` late heartbeats (main queue minutes deep); hover hit-test recursion (`mouseMoved → HoverEventDispatcher → MultiViewResponder.containsGlobalPoints`) holding main 2 min; a 62-minute stall from `Workspace.surfaceTitleBarState` doing `SurfaceMetadataStore.getMetadata` (DispatchQueue.sync) inside sidebar body.
3. **2026-07-28 deadlock** (cause not recorded) with ~22 agents running.
4. Already fixed in c11: ghostty_surface_set_display_id main deadlock (#403), ghostty_surface_free_text ABI leak (C11-212), renderer updateFrame skipped when occluded (C11-225), socket accept-loop autoreleasepool leak (C11-211), runModal on agent paths (C11-204), socket path unlink by tests (C11-105).
If an upstream fix explains or addresses one of these, say so explicitly.

## Atin's use profile (drives severity)
One operator running 10-40 agents (Claude Code, Codex) in parallel across many workspaces, sessions lasting days, heavy agent-driven CLI/socket traffic (`send`, `read-screen`, `set-metadata`, `tree`), frequent surface create/close, restarts with session restore. Severity: **high** = hang, deadlock, crash, data/layout loss, input corruption, unbounded memory/CPU growth under that profile. **med** = visible misbehavior hit regularly, or a perf cost that scales with agent count. **low** = cosmetic, rare edge case, or single-setting.

## Method
1. **Triage every row** in your batch. Give each a disposition:
   - `na-feature`: the fix is to a feature or code c11 does not have (cloud, iOS, SSH/remote, tmux compat, vault, diff, file explorer, feed, canvas, AppKit sidebar list `Sources/Sidebar/AppKitList`, upstream-only settings UI, agent hook integrations c11 lacks, etc.), OR fixes a bug in code upstream added after the fork that c11 never got.
   - `noise`: test-only, CI, docs, revert-of-revert, refactor with no behavior fix, cosmetic too small to matter.
   - `verify`: plausibly a bug in code c11 still shares.
   Be decisive; a one-line reason each. Do not skip rows.
2. **Verify every `verify` row**, highest severity first. For each: read the upstream diff, name the root cause in one sentence, find the matching c11 code and cite `path:line`, and decide:
   - `shared-confirmed`: you found the same buggy code in c11 (cite it).
   - `shared-probable`: c11 has the code path and very likely the bug, but you could not pin the exact line or the trigger depends on runtime behavior.
   - `already-fixed`: c11 fixed it (cite the c11 code or commit; `git log --oneline -S<symbol>` and `git log --grep` help).
   - `n/a-diverged`: c11's code diverged so the bug cannot occur (say why).
   Check c11's own git history too (`git log --oneline --since=2026-03-18 -- <path>`), since c11 sometimes fixed the same bug independently or cherry-picked it in April (C11-20, C11-21).
   Group duplicate PRs that fix the same bug into one entry (list all PR numbers).
   If you run short of time on low-severity rows, mark them `verify-skipped` with a guess, but finish every high and med one.
3. For confirmed/probable rows give: severity (high/med/low), port difficulty (S: under a day, cherry-pick or small rewrite; M: days, needs adaptation; L: a week+, architectural), recommendation (`port` = cherry-pick-ish; `reimplement` = take the idea, write it c11's way; `watch` = real but low value now; `skip`).

## Output
Write markdown to `/Users/atin/Projects/Stage11/code/c11/upstream-triage/c11-1.0/05-bug-sweep-data/verdicts/<BATCH>.md` with:
1. `## Verified` table, one row per bug (grouped PRs): `bug (plain English) | PRs | subsystem | c11 status | severity | port | rec | evidence (upstream file + c11 path:line) | notes (incl. link to c11 known problem)`. Sort high severity first.
2. `## Top findings` : up to 5 paragraphs on the most important shared bugs, with the mechanism and why it matters for Atin.
3. `## Triage ledger` : every row of the batch as `pr | disposition | one-line reason`.
4. `## Counts` : rows in batch, na-feature, noise, verify, and for verify: confirmed, probable, already-fixed, n/a-diverged, skipped.
Plain short sentences, no em-dashes. Mark inferences as inferred.

When done, reply with only: the output path and the counts line. Do not message anyone else.

## Round 2 notes (read these; they override anything above)
- Some rows were already verified in round 1. Before verifying a row, grep its PR number or commit SHA in `/Users/atin/Projects/Stage11/code/c11/upstream-triage/c11-1.0/05-bug-sweep-data/verdicts-lead.md`, `verdicts-browser.md` and `verdicts-focus.md`. If it is there, mark it `done-round1` in your ledger and move on.
- **Ghostty batches** (`ghostty-a`, `ghostty-b`): rows are commits in cmux's Ghostty fork (columns: sha, date, subject). They are present in c11's submodule at `/Users/atin/Projects/Stage11/code/c11/ghostty` (`git -C ghostty show <sha>`). c11's Ghostty HEAD is `26c3e499e`; merge-base with cmux's fork is `b9989c101`. Check whether c11's Ghostty already has an equivalent change (`git -C ghostty log --oneline b9989c101..26c3e499e -S<symbol>`). Many are upstream Ghostty housekeeping: be quick with noise.
- **perf-supplement batch:** performance PRs without "fix" in the title. Judge whether the slow path exists in c11 and matters at 10-40 agents.
- **socket-layout-perf batch:** also triage the 39 changelog-only fixes in `/Users/atin/Projects/Stage11/code/c11/upstream-triage/c11-1.0/05-bug-sweep-data/cl_nopr.txt` (no PR link; find the commit with `git log upstream/main --grep`).
- Write your output file progressively (create it early, append as you go) so partial work survives if you are interrupted.
- When finished, set your c11 tab description to `Done: <counts line>`. Do not message any other tab.
