# c11 hc contract (frozen)

> **Frozen 2026-10-31 17:46 PDT** by the Orchestrator after Review 1 (Opus PASS on repair 1, Fable PASS on repair 2; reviews in `<run-folder>/reviews/C11H-3-contract-*.md` on the build host). Changes after the freeze go through the Orchestrator and reach every consumer ticket.
>
> **Amendment 1** (shards and the bundled core, C11H-65) is a draft under review; see the section of that name below.


C11H-3 owns plan ticket 2; numbers below are plan tickets. **The pin and its checksum come from the Pathfinder (run-state). Candidate `v0.1.16`; detailed types/proofs in `docs/c11-contract-detail.md`.

**Before any pin bump:** upstream herdr-core after 0.1.16 (from 44cb360) starts the macOS core through a launchd job, which breaks c11's TCC attribution (the core as c11.app's child) unless c11's launcher sets `HC_LAUNCHD_DIRECT=<launcher pid>`. 0.1.16 is unaffected. See c11-to-hc.md, item C7, in the hc repo (docs/): "**The core is a direct child of c11.app**, so TCC grants attribute to c11" … "**Breaks on upstream `master`**: macOS cores now start through a launchd job unless `HC_LAUNCHD_DIRECT=<launcher pid>`". 0.1.21 was evaluated on 2026-11-15 and not adopted; what it changes, its security fixes and what adopting it would take: [hc-0.1.21-evaluation.md](hc-0.1.21-evaluation.md).

**L1 — Launch.** Pin `~/.local/share/c11/hc/<pin>/herdr-core`; session `S=c11[-<literal-tag>]`; socket `~/.local/share/c11/run/S.sock`, holders `S.holder.<instance>.sock`; default state `~/.local/state/herdr-core/S`, shared config read-only. Reject overlong paths/relocation. Off-main start: sanitized env, HC_SESSION/HC_SOCKET, HC_SPAWN_MS=10000, no XDG. Raise soft NOFILE to min(finite hard, kern.maxfilesperproc), treating infinite hard as unbounded; preserve sufficient higher soft, leave hard unchanged, re-read effective ≥8192; log limits. Programs inherit it. Terminal overlays preserve intended XDG but cannot override/clear HC_*; programs inherit HC_SESSION/HC_SOCKET/HC_TERMINAL_ID/HC_TERMINAL_SOCKET/HC_SCOPE. Plaintext run.env accepts managed/configured overrides including C11_AGENT_TASK/credentials, never bulk process env or logging.

**L2 — Identity/recovery.** Each connection verifies protocol/version/features, kernel peer, status pid/core id, executable path/file identity and pinned hash (cached by file identity). Ticket 2’s terminal-only `Resources/bin/hc` uses an existing-connection adapter: no autostart; refuse start/update, route restart through `recoverSession(reason:) async -> HCRecoveryResult`, reject unsupported commands. The shim falls through to the PATH `hc` unchanged whenever `HC_SESSION` or `HC_SOCKET` in the caller's environment names anything other than c11's own session; it adapts only calls aimed at c11's core. A bypassed foreign build recovers once: verify own uid/pid/socket/core.lock/core.json id, planned server.restart, confirm old-process exit, start exact pin/tuple, verify post-adoption inventory. Never touch a different core id or kill holders; mixed holders are legitimate. Bound recovery to 30 s, then recovery_required with identities/Retry recovery (6; CLI/guide 9). Guarded input waits for pinned reattach and screen readiness.

**L3 — Lifecycle.** `new | live(record) | ended(proof) | unresolved(identity,reason)`; attachment separate. Ticket 2’s HCCreationIntentStore atomically persists/fsyncs off-main before transmission, independent of autosave. Label attempts c11.panel/c11.creation UUIDs; bind only active attempts. Every restore, including saved-new/keyless, resolves labels/intents before creation; new requires authoritative absence and no pending intent. Known finished/removed attempts settle. The run RPC's client deadline exceeds hc's own bounds (holder start plus `HC_SPAWN_MS`; at least 20 s), so closure follows only transport loss or a core that outlived its own deadline. Unknown absence reaches creation_uncertain/Retry safely by 30 s after connection closure: L2 recovery, confirmed old-process exit and post-adoption absence authorize one replacement. Time alone proves nothing: holder handshake precedes the 10 s spawn timeout and is untimed. Late superseded creations enter Recovered. Failed/unready lookup never authorizes replacement. Fallback only genuinely new/unreachable/pre-transmission, nonpersistent for life, ends on Quit. no_parent/no_notify=true; keep=false; initial input once, never replay uncertain. Surface disposal detaches; panel/workspace/window close ends; Quit detaches persistent sessions. Last detach may resize to 200×120.

