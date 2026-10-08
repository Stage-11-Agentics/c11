# Run State: markdown viewer build (C11-336, C11-357)

## Objective
C11-336 (markdown panel on WKWebView) then C11-357 (linked-doc navigation) merged to `main` on GitHub `Stage-11-Agentics/c11`, validated by a fresh-context computer-use validator on an Atlas tagged build (screenshots), and completed in Lattice. Brief: `~/Library/Application Support/c11/runtime/launch-prompts/11951-…/D31824A0-….txt` (from md-viewer-scoping). Merge reviewed, validated, CI-green PRs; **never cut a release, tag, or touch Sparkle/appcast**.

## Configuration
- Repo `/Users/atin/Projects/Stage11/code/c11`; remote `origin` = github.com/Stage-11-Agentics/c11; default `main`. Base at intake: origin/main `da8205bc9e`. Main checkout holds other agents' `.lattice/` state: never reset/stash/commit it wholesale.
- Board: local `.lattice/`; `LATTICE_ROOT=/Users/atin/Projects/Stage11/code/c11`. Orchestrator actor `agent:claude-md-orchestrator`.
- Contract: `docs/markdown-viewer-design.md` (binding), visual `docs/design-prototypes/markdown-viewer/reader/index.html` r4, 357 ref `navigator/index.html` r1.
- Orchestrator: Claude Opus, panel:97 (`$C11_PANEL_ID`), workspace `8D68EE13-…`; mailbox `md-viewer-orchestrator`. Report channel: Lattice comment on C11-336 + `c11 mailbox send --to md-viewer-scoping`.
- Fleet workspace: workspace:16 "md viewer build". area:43: R1 panel:101, R2 panel:102, Captain panel:103. area:46: R3 panel:108, R4 panel:109 (pre-warm).
- Models: Codex seats on `gpt-6-luna` max (Atin, 2026-10-08 02:15: "we want to be using Luna"; fast tier is fine per seat, but the global Codex default must not be fast). Running seats switched in place via /model (standard tier, context kept); new Codex seats launch with saved config "Luna Fast Max" (per-process `-c service_tier=priority`, never persisted). After any /model switch, restore `model`/`model_reasoning_effort` in ~/.codex/config.toml (Enter in the menu writes the global default; "s session" does not respond to typed input). Review 1 Claude Opus (cross-family), Review 2 Grok `grok-4.7`. R2 (C11-359) large-ticket track: Fable + Astra parallel discovery, Opus synthesis/verify, post-merge review. Merge Captain Codex (Luna max); fallback: Orchestrator lands after the same exact-head checks.
- Caps: owners ≤ 4 active (6 tickets, mostly serial); 1 reviewer per ticket; 1 captain; 1 landing candidate. Queue alarms 15/30/60 min.
- Builds/tests: Atlas via `scripts/remote-build.sh --tag md-<n>`; Hyperion inner loop only. Computer use on Atlas tagged builds only.
- Gate: PR CI is Ubuntu-only (workflow guards, remote-daemon, web typecheck); macOS build/logic/host tests run only post-merge on main (`ci-hourly.yml` "CI main (macOS)"). So any Swift/pbxproj PR also needs the captain's **Atlas exact-head gate** before merge: `scripts/remote-build.sh --tag mc-<n>` (Debug compile) + `--mode test -- -only-testing:c11LogicTests -skip-testing:c11LogicTests/SocketControlPasswordStoreTests` + the ticket's named slice. Watch the post-merge macOS backstop; red → fix forward at once. `ci-macos-compat.yml` fails on main with no jobs (pre-existing): non-blocking.
- Skill sync: Merge Captain only, from merged main.
- Watchdog: Atlas cron `~/md-viewer-run/watchdog.sh` every 10 min, Telegram DM to Atin when `~/md-viewer-run/heartbeat` is 30+ min stale while `~/md-viewer-run/armed` exists. Orchestrator heartbeat touches it. Test send 200 OK. Disarm at closeout: `rm ~/md-viewer-run/armed` + remove cron line.

