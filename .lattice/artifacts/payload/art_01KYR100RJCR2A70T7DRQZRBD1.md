# Action-Ready Synthesis: c11-185-plan

Synthesized from the 9 per-agent reviews in this pack, cross-checked against
`.lattice/plans/task_01KYQYND86DZMKGR58BJ4Y3R53.md` (the 6-line plan) and
`context-task-spec.md` (the locked C11-185 contract). Code claims below were
independently verified in the working tree; verification notes are inline.

## Verdict

**rework-then-rereview**

All nine reviewers independently concluded the plan is not executable as written.
No reviewer said plan-ready. Verdicts ranged from "needs revision, not
rethinking" (standard/claude, standard/codex, standard/gemini, adversarial/codex)
to "the plan is not wrong, it is absent" (adversarial/claude). Both evolutionary
Claude and Codex called it "not yet execution-grade."

The disagreement is only about magnitude, and it resolves cautiously: the plan's
**architecture is affirmed by all nine** (one shared projection consumed by both
tooltip and Surface Details; no lifecycle re-inference; structured details capture
kept out of `SurfaceMetadataStore`; Bonsplit stays generic; submodule before
parent pointer; `pr_open` not merge). What is missing is the entire decision
layer: six of the eight blockers below are load-bearing technical choices the
plan never makes, and three of them do not have a data source in the codebase
today. That is more than a copy-edit pass, and several reviewers noted the same
structural consequence: with a plan this thin, the downstream review gate has no
baseline to review against.

Re-review after rework can be scoped and light (verify the blockers are resolved
with named mechanisms, not re-litigate architecture).

---

## Apply by default

### Blockers (plan is not yet executable as written)

- **B1: No source exists for the presented-state start time, and no step creates one**
  - Where in the plan: step 2 ("one pure c11 activity-help projection"), step 4
    ("state-start arithmetic"); contract "Duration semantics" and AC2.
  - Problem: `Workspace.derivedActivityBySurface` is `[UUID: SidebarActivityState]`
    (verified, `Sources/Workspace.swift:5503`), a bare enum with no entry
    timestamp; `coldAgentSurfaceIds` is a bare `Set<UUID>` (`:5509`);
    `SurfaceActivityTracker` stores one continuously-overwritten `lastActivity`
    per surface with a 250 ms leading-edge debounce (verified,
    `Sources/Conversation/SurfaceActivity.swift:31-66`). It is a last-touch clock,
    not a state-start clock. Nothing in steps 1 to 3 produces a trustworthy
    state-start. Consequence: `Working for 2 minutes` (the ticket's own first
    example) has no input, and using `lastActivity` as a state-start makes an
    idle tooltip reset to the banned `0 minutes` on a single keystroke.
  - Revision: add an explicit timestamp-source matrix to the plan, one row per
    presented state (working, idle, cold, waiting, suppressed-waiting-presented-as-idle,
    flagged+suppressed, no-evidence), naming the exact accessor for each and the
    fallback when it is absent. Decide and record how state-start is obtained:
    the recommended route across reviewers is stamping a `stateEnteredAt` at the
    presented-state transition edge (beside the existing changed/unchanged branch
    in `setDerivedActivity`, `Workspace.swift:7160-7167`), with reconstruction
    from `lastActivity` / `lastActivity + threshold` / notification `createdAt`
    demoted to fallback. The plan must also state explicitly that recording *when*
    inference changed is **not** "changing lifecycle inference," so step 1's fence
    does not read as forbidding the one change the feature needs.
  - Sources: standard/claude (weakness 1, "the single most important gap"),
    standard/codex (weakness 6), adversarial/claude (B1, assumption 1),
    adversarial/codex (blind spot 1), adversarial/gemini (assumption audit),
    evolutionary/claude (suggestion 2), evolutionary/codex (section 2).

- **B2: Formatted duration strings must not cross into Equatable hot-path payloads**
  - Where in the plan: step 2, "precompute it for top tabs and `WorkspacePulseAgent`".
  - Problem: verified `TabItemView.==` includes `lhs.workspacePulse == rhs.workspacePulse`
    (`Sources/ContentView.swift:11745`), and `WorkspacePulseSummary` holds
    `agents: [WorkspacePulseAgent]` (`Sources/Sidebar/SidebarActivityProjector.swift:25`).
    A rendered duration inside `WorkspacePulseAgent` flips that equality on every
    minute boundary for every workspace row with an agent, defeating the
    `.equatable()` typing-latency defense CLAUDE.md names as load-bearing. The
    same shape applies to `BonsplitTabActivityPresentation` (verified `Codable,
    Equatable, Hashable`, `vendor/bonsplit/.../BonsplitActivityAnimationClock.swift:19`),
    where a minute-cadence change produces a real `Tab` mutation and tab-bar diff,
    and serializes localized product copy into Bonsplit's persisted layout.
  - Revision: state the churn boundary as an explicit invariant in the plan:
    stable `Date?` / enum / bool values cross into `WorkspacePulseAgent` and
    `BonsplitTabActivityPresentation`; localized strings are composed at the leaf.
    Add the negative rule: no time-derived or formatted field may be added to any
    type reachable from `TabItemView.==` or from the Bonsplit presentation value.
  - Sources: standard/claude (weakness 2), standard/codex (exec summary, weakness 1),
    standard/gemini (weaknesses), adversarial/claude (challenged decision 1),
    adversarial/codex (challenged decisions), adversarial/gemini (challenged
    decisions, "the fatal flaw"), evolutionary/claude (section 1 problem A),
    evolutionary/codex (section 1), evolutionary/gemini (sequencing).

