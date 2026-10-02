# C11-261 workspace-group sign-off

This is the reproducible g60-v1 validation contract for workspace groups. The
socket driver proves model and persistence facts. It does not prove what a
human can see, where a pointer lands, or which responder owns typing. C1-C6
must be run by a fresh independent reviewer against the same tagged app.

The harness never writes operator approval. H1, H2, and H3 remain blank until
Atin records them separately.

## Preconditions

Run on Atlas with a tagged Debug app built from this checkout. The tag must be
the single ticket tag `c11-261`. The tagged app and CLI are
derived from the tag, and the only accepted socket is:

```text
/tmp/c11-debug-c11-261.sock
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
./scripts/groups-signoff.sh c11-261 \
  --results /tmp/c11-261-signoff-round1 \
  --perf-artifact /absolute/path/to/targeted-comparison.json
```

The harness launches a fresh tagged app, provisions the fixture, executes A1
through A10, saves the post-mutation session, performs A11 through A13 with
QA resume, writes `perf.json`, cleans only the recorded fixture, and quits the
tagged app. `--perf-artifact <path>` imports the completed targeted comparison;
omitting it leaves AC5 unverified. `--skip-restore` is only for a partial run;
it must leave A11-A13 explicitly unverified.

The lower-level commands are useful when debugging a failed chapter:

