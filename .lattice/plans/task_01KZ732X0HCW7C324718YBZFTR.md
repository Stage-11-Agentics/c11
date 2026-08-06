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

---

# PLAN (agent:c11-191, 2026-08-04)

## Correction to the ticket's reading

The ticket reads the Sentry stack as "the tab bar's SwiftUI preference pass". That reading does
not survive contact with the evidence.

The Sentry payload is a `backtrace_symbols()` string dump, symbolicated on-device by nearest
exported symbol. For c11's own (mostly non-exported) Swift frames that lookup drifts, which is
why the quoted stack contains an impossible frame: `Foundation.URL? outlined copy` at frame 4
*calling* `ExclusiveGesture` at frame 3. Outlined copy helpers are leaves; they call nothing.
The c11-binary symbol names in that stack are therefore not trustworthy. Module attribution is.

The operator's own machine carries 151 MB of `~/Library/Logs/c11/hang.log` -- same watchdog,
same records, but locally symbolicated and untruncated (Jun 15 - Aug 4, 59 pids, 5001 episodes,
20778 captures with frames). One signature dominates:

- 9433 captures wedged with leaf `__ulock_wait2`
- 9413 of those with frame 1 = `GhosttyNSView.attachSurface`, frame 2 = `GhosttyTerminalView.updateNSView`
- Framing caveat (trident review, 2026-08-04): ~9412 of those captures come from a single pid
  (6063) in a single ~14h episode -- the persist-sampling watchdog makes capture counts a
  *duration* metric, not a frequency metric. Counted by episode, `attachSurface` appears in
  ~8-11 of ~5004 episodes (~0.2%), vs ~32 for `TabBarView` and ~232 for `updatePreferences`.
  The honest framing is **rare and catastrophic** (unbounded, force-quit-only), not "dominant".
- outer frames: `GraphHost.updatePreferences -> AGGraphGetWeakValue -> AG::Graph::value_ref ->
  update_attribute -> UpdateStack::update -> <SwiftUICore AttributeGraph rule>` -- position for
  position the same fingerprint the ticket quotes for Sentry frames 16-21.

## Root cause (disassembly-verified)

Every wedged sample sits at `attachSurface + 372`. Disassembling the installed release binary:

    0000000100307154  bl _$s3c1115TerminalSurfaceC31reconcileAttachedWindowIfNeeded3foryAA13GhosttyNSViewC_tF
    0000000100307158  ; == attachSurface + 372  (the recorded return address)
    0000000100307164  bl _$s3c1115TerminalSurfaceC25setKeyboardCopyModeActiveyySbF
    0000000100307168  ; == attachSurface + 388  (matches the +388 frames in the same log)

`reconcileAttachedWindowIfNeeded(for:)`'s only blocking primitive is
`ghostty_surface_set_display_id`, which in `ghostty/src/apprt/embedded.zig` is:

    _ = surface.renderer_thread.mailbox.push(.{ .macos_display_id = display_id }, .{ .forever = {} });
    surface.renderer_thread.wakeup.notify() catch {};

The renderer mailbox is a `BlockingQueue(Message, 64)`. A `.forever` push on a full queue waits
on `cond_not_full` -> futex -> `__ulock_wait2`. The notify happens *after* the push, so a full
queue plus a sleeping/wedged renderer thread is a permanent deadlock of the **main thread**.

Observed: pid 6063, 2026-07-29 02:18 -> 16:16 UTC. **13h58m wedged**, 9412 consecutive persist
captures, no `hang.end`.

Why the mailbox fills: `updateNSView` calls `hostedView.attachSurface(...)` on **every** SwiftUI
update, and both `attachToView`'s reuse branch and `reconcileAttachedWindowIfNeeded` re-push the
display id unconditionally. 64 slots do not last long once the renderer stops draining.

## Fix

1. **c11** -- stop re-asserting an unchanged display id from the two per-`updateNSView` sites.
   Memoised `TerminalSurface.setDisplayID(_:force:)`; hot sites pass `force: false`, every
   deliberate unstick-vsync site (`createSurface`, focus, topology churn, `viewDidMoveToWindow`,
   `windowDidChangeScreen`) keeps `force: true`, because `renderer.setMacOSDisplayID`
   intentionally restarts the display link on a re-assert. Memo resets on surface create/destroy.

