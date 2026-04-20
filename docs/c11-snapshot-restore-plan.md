# c11 snapshot & restore

**Status:** plan
**Ticket:** CMUX-37
**Author:** @atin
**Date:** 2026-04-20

## Goal

Capture a c11 workspace's full spatial layout and per-surface state to a JSON file, and rebuild it later — including **bit-exact resume of Claude Code sessions** via `cc --resume <session-id>`.

The killer capability is the Claude piece: `claude --resume <id>` rehydrates an entire session with full context and history. Nobody uses it because nobody keeps track of the IDs. Pairing it with a layout snapshot turns "I'll come back to this tomorrow" into `cmux restore morning-work`.

## Prior art

Third-party `sanghun0724/cmux-claude-skills` ships `cmux-snapshot` / `cmux-restore` Python scripts (~450 LOC). We're not adopting them directly. Three fragilities to avoid:

1. Reads c11's private session file (`~/Library/Application Support/cmux/...json`) — undocumented, drift-prone. We use `cmux tree --all --json`.
2. Detects Claude surfaces by spinner chars (`✳⠂⠐`) in the title. We use the manifest (`terminal_type == claude-code`).
3. Matches session IDs via fuzzy title scoring over `~/.claude/projects/*/sessions-index.json`. We use a SessionStart hook that writes the ID directly to the surface manifest.

Their idea is right; the implementation is heuristic-heavy. Ours is manifest-driven.

## Principle check

Fits **"unopinionated about the terminal"** as sharpened on 2026-04-20:

- Reads only c11's own data (`cmux tree`, manifests) and writes only to its own data dir (`~/.cmux-snapshots/`).
- The only outbound action is `cmux send "cc --resume <id>\n"` — indistinguishable from sending any other string into a terminal. No touching `~/.claude/settings.json`, no hook installation.
- The SessionStart hook that writes `claude.session_id` is **operator-installed, skill-documented**. c11 does not install the hook. Matches the "skill-driven self-reporting is the standard pattern" rule.

## Verified preconditions

- **`cc --resume <id>` works.** `cc` is a shell alias expanding to `claude --model opus --dangerously-skip-permissions`; extra flags pass straight through. `claude -r, --resume [value]` takes an optional session ID.
- **SessionStart hook receives `session_id` on stdin JSON** (along with `source`, `cwd`, `model`). Mechanism confirmed via Claude Code hooks docs.
- **`terminal_type` is already being written to the surface manifest** for live Claude sessions inside c11. Half the plumbing exists today.

## Architecture

### New `cmux` subcommands

```
cmux snapshot [name]             # default: "latest"
cmux restore  [name]             # default: "latest"
cmux list-snapshots
```

Scope is **single workspace by default** (the caller's). Flags:

- `--workspace <ref>` — snapshot a different workspace.
- `--all` — snapshot every workspace in every window. Heavy; explicit opt-in.
- `--out <path>` — override default snapshot directory.

### Snapshot JSON schema (v1)

`cmux tree --json` flattens panes into an array; each pane carries a `split_path` breadcrumb (e.g. `["H:left", "H:left"]`) plus pixel/percent rects. **No nested split tree.** The snapshot mirrors this shape:

```json
{
  "version": 1,
  "captured_at": "2026-04-20T14:30:00Z",
  "name": "morning-work",
  "workspaces": [
    {
      "title": "cmux-41",
      "cwd": "/Users/atin/Projects/Stage11/code/cmux",
      "content_area": { "pixels": { "width": 2808, "height": 1629 } },
      "panes": [
        {
          "ref_at_capture": "pane:7",
          "split_path": ["H:left", "H:left"],
          "percent": { "H": [0, 0.275], "V": [0, 1] },
          "surfaces": [
            {
              "type": "terminal",
              "index_in_pane": 0,
              "title": "Claude :: CMUX-41 impl",
              "description": "Implementing snapshot/restore...",
              "cwd": "/Users/atin/Projects/Stage11/code/cmux",
              "terminal_type": "claude-code",
              "model": "claude-opus-4-7",
              "manifest": { "claude.session_id": "abc123...", ... }
            }
          ]
        }
      ]
    }
  ]
}
```

- `split_path` drives reconstruction. `H:left` / `H:right` = horizontal split, take left/right child. `V:top` / `V:bottom` = vertical split.
- `percent` is captured for post-rebuild `resize-pane` correction.
- `manifest` is fetched per-surface via `cmux get-metadata --surface <ref>` at snapshot time (not present in `cmux tree` output).
- `ref_at_capture` is informational only — refs are regenerated on restore.

### Known-type restart registry

A small table inside the `cmux restore` implementation decides what command to send per `terminal_type`:

| terminal_type | With session ID                  | Without           |
|---------------|----------------------------------|-------------------|
| `claude-code` | `cc --resume <claude.session_id>` | `cc`              |
| `codex`       | (TBD — pending codex resume API) | `codex`           |
| `kimi`        | (TBD)                            | `kimi`            |
| *unknown*     | —                                | leave empty       |

Extensible: new agent types add a row. No c11-side code change needed to **capture** a new agent's session ID — the manifest is free-form. Code change needed only to **restore** it.

### The SessionStart hook (skill-side, opt-in)

Operator installs this in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "[ \"$CMUX_SHELL_INTEGRATION\" = \"1\" ] && jq -r '.session_id' | xargs -I{} cmux set-metadata --key claude.session_id --value {} 2>/dev/null || true"
      }]
    }]
  }
}
```

- Fires on every session boot (`source` = `startup | resume | clear | compact`).
- Reads `session_id` from Claude Code's stdin JSON payload.
- `CMUX_SURFACE_ID` is inherited from the parent c11 shell, so `cmux set-metadata` without flags targets the right surface.
- `|| true` — hook failures never break sessions.
- The `$CMUX_SHELL_INTEGRATION` guard makes it a no-op outside c11.

Documented in the `cmux` skill under a new "Session resume" section.

## Restore algorithm

### Tree reconstruction from split_path breadcrumbs

Given a flat list of panes with paths like `["H:left", "H:left"]`, `["H:left", "H:right"]`, `["H:right"]`:

```
build_tree(panes):
    root = {}
    for p in panes:
        node = root
        for segment in p.split_path:
            kind, side = segment.split(":")   # "H", "left"
            node.setdefault("kind", kind)
            child_key = side                  # "left"|"right"|"top"|"bottom"
            node = node.setdefault(child_key, {})
        node["leaf"] = p
    return root

