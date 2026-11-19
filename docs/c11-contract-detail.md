> Detail for `docs/c11-contract.md` (frozen with it, 2026-10-31 17:46 PDT). Written by the C11H-3 owner as its implementation plan.

# C11H-3 implementation plan — pre-warm draft

2026-10-31. Owner `agent:c11-t2`; panel `C11H-3 hc backend`; worktree `~/src/c11-worktrees/C11H-3`; branch `c11/C11H-3-hc-backend`; build tag `c11-a`. Base created from `6b3885d2`; rebase to the run's current main before implementation and again before review. **Pre-warm only: no commits, builds, launches, or board writes until `GO C11H-3 pin=<ver> sha256=<sha>`.**

## Deliverable and boundary

Rebuild the hc backend around the sibling one-page contract, then deliver a draft PR to private `Stage-11-Agentics/c11h`. The contract is reviewed by the Orchestrator's two discovery seats and frozen before dependent owners implement. The owner does not launch extra review seats or contact other owners directly. All coordination is through `c11-orchestrator`.

The backend owns exact core launch, bounded asynchronous transport, inventory, creation reconciliation, input admission/control delivery, native surface lifetime and the initial integration. It supplies rendering/reconnect/restore hooks; tickets 3–9 own the behaviors named in the contract. No spike backend or historical whole-file diff is copied onto main. In particular, the diff against current main contains unrelated reversions of native panel links and flag styling, which must not be imported.

## Evidence read, and what it changes

Read `owner-common.md`, `common-rules.md`, `CLAUDE.md`, the c11 and Lattice skills, `C11.md`, `docs/c11-{plan,vision,m1-brief}.md`, the four requested exploration reports, and both reviews including their verification notes. Read the spike backend and its `GhosttyTerminalView.swift` diff from `origin/reference/spike-c11v-hc`. A read-only source archive for candidate hc `v0.1.16` is in `<run-folder>/references/C11H-3/herdr-core-0.1.16/`; it came from the upstream tag, not the reference install. The source tag must be rechecked if the GO selects 0.1.15. No hc command has been run.

Candidate protocol facts, established by source inspection rather than runtime proof:

- `paths.rs`: `HC_SOCKET` overrides config `socket`; holder sockets derive from that exact socket by replacing its extension with `holder.sock`, then adding an 8-hex instance before `.sock`. macOS's maximum is 103 path bytes, including the longest holder name. Session name alone is insufficient.
- `api.rs:hello`, `api/types.rs:HelloResult/StatusResult`, `client.rs:build_id`: hello returns generation/version/core/methods/features, not a binary build hash. Status supplies a pid; hc's internal macOS build identity is device/inode/mtime/size. Verify the Unix peer and executable independently, and retain the immutable pin path.
- `events.rs`, `api.rs:events_subscribe`: snapshot and subscription registration share the registry lock. `missed` carries a replacement snapshot; subscribe has `seq`, `terminals`, `channel`. The sequence belongs to the core process and covers documents/remote events as well as local terminal changes. Subscribe unfiltered and advance over every valid event.
- `server.rs:read_frames`: terminal.run tasks survive client disconnect; cancellation only cancels machine.exec. A successful empty snapshot on a new connection can race an old create task. A 30 s resolution deadline ends silent waiting: records/removals settle known attempts; otherwise surface creation_uncertain with Retry safely. That action performs the same-session planned recovery below and waits for actual old-process exit plus post-adoption inventory before replacement. Elapsed time alone does not cancel a run task.
- `api/run.rs`: creation records labels before sending SPAWN; a non-kept timed-out spawn may remove its record. runtime.rs:spawn_result kills/releases a late successful spawn after its record was removed. A removed observed attempt is settled; a never-observed attempt may still be in the untimed holder handshake, so it uses the safe-retry path. Default shell comes from shared hc config unless argv is supplied. Use the shell/command already chosen by c11, not that default.
- `wire.rs`: 9-byte header, channel u32 LE, kind u8, payload length u32 LE; max payload 16 MiB; initial stream credit 256 KiB. CREDIT is an output-flow acknowledgment, **not input delivery acknowledgment**.
- Existing c11 input transactions serialize writers but have delayed Returns and do not report transport admission. All such paths must consume the new result; a wrapper around the old ring alone cannot satisfy A5.

## Concrete contract types

These become code in `HCContract.swift` at contract freeze. Consumers depend on typed values, not raw JSON or direct hc RPCs. All value snapshots are immutable/Sendable; runtime queues/observations are explicit.

```swift
struct HCTerminalKey: Hashable, Codable, Sendable {
    let owningCoreID: String
    let localAddress: String // tN; machine aliases never enter the key
}
struct HCRevision: Equatable, Sendable {
    let connectionGeneration: UInt64; let sequence: UInt64
}
enum HCLifecycle: Sendable {
    case new
    case live(HCTerminalRecord)
    case ended(HCEndEvidence)
    case unresolved(HCPanelIdentity, HCUnavailableReason)
}
enum HCPersistence: String, Codable, Sendable { case persistent, nonpersistent }
enum HCReadiness: Sendable {
    case pending(HCUnavailableReason)
    case ready(HCRevision)
}
enum HCInputOutcome: Sendable {
    case refused(HCInputRefusal) // zero bytes transmitted
    case written(HCWriteReceipt) // never "executed" or "agent acknowledged"
    case uncertain(HCWriteReceipt)
}
```

`HCPanelIdentity`: panel UUID, optional terminal key, persistence, optional outstanding creation UUID. `HCTerminalRecord`: key, labels, machine display name/availability, state, pid, cwd/foreground (pid/name/argv/cwd), title, status/status timestamp/turn, grid, screen exactness, exit code/signal/reason. `tty` and process start time are optional local kernel facts from proc_pidinfo, owned by tickets 7/8 and validated against pid reuse; neither comes from hc. hc strips program_started_ms from Public. Remote records carry neither local fact, and remote pids never supply local ancestry evidence. Public created_ms remains record metadata, not process identity.

`HCBuildIdentity`: pin version, archive SHA-256, executable SHA-256, canonical path, file identity, peer pid/start time, core id and protocol generation. `HCInventorySnapshot`: readiness, revision, record map, build identity (optional while pending), panel bindings and machine availability. This is the single source for tickets 3/7/8/9/15; the raw unfiltered terminal map includes unlabeled local terminals for terminal-birth admission.

`HCEndEvidence`: terminal key or creation intent, revision, evidence kind (finished, observed removal, post-adoption absence, verified create rejection), hcReason verbatim when supplied (including holder_lost, stopped_by_restart, host_shutdown, server_stop, killed, exited), and exit/signal if present. Evidence is consumed once to authorize a replacement; an ended snapshot cannot authorize two creations. `HCCreateResult` distinguishes created/bound, rejected-before-transmission, and unresolved. `HCEndResult` distinguishes confirmed, pending and unresolved; an RPC acceptance alone is not terminal death. Unexpected `keep=true`/live-without-pid remains unresolved for process recovery; no resume into it.

`HCInputRequest`: operation UUID, panel/key, attachment generation, typed source, complete payload/submit intent, optional screen-guard callback; `HCWriteReceipt`: operation UUID, generation, body bytes written to the transport, Return-written flag. `HCInputRefusal` is a stable reason enum (unavailable, stale identity, guard refused, screen unavailable, too large, queue full, input fault). Operator keys/paste and native query replies use the raw lane, not a second programmatic submit API. No body text in receipts or diagnostics.

