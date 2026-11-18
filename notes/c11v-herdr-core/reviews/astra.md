Needs you: nothing. These are changes for the plan owner before launching the build.

# Astra: technical review of the c11h M1 plan

Reviewed 2026-10-31, 15:27 PDT. Read all three c11h documents and the four requested evidence documents. Spot-checked the feature map against c11 `main` at `42db7253e4f1fff1937abaf1243da2c318d0dbf7`; read the spike at `dd0d4e75a9f9c26bed7fed947e500e4869cc2d5e`. No builds, launches, code changes or pushes were performed.

References below use `spike:` for files in `~/src/c11-worktrees/c11v-hc-spike` at that commit. Supplemental `hc:` references are from the existing local herdr-core checkout at `29e6d375623de40cb4820e0894aa131ba057b796` (`v0.1.14`), under `crates/herdr-core/src/`. That is the spike's generation of evidence, **not verification of the proposed 0.1.15 pin**. The Pathfinder must establish which upstream defects remain on 0.1.15.

## Findings

### 1. P1: An hc session name is not a sufficient isolation boundary for ticket 2.

**What is wrong or missing:** Tickets 1 and 2 prescribe separate session names and an owned binary folder but do not prescribe the socket, holder directory, state directory and launch environment as one invariant across starts and updates.

**Evidence:** `docs/c11h-plan.md:42-43`; `hc:paths.rs:18-34` derives state from the session but takes `HC_SOCKET`, then a shared `config.toml` socket, ahead of the session-specific default. An explicit socket also determines the holder socket prefix. `hc:runtime.rs:265-301` discovers holders in that directory and sweeps processes whose holders were not found; `runtime.rs:382-388` kills terminals from an adopted holder absent from its registry. This is already documented in `notes/c11v-herdr-core/hc-federation-robustness.md:14,141`. The exploration also identifies core takeover by a different installed hc binary (`EXPLORATION.md:101-105`); the spike's hello checks only `framed`, not the serving build (`spike:Sources/C11vSpikeBackends.swift:706-734`).

**Consequence:** An inherited override or herdr configuration can defeat the stated isolation, connect to the reference install, or make a restarted core lose its own holders. Checking the downloaded executable's checksum does not establish which executable serves the socket.

**Smallest fix to the plan:** Make ticket 2 own a documented launch tuple: exact executable/build, session, explicit short socket and holder location, state/config policy, and sanitized core environment. Keep it stable across relaunch/update; validate the server identity on every connection. Do not change user programs' XDG homes as a side effect. Add a guest test with a live reference session, conflicting inherited `HC_SOCKET` and config `socket`, then a c11h core restart; neither session may adopt, signal or unlink the other's resources. Verify the behavior on 0.1.15 before selecting a workaround or pulling a minimal hc patch into M1.

### 2. P1: Ticket 1's isolation acceptance misses destructive legacy migration and cross-product CLI discovery.

**What is wrong or missing:** “Run side by side” does not require exercising populated legacy state, symlinks, missing sockets or fallback discovery, where changing the current names can still touch c11.

**Evidence:** `Sources/Mailbox/MailboxLayout.swift:219-246,285-306` migrates `c11mux` into the current root by moving entries and replacing the old root with a symlink; this runs from multiple state-root resolvers. Merely changing `currentName` to `c11h` while retaining the migration source would import c11's old state, including through an existing legacy symlink. `CLI/CLISocketConfig.swift:250-267,275-287,314-332` retains cmux sockets/breadcrumbs and scans names beginning with either `cmux` or `c11`. The app's foreign-default protection is another explicit list (`Sources/SocketControlSettings.swift:637-665`). A healthy explicit-socket run does not execute these fallback paths.

**Consequence:** First launch on an existing machine can move state out from under c11; an implicit CLI invocation when c11h is unavailable can select a foreign socket. A clean guest can pass while the laptop fails.

