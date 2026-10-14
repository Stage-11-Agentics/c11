# Mailbox Feature — STANDARD-lens Synthesis

*Synthesized from the Standard-lens reviews of the c11 mailbox feature pack (PR #251: cross-workspace routing + reject-on-zero).*

> **Coverage note:** This synthesis reflects **2 of 3 models** — Claude and Gemini. **Codex was unavailable** (usage cap) at review time, so the third Standard-lens input is absent. Treat consensus below as agreement between two models, not three.

---

## Executive Summary

Both Standard-lens reviewers independently land in the same place: the mailbox primitive is **structurally sound, conservatively designed, and honestly documented**, with **no correctness blockers**. They agree the cross-workspace design (CLI resolves global state over the socket; per-workspace dispatcher delivers locally via fsevents) is the right seam — it inherits cross-workspace delivery without a heavy global daemon or new long-lived state, and provably preserves same-workspace behavior. The reject-on-zero gate is endorsed by both as the correct backstop against silent blackholing.

The two reviews differ sharply in **depth and severity calibration**, not in conclusion. Claude conducted a deep audit and surfaced several genuine soundness gaps (uncapped `content_type`, silently-swallowed `--ttl-seconds`, a 64-vs-256 name-length mismatch causing partial delivery) plus contract/test-coverage gaps. Gemini ran a lighter pass, found the design excellent, raised only two minor code-hygiene suggestions, and explicitly recorded zero blockers and zero important issues. Where they overlap (design quality, threading-policy fit, debuggability, the local-first default), they agree strongly. Where Claude flags soundness gaps, Gemini is silent rather than dissenting — these are unique findings from a deeper read, not contested claims.

### Ship / Merge Verdict

1. **Both models: SHIP / MERGE.** The feature is production-ready as the Stage-2 primitive it advertises.
2. **As a production primitive:** ship now; the identified gaps are hardening items, not release blockers. Before the mailbox carries heavy multi-agent load (8–30 parallel agents), close Claude's three Section-1 soundness gaps and add the two highest-value test-coverage gaps (the `v2MailboxResolve` socket handler; one end-to-end cross-workspace path).
3. **Confidence caveat:** the merge verdict rests on two models, with the deeper of the two (Claude) explicitly conditioning long-term durability on tightening three named gaps. The absence of Codex means no third independent check on those gaps.

---

## 1. Consensus Issues (both models agree — highest confidence)

These are points where Claude and Gemini independently converged.

1. **No correctness blockers.** Both reviews explicitly state the core pipeline is sound and found zero release blockers. (Claude: "I found no correctness blockers"; Gemini: "Blockers: None.")
2. **Cross-workspace design is the right architecture.** Both praise the CLI-resolves-globally / per-workspace-dispatcher-delivers-locally split as clever and robust — it avoids a heavy global orchestrator daemon and complex IPC locking. (Claude §2; Gemini §2.)
3. **Local-first routing is the correct default.** Both call it exactly right: the sender's own workspace wins on a same-name collision, preventing "spooky action at a distance" when an operator launches two agents with the same name in different workspaces. (Claude §2; Gemini §2.)
4. **Reject-on-zero is the correct backstop.** Both endorse quarantining envelopes that resolve to zero recipients instead of silently dropping them. (Claude §1; Gemini §1.)
5. **Filesystem-as-transport fits the c11/unix ethos.** Both approve the atomic `.tmp → .msg` rename discipline and the fact that raw bash can participate without socket libraries. (Claude §2; Gemini §2.)
6. **Threading-policy compliance.** Both confirm the implementation respects the c11 threading policy — dedicated `.utility` queue for fsevents, bounded main-actor hops. (Claude §4: snapshot-query on main is permitted; Gemini §4: `.utility` queue + 2-second internal timeout in `invokeHandlerSynchronously`.)
7. **Strong operator debuggability.** Both highlight the `_dispatch.log` NDJSON shape and `.err` sidecar pattern as making the system highly debuggable via `c11 mailbox trace`. (Claude §3; Gemini §3.)
8. **Envelope schema as single source of truth.** Both treat the V1 envelope schema / `MailboxEnvelope` validate path as a solid, learnable contract. (Claude §3; Gemini §3.)
9. **Crash-recovery / `_processing/` sweep gap is an acceptable Stage-2 limit.** Both name it and both accept it as a documented trade-off, not a defect. (Claude §1 TOCTOU discussion; Gemini §5.)

---

## 2. Divergent Views (where they disagree — signal worth examining)

The disagreements are about **severity and depth**, not about facts. No factual claim from one model is contradicted by the other.

1. **Severity of the soundness gaps.** Claude rates three issues (`content_type` cap, `--ttl-seconds` swallow, 64-vs-256 name mismatch) as **Important** — real bugs to fix before heavy load. Gemini's deeper-audit equivalents are absent; it recorded **"Important: None."** This is the single biggest divergence: one model found a tier of issues the other did not surface at all. Because these are independently verifiable code facts (with file:line), they should be weighted toward Claude's read — Gemini's silence reads as non-coverage, not a counter-judgment.
2. **The `MailboxDispatcher.swift:231` re-encode.** Gemini's one substantive code finding (`(try? envelope.encode()) ?? Data()` fails open to empty `Data()`, could theoretically write 0-byte inbox files; reuse the `data` constant from line 197 instead). **Claude did not flag this.** Conversely, Claude's name-cap partial-delivery finding touches the same `copyToInbox` path but from a different angle (over-long names, not encode failure). The two models audited the copy path and each caught a different theoretical failure mode — together they cover more than either alone.
3. **Depth of the contract/test critique.** Claude devotes full sections to API-contract asymmetries (`mailbox.resolve` response shape, free-text `reason` strings) and to specific untested code paths. Gemini treats the contract as clean and the test tags (T1–T6) as sufficient. Divergence in scrutiny depth, not a factual conflict.

---

## 3. Unique Findings (raised by only one model)

### Claude-only

1. **`content_type` byte cap declared but never enforced.** Schema (`spec/mailbox-envelope.v1.schema.json:72-77`) and guide (`docs/c11-mailbox-guide.md:304`) say ≤ 128 bytes, but `validate` calls only `requireNonEmptyString` — no `ensureStringByteCap` — so a 5 KB `content_type` validates clean. Spec-vs-code divergence. (`MailboxEnvelope.swift:232-234`.)
2. **`--ttl-seconds` parse failures swallowed silently.** `optionValue(...).flatMap(Int.init)` turns `--ttl-seconds abc` into `nil`; the envelope sends with no TTL and no error. Should be a hard CLI error. Same risk anywhere a numeric flag is `flatMap(Int.init)`'d. (`CLI/c11.swift:16743`.)
3. **64-vs-256 name-length mismatch → partial delivery.** `from`/`to`/`reply_to` accept up to 256 bytes, but the inbox directory component caps at 64 (`MailboxLayout.maxSurfaceNameBytes = 64`). A 65–256-byte recipient validates and resolves, then `copyToInbox` throws inside `inboxURL`, gets caught, logs `_copy`/`eio` — but the envelope still proceeds to handlers and `cleaned`. Net: stdin-PTY delivery succeeds, inbox copy never lands, log shows `eio` not a rejection. Internally inconsistent cap producing a half-success. Unify the caps or treat an un-inbox-able name as `rejected`. (`MailboxLayout.swift:46`,`:147-149`; `MailboxDispatcher.swift:320-356`.)
4. **Socket-unreachable fallback gives no operator signal.** `resolveMailboxTargetWorkspace` silently returns the sender's own workspace when the socket is unreachable; a send to a remote recipient prints a ULID (looks successful) and only later shows as a `rejected` event in the *sender's* log. A one-line stderr note would close the surprise gap. (`CLI/c11.swift:16868-16878`.)
5. **`mailbox.resolve` response shape is asymmetric.** `unique` returns `target_workspace_id` + `target_workspace_ref` + `surface_ids` + `candidates`; `ambiguous`/`unresolved` return only `candidates`. `surface_ids` is computed and returned but ignored by the only caller — document it as forward-looking or drop it. (`TerminalController.swift:8762-8790`.)
6. **`resolution` discriminator defaults to "unresolved" on any unexpected value.** Safe failure mode, but a future protocol addition silently degrades to "message not sent" rather than erroring on version mismatch. Worth a comment. (`CLI/c11.swift:16880-16899`.)
7. **Free-text `reason` strings are brittle for machine consumers.** The doc tells `trace` consumers to distinguish "malformed" from "unknown recipient" by reason text. A structured `reason_code` (e.g. `validation_failed` vs `unresolved_recipient`) alongside the prose would make the log parseable for the orchestrator workflows that are the primary consumers. (`MailboxDispatcher.swift:438-439`.)
8. **Naming-convention nit: env reads lead with legacy name.** `env["CMUX_WORKSPACE_ID"] ?? env["C11_WORKSPACE_ID"]` — dual-read is correct for compat, but house style (CLAUDE.md: "c11, not CMUX — always") says author `C11_*` first. Cosmetic. (`CLI/c11.swift:16691`,`:16705`.)
9. **Test-coverage gaps:** the `v2MailboxResolve` socket handler is entirely untested (`TerminalController.swift:8714-8800`) — the qualifier translation, response assembly, and `mailboxCandidatePayload` mapping, exactly where a routing regression would hide; no automated end-to-end cross-workspace write-path test (only manual T1–T6); and the three Section-1 gaps are each untested, which is why they slipped.
10. **Confirmed strengths worth preserving:** the resolve→deliver TOCTOU window is real and *correctly handled* (recipient workspace's dispatcher rejects with a sidecar if the recipient closes in the window); the Mailbox test files are genuinely members of `c11LogicTests` (verified against `project.pbxproj`), so they are safe to run locally; the doc/code sync is unusually tight for a feature this young.

### Gemini-only

1. **`MailboxDispatcher.swift:231` re-encode fails open to empty `Data()`.** `let envelopeBytes = (try? envelope.encode()) ?? Data()` could theoretically write 0-byte files into recipient inboxes. The dispatcher already loaded the raw valid `Data` at line 197; passing that straight through to `copyToInbox` is safer and more efficient. (Suggestion.)
2. **`rejectUnresolved` and `quarantine` are duplicated.** Both methods perform the same ~5 lines of directory-creation and file-moving (`MailboxDispatcher.swift:377` and `:396`); collapse into one utility. (Suggestion.)
3. **`ext` as open `[String: Any]`** is called out positively — allows organic metadata extension. (Observation, not an issue.)

---

## 4. Consolidated Findings (deduplicated, by severity)

### Blockers

1. **None.** Both models agree there are no release blockers.

### Important (close before heavy multi-agent load — all Claude-sourced; Gemini did not contradict)

1. **Enforce the `content_type` byte cap** to match the schema's ≤ 128 bytes, or relax the schema. (`MailboxEnvelope.swift:232-234`; `spec/mailbox-envelope.v1.schema.json:72-77`.)
2. **Fail loudly on a malformed `--ttl-seconds`** instead of silently dropping to no-TTL; audit other `flatMap(Int.init)` numeric flags for the same pattern. (`CLI/c11.swift:16743`.)
3. **Reconcile the 64-vs-256 name-length caps** so an un-inbox-able recipient is a clean `rejected` rather than a partial delivery that logs `eio`. (`MailboxLayout.swift:46`,`:147-149`; `MailboxDispatcher.swift:320-356`.)
4. **`mailbox.resolve` response asymmetry:** document `surface_ids` as forward-looking or drop it (currently computed and ignored by the only caller). (`TerminalController.swift:8762-8790`.)

### Suggestions

1. **Stop re-encoding the envelope at dispatch.** Reuse the `data` constant from `MailboxDispatcher.swift:197` instead of `(try? envelope.encode()) ?? Data()` at `:231` — removes the fail-open-to-empty-file risk and a redundant encode. *(Gemini.)*
2. **Deduplicate `rejectUnresolved` and `quarantine`** into a single move-and-quarantine utility. (`MailboxDispatcher.swift:377`,`:396`.) *(Gemini.)*
3. **Emit a one-line stderr note when the socket is unreachable** during resolution ("socket unreachable; resolved same-workspace only") so a cross-workspace send doesn't look like a success. (`CLI/c11.swift:16868-16878`.) *(Claude.)*
4. **Add a structured `reason_code`** alongside the free-text `reason` in `rejected` log events for machine-parseable orchestrator consumption. (`MailboxDispatcher.swift:438-439`.) *(Claude.)*
5. **Comment the `resolution` "unresolved" default arm** to flag that a future protocol kind would silently degrade rather than error on version mismatch. (`CLI/c11.swift:16880-16899`.) *(Claude.)*
6. **Lead env-var reads with `C11_*`** per house style (cosmetic; dual-read stays for compat). (`CLI/c11.swift:16691`,`:16705`.) *(Claude.)*

### Test-coverage additions (Claude-sourced; highest value first)

1. **Cover `v2MailboxResolve`** with a logic-target test driving an injected surface list — qualifier translation, response assembly, candidate mapping. Highest-value gap; where a routing regression would hide. (`TerminalController.swift:8714-8800`.)
2. **Add one automated end-to-end cross-workspace path** — a Python socket test in `tests_v2/` against a tagged build (CLI resolves to remote → envelope lands in that workspace's outbox → its dispatcher delivers). This is the headline feature of #251 and currently has only manual T1–T6 coverage.
3. **Add regression tests for each Section-1 gap** (`content_type` cap, 64-vs-256 name mismatch, malformed `--ttl-seconds`) — their absence is precisely why the gaps slipped.

---

## Closing Note

The two available Standard-lens models agree on the verdict (**SHIP / MERGE**) and on every point where their scrutiny overlapped. Their disagreement is one of depth: Claude's deeper audit surfaced a tier of soundness and coverage gaps that Gemini's lighter pass did not reach, and the two caught different failure modes on the same copy path — making their findings complementary rather than conflicting. With Codex absent, there is no third independent check on Claude's Important-tier gaps; weight them accordingly when prioritizing the post-merge hardening pass.
