# Astra audit: the whole c11 1.0 plan

Atin asked for an independent audit of the entire c11 1.0 run plan before build mode starts. You are GPT-6-Astra. You are **read-only**: do not edit plans, tickets, code or any worktree; do not commit, push or comment on tickets; do not message owners. Your only outputs are one report file and one message to the Orchestrator.

## Setup
- `c11 rename-tab --tab "$C11_TAB_ID" "Plan Audit Astra"`; `c11 set-description --tab "$C11_TAB_ID" $'Auditing the whole c11 1.0 plan before build mode; next, write the report.\nLineage: c11 1.0 Orchestrator → Plan Audit Astra'`.
- `export LATTICE_ROOT=/Users/atin/Projects/Stage11/code/c11`. Read the board with `lattice list --tag c11-1.0 --json`, `lattice show <ticket>`, and the plan files `/Users/atin/Projects/Stage11/code/c11/.lattice/plans/<task_id>.md`.
- Code: read origin/main `0ff8887e5e` through any `c11-1.0-*` worktree under `/Users/atin/Projects/Stage11/code/c11-worktrees/` (read-only) or `git show origin/main:<path>`. Never touch the main checkout's working tree. No builds or tests (this Mac is Hyperion; no heavy work).

## Inputs
- Run brief: `/Users/atin/Projects/Stage11/code/c11/upstream-triage/c11-1.0/ORCHESTRATOR-PROMPT.md` (waves, gates, hard rules, model routing).
- Rulings: `README.md`, `BACKLOG.md`, `c11-1.0.html` in that folder. **Rulings are final; do not argue them.** Audit the plan's fidelity to them.
- Run state: `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/run-state.md` (seats, routing, decisions so far).
- Doctrine and guardrails: `CLAUDE.md`, `PHILOSOPHY.md`, `docs/aar-c11-188-attention-loop.md`.
- The journal contract: C11-272 spec (reviewed and attested) and the C11-273 plan.
- Some P2 and release plans (C11-267, 268, 285, 286, 289, 291, 292, 293, 311) may still be in progress; audit what exists and list the rest as not yet planned. C11-271 is in review repair.

## What to audit (the whole, not each ticket again)
1. **Coverage:** every BACKLOG item and ruling maps to a ticket and plan; nothing ruled out has crept in; nothing ruled in is missing or silently narrowed. Call out every place a plan narrowed scope (e.g. C11-275 notify-only, C11-295 bounded lock only) and whether that is honest and within the ruling.
2. **Cross-ticket seams and conflicts:** shared files and contracts (`CLI/c11.swift`, `SocketDispatch`, `Resources/bin/claude`, `TerminalController`, `ContentView`/sidebar, `Workspace`/`WorkspaceManager`, session persistence, Ghostty submodule, skills). Where two plans edit the same seam or define overlapping contracts (journal vs attention vs feed vs agents --json; C11-263 vs C11-264/265; C11-306 vs C11-274; C11-294 vs C11-295/302; C11-259/260 vs C11-301; C11-281/267 vs C11-257), name the conflict and the landing order that avoids it.
3. **Dependency order and the critical path:** compute a dependency-ordered landing sequence and the critical path to the sign-off build. Flag any plan that implements before its dependency merges, and any missing dependency edge on the board.
4. **Wave gates:** can wave 1's gate (baseline published, fixtures replay, Ghostty CI green) and wave 2's gate (one build shows bypass questions, completions and flags correctly and jumps to the right tab; groups at 50+ workspaces) actually be met by these plans? What evidence is planned for each?
5. **Guardrails:** C11-188 (acceptance tied to incidents/fixtures/analytics questions; no absolute fail-closed language; proportionate mechanism), doctrine (no tenant config writes; C11-278 the only amendment), hot paths, localization, disclosure (public repo), validation on Atlas tagged builds with computer use.
6. **Speed:** Atin wants close to overnight. Where is the plan slow or serialized for no reason; which tickets can run in parallel safely; what would you cut or re-order (P2 first) to protect the release.
7. **Top risks:** the five things most likely to stall or break the release, each with the cheapest mitigation.

Every finding names its evidence (ticket, plan section, file:line). No theoretical crash-window hunting.

## Output
Write `/Users/atin/Projects/Stage11/code/c11/upstream-triage/c11-1.0/plan-audit-astra.md`: verdict (ready for build mode / ready with fixes / not ready); a numbered list of findings split into **Must fix before build mode**, **Fix during the run**, and **Notes**, each with evidence and the smallest fix and the owner seat it belongs to; the landing sequence and critical path; the top-risk list. Keep it tight: Atin reads it.

Then send exactly one line and stop:
`c11 send --workspace 8D68EE13-823E-44FF-B2DE-611FFD7BDA7F --tab E588D406-2E13-4581-A349-4EB46BA26639 "AUDIT c11-1.0 <verdict> MUST <n> DURING <n> REPORT upstream-triage/c11-1.0/plan-audit-astra.md"`
No Claude subagents.