**Smallest fix to the plan:** Add explicit ticket 1 rules: no migration from c11/cmux/c11mux roots or preference domains; no implicit discovery outside the c11h family; inherited foreign socket overrides must not become bind targets. Seed the guest with c11 state, a `c11mux -> c11` link, legacy breadcrumbs and a running c11 listener. Exercise first launch, missing-c11h-socket CLI resolution, themes/config writes and shutdown; compare the foreign files, symlinks and listener before and after. Include Debug, staging and Release identities in the audit.

### 3. P1: The inherited app can install c11h's edited skills over the live c11 skills despite the script prohibition.

**What is wrong or missing:** Ticket 9 forbids syncing installed skills, but no ticket disables or separates the app and CLI skill installers.

**Evidence:** `docs/c11h-plan.md:50` and `docs/c11h-m1-brief.md:20` restrict source/script behavior. `Sources/SkillInstaller.swift:46-48,429-434` chooses the destination by harness home and package name, not app bundle identity; lines 593-620 accept a managed skill and remove/copy its directory. Release onboarding offers changed packages, while QA and local dev builds suppress the offer (`Sources/AgentSkillsView.swift:1514-1545`). Thus the prescribed QA path hides this collision.

**Consequence:** The first ordinary staging launch can offer an apparently routine skill update that replaces c11's installed agent contract with the private fork's version, affecting agents in live c11.

**Smallest fix to the plan:** Assign ticket 1 the app onboarding, Settings installer and CLI installer surfaces. For M1, disable writes/removal of shared c11 packages from c11h and teach its agents to use the bundled `c11 guide` for the fork's contract. Ticket 9 must verify that this guide contains its changes. Prove in a normal Release launch with populated managed skill folders that neither onboarding nor installer commands can replace them.

### 4. P1: Porting the spike unchanged carries a main-thread deadlock into ticket 2.

**What is wrong or missing:** The backend ticket does not require replacing the spike's synchronous surface lifetime lock before it becomes the default path.

**Evidence:** `spike:Sources/C11vSpikeBackends.swift:423-427` takes `surfaceLock` on main during detach; lines 530-538 hold that same lock through `ghostty_surface_process_output` on the output queue. In the pinned Ghostty source, `ghostty/src/termio/stream_handler.zig:128-138` can wait forever for the main-consumed surface mailbox to drain. The resulting wait cycle is main → surfaceLock → output → main. This is a static failure path, not a reproduced hang in this review. Separately, the spike connects and reads hello on main (`makeBackend:100-103`); the bytewise poll at lines 690-705 renews its timeout for each byte, so the stated 1.5-second bound is not an overall deadline.

**Consequence:** Closing a flooding panel can freeze the whole app; a slowly answering core can stall startup indefinitely. The current flood check types in another panel but does not close the flooding one.

**Smallest fix to the plan:** Add ticket 2 acceptance for asynchronous connection/hello with a total deadline and bounded frame sizes, and teardown that never makes main wait for an output operation that needs main. Preserve userdata/native-surface lifetime until output has retired. In a guest, flood title/bell/cwd events while repeatedly closing panels and quitting, and test a core that accepts but delays/trickles hello; impose a hard responsiveness timeout.

### 5. P1: Tickets 2 and 6 have no input-loss or replay contract.

**What is wrong or missing:** “Killing the core mid-typing loses no panel” can pass even when input is truncated, discarded or submitted later into a different composer state.

**Evidence:** The spike's 4 MiB shared ring drops whole appends when full (`spike:Sources/C11vSpikeBackends.swift:219-265`), and DATA/RESIZE/CREDIT callers discard the return value (`820-834,1183-1191`). Detached input keeps only the first 64 KiB (`1112-1115,1160-1169`), then automatically flushes it on attach and clears the buffer even if the append failed (`1315-1322`). The same lane carries keystrokes, paste, launch input, resume and mailbox delivery (feature map §C). Ticket 6 checks panel survival, not any of those delivery semantics.

