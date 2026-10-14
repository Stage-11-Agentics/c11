# Brief: model token-cost research for the c11 launch picker

You are a research agent. The c11 agent launch picker (A-button popover) is growing a
**token-cost catalog**: each config row will show `$in/$out` per Mtok. The catalog will
live as an agent-updatable file, refreshed occasionally by runs like this one. You are
producing its first fill.

## Task

Research **current API list prices** (USD per million tokens, input and output) for the
models an operator plausibly launches from c11's harnesses (claude-code, codex, kimi,
grok, opencode/pi/omp router models, github-copilot). Cover at minimum:

- **Anthropic**: current Claude 5 family (Fable/Opus/Sonnet) + Haiku 4.5 — use the
  claude-api skill / official pricing page, not memory.
- **OpenAI**: the current GPT-5.x line and codex-targeted models.
- **Google**: current Gemini Pro/Flash line.
- **Moonshot (Kimi)**, **DeepSeek**, **xAI (Grok)**, **Meta Llama via OpenRouter**,
  and the top ~10 models by traffic on OpenRouter (their pricing pages are public).

Rules:
- Web-verify every number (official pricing pages first, OpenRouter as fallback for
  router models). No prices from memory. Note cache-read/long-context surcharges only
  in a `notes` field if a model's headline price is misleading without them.
- Subscription plans (Max, Codex sub, Kimi coding plan) are OUT of scope — this catalog
  is API list price as a relative magnitude signal, and a `notes` caveat is enough.

## Deliverables

1. `notes/model-cost-research-2026-07-30.md` — human-readable table with source URLs
   and retrieval date.
2. `notes/model-costs-draft-2026-07-30.json` — machine-readable draft, schema:
   `{ "<model-id>": { "in_usd": <num>, "out_usd": <num>, "source": "<url>", "observed_at": "2026-07-30", "notes": "<optional>" } }`
   Use the model ids as c11 knows them (kebab ids like `opus`, `sonnet`, full ids like
   `claude-opus-5`, router forms like `deepseek/deepseek-chat-v3.1`) — include both the
   short and full form as separate keys when both are in circulation.

Work from `/Users/atin/Projects/Stage11/code/c11`. When finished, report completion in
one message to the caller:
`c11 send --workspace 7B4D2337-7CE2-4C91-A460-9633F016C8BC --surface 3D9A25AE-66DE-4F74-A061-6F6457657C70 "MODEL-COSTS <done|blocked>: <one-line summary + file paths>"`
Report recoverable problems the same way; raise a c11 flag only if operator action is
truly required.
