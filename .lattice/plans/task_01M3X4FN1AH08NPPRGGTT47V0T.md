# C11-280: Type --command into a new terminal via Ghostty initial_input

## Incident
`c11 new-workspace --command` creates the workspace, then calls `tab.send_text` and discards the response (`CLI/c11.swift:2238-2244`). That send races shell startup and drops. `new-split` (`:2247-2279`), `new-area` (`:2350-2377`), and `new-tab` (`:2601-2623`) have no `--command`. Help at `:8907`, `:9010`, `:9137`, and `:9238` matches. Base `0ff8887e5e`.

## What is already true
- `initial_command` replaces the shell. `v2WorkspaceCreate` (`WorkspaceHandlers.swift:117-118`, `:232`) passes it to `addWorkspace` as `initialTerminalCommand`. `TerminalSurface` writes it to `surfaceConfig.command` inside `withCString` before `ghostty_surface_new` (`GhosttyTerminalView.swift:3689-3709`). Ghostty then sets `config.command = .{ .shell = cmd }` and `wait-after-command` (`ghostty/src/apprt/embedded.zig:541-547`, read at `/Users/atin/Projects/Stage11/code/c11/ghostty`, not the worktree). Keep this path.
- `ghostty_surface_config_s.initial_input` is already in `ghostty.h:450` (worktree header) and `embedded.zig:464-465`. Nothing in Swift assigns it. Ghostty copies it into `config.input` (`embedded.zig:564-582`) and `Termio.threadEnter` queues those bytes to the PTY after the process starts (`src/termio/Termio.zig:335-387`). The bytes sit in the PTY until the shell reads them, which is why a slow rc does not drop them the way a later `send` can. Do not change Ghostty. Do not init the worktree submodule.
- `newTerminalSurface` (`Workspace.swift:8343-8376`) already passes `initialCommand: remoteTerminalStartupCommand()` for remote shells. `--command` must be a second argument. Do not overwrite that field.
- The layout branch of `v2WorkspaceCreate` (`:159-216`) returns before `initialTerminalCommand` is applied. A `--layout` plus `--command` pair has to fail before `v2WorkspaceApply`, or a workspace is left behind.
- `tab.create` / `area.create` already reject unknown panel types via `v2SurfaceTypeDenial`. They do not know `--command`.
- Headless PTY start runs only when `initialCommand != nil` (`GhosttyTerminalView.swift:2882-2890`). `initial_input` needs the same start, or a background workspace waits for focus before the shell exists.

## Change
Add a pure helper `CreateInitialInput.decide(raw:panelType:hasLayout:) -> Decision` in `Sources/CreateInitialInput.swift`:

- nil or whitespace-only → `.absent`. Drop it. Do not append a CR.
- non-empty and `hasLayout` → `.rejectLayout`.
- non-empty and `panelType` is `browser` or `markdown` → `.rejectNonTerminal`.
- otherwise `.queue`. Do not run `unescapeSendText`. A backslash followed by `n` stays those two characters. If the string does not already end in `\r`, append one `\r`.

CLI (`new-split`, `new-area`, `new-tab`, `new-workspace`):

- Parse `--command`. Blank is `.absent`.
- On `.rejectNonTerminal` or `.rejectLayout`, throw `CLIError` with the localized string and do not call the socket. Nothing is created.
- On `.queue`, set params `initial_input` to that string.
- `new-workspace` stops calling `tab.send_text`. Print the created ref and `input=queued`. Do not say the command ran.
- Help text: `--command` types into the new shell. It is not a shell replacement. `--layout` and `--command` together are an error.

Server, before any create:

- `v2WorkspaceCreate`: if `decide` is a reject, return `invalid_params` and do not call `v2WorkspaceApply` or `addWorkspace`. On `.queue`, pass the string as `initialTerminalInput` beside `initialTerminalCommand`.
- `v2SurfaceCreate` (`SurfaceHandlers.swift:383`), `v2SurfaceSplit` (`:292`), `v2PaneCreate` (`PaneHandlers.swift:176`): same decide. `new-split` is terminal-only (`:329`), so the non-terminal reject is for `tab.create` and `area.create`. On `.queue`, pass `initialInput` into `newTerminalSurface` (`Workspace.swift:8343`), `newTerminalSplit`, and `WorkspaceManager.newSplit` (`:3964`).

