# Result Validator — Phase 4 Reference

Phase 4 fires when the Orchestrator declares the run complete (every ticket in `review` or `done`). A **fresh** agent spawns in its own pane — fresh because Orchestrator bias toward "my work is good" is the failure mode this phase exists to prevent.

The Result Validator's whole job: walk `validation-plan.md` row by row, record pass/fail/partial against the actual run output, write the Validation Report.

## Identity declaration

```bash
c11 set-agent --type claude-code --model claude-opus-4-7
c11 rename-tab --surface "$C11_SURFACE_ID" "Result Validator"
c11 set-description --surface "$C11_SURFACE_ID" "Phase 4 terminal audit — walking .lattice/orchestration/validation-plan.md against the run's PRs. Producing .lattice/orchestration/validation-report.md. One-shot; will exit after surfacing the report."
```

## Boot prompt (spawned by Orchestrator at run-complete)

```bash
cat > /tmp/result-validator-boot.md <<'EOF'
You are the Result Validator for this Lattice run.

You are fresh — no prior context from the Orchestrator or any delegator. That's intentional. Your job is to audit the run against the spec with an independent eye.

Identity:
  - c11 set-agent --type claude-code --model claude-opus-4-7
  - c11 rename-tab --surface "$C11_SURFACE_ID" "Result Validator"
  - Set a description that includes "Phase 4 audit; one-shot."

Load context cold, in this order:
  1. SPEC.md
  2. BUILDPLAN.md
  3. .lattice/orchestration/validation-plan.md  ← this is your work queue
  4. .lattice/orchestration/run-state.md (for the ticket list)

For each row in validation-plan.md WITH `runnable_at: pre-merge-static`:
  1. Resolve the "Artifact to inspect" column — usually a ticket ID. Use `(cd <REPO_ROOT> && lattice show <TICKET-ID> --json)` to find the PR URL, then `gh pr view <url>` or `gh pr diff <url>` to inspect.
  2. Run the named verification method against the artifact.
  3. Record pass / fail / partial.

Skip `runnable_at: post-merge-smoke` rows — they require a merged tree or operator-driven UI walkthrough. Collect them into a separate § "Operator smoke-pass checklist" in the report (see template). The Operator runs them post-merge; you stub them with the verification method copied through verbatim.

Produce .lattice/orchestration/validation-report.md per the template in references/result-validator.md.

After the report is written, surface it to the operator with a clear summary header. Then stop. Do not iterate; the operator decides next steps.

Load the Lattice Orchestrator Workflow skill (`lattice-orchestrator`) and read `references/result-validator.md` before starting.
EOF

c11 send --workspace $WS --surface $RV_SURF "cd <project-root> && claude --dangerously-skip-permissions --model opus \"Read /tmp/result-validator-boot.md and follow the instructions.\""
c11 send-key --workspace $WS --surface $RV_SURF enter
```

## Audit protocol

**Walk every `runnable_at: pre-merge-static` row in `validation-plan.md`.** For each:

1. **Resolve the artifact.** If the row references `PR for TT-3`, run `(cd <REPO_ROOT> && lattice show TT-3 --json | jq '.data.artifact_info[] | select(.role == "pr")')` to get the PR URL.
2. **Inspect.** `gh pr view <url>` for description + diff summary; `gh pr diff <url>` for the diff; clone-and-checkout if you need to run the code; `gh pr checks <url>` for CI status.
3. **Verify.** Run the row's verification method exactly. Don't substitute a different method because it's faster — the validation plan is the contract.
4. **Record.** One of:
   - **Pass** — verification succeeded.
   - **Fail** — verification failed. Describe what was expected vs observed.
   - **Partial** — some sub-criteria pass, others don't. List which.
   - **Blocked** — verification couldn't run for a reason that ISN'T "needs merged tree" (e.g., the PR was never opened, the artifact is missing). Describe the block.

### Parallelize per-row verification with the `Agent` tool when the plan is non-trivial

Per-row verification is independent — each row reads its named artifact and runs its named method. **When the plan has more than ~6 rows and the rows cluster naturally (web-UI rows, runtime rows, provider rows, etc.), parallelize via Claude Code's `Agent` tool** — NOT via new c11 surfaces. Agent sub-spawns are sub-second; new c11 surfaces are seconds-to-minutes and add operational complexity (cwd inheritance bugs, allocator wedges, title-stomping). The right primitive for parallel-fanout-then-merge within a single role is in-process sub-agents.

Concrete pattern:

```
# Stay sequential when the plan is small (~6 rows or fewer) — coordination overhead dominates.
# Otherwise:

# 1. Group rows into 3-5 independent buckets (by area, OR just by ticket cluster).
# 2. Spawn one sub-agent per bucket via the Agent tool. Each gets:
#    - the bucket's rows verbatim from validation-plan.md
#    - the same artifact-resolution + verification-method protocol described above
#    - a prompt to return a structured per-row result table (pass/fail/partial/blocked + evidence)
# 3. The parent Validator collects sub-agent results, writes them into the report, and writes the
#    cross-cutting "Drift from BUILDPLAN.md" and "Recommendations" sections itself — those need
#    the whole tree in one mind.
```

