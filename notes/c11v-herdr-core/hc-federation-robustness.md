# hc (herdr-core) audit: robustness and federation

2026-10-30. Read-only audit of the herdr-core checkout at `dbcdcff` (v0.1.14 plus four commits). Nothing was built or run.

Scope: process model and lifecycle, adoption, federation, the security boundary, limits, protocol stability. The terminal data path (attach internals, stitching, input, viewers, foreground semantics) is covered by another reader and appears here only where it bears on these questions.

Citations: source paths are under `crates/herdr-core/src/` (`platform/unix.rs` means `crates/herdr-core/src/platform/unix.rs`); `tests/…` is under `crates/herdr-core/tests/`; paths starting `crates/`, `docs/`, `schema/`, `scripts/`, `distribution/` or `.github/` are from the repo root.

**VERIFIED**: read end to end in the source (and a test, where one is cited). **INFERRED**: follows from the code plus OS behavior or reasoning; not exercised.

## Summary (ranked: what could make hc unfit as the base for every c11 terminal comes first)

1. **One holder runs every terminal.** A single `hold` process per core build owns every PTY (runtime.rs:240-254, api/run.rs:124-134). If it dies, every non-kept program is hung up and swept; `keep` only brings back a fresh `$SHELL` (runtime.rs:535-558, kept.rs:64-109, tests/m1.rs:349-364). The holder has no SIGTERM handler. VERIFIED.
2. **A core that misses the holders kills their programs.** Holders are found by scanning a socket directory derived from env (runtime.rs:265-287). A core started with a different XDG_RUNTIME_DIR, HC_SOCKET or config `socket` while the real core is down finds none and sweeps every live program by its HC_SCOPE token (runtime.rs:288-301). A core of another state dir that shares the socket directory KILLs every terminal it does not know (runtime.rs:384-390). Code VERIFIED; trigger INFERRED (tests/settings.rs:69-80 covers only the live-core case).
3. **Startup is brittle.** A corrupt terminals.json, machines.json, peers.json or core.json stops the core from starting; only docs.json is quarantined (runtime.rs:153-164, server.rs:100, paths.rs:59-68). Any holder handshake error aborts startup (runtime.rs:282), and a holder that accepts but never answers blocks it forever on an untimed read, before the client socket exists (runtime.rs:309-324). Code VERIFIED; wedge INFERRED.
4. **Ending a terminal kills more than a normal terminal does.** On exit or kill, every process still carrying the terminal's HC_SCOPE token, plus its descendants, gets HUP, TERM, then KILL. `nohup`, `disown`, `setsid`, and a tmux or screen server started there all die (sweep.rs:71-131, holder.rs:335-351, tests/ghosts.rs:63-72). VERIFIED.
5. **Every restart drops every client.** Update, `server restart`, SIGTERM and crash all close every connection with no CLOSE frame. c11 must reconnect, re-snapshot (seq restarts at 0) and reattach every terminal with a full repaint (server.rs:56-75). After a crash, screens are `inexact`, rebuilt from a 1 MiB tail (holder.rs:14, runtime.rs:394-434). VERIFIED.
6. **Environment and limits freeze at the first caller.** The core inherits env, cwd and rlimits from whoever first ran `hc`; holders, and cores a holder restarts, inherit them in turn (client.rs:173-187, platform/unix.rs:122-135, holder.rs:387). Default and kept-recovery shells are `$SHELL` without `-l`, skipping ~/.zprofile (platform/unix.rs:159-161, kept.rs:88). RLIMIT_NOFILE is never raised and the holder keeps 3 fds per terminal (platform/unix.rs:299-307), so a 256 soft limit caps it near 80 terminals. Code VERIFIED; cap INFERRED.
7. **Scale rests on single points.** One current-thread tokio runtime and one holder-reader thread share one global mutex for all output parsing and all requests (server.rs:38, runtime.rs:463-467). Each status-word change, label, create and finish rewrites all of terminals.json with fsync under that mutex (runtime.rs:207-213, viewers.rs:157). Every live terminal's foreground is polled in sequence every 500 ms (foreground.rs:155-174). No test runs more than a handful of terminals. Structure VERIFIED; cost INFERRED.
8. **Federation trust runs back to you.** A machine you added can `send` text plus Enter, `read`, `get`, `wait` and type notes into any local terminal that ever started work there, for that terminal's whole life (remote.rs:527-566, 1030-1037; notes.rs:259-283). With a plain shell as the parent, that is command execution here from the remote box. docs/security.md:47-57 does not say so. VERIFIED.
9. **Remote viewers relay through both cores and degrade on loss.** Every remote byte crosses the remote core, SSH and the local core's single thread (remote.rs:388-394). On loss the stream stays open, `[line to X lost; reconnecting...]` is written into the terminal byte stream, typed keys are dropped, and reattach is a full repaint without history (remote.rs:298-301, 416-423, 765). Event mirrors keep stale live records and no event reports the line state (events.rs:71-75). VERIFIED.
10. **Remote children survive a dropped line but can leak.** A drop never kills them. A parent that ends during the drop queues `$/orphaned` in memory only (runtime.rs:89, remote.rs:665-674), so a local core restart before the line returns leaves those children running for good. Code VERIFIED; leak INFERRED.
11. **"The API only grows" covers less than it seems.** tests/compat.rs:86-123 compares OpenRPC params and results with the last release only. Events, the framed wire, error kinds and the holder protocol are unchecked, and the holder's VERSION is sent but never compared (holder_proto.rs:2-9, runtime.rs:314-317, holder.rs:148-151). Upgrades are tested only from the previous release, on Linux (.github/workflows/ci.yml:121-162). VERIFIED.
12. **No phone-home, but writes beyond its state dir.** The binary runs `curl` only on an explicit update or remote install (releases.rs:36-60, cli.rs:582). It installs ~/.local/bin/herdr-core and an `hc` symlink on remotes (machines.rs:464-471), swaps its own binary in place on `hc update` (cli/update.rs:55-76), runs `loginctl enable-linger` on Linux unasked (platform/systemd.rs:215-238), and keeps each terminal's caller env overrides in plaintext terminals.json (api/run.rs:158). VERIFIED.

## Corrections to docs/c11v-herdr-core.md

