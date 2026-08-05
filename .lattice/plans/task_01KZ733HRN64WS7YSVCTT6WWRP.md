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

---

# PLAN (agent:c11-192, 2026-08-04; revised 2026-08-04 by agent:trident-pane-C11-192 per trident review `notes/trident-review-C11-192-plan-pack-20260804-1618/`)

## Finding: the premise above does not hold

I pulled all 875 events of Sentry issue C11-31 and classified each event's
**wedged main-thread stack** (`extra.stack`, what the watchdog actually captured):

| what main was blocked on | events | % |
|---|---:|---:|
| SwiftUI / AttributeGraph graph work | 559 | 63.9% |
| other compute | 133 | 15.2% |
| synchronous XPC/IPC wait | 96 | 11.0% |
| **Swift generic metadata instantiation (the stack above)** | **50** | **5.7%** |
| file I/O syscall | 15 | 1.7% |
| unclassified `mach_msg` | 12 | 1.4% |
| lock / semaphore wait | 10 | 1.1% |

**How to read this table (limits of the sample).** These are *per-capture*
counts under the pre-#401 reporting regime: every 875 events predate the
per-episode throttle (`reportedCurrentEpisode`, `42ce4c919`), so long episodes
re-sent every 5 seconds and the table is duration-weighted, not
episode-weighted. One user contributed 816 of 875 events; the other six
contributed 59. And the capture that reaches Sentry is systematically the
*persist* capture ~7s into a wedge (detect threshold 2000ms, Sentry threshold
5000ms, recapture interval 5000ms — the first capture is always below the
Sentry threshold), so the table measures *what stays wedged*, not *what
wedges*. It is therefore evidence that multiple distinct wedge classes exist,
and it is **not** a basis for prioritizing between them. Rework: recompute per
episode (dedupe by user + episode, or exclude `recapture == true`) and per
distinct user, and report distinct-user counts alongside every row — in
particular the per-user spread of the 50 generic-metadata captures, which
decides whether that class is the smallest or the most widespread
(see C11-196). The refutation below stands on the two arguments that do not
need the table.

Root cause of the misattribution: `attachStacktrace = true` makes the Cocoa SDK
attach the *capturing* thread's stack, and Sentry fingerprints a message event on
that stack. Hang reports are captured on `com.stage11.c11.hang-monitor`, whose
stack is byte-identical every time — so every main-thread hang, whatever wedged
main, groups into one issue, titled after whichever event was latest. Verified:
every event's `current: true` thread is the watchdog.

Also: no metadata-stack event names a `Button` c11 owns — there is no specific
expensive `Button` to restructure. These two facts (the grouping mechanism and
the absence of any c11-owned Button) are the load-bearing refutation.

**Number discipline.** The table's 50 is the classifier's generic-metadata
bucket (needle match within the 16-frame cause window); 24 of 875 (2.7%) is the
strict count of events whose stack contains the demangler symbols verbatim.
Commit `93e655929`'s message says 58, which matches neither definition — the PR
description must carry a correction note stating the two real definitions and
their counts.

**Reconciliation with C11-191 (unresolved, and it matters).** The sibling plan
reports 9,433 of 20,778 *local* captures wedged on `__ulock_wait2` (9,413 with
`GhosttyNSView.attachSurface` at frame 1, one episode 13h58m). This table puts
`lock-wait` at 10 events, 1.1%. Same watchdog, same era. The likeliest
reconciliation is that Sentry systematically under-samples the worst wedges — a
permanently wedged process never flushes its transport — which would mean any
Sentry-side trend is measured through a sensor that is blindest exactly where
damage is worst. This is currently *unknown*, it bounds what the Acceptance
section's trends can claim, and it is why the local hang log (see Work item 5)
is part of this change rather than an afterthought.

## Scope change (requires ticket-owner sign-off — flagged needs_human)