The public session signatures are fixed here; concrete error/result payloads are the named value types above. `HCCreateRequest` carries panel identity, a freshly claimed creation UUID, selected argv/cwd, managed/configured environment overlays, and the in-memory initial-input intent. The durable intent store contains identities/status only, never that text or environment. `resolve` and `create` also read that store; callers cannot authorize a second creation themselves.

```swift
// HCSession; thread-safe registration, bounded async work, no caller queue waits.
func observe(on queue: DispatchQueue,
             handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation
func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle
func create(_ request: HCCreateRequest) async -> HCCreateResult
func attach(_ key: HCTerminalKey, sink: HCOutputSink,
            display: HCDisplayState) async throws -> HCAttachment
func end(_ key: HCTerminalKey) async -> HCEndResult
func diagnostics() async -> HCDiagnostics
// HCAttachment; synchronous call schedules retirement and returns immediately.
func detach()
```

`HCSession` exposes the functions named in the contract. Observation registration/cancellation is thread-safe; registration delivers the current snapshot first, including unready state. Observers receive the current state first and latest consistent snapshots in order on their nominated serial queue; UI snapshots are coalesced at most every 50 ms with structural sharing. Admission checks the off-main reducer immediately and does not wait for a UI tick. Observer work cannot block the reducer. `resolve` consults only the authoritative snapshot and pending intents. `create` serializes per-panel admission; `end` always uses an exact key, never a label alone. terminal.run has a client deadline of at least 20 s, longer than the normal holder-start plus HC_SPAWN_MS bounds; the 2 s connect/hello deadline is not its RPC deadline. Pending calls are bounded and have independent total deadlines; no semaphore wait on main, reader, or output queues. Request IDs and channels are connection-generation scoped.

`HCOutputSink` receives generation-tagged ordered bytes on a per-panel serial lane and a retire completion. The retained lease owns the native surface pointer and both callback contexts until retirement, never weakly assumes the panel still exists. Main removes the surface from use, closes input admission, cancels new output deliveries and requests retirement without waiting. Output already in progress finishes while main continues draining Ghostty's mailbox. Only then is native free enqueued on main; userdata is released after free. No main-held lock spans `ghostty_surface_process_output`, and no output path synchronously enters main.

`HCDisplayState`: grid, pixel cell dimensions, fg/bg/cursor colors, focus, display generation. Ticket 5 computes it and asks the attachment to serialize it. Initial output may precede channel registration; it is retained in order within the cap or the connection is explicitly invalidated. The typed screenCurrent(after: HCDisplayRevision) async -> HCScreenReceipt? hook is declared by 2 and implemented/proved by 5. It returns a receipt only after the full reattach paint is parsed and grid/attachment generation match, within 2 s; otherwise nil and screen_unavailable. Tickets 4/6/8 use it and a fresh attributed-cell guard. An attach reply, timer or terminal.read is never a receipt.

## Implementation order after GO

1. **Pin and freeze.** Record the GO verbatim and compare its SHA with the downloaded archive; separately hash its extracted executable. Re-read the chosen tag if different. Fill the binding version/hash in the contract, send it for the required two-seat review, incorporate reproduced findings and obtain the Orchestrator's freeze. Only then publish `docs/c11-contract.md` and the typed consumer seam. Use the owner board transitions and `lattice plan write` with actor `agent:c11-t2`; open the private draft PR early. No board write before GO.
2. **Launch and wire.** Add pure launch/path/environment policy, pin verification and Unix peer process verification. On a serial launch queue read kern.maxfilesperproc; set soft NOFILE to min(finite hard, kernel cap), treating infinite hard as unbounded and leaving hard unchanged; re-read and require effective soft at least 8192, emit before/after/kernel-cap evidence, then run the pinned executable's `server start` with a bounded helper deadline. A helper timeout terminates only that helper, never a holder/core. Connect and complete hello/status identity within one 2-second monotonic deadline; partial reads/writes do not reset it. Parse length before allocation, reject invalid frame kind/size, bound pending RPCs (256), and use separate data/control budgets. Distinguish same-session foreign build from unknown session. For the former use one planned restart through the exact verified connection, wait for that pid/start-time incarnation to exit, then start the pin. Never signal an unknown session or any holder. Bound one recovery attempt to 30 s and expose recovery_required plus Retry recovery on failure.
3. **Inventory and lifecycle.** Implement a pure snapshot/event reducer and its socket adapter. Reassemble JSON lines across frames; install snapshot before publishing deltas. `missed` atomically replaces records, including removals. A sequence gap revokes readiness; heartbeat ahead of applied seq requests resnapshot, heartbeat behind does not rewind. Known unrelated event types (including doc) advance seq without invalidation. Unknown additive events also advance seq and trigger one coalesced refresh while retaining existing state; do not loop on a repeatable nonterminal event. A terminal mutation that cannot be decoded revokes readiness and reports incompatible capability. Keep local and remote authority distinct. Ticket 2 persists each creation intent atomically before run outside session autosave, adds c11.creation and c11.panel labels, and resolves every restored/keyless/saved-new panel before creation. Only the active attempt may bind; late superseded records go to Recovered. Label reconciliation preserves key and initial-input status. Never infer death from list failure or lack of a Ghostty surface.
4. **Input and surface wiring.** Add whole-operation admission above Ghostty and a preallocated nonblocking callback queue below it. Reserve body plus framing/submit capacity before accepting a paste; gather/encode within the reservation before sending any body bytes. Determine the real Ghostty callback completion boundary, rather than assuming `ghostty_surface_text`'s return means IO completion. If existing API cannot delimit a complete encoded paste, use a small explicit encoding/capture seam and flag any needed native change to the Orchestrator before changing the submodule. Raw callbacks cannot return an error (C signature is void): latch a failure, suppress further input/Return and report it asynchronously. All programmatic sources (send, text box, file paste, Feed, mailbox, launch prompts, resume and initial input) use submit and receive admission/uncertainty. Operator paste uses a Swift reservation before native submission; without a proven whole encoded callback/completion seam it is refused before calling Ghostty. Ticket 2 installs the generation cancellation at every delayed-Return path in GhosttyTerminalView, TerminalController, MailboxStdinBuffer, LaunchPromptDelivery and Panels/TerminalPanel (LaunchPostBootSequence), before ticket 3 starts; 6 and 8 consume these hooks only. Ticket 2 also converts CSI I/O to FOCUS and orders resize before its query report.
5. **Safe output and launch integration.** Replace the spike lock with asynchronous lease retirement; connect the child-exit notification once per terminal key. For each create/split overwrite all three inherited `io_*` fields. Extract the existing shell/command/environment construction unchanged in meaning; preserve c11-managed identity, wrappers, shell integration, TERM/TERMINFO/COLORTERM/GHOSTTY values and explicit env overrides. Initial input is a distinct bounded operation owned by a creation, omitted from every reattachment's native config. Expose host/persistence from the beginning, including plain-shell fallback. Keep all unrelated link, flag, theme and portal behavior from current main.
6. **Proof and handoff.** Run targeted logic gates, mutation checks and guest scenarios below. Send the updated acceptance table with the draft PR. Rebase on current origin/main, repeat the necessary exact-head native gate, push explicit paths, mark ready and send `READY C11H-3 <PR#> <sha>`. Remain available through the two discovery reviews, synthesis repairs, merge and post-merge review. Merge Captain lands; owner never pushes to c11 or merges independently.

