# c11mux Module 1 — Implementation Notes

Non-normative notes recorded during M1 implementation. Companion to
`docs/c11mux-module-1-tui-detection-spec.md`.

## Context at start

- Branch: `features/c11mux-m1` (worktree at `/Users/atin/Projects/Stage11/code/cmux-worktrees/m1`).
- Starting commit: `9b17eab8 c11mux: land M1, M3+6, M4, M5, M7, M8 specs + integration review`.
- All seven module branches sit at the same commit: spec docs only, no module code.

## M2 shipped with M1

The M1 spec's Goals state that declaration "goes through M2's `surface.set_metadata`"
and that the heuristic calls an in-process accessor "the M2 implementation will add."
The M1 brief in `/tmp/c11mux-impl/m1.md` and the shared `_common.md` both claimed
"M2 (metadata) is already implemented" — but a grep across `Sources/` confirms it is
not: zero matches for `surface.set_metadata`, `SurfaceMetadataStore`, or
`setSurfaceMetadata` outside `docs/`.

M1 cannot ship without the M2 substrate — there is no blob to write to, no
precedence chain to gate the heuristic against, no socket method for declaration
to funnel through. Rather than stall, this branch implements the minimal M2
substrate required by M1's contract:

- `Sources/SurfaceMetadataStore.swift` — per-workspace per-surface metadata map
  plus the parallel `metadata_sources` sidecar; per-workspace serial queue; 64 KiB
  size cap; canonical-key validation; precedence-chain evaluation.
- `surface.set_metadata`, `surface.get_metadata`, `surface.clear_metadata` v2
  JSON-RPC handlers in `Sources/TerminalController.swift`.
- `cmux set-metadata`, `cmux get-metadata`, `cmux clear-metadata` CLI in
  `CLI/cmux.swift`.
- Pruning on surface close / workspace close, mirroring the existing
  `surfaceTTYNames` lifecycle.

Deviations from the full M2 spec:

- Reserved keys carried in the validation table: `role`, `status`, `task`, `model`,
  `progress`, `terminal_type`, `title`, `description`. Rendering for `title` /
  `description` belongs to M7 and is not wired here; the validation catches wrong
  types so tests written against M2's canonical-key rules still pass.
- The sidebar chip render (M3) is not wired. `surface.set_metadata` is a pure
  storage primitive; M3 will consume it later.
- No OSC path yet. M7 adds the `osc` source's call site; the enum accepts the
  value so precedence gating works the moment OSC writes start.

If a later M2-specific branch needs to supersede any of this, the surface is small
enough to rebase onto cleanly: one Swift file, ~20 lines of dispatch code, one CLI
subcommand family.

## Decisions worth recording

- **Single `ps` pass for ports + agents.** PortScanner widens its `ps -o` columns
  from `pid=,tty=` to `pid=,ppid=,tty=,tpgid=,comm=,args=` and hands the rows to
  both the port join and an `AgentDetector` classifier. One process fork per scan,
  not two — matches the M1 spec's "merge — one `ps` is cheaper than two" note.
- **Agent scan scheduling.** Reuses PortScanner's 200 ms coalesce + 6-scan burst.
  Adds a 10 s safety-net timer on the workspace's main tab manager (mirrors the
  existing agent-PID sweep pattern). No separate dispatch queue — agents ride on
  PortScanner's utility queue.
- **Declaration via the in-process accessor, not self-RPC.** The CLI writes
  through the socket, but the heuristic writes through
  `SurfaceMetadataStore.shared.setInternal(...)` — no socket round-trip for an
  in-process writer.
- **`cmux set-agent --surface` default.** If `$CMUX_SURFACE_ID` is set in the
  calling environment, the CLI uses it — so an agent running inside a surface
  always annotates its own surface rather than the focused one. Matches the
  pattern established by `cmux set-status`.
- **Wrapper env-var forwarding.** `Resources/bin/claude` reads `CMUX_AGENT_TYPE`
  (and optionally `_MODEL`, `_TASK`, `_ROLE`) once, calls `cmux set-agent`, then
  `exec`s the real binary. Fire-and-forget — failure to register never blocks the
  TUI start.

## Tests

- `tests_v2/tui_detection_helpers.py` — TUI-mock helper + poll utilities.
- M1 test files per the spec's "Required tests" list.
- M2 round-trip and precedence tests — scoped to what M1 needs to assert; a later
  M2-dedicated branch can extend them.
