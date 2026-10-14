# c11 1.0

On 2026-10-01 Atin made the cmux harvest a major version: **c11 1.0**. We take our time and fully absorb what is worth having from upstream cmux, inside c11's doctrine (host and primitive; no tenant config writes).

Map: `../cmux-landscape-2026-10-01.md`. Research briefs: `_preamble.md` and `_brief-*.md`. Reports land here as `NN-topic.md`.

## Atin's rulings on the landscape (2026-10-01)

| In scope (research) | In scope (grab, no debate) | Out |
|---|---|---|
| 01 Event journal as status source | Socket and CLI hardening (all of it) | Account-backed platform (cloud, mirroring, CodeRouter) |
| 02 Agents on SSH hosts, session move | Restore hardening | Fork Conversation, Vault |
| 03 Feed, replies from notification banners | Workspace groups | Agent hibernation (c11 has its own) |
| 04 iOS companion (exploratory; probably not) | Navigation: focus history, Recently Closed, reopen | Automations engine, `cmux events`, `cmux current` |
| 05 Upstream bug-fix sweep | Basic browser updates | Saved layouts, diff viewer, file tools, iOS Simulator panes, computer use |

Open: hook integration (pros and cons under discussion; c11's doctrine forbids tenant config writes).

## Rulings, round 2 (2026-10-01)

- **S1** (c11 ssh relay hole): approved. Disable the relay in a point release now; 1.0 rebuilds remote transport deny-by-default. Codex is on it (tab "SSH Relay Fix"), stopping at PR plus CI; shipping the release needs Atin's go. Repo is public: neutral wording, nothing from this folder committed until it ships.
- **B1**: yes, finish the bug-sweep verification, on **Bravo**. Not started; waiting for Atin to switch accounts. Prompt: `05-bug-sweep-data/verifier-prompt.md`.
- **B2**: yes. Fix the 2026-08-25 deadlock root in the same Ghostty update as the cmux fixes.
- Pending: B3 (sidebar), B4 (GPU reclaim), J1 to J5 (journal), and the I, G, S2 to S4 and F series.

## Rulings, round 3 (2026-10-01)

- All build work goes to Codex or Grok workers. No Opus subagents.
- Bug sweep pipeline: finish the verifiers, then a Codex tab merges everything into `05-bug-sweep-data/LEDGER.md`, then Fable and Astra audit it independently (`audit-brief.md`). The lead reconciles the two audits.
- The final deliverable is a local HTML page laying out the cmux sync for c11 1.0 (`c11-1.0.html`), kept in step with `C11-1.0.md`. Atin gives feedback on the decisions, then the build starts.

## Rulings, round 4: D1 to D27 (2026-10-01)

Atin's answers, as recorded in `BACKLOG.md`:
- **In:** D1 (build the journal, with strong analytics), D2, D4, D5, D6, D7, D8 (behind a filter), D17 (workspace groups are core; test carefully), D20 (agents read `c11 history`), D26, D27.
- **Lead's call:** D3, deferred to the lead: a SQLite journal with an NDJSON export.
- **Out:** D11 (maybe Overwatch), D12, D13 (not a c11 concept), D14, D15, D16, D18, D21, D23, D24, D25 (no separate point releases).
- **Later:** D19. D22, only on a clear bug.
- **Pending:** D9 (per-tab hosts, Prime sandboxes) and D10 (lid close).
- **Features:** defer to the revised recommendations, adjusted by the rulings above.
- **Next:** ticket writers (Codex and Grok) turn `BACKLOG.md` into Lattice tickets tagged `c11-1.0`. `ORCHESTRATOR-PROMPT.md` drives the build.

- **D9:** out of 1.0. The Prime and remote-hosts spike and build both move to **c11 1.1**.
- **D10:** agreed. No lid-close work in 1.0; Atin uses Caffeine to keep Macs awake.

## Rulings, round 5 (2026-10-01, night)

- **Bug tiers approved** (`05-bug-reconciled.md`):
  - Tier 1, 30 must-do bugs: cluster tickets.
  - Tier 2, 51 bugs: ride along in the same PRs.
  - Tier 3, 34 bugs: parked.
- **B058:** D15 stands. Tab numbers keep resetting. The c11 skill tells agents to hold tab UUIDs across restarts.
- **Run control:** the orchestrator stays in planning mode (wave 0) on Hyperion. No build mode until Atin's explicit go, relayed by the lead.
- **Model routing:** save GPT-6-Astra for the hard tickets. Grok owns the rest.
- **Atlas:** Atin is preparing it with the Atlas Fleet Prep tab (tab:138).
