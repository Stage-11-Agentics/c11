# Catch-up

The c11 fork last shared a common ancestor with upstream at commit `53910919` on 2026-03-18. Since then upstream has merged ~900+ PRs that c11 hasn't seen.

`backlog.md` is the master list of those PRs, marked one of:

- `[ ]` unreviewed
- `[y]` yes — worth attempting
- `[n]` no — skip (branding, infra, c11-divergent feature, etc.)
- `[?]` maybe — needs a closer look
- `[D]` done — already processed (landed, skipped, or escalated; see triage log)

The catch-up flow:

1. **Generate the backlog** (one time):
   ```bash
   ../scripts/list-merged.sh --since 53910919 > backlog.md
   ```
2. **Curate** — Atin walks the list, marks each row `y` / `n` / `?`. Don't try to do this in one sitting; spread over a few sessions.
3. **Drive batches** — `/upstream-triage --catchup --batch-size 10` pulls the next 10 `[y]` rows and runs the standard per-PR flow. Each becomes a c11 PR or a triage-log entry.
4. **Update** — as PRs are processed, the skill flips `[y]` to `[D]`. Re-curate `[?]` rows when more context arrives.

The forward-triage and catch-up flows share the same per-PR machinery. The only difference is where the PR list comes from.
