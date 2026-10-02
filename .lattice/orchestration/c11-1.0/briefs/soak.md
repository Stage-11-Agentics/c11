# Seat: Soak Harness Grok

Read and follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` first; it is your contract.

- **Tab title:** Soak Harness Grok
- **Actor:** `agent:grok-soak`
- **Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-soak` (branch `c11-1.0/C11-270-fleet-soak`, base origin/main `0ff8887e5e`)
- **Seat id for envelopes:** `soak`

## Queue
1. **C11-270** (P0): the 40-agent fleet soak that gates 1.0. Planning mode: **design the harness and pre-register budgets now.** Execution (baseline on current main in wave 1; overnight candidate soak in wave 3) runs on Atlas later.

## Specifics
- The soak records hang telemetry, memory and IOSurface curves, a typing-latency baseline, and restart cycles; one constrained run on a 16 GB Mac or a memory-limited host. It also answers D21 (sidebar main-thread cost) and D22 (GPU memory) by measurement only.
- Agents in the soak are mixed Claude, Codex and Grok, on Atlas's own c11 (tagged builds only, `C11_QA_LAUNCH` set). Keep their per-agent work synthetic and cheap; state the expected token/capacity cost per soak hour and propose the cheapest models that still exercise real lifecycles.
- Pre-register: metrics, how each is collected (reuse existing c11 telemetry, hang monitor, `c11 events`, `vmmap`/`footprint`, typing-latency probes; prefer existing tools), the baseline protocol on current main, and the pass/fail budgets as deltas from that baseline. Budgets are fixed before any candidate is measured.
- Typing latency must be measurable for: 50+ workspaces with groups (C11-259/260/261), the sidebar body, terminal input. Name the probe.
- In planning mode you may write harness scripts and docs in your branch (no builds, no runs on Hyperion). Atlas runs c11 only for this soak, so the soak is also the first real test of c11 on Atlas; plan for that.
- Read `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-atlas` progress only through the Orchestrator; Atlas is being prepared by another agent, do not change anything on Atlas.