**Consequence:** A large prompt or paste can lose its tail while Return survives, credit loss can stall a channel, and guarded programmatic input can be replayed after the screen it was checked against has changed.

**Smallest fix to the plan:** Give ticket 2 ownership of bounded queue admission and control-frame delivery; ticket 6 owns disconnected-input behavior. Require that overflow is never silent and that a partial command is never submitted as success. Recheck guarded sends after reattach; do not promise exactly-once delivery across an unacknowledged connection loss. Add byte-for-byte paste tests across queue saturation and an outage, with explicit acceptance/rejection evidence and no truncated-command execution.

### 6. P1: Restore does not distinguish “terminal absent” from “terminal identity currently unknown.”

**What is wrong or missing:** The fallback in ticket 2 and the resume in tickets 3/4 need an explicit rule that a failed lookup cannot authorize a replacement shell or conversation launch.

**Evidence:** `docs/c11h-plan.md:43-47` permits plain-shell fallback and separately promises same-process restore. The spike falls back before resolving an old panel if the core is unavailable (`spike:Sources/C11vSpikeBackends.swift:100-103`). Once connected, `openOnControl` ignores the error from `terminal.list` and treats any missing result as permission to `terminal.run` (`1267-1281`). The existing resume predicate accepts an attached terminal with unknown shell state (`Sources/Workspace.swift:657-670`).

**Consequence:** A slow startup, transient list failure or lost run reply can produce a second shell/agent for a panel whose original process is still alive. A successful ordinary restart does not cover this failure.

**Smallest fix to the plan:** Freeze a shared lifecycle result in ticket 2: new, live, confirmed ended/missing, or unresolved/reconnecting. Tickets 3, 4 and 6 must use it. Restored unresolved panels wait and retain identity; only an authoritative absence permits a fresh terminal and resume. Reconcile labels after an ambiguous `terminal.run` result before retrying. Limit any exec fallback to explicitly identified new, nonpersistent panels and make their Quit behavior clear. Test delayed/failed list replies, a lost run reply and app launch while the core is recovering; assert one terminal and no injected resume.

### 7. P1: Ticket 4 misses the dirty-startup conversation audit that also suspends surviving agents.

**What is wrong or missing:** Avoiding `suspendAllAlive` on Quit and suppressing typed resumes is insufficient to preserve live conversation state after force-quit.

**Evidence:** The feature map's row 35 cites the workspace resume path, but current main also runs `Sources/Conversation/StartupConversationAudit.swift:133-147` on a dirty launch. `Sources/Conversation/Store.swift:739-751,807-828` turns verified live refs into `.suspended` and unverified ones into `.unknown`, even when their hc process survived. This runs independently of the clean-Quit suspension in `AppDelegate`. Ticket 4's acceptance only observes that a Claude command was not typed.

**Consequence:** The UI can look reattached while the conversation store, journal ownership and later resume decisions still describe a dead prior process. A typed-resume guard alone conceals the inconsistency.

**Smallest fix to the plan:** Add `StartupConversationAudit`, crash-verdict application and late scrape commits to ticket 4. Reconcile surviving hc terminal/process identity before applying dead-process recovery, while retaining the existing causal conversation safeguards. Test force-quit with exact Claude and Codex refs: same runtime and conversation remain live, no fresh wrapper claim/capture is required, and no late audit overwrites them; after actual holder loss, fresh-terminal resume occurs once.

### 8. P1: Relearning tty and pid does not restore Claude's native mailbox route.

**What is wrong or missing:** Tickets 7/8 assume restoring process attribution is enough for the full mailbox behavior to return.

**Evidence:** Claude's native bridge starts only from the wrapper's SessionStart hook (`Resources/bin/claude:255-270`). `CLI/CMUXCLI+Run.swift:119-132` connects once, runs the bridge and returns on disconnect; `CLI/ClaudeMailboxCommand.swift:258-273` throws on EOF. The still-running Claude does not emit a new SessionStart just because c11h restarts. Its binding includes a private session token, held only in the bridge (`ClaudeMailboxCommand.swift:23-36`), so the app cannot reconstruct the bridge from a pid. The prescribed “mail sent after restart reaches it” can pass via typed fallback at an empty prompt.

