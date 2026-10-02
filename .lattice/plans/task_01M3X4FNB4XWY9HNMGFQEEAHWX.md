# C11-283: Scope --window without focusing that window

## Incident
`c11 --window <id> <command>` sends `window.focus` before the command (`CLI/c11.swift:1950-1954`). `focusMainWindow` (`Sources/AppDelegate.swift:6128-6141`) then `orderFront`s that window when the socket command is focus-intent, and `window.focus` is focus-intent (`Sources/TerminalController.swift:252-267`, `WindowHandlers.swift:21` and `:62-76`). Fleet commands pull the key window around. Base `0ff8887e5e`.

## What is already true
- The global flag is stored at `CLI/c11.swift:1732-1736`. `normalizeWindowHandle` (`:5103-5125`) accepts a UUID or `window:N` without checking it exists, and returns nil for empty input. The call site uses `?? windowId`, so an empty token is forwarded. A non-numeric garbage token already throws `Invalid window handle`. `window:999` reaches `window.focus`, whose `not_found` / `invalid_params` does not echo the caller's token. `sendV2` throws on `ok: false` (`:1455-1478`), so the command stops, but only after the focus call.
- Server routing already prefers `window_id`. `v2ResolveWorkspaceManager` (`TerminalController.swift:2947-2972`) returns that window's manager and does not scan other windows. `v2ResolveWorkspace` (`:3044-3052`) then looks up workspace and tab only inside that manager, and returns nil when the tab is elsewhere. `resolveSurfaceSendTargets` (`:3194-3198`) and `v2SurfaceReadText` (`SurfaceHandlers.swift:1129-1135`) turn that nil into `not_found`. No send-delivery or mailbox edit is required.
- A missing `window_id` still locates a tab globally (`:2959-2962`). That stays. An unknown `window:N` makes `v2UUID` return nil and the manager falls through to the key window. The CLI must reject that id before the command.
- Many arms already skip `CMUX_WORKSPACE_ID` when `windowId != nil` (`new-split` `:2253`, `identify` `:1978`, `workspaceFromArgsOrEnv` `:11942-11946`) and still do not put `window_id` on the socket call. They worked only because the pre-dispatch focus changed which window was current.
- `focus-window` (`:2039-2044`) is v1 `focus_window`, not v2 `window.focus`. `workspace.select` (`WorkspaceHandlers.swift:261-284`) is focus-intent and may `focusMainWindow` plus `NSApp.activate`. Leave both.
- `tab.create` is not focus-intent (`SurfaceHandlers.swift:417-421`), so `v2FocusAllowed` is false. Stamping `window_id` does not raise.
- `c11 tree --window` with no value is a scope flag (`tests_v2/test_tree_scope.py`), not the global id. No `tests_v2` caller depends on the global flag's focus side effect. `skills/c11/SKILL.md:160` already says socket commands do not steal focus. It does not say what `c11 --window <id>` does.

## Change
For `send` and `send-key`, preserve explicit-target enforcement using the effective target after window scoping: with a global `--window` and no explicit tab, the caller env tab is suppressed, so an env tab's mere presence must not pass the guard and send to the scoped window's focused tab. Test this from a c11 terminal with both caller env ids populated; no input may reach either window.

Delete `:1950-1954`. Do not replace it with `NSApp.activate` or `window.focus`.

Before the command switch, resolve the global token once:

- List `window.list`. Match UUID, `window:N`, or the listed `index`.
- On miss or empty input, throw `CLIError` with `String(localized: "cli.window.unknown", defaultValue: "Unknown window '%@'.")` containing the raw token. No focus call, so the key window stays.
- Keep the resolved ref (prefer `ref`, else `id`) in `scopedWindow`.

Add two private helpers next to `normalizeWorkspaceHandle`:

