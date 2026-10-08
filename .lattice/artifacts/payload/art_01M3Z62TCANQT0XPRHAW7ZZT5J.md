# C11-261 window 2 ABBA-10 results — INCOMPLETE

Candidate a2e448b74d9ecdfdf356498cfb431036de9e5c95 versus frozen clean main dedc6007a5bb886388af23d7c48c48d76025772f. Protocol art_01M3Z519J5VK0C5CQ793AAKXB6; seal017 art_01M3Z519MQ2R560EBH02X55RAD. New independent cohort, not pooled with the previous130pairs.

Window grant: holder66709, start16:32:57 Atlas/20:32:57 UTC,25minutes, no extension. Admission load14.6987. Both native children74798/74799 under the owned display9 lease. Priming fully settled with no bounded fallback timeouts. Actual per-trial load9.6768–16.1260; continuous load, before/after uptime for every trial, Tart/process snapshots saved. Foreign c11-sb-c11-249-ui remained running; it was not stopped.

800 observations /400 complete scheduled pairs were retained. No-churn: BOTH roles valid120typing/40switch/40scroll. Churn: control valid120/40/39, candidate120/40/38; every role ATTEMPTED120/40/40. Required minimum100/40/40 per phase is missed for scroll. Three real-HID scroll trials timed out at1second: candidate churn-c04-b1-09, candidate churn-c08-b2-06, control churn-c08-b3-05. All have raw precondition/frames and PNGs; no retry or recalibration. These are failures, not outliers discarded from the experiment. Valid-sample percentiles below exclude them as preregistered but do NOT discharge the failed minimum or full gate.

Churn workers each completed2,165/2,400 operations, about9.021Hz rather than10Hz:542reorder,541transfer,541flag,541suppression each. Last operation START lateness23.527s control /23.579s candidate. Recorded first-to-last completion spans240.019s /240.068s; final calls crossed the fixed boundary and were joined. Worker summaries alive=false,pending=false,error=null mean workers DID join; the comparator's generic 'worker did not quiesce' issue here also covers missing required count, NOT proof of a surviving thread. This is a frozen protocol rate/count failure. The collector stopped before post-churn model/resource snapshots and before quiescence. Quiescence0 samples. Do not extend or manufacture it after release.

QUIET DONE C11-261 was sent automatically within the1-second capture-end watcher after the collector exited. The holder disappeared by20:47:01 UTC, before the granted end. The observer hit ProcessLookupError during the brief holder-gone/marker-present handoff and recorded external_release_verified=false; that record is preserved, not edited. Subsequent read-only lsof-p66709/ps showed no holder descriptors/process; marker and UI lock absent at20:48:27. Exact owned children were force-cleaned and proven gone. This is NOT normal synthesized dismissal or clean restart. No build/guest/production app was launched or modified during the run.

Nearest-rank valid-sample p95/p99 in milliseconds, no overhead subtraction:

| Phase/metric | Control p95 / p99 | Candidate p95 / p99 | p95 / p99 limits |
| --- | ---: | ---: | ---: |
| No-churn typing |47.196 /51.171|48.916 /55.907|56.636 /66.171|
| No-churn switch |175.811 /197.939|180.486 /206.384|210.974 /247.424|
| No-churn scroll |59.045 /61.896|55.708 /64.430|70.854 /77.370|
| Churn typing |100.004 /116.939|96.530 /115.874|120.005 /146.174|
| Churn switch |167.137 /190.430|164.820 /170.475|200.564 /238.037|
| Churn scroll |126.029 /127.150|102.611 /114.944|151.235 /158.937|

All12 computable numeric limits are within the registered p95 max(control×1.20,control+5ms), p99 max(control×1.25,control+15ms). No clear candidate-specific latency regression is shown. That does NOT exclude a regression: failed scroll observations exist on BOTH builds (2vs1), under-delivered churn invalidates the prescribed workload, and6quiescence budgets are unmeasured. Whole gate remains INCOMPLETE, not PASS.

Signed paired delta and absolute paired variation (not pure independent noise):

|Phase/metric|Paired n|Signed mean /p95 /p99 ms|Absolute mean /p95 /p99 ms|
|---|---:|---:|---:|
|No-churn typing|120|-0.769 /16.575 /24.193|9.179 /20.752 /25.013|
|No-churn switch|40|2.213 /38.364 /48.041|16.753 /38.364 /48.041|
|No-churn scroll|40|-1.025 /19.086 /24.245|10.612 /21.339 /24.753|
|Churn typing|120|2.375 /47.740 /63.940|24.910 /58.639 /68.389|
|Churn switch|40|-0.460 /21.320 /26.549|10.883 /30.408 /38.690|
|Churn scroll|37|-4.275 /56.498 /58.642|27.017 /73.913 /75.125|

Per-pair raw deltas, loads/time and complete block contrasts are in abba-comparison-incomplete.json. No valid complete churn scroll cycle remains for a four-block contrast because its invalids touch both cycles. Valid typing/switch cycle contrasts range-3.896..2.749/-2.348..8.113ms (no-churn/churn typing),1.142..3.283/-2.072..1.151ms (switch). Actual mean-time imbalances are reported, not assumed zero.

Measured setup/capture noise p95 control /candidate ms:

|Phase/metric|Setup|Pre-input capture|Frame capture|
|---|---:|---:|---:|
|No-churn typing|178.327 /178.835|20.948 /23.452|18.110 /19.409|
|No-churn switch|35.041 /33.366|20.794 /21.306|18.189 /18.651|
|No-churn scroll|268.146 /268.423|37.926 /39.542|26.807 /21.587|
|Churn typing|278.123 /277.707|17.060 /18.646|16.556 /16.519|
|Churn switch|27.243 /26.090|32.450 /30.532|16.366 /16.503|
|Churn scroll|357.326 /354.775|33.540 /33.984|16.953 /16.996|

Activation occurs at block boundaries only, recorded conditionally rather than diluted with zeros. Means ~224–267ms, p95~227–299ms depending phase/metric/role; complete distributions are in the score. Setup includes declared reset/selection query and lock wait; frame capture remains inside key-to-paint. No overhead is subtracted. Before-only CPU/RSS/footprint captures exist; post/quiescent recovery proof is absent. Missing hang logs remain missing instrumentation, not zero-hang proof.

Read-only diagnosis: both churn workers and all switch/reset probes share ONE global SELECTION_LOCK. It serializes two independent apps' mutation and selected-ID RPCs, while reset holds it through0.12s settle and switch holds it through paint/selected-ID verification. This creates avoidable harness contention; symmetrical9.021Hz delivery and23.5s schedule lag are consistent with that bottleneck. Exact time waiting for versus holding the lock was not separately instrumented, so it is not proven the sole cause. The three scroll timeouts remain unattributed (input delivery, UI state or harness); never dismiss them as noise or automatically call them a product regression. A future preregistration should use per-role selection serialization, preserve each role's focus oracle, record lock wait/service time and add symmetric predeclared scroll/switch sample headroom. No such change or further native trial has been executed; a new measurement cohort/window needs an Orchestrator ruling.

Other five review repairs remain implemented and evidenced in art_01M3Z5H8GZGTFCFJM8WQD4M5WW /ev_01M3Z5H8KGDWQMQBJFEJE0WYB2:43 native tests+8 Python, native A1–A9/A12/A13 semantics, complete human runbook/routing, forced restart labeled UNVERIFIED. No push/HANDOFF REVIEW yet because the performance gate is not achieved. H1–H3 and independent CUA remain blank/pending.