**Consequence:** A surviving Claude silently loses native mail after every app restart. Mail that previously reached an idle agent with an operator draft now waits behind that draft, so the agent layer is not equivalent to c11's pre-restart behavior.

**Smallest fix to the plan:** Include surviving native subscriptions in ticket 8: the original session-bound bridge must reconnect/re-register safely, retaining its token only in its own memory and retiring on replacement or agent exit. Validate both native and typed routes after restart, including an idle Claude with a draft left untouched. Include one reconnecting extension route such as omp/OpenCode in the assembled agent test. Also test an agent launched by a surviving shell while c11h is down: the current wrapper deliberately bypasses hooks when its ping fails (`Resources/bin/claude:110-132`), so the plan must state how that agent gains the promised reporting/mail capabilities when the app returns.

### 9. P1: No ticket owns a complete hc inventory and event resynchronization contract.

**What is wrong or missing:** Restore, gate admission and agent recovery depend on authoritative terminal state, but the spike event client is only a logging skeleton and the ticket split never assigns its replacement explicitly.

**Evidence:** `spike:Sources/C11vSpikeBackends.swift:939-959` counts and discards the subscription's terminal snapshot. Lines 962-989 handle finished events, log created/lost/restarted, ignore status/foreground and only log `missed`. The feature map requires refreshing the gate's live pid set on created/restarted/finished (N4), and recovering status and foreground (rows 12, 14, 37). `TerminalController.handleClient` admits/rejects the peer before startup command handling (`Sources/TerminalController.swift:2325-2359`), so a one-shot hook rejected before inventory is ready does not become valid later.

**Consequence:** Missed events or a reconnect can leave stale gate pids, agent attribution and status, or reject the startup reports needed to recover them. A core-kill test that checks only the screens will miss this.

**Smallest fix to the plan:** Put a snapshot-plus-deltas inventory in ticket 2, with framing, sequence/generation handling, bounded buffering, resnapshot on `missed`, and an explicit readiness signal. Tickets 3/7/8 consume this one inventory; pending inventory is unavailable, never proof that a process died. Add a quick injected-event test covering missed/duplicate events, a process exiting or being replaced while c11h is absent, and a new terminal reporting immediately at birth. Check current pid/status and gate decisions, not just panel count. Ticket 9 exposes this readiness and identity evidence in its diagnostics.

### 10. P2: Wave 2's dependencies do not match the shared state and existing-file edits.

**What is wrong or missing:** Splitting the new backend file does not make tickets 3 through 9 independently implementable after ticket 2.

**Evidence:** `docs/c11h-m1-brief.md:47-48` gives only ticket 8 a dependency on 3. Tickets 3 and 4 share restore construction and resume submission in `Sources/Workspace.swift:1335-1365,777-798`; tickets 7 and 8 share `TerminalController.swift` and tty/process registration. Ticket 7's requirement that existing `$C11_PANEL_NUM` and port ranges remain correct needs persisted allocation before restored panels mint refs: current refs allocate from an in-memory counter (`TerminalController.swift:3133-3145`), port ordinals reset (`WorkspaceManager.swift:989-991,6084-6096`), and the spawn env is immutable in surviving processes (`GhosttyTerminalView.swift:3662-3674,3719-3724`). Recovery of an orphan also has to preserve that terminal's existing UUID/env identity. Tickets 5 and 6 both touch attach/resize sequencing. Additionally, wave 3 waits for “every ticket merged,” while ticket 10's done condition already includes the laptop install that must wait for wave 3 GREEN.

