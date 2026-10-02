# C11-310: Measure the sidebar before changing it

## Why
The sidebar rebuilds every workspace and tab on the main thread, and that pattern is present in the code. There is no c11 measurement that says it is the stall. Ruling D21 says measure first and do not rewrite the sidebar. Backlog item: B059.

## Evidence
origin/main `0ff8887e5e`.

- Fable located the parent body at `Sources/ContentView.swift:8535-8600` on this SHA: each pass walks workspaces and tabs and reads the metadata store, unread counts, and attention state from the body.
- Astra held the same shape and called it fan-out, not by itself a deadlock.
- The only measured hang stacks the audits trust are the 2026-08-25 surface teardown join and the 2026-08-12 browser await pump. The SwiftUI hangs in C11-197, C11-202, and C11-205 do not yet name this body as the culprit.
- D21 and F2: the 40-agent soak (C11-270) measures the sidebar. No separate rewrite. `BACKLOG.md` puts D21 under Out as "sidebar rewrite."
- Research: Fable §5 wave 5 and §9 item 8. `05-bug-reconciled.md` tiers B059 as gated.

## Scope
In, only if the C11-270 soak convicts the sidebar (a registered budget miss whose top Swift frames are this sidebar body):
- Publish an immutable snapshot into the existing SwiftUI sidebar so the body does not read the metadata queue. This is the narrow change. It is not an AppKit rewrite. Upstream's AppKit sidebar (#8270) is out.
- Ride-alongs, same sidebar, only in that case: B001 (`DispatchWorkItem` stored in `@State` at `ContentView.swift:1492` and the capturing item near 1882), B029 (row `GeometryReader` writes height into `@State` and feeds the drop delegate), B043 (notification churn invalidates the whole sidebar), B060 (`LazyVStack` plus drag invalidation), B188 (per-row `@AppStorage` and a full workspace scan inside each row).

If the soak does not convict the sidebar: no code change. Close this ticket with the measurement attached. The ride-alongs stay unfixed.

Out:
- A sidebar rewrite, a new sidebar framework, or "while we are here" visual redesign.
- Workspace groups. That is another workstream (C11-259, C11-260). Do not block groups on this ticket, and do not fold group UI into this fix.
- GPU reclaim (D22). The soak measures it. It is not this ticket.
- Mount cap (B012), ticks (B030), titles (B061), layout flush (B056). Those producers land whether or not the sidebar is convicted.
- Parked B184 (sidebar controls using a stale global window). Re-check only if you are already editing that control and the soak convicted you to be here.
- `TabItemView`'s `Equatable` and `.equatable()`. Do not add `@EnvironmentObject` or a new `@ObservedObject` without updating `==`. Do not read `tabManager` or the notification store in that body. Use the precomputed values.

## Approach
Do nothing until C11-270 has a baseline and a verdict. The verdict is a short note on this ticket: convicted or not, with the frame and the budget. If convicted, add a snapshot type the body reads, refreshed off the body when the underlying stores change, coalesced. Keep row identity stable so SwiftUI does not rebuild every row on each keystroke.

## Acceptance criteria
1. This ticket's first result is the soak verdict, posted here, pointing at the C11-270 artifact. No Swift diff before that.
2. If not convicted: the ticket closes with that note and an empty code diff.
3. If convicted: a tagged build at the same 40-workspace shape no longer shows this sidebar body as the top Swift frame for that budget miss. Typing in a terminal does not rebuild sidebar rows. The row height, the drag target, and the context menu still work.
4. Ride-alongs are fixed only in the convicted case, and each one has a behavioral check, not a source-text check.

## Validation
The soak is C11-270, on Atlas, after C11-216. Computer use after a convicted fix: scroll the sidebar, drag a row, open a context menu, and type in a terminal while the sidebar is visible. No Hyperion build. No source-grep test. Do not start a local 40-agent soak on this machine.

## Dependencies
Cross-workstream: F2 is C11-270, and F1 is C11-216 under it. The lead links those. No ws:bugs ticket blocks this. The producer tickets should land first so the soak is not measuring bugs that already have a fix. That is an ordering note, not a link that prevents filing.

## Risks
Typing latency if the snapshot is rebuilt on every keystroke or if `TabItemView` loses `Equatable`. Main thread if the snapshot is computed inside `body`. Doctrine: no tenant config. Any new label uses `String(localized:)` and the translation ticket. Public repo: a measurement gate, not a hang recipe.

Size: L. Tier: P2. Doctrine check: no code unless the soak convicts the sidebar. No rewrite.

