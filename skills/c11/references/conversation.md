# Conversation primitives reference

## Lifecycle journal

The journal records structural observations for an exact `(panel UUID, agent kind,
session ID)` owner. It does not store conversation content or make a session
resumable. See [append API](api.md#structural-lifecycle-append).

Processing follows the app-assigned sequence. Comparable native time can reject
late evidence, and tool activity can only refresh a working turn. In particular,
a late PreToolUse after Stop cannot restart working. A new native submission
boundary can start the next turn. Missing or unsupported evidence remains
unknown/advisory; pressing Esc alone does not prove interruption succeeded.

An observed question, approval, or plan-review request is blocked independently
of unread notifications. Seeing a panel can clear unread, but it does not answer
the request. Existing flag and suppression policy still controls presentation.
Live journal-managed sessions receive derived `activity` from the committed fold;
legacy shell/notification writes cannot override it. Once disconnected, legacy
shell and unmanaged-agent activity can update again while historical attention
remains visible. Claude PostToolUse for AskUserQuestion and ExitPlanMode resolves
only the matching `tool_use_id`. A Claude hook-rank Stop with the same nonempty
`prompt_id` resolves that turn's approval; an unrelated or uncorrelated Stop does
not resolve it.

Restart projects old blocked/error evidence as **unconfirmed** and disconnected.
Old working is not present liveness. Only matching exact restored ownership may
reattach the evidence, and fresh supported events reconcile it. Offline spool
drain cannot replace newer live evidence. No automatic reply, resume or focus
change is implied.

Storage is c11-owned SQLite WAL under
`~/Library/Application Support/c11/journal/<bundle-id>/`. History retains 14 days
within a 256 MiB physical budget for database, WAL, SHM and spool. Current state
has a separate 16 MiB budget; an old open ask survives history pruning. If
protected state or the 24-hour receipt floor prevents recovery, new admission
fails with degraded health. Analytics must disclose retained coverage rather
than reconstructing expired intervals. Spooling is bounded best effort, not a
lossless delivery promise.

This file expands [SKILL.md](../SKILL.md). Loaded on demand; the top-level skill carries the brief.

## What it is

A `Conversation` is a persistable pointer to **a continuation of agent work**. Owned by c11; survives TUI process death and c11 restarts. Each panel hosts at most one *active* `ConversationRef` (v1; the schema leaves room for history). Refs are keyed by an opaque, per-kind id whose interpretation is delegated to a per-kind strategy.

```
Panel ──hosts──▶ Conversation ──interpreted-by──▶ ConversationStrategy
                        │
                        └── carries: kind, id, capturedAt, capturedVia, state, payload, cwd
```

## CLI verbs

```
c11 conversation capture-runtime
c11 conversation claim --kind <k> [--cwd <path>] [--id <id>] [--expected-resume-id <uuid>] [--ttl-ms <n>]
c11 conversation push --kind <k> --id <id> --source <hook|scrape|manual>
                      [--state <alive|suspended|tombstoned|unknown|ended>]
                      [--cwd <path>] [--reason <text>]
                      [--payload <json> | --payload @<path>]
c11 conversation tombstone --kind <k> --id <id> [--reason <text>]
c11 conversation list [--panel <id>] [--json]
c11 conversation get [--panel <id>] [--json]
c11 conversation clear [--panel <id>]
c11 conversation resume (--panel <id> | --all-skipped) [--dry-run] [--json]
c11 conversation find [query] [-a] [--limit <n>] [--session <uuid>] [--open] [--json]
```

| Verb | Use |
|------|-----|
| `capture-runtime` | Codex-only exact capture. Run from the target agent's own tool subprocess with no arguments; reads `CODEX_THREAD_ID`, agreeing c11 panel aliases, and actual cwd from that process. |
| `claim` | Wrapper launch boundary. OpenCode requires a socket-authenticated foreground TUI claim; that claim alone writes its TUI PID and recovery-store metadata. Codex plain/mismatch invalidates its prior exact lifecycle while a matching internal expected-resume id preserves it. |
| `push` | Hook or operator push of the real id. Accepts only `hook`, `scrape`, or `manual`; runtime capture and wrapper claims use dedicated verbs. Reserved OpenCode TUI/recovery keys are rejected, and generic pushes of any kind cannot replace an authenticated v2 route. |
| `tombstone` | Mark the panel's active ref as tombstoned. Operator-initiated; not auto-resumable. |
| `list` | List captured conversations (process-wide; v1 has no per-workspace partitioning). Filter with `--panel`. `--json` for structured output. |
| `get` | Inspect the active ref + `can_resume` + `diagnostic_reason` for a panel. The debugging entry point. |
| `clear` | Wipe the panel's conversations. Forces a fresh launch on next workspace open. |
| `resume` | Recover panels this launch did not resume. Reruns the shared resume decision for every panel the launch skipped (`--all-skipped`) or for one named panel, and types the resume command only into a panel nobody has used since launch (no operator keystroke, shell not running a command). `--dry-run` reports without typing. Each JSON row carries `outcome` (`scheduled`, `would_resume`, `refused`, `skipped`), `skip_code`, `reason`, and the `command`, so a refused panel can still be resumed deliberately with `c11 send`. A scheduled resume is typed after the usual stagger and rechecked then (still untouched, no live writer elsewhere, not already resumed); a later `--dry-run` shows what happened. |
| `find` | Search this Mac's Claude Code and Codex transcripts. See [Find past sessions](#find-past-sessions). |

**Panel resolution.** `claim`, `push`, `tombstone`, `list`, `get`, and `clear` resolve `--panel` from `C11_PANEL_ID` if unset. `resume` needs `--panel` or `--all-skipped` explicitly. `find` does not take `--panel`. **No focused-panel fallback** (the silent-misroute footgun the architecture exists to avoid). If a panel-scoped verb has neither the flag nor the env var, it errors out with `missing_surface`.

**`--payload`** accepts inline JSON or `@<path>` to read JSON from a file (mirrors the `HOOKS_FILE` ergonomics in `Resources/bin/claude` so hook authors writing bash do not have to shell-quote JSON).

**Codex runtime capture has no identity flags.** `capture-runtime` rejects every argument, alias disagreement, malformed/missing environment identity, stale/non-terminal/non-live panels, and panels not owned by the addressed c11 socket instance. This is cooperative causal evidence from the target process, not an adversarial authentication boundary. Orchestrators must instruct each Codex agent to run the command itself; they must not expand or relay a child thread ID.

**State verification requires a recovery mode.** Use `c11 state verify --mode clean|dirty|no-resume [snapshot-path]`. The mode is explicit because a snapshot path cannot reveal the app's sentinel/relaunch policy. Clean evaluates persisted exact ownership; dirty additionally requires on-disk transcript evidence (including direct exact Codex lookup without a recency window); no-resume always reports a policy skip.

## Find past sessions

`c11 conversation find` searches this Mac's Claude Code and Codex transcripts, including sessions that were started outside c11. The scan reads files. It writes nothing under `~/.claude` or `~/.codex`. The query, titles, and prompt text stay in the CLI process: they are not sent on the socket and they are not written to c11's event stream.

It looks at one directory level of `~/.claude/projects/<slug>/<uuid>.jsonl` plus `~/.claude/history.jsonl`, and at `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` plus `~/.codex/history.jsonl`. Nested Claude subagent transcripts are out of scope.

The default match is the title, the working directory, and the user's prompts. A case-insensitive substring is enough. The query is one word, so quote a phrase. `-a` also searches transcript text. A file larger than 8 MiB is counted and its body is not scanned. Every other file is read in 64 KiB chunks, at most 1 MiB, and that file's read stops when the phrase matches. Assistant text matches only with `-a`. While `-a` runs, progress goes to stderr and stdout stays clean for `--json`: `find: files=%lld matches=%lld bytes=%lld`. The numbers are counts only. With `-a`, a listing stops once it has `--limit` matches, newest first, and `--json` sets `"truncated": true` when files remain unread. With `-a`, `--open` stops at two matches, so a second match still refuses and the scan does not continue. With `-a`, `--session` stops when that one id is resolved. Without `-a`, `--open` still counts every match.

An empty query lists transcript files, newest first, 30 rows. It does not list history-only ids. `--limit` is a whole number from 1 to 200. When more matches exist than the limit, `--json` sets `"truncated": true`. `--session <uuid>` keeps that id. A query and `--session` both have to match.

Each row is harness (`claude` or `codex`), the full session id, state, cwd, last active in local time, and title.

| State | Meaning |
|-------|---------|
| `live in panel:N` | The session is on a panel that still exists. A placeholder or a tombstoned ref is not live. |
| `idle` | The transcript is on disk and the session is not live. |
| `gone` | History names the id and the transcript file is gone. A gone row appears only when a query matches. |

`--json` is the stable shape. Key names are the contract. Key order is not. `last_active` is ISO-8601 with the local offset. Human rows use `yyyy-MM-dd HH:mm zzz`. `cwd` is omitted when it is unknown. A live row also has `panel_id`, `panel_ref`, `workspace_id`, `workspace_ref`, and `link`. `link` is `c11://panel/<uuid>`, the same URL `c11 link --panel <uuid>` prints. Human rows print it too, so the operator can Cmd-click that panel. `panel.focus` does not change the selected workspace. The link is how a person opens the workspace that holds the session.

```json
{
  "query": "zephyr",
  "deep": false,
  "truncated": false,
  "skipped": {"corrupt_lines": 0, "huge_files": 0, "unreadable_files": 0},
  "results": [
    {
      "harness": "claude",
      "kind": "claude-code",
      "session_id": "11111111-1111-4111-8111-111111111111",
      "state": "idle",
      "cwd": "/Users/test/proj",
      "last_active": "2026-10-31T15:04:00-07:00",
      "title": "Lattice notes"
    }
  ]
}
```

When a skip count is nonzero, human output prints one stderr line, `skipped: corrupt_lines=%lld huge_files=%lld unreadable_files=%lld`. JSON puts those counts in `skipped`. An empty list prints `(no sessions)` and exits 0. A missing history directory is an empty result, not an error. A corrupt line, an unreadable file, or a file over 8 MiB is counted and skipped. The skip object is counts only.

### Open one session

`--open` acts only when exactly one session matches. That count is the full match count, not the `--limit` page. Zero matches exits nonzero with `No session matched.` More than one match prints the rows and exits nonzero: `find --open needs one session. N matched. Pass --session.` A gone session is refused. A session id that is not a UUID is not resumed.

**Live.** Focus that panel inside the workspace that already holds it. The command is `panel.focus` with that panel id and that workspace id. It does not change which workspace is selected, and it does not open a second copy. Human output: `Focused panel:N in workspace:M. The selected workspace was not changed.` The next line is the `c11://panel/<uuid>` link when the panel id is a UUID. JSON includes `"action": "focus"`, `"link"`, and `"selected_workspace_unchanged": true`.

**Idle.** Open a new terminal in the caller's workspace (`$C11_WORKSPACE_ID`, or `--workspace`), in the session's cwd, and run the same resume line `c11 conversation resume` types. The new panel is not focused, and the selected workspace does not change.

- Claude: `cd '<cwd>' && claude --dangerously-skip-permissions --resume '<uuid>'`
- Codex: `cd '<cwd>' && codex resume --yolo '<uuid>'`

Human output: `Resumed <session id> in panel:N.` JSON includes `"action": "resume"` and `"command"`.

`--open` needs a running c11. If the socket is down, or the live-session read fails, it refuses. Listing works with c11 down. Those rows are `idle` or `gone`, because liveness could not be checked.

Listing reads ids from `window.list`, `workspace.list`, `panel.list`, and `conversation.list`. `--open` sends the panel id and workspace id to `panel.focus`, or the cwd and the resume command to `panel.create`. It never sends the query, the title, or prompt text, and it never calls `workspace.select`.

```bash
c11 conversation find zephyr-needle --json
c11 conversation find zephyr-needle -a --limit 50
c11 conversation find --session 11111111-1111-4111-8111-111111111111 --open
```

## Lifecycle states

| State | Meaning |
|-------|---------|
| `alive` | TUI is running; strategy has confidence the ref is the active conversation. |
| `suspended` | c11 is shutting down or has shut down cleanly; resume on next launch is expected. |
| `tombstoned` | Explicitly ended (operator action, or scrape confirmed the session file is gone for a strategy that can be confident — Claude with hook history). Not auto-resumable. |
| `unknown` | Strategy cannot classify the ref; `resume()` returns `.skip` until pull-scrape promotes it. The resting state for refs found after a crash, ambiguous Codex matches, etc. |
| `unsupported` | Ref kind not registered in this binary's strategy registry. Retain (don't tombstone) so a future c11 release with the strategy can promote it. |

