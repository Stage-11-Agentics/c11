# Architect — Phases 1 & 2 Reference

The Architect runs Phases 1 and 2: planning interview → build plan → run configuration → handoff artifacts on disk. One agent, identity declared at start, hands off to a fresh Orchestrator at the Phase 2→3 boundary.

## Identity declaration

First thing the Architect does — before any dialogue:

```bash
# Inside c11
c11 set-agent --type claude-code --model claude-opus-4-7
c11 rename-tab --surface "$C11_SURFACE_ID" "Architect"
c11 set-description --surface "$C11_SURFACE_ID" "Lattice Orchestrator Architect — planning interview + build plan + run config. Producing SPEC.md, BUILDPLAN.md, run-state.md, validation-plan.md, and Lattice tickets before handoff to Orchestrator."
```

Outside c11: state the role in the first message back to the operator.

## Phase 1 Step 1 — Planning Interview (→ SPEC.md)

**Detect first.** If `SPEC.md` exists at project root, read it, summarize it back to the operator in 3–5 lines, and ask: `use as-is / refine / replace?` Default `use as-is` if the operator doesn't push back. The rest of Step 1 only applies when SPEC.md is missing or being replaced.

**Start open, then narrow.** The very first prompt is always open-ended text — no `AskUserQuestion`, just an invitation to talk:

> *"What are we building? What problem are we solving?"*

From there, follow with open-ended questions to draw out the main flows, who the users are, and what success looks like — anything where the operator's framing matters more than picking between options. As decisions firm up and the conversation moves from "what is this?" to "which option here?", **switch to `AskUserQuestion`**. Its options + descriptions convey concrete tradeoffs faster than open prose, and the operator can always select "Other" to write free text when the options don't fit. Minimize open-text questions once you have enough context to start framing real choices.

**Scale dramatically with project size.** Match the question count to the project's actual complexity, not to a fixed template:

- **Trivial** (CLI utility, small script, single-file refactor): a handful of questions, mostly open. SPEC.md may be half a page.
- **Standard** (web feature, library module, multi-file refactor): 5–15 questions, mixed open + `AskUserQuestion`. SPEC.md is 1–2 pages.
- **Large** (significant user-facing software, novel domain, multi-month commitment): 15–40+ questions across several rounds. **Consider proposing to spawn research sub-agents** — competitor analysis, market research, prior-art audits, technology landscape scans — *before* authoring SPEC.md. The Architect surfaces the suggestion; the operator approves. Findings come back as input to the planning interview.

Don't run a fixed questionnaire. The operator should never feel like they're filling out a form.

**SPEC.md shape** (lean template — adapt to the project):

```markdown
# SPEC — <project name>

## What this is
1–3 sentences. What the thing is for, who it's for, what it replaces or adds.

## Goals
- Goal 1
- Goal 2

## Non-goals
- Explicit out-of-scope item 1
- Explicit out-of-scope item 2
(Non-goals are as important as goals — they keep BUILDPLAN.md from drifting.)

## Acceptance criteria
Numbered list. Each criterion is testable. These are what the Result Validator audits in Phase 4.
1. Criterion 1 — concrete, verifiable.
2. Criterion 2 — …

## Constraints & assumptions
Anything load-bearing the operator hasn't said but the build will lean on (auth model, hosting, data residency, target platforms, etc.).

## Open questions
What the Architect couldn't resolve and is deferring to either BUILDPLAN.md or the operator's later review.
```

Skip sections that don't fit. Add sections the project needs. The shape above is a starting point, not a contract.

## Phase 1 Step 1.5 — Project CLAUDE.md (→ CLAUDE.md at project root)

Once SPEC.md is locked, the Architect authors or updates the project's `CLAUDE.md` at the project root. CLAUDE.md is the agent-facing operational doc that every future session in this project reads first — it sits at the top of every context window and should stay terse (~100 lines max).

Contents at this stage:

- One-line project description + links to `PHILOSOPHY.md`, `SPEC.md` (the `BUILDPLAN.md` link is added by the second pass below).
- Project home — local path; Forgejo/GitHub URL.
- **Autonomy default** for the lattice-orchestrator workflow. If the operator wants this project to default to a specific autonomy level (e.g., *"Run in Fully Autonomous mode by default"*), declare it here. **Phase 2 reads this and uses it as the default autonomy instead of Moderate.**
- Project-specific conventions, privacy posture, service touchpoints.
- Tech stack and build / test / run commands as placeholders — filled by the Step 2 second pass.

