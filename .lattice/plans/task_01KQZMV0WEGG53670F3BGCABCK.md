# C11-34: Per-workspace resume picker on launch + reliable Enter after resume command

## Problem

c11 has a session-resume mechanism (per-workspace snapshots restored via `snapshot.restore_set` at launch), but the UX is opaque and unsatisfying:

1. **No agency at launch.** If a previous session exists, c11 either restores everything or starts fresh; the operator can't say "bring back the perf branch workspace and the lattice review one, leave the other six alone."

2. **Inconsistent submit after the resume command.** When a workspace is restored, the synthesized resume command (e.g. `claude --dangerously-skip-permissions --resume <id>`) is typed into the new shell with a trailing `\n` (see `Sources/AgentRestartRegistry.swift:148`–`163`). Sometimes the command runs; sometimes it sits at the prompt waiting for the operator to press Enter. The behavior is non-deterministic enough to be annoying.

   Likely root cause: the rest of the codebase uses `\r` (carriage return) as the submit terminator when calling `surface.sendText` — see `TabManager.swift:4492`, `4498`, `4809`, `5026`. The registry diverges by using `\n`. Bash/zsh in canonical mode generally accept either as a line terminator, but the empirical flake plus the cross-codebase mismatch suggests a PTY/race or `ghostty_surface_text` translation gap. Whichever it is, the registry should match the rest of c11: send `\r`, and confirm the byte actually executes.

## Proposed shape

### A. Per-workspace resume picker on launch

If a snapshot set exists from the previous session:

- Detect the snapshot set the same way `snapshot.restore_set` already does.
- Present a non-blocking dialogue (sheet on the first window, or a dedicated "Resume previous session" surface) listing each workspace from the prior set with:
  - Workspace name
  - Surface count + one-line title summary (e.g. "claude (perf/phase4), browser (github), markdown (notes/phase6-research-memo.md)")
  - Time since last activity, if available
  - Per-row toggle
- Footer actions: **Resume selected**, **Resume all**, **Skip all**, **Always resume all** (sets a preference; future launches skip the dialogue).
- Dialogue is dismissable; "Skip all" == not opening it.

Implementation notes:
- Reuse `WorkspaceSnapshotStore` + `snapshot.restore_set`; the picker just decides which workspaces from the set to include before invoking.
- Consider exposing a per-set filter on `snapshot.restore_set` so the picker passes a subset rather than rebuilding the restore loop in the UI layer.
- Setting key: `c11.launch.resumePolicy` ∈ `{ ask, always, never }`. Default `ask`.
- Keyboard: ⏎ confirm selection, ⌘⏎ resume all, ⎋ skip.

### B. Reliable Enter after resume command

- Switch the registry's submit terminator from `"\n"` to `"\r"` so it matches the rest of c11 (`TabManager.swift:4492/4498/4809/5026`).
- Update the docstring in `AgentRestartRegistry.swift:126` ("trailing `\n` is part of the row's output") to reflect the change.
- Add a regression test asserting that all four registry rows end in `\r` and that `pendingInitialInputForTests` for a freshly-spawned restored surface ends in `\r`.
- If `\r` alone is still flaky empirically, fall back belt-and-braces: send `\r`, then on the next runloop tick deliver a synthetic Return via `sendSyntheticKey(characters: "\r", keyCode: 0x24)`. Do this only if the simpler fix doesn't hold.

### C. Tests

- **Unit:** all four `AgentRestartRegistry.phase1` rows end in `\r`. The `cd '<dir>' && claude ...` form keeps `\r` at the very end (after the close of the chained command).
- **Integration:** a fixture snapshot with two workspaces; on `snapshot.restore_set`, the resume command runs in the recorded `project_dir` and the prompt has advanced past the typed line.
- **UI (manual / computer-use):** cold-launch with a known snapshot set, confirm picker appears, choose a subset, confirm only those workspaces resume and each restored Claude/Codex surface lands in its actual prior session (not at a fresh shell prompt with an unsubmitted command).

## Out of scope

- Per-surface resume granularity inside a workspace. Workspace-level is the right primitive for now.
- Snapshot expiry / GC policy. Old sets that the operator declines to resume stay on disk; that's a separate concern.
- Cross-machine sync. Local only.

## Files likely touched

- `Sources/AgentRestartRegistry.swift` — terminator switch + docstring
- `Sources/SessionPersistence.swift` and/or new `LaunchResumePicker.swift` — picker view + decision
- `Sources/AppDelegate.swift` — launch hook that consults the policy and shows the picker
- `Sources/TerminalController.swift` — optional subset filter on `snapshot.restore_set`
- `Sources/WorkspaceSnapshotStore.swift` — read snapshot summaries for the picker
- `Resources/Localizable.xcstrings` — English strings; translator pass for the other six locales after

## Discovered while

Discussing c11 launch UX on 2026-05-06. Operator: "I'm not actually super happy with our resume thing." Concretely: (1) all-or-nothing on launch, (2) Enter sometimes lands and sometimes doesn't after the resume command.