**Consequence:** Owners can build mutually incompatible liveness, persisted identity and readiness rules; the final integration discovers omissions only after parallel branches exist. The ticket 10 completion gate is circular as written.

**Smallest fix to the plan:** Have ticket 2 freeze the lifecycle/inventory/attach interfaces and file ownership before wave 2. Assign persisted panel ordinals, allocation high-water marks, port reservations and orphan identity to ticket 3 in collaboration with 7. Make 4 and 7 depend on that contract/implementation; 8 depends on 3, 4, 6 and 7 for final acceptance. Permit 5/6 parallel work only behind the frozen interface, and 9 against its diagnostic schema. Split ticket 10 into artifact/install-command ready before validation, then approved the laptop installation after GREEN. Test reordered/gapped panels, multiple windows, an orphan and creation of a new workspace after restart; old env must still target itself and new ports must not reuse a live range.

### 11. P2: The TCC and update gates do not test the actual signed installation lifecycle.

**What is wrong or missing:** The Pathfinder's spike relaunch test and “same pid after installed update” do not prove that the signed staging update preserves file access or the executable paths surviving shells and holders need.

**Evidence:** `docs/c11h-plan.md:59` tests protected-file access after app/core relaunch, but not after replacing the signed app; ticket 10's acceptance checks only that agents survive. `GhosttyTerminalView.swift:3683-3688,3732-3739,3743-3778` embeds the CLI, wrapper PATH and shell-integration paths in terminal env. Holders restart the core from their remembered executable path (`notes/c11v-herdr-core/hc-federation-robustness.md:60`). The existing remote Release route produces a tag-named staging bundle (`scripts/remote_build.py:497-500`), not by itself the final stable install path.

**Consequence:** Agent pids can survive a successful update while future hook calls, new nested shells or the next holder-led core restart fail; file access can regress without the current update assertion noticing.

**Smallest fix to the plan:** Make ticket 10 and the final validator install two genuinely different signed Release builds at the intended stable path in a guest. Use the ordinary app launch, not only QA environment overrides. Before/after replacement, read actual protected fixtures from the same shell, invoke c11h's CLI/hooks from a surviving agent, start a new shell, then kill only the core and verify holder-led recovery. Keep the external hc executable at a stable retained path and hold its pin fixed for M1 app updates; require a separate screen/history compatibility gate for any later hc/VT upgrade. The laptop gets the already-tested command and artifact.

### 12. P2: “The spike's 20-row checklist passes” is not an executable M1 acceptance gate.

**What is wrong or missing:** Ticket 2 imports a checklist containing known failures, partial results, unperformed checks and a remote case outside M1 without assigning remedies or permitted residuals.

**Evidence:** `docs/c11h-plan.md:43` requires all 20. `SPIKE-0B.md:38-40` records DA1/XTGETTCAP differences and bell/IME not driven; lines 44-45 make flood/theme proof partial; lines 52-62 qualify remote and scale proof. Query fixes are assigned to the future fork in `SPIKE-0B.md:129-137`, while the vision postpones the fork to M5 (`docs/c11h-vision.md:75`). The measured spike used hc 0.1.14, whereas M1 pins 0.1.15. Ticket 9's “an agent diagnoses” also has no named fault or expected diagnostic fields.

**Consequence:** Owners and reviewers cannot agree whether a ticket is green. They must either silently waive failures, expand M1 into hc work, or block indefinitely on a check the guest cannot perform.

**Smallest fix to the plan:** Before tickets start, publish a row-by-row M1 acceptance matrix against exactly 0.1.15: ticket owner, procedure, timeout, observable assertion, and any explicitly accepted residual. Move the remote leg to M3. Assign still-present query defects to an M1 patch or an explicit product limitation; give bell/IME a feasible human acceptance route if automation cannot drive them. Preserve a usable latency probe/baseline after removing spike switches. For ticket 9 inject at least unavailable core, failed attach and refused caller, and require diagnostics to identify panel UUID, terminal, server build, lifecycle/readiness and reason without terminal contents or secrets. Do not label an unperformed/partial row PASS.

