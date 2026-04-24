# C11-13: Tab bar chrome: collapse, expand, and hide states

Let the operator shrink, expand, or fully close the top tab bar (the chrome with tabs + window controls). Motivation: on laptops, vertical space is scarce — giving the tab bar back to the content when agents are running matters.

Three states:
1. **Full** — current behavior. Tabs and chrome fully visible.
2. **Shrunk** — chrome collapses down to a small handle anchored in the top-right corner. The handle shows an expand arrow pointing left ('chrome lives out that way — click to bring it back').
3. **Hidden** — chrome fully gone. Reveal mechanism TBD (menu command + keyboard shortcut minimum; the shrunk handle's expand-left arrow is the visual pattern to mirror for any persistent reveal affordance).

Open questions:
- Exact placement and styling of the shrunk-state handle; expand-left chevron in light and dark theme slots.
- From hidden, what's the path back? Menu + shortcut minimum; optional: persistent reveal zone at top edge on hover.
- Interaction with the sidebar footer (jump-to-unread lives there now) — companion affordance for 'collapse sidebar too' so both dismiss together on small laptops?
- Persistence: per-window, per-workspace, or global preference?
