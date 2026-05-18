# Run state — C11-99 CI restoration program

**Started:** 2026-05-18
**Architect:** agent:claude-opus-4-7 (this session, surface "CI fix orch")
**Operator:** atin

## Configuration

| Setting | Value |
|---|---|
| Autonomy level | **Fully Autonomous** |
| Concurrent delegator cap (N) | 2 |
| Master Validator | off (small run, two streams only) |
| Result Validator | on (Phase 4 audits per-area acceptance criteria) |
| Ticket fidelity | n/a — C11-99 already exists at high fidelity; not re-split |
| C11 detection | yes (`C11_SHELL_INTEGRATION=1`); use embedded browser for any web verification |

## SPEC + BUILDPLAN sources

Phase 1 collapsed — the existing artifacts already serve as SPEC + BUILDPLAN:

- **SPEC** (the WHAT + per-area acceptance criteria): C11-99 ticket description (`lattice show C11-99`)
- **BUILDPLAN** (the HOW + audit context): `notes/build-test-pipeline-audit-2026-05-18.md` — committed at `3246d82bf`

## Lattice ticket

**C11-99** (`task_01KRYCK37SSZJK2S6CN123KVKG`) — single ticket, four work areas. Not re-split into siblings; both delegators update C11-99 with `lattice attach` notes per area and the ticket completes when all four areas have open PRs.

## Delegator map

### Delegator 1 — A+B+D infra pass (`delegator:abd-infra`)

**Scope:** sequential A → B → D, three PRs from the same worktree.

| Area | Order | Effort | Files |
|---|---|---|---|
| A — CI unblock | 1st (highest leverage, ships in hours) | hours | `.github/workflows/{nightly,ci}.yml`, `c11Tests/AppDelegateShortcutRoutingTests.swift` |
| B — Local runnability | 2nd | ~1 day | `Sources/SocketControlSettings.swift`, `c11-unit.xcscheme`, new `scripts/test-unit-local.sh`, `code/c11/CLAUDE.md` |
| D — Workflow hygiene | 3rd | small | `.github/workflows/update-homebrew.yml` (timeout), **delete** `.github/workflows/{claude,test-e2e}.yml`, `scripts/{sparkle_generate_appcast,bump-version}.sh`, `code/c11/CLAUDE.md` ghostty remote name |

**Worktree:** `code/c11-worktrees/c11-99-abd` (branch `c11-99-abd`).

**Pre-decided choices** (under Fully Autonomous):
- Area D claude.yml + test-e2e.yml → **delete both**. Neither has ever served value (claude.yml never invoked; test-e2e.yml's last 3 dispatches failed against a renamed scheme).
- Area D sparkle defaults → flip to `Stage-11-Agentics/c11` (no env var requirement; just safer default).
- Area D bump-version Sparkle floor → hard-fail when invoked for a release tag and curl returns 0 bytes.

### Delegator 2 — C stabilization (`delegator:c-stab`)

**Scope:** diagnose + fix 32 `XCTestExpectation` 1s-timeout failures + the 104s slow test. Multi-day. Independent worktree.

**Worktree:** `code/c11-worktrees/c11-99-c` (branch `c11-99-c`).

**Exit criteria:**
- `c11-unit` step green on main for 5+ consecutive runs
- Flip Area A's `continue-on-error: true` back to hard-fail (cross-worktree coordination at the end — final small PR)
- Quarantined slow test (skipped by Area A) re-enabled

**Iteration accelerator:** Area B's `scripts/test-unit-local.sh` lets this delegator iterate locally without stomping the operator's c11. Delegator 2 starts immediately but its iteration loop speeds up once B lands.

## Parallel-execution dependency map

```
Delegator 1 (A → B → D)         ── 3 PRs sequenced
Delegator 2 (C)                 ── 1+ PR, parallel with D1
                                    │
                                    └── final small PR (flip A flag) once C green
```

Operator's primary review attention: 3 PRs from D1, 1+ from D2.

## Out of scope

- Adding explicit `ARCHS="arm64 x86_64"` to `release.yml`. Confirmed in audit — DMG already universal.
- Rewriting the "self-referential" Homebrew SHA gate. Validates heredoc substitution correctness, which is what's needed.
- Touching `cmux.sparkle.automaticChecksMigration.v2` UserDefaults key. Requires a `cmux.` → `c11.` migration path; carry forward as a separate cycle.

## Run log

(populated by Orchestrator as events fire — first entry on dispatch)
