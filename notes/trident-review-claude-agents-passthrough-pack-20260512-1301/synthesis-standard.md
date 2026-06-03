## Synthesis — Standard Code Reviews (claude-agents-passthrough)

- **Date:** 2026-05-12
- **Branch:** fix/claude-agents-wrapper-passthrough
- **Latest Commit:** 0fdb91e653b37da65dfab68fd83b5859691378b7
- **PR:** Stage-11-Agentics/c11 #150
- **Reviewers Synthesized:** Claude Opus 4.7 (standard-claude), Codex/GPT-5 (standard-codex)
- **Reviewer Unavailable:** Gemini (quota exhausted)

---

## Executive Summary

Both reviewers independently land on the same conclusion: this is a correct, narrowly-scoped 13-line bash wrapper fix that extends the existing passthrough whitelist in `Resources/bin/claude` to cover the seven Agent View subcommands (`agents | attach | logs | stop | kill | respawn | rm`) shipped in Claude Code 2.1.139. Without the fix, c11's wrapper corrupts Agent View argv by injecting synthetic `--session-id` / `--settings` into commands that operate against the per-user supervisor pool, breaking id-bearing forms like `claude attach <id>` and wedging the `agents` TUI into "new session" mode.

Neither reviewer found any blockers. Both flag the same single non-blocking concern (the `unset CLAUDECODE` ordering relative to the new passthrough arm) as the one item worth a defensive cleanup. CI is green on all relevant jobs (build, ghosttykit, web-typecheck, workflow-guard, remote-daemon) with compat-tests pending — neither reviewer treats the pending compat job as a blocker for a bash wrapper change.

## Merge Verdict

**APPROVE AND MERGE.** Consensus across both available reviewers. Optionally apply the cheap one-line defensive cleanup for item 1 (hoist `unset CLAUDECODE` above the `case` block) either in this PR or as a follow-up. After landing, surface upstream to `manaflow-ai/cmux#4005` per c11's cmux-relationship policy.

---

## 1. Consensus Issues (Both Reviewers Agree)

1. **Fix is correct, minimal, and at the right seam.** Both reviewers explicitly endorse the architectural direction: Agent View commands operate against the per-user supervisor pool and are not new foreground sessions, so they must bypass the session-id/settings injection rail. The fix lives in the existing passthrough `case` block, follows the established convention, and respects c11's "unopinionated about the terminal" boundary (no tenant-config writes).

2. **`unset CLAUDECODE` ordering inconsistency (the only flagged concern).** Both reviewers independently raise the same issue: the new Agent View passthrough arm at `Resources/bin/claude:125` executes before `unset CLAUDECODE` at line 133. The pre-existing five passthrough verbs (`mcp|config|api-key|rc|remote-control`) have the same property, so this is not a regression. Both reviewers note the same cheap fix: hoist `unset CLAUDECODE` above the `case` block (or unset it inside the passthrough arm when `IN_C11=1`). Both agree this is non-blocking; Codex flags it as Important pending empirical validation, Claude flags it as Potential. Concern is that `agents`/`attach` are interactive/supervisor-facing entry points where Claude Code's nested-session detection could one day produce spurious warnings in c11-launched panes inheriting `CLAUDECODE` from a parent Claude session.

3. **CI status is acceptable.** Both reviewers note green CI on build, ghosttykit, web-typecheck, workflow-guard, and remote-daemon-tests; both note compat-tests pending at capture time and both judge it non-blocking for a bash wrapper change.

4. **No tenant-config violation.** Both confirm the fix stays inside the wrapper's runtime — no writes to `~/.claude/`, no persistent state. Respects the narrow session-resume-wrapper exception carved out in CLAUDE.md.

5. **Upstream coordination is in scope.** Both reviewers reference `manaflow-ai/cmux#4005` and recommend surfacing this fix upstream per c11's cmux-relationship policy ("c11 → upstream (suggest)").

## 2. Divergent Views

No substantive disagreements. The two reviews are remarkably aligned. Minor framing differences only:

1. **Severity assignment for the `CLAUDECODE` ordering issue.** Codex classifies it as **Important** (with a recommendation to validate or apply the defensive cleanup before shipping). Claude classifies it as **Potential** (non-blocking, "current behavior matches established precedent"). Net effect on merge decision: identical — neither blocks, both recommend the cheap hoist. The disagreement is about urgency labeling, not substance.

2. **Comment block evaluation.** Claude explicitly praises the 12-line doc-comment block as load-bearing and exemplary for future maintainers. Codex does not mention the comment block at all (neither positive nor negative). Not a disagreement, just different focus.

## 3. Unique Findings

### Only Claude raised:

1. **`rm` as a generic-looking subcommand token (Potential).** Calls out that `rm` is the one keyword in the list a skimmer might double-take on. Confirms it's safe — `case` only matches first-positional and `rm` is a real Claude Code subcommand per the cited docs. Suggests explicitly naming the docs host (`code.claude.com`) in the comment as a tooltip in case Anthropic moves the doc URL. No action required.

