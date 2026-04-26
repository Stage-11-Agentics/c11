# C11-22 — Upstream pull: Stability — render, theme, crashes, perf, config, infra (10 picks)

**Bundle theme:** Stability sweep — small upstream-cmux issues covering crashes, render bugs, theme regressions, performance fixes, config-parser regressions, and infrastructure (SSH, AppKit). Disproportionately valuable because each landed fix is a removed source of user-visible failure.

**Source feed:** `code/c11-private/upstream-watch/` (auto-refreshed daily at 08:00 local).
**Original triage:** `code/c11-private/upstream-watch/picks/2026-04-26-pick-10.md` and `picks/2026-04-26-pick-11-25.md`.
**Sibling tickets:** C11-20 (CLI hygiene), C11-21 (Input handling).

---

## Credits roster

These picks must credit the upstream reporters in any commit, PR, or release note that lands the fix.

### Primary reporters (one per pick)

| Reporter | Issue |
|----------|-------|
| @knight42 | [#3162](https://github.com/manaflow-ai/cmux/issues/3162) |
| @shaun0927 | [#2950](https://github.com/manaflow-ai/cmux/issues/2950) |
| @gilsiun | [#1764](https://github.com/manaflow-ai/cmux/issues/1764) |
| @zacharygutt | [#3075](https://github.com/manaflow-ai/cmux/issues/3075) |
| @Corey-T1000 | [#2922](https://github.com/manaflow-ai/cmux/issues/2922) |
| @austinywang | [#1036](https://github.com/manaflow-ai/cmux/issues/1036) |
| @tmad4000 | [#2738](https://github.com/manaflow-ai/cmux/issues/2738) |
| @lawrencecchen | [#2996](https://github.com/manaflow-ai/cmux/issues/2996) |
| @Thinkscape | [#2997](https://github.com/manaflow-ai/cmux/issues/2997) |
| @exlaw | [#2708](https://github.com/manaflow-ai/cmux/issues/2708) |

### Related-issue reporter (likely fixed by same change as #1764)

| Reporter | Issue | Note |
|----------|-------|------|
| @tuzisang | [#2718](https://github.com/manaflow-ai/cmux/issues/2718) | Same dock-badge symptom from a different reporter — likely closes with the same fix |

If the fix for #1764 also closes #2718, credit both reporters in the commit message and reference both issues in the closing PR.

When the corresponding upstream PR exists, also credit its author (preserved by `git cherry-pick`). Use trailers like:

```
Reported-by: @gilsiun <upstream issue #1764>
Also-closes: manaflow-ai/cmux#2718 (reported by @tuzisang)
Cherry-picked-from: manaflow-ai/cmux@<sha> by @<author>
```

---

## Picks

### #3162 — Propagate `SSH_AUTH_SOCK` from CLI environment into SSH startup script
- **Reporter:** @knight42
- **Fix size:** small (env propagation in shared SSH path)
- **Why c11:** SSH workspace bootstrap is shared. Without `SSH_AUTH_SOCK`, agents can't use ssh-agent for git pushes inside SSH workspaces.

### #2950 — `scrollback-limit` drops Ghostty unit suffixes (K/M/G); silent default after PR #2927
- **Reporter:** @shaun0927
- **Fix size:** small (parser regression)
- **Why c11:** Ghostty config parsing in shared submodule path. Silent regression — users think they configured 1G but get the default.

### #1764 — Dock icon badge never appears despite unread notifications being tracked correctly
- **Reporter:** @gilsiun (related: @tuzisang #2718)
- **Fix size:** small (single AppKit `NSApp.dockTile.badgeLabel` assignment, or notification routing)
- **Why c11:** Notification + dock badge wiring is shared AppKit code. State is correct (per the report) — display side is missing.

### #3075 — `cmux.json` named color strings silently reject entire config file
- **Reporter:** @zacharygutt
- **Fix size:** small (validation/error reporting in config loader)
- **Why c11:** Same JSON config loader (renamed config name if applicable, but same code). Silent rejection is the worst kind of bug.

### #2922 — Ghostty `theme = light:X,dark:Y` split syntax not honored — always renders dark
- **Reporter:** @Corey-T1000
- **Fix size:** small (Ghostty config parser in shared submodule path)
- **Why c11:** c11 explicitly uses Light/Dark theme slots (per `code/c11/CLAUDE.md`). This regression directly breaks the c11 theme story.

### #1036 — Crash in `NSToolTipManager`: use-after-free on mouse-enter
- **Reporter:** @austinywang
- **Fix size:** small (lifecycle fix on tooltip detach)
- **Why c11:** AppKit lifecycle bug, not cmux-specific UI. Likely shared. Pure UAF — small focused fix.

### #2738 — SIGSEGV in search thread (`PageFormatter.formatWithState`) racing with `PageList.resizeCols` on io thread
- **Reporter:** @tmad4000
- **Fix size:** small (lock or copy-on-read in PageList)
- **Why c11:** Shared terminal page model. **Caveat:** the c11 CLAUDE.md flags `SurfaceSearchOverlay` as a touchy layering concern — read that section before touching this code path.

### #2996 — Idle spin: `palette.overlay.update` + `find.applyFirstResponder.defer` + `focus.surface.reassert` fire at runloop frequency, saturate one core
- **Reporter:** @lawrencecchen
- **Fix size:** small-medium (debounce/coalesce three known sources)
- **Why c11:** Shared SwiftUI overlay/focus paths. Reporter named the three exact callsites — execute the obvious fix.

### #2997 — Right side of terminal gets cut off, obstructed by scrollbar, when a mouse is connected
- **Reporter:** @Thinkscape
- **Fix size:** small (scrollbar layout when mouse-style scrollbar is active)
- **Why c11:** Shared scroll/render layer. Trivial repro (plug in a mouse). Affects most operators.

### #2708 — Terminal text invisible (white on white) in light mode after updating to 0.63.2
- **Reporter:** @exlaw
- **Fix size:** small (theme color resolution regression)
- **Why c11:** c11 explicitly markets a Light theme slot. A light-mode regression is a brand-relevant bug.

---

## Suggested execution

1. Find upstream PRs that fix these (use `code/c11-private/upstream-watch/prs/`).
2. **#2738 caveat:** before touching, re-read `code/c11/CLAUDE.md` "Terminal find layering contract" — the fix may need to land via `SurfaceSearchOverlay` mounting from `GhosttySurfaceScrollView`.
3. **#2996 measurement:** before debouncing, capture an idle CPU profile to confirm the three named callsites are still the dominant offenders in c11 (the diagnosis is from upstream and our fork may have shifted).
4. **#1764 verify pairing:** test that the fix actually closes #2718 before crediting both reporters.
5. Land as 2-3 PRs grouped by theme: "Crash sweep" (#1036, #2738, #2984 — but #2984 is in C11-20), "Config parser sweep" (#2950, #3075, #2922), "AppKit/render polish" (#1764, #2997, #2708, #2996), and SSH (#3162) standalone.

---

## Cross-bundle note

#2984 (CLI SIGABRT closed pipe) is also a crash; it's bundled into C11-20 because it's CLI-domain. If you do a focused "crash sweep," consider co-landing it with #1036 + #2738 from this ticket.
