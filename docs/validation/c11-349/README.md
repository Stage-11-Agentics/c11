# C11-349 validation

Status: repairs in progress; no accepted 30-minute performance result yet.

Use stock `scripts/remote-build.sh --tag c11-349` on Atlas. A tagged app may
isolate synthetic recording with the validation-only launch hook
`C11_ACTIVITY_HISTORY_DIRECTORY=/absolute/owned/path`. All history readers
must use the same value. Legacy baseline builds ignore it; their runs may
create only manifest-owned synthetic fixtures beside existing history and
must preserve every original file.

The performance gate compares the same 40-panel, 30-minute spinner/progress,
input and mailbox workload on baseline twice, analytics on and analytics off,
on native Atlas and a constrained stock sandbox guest. Start every variant
with the same 300-file, roughly 130 MB synthetic candidate-label corpus and
metadata-only synthetic mirrors of any baseline foreign history. Never copy
production event contents into test artifacts. Measure startup/pruning bounds
separately from the timed workload, using external process/main-thread counters.
Record exact source/build identities, script hashes, effective policy, worker
completion and message-routing counts, dropped records, visibility, all-generation
bytes, screenshots and independently proven synthesized dismissal.

Earlier empty/population-light or harness preflight attempts are invalidated;
they are smoke evidence only. Final evidence and exact-head review will be
linked here after the required gates pass.
