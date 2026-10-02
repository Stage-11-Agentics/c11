# C11-287 completion summary

Runtime PASS at `b7849c703dc5db07b0d1aad2b6125afe15b3ec68`: all eight owner scenarios completed. Synthetic profile/storage/history survived recovery; loaded/empty tabs each replaced twice and suppressed the third; resized/switch-restored browser painted; attached and detached inspectors recovered; native owning-tab and attached owning-window close preserved terminal input. Inspector cancellation-before-attachment is exact-head host-test proof.

Final five-cycle focus comparison used matched 50/50 split, window/display/fixture/probe: baseline mean 0.772 s, candidate mean 0.770 s. No precise latency, speedup or soak claim. Earlier mismatched-divider probe remains exploratory.

Common logic: 2148 tests / 3 skips / 0 failures with only two approved class exclusions. Selected host tests: 31 passed. Shared six-step restore smoke passed. Tagged app dismissed, PID absent, bounded UI leases released and owned guests removed.

Limits: CLI resize plus visual proof; attached docking edge changed side→bottom; no independent Ghostty diagnostic crash log; earlier UI-driving attempts were harness errors; initial logic failures remain recorded as the ruled flaky class and a timing failure that passed retry. Empty restored window title remains unclassified after corrected screenshot and canceled bisect.

[Standalone evidence](C11-287-evidence.html). Validated by agent:codex-validator; no release or deployment is claimed.