2. **ghostty fork** -- `ghostty_surface_set_display_id` must never block its caller. Ordering:
   push `.instant` first, then notify (the wakeup is a coalescing `xev.Async`; notify-then-push
   is a lost-wakeup race -- renderer can wake, drain, and park before the push lands). Full-mailbox
   handling must NOT be silent log-and-drop: see the B1 delivery-contract requirement in the
   review findings below. Land the change in `Stage-11-Agentics/ghostty` and flag it to the
   operator with a one-line note so they decide whether/how to offer it upstream (standing rule:
   no direct pushes/PRs against `manaflow-ai/*`).

## Evidence / measurement

- Before: the hang log above (root cause proven by disassembly, not inference).
- Deterministic: `c11LogicTests` behavioural test over the memo seam -- N update cycles issue 1
  push instead of N, every `force: true` site still pushes.
- Real artifact: tagged build, count `macos_display_id` pushes per session before/after.

---

# REVIEW FINDINGS -- trident plan review, 2026-08-04 (FAIL plan-level: rework-then-rereview)

Full action contract: `notes/trident-review-C11-191-plan-pack-20260804-1613/synthesis-action.md`
(attached to the ticket). Mechanical corrections (B2 notify ordering, I2 episode framing, M1
upstream routing) are already applied above. The rework below is the plan author's to do; the
blocker IDs reference the action synthesis.

**Blocking design work (must be resolved in the reworked plan):**

- **B1 (raised by all 9 reviewers):** memo-on-attempt + drop-on-full permanently strands a stale
  display link (`ghostty_surface_set_display_id` returns `void`; `setMacOSDisplayID` also has two
  silent early-return paths). The plan must state an explicit delivery contract -- caller never
  waits, latest valid ID eventually applies, memo advances only on renderer-accepted state.
  Reviewer-preferred mechanism: a coalesced latest-value slot (atomic + dirty flag) consumed on
  drain; alternatives in the synthesis. Choose and argue one.
- **B3:** enumerate all 9 `ghostty_surface_set_display_id` call sites with per-site `force`
  values and the invariant each protects; make the raw FFI binding private to the policy helper.
- **B4:** state explicitly how PR #12's split-churn frozen-terminal fix survives de-forcing the
  `attachToView` reuse branch; validate with `scripts/repro-c11-18.sh` + tagged-build screenshot.
- **B5:** add a Zig-level queue-full test (fill mailbox, call export, assert no block + latest ID
  applied on drain) and a debug fault-injection switch -- the ghostty half currently has no test.
- **B6:** write a falsifiable acceptance section (episode-counted hang.log oracle, the B5 test as
  CI gate, named Sentry cohort/window/re-open trigger); if the ticket's repro AC is waived, say so.
- **B7:** add the cross-repo sequence: fork branch -> push `Stage-11-Agentics/ghostty` -> ancestry
  check -> parent pointer -> `build-ghosttykit` checksum (run-1-red/run-2-green is expected).
- **I1:** `ghostty_surface_set_focus` / `set_occlusion` push `.forever` into the same mailbox from
  main (7 call sites; occlusion has no dedupe guard). Extend the fix to the class or explicitly
  scope it out with a filed follow-up -- do not imply main is safe.
- **I3/I4/I5/I6, M2/M3:** memo lifecycle state machine; reorder ghostty-first and require both
  halves in one release; reconcile with `notes/BUG-main-thread-deadlock-attachSurface.md`
  (Futex.Deadline = condvar, not mutex) and answer why the renderer stopped draining for 14h;
  name a pure AppKit-free test seam; specify measurement counters and drop-logging policy; record
  disassembly provenance (binary path/UUID/offset procedure) and the frame-pointer gap.

**Blocked on operator (needs-human, S1):** whether this plan is fixing C11-191 at all. The Sentry
stack has no `libsystem_kernel` leaf (a futex block always does); the TabBarView preference-storm
signature exists locally symbolicated in ~32 episodes across 10+ pids; profiles mismatch on
build/duration/population. Decisive sub-hour check: resolve one real 0.58.0+116 Sentry event's
frame-0 offset the same way the plan resolved `attachSurface + 372`. Three reviewers recommend
splitting: file the deadlock as its own P0 and keep C11-191 on the Sentry signature (candidate
root cause located: `vendor/bonsplit .../TabBarView.swift` 730-749/794-809 unguarded
`onPreferenceChange` -> `@State` -> `.frame(width:)` feedback loop). Do not resume rework until
S1 is answered -- it determines the ticket's scope and acceptance criteria.

## Reset 2026-08-04 by agent:trident-pane-C11-191
