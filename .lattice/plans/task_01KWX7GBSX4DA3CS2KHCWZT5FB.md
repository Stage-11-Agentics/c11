# C11-163: Events stream — NDJSON event log, v1 taxonomy, rotation, `c11 events tail`

**Ticket:** C11-163 · Wave 2 · SPEC IDs EVT-1..EVT-8 · depends_on C11-159 (dispatcher extraction).
**Phase when written:** PLANNING ONLY (wave barrier holds; C11-159 not yet merged). This plan is written against the **post-extraction** layout on branch `ts/dx-dispatcher-extraction` and will be re-validated against merged `origin/main` at RESUME.
**Validation bar:** tagged build (`evt-post`) + recorded live scenario proof; CI green is necessary, not sufficient.

---

## 1. Approach & architecture

The design is deliberately a **near-clone of the existing mailbox dispatch log** (`Sources/Mailbox/MailboxDispatchLog.swift` + `Sources/Mailbox/MailboxLayout.swift`), which is already "append-only NDJSON, off-main, non-blocking, fire-and-forget through a serial `.utility` queue, with a shared pure path-builder compiled into both the app and CLI targets." That prior art de-risks EVT-1/3/6 almost entirely; the only genuinely new muscle is **size-capped rotation** (EVT-4) and the **`events` CLI subcommand** (EVT-5), for which the mailbox `tail`/`trace` runners are close templates.

Four new components, all under a new `Sources/Events/` directory plus one CLI extension:

1. **`EventEnvelope` (pure, dual-target).** The value type + serializer for one event. Fields per EVT-1: `seq` (monotonic uint64, per-instance), `ts` (ISO-8601 UTC, fractional seconds), `type` (dotted taxonomy string), subject refs (`workspace`/`surface`/`pane` UUIDs, each optional), `payload` (type-specific dict), plus `instance` (per-process boot id) and `v: 1` (schema version). Serialized with `JSONSerialization` `[.sortedKeys, .withoutEscapingSlashes]`, nil fields omitted, snake_case keys — matching `MailboxDispatchLog.serialize` conventions exactly. Pure Foundation, no app imports, so the CLI reader can decode it.

2. **`EventLogLayout` (pure, dual-target).** Path builders mirroring `MailboxLayout`: state root via `FileManager…applicationSupportDirectory` + `"c11"` (duplicated constant + `StateDirectoryMigration.ensureMigrated()` call, per the house convention), and builders for the events dir `<state>/events/` and the current/rolled log paths. Compiled into **both** the app target and the `c11-cli` target (dual pbxproj membership, exactly like `MailboxLayout.swift`).

3. **`EventLog` (app-only) — the writer.** Clone of `MailboxDispatchLog`: serial `.utility` `DispatchQueue`, lazy persistent `FileHandle`, `append(envelope)` serializes on the caller thread then `queue.async` writes; `flush()` via `queue.sync {}` for tests/shutdown; silent failure drops the handle for retry. **seq is assigned on the queue** (strict ordering, no races). Adds two things the mailbox log lacks:
   - **Rotation (EVT-4):** inside the queue write, after append, check `fileHandle.offset()` against a size cap (default e.g. 8 MiB, injectable). On exceed: close, delete `events.ndjson.1` if present, `FileManager.moveItem` `events.ndjson` → `events.ndjson.1` (single `rename(2)`, the house atomic-rename idiom), reopen fresh, and write a synthetic `log.rotated` marker line as the first record so consumers detect rotation. ≥1 rolled generation retained.
   - **Bounded backpressure (EVT-3 hardening):** a coarse in-flight cap on the queue; if a stuck/full disk backs the queue past N pending, drop-oldest and increment a counter surfaced via a periodic `log.dropped` event. Guarantees "full disk never stalls" is provable, not just asserted — the emitter never blocks regardless of disk state.

4. **`EventEmitter` (app-only) — the facade.** `EventEmitter.shared`, thread-safe `emit(type:workspace:surface:pane:payload:)` callable from **any** thread (main-actor emit sites and off-main store/dispatcher queues alike — the writer owns all threading). Owns the `EventLog`, resolves the path via `EventLogLayout` on first use, and mints the per-process `instance` id (a boot ULID via `MailboxULID`) at startup. A global enable flag (default on; tests inject a temp dir + explicit enable). Emits a `log.opened` marker at app launch carrying `instance` — this is the seq-reset boundary that makes per-instance semantics + rotation detectable together. Exposes `flush()`.

