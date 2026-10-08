C11-251 validation: existing runtime proof mapped to the ask (batch fast rule)

Merged: PR #563, squash 4994d7fce3bf22f1227d6fe62139a4abff59acd0, landing head 0fef7a9ff1bbe9cc689aca3110588f9ae1ff6a37. Merge Captain receipt ev_01M3ZGYF1PEN3KP82RHGGQ3812: exact-head gate 5c36940831b34fc188204b16c1838f26, Debug compile ok, full logic plus c11Tests/SocketTabRefRejectionWiringTests 2,447 tests, 3 skips, 0 failures (XCTest only); installed c11 skill synced and byte-equal. Review: fresh-reviewer round-4 PASS ev_01M3ZGJK32EMQKVFG98VH1VV3Y covering the whole eight-file diff and every resolveWorkspaceId caller, after Astra rounds 1-3 FAIL on successive targeting bypasses. Scope: internal shell-integration telemetry targeting is C11-325 and out of scope here. No new runs were made for this comment.

Ask -> evidence -> result
1. Destructive clear-* commands require a target and fail loudly from a bare shell -> tests_v2/test_cli_sidebar_metadata_commands.py in an isolated tagged Atlas guest, which seeds status, progress, log, description, icon, metadata and block sentinels on the selected workspace. clear-status, clear-progress and clear-log with no target, with only global --window, and with a malformed explicit, environment or window-scoped workspace each exit non-zero, and every sentinel on the selected workspace stays intact. Explicit --workspace and C11_WORKSPACE_ID route to the named workspace, and explicit wins over environment. Green at the exact landing head 0fef7a9ff1 (build 10c69f0b12b948efa1c4147b67ac998b, fresh guest, passed=1 failed=0; ev_01M3ZG9YCASBACHMKJ5686Z07X) -> PASS.
2. Decide list-* and sidebar-state -> decided: they also require an explicit target or caller environment (same suite and matrix, text and JSON); raw v1 status/progress/log, meta aliases, markdown blocks and reset_sidebar reject absent or empty targets; v2 sidebar.state and workspace.{set,get,clear}_metadata require a resolvable workspace_id -> PASS.
3. The fix is real, not an artifact of the test -> red/green controls in the guest: targetless workspace-metadata write replaced the selected workspace's description without the fix (ev_01M3ZFG9YB17B3NYTGGSGWV9TX, build cbdbf85a74be43d8af061d93bd641d55) and passes with it (f339666bcc944f6a8d91299aaa680db0); malformed explicit workspace set-status returned OK on the previous CLI (9eb54d92e3cb4fa694306c686b5a78f9) and fails on the landing head (10c69f0b12) -> PASS. Two discarded attempts hit an unrelated startup race and are not counted.
4. Help and skill text document the required context -> CLI help and skills/c11 references updated; new English strings localized at the call site (locale pass belongs to C11-291) -> PASS.

Reviewer non-blocking note (pre-existing, not introduced here): workspace metadata argument parsing treats a separate `--workspace <id>` value as a positional key or value (get-workspace-metadata lists `(unset)`, clear-workspace-metadata clears a key named by the UUID, positional set appends the UUID). No ticket was filed; it needs a separate fix.

Routed to C11-292 sign-off
- A rerun of tests_v2/test_cli_sidebar_metadata_commands.py on a tagged merged-main guest (the Captain gate does not run tests_v2; the owner's green run is at the landing head).
- A bare-shell check that targetless clear and list commands fail and the selected workspace's sidebar is untouched.

No check contradicts the ask.

Verdict: COMPLETE with the merged-main tests_v2 rerun and bare-shell check routed to C11-292.