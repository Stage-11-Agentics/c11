# Run state — Exact-session resume (opencode / pi / omp)

**Started:** 2026-06-28
**Architect:** agent:exr-architect (surface "EXR Architect", workspace:9)
**Operator:** atin
**Follows:** PR #271 (agent registry + pi/omp/opencode first-class with best-effort resume), merged to main at `5e5c9a3ec`.

## Configuration

| Setting | Value |
|---|---|
| Autonomy level | **Fully Autonomous** |
| Concurrent delegator cap (N) | 2 |
| PR merge policy | **Auto-merge through to done** (squash-merge each PR once its pipeline passes; no human gate) |
| Auto-close finished delegator surfaces | Yes |
| Master Validator | On (audits global build/test/PR state in-flight) |
| Result Validator | On (Phase 4 audits each acceptance criterion) |
| Ticket fidelity | Verbose (sensitive resume-path code; full acceptance criteria in each ticket) |
| C11 detection | yes (`CMUX_SHELL_INTEGRATION=1`); use `c11 state verify` as the resume oracle + the embedded browser / tagged builds for live validation |

## SPEC + BUILDPLAN source

Phase 1 collapsed — the artifacts already exist:

- **SPEC + BUILDPLAN:** `docs/agent-exact-resume-plan.md` (committed to main at `a1e9100c7`) — the architectural finding, per-agent verified facts (formats, flags, the opencode base62 id grammar + the WIP regex bug), and the phased plan.
- **Project agent doc:** `CLAUDE.md` (root) — build/test policy, c11 testing rules, submodule discipline.
- **Reference implementation to mirror:** `Sources/Conversation/Strategies/Codex.swift` (scrape-primary + ambiguity policy), `Sources/Conversation/Scrapers/ClaudeCodeScraper.swift`, the opencode WIP on branch `feat/opencode-resume` (port + FIX its base62 regex bug).

## Tickets + wave table

| Ticket | Title | Wave | Mode | Depends on | Notes |
|---|---|---|---|---|---|
| **C11-151** | opencode exact-resume via plugin rail (Phase A) | 1 | inline-full | — | Independent. ~5 files (keys, store validator, strategy, scraper, plugin JS). |
| **C11-152** | Live scrape-capture pipeline (Phase B foundation) | 1 | inline-full | — | Architectural; **blocks** C11-153 + C11-154. Benefits codex too. |
| **C11-153** | pi exact-resume (PiScraper + PiStrategy) | 2 | inline-full | C11-152 | Press-ahead off C11-152's branch once it hits review. |
| **C11-154** | omp exact-resume (OmpScraper + OmpStrategy) | 2 | inline-full | C11-152 | Press-ahead off C11-152's branch once it hits review. |

**Mode = inline-full for all:** single delegator session per ticket + headless `lattice plan-review` and `lattice code-review` between phases. Real design surface (the live resume path) but each ticket fits in one head; fresh-eyes review is where the value is, not extra c11 tabs.

## Dispatch shape

- Wave 1: dispatch C11-151 + C11-152 in parallel (N=2).
- Wave 2: when C11-152 reaches `review`/`pr_open`, branch C11-153 and C11-154 worktrees off its feature branch (press-ahead) and dispatch (cap permitting, as Wave-1 tickets free slots).
- Every ticket: golden + new unit tests via `c11-logic` (safe local), and a **live snapshot/restore check** for the agent it touches — `c11 state verify` is the dry-run oracle; then a real quit/relaunch in a tagged build. The resume path is where a silent bug strands an operator's session, so the `--role validation` artifact must show an actual resume, not just green units.

## Hard constraints (from CLAUDE.md — carry into every delegator)

- Never run `xcodebuild ... test` on the host scheme locally (launches an untagged DEV.app, crashes the operator's c11). Use `c11-logic` for logic tests; `scripts/test-unit-local.sh` for host-required.
- New Swift files → pbxproj membership via the `xcodeproj` gem; gate on `xcodebuild -list` + ref counts, not the line diff.
- Skill edits → `scripts/sync-installed-skills.sh`.
- The golden test `AgentManifestTests` enforces `hasConversationStrategy` matches `StrategyRegistry.v1` — flip the manifest flag in the same commit as registering a strategy.

## Decisions log (Fully Autonomous — Orchestrator appends)

- (none yet)