## Environment and isolation details

Do not create a second home or rewrite shell rc files. The core launch environment removes inherited `HC_*`, all `XDG_*`, c11/legacy panel identity and harness launch identity; it then sets the owned HC_SESSION/HC_SOCKET and HC_SPAWN_MS=10000. Terminal overlays cannot change or clear HC_*; the five runtime identity/socket/scope values hc supplies are intentional additions. Preserve ordinary user environment needed by shells, including HOME, SHELL, PATH, locale, TMPDIR and SSH_AUTH_SOCK. Explicit per-panel launch overlays restore that panel's intended XDG values without putting them on the core. Compare executable behavior against today's exec shell in a guest; a core-wide sanitized environment must not erase per-panel overrides or shell login behavior.

hc persists `terminal.run.env` in plaintext. Do not copy a whole agent process environment into that map or log it; pass the existing managed/configured terminal overrides and the explicit shell differences, keeping ordinary inherited environment on the core. Preserving those explicit overrides accepts hc's disk persistence of C11_AGENT_TASK and any explicitly configured credentials; do not imply that the private wire field encrypts or omits them. Measure this boundary against the actual exec environment before claiming parity. Pin installation/retention belongs to Pathfinder and ticket 10; this backend verifies and consumes it. Never hash or print tenant tokens, signing material or terminal content in diagnostics.

The c11 socket/holder directory is private, owner-checked, nonsymlinked and stable. Config is shared but never edited; explicit socket overrides its `socket` field. Check current session's core.lock hint for a different endpoint and refuse a launch relocation rather than adopting another directory. Never scan or clean default-session resources. A same-session foreign executable enters the verified planned recovery path; a changed/missing owned pin file or unknown core id is a visible recovery_required condition with no mutation. Hash the executable once per file identity; check identity on each connection. Mixed old holders may be non-current while draining and are retained. File-hash verification is not a hostile same-user attestation mechanism; M1's normal-use bar assumes the retained version path is immutable through updates. Prove rejection of a different same-version executable at another path.

For tag `c11-a`, the literal rule makes session `c11-c11-a`; naming does not strip a prefix. Release uses `c11`. At the current home path both socket and longest holder path fit Darwin's limit. Ticket 11 uses an owned --via adapter which sets the exact build-host executable, HC_SESSION, HC_SOCKET, HC_SPAWN_MS and sanitized no-XDG core launch environment; no default hc dial, remote --install or PATH lookup. A shortcut relying on an already-running core is insufficient.

## Bounded input/output behavior

Limits in the contract are admission limits, not truncation lengths. A too-large single operation is rejected before transmission. Bound one encoded transaction to 1 MiB and aggregate queued input to 4 MiB; reject beyond the cap. Limit control to 256 KiB, coalesce per-channel CREDIT with checked arithmetic, retain newest display values only where no DATA ordering barrier is crossed. Reserve CLOSE/control capacity; if control can no longer be represented, invalidate the connection and report uncertainty. Event/early-channel buffers share a 4 MiB cap; no extra speculative credit. Output queues are charged to stream credit (256 KiB per channel) and return credit only after consumption, including events after reduction.

The writer finishes one frame before another. Bound native output chunks to 64 KiB. No unbounded dispatch closures holding Data and no busy sleep loops. An autorelease pool drains each worker iteration. Unknown channels can be buffered only while a matching attach/subscription is pending; stale channels/generations never receive a later panel's bytes. fd ownership belongs to the connection object until reader and writer retire, avoiding close/reuse races.

No replay of uncertain input. An unsent queued request may be held by ticket 6 only with full payload, identity and outcome ownership; after reconnect it needs a newly parsed local screen and a new guard decision. Initially refuse disconnected input visibly. On mid-write failure, cancel the operation's Return and every existing delayed-submit callback that references the invalid generation. A Return already written cannot be recalled and is reported in the receipt, never falsely described as cancelled. A successful socket write is transport completion only. Initial input with an uncertain outcome is not repeated on restore.

## Tests and evidence

All future commands run from the owner worktree. Builds/tests only via `<run-folder>/bin/atlas-build --tag c11-a`; narrowed `--mode test -- -only-testing:c11LogicTests/<Class>`. Runtime launches, deliberate fault servers and all process signals run in a leased build-host guest. Do not launch the candidate hc on the host. Evidence goes under `<run-folder>/evidence/C11H-3/`. No proof has run during pre-warm.

| Acceptance | Behavioral test / guest observation | Bound and mutation |
|---|---|---|
| A1/F8: isolation and serving build | `HCLaunchPolicyTests`, `HCPeerIdentityTests`; guest default+c11 sessions, conflicting inherited HC_SOCKET/config socket, restart/kill each exact core pid; same terminal pids, correct holder prefixes; managed shim refuses update/autostart and absolute foreign binary at the same session recovers through one planned handover; different core id untouched | 60 s each fault/recovery; remove socket override/build check and retain failing evidence |
| A4: async connect | `HCTransportTests` fake Unix server: never hello, byte-trickle hello, overlong line, bad length and partial frame; periodic main-queue heartbeat continues | 2 s aggregate connect/hello/status; 5 s watchdog; remove monotonic deadline/size guard and show failure |
| A4: no teardown deadlock/UAF | `HCOutputLeaseTests` executable fake sink waits on main while retirement starts; guest flood OSC title/bell/cwd and repeatedly close/recreate, then quit | 2 s UI-heartbeat stall failure, 60 s case; unsafe synchronous retirement produces red test; native guest proof required |
| A5: saturation/control | `HCInputAdmissionTests`; fake transport accepts short writes/EAGAIN then fails; exact receiver bytes, transaction outcomes and absence of cancelled Return; CREDIT still drains when DATA full | 60 s case; remove reservation/uncertain-generation gate and show red; test delayed Return from existing c11 path too |
| A6: no duplicate | `HCLifecycleTests`; delayed/failed list, run reply lost, old run completes after a later empty snapshot, duplicate live labels, restored saved-new panel with an outstanding durable intent, app relaunch during recovery, never-observed request through an untimed holder handshake; exactly one terminal after successful resolution or a bounded explicit recovery state, never an indefinitely blank panel; zero typed resume | 60 s case; remove unresolved/no-retry rule to show second run; use native label inventory in guest |
| A9: inventory | `HCInventoryTests`; snapshot+early event, split JSON line, duplicates, gap, missed replacement, old-generation event, removal while absent, pending pid then terminal birth report | 60 s; observe current pid/status/seq/readiness and admission, not panel count; disable replace/revoke logic and show red |
| F1: descriptors | `HCLaunchLimitTests` isolated launcher behavior plus guest `open`-launched app spawning core itself and creating 200 panels; no pre-started high-limit hc | 5 min setup, then 2 min settle observation; record soft/hard/kernel cap before/after and 200 persistent records; account for libghostty pre-raising the app limit and force 256 only inside the isolated mutation launcher |
| Rows 1/3/4/5/18/25/31/32 | Guest parity of shell argv/cwd/managed env and intentional ulimit -n difference, one-shot initial marker, child exit, split isolation, title/cwd, query/focus/resize order; ticket 5 completes visual/latency measurements | 60 s per behavior; never print secret env; initial marker must appear once through reattach |

