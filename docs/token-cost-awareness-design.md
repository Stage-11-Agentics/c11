# Token-Cost Awareness — Design (C11-174)

**Status:** Draft for operator review — architecture only, nothing implemented or merged.
**Ticket:** C11-174 · **Author:** Token Cost Arch (Fable), commissioned by the Sekhem Prime orchestrator.

c11 becomes the machine's source of truth for **model token economics**: every model's price
($/Mtok in/out, cache tiers), context length, and — for OpenRouter-routed models — per-provider
endpoint economics (price, throughput, latency, uptime). One poller refreshes it every ~24 h;
every consumer (the operator interactively, Sekhem Prime's deck programmatically, any agent in
any surface) just asks c11.

---

## 0. Research findings the design rests on

Probed live on 2026-07-20 (raw notes in the session scratchpad, `api-findings.md`):

1. **`GET /api/v1/models` requires no auth** and returns all 339 models with pricing
   (`$/token` decimal strings), context length, cache-read/write pricing, and a
   `links.details` pointer to the per-model endpoints API. One request covers the whole catalog.
2. **`GET /api/v1/models/{author}/{slug}/endpoints`** returns per-provider endpoints:
   `provider_name`, `tag` (the provider slug usable in `provider.order`), pricing, context,
   `quantization`, `status`, `uptime_last_{5m,30m,1d}`. **Throughput and latency
   (`throughput_last_30m` / `latency_last_30m`, percentile objects p50/p75/p90/p99) are only
   populated on authenticated requests** with the shared `OPENROUTER_API_KEY`. This is the
   data Sekhem v2's route selector needs, so the poller must be able to use a key.
3. **OpenRouter's mirror of native-provider pricing is accurate.** Verified Anthropic models
   against first-party list prices (Fable 5 $10/$50, Opus 4.8 $5/$25, Sonnet 5 at the $2/$10
   intro rate, Haiku 4.5 $1/$5 — cache tiers present too). Native providers (Anthropic, OpenAI,
   Google) expose **no pricing API at all** (Anthropic's Models API has capabilities/context but
   no price). Therefore: **OpenRouter is the single poll source for all models**, with a small
   static-overrides file for anything it lacks (see §2).
4. **Rate-limit etiquette matters**: the key is shared across all Stage 11 projects
   (`platform/openrouter.md`). The design budget is 1 catalog request + a small watchlist of
   endpoint requests per ~24 h — negligible, but explicitly never a hot loop.

Codebase survey (full map in C11-174 notes): no pricing/model-catalog code exists anywhere in
the repo — this is a greenfield subsystem with no naming collisions. The reusable patterns it
slots into are cited inline below.

---

## 1. Placement

**A shared logic core + a thin app-side scheduler**, compiled into both the app and CLI targets
(the same dual-target arrangement as `Sources/Events/EventLogLayout.swift`).

```
Sources/TokenCost/
  TokenCostCatalog.swift        // model of the catalog + JSON codec (schema v1)
  TokenCostStore.swift          // load/save at the state root; atomic writes; staleness check
  TokenCostFetcher.swift        // OpenRouter HTTP client: /models + watchlist /endpoints
  TokenCostRefresher.swift      // app-side singleton scheduler (DispatchSourceTimer)
```

- **Persistence** lives at `~/Library/Application Support/c11/token-cost/catalog.json`,
  resolved the same way `EventLogLayout.defaultStateURL()` resolves the state root, behind
  `StateDirectoryMigration.ensureMigrated(...)`. Atomic writes and a typed error enum modeled
  on `WorkspaceSnapshotStore.swift`.
- **The file is the contract** (same philosophy as the events stream): the CLI and any
  consumer read `catalog.json` directly, with no running app required — the `c11 events` /
  `c11 health` app-down precedent (`CLI/c11.swift:1711`).
- **The scheduler** is an app-level `@unchecked Sendable` singleton on a `.utility`
  `DispatchSourceTimer`, following `SurfaceMetricsSampler` (`Sources/SurfaceMetricsSampler.swift:38`),
  started from `AppDelegate.applicationDidFinishLaunching` next to the other pollers
  (`AppDelegate.swift:~2500`). The 24 h cadence precedent is `UpdateController.swift:12`.
- **Not the daemon**: `daemon/remote` is SSH-workspace transport, not a job host. The poller
  is in-process. **Not upstreamed**: an agent-facing economics primitive is squarely
  "operator:agent pair" territory — c11-only by design per CLAUDE.md's fork-positioning section.