- **B3: The hover-refresh mechanism is never named, and the obvious one cannot do it**
  - Where in the plan: step 2 ("attach native help"); contract guardrail "Refresh
    tooltip copy on hover entry"; AC5 (tooltip and Surface Details agree at the
    same clock instant).
  - Problem: SwiftUI `.help(_:)` takes a `String` evaluated at body-build time and
    has no hover-time callback, so "refresh on hover entry" is not achievable with
    it alone. The escape routes each violate a different stated constraint, and
    the plan picks none, which means the mechanism gets chosen at the keyboard.
    Relevant verified constraints: `vendor/bonsplit/.../SafeTooltip.swift` records
    that an AppKit `addToolTip` on a click-through view whose `hitTest` returns nil
    "silently never appeared," and that `.help` on the view itself is what works;
    `SidebarDecayClock` is a 30 s shared clock whose own doc comment forbids
    observation from `TabItemView`'s body (`Sources/SidebarDecayClock.swift:1-28`).
  - Revision: name one mechanism per consumer (top-tab mark, sidebar summary mark,
    sidebar census mark, open Surface Details) and record, in one line each, the
    constraint being relaxed and why it is acceptable. The plan must show that the
    chosen set satisfies simultaneously: no per-agent repeating timer, no store
    read or date formatting in `TabItemView` body or `WindowTerminalHostView.hitTest()`,
    no parent-row invalidation on a clock tick, and AC5 agreement at one instant.
    (See S2 for the mechanism fork itself, which is an operator/author call.)
  - Sources: all nine. standard/claude (weakness 4), standard/codex (weakness 1, 5),
    standard/gemini (weaknesses, alternatives), adversarial/claude (assumption 4,
    challenged decision 2), adversarial/codex (blind spot 3), adversarial/gemini
    (exec summary), evolutionary/claude (section 1 problem B),
    evolutionary/codex (section 3), evolutionary/gemini (concrete suggestions).

- **B4: Surface Details cannot obtain the promised truth, and Refresh cannot re-read it**
  - Where in the plan: step 3, "capture structured Activity/Created/Last activity
    data for Surface Details separately from metadata JSON"; contract "Refresh
    rereads absolute activity truth"; AC5.
  - Problem: verified `SurfaceManifestSnapshot` carries only `metadata`, `sources`,
    `capturedAt`, and `capture(workspaceId:surfaceId:)` reads only
    `SurfaceMetadataStore.shared` (`Sources/SurfaceManifestView.swift:39-47`). It
    has no panel reference, no tracker read, no notification read. `refresh()`
    reassigns only `snapshot` (`:422-424`), so anything placed on the
    window-construction-time `let handle: SurfaceHandleInfo` (`:65`) is
    structurally unrefreshable and the contract line fails silently.
  - Revision: specify that the activity/timing facts live on
    `SurfaceManifestSnapshot` (a sibling of `metadata`/`sources`, not inside the
    metadata JSON, and not on `handle`), and name the injectable provider that
    `capture` calls to collect panel `createdAt`, tracker last activity, the shared
    activity projection, and the exact waiting evidence. State that `refresh()`
    reruns that same provider, and keep the provider injectable so AC5 can be
    asserted at a fixed `now` in a pure test.
  - Sources: standard/claude (structure hole, question 9), standard/codex
    (exec summary 3, weakness 4), adversarial/claude (assumption 5, challenged
    decision 4), adversarial/codex (blind spot 4), evolutionary/codex (section 5),
    standard/gemini (question 3).

- **B5: The Bonsplit accessibility seam is additive today, so the new copy will duplicate lifecycle**
  - Where in the plan: architecture item 4, step 2, step 4 ("Bonsplit
    help/accessibility rendering"); contract "VoiceOver receives lifecycle,
    duration, modifiers, and flag reason in the same semantic order as the tooltip,
    without duplicating values already exposed by the tab."
  - Problem: Bonsplit composes the host `accessibilityValue` and then appends its
    own derived lifecycle value, and separately applies
    `TabActivityAccessibility.help(for:)` as `.accessibilityHint` (verified
    `vendor/bonsplit/.../TabBarView.swift:1085`, `:1208`; presentation carries only
    `accessibilityValue`, `BonsplitActivityAnimationClock.swift:19-42`). Supplying
    a complete "Idle for 7 minutes, Flagged: ..." phrase through the existing field
    yields VoiceOver saying the lifecycle twice, or saying modifiers before the
    lifecycle. The contract's "without duplicating" clause is satisfiable only
    under a supersede rule.
  - Revision: add an explicit precedence rule to the plan: when the host supplies a
    complete activity presentation, it **replaces** Bonsplit's derived activity
    value and its built-in activity hint; tabs with no host presentation keep
    Bonsplit's localized default. Say what happens to
    `TabActivityAccessibility.help(for:)` (retired, or kept as the no-presentation
    fallback). Require a Bonsplit test asserting the final combined value and its
    order, in both the normal tab renderer and the collapsed/overflow renderer,
    and that unrelated composed values (Loading, Pinned, Unread, Modified, Zoomed)
    still appear exactly once.
  - Sources: standard/claude (weakness 4), standard/codex (exec summary 2,
    weakness 3), adversarial/codex (blind spot 6, challenged decisions),
    evolutionary/claude (section 5), evolutionary/codex (section 4),
    adversarial/claude (B4, partially: see S10 for the part that is a misread).

- **B6: Step 4 instructs a local test run that a standing operator rule forbids**
  - Where in the plan: step 4, "Run focused safe logic/host tests and build checks."
  - Problem: this repo's standing rule (CLAUDE.md testing policy plus a recorded
    operator interruption on C11-181) is to defer **all** local c11 `xcodebuild`
    test actions to CI during delegator/headless runs, including the nominally safe
    `c11-logic` scheme and `scripts/test-unit-local.sh`. C11-184's plan stated this
    as a hard rule. Step 4 as written reads as permission to do the thing that was
    interrupted last time.
  - Revision: rewrite step 4's execution clause: author the coverage, use
    `xcodebuild build` / `build-for-testing` only as a compile-and-link check
    (and note that a green `build-for-testing` proves linking, not assertions),
    and let PR CI's `build` job execute the assertions. Name the prohibition
    explicitly so a fresh delegator cannot re-derive the wrong instruction.
  - Sources: standard/claude (weakness 7, question 15), adversarial/claude
    (challenged decision 7, uncomfortable truth 6). Note the disagreement:
    adversarial/codex (blind spot 7, question 17) recommends the opposite (use
    `c11-logic` for pure slices and `scripts/test-unit-local.sh` for host tests).
    The standing operator rule wins; the codex position is noted here rather than
    silently dropped.