**CLI reader (`c11 events tail`).** A new `events` subcommand dispatched in the **pre-socket** block of `cli/c11.swift` (alongside `state verify`), so it works with **no running app** — it reads the file directly, the file is the contract. Inner `switch commandArgs.first { case "tail": … }`. Reuses the 250 ms size-poll follow loop from `runMailboxTailCommand` and the NDJSON line-filter/sort from `runMailboxTraceCommand`, but skips all socket/`resolveMailboxCaller` machinery. Adds a **non-follow one-shot mode** + clean exit (which neither mailbox runner offers) so it's testable and scriptable.

**Why file-first, no socket, no subscribe channel:** SPEC EVT-5 ("sugar over the file; any process may consume it directly") and the cycle's explicit out-of-scope ("socket subscribe channel for events — file-first only"). The socket is untouched by this ticket except that some emit sites happen to sit downstream of socket commands.

---

## 2. Approach per SPEC ID

- **EVT-1 (NDJSON envelope + fields):** `EventEnvelope` + `EventLog.append`. Each line carries `seq`, `ts`, `type`, optional `workspace`/`surface`/`pane`, `payload`, `instance`, `v`. Path `<state>/events/events.ndjson`.
- **EVT-2 (v1 taxonomy):** wire `EventEmitter.emit(...)` at the transition sites mapped in §3. Types: `surface.created`, `surface.closed`, `workspace.selected`, `metadata.changed` (payload carries key, value, prior, **source tier**), `liveness.derived` (**TEL seam** — see §6), `waiting.entered`/`waiting.left`, `mailbox.accepted`/`mailbox.delivered`. (Bonus, low-cost: `surface.lifecycle` for throttle/hibernate transitions from `SurfaceLifecycleController` — include only if free.)
- **EVT-3 (off-main, non-blocking):** `append` never blocks the caller (cheap serialize + `queue.async`). A stuck/full disk backs up only the writer's private queue; the bounded-drop guard caps memory. Emit sites that are already off-main (metadata stores, mailbox dispatcher) add only a small dict build to their existing queues.
- **EVT-4 (rotation):** size-cap + `events.ndjson.1` roll + `log.rotated` marker, described above.
- **EVT-5 (`c11 events tail`):** `--follow`, `--filter type=…`, `--since <seq|duration>`. `--filter` matches the `type` field; `--since` accepts a seq number or a duration (e.g. `10m`) resolved against `ts`. One-shot (no `--follow`) prints matching lines and exits.
- **EVT-6 (<1s latency):** writer flushes each line to the FileHandle immediately (page cache); CLI polls at 250 ms → comfortably <1s end-to-end. Measured on the tagged build.
- **EVT-7 (recorded consumer-reacts demo):** scenario harness + recording (§5).
- **EVT-8 (schema + skill):** `spec/event-envelope.v1.schema.json` + `spec/fixtures/events/` + `spec/README.md` update; `skills/c11/references/events.md` (new) documenting file location, schema, taxonomy, CLI, linked from `SKILL.md`; `scripts/sync-installed-skills.sh c11`.

---

## 3. File-level change map (post-extraction layout)

**New files:**
- `Sources/Events/EventEnvelope.swift` — value type + serializer. *Dual target membership (app + `c11-cli`).*
- `Sources/Events/EventLogLayout.swift` — pure path builders. *Dual target membership (app + `c11-cli`).*
- `Sources/Events/EventLog.swift` — writer + rotation + bounded drop. *App target.*
- `Sources/Events/EventEmitter.swift` — `.shared` facade, instance id, enable flag, `flush()`. *App target.*
- `spec/event-envelope.v1.schema.json` — JSON Schema (draft 2020-12), `$id` under `stage11.ai/schemas/`.
- `spec/fixtures/events/valid-*.json`, `invalid-*.json` — parity/validation fixtures (each invalid violates exactly one rule).
- `skills/c11/references/events.md` — events reference doc.
- Test files (see §4): `c11LogicTests/EventLogTests.swift`, `EventEnvelopeTests.swift`, `EventLogRotationTests.swift`, `EventEmitterOffMainTests.swift`, `EventLogLayoutTests.swift`; `tests_v2/test_events_parity.py`.

