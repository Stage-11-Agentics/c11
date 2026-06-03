## Critical Code Review
- **Date:** 2026-04-24T18:56:22Z
- **Model:** Codex / GPT-5
- **Branch:** cmux-37/phase-1-snapshots-restore
- **Latest Commit:** 2047daff97f99905bccd0bf74a81fe6b703f8c27
- **Linear Story:** CMUX-37
- **Review Type:** Critical/Adversarial
---

## The Ugly Truth

Phase 1 is structurally clean in the pure seams: `WorkspaceSnapshotConverter` is Foundation-only, the registry is a small value table, the store uses the right current/legacy directories, and the capture path keeps `claude.session_id` on surface metadata while carrying `mailbox.*` as pane metadata.

But the user-facing restore path is not production-ready. The headline feature, "restore with Claude resume", queues `cc --resume <id>` as raw text without submitting it. The tests only assert the pending buffer contains the text, so they bless a terminal sitting at a prompt with a command typed into it instead of an actually resumed agent. There are also CLI-contract bugs around refs, focus semantics, and plain table output.

## What Will Break

1. When `C11_SESSION_RESUME=1 c11 restore <snapshot>` restores a Claude Code terminal, the executor will type `cc --resume <session-id>` but will not press Enter. `TerminalSurface.sendText` writes exactly the bytes it receives (`Sources/GhosttyTerminalView.swift:3534`, `Sources/GhosttyTerminalView.swift:3644`), and `AgentRestartRegistry.phase1` returns a command with no newline (`Sources/AgentRestartRegistry.swift:69`). The restored workspace will not actually resume until a human notices and submits the typed command.

2. `c11 snapshot --workspace workspace:2` is advertised in help but rejected. `runSnapshotCreate` tries to parse the ref locally as a UUID (`CLI/c11.swift:2723`), and `parseUUIDFromRef` only accepts a bare UUID or a `kind:<uuid>` suffix (`CLI/c11.swift:2862`). c11's normal ordinal refs and indexes never reach the socket normalizer.

3. `c11 list-snapshots` likely prints garbage or fails in its non-JSON mode. The table formatter passes Swift `String` values to `%s` C format slots (`CLI/c11.swift:2852`). This code should use `%@` with `NSString`, or avoid `String(format:)` for string columns.

4. `c11 restore --select true` cannot do what the help says. The CLI documents foregrounding the restored workspace (`CLI/c11.swift:8136`), but `snapshot.restore` is absent from `focusIntentV2Methods` (`Sources/TerminalController.swift:130`), so `v2SnapshotRestore` forces `options.select = false` (`Sources/TerminalController.swift:4575`). The flag is accepted and then ignored.

## What's Missing

- A test that proves the registry-synthesized command is executable, not merely present as a substring in `pendingInitialInputForTests`.
- CLI-level coverage for `snapshot --workspace workspace:2`, `snapshot --workspace 2`, and `snapshot --workspace <uuid>`.
- CLI/plain-output coverage for `list-snapshots`.
- A decision test for restore focus semantics: either `snapshot.restore` is a focus-intent command when `--select true`, or the CLI help must stop promising foreground selection.
- No local tests were run, per `CLAUDE.md` and the review prompt.

## The Nits

- `WorkspaceSnapshotCapture.swift` says title capture falls back to live `displayTitle` (`Sources/WorkspaceSnapshotCapture.swift:31`), but the implementation only records `workspace.panelCustomTitles[panelId]` (`Sources/WorkspaceSnapshotCapture.swift:151`). That is probably fine for the stated `setPanelCustomTitle` preservation requirement, but the comment overclaims.
- `WorkspaceSnapshotID.generate` calls the injected clock twice (`Sources/WorkspaceSnapshotCapture.swift:63`, `Sources/WorkspaceSnapshotCapture.swift:64`), so the ULID time prefix and `created_at` can diverge by a tick. Not a production break, just sloppy determinism.

## Blockers

1. ✅ Confirmed — Restore resume does not execute the synthesized command.
   - `AgentRestartRegistry.phase1` returns `"cc --resume \(id)"` with no trailing newline at `Sources/AgentRestartRegistry.swift:69`.
   - The executor passes that string directly to `terminalPanel.sendText(cmd)` at `Sources/WorkspaceLayoutExecutor.swift:225`.
   - `sendText` writes exactly that data or queues exactly that data; it does not append Enter (`Sources/GhosttyTerminalView.swift:3534`, `Sources/GhosttyTerminalView.swift:3644`).
   - The acceptance test only checks `sent.contains(expected)` (`c11Tests/WorkspaceSnapshotRoundTripAcceptanceTests.swift:149`), so it misses the missing submission.

## Important

1. ✅ Confirmed — `snapshot --workspace` rejects normal c11 refs despite documenting them.
   - Help advertises `c11 snapshot --workspace workspace:2` (`CLI/c11.swift:8120`).
   - The parser only accepts UUID-shaped values (`CLI/c11.swift:2723`, `CLI/c11.swift:2862`).
   - This breaks the advertised way to snapshot a non-current workspace.

2. ✅ Confirmed — `restore --select true` is accepted but ignored.
   - `snapshot.restore` is registered as a v2 method (`Sources/TerminalController.swift:2111`) but not as a focus-intent method (`Sources/TerminalController.swift:130`).
   - `v2SnapshotRestore` then clears `options.select` whenever focus is not allowed (`Sources/TerminalController.swift:4575`).
   - The CLI help still claims `--select true|false` foregrounds the restored workspace (`CLI/c11.swift:8136`).

3. ❓ Likely but hard to verify without running the CLI — `list-snapshots` plain table formatting uses the wrong format specifier.
   - The formatter uses `%s` with Swift `String` values at `CLI/c11.swift:2852` and `CLI/c11.swift:2855`.
   - Swift `String(format:)` string interpolation should use `%@`/`NSString` or a Swift-native padding helper. This path has no test coverage.

## Potential

1. ❓ `claude.session_id` is command-adjacent data and is never validated before being embedded in a shell command.
   - The registry trims only whitespace (`Sources/AgentRestartRegistry.swift:65`) and then returns a shell command containing the value (`Sources/AgentRestartRegistry.swift:69`).
   - Today the expected producer is Claude's SessionStart hook, but snapshots and surface metadata are operator-editable. If the blocker above is fixed by appending `\n`, this becomes a real command-injection footgun unless the id is constrained to the Claude session-id grammar or shell-quoted.

2. ⬇️ Capture title fallback comment does not match implementation.
   - Comment promises fallback to `displayTitle`; code captures only `panelCustomTitles`.
   - Lower priority because the requirement was preserving explicit surface names, not default/generated titles.

## Closing

I would not mass deploy this Phase 1 as-is. The data model and most seams are sane, but the resume feature's command is not submitted, and the tests explicitly miss that. Fix the synthesized command execution, add targeted CLI coverage for snapshot refs/list output/restore select, then this becomes a much more credible Phase 1.