- `stampWindow(_ params: inout [String: Any], scopedWindow: String?)` sets `window_id` when non-nil.
- `normalizeWorkspaceHandle` calls from those arms pass `windowHandle: scopedWindow`, so a numeric `--workspace N` lists only that window (`:5148-5154`) and does not take the all-windows scan (`:5156-5167`). A `workspace:N` or `tab:N` that lives elsewhere is left for the server, which returns `not_found`.

Stamp `window_id` on the socket params of every arm that already reads the global `windowId` local, plus the fleet set the ticket names: `send`, `send-key` (same misdirection comment at `:2956-2959` and `:2987-2988`), `read-screen`, `tree`, `new-tab`, `new-split`, `new-area`, `list-workspaces`, `select-workspace`. `identify` gets it too, because it already suppresses the env fallback.

`tree`: pass `scopedWindow` into `runTreeCommand` / `buildTreeWindowNodes`. When set, the node list is that window, not `activePath.windowHandle` (`:14213-14218`). `c11 tree --window` with no global id stays "current window". Do not parse the tree flag as an id.

`select-workspace` gets `window_id` and may still change in-app selection through the existing handler. It is not used to satisfy the read-screen criterion.

Commands that never route (`ping`, `capabilities`, `brand`, `version`, `doctor`, `health`, `events`, `welcome`, app-down `config`) do not get a fake `window_id`. The id is still validated up front, then ignored. They do not focus.

Do not touch `deliverSocketSendText`, the `submitted` / `queued` / `delivered` envelope, or mailbox logging. C11-257 owns those.

## Files
- `CLI/c11.swift` — delete the focus prelude, add the resolver and `stampWindow`, stamp the arms above, pass `windowHandle` into workspace normalization on those arms.
- `skills/c11/SKILL.md` — extend the focus-policy sentence at `:160`: `c11 --window <id>` scopes the command to that window and does not raise it. `c11 focus-window` is how you raise. A tab or workspace that is not in that window is `not_found`.
- `skills/c11/references/api.md` — same sentence where global flags are listed. Do not change the meaning of `c11 tree --window` or `c11 config stats --window`.
- `tests_v2/test_window_scope_no_focus.py` — new live script.

No server file. No `hitTest` / `forceRefresh` edit.

## Acceptance → incident → test → proof
1. Key window stays. Incident: fleet `--window` raises. On an Atlas tagged build with two windows, `focus-window` so A is key, then `c11 --window <B> read-screen --tab <tab in B>`. Response text is from B's tab (`window_id` in the JSON is B). `window.list` still marks A `key: true` before and after. `window.create` makes the new window key, so the script focuses A back before the assertion. That setup focus is not the behavior under test.
2. Bad id. Incident: `?? windowId` forwards junk. `c11 --window not-a-window read-screen` and `c11 --window window:999999 read-screen` exit non-zero, the stderr contains that token, and A's `key` flag is unchanged.
3. Foreign tab. Incident: focus made the other window's tab the target. `c11 --window <B> send --tab <tab in A> --raw` (or a unique sentinel) returns `not_found`. A's `read-screen` does not contain the sentinel. B is not key.
4. Real focus commands. `c11 focus-window --window <B>` leaves B key. `c11 --window <B> select-workspace --workspace <ws in B>` may change B's selected workspace. Criterion 1 does not depend on it.
5. Dispatch review, not a source-grep test. After the change, `window.focus` is not sent from the global prelude. `focus-window` stays on v1 `focus_window`. The behavioral proof is criterion 1. Test policy forbids a test that only greps the CLI source.

No soak. This removes a focus round trip. It adds no work on `WindowTerminalHostView.hitTest`.

## Hot path, strings, persistence
CLI parse and one `window.list` before the command. No keystroke path. No new per-keystroke work. Compare paired window-scope/input latency with C11-270's published baseline/budgets; window listing remains its existing main snapshot. No persistence.

New key: `cli.window.unknown`. English only. `%@` must survive C11-291. No other new string unless an arm's existing English error is touched, in which case leave that string as it is.