Each added rule test includes a real red/green mutation pair with logs; tests do not read source/plist/project files as assertions. Keep functional fake-transport tests separate from native guest proof. Replace these provisional procedure limits with Pathfinder matrix values when it arrives; do not silently weaken acceptance.

Ticket 2's PR must state every not-yet-verified consumer behavior, candidate-pin residual, guest limit (bell/IME) and the tested base/head. Returning from `build-for-testing` is not a test pass: parse `** TEST SUCCEEDED/FAILED **`, executed test count and `C11_REMOTE_OK`. No GitHub CI exists on this private repo. No skill sync is run; ticket 9 edits only the fork's bundled guide.

## Repair 1 evidence and decisions

Both reviews were read in full: `<run-folder>/reviews/C11H-3-contract-{opus,fable}.md`. This repair changes drafts only; no implementation, builds, hc command or runtime probe ran.

**Opus 2 / Fable 1: distinguish the spawn deadline from the whole request.** The requested timeout-only proof is not present in this pin. `api/run.rs:94` awaits `ensure_holder()` **before** inserting a record at lines 130–163 and starting the 10 s spawn timer at lines 165–166. `runtime.rs:244–264` sends ensure_holder to a blocking task, acquires holder_start, waits up to 5 s for the socket and calls take_over. `runtime.rs:326–338` then performs untimed WELCOME/TAIL reads. A holder accepting but not answering leaves the run before insertion even while unrelated inventory snapshots succeed. A delayed task can therefore still insert after an empty snapshot 10 or 30 seconds later. `server.rs:318–332` does not cancel terminal.run on disconnect. This is a concrete source failure path, not a reproduced runtime claim.

The bounded contract is instead:

1. Before transmitting any run, persist active creation UUID, panel UUID, core incarnation (pid + kernel start time), operation status and initial-input status in `HCCreationIntentStore`. Store at `~/Library/Application Support/c11/HC/<session>/creation-intents.json`, atomic temp/write/fsync/rename plus parent-directory sync, on a worker queue. No command, prompt or environment values. Autosave is not the commit barrier. If writing fails, transmit nothing. Serialize this store's per-panel claim; do not create a second independent journal.
2. Close the transmitting connection on ambiguous run outcome; record monotonic closure time. After an app restart, start a fresh conservative 30 s wait from the first reconciliation (persisted wall time cannot shorten it). Keep terminal-created events and pending records visible. A known attempt's terminal or observed removal is authoritative: insertion occurs before SPAWN, and `runtime.rs:613–647` kills/releases any successful spawn whose record was removed. An observed finished/removed attempt may settle immediately. For an unobserved attempt, elapsed time is never absence proof.
3. Within 30 s resolve by active creation label to the existing terminal or an ended proof; otherwise expose `creation_uncertain` and the explicit **Retry safely** action. This is an actionable terminal state, not a hidden infinite spinner. The action calls `recoverSession(.creationUncertain)` once. It waits for the transmitting core pid/start-time incarnation to exit, restarts the exact pin at the same tuple, and requires a ready post-adoption snapshot. Matching live attempt binds; authoritative absence ends the attempt as createRejected, consumes that evidence once and allows one new UUID attempt. No original request can execute in the replacement process. No Return/resume is sent merely because recovery started. A recovery timeout (30 s) is visible recovery_required; it never invents death or authorizes a second run. A later superseded record is placed in Recovered rather than rebound.
4. If a natural core restart already supplied that proof, no further restart is needed. If the chosen pin changes, re-audit ordering before retaining any deadline. The 30 s limit is a client resolution/recovery policy, not a false claim that upstream has a 15 s total request timeout. This implements Opus 2's explicit-recovery alternative with a safe restart instead of an unsafe “start anyway”.

**Opus 1 / Fable 3: prevent ordinary foreign launch and recover explicit bypass.** A PATH shim in c11's own wrapper directory invokes `c11 hc`, an existing-connection adapter implemented by ticket 2 (new CLI file `CLI/HCCoreCommand.swift`, new socket handler `Sources/SocketHandlers/HCCoreHandlers.swift`). It never execs an hc binary, so a successful ping followed by a core crash cannot autostart from terminal XDG/env. M1 supports help, server status/restart, ls, get and run with argv/cwd/explicit env/labels/no-parent/no-notify through the pin's RPC schemas; unsupported commands return hc_command_unsupported, and start/update return hc_managed_runtime. The shim adapts only a call whose caller HC_SESSION and HC_SOCKET both identify this c11 instance's owned tuple. If either names another session/socket, or the owned tuple cannot be established, resolve the next PATH hc excluding the shim and exec it with argv/environment unchanged. Outside c11 it likewise falls through; only c11 terminal PATH contains it. This does not edit tenant config or the installed reference hc. Agent-created unlabeled terminals still enter the session inventory and Recovered. Remote terminals use ticket 14's existing-connection relay once that exists; no local-CLI routing is inferred remotely.

An absolute foreign hc invocation may bypass the shim. Classify `foreign_build` only after peer uid/pid/start time, status pid, canonical own socket, core.lock endpoint and stable core id from the owned session's core.json agree. `HCSession.recoverSession(reason:)` invalidates all input generations, issues one `server.restart` on that already-open verified peer connection, and observes process exit/lock release before invoking the pinned binary's server start with the clean tuple. Recovery must recheck protocol generation compatibility; unknown generation fails visibly before mutation. After hello/status/build checks, resubscribe and reattach, retaining all live keys. Read holders[].current for diagnostics, not as an all-current invariant: older-build holders can retain live terminals legitimately. Check that pre-recovery terminal keys/pids persist. Do not kill holders or a foreign session. The recovery deadline is 30 s; a foreign process winning the replacement race or refusing the handover produces recovery_required with Retry recovery and identities, not an endless automatic restart loop. No protocol/binary-mismatch exec fallback is added.

**Opus 6: Darwin limits.** Source `ghostty/src/os/file.zig:12–48` already raises the app's soft limit; exec children restore the old one, manual hc children do not. The launcher independently computes `target = min(hard == RLIM_INFINITY ? kernelCap : hard, kernelCap)` from getrlimit and sysctl kern.maxfilesperproc, sets only soft, re-reads and verifies `min(readSoft, kernelCap) >= 8192` with hard unchanged. A preexisting readSoft above the effective kernel cap is already sufficient; do not lower it simply to match a printed number. If a finite target cannot be installed or the effective value is below 8192, return `hc_fd_limit` visibly; no silent fallback for a launch-policy error. Record kernelCap and before/after soft/hard. The reviewers disagree on whether infinity is accepted on this build host; the finite-effective-target rule does not depend on that behavior. This owner ran no new probe.

**Opus 5: typed input/readiness paths.** Add these value/API declarations to HCContract:

