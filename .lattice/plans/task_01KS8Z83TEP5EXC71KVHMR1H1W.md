# C11-116: Streaming pane output: c11 subscribe (NDJSON viewport events)

## What it does

A long-lived `c11 subscribe` CLI that streams NDJSON viewport events from a target surface to stdout, so external scripts and sibling agents can react to another pane's output in real time without polling `c11 read-screen`.

Equivalent in spirit to Zellij's `zellij action subscribe --format json`.

## Why

Today an orchestrator watching a worker pane has to poll `read-screen` on an interval and diff, which is wasteful and racy. A streaming primitive unlocks:

- Watching another agent's output without focus-stealing or busy-loops.
- Client-side "wait until command finishes" patterns (subscribe → watch for prompt return / sentinel → exit), without c11 owning brittle prompt-detection logic.
- Lightweight log-aggregation / tee patterns across surfaces.

This was the single Zellij capability flagged as a real c11 gap in the Zellij ↔ c11 comparison (2026-05-22). The complementary "blocking wait on a command" ticket was deliberately dropped — subscribe makes block-wait a library problem rather than a c11 problem.

## Shape

```bash
c11 subscribe --workspace $WS --surface $SURF [flags]
c11 subscribe --workspace $WS --all-surfaces       # multiplex events from every surface in the workspace
```

Flags:
- `--format json` — default and only format in v1; reserve the flag for forward compat.
- `--ansi` — preserve SGR/escape codes (default: strip).
- `--include-scrollback` — emit a one-time backfill of current scrollback before live events.
- `--from-line N` — replay-style consumers that already saw through line N.
- `--heartbeat <seconds>` — emit `{"type":"heartbeat","ts":...}` for dead-connection detection.

Targeting follows the rest of c11: `--workspace + --surface` together when remote, both omitted when watching your own surface (env vars default them).

## Event schema (NDJSON, one JSON object per line)

```json
{"type":"line","ts":"...","surface":"surface:70","seq":1042,"text":"npm test"}
{"type":"line_partial","ts":"...","seq":1043,"text":"FAIL  src/"}
{"type":"scroll","ts":"...","seq":1044,"top_line":827}
{"type":"clear","ts":"...","seq":1045}
{"type":"resize","ts":"...","seq":1046,"cols":120,"rows":40}
{"type":"exit","ts":"...","seq":1047,"reason":"surface_closed"}
{"type":"dropped","ts":"...","seq":1048,"count":17}
```

- `seq` is monotonic per subscription.
- `dropped` markers appear when the bounded ring buffer overflowed; consumer can fall back to `read-screen --scrollback` to repair state.

## Backpressure

Bounded ring buffer per subscription (configurable; e.g. 4 KiB lines default). Slow consumer → drop oldest + emit `dropped` marker. **The producer side (PTY → renderer path) must never block.** Typing latency is sacred; any added work must respect the constraints noted in `c11/CLAUDE.md` under "Typing-latency-sensitive paths."

Multiple concurrent subscribers on the same surface must fan out from a single render tap — do not multiply rendering cost per subscriber.

## Out of scope for v1

- Remote subscribe over a network socket — local socket only.
- Per-region or per-rect subscriptions — full viewport only.
- Server-side filtering by regex or content — let consumers filter.

## Risks / footguns to address in implementation

- The viewport is wrapped, post-render text. Subscribers wanting raw PTY bytes need a different (later) API — document this clearly.
- ANSI stripping adds CPU; per-subscription opt-in.
- Off-main handling per the c11 "Socket command threading policy" — telemetry-class hot path; subscribe handler should parse/validate off-main and only touch the renderer tap via the minimum necessary main-thread hop.

## Acceptance criteria

1. A subscriber receives every line emitted into a target pane (integration test).
2. Slow consumer triggers `dropped` events without producer-side stall (load test, assert typing latency unchanged on the producing surface).
3. Cross-surface targeting works: subscribe from outside the surface being watched, via `--workspace + --surface`.
4. `--include-scrollback` followed by live events yields no gaps and no duplicates (`seq` monotonic across the boundary).
5. `c11 subscribe` exits cleanly when the target surface closes (final `exit` event, zero exit code).
6. SKILL update: add `c11 subscribe` to `skills/c11/SKILL.md` under a new "Streaming output" section, with a worked example for the orchestrator-watching-worker pattern.

## Lattice Orchestrator Workflow

Medium complexity, multi-phase (socket handler + ring buffer + render tap + CLI + skill update). Default to the **Lattice Orchestrator Workflow** — one delegator pane in its own worktree, plan → implement → review → fix → PR.