### 13. P2: No ticket owns clearing authoritative scrollback, a feature-map regression already identified.

**What is wrong or missing:** The M1 promise of the existing CLI and terminal behavior omits `clear-history` across reattachment.

**Evidence:** Feature-map row 27 (`notes/c11v-herdr-core/feature-map.md:50`) says the existing command clears only c11's renderer and history returns on the next attach. Current `Sources/SocketHandlers/PanelHandlers.swift:1372-1377` still performs only Ghostty's local `clear_screen` action. Ticket 5 validates find, and ticket 3 avoids duplicate capture/replay, but neither owns clearing the history source.

**Consequence:** Text the operator or agent explicitly cleared reappears after a routine restart. A successful find-over-attach test does not cover that behavior.

**Smallest fix to the plan:** Add authoritative history clearing to ticket 3 (with ticket 5's renderer integration), or explicitly narrow M1's clear-history behavior and report the unsupported operation rather than claiming a durable clear. Test a unique marker, clear, app reattach and core reconnect; the agreed behavior must hold. Determine whether 0.1.15 exposes the required primitive before assuming this is purely Swift work.

## What the plan gets right

- Separate product/repo/board, disabled Sparkle, and a guest-first the laptop handoff protect the live c11 workflow.
- Keeping c11's agent model and cell-aware input guard is the correct division of responsibility.
- The plan explicitly tackles stale env, tty/pid recovery, resume suppression and persistent-process close semantics.
- TCC, flood memory and assembled-build validation are correctly treated as evidence gates rather than inferred from unit tests.
- The holder failure limit and same-user trust boundary are stated plainly; neither is hidden behind the persistence claim.

NOT READY


## Verification

Verified 2026-10-31, 15:40 PDT against the revised plan and build brief. ADDRESSED means incorporated into the plan, not implemented or proved. The brief's instruction to paste the relevant original findings into owner briefs preserves their detailed acceptance scenarios.

A1: ADDRESSED
A2: ADDRESSED
A3: ADDRESSED
A4: ADDRESSED
A5: PARTIAL — The queue and replay contract is present, but ticket 6 still requires a paste to arrive whole or be refused after killing the core mid-paste (`docs/c11h-plan.md:68`). It does not distinguish rejection before transmission from uncertain delivery after transmission, despite A5's explicit limit on guarantees across unacknowledged loss. Smallest change: retain whole-or-refused for input not yet sent; specify a visible indeterminate outcome for interrupted in-flight input, no automatic replay or submission of its queued Return, and saturation/outage assertions for the actual bytes and reported outcome.
A6: ADDRESSED
A7: ADDRESSED
A8: ADDRESSED
A9: ADDRESSED
A10: ADDRESSED
A11: ADDRESSED
A12: ADDRESSED
A13: ADDRESSED

Regressions introduced by the revision:

1. **The new lifecycle rule excludes initial creation.** `docs/c11h-plan.md:53` says only an authoritative `ended` allows a fresh terminal, although `new` is a separate state and ticket 2 explicitly permits a new panel's plain-shell fallback (`:64`). Applied as the frozen contract, this leaves a genuinely new panel without permission to create its first terminal. Smallest change: permit first creation from `new`; require authoritative ended/missing only for replacement or resume of an existing identity; make an ambiguous creation result `unresolved` before any retry. Owner: ticket 2 / plan owner.

Totals: **12 addressed, 1 partial, 0 missed, 0 declined-ok, 1 regression.** These are two contract corrections before launch; no new source discovery was opened.

Reviewed document SHA-256: plan `c82941dc9f0c441c8bff27a7ce0b2f6a3157876c8d7a739e7bcd807c3aace5a8`; brief `5c267960f2deebc8b86ea0c9efc4d34f6a13e58a659fb025663bbcf40b616cfd`. No plan edits, builds, launches or pushes.