`TerminalTab` and `TerminalSurface` gain `initialInput: String?`, stored separately from `initialCommand`. In `createWithCommandAndWorkingDirectory`, nest another `withCString` around `createSurface()` and set `surfaceConfig.initial_input`. Do not set `surfaceConfig.command` from this string. Both pointers must be alive for the `ghostty_surface_new` call. Schedule the headless start when either field is set.

The human and JSON result for a queued input say `initial_input: queued`. They do not say the command finished.

## Files
- `Sources/CreateInitialInput.swift` — new pure helper, compiled into app phase `A5001051` and CLI phase `B9000006A1B2C3D4E5F60719` because both call it. Hand-edit membership using `CLIResolutionSnapshot.swift` as the existing two-target pattern.
- `CLI/c11.swift` — four command arms and their help (`:8900`, `:9010`, `:9137`, `:9238`, short usage near `:17902`).
- `Sources/SocketHandlers/WorkspaceHandlers.swift` — `v2WorkspaceCreate` only.
- `Sources/SocketHandlers/SurfaceHandlers.swift` — `v2SurfaceCreate`, `v2SurfaceSplit`.
- `Sources/SocketHandlers/PaneHandlers.swift` — `v2PaneCreate`.
- `Sources/Workspace.swift` — `init` initial terminal, `newTerminalSurface`, `newTerminalSplit`.
- `Sources/WorkspaceManager.swift` — `addWorkspace`, `newSplit`.
- `Sources/Tabs/TerminalTab.swift` — pass-through.
- `Sources/GhosttyTerminalView.swift` — `initialInput` field, `withCString`, headless start. Not the selection reads at `:5029` (that is C11-282).
- `c11Tests/CreateInitialInputTests.swift` — `c11LogicTests` only, same membership pattern as `SocketTabRefValidatorTests.swift`. Hand-edit the four pbxproj entries. Do not run the xcodeproj gem.
- `tests_v2/test_create_initial_input.py`
- `skills/c11/references/api.md` — the four commands. One line: the text is queued into the new shell, not reported as finished.

No Ghostty commit. No `deliverSocketSendText` edit.

## Acceptance → incident → test → proof
1. Command runs, shell survives. Incident: create-then-send drops. Atlas tagged build, `tests_v2/test_create_initial_input.py`: `new-tab --command 'printf hi-from-create'`, then `read-screen` contains `hi-from-create`. A follow-up `send` of `echo ok` shows `ok`. Same for `new-split down` and `new-area`. One computer-use check on that tab: the text is readable and a prompt is on screen. No soak.
2. Non-terminal. Incident boundary. Same script: `new-tab --type browser --command 'echo no'` and the markdown form exit non-zero, name `--command`, and `tree` shows no new tab. The logic test asserts `.rejectNonTerminal` for those types and `.queue` for terminal and nil type.
3. Slow rc. Incident: the discarded send. On an isolated Atlas test user, launch with a temporary shell startup fixture that prints `rc-start`, deliberately delays, then prints `rc-ready`; do not edit the operator's rc. `new-workspace --command 'printf ws-create'` must yield exactly one `ws-create` execution after `rc-ready`, and a later `echo ok` runs in the same shell. Capture request tracing showing one workspace.create carrying initial_input and no follow-up tab.send_text. Do not replace this proof with source-grep or an ordinary fast shell; do not add a retry that sends the command again.
4. Layout pair. `new-workspace --layout <name> --command 'printf x'` exits non-zero, names both flags, and the workspace count is unchanged. Logic test: `.rejectLayout` when `hasLayout` is true. Server rejects before `v2WorkspaceApply`.
5. Fields stay distinct. `workspace.create` with `initial_command` `printf cmd-not-input` and no `initial_input`: screen shows that output, and a later `echo still-alive` does not run (Ghostty sets `wait-after-command` for `command`). A sibling create with only `initial_input` does run `echo still-alive`. Logic test: `.queue("printf %s \\n")` keeps the backslash and `n` and adds one trailing CR. It never produces an `initial_command` value.

