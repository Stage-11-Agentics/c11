# Evolutionary review — C11-185

PLAN_ID: `c11-185-plan`  
MODEL: `Codex`

### Executive Summary

The largest opportunity is to turn C11-185 from a tooltip feature into c11's first explicit **temporal truth model for a surface**: one immutable, provenance-aware packet explaining what lifecycle c11 presents, when that presentation's trustworthy boundary began, when c11 last observed activity, when the logical surface was created, and which attention modifiers apply.

The six-step plan points in the right architectural direction. It preserves the existing lifecycle pipeline, proposes one shared projection, keeps date formatting out of typing-hot views, persists logical creation time, respects the Bonsplit boundary, and includes the right release gates. But it is not yet execution-grade for this contract. A competent implementer can begin it, but would still have to invent three load-bearing decisions:

1. which unread notification defines a continuous waiting epoch;
2. how a top-tab tooltip refreshes on hover when `BonsplitTabActivityPresentation` is an immutable value;
3. how full lifecycle help replaces, rather than duplicates, Bonsplit's existing default accessibility value.

The plan should evolve from six broad work buckets into a data-first sequence with a written timestamp-source table, a temporal refresh design, a logical-identity persistence audit, and renderer-specific accessibility gates. This is refinement within the locked scope, not a request to enlarge the product.

### What's Really Being Built

At its core, C11-185 is building a **surface activity truth packet**:

```text
existing liveness + unread epoch + attention + panel identity
                              |
                              v
                  SurfaceActivityTruth
        presented lifecycle / state boundary / last activity
          logical creation / flag reason+age / suppression
                              |
                 +------------+------------+
                 |            |            |
                 v            v            v
             top mark    sidebar marks   Surface Details
```

That packet is more important than any individual tooltip. Today:

- `WorkspacePulseAgent` carries lifecycle and attention modifiers but no temporal payload.
- `TerminalNotificationStore.NotificationIndexes` can answer exact-surface unread membership but exposes no exact-surface waiting epoch.
- `BonsplitTabActivityPresentation` carries an immutable accessibility string, while Bonsplit's `TabItemView` separately appends its default lifecycle value.
- `SurfaceManifestSnapshot.capture` contains metadata and capture time only.
- `Panel` has no logical creation-time contract, while `SessionPanelSnapshot` already provides the natural persistence envelope.

C11-185 connects those islands. Done well, Surface Details becomes an explanation of the same truth rendered compactly elsewhere—not a fourth state derivation and not a metadata dump with extra dates.

### How It Could Be Better

#### 1. Separate temporal truth from localized text

Do not make the shared projection merely a preformatted tooltip `String`. That string becomes stale and makes hover-time refresh difficult. Use two layers:

- `SurfaceActivityTruth`: immutable semantic data, with presented lifecycle, optional state boundary, optional last activity, optional logical creation time, flag reason/raised time, and suppression.
- `SurfaceActivityText`: a pure formatter taking that truth plus an injected `now`, producing the primary lifecycle line, modifier lines, accessibility value, absolute timestamp display, and unambiguous copy value.

`WorkspacePulseAgent` should carry the semantic payload. Surface Details should capture the same payload. The Bonsplit adapter should receive generic temporal help data derived from it—not an independently inferred state.

This split gives tests fixed dates and makes the equality boundary explicit. It also prevents a coarse clock tick from rebuilding the entire equatable sidebar row merely to age one string.

#### 2. Pre-register the timestamp-source table

The plan should state the exact rules before implementation:

| Presented lifecycle | Trustworthy boundary |
|---|---|
| Working | latest c11-observed lifecycle or input boundary from `SurfaceActivityTracker` |
| Idle | latest c11-observed lifecycle or input boundary from `SurfaceActivityTracker` |
| Cold | `lastActivityAt + SidebarAgentColdSettings.thresholdSeconds()` |
| Waiting | beginning of the current exact-surface unread epoch |
| Any state without evidence | `nil`; render the localized state alone |

Suppression must be applied before selecting the duration source: raw waiting + suppressed + unflagged presents as idle and therefore uses activity evidence, not the hidden notification timestamp. Flagged + suppressed preserves waiting and may use its unread epoch.

The current notification index records membership, not time. Add one pure index/projection for the exact surface's waiting boundary. The most coherent default is the **oldest currently unread, signal-eligible exact-surface notification**, because waiting began there and remains continuous until the surface has no qualifying unread record. Using the newest record would silently reset “Waiting for…” while the state never left waiting. If the product wants newest instead, the plan must say so explicitly.

Also settle whether lifecycle transitions bypass `SurfaceActivityTracker`'s 250 ms first-write-wins debounce. Minute-scale UI makes the difference small, but fixed-clock boundary tests and the word “accurate” deserve an intentional rule.

