C11-286 validation: pre-merge runtime proof mapped to acceptance criteria

Merged head 5e24fb743f4836a04e274ef03d91ceec06dda383 (squash 64c26ccc48, PR #545). Evidence reviewed: owner validation, Astra round-2 review, Merge Captain gate, parked Validator batch comment. No new runs were made for this comment.

Criterion -> evidence -> result
1. Top-left unchanged and 1200x800 or clamped=true with frame equal to applied -> ev_01M3YW81FG4TPNS8SVH39XRBNN (isolated Atlas guest run on tagged build, source_head=ba414b796 from the built bundle, cli_server_sha_match=true, summary passed=1 failed=0, resize case) plus 8 WindowResizePlanTests incl. negative-origin secondary-screen fixture at the merged head (ev_01M3YYPNNC4DYTFHM4ATFP9SYZ, invocation 71b5bc95a8d64a768d1cb15e03785b4f; re-run at merged-main head in ev_01M3Z2302E1VH6SRSVKYXPE6SC) -> PASS
2. `- -` prints current size and leaves the frame identical -> ev_01M3YW81FG4TPNS8SVH39XRBNN (read-only case in the guest run) -> PASS
3. Below-minSize request clamps, clamped=true, no throw -> ev_01M3YW81FG4TPNS8SVH39XRBNN (min/max clamp, kept-edge cases) plus WindowResizePlanTests 8/8 (ev_01M3YYPNNC4DYTFHM4ATFP9SYZ, ev_01M3Z2302E1VH6SRSVKYXPE6SC) -> PASS
4. Key window unchanged during resize -> ev_01M3YW81FG4TPNS8SVH39XRBNN ran headless and its logical-selection oracle is withdrawn by the owner (ev_01M3YYPNNC4DYTFHM4ATFP9SYZ); review ev_01M3YZ45JTWBSMYV17KSKQA1VF confirmed the code path has no activate/focus call and the harness now observes frontmost PID and key identity, but no run of that oracle exists -> NOT RUN, routed to sign-off
5. Unknown window id is not_found and focused frame unchanged -> ev_01M3YW81FG4TPNS8SVH39XRBNN (unknown-window and invalid CLI/RPC cases) -> PASS
Additional: off-main parse and worker dispatch repair verified by review ev_01M3YZ45JTWBSMYV17KSKQA1VF (source review plus mutation proof: geometry-anchor mutant fails 6 assertions in 4 tests, baseline and restored pass 8/8). Debug compile and full c11LogicTests green at the landed head: 2,399 tests, 0 failures, 3 existing skips (ev_01M3YZ5W9XMKME59VRA97VV11Q, independently read by the Merge Captain). Merged-main artifact rerun: 2,427 logic tests, 0 failures, WindowResizePlan 8 and CapabilityFeatures 3 pass (ev_01M3Z2302E1VH6SRSVKYXPE6SC). Installed c11-computer-use skill synced and byte-equal (ev_01M3YZ5W9XMKME59VRA97VV11Q).
No failing check was found against any criterion. The interrupted unfiltered host-bound run (AppDelegateShortcutRoutingTests) is a different area, was never a gate for this ticket, and is not used as evidence.

Routed to C11-292 sign-off (human-visible, no runtime run exists)
- Another app frontmost during resize: Finder frontmost and c11 key identity unchanged after resizing a second c11 window by explicit id (covers criterion 4 and the no-activation requirement).
- First c11 window key while resizing the second: frontmost PID and key identity unchanged.
- Secondary-display edge clamp: window placed near an edge of a non-main display, oversized width and height together, clamped=true, top-left unchanged, applied size equals that display's visible frame. Unproven if only one display is available.
- Repaired-head packaged-app worker-dispatch diagnostic: one resize through the real app shows the worker route (the Atlas guest run predates the off-main repair).

Verdict: COMPLETE with sign-off routing: criteria 1, 2, 3 and 5 are covered by runtime and logic proof, criterion 4 and the display-edge case go to the C11-292 sign-off script, and no check contradicts a criterion.