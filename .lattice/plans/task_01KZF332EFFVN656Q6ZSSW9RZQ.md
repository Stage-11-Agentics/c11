# C11-202: SwiftUI update/layout passes wedge main for 2.5-3s (28% of hang episodes, 39 pids)

The real user-visible main-thread freeze, once C11-191 stripped the noise off the aggregate hang
issue.

Re-classifying the operator's local hang log (21,192 captures / 5,311 episodes / 63 pids,
2026-06-15 to 2026-08-06) with the shipped `MainThreadHangSignature` rules:

| bucket | episodes | share | pids | detect median |
|---|---|---|---|---|
| `swiftui-update/hosting-begin-transaction` | 776 | 14.6% | 38 | 2788 ms |
| `swiftui-update/hosting-layout` | 546 | 10.3% | 39 | 2534 ms |
| `swiftui-update` (unphased) | 176 | 3.3% | 30 | 2546 ms |
| `generic-metadata` | 131 | 2.5% | 28 | 2510 ms |

28.2% of all episodes, on 38-39 distinct processes. Real episode length (from `hang.end`): median
6.7 s, p90 49 s. This is the freeze a human actually feels.

WHAT THE STACKS SAY. Main is inside `NSHostingView.layout()` or the SwiftUI run-loop-observer
transaction flush, burning CPU in AttributeGraph and the Swift runtime rather than blocked. The
frame-0 distribution over 1,046 busy production events on 0.58.0+116:

  AttributeGraph  UpdateStack::update 63, Subgraph::update 39, propagate_dirty 32,
                  LayoutDescriptor::Compare 13, AGGraphSetOutputValue 11
  libswiftCore    swift_retain 45, MetadataCacheKey::operator== 20, getCache 16,
                  swift_release 14, ConcurrentReadableHashMap::find 17,
                  getGenericMetadata 7, getAssociatedTypeWitness 7,
                  getTypeByMangledNameInEnvironment / _swift_getKeyPath

Hot generic-metadata cache lookups and keypath resolution are the signature of very large nested
generic view types being re-resolved over and over. c11 has them: the `VerticalTabsSidebar.body`
mangled name in these captures is thousands of characters
(`ScrollView<VStack<LazyVStack<ForEach<..., EquatableView<TabItemView>>>>>` under a stack of
background/overlay/frame modifiers). `AG::Graph::propagate_dirty` and `Subgraph::update` being hot
says the graph is large and broadly invalidated per pass.

WHY IT IS NOT ALREADY FIXED. ~84% of these episodes have no c11 frame on the captured stack at
all, so no single view can be named from the field data as it stands. C11-191 (#411) is the
prerequisite: it appends the own-module frames from below the top window, so the next release's
events name the subtree. Do not start guessing before that data exists.

APPROACH.
  1. Wait for a release carrying #402 + #411, then read `hang.culprit` on the `swiftui-update/*`
     issues. That is the whole point of #411.
  2. In parallel, reproduce locally: many workspaces x many tabs x many surfaces, tagged build,
     Instruments (SwiftUI + Time Profiler) or `sample` against the running process. The goal is a
     >1s pass on demand.
  3. Likely fix directions, in order of evidence: shrink the sidebar/tab-strip view graph
     (hoisting deeply chained modifiers into small `View` structs so the generic types stop being
     enormous), verify structural identity is stable across updates so subtrees are not torn down
     and rebuilt, and confirm the `TabItemView` `Equatable` + `.equatable()` guard still holds at
     the container level (CLAUDE.md documents it as a typing-latency hot path).

ACCEPTANCE. A reproduction that stalls main >1s before the change and does not after, plus the
`swiftui-update/*` Sentry buckets falling on the following release at comparable install count.

FOUND BY. C11-191's identification pass, 2026-08-06/07. Related: C11-191 (evidence quality),
C11-192 (per-cause fingerprinting), C11-186 (hang survivability), C11-200 (the separate
`ghostty_surface_set_display_id` deadlock).
