# c11 1.0: handoff from prep to the orchestrator

Written 2026-10-01 ~20:30 PDT by "c11 1.0 Prep" (Opus, Hyperion workspace:11, tab:139). Read with `upstream-triage/c11-1.0/ORCHESTRATOR-PROMPT.md` (the run brief) and `run-state.md` (this folder). Plans live on each ticket (`lattice show <ticket>`; `.lattice/plans/<task_id>.md`).

## State in one paragraph
Final prep sweep 20261001 20:55 local: 57 `c11-1.0` tickets (56 + C11-312 artifact-only signing). 55 planned, C11-271 is PR #495 with review PASS at 27ebd596 (status still `in_planning`; move it when it lands), C11-310 folded into C11-270. No needs-human flags, no unassigned tickets, no missing plans, no dependency cycles. All seven audit must-fixes verified in the stored plans. All 14 seats on standby except **atlas, which is implementing C11-216 now on Atin's go (build mode for that ticket only)**. Atin's go for the orchestrator means full build mode for everything. Atin approved two concurrent c11 builds on Atlas (concurrency test results: see run-state). Plan and lanes: `upstream-triage/c11-1.0/BUILD-FLOW.md`.

## Seats (Hyperion c11, workspace:11 "c11 1.0", area:29, all suppressed, report to the orchestrator mailbox)
Mailbox in every brief is **tab:139** (`E588D406-2E13-4581-A349-4EB46BA26639`). When the new orchestrator takes over, send each seat one line naming its new mailbox (workspace + tab UUID), or keep tab:139 as a relay.

