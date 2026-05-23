# Orchestrator — Phase 3 Reference

Phase 3 begins the moment the Architect's last artifact lands on disk. The Architect calls `ExitPlanMode` and spawns a fresh c11 pane that boots into the Orchestrator role. The Orchestrator never implements; it dispatches.

## Handoff transition (end of Phase 2 → start of Phase 3)

The Architect's last actions:

1. **Verify artifacts on disk**: SPEC.md, BUILDPLAN.md, run-state.md, agents.md, validation-plan.md, all Lattice tickets created.
2. **Log handoff** to `.lattice/orchestration/run-state.md` (append): `handoff: <timestamp> — Architect → Orchestrator`.
3. **`ExitPlanMode`**.
4. **Spawn the Orchestrator pane** (see Boot prompt below).
5. **Step aside.** The Architect's session no longer drives anything; the operator's channel is now the Orchestrator pane.

## HARD RULE 0 — Resolve your own surface ref at runtime; never use `$C11_SURFACE_ID` directly

The `$C11_SURFACE_ID` (and legacy `$CMUX_SURFACE_ID`) environment variable is **unreliable in fresh `c11 new-surface` shells** — frequently empty. When empty, `c11 set-title --surface "$C11_SURFACE_ID" "..."` expands to `--surface ""` and the c11 binary falls back to the **focused** surface — silently rewriting the spawning orchestrator's title and metadata. This has happened repeatedly across Stage 11 runs; the resulting confusion (the orchestrator's tab keeps reverting to a delegator's title) is hostile to operator observability and trust.

**The fix:** every delegator, sub-agent, captain, and validator boot prompt — and the orchestrator's own boot — must resolve its own surface ref at runtime via `c11 identify --json`:

```bash
MY_SURF=$(c11 identify --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["caller"]["surface_ref"])')
test -n "$MY_SURF" || { echo "FATAL: could not resolve own surface ref"; exit 99; }

c11 set-agent       --surface "$MY_SURF" --type claude-code --model claude-opus-4-7
c11 rename-tab      --surface "$MY_SURF" "<YOUR-ROLE-TITLE>"
c11 set-title       --surface "$MY_SURF" "<YOUR-ROLE-TITLE>"
c11 set-description --surface "$MY_SURF" "<3-line description>"
c11 set-metadata    --surface "$MY_SURF" --key role --value "<role>" --type string
c11 set-metadata    --surface "$MY_SURF" --key task --value "<ticket-or-scope>" --type string
```

The preamble runs before any other c11 write. If the resolution fails (empty `$MY_SURF`), the boot aborts with exit 99 rather than risk stomping the focused surface.

Apply this rule to: orchestrator boot, master validator boot, delegator boot, every sub-agent boot, captain boot. Anywhere a fresh c11 surface starts a fresh shell and needs to set its own identity.

### Protected operator surfaces

