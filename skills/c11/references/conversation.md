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
c11 conversation list [--surface <id>] [--workspace <id>] [--json]
c11 conversation get [--surface <id>] [--json]
c11 conversation clear [--surface <id>]
```

| Verb | Use |
|------|-----|
| `claim` | Wrapper-claim: mint a placeholder ref. Idempotent and conservative — never displaces a real id captured by hook/scrape. |
| `push` | Hook or operator push of the real id. Source priority: `hook > scrape > manual > wrapperClaim`. |
| `tombstone` | Mark the surface's active ref as tombstoned. Operator-initiated; not auto-resumable. |
| `list` | List captured conversations. Use `--json` for structured output. |
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
| `scrape` | Pull from on-disk session storage (`~/.claude/sessions/`, `~/.codex/sessions/`). |
| `manual` | Explicit operator action (`c11 conversation push --source manual`). |
| `wrapperClaim` | Background claim from a TUI wrapper at launch. Lowest priority — never displaces a non-wrapperClaim source. |

Reconciliation rule: latest `capturedAt` wins; on close timestamps, source priority breaks the tie. Wrapper-claims are conservative: they never displace a non-wrapperClaim source regardless of timestamp.

## Strategies (v1)

| Kind | Resume tier | Capture | Resume action |
|------|-------------|---------|---------------|
| `claude-code` | Strong (push-id deterministic) | SessionStart hook → `c11 conversation push`; pull-scrape `~/.claude/sessions/` as fallback | `claude --dangerously-skip-permissions --resume <id>` (id shell-quoted) |
| `codex` | Heuristic (cwd + mtime + activity) | Wrapper-claim placeholder → pull-scrape `~/.codex/sessions/*.jsonl` filtered by cwd, mtime ≥ claim, mtime ≥ surface activity | `codex resume <id>` (specific id; never `--last`) |
| `opencode` | Fresh-launch only | Wrapper-claim placeholder | `opencode` (process launch) — `.skip` for placeholders |
| `kimi` | Fresh-launch only | Wrapper-claim placeholder | `kimi` (process launch) — `.skip` for placeholders |

### Codex ambiguity policy

The motivating bug for the conversation store: two Codex panes opened in the same project both restored to the most-recent global Codex session ("B") instead of their own (`codex resume --last` was order-blind). With the new strategy:

- Codex pull-scrape filters candidates by cwd + mtime ≥ wrapper-claim time + mtime ≥ surface lastActivityTimestamp.
- If **more than one** candidate matches the filter, the strategy returns the ref with `state = .unknown`, `id = most-plausible-candidate (newest mtime)`, and a `diagnosticReason` like `"ambiguous: 3 candidates; chose newest"`.
- `resume()` returns `.skip(reason: "ambiguous")` for `state = .unknown`. Neither pane resumes the other's session; the operator clears via `c11 conversation clear --surface <id>` to force a fresh launch.

The advisory is surfaced via `c11 conversation get`'s `diagnostic_reason` field.

## Wrapper-claim flow (TUI integrators)

```bash
# Pseudo-shape; real wrappers stay bash. See Resources/bin/{claude,codex}.
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

# List every captured conversation across the workspace
c11 conversation list --json | jq '.conversations[] | {kind, id, state, surface_id}'
```

## Removed in 0.46.0 / v1.1

- `CMUX_DISABLE_CONVERSATION_STORE` env-var kill switch.
- The legacy `claude.session_id` reserved-metadata bridge in `WorkspaceSnapshotConversationBridge`.
- The `AgentRestartRegistry` legacy fallback path.

After 0.46.0 / v1.1, conversation refs are the only way c11 captures or resumes per-surface session state.
