# Model token-cost research — 2026-07-30

First fill for the c11 launch-picker token-cost catalog (`model-costs.json`, read by
`Sources/ModelCostCatalog.swift`). Every number below was pulled from the vendor's own
pricing page today, or from OpenRouter's public model API where the model only exists on a
router. Nothing here comes from memory.

**Retrieval date: 2026-07-30.** All figures are **USD per million tokens, API list price**.

## Scope and caveats

- **List price only.** Claude Max, the Codex subscription and the Kimi coding plan all change
  the marginal cost of a token to roughly zero until you hit a cap. This catalog is a
  *relative magnitude* signal for the picker, not billing truth.
- **Cache and long-context rates are in `notes`, not in the headline numbers.** Where a
  model's headline input price is misleading without them (Kimi's 10-20x cache-hit discount,
  DeepSeek's 50x one, the 200k/272k long-context tiers on Gemini Pro, Grok and GPT-5.4+),
  the caveat is recorded on the entry.
- **Batch pricing is excluded.** Most vendors run 50% off for batch; that's a different
  execution mode from an interactive agent launch.
- `:free` OpenRouter tiers are recorded at $0/$0, which is accurate but rate-limited.


## Anthropic — Claude (harness: `claude-code`, `github-copilot`)

Source: [platform.claude.com models overview](https://platform.claude.com/docs/en/about-claude/models/overview.md). `opus`/`sonnet`/`haiku`/`fable` are the family ids c11's `claude-code` picker uses (`ClaudeModelFamily`). Anthropic Max/Pro subscribers pay none of this per token until they hit a cap.

| Model id | $in /MTok | $out /MTok | Notes |
|---|---|---|---|
| `fable` | $10 | $50 |  |
| `claude-fable-5` | $10 | $50 |  |
| `opus` | $5 | $25 |  |
| `claude-opus-5` | $5 | $25 |  |
| `sonnet` | $3 | $15 | Introductory pricing of $2/$10 per MTok applies through 2026-08-31; $3/$15 is the standing list price. |
| `claude-sonnet-5` | $3 | $15 | Introductory pricing of $2/$10 per MTok applies through 2026-08-31; $3/$15 is the standing list price. |
| `haiku` | $1 | $5 |  |
| `claude-haiku-4-5` | $1 | $5 |  |
| `claude-opus-4-8` | $5 | $25 |  |
| `claude-opus-4-7` | $5 | $25 |  |
| `claude-opus-4-6` | $5 | $25 |  |
| `claude-sonnet-4-6` | $3 | $15 |  |
| `claude-opus-4-1` | $15 | $75 | Deprecated; retires 2026-08-05. |

## OpenAI (harness: `codex`, `github-copilot`)

Source: [developers.openai.com/api/docs/pricing](https://developers.openai.com/api/docs/pricing). Bare ids are what the `codex` harness takes.

| Model id | $in /MTok | $out /MTok | Notes |
|---|---|---|---|
| `gpt-5.6-sol` | $5 | $30 |  |
| `gpt-5.6-terra` | $2 | $12 | OpenAI list price. GPT-5.6 Terra/Luna are running a time-limited 50% discount (OpenRouter currently quotes the discounted rate). |
| `gpt-5.6-luna` | $0.2 | $1.2 | OpenAI list price. GPT-5.6 Terra/Luna are running a time-limited 50% discount (OpenRouter currently quotes the discounted rate). |
| `gpt-5.5` | $5 | $30 |  |
| `gpt-5.5-pro` | $30 | $180 |  |
| `gpt-5.4` | $2.5 | $15 | Prompts over 272k tokens bill at a higher long-context rate. |
| `gpt-5.4-mini` | $0.75 | $4.5 |  |
| `gpt-5.4-nano` | $0.2 | $1.25 |  |
| `gpt-5.4-pro` | $30 | $180 |  |
| `gpt-5.2` | $1.75 | $14 |  |
| `gpt-5.2-pro` | $21 | $168 |  |
| `gpt-5.1` | $1.25 | $10 |  |
| `gpt-5` | $1.25 | $10 |  |
| `gpt-5-mini` | $0.25 | $2 |  |
| `gpt-5-nano` | $0.05 | $0.4 |  |
| `gpt-5-pro` | $15 | $120 |  |
| `gpt-5.3-codex` | $1.75 | $14 |  |
| `gpt-5.2-codex` | $1.75 | $14 |  |
| `gpt-5.1-codex-max` | $1.25 | $10 |  |
| `gpt-5.1-codex` | $1.25 | $10 |  |
| `gpt-5.1-codex-mini` | $0.25 | $2 |  |
| `codex-mini-latest` | $1.5 | $6 |  |

## Google Gemini

Source: [ai.google.dev/gemini-api/docs/pricing](https://ai.google.dev/gemini-api/docs/pricing) (paid tier).

| Model id | $in /MTok | $out /MTok | Notes |
|---|---|---|---|
| `gemini-3.6-flash` | $1.5 | $7.5 |  |
| `gemini-3.5-flash` | $1.5 | $9 |  |
| `gemini-3.5-flash-lite` | $0.3 | $2.5 |  |
| `gemini-3.1-pro-preview` | $2 | $12 | Prompts over 200k tokens bill at a higher long-context rate. ($4/$18) |
| `gemini-3.1-flash-lite` | $0.25 | $1.5 |  |
| `gemini-2.5-pro` | $1.25 | $10 | Prompts over 200k tokens bill at a higher long-context rate. ($2.50/$15) |
| `gemini-2.5-flash` | $0.3 | $2.5 |  |
| `gemini-2.5-flash-lite` | $0.1 | $0.4 |  |

## xAI Grok (harness: `grok`)

Source: [docs.x.ai/docs/models](https://docs.x.ai/docs/models). Every Grok model doubles its rate once a request reaches 200k prompt tokens — and the higher rate applies to *all* tokens in that request, not just the overflow.

| Model id | $in /MTok | $out /MTok | Notes |
|---|---|---|---|
| `grok-4.5` | $2 | $6 | Requests at or above 200k prompt tokens bill every token at the higher long-context rate. ($4/$12) |
| `grok-4.3` | $1.25 | $2.5 | Requests at or above 200k prompt tokens bill every token at the higher long-context rate. ($2.50/$5) |
| `grok-build-0.1` | $1 | $2 | Requests at or above 200k prompt tokens bill every token at the higher long-context rate. ($2/$4) |
| `grok-4.20-0309-reasoning` | $1.25 | $2.5 | Requests at or above 200k prompt tokens bill every token at the higher long-context rate. ($2.50/$5) |
| `grok-4.20-0309-non-reasoning` | $1.25 | $2.5 | Requests at or above 200k prompt tokens bill every token at the higher long-context rate. ($2.50/$5) |

## Moonshot / Kimi (harness: `kimi`)

Sources: Kimi platform per-model pricing pages ([K3](https://platform.kimi.ai/docs/pricing/chat-k3.md), [K2.7 Code](https://platform.kimi.ai/docs/pricing/chat-k27-code.md), [K2.6](https://platform.kimi.ai/docs/pricing/chat-k26.md), [K2.5](https://platform.kimi.ai/docs/pricing/chat-k25.md), [Moonshot V1](https://platform.kimi.ai/docs/pricing/chat-v1.md)). Headline input is the **cache-miss** rate; Kimi's cache-hit rate is ~10-20x cheaper.

| Model id | $in /MTok | $out /MTok | Notes |
|---|---|---|---|
| `kimi-k3` | $3 | $15 | Cache-hit input is far cheaper ($0.30/MTok); the headline figure is the cache-miss rate. |
| `kimi-k2.7-code` | $0.95 | $4 | Cache-hit input is far cheaper ($0.19/MTok); the headline figure is the cache-miss rate. |
| `kimi-k2.7-code-highspeed` | $1.9 | $8 | Cache-hit input is far cheaper ($0.38/MTok); the headline figure is the cache-miss rate. |
| `kimi-k2.6` | $0.95 | $4 | Cache-hit input is far cheaper ($0.16/MTok); the headline figure is the cache-miss rate. |
| `kimi-k2.5` | $0.6 | $3 | Cache-hit input is far cheaper ($0.10/MTok); the headline figure is the cache-miss rate. |
| `moonshot-v1-128k` | $2 | $5 |  |
| `moonshot-v1-32k` | $1 | $3 |  |
| `moonshot-v1-8k` | $0.2 | $2 |  |

## DeepSeek (first-party API)

Source: [api-docs.deepseek.com/quick_start/pricing](https://api-docs.deepseek.com/quick_start/pricing). Only two models are offered first-party now; the v3.x line survives only via routers.

| Model id | $in /MTok | $out /MTok | Notes |
|---|---|---|---|
| `deepseek-v4-flash` | $0.14 | $0.28 | Cache-hit input is $0.0028/MTok. |
| `deepseek-v4-pro` | $0.435 | $0.87 | Cache-hit input is $0.003625/MTok. |

## OpenRouter — top 10 by weekly traffic

Ranking read off [openrouter.ai/rankings](https://openrouter.ai/rankings) (weekly token
volume, rendered in the c11 browser since the page is client-side). Prices from
[openrouter.ai/api/v1/models](https://openrouter.ai/api/v1/models).

The shape of this list is worth noting for the picker: **eight of the top ten are
open-weight Chinese or free-tier models**, and the most-used model on the router is two
orders of magnitude cheaper than Opus. The frontier US models barely register in raw token
volume.

| Model id | $in /MTok | $out /MTok | Notes |
|---|---|---|---|
| `xiaomi/mimo-v2.5` | $0.14 | $0.28 | OpenRouter #1 by weekly tokens (9.77T). |
| `deepseek/deepseek-v4-flash` | $0.14 | $0.28 | OpenRouter #2 by weekly tokens (7.3T). |
| `tencent/hy3` | $0.132 | $0.528 | OpenRouter #3 by weekly tokens (4.9T). |
| `deepseek/deepseek-v4-pro` | $0.435 | $0.87 | OpenRouter #4 by weekly tokens (3.55T). |
| `z-ai/glm-5.2` | $0.966 | $3.036 | OpenRouter #5 by weekly tokens (3.14T). |
| `nvidia/nemotron-3-ultra-550b-a55b:free` | $0 | $0 | OpenRouter #6 by weekly tokens (2.7T); free tier, $0/$0. |
| `minimax/minimax-m3` | $0.3 | $1.2 | OpenRouter #7 by weekly tokens (2.03T). |
| `stepfun/step-3.7-flash` | $0.2 | $1.15 | OpenRouter #8 by weekly tokens (1.85T). |
| `moonshotai/kimi-k3` | $3 | $15 | OpenRouter #9 by weekly tokens (1.34T). |
| `inclusionai/ling-3.0-flash:free` | $0 | $0 | OpenRouter #10 by weekly tokens (1.07T); free tier, $0/$0. |

## Router forms (`provider/model`)

These are the keys an opencode / pi / omp router config would use. Prices are OpenRouter's
own quoted rates, which can differ from the vendor's list price when a promotion is running.

| Model id | $in /MTok | $out /MTok | Notes |
|---|---|---|---|
| `anthropic/claude-fable-5` | $10 | $50 |  |
| `anthropic/claude-haiku-4.5` | $1 | $5 |  |
| `anthropic/claude-opus-4-8` | $5 | $25 | c11's router seed spells this with dashes; OpenRouter's actual slug is anthropic/claude-opus-4.8. Same price either way. |
| `anthropic/claude-opus-4.8` | $5 | $25 |  |
| `anthropic/claude-opus-5` | $5 | $25 |  |
| `anthropic/claude-sonnet-5` | $2 | $10 | OpenRouter currently quotes Anthropic's $2/$10 introductory Sonnet 5 rate (standing list price is $3/$15, from 2026-09-01). |
| `deepseek/deepseek-chat-v3.1` | $0.25 | $0.95 |  |
| `deepseek/deepseek-r1` | $0.7 | $2.5 |  |
| `google/gemini-3.1-flash-lite` | $0.25 | $1.5 |  |
| `google/gemini-3.1-pro-preview` | $2 | $12 | Long-context tier above 200k prompt tokens: $4/$18. |
| `google/gemini-3.6-flash` | $1.5 | $7.5 |  |
| `meta-llama/llama-3.1-8b-instruct` | $0.05 | $0.08 |  |
| `meta-llama/llama-3.3-70b-instruct` | $0.13 | $0.4 |  |
| `meta-llama/llama-4-maverick` | $0.2 | $0.8 |  |
| `meta-llama/llama-4-scout` | $0.1 | $0.3 |  |
| `moonshotai/kimi-k2` | $0.57 | $2.3 | Superseded upstream: Moonshot's own pricing docs no longer list kimi-k2; OpenRouter still routes it. |
| `moonshotai/kimi-k2.6` | $0.95 | $4 |  |
| `moonshotai/kimi-k2.7-code` | $0.73 | $3.5 |  |
| `openai/gpt-5.2` | $1.75 | $14 |  |
| `openai/gpt-5.2-codex` | $1.75 | $14 |  |
| `openai/gpt-5.3-codex` | $1.75 | $14 |  |
| `openai/gpt-5.4` | $2.5 | $15 | Long-context tier above 272k prompt tokens: $5/$22.50. |
| `openai/gpt-5.5` | $5 | $30 | Tiered pricing: longer prompts bill at a higher rate. |
| `openai/gpt-5.6-luna` | $0.1 | $0.6 | Reflects OpenAI's time-limited 50% GPT-5.6 discount; list price is $0.20/$1.20. Tiered pricing: longer prompts bill at a higher rate. |
| `openai/gpt-5.6-sol` | $5 | $30 | Tiered pricing: longer prompts bill at a higher rate. |
| `openai/gpt-5.6-terra` | $1 | $6 | Reflects OpenAI's time-limited 50% GPT-5.6 discount; list price is $2/$12. Tiered pricing: longer prompts bill at a higher rate. |
| `qwen/qwen3-coder` | $0.3 | $1 |  |
| `qwen/qwen3.7-max` | $1.475 | $4.425 |  |
| `x-ai/grok-4.20` | $1.25 | $2.5 | Tiered pricing: longer prompts bill at a higher rate. |
| `x-ai/grok-4.3` | $1.25 | $2.5 | Long-context tier at/above 200k prompt tokens: $2.50/$5. |
| `x-ai/grok-4.5` | $2 | $6 | Long-context tier at/above 200k prompt tokens: $4/$12. |
| `x-ai/grok-build-0.1` | $1 | $2 | Tiered pricing: longer prompts bill at a higher rate. |

## Findings that affect c11 beyond the price table

`Sources/AgentConfigEditorModel.swift` still carries the v1 seed catalog, and four of its
model ids no longer exist upstream. They are deliberately **absent** from the JSON draft —
`ModelCostCatalogStore.cost(forModel:)` returns `nil` and the picker shows no cost, which is
the right failure mode. Fabricating a price for a dead id would be worse:

| Stale id in c11 | Status | Current equivalent |
|---|---|---|
| `openai/gpt-5.2-mini` (and freeform `gpt-5.2-mini`) | Never existed / retired | `openai/gpt-5.4-mini`, `openai/gpt-5-mini` |
| `google/gemini-3-pro` | No text model by that slug on OpenRouter | `google/gemini-3.1-pro-preview` |
| `x-ai/grok-4` (and freeform `grok-4`) | Retired | `x-ai/grok-4.5`, `x-ai/grok-4.3` |
| `grok-4-fast` | Retired | `grok-4.3`, `grok-build-0.1` |
| `moonshotai/kimi-k2` / `kimi-k2` | Dropped from Moonshot's own pricing docs; still routed by OpenRouter | `kimi-k3`, `kimi-k2.7-code` |

`kimi-k2` **is** priced in the draft (via OpenRouter) since the route still works; the other
four are not.

Also: c11's router seed writes `anthropic/claude-opus-4-8`, but OpenRouter's slug is
`anthropic/claude-opus-4.8` (dot, not dash). Both keys are in the JSON at the same price so
the picker resolves either spelling, but the seed list should be corrected.

## Method

1. Anthropic, OpenAI, Google, xAI, DeepSeek and Moonshot prices came from each vendor's own
   pricing documentation, fetched today. OpenAI and Moonshot both 301 to new hosts
   (`developers.openai.com`, `platform.kimi.ai`) — the old `platform.openai.com/docs/pricing`
   and `platform.moonshot.ai` URLs are stale bookmarks.
2. Router and OpenRouter-only models came from `https://openrouter.ai/api/v1/models`, whose
   `pricing.prompt` / `pricing.completion` fields are per-token USD strings; multiplied by
   1e6 for the table.
3. The traffic ranking required rendering `openrouter.ai/rankings` in a browser surface —
   the model names are not in the served HTML, and the frontend JSON endpoints are gated.
4. Model ids were reconciled against `ClaudeModelFamily` (`Sources/DefaultAgentConfig.swift`)
   and `routerModelCatalog` / `freeformSuggestions` (`Sources/AgentConfigEditorModel.swift`)
   so the keys match what the picker will actually look up.

## Refresh guidance

Prices moved fast this cycle — GPT-5.2's input price halved over ~90 days, and the GPT-5.6
line is mid-promotion right now. A quarterly refresh is the floor; anything touching the
GPT-5.6 entries should be re-checked after the discount window closes. The OpenRouter API is
the cheapest bulk refresh path (one request covers every router key); the six first-party
pages have to be fetched individually.
