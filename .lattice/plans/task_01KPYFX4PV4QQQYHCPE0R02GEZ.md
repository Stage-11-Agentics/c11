# C11-13 Stage 2 — Implementation Plan

**Ticket:** C11-13 — Inter-agent messaging primitive: mailbox + pluggable delivery handlers
**Scope:** Stage 2 vertical slice (10-item checklist from `.lattice/notes/task_01KPYFX4PV4QQQYHCPE0R02GEZ.md`)
**Branch:** `c11-13/stage-2-vertical-slice`
**Author:** agent:claude-opus-4-7-c11-13-plan
**Date:** 2026-04-24

---

## Codebase survey findings

Concrete paths and class names the Impl phase will touch. All paths relative to the worktree root `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-13-stage2`.

### 1. Socket command dispatcher

- **File:** `Sources/TerminalController.swift`
- **V1 dispatcher:** `processCommand(_:)` at `Sources/TerminalController.swift:1639–2496`. V1 is space-delimited text (`SET_METADATA ...`).
- **V2 dispatcher:** `processV2Command(_:)` at `Sources/TerminalController.swift:1998` onward. V2 is JSON-RPC (`{"id": 1, "method": "surface.set_metadata", "params": {...}}`).
- **V2 method table:** `Sources/TerminalController.swift:2029–2496`. Example entries:
  - `case "surface.set_metadata"` → `v2SurfaceSetMetadata(params:)` at `Sources/TerminalController.swift:2181` (handler impl at `Sources/TerminalController.swift:6394`).
  - `case "surface.get_metadata"` → `v2SurfaceGetMetadata(params:)` at `Sources/TerminalController.swift:2183` (impl at `Sources/TerminalController.swift:6464`).
  - `case "surface.list"` at `Sources/TerminalController.swift:2141` (used by dispatcher to enumerate workspace surfaces).
- **Focus-intent whitelists:** `focusIntentV1Commands` at `Sources/TerminalController.swift:119–128` and `focusIntentV2Methods` at `Sources/TerminalController.swift:130–145`. New mailbox methods (if any) must NOT be added to these sets — socket focus policy forbids mailbox commands from stealing focus.
- **Policy wrapper:** `withSocketCommandPolicy(commandKey:isV2:_:)` at `Sources/TerminalController.swift:300–315`. Any mailbox socket command rides through this wrapper for consistency.
- **Response helpers:** `v2Ok(id:result:)` at `Sources/TerminalController.swift:3229–3235`; `v2Error(id:code:message:data:)` at `Sources/TerminalController.swift:3237–3247`.

### 2. CLI subcommand registration

- **Entry:** `CLI/c11.swift` (single-file Swift tool built by the Xcode project as product type `com.apple.product-type.tool`).
- **`@main`:** `CMUXTermMain` at `CLI/c11.swift:13352–13370`; dispatches to `CMUXCLI(args:).run()` at `CLI/c11.swift:1358`.
- **Top-level switch:** flat `switch command` at `CLI/c11.swift:1540–2431`. Existing `set-metadata` case at `CLI/c11.swift:2332` (handler `runSetMetadataCommand(...)` at `CLI/c11.swift:9077`).
- **Socket client:** `SocketClient` struct at `CLI/c11.swift:857–1167`. V1 send at `CLI/c11.swift:892`, V2 send at `CLI/c11.swift:1125` (`sendV2(method:params:)`).
- **End-to-end `set-metadata` trace** (the pattern mailbox CLI writes that talk to the daemon will mirror):
  - CLI dispatch → `CLI/c11.swift:2332` (`case "set-metadata"`).
  - Handler parses flags → `CLI/c11.swift:9077` (`runSetMetadataCommand`).
  - Target resolution → `CLI/c11.swift:9134` (`resolveMetadataCommandTarget`).
  - Socket call → `CLI/c11.swift:9156` (`client.sendV2(method: "surface.set_metadata", params: ...)`).
  - Server handler → `Sources/TerminalController.swift:6394` (`v2SurfaceSetMetadata`).
- **No noun-verb pattern exists today.** There is no `c11 workspace list` / `c11 snapshot save` subparser precedent — every verb is a top-level switch case. Stage 2 follows the same flat shape: add `case "mailbox"` at `CLI/c11.swift:~1540-2431`, sub-dispatch on `commandArgs.first` to `send|recv|trace|tail`.
- **No existing mailbox CLI.** `rg "mailbox" CLI/` → no hits.
- **Bash wrappers:** `Resources/bin/` contains the cc-specific `claude` shim and `open`. No `c11 new-ulid` helper — mailbox ULIDs will be minted inside Swift handlers or a new `c11 new-ulid` sub-command if bash examples need one.
- **CLI distribution:** compiled by Xcode as part of the app bundle at `Contents/Resources/bin/c11`; PATH is extended to that directory at shell spawn (`Sources/GhosttyTerminalView.swift:3170–3179`).

### 3. `$C11_STATE` resolution

- **Resolver:** `stableSocketDirectoryURL()` at `Sources/SocketControlSettings.swift:573–578`. Returns `FileManager.default.urls(for: .applicationSupportDirectory, …).first.appendingPathComponent("c11mux")`.
- **Resolved directory on this machine:** `~/Library/Application Support/c11mux/`.
- **Constant:** `socketDirectoryName = "c11mux"` at `Sources/SocketControlSettings.swift:296`.
- **Socket path:** `stableSocketFileURL()` at `Sources/SocketControlSettings.swift:580–583` → `~/Library/Application Support/c11mux/c11.sock`.
- **No `workspaces/<id>/` subdirectory exists today.** Current contents: `c11.sock`, `last-socket-path`, per-bundle-id `session-*.json` snapshots, `themes/`. Stage 2 must create the `workspaces/<workspace-id>/mailboxes/…` tree on first send.

### 4. Workspace identity at runtime

- **Model:** `Workspace.id: UUID` at `Sources/Workspace.swift:4972`.
- **Initializer:** `Sources/Workspace.swift:5363–5377` — restores a persisted UUID when provided (stable across restart), else mints a fresh `UUID()`.
- **Format:** currently **`UUID`** (RFC 4122) — **not ULID**. Messaging envelopes still use ULIDs for `id` per the locked schema, but the workspace directory path uses the workspace UUID as-is. The design doc's `<workspace-id>` placeholder is satisfied by this UUID; no ULID migration is required at the workspace layer.

### 5. Env vars set in surface shells

Exact set currently injected at shell spawn (`Sources/GhosttyTerminalView.swift:3140–3163`):

| Key | Value |
|---|---|
| `CMUX_SURFACE_ID` | surface UUID |
| `CMUX_WORKSPACE_ID` | workspace UUID |
| `CMUX_PANEL_ID`, `CMUX_TAB_ID` | legacy aliases for surface UUID |
| `CMUX_SOCKET_PATH` | Unix socket path |
| `CMUX_BUNDLED_CLI_PATH` | absolute path to bundled `c11` binary |
| `CMUX_BUNDLE_ID` | app bundle id |
| `CMUX_PORT`, `CMUX_PORT_END`, `CMUX_PORT_RANGE` | per-workspace port allocation |
| `CMUX_SHELL_INTEGRATION`, `CMUX_SHELL_INTEGRATION_DIR` | shell integration |
| (no `C11_STATE`, no `C11_WORKSPACE_ID`, no `C11_SURFACE_NAME`) | design-doc names are **not** currently set |

**Implication:** the design doc's raw-bash snippet `$C11_STATE/workspaces/$C11_WORKSPACE_ID/mailboxes/_outbox/` and `"from": "$C11_SURFACE_NAME"` will not work verbatim today. See **Decisions needed** below.