1. Line 33, "Each terminal is a holder process that owns the PTY and screen": one holder process per core build owns every PTY. The core keeps the parsed screen; the holder keeps only a raw 1 MiB tail per terminal (holder.rs:1-4, 14; runtime.rs:240-254). VERIFIED.
2. Line 41, "The next `hc` call started a new core ... with its screen intact": the holder also restarts a crashed core by itself after a 3 s grace (holder.rs:367-391; tests/m1.rs:380-397). After a crash the screen is `inexact`, rebuilt from at most 1 MiB of recent output; older history is gone (runtime.rs:394-434; tests/m1.rs:255-279). VERIFIED.
3. Line 73, "an update to herdr cannot restart c11's core": true only if c11 runs its own `HC_SESSION` and state. In a shared session any hc binary can `server restart` or `update`, and the next core starts from that binary (cli/update.rs:77-85, client.rs:173-187). Terminals inherit HC_SESSION (api/run.rs:222-224), so a user's `hc update` typed inside a c11 terminal still targets c11's core. Code VERIFIED; scenario INFERRED.
4. Line 76, "Holders are children of the hc core": only of the core that spawned them, and only while it lives. Holders are started with `setsid` and reparented to launchd once that core exits (platform/unix.rs:122-135). VERIFIED. TCC attribution remains untested.
5. Line 34, "c11 needs no transport code of its own": true for bytes. But line state is not in the event stream (poll `machine.list`), mirrored records go stale while a line is down, and `terminal.list` and the events snapshot disagree about them (remote.rs:225-275, api.rs:231-270, events.rs:71-75). VERIFIED.
6. Line 56, documents "federated across machines": documents live on each core. `doc.get/set` take `on`, and doc events from added machines are relayed, but nothing replicates; a machine's documents are unreachable while its line is down (remote.rs:470-483, 827-864). VERIFIED.

## A. Process model and lifecycle

### A1. How the core starts (VERIFIED)

- Any CLI command that needs a core calls `connect_or_start` (client.rs:81-96). It connects to the socket; else checks `core.lock` for a core listening at another path (client.rs:104-114); else spawns one and polls up to 5 s for the socket (client.rs:189-200).
- `spawn_detached` runs `herdr-core serve` from the remembered executable path, removes `HC_SCOPE`, sets `HC_RUNTIME=1`, and otherwise passes the caller's whole environment and cwd (client.rs:173-187).
- macOS: `setsid()` in `pre_exec`, stdin and stdout to /dev/null, stderr appended to `core.log`. A thread in the CLI reaps the core if it exits while the CLI lives (platform/unix.rs:122-135). No double fork, no launchd.
- Linux with a user systemd manager at the default `/run/user/<uid>`: a transient user service via `systemd-run --user --collect --service-type=exec`, `KillMode=process`, `OOMPolicy=continue`, its env in a 0600 EnvironmentFile (platform/systemd.rs:65-118, 178-211). It then turns on linger (215-238). Without a manager: the setsid path.
- `serve()` takes a non-blocking `flock` on `state/core.lock` and returns quietly if someone holds it (server.rs:22-28). It writes its socket path into the lock file, loads its identity (`ioreg` on macOS, platform/unix.rs:236-243), adopts holders (`Core::start`), then unlinks and binds the client socket (platform/unix.rs:51-56). Everything runs on one current-thread tokio runtime (server.rs:38).

### A2. What the core, holders and programs inherit (VERIFIED)

- Core: the first caller's env, cwd, umask and rlimits. Holder: the core's at spawn time (runtime.rs:251). A core the holder restarts: the holder's (holder.rs:387). The first caller's environment persists until every holder has exited.
- Programs get `child_env(program_env(), caller env)` (api/run.rs:101, 213-235):
  - the core's env minus `SSH_CONNECTION`, `SSH_CLIENT`, `SSH_TTY` (platform/mod.rs:50-73);
  - on Linux only, session variables (DISPLAY, SSH_AUTH_SOCK, DBUS…) refreshed from the user manager at each spawn (platform/systemd.rs:242-265); macOS refreshes nothing;
  - the caller's `env` map; the CLI sends only TERM, TERM_PROGRAM, TERM_PROGRAM_VERSION, COLORTERM (cli.rs:321-323, api.rs:19);
  - HC_TERMINAL_ID, HC_TERMINAL_SOCKET, HC_SCOPE, PWD, HC_SESSION; LANG if missing; TERM=xterm-256color and COLORTERM=truecolor if missing; TERM_PROGRAM=ghostty when absent (api/run.rs:196-235).
- The program runs with `setsid()` and `TIOCSCTTY` on its PTY, after `env_clear()` (platform/unix.rs:261-297). The default program is `$SHELL` with no arguments: interactive, not a login shell (platform/unix.rs:159-161, api/run.rs:17).

### A3. Holders (VERIFIED)

- One current holder per core build takes all new terminals (runtime.rs:115-118, 240-254; api/run.rs:124-134). A holder of another build is told to DRAIN: it keeps its terminals, takes no new ones, exits when empty (runtime.rs:325-346; holder.rs:232-235).
- It is spawned like the core, listening on `<session>.holder.<8 hex>.sock` beside the client socket (runtime.rs:248-252, 256-261).
- It is every program's parent and reads every PTY continuously, keeping a 1 MiB tail per terminal. It uses three threads and three fds per terminal (holder.rs:263-331; platform/unix.rs:299-307).
- It supervises the core. With no core connected for `HC_HOLDER_GRACE_MS` (3 s), it starts one from its own remembered executable path, backing off grace×2^n, at most 60 s, counted over 5 minutes (holder.rs:59-62, 367-391). With no terminals and no core, it exits (holder.rs:375-377).
- It installs no signal handlers. SIGTERM or SIGHUP to a holder kills it and every program it runs; only the core treats SIGTERM as a restart (platform/unix.rs:218-223, server.rs:54-67). `killall herdr-core` therefore restarts the core and ends every terminal.

### A4. Stop, restart and signals (VERIFIED)

