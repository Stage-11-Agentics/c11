# C11-191: Main thread wedges ~2.3s in the tab bar's SwiftUI preference pass (941 Sentry events, 11 users)

The single highest-volume issue on c11's Sentry project. 941 events across 11 distinct users in one day (2026-07-25), all on release com.stage11.c11@0.58.0+116, environment production. Sentry issue C11-30, "main thread hang 2335ms".

STACK (from the hang watchdog's cross-thread capture; frames 0-21 of the wedged main thread):

  0  c11              MiddleClickCapture...
  1  SwiftUICore      _SizedShape
  2  SwiftUICore      ExclusiveGesture
  3  SwiftUICore      ExclusiveGesture
  4  c11              Foundation.URL? outlined copy
  5  c11              Bonsplit.TabBarView.horizontal...
  6  SwiftUI          ScrollViewReader.body
  7  SwiftUICore      DelayedPreferenceChild
  8  SwiftUICore      AttributeGraph.syncMainIfReferences
 ...
 17  AttributeGraph   AG::Graph::UpdateStack::update
 21  SwiftUICore      GraphHost.updatePreferences

READING. Main is inside a SwiftUI preference-key update pass (GraphHost.updatePreferences -> DelayedPreferenceChild -> syncMainIfReferences) driven from Bonsplit's TabBarView horizontal scroll body, with MiddleClickCapture and ExclusiveGesture in the evaluated subtree. `syncMainIfReferences` in an AttributeGraph update is the SwiftUI shape that blocks the main thread while resolving references; a 2.3s stall there means the tab bar's preference/ScrollViewReader machinery is re-evaluating a large subtree synchronously.

WHY IT MATTERS BEYOND THE STALL. CLAUDE.md already names TabItemView as a typing-latency hot path guarded by Equatable + .equatable() precisely so its body is not re-evaluated during typing. This stack is that guard failing (or being bypassed) at the container level: the cost is in TabBarView's own preference/gesture plumbing rather than in TabItemView's body. 11 of the operator base hit it in a single day.

WHERE TO LOOK.
  - vendor/bonsplit TabBarView horizontal scroll container: the ScrollViewReader + preference-key pair.
  - MiddleClickCapture's placement in that subtree — a gesture/NSViewRepresentable in a preference-writing branch forces re-evaluation.
  - The `Foundation.URL?` outlined copy at frame 4 suggests a URL-carrying value is being copied per tab per pass; a URL in a preference payload or Equatable key is worth ruling out.

ACCEPTANCE. A reproduction (many tabs + tab bar interaction) that stalls main >1s before the change and does not after; the Sentry issue does not recur on the next release with comparable install count. Note the outbound Sentry budget landed in #401, so recurrence now shows as fewer events, not zero: judge by issue presence and user count, not event count.

FOUND BY. Sentry audit 2026-08-04. Related: C11-186 (make main-thread hangs survivable) covers reporting/recovery for hangs in general; this ticket is one specific cause.
