# Truth & Stability Cycle — EVALUATION

One row per SPEC criterion. Tags: `autonomous` (delegator/validator can prove it alone), `operator-assisted` (needs the operator driving or judging), `external-oracle` (CI or third-party system is the judge), `felt` (aesthetic/ergonomic judgment, operator only).

**Standing harness commands:**
- Fast suite: `xcodebuild -project GhosttyTabs.xcodeproj -scheme c11-logic -configuration Debug -destination "platform=macOS" test` (~30s warm; the inner-loop clock)
- Host suite (safe wrapper): `scripts/test-unit-local.sh [-only-testing:...]`
- Socket suites: tests_v2 against a tagged build's socket (`C11_SOCKET=/tmp/c11-debug-<tag>.sock`)
- Tagged build: `./scripts/reload.sh --tag <ticket-slug>`; QA launch: `./scripts/launch-tagged-automation.sh <tag> --qa fresh`
- Validation bar for every ticket (operator decision 2026-07-06): **tagged build + live scenario proof with screenshots/recordings attached to the ticket; CI green is necessary but not sufficient.**

| Criterion | Tag | How to verify |
|---|---|---|
| DX-1 | autonomous | Inspect tree: dispatch switch absent from TerminalController.swift; handlers present per domain |
| DX-2 | autonomous + external-oracle | Baseline tests_v2 run recorded pre-change; identical results post-change; c11-logic green; CI green |
| DX-3 | autonomous | Diff audit per handler against the pre-move threading annotations; no added `DispatchQueue.main.sync` |
| DX-4 | autonomous | `wc -l` on TerminalController.swift and new handler files |
| DX-5 | autonomous | Diff audit: no method renames, no response-shape changes |
| HYG-1 | autonomous + external-oracle | `git ls-files \| grep -c node_modules` == 0; CI green |
| HYG-2 | autonomous | `gh pr list` shows zero open dependabot PRs; closures carry reasons |
| HYG-3 | operator-assisted | Inventory artifact reviewed by operator; deletions are the operator's call |
| WEB-1 | autonomous | Repo-wide grep for manaflow domains/keys in web/; only lineage credits remain |
| WEB-2 | autonomous | Read CONTRIBUTING.md |
| WEB-3 | autonomous | Method index count matches `grep -c` of v2 method registrations in source; no cmux branding |
| WEB-4 | autonomous | ROADMAP.md exists; PHILOSOPHY.md reference resolves |
| WEB-5 | autonomous | tests_v2 discovery run passes with only a `c11` binary on PATH |
| TEL-1 | autonomous | Socket test: set key, `get_metadata` returns last-updated; survives snapshot round-trip |
| TEL-2 | operator-assisted + felt | Scripted decay demo on a tagged build (accelerated TTL), screenshots at fresh/stale/expired; operator judges the rendering |
| TEL-3 | autonomous | Scripted: silent pane vs output-producing pane; read derived tier via socket |
| TEL-4 | autonomous + operator-assisted | Scripted takeover demo; screenshot of derived-distinct pill |
| TEL-5 | autonomous | Instruments/hot-path diff review; no new per-keystroke work (CLAUDE.md hot-path list untouched or justified) |
| TEL-6 | operator-assisted + felt | Tagged build screenshots against the cluster plan's design spec; operator judges |
| TEL-7 | autonomous (recorded) | The two scenarios scripted and recorded; artifacts on the ticket |
| TEL-8 | autonomous | Skill diff present in same PR; sync script run |
| EVT-1 | autonomous | Tail the file; validate fields against the envelope schema in spec/ |
| EVT-2 | autonomous | Trigger each taxonomy member; assert one event each |
| EVT-3 | autonomous | Code audit off-main; stall-injection test (slow disk simulation) leaves UI/socket responsive |
| EVT-4 | autonomous | Fill past cap; rotation observed; marker/seq behavior asserted |
| EVT-5 | autonomous | CLI matrix: --follow, --filter, --since |
| EVT-6 | autonomous | Timestamped transition vs consumer-observed time < 1s |
| EVT-7 | autonomous (recorded) | Consumer-reacts demo recorded; artifact on ticket |
| EVT-8 | autonomous | Skill diff + spec/ schema in same PR |
| RES-1 | autonomous (recorded) + operator-assisted | Scripted kill-and-relaunch scenario on a tagged build; per-surface resume/diagnostic table produced; operator spot-checks one live run |
| RES-2 | autonomous | Scope trace: each wired subsystem maps to a scenario need |
| RES-3 | autonomous | The harness script exists, is documented, and reruns green twice consecutively |
| RES-4 | autonomous + external-oracle | Existing resume suites green; CI green |
| RES-5 | autonomous | references/conversation.md diff in same PR |
| COR-1 | autonomous | Socket test matrix: empty/absent ref per write command → error, no write lands |
| COR-2 | autonomous | Skill diff in same PR |
| COR-3 | autonomous | Sweep artifact (audit list → fix commit map); hang monitor log clean during flood test |
| COR-4 | autonomous + external-oracle | Both regression tests present and green in CI |

**Human-use checkpoints (post-merge smoke, operator):**
1. Live with the new sidebar for a day: does decay feel right at default thresholds? Do derived pills read as trustworthy? (felt)
2. Force-quit your real working session once and relaunch: did everything come back? (the RES-1 scenario on real work)
3. Waiting-agent cluster: does the restyle earn its place at a glance? (felt)
4. `c11 events tail --follow` open in a pane during a normal day: is the stream signal or noise? (felt)
