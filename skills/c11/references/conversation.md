# Conversation primitives reference

This file expands [SKILL.md § Conversation primitives](../SKILL.md#conversation-primitives). Loaded on demand; the top-level skill carries the brief.

## What it is

A `Conversation` is a persistable pointer to **a continuation of agent work**. Owned by c11; survives TUI process death and c11 restarts. Each surface hosts at most one *active* `ConversationRef` (v1; the schema leaves room for history). Refs are keyed by an opaque, per-kind id whose interpretation is delegated to a per-kind strategy.

```
Surface ──hosts──▶ Conversation ──interpreted-by──▶ ConversationStrategy
                        │
                        └── carries: kind, id, capturedAt, capturedVia, state, payload, cwd
```

## CLI verbs

```
c11 conversation claim --kind <k> [--cwd <path>] [--id <id>]
c11 conversation push --kind <k> --id <id> --source <hook|scrape|manual>
                      [--state <alive|suspended|tombstoned|unknown|ended>]
                      [--cwd <path>] [--reason <text>]
                      [--payload <json> | --payload @<path>]
c11 conversation tombstone --kind <k> --id <id> [--reason <text>]
c11 conversation list [--surface <id>] [--json]
c11 conversation get [--surface <id>] [--json]
c11 conversation clear [--surface <id>]
```

| Verb | Use |
|------|-----|
| `claim` | Wrapper-claim: mint a placeholder ref. Idempotent and conservative — never displaces a real id captured by hook/scrape. |
| `push` | Hook or operator push of the real id. Source priority: `hook > scrape > manual > wrapperClaim`. |
| `tombstone` | Mark the surface's active ref as tombstoned. Operator-initiated; not auto-resumable. |
| `list` | List captured conversations (process-wide; v1 has no per-workspace partitioning). Filter with `--surface`. `--json` for structured output. |
| `get` | Inspect the active ref + `can_resume` + `diagnostic_reason` for a surface. The debugging entry point. |
| `clear` | Wipe the surface's conversations. Forces a fresh launch on next workspace open. |

**Surface resolution.** Every verb resolves `--surface` from `CMUX_SURFACE_ID` if unset. **No focused-surface fallback** (the silent-misroute footgun the architecture exists to avoid). If the env var is missing and no flag was given, the command errors out with `missing_surface`.

**`--payload`** accepts inline JSON or `@<path>` to read JSON from a file (mirrors the `HOOKS_FILE` ergonomics in `Resources/bin/claude` so hook authors writing bash do not have to shell-quote JSON).

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
| `hook` | Push from a TUI lifecycle hook (e.g. Claude Code SessionStart). Highest priority. |
| `scrape` | Pull from on-disk session storage (`~/.claude/projects/<cwd-slug>/`, `~/.codex/sessions/`, `~/.pi/agent/sessions/<cwd-slug>/`, `~/.omp/agent/sessions/<cwd-slug>/`). Resolves a placeholder to a real id at restore. |
| `manual` | Explicit operator action (`c11 conversation push --source manual`). |
| `wrapperClaim` | Background claim from a TUI wrapper at launch. Lowest priority — never displaces a non-wrapperClaim source. |

Reconciliation rule: latest `capturedAt` wins; on close timestamps, source priority breaks the tie. Wrapper-claims are conservative: they never displace a non-wrapperClaim source regardless of timestamp.

## Strategies

| Kind | Resume tier | Capture | Resume action |
|------|-------------|---------|---------------|
| `claude-code` | Strong (push-id deterministic) | SessionStart hook → `c11 conversation push`. Pull-scrape `~/.claude/projects/<cwd-slug>/` is the fallback when the hook was missed. | `claude --dangerously-skip-permissions --resume <id>` (id shell-quoted) |
| `codex` | Exact, ambiguity-aware | Wrapper-claim placeholder → `CodexScraper` resolves the real id from `~/.codex/sessions/` at restore, filtered by **real cwd** (recovered from the rollout header, see below) + claim-time + activity floors. | `codex resume <id>` (specific id; never `--last`) |
| `pi` | Exact, ambiguity-aware | Wrapper-claim placeholder → `PiScraper` resolves the real id from the cwd slug dir, claim-time + activity floors narrowing past stale sessions. | `pi --session '<id>'` (specific id) |
| `omp` | Exact, ambiguity-aware | Wrapper-claim placeholder → `OmpScraper` resolves the real id from the cwd slug dir, claim-time + activity floors. | `omp --resume='<id>'` (specific id) |
| `opencode` | Push (plugin rail) | Plugin-emitted push of the real id. No scraper in the pull registry. | `cd '<dir>' && opencode -s <id>` — `.skip` for placeholders |
| `grok` | Best-effort resume | Wrapper-claim placeholder | `grok --always-approve --resume` (no id) — `.skip` for placeholders |
| `kimi` | Fresh-launch only | Wrapper-claim placeholder | `kimi` (process launch) — `.skip` for placeholders |
| `github-copilot` | Fresh-launch only | Wrapper-claim placeholder | `copilot` (process launch) — `.skip` for placeholders |

## Crash recovery — what it guarantees per kind

The forced-kill (`kill -9`) path is a first-class, tested guarantee as of the Truth & Stability cycle (C11-164), not a v1.1 aspiration. On launch c11 reads a per-bundle dirty/clean **shutdown sentinel** (`~/.c11/runtime/shutdown.<bundle>.{dirty,clean}`); `.dirty` (or missing) means the last run crashed. The dirty-launch restore ordering is:

1. **Seed** the store from the last snapshot (`seedFromSnapshot`), and seed the per-surface **activity floor** (persisted on each panel as `last_activity_at`).
2. **Scrape-capture** (`runScrapeCapture`): for every restored terminal surface, run its kind's scraper and resolve any placeholder to the real on-disk session id.
3. **Reclassify** (`reclassifyAfterCrash`): for each `.alive`/`.suspended` ref, `transcriptExists` stats the on-disk transcript (stat only — bytes never read). Verified → `.suspended` with `diagnostic_reason = "crash recovery: transcript verified on disk"` (resume fires); missing → `.unknown` with `"crash recovery: transcript not found"` (honest skip). Refs already `.unknown`/`.tombstoned` are untouched, so `/exit`-ended sessions never auto-resume.

The contract: after a crash, **every conversation either resumes exactly per its kind's tier, or the surface carries an honest, specific `diagnostic_reason`.** There are no silent fresh-launches presented as resumes.

- **claude-code** — resumes when the hook-captured (or scrape-recovered) id has a transcript on disk; otherwise `transcript not found`.
- **codex / pi / omp** — the scraper resolves the placeholder to the real id at restore, then reclassify verifies it. A surface whose session file is absent stays a placeholder and simply skips (no wrong resume).
- **opencode / grok / kimi / github-copilot** — no exact-resume rail; a fresh launch is the honest outcome (placeholders skip).

### Codex real-cwd disambiguation

Codex stores sessions flat (`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`), not under a per-cwd directory, so the filename can't say which pane a session belongs to. `CodexScraper` therefore does a **bounded, allowlisted** read of each candidate's first JSONL line and extracts only `payload.cwd` (byte-capped; no transcript content read or logged, per the scrape privacy contract). The strategy then keeps only candidates whose recovered cwd matches the surface's cwd:

- **Distinct-cwd codex panes** each match only their own session → each resumes cleanly.
- **Two codex panes in the same cwd** (genuinely indistinguishable) → `state = .unknown`, `diagnostic_reason = "ambiguous: N candidates; chose newest"`, `resume()` returns `.skip("ambiguous")`. Neither pane resumes the other's session; clear with `c11 conversation clear --surface <id>` to force a fresh launch. This is the correct, honest behaviour — the ambiguity policy the store was built for.

The per-surface **activity floor** (`SurfaceActivityTracker`, persisted in the snapshot) gives the codex/pi/omp filters a lower `mtime` bound that survives a restart, so stale sessions in a shared cwd are excluded rather than widening the candidate set into spurious ambiguity.

## Wrapper-claim flow (TUI integrators)

```bash
# Pseudo-shape; real wrappers stay bash. See Resources/bin/{claude,codex,pi,omp}.
1. Detect c11 environment (CMUX_SURFACE_ID + live socket). Pass through if absent.
2. c11 conversation claim --kind <my-kind> --cwd "$PWD" >/dev/null 2>&1 &
3. (For TUIs with hooks: inject the necessary flags so hooks fire `c11 conversation push`.)
4. exec "$REAL_TUI" "$@"
```

Constraints (CLAUDE.md "unopinionated about the terminal"):

1. PATH-scoped under c11's bundle. Pass-through outside c11.
2. **No persistent writes** to tenant config (`~/.claude/settings.json`, `~/.codex/*`, dotfiles, …).
3. Capture only the minimum needed for resume.
4. Best-effort: failures never block TUI launch.

## Diagnostic recipes

```bash
# "Why did this pane resume that session?"
c11 conversation get --json | jq '.active.diagnostic_reason'

# Force a fresh launch on next workspace open
c11 conversation clear

# Roll back to legacy claude.session_id metadata path (one release window)
CMUX_DISABLE_CONVERSATION_STORE=1 open -a c11

# List every captured conversation in this c11 process
# (v1 stores process-wide; no per-workspace partitioning)
c11 conversation list --json | jq '.conversations[] | {kind, id, state, surface_id}'

# After a crash + relaunch: which surfaces resumed vs carry a diagnostic?
c11 conversation list --json | jq -r '.conversations[]
  | "\(.kind)\t\(.state)\t\(.diagnostic_reason // "-")"'
# RESOLVED surfaces read `suspended` + "crash recovery: transcript verified on disk";
# honest skips read `unknown` + "…transcript not found" / "ambiguous: N candidates".

# Dry-run the resume decision for a saved snapshot without launching (test oracle)
c11 state verify
```

## Landed (Truth & Stability cycle, C11-131 + C11-151..154 + C11-164)

- **Live scrape-capture on restore** (`runScrapeCapture`) — resolves Claude/Codex/pi/omp placeholder refs from disk before the resume pass runs. Superseded the snapshot-only restore.
- **Crash reclassification** (`reclassifyAfterCrash`) replacing the old blanket `markAllUnknown` — verified-transcript refs resume, missing ones carry an honest diagnostic.
- **`SurfaceActivityTracker` snapshot persistence** — the activity floor now persists per panel (`last_activity_at`) and is seeded at restore, so codex/pi/omp disambiguation survives a reboot.
- **Codex real-cwd recovery** via a bounded, allowlisted first-line read of the rollout header — the cwd filter now discriminates across workspaces.
- **`c11 state save` / `c11 state verify` / `c11 app restart`** CLI + socket `session.save` — explicit checkpoint, dry-run resume report, and clean-bounce restart.

Still open: workspace partitioning on `c11 conversation list` (`--workspace` rejected with a clear error).

## Removed in 0.46.0 / v1.1

- `CMUX_DISABLE_CONVERSATION_STORE` env-var kill switch.
- The legacy `claude.session_id` reserved-metadata bridge in `WorkspaceSnapshotConversationBridge`.
- The `AgentRestartRegistry` legacy fallback path.

After 0.46.0 / v1.1, conversation refs are the only way c11 captures or resumes per-surface session state.