## Cut line
No change to `focusIntentV2Methods`. No C11-140 focus-allowance stack. No `settings.open` activation. No `resize-window` (C11-286). Do not retarget `focus-window` onto v2. Do not change `new-tab`'s focus policy. Do not make `--window` a general scope for browser/markdown command flags that already have their own `--window`. C11-284 merges first. Enable `window.route_without_focus` in `Sources/CapabilityFeatures.swift` and use its typed entry in the CLI scope-dispatch path in this same PR. The tagged capabilities response must advertise the flag and the no-focus/foreign-tab scenarios must pass on that artifact (audit finding 8).

## Dependencies and conflicts
- `CLI/c11.swift` is shared with C11-280 (`new-workspace` / `new-split` / `new-area` / `new-tab`, around `:2213-2623`), C11-281 (`send` at `:2947-2976` and `unescapeSendText` at `:11935`), C11-282 (a new command arm), and C11-284 (early dispatch before connect, and the `capabilities` arm). This PR's hunks are the prelude at `:1950` and a `stampWindow` line plus a `windowHandle:` argument on the arms above. Rebase those hunks. Do not mix `--command`, `--raw`, or `guide` into this diff.
- Skill files: one sentence each. Other CLI tickets edit the same files.
- C11-257: stay out of `deliverSocketSendText` and send-event logging. The not_found for a foreign tab already comes from `v2ResolveWorkspace` once `window_id` is set.
- C11-291 translates `cli.window.unknown`. C11-284 merges first, followed by C11-279 before this ticket; later CLI tickets preserve this scoped routing path.

## Decisions
None for Atin. Non-routing commands validate the id and then ignore it, rather than focusing or erroring. Routing commands that already branched on `windowId` get `window_id` on the socket call, which is the scope Astra said the backlog's S label left out.

## Build-mode notes
Branch `c11-1.0/C11-283-window-scope` from current origin/main after predecessor merges; 0ff8887e5e is the citation/intake base, not the later implementation base. One PR. Atlas tagged build for the script. `C11_QA_LAUNCH` set. Attribute any implementation commit to its actual author/model, not the previous planning owner. Sync the installed c11 skill on the landing machine. Do not merge.

## Codex takeover verification
Owner: agent:codex-cli. Verified ticket, stored plan and cited code on intake origin/main 0ff8887e5e965400b01645ef40b85fd0b2605cf2. All behavioral checks above are planned, unperformed. Planning hold remains: no builds, tests, product-code commits or pushes until explicit BUILD MODE. Branch from current origin/main when this ticket starts, retaining predecessor merges and previous local commits.

## History lane implementation corrections (base 43529df178a9cd8817fc092896efd2f3fcd63df5)

The Orchestrator reassigned C11-283 to agent:codex-history; branch c11-1.0/C11-283-window-scope. C11-284 is present. Existing v2 system.tree ignores window_id and chooses focus/caller context, so merely stamping it would still expose the wrong window. The CLI sends scope and filters tree nodes to the validated window; if the fast response lacks that window, its existing legacy node builder resolves only the target window. No server or typing-path edit is needed.

Propagate the validated window at SocketClient.sendV2 for routing domains and system.identify/system.tree, rather than repeating stampWindow at every command and helper call. This covers numeric area/tab lookups and metadata helper dispatch, which the original per-arm edit list did not fully enumerate. Explicit per-command window parameters retain their meaning. Normalize numeric workspace lookup using that shared scope and restrict resolveWorkspaceId's ref/UUID scan to it. Legacy sidebar v1 calls must carry the scoped selected workspace explicitly because they have no window parameter. Preserve caller identity fields; they describe provenance and are not routing fallbacks. send/send-key admission uses the effective surfaceArg, suppressing caller-env tabs under global --window. Offline commands and app-wide history retain their existing independent behavior.