| Event | What happens | Evidence |
|---|---|---|
| SIGTERM to the core | Planned restart: stop accepting, unlink the socket, GOODBYE handover (holders clear their tails), write every screen snapshot and the registry, exit. A client or the holder (after 3 s) starts the next core. | server.rs:63-73, runtime.rs:751-767, holder.rs:236-256; tests/m1.rs:280-302 |
| SIGKILL to the core | Holders see EOF and mark a crash (holder.rs:184-188). Programs keep running and being read. The holder restarts a core after the grace; adoption is inexact. | tests/m1.rs:255-279, 380-397 |
| `server.restart` | Sets the restart flag, replies, then hands over exactly as SIGTERM. The CLI waits up to 30 s for the connection to close, then starts the next core. | api.rs:222-225, server.rs:71-73, 416; cli.rs:545-551, 802-805 |
| `server.stop` | Refuses new runs. Hangs up, terminates, then kills every live program (500 ms, 500 ms, 2 s); waits up to 6 s for execs and sweeps; GOODBYE shutdown (the holder sweeps every scope and exits); records `server_stop`. Kept terminals lose their programs too, but their records stay live ("parked") and get fresh shells at the next start. | runtime.rs:674-708, 770-787; holder.rs:243-252; terminals.rs:324-346; tests/keep.rs:355-362 |

### A5. `hc update` (VERIFIED)

