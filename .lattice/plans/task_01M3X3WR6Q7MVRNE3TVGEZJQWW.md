# C11-265 just-in-time implementation

Retain the stored cut line on base bc915d0509 (C11-263/264/274 merged).

1. Add pure AttentionOrder: flags oldest raised time, then eligible open blocking asks oldest opened time; missing times last, then tab UUID / workspace UUID. Feed all appends turns. Keep one row per exact target and flag+ask counted once.
2. Cache/publish Feed's ordered immutable snapshot on its existing worker queue. Jump uses that prefix, then a derived oldest-first eligible unread notification cache (exact tab targets, deterministic notification tie, dedup, no workspace-only substitution). Revalidate exact ownership before focus; share resolver with feed.open; only successful unread-tail focus marks its notification read. No shortcut/default changes.
3. Menu extra subscribes to the Feed projection via its existing coalesced main refresh. Show separate flag/open-ask/unread counts, explicit zero attention, preserve violet flags and unread 9+ badge and existing notification rows. Updates do not activate c11. Localize new English strings only; source skill ordering contract updated without installed sync.
4. Behavioral tests: ordering/ties/missing times, suppression override, count semantics, stale target walker, unread tail/dedup, publication/removal, menu refresh, shortcut preservation. Atlas-only builds/tests, one c11-265 tag. Record base and changed timings/load for equivalent checks.
5. Atlas disposable primary guest computer-use: real configured shortcut follows flags/asks/unread tail; inspect menu counts, zero state, violet flag; Finder remains frontmost during updates. Capture screenshots, exact-head artifacts, cleanup lease. No local UI/builds.
6. Commit, push only at handoff, draft PR, Lattice validation/status review and HANDOFF C11-265 REVIEW. C11-266 waits for NEXT.

New English localized keys: statusMenu.attention.none (No flags · no open asks), statusMenu.attention.flags.one (1 flag), statusMenu.attention.flags.other (%lld flags), statusMenu.attention.asks.one (1 open ask), statusMenu.attention.asks.other (%lld open asks). Six locales deferred to C11-291 by go-owner. Source skill edits are not synced on this seat.