```swift
enum HCInputSource: Sendable {
    case socket, textBox, filePaste, feed, mailbox, launchPrompt, resume, initial
}
typealias HCInputGuard = @MainActor @Sendable (HCScreenReceipt) -> Bool
struct HCInputRequest: Sendable {
    let operationID: UUID
    let panelID: UUID
    let key: HCTerminalKey
    let attachmentGeneration: UInt64
    let source: HCInputSource
    let payload: Data // complete body; bounded before native encoding
    let submitReturn: Bool
    let screenGuard: HCInputGuard?
}
struct HCDisplayRevision: Equatable, Sendable {
    let attachmentGeneration: UInt64
    let displayGeneration: UInt64
}
struct HCScreenReceipt: Sendable {
    let revision: HCDisplayRevision
    let parsedOutputWatermark: UInt64
    let columns: UInt16; let rows: UInt16
}
enum HCRecoveryReason: Sendable { case foreignBuild, creationUncertain, inputFault }
enum HCRecoveryResult: Sendable {
    case recovered(HCRevision)
    case refused(HCUnavailableReason)
    case recoveryRequired(HCUnavailableReason)
}
// HCSession, callable off-main; one operation per session incident.
func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult
// HCAttachment; 2 declares/routes, 5 implements/proves, 4/6/8 consume.
func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt?
func submit(_ request: HCInputRequest) async -> HCInputOutcome
```

`submit` stores a source enum (socket/textBox/filePaste/feed/mailbox/launchPrompt/resume/initial), terminal key, operation id, attachment generation and optional guard. Guard execution is on main against an HCScreenReceipt and current attributed cells; the worker never reads AppKit. The request cannot retarget to a replacement key. A reattach invalidates the old guard; obtain a new receipt and guard immediately before accepting held input. Receipt invalidation/timeout returns refused(screenUnavailable) before any input. Guarded sources do not automatically become unguarded when the screen is missing. Initial input waits for the first attachment, is recorded as attempted before any bytes, and is never repeated on uncertainty. With no native surface (locked screen), retain the bounded launch specification without terminal creation or initial delivery; report queued, not delivered.

Native source now narrows the paste proof: `ghostty/src/Surface.zig:6307–6313` queues opening fence, body and closing fence as one write_alloc; `termio/Thread.zig:346–353` passes that whole message to `Manual.queueWrite`, whose `Manual.zig:43–78` calls the write callback once, even after linefeed expansion. However `Surface.queueIo` uses sendNonBlocking and the public text API has no operation acknowledgment. Ticket 2 must prove reservation-to-callback attribution and completion/overflow using the actual path, including concurrent query replies; a returned C call or elapsed delay cannot prove success. Reserve worst-case encoding capacity before native text; reject beyond encoded 1 MiB and never enqueue a body prefix. Until that proof exists, `submit`/operator paste refuse before invoking native text. This is a development fallback, not a waiver of M1 paste acceptance. Any additional native seam requires private fork/submodule ownership coordinated through the Orchestrator; no public source push from this run.

Ticket 5 implements the complete-paint boundary and parser/output watermark for screenCurrent; the hc attach reply has no paint length/completion field. The pin's first paint is ordered before live stream data (`viewers.rs:55–86`), but frame boundaries are not paint boundaries. A guessed first DATA frame or a quiet timer cannot set readiness. If the complete boundary cannot be proven, screenCurrent returns nil and the required rendering/input gate remains unverified; no consumer supplies its own heuristic. This unresolved implementation proof has a named owner and a fixed API/failure result.

**Consumer questions decided.** These are contract rules, not options for downstream owners:

- Ticket 3 places every unclaimed live terminal of this session in Recovered, including unlabeled hc-run children. Remote keys use owning machine core id from machine inventory and the remote-local tN; a rename changes routing, not identity. Mirror removal is not end evidence. Explicit workspace/window close ends contained sessions; app Quit only detaches persistent sessions, while exec fallback still ends.
- Ticket 7 waits asynchronously up to 2 s at birth, refreshes once, returns hc_inventory_pending when not ready or an own pending creation has no pid, and hc_caller_not_owned only after an authoritative refreshed inventory/ancestry check. Caller gets retryable status on pending, never a permanent refusal cached from that state. Ticket 7 owns adapting one-shot reports to retry/spool under their deadline; this must be proved against actual wrapper timeouts. Local kernel-derived process start time and tty are optional facts, not fabricated wire fields.
- Tickets 4/6/8 route all automated text through submit; operator keys/paste use raw IO with reservation for paste. Query DATA (including OSC 52) is refused while the input fault is latched, preventing it from interleaving with a truncated command; control CREDIT/CLOSE/RESIZE/FOCUS/FACTS continues. Ticket 6 shows an Input interrupted mark plus Retry input; it requires a new attached/parsed generation and explicit retry, clears no bytes into the program, and never repeats prior input. Program queries may time out during the fault; that is an explicit degraded state, not successful delivery.
- Ticket 9 maps refused to nonzero/zero bytes/retry safe; written to transport delivered and submitted only when Return was written; uncertain to nonzero/retry unsafe. Feed uses the same values; queued is an unresolved pending receipt. Never reclaim/replay an uncertain mailbox/Feed send as if nothing happened. HCEndEvidence keeps hc's reason verbatim, so holder_lost is counted exactly.
- Ticket 11's --via adapter names exact remote binary and complete tuple, strips inherited XDG from the core launch and raises/verifies its limit before any possible autostart. Ticket 15 marks unresolved persistent sessions Reconnecting, retains their host and persistence, and never labels them nonpersistent merely for being unreachable.

**Still open implementation proof, with owner:** 2 native paste completion and durable intent fault tests; 5 complete paint receipt/resize cost; 7 terminal-birth report deadline/retry-spool behavior; 11 actual remote adapter invocation/runtime isolation. Each has the failure behavior above. Pin/checksum stays Pathfinder/Orchestrator's GO; the contract is not frozen by this repair.

**Added review proofs after GO:** late holder WELCOME beyond 30 s must not authorize a duplicate; lost-run/no-record must reach the explicit recovery state by 30 s; Retry safely then yields exactly one bound live process once recovery succeeds. Absolute foreign hc restart in a guest must recover from its path while reference default terminals survive. Every delayed Return site must fail a mutation that removes its generation check. New native paste tests must cover a whole one-callback body, unrelated replies, dropped native mailbox work, encoded expansion, saturation and no Return after failure. Screen tests split the first paint over many frames and permit readiness only after full parsing. None of these proofs has run in pre-warm.


## Repair 2 and parallel delivery

Applied Fable verification R1/R2 exactly to L3/L2. The normal holder-socket plus spawn waits must fit inside terminal.run's client deadline (at least 20 s); the previously documented untimed WELCOME/TAIL caveat remains. Do not apply the 2 s connect/hello budget to a run. With 200 creations, queue unsent requests locally rather than consuming their run deadlines while waiting for a transport slot; every deadline starts at its documented operation boundary, never extends on received bytes, and no failure authorizes a duplicate. Add a behavioral slow-valid-run test (reply after 15 s, before 20 s) that keeps existing attachments; retain the wedged-handshake recovery test.

Shim tests cover matching c11 tuple (adapt), foreign HC_SESSION with inherited c11 HC_SOCKET (fall through unchanged as R2 requires), foreign socket, and no established owned tuple. A recording real-hc fixture beyond the shim in PATH must receive the original argv/environment without recursion; the adapter must not receive those foreign calls. No reference hc or tenant config is changed.