This plan supersedes the ticket's original acceptance. C11-192 was filed as
"remove a proven generic-metadata layout stall, verified by a Time Profiler
trace." The evidence above shows that premise was an artifact of Sentry
grouping: the layout pass named in the title was never established as the cause
of the 875 events, and there is no c11-owned Button to restructure. The work
becomes: make hang reports separable by cause, so that each wedge class gets
its own issue, user count, and trend.

Disposition of the ticket identity (title, branch name `c11-192-button-metadata`,
and PR #402 currently describe three different things) is an operator call —
options: (a) retitle C11-192 to the classifier work, (b) close C11-192 as
invalid and move the work under a new ID, (c) split: keep C11-192 as the
performance question (now C11-196) and re-home this telemetry work. The
needs_human flag on this task carries the question. Until answered, work
proceeds on PR #402 under this ticket.

## Work

All code lives on branch `c11-192-button-metadata` (PR #402). Files touched:
`Sources/MainThreadHangMonitor.swift`, `Sources/SentryHelper.swift`,
`c11Tests/MainThreadHangDetectorTests.swift`. Items marked **[rework]** are not
yet on the branch and are required before re-review.

1. **`MainThreadHangSignature`** (pure enum, `Sources/MainThreadHangMonitor.swift`)
   parses `backtrace_symbols` lines and classifies the wedged stack.

   *Parsing.* `backtrace_symbols` emits `"%-4d%-35s 0x%016lx %s + %lu"`. The
   load address (`0x`-prefixed token) is the only reliable delimiter because
   image names may contain spaces (`c11 DEV`); the trailing `+ <offset>` is
   stripped as per-build noise. Unparseable lines are dropped; a stack with
   zero parseable frames classifies `cause = "unknown"`.

   *Cause vocabulary and precedence* (first match wins; needle-substring match
   over the symbol field within a 16-frame leaf window — `causeWindow = 16`):

   | order | cause | rule |
   |---|---|---|
   | 1 | `xpc-sync-wait` | any of `_dispatch_mach_send_and_wait_for_reply`, `xpc_connection_send_message_with_reply_sync`, `CFXPCSendMessageWithReply` |
   | 2 | `lock-wait` | any of `psynch_mutexwait`, `psynch_cvwait`, `semaphore_wait`, `semaphore_timedwait`, `ulock_wait`, `_pthread_cond_wait` |
   | 3 | `generic-metadata` | any of `swift_getTypeByMangledName`, `_gatherGenericParameters`, `swift_getOpaqueTypeMetadata`, `instantiateGenericMetadata`, `_swift_getGenericMetadata`, `MetadataCacheKey` |
   | 4 | `runloop-idle` | leaf frame contains `mach_msg2_trap` AND window contains `CFRunLoopServiceMachPort` |
   | 5 | `swiftui-update` | any module in the first 8 frames (`moduleWindow = 8`) ∈ {SwiftUI, SwiftUICore, AttributeGraph} |
   | 6 | `appkit` | any module in the first 8 frames ∈ {AppKit, QuartzCore, CoreGraphics, CoreText, HIToolbox} |
   | 7 | `other` | none of the above |

   Blocking waits outrank the libraries that issued them by design: a thread
   parked in a semaphore is a lock problem regardless of the frames above it.

   *Phase vocabulary* (computed only when `cause == "swiftui-update"`; first
   match over the whole stack, most specific first): `hosting-begin-transaction`
   (`NSHostingViewC16beginTransaction`), `hosting-layout`
   (`NSHostingViewC6layout`), `display-list-render`
   (`ViewGraphRootValueUpdaterPAAE6render`), `preferences`
   (`updatePreferences`), `nsview-layout` (`_layoutSubtreeWithOldSize`), `menu`
   (`NSMenu`). **[rework]** When no rule matches, emit `phase = "none"`
   explicitly (tag present, value `none`) instead of omitting the tag — the
   no-phase rate is the rot alarm for these Apple-private-symbol needles (see
   Classifier health).

   *Culprit.* Deepest frame whose module equals `ProcessInfo.processName`,
   skipping `main`. Mangled; consumers run `swift demangle`.

   *Contradictory or degenerate stacks* route to the stable buckets above
   (`unknown` / `other`); the classifier must never mint a per-frame
   fingerprint.

2. **`sentryCaptureWarning`/`sentryCaptureError`** gain optional
   `fingerprint: [String]?` and `tags: [String: String]?` (default nil — all
   existing call sites unchanged). The scope sets the explicit fingerprint when
   given one; tag values are capped at 190 chars (Sentry rejects, not
   truncates, over-limit values).

3. **`MainThreadHangMonitor.reportTelemetry`** fingerprints on the wedged stack
   and sets the tags below. The message becomes
   `"main thread hang (<cause>[/<phase>])"` so an issue title names its cause;
   `stalled_ms` stays in the event context.

   *Fingerprint (wire format — see stability contract).* **[rework]** Versioned:
   `["main-thread-hang", "v1", cause, phase?]` plus tag
   `hang.signature_version = "v1"`. The currently shipped form omits the
   version element; add it before merge, because these strings are permanent
   grouping keys: adding a phase rule splits an existing issue and strands its
   history, renaming a cause orphans its trend. Taxonomy changes are deliberate
   version bumps; Sentry issue merging is the migration tool. This contract is
   also stated as a comment above the rule tables in source. **[rework]**

   *Tag policy.* Tags are bounded, facetable dimensions; unbounded evidence
   lives in event context.

   | field | surface | bound |
   |---|---|---|
   | `hang.cause` | tag | closed vocabulary (7 values) |
   | `hang.phase` | tag | closed vocabulary (6 values + `none`) |
   | `hang.signature_version` | tag | closed vocabulary **[rework]** |
   | `hang.culprit` | tag, ≤190 chars | **[rework]** full untruncated value duplicated into event context `data` (a truncated mangled name does not demangle — the tag naming c11's own code must stay readable somewhere) |
   | `hang.top_symbol` | tag, ≤190 chars | **[rework]** unresolved address-only frames must NOT become tag values (per-launch addresses mint unbounded cardinality); emit sentinel `unresolved` and keep the raw frame in context |
   | `hang.recapture` | tag | note: under the current thresholds the Sentry-reported capture is nearly always the persist capture, so this tag is near-constant `"true"`; its purpose is trend-splitting if thresholds ever change. If that isn't wanted, drop it. |
   | `stalled_ms`, full stack | context only | never tags |

   *Privacy.* Symbol names leave the machine only under
   `TelemetrySettings.enabledForCurrentLaunch`, same as every Sentry payload.
   Residual exposure: mangled c11 symbol names (including unreleased feature
   names) become searchable strings in a third-party service; accepted, noted.

   *Threading.* Classification is bounded string work over ≤96 frames and runs
   on the watchdog thread inside `reportTelemetry`, off main — consistent with
   the socket-command threading policy. No typing-latency path is touched.

4. **Tests** — `MainThreadHangSignatureTests` test class, currently appended to
   `c11Tests/MainThreadHangDetectorTests.swift`, which is a member of the
   **`c11LogicTests`** target despite living in `c11Tests/` on disk. That
   disk/target mismatch is the C11-105 failure pattern; it is harmless here (no
   socket state) but must be stated, not discovered. **[rework]** Either move
   the class to its own file `c11Tests/MainThreadHangSignatureTests.swift` (kept
   in the `c11LogicTests` target, with a comment naming the mismatch) or add
   that comment where it sits. Coverage: parsing (incl. space-bearing module
   names), every cause rule and its precedence, phase narrowing, culprit
   extraction, degenerate captures — plus the fixtures under Verification.

5. **[rework] Local hang log classification.** Call
   `MainThreadHangSignature.describe` from `handleHang` for *every* capture
   (not only the Sentry-gated one) and append `cause=` / `phase=` / `culprit=`
   to the local hang-log header line. ~3 lines. This makes
   `grep 'cause=lock-wait' ~/Library/Logs/c11/hang.log` a real triage command
   with full untruncated frames and no consent gate, and it is the only path
   that sees the wedges Sentry structurally misses (see the C11-191
   reconciliation above).

Grouping is deliberately coarse, and the plan records the considered range —
see Alternatives considered.

## Non-goals

No view-tree restructuring, and no claim that a metadata hang was fixed —
explicitly: no `ContentView.swift` or other view-tree work is in scope. 10422ms
is the stall duration at the moment of a single sample, not time spent in the
sampled frame. Whether generic-metadata instantiation is worth attacking is
C11-196's question, answerable once this change ships.

## Alternatives considered

- **Server-side Sentry fingerprint rules** — editable without a release, and
  could have reclassified the 875 held events to validate the taxonomy before
  shipping code. Rejected because the wedged stack is a context string
  (`extra.stack`), not a structured stacktrace, so server rules cannot reach
  it. (That limitation is itself an argument for fixing the event *shape* —
  synthesizing a `threads` payload with the wedged main marked `current: true`
  — which would make Sentry's own grouper and display correct and the
  hand-rolled classifier optional. Surfaced to the operator as review item S4;
  not chosen here.)
- **Medium-granularity fingerprint `[cause, phase, culprit-module]`** — more
  issues, each more specific. Rejected: `culprit` has 114 distinct values over
  the corpus and belongs as a facetable tag inside a coarse issue, not as a
  group splitter.
- **Fingerprint on top-N frames** — over the same 875 reports a top-5-frame
  fingerprint gives 645 groups (607 singletons). Rejected as the other endpoint
  of the spectrum.
- **Fix only `attachStacktrace` / display, leave grouping to Sentry** —
  rejected: Sentry's default grouper on message events is what produced the
  single-issue collapse being fixed.

## `attachStacktrace` remains on — the misleading display survives this change

`Sources/AppDelegate.swift:2615` still sets `attachStacktrace = true`, and the
unused `beforeSend` hook sits at `:2623`. The new per-cause issues will
therefore still *render* the watchdog's stack in Sentry's primary stack-trace
panel, with the real wedged stack demoted to a context string — the exact
presentation that caused this ticket to be filed against a nonexistent Button.
The same defect applies to every message event captured from a fixed-shape
worker thread (other `sentryCaptureError` call sites included). Fixing the
display (strip in `beforeSend` for `category: "hang"` vs synthesize a `threads`
payload) is a design call surfaced to the operator (review items I4/S4); it is
deliberately not scoped into PR #402. Until it lands, every hang issue's stack
panel is decoration: read `hang.*` tags and the context stack instead.

## Verification

**Reproducibility [rework].** The 875-event analysis currently exists only in
the authoring agent's session. Commit: (a) a redacted fixture corpus
`c11Tests/Fixtures/hang-stacks.jsonl` (verbatim `extra.stack` values from the
`0.58.0+116` events; redaction rule: drop user-identifying paths, keep frames);
(b) the replay harness that runs the classifier over it; (c) a distribution
test asserting bands, not point values — no stack with parseable frames
classifies `unknown`; `swiftui-update` within a stated band; total distinct
fingerprints within a stated band (guards both collapse-to-one and
explosion-into-singletons). CI's `build` job (compile + logic tests) runs it.

**Ground-truth fixture [rework].** Add a `lock-wait` fixture built from a
verbatim C11-191 `attachSurface` / `__ulock_wait2` capture out of
`~/Library/Logs/c11/hang.log` and assert it classifies `lock-wait` with
`culprit` naming `attachSurface`. This is the one classification with
independently proven ground truth (C11-191's disassembly work); if it does not
come out `lock-wait`, that is a classifier bug.

**Real-artifact validation [rework — merge gate].** Offline replay proves the
classifier is a function; nothing yet proves Sentry honors any of it ("green
tests ≠ working product"). On a tagged build: induce a main-thread stall past
the 5000ms Sentry threshold (temporary debug hook or a `sleep` behind a debug
menu item — see review item E2 for making this a permanent reusable gate),
with telemetry consent on, then confirm **in the Sentry UI**: the event's
title names the cause; the explicit fingerprint took (event landed in a new
per-cause issue, not C11-31); all `hang.*` tags survived ingestion and are
facetable; a second induced hang with a different cause lands in a *different*
issue. Screenshot both issues and attach to PR #402.

**Existing offline result (to be superseded by the committed replay):** the
classifier over all 875 production stacks produces 13 issues from 1;
`hang.culprit` lands on 172 reports naming 114 distinct c11 symbols.

## Classifier health

The phase needles match Apple private symbols; macOS updates will rot them
silently — `phase` drops to `none`, the fingerprint changes, history forks, and
the dashboard reads as "hangs fixed." Contract: the metrics to watch are the
rate of `unknown` + `other` (baseline ~16.6% combined on the corpus), the rate
of `swiftui-update` with `phase = none`, and `hang.culprit` coverage (baseline
172/875 ≈ 20%). If `phase = none` exceeds half of `swiftui-update` events, or
`unknown`+`other` doubles against baseline, the taxonomy has rotted: bump the
signature version with corrected needles. Owner: the recurring Sentry audit
(agent:sentry-audit) checks these on each sweep.

## Rollout

Landing this forks Sentry history: C11-30/C11-31 go quiet and new per-cause
issues appear. That silence is expected, not a fix. On the first post-merge
release: annotate-and-resolve the old issues with a pointer to this plan, audit
any alert rules/saved searches keyed to them, and treat trend comparisons
across the taxonomy boundary as invalid.

## Acceptance (amended — supersedes the original; see Scope change)

The original acceptance ("a profile showing `swift_getTypeByMangledName` absent
from the layout pass") cannot be met, because the layout pass it names was never
established as the cause of the 875 events.

**Merge gates (all must pass before PR #402 merges):**
1. Committed corpus replay test green with asserted distribution bands (above).
2. C11-191 ground-truth `lock-wait` fixture green.
3. Real-artifact Sentry validation screenshots attached to the PR (above).

**Post-release gate** — owner: **agent:sentry-audit**, window: **14 days** after
the first release carrying this change: ≥90% of hang events classify into a
named cause (not `unknown`/`other`); `generic-metadata` and the
`swiftui-update/*` phases exist as distinct Sentry issues with independent
distinct-user counts; the per-bucket weekly event volume is recorded on
C11-196 (post-#401 throttling may starve trends — that projection is review
item S7 and decides whether trend-based verdicts are achievable at all). If
the ≥90% bar fails, this ticket reopens.

## Follow-ups (filed)

- **C11-193** — synchronous XPC/AppleEvents wedge class (96 captures, up to 604s).
- **C11-194** — SwiftUI graph-work family: split `hosting-begin-transaction` vs
  `hosting-layout`, attack the dominant phase (C11-191 is in this family).
- **C11-195** — decide whether `runloop-idle` captures should report at all.
- **C11-196** — is generic-metadata a real user-facing class; owns the per-user
  recount of the 50-capture bucket and the post-classifier trend verdict.

## Rework checklist for PR #402 (delta between plan and branch)

1. Version the fingerprint (`"v1"` element) + `hang.signature_version` tag +
   wire-format comment above the rule tables. (I1)
2. Emit `phase = "none"` explicitly when no phase rule matches. (M3)
3. `hang.top_symbol`: sentinel for unresolved address-only frames;
   `hang.culprit`: full value duplicated into context. (I5)
4. Classify every capture into the local hang log header in `handleHang`. (EW1)
5. Commit fixture corpus + replay harness + distribution test. (I2)
6. Add the C11-191 `lock-wait` ground-truth fixture. (I3)
7. Move/annotate `MainThreadHangSignatureTests` re: disk/target mismatch. (M2)
8. Run the real-artifact Sentry validation; attach screenshots. (B3)
9. Add PR-description note correcting commit `93e655929`'s "58" (definitions:
   50 = classifier bucket, 24 = strict demangler-symbol count). (M1)
10. Recompute the distribution per-episode and per-user; update the Finding
    table or confirm its per-capture labeling stands. (B4)

PR: https://github.com/Stage-11-Agentics/c11/pull/402

## Reset 2026-08-04 by agent:trident-pane-C11-192