If CLAUDE.md already exists from prior project work, the Architect *updates* it — preserving anything the operator wrote, adding the lattice-orchestrator-relevant sections (autonomy default, standard-files index), and surfacing any drift to the operator for confirmation.

**Second pass at end of Step 2.** After BUILDPLAN.md is locked, the Architect updates CLAUDE.md to fill in tech-stack specifics, build / test / run commands, and any conventions that surfaced during the build plan. Two passes total: one declaration after SPEC.md, one finalization after BUILDPLAN.md.

The CLAUDE.md must include a **`## Lessons learned`** section pointing at `lessons-learned.md` (Step 1.6) and instructing future agents to append entries on failures, confusion, or thrash. Format and trigger conditions live in that section.

## Phase 1 Step 1.6 — `lessons-learned.md` (→ lessons-learned.md at project root)

Author `lessons-learned.md` at the project root. The file is an **append-only** log of failures, points of confusion, and thrash that hit the project. Every future agent in this project is expected to add an entry whenever one of those happens — not only catastrophic failures, but moments of confusion that cost time, dead ends, surprising defaults, things that bit unexpectedly. The CLAUDE.md "Lessons learned" section (Step 1.5) makes that obligation explicit.

Template — write it once; agents extend it over time:

```markdown
# Lessons learned — <project>

Append-only log. Every failure, point of confusion, or thrash gets an entry. The point is to make the next agent or session pay less for the same problem.

**Format per entry:**
- `## YYYY-MM-DD — <short title>` (one-line header)
- **What happened**: factual one-paragraph
- **Why it bit**: the root cause, not just the symptom
- **Fix applied** (if any): what was done in this run
- **For next time**: what should change in scripts, skills, or process

Entries should be terse. If a lesson is wide enough that other Stage 11 projects would benefit, also propagate it into the relevant skill or `code/platform/{service}.md` doc — this file is the local copy, the skill/platform docs hold the durable version.
```

If `lessons-learned.md` already exists from prior project work, leave it alone — it's append-only by design.

## Phase 1 Step 1.7 — Early setup (offered to operator; parallelizable with planning)

A set of standardized setup tasks does not depend on BUILDPLAN.md content. They can be initiated as soon as SPEC.md (and CLAUDE.md + lessons-learned.md) is locked, and they run in the background while the operator iterates on BUILDPLAN.md or runs a plan review (e.g., Trident). **The Architect should offer them to the operator as a checklist at the end of Step 1.6** — anything declined falls back into the Phase 2→3 handoff sequence as before.

Why this matters: orchestrator-driven runs hit ~30 minutes of plumbing if everything is batched at Phase 2→3 handoff. Running these in parallel with planning removes that serial choke point.

Candidate tasks (skip what doesn't apply to the project):

- **Git project initialization.** `git init`, initial commit including the Phase 1 docs (PHILOSOPHY.md, SPEC.md, CLAUDE.md, lessons-learned.md) plus a `.gitignore`.
- **Forgejo / GitHub repo creation.** Private by default per Stage 11 convention. Push the initial commit; add remote.
- **`lattice init`.** Use **`--workflow classic`** — the orchestrator flow uses canonical status keys (`backlog`, `in_progress`, `review`, `pr_open`, `done`). The `opinionated` preset's playful display names ("thinking about it", "on it", "shipped") conflict with the architect / orchestrator vocabulary. Pass `--actor`, `--project-code`, `--project-name`, `--model`, plus `--no-setup-claude --no-setup-agents` since the Architect manages those directly.
- **Lattice dashboard.** Start with a project-unique port. **Check `lsof -nP -iTCP:<port> -sTCP:LISTEN` first** — do not assume a free port. After launch, tail the dashboard log for "Port X is already in use" before declaring success. Capture the chosen port in `run-state.md` (Phase 2).
- **c11 workspace layout.** Geometry per the Phase 2→3 handoff (Main View Area / Control Surface / Delegate View Area). Title each pane via `c11 set-metadata`. Add the Lattice Board browser surface to the Control Surface.

The operator can authorize "all of the above" or pick selectively. Whatever runs at this step is written to `run-state.md` once Phase 2 begins so the Orchestrator has a complete inventory.

## Phase 1 Step 2 — Build Plan (→ BUILDPLAN.md)

Same Architect, carrying spec-context forward. The Architect's technical voice — proposes, justifies, breaks down.

**This is also an interview, not solo authoring.** Don't write BUILDPLAN.md in isolation and present it as a fait accompli. Drive each major decision (stack, framework, hosting, schema shape, breakdown structure) through `AskUserQuestion` by default — long descriptions, explicit pros/cons, a recommended option marked `(Recommended)` when the Architect has a clear preference. AskUserQuestion is the right primitive for build-plan dialogue because the choices are concrete and the operator benefits from seeing tradeoffs surfaced rather than having to extract them from prose. The operator can always add comments or pick "Other" to override.

**Encourage parallelization.** Bias architecture decisions toward shapes that *let downstream work proceed in parallel*. Independent modules, narrow interfaces between primitives, schema definitions that can ship ahead of the code that uses them — these reduce the depth of the dependency graph in §Tickets below, which is the single biggest lever on how fast the run actually finishes. When two architectural shapes are otherwise tied, prefer the one that lets more tickets run concurrently. Call out the parallelization angle explicitly in the relevant build-plan section so it's visible to the operator.

**End with an explicit confirmation gate.** Once the major decisions are settled and the breakdown is drafted, ask the operator: *"Happy with the overall build plan? Want to review it once more, or move to ticket creation?"* Iterate as long as they want — the cost of a wrong plan here is hours of misdirected delegator work downstream.

**BUILDPLAN.md shape:**

```markdown
# BUILDPLAN — <project name>