**L4 — Inventory.** One unfiltered snapshot+deltas, revision (connectionGeneration,seq); reassemble lines, snapshot before early events, discard old/duplicate events, replace on missed, revoke readiness on gaps/malformed/overflow. Unrelated events advance seq. UI coalesces at 50 ms; admission reads reducer immediately. Key (owningCoreID,localAddress); aliases only route; mirror removal/link loss never proves death. Tty/start time are optional local kernel facts (7/8), absent remotely, never hc fields. Preserve end reason verbatim. All unclaimed live terminals enter Recovered (3). Birth admission: ≤2 s/one refresh, retryable hc_inventory_pending or definitive hc_caller_not_owned (7).

**L4 Amendment 1 (C11H-103, the Lead 2026-11-01 20:10).** An unclaimed live terminal whose own panel is missing from the restored layout returns to that panel's workspace instead of Recovered, only under these conditions:
- (1) it returns to the workspace its `c11.workspace` label names only if that workspace exists in the restored session; otherwise Recovered;
- (2) "Start fresh" (and Option at launch choosing fresh) still sends every live terminal to Recovered;
- (3) a superseded creation still goes to Recovered (L3 holds), and so does any orphan whose label disagrees with another live claim;
- (4) a returning panel is added as a new panel at the end of that workspace's last area, never splitting or reordering the saved layout, and gets its `c11.title`;
- (5) every return writes one hc-diagnostics line (`event=recovered_home`: panel, terminal, workspace, reason), never silent;
- (6) labels carry no secrets: `c11.title` is clipped to 120 characters and is readable by any same-user process through hc (install guide, Trust boundary).

**L5 — APIs/threads.** Typed HCSession observe/resolve/create/attach/end/diagnostics signatures are in the plan. HCAttachment.detach returns immediately; retire output off-main before native free on main; userdata survives free. `screenCurrent(after: HCDisplayRevision) async -> HCScreenReceipt?`: 2 declares, 5 implements/proves full reattach paint parsed with matching grid/generation; ≤2 s then nil. 4/6/8 share receipt/fresh attributed-cell guard. No surface (including locked screen): queue creation/initial input until attachment is possible.

**L6 — Input.** `submit(HCInputRequest) async -> HCInputOutcome` routes send/text-box/file-paste/Feed/doorbell/launch/resume/initial; operator keys/paste use raw IO, paste pre-reserved in Swift. Ticket 2 proves whole-paste completion; until proved refuse before native submission. Ticket 2 owns every delayed-Return generation check, CSI-I/O→FOCUS and ordered RESIZE/report. CLI/Feed outcomes: refused=zero/retry-safe; written=transport delivered, submitted only if Return written; uncertain=nonzero exit/retry-unsafe, cancel unsent Return, never replay; queued=pending. Input fault refuses keys/paste/query DATA (2 emits, 6 presents); controls drain. Fresh parsed attachment plus explicit Retry input clears it without replay.

**L7 — Bounds.** Hello 64 KiB; connect/hello/identity 2 s total; frames 16 MiB; event line and aggregate early/event buffer 4 MiB; encoded transaction 1 MiB, queued input 4 MiB; reserved/coalesced control 256 KiB. Overflow is explicit refusal/invalidation, never truncation. Credit follows consumption, **including events**; ordering-dependent control/DATA stay together.

| Owner | Files/seams reserved |
|---|---|
| 1 / 2 | 1 owns product/socket constants; 2 owns terminal-env extraction in GhosttyTerminalView; serialize any overlap through Orchestrator |
| 2 | Sources/HC core/types/transport/inventory/input/lease/intent store; Resources/bin/hc/CLI adapter; every delayed-Return hook in GhosttyTerminalView, TerminalController, MailboxStdinBuffer, LaunchPromptDelivery, Panels/TerminalPanel LaunchPostBootSequence **before 3** |
| 3 / 4 | 3 restore/identity/close/allocations in Workspace, SessionPersistence, managers; 4 conversation audit/resume/Quit after 3, through submit |
| 5 / 6 | 5 rendering/screenCurrent/resize/facts; 6 reconnect/disconnected-input/recovery/fault UI through 2’s hooks |
| 7 / 8 / 9 | 7 admission/capture; 8 agent/tty/mail recovery after 3/4/6/7; 9 diagnostics/CLI/bundled guide |
| 11 / 15 | 11 build-host --via exact executable/session/socket/no-XDG tuple, never default dial/install; 15 unresolved=Reconnecting, preserves persistence |

