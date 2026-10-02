# Seat: Fixtures Attention Grok

Read and follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` first; it is your contract.

- **Tab title:** Fixtures Attention Grok
- **Actor:** `agent:grok-fixtures`
- **Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-fixtures` (branch `c11-1.0/C11-271-lifecycle-fixtures`, base origin/main `0ff8887e5e`)
- **Seat id for envelopes:** `fixtures`

## Queue
1. **C11-271** (P0): capture real lifecycle sequences as the journal and Feed fixture oracle. **Execute now, not just plan.**
2. **C11-263** (P0): attention bug batch. Plan it after the corpus exists (it depends on C11-271); implement in build mode on branch `c11-1.0/C11-263-attention-batch` from origin/main.

## C11-271 specifics (amendment from the run brief)
- The run brief directs: capture the corpus **from production c11 sessions now**, without waiting for an Atlas tagged build. That amends C11-271 AC1's 'tagged-build' wording: record the production c11 version and build (`c11 --version`, `c11 doctor --json`) in every capture's provenance, and mark any case that genuinely needs a tagged build as 'recapture on tagged build' in the manifest. Post a one-line comment on C11-271 recording this amendment.
- How to capture without tenant config writes: launch short-lived test agents in a **new c11 workspace you create** (`c11 launch-agent ... --new-workspace`, then close it when done), and record raw hook payloads **per process** (for Claude, an extra per-process `--settings` file you author under your worktree or `/tmp`, whose hooks append payloads to a capture file; the bundled wrapper's own hooks keep running). Also record c11's side: `c11 events tail`, `c11 get-metadata`, `c11 tree --json` before/after each step as the visible-state oracle. Never edit `~/.claude/settings.json`, `~/.codex/*`, `~/.config/opencode/*`.
- **No computer use or synthesized clicks/drags on this Mac** (Atin's screen is live). Drive agents with `c11 send`/`send-key` into your own test workspace only; read state through the socket. If an incident truly needs a human gesture, list it as a gap.
- Keep test agents cheap: tiny synthetic tasks (for example "list two files, then ask me a multiple-choice question"), short sessions, close them promptly. Codex test agents use a light model (`gpt-5.6-luna`), not Astra.
- Sanitize: no prompt/tool bodies, no real session/conversation IDs (replace with stable synthetic IDs), no account names, no home paths. Synthetic data only.
- Output in your branch: a fixture directory (propose a location, e.g. `c11Tests/Fixtures/lifecycle/`), a manifest linking every normalized record to its sanitized capture and distinguishing current behavior from intended projection, and a fixture reader/replay contract (code that runs in tests later; do not run tests now). You may commit and push this branch and open a **draft** PR when the corpus is complete; send HANDOFF REVIEW with the draft PR (review can run without a build).