> Source spec: [SPEC.md](./SPEC.md)
> Architect: <agent id>
> Date: <YYYY-MM-DD>

## High-level technical decisions
- Stack: …
- Framework: …
- Hosting: …
- Key library choices: …

For each non-trivial choice, one or two sentences on *why* over alternatives.

## Architecture
Components, data flow, integration points. Mermaid diagram when it earns its keep.

## Per-screen functionality
(Only if the project has a UI.) One subsection per screen:
- **<Screen name>** — what it does, what state it owns, what it links to.
- Optional Mermaid layout diagram when layout itself is a design decision.

## Tickets
The work, broken into Lattice tickets the Orchestrator will dispatch delegators against. See "Ticket breakdown" below for shape. **Bias toward shapes that maximize parallelism** — see the parallelization note in the build-plan dialogue.

1. **<Ticket title>** (TT-1)
   - What's in it: 2–3 sentences.
   - Acceptance criteria it satisfies (from SPEC.md): #1, #3
   - Depends on: (other tickets) or "—"
2. **<Ticket title>** (TT-2)
   - …

## Field Assignments

Every persisted field — token rows, session state, artifact JSON, etc. — gets a row.
Empty `Writer` cell is a planning-blocker: assign before tickets mint, or surface as an unowned-writer flag to the operator.

| Field | Schema-owner ticket | Writer ticket | Reader tickets |
|---|---|---|---|
| <field-name> | <ticket-label> | <ticket-label> | <ticket-labels> |

**If any field's Writer cell is empty, that's a planning blocker** — assign the writer before ticket mint, or surface it as an unowned-writer flag. The `viewing_began_at`-shaped silent-UI-hole pattern from the Expanded Cinema v1.1 retrospective is the canonical failure mode this catches: PSY-43 read the field for the admin "in progress" status badge, PSY-40 declared the schema, but no ticket was assigned to write it — the badge silently never displays in production.

