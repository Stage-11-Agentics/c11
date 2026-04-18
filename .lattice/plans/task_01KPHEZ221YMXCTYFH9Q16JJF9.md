# CMUX-14: Lineage primitive on the surface manifest

## Summary

Promote **lineage** from a skill-level title-string convention to a first-class canonical key on the surface manifest. Today, downstream tab naming is encoded by writing `Login Button :: MA Review :: Claude` into `title` and a matching breadcrumb into `description`. That lands the UX but leaves lineage unqueryable, brittle under parent renames, and lost on any title override.

This ticket makes lineage a primitive: a typed, validated, persisted chain of ancestors that tooling (sidebar, title-bar breadcrumb, `cmux tree`, Lattice, Mycelium, future consumers) can render and reason over. The `::` title convention stays for human-readable display; `lineage` carries the structural truth.

## The primitive

Add a canonical key `lineage` to the surface manifest. Shape:

```jsonc
{
  "lineage": {
    "version": 1,
    "ancestors": [
      {
        "surface_ref":    "surface:5",
        "title_snapshot": "Login Button",
        "role_snapshot":  "feature-agent",
        "spawned_at":     "2026-04-18T14:08:00Z"
      },
      {
        "surface_ref":    "surface:12",
        "title_snapshot": "Multi-Agent Review",
        "role_snapshot":  "review-orchestrator",
        "spawned_at":     "2026-04-18T14:12:00Z"
      }
    ]
  }
}
```

### Design decisions (locked in)

1. **Ordering: root-first.** `ancestors[0]` is the furthest ancestor; `ancestors[-1]` is the immediate parent. Matches the `A :: B :: C` reading.
2. **Resolution: live with snapshot fallback.** `cmux get-lineage` resolves `surface_ref` to current titles by default; falls back to `title_snapshot` when the parent surface is gone. No push machinery — no update storms when a parent renames.
3. **Source: `explicit`.** `cmux set-parent` writes `lineage` with `source: explicit`. No new source tier. Users can still override via raw `cmux set-metadata` like any canonical key.
4. **First-cut scope:** primitive + CLI + skill update. Defer the title-bar breadcrumb widget, auto-derivation of `title` from `lineage`, and `cmux tree` annotations to follow-up tickets.

### Schema / validation

- `ancestors`: array, max length **16** (rejects deeper chains).
- Each entry:
  - `surface_ref` — required, string, surface ref or UUID
  - `title_snapshot` — required on write, string, ≤ 256 chars (matches `title` cap)
  - `role_snapshot` — optional, string, ≤ 64 chars
  - `spawned_at` — optional, RFC 3339 string; server fills `now` if absent
- Reject cycles: a surface cannot appear in its own `ancestors`.
- Total `lineage` blob ≤ 4 KiB (well under per-surface 64 KiB manifest cap).
- Violations return `reserved_key_invalid_type` (consistent with other canonical keys).

## New CLI

```bash
# Primary sugar. Orchestrator calls this on the child after spawning.
# Server reads parent.lineage.ancestors, appends the parent itself
# (with a snapshot of the parent's current title + role),
# and writes the resulting chain to the child.
cmux set-parent <parent-surface-ref>
cmux set-parent --workspace $WS --surface $CHILD_SURF <parent-surface-ref>

# Read the chain.
cmux get-lineage                           # resolved where possible, snapshot fallback, human-readable
cmux get-lineage --json                    # full structure
cmux get-lineage --format chain            # "Login Button :: MA Review" (splice-ready for titles)
cmux get-lineage --snapshot                # stored snapshots only, no live resolution
cmux get-lineage --surface <ref>           # query another surface
```

`cmux set-parent` is the only write path the skill teaches. `cmux set-metadata --key lineage --json '...'` continues to work as the low-level escape hatch for tooling and migrations.

## Server semantics

On `set-parent child_surface, parent_ref`:

1. Load `parent.metadata.lineage.ancestors` (or `[]` if unset).
2. Compose a new entry for the parent itself: `{surface_ref: <parent>, title_snapshot: parent.title, role_snapshot: parent.role, spawned_at: now}`.
3. Append to the parent's ancestors → the child's new chain.
4. Validate: depth ≤ 16, no cycle (child not in chain).
5. Write `child.metadata.lineage = {version: 1, ancestors: <chain>}` with `source: explicit`.
6. Emit the normal `metadata.changed` signal — no new plumbing.

On `get-lineage`:

- For each entry, if `surface_ref` resolves to a live surface, overlay its current `title` / `role` onto the snapshot. Otherwise surface the snapshot as-is with a `stale: true` flag in JSON output.

## Skill update

`skills/cmux/SKILL.md` and `skills/cmux/references/orchestration.md` currently teach the `::` string convention (added in the conversation that produced this ticket). Extend them to:

- Prefer `cmux set-parent` over manually composing the title string — the server composes lineage; the title can still be set independently.
- Sub-agents orient by reading `cmux get-lineage --format chain` rather than parsing the title string.
- Retain the `::` title display convention as the human-readable default (either user-set, or future auto-derived from `lineage`).

## Out of scope (future tickets)

- **Title-bar breadcrumb widget.** Expanded view gets a chip row sourced from `lineage`; each ancestor clickable → focuses that surface, grayed if closed.
- **Auto-derivation of `title` from `lineage`.** When `title` is unset, render as `ancestors[*].title_snapshot.join(" :: ") + " :: " + <self_role>`.
- **`cmux tree` lineage annotations.** Tree already shows split topology; could add a lineage column.
- **Parent-rename push propagation.** Live-resolve on read covers the common case; push is an optimization.
- **Cross-window lineage test pass.** Works transparently via UUIDs but needs explicit coverage.

## Acceptance criteria

1. New canonical key `lineage` validated, stored, retrievable via `cmux get-metadata --key lineage`.
2. `cmux set-parent <ref>` composes the chain server-side and writes to the child; rejects cycles and over-depth.
3. `cmux get-lineage` returns resolved JSON by default; `--snapshot` returns stored-only; `--format chain` returns the `A :: B :: C` string.
4. Socket method `surface.set_parent` available for programmatic use.
5. Skill files teach `set-parent` / `get-lineage` as the canonical workflow; the `::` title convention is preserved as display-layer default.
6. Tests:
   - Basic `set-parent` / `get-lineage` round-trip
   - Deep chain (length 16) accepted; length 17 rejected
   - Cycle rejection
   - Live resolution vs snapshot fallback when parent is closed
   - Validation errors for malformed entries
7. All skill references and examples updated to reference the primitive.

## Context

This ticket was spawned from a conversation about tab-title fidelity in c11mux ("Title Bar Fidelity Improvements"). Initial work updated the skill file to teach the `::` title convention + `Lineage:` breadcrumb in descriptions. That convention is a useful UX default on its own; making lineage a structural primitive is the next step so tooling can reason over the chain instead of parsing strings.