Operator-spawned surfaces (Master Validator, audit agents, ad-hoc operator tabs, the Orchestrator's own surface) should be marked with metadata so a misbehaving sub-agent can't stomp them even if it bypasses HARD RULE 0:

```bash
c11 set-metadata --surface "$MY_SURF" --key protected --value "true" --type string
```

The Orchestrator sets `protected=true` on its own surface (Step 0) and on Master Validator / audit / captain surfaces it spawns. **Future c11 binary work** (open issue): `c11 set-title` / `c11 rename-tab` should refuse to overwrite a surface whose `protected=true` metadata is set unless the caller IS that surface's resolved ref. Until that lands, the marker is advisory — but the runtime-resolve preamble (HARD RULE 0) is the actual defense; this is belt-and-suspenders.

## Boot prompt (Orchestrator pane)

Spawn pattern (inside c11, in the Main View Area pane):

```bash
# Stage the boot prompt
cat > /tmp/orchestrator-boot.md <<'EOF'
You are the Orchestrator for this Lattice run.

Identity (run BEFORE any other c11 write — see HARD RULE 0):
  - Resolve your own surface ref at runtime:
    `MY_SURF=$(c11 identify --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["caller"]["surface_ref"])')`
  - `c11 set-agent --surface "$MY_SURF" --type claude-code --model claude-opus-4-7`
  - `c11 rename-tab --surface "$MY_SURF" "Orchestrator"` AND `c11 set-title --surface "$MY_SURF" "Orchestrator"` (both — single-call propagation is unreliable)
  - Set description: 3-line format covering the project + the run + your current focus.

Load context (in this order):
  1. Read SPEC.md (the WHAT).
  2. Read BUILDPLAN.md (the HOW).
  3. Read .lattice/orchestration/run-state.md (autonomy level, N, ticket list, validator flags, workspace pane refs).
  4. Read .lattice/orchestration/validation-plan.md (so you know what Phase 4 will check against).
  5. Read .lattice/orchestration/agents.md (currently empty; you'll populate it).

Then load the Lattice Orchestrator Workflow skill (`lattice-orchestrator`) and read `references/orchestrator.md`.

**Step 0 — Workspace activation (before any dispatch).** See the "Workspace activation (Step 0)" section in `references/orchestrator.md` for full details. Briefly:
  - Read the workspace pane refs from run-state.md's `## Workspace panes` section.
  - Start the lattice dashboard daemon on a free port (`nohup lattice dashboard --port <port> > /tmp/lattice-dashboard.log 2>&1 & disown`).
  - Open the Lattice Board as a browser surface in the Control Surface pane (`c11 new-surface --type browser --url http://localhost:<port> --pane <control_surface_ref>`).
  - If `Master Validator: on` in run-state.md, spawn the Master Validator as a sibling tab in the Main View Area pane.
  - Update agents.md with the new surface refs.

Then begin the dispatch loop: dispatch delegators against the ticket list per the run-state.md configuration. Drive cadence with the **`/loop`** skill (Claude's native recurring-task primitive — see `## Cadence` below for tick body, timing, and the no-shell-watch rule). Run until every ticket is in `pr_open` or `done` (new Lattice workflow: `pr_open` = PR open awaiting human merge; `done` = merged). Then declare run-complete and (if the Result Validator is enabled in run-state) spawn the Result Validator.

Default mode: delegate. You do not implement.
EOF

# Spawn into the Main View Area pane (use the pane ref the Architect captured at workspace setup)
c11 send --workspace $WS --surface $ORCH_SURF "cd <project-root> && claude --dangerously-skip-permissions --model opus \"Read /tmp/orchestrator-boot.md and follow the instructions.\""
c11 send-key --workspace $WS --surface $ORCH_SURF enter
```

## Workspace activation (Step 0)

The Architect built the workspace *geometry* at end-of-Phase-2 (named panes: Main View Area, Control Surface, and **three Delegate View Areas** for any non-trivial run) and wrote the pane refs to `run-state.md` under `## Workspace panes`. The Orchestrator's Step 0 — before dispatching anything — is to **activate** that geometry: fill it with live content.

**Why three delegate panes (not one).** The c11 PTY allocator wedges at ~20-25 surfaces per pane on multi-hour runs; once one pane wedges, the state spreads globally within ~60s. A single delegate pane on a 40-ticket run will accumulate ~50-60 surfaces (delegators + plan/impl/fix sub-agents) and hit the wedge multiple times. Splitting dispatches across three panes pushes the per-pane count below threshold. **Soft cap per pane: 15 surfaces.** Going a few over is fine if the extras are directly related (a delegator + its sub-agents on the same pane). Rotate new delegators to the lightest-loaded pane.

Steps, in order:

1. **Read workspace pane refs.** From `run-state.md`'s `## Workspace panes` section, capture `main_view_area`, `control_surface`, and **`delegate_view_area_{1,2,3}`** + `workspace` refs into shell variables (`MV_PANE`, `CS_PANE`, `DV_PANE_1`, `DV_PANE_2`, `DV_PANE_3`, `WS`).

2. **Start the Lattice dashboard daemon.** Detached, on a free port — don't pipe to `head`/`tail` or it dies on SIGPIPE:

   ```bash
   PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
   nohup lattice dashboard --port $PORT > /tmp/lattice-dashboard-$PORT.log 2>&1 &
   disown
   # Wait for it to actually start listening (avoid race with the browser-pane open)
   until curl -sf http://localhost:$PORT >/dev/null 2>&1; do sleep 0.2; done
   ```

   Record `PORT` and the log path to `agents.md` and the `run-state.md` decision log.

3. **Open the Lattice Board** as a browser surface in the Control Surface pane:

   ```bash
   c11 new-surface --type browser --url "http://localhost:$PORT" --pane $CS_PANE
   # Capture the returned surface ref; set title + description
   c11 set-title       --workspace $WS --surface <new_surface> "Lattice Board"
   c11 set-description --workspace $WS --surface <new_surface> "Live ticket status + dependency graph for this run. Operator's at-a-glance control surface."
   ```

4. **Spawn the Master Validator** (if `Master Validator: on` in run-state.md). New tab in the Main View Area pane:

   ```bash
   c11 new-surface --type terminal --pane $MV_PANE
   # Capture surface ref, then spawn a fresh claude with the Master Validator boot prompt
   # (see "Master Validator boot" below)
   ```

   If Master Validator is off, skip this step. The Main View Area pane will hold only the Orchestrator's tab (which is already active).

5. **Update agents.md.** Add the Lattice Board surface, Master Validator surface (if spawned), the dashboard PID/PORT. The Orchestrator's tick will keep agents.md current from here on.

6. **Announce readiness to the operator.** One short message: workspace activated, dashboard live at `http://localhost:$PORT`, Master Validator running (or off), about to begin dispatching N delegators against M tickets. After this, the dispatch loop begins.

### Master Validator boot prompt

When `Master Validator: on`, the Orchestrator boots the Master Validator into its sibling tab in Main View Area:

```
You are the Master Validator for this Lattice run.

Identity:
  - c11 set-agent --type claude-code --model claude-opus-4-7
  - Resolve surface ref: `MY_SURF=$(c11 identify --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["caller"]["surface_ref"])')` (see HARD RULE 0)
  - c11 rename-tab --surface "$MY_SURF" "Master Validator" + c11 set-title --surface "$MY_SURF" "Master Validator"
  - 3-line description: project + run + current focus.

Read SPEC.md, BUILDPLAN.md, run-state.md.

Your job: continuously audit global build / test / PR state during Phase 3. On a 5-minute tick:
  - Walk all open delegator surfaces (read agents.md for refs).
  - Check build state, test state, PR queue, CI status across the worktrees.
  - Surface anomalies to the Orchestrator via `lattice comment` on the relevant ticket(s) and/or by setting your c11 sidebar status flag.
  - Audit run-state.md against Lattice ground truth — flag drift.

You do not implement. You do not dispatch. You audit and report.
```

Spawn this with the same one-shot pattern as the Orchestrator boot, into the captured Master Validator surface.

## run-state.md schema

Single markdown file the Orchestrator reads on boot and updates as the run evolves. Human-readable; the operator can `cat` it any time.

```markdown
# Run State

## Configuration
- Autonomy: <Fully Autonomous | Moderate | Minimal>
- Concurrent delegator cap (N): <number>
- C11: <on | off> — workspace: <workspace_ref>
- PR merge policy: <Auto-merge | Leave at pr_open>   # see orchestrator.md § Auto-merge mode
- Lattice ticket fidelity: <Verbose | Minimal>
- Lattice plan_review_mode: <inline | single | triple>   # pinned at Phase 2 from .lattice/config.json
- Lattice review_mode: <inline | single | triple>        # pinned at Phase 2 from .lattice/config.json
- Master Validator: <on | off>
- Closeout audit: <on | off>
- Result Validator: <on | off>

## Workspace panes (c11 refs)
- main_view_area: pane:<N>
- control_surface: pane:<N>
- delegate_view_area: pane:<N>
- workspace: workspace:<N>
- lattice_dashboard_port: <port>  (filled in by Orchestrator at Step 0)

## Tickets in scope

Each ticket carries an explicit workflow mode (set in Phase 2 per "Workflow modes — per ticket" in SKILL.md). The Orchestrator's tick body reads this to set the right expectations (fast-track runs synchronously without `/loop`; inline-full and sub-agent-full enter `/loop`).

| Ticket | Title | Status | Workflow mode | Branch base |
|---|---|---|---|---|
| TT-1 | <title> | <status> | fast-track | origin/main |
| TT-2 | <title> | <status> | inline-full | origin/main |
| TT-3 | <title> | <status> | sub-agent-full | origin/feat/tt-1-foundation |
| … | … | … | … | … |

## Decision log (append-only)
- <YYYY-MM-DDTHH:MM> Architect → Orchestrator handoff.
- <YYYY-MM-DDTHH:MM> Spawned delegator for TT-1.
- <YYYY-MM-DDTHH:MM> TT-3 status → pr_open; spawning TT-5 (depends_on TT-3) per press-ahead.
- <YYYY-MM-DDTHH:MM> [autonomy: Fully Autonomous] Chose Postgres over SQLite for TT-7. Rationale: BUILDPLAN.md called for multi-tenant; SQLite single-writer kills the use case.
- …
```

## agents.md schema

Denormalized join of "what's running where." Refreshed by the Orchestrator every tick.

```markdown
# Agents

| Role | Ticket | Surface ref | Pane ref | Branch | Worktree | Phase | Last seen | Spawned at |
|------|--------|-------------|----------|--------|----------|-------|-----------|------------|
| Delegator | TT-1 | surface:23 | pane:7 | feat/tt-1-schema | …/worktrees/tt-1 | impl | 10:42 | 10:15 |
| Delegator | TT-3 | surface:24 | pane:8 | feat/tt-3-login | …/worktrees/tt-3 | review | 10:43 | 10:30 |
| Master Validator | — | surface:22 | pane:6 (Main View Area) | — | — | — | 10:43 | 10:10 |
```

The *active* table is overwritten by the Orchestrator each tick — Lattice + c11 remain authoritative for live state. The Archived section below is append-only.

### Archived (run history)

When a delegator hits `done` and gets cleaned up (worktree removed, surface auto-closed), move its row from the active table above into an append-only `## Archived` section:

| Actor | Ticket | Outcome | Notes |
|---|---|---|---|
| agent:delegator-tt-5 | TT-5 | done | Merged at `<SHA>` (clean ort). 1270 LOC impl + 1054 LOC tests. 97 new tests (218 total on main). Auto-code-review PASS + orchestrator second-opinion PASS. |
| agent:delegator-tt-9 | TT-9 | done | Merged at `<SHA>`. **Misrouted `c11 rename-tab` to orchestrator surface (HARD RULE 0 violation; stale boot prompt).** Labels manually restored. Work unaffected. |

One row per closed delegator. Notes capture: merge SHA, line counts (impl + tests), test delta, anomalies hit + recovery taken, anything a future agent or the Phase 4 audit will want to know.

This is the closeout audit's primary input. A populated Archived table reduces audit cost from "read every ticket + branch + transcript" to "scan the anomaly notes for recurring patterns." Patterns visible here (e.g., the same footgun biting two delegators in a row) feed the **Run-time footgun catalog** below.

## The dispatch loop

The Orchestrator's tick body, run on every wake-up under `/loop`:

1. **Refresh** — re-read run-state.md, re-query Lattice for ticket statuses, re-walk `c11 tree` for surface state. Refresh agents.md.
2. **Surface escalations** — any ticket in `needs_human` or `blocked` gets the escalation banner (see below) at the top of this tick's operator-facing response. **Re-surface every tick while in needs_human/blocked**, not just on transition.
3. **Press-ahead audit** — for every ticket that hit `review` or `pr_open` since the last tick, audit downstream tickets for new claimability. If a downstream ticket can now be planned/implemented against the in-flight feature branch, spawn its delegator (subject to the N cap). See `## Press-ahead discipline` and `### Branch off the in-review parent, NOT main` below.
4. **Auto-merge (when enabled in run-state config)** — for every ticket in `pr_open` since the last tick, merge its PR (squash via REST) and `lattice complete` the ticket. See `## Auto-merge mode` below. **Default OFF; opt-in via Phase 2 `PR merge policy` config or a project CLAUDE.md auto-merge declaration.** When OFF, leave PRs at `pr_open` and surface the `✅ READY FOR REVIEW` banner to the operator.
5. **Auto-close finished surfaces** — for every ticket that transitioned to `done` since the last tick, run `c11 close-surface --surface <delegator_surface>` plus any sub-agent surfaces (plan/impl/fix/review) the delegator spawned. Mark the agents.md row as "closed at tick K". **Default ON; the operator can opt out at Phase 2 config.** Frees PTY slots, keeps per-pane counts under the wedge threshold. Tradeoff: lose live retrospective inspection — c11 session-persistence + lattice transcripts + commit history still cover the audit need.
6. **Spawn next available** — if delegator slots are free and unblocked tickets exist, spawn a delegator (see Spawning below). **Route to the lightest-loaded delegate pane** (soft cap 15 surfaces per pane; small overage OK for a delegator's own sub-agents).
7. **Schedule the next wake** — call `ScheduleWakeup` with a delay matched to current state (see `## Cadence` below). **One wake at a time** — don't double-schedule.

## Cadence

**Use the `/loop` skill — Claude's native recurring-task primitive. Do NOT use shell `watch`, `sleep` loops, `lattice watch --exec` as the orchestration heartbeat, or any other Bash-subprocess polling.** Shell loops live in a subprocess that dies when context compacts, can't re-enter the model with refreshed state, and are invisible to the harness. `/loop` (with `ScheduleWakeup` under the hood) is harness-managed: each wake re-enters this conversation, the model sees fresh Lattice/c11 state, runs the tick body, and either schedules the next wake or exits the loop. (`lattice watch` as a one-shot event listener for a non-orchestration purpose — e.g., an OS notification on a single ticket transition — is still fine; the rule is about cadence, not the command's existence.)

**Invocation.** Start the loop after Step 0 workspace activation, before the first dispatch:

```
/loop <orchestrator-tick-prompt>
```

No interval → dynamic mode; the model self-paces by calling `ScheduleWakeup` at the end of each tick (Step 5 of the tick body).

**Default delays.** Pick from cache-window-aware breakpoints (per `ScheduleWakeup` guidance):

| State | Delay | Why |
|---|---|---|
| **Active dispatch** — delegators in flight, work to advance | **270s (~4.5 min)** | Inside the 5-min prompt-cache window; wake-up is cheap. Picks up status transitions promptly. |
| **Quiescent** — every ticket in `pr_open`, waiting on operator merge | **1200–1800s (20–30 min)** | Nothing actionable. Long idle amortizes the cache miss into a much longer wait. |
| **Watching an external state change** — CI, deploy, single ticket close | **270s (~4.5 min)** | Same cache window; matched to typical change rates. |
| **Run complete** — about to spawn Result Validator or close | **end the loop** | Stop calling `ScheduleWakeup`. Silence after closeout is correct. |

**Don't pick 300s.** It's the worst-of-both-worlds — pays the cache miss without amortizing (per `ScheduleWakeup` guidance). If you're tempted by "5 min," drop to 270s or step up to 1200s+.

**Delegator-level cadence.** One level down from the Orchestrator, each delegator polls its own sub-agents (planner, implementer, reviewer) at **180s** under the same cache-window logic. That guidance lives in the Lattice CLAUDE.md template (`Sub-Agent Execution Model` → "Sub-agent polling cadence") so every delegator picks it up via the project's CLAUDE.md; it's repeated here for harmonization. The Orchestrator never reaches in to set a delegator's interval.

**End the loop explicitly** when the run is complete: stop calling `ScheduleWakeup`. The orchestrator's last response is the closeout (or the hand-off to Result Validator). After that, silence is the correct state.

## Recovery patterns (delegator silent halt)

Three failure modes recur and have proven recovery procedures. Detection is mostly the same — a delegator's cost counter frozen across 2+ orchestrator ticks (≥9 min) is the canonical tell. Deep-read the screen to confirm one of these patterns, then apply the matching recovery. **Never trust `c11 send-key enter` alone** — Claude Code's TUI sometimes swallows synthetic Return; always pair it with a fresh `c11 send "<message>"` immediately before.

### Pattern: frozen cost across ≥2 ticks

Symptoms: cost counter unchanged across ticks; api time unchanged; "Cooked for X" or "Baked for X" indicator with no monitor; input box may contain unsubmitted text like "check on the impl agent" or "check on the planner".

Recovery:

```bash
c11 send --surface <halted> "ORCHESTRATOR NOTE: Your cost counter has been frozen for N ticks. Your last response finished but /loop did not resume — likely a swallowed synthetic Return on a queued tick prompt. Please: (1) read your sub-agent surface or Lattice for new comments, (2) advance the current phase, (3) resume /loop."
c11 send-key --surface <halted> enter
```

### Pattern: Claude auth-state halt ("Not logged in")

Symptoms: same frozen-cost signature, but a deep screen read shows `⎿  Not logged in · Please run /login` as the last tool result line. Almost always happens when the operator swaps Claude accounts mid-run — in-flight tool calls return that error, the delegator stops responding, no /loop, no monitor.

Recovery:

```bash
c11 send --surface <halted> "ORCHESTRATOR NOTE: Claude auth was swapped mid-run; your last tool call returned 'Not logged in'. Auth should now be restored. Please retry that tool call, then resume /loop."
c11 send-key --surface <halted> enter
```

### Pattern: TUI synthetic-Return swallowed

Symptoms: cost moves slightly each tick (/loop alive) but the input box shows queued text that never submitted. The delegator is alive but bouncing on its own input.

Recovery: same as frozen-cost — explicit `c11 send` with new text + `send-key enter`. The new send replaces the stuck buffer and the explicit Return registers.

### When recovery fails

If two consecutive recovery sends don't move the cost counter, the session is dead (likely `/loop ended` was emitted earlier and the session can't be re-entered without operator action). Surface to operator with the recovery transcript and ask whether to respawn the delegator on a fresh surface (resuming from the most recent commit on the worktree's branch).

## Reading delegator state — idle vs background-watching

A pane that *looks* idle is one of three things — read the last ~15 lines before intervening:

| Tell | Meaning |
|---|---|
| Bare `❯` prompt, no `✻/✶` indicator, no `shell still running` footer | Genuinely idle. Safe to override or close. |
| `✻ <verb> for Xm` + `· 1 shell still running` | Background task active (watcher on a daemon log, artifact path, etc.). Don't intervene — let it tick. |
| `✻ <verb> for Xm`, no shell footer | Claude is thinking. Wait. |

Two delegators "idle at the same time" with the same shape is the signature of background-watching on each, not coincident stalls. Don't conflate "Lattice hasn't transitioned" with "stuck"; don't take an operator's "looks idle" framing at face value when the screen tells say otherwise.

## Spawning a delegator

**Pick the workflow mode per ticket first.** SKILL.md's "Workflow modes — per ticket" section enumerates fast-track / inline-full / sub-agent-full and the selection criteria. The shape of the boot prompt and the delegator's tick cadence depend on the chosen mode:

| Mode | Sub-agents | Headless lattice reviews | Delegator `/loop`? | Boot template |
|------|------------|--------------------------|---------------------|----------------|
| Fast-track | none | none (inline self-review via `lattice attach --role review`) | no — runs synchronously | "Fast-track boot prompt template" below |
| Inline-full *(default for medium work)* | none | `lattice plan-review --mode single` + `lattice code-review --mode single`, both `LATTICE_SPAWN_BACKEND=headless` | yes (single-session loop) | "Inline-full boot prompt template" below |
| Sub-agent-full *(escalation)* | planner + impl + (fix) as new tabs on delegator's pane | same headless lattice reviews between phases | yes (delegator + each sub-agent) | "Sub-agent-full boot prompt template" below (the legacy "Per-ticket setup" template) |

Record the chosen mode in `run-state.md`'s wave table so the Orchestrator's tick body sets the right expectations. Mixing modes within a wave is normal.

### Fast-track boot prompt template

Smallest shape. One session runs plan → impl → self-review → PR inline. Per-phase actor IDs keep the event log honest.

```bash
# Worktree (same shape as below)
git worktree add /path/to/<repo>-worktrees/<ticket-slug> -b fix/<ticket-slug> origin/main

# Pane: spawn a NEW TAB on the delegate pane (no new pane, no new workspace)
c11 new-surface --pane $DELEGATE_VIEW_PANE --no-focus
# Capture the returned surface ref

cat > /tmp/delegator-<ticket>-boot.md <<EOF
You are the Delegator for <TICKET-ID>. **Fast-track**: one Claude session wears all hats.

## Worktree assertion (run FIRST)
test "\$(pwd)" = "<absolute-worktree-path>" || { echo "WORKTREE MISMATCH"; exit 99; }

## Environment
export LATTICE_SPAWN_BACKEND=headless    # defensive; not used in fast-track but harmless
export LATTICE_ROOT=<absolute-repo-root>

## c11 orientation (HARD RULE — runtime-resolve own surface)
MY_SURF=\$(c11 identify --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["caller"]["surface_ref"])')
test -n "\$MY_SURF" || { echo "FATAL: could not resolve own surface ref"; exit 99; }
c11 set-agent       --surface "\$MY_SURF" --type claude-code --model claude-opus-4-7
c11 rename-tab      --surface "\$MY_SURF" "<TICKET-ID> Delegator"
c11 set-title       --surface "\$MY_SURF" "<TICKET-ID> Delegator"
c11 set-description --surface "\$MY_SURF" "Fast-track delegator for <TICKET-ID>. <one-line scope>."

## Phases (all inline, no sub-agents)
1. Plan:  lattice status <TICKET-ID> in_planning --actor agent:<id>-planner ; write plan to \$REPO_ROOT/.lattice/plans/<task_uuid>.md ; lattice status <TICKET-ID> planned --actor agent:<id>-planner
2. Impl:  lattice status <TICKET-ID> in_progress --actor agent:<id>-impl ; git fetch && (rebase if needed); edits + tests; commit
3. Self-review:  lattice status <TICKET-ID> review --actor agent:<id>-reviewer ; lattice attach <TICKET-ID> --type note --role review --inline "<markdown verdict>" --actor agent:<id>-reviewer
4. PR: git push -u origin <branch> ; create PR via Forgejo REST or gh ; lattice attach <TICKET-ID> <pr_url> --type reference --title "PR #N" --actor agent:<id>-impl ; lattice status <TICKET-ID> pr_open --actor agent:<id>-impl

Stop after pr_open. Orchestrator merges + completes per auto-merge policy.
EOF

c11 send --workspace \$WS --surface \$NEW_DELEGATOR_SURF "cd <worktree> && claude --dangerously-skip-permissions --model opus \"Read /tmp/delegator-<ticket>-boot.md and follow the instructions.\""
c11 send-key --workspace \$WS --surface \$NEW_DELEGATOR_SURF enter
```

The delegator runs synchronously — no `/loop`. It completes plan → impl → review → PR → stop in one continuous session and reports a final completion comment. The Orchestrator's next tick picks it up at `pr_open` and merges.

### Inline-full boot prompt template (default for medium work)

Same single-session shape as fast-track, but with headless `lattice plan-review` + `lattice code-review` between phases. Fresh-eyes value via the headless reviewer backend, zero new c11 tabs.

```bash
# Worktree + new-surface as above

cat > /tmp/delegator-<ticket>-boot.md <<EOF
You are the Delegator for <TICKET-ID>. **Inline-full**: one Claude session wears all hats, with headless lattice reviews between phases.

## Worktree assertion (run FIRST)
test "\$(pwd)" = "<absolute-worktree-path>" || { echo "WORKTREE MISMATCH"; exit 99; }

## Environment
export LATTICE_SPAWN_BACKEND=headless    # MUST be set — keeps reviews out of c11 surfaces
export LATTICE_ROOT=<absolute-repo-root>

## c11 orientation (HARD RULE — runtime-resolve own surface, same as fast-track)
MY_SURF=\$(c11 identify --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["caller"]["surface_ref"])')
test -n "\$MY_SURF" || { echo "FATAL"; exit 99; }
c11 set-agent       --surface "\$MY_SURF" --type claude-code --model claude-opus-4-7
c11 rename-tab      --surface "\$MY_SURF" "<TICKET-ID> Delegator"
c11 set-title       --surface "\$MY_SURF" "<TICKET-ID> Delegator"
c11 set-description --surface "\$MY_SURF" "Inline-full delegator for <TICKET-ID>. <one-line scope>. Headless lattice reviews."

## Phases (all inline; reviews are headless subshells)
1. Plan:        lattice status <TICKET-ID> in_planning --actor agent:<id>-planner ; write plan to \$REPO_ROOT/.lattice/plans/<task_uuid>.md (absolute path — see HARD RULE on plan-file paths in this file) ; lattice status <TICKET-ID> planned --actor agent:<id>-planner
2. Plan-Review: (cd \$REPO_ROOT && lattice plan-review <TICKET-ID> --mode single --actor agent:<id>-plan-reviewer)   # HEADLESS via LATTICE_SPAWN_BACKEND=headless ; read artifact ; fold findings into the plan file's '## Plan-Review Cycle 1 Resolutions (AUTHORITATIVE)' amendment block ; restore tab title (lattice CLI sometimes clobbers it)
3. Impl:        lattice status <TICKET-ID> in_progress --actor agent:<id>-impl ; git fetch && rebase if needed ; edits + tests ; commit
4. Code-Review: lattice status <TICKET-ID> review --actor agent:<id>-reviewer ; (cd <WORKTREE> && lattice code-review <TICKET-ID> --mode single --base origin/main --actor agent:<id>-reviewer)   # HEADLESS ; restore tab title. If CLI hangs >5–10 min OR returns empty diff, fall back to the own-reviewer pattern (see references/orchestrator.md § Own-reviewer-tab fallback): compute git diff, write review artifact, lattice attach --role review --inline.
5. Fix (if review surfaces Critical/Major): lattice status <TICKET-ID> in_progress --actor agent:<id>-impl ; edits + tests + commit ; lattice status <TICKET-ID> review --actor agent:<id>-reviewer ; re-run code-review or own-reviewer.
6. PR: git push ; create PR ; lattice attach <TICKET-ID> <pr_url> --type reference ; lattice status <TICKET-ID> pr_open --actor agent:<id>-impl

Stop after pr_open. Orchestrator merges + completes. Distinct actor IDs per phase keep the audit trail clean.

## Run under /loop (cadence)
60s tick while you're between phases or waiting on a headless CLI; end the loop on pr_open + completion comment.
EOF

# Launch — same atomic-cwd-binding shape as fast-track
c11 send --workspace \$WS --surface \$NEW_DELEGATOR_SURF "cd <worktree> && claude --dangerously-skip-permissions --model opus \"Read /tmp/delegator-<ticket>-boot.md and follow the instructions.\""
c11 send-key --workspace \$WS --surface \$NEW_DELEGATOR_SURF enter
```

**Why no sub-agent spawns?** A single Claude session can hold the plan + the diff + the review findings for a 2–5-file change comfortably. Headless `lattice plan-review` / `lattice code-review` provide fresh-eyes value via a *different* agent backend (different prompt, fresh context), which is what the sub-agent spawning was buying — without the c11 PTY pressure, the per-sub-agent `/loop`, or the atomic-cwd footgun. This is the **default for medium work** (Holodeck gate-rerun HOLO-54, HOLO-57; substrate-round fixes; most non-trivial bug fixes). Only escalate to sub-agent-full when no single context window can plausibly hold the whole ticket.

### Sub-agent-full boot prompt template (escalation only)

Per-ticket setup:

```bash
# Git worktree
git worktree add /path/to/<repo>-worktrees/<ticket-slug> -b feat/<ticket-slug> origin/main
# (or origin/<dep-branch> if a depends_on is in flight)

# c11 pane in Delegate View Area
c11 new-pane --type terminal --pane $DELEGATE_VIEW_PANE
# Capture the returned pane:ref / surface:ref

# Boot the delegator
cat > /tmp/delegator-<ticket>-boot.md <<EOF
You are the Delegator for <TICKET-ID> — <title>.

Identity:
  - c11 set-agent --type claude-code --model claude-opus-4-7
  - Resolve surface ref: `MY_SURF=\$(c11 identify --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["caller"]["surface_ref"])')` (see HARD RULE 0)
  - c11 rename-tab --surface "\$MY_SURF" "<TICKET-ID> Delegator" + c11 set-title --surface "\$MY_SURF" "<TICKET-ID> Delegator"
  - 3-line description: parent context / this ticket / current phase.

Worktree: /path/to/<repo>-worktrees/<ticket-slug>
Branch: feat/<ticket-slug>

Load context:
  1. cd into the worktree.
  2. Read SPEC.md, BUILDPLAN.md, and the ticket via \`(cd <REPO_ROOT> && lattice show <TICKET-ID> --full)\`.

Run phases sequentially in YOUR OWN PANE. **Status discipline is a HARD RULE — bump Lattice status BEFORE the work of each phase begins, not after. See the dedicated HARD RULE section below.**

  1. Plan — bump \`lattice status <TICKET-ID> in_planning\`. Spawn a plan sub-agent as a NEW TAB on this pane **using the atomic-cwd-binding launch pattern in \`## Spawning a sub-agent\` below — never bare \`c11 send "claude ..."\` without the \`cd <worktree> &&\` prefix.**
  2. Plan-Review — run \`(cd \$REPO_ROOT && lattice plan-review <TICKET-ID> --headless --actor agent:<id>-plan-reviewer)\` as a bash subshell. **HEADLESS — NOT a new c11 surface.** See the HARD RULE below. Triage → Cycle K Resolutions block in the plan file. Bump \`lattice status <TICKET-ID> planned\`.
  3. Implement — BEFORE spawning the impl sub-agent, bump \`lattice status <TICKET-ID> in_progress\` AND scan in-flight PRs for cross-ticket constraints: run \`mcp__forgejo__list_pull_requests --state=open\` (or \`gh pr list --state=open\` for GitHub-hosted projects) and read any PR body that mentions your ticket's BUILDPLAN label or its Lattice short ID. Honor anything flagged "open contract", "lock in before X", or in an "Open contracts" section. If unclear, ask the Orchestrator on its surface (visible in \`agents.md\` / \`run-state.md\`). Then spawn the impl sub-agent as a NEW TAB on this pane **using the atomic-cwd-binding launch pattern in \`## Spawning a sub-agent\` below.**
  4. Code-Review — bump \`lattice status <TICKET-ID> review\` (new Lattice meaning: "local review is underway, examining the diff before a PR is opened"). Run \`(cd <WORKTREE> && lattice code-review <TICKET-ID> --headless --base <remote>/main --actor agent:<id>-reviewer)\` as a bash subshell. **HEADLESS — NOT a new c11 surface.** See the HARD RULE below. **If \`code-review\` returns an empty diff or vacuous artifact, see "Own-reviewer-tab fallback" below — do NOT abandon the phase.**
  5. Fix — if review found issues, bump status back to \`in_progress\`, spawn a fix sub-agent as a NEW TAB on this pane **using the atomic-cwd-binding launch pattern in \`## Spawning a sub-agent\` below**, then bump back to \`review\` when fix completes. (If you skip the re-bump, the board lies — see HARD RULE on status discipline.)
  6. Open PR — write the PR body, push the branch, then run \`mcp__forgejo__create_pull_request\` (or \`gh pr create\`) AND \`lattice status <TICKET-ID> pr_open\` as PARALLEL calls in the same tool-call batch. Never sequence them. \`pr_open\` is the delegator's terminal state (the new Lattice workflow puts \`pr_open\` between \`review\` and \`done\`; the merger moves the ticket to \`done\`, not the delegator).

Sub-agent boilerplate is at the bottom of references/orchestrator.md — bake it into every sub-agent prompt.

Lattice writes: every \`lattice\` call runs through the PARENT repo, not the worktree. Use \`(cd <REPO_ROOT> && lattice ...)\`. Two exceptions that run from the worktree (because their output rides the feature branch): \`lattice branch-link\` (before scaffold commit) and \`lattice code-review\` (with explicit \`--base origin/main\`, NEVER bare \`main\` — they look identical but post-merge \`main\` and \`origin/main\` may differ, producing an empty diff).

**\`lattice\` from a worktree: the find_root footgun.** LAT-219 added auto-detection so most \`lattice\` calls route correctly from a worktree — but **\`lattice code-review\` still has worktree↔root bridge bugs that even \`LATTICE_ROOT=$PWD\` doesn't always fix.** Set \`export LATTICE_ROOT=$PWD\` at session start as the cheap mitigation; when it fails anyway (empty diff, vacuous artifact), fall back to the **own-reviewer-tab pattern** documented later in this file. Every Wave 2 delegator on the EC v1.2.1 run hit this — the fallback is the documented standard, not an exception.

**HARD RULE — status discipline.** Bump Lattice status BEFORE each phase begins, not after. Only YOU bump status — sub-agents post completion comments and stop. Verify with \`lattice show <TICKET-ID> --json\` after each bump. The orchestrator's tick reads Lattice status to distinguish "actively working" from "idle/stalled" — a ticket sitting at \`planned\` while impl is mid-flight makes the board lie and triggers false recovery interventions. If you correct a premature bump (e.g., plan-review surfaces findings and you downgrade \`in_progress → planned\` to triage), **explicitly re-bump back to \`in_progress\` before re-launching impl** — easy to forget after a triage roundtrip. Status drift is the #1 silent-failure mode of well-meaning delegators.

When the PR is open, post a completion comment on the ticket and stop. Do not address the Orchestrator or operator directly — they'll see the PR appear via the Lattice Board.
EOF

c11 send --workspace $WS --surface $NEW_DELEGATOR_SURF "cd /path/to/worktree && claude --dangerously-skip-permissions --model opus \"Read /tmp/delegator-<ticket>-boot.md and follow the instructions.\""
c11 send-key --workspace $WS --surface $NEW_DELEGATOR_SURF enter

# Update agents.md and run-state.md decision log
```

Note that the delegator launch line above already follows the **atomic cwd binding** pattern (`cd /path/to/worktree && claude ...`). The next section makes this rule explicit and extends it to every sub-agent the delegator spawns.

## Spawning a sub-agent (plan / impl / fix) — atomic cwd binding (HARD RULE)

**HARD RULE.** Every sub-agent launch line — plan, impl, fix, and any code-review fallback tab — must `cd <abs-worktree-path> && export LATTICE_ROOT=<repo-root> && claude ... "Read <prompt> and follow."` — *atomic* with the `claude` invocation. NEVER rely on the new tab's inherited cwd. This is the rule that prevents the worst kind of silent failure the workflow has: a sub-agent running in a *sibling delegator's* worktree while its tab name, its prompt, and its Lattice writes all reference a different ticket.

**Why it bites in the shared Delegate View Area.** Per the layout, every delegator (and every plan/impl/fix sub-agent it spawns) lives as a tab on a single shared pane: `delegate_view_area` from `run-state.md`. `c11 new-surface --pane <DV>` spawns the new terminal with the pane's *last* shell cwd — set by whichever sibling tab most recently typed a `cd`. From the spawner's perspective this inheritance is non-deterministic. A sub-agent launched without an explicit `cd` will land in *some other delegator's worktree* most of the time. The symptoms are silent:

- Tab named `HOLO-N impl` (the agent self-named from whatever cwd it found), but reading `/tmp/holo-M-impl-prompt.md`, and a missed `cd` prefix on a single `Write` lands the file in a *third* worktree entirely.
- Claude Code's Bash tool does NOT persist `cd` across tool calls — every call is independent. Even if the agent runs `cd <correct>` once, the next call resets to the inherited cwd. The session becomes a maze of `cd <correct> &&` prefixes; one missing prefix silently writes to the wrong worktree.
- `lattice` calls misroute through the wrong worktree↔root bridge. With `LATTICE_ROOT` unset (or set to the sibling's path), writes can land on a sibling ticket's Lattice state.
- The agent eventually catches the mismatch (because the prompt's "you are working on HOLO-N" doesn't match `pwd`), but by then it has already renamed its tab, set its `c11 set-agent` identity, and possibly bumped `lattice status` on the wrong ticket. Recovery is messy.

**The launch line, every time:**

```bash
# 1. Stage the prompt (worktree-relative paths inside the prompt body — see the
#    "Source-file paths in agent prompts are worktree-relative" HARD RULE below)
cat > /tmp/holo-N-impl-prompt.md <<EOF
... prompt body ...
EOF

# 2. Capture the worktree's absolute path (single source of truth — derive everything else from N)
WT_N=/Users/<op>/Projects/.../holodeck-worktrees/holo-N-<slug>

# 3. Spawn a fresh tab on the delegator's pane (no focus steal)
c11 new-surface --pane "$DELEGATE_VIEW_PANE" --no-focus
# Capture the returned surface ref → $NEW_SUBAGENT_SURF

# 4. ATOMIC launch: cd to the target worktree, set LATTICE_ROOT, then claude — ALL IN ONE COMMAND
c11 send --workspace "$WS" --surface "$NEW_SUBAGENT_SURF" \
  "cd $WT_N && export LATTICE_ROOT=$REPO_ROOT && claude --dangerously-skip-permissions \"Read /tmp/holo-N-impl-prompt.md and follow the instructions.\""

# 5. Explicit Enter (the Claude Code TUI sometimes swallows the synthetic Return inside `c11 send`;
#    the second call is the durable two-step pattern for Claude-to-Claude handoffs)
c11 send-key --workspace "$WS" --surface "$NEW_SUBAGENT_SURF" enter
```

**Three load-bearing pieces, in order:**

1. **`cd $WT_N && ...`** is the cwd binding. It runs BEFORE `claude` reads its first byte. Whatever cwd the new tab inherited is overridden atomically.
2. **`export LATTICE_ROOT=$REPO_ROOT`** points `lattice` writes at the parent repo from the start. LAT-219 auto-routes from a linked worktree, but the explicit `LATTICE_ROOT` beats any environmental drift (e.g., a sibling's `LATTICE_ROOT` having leaked into the inherited shell env).
3. **The prompt path itself** stays ticket-N-keyed. The atomic launch protects you from the cwd half of the bug; correct path selection protects you from the prompt half. See *Prompt path conventions* below.

The exact same shape applies to plan, impl, code-review-fallback, and fix sub-agent spawns. The prompt changes; the launch shape does not.

### Prompt path conventions

Global `/tmp/holo-N-<phase>-prompt.md` paths sit in a shared filesystem namespace — addressable from any cwd. A launch line with the wrong N (typo, stale copy-paste, off-by-one in a templated loop) reads the wrong ticket's prompt and nothing catches it on the filesystem side.

**Preferred (when the project supports it):** stage prompts inside the worktree at `<WT_N>/.lattice/tmp-prompts/<phase>-prompt.md`. The path is then physically bound to the worktree — if the launch line ends up in the wrong cwd somehow, the `Read` of the wrong-ticket's prompt fails outright instead of silently succeeding on a sibling's `/tmp/` file.

**Acceptable (the current pattern in older runs):** `/tmp/holo-N-<phase>-prompt.md` is fine *if and only if* the atomic launch above is in place AND the receiver-side guard (next section) is in place. The guard is what makes the global-namespace pattern safe.

### Receiver-side guard (defense in depth)

Every sub-agent prompt's first action — before the c11 orientation block, before any tool call — is a worktree assertion. The guard catches launcher bugs that bypass the rules above (e.g., a captain hand-launches a sub-agent and forgets the `cd`, or a future delegator template regresses).

```markdown
## Worktree assertion (run FIRST, before anything else)

This prompt is for ticket <TICKET-ID>, expected worktree `<absolute-worktree-path>`.

Your first action — before c11 orientation, before any other tool call — run:

\`\`\`bash
test "$(pwd)" = "<absolute-worktree-path>" || {
  echo "WORKTREE MISMATCH: pwd=$(pwd) expected=<absolute-worktree-path>"
  echo "This launcher violated the atomic-cwd HARD RULE in lattice-orchestrator/orchestrator.md."
  exit 99
}
\`\`\`

If the assertion fails: HALT. Do NOT `cd` into the expected worktree. Do NOT rename the c11 tab. Do NOT call `c11 set-agent`. Do NOT bump Lattice status. Do NOT improvise. Surface the mismatch to the operator with: the actual pwd, the expected worktree, and the prompt path you were launched with. Then stop. The fix is at the spawn side; downstream repair just hides the bug.
```

The guard sits at line 1 of the prompt because that's the only point at which `pwd` reflects the launch cwd unmolested by any in-prompt `cd` instructions. After that, any "first action — `cd <worktree>`" line in the prompt body is too late: the agent has already passed the point where the mismatch is diagnosable.

## HARD RULE: delegators never create c11 workspaces

A delegator's surface footprint is bounded — **tabs on its own pane, never a new workspace.** Without explicit operator intervention, no delegator action ever creates a c11 workspace.

**The reviews are the footgun.** `lattice plan-review` and `lattice code-review` internally call `agent_spawn`, which auto-selects backend in this order: `cmux → terminal → headless`. When invoked from inside c11, the cmux backend wins by default — and Lattice spawns each review agent **into a brand-new c11 workspace**. One per ticket per review type. Across a 15-ticket run that's ~30 stray workspaces clogging the sidebar.

**The rule.** Force the headless backend; the exact flag shape depends on the Lattice version installed. The env var works everywhere:

```bash
# Set once per session — covers every nested review invocation regardless of flag.
export LATTICE_SPAWN_BACKEND=headless

# Then either of the two flag shapes (whichever the install accepts):
(cd $REPO_ROOT  && lattice plan-review <TICKET-ID> --mode single --actor agent:<id>-plan-reviewer)
(cd <WORKTREE>  && lattice code-review <TICKET-ID> --mode single --base origin/main --actor agent:<id>-reviewer)

# Older installs (pre the --headless removal) still accept the explicit flag:
(cd $REPO_ROOT  && lattice plan-review <TICKET-ID> --headless --actor agent:<id>-plan-reviewer)
```

If the CLI errors `No such option: --headless`, the flag was removed on this install — use `--mode single` + the env var. See the `### Force the headless reviewer backend` clause later in this file for the full version-drift story.

The headless backend forces `subprocess.run` dispatch: no panes, no surfaces, no workspaces — just a CLI command that produces a typed artifact and exits. The delegator runs it as a bash subshell from its own pane and reads the artifact afterward. **Do NOT spawn a separate c11 surface, set up an agent identity, and `c11 send` the lattice command into it** — that pattern triggers the cwd-on-launch silent-failure bug (fresh surfaces start in `$HOME`, no `.lattice/` there) on top of the workspace-clutter problem.

**Other delegator phases (Plan, Implement, Fix) are c11 surfaces — but always new TABS on the delegator's own pane, never new panes, never new workspaces.** If a sub-agent needs a sub-sub-agent (rare), same rule: tab on the existing pane.

If an operator explicitly asks for a new workspace (e.g., "spawn the review in its own workspace so I can full-screen it"), do it. Absent that explicit ask, the answer is always: tab on this pane, or headless bash subshell.

**Post-merge cleanup: `/quit` exits the foreground Claude but does NOT reap background subprocesses** (orphaned `lattice code-review` without `--headless`, `tail -f` watchers). Those orphans can keep spawning panes after the merge. Use `c11 close-surface` on the delegator's surface — it kills children too. If a stray pane shows up afterwards titled like `<TICKET> reviewer`, root cause is a missing `--headless` in the delegator's prompt.

## Own-reviewer-tab fallback (when `lattice code-review` returns empty)

`lattice code-review --headless --base <remote>/main` invoked from a worktree fails reliably in ways `LATTICE_ROOT=$PWD` does not always fix — the CLI's worktree↔root bridge for code-review is more fragile than for plan-review (LAT-219 fixed plan-review; code-review still drifts). Symptom: empty-diff artifact, vacuous review, or "no commits found". Observed in multiple independent runs; every Wave 2 delegator on the EC v1.2.1 run hit it.

**Do NOT abandon the code-review phase. Do NOT spawn the reviewer into a new c11 workspace** (the auto-backend selector will try to, ignore it).

**The fallback:** spawn a custom code-reviewer sub-agent as a NEW TAB on your own pane. Prompt it to:

1. Compute the diff itself: `git fetch <remote> && git log <remote>/main..HEAD --stat` plus per-file `git diff <remote>/main..HEAD -- <path>` for each changed file.
2. Walk the diff, produce an artifact at `notes/.tmp/<TICKET>-codereview-custom.md` with the same shape `lattice code-review` would have produced: Verdict (PASS / PASS-WITH-NITS / FAIL), Critical/Major/Minor/NIT findings, per-finding (file:line, recommendation), end with a one-line summary.
3. Attach via `lattice attach <TICKET-ID> --type note --role review --inline "<markdown contents>" --actor agent:<id>-reviewer`. The `--role review` artifact satisfies the default `done` completion policy — the orchestrator can't tell the difference from a CLI-generated review.
4. Post a completion comment on the ticket noting "code-review (own-reviewer-tab fallback, CLI worktree↔root bridge failed)" so the closeout audit can count how often the upstream bug fires.

Then proceed to phase 5 (Fix) per the normal arc. The fallback is the documented behavior, not an exception — log it as "fallback used" in the run-state decision log so the operator and Result Validator can quantify the CLI footgun.

## Plan-Review Triage: amendment-block convention

**After `lattice plan-review` returns, the delegator does NOT proceed to Impl until findings are triaged and folded into the plan as an authoritative amendment block.** Going straight to Impl with unresolved plan-review findings causes the impl agent to stall (correctly — it refuses to act on stale guidance), wasting a full sub-agent spin-up.

Triage each finding as one of:
- **Obvious** — clear-cut fix; fold into amendment block.
- **Evolutionary** — meaningful but not blocking; fold or defer to follow-up ticket, delegator's call.
- **Complex** — real design decision; surface to operator (`needs_human` + comment with the decision needed).

Then append a new section to the plan file at `$REPO_ROOT/.lattice/plans/<task_id>.md`:

```markdown
## N. Plan-Review Cycle K Resolutions (AUTHORITATIVE — overrides earlier text on conflict)

### Critical: <finding shape>
- **Reviewer's concern:** <verbatim or paraphrased>
- **Resolution:** <fold / defer to follow-up / escalate>
- **Plan-section affected:** <section number or "new behavior">

### Major: <finding shape>
...
```

The implementer reads top-to-bottom; the addendum is the last word, so it wins on conflict. Bake this into every impl prompt: *"Read the plan top-to-bottom; the Cycle-K Resolutions section at the bottom is binding and overrides earlier text."*

For a second cycle (after re-plan), append `## N+1. Plan-Review Cycle K+1 Resolutions (AUTHORITATIVE — overrides Cycle K)`.

**Optional: re-run plan-review (cycle 2)** after amendments land, especially if the findings were dense (≥5) or touched architecturally-significant sections. A PASS on cycle 2 is the strongest signal that the plan is ready for impl.

## Delegator cadence

**HARD RULE: Delegator main loop uses `/loop` with a 60-second tick. NEVER `bash sleep`, `watch`, `until ... sleep ... done`, or `lattice watch --exec` as a polling primitive.** These were independently re-discovered as anti-patterns by multiple delegators in the TT-43/TT-59 run. Shell sleep loops live in subprocesses that die when context compacts, can't re-enter the model with refreshed state, and are invisible to the harness — your delegator silently stalls and the operator wakes up to a frozen run hours later. `/loop` is harness-managed; each wake re-enters the conversation with fresh Lattice/c11 state.

60s while work is in flight — do not self-pace longer cadences. Phase transitions are turning over on this clock; a 20-min sleep is dead time when a sibling sub-agent has just posted a completion comment. End the loop only when the PR is open and the completion comment is posted (fast-track delegators run synchronously and don't enter `/loop` at all).

**Once you say `Loop ended`, you're dead.** A `Claude Code` session whose `/loop` has terminated will not respond to `c11 send-key enter`, won't auto-resume on lattice state changes, and won't process operator typing in its prompt box unless the operator manually re-engages with the session. So: **don't end the loop until the work is truly complete** (PR open + completion comment posted), and if you anticipate any post-PR cleanup (worktree teardown, branch deletion), do it before ending the loop, not after.

Codex has no `/loop` equivalent; if a Codex delegator is needed for some reason, flag the launch as non-standard to the operator and use explicit `codex exec` re-invocations rather than a background polling loop.

The cadence applies per delegator instance. Multiple delegators each run their own `/loop`; they don't coordinate cadence with each other or with the Orchestrator beyond the Lattice events they emit.

## Sub-agent boilerplate (delegator → plan/impl/review/fix)

Every sub-agent prompt the delegator writes must include these clauses verbatim. They're load-bearing — each one corresponds to a real silent-failure mode observed in prior runs.

### Worktree assertion at line 1 of every prompt (HARD RULE)

> **HARD RULE.** The receiver-side worktree assertion (see `## Spawning a sub-agent (plan / impl / fix) — atomic cwd binding (HARD RULE)` earlier in this file) goes at the **top** of every sub-agent prompt — before the c11 orientation block, before any tool call. It pairs with the spawn-side atomic-cwd rule as the second line of defense. Without it, a launcher bug bypassing the spawn rule (e.g., a captain hand-launches a sub-agent and forgets the `cd`, or a templating regression) lands the agent in a sibling delegator's worktree silently. The assertion HALTs on mismatch; never cd-fix-it-up.

### Stop instruction (end of every sub-agent prompt)

> After you post your completion comment, stop. Do not call `lattice status` — status transitions are the delegator's responsibility, not yours. Do not address the human or the Orchestrator directly; the delegator is the only interface upward. Another agent will evaluate your work and continue the process.

### Read-before-Write on pre-existing files

> Before calling `Write` on any file you didn't create in this session, call `Read` on it first — even if it's a near-empty scaffold. Lattice plan files are scaffolded at task creation, so the plan path always exists.

### Re-fetch `origin/main` at every phase boundary

> First thing: `git fetch origin && git log -1 origin/main`. Record the SHA at the top of your output ("Working against origin/main @ `<sha>`"). The next phase will re-check; if SHAs differ, flag as drift.

For impl agents specifically: `git fetch origin && git rebase origin/main` (or merge) as the first code action.

### Deviate-with-flag for plan-vs-spec contradictions (impl agents only)

> Follow the plan, but if the plan contradicts SPEC, the codebase, a literal sample config, or itself, **deviate to fix the contradiction** and **flag the deviation in your completion comment** with: (a) the contradiction shape, (b) which side you took (plan vs SPEC vs sample), and (c) why. The code-reviewer will validate the deviation; don't ship the plan if it's wrong.

### Lattice items live in the root repo, not the worktree (HARD RULE)

> **HARD RULE.** Lattice state — tasks, events, statuses, plan files, comments — lives in the **root repo's** `.lattice/`, never in a worktree's. This is the outcome rule: it doesn't matter where you typed the command, it matters where the write landed. The orchestrator, sibling agents, and the dashboard all poll the root's `.lattice/`; a write that lands in a worktree's `.lattice/` is invisible to them, decisions get made on stale data, and recovery is hard.
>
> **The CLI now enforces this for you.** As of Lattice PR #17 (LAT-219), `lattice` auto-detects when it's running inside a git linked worktree and routes reads/writes to the root repo's `.lattice/` automatically — the same way `git status` in a worktree talks to the primary. You no longer need `(cd $REPO_ROOT && lattice ...)` wrappers or `LATTICE_ROOT` plumbing for normal commands. Run `lattice` from wherever; the items end up in the root.
>
> **Two exceptions that intentionally write to the worktree's `.lattice/`** because their output is meant to ride the feature branch into the PR: `lattice branch-link` / `branch-unlink` (so the branch_linked event commits with the branch) and `lattice code-review` (so review artifacts ride into commit 1). These only have a real effect in projects where `.lattice/` is *tracked* (e.g. c11). In projects where `.lattice/` is *gitignored* (e.g. Lattice itself), the exception falls back to the root automatically — same outcome.
>
> **Plan files write to `$REPO_ROOT/.lattice/plans/<task_id>.md`.** Always. The CLI handles this when `lattice` is the one writing.
>
> **But sub-agents writing plan files directly via the Claude `Write` tool DO NOT get LAT-219 auto-routing.** A planner sub-agent that does `Write(.lattice/plans/<uuid>.md, ...)` from inside a worktree resolves the relative path against the worktree's cwd — and if the project tracks `.lattice/` in git (e.g. Substrate, c11), the worktree has its own `.lattice/plans/` shadow. The Write lands there, invisible to the orchestrator's plan-review which reads from `$REPO_ROOT/.lattice/plans/`. Symptom: planner reports completion, parent plan file is still the empty scaffold, plan-review runs on stale content. **HARD RULE for sub-agent prompts:** any `Write` to `.lattice/plans/<uuid>.md` MUST use the absolute parent path (`/Users/<op>/Projects/.../<project>/.lattice/plans/<uuid>.md`) — NEVER the relative form. Recovery if it happens: nudge the still-alive planner via `c11 send` with the absolute-path instruction; the in-memory context still has the plan, the re-Write is fast. Observed: Substrate Round 2 SB-28 planner (2026-05-21).
>
> **If you hit `Invalid transition from <state> to <target>`**, the state is fine. Either: (a) you're on an older Lattice install without the LAT-219 fix — upgrade and retry, or (b) something has set `LATTICE_ROOT` to the wrong path (it overrides auto-detection). Suspect environment drift before suspecting state corruption.
>
> **Historical context (pre-LAT-219).** Before the auto-route shipped, this rule was *mechanical*: "never run `lattice` from a worktree; always `(cd $REPO_ROOT && lattice ...)`". That phrasing remains in older PRs, retros, and operator notes. The new outcome-based rule supersedes it. See the `lattice` skill's `references/worktree-guide.md` for the canonical operator-facing explanation.

### Force the headless reviewer backend (HARD RULE)

> **HARD RULE.** Any `lattice plan-review` or `lattice code-review` invocation in a sub-agent prompt MUST force the headless backend. Without it, Lattice's auto-backend selector spawns the reviewer into a brand-new c11 workspace per iteration — they accumulate as sidebar clutter the operator must clean up manually.
>
> **The flag set has drifted across Lattice versions.** Two shapes that both work:
>
> ```bash
> # Newer installs (post the --headless removal): use --mode single + env var.
> export LATTICE_SPAWN_BACKEND=headless
> (cd $REPO_ROOT && lattice plan-review <TICKET-ID> --mode single --actor agent:<id>-plan-reviewer)
> (cd <WORKTREE> && lattice code-review <TICKET-ID> --mode single --base <remote>/main --actor agent:<id>-reviewer)
>
> # Older installs still accept --headless directly:
> (cd $REPO_ROOT && lattice plan-review <TICKET-ID> --headless --actor agent:<id>-plan-reviewer)
> ```
>
> If a delegator hits `Error: No such option: --headless`, fall back to `--mode single` + `LATTICE_SPAWN_BACKEND=headless` exported. The env var is the safer default — it covers every nested review invocation in the same shell, including ones that forget the flag.
>
> This is the sub-agent-side mirror of the "HARD RULE: delegators never create c11 workspaces" section earlier in this file. The delegator's own review invocations are covered there; this clause covers the plan sub-agent's plan-review call (which the delegator's phase list doesn't directly reach) and any code-review a fix sub-agent might re-run.
>
> **Lattice CLI also renames the invoking surface's tab** when the cmux backend leaks through (e.g. when `LATTICE_SPAWN_BACKEND` isn't set and the install's `--headless` flag was removed). The delegator's tab title becomes `review-<random>` or `merge-<random>`, hostile to operator observability. **Restore immediately** after every lattice review call: `c11 rename-tab --surface "$MY_SURF" "<TICKET-ID> Delegator" && c11 set-title --surface "$MY_SURF" "<TICKET-ID> Delegator"`. Defensive — cheap to call when no rename happened, recovers the operator's bearings when one did.
>
> **Observed:** C11-27 (2026-05-16) — the orchestrator inlined `code-review --headless` into the boot file but dropped it for the plan sub-agent's plan-review call. Five plan-review iterations produced ten stray `plan-review-*` / `merge-*` workspaces before the operator caught it. Substrate Round 2 (2026-05-21) — every delegator independently hit `--headless` rejection and rotated to `--mode single`; lattice CLI clobbered several delegator tab titles, restored by the orchestrator each tick.

### Plan-file watcher Monitor must use the exact `.lattice/plans/` path (HARD RULE)

> **HARD RULE.** When a delegator arms a Monitor / sha256-watcher / file watcher on the planner's plan-file output, the path **must include the `.lattice/` segment**: `$REPO_ROOT/.lattice/plans/<task_uuid>.md`. A Monitor pointed at `$REPO_ROOT/plans/<task_uuid>.md` (no `.lattice/`) silently never fires, the delegator background-watches forever, and the run stalls until the orchestrator nudges. Observed: Substrate Round 2 SB-21 (2026-05-21) — delegator's Monitor watched the wrong path; planner completed 5 min in, delegator idled 10+ min until orchestrator + Master Validator both flagged the drift. Spell out the exact path in the delegator-prompt template; never rely on the model to reconstruct it.

### Source-file paths in agent prompts are worktree-relative (HARD RULE)

> **HARD RULE.** When you write a prompt for an agent running in a worktree, every project-file path is worktree-relative: `src/...`, `tests/...`, `configs/...`. **Never embed an absolute path to the parent repo** (`/Users/<op>/Projects/.../src/...`) — agents follow the path literally, the Edit/Write goes to the parent repo's working tree, and the agent's feature branch ends up empty while the parent's working tree silently fills with uncommitted changes.
>
> **The footgun**: it's natural to drop in `/Users/<op>/Projects/Stage11/code/<project>/<path>` when writing a prompt — that's the path you copy-pasted from the operator's file tree. Don't. Agents are not the operator, and an `isolation: "worktree"` Agent invocation puts the agent in a *different* directory than the operator. Absolute paths bypass that.
>
> **Symptom**: agent reports completion with a clean summary, claims the branch is pushed, but `git ls-remote origin <branch>` returns nothing and the worktree's `git status` is empty — while the parent repo's working tree has all the work as unstaged changes. Recovery is the salvage pattern: copy the work out of the parent's working tree (or the agent's worktree if the agent half-followed the prompt), commit on the intended branch, push.
>
> **The discipline**: write prompts as-if you were typing the commands at a shell prompt *inside* the worktree. Project files: `src/taste_tester/reports/lineage.py`, not `/Users/atin/.../taste-tester/src/taste_tester/reports/lineage.py`. Reserve absolute paths for things that genuinely live outside the project — operator config, the skill files themselves, `~/.zshenv`.
>
> If a sub-agent needs to read a sibling-project file (rare), explicitly call that out: "this file lives outside your worktree at `<absolute_path>`; read it but never write back to that location."

### Sub-agents in c11 surfaces, never headless `claude -p` shells

> If you're spawning sub-sub-agents (rare), they run in c11 surfaces — new tabs on this pane is the canonical pattern. Headless `claude -p &` background shells break the c11 auth chain, are invisible to the operator, and lose `c11 set-status` / `c11 log` access.

## Operator escalation format

When the Orchestrator surfaces to the operator, lead with an unmistakable header. Loud here, restrained elsewhere.

| Transition | Lead with | Tone |
|---|---|---|
| `→ needs_human` | **🛑 NEEDS YOUR INPUT — `<TICKET>`** | Action required. Don't bury it. |
| `→ blocked` | **⛔ BLOCKED — `<TICKET>`** | External dependency; usually action required. |
| `→ pr_open` | **✅ READY FOR REVIEW — `<TICKET>`** | PR up; operator's call to merge. |
| `→ review` | (informational, no banner) | Local code-review running; transient — not yet PR-up. Surface in run-state log, don't escalate to operator. |
| `→ done` | **🎉 DONE — `<TICKET>`** | Final ceremony complete; informational. |
| Signal-phrase comment, no status change | **📋 UPDATE — `<TICKET>`** | Progress checkpoint; informational. |

After the header, answer three questions, terse:
1. **What changed?** (Status transition or comment summary.)
2. **What does it mean?** (Done / blocked / decision needed / progress.)
3. **What's next, and is it on you or them?**

### Re-surfacing — once posted ≠ once seen

Operators are not staring at the chat continuously. A single banner 30 minutes ago that scrolled out of view is the same as silence.

- **Every wake-up tick while a ticket is in `needs_human` / `blocked`, re-surface the banner at the top of the response.** Stop the moment the ticket leaves that state.
- **OS-level notifications** for genuine time-sensitive blockers when the operator is expected AFK: `osascript -e 'display notification "<msg>" with title "🛑 <TICKET>" sound name "Glass"'`. Use sparingly — operators noise-fatigue.
- **c11 sidebar status** — set the Orchestrator pane's sidebar to a highlight color while any ticket is needs_human/blocked. Clear when unblocked.

## Press-ahead discipline

**Press-ahead means: spawn dependent work as soon as the dependency hits `review` or `pr_open`, not when it merges.**

- A ticket in `review` has its code committed on a branch (and code-review running locally). A ticket in `pr_open` has its branch pushed and the PR open. Either signals "press-ahead is safe — downstream tickets can build against this code."
- After every status transition, audit ALL not-yet-spawned tickets for new claimability surface created by that transition.
- Default to spawn unless there's a hard reason not to.
- The Merge Captain pattern (below) handles post-hoc conflicts at PR-landing time. The cost of one captain pass is far less than serializing the work.
- Don't wait for operator approval before spawning the next dependent ticket — that's a press-ahead failure. The operator's reviewing/merging cadence is independent of the next ticket's planning cadence; parallelize them.

### Branch off the in-review parent, NOT main

When dispatching a dependent ticket while its parent is in `review` or `pr_open`, branch the dependent's worktree off the parent's feature branch — not off main. This gives the dependent delegator direct access to the parent's shared code (imports, types, mocks, scaffolding) instead of having to mock against contract comments and discover signature drift at merge time.

```bash
# Parent at `pr_open` — its branch is on the remote:
git worktree add worktrees/<child-slug> -b <child-slug> <remote>/<parent-branch>

# Parent at `review` (branch not yet pushed) — branch off the local ref:
git worktree add worktrees/<child-slug> -b <child-slug> <parent-branch>
```

The dependent delegator's PR body **must** note the branch anchor + that the PR will rebase post-merge (e.g., "Branched off `<remote>/<parent-branch>` — merge that PR first, then this rebases"). Record the anchor in the run-state Wave table so a Merge Captain can plan the dependency order.

This pattern was the press-ahead reward on the EC v1.2.1 run: all three Wave 2 delegators branched off `<remote>/<parent-branch>`, got the foundation utilities import-stable for free, and the Result Validator confirmed cross-row C2 (shared-utilities import-stable) trivially. See `code/ExpandedCinema/LESSONS.md` (the canonical closeout-audit example) for the full story.

## Auto-merge mode (Phase-2 opt-in)

**Default off.** When the Phase-2 `PR merge policy` config is *Auto-merge* — either by operator choice at config-time or by the project's `CLAUDE.md` declaring `## PR merge policy — auto-merge through to done` — the Orchestrator squash-merges every PR at `pr_open` and runs `lattice complete` without waiting for human review. Use this for runs where the operator trusts the pipeline end-to-end (delegator code-review + auto-code-review-on-transition + Master Validator + Result Validator) and prefers `done` over a queue of open PRs. The tradeoff is no human gate before main moves; any issue with a merged PR gets fixed in a follow-up commit or ticket. Auto-merge is **not** the c11-wedge degraded mode below — that's a different situation (Captain dispatch is blocked); this is a steady-state default.

The tick-body step 4 fires automatically when this mode is enabled. The per-PR shape:

```bash
# Per PR that hit pr_open since last tick
TICKET=HOLO-NN
PR=NN
PAT=$(security find-internet-password -s forgejo.stage11.ai -w)  # or platform-equivalent

# 1. Check mergeability (rebase if needed). If the PR has no parent press-ahead anchor, a fast-forward merge usually applies cleanly.
curl -sf -H "Authorization: token $PAT" "https://forgejo.stage11.ai/api/v1/repos/<org>/<repo>/pulls/$PR" | jq '.mergeable, .has_merge_conflicts'

# 2. If mergeable=false or there's a parent dependency: rebase the worktree onto post-parent origin/main, push, retry. See "Press-ahead merge ordering" below.
#    Otherwise, skip straight to step 3.

# 3. Squash-merge.
curl -sf -X POST -H "Authorization: token $PAT" -H "Content-Type: application/json" \
  "https://forgejo.stage11.ai/api/v1/repos/<org>/<repo>/pulls/$PR/merge" \
  -d '{"Do":"squash","delete_branch_after_merge":false}'

# 4. Lattice complete.
lattice complete $TICKET --review "Merged via Orchestrator auto-merge (PR #$PR, squash). <one-line summary>. Per project auto-merge policy." --actor agent:orchestrator-<run>

# 5. Auto-close the delegator's surface (step 5 of the tick body does this; or do it inline here).
c11 close-surface --workspace $WS --surface $DELEGATOR_SURF
```

**Press-ahead merge ordering** is critical when delegators stacked branches via `### Branch off the in-review parent, NOT main`. The rule: merge the **parent** PR first; for each **child** PR, rebase its worktree onto post-merge `origin/main` and push (`--force-with-lease`) before merging the child. The child's PR head is rewritten, but its merge keeps the squash shape clean against the new main.

Concretely, for a stacked pair where child branched off `parent` at SHA `<P>`:

```bash
# After merging parent (PR #parent), rebase child onto new main
cd <child-worktree>
git fetch origin -q
git rebase origin/main   # picks up parent's squash commit, drops the now-redundant parent commits
# Resolve conflicts with the take-both-additive-registrations pattern documented below if any
git push --force-with-lease origin <child-branch>
sleep 5  # Forgejo recompute window
# Then merge child via the per-PR shape above
```

Record every auto-merged PR in `agents.md` under an "Auto-merges" subsection so the closeout audit can quantify what landed without human review and the run summary surfaces the merge SHA for each ticket.

**The take-both-additive-registrations conflict pattern** — when a rebase hits a conflict because both branches added entries to the same registration file (`__init__.py` re-exports, CLI subcommand registries, mock provider registries), the resolution is almost always "take both additions, preserve order by ticket id." Don't choose one side; merge the union. This was the documented pattern from the EC v1.2.1 + Holodeck v1 Phase 3 closeout audits.

**Conflict modes that need operator surfacing**: real semantic conflicts (both branches modified the same function's body, both renamed the same symbol, etc.) get surfaced via `🛑 NEEDS YOUR INPUT — <TICKET> auto-merge conflict` rather than guessed-at. Auto-merge mode does NOT mean "merge through any conflict."

## Orchestrator-as-captain (degraded mode, last resort)

**Different situation from auto-merge above.** This section covers the case where the *normal* Captain dispatch is blocked — most commonly when the c11 PTY allocator wedges and the Orchestrator can't spawn a new Merge Captain surface. The Orchestrator picks up the merging work itself as a last resort, regardless of the run's `PR merge policy` config. Auto-merge mode (above) is a steady-state choice; this is an escape hatch.

**Fix the underlying problem first.** If c11 wedges or Captain dispatch fails, the right move is to identify the root cause (restart c11, address auth, etc.) and resume the normal captain pattern. Running indefinitely in degraded mode masks real bugs that deserve fixing.

That said, when c11 is wedged and PRs are piling up — and the operator needs progress — the Orchestrator can merge PRs directly via the Forgejo / GitHub REST API. This is the documented escape hatch, not a steady-state approach:

```bash
# Per PR
cd <worktree>
git fetch origin -q
git rebase origin/main   # or `git rebase --onto origin/main <cut-sha>` for stacked branches
# Resolve conflicts (take-both for additive __init__.py, etc.)
uv run pytest tests/<touched>/ -x --tb=line
git push --force-with-lease origin <branch>
sleep 15  # Forgejo recompute window
curl -sS -X POST -H "Authorization: token $PAT" -H "Content-Type: application/json" \
  "<host>/api/v1/repos/<owner>/<repo>/pulls/<N>/merge" \
  -d '{"Do":"squash","delete_branch_after_merge":false}'
cd <repo_root>
lattice complete <TICKET-ID> --review "Landed via Orchestrator direct merge (PR #N). Notes on conflict resolution." --actor agent:orchestrator-<id>
```

Log every direct merge in `agents.md` under a "Direct merges" subsection so the closeout audit can quantify how often the degraded path fired (and flag the underlying issues for repair).

## Captain pattern

A **captain** is a one-shot recovery agent for cross-cutting batch operations across multiple tickets/PRs. Distinct from delegators (per-ticket) and sub-agents (per-phase inside a delegator). Examples:

- **Merge Captain** — rebases a stack and merges in dependency order.
- **Rebase Captain** — applies a sweeping main-merge across N open feature branches.
- **Status Captain** — recovers from a parallel-session race that corrupted ticket status.

Naming convention: `<Scope> Captain`. Spawn when there's cross-cutting work that doesn't fit a single ticket's scope. Captain stops when its operation is done; spawn a fresh captain rather than re-tasking the previous one.

### Merge Captain procedure

The Merge Captain lands a press-ahead stack onto main. Squash-merging stacked branches is a known foot-gun — **every PR after the first will hit conflicts** because the stacked branch chain causes them. The chain is what enabled the parallelism during build; it's also what creates the merge friction. Plan accordingly.

#### The stacked-branch-after-squash artifact (read first)

When PR #1 squash-merges, main gets one new commit containing the full diff. PR #2's branch still has #1's original (unsquashed) commits in its history. From git's perspective, these are different histories of overlapping content → conflict on every subsequent merge attempt.

**The fix is mechanical:** rebase each feature branch onto main, dropping the empty pre-ticket commits. The recipe:

```bash
cd worktrees/<branch>
git fetch origin main
# Find the last commit on this branch that's NOT this ticket's work
# (typically the parent ticket's last commit). Call it <cut-sha>.
git log --oneline HEAD -10
git rebase --onto origin/main <cut-sha> <branch>
git push --force-with-lease origin <branch>
# Wait 10–25s for GitHub to recompute mergeability, then merge.
```

The OVR V1 run (2026-05-20, 15 PRs) needed this on 14 of 15 PRs. Budget ~1–2 minutes per PR for the rebase + GitHub recomputation delay.

#### Retarget before delete-branch (foot-gun)

`gh pr merge <N> --delete-branch` deletes the base branch **atomically with the merge**. GitHub auto-closes any PR whose base is deleted, and **closed PRs with a missing base cannot be reopened or retargeted**. This bites whenever press-ahead PRs target *each other's* feature branches instead of main.

**Order matters:**

```bash
# WRONG — strands #11 and #12 if they target #10's branch:
gh pr merge 10 --squash --delete-branch

# RIGHT — retarget dependents first, then merge with delete-branch:
gh pr edit 11 --base main
gh pr edit 12 --base main
gh pr merge 10 --squash --delete-branch
```

If you find yourself with orphaned closed PRs (their base branch was already deleted), the recovery is: rebase the orphan branches onto main, force-push, open *fresh* PRs targeting main. The originals stay closed in the history — mildly confusing for reviewers but recoverable.

#### Conflict triage (what to auto-resolve, what to surface)

| Conflict shape | Action |
|---|---|
| **Additive dep-list in `pyproject.toml` + `uv.lock`** (both sides add different deps to the `dependencies = [...]` array) | **Auto-resolve.** Take the union of dep lines, then `rm uv.lock && uv lock` to regenerate deterministically. This is the dominant conflict shape across a stack — codify the auto-resolve so the operator isn't paged 6× per run. |
| **Empty/no-op rebase conflicts** (rebase trying to replay commits that are already in main as squashes) | **Auto-resolve via `git rebase --onto origin/main <cut-sha>`** — see recipe above. Skip the obsolete commits entirely. |
| **Modify/delete or modify/modify in code, schemas, tests** | **Stop. Run `uv run pytest <touched-package>/ -x` first** to see what depends on the deleted/modified code. Then decide: resolve in-session if the answer is unambiguous and the test confirms it, or surface to operator with the diff. |
| **Anything else novel** | Surface. |

#### Run-touched-tests-on-modify/delete rule

If you resolve a conflict by **deleting code** the other side modified, **other tests may depend on the deleted code**. Before pushing, run the targeted suite for the affected package:

```bash
uv run pytest tests/<affected-package>/ -x --tb=line
```

This is a 10-second check that catches the "import resolves but the symbol changed shape" failure mode. The Merge Captain isn't responsible for running the *full* suite, but is responsible for not shipping broken tests it created by deleting referenced code. On the OVR V1 run, skipping this check shipped 3 broken tests in `tests/job/test_cli_status.py` — caught only in retrospective.

#### Worktree state hygiene

Sibling delegators leave `uv.lock`, `__pycache__`, and other build cruft in worktrees. Before each rebase, scrub:

```bash
git -C <worktree> reset --hard HEAD
git -C <worktree> clean -fd
```

This is fully-autonomous-safe (work should already be committed; if not, the delegator that owned the worktree never finished — that's a separate problem to surface). Saves the 1–2 minute digressions on "untracked uv.lock blocks checkout" / "rm waits interactively."

#### Lattice status terminal-state check

The boot doc may say `lattice status <ticket> shipped`, but some installs resolve `shipped` → `done` (or use a different terminal-state name). Confirm at run start:

```bash
lattice show <any-completed-ticket> --json | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',d).get('status'))"
```

The command will succeed either way; this just makes the boot doc match the install's vocabulary so the operator isn't reading mismatched terms.

## Resume path

Dead-session recovery (host crash, c11 closed, /loop ended, /compact stranded the loop) is handled by c11's workspace persistence and the `claude-hook session-start` resume mechanism — see the `c11` skill's "Workspace persistence" section. The orchestrator does NOT carry its own dead-delegator recovery logic; rely on c11 to bring the surface back with the original session resumed, then resume the dispatch loop normally. If a delegator surface is gone after a c11 restart and didn't auto-resume, that's an operator-level recovery — surface it via `needs_human`.

For multi-day run resumption (operator returns the next day to an in-flight run), see the `## Resume path` section in `SKILL.md` — that's about resuming the *run* (re-reading run-state.md + agents.md, re-attaching to the existing Orchestrator pane), not about recovering a dead delegator.

## Run-time footgun catalog

When a delegator (or sub-agent) trips on a silent-failure mode that isn't already a HARD RULE in this file — a CLI key/value mismatch, an env-var that lies, a status-machine surprise, a worktree↔root bridge that drifts — capture it twice:

1. **Append a row to `run-state.md`** under a `## Run-time footguns` section:
   ```
   - 2026-05-19 — `until lattice review-status | grep state: done` polling loop returns `status: none`, never matches → silent stall. Mitigation: don't poll; read the artifact directly.
   ```

2. **Fold the mitigation into every subsequent delegator boot prompt** as a labeled warning. Don't expect the next delegator to read run-state.md and notice — bake the warning into the prompt body where it will be loaded before any tool calls.

The catalog (1) is for the operator and the closeout audit. The prompt update (2) is what actually stops recurrence. Catalog-without-prompt-update guarantees the next delegator hits the same wall.

The Archived rows in `agents.md` (see schema above) are the input signal — when a delegator's anomaly note matches an earlier one, you have a recurring footgun. Promote it to the catalog immediately; don't wait for a third instance to confirm.

**Escalation:** if the same footgun fires three times across delegators despite the prompt-baked mitigation, promote it from a per-run catalog entry to a permanent `HARD RULE` in this file. The prompt-warning approach isn't enough at that point — the rule needs to ride in the skill, not in each run's transient prompts.

## Closeout audit (when run completes)

After all tickets are in `pr_open` or `done` (and after the Result Validator's report, if enabled):

1. Read every Lattice ticket comment, every sub-agent surface transcript, every commit on every branch.
2. Extract **timeless** findings: patterns that will recur, gotchas worth a permanent fix. One-off mistakes don't qualify.
3. Each finding: **failure mode → why it matters → potential fix**.
4. Route by destination:
   - **`LESSONS.md` at project root** — default; cheapest write.
   - **Project's CLAUDE.md** — promotion candidate if it's a behavioral rule for this project.
   - **The workflow skill** (`lattice-orchestrator`) — promotion candidate if it's about the workflow itself.
   - **Lattice project** — promotion candidate if it's a Lattice CLI bug or footgun.

Audit writes to `LESSONS.md` directly. For the other three destinations, audit posts a Lattice comment on a tracking ticket recommending the promotion — the operator decides.

Audit entry format:

```markdown
## <YYYY-MM-DD> — <TICKET-ID> — <one-line title>
- **Failure mode:** what happened, in one sentence.
- **Why it matters:** what it costs if it recurs.
- **Workaround that worked:** the in-run fix (so the next agent doesn't reinvent it).
- **Potential fix:** the concrete next step (skill update / Lattice ticket / CLAUDE.md edit).
- **Routed to:** LESSONS.md (this file) — *or* "proposed CLAUDE.md update" / "proposed skill update" / "proposed Lattice issue."
```

**Canonical example:** `code/ExpandedCinema/LESSONS.md` (EC v1.2.1 run closeout, 5 findings — the `lattice code-review` worktree↔root failure that birthed the own-reviewer-tab fallback above; the press-ahead branch-off pattern; status-discipline drift; the `/compact` + `/loop` interaction; and the `lattice plan-review` auto-route gotcha). Use it as a shape reference when authoring a new run's audit.