**Edited files (emit-site wiring, from the confirmed map):**
- `Sources/Workspace.swift` — **surface.created** at the ~5 panel-insertion sites (`init` seed ~L5822; `newTerminalSplit` ~L8096/8187; `newBrowserSplit` ~L8283/8370; `newMarkdownSplit` ~L8426/8480; restore `createPanel(from:inPane:)` ~L912; reattach ~L9000). Prefer a single private `emitSurfaceCreated(_ panel:)` helper called from each, to avoid drift. **surface.closed** — one emit in the bonsplit close funnel `splitTabBar(_:didCloseTab:fromPane:)` teardown at ~L11314 (before/at `panels.removeValue`). Main-actor.
- `Sources/TabManager.swift` — **workspace.selected** in `selectedTabId.didSet`, after the `guard selectedTabId != oldValue` dedupe (~L893); payload carries old/new workspace id. Main-actor.
- `Sources/SurfaceMetadataStore.swift` — **metadata.changed** at the two commit points inside the serial queue: `setMetadataLocked` (~L655) and `setInternal` (~L575), gated on the actual-mutation condition (the same signal that bumps `metadataStoreRevision`) **and** on the key being canonical (`status`/`title`/`description`/`progress` at minimum; extend to the `MetadataKey` canonical set). Payload: key, new value, prior value (available in `WriteResult.priorValues`), source tier. Off-main.
- `Sources/PaneMetadataStore.swift` — same as above for pane-scoped canonical metadata (`setMetadataLocked` ~L306, `setInternal` ~L224). Off-main. (Include if pane canonical keys are in v1 scope; otherwise note as deferred.)
- `Sources/TerminalNotificationStore.swift` — **waiting.entered/left** on the per-surface `unreadCountByTabId` edge: rising 0→1 in `addNotification` (~L902), falling 1→0 in `markRead*` (~L912–950). Main-actor.
- `Sources/Mailbox/MailboxDispatcher.swift` — **mailbox.accepted** alongside `log.append(.received…)` (~L284), **mailbox.delivered** alongside `log.append(.copied…)` (~L372). Off-main utility queue. (These are 1:1 with existing dispatch-log appends → lowest-risk hooks.)
- `Sources/AppDelegate.swift` — start `EventEmitter.shared` and emit `log.opened` in `applicationDidFinishLaunching`; `flush()` on terminate.
- `cli/c11.swift` — new `events` case in the pre-socket dispatch (~L1699 region), `runEventsCommand` + `runEventsTail` extensions near the mailbox runners (~L16981+), and `events` entries in `subcommandUsage` (~L7763) and top-level `usage()` (~L16277).
- `GhosttyTabs.xcodeproj/project.pbxproj` — add the four new `Sources/Events/*.swift` to the app target; add `EventEnvelope.swift` + `EventLogLayout.swift` to the **`c11-cli`** target too (dual membership, mirroring `MailboxLayout.swift`); add the new test files to `c11LogicTests`. **Expect gem-normalized diff bloat** (CLAUDE.md pbxproj pitfall) — gate on `xcodebuild -list` + membership counts, not line-by-line.
- `spec/README.md` — add an events section (what the schema enforces vs. the Swift validator).
- `skills/c11/SKILL.md` — link the new `references/events.md`.
- **TEL seam:** `Sources/Events/EventEmitter.swift` exposes `emitDerivedLiveness(surface:state:)`; if C11-162 hasn't landed the derived-liveness signal, this is a stub call site TEL wires later (§6).

**Explicitly NOT touched:** hot paths (`hitTest`, `TabItemView`, `forceRefresh`), the socket dispatch/threading tiers, any `DispatchQueue.main.sync` on telemetry paths. No socket subscribe channel.

---

## 4. Test plan (per EVALUATION row — all EVT rows are `autonomous`)

Fast local loop is `c11-logic` (temp-dir-injected `EventLog`, tiny caps, `flush()` — all hermetic and sub-second). Socket/live rows run against the tagged build.

