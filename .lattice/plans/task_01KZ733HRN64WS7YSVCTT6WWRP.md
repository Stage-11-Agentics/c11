# C11-192: Main thread wedges 10s in swift_getTypeByMangledName under SwiftUI.Button.body (875 Sentry events, 7 users)

Second-highest-volume issue on c11's Sentry project and the longest stall: 875 events across 7 distinct users in one day (2026-07-25), all on release com.stage11.c11@0.58.0+116, environment production. Sentry issue C11-31, "main thread hang 10422ms (persist)".

STACK (wedged main thread, frames 0-21):

  0  libswiftCore  _gatherGenericParameters
  1  libswiftCore  DecodedMetadataBuilder::createBoundGenericType
  2  libswiftCore  swift::Demangle::TypeDecoder
  3  libswiftCore  swift_getTypeByMangledNodeImpl
  4  libswiftCore  swift_getTypeByMangledNode
  5  libswiftCore  swift_getTypeByMangledNameImpl
  6  libswiftCore  swift_getTypeByMangledName
  7  libswiftCore  swift_getOpaqueTypeMetadataImpl
  8  SwiftUI       Button.body
  9  SwiftUICore   ViewBodyAccessor.updateBody
 ...
 17  SwiftUICore   GraphHost.runTransaction
 18  SwiftUICore   GraphHost.flushTransactions
 21  SwiftUI       NSHostingView.layout

READING. Main is inside the Swift runtime instantiating generic type metadata by demangling a mangled name, reached from an opaque return type (`some View`) on a Button's body, during an NSHostingView layout pass. This is the well-known cost of very deeply nested generic SwiftUI view trees: each distinct `some View` opaque type must have its metadata built at runtime, the demangler walks the whole nested generic structure, and the cache misses on first use. Ten seconds means the tree under that Button is enormous — likely a modifier chain multiplied across a ForEach.

This is a different mechanism from the 2.3s tab bar stall (see the sibling ticket) even though both surface as "main thread hang": that one is preference/AttributeGraph work, this one is runtime metadata instantiation. They need different fixes.

WHERE TO LOOK.
  - Find the Button whose body is that deep. `NSHostingView.layout` plus a Button in the graph points at chrome hosted in AppKit: tab bar, sidebar rows, or panel toolbars.
  - The standard remedies, in order of bluntness: break the modifier chain with explicit `AnyView` at the deepest point (trades metadata cost for erasure), factor the subtree into a named `struct` conforming to `View` with a concrete body type, or hoist the repeated modifier stack out of a ForEach so one metadata instantiation serves every row.
  - Verify with a Time Profiler trace filtered to `swift_getTypeByMangledName`; the fix is confirmed when that symbol stops appearing in layout passes.

WHY IT MATTERS. Ten seconds is a beachball, not a stutter, and 7 users hit it. It is also self-inflicted and fixable purely by view-tree shape: no concurrency, no locking, no ghostty involvement.

ACCEPTANCE. A profile showing `swift_getTypeByMangledName` absent from (or under 100ms in) the layout pass that previously showed it; the Sentry issue does not recur on the next release with comparable install count. The outbound Sentry budget landed in #401, so judge recurrence by issue presence and user count, not event count.

FOUND BY. Sentry audit 2026-08-04. Related: C11-186 (make main-thread hangs survivable) covers reporting/recovery in general; this is one specific cause.
