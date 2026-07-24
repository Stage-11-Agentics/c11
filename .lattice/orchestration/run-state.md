# Run: C11-175 Agent-Config Primitive v1 (model picker build)

**Started:** 2026-07-20
**Orchestrator:** agent:orchestrator-c11175 (Fable, surface:108 "Model Picker UX"→"Orchestrator", workspace:14)
**Contract:** docs/agent-config-primitive-design.md (§8 decisions locked) + docs/design-prototypes/model-picker/ (binding prototype, operator-approved) — committed @ 274ef671c

## Configuration
- Run profile: **max** (operator: "let's rumble"; CLAUDE.md declares none)
- Autonomy (resolved): Fully Autonomous — decide+log; escalate destructive/irreversible only
- N concurrent delegators: 5 (7 tickets; wave 1 = 3)
- PR merge policy (resolved): delegators self-merge behind the fails-open gate (fresh PASS review naming HEAD + `gh pr checks` green + validation artifact) — **EXCEPT C11-181/C11-182 (taste): hold at pr_open + needs_human, never self-merge**
- Git remote (verified): `origin` = github.com/Stage-11-Agentics/c11 (`upstream` = manaflow, NO-PUSH, never touch)
- Terminal pre-merge status: `pr_open` (needs `--role validation` artifact; `done` needs `--role review`)
- Status lanes: backlog → in_planning → planned → in_progress → review → in_validation → pr_open → done
- Ticket fidelity: verbose (descriptions carry design-doc § anchors as AC IDs)
- plan_review_mode triple / review_mode inline in config.json — delegators force `--mode single` + `LATTICE_SPAWN_BACKEND=headless`
- Master Validator: ON (spawn at wave 2) · Result Validator: ON · auto-close surfaces: on
- Discovered small work: absorb (max), recorded in ticket + PR body
- Test loop: `xcodebuild -project GhosttyTabs.xcodeproj -scheme c11-logic -configuration Debug -destination "platform=macOS" test -only-testing:c11LogicTests/<Class>` ONLY. Never the c11-unit/host scheme locally; UI behavior goes to CI. Workspace-constructing logic tests may crash the bare local runner (NSApp nil) — narrow to pure-logic classes, let CI cover the rest.
- Worktrees: `/Users/atin/Projects/Stage11/code/c11-worktrees/<slug>` — provision before first build: `git submodule update --init --recursive ghostty vendor/bonsplit` + `ln -s /Users/atin/Projects/Stage11/code/c11/GhosttyKit.xcframework GhosttyKit.xcframework`

## Workspace panes (c11 refs)
- Run workspace: workspace:15 "C11-175 Build" (window:1)
- Delegate pane A: pane:46 (cfg-store surface:145, stats-rail surface:147)
- Delegate pane B: pane:47 (sysprompt surface:146, Lattice Board surface:148)
- Lattice dashboard: http://localhost:63187 (log /tmp/lattice-dashboard-63187.log)
- Orchestrator: workspace:14 pane:35 surface:108 (this session)

## Tickets in scope
| Ticket | Title (short) | Status | Workflow mode | Branch base | Wave |
|---|---|---|---|---|---|
| C11-176 | Library store + models | backlog | inline-full | origin/main | 1 |
| C11-177 | System-prompt axis | backlog | inline-full | origin/main | 1 |
| C11-178 | Stats rail + recordLaunch | backlog | inline-full | origin/main | 1 |
| C11-179 | Composition overlay + effectiveDefault | backlog | inline-full | press-ahead off parents | 2 |
| C11-180 | c11 config CLI + socket | backlog | inline-full | origin/main post-deps | 2 |
| C11-181 | A-button popover (TASTE-HOLD) | backlog | inline-full | origin/main post-C11-179 | 3 |
| C11-182 | Settings editor + stats view (TASTE-HOLD) | backlog | inline-full | origin/main post-C11-179 | 3 |

## Decision log (append-only)
- 2026-07-20 [fully-autonomous] Profile max: operator explicit go; taste tickets carved to needs_human per skill invariant.
- 2026-07-20 [fully-autonomous] Tier-1 picker = custom popover anchored to A button, NOT bonsplit contextMenu enrichment (prototype README §4.1); removes vendor/bonsplit from v1 scope. Overrides design doc §7 bonsplit row for v1.
- 2026-07-20 [fully-autonomous] §9 v1 split into 7 tickets; 3 independent wave-1 roots for parallelism.
- 2026-07-20 [fully-autonomous] Prior T&S run's orchestration files archived to archive/2026-07-truth-and-stability/.

## Run-time footguns
(rows added during dispatch)