- **EVT-1** — `EventEnvelopeTests` + `EventLogTests`: emit events, read back the NDJSON, assert every required field present and well-typed; assert order + monotonic seq. Validate a sample line against the schema shape (and drive `spec/fixtures/events/*` through the Swift validator).
- **EVT-2** — `EventEmitter` unit tests assert one correctly-typed event per taxonomy member (pure emit-level). Socket/UI-driven members (metadata change, workspace select, mailbox delivery, surface close) are additionally proven live in the EVT-7 recorded scenario against the tagged build.
- **EVT-3** — `EventEmitterOffMainTests`: inject a deliberately-slow/blocked `FileHandle` (or paused queue); assert `emit()` returns immediately (timed) and the bounded-drop counter engages instead of growing unbounded. Code-audit note: enumerate every emit site's actor and confirm none blocks.
- **EVT-4** — `EventLogRotationTests`: tiny cap, write past it, assert `events.ndjson.1` exists, `events.ndjson` reopened, and a `log.rotated` marker is present/seq behavior asserted; ≥1 generation retained.
- **EVT-5** — `tests_v2/test_events_parity.py` + a CLI test: craft an NDJSON file, run `c11 events tail` one-shot with `--filter type=`, `--since <seq>`, `--since <duration>`; assert exact line selection. `--follow` covered by a bounded harness (write → poll → observe → exit), never an unbounded block.
- **EVT-6** — tagged-build measurement: emit a transition, `events tail --follow` consumer timestamps observation; assert <1s. Recorded.
- **EVT-7** — scripted scenario on the tagged build: consumer tails the stream; a `set-status`, a `mailbox send` delivery, and a `surface.close` each appear and the consumer reacts. **Recorded** (asciinema/screen capture) → ticket artifact.
- **EVT-8** — presence check: schema in `spec/`, fixtures parse/violate as declared, `references/events.md` + `SKILL.md` link in the same PR, installed-skill sync run.

Test-quality guardrails (CLAUDE.md): all tests exercise runtime behavior (write → read → assert), not source text; no plist/pbxproj-text assertions; heavy/slow cases stay hermetic and fast or are quarantined out of the default suite.

---

## 5. Validation-artifact plan (attach all `--role validation`)

- **Tagged build** `evt-post` via `./scripts/reload.sh --tag evt-post` (build lock acquired first).
- **EVT-7 recording** — screen/asciinema capture of `c11 events tail --follow` reacting to a status change + mailbox delivery + surface close, with the consumer visibly reacting.
- **EVT-6 latency log** — timestamped transition-vs-observation deltas, all <1s.
- **EVT-4 rotation proof** — `ls`/sizes before & after, plus the `log.rotated` marker line and the retained `.1` generation.
- **EVT-5 CLI matrix transcript** — `--follow`, `--filter type=`, `--since seq`, `--since duration`, one-shot exit.
- **CI green** run link + `c11-logic` local run output.
- **Schema/fixtures** parity run output (`tests_v2/test_events_parity.py`).

---

## 6. Risks & seams