```bash
./scripts/groups-fixture.sh c11-261 provision
./scripts/groups-fixture.sh c11-261 automated \
  --out /tmp/c11-groups-g60-c11-261/steps.jsonl
./scripts/groups-fixture.sh c11-261 snapshot \
  --state /tmp/c11-groups-g60-c11-261/state.json \
  --out /tmp/c11-groups-g60-c11-261/snapshot.json
./scripts/groups-fixture.sh c11-261 cleanup
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
8. **A8 attention.** The repeatable `attention` command seeds two flags on
   w09/w11, suppresses w11/w12, and creates real exact-tab unread on declared
   synthetic codex tabs w10/w11/w14. Expected: two flags, two unsuppressed waiting
   demands, three signal-eligible unread notices (flagged suppressed w11 remains
   eligible). Routine suppressed unread is excluded exactly like rows. This
   proves notification-driven waiting, not an agent completion hook. C2 verifies
   the native visible projection against these exact notification/tab IDs.
9. **A9 non-destructive removal.** Delete Empty Pinned and ungroup Move Lane.
   Member workspaces and tabs remain alive and their group IDs become null.
10. **A10 batch reorder.** A partial batch reorder must leave the dry run
    unchanged, preserve the pin segment, and produce one real mutation. The
    one-shot driver does not subscribe to the event stream, so event emission
    is recorded unverified rather than inferred from `changed: true`.

Every chapter is a JSONL record with before/after snapshots, assertions,
unverified reasons, elapsed time, and no UI claim.

Every step enforces surviving workspace/tab IDs, tab types, TTYs and available
shell PID sets. Each intermediate move asserts destination membership, relative
placement and unchanged unrelated order/membership. Each close asserts the exact
workspace/tab/PID removal and unchanged survivors. Missing process identity is
UNVERIFIED. Provisioned ownership records are never replaced by what survived.

## Restore chapters

The owner runner saves `post-mutation.json`, quits the tagged app, and resumes
it with QA mode:

11. **A11 clean restart.** `post-resume.json` must preserve group identity,
    group order, names, color/icon, collapse/pin state, workspace order,
    membership, and panel identities. This is a clean-restart proof, not a
    crash-injection proof. The comparator matches windows by persisted
    workspace/group identity and ignores regenerated pane IDs, terminal
    titles, PTYs, and browser rendering flags. `termination.jsonl` records the
    actual exit outcome. TERM/KILL escalation leaves A11 UNVERIFIED and labels
    the semantic comparison forced-restore, even when its contents match.
12. **A12 pre-group snapshot.** Replace the tagged session file with
    `tests_v2/fixtures/pre-group-session.json`, resume, and assert one
    ungrouped workspace with no invented folder. Its workspace/tab IDs, pins,
    custom titles and payload are compared against the supplied fixture. Missing
    and empty group arrays are equivalent representations of no folders.
13. **A13 empty-group snapshot.** Replace it with
    `tests_v2/fixtures/empty-group-session.json`, resume, and assert that the
    exact group UUID/name/color/icon/pin/collapse and workspace/tab identities
    match the supplied fixture, with no invented member.

The canonical session path is derived from the tagged bundle ID:

```text
~/Library/Application Support/c11/session-com.stage11.c11.debug.<tag-id>.json
```

The runner copies only the two checked-in fixtures to that exact tagged path;
it never edits the operator's production session.

## Independent computer-use chapters C1-C6

A7-A13 destroy the original g60 population; the automated runner finishes with
the one-workspace A13 fixture and quits. Before every independent C/performance
chapter, fresh-launch and reprovision. Never reuse the mutated A window:

```bash
scripts/launch-tagged-automation.sh c11-261 --qa fresh --wait-socket 30
scripts/groups-fixture.sh c11-261 provision --out /tmp/c11-261-C-provision.json
scripts/groups-fixture.sh c11-261 attention --out /tmp/c11-261-C-attention.json
scripts/groups-fixture.sh c11-261 snapshot --out /tmp/c11-261-C-before.json
```

If prior state exists, cleanup it on its listening tagged socket and quit before
fresh-launching. The `attention` command resets w09-w14 flags/suppression and
clears the disposable tagged instance's notifications once before seeding.
Expected Collapsed Flag counts are flags=2, waiting=2, eligible unread=3. Read
native activity/AX labels alongside metadata; absent waiting projection is a
failure or unverified seam, never an agent-lifecycle PASS.

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
   verify the header updates without losing attention state. Lower w09: 2→1,
   violet remains because suppressed w11 is flagged. Lower w11: 1→0, violet goes.
   Re-raise w09: 1/violet, then transfer it to Tail: old header loses that flag,
   Tail gains it, Collapsed Flag stays collapsed. Toggle w10 suppression and
   confirm its routine waiting/unread disappears and returns.
3. **C3 pointer drags.** Drag a workspace into a group, between members, out
   to no group, and across the pin boundary. Capture before/after screenshots
   and machine-readable IDs. Also reorder pinned and unpinned headers separately;
   drop w16 on its own header center (expected: append to that folder's matching
   pin segment), drop on Empty Collapsed without expanding it, Escape mid-drag,
   and drop outside sidebar (no mutation). Delete a target group through a second
   tagged socket during drag: stale target cancels, source remains alive and no
   unrelated row moves. Compare highlight with exact order/membership after each.
4. **C4 cancelled drop/context menu.** Begin a drop and dismiss it without a
   target; use the group context menu to exercise delete/ungroup. Prove the
   cancellation caused no mutation and dismiss every menu/modal with
   synthesized input. Menu matrix: Rename, Color, Icon, Pin/Unpin, Ungroup, New
   Group (empty folder, no new workspace), workspace Move to Group; no Close
   Members item. Exercise keyboard/VoiceOver names and exact counts. Drop the
   synthetic fixture file into a terminal and a Bonsplit tab between areas to
   preserve existing drag paths. Select browser w04, then terminal w03; typing
   reaches w03 and its shell PID remains unchanged.
5. **C5 geometry.** Exercise a group with 100 members, including the 99+
   count presentation, row readability, and scrolling. Record the window
   size/display identity and screenshots. First reset/reprovision g60. Run
   `scripts/groups-fixture.sh c11-261 geometry --count 9 --out /tmp/c11-261-C5-9.json`,
   then repeat with counts 10, 99, 100. It extends the owned fixture to exactly
   100 workspaces and records Geometry's UUID. Chevron/icon/name/controls must
   not jump; 100 shows 99+ with exact accessible count. Check narrow/wide sidebar
   and scrolling. Cleanup/quit/fresh-reprovision g60 before C6/performance.
6. **C6 locale.** Capture the group header/count/menu in each shipped locale:
   Japanese, Ukrainian, Korean, Simplified Chinese, Traditional Chinese, and
   Russian. Check truncation, count labels, and accessibility names.

The independent reviewer records `PASS`, `FAIL`, or `UNVERIFIED` per chapter;
no result is inferred from the socket oracle or from a green build.

Explicitly routed C11-260 residuals: the Atlas Validator integration matrix owns
pending-prime creation/mount cap (C11-301: creation ≤2, handoff ≤3, selected always
mounted, queue settles to one), and the real selective-resume picker (keep subset,
omit a window, retain empty folders, no-selection fallback). Record actual UI/log
results with candidate SHA on C11-261/C11-260; unit tests alone do not discharge
these. C1-C4 own the remaining focus, drag, menu, keyboard/VoiceOver, file/Bonsplit
cases above. Route locale failures to C11-291.

After every C chapter run:

```bash
scripts/groups-fixture.sh c11-261 cleanup --out /tmp/c11-261-C-cleanup.json
```

Then synthesize Command-Q to the verified tagged PID, dismiss only its observed
dialog and prove that PID is gone within the 20-minute cap. Forced termination
is cleanup failure evidence, never synthesized-dismissal proof. Production
workspaces/session must be unchanged.

## Performance and handoff

C11-270 ruling ev_01M3XD1J9QC40BV7NAR7C071PT removes the M1 dependency. Measure
a frozen current-main control against the repaired candidate now. Build both via
remote-build with the same tag `c11-261`, retaining each bundle in its role's
evidence directory before the next rebuild overwrites the single tag. Run them
sequentially with equivalent fresh g60 populations, same display/window/settings.
Both current-main and candidate already contain groups.

Once both artifacts exist, request `REQUEST QUIET ATLAS C11-261 <minutes>` at
tab:210 and await the reservation. Hold both real build-slot FDs, record load at
1 Hz and host CPU/RSS processes, require load <8 at each role start and throughout
the admitted pair. Retain contamination as INCOMPLETE; no automatic resampling.
Release slots immediately on completion or failure.

Reuse the C11-260 g60-w2-v1 targeted protocol: observed priming settlement then
60-second warmup; fixed 60-second no-churn, churn and quiescence phases, each
105 typing, 42 switch and 42 real sidebar-scroll probes (valid minimum 100/40/40).
Churn is 600 RPCs at 10 Hz: 150 each reorder, transfer, flag, waiting suppression.
Visible-state templates and distinct negative controls prove key-to-paint/switch/
scroll endpoints; socket ACK is not paint time. Freeze scripts/geometry/budgets
before collection and retain every attempt.

All 18 phase/metric limits: candidate p95 ≤ max(control p95 ×1.20, control p95
+5 ms); candidate p99 ≤ max(control p99 ×1.25, control p99 +15 ms). Nearest-rank
percentiles; 42-sample p99 is the maximum. Publish raw samples/captures, failures,
monotonic timestamps, capture/setup overhead noise percentiles, continuous load,
mutation schedule/results, hang-monitor records (2-second threshold), CPU/RSS/
footprint/available IOSurface and quiescent recovery. Name unavailable instruments.

C11-260 watch-point dispositions: per-header palette read is hoisted to one
read per sidebar evaluation; dead SidebarDropPlanner.indicator/targetIndex and
their tests are removed (live edgeForPointer retained). The global notification
needsAllAttention refresh remains measured here; use a per-workspace dirty set
only if the gate reveals an attributable regression. Report actual measured
disposition in the validation artifact.

The evidence directory must contain `run.json`, `commands.txt`,
`provision-summary.json`, `automation-summary.json`, `steps.jsonl`, restore
save/compare artifacts, `perf.json`, and `cleanup.json`. The final handoff
must name the exact head SHA and PR URL. C1-C6 and H1-H3 remain explicitly
pending until their owners provide evidence.

## Operator block (only Atin fills this)

Build SHA: ______  Bundle/tag: ______  PID/window/display: ______

Evidence directory: ______  Independent C results: ______  Perf result: ______

H1. Confirm the tagged window matches the identity block. Result: ______

H2. Walk C1, C2 and C3 yourself; stop on the first surprise. Result: ______

H3. Run scoped cleanup and quit; confirm production session untouched. Result: ______

Decision: approve / reject: ______  Name: ______  Date: ______
