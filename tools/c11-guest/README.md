# c11 guest kit (C11H-17)

Host-side entry: `C11_GUEST=<run-id> C11_APP=<tagged .app> tools/c11-guest/g.sh <verb> [args]` (the matrix's `$G`). `C11_RUN` is accepted as a synonym of `C11_GUEST`. A host `C11_APP` path is mapped to where `sandbox-up` put it in the guest (`/Users/admin/c11-sandbox/apps/<run>/<basename>`). `guest.sh` is shipped to `~/c11-guest/` on first use (sha-checked); it never runs on the host.

| verb | does |
|---|---|
| `launch [fresh\|resume] [VAR=val…]` | `open -g` in the Aqua session with `C11_QA_LAUNCH=<mode>` and `C11_SOCKET_MODE=automation` (`c11Only` in the gated mode below); extra `VAR=val` replace defaults (e.g. `C11_HC_SOCKET_OVERRIDE=<proxy.sock>`); quits a running copy first; waits for the c11 socket |
| `launch-env [fresh\|resume\|normal] [VAR=val…]` | the environment `launch` would give the app, one `KEY=value` per line; launches nothing |
| **gated mode** `C11_SOCKET_GATE=1` | C11H-33: `launch` uses `C11_SOCKET_MODE=c11Only`, the app's normal default, which admits only callers inside c11's own terminals (the default `automation` admits every caller). The kit's ssh caller (`cli`) is then refused; drive the app with `incli`. A `C11_SOCKET_MODE=` on the launch line still wins. `env` prints `SOCKET_MODE`. In a gated app **`incli` is the only way to run a sending row**: anything through `cli`, `diag` or a raw ssh call is refused by design (`hc_caller_not_owned`). Rows that need a gated app: `tools/c11h-validator/checks/V6.admission.sh` (this mode; every admitted command through `incli`), `tools/c11h-proofs/T9.3.sh` and `T9.6.sh` (launch with `C11_SOCKET_MODE=cmuxOnly` themselves; their only callers while gated are the outside ones they expect refused). `lib.sh`'s `launch_fresh`/`launch_new` wait on `alive` instead of `cli tree` after a gated launch |
| `quit` | AppleScript quit by the app's bundle id; `quit-ok` or `still-running` (exit 1) |
| `kill9-app`, `crash-app` (SIGSEGV) | signal the app |
| `kill9-core`, `kill9-holder`, `stop-core`, `cont-core` | signal c11's core / holders only (pinned path under `~/.local/share/c11/hc` and this session); never the `default` session. Exit 5 if none found |
| `procs` | ps of the app, core and holders |
| `keys '<System Events body>'` | frontmost + System Events body |
| `shot <name>` | window screenshot; host copy at `$EVIDENCE_DIR/${C11_ROW:-adhoc}/<name>.png` (path printed) |
| `cli …` | the bundled `c11` at c11's socket (found via env, breadcrumb, tagged default, prod default) |
| `incli <panel UUID\|any> <c11 args…>` | the bundled `c11` run inside one of the app's own hc terminals, as an agent there runs it: typed into the live terminal labelled `c11.panel=<panel>` (`any`: the first) with `hc send`, in that terminal's own environment, so a gated socket admits it. Prints one JSON record `{panel, terminal, rc, out, err, env}` (`env`: the terminal's `C11_SOCKET_PATH`, `C11_PANEL_ID`, `C11_WORKSPACE_ID`, `C11_SHELL_INTEGRATION`). Exit 4 no core socket (never autostarts), 5 no such terminal, 6 no exit code within `C11_INCLI_S` (default 20) s, 7 hc send failed (hc 0.1.16 `send` waits for the terminal to be idle, so type only into a shell at its prompt). The typed line shows in that panel. Self-test `test/incli-selftest.sh` |
| `hc …` | the pinned hc with c11's session and socket, `env -i`, no XDG. Refuses (exit 4) to autostart a core when the socket is absent unless `C11_HC_ALLOW_START=1` or the verb is `server` |
| `diag` | `$DIAG`: ticket 9's verb when `C11_DIAG_VERB` is set, else `tree --json` joined by the `c11.panel` label to `hcrecs --all` (`diagjoin.py`; `c11 hc-diagnostics --json` adds `hc_build`, and tty/pid where hc has none). `hc ls --json` prints no labels or pid, so it cannot be joined itself |
| `hcrecs [--all]` | `hc ls --json`, each terminal replaced by its `hc get <address> --json` record (labels, pid, state, reason); same shape as `hc ls --json`. Exit 4 with no core socket (never autostarts). `hcrecs.py` and `diagjoin.py` ship with `guest.sh` |
| `sh '<zsh>'`, `aqua-sh '<zsh>'` | run in the guest (plain ssh / Aqua session) |
| `alive` | exit 0 and `alive pid=… socket=…` when the app runs and its socket accepts a connect (the session check) |
| `reap-row <row>`, `rows-clear` | C11H-31: every guest command run while `C11_ROW` is set records its process group and leader start time in `~/c11-guest/rows/<row>` (`rowtag.sh`); `reap-row` ends only those groups, inside the guest, after `run-row.py` killed the row on the host; `rows-clear` forgets them at session start. The app is launched through launchd and is never in a row's group. `C11_G_DRY=1` prints the command a verb would send instead of running ssh (no guest needed; the host self-test runs it with `kill` shadowed) |
| `put`, `get`, `put-app`, `upload-tools`, `ip`, `env` | file transfer, second build (`C11_APP_B`), probes to `~/c11-guest/tools`, resolved names |

Names that may still move (bundle, socket, breadcrumb, hc root, override env, diag verb) are in one variables block at the top of `guest.sh`.

AX reads: AppleScript's `value of attribute "AXDescription"` misreports SwiftUI elements (it returned empty for a SwiftUI button whose AXDescription is set). Read accessibility through the AX API instead: `axdump.c` (compile on the host with `clang -O2 -o axdump axdump.c -framework ApplicationServices`, `g.sh put` it, then `g.sh aqua-sh "/tmp/axdump <app pid> <identifier prefix>"`) prints role, AXTitle, AXDescription and AXValue for every element whose AXIdentifier starts with the prefix, and for its descendants. C11H-166.

Probes (upload with `g.sh upload-tools`, run in the guest with `g.sh sh`): `rx.py`, `q0b.py`, `r2048.py`, `lat0b.sh`, `latp.py`, `p200.sh`, `sampler.sh`, `rss.py`, `replay0b.py`, `kitty.zsh`, `hcx.py`. `snap.sh <out>` runs in the guest.

Wire faults: the socket proxy `hcfault.py` was removed (a proxy replaces the kernel peer and fails contract L2's serving-build check). Faults are injected inside the Debug app by C11H-21's env var; proofs use `launch_faulted` in `tools/c11h-proofs/lib.sh`, whose env name and log token are placeholders until C11H-21 sends them.

The proofs and validator kits that drove this kit (`tools/c11h-proofs/`, `tools/c11h-validator/`) are archived in the private c11-ops repo (C11H-268); `test/hcrecs-selftest.sh` finds them through `C11_PROOFS_DIR` or a c11-ops checkout beside this repo.