## 2. Data model

`catalog.json`, schema v1. All prices normalized at ingest from OpenRouter's `$/token` strings
to **USD per Mtok** (the human- and deck-facing unit).

```jsonc
{
  "schema_version": 1,
  "source": "openrouter",
  "fetched_at": "2026-07-20T21:04:00Z",       // last successful /models fetch
  "models": {
    "anthropic/claude-fable-5": {
      "name": "Anthropic: Claude Fable 5",
      "provider": "anthropic",                 // author prefix of the id
      "input_usd_per_mtok": 10.0,
      "output_usd_per_mtok": 50.0,
      "cache_read_usd_per_mtok": 1.0,          // null when absent
      "cache_write_usd_per_mtok": 12.5,        // null when absent
      "context_length": 1048576,
      "max_output_tokens": 128000,
      "updated_at": "2026-07-20T21:04:00Z"
    }
    // ... all ~339 models
  },
  "endpoints": {                               // watchlist models only (see §3)
    "deepseek/deepseek-chat-v3.1": {
      "fetched_at": "2026-07-20T21:04:05Z",
      "authenticated": true,                   // whether throughput/latency could be populated
      "endpoints": [
        {
          "provider_name": "DeepInfra",
          "provider_slug": "deepinfra/fp4",    // OpenRouter `tag` — valid in provider.order
          "input_usd_per_mtok": 0.25,
          "output_usd_per_mtok": 0.95,
          "context_length": 163840,
          "quantization": "fp4",
          "throughput_tok_s": { "p50": 10, "p75": 12, "p90": 14, "p99": 20.6 },  // null unauth
          "latency_ms":       { "p50": 1113, "p75": 1886, "p90": 3220, "p99": 14413 },
          "uptime_30m_pct": 99.9,
          "status": 0
        }
      ]
    }
  },
  "overrides_applied": ["local/ollama-qwen3", "anthropic/claude-fable-5#cache_write_1h"]
}
```

**Static overrides** — `token-cost/overrides.json` beside the catalog (operator-editable,
never touched by the poller): entries merged over the fetched data at load time. This is the
escape hatch for the "all models" requirement beyond OpenRouter's reach — local models
(ollama/mlx at $0), models OpenRouter doesn't carry, or pricing fields it lacks (e.g.
Anthropic's 1 h cache-write tier). Sekhem v1's static bands can be expressed here too, making
v1 and v2 read the same shape.

## 3. Poller

- **Cadence:** every 24 h ± up to 5 min jitter. **Triggers:** app launch (fetch only if
  `fetched_at` is > 24 h old — so relaunches never re-poll), the timer, and an explicit
  `c11 token-cost refresh` (guarded by a 15 min minimum interval so a scripted loop can't
  hammer the shared key).