## Capture sources

| Source | When written |
|--------|--------------|
| `hook` | Push from a TUI lifecycle hook (e.g. Claude Code SessionStart). Causal evidence. |
| `runtimeEnv` | Exact identity read by the target agent's own tool subprocess. Codex uses `CODEX_THREAD_ID`; causal and sticky against inferred wrapper/scrape observations. |
| `scrape` | Pull from on-disk session storage (`~/.claude/projects/<cwd-slug>/`, `~/.codex/sessions/`, `~/.pi/agent/sessions/<cwd-slug>/`, `~/.omp/agent/sessions/<cwd-slug>/`). Resolves a placeholder to a real id at restore. |
| `manual` | Explicit operator action (`c11 conversation push --source manual`). |
| `wrapperClaim` | Internal claim provenance written only by `conversation claim` (never generic push). Expiry-bounded for Codex; legacy wrappers may still use best-effort claims. |

Reconciliation first respects evidence strength: causal `runtimeEnv`/hook identity cannot be displaced by inferred scrape/manual observations. Conflicting causal ownership is quarantined rather than timestamp-won. Within an evidence tier, timestamp and source priority reconcile updates. For non-Codex kinds, wrapper claims retain the legacy conservative rule and never displace a non-wrapper source (so a delayed Claude claim cannot overwrite its SessionStart hook). Codex has one deliberate interactive-process-boundary exception: a plain launch or mismatched explicit resume atomically replaces its prior exact ref with a placeholder until causal runtime capture; only an exact matching `codex resume <uuid>` intent preserves that ref.

