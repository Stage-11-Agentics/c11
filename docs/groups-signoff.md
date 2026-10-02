# C11-261 workspace-group sign-off

This is the reproducible g60-v1 validation contract for workspace groups. The
socket driver proves model and persistence facts. It does not prove what a
human can see, where a pointer lands, or which responder owns typing. C1-C6
must be run by a fresh independent reviewer against the same tagged app.

The harness never writes operator approval. H1, H2, and H3 remain blank until
Atin records them separately.

## Preconditions

Run on Atlas with a tagged Debug app built from this checkout. The tag must be
unique to this run, for example `c11-261-groups`. The tagged app and CLI are
derived from the tag, and the only accepted socket is:

```text
/tmp/c11-debug-c11-261-groups.sock
```

Do not point the harness at `~/Library/Application Support/c11/c11.sock`.
The launch path suppresses both startup dialogs with `--qa fresh` or
`--qa resume`. Record these identity fields before interpreting a result:

```text
source checkout and HEAD
origin/main
Atlas hostname
tagged app path and CLI SHA-256
tagged socket path
display identity from system_profiler SPDisplaysDataType
```

The sign-off runner writes those values to `run.json` and writes every exact
command to `commands.txt`.

## Automated socket chapters

Run the complete owner harness:

```bash
./scripts/groups-signoff.sh c11-261-groups \
  --results /tmp/c11-groups-signoff-c11-261-groups
```

The harness launches a fresh tagged app, provisions the fixture, executes A1
through A10, saves the post-mutation session, performs A11 through A13 with
QA resume, writes `perf.json`, cleans only the recorded fixture, and quits the
tagged app. `--baseline-artifact <path>` records the C11-270 baseline identity,
but AC5 remains unverified unless the registered C11-270 harness supplies the
paired same-host/display samples. `--skip-restore` is only for a partial run;
it must leave A11-A13 explicitly unverified.

The lower-level commands are useful when debugging a failed chapter:

```bash
./scripts/groups-fixture.sh c11-261-groups provision
./scripts/groups-fixture.sh c11-261-groups automated \
  --out /tmp/c11-groups-g60-c11-261-groups/steps.jsonl
./scripts/groups-fixture.sh c11-261-groups snapshot \
  --state /tmp/c11-groups-g60-c11-261-groups/state.json \
  --out /tmp/c11-groups-g60-c11-261-groups/snapshot.json
./scripts/groups-fixture.sh c11-261-groups cleanup
```

`tests_v2/test_workspace_groups_scale.py` is the executable oracle behind the
wrapper. It exits 77 with `SKIP` when the candidate does not expose
`workspace.group.list`; a skip is not a pass.

### Fixture contract

`g60-v1` creates one window and exactly 60 workspaces named `g60-w01` through
`g60-w60`, six groups, and two empty groups. The groups are:

1. `Pinned Fleet`: pinned, expanded, `w01`-`w08`; `w01` and `w02` are pinned
   members. `w03` is terminal, `w04` browser `about:blank`, and `w05`
   markdown.
2. `Collapsed Flag`: unpinned, collapsed, `w09`-`w14`.
3. `Empty Pinned`: pinned, expanded, empty.
4. `Empty Collapsed`: unpinned, collapsed, empty.
5. `Tail`: unpinned, expanded, `w15`-`w24`.
6. `Move Lane`: unpinned, expanded, `w25`-`w28`.

`w29`-`w60` are ungrouped. `w29`-`w32` are pinned; `w33` is browser
`about:blank`; `w34` is markdown. All remaining tabs are idle terminals. The
fixture records every workspace UUID, tab UUID, TTY, and discoverable shell
PID. A missing TTY is reported as unverified identity evidence, never filled
with a made-up PID.

The group projection is checked as pinned groups, pinned ungrouped workspaces,
unpinned groups, and ungrouped workspaces. Member order is read from the live
workspace order, not reconstructed from group display names.

### A1-A10 result meanings

1. **A1 provision and baseline.** Assert 60 workspaces, six groups, two empty
   groups, mixed tab kinds, IDs, group membership, pin state, collapse state,
   and canonical member order.
2. **A2 transfer.** Move `w35` into Move Lane and back to no group. Its UUID
   and tab identity must survive.
3. **A3 relative reorder.** Move `w16` before `w15`, transfer it through Move
   Lane, then restore it to Tail before `w17`.
4. **A4 collapsed empty targets.** Move `w36` to Empty Pinned and `w37` to
   Empty Collapsed without expanding the latter, then return both.
5. **A5 pin boundaries.** Drop unpinned `w38` toward pinned `w29`, then pinned
   `w01` toward the unpinned segment and back. Pin state must not toggle.
6. **A6 cancelled-drop oracle.** Adding an already grouped member must return
   `already_grouped`; adding a workspace from a second window must return
   `wrong_window`; both must leave IDs and order unchanged. The pointer-level
   cancellation gesture is C4.
