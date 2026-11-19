Fixtures for `test/hcrecs-selftest.sh` (C11H-31).

Real guest output, copied unchanged:
- `hcls-6-live.json`: `hc ls --json` (hc 0.1.16) from C11H-24's guest run, from the run evidence folder (6 live terminals; no labels, no pid).
- `hcdiag-ready.json`: `c11 hc-diagnostics --json` from the same run (readiness ready, `panels` empty).
- `hcls-socket-absent.err`: the kit's `hc ls` error with no core, from C11H-24 attempt 5.
- `procs-core.txt`, `procs-nocore.txt`: the kit's `procs` from that run (core serving from `/hc/0.1.16/`) and from attempt 5 (no core).
- `get-ticker-real.json`: `hc get studio/ticker --json` from C11H-13's guest run, from the run evidence folder (a terminal no app made: `labels` empty).

Derived (no real labelled `hc get` output exists yet):
- `get-records.json`: one `hc get` record per address of `hcls-6-live.json`, in the real record's shape (`get-ticker-real.json`), with the labels the app writes (`c11.panel` = panel UUID, `c11.creation`; `Sources/HC/HCManagedSession.swift`). The panel UUIDs are that run's six `list-panels` ids. `t5` is a finished earlier terminal of the first panel.
- `hcls-all.json`: `hcls-6-live.json` plus `t5` as `hc ls --all` would list it (the run's `hidden_finished` was 1).
- `tree-6.json`: those six panel ids in the tree shape the kit's `tq` walks.
