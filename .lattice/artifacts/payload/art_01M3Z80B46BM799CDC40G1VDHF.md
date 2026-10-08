# C11-265 validation: shared attention ordering, Feed and jump, menu-bar counts

Basis: owner packaged UI pass, reviewer screenshot inspection, exact-head gates, independent merged-head rails. No new native run in this pass.

## Criterion -> evidence -> result

1. Two flags plus three asks, interleaved timestamps: flags oldest-first, then asks oldest-first; tied timestamps stable -> AttentionOrderTests (5), FeedProjectorTests (14) at exact head ev_01M3YZSPPC00DV74X017P9XXQB (2402 logic tests, 0 failures) and merged head ev_01M3Z23003TJMRC99ZJNRPB8R4 (2427 logic + 11 host, 0 failures); packaged guest shortcut picks flag, then oldest ask, then next ask, and `feed.list` order agrees (28-check probe PASS) ev_01M3YZ8MTMYVH6HQRAJA7256WE -> PASS
2. Suppressed routine asks excluded, suppressed flags kept at flag priority, lowering a flag exposes the ask at original age, flag-plus-ask counts one ask -> projection fixtures (ev_01M3YZ8MTMYVH6HQRAJA7256WE, ev_01M3Z23003TJMRC99ZJNRPB8R4); guest probe raises a suppressed flag (precedes older asks) and then lowers it -> PASS
3. Closed/unavailable target skipped consistently, no redirect to the focused tab; next Feed row matches the jump -> candidate-walker closure fixture; guest probe closes a flagged tab, `feed.open` returns unavailable with selection unchanged, real jump reaches the next ask (ev_01M3YZ8MTMYVH6HQRAJA7256WE); reviewer confirmed shared resolver, ev_01M3YZEFWF5VHACKAH9DS69B9Y -> PASS
4. Menu bar shows flags and the same open-ask count, zero states included, finished turn not an ask, updates do not activate c11 -> real status extra in packaged guest: zero state and "1 flag, 3 open asks, No unread notifications"; completed turn is a nonblocking row; Finder stayed foreground and selection unchanged during updates; menus dismissed (window ids gone); screenshots inspected by the reviewer (readable, unobstructed), ev_01M3YZ8MTMYVH6HQRAJA7256WE, ev_01M3YZEFWF5VHACKAH9DS69B9Y; MenuBarExtraAttentionTests (5) and snapshot builder (5) pass at the merged head -> PASS
5. Existing shortcut bindings survive; default jump binding unchanged -> host test with an isolated defaults suite persists a custom binding (Shift-Command-J, correcting the owner's Option-V wording per ev_01M3YZEFWF5VHACKAH9DS69B9Y) across controller refresh, 11 host tests green at merged head ev_01M3Z23003TJMRC99ZJNRPB8R4; packaged keyboard run invokes the unchanged Control-Command-Return default, ev_01M3YZ8MTMYVH6HQRAJA7256WE -> PASS

Notes: exact-head Captain gate ev_01M3YZSPPC00DV74X017P9XXQB; PR checks green (ev_01M3YZB3D2MX54H86PF853YRT1). The probe ran at the reviewed head before squash; merged-head rails pass (ev_01M3Z23003TJMRC99ZJNRPB8R4). The small update-query timing smoke shows no material regression (median 32.96 -> 31.73 ms; burst echo 16.5 ms slower under different load); it is not a soak.

## Routed to C11-292 sign-off

None. The F2 churn comparison is deferred to C11-270 under the Orchestrator ruling.

## Verdict

COMPLETE; no check contradicts any criterion.