7. **A7 tail deletion.** Close `w15` and `w24`, then the other Tail members.
   Tail remains as an empty group; closed UUIDs and tab identities do not
   reappear.
8. **A8 attention.** On collapsed `Collapsed Flag`, raise a plain flag for
   `w09`, attempt a real `agent.launch` waiting probe for `w10`, suppress then
   flag a real `w11` probe, suppress plain `w12`, create a workspace-scoped
   notice for `w13`, and create an exact-tab notice for `w14`. Waiting and
   unread counts are derived from live tab/notification IDs. If the native
   waiting state is not observable within 60 seconds, the chapter records
   `waiting-unverified` and stops retrying. A workspace-scoped notification
   that resolves to a focused tab is also explicitly unverified for null-tab
   aggregation.
9. **A9 non-destructive removal.** Delete Empty Pinned and ungroup Move Lane.
   Member workspaces and tabs remain alive and their group IDs become null.
10. **A10 batch reorder.** A partial batch reorder must leave the dry run
    unchanged, preserve the pin segment, and produce one real mutation. The
    one-shot driver does not subscribe to the event stream, so event emission
    is recorded unverified rather than inferred from `changed: true`.

Every chapter is a JSONL record with before/after snapshots, assertions,
unverified reasons, elapsed time, and no UI claim.

## Restore chapters

The owner runner saves `post-mutation.json`, quits the tagged app, and resumes
it with QA mode:

11. **A11 clean restart.** `post-resume.json` must preserve group identity,
    group order, names, color/icon, collapse/pin state, workspace order,
    membership, and panel identities. This is a clean-restart proof, not a
    crash-injection proof. The comparator matches windows by persisted
    workspace/group identity and ignores regenerated pane IDs, terminal
    titles, PTYs, and browser rendering flags.
12. **A12 pre-group snapshot.** Replace the tagged session file with
    `tests_v2/fixtures/pre-group-session.json`, resume, and assert one
    ungrouped workspace with no `workspaceGroups` and no invented folder.
13. **A13 empty-group snapshot.** Replace it with
    `tests_v2/fixtures/empty-group-session.json`, resume, and assert that the
    pinned collapsed empty folder remains alongside its control workspace.

The canonical session path is derived from the tagged bundle ID:

```text
~/Library/Application Support/c11/session-com.stage11.c11.debug.<tag-id>.json
```

The runner copies only the two checked-in fixtures to that exact tagged path;
it never edits the operator's production session.

## Independent computer-use chapters C1-C6

Use a fresh reviewer and the exact tagged app on Atlas. Enumerate displays
first instead of assuming a display index. Set a hard 20-minute timer, prove
synthetic dismissal before handoff, and capture screenshots plus a short
scenario artifact. Inspect `c11 tree --no-layout` before calling the run good;
rebalance areas if the target interaction is unreadable. The socket is setup
and oracle infrastructure, not a substitute for these UI steps.

1. **C1 collapse/expand and typing.** With a selected terminal inside a group,
   collapse and expand its header while preserving selection, then type into
   the terminal. Capture the visible selected row and a read-screen receipt.
2. **C2 attention projection.** On the collapsed Flag group, verify hidden
   violet/flag and waiting/unread counts, then transfer a flagged member and
   verify the header updates without losing attention state.
3. **C3 pointer drags.** Drag a workspace into a group, between members, out
   to no group, and across the pin boundary. Capture before/after screenshots
   and machine-readable IDs.
4. **C4 cancelled drop/context menu.** Begin a drop and dismiss it without a
   target; use the group context menu to exercise delete/ungroup. Prove the
   cancellation caused no mutation and dismiss every menu/modal with
   synthesized input.
5. **C5 geometry.** Exercise a group with 100 members, including the 99+
   count presentation, row readability, and scrolling. Record the window
   size/display identity and screenshots.
6. **C6 locale.** Capture the group header/count/menu in each shipped locale:
   Japanese, Ukrainian, Korean, Simplified Chinese, Traditional Chinese, and
   Russian. Check truncation, count labels, and accessibility names.

The independent reviewer records `PASS`, `FAIL`, or `UNVERIFIED` per chapter;
no result is inferred from the socket oracle or from a green build.

## Performance and handoff

AC5 consumes the registered C11-270 M1 budget and baseline. Run paired g60
baseline/candidate samples on the same Atlas host and display through that
harness. If the budget, baseline, or samples are absent, write
`perf.json.status = unverified`; do not invent numbers or create a second
sampler in this ticket.

The evidence directory must contain `run.json`, `commands.txt`,
`provision-summary.json`, `automation-summary.json`, `steps.jsonl`, restore
save/compare artifacts, `perf.json`, and `cleanup.json`. The final handoff
must name the exact head SHA and PR URL. C1-C6 and H1-H3 remain explicitly
pending until their owners provide evidence.
