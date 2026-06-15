# c11 Codebase Audit — Findings

**Date:** 2026-06-09 · **Method:** static read-and-reason audit across the whole repo (Swift app `Sources/`, Swift CLI `CLI/`, skills, docs, scripts, CI), fanned out across parallel area auditors, deduped and verified by the synthesizer. **Scope at audit time:** HEAD = `5c1227bfe`, app version 0.51.0, `TerminalController.swift` ≈19.7k LOC / 551 socket cases, `CLI/c11.swift` ≈16.7k LOC / 335 cases.

**How to read:** each bullet is `[Sev | Conf] path:line — problem (impact)`. **Sev**: High = crash / data-loss / security / deadlock / actively-wrong-behavior; Med = latent bug, race, policy violation, real maintainability hazard; Low = nit / cleanup / cosmetic. **Conf**: synthesizer's confidence the finding is real (some are static-analysis suspicions, not proven at runtime). Line numbers are from audit-time HEAD and may drift.

---

## ★ Systemic / headline issues (fix these first)

### S1. The agent-facing skill is built on `C11_*` env vars the binary never exports to shells
The single highest-impact finding. Verified live: an agent shell inside c11 has only `CMUX_*` set (`CMUX_SHELL_INTEGRATION=1`, `CMUX_SURFACE_ID`, `CMUX_WORKSPACE_ID`, `CMUX_SOCKET_PATH`, `CMUX_TAB_ID`, `CMUX_PANEL_ID`). The only `C11_*` vars exported are `C11_DEFAULT_AGENT_LAUNCH` / `C11_DEFAULT_AGENT_SEED_PROMPT`.

- [High | High] `Sources/GhosttyTerminalView.swift:3339-3413` — child PTY env is seeded via `setManagedEnvironmentValue` with `CMUX_*` keys ONLY; no `C11_SURFACE_ID`/`C11_WORKSPACE_ID`/`C11_SOCKET_PATH`/`C11_SHELL_INTEGRATION` are ever written to the shell.
- [High | High] `Sources/C11EnvBridge.swift:5-16` — `mirrorC11CmuxEnv()` (the supposed "binary dual-reads" mechanism) runs `setenv` on the **app process's own** environment at `AppDelegate.swift:2384`; it does NOT touch the spawned terminal's managed env, so the mirror never reaches agents.
- [High | High] `skills/c11/SKILL.md:19,25,43-48` — "Detect c11: check `C11_SHELL_INTEGRATION`" and the orient recipe using `$C11_SURFACE_ID`, `$C11_AGENT_TYPE`, `$C11_AGENT_MODEL` are all broken against the shipping binary; a literal-following agent concludes "not in c11" and writes empty agent identity. The documented "`$C11_SURFACE_ID` may be empty" footgun is actually the *normal* case, not an edge case.
- [High | High] `/Users/atin/Projects/Stage11/CLAUDE.md` (naming section) — claim "legacy `CMUX_*` are set **alongside** `C11_*` on current binaries… `C11_*` alone always works" is **false** for shell env. Either fix the binary to also export `C11_*` (preferred — write both keys in `setManagedEnvironmentValue`, and add a shell-integration mirror), or fix every doc/skill back to `CMUX_*`. The binary-side fix is the right one given the project's stated direction.
- [Med | High] `Sources/SocketControlSettings.swift:296-298,460,650,667` — socket-control reads only `CMUX_SOCKET_PATH`/`_ENABLE`/`_MODE`/`_PASSWORD`/`CMUX_TAG`; no `C11_*` fallback, so a caller exporting `C11_SOCKET_PASSWORD` silently fails auth.
- Decision needed: pick a direction (export both from the binary, or revert docs). Right now docs and binary disagree and agents are the ones paying for it.

### S2. Empty/missing `--surface ""` silently misroutes to the *focused* surface (the documented footgun, in code)
A blank surface ref is treated as "absent" and falls back to the focused surface across many write paths — so a sub-agent stomps a peer's terminal/metadata with an identical-looking `OK`.

- [High | High] `Sources/TerminalController.swift:7654,6363,6610` — `v2SurfaceSendText` and peer v2 handlers resolve `v2UUID(...) ?? ws.focusedPanelId`; `v2UUID`/`v2String` nil out empty strings (`:4064-4066`), so `--surface ""` injects text/keys into whatever the operator is focused on.
- [High | High] `CLI/c11.swift:2433-2435,2456` — `send`/`send-key` guard checks `CMUX_SURFACE_ID != nil` but not `!= ""`; an exported empty string passes the guard, `normalizeSurfaceHandle("")` → nil, command routes to focused surface.
- [High | High] `CLI/c11.swift:14555,15026-15034` — SessionStart conversation-push hook falls back to `resolveSurfaceId(nil)` → focused surface when `CMUX_SURFACE_ID` is absent OR when `--workspace` is passed without `--surface`; mis-keys the captured conversation ref (wrong session resumes in wrong pane). Given S1, the absent case is common.
- [Med | High] `Sources/TerminalController.swift:18034-18046,18141` — `resolveTabForReport` and panel-metadata mutation treat `--tab=""`/`--panel=""` as omitted and fall through to the focused tab/panel.
- Root fix: distinguish "absent" from "empty/whitespace" at the parse layer (`v2UUID`/`v2String` and CLI guards) and ERROR on an explicitly-empty ref instead of defaulting. `v2UUID` vs `v2UUIDAny` already diverge here (`:4114-4130`) — unify them.

