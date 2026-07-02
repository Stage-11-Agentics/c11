# Intake playbook (Phase 0 — Orchestrator)

Mechanics for turning a complete build contract into a dispatchable run. Assumes SKILL.md's Phase 0 overview.

## Identity

Declare the seat at invoke, per the c11 skill's orientation block: `c11 set-agent`, `rename-tab` to `Orchestrator`, `set-description` with the run's one-liner. Outside c11, state the role in the first message. (For every *spawned* agent, use the Identity Block in `orchestrator.md` — the env-var pitfalls it guards against apply to fresh surfaces, not to your own established session.)

## Contract checks

Run the checks listed in SKILL.md Phase 0. On any failure: name the gap, propose the remedy, let the operator route it — upstream to the contract's author (an amendment), or into the run as an early ticket (e.g., "split the test suite: `test` ≤60s hermetic + `test:full`"). Never quietly patch the contract yourself; the audit's independence depends on the builders not authoring their own contract.

## Install facts to pin (recorded in run-state § Configuration)

- **Status vocabulary / terminal pre-merge status.** From `.lattice/config.json` plus the project `CLAUDE.md`. Installs differ — some collapse `pr_open` into `review`, some end at `done`, some `shipped`. A delegator that blindly runs `lattice status <ID> pr_open` on the wrong install hits `Invalid transition` and thrashes or strands the ticket. Verify with `lattice show <ID> --json | jq .valid_transitions`; thread the pinned value into every boot prompt in place of any literal status.
- **Git remote name.** `git remote -v`. Record it once; every fetch, `code-review --base`, and push in every prompt uses it.
- **Cross-repo tickets.** Scan acceptance criteria for files outside this repo; a cross-repo ticket's delegator pushes and PRs *there* — say so in the ticket.
- **Fresh Lattice board?** If the project has no `.lattice/`, initialize with `lattice init --workflow classic --preset stage11 --no-setup-claude --no-setup-agents` (plus `--actor --project-code --project-name --model`). The `classic`+`stage11` pair gives the canonical lanes (`backlog, in_progress, review, in_validation, pr_open, done`); other presets lack lanes the dispatch loop drives or rename them decoratively.

## Config dialogue

Auto-suggest from plan size, ask only what the defaults don't settle: autonomy (project `CLAUDE.md` may declare `## Autonomy default`); N concurrent delegators (default 5); PR merge policy (default leave-at-terminal-pre-merge unless `CLAUDE.md` declares auto-merge; pin to run-state); per-ticket workflow mode (default inline-full for medium work; a typical wave is 50–80% fast-track + inline-full); Master Validator (default on >3 tickets); Result Validator (default on); auto-close finished surfaces (default on); c11 workspace preferences. Fold any operator global comments (style, libraries to avoid, time windows) into run-state. Close by describing Phase 1 concretely — panes, escalation banners, what "done" looks like.

## Minting tickets

One ticket per build-plan item:

```bash
lattice create "<title>" --actor "agent:orchestrator-intake"
lattice link <id> depends_on <other-id> --actor "agent:orchestrator-intake"
```

- Every mutation requires `--actor` (or `--name`) — creates *and* links; omitting it fails the call.
- No ticket IDs in titles — the dashboard already renders the ID, so embedded IDs display doubled. Fix strays with `lattice update <ID> title="..." --actor ...`.
- Dependencies conservative: link only when a ticket needs the other's code or runtime artifact. Loose dependencies kill parallelism.
- Preserve the BUILDPLAN's checkpoint-shaped order in the dependency structure; default ticket size half-day to a day.
- **Fidelity:** verbose (full description, acceptance criteria by ID, "Plan: filled in by delegator's plan phase", depends-on) or minimal (one line + BUILDPLAN anchor). Either way the ticket must reference its SPEC criteria IDs — the Result Validator maps audit rows through them.
- Unavoidable shared-file edits (from the BUILDPLAN) flagged in the affected tickets so dispatch serializes them.

