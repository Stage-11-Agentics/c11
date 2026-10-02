# C11-261 plan: 60-workspace group validation and Atin's sign-off script

Planning only. No product code. Implement later on `c11-1.0/C11-261-groups-validation` from the origin/main that contains merged C11-259 and C11-260. Do not implement on `c11-1.0/C11-262-focus-history`. If either groups PR is absent from that main, send BLOCKED and stop.

## What this ticket is

W3. Evidence and a repeatable script for the folder model in the C11-259 plan (`.lattice/plans/task_01M3X3Q706AHNBFJT4AW4F07NE.md`) and the sidebar in the C11-260 plan (`.lattice/plans/task_01M3X3Q72SRQC6X52RE70A9ZFK.md`). Those two plans are the design. This ticket does not reopen them.

C11-270 (F2, `task_01M3X3XPDAV6KFRYRJFP5TTJD4`) owns numeric soak budgets and sampling. Its amended plan publishes milestone M1: registered budgets, the 3 h baseline and the collected g60 control. This ticket consumes M1, not ticket completion or M2's 10 h final-candidate/2.5 h constrained runs. Reference its versioned machine-readable budget artifact at execution time. Do not wait for it now, and do not invent a second budget set. A missing baseline or budget leaves AC5 unverified, not passed. This targeted proof does not replace C11-270's final mixed-fleet soak and does not satisfy C11-270.

Checked on this base (`0ff8887e5e`): `SessionPersistencePolicy.maxWorkspacesPerWindow` is 128 (`SessionPersistence.swift:19`), so 60 workspaces fit. `reorderWorkspace` is `WorkspaceManager.swift:2386-2410`. `WorkspaceSidebar` starts at `ContentView.swift:8393`. Session files are per bundle id (`SessionPersistence.swift:663-686`): production is `session-com.stage11.c11.json`; a tagged app is `session-<its bundle id>.json`. Tagged launch is `scripts/launch-tagged-automation.sh`: socket `/tmp/c11-debug-<tag>.sock`, bundle `com.stage11.c11.debug.<tag>`, `--qa fresh|resume`.

## Deliverables (this branch only)

- `scripts/groups-fixture.sh` — provision and cleanup of fixture `g60-v1`.
- `scripts/groups-signoff.sh` — runs the automated steps, writes a results directory, and refuses to mark Atin's approval.
- `docs/groups-signoff.md` — the numbered script X2 hands Atin. Same step numbers as the driver.
- `scripts/groups-fixture/pre-group-session.json` and `empty-group-session.json` — synthetic v1 snapshots, no real paths or prompts.
- `tests_v2/test_workspace_groups_scale.py` — oracle only, against the tagged socket. Skip with an explicit message if `workspace.group.list` is absent. A skip is not a pass.

No new SwiftUI, no shortcut changes, no skill command. Groups behavior stays in C11-259/260. A product failure is a comment on that ticket with the step id and artifact path. Fix the harness here. Do not patch their files from this branch unless the Orchestrator sends that repair.

## Isolation

The driver takes `--tag` and sets `C11_SOCKET=/tmp/c11-debug-<tag>.sock` itself. It exits before any `c11` call if that socket path is the production socket (`~/Library/Application Support/c11/c11.sock`) or if `C11_SOCKET` was already pointed there. Launch only through `scripts/launch-tagged-automation.sh <tag> --qa fresh` (restore steps use `--qa resume`). Quit with `osascript` on that bundle id, as the launch script does. Never `pkill c11` without the tagged app name. Cleanup deletes `/tmp/c11-groups-g60-<tag>/` and the tagged app's own session file only. It does not delete or overwrite `session-com.stage11.c11.json`.

Manifest `run.json` in the results directory records: fixture version `g60-v1`, host, display id, bundle id, socket path, app path, candidate git SHA, app version, baseline SHA from the C11-270 artifact or `absent`, and the exact command lines.

## Fixture g60-v1

One window, 60 workspaces, 6 folders. Names `g60-w01` … `g60-w60` and the folder names below. No agents except the two waiting tabs in step A8. Terminals stay at an idle shell. Browsers open `about:blank`. Markdown tabs open the synthetic note shipped next to the fixture. Record every workspace UUID, tab UUID, and shell PID after provision.

| Folder | Pin | Collapse | Members |
|---|---|---|---|
| Pinned Fleet | pinned | expanded | w01–w08. w01 and w02 member-pinned. w03 terminal, w04 browser, w05 markdown. |
| Collapsed Flag | unpinned | collapsed | w09–w14. Attention is applied in A8, not at create. |
| Empty Pinned | pinned | expanded | none |
| Empty Collapsed | unpinned | collapsed | none |
| Tail | unpinned | expanded | w15–w24. w15 is the first-member close target. w24 is the last. |
| Move Lane | unpinned | expanded | w25–w28 |