### S3. Two ~16-20k-line god files concentrate the whole command surface
- [Med | High] `Sources/TerminalController.swift` (19.7k LOC, 551 cases) — extract cohesive clusters into handler types: `browser.*` (~84 cases), sidebar telemetry (`set_status`/`report_*`/`log`/`ports_kick` + v1 variants ~2358-2444,18031-18460), `debug.*` (~35 cases, `#if DEBUG`, interleaved with prod), `workspace.*`/`surface.*`/`pane.*` (~63 cases), and the socket accept/handleClient loop (~1014-1780) which is separable from dispatch.
- [Med | High] `CLI/c11.swift` (16.7k LOC, 335 cases) — extract: browser cmds (~6280-7400), SSH tunnel (~5600-5970), mailbox (~16295-16690), claude-hook dispatch (~14400-14900), snapshot/blueprint (~3054-3950). No change can safely touch two clusters at once today.

### S4. Socket telemetry hot path violates the project's own threading policy
- [Med | High] `Sources/TerminalController.swift:1903-1908,1827-1834` — every non-allowlisted command (incl. focused-target telemetry: `set_status`/`report_meta`/`log`/`set_progress` without an explicit selector) runs the full handler under `DispatchQueue.main.sync` on the worker thread, blocking main for the handler's duration. The `send`/`send_key` slow path holds it up to 2s (`waitUpTo: 2.0`, `:17196,17384`) — a typing-latency hit while the operator types. Policy says: parse/dedupe off-main, `async` only minimal UI mutation. Only the explicit-selector fast path currently honors it.

---

## Socket command layer & TerminalController

### Focus / selection policy
- [High | Med] `Sources/TerminalController.swift:174-176,400-449` — `socketCommandFocusAllowanceStack`/`socketCommandPolicyDepth` is a single **global static** push/pop stack, but each client runs on its own `Thread.detachNewThread` (`:1633`). Concurrent pushes make `.last` nondeterministic: a focus-intent command can read another's `false` (focus dropped) or a non-focus command can read a `true` (focus stolen). The nesting model assumes single-threaded execution that doesn't hold.
- [Med | Med] `Sources/TerminalController.swift:10227-10247` — `settings.open` defaults `activate=true` and calls `presentPreferencesWindow` (app activation) but is NOT a focus-intent method; a socket `settings.open` with no args steals focus, contrary to policy.
- [Med | Med] `Sources/TerminalController.swift:14220-14235` — `debug.type` calls `NSApp.activate` + `makeKeyAndOrderFront` directly, bypassing `v2FocusAllowed()`; not in `focusIntentV2Methods`. DEBUG-only but unconditionally steals focus.

### Socket I/O correctness
- [Med | High] `Sources/TerminalController.swift:1761-1762` — read chunks decoded with `String(bytes:…,encoding:.utf8) ?? ""` per 4096-byte chunk; a multibyte UTF-8 sequence split across the read boundary fails to decode and the partial bytes are dropped, corrupting `send`/`send_text` payloads with CJK/emoji. Accumulate bytes, decode after newline framing.
- [Low | Med] `Sources/TerminalController.swift:1758` — server `read()` has no `SO_RCVTIMEO`; a peer sending a partial line (no newline) parks a per-connection worker thread forever. Combined with unbounded `Thread.detachNewThread` per connection (`:1633`), a thread-exhaustion vector.
- [Low | Med] `Sources/SocketControlSettings.swift:134` — password `verify` uses `expected == candidate` (non-constant-time compare); local 0600 socket so low risk, trivial to harden.

### Response/error contract
- [Low | High] `Sources/TerminalController.swift` — v1 returns bare `"OK"`/`"ERROR: …"` strings (`:17220,18103`) while v2 returns JSON `{ok,error{code,message}}` envelopes; mixed contracts over one socket. v1 errors carry no machine-parseable code, and `CLIAdvisoryConnectivity.swift:17-27` string-matches broad substrings (`"No such file or directory"`, `"Permission denied"`) that can swallow a genuine command failure as an advisory no-op.

---

## UI / typing-latency / rendering

The four documented typing-latency footguns all still hold (hitTest `isPointerEvent` guard, `TabItemView` equatable, `forceRefresh()` allocation-free, find-overlay AppKit mount, no app-level display link). The new hot-path cost is in the **sidebar sampler**, not keystrokes.

