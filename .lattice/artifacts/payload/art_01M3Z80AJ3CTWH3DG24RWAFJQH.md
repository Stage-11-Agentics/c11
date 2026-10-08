# C11-264 validation: Feed typed asks (list, open, watch, ask events)

Basis: existing pre-merge runtime proof plus exact-head gates. Merged head ee66573112 (squash bc915d0509). No new native run in this pass.

## Criterion -> evidence -> result

1. Typed fixtures (question, plan, permission, turn end; target UUIDs, source, opened_at, state; unknown options/source explicit) -> FeedProjectorTests (14) in Merge Captain exact-head gate ev_01M3YW8PSHREV9V6J92XC03HK0 (2397 logic tests, 0 failures) and independent shared gate ev_01M3YZ7AMJKG7S7JZTYRSERT6S (2414 logic + 8 host, 0 failures); packaged guest `feed list` returns the typed flagged row and prompt, ev_01M3YRG3Q30YW8N75NDWH69CTK. Generic input is explicitly unsupported by the amended plan, accepted in review ev_01M3YRT6K6T5XG99K618WS5JYM -> PASS (generic-input scope per amended plan)
2. Flag plus question on one tab; unrelated notice keeps the question; response/moved-on retires it; sibling tool start does not -> FeedProjectorTests incl. captured bypass/answered-ask corpus through fold, projector and events (ev_01M3YW8PSHREV9V6J92XC03HK0, ev_01M3YZ7AMJKG7S7JZTYRSERT6S); guest test_feed_list_watch.py shows unrelated activity preserving the question and matching resolution retiring it, ev_01M3YV1VX1MKNXAAAM6BNRS3BZ -> PASS
3. ask.opened/ask.closed with correct target and bounded payload; duplicate J2 event adds no second row -> serialized-event parity in FeedProjectorTests, JournalReducerTests (12) idempotency (ev_01M3YZ7AMJKG7S7JZTYRSERT6S); event schema/fixtures `jq` clean, ev_01M3YRG3Q30YW8N75NDWH69CTK; reviewer mutation proof ev_01M3YVP3HNG5DR392AAZDAF27Q -> PASS
4. list and watch agree across open/close, suppression, restart/reconnect; continuity-unavailable surfaced then refreshed; suppressed routine asks hidden, flags visible -> guest test_feed_list_watch.py, test_feed_watch_auth.py (authenticated reconnect, scope preserved), test_feed_watch_restart.py (real app termination and relaunch, new instance snapshot, new turn_end observed, CLI RSS 17,584 -> 17,792 KiB over 120 updates), ev_01M3YV1VX1MKNXAAAM6BNRS3BZ; reviewer mutations (omit reconnect, omit removal forwarding) each fail the matching test, ev_01M3YVP3HNG5DR392AAZDAF27Q -> PASS
5. feed open targets the selected row's real tab across workspaces; closed/unknown tab returns unavailable with no substitute; list/watch never move focus; no feed command sends an answer -> guest test_feed_open.py: exact workspace/tab focused, unknown tab and workspace unavailable without selection change, ev_01M3YRG3Q30YW8N75NDWH69CTK; closed-target retirement (service removal/prune) test and mutation proof, ev_01M3YVP3HNG5DR392AAZDAF27Q; no answer path in diff per review ev_01M3YRT6K6T5XG99K618WS5JYM -> PASS for same-window/two-workspace behavior; cross-window foreground gap routed below

Also: privacy of failed delivery (7 modes: lost/rejected bodies absent from socket calls and disk) and producer fixture, ev_01M3YV1VX1MKNXAAAM6BNRS3BZ and ev_01M3YZ7AMJKG7S7JZTYRSERT6S; merge integration attested ev_01M3YVYDKMK2E1JQ1V8SAH4050 (mechanical union of two files) and gated at the exact head.

## Routed to C11-292 sign-off

- Cross-window `feed open` with another app frontmost and unsubmitted terminal input in a second window: the expanded scenario was never passed (guest display/onboarding blocked synthesized input). Visible-focus claim only.
- A real agent question appearing as a typed Feed row and retiring on answer: only synthetic and replayed-corpus proof exists (native provider answer/resume is coordinated with C11-274/C11-231).
- Typing-latency / main-thread comparison against the F2 baseline: deferred to C11-270 under the Orchestrator ruling; only bounded watch RSS is recorded.

## Verdict

COMPLETE with sign-off gaps routed to C11-292; no check contradicts any criterion.