- **B7: The Bonsplit ordering gate is missing its precondition, and the submodule is detached right now**
  - Where in the plan: step 5, "Commit and push any Bonsplit change to
    `Stage-11-Agentics/bonsplit` main before the parent pointer."
  - Problem: verified `git -C vendor/bonsplit symbolic-ref --short HEAD` fails with
    "ref HEAD is not a symbolic ref", i.e. the submodule is **detached now**. An
    implementer following step 5 verbatim commits on a detached HEAD, pushes
    nothing, and orphans the commit; the parent pointer then references an
    unreachable SHA. CLAUDE.md names this pitfall explicitly and C11-184 carried it
    as a Phase 0 gate.
  - Revision: expand step 5 into explicit sub-steps, and move the preparation
    **before the first Bonsplit edit**: `cd vendor/bonsplit && git checkout main &&
    git fetch origin && git merge --ff-only origin/main`, confirm
    `git symbolic-ref --short HEAD` is `main`, edit, commit, push, re-fetch to
    check for remote drift, verify `git merge-base --is-ancestor HEAD origin/main`,
    then commit the parent pointer.
  - Sources: standard/claude (weakness 3), standard/codex (weakness 11),
    adversarial/claude (pattern 5, uncomfortable truth 7, question 18),
    adversarial/codex (blind spot 7, challenged decisions, question 18).

- **B8: Waiting has no exact-surface timestamp accessor, and the epoch rule is undefined**
  - Where in the plan: step 2/step 4; contract "Waiting uses the exact surface
    unread-notification creation time when available"; AC2.
  - Problem: verified `TerminalNotification` carries `createdAt`
    (`Sources/TerminalNotificationStore.swift:647`) but the store exposes only
    `hasUnreadNotification(forTabId:surfaceId:)` (`:923`) for exact-surface
    membership. There is no accessor returning the matching record's `createdAt`,
    and scanning the published notification array from a renderer would violate
    the plan's own performance guardrail. Separately, with more than one unread on
    a surface, oldest vs newest is a semantic choice: newest silently resets
    "Waiting for ..." while the state never left waiting.
  - Revision: add a step that introduces a bounded, precomputed exact-surface
    waiting-boundary accessor or index on `TerminalNotificationStore`, and state the
    epoch rule in the plan. Recommended default, per the only reviewers who argued
    it: the **oldest currently-unread signal-eligible** exact-surface record, so the
    waiting epoch stays continuous until the surface has no qualifying unread; note
    the reset-on-last-clear behavior and the missing-record fallback (no duration).
    Also state that a raw-waiting surface that is suppressed and therefore presented
    as idle uses the activity boundary, not the unread timestamp.
  - Sources: standard/codex (exec summary 1, weakness 2, question 3, 4),
    adversarial/claude (B7, question 12), adversarial/codex (assumption audit,
    blind spot 1, question 8), adversarial/gemini (blind spots, question 5),
    evolutionary/codex (section 2, question 1).

### Important (revise before implementation starts)

- **I1: No step 0: no base/ancestry gate, no worktree confirmation, no provisioning**
  - Where in the plan: step 1 is behavior baselines; nothing precedes it.
  - Problem: the contract's guardrail requires implementing from an isolated
    worktree, and the primary checkout is dirty in `Sources/ContentView.swift`
    (a file this ticket must edit). A fresh worktree also cannot build until
    submodules and the `GhosttyKit.xcframework` symlink are provisioned, a
    documented CLAUDE.md pitfall that fails three times in a row for reasons that
    are not code. Reviewers also noted the branch was one to two commits behind
    `main` at review time.
  - Revision: add a step 0: confirm execution inside the C11-185 worktree, record
    the base commit and verify C11-183/C11-184 ancestry, `git submodule update
    --init --recursive ghostty vendor/bonsplit`, symlink `GhosttyKit.xcframework`
    from the main checkout, record the exact owned paths, and prove the shared
    dirty checkout is untouched.
  - Sources: standard/claude (weakness 8, recommendation 3), standard/codex
    (weakness 11), adversarial/claude (assumption 13, question 19),
    adversarial/codex (blind spot 7).