The contract's Parts section is the delivery/ownership authority. The six implementation steps above describe dependencies, not one owner's serial schedule: **2A** owns launch/recovery/lifecycle, **2B** transport/inventory, **2C** input/surface activation. This owner keeps 2A at Astra xhigh; the Orchestrator dispatches two distinct Astra high seats under the named actors/branches only after freeze/GO. No extra seat, branch, commit, build or board transition is created by this repair.

**First PR and shared seam.** 2A's first PR contains the frozen docs/c11-contract.md plus HCContract.swift and HCBackendInterfaces.swift, followed by its implementation. The initial interface commit gives all three branches one identical compileable base: injected HCConnectionFactory/HCConnection, HCInventorySource, HCInputPort and HCScreenProvider protocols, using the public value types already specified. HCSession receives these dependencies; HCUnavailableRuntime is explicit unavailable/zero-transmission, with no core or terminal launch. Fake peers/sinks exercise real launch decisions, durable intents and lifecycle transitions, not source shape. 2A alone owns those shared declarations; additions go through the Orchestrator's contract process.

**File boundaries.** 2A owns HCSession, HCLaunchPolicy/Launcher, HCBuildIdentity verification, HCRecoveryCoordinator, HCCreationIntentStore and HCLifecycleResolver; the shim and its new CLI/socket adapters call this session interface. 2B owns HCWire, HCUnixConnection/RPC/channel implementations, HCControlWriter, HCInventoryReducer/Observer and HCLiveSessionFactory. It supplies wire capacity/reservation and ordered writes; 2C owns transaction admission/encoded-paste attribution, outcome semantics and generation cancellation above that writer, without a second competing queue. 2C owns HCInputCoordinator, HCOutputLease and HCNativeBridge, and all existing surface/terminal-env/Return integration blocks. 2A does not edit TerminalController's integration blocks: 2C registers 2A's new handler there. 2C's input/screen ports bind to the public attachment interface; tickets 5/6 later fill only their frozen rendering/reconnect seams. Only 2C activates hc as the panel backend; 2A/2B do not turn an incomplete adapter into exec fallback for a restored identity.

**Landing and evidence.** 2A can land against unavailable adapters/fakes without 2B/2C; 2B can land after 2A without 2C; 2C integrates the landed services. Branches build in parallel from the common interface commit, with one build-host tag per seat assigned by the Orchestrator and shared slot admission. Each PR contains its own tests, mutation red/green pairs, exact-head build-host gate and cross-family review, plus an explicit NOT VERIFIED list for full-app checks that require later assembly. Those rows remain assigned to their part owner in the contract and are run on the assembled 2C head before the overall ticket handoff. No component PR claims the parent ticket complete. Part-specific work stays within the original ticket-2 acceptance; the final 2C acceptance table includes all T2.0–T2.22 evidence and the existing A1/A4/A5/A6/A9/F1/F8 and feature-parity proofs. 2A retains isolation, restart and durable-creation proofs; 2B retains async-connect, inventory and wire-credit proofs; 2C retains native lifetime, paste/Return, environment and panel integration proofs. Rendering/held-input rows still require the actual ticket-5/6 hooks, never a stub PASS.

**Proof tooling.** The wave proof seat owns guest scripts and the hcfault proxy under the Orchestrator; 2B supplies its protocol requirements and owns the Debug-only connection-factory injection used by it, while 2C wires the assembled app/guest-helper entry point. A fault-proxy transport endpoint never changes the core launch/holder tuple or disables serving-build verification. Serialized project membership and guest/helper edits are coordinated through the Orchestrator. All evidence retains the head actually tested; any row needing the final assembled runtime is rerun there. Waits are logged with duration; over 15 minutes gets a NEEDS line through the Orchestrator.


## Amendment 1 detail: shards and the bundled core (C11H-65)

> Draft for review, 2026-11-01, written by the C11H-65 owner (`agent:c11-t3c`). It details "Amendment 1" in `docs/c11-contract.md` and is frozen with it. Docs only. Nothing here ran hc, connected to a live session or built anything.

### What it rests on

| Fact | Source |
|---|---|
| A holder kill ends only its own session's terminals (`holder_lost` in 0.08 s); the other session's pids and holder are unchanged | hc `docs/shards.md` (b) |
| `core.id` is per session (`core.json`); `core.name` is the hostname for every session; addresses restart at `t1` | hc `docs/shards.md` (b) |
| About 18 MB and 0.09 % of one CPU per idle shard, linear to 16; a core starts in about 0.1 s | hc `docs/shards.md` (c) |
| 8 floods in one session: a quiet terminal's echo p99 is 393 to 550 ms in that session, 0.37 to 0.92 ms in its own shard; inside a flooding shard, about 0.2 s a key | shard plan, "The design" and "Settled" (W4 raw runs `~/hc-lab/results/a-*`, the build host 13:33 to 13:45 PST) |
| A pool of 8 started lazily, sticky by workspace, S0 kept as legacy, remote pairs one to one, ControlMaster off | shard plan (Atin approved 13:25 PST; settled 13:50 PST) |
| hc reads `$XDG_CONFIG_HOME/herdr-core/config.toml`; a core's own `XDG_CONFIG_HOME` sets its `headless` size and reaches programs | hc 0.1.16 tests (`tests/common/mod.rs`, `tests/settings.rs`); hc `docs/c11-to-hc.md` S3 |
| Upstream after 0.1.16 starts the macOS core through launchd unless `HC_LAUNCHD_DIRECT=<direct parent pid>`, which covers only the first start; `SSH_CONNECTION` keeps a holder-restarted core direct | hc `docs/c11-to-hc.md` C7, S2; hc Lead's domain review on #107 (master `277f6a6`, lab run 14:15 PST) |
| A binary in a folder the user cannot write refuses `update` and keeps its hash | hc `docs/c11-to-hc.md` S1 |
| Stock hc passes the contract suite under the hardened runtime with no entitlements (ad hoc); Developer ID and notarized still open | hc `docs/c11-to-hc.md`, "Hardened runtime" |

**K.** The Orchestrator's brief held K open until W4's flood numbers landed, leaning to one shard per workspace. Those numbers landed, and the hc Lead's plan settled a fixed pool of 8. One shard per workspace would mean one SSH link per workspace per machine pair. Eight caps that at 8, and a flood or holder loss still reaches only an eighth. The Orchestrator confirms K at freeze; changing it later is one constant plus the path-length check below.

### Names and paths

`base` is L1's session: `c11` (release) or `c11-<literal-tag>` (dev). `HCShardID(index: 0)` is S0 = `base`; index N in 1…8 is `base-sN`.

| Shard | Release | Dev tag `c11-a` | Socket |
|---|---|---|---|
| 0 (legacy) | `c11` | `c11-c11-a` | `~/.local/share/c11/run/c11.sock` |
| 3 | `c11-s3` | `c11-c11-a-s3` | `~/.local/share/c11/run/c11-s3.sock` |

The holder, state and intent paths follow L1 with the shard's session. **Path budget.** The longest path is shard 8's holder: `<home>/.local/share/c11/run/<base>-s8.holder.<8 hex>.sock`. With home `/Users/demo` that is 67 + 3 + tag bytes, so a tag fits up to 33 bytes (36 before shards). The launch policy checks shard K's holder path once at app start and refuses the whole tuple on failure. A K of 10 or more adds a byte (`-s10`). A dev tag that is `s<digits>` or ends in `-s<digits>` is refused: tag `s3` would make base `c11-s3`, which is release shard 3, and tag `a-s3` would collide with tag `a`'s shard 3.

