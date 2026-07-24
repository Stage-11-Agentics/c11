# Validation Plan — Truth & Stability cycle

Source spec: [SPEC.md](../../docs/cycles/2026-07-truth-and-stability/SPEC.md) · Source evaluation: [EVALUATION.md](../../docs/cycles/2026-07-truth-and-stability/EVALUATION.md) · Date: 2026-07-07

Conventions: "artifact" means a `--role validation` attachment on the named ticket (screenshot/recording/log/table). The Result Validator runs every `pre-merge-static` row from PR diff + source + recorded artifacts; it re-runs nothing that needs a merged tree or a human. Runtime proofs are recorded by delegators pre-merge; the Validator verifies the artifact exists, is specific, and matches the claim.

| # | Criterion (ID) | Verification method | Artifact to inspect | Pass condition | runnable_at |
|---|---|---|---|---|---|
| 1 | DX-1 | Read PR tree: dispatch switch gone from TerminalController.swift; per-domain handler files under a dedicated dir | PR (C11-159) diff | No socket dispatch switch in TerminalController.swift; ≥6 domain handler units present | pre-merge-static |
| 2 | DX-2 | Compare recorded pre-change tests_v2 baseline vs post-change run on the ticket; check c11-logic + CI status on PR | C11-159 validation artifacts + PR checks | Baseline and post-change results identical; c11-logic green; CI green | pre-merge-static |
| 3 | DX-3 | Diff audit per handler: threading annotations (off-main vs main-actor) preserved; grep diff for added `DispatchQueue.main.sync` | PR (C11-159) diff | Zero handlers change threading tier; zero added main.sync on telemetry paths | pre-merge-static |
| 4 | DX-4 | `wc -l` on TerminalController.swift and each new handler file at PR head | PR (C11-159) branch | TerminalController.swift < ~10k LOC; no new handler > ~3k LOC | pre-merge-static |
| 5 | DX-5 | Diff audit: socket method names and wire response shapes unchanged; no new abstraction beyond the handler seam | PR (C11-159) diff | No renamed methods, no changed response shapes | pre-merge-static |
| 6 | HYG-1 | Run `git ls-files \| grep -c node_modules` at PR head; check .gitignore; CI status | PR (C11-160) branch + checks | Count = 0; gitignored; CI green | pre-merge-static |
| 7 | HYG-2 | `gh pr list --author app/dependabot --state open`; read closure comments on closed ones | GitHub PR list | Zero open dependabot PRs; every closure carries a one-line reason | pre-merge-static |
| 8 | HYG-3 | Confirm stale-branch inventory artifact exists (local+remote, last-commit date, merged status) | C11-160 attachment | Inventory complete and readable; NO deletions performed | pre-merge-static |
| 9 | HYG-3b | Operator reviews inventory and decides deletions | inventory artifact | Operator call | post-merge-smoke |
| 10 | WEB-1 | Repo grep for manaflow domains/keys under web/ at PR head | PR (C11-161) branch | Only deliberate lineage credits remain | pre-merge-static |
| 11 | WEB-2 | Read CONTRIBUTING.md at PR head | PR (C11-161) branch | Directs to Stage-11-Agentics/c11 | pre-merge-static |
| 12 | WEB-3 | Count dotted v2 method registrations in source vs method-index entries in docs/socket-api-reference.md; grep doc for cmux branding | PR (C11-161) branch | Counts match; zero stale cmux naming; JSON-RPC framing documented | pre-merge-static |
| 13 | WEB-4 | ROADMAP.md exists at repo root; PHILOSOPHY.md reference resolves | PR (C11-161) branch | Both true | pre-merge-static |
| 14 | WEB-5 | Read tests_v2 discovery code at PR head + delegator's recorded discovery-run log (c11-only PATH) | PR diff + C11-161 artifact | Discovery locates `c11` binary; recorded run passed with no `cmux` binary on PATH | pre-merge-static |
| 15 | TEL-1 | Read PR: timestamp persisted with canonical metadata; socket test present; delegator's socket-test artifact (set key → get_metadata returns last-updated; snapshot round-trip) | PR (C11-162) diff + artifact | Test exists + recorded run green | pre-merge-static |
| 16 | TEL-2 | Inspect recorded decay demo (accelerated TTL screenshots fresh/stale/expired); settings expose thresholds w/ 5m/15m defaults | C11-162 artifacts + diff | Screenshots show three visual states; defaults + tunability in code | pre-merge-static |
| 17 | TEL-2b | Operator judges decay rendering + thresholds by living with it | merged build | Feels right (felt) | post-merge-smoke |
| 18 | TEL-3 | Read derived-liveness implementation + recorded scripted proof (silent pane vs output pane, derived tier via socket) | PR diff + C11-162 artifact | Derived tier written; never overwrites fresh explicit | pre-merge-static |
| 19 | TEL-4 | Recorded takeover demo + screenshot of derived-distinct pill; code path for explicit-resume | C11-162 artifacts + diff | Takeover on expiry; visually distinct; explicit resumes on re-report | pre-merge-static |
| 20 | TEL-5 | Hot-path diff review: CLAUDE.md hot-path list untouched (or justified); no per-keystroke/per-frame additions | PR (C11-162) diff | Clean or explicitly justified | pre-merge-static |
| 21 | TEL-6 | Tagged-build screenshots vs docs/c11-waiting-agent-cluster-plan.md design spec | C11-162 artifacts | Two-row cluster, rename, lit-state inversion, prev/next arrows all present | pre-merge-static |
| 22 | TEL-6b | Operator judges cluster restyle at a glance | merged build | Earns its place (felt) | post-merge-smoke |
| 23 | TEL-7 | Both scenarios recorded: (a) status → silence → decay → derived flip; (b) never-reporting agent with output → derived `working` | C11-162 artifacts | Both recordings attached and show claimed behavior | pre-merge-static |
| 24 | TEL-8 | Skill metadata-reference diff in same PR; sync script run noted | PR (C11-162) diff | Age/decay + derived-liveness documented | pre-merge-static |
| 25 | EVT-1 | Read emitter + envelope schema in spec/; delegator's tail-capture validated against schema | PR (C11-163) diff + artifact | NDJSON w/ seq, ISO-8601 ts, type, subject refs, payload | pre-merge-static |
| 26 | EVT-2 | Taxonomy check: each v1 member has an emit site; recorded trigger-each-member run | PR diff + C11-163 artifact | All members present (derived-liveness via TEL stub if seam hit) | pre-merge-static |
| 27 | EVT-3 | Code audit: writes off-main, non-blocking; stall-injection test present + recorded result | PR diff + C11-163 artifact | UI/socket unaffected by slow disk in test | pre-merge-static |
| 28 | EVT-4 | Rotation test/recorded run: fill past cap, one rolled generation, rotation detectable | PR diff + C11-163 artifact | Rotation observed w/ marker or seq reset | pre-merge-static |
| 29 | EVT-5 | CLI matrix recorded: `c11 events tail` with --follow / --filter type= / --since | C11-163 artifact | All three flags demonstrated | pre-merge-static |
| 30 | EVT-6 | Latency measurement in recorded run (transition ts vs consumer-observed ts) | C11-163 artifact | < 1s under normal load | pre-merge-static |
| 31 | EVT-7 | Consumer-reacts demo recording (status change, mailbox delivery, surface close) | C11-163 artifact | All three appear; consumer reacts | pre-merge-static |
| 32 | EVT-8 | Skill diff + spec/ schema in same PR | PR (C11-163) diff | Both present | pre-merge-static |
| 33 | RES-1 | Recorded kill-and-relaunch scenario run (≥10 conversations, ≥3 workspaces, ≥3 kinds incl. claude-code+codex) + per-surface resume/diagnostic table | C11-164 artifacts | Every surface resumes per tier OR shows specific diagnostic_reason; zero silent fresh-launches | pre-merge-static |
| 34 | RES-1b | Operator force-quits real session once and relaunches | merged build | Everything comes back | post-merge-smoke |
| 35 | RES-2 | Scope trace in ticket: each wired subsystem ↔ scenario need | C11-164 attachment | Complete mapping, no unscoped work | pre-merge-static |
| 36 | RES-3 | Harness script in PR, documented; two consecutive green runs recorded | PR diff + C11-164 artifact | Script exists; 2× green | pre-merge-static |
| 37 | RES-4 | Existing resume suites green; CI green | PR (C11-164) checks | Green | pre-merge-static |
| 38 | RES-5 | references/conversation.md diff in same PR | PR (C11-164) diff | Per-kind crash guarantees documented | pre-merge-static |
| 39 | COR-1 | Read rejection code + socket test matrix (all 10 write commands, empty + absent ref) + recorded run | PR (C11-165) diff + artifact | Error returned, no write lands, for every command | pre-merge-static |
| 40 | COR-2 | Skill footgun-guidance diff in same PR | PR (C11-165) diff | Updated to new contract | pre-merge-static |
| 41 | COR-3 | Sweep artifact (audit list → fix commit map); flood-test recorded run with clean hang-monitor log | C11-165 artifacts | pane.confirm, feedback.submit, nested CFRunLoopRun genre all addressed; monitor clean | pre-merge-static |
| 42 | COR-4 | Both regression tests present in diff and green in CI | PR (C11-165) diff + checks | Empty-ref logic test + socket-flood test, green | pre-merge-static |
| 43 | Smoke-1 | Live with new sidebar for a day (decay feel, derived-pill trust) | merged build | Operator judgment (felt) | post-merge-smoke |
| 44 | Smoke-2 | `c11 events tail --follow` open during a normal day: signal or noise? | merged build | Operator judgment (felt) | post-merge-smoke |
