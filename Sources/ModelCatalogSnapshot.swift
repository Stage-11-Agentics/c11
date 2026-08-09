import Foundation

// GENERATED FILE — do not edit by hand.
//
// Regenerate with:
//     scripts/generate-model-catalog-snapshot.sh                       # live CLIs
//     scripts/generate-model-catalog-snapshot.sh --from c11Tests/Fixtures/model-catalog
//
// The offline tier of the model catalog (C11-203 Part D): the rows the
// harness CLIs published when this file was generated, in the same raw
// form live enumeration produces, so the merge has one code path.
//
// 1442 raw records → 629 models across 57 providers:
//   openai: 177
//   anthropic: 41
//   google: 84
//   moonshot: 15
//   xai: 15
//   deepseek: 15
//   qwen: 61
//   mistral: 26
//   meta: 13
//   zai: 16
//   opencode: 8
//   ai21: 1
//   aion-labs: 4
//   allenai: 2
//   amazon: 5
//   anthracite-org: 1
//   arcee-ai: 7
//   baidu: 4
//   bytedance: 1
//   bytedance-seed: 4
//   cognitivecomputations: 1
//   cohere: 5
//   deepcogito: 1
//   essentialai: 1
//   gryphe: 1
//   ibm-granite: 2
//   inception: 3
//   inclusionai: 9
//   kwaipilot: 4
//   liquid: 1
//   mancer: 1
//   meituan: 2
//   microsoft: 2
//   minimax: 10
//   morph: 2
//   nex-agi: 4
//   nousresearch: 5
//   nvidia: 14
//   openrouter: 11
//   perceptron: 1
//   perplexity: 5
//   poolside: 8
//   prime-intellect: 1
//   reka: 1
//   rekaai: 2
//   relace: 2
//   sakana: 1
//   sao10k: 4
//   stepfun: 3
//   tencent: 4
//   thedrummer: 4
//   thinkingmachines: 3
//   tngtech: 2
//   undi95: 1
//   upstage: 2
//   writer: 1
//   xiaomi: 5

enum ModelCatalogSnapshot {
    /// When the capture behind this snapshot was taken.
    static let generatedAtISO8601 = "2026-08-09T01:35:29Z"
    static let generatedAt: Date? = ISO8601DateFormatter().date(from: generatedAtISO8601)

    /// Raw rows, decoded once.
    static let records: [RawCatalogRecord] = ModelCatalogRecordCodec.decode(tsv)