## Strategies

| Kind | Resume tier | Capture | Resume action |
|------|-------------|---------|---------------|
| `claude-code` | Strong (push-id deterministic) | SessionStart hook → `c11 conversation push`. Pull-scrape `~/.claude/projects/<cwd-slug>/` is the fallback when the hook was missed. | `claude --dangerously-skip-permissions --resume <id>` (id shell-quoted) |
| `codex` | Exact, causal | Before its expiry-bounded claim, the wrapper atomically writes a c11-owned per-panel launch-boundary marker beside the active socket. The marker survives acknowledged and failed/expired claims so a crash before autosave cannot expose the older on-disk owner. The listener records its actual post-fallback socket path per bundle, allowing startup to find that marker before the new listener binds. Marker replay is retained intentionally and is harmless after a durable placeholder or newer runtime capture; the next launch overwrites it. The running target executes `capture-runtime`, which records its exact `CODEX_THREAD_ID`. `CodexScraper` remains a conservative crash fallback when causal capture was missed. | `codex resume --yolo <id>` (specific id; never `--last`) |
| `pi` | Exact, ambiguity-aware | Wrapper-claim placeholder → `PiScraper` resolves the real id from the cwd slug dir, claim-time + activity floors narrowing past stale sessions. | `pi --session '<id>'` (specific id) |
| `omp` | Exact, causal after persistence | Wrapper watches OMP's tty pointer and, once the first message creates its JSONL, pushes the exact UUID, effective cwd, and path. The cwd scraper remains a legacy fallback. Empty sessions stay placeholders. | `omp --auto-approve --resume='<id>'` (specific id) |
| `opencode` | Exact displayed root | v1 plugin pushes the exact root; 2.0.25 TUI plugin reads its own displayed route and session row, then captures directly from the reserved foreground TUI process over c11's socket. Route changes first unbind the old identity; child and unresolved routes remain placeholders. The v2 claim is socket-worker dispatched for literal panel UUIDs and binds the TUI PID plus process start time, so an exited or reused PID cannot keep owning a session. Final panel close clears its ref; moves and app termination preserve it. Inherited tool-subprocess panel variables are not route proof. Crash recovery checks the exact requested ID in supported `session_v2` or legacy `session` tables, honoring `OPENCODE_DB` absolute and data-directory-relative overrides; `:memory:` is unverifiable. Disabling native mail still loads exact identity capture. Busy native mail stays buffered until the route becomes ready; typed fallback rereads identity immediately before input. Unknown versions keep baseline lifecycle tracking but receive no version-specific plugin injection. | `cd '<dir>' && opencode --auto -s <id>` — `.skip` for placeholders |
| `grok` | Exact after persistence | PATH wrapper injects a UUID, then pushes it with the exact session directory after the first message persists. Empty sessions remain uncaptured. | `grok --always-approve --resume '<id>'` |
| `kimi` | Fresh-launch only | Wrapper-claim placeholder | `kimi --auto` (process launch) — `.skip` for placeholders |
| `github-copilot` | Fresh-launch only | Wrapper-claim placeholder | `copilot --allow-all --autopilot` (process launch) — `.skip` for placeholders |

