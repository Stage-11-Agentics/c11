# C11-290 plan

Verified on `0ff8887e5e`. The certain doc correction is commit `c2a7f7c876` on `c11-1.0/C11-290-ssh-api` (parent `0ff8887e5e`). Not pushed.

## What the two lines got wrong

`skills/c11/references/api.md:431` said "Tab is not a terminal" means `--tab` without `--workspace`. `Workspace.terminalPanel(for:)` (`Sources/Workspace.swift:6172-6174`) returns nil unless the panel is a `TerminalTab`. The error is `invalid_params` / "Tab is not a terminal" at `Sources/SocketHandlers/SurfaceHandlers.swift:1084-1086` and `:1142-1144`, and `Sources/TerminalController.swift:3251-3252`. A missing workspace is a different error. Leave the addressing section at `api.md:33-42`. Leave the `resize-pane` "tmux-compatible" sentence at `:360`.

`api.md:440` said to install tmux. After #490, `handleCommandLine` (`Sources/Workspace.swift:3118-3129`) answers every post-auth command with `remote_commands_disabled` and "c11 commands are not available over c11 ssh in this version". The interactive shell defines `c11` and `cmux` to print that on stderr and return 1 (`CLI/c11.swift:6386-6395`). `remoteCLIWrapperScript` (`Workspace.swift:4222-4227`) is the same string. `skills/c11/SKILL.md:131-136` already says this. Help at `CLI/c11.swift:8929-8946` describes the workspace and the local proxy and does not mention tmux. Leave help and SKILL.md unless the smoke disproves them.

Commit `c2a7f7c876` rewrites only those two bullets:

- **"Tab is not a terminal"** — that tab is not a terminal (a browser or markdown tab, or a ref that does not name one). `send`, `read-screen`, and the other terminal commands need a terminal tab. Find one with `c11 tree`.
- `c11 ssh <host>` opens a remote shell and a local SSH proxy so browser traffic can egress from that host. Commands inside that shell do not run on the Mac. `c11 ping` there prints "c11 commands are not available over c11 ssh in this version" and does not return `pong`. Use the local CLI. See the SSH section in SKILL.md.

The doc does not claim the Atlas smoke has run.

## Acceptance

1. Shell. Incident: no live `c11 ssh atlas` since #490. Proof, in build mode: an Atlas tagged Debug app via `./scripts/launch-tagged-automation.sh <tag> --qa fresh`. UI driving stays on Atlas. From the local CLI, `c11 ssh atlas`. Do not edit `~/.ssh/config`. In the remote shell, `hostname` and `pwd`. Record hostname. Record pwd only as "remote home, not this Mac"; do not paste the path. Record tag, machine, and UTC. No keys, tokens, or cookie values. Same note on `lattice comment --role validation`.
2. Proxy. A same-machine `api.ipify.org` compare is not the proof. The app and `c11 ssh atlas` share Atlas's egress, so a browser that never uses the local proxy (`Workspace.swift` allocates it on `127.0.0.1`) can show the same address. From the Atlas app, `c11 ssh` to an existing SSH host that is not the machine running the app. Do not edit `~/.ssh/config` and do not provision a new service. On that host, one listener bound to its loopback answers one path. A direct request from Atlas to that URL fails. A browser tab in that ssh workspace loads it. The note quotes the request evidence: the listener's one request line (method and path) and that the tab showed the body only that listener returns. If no distinct host is available, this check stays blocked. Do not record an ipify match as a pass.
3. Refusal. Incident: #490 closed the relay. Inside the `c11 ssh atlas` shell, `c11 ping` prints the refusal, exits non-zero, and does not print `pong`. Do not weaken `tests_v2/test_ssh_remote_cli_relay.py:123-137`, `tests_v2/test_ssh_remote_interactive_cmux_command_regression.py:188`, `tests/test_cli_ssh_shell_bootstrap.py` (message at `:23`), or `c11Tests/WorkspaceRemoteConnectionTests.swift:131` and `:178-189`. They were not re-run in planning mode. CI job `remote-daemon-tests` is the docker run. Do not run Docker on Hyperion.
4. The two bullets above are the api.md correction. No markdown grep test. Read the file on `c2a7f7c876`. If the smoke disproves a sentence, change that sentence in this PR. Do not describe the old relay.
5. The SKILL.md SSH section stays unless the smoke disagrees. Then update it in the same PR.
6. The docker refusal assertions stay. The PR says they were not re-run locally because they need Docker, unless an Atlas slot runs `remote-daemon-tests`.

