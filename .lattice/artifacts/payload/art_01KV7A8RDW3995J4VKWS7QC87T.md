# Code Review: C11-144 — Mailbox delivery safety (prompt-gated stdin + receiver-pull cadence)

## 1. Verdict

**PASS** — The C11-144 implementation is correct, matches the plan, and meets the
code-level acceptance criteria. Two non-code caveats below must be settled before
this lands: **(a)** the diff supplied in this review packet is the *wrong change*
(it is the `#251`/`#252` cross-workspace work, not C11-144), and **(b)** the
explicit dogfood-validation gate has no evidence in the tree yet. The code itself
is good; these are a review-packaging defect and an acceptance-evidence gap, not
implementation bugs.

> I did not review off the supplied diff alone — it does not contain the C11-144
> code. I reviewed the actual implementation on the branch (`git diff
> 5c9cbe70e..HEAD`), which is what the task describes.

## 2. Summary

The task is prompt-gated stdin delivery: gate PTY injection on the already-tracked
`PanelShellActivityState`, buffer while the recipient shell is busy, flush FIFO at
the next prompt, and add a receiver-pull cadence to the skill as the durable floor.
The real implementation (`MailboxStdinBuffer.swift` pure seam, `StdinMailboxHandler`
writer-signature extension, `Workspace` wiring, dispatch-log lifecycle events, docs,
synced skill) does exactly this, cleanly and idiomatically, with solid unit coverage
of the pure logic. The single highest-impact finding is process, not code: **the diff
handed to this reviewer is `#251`/`#252` (cross-workspace routing + `content_type`
cap), so a reviewer trusting only the packet would review the wrong change entirely.**

### What was actually verified
- **Branch shape:** `main` is at `c41538d41`; merge-base `206588057`. The branch
  stacks four commits — `#251` (route across workspaces), `#252` (de-silence
  cross-workspace seam), then the two C11-144 commits `db3fe924b` (prompt-gate stdin)
  and `b8147a7d8` (docs). Neither `#251` nor `#252` is on `main` yet, so a `main...HEAD`
  PR ships all four.
- **C11-144 code** = `5c9cbe70e..HEAD`: `MailboxStdinBuffer.swift` (new, 139 lines),
  `StdinMailboxHandler.swift`, `Workspace.swift`, `MailboxDispatchLog.swift`,
  `MailboxDispatcher.swift`, `MailboxStdinBufferTests.swift` (new, 168 lines),
  `StdinHandlerFormattingTests.swift`, `docs/c11-mailbox-guide.md`, `skills/c11/SKILL.md`,
  `project.pbxproj`.
- **MainActor safety:** `Workspace` is `@MainActor` (Sources/Workspace.swift:5132), so
  the "buffer state is main-confined, no locks" claim is statically guaranteed.
- **Telemetry is non-blocking:** `MailboxDispatchLog.append` serializes synchronously
  then `queue.async`-es the file write — the main-actor flush path's `logStdinLifecycle`
  calls do not block main (complies with the socket-telemetry threading policy).
- **Transition-gated flush:** `updatePanelShellActivityState` early-returns on
  `previousState == state` (Workspace.swift:6718), so flush fires only on a genuine
  transition *to* `.promptIdle`, exactly as the plan specifies.
- **Compile safety:** the 2-arg→4-arg `Writer` typealias change is propagated to every
  call site (production writer + all 5 test sites); the new `WriteOutcome.buffered` and
  the four new `HandlerOutcome` cases introduce no non-exhaustive switch (the outcome
  enum is a String raw-enum used only for construction/serialization).
- **Target membership:** both new `.swift` files are registered in `project.pbxproj`
  (file-ref + build-file + group + Sources phase) — they will actually compile/run.
- **Skill HARD RULE:** `skills/c11/SKILL.md` is byte-identical to the installed copy at
  `~/.claude/skills/c11/SKILL.md` — the sync step was performed.

## 3. Issues

**[CRITICAL] review packet `prompt.md` — Supplied diff is not the C11-144 change**
The `### Diff` block in the review prompt contains only the `#251`/`#252` work:
`resolveMailboxTargetWorkspace` returning a `(workspaceId, verified)` tuple, the
unverified-send loud-fail, cross-workspace `trace`, and the `content_type` 128-byte cap.
**None of the C11-144 implementation is in it** — no `MailboxStdinBuffer.swift`, no
`StdinMailboxHandler` gating, no `Workspace` buffer/flush wiring, no buffer tests. The
"Project Context" section is also truncated mid-sentence. A reviewer who trusted the
packet would pass/fail the wrong change and never see the actual deliverable.
**Fix:** Regenerate the review diff against the correct range. For C11-144 alone:
`git diff 5c9cbe70e..HEAD`. If the intent is to review the whole stacked branch as one
PR: `git diff main...HEAD` (which includes `#251`/`#252` — confirm those were already
reviewed under their own PR numbers so they are not silently re-reviewed or, worse,
skipped). Fix the diff-generation step in the review harness so the base/head match the
task being reviewed.