## Open questions / deferred decisions
Anything the build plan can't resolve and that needs to come back to the operator (or be answered during impl).
```

## Ticket breakdown

A ticket is a unit of work that can be delegated end-to-end (plan → impl → review → fix → PR) by a single delegator. Rules of thumb:

- **One ticket per testable user-visible behavior** when possible. Easier for the operator to review.
- **One ticket per architecturally distinct primitive** when the work is infrastructure-shaped. e.g., "schema definition" is its own ticket; "API endpoints using the schema" is another.
- **Declare dependencies, but conservatively.** A ticket depends on another only if it needs the other's *code or runtime artifact* to design or implement against — not just because the author wrote them in order. The Orchestrator's press-ahead discipline will spawn dependents against in-flight feature branches when the dependency is conceptually clear; loose dependencies kill parallelism. **Defaulting to fewer dependencies = more parallel work = faster run.**
- **Default ticket size: a half-day to a day of work.** Smaller fragments the operator's review attention; larger compounds the delegator's context burden.

## Phase 2 — Workflow Configuration

By the time Phase 2 starts, BUILDPLAN.md exists — which means the Architect can **auto-suggest defaults** for almost every config question instead of asking from scratch. Big project with 12 tickets → propose `N=5, Master Validator on, Result Validator on`. Tiny three-ticket cleanup → propose `N=2, Master Validator off, Result Validator off`. Present the suggestions, let the operator change anything; don't make them re-derive what BUILDPLAN.md already implies.

**This phase is also where the operator's overall / global comments belong.** Anything they want encoded into the run shape that doesn't fit the per-ticket SPEC.md acceptance criteria — coding style preferences, third-party libraries to avoid, time-of-day windows for risky operations, who to ping when blocked, etc. Make space for these; they'll get folded into `run-state.md` and the delegators will see them.

**Educate the operator about Phase 3 before exiting Phase 2.** A short summary of what the Orchestrator is about to do — how many delegators will be spawned, what panes will appear, how escalations will surface, what "done" looks like. Many operators are seeing this run shape for the first time; the few sentences of expectation-setting prevent surprises 20 minutes in.

Questions roughly in order, but skip the ones whose answers are obvious from BUILDPLAN.md:

1. **Autonomy level** — Fully Autonomous / Moderate / Minimal. Default: if the project's `CLAUDE.md` declares an autonomy default (e.g., `## Autonomy default — Fully Autonomous`), use that. Otherwise Moderate. (Level definitions are in SKILL.md.)
2. **Concurrent delegator cap (N)** — operator picks. Default 5; scale down for Minimal autonomy or low-trust first runs.
3. **C11 detection** — if `C11_SHELL_INTEGRATION=1`, ask about workspace layout preferences (existing workspace vs new), whether the Lattice Board browser pane should start now, sidebar status flag color.
4. **PR merge policy** — *Auto-merge* (Orchestrator squash-merges PRs at `pr_open` and lattice-completes the ticket, without operator review) vs *Leave at pr_open* (operator merges manually; ticket sits at `pr_open` until they do). Default: **Leave at pr_open** unless the project's `CLAUDE.md` declares an auto-merge default (e.g., `## PR merge policy — auto-merge through to done`). Auto-merge fits projects where the operator trusts the run end-to-end and would rather see `done` than a queue of pending PRs to hand-merge; the tradeoff is no human-in-the-loop gate before main moves. Either way, the orchestrator handles press-ahead branch ordering (parent first, then child rebases) — see `orchestrator.md` § "Auto-merge mode". Pin the chosen mode into `run-state.md` under `## Configuration` so the Orchestrator and any Captain it spawns operate consistently.
5. **Lattice ticket fidelity** — Verbose vs Minimal (see below).
6. **Master Validator** — On (default for runs > 3 tickets) or off.
7. **Closeout audit** — On (default) or off.
8. **Result Validator at Phase 4** — On (default) or off.

Anything else the operator wants encoded into the run shape goes here too — the question list isn't exhaustive.

### Ticket fidelity — Verbose vs Minimal

**Verbose** (good for high-stakes runs, unfamiliar projects, or when the operator wants to read tickets standalone):

```markdown
# TT-3 — Login screen

## Description
Implement the login screen per BUILDPLAN.md §Per-screen / Login. Handles email+password auth, "remember me," and error states.

## Acceptance criteria
- Email + password fields with inline validation.
- "Remember me" persists across sessions via secure cookie.
- Wrong credentials show inline error without losing typed email.
- Successful login redirects to /dashboard.

## Plan
(Filled in by delegator's plan phase.)

## Depends on
- TT-1 (auth API)
```

**Minimal** (good for high-trust runs where the operator already lives in BUILDPLAN.md):

```markdown
# TT-3 — Login screen
See [BUILDPLAN.md §Per-screen / Login](../BUILDPLAN.md#login). Satisfies SPEC.md acceptance #4. Depends on TT-1.
```

Both fidelities should reference SPEC.md acceptance criteria — the Result Validator uses those references to know which audit row applies.

## Handoff artifacts (end of Phase 2)

Before writing the Phase 2 artifacts, **finalize CLAUDE.md** (the Step 2 second pass): fill in tech-stack specifics, build / test / run commands, and any conventions that surfaced during BUILDPLAN.md. Then write these to disk **in this order**:

