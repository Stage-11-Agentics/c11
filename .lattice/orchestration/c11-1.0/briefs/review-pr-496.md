# Review: PR #496 (c11 skill: launch-agent prompts are one-line pointers to a brief file)

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md` with these differences: there is **no Lattice ticket**, so skip every lattice step and post nothing to Lattice. Title `PR496 Review`. Do not post to GitHub.

- PR https://github.com/Stage-11-Agentics/c11/pull/496, branch `skill/short-launch-prompts`, head `c1be8afd15316e1b4dcf928431771d3b35782aea`, base origin/main `0ff8887e5e`. Docs-only: `skills/c11/references/orchestration.md`.
- Check: (1) every factual claim in the new text against the shipped CLI source on that head (how `launch-agent` delivers `--prompt` and `--prompt-file` to the agent process: argv, stdin or file), and that the example command is valid `c11 launch-agent` syntax; (2) it fits the c11 skill's style (short, present tense, no history narration); (3) disclosure (no home paths or private data).
- Blocking only if a claim is false or the example would fail.
- Write your review to `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/review-pr-496-result.md`, then send one line: `VERDICT PR496 PASS|FAIL c1be8afd15316e1b4dcf928431771d3b35782aea /Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/review-pr-496-result.md`.
