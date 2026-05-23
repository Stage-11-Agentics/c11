---
name: lattice-orchestrator
version: 1
description: Lattice Orchestration Workflow by Stage 11 — a four-phase workflow. Phase 1 the Architect runs a Planning Interview and produces SPEC.md, project CLAUDE.md, lessons-learned.md, and BUILDPLAN.md, plus an optional early-setup pass parallelizable with the build plan. Phase 2 the Architect captures run configuration AND writes all handoff artifacts (run-state.md, Lattice tickets, validation plan). Phase 3 a fresh Orchestrator pane runs the dispatch loop — delegators (one per ticket) drive plan → impl → review → fix → PR. Phase 4 a fresh Result Validator executes the Phase-2 validation plan against the run's output. Invoke when the operator says "orchestrate this," "kick off the orchestration," "run the orchestrator," "set up an overnight run," or similar.
---

# Lattice Orchestrator Workflow

The Stage 11 way to point a session at a project and end up with a small fleet of delegators producing open PRs, audited against spec at the end. Three named roles span the run end-to-end: **Architect** (Phases 1–2, produces every artifact the run needs), **Orchestrator** (Phase 3, dispatches delegators), **Result Validator** (Phase 4, terminal audit). Plus the supporting cast — delegators (one per ticket), captains (one-shot recovery), and the Master Validator singleton (in-flight global audit).

## Workflow modes — per ticket

Each ticket in a wave gets a workflow mode picked in Phase 2 and recorded in `run-state.md`'s wave table. Three modes; pick the lightest one that still earns its keep. Mixing modes within a wave is normal and encouraged — most real waves are 60–80% fast-track + inline-full with sub-agent-full reserved for the genuinely large outliers.

### 1. Fast-track — single session, inline self-review

One delegator session runs the whole arc `backlog → planned → in_progress → review → pr_open → done`. No sub-agents spawned. No `lattice plan-review` / `lattice code-review` CLI invocations. The same session wears planner / implementer / reviewer hats with distinct actor IDs in the event log (`agent:<id>-planner`, `-impl`, `-reviewer`) so the audit trail shows who did what. Code-review is attached inline against the diff:

```
lattice attach <task> --type note --role review --inline "<review markdown>" --actor agent:<id>-reviewer
```

The `--role review` artifact satisfies the default `done` completion policy. `lattice code-review --mode inline` is a guidance-printer — use `lattice attach` directly.

**Use for:** clear root cause; single file or a tight cluster of closely-related files; bug fixes, CLI flag additions, doc updates, single-function refactors, config tweaks, test additions — anywhere the implementer can plausibly catch their own bugs because the surface is small enough to hold in one head.

### 2. Inline-full — single session + headless `lattice` reviews between phases  *(default for medium work)*

Same single Claude session as fast-track, but with two extra steps. After the plan is written and before bumping to `planned`, the delegator runs:

```
LATTICE_SPAWN_BACKEND=headless
(cd $REPO_ROOT && lattice plan-review <TICKET-ID> --mode single --actor agent:<id>-plan-reviewer)
```

…as a **headless** bash subshell (the env var is the durable way; older installs accept `--headless` directly). The CLI spins a fresh-eyes reviewer backend, produces a typed artifact, and exits. The delegator reads the artifact, triages findings into an authoritative amendment block at the bottom of the plan file (`## Plan-Review Cycle K Resolutions (AUTHORITATIVE — overrides earlier text on conflict)`), then proceeds. Same shape after impl:

```
(cd <WORKTREE> && lattice code-review <TICKET-ID> --mode single --base origin/main --actor agent:<id>-reviewer)
```

Fresh-eyes value comes from the headless reviewer agent (different prompt, different context window) — *not* from spawning new c11 tabs. The delegator never leaves its own session.

**Use for:** real design surface but bounded scope; touches 2–5 files; a reviewer in a fresh head will catch what the implementer can't easily see, but the impl itself fits in one head. Dispatcher reconciliation, API-key plumbing, schema extensions, contract reconciliation. **Default when in doubt** — it gets fresh-eyes value while keeping c11 PTY pressure low (1 surface per ticket instead of 3–5).

If `lattice code-review` hangs past ~5–10 minutes or returns an empty diff (the documented worktree↔root bridge bug), fall back to the **own-reviewer pattern** before abandoning the phase — see `references/orchestrator.md` § "Own-reviewer-tab fallback."

