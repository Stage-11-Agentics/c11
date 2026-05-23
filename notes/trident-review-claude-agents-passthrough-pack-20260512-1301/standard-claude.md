## Code Review
- **Date:** 2026-05-12T13:01:00Z
- **Model:** Claude Opus 4.7 (claude-opus-4-7)
- **Branch:** fix/claude-agents-wrapper-passthrough
- **Latest Commit:** 0fdb91e653b37da65dfab68fd83b5859691378b7
- **Linear Story:** claude-agents-passthrough (PR #150 — Stage-11-Agentics/c11)
---

## Summary

This is a tightly-scoped 13-line change to `Resources/bin/claude` that extends the wrapper's passthrough whitelist for subcommands that don't support `--session-id` / `--settings` injection. It adds the seven new Agent View subcommands shipped in Claude Code 2.1.139 (2026-05-11): `agents | attach | logs | stop | kill | respawn | rm`. Without this fix, c11 mangles every Agent View invocation by either replacing the real positional argument target with the wrapper's synthetic UUID, or wedging the `agents` TUI into "launch a new session" mode instead of listing the supervisor's existing pool.

The fix is correct, minimal, well-commented, and consistent with the existing pattern. It matches the precedent already in the file (`mcp|config|api-key|rc|remote-control`) and parallels how the sibling `Resources/bin/codex` wrapper handles its own non-interactive subcommand whitelist. CI is green on the relevant jobs (build, ghosttykit, web-typecheck, workflow-guard, remote-daemon).

## Architectural

**Correct level of intervention.** The wrapper's invariant is "inject session-id + settings into interactive sessions; pass through everything else." Agent View commands are explicitly not "start a new interactive session" — they operate on the supervisor pool by short session id (`attach <id>`, `logs <id>`, `stop <id>`, etc.) or open a TUI rooted in existing state (`agents`). The fix lives at exactly the right seam: the existing `case "${1:-}" in ... esac` passthrough block. No new code paths, no new abstractions, no new state. This is the right shape.

**The doc-comment block is load-bearing and well done.** Twelve lines of comments justifying a one-line change might look heavy, but for a wrapper that other agents (and future maintainers) will revisit every time Claude Code adds a new subcommand, the rationale-per-keyword is exactly what's needed. The comment explains *why* the rail breaks for each command class (positional argv collision vs. TUI re-routing), points at the upstream docs, and dates the affected Claude Code version. Next agent who sees a new subcommand misbehaving has an instant template.

**Consistency with the codex wrapper.** The codex sibling at `Resources/bin/codex` (lines 79–83) uses the same pattern: a `case` whitelist of non-interactive subcommands that bypass the metadata-write rail. The convention is established. PR #150 just keeps the convention in step with Claude Code's actual surface as of 2.1.139.

**No tenant-config violation.** The fix stays inside the wrapper's own runtime — no writes to `~/.claude/`, no persistent state, no behavior beyond `exec "$REAL_CLAUDE" "$@"`. This is the "narrow exception" the c11 principle (CLAUDE.md: "Principle: unopinionated about the terminal") explicitly carves out for session-resume wrappers. The fix respects the constraint.

## Tactical

**Pattern alignment.** Multi-line `case` clause is reformatted across three lines instead of the original one-liner. That's fine — bash `case` is whitespace-insensitive there and the multi-line form will scale better if the list grows further. No quoting concerns: the pipe-separated patterns are literal tokens, `${1:-}` is properly braced/defaulted.

**No collision risk with c11-internal flags or first-positional usage.** The seven new keywords don't overlap with c11-side metadata, the `--resume`/`--continue` family parsed later, or any positional argument shape Claude Code injects through `--settings`. They are exclusively first-positional subcommand verbs, which is exactly what `${1:-}` matches.

**Ordering / precedence.** The new branch is reached *after* the early-bail in lines 96–109 (not in c11 / hooks disabled / socket dead), which is correct — outside c11 we never want to inject, period. Inside c11 with a live socket, we now correctly passthrough Agent View commands before doing any session-id work. No regression in the existing five passthrough verbs.

**`unset CLAUDECODE` is intentionally NOT applied to Agent View passthroughs.** Worth flagging since a reviewer might wonder about this: the early-passthrough path (line 108) does *not* unset `CLAUDECODE` when `IN_C11=0`, but it *does* unset it when `IN_C11=1` via the guard at lines 104–106. The new Agent View passthrough at line 126 is reached *only* when `IN_C11=1` and socket is live, then `exec`s without unsetting `CLAUDECODE`. This means `claude agents` invoked from inside a c11 surface that was launched from a parent Claude Code session will see `CLAUDECODE` set and may emit the "nested session" warning. For the Agent View commands this is likely harmless (they don't start interactive sessions), but it is a small behavioral inconsistency with the rest of the wrapper's policy. See potential item 3.

**Test coverage.** Per project policy (`CLAUDE.md`: "Never run tests locally"), CI is the source of truth. Latest run shows green on build, build-ghosttykit, web-typecheck, workflow-guard, remote-daemon-tests. `compat-tests` is pending at time of context capture — not a blocker for a bash wrapper change since the compat suite tests socket protocol shape, not shell scripts. There are no unit tests for `Resources/bin/claude` itself (this is genuinely hard to test without spawning Claude Code), and adding one purely to assert "this case branch contains these tokens" would violate the project's "Test quality policy" (`CLAUDE.md`) which explicitly bans tests that grep-match source text. Skipping is correct.

**Security.** No new attack surface. The keywords are matched against `${1:-}`, exec'd literally. No interpolation, no eval, no command construction from user input. The added subcommands forward `"$@"` to the real binary, same as the pre-existing five.

**Performance.** Zero runtime cost. The `case` is O(1) string comparison against a fixed pattern list. No startup latency added.

## Findings

### Blockers

*(none)*

### Important

*(none)*

### Potential

1. ⬇️ **`unset CLAUDECODE` inconsistency for Agent View passthroughs.** Lines 125–129: when an Agent View command is taken via the new passthrough, the wrapper `exec`s without first running `unset CLAUDECODE`. The five pre-existing passthrough verbs (`mcp|config|api-key|rc|remote-control`) have the same property — this is not a regression — but it's worth a thought. For `agents`/`attach`/etc. it's almost certainly fine (they don't open new interactive sessions where "nested session" detection would matter), but if Anthropic ever adds nested-session warning emission to `claude agents` or `claude logs`, the user would see spurious warnings from c11-launched panes whose parent shell was started from Claude Code. Cheap defensive move: hoist `unset CLAUDECODE` above the `case` block. Non-blocking; the current behavior matches established precedent in the file.

2. ⬇️ **`rm` as a top-level subcommand token is unusually generic.** Worth a sanity-check note: `rm` is a common token and a reviewer might worry about accidentally matching a user typing `claude rm ...` meaning something else. But `case` only matches first-positional, and `rm` is a real Claude Code subcommand per the docs reference in the comment. No action needed — just calling out that this is the one keyword in the list that someone skimming might double-take. The justifying comment block on lines 116–124 covers this; consider explicitly naming the docs URL host (`code.claude.com`) again as a tooltip if Anthropic ever moves the doc.

3. ❓ **Forward-looking: should the passthrough list be data instead of code?** As Claude Code keeps shipping new top-level subcommands (Agent View is just the latest), this `case` will grow. One option for the future: pull the list into a small env-var override or a `Resources/bin/claude-passthrough.txt` file the wrapper reads, so updates don't require a c11 release. Not a blocker, not even a recommendation — just flagging that this is the second time the list has been extended (mcp/config/api-key/rc/remote-control was already a batch). If the cadence stays this slow, the case statement is fine as-is. Discuss only if it comes up again within the next few Claude Code minor versions.

4. ⬇️ **No SKILL/doc update needed, but worth a glance.** The `c11` skill (`skills/c11/SKILL.md`) doesn't document the wrapper's internal passthrough list, so this PR doesn't trigger a skill-update obligation. CLAUDE.md mentions "the skill is the contract; let it rot and agents get worse at using c11" — that rule applies to user-facing CLI surface, not internal wrapper plumbing. Confirmed no doc update needed.

## Validation Pass

Each finding above has been re-checked against the diff and the surrounding file context:

1. ⬇️ Confirmed. `unset CLAUDECODE` at line 133 is reached only after the `case` exits without matching — verified by reading lines 96–133. Same property holds for the pre-existing five verbs; not a new bug.
2. ⬇️ Confirmed. `case` matches `$1` only; `rm` is a Claude Code subcommand per the upstream Agent View docs cited in the new comment.
3. ❓ Open question for the maintainer's judgment. No code action needed in this PR.
4. ⬇️ Confirmed. Skill files reviewed at orientation time; no mention of the wrapper passthrough list.

## Recommendation

**Approve and merge.** This is a correct, minimal, well-commented fix to a real bug that ships in production Claude Code as of 2026-05-11. The comment block alone makes it worth landing — future maintainers (human or agent) hitting the same class of problem with a new subcommand will have an exemplar to follow. The same bug is tracked upstream (manaflow-ai/cmux#4005); per c11's cmux-relationship policy (CLAUDE.md: "c11 → upstream (suggest)"), this fix is a strong candidate to surface upstream after landing here — the comment block ports cleanly and the underlying bug is identical.

**Files touched (absolute paths):**
- `/Users/atin/Projects/Stage11/code/c11/Resources/bin/claude`