- [High | High] `Sources/ContentView.swift:8394,8540-8587` — `VerticalTabsSidebar` observes `surfaceMetricsSampler.shared`, whose `revision` bumps at 2-10 Hz and invalidates the whole sidebar body every tick regardless of whether any displayed value changed. Each tick recomputes per-tab `canonicalMetadataSnapshot` (locked dict copy + allocs), `AgentChipResolver.resolve`, `WorktreeChipProjector.project`, themed colors, notification lookups — O(workspaces) sustained background CPU. `.equatable()` only saves row bodies, not this parent work.
- [Med | High] `Sources/TerminalController.swift:11084-11094` — `canonicalMetadataSnapshot` allocates two dicts + rebuilds `MetadataSource` per key on every call; invoked per-tab per sampler tick from the sidebar body.
- [Med | High] `Sources/ContentView.swift:11244-11245` — `TabItemView.==` compares colors via `hexString(includeAlpha:)` (NSColor sRGB conversion + String alloc) in the equality hot path, per-row per parent re-eval. Compare components directly.
- [Med | High] `Sources/ContentView.swift:2461-2730` — `ContentView.body` builds 16+ nested `AnyView(...).onReceive/.onChange` wrappers; type erasure defeats structural diffing and the whole stack + subscriptions rebuild on every body eval.
- [Med | Med] `Sources/ContentView.swift:1464-1471` — ContentView observes six observable objects; any `@Published` change (incl. chatty `notificationStore`) re-evaluates the heavy body above.
- [Med | High] `Sources/TerminalNotificationStore.swift:687-692,1009-1233` — `notifications` array has no cap/eviction; `didSet` rebuilds `indexes` O(n) and refreshes dock badge on every mutation, and each ingest copies+appends+reassigns O(n). Long agent-heavy sessions grow unbounded; every new notification costs O(n) plus a root-view re-eval.
- [Low | Med] `Sources/GhosttyTerminalView.swift:1203-1219` — app-level `appObservers` (didBecomeActive/didResignActive) appended but never removed; `[weak self]` so no cycle, but asymmetric vs other observer teardown — latent leak if the type ever becomes non-singleton.
- [Low | Med] `Sources/ContentView.swift:10797-10808` — `ArrowButton` repeat-timer closures capture `self` strongly and rely on `.onDisappear { stopRepeat() }` to break the timer→self retention; fragile if onDisappear is skipped during split/workspace churn.

---

## Workspace persistence, snapshot/restore & conversation store

### Snapshot capture/restore data integrity
- [High | Med] `Sources/Workspace.swift:181,416-428,758` — `readConversationsByPanelIdSync` returns empty `[:]` on a 2s actor timeout, then capture writes `.empty` (`active: nil`) for every terminal panel — silently dropping ALL conversation refs from the snapshot under contention, with no error surfaced.
- [Med | High] `Sources/AppDelegate.swift:2903-2927` — `applicationWillTerminate` re-reads the store via the 2s-timeout sync read on the main thread during teardown, then `promoteToClean` marks shutdown clean even if the read timed out — a "clean" marker over a conversation-less snapshot, so refs are permanently lost with no crash-recovery rescue.
- [Med | High] `Sources/SessionPersistence.swift:475-479` — top-level decode uses `try?` → returns `nil` on any decode error; one corrupt/unknown field discards the entire session snapshot (all windows/workspaces/refs) rather than salvaging intact parts.
- [Low | Med] `Sources/SessionPersistence.swift:476-477` — version mismatch discards the whole snapshot with no migration or backup; a single schema bump silently abandons full restore state.
- [Med | Med] `Sources/Conversation/SnapshotBridge.swift:32-77,68-73` — `seedFromSnapshot` keys the store by `panel.id.uuidString` (snapshot id) while the live store is keyed by surface id; if those ever differ, refs become unreachable with no validation. The seed runs under a 1s `sema.wait`; on timeout restore proceeds unseeded and silently skips all resume.

### Conversation store state machine
- [High | High] `Sources/Conversation/Store.swift:188-198` — `markAllUnknown` transitions EVERY active ref to `.unknown` on crash recovery, including `.tombstoned`/`.unsupported`; a user-`/exit`-tombstoned conversation is resurrected and re-resumed after a crash, violating "tombstone is terminal."
- [Med | Med] `Sources/Conversation/Store.swift:175-184` — `suspendAllAlive` only suspends `.alive`; a ref left `.unknown` at clean shutdown persists as `.unknown` and never auto-resumes even though the operator cleanly quit with that pane open.
- [Med | High] `Sources/Conversation/Strategies/Codex.swift:50-60` + `Store.swift:241-243` — `shouldReplace` lets a newer-mtime `.scrape`/`.unknown` ref overwrite an earlier confident `.alive`/`.suspended` ref purely on timestamp; a stale duplicate session file demotes a good ref to ambiguous. Reconciliation ignores `placeholder` status too.
- [Med | High] `Sources/TerminalController.swift:9842-9858` + `CLI/c11.swift:15110-15112` — the `state=ended`→`.unknown` "don't downgrade during shutdown" invariant is enforced only by the CLI client's pre-check, and `isAppCurrentlyTerminating` returns `false` when the field is absent from an older server response; any direct socket caller (or partial response) can demote a live resumable ref.