**Env var stability:** env is injected once at `ghostty_surface_new` time (`Sources/GhosttyTerminalView.swift:3111–3255`) and added to `protectedStartupEnvironmentKeys`. There is no dynamic-update path today — a `c11 set-title` after spawn does NOT update the running shell's env. Any env-var strategy for surface name must either accept this staleness or be read live via a CLI helper at send time.

### 6. Surface-name resolution (name → surface handle)

- **Current mechanism:** title is a canonical metadata key, `MetadataKey.title` at `Sources/SurfaceMetadataStore.swift:19` (public enum).
- **Read:** `SurfaceMetadataStore.shared.getMetadata(workspaceId:surfaceId:)` at `Sources/SurfaceMetadataStore.swift:269` — returns `(metadata: [String: Any], sources: [String: [String: Any]])`.
- **Write via `c11 set-title`:** CLI dispatch at `CLI/c11.swift:1670–1671` → `runSetTitle` at `CLI/c11.swift:3742–3755` → `runSetTitleBarText(key: "title", ...)` at `CLI/c11.swift:3835` → `client.sendV2(method: "surface.set_metadata", params: [metadata: [title: value], ...])`. Server handler `v2SurfaceSetMetadata` at `Sources/TerminalController.swift:6394` forwards to `SurfaceMetadataStore.setMetadata(...)`.
- **No built-in name → surface lookup.** Stage 2 must add one. Algorithm: enumerate workspace surfaces via `surface.list`, fetch each surface's `title`, match against the name. Live-surface only in v1; alignment doc §1 specifies fallback-to-`surface:N` with warning when a surface has no title (but mailbox addressing must use names, so unnamed surfaces cannot receive until operator names them).
- **Tab rename vs surface rename:** `c11 rename-tab` and `c11 set-title` both write the same `title` metadata key; `Sources/Workspace.swift:6391–6416` syncs the title through `panelTitles[panelId]` for rendering. 1:1 mapping between tab/surface handles (confirmed: `tab:81` = `surface:81` in `c11 identify` output).

### 7. Pane/surface metadata store