Every resume line carries its agent's auto-approve flag, the same one its launch command uses (`AgentAutoApprove` in `Sources/AgentManifest.swift`). A resumed agent has the permission posture of a freshly launched one. `pi` is the exception: its CLI has no auto-approve-all flag, so it prompts on launch and on resume alike.

## Crash recovery — what it guarantees per kind

On launch c11 reads a per-bundle dirty/clean **shutdown sentinel** (`~/.c11/runtime/shutdown.<bundle>.{dirty,clean}`); `.dirty` (or missing) means the last run did not shut down cleanly (a crash, `kill -9`, a reboot). The startup audit then runs in phases, and **each restored panel waits only for the phase its own decision needs**:

1. **Seed** the store from the last snapshot and seed the per-panel **activity floor** (`last_activity_at`). This step is in memory and is the only one launch blocks main on; every store read that feeds a snapshot waits for it too, so an unseeded store is never persisted.
2. **Classify.** Codex launch-boundary markers apply first. Dirty launches then check each `.alive`/`.suspended` ref's transcript off the store actor (bytes never read; one walk of `~/.codex/sessions` covers every Codex ref). Verified → `.suspended` with `diagnostic_reason = "crash recovery: transcript verified on disk"`; missing → `.unknown` with `"crash recovery: transcript not found"`. Refs already `.unknown`/`.tombstoned` are untouched, so `/exit`-ended sessions never auto-resume. `app restart --no-resume` marks every ref `.unknown` with reason `app restart --no-resume`, a policy decision that persists. Panels with exact causal refs (hook or runtime capture) decide here and resume; they never wait on a scrape.
3. **Scrape only what needs it.** Only panels whose ref is missing, a placeholder, or inferred depend on the scraper, and only their kinds are collected (Codex keeps its causal panels in the batch so their ids stay reserved and the same-cwd rule still applies). Each kind scrapes and commits on its own. Such a panel is decided once when its scrape lands (one `conversation.resume.decision`), and the command is typed only if nobody has used the panel since launch (no operator keystroke, and its shell idle at the prompt or not yet started); otherwise it skips with `panel-in-use`.

