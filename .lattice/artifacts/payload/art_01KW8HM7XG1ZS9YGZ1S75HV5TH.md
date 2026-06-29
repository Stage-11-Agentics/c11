# C11-153 Validation — OBSERVED live pi exact-session resume

## 1. Unit (safe c11-logic scheme, NEVER host)
`xcodebuild -scheme c11-logic test -only-testing:c11LogicTests/PiConversationTests -only-testing:c11LogicTests/AgentManifestTests`
→ ** TEST SUCCEEDED **: 12 PiConversationTests + 8 AgentManifestTests, 0 failures.
AgentManifestTests.testConversationStrategyPresenceParity green = manifest hasConversationStrategy flip + StrategyRegistry.v1 registration are in sync.

## 2. Live exact-session resume (tagged build com.stage11.c11.debug.c11.153, build 0.53.0/110)
Tagged build: `./scripts/reload.sh --tag c11-153`. Non-symlinked cwd `~/c11-153-pi-live` (avoids the /tmp→/private/tmp slug divergence).

**Setup (pre-quit):** launched `pi` in surface, sent a prompt → pi wrote ONE session:
`~/.pi/agent/sessions/--Users-atin-c11-153-pi-live--/2026-06-29T01-55-25-527Z_019f1116-a8d7-70d5-bc9e-0c91c1050a08.jsonl`
Target session UUID = **019f1116-a8d7-70d5-bc9e-0c91c1050a08**. Set terminal_type=pi (what AgentDetector classifies node+@earendil-works/pi as; set explicitly for determinism).

**Snapshot at graceful quit** (`session-com.stage11.c11.debug.c11.153.json`): pi panel had
`terminal_type='pi'`, `directory='/Users/atin/c11-153-pi-live'`, `surface_conversations.active = None`
(i.e. NO pre-resolved ref — resolution must come from scrape-capture at restore).

**Relaunch with resume** (`./scripts/launch-tagged-automation.sh c11-153 --qa resume`). After restore, on the running instance:

`c11 conversation list --json` →
```json
{ "kind":"pi", "id":"019f1116-a8d7-70d5-bc9e-0c91c1050a08", "state":"alive",
  "captured_via":"scrape", "diagnostic_reason":"matched cwd + mtime after claim",
  "cwd":"/Users/atin/c11-153-pi-live", "placeholder":false }
```

This is the load-bearing evidence:
- `id` == the exact pre-quit session UUID.
- `captured_via:"scrape"` — resolved by **PiScraper + PiStrategy.capture at restore** (snapshot active was None).
- `diagnostic_reason:"matched cwd + mtime after claim"` — the single-candidate (NOT ambiguous) branch of PiStrategy.capture; cwd-slug scoping yielded exactly one candidate.
- `state:"alive"` — which PiStrategy.resume maps to `.typeCommand("pi --session '019f1116-…'", submit:true)` (pinned by green unit test testPiSingleCandidateResumesExactSession).

**Corroboration:** the restored pi surface re-rendered the EXACT prior session (my "say ok" prompt + its "402 Insufficient credits" reply) — proving pi resumed session 019f1116, not a fresh one.

**Resume-rail note:** because the surface carries an *alive conversation ref*, c11's restore uses the ConversationStrategy rail (PiStrategy.resume → `pi --session '<id>'`), NOT the manifest phase-1 `pi -c` fallback (which only fires when there is no ref). Same path C11-152 validated for codex.

## Caveat surfaced (honest)
On a machine with many pi sessions across projects, the whole-tree mirror would be ambiguous→skip; this is exactly why PiScraper does cwd-slug scoping (impl-time deviation, documented). Within a single cwd with >1 session, resume correctly returns ambiguous→skip (safe). pi surfaces need terminal_type=pi present (AgentDetector sets it heuristically once it scans the foreground process; a just-launched pi may not have it until the next scan — the scrape pipeline is a no-op for that panel until then).

VERDICT: PASS — observed live exact-session resume. pr_open unblocked.