Ungrouped: w29–w60 (32). w29–w32 pinned, the rest unpinned. w33 browser, w34 markdown. Root order must match the C11-259 projection: pinned folders, pinned ungrouped workspaces, unpinned folders, unpinned ungrouped workspaces. Member order inside a folder is canonical workspace order.

Resolve names in this fixture manifest to the UUIDs/current refs returned at provision. The C11-259 contract rejects group display names as selectors: never pass `Move Lane`, `Tail`, or `g60-w35` as a CLI ref. Scenario names below are labels, not literal command arguments.

Commands are the C11-259 contract: `c11 workspace-group create|add|pin|collapse|move`, `c11 new-workspace`, `c11 new-tab`. `add` takes currently ungrouped workspaces only. Create every workspace first, then add.

## Automated steps

Each step snapshots `c11 workspace-group list --json` and `c11 tree --json` before and after. Assert workspace UUID set and shell PID set are unchanged unless the step is a close. Assert no duplicate UUIDs. Assert the flat `windows[].workspaces` array is still the canonical order; the visible root projection is a separate assertion, since the flat array never becomes folder-header order. Results append to `steps.jsonl`.

- A1 Provision g60-v1. Assert 60 workspaces, 6 folders, 2 empty, member counts above.
- A2 Join: move w35 into Move Lane with `move --workspace w35 --to-group Move Lane`. Leave: `move --workspace w35 --to-group none`.
- A3 Intra-group: move w16 before w15 inside Tail. Inter-group: move w16 into Move Lane, then back. Order of everyone else unchanged.
- A4 Drop onto empty and collapsed bodies without expanding them: `move` w36 into Empty Pinned and w37 into Empty Collapsed. Both folders stay at their previous collapse bit. Move them back.
- A5 Pin boundary: move unpinned w38 onto pinned w29 with `--before`. C11-259 clamps inside the pin segment and does not toggle pin. Assert w38 is still unpinned and did not enter the pinned prefix. Repeat a pinned member toward an unpinned slot.
- A6 Cancelled drop is computer-use (C4). The oracle half is a rejected command: `add` of an already-grouped workspace returns `already_grouped` and changes nothing. A second-window target returns `wrong_window` and changes nothing.
- A7 Restore w16 to its original Tail position after A3, and assert w15/w24 are the first/last live members before closing. Close w15 (first Tail member) with the existing close-workspace command. Tail remains, UUID and name unchanged, w16–w24 still members and no survivor loses its original tabs or shell PID. Record the complete original w15 tab/PID set: closing that workspace removes exactly that set, not a single assumed shell if a fixture has extra tabs. Close w24 (last). Then close until Tail is empty: the folder remains. Do not reopen those workspaces. Later A steps do not need Tail rebuilt. The computer-use chapter does not use a rebuilt Tail; it restores g60-v1. Closing must not delete the folder or promote an anchor.
- A8 Attention on Collapsed Flag, folder stays collapsed. w09: `c11 raise-flag` on a plain terminal. w10: `c11 launch-agent` a one-line synthetic prompt that finishes, so the tab reaches `.waiting`, not suppressed. w11: same, then `c11 suppress` and `c11 raise-flag`. w12: plain suppressed terminal with no notification; it contributes no waiting demand. w13: use the workspace-scoped notification socket path that actually omits a tab target; verify the stored/oracle notification has null tab identity (the CLI may otherwise inherit the calling tab). w14: `c11 notify` explicitly targeted at the fixture tab. Snapshot exact notification IDs/counts before each add. There is no debug "set waiting" method on `0ff8887e5e`. Do not add one. If W2 lands a seam, use it instead of `launch-agent` and record which. If `.waiting` is not observable within 60 s, mark A8 waiting-counts unverified and stop retrying. Oracle: flagged count includes w09 and w11; unsuppressed waiting includes w10 and any other tab whose existing resolved activity is actually `.waiting`. In particular an exact-tab unread notification on w14 can itself yield `.waiting` (`TabLivenessDeriver.swift:13`); do not assert w10 is the only waiting tab. Suppressed w11 is excluded from waiting and included in flags. Unread counts include the agents' completion notifications as well as exactly one new notification each for w13/w14; derive expected counts from notification IDs and resolved activities, rather than fixing unread at two. C11-259's list contract has no attention-count fields: use the shared C11-260 summary projection via an agreed read-only tagged oracle/test seam, or the existing per-tab/notification socket snapshot. Record the seam and compare the screenshot to independently computed counts; do not assume `workspace-group list` grew undeclared fields.
- A9 `delete` Empty Pinned. Members were already zero. `ungroup` Move Lane: w25–w28 stay alive, ungrouped, PIDs unchanged, folder id gone. `delete` and `ungroup` are the same non-destructive operation in the C11-259 plan.
- A10 `reorder-workspaces --order` a partial list. Assert the C11-259 pin-segment rule and that group membership did not change. `--dry-run` emits no `workspace.reordered` event; a real change emits one.