**A failed or slow phase writes nothing.** Persisted refs keep their state for the next launch; the failure shows in the skip reason and in the `conversation.startup_audit` event (one per launch: per-phase milliseconds, the main-thread seed wait, panels by evidence tier, scrape failures by kind). A same-id causal report (`capture-runtime`, a SessionStart hook push) on a ref that is not `alive` returns it to `alive`.

The contract: after a crash, **every conversation either resumes exactly per its kind's tier, or the panel carries an honest, specific `diagnostic_reason`.** There are no silent fresh-launches presented as resumes.

- **claude-code** — resumes when the hook-captured (or scrape-recovered) id has a transcript on disk; otherwise `transcript not found`.
- **codex / pi** — the scraper resolves the placeholder to the real id at restore, then reclassify verifies it. A panel whose session file is absent stays a placeholder and simply skips (no wrong resume).
- **omp / grok** — their PATH wrappers publish exact causal identity only after the first message creates the durable JSONL/session directory. Dirty restore stats that exact payload path. An empty session never reaches this tier and skips.
- **opencode** — the client-owned TUI process captures the exact root; the socket peer PID must match a fresh, in-memory wrapper claim. A wrapper claim retries only startup `not_ready` responses within a bounded window. Generic pushes cannot forge the reserved TUI PID/recovery keys or replace an authenticated v2 route. Route mutations carry a per-TUI generation, so c11 rejects delayed writes from older routes. The typed gate reads a lock-backed projection and closes as soon as a verified claim or route transition begins. Route changes retry their unbind write until accepted; with native mail enabled, a provisional stream rejects delivery until the new root binds. Binding the exact root schedules a fresh gate read for buffered typed mail. The claim records that launch's `HOME`, `XDG_DATA_HOME`, and `OPENCODE_DB`; restore verifies the exact ID in that same store. Invalid, empty, `:memory:`, or unsupported stores remain unverifiable, with no fallback to c11's own database; c11 never substitutes the newest same-directory session.
- **kimi / github-copilot** — no exact-resume rail; a fresh launch is the honest outcome (placeholders skip).