- **I2: Duration formatting and plural safety are unspecified, and `jq` cannot validate them**
  - Where in the plan: step 2 ("localized duration/modifier composition"), step 5
    ("validate catalogs/tokens"); contract "Relative duration formatting is
    locale-aware and plural-safe" plus AC10.
  - Problem: the reachable wrong answers are the easy ones.
    `RelativeDateTimeFormatter` (already used in `SurfaceManifestView`) yields
    "7 min ago", producing "Working 2 minutes ago", not a duration. A hand-rolled
    `%lld minutes` key requires xcstrings **plural variations**, and ru/uk need
    one/few/many/other categories, which `jq .` well-formedness cannot detect as
    missing. The existing `surface.flag.accessibility` key shows the
    interpolation-in-`defaultValue` style already in use here, which cannot express
    plural correctness.
  - Revision: name the formatter (reviewers converge on `DateComponentsFormatter`
    for the locale-correct duration noun phrase, composed into a
    `String(localized:defaultValue:)` sentence template), and add an explicit
    validation step beyond `jq`: assert that every locale's entry has the required
    plural categories and that every interpolation token in the English value
    survives in all six translations.
  - Sources: standard/claude (weakness 10, question 18), adversarial/claude
    (assumption 6, B10, question 10), adversarial/codex (blind spot 2, secondary
    assumptions), adversarial/gemini (uncomfortable truths), evolutionary/codex
    (section 2, suggestion 8).

- **I3: The unit ladder, rounding, and degenerate-input behavior are undefined**
  - Where in the plan: step 4 ("state-start arithmetic", "cold threshold"); contract
    bans fabricating `0 minutes` only for missing evidence.
  - Problem: what a three-second-old state displays is unspecified, and that is the
    commonest case for `working`, the state operators look at most. Also unspecified:
    floor vs nearest rounding, behavior exactly at a rollover boundary, behavior at
    the instant cold begins, and behavior for a future or clock-corrected timestamp
    (which can currently produce a negative duration).
  - Revision: state the unit ladder and rounding rule, the sub-minute presentation,
    the behavior for a real duration that rounds to zero (this is distinct from
    "no evidence"), and fail-closed behavior for negative/future timestamps. Add
    the boundary cases to the step-4 test list so they are deterministic.
  - Sources: adversarial/claude (B6, question 11), adversarial/codex (blind spot 2,
    question 7), evolutionary/codex (suggestion 8).

- **I4: The cold-start input never reaches the render site**
  - Where in the plan: step 2 precompute; contract "Cold begins when last activity
    plus `SidebarAgentColdSettings.thresholdSeconds()` is crossed. `Cold for` must
    not mean total idle time."
  - Problem: verified `SurfaceLivenessDeriver.publishCold` takes
    `observedLastTouchedAt` purely as a local staleness guard and publishes only
    `setAgentCold(Bool)` (`Sources/SurfaceLivenessDeriver.swift:295-322`), and
    `Workspace.coldAgentSurfaceIds` is a bare `Set<UUID>`. So the precompute path
    has no cold-crossing input at all. A second issue: computing cold-start as
    `lastActivity + liveThreshold` makes displayed cold duration jump retroactively
    when the operator edits the cold threshold in Settings.
  - Revision: name the value that carries cold-crossing to the render site (a
    published crossing `Date`, or the `stateEnteredAt` stamp from B1 covering cold
    as one presented state) and say which. If reconstruction from the live threshold
    is kept, state the threshold-change behavior deliberately rather than by
    accident.
  - Sources: adversarial/claude (assumption 2, question 3), adversarial/gemini
    (assumption audit, question 4), standard/gemini (weaknesses, question 4),
    evolutionary/claude (section 2, question 11), evolutionary/codex (section 2).