## Restore

- A11 `c11 state save`, quit the tagged app, `launch-tagged-automation.sh <tag> --qa resume`. Compare group UUIDs, names, colors, icons, collapse, pin, member UUID lists, and workspace order to the pre-quit snapshot. Label the results file `clean-restart`. This is not crash proof.
- A12 Copy `pre-group-session.json` (version 1, workspaces, no `workspaceGroups` key) onto the tagged app's session path only, launch `--qa resume`. Workspaces restore ungrouped. No folder is invented. Then quit.
- A13 Repeat with `empty-group-session.json`: one empty folder and one workspace. The empty folder is still there after resume.
- Do not run a crash injection. If someone later runs one, label that file `crash` and do not cite it as A11.

## Chapters

A1–A13 are one chapter. A1 provisions g60-v1. A7–A9 close members and delete or ungroup folders, and A11 resumes that post-mutation session. Do not restore in the middle of A1–A13.

Before each later independent chapter, restore g60-v1 and append that restore to `steps.jsonl` (the command, then 60 workspaces and 6 folders). The computer-use chapter and the performance chapter each restore. Create does not apply attention, so the computer-use chapter re-applies the A8 attention setup on the restored fixture and records those socket counts before C2. Do not reuse Tail, Move Lane, or Empty Pinned from the destroyed A chapter.

## Computer-use steps

Fresh-context reviewer, routed by the Orchestrator. Brief names the tagged bundle id, the socket, the step ids, and the success checks below. Enumerate screens and name the display. Hard stop at 20 minutes. Prove dismissal by synthesized quit and a gone process. `c11 tree --no-layout` before success; if the sidebar is too narrow to read a header, widen it and write that down. Screenshots crop to the tagged window. Synthetic titles only.

- C1 Chevron on Pinned Fleet collapses and expands. The selected terminal stays mounted and accepts one typed character. Screenshot plus PID unchanged.
- C2 Collapsed Flag while collapsed: violet flag treatment is visible on the header; screenshot. Counts on screen match this chapter's attention setup, not the destroyed A run. Clear w09's flag: count drops 2→1 and violet remains because w11 is still flagged and suppressed. Clear w11's flag: count drops 1→0 and violet disappears. Re-raise w09 alone and confirm count 1/violet before transfer. Only then transfer w09 into Tail. Collapsed Flag's flagged count drops and Tail's rises without expanding Collapsed Flag.
- C3 Pointer drags, not CLI: join w39 onto Move Lane (header center), leave it via the ungrouped lane, reorder Tail by member edge, reorder two unpinned folders by header drag, drop onto Empty Collapsed (stays collapsed), Escape mid-drag (no change), drop outside the sidebar (no change). After each, socket order matches the highlight the reviewer saw.
- C4 Context menu on one folder: Rename, Color, Icon, Pin, Unpin, Ungroup. Only that folder changes. New Group from the sidebar menu creates an empty folder and does not create a workspace. Move to Group from a workspace menu matches a drag. No Close Members item exists.
- C5 Independent geometry subchapter on the same tagged app: restore g60-v1, then use a synthetic 100-workspace fixture (within the 128-workspace cap) for a single folder at 9, 10, 99 and 100 members. Record its fixture identity separately; it is not the g60 performance population. Chevron/icon/name stay fixed and 100 renders 99+ with exact accessible count. One screenshot each, then cleanup and restore g60-v1 before C6/performance.
- C6 Header screenshot in ja, uk, ko, zh-Hans, zh-Hant, and ru. One collapsed header each, not six full drag passes. A missing `%lld`, a clipped badge, or a raw key goes back to C11-260 / C11-291. It does not fail this ticket's drag steps and it is not fixed here.

## Performance (AC5)

Paired comparison, same Atlas host as the C11-270 baseline, same recorded display, window size, and theme.