### 3. Sub-agent-full — separate c11 tabs for plan / impl / fix  *(escalation only)*

The original four-agent-dance shape. Planner spawned as a new tab on the delegator's pane; the delegator monitors via `/loop`; headless `lattice plan-review` once the planner posts completion; impl sub-agent in another new tab; headless code-review; fix sub-agent if findings exist.

**Use only when:** the ticket is genuinely enormous (thousands of LOC across many independent files); each phase needs a fresh context window because no single window can hold the whole thing; or the work spans skill domains the same context shouldn't try to multitask. Sub-agent spawns add c11 PTY pressure (wedge threshold ~15 surfaces per pane) and orchestration overhead (a delegator `/loop` per spawned sub-agent), so this mode trades against pane budget and run wall time.

### Mode-selection rule of thumb

- **Escalate one step at a time.** Fast-track → inline-full → sub-agent-full. The cost of an unreviewed merge is unbounded, but going from fast-track straight to sub-agent-full is rarely the right move.
- **Capture the mode per ticket in `run-state.md`'s wave table.** The Orchestrator's tick body reads it to set the right expectations: fast-track delegators run synchronously and don't enter `/loop`; inline-full and sub-agent-full delegators run under `/loop`.
- **Boot prompt scope matches the mode.** A fast-track prompt does not include `lattice plan-review` / `lattice code-review` lines. An inline-full prompt includes them as headless subshells. A sub-agent-full prompt spawns plan/impl/fix sub-agents and references the sub-agent boilerplate at the bottom of `references/orchestrator.md`. See `references/orchestrator.md` § "Spawning a delegator" for templates of each.

## The flow

```mermaid
flowchart TD
    P1["<b>Phase 1 — Planning &amp; Build</b><br/><i>Architect</i><br/>Step 1: Planning Interview<br/>Step 1.5: Project CLAUDE.md<br/>Step 1.6: lessons-learned.md<br/>Step 1.7: Early setup (optional, parallelizable)<br/>Step 2: Build Plan"]
    P2["<b>Phase 2 — Run Configuration</b><br/><i>Architect</i><br/>config + handoff artifacts<br/>(tickets, run-state, validation plan)"]
    P3["<b>Phase 3 — Orchestration of Implementation</b><br/><i>Orchestrator</i><br/>dispatch loop until every ticket has an open PR"]
    P4["<b>Phase 4 — Validate Result</b><br/><i>fresh Result Validator</i><br/>executes Phase-2 validation plan"]

    P1 -->|SPEC.md + CLAUDE.md + lessons-learned.md + BUILDPLAN.md<br/>(+ early-setup artifacts if authorized)| P2
    P2 -->|tickets + run-state.md + validation-plan.md<br/>ExitPlanMode + spawn fresh pane| P3
    P3 --> ORCH
    ORCH -->|run complete| P4

    subgraph ORCH["Orchestrator pane — dispatches delegators"]
        direction LR
        D1["Delegator 1"]
        D2["Delegator 2"]
        D3["Delegator 3"]
    end
```

Three distinct agent identities across the run. The Architect's context never bleeds into the Orchestrator's; the Orchestrator's never bleeds into the Result Validator's. That independence is the point — each role audits the previous role's work with fresh eyes.

---

## Preflight

**Your first action when the operator invokes the workflow, before anything else.** A ~30-second check that the substrate this workflow assumes is actually present. The whole flow leans on Lattice, a git repo, and an agent harness that can spawn parallel sub-sessions; catching a missing piece on minute one beats discovering it when the Architect is trying to write tickets in Phase 2.

Run each check, print a one-line result, halt on any hard failure with the fix inline.

**Hard checks (halt on miss):**

- **Lattice CLI on PATH** — `lattice --version`. If missing, Lattice is the substrate every phase reads and writes through; there's no degraded mode. Point the operator at the install path (`uv tool install -e <path-to-Lattice>` from source, or the Lattice repo's README) and stop.
- **Git repo** — `git rev-parse --show-toplevel`. If we're not inside one, stop. Step 1.7 (Early setup) offers `git init`, but only once we get there; the Architect can't write tickets that reference a project without a project root.
- **Concurrent agent surfaces are reachable** — `C11_SHELL_INTEGRATION=1` confirms c11 (every layout primitive works). Outside c11, ask the operator to confirm they can spawn parallel sub-sessions in whatever terminal they use. If they cannot, the workflow's dispatch loop has nowhere to land delegators; stop.