    /// harness, rawID, displayName, context, efforts, flags, providerHint.
    static let tsv = #"""
claude-code	opus	Opus		-		anthropic
claude-code	sonnet	Sonnet		-		anthropic
claude-code	haiku	Haiku		-		anthropic
claude-code	fable	Fable		-		anthropic
codex	gpt-5.6-astra	GPT-5.6 Astra		-	soon	openai			4
codex	gpt-5.3-codex-spark	GPT-5.3-Codex-Spark	128000	low,medium,high,xhigh		openai	high		26
codex	gpt-5.4	GPT-5.4	272000	low,medium,high,xhigh		openai	medium	gpt-5.6-terra	16	GPT-5.4 will be deprecated soon\n\nCodex now uses GPT-5.6 Terra in place of GPT-5.4. Switch to GPT-5.6 Terra to continue.\n
codex	gpt-5.4-mini	GPT-5.4-Mini	272000	low,medium,high,xhigh		openai	medium	gpt-5.6-luna	23	GPT-5.4 Mini will be deprecated soon\n\nCodex now uses GPT-5.6 Luna in place of GPT-5.4 Mini. Switch to GPT-5.6 Luna to continue.\n
codex	gpt-5.5	GPT-5.5	272000	low,medium,high,xhigh		openai	medium		7
codex	gpt-5.6-luna	GPT-5.6-Luna	272000	low,medium,high,xhigh,max		openai	medium		3
codex	gpt-5.6-sol	GPT-5.6-Sol	272000	low,medium,high,xhigh,max,ultra		openai	low		1
codex	gpt-5.6-sol-wm	GPT-5.6-Sol-WM	272000	low,medium,high,xhigh,max,ultra		openai	low		1
codex	gpt-5.6-terra	GPT-5.6-Terra	272000	low,medium,high,xhigh,max,ultra		openai	medium		2
grok	grok-4.5			-		xai
kimi	k3	K3	1048576	low,high,max		moonshot	high
kimi	k3-256k	K3-256k	262144	low,high,max		moonshot	high
kimi	kimi-for-coding	K2.7 Coding	262144	0		moonshot
kimi	kimi-for-coding-highspeed	K2.7 Coding Highspeed	262144	0		moonshot
omp	google/antigravity-preview-05-2026		131000	0		google
omp	google/deep-research-max-preview-04-2026		131000	0		google
omp	google/deep-research-preview-04-2026		131000	0		google
omp	google/deep-research-pro-preview-12-2025		131000	minimal,low,medium,high		google
omp	google/gemini-1.5-flash		1000000	0		google
omp	google/gemini-1.5-flash-8b		1000000	0		google
omp	google/gemini-1.5-pro		1000000	0		google
omp	google/gemini-2.0-flash		1000000	0		google
omp	google/gemini-2.0-flash-001		1000000	0		google
omp	google/gemini-2.0-flash-lite		1000000	0		google
omp	google/gemini-2.0-flash-lite-001		1000000	0		google
omp	google/gemini-2.5-computer-use-preview-10-2025		131000	minimal,low,medium,high		google
omp	google/gemini-2.5-flash		1000000	minimal,low,medium,high		google
omp	google/gemini-2.5-flash-image		33000	minimal,low,medium,high		google
omp	google/gemini-2.5-flash-lite		1000000	minimal,low,medium,high		google
omp	google/gemini-2.5-flash-lite-preview-06-17		1000000	minimal,low,medium,high		google
omp	google/gemini-2.5-flash-lite-preview-09-2025		1000000	minimal,low,medium,high		google
omp	google/gemini-2.5-flash-preview-04-17		1000000	minimal,low,medium,high		google
omp	google/gemini-2.5-flash-preview-05-20		1000000	minimal,low,medium,high		google
omp	google/gemini-2.5-flash-preview-09-2025		1000000	minimal,low,medium,high		google
omp	google/gemini-2.5-flash-preview-tts		8200	minimal,low,medium,high		google
omp	google/gemini-2.5-pro		1000000	minimal,low,medium,high		google
omp	google/gemini-2.5-pro-preview-05-06		1000000	minimal,low,medium,high		google
omp	google/gemini-2.5-pro-preview-06-05		1000000	minimal,low,medium,high		google
omp	google/gemini-2.5-pro-preview-tts		8200	minimal,low,medium,high		google
omp	google/gemini-3-flash-preview		1000000	minimal,low,medium,high		google
omp	google/gemini-3-pro-image		131000	low,high		google
omp	google/gemini-3-pro-image-preview		131000	low,high		google
omp	google/gemini-3-pro-preview		1000000	low,high		google
omp	google/gemini-3.1-flash-image		66000	0		google
omp	google/gemini-3.1-flash-image-preview		66000	0		google
omp	google/gemini-3.1-flash-lite		1000000	minimal,low,medium,high		google
omp	google/gemini-3.1-flash-lite-image		66000	0		google
omp	google/gemini-3.1-flash-lite-preview		1000000	minimal,low,medium,high		google
omp	google/gemini-3.1-flash-tts-preview		8200	0		google
omp	google/gemini-3.1-pro-preview		1000000	low,high		google
omp	google/gemini-3.1-pro-preview-customtools		1000000	low,high		google
omp	google/gemini-3.5-flash		1000000	minimal,low,medium,high		google
omp	google/gemini-3.5-flash-lite		1000000	0		google
omp	google/gemini-3.6-flash		1000000	0		google
omp	google/gemini-flash-latest		1000000	minimal,low,medium,high		google
omp	google/gemini-flash-lite-latest		1000000	minimal,low,medium,high		google
omp	google/gemini-live-2.5-flash		128000	minimal,low,medium,high		google
omp	google/gemini-live-2.5-flash-preview-native-audio		131000	minimal,low,medium,high		google
omp	google/gemini-omni-flash-preview		131000	0		google
omp	google/gemini-pro-latest		1000000	minimal,low,medium,high		google
omp	google/gemini-robotics-er-1.5-preview		1000000	0		google
omp	google/gemini-robotics-er-1.6-preview		131000	0		google
omp	google/gemini-robotics-er-2-preview		131000	0		google
omp	google/gemma-3-27b-it		131000	0		google
omp	google/gemma-4-26b		256000	minimal,low,medium,high		google
omp	google/gemma-4-26b-a4b-it		262000	minimal,low,medium,high		google
omp	google/gemma-4-26b-it		256000	minimal,low,medium,high		google
omp	google/gemma-4-31b		256000	minimal,low,medium,high		google
omp	google/gemma-4-31b-it		262000	minimal,low,medium,high		google
omp	google/gemma-4-E2B-it		131000	minimal,low,medium,high		google
omp	google/gemma-4-E4B-it		131000	minimal,low,medium,high		google
omp	google/lyria-3-clip-preview		1000000	0		google
omp	google/lyria-3-pro-preview		1000000	minimal,low,medium,high		google
omp	google/nano-banana-pro-preview		131000	minimal,low,medium,high		google
omp	kimi/k3		1000000	minimal,low,medium,high,xhigh		kimi
omp	kimi/k3-256k		262000	minimal,low,medium,high,xhigh		kimi
omp	kimi/kimi-for-coding		262000	minimal,low,medium,high		kimi
omp	kimi/kimi-for-coding-highspeed		262000	minimal,low,medium,high		kimi
omp	openai/chatgpt-image-latest			0		openai
omp	openai/codex-mini-latest		200000	minimal,low,medium,high,xhigh		openai
omp	openai/gpt-3.5-turbo			0		openai
omp	openai/gpt-3.5-turbo-0125			0		openai
omp	openai/gpt-3.5-turbo-1106			0		openai
omp	openai/gpt-3.5-turbo-16k			0		openai
omp	openai/gpt-3.5-turbo-instruct			0		openai
omp	openai/gpt-3.5-turbo-instruct-0914			0		openai
omp	openai/gpt-4		8200	0		openai
omp	openai/gpt-4-0613			0		openai
omp	openai/gpt-4-turbo		128000	0		openai
omp	openai/gpt-4-turbo-2024-04-09			0		openai
omp	openai/gpt-4.1		1000000	0		openai
omp	openai/gpt-4.1-2025-04-14			0		openai
omp	openai/gpt-4.1-mini		1000000	0		openai
omp	openai/gpt-4.1-mini-2025-04-14			0		openai
omp	openai/gpt-4.1-nano		1000000	0		openai
omp	openai/gpt-4.1-nano-2025-04-14			0		openai
omp	openai/gpt-4o		128000	0		openai
omp	openai/gpt-4o-2024-05-13		128000	0		openai
omp	openai/gpt-4o-2024-08-06		128000	0		openai
omp	openai/gpt-4o-2024-11-20		128000	0		openai
omp	openai/gpt-4o-mini		128000	0		openai
omp	openai/gpt-4o-mini-2024-07-18			0		openai
omp	openai/gpt-4o-mini-search-preview			0		openai
omp	openai/gpt-4o-mini-search-preview-2025-03-11			0		openai
omp	openai/gpt-4o-mini-transcribe			0		openai
omp	openai/gpt-4o-mini-transcribe-2025-03-20			0		openai
omp	openai/gpt-4o-mini-transcribe-2025-12-15			0		openai
omp	openai/gpt-4o-mini-tts			0		openai
omp	openai/gpt-4o-mini-tts-2025-03-20			0		openai
omp	openai/gpt-4o-mini-tts-2025-12-15			0		openai
omp	openai/gpt-4o-search-preview			0		openai
omp	openai/gpt-4o-search-preview-2025-03-11			0		openai
omp	openai/gpt-4o-transcribe			0		openai
omp	openai/gpt-4o-transcribe-diarize			0		openai
omp	openai/gpt-5		400000	minimal,low,medium,high		openai
omp	openai/gpt-5-2025-08-07			0		openai
omp	openai/gpt-5-chat-latest		128000	0		openai
omp	openai/gpt-5-codex		272000	minimal,low,medium,high		openai
omp	openai/gpt-5-mini		400000	minimal,low,medium,high		openai
omp	openai/gpt-5-mini-2025-08-07			0		openai
omp	openai/gpt-5-nano		400000	minimal,low,medium,high		openai
omp	openai/gpt-5-nano-2025-08-07			0		openai
omp	openai/gpt-5-pro		400000	minimal,low,medium,high		openai
omp	openai/gpt-5-pro-2025-10-06			0		openai
omp	openai/gpt-5-search-api			0		openai
omp	openai/gpt-5-search-api-2025-10-14			0		openai
omp	openai/gpt-5.1		400000	minimal,low,medium,high		openai
omp	openai/gpt-5.1-2025-11-13			0		openai
omp	openai/gpt-5.1-chat-latest		128000	minimal,low,medium,high		openai
omp	openai/gpt-5.1-codex		272000	minimal,low,medium,high		openai
omp	openai/gpt-5.1-codex-max		272000	minimal,low,medium,high		openai
omp	openai/gpt-5.1-codex-mini		272000	medium,high		openai
omp	openai/gpt-5.2		400000	low,medium,high,xhigh		openai
omp	openai/gpt-5.2-2025-12-11			0		openai
omp	openai/gpt-5.2-chat-latest		128000	low,medium,high,xhigh		openai
omp	openai/gpt-5.2-codex		272000	low,medium,high,xhigh		openai
omp	openai/gpt-5.2-pro		400000	low,medium,high,xhigh		openai
omp	openai/gpt-5.2-pro-2025-12-11			0		openai
omp	openai/gpt-5.3-chat-latest		128000	0		openai
omp	openai/gpt-5.3-codex		272000	low,medium,high,xhigh		openai
omp	openai/gpt-5.3-codex-spark		128000	low,medium,high,xhigh		openai
omp	openai/gpt-5.4		1000000	low,medium,high,xhigh		openai
omp	openai/gpt-5.4-2026-03-05			0		openai
omp	openai/gpt-5.4-mini		400000	low,medium,high,xhigh		openai
omp	openai/gpt-5.4-mini-2026-03-17			0		openai
omp	openai/gpt-5.4-nano		400000	low,medium,high,xhigh		openai
omp	openai/gpt-5.4-nano-2026-03-17			0		openai
omp	openai/gpt-5.4-pro		1100000	low,medium,high,xhigh		openai
omp	openai/gpt-5.4-pro-2026-03-05			0		openai
omp	openai/gpt-5.5		1100000	low,medium,high,xhigh		openai
omp	openai/gpt-5.5-2026-04-23			0		openai
omp	openai/gpt-5.5-pro		1100000	low,medium,high,xhigh		openai
omp	openai/gpt-5.5-pro-2026-04-23			0		openai
omp	openai/gpt-5.6-luna			0		openai
omp	openai/gpt-5.6-sol			0		openai
omp	openai/gpt-5.6-terra			0		openai
omp	openai/gpt-audio			0		openai
omp	openai/gpt-audio-1.5			0		openai
omp	openai/gpt-audio-2025-08-28			0		openai
omp	openai/gpt-audio-mini			0		openai
omp	openai/gpt-audio-mini-2025-10-06			0		openai
omp	openai/gpt-audio-mini-2025-12-15			0		openai
omp	openai/gpt-live-transcribe			0		openai
omp	openai/gpt-transcribe			0		openai
omp	openai/o1		200000	minimal,low,medium,high,xhigh		openai
omp	openai/o1-2024-12-17			0		openai
omp	openai/o1-pro		200000	minimal,low,medium,high,xhigh		openai
omp	openai/o1-pro-2025-03-19			0		openai
omp	openai/o3		200000	minimal,low,medium,high,xhigh		openai
omp	openai/o3-2025-04-16			0		openai
omp	openai/o3-deep-research		200000	minimal,low,medium,high,xhigh		openai
omp	openai/o3-mini		200000	minimal,low,medium,high,xhigh		openai
omp	openai/o3-mini-2025-01-31			0		openai
omp	openai/o3-pro		200000	minimal,low,medium,high,xhigh		openai
omp	openai/o4-mini		200000	minimal,low,medium,high,xhigh		openai
omp	openai/o4-mini-2025-04-16			0		openai
omp	openai/o4-mini-deep-research		200000	minimal,low,medium,high,xhigh		openai
omp	openrouter/ai21/jamba-large-1.7		256000	0		openrouter
omp	openrouter/aion-labs/aion-2.0		131000	minimal,low,medium,high		openrouter
omp	openrouter/aion-labs/aion-3.0		131000	minimal,low,medium,high		openrouter
omp	openrouter/aion-labs/aion-3.0-mini		131000	minimal,low,medium,high		openrouter
omp	openrouter/alibaba/tongyi-deepresearch-30b-a3b		131000	minimal,low,medium,high		openrouter
omp	openrouter/allenai/olmo-3.1-32b-instruct		66000	0		openrouter
omp	openrouter/amazon/nova-2-lite-v1		1000000	minimal,low,medium,high		openrouter
omp	openrouter/amazon/nova-lite-v1		300000	0		openrouter
omp	openrouter/amazon/nova-micro-v1		128000	0		openrouter
omp	openrouter/amazon/nova-premier-v1		1000000	0		openrouter
omp	openrouter/amazon/nova-pro-v1		300000	0		openrouter
omp	openrouter/anthropic/claude-3-haiku		200000	0		openrouter
omp	openrouter/anthropic/claude-3.5-haiku		200000	0		openrouter
omp	openrouter/anthropic/claude-3.5-sonnet		200000	0		openrouter
omp	openrouter/anthropic/claude-3.7-sonnet		200000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-3.7-sonnet:thinking		200000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-fable-5		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/anthropic/claude-fable-5:batch		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/anthropic/claude-haiku-4.5		200000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-haiku-4.5:batch		200000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-opus-4		200000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-opus-4.1		200000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-opus-4.1:batch		200000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-opus-4.5		200000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-opus-4.5:batch		200000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-opus-4.6		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/anthropic/claude-opus-4.6-fast		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/anthropic/claude-opus-4.6:batch		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/anthropic/claude-opus-4.7		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/anthropic/claude-opus-4.7-fast		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/anthropic/claude-opus-4.7:batch		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/anthropic/claude-opus-4.8		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/anthropic/claude-opus-4.8-fast		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/anthropic/claude-opus-4.8:batch		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/anthropic/claude-opus-5		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/anthropic/claude-opus-5-fast		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/anthropic/claude-opus-5:batch		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/anthropic/claude-sonnet-4		1000000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-sonnet-4.5		1000000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-sonnet-4.5:batch		1000000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-sonnet-4.6		1000000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-sonnet-4.6:batch		1000000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-sonnet-5		1000000	minimal,low,medium,high		openrouter
omp	openrouter/anthropic/claude-sonnet-5:batch		1000000	minimal,low,medium,high		openrouter
omp	openrouter/arcee-ai/trinity-large-preview		131000	0		openrouter
omp	openrouter/arcee-ai/trinity-large-preview:free		131000	0		openrouter
omp	openrouter/arcee-ai/trinity-large-thinking		262000	minimal,low,medium,high		openrouter
omp	openrouter/arcee-ai/trinity-large-thinking:free		262000	minimal,low,medium,high		openrouter
omp	openrouter/arcee-ai/trinity-mini		131000	minimal,low,medium,high		openrouter
omp	openrouter/arcee-ai/trinity-mini:free		131000	minimal,low,medium,high		openrouter
omp	openrouter/arcee-ai/virtuoso-large		131000	0		openrouter
omp	openrouter/auto		2000000	minimal,low,medium,high		openrouter
omp	openrouter/baidu/cobuddy:free		131000	minimal,low,medium,high		openrouter
omp	openrouter/baidu/ernie-4.5-21b-a3b		131000	0		openrouter
omp	openrouter/baidu/ernie-4.5-vl-28b-a3b		131000	minimal,low,medium,high		openrouter
omp	openrouter/bytedance-seed/seed-1.6		262000	minimal,low,medium,high		openrouter
omp	openrouter/bytedance-seed/seed-1.6-flash		262000	minimal,low,medium,high		openrouter
omp	openrouter/bytedance-seed/seed-2.0-lite		262000	minimal,low,medium,high		openrouter
omp	openrouter/bytedance-seed/seed-2.0-mini		262000	minimal,low,medium,high		openrouter
omp	openrouter/cohere/command-r-08-2024		128000	0		openrouter
omp	openrouter/cohere/command-r-plus-08-2024		128000	0		openrouter
omp	openrouter/cohere/north-mini-code:free		256000	minimal,low,medium,high		openrouter
omp	openrouter/deepseek/deepseek-chat		164000	0		openrouter
omp	openrouter/deepseek/deepseek-chat-v3-0324		164000	minimal,low,medium,high		openrouter
omp	openrouter/deepseek/deepseek-chat-v3.1		164000	minimal,low,medium,high		openrouter
omp	openrouter/deepseek/deepseek-r1		164000	minimal,low,medium,high		openrouter
omp	openrouter/deepseek/deepseek-r1-0528		164000	minimal,low,medium,high		openrouter
omp	openrouter/deepseek/deepseek-v3.1-terminus		164000	minimal,low,medium,high		openrouter
omp	openrouter/deepseek/deepseek-v3.1-terminus:exacto		164000	minimal,low,medium,high		openrouter
omp	openrouter/deepseek/deepseek-v3.2		164000	minimal,low,medium,high		openrouter
omp	openrouter/deepseek/deepseek-v3.2-exp		164000	minimal,low,medium,high		openrouter
omp	openrouter/deepseek/deepseek-v4-flash		1000000	minimal,low,medium,high		openrouter
omp	openrouter/deepseek/deepseek-v4-flash-0731		1000000	minimal,low,medium,high		openrouter
omp	openrouter/deepseek/deepseek-v4-flash:free		1000000	minimal,low,medium,high		openrouter
omp	openrouter/deepseek/deepseek-v4-pro		1000000	minimal,low,medium,high		openrouter
omp	openrouter/essentialai/rnj-1-instruct		33000	0		openrouter
omp	openrouter/google/gemini-2.0-flash-001		1000000	0		openrouter
omp	openrouter/google/gemini-2.0-flash-lite-001		1000000	0		openrouter
omp	openrouter/google/gemini-2.5-flash		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-2.5-flash-lite		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-2.5-flash-lite-preview-09-2025		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-2.5-flash-lite:batch		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-2.5-flash-preview-09-2025		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-2.5-flash:batch		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-2.5-pro		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-2.5-pro-preview		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-2.5-pro-preview-05-06		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-2.5-pro:batch		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-3-flash-preview		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-3-flash-preview:batch		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-3-pro-image		131000	low,high		openrouter
omp	openrouter/google/gemini-3-pro-preview		1000000	low,high		openrouter
omp	openrouter/google/gemini-3.1-flash-lite		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-3.1-flash-lite-preview		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-3.1-flash-lite:batch		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-3.1-pro-preview		1000000	low,high		openrouter
omp	openrouter/google/gemini-3.1-pro-preview-customtools		1000000	low,high		openrouter
omp	openrouter/google/gemini-3.1-pro-preview:batch		1000000	low,high		openrouter
omp	openrouter/google/gemini-3.5-flash		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-3.5-flash-lite		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-3.5-flash-lite:batch		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-3.5-flash:batch		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-3.6-flash		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemini-3.6-flash:batch		1000000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemma-3-12b-it		131000	0		openrouter
omp	openrouter/google/gemma-3-27b-it		262000	0		openrouter
omp	openrouter/google/gemma-3-27b-it:free		131000	0		openrouter
omp	openrouter/google/gemma-4-26b-a4b-it		262000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemma-4-26b-a4b-it:free		262000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemma-4-31b-it		262000	minimal,low,medium,high		openrouter
omp	openrouter/google/gemma-4-31b-it:free		262000	minimal,low,medium,high		openrouter
omp	openrouter/ibm-granite/granite-4.1-8b		131000	0		openrouter
omp	openrouter/inception/mercury		128000	0		openrouter
omp	openrouter/inception/mercury-2		128000	minimal,low,medium,high		openrouter
omp	openrouter/inception/mercury-coder		128000	0		openrouter
omp	openrouter/inclusionai/ling-2.6-1t		262000	0		openrouter
omp	openrouter/inclusionai/ling-2.6-1t:free		262000	0		openrouter
omp	openrouter/inclusionai/ling-2.6-flash		262000	0		openrouter
omp	openrouter/inclusionai/ling-2.6-flash:free		262000	0		openrouter
omp	openrouter/inclusionai/ling-3.0-flash		262000	minimal,low,medium,high		openrouter
omp	openrouter/inclusionai/ling-3.0-tiny:free		262000	minimal,low,medium,high		openrouter
omp	openrouter/inclusionai/ring-2.6-1t		262000	minimal,low,medium,high		openrouter
omp	openrouter/inclusionai/ring-2.6-1t:free		262000	minimal,low,medium,high		openrouter
omp	openrouter/kwaipilot/kat-coder-air-v2.5		256000	0		openrouter
omp	openrouter/kwaipilot/kat-coder-pro		256000	0		openrouter
omp	openrouter/kwaipilot/kat-coder-pro-v2		262000	0		openrouter
omp	openrouter/kwaipilot/kat-coder-pro-v2.5		256000	0		openrouter
omp	openrouter/liquid/lfm-2.5-1.2b-thinking:free		33000	minimal,low,medium,high		openrouter
omp	openrouter/meituan/longcat-2.0		1000000	minimal,low,medium,high		openrouter
omp	openrouter/meituan/longcat-flash-chat		131000	0		openrouter
omp	openrouter/meta-llama/llama-3-8b-instruct		8200	0		openrouter
omp	openrouter/meta-llama/llama-3.1-405b-instruct		131000	0		openrouter
omp	openrouter/meta-llama/llama-3.1-70b-instruct		131000	0		openrouter
omp	openrouter/meta-llama/llama-3.1-8b-instruct		131000	0		openrouter
omp	openrouter/meta-llama/llama-3.3-70b-instruct		131000	0		openrouter
omp	openrouter/meta-llama/llama-3.3-70b-instruct:free		131000	0		openrouter
omp	openrouter/meta-llama/llama-4-maverick		1000000	0		openrouter
omp	openrouter/meta-llama/llama-4-scout		1300000	0		openrouter
omp	openrouter/meta/muse-spark-1.1		1000000	minimal,low,medium,high		openrouter
omp	openrouter/meta/muse-spark-1.2		1000000	minimal,low,medium,high		openrouter
omp	openrouter/minimax/minimax-m1		1000000	minimal,low,medium,high		openrouter
omp	openrouter/minimax/minimax-m2		205000	low,medium,high		openrouter
omp	openrouter/minimax/minimax-m2.1		205000	low,medium,high		openrouter
omp	openrouter/minimax/minimax-m2.5		205000	low,medium,high		openrouter
omp	openrouter/minimax/minimax-m2.5:free		205000	low,medium,high		openrouter
omp	openrouter/minimax/minimax-m2.7		205000	low,medium,high		openrouter
omp	openrouter/minimax/minimax-m3		1000000	minimal,low,medium,high		openrouter
omp	openrouter/minimax/minimax-m3:batch		524000	minimal,low,medium,high		openrouter
omp	openrouter/mistralai/codestral-2508		256000	0		openrouter
omp	openrouter/mistralai/devstral-2512		262000	0		openrouter
omp	openrouter/mistralai/devstral-medium		131000	0		openrouter
omp	openrouter/mistralai/devstral-small		131000	0		openrouter
omp	openrouter/mistralai/ministral-14b-2512		262000	0		openrouter
omp	openrouter/mistralai/ministral-3b-2512		131000	0		openrouter
omp	openrouter/mistralai/ministral-8b-2512		262000	0		openrouter
omp	openrouter/mistralai/mistral-large		128000	0		openrouter
omp	openrouter/mistralai/mistral-large-2407		131000	0		openrouter
omp	openrouter/mistralai/mistral-large-2411		131000	0		openrouter
omp	openrouter/mistralai/mistral-large-2512		262000	0		openrouter
omp	openrouter/mistralai/mistral-medium-3		131000	0		openrouter
omp	openrouter/mistralai/mistral-medium-3-5		262000	minimal,low,medium,high		openrouter
omp	openrouter/mistralai/mistral-medium-3.1		131000	0		openrouter
omp	openrouter/mistralai/mistral-nemo		131000	0		openrouter
omp	openrouter/mistralai/mistral-saba		33000	0		openrouter
omp	openrouter/mistralai/mistral-small-24b-instruct-2501		33000	0		openrouter
omp	openrouter/mistralai/mistral-small-2603		262000	minimal,low,medium,high		openrouter
omp	openrouter/mistralai/mistral-small-3.1-24b-instruct		131000	0		openrouter
omp	openrouter/mistralai/mistral-small-3.1-24b-instruct:free		128000	0		openrouter
omp	openrouter/mistralai/mistral-small-3.2-24b-instruct		256000	0		openrouter
omp	openrouter/mistralai/mistral-small-creative		33000	0		openrouter
omp	openrouter/mistralai/mixtral-8x22b-instruct		66000	0		openrouter
omp	openrouter/mistralai/mixtral-8x7b-instruct		33000	0		openrouter
omp	openrouter/mistralai/pixtral-large-2411		131000	0		openrouter
omp	openrouter/mistralai/voxtral-small-24b-2507		32000	0		openrouter
omp	openrouter/moonshotai/kimi-k2		131000	0		openrouter
omp	openrouter/moonshotai/kimi-k2-0905		262000	0		openrouter
omp	openrouter/moonshotai/kimi-k2-0905:exacto		262000	0		openrouter
omp	openrouter/moonshotai/kimi-k2-thinking		262000	minimal,low,medium,high		openrouter
omp	openrouter/moonshotai/kimi-k2.5		262000	minimal,low,medium,high		openrouter
omp	openrouter/moonshotai/kimi-k2.6		262000	minimal,low,medium,high		openrouter
omp	openrouter/moonshotai/kimi-k2.6:free		262000	minimal,low,medium,high		openrouter
omp	openrouter/moonshotai/kimi-k2.7-code		262000	minimal,low,medium,high		openrouter
omp	openrouter/moonshotai/kimi-k2.7-code:batch		262000	minimal,low,medium,high		openrouter
omp	openrouter/moonshotai/kimi-k3		1000000	minimal,low,medium,high		openrouter
omp	openrouter/nex-agi/deepseek-v3.1-nex-n1		131000	0		openrouter
omp	openrouter/nex-agi/nex-n2-mini		262000	minimal,low,medium,high		openrouter
omp	openrouter/nex-agi/nex-n2-pro		262000	minimal,low,medium,high		openrouter
omp	openrouter/nex-agi/nex-n2-pro:free		262000	minimal,low,medium,high		openrouter
omp	openrouter/nousresearch/deephermes-3-mistral-24b-preview		33000	minimal,low,medium,high		openrouter
omp	openrouter/nousresearch/hermes-4-70b		131000	minimal,low,medium,high		openrouter
omp	openrouter/nvidia/llama-3.1-nemotron-70b-instruct		131000	0		openrouter
omp	openrouter/nvidia/llama-3.3-nemotron-super-49b-v1.5		131000	minimal,low,medium,high		openrouter
omp	openrouter/nvidia/nemotron-3-nano-30b-a3b		262000	minimal,low,medium,high		openrouter
omp	openrouter/nvidia/nemotron-3-nano-30b-a3b:free		256000	minimal,low,medium,high		openrouter
omp	openrouter/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free		256000	minimal,low,medium,high		openrouter
omp	openrouter/nvidia/nemotron-3-super-120b-a12b		1000000	minimal,low,medium,high		openrouter
omp	openrouter/nvidia/nemotron-3-super-120b-a12b:free		262000	minimal,low,medium,high		openrouter
omp	openrouter/nvidia/nemotron-3-ultra-550b-a55b		512000	minimal,low,medium,high		openrouter
omp	openrouter/nvidia/nemotron-3-ultra-550b-a55b:batch		512000	minimal,low,medium,high		openrouter
omp	openrouter/nvidia/nemotron-3-ultra-550b-a55b:free		1000000	minimal,low,medium,high		openrouter
omp	openrouter/nvidia/nemotron-nano-12b-v2-vl:free		128000	minimal,low,medium,high		openrouter
omp	openrouter/nvidia/nemotron-nano-9b-v2		131000	minimal,low,medium,high		openrouter
omp	openrouter/nvidia/nemotron-nano-9b-v2:free		128000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-3.5-turbo		16000	0		openrouter
omp	openrouter/openai/gpt-3.5-turbo-0613		4100	0		openrouter
omp	openrouter/openai/gpt-3.5-turbo-16k		16000	0		openrouter
omp	openrouter/openai/gpt-3.5-turbo:batch		16000	0		openrouter
omp	openrouter/openai/gpt-4		8200	0		openrouter
omp	openrouter/openai/gpt-4-0314		8200	0		openrouter
omp	openrouter/openai/gpt-4-1106-preview		128000	0		openrouter
omp	openrouter/openai/gpt-4-turbo		128000	0		openrouter
omp	openrouter/openai/gpt-4-turbo-preview		128000	0		openrouter
omp	openrouter/openai/gpt-4-turbo:batch		128000	0		openrouter
omp	openrouter/openai/gpt-4.1		1000000	0		openrouter
omp	openrouter/openai/gpt-4.1-mini		1000000	0		openrouter
omp	openrouter/openai/gpt-4.1-mini:batch		1000000	0		openrouter
omp	openrouter/openai/gpt-4.1-nano		1000000	0		openrouter
omp	openrouter/openai/gpt-4.1-nano:batch		1000000	0		openrouter
omp	openrouter/openai/gpt-4.1:batch		1000000	0		openrouter
omp	openrouter/openai/gpt-4o		128000	0		openrouter
omp	openrouter/openai/gpt-4o-2024-05-13		128000	0		openrouter
omp	openrouter/openai/gpt-4o-2024-08-06		128000	0		openrouter
omp	openrouter/openai/gpt-4o-2024-11-20		128000	0		openrouter
omp	openrouter/openai/gpt-4o-audio-preview		128000	0		openrouter
omp	openrouter/openai/gpt-4o-mini		128000	0		openrouter
omp	openrouter/openai/gpt-4o-mini-2024-07-18		128000	0		openrouter
omp	openrouter/openai/gpt-4o-mini:batch		128000	0		openrouter
omp	openrouter/openai/gpt-4o:batch		128000	0		openrouter
omp	openrouter/openai/gpt-4o:extended		128000	0		openrouter
omp	openrouter/openai/gpt-5		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5-codex		272000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5-codex:batch		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5-image		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5-image-mini		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5-mini		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5-mini:batch		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5-nano		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5-nano:batch		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5-pro		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5-pro:batch		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5.1		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5.1-chat		128000	0		openrouter
omp	openrouter/openai/gpt-5.1-codex		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5.1-codex-max		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5.1-codex-mini		400000	medium,high		openrouter
omp	openrouter/openai/gpt-5.1:batch		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-5.2		400000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.2-chat		128000	0		openrouter
omp	openrouter/openai/gpt-5.2-codex		400000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.2-pro		400000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.2-pro:batch		400000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.2:batch		400000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.3-chat		128000	0		openrouter
omp	openrouter/openai/gpt-5.3-codex		400000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.4		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.4-mini		400000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.4-mini:batch		400000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.4-nano		400000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.4-nano:batch		400000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.4-pro		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.4-pro:batch		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.4:batch		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.5		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.5-pro		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.5-pro:batch		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.5:batch		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.6-luna		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.6-luna-pro		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.6-luna-pro:batch		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.6-luna:batch		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.6-sol		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.6-sol-pro		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.6-sol-pro:batch		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.6-sol:batch		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.6-terra		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.6-terra-pro		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.6-terra-pro:batch		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5.6-terra:batch		1100000	low,medium,high,xhigh		openrouter
omp	openrouter/openai/gpt-5:batch		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-audio		128000	0		openrouter
omp	openrouter/openai/gpt-audio-mini		128000	0		openrouter
omp	openrouter/openai/gpt-chat-latest		400000	minimal,low,medium,high		openrouter
omp	openrouter/openai/gpt-oss-120b		131000	low,medium,high		openrouter
omp	openrouter/openai/gpt-oss-120b:exacto		131000	low,medium,high		openrouter
omp	openrouter/openai/gpt-oss-120b:free		131000	low,medium,high		openrouter
omp	openrouter/openai/gpt-oss-20b		131000	low,medium,high		openrouter
omp	openrouter/openai/gpt-oss-20b:free		131000	low,medium,high		openrouter
omp	openrouter/openai/gpt-oss-safeguard-20b		131000	low,medium,high		openrouter
omp	openrouter/openai/o1		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o1:batch		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o3		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o3-deep-research		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o3-mini		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o3-mini-high		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o3-mini-high:batch		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o3-mini:batch		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o3-pro		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o3-pro:batch		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o3:batch		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o4-mini		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o4-mini-deep-research		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o4-mini-high		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o4-mini-high:batch		200000	minimal,low,medium,high		openrouter
omp	openrouter/openai/o4-mini:batch		200000	minimal,low,medium,high		openrouter
omp	openrouter/openrouter/aurora-alpha		128000	minimal,low,medium,high		openrouter
omp	openrouter/openrouter/auto		2000000	minimal,low,medium,high		openrouter
omp	openrouter/openrouter/auto-beta		2000000	minimal,low,medium,high		openrouter
omp	openrouter/openrouter/elephant-alpha		262000	0		openrouter
omp	openrouter/openrouter/free		200000	minimal,low,medium,high		openrouter
omp	openrouter/openrouter/healer-alpha		262000	minimal,low,medium,high		openrouter
omp	openrouter/openrouter/hunter-alpha		1000000	minimal,low,medium,high		openrouter
omp	openrouter/openrouter/owl-alpha		1000000	minimal,low,medium,high		openrouter
omp	openrouter/poolside/laguna-m.1		262000	minimal,low,medium,high		openrouter
omp	openrouter/poolside/laguna-m.1:free		262000	minimal,low,medium,high		openrouter
omp	openrouter/poolside/laguna-s-2.1		1000000	minimal,low,medium,high		openrouter
omp	openrouter/poolside/laguna-s-2.1:free		262000	minimal,low,medium,high		openrouter
omp	openrouter/poolside/laguna-xs-2.1		262000	minimal,low,medium,high		openrouter
omp	openrouter/poolside/laguna-xs-2.1:free		262000	minimal,low,medium,high		openrouter
omp	openrouter/poolside/laguna-xs.2		262000	minimal,low,medium,high		openrouter
omp	openrouter/poolside/laguna-xs.2:free		262000	minimal,low,medium,high		openrouter
omp	openrouter/prime-intellect/intellect-3		131000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen-2.5-72b-instruct		33000	0		openrouter
omp	openrouter/qwen/qwen-2.5-7b-instruct		33000	0		openrouter
omp	openrouter/qwen/qwen-max		33000	0		openrouter
omp	openrouter/qwen/qwen-plus		1000000	0		openrouter
omp	openrouter/qwen/qwen-plus-2025-07-28		1000000	0		openrouter
omp	openrouter/qwen/qwen-plus-2025-07-28:thinking		1000000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen-turbo		131000	0		openrouter
omp	openrouter/qwen/qwen-vl-max		131000	0		openrouter
omp	openrouter/qwen/qwen3-14b		131000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3-235b-a22b		131000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3-235b-a22b-2507		262000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3-235b-a22b-thinking-2507		262000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3-30b-a3b		131000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3-30b-a3b-instruct-2507		262000	0		openrouter
omp	openrouter/qwen/qwen3-30b-a3b-thinking-2507		82000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3-32b		131000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3-4b		131000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3-4b:free		41000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3-8b		131000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3-coder		262000	0		openrouter
omp	openrouter/qwen/qwen3-coder-30b-a3b-instruct		262000	0		openrouter
omp	openrouter/qwen/qwen3-coder-flash		1000000	0		openrouter
omp	openrouter/qwen/qwen3-coder-next		262000	0		openrouter
omp	openrouter/qwen/qwen3-coder-plus		1000000	0		openrouter
omp	openrouter/qwen/qwen3-coder:exacto		262000	0		openrouter
omp	openrouter/qwen/qwen3-coder:free		1000000	0		openrouter
omp	openrouter/qwen/qwen3-max		262000	0		openrouter
omp	openrouter/qwen/qwen3-max-thinking		262000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3-next-80b-a3b-instruct		262000	0		openrouter
omp	openrouter/qwen/qwen3-next-80b-a3b-instruct:free		262000	0		openrouter
omp	openrouter/qwen/qwen3-next-80b-a3b-thinking		262000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3-vl-235b-a22b-instruct		262000	0		openrouter
omp	openrouter/qwen/qwen3-vl-235b-a22b-thinking		131000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3-vl-30b-a3b-instruct		262000	0		openrouter
omp	openrouter/qwen/qwen3-vl-30b-a3b-thinking		262000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3-vl-32b-instruct		131000	0		openrouter
omp	openrouter/qwen/qwen3-vl-8b-instruct		262000	0		openrouter
omp	openrouter/qwen/qwen3-vl-8b-thinking		131000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.5-122b-a10b		262000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.5-27b		262000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.5-35b-a3b		262000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.5-397b-a17b		262000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.5-9b		262000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.5-flash-02-23		1000000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.5-plus-02-15		1000000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.5-plus-20260420		1000000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.6-27b		262000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.6-35b-a3b		262000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.6-flash		1000000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.6-max-preview		262000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.6-plus		1000000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.6-plus-preview:free		1000000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.6-plus:free		1000000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.7-flash		1000000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.7-max		1000000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.7-plus		1000000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwen3.8-max		1000000	minimal,low,medium,high		openrouter
omp	openrouter/qwen/qwq-32b		131000	minimal,low,medium,high		openrouter
omp	openrouter/reka/reka-edge		16000	0		openrouter
omp	openrouter/rekaai/reka-edge		16000	0		openrouter
omp	openrouter/relace/relace-search		256000	0		openrouter
omp	openrouter/sakana/fugu-ultra		1000000	minimal,low,medium,high		openrouter
omp	openrouter/sao10k/l3-euryale-70b		8200	0		openrouter
omp	openrouter/sao10k/l3.1-euryale-70b		131000	0		openrouter
omp	openrouter/stepfun/step-3.5-flash		262000	minimal,low,medium,high		openrouter
omp	openrouter/stepfun/step-3.5-flash:free		256000	minimal,low,medium,high		openrouter
omp	openrouter/stepfun/step-3.7-flash		262000	minimal,low,medium,high		openrouter
omp	openrouter/tencent/hy3		262000	minimal,low,medium,high		openrouter
omp	openrouter/tencent/hy3-preview		262000	minimal,low,medium,high		openrouter
omp	openrouter/tencent/hy3-preview:free		262000	minimal,low,medium,high		openrouter
omp	openrouter/thedrummer/rocinante-12b		33000	0		openrouter
omp	openrouter/thedrummer/unslopnemo-12b		1000000	0		openrouter
omp	openrouter/thinkingmachines/inkling		1000000	minimal,low,medium,high		openrouter
omp	openrouter/thinkingmachines/inkling-small		524000	minimal,low,medium,high		openrouter
omp	openrouter/thinkingmachines/inkling:batch		524000	minimal,low,medium,high		openrouter
omp	openrouter/tngtech/deepseek-r1t2-chimera		164000	minimal,low,medium,high		openrouter
omp	openrouter/tngtech/tng-r1t-chimera		164000	minimal,low,medium,high		openrouter
omp	openrouter/upstage/solar-pro-3		131000	minimal,low,medium,high		openrouter
omp	openrouter/upstage/solar-pro-3:free		128000	minimal,low,medium,high		openrouter
omp	openrouter/x-ai/grok-3		131000	0		openrouter
omp	openrouter/x-ai/grok-3-beta		131000	0		openrouter
omp	openrouter/x-ai/grok-3-mini		131000	minimal,low,medium,high		openrouter
omp	openrouter/x-ai/grok-3-mini-beta		131000	minimal,low,medium,high		openrouter
omp	openrouter/x-ai/grok-4		256000	minimal,low,medium,high		openrouter
omp	openrouter/x-ai/grok-4-fast		2000000	minimal,low,medium,high		openrouter
omp	openrouter/x-ai/grok-4.1-fast		2000000	minimal,low,medium,high		openrouter
omp	openrouter/x-ai/grok-4.20		2000000	minimal,low,medium,high		openrouter
omp	openrouter/x-ai/grok-4.20-beta		2000000	minimal,low,medium,high		openrouter
omp	openrouter/x-ai/grok-4.3		1000000	minimal,low,medium,high		openrouter
omp	openrouter/x-ai/grok-4.5		500000	minimal,low,medium,high		openrouter
omp	openrouter/x-ai/grok-build-0.1		256000	minimal,low,medium,high		openrouter
omp	openrouter/x-ai/grok-code-fast-1		256000	minimal,low,medium,high		openrouter
omp	openrouter/xiaomi/mimo-v2-flash		262000	low,medium,high		openrouter
omp	openrouter/xiaomi/mimo-v2-omni		262000	low,medium,high		openrouter
omp	openrouter/xiaomi/mimo-v2-pro		1000000	low,medium,high		openrouter
omp	openrouter/xiaomi/mimo-v2.5		1100000	low,medium,high		openrouter
omp	openrouter/xiaomi/mimo-v2.5-pro		1100000	low,medium,high		openrouter
omp	openrouter/z-ai/glm-4-32b		128000	0		openrouter
omp	openrouter/z-ai/glm-4.5		131000	minimal,low,medium,high		openrouter
omp	openrouter/z-ai/glm-4.5-air		131000	minimal,low,medium,high		openrouter
omp	openrouter/z-ai/glm-4.5-air:free		131000	minimal,low,medium,high		openrouter
omp	openrouter/z-ai/glm-4.5v		66000	minimal,low,medium,high		openrouter
omp	openrouter/z-ai/glm-4.6		205000	minimal,low,medium,high		openrouter
omp	openrouter/z-ai/glm-4.6:exacto		205000	minimal,low,medium,high		openrouter
omp	openrouter/z-ai/glm-4.6v		131000	minimal,low,medium,high		openrouter
omp	openrouter/z-ai/glm-4.7		205000	minimal,low,medium,high		openrouter
omp	openrouter/z-ai/glm-4.7-flash		203000	minimal,low,medium,high		openrouter
omp	openrouter/z-ai/glm-5		205000	minimal,low,medium,high		openrouter
omp	openrouter/z-ai/glm-5-turbo		203000	minimal,low,medium,high		openrouter
omp	openrouter/z-ai/glm-5.1		205000	minimal,low,medium,high		openrouter
omp	openrouter/z-ai/glm-5.2		1000000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/z-ai/glm-5.2:batch		512000	minimal,low,medium,high,xhigh		openrouter
omp	openrouter/z-ai/glm-5v-turbo		203000	minimal,low,medium,high		openrouter
omp	openrouter/~anthropic/claude-fable-latest		1000000	minimal,low,medium,high		openrouter
omp	openrouter/~anthropic/claude-haiku-latest		200000	minimal,low,medium,high		openrouter
omp	openrouter/~anthropic/claude-opus-latest		1000000	minimal,low,medium,high		openrouter
omp	openrouter/~anthropic/claude-sonnet-latest		1000000	minimal,low,medium,high		openrouter
omp	openrouter/~deepseek/deepseek-v4-flash-latest		1000000	minimal,low,medium,high		openrouter
omp	openrouter/~google/gemini-flash-latest		1000000	minimal,low,medium,high		openrouter
omp	openrouter/~google/gemini-pro-latest		1000000	minimal,low,medium,high		openrouter
omp	openrouter/~moonshotai/kimi-latest		1000000	minimal,low,medium,high		openrouter
omp	openrouter/~openai/gpt-latest		1100000	minimal,low,medium,high		openrouter
omp	openrouter/~openai/gpt-mini-latest		400000	minimal,low,medium,high		openrouter
omp	openrouter/~x-ai/grok-latest		500000	minimal,low,medium,high		openrouter
opencode	google/deep-research-max-preview-04-2026			-
opencode	google/deep-research-preview-04-2026			-
opencode	google/gemini-2.5-computer-use-preview-10-2025			-
opencode	google/gemini-2.5-flash			-
opencode	google/gemini-2.5-flash-image			-
opencode	google/gemini-2.5-flash-lite			-
opencode	google/gemini-2.5-flash-preview-tts			-
opencode	google/gemini-2.5-pro			-
opencode	google/gemini-2.5-pro-preview-tts			-
opencode	google/gemini-3-flash-preview			-
opencode	google/gemini-3-pro-image			-
opencode	google/gemini-3-pro-image-preview			-
opencode	google/gemini-3.1-flash-image			-
opencode	google/gemini-3.1-flash-image-preview			-
opencode	google/gemini-3.1-flash-lite			-
opencode	google/gemini-3.1-flash-lite-image			-
opencode	google/gemini-3.1-flash-live-preview			-
opencode	google/gemini-3.1-flash-tts-preview			-
opencode	google/gemini-3.1-pro-preview			-
opencode	google/gemini-3.1-pro-preview-customtools			-
opencode	google/gemini-3.5-flash			-
opencode	google/gemini-3.5-flash-lite			-
opencode	google/gemini-3.5-live-translate-preview			-
opencode	google/gemini-3.6-flash			-
opencode	google/gemini-embedding-001			-
opencode	google/gemini-embedding-2			-
opencode	google/gemini-flash-latest			-
opencode	google/gemini-flash-lite-latest			-
opencode	google/gemini-omni-flash-preview			-
opencode	google/gemini-robotics-er-1.6-preview			-
opencode	google/gemma-4-26b-a4b-it			-
opencode	google/gemma-4-31b-it			-
opencode	google/lyria-3-clip-preview			-
opencode	google/lyria-3-pro-preview			-
opencode	google/veo-3.1-fast-generate-preview			-
opencode	google/veo-3.1-generate-preview			-
opencode	google/veo-3.1-lite-generate-preview			-
opencode	kimi/k3			-
opencode	kimi/k3-256k			-
opencode	kimi/kimi-for-coding			-
opencode	kimi/kimi-for-coding-highspeed			-
opencode	openai/chatgpt-image-latest			-
opencode	openai/gpt-4.1			-
opencode	openai/gpt-4.1-mini			-
opencode	openai/gpt-4o			-
opencode	openai/gpt-4o-2024-08-06			-
opencode	openai/gpt-4o-2024-11-20			-
opencode	openai/gpt-4o-mini			-
opencode	openai/gpt-5			-
opencode	openai/gpt-5-mini			-
opencode	openai/gpt-5-nano			-
opencode	openai/gpt-5-pro			-
opencode	openai/gpt-5.1			-
opencode	openai/gpt-5.2			-
opencode	openai/gpt-5.2-chat-latest			-
opencode	openai/gpt-5.2-pro			-
opencode	openai/gpt-5.3-chat-latest			-
opencode	openai/gpt-5.3-codex			-
opencode	openai/gpt-5.3-codex-spark			-
opencode	openai/gpt-5.4			-
opencode	openai/gpt-5.4-fast			-
opencode	openai/gpt-5.4-mini			-
opencode	openai/gpt-5.4-mini-fast			-
opencode	openai/gpt-5.4-nano			-
opencode	openai/gpt-5.4-pro			-
opencode	openai/gpt-5.5			-
opencode	openai/gpt-5.5-fast			-
opencode	openai/gpt-5.5-pro			-
opencode	openai/gpt-5.6			-
opencode	openai/gpt-5.6-fast			-
opencode	openai/gpt-5.6-luna			-
opencode	openai/gpt-5.6-luna-fast			-
opencode	openai/gpt-5.6-luna-pro			-
opencode	openai/gpt-5.6-pro			-
opencode	openai/gpt-5.6-sol			-
opencode	openai/gpt-5.6-sol-fast			-
opencode	openai/gpt-5.6-sol-pro			-
opencode	openai/gpt-5.6-terra			-
opencode	openai/gpt-5.6-terra-fast			-
opencode	openai/gpt-5.6-terra-pro			-
opencode	openai/gpt-image-1-mini			-
opencode	openai/gpt-image-1.5			-
opencode	openai/gpt-image-2			-
opencode	openai/gpt-realtime-2.1			-
opencode	openai/o3			-
opencode	openai/o3-pro			-
opencode	openai/text-embedding-3-large			-
opencode	openai/text-embedding-3-small			-
opencode	openai/text-embedding-ada-002			-
opencode	opencode/big-pickle			-
opencode	opencode/deepseek-v4-flash-free			-
opencode	opencode/laguna-s-2.1-free			-
opencode	opencode/ling-3.0-tiny-free			-
opencode	opencode/longcat-2.0-free			-
opencode	opencode/mimo-v2.5-free			-
opencode	opencode/nemotron-3-ultra-free			-
opencode	opencode/north-mini-code-free			-
opencode	openrouter/ai21/jamba-large-1.7			-
opencode	openrouter/aion-labs/aion-2.0			-
opencode	openrouter/aion-labs/aion-3.0			-
opencode	openrouter/aion-labs/aion-3.0-mini			-
opencode	openrouter/aion-labs/aion-rp-llama-3.1-8b			-
opencode	openrouter/allenai/olmo-3-32b-think			-
opencode	openrouter/amazon/nova-2-lite-v1			-
opencode	openrouter/amazon/nova-lite-v1			-
opencode	openrouter/amazon/nova-micro-v1			-
opencode	openrouter/amazon/nova-premier-v1			-
opencode	openrouter/amazon/nova-pro-v1			-
opencode	openrouter/anthracite-org/magnum-v4-72b			-
opencode	openrouter/anthropic/claude-3-haiku			-
opencode	openrouter/anthropic/claude-fable-5			-
opencode	openrouter/anthropic/claude-haiku-4.5			-
opencode	openrouter/anthropic/claude-opus-4			-
opencode	openrouter/anthropic/claude-opus-4.1			-
opencode	openrouter/anthropic/claude-opus-4.5			-
opencode	openrouter/anthropic/claude-opus-4.6			-
opencode	openrouter/anthropic/claude-opus-4.7			-
opencode	openrouter/anthropic/claude-opus-4.7-fast			-
opencode	openrouter/anthropic/claude-opus-4.8			-
opencode	openrouter/anthropic/claude-opus-4.8-fast			-
opencode	openrouter/anthropic/claude-opus-5			-
opencode	openrouter/anthropic/claude-opus-5-fast			-
opencode	openrouter/anthropic/claude-sonnet-4			-
opencode	openrouter/anthropic/claude-sonnet-4.5			-
opencode	openrouter/anthropic/claude-sonnet-4.6			-
opencode	openrouter/anthropic/claude-sonnet-5			-
opencode	openrouter/arcee-ai/trinity-large-thinking			-
opencode	openrouter/arcee-ai/virtuoso-large			-
opencode	openrouter/baidu/ernie-4.5-vl-424b-a47b			-
opencode	openrouter/bytedance-seed/seed-1.6			-
opencode	openrouter/bytedance-seed/seed-1.6-flash			-
opencode	openrouter/bytedance-seed/seed-2.0-lite			-
opencode	openrouter/bytedance-seed/seed-2.0-mini			-
opencode	openrouter/bytedance/ui-tars-1.5-7b			-
opencode	openrouter/cognitivecomputations/dolphin-mistral-24b-venice-edition			-
opencode	openrouter/cohere/command-a			-
opencode	openrouter/cohere/command-r-08-2024			-
opencode	openrouter/cohere/command-r-plus-08-2024			-
opencode	openrouter/cohere/command-r7b-12-2024			-
opencode	openrouter/cohere/north-mini-code:free			-
opencode	openrouter/deepcogito/cogito-v2.1-671b			-
opencode	openrouter/deepseek/deepseek-chat			-
opencode	openrouter/deepseek/deepseek-chat-v3-0324			-
opencode	openrouter/deepseek/deepseek-chat-v3.1			-
opencode	openrouter/deepseek/deepseek-r1			-
opencode	openrouter/deepseek/deepseek-r1-0528			-
opencode	openrouter/deepseek/deepseek-r1-distill-llama-70b			-
opencode	openrouter/deepseek/deepseek-v3.1-terminus			-
opencode	openrouter/deepseek/deepseek-v3.2			-
opencode	openrouter/deepseek/deepseek-v3.2-exp			-
opencode	openrouter/deepseek/deepseek-v4-flash			-
opencode	openrouter/deepseek/deepseek-v4-flash-0731			-
opencode	openrouter/deepseek/deepseek-v4-pro			-
opencode	openrouter/google/gemini-2.5-flash			-
opencode	openrouter/google/gemini-2.5-flash-image			-
opencode	openrouter/google/gemini-2.5-flash-lite			-
opencode	openrouter/google/gemini-2.5-pro			-
opencode	openrouter/google/gemini-2.5-pro-preview			-
opencode	openrouter/google/gemini-2.5-pro-preview-05-06			-
opencode	openrouter/google/gemini-3-flash-preview			-
opencode	openrouter/google/gemini-3-pro-image			-
opencode	openrouter/google/gemini-3-pro-image-preview			-
opencode	openrouter/google/gemini-3.1-flash-image			-
opencode	openrouter/google/gemini-3.1-flash-image-preview			-
opencode	openrouter/google/gemini-3.1-flash-lite			-
opencode	openrouter/google/gemini-3.1-flash-lite-image			-
opencode	openrouter/google/gemini-3.1-flash-lite-preview			-
opencode	openrouter/google/gemini-3.1-pro-preview			-
opencode	openrouter/google/gemini-3.1-pro-preview-customtools			-
opencode	openrouter/google/gemini-3.5-flash			-
opencode	openrouter/google/gemini-3.5-flash-lite			-
opencode	openrouter/google/gemini-3.6-flash			-
opencode	openrouter/google/gemma-2-27b-it			-
opencode	openrouter/google/gemma-3-12b-it			-
opencode	openrouter/google/gemma-3-27b-it			-
opencode	openrouter/google/gemma-3-4b-it			-
opencode	openrouter/google/gemma-3n-e4b-it			-
opencode	openrouter/google/gemma-4-26b-a4b-it			-
opencode	openrouter/google/gemma-4-26b-a4b-it:free			-
opencode	openrouter/google/gemma-4-31b-it			-
opencode	openrouter/google/gemma-4-31b-it:free			-
opencode	openrouter/google/lyria-3-clip-preview			-
opencode	openrouter/google/lyria-3-pro-preview			-
opencode	openrouter/gryphe/mythomax-l2-13b			-
opencode	openrouter/ibm-granite/granite-4.0-h-micro			-
opencode	openrouter/ibm-granite/granite-4.1-8b			-
opencode	openrouter/inception/mercury-2			-
opencode	openrouter/inclusionai/ling-2.6-1t			-
opencode	openrouter/inclusionai/ling-2.6-flash			-
opencode	openrouter/inclusionai/ling-3.0-flash			-
opencode	openrouter/inclusionai/ling-3.0-tiny:free			-
opencode	openrouter/inclusionai/ring-2.6-1t			-
opencode	openrouter/kwaipilot/kat-coder-air-v2.5			-
opencode	openrouter/kwaipilot/kat-coder-pro-v2			-
opencode	openrouter/kwaipilot/kat-coder-pro-v2.5			-
opencode	openrouter/mancer/weaver			-
opencode	openrouter/meituan/longcat-2.0			-
opencode	openrouter/meta-llama/llama-3.1-70b-instruct			-
opencode	openrouter/meta-llama/llama-3.1-8b-instruct			-
opencode	openrouter/meta-llama/llama-3.2-1b-instruct			-
opencode	openrouter/meta-llama/llama-3.2-3b-instruct			-
opencode	openrouter/meta-llama/llama-3.3-70b-instruct			-
opencode	openrouter/meta-llama/llama-4-maverick			-
opencode	openrouter/meta-llama/llama-4-scout			-
opencode	openrouter/meta-llama/llama-guard-4-12b			-
opencode	openrouter/meta/muse-spark-1.1			-
opencode	openrouter/meta/muse-spark-1.2			-
opencode	openrouter/microsoft/phi-4			-
opencode	openrouter/microsoft/wizardlm-2-8x22b			-
opencode	openrouter/minimax/minimax-01			-
opencode	openrouter/minimax/minimax-m1			-
opencode	openrouter/minimax/minimax-m2			-
opencode	openrouter/minimax/minimax-m2-her			-
opencode	openrouter/minimax/minimax-m2.1			-
opencode	openrouter/minimax/minimax-m2.5			-
opencode	openrouter/minimax/minimax-m2.7			-
opencode	openrouter/minimax/minimax-m3			-
opencode	openrouter/mistralai/codestral-2508			-
opencode	openrouter/mistralai/ministral-14b-2512			-
opencode	openrouter/mistralai/ministral-3b-2512			-
opencode	openrouter/mistralai/ministral-8b-2512			-
opencode	openrouter/mistralai/mistral-large			-
opencode	openrouter/mistralai/mistral-large-2407			-
opencode	openrouter/mistralai/mistral-large-2512			-
opencode	openrouter/mistralai/mistral-medium-3			-
opencode	openrouter/mistralai/mistral-medium-3-5			-
opencode	openrouter/mistralai/mistral-medium-3.1			-
opencode	openrouter/mistralai/mistral-nemo			-
opencode	openrouter/mistralai/mistral-saba			-
opencode	openrouter/mistralai/mistral-small-24b-instruct-2501			-
opencode	openrouter/mistralai/mistral-small-2603			-
opencode	openrouter/mistralai/mistral-small-3.1-24b-instruct			-
opencode	openrouter/mistralai/mistral-small-3.2-24b-instruct			-
opencode	openrouter/mistralai/mixtral-8x22b-instruct			-
opencode	openrouter/mistralai/voxtral-small-24b-2507			-
opencode	openrouter/moonshotai/kimi-k2			-
opencode	openrouter/moonshotai/kimi-k2-0905			-
opencode	openrouter/moonshotai/kimi-k2-thinking			-
opencode	openrouter/moonshotai/kimi-k2.5			-
opencode	openrouter/moonshotai/kimi-k2.6			-
opencode	openrouter/moonshotai/kimi-k2.7-code			-
opencode	openrouter/moonshotai/kimi-k3			-
opencode	openrouter/morph/morph-v3-fast			-
opencode	openrouter/morph/morph-v3-large			-
opencode	openrouter/nex-agi/nex-n2-mini			-
opencode	openrouter/nex-agi/nex-n2-pro			-
opencode	openrouter/nousresearch/hermes-3-llama-3.1-405b			-
opencode	openrouter/nousresearch/hermes-3-llama-3.1-70b			-
opencode	openrouter/nousresearch/hermes-4-405b			-
opencode	openrouter/nousresearch/hermes-4-70b			-
opencode	openrouter/nvidia/nemotron-3-nano-30b-a3b			-
opencode	openrouter/nvidia/nemotron-3-nano-30b-a3b:free			-
opencode	openrouter/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free			-
opencode	openrouter/nvidia/nemotron-3-super-120b-a12b			-
opencode	openrouter/nvidia/nemotron-3-super-120b-a12b:free			-
opencode	openrouter/nvidia/nemotron-3-ultra-550b-a55b			-
opencode	openrouter/nvidia/nemotron-3-ultra-550b-a55b:free			-
opencode	openrouter/nvidia/nemotron-3.5-content-safety:free			-
opencode	openrouter/nvidia/nemotron-nano-12b-v2-vl:free			-
opencode	openrouter/nvidia/nemotron-nano-9b-v2:free			-
opencode	openrouter/openai/gpt-3.5-turbo			-
opencode	openrouter/openai/gpt-3.5-turbo-0613			-
opencode	openrouter/openai/gpt-3.5-turbo-16k			-
opencode	openrouter/openai/gpt-3.5-turbo-instruct			-
opencode	openrouter/openai/gpt-4			-
opencode	openrouter/openai/gpt-4-turbo			-
opencode	openrouter/openai/gpt-4-turbo-preview			-
opencode	openrouter/openai/gpt-4.1			-
opencode	openrouter/openai/gpt-4.1-mini			-
opencode	openrouter/openai/gpt-4.1-nano			-
opencode	openrouter/openai/gpt-4o			-
opencode	openrouter/openai/gpt-4o-2024-05-13			-
opencode	openrouter/openai/gpt-4o-2024-08-06			-
opencode	openrouter/openai/gpt-4o-2024-11-20			-
opencode	openrouter/openai/gpt-4o-mini			-
opencode	openrouter/openai/gpt-4o-mini-2024-07-18			-
opencode	openrouter/openai/gpt-5			-
opencode	openrouter/openai/gpt-5-image			-
opencode	openrouter/openai/gpt-5-image-mini			-
opencode	openrouter/openai/gpt-5-mini			-
opencode	openrouter/openai/gpt-5-nano			-
opencode	openrouter/openai/gpt-5-pro			-
opencode	openrouter/openai/gpt-5.1			-
opencode	openrouter/openai/gpt-5.1-codex			-
opencode	openrouter/openai/gpt-5.1-codex-max			-
opencode	openrouter/openai/gpt-5.1-codex-mini			-
opencode	openrouter/openai/gpt-5.2			-
opencode	openrouter/openai/gpt-5.2-chat			-
opencode	openrouter/openai/gpt-5.2-codex			-
opencode	openrouter/openai/gpt-5.2-pro			-
opencode	openrouter/openai/gpt-5.3-chat			-
opencode	openrouter/openai/gpt-5.3-codex			-
opencode	openrouter/openai/gpt-5.4			-
opencode	openrouter/openai/gpt-5.4-image-2			-
opencode	openrouter/openai/gpt-5.4-mini			-
opencode	openrouter/openai/gpt-5.4-nano			-
opencode	openrouter/openai/gpt-5.4-pro			-
opencode	openrouter/openai/gpt-5.5			-
opencode	openrouter/openai/gpt-5.5-pro			-
opencode	openrouter/openai/gpt-5.6-luna			-
opencode	openrouter/openai/gpt-5.6-luna-pro			-
opencode	openrouter/openai/gpt-5.6-sol			-
opencode	openrouter/openai/gpt-5.6-sol-pro			-
opencode	openrouter/openai/gpt-5.6-terra			-
opencode	openrouter/openai/gpt-5.6-terra-pro			-
opencode	openrouter/openai/gpt-audio			-
opencode	openrouter/openai/gpt-audio-mini			-
opencode	openrouter/openai/gpt-chat-latest			-
opencode	openrouter/openai/gpt-oss-120b			-
opencode	openrouter/openai/gpt-oss-20b			-
opencode	openrouter/openai/gpt-oss-20b:free			-
opencode	openrouter/openai/gpt-oss-safeguard-20b			-
opencode	openrouter/openai/o1			-
opencode	openrouter/openai/o1-pro			-
opencode	openrouter/openai/o3			-
opencode	openrouter/openai/o3-mini			-
opencode	openrouter/openai/o3-mini-high			-
opencode	openrouter/openai/o3-pro			-
opencode	openrouter/openai/o4-mini			-
opencode	openrouter/openai/o4-mini-high			-
opencode	openrouter/openrouter/auto			-
opencode	openrouter/openrouter/bodybuilder			-
opencode	openrouter/openrouter/free			-
opencode	openrouter/openrouter/fusion			-
opencode	openrouter/openrouter/pareto-code			-
opencode	openrouter/perceptron/perceptron-mk1			-
opencode	openrouter/perplexity/sonar			-
opencode	openrouter/perplexity/sonar-deep-research			-
opencode	openrouter/perplexity/sonar-pro			-
opencode	openrouter/perplexity/sonar-pro-search			-
opencode	openrouter/perplexity/sonar-reasoning-pro			-
opencode	openrouter/poolside/laguna-s-2.1			-
opencode	openrouter/poolside/laguna-s-2.1:free			-
opencode	openrouter/poolside/laguna-xs-2.1			-
opencode	openrouter/poolside/laguna-xs-2.1:free			-
opencode	openrouter/qwen/qwen-2.5-72b-instruct			-
opencode	openrouter/qwen/qwen-2.5-7b-instruct			-
opencode	openrouter/qwen/qwen-2.5-coder-32b-instruct			-
opencode	openrouter/qwen/qwen-plus			-
opencode	openrouter/qwen/qwen-plus-2025-07-28			-
opencode	openrouter/qwen/qwen-plus-2025-07-28:thinking			-
opencode	openrouter/qwen/qwen2.5-vl-72b-instruct			-
opencode	openrouter/qwen/qwen3-14b			-
opencode	openrouter/qwen/qwen3-235b-a22b			-
opencode	openrouter/qwen/qwen3-235b-a22b-2507			-
opencode	openrouter/qwen/qwen3-235b-a22b-thinking-2507			-
opencode	openrouter/qwen/qwen3-30b-a3b			-
opencode	openrouter/qwen/qwen3-30b-a3b-instruct-2507			-
opencode	openrouter/qwen/qwen3-30b-a3b-thinking-2507			-
opencode	openrouter/qwen/qwen3-32b			-
opencode	openrouter/qwen/qwen3-8b			-
opencode	openrouter/qwen/qwen3-coder			-
opencode	openrouter/qwen/qwen3-coder-30b-a3b-instruct			-
opencode	openrouter/qwen/qwen3-coder-flash			-
opencode	openrouter/qwen/qwen3-coder-next			-
opencode	openrouter/qwen/qwen3-coder-plus			-
opencode	openrouter/qwen/qwen3-max			-
opencode	openrouter/qwen/qwen3-max-thinking			-
opencode	openrouter/qwen/qwen3-next-80b-a3b-instruct			-
opencode	openrouter/qwen/qwen3-next-80b-a3b-thinking			-
opencode	openrouter/qwen/qwen3-vl-235b-a22b-instruct			-
opencode	openrouter/qwen/qwen3-vl-235b-a22b-thinking			-
opencode	openrouter/qwen/qwen3-vl-30b-a3b-instruct			-
opencode	openrouter/qwen/qwen3-vl-30b-a3b-thinking			-
opencode	openrouter/qwen/qwen3-vl-32b-instruct			-
opencode	openrouter/qwen/qwen3-vl-8b-instruct			-
opencode	openrouter/qwen/qwen3-vl-8b-thinking			-
opencode	openrouter/qwen/qwen3.5-122b-a10b			-
opencode	openrouter/qwen/qwen3.5-27b			-
opencode	openrouter/qwen/qwen3.5-35b-a3b			-
opencode	openrouter/qwen/qwen3.5-397b-a17b			-
opencode	openrouter/qwen/qwen3.5-9b			-
opencode	openrouter/qwen/qwen3.5-flash-02-23			-
opencode	openrouter/qwen/qwen3.5-plus-02-15			-
opencode	openrouter/qwen/qwen3.5-plus-20260420			-
opencode	openrouter/qwen/qwen3.6-27b			-
opencode	openrouter/qwen/qwen3.6-35b-a3b			-
opencode	openrouter/qwen/qwen3.6-flash			-
opencode	openrouter/qwen/qwen3.6-max-preview			-
opencode	openrouter/qwen/qwen3.6-plus			-
opencode	openrouter/qwen/qwen3.7-flash			-
opencode	openrouter/qwen/qwen3.7-max			-
opencode	openrouter/qwen/qwen3.7-plus			-
opencode	openrouter/qwen/qwen3.8-max			-
opencode	openrouter/rekaai/reka-edge			-
opencode	openrouter/rekaai/reka-flash-3			-
opencode	openrouter/relace/relace-apply-3			-
opencode	openrouter/relace/relace-search			-
opencode	openrouter/sakana/fugu-ultra			-
opencode	openrouter/sao10k/l3-lunaris-8b			-
opencode	openrouter/sao10k/l3.1-euryale-70b			-
opencode	openrouter/sao10k/l3.3-euryale-70b			-
opencode	openrouter/stepfun/step-3.5-flash			-
opencode	openrouter/stepfun/step-3.7-flash			-
opencode	openrouter/tencent/hunyuan-a13b-instruct			-
opencode	openrouter/tencent/hy3			-
opencode	openrouter/tencent/hy3-preview			-
opencode	openrouter/thedrummer/cydonia-24b-v4.1			-
opencode	openrouter/thedrummer/rocinante-12b			-
opencode	openrouter/thedrummer/skyfall-36b-v2			-
opencode	openrouter/thedrummer/unslopnemo-12b			-
opencode	openrouter/thinkingmachines/inkling			-
opencode	openrouter/thinkingmachines/inkling-small			-
opencode	openrouter/undi95/remm-slerp-l2-13b			-
opencode	openrouter/upstage/solar-pro-3			-
opencode	openrouter/writer/palmyra-x5			-
opencode	openrouter/x-ai/grok-4.20			-
opencode	openrouter/x-ai/grok-4.20-multi-agent			-
opencode	openrouter/x-ai/grok-4.3			-
opencode	openrouter/x-ai/grok-4.5			-
opencode	openrouter/x-ai/grok-build-0.1			-
opencode	openrouter/xiaomi/mimo-v2.5			-
opencode	openrouter/xiaomi/mimo-v2.5-pro			-
opencode	openrouter/z-ai/glm-4.5			-
opencode	openrouter/z-ai/glm-4.5-air			-
opencode	openrouter/z-ai/glm-4.5v			-
opencode	openrouter/z-ai/glm-4.6			-
opencode	openrouter/z-ai/glm-4.6v			-
opencode	openrouter/z-ai/glm-4.7			-
opencode	openrouter/z-ai/glm-4.7-flash			-
opencode	openrouter/z-ai/glm-5			-
opencode	openrouter/z-ai/glm-5-turbo			-
opencode	openrouter/z-ai/glm-5.1			-
opencode	openrouter/z-ai/glm-5.2			-
opencode	openrouter/z-ai/glm-5v-turbo			-
opencode	openrouter/~anthropic/claude-fable-latest			-
opencode	openrouter/~anthropic/claude-haiku-latest			-
opencode	openrouter/~anthropic/claude-opus-latest			-
opencode	openrouter/~anthropic/claude-sonnet-latest			-
opencode	openrouter/~deepseek/deepseek-v4-flash-latest			-
opencode	openrouter/~google/gemini-flash-latest			-
opencode	openrouter/~google/gemini-pro-latest			-
opencode	openrouter/~moonshotai/kimi-latest			-
opencode	openrouter/~openai/gpt-latest			-
opencode	openrouter/~openai/gpt-mini-latest			-
opencode	openrouter/~x-ai/grok-latest			-
pi	google/deep-research-max-preview-04-2026		131100	-		google
pi	google/deep-research-preview-04-2026		131100	-		google
pi	google/gemini-2.0-flash		1000000	-		google
pi	google/gemini-2.0-flash-lite		1000000	-		google
pi	google/gemini-2.5-computer-use-preview-10-2025		131100	-		google
pi	google/gemini-2.5-flash		1000000	-		google
pi	google/gemini-2.5-flash-lite		1000000	-		google
pi	google/gemini-2.5-pro		1000000	-		google
pi	google/gemini-3-flash-preview		1000000	-		google
pi	google/gemini-3-pro-preview		1000000	-		google
pi	google/gemini-3.1-flash-lite		1000000	-		google
pi	google/gemini-3.1-flash-lite-image		65500	-		google
pi	google/gemini-3.1-flash-lite-preview		1000000	-		google
pi	google/gemini-3.1-flash-live-preview		131100	-		google
pi	google/gemini-3.1-pro-preview		1000000	-		google
pi	google/gemini-3.1-pro-preview-customtools		1000000	-		google
pi	google/gemini-3.5-flash		1000000	-		google
pi	google/gemini-3.5-flash-lite		1000000	-		google
pi	google/gemini-3.6-flash		1000000	-		google
pi	google/gemini-flash-latest		1000000	-		google
pi	google/gemini-flash-lite-latest		1000000	-		google
pi	google/gemini-robotics-er-1.6-preview		131100	-		google
pi	google/gemma-4-26b-a4b-it		262100	-		google
pi	google/gemma-4-31b-it		262100	-		google
pi	kimi/k3		1000000	-		kimi
pi	kimi/k3-256k		262100	-		kimi
pi	kimi/kimi-for-coding		262100	-		kimi
pi	kimi/kimi-for-coding-highspeed		262100	-		kimi
pi	openai/gpt-4		8200	-		openai
pi	openai/gpt-4-turbo		128000	-		openai
pi	openai/gpt-4.1		1000000	-		openai
pi	openai/gpt-4.1-mini		1000000	-		openai
pi	openai/gpt-4.1-nano		1000000	-		openai
pi	openai/gpt-4o		128000	-		openai
pi	openai/gpt-4o-2024-05-13		128000	-		openai
pi	openai/gpt-4o-2024-08-06		128000	-		openai
pi	openai/gpt-4o-2024-11-20		128000	-		openai
pi	openai/gpt-4o-mini		128000	-		openai
pi	openai/gpt-5		400000	-		openai
pi	openai/gpt-5-chat-latest		128000	-		openai
pi	openai/gpt-5-codex		400000	-		openai
pi	openai/gpt-5-mini		400000	-		openai
pi	openai/gpt-5-nano		400000	-		openai
pi	openai/gpt-5-pro		400000	-		openai
pi	openai/gpt-5.1		400000	-		openai
pi	openai/gpt-5.1-chat-latest		128000	-		openai
pi	openai/gpt-5.1-codex		400000	-		openai
pi	openai/gpt-5.1-codex-max		400000	-		openai
pi	openai/gpt-5.1-codex-mini		400000	-		openai
pi	openai/gpt-5.2		400000	-		openai
pi	openai/gpt-5.2-chat-latest		128000	-		openai
pi	openai/gpt-5.2-codex		400000	-		openai
pi	openai/gpt-5.2-pro		400000	-		openai
pi	openai/gpt-5.3-chat-latest		128000	-		openai
pi	openai/gpt-5.3-codex		400000	-		openai
pi	openai/gpt-5.3-codex-spark		128000	-		openai
pi	openai/gpt-5.4		272000	-		openai
pi	openai/gpt-5.4-mini		400000	-		openai
pi	openai/gpt-5.4-nano		400000	-		openai
pi	openai/gpt-5.4-pro		1100000	-		openai
pi	openai/gpt-5.5		272000	-		openai
pi	openai/gpt-5.5-pro		1100000	-		openai
pi	openai/gpt-5.6-luna		272000	-		openai
pi	openai/gpt-5.6-sol		272000	-		openai
pi	openai/gpt-5.6-terra		272000	-		openai
pi	openai/gpt-realtime-2.1		128000	-		openai
pi	openai/o1		200000	-		openai
pi	openai/o1-pro		200000	-		openai
pi	openai/o3		200000	-		openai
pi	openai/o3-deep-research		200000	-		openai
pi	openai/o3-mini		200000	-		openai
pi	openai/o3-pro		200000	-		openai
pi	openai/o4-mini		200000	-		openai
pi	openai/o4-mini-deep-research		200000	-		openai
pi	openrouter/ai21/jamba-large-1.7		256000	-		openrouter
pi	openrouter/aion-labs/aion-2.0		131100	-		openrouter
pi	openrouter/aion-labs/aion-3.0		131100	-		openrouter
pi	openrouter/aion-labs/aion-3.0-mini		131100	-		openrouter
pi	openrouter/amazon/nova-2-lite-v1		1000000	-		openrouter
pi	openrouter/amazon/nova-lite-v1		300000	-		openrouter
pi	openrouter/amazon/nova-micro-v1		128000	-		openrouter
pi	openrouter/amazon/nova-premier-v1		1000000	-		openrouter
pi	openrouter/amazon/nova-pro-v1		300000	-		openrouter
pi	openrouter/anthropic/claude-3-haiku		200000	-		openrouter
pi	openrouter/anthropic/claude-fable-5		1000000	-		openrouter
pi	openrouter/anthropic/claude-fable-5:batch		1000000	-		openrouter
pi	openrouter/anthropic/claude-haiku-4.5		200000	-		openrouter
pi	openrouter/anthropic/claude-haiku-4.5:batch		200000	-		openrouter
pi	openrouter/anthropic/claude-opus-4		200000	-		openrouter
pi	openrouter/anthropic/claude-opus-4.1		200000	-		openrouter
pi	openrouter/anthropic/claude-opus-4.1:batch		200000	-		openrouter
pi	openrouter/anthropic/claude-opus-4.5		200000	-		openrouter
pi	openrouter/anthropic/claude-opus-4.5:batch		200000	-		openrouter
pi	openrouter/anthropic/claude-opus-4.6		1000000	-		openrouter
pi	openrouter/anthropic/claude-opus-4.6:batch		1000000	-		openrouter
pi	openrouter/anthropic/claude-opus-4.7		1000000	-		openrouter
pi	openrouter/anthropic/claude-opus-4.7-fast		1000000	-		openrouter
pi	openrouter/anthropic/claude-opus-4.7:batch		1000000	-		openrouter
pi	openrouter/anthropic/claude-opus-4.8		1000000	-		openrouter
pi	openrouter/anthropic/claude-opus-4.8-fast		1000000	-		openrouter
pi	openrouter/anthropic/claude-opus-4.8:batch		1000000	-		openrouter
pi	openrouter/anthropic/claude-opus-5		1000000	-		openrouter
pi	openrouter/anthropic/claude-opus-5-fast		1000000	-		openrouter
pi	openrouter/anthropic/claude-sonnet-4		200000	-		openrouter
pi	openrouter/anthropic/claude-sonnet-4.5		1000000	-		openrouter
pi	openrouter/anthropic/claude-sonnet-4.5:batch		1000000	-		openrouter
pi	openrouter/anthropic/claude-sonnet-4.6		1000000	-		openrouter
pi	openrouter/anthropic/claude-sonnet-5		1000000	-		openrouter
pi	openrouter/anthropic/claude-sonnet-5:batch		1000000	-		openrouter
pi	openrouter/arcee-ai/trinity-large-thinking		262100	-		openrouter
pi	openrouter/arcee-ai/virtuoso-large		131100	-		openrouter
pi	openrouter/auto		2000000	-		openrouter
pi	openrouter/bytedance-seed/seed-1.6		262100	-		openrouter
pi	openrouter/bytedance-seed/seed-1.6-flash		262100	-		openrouter
pi	openrouter/bytedance-seed/seed-2.0-lite		262100	-		openrouter
pi	openrouter/bytedance-seed/seed-2.0-mini		262100	-		openrouter
pi	openrouter/cohere/command-r-08-2024		128000	-		openrouter
pi	openrouter/cohere/command-r-plus-08-2024		128000	-		openrouter
pi	openrouter/cohere/north-mini-code:free		256000	-		openrouter
pi	openrouter/deepseek/deepseek-chat		128000	-		openrouter
pi	openrouter/deepseek/deepseek-chat-v3-0324		163800	-		openrouter
pi	openrouter/deepseek/deepseek-chat-v3.1		163800	-		openrouter
pi	openrouter/deepseek/deepseek-r1		64000	-		openrouter
pi	openrouter/deepseek/deepseek-r1-0528		163800	-		openrouter
pi	openrouter/deepseek/deepseek-v3.1-terminus		131100	-		openrouter
pi	openrouter/deepseek/deepseek-v3.2		163800	-		openrouter
pi	openrouter/deepseek/deepseek-v3.2-exp		163800	-		openrouter
pi	openrouter/deepseek/deepseek-v4-flash		1000000	-		openrouter
pi	openrouter/deepseek/deepseek-v4-flash-0731		1000000	-		openrouter
pi	openrouter/deepseek/deepseek-v4-pro		1000000	-		openrouter
pi	openrouter/google/gemini-2.5-flash		1000000	-		openrouter
pi	openrouter/google/gemini-2.5-flash-lite		1000000	-		openrouter
pi	openrouter/google/gemini-2.5-flash-lite:batch		1000000	-		openrouter
pi	openrouter/google/gemini-2.5-flash:batch		1000000	-		openrouter
pi	openrouter/google/gemini-2.5-pro		1000000	-		openrouter
pi	openrouter/google/gemini-2.5-pro-preview		1000000	-		openrouter
pi	openrouter/google/gemini-2.5-pro-preview-05-06		1000000	-		openrouter
pi	openrouter/google/gemini-2.5-pro:batch		1000000	-		openrouter
pi	openrouter/google/gemini-3-flash-preview		1000000	-		openrouter
pi	openrouter/google/gemini-3-flash-preview:batch		1000000	-		openrouter
pi	openrouter/google/gemini-3-pro-image		65500	-		openrouter
pi	openrouter/google/gemini-3.1-flash-lite		1000000	-		openrouter
pi	openrouter/google/gemini-3.1-flash-lite-preview		1000000	-		openrouter
pi	openrouter/google/gemini-3.1-flash-lite:batch		1000000	-		openrouter
pi	openrouter/google/gemini-3.1-pro-preview		1000000	-		openrouter
pi	openrouter/google/gemini-3.1-pro-preview-customtools		1000000	-		openrouter
pi	openrouter/google/gemini-3.1-pro-preview:batch		1000000	-		openrouter
pi	openrouter/google/gemini-3.5-flash		1000000	-		openrouter
pi	openrouter/google/gemini-3.5-flash-lite		1000000	-		openrouter
pi	openrouter/google/gemini-3.5-flash-lite:batch		1000000	-		openrouter
pi	openrouter/google/gemini-3.5-flash:batch		1000000	-		openrouter
pi	openrouter/google/gemini-3.6-flash		1000000	-		openrouter
pi	openrouter/google/gemini-3.6-flash:batch		1000000	-		openrouter
pi	openrouter/google/gemma-3-12b-it		131100	-		openrouter
pi	openrouter/google/gemma-3-27b-it		131100	-		openrouter
pi	openrouter/google/gemma-4-26b-a4b-it		262100	-		openrouter
pi	openrouter/google/gemma-4-26b-a4b-it:free		131100	-		openrouter
pi	openrouter/google/gemma-4-31b-it		262100	-		openrouter
pi	openrouter/google/gemma-4-31b-it:free		262100	-		openrouter
pi	openrouter/ibm-granite/granite-4.1-8b		131100	-		openrouter
pi	openrouter/inception/mercury-2		128000	-		openrouter
pi	openrouter/inclusionai/ling-2.6-1t		262100	-		openrouter
pi	openrouter/inclusionai/ling-2.6-flash		262100	-		openrouter
pi	openrouter/inclusionai/ling-3.0-flash:free		262100	-		openrouter
pi	openrouter/inclusionai/ring-2.6-1t		262100	-		openrouter
pi	openrouter/kwaipilot/kat-coder-air-v2.5		256000	-		openrouter
pi	openrouter/kwaipilot/kat-coder-pro-v2		256000	-		openrouter
pi	openrouter/kwaipilot/kat-coder-pro-v2.5		256000	-		openrouter
pi	openrouter/meituan/longcat-2.0		1000000	-		openrouter
pi	openrouter/meta-llama/llama-3.1-70b-instruct		131100	-		openrouter
pi	openrouter/meta-llama/llama-3.1-8b-instruct		131100	-		openrouter
pi	openrouter/meta-llama/llama-3.3-70b-instruct		131100	-		openrouter
pi	openrouter/meta-llama/llama-4-maverick		1000000	-		openrouter
pi	openrouter/meta-llama/llama-4-scout		327700	-		openrouter
pi	openrouter/meta/muse-spark-1.1		1000000	-		openrouter
pi	openrouter/minimax/minimax-m1		1000000	-		openrouter
pi	openrouter/minimax/minimax-m2		204800	-		openrouter
pi	openrouter/minimax/minimax-m2.1		204800	-		openrouter
pi	openrouter/minimax/minimax-m2.5		196600	-		openrouter
pi	openrouter/minimax/minimax-m2.7		196600	-		openrouter
pi	openrouter/minimax/minimax-m3		524300	-		openrouter
pi	openrouter/minimax/minimax-m3:batch		524300	-		openrouter
pi	openrouter/mistralai/codestral-2508		256000	-		openrouter
pi	openrouter/mistralai/devstral-2512		262100	-		openrouter
pi	openrouter/mistralai/ministral-14b-2512		262100	-		openrouter
pi	openrouter/mistralai/ministral-3b-2512		131100	-		openrouter
pi	openrouter/mistralai/ministral-8b-2512		262100	-		openrouter
pi	openrouter/mistralai/mistral-large		128000	-		openrouter
pi	openrouter/mistralai/mistral-large-2407		131100	-		openrouter
pi	openrouter/mistralai/mistral-large-2512		262100	-		openrouter
pi	openrouter/mistralai/mistral-medium-3		131100	-		openrouter
pi	openrouter/mistralai/mistral-medium-3-5		262100	-		openrouter
pi	openrouter/mistralai/mistral-medium-3.1		131100	-		openrouter
pi	openrouter/mistralai/mistral-nemo		131100	-		openrouter
pi	openrouter/mistralai/mistral-saba		32800	-		openrouter
pi	openrouter/mistralai/mistral-small-2603		262100	-		openrouter
pi	openrouter/mistralai/mistral-small-3.2-24b-instruct		128000	-		openrouter
pi	openrouter/mistralai/mixtral-8x22b-instruct		65500	-		openrouter
pi	openrouter/mistralai/voxtral-small-24b-2507		32000	-		openrouter
pi	openrouter/moonshotai/kimi-k2		131100	-		openrouter
pi	openrouter/moonshotai/kimi-k2-0905		262100	-		openrouter
pi	openrouter/moonshotai/kimi-k2-thinking		262100	-		openrouter
pi	openrouter/moonshotai/kimi-k2.5		262100	-		openrouter
pi	openrouter/moonshotai/kimi-k2.6		262100	-		openrouter
pi	openrouter/moonshotai/kimi-k2.7-code		262100	-		openrouter
pi	openrouter/moonshotai/kimi-k3		1000000	-		openrouter
pi	openrouter/nex-agi/nex-n2-mini		262100	-		openrouter
pi	openrouter/nex-agi/nex-n2-pro		262100	-		openrouter
pi	openrouter/nvidia/nemotron-3-nano-30b-a3b		262100	-		openrouter
pi	openrouter/nvidia/nemotron-3-nano-30b-a3b:free		256000	-		openrouter
pi	openrouter/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free		256000	-		openrouter
pi	openrouter/nvidia/nemotron-3-super-120b-a12b		262100	-		openrouter
pi	openrouter/nvidia/nemotron-3-super-120b-a12b:free		262100	-		openrouter
pi	openrouter/nvidia/nemotron-3-ultra-550b-a55b		512300	-		openrouter
pi	openrouter/nvidia/nemotron-3-ultra-550b-a55b:free		1000000	-		openrouter
pi	openrouter/nvidia/nemotron-nano-12b-v2-vl:free		128000	-		openrouter
pi	openrouter/nvidia/nemotron-nano-9b-v2:free		128000	-		openrouter
pi	openrouter/openai/gpt-3.5-turbo		16400	-		openrouter
pi	openrouter/openai/gpt-3.5-turbo-0613		4100	-		openrouter
pi	openrouter/openai/gpt-3.5-turbo-16k		16400	-		openrouter
pi	openrouter/openai/gpt-4		8200	-		openrouter
pi	openrouter/openai/gpt-4-turbo		128000	-		openrouter
pi	openrouter/openai/gpt-4-turbo-preview		128000	-		openrouter
pi	openrouter/openai/gpt-4.1		1000000	-		openrouter
pi	openrouter/openai/gpt-4.1-mini		1000000	-		openrouter
pi	openrouter/openai/gpt-4.1-nano		1000000	-		openrouter
pi	openrouter/openai/gpt-4o		128000	-		openrouter
pi	openrouter/openai/gpt-4o-2024-05-13		128000	-		openrouter
pi	openrouter/openai/gpt-4o-2024-08-06		128000	-		openrouter
pi	openrouter/openai/gpt-4o-2024-11-20		128000	-		openrouter
pi	openrouter/openai/gpt-4o-mini		128000	-		openrouter
pi	openrouter/openai/gpt-4o-mini-2024-07-18		128000	-		openrouter
pi	openrouter/openai/gpt-5		400000	-		openrouter
pi	openrouter/openai/gpt-5-codex		400000	-		openrouter
pi	openrouter/openai/gpt-5-mini		400000	-		openrouter
pi	openrouter/openai/gpt-5-mini:batch		400000	-		openrouter
pi	openrouter/openai/gpt-5-nano		400000	-		openrouter
pi	openrouter/openai/gpt-5-nano:batch		400000	-		openrouter
pi	openrouter/openai/gpt-5-pro		400000	-		openrouter
pi	openrouter/openai/gpt-5.1		400000	-		openrouter
pi	openrouter/openai/gpt-5.1-chat		128000	-		openrouter
pi	openrouter/openai/gpt-5.1-codex		400000	-		openrouter
pi	openrouter/openai/gpt-5.1-codex-max		400000	-		openrouter
pi	openrouter/openai/gpt-5.1-codex-mini		400000	-		openrouter
pi	openrouter/openai/gpt-5.1:batch		400000	-		openrouter
pi	openrouter/openai/gpt-5.2		400000	-		openrouter
pi	openrouter/openai/gpt-5.2-chat		128000	-		openrouter
pi	openrouter/openai/gpt-5.2-codex		400000	-		openrouter
pi	openrouter/openai/gpt-5.2-pro		400000	-		openrouter
pi	openrouter/openai/gpt-5.2:batch		400000	-		openrouter
pi	openrouter/openai/gpt-5.3-chat		128000	-		openrouter
pi	openrouter/openai/gpt-5.3-codex		400000	-		openrouter
pi	openrouter/openai/gpt-5.4		1100000	-		openrouter
pi	openrouter/openai/gpt-5.4-mini		400000	-		openrouter
pi	openrouter/openai/gpt-5.4-mini:batch		400000	-		openrouter
pi	openrouter/openai/gpt-5.4-nano		400000	-		openrouter
pi	openrouter/openai/gpt-5.4-nano:batch		400000	-		openrouter
pi	openrouter/openai/gpt-5.4-pro		1100000	-		openrouter
pi	openrouter/openai/gpt-5.4:batch		1100000	-		openrouter
pi	openrouter/openai/gpt-5.5		1100000	-		openrouter
pi	openrouter/openai/gpt-5.5-pro		1100000	-		openrouter
pi	openrouter/openai/gpt-5.5:batch		1100000	-		openrouter
pi	openrouter/openai/gpt-5.6-luna		1100000	-		openrouter
pi	openrouter/openai/gpt-5.6-luna-pro		1100000	-		openrouter
pi	openrouter/openai/gpt-5.6-sol		1100000	-		openrouter
pi	openrouter/openai/gpt-5.6-sol-pro		1100000	-		openrouter
pi	openrouter/openai/gpt-5.6-terra		1100000	-		openrouter
pi	openrouter/openai/gpt-5.6-terra-pro		1100000	-		openrouter
pi	openrouter/openai/gpt-5:batch		400000	-		openrouter
pi	openrouter/openai/gpt-audio		128000	-		openrouter
pi	openrouter/openai/gpt-audio-mini		128000	-		openrouter
pi	openrouter/openai/gpt-chat-latest		400000	-		openrouter
pi	openrouter/openai/gpt-oss-120b		131100	-		openrouter
pi	openrouter/openai/gpt-oss-20b		131100	-		openrouter
pi	openrouter/openai/gpt-oss-20b:free		131100	-		openrouter
pi	openrouter/openai/gpt-oss-safeguard-20b		131100	-		openrouter
pi	openrouter/openai/o1		200000	-		openrouter
pi	openrouter/openai/o3		200000	-		openrouter
pi	openrouter/openai/o3-deep-research		200000	-		openrouter
pi	openrouter/openai/o3-mini		200000	-		openrouter
pi	openrouter/openai/o3-mini-high		200000	-		openrouter
pi	openrouter/openai/o3-pro		200000	-		openrouter
pi	openrouter/openai/o4-mini		200000	-		openrouter
pi	openrouter/openai/o4-mini-deep-research		200000	-		openrouter
pi	openrouter/openai/o4-mini-high		200000	-		openrouter
pi	openrouter/openrouter/auto		2000000	-		openrouter
pi	openrouter/openrouter/auto-beta		2000000	-		openrouter
pi	openrouter/openrouter/free		200000	-		openrouter
pi	openrouter/openrouter/fusion		1000000	-		openrouter
pi	openrouter/poolside/laguna-m.1		262100	-		openrouter
pi	openrouter/poolside/laguna-m.1:free		262100	-		openrouter
pi	openrouter/poolside/laguna-s-2.1		1000000	-		openrouter
pi	openrouter/poolside/laguna-s-2.1:free		262100	-		openrouter
pi	openrouter/poolside/laguna-xs-2.1		262100	-		openrouter
pi	openrouter/poolside/laguna-xs-2.1:free		262100	-		openrouter
pi	openrouter/qwen/qwen-2.5-72b-instruct		32800	-		openrouter
pi	openrouter/qwen/qwen-2.5-7b-instruct		32800	-		openrouter
pi	openrouter/qwen/qwen-plus		1000000	-		openrouter
pi	openrouter/qwen/qwen-plus-2025-07-28		1000000	-		openrouter
pi	openrouter/qwen/qwen-plus-2025-07-28:thinking		1000000	-		openrouter
pi	openrouter/qwen/qwen3-14b		131100	-		openrouter
pi	openrouter/qwen/qwen3-235b-a22b		131100	-		openrouter
pi	openrouter/qwen/qwen3-235b-a22b-2507		262100	-		openrouter
pi	openrouter/qwen/qwen3-235b-a22b-thinking-2507		131100	-		openrouter
pi	openrouter/qwen/qwen3-30b-a3b		41000	-		openrouter
pi	openrouter/qwen/qwen3-30b-a3b-instruct-2507		128000	-		openrouter
pi	openrouter/qwen/qwen3-30b-a3b-thinking-2507		81900	-		openrouter
pi	openrouter/qwen/qwen3-32b		41000	-		openrouter
pi	openrouter/qwen/qwen3-8b		131100	-		openrouter
pi	openrouter/qwen/qwen3-coder		262100	-		openrouter
pi	openrouter/qwen/qwen3-coder-30b-a3b-instruct		160000	-		openrouter
pi	openrouter/qwen/qwen3-coder-flash		1000000	-		openrouter
pi	openrouter/qwen/qwen3-coder-next		262100	-		openrouter
pi	openrouter/qwen/qwen3-coder-plus		1000000	-		openrouter
pi	openrouter/qwen/qwen3-max		262100	-		openrouter
pi	openrouter/qwen/qwen3-max-thinking		262100	-		openrouter
pi	openrouter/qwen/qwen3-next-80b-a3b-instruct		262100	-		openrouter
pi	openrouter/qwen/qwen3-next-80b-a3b-thinking		131100	-		openrouter
pi	openrouter/qwen/qwen3-vl-235b-a22b-instruct		131100	-		openrouter
pi	openrouter/qwen/qwen3-vl-235b-a22b-thinking		131100	-		openrouter
pi	openrouter/qwen/qwen3-vl-30b-a3b-instruct		131100	-		openrouter
pi	openrouter/qwen/qwen3-vl-30b-a3b-thinking		131100	-		openrouter
pi	openrouter/qwen/qwen3-vl-32b-instruct		131100	-		openrouter
pi	openrouter/qwen/qwen3-vl-8b-instruct		131100	-		openrouter
pi	openrouter/qwen/qwen3-vl-8b-thinking		131100	-		openrouter
pi	openrouter/qwen/qwen3.5-122b-a10b		262100	-		openrouter
pi	openrouter/qwen/qwen3.5-27b		262100	-		openrouter
pi	openrouter/qwen/qwen3.5-35b-a3b		262100	-		openrouter
pi	openrouter/qwen/qwen3.5-397b-a17b		262100	-		openrouter
pi	openrouter/qwen/qwen3.5-9b		262100	-		openrouter
pi	openrouter/qwen/qwen3.5-flash-02-23		1000000	-		openrouter
pi	openrouter/qwen/qwen3.5-plus-02-15		1000000	-		openrouter
pi	openrouter/qwen/qwen3.5-plus-20260420		1000000	-		openrouter
pi	openrouter/qwen/qwen3.6-27b		262100	-		openrouter
pi	openrouter/qwen/qwen3.6-35b-a3b		262100	-		openrouter
pi	openrouter/qwen/qwen3.6-flash		1000000	-		openrouter
pi	openrouter/qwen/qwen3.6-max-preview		262100	-		openrouter
pi	openrouter/qwen/qwen3.6-plus		1000000	-		openrouter
pi	openrouter/qwen/qwen3.7-flash		1000000	-		openrouter
pi	openrouter/qwen/qwen3.7-max		1000000	-		openrouter
pi	openrouter/qwen/qwen3.7-plus		1000000	-		openrouter
pi	openrouter/rekaai/reka-edge		16400	-		openrouter
pi	openrouter/relace/relace-search		256000	-		openrouter
pi	openrouter/sakana/fugu-ultra		1000000	-		openrouter
pi	openrouter/sao10k/l3.1-euryale-70b		131100	-		openrouter
pi	openrouter/stepfun/step-3.5-flash		262100	-		openrouter
pi	openrouter/stepfun/step-3.7-flash		256000	-		openrouter
pi	openrouter/tencent/hy3		262100	-		openrouter
pi	openrouter/tencent/hy3-preview		262100	-		openrouter
pi	openrouter/thedrummer/unslopnemo-12b		32800	-		openrouter
pi	openrouter/thinkingmachines/inkling		524300	-		openrouter
pi	openrouter/upstage/solar-pro-3		128000	-		openrouter
pi	openrouter/x-ai/grok-4.20		2000000	-		openrouter
pi	openrouter/x-ai/grok-4.3		1000000	-		openrouter
pi	openrouter/x-ai/grok-4.5		500000	-		openrouter
pi	openrouter/x-ai/grok-build-0.1		256000	-		openrouter
pi	openrouter/xiaomi/mimo-v2.5		1000000	-		openrouter
pi	openrouter/xiaomi/mimo-v2.5-pro		1000000	-		openrouter
pi	openrouter/z-ai/glm-4.5		131100	-		openrouter
pi	openrouter/z-ai/glm-4.5-air		131100	-		openrouter
pi	openrouter/z-ai/glm-4.5v		65500	-		openrouter
pi	openrouter/z-ai/glm-4.6		202800	-		openrouter
pi	openrouter/z-ai/glm-4.6v		131100	-		openrouter
pi	openrouter/z-ai/glm-4.7		202800	-		openrouter
pi	openrouter/z-ai/glm-4.7-flash		202800	-		openrouter
pi	openrouter/z-ai/glm-5		204800	-		openrouter
pi	openrouter/z-ai/glm-5-turbo		202800	-		openrouter
pi	openrouter/z-ai/glm-5.1		200000	-		openrouter
pi	openrouter/z-ai/glm-5.2		1000000	-		openrouter
pi	openrouter/z-ai/glm-5v-turbo		202800	-		openrouter
pi	openrouter/~anthropic/claude-fable-latest		1000000	-		openrouter
pi	openrouter/~anthropic/claude-haiku-latest		200000	-		openrouter
pi	openrouter/~anthropic/claude-opus-latest		1000000	-		openrouter
pi	openrouter/~anthropic/claude-sonnet-latest		1000000	-		openrouter
pi	openrouter/~google/gemini-flash-latest		1000000	-		openrouter
pi	openrouter/~google/gemini-pro-latest		1000000	-		openrouter
pi	openrouter/~moonshotai/kimi-latest		1000000	-		openrouter
pi	openrouter/~openai/gpt-latest		1100000	-		openrouter
pi	openrouter/~openai/gpt-mini-latest		400000	-		openrouter
pi	openrouter/~x-ai/grok-latest		500000	-		openrouter
"""#
}
