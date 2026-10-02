# C11-285: Add c11 rpc as a local raw socket call

## Release
P2. This ships in its own PR and never holds 1.0. If it slips, the release ships without `c11 rpc`. No other ticket calls it. Skills and tests that already have a command keep using that command.

It is independent of C11-286. That ticket is AppKit frame math. This one is a CLI verb in front of `sendV2`. No shared hunk. It does not edit the ssh refusal, the global `--window` prelude (C11-283), send delivery (C11-281), or `tab.input_sent` (C11-257). C11-284 lands first. If this P2 ticket is admitted, add/enable cli.rpc in Sources/CapabilityFeatures.swift with the CLI implementation and use the same typed entry at rpc dispatch. Tagged capabilities and real rpc scenarios must agree on that artifact; if this P2 ticket is cut, neither command nor flag is advertised (audit finding 8).

## Incident
Skills and tests hand-roll a socket call because no command sends one raw method. That breaks when the framing or the socket path changes. Backlog C7. Base `0ff8887e5e`.

## What is already true
There is no `rpc` command. `case "rpc"` is absent from `CLI/c11.swift`. `capabilities` is the shape to copy: connect, then `client.sendV2(method:)` (`:1961-1963`). `sendV2` (`:1362-1376`) builds one v2 object and, on a server error, throws `CLIError` whose message is `"\(code): \(message)"` (`:1459-1478`). `CMUXTermMain` prints that on stderr and exits 1 (`:18135-18137`). `system.ping` returns `pong: true` (`SystemHandlers.swift:15-24`).

A missing app fails at `client.connect()` (`:1922-1938`) before the switch. That is the connection error.

Remote c11 is already closed, and this PR does not reopen it.

- The interactive ssh shell writes a stub `c11` that prints `c11 commands are not available over c11 ssh in this version` and exits 1, for every argument (`CLI/c11.swift:6386-6394` and the bin stub at `:6431-6434`).
- After a relay handshake, `handleCommandLine` refuses every line with `remote_commands_disabled` and that same message (`Sources/Workspace.swift:3118-3129`). It does not read the line. `WorkspaceRemoteCLIRelayServer.start()` throws the same message (`:3207-3210`).
- `c11Tests/WorkspaceRemoteConnectionTests.swift` already asserts both (`:129-131`, `:135-189`, the post-handshake line is `ping`).
- `tests_v2/test_ssh_remote_cli_relay.py:123-137` runs the remote stub as `c11 ping` and `cmux ping`. The notes that say this file already tests `rpc system.capabilities` are stale. It does not.

On the intake base the global --window prelude (CLI/c11.swift:1950-1954) focuses only when --window appears before the verb; C11-283 removes it before this ticket in the binding queue. `rpc` does not read `windowId` and does not call `window.focus`. Do not edit the prelude. C11-283 owns that deletion.

## Change
Parse/validate method and JSON in the existing pre-connect early-dispatch region, then add case rpc beside capabilities for the validated socket call. This makes malformed payloads usage errors even with no app running, without affecting valid rpc connection errors. The normal sendV2 compatibility discovery may precede the first named request; request tracing distinguishes that probe from the actual method. No source-grep test or claim of exactly one wire frame on a cold client.

`RpcCommand.parse(_ args: [String]) throws -> (method: String, params: [String: Any])` in `Sources/RpcCommand.swift` (Foundation only).

- One method token, non-empty, no whitespace. A missing method is a usage error.
- No JSON means params `[:]`.
- A JSON argument must be one object. `[]`, a string, a number, and a second positional are errors. The error names the bad token. Do not call `sendV2`.
- Do not run `unescapeSendText`. The object is the params the caller wrote.
- Do not check the method against `system.capabilities`. An unknown method is the server's `method_not_found`, passed through `sendV2`.
- Do not special-case `tab.send_text`, focus, or ssh.

Print the result with the same `jsonString` helper `capabilities` uses. Pretty or not, it is the result object, not a sentence. `--json` and the default both print that object. `pong` stays `true` alongside `is_terminating_app`. Do not strip fields.

Help at `subcommandUsage` (`:8495`) and one usage line next to `capabilities` (`:17890`).

## Files
- `Sources/RpcCommand.swift`. One `PBXFileReference`. Two `PBXBuildFile` rows, same pattern as `CLIResolutionSnapshot.swift`: app phase `A5001051` and CLI phase `B9000006`. Hand-edit `project.pbxproj`. Do not use the xcodeproj gem.
- Sources/CapabilityFeatures.swift — enabled cli.rpc entry used by CLI dispatch.
- `CLI/c11.swift` — the `rpc` arm, help, usage. Not `:1950-1954`. Not `:6386-6434`.
- `c11Tests/RpcCommandTests.swift` in c11LogicTests phase `37DDE3B0A6A70E75A7B2BEDF`. Hand-edit.
- `tests_v2/test_cli_rpc.py`.
- `tests_v2/test_ssh_remote_cli_relay.py` — one more stub invocation, `c11 rpc system.ping`, inside `_assert_remote_commands_unavailable`. The expected stderr is the existing sentence. Do not change the stub.
- `skills/c11/references/api.md` — a short "Raw method" note in Troubleshooting (around `:427`), not in the send-key vocabulary (`:288`, C11-308) and not in the ordinal paragraph (`:31`, C11-309).
- One bullet in `skills/c11/SKILL.md` beside the send rules (`:157-161`), its own line, so C11-281's sentence is untouched.