### Codex real-cwd disambiguation

Codex stores sessions flat (`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`), not under a per-cwd directory, so the filename can't say which panel a session belongs to. `CodexScraper` therefore does a **bounded, allowlisted** read of each candidate's first JSONL line and extracts only `payload.cwd` (byte-capped; no transcript content read or logged, per the scrape privacy contract). The strategy then keeps only candidates whose recovered cwd matches the panel's cwd:

- **Distinct-cwd codex panels** each match only their own session → each resumes cleanly.
- **Two codex panels in the same cwd without causal capture** are genuinely indistinguishable to the scraper. Every inferred owner is quarantined and `resume()` skips rather than timestamp-picking. Distinct `runtimeEnv` refs remain independently resumable even when their cwd is identical. Clear an ambiguous ref with `c11 conversation clear --panel <id>` to force a fresh launch.

The per-panel **activity floor** (`SurfaceActivityTracker`, persisted in the snapshot) gives the codex/pi/omp filters a lower `mtime` bound that survives a restart, so stale sessions in a shared cwd are excluded rather than widening the candidate set into spurious ambiguity.

## Wrapper-claim flow (TUI integrators)

```bash
# Pseudo-shape; real wrappers stay bash. See Resources/bin/{claude,codex,pi,omp,grok}.
1. Detect c11 environment (C11_PANEL_ID + live socket). Pass through if absent.
2. For Codex, synchronously run `conversation claim ... --ttl-ms <short-bound>`.
   The server checks the absolute expiry at the store mutation boundary.
   Continue only after an acknowledged commit or an expired/failed no-op.
3. (For TUIs with hooks: inject the necessary flags so hooks fire `c11 conversation push`.)
4. exec "$REAL_TUI" "$@"
```