Enable and consume CapabilityFeatures.ID.windowRouteWithoutFocus at global scope admission. New English key cli.window.unknown only; translation remains C11-291. Source skills are updated, but only the Merge Captain syncs installed copies from merged main. Add executable fake-socket CLI routing coverage in tests/test_cli_window_scope.py and run it against the built CLI, then prove actual no-focus/foreign-tab behavior and advertised feature on a tagged app. No Tart guest was created by this lane; leave other guests alone.

## First implementation review repairs

The routing fixture now models real key-window tree scope and handlers that globally locate tabs. Clear-notifications and current-workspace carry the scoped selected workspace on legacy paths. Legacy sidebar workspace UUIDs go through scoped membership resolution; sidebar JSON suppresses ambient workspace env. Notification, attention, sidebar and snapshot routing methods receive window_id. For tab.move/reorder and attention mutations whose existing handlers locate globally, the CLI checks requested source/destination/anchor membership before mutation. The default tree resolves the scoped selected workspace explicitly and applies the same selection in the legacy fallback.

One server exception to the original no-server cut is necessary: Sources/SocketHandlers/ConfigHandlers.swift must forward its incoming window_id when composing agent.launch. This is a single parameter preservation change; the existing agent launcher already resolves the target manager from it. No input, focus-intent or telemetry threading code changes. The CLI fixture proves the incoming config route; the native tagged app proves its actual target placement.

## Final routing seam correction

The tab.move handler treats window_id as an explicit destination. Global scope therefore validates the source tab and its handles without injecting a destination window. An explicit command-local --window retains destination meaning and checks destination handles in that window. Regression fixtures cover both index-only moves from a nonselected scoped workspace and explicit cross-window transfers. Snapshot restore routes by scope and suppresses caller env for in-place targets. Area swap/join admission includes source/target area membership. Titlebar helpers suppress ambient workspace/tab routing under global scope.

## Native focus setup correction

The existing focus-window handler calls orderFront and selects the active window manager under socket focus policy; it does not make a previously non-key window become macOS key. Establish key A with a PID-scoped UI AXRaise on the owned tagged app, then use the real window.list key flags before/after scoped commands. Preserve the focus-window dispatch and verify its existing active-manager selection through current-window. Acceptance step 4's old promise of key B is corrected to this observed existing behavior; no focus-handler change is part of this ticket. Capability identity commit stamps may be null on these debug artifacts, so exact-head proof uses the remote build manifest and matching owned executable SHA256, without claiming nullable sha_match is true.

## Astra repair round 1

Blocking review ev_01M3XYQPF1QM1AJQYZ36MYV1P6 exposed three additional legacy routes. Carry the scoped workspace UUID on drag_surface_to_split and refresh_surfaces (--workspace=), and default_agent launch (--workspace UUID). The server resolves that workspace's manager without changing the active manager or focus. Existing-tab default launch uses the same workspace for cwd lookup and delivery. Preserve unscoped behavior and off-main launch file I/O.

An explicit tree workspace must resolve inside the global window before system.tree. In fallback, workspace.list selects a manager and lists all its workspaces; filter those rows to the resolved explicit workspace. The executable fixture now models this real enumeration behavior. Cover explicit nonselected B workspace and foreign A workspace UUID/ref on native, ignored-scope and unsupported-tree servers; legacy mutations only B, A remains key; stale closed-window rejection and unscoped controls.

English scope keys for C11-291: cli.window.scope.workspaceNotFound, cli.window.scope.tabNotFound, cli.window.scope.areaNotFound, cli.window.scope.workspaceTabNotFound. Additional legacy server keys are listed in the repair validation comment. No forceRefresh implementation or input-path edits. Default legacy refresh merely changes which workspace is traversed.

Legacy carrier error keys for C11-291: socket.workspace.invalid and socket.workspace.not_found. Scoped CLI tab resolution also rejects malformed explicit tokens before any legacy mutation. The localized error retains the rejected workspace token as diagnostic data.
