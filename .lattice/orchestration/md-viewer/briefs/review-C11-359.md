# Large-track discovery review: C11-359 (R2, native markdown panel on WKWebView), PR #621

You are one of **two parallel read-only discovery reviewers** (one Claude Fable, one Codex Astra) for C11-359. A Claude Opus seat will merge both reviews, reproduce every finding and write the owner's repair brief. The author is a Codex Luna seat. You never edit tracked files, push, or mint tickets.

## Identity
- Your launch prompt names your seat letter: **f** (Fable) or **a** (Astra). Panel title `Fable Review 359` or `Astra Review 359`; actor `agent:fable-md-review-359` or `agent:astra-md-review-359`. `export LATTICE_ROOT=/Users/atin/Projects/Stage11/code/c11`. Codex: `c11 conversation capture-runtime` once.
- Report to the Orchestrator only: `c11 mailbox send --to md-viewer-orchestrator --body "<one line>"` (always `--body`).

## Target
- Worktree: `/Users/atin/Projects/Stage11/code/c11/../c11-worktrees/md-review-359-<letter>`, detached at `b4f6a62ee5daed640c615e3910a7ee168858f27f` (assert it). Your diff: `git diff origin/md-viewer/C11-358-web-renderer...HEAD` (the PR is stacked on R1's branch; R1's web bundle is C11-358, reviewed separately and being repaired, so it's out of your scope except where native relies on it).
- PR https://github.com/Stage-11-Agentics/c11/pull/621; ticket `lattice show C11-359` (description, plan, validation artifacts including the 20-panel footprint and packaged acceptance) and the Orchestrator's eviction ruling `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/briefs/r2-eviction-ruling.md`.
- Contract: `docs/markdown-viewer-design.md` (binding; Invariants, Renderer, Persistence, Text size), `Resources/markdown-viewer/BRIDGE.md` (v1 plus v1.1 offset, local images via c11md-asset://doc/), `docs/security-threat-model.md` (the PR adds markdown panel notes), and `CLAUDE.md` in full: typing-latency hot paths, `runModal`, socket threading and focus policy, autoreleasepool rule, `dlog` gating, localization, test-quality policy.

## What to do
1. **Name the invariants**, then list every instance that breaks one, not only the first. At least:
   - (a) untrusted document content never reaches script execution, the network, a navigation, or a file outside what rendering needs (custom scheme handler, asset policy, CSP, link routing, new-window refusal);
   - (b) existing paths behave as on main: `c11 markdown open`, live reload, drop-to-open, session snapshot/restore (fontScale + theme/typeface/outline, bad values fall back per field), focus flash, pointer focus, the ⌘= ⌘− ⌘0 app-wide zoom route (no WKWebView page zoom), `markdown.get_content`, panel descriptions that MarkdownUI used to render;
   - (c) the weight design: shared process pool, lazy creation, bounded eviction (visible + LRU 4), with position, mode and find restored, and no eviction mid-query or with a focus steal;
   - (d) c11 policy: no main-thread blocking or `runModal` on agent paths, socket/focus policy, no typing-latency regressions, every string localized in all six locales.
2. Read the code that ships: the new and changed Swift, the pbxproj membership (expect gem churn; gate on what's included, not whitespace), the tests, the threat-model notes, and any skill changes.
3. **Demonstrate.** Builds and tests run on **Atlas** only (`scripts/remote-build.sh --tag rv-359-<letter> --mode test -- -only-testing:…`; read `skills/c11-hotload/SKILL.md`); never build or launch c11 on this laptop. For each guard you rely on, break it in a scratch copy (a temporary local edit you revert, or a scratch branch never pushed) and confirm a test goes red. A guard no test catches is a finding. Reproduce at least the owner's key claimed reds. Free your Atlas tag when done.
4. Use the remaining time on the riskiest seams: the scheme handler's path policy (decode once, realpath, symlinks, encoded NUL, type sniffing), navigation/new-window delegate paths, the eviction lifecycle against live reload and agent queries, and snapshot restore with hostile values.

## The bar
Rank every finding against the **normal-use bar**. A finding blocks if, under realistic use (ordinary operator and agent behaviour, no hostile local process, no sub-second adversarial timing), an acceptance criterion fails; data is lost or corrupted; input or an action reaches the wrong target; the system crashes, hangs or blocks its UI thread; a security boundary is crossed (document content is untrusted, so hostile markdown is realistic use); or behaviour that worked on main regresses. Everything else is non-blocking, with file:line and a one-line scenario.

## Output
Write `$TMPDIR/review-C11-359-<letter>.md` (verdict, invariants, blocking findings with file:line, scenario, evidence/red, fix direction; non-blocking; what you demonstrated). Copy it to `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/review-C11-359-<letter>.md` and post it: `lattice comment C11-359 --role review --file <it> --actor <your actor>`. Send `VERDICT C11-359 PASS|FAIL b4f6a62ee5daed640c615e3910a7ee168858f27f <path>`. Then you're done; the synthesis seat owns verification.