`--expected-resume-id <uuid>` is wrapper-internal lifecycle intent, not a
causal identity report. The wrapper supplies it only for an explicit
`codex resume <uuid>` invocation. An exact match preserves that panel's
existing exact ref while the target resumes; a plain launch, `--last`, or a
different UUID atomically invalidates the prior ref to a placeholder until the
new target runs `conversation capture-runtime` (or a safe fallback scrape
resolves it). Operators and orchestrators should not use this option as a
substitute for target-process runtime capture.

Constraints (CLAUDE.md "unopinionated about the terminal"):

1. PATH-scoped under c11's bundle. Pass-through outside c11.
2. **No persistent writes** to tenant config (`~/.claude/settings.json`, `~/.codex/*`, dotfiles, …).
3. Capture only the minimum needed for resume.
4. Best-effort: failures never block TUI launch.

Codex `SessionStart` hook injection is intentionally not used. Outside managed environments Codex requires trusted hook configuration, and bypassing trust would weaken the pass-through safety contract. The runtime-environment command plus the bounded wrapper fallback provides the capture rail without writing tenant config or making launch depend on hook trust.

## Diagnostic recipes

```bash
# "Why did this panel resume that session?"
c11 conversation get --json | jq '.active.diagnostic_reason'

# Force a fresh launch on next workspace open
c11 conversation clear

# List every captured conversation in this c11 process
# (v1 stores process-wide; no per-workspace partitioning)
c11 conversation list --json | jq '.conversations[] | {kind, id, state, panel_id}'

# After a relaunch: which panels did not resume, and why? Then recover them.
c11 conversation resume --all-skipped --dry-run --json | jq -r '.panels[]
  | "\(.outcome)\t\(.kind)\t\(.skip_code // "-")\t\(.reason // "-")"'
c11 conversation resume --all-skipped

# Where did the startup audit spend its time?
c11 events tail --filter type=conversation.startup_audit

# After a crash + relaunch: which panels resumed vs carry a diagnostic?
c11 conversation list --json | jq -r '.conversations[]
  | "\(.kind)\t\(.state)\t\(.diagnostic_reason // "-")"'
# RESOLVED panels read `suspended` + "crash recovery: transcript verified on disk";
# honest skips read `unknown` + "…transcript not found" / "ambiguous: N candidates".

# Dry-run the resume decision for a saved snapshot without launching (test oracle)
c11 state verify --mode dirty
```

## Landed (Truth & Stability cycle, C11-131 + C11-151..154 + C11-164)

- **Live scrape-capture on restore** — resolves Claude/Codex/pi/omp placeholder refs from disk for the panels that need it.
- **Crash reclassification** (`reclassifyAfterCrash`) replacing the old blanket `markAllUnknown` — verified-transcript refs resume, missing ones carry an honest diagnostic.
- **`SurfaceActivityTracker` snapshot persistence** — the activity floor now persists per panel (`last_activity_at`) and is seeded at restore, so codex/pi/omp disambiguation survives a reboot.
- **Codex real-cwd recovery** via a bounded, allowlisted first-line read of the rollout header — the cwd filter now discriminates across workspaces.
- **`c11 state save` / `c11 state verify` / `c11 app restart`** CLI + socket `session.save` — explicit checkpoint, dry-run resume report, and clean-bounce restart.

Still open: workspace partitioning on `c11 conversation list` (`--workspace` rejected with a clear error).

## Removed in 0.46.0 / v1.1

- The environment-variable kill switch for the conversation store.
- The legacy `claude.session_id` reserved-metadata bridge in `WorkspaceSnapshotConversationBridge`.
- The `AgentRestartRegistry` legacy fallback path.

After 0.46.0 / v1.1, conversation refs are the only way c11 captures or resumes per-panel session state.