## Validation plan (`.lattice/orchestration/validation-plan.md`)

`EVALUATION.md` re-expressed for the terminal audit. Schema is load-bearing:

```markdown
# Validation Plan
Source spec: [SPEC.md](../../SPEC.md) · Source evaluation: [EVALUATION.md](../../EVALUATION.md) · Date: <date>

| # | Criterion (ID) | Verification method | Artifact to inspect | Pass condition | runnable_at |
```

- `runnable_at` has exactly two values: **`pre-merge-static`** (answerable from `gh pr diff` + reading source — the Result Validator runs these) and **`post-merge-smoke`** (needs the merged tree, cross-applied PRs, or a human driving — the operator runs these after merge; the Validator lists them verbatim as the smoke checklist). Tag honestly: a static row that secretly needs a merged tree ships a partial-inspection failure into Phase 2. `felt` and `operator-assisted` criteria are smoke-side by construction; for `external-oracle` rows, name the oracle and who supplies it.
- Every criterion gets ≥1 row (a criterion too vague to row-ify goes back to the contract's author). Verification methods are concrete and reproducible — "looks correct" is not a method. Pass conditions are single-line and testable — if you can't write one, the row is a wish. The artifact column names the PR via ticket ID; the Validator resolves it.
- The Validator will not invent rows; what's written here is exactly what gets audited.
- Operator reviews the draft: row count, coverage, sharpen or accept (default accept-as-is).

## run-state.md (`.lattice/orchestration/run-state.md`)

```markdown
## Configuration
Autonomy · N · PR merge policy · Git remote (verified) · Terminal pre-merge status ·
Ticket fidelity · plan_review_mode / review_mode (from .lattice/config.json) ·
Master Validator · Result Validator · auto-close surfaces · c11 workspace ref

## Workspace panes (c11 refs)
main_view_area / control_surface / delegate_view_area_1..3 / workspace / lattice_dashboard_port

## Tickets in scope
| Ticket | Title | Status | Workflow mode | Branch base |

## Decision log (append-only)
- <date> [autonomy: <level>] <decision + one-line why>

## Run-time footguns
(rows added during dispatch — see orchestrator.md)
```

Branch base may be a parent feature branch for press-ahead children. Per-ticket review-mode overrides get a decision-log entry.

## agents.md (`.lattice/orchestration/agents.md`)

Active table, overwritten each tick (Lattice + `c11 tree` are ground truth): `| Role | Ticket | Surface ref | Pane ref | Branch | Worktree | Phase | Last seen | Spawned at |`. Below it, `### Archived (run history)` — append-only `| Actor | Ticket | Outcome | Notes |`, where notes carry merge SHA, LOC, test delta, and any anomaly + recovery. A populated archive turns the closeout audit from "read every transcript" into "scan the anomaly notes," and recurring anomalies feed the footgun catalog.

## Workspace geometry & dashboard (inside c11)

1. From your own pane: `c11 new-split right` (your column becomes the Main View Area), then on the right column `c11 new-split down` twice → Control Surface (top) + Delegate View panes. Title panes via `c11 set-metadata --pane <ref> --key title --value "..."`; write all refs to run-state. Mark operator-critical surfaces `--key protected --value true` (advisory).
2. Dashboard: pick a free port (`python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()'`), but verify with `lsof -nP -iTCP:<port> -sTCP:LISTEN` — never assume. Launch `nohup lattice dashboard --port $PORT > /tmp/lattice-dashboard-$PORT.log 2>&1 & disown` (never pipe through `head`/`tail` — SIGPIPE kills it). Wait `until curl -sf http://localhost:$PORT`, and tail the log for "Port X is already in use" before declaring success. Record the port in run-state.
3. Board surface: `c11 new-surface --type browser --url "http://localhost:$PORT" --pane <control-surface>` titled "Lattice Board".

Outside c11: skip geometry; the operator drives `lattice list` / `lattice show` instead of the board.

Then enter Phase 1 with `references/orchestrator.md` loaded.