**[MAJOR] acceptance — Dogfood validation gate has no evidence**
The task and plan make the dogfood test a first-class deliverable: fire messages into
agents mid-Vim and mid-build on a *tagged* build, confirm no PTY corruption and that
buffered messages flush at the next prompt — and it is explicitly the empirical
tie-breaker for the Claude-vs-Gemini split on whether direct PTY push corrupts. There
is no open PR, no `notes/` artifact, and no screenshots/`read-screen` evidence in the
tree (`git log 5c9cbe70e..HEAD` and `ls notes/` both come up empty for C11-144). The
code is structured to make this testable, but the runtime claim is unverified.
**Fix:** Run the dogfood scenario on a `./scripts/reload.sh --tag c11-144` build with a
recipient surface set to `mailbox.delivery=stdin`; capture (1) mid-build buffer→flush,
(2) mid-vim no-corruption, and (3) whether a *direct* push into a live agent corrupts
(records the Claude-vs-Gemini answer). Attach evidence to the ticket/PR. Tear the tagged
build down; never touch prod c11.

**[MINOR] Sources/Workspace.swift:6726-6730 — Residual flush-onto-bare-shell window near agent exit**
The freshness window (600 s) correctly stops hours-long agent sessions from dumping
stale `<c11-msg>` blocks when the agent finally exits. But a message buffered *within*
10 minutes of an agent quitting will still flush onto the now-bare shell when it returns
to `.promptIdle`, pasting `<c11-msg ...>` + Return as shell input (harmless garbage —
body is XML-escaped, `<` is at worst a redirect — and the message was already delivered
via the inbox/pull floor, but it is visible junk on the operator's prompt). This is an
acknowledged design tradeoff, not a defect; shell state alone cannot distinguish
"agent exited" from "long build finished."
**Fix:** Have the dogfood test explicitly probe "buffer a message, then quit the agent
within the window" and decide whether the residual junk is acceptable. If not, a future
refinement could suppress flush when the surface lacks a live known-recipient signal.
Not a blocker for this ticket.

**[MINOR] c11Tests/MailboxStdinBufferTests.swift — Confirm logic-target membership and add a cheap lifecycle-log test**
Two small testing gaps:
1. The plan places the test in the `c11LogicTests` target (file on disk in `c11Tests/`)
   so it runs in the fast logic-only loop. Verify the `project.pbxproj` Sources-phase
   membership for `MailboxStdinBufferTests.swift` is the logic target, not only the
   host-required `c11Tests` target — otherwise the pure test needlessly drags in the app
   host.
2. `MailboxDispatcher.logStdinLifecycle` and the `.buffered`/`flushed`/`expired`/`evicted`
   event mapping are untested. The PTY/Workspace wiring is reasonably dogfood-gated, but
   `logStdinLifecycle` is trivially unit-testable (call it → read back the dispatch log
   line → assert `handler="stdin"`, `outcome=...`). A 10-line test would lock the
   trace-visibility contract that the whole "never a silent drop" story depends on.
**Fix:** Confirm target membership; add the lifecycle-log assertion.

**[MINOR] CLI/c11.swift (#252, stacked on this branch) — Positional `%@` substitution breaks under placeholder reordering**
Out of strict C11-144 scope but it ships in the same branch and appears in the supplied
diff: the unverified-send error fills its three `%@` placeholders by repeatedly calling
`message.range(of: "%@")` and replacing left-to-right with `[envelope.id, to, envelope.id]`.
This is correct for the English source string but silently wrong for any localization
that reorders the placeholders — the values get bound by textual position, not by index.
**Fix:** Use indexed format arguments (`%1$@`, `%2$@`, `%3$@`) with
`String(format:locale:)`, or pass the recipient/id via a structured value rather than
hand-rolled `%@` splicing. (If `#251`/`#252` were already reviewed/merged under their own
PRs, fold this into that line instead.)

## 4. Positive Observations

- **The pure seam is exemplary.** `MailboxStdinBuffer` is a clock-injected value type with
  no PTY, no `Workspace` instance, and no ambient `Date.now` — so gating/buffer/flush is
  deterministically unit-testable. The tests exercise every state of `decide()`, FIFO
  drain, per-surface isolation, the freshness window *including the exact boundary*
  (`<=` is fresh), cap eviction (oldest-first, reported), `removeSurface`/`retainOnly`,
  and the empty-drain no-op. This is the right shape for the "settle it empirically later"
  parts to sit on.
- **Reuses existing machinery, no new lifecycle hook** — exactly the plan's constraint.
  Gating on the already-tracked `PanelShellActivityState` and flushing from the existing
  `updatePanelShellActivityState` transition is minimal and correct, and the flush is
  precisely gated by the pre-existing `previousState != state` guard.
- **"Never a silent drop" is real and observable.** Every lifecycle step
  (`buffered`/`flushed`/`expired`/`evicted`) is emitted as a `handler` event keyed on the
  same id/recipient, so `c11 mailbox trace <id>` shows the full path. The `buffered` event
  is logged inline by the dispatcher; the out-of-band steps go through `logStdinLifecycle`.
  The design consistently treats the filesystem inbox + `recv --drain` as the durable floor
  and the PTY as a best-effort doorbell.
- **Cleanup is thorough.** The buffer is pruned at all the right seams — surface teardown
  (both BonsplitDelegate paths), the `retainOnly` prune fast-path, and surface-not-terminal
  at flush time — so no buffer entries leak for dead surfaces.
- **Threading discipline observed.** Main-actor confinement removes the need for locks, and
  telemetry stays off the main thread via the log's async queue — consistent with the
  repo's socket-command threading policy.
- **Docs + skill are first-class, not an afterthought.** The mailbox guide gains a
  prompt-gated-delivery section, an updated sequence diagram, and an outcome table; the
  agent-facing skill reframes pull as the contract and push as the doorbell — and the
  installed skill copy was actually synced (the HARD RULE that has bitten this repo before).