1. **TEL derived-liveness seam (EVT-2 `liveness.derived`).** Per BUILDPLAN, EVT-2 consumes C11-162 (TEL)'s derived-liveness transitions. If TEL's signal hasn't landed at RESUME, land the event type + a stub `EventEmitter.emitDerivedLiveness(...)` and note it — TEL completes the wiring. **The seam decision will be logged in the completion comment either way** (boot prompt §SEAM RULE).
2. **Off-main emit adds work to the metadata-store serial queue** (a telemetry path). Mitigation: the emit is a tiny dict build + `queue.async` handoff (no I/O on the store's queue); the `metadata.changed` gate is canonical-key-only + mutation-only, so idempotent/no-op writes and non-canonical keys emit nothing. Keeps the CLAUDE.md socket-telemetry-off-main policy intact. Watch `metadata.changed` volume under a status/progress flood; rely on upstream coalescing, and the writer's bounded-drop guard is the backstop.
3. **`full disk never stalls`** — proven by the bounded-drop guard + the async-never-blocks-caller design, asserted in the EVT-3 stall-injection test.
4. **Per-instance file vs. deterministic CLI path.** Resolved: stable primary path `events.ndjson`, per-boot `instance` id in every envelope, seq resets per instance, `log.opened`/`log.rotated` markers → the CLI has a fixed file to tail while consumers can still detect instance change / seq reset / rotation. Two concurrent prod instances writing the same file is rare (single socket) and the `instance` field disambiguates; accepted, noted.
5. **`surface.created` has no single funnel** (~5 insertion sites). Mitigation: one `emitSurfaceCreated` helper called from each site; note for future surface-creation paths to call it.
6. **CLI follow loop blocks forever** in the mailbox template. Mitigation: add a non-follow one-shot + clean exit; `--follow` used only where a persistent tail is wanted.
7. **CLI build integration.** New shared pure files must be visible to the `c11-cli` target exactly as `MailboxLayout.swift` is (dual pbxproj membership). Re-verify the CLI build mechanism at RESUME and that `EventEnvelope`/`EventLogLayout` compile cleanly in `c11-cli` (no app-only imports).
8. **pbxproj diff bloat** from gem normalization — expected; gate on `xcodebuild -list` + membership counts.

---

## 7. Localization

**No new user-facing SwiftUI strings are planned.** The feature is a CLI subcommand + an on-disk file; CLI help/output in `cli/c11.swift` follows the existing (non-`String(localized:)`) CLI convention. If any app-side UI surface is added to visualize events (none in scope), its strings must be localized at the call site per CLAUDE.md and a six-locale translation pass delegated. **Localization pass: not required for this ticket** (flagged for reviewer confirmation).

---

## 8. Build/PR sequencing (at RESUME, not now)

1. `EventEnvelope` + `EventLogLayout` (pure) → 2. `EventLog` (+ rotation/backpressure) → 3. `EventEmitter` → 4. wire emit sites (taxonomy) → 5. `c11 events tail` CLI → 6. `spec/` schema + fixtures → 7. `references/events.md` + `SKILL.md` + sync → 8. tests → 9. tagged build + recorded validation. Commit in logical units; `c11-logic` green after each code unit; build lock held only around xcodebuild/reload; review via headless `lattice code-review`; stop at `pr_open` for operator merge.

---

## 9. Plan-Review Cycle 1 Resolutions (AUTHORITATIVE — overrides earlier text on conflict)

The board's configured triple/trident plan-review could not run in this workspace (it spawns c11 review panes; `c11 new-pane` failed `pane_too_small`, which is also why the 08:28 auto-review died with no artifacts). Fallback: three independent adversarial reviewers (SPEC-completeness, architecture+CLAUDE.md, codebase-accuracy) ran against the plan, the contract, and the post-extraction worktree. Verdicts: architecture **REWORK**, spec **APPROVE-WITH-CHANGES**, codebase **APPROVE-WITH-CHANGES** — the mailbox-clone architecture, dual-target model, threading model, and (verified-exact) code references all stand; the items below are concrete corrections to fold in **before build**. No architectural re-review is warranted (no architecture change). Reviewers independently confirmed: the TEL derived-liveness signal is genuinely unlanded (correct to stub); `spec/` + fixtures + `tests_v2` parity scaffolding exist; `c11-cli` is a real target with `MailboxLayout.swift` dual-membership; the CLI pre-socket seam (`state verify` @ L1699–1706, before `SocketClient` @ L1708) is exact.

### A. [Critical] Rotation-aware CLI follow loop — do NOT clone the mailbox loop verbatim
The mailbox `runMailboxTailCommand` follow loop is offset-based (`seek(toOffset: lastSize)`) and the mailbox log **never rotates**. The events log **does** rotate (fresh, smaller file at the same path), so after a roll `lastSize` (~cap) seeks past EOF and the follower **silently stalls forever** — breaking EVT-4/5/6 for the primary consumer. **Resolution:** the events follow loop must detect rotation each poll — compare current size vs `lastSize` **and** inode via `fstat` `st_ino`/`st_dev`; if the file shrank or the inode changed, reset `lastSize = 0` and re-read from the top (which begins with the `log.rotated` marker), optionally draining `.1` first to bridge the gap. The `log.rotated` marker is for downstream consumers; it does **not** fix the CLI's own offset math. **New test (EVT-4):** rotate the log *while a `--follow` consumer is attached* and assert it observes the marker + all post-rotation lines within <1s.

### B. [Major] seq + serialization both happen on the writer queue (resolve the contradiction)
Earlier text said "serialize on the caller thread" **and** "seq assigned on the queue" — mutually exclusive, and assigning seq on the caller lets two racing emitters invert file-order vs seq. **Resolution:** on the caller, build only the lightweight envelope struct (capturing `ts` at call time); hand the struct to `queue.async`; **assign `seq` and run `JSONSerialization` inside the serial queue** — the queue is the single ordering authority. Consequence to document in the schema/skill: **`seq` is the sequence oracle; `ts` is approximately monotonic and may invert slightly relative to `seq` across racing threads.**

### C. [Major] `surface.created` — route ALL insertions through one chokepoint; the enumerated map undercounts
Codebase verification found the create map missing real insertions: **L9675** (new `TerminalPanel`, new-tab), **L11708** (new `TerminalPanel`, new-split), and **L11642** (`replacementPanel`, adjudicate). **Resolution:** implement `emitSurfaceCreated(panel:)` and call it from every insertion: 5822, 912, 8096, 8187, 8283, 8370, 8426, 8480, 9000, **9675, 11642, 11708** — verify the full set at build time by grepping every `panels[…] =` assignment rather than trusting this list. Emit **only after successful attach (past the rollback `removeValue` at 8123/8203/8304/…)** so a failed create does not emit an orphan `created`.

### D. [Major] `surface.closed` — single destruction chokepoint covering bulk-teardown + detach
`splitTabBar(_:didCloseTab:fromPane:)` @ L11314 catches interactive single closes but **misses** bulk teardown (`teardownAllPanels` ~L11498, workspace/window close / "close all") and detach removal (~L9053) — surfaces torn down on workspace close vanish from the stream with no `surface.closed`. EVT-7's scripted single close routes through 11314 and would mask this. **Resolution:** wrap `panels.removeValue` behind `emitSurfaceClosed(panelId:)` and call it from 11314, the bulk-teardown block, and the detach path. **Move policy (create/close balance):** a cross-pane detach→reattach surfaces as a `surface.closed` (on detach ~9053) then `surface.created` (on reattach ~9000) pair — documented so consumers reconstructing live-surface state stay balanced. **New test:** assert a workspace-close teardown emits `surface.closed` for each panel, not just the interactive path.

### E. [Major] `metadata.changed` prior value is NOT free on the surface side — capture it at the write site
`WriteResult.priorValues` is **declared but never populated** in `SurfaceMetadataStore` (L378 is a stub), and `setInternal` (L554) returns a bare `Bool`, no `WriteResult`. Only `PaneMetadataStore` populates `priorValues` (L271). **Resolution:** capture the prior inline at each surface write site — read `blob[key]` before the overwrite at ~L655, and the existing value before the commit in `setInternal` (~L575) — and pass it into the emit. Schema treats `prior` as **optional**. Note the Surface/Pane asymmetry, and that **`PaneMetadataStore` has no `metadataStoreRevision`** (surface-only field, L585); the pane mutation gate is its `applied`/`Bool` result, not a revision bump. Corrected pane line refs: `setInternal` ~L204, `setMetadataLocked` ~L241.

### F. [Major] Per-instance log file (satisfy EVT-1 literally + eliminate multi-writer corruption)
Risk #4's single shared `events.ndjson` both deviates from EVT-1's "**per-instance**" wording and is unsafe: the repo's own `StateDirectoryMigration` dogfooding note documents a tagged debug build running **alongside** the prod build, so two live writers occur — and `FileHandle(forWritingTo:)` + `seekToEnd` + `write` is a non-atomic append (no `O_APPEND`) that interleaves/corrupts NDJSON. **Resolution (supersedes Risk #4):** name the file **per-instance** — `<state>/events/events-<instance>.ndjson`, `instance = <launchTag-or-safeBundleId>-<pid>`. Rotation rolls `events-<instance>.ndjson.1`. The CLI resolves the target deterministically: default = **newest by mtime** in `<state>/events/` (optionally a `current` symlink updated at `log.opened`), with an `--instance <id>` override. This removes the accepted corruption risk rather than documenting it; the `instance` envelope field is retained for provenance.

### G. [Major] `metadata.changed` — exclude `progress` from v1 (flood control)
`progress` is the highest-frequency canonical key (0.00→1.00 in many small revision-bumping steps); no upstream coalescing exists, so it would dominate the stream and the indiscriminate drop-guard would evict meaningful transitions (`surface.closed`, `mailbox.delivered`) sharing the writer queue. **Resolution:** v1 `metadata.changed` covers **`status`, `title`, `description`** (plus `role`/`task`/`model` if cheap) and **excludes `progress`**. `progress` may be added later behind explicit coalescing (≤1 event/surface/N ms or threshold crossings). Payload carries key, new value, optional prior (per E), and **source tier as `source.rawValue` (plain string)**.

### H. [Minor→Major] `waiting.*` is a second cross-ticket seam with TEL-6
The waiting signal is `TerminalNotificationStore` unread edges, but TEL-6 (waiting-agent cluster restyle, `docs/c11-waiting-agent-cluster-plan.md`) may redefine "attention demand" in this same wave. **Resolution:** flag `waiting.entered/left` as a **second seam parallel to `liveness.derived`**; confirm with TEL that the unread edge is the canonical waiting signal (or wire to whatever TEL-6 exposes) and **log the decision in the completion comment**. Implementation corrections: `unreadCountByTabId` is keyed by **tabId (per-tab, not per-surface)**; the count is recomputed in the index rebuild (~L1240), so hook the **0↔1 edge via a before/after count read**, not a raw increment; include `markAllRead` (~L968) as a falling-edge path (outside the earlier ~L912–950 range).

### I. [Minor] EVT-8 is a PR review-gate checklist, not an automated test
CLAUDE.md's test-quality policy forbids tests that assert a file/key/snippet exists. **Resolution:** schema-file-present / `SKILL.md`-link / sync-ran are **review-gate checklist** items; the only EVT-8 code in the suite is the **behavioral** fixture validator (drive `spec/fixtures/events/*` through the Swift validator, assert valid parse / invalid rejection). The **dual-target compile is proven behaviorally** by `c11 events tail` running from the CLI binary — no source-text pbxproj test.

### J. [Minor] Keep app-only types out of the pure envelope
`EventEnvelope`/`EventLogLayout` must not name `MetadataSource` (lives in app-only `SurfaceMetadataStore.swift`) or any app symbol. Payload is untyped `[String: Any]`; the app-side emit site stringifies (`source.rawValue`). Guard the `c11-cli` build.

### K. [Minor] Eager EventEmitter init
Initialize `EventEmitter.shared` **early in launch on main** (resolve path, mint `instance`, emit `log.opened`) **before** any surface-creation or metadata path can fire, so the first-use `StateDirectoryMigration.ensureMigrated()` + `createDirectory` I/O never lands on the metadata store's serial queue or blocks a restore-time emit.

### L. [Minor] Corrections to earlier wording
- Serializer baseline is `JSONSerialization [.sortedKeys]` (the mailbox log does **not** use `.withoutEscapingSlashes`); events **adds** `.withoutEscapingSlashes` deliberately (cleaner path output in payloads) — an addition, not a "match."
- Test sources live in the **`c11Tests/`** folder compiled into the **`c11-logic`/`c11LogicTests` target**; write new test files under `c11Tests/` (not a `c11LogicTests/` directory).
- CLI runner placement "~L16981+" is cosmetic; land the `events` runners near the mailbox runners (`runMailboxTraceCommand` L17365 / `runMailboxTailCommand` L17420).

### M. [Minor] Localization decision for `events` CLI text (conscious call)
The blanket "CLI strings aren't localized" premise is overstated: the ratio is ~361 plain `CLIError` : ~10 `String(localized:)`, but the **very runners being cloned localize their usage text** (e.g. `runMailboxTraceCommand`), and CLAUDE.md mandates call-site localization. **Resolution:** localize the new `events` **usage/help** text via `String(localized:)` (consistent with the cloned templates and CLAUDE.md); machine NDJSON passthrough and error codes stay plain. This is a small, bounded English-only addition — no six-locale pass triggered, but flag for reviewer confirmation.

### N. [Minor] EVT-7 concrete reactive consumer
Pin the reactive artifact in the harness: e.g. `c11 events tail --follow --filter type=surface.closed | while read -r line; do <print/log/beep>; done`, so the recording shows an unambiguous **cause → event → reaction** for the status change, the mailbox delivery, and the surface close.

### Net effect on §1–§8
Architecture, file map, and threading model are unchanged. Concrete deltas to carry into build: rotation-aware follow loop (A); seq+serialize-on-queue (B); `emitSurfaceCreated`/`emitSurfaceClosed` single chokepoints with the full insertion set + move policy (C, D); surface-side prior capture (E); per-instance filename + newest-by-mtime CLI resolution (F, supersedes Risk #4); `progress` excluded from v1 `metadata.changed` (G); `waiting.*` logged as a TEL seam (H); EVT-8 split into behavioral test + review checklist (I); pure-envelope type hygiene (J); eager emitter init (K); wording/path/localization corrections (L, M, N).