#### 3. Design refresh behavior, not just formatting

The locked contract says tooltip text refreshes on hover entry. An immutable precomputed `helpText` in `BonsplitTabActivityPresentation` cannot guarantee that.

A stronger Bonsplit seam is a generic, Codable temporal help payload: host-supplied localized undated text/format templates and modifier lines plus an optional boundary date. Bonsplit can sample `Date()` only when the padded mark enters hover and render the supplied presentation without learning what “flagged,” “suppressed,” or “waiting” mean. The sidebar mark leaves can do the same from `SurfaceActivityTruth`. Surface Details can observe the existing 30-second `SidebarDecayClock` while its window is visible.

That yields:

- no per-agent timers;
- exact hover-entry refresh;
- bounded visible-window aging;
- no metadata, notification, or tracker reads inside either hot tab body;
- no parent-row invalidation on every relative-time tick.

The plan should explicitly reject a cached final string as insufficient.

#### 4. Make accessibility precedence explicit

The top tab currently composes `activityPresentation.accessibilityValue` and Bonsplit's default lifecycle value. If c11 supplies “Idle for 7 minutes, Flagged: …” and Bonsplit then appends “Idle,” VoiceOver duplicates the lifecycle.

Add a generic precedence rule: a host-supplied complete activity accessibility presentation replaces the default activity value; ordinary tabs with no complete presentation retain Bonsplit's localized default. Test normal and collapsed/overflow tab renderers. In the sidebar summary row, expose the mark semantics once on the actionable row; in the census row, expose them once on the standalone mark. Keep the decorative shape itself hidden from accessibility.

This turns “same semantic order” into an executable contract instead of a reviewer judgment.

#### 5. Treat `createdAt` as logical identity, not constructor convenience

Add optional `createdAt` to `Panel` and all three implementations. Fresh logical surfaces get `Date()` once. Restore passes `snapshot.createdAt` verbatim, including `nil` for legacy snapshots. `SessionPanelSnapshot` gets optional `created_at` and explicit backward-compatible coding.

The plan should audit constructors by semantic category:

- initial workspace surface;
- terminal/browser/markdown split and new-surface paths;
- placeholder and last-panel replacement paths;
- session restore for all three panel types;
- detach/transfer and any same-identity reattachment path;
- browser reopen, with an explicit call whether reopening creates a new logical surface.

The invariant should be simple: **same logical surface identity preserves its date; a genuinely new surface identity gets a new date; missing legacy provenance remains nil.**

For Surface Details, add one structured capture seam that reads panel creation time, the shared activity truth, and metadata independently. Do not make the SwiftUI view rediscover a `Workspace` through globals. Refresh should recapture absolute truth; the leaf clock should only advance display ages.

The plan also needs the details-row obligations it currently compresses away:

- Activity, Created, Last activity, and Captured remain distinct;
- timestamps include timezone;
- Created and Last activity remain selectable;
- copied values use an unambiguous offset-bearing form;
- `Not recorded` is localized and is not converted into a fake date;
- non-agent/browser/markdown Activity and Last activity behavior is explicitly defined.

### Mutations and Wild Ideas

These are follow-ups unlocked by the model, not scope additions for C11-185:

1. **“Why this mark?” provenance.** Surface Details could later show the source of the current projection: lifecycle edge at T, unread record at T, or cold threshold crossed at T. That would turn intermittent liveness bugs into inspectable evidence.
2. **Age-aware attention routing.** Once waiting has a stable epoch, a future queue could prioritize the oldest operator demand without changing mark semantics.
3. **Surface restore forensics.** Created / Last activity / Captured forms a useful temporal triplet for distinguishing a restored but dormant surface from one newly created after relaunch.
4. **A read-only agent-facing truth seam.** A future CLI/events follow-up could expose the same packet so agents can explain visible state without scraping UI. The ticket correctly excludes adding that API now.
5. **Epoch history, only if demanded.** If operators later need “how long was this agent waiting over the day?”, the present snapshot can evolve into bounded activity epochs. Do not start that event history in this ticket.

The important mutation is conceptual: stop treating relative time as copy glued to a glyph; treat it as a projection over trustworthy temporal evidence.

### What It Unlocks

Shipping the temporal truth packet creates leverage beyond the immediate UI:

- Renderer agreement becomes testable as equality over one payload and one clock instant.
- Surface Details becomes the authoritative debugging surface for marks.
- Restored surfaces gain honest provenance instead of app-launch-time fiction.
- Future lifecycle or attention states can add one source rule and inherit all three renderers.
- Waiting age becomes stable enough for future prioritization, analytics, or event output.
- Localization work compounds because state/duration/modifier composition is centralized.
- Bonsplit gains a generic host-supplied temporal-help primitive that can be offered upstream without importing c11 policy.