### Resume correctness
- [Med | High] `Sources/Conversation/Strategies/ClaudeCode.swift:56-57` — new resume types `claude --resume <id>` with no `cd <project_dir>` prefix that the legacy `AgentRestartRegistry.phase1` (`:163-168`) had; `--resume` resolves the JSONL relative to cwd, so sessions captured in a worktree/subdir become non-resumable. `ref.cwd` is carried but never used.
- [Med | High] `Sources/Conversation/SurfaceActivity.swift:70,79` + `Scrapers/ClaudeCodeScraper.swift:45-59` — the Codex "mtime ≥ surface lastActivity" disambiguation floor is permanently nil (`SurfaceActivityTracker.seed/snapshot` have zero production callers; never persisted), and scrapers stamp the surface cwd into every candidate so the `cwd != candCwd` filter (`Codex.swift:31`) is a structural no-op. The same-cwd ambiguity the primitive exists to fix is not actually disambiguated in v1 — documented as a v1.1 deferral but ships as live-but-inert code.
- [Low | Med] `Sources/AgentRestartRegistry.swift:171-174` — the `CMUX_DISABLE_CONVERSATION_STORE=1` kill-switch fallback still resumes Codex via `codex resume --last`, the exact global-lookup bug the new architecture exists to fix; the documented escape hatch reintroduces the original defect.

### Durability / cleanup
- [Low | Low] `Sources/SessionPersistence.swift:577-595` — `writeReplayFile` strands per-restore scrollback temp files under `cmux-session-scrollback/` keyed by fresh UUIDs, never cleaned up (unbounded between OS tmp reaps).
- [Low | Med] `Sources/Conversation/SurfaceActivity.swift:21,63` — mixes `queue.async` (record) and `queue.sync` (read/seed/snapshot) on one serial queue; a `queue.sync` from a context already on the queue would deadlock (no current caller, latent hazard).

---

## Browser surfaces (WKWebView)

### Arbitrary script/state injection via socket (security)
- [High | High] `Sources/TerminalController.swift:11559-11577` — `browser.eval` executes an arbitrary caller-supplied `script` in the active page's JS context. In `automation` mode (no ancestry check) any local same-user process can read cookies/localStorage/DOM of any open site.
- [High | High] `Sources/TerminalController.swift:14055-14076,14098-14129` — `browser.addinitscript`/`browser.addstyle` add persistent `WKUserScript`s (`atDocumentStart`, `forMainFrameOnly:false`) that fire on every subsequent navigation incl. cross-origin frames; the per-surface arrays are never cleared on surface close and there's no per-script removal, so they accumulate permanently.
- [Med | High] `Sources/TerminalController.swift:13925-14053` — `browser.state.save`/`load` write cookies+localStorage to / read them from an arbitrary caller-supplied path with no validation; in automation mode any local process can exfiltrate or inject session auth.

### Memory / state leaks (per-surface dictionaries never evicted)
- [Med | High] `Sources/TerminalController.swift:311-317` — `v2BrowserInitScriptsBySurface`, `…InitStylesBySurface`, `…DialogQueueBySurface`, `…DownloadEventsBySurface`, `…UnsupportedNetworkRequestsBySurface`, and `v2BrowserElementRefs` (`:311`) are keyed by surface UUID and never removed on surface destroy; open/close cycles grow them unbounded.
- [Med | High] `Sources/BrowserSnapshotStore.swift:43` — `snapshots` holds full-resolution `NSImage` page screenshots keyed by surface UUID; `clear` only fires on resume, so hibernated-but-never-resumed surfaces retain their image for process lifetime.

### Navigation policy gaps
- [Med | High] `Sources/Panels/BrowserPanel.swift:6127-6222` — insecure-HTTP block and external-URL filter only apply when `targetFrame?.isMainFrame != false`; subframe navigations to HTTP / app-scheme URLs from cross-origin iframes bypass both checks.
- [Med | High] `Sources/Panels/BrowserPanel.swift:860-874` — `browserEmbeddedNavigationSchemes` includes `"javascript"`, so `javascript:` omnibar URIs are not rejected (surprising, inconsistent with blocks on other schemes).
- [Low | High] `Sources/Panels/CmuxWebView.swift:993-1043` — context-menu "Download Linked File" for `file://` reads synchronously with `Data(contentsOf:)` on the main thread; large files stall the UI.
- [Low | High] `Sources/Panels/BrowserPanel.swift:1911-2058` — address-bar focus scripts `postMessage(..., "*")` with wildcard target origin; any cross-origin iframe can read focused-element id/selection (low-sensitivity leak, postMessage hygiene).

### Private-SPI / lifecycle fragility
- [Med | High] `Sources/BrowserWindowPortal.swift:65-68` — invokes private WebKit selectors (`_exitInWindow`, `_enterInWindow`, `_endDeferringViewInWindowChangesSync`) via `unsafeBitCast` of `method(for:)`; a WebKit signature change is a hard crash with only `responds(to:)` as a guard.
- [Med | Med] `Sources/BrowserSnapshotStore.swift:139-192` — `c11_webProcessIdentifier` reads private `_webProcessIdentifier` via KVC; on a WebKit rename the SIGTERM teardown silently no-ops. `tearDownGracefully` nils delegates before removal, so in-flight `evaluateJavaScript` completions are silently dropped (races hibernation).
- [Low | High] `Sources/Find/BrowserFindJavaScript.swift:13-103` / `Sources/Panels/CmuxWebView.swift:284-715` — `jsStringEscape` omits backticks; `findLinkAtPoint`/`findImageURLAtPoint` interpolate coordinates into JS without JSON encoding (event-sourced today, but any synthetic call-site could inject).

---

## Mailbox & metadata

