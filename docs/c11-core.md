# c11-core

`c11-core` is a terminal utility for c11's own hc core. It runs from any terminal: a c11 panel, Terminal.app, or an ssh shell on the same Mac. It shows the core, its holder, every terminal and every linked machine, and it can restart the core, open a terminal in Terminal.app, reconnect a machine and link the build host. It is `Resources/bin/c11-core` in the app bundle. You can also open it in a panel with `c11 core` or **Window ▸ hc Core**.

## What it talks to

`c11-core` uses the core this c11 build launches, and nothing else:

- **Session and socket** (for the core commands; `abandoned` and `end-abandoned` read other sessions' records, below) come from the build: session `c11` for release only; `c11-debug`, `c11-staging` and `c11-nightly` for the untagged Debug, staging and nightly builds (`c11-staging-<slug>` for a tagged staging build); `c11-<tag>` for a tagged Debug build. No two builds share a core or its terminals. A staging, nightly or untagged Debug build that ran before C11H-216 kept its terminals in release's session; the first isolated build cannot reach them, so end them (End All Sessions in that build) before switching it. The socket is `~/.local/share/c11/run/<session>.sock`. `HC_SESSION`, `HC_SOCKET` and `PATH` are ignored.
- **Before it reads anything beyond the core's own `hello` and `server.status`** (which identify the peer) it runs the checks c11 itself makes (`HCBuildVerifier`):
  - `socket_owner`: the socket is a socket and is yours;
  - `peer`: the process on the other end is yours, and is the pid the core reports for itself;
  - `session`: the core's `core.lock` and `core.json` belong to this session;
  - `pin`: the process runs `~/.local/share/c11/hc/0.1.16/herdr-core`, whose SHA-256 is the pin's.

  If any check fails, nothing is read or changed, and the refusal says which check failed.
- **It never** starts a core of its own, runs `hc update`, kills a process by name, or touches the holder. It never uses c11's app socket, so c11's caller check (C11H-33) never applies to it and nothing is opened up. hc already lets any process of your user drive its socket; `c11-core` only adds care.

## Commands

| Command | What it does |
|---|---|
| `c11-core [--all] [--json]` | The core, holder, live terminals and machines. `--all` adds finished terminals. |
| `c11-core show <terminal> [--json]` | One terminal in detail. `--json` prints that terminal's item (the shape below), not the whole object. |
| `c11-core watch` | The status list, refreshed every 2 s. Keys: ↑↓ select, `o` open (watch only), `O` take over, `r` restart, `q` quit. |
| `c11-core open <terminal> [--take-over] [--yes]` | Opens the terminal in a new Terminal.app window. |
| `c11-core restart [--yes] [--json]` | Restarts the core. The holder keeps every program running. |
| `c11-core reconnect <machine> [--yes] [--json]` | Runs `machine login <machine>` (hc 0.1.16 has no other redial) for a linked machine that is down. |
| `c11-core link <machine> [--yes] [--json]` | Adds a machine (the build host, say) through the install guide's via script. The plan names the ssh target the via dials. Inside a c11 terminal `--yes` is refused: the operator answers. |
| `c11-core abandoned [--all] [--json]` | hc sessions whose core and holder are gone, with what their terminals left running. `--all` adds the sessions passed over and why. Needs no running core. |
| `c11-core end-abandoned <session> [--grace <s>] [--yes] [--json]` | Ends one listed session's leftovers: SIGHUP, then SIGKILL after the grace (3 s by default). |

**Asking first.** Actions ask before they change anything. With `--json`, or without a terminal, they need `--yes` and never prompt.

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | ok |
| 2 | usage, or no such terminal or machine |
| 3 | not c11's core (`socket_not_owned`, `wrong_session`, `not_c11_pin`) |
| 4 | the core is not running (`core_not_running`) |
| 5 | the action failed |
| 6 | declined at the prompt |
| 7 | not abandoned: this build's session or the caller's, a running core, or a live holder (`end-abandoned`) |

### Jumping to a terminal's panel

Every terminal that a c11 panel shows carries a link, `c11://panel/<uuid>`. c11 registers the `c11://` scheme (C11H-23); `c11://` belongs to c11. Inside c11 you open it yourself: ⌘-click it in a c11 terminal, or click it in a local page in a c11 browser panel. That switches workspace and selects the panel.

No `c11` command does this. Socket commands never switch the selected workspace or bring c11 forward, so the jump is always your own click. Terminal.app can't open `c11://` links, so outside c11 the tool prints `(jump: inside c11)` instead.

### Opening a terminal in Terminal.app

`open` writes a short `.command` file under `~/.local/share/c11/core/` (0700), then runs `open -a Terminal` on it. The file deletes itself when it starts. It runs c11's pinned `herdr-core attach`, with the session and socket written out explicitly.

- **Only hc's address shape opens**: `tN`, or `<machine>/tN` where the machine is ASCII letters, digits, `.`, `_` and `-` (every name `link`, pairing and Add Machine create), never `local`. `show` and `open` refuse anything else before they connect (exit 2), and the address enters the script only as the quoted argument of its `exec` line.

- **By default it is watch-only** (`--observe`). You see the terminal live, but typing in that window is ignored, and c11 keeps its size.
- **`--take-over`** is a plain attach, which types and takes the size. It explains what that does to the c11 panel and asks first; with `--json` or no terminal it needs `--yes`.
- **Detach** with `ctrl+\`.

### Two clients on one terminal

This was measured on hc 0.1.16 (C11H-37, in a guest):
- Both clients type into the same program, interleaved, with no lock. Both see all the output.
- The client that was active most recently sets the size: the one that attached, typed or resized last. The other client is not told. It shows the screen drawn for the other size, with cut or wrapped lines, until it types or resizes again.
- An `--observe` client never types and never takes the size.

While Terminal.app holds the size, c11's panel looks wrong, and its input guard may misread the composer.

### Restart

`restart` follows c11's own recovery for the parts it can do from outside the app:
1. Sends `server.restart` to the verified core.
2. Waits for that exact process to exit.
3. Waits up to 30 s for a verified core with the same session and core id in a new process.

The holder keeps every program running. The utility never starts a core itself. c11 starts the new core when it reconnects (`HCManagedSession` launches the pinned core when the old one is gone), and its panels reconnect by themselves. With c11 quit, no verified core returns, and `restart` says to open c11. The result reports how many terminals were adopted and how many screen copies are exact.

### Abandoned sessions

hc ends a lost holder's terminals itself, `nohup` jobs included, in the running core and in the next core that starts for that session. A session whose core never runs again (an old dev build's tag, the c11h to c11 rename, an uninstalled build) keeps whatever its terminals left. `abandoned` finds those; `end-abandoned` ends one session's.

- **Where it looks.** Session folders under hc's state root (`~/.local/state/herdr-core/`) named as c11 names its sessions (`c11`, `c11-*`, and c11h 1.x's `c11h`, `c11h-*`). This build's session and its shards, and the session the caller runs in (`HC_SESSION`), are never candidates. Folder names only say where to look; no process is chosen by name or argv.
- **Abandoned** means nothing accepts on the session's core socket (the one its `core.lock` names, or `run/<session>.sock`), no process of yours holds a unix socket named `<session>.sock` or `<session>.holder.*.sock` (wherever it is bound, and whether or not its file still exists), and no recorded terminal's root has a parent other than launchd. When the process or socket table cannot be read, nothing is judged abandoned.
- **What counts** comes from hc's own record, `terminals.json`: each terminal hc did not record as finished, with its root's pid, `program_started_ms` and `scope`. Every hc build c11 shipped writes it, so sessions older than any c11 ledger are covered.
  - `root`: a process with that pid, your real uid, a kernel start time within 2 s of the recorded one, parented by launchd and leading its own session.
  - `session`: any process of yours in that root's session.
  - `scope`: the root is gone and no process holds its pid; the process is in the session that pid named, started after the root, and its environment's `HC_SCOPE` is exactly the recorded token. A process with no `HC_SCOPE` at all is not counted.
  - A process with a child in another session (it launched an app or a core that lives on its own) is never a leftover.
  - Anything else in those sessions is `unverified`: counted, never signalled. A session with only unverified processes is skipped as `unverified_only`.
- **Unreadable is never none.** A `core.lock` that is present but unsafe (a symlink, not yours, writable by group or others, an ACL) or that names anything but `<session>.sock` makes the session `unreadable`, as does a `terminals.json` whose start time is not a whole number that fits. Only a missing file counts as absent. Unreadable sessions are counted (`unreadable` in the counts and status, `abandoned_unreadable` in `hc-diagnostics`), so a zero is not claimed when something could not be read.
- **Over-protection is deliberate.** The holder and core checks match socket names, so a session named like a c11 app's own control socket (`c11h`, `c11`, `c11-debug`) reads as `core_running` while that app runs.
- **Ending.** `end-abandoned` reads the session again and refuses anything not abandoned (exit 7). It sends SIGHUP, then SIGCONT, each only to a process still the same pid and start time. After the grace it reads the session again and sends SIGKILL only to what that read lists, each checked again right before; a process that left the session, or a session that gained a core or holder meanwhile, gets none (`escalation_refused`, exit 5). A closing read that cannot confirm the result reports `remaining: null` and exit 5, never success. It never signals the caller, its ancestors or its session, never starts a core, and leaves hc's state files as they are.

`abandoned --json` prints `c11.core.abandoned/1`: `count` (`sessions`, `terminals`, `processes`, `unverified`, `unreadable`), `sessions[]` (`session`, `terminals: {recorded, left}`, `processes: {count, unverified, items[]: {pid, started_at, terminal, basis}}`), `skipped[]` (`session`, `why`: `current`, `core_running`, `holder_alive`, `unverified_only`, `unreadable`) and `protected`. The status object adds `abandoned: {sessions, processes, unreadable}`. `c11 hc-diagnostics` carries `abandoned_processes`, `abandoned_unreadable` and `abandoned_sessions[]` (no pids), refreshed at most every 30 s.

### Link the build host

`link <machine>` uses `~/.local/share/c11/atlas-via.sh`, rendered by the install guide (build-host section, step 2). It goes ahead only if that script runs c11's pinned hc for this session by its full path. It then runs `machine add --name <machine> --session <session> --via <script>`, with the name it was given, against the verified core and checks the link with `machine.list`. It never renders the script itself, because the build host's paths are the build host's.

## `--json`: schema `c11.core/1`

One object:

```json
{
  "schema": "c11.core/1",
  "generated_at": "2026-11-01T18:32:05Z",
  "machine": "Laptop",
  "session": "c11",
  "socket": "/Users/demo/.local/share/c11/run/c11.sock",
  "verified": {"ok": true, "pin": {"version": "0.1.16", "path": "…/herdr-core", "sha256": "c617…b922"},
               "checks": [{"check": "socket_owner", "ok": true, "detail": "uid 501"}, …]},
  "core": {"version": "0.1.16", "pid": 41207, "core_id": "…", "started_at": "…", "uptime_s": 11524},
  "holder": {"pid": 41219, "started_at": "…", "uptime_s": 274225, "terminals_owned": 14},
  "terminals": {"count": {"live": 14, "finished": 1, "starting": 0}, "items": [ … ], "refused": 0},
  "machines": [{"name": "local", "state": "local", "host": "Laptop"},
               {"name": "studio", "state": "connected", "version": "0.1.16", "pin_ok": true}],
  "actions": [{"name": "restart", "available": true},
              {"name": "reconnect", "machine": "studio", "available": false, "why": "connected"}]
}
```

Each terminal item is a record hc reported with its own address shape (`tN`, or `<machine>/tN`) whose `terminal.get` reply names that same address. Any other record is left out and counted in `terminals.refused`; the status list and `watch` say how many when there are any. Every string from hc or a linked machine that the status list, `show` or `watch` prints has its control characters shown as `\xHH`, and `--json` escapes DEL and the C1 controls as `\u00XX` besides the C0 controls JSON always escapes. A record time past 2100 reads as no time, and records with no time list last.

Each terminal item:

| Field | Meaning |
|---|---|
| `address`, `machine`, `state` | hc's address (`t1`, `studio/t4`), the machine it runs on, and `live`, `finished` or `starting`. |
| `agent` | `{name, status, status_at, turn}`, or `null` for a plain shell. |
| `foreground` | `{name, pid}`. The pid is `null` on another machine: remote pids are never read. |
| `cwd` | The foreground program's directory, else the terminal's. |
| `launched_at` | When hc started it (hc's `created_ms`). |
| `last_active` | `{at, source}`. `source: "tty"` is the last output on its tty, read locally from the tty's modification time. `"status"` is hc's last agent status change. The later of the two wins. `null` when neither exists. |
| `cpu_percent`, `memory_bytes` | The terminal's process tree, from one `ps` sample. `null` on another machine. |
| `size` | `{cols, rows}`, set by the client active last. |
| `screen_copy` | `exact`: hc holds a faithful copy of the screen. `rebuilt` (hc's `inexact`): after a core crash, hc redrew it from the last 1 MiB of output, so colors or layout can be off until the program repaints. |
| `c11_panel` | `{id, ref, workspace, link}`, from hc's `c11.panel` label (read only when it is a UUID) and c11's own saved panel map (read-only). `null` when no c11 panel shows it. |
| `open` | `{watch, take_over}`: the commands that open it outside c11. `null` unless live. |
| `exit_code` | Present for a finished terminal. |

A refusal is `{"schema", "ok": false, "session", "socket", "verified": {"ok": false, "checks"}, "error": {"code", "detail"}}`, and the exit code matches.

An action with `--json --yes` prints one object, `{"schema": "c11.core.action/1", "action", "ok", …}`. For `restart` that is `before`, `after`, `terminals: {adopted, lost, screens_exact}` and `elapsed_ms`.

**Stability:**
- Fields are only added within `/1`. A removal, rename or type change becomes `c11.core/2`. Readers ignore fields they don't know.
- Times are RFC 3339 UTC, durations are whole seconds, and pids are integers or `null`.
