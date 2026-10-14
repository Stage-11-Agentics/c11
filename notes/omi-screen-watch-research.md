# Omi (BasedHardware) — Deep Research Brief

**Date:** 2026-06-07
**Audience:** Technical founder evaluating the continuous screen/audio-memory space
**Method:** Multi-agent deep-research workflow (102 agents, 19 sources fetched, 93 claims extracted, adversarial verification) + direct primary-source verification of claims the workflow's verify phase couldn't complete due to API rate limits. Confidence labels reflect the final merged state.

---

## TL;DR

Omi is a real, shipping, MIT-licensed "second brain": the macOS desktop app genuinely watches your screen (ScreenCaptureKit), listens, transcribes live, and emits summaries/action items, with a webhook app platform and an official MCP server on top. But it is **cloud-coupled by design** — Deepgram, OpenAI, Firebase/GCP, Pinecone are documented as required services — and a genuinely private self-host is nontrivial-to-impossible at the edges (Firebase has no local substitute; even self-hosted Deepgram phones a license server every minute). For a *local-first* continuous screen-memory substrate, **screenpipe is the stronger architectural fit**; Omi's distinct value is the integrated wearable + mobile + app-store ecosystem and its agent-facing memory API.

---

## 1. Product surface & screen-watching capability

**Confidence: high (verified 3-0 by workflow).**

- Desktop app captures **screen + conversations**, transcribes in real time, generates summaries and action items. This is shipped code, not roadmap: the macOS app has a `ScreenCaptureService` built on **ScreenCaptureKit**, a frame pipeline, `FocusAssistant`, `ProactiveAssistantsPlugin`, a transcription state machine, an Action Items UI, and a backend `GoalGenerationService`.
- Privacy policy confirms the capture path in the data model: "Screen and System Recordings" and "screen snapshots for conversation context" are collected and stored.
- macOS 14+ only for desktop. Mobile (Flutter, iOS/Android) and the wearable (nRF/Zephyr necklace; Omi Glass on ESP32-S3) are audio-first.
- Maturity: ~12.7k stars, 668 releases, very active. Marketing claims 300k+ users (unverified).
- Naming collision warning: the App Store "Screen Recorder by Omi" is an **unrelated** product.

## 2. Architecture & cloud-dependence

**Confidence: high (verified 3-0).**

- **Desktop:** Swift/SwiftUI frontend + Rust app-local backend. Separately, a **Backend-Rust API server** (Firestore/Redis/auth/LLM glue) exists alongside the main Python/FastAPI backend.
- **Mobile:** Flutter. **Web:** TypeScript/Next.js. **Backend:** Python/FastAPI on Firebase/GCP.
- **Pipeline:** live audio → Deepgram STT → VAD/diarization (GPU infra) → OpenAI for text processing → Firestore storage, Pinecone embeddings, Typesense search, Redis/Upstash caching.
- The docs' Required Services list: **OpenAI, Deepgram, Pinecone, Hugging Face, Redis/Upstash, Firebase — all mandatory** for the documented setup (verified 2-1; the dissent: some are swappable via OpenAI-compatible endpoints and alternate STT, but that's the advanced path, not the default).

## 3. Self-host story

**Confidence: high (verified 3-0 / 2-0).**

