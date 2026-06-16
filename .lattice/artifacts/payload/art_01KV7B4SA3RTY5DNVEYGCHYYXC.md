# C11-144 Live Validation — prompt-gated stdin delivery

**Build:** tagged Debug `c11-144` from worktree `c11-144-delivery-safety` (`./scripts/reload.sh --tag c11-144`), socket `/tmp/c11-debug-c11-144.sock`. Prod c11 untouched. Evidence is PTY `read-screen` transcripts + the on-disk `_dispatch.log` (both reproducible; stronger than a screenshot because they show exact bytes).

Recipient = a terminal surface with `mailbox.delivery=stdin`. Sender = a peer terminal running `c11 mailbox send`. Shell-activity state was driven over the socket with the **correct** scope (`--tab=<workspace-uuid> --panel=<recipient-surface-uuid>`) to exercise the real `report_shell_state → updatePanelShellActivityState → flush` path (see "Pre-existing infra finding" for why the shell integration's own reports don't land in this build).

## Results — every gate path confirmed end-to-end

| # | Scenario | Recipient state | Expected | Observed |
|---|----------|-----------------|----------|----------|
| 1 | Send while idle | `promptIdle` | inject now | `<c11-msg>` block appeared immediately; `_dispatch.log` `outcome=ok` (id …5BZDPTMC) |
| 2 | Send while busy | `commandRunning` | buffer, no inject | no block in PTY; `outcome=buffered` (ids …V5QZ679M, …1FQZYF74) |
| 3 | Return to prompt | `commandRunning → promptIdle` | flush FIFO | both buffered blocks injected at the exact transition; `outcome=flushed`, bytes carried (195 / 187) |
| 4 | **Gated send into open vim** | `commandRunning` (vim) | buffer, **vim uncorrupted** | vim buffer stayed pristine; message buffered, then flushed cleanly after `:q!` + prompt |
| 5 | **Raw ungated push into open vim** (`c11 send`, bypasses the gate = old behavior) | vim | — | **vim corrupted**: leading chars eaten as normal-mode commands, editor dropped into `-- INSERT --`, rest of block inserted as buffer text |

`c11 mailbox trace` for a buffered id shows `received → resolved → copied → handler(buffered) → cleaned … → handler(flushed)` — a buffered message is delayed and fully traceable, **never a silent drop**.

## The Claude-vs-Gemini split is settled — empirically

Scenarios 4 vs 5 are the decisive comparison. A raw push into a busy raw-mode app (vim) **does** corrupt the input stream (Gemini's claim). The prompt-gate prevents exactly that: the identical message over the gated mailbox path buffered instead and flushed cleanly once vim exited. **Verdict: ungated PTY push into a busy recipient is unsafe; the prompt-gate is the correct fix.** Ship the gate; keep the pull cadence as the contract.

## Residual flush-onto-bare-shell (acknowledged tradeoff, confirmed harmless)

When a buffered block flushes onto a recipient that is back at a **bare zsh prompt** (not an agent TUI), zsh tries to read it and prints `zsh: parse error near '\n'`. Harmless — the body is XML-escaped, nothing executes — and the message was already on the inbox/pull floor. For the real target (an agent TUI consuming a turn) this is the intended delivery. The 600 s freshness window keeps hours-long agent sessions from dumping stale blocks onto a bare shell when the agent finally exits.

## Pre-existing infra finding (NOT C11-144 code; affects how this feature behaves in practice)

In this build, `CMUX_TAB_ID == CMUX_PANEL_ID == CMUX_SURFACE_ID` (the **surface** UUID), while `CMUX_WORKSPACE_ID` is the distinct workspace UUID. The shell integration reports `report_shell_state … --tab=$CMUX_TAB_ID`, but `explicitSocketScope` interprets `--tab` as the **workspace** id, so `tabManagerFor(tabId: <surface-uuid>)` finds no tab and the report is silently dropped. Result: the integration's automatic `promptIdle`/`commandRunning` reports never reach the panel — `panelShellActivityStates` stays `.unknown` (zero `surface.shellState` events in the tagged debug log from the integration; only the correctly-scoped manual reports landed). This is pre-existing (C11-144 touches none of the env-var export, the shell-integration scripts, `explicitSocketScope`, or `reportShellState`).

**Consequence — and why Layer 2 is the contract, not a nice-to-have:**
- With state stuck `.unknown`, the gate buffers everything → **safe** (no corruption), but push-flush never fires automatically; delivery falls entirely to `c11 mailbox recv --drain`.
- Independently of this bug: an agent TUI keeps its shell `commandRunning` for its **entire life**, so push into a *live* agent always buffers and only flushes on agent exit (by which point the freshness window has dropped it). So even with perfect shell-state reporting, messaging a live agent relies on the pull floor.

Net: Layer 1 (the gate) is fundamentally a **safety** mechanism — it guarantees push never corrupts. Layer 2 (the `recv --drain` turn-boundary cadence, shipped in the skill) is the **delivery** contract. The implementation and docs already frame it this way ("doorbell, not delivery").

**Recommended follow-up (separate ticket):** fix the `CMUX_TAB_ID` export (it should carry the workspace UUID) or relax `explicitSocketScope` to resolve a panel by surface UUID across workspaces, so shell-state reporting reaches the panel and the bare-shell/build/vim push-flush path works without manual scope. Until then, the pull cadence covers delivery.

## Acceptance

- [x] No PTY corruption when a message arrives mid-command / mid-vim (gated path buffers).
- [x] Buffered messages flush at the next prompt (FIFO, traceable).
- [x] Empirically settled: ungated PTY push corrupts; the gate fixes it.
- [x] Tagged build torn down after validation.
