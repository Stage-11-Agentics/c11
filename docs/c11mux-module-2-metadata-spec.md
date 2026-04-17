# c11mux Module 2 — Per-Surface JSON Metadata Spec

Canonical specification for Module 2 of the [c11mux charter](./c11mux-charter.md). All other c11mux modules key off this document; they extend the reserved-key table and the `metadata_sources` sidecar but do not redefine the transport, precedence model, or storage semantics.

Status: specification, not yet implemented. Treat every socket method in this document as a **new primitive introduced by M2** — none of `surface.set_metadata`, `surface.get_metadata`, or `surface.clear_metadata` exist in the v2 API today (see `docs/socket-api-reference.md`). This spec defines their wire format and the canonical-key shape they carry.

---

## Purpose

Each surface can carry an open-ended JSON object that agents read and write over the socket. c11mux stores the blob, exposes it via a small API, and renders a narrow set of **canonical keys** in the sidebar. Everything else in the blob is opaque to c11mux and available to consumers (Lattice, internal dashboards, future Stage 11 tooling).

This is not a replacement for the existing sidebar-metadata commands (`set_status`, `set_progress`, `log`). It is an open-ended payload that sits alongside them. The sidebar-metadata commands remain the fastest path for small reactive pills; the per-surface blob is the transport for everything structured and consumer-agnostic.

---

## Delivery model

**Pull-on-demand only.** Consumers fetch the blob when they want the current state. No push/subscribe, no `metadata.changed` event. This is a deliberate simplification — push/subscribe is named in the charter's parking lot and only ships if consumer count grows past what pull serves well.

**In-memory only.** The blob lives on the `Surface` model in the running cmux process. It does not persist across app relaunch. Consumers that need durability write their own persistence (Lattice already does).

**Per-surface.** Keyed by the surface UUID. Workspace-scoped or window-scoped metadata is out of scope for M2.

---

## Storage shape

Each surface owns two dictionaries:

- **`metadata`** — the free-form JSON object. Any key the consumer likes; the sidebar only renders the canonical subset.
- **`metadata_sources`** — a parallel dictionary keyed on the same keys, whose value is a small sidecar object describing where the current value came from. Defined below.

Both dictionaries are always present. When a key has never been written, it is absent from both. When it is cleared, it is removed from both.

### Size cap

The serialized `metadata` object is capped at **64 KiB** (65536 bytes) per surface. Writes that would exceed the cap return `payload_too_large`. The `metadata_sources` sidecar does not count against this cap. Consumers that need larger payloads should store them externally (S3, Lattice attachments) and put a reference in the blob.

---

## Canonical keys (reserved set)

These keys have a defined shape and render in the sidebar. Any write to a canonical key that violates its type returns `reserved_key_invalid_type`. Writes to non-reserved keys accept any JSON value.

| Key | Type | Rendering | Graduated by |
|-----|------|-----------|--------------|
| `role` | string, ≤ 64 chars, kebab-case | sidebar: small label after tab title | M2 |
| `status` | string, ≤ 32 chars | sidebar: colored pill | M2 |
| `task` | string, ≤ 128 chars | sidebar: monospace tag | M2 |
| `model` | string, ≤ 64 chars, kebab-case | sidebar chip (M3) | M2 (seeded/consumed by M1, M3) |
| `progress` | number, 0.0 – 1.0 | sidebar: progress bar | M2 |
| `terminal_type` | string, kebab-case, ≤ 32 chars. Canonical values: `claude-code`, `codex`, `kimi`, `opencode`, `shell`, `unknown`. Open-ended for future TUIs. | sidebar chip (M3) | M1 (see `c11mux-module-1-tui-detection-spec.md`) |
| `title` | string, plain text, ≤ 256 chars | title bar + sidebar tab label (truncated) | M7 (see `c11mux-module-7-title-bar-spec.md`) |
| `description` | string, basic Markdown subset (`**bold**`, `*italic*`, inline `code`), ≤ 2048 chars | title bar expanded region | M7 |

**Sidebar rendering order when present:** `model` → `terminal_type` → `role` → `status` → `task` → `progress`. `title` and `description` render in the title bar (Module 7), not the sidebar — the sidebar tab label is a truncated projection of `title` as specified in M7. Implementations MUST NOT render `title`/`description` twice.

**Extension rule.** New canonical keys are added only by an explicit module spec that amends this table. A module prompt graduating a new key must specify type, validation, size cap, render slot, and how it interacts with `metadata_sources`.

---

## `metadata_sources` sidecar

Every canonical key's value carries a parallel `metadata_sources[key]` record describing who wrote it and when. Non-canonical keys MAY carry a sidecar; c11mux does not require one.

```json
{
  "metadata": { "terminal_type": "claude-code", "model": "claude-opus-4-7" },
  "metadata_sources": {
    "terminal_type": { "source": "heuristic", "ts": 1713313200.123 },
    "model":         { "source": "declare",   "ts": 1713313201.456 }
  }
}
```

