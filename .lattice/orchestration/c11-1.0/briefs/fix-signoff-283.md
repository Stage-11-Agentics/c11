# Sign-off fix: C11-283 focus-window

Read `luna-owner.md`, `owner-common.md` and `go-owner.md` in this directory (Codex GPT-6-Luna max, fast mode off). Actor `agent:luna-283s`; tab title `Signoff 283 Luna`.

The C11-292 rehearsal step 4, on the signoff-1-0 build (main 9c9cf4ba44) in an Atlas guest: window-scoped reads and sends behaved correctly, but (1) `c11 focus-window --window <B UUID>` returned OK and made B current/active in c11's model while window A stayed `key:true` and B `key:false`, so B was not brought forward; (2) `focus-window --window window:2` (the documented ref form) returned `ERROR: Invalid window id`. Evidence: `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-292/build-remote/a56aae33573c4c5baf29f3fbf6d67ffd/rehearsal/c11-292-02/`.

- Worktree from origin/main (`c11-1.0/C11-283-signoff-fix`). Determine whether (1) is a product bug (focus-window must make the target window key and front, since it is an explicit focus-intent command) or a guest artifact (for example the app not active in the guest session); prove which. Fix (2): accept `window:N` refs everywhere a window handle is accepted, matching the skill.
- Respect C11-323: focus-window is a window focus, not a workspace switch; do not route it through the workspace gate.
- Tests that go red without the fix; full c11LogicTests; a guest proof on an Atlas tagged build (Atlas-local, no app upload). One PR on C11-283. `HANDOFF C11-283 REVIEW <head> <PR> <evidence>` to tab:210. 60-minute box.
