# UX audit synthesis — launch panel v2

*Two independent audits of the same design: gpt-5.6-sol xhigh (`UX-AUDIT.md`) and Fable 5
(`UX-AUDIT-FABLE.md`), 2026-07-24. Both drove the live prototype, not just the source. This
synthesis merges them, marks what operator decisions already resolved, what was fixed in the
prototype immediately, and what still needs a call.*

## Already resolved (decision or fix landed)

| Finding (both audits unless noted) | Resolution |
|---|---|
| Post-launch focus/occlusion blockers (sol B3+S2, Fable S3-A) | **Decision 7: ↵ launches AND closes.** The panel never sits over a booting agent. |
| Keyboard can't reach dropdowns (sol B1, Fable B1) | **Decision 9: dropdowns are mouse-only**, ↵ on a harness row launches what's shown. Both auditors listed exactly this as their "option 1." Column copy now reads `preset to base · click to tweak · ↵ launches shown`. |
| Harness base editor missing (sol B5, Fable M5) | Base-recipe editor added under the harness grid (rev 3), absorbing the old Agents & Automation fields. |
| Settings pins contradict launch-sets-default (sol S3, Fable S2) | Pin buttons deleted from Settings rows; default strip is now pure status text ("set by launching · 2m ago"). Last-launched is the only writer. |
| Disabled-harness rollup miscounts (sol M2, Fable M4) | Now "+ 2 disabled · 1 not detected — Settings ›". |
| Inert "—" effort dropdown is a fake control (Fable M2) | Now static dim text, no menu. |
| Gold spent on prose (sol S7, Fable M6) | Header default value and hint-bar phrase de-golded; gold = ● default, kb-focus, changed dropdowns, sys-prompt chips only. |
| No keyboard route to Settings (Fable M3) | `⌘,` added to the hint bar. |
| Mock hygiene: fractional launch counts (sol M6), fake "deep" effort tier (Fable P3) | Integer stats; claude ladder now `low/medium/high/xhigh`. |

## Do at implementation time (agreed, no decision needed)

1. **Focus contract for the open panel** (sol B3, Fable B2 — the surviving half of the blocker).
   Panel takes key focus on open. Clicking a terminal moves focus out; the panel drops to a
   visibly dimmed unfocused state (gold spine falls back to gray ladder). Click or ⌘⇧A
   re-activates. **Esc belongs to whatever has focus** — it never closes an unfocused panel.
2. **Esc peels one layer**: open dropdown → close dropdown; else close panel (Fable S5, verified
   broken in the prototype's mock JS — spec it, don't inherit it).
3. **Pane-relative geometry** (sol B4, Fable S3-B): clamp `width = min(780, paneWidth − 24)`;
   below ~460pt center on the window instead; columns scroll independently past N rows under
   sticky headers; kb-focus auto-scrolls into view.
4. **Pane link ring**: while open, hold a 1px goldFaint inset ring on the target pane — answers
   "which pane" for clamped/⌘⇧A cases (Fable S3).
5. **Default-write visibility without a toast** (sol S1, Fable S1; toasts are ruled out): the
   A-button tooltip always names the effective default; when a launch *changes* the default, pulse
   the A button's gold accent once (the §7 flash vocabulary); the harness row's hover label reads
   `launch — sets default`. Write-time feedback, zero chrome.
6. **Anonymous default snapshot** (sol B2, Fable Q3): a tweaked harness launch becomes the default
   as a *persisted resolved snapshot* (harness · model · effort), not a pointer to the mutable
   base. The DEFAULT tag renders on the harness row with its tweaked dropdowns; Settings' strip
   prints the resolved axes. Editing/deleting configs or bases never mutates the snapshot.
7. **Vocabulary split** (Fable S4, sol M1): "default" = system default, exclusively. Harness-side
   values are "base" everywhere. Dropdowns are labeled Model and Effort in accessibility names.
8. **Tweaks reset on close** (Fable M1): reopening the panel always shows bases. One-offs are
   one-offs; repeat intent is already captured by launch-sets-default and + save.
9. **Real accessibility tree** (both): every row/dropdown is a real control with role + label —
   VoiceOver and c11's own computer-use validation agents depend on it.
10. **Changed-chip contrast on focused rows** (Fable P1): `.changed` inside `.kb-focus` needs a
    stepped-up treatment; today it's gold-on-goldFaint and disappears.

## Final calls (made 2026-07-25, operator delegated)

1. **The recent strip: conditional (option b).** Hidden when recent ≡ default (the steady state —
   panel gets the row back). Appears only when the last launch happened outside the panel
   (CLI, blueprint, ⌘-launch) or immediately after a default *change*, where it shows the
   previous default with a `restore ↩` affordance — one-click undo for a misfired
   launch-sets-default. This is the only undo surface the rule needs.
2. **Inheritance display: resolved phrasing adopted.** One control per field; the inherited
   choice reads `Inherit — opus, from claude code base`. Single provenance label (○/●), no
   duplicate badge+chip state.

## Where the auditors disagreed

Only once, and your mouse-only decision mooted it: sol wanted Tab/Shift-Tab traversal into
dropdowns (platform convention), Fable wanted a ←→ sub-cursor (one new key pair). If keyboard
tweaking ever becomes a demand, Fable's ←→ shape fits the ↑↓/↵ grammar better; park it.
