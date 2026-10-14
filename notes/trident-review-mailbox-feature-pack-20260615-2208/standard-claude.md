# Mailbox Feature Review — STANDARD lens (Claude)

Reviewed the mailbox primitive as it stands on `main` after PR #251 (cross-workspace routing + reject-on-zero). Read the full `Sources/Mailbox/*.swift`, the `CLI/c11.swift` send/resolve/recv paths, the `Sources/Workspace.swift` and `Sources/AppDelegate.swift` wiring, the `mailbox.resolve` socket method in `Sources/TerminalController.swift`, the docs, the schema, the skill, and the Swift tests.

**Bottom line up front:** this is a well-shaped, well-documented Stage-2 primitive. The pipeline does what it claims, the cross-workspace change is coherent and conservative (local-first preserves old behavior exactly), and the silent-drop fix is the right backstop. I found no correctness blockers. There are a handful of real-but-minor soundness gaps and a couple of contract/consistency divergences worth tightening before this is leaned on by 8–30 parallel agents.

---

## 1. Correctness & soundness

The core pipeline (`MailboxDispatcher.dispatchOne`, `MailboxDispatcher.swift:226-306`) is sound: atomic outbox→processing move, validate, resolve, the new reject-on-zero gate (`:281-288`), copy, handlers, cleaned. Dedupe via `recentlySeen` + ENOENT-on-move (`:229`,`:237-241`) correctly makes re-fired fsevents idempotent. Validation is genuinely careful — the NSNumber bool/double discrimination in `requireInteger` (`MailboxEnvelope.swift:331-349`) is the kind of edge most implementations get wrong, and it's covered.

The cross-workspace resolver (`MailboxGlobalResolver.resolve`, `MailboxSurfaceResolver.swift:169-194`) is a clean pure function with correct precedence: qualifier short-circuits, then local-first, then unique-remote, then ambiguous. Local-first is verified to win over a same-named remote (`testLocalMatchWinsOverRemoteSameName`).

### Important

