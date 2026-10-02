# Conversation primitives reference

## Lifecycle journal

The journal records structural observations for an exact `(tab UUID, agent kind,
session ID)` owner. It does not store conversation content or make a session
resumable. See [append API](api.md#structural-lifecycle-append).

Processing follows the app-assigned sequence. Comparable native time can reject
late evidence, and tool activity can only refresh a working turn. In particular,
a late PreToolUse after Stop cannot restart working. A new native submission
boundary can start the next turn. Missing or unsupported evidence remains
unknown/advisory; pressing Esc alone does not prove interruption succeeded.

An observed question, approval, or plan-review request is blocked independently
of unread notifications. Seeing a tab can clear unread, but it does not answer
the request. Existing flag and suppression policy still controls presentation.
Journal-managed sessions receive derived `activity` from the committed fold;
legacy shell/notification writes cannot override it.

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

This file expands [SKILL.md § Conversation primitives](../SKILL.md#conversation-primitives). Loaded on demand; the top-level skill carries the brief.

## What it is

A `Conversation` is a persistable pointer to **a continuation of agent work**. Owned by c11; survives TUI process death and c11 restarts. Each tab hosts at most one *active* `ConversationRef` (v1; the schema leaves room for history). Refs are keyed by an opaque, per-kind id whose interpretation is delegated to a per-kind strategy.

```
Tab ──hosts──▶ Conversation ──interpreted-by──▶ ConversationStrategy
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
c11 conversation list [--tab <id>] [--json]
c11 conversation get [--tab <id>] [--json]
c11 conversation clear [--tab <id>]
```

| Verb | Use |
|------|-----|
| `capture-runtime` | Codex-only exact capture. Run from the target agent's own tool subprocess with no arguments; reads `CODEX_THREAD_ID`, agreeing c11 tab aliases, and actual cwd from that process. |
| `claim` | Wrapper launch boundary. Conservative for non-Codex kinds; Codex plain/mismatch invalidates its prior exact lifecycle while a matching internal expected-resume id preserves it. |
| `push` | Hook or operator push of the real id. Accepts only `hook`, `scrape`, or `manual`; runtime environment capture and wrapper claims use their dedicated verbs. |
| `tombstone` | Mark the tab's active ref as tombstoned. Operator-initiated; not auto-resumable. |
| `list` | List captured conversations (process-wide; v1 has no per-workspace partitioning). Filter with `--tab`. `--json` for structured output. |
| `get` | Inspect the active ref + `can_resume` + `diagnostic_reason` for a tab. The debugging entry point. |
| `clear` | Wipe the tab's conversations. Forces a fresh launch on next workspace open. |

**Tab resolution.** Every verb resolves `--tab` from `C11_TAB_ID` if unset. **No focused-tab fallback** (the silent-misroute footgun the architecture exists to avoid). If the env var is missing and no flag was given, the command errors out with `missing_surface`.

**`--payload`** accepts inline JSON or `@<path>` to read JSON from a file (mirrors the `HOOKS_FILE` ergonomics in `Resources/bin/claude` so hook authors writing bash do not have to shell-quote JSON).

**Codex runtime capture has no identity flags.** `capture-runtime` rejects every argument, alias disagreement, malformed/missing environment identity, stale/non-terminal/non-live tabs, and tabs not owned by the addressed c11 socket instance. This is cooperative causal evidence from the target process, not an adversarial authentication boundary. Orchestrators must instruct each Codex agent to run the command itself; they must not expand or relay a child thread ID.

**State verification requires a recovery mode.** Use `c11 state verify --mode clean|dirty|no-resume [snapshot-path]`. The mode is explicit because a snapshot path cannot reveal the app's sentinel/relaunch policy. Clean evaluates persisted exact ownership; dirty additionally requires on-disk transcript evidence (including direct exact Codex lookup without a recency window); no-resume always reports a policy skip.

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
| `codex` | Exact, causal | Before its expiry-bounded claim, the wrapper atomically writes a c11-owned per-tab launch-boundary marker beside the active socket. The marker survives acknowledged and failed/expired claims so a crash before autosave cannot expose the older on-disk owner. The listener records its actual post-fallback socket path per bundle, allowing startup to find that marker before the new listener binds. Marker replay is retained intentionally and is harmless after a durable placeholder or newer runtime capture; the next launch overwrites it. The running target executes `capture-runtime`, which records its exact `CODEX_THREAD_ID`. `CodexScraper` remains a conservative crash fallback when causal capture was missed. | `codex resume --yolo <id>` (specific id; never `--last`) |
| `pi` | Exact, ambiguity-aware | Wrapper-claim placeholder → `PiScraper` resolves the real id from the cwd slug dir, claim-time + activity floors narrowing past stale sessions. | `pi --session '<id>'` (specific id) |
| `omp` | Exact, causal after persistence | Wrapper watches OMP's tty pointer and, once the first message creates its JSONL, pushes the exact UUID, effective cwd, and path. The cwd scraper remains a legacy fallback. Empty sessions stay placeholders. | `omp --auto-approve --resume='<id>'` (specific id) |
| `opencode` | Push (plugin rail) | Plugin-emitted push of the real id. No scraper in the pull registry. | `cd '<dir>' && opencode --auto -s <id>` — `.skip` for placeholders |
| `grok` | Exact after persistence | PATH wrapper injects a UUID, then pushes it with the exact session directory after the first message persists. Empty sessions remain uncaptured. | `grok --always-approve --resume '<id>'` |
| `kimi` | Fresh-launch only | Wrapper-claim placeholder | `kimi --auto` (process launch) — `.skip` for placeholders |
| `github-copilot` | Fresh-launch only | Wrapper-claim placeholder | `copilot --allow-all --autopilot` (process launch) — `.skip` for placeholders |

Every resume line carries its agent's auto-approve flag, the same one its launch command uses (`AgentAutoApprove` in `Sources/AgentManifest.swift`). A resumed agent has the permission posture of a freshly launched one. `pi` is the exception: its CLI has no auto-approve-all flag, so it prompts on launch and on resume alike.

## Crash recovery — what it guarantees per kind

The forced-kill (`kill -9`) path is a first-class, tested guarantee as of the Truth & Stability cycle (C11-164), not a v1.1 aspiration. On launch c11 reads a per-bundle dirty/clean **shutdown sentinel** (`~/.c11/runtime/shutdown.<bundle>.{dirty,clean}`); `.dirty` (or missing) means the last run crashed. The dirty-launch restore ordering is:

1. **Seed** the store from the last snapshot (`seedFromSnapshot`), and seed the per-tab **activity floor** (persisted on each tab as `last_activity_at`).
2. **Scrape-capture** (`runScrapeCapture`): for every restored terminal tab, run its kind's scraper and resolve any placeholder to the real on-disk session id.
3. **Reclassify** (`reclassifyAfterCrash`): for each `.alive`/`.suspended` ref, `transcriptExists` stats the on-disk transcript (stat only — bytes never read). Verified → `.suspended` with `diagnostic_reason = "crash recovery: transcript verified on disk"` (resume fires); missing → `.unknown` with `"crash recovery: transcript not found"` (honest skip). Refs already `.unknown`/`.tombstoned` are untouched, so `/exit`-ended sessions never auto-resume.

The contract: after a crash, **every conversation either resumes exactly per its kind's tier, or the tab carries an honest, specific `diagnostic_reason`.** There are no silent fresh-launches presented as resumes.

- **claude-code** — resumes when the hook-captured (or scrape-recovered) id has a transcript on disk; otherwise `transcript not found`.
- **codex / pi** — the scraper resolves the placeholder to the real id at restore, then reclassify verifies it. A tab whose session file is absent stays a placeholder and simply skips (no wrong resume).
- **omp / grok** — their PATH wrappers publish exact causal identity only after the first message creates the durable JSONL/session directory. Dirty restore stats that exact payload path. An empty session never reaches this tier and skips.
- **opencode** — the plugin pushes exact identity; restore resumes that id.
- **kimi / github-copilot** — no exact-resume rail; a fresh launch is the honest outcome (placeholders skip).

### Codex real-cwd disambiguation

Codex stores sessions flat (`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`), not under a per-cwd directory, so the filename can't say which tab a session belongs to. `CodexScraper` therefore does a **bounded, allowlisted** read of each candidate's first JSONL line and extracts only `payload.cwd` (byte-capped; no transcript content read or logged, per the scrape privacy contract). The strategy then keeps only candidates whose recovered cwd matches the tab's cwd:

- **Distinct-cwd codex tabs** each match only their own session → each resumes cleanly.
- **Two codex tabs in the same cwd without causal capture** are genuinely indistinguishable to the scraper. Every inferred owner is quarantined and `resume()` skips rather than timestamp-picking. Distinct `runtimeEnv` refs remain independently resumable even when their cwd is identical. Clear an ambiguous ref with `c11 conversation clear --tab <id>` to force a fresh launch.

The per-tab **activity floor** (`SurfaceActivityTracker`, persisted in the snapshot) gives the codex/pi/omp filters a lower `mtime` bound that survives a restart, so stale sessions in a shared cwd are excluded rather than widening the candidate set into spurious ambiguity.

## Wrapper-claim flow (TUI integrators)

```bash
# Pseudo-shape; real wrappers stay bash. See Resources/bin/{claude,codex,pi,omp,grok}.
1. Detect c11 environment (C11_TAB_ID + live socket). Pass through if absent.
2. For Codex, synchronously run `conversation claim ... --ttl-ms <short-bound>`.
   The server checks the absolute expiry at the store mutation boundary.
   Continue only after an acknowledged commit or an expired/failed no-op.
3. (For TUIs with hooks: inject the necessary flags so hooks fire `c11 conversation push`.)
4. exec "$REAL_TUI" "$@"
```

`--expected-resume-id <uuid>` is wrapper-internal lifecycle intent, not a
causal identity report. The wrapper supplies it only for an explicit
`codex resume <uuid>` invocation. An exact match preserves that tab's
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
# "Why did this tab resume that session?"
c11 conversation get --json | jq '.active.diagnostic_reason'

# Force a fresh launch on next workspace open
c11 conversation clear

# List every captured conversation in this c11 process
# (v1 stores process-wide; no per-workspace partitioning)
c11 conversation list --json | jq '.conversations[] | {kind, id, state, tab_id}'

# After a crash + relaunch: which tabs resumed vs carry a diagnostic?
c11 conversation list --json | jq -r '.conversations[]
  | "\(.kind)\t\(.state)\t\(.diagnostic_reason // "-")"'
# RESOLVED tabs read `suspended` + "crash recovery: transcript verified on disk";
# honest skips read `unknown` + "…transcript not found" / "ambiguous: N candidates".

# Dry-run the resume decision for a saved snapshot without launching (test oracle)
c11 state verify --mode dirty
```

## Landed (Truth & Stability cycle, C11-131 + C11-151..154 + C11-164)

- **Live scrape-capture on restore** (`runScrapeCapture`) — resolves Claude/Codex/pi/omp placeholder refs from disk before the resume pass runs. Superseded the snapshot-only restore.
- **Crash reclassification** (`reclassifyAfterCrash`) replacing the old blanket `markAllUnknown` — verified-transcript refs resume, missing ones carry an honest diagnostic.
- **`SurfaceActivityTracker` snapshot persistence** — the activity floor now persists per tab (`last_activity_at`) and is seeded at restore, so codex/pi/omp disambiguation survives a reboot.
- **Codex real-cwd recovery** via a bounded, allowlisted first-line read of the rollout header — the cwd filter now discriminates across workspaces.
- **`c11 state save` / `c11 state verify` / `c11 app restart`** CLI + socket `session.save` — explicit checkpoint, dry-run resume report, and clean-bounce restart.

Still open: workspace partitioning on `c11 conversation list` (`--workspace` rejected with a clear error).

## Removed in 0.46.0 / v1.1

- The environment-variable kill switch for the conversation store.
- The legacy `claude.session_id` reserved-metadata bridge in `WorkspaceSnapshotConversationBridge`.
- The `AgentRestartRegistry` legacy fallback path.

After 0.46.0 / v1.1, conversation refs are the only way c11 captures or resumes per-tab session state.
