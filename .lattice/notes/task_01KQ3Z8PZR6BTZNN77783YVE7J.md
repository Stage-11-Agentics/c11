# C11-20 — Upstream pull: CLI hygiene & focus policy (7 picks)

**Bundle theme:** Small upstream-cmux issues that align tightly with c11's documented Socket focus policy and CLI hygiene. Every pick lives in shared CLI/socket code.

**Source feed:** `code/c11-private/upstream-watch/` (auto-refreshed daily at 08:00 local).
**Original triage:** `code/c11-private/upstream-watch/picks/2026-04-26-pick-10.md` and `picks/2026-04-26-pick-11-25.md`.
**Sibling tickets:** C11-21 (Input handling), C11-22 (Stability).

---

## Credits roster

These picks must credit the upstream reporters in any commit, PR, or release note that lands the fix. Original issue authors:

| Reporter | Issue |
|----------|-------|
| @andy5090 | [#3098](https://github.com/manaflow-ai/cmux/issues/3098) |
| @jasonkuhrt | [#1418](https://github.com/manaflow-ai/cmux/issues/1418) |
| @hummer98 | [#2839](https://github.com/manaflow-ai/cmux/issues/2839) |
| @nengqi | [#2984](https://github.com/manaflow-ai/cmux/issues/2984) |
| @EtanHey | [#3129](https://github.com/manaflow-ai/cmux/issues/3129) |
| @austinywang | [#3065](https://github.com/manaflow-ai/cmux/issues/3065) |
| @shaun0927 | [#2951](https://github.com/manaflow-ai/cmux/issues/2951) |

When the corresponding upstream PR exists, also credit its author (preserved automatically by `git cherry-pick`). Use commit trailers like:

```
Reported-by: @andy5090 <upstream issue #3098>
Cherry-picked-from: manaflow-ai/cmux@<sha> by @<author>
```

---

## Picks

### #3098 — `tty` field always null in `--json tree` output
- **Reporter:** @andy5090
- **Fix size:** trivial (~5 lines, one JSON serializer)
- **Why c11:** `c11 tree` is a documented surface in `skills/c11/SKILL.md`. Shared code path.
- **Why now:** Quick win, validates the cherry-pick → CMUX→C11 rename → land flow on something risk-free.

### #1418 — `new-surface --no-focus` flag
- **Reporter:** @jasonkuhrt
- **Fix size:** small (CLI flag + one socket arg)
- **Why c11:** Directly aligned with the Socket focus policy in `code/c11/CLAUDE.md` ("non-focus commands should preserve current user focus context"). Adding `--no-focus` is the canonical c11-style move.

### #2839 — `cmux send` should error when `--surface` omitted, not silently send to current
- **Reporter:** @hummer98
- **Fix size:** small (one validation check at CLI entry)
- **Why c11:** Same focus-policy spirit — "don't silently apply to wrong target." Identical bug almost certainly applies to `c11 send`.

### #2984 — CLI SIGABRT writing to closed pipe (NSFileHandle exception not caught)
- **Reporter:** @nengqi
- **Fix size:** small (`@try/@catch` wrap or lower-level write)
- **Why c11:** CLI socket layer is shared. SIGABRT on broken pipes is a v1 footgun.

### #3129 — `surface.send_text` silently drops keystrokes when target tab is not the focused tab of its pane
- **Reporter:** @EtanHey
- **Fix size:** small (route to surface, not just to focused tab in pane)
- **Why c11:** Shared socket command. Silent drop is the worst kind of failure for agent automation. Aligns with focus policy.

### #3065 — CLI focus/workspace actions often spawn a new window instead of focusing the existing one
- **Reporter:** @austinywang (upstream maintainer — confirmed real)
- **Fix size:** small (existing-window resolution before fallback to new)
- **Why c11:** Same focus policy. Pairs naturally with #1418, #2839, #3129 as a "focus ergonomics" sweep.

### #2951 — `workspace.create --layout` returns success but leaves orphan workspace on partial layout failure
- **Reporter:** @shaun0927
- **Fix size:** small (transactional cleanup on partial failure)
- **Why c11:** Shared CLI surface. Orphan resources from "successful" failures break agent retry assumptions.

---

## Suggested execution

1. Find which of these have upstream PRs already open or merged (use `code/c11-private/upstream-watch/prs/`).
2. For PRs that exist: cherry-pick into a `cmux-pr/NNN-slug` branch in c11. Preserve upstream author in commit metadata. Add `Reported-by:` trailer for the issue reporter.
3. For issues without an upstream PR yet: write the fix in c11, file an upstream PR if the fix isn't c11-specific (per the Upstream Fixes guidance in `code/CLAUDE.md`), and credit the issue reporter on both sides.
4. Apply the CMUX→C11 rename **at integration time**, not at branch creation, so cherry-pick math stays clean.
5. Land as a single themed PR titled "Focus ergonomics & CLI hygiene sweep (closes upstream #3098, #1418, #2839, #2984, #3129, #3065, #2951)" or similar.