- The documented self-host path **mandates Google Cloud + Firebase**: enable Cloud Resource Manager + Firebase Management APIs, `gcloud auth application-default login` to generate `google-credentials.json`. The minimum env-var set has **no local-only default**.
- **Firebase has no local alternative** in the docs. (A claim that there's *no way* to substitute your own Firebase project was refuted 0-2 — you can bring your own project — but you cannot remove Firebase.)
- Deepgram can be swapped for alternate STT or self-hosted Deepgram, but **even self-hosted Deepgram maintains an ongoing connection to `license.deepgram.com`** — every minute, over HTTPS — to validate components and report usage. No audio/transcripts leave, but it is never airgapped. (Verified 2-0 against Deepgram's own docs.)
- Net: "self-hosted Omi" means "Omi on your own cloud accounts," not "Omi on your own metal." Budget real integration work to make it private; full air-gap is not achievable on the documented stack.
- Quick start for the desktop app alone: `git clone … && cd omi/desktop && ./run.sh --yolo` (macOS 14+, Xcode, Node; full dev needs Rust).

## 4. Privacy & data model

**Confidence: high (directly verified against Omi's privacy policy, 2026-06-07).**

- **Raw audio is not retained**: "Raw audio recordings are not stored or retained after processing is complete." One exception: an optional personal speech sample for voice ID, deletable.
- **Screen snapshots ARE stored** as conversation context (encrypted, AES-256 at rest / TLS in transit, on GCP).
- Named processors: Deepgram (live audio stream), OpenAI (text only — "no raw audio"), Google Cloud/Firebase (transcripts, summaries, metadata, uploads), plus Stripe/PayPal, Typesense, Pinecone, Instabug.
- Retention: "as long as necessary"; user-initiated deletion and full account deletion documented.
- No major public controversy surfaced in this pass, but the workflow's privacy-controversy angle was rate-limit-degraded; treat "no controversies found" as weak evidence of absence. The always-on-wearable category as a whole draws consent-of-bystanders criticism (bioethics commentary exists citing Omi by name).

## 5. Company & community health

**Confidence: medium-high (directly verified against Omi's own announcement; not triangulated against SEC/Crunchbase).**

- **Based Hardware Inc.**, San Francisco. Founder: **Nik Shevchenko**. Raised **$2M led by Tim Draper** (announced 2025-01-30), with a Dropbox co-founder, 468 Capital, Embedding VC, and angels. Funds aimed at hiring, developer bounties/hackathons, and **BCI development** (TechCrunch covered the brain-interface angle Jan 2025).
- GitHub: ~12.7k stars, ~2k forks, 668 releases, ~444 open issues — high momentum, broad surface (firmware → cloud).
- Business shape: hardware (necklace, glass) + app-store ecosystem with monetization for app developers. The $2M raise is small for a hardware company — expect either a follow-on round or heavy reliance on the OSS community for velocity.

## 6. Head-to-head: Omi vs screenpipe vs Rewind/Limitless

**Screenpipe** (directly verified against its repo, 2026-06-07):
- **100% local by default** — "nothing sent to external servers." Event-driven capture (app switches, clicks, typing pauses, scrolling → screenshots + accessibility-tree data), system audio + mic with **local Whisper** transcription.
- Storage: local **SQLite** (FTS5 search) + JPEGs (~300 MB / 8 hours).
- Programmability: **REST API on localhost:3030** (search screen/audio/frames, raw SQL), JS/TS SDK plus Tauri/Electron/Swift SDKs, and **"pipes"** — scheduled AI agents defined as markdown files with YAML-frontmatter data permissions.
- MIT, **19.2k stars**, joined **YC S26** (May 2026). Optional cloud sync/AI, never required.

**Rewind / Limitless:** closed-source, cloud-account-tethered; Rewind effectively wound down into Limitless (pendant-first). Not a build-on substrate. *(Context only — this leg was rate-limit-degraded and not independently verified in this pass.)*

| | **Omi** | **screenpipe** | **Rewind/Limitless** |
|---|---|---|---|
| License | MIT | MIT | Closed |
| Default data path | Cloud (GCP/Deepgram/OpenAI) | Local (SQLite + files) | Cloud |
| Screen capture | ScreenCaptureKit snapshots → cloud context | Event-driven screenshots + AX tree, local | Continuous, local index + cloud AI |
| Audio | Live stream → Deepgram; raw audio not retained | Local Whisper | Pendant/mic → cloud |
| Agent hooks | MCP server, webhooks, app store | localhost REST, SDKs, pipes | Minimal |
| Hardware | Necklace, Glass, BCI ambitions | None | Pendant |
| Momentum | 12.7k★, $2M Draper | 19.2k★, YC S26 | n/a |

**Verdict for the screen-memory use case:** screenpipe wins on architecture (local-first, queryable, agent-pluggable); Omi wins on integrated product breadth (wearable + mobile + ecosystem) and on having a hosted memory API an agent fleet can hit from anywhere.

## 7. Stage 11 relevance — agent integration surface

**Confidence: high (directly verified against docs.omi.me and omi.me, 2026-06-07).**

- **Official MCP server, shipped:** hosted SSE at `https://api.omi.me/v1/mcp/sse`, Bearer auth with `omi_mcp_`-prefixed keys (generated in-app: Settings → Developer → MCP), plus a local Docker variant for Claude Desktop. Tools: `get_memories`, `create_memory`, `edit_memory`, `delete_memory`, `get_conversations`, `get_conversation_by_id`. Documented clients: Claude Desktop, Cursor (Poke mentioned).
- **Developer REST API:** `https://api.omi.me/v1/dev` with `omi_dev_` Bearer tokens — memories (incl. batch up to 25), conversations, action items. *(Sourced from a secondary aggregator; shape consistent with the MCP docs but worth one direct doc check before building.)*
- **Webhook app platform:** integration apps register a server endpoint and receive events — **memory-creation trigger** ("run your code when a memory is created"), **real-time transcript stream** ("process live audio transcripts as they happen"), **chat tools** (user-invokable actions like "create a GitHub issue"), and **raw audio byte streaming** for custom STT. Prompt-only apps need no server. Distribution + monetization through the Omi app store.
- **Implication:** Omi's capture layer absolutely can feed agent workflows — it's the most agent-legible of the three (MCP + webhooks + REST). The catch is that everything routes through *their* cloud memory store; you integrate with Omi-the-service, not Omi-the-library. If the play is "agents with ambient operator context," screenpipe's localhost API is the substrate you could embed; Omi is the ecosystem you'd interoperate with.

---

## Open questions / known gaps

- The workflow's adversarial-verify phase was heavily rate-limited; items in §5–§7 were re-verified by direct primary-source fetch instead of the 3-vote panel. The Dev REST API details rest on one aggregator + consistency with official MCP docs.
- Funding figure not triangulated beyond Omi's own announcement + TechCrunch coverage.
- No deep dive into Omi's webhook payload schemas or rate limits — needed before any real integration spike.
- Rewind/Limitless current state asserted from general knowledge, not verified this pass.

## Sources

- [BasedHardware/omi (GitHub)](https://github.com/BasedHardware/omi) · [desktop README](https://github.com/BasedHardware/omi/blob/main/desktop/README.md)
- [Omi Backend Setup docs](https://docs.omi.me/doc/developer/backend/Backend_Setup) · [Omi Apps Introduction](https://docs.omi.me/doc/developer/apps/Introduction)
- [Omi MCP guide (Claude/Cursor)](https://www.omi.me/blogs/integrations/mcp-claude-cursor)
- [Omi privacy policy](https://help.omi.me/en/articles/13162549-omi-privacy-policy)
- [Omi $2M raise announcement](https://www.omi.me/blogs/news/omi-raises-2m-from-tim-draper) · [TechCrunch coverage](https://techcrunch.com/2025/01/08/omi-a-competitor-to-friend-wants-to-boost-your-productivity-using-ai-and-a-brain-interface/)
- [Deepgram self-hosted docs](https://developers.deepgram.com/docs/self-hosted-introduction)
- [screenpipe/screenpipe (GitHub)](https://github.com/screenpipe/screenpipe)
- [Omi API integration (LobeHub aggregator)](https://lobehub.com/skills/basedhardware-omi-omi-api-integration) *(secondary)*
