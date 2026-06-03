# Overnight Run Retrospective — 2026-05-06

**Run start:** 2026-05-06T22:46:57Z. **Run complete:** 2026-05-07T03:53:22Z (≈5h6m wall, six PRs landed, queue empty, C11-19 deferred per operator).
**Snapshot taken:** initial draft 02:30Z mid-run; updated 03:55Z post-completion; revised 2026-05-07 with operator feedback to generalize section 3.
**Operator:** Atin (asleep through the first half; questioned the silence on C11-30 / C11-24 on return — that question is the only reason the C11-24 false-positive validation was caught — and intervened twice in the back half: 02:30Z to FREEZE promotions, ~03:43Z to expedite C11-4 handoff before system restart).
**Author:** Single-pass investigation by a fresh Claude Code session.

## Run outcome at a glance

| Ticket | Tier | PR | Wall time | Verdict |
|---|---|---|---|---|
| C11-17 | light | [#136](https://github.com/Stage-11-Agentics/c11/pull/136) | 1h10m | clean Validate pass |
| C11-30 | heavy | [#139](https://github.com/Stage-11-Agentics/c11/pull/139) | 3h55m | **PASS-WITH-NOTES** (Path 1 anomaly documented in PR body) |
| C11-24 | heavy | [#143](https://github.com/Stage-11-Agentics/c11/pull/143) | 4h26m | **Validate short-circuited** — cross-wired sibling, then 30+ min waiting on tagged build, delegator launched build inline |
| C11-16 | heavy | [#138](https://github.com/Stage-11-Agentics/c11/pull/138) | 3h25m | **Test 1 FAIL** root-caused to pre-existing `migrateLegacyPreferencesIfNeeded` masking from `com.cmuxterm.app cmuxWelcomeShown=1`; not a C11-16 defect |
| C11-18 | heavy | [#142](https://github.com/Stage-11-Agentics/c11/pull/142) | 3h22m | clean Validate pass on path-b diagnostics-only PR |
| C11-4 | light | [#144](https://github.com/Stage-11-Agentics/c11/pull/144) | ~1h21m from launch | **Build-only handoff** — operator FINAL NUDGE expedited the wrap; full CI will validate |
| C11-1 | research | n/a | 5m37s | 168-line recommendation file at `notes/c11-1-recommendation-2026-05-06.md` |
| C11-19 | — | — | — | Deferred per operator directive at 02:30Z |

Sections 2 and 3 are where the value is. Section 3 has been rewritten as a generalized list of system / flow-level fixes, not incident-specific patches.

---

## 1. What went well

### 1.1 The state.json + git-rev-list fallback kept the orchestrator honest after Lattice itself broke

At 00:32Z the orchestrator's polling found C11-24 had reverted from `status=in_progress, comments=N` back to `status=backlog, comments=1`, and C11-16 dropped from 6→3 comments. Both contradicted the prior `last_status` / `last_comment_count` in `state.json`. That contradiction is what triggered the investigation that found `stash@{0}` had captured ~75 lines of overnight events from the parent repo's `.lattice/events/*.jsonl` (the auto-stash-before-branch-switch from a parallel perf session).

The orchestrator then switched its source-of-truth from `lattice show` to `git -C $WT_DIR rev-list --count origin/main..HEAD` per worktree branch. Graceful degradation under store corruption — that's the property worth keeping.

### 1.2 Delegator self-recovery from the Lattice events race

Two delegators independently noticed their writes had been clobbered and recovered without orchestrator help:

- **C11-16 at 00:26Z**: `lattice status review --force --reason "...event-file race..."` and continued.
- **C11-24 at 00:50Z**: `lattice status backlog -> review --force` and posted an explicit `AUDIT TRAIL RECOVERY` comment naming "11 events were lost."

The lattice-delegate skill doesn't currently teach this recovery — the delegators inferred it from the symptom (writes vanished) and the principle that Lattice writes target `$REPO_ROOT`. Robustness from agents reading and applying principles, not following checklists.

### 1.3 The delegator-as-membrane principle held across 4 parallel delegations

No sub-agent posted a message intended for the operator. Every escalation, every recovery comment, every status decision flowed through the delegator pane. C11-24's recovery comment was posted by `agent:overnight-c11-24` (the delegator), not by `agent:overnight-c11-24-validate-codex` — even though the cross-wiring was a Validate-sibling problem. The membrane held.

### 1.4 The cohesion-vs-spree judgment held under pressure

C11-18's Impl phase explicitly *declined* to absorb the only-pane reset double-replacement bug it discovered, with reasoning recorded: *"premature fix would change the very repro path diagnostics need to capture."* That's the inverse of the cohesion principle correctly applied — when absorbing the fix would corrupt the phase you're in (diagnostics), you don't absorb. C11-30 absorbed two review fixes as commits instead of follow-ups. C11-17's Validate noted a pre-existing test compile failure as separate-ticket material. Three correct cohesion calls in three different shapes.

### 1.5 The C11-18 diagnose-first framing was the right call

The Plan sibling was given a tri-choice prompt (fix / diagnostics-only / needs_human) and chose **path-b: diagnostics-only**, with explicit reasoning that *"three plausible mechanisms remain"* and a static investigation can't enumerate every observation under a single mechanism. Shipped a `C11_PORTAL_DEBUG` file logger + lifecycle event emission + repro script instead of speculating a fix. *Don't declare root cause until every observation is explained* operating exactly as designed.

### 1.6 Research as a sibling pane (not a delegation slot)

C11-1 single-pass write-and-stop, finished in 5m 37s, 168-line recommendation file. The pane was then reused for C11-18 when the wait-list opened up. Treating research as not-a-delegation kept it from competing for Validate-tier infrastructure (tagged builds, computer-use validation) that the four code tickets needed.

### 1.7 Operator interrupt + "why is it silent" pattern caught the false-positive

Atin's question on returning — *"why is C11-30 silent?"* — kicked off the investigation that revealed both the Lattice-events stash regression AND the C11-24 cross-wired Validate. Without that question, surface:44's `"Validate pass"` comment posted to **C11-17 instead of C11-24** would have freed the C11-24 pane prematurely. The retro point isn't "Atin saved the run" — it's *"the orchestrator's silence was itself a signal"*.

---

## 2. What went wrong

### 2.1 🚨 Cross-wired sub-agent launches inherited the wrong worktree's cwd

Headline finding. **Two confirmed instances:**

- **C11-24 Validate (surface:44)**: launched in the **C11-17 worktree's cwd** instead of C11-24's. It read C11-17's prompt files, validated the C11-17 deletion PR, and posted a `"Validate pass."` Lattice comment **to C11-17** at 01:32:05Z. Subsequently corrected by the C11-24 delegator: *"previous Validate sibling (surface:44) inherited the wrong cwd (c11-17 worktree)... It validated C11-17 by mistake... surface:44 set aside as 'cross-wired-DO-NOT-TRUST'."* Net consequence had this not been caught: a false-positive Validate would have moved C11-24 forward in the orchestrator's state machine, the pane would have been reused for C11-19 or C11-4, and the actual C11-24 manifest viewer would have shipped without computer-use validation.

- **C11-16 Review siblings**: per the C11-16 delegator's handoff: *"Two false-start Review siblings landed in the wrong worktree before the third launched correctly. Useful reminder for the lattice-delegate skill that the orchestrator must verify cwd via `read-screen` before sending the launch line, or use absolute paths in the prompt-file argument."*

**Mechanism:** new c11 surfaces inherit `$HOME` or a stale last-used-cwd, NOT the orchestrator's cwd. The launch line `cd $WT_DIR && claude ...` works for *new* shells but fails when a sibling surface's underlying shell has drifted into a different worktree's tree.

**Fix:** §3.2 (sub-agent launch contract — explicit, verified cwd + dispatcher). The mechanism this prevents is the entire roulette wheel.

### 2.2 🚨 Launcher dispatch was implicit, not enforced

The C11-24 Validate prompt at `c11-24-overnight-manifest-viewer/.lattice/prompts/c11-24-validate-codex.md` was filename-tagged for one TUI; surface:44 launched a different one. The skill currently treats which TUI to spawn as a property of the prompt's *content* ("you are a Codex agent" in prose), not as a property of the *launch command*. There is no machinery preventing a generic `claude` launch against a prompt that needs a different TUI shape.

Note (operator clarification): **computer-use is a capability available to multiple models, not Codex-specific.** The fix is not "mandate Codex for Validate" — it's "make the launcher dispatch from the prompt explicit so whatever launcher is chosen actually gets used." See §3.2.

### 2.3 Lattice events stash regression — store isn't isolated from the working tree

A parallel session running on a different branch auto-stashed before a branch switch in the **parent repo's working tree**. That stash captured ~75 lines of `.lattice/events/*.jsonl` deltas the four overnight delegators had been writing. Result: `lattice show C11-24` reverted to `status=backlog, comments=1` mid-run; `lattice show C11-16` dropped 6→3 comments. Real progress (commit history, surface metadata) was unaffected; only the file-based event log was corrupted.

The stash is **still live on `stash@{0}`**, contains perf/phase4 + C11-34 work too, and cannot be popped without clobbering the other session.

Root cause is structural: `.lattice/events/*.jsonl` is **tracked in the working tree of the consuming repo**. Any session that runs `git stash` for any reason — including the auto-stash that `git checkout` does on a dirty tree — captures every other session's in-flight Lattice writes.

**Fix:** §3.3 (Lattice store isolation — events out of the working tree, or Lattice lives in its own repo).

### 2.4 C11-16 Validate Test 1 failure — pre-existing, not retro-material

Computer-use validation stopped at *"Test 1 checkpoint 2 did not show TCC primer."* Root-caused by the C11-16 delegator to a pre-existing C11-15 legacy-preference masking bug (`com.cmuxterm.app cmuxWelcomeShown=1`). **Not a C11-16 defect.** Operator can re-validate on a clean machine; PR body documents the workaround. Worth filing as a follow-up on C11-15 but not a retro priority.

### 2.5 CI workflow name mismatch in the runbook

Runbook listed `build`, `compat-tests`, `workflow-guard-tests`. Real names: `CI`, `macOS Compatibility`, `Build GhosttyKit`; no `workflow-guard-tests` exists. The orchestrator caught this at run-time and adjusted, but the runbook would mis-gate a successor session that didn't notice. **Fix:** §3.9 (preflight queries, not hardcoded values).

### 2.6 Stray-cwd surfaces accumulated; no one was authorized to clean them

Per `c11 tree --workspace workspace:3 --no-layout`: ~8 surfaces across 5 panes had no role tag, just stale cwds — partial-launch evidence from spawn-then-abandon cycles. None broke the run, but they clutter the sidebar and make `c11 tree` harder to scrub. The deeper issue: there is no agent in the topology authorized to garbage-collect them. Delegators only own their own pane's siblings; the orchestrator watched all panes but had no GC mandate.

**Fix:** §3.5 (orchestrator authorized to garbage-collect strays).

### 2.7 Validation pacing was wildly under-budgeted

Heavy tier ran 3–4 hours per ticket vs. a 1–3 hour implied budget; only 2 of 6 PRs cleared a clean Validate. De-emphasized in section 3 per operator — pacing is a symptom, not a root cause. The structural fix is the validation-harness redesign in §3.7; if the harness pulls heavy validation into the 10–15 min range as designed, "pacing" stops being a budget question.

### 2.8 c11 daemon congestion under parallel load

C11-16 delegator: *"c11 daemon congestion (`surface.read_text` / `surface.create` 10s timeouts) from many parallel agents made surface spawning unreliable. Translator was done inline as a result."* The translator was supposed to be a separate sibling surface walking 6 locales sequentially; daemon saturation forced the delegator to inline the work, hiding the locale walk from the operator's pane scrub. **Track as a c11 perf bug separately.** The retro-relevant systems-level lesson: §3.8 (skill content must include graceful-degradation fallbacks for infrastructure that can fail).

### 2.9 Status was bumped by a sub-agent, not the delegator

C11-4's Impl sub-agent bumped `status=review` *itself*, before the delegator had verified Review/Validate. This violates the lifecycle contract — Impl ends at `status=review` only as the **last** act of the phase, after the delegator confirms. The bump didn't bite because (a) promotions were already FROZEN by operator, (b) the delegator was still actively running. But the failure mode is real: Impl bumping before Review is orchestrator-state corruption that would silently cascade into wrong-pane reuse mid-queue.

The skill doesn't currently say *who* — delegator or sub-agent — is supposed to do the bump. **Fix:** §3.4 (status discipline: only the delegator bumps).

### 2.10 PR results conceal validation gaps

"All 6 PRs landed" headline conceals: one PASS-WITH-NOTES (C11-30), one Test 1 fail rooted in pre-existing masking (C11-16), one Validate short-circuit (C11-24), one build-only handoff (C11-4). Only **two of six** PRs cleared a clean Validate end-to-end. CI on `main` will be the authoritative gate for the rest. Doesn't change what shipped, but the truth-in-advertising matters for the next overnight's expectation-setting.

### 2.11 Disk full mid-run

Host hit 100% capacity early in C11-18 Impl; 95GB of stale DerivedData accumulated. Impl agent self-resolved by pruning stale entries; could have wiped something live. **Fix:** §3.9 (disk preflight + periodic check).

---

## 3. Systems & flow fixes

Generalized — not pegged to individual incidents. Each item names where the change lands and what shape it takes. Order is rough priority: topology and contract changes first, infrastructure changes second.

### 3.1 Topology vocabulary: orchestrator (singleton) + delegator (per-ticket), each on its own loop

**Lands:** `lattice-delegate skill`, runbook templates.

The pattern is and should be:

- **Orchestrator** — singleton per run. One agent on a polling loop, watches every in-flight delegation, makes promotion / freeze / surface-to-operator decisions, owns workspace-level concerns.
- **Delegator** — one per ticket. Each on its own loop inside its own pane, drives plan→impl→review→validate→handoff, owns sub-agent lifecycle inside its pane.

Drop the "meta-orchestrator" terminology — there's only one orchestrator, the "meta-" prefix is noise. Make this vocabulary consistent across the skill, the runbook templates, the prompt templates, and any delegator/orchestrator self-introductions. Both roles are explicitly *"on a loop"* — say so. Successor sessions need to instantly recognize which seat they're in.

This also clarifies authority: orchestrator owns workspace-level cleanup and cross-ticket sequencing; delegator owns its pane and its sub-agents. Section 3.5 below depends on this clarity.

### 3.2 Sub-agent launch contract: explicit cwd, explicit launcher, verified

**Lands:** `lattice-delegate skill`, sub-agent prompt templates.

Three rules, all enforceable:

1. **Absolute paths in launch lines.** Every sub-agent launch passes the absolute path to its prompt file (`$WT_DIR/.lattice/prompts/...`), never a relative form. If the surface's cwd has drifted, the absolute path still resolves; if the launcher itself is wrong, the prompt content tells the agent to bail.
2. **Post-launch verification.** After `c11 send-key enter`, the spawning agent (delegator or orchestrator) reads the surface's screen and confirms the worktree path appears within ~5s. If it doesn't, tag the surface `(spawn-failed)` and respawn. No "fire and trust."
3. **Launcher dispatch from prompt suffix.** Prompt filename suffixes name the launcher: `*-claude.md` → Claude Code; `*-codex.md` → Codex; `*-computer-use.md` → whichever computer-use-capable launcher is appropriate (model is a parameter, not a hard-coded provider). A naive launcher against a mismatched suffix should fail loudly. The point isn't "mandate one provider" — computer-use is a capability available to multiple models — it's "the launcher choice should be explicit and enforced, not inferred from prompt prose."

Failure mode prevented: every cross-wired-sub-agent incident from this run.

### 3.3 Lattice store isolation: events live outside any working tree

**Lands:** Lattice CLI, possibly Stage 11 directory layout.

Three options ranked by structural cleanliness:

- **A (cleanest):** Lattice runs as its own repo, sibling to the projects that consume it. Tasks/plans/events all live there. Consumer projects reference Lattice tickets by ULID, never have a `.lattice/` directory of their own. Operator's idea — worth thinking through. Cost: every Lattice-using project needs to know how to find the Lattice repo (env var, settings file, well-known path).
- **B (cheap and good):** Lattice events land in `~/.local/state/lattice/events/<repo-id>/<ulid>.jsonl` or `.git/lattice-events/`. Outside the working tree. Tasks/plans/sessions stay in `.lattice/` since those are human-readable artifacts that benefit from git tracking.
- **C (band-aid):** gitignore `.lattice/events/`. Stops the stash race; events are no longer reproducible from a clean clone.

Pick one before next overnight. Today, *any* `git stash` from any session in the consuming repo can clobber every parallel delegator's audit trail.

### 3.4 Status discipline: only the delegator bumps Lattice status

**Lands:** `lattice-delegate skill`, every sub-agent prompt template.

Make the rule explicit and one-sided:

> **Only the delegator bumps Lattice status.** Sub-agents (Plan, Impl, Translator, Review, Validate, Fix) post completion comments to Lattice and stop. The delegator reads the completion, verifies the artifact, and bumps the status. Status discipline is the delegator's contract; sub-agents who bump status are violating their stop instruction.

Add a corresponding line to **every sub-agent prompt template's stop instruction**:
> *"Do NOT call `lattice status` from this sub-agent. Status transitions are the delegator's responsibility."*

Failure mode prevented: orchestrator's state machine sees `status=review` on a ticket whose actual delegator is still running, promotes the next wait-list ticket into the supposedly-freed pane.

### 3.5 Surface hygiene: orchestrator authorized to garbage-collect strays

**Lands:** `lattice-delegate skill` (orchestrator role), `c11 codebase`.

Delegators only own surfaces inside their own pane. The orchestrator (per §3.1, the singleton watcher) is the right authority for workspace-level cleanup. Two changes:

1. **Authorize the orchestrator to GC strays.** Polling logic includes: identify surfaces with no role metadata after N minutes of liveness; rename them `(orphan-N)`; close them after a configurable timeout. The skill currently doesn't authorize anyone to do this; the result is that strays accumulate and pollute `c11 tree` output.
2. **Spawn-time cwd is explicit.** Add `c11 new-surface --cwd <path>` (and equivalent on `new-pane`) so the spawn-time cwd is set by the launcher rather than inherited from `$HOME` or daemon-last-used. Eliminates a class of partial-launch surfaces by removing the "spawn first, cd second, hope" pattern.

### 3.6 Polling logic: silence is a signal

**Lands:** orchestrator polling logic, runbook templates.

Today the orchestrator surfaces only on explicit transitions and signal-phrase comments. Three additions:

1. **Per-phase budgets.** Each phase has a wall-time budget (Plan 30 min, Impl 90 min, Validate <pick from §3.7>, etc.). If no comment lands on a ticket within its phase budget, proactive `read-screen` of the relevant sub-agent surface; surface a `📋 UPDATE` to operator with the screen tail.
2. **Signal-phrase regex extension.** Recovery vocabulary belongs in the regex: `recovery`, `wrong cwd`, `cross-wired`, `inherited`, `set aside`, `false start`, `RECOVERY`. C11-24's recovery comment contained four of these; none were in the orchestrator's regex.
3. **Auto-tightened cadence in tail.** When `in_flight ≤ 1` and `wait_list == 0`, drop wakeup delay to 270s. Don't sleep through end-of-run.

Generalizes the C11-30-silent-pattern lesson into a polling rule.

### 3.7 Validation harness: judge artifacts, don't drive (provider-agnostic)

**Lands:** `c11 codebase` (`scripts/validation/`), `lattice-delegate skill` (Validate phase), `runbook`.

The Validate sub-agent stops being a UI driver and becomes an **artifact judge**. Three components:

1. **Library of deterministic primitives** in `scripts/validation/lib/`. Per-pattern reusable shell + osascript + cliclick scripts: `close-overlay.sh`, `context-menu.sh`, `tcc-primer.sh`, `surface-manifest.sh`, `pane-split.sh`, etc. Each parameterized on bundle id + socket; each returns pass/fail + a structured artifact directory. Pure shell, deterministic, version-controlled, amortized across runs.
2. **Tagged-build cache shared across tickets.** A single `c11-validation-base` pre-warmed at orchestrator launch, then per-ticket overlays via incremental compile. Eliminates the "from scratch per ticket" cost.
3. **Validate sub-agent reads artifacts and judges.** Whatever model is doing computer-use validation (Claude, Codex, anything else with the capability) gets a short prompt: *"Read `artifacts/<ticket>-validation/`. Pass criteria: A, B, C. Verdict: PASS/FAIL with rationale."* The agent spends its time on judgment, not on driving — which is where the cognitive value is anyway. Provider-agnostic by design.

Migration path: skeleton + 3 primitives covering this run's patterns first; expand the library as new patterns come up; bespoke per-ticket prompts become the exception, not the default. The skill's Validate phase guidance shifts from "spawn a computer-use validator with a per-ticket prompt" to "select a harness primitive, run it, then spawn a validator as judge."

This is the single highest-leverage system-level fix in the retro. Pacing concerns disappear when the pipeline pulls heavy validation into the 10–15 min range.

### 3.8 Skill content: recovery, diagnose-first, research-as-sibling

**Lands:** `lattice-delegate skill`, delegator prompt template.

Three patterns this run earned that should become first-class skill content rather than heroic inference:

1. **Recovery from event-store corruption.** Add to delegator template's "Lattice writes" discipline: if `lattice show` returns earlier-than-expected status, recover with `lattice status --force --reason "audit trail recovery"` plus a comment naming what was lost and which artifacts are the source of truth. Encode the C11-16 / C11-24 pattern.
2. **Diagnose-first delegator template.** Alongside the default impl-first delegator, ship a variant where the Plan sibling is given a tri-choice exit: (a) ship a fix, (b) ship diagnostics-only, (c) needs_human. C11-18's path-b choice was correct precisely because the prompt allowed it; that exit should be available to any high-bug ticket where root cause may not be enumerable from static analysis.
3. **Research-as-sibling-pane.** Tickets whose deliverable is a markdown file (research, audit, decision-prep) get a single-pass agent in a shared pane that's recycled when done. Don't burn full-delegation overhead on them. C11-1 finished in 5m37s and freed its pane for the wait list; that's the pattern.

Plus: delegators must be taught to fall back gracefully when c11 daemon ops time out (e.g., translator inline if surface spawn fails N times), with explicit Lattice-comment audit. The infrastructure can fail; the skill should say what to do when it does.

### 3.9 Preflight: queries, not hardcoded values

**Lands:** runbook templates.

Runbooks must not hardcode environmental facts that can drift. At launch time, query:

- **CI workflow names:** `gh workflow list --json name,state | jq ...`. Halt and surface if expected names don't match.
- **Disk free space:** `df -k`. Halt if below threshold; periodic check during run with operator surfacing on low.
- **Worktree state:** the existing collision-handling protocol (re-fetch origin/main, rebase if clean, log conflict if dirty).
- **Active app/socket:** verify the production c11 socket is reachable before assuming `c11 ...` commands will work.

A runbook that hardcodes anything is a runbook that mis-fires the moment the environment shifts.

### 3.10 State observability: phase surfaces tracked, actor-to-surface verified

**Lands:** runbook (`state.json` schema), orchestrator polling logic.

Today `state.json` records `deleg_surf` per ticket but not the per-phase sibling surface refs. Add `phase_surfaces` per in-flight ticket so the orchestrator can cross-reference: when a `comment_added` event arrives with `actor: agent:overnight-c11-24-validate-codex`, that actor should map to a surface in C11-24's phase_surfaces, not to a surface tagged for another ticket. Mismatch detection at the orchestrator level catches wrong-pane writes earlier than the delegator currently does.

```json
"phase_surfaces": {
  "plan": "surface:16",
  "impl": "surface:21",
  "review": "surface:40",
  "validate": ["surface:44 (cross-wired-set-aside)", "surface:49"]
}
```

The point isn't the JSON shape — it's that the orchestrator should know which surfaces belong to which phase of which delegation, so writes from the wrong place are detectable as a class of failure.

---

## Closing

The pattern works. **All six overnight delegations landed PRs**; the C11-1 research deliverable shipped in 5m37s; C11-19 was deferred per operator directive; the wait list ended empty. Run wall time was 5h6m for six tickets, with two operator interventions.

That said, only **two of six** PRs cleared a clean Validate end-to-end. The pattern proved it can drive code through to PR; the validation pipeline proved it currently can't keep up. The orchestrator survived a serious mid-run Lattice corruption event, a near-miss false-positive validation, two false-start Review siblings, daemon congestion, disk pressure, and a system-restart deadline — all because the delegator-as-membrane and parent-repo-writes principles held under load.

Three system-level priorities for next overnight:

- **Correctness:** §3.1 (orchestrator/delegator vocabulary) + §3.2 (sub-agent launch contract). These eliminate the entire cross-wired-sub-agent class of failure.
- **Throughput:** §3.7 (validation harness — judge artifacts, don't drive). This is what turns "overnight = 4–6 tickets" into "overnight = the whole queue plus the wait list."
- **Risk:** §3.3 (Lattice store isolation). The stash race that hit this run will hit any run where any agent runs `git checkout` on a dirty parent repo. Worth fixing before next overnight, not after.

Everything else in section 3 is supporting infrastructure for those three.
