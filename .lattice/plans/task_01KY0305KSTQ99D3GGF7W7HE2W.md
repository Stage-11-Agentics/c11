# C11-174: Token-cost awareness: model pricing catalog + 24h OpenRouter poller + query surface (architecture)

Architect c11 as the source of truth for model token cost. Deliverable: design doc (docs/token-cost-awareness-design.md) covering placement, data model (all-models pricing + per-provider OpenRouter endpoints economics), 24h poller with persistence and stale-serve, and query surface (CLI/socket/events) for operator + Sekhem Prime v2 deck consumption. Commissioned by Sekhem Prime orchestrator; architecture only until operator review.
