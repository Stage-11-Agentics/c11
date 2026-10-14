# Action-Ready Synthesis: Mailbox Feature

*Synthesized from 6 trident reviews (standard/critical/evolutionary × Claude/Gemini). Codex was capped, so this reflects **2 of 3 models**, not 3. Every "Apply by default" item below was cross-checked against the live source (`Sources/Mailbox/*.swift`, `CLI/c11.swift`, `spec/mailbox-envelope.v1.schema.json`) and is either raised by 2+ reviewers or confirmed by direct file:line inspection.*

## Verdict

**harden-then-trust** — The same-workspace path and the envelope/validation layer are genuinely solid (no correctness blocker found by any reviewer), and the #251 cross-workspace + reject-on-zero change is the right increment. But the cross-workspace seam ships with three converged-upon observability/silent-failure gaps (TOCTOU mis-route, sender-blind `trace`/`tail`, socket-down doomed send) that erode trust in exactly the 8–30-agent unattended workload it's built for. Ship the low-risk hardening below; route the structural items to the operator.

---

## Apply by default (validated, low-risk, in-scope hardening)

### B1 — `trace`/`tail` are structurally blind to cross-workspace delivery
- **Location:** `CLI/c11.swift:16982` (`runMailboxTraceCommand`) and `CLI/c11.swift:17006` (`runMailboxTailCommand`) — both read `dispatchLogURL(state:workspaceId:)` for the **caller's** workspace via `resolveMailboxCaller`.
- **Problem:** A cross-workspace send writes the envelope into the *recipient's* outbox; all lifecycle events (`received`/`resolved`/`copied`/`handler`/`rejected`/`cleaned`) are logged by the recipient's per-workspace dispatcher into the **recipient's** `_dispatch.log`. `c11 mailbox trace <id>` from the sender returns **empty** for every cross-workspace send — successful or rejected. The operator's primary diagnostic is useless for the headline feature.
- **Fix:** Make `trace`/`tail` cross-workspace-aware. Simplest path that closes it: have `runMailboxSendCommand` emit a sender-side `sent` event recording the target workspace id, so `trace` can chain to the recipient's log; or have `trace` re-resolve `--to`/the id's target workspace and read that log too. Verified the events are per-workspace (`MailboxDispatcher.log`).
- **Sources:** critical-claude (F2, "CERTAIN — structural"), critical-gemini ("Split-brain trace logs", "Guaranteed on cross-workspace errors"). 2 reviewers + code-confirmed.

### B2 — Socket-down fallback writes a guaranteed-doomed cross-workspace envelope, exits 0
- **Location:** `CLI/c11.swift:16868-16872` (`resolveMailboxTargetWorkspace` catch arm returns `senderWorkspaceId`).
- **Problem:** When `mailbox.resolve` throws (socket unreachable — CLAUDE.md/C11-105 documents this happening while the app is alive), the send falls back to the sender's own workspace. If the real recipient is elsewhere, the sender's dispatcher resolves to nobody and rejects into the **sender's** `_rejected/` — but the CLI already printed a ULID and exited **0**. From the operator's seat this is a silent drop during a documented real failure mode.
- **Fix:** When the socket is unreachable **and** `--to` cannot be locally confirmed, fail the send (non-zero) with a clear "could not resolve recipient (socket unreachable); message not sent" rather than writing a doomed envelope. Same-workspace sends where the name resolves locally can still proceed. (Pairs with B1: even the rejection it produces is invisible to the sender today.)
- **Sources:** critical-claude (F3), critical-gemini ("Socket unreachability fallback masks ambiguity"), standard-claude (flagged the same swallow as a surprise gap). 3 reviewers + code-confirmed.

### I1 — `content_type` byte cap declared in schema but never enforced
- **Location:** `Sources/Mailbox/MailboxEnvelope.swift:232-234` (validate) vs `spec/mailbox-envelope.v1.schema.json:72-76` (`maxLength: 128`).
- **Problem:** Every other capped string field (`from`, `to`, `reply_to`, `topic`) gets `ensureStringByteCap`; `content_type` only gets `requireNonEmptyString`. A 5 KB `content_type` validates clean — a spec-vs-code divergence. Confirmed: `maxStringFieldBytes = 256`, schema says 128, validator caps neither.
- **Fix:** Add `try ensureStringByteCap(contentType, field: "content_type")` (and reconcile the 256 vs 128 number against the schema — pick one). Low blast radius (advisory hint), but a schema-conformance test would have caught it.
- **Sources:** standard-claude (Important), evolutionary-claude (§6 "audit the validator's job"). 2 reviewers + code-confirmed.