| Seat | Tab | Harness | Tickets |
|---|---|---|---|
| atlas | 191 | Codex | 216, 312, 292, 293 |
| journal | 143 | Astra xhigh | 272 (spec, reviewed + attested), 273 |
| groups | 144 | Astra | 259, 260 |
| fixtures | 200 | Codex | 271 (draft PR #495, review PASS at 27ebd596; lands in build mode), 263 |
| soak | 192 | Codex | 270 (+310) |
| cli | 202 | Codex | 284 first, then 279, 283, 280, 282, 281, 308, 309, 285, 286 |
| launch | 196 | Codex | 258, 269, 306, 305, 311 |
| history | 197 | Codex | 262, 261, 231, 277, 291 |
| browser | 193 | Codex | 287, 288, 290, 307, 304, 289 |
| ghostty | 157 | Astra | 294 |
| hangs | 158 | Astra | 295, 296, 302, 303, 301 |
| crashes | 159 | Astra | 297, 299, 298, 300 (+ B075 note on 311) |
| producers | 194 | Codex | 274, 275, 276, 278 |
| feed | 195 | Codex | 264, 265, 266, 267, 268 |

Briefs: `briefs/owner-common.md` + `briefs/<seat>.md`; reviewers `briefs/reviewer-common.md` + `briefs/review-*.md`.

## Decisions on record (all Atin unless noted)
- **Codex everywhere (Atin, 2026-10-01 ~20:45):** favor Codex over Grok; Codex plan upgraded and resets tomorrow morning, so treat Codex capacity as unlimited. Astra (`gpt-6-astra`) owns the deep tickets (272, 273, 259, 260, 294, 295-303 cluster); all other owners are Codex `gpt-6.1-sol` high (all former Grok seats now Codex). Reviews cross models within Codex: Sol-owned work reviewed by Astra, Astra-owned work reviewed by `gpt-6.1-sol` Grok reviews are allowed too (Atin). **One Fable review is allowed on larger items where it earns its place** (Atin, 2026-10-01): e.g. the journal store C11-273, workspace groups C11-259/260, the Ghostty patch set C11-294, and the integrated sign-off candidate; Claude Code `--model fable --effort high`, read-only, no Fable subagents, counts as one of the three review cycles. Don't manage usage; handle limits when hit.
- On Prime boxes use `--agent codex --model gpt-6-sol` or `gpt-6.1-sol` (proven); `gpt-5.6-luna` failed 401 at TUI bootstrap on a box.
- C11-216 notarization: option A (Atlas does Debug/test/Release compile; signing + notarizing stays in GitHub Actions). Audit must-fix 7 adds an artifact-only signing workflow so Atin approves exact signed bytes before publish.
- C11-270 soak: subscription auth on Atlas, 3h baseline (M1) + 10h overnight candidate (M2) + 2.5h constrained. Dependents gate on M1, not ticket completion (board uses related_to; comment on C11-270).
- C11-275: Codex stays on notify (trust-isolation probe failed on 0.159.3, within ruling D2).
- C11-295: bounded lock acquisition only; full off-main native formatting is a 1.0 residual (C11-294 SEAM no).
- C11-271: captures from production c11 (run brief); app-restart and Codex child-completion are tagged-build recapture gaps. Never restart Hyperion's production c11.
- **Review budget (Atin, 2026-10-01, supersedes the brief's hard 3):** three rounds normally; if still blocking after three and clearly converging (finding set shrinking, nothing recurring, no new mechanism), up to two more rounds with a fresh reviewer (clean context, different family where possible); stop and escalate at five or on divergence. Now in `lattice-orchestrator-v2` invariant 7 and `lattice-hosted-orchestrator` (overwatch `8341bf8`, live on Hyperion and Atlas).

## Board edges added by prep (audit finding 5)
281, 267, 297 → depend on C11-257 (send/mailbox file barrier). 273 → 263. 278 → 274, 275, 276. 292 → every P0/P1 ticket (47 edges). 259-262, 294, 295, 302, 303: `depends_on C11-270` replaced with `related_to` (M1 gate).

## Readiness checks (prep, 2026-10-01 evening)
**Atlas** (`ssh atlas`, user `atinwoodard`):
- Xcode 26.6 selected globally; **c11 needs Xcode 26.3** (`/Applications/Xcode-26.3.app`, via `DEVELOPER_DIR`) with Zig 0.15.2. 26.6 failed Zig bootstrap. Prep's unsigned no-launch Debug build succeeded on 26.3. C11-216 must pin this.
- Checkout `~/Projects/Stage11/code/c11` clean at origin/main `0ff8887e5e`; GhosttyKit `26c3e499` linked; `scripts/with-build-lock.sh` present. Load ~3-5, 263 GiB free.
- c11 0.67.0 running (one workspace, four terminals). Non-interactive `ssh atlas cmd` has no `/opt/homebrew/bin` on PATH: use `zsh -lic '…'` or full paths (`/opt/homebrew/bin/c11`, `gh`).
- Codex 0.159.3 and Grok 1.0.46 logged in (personal). Claude Code 2.1.284 present; which call-sign it bills on Atlas was not confirmed (matters for the subscription soak).
- **`gh` on Atlas is logged out** (token invalid). Needed only if something on Atlas uses gh (Merge Captain, release scripts run there). Fix: Atin runs `gh auth login` on Atlas.

**Prime boxes** (Overwatch launcher on Atlas, `code/overwatch`, `launcher/seat.sh`, `DISPATCH.md`):
- GitHub App installed on `Stage-11-Agentics/c11` (reviewer token minted OK).
- Added profile `c11` (overwatch `da491db`: forge github, allow github hosts + PyPI; no `.lattice`, so seats are Lattice-blind: pass `--lattice none`).
- **Grok seat on c11: works end to end** (clone at main, `gh api` as the App, repo read). Probe box deleted.
- **Codex seat on c11: works end to end** with `gpt-6-sol` (clone at main, `gh api` as the App). A first probe with `gpt-5.6-luna` failed 401 at TUI bootstrap; the seat login itself is healthy on Atlas. Probe boxes deleted.
- Fit: boxes are Linux. They cannot build or run c11 (macOS app). Good uses: Codex/Grok **reviewers** (read-only diff review; voice is the PR, and c11 PRs are public, so review text is public), Python soak-harness unit tests, doc/skill-only tickets. Default seat kind is Claude: always pass `--agent grok|codex` (no Claude workers this run). Mirror box verdicts into Lattice yourself (boxes are Lattice-blind).

## Open before the go
1. Remaining audit amendments: confirm PLANNED re-stores from atlas (216/292/293), producers (274/278), history (231/277/291/261), feed (265/266), soak (270), cli (284 order, 282, 281), browser (307/288/290). Re-run Astra's audit on the deltas only if you want a second pass (one cycle).
2. C11-271 delta re-review verdict (tab:187).
3. Atlas `gh` login (Atin, only if something on Atlas will use gh).
4. Atin's explicit go → C11-216 first (build from a real isolated delegator worktree), launch the Merge Captain, then wave 1.

## Placement (Atin, 2026-10-01)
Keep the whole run inside Hyperion's workspace:11 ("c11 1.0"): the orchestrator, Merge Captain, every owner, reviewer, auditor and validator. Launch with `--workspace workspace:11` (or no placement flag from inside it); never `--new-workspace`. Split new areas inside workspace:11 when area:29 gets crowded. Exceptions by necessity only: builds run on Atlas over ssh (no surfaces), computer-use validation runs in Atlas's own c11 against tagged builds, and Prime seats' hosting surfaces are created by the launcher in Atlas's c11 (prefer local seats; use boxes only when it clearly helps).

## Grok hang (observed 2026-10-01, CLI seat)
Grok 1.0.46 can hang on a single inference request with no first token, no error and no retry logged (CLI seat: request at 03:26:24Z, nothing for 4+ min, after TTFT climbed to 17-47 s on a ~110k-token context). Fleet-wide Grok p90 TTFT was 5-9 s with 34-110 s maxima per 10-minute window while ~9 Grok sessions ran. If any Grok agent (e.g. a reviewer) shows "Waiting for response" for 3+ minutes, press Esc (or Ctrl+C) in its tab and re-send the last instruction; replace the agent only if that fails. Evidence: `~/.grok/sessions/<cwd>/<session>/events.jsonl`, `~/.grok/logs/unified.jsonl` (`shell.turn.inference_done` carries `ttft_ms`).

## Launch rule
Always launch seats with a one-line `--prompt "Read <brief file> and follow it exactly."`. Put every specific in the brief file. A long inline prompt (~1 KB with parentheses/semicolons) left the first Codex CLI seat (tab:201) dead on arrival with no session; same class as C11-258.
Now in the skills: c11 `skills/c11/references/orchestration.md` (PR #496, docs-only, installed copy already synced on Hyperion; land it early via the Merge Captain, then `scripts/sync-installed-skills.sh c11`), `lattice-orchestrator-v2` delivery.md and `lattice-hosted-orchestrator` (overwatch `2a84a3a`, live on Hyperion and Atlas).

## Restart recovery (only if c11 or the Mac restarts; Atin cancelled the planned pre-launch restart, so seats stay alive)
All seat sessions end on restart. Nothing durable is lost: plans are on the tickets (`.lattice/plans/`), worktrees and their local commits are on disk (`~/Projects/Stage11/code/c11-worktrees/c11-1.0-<seat>`), briefs are in `briefs/`. A board backup is at `~/Projects/Stage11/code/c11-1.0-board-backup-20261001-2055.tgz` (taken before restart; refresh it right before restarting). After restart the orchestrator relaunches each seat **in workspace:11** with a one-line prompt:

`c11 launch-agent --type codex --model <model> --effort <effort> --area <area> --cwd <worktree> --title "<title>" --task <first ticket> --suppressed --prompt "Read <abs>/briefs/resume-after-restart.md and follow it exactly. Seat brief: <abs>/briefs/<seat>.md. Orchestrator mailbox: workspace <uuid> tab <uuid>."`

| Seat | Model / effort | Title | First ticket |
|---|---|---|---|
| atlas | gpt-6.1-sol / high | Atlas Builds Codex | C11-216 |
| journal | gpt-6-astra / xhigh | Journal Spec Astra | C11-273 |
| groups | gpt-6-astra / high | Groups Model Astra | C11-259 |
| fixtures | gpt-6.1-sol / high | Fixtures Attention Codex | C11-263 |
| soak | gpt-6.1-sol / high | Soak Harness Codex | C11-270 |
| cli | gpt-6.1-sol / high | CLI Batch Codex | C11-284 |
| launch | gpt-6.1-sol / high | Launch Hygiene Codex | C11-258 |
| history | gpt-6.1-sol / high | Focus History Codex | C11-262 |
| browser | gpt-6.1-sol / high | Browser SSH Codex | C11-287 |
| ghostty | gpt-6-astra / high | Ghostty Patch Astra | C11-294 |
| hangs | gpt-6-astra / high | Hangs Main Astra | C11-295 |
| crashes | gpt-6-astra / high | Restore Crashes Astra | C11-297 |
| producers | gpt-6.1-sol / high | Journal Producers Codex | C11-274 |
| feed | gpt-6.1-sol / high | Feed Codex | C11-264 |

Relaunch seats just in time (when their ticket is admitted), not all fourteen at boot: the finish-first caps (2-3 owners implementing) mean most seats would only idle. Launch the Merge Captain before the first owner.

## Fresh owners, just in time (Atin, 2026-10-01)
The 13 standby planning seats were closed to start build mode with fresh context; only **atlas (tab:191)** stays alive, implementing C11-216. When a ticket is admitted, launch a **fresh owner** for it with the "Restart recovery" recipe above (one-line prompt to `briefs/resume-after-restart.md` plus the seat brief and your mailbox; model/effort/title from that table). Everything durable is on disk:
- plans on every ticket (`.lattice/plans/`), owners already assigned per seat actor (`agent:codex-<seat>`; Astra seats keep their brief actors);
- worktrees `~/Projects/Stage11/code/c11-worktrees/c11-1.0-<seat>` with local, unpushed commits: soak (`c11-1.0/C11-270-fleet-soak`, 6 ahead incl. WIP docs `37aa6477e8`), journal (`c11-1.0/C11-272-journal-spec`, WIP spec/plan docs `d96527cce1`), browser (`c11-1.0/C11-290-ssh-api` at `c2a7f7c876`, API doc fix), fixtures (`c11-1.0/C11-271-lifecycle-fixtures` = PR #495 head);
- per-ticket branches already exist in some worktrees (e.g. hangs: 296, 301, 302, 303); fresh owners create the rest from origin/main.
Seat rows in the tables above now mean "lane", not a live tab.