restore_tree(node, ws_ref, parent_pane_ref, parent_surf_ref):
    if "leaf" in node:
        configure(parent_surf_ref, node["leaf"].surfaces[0])
        for extra in node["leaf"].surfaces[1:]:
            new_surf = cmux new-surface --pane parent_pane_ref
            configure(new_surf, extra)
        return

    direction = "right" if node["kind"] == "H" else "down"
    first_key, second_key = ("left","right") if node["kind"]=="H" else ("top","bottom")

    before = list-panes(ws_ref)
    cmux new-split direction --surface parent_surf_ref
    after = list-panes(ws_ref)
    new_pane = (after - before).single()
    new_surf = first_surface_of(new_pane)

    restore_tree(node[first_key],  ws_ref, parent_pane_ref, parent_surf_ref)
    restore_tree(node[second_key], ws_ref, new_pane,        new_surf)

configure(surf_ref, surface_data):
    cmux set-metadata --surface surf_ref --json <manifest>
    cmux set-title       --surface surf_ref <title>
    cmux set-description --surface surf_ref <description>
    cmux send --surface surf_ref "cd <cwd>\n"
    cmd = restart_command(terminal_type, manifest)
    if cmd: cmux send --surface surf_ref "<cmd>\n"
```

After full rebuild, walk the pane list once more and `resize-pane` any pane whose actual `percent` rect diverges from the snapshot by more than ~2%.

### Edge cases

- **`new-split` doesn't return the new pane ref.** Use the list-diff trick (documented in the cmux skill).
- **Split ratios drift.** Apply `resize-pane` corrections after the tree is fully rebuilt, not during recursion.
- **Session file missing.** If `~/.claude/projects/<key>/<session-id>.jsonl` no longer exists, `cc --resume <id>` fails. Detect by checking the file before sending the command; fall back to `cc` (fresh session) and emit a warning.
- **Multi-cc in one workspace.** Each surface gets its own restart command dispatched directly — no ready-state polling, so the existing multi-cc gotcha doesn't apply.
- **Browser / markdown surfaces.** Restore as `cmux new-pane --type browser --url ...` / `--type markdown --file ...`. No session-resume concept, just recreate.
- **Non-cc agents without a session ID.** Launch the bare binary (`codex`, `kimi`). Fresh session, CWD preserved.

## Open questions

1. **Surface CWD exposure.** `cmux tree --json` does **not** include per-surface working directory. Options:
   - (a) Add `working_directory` to `cmux tree` surface output.
   - (b) Have the SessionStart hook write `$PWD` as `cwd` in the manifest (two `set-metadata` calls, trivial).
   - (c) Add a small socket command `cmux get-cwd --surface <ref>`.
   
   Lean: **(b)**. Keeps c11's surface of concern narrow; operator-controlled via the same hook that's already opt-in.

2. **Pane-layer manifests.** The pane layer carries its own metadata (CMUX-11). Snapshot schema should include `pane.manifest` per pane entry for symmetry. Add in Phase 1.

3. **Snapshot versioning.** Start with `version: 1`. First schema change gets a migration function in `cmux restore`.

4. **Auto-snapshot cadence.** Periodic snapshots via c11 itself? Probably not — that's operator policy, best done via a cron or a `Stop` hook the operator installs.

## Implementation phases

**Phase 1 — primitives.** `cmux snapshot`, `cmux restore`, `cmux list-snapshots` subcommands. Terminal-only surfaces. Claude resume via session ID. Single workspace. Resolve open question (1) by going with option (b).

**Phase 2 — full surface coverage.** Browser and markdown surfaces. `--all` flag for multi-workspace snapshots.

**Phase 3 — skill docs + hook.** Add "Session resume" section to `~/.claude/skills/cmux/SKILL.md` with the SessionStart hook snippet (both `claude.session_id` and `cwd`). Update `references/metadata.md` to document `claude.session_id` as a non-canonical convention.

**Phase 4 — resume registry.** Add codex / kimi / opencode rows when their resume APIs stabilize. Driven by user demand.

## Related tickets

- **CMUX-4** — Claude session index (opt-in). Overlaps; this plan supersedes the "manual index" idea with a SessionStart-hook-driven manifest write.
- **CMUX-5** — Recovery UI. Natural follow-on: surface snapshots in a picker instead of requiring CLI invocation.
- **CMUX-11** — Nameable panes + pane metadata. Snapshot schema should preserve pane-layer metadata.
- **CMUX-14** — Lineage primitive on the surface manifest. Restore preserves `::` chains verbatim via the manifest blob.
