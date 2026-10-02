# Run State: C11-257 agent messaging

## Objective
Five lanes of C11-257 (A record sends, B mail to waiting agents, C hook drains, D messages page, E help + teaching), one delegator, worktree, branch and PR each. Every lane holds at `pr_open` after independent review and runtime proof. Then one integrated tagged dev build plus a numbered sign-off script for Atin. His pass on the script is merge approval for all five PRs. Done = all five merged and verified on origin/main, `lattice complete C11-257`.

## Configuration
- Repo: ~/Projects/Stage11/code/c11 (board = local `.lattice/`, LATTICE_ROOT = repo root). Remote `origin` = github.com/Stage-11-Agentics/c11, default `main`. `upstream` (manaflow) never touched.
- Base for all lanes: origin/main 53d5d8d563 (fetched 2026-10-01, current; C11-248 P3A/B/C, P5-P8 already merged).
- Worktrees: ~/Projects/Stage11/code/c11-worktrees/c11-257-{a..e}, branches c11-257-{a..e}. Provisioned (submodules + SHA-keyed GhosttyKit link, ghostty 26c3e499).
- Merge policy: HOLD at pr_open (operator brief). At Atin's pass, the Integrator (tab:205) becomes Merge Captain per merge-captain.md: land A → B → C → D → E (squash), rebasing with the int conflict resolutions; Orchestrator is fallback.
- WIP: max 3 delegators building at once (operator brief). E's docs/help work does not count. Reviewer cap 1 at a time.
- Builds: one per machine via scripts/with-build-lock.sh. Tagged builds only (`./scripts/reload.sh --tag c11-257-<lane>`), validation launches with `C11_QA_LAUNCH=fresh`.
- Local tests: c11-logic scheme narrowed with -only-testing, through the lock. Never c11-unit locally. CI covers the rest.
- Models: A, D, E owner Luna max fast (Codex); B, C owner Opus high (Claude Code). Review cross-family: Luna-owned → Opus reviewer; Opus-owned → Sol xhigh reviewer.
- Comms: hub-and-spoke to Orchestrator tab:91 (workspace:9) via `c11 send`. Durable evidence as C11-257 comments prefixed with the lane letter.
- Runtime approval (operator brief): local tagged c11 builds; Claude, Codex and Grok agent tabs inside them for B/C live proof; c11 embedded browser for D. No production c11 changes, no pushes to upstream, no tenant-config writes outside the CLAUDE.md wrapper rail.
- Screen lock blocks terminal creation (ghostty OutOfMemory): park and ask Atin.
- Coexisting run: C11-248 orchestrator active in this repo. Do not touch its worktrees, branches, or .lattice/orchestration/run-state.md.

## Seats (workspace:9)
- Orchestrator tab:91 (area:21). Owners in area:26: A tab:108 (Luna), B tab:109 (Opus), C tab:110 (Opus), E tab:111 (Luna), D tab:118 (Luna). Reviewers: none running. Reviewer cap raised to 2 concurrent (read-only, no builds; lanes are held anyway). All suppressed; Orchestrator owns their completion.

## Integrator
- INT handoff @ cd25a63167 (product code ba1ae1ed46): tagged c11-257-int running; Sign-off workspace:2 (sender tab:6, lc-claude 7, lc-codex 8, lc-grok 9, awkward title 10, messages page 11). Sign-off script posted to Atin (signoff.md).
- C11-257 Integrator (Opus) tab:205, worktree c11-257-int (merges A-E heads, tagged c11-257-int, smoke). Re-merge on lane updates.

## Landed (verified on origin/main 2026-10-01 ~23:14)
- A #492 3a38d8a23b · B #491 72cd3882df · C #493 2b3c67ede3 · D #494 9b1380e08f · E #497 0bc4b61779
- Installed c11 skill synced from origin/main 0bc4b61779.
- Follow-ups filed as C11-313.
- Main smoke passed (Atlas-built c11-257-main, steps 1/3/4/8). C11-257 completed (lattice complete) 2026-10-01 ~23:25. Lane tabs closed; lane worktrees removed (branches kept). Integrator tab:205 stays to watch main CI + Mailbox parity on 0bc4b61779 and fix forward; its worktree c11-257-int remains until then.