- **I5: `createdAt` needs a creation-path audit, an explicit-nil restore rule, and non-snapshot coverage**
  - Where in the plan: step 3 ("promote optional logical `createdAt` ... preserve it
    on terminal/browser/markdown restore while leaving legacy snapshots nil"),
    step 4 ("creation round trips, legacy decode"); AC6.
  - Problem: "optional" plus a defaulted `Date()` initializer parameter is exactly
    how a legacy restore fabricates a creation time, and a Codable round-trip test
    cannot catch it because the defect happens after decode, in the restore helper.
    The plan also names only the three primary create paths, while reviewers list
    split creation, placeholder/last-panel replacement, terminal replacement,
    browser reopen, layout-executor restore, CLI/socket creation, and
    detach/transfer. Verified: `Workspace.swift:9548-9570` has explicit detach
    handling that adds and removes `derivedActivityBySurface` / `coldAgentSurfaceIds`
    entries, so a detach path that re-mints the panel silently sets `Created` to
    "now" while AC6's tests stay green. Good news the plan can lean on: verified
    `SessionPanelSnapshot.lastActivityAt` already exists with the
    backward-compatible optional pattern (`Sources/SessionPersistence.swift:369-379`),
    so `created_at` is a copy-shaped addition.
  - Revision: add the invariant ("same logical surface identity preserves its date;
    a genuinely new surface gets a new date; missing legacy provenance stays nil"),
    enumerate every create/restore/replace/reopen/detach path and mark each as
    preserving or minting, require restore to pass the decoded value verbatim
    including explicit `nil`, and add a test that drives a legacy snapshot through
    the **real restore constructor** (not just Codable) asserting `createdAt == nil`,
    plus a detach/transfer preservation test.
  - Sources: standard/codex (weakness 7, 8, question 12), adversarial/claude (B2,
    question 7), adversarial/codex (blind spot 5, challenged decisions, question 13,
    14), evolutionary/codex (section 5), adversarial/gemini (challenged decisions).

- **I6: The feature's most likely failure is invisible, and the only detector is last and gated**
  - Where in the plan: step 6 (all visible evidence, "after the separately requested
    approval").
  - Problem: a tooltip that never renders compiles, passes every step-4 test, and
    goes green in CI. The recorded in-repo lesson
    (`vendor/bonsplit/.../SafeTooltip.swift`) is that a tooltip hosted on a view
    macOS does not query "silently never appeared." Deferring the first hover to
    the end, behind an approval that was **withheld on the immediately preceding
    ticket** (C11-184 shipped both visual gates deferred), means the highest-risk
    unknown is checked last or not at all.
  - Revision: front-load a cheap render proof before the expensive work: either a
    tagged-build probe attaching a hardcoded placeholder tooltip to all three target
    views to confirm each one actually appears, or (per the evolutionary reordering)
    wire Surface Details first as the low-risk surface that proves the projection end
    to end before any hit-testing subtlety. Also add a defined terminal state for a
    second approval denial: what ships, what is deferred, and in what acceptance
    language.
  - Sources: adversarial/claude (exec summary, pattern 2, challenged decision 8,
    disruption A, question 4), adversarial/codex (challenged decisions, "screenshots
    prove presence, not behavior"), standard/codex (weakness 9),
    evolutionary/claude (sequencing step C).

- **I7: Tests are batched after all implementation, and no test-target assignment exists**
  - Where in the plan: step 4 collects all coverage for work done in steps 2 and 3.
  - Problem: for a temporal feature the pure semantics should fail before renderer,
    persistence, and submodule work is built on top of them. Reviewers also note
    that which tests go to `c11LogicTests` vs host `c11Tests` vs Bonsplit's own
    target is a decision with real consequences in this repo (the local
    `c11-logic` workspace-constructing crash caveat; the C11-105 socket-unlink
    incident caused by a test in the wrong target).
  - Revision: move each test family into the step that creates the code it covers,
    put the pure projection plus its fixed-clock test matrix before any renderer
    wiring, and add a small table assigning every planned test to its target
    (`c11LogicTests`, `c11Tests`, Bonsplit). Keep the existing step-4 case list,
    which reviewers agreed is a good list, and add the boundary cases from I3.
  - Sources: standard/codex (decomposition, weakness ordering), adversarial/claude
    (B12), evolutionary/claude (sequencing A to F), evolutionary/codex (sequencing),
    evolutionary/gemini (sequencing).

- **I8: Localization scope and ordering are understated**
  - Where in the plan: step 5, "Delegate the final six-locale translation pass in one
    fresh c11 surface, validate catalogs/tokens".
  - Problem: there are two catalogs, not one. Verified
    `vendor/bonsplit/Sources/Bonsplit/Resources/` has **seven** `.lproj` catalogs
    (en, ja, ko, ru, uk, zh-Hans, zh-Hant), and the contract requires Bonsplit
    activity labels to remain localized in all seven. Whether Bonsplit needs any new
    entries depends on an unstated decision: if c11 composes the localized string
    and passes it as data (which architecture item 4 implies), Bonsplit needs zero;
    if Bonsplit composes from parts, it needs seven. Step 5 also orders the Bonsplit
    push **before** the translation pass, so a translation pass that reveals a needed
    `.lproj` string forces a second submodule commit and pointer redo.
  - Revision: state the data-only Bonsplit decision explicitly (or list the seven
    catalog entries as work), freeze English copy before the Bonsplit push, define
    what "Bonsplit catalog validation" concretely is, and reorder so the copy shape
    stops moving before the cross-repo commit lands.
  - Sources: standard/claude (weakness 10, question 12, 13), adversarial/claude
    (B11, question 18), adversarial/codex (secondary assumptions),
    evolutionary/codex (sequencing 6, 7).

- **I9: No correction loop after the step-5 push**
  - Where in the plan: step 5 pushes Bonsplit and the parent branch; step 6 then does
    the self-review and validation.
  - Problem: any defect found in step 6 lands after the submodule push, the parent
    pointer, and the translation delegation. The plan has no defined fix-and-reverify
    path, and no final scoped-status / ancestry check after the last fix.
  - Revision: add an explicit correction loop: after any step-6 fix, re-run the
    scoped `git status` and diff check, re-verify Bonsplit remote reachability
    (`merge-base --is-ancestor`) if the submodule changed again, re-run the
    translation/token validation if copy changed, and only then re-enter validation.
  - Sources: standard/codex (weakness 10, question 14), adversarial/codex
    (blind spot 7, "one substantive review/fix/re-review budget").

### Straightforward mediums

- **M1: The absolute timestamp formatter has no timezone and no explicit locale**
  - Where in the plan: step 3 (Surface Details capture); contract "Absolute
    timestamps include timezone", example `2026-07-29 14:31:05 EDT`.
  - Problem: verified `SurfaceManifestView.timestampFormatter` is a `DateFormatter`
    with `dateFormat = "yyyy-MM-dd HH:mm:ss"`, no `timeZone` and no `locale`
    (`Sources/SurfaceManifestView.swift:426-430`). Reusing it silently fails the
    contract, and a fixed `dateFormat` without `locale = en_US_POSIX` can render
    non-Gregorian calendars or non-Latin digits under some user locales. The
    existing `Captured` row uses the same formatter, so the plan must also decide
    whether `Captured` gains a timezone (consistent, but a visible change to a row
    the contract says stays separate) or two formats coexist in the panel.
  - Revision: specify the formatter configuration for the new rows and state the
    `Captured` decision explicitly, either way.
  - Sources: standard/claude (weakness 6, question 8), standard/codex (Surface
    Details section, question 10), adversarial/claude (B9, question 14),
    adversarial/codex (blind spot 4), evolutionary/codex (section 5).

- **M2: The copy value format for Created / Last activity is unspecified**
  - Where in the plan: step 3; contract "remain selectable, and offer an unambiguous
    copy value".
  - Problem: a timezone abbreviation such as `CST` is not globally unambiguous, so
    the displayed string and the copied string may need to differ. Three reviewers
    ask which one lands on the pasteboard.
  - Revision: state it: localized timezone-bearing text for display, and an
    unambiguous offset-bearing form (ISO 8601 with numeric UTC offset) for the copy
    action.
  - Sources: standard/codex (question 10), adversarial/codex (blind spot 4,
    question 11), evolutionary/codex (question 5).

- **M3: The collapsed/overflow tab mark and the `+N` census chip are unresolved against AC1**
  - Where in the plan: step 2, "the top-tab mark" (singular).
  - Problem: verified there are **two** `TabActivityMark(` call sites:
    `vendor/bonsplit/.../TabItemView.swift:742` (the tab's leading accessory) and
    `.../TabBarView.swift:1238` (`collapsedActivityMark`). The contract excludes the
    c11 aggregate composition rail but says nothing about the collapsed chip. On the
    sidebar side, the census mark row compresses to a `+N` chip under width pressure,
    so hidden marks and the chip itself get no tooltip, against AC1's "every
    individual agent mark."
  - Revision: state a decision for the collapsed/overflow tab mark and for the `+N`
    chip and hidden census marks (in scope with what copy, or explicitly out of scope
    with AC1 read as "every *visible* individual mark").
  - Sources: standard/claude (weakness 9, question 7), adversarial/claude (B5, B16,
    question 16), evolutionary/codex (question 7, suggestion 9).

- **M4: Use the existing bulk tracker read rather than N per-agent `queue.sync` calls**
  - Where in the plan: step 2 precompute in the sidebar roster path.
  - Problem: verified `SurfaceActivityTracker.lastActivity(for:)` is a `queue.sync`
    hop onto a `.utility`-QoS serial queue
    (`Sources/Conversation/SurfaceActivity.swift:60-66`). Calling it once per agent
    from the sidebar roster build, which runs on every parent evaluation, is a
    serialized main-to-utility round trip per agent per evaluation, with priority
    inversion risk. A bulk read already exists: `snapshot()` (`:78+`), used by the
    snapshot-capture path.
  - Revision: state that the precompute takes one `SurfaceActivityTracker.snapshot()`
    per sync and indexes into it, never a point read per agent.
  - Sources: standard/claude (weakness 5, question 19), adversarial/claude (B3,
    question 8).

- **M5: Non-agent surfaces are undefined for the new rows**
  - Where in the plan: step 3; contract Surface Details group is "always-visible".
  - Problem: what Activity and Last activity show for browser, markdown, and plain
    non-agent shell surfaces is unstated. Guessing wrong here silently broadens what
    c11 claims to observe, which the contract's out-of-scope list forbids.
  - Revision: state per surface kind what Activity and Last activity display, using
    `Not recorded` where c11 has no trustworthy observation source rather than
    inventing one.
  - Sources: standard/codex (question 8), adversarial/codex (blind spot 4,
    question 10), evolutionary/codex (section 5, question 3).

- **M6: Name the existing padded mark container as the tooltip owner, and require click transparency**
  - Where in the plan: performance guardrail "The top tooltip target may include the
    mark padding ... but must not change layout, tab selection, context menus, or
    close behavior"; AC4.
  - Problem: the plan treats the hit target as a clause. It is the fiddliest part of
    the ticket: the owner view must be hit-testable enough that macOS queries it for
    a tooltip while staying transparent to click routing. Reviewers also note the
    good news the plan does not use: the padded hit area already exists as a
    fixed-size container around the mark in Bonsplit's `TabItemView` (roughly
    `:737-775`), so AC4 can be satisfied with no geometry change at all.
  - Revision: name the existing padded container as the tooltip owner for the top
    tab, name the equivalent owner for each sidebar mark location, and state the
    hit-testable-for-tooltips / transparent-to-clicks pair as an explicit
    requirement with its own verification, not a clause.
  - Sources: standard/claude (weakness 4 closing note), standard/codex (Bonsplit
    boundary section), evolutionary/claude (section 1 gotcha, question 7,
    suggestion 1), adversarial/codex (blind spot 6).

### Evolutionary clear wins

- **EW1: Reuse Surface Details' existing row and copy affordances for the new group**
  - Where in the plan: step 3, "capture structured Activity/Created/Last activity data
    for Surface Details".
  - Problem: verified `Sources/SurfaceManifestView.swift` already has
    `refRow(label:value:field:size:)` (`:168`), `copyButton(field:value:)` (`:239`),
    and the `copiedField` / "Copied" confirmation flow (`:70`, `:415`). The plan does
    not name them, risking a reimplementation of selectable text and copy in a panel
    the contract forbids redesigning.
  - Revision: state that the new activity/timing group is built from the existing
    `refRow` / `copyButton` / `copiedField` affordances so it is visually native to
    the panel and the selectable/copy requirements come for free.
  - Sources: evolutionary/claude (section 4, suggestion 7), evolutionary/codex
    (section 5 details-row obligations).

---

## Surface to user (do not apply silently)

- **S1: `createdAt` via `Panel` protocol promotion vs a `SurfaceCreationRegistry`**
  - Why deferred: disagreement, and one option contradicts the locked contract.
  - Summary: the contract's architecture item 5 says to promote logical `createdAt`
    to a first-class panel/session property, and standard/codex plus
    evolutionary/codex agree that is the right ownership boundary. evolutionary/claude
    argues for a registry mirroring `SurfaceActivityTracker` instead, on the grounds
    that the protocol route is a wide, shallow diff across the noisiest files
    (`BrowserPanel.swift` is ~10k lines) that must be repeated for every future
    surface kind, whereas a registry needs four touch points that already exist for
    `lastActivityAt` (`Workspace.swift:905`, `AppDelegate.swift:3317`). Both routes
    satisfy the actual contract (`created_at` on `SessionPanelSnapshot`). Choosing
    the registry is a deviation from a locked contract item and should be an
    operator/author call, not a synthesis edit. Whichever is chosen, the plan should
    also answer whether `createdAt` becomes a required `Panel` protocol member or is
    held per-implementation.
  - Sources: evolutionary/claude (section 3, question 4) vs standard/codex
    (architecture section, question 11) and evolutionary/codex (section 5);
    contract architecture item 5. Also standard/claude question 10.

- **S2: Which tooltip mechanism to adopt**
  - Why deferred: design-needed, with real tradeoffs and reviewers landing differently.
  - Summary: B3 requires the plan to *name* a mechanism; which one is a genuine fork.
    standard/claude recommends `.help()` with a sync-time string and a documented
    staleness bound, explicitly to avoid introducing `onHover` into a view whose own
    comments record a tap-breaking regression from exactly that
    (`vendor/bonsplit/.../TabBarView.swift:1034`), accepting that "refresh on hover
    entry" is then relaxed. evolutionary/claude recommends the opposite: a small
    `NSViewRepresentable` (`LazyTooltip`) owning `NSView.toolTip` with an
    `NSToolTipOwner` callback, which is the only mechanism that literally satisfies
    hover-entry freshness and makes AC5 automatic, at the cost of running straight at
    `SafeTooltip.swift`'s recorded silent-failure mode unless the owner view is
    genuinely hit-testable. evolutionary/codex proposes a third route: a generic
    Codable temporal-help payload that Bonsplit samples `Date()` against at hover.
    Each relaxes a different constraint, and one of them relaxes a *contract* line.
    The operator should pick, or explicitly authorize relaxing the hover-entry
    wording.
  - Sources: standard/claude (alternatives, question 5), evolutionary/claude
    (section 1, suggestion 1), evolutionary/codex (section 3, question 8),
    adversarial/claude (challenged decision 2), adversarial/gemini (question 3).

- **S3: Should the state-entry stamp persist across restart?**
  - Why deferred: author-intent-needed; the contract is silent.
  - Summary: B1's recommended stamp raises a question no reviewer can answer from the
    contract. standard/claude argues it should **not** persist ("Working for 3 days"
    across a reboot is a lie) and notes step 3 persists only `createdAt`.
    evolutionary/claude argues the opposite, that persisting `state_entered_at`
    beside the proven `last_activity_at` is the whole point and is what makes the
    data useful later. Related, unmentioned by the contract: waiting duration will
    vanish across restart regardless, because `TerminalNotificationStore` is
    in-memory (see S6).
  - Sources: standard/claude (weakness 1 closing, question 3) vs evolutionary/claude
    (section 1 fix, suggestion 2, question 8).

- **S4: Self-review vs an independent review gate at step 6**
  - Why deferred: author-intent / workflow call.
  - Summary: step 6 says "Perform a rigorous self-review, attach review evidence, and
    enter validation." adversarial/codex flags that a builder self-review is not an
    independent review and that this repo's ticket discipline normally expects a
    fresh reviewer before validation. Whether to add an independent reviewer to this
    ticket is an orchestration decision, not a plan defect the synthesizer should
    resolve.
  - Sources: adversarial/codex (assumption audit, uncomfortable truths, question 15).

- **S5: `Created` will read `Not recorded` on every currently-open surface on ship day**
  - Why deferred: design-needed; a copy/UX decision with no reviewer consensus on the
    fix.
  - Summary: correct per contract (do not invent an original creation time), and
    guaranteed to read as broken: the headline new field is blank everywhere until
    surfaces are recreated, which for long-lived workspaces means weeks.
    adversarial/claude raises it and suggests the copy could explain itself (for
    example a parenthetical noting the field predates the surface) rather than a bare
    `Not recorded`. Any such copy change touches the locked contract's exact wording,
    so the operator should decide.
  - Sources: adversarial/claude (assumption 10, uncomfortable truth 4, question 21).

- **S6: Waiting duration will disappear across restart while its neighbours persist**
  - Why deferred: author-intent-needed; internally consistent with the contract but
    unmentioned by it.
  - Summary: `TerminalNotificationStore` is in-memory, so after a restart a waiting
    surface shows a persisted `Created`, a persisted `Last activity`, and no waiting
    duration. Consistent with "if no trustworthy state-start timestamp exists, show
    the localized state alone", and likely to read as a bug. Worth an explicit
    acknowledgement in the plan or an explicit acceptance by the operator.
  - Sources: adversarial/claude (assumption 11, uncomfortable truth 5).

- **S7: No rollback lever, kill switch, or settings gate**
  - Why deferred: scope decision; single reviewer, and C11-184's precedent is the only
    argument for it.
  - Summary: C11-184 shipped with a pre-registered fallback ladder. C11-185 has
    nothing, so if the tooltips prove noisy, slow, or wrong post-merge the only lever
    is a revert that also removes the Surface Details group operators may already
    rely on.
  - Sources: adversarial/claude (B8, question 20).

- **S8: No typing-latency gate, across three consecutive tickets on the same hot path**
  - Why deferred: operator call on cost vs value; the specific gate is not agreed.
  - Summary: adversarial/claude notes C11-183 and C11-184 both touched `TabItemView`
    and the sidebar mark renderers, that C11-184 defined a 20-agent p95 gate and
    recorded that it "was not run", and that C11-185 defines none while adding
    per-agent work to the same paths. evolutionary/claude suggests the cheap version:
    measure current sidebar body-evaluation frequency during the baseline step, using
    the existing debug event log, so the precompute-cost question is settled
    empirically rather than by argument. B2 and M4 remove the two known regression
    vectors; whether to add a measured gate on top is a scope call.
  - Sources: adversarial/claude (pattern 3, question 9), evolutionary/claude
    (sequencing, suggestion 10), standard/claude (weakness 5).

- **S9: Monotonic clock for duration arithmetic across sleep/wake**
  - Why deferred: single reviewer, and likely counterproductive.
  - Summary: evolutionary/gemini recommends `mach_absolute_time` /
    `systemUptime`-based durations to avoid sleep/wake drift. For this feature the
    wall-clock elapsed reading is arguably the *correct* one (an agent idle across a
    lid-close really has been idle that long), and a monotonic clock would understate
    it. The genuine sub-question worth an answer is whether an agent should present as
    cold immediately on wake when the threshold elapsed while asleep. Do not adopt the
    monotonic-clock change without that decision.
  - Sources: evolutionary/gemini (how it could be better, suggestion 1, question 1).

- **S10: Reviewer misread to disregard: the "parent tooltip already covers the mark" claim**
  - Why deferred: reviewer misread; verified against the file.
  - Summary: adversarial/claude (B4, question 15) asserts that
    `vendor/bonsplit/.../TabBarView.swift:1916` "already attaches `.help(tooltip)` to
    tab chrome", so a new mark tooltip would collide with a parent tooltip and change
    which one appears, breaking AC4. Verified: that `.help(tooltip)` is on a **split
    toolbar action button** (`SplitActionButtonStyle`, the normal/medium bar and
    dropdown controls row), not on tab chrome, and it does not cover the mark region.
    Do not plan around a parent-tooltip collision at that site. The other half of the
    same finding **is** valid and is captured in B5: `TabActivityAccessibility.help(for:)`
    becomes either dead code or a second source of truth for the same sentence.
    Related nuance worth carrying forward: `SafeTooltip.swift`'s recorded lesson is
    that `.help` on the view itself is what *works* and an AppKit `addToolTip` on an
    occluded click-through view is what silently failed, which is the inverse of how
    adversarial/claude frames the `.help()` risk. The hit-testability concern is real;
    the direction of the evidence is not what that review implies.
  - Sources: adversarial/claude (B4, assumption 3, question 15), cross-checked
    against `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift:1890-1917`
    and `vendor/bonsplit/Sources/Bonsplit/Public/SafeTooltip.swift:1-20`.

---

## Evolutionary worth considering (do not apply silently)

- **E1: Emit `activity.state_changed {surface, from, to, at}` at the same edge that stamps the state-entry time**
  - Summary: if B1 is resolved by stamping a transition timestamp, one additional line
    at the same edge, through the existing `Sources/Events/EventEmitter.swift` (which
    already carries C11-184's four attention events), turns a terminal feature into a
    durable, queryable transition log with an existing transport and an existing
    Overwatch consumer.
  - Why worth a look: the argued asymmetry is that deferring the emit does not defer
    the cost, it destroys the history, and the plan is already touching that exact
    seam for a different reason.
  - Sources: evolutionary/claude (the flywheel, suggestion 3, question 5); note
    evolutionary/codex explicitly recommends *not* starting an event history in this
    ticket (mutations item 5), so this is a live disagreement.

- **E2: Land the snapshot fields as a standalone first commit so data starts accumulating immediately**
  - Summary: ship `created_at` (and `state_entered_at`, if adopted) on
    `SessionPanelSnapshot` plus capture/seed/clear as their own purely additive
    commit, before any UI work. The backcompat pattern is already proven by
    `last_activity_at` (verified, `Sources/SessionPersistence.swift:369-379`), so the
    risk is known and the decode path is copy-shaped.
  - Why worth a look: if the rest of the ticket slips, the operator's machine still
    has real creation timestamps accumulating from day one instead of starting at zero
    whenever the UI lands.
  - Sources: evolutionary/claude (sequencing step A, question 8), consistent with
    evolutionary/codex's data-first sequencing (step 3 before UI).

- **E3: File two follow-on tickets now, while the context is hot**
  - Summary: `c11 activity <surface>` as a socket read of the same projection (thin
    once the value type exists; Overwatch currently has to infer duration from prose),
    and oldest-stuck-first as the third rung of C11-184's attention-routing ladder
    (free once a state-entry time exists: no flags, no waiting, jump to the agent cold
    longest).
  - Why worth a look: both are cheap to spec now and much more expensive to spec cold
    in three months; the contract correctly keeps both out of *this* ticket ("no new
    CLI or socket API fields solely for this UI change").
  - Sources: evolutionary/claude (mutations, suggestion 9), evolutionary/codex
    (mutations 2, 4), evolutionary/gemini (what it unlocks).