No edit to `Workspace.swift`, `SystemHandlers.swift`, `focusIntentV2Methods`, or `SocketDispatch.swift`.

## Tests
`RpcCommand.parse`, incident named (a hand-rolled `nc` call breaks when framing changes):

- `["system.ping"]` is method `system.ping` and empty params.
- `["system.ping", "{\"text\":\"hello\"}"]` returns that object.
- `["system.ping", "[]"]` throws, and the message says the payload must be a JSON object.
- `["system.ping", "{}", "extra"]` throws.
- `[]` throws.

No socket in the logic test. No source-grep test.

## Acceptance
1. Tagged build, Atlas sandbox, not the operator's c11. `c11 rpc system.ping` prints JSON with `pong: true`. `window.list` before and after shows the same `key: true` window. The command did not pass `--window`.
2. `c11 rpc tab.send_text '{"text":"hello","tab_id":"<uuid>"}'` lands in that tab. `read-screen` shows `hello`. A following `c11 send` of the same word still works. The rpc path did not unescape.
3. `c11 rpc no.such.method` exits non-zero and stderr contains `method_not_found`. `c11 rpc system.ping '[]'` exits non-zero, stderr names the payload, and the trace has no `no.such` or second `system.ping` request. A missing app is the existing connection error, before any method is sent.
4. From a `c11 ssh` remote shell, `c11 rpc system.ping` fails with `c11 commands are not available over c11 ssh in this version` and does not run `system.ping` on the Mac. The docker test's new invocation shows that. The handshake test still refuses an arbitrary line. This PR did not edit `handleCommandLine`.

## Skill
The api.md note says `c11 rpc <method> [json]` is a local escape hatch for a socket method that has no command. Prefer the command when one exists. It does nothing over `c11 ssh`. The SKILL.md bullet says the same in one line. Do not teach `rpc` as the way to send text, focus, or resize.

The c11 skill is installable (`skills/MANIFEST.json`). After the edit, on the landing machine, `scripts/sync-installed-skills.sh c11`. Planning mode does not run it. The reviewer reads the repo file and `~/.claude/skills/c11/references/api.md`, and checks that `.c11-skill.json` is still present.

## Hot path
None. One socket request per invocation. No `hitTest`, no `forceRefresh`, no display link.

## Strings
English only. C11-291 translates. No interpolation token in the payload error.

- `cli.rpc.usage` = "rpc requires a method name and an optional JSON object."
- `cli.rpc.payload` = "rpc payload must be a JSON object."

Help stays in the existing raw help strings.

## Cut
No `resize-window`. No `c11 guide`. No feature-flag type created here. No remote relay, no ssh allowlist, no forwarded rpc. No parameter schemas. No focus and no `NSApp.activate`. No tenant config. No soak.

## Dependencies
C11-284 must merge first. This optional feature never gates the P1 queue or release; feature registry/source dispatch changes ship together. C11-286 is a different PR. Shared skill files are one bullet and one troubleshooting note.

## Branch
Build mode, from `origin/main`: `c11-1.0/C11-285-rpc`.

## Decisions
None.

## Codex takeover verification
Owner: agent:codex-cli. Verified ticket, stored plan and cited code on intake origin/main 0ff8887e5e965400b01645ef40b85fd0b2605cf2. All behavioral checks above are planned, unperformed. Planning hold remains: no builds, tests, product-code commits or pushes until explicit BUILD MODE. Branch from current origin/main when this ticket starts, retaining predecessor merges and previous local commits.

## Build-mode takeover (agent:codex-launch)

Assigned by the Orchestrator after C11-280 handoff. Implementation base is fetched origin/main 7edd59b882df9a6c5eda80566d34514acdd1b332. Retain the stored cut line. The C11-284 registry is present; cli.rpc is added and enabled with its typed dispatch. No installed-skill sync: go-owner.md now reserves that action for the Merge Captain from merged main. No owner self-review. Low-risk runtime acceptance is handed to the Atlas batch Validator, with numbered steps in the validation comment; targeted executable CLI and pure-logic checks run before handoff. Two localized error keys remain cli.rpc.usage and cli.rpc.payload. rpc accepts global or subcommand --json; payloads are never unescaped or ID-formatted. The shared --window prelude is still on this base and belongs to C11-283, so it is not edited here. Acceptance uses no --window flag. This P2 branch pauses at a clean commit immediately on C11-273 MERGED.