## Capacity (glideslope 2026-10-08 01:50 PDT)
Codex weekly 0% (resets Wed Oct 14). Claude Alpha 60% (◆60.6), Fable 13%; resets Sat Oct 10. Grok 0%.

## Pathfind (done by Orchestrator, no separate seat)
| Assumption | Check | Result |
|---|---|---|
| Atlas reachable, room | ssh uptime/df | load 3.6, 142 GB free |
| Capacity | glideslope | ample (above) |
| CI on main | gh run list | ci.yml green; compat workflow broken pre-run (non-blocking) |
| Sol config exists | c11 config list | "Sol High" codex gpt-6.1-sol high |
| Watchdog channel | Telegram test | 200 |
| Remote build, landing dry run | delegated | owners' first Atlas build; captain READY dry run |

## Tickets
| Ticket | What | Depends | Owner | Track | State |
|---|---|---|---|---|---|
| C11-358 R1 | web renderer bundle + bridge | — | codex-md-r1 (closed) | normal | merged c37ced9d78 (#620), done |
| C11-359 R2 | native WKWebView panel | lands after 358 (builds in parallel on BRIDGE.md) | codex-md-r2 (closed) | large | merged a95823705c (#621) + follow-up fd263426f9 (#622), done |
| C11-360 R3 | reader chrome | 358, 359 | codex-md-r3 (closed) | normal | merged bdb91b1e12 (#623), done |
| C11-361 R4 | agent CLI + skill | 359 | codex-md-r4 (closed) | normal | merged 22786494a8 (#624), done |
| C11-362 N1 | in-panel navigation | 360, 361 | codex-md-n1 panel:133 (Luna Fast Max) | normal | repair (PR #626; R1 FAIL B1-B3; Grok R2 pan:167) |
| C11-363 N2 | corpus palette, backlinks, ticket links | 362 (seam via nav API) | codex-md-n2 panel:149 (pre-warm) | normal | not_admissible |

## Decisions (our assumptions, surfaced to Atin at first checkpoint)
- 2026-10-08 Split C11-336 into R1–R4 and C11-357 into N1–N2 (child tickets C11-358..363).
- 2026-10-08 R1 and R2 run in parallel against a bridge contract R1 pushes first (exception to "dependents implement after merge"); R2 lands after R1.
- 2026-10-08 Toolbar is native SwiftUI (doc names browser buttons it mirrors); outline/find placement is R3's call.
- 2026-10-08 357 corpus = git repo containing the open file, else its directory; skip .git, node_modules, build outputs. Ticket IDs link only when that repo has `.lattice/`, read-only; plain text otherwise. Vimium link hints out.
- 2026-10-08 Routing per Configuration recorded without blocking on Atin (brief fixed Sol builders and cross-family review).

- 2026-10-08 BRIDGE v1 (249e9e38c8) accepted; amended final e9e04ae479: local images inside the doc dir render via c11md-asset://doc/<rel path>, native validates realpath; remote/data/outside stay inert.

- 2026-10-08 02:15 Atin: Codex seats move from Sol to Luna. All five switched in place to GPT-6-Luna max; global ~/.codex/config.toml default restored (gpt-6-astra high, service_tier default).

- 2026-10-08 02:26 R1 harness cannot register a private WKWebView scheme: harness proves URL policy only; native byte validation is R2's test burden.

- 2026-10-08 02:45 C11-359 weight DECISION: lazy alone left 25 WebContent procs, +2.9 GB RSS after visiting 20. Ruling: bounded eviction in-ticket (visible + LRU 4), position restore, footprint-based re-measure (briefs/r2-eviction-ruling.md).

- 2026-10-08 02:50 Bridge v1.1 (additive): visible().lines.offset + scrollToLine(line, offset=0) for eviction restore. R1 commits on side branch md-viewer/C11-358-bridge-offset; joins PR #620 at the repair push.

- 2026-10-08 03:15 C11-359 reviews start before R1 merges: stacked draft PR (base = R1 branch), rebase + retarget to main after R1 lands, delta attestation. Eviction measured 960 MiB physical / 10 procs (vs ~2.9 GB RSS / 25); restore-position bug under owner diagnosis.

- 2026-10-08 04:22 Synthesis Q1 ruling: restore mailto: links only (base opened them) inside C11-359's repair, via NSWorkspace after validation.

- 2026-10-08 06:45 C11-360 DECISION ruling: outline (and find bar) render in the page; native owns toggle, ⇧⌘O, persisted choice. R3 owns Resources/markdown-viewer edits for its ticket.

- 2026-10-08 08:55 C11-360 Review 1 calls: find bar moves into the page (enforcing the 06:45 ruling); "system" theme follows c11 effective appearance (= OS when c11 is System), unchanged since #622.

- 2026-10-08 12:50 N1/N2 seam: MarkdownPanel.navigate(to:fragment:origin:) async -> MarkdownNavigationOutcome (panel-owned, no focus change); N2 origins .palette/.backlink.

- 2026-10-08 14:30 Atin: get it all done. Remaining-run rules: single Opus review per ticket (Grok R2 on C11-362 already running is kept); N2 starts now in parallel against N1's pushed nav API; scope = all of C11-357.

## Active blockers
- none

## Accepted residuals
- none

## Orchestrator footguns
- Drawbridge is dry-run (CLAUDE.md): its review job after `gh pr ready` is advisory, not a merge gate. The captain waited ~15 min on it for #624.
- Atlas disk filled at ~11:25 (ENOSPC) from per-attempt tags (~4.7 GB each). Orchestrator owns cleanup: delete a finished tickets tags + DerivedData at completion. Remind seats to reuse one tag.
- Never `c11 mailbox recv --drain >/dev/null`: it marks unread envelopes read. A C11-361 HANDOFF was lost for ~27 min (08:38 → 09:06). Drain with output and read every body.

## Follow-up candidates (file at closeout)
- Shared-resolver hole (upstream code): an unresolvable explicit panel ref falls back to the focused panel in v2ResolveWorkspaceSurface; markdown handlers fixed in C11-361; remaining callers are DebugHandlers (panel sheet/detail, rail, strip-scroll, hover test seams). Low severity; one follow-up ticket, consider offering upstream.
- [filed by scoping as C11-364; do not duplicate] `c11 mailbox send --to X "text"` (positional, no --body) silently sends an empty envelope instead of erroring. Bit this run at launch (R1 and scoping messages arrived empty). Fix: reject a positional body, or treat it as --body.
- `c11 config launch --area <ref|uuid>` returns `not_found: Area not found` for an area in another workspace (caller is workspace 8D68…); `--workspace workspace:16` works and lands in that workspace's focused area.

## Pre-existing (not this run; report to Atin)
- CI main (macOS) host test BrowserDeveloperToolsVisibilityPersistenceTests.testVisibleReplacementLocalHostNormalizesBottomDockedInspectorFrames fails on main since at least da0c104934 (2026-10-06); 4 runs before this run, again at fd263426f9. Treated as non-blocking for this run.

## Hardening ticket candidates (mint at closeout, one ticket)
- C11-358 (Opus verify): 8ad5469 line map makes highlighted 1000–3000-line fences scroll at 17–28 ms median frames; fast-follow.
- C11-358 (Opus verify): #1 partial: blocked-link classification, KaTeX trust and sanitize-alone guards still untested.
- C11-358 Review 1 non-blocking #5 #8 #9 #11 #12; Review 2 non-blocking #2 (identical block signatures).
- C11-359 verify2: paragraph after a nested list inside an item repeats the marker; nested quotes render flat.
- C11-359: mailto with an encoded newline in body is refused (conservative).
- C11-359 synthesis H1–H8 (failed renderer never recovers while visible; link narrowing notes; relative .md reach; legacy fontScale; Package.resolved churn; synchronize per update; hard links; CSP header + frame/origin witnesses).
