# C11-300 — Check workspace ownership before close

Inspected base `0ff8887e5e965400b01645ef40b85fd0b2605cf2`. Owner `agent:astra-crashes`. Planning only; no builds/tests run. New branch from refreshed origin/main `c11-1.0/C11-300-close-ownership`, separate PR.

## Verified incident

B019: `Sources/WorkspaceManager.swift:2624` checks only workspace count before clearing probes, sidebar selection, notifications, panels, remote connection and owning manager. Membership is tested at `:2636`, too late. `detachWorkspace:2652` already looks up membership first. Read upstream #8753 `a76deb63e0` locally; its correction is the early ownership guard. Sources: LEDGER B019, session-b verification, Fable C4 and Astra lifetime/ownership audit; no broader close overhaul.

There is already `WorkspaceManagerWorkspaceOwnershipTests.testCloseWorkspaceIgnoresWorkspaceNotOwnedByManager` at `c11Tests/WorkspaceManagerUnitTests.swift:101`, in the host-required target. It checks an external workspace's panels/titles, but does not attach it to a second manager. Extend it; do not duplicate it or infer a passing result from its existence.

The public `workspace.close` handler already looks up the requested workspace inside the explicitly selected manager (`WorkspaceHandlers.swift:335`). A wrong-window socket request alone therefore does NOT exercise the defective direct `closeWorkspace` call. Keep runtime evidence for that API boundary separate from the host test that reproduces the actual bug.

## Minimal implementation

1. `WorkspaceManager.closeWorkspace`: alongside the existing `count > 1` guard, obtain the member index before any breadcrumb, cleanup, notification clearing or teardown. Return immediately if absent. Use the owned workspace at that index for teardown and remove that index, then preserve the existing selected-index fallback. This avoids operating on an unrelated supplied object even if its ID matches a member. No new async work or focus policy.
2. `c11Tests/WorkspaceManagerUnitTests.swift`: strengthen the ownership test with two actual managers, each having at least two workspaces (so the old count guard cannot hide the bug). Close A through manager B; assert both lists and selections unchanged, A's panel object identities/count/titles and owning manager preserved, and a synthetic notification for A remains. Then close A through its owner and assert normal removal/teardown. Add detach→attach→stale-old-manager-close using the same objects, and retain existing confirmation Cancel/Accept tests. Restore shared AppDelegate/notification state in teardown.
3. Add a narrow direct-last-workspace case (method refuses) and keep the confirmation path's existing last-workspace behavior (it can close the window through `finishCloseWorkspace`). The ticket's “last workspace refuses” applies to direct `closeWorkspace`, not the confirmation helper; do not change product behavior to make both identical.
4. Tagged runtime script `tests_v2/test_workspace_close_ownership.py` exercises explicit wrong-window socket close and cross-window move with real terminals. No new production command or debug-only close backdoor just to reproduce the direct call; the existing host test supplies that executable path.

## Acceptance → fixture → proof

| Criterion / incident | Behavioral gate and remote validation host runtime evidence |
|---|---|
| AC1 B019 | Host test directly calls wrong manager with a foreign workspace that has live tab objects, then checks the state above. On remote validation host packaged tagged build, two windows each hold two workspaces; A contains a long-running synthetic heartbeat shell and unsaved variable. Wrong-window socket close returns not_found; tree retains A and terminal UUIDs and its process/variable survive. This runtime check proves the routing boundary, while the direct host test proves the repaired teardown boundary. |
| AC2 valid/last close | Host cases show owner close removes only A, direct close of the owner's final workspace returns unchanged, and accepted/cancelled confirmation follows current behavior. On the tagged app, computer use cancels then accepts the existing workspace confirmation with a synthetic running process; verify affected UUID disappears only after acceptance and unrelated terminals remain live. |
| AC3 cross-window move | Host fixture detaches A from manager 1 and attaches to manager 2; stale close through manager 1 leaves it intact. Packaged build moves A between windows with existing socket move command; before/after tree, same child PID and shell variable prove no teardown. Then legitimate owner close still works. |

Run targeted `c11Tests/WorkspaceManagerWorkspaceOwnershipTests` and impacted confirmation/child-exit classes on remote validation host through C11-216 after BUILD MODE. Run socket script only inside the isolated remote validation host guest; never operator session. Tagged launcher sets `C11_QA_LAUNCH=fresh`; restore is not this ticket's path. UI pass uses a verified guest display, hard timeout and proven dismissal; retain screenshots plus tree/PID artifacts. Tests are proposed, not executed.

## Impact and cut line

One main-actor ownership check and reuse of its index before side effects; no new socket dispatch, background thread, input handling, hitTest, forceRefresh or sidebar-body work. Existing selection fallback remains; compare the small move/close fixture's focus and input-latency observations to C11-270 baseline rather than adding a soak. No localized strings, persistence changes, tenant config, submodule or skill edits.

C11-216 required for tests/runtime. C11-297 may change nearby lifecycle/ref bookkeeping; base this ticket independently on current main when build begins and preserve those updates. No C11-257 send/mailbox edits. Out: B017 shortcuts, B081 tab fallback, B114 Bonsplit focus, B018/B069 window retention, general teardown or close-confirmation redesign.

Open decisions: none. Maximum three review cycles, Orchestrator routes review; Merge Captain merges. Await BUILD MODE.


## Build-mode update (2026-10-01)

Implementation base refreshed to 72cd3882df1fad2a3e2d74a817a18eb1d980b76f. The owner flow now uses the operator's batch validation: C11-300 is low-risk, so numbered Validator steps accompany CI and host-test evidence; runtime/confirmation UI proof is performed on merged main by the batch Validator. C11-216 is build capacity only, and operator workstation locked tagged builds are authorized overnight, though GitHub CI remains the chosen test rail here. No soak or typing-path implementation is added.

The existing foreground-confirmation test assumes addWorkspace leaves the original workspace selected, but addWorkspace selects the new workspace; the exact-base advisory logs already show its precondition and final selection failing. Set its intended foreground selection explicitly before testing confirmation. This corrects the test fixture without changing confirmation behavior. Add the matching-ID/different-instance case to verify close resolves the owned instance per the stored plan. Other implementation and cut-line choices remain unchanged.
