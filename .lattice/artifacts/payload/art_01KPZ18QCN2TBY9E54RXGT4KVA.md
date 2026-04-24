# C11-13 ⇄ CMUX-37 Alignment

**Status:** locked 2026-04-24
**Purpose:** both tickets extend the existing CMUX-11 per-surface metadata layer. This document locks the shared conventions so neither ships a retrofit, and both can proceed in parallel without coordination overhead.

## The tickets

- **C11-13** — Inter-agent messaging primitive: mailbox + pluggable delivery handlers (in_planning).
- **CMUX-37** — Workspace persistence: Blueprints (declarative) + Snapshots (live state) + session resume (backlog, ready to start Phase 0).

Both read/write per-surface metadata via the existing CMUX-11 system (`PaneMetadataStore`, `SurfaceMetadataStore`). C11-13 adds `mailbox.*` keys; CMUX-37's Blueprint/Snapshot schemas must serialize those keys faithfully as part of `SurfaceSpec.metadata`. Neither ticket blocks the other; they ship independently and re-converge at CMUX-37 Phase 2 (Blueprint format) when mailbox fields become documented Blueprint properties.

---

## Locked convention #1 — Surface names are the stable addressing primitive

A c11 surface has two identifiers:
- `surface:N` — process-local reference, reassigned on restart. Used inside c11 for live surface handling. **NOT stable across snapshot/restore or mailbox lifecycle.**
- **Surface name** — human-readable label set via `c11 set-title` / nameable-panes. Persisted in pane metadata. **Stable across restart, Snapshot, and Blueprint materialization.**

Both tickets commit to:
- **Messaging addresses surfaces by name.** `c11 mailbox send --to watcher` resolves via surface name, not `surface:N`.
- **Blueprints reference surfaces by name.** Blueprint YAML uses `name: watcher`, not a process-local id.
- **Snapshot restore preserves names verbatim.** A restored surface keeps the same name and therefore the same mailbox identity.

Fallback: when a surface has no name set, messaging falls back to `surface:N` with a warning. The operator (or auto-profile) is nudged to set a name.

## Locked convention #2 — Reserved `mailbox.*` metadata namespace

All messaging config lives under the `mailbox.` key prefix in pane metadata. Both tickets commit to:

- C11-13 **does not** introduce any pane-metadata keys outside `mailbox.*` during v1. New keys added in v1.1+ stay in this namespace.
- CMUX-37 **reserves** the `mailbox.*` prefix: Blueprints and Snapshots round-trip every `mailbox.*` key they encounter, unmodified. Blueprint authors can set them declaratively.
- Other prefixes (`claude.*`, `codex.*`, etc. for the known-type restart registry; `sidebar.*` for status/progress) are independent and do not collide.

v1 `mailbox.*` keys:

| Key | Value | Meaning |
|---|---|---|
| `mailbox.delivery` | comma-separated list | e.g. `"stdin,watch"`. Handler selection. |
| `mailbox.subscribe` | comma-separated globs | e.g. `"build.*,deploy.green"`. Topic subscription patterns. |
| `mailbox.retention_days` | integer (as string) | Inbox envelope retention. Default 7. |

v1.1 additions (reserved; neither ticket uses them yet):
- `mailbox.advertises` — topic discovery payload (JSON-in-string or comma-separated depending on schema decision).
- `mailbox.allow` / `mailbox.deny` — sender allow/deny lists.
- `mailbox.rate_limit` — per-sender rate limits.

## Locked convention #3 — Metadata value encoding: strings-only for v1

Pane metadata is `[String: String]` today (CMUX-11 shape). Both tickets commit to:

- **All `mailbox.*` values are strings** in v1. Multi-value fields use comma-separation (`"stdin,watch"`). Integer values are parsed from strings (`"7"` → 7). JSON values are NOT used until the metadata layer itself supports structured values.
- If either ticket needs structured metadata values before the other, a **joint** schema migration happens — not a unilateral switch. The migration updates `PaneMetadataStore`/`SurfaceMetadataStore` to carry JSON values, with a `schema_version` field for transition.
- Until then: comma-separation for lists; space-separation is avoided (surface names may contain spaces).

## Locked convention #4 — Composition path in `WorkspaceApplyPlan`

When CMUX-37's `WorkspaceApplyPlan` executor lands (Phase 0), it becomes the authoritative creation path for surfaces and their metadata. At that point:

- `SurfaceSpec.metadata: [String: JSONValue]` carries any `mailbox.*` keys a Blueprint declares. The executor writes them to `SurfaceMetadataStore`/`PaneMetadataStore` as part of the one-shot creation transaction — no post-hoc `c11 mailbox configure` calls.
- **C11-13's `c11 mailbox configure` CLI continues to work** as a direct metadata mutation for already-live surfaces. It does NOT route through `WorkspaceApplyPlan` (which is a creation primitive, not a mutation primitive).
- Blueprint authoring docs (CMUX-37 Phase 4 skill updates) treat `mailbox.*` fields as first-class surface properties, with examples.

C11-13 does not wait on this. During v1, `c11 mailbox configure` writes to metadata via the existing socket metadata path — the same path `c11 set-metadata` already uses. When `WorkspaceApplyPlan` lands, creation-time mailbox config becomes available as a Blueprint feature; runtime reconfiguration continues through the CLI path.

## Locked convention #5 — Mailbox lifecycle under Snapshot / restore

When CMUX-37 Phase 1 ships (Snapshot + restore):

- Snapshot capture: includes all pane metadata, which includes `mailbox.*` keys. Nothing special for C11-13 to do.
- Snapshot restore: reapplies the pane metadata before messaging resumes. Mailbox inboxes on disk (`$C11_STATE/workspaces/<ws>/mailboxes/<surface-name>/`) persist across the restart window regardless of Snapshot state — they are just files. On dispatcher start after restore, the periodic sweep re-dispatches any envelopes stranded in `_outbox/` or `_processing/`. Receivers dedupe by `id`, so re-delivery under restore is safe by construction.
- **If a surface is restored with a different name than it had at snapshot time**, inbox messages addressed to the old name are orphaned. Two mitigations:
  - Snapshot should preserve names. This is CMUX-37's contract.
  - If renaming happens intentionally, operator cleanup of the old inbox dir is acceptable — the envelopes are durable but the surface identity changed, which is semantically "you're a different mailbox now."

## What's NOT locked (ticket-specific; each ticket decides)

- C11-13's envelope JSON schema — fully locked in C11-13's design doc.
- C11-13's handler implementations (stdin/silent/watch).
- CMUX-37's `WorkspaceApplyPlan` shape, executor implementation, Blueprint Markdown schema.
- CMUX-37's restart registry beyond "known-type + session_id → resume command."

---

## Operational contract

- **Either ticket can change something inside its own scope without asking the other.**
- **Any change to the shared conventions above requires updating this doc and noting it in both tickets' plan notes.**
- **New metadata-namespace prefixes** (beyond `mailbox.*` for C11-13 and restart-registry keys for CMUX-37) should be coordinated to avoid collision — a one-line comment on the other ticket is enough.