- Without `--from`, it downloads `core/latest.json` (or one version's manifest) with curl, refuses another protocol generation without `--force`, downloads the archive and checks its SHA-256 against that same unsigned manifest (cli.rs:573-607, releases.rs:51-120). It never checks on its own (cli.rs:582).
- It refuses a binary owned by Homebrew, Nix or mise (cli/update.rs:57-64) and an older version without `--force` (67-69). It stages a copy beside the target, checks its `--version`, and renames it over `current_exe().canonicalize()` (platform/unix.rs:139-148).
- It then calls `server.restart`, waits for the close, and calls `server.status`, which starts the new core from the swapped path (cli/update.rs:77-85). The running core is not re-executed; it hands over and exits. `up_to_date` also restarts a running core older than the installed binary (cli/update.rs:33-48).
- Holders keep running their old binary image. The new core sees another build id (Linux: ELF build-id; macOS: dev:inode:mtime:size of the executable; client.rs:50-62, platform/unix.rs:113-116), tells them to DRAIN, and starts a new holder for new terminals (tests/m1.rs:399-426). A long-lived terminal keeps its old holder, and that holder's old code, for its whole life.

### A6. Holder crash, `keep`, parking (VERIFIED unless marked)

- A dead holder closes every PTY master. The kernel hangs up each terminal: the shell, as session leader, gets SIGHUP and the slave returns EIO (INFERRED from POSIX). The core sees the link close, sweeps every scope that holder ran, and finishes each live terminal with `holder_lost` (runtime.rs:535-558; tests/ghosts.rs:74-83). The last screen is saved to `screens/` and stays readable for a day (runtime.rs:603-611).
- Non-kept terminals are lost. `keep` (run `--keep`, or `terminal.keep`) changes only the record: loss by `holder_lost`, `stopped_by_restart`, `server_stop`, `host_shutdown`, or death by signal without an exit code leaves it live with no pid (terminals.rs:324-346, runtime.rs:575-581). Attach streams close with the loss reason (runtime.rs:600-602).
- Recovery runs every second (server.rs:41-47). It starts a holder if needed and spawns `$SHELL`, never the original command, in the last observed foreground folder, else the start folder, else HOME, with the current core env plus the saved caller overrides (kept.rs:43-110). Name, labels, size, parent and identity carry over; title, the reported flag, template and input overrides reset (kept.rs:86-99). A `restarted` event carries the new record.
- Backoff: 1.5, 3, 6, 12, 30, then 60 s forever, reset once a program has lived 10 s (kept.rs:9-25). Meanwhile send, keys, interrupt and attach return `unavailable` (terminals.rs:149-158).
- An exit with a code and an explicit kill stay final even when kept (terminals.rs:326-330; tests/keep.rs:5-20). Children that die with their parent are killed, not recovered (notes.rs:207-224).

### A7. Re-exec and fd handover (VERIFIED)

None. No self-exec and no SCM_RIGHTS anywhere in `src/`. Continuity comes only from holders outliving cores and from snapshots on disk.

### A8. Persisted state and corrupt files (VERIFIED unless marked)

Writes go to `<file>.tmp`, fsync, rename, with no directory fsync (paths.rs:70-75). On macOS, Rust's `sync_all` issues F_FULLFSYNC (INFERRED from std behavior). `read_state` returns the default only for a missing file; anything unreadable or unparsable is an error (paths.rs:59-68).

| File (state dir unless noted) | Holds | Written | Corrupt at startup |
|---|---|---|---|
| `core.lock` | flock; socket path | each start | content only read as a path hint |
| `core.json` | id, name, machine id | first start; clone detection | core does not start (server.rs:100) |
| `terminals.json` | whole registry, including caller env overrides | `save()` on ~20 call sites; `save_soon()` within 2 s | core does not start (runtime.rs:153) |
| `docs.json` | every document | each `doc.set` | renamed to `docs.json.bad`; starts empty (runtime.rs:154-161) |
| `machines.json` | added machines | add, rename, rm, version change | core does not start (runtime.rs:163) |
| `peers.json` | cores that dialed in, with note outboxes | peer joins, queued notes | core does not start (runtime.rs:164) |
| `screens/<t>.snap` | Ghostty snapshot | on finish; on handover (errors ignored, runtime.rs:763) | decode failure gives an inexact screen (runtime.rs:394-399) |
| `files/<t>/` | `put` uploads | `terminal.put` | not read at start |
| `execs/<token>` | exec scope tokens | exec start; removed at end | swept at start (exec.rs:103-116) |
| `core.log`, `holder.log` | stderr | appended, never rotated | not read |
| runtime dir | `<session>.sock`, `<session>.holder.<id>.sock`, `ssh-<hash>` | | stale holder sockets deleted on a refused connect (runtime.rs:283-285) |

A core that cannot start leaves the holder retrying with backoff while programs run unreachable (holder.rs:367-391). The CLI reports only "core did not start within 5 s". INFERRED.

## B. Adoption after a core crash

### B1. Discovery (VERIFIED)

The core lists the holder socket's directory for `<session>.holder.sock` and `<session>.holder.*.sock`, sorted, and connects to each (runtime.rs:265-287). A refused connect means a dead holder; its socket file is deleted. There is no pid file and no registry of holders. The directory is the only index, and its location comes from env and config (paths.rs:17-49, platform/unix.rs:88-95).

### B2. Handshake and matching (VERIFIED)

- HELLO, then WELCOME (instance, pid, build, `previous` = none, handover or crash, and the terminal list), then one TAIL frame per terminal (runtime.rs:309-324; holder.rs:147-182). Reads block with no timeout.
- A held terminal is adopted only if the registry has a live record with that id and that holder instance (runtime.rs:377-378). Anything else is killed and released (runtime.rs:384-390).
- After a handover: the saved snapshot is restored and the tail (output since GOODBYE) replayed; query replies in it go to the program (runtime.rs:394-409).
- After a crash, or if the snapshot fails to decode: a blank screen at the holder's size, the ≤1 MiB tail replayed, replies discarded, `screen: "inexact"`, and full-screen programs nudged (rows-1, then back) to repaint (runtime.rs:398-438, 448-461). Status reports in the tail are reapplied, counting at most one turn (runtime.rs:417-429; tests/m3.rs:196).
- **"inexact"** means the screen was rebuilt from recent raw output, not restored. Reads report `complete: false` (api.rs:356-358).
- Live records no holder adopted end as `stopped_by_restart` (kept ones park), and the scopes of every such terminal are swept again (runtime.rs:288-301). Exec tokens left by a crashed core are swept too (exec.rs:103-116).

### B3. What a crash keeps and loses

- Kept: names, labels, parent links, keep flags, status words and turns, all saved synchronously; documents, machines, peers and peer outboxes. VERIFIED.
- Lost or approximate (VERIFIED):
  - scrollback older than the 1 MiB tail, and any screen content drawn more than 1 MiB of output ago (holder.rs:14);
  - up to 2 s of title, size, foreground and status-message changes (runtime.rs:133, 215-232; tests/m1.rs:433);
  - everything held only in memory: notes from machines (`afar_notes`), queued `$/orphaned` messages (`machine_outbox`), wait bookkeeping (`last_send`, `waiting`, `messages`), kill intents, pending spawn replies (runtime.rs:42-93);
  - every client connection, attach stream, event subscription and call in flight;
  - running `machine.exec` children, which the next core sweeps; their output is lost (exec.rs:1-4).
- Queries a program sent while no core was running go unanswered. INFERRED.

### B4. Races

- **Two cores at once**: the flock admits one; the other exits silently (server.rs:22-28; tests/m0.rs:30-44). VERIFIED.
- **Old core still handing over**: it holds the flock through GOODBYE (up to 6 s per holder) and sweeps (up to 6 s twice) (runtime.rs:711-727, 743-748). A new core exits silently; the CLI that started it reports a 5 s failure; the holder starts a core 3 s after GOODBYE (holder.rs:367-391). Timing INFERRED.
- **Newest HELLO wins**: a holder drops its current core as crashed when another connects (holder.rs:152-156). The flock is per state dir, but the socket and holder directory come from XDG_RUNTIME_DIR, HC_SOCKET or config `socket` (paths.rs:28-35). Two cores with different state dirs that resolve the same socket directory both adopt: the second unlinks the first's socket (platform/unix.rs:52) and kills every terminal its registry lacks (runtime.rs:384-390). A config `socket`, shared by every session (docs/security.md:44), or one HC_SOCKET has no session part, so this can happen across HC_SESSIONs. Code VERIFIED; trigger INFERRED.
- **Empty directory**: a core whose env points at a socket directory without the real holders finds none and sweeps every live program by token (runtime.rs:288-301, sweep.rs:99-131). `listening_elsewhere` prevents this only while the real core is up (client.rs:104-114; tests/settings.rs:69-80). Code VERIFIED; trigger INFERRED.
- **Wedged holder**: one that accepts but never writes (stopped, deadlocked) blocks `Core::start` before the socket binds; later cores exit on the flock. Total outage until it is killed. INFERRED from runtime.rs:280-283, 309-324.
- **Stale "exact" screens**: GOODBYE handover clears holder tails before the snapshots are written, and write errors are ignored (runtime.rs:751-767, holder.rs:239-242). A crash or full disk in between leaves an older snapshot, which the next core restores as `exact` with only the new tail on top. INFERRED.
- **Snapshot format**: `restore` returns None for a snapshot another Ghostty version cannot decode (crates/ghostty-vt/src/lib.rs:692-709). After a handover the tail was cleared, so the fallback is a near-blank `inexact` screen and lost history. Whether hc's Ghostty pin keeps the format stable is unknown. INFERRED.

## C. Federation

### C1. `machine add`, end to end (VERIFIED unless marked)

1. In a terminal, the CLI first logs in interactively and leaves a shared ControlMaster: `ssh -S <socket dir>/ssh-<48-bit hash> -o ControlMaster=auto -o BatchMode=no -o ControlPersist=600 <target> exit` (cli/machine.rs:40-45; machines.rs:127-132, 160-174).
2. The core dials: `ssh -S <same> -o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -T <target> "sh -c 'p=$(command -v herdr-core) || p=$HOME/.local/bin/herdr-core; …; exec \"$p\" connect'"` (machines.rs:59-77, 139-155, 210-224). It rides the master if one is up, else authenticates with keys or an agent. It never prompts.
3. It sends `hello {generation: 1, …}` and takes the first line with id 1 as the reply, skipping banners, within 20 s (machines.rs:285-304). Failures map to `hc_missing`, `needs_login`, `incompatible` (another generation) or `unreachable` (machines.rs:305-358).
4. The core refuses its own id, a core id already added, or a taken name; then saves machines.json and starts the line (api.rs:572-629).
5. User-settable options: none in hc. Only `~/.ssh/config` Host entries, or `--via '<command>'`, which runs `sh -c '<command> "$1"' sh <line>` with none of hc's ssh options (machines.rs:59-64, 110-117). `HC_SSH` replaces ssh outright (a test hook, machines.rs:140-142).
6. The dialing ssh runs in the core's frozen environment (A2): its SSH_AUTH_SOCK and HOME decide which keys work. On Linux, a core started from an ssh login has SSH_AUTH_SOCK stripped from its own env (platform/systemd.rs:157-170), so agent auth for its lines fails without a ControlMaster. INFERRED.

### C2. The far side (VERIFIED)

`hc connect` connects to that session's core, starting it if needed, and pumps bytes both ways (cli.rs:808-827). The far core registers the dialer, whose framed hello names a `core`, as a peer (server.rs:176-178, remote.rs:589-613). The dialer then subscribes to every event there (remote.rs:335-337); the peer flag narrows that to the far core's own terminals (api.rs:531, events.rs:29-31).

### C3. Installing and updating hc there

- `machine add` offers an install only on `hc_missing` or `incompatible`, asking in a terminal or taking `--install` (cli/machine.rs:46-60). `machine update` always installs (cli/machine.rs:109-123). VERIFIED.
- It runs in the CLI, not the core. It probes `uname -sm`. Same OS and CPU: it pipes `current_exe()`'s bytes. Otherwise it downloads this version's release for that target locally with curl and checks its SHA-256 (machines.rs:424-460). VERIFIED.
- The remote script writes `$HOME/.local/bin/.herdr-core.new.$$` with `head -c N`, checks the byte count, checks that `--version` runs, `mv -f`s it over `~/.local/bin/herdr-core`, adds `~/.local/bin/hc` if no `hc` exists, then runs `herdr-core server restart` there so its terminals keep running (machines.rs:464-471; tests/machines.rs:93-116). VERIFIED.
- There is no version check before the overwrite, so `machine update` can downgrade a newer remote hc. No check VERIFIED; downgrade effects INFERRED.
- The dial prefers `command -v herdr-core` over `~/.local/bin`. An older herdr-core earlier on that PATH would be the binary that starts the remote core after its next restart. INFERRED.

### C4. Merging terminals and events (VERIFIED)

- **Addresses**: `localize` rewrites string values under the keys `address`, `parent`, `terminal`, `from` and `removed`, anywhere in a reply or event. `t7` becomes `box/t7`; our own id or name becomes bare; a known machine id becomes its name (remote.rs:1059-1091). It recurses into labels and status records, so a label named `terminal` or `address` on a remote terminal is rewritten too. Documents are exempt (remote.rs:1027-1028).
- **Events**: each line subscribes unfiltered on the far core. Each event is localized, applied to an in-memory mirror, and delivered to local subscribers under the local `seq` (remote.rs:449-502, events.rs:130-170). Per-machine order holds; local and remote events interleave as processed; remote `seq` is discarded.
- **`missed` on (re)connect**: the subscription's snapshot replaces the mirror. Changed or new records arrive as `created`, gone ones as `removed`, and unfiltered subscribers also get a local `missed` with a full snapshot (remote.rs:371-378, 431-446; events.rs:174-202; remote/tests.rs). A remote `missed` does the same (remote.rs:461-464).
- **While a line is down**: mirrors are not cleared, and no event says the machine is gone. The events snapshot still lists its terminals as they were (events.rs:71-75), while `terminal.list` asks each machine live with a 3 s cap and omits a down one (api.rs:250-266; tests/remote.rs:443-460). Line state is visible only through `machine.list` (remote.rs:160-183).
- `machine.rm` emits `removed` for each mirrored terminal and closes relayed viewers with an empty CLOSE (remote.rs:208-223).

### C5. Line loss and redial (VERIFIED unless marked)

- No bytes for `machine_timeout` (30 s) plus the heartbeat interval (15 s) gives the line up (remote.rs:349-365, config.rs:39-41). ssh's keepalive gives up after 60 s.
- After a line ends it redials at once; failed dials back off from 250 ms, doubling to 30 s (`HC_RECONNECT_MS`), reset on success (remote.rs:225-275). A far side that accepts and drops at once is redialed with no pause. INFERRED tight loop.
- Pending calls fail at once with "lost the line" (remote.rs:414-415). New calls wait up to `machine_timeout` while it redials (remote.rs:867-909). `terminal.wait`, and `run` or `send` with wait, ride out drops; a run is found again by a random `hc.run` label (remote.rs:941-994; tests/remote.rs:403-441). A caller that gives up sends `$/cancelRequest`, which the far core honors only for execs (remote.rs:131-142, server.rs:311-315).

### C6. A viewer of a remote terminal when the line drops (VERIFIED)

- The local stream stays open. The text `\r\n[line to <name> lost; reconnecting...]\r\n` is written into it as terminal output (remote.rs:416-423), so it lands on a full-screen program's display until the repaint.
- Keys, resizes and credits sent meanwhile are dropped, not queued (remote.rs:765). Size and display facts are remembered for the reattach (remote.rs:751-758).
- When the line is back, each waiting viewer is reattached on the same local channel with `history: 0` and `resumed: true`: a full first paint, no replay of what scrolled past, and no size lead until the viewer is active again (remote.rs:289-319; tests/remote.rs:355-401). It cannot resume without a repaint.
- If the terminal ended meanwhile, or the reattach fails, the stream gets CLOSE with an empty payload, not the exit reason (remote.rs:313-316). If the line never returns, the stream stays open forever.

### C7. Parents and children across machines (VERIFIED unless marked)

- A run with `--on` from inside a terminal sends the caller as `<our id>/t3` (remote.rs:858-862). The far core stores the parent as `<its name for us>/t3` and sets die_with_parent by default (api/run.rs:110-115, 137; remote.rs:1004-1007 for older cores).
- A successful remote run adds that machine to the local parent's `afar` set (remote.rs:1030-1037). Nothing removes it while the record lives.
- When the local parent finishes (not when a kept one is lost), `$/orphaned` goes to every machine in `afar`, or into an in-memory outbox while the line is down (runtime.rs:596-598, remote.rs:665-674). The far core kills its live children with die_with_parent whose parent matches, and only when the message arrives on a peer connection (remote.rs:678-697; tests/remote.rs:233-243).
- A dropped link alone never kills remote children: `peer_left` only forgets the line (remote.rs:635-638). After a local reboot the parents end as `stopped_by_restart` at the next start, the outbox flushes when the line connects, and the children die then (runtime.rs:288-293, remote.rs:328-330). A local core restart while the outbox holds a message loses it, and those children run on unparented. INFERRED.
- Children report back with `hc send` to `<prefix>/t3`. Notes for a parent whose core is away are queued in peers.json until it dials back (remote.rs:648-661; tests/remote.rs:245-257).

### C8. What `hello {core, calls_you}` grants (VERIFIED)

- Any client whose framed hello carries `core.id` and `core.name` becomes a peer. Nothing checks that it is a core, that it came over SSH, or that the id is real (server.rs:176-178, remote.rs:589-613). `calls_you` is stored as given.
- By claiming a real peer's id it replaces that peer's line, receives its queued outbox, can rename the stored peer, and can grow peers.json without bound (remote.rs:599-612).
- It gains: callers prefixed `<id>/` renamed to the peer's name (remote.rs:616-627), the right to send `$/orphaned` for that peer's terminals (remote.rs:678-697), and list and subscribe narrowed to local terminals (api.rs:234, 531). Nothing beyond what any local client already has (D).
- The other direction matters more. The machine you added may call only `terminal.send`, `get`, `read` and `wait`, plus `notes`, and only on local terminals whose `afar` includes it (remote.rs:527-566; tests/remote.rs:194-197). `send` accepts `force` and types raw text plus Enter into a terminal that does not report status, such as a shell (input.rs:156-177, notes.rs:142-163). Any process on that machine running as the hc user can do it through its own core (tests/remote.rs:190-192).

### C9. The relay path (VERIFIED)

Remote PTY → remote holder → remote core (parses, one thread) → `hc connect` → SSH → the local core's line task → the viewer connection's outbox (remote.rs:388-394). The local core does not parse remote output; it relays credit both ways (remote.rs:762-766). There is no direct path. Throughput is bounded by SSH and by each core's single runtime thread, and every machine shares the local one.

## D. Security boundary

VERIFIED unless marked.

- No authentication, tokens or capability scoping: every connection may call every method (rpc.rs:185-196, server.rs:383-420). Privacy rests on the 0700 directories hc creates (platform/unix.rs:98-101). Existing directories are not repaired and socket files are not chmodded (platform/unix.rs:51-56), as docs/security.md:21-24 says.
- Ways a client can affect terminals it did not create:
  1. `terminal.send`, `keys`, `interrupt` type into any terminal; `force` overrides `blocked` (api.rs:408-450, 501-520; input.rs:156-177).
  2. `terminal.attach` without `observe` types, resizes, and takes the size lead (api.rs:378-406).
  3. `terminal.kill`, `rm`, `label`, `keep`, `put` (api.rs:278-332, 479-499).
  4. `terminal.read`, `get`, `wait`, `events.subscribe` read any screen, history or fact.
  5. `terminal.run` with `parent` naming any terminal: the new terminal dies with it and has notes typed into it (api/run.rs:110-111, notes.rs:207-224).
  6. `machine.exec` runs any command; `file.read/write/edit` touch any path (exec.rs:133-224, files.rs:13-37).
  7. `doc.set` overwrites any document, guarded only by its version (api/doc.rs:9-39).
  8. `machine.add` with `via` runs an arbitrary local shell line (machines.rs:59-64); also `machine.rm`, `rename`, `connect`.
  9. `server.stop` ends every program; `server.restart`.
  10. A framed hello with `core` registers as, or hijacks, a peer (C8).
  11. All of the above on every added machine, through `on` and `machine/t7` addresses (remote.rs:827-864).
- `caller` is a client-asserted string: `HC_TERMINAL_ID`, else `ppid:<n>` (cli.rs:712-714). It sets the parent of a new terminal, routes notes, writes `<hc from="…">` tags on messages, ties a later wait to a send's turn, drives seen/news bookkeeping, and refuses self-attach (api/run.rs:110-120, notes.rs:142-163, api.rs:387-396, 437-440). Any client can claim any caller.
- Where the code goes beyond docs/security.md:
  1. Remote trust (docs/security.md:47-57) covers what you can do to a machine, not that the machine can type into and read local terminals that started work there (C8).
  2. Sessions (docs/security.md:35-45, 75-76): a config `socket` or a single HC_SOCKET has no session part (paths.rs:28-35), so HC_SESSION then selects neither a separate core nor separate holders (B4).
  3. Unmentioned: caller env overrides saved in plaintext for every terminal (api/run.rs:158, terminals.rs:26-28); automatic `loginctl enable-linger` on Linux (platform/systemd.rs:215-238); the `hc` symlink created on remotes (machines.rs:468).
  4. A code comment, not the doc: holder_proto.rs:2-3 says VERSION is checked; nothing compares it (F).

## E. Limits and resource behavior

### E1. Hard limits (VERIFIED)

| Limit | Value | Where |
|---|---|---|
| Frame payload (clients, cores, holder) | 16 MiB | wire.rs:8, holder_proto.rs:10 |
| Initial credit per stream | 256 KiB | wire.rs:24 |
| Stream backlog before a repaint (attach) or `missed` (events) | 4 MiB | wire.rs:26, 197-221 |
| Queued replies before disconnect | 64 MiB | wire.rs:28, server.rs:184-187 |
| Plain-mode event queue | 1024 events | events.rs:14 |
| Holder tail per terminal | 1 MiB | holder.rs:14 |
| Scrollback per live terminal, in the core | 5 MB (`history_mb`) | config.rs:20-21, 43-45 |
| Lines readable from a finished terminal | 1000 | api.rs:17 |
| Finished terminals kept | 500, and 24 h after a live parent saw it (`HC_RETAIN_MS`) | terminals.rs:9-10, 368-394 |
| Live terminals | no limit; u32 ids, never reused | terminals.rs:246-249 |
| Document | 1 MiB each; no count limit | api/doc.rs:11 |
| Status records per terminal | 256 | status.rs:10 |
| Concurrent execs | 16; timeout ≤600 s; 8 MiB stdout, 1 MiB stderr, 8 MiB stdin | exec.rs:17-22 |
| `file.read`/`write` | 8 MiB per call; 64 MiB file | files.rs:9-11 |
| `put` | 8 MiB | put.rs:6 |
| Names | 1-32 of `a-z 0-9 - _ .` | addr.rs:6-15 |
| Socket path | 103 bytes on macOS, 107 on Linux | platform/unix.rs:83-86, paths.rs:36-47 |
| Spawn answer | 10 s (`HC_SPAWN_MS`) | api/run.rs:165-166 |
| Machine call | 30 s plus any wait; dial 20 s; `terminal.list` per machine 3 s | config.rs:39-41, machines.rs:304, api.rs:257 |

Edges: a `missed` snapshot must itself fit the 4 MiB backlog or it is dropped with it; unfiltered snapshots include up to 500 finished terminals and every mirror (events.rs:148-154, wire.rs:199-206). The buffer for a remote's unfinished event line has no cap (remote.rs:449-456). Both INFERRED.

### E2. Timers

| What | Interval | Work | Where |
|---|---|---|---|
| Foreground watch | 500 ms (`HC_FOREGROUND_MS`) | For each live terminal in turn: a holder round trip (`tcgetpgrp`, 1 s timeout), then on macOS `proc_name`, `proc_pidinfo(VNODEPATHINFO)` and `sysctl(KERN_PROCARGS2)`, which copies the target's whole argv and env. An event and `save_soon` on change. Not `ps`. | foreground.rs:105-175, input.rs:308-317, holder.rs:218-222 |
| Kept recovery | 1 s | scans every record | server.rs:41-47, kept.rs:43-45 |
| Registry save debounce | 2 s | full rewrite plus fsync | runtime.rs:133, 223-232 |
| Event heartbeat | 15 s per subscriber | | server.rs:216-275 |
| Holder supervisor | 100 ms per holder | | holder.rs:367-372 |
| Machine silence | 45 s per line | | remote.rs:349-365 |
| Machine redial | 250 ms to 30 s | spawns ssh | remote.rs:225-275 |
| Parent notes | 60 s waits per parent with pending notes | | notes.rs:236-240 |

At 200 terminals the foreground watch alone is about 400 holder round trips and 1,200 process-info syscalls per second on the core's only async thread, whether or not anything changed. Structure VERIFIED; cost INFERRED.

### E3. Work that grows with the number of terminals (VERIFIED unless marked)

- Every event walks every subscriber, including one per `terminal.wait` in flight (events.rs:130-170, wait.rs:108-118). A subscriber that fell behind gets a full snapshot built for it. `changed.notify_waiters()` wakes every waiter (events.rs:169).
- `save()` serializes the whole registry (up to 500 finished plus all live) and fsyncs under the global mutex, on about 20 call sites: create, finish, remove, label, keep, status-word change, win32 toggle, kept spawn, `afar` insert and note steps (runtime.rs:207-213; viewers.rs:123, 157). Status-word saves run on the holder-reader thread and stall all output meanwhile. On macOS each is an F_FULLFSYNC (INFERRED).
- `doc.set` rewrites every document with fsync (api/doc.rs:25-26).
- `terminal.list` prunes (sorting all finished records) and asks every machine (api.rs:236-266).
- Each terminal exit or kill sweeps: a scan of the whole process table (macOS: `proc_listallpids`, then two calls per pid) plus an env read of every process younger than the token, repeated every 25 ms for up to 3 s while leftovers remain (sweep.rs:75-131, 156-175). 200 terminals ending together run 200 scans in parallel in the holder.
- Output costs per terminal, not per n, but all output for all terminals is parsed on one thread under one mutex (runtime.rs:463-467, viewers.rs:86-142).
- Startup reads every snapshot and replays every tail before the socket binds, while the CLI waits only 5 s (runtime.rs:265-306, client.rs:189-200). A large session can outlast that. INFERRED.
- Memory: up to 5 MB of scrollback per live terminal in the core, up to 1 MiB of tail per terminal in the holder, and three threads per terminal in the holder.

## F. Protocol stability (VERIFIED unless marked)

- `GENERATION = 1` (api.rs:15). A hello with another generation fails `unsupported_generation`; omitting it is accepted (api.rs:168-175). `hc update` refuses another generation without `--force` (cli.rs:586-597). A remote of another generation shows `needs_update` (machines.rs:351-356, remote.rs:269).
- `hello` returns `version`, `methods` and `features` (`framed`, `attach`, `events`, `status`, `shell`) for negotiation at runtime (api.rs:16, 176-183). The core gates remote own-shell runs on `shell` (remote.rs:1011-1018).
- tests/compat.rs compares `schema/released.openrpc.json` (the last release; today identical to 0.1.14's `hc.openrpc.json`) with the code. It fails on a removed method or param, a newly required input, an input that accepts less, or a result that loses a field or changes its type (compat.rs:46-123). It reads only params and results.
- Not covered: the `errors` lists; event notifications, their types and data shapes, `missed` and `heartbeat`; framed mode (frame kinds, credit window, CLOSE reason JSON, first paint contents); core-to-core extras (`$/orphaned`, `notes`, `$/cancelRequest`, hello's `core` and `calls_you`); on-disk state; the holder protocol.
- Holder protocol: `VERSION = 1` travels in Hello and Welcome and neither side compares it (holder_proto.rs:9; runtime.rs:309-317; holder.rs:147-151). Compatibility rests on serde defaults (`build` is `#[serde(default)]`, holder_proto.rs:82-83) and unchanged frame kinds. A new core must speak every older holder protocol while an old holder drains, and crash adoption across builds takes the same path. scripts/upgrade-test.sh and tests/upgrade.rs:68-138 test only the previous release to this tree, and only on Linux CI (.github/workflows/ci.yml:121-162).
- Saved state "only moves forward" (cli.rs:94-96). Nothing uses `deny_unknown_fields`, so an older core reads newer files and drops unknown fields on its next write. INFERRED.
- What c11 must track if it pins one hc version:
  1. The generation, and `version`/`methods`/`features` on every connect, because the core it reaches may not be the binary it ships (G1).
  2. The OpenRPC methods it calls (guarded by compat.rs).
  3. Event types and data as tabled in schema/README.md:83-147, plus `missed` and `heartbeat` behavior (unguarded).
  4. Framed mode: frame kinds; 256 KiB initial credit on every stream, event channels included, so c11 must CREDIT event bytes as remote.rs:384-387 does; the 4 MiB repaint rule; CLOSE reasons (unguarded).
  5. Error kinds in `data.kind` (unguarded).
  6. Terminal record fields (`Public`, terminals.rs:397-447), guarded through result schemas.
  7. Ghostty snapshot compatibility between the hc versions it moves across (B4).

## G. Surprises for a c11 maintainer

1. **The core belongs to the user and session, not the app.** Any hc binary can start, restart or update it, and the holder restarts it from whatever path it remembers (holder.rs:387, client.rs:15-20). c11 needs its own HC_SESSION and state dirs to keep a user's hc out; even then a user's `hc update` inside a c11 terminal targets c11's core. Code VERIFIED; scenario INFERRED.
2. **`hc update` overwrites `current_exe()` in place** (cli/update.rs:55-76). Run from a binary inside c11.app, it would rewrite a signed bundle. Only Homebrew, Nix and mise paths are refused (client.rs:30-35). VERIFIED.
3. **macOS: no launchd integration.** The core is a plain setsid process, gone at logout, started again only by the next hc call (platform/unix.rs:122-135). Paths follow XDG even on macOS: `~/.local/state/herdr-core/<session>/` holds state and, without XDG_RUNTIME_DIR, the sockets (platform/unix.rs:75-95). Release builds for macOS are not signed or notarized; only Windows has a signing job (.github/workflows/release.yml:32-37, 109-160). VERIFIED.
4. **macOS-specific code.** `ioreg` runs at every start for the hardware UUID; a changed UUID (a disk moved to another Mac) wipes terminals, screens, peers, files and execs (platform/unix.rs:236-243, server.rs:90-121). Sweeps and foreground use `mach_absolute_time`, `proc_listallpids`, `proc_pidinfo`, `proc_pid_rusage` and KERN_PROCARGS2 (sweep.rs:31-37, 155-180; foreground.rs:105-151). macOS hides the env of Apple-signed binaries, so a `nohup /bin/sleep` orphan escapes the sweep while a `nohup node` one does not (sweep.rs:94-97). VERIFIED.
5. **File descriptors.** No `setrlimit` anywhere in `src/`. The holder holds three fds per terminal. A holder started under macOS's default soft limit of 256 would fail spawns near 80 terminals. INFERRED; experiment 1 below.
6. **TCC.** Holders and programs descend from whoever first started the core, not from c11.app unless c11 starts it. Which app macOS charges for camera, file or automation prompts is untested. INFERRED.
7. **Headless size.** With no active viewer, a terminal snaps to 200x120 (config `headless`) and its program gets SIGWINCH (viewers.rs:254-272). c11 must keep a viewer on hidden terminals, or set `headless`. VERIFIED.
8. **Injected env.** Programs see TERM_PROGRAM=ghostty unless the caller sets it; waited runs get PAGER, GIT_PAGER and GH_PAGER set to `cat` (api/run.rs:24-29, 228-233). VERIFIED.
9. **Secrets on disk.** Env passed in `terminal.run.env` is saved in plaintext in terminals.json for every terminal, kept or not, until the record expires (api/run.rs:158, terminals.rs:26-28; tests/keep.rs:105-133). VERIFIED.
10. **Writes outside the state dir**: the runtime socket dir and ssh control sockets; `$TMPDIR/hc-download-*` during downloads (releases.rs:122-138); the swapped binary on update; `~/.local/bin/herdr-core` and `~/.local/bin/hc` on remotes; on Linux `/run/user/<uid>/hc-*/environment` and linger (platform/systemd.rs:140-153, 215-238). No shell rc edits and no PATH changes from the binary. The install script writes only `~/.local/bin` and tags its download URL `?src=install|update` for a release counter (distribution/install.sh:53-63). VERIFIED.
11. **No phone-home.** The only network access is `curl` on an explicit `hc update`, or on a cross-platform `machine add --install` or `machine update` (releases.rs:36-60, cli.rs:582, machines.rs:447-460). No update checks, no telemetry. VERIFIED.
12. **Observability.** Logs are unstructured `eprintln!` lines with no timestamps, appended to core.log and holder.log and never rotated (client.rs:168, runtime.rs:251). There is no command to rebind a socket unlinked under a live core; the remedy is SIGTERM to the core, a planned restart. INFERRED; compare c11's own "Restart CLI Listener".
13. **pkill patterns.** A pattern matching the holder's path (c11's scripts/rebuild.sh runs `pkill -9 -f c11`) would end every terminal if hc runs from inside c11.app. INFERRED.
14. **Test harness.** Real binaries, real PTYs and processes, isolated XDG dirs per test under /var/tmp, a 30 s watchdog per test binary, and a leak check that scans every process's env after each test; on macOS it finds nothing because other processes' env is unreadable (tests/common/mod.rs:19-76, 143-223). Machines run through a fake `ssh` script (`HC_SSH`) that starts the far core locally; drops are simulated by restarting the far core with a `down` file, freezes with SIGSTOP (tests/common/mod.rs:225-257; tests/remote.rs:24-64). tests/fake_tui.py is a 91-line full-screen fake agent for the stitch tests only, which macOS CI skips (.github/workflows/ci.yml:110-119). Not exercised anywhere: real SSH (ControlMaster lifetime, host keys, agents), real network partitions, more than a handful of terminals, output floods across many terminals, corrupt state at startup, a wedged holder at startup, cores with mismatched env, a crash during handover, upgrades on macOS or across more than one release. VERIFIED.

## Experiments that would settle the INFERRED items

Run each in an isolated session (own HC_SESSION, scratch XDG dirs, short socket path), as the brief requires.

1. **fd cap**: from a shell with `ulimit -n 256`, start a core and 120 `sleep` terminals; watch for spawn failures and EMFILE in holder.log.
2. **Env-mismatch kill**: start a core under XDG_RUNTIME_DIR=A with three terminals, SIGKILL the core, then within 3 s run `XDG_RUNTIME_DIR=B hc ls`; check whether the programs survive.
3. **Wedged holder**: SIGSTOP the holder, SIGKILL the core, run `hc ls`; expect a 5 s failure and no core until SIGCONT.
4. **Corrupt state**: truncate terminals.json with the core stopped and the holder alive; confirm the start failure and the holder's backoff in core.log.
5. **Scale**: 200 terminals each flipping OSC 7501 status at 1 Hz; measure core CPU, fsync rate (`fs_usage`), and keystroke p99 against the 51 µs baseline.
6. **Line loss on a Prime sandbox**: block the path with `pfctl`; time the silence detection, see the banner land in a viewer, confirm reattach and the stale mirror.
7. **Snapshot compatibility**: update between two releases with different Ghostty pins and compare screens after the handover.
