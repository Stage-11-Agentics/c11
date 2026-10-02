# C11-271: Capture real lifecycle sequences as the journal and Feed fixture oracle

## Why
The next lifecycle implementation needs observed hook sequences and visible outcomes so review converges on the incidents that actually confused the operator. Backlog item: F3.

## Evidence
- All c11 code citations below are on origin/main `0ff8887e5e`; upstream citations are on upstream/main `920ff39ff7`.
- c11: `Resources/bin/claude:207` injects six hooks with asynchronous PreToolUse. `CLI/c11.swift:17006` caches AskUserQuestion while `:17036` assumes a later Notification. `Resources/bin/codex:47` carries the legacy notify payload; `Sources/AgentModelDetection.swift:88` currently has prompt/agent/tool-result observations.
- Research: BACKLOG.md F3; report 01 Effort and risk; Fable §3 week 1; Astra §3 acceptance examples and §4 late-event counterexample; `docs/aar-c11-188-attention-loop.md:59` explains the missing empirical oracle.
- Upstream: #15173/#16257 late-event fixes and #6606 bypass behavior are reference incidents, not a substitute for c11 captures.

## Scope
In: sanitized, replayable real captures for Claude normal and bypass modes, Codex, Grok and OpenCode; incident provenance and expected marks. Out: J2 fold/store implementation, speculative signal parity, screen classification and independent fixes to the A1 attention bug batch.

## Approach
Record hook/source occurrence and arrival order, provider version, source SHA, exact session/tab attribution and visible state before/after each step. Separate raw observed behavior from the intended repaired projection. Keep structural tool names where needed, but remove prompt/tool bodies and private identifiers. Where a provider emits no signal, record absence/capability limits rather than fabricate an event. Derive controlled reorder/restart variants from named real captures and label those variants.

## Acceptance criteria
1. The corpus contains versioned tagged-build captures for all five requested modes/providers: Claude normal, Claude bypass, Codex, Grok and OpenCode, each with a replay recipe and expected observations.
2. Capture bypass AskUserQuestion and ExitPlanMode, late async PreToolUse after Stop, Esc interruption, restart while waiting, and tab B’s tool start while tab A waits. Every incident has source/arrival ordering and a visible-state oracle; list missing native signals explicitly.
3. Include the C11-189/GAF-13 child-completion case as an attribution regression: a child callback must not be treated as the root finishing.
4. A reviewer can replay normalized fixtures without provider/network access and compare their expected projections. A fixture manifest links each transformed record to the sanitized capture and distinguishes current bug behavior from the intended result.
5. Public fixture artifacts contain no user prompt or tool bodies, secrets, private account names or real conversation identifiers.

## Validation
Capture on an Atlas-built tagged app after F1 and record the real UI through bounded computer use; use a verified display and dismissal. Add a lightweight fixture reader/replay contract, not tests that grep source text. Replay is the oracle handed to J1/J2 and Feed; the capture job is not a 72-hour soak.

## Dependencies
Depends on F1 / C11-216 for the tagged capture route. Unlocks J1 and the attention/Feed workstream. Coordinate the sibling-clear/bypass cases with A1; the fixture ticket owns evidence only.

## Risks
Provider/version drift, missing native signals and accidental content disclosure can invalidate fixtures. Capture must not add blocking hooks or mutate tenant config. Keep recording overhead out of hot paths; no new product UI is expected. Apply docs/aar-c11-188-attention-loop.md: evaluate the named fixtures/questions, cap review/fix cycles at three, and escalate non-convergence instead of expanding the contract.

Size: S. Tier: P0. Doctrine check: optional observation and c11-owned storage only; no tenant configuration writes, automatic answers or trust broadening.

