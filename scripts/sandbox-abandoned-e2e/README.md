# Abandoned-session e2e (C11H-352)

Proves that `c11-core` lists an hc session whose core and holder are gone, with exactly what its terminals left running, and that `c11-core end-abandoned` ends those processes and nothing else.

Runs in a sandbox guest on the build host against a tagged build. Never on the operator's laptop, and never signals a process outside the guest.

## Run it

On the build host, from the source folder the remote build left (it holds this harness), with the tagged app that build retrieved:

```bash
C11_SANDBOX_HOST=local scripts/sandbox-abandoned-e2e/run.sh "<artifacts>/c11 DEV <tag>.app" --run-id <id> --out <summary.json>
```

`--keep` leaves the guest up (`scripts/sandbox-down.sh <id>` removes it); `--reuse` runs in a guest that is already up. Exit 0 when every check passes, 1 when one fails, 2 when the harness failed.

## What it does

c11 launches fresh (shards off, so `c11-core` status reaches its core); one of its panels starts a `nohup sleep` and a HUP-ignoring sleep. With c11's pinned `herdr-core`, the guest then starts two sessions c11 does not own: `c11-probe-old`, with one terminal whose root ignores the hangup and has a child (the alive-root shape the build host's 51 login shells had) and one whose root ends on the hangup and leaves a `nohup` job (the dead-root shape), and `c11-probe-held`, left running. It SIGKILLs `c11-probe-old`'s core and then its holder, by the pids it read.

| Check | Passes when |
|---|---|
| `abandoned_shape` | the alive root and its child, and the dead root's `nohup` job, are what is left; no core runs for the session |
| `listed` | `c11-core abandoned --json` lists exactly those 3 processes, as `root`, `session` and `scope` |
| `others_not_listed` | c11's own sessions are not listed, and `c11-probe-held` is skipped as `core_running` |
| `text_line` | the text form prints one `abandoned session=c11-probe-old … processes=3` line |
| `status_counts` | `c11-core --json` carries `abandoned.processes` |
| `hc_diagnostics` | `c11 hc-diagnostics` (JSON and text) shows the session, within its 30 s cache |
| `refuse_current` | `end-abandoned` on c11's own session exits 7 (`current`) |
| `refuse_core_running` | `end-abandoned c11-probe-held` exits 7 (`core_running`); its terminal keeps running |
| `refuse_live_holder` | with that session's core just killed and its holder alive, it still exits 7 |
| `end_ends_leftovers` | `end-abandoned c11-probe-old --yes --json` exits 0, hung up 3, and all 3 are gone |
| `end_starts_no_core` | no core runs for `c11-probe-old` afterwards |
| `live_untouched`, `held_untouched` | c11's panel processes and the held session's keep their pid and start time |
| `relisted_clean` | `c11-core abandoned` no longer lists the session |