2. **Forward-looking: passthrough list as data vs code (Potential, open question).** Notes that this is the second time the list has been extended (after the original `mcp|config|api-key|rc|remote-control` batch). Floats the idea of pulling the list into an env-var override or a `Resources/bin/claude-passthrough.txt` so updates don't require a c11 release. Explicitly framed as "discuss only if it comes up again." Not a recommendation.

3. **No SKILL/doc update needed (confirmed).** Reviewed `skills/c11/SKILL.md` and confirms the wrapper's internal passthrough list isn't documented there, so this PR doesn't trigger a skill-update obligation. The CLAUDE.md "skill is the contract" rule applies to user-facing CLI surface, not internal wrapper plumbing.

4. **Test coverage rationale (Tactical note).** Argues against adding any test for this change on grounds that the only feasible test would be a grep-match against the case branch tokens, which would violate the project's "Test quality policy" ban on tests-of-source-text. Concludes skipping is correct per policy.

### Only Codex raised:

5. **Concrete test recommendation (Important).** Counter to Claude's view above, Codex argues a meaningful behavioral test IS available without violating the test policy: extend the existing `tests/test_claude_wrapper_hooks.py` harness (which already mocks the real `claude` binary at lines 126–185) to invoke `claude agents` and an id-bearing form like `claude attach 7c5dcf5d`, then assert the real binary receives original argv with no `--session-id` or `--settings`. This would be a runtime-behavior assertion through an executable seam, not a source-text grep, and would catch the exact bug class this PR fixes. **This is the most substantive unique finding in the synthesis.**

6. **`claude --bg ...` triage (Potential).** Notes the Agent View docs describe `claude --bg "<prompt>"` as the shell entry point for launching a background supervisor session, but this PR only handles top-level subcommands. If `--bg` sessions are supervisor-owned and detached from the current c11 surface, injecting surface-scoped hooks and a synthetic session id may be wrong there too. Explicitly framed as follow-up scope, not a blocker on this PR.

7. **Process methodology note.** Codex explicitly documents that it did not run `git fetch`/`git pull` (handoff forbids writes other than the review file) and did not run local tests (project policy). Useful provenance for the synthesis.

## 4. Consolidated Findings

### Blockers
*(none — unanimous)*

### Important
1. **`unset CLAUDECODE` ordering — apply the defensive cleanup.** Hoist `unset CLAUDECODE` above the passthrough `case` block (or unset it inside the passthrough arm when `IN_C11=1`). Both reviewers flag it; Codex argues for it pre-merge, Claude calls it non-blocking. Cheap, defensive, eliminates a class of future nested-session-warning surprises in `agents`/`attach` paths.

2. **Add a behavioral regression test for argv passthrough (Codex's unique recommendation).** Extend `tests/test_claude_wrapper_hooks.py` to exercise `claude agents` and `claude attach <id>` through the existing fake-real-claude harness, asserting the real binary receives unmodified argv with no `--session-id` or `--settings`. This is a true runtime-behavior test through an executable seam (not a source grep), so it does not run afoul of the project's test-quality policy. Worth adding either in this PR or as an immediate follow-up; it would catch any future regression in this exact argv-classification rail.

### Potential / Follow-ups
3. **Triage `claude --bg "<prompt>"` injection behavior.** The wrapper currently still injects on `--bg` invocations. If `--bg` sessions are supervisor-owned and detached from the c11 surface, the injection may be wrong. Tracker item, not a blocker on this PR.

4. **Consider extracting the passthrough list to data.** If a third extension of the `case` list lands within the next few Claude Code minor versions, consider moving the list to `Resources/bin/claude-passthrough.txt` or an env override so future updates don't require a c11 release. Not a recommendation today.

5. **Surface upstream to `manaflow-ai/cmux#4005`.** Per c11's cmux-relationship policy, this fix is a strong upstream candidate. The comment block ports cleanly and the underlying bug is identical. Open a PR or flag to the operator after landing here.

6. **Optional: explicitly name docs host in the comment.** Add `code.claude.com` as a host reference inside the doc-comment block so the rationale survives doc-URL migrations. Trivial editorial improvement only.

### Confirmed Non-Issues
7. **No SKILL.md update obligation.** The wrapper's internal passthrough list isn't documented in `skills/c11/SKILL.md`; the "skill is the contract" rule applies to user-facing CLI surface only.

8. **No new attack surface.** `case` matches `${1:-}` against literal tokens, exec passes `"$@"` to the real binary. No interpolation, no eval.

9. **No performance cost.** O(1) string comparison; zero startup latency added.

10. **No collision with c11-internal flags or `--resume`/`--continue` parsing.** The seven new keywords are exclusively first-positional subcommand verbs.

---

## Files Touched
- `/Users/atin/Projects/Stage11/code/c11/Resources/bin/claude`

## Source Reviews
- `/Users/atin/Projects/Stage11/code/c11/notes/trident-review-claude-agents-passthrough-pack-20260512-1301/standard-claude.md`
- `/Users/atin/Projects/Stage11/code/c11/notes/trident-review-claude-agents-passthrough-pack-20260512-1301/standard-codex.md`
- standard-gemini.md — UNAVAILABLE (quota exhausted)
