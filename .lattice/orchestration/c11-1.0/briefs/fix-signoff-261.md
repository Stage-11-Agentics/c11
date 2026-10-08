# Sign-off fix: C11-261 groups runner vs C11-323

Read `luna-owner.md`, `owner-common.md` and `go-owner.md` in this directory (Codex GPT-6-Luna max, fast mode off). Actor `agent:luna-261s`; tab title `Signoff 261 Luna`.

The C11-292 rehearsal ran `scripts/groups-signoff.sh` unchanged on the signoff-1-0 build (main 9c9cf4ba44). It exited in its automated chapter with `workspace_switch_blocked`: since C11-323, no socket caller can change the visible workspace, and the runner selects workspaces over the socket. Evidence: `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-292/build-remote/a56aae33573c4c5baf29f3fbf6d67ffd/rehearsal/host-run/`.

- Worktree from origin/main (`c11-1.0/C11-261-signoff-fix`). Find every place the runner and its helpers (scripts/groups-signoff.sh, scripts/groups-fixture.sh, tests_v2/test_workspace_groups_scale.py) switch the visible workspace through the socket.
- Preferred fix: change the harness so it does not need visible switching. Drive background workspaces directly (allowed by C11-323), and make the visible-selection checks operator steps in the human chapter. Only if a check truly needs a programmatic visible switch, propose a DEBUG-only, test-only seam that is compiled out of Release, and send `DECISION` before building it: C11-323 is a hard block and Atin chose no override.
- Run the fixed runner end to end on Atlas against a tagged build of current main (Atlas host, isolated tag app, socket and session, as the C11-292 ruling allows; clean up after). Record A1-A13 results.
- One PR on C11-261 (tests and scripts only, no product change expected). `HANDOFF C11-261 REVIEW <head> <PR> <run evidence>` to tab:210. 90-minute box.
