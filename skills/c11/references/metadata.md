# c11 Per-Surface Metadata

Every surface in c11 carries an open-ended JSON metadata blob. Agents read and write it over the socket. c11 stores it, renders a narrow set of **canonical keys** in the sidebar and title bar, and leaves everything else opaque for consumers (Lattice, internal dashboards, future Stage 11 tooling). This is the transport — and the vocabulary — that lets a spike's agents speak to the room they are working in.

Canonical spec: [`docs/c11mux-module-2-metadata-spec.md`](../../../docs/c11mux-module-2-metadata-spec.md). This reference summarizes the agent-facing surface.

## Contents

- [Delivery model](#delivery-model)
- [Canonical keys](#canonical-keys)
- [CLI](#cli)
- [Socket methods](#socket-methods)
- [Precedence & sources](#precedence--sources)
- [Errors](#errors)
- [Consumer patterns](#consumer-patterns)

## Delivery model

- **Pull-on-demand only.** Consumers fetch the blob when they want the current state. No push/subscribe, no `metadata.changed` event.
- **In-memory only.** The blob lives on the `Surface` model in the running c11 process. It does not persist across app relaunch. Consumers that need durability own it.
- **Per-surface.** Keyed by the surface UUID. No workspace- or window-scoped metadata in v1.
- **64 KiB cap** on the serialized `metadata` object per surface. Writes that would exceed the cap return `payload_too_large`. Store large payloads externally (S3, Lattice attachments) and put a reference in the blob.

## Canonical keys

These keys have a defined shape and render in the sidebar or title bar. Any write to a canonical key that violates its type returns `reserved_key_invalid_type`. Writes to non-reserved keys accept any JSON value.

| Key | Type | Constraint | Rendering |
|-----|------|------------|-----------|
| `role` | string | kebab-case, ≤ 64 chars | sidebar: small label after tab title |
| `status` | string | ≤ 32 chars | sidebar: colored pill |
| `task` | string | ≤ 128 chars | sidebar: monospace tag |
| `model` | string | kebab-case, ≤ 64 chars | sidebar chip |
| `progress` | number | 0.0 – 1.0 | sidebar: progress bar |
| `terminal_type` | string | kebab-case, ≤ 32 chars | sidebar chip. Canonical values: `claude-code`, `codex`, `kimi`, `opencode`, `shell`, `unknown`. Open-ended. |
| `title` | string | plain text, ≤ 256 chars | title bar + sidebar tab label (truncated) |
| `description` | string | Markdown subset (bold/italic, inline `code`, lists, headings, blockquotes, links, rules — no images, fenced code, or tables), ≤ 2048 chars | title bar expanded region |

**Sidebar rendering order** when present: `model` → `terminal_type` → `role` → `status` → `task` → `progress`. `title` and `description` render in the title bar, not the sidebar — the sidebar tab label is a truncated projection of `title`.

**Non-canonical keys are yours.** Any JSON value, any key shape. The blob is Lattice's transport, your app's transport, your orchestrator's transport — c11 does not interpret non-canonical content.

## CLI

All CLI commands are sugar over the socket methods below.

```bash
# Write (merge by default)
cmux set-metadata --json '{"role":"reviewer","task":"lat-412","progress":0.4}'
cmux set-metadata --key status --value "running"
cmux set-metadata --key progress --value 0.6 --type number
cmux set-metadata --key config --value '{"shards":10}' --type json

# Replace (wipes everything; requires explicit source)
cmux set-metadata --mode replace --json '{"role":"fresh"}'

# Read
cmux get-metadata                    # full blob, no sources
cmux get-metadata --key role --key model
cmux get-metadata --sources          # include metadata_sources sidecar
cmux get-metadata --json             # raw socket result

# Clear
cmux clear-metadata --key task
cmux clear-metadata                  # clear everything (requires explicit source)
```

### Agent-declaration sugar (M1)

`cmux set-agent` is a wrapper over `set-metadata` with `source: declare`:

```bash
cmux set-agent --type claude-code --model claude-opus-4-7
cmux set-agent --type codex --task lat-412 --role reviewer
```

Writes `terminal_type`, and optionally `model`, `task`, `role` with `source: declare`. Declaration overrides heuristic auto-detection but not user-explicit writes. Clear with `cmux clear-metadata --key terminal_type`.

### Title & description sugar (M7)

```bash
cmux set-title "My Surface Title"
cmux set-title --from-file /tmp/title.txt
cmux set-description "Long-form description of what this surface is doing and why."
cmux set-description --from-file /tmp/desc.md

# Read the rendered title-bar state (title, description, sources, collapsed,
# effective_collapsed, visible, sidebar_label). Defaults to caller's surface.
cmux get-titlebar-state
cmux get-titlebar-state --surface surface:3
```

Writes canonical `title` or `description` with `source: explicit`. `cmux rename-tab` is an alias for `cmux set-title`.

The description renders with MarkdownUI at 11pt with a compact heading hierarchy (13/12/11). Links render styled but are **not navigable** in v1 (`OpenURLAction { .discarded }`). Images, fenced code blocks, and table rows are stripped at render time; the raw string still round-trips through the store unchanged. Content over ~5 lines scrolls internally inside a 90pt-capped region.

When `description` is empty the title bar renders as collapsed regardless of the flag (`effective_collapsed = collapsed || description.isEmpty`) — this is what the socket payload's `effective_collapsed` field reports.

## Socket methods

All methods follow the v2 JSON-RPC convention. Responses: `{"id", "ok", "result"}`.

### `surface.set_metadata`

Merge a partial metadata object into the surface's blob.

```json
{
  "method": "surface.set_metadata",
  "params": {
    "surface_id": "<uuid-or-ref>",
    "mode": "merge",
    "source": "explicit",
    "metadata": { "role": "reviewer", "task": "lat-412" }
  }
}
```

| Param | Required | Notes |
|-------|----------|-------|
| `surface_id` | yes | UUID or ref; defaults to focused surface |
| `metadata` | yes | Partial or full object; ≤ 64 KiB post-merge |
| `mode` | no | `"merge"` (default, shallow) or `"replace"` (requires `source: explicit`) |
| `source` | no | Default `"explicit"`; other values: `"declare"`, `"osc"`, `"heuristic"` |

Semantics: shallow merge (nested objects are replaced, not deep-merged). Per-key precedence — some keys may land, others may be rejected with `applied: false`.

Result includes `applied` (per-key booleans), `reasons` (for rejected keys), and the full `metadata` / `metadata_sources` after the write.

### `surface.get_metadata`

```json
{
  "method": "surface.get_metadata",
  "params": { "surface_id": "<uuid-or-ref>", "keys": ["role","model"], "include_sources": true }
}
```

| Param | Required | Notes |
|-------|----------|-------|
| `surface_id` | yes | UUID or ref; defaults to focused surface |
| `keys` | no | Return only these keys; omit for full blob |
| `include_sources` | no | Default `false`; when `true`, response includes `metadata_sources` |

### `surface.clear_metadata`

```json
{
  "method": "surface.clear_metadata",
  "params": { "surface_id": "<uuid-or-ref>", "keys": ["task"], "source": "explicit" }
}
```

Omit `keys` to clear everything (requires `source: explicit`). Precedence applies as in `set_metadata`.

## Precedence & sources

Every canonical key's value carries a parallel `metadata_sources[key]` record describing who wrote it and when.

```json
{
  "metadata": { "terminal_type": "claude-code", "model": "claude-opus-4-7" },
  "metadata_sources": {
    "terminal_type": { "source": "heuristic", "ts": 1713313200.123 },
    "model":         { "source": "declare",   "ts": 1713313201.456 }
  }
}
```

### Source enum

| Value | Writer | Notes |
|-------|--------|-------|
| `heuristic` | c11 internal process-tree scan (M1) | Best-effort auto-detection. Never overwrites higher-precedence values. |
| `osc` | Terminal emulator OSC 0/1/2 sequence (M7) | Writes `title` only. Newer OSC writes overwrite older `osc` writes. |
| `declare` | Agent declaration (`cmux set-agent`, env vars) | Explicit agent self-identification. |
| `explicit` | User CLI (`cmux set-metadata`, `cmux set-title`, inline edit) | Highest precedence; user intent wins. |

### Precedence chain

```
explicit > declare > osc > heuristic
```

- **`explicit` always wins.** `cmux set-metadata` overwrites any prior value.
- **`declare` overwrites `osc` and `heuristic`**, not `explicit`.
- **`osc` overwrites `heuristic`** and older `osc`, not `declare` or `explicit`.
- **`heuristic` only writes when the key is unset or current source is `heuristic`.**

A write that fails the precedence check returns `ok: true` with `result.applied[key]: false` and `result.reasons[key]: "lower_precedence"`. The current value is left untouched.

**Clear semantics.** `clear_metadata` with `source: explicit` always succeeds. A clear from a lower-precedence writer only succeeds if the current source is at or below the caller's.

## Errors

| Code | When |
|------|------|
| `surface_not_found` | `surface_id` doesn't resolve |
| `invalid_json` | `metadata` is not a JSON object, or a ref is invalid |
| `payload_too_large` | Post-merge blob exceeds 64 KiB |
| `reserved_key_invalid_type` | Canonical key written with wrong type or size; `detail.key` names it |
| `invalid_mode` | `mode` is not `"merge"` or `"replace"` |
| `invalid_source` | `source` is not in the enum |
| `invalid_keys_param` | `keys` is present but not an array of strings |
| `replace_requires_explicit` | `mode: "replace"` requested with non-`explicit` source |
| `lower_precedence` | Soft; per-key in `applied: false`, not a top-level error |

## Consumer patterns

**Lattice.** Writes `task` and `role` on the orchestrator's surface and on each sub-agent's surface. Polls `get_metadata` on a ticket's known surfaces to render aggregate state in the Lattice UI. `source: declare` for automated writes; `source: explicit` for user-driven writes in the Lattice UI.

**Orchestrators.** Write `status`, `progress`, `role` at each milestone. The orchestrator does not need to ping the operator — canonical keys drive sidebar chips and title bars. Also use `title` / `description` for high-signal surface identity ("SIG Delegator", "Running smoke suite across 10 shards; reports to Lattice task lat-412").

**Handoffs.** Structured handoffs between agents can ride on non-canonical keys — e.g. agent A writes `cmux set-metadata --json '{"handoff":{"from":"A","to":"B","result":{...}}}'` on agent B's surface; agent B polls `get-metadata --key handoff` at its prompt loop. Pull-on-demand, no subscribe.

**Custom surfaces.** Any app that creates a c11 surface (via the socket `surface.create` method) owns that surface's metadata. Use it to carry domain-specific state — a markdown viewer could write `{"doc_path":"/path/to/file.md","last_modified_ts":...}` on its own surface so other agents can pull the current doc without asking.
