# C11-261 repair round 1: partial g60 comparison — INCOMPLETE

2026-10-02. Candidate a2e448b74d9ecdfdf356498cfb431036de9e5c95; clean main control dedc6007a5bb886388af23d7c48c48d76025772f. Frozen seal identity-015.json; attempt-010. These are descriptive partial measurements, NOT a performance gate PASS or AC5 completion.

The fixed 130-second no-churn phase overran after 130 complete A/B pairs (260 raw observations). Each role has 74 typing, 28 switch, 28 scroll observations, all valid. Required minimums are 100/40/40 per role per phase. Churn and quiescence have ZERO observations; final phase/model checks and normal synthesized dismissal were not completed. No trials are discarded or retried. QUIET DONE C11-261 was sent immediately; the Orchestrator released the slots at 20:16:19 UTC. The UI supervisor then force-cleaned only its exact owned children. This is NOT clean-restart or normal-dismissal evidence.

Nearest-rank milliseconds, no overhead subtraction:

| Metric | Pairs | Control p95 / p99 | Candidate p95 / p99 | p95 / p99 limits |
| --- | ---: | ---: | ---: | ---: |
| Typing | 74 | 52.212 / 56.546 | 55.803 / 63.085 | 62.654 / 71.546 |
| Switch | 28 | 196.367 / 197.567 | 185.748 / 215.506 | 235.640 / 246.958 |
| Scroll | 28 | 62.972 / 67.269 | 60.438 / 61.310 | 75.566 / 84.087 |

Limits remain p95 <= max(control*1.20, control+5 ms), p99 <= max(control*1.25, control+15 ms). The six *partial* comparisons are within these limits. These partial numbers do not show a clear regression. Typing tails and switch p99 are higher, but undersampling and paired variability prevent a claim that the full gate passes or that regression is excluded.

Paired candidate-minus-control deltas and absolute paired variability (the latter is descriptive variation including any real product difference, NOT an independent pure-noise estimate):

| Metric | Signed mean / p50 / p95 / p99 ms | Absolute mean / p50 / p95 / p99 ms |
| --- | ---: | ---: |
| Typing | -0.271 / 1.235 / 18.390 / 30.299 | 9.940 / 8.004 / 22.940 / 30.299 |
| Switch | -3.519 / -2.648 / 26.814 / 28.347 | 12.717 / 10.305 / 28.349 / 48.192 |
| Scroll | -3.220 / -1.135 / 18.180 / 21.477 | 9.993 / 6.019 / 28.150 / 30.961 |

Measured harness overhead, control / candidate (mean, p95 ms):

| Metric | Activation | Setup | Pre-input capture | Individual frame capture |
| --- | --- | --- | --- | --- |
| Typing | 221.976,227.084 / 220.922,226.355 | 160.044,167.430 / 159.003,167.246 | 15.771,19.914 / 15.362,19.573 | 12.681,16.523 / 13.147,17.020 |
| Switch | 221.319,227.640 / 221.016,227.136 | 16.108,21.078 / 16.201,23.105 | 13.287,17.434 / 13.428,16.361 | 12.990,17.631 / 13.334,17.357 |
| Scroll | 222.287,227.525 / 220.590,227.038 | 253.869,260.911 / 252.874,256.992 | 28.989,34.659 / 29.020,32.513 | 13.941,20.220 / 14.034,20.795 |

Activation/setup/pre-input capture are outside key-to-paint. Paint frame capture remains inside the measured latency; nothing is subtracted. Roughly 400 ms per-trial external overhead explains why the earlier fixed schedule was too short. The revised protocol will budget this explicitly, before any new cohort.

Before/after uptime and load are saved for EVERY observation, plus continuous process/VM records. Sample 1-minute load ranged 9.1763–11.8481. Foreign VMs c11-sb-311c-b114-focus-2 and c11-sb-c11-231 were running and were not stopped. Exact per-pair loads/deltas are in comparison-incomplete.json and raw JSONL. Template/artifact/selected-ID and timestamp checks found no errors among the captured observations. Tagged hang logs were not generated: absence is not proof of zero hangs. Before/after-incomplete resource captures are descriptive, not quiescence evidence.

Other five review repairs are implemented at the candidate head: suppression eligibility with a production-adapter behavioral test; corrected oracle/dead planner retirement/perf-watch dispositions; exact intermediate membership/order/tab/root-shell PID/removal oracles; actual fixture restore comparisons; complete human chapter setup/reset/routing/operator block; forced exits labeled UNVERIFIED rather than clean restart. Atlas final native gate invocation 9095bbf903ca4834baaf1adefb6cec36 ran 43 tests (27 host + 16 logic), zero failures, TEST SUCCEEDED. Eight executable Python oracle tests passed. Native scale A1–A9, A12–A13 passed; A10 event subscription and A11 clean restart remain explicitly UNVERIFIED. Human/operator checks remain pending, not signed off by the owner.

This report and machine-readable comparison are published now. Raw observations, templates, PNGs, logs, observer release records and the frozen seal015 helper version are being archived together. A new ABBA cohort will be separately preregistered; these 260 observations will not be pooled into it or erased.
