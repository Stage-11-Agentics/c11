# Action-Ready Synthesis: claude-agents-passthrough

## Verdict
fix-then-merge

The 13-line passthrough fix is correct and merits landing. Five of six reviewers independently flagged one issue that should land in the same PR: the new passthrough arm execs before `unset CLAUDECODE`, which can poison interactive Agent View launches (`claude agents`, `claude attach <id>`) in c11 terminals whose parent shell inherited `CLAUDECODE=1`. The fix is one line. Everything else is follow-up or evolutionary.

## Apply by default

### Blockers (merge-blocking)

*(none)*

No reviewer flagged a true blocker. The `CLAUDECODE` issue below is rated "Important — land in same PR" by 5 of 6 reviewers; critical-codex called it "not production-ready as written," but the consensus around it is "small defensive move, ship with it" rather than "do not merge."

### Important (land in same PR)

**I1. Unset `CLAUDECODE` before the Agent View passthrough arm.**
- Location: `/Users/atin/Projects/Stage11/code/c11/Resources/bin/claude:125-133`
- Problem: The new `case` arm at line 125-128 `exec`s the real Claude binary before `unset CLAUDECODE` runs at line 133. When a c11 terminal inherits `CLAUDECODE=1` from a parent Claude Code session (common operator pattern), running `claude agents` or `claude attach <id>` from that terminal hands the nested-session marker through to the real binary. The TUI may emit nested-session warnings or alter behavior. `claude attach <id>` is the sharpest case: the user is explicitly entering an interactive Claude session and the wrapper's own protection rail is being skipped.
- Fix: Move the `unset CLAUDECODE` line from its current position (line 133) to immediately above the passthrough `case` block (currently line 125, after the `# Pass through subcommands...` comment block). The five pre-existing passthrough verbs (`mcp|config|api-key|rc|remote-control`) will then also get the cleanup, which matches the rest of the wrapper's intent. Verify by reading lines 96-135 of the post-edit file to confirm `unset CLAUDECODE` runs before the `exec` in the passthrough arm.
- Sources: standard-claude (Potential #1), standard-codex (Important #1), critical-claude (Important #2), critical-codex (Important #1), evolutionary-codex (Suggestion #3). 5 of 6 reviewers.

### Straightforward mediums

*(none)*

No medium-sized in-place fixes reached the validation bar. All other recurring items are either deferred design discussions (verb-taxonomy manifest, supervisor-mode metadata, `--bg` triage) or process items (skill update, upstream coordination) that benefit from operator judgment.

### Evolutionary clear wins

*(none)*

No evolutionary item is both clearly beneficial, low-risk, and in scope for this PR. The closest candidate — adding a behavioral test for the new passthrough — is worth doing but is a follow-up rather than something to silently bundle into this 13-line wrapper fix. Surfaced below as S1.

## Surface to user (do not apply silently)

**S1. Behavioral test coverage for wrapper passthrough.**
- Why deferred: Two reviewers (standard-codex Important #2, evolutionary-codex Suggestion #1) want a test that drives `claude agents` / `claude attach <id>` through the existing fake-real-Claude harness and asserts the real binary receives the original argv with no `--session-id` or `--settings`. The harness already exists at `/Users/atin/Projects/Stage11/code/c11/tests/test_claude_wrapper_hooks.py:38` and is well-shaped for this addition. This is genuinely useful and would catch the "forgot to add `respawn`" class of bug, but it is a separate piece of work — not a one-line edit — and the operator may want to choose whether to expand it now or in a follow-up alongside the verb-taxonomy work below.
- Summary: Extend `tests/test_claude_wrapper_hooks.py` with a live-socket test case for each of the seven new commands, asserting the fake real binary receives exactly the original argv (no `--session-id`, no `--settings`) and the bounded c11 ping still occurs.
- Sources: standard-codex (Important #2), evolutionary-codex (Suggestion #1).

**S2. Reactive-whitelist fragility — extract verb taxonomy into a manifest.**
- Why deferred: Three reviewers (critical-claude Important #1, evolutionary-claude Vector A / Suggestion #1, evolutionary-codex Strategic #4) name the underlying structural concern: every future Claude/Codex subcommand will silently break c11 until someone files a one-line PR. They propose moving the verb list to a declarative manifest (`Resources/wrappers/claude.yaml` / `codex.yaml`) read by both wrappers. This is a real follow-up worth doing, but it is design work that needs operator input on shape (YAML vs JSON, where it lives, whether the wrapper parses it directly or via a tiny `c11 wrapper-policy` helper).
- Summary: Extract the `case` whitelist in `Resources/bin/claude:125-128` and the parallel one in `Resources/bin/codex:79-83` into a shared manifest. New upstream verbs become one-line manifest edits instead of bash patches. Pair with a test corpus.
- Sources: critical-claude (Important #1), evolutionary-claude (Vector A / Suggestion #1), evolutionary-codex (Strategic #4).

**S3. `claude --bg <prompt>` still on the injection path.**
- Why deferred: Three reviewers (standard-codex Potential #3, evolutionary-claude Pattern 5 / Suggestion #5, evolutionary-codex "Emerging Patterns") flag that `--bg` is a flag, not a subcommand, so the existing `case "${1:-}"` cannot classify it. Today, `claude --bg "<prompt>"` still gets `--session-id` and `--settings` injected even though it launches a detached supervisor session. The PR comment correctly scopes itself to subcommands, but this is the natural next bug. The fix requires either a small pre-`case` argv scan or the manifest work in S2.
- Summary: Decide policy for `--bg` (likely: scan argv for `--bg` before the `case` and route to a "bg-detached" policy). Either fix in a follow-up PR or fold into S2.
- Sources: standard-codex (Potential #3), evolutionary-claude (Pattern 5, Suggestion #5), evolutionary-codex (Emerging Patterns).

**S4. Skill update for Agent View interaction inside c11.**
- Why deferred: Two reviewers (critical-claude Potential #4, evolutionary-codex Strategic #6) want a short addition to the `c11` skill noting that Agent View subcommands pass through and bypass the session-resume rail. The c11 CLAUDE.md says agent-facing behavior changes should reach the skill. This is process, not code — operator judgment on whether to land it with this PR, as a follow-up, or skip.
- Summary: Add a paragraph to the `c11` skill (or peer skill) explaining that `claude agents|attach|logs|stop|kill|respawn|rm` are passthrough inside c11 and bypass the session-resume registry. Prevents future agents from debugging a missing `claude.session_id` as if it were a hook failure.
- Sources: critical-claude (Potential #4), evolutionary-codex (Strategic #6).

**S5. Upstream coordination note for manaflow-ai/cmux#4005.**
- Why deferred: Two reviewers (standard-codex Potential #4, critical-claude Potential #5) note c11's bidirectional-upstream policy and ask for a one-line PR comment indicating whether this exact diff will be offered to cmux#4005 or whether cmux is taking a different approach. Process item, no code change.
- Summary: Add a PR comment (or commit footer in a follow-up) recording the upstream coordination decision.
- Sources: standard-codex (Potential #4), critical-claude (Potential #5).

## Evolutionary worth considering (do not apply silently)

**E1. Write supervisor metadata on `claude attach`/`respawn`.**
- Summary: Extend the wrapper's new passthrough arm to do one extra background `c11 set-metadata` call when `$1` is `attach` or `respawn`, capturing the short session id (`$2`) as `claude.attached_session`. The c11 surface would then know which background session is on the operator's screen — sidebar can render it, restore could re-attach by short id.
- Why worth a look: Both evolutionary reviewers (evolutionary-claude Vector B / Suggestion #3, evolutionary-codex "Mutations" / Strategic #5) independently identified this as the move that turns "get out of the way of Agent View" into "actively support Agent View as a primary surface for Claude Code work." Mechanically small (one extra background metadata write). The exploration needed is on the rendering and restore side, not on the wrapper side. Pairs naturally with S4.
- Sources: evolutionary-claude (Vector B, Suggestion #3, Mutation 3), evolutionary-codex (Mutations, Strategic #5).

**E2. Name the launch policy classes inside the wrapper (lightweight precursor to S2).**
- Summary: Before extracting to a manifest, introduce small named shell predicates inside `Resources/bin/claude` itself: `is_auxiliary_subcommand`, `is_supervisor_subcommand`, eventually `has_detached_session_flag` (for `--bg`). Same bash, vocabulary added. This is the cheapest first step toward S2 / S3 and lets future reviewers reason about classes rather than rediscovering them from the `case` arm.
- Why worth a look: Both evolutionary reviewers (evolutionary-claude Pattern 2, evolutionary-codex Suggestion #2) name this as a low-risk stepping stone. Lower commitment than the manifest, but creates the same vocabulary surface. Useful even if S2 never lands.
- Sources: evolutionary-claude (Pattern 2, Vector A intro), evolutionary-codex (Suggestion #2).
