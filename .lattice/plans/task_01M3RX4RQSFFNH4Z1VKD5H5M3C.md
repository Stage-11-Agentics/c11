# C11-245 plan

Operator approved the prototype. Implement it, with Undo.

## Tip

A non-modal popover under the count cell of the area the operator is looking at, and only while that area is overflowing (scrolling strip, or the solid block). Same anchor for both. Copy teaches the count cell's tab list and Tab Layout: Rail, with a miniature rail preview (mark, title, status word, no clocks).

Actions:

- Try Rail: set `tabLayoutMode` to `rail` for every area and open this area's rail. The popover stays up and becomes Undo. Undo puts Tabs back everywhere, closes the popover, and is not a dismissal. It does not clear `lastOffered`.
- Show tab list: open this area's existing tab sheet. The tip steps aside, then returns with the "that list is the number" copy. Not a dismissal.
- Don't show again: the only action that sets `dismissed`. Layout stays Tabs.

Leaving the tip alone (click outside or Escape) records the offer and waits 30 days. It does not set `dismissed`. The tip does not take terminal keyboard focus.

`dismissed` is set only by Don't show again. Try Rail, Undo, Settings to Rail, and switching back to Tabs do not set it. Layout Rail hides the teaching tip while it is on. That is separate from dismissal.

## Trigger

An overflow day is a local calendar day on which any area's strip scrolled or folded. A blip under 2 seconds does not count. One mark per day, one defaults write per day.

Offer when all of these hold:

- 4 overflow days fall inside the last 14 calendar days (today and the 13 days before it).
- Tab Layout is still Tabs.
- The tip is not dismissed.
- At least 30 calendar days since `lastOffered` (a missing stamp may offer).
- The focused area of the front workspace is overflowing now.

`shouldOffer` means a new offer may start. The host keeps the live showing, including while the sheet is open or the area briefly stops overflowing.

## Storage and structure

User defaults only, same domain as `tabLayoutMode`. Keys: `c11.tabRailTip.overflowDays`, `c11.tabRailTip.lastOffered`, `c11.tabRailTip.dismissed`. Not written to logs, health, or the socket.

The predicate is a pure model with an injected calendar and defaults store, tested in `c11LogicTests`. Overflow and the count-cell view are reported by bonsplit (edge-triggered). The bonsplit change is its own PR; this branch pins that SHA until it is on bonsplit main.

English strings only, via `String(localized:defaultValue:)`. No local app launch. CI compiles and runs the logic tests.