### Mailbox identity / dedup / durability
- [Med | High] `Sources/Mailbox/MailboxDispatcher.swift:227` — the dispatch `id` is taken from the outbox **filename**, never validated as a ULID nor checked against the envelope's own `id`; it drives dedup, `_processing/<id>.msg`, `_rejected/<id>.msg`, and pre-validation log lines. Two files with the same stem collide in dedup; the log's id can disagree with the real envelope ULID.
- [Med | High] `Sources/Mailbox/MailboxDispatcher.swift:229,243` — dedup `recentlySeen` is an in-memory 1024-ring that does NOT persist across restart, so a re-presented `_outbox` file with the same id is re-dispatched; the documented "dedup-by-id" guarantee is lost on relaunch.
- [Med | High] `Sources/Mailbox/MailboxDispatcher.swift:99-103` — confirmed: no Stage-2 recovery sweep returns stranded `_processing/*.msg` to `_outbox/`; an envelope in flight at kill time is permanently stuck (silent loss until Stage 3).
- [Low | Med] `Sources/Mailbox/MailboxEnvelope.swift:179,331-348` — `ts` regex accepts impossible dates (`2024-99-99T99:99:99Z`); `requireInteger` accepts `1.0` for `version`/`ttl_seconds`, disagreeing with the JSON-Schema `integer` type.
- [Low | Low] `Sources/Mailbox/MailboxULID.swift:29-40` — `UInt64(date * 1000)` traps on a pre-1970 `Date`; the monotonic counter breaks lexicographic ordering across a backward wall-clock step.

### Mailbox injection / escaping
- [Med | Med] `Sources/Mailbox/StdinMailboxHandler.swift:171-183` — body XML-escaping prevents `</c11-msg>` tag forgery but does NOT neutralize ANSI/OSC control sequences; a body with raw `\x1b]…` is written verbatim into the recipient PTY — terminal-escape injection into the recipient agent's screen.
- [Low | High] `Sources/Mailbox/StdinMailboxHandler.swift:154-167` — attribute escaping covers `<>&"` but not `'`; safe today (attrs are double-quoted) but inherited by any future single-quoted emitter.

### Mailbox routing / delivery config
- [Med | High] `Sources/Mailbox/MailboxSurfaceResolver.swift:74-77` — `mailbox.delivery` is parsed as a comma-separated string; a JSON-array value (`["stdin"]`, a natural mistake) is dropped at `value as? String` → zero handlers registered, no warning. Envelopes land in inbox but never reach the PTY. Validate/warn on non-string `mailbox.delivery`.
- [Med | High] `Sources/Mailbox/MailboxDispatcher.swift:296-298` + `MailboxSurfaceResolver.swift:39-43` — two live surfaces sharing a `title` both receive a copy and both stdin handlers fire; the resolver's documented "duplicate-warning logging" is not actually emitted.
- [Med | High] `Sources/SurfaceMetadataStore.swift:200-203` vs `Sources/Mailbox/MailboxLayout.swift:143-162` — a surface `title` is validated as ≤256 chars with no path checks, but `inboxURL` requires ≤64 bytes and rejects `/`,`..`,leading-`.`; a valid-but-unsafe-as-path title resolves as a recipient then `copyToInbox` throws and the envelope is silently dropped (logged `.eio`) — undeliverable mail with no clear cause.
- [Low | Med] `Sources/Mailbox/MailboxDispatcher.swift:347-361` — an unknown handler name (typo `stdn`) logs outcome `.eio`, indistinguishable from a real inbox-write I/O failure (same code), making misconfig undiagnosable from `_dispatch.log`.
- [Low | Med] `Sources/Mailbox/MailboxLayout.swift:143-162` / `MailboxIO.swift:42` — no `O_NOFOLLOW`/realpath containment; a planted symlink at an inbox/`_outbox` dir is followed by `write(to:)`/`moveItem` (state dir is 0700 so risk is low).

### State-dir migration (legacy `c11mux` → `c11`)
- [Med | Med] `Sources/Mailbox/MailboxLayout.swift:247-257,305-308` — cross-process migration (remove legacy dir → symlink to `c11`) is unguarded by any file lock; the `didRun` latch is per-process. Two processes racing can split state or leave the symlink un-created (stderr-logged only). Per-workspace dirs present in both are abandoned silently if `current` is the empty fresh copy.

### Metadata stores
- [Med | High] `Sources/SurfaceMetadataStore.swift:539-542,623-628` — the 64 KiB per-surface cap is checked against the values blob only, excluding the parallel `sources` sidecar; values+sources can exceed the documented cap on disk (`PersistedMetadata.swift:90` re-enforces values only).
- [Med | Med] `Sources/SurfaceMetadataStore.swift:480-508` — `removeSurface`/`pruneWorkspace` use `queue.async` (fire-and-forget) while reads/writes use `queue.sync`; a heuristic `setInternal` racing an async `removeSurface` can re-create a closed surface's entry after pruning. Mixed sync/async makes ordering vs external callers nondeterministic.
- [Low | High] `Sources/SurfaceMetadataStore.swift:290-298` — string caps use `s.count` (Characters) not UTF-8 bytes, while the spec and mailbox layer are byte-based; a 256-emoji title (~1 KB) passes the 256 cap. Inconsistent with `MailboxEnvelope.ensureStringByteCap`.
- [Low | Med] `Sources/SurfaceMetadataStore.swift:163-177` — `mailbox.*` keys are non-reserved so the store accepts any JSON value, but the resolver only honors strings; a well-formed wrong-typed `mailbox.delivery` is accepted and silently ignored (ties to the delivery-parsing finding).
- [Low | Med] `Sources/PersistedMetadata.swift:273-287` — `enforceSizeCap` drops the "largest key"; one bloated non-canonical key can silently discard a canonical key (e.g. `description`) on restore-persist, with only a DEBUG log — data loss across restart.
- [Low | Med] `Sources/SurfaceMetadataStore.swift:641-649` — `sameJSONValue` dedup falls back to `JSONSerialization`; a non-serializable `Any` (stray `Date`) makes two values compare equal (both nil), so a real change is treated as a no-op and not persisted.
- [Low | Med] `Sources/Mailbox/MailboxDispatchLog.swift:82-107` — log write failures are silently swallowed; the documented "audit trail" can have gaps with zero signal.