- **Requests per cycle:** 1 × `/models` (unauthenticated is sufficient) + N × `/endpoints` for
  the **watchlist** (`token-cost/watchlist.json`, default seeded with Sekhem's route models and
  the operator's daily drivers — final list is an open question, §6). Endpoints requests send
  `Authorization: Bearer` when a key is available so throughput/latency populate; without a key
  they still yield pricing/uptime with `"authenticated": false`.
- **Key sourcing:** `OPENROUTER_API_KEY` from the app/CLI environment when present. c11 never
  reaches into tenant config or the Stage 11 platform tree (that path is Atin's deployment
  detail, not a c11 assumption). A Settings-stored key (Keychain) is a possible later
  convenience — open question §6.
- **Failure behavior: serve stale, loudly.** On any fetch error the existing catalog stays
  untouched and queries keep answering from it; every answer carries `fetched_at` so consumers
  can render an age badge. Retry with backoff (1 h → 2 h → 4 h, capped) until a cycle
  succeeds. Failures are logged; optionally surfaced on the events stream (§4).
- **Concurrent writers** (CLI fetch-if-stale racing the app timer): atomic whole-file writes,
  last-writer-wins — both writers produce equivalent content, so no lock is needed beyond
  `.atomic`.

## 4. Query interface

**CLI** (primary surface for both operator and Sekhem):

```
c11 token-cost <model> [--json]        # one model's economics (fuzzy: "fable-5" matches anthropic/claude-fable-5)
c11 token-cost list [--provider anthropic] [--json]
c11 token-cost <model> --endpoints [--json]   # per-provider table for a watchlist model
c11 token-cost refresh [--json]        # force refresh (min-interval guarded)
```

Reads `catalog.json` directly (works with the app down). If the catalog is missing or > 24 h
stale, the CLI performs the fetch itself before answering — so the very first query on a fresh
machine works, and the app timer is an optimization, not a dependency.

**Socket v2** (for agents already holding a socket connection): `tokencost.get`,
`tokencost.list`, `tokencost.endpoints`, `tokencost.refresh` — one new prefix branch in
`v2DispatchExtracted` (`SocketDispatch.swift:886`), a handler file modeled on
`SystemHandlers.swift`, and all four methods in the `socketWorkerV2Methods` off-main allowlist
per the socket threading policy (they only read a file / kick a background fetch — no main-actor
work, no focus mutation).

**Events** (phase 2, optional): a `tokencost.refreshed` envelope on the NDJSON stream when a
cycle lands, payload `{fetched_at, model_count, watchlist_count, changed: n}`. Note this is a
**new precedent** — no background subsystem emits events today — so it's proposed, not assumed
(§6).

## 5. Sekhem Prime consumption (v2)

- **v1 keeps working with zero dependency**: static bands ship inside Sekhem; nothing here is
  in its path. Optionally the same band numbers get mirrored into `overrides.json` so both
  generations read one shape, but that's cosmetic.
- **v2**: Sekhem's Mac brain (same machine as c11) runs `c11 token-cost <model> --endpoints --json`
  per route model on its own display cadence — or reads `catalog.json` directly for zero
  subprocess cost. Route mapping from the endpoints array:
  - `CHEAPEST` (`:floor`) → endpoint with min `input+output` price → show its $/Mtok pair.
  - `FASTEST` (`:nitro`) → endpoint with max `throughput_tok_s.p50` → show its tok/s.
  - `DEFAULT` → the model-level price from `models{}`.
- **Degradation:** `fetched_at` older than ~48 h → deck renders last-known values with an age
  badge, or falls back to v1 static bands. Catalog absent entirely → v1 bands. The deck never
  blocks on c11.

## 6. Rollout & open questions

**Recommended path — small first cut, layered:**

| Phase | Scope | Delivers |
|---|---|---|
| 1 | `Sources/TokenCost/` core (catalog, store, fetcher) + `c11 token-cost` CLI with fetch-if-stale | The whole feature, minus background freshness — Sekhem v2 can build against this immediately |
| 2 | App-side `TokenCostRefresher` timer + socket v2 methods (+ optional `tokencost.refreshed` event) | Always-warm catalog; agent/socket ergonomics |
| 3 | UI surfaces if wanted (settings pane for key/watchlist, sidebar hints) | Operator polish |

Phase 1 alone satisfies the operator directives (24 h-fresh costs, all models, v1+v2 support);
phases 2–3 are ergonomics. Each phase is a normal C11 ticket → PR through the lattice-orchestrator
flow. Tests: the catalog codec, normalization ($/token string → $/Mtok), staleness logic, and
override merging are all pure logic → `c11LogicTests` (fast local loop); fetcher gets a
fixture-fed test, never a live-network test in the default suite.

**Decisions (operator interview, 2026-07-20):**

1. **Watchlist seed:** Sekhem's route models + the Anthropic/OpenAI daily drivers
   (fable-5, opus-4.8, sonnet-5, haiku-4.5, gpt-5.x). For the Anthropic/OpenAI entries the
   requirement is **the price the native API serves them at** — which the catalog's
   model-level pricing already is: OpenRouter's mirror matches first-party list prices exactly
   (verified §0.3), so `models{}` satisfies this directly; their endpoints entries add
   uptime/latency only.
2. **Key sourcing:** env var only (`OPENROUTER_API_KEY` from the launch environment); absent
   key degrades gracefully. No Keychain/Settings surface unless the Finder-launch gap ever
   bites in practice.
3. **Events:** emit `tokencost.refreshed` in **phase 2**, when the app-side timer ships — the
   first background-subsystem event on the stream, app-process-emitted only (the CLI
   fetch-if-stale path does not emit).
4. **CLI verb:** `c11 token-cost`, no `cost` alias.
5. **Model matching:** fuzzy for humans, exact for scripts — suffix/substring resolution
   (`fable-5` → `anthropic/claude-fable-5`); ambiguous input errors with the candidate list,
   never best-guesses; `--json` output echoes the resolved exact id. Sekhem passes exact ids.

With these settled the design is complete; next step on operator go-ahead is phase 1 as a
C11 ticket through the lattice-orchestrator flow.