**Soft warnings (note and continue):**

- **c11 not detected** (`C11_SHELL_INTEGRATION` unset) — print: "Running without c11. Layout sections (Main View Area / Control Surface / Delegate View Area) are conceptual; pane/surface/sidebar commands no-op. Workflow still runs end-to-end."
- **No Lattice state in this project** (no `.lattice/` directory and no Phase 2 artifacts under `.lattice/orchestration/`) — print: "Fresh project. Step 1.7 (Early setup) will offer `lattice init --workflow classic`."
- **No git remote configured** (`git remote -v` empty) — print: "No git remote. Step 1.7 will offer Forgejo/GitHub repo creation. PR creation in Phase 3 requires this."

**Output shape — terse grid, then proceed or halt:**

```
Preflight:
  [✓] lattice CLI present
  [✓] inside git repo
  [✓] c11 detected (workspace:1)
  [!] no Lattice run state — will offer `lattice init` in Step 1.7
  [!] no git remote — will offer repo creation in Step 1.7
Proceeding to Phase 1.
```

On a hard miss the grid stops at the failure with the install/fix hint inline. Don't continue.

**Resume runs skip the soft warnings on existing state.** If `.lattice/orchestration/run-state.md` is already present, the second and third soft warnings are inapplicable by definition; just report `[✓] resuming in-flight run`.

---

## Phase 1 — Planning & Build (Architect)

**Goal:** produce or update `SPEC.md`, project `CLAUDE.md`, `lessons-learned.md`, and `BUILDPLAN.md` at project root, plus optionally an early-setup pass parallelizable with the build plan.

One agent — the **Architect** — runs the steps sequentially, carrying context forward. Identity declared at start (sidebar, tab name, c11 manifest if inside c11) so the operator can see which seat they're talking to.

### Step 1: Planning Interview → `SPEC.md`

- Detect existing `SPEC.md`:
  - **Present** → surface a summary, ask `use as-is / refine / replace`. Default `use as-is`.
  - **Missing** → run a dialogue to author it.
- **Dialogue-driven, not a checklist.** Use `AskUserQuestion` liberally — 5, 10, 20 rounds is fine. Adapt to what's already known. Watch out for the Entrance Interview anti-pattern: operators bristle at fixed questionnaires.
- Output: `SPEC.md` — user-facing requirements, scope, success criteria. The WHAT.

### Step 1.5: Project CLAUDE.md → `CLAUDE.md`

After SPEC.md is locked, author or update the project's `CLAUDE.md` at the project root. CLAUDE.md is the agent-facing operational doc — every future session in this project reads it first. Keep it terse (~100 lines).

- One-line project description + links to PHILOSOPHY.md + SPEC.md.
- Project home (local path; Forgejo/GitHub URL).
- **Autonomy default** for the lattice-orchestrator workflow. If the operator wants this project to default to a specific level (e.g., *"Run in Fully Autonomous mode by default"*), declare it here — Phase 2 reads it as the default instead of Moderate.
- **`## Lessons learned`** section pointing at `lessons-learned.md` (Step 1.6) and the trigger conditions (failures, confusion, thrash).
- Conventions, privacy posture, service touchpoints.
- Tech stack and build / test / run commands as placeholders; finalized in a Step 2 second pass after BUILDPLAN.md lands.

Full template + second-pass detail in `references/architect.md`.

### Step 1.6: `lessons-learned.md`

Author `lessons-learned.md` at the project root — an append-only log of failures, points of confusion, and thrash. Every future agent appends entries when they hit something worth flagging. The CLAUDE.md "Lessons learned" section (Step 1.5) makes that obligation explicit; the file gives the format.

Template + format detail in `references/architect.md`.

### Step 1.7: Early setup — optional, parallelizable with planning

Once SPEC.md, CLAUDE.md, and lessons-learned.md are locked, the Architect **offers** a checklist of standardized setup tasks to the operator: `git init`, Forgejo/GitHub repo creation, `lattice init` (use **`--workflow classic`** — see references), Lattice dashboard launch with port-collision check, c11 workspace layout.

These do not depend on BUILDPLAN.md and can run in the background while the operator iterates on the build plan or runs a plan review. Anything declined falls back into the Phase 2→3 handoff as before.

Full task list, port-collision pattern, and `lattice init` defaults in `references/architect.md`.