**Remote sessions.** Ticket 11's remote session takes the shard's session name: local `c11-s3` links to remote `c11-s3` through `atlas-via.sh` with that `HC_SESSION`/`HC_SOCKET`. Remote shard 0 stays `c11`. The build host runs no pool shard that has no local pair. The remote core starts lazily too, on the first link from its pair.

### Types (added to `HCContract.swift` by SH2)

```swift
struct HCShardID: Hashable, Codable, Comparable, Sendable {
    let index: Int                       // 0 = legacy S0; 1...HCShardPool.size = pool
    static let legacy = HCShardID(index: 0)
}
enum HCShardPool {
    static let size = 8                  // K; one constant
    static func session(base: String, shard: HCShardID) -> String  // base or base-sN
}
struct HCShardStatus: Sendable {         // per-shard diagnostics row (SH5)
    let shard: HCShardID; let session: String
    let coreID: String?; let holderPID: Int32?
    let readiness: HCReadiness; let liveTerminals: Int
    let link: HCMachineAvailability?     // nil when the shard has no remote pair
}
```

`HCTerminalKey` is unchanged. Its `owningCoreID` already separates shards, and the key is never rewritten to add a shard. The pool keeps a `coreID → HCShardID` map from each verified connection, plus a remote core id map from each shard's link. A key whose core id is in neither map is unresolved, never guessed. `HCInventorySnapshot` stays per shard. The pool's merged snapshot carries the union of records, a per-shard readiness map, and per-shard revisions; it has no single merged revision.

The session snapshot (SH2) persists the workspace's `HCShardID` and, for each hc panel, the session name its key belongs to. Core ids survive a core restart, but not a deleted state directory. If a saved key's core id no longer matches its saved session's live core id, the panel resolves by labels in that session (L3) and never by address alone.

### Lazy start and placement

- **Start.** Shard N starts when a creation is placed on it; when restore finds a snapshot placement, saved key or pending intent naming it; or when its own socket answers at app launch (a core still running from the last app run is adopted, never restarted). The pool probes only the fixed names S0…SK under c11's own run directory: no directory scan, and no other session is touched.
- **Load.** Load is the live terminal count of that shard in the merged inventory, local and remote together. A shard that is not ready counts its last known value. A shard that has never started counts 0.
- **Choice.** On a workspace's first hc terminal, pick the least-loaded pool shard, with ties to the lowest index. If the chosen shard cannot start, the creation fails as L3 says (`recovery_required` or fallback). It never silently retries on another shard, which would split the workspace.
- **Stickiness.** A workspace keeps its shard for life, including across quits. A workspace whose shard is unrecoverable keeps that placement and shows `recovery_required`; the operator's Retry recovery acts on that shard only. A workspace created before shards holds S0 terminals. Its next new terminal is placed in the pool, so that workspace spans two shards until its S0 terminals close. S0 is never a placement target.
- **Remote.** A workspace on a remote machine is placed by the same rule. Its terminals run on the remote session paired with the chosen local shard.

### Restore and resolution across shards

| Panel has | Resolves in | `new` needs |
|---|---|---|
| a pending intent | the shard whose store holds it | L3 rules in that shard |
| a saved key and session | that session; labels if the core id changed | authoritative absence there |
| a workspace placement only | the placed shard | absence there and no pending intent in any store |
| none of these (pre-shard snapshot) | S0 | absence in S0 and no pending intent in any store |

"No pending intent in any store" reads the intent store of S0 and of every pool shard whose intent directory exists. Reading a store does not start its core. A label match found in a different shard than expected binds when the creation UUID is this panel's active attempt, which can only happen after a lost placement; otherwise the record enters Recovered. One shard's `recovery_required` leaves only its own panels unresolved (Reconnecting, ticket 15).

### Merged inventory and admission

- Each shard's reducer runs L4 unchanged on its own connection: its own generation and sequence, snapshot before deltas, and revoke on gap or overflow. The pool merges on every per-shard publish, and the UI coalesces the merged view at 50 ms.
- **Readiness for a consumer** is the readiness of the shard that holds the record in question. "All ready" is used only by admission and by `new` with no placement.
- **Admission (ticket 7, SH3).** This keeps the frozen birth rule (the "Consumer questions decided" ticket-7 entry; today's `HCProcessAdmission`) and applies it across shards. A shard being ready is never enough to refuse, because a ready snapshot can still predate the caller's birth.
  1. Walk the caller's local ancestry. If a ready shard's inventory owns a live terminal in that chain, admit.
  2. On a miss, start one birth refresh for this caller on **every started shard, ready or not**. A shard that is starting counts as started. Do this at most once per caller and shard connection generation, inside the same 2 s birth window and under the existing bounded attempt table. Return `hc_inventory_pending` until each of those refreshes has completed with a ready revision of that generation, no later than the shard's current one.
  3. Stay `hc_inventory_pending` while any started shard has an own local terminal that is `starting`, or running without a pid. That is the frozen pending-PID hold, now checked in every shard.
  4. Return `hc_caller_not_owned` only when every started shard is ready, each has completed its birth refresh for this caller, none holds an own PID-less or starting terminal, and the walk finds no owner in any of them.

  Pending is retryable and never cached as a refusal (frozen rule). A remote record never supplies local ancestry, as L4 already says.
- **Recovered.** Each shard's unclaimed live terminals enter Recovered, S0 included, with the shard shown in the row. The ticket-3 planner runs over the merged view, using each record's own shard owner to decide local ownership.
- **Pairing error.** Local shard A's core links only to remote session A. If a remote key appears through two local shards, which only a misconfigured link can cause, the record from the paired shard wins. The other is ignored and logged once with both sessions. No second panel or Recovered row is created.

### Recovery isolation

`recoverSession(reason:)` belongs to one shard's `HCSession`. It invalidates input generations of that shard's attachments only, issues `server.restart` on that shard's verified connection only, and waits for that shard's core process to exit. Other shards keep reading, writing and creating throughout. The pool has no app-wide recovery; a recovery on every shard is that many independent operations. Holders are never signalled in any shard (L2). The shim (`Resources/bin/hc`) routes an adapted call to the shard named by the caller's `HC_SESSION`/`HC_SOCKET` pair. A pair naming a pool shard that is not started returns `hc_managed_runtime` and starts nothing. The c11 Lead's F13 note on `hc server restart` applies to each shard's recovery, so SH2's recovery-isolation proof runs on the current pin.

### Bounds across shards

All L7 limits apply per connection. Worst case for one connection: 4 MiB event and early buffer, plus 4 MiB queued input, plus 256 KiB control, plus one 16 MiB frame in flight, about 24.3 MiB. That is about 218 MiB across 9 connections. It is reached only if every shard floods at once while also saturating input. The cost is accepted, not pooled, because a shared budget would let one flooding shard refuse another's input, which shards exist to prevent. Output credit stays per channel (256 KiB). The only thing shared across shards is the main thread, which L5 already keeps free of waits.

### Bundled core environment (C11H-66)

A local core's launch environment is L1's sanitized environment plus:

| Variable | Value | Why |
|---|---|---|
| `XDG_CONFIG_HOME` | `<home>/.local/share/c11/config`, absolute (one directory for every shard) | c11's own `herdr-core/config.toml` (start size `headless`, P5 workaround); hc's shared `~/.config/herdr-core` is never read or written |
| `HC_LAUNCHD_DIRECT` | pid of the process that spawns `serve`, which is the core's direct parent | First start stays direct (C7). Upstream `prepare_core()` (master `platform/macos_launchd.rs:119-128`) honours it only when it equals the direct parent pid, then removes it. A forking wrapper between c11 and `serve` silently defeats it; an exec'ing one is fine. |
| `SSH_CONNECTION` | `c11 0 c11 0` (fixed placeholder) | Restarts stay direct. A core the holder restarts after a crash has the holder as parent and no `HC_LAUNCHD_DIRECT`, so on master it moves to launchd: the hc Lead's lab run (14:15 PST) showed ppid 1 after `kill -9` with `HC_LAUNCHD_DIRECT` alone, and the holder as parent with `SSH_CONNECTION` also set. hc forces a direct start while it is set (`macos_launchd.rs:126,148`) and strips `SSH_CONNECTION`/`SSH_CLIENT`/`SSH_TTY` from every program (`platform/mod.rs:86,116`). |

Both launchd values are inert on 0.1.16. The rule for restarts is `SSH_CONNECTION`, the only one this contract allows; C11H-66 proves it on the pin it bundles. Without it, a post-0.1.16 pin would lose direct parentage after a crash, and a later holder could fall outside c11's TCC coalition. If an hc pin ever reads more from `SSH_CONNECTION` than "is it set", C11H-66's contract-suite run must show it; the placeholder is otherwise opaque.

All other `XDG_*` stay stripped from the core. c11 writes the config file atomically before a core starts, and only when its contents change. A core that is already running keeps the settings it read at start.

**Terminal `XDG_CONFIG_HOME`.** S3 shows the core's value reaching the shell, so every hc terminal gets its intended value instead:

| Panel's intended value | c11 inherited a value | Terminal gets |
|---|---|---|
| set | either | overlay with the panel's value |
| none | set | overlay with the inherited value |
| none | none | real unset: argv becomes `/usr/bin/env -u XDG_CONFIG_HOME <argv>` |

`$HOME/.config` is not a substitute for unset on macOS. Tools such as lazygit read `~/Library/Application Support/<tool>` when the variable is unset and `$XDG_CONFIG_HOME/<tool>` when it is set, so agents' tools would read a different config in c11 than in c11. `env` execs its target, so the shell keeps the same pid. The ancestry (`holder -> shell`; `holder -> login -flp -> shell` for terminals opened before C11H-232) and the admission walk are unchanged, and C11H-66 proves both. The prefix applies to the argv c11 already chose (L3 detail: never hc's default shell). It is part of creation, so restore's label resolution is unaffected.