- **Classes:** `PaneMetadataStore` at `Sources/PaneMetadataStore.swift:22` (final class, `@unchecked Sendable`). `SurfaceMetadataStore` at `Sources/SurfaceMetadataStore.swift:63`.
- **Persistence medium:** **in-memory only in v1.** Both stores document this explicitly (`Sources/SurfaceMetadataStore.swift:53–62`, `Sources/PaneMetadataStore.swift:19–20`). Durability is handled by session snapshots (not the store's concern). Restoration: `restoreFromSnapshot()` at `Sources/SurfaceMetadataStore.swift:356`.
- **Schema:** `[String: Any]` per surface/pane, 64 KiB cap serialised (`Sources/SurfaceMetadataStore.swift:68`). Alignment doc §3 mandates that all `mailbox.*` values are strings for v1 (comma-separated lists).
- **Thread safety:** serial queue `DispatchQueue(label: "com.stage11.c11.surface-metadata", qos: .userInitiated)` at `Sources/SurfaceMetadataStore.swift:125`.
- **Enumeration by prefix:** not built in. Consumers must call `getMetadata()` and filter keys manually (`metadata.keys.filter { $0.hasPrefix("mailbox.") }`). The dispatcher will do this.
- **Change notifications:** **none.** `Sources/SurfaceMetadataStore.swift:353–355`: "Silent by design. The store has no observer infrastructure today … Adding a notification pipeline is Phase 3 scope." A monotonic `metadataStoreRevision` counter exists (`Sources/SurfaceMetadataStore.swift:280–282`) for poll-based diffing, but no push notifications. Stage 2 dispatcher reads `mailbox.*` keys **at dispatch time**, every time — a cheap re-read is simpler than wiring observers.
- **No existing `mailbox.*` references:** `rg "mailbox\." Sources/ CLI/` is empty. Greenfield.

### 8. fsevent watcher infrastructure

- **Existing wrapper:** `Sources/Theme/ThemeDirectoryWatcher.swift:12–*` — an `FSEventStreamRef` wrapper with debounce + polling fallback, driven by `DispatchQueue(label: "c11.theme-watcher", qos: .utility)` at `Sources/Theme/ThemeDirectoryWatcher.swift:22`. This is the canonical pattern to reuse.
- **Other uses:** `DispatchSourceFileSystemObject` appears in `Sources/TerminalController.swift` (terminal surface attachments) and `Sources/Panels/MarkdownPanel.swift` (markdown live-reload). These are single-file watchers, not directory watchers.
- **Stage 2 plan:** mirror `ThemeDirectoryWatcher`'s structure into `Sources/Mailbox/MailboxOutboxWatcher.swift`. Watches `$C11_STATE/workspaces/<ws>/mailboxes/_outbox/` for new `.msg` files (filename-filter on `hasSuffix(".msg")`). Coalesce / debounce events; 5-second periodic sweep (`DispatchSourceTimer`) as belt-and-suspenders per design doc §1 and review item #4.

### 9. Atomic write helpers

- **No dedicated helper today.** Extant pattern: `Sources/Workspace.swift:4010, 4015, 4101` — caller constructs a `".tmp-\(UUID())"` temp filename, writes bytes, then `FileManager.moveItem(at:to:)` to the final path.
- **Stage 2 plan:** introduce `Sources/Mailbox/MailboxIO.swift` with `atomicWrite(data:to:)` that writes to `<dir>/.<uuid>.tmp` and renames to the target on the same filesystem. Reusable for both envelope writes (`_outbox/`) and `_dispatch.log` line appends (append via `FileHandle.write` without rename; no atomicity needed for line append since NDJSON recovers from truncation).

### 10. Background queue / Task / Actor infrastructure

- **Canonical off-main pattern:** `DispatchQueue(label: "c11.<feature>", qos: .utility)` with `setSpecific` for queue identity checks. Two live examples:
  - `Sources/PostHogAnalytics.swift:29` — `com.stage11.c11.posthog.analytics`, QoS `.utility`.
  - `Sources/Theme/ThemeDirectoryWatcher.swift:22` — `c11.theme-watcher`, QoS `.utility`.
- **UI scheduling:** `Task { @MainActor in … }` / `DispatchQueue.main.async` at the tail when badge/UI update is actually needed.
- **Socket command threading policy (`CLAUDE.md`):** high-frequency `report_*` commands and metadata updates must parse/validate/coalesce off-main. Applies to any new mailbox socket commands and to the dispatcher itself. Stage 2 creates a dedicated queue `com.stage11.c11.mailbox.dispatcher` at `.utility` QoS.
- **Per-surface stdin write:** has to go through Ghostty's terminal write path, which is main-actor-bound. Pattern: dispatcher computes the framed bytes off-main, then `DispatchQueue.main.async` a single call to write into the surface — with a 500 ms `DispatchSemaphore.wait(timeout:)` guarding the completion so a stuck recipient doesn't stall the dispatcher.

### 11. Test harness

- **Swift unit tests:** `c11Tests/` (XCTest; 63 files). Canonical example `c11Tests/ThemeRegistryTests.swift`. Shape: `@testable import cmux`, `XCTestCase` subclass, `XCTAssert*` helpers. Mailbox Swift tests (envelope validator, atomic write, surface-name resolver, NDJSON writer) land here.
- **UI tests:** `c11UITests/` (18 files). Not relevant for Stage 2 — the messaging primitive has no UI surface beyond an optional sidebar badge (deferred to Stage 3).
- **Python integration tests:** `tests_v2/` (confirmed). Client library `tests_v2/cmux.py` — at `tests_v2/cmux.py:36–50` it resolves socket path via `~/Library/Application Support/c11mux/last-socket-path` with env-var override `CMUX_SOCKET` / `C11_SOCKET`. Test shape: `with cmux(SOCKET_PATH) as c: c.identify()`, then `c._call("surface.set_metadata", {...})`. Parity test lands in `tests_v2/test_mailbox_parity.py`.
- **CI workflows** at `.github/workflows/`:
  - `test-e2e.yml` — manual `workflow_dispatch`; runs `xcodebuild test-without-building` for UI + socket tests on macOS 14/15; 20-minute timeout. This is where the parity test runs (`tests_v2/` is invoked from this workflow's job matrix).
  - `ci.yml` — per-push build check, GhosttyKit checksum, remote-daemon Go tests, web typecheck. Guardrail, not heavy tests.
  - `nightly.yml` — full macOS 14/15 × arm64/x86_64 matrix, archive + S3 upload.
  - `release.yml`, `ci-macos-compat.yml`, `build-ghosttykit.yml`, `update-homebrew.yml`, `claude.yml` — unrelated.

### 12. JSON Schema validation

- **No dependency today.** `Package.swift`, `Package.resolved`, and `package.json` carry no JSON Schema validator. `tests_v2/` has no `jsonschema` import.
- **Stage 2 plan:** write a minimal Swift envelope validator in `Sources/Mailbox/MailboxEnvelope.swift` that encodes the schema rules manually — required fields, type check (`Int`, `String`, `Bool`, `[String: Any]`), `version == 1`, body size ≤ 4096 bytes, UTF-8 check, `additionalProperties: false` for the top level (with `ext` as the escape hatch), mutually-exclusive `body` vs `body_ref` (body must be empty string when `body_ref` is set), at-least-one-of `to|topic`. This keeps the dependency surface zero. Golden invalid fixtures (see Step 1) exercise every rule. Python parity-test harness re-uses the same rules by round-tripping fixtures through `c11 mailbox send` and raw-file paths; it does not need an independent validator.

### 13. ULID + NDJSON writer

- **ULID:** no dep in the tree; no helper exists. Envelope `id` must be ULID per schema. Stage 2 adds `Sources/Mailbox/MailboxULID.swift` — a minimal Crockford-base32 ULID generator (48-bit ms timestamp + 80-bit randomness, monotonic within ms). ~60 LoC Swift. Unit-tested for sort stability and lexicographic order.
- **NDJSON writer:** no existing helper. `Sources/Mailbox/MailboxDispatchLog.swift` wraps a dedicated `DispatchQueue(label: "com.stage11.c11.mailbox.log", qos: .utility)` serialising `JSONEncoder` + `"\n"` appends through one `FileHandle`. Daily rotation deferred to Stage 3 — Stage 2 writes a single growing file per workspace.

### 14. File layout at `~/Library/Application Support/c11mux/`

Confirmed contents (`ls -la` on 2026-04-24):

```
c11.sock            (Unix socket)
last-socket-path    (marker file)
session-<bundle-id>.json  (session snapshots, many)
themes/             (theme files)
```

Stage 2 creates `workspaces/<workspace-uuid>/mailboxes/{_outbox,_processing,_rejected,<surface-name>}/` + `_dispatch.log` on first mailbox write per workspace. Directory creation is lazy, with `FileManager.createDirectory(at:withIntermediateDirectories:true, attributes: [.posixPermissions: 0o700])`.

---

## Architecture summary

**One paragraph.** The mailbox dispatcher runs **in-process** inside the c11 Swift app on a dedicated `com.stage11.c11.mailbox.dispatcher` utility queue, one instance per active workspace, started when the workspace becomes active and stopped on workspace teardown. The dispatcher owns an `FSEventStreamRef` watching `$C11_STATE/workspaces/<ws>/mailboxes/_outbox/` (mirroring `ThemeDirectoryWatcher`) plus a 5-second `DispatchSourceTimer` sweep. On each new `*.msg` file it atomic-moves to `_processing/`, validates via `MailboxEnvelope.validate`, looks up recipients by consulting `SurfaceMetadataStore` (filter live workspace surfaces whose `title` matches `to` or whose `mailbox.subscribe` globs match `topic`), atomically copies the envelope into each recipient inbox directory, appends NDJSON events to `_dispatch.log`, then invokes handlers per recipient's `mailbox.delivery`. The v1 `stdin` handler computes the `<c11-msg>` framed block off-main, hops to `@MainActor` with a 500 ms-bounded semaphore to write into the recipient surface's PTY via the existing Ghostty input path, and logs outcome (`ok` / `timeout` / `EIO`). The **CLI side** lives in `CLI/c11.swift` as new top-level cases (`case "mailbox":` sub-dispatching to `send|recv|trace|tail`) — every CLI command is pure file I/O (no socket), so `send` fits in a ~30-line wrapper around `MailboxEnvelope.build()` + `atomicWrite()`, and `recv` is directory listing + read + unlink. The **Python parity test** in `tests_v2/test_mailbox_parity.py` uses the same envelope construction rules to write raw files and compares inbox byte-state against a CLI-invoked second run. No socket protocol additions are required for Stage 2 — observability (`trace`, `tail`) is pure file read on `_dispatch.log`.

---

## Implementation order

Ordered sub-item by sub-item. Each step is a discrete commit-level unit. Dependencies noted inline. Impl agent commits per step, pushes, watches CI, fixes on red.

### Step 1 — Schema + fixtures (foundation; nothing depends on building code yet)

- **Files to add:**
  - `spec/mailbox-envelope.v1.schema.json` — JSON Schema draft 2020-12, encoding the v1 envelope rules from design doc §3.
  - `spec/fixtures/envelopes/valid-minimal.json` — smallest valid envelope (`version`, `id`, `from`, `ts`, `body`, `to`).
  - `spec/fixtures/envelopes/valid-topic.json` — topic-only (no `to`).
  - `spec/fixtures/envelopes/valid-with-ext.json` — exercise `ext` escape hatch.
  - `spec/fixtures/envelopes/valid-reply-chain.json` — `reply_to` + `in_reply_to`.
  - `spec/fixtures/envelopes/valid-body-ref.json` — `body: ""` + `body_ref: "/abs/path"`.
  - `spec/fixtures/envelopes/invalid-missing-version.json`
  - `spec/fixtures/envelopes/invalid-wrong-version-type.json` (`"version": "1"` — must be integer)
  - `spec/fixtures/envelopes/invalid-no-recipient.json` (neither `to` nor `topic`)
  - `spec/fixtures/envelopes/invalid-unknown-top-level-key.json` (stray `"foo": 1`)
  - `spec/fixtures/envelopes/invalid-oversize-body.json` (body > 4096 bytes)
  - `spec/fixtures/envelopes/invalid-body-and-body-ref.json` (both set non-empty)
  - `spec/fixtures/envelopes/invalid-bad-ts.json` (not RFC3339)
  - `spec/fixtures/envelopes/invalid-bad-ulid.json` (`id: "not-a-ulid"`)
  - `spec/README.md` — brief note that the schema is the source of truth.
- **What:** lock the schema before any Swift code is written. Fixtures drive the Swift validator's unit tests and the Python parity test.
- **Acceptance:** schema loads as valid JSON Schema (cross-validated with `python -m json.tool`); every `valid-*.json` round-trips through `json.load` / `json.dump` without error; every `invalid-*.json` violates exactly one documented rule. Committed in a single commit titled `spec: lock mailbox envelope v1 schema + fixtures`.

### Step 2 — Directory layout constants + path helpers (pure library; no I/O yet)

- **Files to add:**
  - `Sources/Mailbox/MailboxLayout.swift` — constants + path builders (`outboxURL(state:workspaceId:)`, `processingURL`, `rejectedURL`, `inboxURL(state:workspaceId:surfaceName:)`, `dispatchLogURL`, `blobsURL`).
  - `c11Tests/MailboxLayoutTests.swift` — XCTest that asserts path shapes and rejects surface names with path separators (`/`, `..`).
- **What:** produce the URLs. Resolve the state root via `stableSocketDirectoryURL()` from `Sources/SocketControlSettings.swift:573`. No env-var override — test isolation is handled by HOME isolation on the c11 spawn (see Step 12). Validate surface-name characters (reject `/`, `\0`, `..`, leading `.`, names >64 bytes UTF-8). Rejection is used by the dispatcher as an early bail-out.
- **Acceptance:** unit tests pass locally under `xcodebuild -scheme c11-unit` on CI; no runtime I/O performed. Impl agent does NOT run tests locally — pushes, watches `gh run watch` for `ci.yml` + `test-e2e.yml` green.

### Step 3 — DESCOPED: env-var wiring moved to a separate ticket

**Decision D1 (resolved 2026-04-24):** do NOT introduce new `C11_*` env vars in this ticket. The broader `CMUX_*` → `C11_*` rename (plus any supporting dual-inject or alias strategy) is its own scope and lives in a follow-up Lattice ticket, not here. C11-13's Stage 2 must work without changing the shell-spawn env-var contract.

**Consequences to the rest of the plan:**
- `MailboxLayout.swift` (Step 2) resolves the state root via `stableSocketDirectoryURL()` directly; no `C11_STATE` override. Tests use HOME isolation on the c11 spawn instead of an env-var override (see Step 12).
- The CLI (`c11 mailbox send`, `recv`) resolves the caller's workspace + surface name via two existing socket calls — `c11 identify` (focused `surface_ref` + `workspace_ref`) then `surface.get_metadata` (pulls `title`). No env-var dependency, CMUX or otherwise.
- Raw-bash writers get a pair of new helper subcommands instead of env vars: `c11 mailbox outbox-dir` (prints the absolute outbox path for the caller's workspace) and `c11 mailbox surface-name` (prints the caller's surface title). Design doc's raw-bash snippet is rewritten to use these — examples work identically in any shell, any language, with zero new env vars.

**Follow-up ticket filed:** [C11-14](../notes/task_01KPZ4HTTMEWBNMYANS40WKGBB.md) — "CMUX_* → C11_* cleanup: env vars, product identifiers, remaining CMUX references". Tracks the rename as its own scope so C11-13's mailbox work ships without coupling to that cleanup.

### Step 4 — Atomic write helper + ULID generator

- **Files to add:**
  - `Sources/Mailbox/MailboxIO.swift` — `func atomicWrite(data: Data, to url: URL) throws` using dot-prefixed temp file on the same directory + `FileManager.replaceItem(at:withItemAt:…)`.
  - `Sources/Mailbox/MailboxULID.swift` — Crockford-base32 ULID (26 chars), monotonic within the same millisecond; `static func make() -> String`.
  - `c11Tests/MailboxIOTests.swift` — writes `data`, asserts file appears, `.tmp` does not linger, crash mid-write leaves only the temp file.
  - `c11Tests/MailboxULIDTests.swift` — asserts length, charset, sort stability over 10k generated IDs.
- **What:** the two lowest-level primitives, each small enough to land in one commit.
- **Acceptance:** unit tests pass in CI. Helpers used by Step 5 and beyond.

### Step 5 — Envelope validator (Swift) driven by the Step 1 fixtures

- **Files to add:**
  - `Sources/Mailbox/MailboxEnvelope.swift` — `struct MailboxEnvelope: Codable`, `static func validate(data: Data) throws -> MailboxEnvelope`, `static func build(from:to:topic:body:replyTo:inReplyTo:urgent:ttlSeconds:bodyRef:contentType:ext:) -> MailboxEnvelope`.
  - Error enum with one case per rule (`missingVersion`, `wrongVersionType`, `unknownTopLevelKey`, `bodyTooLarge`, `noRecipient`, `invalidTimestamp`, `invalidULID`, `bodyAndBodyRefConflict`, …).
  - `c11Tests/MailboxEnvelopeValidationTests.swift` — parameterised over every fixture under `spec/fixtures/envelopes/`. Each `valid-*` must parse; each `invalid-*` must throw the expected error case.
- **What:** the one and only envelope-builder library per design-doc drift-rule #1. CLI and dispatcher both go through `build()` (send path) and `validate()` (receive path).
- **Acceptance:** every fixture categorises correctly. Failure to parse a `valid-*` fixture or acceptance of an `invalid-*` fixture fails the build.

### Step 6 — Dispatch log (NDJSON writer)

- **Files to add:**
  - `Sources/Mailbox/MailboxDispatchLog.swift` — `class MailboxDispatchLog` with a serial `DispatchQueue(label: "com.stage11.c11.mailbox.log", qos: .utility)`, `append(event:)`. Events: `received`, `resolved`, `copied`, `handler`, `rejected`, `cleaned`, `replayed`. Schema matches design doc §6.
  - `c11Tests/MailboxDispatchLogTests.swift` — asserts one line per event, valid JSON per line, file append preserves prior content, concurrent appends from 16 threads produce 16 lines.
- **Acceptance:** 16-thread concurrency test passes (off-main behaviour must not interleave partial writes).

### Step 7 — Surface-name resolver

- **Files to add:**
  - `Sources/Mailbox/MailboxSurfaceResolver.swift` — `func surfaceIds(forName name: String, workspaceId: UUID) -> [UUID]` (returns all live surfaces whose `title` equals `name` — should be 0 or 1 but we tolerate duplicates by returning a list and logging a warning on `count > 1`).
  - `func surfaceName(for surfaceId: UUID, workspaceId: UUID) -> String?` (used for `from` auto-fill if env var is absent).
  - `func surfacesWithMailboxMetadata(workspaceId: UUID) -> [(UUID, String, [String: String])]` — enumerates all live surfaces, pulls `title` + any `mailbox.*` keys, returns tuples (surface id, name, mailbox-metadata-dict).
  - `c11Tests/MailboxSurfaceResolverTests.swift` — stubbed `SurfaceMetadataStore`, asserts filter behavior.
- **Acceptance:** unit tests pass. Resolver reads `SurfaceMetadataStore.shared.getMetadata(...)` each call (no caching — simpler than observer wiring; re-read cost is negligible at dispatch-time volumes).

### Step 8 — fsevent watcher

- **Files to add:**
  - `Sources/Mailbox/MailboxOutboxWatcher.swift` — `class MailboxOutboxWatcher`, modeled on `Sources/Theme/ThemeDirectoryWatcher.swift`. Takes a workspace URL, starts an `FSEventStreamRef`, emits callbacks on the dispatcher queue. Debounce 50 ms. Includes a `DispatchSourceTimer` firing every 5 seconds as the belt-and-suspenders sweep (per design §1; review item #4).
  - `c11Tests/MailboxOutboxWatcherTests.swift` — touch-file tests using `NSTemporaryDirectory()` + `XCTestExpectation`. Assert both fsevent and sweep paths wake the callback.
- **Acceptance:** tests green.

### Step 9 — Dispatcher (the orchestrator)

- **Files to add:**
  - `Sources/Mailbox/MailboxDispatcher.swift` — owns: the watcher (Step 8), resolver (Step 7), log (Step 6), envelope library (Step 5), handlers registry (Step 10). Public: `start(workspaceId:stateURL:)`, `stop()`.
  - Dispatch loop steps (executed serially per envelope on the utility queue):
    1. Watcher fires with a filename in `_outbox/`.
    2. Dedupe: check `_dispatch.log` tail for an id we've already `received` + `cleaned` in this session. In-memory `Set<String>` of recently-seen ids (capped at 1024) for O(1) check; for longer history rely on atomic-move idempotency.
    3. Atomic-move `_outbox/<id>.msg` → `_processing/<id>.msg`. On `ENOENT`, skip (another fsevent replay already moved it).
    4. Read + validate envelope (Step 5). On fail, move to `_rejected/<id>.msg`, write sibling `.err` with reason, append `rejected` event, return.
    5. Resolve recipients: `to` → lookup by surface name; `topic` → scan every live surface's `mailbox.subscribe` globs (Step 7's `surfacesWithMailboxMetadata`). Union into recipient set. Append `resolved` event.
    6. For each recipient: create inbox dir if missing, atomic-copy envelope to `<inbox>/<id>.msg`, append `copied` event.
    7. For each recipient × each handler in their `mailbox.delivery` list, invoke handler (Step 10). Append `handler` event with outcome.
    8. Unlink `_processing/<id>.msg`. Append `cleaned` event.
  - Hot-path compliance: all eight steps run on the dispatcher queue (off-main). Step 7 handler invocation may hop to main if the handler is `stdin` (which has to touch the Ghostty write path) — but the hop is bounded by the 500 ms timeout so the dispatcher never blocks.
- **Files to edit:**
  - `Sources/Workspace.swift` — activate dispatcher on workspace init, tear down on deinit. One new instance property; one `dispatcher?.start(...)` call near where other per-workspace long-lived resources are brought up; matching `stop()` in tear-down.
- **Files to add (tests):**
  - `c11Tests/MailboxDispatcherTests.swift` — spins up a dispatcher against a temp directory, writes a fixture envelope to `_outbox/`, asserts inbox population + dispatch log state after waiting on an expectation.
- **Acceptance:** unit tests pass in CI.

### Step 10 — `stdin` handler (async PTY write with 500 ms timeout)

- **Files to add:**
  - `Sources/Mailbox/MailboxHandler.swift` — `protocol MailboxHandler { func deliver(envelope: MailboxEnvelope, to surfaceId: UUID) async -> HandlerOutcome }`; `enum HandlerOutcome { case ok, timeout, eio, closed }`. (`.epipe` was removed in the review cycle 1 rework as unreachable; real PTY errno propagation is deferred to Stage 3.)
  - `Sources/Mailbox/StdinMailboxHandler.swift` — formats the envelope as a `<c11-msg>` block (leading blank line, tag with XML-escaped attributes, body, closing tag, trailing blank line). Hops to `@MainActor`, writes via the existing Ghostty surface input API, with a 500 ms `Task.withTimeout` semaphore guarding the await. Logs outcome.
- **Files to edit:**
  - `Sources/Mailbox/MailboxDispatcher.swift` — register `StdinMailboxHandler` under the string key `"stdin"`. `silent` registers a no-op handler that always returns `.ok`. `watch` is NOT implemented in Stage 2 (deferred; dispatcher rejects unknown handlers with a log warning but does not fail).
- **Files to add (tests):**
  - `c11Tests/StdinHandlerFormattingTests.swift` — asserts the framed block's exact byte shape for a canonical envelope; asserts attribute XML-escaping (`<`, `>`, `&` in body become `&lt;`, `&gt;`, `&amp;`); asserts trailing `</c11-msg>` is not forgeable (body containing literal `</c11-msg>` emerges escaped).
- **Acceptance:** tests green. No live PTY test in unit suite — PTY behaviour is exercised end-to-end in the parity test (Step 12).

### Step 11 — CLI commands (`c11 mailbox send|recv|trace|tail`)

- **Files to edit:**
  - `CLI/c11.swift` — add `case "mailbox":` to the top-level switch around `CLI/c11.swift:1540–2431`. Sub-dispatch on `commandArgs.first`:
    - `send` → `runMailboxSendCommand(...)`: parses `--to <name>`, `--topic <name>`, `--body <text>`, `--body-ref <path>`, `--reply-to <name>`, `--urgent`, `--ttl-seconds <n>`, `--from <name>` (optional override). When `--from` is absent, resolves caller's surface title via socket: `c11 identify` → focused `surface_ref`/`workspace_ref` → `surface.get_metadata` → `title`. Calls `MailboxEnvelope.build(...)`, serialises, `atomicWrite()` into `_outbox/`. **Must be ≤30 lines of send logic** per drift rule #7.
    - `recv` → `runMailboxRecvCommand(...)`: parses `--drain` (default) / `--peek`. Resolves caller's inbox dir via the same socket path (workspace id + surface name). Lists `<inbox>/*.msg`, reads each, emits NDJSON to stdout, unlinks on drain. No envelope-modification socket call.
    - `trace` → `runMailboxTraceCommand(...)`: takes one positional arg (envelope id). Greps `_dispatch.log` for that id, pretty-prints each line.
    - `tail` → `runMailboxTailCommand(...)`: `tail -f` equivalent on `_dispatch.log` (uses a `DispatchSource` file watcher or a simple polling loop).
    - `outbox-dir` → `runMailboxOutboxDirCommand(...)`: resolves caller's workspace via `c11 identify`, prints the absolute path of `<state>/workspaces/<ws-uuid>/mailboxes/_outbox/` to stdout. Pure helper for raw-bash writers; no side effects.
    - `inbox-dir` → `runMailboxInboxDirCommand(...)`: resolves caller's workspace + surface name via socket, prints the absolute path of `<state>/workspaces/<ws-uuid>/mailboxes/<surface-name>/` to stdout. Pure helper for raw-bash receivers.
    - `surface-name` → `runMailboxSurfaceNameCommand(...)`: resolves caller's surface title via socket and prints it. Lets raw-bash writers set `"from"` without knowing the surface identity upfront.
  - For `watch` (v1.1, not Stage 2): emit `"watch not implemented in Stage 2"` if invoked.
  - **Design-doc update is in scope for this step:** rewrite `docs/c11-messaging-primitive-design.md` §3's raw-bash send snippet (currently uses `$C11_STATE/...`) to use the `outbox-dir` / `surface-name` helpers. The doc's receive snippet picks up `inbox-dir`. Skill-teaches-grammar example updated to match.
- **Files to add:**
  - `Resources/bin/c11-mailbox-send-bash-example.sh` — a four-line bash reference showing the raw file-write equivalent of `c11 mailbox send`, used by the skill.
- **Acceptance:** `c11 mailbox send --to foo --body "hi"` appears in `_outbox/` as a valid envelope; `c11 mailbox recv --drain` returns it; `c11 mailbox trace <id>` shows dispatch events; `c11 mailbox tail` streams live. Validated via the parity test (Step 12).

### Step 12 — Parity test (Python, `tests_v2/`)

- **Files to add:**
  - `tests_v2/test_mailbox_parity.py` — the drift-enforcement lock per design rule #6.
- **Test structure:**
  1. Fresh temp state dir injected via `C11_STATE` env var on a spawned test surface (the c11 app must respect that override — add handling in Step 2's `MailboxLayout.swift`).
  2. Define a list of logical payloads: each a dict with `to`, `topic`, `body`, `urgent`, `reply_to`, `in_reply_to` combinations.
  3. For each payload, dispatch is parameterised over two senders:
     - **raw-file sender** (Python writes `<outbox>/<id>.tmp` then renames), using identical defaults for `version`, `id`, `from`, `ts` as the CLI would auto-fill.
     - **CLI sender** (`subprocess.run(["c11", "mailbox", "send", ...])`).
  4. Wait (with a 5 s expectation timeout) for the envelope to arrive in the target inbox.
  5. Assert byte-equivalent inbox state — the bytes of the file `<inbox>/<id>.msg` after dispatch must be identical regardless of sender path. Any difference (e.g., a missing field the CLI auto-filled but the file writer did not, or vice versa) fails the test.
  6. Assert `_dispatch.log` state: the sequence of events for each `id` is identical across senders.
- **Implementation note:** because `ts` and `id` differ between runs by construction, the test either: (a) pins them (raw-file sender supplies an explicit `--id` / `--ts`, and the CLI supports `--id`/`--ts` override flags for test parity — add in Step 11), or (b) strips them from byte comparison (parse both inbox files as JSON, pop `id` + `ts`, compare remainder). **Option (a) is preferable** — it proves true byte-parity, and the `--id`/`--ts` overrides are operator-useful for replay/testing anyway.
- **Acceptance:** test runs in `test-e2e.yml` on every push. Impl agent does not run it locally — pushes, watches `gh run watch --exit-status` on the feature branch, fixes on red.

### Step 13 — Stale-tmp GC + `_processing/` integrity

- **Files to edit:**
  - `Sources/Mailbox/MailboxDispatcher.swift` — add a sweep tick every 60 s that deletes `_outbox/*.tmp` older than 5 minutes, logging a `gc` event to `_dispatch.log`.
- **Note on `_processing/` crash recovery:** per plan note "Out of scope (Stage 2)", full crash recovery is Stage 3. Stage 2 leaves stranded `_processing/` files on crash; a follow-up ticket handles the sweep. This is safe because receivers dedupe by `id`: a restart-and-re-send duplicates the dispatch but doesn't corrupt.
- **Acceptance:** unit test `c11Tests/MailboxDispatcherGCTests.swift` asserts the GC behaviour with a mocked clock.

### Step 14 — Skill section (minimal)

- **Files to edit:**
  - `skills/c11/SKILL.md` — add a new section "Inter-agent messaging (mailbox)" with:
    - The XML `<c11-msg>` tag grammar + escaping rule.
    - Default receive protocol (finish tool call → treat as system message → dedupe by id → acknowledge inline).
    - Send via CLI (`c11 mailbox send …`) + raw bash (four-line example) side-by-side.
    - Receive via PTY (automatic for `stdin` delivery) + CLI (`c11 mailbox recv --drain`).
    - Debugging (`c11 mailbox trace <id>`, `c11 mailbox tail`).
    - "Stage 2 limitations" note: no topics, no subscribe, no watch, no silent-surface sidecar, no `body_ref`.
- **Rationale:** the mission statement in `CLAUDE.md` is emphatic — "every change to the CLI, socket protocol, metadata schema, or surface model is incomplete until the skill is updated to match." The mailbox CLI lands in Step 11; the skill update is non-negotiable.
- **Acceptance:** Impl agent self-reviews by reading the skill top-to-bottom, ensures every Stage 2 CLI flag is documented, commits alongside the CLI step or immediately after.

---

## Parity test design

Explicit harness spec. This is the drift-enforcement lock and the highest-stakes test in the plan.

- **Location:** `tests_v2/test_mailbox_parity.py`.
- **Runner:** existing `tests_v2/cmux.py` client (socket round-trips already use it for other tests). Add a `MailboxContext` helper that wraps: temp directory setup, env var injection, CLI binary path resolution, dispatch-log tail parsing.
- **Dispatcher lifecycle:** the dispatcher runs inside the live c11 app (launched by the CI harness in `test-e2e.yml`). The test harness isolates state by spawning the c11 app with an overridden `HOME`, so `FileManager.default.urls(for: .applicationSupportDirectory, …)` resolves under a fresh tmp tree. No app code changes are needed for this — it falls out of using `stableSocketDirectoryURL()` unmodified. Dispatcher already runs per-workspace, so a test workspace spawned for this run is isolated.
- **Test workspace spawn:** `c.call("workspace.new", {...})` via socket — creates a workspace with two surfaces pre-named `sender` and `receiver` via `c.call("surface.set_metadata", {"metadata": {"title": "sender"}})`.
- **Logical payload set:** ~8 variations covering the envelope schema's axes:
  1. Minimal (`to` only, `body` non-empty).
  2. With `topic` and `to`.
  3. `urgent: true`.
  4. `reply_to` + `in_reply_to`.
  5. `content_type: "application/json"`.
  6. `body_ref` (body empty, external file).
  7. `ext: {custom: "value"}`.
  8. `ttl_seconds` set.
- **Sender paths:**
  - **CLI:** `subprocess.run(["c11", "mailbox", "send", "--id", <fixed>, "--ts", <fixed>, …])`.
  - **Raw file write:** builds the same JSON envelope in Python, atomic-writes `<outbox>/<id>.tmp` → `.msg` rename.
- **Byte-equivalence assertion:** for each payload × each sender, after waiting for dispatch (5 s timeout polling `<inbox>/<id>.msg` existence), read the inbox file bytes and compare. The CLI run and raw-file run must produce byte-identical inbox state given the same `--id` and `--ts` overrides. Any divergence (CLI silently fills a field, CLI reorders keys, …) is a test failure.
- **Dispatch log parity:** parse `_dispatch.log`, filter to events with the test's `id`, assert the sequence is identical across runs: `received` → `resolved` → `copied` → `handler` → `cleaned`. Event payloads (recipient name, handler name) must match.
- **Handler outcome:** in the test workspace, the receiver surface has `mailbox.delivery: "silent"` (not `stdin`, because we don't want test output contaminating the real receiver PTY). This makes the handler step a no-op and isolates the test to inbox + log state.
- **Failure reporting:** on mismatch, the test prints both files side-by-side with a unified diff and fails with the exact byte offset.
- **No local runs:** per CLAUDE.md testing policy, the Impl agent never runs this locally. Workflow: commit → push → `gh run watch --workflow=test-e2e.yml <sha>` → read CI logs on failure → fix → repeat.

---

## Test / CI strategy

- **Swift unit tests** (`c11Tests/Mailbox*Tests.swift`): run in `ci.yml` on every push (already wired to `xcodebuild -scheme c11-unit`). All steps 2–10 and 13 land unit tests here. Unit tests must pass before Step 12 (parity) is trusted.
- **Python integration test** (`tests_v2/test_mailbox_parity.py`): runs in `test-e2e.yml` via `workflow_dispatch`. Impl agent triggers with `gh workflow run test-e2e.yml --ref c11-13/stage-2-vertical-slice` after each meaningful push; waits with `gh run watch`.
- **Workflow order for the Impl agent per step:**
  1. Commit step's code + tests to `c11-13/stage-2-vertical-slice`.
  2. `git push` — triggers `ci.yml` automatically.
  3. `gh workflow run test-e2e.yml --ref c11-13/stage-2-vertical-slice` — triggers E2E.
  4. `gh run watch` on the latest runs; fix on red.
  5. On green, advance to the next step.
- **Known CI gap:** `test-e2e.yml` is manual-dispatch only. No auto-run on push. Impl agent must remember to trigger it explicitly after Step 12 lands; otherwise red state ships unnoticed. Plan to add a `push:` trigger filtered to `paths: ["tests_v2/**", "Sources/Mailbox/**"]` as part of Step 12's PR — small, scoped change, keeps the parity test honest.

---

## Risks and unknowns

- **No env-var dependency for surface name.** Since Step 3 was descoped, the CLI always resolves `from` via socket (`c11 identify` + `surface.get_metadata` → `title`) rather than reading an env var. Raw-bash writers call `c11 mailbox surface-name` (same socket round-trip behind the scenes) whenever they need their own name. Both approaches see the **current** title after any rename — there's no staleness window to worry about. Cost is one extra round-trip per send; at expected Stage 2 volumes that's invisible.
- **No change notifications on `SurfaceMetadataStore`.** Dispatcher re-reads `mailbox.*` keys on every dispatch. At expected Stage 2 volumes (human-initiated message rate, maybe tens per minute), this is cheap. If volume scales (automated agent chatter >1 msg/s sustained), we may need to add a notification pipeline — Stage 3 concern, not Stage 2.
- **fsevent coalescing vs replay.** macOS FSEvents coalesce events and can replay after wake-from-sleep. The atomic move into `_processing/` is the idempotency primitive; a replay that sees the same filename already in `_processing/` (or absent from `_outbox/`) is a no-op. The 5-second periodic sweep catches any truly missed events. Confidence: the `ThemeDirectoryWatcher` pattern already handles this class of problem in production.
- **Typing-latency hot paths.** Dispatcher work is firmly off-main. The one main-thread hop is in `StdinMailboxHandler.deliver`, where the 500 ms "timeout" is a **reporting bound, not a runtime bound**. `MainActor.run { writer(...) }` is synchronous and Swift task cancellation is cooperative — a slow writer closure keeps main occupied even after the dispatcher logs `timeout` and moves on. The same is true of the outer 2 s semaphore wait in `MailboxDispatcher.invokeHandlerSynchronously`. In practice the production writer (`TerminalPanel.sendText` → buffered byte append) returns in microseconds, so the reporting bound is usually identical to the runtime bound. But "usually" is not "always", and a jammed PTY can freeze typing for every surface on the host. Genuine async-cancellable PTY writes are a follow-up ticket after Stage 2 lands. Until then, the compliance claim we stand behind is: **dispatcher liveness is bounded; main-thread occupancy is not**. Tests (`StdinHandlerFormattingTests.testDeliverReturnsTimeoutEvenWhenWriterBlocksMultipleSeconds`) pin the reporting behavior.
- **Cross-ticket with CMUX-37.** Alignment doc §4 states mailbox config rides in `SurfaceSpec.metadata` when CMUX-37 Phase 0 lands. Stage 2 does not depend on Phase 0 — `c11 mailbox configure` is Stage 3 and uses the existing socket metadata commands directly. No coordination blocking here.
- **Workspace teardown race.** If a workspace is closed mid-dispatch, the dispatcher's `stop()` must wait for in-flight dispatch to finish (or cancel safely) before cleanup. Simplest: `stop()` cancels the watcher + timer, then waits on the serial queue's drain. In-flight envelope stays in `_processing/` for next workspace open. Tested via dispatcher unit test.
- **CLI binary path in `test-e2e.yml`.** CLI lives inside the app bundle at `Contents/Resources/bin/c11`. The test harness must locate the built bundle's CLI after each build — add a small helper in `tests_v2/cmux.py` to resolve the path via the `CMUX_BUNDLED_CLI_PATH` env var (already injected by `Sources/GhosttyTerminalView.swift:3149–3152` but only inside surface shells; the harness may need to invoke it through a spawned surface, not from the test process directly).

---

## Localization

The following **new** user-facing English strings ship in Stage 2. All MUST be wrapped in `String(localized: "<key>", defaultValue: "<English>")` per `CLAUDE.md`. After Impl lands, a Translator sub-agent syncs six locales (ja, uk, ko, zh-Hans, zh-Hant, ru) by editing `Resources/Localizable.xcstrings`.

| Key | English | Where |
|---|---|---|
| `mailbox.cli.send.usage` | "c11 mailbox send [--to <surface>] [--topic <topic>] --body <text> [--body-ref <path>] [--reply-to <surface>] [--urgent] [--ttl-seconds <n>] [--from <surface>] [--id <ulid>] [--ts <rfc3339>]" | `CLI/c11.swift` usage for `send` |
| `mailbox.cli.recv.usage` | "c11 mailbox recv [--drain\|--peek]" | `CLI/c11.swift` |
| `mailbox.cli.trace.usage` | "c11 mailbox trace <envelope-id>" | `CLI/c11.swift` |
| `mailbox.cli.tail.usage` | "c11 mailbox tail" | `CLI/c11.swift` |
| `mailbox.cli.error.no-recipient` | "A mailbox envelope needs --to or --topic." | `CLI/c11.swift` validation path |
| `mailbox.cli.error.body-too-large` | "Inline --body exceeds the 4 KB cap. Use --body-ref <path> for larger payloads." | `CLI/c11.swift` |
| `mailbox.cli.error.surface-not-found` | "No surface named %@ in this workspace." | `CLI/c11.swift` |
| `mailbox.dispatch.error.invalid-envelope` | "Rejected mailbox envelope %@: %@" | dispatcher log-line composition surfaced to sidebar log when operator-visible |
| `mailbox.dispatch.error.handler-timeout` | "Handler %@ for surface %@ timed out after 500 ms." | logged to sidebar if user-visible |

**No UI changes in Stage 2** — no new alerts, menus, or buttons. The sidebar badge (deferred to Stage 3) and the mailbox-configure flyout (Stage 3) introduce more strings later. The Translator pass is small for Stage 2 (~9 strings × 6 locales = 54 entries).

---

## Decisions resolved

**D1 — Env-var aliases at shell spawn (resolved 2026-04-24 by operator):** do NOT introduce new `C11_*` env vars in this ticket. Keep the `CMUX_*` → `C11_*` rename as its own scope — a separate Lattice ticket tracks the cleanup. For this ticket:
- No shell-spawn env-var changes. `Sources/GhosttyTerminalView.swift:3140-3163` untouched.
- Mailbox CLI resolves workspace/surface via socket (`c11 identify` + `surface.get_metadata`).
- Raw-bash writers use helper subcommands: `c11 mailbox outbox-dir`, `c11 mailbox inbox-dir`, `c11 mailbox surface-name`.
- Design doc's raw-bash snippets rewritten to use the helpers (Step 11 includes the doc edits).
- Test isolation uses HOME override on the c11 spawn, not a state-dir env var.

No outstanding decisions.

---

## Out of scope (Stage 2)

Verbatim from `.lattice/notes/task_01KPYFX4PV4QQQYHCPE0R02GEZ.md`:

- **Topic subscribe globs and topic fan-out.** (Stage 3: `mailbox.subscribe` reads, dispatch-time fan-out.)
- **`silent` and `watch` handlers.** (Silent is implemented as a no-op shim in Stage 2 for parity-test isolation, but not advertised as a supported handler; watch is explicitly deferred.)
- **`c11 mailbox configure` CLI.** (Stage 3: wraps `c11 set-metadata --key mailbox.*`.)
- **`body_ref` safety-valve.** (Stage 2 validates the field shape but does not wire reading through; inline-body cap at 4096 bytes is the only size rule enforced.)
- **Per-surface inbox cap (1000 pending → `_rejected/`).** (Stage 3.)
- **Crash recovery of `_processing/` on c11 start.** (Stage 3.)
- **TOON output format.** (v1.1.)
- **`exec` / `webhook` / `file-tail` / `signal` handlers.** (v1.1+; requires security model first.)
- **Topic discovery registry (`_topics.json`, `mailbox.advertises`, `c11 mailbox topics`).** (v1.1.)
- **Manifest allow/deny lists.** (v1.1.)

Stage 3 and v1.1 work lives on separate tickets to be filed after Stage 2 lands (see "Stage 4 — Skill + docs + rollout" in the plan note).

## Review Cycle 1 Findings (2026-04-24, verdict: fail-impl)

Nine-agent Trident review (Claude Opus 4.7 + Codex / GPT-5 + Gemini 1.5 Pro × correctness / security / architecture lenses) ran against `027d9e86` and produced a review pack at `notes/trident-review-C11-13-pack-20260424-0403/`. The pack has 9 per-reviewer files plus 3 synthesis files (standard / critical / evolutionary). Read the critical synthesis first — it's the canonical blocker list.

The plan itself is sound. The implementation has specific, fixable misses. Cycle to Impl, not Plan.

### Must-fix in this cycle (ordered by prevention-per-hour)

1. **Real byte parity in the parity test.** Pin `id`/`ts` on both sides, assert `cli_inbox_bytes == raw_inbox_bytes` directly. Python-normalized comparison defeats the drift-enforcement lock the design doc §3 rule #6 and plan Step 12 both promise.
   - Files: `tests_v2/test_mailbox_parity.py:355-365`.
   - Acceptance: test fails visibly on any byte divergence (prove by temporarily perturbing encoder output in a local tweak before submitting — the test must reject it).
2. **Fix `JSONSerialization` slash escaping.** Swift's default escapes `/`; Python's `json.dumps` doesn't. `body-ref` payloads will fail real byte comparison the moment #1 lands. Use `JSONEncoder.OutputFormatting.withoutEscapingSlashes` (or equivalent) everywhere the CLI writes an envelope.
   - File: `Sources/Mailbox/MailboxEnvelope.swift:69` (and anywhere else CLI serializes envelopes).
3. **Fix topic-only envelope semantics.** Today the dispatcher resolves topic-only to `[]` recipients, cleans the envelope, and returns success. Silent drop is the worst option. Since topic subscribe/fan-out is Stage 3, Stage 2 must either:
   - Reject topic-only at CLI (`runMailboxSendCommand` when `to == nil && topic != nil` → hard error + non-zero exit), OR
   - Emit an explicit `rejected` dispatch-log event with reason `topics_not_implemented`, AND the CLI must exit non-zero when the envelope is rejected this way.
   - Also: update `skills/c11/SKILL.md` to say topic-only sends fail in Stage 2. Drop the skill lines that teach topic-only as usable.
4. **Pre-existing `_outbox/*.msg` files must dispatch on start.** Current `MailboxOutboxWatcher.start()` snapshots `knownFiles = currentSnapshot()` — anything pre-existing is stranded until manually removed. Fix so startup triggers dispatch of pre-existing envelopes (atomic move-to-processing remains the idempotency primitive).
   - Files: `Sources/Mailbox/MailboxOutboxWatcher.swift:61, 157`.
5. **Honest main-thread bound.** `MainActor.run` is uncancellable; Swift task cancellation is cooperative. The 500 ms / 2 s timeouts are *reporting* bounds — the main thread can still be stuck while the dispatcher logs "timeout." Two honest paths:
   - **(a)** Write to the Ghostty terminal via a genuinely async, cancellable code path (half-day of work, but aligned with hot-path policy).
   - **(b)** Document explicitly in the plan, skill, and `StdinMailboxHandler` comments that the 500 ms bound is a reporting bound, update the hot-path-compliance claim in the plan risks section, and add a test that proves the timeout fires even when the mocked writer blocks for 5 s.
   - **Lean: (b) for this cycle.** Honest documentation beats overclaimed cancellation; (a) can be a follow-up ticket. If you pick (a), flag it in the commit message.
6. **EIO/EPIPE — wire or delete.** Today the production writer returns `.ok` unconditionally and the `.epipe` variant is unreachable. Either (a) propagate real Ghostty write failures into the dispatcher outcome, or (b) delete the unreachable variants (`.eio`, `.epipe`, `.closed`) and narrow the claim in plan + skill.
   - Lean: **(b) — delete the unreachable variants** and tighten the docs. Real PTY failure propagation is Stage 3 alongside the crash-recovery work.
   - Files: `Sources/Mailbox/StdinMailboxHandler.swift`, `Sources/Workspace.swift:5538`, `Sources/GhosttyTerminalView.swift:3524` (inspect only; real wiring is deferred).
7. **Scrub `$C11_*` raw env-var examples from design doc §12.** The CLI-helper rewrite in Step 11 missed §12. Rewrite every `$C11_STATE` / `$C11_WORKSPACE_ID` / `$C11_SURFACE_NAME` reference to use `$(c11 mailbox outbox-dir)` etc.
   - File: `docs/c11-messaging-primitive-design.md:649, 657` (full sweep — grep for `C11_STATE` across the doc).
8. **Parity test on CI push.** Add a workflow (or extend `test-e2e.yml`) that runs the parity test on push with `paths: ["tests_v2/test_mailbox_parity.py", "Sources/Mailbox/**", "CLI/c11.swift", "spec/**"]`. Without this, the lock never runs on the actual merge path.
   - File: `.github/workflows/test-e2e.yml` (or a new `mailbox-parity.yml`).

### Explicitly deferred (with doc tightening)

**P0 #5 — `_processing/` crash-recovery sweep on dispatcher start.** This is `.lattice/notes/task_01KPYFX4PV4QQQYHCPE0R02GEZ.md`'s "Out of scope (Stage 2)" line 427: "Crash recovery of `_processing/` on c11 start. (Stage 3.)" — the plan note intentionally deferred it. The review correctly noticed that the at-least-once delivery claim is load-bearing on this recovery, so instead of pulling the work into Stage 2:

- **Tighten the at-least-once claim** in the design doc, the skill, and `StdinMailboxHandler.swift` comments: explicitly say *"Stage 2 provides at-least-once for the steady-state dispatch loop. Full at-least-once under dispatcher-crash-while-processing requires the `_processing/` recovery sweep shipping in Stage 3."* Don't overclaim.
- Add a visible TODO comment at the dispatcher `start()` site pointing at the Stage 3 scope.

### Also deferred (P1 — follow-up tickets, not this cycle)

These were raised by single reviewers and are real but not merge-blockers for Stage 2:

- Cross-process single-writer pidfile lock (dev+user-build collision).
- `stop()` drains in-flight dispatch (`queue.sync {}` after cancellation).
- Workspace-exists check on CLI send (reject envelopes targeting a non-live `CMUX_WORKSPACE_ID`).
- Envelope total-size cap (ext flood prevention).
- Surface-name length parity (envelope 256B vs layout 64B — reconcile to 64 in both).
- Default `mailbox.delivery` to `["silent"]` when unset, with explicit handler log entry.
- Whitespace-only surface-name rejection.
- Duplicate surface-name detection.
- Untitled-surface helpers should not require a title.
- Malformed `--ttl-seconds` must error.
- Unicode/emoji body fixture + `invalid-bad-topic` / `invalid-from-too-long` fixtures.
- Dispatch log rotation (design doc §6 promise, unbounded in Stage 2).
- Envelope file perms 0o600 under 0o700 dirs.
- Ring-buffer `recentlySeen`.
- Unknown-handler typo log entry.
- `c11 mailbox tail` using `DispatchSourceFileSystemObject` instead of 0.25 s poll.
- `MailboxSurfaceResolver.surfaceIds(forName:)` dead code cleanup.
- `ISO8601DateFormatter` for envelope `ts` validation.
- Triple-nil coalesce smell at `CLI/c11.swift:16411`.

File these as a P1 ticket (C11-15 candidate) after the Cycle-1 rework merges.

### Execution rules for Cycle 1 rework

- **Commit per must-fix item.** One or two commits per item depending on size. Reference the P0 number in the subject: `C11-13 rework: P0 #1 — real byte parity in test_mailbox_parity.py`.
- **Push after each commit** — CI runs automatically on the open PR #73.
- **After all 8 must-fix items land:** post a Lattice comment, set status `review` on the ticket, and the delegator spawns Review Cycle 2.
- **Hot-path compliance claim:** re-read `CLAUDE.md`'s Socket command threading policy and the StdinHandler P0 #5 notes before touching `StdinMailboxHandler.swift`. If you pick path (b), the commit must include the tests proving the reporting-bound behavior.
- **Max 3 review cycles before `needs_human`.** This is Cycle 1; aim to get it right.