Open proofs: 2 paste completion/intent durability; 5 paint boundary/resize cost; 7 one-shot report retry/spooling; 11 remote adapter isolation. Failure rules above apply; M1 acceptance still requires proof.

## Amendment 1: shards and the bundled core (C11H-65)

> **Draft for review, 2026-11-01**, C11H-65 (SH1). Frozen like the original once reviewed. Sources: the hc Lead's shard plan (`<run-folder>/hc-shards-c11.md`, approved by Atin 13:25 PST, settled 13:50 PST); hc repo `docs/shards.md` (W4) and `docs/c11-to-hc.md` (C7, S1–S3). Where this section and L1–L7 differ, this section governs: the shard rules from SH2, the bundled-core rules from C11H-66. Until each lands, L1–L7 describe the running build. Types and rules in detail: `docs/c11-contract-detail.md`, "Amendment 1".

**Shards.** A shard is one hc session with its own core, holder, socket, state, intent store and parse thread. **Shard 0** is the existing session `S0 = c11[-<literal-tag>]`; it keeps the terminals it holds, takes no new workspace and empties as they close. Nothing in it is moved or ended. **Pool shards 1…K**, with **K = 8** as one constant. K was open in the brief, with one shard per workspace as the lean, until W4's flood runs landed (13:33–13:46 PST). The hc Lead then settled 8: it caps remote links at 8 per machine pair and still splits a flood or holder loss eight ways. A pool shard starts on first use, never at app launch.

**A1.L1 — Launch.** Shard N ≥ 1 is session `S0-s<N>` (release `c11-s3`, dev `c11-<tag>-s3`), with socket `~/.local/share/c11/run/<session>.sock`, holders `<session>.holder.<instance>.sock`, state `~/.local/state/herdr-core/<session>` and intents `~/Library/Application Support/c11/HC/<session>/`. The 103-byte check runs against the longest holder path of shard K, so tags get 3 bytes shorter. A dev tag that is `s<digits>` or ends in `-s<digits>` is refused, because it would name another base's shard. A tuple that fails is refused for the whole app, never shortened or skipped per shard. Every core gets the L1 sanitized environment and its own NOFILE raise and ≥8192 check, run per core and logged with the session.

**Bundled core (C11H-66).** A local core's environment gains exactly three values:
- `XDG_CONFIG_HOME=<home>/.local/share/c11/config` (absolute; one directory for every shard). hc reads `herdr-core/config.toml` there; only c11 writes it, and hc's shared config is never read or written again.
- `HC_LAUNCHD_DIRECT=<pid of the core's direct parent>`, the process that spawns `serve`. Any wrapper in between must exec, not fork. This keeps the first start direct (C7: TCC attributes to c11).
- `SSH_CONNECTION=c11 0 c11 0`, a fixed placeholder. This is the **one rule for restarts**: on a pin after 0.1.16, hc honours `HC_LAUNCHD_DIRECT` only from the direct parent and removes it on read. A core the holder restarts after a crash (C8) would therefore move to launchd. hc starts directly whenever `SSH_CONNECTION` is set, and strips `SSH_CONNECTION`/`SSH_CLIENT`/`SSH_TTY` from every program. Both values are inert on 0.1.16.

Every other `XDG_*` stays stripped. The core's `XDG_CONFIG_HOME` reaches programs (S3), so every terminal gets its intended value:
- the panel's own value, else the one c11 itself inherited, set by overlay;
- with neither, a real unset: the terminal's argv is prefixed with `/usr/bin/env -u XDG_CONFIG_HOME`, which execs and so adds no process to the ancestry.

Setting `$HOME/.config` instead is not the same as unset on macOS, because tools switch between `~/Library/Application Support` and `$XDG_CONFIG_HOME`.

**Remote cores.** `atlas-via.sh` gives each remote shard core the same config home on its own machine, `XDG_CONFIG_HOME=<remote home>/.local/share/c11/config`. The c11 install on that machine writes it, and that one variable is added to the link's environment allowlist. Remote cores never read hc's shared config, and they get neither `HC_LAUNCHD_DIRECT` nor `SSH_CONNECTION`: no TCC attribution is at stake there. Remote terminals get the panel's own value or the `env -u` unset, never the local app's inherited value.

The binary moves to `Contents/Helpers/` in the signed app, a folder the user cannot write (S1 refuses `update`), and L2 verifies that path and hash.