## Landing matrix
| Lane | Branch | Owner model | Reviewer | Plan risk | State |
|---|---|---|---|---|---|
| A record sends | c11-257-a | Luna | Opus | low | PASS r3 @ a38e21ef4d (PR #492; CI pending at PASS, confirm green at integration); owner idle |
| B waiting delivery + inbox keying | c11-257-b | Opus | Sol | medium | PASS r6 @ e349e842a8 (PR #491; CI green); owner idle |
| C hook drains (Claude/Codex/Grok) | c11-257-c | Opus | Sol | high: tenant-config rule | PASS r8 @ ea4d923b6f + attested test-only e9b25928d9 (PR #493); owner idle |
| D messages page | c11-257-d | Luna | Opus | low (design unsigned) | PASS r4 @ 7c4a5ea04e (PR #494; CI running at PASS); visual port held for Atin's design feedback |
| E --help + teaching | c11-257-e | Luna | Opus | low | PASS r1 @ 4c79a63c8f + Orchestrator-attested text-only 87c41217f0 (PR #497); owner idle |

## Pinned contract clarifications (Orchestrator, 2026-10-01; posted on C11-257)
- C2-impl: exact `emitMailboxDelivered` signature (adds `via: String = "inbox"`). Lane A owns; B and C copy it byte-for-byte only if they need it.
- C3-order: claim before inject. A consumer renames the envelope into `_read/` before it injects or prints it; on injection failure it renames it back.
- C5 inbox key: recipient tab UUID. Lane B owns `MailboxLayout.inboxURL` + `resolveMailboxCaller`; nobody else edits them.

## Active blockers
- none

## Follow-ups (one ticket at the end)
- C r7: non-ULID filename with valid envelope JSON -> framed id differs from receipt id (crafted file only).
- B r6: (1) recursive input-queue drain + single flag; legacy v1 per-char send inside another writer's window can overflow the stack; (2) mail refused on a busy slot waits for the next agent edge (no retry at transaction end); (3) deferred socket send/send-key dropped if the surface detaches before its turn (previously fell back to pending-text queue); (4) deferred performBindingAction returns true early; (5) attached-surface paste-delay seam test still worth adding.
- C r8: stale comments say prompt-submit claims (c11.swift:19157,1940); --event override can mis-wire; Claude labels Stop-hook delivery 'Stop hook error' (find a shape that avoids it); duplicate Grok assertion.
- INT r2: one unreproduced non-flush (mail arrived during a 59 s forced turn; idle edge without waiting.entered; mail waited for the next Stop drain, still exactly once) — Lane B to investigate.
- INT: tagged app ended up frontmost once during setup (cause untested).
- D r3 nb4/5: bound label misleading when bytes limit; page renders twice per write (fold into visual pass).

## Integration notes
- E r1 follow-up 1: D and E both add `case "mailbox"` usage and a top-level mailbox help line; keep D's (includes view), drop E's two lines.
- D help text duplicates E's mailbox help entries (CLI/c11.swift ~8522, ~18007); reconcile at integration. Small docs/MiscHandlers conflicts with B, C, E expected.
- C r2 nb#5: drain must sort UUID + legacy inbox entries by ULID before claiming (only exists in the B+C merge).
- C drain fast path: after C5 (UUID inboxes) lands, prepareMailboxHookDrain can check the caller's own UUID dir and skip the socket title lookup (~260 ms on a loaded machine).
- Resources/bin/grok: B adds grok_watch_turns block; C may touch the wrapper too; merge side by side.
- B Stop-hook push vs C Stop-hook drain race is safe by C3 rename.
- A validation: 'c11 mailbox send' reportedly rejected on A's tagged build (B's worked); A reviewer to classify.

## Decisions
- 2026-10-01 No Merge Captain before sign-off: operator brief holds every lane at pr_open.
- 2026-10-01 Lane C plan must fit the CLAUDE.md rule "c11 never writes tenant config" (wrapper rail only). If a harness can take hooks only from persistent config, Lane C raises a DECISION.

- 2026-10-01 Grok C6 ruling (Atin leans plugin, flexible): default no ~/.grok write, Lane B wrapper watcher; pre-approved fallback = opt-in Grok plugin if B's live Grok proof fails. B's proof passed.
- 2026-10-01 Atin: press ahead to merge; sign-off script stays the merge gate (offered per-lane merge as alternative).

- 2026-10-01 Via Mailbox research tab 71 (Atin's behalf): Lane D builds writer/data/plumbing first, holds the visual port until Atin's prototype feedback is relayed.

- 2026-10-01 B r1 finding 6 ruling: real-keyboard draft proof is operator-only on Hyperion (focus theft); B adds a non-focus-stealing seam proof + Atin keeps the sign-off step.

- 2026-10-01 18:15 A and C r1 reviewers never started (launch-agent typed a >1 KB prompt into the shell, truncated at the tty line limit, zsh quote>); ~30 min lost. Relaunched with short prompts pointing at review-a-r1.md / review-c-r1.md. Filed C11-258. Rule for this run: launch prompts stay short and point at a file.

- 2026-10-01 A r1 finding 3 ruling: queued v2 sends emit tab.input_sent at enqueue with queued:true.

- 2026-10-01 C r1 ruling: hook fast path reads only the C5 UUID inbox from C11_TAB_ID (no socket); legacy title-keyed inboxes drain via explicit recv only.

- 2026-10-01 B r3: same bug class seen three times (mail pasted into a PTY not read by the interactive agent). Directed a structural fix for round 4 instead of mode enumeration. If r4 still blocks: park PR #491 per the 4-round rule and bring Atin a cut-line decision.

- 2026-10-01 ~20:05 Atin: yes to a fifth round for B and C; "we want to get this done successfully" (aim for clean passes, not residuals). Open question to Atin: default mailbox.delivery=stdin on for agent tabs? Assumption until answered: off by default, E's docs teach agents to opt in at orientation.

- 2026-10-01 C r6 proceeds under Atin's 'get this done successfully' (beyond the 5th round he approved); design directed to a filesystem receipt spool so the socket-after-claim class cannot recur.

- 2026-10-01 20:20 Lane D's HANDOFF via c11 send to tab:91 never arrived (found by heartbeat ~40 min later). Comms gap worth noting for the ticket itself.

- 2026-10-01 ~20:50 Atin concerned about thrashing, wants it wrapped up. Orchestrator: reviews become final gates judged by final-gate.md (realistic-use blockers only; theoretical edges -> one follow-up ticket); E finalizes docs now; integrator assembles the integrated build in parallel. Orchestrator owns that its 'hunt for the class' review prompts widened scope each round.

- 2026-10-01 ~21:10 INT finding: UserPromptSubmit additionalContext mail is seen but not acted on by Claude. Orchestrator decision (a): drop prompt-submit drain; delivery = B push (waiting) + C Stop drain (turn end) + recv floor.

- 2026-10-01 ~21:45 Atin: "Yep, get it done, please" = merge approval. Integrator is Merge Captain, landing A→B→C→D→E.

## Accepted residuals
- none