- Baseline app: the C11-270 baseline SHA, 60 workspaces, same tab types and pins, no group UI.
- Candidate: merged groups build, fixture g60-v1, restored or provisioned at the start of this chapter. Do not measure the mutated A or C window.
- Phases, already fixed by the W1/W2 plans: no-churn sample; 10 group or reorder mutations per second for 60 seconds (baseline uses workspace reorder only, so the action is the same rate of order changes); quiescence. Candidate also records one pointer-drag burst. That burst is descriptive. It is a paired budget only if C11-270 registers one.
- Read sample length, repetitions, typing-latency budget, switch-latency budget, hang rule, and memory/IOSurface rule from the C11-270 plan and its published baseline artifact. Hang evidence uses `MainThreadHangMonitor` (2 s default at `Sources/MainThreadHangMonitor.swift:248`, 32 MiB log cap at `:375`). Do not add a sampler on the keystroke path. Do not add sidebar counters here; if W2's DEBUG counters exist, copy them into the results.
- Publish raw samples and the summary under `/tmp/c11-groups-g60-<tag>/perf/`. Attach that directory to this ticket. If the baseline SHA, the budget numbers, or a phase sample is missing, write `ac5: unverified` and the missing name. Do not convert that into a pass.

## Sign-off script

`docs/groups-signoff.md` is the human document. It lists A1–A13 and C1–C6 with the expected visible result in one line each, the build-identity blanks, the cleanup commands, and a hard rule: the driver never writes "approved". Atin's block is:

```
H1. Confirm the tagged window is the one named in the identity block.
H2. Walk C1, C2, and C3 yourself. Stop on the first surprise.
H3. Quit with the cleanup command. Confirm the production c11 session is untouched.
Decision: approve / reject. Name: . Date: .
```

Those three lines stay blank in every artifact this seat uploads. X2 includes this file. It does not infer approval from a green driver.

Visible QA runs follow the computer-use constraints: verified display, 20-minute timer, synthesized dismissal, `tree --no-layout`. Builds use the Atlas path and `scripts/with-build-lock.sh`. `C11_QA_LAUNCH` is set by the launch script. tests_v2 runs in the sandbox guest against the tagged socket, never the operator's c11.

## Acceptance

| AC | Incident / question | Proof |
|---|---|---|
| 1 | A 50-workspace run must not touch the operator's session. | Driver refusal test against the production socket path (logic/script test, no app). One Atlas provision writes `run.json` with tag, SHAs, fixture version, and commands. Cleanup leaves `session-com.stage11.c11.json` mtime unchanged. |
| 2 | cmux anchor bugs (#5253 and the named follow-ups) dropped or duplicated members and promoted anchors. Folder model must not. | A2–A7 and C3. UUID and PID assertions. Screenshots of the drag highlight and the post-state. |
| 3 | A flag inside a collapsed folder is hidden if the header only sums visible rows. Suppressed waiting must not inflate the count. | A8 oracle plus C2 screenshot. Unverified waiting is reported as unverified. |
| 4 | Old snapshots have no group key (`SessionPersistence` version stays 1). | A11 clean-restart, A12 pre-group, A13 empty group. Files labeled `clean-restart`. No crash claim. |
| 5 | Group headers and churn can regress typing. F2 asked for a measured comparison, not a feeling. | Perf section. Pass only against C11-270's registered budgets. Otherwise unverified. |
| 6 | Automation can look done while the sidebar is unreadable, and a script can rubber-stamp the operator. | C1–C6 by a fresh reviewer. `docs/groups-signoff.md` with H1–H3 blank. This seat does not fill them. |

## Hot path

No edits to `hitTest`, `WorkspaceRowView`, or `forceRefresh`. The churn loop is socket reorder at 10 Hz for 60 s, off the keystroke path. Typing samples come from C11-270's method. `dlog` stays out of this branch.

## Cut

Implementing folders, drag, or attention (C11-259, C11-260). A second fleet harness, the final mixed-fleet soak, the 16 GB run, sidebar rewrite, GPU reclaim, hang fixes, auto-filing, account restore, stable tab numbers, focus history, release. Six full drag passes. Crash-resume proof. Editing tenant config. Filling in Atin's signature.

## Dependencies

Merged C11-259 and C11-260 before this branch's first product-adjacent run. C11-216 for Atlas builds and the tagged app. C11-270 milestone M1 for the published baseline, g60 control and registered numbers. Do not wait for M2 or for C11-270 to become done; reserve measurements without concurrent Atlas builds/UI drivers. C11-291 for locale rendering defects found in C6. X2 consumes `docs/groups-signoff.md`. Three review cycles, then Atin. No merge and no release from this seat.

Open human decisions: none.

## Codex takeover verification

Audit findings 4/11 verified against the amended groups/soak plans and clean base `0ff8887e5e965400b01645ef40b85fd0b2605cf2`. Independent chapter restore/re-raise repairs were already present; corrected the remaining two-flag assertion, actual group selectors/list contract, unread/waiting oracle, destructive-step ordering and 99+ fixture population. M1 gates comparative proof; locale chapter finishes after C11-291 on the integrated candidate. No new human decision; no builds/tests/product edits.