- **`content_type` byte cap is declared but never enforced** (`MailboxEnvelope.swift:232-234`). The schema (`spec/mailbox-envelope.v1.schema.json:72-77`) and the guide table (`docs/c11-mailbox-guide.md:304`) both say `≤ 128 bytes`, but `validate` only calls `requireNonEmptyString` for `content_type` — no `ensureStringByteCap`. So a 5 KB `content_type` validates clean. Every other capped string field (`from`, `to`, `reply_to`, `topic`) gets `ensureStringByteCap`; `content_type` was missed. Low blast radius (it's an advisory hint), but it's a spec-vs-code divergence that a schema-conformance test would catch. Add the cap to match the schema, or relax the schema.

- **`--ttl-seconds` parse failures are swallowed silently** (`CLI/c11.swift:16743`). `optionValue(...).flatMap(Int.init)` means `--ttl-seconds abc` produces `nil`, and the envelope sends with no TTL at all — the operator typed an expiry and got none, with no error. Same shape risk exists wherever a numeric flag is `flatMap(Int.init)`'d. A `--ttl-seconds <nonint>` should be a hard CLI error, not a silent drop to `nil`.

- **`from`/`to`/`reply_to` accept up to 256 bytes but the inbox directory component caps at 64** (`MailboxLayout.maxSurfaceNameBytes = 64`, `MailboxLayout.swift:46`,`:147-149`). A recipient name 65–256 bytes validates, resolves (the resolver matches by exact title string with no length check), then `copyToInbox` (`MailboxDispatcher.swift:320-356`) throws inside `inboxURL`'s `validateSurfaceName`, gets caught, and logs a `_copy`/`eio` line — but the envelope still proceeds to handlers and `cleaned`. Net: stdin-PTY delivery succeeds, the inbox copy silently never lands, and the dispatch log shows `eio` rather than a rejection. This is an internally-inconsistent cap (256 for the wire field, 64 for the directory) producing a partial-delivery state. Either unify the caps or treat an un-inbox-able name as a `rejected`, not a half-success.

### Suggestions / observations (not bugs)

- The socket-unreachable fallback in `resolveMailboxTargetWorkspace` (`CLI/c11.swift:16868-16878`) silently returns the sender's own workspace. That's the documented behavior and the dispatcher rejection is the backstop, but the operator gets **no signal** that cross-workspace resolution was skipped — a send to a remote recipient will look like it succeeded (prints a ULID) and only later show up as a `rejected` event in the *sender's* log. A one-line stderr note ("socket unreachable; resolved same-workspace only") would close the surprise gap without changing behavior.
- `recentlySeen` is a flat `Array.contains` capped at 1024 (`MailboxDispatcher.swift:51-52`,`:481-491`). O(n) per dispatch is fine at Stage-2 volumes, and the cap bounds memory. No action; flagging only because the comment frames duplicates as "shouldn't happen" while the at-least-once contract guarantees they will.
- TOCTOU window between resolve (CLI socket call) and dispatch (recipient workspace's fsevent) is real and *correctly handled* — if the recipient closes in that window, the recipient workspace's dispatcher rejects with a sidecar. This is the intended design and worth calling out as a strength, not a flaw.

---

## 2. Design quality

The split is coherent and, importantly, **conservative**: cross-workspace delivery is achieved by the CLI writing into the recipient workspace's outbox so that workspace's existing per-workspace dispatcher delivers locally — no global dispatcher, no new long-lived cross-workspace state, and same-workspace behavior is provably unchanged (local-first). Synchronous resolution at the CLI (over the socket) + async delivery (via fsevents) is the right seam: resolution needs a consistent global snapshot, delivery doesn't.

Local-first as the default is the correct call for the dogfood workload — an agent addressing a sibling by a common name (`Reviewer`, `Builder`) should hit its own workspace first, and reaching across only when unambiguous matches operator intuition. Ambiguity-as-error (rather than broadcast or arbitrary-pick) is the safe default for a delivery primitive.

Filesystem-as-transport is clean and the atomic `.tmp → .msg` rename discipline is consistent everywhere (`MailboxIO.atomicWrite`, the bash example, the watcher's dot-prefix filter). The "filesystem is the contract, CLI is convenience" framing is honest and the parity test enforces it.

**Design tension worth naming for the mutation discussion:** recipient identity == mutable, non-unique `title` metadata. The whole addressing model rests on a field a user or agent can change at any moment, and the resolve→deliver window means the name can move between resolution and delivery. PR #251 makes this *more* load-bearing by resolving globally. For Stage 3 this is the thing most worth hardening — e.g., an optional stable mailbox alias decoupled from the display title — but it's a known tradeoff, not a defect in what shipped.

---

## 3. API / contract clarity

The CLI surface is learnable and the flag set maps cleanly onto the envelope. `--to-workspace` is a good disambiguator and the ambiguity error message lists candidate refs (`CLI/c11.swift:16896-16920`), which is exactly what an operator needs.

The envelope schema is a genuine single source of truth — `MailboxEnvelope.build` re-validates through the same `validate` path the dispatcher uses (`MailboxEnvelope.swift:291-297`), so senders can't construct something the dispatcher would reject. Good.

### Important

- **The `mailbox.resolve` socket response shape is asymmetric and a little surprising.** `unique` returns `target_workspace_id` + `target_workspace_ref` + `surface_ids` + `candidates`; `ambiguous`/`unresolved` return only `candidates` (`TerminalController.swift:8762-8790`). The CLI only consumes `target_workspace_id` and `candidates`, so this is fine in practice, but `surface_ids` is computed and returned and then ignored by the only caller — either it's a forward-looking field (document it) or dead payload (drop it). Minor, but a socket contract should not ship fields no one reads without a note saying why.
- The `resolution` discriminator defaults to "unresolved" on *any* unexpected value (`CLI/c11.swift:16880-16899`, the `default:` arm). That's a safe failure mode, but it means a future protocol addition (a new resolution kind) silently degrades to "message not sent" rather than erroring loudly about a version mismatch. Acceptable for now; worth a comment.

### Suggestion

- The dispatch-log `rejected` event uses a free-text `reason` string and the doc tells `trace` consumers to distinguish "malformed" from "unknown recipient" by the reason text (`MailboxDispatcher.swift:438-439`). String-matching on a human-readable reason is brittle. A structured `reason_code` (e.g. `validation_failed` vs `unresolved_recipient`) alongside the prose would make the log machine-parseable for the orchestrator workflows that are the primary consumers.

---

## 4. Consistency & fit

Fits c11 conventions well. The `mailbox.resolve` handler is registered in the v2 method table and the known-methods list (`TerminalController.swift:2888-2889`,`:3266`), uses the standard `v2String`/`v2UUID`/`v2Ref` helpers, and goes through `v2MainSync` to read `@Published panels` from main — consistent with the threading policy (this is a snapshot-query command, which the policy explicitly permits on main). It does not steal focus (read-only), consistent with the socket focus policy. The per-workspace dispatcher rides a `.utility` queue per the threading policy.

The skill (`skills/c11/SKILL.md:465-557`) and the guide (`docs/c11-mailbox-guide.md`) accurately describe the shipped code: cross-workspace routing, local-first precedence, reject-on-zero with `.err` sidecar, the `{stdin, silent}` handler set, the topic-only rejection, and the Stage-2 limits table all match the implementation. The lifecycle state diagram (`guide:225-245`) correctly shows the new `Resolved → Rejected` edge. This is unusually well-synced doc/code for a feature this young.

### Minor consistency notes

- Per the repo's own naming convention (CLAUDE.md: "c11, not CMUX — always"), the env-var reads still lead with the legacy name: `env["CMUX_WORKSPACE_ID"] ?? env["C11_WORKSPACE_ID"]` (`CLI/c11.swift:16691`,`:16705`). Dual-read is correct for compat, but the convention says author `C11_*` first. Cosmetic, but it's the documented house style.
- The `replayed` and `gc` log events and the `epipe`-removed note are all documented honestly. No drift there.

---

## 5. Test coverage

**Proven:** envelope validation edges (the `MailboxEnvelopeValidationTests` suite exists alongside the others), the happy-path dispatch sequence, invalid-envelope quarantine, the new unresolved-recipient rejection (`testUnresolvedRecipientIsRejectedNotSilentlyDropped`, `MailboxDispatcherTests.swift:209-266` — asserts no handler fires, `_rejected/` gets msg+err, log ends `received→resolved→rejected` with no `cleaned`), dedupe, GC sweep, IO atomicity, layout/surface-name validation, and the full `MailboxGlobalResolver` matrix (local-first, remote-unique, unknown, cross-workspace ambiguity, qualifier hit, qualifier miss — `MailboxSurfaceResolverTests.swift:147-240`). These are real behavioral tests, not shape assertions — they comply with the repo's test-quality policy.

I confirmed the Mailbox test files, though physically under `c11Tests/`, are members of the **`c11LogicTests`** target (verified against `project.pbxproj`), so the context's "c11LogicTests, safe to run locally" claim is accurate.

### Gaps (unproven)

- **The `v2MailboxResolve` socket handler itself is untested.** Tests cover the pure `MailboxGlobalResolver` and the dispatcher, but the glue in `TerminalController.v2MailboxResolve` (`:8714-8800`) — the workspace-qualifier translation (UUID-direct vs ref-string lookup vs unknown-ref→unresolved at `:8758-8772`), the response payload assembly, the `mailboxCandidatePayload` mapping — has no coverage. This is exactly where a routing regression would hide. A logic-target test that drives `v2MailboxResolve` with an injected surface list would close the highest-value gap.
- **No test exercises the actual cross-workspace write path end to end** (CLI resolves to a remote workspace → envelope lands in *that* workspace's outbox → its dispatcher delivers). The live-validation T1–T6 covered this manually on a tagged build, but there's no automated guard. Given this is the headline feature of #251, a Python socket test in `tests_v2/` against a tagged build's socket would be worth adding.
- **`content_type` cap, the 64-vs-256 name-length mismatch, and the malformed-`--ttl-seconds` swallow** (all Section 1) are each currently untested — which is precisely why they slipped.

---

## Merge / ship verdict

**Ship** — the feature is correct, coherent, honestly documented, and well-tested for what it claims; it's production-ready as the Stage-2 primitive it advertises. None of my findings are release blockers. Before it carries heavy multi-agent load, tighten the three Section-1 soundness gaps (enforce the `content_type` cap, fail loudly on a bad `--ttl-seconds`, and reconcile the 64-vs-256 name caps) and add coverage for `v2MailboxResolve` and one end-to-end cross-workspace path. The mutable-`title`-as-address model is the right thing to put under the microscope when planning the next mutation, not a reason to hold this one.