The final `terminal.run` parameter builder (`HCLaunchPolicy.terminalRunParameters`) applies this rule to every panel create, replacement, retry, headless or remote start, and managed `hc run`. The environment at that boundary contains terminal overrides, never the core environment. A supplied XDG value is intentional even if empty or equal to the core directory; no path comparison discards it. An omitted argv resolves the owning machine's login shell after the same guard.

`HC_SPAWN_MS` and `HC_LAUNCHD_DIRECT` are launch-only `HC_*` variables, which terminal overlays cannot change (L1). The pinned 0.1.16 core passes both to programs, so the same builder always unsets them. Both stay on the core. The terminal's own HC_SESSION, HC_SOCKET, HC_TERMINAL_ID, HC_TERMINAL_SOCKET and HC_SCOPE remain available. hc itself removes the `SSH_CONNECTION` restart placeholder and the other SSH login markers before spawning programs.

**Remote cores (`atlas-via.sh`).** Today the link's environment allowlist is `HOME USER LOGNAME SHELL LANG PATH HC_SESSION HC_SOCKET HC_SPAWN_MS` with no `XDG_*` (`HCAtlasLink`). A build-host shard core therefore reads the build host's shared `~/.config/herdr-core/config.toml`, which is herdr-app's. C11H-66 changes this:
- The link sets `XDG_CONFIG_HOME=<remote home>/.local/share/c11/config` on the remote core, and the allowlist admits exactly that one `XDG_*` key. c11's install on the remote machine writes the same config file there.
- Remote cores get neither `HC_LAUNCHD_DIRECT` nor `SSH_CONNECTION`: there is no c11.app on the far end, so no TCC attribution is at stake. C11H-66 records on its pin whether a remote core restarted by its holder goes to launchd, as a fact, not a gate.
- Remote terminals follow the same table, except the middle row: a remote terminal never takes the local app's inherited value, which names a path on another machine. With no panel value it is unset through `env -u`.

**Binary.** The pin path moves from `~/.local/share/c11/hc/<pin>/herdr-core` to `c11.app/Contents/Helpers/<name>`. It is signed in the app's inside-out codesign pass with the hardened runtime, and its folder is not user-writable. L2 verifies the bundled path, file identity and hash, and S1's `update` refusal holds there. Shards share the one binary. Before C11H-66 lands, the existing pin path stays authoritative.

### What SH2 to SH6 and C11H-66 must prove

| Ticket | Behavioral proof (logic test, fake peers, or guest row) |
|---|---|
| SH2 | Two workspaces place on two shards. A third goes to the least loaded, and a ninth shares. Quit and relaunch keep placements and keys. A pre-shard snapshot resolves in S0. A pending intent in shard 5's store blocks `new` for that panel. A shard that cannot start fails only its creation. Tuple refusal at shard K's holder length. Removing the per-shard store read shows a duplicate in a test. |
| SH3 | Admission owns callers of every shard. It returns pending while one started shard is unready; pending when every shard is ready but the caller is missing and the birth refresh has not finished, with one shard and with several; pending while an own terminal in any shard is starting or PID-less; and `not_owned` only after refreshed, authoritative inventories in every started shard. A mutation that skips the refresh for ready shards, or drops the PID-less hold, turns a test red. A process reporting at terminal start is admitted in each shard, with all 20 birth reports present (T7.3 per shard, guest). Every verb the skill teaches works from a terminal in each shard (guest). |
| SH4 | Pairing by session name. A dropped link marks only its shard's remote panels. A pairing-error key does not make a second panel. The build host `ps` shows only paired sessions (guest). |
| SH5 | Diagnostics list each shard. A holder kill is attributed to its shard from logs and the CLI alone. |
| SH6 | Guest: a holder kill ends only one workspace's terminals, and each resumes once. With 8 floods in one workspace, typing in another stays at its idle latency. |
| C11H-66 | The core's own `headless` size takes effect, locally and on a remote shard core. A shell sees the right `XDG_CONFIG_HOME` in each of the three table rows, with the third truly unset (`env` shows no key). The C11 ancestry and admission are unchanged with the `env -u` prefix. The first core is a direct child of c11. A core restarted by the holder after `kill -9` stays a direct descendant of c11 (needs a post-0.1.16 pin to be meaningful; run on master in the contract suite). Programs see no `SSH_*` from the core. `update` is refused from `Contents/Helpers/`. TCC attribution (guest). |
