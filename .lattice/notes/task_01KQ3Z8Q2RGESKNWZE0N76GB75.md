# C11-21 — Upstream pull: Input handling — keyboard, IME, paste, clipboard, signals (8 picks)

**Bundle theme:** Small upstream-cmux issues affecting input handling: keyboard layouts, IME, paste/clipboard, signals, and keystroke-triggered UI. Disproportionately important because c11 ships in 6 non-English locales (ja, uk, ko, zh-Hans, zh-Hant, ru) and any input-path bug compounds across them.

**Source feed:** `code/c11-private/upstream-watch/` (auto-refreshed daily at 08:00 local).
**Original triage:** `code/c11-private/upstream-watch/picks/2026-04-26-pick-10.md` and `picks/2026-04-26-pick-11-25.md`.
**Sibling tickets:** C11-20 (CLI hygiene), C11-22 (Stability).

---

## Credits roster

These picks must credit the upstream reporters in any commit, PR, or release note that lands the fix.

### Primary reporters (one per pick)

| Reporter | Issue |
|----------|-------|
| @wada811 | [#3061](https://github.com/manaflow-ai/cmux/issues/3061) |
| @DaikiHayata | [#1456](https://github.com/manaflow-ai/cmux/issues/1456) |
| @tmad4000 | [#3096](https://github.com/manaflow-ai/cmux/issues/3096) |
| @jewel-sallylab | [#3069](https://github.com/manaflow-ai/cmux/issues/3069) |
| @alceal | [#1469](https://github.com/manaflow-ai/cmux/issues/1469) |
| @sldx | [#1153](https://github.com/manaflow-ai/cmux/issues/1153) |
| @freshtonic | [#2105](https://github.com/manaflow-ai/cmux/issues/2105) |
| @shaun0927 | [#2949](https://github.com/manaflow-ai/cmux/issues/2949) |

### Related-issue reporters (likely fixed by same change as #3069)

| Reporter | Issue | Note |
|----------|-------|------|
| @AndreySoloviev | [#2756](https://github.com/manaflow-ai/cmux/issues/2756) | Cyrillic paste — same root cause as #3069 |
| @pankrusheff | [#2891](https://github.com/manaflow-ai/cmux/issues/2891) | Qt non-ASCII paste — same root cause |

If the fix for #3069 also closes #2756 and #2891, credit all three reporters in the commit message and reference all three issues in the closing PR.

When the corresponding upstream PR exists, also credit its author (preserved by `git cherry-pick`). Use trailers like:

```
Reported-by: @jewel-sallylab <upstream issue #3069>
Also-closes: manaflow-ai/cmux#2756 (reported by @AndreySoloviev)
Also-closes: manaflow-ai/cmux#2891 (reported by @pankrusheff)
Cherry-picked-from: manaflow-ai/cmux@<sha> by @<author>
```

---

## Picks

### #3061 — Cmd+Shift+[ triggers `nextSurface` instead of `prevSurface`
- **Reporter:** @wada811
- **Fix size:** trivial (single keybind table entry)
- **Why c11:** Pure regression in shortcut wiring (likely from cmux PR #2528). c11 inherited the same shortcut table.

### #1456 — Zoom-in not working; zoom-out works fine
- **Reporter:** @DaikiHayata
- **Fix size:** small (asymmetry in font-size handler)
- **Why c11:** Font-size scaling is shared Ghostty/terminal code. Asymmetry suggests one branch missing a sign or a clamp.

### #3096 — Copying soft-wrapped long command inserts hard newlines at wrap points
- **Reporter:** @tmad4000
- **Fix size:** small-medium (terminal selection-to-clipboard path)
- **Why c11:** Lives in shared Ghostty/terminal selection code. Pasting a copied command into another terminal silently breaks it.

### #3069 — Cmd+V paste replaces non-ASCII UTF-8 (Korean Hangul) with `?`
- **Reporter:** @jewel-sallylab (related: @AndreySoloviev #2756, @pankrusheff #2891)
- **Fix size:** small (clipboard encoding pipeline)
- **Why c11:** Shared paste path. **Bonus:** likely closes #2756 (Cyrillic) and #2891 (Qt non-ASCII) — one fix, three issues. High-value, especially given c11's 6-locale shipping story.

### #1469 — Option key characters not reachable on non-US keyboard layouts
- **Reporter:** @alceal
- **Fix size:** small (option-key passthrough in keyboard handler)
- **Why c11:** Shared keyboard path. Blocking option+key on EU/CJK layouts hits real users on every shipping locale.

### #1153 — `alt+backspace` doesn't delete last word
- **Reporter:** @sldx
- **Fix size:** trivial (single keystroke handler)
- **Why c11:** Universal macOS convention. Pure delight bug — every Mac user hits this.

### #2105 — `ctrl-z` kills process instead of backgrounding
- **Reporter:** @freshtonic
- **Fix size:** small (signal forwarding in PTY layer)
- **Why c11:** Shared shell signal handling. POSIX behavior is broken — real correctness bug.

### #2949 — Modifier press/release events dropped while IME marked text is active
- **Reporter:** @shaun0927
- **Fix size:** small-medium (IME state machine + modifier forwarding)
- **Why c11:** Shared IME path. Reporter has the diagnosis precise.

---

## Suggested execution

1. Find upstream PRs that fix these (use `code/c11-private/upstream-watch/prs/`). Many of these may be fixed in a single upstream PR each — keyboard work tends to be focused.
2. **Test on real non-English input** for #1469, #3069, #2949 — c11 ships in ja/uk/ko/zh-Hans/zh-Hant/ru, so locale-specific regressions need to be verified per locale before landing.
3. Land #3069 carefully — verify the same fix actually closes #2756 and #2891 before claiming all three; don't credit reporters whose bugs aren't actually fixed.
4. Apply CMUX→C11 rename at integration time only.
5. Consider shipping as 2 PRs: one for "input convention fixes" (#3061, #1456, #1153, #2105) and one for "international paste/IME bundle" (#3069, #1469, #2949, #3096) — the latter benefits from being verified across all c11 shipping locales.