## If the smoke fails

File the log line. A fix stays in SSH bootstrap (`CLI/c11.swift` `buildInteractiveRemoteShellScript` and the `ssh` dispatch), the local proxy, or the refusal path (`handleCommandLine`, `remoteCLIWrapperScript`). Do not turn the relay back on. A missing daemon, or a refusal that does not match the message, is a product bug. Remote `c11 send` is out of scope.

## Hot path, strings, persistence

None. No keystroke path, no soak, no new `String(localized:)` key. No tenant config and no `~/.ssh/config` edit.

## Cut

The command relay. A tmux recipe for lid-close. The read-only Atlas fleet view. Persist and reattach of remote workspaces. The Go holder, remote CLI verbs, per-tab hosts, `c11 move`, Prime override, federation. R2 / D9 / D10. The addressing section and the resize-pane sentence.

## Dependencies

Depends on C11-216 for an Atlas-built tagged app. The smoke waits for BUILD MODE and that build. The sign-off build depends on this ticket. Do not link a command-channel ticket.

## Decisions

None.

## Skill install

`skills/c11/references/api.md` is part of the installable c11 skill. After this branch merges, run `scripts/sync-installed-skills.sh c11` on the landing machine. Do not sync this unmerged branch into the live skill.

## History lane execution update (base 2d2440ac65425b0041aad2b3117f6c1c5e612768)

Reassigned to agent:codex-history by the Orchestrator after C11-305 handoff. New branch c11-1.0/C11-290-ssh-smoke cherry-picks c2a7f7c876 as 688016659e5eb9ce436c473f2ddb23369921d11a. Exact-head tagged Atlas build passed, invocation 5836bdcb0b02475780ca5762c8aa7989. No native source changed. Installed skill sync belongs solely to the Merge Captain after landing; owner does not sync.

Audit finding10 remains binding: use a distinct remote endpoint with loopback-only listener, prove the matching direct request from Atlas fails, and capture browser body plus listener request evidence. Same-machine egress/IP equality is not proof. Atlas has one verified 1920x1080 virtual display. Its default SSH environment lacks client credentials for c11 ssh atlas. Establish process-scoped credential forwarding using existing keys as needed, without copying private keys or editing tenant SSH configuration. An existing remote Linux VM can supply the distinct loopback listener; create no new VM or persistent service. Every owned launch/listener/forwarding bridge has a hard timer and scoped cleanup.

CI wording correction: remote-daemon-tests now runs Go tests and release-asset guards, not Docker. The SSH CLI bootstrap harness runs in the build job. The Docker SSH refusal/proxy tests remain separate and will be labelled unperformed unless actually run; do not count Go CI as those Docker assertions. No host Docker was found on Atlas. The one-shot tagged runtime smoke, exact refusal output/exit status, and remote-only browser request are the ticket's required proof; no source-grep tests.

## Reset 2026-10-02 by agent:codex-history

## Orchestrator topology override (2026-10-02)

The Orchestrator explicitly authorizes UI on Hyperion tonight. Build on Atlas with remote-build.sh --launch, taking the Hyperion UI slot, and run the returned tagged app here. Then c11 ssh atlas supplies a distinct remote endpoint using existing local SSH credentials. Start the planned timed listener on Atlas bound only to 127.0.0.1; prove a matching direct Hyperion request fails and the browser in the SSH workspace loads its unique body. Record the actual listener request line and rendered page, stop the listener, dismiss the owned tagged app with PID-scoped synthesized input, release the slot, and hand off. No VM or persistent service is needed. This replaces the Atlas-app/distinct-Linux-host topology above; the audit finding 10 proof standard stays the same.