**A1.L2 — Identity/recovery.** L2 identity checks run per connection, so each shard verifies its own peer, pid, core id and binary. Core ids are per session (`core.json`), so no shard's id matches another's. Recovery is per shard. `recoverSession` acts only on the shard whose verified connection raised it, and its 30 s bound is per shard. One shard's `foreign_build`, `creation_uncertain` or `recovery_required` never pauses, restarts or invalidates the input of another. The shim adapts a call whose `HC_SESSION` and `HC_SOCKET` name the same session among this app's S0 to SK and routes it to that shard. Anything else falls through unchanged.

**A1.L3 — Lifecycle.** Creation targets a shard, and placement is sticky by workspace:
- A workspace's first hc terminal takes the pool shard with the fewest live terminals in the merged inventory (an unstarted shard counts 0, ties go to the lowest N). Past 8 workspaces, workspaces share shards.
- Every later terminal of that workspace, split or new panel, goes to the same shard. The placement is persisted in the session snapshot, and the creation intent goes into the target shard's own store (L3's store is already per session) before transmission.
- A panel moved to another workspace keeps its terminal where it is (hc cannot move a live terminal).
- Restore resolves each panel in the shard its intent or saved key names. A panel with neither (a snapshot from before shards) resolves in S0.
- `new` requires authoritative absence in that shard and no pending intent in any shard's store.
- A shard that cannot become ready leaves its own panels unresolved (Reconnecting, 15) and blocks nothing elsewhere.
- Superseded late records enter Recovered from whichever shard holds them. `end` routes the exact key to its shard. The 20 s run and 30 s resolution deadlines are per shard.

**A1.L4 — Inventory.** Each started shard has one connection and one reducer, with its own revision `(connectionGeneration, seq)`. Revisions are never compared across shards.
- The merged view is the union keyed `(owningCoreID, localAddress)`. Addresses restart at `t1` in every shard, so an address alone never identifies a terminal.
- Readiness is per shard: a gap, `missed`, malformed event or overflow revokes only that shard. The UI coalesces the merged view at 50 ms.
- Admission (7) keeps the frozen birth rule in every shard. A caller descended from a live terminal of any shard is owned. A miss starts the one bounded birth refresh on every started shard, ready or not, and stays `hc_inventory_pending` until those refreshes complete and while any shard has an own terminal that is starting or without a pid. `hc_caller_not_owned` comes only after refreshed, authoritative inventories in every started shard find no owner.
- Unclaimed live terminals of every shard, S0 included, enter Recovered (3).
- **Remote shards pair one to one.** Local shard N links only to the same-named session on the remote machine (11's `--via` takes the session), so remote keys carry that remote shard's core id. Link state is per shard. A key seen through two connections is a pairing error: it routes through its paired shard, is logged, and never makes a second panel. SSH ControlMaster stays off.

**A1.L5 — APIs/threads.** One `HCSession` per shard; L5's signatures are unchanged. A pool front (`HCShardPool`) routes keys by owning core id (remote keys by their link's shard), places creations, merges observation and lists every shard in diagnostics (session, core id, holder, terminals, readiness, link).

**A1.L6 — Input.** L6 is unchanged and applies per shard. A shard's reconnect or input fault refuses only its own attachments' input.

**A1.L7 — Bounds.** Every L7 bound applies per connection, meaning c11's connection to each shard's core; none is pooled. That covers the 2 s connect/hello/identity window, 16 MiB frames, the 4 MiB event and early buffers, 1 MiB transactions, 4 MiB queued input, 256 KiB control and 256 pending RPCs. Overflow invalidates only that connection. With S0 plus 8 pool shards, app-wide buffering can reach 9× one connection's; that is accepted (detail).

| Owner | Amendment 1 scope |
|---|---|
| SH2 | `HCShardPool`, lazy start, placement and its snapshot field, intents in the target shard's store, restore across shards, S0 as legacy; also per-shard launch/NOFILE and recovery isolation (A1.L1–L3, L5) |
| SH3 / SH4 | 3 admission, `capture-runtime`, tty and agent re-learning across shards; 4 remote pairs, `--via` per session, link chip per shard |
| SH5 / SH6 | 5 diagnostics and `holder_lost` with its shard; 6 guest proof: holder kill ends one shard only, typing in one workspace at idle latency while another floods |
| C11H-66 | Bundled binary in `Contents/Helpers/`; `XDG_CONFIG_HOME` with overlay or `env -u` unset, local and on `atlas-via.sh`; `HC_LAUNCHD_DIRECT` and the `SSH_CONNECTION` restart rule |

Open proofs: SH6's two guest rows; C11H-66's S3 overlay and unset, the holder-restarted core staying a direct descendant, and the C7 TCC row in a guest. Inside one flooding shard, typing still waits (about 0.2 s a key); that is P3 and is not claimed here. Open, out of scope today: two client Macs pairing with the same remote `c11-sN` would share that shard.