### I2 — `--ttl-seconds` parse failure is silently swallowed to `nil`
- **Location:** `CLI/c11.swift:16743` — `optionValue(subArgs, name: "--ttl-seconds").flatMap(Int.init)`.
- **Problem:** `--ttl-seconds abc` produces `nil`; the envelope sends with **no TTL**. The operator typed an expiry and got none, with no error. (Note: TTL is advisory/unenforced anyway, so impact is "operator surprise," not data loss — but the silent-parse pattern is the real defect.)
- **Fix:** Make a non-integer `--ttl-seconds` a hard CLI error. Audit other numeric flags using the same `flatMap(Int.init)` shape.
- **Sources:** standard-claude (Important), code-confirmed (single-reviewer but obvious at the cited line).

### I3 — Inbox name caps are internally inconsistent (256 wire vs 64 dir) → partial-delivery state
- **Location:** `Sources/Mailbox/MailboxEnvelope.swift:20` (`maxStringFieldBytes = 256`) vs `Sources/Mailbox/MailboxLayout.swift:47,147` (`maxSurfaceNameBytes = 64`).
- **Problem:** A `to` of 65–256 bytes validates and resolves, then `copyToInbox` (`MailboxDispatcher.swift:320-356`) throws inside `inboxURL`'s name validation, is caught, and logs a `_copy`/`eio` line — **but dispatch still proceeds to handlers and `cleaned`**. Net: stdin-PTY delivery succeeds while the inbox copy silently never lands; the log shows `eio` instead of a rejection. An internally-inconsistent cap producing a half-success.
- **Fix:** Unify the caps (cap the wire `to`/`from`/`reply_to` at the same 64-byte ceiling the inbox dir enforces, the simplest reconciliation), **or** treat an un-inbox-able name as a `rejected` rather than a logged-but-continued half-delivery.
- **Sources:** standard-claude (Important), code-confirmed (single-reviewer but obvious by reading the two constants + the catch arm).

### M1 — `v2MailboxResolve` socket glue is untested (highest-value coverage gap)
- **Location:** `Sources/TerminalController.swift:8714-8800` (handler), tests only cover the pure `MailboxGlobalResolver` and the dispatcher.
- **Problem:** The qualifier translation (UUID-direct vs ref-string lookup vs unknown-ref→unresolved), the response-payload assembly, and `mailboxCandidatePayload` have no coverage — exactly where a routing regression would hide.
- **Fix:** Add a `c11LogicTests` test driving `v2MailboxResolve` with an injected surface list (the resolver is already injectable). Optionally a `tests_v2/` Python socket test against a tagged build for one end-to-end cross-workspace write path.
- **Sources:** standard-claude (Test coverage gap). Single-reviewer but a concrete, low-risk addition consistent with the repo's test-quality policy.

### M2 — Collapse `rejectUnresolved` and `quarantine` duplication
- **Location:** `Sources/Mailbox/MailboxDispatcher.swift:440` (`rejectUnresolved`) and `:462` (`quarantine`).
- **Problem:** Both perform the identical 5-line dir-create + move-to-`_rejected` + `.err`-sidecar write, differing only in the `reason` string and the log event variant. Confirmed near-identical by inspection.
- **Fix:** Extract a shared `private func writeRejected(id:processingURL:reason:event:)` helper. Purely mechanical, no behavior change.
- **Sources:** standard-gemini (Suggestion). Single-reviewer + code-confirmed; trivially safe.

### M3 — Remove the `watch` subcommand stub
- **Location:** `CLI/c11.swift:16632-16633` — `case "watch": throw CLIError(... "watch not implemented in Stage 2; see c11 mailbox tail ...")`.
- **Problem:** A subcommand that exists only to error is a worse experience than no subcommand. The design's three-handler vision collapses cleanly to `stdin`/`silent` + `tail` for streams.
- **Fix:** Either delete the `case "watch"` arm (let it fall to the unknown-subcommand error) or alias it to `tail`. Confirmed it is a throw-only stub.
- **Sources:** evolutionary-claude (§6). Single-reviewer + code-confirmed; trivial.

> **Not applied (raised but does not survive cross-check):** standard-gemini's "reuse `data` from line 197 instead of `(try? envelope.encode()) ?? Data()`" (`MailboxDispatcher.swift:291`). The `?? Data()` fallback is real, but `encode()` re-serializes the *validated* envelope (canonical form) rather than the raw on-disk bytes; swapping to raw `data` changes inbox-copy semantics subtly. Worth considering but **surface, don't silently apply** — it's an efficiency/correctness tradeoff, not a clear win. (Listed here for traceability; see S5.)

---

## Evolution roadmap (validated direction, NOT silent applies)