The Validator stays the singleton report-writer. The sub-agents are temporary fan-out workers. Don't stress the parallelization if the bucketing is awkward; sequential is fine for small plans.

**Do NOT use `c11 new-surface` for this.** That's the wrong primitive at this scope — its cost model is built for long-lived delegator surfaces, not transient per-row verification.

**`runnable_at: post-merge-smoke` rows are NOT walked here.** Collect them verbatim into the report's § "Operator smoke-pass checklist" (template below). They're the operator's post-merge pass — your job is to stage them, not run them. If you find yourself wanting to attempt one anyway because it "should be easy," resist: cross-applying multiple open PRs to a single tree pre-merge is exactly the `PARTIAL-INSPECTION` shape the two-track plan exists to prevent.

**Don't invent rows.** If the run produced behavior the validation plan didn't anticipate, note it in the "Drift" section of the report — don't silently add a row. The Architect's plan is the audit contract.

**Don't silently skip pre-merge-static rows.** If a row is genuinely un-verifiable (e.g., the artifact column references a PR that was never opened), record it as **Blocked** with the reason.

## Validation Report template

Write to `.lattice/orchestration/validation-report.md`:

```markdown
# Validation Report

Source spec: [SPEC.md](../../SPEC.md)
Source build plan: [BUILDPLAN.md](../../BUILDPLAN.md)
Source validation plan: [validation-plan.md](./validation-plan.md)
Result Validator: <agent id>
Date: <YYYY-MM-DD>
Run completed: <YYYY-MM-DDTHH:MM>

## Summary
- Total criteria audited: <N>
- Pass: <count>
- Partial: <count>
- Fail: <count>
- Blocked: <count>

**Overall verdict:** <one-line bottom-line — green / yellow / red, and why>

## Per-criterion results

| # | SPEC.md criterion | Result | Notes |
|---|---|---|---|
| 1 | "Email + password fields with inline validation" (SPEC §Acceptance #4) | ✅ Pass | Inline error renders within 80ms (target <200ms). PR #42. |
| 2 | "Wrong credentials show inline error without losing typed email" | ⚠️ Partial | Email preserved on first failure; cleared on second consecutive failure. PR #42, src/screens/Login.tsx:88. |
| 3 | "Successful login redirects to /dashboard" | ❌ Fail | Redirects to / instead of /dashboard. PR #42, src/screens/Login.tsx:104. |
| … | … | … | … |

## Drift from BUILDPLAN.md
Anything that shipped but wasn't in the build plan (additions, architectural divergence). One paragraph per item.

- **<Drift item title>** — what's different from BUILDPLAN.md, where it lives, whether it's a problem.
- …

## Gaps
Spec criteria that weren't satisfied by any merged or open PR.

- Criterion #<N>: <why it's gap-shaped — no ticket covered it / ticket abandoned / etc.>

## Recommendations
What to do with the run.

- **Fix-back-in-flight:** items the still-live Orchestrator can hand to existing delegators (likely the original ticket's delegator).
- **New tickets:** items that need fresh tickets and delegators (typically drift-shaped or gaps).
- **Accept-as-is:** items that fell short of spec but are intentional or acceptable (operator can override the validator's strict reading).

## What I couldn't verify
Anything blocked, or anything where the verification method in the plan didn't have enough specificity to give a clean result. Architect feedback for next time.

## Operator smoke-pass checklist (post-merge)

Every `runnable_at: post-merge-smoke` row in validation-plan.md, copied through verbatim for the operator to walk after merge. The Result Validator does not attempt these.

| # | SPEC.md criterion | Verification method | Artifact to inspect | Pass condition |
|---|---|---|---|---|
| 2 | "Wrong credentials show inline error without losing typed email" | Open the login screen in Chrome, submit valid email + wrong password, confirm email persists in input | Merged login flow | Email value preserved in field after failed submit |
| 3 | "Successful login redirects to /dashboard" | Submit valid creds in Chrome, observe redirect | Merged login + auth-API flow | URL changes to /dashboard within 1s of submit |
| … | … | … | … | … |
```

## Surfacing to the operator

After writing the report, post a single condensed summary back to the operator. Lead with the verdict:

```
🎉 RUN VALIDATED — <project name>

Overall: <green/yellow/red — one-liner>
Pass: <N> / Partial: <N> / Fail: <N> / Blocked: <N>

Top items needing decision:
- <1-line on most-important fail or gap>
- <1-line on second-most>
- <…>

Full report: .lattice/orchestration/validation-report.md
```

Then stop. The Result Validator is one-shot. The Orchestrator (still alive in its pane) is the operator's channel for routing fix-backs or opening follow-up tickets.

## When to skip Phase 4

The Architect can disable the Result Validator in Phase 2 config. Skip when:

- The run is trivial (1–2 tickets, single-component changes) and the spec-vs-result audit isn't worth the agent-spawn overhead.
- The operator is doing the audit themselves (small project, hands-on review).
- The validation plan would be near-empty (rare, but happens for pure-refactor runs where the spec criterion is "behavior unchanged").

In all other cases, **default on**. The Result Validator is cheap insurance against the Orchestrator's self-congratulatory bias.
