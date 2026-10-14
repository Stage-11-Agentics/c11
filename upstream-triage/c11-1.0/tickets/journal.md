| Backlog id | Ticket id | Title | Tier | Size | Deps (backlog ids) | Created or updated |
|---|---|---|---|---|---|---|
| F1 | C11-216 | Move c11 tagged builds, tests and release builds onto Atlas | P0 | M | — | updated |
| F2 | C11-270 | Gate c11 1.0 with a measured 40-agent fleet soak | P0 | M | F1 | created |
| F3 | C11-271 | Capture real lifecycle sequences as the journal and Feed fixture oracle | P0 | S | F1 | created |
| J1 | C11-272 | Specify the SQLite lifecycle journal and obtain cross-family plan review | P1 | M | F3 | created |
| J2 | C11-273 | Implement journal append, SQLite store, pure fold and bounded replay | P1 | L | J1 | created |
| J3 | C11-274 | Widen Claude lifecycle observations through per-process hooks | P1 | M | J2 | created |
| J4 | C11-275 | Gate Codex per-process lifecycle hooks on isolated trust proof | P1 | M | J2 | created |
| J5 | C11-276 | Emit advisory Codex and Grok turn edges from transcript observation | P1 | M | J2 | created |
| J6 | C11-231 | Expose journal-backed agent snapshots, waiting reasons, clocks and restore candidates | P1 | M | J2 | updated |
| J7 | C11-277 | Query lifecycle analytics and export the journal as NDJSON | P1 | M | J2 | created |
| J8 | C11-278 | Document bounded lifecycle hooks and sync the journal operating skill | P1 | S | J2, J6, J7 | created |