*Both models' evolutionary lenses converged hard on the same two-part root. These are direction, not edits.*

### E1 — Stable address alongside the mutable `title` (★ top leverage)
- **What it unlocks:** Recipient identity today == the surface `title`, which is user/agent-mutable and non-unique (`MailboxSurfaceResolver`, `AppDelegate.mailboxAddressableSurfaces`). The global CLAUDE.md *mandates* tab-renaming as an agent's first action — so the bus silently partitions every time an agent renames itself, and reply chains addressed to `delegator-3` rejects-unresolved the moment it retitles. A stable address (either a directly-addressable `surface:<ulid>` form, or a `mailbox.address`/`mailbox.role` metadata key that wins over `title` when set) removes the single most insidious *silent* partition and is the prerequisite for every downstream reliability mutation. Also underwrites the TOCTOU mis-route risk (F1): titles being mutable + non-unique is what lets a recycled surface inherit a name between resolve and dispatch.
- **Rough cost:** Small. The resolver already enumerates surfaces and reads metadata; add one key lookup with title-fallback in `MailboxGlobalResolver.resolve`. CLI gains a `surface:<ulid>` qualifier mirroring existing `workspace:*` parsing. No envelope-schema change (`to` is already an opaque string). Backward-compatible.
- **Leverage rank:** #1 — cheapest change that kills the most silent failures.
- **Sources:** evolutionary-claude (LEVERAGE #1), evolutionary-gemini (#1), standard-claude (design tension §2), critical-claude (F1 root cause). All converge.

### E2 — Liveness as a first-class signal: presence + monitor (★ second leverage)
- **What it unlocks:** The mailbox *delivers* but cannot make a stochastic LLM actor *process* — "doorbell, not delivery." For 8 agents the operator's eyes are the supervisor; for 30 agents overnight there is none, so a recipient that's dead/quiet/never-reads is an invisible deadlock. Two sub-pieces: (a) **presence** — surface the data `mailbox.resolve` already computes as a queryable `c11 mailbox who` / `resolve --to <name>` so a sender can check "is my recipient alive?" before blocking on a reply; (b) **monitor / dead-letter-on-close** — emit a `recipient_closed` `_dispatch.log` event (and eventually an Erlang-style synthetic `'DOWN'` `<c11-msg>`) when a surface with an outstanding correlation closes. This is the jump from "interesting structure I dogfood" to "infrastructure I trust unattended."
- **Rough cost:** Medium. Presence (a) is nearly free (exposing existing data). Monitor (b) needs correlation/close-hook tracking — start with the log event, defer the synthetic `'DOWN'`. Honest caveat both reviewers flag: "PTY exists" ≠ "agent will respond" — don't oversell presence.
- **Leverage rank:** #2 — the one capability that makes the 30-agent unattended case legible.
- **Sources:** evolutionary-claude (LEVERAGE #2, "the single most important mutation" alongside E1), evolutionary-gemini (#4 ack/recovery, supervision in §2). Converge.

### E3 — Out-of-band / side-channel delivery (decouple from PTY paste)
- **What it unlocks:** `stdin` delivery pastes `<c11-msg>` + Return into a live PTY — undefined for cooked-mode shells, and racy if the agent is mid-command or in a TUI (vim/fzf). A dedicated control socket or named pipe the agent tails would let agents receive reliably while working. (Gemini calls this its #1/#2; Claude is more sanguine — see the disagreement note in S1.)
- **Rough cost:** Medium-high; touches the delivery handler contract and the agent-side read convention.
- **Leverage rank:** #3 — high unlock, but contested as to urgency (the receiver-declared `mailbox.delivery` already lets a surface opt out of PTY writes).
- **Sources:** evolutionary-gemini (top mutation, both halves), critical-gemini (PTY corruption), evolutionary-claude (treats PTY-as-doorbell as *acceptable* for the handoff 80% case).

### E4 — Topic / role-broadcast fan-out
- **What it unlocks:** Broadcast without the sender enumerating recipients ("all delegators, abort"; overwatch "report status"). Both models note the operator will want **push-to-role** (`--to @delegators` → every surface with `mailbox.role=delegator`) more than the planned pull-shaped topic-subscribe. Role addressing is *cheaper* than glob topics and arguably ships first as the 80% case.
- **Rough cost:** Medium, mostly already scoped for Stage 3; rides the same dispatch-time-resolution machinery.
- **Leverage rank:** #4.
- **Sources:** evolutionary-claude (#3), evolutionary-gemini (#3). Converge on role-over-topic.

### E5 — `_processing/` crash-recovery sweep
- **What it unlocks:** Closes the documented at-least-once crash-window hole (a dispatcher killed between processing-move and inbox-copy strands the envelope forever; `start()` scans only `_outbox`, never `_processing`). Matters for the overnight/reload case. Receivers dedupe by id, so redelivery is safe by construction.
- **Rough cost:** Small (~20 lines, design already specifies it).
- **Leverage rank:** #5 — real but narrow window (move→copy is microseconds; the inbox copy carries durability).
- **Sources:** evolutionary-claude (#4), evolutionary-gemini (#4), critical-claude (F8, Stage-2-acknowledged). Converge.

---

## Surface to user (do not apply silently)

### S1 — Disagreement: is the PTY-paste `stdin` handler a liability or the right primitive?
Gemini (both critical + evolutionary) treats `stdin` PTY-pasting as a near-fatal design flaw ("fragile bash-script parlor trick," predicts operators abandon it within 3 months). Claude treats "doorbell, not delivery" as an *intentional, acceptable* contract for the 80% handoff case, given receiver-declared `mailbox.delivery` opt-out. This is a genuine architectural fork (→ E3) the operator must adjudicate, not an apply.

### S2 — Mutable/non-unique `title` as the address, and the cross-workspace TOCTOU (F1)
The deepest structural tension every lens named. PR #251 makes `title` *more* load-bearing by resolving globally; under churn a recipient can be renamed/closed/recycled between CLI-resolve and recipient-dispatch, causing silent loss **or mis-delivery to a recycled same-named surface**. The fix is E1 (stable address), which is a design decision with schema/CLI-surface implications — surface it, don't bolt on a point patch.

### S3 — Security/integrity posture: forgeable `from`, semantic prompt-injection, framed-block-as-RCE
`from` is sender-attested and unverified (any agent can forge `from="orchestrator"`); the framed body is submitted as one operator-equivalent turn to the recipient agent (semantic injection — the XML-escaping defends the *frame*, not the *agent*). critical-claude rates this LOW today (trusted single-user fleet) but a hard blocker for any cross-host/less-trusted future (→ blocks E-cross-host). This is a "document the trust model loudly + decide the threat boundary" call for the operator, not a silent code change.

### S4 — Scope-expanding evolution candidates (name, don't build)
Cross-host/tailnet bridge (Atlas↔Hyperion — reopens the deferred auth model, high risk), the `<c11-msg>` block as a **standalone provider-neutral wire protocol** (both models' "wildest" — near-free doc-and-a-name, largest surface area), content-addressed log as shared swarm memory, sender-visible receipt/ack primitive, mailbox-as-human↔swarm seam, observability dashboard. All deliberately deferred by the reviewers themselves; flagged for the operator's roadmap, not this pass.

### S5 — Gemini's "stop re-encoding the envelope" suggestion
`MailboxDispatcher.swift:291` `(try? envelope.encode()) ?? Data()` could in theory write a 0-byte inbox file. But `encode()` emits the canonical validated form, not the raw on-disk bytes — swapping to the raw `data` constant changes copy semantics subtly. Worth a deliberate decision (guard the empty-encode failure path vs. pass raw bytes through), not a silent apply.

### S6 — Gemini's "require explicit `--to-workspace` always; drop local-first"
evolutionary-gemini calls the local-first/single-remote/ambiguous precedence "too clever." Claude (standard + evolutionary) argues local-first is *exactly right* for the dogfood workload (an agent addressing a sibling by a common name should hit its own workspace first). Direct disagreement on a shipped, tested behavior — operator's call, not an apply.

### S7 — `body_ref` accepted-but-not-read-through
Validated for shape, never read; a `body_ref`-only envelope delivers an empty body to the agent with no warning (Stage-2-known, but silently lossy). evolutionary-claude: "finish it or stop validating it as if c11 owns it." A scope/design decision, not a bug fix.

### S8 — Lower-severity items logged but not validated as apply-now
`recentlySeen` O(n)/1024-cap dedupe leakiness + id-reuse silent-drop (critical-claude F6, critical-gemini §1); unbounded `_dispatch.log` + `_rejected/` growth over long sessions (critical-claude F5 — *not* on the Stage-2 list); double resolution work on main actor (F9); `mailbox.resolve` asymmetric response shape returning unused `surface_ids` (standard-claude); free-text `reason` string the docs ask `trace` to string-match (standard-claude — a structured `reason_code` would help). Each is real but either narrow or design-shaped; batch for the operator's review rather than silent application.

---

*Cross-check method: B1, B2, I1, I2, I3, M2, M3 confirmed by direct file:line inspection of the cited lines. M1 is a coverage gap confirmed by absence of any `v2MailboxResolve` test. E1/E2 are the convergence point of all four evolutionary/design passes across both models.*