### `source` enum

Full enum defined here, owned by M2. Modules that add new source values amend this table. M1 introduces the enum's consumers; M7 adds the `osc` value's semantics.

| Value | Writer | Notes |
|-------|--------|-------|
| `heuristic` | c11mux internal process-tree scan (M1) | Best-effort auto-detection. Never overwrites higher-precedence values. |
| `osc` | Terminal emulator OSC 0/1/2 sequence (M7) | Only writes `title`. Newer OSC writes overwrite older `osc` writes. |
| `declare` | Agent declaration via CLI/env (M1 `cmux set-agent`, env vars) | Explicit agent self-identification. |
| `explicit` | User CLI (`cmux set-metadata`, `cmux set-title`, `cmux set-description`) or UI inline edit | Highest precedence; user intent wins. |

### Precedence

When a writer attempts to change a key, the new write lands IFF `new_source >= current_source` in the precedence chain:

```
explicit > declare > osc > heuristic
```

- **`explicit` always wins.** A `cmux set-metadata` CLI call overwrites any prior value regardless of source.
- **`declare` overwrites `osc` and `heuristic`**, but not `explicit`.
- **`osc` overwrites `heuristic` and earlier `osc`** (newest OSC within `source=osc` wins), but not `declare` or `explicit`.
- **`heuristic` only writes when the key is unset or current source is `heuristic`.** It never overwrites any explicit or declared value.

A write that fails the precedence check returns `ok: true` with `result.applied: false` and `result.reason: "lower_precedence"`. The current value is left untouched. Consumers that need last-write-wins behavior must use `source: explicit`.

**Clear semantics.** `surface.clear_metadata` with `source: explicit` always succeeds. A clear from a lower-precedence writer only succeeds if the current source is at or below the caller's source.

---

## Socket methods

All methods follow the v2 JSON-RPC convention (`docs/socket-api-reference.md`). Responses use `{"id", "ok", "result"}`.

### `surface.set_metadata`

Merge a partial metadata object into the surface's blob.

```json
{
  "id": "m1",
  "method": "surface.set_metadata",
  "params": {
    "surface_id": "<uuid-or-ref>",
    "mode": "merge",
    "source": "explicit",
    "metadata": { "role": "reviewer", "task": "lat-412" }
  }
}
```

**Params:**

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `surface_id` | yes | string | Surface UUID or ref (`surface:3`). Defaults to focused surface if omitted (matches other v2 methods). |
| `metadata` | yes | object | Partial or full object. Must serialize ≤ 64 KiB after merge. |
| `mode` | no | `"merge"` \| `"replace"` | Default: `"merge"` (shallow merge, last-write-wins per key, precedence-gated). `"replace"` discards the existing blob and the existing sidecar entirely. `replace` requires `source: explicit`. |
| `source` | no | source enum value | Default: `"explicit"`. Writers that aren't the user supply their own source. |

**Semantics:**

- **Shallow merge.** Keys present in the request overwrite those same keys in the blob (subject to precedence). Keys absent from the request are untouched. Nested objects are replaced, not deep-merged.
- **Per-key precedence.** Each key's write is evaluated independently against its current `metadata_sources[key].source`. Some keys in the request may land, others may be rejected with `applied: false`.
- **Sidecar update.** Every successfully-written key gets its `metadata_sources[key]` set to `{"source": <params.source>, "ts": <server_now>}`.

**Result:**

```json
{
  "ok": true,
  "result": {
    "applied": { "role": true, "task": false },
    "reasons": { "task": "lower_precedence" },
    "metadata": { "...current full blob..." },
    "metadata_sources": { "...current full sidecar..." }
  }
}
```

### `surface.get_metadata`

Fetch the current metadata and (optionally) the sidecar.

```json
{
  "id": "m2",
  "method": "surface.get_metadata",
  "params": { "surface_id": "<uuid-or-ref>", "keys": ["role","model"], "include_sources": true }
}
```

**Params:**

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `surface_id` | yes | string | Surface UUID or ref. Defaults to focused surface. |
| `keys` | no | array of string | Return only these keys. Omit for full blob. |
| `include_sources` | no | boolean | Default: `false`. When `true`, response includes `metadata_sources`. |

**Result:**

```json
{
  "ok": true,
  "result": {
    "surface_id": "<uuid>",
    "metadata": { "...": "..." },
    "metadata_sources": { "...": {"source":"explicit","ts":...} }   // only if include_sources
  }
}
```

### `surface.clear_metadata`

Remove one or more keys, or the entire blob.

```json
{
  "id": "m3",
  "method": "surface.clear_metadata",
  "params": { "surface_id": "<uuid-or-ref>", "keys": ["task"], "source": "explicit" }
}
```

**Params:**

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `surface_id` | yes | string | Surface UUID or ref. Defaults to focused surface. |
| `keys` | no | array of string | Clear only these. Omit to clear everything (requires `source: explicit`). |
| `source` | no | source enum value | Default: `"explicit"`. Precedence applies as in `set_metadata`. |