### Step 2: Build Plan → `BUILDPLAN.md`

Same Architect, carrying spec-context forward. Covers:

- **High-level technical decisions** — stack, framework, infrastructure, key library choices.
- **Overall architecture** — components, data flow, integration points.
- **Per-screen functionality** (when there's a UI) — what each screen does, what state it owns.
- **Optional screen layout diagrams** — Mermaid when layout itself is a decision point.
- **Breakdown into tickets** — the work, sliced into Lattice tickets the Orchestrator spawns delegators against. **Bias toward shapes that maximize parallelism** — independent modules, narrow interfaces, schemas that ship ahead of consumers. Fewer dependencies = more parallel work = faster run. Ticket fidelity (verbose vs minimal) is operator-chosen in Phase 2.

Operator confirms `BUILDPLAN.md` before Phase 2 begins. Iterate as long as needed — the cost of getting the plan wrong here is hours of misdirected delegator work downstream.

Dialogue patterns, SPEC.md / BUILDPLAN.md templates, breakdown convention: `references/architect.md`.

---

## Phase 2 — Run Configuration (Architect)

**Goal:** capture every variable needed for Phase 3, then write every handoff artifact so the Orchestrator can boot with full context.

Still the Architect. Two parts: gather the config, then write everything to disk.

### Config questions (in rough order)

- **Autonomy level** — Fully Autonomous / Moderate / Minimal. Default: from project `CLAUDE.md` if it declares an autonomy default (e.g., `## Autonomy default — Fully Autonomous`); otherwise Moderate.
- **Concurrent delegator cap (N)** — operator picks. Default `N=5`. Scales down for Minimal autonomy.
- **Auto-close finished delegator surfaces** — Yes (default) / No. When a delegator's ticket reaches `done` in Lattice, the Orchestrator runs `c11 close-surface` on its delegator + sub-agent surfaces. Frees PTY slots and avoids the c11 wedge that fires around ~25 surfaces per pane. Operator may choose No if they want to inspect dead-session transcripts manually (sessions can also be resumed later from c11's persistence).
- **PR merge policy** — *Leave at pr_open* (default) / *Auto-merge*. Default leaves PRs for the operator to merge manually after Phase-3 dispatch completes. *Auto-merge* opts the run into the pattern documented at `references/orchestrator.md` § "Auto-merge mode (Phase-2 opt-in)" — the Orchestrator squash-merges every PR at `pr_open` and runs `lattice complete` without waiting for human review. Use auto-merge when the operator trusts the pipeline (delegator review + headless code-review + Master Validator + Result Validator) and prefers `done` over a queue of open PRs. Default: pick up from the project's `CLAUDE.md` if it declares `## PR merge policy — auto-merge through to done`; otherwise *Leave at pr_open*. Operator-AFK runs with a large ticket bundle benefit substantially — the Overtone V1.1 build run (2026-05-23) sat at 7 PRs queued for ~5h before manual clearance; under auto-merge it would have closed itself out.
- **C11 detection** — if `C11_SHELL_INTEGRATION=1`, lean in: workspace layout preferences, browser pane wanted, sidebar status flag color, anything c11-specific the operator wants tuned. **Three delegate panes by default** (not one): the c11 PTY allocator wedges past ~25 surfaces per pane, and a single dispatch pane will hit that threshold on any non-trivial run. See `references/orchestrator.md` § "Workspace activation".
- **Lattice ticket fidelity** — Verbose (detailed acceptance criteria, full description, full plan) vs Minimal (one-line summary linking back to BUILDPLAN.md section). Operator's "vibe."
- **Master Validator** — On (default for runs >3 tickets) or off.
- **Closeout audit** — On (default) or off.
- **Result Validator at Phase 4** — On (default) or off.

### Handoff artifacts (written before Phase 3 begins)

Once every variable is known, the Architect writes — in this order, all on disk before exiting plan mode:

- **Lattice tickets** — one per BUILDPLAN.md ticket entry, at chosen fidelity. Each ticket references its BUILDPLAN.md section + SPEC.md acceptance criteria.
- **`.lattice/orchestration/run-state.md`** — autonomy, cap (N), ticket list, validator flags, c11 preferences.
- **`.lattice/orchestration/agents.md`** — empty scaffold; the Orchestrator populates as delegators spawn.
- **`.lattice/orchestration/validation-plan.md`** — per-acceptance-criterion audit plan. Authored **now**, while spec context is fresh — not at Phase 4 when the auditor has only artifacts to read from. Captures, per row: which SPEC.md criterion, how to verify it, which artifact to inspect (which PR / screen / file / test).

