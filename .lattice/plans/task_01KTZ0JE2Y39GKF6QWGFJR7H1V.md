# C11-138: Identity & write-routing correctness (C11_* env export, socket discovery, empty-ref misroute, naming sweep)

## Identity & write-routing correctness (audit keystone)

Source: `notes/c11-audit-merged-2026-06-09.md` P0.1, P0.2, P3-naming. Validated against HEAD `b3dfc10bc` (line refs below corrected from the audit's `5c1227bfe` numbers). **Do this ticket first** — the audit's own note: fix the `C11_*` export side *before* any blind cmux→c11 rename, because the cmux-named paths are load-bearing until then. Unblocks ~15 downstream findings.

### A. Export `C11_*` to spawned shells (P0.1) — CONFIRMED
The binary exports only `CMUX_*` to shells; every skill, doc, and the naming convention assume `C11_*` exist. Recommended fix: **export both** from the binary.
- `Sources/GhosttyTerminalView.swift:3339-3413` — PTY env seeds `CMUX_SURFACE_ID/WORKSPACE_ID/PANEL_ID/TAB_ID/SOCKET_PATH/SHELL_INTEGRATION` only (the per-surface `env` dict starts empty and does not inherit the app-process mirror). Add `C11_*` aliases for every key here.
- `Sources/C11EnvBridge.swift:5-16` — `mirrorC11CmuxEnv()` mutates only the *app/CLI process* env (callers `AppDelegate.swift:2421`, `CLI/c11.swift:16189`); it never reaches the spawned shell. Not a substitute for the PTY fix above.
- `Sources/SocketControlSettings.swift:296-298,460,467,650,667` — socket-control reads only `CMUX_SOCKET_PASSWORD/PATH/ENABLE/MODE/_ALLOW_OVERRIDE` + `CMUX_TAG`. Add `C11_*` fallbacks (a caller exporting `C11_SOCKET_PASSWORD` silently fails auth today).
- `C11_AGENT_TYPE` / `C11_AGENT_MODEL` / `C11_AGENT_TASK` exist **nowhere** in code (only in `skills/c11/SKILL.md:25,43,48,69,113` + `references/api.md:56-58,195`); `c11 set-agent --type "$C11_AGENT_TYPE"` errors because `--type` is required and the var is unset. Either implement spawn-path seeding of these three vars, or delete the doc claims. **Decision required.**
- **Note — daemon Go is already fine:** `daemon/remote/cmd/c11d-remote/cli.go:91-93` already reads `C11_SOCKET_PATH` then legacy `CMUX_SOCKET_PATH`. The audit's "same gap" is partly wrong; only `CMUX_WORKSPACE_ID/SURFACE_ID/RELAY_*` remain cmux-only there, moot until the binary exports the C11_* equivalents.

### B. CLI socket auto-discovery is cmux-named (P0.1) — CONFIRMED, verified live
Server binds c11-named paths but the CLI looks for cmux-named ones, so any caller **outside a c11 pane** (cron, launchd, fresh shell) cannot find a running server. Every discovery channel is broken:
- `CLI/c11.swift:695-701` — `appSupportDirectoryName="cmux"`, `stableSocketFileName="cmux.sock"`, `/tmp/cmux.sock`, `/tmp/cmux-debug.sock`.
- `CLI/c11.swift:738-757` — candidate paths; `:743-744` tag-derived `/tmp/cmux-debug-<slug>.sock`; `:289` `discoverSockets` filters `name.hasPrefix("cmux")`; `:809` `discoverTaggedSockets` same; `:763-778` breadcrumb read from `cmux/last-socket-path` + `/tmp/cmux-last-socket-path`.
- Server side binds/writes c11: `SocketControlSettings.swift:300-301,591-601` (`Application Support/c11/c11.sock`), `:565,:582` tagged `/tmp/c11-debug-<slug>.sock`, `:304,:526` breadcrumb to the `c11` dir. (In-pane callers are saved only because the PTY hands them `CMUX_SOCKET_PATH` directly.)
- Fix: rename discovery dir/file/glob/breadcrumb to c11, keeping cmux as a fallback.

### C. Absent-vs-empty surface/tab refs misroute writes (P0.2) — CONFIRMED
Empty-string refs are treated as "absent" and fall back to the **focused** surface, so a sub-agent stomps a peer's terminal/metadata with an identical-looking `OK`.
- `Sources/TerminalController.swift:4068-4072` (`v2String` trims+nils empty), `:4119-4125` (`v2UUID`) — empty collapses to nil. The real defect is empty==absent conflation here (the audit's "unify v2UUID/v2UUIDAny" framing is slightly off — both already nil empty).
- `CLI/c11.swift:2445-2448` (send) / `:2467-2470` (send-key) — guard passes when `CMUX_SURFACE_ID` is non-nil even if empty; `normalizeSurfaceHandle` (`:4531-4545`) nils empty → no `surface_id` sent → server resolves `v2UUID(...) ?? ws.focusedPanelId` at **`TerminalController.swift:7716`** (corrected from audit's `:7654`).
- `Sources/TerminalController.swift:18093-18108` — `resolveTabForReport`: `--tab=""` fails the non-empty check at `:18096` and falls through to `selectedTabId` at `:18107-18108`. (The `--panel=` path is already hardened — empty errors at `:18164-18166`. Only the tab side leaks.)
- **Root fix once at the parse layer:** make `v2String`/`v2UUID` (or a new strict variant) distinguish *absent* from *explicitly-empty/whitespace* and ERROR on explicitly-empty surface/tab refs; apply at `:7716` and `:18096`.
- **Already fixed, do NOT chase:** the SessionStart conversation-push path (audit cited `CLI/c11.swift:14555,15026-15034`). Both `resolveConversationSurface` (`CLI/c11.swift:11653-11663`) and `v2ResolveSurfaceForConversation` (`TerminalController.swift:9772-9783`) now explicitly throw `missing_surface` rather than falling back to the focused surface.

### D. Naming residue sweep (P3) — CONFIRMED, sequence AFTER A/B land
- `~/.cmuxterm/` hook-state path (`CLI/c11.swift:371,13998,14416`) — rename to `~/.c11` **with migration** (read at runtime).
- `discoverSockets`/`discoverTaggedSockets` cmux-prefix filters — folded into B.
- One genuinely user-visible string: `Sources/TerminalNotificationStore.swift:822` `"cmux test notification"` (also unlocalized); `:1042` `?? "cmux"` fallback. Fix both.
- `Resources/bin/open` cmux gating + UserDefaults keys (`browser*InCmuxBrowser`) — cosmetic, rebrand comments/keys.
- Keep deliberately: the about-screen "fork of cmux by manaflow-ai" lineage attribution (`c11App.swift:3199`); UserDefaults `cmux` *migration* keys (renaming re-runs migration).

### Acceptance
Out-of-pane `c11 ping` succeeds against a running app; `C11_SHELL_INTEGRATION`/`C11_SURFACE_ID` are set in spawned shells; `skills/c11/SKILL.md:19-48` detection + orient recipes work as written (or the doc is corrected to match); an explicitly-empty `--surface ""`/`--tab ""` errors instead of routing to the focused surface.
