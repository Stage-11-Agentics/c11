# C11-291 two-key refresh (after C11-268)

Read `luna-owner.md` and `owner-common.md` in this directory (Codex GPT-6-Luna max, fast mode off). Actor `agent:luna-291b`; tab title `C11-291 Keys Luna`.

- Worktree from current origin/main AFTER C11-268 has merged (fetch, confirm `feed.answer.multilineUnsupported` exists in the catalog): `git -C /Users/atin/Projects/Stage11/code/c11 worktree add -b c11-1.0/C11-291-twokeys /Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-291-twokeys origin/main`.
- Two keys only:
  1. `feed.answer.multilineUnsupported` (added by C11-268 with English only): translate into ja, uk, ko, zh-Hans, zh-Hant, ru.
  2. `socket.send.guard_refused` (used in Sources/SocketHandlers/SurfaceHandlers.swift by C11-267, missing from the catalog entirely): add the key with its English value exactly as the call site's defaultValue, plus the six translations. It has a `%@` token; keep it in every locale.
- Mark translated, `jq` must parse, run the token check, zero missing. Do not touch other keys. One PR; `HANDOFF C11-291 REVIEW <head> <PR> <validation>` to tab:210. 20-minute box.