## Repair 1

- Opus 1 / Fable 3: protected HC env, existing-only shim, bounded same-session recovery — L1–L2 (lines 5–7).
- Opus 2 / Fable 1: per-attempt labels, settle evidence and 30 s actionable safe-retry deadline; source caveat on untimed pre-spawn handshake retained — L3 (line 9); plan “Repair 1 evidence”.
- Opus 3: durable ticket-2 intent store and resolve-before-create for every restore — L3 (line 9).
- Opus 4: all delayed-Return hooks assigned to 2 before 3; 6 consumes them — L6 (line 15), ownership row 2 (line 22).
- Opus 5: shared typed routing/readiness API with explicit unavailable fallback — L5–L6 (lines 13–15).
- Opus 6: finite Darwin target, verification and inherited-limit parity — L1 (line 5).
- Fable 2: tty/start time explicitly local kernel facts, never hc fields — L4 (line 11).

## Parts

After freeze and GO, three owners implement in parallel; the Orchestrator dispatches the two additional seats. Merge order is **2A → 2B → 2C**, each a separate PR/branch that builds and lands without an unmerged implementation from a later part. These are subdivisions of C11H-3, not changes to the consumer ticket numbers above.

| Part / owner / branch | Scope from ticket 2's ownership | Independently landable result |
|---|---|---|
| **2A — Launch, restart and lifecycle**; this owner `agent:c11-t2`, Astra xhigh; `c11/C11H-3-hc-backend` | docs/c11-contract.md; Sources/HC contract/session/launch/build-identity/recovery/creation-intent/lifecycle; Resources/bin/hc, CLI/HCCoreCommand.swift, Sources/SocketHandlers/HCCoreHandlers.swift | Frozen types and injected connection/inventory/input interfaces; real launch/recovery/lifecycle policies with executable fake-peer tests. A production unavailable adapter refuses work and starts nothing until 2B/2C compose it. No activation of the hc panel backend yet. **All restart/lifecycle logic stays here.** |
| **2B — Transport and inventory**; separate `agent:c11-t2-wire`, Astra high; `c11/C11H-3-wire-inventory` | Sources/HC framing/socket/RPC/channel/control-credit/inventory reducer and live connection adapter | Implements 2A's connection/inventory interfaces, deadlines and bounded queues. Lands after 2A with transport/reducer tests and an injectable live-session factory; no native surface or input-policy dependency on 2C. |
| **2C — Input, surfaces and activation**; separate `agent:c11-t2-io`, Astra high; `c11/C11H-3-input-surface` | Sources/HC input admission/output lease/native bridge; GhosttyTerminalView terminal-env/io wiring; every delayed-Return hook in TerminalController, MailboxStdinBuffer, LaunchPromptDelivery, Panels/TerminalPanel; adapter registration | Builds/tests input and lease behavior against the frozen interfaces and fakes while 2A/2B proceed. Lands after 2B: composes the live backend, activates hc panels, installs all generation hooks before ticket 3, and retains tickets 5/6's declared extension points. No later-part implementation is needed to compile or land it. |

2A publishes the common compileable interface commit in its first draft PR; 2B/2C branch from that exact commit, use injected fakes, and rebase onto main as predecessors merge. They do not copy or redefine shared types or wait for 2A's full implementation. Each owns its component tests; project membership edits are reconciled in merge order. The Orchestrator's wave proof seat prepares guest scripts; component owners retain proof responsibility. Every part gets cross-family review and a build-host gate at its exact head; build/guest admission remains serialized as required, and waits over 15 minutes are reported.

Matrix ownership below assigns **all 23 T2 rows exactly once**, including final evidence collection. All existing procedures, timeouts, residuals and mutation checks remain required. Component-only proofs never count as full-app PASS: dependent rows stay NOT VERIFIED until the assembled 2C head; each named owner runs its rows there, and C11H-3 cannot finish without the complete acceptance. 2C also coordinates full-backend flood/input checks with tickets 5/6 when their runtime hooks are required; no unavailable stub waives a row.

| Accountable part | Acceptance matrix rows |
|---|---|
| 2A | T2.0, T2.1, T2.2, T2.5, T2.11, T2.12, T2.15, T2.16, T2.17, T2.18 |
| 2B | T2.14, T2.19, T2.22 |
| 2C | T2.3, T2.4, T2.6, T2.7, T2.8, T2.9, T2.10, T2.13, T2.20, T2.21 |
