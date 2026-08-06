# C11-200: ghostty_surface_set_display_id deadlocks the main thread permanently (fixed in #403, split from C11-191)

Split out of C11-191 by operator decision on 2026-08-06.

WHAT IT IS. ghostty_surface_set_display_id pushed .forever into a 64-slot renderer mailbox from the main thread. When the mailbox is full the main thread blocks with no timeout and never recovers: force-quit only. Observed locally as a single pid wedged 13h58m with a __ulock_wait2 leaf.

WHY IT IS NOT C11-191. Four of nine Trident reviewers established that the Sentry issue behind C11-191 (com.stage11.c11@0.58.0+116, bounded ~2335ms, no libsystem_kernel leaf, 11+ users) cannot be this deadlock: a futex block always shows a libsystem_kernel leaf, and the profiles mismatch on build, duration, and population. C11-191 stays pointed at the tab-bar preference-pass signature.

RESOLUTION. Fixed by PR #403, merged 2026-08-06 as 8c7422b4f. Filed as done for the record so the fix has an owning ticket.
