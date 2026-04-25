# Claude Code session resume

c11 restores Claude Code sessions by reading a per-surface `claude.session_id` out of the snapshot envelope and re-spawning the surface with `cc --resume <session-id>`. Everything below is what makes that wire up end-to-end.

## Where the session id comes from

Claude Code emits a `SessionStart` hook event on startup with a JSON payload that includes `session_id`, `cwd`, and `transcript_path`. Operators forward that payload to `c11 claude-hook session-start`, which:

1. Upserts the session into `~/.cmuxterm/claude-hook-sessions.json` (the sidebar's long-lived session register).
2. Writes `claude.session_id = <id>` onto the current surface's metadata via `surface.set_metadata` (mode `merge`, source `explicit`). This is the value the Phase 1 restart registry consults at restore time.

Both writes are best-effort: the hook never surfaces an error banner to Claude Code just because the c11 control socket is unreachable. The `surface.set_metadata` write in particular follows the existing advisory pattern and emits one of three breadcrumbs — `claude-hook.session-id.metadata-write.{ok,skipped,failed}` — so the outcome is visible in telemetry.

## The operator-installed SessionStart hook

c11 **never writes to `~/.claude/settings.json`** — the operator owns that file. Copy this snippet into the hooks section of `~/.claude/settings.json` (adjust the `cc` binary path if you use a custom alias):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "cc claude-hook session-start" }
        ]
      }
    ]
  }
}
```

The `Resources/bin/claude` shim shipped with the c11 app bundle is a PATH-scoped, grandfathered Claude-only wrapper — in-c11 shells pick it up automatically, no per-machine configuration. See `CLAUDE.md`'s "Unopinionated about the terminal" section; do **not** generalise this pattern to other TUIs.

## Restoring a snapshot

```bash
# Default: capture the current workspace to ~/.c11-snapshots/<ulid>.json
c11 snapshot

# Restore without session resume (fresh shells, layout preserved)
c11 restore 01KQ0XYZ…

# Restore with cc session resume
C11_SESSION_RESUME=1 c11 restore 01KQ0XYZ…

# Replace the current workspace's content in place (no duplicate tab).
# The target workspace's existing panels and splits are closed first;
# the new workspace inherits the plan. Note: the workspace UUID changes
# (a fresh workspace is minted and the prior one is closed).
c11 restore --in-place 01KQ0XYZ…
```

- `C11_SESSION_RESUME` (mirror: `CMUX_SESSION_RESUME`) is read at the CLI layer only.  A truthy value (anything except empty / `0` / `false` / `no` / `off`) threads `restart_registry: "phase1"` into the `snapshot.restore` v2 call.
- The registry is **not** serialised onto the snapshot file. A snapshot written today stays restorable after Phase 5 adds `codex` / `opencode` / `kimi` rows because the registry is resolved by name app-side at restore time.
- An explicit `SurfaceSpec.command` on a terminal surface always wins; registry synthesis only fires when the command field is nil or empty.

## What ends up where

| Layer | Where the session id lives | How it's consumed |
|---|---|---|
| `~/.cmuxterm/claude-hook-sessions.json` | SessionStore record | Sidebar UI, stale-session detection |
| Surface metadata (`SurfaceMetadataStore`) | `claude.session_id` key, source `.explicit` | Phase 1 restart registry; serialised into snapshot envelopes |
| Snapshot envelope (`WorkspaceSnapshotFile`) | Embedded plan → `surfaces[i].metadata["claude.session_id"]` | Loaded at restore time; executor synthesises `cc --resume <id>` when registry is set |

## Privacy and storage

Snapshot envelopes store `claude.session_id` values in cleartext under `~/.c11-snapshots/` (and the legacy `~/.cmux-snapshots/`). Session ids are UUIDv4 transcript-lookup keys, not credentials: they cannot mint a new Claude session and they grant no API or auth scope on their own.

The threat model is narrow: a local attacker who already has read access to the operator's home directory can pair a captured session id with `~/.claude/projects/<project>/` to enumerate historical Claude transcripts. If that is outside your threat model, no action is needed. If it is inside, treat `~/.c11-snapshots/` with the same hygiene you give `~/.claude/projects/`: restrict permissions, exclude from shared-volume backups, or delete snapshots after restore.

c11 does not encrypt at rest (no Keychain round-trip). The restart registry synthesises the resume command in-process well before the operator would be prompted for biometrics, so Keychain storage would block non-interactive restore without meaningfully raising the attacker bar (anyone with local read access to the snapshot file already has local read access to `~/.claude/projects/`). Operator decision (C11-14): document the threat model and ship as-is. Revisit if the threat model ever includes untrusted local processes.

## Troubleshooting

- **Restore starts fresh shells instead of resuming.** Verify `C11_SESSION_RESUME=1` is set in the environment that runs `c11 restore`. The env var is *not* inherited into new workspaces — it's read once, at the CLI layer, when the restore command fires.
- **Registry declines with `restart_registry_declined` failure.** The surface's metadata blob has `terminal_type=claude-code` but no (or empty) `claude.session_id`. Usually means SessionStart never fired — re-run Claude Code inside a c11 surface, or re-install the SessionStart hook snippet above.
- **Snapshot lists an entry as `SOURCE legacy`.** File is under `~/.cmux-snapshots/` from a prior iteration. Writes always go to `~/.c11-snapshots/`; legacy files are readable but never re-written.