Clearing a key removes it from both `metadata` and `metadata_sources`. Result shape mirrors `set_metadata`.

---

## CLI

Sugar commands wrap the socket methods. All sugar ultimately emits `surface.set_metadata` / `surface.get_metadata` / `surface.clear_metadata`.

| CLI | Socket equivalent | Notes |
|-----|-------------------|-------|
| `cmux set-metadata [--surface <ref>] --json '{...}'` | `surface.set_metadata { mode:"merge", source:"explicit", metadata: <json> }` | General-purpose; any keys. |
| `cmux set-metadata --key K --value V [--type string\|number\|bool\|json]` | same, single key | Sugar for single-key merges. |
| `cmux get-metadata [--surface <ref>] [--key K ...] [--sources]` | `surface.get_metadata` | `--sources` toggles `include_sources`. |
| `cmux clear-metadata [--surface <ref>] [--key K ...]` | `surface.clear_metadata` | No keys → clear all (explicit only). |
| `cmux set-status`, `cmux set-progress`, `cmux log` | existing sidebar-metadata commands | Unchanged by M2. |
| `cmux set-agent` | M1 sugar over `surface.set_metadata` | See Module 1 spec. |
| `cmux set-title`, `cmux set-description` | M7 sugar over `surface.set_metadata` | See Module 7 spec. |

**Output format.** All get/set CLIs default to human-readable key/value; `--json` emits the raw socket result. Shape matches existing v2 CLI conventions.

---

## Errors

| Code | When |
|------|------|
| `surface_not_found` | `surface_id` doesn't resolve. |
| `invalid_json` | `metadata` field is not a JSON object, or an invalid ref is supplied. |
| `payload_too_large` | Post-merge blob exceeds 64 KiB. |
| `reserved_key_invalid_type` | A canonical key was written with the wrong type or violates its size cap. Includes `key` in the detail. |
| `invalid_mode` | `mode` is not `"merge"` or `"replace"`. |
| `invalid_source` | `source` is not in the enum. |
| `invalid_keys_param` | `keys` is present but not an array of strings. |
| `replace_requires_explicit` | `mode: "replace"` was requested with a non-`explicit` source. |
| `lower_precedence` | Soft result — returned per-key in `applied: false`, not a top-level error. |

---

## Threading

All three methods are off-main (per `CLAUDE.md`'s socket threading policy):

1. Parse, validate, precedence-check, and merge off-main.
2. Apply mutation to the surface's in-memory blob off-main (guarded by a per-surface lock).
3. Any sidebar re-render scheduled via `DispatchQueue.main.async`.

A `surface.set_metadata` arriving during surface close is valid until the surface is deallocated: the precedence check runs, the write lands in the dying surface's blob, and the next `get_metadata` returns `surface_not_found`. Consumers treat lost writes as best-effort — no delivery guarantees when the target is mid-close.

---

## Test surface (mandatory)

Per the charter's testability principle, every behavior is verifiable from a headless test (no screen scraping).

- **Round-trip.** Set a full blob via `cmux set-metadata --json '{...}'`; read it back via `cmux get-metadata --json`. Assert deep equality.
- **Canonical key validation.** Write `role: 123` (wrong type) and assert `reserved_key_invalid_type`. Write `progress: 1.5` and assert the same.
- **Precedence ladder.** For each adjacent pair in `explicit > declare > osc > heuristic`: write the higher source, then attempt to overwrite with the lower source, assert `applied: false` and unchanged value. Then overwrite with equal-or-higher source, assert `applied: true`.
- **Merge vs replace.** Set `{a:1, b:2}`; merge `{b:3}`; assert `{a:1, b:3}`. Set `{a:1, b:2}`; replace `{c:4}`; assert `{c:4}` with sidecar reset.
- **Size cap.** Build a payload just under 64 KiB; merge. Build one over; assert `payload_too_large`.
- **Sidecar visibility.** `get-metadata` without `--sources` returns no `metadata_sources`; with `--sources` returns the full sidecar. Every canonical-key write produces a sidecar entry with a monotonic `ts`.
- **Clear with source gate.** Set a key with `source: explicit`; attempt `clear_metadata` with `source: heuristic`; assert `applied: false`. Clear with `source: explicit`; assert the key and its sidecar are gone.

All of the above are exercised via CLI; socket-level tests wrap the same JSON-RPC shapes directly.

---

## Non-goals

- **Push/subscribe.** Named and parked. Pull-on-demand is the only delivery mode in M2.
- **Persistence across restart.** Metadata lives in memory. Consumers that need durability own it.
- **Deep merge.** Nested object merges are full-value replacements. Consumers needing deep-merge compose client-side before writing.
- **Workspace/window-scoped metadata.** Surfaces only. Future modules may introduce parallel blobs; M2 does not reserve space for them.
- **Schema validation of non-canonical keys.** Anything outside the reserved table is opaque to c11mux.
