# C11-205: Generic-metadata instantiation hangs: 13 of 20 users, 4.6s median stall

FOUND BY. C11-199's offline reclassification of the complete pre-classifier hang corpus: all 4,763 events of Sentry issues C11-30 and C11-31, 20 distinct users, 32 device hashes, 2026-07-25 to 2026-08-10. Events were classified by a faithful Python port of MainThreadHangSignature's rules as shipped (exact, not approximate: shipped releases send stack.prefix(24) contiguous, and causeWindow=16 / moduleWindow=8 both fit inside that).

EVIDENCE. generic-metadata is 273 events from 13 of 20 distinct users, 43 user-days, 151 episodes across 11 users. The known outlier user (52.6 percent of the whole corpus) contributes 175; twelve other users contribute 98, and nine users have 2 or more, so it is not a one-off per person. Concentration index 1.22 against a corpus baseline of 1.0, versus xpc-sync-wait at 1.74, which is what a genuinely single-machine class looks like. Its 5.7 percent volume share badly understates its reach.

SEVERITY. Median stall 4,566 ms, p90 25.3 s, 49.3 percent of captures at or above 5 s. Second-highest median of any cause. Current, not historical: 54 events from 7 users on 0.61.0, the latest public release, through 2026-08-10. Reprojected into the post-#401 episode-only shape it still runs at 65 episodes per week from 11 users, so the C11-192 review's S7 worry about throttling starving the trend is not supported.

SHAPE. All six cause needles fire (MetadataCacheKey 302, swift_getTypeByMangledName 202, _swift_getGenericMetadata 177, and the rest). Leaf symbols are Swift runtime metadata-cache lookup, not one pathological call site, so expect this to be a generics-heavy type instantiated on a hot path rather than a single bad call.

WORK. Time Profiler on the running app to find which c11 type instantiation drives the metadata cache misses on main. Likely suspects are deeply generic SwiftUI view types in the hot render paths (tab bar, sidebar, split chrome) where the metadata cache is cold at first instantiation. Fix by reducing generic nesting, pre-warming, or type-erasing the offending path.

ACCEPTANCE. A Time Profiler trace naming the concrete c11 type or view path responsible, a fix, and a measurable drop in generic-metadata episode rate for the affected users on the following release.

RELATION. Spun out of the C11-199 spike, which answered the per-user-spread half of its question and parked the post-classifier-trend half (blocked on 0.63.0 reaching users). This ticket owns the fix; C11-199 owns the trend verdict.