### Sequencing and Compounding

The optimal sequence is:

1. **Freeze temporal semantics.** Write the timestamp-source table, decide the unread epoch, define missing/future-date behavior, and create fixed-clock test fixtures.
2. **Build the semantic packet and formatter.** Cover every lifecycle × flag × suppression combination, cold threshold arithmetic, missing evidence, and token-safe localized duration composition.
3. **Add persistent logical creation.** Wire all three panel types and snapshot decoding/encoding; prove fresh, restored, and legacy behavior before UI work.
4. **Make Surface Details the first vertical slice.** It exposes the full packet and is the easiest place to compare Activity, Created, Last activity, and Captured at one injected instant.
5. **Wire the two sidebar mark locations.** Carry immutable truth through `WorkspacePulseAgent`; add leaf-only hover refresh and accessibility without changing `TabItemView`'s equality/hot-path contract.
6. **Extend Bonsplit generically.** Add temporal help, accessibility precedence, and normal/collapsed renderer tests. Commit and push Bonsplit `main`, verify reachability, then commit the parent pointer.
7. **Freeze English and translate.** Run the required fresh-surface six-locale pass across both c11 and Bonsplit catalogs; validate JSON/catalogs and interpolation tokens.
8. **Review and validate.** Run focused safe tests/builds, exact scoped diff and submodule checks, one substantive review/fix/re-review budget, then—only after separately recorded approval—tagged hover/details validation and draft PR handoff.

This order makes each stage an oracle for the next. Details proves the model; sidebar proves host rendering; Bonsplit proves the cross-module adapter. Localization happens only after all copy shapes stop moving.

### The Flywheel

The flywheel is:

```text
one temporal source table
    -> one truth packet
    -> shared fixed-clock fixtures
    -> renderer agreement tests
    -> fewer divergent bugs
    -> more confidence adding provenance
    -> a stronger truth packet
```

The small change that starts it is making renderer tests consume the same fixture. For a fixed surface, notification set, threshold, and `now`, assert:

- the sidebar tooltip text;
- the top-tab generic help/accessibility output;
- the Surface Details Activity line

all agree. Then separately test each renderer's actual attachment/hit area. That combination catches both semantic drift and UI wiring failures.

### Concrete Suggestions

1. Replace plan step 2 with named semantic and formatting types plus the timestamp-source table.
2. Add a pure exact-surface unread-epoch builder to `TerminalNotificationStore` rather than scanning notifications from a view.
3. Carry semantic dates in `WorkspacePulseAgent`; never cache only the final relative string there.
4. Define a generic Bonsplit temporal-help payload that can refresh at hover entry, and make complete host accessibility replace the default lifecycle value.
5. Add `createdAt: Date?` to `Panel`; default fresh initializers to a new date and pass restore values—including nil—explicitly.
6. Introduce a structured Surface Details capture service/value containing metadata, activity truth, creation time, last activity, and capture time as separate fields.
7. Use `SidebarDecayClock` only in small visible leaves such as the open Details timing group; do not observe it from the equatable sidebar row or Bonsplit tab row.
8. Expand tests to cover all three panel kinds, multiple unread notifications, waiting epoch reset after the last unread clears, exact cold-threshold crossing, future/invalid timestamps, timezone-bearing copy values, accessibility non-duplication, and tooltip attachment to the padded mark rather than the row or composition rail.
9. Add an explicit constructor/identity audit checklist and a submodule call-site audit for normal plus collapsed Bonsplit tab marks.
10. Keep the wild ideas above as follow-up candidates. Do not add tool-call observation, activity history, new socket fields, or a Surface Details redesign to this ticket.

### Questions for the Plan Author

1. Does a continuous waiting duration begin at the oldest currently unread exact-surface notification, or reset to the newest unread notification?
2. Should lifecycle-transition writes bypass `SurfaceActivityTracker`'s 250 ms debounce so the boundary is exact in tests and rapid transitions?
3. For browser, markdown, and non-agent terminal surfaces, should Surface Details show Activity and Last activity as `Not recorded`, or is there another existing truth source the contract intends to expose?
4. Is a reopened closed browser a new logical surface with a new Created time, or should reopening preserve the closed surface's original logical creation?
5. What is the required copy representation for absolute timestamps: localized display plus ISO 8601 with numeric UTC offset, or one shared format?
6. Should flag age be deliberately omitted from v1 copy while retaining `flagRaisedAt` in the semantic packet?
7. Must the generic Bonsplit tooltip cover collapsed/overflow representations of an individual surface tab as well as the visible horizontal tab strip?
8. Is exact hover-entry refresh mandatory for the first frame of the native tooltip, or is the existing 30-second shared-clock granularity acceptable? The locked wording currently implies exact hover-entry refresh.

