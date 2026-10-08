# Review: C11-283 sign-off fix (focus-window raises its target; window:N refs)

Follow `reviewer-common.md` in this directory (mailbox tab:210). Title `Signoff 283 Review`. Actor `agent:astra-review-283s`.

- PR https://github.com/Stage-11-Agentics/c11/pull/581, head `0eaa5bca3155d12f3794c51243320d831b709862`, base = merge-base with origin/main. Validation ev_01M40F7597H3ZBYMMRBP396CMP and ev_01M40GNKN8HMHFX2DD83FA09PS (full c11LogicTests 2,503/0; window-scope CLI fixture 133 cases with a red pre-fix run; tagged guest proof that `focus-window` by UUID and by `window:2` makes B key).
- Context: the C11-292 rehearsal found `focus-window` returned OK without making the target window key, and the `window:N` ref was rejected.
- Focus, since this changes focus policy right before release: only the explicit window-focus intents (`focus_window`, `window.focus`) may activate the app and raise a window; every other socket command still never steals focus (CLAUDE.md socket focus policy); workspace and surface focus intents stay activation-suppressed and C11-323's workspace gate is untouched (focus-window must not change which workspace a window shows); `window:N` resolution is strict (a malformed handle errors and never falls back to the current window, the C11-251 lesson); no typing-path change.
- Break the focus-intent distinction and confirm a test goes red.
- Reply `VERDICT C11-283 PASS|FAIL <head> <artifact>` to tab:210.
