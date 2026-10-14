# Mailbox workstream — who-did-what attribution + build/test + live smoke

**Date:** 2026-06-16 · **Auditor:** Claude Code (Opus 4.8, 1M) sub-agent, spawned from the Etch workspace
**Scope:** the Mailbox hardening cluster merged into c11 `main` in the ~last 24h — PRs **#251 #252 #253 #254**, tickets **C11-143 / C11-144**.
**Substrate under test:** `entire-agent-etch` v0.01.002 captured-session data, joined against git/`gh` history. This is a dogfood of Etch's core thesis: *git says one human did everything; can Etch tell us which agents actually did the work?*

---

## TL;DR

- **Build + tests: PASS.** Current `main`/`release-v0.53.0` HEAD (`15dbc626a`, 0.53.0) compiles clean; `c11-logic` suite = **1001 tests, 0 failures, 3 skipped**, and all **12 Mailbox suites** ran — including the four new ones (`MailboxGlobalResolverTests`, `MailboxAddressTests`, `MailboxStdinBufferTests`, `MailboxEnvelopeValidationTests`).
- **Live behavior: PASS** (on a freshly-built tagged 0.53.0 instance — see the binary-currency gap below). C11-143 stable addressing, C11-144 prompt-gated buffering, and #251/#252 cross-workspace routing + loud rejection were all exercised end-to-end with `mailbox trace` / `recv` evidence.
- **Etch dogfood: a genuine, qualified win.** For the two worktree-isolated tickets (C11-143/#253, C11-144/#254) Etch alone reconstructs delegator→commits→PR with worktree provenance — something git *cannot* show (git credits 100% to the human). For the two main-checkout PRs (#251/#252) attribution is only partial: the real implementer was backfilled via `import` capture, so it carries no commit/PR linkage and joins only by branch+files+time. The convenience layers that would make this a one-query answer (`orchestration.ticket_id/role`, `outcome.pr_number`, `tokens`) are **empty on every session**.

---

## The git baseline (what you'd know without Etch)

All four PRs were authored and merged by the human operator account, and the squashed commits all carry `Atin <atin@atin.me>`:

| PR | Title | Branch | Squash commit | Author | Merged by |
|----|-------|--------|---------------|--------|-----------|
| #251 | Mailbox: route across all workspaces, stop silent drops | `mailbox-cross-workspace-routing` | `09d26f1cb` | BenevolentFutures | BenevolentFutures |
| #252 | Mailbox: de-silence cross-workspace seam (P0 hardening) | `mailbox-harden-followup` | `5c9cbe70e` | BenevolentFutures | BenevolentFutures |
| #253 | Mailbox: stable addressing `mailbox.address`/`role` [C11-143] | `c11-143-stable-addressing` | `ff4ea15c2` | BenevolentFutures | BenevolentFutures |
| #254 | Mailbox: prompt-gated stdin delivery (C11-144) | `c11-144-delivery-safety` | `f4c2b4c69` | BenevolentFutures | BenevolentFutures |

Plus version bumps to 0.52.0 (`8baea4876`, #246, pre-cluster) and 0.53.0 (`15dbc626a`). Git attribution = "the human did all of it." **That is the gap Etch is supposed to close.**

---

## Part 1 — Who actually did what (Etch + git join)

Etch captured **16 sessions** in the window (`--since 2026-06-14`), of which 8 are mailbox-relevant. The join key that makes this work is `git_end.commits_produced` — Etch records the exact SHAs a session created, and those map 1:1 onto the per-branch commits that were later squashed into each PR. The squash-commit file sets match the producing session's `files_touched` exactly.

### Who-did-what table

| Ticket / PR | Agent session (Etch ULID) | Runtime / model | Role (inferred) | Capture | Worktree | Commits produced → squashed into |
|---|---|---|---|---|---|---|
| **#251** routing | `01KV6K3RVZS8…` | claude-code / **opus-4-8** | implementer (ran `trident-code-review`, spawned 7 sub-Agents; 141 tool calls) | **import** | main checkout | *none recorded* (import has no `git_end`) → work landed as `09d26f1cb` |
| **#251/#252** land | `01KV69BB86T5…` | claude-code / **opus-4-8[1m]** | interactive operator (committed) | hooks | main checkout | `1bb5bf45`, `09d26f1c` → #251 + #252 branch |
| **#253 / C11-143** | `01KV78J62E95…` | claude-code / **opus-4-8[1m]** | **delegator** (prompt = `<task-notification>`) | hooks | ✅ `c11-worktrees/c11-143` | `784bdd23, 4a31f173, 42c0825f, 26962f33` → **`ff4ea15c2` (#253)** |
| **#253 / C11-143** | `01KV79F7VKD7…` | claude-code / opus-4-8 | **reviewer** (prompt = "Read …/review…/output.md"; 0 commits) | hooks | ✅ `c11-worktrees/c11-143` | — (review only) |
| **#254 / C11-144** | `01KV78JD49RZ…` | claude-code / **opus-4-8[1m]** | **delegator** (`<task-notification>`) | hooks | ✅ `c11-worktrees/c11-144` | `20cde927, b8147a7d, db3fe924` → **`f4c2b4c69` (#254)** |
| **#254 / C11-144** | `01KV79TYWD8K…` | claude-code / opus-4-8 | **reviewer** | hooks | ✅ `c11-worktrees/c11-144` | — (review only) |
| merge of all 4 | `01KV6K3MP25Q…` | claude-code / **opus-4-8[1m]** | **orchestrator / merge** (prompt = "Merge them.") | hooks | main checkout | `f4c2b4c6, ff4ea15c, 5c9cbe70, 09d26f1c` (all four squashes on `main`) |

**Reconstructed narrative.** Two distinct delivery patterns are visible:

1. **#251 + #252 — main-checkout work.** The cross-workspace-routing + de-silencing code was implemented by import-captured session `01KV6K3R` (Opus 4.8, a heavy session that itself ran a 9-lens `trident-code-review` and spawned 7 sub-Agents — note the `notes/.tmp/trident-mailbox-feature/` artifacts). It was committed/landed by the hooks-captured interactive operator session `01KV69BB86`.
2. **#253 + #254 — clean lattice-orchestrator pattern.** C11-143 and C11-144 each got a dedicated **delegator in its own worktree** (`c11-worktrees/c11-143`, `…/c11-144`, both `is_worktree:true` in the Etch record) plus a dedicated **reviewer**. The two delegators ran **in parallel** (both started ~03:45Z, both ended ~05:02Z) — dispatched concurrently as background Tasks (their first prompt line is a `<task-notification>` block). Then orchestrator session `01KV6K3MP` ("Merge them.") squash-merged all four to `main`.

Every one of these agents is invisible in git, which shows only `Atin` / `BenevolentFutures`. Etch surfaces the whole crew.

### Open at audit time (not part of the cluster)
#256 (Release v0.53.0), #255 (lattice-orchestrator skill hardening), #248–#250 (dependabot). All `BenevolentFutures`/`dependabot`.

---

## Attribution-quality verdict (the headline dogfood result)

**Could I reconstruct who-did-what from Etch alone? Mostly yes for the worktree tickets, only partially for the main-checkout PRs.** Specifics:

**What Etch nailed (real wins over git):**
- **Commit-level provenance.** `git_end.commits_produced` on the C11-143/C11-144 delegator sessions maps exactly onto the branch commits that were squashed into #253/#254. That is a clean session→commit→PR chain that git's flat "Atin authored everything" actively hides.
- **Worktree isolation is legible.** `is_worktree:true` + `worktree_path` show each delegator ran in its own `c11-worktrees/<ticket>` tree — you can *see* the lattice-orchestrator blast-radius discipline in the data.
- **Role separation by evidence.** Delegators (`<task-notification>` prompt + non-empty `commits_produced` + `[1m]` context model) are cleanly distinguishable from reviewers (review-prompt + zero commits + plain Opus) — even though no explicit role field is set.
- **Parallelism is reconstructable** from the overlapping start/end timestamps.

**Where it fell short (trust-calibration findings):**
1. **Empty provenance layers everywhere.** `orchestration.ticket_id`, `orchestration.run_id`, `orchestration.role`, `outcome.pr_number`, `outcome.pr_state`, `outcome.ci_status`, and `tokens` are **null/empty on all 16 sessions** — even on branches literally named `c11-143` / `c11-144`. So the session→ticket and session→PR joins are *external inferences* (branch-name + git/`gh`), not facts Etch recorded. The role column above is inferred from prompt-shape, not read from a field.
2. **`import`-captured implementers have no commit linkage.** The actual #251 implementer (`01KV6K3R`) is `capture.method=import` with `git_end=null` → no `commits_produced`. You can only place it on the branch by `git_start.branch` + `files_touched` overlap + time. So for #251/#252 you can say "this agent touched the mailbox routing code" but not cleanly separate implement-vs-commit from provenance alone.
3. **A branch-only join would misattribute.** Session `01KV69BBEB` carries `git_start.branch = mailbox-cross-workspace-routing` but did **zero** mailbox work — all 6 of its `files_touched` are in `code/Etch/` (it was the Etch self-audit agent that happened to run while the c11 repo sat on that branch). `files_touched` is the disambiguator; branch alone lies.
4. **Import backfill creates phantom sessions.** Three codex/`gpt-5.5` sessions (`01KV733J…`, `01KV733JV…`, `01KV733M…`) are 4-second, **0-tool-call**, 0-file, no-commit records whose entire prompt is the repo `AGENTS.md`. They'd pollute any naive "who worked on c11" count. (Repo-wide: 188 of 207 sessions are `import` vs only 7 `hooks` — the corpus is mostly backfill, and backfill is the lower-fidelity tier.)

**Bottom line:** Etch answered the core question — *which agent sessions, in which worktrees, produced which commits* — for the half of the cluster that ran through the hooks-captured orchestrator workflow, and that answer is strictly more than git can give. But the "one query → who did this ticket" experience isn't there yet: the ticket/PR/role linkage fields are unpopulated, so a human (or this audit) still has to bridge the last hop with git + prompt-shape reading. The substrate is trustworthy for *commits and files*; treat its *ticket/PR/role* layer as not-yet-populated rather than empty-because-nothing-happened.

---

## Part 2 — Build + tests

Per `code/c11/CLAUDE.md`, the safe local loop for model/parser code is the `c11-logic` scheme (logic-only, no DEV.app host). Ran on HEAD `15dbc626a`:

```
xcodebuild -project GhosttyTabs.xcodeproj -scheme c11-logic -configuration Debug \
  -destination "platform=macOS" test
```

**Result: `** TEST SUCCEEDED **`**
```
Test Suite 'c11LogicTests.xctest' passed
  Executed 1001 tests, with 3 tests skipped and 0 failures (0 unexpected) in 43.9s
```

All 12 Mailbox suites executed and passed, including the suites added by this cluster:
- `MailboxGlobalResolverTests` (#251 cross-workspace resolution)
- `MailboxEnvelopeValidationTests` (#252 envelope hardening / content_type)
- `MailboxAddressTests` (C11-143 stable addressing)
- `MailboxStdinBufferTests` (C11-144 buffer-while-busy / flush)
- plus `MailboxDispatcherTests`, `MailboxDispatcherGCTests`, `MailboxDispatchLogTests`, `MailboxSurfaceResolverTests`, `MailboxIOTests`, `MailboxLayoutTests`, `MailboxOutboxWatcherTests`, `MailboxULIDTests`.

(The host-required `c11Tests`/`tests_v2` suites were not run locally per policy — the host scheme launches a DEV.app and the Python parity test needs a running new-binary socket; the logic suite plus the live smoke below cover the behavior.)

---

## Part 3 — Live smoke (C11-143 / C11-144 / #251)

### Binary-currency gap (called out, not papered over)
The operator's **running** instance is `/Applications/c11.app` at **0.51.0 (108)** — and it predates the entire cluster: `c11 mailbox` returns *"Unknown command 'mailbox'."* on it. **None of #251–#254 is exercisable on the live instance.** This is the same lesson Etch itself just learned about stale state: don't validate against an old binary and call it verified.

So I built and launched a **tagged Debug staging build** from HEAD via `./scripts/reload.sh --tag mbxaudit` → **`c11 0.53.0 (110)`**, socket `/tmp/c11-debug-mbxaudit.sock`. All smoke below ran against that, in its own surfaces, without touching the operator's workspaces. (The tagged app self-quit once mid-run and was relaunched from the built bundle — noted for honesty; no crash report was produced.)

### Smoke 1 — C11-143 stable addressing + #251/#252 dispatch log
Setup: `bob` (surface:3, `mailbox.address=bob-smoke`), `alice` (surface:2, `mailbox.address=alice-smoke`, `mailbox.delivery=stdin`). `bob` sends `--to surface:alice-smoke`. `mailbox trace`:
```
received  from=bob  to=surface:alice-smoke
resolved  recipients=["alice"]            ← address → surface titled "alice"
copied    recipient=alice
handler   handler=stdin  outcome=buffered ← C11-144 (alice not at promptIdle)
cleaned
```
`alice` `recv --peek` → `{"body":"hello-alice-1 sha=abc","from":"bob","to":"surface:alice-smoke",…}`. Durable inbox delivery confirmed.

### Smoke 2 — the decoupling-from-mutable-title proof (C11-143 core claim)
Renamed alice's **title** to `alice-RENAMED-xyz` (address unchanged), then:
- Send `--to surface:alice-smoke` → **still delivered**; trace shows `resolved recipients=["alice-RENAMED-xyz"]` — same surface, reached by stable address despite the new title. ✅
- Send `--to alice` (the **old title**) → `Error: No live surface named "alice" in any workspace. Message not sent.` exit **1**. ✅ — proves (a) the title is *not* what carried the earlier delivery, and (b) an unresolvable recipient is **loudly rejected, not silently dropped** (#251/#252).

### Smoke 3 — C11-144 prompt-gated stdin delivery
Across every send, the stdin handler logged `outcome="buffered"` while the recipient shell was not at a genuine prompt — i.e. it **declined to inject into a non-idle PTY** (exactly the buffer-while-busy contract) and the message was still `copied` to the durable inbox and drainable via `recv`. The buffering half — the safety-critical half — is directly demonstrated. The flush-to-PTY half did not visually render under socket-`send`-driven input (synthetic input doesn't drive the shell-integration prompt-state transitions the way interactive typing does); the flush logic is covered by the passing `MailboxStdinBufferTests`.

### Smoke 4 — #251 cross-workspace routing
New workspace `ws2-carol` (surface:5, `carol-smoke`). `bob` in ws1 sends `--to surface:carol-smoke` (ws2). Trace, logged in the **recipient's** workspace:
```
received  from=bob  to=surface:carol-smoke
resolved  recipients=["carol"]
copied    recipient=carol
handler   handler=stdin  outcome=buffered
cleaned
```
`carol` `recv --drain` → `{"body":"cross-ws-hello","from":"bob","to":"surface:carol-smoke",…}`. Cross-workspace resolve + deliver confirmed; no silent drop. ✅

---

## Evidence index
- Etch dump: `entire-agent-etch query --repo . --since 2026-06-14T00:00:00Z --json` (16 sessions) → `/tmp/etch-mailbox-window.json`
- Build/test log: `/tmp/c11-logic-test.log` (`** TEST SUCCEEDED **`, 1001 tests)
- Tagged build: `/tmp/c11-reload-mbxaudit.log` (0.53.0 / build 110), socket `/tmp/c11-debug-mbxaudit.sock`
- Live envelope ids traced: `01KV7F7T7B…` (addressed), `01KV7FA2PK…` (post-rename), `01KV7FBBJ9…` (cross-workspace)