---

## App lifecycle, default-agent, skills install, update, analytics

### Default-agent resolver (the historical A-button bug is FIXED — verify before touching)
- [Resolved | High] `Sources/DefaultAgentConfig.swift:190-206` — the legacy-array-format `~/.c11/agents.json` lenient-decoder bug that pinned the A button to claude-code is **fixed on HEAD** (decoder now throws on non-dict `agents`, so `find`'s `try?` rejects the file). No action; noted so a future change doesn't reintroduce it.
- [Med | High] `Sources/DefaultAgentConfig.swift:77-79,183-189` — `AgentConfig.init(from:)` swallows every field decode error with `try?` (corrupt `command`/`initialPrompt` → silent `""`); a `defaultAgent` naming an unknown agent (`"gemini"`) is treated as no-explicit-default and silently ignored with no log.
- [Med | High] `Sources/DefaultAgentProjectConfig.swift:24-25` — project walk looks only for `.c11/agents.json`; no `.cmux/agents.json` fallback and parse failures are swallowed, so a `.cmux`-era project config gives no override and no diagnostic.

### Skills install
- [High | High] `Sources/AgentSkillsView.swift:150-175` — `install()`/`remove()` are synchronous `@MainActor` calling blocking `SkillInstaller.install()` (dir enumeration + SHA-256 of all content + `copyItem`) on the main thread; large trees / slow FS hang the UI.
- [Med | High] `Sources/SkillInstaller.swift:195-199,339-379` — `discoverPackages` skips hidden files but `contentHash` (`:346`) enumerates with no skip and follows symlinks; a `.DS_Store` or symlinked dir perturbs the hash (spurious "outdated"→reinstall) or pulls files outside the skill boundary.
- [Med | Med] `Sources/SkillInstaller.swift:506` — `AppIdentity.current` reads `info["CMUXCommit"]` for skill-manifest `commitShort`; a release build supplying only `C11Commit` (cf. `SentryHelper.swift:152`) stores empty provenance in every installed skill manifest.

### Auto-update (Sparkle)
- [Low | Med] `Sources/Update/UpdateDriver.swift:5,128-130` — `UpdateDriver` is a plain `NSObject` with no `@MainActor`; `lastFeedURLString` is written on Sparkle's background thread and read on main with no locking (data race). `showReady(...)` unconditionally `reply(.install)`, skipping the `.installing` UI state.
- [Low | High] `Sources/Update/UpdateController.swift:11,107` — `migrationKey`/`CMUX_UI_TEST_RESET_SPARKLE_PERMISSION` use legacy `cmux` namespace (the UserDefaults key is stuck — renaming re-runs the migration for all users).

### Analytics / lifecycle
- [Low | High] `Sources/PostHogAnalytics.swift:9` + `Sources/AppDelegate.swift:2505` — PostHog public key and Sentry DSN are hardcoded in source committed to a public repo; documented-intentional (write-only) but lets anyone inject events/crashes into the Stage 11 projects.
- [Med | High] `Sources/AgentDetector.swift:67-106` — when a scan is in flight, new `kick()`/`registerTTY()` append to `pendingKicks` but arm no new coalesce timer, and `runScan`'s `defer` doesn't re-check `pendingKicks` on completion; kicks are dropped until the next 10s sweep → stale `terminal_type` for agents launched during a scan.
- [Med | High] `Sources/AppDelegate.swift:2912-2917` — `applicationWillTerminate` blocks main on `suspendDone.wait(timeout: 1.0)`; on actor contention the wait times out silently (`_ =`) and sessions persist as `.alive` for next launch, no log.
- [Low | Med] `Sources/C11EnvBridge.swift` / `AppDelegate.swift:2495-2502` — `mirrorC11CmuxEnv()` calls `setenv` (not thread-safe vs concurrent `getenv`/`setenv`) during startup while Sentry's background init reads env; the locale pre-warm guards only the Sentry call, not the mirror — possible startup SIGSEGV race.

---

## CLI (`CLI/c11.swift`)

### Socket connection
- [Med | High] `CLI/c11.swift:695-699` — `appSupportDirectoryName="cmux"` / `stableSocketFileName="cmux.sock"` and `legacyDefaultSocketPath="/tmp/cmux.sock"` diverge from the server's `c11/c11.sock` and `/tmp/c11.sock` (`SocketControlSettings.swift:300-303`). Masked in the common case because the CLI reads `CMUX_SOCKET_PATH` from env first, but a CLI invoked outside a c11 shell (relying on the stable/legacy fallback) never finds the socket. Align the constants.
- [High | High] `CLI/c11.swift:966-970` — `write()` checks `sent < 0` but not a short write (`sent < len`); a partial write silently truncates the command on the wire. Also not retried on `EINTR` (`:963`, unlike the read loop at `:984`).
- [Med | High] `CLI/c11.swift:935` — `multilineResponseIdleTimeoutSeconds = 0.12` adds 120 ms per v2 round-trip after the response newline before declaring read-done.
- [Med | High] `CLI/c11.swift:582-585,4259` — `SocketPasswordResolver.normalized()` trims only leading/trailing newlines; an embedded `\n` in a file-stored password injects a second `auth` command on the wire, and an embedded space tokenizes as two args → auth silently fails.

### Arg parsing / quoting
- [High | High] `CLI/c11.swift:2437` — `send` does not reject unknown flags; `--text "hi"` joins into the typed payload and `--text` is typed literally into the terminal (the documented footgun, unguarded in code).
- [High | High] `CLI/c11.swift:11903-11906` — `forwardSidebarMetadataCommand` quotes with sh-style `shellQuote()` but the v1 server tokenizer (`TerminalController.swift:1963-2036`) doesn't implement sh quote-concatenation, so any `set-status`/`log` message containing a single quote is split at the embedded space and silently truncated. Use `v1QuoteForTokenizer` (the path `runDefaultAgentLaunchCommand` already uses at `:11100`).
- [Med | High] `CLI/c11.swift:1524-1570` — global flags don't support `=`-form; `c11 --socket=/tmp/c11.sock …` falls through and, because it contains `/`, `looksLikePath()` treats it as a path to open rather than a parse error.
- [Med | High] `CLI/c11.swift:11008,1819,1826` — `default-agent set <type>`, `focus_window <target>`, `close_window <target>` interpolate user values into v1 command strings with no quoting; a multi-word value drops/mis-tokenizes silently.

### Error contract / exit codes
- [Med | High] `CLI/c11.swift:1574-1575,1615-1617` — missing-command prints usage to stdout then errors to stderr (split streams break stdout-capturing scripts); `c11 unknowncmd --help` returns exit 0 for a completely unknown command.
- [Med | Med] `CLI/c11.swift:1274` — `sendV2` returns empty `[:]` when the response is `{ok:true}` with no `result`; callers reading result fields get silent nil instead of an error.

### Stale `cmux`/`cmuxterm` brand in CLI internals
- [Low | High] `CLI/c11.swift:566,371` — `ClaudeHookSessionStore.defaultStatePath = ~/.cmuxterm/claude-hook-sessions.json` and env override `CMUX_CLAUDE_HOOK_STATE_PATH` use the oldest brand name.
- [Low | High] `CLI/c11.swift:289` — `discoverSockets()` filters `name.hasPrefix("cmux")`, missing any `c11-`-prefixed socket in Sentry telemetry context.

---

## Skills & docs accuracy (drift that breaks agents following the skill)

(See also S1 for the systemic env-var drift, and S2 for the conversation-hook misroute.)

### Wrong commands an agent would run and fail
- [High | High] `skills/c11/references/api.md:254-266` — documents `c11 install claude-code` / `c11 uninstall …` as top-level commands; the real commands are `c11 skill install --tool claude` / `c11 skill remove` (`c11.swift:15923-15925`).
- [High | High] `docs/socket-api-reference.md:84-105` — documents `focus-surface`, `list-surfaces`, `send-surface`, `send-key-surface`; none exist. Correct: `focus-pane`, `list-pane-surfaces`, `send --surface`, `send-key --surface`. Header still says "cmux Socket API Reference" with a dead `cmux.com/docs/api` link; access mode `cmuxOnly` is actually `c11Only`.
- [High | High] `skills/c11/SKILL.md:604-606` — says Claude resumes as `cc --resume <id>`; actual code issues `claude --dangerously-skip-permissions --resume <id>` (`ClaudeCode.swift:57`). `cc` is clang on this machine and omits the required `--dangerously-skip-permissions`.
- [Med | High] `skills/c11/SKILL.md:564 vs :571` — directly contradicts itself: "`open <url>` reuses the browser surface" vs "repeated `open <file>` stacks a new browser surface each time."

### Stale forward references / version drift
- [Med | High] `skills/c11/SKILL.md:609` — says `C11_SESSION_RESUME`/`AgentRestartRegistry` are "scheduled for removal in 0.46.0/v1.1"; current version is 0.51.0 and both are still present (20+ refs). Violates the skill-writing "no past/future backstory" rule and the deadline is factually wrong.
- [Med | High] `/Users/atin/Projects/Stage11/code/c11/CLAUDE.md` socket-path line + `docs/security-threat-model.md:244` — quote the socket as `c11/c11.sock` and `c11mux/c11.sock` respectively; the CLI constants say `cmux/cmux.sock` (the live path is `c11/c11.sock` per env, so the threat-model and CLI both disagree with reality in different directions — reconcile all three).
- [Low | High] `skills/MANIFEST.json:3-9` — registers 5 installable skills; `c11-hotload` and `release` are referenced as peer skills in CLAUDE.md but not in MANIFEST, so they can't be `c11 skill install`-ed.
- [Low | High] Residual `CMUX_`/`cmux`/`cmuxterm` in authored content that the naming convention says should be `C11_*`: `skills/c11/references/conversation.md:38,96,119`, `skills/c11-browser/references/commands.md:23,30`, `skills/c11-markdown/references/commands.md:14`, `Sources/TerminalController.swift:15146-15157` (`cmux.main` window-id match), `Sources/TCCPrimerView.swift:248` (`cmuxTCCPrimerShown`). Note these are entangled with S1 — don't blind-rename code without fixing the export side.
- [Low | High] Installed-skill sync check: `diff -rq skills/<name> ~/.claude/skills/<name>` shows only the `.c11-skill.json` marker differs on this machine — no content drift. Good.

---

## Build / release / CI / scripts

### Green-when-broken / gate gaps
- [Med | High] `.github/workflows/release.yml:155-161`, `nightly.yml:209-218` — Release/nightly build steps use `xcodebuild … build` (no `test` action) with no `set -euo pipefail`; a logic regression ships to users with no logic gate before sign/notarize/publish.
- [Med | High] no file (gap) — there is no CI lint for ungated `dlog(` calls; the CLAUDE.md documents that an ungated `dlog` breaks Release but CI compiles Debug, so it only surfaces at release-staging. All current calls are gated, but nothing prevents a new one. Add a fast pre-merge grep guard.
- [Low | High] `.github/workflows/ci.yml:215` — host-bound test step is `continue-on-error: true`, so those test classes never block merges and there's no tracking that they're excluded.

### Script injection / secrets
- [Med | High] `.github/workflows/update-homebrew.yml:33-37` — `${{ github.event.inputs.version }}` and `${{ github.event.workflow_run.head_branch }}` are interpolated directly into `run:` blocks; a dispatch caller / branch name with shell metacharacters injects. Pass via `env:` first.
- [Med | High] `.github/workflows/release.yml:151`, `nightly.yml:205` — `SPARKLE_PRIVATE_KEY` passed as a positional CLI arg to `swift … "$SPARKLE_PRIVATE_KEY"`; visible in `ps` for the process lifetime. Pass via stdin/tmpfile.
- [Low | Med] `.github/workflows/release.yml:9` — top-level `permissions: contents: write` granted to every step; scope to the upload/release step. Also `brew install getsentry/tools/sentry-cli || true` (`:311`, `nightly.yml:471`) is unpinned third-party tap at release time.

### Release integrity / robustness
- [Med | High] `.github/workflows/release.yml:30-78,329` — a `workflow_dispatch` run on a non-tag branch yields `tag = "main"`; `getReleaseByTag("main")` 404s but the build proceeds and the upload falls back to `refs/heads/main` as the tag, creating a malformed release.
- [Low | High] `.github/workflows/build-ghosttykit.yml:144-145` — `git commit` + bare `git push` with no `pull --rebase`; a concurrent push makes this fail (exit 128) and the checksum is never pinned, leaving the next run without a valid checksum entry.
- [Low | Med] `scripts/bump-version.sh:92-93`, `scripts/sparkle_generate_appcast.sh:86-121` — unquoted version used as a `sed` pattern (regex wildcards); `$SIGNATURE`/`$DMG_LENGTH` interpolated into a `python3 -c` heredoc (single-quote in output corrupts the appcast); arbitrary-XML fallback picks any appcast without matching the DMG.

### Shell-script safety
- [Low | High] `scripts/smoke-test-ci.sh:25-26` — `pkill -x "c11"` kills any exactly-named `c11` system-wide; run locally it kills the operator's production c11 (no CI/VM guard, unlike `run-tests-v1.sh`).
- [Low | Med] `scripts/download-prebuilt-ghosttykit.sh:66` — `rm -rf "$OUTPUT_DIR"` with a relative default and no cd guard; from an unexpected cwd it deletes the wrong dir.
- [Low | Med] `.github/workflows/nightly.yml:433` — `find … | head -n 1` under `set -euo pipefail`: a second DMG makes `find` get SIGPIPE → exit 141 silently aborts the function.

---

## Cross-cutting themes (for prioritization)

1. **`C11_*`/`CMUX_*` split (S1)** touches skill detection, socket auth, conversation routing, code naming. One decision (export both from the binary) unblocks the most downstream issues — do it before any blind `cmux→c11` rename, which would otherwise break working code.
2. **"Absent vs empty" ref handling (S2)** is the same root cause behind several High misroute findings across the socket layer, the CLI, and the conversation hook. Fix once at the parse layer.
3. **Silent-failure ergonomics** recur everywhere: `try?`-swallowed config/decoder errors, fire-and-forget log writes, timeouts that discard results with no signal, dropped mailbox handlers. A pass to surface these (even as DEBUG logs / non-zero exits) would sharply cut debugging time.
4. **Unbounded in-memory stores**: notifications, browser per-surface dicts, snapshot images, mailbox dedup ring, scrollback temp files. None have caps/eviction; long sessions degrade.
5. **Two god files (S3)** make every other fix riskier. Extracting handler clusters is the enabling refactor for everything above.