1. **Lattice tickets** — one per BUILDPLAN.md ticket entry, at chosen fidelity. Mint with:
   ```bash
   lattice create "<ticket-title>" --actor "agent:architect-phase2"
   # then link dependencies:
   lattice link <ticket-id> depends_on <other-ticket-id> --actor "agent:architect-phase2"
   ```
   Lattice requires either `--name` or `--actor` on every mutation command — without one, the call fails with `Either --name (session) or --actor (legacy) is required.` Architect-Phase-2 sets `--actor "agent:architect-phase2"` on every `lattice create` / `lattice link` call to keep the event log clean. Set it on every ticket and every dependency link, not just the first.

   **Title hygiene** — do **not** embed `TT-N` or other cross-reference labels in the ticket title. Lattice's dashboard renders the short ID (`<PROJECT_CODE>-<N>`) alongside the title, so a title like `"TT-1 Python project scaffold"` displays as `HOLO-1: TT-1 Python project scaffold` — redundant and noisy. Use the title for the descriptor only; cross-reference labels (TT-N) live in BUILDPLAN.md section anchors. If tickets were minted with the doubled prefix, `lattice update HOLO-N title="..." --actor agent:architect-phase2` fixes them in place.
2. **`.lattice/orchestration/run-state.md`** — autonomy, N, ticket list, validator flags, c11 prefs, **plus the project's `plan_review_mode` and `review_mode` read from `.lattice/config.json` and pinned for the run**. Pinning at Phase 2 keeps every wave's delegators on the same review modes; per-ticket overrides (e.g., `--mode triple` for a highest-risk ticket) are fine but require an entry in the decision log so wave-to-wave drift is visible rather than silent. (Schema in `references/orchestrator.md`.)

   **The ticket-list table also carries a `Workflow mode` column** — `fast-track` / `inline-full` / `sub-agent-full` per ticket, picked per the selection criteria in SKILL.md § "Workflow modes — per ticket". Default to **inline-full** for medium work (single Claude session + headless `lattice plan-review` + `lattice code-review` between phases — fresh-eyes value without the c11 PTY pressure of sub-agent spawns); use **fast-track** for clear-root-cause bug fixes / single-file changes / config tweaks where the implementer can plausibly catch their own bugs; reserve **sub-agent-full** for genuinely enormous tickets where no single context window can hold the work. Mixing modes within a wave is normal — a typical wave is 50–80% fast-track + inline-full with sub-agent-full as the occasional outlier. The Orchestrator reads this column to set its tick expectations (fast-track runs synchronously without `/loop`; the other two enter `/loop`).
3. **`.lattice/orchestration/agents.md`** — empty scaffold; Orchestrator populates as delegators spawn.
4. **`.lattice/orchestration/validation-plan.md`** — see below.

## Validation Plan template (load-bearing)

The Result Validator in Phase 4 walks this file row by row. **Schema matters here** — different Architects must produce the same shape so different Result Validators produce comparable Validation Reports.

```markdown
# Validation Plan

Source spec: [SPEC.md](../../SPEC.md)
Source build plan: [BUILDPLAN.md](../../BUILDPLAN.md)
Architect: <agent id>
Date: <YYYY-MM-DD>

| # | SPEC.md criterion | Verification method | Artifact to inspect | Pass condition | runnable_at |
|---|---|---|---|---|---|
| 1 | "Email + password fields with inline validation" (SPEC §Acceptance #4) | Read `src/screens/Login.tsx`; confirm inline-error component is wired to the email field's onBlur/onChange path | PR for TT-3 (Login screen) — `src/screens/Login.tsx` | Inline error component referenced from email field handler; no full-page reload code path | pre-merge-static |
| 2 | "Wrong credentials show inline error without losing typed email" (SPEC §Acceptance #4) | Open the login screen in Chrome, submit valid email + wrong password, confirm email persists in input | Merged login flow | Email value preserved in field after failed submit | post-merge-smoke |
| 3 | "Successful login redirects to /dashboard" (SPEC §Acceptance #4) | Submit valid creds in Chrome, observe redirect | Merged login + auth-API flow (TT-3 + TT-1) | URL changes to /dashboard within 1s of submit | post-merge-smoke |
| … | … | … | … | … | … |
```

**The `runnable_at` column has exactly two values:**

- **`pre-merge-static`** — Result Validator runs this in Phase 4 against the open PR(s): code inspection, schema-shape checks, file-existence checks, contract checks against the diff. Anything that can be answered from `gh pr diff` + reading source without a merged tree or a live browser.
- **`post-merge-smoke`** — requires a merged tree, multiple PRs cross-applied, or an operator-driven UI walkthrough. **The Operator runs these post-merge**; the Result Validator stubs them in the report.

