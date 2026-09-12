# C11-208: Split the xpc-sync-wait bucket on 'c11 frame present' so it measures something we own

FOUND BY. C11-196, whose written acceptance criterion turned out to be unmeetable by fixing c11 code. This ticket inherits that measurement question.

THE PROBLEM. Of the 82 xpc-sync-wait captures in the pre-classifier corpus (C11-30 + C11-31, 6 distinct users, four clusters), exactly ONE carries a c11 frame. The other 81 are the OS blocking c11's main thread with no c11 frame present: LaunchServices notification deliveries into an idle runloop (59 captures, one user, max 142,654 ms) and RunningBoard rbs_acquire_appnap_assertion via CFRunLoopSetOptionsReason (12 captures, 5 users). We cannot fix those by changing our code, so the bucket's headline numbers cannot move no matter how much sync XPC we remove from main. C11-196's clause 'no capture exceeds 10s in that bucket' was therefore void on arrival, and any future release-over-release read of this bucket will be dominated by noise we do not control.

WORK. Teach the xpc-sync-wait rule in Sources/MainThreadHangMonitor.swift to distinguish the two populations, the same way C11-198/PR #413 split runloop-idle on the -[NSApplication run] frame. The natural discriminator is whether any frame in the capture belongs to the app's own module. Suggested shape: keep xpc-sync-wait for captures with a c11 frame, and give the system-owned deliveries their own cause or phase so they group separately in Sentry.

CAVEAT WORTH CHECKING FIRST. Shipped releases send only stack.prefix(24) on the wire, and the 81 system-owned captures bottom out in the event loop before a c11 frame could appear within that window. So 'no c11 frame in the first 24' may be indistinguishable from 'c11 frame deeper than 24'. Verify against the local hang log, which holds full 96-frame captures, before trusting the discriminator. If it does not separate cleanly, say so and close rather than shipping a rule that mislabels.

ACCEPTANCE. Either a validated discriminator with the same rigor #413 applied to runloop-idle (present on all of one population, absent from all of the other, stated over a named capture count), plus the code change and behavioral tests; or a recorded finding that the two populations are not separable within the 24-frame wire budget, with the evidence.

RELATION. Successor to C11-196's acceptance clause, which is declared void on that ticket. Sibling in method to C11-198/#413.