## Hot path, strings, persistence
Surface create only. No keystroke path, no display link, no manual `ghostty_surface_draw`. Compare startup/input latency with C11-270's registered baseline/budgets on paired artifacts; ready/flush is not command completion. The socket worker must not wait for rc. No persistence. Restored sessions do not replay `initial_input`. Consume/clear the startup field after a successful native create so a later runtime reconstruction cannot execute it again; retain it on a failed create until the actual initial start. Check exactly-once execution through a tagged close/reparent/runtime-recovery fixture.

New keys, English only, tokens must survive C11-291:

- `cli.create.command.nonTerminal` — "`--command` is only for a terminal (%@)."
- `cli.create.command.withLayout` — "`--command` cannot be combined with `--layout`."
- `cli.create.command.requiresValue` — "--command requires text"
- `socket.create.initialInput.invalidType` — "initial_input must be a string"
- `socket.create.initialInput.unavailable` — "create.initial_input is unavailable"

The stable human marker is `input=queued`; no unused localized queued label is added.

Server `invalid_params` messages reuse those strings.

## Cut line
No `launch-agent` prompt work (C11-258). No bracketed-paste split. No delivery report that the command finished. No second executor for `--layout`. No change to `initial_command` / `initialTerminalCommand`. No Ghostty patch. After C11-284 merges, enable `create.initial_input` in `Sources/CapabilityFeatures.swift` with this implementation; CLI/server create dispatch use the typed entry. Tagged capabilities must include it while all four real create scenarios pass on the same artifact (audit finding 8). No absent-registry fallback.

## Dependencies and conflicts
- `CLI/c11.swift` arms `:2213-2623` overlap C11-283's `stampWindow` lines on `new-split`, `new-area`, and `new-tab`. Keep this diff to `--command` parsing and the removed `tab.send_text`. Merge current main and preserve the stamp.
- `GhosttyTerminalView.swift` overlaps C11-282 only by file. This PR touches init and surface create (`~2860`, `~3690`). C11-282 touches the selection reads (`~5029`, `~5267`).
- C11-281 documents send and must not put the follow-up send back. This ticket owns the create story.
- C11-291 translates the three keys. No backlog blocker.

## Decisions
None for Atin. Append `\r` only when the queued string does not already end in `\r`. Remote shells keep `initialCommand` as the shell replacement and receive `--command` as `initial_input`.

## Build-mode notes
Branch `c11-1.0/C11-280-initial-input` from current origin/main after predecessor merges; 0ff8887e5e is the citation/intake base, not the later implementation base. One PR. Atlas `c11-logic` for `CreateInitialInputTests`, then the tagged-build script. `C11_QA_LAUNCH` set. Attribute any implementation commit to its actual author/model, not the previous planning owner. Only the Merge Captain syncs installed skills from merged main; the owner never runs sync. Do not merge.

## Codex takeover verification
Historic planning owner: agent:codex-cli; current implementation owner: agent:codex-launch. Verified ticket, stored plan and cited code on intake origin/main 0ff8887e5e965400b01645ef40b85fd0b2605cf2. All behavioral checks above are planned, unperformed. The original planning hold was superseded by explicit BUILD MODE; validation is now executed on Atlas. Branch from current origin/main when this ticket starts, retaining predecessor merges and previous local commits.


## Current build-mode execution
Owner agent:codex-launch took over from the CLI lane on branch c11-1.0/C11-280-initial-input, intake base 2d2440ac65425b0041aad2b3117f6c1c5e612768. Planning hold is superseded by go-owner BUILD MODE. Enable the C11-284 typed registry entry alongside CLI/server admission. Add executable fake-server CLI tests and host-only CreateInitialInputRuntimeTests (c11Tests membership) for isolated slow rc and runtime reconstruction. No owner self-review runs; the Orchestrator routes Astra review. Merge origin/main before tagged runtime proof, preserving the C11-258 Ghostty ABI prerequisite. Use paired tagged Atlas startup measurements instead of the deferred soak. Never sync or modify installed skills; Captain alone syncs merged main.

The final CLI parser removes `--command` and its literal value before inspecting help, routing, type or layout flags; the executable fixture includes flag-looking command bodies. Host slow-rc isolation uses an env launcher to set temporary HOME/ZDOTDIR, because c11 protects its own integration ZDOTDIR from ordinary startup overrides.

## Reset 2026-10-02 by agent:codex-launch