The Result Validator walks **only `pre-merge-static` rows** and produces the audit report. `post-merge-smoke` rows are collected into a separate § "Operator smoke-pass checklist" that the operator runs after merge. **Mark each row honestly** — don't write a `pre-merge-static` row that secretly needs a merged tree; the Validator can't honor it and you've shipped a `PARTIAL-INSPECTION`-shaped failure into Phase 4.

**Rules:**

- **Every SPEC.md acceptance criterion gets at least one row.** If a criterion is too vague to verify, push back to the operator during Phase 1 — don't paper over it here.
- **Verification method is concrete and reproducible.** "Looks correct" is not a verification method.
- **Artifact column names the PR (or PRs) where the verification target lives.** Use ticket IDs at write-time; the Result Validator resolves them to PR URLs in Phase 4.
- **Pass condition is a single line, testable.** If you can't write one, the criterion isn't an acceptance criterion — it's a wish.

This file is the operator's contract with the run. **The Result Validator will not invent rows; what's here in Phase 2 is what gets audited in Phase 4.** Spend the time to write it well.

**The Architect drafts the validation plan; the operator reviews it.** Once the draft is on disk, surface it back to the operator with a quick read-through: "Here's the validation plan I've drafted — N rows covering M acceptance criteria. Want to walk through it, add rows, sharpen any verification methods, or accept as-is?" Default to accept-as-is if the operator doesn't push back. Validation plan review is part of Phase 2, not a Phase 4 surprise.

## When Phase 2 is done — handing off to Phase 3

All four artifact types on disk, operator has confirmed run-state.md and validation-plan.md. The Architect's last act is the handoff mechanic itself — concretely:

1. **Create the workspace layout** (inside c11 only — skip outside c11). The Architect builds the *geometry*; the Orchestrator will populate it with content on boot. Three new panes, each with a pane-layer title set via `c11 set-metadata --pane <ref> --key title --value "..."`:
   - **Main View Area** (left, full-height) — `c11 new-split right` from the Architect's pane to carve off the right half, then the Architect's original column becomes Main View Area. Title: `Main View Area`.
   - **Control Surface** (top-right) — `c11 new-split down` from the right pane to split it horizontally. The top becomes Control Surface. Title: `Control Surface`.
   - **Delegate View Area** (bottom-right) — the lower pane from that split. Title: `Delegate View Area`.

   Capture all three pane refs and write them to `.lattice/orchestration/run-state.md` under a new section:

   ```markdown
   ## Workspace panes (c11 refs)
   - main_view_area: pane:<N>
   - control_surface: pane:<N>
   - delegate_view_area: pane:<N>
   - workspace: workspace:<N>
   ```

   The Orchestrator reads these refs in Step 0 of its boot — without them, it has no way to know where to put the Lattice Board, the Master Validator, or the delegators.

2. **Append a handoff entry** to `.lattice/orchestration/run-state.md`: `<timestamp> — Architect → Orchestrator handoff initiated.`

3. **Spawn the Orchestrator** into the Main View Area pane (use the `main_view_area` ref from Step 1). The launch command is one-shot — a fresh `claude --dangerously-skip-permissions --model opus` invocation pointed at a boot prompt that:
   - Declares the role: *"You are the Orchestrator for this Lattice run."*
   - Tells it to load the Lattice Orchestrator Workflow skill (`lattice-orchestrator`) and read `references/orchestrator.md`.
   - Tells it to read SPEC.md, BUILDPLAN.md, run-state.md, and validation-plan.md before doing anything else.
   - Tells it to run **Workspace activation (Step 0)** from `references/orchestrator.md` before beginning the dispatch loop.
   - Hands off operator-channel responsibility.

4. **Step aside.** The Architect's session no longer drives anything. The operator's conversation is now with the Orchestrator pane.

The full boot-prompt template lives in `references/orchestrator.md` under "Boot prompt (Orchestrator pane)." The Architect doesn't need to invent it — read that section, plug in the project root + workspace + pane refs, and send.

**Outside c11**, skip Step 1 entirely. The role model still works without the spatial layout — the Orchestrator boots in whatever surface it gets, delegators run as background processes or separate terminal sessions, and the operator does more window-management work themselves. The Lattice Board is replaced by the operator running `lattice list` / `lattice show` directly.