When all artifacts are on disk, Phase 2 is done.

Full config question set, validation plan template, ticket fidelity examples: `references/architect.md`.

---

## Phase 3 — Orchestration of Implementation (Orchestrator)

**Goal:** run the dispatch loop until every ticket has an open PR.

Starts with a short handoff transition (the artifacts already exist on disk from Phase 2):

1. **`ExitPlanMode`**.
2. **Spawn a fresh c11 pane** with `cd <project-root> && claude --dangerously-skip-permissions --model opus`. Boot prompt loads `SPEC.md` + `BUILDPLAN.md` + `run-state.md` + `validation-plan.md` and assumes the Orchestrator role.
3. **Architect's session steps aside.** The Orchestrator pane is now the operator's channel for this run.

Then the dispatch loop:

- Orchestrator reads the ticket list from `run-state.md` and the dependency graph in Lattice.
- Spawns up to **N delegators** in parallel (N = configured cap, default 5).
- Each delegator runs in its own git worktree, in its own pane, driving plan → impl → review → fix → open PR (with `pr_open` as its terminal Lattice status — the new workflow puts `pr_open` between `review` and `done`).
- Orchestrator runs a `/loop` (Claude's native recurring-task primitive) — 4-min tick while delegators are in flight, longer when quiescent. Each tick surfaces `needs_human` / `blocked` tickets, advances dependency-unblocked work, reports state. **Never use shell `watch` / `sleep` / `lattice watch --exec` as the cadence engine.** See `references/orchestrator.md` `## Cadence`.
- **Press-ahead discipline** — the moment a ticket hits `review` (local code-review running) or `pr_open` (PR up), downstream tickets whose work can be designed against the in-flight feature branch become claimable. Branch dependent worktrees off the parent's feature branch, NOT main — see `references/orchestrator.md` `### Branch off the in-review parent`.
- Run completes when every ticket is in `pr_open` or `done`.

Loop cadences, escalation format, run-state.md schema, press-ahead rules, captain pattern: `references/orchestrator.md`.

Pane spawn details, boot prompt template, multi-day run-resume path: `references/orchestrator.md`. (Dead-session recovery — host crash, c11 closed, /loop ended — is delegated to c11's workspace persistence and `claude-hook session-start`; see the `c11` skill.)

---

## Phase 4 — Validate Result (Result Validator)

**Goal:** terminal audit — does the run's output match the spec?

Fires when the Orchestrator declares the run complete. A **fresh Result Validator agent** spawns in its own pane. Fresh because Orchestrator bias toward "my work is good" is the failure mode this phase exists to prevent.

The Result Validator:

1. Loads `SPEC.md`, `BUILDPLAN.md`, and `validation-plan.md` (authored in Phase 2 while spec context was fresh).
2. Walks each row of the validation plan: pulls the named PR(s), inspects the named artifact, runs the named verification.
3. Records pass / fail / partial per acceptance criterion.
4. Produces the **Validation Report** at `.lattice/orchestration/validation-report.md`: per-criterion result, gaps, drift from BUILDPLAN.md architecture, recommendations.
5. Surfaces the report to the operator.

The operator decides: accept the run, send fixes back to delegators via the still-live Orchestrator, or open follow-up tickets.

Skippable in Phase 2 config for trivial runs where the spec-vs-result audit isn't worth the agent-spawn overhead.

Audit protocol, report template, when to skip: `references/result-validator.md`.

---

## Autonomy levels

Three levels. Set in Phase 2, recorded in `run-state.md`, governs every Orchestrator decision.

### Fully Autonomous

**Approval threshold:** only stops for spend > $20 OR permanent data destruction. **Default behavior is to route around even those.** Pick a path that doesn't trigger the stop.

- Mildly irreversible (file deletes, branch deletes, force-push to a feature branch) → auto-approved.
- Small spend (< $20) → auto-approved.
- Architectural choices, scope expansions, dependency loosening → Orchestrator picks, logs the decision to `run-state.md`, proceeds.
- Anything else → Orchestrator picks, ships, surfaces on operator return.

The 99.9% rule: if you're tempted to ask, you almost certainly shouldn't. Find the path that doesn't need approval.

### Moderate Intervention

**Approval threshold:** non-trivial architectural choices, scope expansions, mild irreversibility.

- Standard "interactive" posture. Surfaces at meaningful decision points.
- Default for day-time runs with the operator engaged.

### Minimal Intervention

**Approval threshold:** every phase transition and most substantive choices.

- The operator is actively co-driving. Orchestrator asks more than it decides.
- Use for high-stakes or unfamiliar projects, or when the operator wants close-quarters supervision.

---

## Roles (one-liners)

- **Architect** — Phases 1–2. Produces SPEC.md, project CLAUDE.md, BUILDPLAN.md, run-state.md, Lattice tickets, and the validation plan. Hands off to Orchestrator at the Phase 2→3 boundary, then steps aside.
- **Orchestrator** — singleton during Phase 3. Human↔LLM channel. Dispatches delegators, never implements.
- **Delegator** — one per Lattice ticket. Drives plan → impl → review → fix → PR in its own worktree + pane. Terminal state: open PR.
- **Captain** — one-shot recovery agent for cross-cutting batch work (e.g., Merge Captain rebases a stack). Naming: `<Scope> Captain`.
- **Master Validator** — singleton during Phase 3. Continuously audits global build/test/PR state in-flight, reports up to the Orchestrator. Lives in the Main View Area (full-height left column) alongside the Orchestrator, both as singleton tabs the operator can glance at any time.
- **Result Validator** — Phase 4. Fresh agent, terminal audit executing the Phase-2 validation plan. Produces the Validation Report. One-shot.

---

## Layout (inside c11, during Phase 3)

Three named regions. Each region is a c11 pane (titled via `c11 set-metadata --pane <ref> --key title --value "..."`). Surfaces within a region show as tabs of that pane.

<table>
  <tr>
    <td rowspan="2" align="center" width="50%">
      <b>Main View Area</b><br/><br/>
      full-height left column<br/>
      <b>singletons live here</b><br/><br/>
      Orchestrator (operator's<br/>primary conversation channel)<br/>
      Master Validator<br/>
      (continuous in-flight audit)<br/><br/>
      <i>any future singleton roles<br/>also land in this region</i>
    </td>
    <td align="center" width="50%">
      <b>Control Surface</b><br/><br/>
      Lattice Board<br/>
      ticket status<br/>
      + dependency graph<br/><br/>
      <i>where the operator goes to<br/>redirect, prioritize, intervene</i>
    </td>
  </tr>
  <tr>
    <td align="center">
      <b>Delegate View Area</b><br/><br/>
      Delegators 1..N<br/>
      (default N=5, set in Phase 2)<br/>
      each in own worktree + pane,<br/>
      plan → impl → review → fix → PR
    </td>
  </tr>
</table>

Notes on the layout:

- **Main View Area** (left, full-height) is where **singletons live** — currently the Orchestrator (operator's primary conversation channel) and the Master Validator (continuous in-flight audit). Most-glanceable real estate is reserved for the roles whose output the operator needs constant visibility into. Singletons sit as tabs of the same pane; the operator switches between them with c11 tab navigation. Any future singleton role lands in this region by default.
- **Control Surface** (top-right) holds the **Lattice Board** — a c11 **browser pane** pointing at the project's local `lattice dashboard` URL, not a terminal running `lattice list`. Start the dashboard on a free port before opening the pane. The operator's at-a-glance work view, and where they reach to redirect, prioritize, or intervene.
- **Delegate View Area** (bottom-right) is where the actual delegator panes live. The single cell in the diagram represents Delegators 1, 2, 3, …, N — where **N is the maximum concurrent delegators set in Phase 2 (default 5)**. Each delegator gets its own pane inside this region; sub-agents (plan / impl / review / fix) run as **new tabs on the delegator's own pane**, never headless `claude -p` shells.

Each region is a real c11 pane with its own pane-layer title and description — set via `c11 set-metadata --pane <ref> --key title --value "Main View Area"` (and `--key description --value "..."`). The operator can read the layout from the sidebar without opening any surface.

Outside c11, the role model is unchanged but the surfaces are whatever's available.

---

## Default mode: delegate (Orchestrator only)

The Orchestrator's one inviolable norm — it dispatches delegators; it does not implement. (The Architect, by contrast, *is* the implementer of its own phase's artifacts.)

- Operator asks the Orchestrator for an implementation change → it routes to the relevant delegator.
- Operator asks the Orchestrator about a ticket → it answers from its own context or queries the delegator.

A trivial inline fix during the operator's live conversation is allowed (a README typo, a one-line config tweak). Sustained code-writing by the Orchestrator means the workflow has drifted — recover by spawning a delegator.

---

## Build for debuggability: extensive logs + automated access

A meta-principle the Architect bakes into the build plan and every delegator carries into implementation. Agents debug almost exclusively from artifacts: logs, status endpoints, structured outputs, exit codes. When the system being built makes those artifacts cheap to produce and easy to consume, the loop tightens dramatically — failures get diagnosed in seconds, sub-agents self-validate without operator intervention, and the Result Validator's Phase 4 audit has more to read.

Bias toward:

- **Generous structured logging by default.** Every meaningful step logs what it did with enough context to reconstruct state later. JSON lines when volume warrants. Don't gate behind verbose flags by default — the cost of "too much log" is trivial compared to the cost of one missing breadcrumb at 2am.
- **Automated access surfaces.** Every running system should expose a programmatic seam an agent can hit without a UI: a CLI subcommand, a Unix socket, an HTTP endpoint, a `--json` flag on the relevant binaries. If the delegator can't `curl` / `grep` / query what it just built, the next debugging pass needs an operator in front of a screen, which this workflow exists to avoid.
- **Surfaceable status, not buried state.** Expose queues, in-flight jobs, last-error, health. `status` / `inspect` / `dump` subcommands cost almost nothing at write-time and pay back every time something goes sideways.
- **Legible failures.** Errors print why, what, and (when known) what to try. Stack traces alone are evidence, not diagnosis.

Architects call this out explicitly in the project `CLAUDE.md` (Step 1.5) so every future delegator in the project sees it. The Build Plan (Step 2) reflects it in component design — observability is part of the spec, not a Phase-4 retrofit.

---

## Resume path

If the skill is invoked on a project that already has `SPEC.md`, `BUILDPLAN.md`, and `.lattice/orchestration/run-state.md`, the Architect detects an in-flight run. (Project `CLAUDE.md` is also detected and refreshed if its standard sections are stale.)

- **Phase 1 Step 1** collapses to: "SPEC.md exists. Use as-is, refine, or replace?"
- **Phase 1 Step 1.5** collapses to: "CLAUDE.md exists. Standard sections present and current?" If sections are missing or stale, the Architect proposes targeted updates rather than a full rewrite.
- **Phase 1 Step 2** collapses to: "BUILDPLAN.md exists. Confirm or edit?"
- **Phase 2** collapses to: "run-state.md exists. Confirm or edit autonomy / cap / etc?" — validation plan and tickets get the same surface-and-confirm treatment.
- **Phase 3** spawns a fresh Orchestrator pane bound to the existing run-state. If the c11 workspace was snapshotted, restoring it with `C11_SESSION_RESUME=1 c11 restore <id>` brings the Orchestrator (and any in-flight delegators) back with their sessions resumed — see the `c11` skill's "Workspace persistence" section.
- **Phase 4** is unchanged — fires when the Orchestrator declares the (resumed) run complete.

No re-interviewing. The operator can walk away mid-run, come back the next day, and pick up exactly where things stand.

---

## References

Three files, loaded on demand. **Each is one role's playbook — sub-pages of the workflow, not separate skills.** The agent currently in that role reads the relevant playbook; the others stay unloaded. Anything not pinned to a reference is left to model intelligence and project context — see Stage 11 CLAUDE.md's "Skill Writing: Trust Model Intelligence."

| File | When to load |
|---|---|
| `references/architect.md` | Phases 1–2 — planning interview patterns, SPEC.md + CLAUDE.md + BUILDPLAN.md templates, config question set, validation plan template, ticket fidelity examples, breakdown convention |
| `references/orchestrator.md` | Phase 3 — boot prompt, loop cadences, escalation format, press-ahead discipline, run-state.md / agents.md schema, sub-agent boilerplate (stop instruction, read-before-write, deviate-with-flag), captain pattern, resume path, closeout audit |
| `references/result-validator.md` | Phase 4 — audit protocol, Validation Report template, when to skip |

Operational footguns around Lattice CLI (parent-repo-vs-worktree, status discipline, plan-review amendment blocks) live in the **`lattice` skill**, not here — that's where they belong since they apply to every Lattice-using project, not just orchestrated runs.
